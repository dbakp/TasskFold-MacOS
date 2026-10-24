import Foundation

/// A repeat edit captures its planning/completion context as one reviewed unit.
/// This is task recurrence, not a reminder schedule or server-owned series link.
enum TeamTaskRecurrence {
    static let fields: Set<String> = ["is_recurring", "recurrence_pattern", "recurrence_end_date"]
    static let cohort: Set<String> = fields.union(["due_date", "due_time", "time_zone", "completed", "completed_at", "completion_version"])
    static let ruleFields: Set<String> = ["type", "interval", "daysOfWeek", "dayOfMonth", "daysOfMonth", "monthOfYear", "weekday", "weekdayOrdinal", "count", "endDate", "fromCompletion"]
    static func touches(_ changes: [String: JSON]) -> Bool { !fields.isDisjoint(with: changes.keys) }
    static var invalid: AppFailure { AppFailure(message: "Review this repeat rule and its planned date. Your saved rule is kept unchanged.") }
    static var conflict: AppFailure { AppFailure(message: "TASKFOLD_CONFLICT: The repeat rule, plan or completion changed. Review the current task before applying your draft.") }
    private static func day(_ value: JSON) -> Bool {
        guard case .string(let text) = value, text.count == 10 else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return Dates.parse(text, calendar: calendar).map { TaskPlanner.dayKey($0, calendar: calendar) == text } ?? false
    }
    /// Unknown semantics remain visible through the original task/recovery record,
    /// but are never silently rewritten by controls that cannot represent them.
    static func supported(_ task: Record) -> Bool {
        guard task["is_recurring"] == .bool(true) || task["is_recurring"] == .bool(false) || task["is_recurring"] == .null else { return false }
        if task["recurrence_end_date"] != .null, !day(task["recurrence_end_date"]) { return false }
        let raw = task["recurrence_pattern"]
        if raw != .null {
            guard case .object(let rule) = raw, Set(rule.keys).isSubset(of: ruleFields) else { return false }
            if !rule.isEmpty, !Recurrence.valid(Record(rule)) { return false }
            if let end = rule["endDate"], end != .null, end != .string(""), !day(end) { return false }
        }
        if task["is_recurring"] == .bool(true) {
            guard day(task["due_date"]), Recurrence.valid(Recurrence.effective(task)) else { return false }
        }
        return true
    }
    static func reviewedChanges(from original: Record, to proposed: Record) throws -> [String: JSON] {
        let changed = Set(original.fields.keys).union(proposed.fields.keys).filter { original[$0] != proposed[$0] }
        guard Set(changed).isSubset(of: fields.union(["due_date"])) else { throw invalid }
        let values = Dictionary(uniqueKeysWithValues: changed.map { ($0, proposed[$0]) })
        if !values.isEmpty {
            guard touches(values) else { throw invalid }
            try validate(base: TaskCompletionRevision.editBaseline(for: values, from: original), changes: values)
        }
        return values
    }
    static func validate(base: [String: JSON], changes: [String: JSON]) throws {
        guard touches(changes) else { return }
        guard cohort.isSubset(of: base.keys), changes["completed"] == nil, changes["completed_at"] == nil,
              case .number(let version)? = base["completion_version"], version.isFinite,
              version >= 0, version <= 9_007_199_254_740_991, version.rounded() == version,
              case .bool? = base["completed"], supported(Record(base)) else { throw invalid }
        if let enabled = changes["is_recurring"], enabled != .bool(true), enabled != .bool(false) { throw invalid }
        var desired = Record(base); for (key, value) in changes { desired[key] = value }
        guard supported(desired) else { throw invalid }
    }
    static func requireCurrent(base: [String: JSON], current: Record) throws {
        guard cohort.isSubset(of: base.keys) else { throw invalid }
        for key in cohort {
            let old = base[key]!, live = current[key]
            if old == live { continue }
            if key == "due_time", old != .null, live != .null {
                func clock(_ text: String) -> String { text.count == 8 && text.hasSuffix(":00") ? String(text.prefix(5)) : text }
                if clock(old.text) == clock(live.text) { continue }
            }
            if key == "completed_at", let a = TaskPlanning.instant(old.text), let b = TaskPlanning.instant(live.text), a == b { continue }
            throw conflict
        }
    }
}
