import XCTest
@testable import TaskfoldCore

/// The Today header ring (Core/DayPlan.swift, `DayPlan.todayRing`): segments are today's tasks sized by estimate.
final class TodayRingTests: XCTestCase {
    func cal() -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!; return c }
    func at(_ hhmm: String, _ c: Calendar) -> Date {
        let p = hhmm.split(separator: ":").map { Int($0)! }
        return c.date(from: DateComponents(timeZone: c.timeZone, year: 2026, month: 11, day: 11, hour: p[0], minute: p[1]))!
    }
    func task(_ id: String, minutes: Int? = nil, project: String = "p", date: String = "2026-11-11", time: String? = nil, done: Bool = false) -> Record {
        var row = Record.task(user: "owner", createdAt: "2026-11-01T09:00:00Z")
        row["id"] = .string(id); row["title"] = .string("Task " + id); row["due_date"] = .string(date); row["project_id"] = .string(project)
        if let time { row["due_time"] = .string(time) }
        if let minutes { row["duration_minutes"] = .number(Double(minutes)) }
        if done { row["completed"] = .bool(true) }
        return row
    }
    func ring(_ tasks: [Record], _ events: [PlannerEvent] = [], hours: WorkingHours? = WorkingHours()) -> TodayRing {
        let c = cal(); return DayPlan.todayRing(tasks, events: events, on: Dates.parse("2026-11-11", calendar: c)!, hours: hours, calendar: c)
    }

    func testSegmentsAreSizedByEstimateAgainstFreeCapacity() {
        // 8h working day minus 2h of meetings: 6h free. 4h 10m planned, 45m of it done.
        let c = cal()
        let events = [PlannerEvent(id: "m1", calendarID: "w", title: "m1", start: at("10:00", c), end: at("11:00", c)),
                      PlannerEvent(id: "m2", calendarID: "w", title: "m2", start: at("14:00", c), end: at("15:00", c))]
        let r = ring([task("a", minutes: 90, project: "focus"), task("b", minutes: 45, project: "work", done: true),
                      task("c", minutes: 30, project: "home"), task("d", minutes: 30, project: "home"), task("e", minutes: 25, project: "home"),
                      task("f", minutes: 30, project: "personal")], events)
        XCTAssertEqual(r.plannedMinutes, 250); XCTAssertEqual(r.doneMinutes, 45); XCTAssertEqual(r.freeMinutes, 360)
        XCTAssertEqual(r.figure, "4h 10m"); XCTAssertEqual(r.capacity, "of 6h")
        XCTAssertEqual(r.segments.map(\.id), ["a", "b", "c", "d", "e", "f"])
        XCTAssertEqual(r.segments.map(\.done), [false, true, false, false, false, false])
        XCTAssertEqual(r.segments[0].length, 90.0 / 360, accuracy: 1e-9)
        XCTAssertEqual(r.segments[1].start, 90.0 / 360, accuracy: 1e-9)
        let end = r.segments.last.map { $0.start + $0.length } ?? 0
        XCTAssertEqual(end, 250.0 / 360, accuracy: 1e-9, "the rest of the track is free capacity")
        XCTAssertEqual(r.doneCount, 1); XCTAssertEqual(r.taskCount, 6)
        XCTAssertEqual(r.accessibilityLabel, "Today: 4 hours 10 minutes planned of 6 hours free, 45 minutes done. 1 of 6 tasks done")
    }

    func testOverFullDayFillsTheWholeRing() {
        let r = ring([task("a", minutes: 300), task("b", minutes: 300)])
        XCTAssertTrue(r.isOver)
        XCTAssertEqual(r.segments.map(\.length).reduce(0, +), 1, accuracy: 1e-9)
    }

    func testTimedTasksComeFirstByStartThenGivenOrder() {
        let r = ring([task("late", minutes: 30, time: "15:00"), task("loose", minutes: 30), task("early", minutes: 30, time: "09:00")])
        XCTAssertEqual(r.segments.map(\.id), ["early", "late", "loose"])
    }

    func testOnlyTodaysEstimatedTopLevelTasksBecomeSegments() {
        let r = ring([task("today", minutes: 30), task("tomorrow", minutes: 30, date: "2026-11-12"), task("noEstimate"), task("done", minutes: 15, done: true)])
        XCTAssertEqual(r.segments.map(\.id), ["today", "done"])
        XCTAssertEqual(r.unestimatedCount, 1); XCTAssertEqual(r.taskCount, 3)
        XCTAssertTrue(r.accessibilityLabel.hasSuffix(", 1 without an estimate"))
    }

    func testWithoutWorkingHoursSegmentsShareTheCircleAndSaySo() {
        let r = ring([task("a", minutes: 60), task("b", minutes: 30)], hours: nil)
        XCTAssertFalse(r.hasWorkingHours); XCTAssertNil(r.capacity)
        XCTAssertEqual(r.segments[0].length, 2.0 / 3, accuracy: 1e-9)
        XCTAssertTrue(r.accessibilityLabel.contains("Working hours not set"))
    }

    func testEmptyDayHasNoSegments() {
        let r = ring([])
        XCTAssertTrue(r.segments.isEmpty); XCTAssertEqual(r.figure, "0m"); XCTAssertEqual(r.capacity, "of 8h")
    }

    func testRemainderIsOnlyTheUnplannedPartOfTheCircle() {
        let r = ring([task("a", minutes: 120), task("b", minutes: 120)])
        XCTAssertEqual(r.remainder.start, 0.5, accuracy: 1e-9); XCTAssertEqual(r.remainder.length, 0.5, accuracy: 1e-9)
        XCTAssertEqual(ring([task("a", minutes: 600)]).remainder.length, 0, accuracy: 1e-9, "an over-full day has no track at all")
        XCTAssertEqual(ring([]).remainder.length, 1, accuracy: 1e-9, "an empty day is all remainder")
    }

    func testMidpointIsWhereTheFoldLands() {
        let r = ring([task("a", minutes: 120), task("b", minutes: 240)])
        XCTAssertEqual(r.midpoint(of: "a") ?? -1, 60.0 / 480, accuracy: 1e-9)
        XCTAssertEqual(r.midpoint(of: "b") ?? -1, 240.0 / 480, accuracy: 1e-9)
        XCTAssertNil(r.midpoint(of: "missing"))
    }

    // MARK: The ring on every list (round 6)

    /// Monday-first English calendar in Copenhagen, so week tests do not depend on the machine's region.
    func week(first: Int = 2) -> Calendar { var c = cal(); c.firstWeekday = first; c.locale = Locale(identifier: "en_US_POSIX"); return c }
    func date(_ key: String, _ c: Calendar) -> Date { Dates.parse(key, calendar: c)! }
    let allDays = WorkingHours(start: 9 * 60, end: 15 * 60, weekdays: Set(1...7))

    func testRingForAnyDateMatchesTodayRingAndOnlyReadsThatDay() {
        let c = cal()
        let tasks = [task("a", minutes: 60, date: "2026-11-12"), task("b", minutes: 30, date: "2026-11-12", done: true), task("c", minutes: 45, date: "2026-11-11")]
        let thursday = DayPlan.ring(for: date("2026-11-12", c), tasks: tasks, events: [], hours: allDays, calendar: c)
        XCTAssertEqual(thursday.segments.map(\.id), ["a", "b"])
        XCTAssertEqual(thursday.plannedMinutes, 90); XCTAssertEqual(thursday.doneMinutes, 30); XCTAssertEqual(thursday.freeMinutes, 360)
        let wednesday = date("2026-11-11", c)
        XCTAssertEqual(DayPlan.ring(for: wednesday, tasks: tasks, events: [], hours: allDays, calendar: c),
                       DayPlan.todayRing(tasks, events: [], on: wednesday, hours: allDays, calendar: c), "todayRing is ring(for:) for today")
    }
    func testMeetingsOnAnotherDayDoNotReduceThisDaysFreeTime() {
        let c = cal()
        let wednesdayMeeting = PlannerEvent(id: "m", calendarID: "w", title: "m", start: at("10:00", c), end: at("12:00", c))
        let thursday = DayPlan.ring(for: date("2026-11-12", c), tasks: [task("a", minutes: 60, date: "2026-11-12")], events: [wednesdayMeeting], hours: allDays, calendar: c)
        XCTAssertEqual(thursday.freeMinutes, 360)
    }
    func testRingsForSeveralDaysSortTasksIntoTheirDays() {
        let c = cal()
        let days = ["2026-11-11", "2026-11-12", "2026-11-13"].map { date($0, c) }
        let tasks = [task("a", minutes: 60, date: "2026-11-12"), task("b", minutes: 30, date: "2026-11-13"), task("c", minutes: 15, date: "2026-11-12"), task("far", minutes: 99, date: "2026-12-01")]
        let rings = DayPlan.rings(for: days, tasks: tasks, events: [], hours: allDays, calendar: c)
        XCTAssertEqual(rings["2026-11-11"]?.segments.count, 0)
        XCTAssertEqual(rings["2026-11-12"]?.segments.map(\.id), ["a", "c"])
        XCTAssertEqual(rings["2026-11-13"]?.plannedMinutes, 30)
        XCTAssertNil(rings["2026-12-01"])
        XCTAssertEqual(rings["2026-11-12"], DayPlan.ring(for: days[1], tasks: tasks, events: [], hours: allDays, calendar: c))
    }

    func testDayFigureWithinCapacityIsPlannedOfFree() {
        let c = cal()
        let r = DayPlan.ring(for: date("2026-11-11", c), tasks: [task("a", minutes: 90), task("b", minutes: 45), task("c", minutes: 115)], events: [], hours: allDays, calendar: c)
        let figure = DayPlan.dayFigure(r, hours: allDays)
        XCTAssertEqual(figure, DayFigure(lead: "4h 10m", leadIsAlert: false, rest: " of 6h"))
        XCTAssertEqual(figure.text, "4h 10m of 6h")
        XCTAssertEqual(r.overMinutes, 0); XCTAssertEqual(r.overflowFraction, 0)
        XCTAssertEqual(DayPlan.dayRingLabel(r, name: "Today 11 Nov", hours: allDays), "Today 11 Nov: 4 hours 10 minutes planned of 6 hours free. 0 of 3 tasks done")
    }
    func testOverbookedDayClosesTheRingAndMeasuresTheOverflow() {
        let c = cal()
        let r = DayPlan.ring(for: date("2026-11-11", c), tasks: [task("a", minutes: 240), task("b", minutes: 120), task("c", minutes: 90)], events: [], hours: allDays, calendar: c)
        XCTAssertEqual(r.plannedMinutes, 450); XCTAssertTrue(r.isOver)
        XCTAssertEqual(r.overMinutes, 90)
        XCTAssertEqual(r.overflowFraction, 0.25, accuracy: 1e-9, "1h 30m over 6h is a quarter of the circle")
        XCTAssertEqual(r.segments.map(\.length).reduce(0, +), 1, accuracy: 1e-9, "the ring itself is closed")
        let figure = DayPlan.dayFigure(r, hours: allDays)
        XCTAssertEqual(figure.lead, "1h 30m over"); XCTAssertTrue(figure.leadIsAlert)
        XCTAssertEqual(figure.text, "1h 30m over · 7h 30m of 6h")
        XCTAssertEqual(DayPlan.dayRingLabel(r, name: "Monday", hours: allDays), "Monday: 7 hours 30 minutes planned of 6 hours free, 1 hour 30 minutes over. 0 of 3 tasks done")
        XCTAssertEqual(r.accessibilityLabel(for: "Monday"), "Monday: 7 hours 30 minutes planned of 6 hours free. 0 of 3 tasks done", "the plain label never mentions over")
    }
    func testOverflowIsCappedAtOneFullTurn() {
        let c = cal()
        let r = DayPlan.ring(for: date("2026-11-11", c), tasks: [task("a", minutes: 900)], events: [], hours: allDays, calendar: c)
        XCTAssertEqual(r.overflowFraction, 1, accuracy: 1e-9)
    }
    func testDayOffIsHoursSetButNotForThisDay() {
        let c = cal()
        let weekdaysOnly = WorkingHours() // Monday to Friday; 14 Nov 2026 is a Saturday
        let saturday = date("2026-11-14", c)
        let busy = DayPlan.ring(for: saturday, tasks: [task("a", minutes: 25, date: "2026-11-14")], events: [], hours: weekdaysOnly, calendar: c)
        XCTAssertFalse(busy.hasWorkingHours)
        XCTAssertEqual(DayPlan.dayFigure(busy, hours: weekdaysOnly), DayFigure(lead: "", leadIsAlert: false, rest: "Day off · 1 task"))
        let two = DayPlan.ring(for: saturday, tasks: [task("a", minutes: 25, date: "2026-11-14"), task("b", date: "2026-11-14")], events: [], hours: weekdaysOnly, calendar: c)
        XCTAssertEqual(DayPlan.dayFigure(two, hours: weekdaysOnly).text, "Day off · 2 tasks")
        let empty = DayPlan.ring(for: saturday, tasks: [], events: [], hours: weekdaysOnly, calendar: c)
        XCTAssertEqual(DayPlan.dayFigure(empty, hours: weekdaysOnly).text, "Day off")
        XCTAssertEqual(DayPlan.dayRingLabel(busy, name: "Saturday 14 Nov", hours: weekdaysOnly), "Saturday 14 Nov: day off, 1 task")
        XCTAssertEqual(busy.overMinutes, 0, "nothing to be over without hours")
        XCTAssertTrue(DayPlan.isDayOff(busy, hours: weekdaysOnly)); XCTAssertFalse(DayPlan.isDayOff(busy, hours: nil))
        XCTAssertTrue(busy.outline.segments.isEmpty, "a day off draws only the dashed outline")
        XCTAssertEqual(busy.outline.remainder.length, 1, accuracy: 1e-9)
    }
    func testHoursNeverSetSaysPlannedInsteadOfDayOff() {
        let c = cal()
        let r = DayPlan.ring(for: date("2026-11-14", c), tasks: [task("a", minutes: 90, date: "2026-11-14")], events: [], hours: nil, calendar: c)
        XCTAssertEqual(DayPlan.dayFigure(r, hours: nil).text, "1h 30m planned")
    }

    // MARK: Project week

    func testProjectWeekRingIsThisProjectsEstimatedWorkDueThisWeek() {
        let c = week()
        let tasks = [task("mon", minutes: 60, project: "p", date: "2026-11-09", done: true), task("wed", minutes: 90, project: "p", date: "2026-11-11"),
                     task("sun", minutes: 30, project: "p", date: "2026-11-15"), task("next", minutes: 120, project: "p", date: "2026-11-16"),
                     task("last", minutes: 45, project: "p", date: "2026-11-08"), task("noEstimate", project: "p", date: "2026-11-10"),
                     task("other", minutes: 150, project: "q", date: "2026-11-10")]
        let w = DayPlan.projectWeekRing(tasks, project: "p", on: date("2026-11-11", c), calendar: c)
        XCTAssertEqual(w?.plannedMinutes, 180); XCTAssertEqual(w?.doneMinutes, 60); XCTAssertEqual(w?.weekPlannedMinutes, 330)
        XCTAssertEqual(w?.figure, "1h"); XCTAssertEqual(w?.rest, "of 3h this week")
        XCTAssertEqual(w?.ring.segments.map(\.id), ["mon", "wed", "sun"], "done work first, then by day")
        XCTAssertEqual(w?.ring.segments.map(\.done), [true, false, false])
        XCTAssertEqual(w?.ring.segments.map(\.length).reduce(0, +) ?? 0, 1, accuracy: 1e-9, "the project's week is the whole circle")
        XCTAssertEqual(w?.ring.remainder.length ?? 1, 0, accuracy: 0.0005)
        XCTAssertEqual(w?.shareLine, "About half of your planned week")
        XCTAssertEqual(w?.accessibilityLabel, "This week: 1 hour done of 3 hours. About half of your planned week")
    }
    func testProjectWeekFollowsTheCalendarsFirstWeekday() {
        let tasks = [task("sat", minutes: 30, project: "p", date: "2026-11-14"), task("sun", minutes: 60, project: "p", date: "2026-11-15")]
        let mondayFirst = DayPlan.projectWeekRing(tasks, project: "p", on: date("2026-11-11", week()), calendar: week())
        XCTAssertEqual(mondayFirst?.plannedMinutes, 90, "Saturday and Sunday close a Monday week")
        let sundayFirst = DayPlan.projectWeekRing(tasks, project: "p", on: date("2026-11-11", week(first: 1)), calendar: week(first: 1))
        XCTAssertEqual(sundayFirst?.plannedMinutes, 30, "Sunday 15 Nov starts the next Sunday week")
    }
    func testProjectWeekIsNilWhenNothingIsEstimatedThisWeek() {
        let c = week()
        let tasks = [task("a", project: "p", date: "2026-11-10"), task("b", minutes: 30, project: "p", date: "2026-11-20"), task("c", minutes: 30, project: "q", date: "2026-11-10")]
        XCTAssertNil(DayPlan.projectWeekRing(tasks, project: "p", on: date("2026-11-11", c), calendar: c))
        XCTAssertNil(DayPlan.projectWeekRing(tasks, project: "", on: date("2026-11-11", c), calendar: c), "Inbox has no week ring")
    }
    func testProjectWeekShareReadsPlainly() {
        func line(_ mine: Int, of total: Int) -> String? {
            ProjectWeekRing(ring: ring([]), plannedMinutes: mine, doneMinutes: 0, weekPlannedMinutes: total).shareLine
        }
        XCTAssertEqual(line(5, of: 100), "A small part of your planned week")
        XCTAssertEqual(line(25, of: 100), "About a quarter of your planned week")
        XCTAssertEqual(line(33, of: 100), "About a third of your planned week")
        XCTAssertEqual(line(67, of: 100), "About two thirds of your planned week")
        XCTAssertEqual(line(90, of: 100), "Most of your planned week")
        XCTAssertEqual(line(98, of: 100), "Nearly all of your planned week")
        XCTAssertEqual(line(100, of: 100), "All of your planned week")
        XCTAssertNil(line(0, of: 0), "no planned time, no line")
    }
}
