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
                            .accessibilityLabel("打开设置")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let error = store.error {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.waiting)
                        Text(error).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                        Button { store.error = nil } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("关闭提示")
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
            Text(stale ? "过期 · \(status.title)" : status.title)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(stale ? Color.secondary : status.tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background((stale ? Color.secondary : status.tint).opacity(0.12), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(stale ? "上次状态：\(status.title)，当前已过期" : status.title)
    }
}

private struct AgeLabel: View {
    let date: Date
    let now: Date
    var body: some View { Text(Self.text(date: date, now: now)).monospacedDigit() }

    static func text(date: Date, now: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 5 { return "刚刚" }
        if seconds < 60 { return "\(seconds) 秒前" }
        if seconds < 3_600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86_400 { return "\(seconds / 3_600) 小时前" }
        return "\(seconds / 86_400) 天前"
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
        if current { return "同步正常" }
        if store.lastSync == nil && store.syncError == nil { return "正在连接" }
        return "同步异常 · 显示上次记录"
    }
    private var detail: String {
        guard current else { return "等待下一次同步" }
        return "\(running) 执行中 · \(waiting) 待处理 · \(online) 台在线"
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
    case all = "全部", running = "执行中", waiting = "待处理", finished = "已结束"
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
                        placeholder("正在加载电脑状态…")
                    } else if store.devices.isEmpty {
                        placeholder("还没有连接电脑。在 Mac 上运行 agent-monitor pair 完成绑定。")
                    }
                    ForEach(store.devices.sorted { $0.deviceId < $1.deviceId }) { device in
                        DeviceRow(
                            device: device,
                            activeTasks: tasks.filter { $0.deviceId == device.deviceId && $0.taskStatus.isActive }.count,
                            now: store.serverDate(at: now),
                            snapshotCurrent: current
                        )
                        .swipeActions {
                            Button("撤销绑定", role: .destructive) { Task { await store.revoke(device) } }
                        }
                    }
                } header: {
                    sectionHeader("电脑", trailing: "\(store.devices.count) 台")
                } footer: {
                    Text("电脑失联只说明心跳过期，不代表任务失败。")
                }
                Section {
                    if store.lastSync == nil && store.syncError == nil {
                        placeholder("正在加载任务…")
                    } else if visible.isEmpty {
                        placeholder(tasks.isEmpty ? "还没有记录。Hermes 开始执行后会出现在这里。" : "没有\(filter.rawValue)的任务。")
                    }
                    ForEach(visible, id: \.taskKey) { event in
                        NavigationLink {
                            TaskDetail(store: store, taskId: event.taskId, deviceId: event.deviceId)
                        } label: {
                            TaskRow(event: event, stale: store.isStale(event, at: now))
                        }
                    }
                } header: {
                    sectionHeader("最近", trailing: filter == .all ? "\(visible.count) 项" : "\(filter.rawValue) · \(visible.count)")
                } footer: {
                    Text("保留 7 天。本轮结束表示这一轮输出完成，结果仍需验收。")
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await store.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("筛选", selection: $filter) {
                            ForEach(TaskFilter.allCases) { item in
                                Label(item.rawValue, systemImage: item.symbol).tag(item)
                            }
                        }
                        Divider()
                        Button { Task { await store.refresh() } } label: {
                            Label("立即刷新", systemImage: "arrow.clockwise")
                        }
                        .disabled(store.isRefreshing)
                    } label: {
                        Image(systemName: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("筛选任务")
                }
            }
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
        if !snapshotCurrent { return online ? "连接中" : "上次心跳已过期" }
        if !online { return "失联 · 状态已过期" }
        return activeTasks == 0 ? "在线 · 空闲" : "在线 · \(activeTasks) 项进行中"
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
                            Label(deviceOnline ? "同步中断，以下是上次记录。" : "电脑失联，执行状态已过期。",
                                  systemImage: "clock.badge.exclamationmark")
                                .font(.footnote)
                                .foregroundStyle(Palette.waiting)
                        }
                    }
                    Section {
                        LabeledContent("Agent", value: event.brandLabel)
                        LabeledContent("类型", value: event.agentKind)
                        LabeledContent("电脑", value: "Mac · \(deviceId.suffix(6))")
                        LabeledContent("最后事件", value: event.date.formatted(date: .abbreviated, time: .standard))
                        if let parent = event.parentTaskId {
                            LabeledContent("父任务", value: String(parent.suffix(6)))
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
                                            Text("用时 \((Double(duration) / 1_000).formatted(.number.precision(.fractionLength(0...2)))) 秒")
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
                        Text("事件记录 · \(history.count)").textCase(nil)
                    } footer: {
                        Text("按最近时间排序。本轮结束不代表结果已验收。")
                    }
                } else {
                    ContentUnavailableView("没有这条记录", systemImage: "clock", description: Text("记录可能已清空或超过 7 天保留期。"))
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await store.refresh() }
            .navigationTitle(history.first?.displayName ?? "详情")
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
                    Text("在手机上查看 Hermes 的执行状态").font(.headline)
                    Text("绑定后，任务开始、等待人工处理、本轮结束和失败都会同步到这里。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section {
                TextField("HTTPS 服务地址", text: $bridge)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("服务地址")
                HStack {
                    TextField("一次性配对码", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { scanning = true } label: { Image(systemName: "qrcode.viewfinder") }
                        .accessibilityLabel("扫描配对二维码").frame(minWidth: 44, minHeight: 44)
                }
                Button {
                    Task { await store.pair(rawCode: code, rawBridge: bridge) }
                } label: {
                    HStack(spacing: 8) {
                        if store.isPairing { ProgressView().controlSize(.small) }
                        Text(store.isPairing ? "正在绑定…" : "绑定 Mac")
                    }
                    .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isPairing)
            } header: {
                Text("绑定电脑")
            } footer: {
                Text("在 Mac 运行 agent-monitor pair 生成二维码。配对码 5 分钟内有效，只能使用一次。")
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
        case .authorized, .provisional, .ephemeral: "已允许"
        case .denied: "未允许"
        case .notDetermined: "未开启"
        @unknown default: "未知"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("服务", value: URL(string: store.bridge)?.host ?? store.bridge)
                    LabeledContent("绑定电脑", value: "\(store.devices.count) 台")
                    LabeledContent("最近同步", value: store.lastSync?.formatted(date: .omitted, time: .standard) ?? "尚未同步")
                    if let error = store.error {
                        Text(error).font(.footnote).foregroundStyle(Palette.waiting)
                    }
                } header: {
                    Text("连接")
                }
                Section {
                    LabeledContent("通知权限", value: notificationTitle)
                    Button(notificationStatus == .notDetermined ? "开启任务通知" : "管理通知设置") {
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
                    Text("任务通知")
                } footer: {
                    Text("完成、失败、等待处理时提醒。锁屏只显示事件类型，打开 App 可同步最新状态。")
                }
                Section {
                    Toggle(isOn: Binding(get: { store.soundEnabled }, set: { store.setSoundEnabled($0) })) {
                        Label("本轮结束提示音", systemImage: "speaker.wave.2")
                    }
                    Button { CompletionFeedback.play() } label: {
                        Label("试听提示音", systemImage: "play.circle")
                    }
                    .disabled(!store.soundEnabled)
                } header: {
                    Text("提示音")
                } footer: {
                    Text("仅在 App 打开时、任务从执行中转为本轮结束时响一次；静音键开启时只震动。")
                }
                Section {
                    Button("清空云端历史", role: .destructive) { confirmClearHistory = true }
                    Button("解除此手机绑定", role: .destructive) { confirmUnpair = true }
                } header: {
                    Text("数据与绑定")
                } footer: {
                    Text("云端保留 7 天。清空历史不会删除 Mac 上的本地事件；电脑列表左滑可撤销单台电脑。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task(id: phase) { await updateNotificationStatus() }
            .confirmationDialog("清空 7 天任务历史？此操作无法撤销。", isPresented: $confirmClearHistory, titleVisibility: .visible) {
                Button("清空云端历史", role: .destructive) { Task { await store.clearCloudHistory() } }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("解除后此手机凭证立即失效。", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("解除绑定", role: .destructive) { Task { await store.unpair(); if !store.paired { dismiss() } } }
                Button("取消", role: .cancel) {}
            }
        }
        .tint(Palette.accent)
        .presentationDragIndicator(.visible)
    }

    private func updateNotificationStatus() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}