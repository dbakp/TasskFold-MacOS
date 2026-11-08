import XCTest
@testable import TaskfoldCore

final class TaskInstantReadTests: XCTestCase {
    private func calendar(_ zone: String, identifier: Calendar.Identifier = .gregorian) -> Calendar {
        var result = Calendar(identifier: identifier); result.timeZone = TimeZone(identifier: zone)!; return result
    }
    private func row(_ index: Int, date: String = "2026-11-08", time: String = "09:30", zone: String = "UTC", instant: String = "2026-11-08T09:30:00Z") -> Record {
        Record(["id": .string("row-\(index)"), "title": .string("Current task \(index)"), "completed": .bool(false), "due_date": .string(date), "due_time": .string(time), "time_zone": .string(zone), "scheduled_at": .string(instant)])
    }
    private func variedRows() -> [Record] {
        (0..<500).map { index in
            let day = String(format: "2026-11-%02d", 8 + index % 14), time = String(format: "%02d:%02d", index / 60, index % 60)
            return row(index, date: day, time: time, instant: day + "T" + time + (index % 2 == 0 ? ":00.125Z" : ":00Z"))
        }
    }
    func testSerialParserMatchesFreshForOffsetsFractionsAndInvalidThenValidInput() {
        let values = ["", "bad", "2026-11-08", "2026-11-08T23:59:59Z", "2026-11-08T23:59:59.999Z", "2026-11-08T09:30:00+01:00", "2026-11-08T09:30:00.123456-05:00", "2026-10-25T02:30:00+02:00", "2026-10-25T02:30:00+01:00", "2016-12-31T23:59:60Z", "2026-13-80T99:99:99Z", "2026-11-08T09:30:00Z"]
        var read = TaskPlanning.InstantRead()
        XCTAssertNil(read.instant("")); XCTAssertEqual(read.formatterCount, 0)
        for value in values + values.reversed() + values { XCTAssertEqual(read.instant(value), TaskPlanning.instant(value), value) }
        XCTAssertEqual(read.formatterCount, 2)
    }
    func testReusedParserPreservesWallMinuteValidationFoldsGapsAndCalendarRules() {
        let rows = [row(0), row(1, date: "2026-10-25", time: "02:30", zone: "Europe/Copenhagen", instant: "2026-10-25T01:30:00.125Z"),
                    row(2, date: "2026-10-25", time: "02:30", zone: "Europe/Copenhagen", instant: "2026-10-25T00:30:00Z"),
                    row(3, date: "2026-10-04", time: "02:15", zone: "Australia/Lord_Howe", instant: "bad"),
                    row(4, date: "2011-12-30", zone: "Pacific/Apia", instant: "bad"), row(5, date: "bad"), row(6, time: "bad"), row(7, zone: "bad"),
                    row(8, instant: "2026-11-08T10:30:00Z"), row(9, date: "2026-11-09", instant: "2026-11-08T09:30:00Z"), row(10, zone: "", instant: "")]
        for c in [calendar("Europe/Copenhagen"), calendar("America/New_York", identifier: .buddhist), calendar("Pacific/Auckland", identifier: .islamic)] {
            var read = TaskPlanning.InstantRead()
            for r in rows + rows.reversed() {
                XCTAssertEqual(TaskPlanning.start(r, calendar: c, parseInstant: { read.instant($0) }), TaskPlanning.start(r, calendar: c))
            }
            XCTAssertLessThanOrEqual(read.formatterCount, 2)
        }
    }
    func testDistinctSavedSchedulesKeepExactResultsAndNeverMutateCurrentRows() throws {
        var rows = variedRows()
        rows[0]["future"] = try TaskfoldJSONDecoder().decode(JSON.self, from: Data("{\"precise\":9007199254740993,\"large\":1e500}".utf8))
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(rows), c = calendar("Europe/Copenhagen")
        var read = TaskPlannedDayRead(calendar: c)
        let expected = rows.map { TaskPlanner.plannedDay($0, calendar: c) }
        XCTAssertEqual(rows.map { read.day($0) }, expected)
        XCTAssertEqual(read.resolutionCount, 500); XCTAssertTrue((1...2).contains(read.instantFormatterCount))
        var changed = rows[0]; changed["id"] = .string("latest"); changed["title"] = .string("Edited title"); changed["completed"] = .bool(true)
        XCTAssertEqual(read.day(changed), expected[0]); XCTAssertEqual(read.resolutionCount, 500)
        XCTAssertEqual(try encoder.encode(rows), original)
    }
    func testDatedQueriesKeepOrderCompletionSelectedDayAndFreshZoneContext() {
        let cache = TaskCache()
        var rows = [row(0, time: "23:30", instant: "2026-11-08T23:30:00Z"), row(1, date: "2026-11-07", instant: "2026-11-07T09:30:00Z"), row(2, date: "", time: "", zone: "", instant: ""), row(3)]
        rows[3]["completed"] = .bool(true); cache.update(rows)
        func verify() {
            for zone in ["UTC", "Europe/Copenhagen", "America/New_York", "invalid"] {
                for scope in [TaskScope.today, .upcoming] {
                    for completed in [false, true] {
                        for selected in [String?.none, "2026-11-08", "2026-11-09"] {
                            var query = TaskQuery(scope: scope); query.today = "2026-11-08"; query.timeZone = zone; query.includeCompleted = completed; query.selectedDay = selected; query.sort = "manual"
                            let expected = cache.productiveReading().presentation.filter { r in
                                guard completed || !r.completed else { return false }
                                let day = FilterRule.plannedDay(r, timeZone: zone)
                                return scope == .today ? !day.isEmpty && day <= query.today : selected.map { day == $0 } ?? !day.isEmpty
                            }
                            XCTAssertTrue(AuthoredValueComparison.sameRows(cache.matching(query), expected))
                        }
                    }
                }
            }
        }
        verify(); rows[0]["due_date"] = .string("2026-11-10"); rows[0]["scheduled_at"] = .null; rows[1]["completed"] = .bool(true); cache.update(rows); verify()
    }
    func testFloatingRowsAvoidParsersAndOperationsDoNotShareTravelState() {
        var read = TaskPlannedDayRead(timeZone: "UTC")
        for r in [row(0, zone: ""), row(1, time: "", zone: "", instant: "bad"), row(2, zone: "invalid")] {
            XCTAssertEqual(read.day(r), FilterRule.plannedDay(r, timeZone: "UTC"))
        }
        XCTAssertEqual(read.instantFormatterCount, 0)
        let late = row(3, time: "23:30", instant: "2026-11-08T23:30:00Z")
        var east = TaskPlannedDayRead(timeZone: "Europe/Copenhagen"), west = TaskPlannedDayRead(timeZone: "America/New_York")
        XCTAssertEqual(east.day(late), "2026-11-09"); XCTAssertEqual(west.day(late), "2026-11-08")
        XCTAssertTrue((1...2).contains(east.instantFormatterCount)); XCTAssertTrue((1...2).contains(west.instantFormatterCount))
    }
    func testVariedScheduleReadDiagnostic() {
        let rows = variedRows(), c = calendar("Europe/Copenhagen")
        let start = ContinuousClock.now, expected = rows.map { TaskPlanner.plannedDay($0, calendar: c) }, baseline = start.duration(to: .now)
        var read = TaskPlannedDayRead(calendar: c)
        let next = ContinuousClock.now, actual = rows.map { read.day($0) }, measured = next.duration(to: .now)
        XCTAssertEqual(actual, expected); XCTAssertEqual(read.resolutionCount, 500); XCTAssertTrue((1...2).contains(read.instantFormatterCount))
        print("TASKFOLD_VARIED_SCHEDULE baseline=\(baseline) current=\(measured) rows=500 resolutions=\(read.resolutionCount) formatters=\(read.instantFormatterCount)")
    }
}
