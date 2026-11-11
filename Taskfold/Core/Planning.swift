import Foundation

/// This Evening and Someday: two calm planning states that live beside, not inside, a task's schedule.
///
/// Storage (no server schema change). Both states are per-account ordered id lists in the existing
/// `view_orders` table (text key up to 300 characters, a JSON array of up to 10,000 strings), the table
/// that already holds manual list order and pinned notes (`widget-note:`). Reserved keys:
///   - `planning:someday`         task ids, newest first, no date
///   - `planning:evening:<day>`   task ids in manual order, valid only on that civil day (`yyyy-MM-dd`)
/// The `view_preferences` documents were rejected: every JSON column there is a dedicated, validated column
/// (a new `planning` column is a migration), and the one that tolerates extra fields, `productivity_goals`,
/// is pinned to the `insights` row with a 4,096-byte server check, which a 300-task Someday (about 12 KB of
/// ids) cannot fit. A reserved label was not needed.
///
/// Older clients never read these keys, so they ignore the state; their list-order and pin code paths look rows
/// up by their own keys. Nothing here changes a task's due date except an explicit Move to Someday, and
/// the effective rules below keep a stale or lost list entry harmless: a Someday task is only treated as such
/// while it is open and undated, and an Evening task only while it is open, due today or earlier and listed
/// for today.
enum PlanningSlot: String, Sendable, Equatable, CaseIterable {
    case evening, someday
    var title: String { self == .evening ? "This Evening" : "Someday" }
    var symbol: String { self == .evening ? "moon.fill" : "moon.zzz" }
}

struct PlanningState: Equatable, Sendable {
    /// The civil day the evening list is read for.
    var today: String
    /// Ordered ids for `today` only.
    var evening: [String] = []
    /// Newest first.
    var someday: [String] = []
    /// Keys of valid evening rows for earlier days; they have expired and are removed with the next planning write.
    var expiredEveningKeys: [String] = []
}

enum Planning {
    static let table = "view_orders"
    static let somedayKey = "planning:someday"
    static let eveningPrefix = "planning:evening:"
    /// The server's `view_orders.ids` limit. A list that cannot fit is refused, never truncated.
    static let maxIDs = 10_000
    static let maxKeyBytes = 300
    static let reviewStaleDays = 30
    static let reviewIntervalDays = 7

    static func eveningKey(_ day: String) -> String { eveningPrefix + day }
    static func isPlanningKey(_ key: String) -> Bool { key.hasPrefix("planning:") }

    /// The civil day in `calendar`'s zone; Evening expires when this value changes.
    static func day(_ date: Date, calendar: Calendar = .current) -> String { TaskPlanner.dayKey(date, calendar: calendar) }

    // MARK: Reading

    /// Tolerant read of one list row. Rows of other accounts, malformed values and duplicates are ignored.
    static func ids(_ row: Record?, account: String) -> [String] {
        guard let row, !account.isEmpty, row.string("user_id") == account, case .array(let values) = row["ids"] else { return [] }
        var seen = Set<String>(), result: [String] = []
        for value in values {
            guard case .string(let id) = value, !id.isEmpty, seen.insert(id).inserted else { continue }
            result.append(id)
            if result.count == maxIDs { break }
        }
        return result
    }

    static func state(rows: [Record], account: String, today: String) -> PlanningState {
        var state = PlanningState(today: today)
        var firstByKey: [String: Record] = [:]
        for row in rows where isPlanningKey(row.id) && firstByKey[row.id] == nil { firstByKey[row.id] = row }
        state.someday = ids(firstByKey[somedayKey], account: account)
        state.evening = ids(firstByKey[eveningKey(today)], account: account)
        state.expiredEveningKeys = firstByKey.keys.filter { key in
            guard key.hasPrefix(eveningPrefix), firstByKey[key]?.string("user_id") == account else { return false }
            let day = String(key.dropFirst(eveningPrefix.count))
            return Dates.parse(day) != nil && day < today
        }.sorted()
        return state
    }

