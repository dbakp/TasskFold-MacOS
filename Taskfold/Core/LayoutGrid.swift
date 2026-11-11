import Foundation

/// The three ways a task scope can be laid out. The stored value lives in `view_preferences.layout`
/// (or `saved_views.layout`); this type only decides which values a scope may show.
enum TaskLayout: String, CaseIterable, Sendable, Identifiable {
    case list, board, calendar
    var id: String { rawValue }
    var title: String { switch self { case .list: return "List"; case .board: return "Board"; case .calendar: return "Calendar" } }
    var symbol: String { switch self { case .list: return "list.bullet"; case .board: return "rectangle.split.3x1"; case .calendar: return "calendar" } }
    /// Layouts valid for a scope. Saved filters stay list/board because older clients reject `calendar` there.
    static func available(for scope: TaskScope) -> [TaskLayout] {
        switch scope {
        case .project, .upcoming: return [.list, .board, .calendar]
        case .today, .label, .inbox, .saved: return [.list, .board]
        case .all, .completed: return [.list]
        }
    }
    /// A stored value that is not valid for the scope reads as List; the stored value itself is never rewritten.
    static func resolved(_ stored: String, for scope: TaskScope) -> TaskLayout {
        guard let layout = TaskLayout(rawValue: stored), available(for: scope).contains(layout) else { return .list }
        return layout
    }
}

/// One board column: a day, a project or a section, with the tasks it holds.
struct LayoutColumn: Identifiable, Equatable {
    enum Kind: Equatable { case overdue, day(String), project(String), section(project: String, section: String) }
    var id: String
    var kind: Kind
    var title: String
    var subtitle: String?
    var tasks: [Record]
    var openCount: Int { tasks.filter { TaskKind.mayComplete($0) && !$0.completed }.count }
}

/// Upcoming as a board: an Overdue column first when needed, then one column per day for the next seven
/// days (empty days stay so they can receive drops), then any later day that already holds work.
enum UpcomingColumns {
    static func build(tasks: [Record], today: Date = Date(), days: Int = 7, calendar: Calendar = .current) -> [LayoutColumn] {
        let todayKey = TaskPlanner.dayKey(today, calendar: calendar)
        var read = TaskPlannedDayRead(calendar: calendar)
        var overdue: [Record] = [], byDay: [String: [Record]] = [:], seen = Set<String>()
        for task in tasks where seen.insert(task.id).inserted {
            let day = read.day(task)
            guard !day.isEmpty else { continue }
            if day < todayKey { if !task.completed && TaskKind.mayComplete(task) { overdue.append(task) }; continue }
            byDay[day, default: []].append(task)
        }
        var columns: [LayoutColumn] = []
        if !overdue.isEmpty {
            columns.append(LayoutColumn(id: "overdue", kind: .overdue, title: "Overdue", subtitle: nil, tasks: overdue.sorted { read.day($0) < read.day($1) }))
        }
        let anchor = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: today) ?? today
        let near = (0..<max(0, days)).compactMap { calendar.date(byAdding: .day, value: $0, to: anchor) }.map { TaskPlanner.dayKey($0, calendar: calendar) }
        let keys = Set(near).union(byDay.keys).sorted()
        for key in keys {
            columns.append(LayoutColumn(id: "day:" + key, kind: .day(key), title: dayTitle(key, today: todayKey, calendar: calendar), subtitle: dayDetail(key, calendar: calendar), tasks: byDay[key] ?? []))
        }
        return columns
    }
    static func dayTitle(_ key: String, today: String, calendar: Calendar = .current) -> String {
        guard let date = Dates.parse(key, calendar: calendar), let todayDate = Dates.parse(today, calendar: calendar) else { return key }
        if key == today { return "Today" }
        if calendar.dateComponents([.day], from: todayDate, to: date).day == 1 { return "Tomorrow" }
        return calendar.weekdaySymbols[calendar.component(.weekday, from: date) - 1]
    }
    static func dayDetail(_ key: String, calendar: Calendar = .current) -> String? {
        guard let date = Dates.parse(key, calendar: calendar) else { return nil }
        return calendar.shortMonthSymbols[calendar.component(.month, from: date) - 1] + " " + String(calendar.component(.day, from: date))
    }
}

/// Today and label boards: one column per project (the Inbox first), only for projects that hold tasks.
enum ProjectColumns {
    static let inboxID = "project:"
    static func build(tasks: [Record], projects: [Record]) -> [LayoutColumn] {
        var byProject: [String: [Record]] = [:], seen = Set<String>()
        for task in tasks where seen.insert(task.id).inserted { byProject[task.string("project_id"), default: []].append(task) }
        var columns: [LayoutColumn] = []
        if let inbox = byProject[""], !inbox.isEmpty {
            columns.append(LayoutColumn(id: inboxID, kind: .project(""), title: "Inbox", subtitle: nil, tasks: inbox))
        }
        var used = Set([""])
        for project in projects where byProject[project.id] != nil && used.insert(project.id).inserted {
            columns.append(LayoutColumn(id: "project:" + project.id, kind: .project(project.id), title: project.name, subtitle: nil, tasks: byProject[project.id] ?? []))
        }
        for id in byProject.keys.sorted() where used.insert(id).inserted {
            columns.append(LayoutColumn(id: "project:" + id, kind: .project(id), title: "Shared project", subtitle: nil, tasks: byProject[id] ?? []))
        }
        return columns
    }
}

