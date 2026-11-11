import Foundation

/// The guided daily-planning ritual (triage, estimate, time-block, done) and the evening shutdown.
///
/// Everything here is pure: no Store, no UI. Writes are built from the existing `TaskPlanner.fields`,
/// `dayFields` and `tomorrowFields`, and committed by the callers through the ordinary Store paths, so undo,
/// sync, reminders and recurrence behave exactly as they do for any other schedule edit.
///
/// "Planned today" storage (no server schema change). Two reserved keys in the per-account `view_orders`
/// table, the same table and approach as This Evening and Someday (see Planning.swift):
///   - `planning:day:<yyyy-MM-dd>`       ids of the tasks planned for that civil day, in planned order
///   - `planning:shutdown:<yyyy-MM-dd>`  an empty marker: the day was shut down
/// Both are valid only on their own day and are removed with the next write of a later day, like the evening list.
/// Older clients never read the keys, and a lost or stale row only brings the gentle header prompt back.
enum DayPlanStep: Int, CaseIterable, Sendable {
    case triage, estimate, timeBlock, done
    var number: Int { rawValue + 1 }
    static var count: Int { allCases.count }
    var title: String {
        switch self { case .triage: "Triage"; case .estimate: "Estimate"; case .timeBlock: "Time-block"; case .done: "Done" }
    }
    /// "Step 2 of 4, Estimate"
    var accessibilityLabel: String { "Step \(number) of \(Self.count), \(title)" }
}

/// Why a task stays unscheduled after "Fit my day".
enum DayPlanSkip: String, Equatable, Sendable {
    case noEstimate, longerThanAnyGap, noRoom, noWorkingHours, evening
    var message: String {
        switch self {
        case .noEstimate: "Needs an estimate"
        case .longerThanAnyGap: "Longer than any free gap"
        case .noRoom: "No room left today"
        case .noWorkingHours: "No working hours today"
        case .evening: "Kept for this evening"
        }
    }
}

struct DayPlanPlacement: Equatable, Identifiable, Sendable {
    var taskID: String
    var start: Date
    var minutes: Int
    var id: String { taskID }
    var end: Date { start.addingTimeInterval(Double(minutes) * 60) }
}

struct DayPlanFit: Equatable, Sendable {
    struct Unplaced: Equatable, Identifiable, Sendable {
        var taskID: String
        var reason: DayPlanSkip
        var id: String { taskID }
    }
    /// Chronological.
    var placements: [DayPlanPlacement] = []
    /// Input order.
    var didntFit: [Unplaced] = []
    var placedMinutes: Int { placements.reduce(0) { $0 + $1.minutes } }
}

struct DayPlanTotals: Equatable, Sendable {
    var taskCount = 0
    var estimatedMinutes = 0
    var unestimatedCount = 0
    var workingMinutes = 0
    var busyMinutes = 0
    var freeMinutes: Int { max(0, workingMinutes - busyMinutes) }
    /// Minutes of estimated work beyond the free time, rounded up to five. Zero when it fits.
    var overMinutes: Int {
        let over = estimatedMinutes - freeMinutes
        return over > 0 ? DayPlan.roundedUp(over, to: 5) : 0
    }
    var isOver: Bool { overMinutes > 0 }
    var overNote: String? { isOver ? "About \(DayPlan.duration(overMinutes)) more than your free time" : nil }
    var capacityLabel: String { "\(DayPlan.duration(estimatedMinutes)) planned of \(DayPlan.duration(freeMinutes)) free" }
    var capacityAccessibility: String { "Capacity: \(DayPlan.spoken(estimatedMinutes)) planned of \(DayPlan.spoken(freeMinutes)) free" }
    /// 0...1 for a meter; full when over.
    var fraction: Double { freeMinutes > 0 ? min(1, Double(estimatedMinutes) / Double(freeMinutes)) : (estimatedMinutes > 0 ? 1 : 0) }
}

/// What the Today header offers for the current day.
enum DayPlanPrompt: Equatable, Sendable { case plan, shutdown, planned, shutDown }

