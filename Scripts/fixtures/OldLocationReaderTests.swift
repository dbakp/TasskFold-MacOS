import XCTest
@testable import TaskfoldCore
final class OldLocationReaderTests: XCTestCase {
    func testOpaqueDeviceLocationReferencePreservesEditsRecordRoundtripAndSuccessorWithoutFallbackAlert() throws {
        let taskID = "82000000-0000-4000-8000-000000000001", generation = "82000000-0000-4000-8000-000000000002"
        let reference: JSON = .object(["version": .number(1), "device": .string("82000000-0000-4000-8000-000000000003"), "task_id": .string(taskID), "task_generation": .string(generation), "place_id": .string("82000000-0000-4000-8000-000000000004"), "place_revision": .string("82000000-0000-4000-8000-000000000005"), "arm": .string("82000000-0000-4000-8000-000000000006"), "transition": .string("arrive"), "repeats": .bool(false), "future": .object(["preserve": .bool(true)])])
        let raw: JSON = .object(["version": .number(6), "id": .string("82000000-0000-4000-8000-000000000007"), "kind": .string("location"), "enabled": .bool(true), "channels": .array([.string("local")]), "location_reference": reference])
        XCTAssertNil(ReminderSpec(row: raw))
        var task = Record(["id": .string(taskID), "task_generation": .string(generation), "completion_version": .number(0), "title": .string("Location reference proof"), "due_date": .string("2027-01-16"), "due_time": .string("09:00"), "is_recurring": .bool(true), "recurrence_pattern": .object(["type": .string("daily"), "count": .number(3)]), "reminder_specs": .array([raw])])
        XCTAssertTrue(DueReminder.events(tasks: [task]).isEmpty)
        task["title"] = .string("Changed title"); XCTAssertTrue(ReminderSpec.setPlanned(false, task: &task))
        let restored = try JSONDecoder().decode(Record.self, from: JSONEncoder().encode(task))
        XCTAssertEqual(restored, task)
        XCTAssertEqual(ReminderSpec.rows(restored).first, raw); XCTAssertTrue(DueReminder.events(tasks: [restored]).isEmpty)
        let changes = TaskCompletion.complete(restored, tasks: [restored], at: ISO8601DateFormatter().date(from: "2027-01-16T12:00:00Z")!)
        let successor = Record(try XCTUnwrap(changes.first { $0.method == "POST" }).fields)
        XCTAssertNotEqual(successor.id, taskID); XCTAssertNotEqual(successor.string("task_generation"), generation)
        XCTAssertEqual(ReminderSpec.rows(successor).first, raw); XCTAssertTrue(DueReminder.events(tasks: [successor]).isEmpty)
    }
}
