import SwiftUI

private extension MonitorTaskStatus {
    var tint: Color {
        switch self {
        case .running: .green
        case .waiting: .orange
        case .failed: .red
        case .completed, .interrupted, .incomplete, .unknown: .secondary
        }
    }
}

private struct TaskRoute: Hashable {
    let taskId: String
    let deviceId: String
}

/// The watch shows one thing well: what is running right now, and how each task ended.
struct WatchRoot: View {
    @ObservedObject var store: WatchStore
    @State private var path: [TaskRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.paired { taskList } else { pairingPrompt }
            }
            .navigationTitle("Agent")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: TaskRoute.self) { route in
                WatchTaskDetail(store: store, taskId: route.taskId, deviceId: route.deviceId)
            }
            .containerBackground(.fill.tertiary, for: .navigation)
            #if DEBUG
            .task {
                // Debug-only: lets a simulator run open the detail screen for a screenshot.
                guard ProcessInfo.processInfo.environment["MONITOR_DEBUG_DETAIL"] == "1" else { return }
                for _ in 0..<20 {
                    if path.isEmpty, let first = store.latestTasks.first {
                        path = [TaskRoute(taskId: first.taskId, deviceId: first.deviceId)]
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            #endif
        }
    }

    private var pairingPrompt: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("先在 iPhone 上完成绑定")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("打开 iPhone 上的 Agent Monitor，配对后手表会自动收到凭证。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("从 iPhone 同步") { store.requestFromPhone() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 4)
        }
    }

    private var taskList: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let now = context.date
            let tasks = store.latestTasks
            let running = tasks.filter { $0.taskStatus == .running && !store.isStale($0, at: now) }.count
            let waiting = tasks.filter { $0.taskStatus == .waiting && !store.isStale($0, at: now) }.count
            List {
                Section {
                    summary(running: running, waiting: waiting, now: now)
                        .listRowBackground(Color.clear)
                    if tasks.isEmpty {
                        Text(store.syncError ?? "还没有任务记录。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(tasks, id: \.taskKey) { event in
                        NavigationLink(value: TaskRoute(taskId: event.taskId, deviceId: event.deviceId)) {
                            WatchTaskRow(event: event, stale: store.isStale(event, at: now))
                        }
                    }
                }
            }
            .listStyle(.carousel)
            .refreshable { await store.refresh() }
        }
    }

    private func summary(running: Int, waiting: Int, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(store.snapshotIsCurrent(at: now) ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(store.snapshotIsCurrent(at: now) ? "同步正常" : "显示上次记录")
                    .font(.footnote.weight(.medium))
                Spacer(minLength: 4)
                if let lastSync = store.lastSync {
                    Text(lastSync, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text("\(running) 执行中 · \(waiting) 待处理")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WatchTaskRow: View {
    let event: MonitorEvent
    var stale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(event.displayName)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 4) {
                Image(systemName: event.brandSymbol).font(.caption2).foregroundStyle(.secondary)
                Text(event.brandLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(stale ? "过期" : event.taskStatus.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(stale ? .secondary : event.taskStatus.tint)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.displayName)，\(event.brandLabel)，\(stale ? "已过期" : event.taskStatus.title)")
    }
}

private struct WatchTaskDetail: View {
    @ObservedObject var store: WatchStore
    let taskId: String
    let deviceId: String

    private var history: [MonitorEvent] {
        store.events.filter { $0.taskId == taskId && $0.deviceId == deviceId }.sorted { $0.occurredAt > $1.occurredAt }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let now = context.date
            List {
                if let event = history.first {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(event.displayName).font(.headline)
                            HStack(spacing: 6) {
                                Text(event.brandLabel).font(.footnote).foregroundStyle(.secondary)
                                Text("·").foregroundStyle(.tertiary)
                                Text(event.taskStatus.title)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(store.isStale(event, at: now) ? .secondary : event.taskStatus.tint)
                            }
                            Text(event.date.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        ForEach(history.prefix(4)) { item in
                            HStack(spacing: 6) {
                                Image(systemName: item.taskStatus.symbol)
                                    .font(.caption2)
                                    .foregroundStyle(item.taskStatus.tint)
                                Text(item.activity).font(.footnote).lineLimit(1)
                                Spacer(minLength: 2)
                                Text(item.date, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        Text("本轮结束不代表结果已验收。")
                    }
                } else {
                    Text("记录不可用").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .listStyle(.carousel)
        }
        .navigationTitle("详情")
        .containerBackground(.fill.tertiary, for: .navigation)
    }
}