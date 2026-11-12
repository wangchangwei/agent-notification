import AVFoundation
import AudioToolbox
import Security
import SwiftUI
import UIKit
import UserNotifications

@MainActor final class MonitorStore: ObservableObject {
    @Published var devices: [MonitorDevice] = []
    @Published var events: [MonitorEvent] = []
    @Published var error: String?
    @Published var paired: Bool = false
    @Published var lastSync: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isPairing = false
    @Published private(set) var syncError: String?
    var latestTasks: [MonitorEvent] { Snapshot(devices: devices, events: events).latestTasks }
    private var snapshotClock: SnapshotClock?
    private var watcher = StatusTransitionWatcher()
    private var lastCompletionFeedback: Date?
    private var sceneIsActive = true
    @Published var soundEnabled: Bool = true

    func setSceneActive(_ active: Bool) {
        sceneIsActive = active
        if active { pushCredentialsToWatch() }
    }

    /// The watch keeps its own copy of the credential; resend it whenever the phone comes forward.
    func pushCredentialsToWatch() {
        PhoneWatchLink.shared.activate()
        guard let token = token(), !bridge.isEmpty else {
            PhoneWatchLink.shared.publish(bridge: "", token: nil)
            return
        }
        PhoneWatchLink.shared.publish(bridge: bridge, token: token)
    }
    func setSoundEnabled(_ enabled: Bool) {
        soundEnabled = enabled
        defaults.set(enabled, forKey: "completionSound")
    }

    func serverDate(at date: Date) -> Date { snapshotClock?.serverDate(at: date) ?? date }

    func deviceIsOnline(_ device: MonitorDevice, at date: Date) -> Bool {
        device.isOnline(at: serverDate(at: date))
    }

    func snapshotIsCurrent(at date: Date) -> Bool {
        guard let lastSync else { return false }
        return syncError == nil && date.timeIntervalSince(lastSync) <= 15
    }

