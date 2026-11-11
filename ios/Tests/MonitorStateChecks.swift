import Foundation

@main enum MonitorStateChecks {
    static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            count += 1
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        func event(_ status: String, type: String = "tool_finished", device: String = "mac-a", time: Double = 100, parent: String? = nil, title: String? = nil, brand: String? = nil) throws -> MonitorEvent {
            var payload: [String: Any] = [
                "event_id": "event-\(device)-\(time)", "task_id": "same-task",
                "device_id": device, "event_type": type, "status": status,
                "occurred_at": time, "summary": "工具执行完毕", "tool_name": "terminal"
            ]
            if let parent { payload["parent_task_id"] = parent }
            if let title { payload["title"] = title }
            if let brand { payload["brand"] = brand }
            return try decoder.decode(MonitorEvent.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        let toolReturned = try event("running")
        check(toolReturned.taskStatus == .running, "A returned tool must not mark the task completed")
        check(toolReturned.activity == "terminal 已返回", "The row must keep the tool name after it returns")
        check(toolReturned.durationMs == nil, "Older snapshots without duration must still decode")
        check(tryStatus("incomplete", "interrupted", decoder) == .incomplete, "An incomplete turn must be distinguished from an explicit interruption")
        check(tryStatus("interrupted", "interrupted", decoder) == .interrupted, "Explicit interruption must remain an interruption")
        for status in ["running", "waiting", "completed", "failed", "interrupted"] {
            let known = try event(status)
            check(known.taskStatus.rawValue == status, "Known status must be preserved: \(status)")
        }
        let unknown = try event("future-status")
        check(unknown.taskStatus == .unknown, "Unrecognized status must be unknown")
        check(!unknown.taskStatus.isActive, "Unknown must not inflate active task counts")
        check(MonitorTaskStatus.completed.title == "本轮结束", "Completed must not imply accepted results")
        check(MonitorTaskStatus.waiting.isActive, "Waiting tasks are still active")
        check(!MonitorTaskStatus.failed.isActive, "Failed tasks are no longer active")
        check(toolReturned.agentKind == "主 agent", "A task without a parent is the main agent")
        let child = try event("running", parent: "11111111-2222-3333-4444-555555555555")
        check(child.agentKind == "子 agent", "A task with a parent is a sub-agent")
        let titled = try event("running", title: "优化 iOS 页面")
        check(titled.displayName == "优化 iOS 页面", "A scrubbed request title is the row title")
        check(!toolReturned.displayName.contains("same-task"), "A row never falls back to a raw task id")
        check(toolReturned.displayName.hasPrefix("未命名 · "), "Without a title the row shows a neutral label")
        check(child.displayName.hasPrefix("未命名 · "), "A child task uses the same neutral fallback")
        let hermesTask = try event("running", brand: "hermes")
        let codexTask = try event("running", brand: "codex")
        let piTask = try event("running", brand: "pi")
        let claudeTask = try event("running", brand: "claude-code")
        let qwenTask = try event("running", brand: "qwen")
        check(hermesTask.brandLabel == "Hermes", "The row labels the agent brand, not the hierarchy")
        check(codexTask.brandLabel == "Codex", "Codex tasks are labelled Codex")
        check(piTask.brandLabel == "Pi", "Pi tasks are labelled Pi")
        check(claudeTask.brandLabel == "Claude Code", "Known multi-word brands keep their display name")
        check(qwenTask.brandLabel == "Qwen", "An unknown slug is capitalised")
        check(toolReturned.brandLabel == "Agent", "Events from before brands existed fall back to Agent")

        let older = try event("running", time: 99)
        let ended = try event("completed", type: "completed", time: 101)
        let otherMac = try event("waiting", type: "waiting", device: "mac-b", time: 102)
        let latest = Snapshot(devices: [], events: [ended, otherMac, older, toolReturned]).latestTasks
        check(latest.count == 2, "Identical task IDs on different Macs must not collide")
        check(latest.first?.deviceId == "mac-b", "Latest tasks must sort by most recent event")
        check(latest.first { $0.deviceId == "mac-a" }?.taskStatus == .completed, "Out-of-order history must not overwrite the newest task status")

        let device = MonitorDevice(deviceId: "mac-a", lastSeen: 1_000, online: true)
        check(device.isOnline(at: Date(timeIntervalSince1970: 1_120)), "A heartbeat at the TTL boundary is current")
        check(!device.isOnline(at: Date(timeIntervalSince1970: 1_121)), "Cached online state must expire locally without a new snapshot")
        check(!MonitorDevice(deviceId: "mac-a", lastSeen: 0, online: true).isOnline(at: Date(timeIntervalSince1970: 10)), "Missing heartbeat must not appear online")
        check(!MonitorDevice(deviceId: "mac-a", lastSeen: 1_000, online: false).isOnline(at: Date(timeIntervalSince1970: 1_001)), "A server-side offline flag must not be overridden")

        let snapshot = try decoder.decode(Snapshot.self, from: Data("{\"server_time\":1100,\"devices\":[],\"events\":[]}".utf8))
        check(snapshot.serverTime == 1_100, "Snapshot must decode the server clock")
        let legacy = try decoder.decode(Snapshot.self, from: Data("{\"devices\":[],\"events\":[]}".utf8))
        check(legacy.serverTime == nil, "Snapshots without a server clock must remain compatible")
        let fastPhone = SnapshotClock(serverTime: 1_100, receivedAt: Date(timeIntervalSince1970: 4_700))
        let slowPhone = SnapshotClock(serverTime: 1_100, receivedAt: Date(timeIntervalSince1970: -2_500))
        check(device.isOnline(at: fastPhone.serverDate(at: Date(timeIntervalSince1970: 4_705))), "A phone clock one hour fast must not falsely disconnect an online Mac")
        check(device.isOnline(at: slowPhone.serverDate(at: Date(timeIntervalSince1970: -2_495))), "A phone clock one hour slow must preserve the server heartbeat age")
        check(!device.isOnline(at: fastPhone.serverDate(at: Date(timeIntervalSince1970: 4_721))), "Heartbeats must expire relative to the calibrated clock")
        check(fastPhone.serverDate(at: Date(timeIntervalSince1970: 4_699)).timeIntervalSince1970 == 1_100, "The estimated server clock must not predate the received snapshot")

        var watcher = StatusTransitionWatcher()
        let running = try event("running", time: 200)
        let finished = try event("completed", type: "completed", time: 210)
        check(watcher.completed(among: [running], freshAfter: 0).isEmpty, "First sight of a running task must not ring")
        check(watcher.completed(among: [finished], freshAfter: 0).count == 1, "Running to completed must ring exactly once")
        check(watcher.completed(among: [finished], freshAfter: 0).isEmpty, "A repeated snapshot must not ring again")
        check(watcher.completed(among: [running], freshAfter: 0).isEmpty, "A late older event must not regress or ring")
        var lateWatcher = StatusTransitionWatcher()
        _ = lateWatcher.completed(among: [running], freshAfter: 0)
        check(lateWatcher.completed(among: [finished], freshAfter: 1_000).isEmpty, "A completion older than the freshness window must stay silent")
        var waitingWatcher = StatusTransitionWatcher()
        let waiting = try event("waiting", type: "waiting", time: 300)
        let waitingFinished = try event("completed", type: "completed", time: 310)
        _ = waitingWatcher.completed(among: [waiting], freshAfter: 0)
        check(waitingWatcher.completed(among: [waitingFinished], freshAfter: 0).count == 1, "A task waiting for a human must ring when it finishes")
        var failedWatcher = StatusTransitionWatcher()
        let failed = try event("failed", type: "failed", time: 220)
        _ = failedWatcher.completed(among: [running], freshAfter: 0)
        check(failedWatcher.completed(among: [failed], freshAfter: 0).isEmpty, "A failure is not a completion and must stay silent")
        let now = Date(timeIntervalSince1970: 1_000)
        check(CompletionPolicy.shouldRing(finished: 1, enabled: true, sceneActive: true, lastRing: nil, now: now), "A fresh completion rings")
        check(!CompletionPolicy.shouldRing(finished: 1, enabled: false, sceneActive: true, lastRing: nil, now: now), "The sound switch must silence it")
        check(!CompletionPolicy.shouldRing(finished: 1, enabled: true, sceneActive: false, lastRing: nil, now: now), "A backgrounded app must not ring")
        check(!CompletionPolicy.shouldRing(finished: 0, enabled: true, sceneActive: true, lastRing: nil, now: now), "No transition means no sound")
        check(!CompletionPolicy.shouldRing(finished: 2, enabled: true, sceneActive: true, lastRing: now.addingTimeInterval(-2), now: now), "A burst within three seconds must not repeat")
        check(CompletionPolicy.shouldRing(finished: 2, enabled: true, sceneActive: true, lastRing: now.addingTimeInterval(-4), now: now), "Separate completions minutes apart each ring")
        print("Monitor state checks passed: \(count)")
    }

    private static func tryStatus(_ type: String, _ status: String, _ decoder: JSONDecoder) -> MonitorTaskStatus {
        let payload = """
        {"event_id":"e","task_id":"t","device_id":"d","event_type":"\(type)","status":"\(status)","occurred_at":100,"summary":"状态"}
        """
        return try! decoder.decode(MonitorEvent.self, from: Data(payload.utf8)).taskStatus
    }
}
