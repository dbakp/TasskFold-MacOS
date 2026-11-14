import XCTest
@testable import TaskfoldCore

/// The daily planning ritual (Core/DayPlan.swift): steps, totals, Fit my day, the planned-today state and shutdown.
final class DayPlanTests: XCTestCase {
    let account = "owner"
    func cal(_ zone: String = "Europe/Copenhagen") -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; return c }
    func day(_ text: String, _ c: Calendar) -> Date { Dates.parse(text, calendar: c)! }
    func at(_ day: String, _ hhmm: String, _ c: Calendar) -> Date {
        let parts = hhmm.split(separator: ":").map { Int($0)! }
        return c.date(from: DateComponents(timeZone: c.timeZone, year: Int(day.prefix(4)), month: Int(day.dropFirst(5).prefix(2)), day: Int(day.suffix(2)), hour: parts[0], minute: parts[1]))!
    }
    func task(_ id: String, minutes: Int? = nil, priority: Int = 4, date: String = "2026-11-11", time: String? = nil, extra: [String: JSON] = [:]) -> Record {
        var row = Record.task(user: account, createdAt: "2026-11-01T09:00:00Z")
        row["id"] = .string(id); row["title"] = .string("Task " + id); row["due_date"] = .string(date); row["priority"] = .number(Double(priority))
        if let minutes { row["duration_minutes"] = .number(Double(minutes)) }
        if let time { row["due_time"] = .string(time) }
        for (key, value) in extra { row[key] = value }
        return row
    }
    func event(_ id: String, _ day: String, _ from: String, _ to: String, _ c: Calendar, allDay: Bool = false) -> PlannerEvent {
        PlannerEvent(id: id, calendarID: "work", title: id, start: at(day, from, c), end: at(day, to, c), allDay: allDay)
    }
    func clock(_ date: Date, _ c: Calendar) -> String { String(format: "%02d:%02d", c.component(.hour, from: date), c.component(.minute, from: date)) }
    func starts(_ fit: DayPlanFit, _ c: Calendar) -> [String: String] { Dictionary(uniqueKeysWithValues: fit.placements.map { ($0.taskID, clock($0.start, c)) }) }
    let wed = "2026-11-11"
    func order(_ key: String, _ ids: [String], user: String = "owner") -> Record {
        Record(["id": .string(key), "user_id": .string(user), "ids": .array(ids.map(JSON.string))])
    }

    // MARK: Steps and formatting

    func testStepLabelsAndEligibility() {
        XCTAssertEqual(DayPlanStep.estimate.accessibilityLabel, "Step 2 of 4, Estimate")
        XCTAssertEqual(DayPlanStep.timeBlock.title, "Time-block")
        XCTAssertEqual(DayPlan.eligibleSteps(triageCount: 3, today: []), [.triage, .done])
        XCTAssertEqual(DayPlan.eligibleSteps(triageCount: 0, today: [task("a")]), [.estimate, .done])
        XCTAssertEqual(DayPlan.eligibleSteps(triageCount: 2, today: [task("a", minutes: 30)]), [.triage, .estimate, .timeBlock, .done])
        let all = DayPlan.eligibleSteps(triageCount: 1, today: [task("a", minutes: 30)])
        XCTAssertEqual(DayPlan.next(after: .triage, eligible: all), .estimate)
        XCTAssertEqual(DayPlan.next(after: .done, eligible: all), .done)
        XCTAssertEqual(DayPlan.previous(before: .estimate, eligible: all), .triage)
        XCTAssertNil(DayPlan.previous(before: .triage, eligible: all))
        let sparse = DayPlan.eligibleSteps(triageCount: 0, today: [task("a")])
        XCTAssertEqual(DayPlan.next(after: .estimate, eligible: sparse), .done, "Time-block is skipped when nothing has an estimate")
    }

    func testDurationAndSpokenFormatting() {
        XCTAssertEqual(DayPlan.duration(0), "0m"); XCTAssertEqual(DayPlan.duration(45), "45m"); XCTAssertEqual(DayPlan.duration(120), "2h"); XCTAssertEqual(DayPlan.duration(255), "4h 15m")
        XCTAssertEqual(DayPlan.spoken(255), "4 hours 15 minutes"); XCTAssertEqual(DayPlan.spoken(60), "1 hour"); XCTAssertEqual(DayPlan.spoken(1), "1 minute"); XCTAssertEqual(DayPlan.spoken(0), "0 minutes")
        XCTAssertEqual(DayPlan.summaryLine(taskCount: 5, plannedMinutes: 255, finish: "16:30"), "5 tasks · 4h 15m planned · finishes around 16:30")
        XCTAssertEqual(DayPlan.summaryLine(taskCount: 1, plannedMinutes: 30, finish: nil), "1 task · 30m planned")
        XCTAssertEqual(DayPlan.roundedUp(86, to: 5), 90); XCTAssertEqual(DayPlan.roundedUp(90, to: 5), 90)
    }

    // MARK: Totals

    func testTotalsCountFreeTimeMinusEventsAndNeverBlock() {
        let c = cal(), d = day(wed, c)
        let tasks = [task("a", minutes: 120), task("b", minutes: 90), task("c", minutes: 60), task("d"), task("later", minutes: 600, date: "2026-11-12")]
        let events = [event("standup", wed, "10:00", "11:00", c), event("review", wed, "14:00", "15:00", c)]
        let totals = DayPlan.totals(tasks, events: events, on: d, hours: WorkingHours(), calendar: c)
        XCTAssertEqual(totals.taskCount, 4); XCTAssertEqual(totals.estimatedMinutes, 270); XCTAssertEqual(totals.unestimatedCount, 1)
        XCTAssertEqual(totals.workingMinutes, 480); XCTAssertEqual(totals.busyMinutes, 120); XCTAssertEqual(totals.freeMinutes, 360)
        XCTAssertFalse(totals.isOver); XCTAssertNil(totals.overNote)
        XCTAssertEqual(totals.capacityLabel, "4h 30m planned · 6h free")
        XCTAssertEqual(totals.capacityAccessibility, "Capacity: 4 hours 30 minutes planned, 6 hours free")
        let over = DayPlan.totals(tasks + [task("e", minutes: 180)], events: events, on: d, hours: WorkingHours(), calendar: c)
        XCTAssertEqual(over.overMinutes, 90); XCTAssertEqual(over.overNote, "About 1h 30m more than your free time"); XCTAssertEqual(over.fraction, 1)
    }

    func testAllDayEventsAndOverlappingEventsDoNotDistortCapacity() {
        let c = cal(), d = day(wed, c)
        let events = [event("ooo", wed, "00:00", "23:59", c, allDay: true), event("a", wed, "09:00", "10:00", c), event("b", wed, "09:30", "10:30", c)]
        let totals = DayPlan.totals([task("a", minutes: 60)], events: events, on: d, hours: WorkingHours(), calendar: c)
        XCTAssertEqual(totals.busyMinutes, 90); XCTAssertEqual(totals.freeMinutes, 390)
    }

    func testTotalsOnADayWithoutWorkingHoursAreAllOver() {
        let c = cal(), saturday = day("2026-11-14", c)
        let totals = DayPlan.totals([task("a", minutes: 30, date: "2026-11-14")], events: [], on: saturday, hours: WorkingHours(), calendar: c)
        XCTAssertEqual(totals.freeMinutes, 0); XCTAssertEqual(totals.overMinutes, 30); XCTAssertEqual(totals.fraction, 1)
    }

    func testFinishesAroundIsTheLatestEstimatedEnd() {
        let c = cal()
        let tasks = [task("a", minutes: 60, time: "09:00"), task("b", minutes: 45, time: "15:45"), task("c", time: "17:00"), task("d", minutes: 30)]
        XCTAssertEqual(clock(DayPlan.finishesAround(tasks, calendar: c)!, c), "16:30")
        XCTAssertNil(DayPlan.finishesAround([task("d", minutes: 30), task("c", time: "17:00")], calendar: c))
    }

    // MARK: Fit my day

    func testFirstFitUsesGapsAroundEventsWithABuffer() {
        let c = cal(), d = day(wed, c)
        let fit = DayPlan.fit(tasks: [task("a", minutes: 60), task("b", minutes: 30), task("c", minutes: 45)], events: [event("meeting", wed, "10:00", "11:00", c)], on: d, hours: WorkingHours(), calendar: c)
        // The 60 minute task cannot end by 09:55, so it goes after the meeting; the 30 minute task takes the morning gap.
        XCTAssertEqual(starts(fit, c), ["a": "11:05", "b": "09:00", "c": "12:10"])
        XCTAssertEqual(fit.placements.map(\.taskID), ["b", "a", "c"], "Placements are chronological")
        XCTAssertTrue(fit.didntFit.isEmpty); XCTAssertEqual(fit.placedMinutes, 135)
    }

    func testBackToBackTasksKeepAFiveMinuteBuffer() {
        let c = cal(), d = day(wed, c)
        let fit = DayPlan.fit(tasks: [task("a", minutes: 30), task("b", minutes: 30), task("c", minutes: 15)], events: [], on: d, hours: WorkingHours(), calendar: c)
        XCTAssertEqual(starts(fit, c), ["a": "09:00", "b": "09:35", "c": "10:10"])
    }

    func testPriorityThenManualOrder() {
        let c = cal(), d = day(wed, c)
        let tasks = [task("manual1", minutes: 30, priority: 4), task("urgent", minutes: 30, priority: 1), task("manual2", minutes: 30, priority: 4), task("high", minutes: 30, priority: 2)]
        let fit = DayPlan.fit(tasks: tasks, events: [], on: d, hours: WorkingHours(), calendar: c)
        XCTAssertEqual(fit.placements.map(\.taskID), ["urgent", "high", "manual1", "manual2"])
    }

    func testRespectsAlreadyTimedTasksIncludingOnesWithoutAnEstimate() {
        let c = cal(), d = day(wed, c)
        let tasks = [task("fixed", minutes: 60, time: "09:00"), task("point", time: "10:30"), task("a", minutes: 30), task("b", minutes: 30)]
        let fit = DayPlan.fit(tasks: tasks, events: [], on: d, hours: WorkingHours(), calendar: c)
        // 09:00-10:00 is taken (free from 10:05); the point at 10:30 blocks 10:25-10:35, so the 20 minute gap between them is too short.
        XCTAssertEqual(starts(fit, c), ["a": "10:35", "b": "11:10"])
        XCTAssertNil(starts(fit, c)["fixed"]); XCTAssertNil(starts(fit, c)["point"])
    }

    func testNotBeforeNeverPlacesInThePastAndRoundsToTheGrid() {
        let c = cal(), d = day(wed, c)
        let fit = DayPlan.fit(tasks: [task("a", minutes: 30)], events: [], on: d, hours: WorkingHours(), notBefore: at(wed, "09:07", c), calendar: c)
        XCTAssertEqual(starts(fit, c), ["a": "09:10"])
        let late = DayPlan.fit(tasks: [task("a", minutes: 30)], events: [], on: d, hours: WorkingHours(), notBefore: at(wed, "16:45", c), calendar: c)
        XCTAssertTrue(late.placements.isEmpty); XCTAssertEqual(late.didntFit, [.init(taskID: "a", reason: .longerThanAnyGap)], "Only 15 minutes of the day are left")
        let after = DayPlan.fit(tasks: [task("a", minutes: 30)], events: [], on: d, hours: WorkingHours(), notBefore: at(wed, "19:00", c), calendar: c)
        XCTAssertEqual(after.didntFit.first?.reason, .noRoom)
    }

    func testAllDayEventsDoNotBlockButTimedEventsOutsideWorkingHoursAreIgnored() {
        let c = cal(), d = day(wed, c)
        let events = [event("holiday", wed, "00:00", "23:59", c, allDay: true), event("breakfast", wed, "07:00", "08:30", c), event("dinner", wed, "18:00", "20:00", c)]
        let fit = DayPlan.fit(tasks: [task("a", minutes: 480)], events: events, on: d, hours: WorkingHours(), calendar: c)
        XCTAssertEqual(starts(fit, c), ["a": "09:00"])
    }

    func testNoEstimateZeroEstimateAndNonWorkingDays() {
        let c = cal(), d = day(wed, c)
        let tasks = [task("none"), task("zero", extra: ["duration_minutes": .number(0)]), task("ok", minutes: 20)]
        let fit = DayPlan.fit(tasks: tasks, events: [], on: d, hours: WorkingHours(), calendar: c)
        XCTAssertEqual(fit.didntFit, [.init(taskID: "none", reason: .noEstimate), .init(taskID: "zero", reason: .noEstimate)])
        XCTAssertEqual(starts(fit, c), ["ok": "09:00"])
        let saturday = day("2026-11-14", c)
        let weekend = DayPlan.fit(tasks: [task("a", minutes: 20, date: "2026-11-14")], events: [], on: saturday, hours: WorkingHours(), calendar: c)
        XCTAssertEqual(weekend.didntFit, [.init(taskID: "a", reason: .noWorkingHours)])
        let nohours = DayPlan.fit(tasks: [task("a", minutes: 20)], events: [], on: d, hours: nil, calendar: c)
        XCTAssertEqual(nohours.didntFit, [.init(taskID: "a", reason: .noWorkingHours)])
    }

    func testLongerThanAnyGapVersusNoRoomLeft() {
        let c = cal(), d = day(wed, c)
        let events = [event("a", wed, "11:00", "12:00", c), event("b", wed, "15:00", "16:00", c)]
        // Largest gap is 12:05-14:55 = 170 minutes.
        let long = DayPlan.fit(tasks: [task("huge", minutes: 200)], events: events, on: d, hours: WorkingHours(), calendar: c)
        XCTAssertEqual(long.didntFit, [.init(taskID: "huge", reason: .longerThanAnyGap)])
        let tooLong = DayPlan.fit(tasks: [task("ten-hours", minutes: 600)], events: [], on: d, hours: WorkingHours(), calendar: c)
        XCTAssertEqual(tooLong.didntFit.first?.reason, .longerThanAnyGap)
        let crowded = DayPlan.fit(tasks: [task("a", minutes: 170, priority: 1), task("b", minutes: 100, priority: 2), task("c", minutes: 120, priority: 3), task("d", minutes: 30, priority: 4)], events: events, on: d, hours: WorkingHours(), calendar: c)
        XCTAssertEqual(starts(crowded, c), ["b": "09:00", "a": "12:05", "d": "16:05"])
        XCTAssertEqual(crowded.didntFit, [.init(taskID: "c", reason: .noRoom)], "It would fit an empty gap, but the gaps are used up")
    }

    func testRecurringAndFixedZoneTasksArePlacedLikeAnyOther() throws {
        let c = cal(), d = day(wed, c)
        let repeating = task("daily", minutes: 30, extra: ["is_recurring": .bool(true), "recurrence_pattern": .object(["type": .string("daily"), "interval": .number(1)])])
        let fixed = task("ny", minutes: 30, extra: ["time_zone": .string("America/New_York")])
        let fit = DayPlan.fit(tasks: [repeating, fixed], events: [], on: d, hours: WorkingHours(), calendar: c)
        XCTAssertEqual(Set(fit.placements.map(\.taskID)), ["daily", "ny"])
        let changes = DayPlan.fieldChanges(fit, tasks: [repeating, fixed], calendar: c)
        XCTAssertEqual(changes.count, 2)
        let ny = try XCTUnwrap(changes.first { $0.task.id == "ny" })
        XCTAssertEqual(ny.fields["time_zone"], .string("America/New_York"), "A fixed time keeps its zone")
        XCTAssertNotNil(ny.fields["scheduled_at"])
        XCTAssertNil(changes.first { $0.task.id == "daily" }?.fields["duration_minutes"], "Fit keeps the estimate and writes only the time")
    }

    func testCompletedHeadingsAndChecklistChildrenAreNeverPlaced() {
        let c = cal(), d = day(wed, c)
        var done = task("done", minutes: 30); done["completed"] = .bool(true)
        let child = task(SubtaskTree.reference(parent: "parent", key: "k1"), minutes: 30)
        let fit = DayPlan.fit(tasks: [done, child, task("a", minutes: 30)], events: [], on: d, hours: WorkingHours(), calendar: c)
        XCTAssertEqual(fit.placements.map(\.taskID), ["a"]); XCTAssertTrue(fit.didntFit.isEmpty)
    }

    func testEveningTasksStayUntimedUnlessTheUserOptsIn() {
        let c = cal(), d = day(wed, c)
        let tasks = [task("work", minutes: 60), task("run", minutes: 45), task("read", minutes: 30)]
        let off = DayPlan.fit(tasks: tasks, events: [], on: d, hours: WorkingHours(), eveningIDs: ["run", "read"], calendar: c)
        XCTAssertEqual(off.placements.map(\.taskID), ["work"])
        XCTAssertEqual(off.didntFit, [.init(taskID: "run", reason: .evening), .init(taskID: "read", reason: .evening)])
        let on = DayPlan.fit(tasks: tasks, events: [], on: d, hours: WorkingHours(), eveningIDs: ["run", "read"], placeEvening: true, calendar: c)
        XCTAssertEqual(starts(on, c), ["work": "09:00", "run": "17:00", "read": "17:50"])
        let tight = DayPlan.fit(tasks: [task("a", minutes: 301, priority: 4)], events: [], on: d, hours: WorkingHours(), eveningIDs: ["a"], placeEvening: true, calendar: c)
        XCTAssertEqual(tight.didntFit.first?.reason, .longerThanAnyGap, "The evening ends at 22:00")
    }

    func testSpringForwardDayHasTwentyThreeRealHours() {
        let c = cal(), d = day("2026-03-29", c)
        let hours = WorkingHours(start: 0, end: 1440, weekdays: Set(1...7))
        let fit = DayPlan.fit(tasks: [task("long", minutes: 1320, date: "2026-03-29"), task("hour", minutes: 60, date: "2026-03-29")], events: [], on: d, hours: hours, calendar: c)
        XCTAssertEqual(starts(fit, c)["long"], "00:00")
        XCTAssertEqual(fit.didntFit, [.init(taskID: "hour", reason: .noRoom)], "22h + 5m buffer leaves 55 real minutes on a 23 hour day")
        let normal = DayPlan.fit(tasks: [task("long", minutes: 1320, date: "2026-11-11"), task("hour", minutes: 60, date: "2026-11-11")], events: [], on: day(wed, c), hours: WorkingHours(start: 0, end: 1440, weekdays: Set(1...7)), calendar: c)
        XCTAssertEqual(normal.placements.count, 2)
    }

    func testFallBackDayHasTwentyFiveRealHoursAndSkipsTheAmbiguousRepeat() throws {
        let c = cal(), d = day("2026-10-25", c)
        let long = DayPlan.fit(tasks: [task("long", minutes: 1440, date: "2026-10-25"), task("half", minutes: 30, date: "2026-10-25")], events: [], on: d, hours: WorkingHours(start: 0, end: 1440, weekdays: Set(1...7)), calendar: c)
        XCTAssertEqual(long.placements.count, 2, "The extra hour is real time")
        // 01:00-05:00 wall time covers both 02:xx hours. A start in the second 02:xx would be ambiguous for a floating time.
        let hours = WorkingHours(start: 60, end: 300, weekdays: Set(1...7))
        let hourly = (1...5).map { task("t\($0)", minutes: 60, date: "2026-10-25") }
        let fit = DayPlan.fit(tasks: hourly, events: [], on: d, hours: hours, calendar: c)
        XCTAssertEqual(fit.placements.count, 3)
        for placement in fit.placements {
            let source = try XCTUnwrap(hourly.first { $0.id == placement.taskID })
            XCTAssertNoThrow(try TaskPlanner.fields(task: source, start: placement.start, calendar: c), "Every start must be storable")
        }
        XCTAssertEqual(c.component(.hour, from: fit.placements[2].start), 3, "The third task starts at 03:00, not in the repeated 02:xx")
    }

    func testAppliedFitNeverOverlapsEventsOrEachOther() {
        let c = cal(), d = day(wed, c)
        let events = [event("a", wed, "09:30", "10:15", c), event("b", wed, "12:00", "13:00", c), event("c", wed, "14:20", "15:00", c)]
        let tasks = (1...9).map { task("t\($0)", minutes: [20, 35, 50, 25, 15, 40, 60, 30, 45][$0 - 1], priority: [2, 4, 3, 1, 4, 2, 3, 4, 1][$0 - 1]) }
        let fit = DayPlan.fit(tasks: tasks, events: events, on: d, hours: WorkingHours(), calendar: c)
        let after = DayPlan.applying(fit, to: tasks, calendar: c)
        for placement in fit.placements {
            let record = after.first { $0.id == placement.taskID }!
            XCTAssertTrue(TaskPlanner.conflicts(task: record, start: placement.start, minutes: placement.minutes, tasks: after.filter { $0.id != record.id }, events: events, calendar: c).isEmpty, record.title)
            XCTAssertEqual(clock(TaskPlanning.start(record, calendar: c)!, c), clock(placement.start, c))
            XCTAssertGreaterThanOrEqual(placement.start, at(wed, "09:00", c)); XCTAssertLessThanOrEqual(placement.end, at(wed, "17:00", c))
        }
        XCTAssertEqual(Set(fit.placements.map(\.taskID)).union(fit.didntFit.map(\.taskID)), Set(tasks.map(\.id)))
    }

    func testFirstSlotSuggestionIgnoresTheTaskItself() {
        let c = cal(), d = day(wed, c)
        let tasks = [task("fixed", minutes: 60, time: "09:00"), task("a", minutes: 30), task("b", minutes: 30, time: "10:30")]
        XCTAssertEqual(DayPlan.firstSlot(for: tasks[2], tasks: tasks, events: [], on: d, hours: WorkingHours(), calendar: c).map { clock($0, c) }, "10:05", "A task already placed can be moved to the first slot")
        XCTAssertEqual(DayPlan.firstSlot(for: tasks[1], tasks: tasks, events: [], on: d, hours: WorkingHours(), calendar: c).map { clock($0, c) }, "11:05", "Timed tasks block; other unscheduled tasks do not")
    }

    func testRoundedUpGridAnchorsAtTheStartOfTheDay() {
        let c = cal(), start = day(wed, c)
        XCTAssertEqual(DayPlan.roundedUp(at(wed, "09:00", c), from: start), at(wed, "09:00", c))
        XCTAssertEqual(DayPlan.roundedUp(at(wed, "09:01", c), from: start), at(wed, "09:05", c))
        XCTAssertEqual(DayPlan.roundedUp(at(wed, "09:05", c).addingTimeInterval(1), from: start), at(wed, "09:10", c))
    }

    // MARK: Estimates and the Today header

    func testEstimateFieldsAreBoundedAndOnlyWriteTheDuration() throws {
        XCTAssertEqual(try DayPlan.estimateFields(minutes: 90), ["duration_minutes": .number(90)])
        XCTAssertThrowsError(try DayPlan.estimateFields(minutes: 0)); XCTAssertThrowsError(try DayPlan.estimateFields(minutes: 10081))
        XCTAssertEqual(DayPlan.chips, [15, 30, 60, 120]); XCTAssertEqual(DayPlan.withoutEstimate([task("a"), task("b", minutes: 5)]).map(\.id), ["a"])
    }

    func testHeaderPromptFollowsThePlannedStateAndWorkingHours() {
        let c = cal(), hours = WorkingHours()
        let fresh = DayPlanState(today: wed), planned = DayPlanState(today: wed, plannedIDs: ["a"], planned: true), closed = DayPlanState(today: wed, planned: true, shutDown: true)
        let morning = at(wed, "08:30", c), afternoon = at(wed, "15:00", c), evening = at(wed, "17:30", c)
        XCTAssertEqual(DayPlan.prompt(state: fresh, now: morning, hours: hours, hasWork: true, calendar: c), .plan)
        XCTAssertNil(DayPlan.prompt(state: fresh, now: morning, hours: hours, hasWork: false, calendar: c), "Nothing to plan, nothing to say")
        XCTAssertEqual(DayPlan.prompt(state: planned, now: afternoon, hours: hours, hasWork: true, calendar: c), .planned)
        XCTAssertEqual(DayPlan.prompt(state: planned, now: evening, hours: hours, hasWork: true, calendar: c), .shutdown)
        XCTAssertEqual(DayPlan.prompt(state: fresh, now: evening, hours: hours, hasWork: true, calendar: c), .shutdown, "No nagging to plan after hours")
        XCTAssertEqual(DayPlan.prompt(state: closed, now: evening, hours: hours, hasWork: true, calendar: c), .shutDown)
        XCTAssertEqual(DayPlan.prompt(state: closed, now: morning, hours: hours, hasWork: true, calendar: c), .shutDown)
        let saturday = day("2026-11-14", c)
        XCTAssertFalse(DayPlan.isAfterWorkingHours(now: saturday.addingTimeInterval(17 * 3600), hours: hours, calendar: c), "A non-working day ends at 18:00")
        XCTAssertTrue(DayPlan.isAfterWorkingHours(now: saturday.addingTimeInterval(18 * 3600), hours: hours, calendar: c))
        XCTAssertTrue(DayPlan.isAfterWorkingHours(now: at(wed, "17:00", c), hours: hours, calendar: c)); XCTAssertFalse(DayPlan.isAfterWorkingHours(now: at(wed, "16:59", c), hours: hours, calendar: c))
    }

    // MARK: Planned-today state

    func testPlannedStateIsPerAccountAndExpiresWithTheDay() throws {
        let rows = [order("planning:day:2026-11-11", ["a", "b", "a"]), order("planning:shutdown:2026-11-10", []), order("planning:day:2026-11-09", ["x"]),
                    order("planning:day:2026-11-11", ["other"], user: "someone-else"), order("planning:evening:2026-11-11", ["e"]), order("planning:day:not-a-day", ["z"])]
        let state = DayPlan.state(rows: rows, account: account, today: wed)
        XCTAssertTrue(state.planned); XCTAssertFalse(state.shutDown); XCTAssertEqual(state.plannedIDs, ["a", "b"])
        XCTAssertEqual(state.expiredKeys, ["planning:day:2026-11-09", "planning:shutdown:2026-11-10"])
        let tomorrow = DayPlan.state(rows: rows, account: account, today: "2026-11-12")
        XCTAssertFalse(tomorrow.planned); XCTAssertEqual(tomorrow.plannedIDs, [])
        XCTAssertFalse(DayPlan.state(rows: rows, account: "", today: wed).planned)
        XCTAssertFalse(DayPlan.state(rows: rows, account: "someone-else", today: "2026-11-10").planned)
    }

    func testMarkPlannedWritesOneRowCleansUpAndIsIdempotent() throws {
        var snapshot = Snapshot(); snapshot.tables["view_orders"] = [order("planning:day:2026-11-09", ["x"]), order("planning:shutdown:2026-11-09", [])]
        var changes = try DayPlan.markPlanned(ids: ["a", "b", "a", ""], rows: snapshot.tables["view_orders"]!, account: account, today: wed)
        XCTAssertEqual(changes.map(\.method), ["DELETE", "DELETE", "POST"]); XCTAssertEqual(changes.last?.recordID, "planning:day:2026-11-11")
        XCTAssertEqual(changes.last?.fields["ids"], .array([.string("a"), .string("b")])); XCTAssertEqual(changes.last?.fields["user_id"], .string(account))
        for change in changes { snapshot.apply(change) }
        let rows = snapshot.tables["view_orders"]!
        XCTAssertEqual(rows.map(\.id), ["planning:day:2026-11-11"])
        XCTAssertEqual(try DayPlan.markPlanned(ids: ["a", "b"], rows: rows, account: account, today: wed), [], "The same plan is not written twice")
        changes = try DayPlan.markPlanned(ids: ["a", "b", "c"], rows: rows, account: account, today: wed)
        XCTAssertEqual(changes.map(\.method), ["PATCH"])
        XCTAssertThrowsError(try DayPlan.markPlanned(ids: ["a"], rows: [], account: "", today: wed))
        XCTAssertThrowsError(try DayPlan.markPlanned(ids: ["a"], rows: [order("planning:day:2026-11-11", [], user: "someone-else")], account: account, today: wed))
    }

    func testMarkShutdownIsAnEmptyMarkerThatDoesNotChangePlannedState() throws {
        var snapshot = Snapshot(); snapshot.tables["view_orders"] = [order("planning:day:2026-11-11", ["a"])]
        let changes = try DayPlan.markShutdown(rows: snapshot.tables["view_orders"]!, account: account, today: wed)
        XCTAssertEqual(changes.map(\.recordID), ["planning:shutdown:2026-11-11"]); XCTAssertEqual(changes.first?.fields["ids"], .array([]))
        for change in changes { snapshot.apply(change) }
        let state = DayPlan.state(rows: snapshot.tables["view_orders"]!, account: account, today: wed)
        XCTAssertTrue(state.planned); XCTAssertTrue(state.shutDown); XCTAssertEqual(state.plannedIDs, ["a"])
        XCTAssertEqual(try DayPlan.markShutdown(rows: snapshot.tables["view_orders"]!, account: account, today: wed), [])
    }

    func testPlannedKeysNeverCollideWithEveningOrSomeday() {
        let state = Planning.state(rows: [order("planning:day:2026-11-09", ["a"]), order("planning:shutdown:2026-11-09", []), order("planning:evening:2026-11-11", ["e"]), order("planning:someday", ["s"])], account: account, today: wed)
        XCTAssertEqual(state.evening, ["e"]); XCTAssertEqual(state.someday, ["s"]); XCTAssertEqual(state.expiredEveningKeys, [])
        XCTAssertLessThan(DayPlan.plannedKey("2026-11-11").utf8.count, Planning.maxKeyBytes)
    }

    // MARK: Shutdown

    func testCompletedTodayCountsRootTasksInTheLocalDay() {
        let c = cal(), d = day(wed, c)
        func done(_ id: String, _ stamp: String?) -> Record { var t = task(id); t["completed"] = .bool(true); if let stamp { t["completed_at"] = .string(stamp) }; return t }
        let tasks = [done("a", "2026-11-11T08:00:00Z"), done("b", "2026-11-11T22:59:59Z"), done("midnight", "2026-11-11T23:00:00Z"), done("early", "2026-11-10T22:59:59Z"), done("nostamp", nil), done(SubtaskTree.reference(parent: "p", key: "k1"), "2026-11-11T09:00:00Z"), task("open")]
        XCTAssertEqual(DayPlan.completedCount(tasks, on: d, calendar: c), 2)
    }

    func testShutdownListsOpenWorkPlannedForTodayInOrder() {
        let c = cal()
        var done = task("done"); done["completed"] = .bool(true)
        let tasks = [task("a"), done, task("tomorrow", date: "2026-11-12"), task("b"), task("overdue", date: "2026-11-09"), task("moved", date: "2026-11-12"), task(SubtaskTree.reference(parent: "p", key: "k1"))]
        XCTAssertEqual(DayPlan.openForShutdown(tasks, plannedIDs: [], day: wed, calendar: c).map(\.id), ["a", "b"])
        XCTAssertEqual(DayPlan.openForShutdown(tasks, plannedIDs: ["overdue", "moved", "done"], day: wed, calendar: c).map(\.id), ["a", "b", "overdue"], "Planned and still open, but not moved to a later day")
    }

    func testClosingLineIsStablePerDayAndWarm() {
        XCTAssertEqual(DayPlan.closingLine(for: wed), DayPlan.closingLine(for: wed))
        XCTAssertTrue(DayPlan.closingLines.contains(DayPlan.closingLine(for: "2026-11-12")))
        XCTAssertGreaterThan(Set((1...28).map { DayPlan.closingLine(for: String(format: "2026-11-%02d", $0)) }).count, 1)
        XCTAssertFalse(DayPlan.closingLines.contains { $0.contains("!") }, "Calm, not celebratory")
    }

    func testStreakTextNeedsGoalsAndARunningStreak() {
        func summary(goal: Bool, length: Int) -> MomentumSummary {
            MomentumSummary(hasDailyGoal: goal, hasWeeklyGoal: false, dailyStreak: .init(length: length, since: nil), longestDailyStreak: .none, weeklyStreak: .none, longestWeeklyStreak: .none,
                            score: nil, totalCompletions: 0, level: Momentum.level(totalCompletions: 0, longestDailyStreak: 0), week: [], vacation: .off, reliable: true)
        }
        XCTAssertEqual(DayPlan.streakText(summary(goal: true, length: 7)), "7-day streak")
        XCTAssertEqual(DayPlan.streakText(summary(goal: true, length: 1)), "1-day streak")
        XCTAssertNil(DayPlan.streakText(summary(goal: true, length: 0))); XCTAssertNil(DayPlan.streakText(summary(goal: false, length: 7))); XCTAssertNil(DayPlan.streakText(nil))
    }
}
