import Foundation

/// Habits: recurring tasks the person chooses to track. A habit is never a new kind of record.
///
/// Storage (no server schema change). The habit set is one per-account ordered id list in the existing
/// `view_orders` table, the same table and approach as This Evening, Someday and the daily plan (see Planning.swift):
///   - `planning:habits`   recurrence-root ids, in the order shown
/// The id is the *recurrence root*: the first task of a series. Every later occurrence is a separate task row
/// whose `recurrence_parent_id` is that root (see `TaskCompletion.toggle`), so the id stays stable as the series
/// advances. Older clients never read the key; the task keeps working as an ordinary recurring task.
///
/// History needs no new storage. Completing a recurring occurrence marks that row completed (it keeps its
/// `due_date` and `completed_at`) and creates its successor, so the whole series, with every completion date,
/// is already in the tasks table. Habit history is a pure read of those rows and of the recurrence rule.
///
/// Honesty rules (the Momentum rules, applied to a series):
///   - Days before the first known occurrence of the series are `untracked`, never `missed`. They end what can be
///     computed and a streak that reaches them is reported "since <date>".
///   - Days the rule does not hit are `notScheduled`: skipped, never broken.
///   - Vacation days (Momentum's ranges) freeze streaks. A day with a check-in still counts as done.
///   - Today is `pending` until checked in and never breaks a streak.
///   - A completion counts for the day it happened when the rule schedules that day; an early completion counts for
///     the day the occurrence was due; otherwise it counts for its due day.
enum HabitDayState: String, Equatable, Sendable {
    case done, missed, notScheduled, pending, vacation, untracked, future
    var spoken: String {
        switch self {
        case .done: "done"
        case .missed: "missed"
        case .notScheduled: "not scheduled"
        case .pending: "still to do"
        case .vacation: "on vacation"
        case .untracked: "not tracked yet"
        case .future: "upcoming"
        }
    }
}

struct HabitDay: Equatable, Identifiable, Sendable {
    /// `yyyy-MM-dd` in the reading's calendar.
    var id: String
    var date: Date
    var state: HabitDayState
}

struct HabitStreak: Equatable, Sendable {
    var length: Int
    /// Set when recorded history, not a missed day, bounds the streak: "since <date>". A `yyyy-MM-dd` key.
    var since: String?
    static let none = HabitStreak(length: 0, since: nil)
}

struct HabitCompletion: Equatable, Identifiable, Sendable {
    var id: String
    var completedAt: Date
    /// The day this completion counts for.
    var day: String
}

struct HabitHeatWeek: Equatable, Identifiable, Sendable {
    /// First day of the week.
    var id: String
    /// Seven days in week order.
    var days: [HabitDay]
    var summary: String
}

struct HabitReading: Equatable, Identifiable, Sendable {
    var id: String { habitID }
    /// The recurrence root, the id stored in the habit list.
    var habitID: String
    var title: String
    /// The open occurrence a check-in completes; nil when the series has ended.
    var occurrenceID: String?
    var schedule: String
    /// The last seven days, oldest first, ending today.
    var week: [HabitDay]
    var currentStreak: HabitStreak
    var bestStreak: HabitStreak
    var monthDone: Int
    var monthScheduled: Int
    var scheduledToday: Bool
    var doneToday: Bool
    /// Twelve weeks ending with the current one, oldest first.
    var heatmap: [HabitHeatWeek]
    /// Newest first.
    var recent: [HabitCompletion]
    /// First day with a known occurrence; history before it does not exist.
    var trackedSince: String?
    /// 0...100, nil until a day this month can be judged.
    var monthRate: Int? { monthScheduled > 0 ? Int((Double(monthDone) * 100 / Double(monthScheduled)).rounded()) : nil }
    var canCheckIn: Bool { occurrenceID != nil && scheduledToday && !doneToday }
}

enum Habits {
    static let table = Planning.table
    static let key = "planning:habits"
    static let maxHabits = 200
    static let heatmapWeeks = 12
    /// How far back streaks and rates read.
    static let historyDays = 366
    static let recentLimit = 20
    private static let walkLimit = 4000

    // MARK: Identity

