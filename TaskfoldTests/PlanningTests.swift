import XCTest
@testable import TaskfoldCore

final class PlanningTests: XCTestCase {
    func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!; return calendar
    }
    func fixed(_ instant: String = "2026-10-25T01:30:00Z") -> Record {
        Record(["id": .string("task"), "due_date": .string("2026-10-25"), "due_time": .string("02:30"), "time_zone": .string("Europe/Copenhagen"), "scheduled_at": .string(instant), "deadline_date": .string("2026-10-30"), "duration_minutes": .number(25)])
    }
    func testBothDSTFoldsRetainTheirExactInstantAcrossTravel() {
        for time in ["2026-10-25T00:30:00Z", "2026-10-25T01:30:00Z"] {
            let task = fixed(time)
            XCTAssertEqual(TaskPlanning.start(task, calendar: calendar("America/New_York")), TaskPlanning.instant(time))
            let plan = DueReminder.plan(tasks: [task], now: TaskPlanning.instant("2026-10-24T00:00:00Z")!, calendar: calendar("America/New_York"))
            XCTAssertEqual(plan.first?.date, TaskPlanning.instant(time))
        }
    }
    func testFloatingTimeStaysAtNineInEachCalendar() {
        let task = Record(["due_date": .string("2026-10-05"), "due_time": .string("09:00")])
        let copenhagen = calendar("Europe/Copenhagen"), newYork = calendar("America/New_York")
        XCTAssertEqual(copenhagen.component(.hour, from: TaskPlanning.start(task, calendar: copenhagen)!), 9)
        XCTAssertEqual(newYork.component(.hour, from: TaskPlanning.start(task, calendar: newYork)!), 9)
        XCTAssertNotEqual(TaskPlanning.start(task, calendar: copenhagen), TaskPlanning.start(task, calendar: newYork))
    }
    func testRescheduleRebuildsInstantAndLeavesDeadlineAndDurationAlone() {
        let task = fixed()
        let changes = TaskPlanning.fields(["due_date": .string("2026-10-26")], existing: task, calendar: calendar("America/New_York"))
        XCTAssertEqual(changes["scheduled_at"], .string("2026-10-26T01:30:00Z"))
        XCTAssertNil(changes["deadline_date"]); XCTAssertNil(changes["duration_minutes"])
        var snapshot = Snapshot(tables: ["tasks": [task]])
        snapshot.apply(Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: changes))
        XCTAssertEqual(snapshot.tables["tasks"]?.first?.string("deadline_date"), "2026-10-30")
    }
    func testNewRecurringOccurrenceClearsOneOffDeadlineAndKeepsEstimate() {
        let next = TaskPlanning.nextOccurrence(fixed(), date: Dates.parse("2026-10-26")!)
        XCTAssertEqual(next["deadline_date"], .null); XCTAssertEqual(next.durationMinutes, 25)
        XCTAssertEqual(next.string("scheduled_at"), "2026-10-26T01:30:00Z")
    }
    func testLegacyCacheAndNewFieldsSurviveQueueRoundTrip() throws {
        let old = try JSONDecoder().decode(Record.self, from: Data(#"{"id":"old","title":"Legacy","due_date":null}"#.utf8))
        XCTAssertNil(old.deadline); XCTAssertNil(old.durationMinutes)
        let task = fixed(); let snapshot = Snapshot(tables: ["tasks": [task]], pending: [Mutation(table: "tasks", recordID: task.id, method: "POST", fields: task.fields)])
        XCTAssertEqual(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
        XCTAssertNil(Record(["duration_minutes": .number(-10)]).durationMinutes)
    }
}

extension PlanningTests {
    func testQuickEntrySeparatesPlanDeadlineAndEstimate() {
        let quick = QuickEntry("Prepare report tomorrow ~25m {2026-10-09}", now: Dates.parse("2026-10-05")!)
        XCTAssertEqual(quick.title, "Prepare report")
        XCTAssertEqual(quick.updates["due_date"], .string("2026-10-06"))
        XCTAssertEqual(quick.updates["deadline_date"], .string("2026-10-09"))
        XCTAssertEqual(quick.updates["duration_minutes"], .number(25))
        XCTAssertEqual(QuickEntry("Workshop ~2h").updates["duration_minutes"], .number(120))
    }
    func testDeclinedPlanningChipsAndEscapedWordsRemainLiteral() {
        let quick = QuickEntry("Prepare ~25m {2026-10-09}", disabled: ["duration_minutes", "deadline_date"])
        XCTAssertEqual(quick.title, "Prepare ~25m {2026-10-09}"); XCTAssertTrue(quick.updates.isEmpty)
        let escaped = QuickEntry(##"Call \tomorrow \p1 \#home \{2026-10-09} \~25m"##)
        XCTAssertEqual(escaped.title, "Call tomorrow p1 #home {2026-10-09} ~25m"); XCTAssertTrue(escaped.updates.isEmpty)
        XCTAssertTrue(QuickEntry(#"Write "tomorrow p1""#).updates.isEmpty)
        XCTAssertTrue(QuickEntry("Invalid {2026-02-30} ~99999h").updates.isEmpty)
    }
}