    /// The ids listed under Someday for this account, without checking the tasks.
    static func listedSomeday(rows: [Record], account: String) -> Set<String> {
        Set(ids(rows.first { $0.id == somedayKey }, account: account))
    }

    /// Open, ordinary, top-level work. Headings, unsupported kinds and checklist children never enter either state.
    static func eligible(_ task: Record) -> Bool {
        !task.id.isEmpty && TaskKind.mayComplete(task) && !task.completed && SubtaskTree.referencePath(task.id) == nil
    }
    static func isRepeating(_ task: Record) -> Bool { task["is_recurring"].flag }

    /// Someday is "listed and still undated"; scheduling a task anywhere (even on an older client) releases it.
    static func isSomeday(_ task: Record, listed: Set<String>, calendar: Calendar = .current) -> Bool {
        listed.contains(task.id) && eligible(task) && TaskPlanner.plannedDay(task, calendar: calendar).isEmpty
    }
    /// Hidden from dated and inbox lists. Cheap enough for per-row use: no parsing beyond two field reads.
    static func hides(_ task: Record, listed: Set<String>) -> Bool {
        listed.contains(task.id) && !task.completed && task.string("due_date").isEmpty && task.string("scheduled_at").isEmpty
    }
    static func isEvening(_ task: Record, state: PlanningState, calendar: Calendar = .current) -> Bool {
        guard state.evening.contains(task.id), eligible(task) else { return false }
        let day = TaskPlanner.plannedDay(task, calendar: calendar)
        return !day.isEmpty && day <= state.today
    }

