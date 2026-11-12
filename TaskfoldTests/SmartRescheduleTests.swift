import XCTest
@testable import TaskfoldCore

/// Smart reschedule (Core/SmartReschedule.swift): the deterministic plan, its limits and the one-line note rules.
final class SmartRescheduleTests: XCTestCase {
    let account = "owner"
    func cal(_ zone: String = "Europe/Copenhagen") -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; return c }
    func at(_ day: String, _ hhmm: String, _ c: Calendar) -> Date {
        let parts = hhmm.split(separator: ":").map { Int($0)! }
        return c.date(from: DateComponents(timeZone: c.timeZone, year: Int(day.prefix(4)), month: Int(day.dropFirst(5).prefix(2)), day: Int(day.suffix(2)), hour: parts[0], minute: parts[1]))!
    }
    func task(_ id: String, minutes: Int? = nil, priority: Int = 4, date: String = "2026-11-09", time: String? = nil, deadline: String? = nil, extra: [String: JSON] = [:]) -> Record {
        var row = Record.task(user: account, createdAt: "2026-11-01T09:00:00Z")
        row["id"] = .string(id); row["title"] = .string("Task " + id); row["due_date"] = .string(date); row["priority"] = .number(Double(priority))
        if let minutes { row["duration_minutes"] = .number(Double(minutes)) }
        if let time { row["due_time"] = .string(time) }
        if let deadline { row["deadline_date"] = .string(deadline) }
        for (key, value) in extra { row[key] = value }
        return row
    }
    func weekly(_ id: String, date: String, days: [Int] = []) -> Record {
        task(id, minutes: 30, date: date, extra: ["is_recurring": .bool(true), "recurrence_pattern": .object(["type": .string("weekly"), "interval": .number(1)])])
    }
    // Wednesday 11 Nov 2026, 08:00 in Copenhagen: the working days are Wed 11, Thu 12, Fri 13, Mon 16 and Tue 17.
    func plan(_ tasks: [Record], events: [PlannerEvent] = [], hours: WorkingHours? = WorkingHours(), days: Int = 5, now: String = "08:00", on day: String = "2026-11-11",
              zone: String = "Europe/Copenhagen", held: Set<String> = [], editable: @escaping (Record) -> Bool = { _ in true }) -> SmartReschedule.Plan {
        let c = cal(zone)
        return SmartReschedule.plan(tasks: tasks, events: events, hours: hours, workingDays: days, now: at(day, now, c), held: held, calendar: c, isEditable: editable)
    }
    func days(_ p: SmartReschedule.Plan) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: p.days.map { ($0.day, p.placements(on: $0.day).map(\.taskID).sorted()) })
    }

    // MARK: Spreading and capacity

    func testSpreadsOverdueWorkAcrossWorkingDaysWithinCapacity() {
        let p = plan((1...5).map { task("t\($0)", minutes: 240, date: "2026-11-0\($0 + 3)") })
        XCTAssertEqual(p.days.map(\.day), ["2026-11-11", "2026-11-12", "2026-11-13", "2026-11-16", "2026-11-17"], "The weekend is skipped")
        XCTAssertEqual(p.days.map(\.freeMinutes), [480, 480, 480, 480, 480])
        XCTAssertEqual(p.placements.count, 5); XCTAssertTrue(p.unplaced.isEmpty)
        for day in p.days { XCTAssertLessThanOrEqual(p.load(on: day.day), day.freeMinutes) }
        XCTAssertEqual(p.load(on: "2026-11-11"), 480); XCTAssertEqual(p.load(on: "2026-11-12"), 480); XCTAssertEqual(p.load(on: "2026-11-13"), 240)
    }
    func testMissingEstimateCountsThirtyMinutes() {
        let p = plan([task("a"), task("b", minutes: 45)])
        XCTAssertEqual(p.placements.first { $0.taskID == "a" }?.minutes, 30); XCTAssertEqual(p.placements.first { $0.taskID == "a" }?.guessed, true)
        XCTAssertEqual(p.placements.first { $0.taskID == "b" }?.guessed, false)
        XCTAssertEqual(p.load(on: "2026-11-11"), 75)
    }
    func testEventsAndAlreadyPlannedWorkReduceFreeTime() {
        let c = cal()
        let events = [PlannerEvent(id: "m", calendarID: "w", start: at("2026-11-11", "10:00", c), end: at("2026-11-11", "14:00", c)),
                      PlannerEvent(id: "ad", calendarID: "w", start: at("2026-11-12", "00:00", c), end: at("2026-11-13", "00:00", c), allDay: true)]
        let planned = [task("p1", minutes: 60, date: "2026-11-12"), task("p2", date: "2026-11-12"), task("done", minutes: 600, date: "2026-11-12", extra: ["completed": .bool(true)])]
        let p = plan([task("a", minutes: 30)] + planned, events: events)
        XCTAssertEqual(p.days[0].freeMinutes, 240, "Wednesday: 8 hours minus a 4 hour meeting")
        XCTAssertEqual(p.days[1].freeMinutes, 480 - 60 - 30, "Thursday: all-day events are information; planned work counts its estimate or 30 minutes; completed work is ignored")
        XCTAssertEqual(p.days[2].freeMinutes, 480)
    }
    func testTodayOffersOnlyWhatRemains() {
        XCTAssertEqual(plan([task("a")], now: "16:00").days[0].freeMinutes, 60)
        XCTAssertEqual(plan([task("a")], now: "07:00").days[0].freeMinutes, 480)
        let late = plan([task("a")], now: "18:00")
        XCTAssertEqual(late.days.first?.day, "2026-11-12", "After working hours the first day is tomorrow")
        XCTAssertEqual(late.days.count, 5)
    }
    func testOverCapacityLeavesTasksOverdueWithAMessage() {
        let tasks = (1...12).map { task("t\($0)", minutes: 240, priority: min(4, ($0 + 2) / 3)) }
        let p = plan(tasks)
        XCTAssertEqual(p.placements.count, 10); XCTAssertEqual(p.unplaced.count, 2)
        XCTAssertTrue(p.unplaced.allSatisfy { $0.reason == .noRoom })
        XCTAssertEqual(p.unplacedMessage, "2 tasks didn’t fit in 5 days. Keep them overdue or extend to 10 days.")
        XCTAssertTrue(p.canExtend)
        let wide = plan(tasks, days: 10)
        XCTAssertEqual(wide.placements.count, 12); XCTAssertNil(wide.unplacedMessage)
        XCTAssertEqual(plan((1...21).map { task("t\($0)", minutes: 240) }, days: 10).unplacedMessage, "1 task didn’t fit in 10 days. Keep it overdue or choose dates yourself.")
    }
    func testTaskLongerThanAnyDayIsReported() {
        let p = plan([task("huge", minutes: 700), task("ok", minutes: 60)])
        XCTAssertEqual(p.unplaced, [.init(taskID: "huge", reason: .longerThanAnyDay)])
        XCTAssertEqual(p.placements.map(\.taskID), ["ok"])
    }
    func testNothingOverdueGivesAnEmptyPlan() {
        let p = plan([task("today", date: "2026-11-11"), task("future", date: "2026-11-14")])
        XCTAssertTrue(p.isEmpty); XCTAssertNil(p.unplacedMessage)
        XCTAssertTrue(plan([]).isEmpty)
    }

    // MARK: Order, priority, deadlines and age

    func testPriorityThenDeadlineThenAge() {
        let tasks = [task("low-old", minutes: 480, priority: 4, date: "2026-11-02"),
                     task("p1-new", minutes: 480, priority: 1, date: "2026-11-10"),
                     task("p2-deadline", minutes: 480, priority: 2, date: "2026-11-09", deadline: "2026-11-20"),
                     task("p2-nodeadline-old", minutes: 480, priority: 2, date: "2026-11-01"),
                     task("p2-sooner", minutes: 480, priority: 2, date: "2026-11-09", deadline: "2026-11-13")]
        let ordered = SmartReschedule.prioritised(tasks, calendar: cal()).map(\.id)
        XCTAssertEqual(ordered, ["p1-new", "p2-sooner", "p2-deadline", "p2-nodeadline-old", "low-old"])
        let p = plan(tasks)
        XCTAssertEqual(p.placements.map(\.day), ["2026-11-11", "2026-11-12", "2026-11-13", "2026-11-16", "2026-11-17"])
        XCTAssertEqual(p.placements.map(\.taskID), ordered)
    }
    func testAgeBreaksTiesAndIdsKeepItStable() {
        let ordered = SmartReschedule.prioritised([task("b", date: "2026-11-05"), task("a", date: "2026-11-05"), task("c", date: "2026-11-03")], calendar: cal()).map(\.id)
        XCTAssertEqual(ordered, ["c", "a", "b"])
    }
    func testNeverSchedulesAfterADeadline() {
        let p = plan([task("a", minutes: 480, priority: 1), task("c", minutes: 60, priority: 4, deadline: "2026-11-12")])
        XCTAssertEqual(p.placements.first { $0.taskID == "c" }?.day, "2026-11-12", "Wednesday is full, so the deadline task takes Thursday, not Friday")
        let tasks = (1...8).map { task("x\($0)", minutes: 240, priority: $0 % 4 + 1, date: "2026-11-0\($0)", deadline: $0 % 2 == 0 ? "2026-11-12" : nil) }
        let many = plan(tasks), deadlines = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.string("deadline_date")) })
        XCTAssertFalse(many.placements.isEmpty)
        for placement in many.placements { if let deadline = deadlines[placement.taskID], !deadline.isEmpty { XCTAssertLessThanOrEqual(placement.day, deadline, placement.taskID) } }
    }
    func testDeadlineBeforeTheFirstDayStaysOverdue() {
        let p = plan([task("late", deadline: "2026-11-10"), task("fine")])
        XCTAssertEqual(p.unplaced, [.init(taskID: "late", reason: .afterDeadline)])
        XCTAssertEqual(p.placements.map(\.taskID), ["fine"])
    }
    func testDeadlineWithNoRoomBeforeItIsNoRoom() {
        let p = plan([task("a", minutes: 480, priority: 1, deadline: "2026-11-11"), task("b", minutes: 60, priority: 2, deadline: "2026-11-11")])
        XCTAssertEqual(p.unplaced, [.init(taskID: "b", reason: .noRoom)])
    }

    // MARK: Recurring, timed and editable tasks

    func testRecurringTaskMovesOnlyToItsNextOccurrenceAndShowsWhatItPasses() {
        let p = plan([weekly("w", date: "2026-11-02")])
        XCTAssertEqual(p.placements, [.init(taskID: "w", day: "2026-11-16", minutes: 30, guessed: false, repeatSkipped: 2)], "Missed 2 and 9 November; next is Monday 16")
        XCTAssertTrue(p.moveTargets(for: "w").isEmpty)
        var copy = p
        XCTAssertFalse(copy.move("w", to: "2026-11-12")); XCTAssertEqual(copy.placements, p.placements)
    }
    func testDailyRecurringTaskLandsOnTodayAndCountsAgainstTheDay() {
        let daily = task("d", minutes: 60, date: "2026-11-09", extra: ["is_recurring": .bool(true), "recurrence_pattern": .object(["type": .string("daily"), "interval": .number(1)])])
        let p = plan([daily, task("a", minutes: 450, priority: 1)])
        XCTAssertEqual(p.placements.first { $0.taskID == "d" }?.day, "2026-11-11")
        XCTAssertEqual(p.placements.first { $0.taskID == "d" }?.repeatSkipped, 2)
        XCTAssertEqual(p.placements.first { $0.taskID == "a" }?.day, "2026-11-12", "The repeat claimed Wednesday first, so 450 minutes no longer fit there")
    }
    func testRecurringTaskBeyondTheWindowStaysOverdue() {
        let monthly = task("m", minutes: 30, date: "2026-10-20", extra: ["is_recurring": .bool(true), "recurrence_pattern": .object(["type": .string("monthly"), "interval": .number(1)])])
        XCTAssertEqual(plan([monthly]).unplaced, [.init(taskID: "m", reason: .recurringBeyondWindow)])
        XCTAssertEqual(plan([monthly], days: 10).placements.map(\.day), ["2026-11-20"], "A longer window reaches it; the date is a weekday")
    }
    func testRecurringTaskOnADayOffIsShownOnItsOwnDay() {
        let saturday = task("s", minutes: 30, date: "2026-11-07", extra: ["is_recurring": .bool(true), "recurrence_pattern": .object(["type": .string("weekly"), "interval": .number(1), "daysOfWeek": .array([.number(6)])])])
        let p = plan([saturday])
        XCTAssertEqual(p.placements.first?.day, "2026-11-14")
        let day = p.days.first { $0.day == "2026-11-14" }
        XCTAssertEqual(day?.workingMinutes, 0); XCTAssertFalse(p.isOver("2026-11-14"))
        XCTAssertEqual(p.days.map(\.day), p.days.map(\.day).sorted())
    }
    func testTimedTaskKeepsItsTimeOfDay() {
        let c = cal()
        let timed = task("t", minutes: 30, date: "2026-11-05", time: "14:30")
        let p = plan([timed, task("x", minutes: 480, priority: 1)])
        let day = p.placements.first { $0.taskID == "t" }!.day
        XCTAssertEqual(day, "2026-11-12")
        let changes = SmartReschedule.fieldChanges(p, tasks: [timed], calendar: c)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].fields["due_date"], .string("2026-11-12"))
        XCTAssertNil(changes[0].fields["due_time"], "The clock time is untouched")
        var untimed = timed; untimed["due_time"] = .null
        XCTAssertNil(SmartReschedule.fieldChanges(p, tasks: [untimed], calendar: c).first?.fields["due_time"])
    }
    func testFixedTimeZoneTaskKeepsItsZone() {
        let c = cal()
        let fixed = task("f", minutes: 30, date: "2026-11-05", time: "09:00", extra: ["time_zone": .string("America/New_York"), "scheduled_at": .string("2026-11-05T14:00:00Z")])
        let p = plan([fixed])
        let changes = SmartReschedule.fieldChanges(p, tasks: [fixed], calendar: c)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].fields["due_date"], .string("2026-11-11"))
        XCTAssertEqual(changes[0].fields["scheduled_at"], .string("2026-11-11T14:00:00Z"), "09:00 in New York stays 09:00 in New York")
        XCTAssertNil(changes[0].fields["time_zone"], "The zone is untouched"); XCTAssertNil(changes[0].fields["due_time"])
    }
    func testReadOnlyHeldAndNonTasksAreNeverTouched() {
        let shared = task("shared", minutes: 30)
        var heading = task("h"); heading["is_heading"] = .bool(true)
        let child = task(SubtaskTree.reference(parent: "parent", key: "child"))
        let p = plan([shared, task("mine"), task("evening"), task("done", extra: ["completed": .bool(true)]), heading, child], held: ["evening"], editable: { $0.id != "shared" })
        XCTAssertEqual(p.placements.map(\.taskID), ["mine"])
        XCTAssertEqual(p.readOnlyCount, 1); XCTAssertTrue(p.unplaced.isEmpty)
    }

    // MARK: Working days, time zones and DST

    func testWorkingDaysSettingDecidesWhichDaysCount() {
        let friday = plan([task("a")], now: "09:30", on: "2026-11-13")
        XCTAssertEqual(friday.days.map(\.day), ["2026-11-13", "2026-11-16", "2026-11-17", "2026-11-18", "2026-11-19"])
        XCTAssertEqual(friday.days[0].freeMinutes, 450)
        let everyDay = plan([task("a")], hours: WorkingHours(start: 540, end: 1020, weekdays: [1, 2, 3, 4, 5, 6, 7]), now: "09:30", on: "2026-11-13", zone: "Europe/Copenhagen")
        XCTAssertEqual(everyDay.days.map(\.day), ["2026-11-13", "2026-11-14", "2026-11-15", "2026-11-16", "2026-11-17"])
        let none = plan([task("a")], hours: WorkingHours(start: 540, end: 1020, weekdays: []))
        XCTAssertTrue(none.days.isEmpty); XCTAssertEqual(none.unplaced, [.init(taskID: "a", reason: .noWorkingDays)])
        XCTAssertEqual(plan([task("a")], hours: nil).days.count, 5, "Without a saved preference the default weekday hours apply")
    }
    func testDaylightSavingDaysKeepTheirRealWorkingTime() {
        let everyDay = WorkingHours(start: 0, end: 1440, weekdays: [1, 2, 3, 4, 5, 6, 7])
        let spring = plan([task("a")], hours: everyDay, now: "00:00", on: "2026-03-27")
        XCTAssertEqual(spring.days.map(\.day), ["2026-03-27", "2026-03-28", "2026-03-29", "2026-03-30", "2026-03-31"])
        XCTAssertEqual(spring.days.map(\.workingMinutes), [1440, 1440, 1380, 1440, 1440], "The 29 March day has 23 hours")
        let autumn = plan([task("a")], hours: everyDay, now: "00:00", on: "2026-10-23")
        XCTAssertEqual(autumn.days.map(\.day), ["2026-10-23", "2026-10-24", "2026-10-25", "2026-10-26", "2026-10-27"])
        XCTAssertEqual(autumn.days.map(\.workingMinutes), [1440, 1440, 1500, 1440, 1440], "The 25 October day has 25 hours")
        let office = plan([task("a")], hours: WorkingHours(start: 540, end: 1020, weekdays: [1, 2, 3, 4, 5, 6, 7]), now: "08:00", on: "2026-10-23")
        XCTAssertEqual(office.days.map(\.freeMinutes), [480, 480, 480, 480, 480])
    }
    func testOtherTimeZonesUseTheirOwnCalendarDay() {
        let sydney = plan([task("a")], now: "08:00", on: "2026-11-11", zone: "Australia/Sydney")
        XCTAssertEqual(sydney.days.first?.day, "2026-11-11")
        let honolulu = plan([task("a")], now: "08:00", on: "2026-11-11", zone: "Pacific/Honolulu")
        XCTAssertEqual(honolulu.days.map(\.day), ["2026-11-11", "2026-11-12", "2026-11-13", "2026-11-16", "2026-11-17"])
        XCTAssertEqual(plan([task("a", date: "2026-11-10")], now: "08:00", on: "2026-11-11", zone: "Pacific/Honolulu").placements.count, 1)
    }

    // MARK: Review edits

    func testMovingAndExcludingUpdateTheDayTotals() {
        var p = plan([task("a", minutes: 120), task("b", minutes: 60), task("c", minutes: 90)])
        XCTAssertEqual(p.summary(on: "2026-11-11"), "3 tasks · 4h 30m")
        XCTAssertEqual(p.summary(on: "2026-11-12"), "No tasks")
        XCTAssertTrue(p.move("b", to: "2026-11-12"))
        XCTAssertEqual(p.summary(on: "2026-11-11"), "2 tasks · 3h 30m"); XCTAssertEqual(p.summary(on: "2026-11-12"), "1 task · 1h")
        p.setExcluded("a", true)
        XCTAssertEqual(p.includedCount, 2); XCTAssertEqual(p.summary(on: "2026-11-11"), "1 task · 1h 30m")
        XCTAssertEqual(SmartReschedule.fieldChanges(p, tasks: [task("a"), task("b"), task("c")], calendar: cal()).map(\.task.id).sorted(), ["b", "c"])
        p.setExcluded("a", false); XCTAssertEqual(p.includedCount, 3)
        XCTAssertFalse(p.move("b", to: "2026-11-14"), "Not a working day of this plan")
        XCTAssertFalse(p.move("missing", to: "2026-11-12"))
        XCTAssertEqual(p.moveTargets(for: "b").count, 5)
    }
    func testMovingAfterADeadlineIsFlagged() {
        var p = plan([task("a", minutes: 60, deadline: "2026-11-12")])
        XCTAssertTrue(p.move("a", to: "2026-11-13", deadline: "2026-11-12"))
        XCTAssertEqual(p.placements.first?.afterDeadline, true)
        XCTAssertTrue(p.move("a", to: "2026-11-12", deadline: "2026-11-12"))
        XCTAssertEqual(p.placements.first?.afterDeadline, false)
    }
    func testOverCapacityDayAfterAManualMove() {
        var p = plan([task("a", minutes: 480), task("b", minutes: 60)])
        XCTAssertFalse(p.isOver("2026-11-12"))
        XCTAssertTrue(p.move("b", to: "2026-11-11")); XCTAssertTrue(p.isOver("2026-11-11"))
    }
    func testAccessibilityLabelNamesDayCountAndCapacity() {
        let p = plan([task("a", minutes: 60), task("b", minutes: 60)])
        XCTAssertEqual(p.accessibility(on: "2026-11-11"), "Wednesday, 2 tasks, 2 hours of 8 hours free")
        XCTAssertEqual(p.accessibility(on: "2026-11-12"), "Thursday, 0 tasks, 0 minutes of 8 hours free")
    }

    // MARK: Plan stays deterministic and bounded

    func testPlanIsDeterministicAndBounded() {
        let tasks = (0..<700).map { task("t\(String(format: "%03d", $0))", minutes: 5, priority: $0 % 4 + 1, date: "2026-10-\(String(format: "%02d", $0 % 28 + 1))") }
        let a = plan(tasks, days: 10), b = plan(tasks.reversed(), days: 10)
        XCTAssertEqual(a.placements.count + a.unplaced.count, SmartReschedule.maximumTasks)
        XCTAssertEqual(a, b, "Input order does not change the plan")
        XCTAssertEqual(plan(tasks, days: 99).days.count, 30)
    }

    // MARK: One-line notes never change the plan

    func testNotesAreCleanedAndOnlyForDaysWithTasks() {
        let p = plan([task("a", minutes: 60)])
        let notes = SmartReschedule.cleanNotes([("2026-11-11", "  Light start:\none call\u{0} and the report  "), ("2026-11-12", "Empty day note"), ("2099-01-01", "Unknown"), ("2026-11-11", "Duplicate")], plan: p)
        XCTAssertEqual(notes, ["2026-11-11": "Light start: one call and the report"])
        XCTAssertEqual(SmartReschedule.cleanNote(String(repeating: "x", count: 200))?.count, 90)
        XCTAssertNil(SmartReschedule.cleanNote(" \n "))
    }
    func testNotePromptDescribesThePlanOnly() {
        let p = plan([task("a", minutes: 60)])
        let text = SmartReschedule.notesPrompt(p, titles: ["a": "Prepare\nreport"], calendar: cal())
        XCTAssertTrue(text.contains("2026-11-11") && text.contains("1h of 8h free") && text.contains("Prepare report"), text)
        XCTAssertFalse(text.contains("2026-11-12"), "Days without tasks are not described")
        XCTAssertLessThanOrEqual(SmartReschedule.notesPrompt(p, titles: ["a": String(repeating: "x", count: 5_000)]).count, 6_000)
    }
    func testNoteSessionRejectsStaleAndSupersededResults() throws {
        let workspace = WorkspaceBinding(account: account, generation: UUID()), session = UUID()
        var p = plan([task("a", minutes: 60), task("b", minutes: 60)])
        var run = SmartRescheduleSession(workspace: workspace, session: session)
        let first = try XCTUnwrap(run.begin(plan: p, workspace: workspace, session: session))
        let second = try XCTUnwrap(run.begin(plan: p, workspace: workspace, session: session))
        XCTAssertNil(run.receive([("2026-11-11", "Old")], token: first, plan: p, workspace: workspace, session: session))
        var moved = p; moved.move("b", to: "2026-11-12")
        XCTAssertNil(run.receive([("2026-11-11", "Late")], token: second, plan: moved, workspace: workspace, session: session), "A plan changed by the person discards the note")
        let third = try XCTUnwrap(run.begin(plan: p, workspace: workspace, session: session))
        XCTAssertNil(run.receive([("2026-11-11", "x")], token: third, plan: p, workspace: WorkspaceBinding(account: account, generation: UUID()), session: session))
        let fourth = try XCTUnwrap(run.begin(plan: p, workspace: workspace, session: session))
        XCTAssertEqual(run.receive([("2026-11-11", "Two calls and the report")], token: fourth, plan: p, workspace: workspace, session: session), ["2026-11-11": "Two calls and the report"])
        XCTAssertNil(run.receive([("2026-11-11", "Again")], token: fourth, plan: p, workspace: workspace, session: session))
        let fifth = try XCTUnwrap(run.begin(plan: p, workspace: workspace, session: session)); run.close()
        XCTAssertNil(run.receive([("2026-11-11", "x")], token: fifth, plan: p, workspace: workspace, session: session))
        p.setExcluded("a", true)
        XCTAssertNotEqual(SmartRescheduleSession.fingerprint(p), SmartRescheduleSession.fingerprint(plan([task("a", minutes: 60), task("b", minutes: 60)])))
    }
}