    /// The series a task belongs to.
    static func root(of task: Record) -> String {
        let parent = task.string("recurrence_parent_id")
        return parent.isEmpty ? task.id : parent
    }
    static func family(_ habit: String, in tasks: [Record]) -> [Record] {
        tasks.filter { !$0.id.isEmpty && ($0.id == habit || $0.string("recurrence_parent_id") == habit) }
    }
    /// Recurring, ordinary, top-level work the account owns. Shared (team) tasks are excluded by the caller.
    static func eligible(_ task: Record, account: String) -> Bool {
        guard !account.isEmpty, !task.id.isEmpty, task["is_recurring"].flag, TaskKind.mayComplete(task),
              SubtaskTree.referencePath(task.id) == nil, task.string("user_id").lowercased() == account.lowercased(),
              Recurrence.valid(Recurrence.effective(task)) else { return false }
        return true
    }
    /// The open occurrence of a series: the earliest one still to do.
    static func openOccurrence(_ habit: String, in tasks: [Record]) -> Record? {
        family(habit, in: tasks).filter { !$0.completed && $0["is_recurring"].flag }
            .min { ($0.string("due_date"), $0.id) < ($1.string("due_date"), $1.id) }
    }

    // MARK: Reading the stored list

    static func ids(rows: [Record], account: String) -> [String] {
        Planning.ids(rows.first { $0.id == key }, account: account)
    }

    /// The saved list without series that are gone or no longer repeating. Order is preserved.
    static func pruned(_ ids: [String], tasks: [Record], account: String) -> [String] {
        var live = Set<String>()
        for task in tasks where !task.completed && task["is_recurring"].flag && TaskKind.mayComplete(task) && task.string("user_id").lowercased() == account.lowercased() {
            live.insert(root(of: task))
        }
        var seen = Set<String>()
        return ids.filter { live.contains($0) && seen.insert($0).inserted }
    }

    // MARK: Writing

    private static func upsert(_ list: [String], rows: [Record], account: String) throws -> Mutation {
        guard !account.isEmpty else { throw AppFailure(message: "Open your workspace before tracking habits.") }
        guard list.count <= maxHabits else { throw AppFailure(message: "You can track up to \(maxHabits) habits.") }
        let existing = rows.first { $0.id == key }
        guard existing == nil || existing?.string("user_id") == account else { throw AppFailure(message: "This habit list belongs to another workspace.") }
        return Mutation(table: table, recordID: key, method: existing == nil ? "POST" : "PATCH",
                        fields: ["id": .string(key), "user_id": .string(account), "ids": .array(list.map(JSON.string))])
    }

    /// Adds or removes a series. Stale ids are dropped in the same write. Returns no change when nothing differs.
    static func setTracked(_ task: Record, tracked: Bool, tasks: [Record], rows: [Record], account: String) throws -> [Mutation] {
        guard !account.isEmpty else { throw AppFailure(message: "Open your workspace before tracking habits.") }
        let habit = root(of: task)
        let current = ids(rows: rows, account: account)
        var list = pruned(current, tasks: tasks, account: account)
        if tracked {
            guard eligible(task, account: account) else { throw AppFailure(message: "Only repeating tasks you own can be tracked as habits.") }
            if !list.contains(habit) { list.append(habit) }
        } else { list.removeAll { $0 == habit } }
        guard list != current else { return [] }
        return [try upsert(list, rows: rows, account: account)]
    }

    /// Re-ranks the list. Unknown ids are ignored and missing ones keep their place at the end.
    static func reorder(_ ordered: [String], tasks: [Record], rows: [Record], account: String) throws -> [Mutation] {
        let current = ids(rows: rows, account: account)
        let valid = pruned(current, tasks: tasks, account: account)
        let known = Set(valid)
        let first = ordered.filter(known.contains)
        let list = first + valid.filter { !first.contains($0) }
        guard list != current else { return [] }
        return [try upsert(list, rows: rows, account: account)]
    }

    // MARK: Schedule

    static func isTracked(_ task: Record, ids: [String]) -> Bool { ids.contains(root(of: task)) }

