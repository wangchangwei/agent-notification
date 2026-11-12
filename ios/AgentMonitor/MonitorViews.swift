import SwiftUI
import UIKit
import UserNotifications

/// System colors and text styles only. `color.md › System colors` asks apps not to hard-code
/// system values, and `dark-mode.md › Mobile` asks for the system base/elevated backgrounds
/// instead of custom surfaces.
private enum Palette {
    static let accent = Color.green
    static let waiting = Color.orange
    static let failure = Color.red
}

private extension MonitorTaskStatus {
    var tint: Color {
        switch self {
        case .running: Palette.accent
        case .waiting: Palette.waiting
        case .failed: Palette.failure
        case .completed, .interrupted, .incomplete, .unknown: .secondary
        }
    }
}

struct RootView: View {
    @ObservedObject var store: MonitorStore
    @State private var settings = false

    var body: some View {
        NavigationStack {
            Group {
                if store.paired { Dashboard(store: store) }
                else { Pairing(store: store) }
            }
            .navigationTitle("Agent Monitor")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if store.paired {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { settings = true } label: { Image(systemName: "slider.horizontal.3") }
                            .accessibilityLabel("Open settings")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let error = store.error {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.waiting)
                        Text(error).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                        Button { store.error = nil } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Dismiss message")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .padding(.leading, 16)
                    .background(.bar)
                    .overlay(alignment: .top) { Divider() }
                }
            }
        }
        .tint(Palette.accent)
        .sheet(isPresented: $settings) { MonitorSettings(store: store) }
    }
}

/// The single moving element in the app: a live dot on a running task.
/// `motion.md` asks motion to be purposeful and optional, so it stops under Reduce Motion.
private struct LiveDot: View {
    var tint: Color
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.3 : 1)
            .animation(animated && !reduceMotion ? .easeInOut(duration: 1.3).repeatForever(autoreverses: true) : nil, value: dim)
            .onAppear { if animated && !reduceMotion { dim = true } }
            .accessibilityHidden(true)
    }
}

private struct StatusBadge: View {
    let status: MonitorTaskStatus
    var stale = false

