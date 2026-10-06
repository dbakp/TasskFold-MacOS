import Foundation

struct TaskActivity: Equatable, Identifiable, Sendable {
    static let table = "task_activity"
    static let epochTable = "task_activity_epoch"
    static let stateKeys: Set<String> = ["project_id", "section_id", "completed", "completed_at", "due_date", "due_time", "scheduled_at", "time_zone", "deadline_date", "recurrence_parent_id"]
    enum Kind: String, CaseIterable, Sendable {
        case created, completed, reopened, completion_time, rescheduled, moved, deleted
        var title: String {
            switch self { case .created: return "Created"; case .completed: return "Completed"; case .reopened: return "Reopened"; case .completion_time: return "Completion time updated"; case .rescheduled: return "Plan changed"; case .moved: return "Moved"; case .deleted: return "Removed" }
        }
    }
    var id: String
    var sequence: Int64
    var owner: String
    var taskID: String
    var actor: String?
    var recordedAt: Date
    var effectiveAt: Date
    var completionVersion: Int64
    var kinds: [Kind]
    var before: [String: JSON]
    var after: [String: JSON]
    init?(row: Record) {
        guard UUID(uuidString: row.id) != nil, let sequence = Self.integer(row["sequence"]), sequence > 0,
              Self.validID(row.string("user_id")), Self.validID(row.string("task_id")),
              row["actor_id"] == .null || Self.validID(row.string("actor_id")),
              let recorded = TaskPlanning.instant(row.string("recorded_at")), let effective = TaskPlanning.instant(row.string("effective_at")),
              let version = Self.integer(row["completion_version"]),
              case .array(let values) = row["kinds"], !values.isEmpty, values.count <= Kind.allCases.count,
              values.allSatisfy({ if case .string(let value) = $0 { return Kind(rawValue: value) != nil }; return false }),
              Set(values.map(\.text)).count == values.count,
              case .object(let before) = row["before_state"], case .object(let after) = row["after_state"],
              Self.validState(before), Self.validState(after),
              Self.changes(before: before, after: after).map(\.rawValue) == values.map(\.text) else { return nil }
        id = row.id.lowercased(); self.sequence = sequence; owner = row.string("user_id"); taskID = row.string("task_id").lowercased()
        actor = row["actor_id"] == .null ? nil : row.string("actor_id")
        recordedAt = recorded; effectiveAt = effective; completionVersion = version; kinds = values.compactMap { Kind(rawValue: $0.text) }
        self.before = before; self.after = after
    }
    static func validID(_ text: String) -> Bool { !text.isEmpty && text.utf8.count <= 256 }
    static func integer(_ value: JSON) -> Int64? {
        guard case .number(let n) = value, n.isFinite, n >= 0, n <= 9_007_199_254_740_991, n.rounded(.down) == n else { return nil }
        return Int64(n)
    }
    static func validState(_ state: [String: JSON]) -> Bool {
        guard state.isEmpty || Set(state.keys) == stateKeys && { if case .bool = state["completed"] { return true }; return false }() else { return false }
        for (key, value) in state {
            if value == .null { continue }
            if key == "completed" { guard case .bool = value else { return false } }
            else { guard case .string(let text) = value, text.utf8.count <= 256 else { return false } }
        }
        for key in ["completed_at", "scheduled_at"] where state[key] != nil && state[key] != .null {
            guard TaskPlanning.instant(state[key]!.text) != nil else { return false }
        }
        for key in ["due_date", "deadline_date"] where state[key] != nil && state[key] != .null {
            let text = state[key]!.text
            guard text.count == 10, Dates.parse(text) != nil else { return false }
        }
        return true
    }
    static func state(_ task: Record?) -> [String: JSON] {
        guard let task else { return [:] }
        var result = Dictionary(uniqueKeysWithValues: stateKeys.map { ($0, task[$0]) })
        result["completed"] = .bool(task.completed)
        // SQL time/timestamp comparisons are semantic, not spelling comparisons.
        for key in ["completed_at", "scheduled_at"] {
            if let instant = TaskPlanning.instant(task.string(key)) { result[key] = .string(stamp(instant)) }
        }
        if !task.string("due_time").isEmpty { result["due_time"] = .string(task.string("due_time").count == 5 ? task.string("due_time") + ":00" : task.string("due_time")) }
        return result
    }
    static func stamp(_ date: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date) }
    static func changes(before: [String: JSON], after: [String: JSON]) -> [Kind] {
        if before.isEmpty { return after.isEmpty ? [] : [.created] }
        if after.isEmpty { return [.deleted] }
        var result: [Kind] = []
        if before["completed"] != after["completed"] { result.append(after["completed"] == .bool(true) ? .completed : .reopened) }
        else if before["completed_at"] != after["completed_at"] { result.append(.completion_time) }
        if before["project_id"] != after["project_id"] || before["section_id"] != after["section_id"] { result.append(.moved) }
        let planned = stateKeys.subtracting(["project_id", "section_id", "completed", "completed_at", "recurrence_parent_id"])
        if planned.contains(where: { before[$0] != after[$0] }) { result.append(.rescheduled) }
        return result
    }
    static func recordLocal(_ change: Mutation, before: Record?, after: Record?, snapshot: inout Snapshot, account: String, now: Date = Date()) {
        guard change.table == "tasks", validID(account), let task = after ?? before, validID(task.id) else { return }
        let b = state(before), a = state(after), kinds = changes(before: b, after: a)
        guard !kinds.isEmpty else { return }
        let existing = snapshot.tables[table] ?? []
        guard !existing.contains(where: { $0.id.lowercased() == change.id.uuidString.lowercased() }) else { return }
        let last = existing.compactMap { integer($0["sequence"]) }.max() ?? 0
        guard last < 9_007_199_254_740_991 else { return }
        let effective = kinds.contains(.completed) ? TaskPlanning.instant(task.string("completed_at")) ?? now : now
        let row = Record(["id": .string(change.id.uuidString.lowercased()), "sequence": .number(Double(last + 1)), "user_id": .string(account), "task_id": .string(task.id), "actor_id": .string(account), "recorded_at": .string(stamp(now)), "effective_at": .string(stamp(effective)), "completion_version": task.fields["completion_version"] ?? .number(0), "kinds": .array(kinds.map { .string($0.rawValue) }), "before_state": .object(b), "after_state": .object(a)])
        guard Self(row: row) != nil else { return }
        snapshot.tables[table, default: []].append(row)
        if snapshot.tables[epochTable]?.isEmpty != false { snapshot.tables[epochTable] = [Record(["id": .string("current"), "recorded_from": .string(stamp(now))])] }
    }
    func involves(project: String) -> Bool { before["project_id"]?.text.lowercased() == project.lowercased() || after["project_id"]?.text.lowercased() == project.lowercased() }
}