struct DayPlanState: Equatable, Sendable {
    var today: String
    var plannedIDs: [String] = []
    var planned = false
    var shutDown = false
    /// Rows of earlier days; removed with the next write.
    var expiredKeys: [String] = []
}

enum DayPlan {
    static let table = Planning.table
    static let plannedPrefix = "planning:day:"
    static let shutdownPrefix = "planning:shutdown:"
    /// Minutes kept free before and after anything already in the day.
    static let buffer = 5
    static let grid = 5
    /// Quick estimate chips, keys 1 to 4 on the Mac; key 5 is a custom value.
    static let chips: [Int] = [15, 30, 60, 120]
    /// Evening tasks, when the user opts in, are placed after working hours and never later than this.
    static let eveningEndMinute = 22 * 60
    /// Without usable working hours, the day is treated as over from here.
    static let fallbackEndMinute = 18 * 60

    static func plannedKey(_ day: String) -> String { plannedPrefix + day }
    static func shutdownKey(_ day: String) -> String { shutdownPrefix + day }

    // MARK: Formatting

    static func roundedUp(_ value: Int, to unit: Int) -> Int { unit > 0 ? ((value + unit - 1) / unit) * unit : value }

    /// "1h 30m", "45m", "2h".
    static func duration(_ minutes: Int) -> String {
        let minutes = max(0, minutes), h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
    /// "1 hour 30 minutes", for VoiceOver.
    static func spoken(_ minutes: Int) -> String {
        let minutes = max(0, minutes), h = minutes / 60, m = minutes % 60
        var parts: [String] = []
        if h > 0 { parts.append(h == 1 ? "1 hour" : "\(h) hours") }
        if m > 0 || h == 0 { parts.append(m == 1 ? "1 minute" : "\(m) minutes") }
        return parts.joined(separator: " ")
    }
    static func chipTitle(_ minutes: Int) -> String { duration(minutes) }

    /// "5 tasks · 4h 15m planned · finishes around 16:30". `finish` is already formatted for the user's locale.
    static func summaryLine(taskCount: Int, plannedMinutes: Int, finish: String?) -> String {
        var parts = [taskCount == 1 ? "1 task" : "\(taskCount) tasks", "\(duration(plannedMinutes)) planned"]
        if let finish { parts.append("finishes around \(finish)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Which tasks

    /// Open, ordinary, top-level work planned for `day`. Headings, unsupported kinds, checklist children and
    /// completed tasks never enter the plan. Recurring tasks are ordinary here: this occurrence is today's work.
    static func todayTasks(_ tasks: [Record], day: String, calendar: Calendar = .current) -> [Record] {
        tasks.filter { Planning.eligible($0) && TaskPlanner.plannedDay($0, calendar: calendar) == day }
    }
    static func isTimed(_ task: Record, calendar: Calendar = .current) -> Bool { TaskPlanning.start(task, calendar: calendar) != nil }
    /// Priority bands first, the given order inside each band. The caller passes the manual order.
    static func prioritised(_ tasks: [Record]) -> [Record] {
        tasks.enumerated().sorted { $0.element.priority == $1.element.priority ? $0.offset < $1.offset : $0.element.priority < $1.element.priority }.map(\.element)
    }
    static func withoutEstimate(_ tasks: [Record]) -> [Record] { tasks.filter { $0.durationMinutes == nil } }

    // MARK: Steps

    /// The steps worth showing. Triage needs something to decide, Estimate needs a task, Time-block needs an
    /// estimated task that could be placed, and Done always closes the flow.
    static func eligibleSteps(triageCount: Int, today: [Record]) -> [DayPlanStep] {
        var steps: [DayPlanStep] = []
        if triageCount > 0 { steps.append(.triage) }
        if !today.isEmpty { steps.append(.estimate) }
        if today.contains(where: { $0.durationMinutes != nil }) { steps.append(.timeBlock) }
        steps.append(.done)
        return steps
    }
    static func next(after step: DayPlanStep, eligible: [DayPlanStep]) -> DayPlanStep {
        eligible.first { $0.rawValue > step.rawValue } ?? .done
    }
    static func previous(before step: DayPlanStep, eligible: [DayPlanStep]) -> DayPlanStep? {
        eligible.last { $0.rawValue < step.rawValue }
    }

    // MARK: Totals

    /// Free capacity comes from `PlannerCapacity` (working hours minus calendar events). All-day events are
    /// information, not busy time, so they never reduce it.
    static func totals(_ tasks: [Record], events: [PlannerEvent], on day: Date, hours: WorkingHours?, calendar: Calendar = .current) -> DayPlanTotals {
        let work = todayTasks(tasks, day: TaskPlanner.dayKey(day, calendar: calendar), calendar: calendar)
        let capacity = TaskPlanner.capacity(work, events: events.filter { !$0.allDay }, on: day, hours: hours, calendar: calendar)
        return DayPlanTotals(taskCount: work.count, estimatedMinutes: work.compactMap(\.durationMinutes).reduce(0, +),
                             unestimatedCount: work.filter { $0.durationMinutes == nil }.count,
                             workingMinutes: capacity.workingMinutes, busyMinutes: capacity.busyMinutes)
    }

    /// The end of the latest timed, estimated task. Nil when nothing has both a time and an estimate.
    static func finishesAround(_ tasks: [Record], calendar: Calendar = .current) -> Date? {
        tasks.compactMap { task -> Date? in
            guard let start = TaskPlanning.start(task, calendar: calendar), let minutes = task.durationMinutes else { return nil }
            return start.addingTimeInterval(Double(minutes) * 60)
        }.max()
    }

    // MARK: Fit my day

    /// Places unscheduled, estimated tasks into the free slots of `day`, in priority then manual order.
    ///
    /// Slots are the working-hours window minus calendar events (all-day events do not block) minus tasks that
    /// already have a time, each padded by `buffer` minutes. Tasks go first-fit into the earliest slot that holds
    /// them, on a five-minute grid, never before `notBefore`. Every start is checked with `TaskPlanner.fields`
    /// (so an ambiguous clock time is skipped) and `TaskPlanner.conflicts`. Durations are real elapsed time, so a
    /// 23 or 25 hour day needs no special case. Tasks without an estimate, longer than any gap, or left without
    /// room stay unscheduled with a reason. Evening tasks stay untimed unless `placeEvening`, then they go after
    /// working hours and no later than 22:00.
    static func fit(tasks: [Record], events: [PlannerEvent], on day: Date, hours: WorkingHours?, eveningIDs: Set<String> = [],
                    placeEvening: Bool = false, notBefore: Date? = nil, buffer: Int = DayPlan.buffer, calendar: Calendar = .current) -> DayPlanFit {
        var result = DayPlanFit()
        let bounds = calendar.dateInterval(of: .day, for: day)
        let pad = Double(max(0, buffer)) * 60
        let timedEvents = events.filter { !$0.allDay && $0.end > $0.start }
        var busy = timedEvents.map(\.interval)
        var occupied: [Record] = []
        var candidates: [Record] = []
        for task in tasks where Planning.eligible(task) {
            if let start = TaskPlanning.start(task, calendar: calendar) {
                busy.append(DateInterval(start: start, end: start.addingTimeInterval(Double(task.durationMinutes ?? 0) * 60)))
                occupied.append(task)
            } else { candidates.append(task) }
        }
        let ordered = prioritised(candidates)
        let window = hours?.interval(on: day, calendar: calendar)
        let earliest = notBefore
        func region(_ interval: DateInterval?) -> DateInterval? {
            guard var interval else { return nil }
            if let earliest { interval = DateInterval(start: max(interval.start, earliest), end: max(interval.end, max(interval.start, earliest))) }
            return interval.duration > 0 ? interval : nil
        }
        var daytime = region(window).map { gaps(in: $0, busy: busy, pad: pad) } ?? []
        var evening: [DateInterval] = []
        if placeEvening, let window, let bounds,
           let end = TaskPlanning.wallTime(day: bounds.start, hour: eveningEndMinute / 60, minute: eveningEndMinute % 60, calendar: calendar),
           end > window.end, let area = region(DateInterval(start: window.end, end: min(end, bounds.end))) {
            evening = gaps(in: area, busy: busy, pad: pad)
        }
        let daytimeLongest = daytime.map(\.duration).max() ?? 0
        let eveningLongest = evening.map(\.duration).max() ?? 0
        let dayStart = bounds?.start ?? calendar.startOfDay(for: day)

        for task in ordered {
            guard let minutes = task.durationMinutes else { result.didntFit.append(.init(taskID: task.id, reason: .noEstimate)); continue }
            let isEvening = eveningIDs.contains(task.id)
            if isEvening && !placeEvening { result.didntFit.append(.init(taskID: task.id, reason: .evening)); continue }
            let length = Double(minutes) * 60
            var pool = isEvening ? evening : daytime
            var placed: Date?
            search: for index in pool.indices {
                var start = roundedUp(pool[index].start, from: dayStart)
                while start.addingTimeInterval(length) <= pool[index].end {
                    if (try? TaskPlanner.fields(task: task, start: start, calendar: calendar)) != nil,
                       TaskPlanner.conflicts(task: task, start: start, minutes: minutes, tasks: occupied, events: timedEvents, calendar: calendar).isEmpty {
                        placed = start
                        let next = roundedUp(start.addingTimeInterval(length + pad), from: dayStart)
                        if next < pool[index].end { pool[index] = DateInterval(start: next, end: pool[index].end) } else { pool.remove(at: index) }
                        break search
                    }
                    start = start.addingTimeInterval(Double(grid) * 60)
                }
            }
            if isEvening { evening = pool } else { daytime = pool }
            if let placed {
                result.placements.append(.init(taskID: task.id, start: placed, minutes: minutes))
                if let fields = try? TaskPlanner.fields(task: task, start: placed, calendar: calendar) {
                    var copy = task; for (key, value) in fields { copy[key] = value }
                    occupied.append(copy)
                }
                continue
            }
            let longest = isEvening ? eveningLongest : daytimeLongest
            let reason: DayPlanSkip = window == nil ? .noWorkingHours : (longest > 0 && length > longest ? .longerThanAnyGap : .noRoom)
            result.didntFit.append(.init(taskID: task.id, reason: reason))
        }
        result.placements.sort { $0.start == $1.start ? $0.taskID < $1.taskID : $0.start < $1.start }
        return result
    }

    /// Free intervals inside `region`, after removing each busy interval padded by `pad` seconds on both sides.
    static func gaps(in region: DateInterval, busy: [DateInterval], pad: TimeInterval) -> [DateInterval] {
        let blocked = busy.map { DateInterval(start: $0.start.addingTimeInterval(-pad), end: $0.end.addingTimeInterval(pad)) }
            .filter { $0.end > region.start && $0.start < region.end }.sorted { $0.start < $1.start }
        var cursor = region.start, free: [DateInterval] = []
        for block in blocked {
            if block.start > cursor { free.append(DateInterval(start: cursor, end: min(block.start, region.end))) }
            cursor = max(cursor, block.end)
            if cursor >= region.end { break }
        }
        if cursor < region.end { free.append(DateInterval(start: cursor, end: region.end)) }
        return free.filter { $0.duration > 0 }
    }

    /// The next point on the five-minute grid anchored at the start of the day, never earlier than `date`.
    static func roundedUp(_ date: Date, from dayStart: Date) -> Date {
        let step = Double(grid) * 60, elapsed = date.timeIntervalSince(dayStart)
        let steps = (elapsed / step - 1e-9).rounded(.up)
        return dayStart.addingTimeInterval(max(0, steps) * step)
    }

    /// The first start at which one task fits, for the "Place at…" suggestion. Nil when nothing fits.
    static func firstSlot(for task: Record, tasks: [Record], events: [PlannerEvent], on day: Date, hours: WorkingHours?, notBefore: Date? = nil, calendar: Calendar = .current) -> Date? {
        var solo = task
        for key in ["due_time", "time_zone", "scheduled_at"] { solo[key] = .null }
        return fit(tasks: [solo] + tasks.filter { $0.id != task.id && isTimed($0, calendar: calendar) }, events: events, on: day, hours: hours, notBefore: notBefore, calendar: calendar)
            .placements.first { $0.taskID == task.id }?.start
    }

    /// The task rows as they will be after the fit, for the preview timeline. Failures of `fields` cannot happen
    /// for a placement `fit` produced, but are skipped rather than trusted.
    static func fieldChanges(_ fit: DayPlanFit, tasks: [Record], calendar: Calendar = .current) -> [(task: Record, fields: [String: JSON])] {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return fit.placements.compactMap { placement in
            guard let task = byID[placement.taskID], let fields = try? TaskPlanner.fields(task: task, start: placement.start, calendar: calendar), !fields.isEmpty else { return nil }
            return (task, fields)
        }
    }
    static func applying(_ fit: DayPlanFit, to tasks: [Record], calendar: Calendar = .current) -> [Record] {
        let changes = Dictionary(fieldChanges(fit, tasks: tasks, calendar: calendar).map { ($0.task.id, $0.fields) }, uniquingKeysWith: { first, _ in first })
        return tasks.map { task in
            guard let fields = changes[task.id] else { return task }
            var copy = task; for (key, value) in fields { copy[key] = value }
            return copy
        }
    }

    static func estimateFields(minutes: Int) throws -> [String: JSON] {
        guard (1...10080).contains(minutes) else { throw PlannerFailure(message: "Choose an estimate between 1 minute and 7 days.") }
        return ["duration_minutes": .number(Double(minutes))]
    }

    // MARK: Header prompt

    /// Whether working hours are over at `now`. Without hours for today, the day ends at 18:00.
    static func isAfterWorkingHours(now: Date, hours: WorkingHours?, calendar: Calendar = .current) -> Bool {
        if let end = hours?.interval(on: now, calendar: calendar)?.end { return now >= end }
        guard let bounds = calendar.dateInterval(of: .day, for: now),
              let fallback = TaskPlanning.wallTime(day: bounds.start, hour: fallbackEndMinute / 60, minute: fallbackEndMinute % 60, calendar: calendar) else { return false }
        return now >= fallback
    }

    /// The Today header: a gentle prompt to plan until the day is planned, a shutdown prompt once working hours
    /// are over, and a quiet confirmation afterwards. Nil when there is nothing to offer.
    static func prompt(state: DayPlanState, now: Date, hours: WorkingHours?, hasWork: Bool, calendar: Calendar = .current) -> DayPlanPrompt? {
        if state.shutDown { return .shutDown }
        if isAfterWorkingHours(now: now, hours: hours, calendar: calendar) { return hasWork || state.planned ? .shutdown : nil }
        if state.planned { return .planned }
        return hasWork ? .plan : nil
    }

    // MARK: Planned-today state

    static func state(rows: [Record], account: String, today: String) -> DayPlanState {
        var state = DayPlanState(today: today)
        var seen = Set<String>()
        for row in rows where seen.insert(row.id).inserted && row.string("user_id") == account && !account.isEmpty {
            if row.id.hasPrefix(plannedPrefix) {
                let day = String(row.id.dropFirst(plannedPrefix.count))
                guard Dates.parse(day) != nil else { continue }
                if day == today { state.planned = true; state.plannedIDs = Planning.ids(row, account: account) } else if day < today { state.expiredKeys.append(row.id) }
            } else if row.id.hasPrefix(shutdownPrefix) {
                let day = String(row.id.dropFirst(shutdownPrefix.count))
                guard Dates.parse(day) != nil else { continue }
                if day == today { state.shutDown = true } else if day < today { state.expiredKeys.append(row.id) }
            }
        }
        state.expiredKeys.sort()
        return state
    }

    private static func upsert(_ key: String, ids: [String], rows: [Record], account: String) throws -> Mutation {
        guard !account.isEmpty else { throw AppFailure(message: "Open your workspace before planning tasks.") }
        guard key.utf8.count <= Planning.maxKeyBytes, ids.count <= Planning.maxIDs else { throw AppFailure(message: "This planning list could not be saved.") }
        let existing = rows.first { $0.id == key }
        guard existing == nil || existing?.string("user_id") == account else { throw AppFailure(message: "This planning list belongs to another workspace.") }
        return Mutation(table: table, recordID: key, method: existing == nil ? "POST" : "PATCH",
                        fields: ["id": .string(key), "user_id": .string(account), "ids": .array(ids.map(JSON.string))])
    }
    private static func cleanup(_ state: DayPlanState, rows: [Record], account: String) -> [Mutation] {
        state.expiredKeys.compactMap { key in
            rows.contains { $0.id == key && $0.string("user_id") == account } ? Mutation(table: table, recordID: key, method: "DELETE", fields: [:]) : nil
        }
    }

    /// Records that today was planned, with the ids planned. Nothing is written when the same ids are already saved.
    static func markPlanned(ids: [String], rows: [Record], account: String, today: String) throws -> [Mutation] {
        let state = state(rows: rows, account: account, today: today)
        var seen = Set<String>()
        let unique = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        if state.planned && state.plannedIDs == unique && state.expiredKeys.isEmpty { return [] }
        return cleanup(state, rows: rows, account: account) + [try upsert(plannedKey(today), ids: unique, rows: rows, account: account)]
    }
    static func markShutdown(rows: [Record], account: String, today: String) throws -> [Mutation] {
        let state = state(rows: rows, account: account, today: today)
        if state.shutDown && state.expiredKeys.isEmpty { return [] }
        return cleanup(state, rows: rows, account: account) + (state.shutDown ? [] : [try upsert(shutdownKey(today), ids: [], rows: rows, account: account)])
    }

    // MARK: Shutdown

    /// Root tasks completed on `day`, from their completion stamps.
    static func completedCount(_ tasks: [Record], on day: Date, calendar: Calendar = .current) -> Int {
        guard let bounds = calendar.dateInterval(of: .day, for: day) else { return 0 }
        return tasks.filter { task in
            guard task.completed, SubtaskTree.referencePath(task.id) == nil, let at = TaskPlanning.instant(task.string("completed_at")) else { return false }
            return at >= bounds.start && at < bounds.end
        }.count
    }

    /// Still-open work planned for today: due today, or listed in today's plan and not moved on. Order is kept.
    static func openForShutdown(_ tasks: [Record], plannedIDs: [String], day: String, calendar: Calendar = .current) -> [Record] {
        let planned = Set(plannedIDs)
        return tasks.filter { task in
            guard Planning.eligible(task) else { return false }
            let planDay = TaskPlanner.plannedDay(task, calendar: calendar)
            return planDay == day || (planned.contains(task.id) && !planDay.isEmpty && planDay <= day)
        }
    }

    static let closingLines = [
        "That's a day. Rest well.",
        "Good work today. Tomorrow can wait.",
        "The day is closed. Enjoy your evening.",
        "Nicely done. Step away with a clear head.",
        "You showed up today. That counts.",
    ]
    /// One line per civil day, stable while the sheet is open.
    static func closingLine(for day: String) -> String {
        let seed = day.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 10_007 }
        return closingLines[seed % closingLines.count]
    }
    /// "7-day streak", when goals are on and a daily streak is running.
    static func streakText(_ summary: MomentumSummary?) -> String? {
        guard let summary, summary.hasDailyGoal, summary.dailyStreak.length > 0 else { return nil }
        return "\(summary.dailyStreak.length)-day streak"
    }
}
