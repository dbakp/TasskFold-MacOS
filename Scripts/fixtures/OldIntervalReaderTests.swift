import XCTest
@testable import TaskfoldCore
final class OldIntervalReaderTests: XCTestCase {
    func testActualPreviousReaderPreservesUnknownIntervalAcrossEditsSaveAndSuccessor() throws {
        let raw: JSON = .object(["version": .number(3), "id": .string("11000000-0000-4000-8000-000000000001"), "kind": .string("interval"), "enabled": .bool(true), "channels": .array([.string("local")]), "interval_schedule": .object(["start_ms": .number(1800000000000), "every_minutes": .number(30), "count": .number(3), "until_ms": .null])])
        XCTAssertNil(ReminderSpec(row: raw))
        var task = Record(["id": .string(UUID().uuidString), "title": .string("Old reader"), "due_date": .string("2027-01-15"), "is_recurring": .bool(true), "recurrence_pattern": .object(["type": .string("daily")]), "reminder_specs": .array([raw])])
        task["title"] = .string("Changed title"); XCTAssertTrue(ReminderSpec.setPlanned(false, task: &task))
        XCTAssertEqual(ReminderSpec.rows(task).first, raw)
        let saved = try JSONDecoder().decode(Record.self, from: JSONEncoder().encode(task))
        XCTAssertEqual(ReminderSpec.rows(saved).first, raw)
        XCTAssertEqual(ReminderSpec.rows(TaskPlanning.nextOccurrence(saved, date: Date())).first, raw)
        XCTAssertTrue(DueReminder.events(tasks: [saved]).isEmpty)
    }
}
