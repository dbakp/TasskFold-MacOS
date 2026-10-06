import Foundation

/// A bounded, credential-free clock projection shared by the app and its widget extension.
public struct FocusWidgetClock: Codable, Equatable, Sendable {
    public var sessionID: String
    public var taskID: String
    public var durationSeconds: Int
    public var elapsedMilliseconds: Int64
    public var startedAt: Int64
    public var changedAt: Int64
    public var runningSince: Int64?
    public var status: String
    public var taskState: String
    public var title: String?
    public init(sessionID: String, taskID: String, durationSeconds: Int, elapsedMilliseconds: Int64, startedAt: Int64, changedAt: Int64, runningSince: Int64?, status: String, taskState: String, title: String?) {
        self.sessionID = sessionID; self.taskID = taskID; self.durationSeconds = durationSeconds
        self.elapsedMilliseconds = elapsedMilliseconds; self.startedAt = startedAt; self.changedAt = changedAt
        self.runningSince = runningSince; self.status = status; self.taskState = taskState; self.title = title
    }
    public var valid: Bool {
        guard UUID(uuidString: sessionID) != nil, UUID(uuidString: taskID) != nil,
              (60...10800).contains(durationSeconds), durationSeconds % 60 == 0,
              (0...Int64(durationSeconds * 1000)).contains(elapsedMilliseconds),
              (0...4_133_980_800_000).contains(startedAt), (startedAt...4_133_980_800_000).contains(changedAt),
              ["running", "paused", "stopped"].contains(status), ["open", "completed", "unavailable"].contains(taskState),
              title.map({ $0.count <= 160 && $0.utf8.count <= 1000 }) ?? true,
              taskState != "unavailable" || title == nil else { return false }
        return status == "running" ? runningSince.map { (startedAt...changedAt).contains($0) } ?? false : runningSince == nil
    }
    public var endDate: Date? {
        guard valid, status == "running", let runningSince else { return nil }
        return Date(timeIntervalSince1970: Double(runningSince + Int64(durationSeconds) * 1000 - elapsedMilliseconds) / 1000)
    }
    /// The full interval retains already accumulated progress when resuming.
    public var timerInterval: ClosedRange<Date>? {
        guard let end = endDate else { return nil }
        return end.addingTimeInterval(-Double(durationSeconds))...end
    }
    public func elapsed(at date: Date) -> Int64 {
        guard valid else { return 0 }
        let limit = Int64(durationSeconds * 1000)
        let time = (date.timeIntervalSince1970 * 1000).rounded(.down)
        guard status == "running", let runningSince, time.isFinite, time >= 0, time <= 4_133_980_800_000 else { return elapsedMilliseconds }
        return min(limit, elapsedMilliseconds + max(0, Int64(time) - runningSince))
    }
    public func remaining(at date: Date) -> TimeInterval { guard valid else { return 0 }; return Double(Int64(durationSeconds * 1000) - elapsed(at: date)) / 1000 }
    public func clock(at date: Date, spent: Bool = false) -> String {
        let seconds = spent ? Int(elapsed(at: date) / 1000) : Int(ceil(remaining(at: date)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

public enum FocusWidgetStatus: Equatable, Sendable { case refresh, idle, running, paused, ended, finished, conflict, unavailable }
public struct FocusWidgetSnapshot: Codable, Equatable, Sendable {
    public var version = 1
    public var account: String
    public var clock: FocusWidgetClock?
    public var conflict: Bool
    public init(account: String, clock: FocusWidgetClock? = nil, conflict: Bool = false) { self.account = account; self.clock = clock; self.conflict = conflict }
    public func valid(for owner: String) -> Bool { version == 1 && !owner.isEmpty && account == owner && account.utf8.count <= 256 && (clock?.valid ?? true) }
    public func status(at date: Date, owner: String, updated: TimeInterval) -> FocusWidgetStatus {
        guard valid(for: owner), updated.isFinite, updated > 0, date.timeIntervalSinceReferenceDate >= updated - 300, date.timeIntervalSinceReferenceDate < updated + 86_400 else { return .refresh }
        if conflict { return .conflict }
        guard let clock else { return .idle }
        if clock.taskState == "unavailable" || clock.taskState == "completed" { return .unavailable }
        if clock.status == "stopped" { return .ended }
        if clock.remaining(at: date) == 0 { return .finished }
        return clock.status == "paused" ? .paused : .running
    }
    public func timelineDates(from now: Date, updated: TimeInterval) -> [Date] {
        guard valid(for: account), updated.isFinite, updated > 0 else { return [now] }
        var dates = [now]
        let expiry = Date(timeIntervalSinceReferenceDate: updated + 86_400)
        if expiry > now { dates.append(expiry) }
        if let end = clock?.endDate, end > now, end < expiry { dates.append(end) }
        return Array(Set(dates)).sorted()
    }
}

/// Opening a widget only presents the newest session; it never executes a stale timer command.
public struct FocusSessionLink: Equatable, Sendable {
    public var account: String
    public init(account: String) { self.account = account }
    public var url: URL {
        var parts = URLComponents(); parts.scheme = "taskfold"; parts.host = "focus"
        parts.queryItems = [URLQueryItem(name: "account", value: account)]
        return parts.url!
    }
    public static func parse(_ url: URL) -> Self? {
        guard url.scheme == "taskfold", url.host == "focus", url.fragment == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.percentEncodedPath.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil,
              let query = parts.queryItems, query.count == 1, query[0].name == "account",
              let account = query[0].value, !account.isEmpty, account.utf8.count <= 256 else { return nil }
        return Self(account: account)
    }
}