    var body: some View {
        HStack(spacing: 4) {
            if status == .running && !stale {
                LiveDot(tint: status.tint)
            } else {
                Image(systemName: stale ? "clock" : status.symbol).imageScale(.small)
            }
            Text(stale ? "Stale · \(status.title)" : status.title)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(stale ? Color.secondary : status.tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background((stale ? Color.secondary : status.tint).opacity(0.12), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(stale ? "Last known: \(status.title), now stale" : status.title)
    }
}

private struct AgeLabel: View {
    let date: Date
    let now: Date
    var body: some View { Text(Self.text(date: date, now: now)).monospacedDigit() }

    static func text(date: Date, now: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

/// One line of sync state and one line of counts, replacing the old bar plus three-metric strip.
/// `layout.md › Visual hierarchy` prefers grouping with space over extra containers.
private struct StatusSummary: View {
    @ObservedObject var store: MonitorStore
    let now: Date
    let running: Int
    let waiting: Int
    let online: Int

    private var current: Bool { store.snapshotIsCurrent(at: now) }
    private var tone: Color { current ? Palette.accent : Palette.waiting }
    private var headline: String {
        if current { return "Synced" }
        if store.lastSync == nil && store.syncError == nil { return "Connecting" }
        return "Sync problem · showing last snapshot"
    }
    private var detail: String {
        guard current else { return "Waiting for the next sync" }
        return "\(running) running · \(waiting) waiting · \(online) online"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                LiveDot(tint: tone, animated: current)
                Text(headline).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else if let date = store.lastSync {
                    AgeLabel(date: date, now: now).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Text(store.syncError ?? detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private enum TaskFilter: String, CaseIterable, Identifiable {
    case all = "All", running = "Running", waiting = "Waiting", finished = "Finished"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .running: "circle.dotted"
        case .waiting: "hand.raised"
        case .finished: "checkmark.circle"
        }
    }

    func includes(_ event: MonitorEvent) -> Bool {
        switch self {
        case .all: true
        case .running: event.taskStatus == .running
        case .waiting: event.taskStatus == .waiting
        case .finished: [.completed, .failed, .interrupted, .incomplete].contains(event.taskStatus)
        }
    }
}

struct Dashboard: View {
    @ObservedObject var store: MonitorStore
    @State private var filter: TaskFilter = .all
    @State private var renaming: MonitorDevice?
    @State private var renameText = ""
    #if DEBUG
    // Debug-only: lets a simulator run open the sheet for a screenshot.
    @State private var addingComputer = ProcessInfo.processInfo.environment["MONITOR_DEBUG_ADD_COMPUTER"] == "1"
    #else
    @State private var addingComputer = false
    #endif

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let now = context.date
            let current = store.snapshotIsCurrent(at: now)
            let tasks = store.latestTasks.sorted {
                let left = store.isStale($0, at: now) ? 3 : $0.taskStatus.priority
                let right = store.isStale($1, at: now) ? 3 : $1.taskStatus.priority
                if left != right { return left < right }
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
                return $0.taskKey < $1.taskKey
            }
            let visible = tasks.filter { filter.includes($0) }
            List {
                Section {
                    StatusSummary(
                        store: store, now: now,
                        running: tasks.filter { $0.taskStatus == .running && !store.isStale($0, at: now) }.count,
                        waiting: tasks.filter { $0.taskStatus == .waiting && !store.isStale($0, at: now) }.count,
                        online: store.devices.filter { store.deviceIsOnline($0, at: now) }.count
                    )
                }
                Section {
                    if store.lastSync == nil && store.syncError == nil {
                        placeholder("Loading computers…")
                    } else if store.devices.isEmpty {
                        placeholder("No Macs yet. Tap Add a computer, then run the command it shows on that Mac.")
                    }
                    ForEach(store.devices.sorted { $0.deviceId < $1.deviceId }) { device in
                        DeviceRow(
                            device: device,
                            activeTasks: tasks.filter { $0.deviceId == device.deviceId && $0.taskStatus.isActive }.count,
                            now: store.serverDate(at: now),
                            snapshotCurrent: current
                        )
                        .swipeActions {
                            Button("Revoke", role: .destructive) { Task { await store.revoke(device) } }
                            Button("Rename") { renameText = device.deviceName ?? ""; renaming = device }.tint(.indigo)
                        }
                        .contextMenu {
                            Button("Rename this Mac") { renameText = device.deviceName ?? ""; renaming = device }
                        }
                    }
                    Button { addingComputer = true } label: {
                        Label("Add a computer", systemImage: "plus.circle")
                    }
                } header: {
                    sectionHeader("Computers", trailing: "\(store.devices.count)")
                } footer: {
                    Text("A missing heartbeat only means the Mac is offline; it does not mean its tasks failed. Swipe a computer row to rename it.")
                }
                .alert("Name this Mac", isPresented: Binding(
                    get: { renaming != nil },
                    set: { if !$0 { renaming = nil } }
                )) {
                    TextField("e.g. Studio MacBook", text: $renameText)
                    Button("Cancel", role: .cancel) { renaming = nil }
                    Button("Save") {
                        guard let device = renaming else { return }
                        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        renaming = nil
                        Task { await store.rename(device, to: name) }
                    }
                } message: {
                    Text("Shown on this phone only, to tell Macs apart. Leave it empty for the default.")
                }
                Section {
                    if store.lastSync == nil && store.syncError == nil {
                        placeholder("Loading tasks…")
                    } else if visible.isEmpty {
                        placeholder(tasks.isEmpty ? "No activity yet. Tasks appear here once Hermes starts working." : "No \(filter.rawValue.lowercased()) tasks.")
                    }
                    ForEach(visible, id: \.taskKey) { event in
                        NavigationLink {
                            TaskDetail(store: store, taskId: event.taskId, deviceId: event.deviceId)
                        } label: {
                            TaskRow(event: event, stale: store.isStale(event, at: now))
                        }
                    }
                } header: {
                    sectionHeader("Recent", trailing: filter == .all ? "\(visible.count)" : "\(filter.rawValue) · \(visible.count)")
                } footer: {
                    Text("Kept for 7 days. A finished turn means the agent stopped for that turn; the result still needs review.")
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await store.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Filter", selection: $filter) {
                            ForEach(TaskFilter.allCases) { item in
                                Label(item.rawValue, systemImage: item.symbol).tag(item)
                            }
                        }
                        Divider()
                        Button { Task { await store.refresh() } } label: {
                            Label("Refresh now", systemImage: "arrow.clockwise")
                        }
                        .disabled(store.isRefreshing)
                    } label: {
                        Image(systemName: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Filter tasks")
                }
            }
            .sheet(isPresented: $addingComputer) { AddComputerSheet(store: store) }
        }
    }

    private func sectionHeader(_ title: String, trailing: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(trailing).monospacedDigit()
        }
        .font(.footnote)
        .textCase(nil)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
    }
}

/// Settings-style row anatomy: a glyph chip, then title with a secondary line, then the value.
private struct DeviceRow: View {
    let device: MonitorDevice
    let activeTasks: Int
    let now: Date
    let snapshotCurrent: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    private var online: Bool { device.isOnline(at: now) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if device.lastSeen > 0 && !typeSize.isAccessibilitySize {
                AgeLabel(date: Date(timeIntervalSince1970: TimeInterval(device.lastSeen)), now: now)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if !snapshotCurrent { return online ? "Connecting" : "Last heartbeat expired" }
        if !online { return "Offline · state is stale" }
        return activeTasks == 0 ? "Online · idle" : "Online · \(activeTasks) active"
    }
}

struct TaskRow: View {
    let event: MonitorEvent
    var stale = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: event.brandSymbol)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.displayName)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(event.brandLabel).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 6)
                    StatusBadge(status: event.taskStatus, stale: stale)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct TaskDetail: View {
    @ObservedObject var store: MonitorStore
    let taskId: String
    let deviceId: String
    private var history: [MonitorEvent] {
        store.events.filter { $0.taskId == taskId && $0.deviceId == deviceId }.sorted { $0.occurredAt > $1.occurredAt }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let now = context.date
            let deviceOnline = store.devices.first { $0.deviceId == deviceId }.map { store.deviceIsOnline($0, at: now) } ?? false
            List {
                if let event = history.first {
                    let stale = store.isStale(event, at: now)
                    Section {
                        TaskRow(event: event, stale: stale)
                        if stale {
                            Label(deviceOnline ? "Sync interrupted; this is the last snapshot." : "Mac offline; this state is stale.",
                                  systemImage: "clock.badge.exclamationmark")
                                .font(.footnote)
                                .foregroundStyle(Palette.waiting)
                        }
                    }
                    Section {
                        LabeledContent("Agent", value: event.brandLabel)
                        LabeledContent("Kind", value: event.agentKind)
                        LabeledContent("Mac", value: "Mac · \(deviceId.suffix(6))")
                        LabeledContent("Last event", value: event.date.formatted(date: .abbreviated, time: .standard))
                        if let parent = event.parentTaskId {
                            LabeledContent("Parent", value: String(parent.suffix(6)))
                        }
                    }
                    Section {
                        ForEach(history) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: item.taskStatus.symbol)
                                    .foregroundStyle(item.taskStatus.tint)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.activity).font(.subheadline).textSelection(.enabled)
                                    HStack(spacing: 8) {
                                        Text(item.date.formatted(date: .omitted, time: .standard)).monospacedDigit()
                                        if let duration = item.durationMs {
                                            Text("\((Double(duration) / 1_000).formatted(.number.precision(.fractionLength(0...2))))s")
                                        }
                                    }
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                StatusBadge(status: item.taskStatus)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        Text("Events · \(history.count)").textCase(nil)
                    } footer: {
                        Text("Newest first. A finished turn does not mean the result was accepted.")
                    }
                } else {
                    ContentUnavailableView("No record for this task", systemImage: "clock", description: Text("It may have been cleared, or is older than the 7-day window."))
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await store.refresh() }
            .navigationTitle(history.first?.displayName ?? "Details")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct Pairing: View {
    @ObservedObject var store: MonitorStore
    @State private var bridge = "https://"
    @State private var code = ""
    @State private var scanning = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hermes status, on your phone").font(.headline)
                    Text("Once paired, task starts, waiting states, finished turns and failures sync here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section {
                TextField("Bridge URL (https)", text: $bridge)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Bridge URL")
                HStack {
                    TextField("One-time pairing code", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { scanning = true } label: { Image(systemName: "qrcode.viewfinder") }
                        .accessibilityLabel("Scan pairing QR code").frame(minWidth: 44, minHeight: 44)
                }
                Button {
                    Task { await store.pair(rawCode: code, rawBridge: bridge) }
                } label: {
                    HStack(spacing: 8) {
                        if store.isPairing { ProgressView().controlSize(.small) }
                        Text(store.isPairing ? "Pairing…" : "Pair Mac")
                    }
                    .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isPairing)
            } header: {
                Text("Pair a Mac")
            } footer: {
                Text("Run agent-monitor pair on the Mac to get a QR code. The code is valid for 5 minutes and works once.")
            }
        }
        .sheet(isPresented: $scanning) {
            QRScanner { value in
                code = value; scanning = false
                Task { await store.pair(rawCode: value, rawBridge: bridge) }
            }.ignoresSafeArea()
        }
    }
}

private struct MonitorSettings: View {
    @ObservedObject var store: MonitorStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var confirmUnpair = false
    @State private var confirmClearHistory = false
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    private var notificationTitle: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: "Allowed"
        case .denied: "Denied"
        case .notDetermined: "Not requested"
        @unknown default: "Unknown"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Bridge", value: URL(string: store.bridge)?.host ?? store.bridge)
                    LabeledContent("Macs", value: "\(store.devices.count)")
                    LabeledContent("Last sync", value: store.lastSync?.formatted(date: .omitted, time: .standard) ?? "Never")
                    if let error = store.error {
                        Text(error).font(.footnote).foregroundStyle(Palette.waiting)
                    }
                } header: {
                    Text("Connection")
                }
                Section {
                    LabeledContent("Permission", value: notificationTitle)
                    Button(notificationStatus == .notDetermined ? "Enable task notifications" : "Manage notifications") {
                        Task {
                            if notificationStatus != .notDetermined {
                                if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
                            } else {
                                let allowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
                                if allowed { UIApplication.shared.registerForRemoteNotifications() }
                                await updateNotificationStatus()
                            }
                        }
                    }
                } header: {
                    Text("Task notifications")
                } footer: {
                    Text("Alerts for finished, failed and waiting tasks. The lock screen shows only the event type; open the app for the current state.")
                }
                Section {
                    Toggle(isOn: Binding(get: { store.soundEnabled }, set: { store.setSoundEnabled($0) })) {
                        Label("Sound when a turn finishes", systemImage: "speaker.wave.2")
                    }
                    Button { CompletionFeedback.play() } label: {
                        Label("Preview sound", systemImage: "play.circle")
                    }
                    .disabled(!store.soundEnabled)
                } header: {
                    Text("Sound")
                } footer: {
                    Text("Plays once while the app is open when a task turns from running to finished; with the mute switch on it only vibrates.")
                }
                Section {
                    Button("Clear cloud history", role: .destructive) { confirmClearHistory = true }
                    Button("Unpair this phone", role: .destructive) { confirmUnpair = true }
                } header: {
                    Text("Data & pairing")
                } footer: {
                    Text("Cloud records are kept for 7 days. Clearing history does not delete events still queued on a Mac; swipe a computer row to revoke one.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: phase) { await updateNotificationStatus() }
            .confirmationDialog("Clear the 7-day task history? This cannot be undone.", isPresented: $confirmClearHistory, titleVisibility: .visible) {
                Button("Clear cloud history", role: .destructive) { Task { await store.clearCloudHistory() } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("This phone stops working immediately after unpairing.", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { Task { await store.unpair(); if !store.paired { dismiss() } } }
                Button("Cancel", role: .cancel) {}
            }
        }
        .tint(Palette.accent)
        .presentationDragIndicator(.visible)
    }

    private func updateNotificationStatus() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

/// Another Mac joins without ever seeing the bootstrap secret: this phone issues a one-time
/// code and shows the exact command to paste there.
private struct AddComputerSheet: View {
    @ObservedObject var store: MonitorStore
    @Environment(\.dismiss) private var dismiss
    @State private var code: String?
    @State private var expiresAt: Date?
    @State private var failure: String?
    @State private var loading = false
    @State private var copied = false

    private static let installer = "https://github.com/wangchangwei/agent-notification/releases/latest/download/install.sh"

    private var command: String {
        "curl -fsSL " + Self.installer + " | sh -s -- --url " + store.bridge + " --code " + (code ?? "000000")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let code {
                        Text(spaced(code))
                            .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                            .monospacedDigit()
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                            .accessibilityLabel("Install code " + code.map(String.init).joined(separator: " "))
                        if let expiresAt {
                            LabeledContent("Valid until", value: expiresAt.formatted(date: .omitted, time: .shortened))
                                .font(.footnote)
                        }
                    } else if loading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Creating a code…").foregroundStyle(.secondary)
                        }
                    }
                    if let failure {
                        Text(failure).font(.footnote).foregroundStyle(Palette.waiting)
                        Button("Try again") { Task { await load() } }
                    }
                } header: {
                    Text("One-time code")
                } footer: {
                    Text("Works once and expires in 10 minutes. It only authorises adding a Mac to this account.")
                }
                Section {
                    Text(command)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        UIPasteboard.general.string = command
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy command", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(code == nil)
                } header: {
                    Text("Run this in Terminal on the new Mac")
                } footer: {
                    Text("It installs the probe and registers that Mac to this account. Start it there with agent-monitor run.")
                }
                Section {
                    Button("New code") { Task { await load() } }.disabled(loading)
                } footer: {
                    Text("Each code is single use, so ask for one per Mac.")
                }
            }
            .navigationTitle("Add a computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { if code == nil { await load() } }
        }
        .tint(Palette.accent)
        .presentationDragIndicator(.visible)
    }

    private func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let middle = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex..<middle]) \(code[middle...])"
    }

    private func load() async {
        loading = true; failure = nil; copied = false
        defer { loading = false }
        do {
            let ack = try await store.createInstallCode()
            code = ack.code
            expiresAt = Date().addingTimeInterval(TimeInterval(ack.expiresInSeconds ?? 600))
        } catch {
            code = nil; expiresAt = nil
            failure = error.localizedDescription
        }
    }
}