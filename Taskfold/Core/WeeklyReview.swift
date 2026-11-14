import Foundation

/// The guided Weekly review: Inbox, Slipped, Estimates, Projects without a next action, Someday and Next week.
/// Pure: no Store, no UI. Every step reuses logic that already exists (Inbox review, Smart reschedule, ActualTime,
/// the Someday review, DayPlan capacity); this file only decides what each step has to show.
///
/// "Last reviewed" storage (no server schema change): one reserved row in the per-account `view_orders` table, the
/// same approach as Someday, This Evening, Habits and actual time (see Planning.swift):
///   - `weekly:review`   `ids` holds one string, the instant of the last finished review as an ISO 8601 UTC time.
/// Older clients never read the key. A lost or unreadable row only means the review reads as "not reviewed yet".
enum WeeklyReviewStep: Int, CaseIterable, Sendable {
    case inbox, slipped, estimates, projects, someday, nextWeek
    /// 1-based and stable: `weeklyReviewStep-<number>` identifies a step even when others are skipped.
    var number: Int { rawValue + 1 }
    var identifier: String { "weeklyReviewStep-\(number)" }
    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .slipped: "Slipped last week"
        case .estimates: "Estimates"
        case .projects: "Next actions"
        case .someday: "Someday"
        case .nextWeek: "Next week"
        }
    }
    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .slipped: "arrow.uturn.forward"
        case .estimates: "timer"
        case .projects: "folder"
        case .someday: "moon.zzz"
        case .nextWeek: "calendar"
        }
    }
}

/// One day of the next-week glance: planned work against free time.
struct WeeklyDayLoad: Equatable, Identifiable, Sendable {
    enum State: String, Equatable, Sendable { case off, clear, comfortable, full, over }
    var day: String
    var date: Date
    var totals: DayPlanTotals
    var id: String { day }
    var state: State {
        if totals.workingMinutes == 0 { return .off }
        if totals.taskCount == 0 { return .clear }
        if totals.isOver { return .over }
        return totals.fraction >= 0.8 ? .full : .comfortable
    }
    var plannedMinutes: Int { totals.estimatedMinutes }
}

struct WeeklyLoad: Equatable, Sendable {
    var days: [WeeklyDayLoad]
    var plannedMinutes: Int { days.reduce(0) { $0 + $1.totals.estimatedMinutes } }
    var freeMinutes: Int { days.reduce(0) { $0 + $1.totals.freeMinutes } }
    var taskCount: Int { days.reduce(0) { $0 + $1.totals.taskCount } }
    var unestimatedCount: Int { days.reduce(0) { $0 + $1.totals.unestimatedCount } }
    var overDays: [WeeklyDayLoad] { days.filter { $0.state == .over } }
    /// The day with the most estimated work, nil when nothing is estimated.
    var busiest: WeeklyDayLoad? {
        days.filter { $0.totals.estimatedMinutes > 0 }.max { ($0.totals.estimatedMinutes, $1.day) < ($1.totals.estimatedMinutes, $0.day) }
    }
    /// A working day with the least planned work, for "room on Wednesday".
    var lightest: WeeklyDayLoad? {
        days.filter { $0.totals.workingMinutes > 0 }.min { ($0.totals.estimatedMinutes, $0.day) < ($1.totals.estimatedMinutes, $1.day) }
    }
    /// Calm and specific. Never a score.
    func message(calendar: Calendar = .current) -> String {
        if taskCount == 0 { return "Nothing is planned for the next 7 days yet." }
        func name(_ load: WeeklyDayLoad) -> String { load.date.formatted(.dateTime.weekday(.wide).locale(.current)) }
        let over = overDays
        if let first = over.first {
            let extra = DayPlan.duration(first.totals.overMinutes)
            if over.count == 1 { return "\(name(first)) looks full: about \(extra) more than your free time." }
            return "\(over.count) days look full, most of all \(name(over.max { $0.totals.overMinutes < $1.totals.overMinutes } ?? first)). Spread some work out if you can."
        }
        if let busiest, busiest.state == .full { return "\(name(busiest)) is your fullest day. The rest of the week has room." }
        return "The week looks comfortable: \(DayPlan.duration(plannedMinutes)) planned of \(DayPlan.duration(freeMinutes)) free."
    }
}