    func isStale(_ event: MonitorEvent, at date: Date) -> Bool {
        event.taskStatus.isActive && (!snapshotIsCurrent(at: date) || !(devices.first { $0.deviceId == event.deviceId }.map { deviceIsOnline($0, at: date) } ?? false))
    }
    private let account = "agent-monitor-phone-token"
    private let defaults = UserDefaults.standard
    var bridge: String { (defaults.string(forKey: "bridgeURL") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    init() {
        soundEnabled = (UserDefaults.standard.object(forKey: "completionSound") as? Bool) ?? true
        #if DEBUG
        // Debug-only: lets a simulator run be seeded from the environment
        // (SIMCTL_CHILD_MONITOR_DEBUG_TOKEN / _BRIDGE) instead of typing a pairing code.
        let env = ProcessInfo.processInfo.environment
        if let token = env["MONITOR_DEBUG_TOKEN"], let bridge = env["MONITOR_DEBUG_BRIDGE"] {
            UserDefaults.standard.set(bridge, forKey: "bridgeURL")
            // The simulator's Keychain may refuse the item; the fallback keeps the run usable.
            if !Keychain.save(token, account: "agent-monitor-phone-token") {
                UserDefaults.standard.set(token, forKey: "debugPhoneToken")
            }
        }
        #endif
        paired = token() != nil && !(UserDefaults.standard.string(forKey: "bridgeURL") ?? "").isEmpty
    }

    private func token() -> String? {
        if let stored = Keychain.read(account) { return stored }
        #if DEBUG
        return UserDefaults.standard.string(forKey: "debugPhoneToken")
        #else
        return nil
        #endif
    }

    func pair(rawCode: String, rawBridge: String) async {
        guard !isPairing else { return }
        isPairing = true
        defer { isPairing = false }
        let url = rawBridge.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let parsed = URL(string: url), parsed.scheme == "https" || parsed.host == "localhost" || parsed.host == "127.0.0.1" else { error = "Enter a valid HTTPS bridge URL."; return }
        let code = Self.code(from: rawCode)
        guard !code.isEmpty else { error = "That QR code or pairing code is not valid."; return }
        do {
            let response: PairResponse = try await request("/v1/pair/redeem", base: url, body: PairRequest(code: code))
            guard Keychain.save(response.accessToken, account: account) else { throw MonitorError.keychain }
            defaults.set(url, forKey: "bridgeURL"); defaults.set(response.ownerId, forKey: "ownerId")
            paired = true; error = nil
            await refresh()
            pushCredentialsToWatch()
            UIApplication.shared.registerForRemoteNotifications()
        } catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        guard paired, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            guard let token = token() else { throw MonitorError.notPaired }
            let result = try await MonitorAPI.snapshot(base: bridge, token: token)
            devices = result.devices
            events = result.events.sorted { $0.occurredAt > $1.occurredAt }
            let receivedAt = Date()
            let clock = SnapshotClock(serverTime: result.serverTime ?? receivedAt.timeIntervalSince1970, receivedAt: receivedAt)
            snapshotClock = clock
            lastSync = receivedAt; syncError = nil
            announceCompletions(in: result, clock: clock, receivedAt: receivedAt)
        } catch is CancellationError {
        } catch { syncError = error.localizedDescription }
    }

    func savePushToken(_ token: String) async {
        guard paired else { return }
        do { let _: Ack = try await authorized("/v1/push-token", method: "PUT", body: PushRequest(token: token)) }
        catch { self.error = "Push token not synced yet." }
    }

    func revoke(_ device: MonitorDevice) async {
        do { let _: Ack = try await authorized("/v1/devices/\(device.deviceId)", method: "DELETE"); await refresh() }
        catch { self.error = error.localizedDescription }
    }

    func rename(_ device: MonitorDevice, to name: String) async {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let fallback = trimmed.isEmpty ? "Mac" : trimmed
        do {
            let _: RenameAck = try await authorized(
                "/v1/devices/\(device.deviceId)", method: "PUT", body: RenameRequest(deviceName: fallback)
            )
            if let index = devices.firstIndex(where: { $0.deviceId == device.deviceId }) {
                devices[index] = MonitorDevice(
                    deviceId: device.deviceId, lastSeen: device.lastSeen, online: device.online, deviceName: fallback
                )
            }
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func unpair() async {
        do { let _: Ack = try await authorized("/v1/pairing", method: "DELETE") }
        catch { self.error = "Unpairing was not confirmed; the credential stays on this phone."; return }
        Keychain.delete(account); defaults.removeObject(forKey: "bridgeURL"); defaults.removeObject(forKey: "ownerId")
        #if DEBUG
        defaults.removeObject(forKey: "debugPhoneToken")
        #endif
        devices = []; events = []; paired = false; error = nil; lastSync = nil; syncError = nil; snapshotClock = nil
        watcher.reset()
        PhoneWatchLink.shared.publish(bridge: "", token: nil)
    }

    func clearCloudHistory() async {
        do {
            let _: Ack = try await authorized("/v1/events", method: "DELETE")
            events = []; error = nil
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    /// Sounds only for a task that genuinely moved from active to finished while the app was open.
    private func announceCompletions(in snapshot: Snapshot, clock: SnapshotClock, receivedAt: Date) {
        let finished = watcher.completed(among: snapshot.latestTasks, freshAfter: clock.serverTime - 120)
        // A push for the same completion can arrive next to the poll; keep it to one signal.
        guard CompletionPolicy.shouldRing(finished: finished.count, enabled: soundEnabled, sceneActive: sceneIsActive, lastRing: lastCompletionFeedback, now: receivedAt) else { return }
        lastCompletionFeedback = receivedAt
        CompletionFeedback.play()
    }

    private func authorized<R: Decodable, B: Encodable>(_ path: String, method: String, body: B? = Optional<EmptyBody>.none) async throws -> R {
        guard let token = token(), !bridge.isEmpty else { throw MonitorError.notPaired }
        var req = try makeRequest(path, base: bridge, method: method, body: body)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await perform(req)
    }

    private func request<R: Decodable, B: Encodable>(_ path: String, base: String, body: B) async throws -> R {
        try await perform(makeRequest(path, base: base, method: "POST", body: body))
    }

    private func makeRequest<B: Encodable>(_ path: String, base: String, method: String, body: B?) throws -> URLRequest {
        guard let url = URL(string: base + path) else { throw MonitorError.badURL }
        var req = URLRequest(url: url, timeoutInterval: 10); req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONEncoder().encode(body) }
        return req
    }

    private func perform<R: Decodable>(_ req: URLRequest) async throws -> R {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw MonitorError.response }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw MonitorError.unauthorized }
            if http.statusCode == 410 { throw MonitorError.expired }
            throw MonitorError.server(http.statusCode)
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(R.self, from: data)
    }

    static func code(from raw: String) -> String {
        if let url = URLComponents(string: raw), let code = url.queryItems?.first(where: { $0.name == "code" })?.value { return code }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@main struct AgentMonitorApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var push
    @StateObject private var store = MonitorStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .task(id: phase) {
                    store.setSceneActive(phase == .active)
                    guard phase == .active else { return }
                    if store.paired { UIApplication.shared.registerForRemoteNotifications() }
                    while !Task.isCancelled { await store.refresh(); try? await Task.sleep(for: .seconds(5)) }
                }
                .onReceive(push.$deviceToken.compactMap { $0 }) { token in Task { await store.savePushToken(token) } }
        }
    }
}


@MainActor final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    @Published var deviceToken: String?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool { UNUserNotificationCenter.current().delegate = self; return true }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) { deviceToken = token.map { String(format: "%02x", $0) }.joined() }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound, .list] }
}