struct ProjectPulseReading {
    var total = 0
    var completed = 0
    var completions = 0
    var reopens = 0
    var additions = 0
    var movedIn = 0
    var movedOut = 0
    var events: [TaskActivity] = []
    var malformed = 0
    var start: Date
    var end: Date
    init(project: String, tasks: [Record], activity: [Record], now: Date = Date(), calendar input: Calendar = .current) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = input.timeZone
        end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        start = calendar.date(byAdding: .day, value: -7, to: end)!
        var ids = Set<String>()
        let scope = tasks.filter { $0.string("project_id").lowercased() == project.lowercased() && ids.insert($0.id.lowercased()).inserted }
        total = scope.count; completed = scope.filter(\.completed).count
        var seen = Set<String>(); malformed = 0
        events = activity.compactMap { row in
            guard let event = TaskActivity(row: row) else { malformed += 1; return nil }
            guard seen.insert(event.id).inserted, event.involves(project: project) else { return nil }
            return event
        }.sorted { $0.sequence == $1.sequence ? $0.id > $1.id : $0.sequence > $1.sequence }
        let recent = events.filter { $0.recordedAt >= start && $0.recordedAt < end && $0.recordedAt <= now }
        func before(_ event: TaskActivity) -> Bool { event.before["project_id"]?.text.lowercased() == project.lowercased() }
        func after(_ event: TaskActivity) -> Bool { event.after["project_id"]?.text.lowercased() == project.lowercased() }
        completions = recent.filter { $0.kinds.contains(.completed) && after($0) }.count
        reopens = recent.filter { $0.kinds.contains(.reopened) && before($0) }.count
        additions = recent.filter { $0.kinds.contains(.created) && after($0) }.count
        movedIn = recent.filter { !before($0) && after($0) && $0.kinds.contains(.moved) }.count
        movedOut = recent.filter { before($0) && !after($0) && $0.kinds.contains(.moved) }.count
    }
}


/// Immutable sequence cursors avoid UUID ordering/offset shifts as new activity arrives.
enum TaskActivityPage {
    static func query(after sequence: Int64) -> String { "/rest/v1/task_activity?select=*&order=sequence.asc&sequence=gt.\(sequence)&limit=500" }
    static func cursor(_ rows: [Record], after previous: Int64) throws -> Int64 {
        var cursor = previous
        for row in rows {
            guard let value = TaskActivity.integer(row["sequence"]), value > cursor else { throw AppFailure(message: "Activity history could not be read in order. Refresh your workspace.") }
            cursor = value
        }
        return cursor
    }
}