/// What the person did, for the done screen. Counts only; never a score.
struct WeeklyReviewProgress: Equatable, Sendable {
    var inboxCleared = 0
    var rescheduled = 0
    var movedToSomeday = 0
    var deleted = 0
    var projectsFixed = 0
    var somedayReviewed = 0
    var skipped = 0

    var isEmpty: Bool { inboxCleared + rescheduled + movedToSomeday + deleted + projectsFixed + somedayReviewed == 0 }
    private static func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
    var headline: String { isEmpty ? "You’re up to date" : "Review finished" }
    /// Short sentences for what changed. Empty when nothing did.
    var lines: [String] {
        var result: [String] = []
        if inboxCleared > 0 { result.append(Self.count(inboxCleared, "inbox task sorted", "inbox tasks sorted")) }
        if rescheduled > 0 { result.append(Self.count(rescheduled, "slipped task rescheduled", "slipped tasks rescheduled")) }
        if movedToSomeday > 0 { result.append(Self.count(movedToSomeday, "task moved to Someday", "tasks moved to Someday")) }
        if deleted > 0 { result.append(Self.count(deleted, "task deleted", "tasks deleted")) }
        if projectsFixed > 0 { result.append(Self.count(projectsFixed, "project given a next action", "projects given a next action")) }
        if somedayReviewed > 0 { result.append(Self.count(somedayReviewed, "Someday idea reviewed", "Someday ideas reviewed")) }
        return result
    }
    var summary: String { isEmpty ? "Nothing needed changing this week." : lines.joined(separator: ". ") + "." }
}

enum WeeklyReview {
    static let table = Planning.table
    static let key = "weekly:review"
    /// "Slipped last week": planned in the 7 days before today.
    static let lookbackDays = 7
    static let nextWeekDays = 7
    static let intervalDays = 7
    /// The reminder defaults: Friday (Calendar weekday 6) at 16:00.
    static let defaultReminderWeekday = 6
    static let defaultReminderMinutes = 16 * 60
    static let reminderIdentifier = "taskfold.weekly-review"

    static func isKey(_ key: String) -> Bool { key == Self.key }

