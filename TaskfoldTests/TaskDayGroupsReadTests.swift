import Foundation
import XCTest
@testable import TaskfoldCore

final class TaskDayGroupsReadTests: XCTestCase {
    private let today = "2026-11-07"
    private func calendar(_ zone: String = "UTC", _ id: Calendar.Identifier = .gregorian) -> Calendar { var c = Calendar(identifier: id); c.timeZone = TimeZone(identifier: zone)!; return c }
    private func row(_ id: String, _ day: String, done: Bool = false) -> Record {
        Record(["id": .string(id), "title": .string("Task " + id), "due_date": .string(day), "completed": .bool(done), "priority": .number(4)])
    }
    private func timed(_ id: String, day: String = "2026-11-07", instant: String = "2026-11-07T23:30:00Z") -> Record {
        var r = row(id, day); r["due_time"] = .string("23:30"); r["time_zone"] = .string("UTC"); r["scheduled_at"] = .string(instant); return r
    }
    private func exactRows(_ a: [Record], _ b: [Record], file: StaticString = #filePath, line: UInt = #line) throws {
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(a), try encoder.encode(b), file: file, line: line)
    }
    private func legacy(_ rows: [Record], horizon: [String], calendar: Calendar) -> [(String, [Record])] {
        let overdue = rows.filter { !$0.completed && !TaskPlanner.plannedDay($0, calendar: calendar).isEmpty && TaskPlanner.plannedDay($0, calendar: calendar) < today }
        let future = rows.filter { TaskPlanner.plannedDay($0, calendar: calendar) >= today }
        let days = Set(future.map { TaskPlanner.plannedDay($0, calendar: calendar) }).union(horizon).sorted()
        return [("Overdue", overdue)] + days.map { day in (day, future.filter { TaskPlanner.plannedDay($0, calendar: calendar) == day }) }
    }
    private func assertLegacy(_ rows: [Record], horizon: [String] = ["2026-11-07", "2026-11-08"], calendar: Calendar) throws {
        let expected = legacy(rows, horizon: horizon, calendar: calendar), read = TaskDayGroupsRead(tasks: rows, today: today, calendar: calendar)
        let actual = [("Overdue", read.overdue)] + read.upcomingDays(adding: horizon).map { ($0, read.rowsByDay[$0] ?? []) }
        XCTAssertEqual(actual.map { $0.0 }, expected.map { $0.0 })
        for (a,b) in zip(actual, expected) { try exactRows(a.1,b.1) }
        try exactRows(read.rowsByDay[today] ?? [], rows.filter { TaskPlanner.plannedDay($0, calendar: calendar) == today })
    }
    func testMixedOpenCompletedMissingAndUnusualDaysKeepPreviousSections() throws {
        let rows = [row("a", "2026-11-05"), row("b", today), row("c", "2026-11-04", done: true), row("d", ""), row("e", "2026-11-08", done: true), row("f", "unknown"), row("g", today, done: true)]
        try assertLegacy(rows, calendar: calendar())
        let read = TaskDayGroupsRead(tasks: rows, today: today, calendar: calendar())
        XCTAssertEqual(read.overdue.map(\.id), ["a"]); XCTAssertEqual(read.rowsByDay[today]?.map(\.id), ["b","g"])
    }
    func testOverdueOrderStaysGlobalWhileDayRowsKeepSuppliedOrderAndDuplicateIDs() throws {
        let rows = [row("dup", "2026-11-06"), row("middle", "2026-11-01"), row("dup", "2026-11-06"), row("future-a", today), row("future-b", today)]
        try assertLegacy(rows, calendar: calendar())
        let read = TaskDayGroupsRead(tasks: rows, today: today, calendar: calendar())
        try exactRows(read.overdue, Array(rows.prefix(3)))
        XCTAssertEqual(read.rowsByDay[today]?.map(\.id), ["future-a","future-b"])
    }
    func testEmptyHorizonDaysAndFarFutureWorkRemainVisible() throws {
        let horizon = (7...20).map { String(format: "2026-11-%02d", $0) }
        let rows = [row("later", "2099-01-01")]
        try assertLegacy(rows, horizon: horizon, calendar: calendar())
        XCTAssertEqual(TaskDayGroupsRead(tasks: rows, today: today).upcomingDays(adding: horizon), horizon + ["2099-01-01"])
        XCTAssertEqual(TaskDayGroupsRead(tasks: [], today: today).upcomingDays(adding: horizon), horizon)
    }
    func testTravelDSTAndDisplayCalendarsUseTheExistingPlanningContract() throws {
        let rows = [timed("midnight"), timed("fold",day:"2026-10-25",instant:"2026-10-25T01:30:00Z"), timed("gap",day:"2026-10-04",instant:"2026-10-04T15:30:00Z")]
        for zone in ["UTC","Europe/Copenhagen","America/New_York","Australia/Lord_Howe"] {
            for id in [Calendar.Identifier.gregorian,.buddhist,.japanese] { try assertLegacy(rows, calendar: calendar(zone,id)) }
        }
        XCTAssertEqual(TaskDayGroupsRead(tasks: [rows[0]],today:today,calendar:calendar("Europe/Copenhagen")).rowsByDay["2026-11-08"]?.count,1)
    }
    func testUnsupportedFixedFieldsAndFloatingDaysKeepExistingFallback() throws {
        var badZone = timed("zone"); badZone["time_zone"] = .string("unknown")
        var badInstant = timed("instant"); badInstant["scheduled_at"] = .string("invalid")
        var badClock = timed("clock"); badClock["due_time"] = .string("32:90")
        try assertLegacy([badZone,badInstant,badClock,row("floating","2026-11-08")],calendar:calendar("Europe/Copenhagen"))
    }
    func testHeadingsAndIndependentChildrenArePreservedWithoutNewCountingRules() throws {
        var heading = row("heading","2026-11-06"); heading["is_heading"] = .bool(true)
        var child = row("subtask:root/child",today); child["description"] = .string("Keep notes"); child["future"] = try TaskfoldJSONDecoder().decode(JSON.self,from:Data("9007199254740993".utf8))
        let rows = [heading,child]; try assertLegacy(rows,calendar:calendar())
        let read = TaskDayGroupsRead(tasks:rows,today:today,calendar:calendar()); XCTAssertEqual(read.overdue.map(\.id),["heading"])
        try exactRows(read.rowsByDay[today] ?? [],[child])
    }
    func testFreshSourceClockAndZoneReadsDoNotMutatePriorValues() throws {
        var rows = [timed("a"),row("b","2026-11-06")]
        let original = rows, old = TaskDayGroupsRead(tasks:rows,today:today,calendar:calendar())
        rows[0]["due_date"] = .string("2026-11-10"); rows[0]["scheduled_at"] = .null; rows[0]["title"] = .string("Edited")
        let edited = TaskDayGroupsRead(tasks:rows,today:today,calendar:calendar())
        XCTAssertNotNil(edited.rowsByDay["2026-11-10"]); try exactRows(old.rowsByDay[today] ?? [],[original[0]])
        let tomorrow = TaskDayGroupsRead(tasks:original,today:"2026-11-08",calendar:calendar())
        XCTAssertEqual(tomorrow.overdue.count,2)
        try exactRows(TaskDayGroupsRead(tasks:original,today:today,calendar:calendar()).rowsByDay[today] ?? [],old.rowsByDay[today] ?? [])
    }
    func testManualPriorityOrderRemainsAnIndependentPerDayRead() throws {
        var a=row("a",today),b=row("b",today),c=row("c",today);a["priority"] = .number(1);b["priority"] = .number(2);c["priority"] = .number(1)
        let read=TaskDayGroupsRead(tasks:[a,b,c],today:today), ids=["b","c","a"]
        try exactRows(DayPlacement.arranged(read.rowsByDay[today] ?? [],ids:ids),DayPlacement.arranged([a,b,c],ids:ids))
        XCTAssertEqual(DayPlacement.arranged(read.rowsByDay[today] ?? [],ids:ids).map(\.id),["c","a","b"])
    }
    func testRepeatedSectionWorkloadRecordsEquivalentReadTimings() throws {
        let c=calendar("Europe/Copenhagen"),horizon=(7...20).map{String(format:"2026-11-%02d",$0)}
        let rows=(0..<120).map{timed("r-\($0)",day:String(format:"2026-11-%02d",7+$0%14),instant:String(format:"2026-11-%02dT09:30:00Z",7+$0%14))}
        var before:[Double]=[],after:[Double]=[]
        for _ in 0..<3 {
            let a=Date(),old=legacy(rows,horizon:horizon,calendar:c),b=Date()
            let read=TaskDayGroupsRead(tasks:rows,today:today,calendar:c)
            let fresh=[("Overdue",read.overdue)]+read.upcomingDays(adding:horizon).map{($0,read.rowsByDay[$0] ?? [])}
            let end=Date();XCTAssertEqual(old.map{$0.0},fresh.map{$0.0});for (x,y) in zip(old,fresh){try exactRows(x.1,y.1)}
            before.append(b.timeIntervalSince(a));after.append(end.timeIntervalSince(b))
        }
        print("DAY_GROUPING_TIMING rows=120 days=14 legacy=\(before) singlePass=\(after)")
    }
}