    /// Splits Today's rows (already due today or earlier) into the regular list and the evening list, in manual order.
    static func partition(_ rows: [Record], state: PlanningState, calendar: Calendar = .current) -> (regular: [Record], evening: [Record]) {
        guard !state.evening.isEmpty else { return (rows, []) }
        let rank = Dictionary(state.evening.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var regular: [Record] = [], evening: [Record] = []
        for row in rows { if rank[row.id] != nil && isEvening(row, state: state, calendar: calendar) { evening.append(row) } else { regular.append(row) } }
        evening.sort { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
        return (regular, evening)
    }

    /// Someday tasks in list order. `tasks` is the set the caller is willing to show (focus filters applied).
    static func somedayTasks(_ tasks: [Record], state: PlanningState, calendar: Calendar = .current) -> [Record] {
        let listed = Set(state.someday)
        let rank = Dictionary(state.someday.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return tasks.filter { isSomeday($0, listed: listed, calendar: calendar) }.sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
    }

    /// The saved list without ids that are gone, completed or no longer in the state. Order is preserved.
    static func pruned(_ slot: PlanningSlot, ids: [String], tasks: [Record], state: PlanningState, calendar: Calendar = .current) -> [String] {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return ids.filter { id in
            guard let task = byID[id], eligible(task), seen.insert(id).inserted else { return false }
            let day = TaskPlanner.plannedDay(task, calendar: calendar)
            return slot == .someday ? day.isEmpty : (!day.isEmpty && day <= state.today)
        }
    }

    // MARK: Writing

    private static func upsert(_ key: String, ids: [String], rows: [Record], account: String) throws -> Mutation {
        guard key.utf8.count <= maxKeyBytes else { throw AppFailure(message: "This planning list could not be saved.") }
        guard ids.count <= maxIDs else { throw AppFailure(message: "Someday is full. Schedule or delete a few tasks before adding more.") }
        let existing = rows.first { $0.id == key }
        guard existing == nil || existing?.string("user_id") == account else { throw AppFailure(message: "This planning list belongs to another workspace.") }
        return Mutation(table: table, recordID: key, method: existing == nil ? "POST" : "PATCH",
                        fields: ["id": .string(key), "user_id": .string(account), "ids": .array(ids.map(JSON.string))])
    }
    private static func expiredCleanup(_ state: PlanningState, rows: [Record], account: String) -> [Mutation] {
        state.expiredEveningKeys.compactMap { key in
            rows.contains { $0.id == key && $0.string("user_id") == account } ? Mutation(table: table, recordID: key, method: "DELETE", fields: [:]) : nil
        }
    }
    private static func requireAccount(_ account: String) throws { guard !account.isEmpty else { throw AppFailure(message: "Open your workspace before planning tasks.") } }

    /// Moves tasks into This Evening without touching their due dates. Only open tasks due today or earlier qualify.
    /// `before` places them ahead of that evening task, otherwise at the end.
    static func moveToEvening(_ ids: [String], before: String? = nil, tasks: [Record], rows: [Record], account: String, today: String, calendar: Calendar = .current) throws -> [Mutation] {
        try requireAccount(account)
        let state = state(rows: rows, account: account, today: today)
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let moving = ids.filter { id in
            guard let task = byID[id], eligible(task), seen.insert(id).inserted else { return false }
            let day = TaskPlanner.plannedDay(task, calendar: calendar)
            return !day.isEmpty && day <= today
        }
        guard !moving.isEmpty else { throw AppFailure(message: "This Evening is for tasks due today or earlier.") }
        var order = pruned(.evening, ids: state.evening, tasks: tasks, state: state, calendar: calendar).filter { !moving.contains($0) }
        order.insert(contentsOf: moving, at: before.flatMap { order.firstIndex(of: $0) } ?? order.count)
        return expiredCleanup(state, rows: rows, account: account) + [try upsert(eveningKey(today), ids: order, rows: rows, account: account)]
    }

    /// Returns tasks to the regular Today list.
    static func removeFromEvening(_ ids: [String], tasks: [Record], rows: [Record], account: String, today: String, calendar: Calendar = .current) throws -> [Mutation] {
        try requireAccount(account)
        let state = state(rows: rows, account: account, today: today)
        guard ids.contains(where: state.evening.contains) else { return expiredCleanup(state, rows: rows, account: account) }
        let order = pruned(.evening, ids: state.evening, tasks: tasks, state: state, calendar: calendar).filter { !ids.contains($0) }
        return expiredCleanup(state, rows: rows, account: account) + [try upsert(eveningKey(today), ids: order, rows: rows, account: account)]
    }

    /// Re-ranks the evening list. Ids not currently in the evening list are ignored.
    static func reorderEvening(_ ordered: [String], tasks: [Record], rows: [Record], account: String, today: String, calendar: Calendar = .current) throws -> [Mutation] {
        try requireAccount(account)
        let state = state(rows: rows, account: account, today: today)
        let valid = pruned(.evening, ids: state.evening, tasks: tasks, state: state, calendar: calendar)
        let known = Set(valid)
        let order = ordered.filter(known.contains)
        let order2 = order + valid.filter { !order.contains($0) }
        guard order2 != state.evening else { return [] }
        return expiredCleanup(state, rows: rows, account: account) + [try upsert(eveningKey(today), ids: order2, rows: rows, account: account)]
    }

    /// Fields that clear a task's schedule, the same as "Remove Date".
    static let clearedSchedule: [String: JSON] = ["due_date": .null, "due_time": .null, "time_zone": .null, "scheduled_at": .null]

    /// Files tasks under Someday: the due date is cleared (the task PATCH and the list update commit together, so one
    /// undo restores both) and any evening entry is dropped. Repeating tasks keep their schedule and are skipped.
    static func moveToSomeday(_ ids: [String], tasks: [Record], rows: [Record], account: String, today: String, calendar: Calendar = .current) throws -> [Mutation] {
        try requireAccount(account)
        let state = state(rows: rows, account: account, today: today)
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let moving = ids.compactMap { id -> Record? in
            guard let task = byID[id], eligible(task), !isRepeating(task), seen.insert(id).inserted else { return nil }
            return task
        }
        guard !moving.isEmpty else { throw AppFailure(message: "Repeating tasks keep their schedule, so they can’t move to Someday.") }
        let movingIDs = moving.map(\.id)
        let list = pruned(.someday, ids: state.someday, tasks: tasks, state: state, calendar: calendar).filter { !movingIDs.contains($0) }
        var changes: [Mutation] = moving.compactMap { task in
            let fields = clearedSchedule.filter { task[$0.key] != .null && !(task.string($0.key).isEmpty) }
            return fields.isEmpty ? nil : Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: fields)
        }
        changes += expiredCleanup(state, rows: rows, account: account)
        if movingIDs.contains(where: state.evening.contains) {
            let order = pruned(.evening, ids: state.evening, tasks: tasks, state: state, calendar: calendar).filter { !movingIDs.contains($0) }
            changes.append(try upsert(eveningKey(today), ids: order, rows: rows, account: account))
        }
        changes.append(try upsert(somedayKey, ids: movingIDs + list, rows: rows, account: account))
        return changes
    }

    /// Releases tasks from the Someday list (after they are scheduled). The caller supplies the schedule change.
    static func removeFromSomeday(_ ids: [String], tasks: [Record], rows: [Record], account: String, today: String, calendar: Calendar = .current) throws -> [Mutation] {
        try requireAccount(account)
        let state = state(rows: rows, account: account, today: today)
        guard ids.contains(where: state.someday.contains) else { return [] }
        let released = Set(ids)
        let list = pruned(.someday, ids: state.someday, tasks: tasks.filter { !released.contains($0.id) }, state: state, calendar: calendar)
        return [try upsert(somedayKey, ids: list, rows: rows, account: account)]
    }

    /// New tasks created with a planning token. The task rows are the caller's own pending creation.
    static func filingNewTask(_ task: Record, slot: PlanningSlot, tasks: [Record], rows: [Record], account: String, today: String, calendar: Calendar = .current) throws -> [Mutation] {
        let known = tasks.filter { $0.id != task.id } + [task]
        switch slot {
        case .evening:
            return try moveToEvening([task.id], tasks: known, rows: rows, account: account, today: today, calendar: calendar)
        case .someday:
            // The task is created undated already; only the list entry is written.
            try requireAccount(account)
            let state = state(rows: rows, account: account, today: today)
            let list = pruned(.someday, ids: state.someday, tasks: known, state: state, calendar: calendar).filter { $0 != task.id }
            return [try upsert(somedayKey, ids: [task.id] + list, rows: rows, account: account)]
        }
    }

    // MARK: Review

    struct Review: Equatable, Sendable {
        /// Items that have been waiting longer than `reviewStaleDays`.
        var staleIDs: [String]
        var count: Int { staleIDs.count }
        var message: String { count == 1 ? "1 idea has been here for over a month." : "\(count) ideas have been here for over a month." }
    }
    /// A gentle weekly prompt: only while something has waited more than 30 days and the last review (kept on
    /// this device) is a week or more old. `createdAt` is the age proxy; no notification is ever scheduled.
    static func review(_ someday: [Record], now: Date, lastReviewed: Date?, calendar: Calendar = .current) -> Review? {
        if let lastReviewed, let next = calendar.date(byAdding: .day, value: reviewIntervalDays, to: lastReviewed), now < next { return nil }
        guard let cutoff = calendar.date(byAdding: .day, value: -reviewStaleDays, to: now) else { return nil }
        let stale = someday.filter { task in TaskPlanning.instant(task.string("created_at")).map { $0 < cutoff } ?? false }.map(\.id)
        return stale.isEmpty ? nil : Review(staleIDs: stale)
    }

    // MARK: Quick Add

    /// `this evening` and `someday` are matched as whole words; the bare word `evening` keeps its older meaning
    /// of a 7 PM clock time.
    static let eveningPattern = #"(?<![\p{L}\p{N}_/.@#])this\s+evening(?![\p{L}\p{N}_/@]|:\d|\.[\p{L}\p{N}])"#
    static let somedayPattern = #"(?<![\p{L}\p{N}_/.@#])someday(?![\p{L}\p{N}_/@]|:\d|\.[\p{L}\p{N}])"#
}
