import XCTest
@testable import TaskfoldCore

/// The planner header's capacity ring (Core/DayPlan.swift): planned time against free time for one day.
final class CapacityRingTests: XCTestCase {
    func cal() -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!; return c }
    func at(_ day: String, _ hhmm: String, _ c: Calendar) -> Date {
        let p = hhmm.split(separator: ":").map { Int($0)! }
        return c.date(from: DateComponents(timeZone: c.timeZone, year: Int(day.prefix(4)), month: Int(day.dropFirst(5).prefix(2)), day: Int(day.suffix(2)), hour: p[0], minute: p[1]))!
    }
    func task(_ id: String, minutes: Int? = nil, date: String = "2026-11-11", done: Bool = false) -> Record {
        var row = Record.task(user: "owner", createdAt: "2026-11-01T09:00:00Z")
        row["id"] = .string(id); row["title"] = .string("Task " + id); row["due_date"] = .string(date)
        if let minutes { row["duration_minutes"] = .number(Double(minutes)) }
        if done { row["completed"] = .bool(true) }
        return row
    }
    func event(_ id: String, _ from: String, _ to: String, _ c: Calendar, day: String = "2026-11-11", allDay: Bool = false) -> PlannerEvent {
        PlannerEvent(id: id, calendarID: "work", title: id, start: at(day, from, c), end: at(day, to, c), allDay: allDay)
    }
    func ring(_ tasks: [Record], _ events: [PlannerEvent] = [], day: String = "2026-11-11", hours: WorkingHours? = WorkingHours()) -> CapacityRing {
        let c = cal(); return DayPlan.capacityRing(tasks, events: events, on: Dates.parse(day, calendar: c)!, hours: hours, calendar: c)
    }

    func testPlannedAgainstFreeFitsWithoutOfferingFit() {
        // 08:00 working day minus 2h of meetings leaves 6h free; 4h30 planned fits.
        let c = cal()
        let r = ring([task("a", minutes: 120), task("b", minutes: 90), task("c", minutes: 60)], [event("m1", "10:00", "11:00", c), event("m2", "14:00", "15:00", c)])
        XCTAssertEqual(r.plannedMinutes, 270); XCTAssertEqual(r.freeMinutes, 360)
        XCTAssertEqual(r.label, "4h 30m planned · 6h free")
        XCTAssertFalse(r.isOver); XCTAssertFalse(r.offersFit)
        XCTAssertEqual(r.fraction, 0.75, accuracy: 0.001)
        XCTAssertEqual(r.accessibilityLabel, "Capacity: 4 hours 30 minutes planned, 6 hours free")
    }

    func testOverCapacityOffersFitAndSpeaksTheOverage() {
        let c = cal()
        let r = ring([task("a", minutes: 300), task("b", minutes: 240)], [event("m1", "09:00", "11:00", c)])
        XCTAssertEqual(r.label, "9h planned · 6h free")
        XCTAssertTrue(r.isOver); XCTAssertTrue(r.offersFit); XCTAssertEqual(r.overMinutes, 180); XCTAssertEqual(r.fraction, 1)
        XCTAssertEqual(r.accessibilityLabel, "Capacity: 9 hours planned, 6 hours free, 3 hours over")
    }

    func testExactlyFullIsNotOver() {
        let r = ring([task("a", minutes: 480)])
        XCTAssertFalse(r.isOver); XCTAssertFalse(r.offersFit); XCTAssertEqual(r.fraction, 1)
    }

    func testOnlyThatDaysOpenEstimatesCountAndMissingEstimatesAreNoted() {
        let r = ring([task("a", minutes: 60), task("b"), task("c"), task("later", minutes: 600, date: "2026-11-12"), task("done", minutes: 600, done: true)])
        XCTAssertEqual(r.plannedMinutes, 60); XCTAssertEqual(r.unestimatedCount, 2)
        XCTAssertEqual(r.accessibilityLabel, "Capacity: 1 hour planned, 8 hours free, 2 tasks without estimates")
    }

    func testAllDayAndOverlappingEventsDoNotDistortFreeTime() {
        let c = cal()
        let events = [event("ooo", "00:00", "23:59", c, allDay: true), event("a", "09:00", "10:00", c), event("b", "09:30", "10:30", c)]
        XCTAssertEqual(ring([task("a", minutes: 60)], events).freeMinutes, 390)
    }

    func testDayWithoutWorkingHoursNeverOffersFit() {
        let off = ring([task("a", minutes: 120, date: "2026-11-14")], day: "2026-11-14")
        XCTAssertFalse(off.hasWorkingHours); XCTAssertFalse(off.offersFit); XCTAssertEqual(off.fraction, 0)
        XCTAssertEqual(off.label, "2h planned. Set working hours to see what fits.")
        XCTAssertEqual(off.accessibilityLabel, "Capacity: 2 hours planned. Set working hours to see what fits.")
        XCTAssertFalse(ring([task("a", minutes: 120)], hours: nil).offersFit)
    }

    func testEmptyDayIsCalm() {
        let r = ring([])
        XCTAssertEqual(r.label, "0m planned · 8h free"); XCTAssertEqual(r.fraction, 0); XCTAssertFalse(r.offersFit)
    }
}
