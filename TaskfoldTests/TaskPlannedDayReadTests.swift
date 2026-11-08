import XCTest
@testable import TaskfoldCore

final class TaskPlannedDayReadTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: zone)!; return value
    }
    private func row(_ id: String = "a", date: String = "2026-11-08", time: String = "09:30", zone: String = "UTC", instant: String = "") -> Record {
        Record(["id": .string(id), "due_date": .string(date), "due_time": .string(time), "time_zone": .string(zone), "scheduled_at": .string(instant)])
    }
    func testEveryPlanningInputDistinguishesResolutionAndOtherFieldsStayCurrent() {
        var read = TaskPlannedDayRead(calendar: calendar("Europe/Copenhagen"))
        let original = row()
        XCTAssertEqual(read.day(original), TaskPlanner.plannedDay(original, calendar: calendar("Europe/Copenhagen")))
        var edited = original; edited["title"] = .string("Latest title"); edited["completed"] = .bool(true)
        edited["id"] = .string("different"); edited["description"] = .string("Current full text")
        XCTAssertEqual(read.day(edited), read.day(original)); XCTAssertEqual(read.resolutionCount, 1)
        for (key, value) in [("due_date", "2026-11-09"), ("due_time", "23:30"), ("time_zone", "America/New_York"), ("scheduled_at", "2026-11-08T09:30:00Z")] {
            var r = original; r[key] = .string(value)
            XCTAssertEqual(read.day(r), TaskPlanner.plannedDay(r, calendar: calendar("Europe/Copenhagen")))
        }
        XCTAssertEqual(read.resolutionCount, 5)
    }
    func testTravelFoldGapMalformedAndFloatingSchedulesMatchIndependentResolver() {
        let rows = [row(), row(date: "2026-10-25", time: "02:30", zone: "Europe/Copenhagen", instant: "2026-10-25T01:30:00Z"),
                    row(date: "2026-10-04", time: "02:15", zone: "Australia/Lord_Howe"),
                    row(date: "2011-12-30", zone: "Pacific/Apia"), row(date: "invalid"), row(time: "invalid"), row(zone: "invalid"),
                    row(date: "2026-11-08T00:00:00Z", time: "", zone: ""), row(date: "", time: "", zone: ""),
                    row(time: "23:30", instant: "2026-11-08T23:30:00Z"), row(instant: "not an instant")]
        for zone in ["UTC", "Europe/Copenhagen", "America/New_York", "Pacific/Auckland"] {
            let c = calendar(zone); var read = TaskPlannedDayRead(calendar: c)
            for r in rows + rows.reversed() { XCTAssertEqual(read.day(r), TaskPlanner.plannedDay(r, calendar: c)) }
            XCTAssertEqual(read.resolutionCount, rows.count)
        }
    }
    func testNewOperationCannotReuseAnotherZoneOrEditedSchedule() {
        let r = row(time: "23:30", instant: "2026-11-08T23:30:00Z")
        var first = TaskPlannedDayRead(calendar: calendar("Europe/Copenhagen"))
        var second = TaskPlannedDayRead(calendar: calendar("America/New_York"))
        XCTAssertEqual(first.day(r), "2026-11-09"); XCTAssertEqual(second.day(r), "2026-11-08")
        var edited = r; edited["due_date"] = .string("2026-11-10"); edited["scheduled_at"] = .null
        XCTAssertEqual(first.day(edited), "2026-11-11")
        XCTAssertEqual(first.resolutionCount, 2); XCTAssertEqual(second.resolutionCount, 1)
    }
    func testGroupedRowsKeepCurrentPayloadDuplicatesCompletionAndOrder() throws {
        var a = row("duplicate"); a["title"] = .string("First")
        a["future"] = try TaskfoldJSONDecoder().decode(JSON.self, from: Data("9007199254740993".utf8))
        var b = a; b["title"] = .string("Second"); b["completed"] = .bool(true)
        let rows = [a, row("before", date: "2026-11-07"), b, row("undated", date: "", time: "", zone: "")]
        let c = calendar("Europe/Copenhagen"), today = "2026-11-08"
        var expected: [String: [Record]] = [:], overdue: [Record] = []
        for r in rows {
            let day = TaskPlanner.plannedDay(r, calendar: c); expected[day, default: []].append(r)
            if !r.completed, !day.isEmpty, day < today { overdue.append(r) }
        }
        let result = TaskDayGroupsRead(tasks: rows, today: today, calendar: c)
        XCTAssertEqual(Set(result.rowsByDay.keys), Set(expected.keys))
        for (day, values) in expected { XCTAssertTrue(AuthoredValueComparison.sameRows(result.rowsByDay[day]!, values)) }
        XCTAssertTrue(AuthoredValueComparison.sameRows(result.overdue, overdue))
    }
    func testRepeatedScheduleWorkloadResolvesDistinctSchedulesOnly() {
        let c = calendar("Europe/Copenhagen")
        let rows = (0..<500).map { row("r\($0)", date: String(format: "2026-11-%02d", 8 + $0 % 14)) }
        var read = TaskPlannedDayRead(calendar: c)
        let start = ContinuousClock.now
        let expected = rows.map { TaskPlanner.plannedDay($0, calendar: c) }
        let baseline = start.duration(to: .now)
        let next = ContinuousClock.now
        let actual = rows.map { read.day($0) }
        let measured = next.duration(to: .now)
        XCTAssertEqual(actual, expected); XCTAssertEqual(read.resolutionCount, 14)
        print("TASKFOLD_SCHEDULE_READ baseline=\(baseline) current=\(measured) rows=500 resolutions=14")
    }
}