    // MARK: Last reviewed

    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]; return formatter
    }
    /// Tolerant read. A row of another account, a malformed value or no row reads as never reviewed.
    static func lastReviewed(rows: [Record], account: String) -> Date? {
        guard !account.isEmpty, let row = rows.first(where: { $0.id == key }), row.string("user_id").lowercased() == account.lowercased(),
              case .array(let values) = row["ids"], case .string(let text)? = values.first else { return nil }
        return formatter().date(from: text)
    }
    /// The change that stamps a finished review. Refuses another workspace's row.
    static func markReviewed(at now: Date, rows: [Record], account: String) throws -> Mutation {
        guard !account.isEmpty else { throw AppFailure(message: "Open your workspace before finishing a review.") }
        let existing = rows.first { $0.id == key }
        guard existing == nil || existing?.string("user_id").lowercased() == account.lowercased() else {
            throw AppFailure(message: "This review record belongs to another workspace.")
        }
        return Mutation(table: table, recordID: key, method: existing == nil ? "POST" : "PATCH",
                        fields: ["id": .string(key), "user_id": .string(account), "ids": .array([.string(formatter().string(from: now))])])
    }
    /// Whole calendar days since the last review, nil when never reviewed.
    static func daysSince(_ last: Date?, now: Date, calendar: Calendar = .current) -> Int? {
        guard let last else { return nil }
        return max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: last), to: calendar.startOfDay(for: now)).day ?? 0)
    }
    static func isDue(lastReviewed: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let days = daysSince(lastReviewed, now: now, calendar: calendar) else { return true }
        return days >= intervalDays
    }
    /// "Not reviewed yet", "Reviewed today", "Reviewed yesterday", "Reviewed 3 days ago".
    static func statusText(lastReviewed: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let days = daysSince(lastReviewed, now: now, calendar: calendar) else { return "Not reviewed yet" }
        switch days { case 0: return "Reviewed today"; case 1: return "Reviewed yesterday"; default: return "Reviewed \(days) days ago" }
    }

    // MARK: Reminder

    /// The next time the weekly reminder fires: the first `weekday` (Calendar numbering) at `minutes` after `now`.
    static func nextReminder(after now: Date, weekday: Int, minutes: Int, calendar: Calendar = .current) -> Date? {
        guard (1...7).contains(weekday), (0..<1440).contains(minutes) else { return nil }
        var components = DateComponents(); components.weekday = weekday; components.hour = minutes / 60; components.minute = minutes % 60
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
    }

    // MARK: Steps

    /// The steps worth showing, in order. Empty steps are left out so the review stays quick; Next week always stays.
    static func steps(inbox: Int, slipped: Int, estimatesReliable: Bool, projectsWithoutNext: Int, somedayStale: Int) -> [WeeklyReviewStep] {
        var result: [WeeklyReviewStep] = []
        if inbox > 0 { result.append(.inbox) }
        if slipped > 0 { result.append(.slipped) }
        if estimatesReliable { result.append(.estimates) }
        if projectsWithoutNext > 0 { result.append(.projects) }
        if somedayStale > 0 { result.append(.someday) }
        result.append(.nextWeek)
        return result
    }

    // MARK: Slipped last week

    /// Open, ordinary, top-level tasks planned (due or scheduled) in the 7 days before today and still open. Tasks held
    /// for This Evening are kept on purpose and are left out. Order: priority, nearest deadline, oldest date.
    static func slipped(_ tasks: [Record], today: String, held: Set<String> = [], calendar: Calendar = .current,
                        isEditable: (Record) -> Bool = { _ in true }) -> [Record] {
        guard let todayDate = Dates.parse(today, calendar: calendar), let from = calendar.date(byAdding: .day, value: -lookbackDays, to: todayDate) else { return [] }
        let first = TaskPlanner.dayKey(from, calendar: calendar)
        let rows = tasks.filter { task in
            guard Planning.eligible(task), !held.contains(task.id), isEditable(task) else { return false }
            let day = TaskPlanner.plannedDay(task, calendar: calendar)
            return !day.isEmpty && day >= first && day < today
        }
        return SmartReschedule.prioritised(rows, calendar: calendar)
    }

    // MARK: Projects without a next action

    /// Active personal projects with no open, undated task: nothing waiting to be picked up. Archived projects, shared
    /// team projects (Quick Add cannot write there) and Someday-filed tasks do not count. Sorted by name.
    static func projectsWithoutNextAction(projects: [Record], tasks: [Record], someday: Set<String> = [], account: String,
                                          calendar: Calendar = .current) -> [Record] {
        let archived = ProjectOrganization.archivedIDs(in: projects)
        var withNext = Set<String>()
        for task in tasks where Planning.eligible(task) && !someday.contains(task.id) && TaskPlanner.plannedDay(task, calendar: calendar).isEmpty {
            let project = task.string("project_id")
            if !project.isEmpty { withNext.insert(project) }
        }
        return projects.filter { project in
            !project.id.isEmpty && !archived.contains(project.id) && project["team_id"] == .null && !withNext.contains(project.id)
                && (project.string("user_id").isEmpty || project.string("user_id").lowercased() == account.lowercased())
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Next week

    /// The 7 days after today: estimated work against working hours minus timed calendar events (`DayPlan.totals`).
    static func load(tasks: [Record], events: [PlannerEvent], hours: WorkingHours?, now: Date, calendar: Calendar = .current) -> WeeklyLoad {
        let start = calendar.startOfDay(for: now)
        let days = (1...nextWeekDays).compactMap { offset -> WeeklyDayLoad? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return WeeklyDayLoad(day: TaskPlanner.dayKey(date, calendar: calendar), date: date,
                                 totals: DayPlan.totals(tasks, events: events, on: date, hours: hours, calendar: calendar))
        }
        return WeeklyLoad(days: days)
    }
}