    /// "Every day", "Every weekday", "Every Mon, Wed, Fri", "Every 2 weeks on Tue".
    static func scheduleSummary(_ task: Record) -> String {
        let p = Recurrence.effective(task)
        guard Recurrence.valid(p) else { return "Repeats" }
        let interval = Recurrence.number(p["interval"], in: 1...10000) ?? 1
        let type = p.string("type")
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let days = Array(Set(p["daysOfWeek"].list.compactMap { Recurrence.number($0, in: 0...6) })).sorted()
        if p["fromCompletion"].flag { return Recurrence.summary(p) }
        if type == "weekly", !days.isEmpty {
            if interval == 1 {
                if days == [1, 2, 3, 4, 5] { return "Every weekday" }
                if days == [0, 6] { return "Every weekend" }
                if days.count == 7 { return "Every day" }
                return "Every " + days.map { names[$0] }.joined(separator: ", ")
            }
            return "Every \(interval) weeks on " + days.map { names[$0] }.joined(separator: ", ")
        }
        if type == "daily" || type == "custom" { return interval == 1 ? "Every day" : "Every \(interval) days" }
        if type == "weekly" { return interval == 1 ? "Every week" : "Every \(interval) weeks" }
        return Recurrence.summary(p)
    }

    /// Days the rule schedules from `anchor` through `through` (inclusive, `yyyy-MM-dd`). Completion-based rules
    /// have no calendar of their own, so they schedule only the anchor.
    static func scheduledDays(rule task: Record, anchor: String, through: String, calendar: Calendar) -> Set<String> {
        guard anchor <= through else { return [] }
        var result: Set<String> = [anchor]
        var pattern = Recurrence.effective(task)
        guard Recurrence.valid(pattern), !pattern["fromCompletion"].flag else { return result }
        // A remaining-occurrence counter belongs to the open occurrence, not to the series' past.
        pattern["count"] = .null
        var probe = task
        probe["is_recurring"] = .bool(true); probe["recurrence_pattern"] = .object(pattern.fields); probe["due_date"] = .string(anchor)
        probe["recurrence_end_date"] = .null
        let zone = TaskCompletion.calendar(for: task, input: calendar)
        var last = anchor
        for _ in 0..<walkLimit {
            guard let next = Dates.next(probe, calendar: calendar) else { break }
            let day = TaskPlanner.dayKey(next, calendar: zone)
            guard day > last, day <= through else { break }
            result.insert(day); last = day
            probe["due_date"] = .string(day)
        }
        return result
    }

    // MARK: Reading a habit

    private struct Occurrence {
        var id: String
        var dueDay: String
        var completedAt: Date?
        var completedDay: String?
    }

