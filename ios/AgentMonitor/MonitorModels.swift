import Foundation

struct Snapshot: Decodable {
    let devices: [MonitorDevice]
    let events: [MonitorEvent]
    let serverTime: TimeInterval?

    init(devices: [MonitorDevice], events: [MonitorEvent], serverTime: TimeInterval? = nil) {
        self.devices = devices
        self.events = events
        self.serverTime = serverTime
    }

    var latestTasks: [MonitorEvent] {
        var latest: [String: MonitorEvent] = [:]
        for event in events {
            if let previous = latest[event.taskKey], previous.occurredAt > event.occurredAt { continue }
            latest[event.taskKey] = event
        }
        return latest.values.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
            return $0.taskKey < $1.taskKey
        }
    }
}

struct SnapshotClock {
    let serverTime: TimeInterval
    let receivedAt: Date

    func serverDate(at localDate: Date) -> Date {
        Date(timeIntervalSince1970: serverTime + max(0, localDate.timeIntervalSince(receivedAt)))
    }
}

/// Remembers the newest status per task so a move into completion is reported exactly once.
struct StatusTransitionWatcher {
    private var seen: [String: (status: MonitorTaskStatus, occurredAt: TimeInterval)] = [:]

    mutating func completed(among tasks: [MonitorEvent], freshAfter: TimeInterval) -> [MonitorEvent] {
        var finished: [MonitorEvent] = []
        for task in tasks {
            let previous = seen[task.taskKey]
            // An out-of-order snapshot must never regress the known status.
            if let previous, task.occurredAt <= previous.occurredAt { continue }
            seen[task.taskKey] = (task.taskStatus, task.occurredAt)
            guard let previous, previous.status.isActive, task.taskStatus == .completed else { continue }
            guard task.occurredAt >= freshAfter else { continue }
            finished.append(task)
        }
        return finished
    }

    mutating func reset() { seen.removeAll() }
}

enum CompletionPolicy {
    /// One signal per completion burst, only while the app is visible and the user left sound on.
    static func shouldRing(finished: Int, enabled: Bool, sceneActive: Bool, lastRing: Date?, now: Date) -> Bool {
        guard finished > 0, enabled, sceneActive else { return false }
        if let lastRing, now.timeIntervalSince(lastRing) < 3 { return false }
        return true
    }
}

struct MonitorDevice: Codable, Identifiable {
    let deviceId: String
    let lastSeen: Int
    let online: Bool
    /// Set from the phone; the Mac's own setup name is the fallback.
    let deviceName: String?
    var id: String { deviceId }
    init(deviceId: String, lastSeen: Int, online: Bool, deviceName: String? = nil) {
        self.deviceId = deviceId
        self.lastSeen = lastSeen
        self.online = online
        self.deviceName = deviceName
    }
    var displayName: String {
        if let deviceName, !deviceName.isEmpty { return deviceName }
        return "Mac · \(deviceId.suffix(6))"
    }

    func isOnline(at date: Date) -> Bool {
        online && lastSeen > 0 && date.timeIntervalSince1970 - TimeInterval(lastSeen) <= 120
    }
}

struct MonitorEvent: Codable, Identifiable {
    let eventId: String
    let taskId: String
    let parentTaskId: String?
    let deviceId: String
    let eventType: String
    let status: String
    let toolName: String?
    let durationMs: Int?
    let occurredAt: TimeInterval
    let summary: String
    let title: String?
    let brand: String?
    var id: String { eventId }
    var taskKey: String { "\(deviceId)/\(taskId)" }
    var date: Date { Date(timeIntervalSince1970: occurredAt) }
    var displayName: String {
        if let title, !title.isEmpty { return title }
        // No scrubbed request title (older events, or a turn whose prompt was withheld):
        // name the row by the harness instead of an empty placeholder.
        return "\(brandLabel) · \(Self.clock.string(from: date))"
    }
    var agentKind: String { parentTaskId == nil ? "Main agent" : "Sub-agent" }
    var brandLabel: String {
        guard let brand, !brand.isEmpty else { return "Agent" }
        switch brand {
        case "hermes": return "Hermes"
        case "codex": return "Codex"
        case "pi": return "Pi"
        case "claude", "claude-code": return "Claude Code"
        case "gemini": return "Gemini"
        default: return brand.prefix(1).uppercased() + brand.dropFirst()
        }
    }
    /// One glyph per harness, so a row is identifiable before the label is read.
    var brandSymbol: String {
        switch brand {
        case "hermes": "sparkles"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "pi": "function"
        case "claude", "claude-code": "asterisk"
        case "gemini": "diamond"
        default: "circle.grid.2x2"
        }
    }
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    var taskStatus: MonitorTaskStatus {
        if eventType == "incomplete" { return .incomplete }
        return MonitorTaskStatus(rawValue: status) ?? .unknown
    }
    var activity: String {
        if let toolName, eventType == "tool_started" { return "Called \(toolName)" }
        if let toolName, eventType == "tool_finished" { return "\(toolName) returned" }
        return summary
    }
}

enum MonitorTaskStatus: String, CaseIterable {
    case running, waiting, completed, failed, interrupted, incomplete, unknown

    var title: String {
        switch self {
        case .running: "Running"
        case .waiting: "Waiting"
        case .completed: "Finished"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        case .incomplete: "Incomplete"
        case .unknown: "Unknown"
        }
    }
    var symbol: String {
        switch self {
        case .running: "circle.dotted"
        case .waiting: "hand.raised.fill"
        case .completed: "checkmark.circle"
        case .failed: "xmark.circle.fill"
        case .interrupted: "pause.circle"
        case .incomplete, .unknown: "questionmark.circle"
        }
    }
    var isActive: Bool { self == .running || self == .waiting }
    var priority: Int {
        switch self {
        case .waiting: 0
        case .running: 1
        case .failed: 2
        case .interrupted, .incomplete, .unknown: 3
        case .completed: 4
        }
    }
}
