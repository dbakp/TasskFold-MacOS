import XCTest
@testable import TaskfoldCore
final class OldPresentationReaderTests: XCTestCase {
    func testPreviousReaderPreservesEveryOpaquePresentationWithoutSubstituteAlerts() throws {
        let schedules: [[String: JSON]] = [
            ["version": .number(1), "kind": .string("relative"), "anchor": .string("planned"), "offset_minutes": .number(-10)],
            ["version": .number(1), "kind": .string("absolute"), "at": .string("2027-01-16T09:00:00Z"), "time_zone": .string("UTC")],
            ["version": .number(2), "kind": .string("recurring"), "start_day": .string("2027-01-16"), "time": .string("09:00"), "time_zone": .string("UTC"), "recurrence": .object(["type": .string("daily")])],
            ["version": .number(3), "kind": .string("interval"), "interval_schedule": .object(["start_ms": .number(1800000000000), "every_minutes": .number(30), "count": .number(3), "until_ms": .null])]
        ]
        for var fields in schedules {
            fields["schedule_version"] = fields["version"]; fields["version"] = .number(4)
            fields["presentation"] = .string("time-sensitive"); fields["id"] = .string("11000000-0000-4000-8000-000000000001")
            fields["channels"] = .array([.string("local")]); fields["enabled"] = .bool(true)
            let raw = JSON.object(fields); XCTAssertNil(ReminderSpec(row: raw))
            var task = Record(["id": .string(UUID().uuidString), "title": .string("Old reader"), "due_date": .string("2027-01-15"), "is_recurring": .bool(true), "recurrence_pattern": .object(["type": .string("daily")]), "reminder_specs": .array([raw])])
            task["title"] = .string("Changed title"); XCTAssertTrue(ReminderSpec.setPlanned(false, task: &task))
            let saved = try JSONDecoder().decode(Record.self, from: JSONEncoder().encode(task))
            XCTAssertEqual(ReminderSpec.rows(saved).first, raw)
            XCTAssertEqual(ReminderSpec.rows(TaskPlanning.nextOccurrence(saved, date: Date())).first, raw)
            XCTAssertTrue(DueReminder.events(tasks: [saved]).isEmpty)
        }
    }
}