    /// Everything the Habits view shows for one series. Pure: tasks and a calendar in, readings out.
    /// `vacations` are Momentum's ranges. `calendar` carries the week start and time zone.
    static func read(habit: String, tasks: [Record], calendar: Calendar, vacations: [VacationRange] = [], now: Date, locale: Locale = .current) -> HabitReading? {
        let rows = family(habit, in: tasks)
        guard !rows.isEmpty else { return nil }
        let cal = calendar   // `locale` only formats text; setting it on the calendar would override the week start
        let today = TaskPlanner.dayKey(now, calendar: cal)
        func parse(_ text: String) -> Date? { Dates.parse(text, calendar: cal) }
        let current = openOccurrence(habit, in: tasks)
        // The rule comes from the open occurrence; a finished series falls back to its newest row.
        let rule = current ?? rows.max { ($0.string("due_date"), $0.id) < ($1.string("due_date"), $1.id) }!
        var occurrences: [Occurrence] = rows.map { row in
            let zone = TaskCompletion.calendar(for: row, input: cal)
            let at = row.completed ? TaskPlanning.instant(row.string("completed_at")) : nil
            let due = String(row.string("due_date").prefix(10))
            let doneDay = row.completed ? (at.map { TaskPlanner.dayKey($0, calendar: zone) } ?? (due.isEmpty ? nil : due)) : nil
            return Occurrence(id: row.id, dueDay: due, completedAt: at, completedDay: doneDay)
        }
        occurrences = occurrences.filter { !$0.dueDay.isEmpty || $0.completedDay != nil }
        let createdDays = rows.compactMap { TaskPlanning.instant($0.string("created_at")).map { TaskPlanner.dayKey($0, calendar: cal) } }
        var starts = occurrences.compactMap { $0.dueDay.isEmpty ? nil : $0.dueDay } + occurrences.compactMap(\.completedDay)
        if starts.isEmpty { starts = createdDays }
        guard let anchor = starts.min() else { return nil }
        let windowStart: String = {
            guard let start = parse(today), let back = cal.date(byAdding: .day, value: -(historyDays - 1), to: start) else { return anchor }
            return TaskPlanner.dayKey(back, calendar: cal)
        }()
        var scheduled = scheduledDays(rule: rule, anchor: anchor, through: today, calendar: cal)
        for occurrence in occurrences where !occurrence.dueDay.isEmpty && occurrence.dueDay <= today { scheduled.insert(occurrence.dueDay) }
        // Credit each completion to one day.
        var credited: [String: Date] = [:]
        var completions: [HabitCompletion] = []
        for occurrence in occurrences {
            guard let completedDay = occurrence.completedDay else { continue }
            let due = occurrence.dueDay
            let day: String
            if !due.isEmpty, completedDay < due { day = due }
            else if scheduled.contains(completedDay) || due.isEmpty { day = completedDay }
            else { day = due }
            scheduled.insert(day)
            let stamp = occurrence.completedAt ?? parse(day) ?? now
            credited[day] = max(credited[day] ?? .distantPast, stamp)
            completions.append(HabitCompletion(id: occurrence.id, completedAt: stamp, day: day))
        }
        func inVacation(_ day: String) -> Bool { vacations.contains { $0.contains(day) } }
        func state(_ day: String) -> HabitDayState {
            if day > today { return .future }
            if day < anchor { return .untracked }
            if credited[day] != nil { return .done }
            guard scheduled.contains(day) else { return .notScheduled }
            if inVacation(day) { return .vacation }
            return day == today ? .pending : .missed
        }
        func dayValue(_ key: String) -> HabitDay? { parse(key).map { HabitDay(id: key, date: $0, state: state(key)) } }
        // The streak window, oldest first, ending today.
        var window: [HabitDay] = []
        if var cursor = parse(max(windowStart, anchor)), let end = parse(today) {
            // Include the untracked day before the anchor so a streak that starts at the anchor is reported "since".
            if anchor >= windowStart, let before = cal.date(byAdding: .day, value: -1, to: cursor) { cursor = before }
            while cursor <= end {
                if let value = dayValue(TaskPlanner.dayKey(cursor, calendar: cal)) { window.append(value) }
                guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
        }
        let streaks = Self.streaks(window)
        // Last seven days.
        var week: [HabitDay] = []
        if let end = parse(today) {
            for offset in stride(from: -6, through: 0, by: 1) {
                if let date = cal.date(byAdding: .day, value: offset, to: end), let value = dayValue(TaskPlanner.dayKey(date, calendar: cal)) { week.append(value) }
            }
        }
        // This month.
        var monthDone = 0, monthScheduled = 0
        if let end = parse(today), let month = cal.dateInterval(of: .month, for: end) {
            var cursor = month.start
            while cursor <= end {
                switch state(TaskPlanner.dayKey(cursor, calendar: cal)) {
                case .done: monthDone += 1; monthScheduled += 1
                case .missed: monthScheduled += 1
                default: break
                }
                guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
        }
        // Heatmap: twelve whole weeks ending with this one.
        var heat: [HabitHeatWeek] = []
        if let end = parse(today), let thisWeek = cal.dateInterval(of: .weekOfYear, for: end)?.start {
            let formatter = DateFormatter(); formatter.locale = locale; formatter.timeZone = cal.timeZone; formatter.setLocalizedDateFormatFromTemplate("dMMM")
            for back in stride(from: heatmapWeeks - 1, through: 0, by: -1) {
                guard let start = cal.date(byAdding: .day, value: -7 * back, to: thisWeek) else { continue }
                var days: [HabitDay] = []
                for offset in 0..<7 {
                    if let date = cal.date(byAdding: .day, value: offset, to: start), let value = dayValue(TaskPlanner.dayKey(date, calendar: cal)) { days.append(value) }
                }
                guard days.count == 7 else { continue }
                let done = days.filter { $0.state == .done }.count
                let judged = days.filter { [.done, .missed].contains($0.state) }.count
                let pending = days.contains { $0.state == .pending }
                var summary = "Week of " + formatter.string(from: start) + ": "
                if judged == 0 && !pending { summary += days.contains { $0.state == .untracked } ? "not tracked yet" : "nothing scheduled" }
                else { summary += "\(done) of \(judged) scheduled \(judged == 1 ? "day" : "days") done" + (pending ? ", today still to do" : "") }
                heat.append(HabitHeatWeek(id: days[0].id, days: days, summary: summary))
            }
        }
        let todayState = state(today)
        return HabitReading(
            habitID: habit, title: (rule.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled habit" : rule.title),
            occurrenceID: current?.id, schedule: scheduleSummary(rule), week: week,
            currentStreak: streaks.current, bestStreak: streaks.best, monthDone: monthDone, monthScheduled: monthScheduled,
            scheduledToday: scheduled.contains(today), doneToday: todayState == .done,
            heatmap: heat, recent: Array(completions.sorted { $0.completedAt == $1.completedAt ? $0.id > $1.id : $0.completedAt > $1.completedAt }.prefix(recentLimit)),
            trackedSince: anchor)
    }

    /// Current streak ends at the newest day (a skipped or pending newest day is passed over); best is the longest run.
    static func streaks(_ days: [HabitDay]) -> (current: HabitStreak, best: HabitStreak) {
        var current = 0, currentSince: String?, endedByMiss = false
        scan: for day in days.reversed() {
            switch day.state {
            case .done: current += 1; currentSince = day.id
            case .missed: endedByMiss = true; break scan
            case .untracked: break scan
            default: break
            }
        }
        var best = 0, bestSince: String?, bestLimited = false
        var run = 0, runSince: String?, runLimited = true
        for day in days {
            switch day.state {
            case .done:
                if run == 0 { runSince = day.id }
                run += 1
                if run > best { best = run; bestSince = runSince; bestLimited = runLimited }
            case .missed: run = 0; runLimited = false
            case .untracked: run = 0; runLimited = true
            default: break
            }
        }
        return (HabitStreak(length: current, since: current > 0 && !endedByMiss ? currentSince : nil),
                HabitStreak(length: best, since: bestLimited && best > 0 ? bestSince : nil))
    }

    // MARK: Today

    struct TodaySummary: Equatable, Sendable {
        var done: Int
        var total: Int
        var label: String { "Habits \(done)/\(total)" }
    }
    /// A cheap count for the Today header: habits with an open occurrence due today or earlier, plus those
    /// completed today. No schedule walk.
    static func todaySummary(ids: [String], tasks: [Record], today: String, calendar: Calendar) -> TodaySummary? {
        guard !ids.isEmpty else { return nil }
        var done = 0, total = 0
        let byRoot = Dictionary(grouping: tasks.filter { !$0.id.isEmpty }) { root(of: $0) }
        for habit in ids {
            let rows = byRoot[habit] ?? []
            let completedToday = rows.contains { row in
                guard row.completed, let at = TaskPlanning.instant(row.string("completed_at")) else { return false }
                return TaskPlanner.dayKey(at, calendar: TaskCompletion.calendar(for: row, input: calendar)) == today
            }
            let due = rows.contains { !$0.completed && $0["is_recurring"].flag && { let day = String($0.string("due_date").prefix(10)); return !day.isEmpty && day <= today }($0) }
            if completedToday { done += 1; total += 1 } else if due { total += 1 }
        }
        return total > 0 ? TodaySummary(done: done, total: total) : nil
    }

    // MARK: Accessibility

    /// "Read 20 pages, 12-day streak, done today".
    static func spoken(_ reading: HabitReading) -> String {
        var parts = [reading.title]
        parts.append(reading.currentStreak.length == 0 ? "no streak yet" : "\(reading.currentStreak.length)-day streak")
        if reading.doneToday { parts.append("done today") }
        else if reading.canCheckIn { parts.append("not done today") }
        else if !reading.scheduledToday { parts.append("not scheduled today") }
        return parts.joined(separator: ", ")
    }
    static func streakText(_ streak: HabitStreak, since: (String) -> String) -> String {
        let value = "\(streak.length)-day streak"
        return streak.since.map { value + ", since " + since($0) } ?? value
    }
}
