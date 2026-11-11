import Foundation
import Security
import WatchConnectivity

/// The watch keeps its own credential, delivered once from the phone over WatchConnectivity.
/// It never reads the phone's Keychain.
@MainActor final class WatchStore: ObservableObject {
    @Published private(set) var devices: [MonitorDevice] = []
    @Published private(set) var events: [MonitorEvent] = []
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var bridge = ""
    @Published private(set) var hasCredential = false
    @Published var error: String?

    private let account = "agent-monitor-watch-token"
    private let defaults = UserDefaults.standard
    private var clock: SnapshotClock?
    private var sceneActive = true

    var latestTasks: [MonitorEvent] { Snapshot(devices: devices, events: events).latestTasks }
    var paired: Bool { hasCredential && !bridge.isEmpty }

    init() {
        bridge = defaults.string(forKey: "bridgeURL") ?? ""
        hasCredential = Keychain.read(account) != nil
        #if DEBUG
        // Debug-only: lets a watch simulator run be seeded instead of relying on a paired phone.
        let env = ProcessInfo.processInfo.environment
        if let token = env["MONITOR_DEBUG_TOKEN"], let seededBridge = env["MONITOR_DEBUG_BRIDGE"] {
            if !Keychain.save(token, account: account) {
                defaults.set(token, forKey: "debugWatchToken")
            }
            defaults.set(seededBridge, forKey: "bridgeURL")
            bridge = seededBridge
            hasCredential = true
        }
        #endif
        WatchLink.shared.onCredentials = { [weak self] bridge, token in
            Task { @MainActor in self?.accept(bridge: bridge, token: token) }
        }
        WatchLink.shared.onCleared = { [weak self] in
            Task { @MainActor in self?.accept(bridge: "", token: nil) }
        }
        WatchLink.shared.activate()
    }

    func setActive(_ active: Bool) {
        sceneActive = active
        if active { WatchLink.shared.requestCredentials() }
    }

    func refresh() async {
        guard paired, !isRefreshing, let token = credential() else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let snapshot = try await MonitorAPI.snapshot(base: bridge, token: token)
            devices = snapshot.devices
            events = snapshot.events.sorted { $0.occurredAt > $1.occurredAt }
            let receivedAt = Date()
            clock = SnapshotClock(serverTime: snapshot.serverTime ?? receivedAt.timeIntervalSince1970, receivedAt: receivedAt)
            lastSync = receivedAt
            syncError = nil
        } catch is CancellationError {
        } catch {
            syncError = error.localizedDescription
        }
    }

    func requestFromPhone() {
        WatchLink.shared.requestCredentials()
    }

    func serverDate(at date: Date) -> Date { clock?.serverDate(at: date) ?? date }

    func deviceIsOnline(_ device: MonitorDevice, at date: Date) -> Bool {
        device.isOnline(at: serverDate(at: date))
    }

    func isStale(_ event: MonitorEvent, at date: Date) -> Bool {
        event.taskStatus.isActive
            && (!snapshotIsCurrent(at: date) || !(devices.first { $0.deviceId == event.deviceId }.map { deviceIsOnline($0, at: date) } ?? false))
    }

    func snapshotIsCurrent(at date: Date) -> Bool {
        guard let lastSync else { return false }
        return syncError == nil && date.timeIntervalSince(lastSync) <= 30
    }

    private func accept(bridge newBridge: String, token: String?) {
        if let token, !newBridge.isEmpty {
            _ = Keychain.save(token, account: account)
            defaults.set(newBridge, forKey: "bridgeURL")
            bridge = newBridge
            hasCredential = true
            error = nil
            Task { await refresh() }
        } else if token == nil && newBridge.isEmpty {
            Keychain.delete(account)
            defaults.removeObject(forKey: "bridgeURL")
            bridge = ""
            hasCredential = false
            devices = []
            events = []
            lastSync = nil
            syncError = nil
        }
    }

    private func credential() -> String? {
        if let stored = Keychain.read(account) { return stored }
        #if DEBUG
        return defaults.string(forKey: "debugWatchToken")
        #else
        return nil
        #endif
    }
}

/// Credentials and a one-shot pull request cross the phone-watch boundary here.
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()
    var onCredentials: ((String, String) -> Void)?
    var onCleared: (() -> Void)?

    private var activated = false

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        activated = true
    }

    func requestCredentials() {
        guard activated, WCSession.default.activationState == .activated else { return }
        WCSession.default.sendMessage(["pull": true], replyHandler: { [weak self] reply in
            guard let bridge = reply["bridge"] as? String, let token = reply["token"] as? String,
                  !bridge.isEmpty, !token.isEmpty else { return }
            self?.onCredentials?(bridge, token)
        }, errorHandler: { _ in })
    }

    private func apply(_ context: [String: Any]) {
        guard let bridge = context["bridge"] as? String, let token = context["token"] as? String else { return }
        if bridge.isEmpty || token.isEmpty { onCleared?() } else { onCredentials?(bridge, token) }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        if !session.receivedApplicationContext.isEmpty { apply(session.receivedApplicationContext) }
        requestCredentials()
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        apply(applicationContext)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        apply(message)
        replyHandler([:])
    }
}

private enum Keychain {
    private static let service = "org.nousresearch.agent-monitor"

    static func save(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func read(_ account: String) -> String? {
        var result: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}