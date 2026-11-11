import XCTest
@testable import TaskfoldCore

final class LayoutGridTests: XCTestCase {
    private func calendar(_ zone: String = "UTC", firstWeekday: Int = 1) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!; calendar.firstWeekday = firstWeekday; calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }
    private func date(_ iso: String, _ zone: String = "UTC") -> Date { TaskPlanning.instant(iso)! }
    private func task(_ id: String, due: String? = nil, priority: Int = 4, completed: Bool = false, time: String? = nil, project: String = "", extra: [String: JSON] = [:]) -> Record {
        var fields: [String: JSON] = ["id": .string(id), "title": .string("Task " + id), "priority": .number(Double(priority)), "completed": .bool(completed), "project_id": .string(project)]
        if let due { fields["due_date"] = .string(due) }
        if let time { fields["due_time"] = .string(time) }
        for (key, value) in extra { fields[key] = value }
        return Record(fields)
    }

    // MARK: Layout validity

    func testLayoutMatrixMatchesTheSpec() {
        XCTAssertEqual(TaskLayout.available(for: .project("p")), [.list, .board, .calendar])
        XCTAssertEqual(TaskLayout.available(for: .upcoming), [.list, .board, .calendar])
        XCTAssertEqual(TaskLayout.available(for: .today), [.list, .board])
        XCTAssertEqual(TaskLayout.available(for: .label("l")), [.list, .board])
        XCTAssertEqual(TaskLayout.available(for: .inbox), [.list, .board])
        XCTAssertEqual(TaskLayout.available(for: .all), [.list])
        XCTAssertEqual(TaskLayout.available(for: .completed), [.list])
    }
    func testSavedFiltersNeverOfferCalendar() {
        XCTAssertEqual(TaskLayout.available(for: .saved("v")), [.list, .board])
        XCTAssertEqual(TaskLayout.resolved("calendar", for: .saved("v")), .list)
    }
    func testInvalidStoredValueShowsListWithoutBeingRewritten() {
        XCTAssertEqual(TaskLayout.resolved("calendar", for: .today), .list)
        XCTAssertEqual(TaskLayout.resolved("board", for: .completed), .list)
        XCTAssertEqual(TaskLayout.resolved("garbage", for: .project("p")), .list)
        XCTAssertEqual(TaskLayout.resolved("calendar", for: .project("p")), .calendar)
        XCTAssertEqual(TaskLayout.resolved("board", for: .inbox), .board)
    }
    func testLayoutSymbols() {
        XCTAssertEqual(TaskLayout.allCases.map(\.symbol), ["list.bullet", "rectangle.split.3x1", "calendar"])
    }

    // MARK: Overflow

    func testOverflowShowsThreeTitlesThenPlusN() {
        XCTAssertEqual(MonthGrid.overflow(count: 0).extra, 0)
        XCTAssertEqual(MonthGrid.overflow(count: 3).extra, 0)
        XCTAssertEqual(MonthGrid.overflow(count: 4).shown, 3)
        XCTAssertEqual(MonthGrid.overflow(count: 4).extra, 1)
        XCTAssertEqual(MonthGrid.overflow(count: 10, limit: 2).extra, 8)
    }
    func testUndatedFooterWording() {
        XCTAssertNil(MonthGrid.undatedFooter(0))
        XCTAssertEqual(MonthGrid.undatedFooter(1), "1 task without a date")
        XCTAssertEqual(MonthGrid.undatedFooter(3), "3 tasks without a date")
    }

    // MARK: Month grid

    func testNovember2026WithSundayStart() {
        let cal = calendar()
        let grid = MonthGrid.build(month: date("2026-11-15T12:00:00Z"), tasks: [], today: date("2026-11-11T12:00:00Z"), calendar: cal)
        XCTAssertEqual(grid.weekdaySymbols.first, "Sun")
        XCTAssertEqual(grid.weeks.count, 5)
        XCTAssertTrue(grid.weeks.allSatisfy { $0.count == 7 })
        XCTAssertEqual(grid.weeks[0][0].id, "2026-11-01")
        XCTAssertEqual(grid.weeks[4][1].id, "2026-11-30")
        XCTAssertEqual(grid.cells.filter(\.inMonth).count, 30)
        XCTAssertEqual(grid.cells.filter(\.isToday).map(\.id), ["2026-11-11"])
    }
    func testMondayStartShiftsTheLeadingDaysAndHeader() {
        let cal = calendar(firstWeekday: 2)
        let grid = MonthGrid.build(month: date("2026-11-15T12:00:00Z"), tasks: [], today: date("2026-11-11T12:00:00Z"), calendar: cal)
        XCTAssertEqual(grid.weekdaySymbols.first, "Mon")
        XCTAssertEqual(grid.weekdaySymbols.last, "Sun")
        XCTAssertEqual(grid.weeks[0][0].id, "2026-10-26")
        XCTAssertFalse(grid.weeks[0][0].inMonth)
        XCTAssertEqual(grid.weeks[0][6].id, "2026-11-01")
        XCTAssertEqual(grid.weeks.count, 6)
    }
    func testFebruaryOfALeapYearOnASundayStartFitsFourWeeks() {
        let cal = calendar()
        let grid = MonthGrid.build(month: date("2026-02-10T12:00:00Z"), tasks: [], today: date("2026-02-10T12:00:00Z"), calendar: cal)
        XCTAssertEqual(grid.weeks.count, 4) // 1 Feb 2026 is a Sunday and the month has 28 days
        let leap = MonthGrid.build(month: date("2028-02-10T12:00:00Z"), tasks: [], today: date("2028-02-10T12:00:00Z"), calendar: cal)
        XCTAssertEqual(leap.cells.filter(\.inMonth).count, 29)
    }
    func testTasksLandOnTheirDueDayWithOverflowAndOverdue() {
        let cal = calendar()
        let tasks = (1...5).map { task("a\($0)", due: "2026-11-20") } + [task("old", due: "2026-11-05"), task("done", due: "2026-11-05", completed: true)]
        let grid = MonthGrid.build(month: date("2026-11-01T12:00:00Z"), tasks: tasks, today: date("2026-11-11T12:00:00Z"), calendar: cal)
        let busy = grid.cell("2026-11-20")!
        XCTAssertEqual(busy.tasks.count, 5)
        XCTAssertEqual(busy.visibleTasks.count, 3)
        XCTAssertEqual(busy.overflow, 2)
        XCTAssertEqual(busy.overdueCount, 0)
        let past = grid.cell("2026-11-05")!
        XCTAssertEqual(past.overdueCount, 1)
        XCTAssertTrue(past.isOverdue(tasks[5]))
        XCTAssertFalse(past.isOverdue(tasks[6]))
    }
    func testCellOrderIsPriorityThenTimeThenSourceOrder() {
        let cal = calendar()
        let tasks = [task("low", due: "2026-11-12"), task("late", due: "2026-11-12", priority: 2, time: "15:00"), task("early", due: "2026-11-12", priority: 2, time: "08:00"), task("urgent", due: "2026-11-12", priority: 1)]
        let grid = MonthGrid.build(month: date("2026-11-01T12:00:00Z"), tasks: tasks, today: date("2026-11-11T12:00:00Z"), calendar: cal)
        XCTAssertEqual(grid.cell("2026-11-12")!.tasks.map(\.id), ["urgent", "early", "late", "low"])
    }
    func testUndatedTasksAreCountedNotPlaced() {
        let cal = calendar()
        let tasks = [task("a"), task("b"), task("c"), task("d", completed: true), task("e", due: "2026-11-02")]
        let grid = MonthGrid.build(month: date("2026-11-01T12:00:00Z"), tasks: tasks, today: date("2026-11-11T12:00:00Z"), calendar: cal)
        XCTAssertEqual(grid.undatedCount, 3)
        XCTAssertEqual(grid.undatedFooter, "3 tasks without a date")
        XCTAssertEqual(grid.cells.flatMap(\.tasks).map(\.id), ["e"])
    }
    func testRecurringTaskShowsOnlyItsNextOccurrence() {
        let cal = calendar()
        let weekly = task("weekly", due: "2026-11-18", extra: ["is_recurring": .bool(true), "recurrence_pattern": .object(["type": .string("weekly"), "interval": .number(1)])])
        let grid = MonthGrid.build(month: date("2026-11-01T12:00:00Z"), tasks: [weekly], today: date("2026-11-11T12:00:00Z"), calendar: cal)
        XCTAssertEqual(grid.cells.filter { !$0.tasks.isEmpty }.map(\.id), ["2026-11-18"])
    }
    func testDuplicateRowsAppearOnce() {
        let cal = calendar()
        let one = task("same", due: "2026-11-12")
        let grid = MonthGrid.build(month: date("2026-11-01T12:00:00Z"), tasks: [one, one], today: date("2026-11-11T12:00:00Z"), calendar: cal)
        XCTAssertEqual(grid.cell("2026-11-12")!.tasks.count, 1)
    }
    func testSpringForwardMonthKeepsEveryDayOnce() {
        // 8 March 2026: US clocks skip an hour. Cells must still be consecutive civil days.
        let cal = calendar("America/New_York")
        let grid = MonthGrid.build(month: date("2026-03-15T16:00:00Z"), tasks: [task("x", due: "2026-03-08"), task("y", due: "2026-03-09")], today: date("2026-03-08T16:00:00Z"), calendar: cal)
        let ids = grid.cells.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(grid.cell("2026-03-08")?.tasks.map(\.id), ["x"])
        XCTAssertEqual(grid.cell("2026-03-09")?.tasks.map(\.id), ["y"])
        XCTAssertEqual(grid.cell("2026-03-08")?.isToday, true)
        XCTAssertEqual(ids.first, "2026-03-01")
    }
    func testFallBackMonthKeepsEveryDayOnce() {
        // 25 October 2026: Copenhagen repeats an hour.
        let cal = calendar("Europe/Copenhagen", firstWeekday: 2)
        let grid = MonthGrid.build(month: date("2026-10-15T10:00:00Z"), tasks: [task("x", due: "2026-10-25")], today: date("2026-10-25T10:00:00Z"), calendar: cal)
        let ids = grid.cells.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids.first, "2026-09-28")
        XCTAssertEqual(grid.cell("2026-10-25")?.tasks.count, 1)
        XCTAssertEqual(ids.filter { $0.hasPrefix("2026-10") }.count, 31)
    }
    func testMidnightDSTZoneStillHasAllDays() {
        // Some zones change clocks at midnight, so 00:00 does not exist on that day.
        let cal = calendar("America/Santiago")
        let grid = MonthGrid.build(month: date("2026-09-15T12:00:00Z"), tasks: [], today: date("2026-09-15T12:00:00Z"), calendar: cal)
        XCTAssertEqual(grid.cells.filter(\.inMonth).count, 30)
        XCTAssertEqual(Set(grid.cells.map(\.id)).count, grid.cells.count)
    }
    func testMonthShifting() {
        let cal = calendar()
        let next = MonthGrid.shifted(date("2026-12-20T12:00:00Z"), by: 1, calendar: cal)
        XCTAssertEqual(TaskPlanner.dayKey(next, calendar: cal), "2027-01-01")
        let back = MonthGrid.shifted(date("2026-01-20T12:00:00Z"), by: -1, calendar: cal)
        XCTAssertEqual(TaskPlanner.dayKey(back, calendar: cal), "2025-12-01")
    }
    func testBusyDaysIgnoreCompletedAndUndated() {
        let cal = calendar()
        let busy = MonthGrid.busyDays([task("a", due: "2026-11-12"), task("b", due: "2026-11-13", completed: true), task("c")], calendar: cal)
        XCTAssertEqual(busy, ["2026-11-12"])
    }

    // MARK: Upcoming board

    func testUpcomingHasSevenDayColumnsAndNoOverdueWhenNothingIsLate() {
        let cal = calendar()
        let columns = UpcomingColumns.build(tasks: [task("a", due: "2026-11-12")], today: date("2026-11-11T12:00:00Z"), calendar: cal)
        XCTAssertEqual(columns.count, 7)
        XCTAssertEqual(columns.first?.kind, .day("2026-11-11"))
        XCTAssertEqual(columns.map(\.title), ["Today", "Tomorrow", "Friday", "Saturday", "Sunday", "Monday", "Tuesday"])
        XCTAssertEqual(columns[1].tasks.map(\.id), ["a"])
        XCTAssertEqual(columns[0].subtitle, "Nov 11")
    }
    func testUpcomingPutsOverdueFirstAndKeepsCompletedPastWorkOut() {
        let cal = calendar()
        let tasks = [task("late2", due: "2026-11-09"), task("late1", due: "2026-11-02"), task("doneLate", due: "2026-11-03", completed: true), task("today", due: "2026-11-11")]
        let columns = UpcomingColumns.build(tasks: tasks, today: date("2026-11-11T12:00:00Z"), calendar: cal)
        XCTAssertEqual(columns.first?.kind, .overdue)
        XCTAssertEqual(columns.first?.tasks.map(\.id), ["late1", "late2"])
        XCTAssertEqual(columns.count, 8)
        XCTAssertEqual(columns[1].tasks.map(\.id), ["today"])
    }
    func testUpcomingAppendsLaterDaysThatHoldWorkAndSkipsUndated() {
        let cal = calendar()
        let tasks = [task("far", due: "2026-12-24"), task("nodate"), task("near", due: "2026-11-14")]
        let columns = UpcomingColumns.build(tasks: tasks, today: date("2026-11-11T12:00:00Z"), calendar: cal)
        XCTAssertEqual(columns.count, 8)
        XCTAssertEqual(columns.last?.kind, .day("2026-12-24"))
        XCTAssertEqual(columns.last?.tasks.map(\.id), ["far"])
        XCTAssertFalse(columns.flatMap(\.tasks).contains { $0.id == "nodate" })
    }
    func testUpcomingKeepsTimeOfDayTasksOnTheirDay() {
        let cal = calendar()
        let columns = UpcomingColumns.build(tasks: [task("timed", due: "2026-11-13", time: "09:30")], today: date("2026-11-11T12:00:00Z"), calendar: cal)
        XCTAssertEqual(columns.first { $0.kind == .day("2026-11-13") }?.tasks.map(\.id), ["timed"])
    }
    func testUpcomingAcrossSpringForwardHasSevenDistinctDays() {
        let cal = calendar("America/New_York")
        let columns = UpcomingColumns.build(tasks: [], today: date("2026-03-05T17:00:00Z"), calendar: cal)
        XCTAssertEqual(columns.map(\.id), ["day:2026-03-05", "day:2026-03-06", "day:2026-03-07", "day:2026-03-08", "day:2026-03-09", "day:2026-03-10", "day:2026-03-11"])
    }

    // MARK: Project columns (Today and labels)

    func testProjectColumnsPutInboxFirstThenProjectOrder() {
        let projects = [Record(["id": .string("b"), "name": .string("Beta")]), Record(["id": .string("a"), "name": .string("Alpha")]), Record(["id": .string("empty"), "name": .string("Empty")])]
        let tasks = [task("1", project: "a"), task("2", project: "b"), task("3"), task("4", project: "b"), task("5", project: "gone")]
        let columns = ProjectColumns.build(tasks: tasks, projects: projects)
        XCTAssertEqual(columns.map(\.title), ["Inbox", "Beta", "Alpha", "Shared project"])
        XCTAssertEqual(columns[1].tasks.map(\.id), ["2", "4"])
        XCTAssertEqual(columns[1].kind, .project("b"))
    }
    func testOpenCountSkipsCompletedAndHeadings() {
        let column = LayoutColumn(id: "x", kind: .overdue, title: "x", subtitle: nil, tasks: [task("a"), task("b", completed: true), task("h", extra: ["is_heading": .bool(true)])])
        XCTAssertEqual(column.openCount, 1)
    }
}
