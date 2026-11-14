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
}
