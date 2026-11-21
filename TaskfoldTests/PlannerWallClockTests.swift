import XCTest
@testable import TaskfoldCore

/// Time grids label their rows 0:00–23:00 on the wall clock. On a daylight-saving changeover day the day lasts 23 or 25
/// hours, so a position read from elapsed seconds drifts an hour off its label after the change; `TaskPlanner.wallMinute`
/// reads the clock instead. Europe/Copenhagen: spring forward on 29 March 2026 (02:00 → 03:00), fall back on 25 October
/// 2026 (03:00 → 02:00).
final class PlannerWallClockTests: XCTestCase {
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Europe/Copenhagen")!; return value }
    private func day(_ key: String) -> Date { Dates.parse(key, calendar: calendar)! }
    private func at(_ key: String, _ hour: Int, _ minute: Int, fold: Calendar.RepeatedTimePolicy = .first) -> Date {
        TaskPlanning.wallTime(day: day(key), hour: hour, minute: minute, calendar: calendar, fold: fold)!
    }
    private func task(_ id: String, _ key: String, _ time: String, _ minutes: Int? = nil) -> Record {
        var row = Record(["id": .string(id), "title": .string(id), "due_date": .string(key), "due_time": .string(time)])
        if let minutes { row["duration_minutes"] = .number(Double(minutes)) }
        return row
    }

    func testOrdinaryDayWallMinuteMatchesElapsedMinute() {
        let key = "2026-11-18"
        XCTAssertEqual(calendar.dateInterval(of: .day, for: day(key))?.duration, 86_400)
        for (hour, minute) in [(0, 0), (9, 0), (10, 15), (23, 45)] {
            let date = at(key, hour, minute)
            XCTAssertEqual(TaskPlanner.wallMinute(date, on: day(key), calendar: calendar), Double(hour * 60 + minute))
        }
        let blocks = TaskPlanner.blocks([task("a", key, "10:15", 60)], on: day(key), calendar: calendar)
        XCTAssertEqual(blocks.first?.minute, 615)
    }

    func testSpringForwardKeepsBlocksOnTheirHourLabels() throws {
        let key = "2026-03-29"
        XCTAssertEqual(calendar.dateInterval(of: .day, for: day(key))?.duration, 23 * 3600)
        // Before the change, elapsed and wall clock agree.
        XCTAssertEqual(TaskPlanner.wallMinute(at(key, 1, 30), on: day(key), calendar: calendar), 90)
        // After it, elapsed time is an hour short of the clock: 10:00 is 540 elapsed minutes, but sits on the 10:00 line.
        let blocks = TaskPlanner.blocks([task("standup", key, "10:00", 30), task("late", key, "23:30", 30)], on: day(key), calendar: calendar)
        let standup = try XCTUnwrap(blocks.first { $0.id == "standup" }), late = try XCTUnwrap(blocks.first { $0.id == "late" })
        XCTAssertEqual(standup.minute, 540, "PlannerBlock.minute stays elapsed time (lanes and capacity read it)")
        XCTAssertEqual(TaskPlanner.wallMinute(standup.clippedStart, on: day(key), calendar: calendar), 600)
        XCTAssertEqual(TaskPlanner.wallMinute(late.clippedStart, on: day(key), calendar: calendar), 1410)
        // The skipped hour does not exist: 02:30 resolves to the next valid minute, 03:00.
        XCTAssertEqual(TaskPlanner.wallMinute(at(key, 2, 30), on: day(key), calendar: calendar), 180)
        // Events go through the shared timeline layout; the same reading applies.
        let event = PlannerEvent(id: "review", calendarID: "c", start: at(key, 14, 30), end: at(key, 15, 0))
        let item = try XCTUnwrap(PlannerTimelineItem.layout(blocks: [], events: [event], on: day(key), calendar: calendar).first)
        let start = try XCTUnwrap(calendar.dateInterval(of: .day, for: day(key))).start.addingTimeInterval(item.minute * 60)
        XCTAssertEqual(item.minute, 810)
        XCTAssertEqual(TaskPlanner.wallMinute(start, on: day(key), calendar: calendar), 870)
    }

    func testFallBackKeepsBlocksOnTheirHourLabels() throws {
        let key = "2026-10-25"
        XCTAssertEqual(calendar.dateInterval(of: .day, for: day(key))?.duration, 25 * 3600)
        let blocks = TaskPlanner.blocks([task("standup", key, "10:00", 30), task("late", key, "23:30", 30)], on: day(key), calendar: calendar)
        let standup = try XCTUnwrap(blocks.first { $0.id == "standup" }), late = try XCTUnwrap(blocks.first { $0.id == "late" })
        XCTAssertEqual(standup.minute, 660, "An hour past the 10:00 line when read as elapsed time")
        XCTAssertEqual(TaskPlanner.wallMinute(standup.clippedStart, on: day(key), calendar: calendar), 600)
        XCTAssertEqual(TaskPlanner.wallMinute(late.clippedStart, on: day(key), calendar: calendar), 1410)
        // The repeated hour: both 02:30s read 02:30 on the clock.
        let first = at(key, 2, 30, fold: .first), second = at(key, 2, 30, fold: .last)
        XCTAssertEqual(second.timeIntervalSince(first), 3600)
        XCTAssertEqual(TaskPlanner.wallMinute(first, on: day(key), calendar: calendar), 150)
        XCTAssertEqual(TaskPlanner.wallMinute(second, on: day(key), calendar: calendar), 150)
    }

    func testWallMinuteIsClampedToTheDay() throws {
        for key in ["2026-03-29", "2026-10-25", "2026-11-18"] {
            let bounds = try XCTUnwrap(calendar.dateInterval(of: .day, for: day(key)))
            XCTAssertEqual(TaskPlanner.wallMinute(bounds.start, on: day(key), calendar: calendar), 0)
            XCTAssertEqual(TaskPlanner.wallMinute(bounds.start.addingTimeInterval(-3600), on: day(key), calendar: calendar), 0)
            XCTAssertEqual(TaskPlanner.wallMinute(bounds.end, on: day(key), calendar: calendar), 1440)
            XCTAssertEqual(TaskPlanner.wallMinute(bounds.end.addingTimeInterval(-60), on: day(key), calendar: calendar), 1439)
            XCTAssertEqual(TaskPlanner.wallMinute(bounds.start.addingTimeInterval(90), on: day(key), calendar: calendar), 1.5)
        }
    }

    func testEveryQuarterHourRoundTripsThroughWallTime() {
        // A drop on the grid turns a wall minute back into an instant with `TaskPlanning.wallTime`; reading it gives the same
        // minute on all three days, except inside the skipped spring hour, which resolves to 03:00.
        for key in ["2026-03-29", "2026-10-25", "2026-11-18"] {
            for slot in stride(from: 0, to: 1440, by: 15) {
                let date = at(key, slot / 60, slot % 60)
                let expected = key == "2026-03-29" && (120..<180).contains(slot) ? 180 : slot
                XCTAssertEqual(TaskPlanner.wallMinute(date, on: day(key), calendar: calendar), Double(expected), "\(key) \(slot)")
            }
        }
    }
}