/// A month laid out as whole weeks, honouring the calendar's first weekday. Each task appears once, on the
/// day it is next due, so a recurring task shows its upcoming occurrence only. Tasks without a date are
/// counted for the footer instead of being placed.
struct MonthGrid: Equatable {
    struct Cell: Identifiable, Equatable {
        let id: String
        let date: Date
        let dayNumber: Int
        let inMonth: Bool
        let isToday: Bool
        let isPast: Bool
        let tasks: [Record]
        let titleLimit: Int
        var visibleTasks: [Record] { Array(tasks.prefix(titleLimit)) }
        var overflow: Int { MonthGrid.overflow(count: tasks.count, limit: titleLimit).extra }
        /// Open tasks on a past day are overdue.
        func isOverdue(_ task: Record) -> Bool { isPast && !task.completed && TaskKind.mayComplete(task) }
        var overdueCount: Int { tasks.filter(isOverdue).count }
    }
    let monthStart: Date
    let weekdaySymbols: [String]
    let weeks: [[Cell]]
    let undatedCount: Int

    var cells: [Cell] { weeks.flatMap { $0 } }
    var undatedFooter: String? { MonthGrid.undatedFooter(undatedCount) }
    func cell(_ day: String) -> Cell? { cells.first { $0.id == day } }

    static func overflow(count: Int, limit: Int = 3) -> (shown: Int, extra: Int) {
        let shown = max(0, min(count, limit)); return (shown, max(0, count - shown))
    }
    static func undatedFooter(_ count: Int) -> String? {
        count > 0 ? "\(count) \(count == 1 ? "task" : "tasks") without a date" : nil
    }
    /// The first moment of the month `offset` months from `month`.
    static func shifted(_ month: Date, by offset: Int, calendar: Calendar = .current) -> Date {
        let start = calendar.dateInterval(of: .month, for: month)?.start ?? month
        return calendar.date(byAdding: .month, value: offset, to: start) ?? start
    }
    /// Days that hold at least one open task, for dot indicators.
    static func busyDays(_ tasks: [Record], calendar: Calendar = .current) -> Set<String> {
        var read = TaskPlannedDayRead(calendar: calendar), days = Set<String>()
        for task in tasks where !task.completed { let day = read.day(task); if !day.isEmpty { days.insert(day) } }
        return days
    }

    static func build(month: Date, tasks: [Record], today: Date = Date(), calendar: Calendar = .current, titleLimit: Int = 3) -> MonthGrid {
        let first = calendar.dateInterval(of: .month, for: month)?.start ?? calendar.startOfDay(for: month)
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let length = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        let weekCount = (lead + length + 6) / 7
        // Noon anchors keep every cell on the right civil day across 23- and 25-hour days.
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: first) ?? first
        let todayKey = TaskPlanner.dayKey(today, calendar: calendar)
        var read = TaskPlannedDayRead(calendar: calendar)
        var byDay: [String: [Record]] = [:], seen = Set<String>(), undated = 0
        for task in tasks where seen.insert(task.id).inserted {
            let day = read.day(task)
            if day.isEmpty { if !task.completed && TaskKind.mayComplete(task) { undated += 1 }; continue }
            byDay[day, default: []].append(task)
        }
        let monthNumber = calendar.component(.month, from: first)
        var weeks: [[Cell]] = []
        for week in 0..<weekCount {
            var row: [Cell] = []
            for weekday in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: week * 7 + weekday - lead, to: noon) else { continue }
                let key = TaskPlanner.dayKey(date, calendar: calendar)
                let ordered = (byDay[key] ?? []).enumerated().sorted { a, b in
                    if a.element.priority != b.element.priority { return a.element.priority < b.element.priority }
                    let ta = a.element.string("due_time"), tb = b.element.string("due_time")
                    if ta != tb { return ta.isEmpty ? false : tb.isEmpty ? true : ta < tb }
                    return a.offset < b.offset
                }.map(\.element)
                row.append(Cell(id: key, date: date, dayNumber: calendar.component(.day, from: date), inMonth: calendar.component(.month, from: date) == monthNumber,
                                isToday: key == todayKey, isPast: key < todayKey, tasks: ordered, titleLimit: titleLimit))
            }
            weeks.append(row)
        }
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let rotated = (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
        return MonthGrid(monthStart: first, weekdaySymbols: rotated, weeks: weeks, undatedCount: undated)
    }
}
