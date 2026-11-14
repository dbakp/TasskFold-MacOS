import XCTest
@testable import TaskfoldCore

final class IntentLogicTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    // Thursday 12 November 2026.
    private let now = Date(timeIntervalSince1970: 1_794_484_800)
    private let today = "2026-11-12"
    private let a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1", b = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2", c = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3"
    private func task(_ id: String, _ title: String, due: String = "", project: String = "", priority: Int = 4, notes: String = "", done: Bool = false) -> Record {
        Record(["id": .string(id), "title": .string(title), "description": .string(notes), "due_date": due.isEmpty ? .null : .string(due),
                "project_id": project.isEmpty ? .null : .string(project), "priority": .number(Double(priority)), "completed": .bool(done)])
    }
    private var projects: [Record] {
        [Record(["id": .string("work"), "name": .string("Work")]), Record(["id": .string("sub"), "name": .string("Reports"), "parent_id": .string("work")]),
         Record(["id": .string("home"), "name": .string("Home")])]
    }
    private var fixture: [Record] {
        [task(a, "Send the invoice", due: "2026-11-10", project: "work", priority: 1), task(b, "Plan the offsite", due: today, project: "sub", notes: "Book the venue"),
         task(c, "Water plants", due: "2026-11-14", project: "home"), task("d", "Someday idea"), task("e", "Finished thing", due: today, done: true),
         task("f", "Far future", due: "2026-12-25", project: "home"), task("g", "Next week", due: "2026-11-19")]
    }

    func testSearchMatchesTitleOrNotesAllWordsAndSkipsCompleted() {
        XCTAssertEqual(IntentTaskSelection.search(fixture, text: "invoice").map(\.id), [a])
        XCTAssertEqual(IntentTaskSelection.search(fixture, text: "VENUE book").map(\.id), [b], "Notes count, order and case do not")
        XCTAssertTrue(IntentTaskSelection.search(fixture, text: "finished").isEmpty)
        XCTAssertTrue(IntentTaskSelection.search(fixture, text: "   ").isEmpty)
        XCTAssertEqual(IntentTaskSelection.search(fixture, text: "the", limit: 1).count, 1)
    }

    func testGetByFilterTodayOverdueNextSevenDaysAndProject() {
        func ids(_ kind: IntentListFilter, project: String? = nil) -> [String] {
            IntentTaskSelection.filter(fixture, kind, today: today, calendar: calendar, project: project, projects: projects).map(\.id)
        }
        XCTAssertEqual(ids(.today), [b])
        XCTAssertEqual(ids(.overdue), [a])
        XCTAssertEqual(ids(.upcoming), [b, c], "Today through the sixth day after it")
        XCTAssertEqual(Set(ids(.project, project: "work")), [a, b], "A project includes its subprojects")
        XCTAssertEqual(ids(.project, project: "home"), [c, "f"])
        XCTAssertTrue(ids(.project, project: nil).isEmpty)
        XCTAssertEqual(IntentTaskSelection.filter(fixture, .upcoming, today: "2026-11-13", calendar: calendar).map(\.id), [c, "g"])
    }

    func testResultsAreOrderedByPriorityThenDate() {
        let rows = [task("x", "Later", due: "2026-11-20", priority: 2), task("y", "Soon", due: "2026-11-13", priority: 2), task("z", "Urgent", due: "2026-12-01", priority: 1)]
        XCTAssertEqual(IntentTaskSelection.ordered(rows).map(\.id), ["z", "y", "x"])
    }

    func testHeadingsAndUntitledRowsAreNeverReturned() {
        var heading = task("h", "Section"); heading["is_heading"] = .bool(true)
        XCTAssertEqual(IntentTaskSelection.open([heading, task("u", "  "), task("ok", "Fine")]).map(\.id), ["ok"])
    }

    func testDueDateAcceptsADateOrNaturalLanguageUsingTheExistingParser() {
        func day(_ phrase: String?, date: Date? = nil) -> String? { IntentDate.day(phrase: phrase, date: date, now: now, calendar: calendar) }
        XCTAssertEqual(day("tomorrow"), "2026-11-13")
        XCTAssertEqual(day("  Today "), "2026-11-12")
        XCTAssertEqual(day("monday"), "2026-11-16")
        XCTAssertEqual(day("next friday"), "2026-11-13")
        XCTAssertEqual(day("2026-12-03"), "2026-12-03")
        XCTAssertEqual(day("dec 3"), "2026-12-03")
        XCTAssertEqual(day("next week"), "2026-11-16", "Honors the default date preferences")
        XCTAssertEqual(day(nil, date: Date(timeIntervalSince1970: 1_796_000_000)), Dates.day(Date(timeIntervalSince1970: 1_796_000_000)), "A picked date wins")
        XCTAssertNil(day("blorp")); XCTAssertNil(day("")); XCTAssertNil(day(nil))
    }

    func testAddOptionsLayerProjectDueAndPriorityOverTheParsedText() {
        var parsed = Record.task(user: "u", project: "typed")
        parsed["title"] = .string("Call mum"); parsed["priority"] = .number(3)
        let both = IntentAddOptions.apply(to: parsed, project: "home", dueDay: "2026-11-13", priority: 1)
        XCTAssertEqual(both.string("project_id"), "home"); XCTAssertEqual(both.string("due_date"), "2026-11-13"); XCTAssertEqual(both.priority, 1)
        XCTAssertEqual(both.title, "Call mum")
        let none = IntentAddOptions.apply(to: parsed, project: nil, dueDay: nil, priority: nil)
        XCTAssertEqual(none, parsed, "No parameter means the text decides")
        XCTAssertEqual(IntentAddOptions.apply(to: parsed, project: "", dueDay: "not-a-day", priority: 9), parsed, "Invalid values are ignored, not saved")
    }

    func testRescheduleUsesThePlannerAndLeavesAnUnchangedDayAlone() {
        let record = task(a, "Send", due: "2026-11-10")
        let fields = TaskPlanner.dayFields(task: record, day: "2026-11-13", calendar: calendar)
        XCTAssertEqual(fields["due_date"], .string("2026-11-13"))
        XCTAssertTrue(TaskPlanner.dayFields(task: record, day: "2026-11-10", calendar: calendar).isEmpty)
    }

    func testSummaryNamesFiveTasksThenCountsTheRest() {
        let rows = (1...7).map { task("t\($0)", "Task \($0)") }
        XCTAssertEqual(IntentSummary.list(rows, empty: "none", label: "due today"), "7 tasks due today: Task 1, Task 2, Task 3, Task 4, Task 5 and 2 more.")
        XCTAssertEqual(IntentSummary.list([rows[0]], empty: "none", label: "overdue"), "1 task overdue: Task 1.")
        XCTAssertEqual(IntentSummary.list([], empty: "Nothing is overdue.", label: "overdue"), "Nothing is overdue.")
    }

    func testNextFocusTaskPrefersDueWorkThenPriorityAndNeedsAValidID() {
        XCTAssertEqual(FocusNextTask.pick(fixture, today: today)?.id, a)
        XCTAssertEqual(FocusNextTask.pick([task(b, "Undated"), task(c, "Dated", due: "2026-12-01")], today: today)?.id, c)
        XCTAssertEqual(FocusNextTask.pick([task(b, "Plain")], today: today)?.id, b)
        XCTAssertNil(FocusNextTask.pick([task("not-a-uuid", "Bad id"), task(a, "Done", done: true)], today: today))
        XCTAssertNil(FocusNextTask.pick([], today: today))
    }

    func testFocusControlPlanStartsStopsAndRefusesStaleTaps() throws {
        let running = try FocusSession(taskID: a, minutes: 25, now: now)
        let start = FocusControlRequest(action: .start, sessionID: nil, issuedAt: now)
        XCTAssertEqual(FocusControlPlan.resolve(start, current: nil, tasks: fixture, today: today, now: now), .start(taskID: a))
        XCTAssertEqual(FocusControlPlan.resolve(start, current: running, tasks: fixture, today: today, now: now.addingTimeInterval(5)), .ignore("A Focus session is already running."))
        XCTAssertEqual(FocusControlPlan.resolve(start, current: nil, tasks: [], today: today, now: now), .ignore("Add an open task to focus on."))
        let finished = try running.stopped(at: now.addingTimeInterval(60))
        XCTAssertEqual(FocusControlPlan.resolve(start, current: finished, tasks: fixture, today: today, now: now.addingTimeInterval(61)), .start(taskID: a), "A stopped session does not block a new one")

        let stop = FocusControlRequest(action: .stop, sessionID: running.id, issuedAt: now)
        XCTAssertEqual(FocusControlPlan.resolve(stop, current: running, tasks: fixture, today: today, now: now), .stop(sessionID: running.id))
        let newer = try FocusSession(taskID: b, minutes: 10, now: now)
        XCTAssertEqual(FocusControlPlan.resolve(stop, current: newer, tasks: fixture, today: today, now: now), .ignore("A newer Focus session is running."))
        XCTAssertEqual(FocusControlPlan.resolve(stop, current: nil, tasks: fixture, today: today, now: now), .ignore("No Focus session to stop."))
        XCTAssertEqual(FocusControlPlan.resolve(stop, current: finished, tasks: fixture, today: today, now: now), .ignore("No Focus session to stop."))
        XCTAssertEqual(FocusControlPlan.resolve(stop, current: running, tasks: fixture, today: today, now: now.addingTimeInterval(FocusControlRequest.lifetime + 1)), .ignore("That timer tap is out of date."))
    }

    func testFocusControlRequestSurvivesTheSharedFileAndExpires() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("focus-control-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: directory) }
        let disk = FocusControlDisk(directory: directory)
        XCTAssertNil(disk.read())
        let request = FocusControlRequest(action: .stop, sessionID: "s1", issuedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try disk.write(request)
        XCTAssertEqual(disk.read(), request)
        let newer = FocusControlRequest(action: .start, sessionID: nil, issuedAt: Date(timeIntervalSince1970: 1_700_000_100))
        try disk.write(newer)
        XCTAssertEqual(disk.read(), newer, "A newer tap replaces the older one")
        XCTAssertTrue(newer.isFresh(at: newer.issuedAt)); XCTAssertFalse(newer.isFresh(at: newer.issuedAt.addingTimeInterval(121)))
        XCTAssertFalse(newer.isFresh(at: newer.issuedAt.addingTimeInterval(-120)), "A clock far in the past is not trusted")
        disk.clear(); XCTAssertNil(disk.read())
    }

    // MARK: Task entity matching, suggestions, tomorrow and moves

    func testMatchRanksExactThenPrefixThenWordStartThenAnywhere() {
        let rows = [task("1", "Pay rent late fee", priority: 1), task("2", "rent", priority: 4), task("3", "Rental car forms"),
                    task("4", "Parent meeting", due: today), task("5", "Rent the flat", priority: 3)]
        XCTAssertEqual(IntentTaskSelection.match(rows, text: "Rent").map(\.id), ["2", "5", "3", "1", "4"],
                       "Exact, starts with, a word starts with, then anywhere. Ties keep priority order")
        XCTAssertEqual(IntentTaskSelection.match(rows, text: "  RENT  ").first?.id, "2")
    }

    func testMatchUsesTitlesOnlyIgnoresAccentsCompletedAndHeadings() {
        let rows = [task("1", "Café order", notes: "call the bank"), task("2", "Bank forms"), task("3", "Bank done", done: true),
                    Record(["id": .string("4"), "title": .string("Bank heading"), "is_heading": .bool(true)])]
        XCTAssertEqual(IntentTaskSelection.match(rows, text: "bank").map(\.id), ["2"], "Notes, completed tasks and headings never match")
        XCTAssertEqual(IntentTaskSelection.match(rows, text: "cafe").map(\.id), ["1"])
        XCTAssertTrue(IntentTaskSelection.match(rows, text: "").isEmpty)
        XCTAssertTrue(IntentTaskSelection.match(rows, text: "zebra").isEmpty)
        XCTAssertEqual(IntentTaskSelection.match(fixture, text: "the", limit: 1).count, 1)
        XCTAssertTrue(IntentTaskSelection.match(fixture, text: "the", limit: 0).isEmpty)
    }

    func testSuggestedPutsDueAndOverdueFirstThenLaterThenUndatedWithinTheLimit() {
        XCTAssertEqual(IntentTaskSelection.suggested(fixture, today: today).map(\.id), [a, b, c, "g", "f", "d"])
        XCTAssertEqual(IntentTaskSelection.suggested(fixture, today: today, limit: 2).map(\.id), [a, b])
        XCTAssertTrue(IntentTaskSelection.suggested([], today: today).isEmpty)
    }

    func testTomorrowIsTheNextCalendarDayAcrossMonthsAndYears() {
        XCTAssertEqual(IntentDate.tomorrow(now: now, calendar: calendar), "2026-11-13")
        let endOfYear = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 23, minute: 30))!
        XCTAssertEqual(IntentDate.tomorrow(now: endOfYear, calendar: calendar), "2027-01-01")
        let leap = calendar.date(from: DateComponents(year: 2028, month: 2, day: 28, hour: 9))!
        XCTAssertEqual(IntentDate.tomorrow(now: leap, calendar: calendar), "2028-02-29")
    }

    func testMovePlanMovesSkipsSameDayHeadingsAndSharedTasks() {
        let open = task("1", "Plan", due: today)
        XCTAssertEqual(IntentMovePlan.resolve(task: open, day: "2026-11-13", shared: false, calendar: calendar), .move(["due_date": .string("2026-11-13")]))
        XCTAssertEqual(IntentMovePlan.resolve(task: open, day: today, shared: false, calendar: calendar), .alreadySet)
        XCTAssertEqual(IntentMovePlan.resolve(task: open, day: "2026-11-13", shared: true, calendar: calendar), .shared)
        let heading = Record(["id": .string("h"), "title": .string("Heading"), "is_heading": .bool(true)])
        XCTAssertEqual(IntentMovePlan.resolve(task: heading, day: "2026-11-13", shared: false, calendar: calendar), .heading)
        XCTAssertEqual(IntentMovePlan.resolve(task: heading, day: "2026-11-13", shared: true, calendar: calendar), .heading)
    }

    func testEntityAccessNeedsSignInAndAnUnlockedDevice() {
        XCTAssertTrue(IntentEntityAccess.allowed(signedIn: true, protectedDataAvailable: true))
        XCTAssertFalse(IntentEntityAccess.allowed(signedIn: true, protectedDataAvailable: false))
        XCTAssertFalse(IntentEntityAccess.allowed(signedIn: false, protectedDataAvailable: true))
    }
}