enum CompletionFeedback {
    /// System sound respects the ring/silent switch; the haptic still confirms on a muted phone.
    static func play() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AudioServicesPlaySystemSound(1007)
    }
}

private enum Keychain {
    static func save(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }; delete(account)
        return SecItemAdd([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.nousresearch.agent-monitor", kSecAttrAccount as String: account, kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil) == errSecSuccess
    }
    static func read(_ account: String) -> String? {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.nousresearch.agent-monitor", kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete(_ account: String) { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.nousresearch.agent-monitor", kSecAttrAccount as String: account] as CFDictionary) }
}

private struct PairRequest: Encodable { let code: String }
private struct PairResponse: Decodable { let ownerId: String; let accessToken: String }
private struct PushRequest: Encodable { let token: String }
private struct RenameRequest: Encodable { let deviceName: String }
private struct RenameAck: Decodable { let deviceId: String?; let deviceName: String? }
private struct Ack: Decodable { let registered: Bool?; let revoked: Bool?; let unpaired: Bool?; let cleared: Bool? }
private struct EmptyBody: Encodable {}

private enum MonitorError: LocalizedError {
    case keychain, notPaired, badURL, response, unauthorized, expired, server(Int)
    var errorDescription: String? {
        switch self { case .keychain: "Could not save the credential to the Keychain."; case .notPaired: "This phone is not paired."; case .badURL: "That bridge URL is not valid."; case .response: "The bridge returned an unreadable response."; case .unauthorized: "This phone was revoked. Pair again."; case .expired: "The pairing code expired or was already used."; case .server(let status): "The bridge rejected the request (\(status))." }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { let controller = ScannerController(); controller.onCode = onCode; return controller }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var layer: AVCaptureVideoPreviewLayer?
    private var scanned = false
    override func viewDidLoad() { super.viewDidLoad(); view.backgroundColor = .black; configure() }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); layer?.frame = view.bounds }
    private func configure() {
        guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { message("Camera unavailable. Type the pairing code instead."); return }
        session.addInput(input); let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { message("Could not start the QR scanner."); return }
        session.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session); preview.videoGravity = .resizeAspectFill; view.layer.addSublayer(preview); layer = preview
        let close = UIButton(type: .system); close.setTitle("Close", for: .normal); close.tintColor = .white; close.addTarget(self, action: #selector(closeScanner), for: .touchUpInside); close.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(close)
        NSLayoutConstraint.activate([close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18), close.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)])
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in DispatchQueue.main.async { if allowed { self?.session.startRunning() } else { self?.message("Allow camera access in Settings.") } } }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !scanned, let value = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first?.stringValue else { return }
        scanned = true; onCode?(value)
    }
    private func message(_ text: String) { let label = UILabel(); label.text = text; label.textColor = .white; label.numberOfLines = 0; label.textAlignment = .center; label.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(label); NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: view.centerXAnchor), label.centerYAnchor.constraint(equalTo: view.centerYAnchor), label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)]) }
    @objc private func closeScanner() { dismiss(animated: true) }
}
