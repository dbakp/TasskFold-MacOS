import XCTest
@testable import TaskfoldCore

final class TaskCompletionTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-24T12:00:00Z")!
    private func calendar(_ zone: String) -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; return c }
    private func task() -> Record {
        Record(["id": .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), "user_id": .string("owner"), "title": .string("Review"), "completed": .bool(false), "completed_at": .null,
            "due_date": .string("2026-10-24"), "due_time": .string("09:00"), "is_recurring": .bool(true), "recurrence_pattern": .object(["type": .string("daily"), "interval": .number(1), "count": .number(3)]),
            "deadline_date": .string("2026-10-24"), "duration_minutes": .number(25), "comments": .array([.object(["id": .string("old-comment"), "text": .string("Old occurrence")])]),
            "created_at": .string("2026-10-01T12:00:00Z"), "updated_at": .string("2026-10-23T12:00:00Z"), "subtasks": .array([])])
    }
    func testIndependentCompletionsUseOneStableCreateOnlySuccessorAndExplicitBaselines() throws {
        let source = task(), cph = calendar("Europe/Copenhagen")
        let first = TaskCompletion.complete(source, tasks: [source], at: now, calendar: cph)
        let second = TaskCompletion.complete(source, tasks: [source], at: now.addingTimeInterval(5), calendar: cph)
        XCTAssertEqual(first.count, 2); XCTAssertEqual(first[1].recordID, second[1].recordID)
        XCTAssertNotNil(UUID(uuidString: first[1].recordID)); XCTAssertEqual(first[1].insertOnly, true)
        XCTAssertEqual(first[0].baseline, ["completed": .bool(false), "completed_at": .null, "completion_version": .number(0)])
        XCTAssertEqual(Set(first[0].fields.keys), ["completed", "completed_at"])
        XCTAssertNotEqual(first[1].fields["created_at"], second[1].fields["created_at"])
    }
    func testRetryAndLegacyRandomSuccessorNeverCreateOrOverwriteAnotherOccurrence() throws {
        let source = task(), changes = TaskCompletion.complete(source, tasks: [], at: now)
        var existing = Record(try XCTUnwrap(changes.last?.fields)); existing["title"] = .string("Edited on another device")
        XCTAssertEqual(TaskCompletion.complete(source, tasks: [source, existing], at: now).count, 1)
        existing["id"] = .string("legacy-random-id")
        XCTAssertEqual(TaskCompletion.complete(source, tasks: [source, existing], at: now).count, 1)
        XCTAssertEqual(existing.title, "Edited on another device")
    }
    func testReopenAndAlreadyCompletedWidgetActionNeverCreateNewOccurrences() {
        var source = task(); source["completed"] = .bool(true); source["completed_at"] = .string("2026-10-24T10:00:00Z")
        XCTAssertTrue(TaskCompletion.complete(source, tasks: [source], at: now).isEmpty)
        let reopening = TaskCompletion.toggle(source, tasks: [source], at: now)
        XCTAssertEqual(reopening.count, 1); XCTAssertEqual(reopening[0].fields, ["completed": .bool(false), "completed_at": .null])
        var invalid = source; invalid["id"] = .string("")
        XCTAssertTrue(TaskCompletion.toggle(invalid, tasks: [], at: now).isEmpty)
    }
    func testSuccessorPreservesPlanningEstimatesAssignmentAndFutureFieldsButClearsOneOffState() throws {
        var source = task(); source["time_zone"] = .string("Europe/Copenhagen"); source["scheduled_at"] = .string("2026-10-24T07:00:00Z")
        source["assigned_to"] = .string("person"); source["future_setting"] = .object(["version": .number(99)])
        let relative = ReminderSpec.relative(-30, id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa01")
        let absolute = ReminderSpec.absolute(now.addingTimeInterval(60), id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa02")
        source["reminder_specs"] = .array([.object(relative.raw), .object(absolute.raw)])
        let next = Record(try XCTUnwrap(TaskCompletion.complete(source, tasks: [], at: now).last?.fields))
        XCTAssertEqual(next["deadline_date"], .null); XCTAssertEqual(next["duration_minutes"], .number(25))
        XCTAssertEqual(next.string("due_date"), "2026-10-25"); XCTAssertEqual(next.string("scheduled_at"), "2026-10-25T08:00:00Z")
        XCTAssertEqual(next["assigned_to"], source["assigned_to"]); XCTAssertEqual(next["future_setting"], source["future_setting"])
        XCTAssertEqual(next["reminder_specs"], .array([.object(relative.raw)])); XCTAssertEqual(next["comments"], .array([]))
        XCTAssertEqual(next["recurrence_pattern"].object["count"], .number(2)); XCTAssertNil(next.fields["updated_at"])
        XCTAssertFalse(source.completed); XCTAssertEqual(source.string("deadline_date"), "2026-10-24")
    }
    func testFixedWeeklyRecurrenceDoesNotChangeWeekdayOrIdentityAfterTravel() throws {
        var source = task(); source["time_zone"] = .string("Europe/Copenhagen"); source["due_time"] = .string("00:30")
        source["recurrence_pattern"] = .object(["type": .string("weekly"), "interval": .number(1), "daysOfWeek": .array([.number(6)])])
        let cph = TaskCompletion.complete(source, tasks: [], at: now, calendar: calendar("Europe/Copenhagen"))
        let ny = TaskCompletion.complete(source, tasks: [], at: now, calendar: calendar("America/New_York"))
        XCTAssertEqual(cph[1].fields["due_date"], .string("2026-10-31")); XCTAssertEqual(cph[1].recordID, ny[1].recordID)
        XCTAssertEqual(cph[1].fields["scheduled_at"], ny[1].fields["scheduled_at"])
    }
    func testFloatingWeeklyDatesUseStoredGregorianDayInEachDeviceZone() throws {
        var source = task(); source["recurrence_pattern"] = .object(["type": .string("weekly"), "interval": .number(1), "daysOfWeek": .array([.number(6)])])
        var buddhist = Calendar(identifier: .buddhist); buddhist.timeZone = TimeZone(identifier: "America/New_York")!
        let cph = TaskCompletion.complete(source, tasks: [], at: now, calendar: calendar("Europe/Copenhagen"))
        let ny = TaskCompletion.complete(source, tasks: [], at: now, calendar: buddhist)
        XCTAssertEqual(cph[1].fields["due_date"], .string("2026-10-31")); XCTAssertEqual(cph[1].recordID, ny[1].recordID)
        XCTAssertEqual(ny[1].fields["time_zone"], nil)
    }
    func testCountAndInclusiveEndDateDoNotCreateAnExtraOccurrence() {
        var source = task(); source["recurrence_pattern"] = .object(["type": .string("daily"), "count": .number(1)])
        XCTAssertEqual(TaskCompletion.complete(source, tasks: [], at: now).count, 1)
        source["recurrence_pattern"] = .object(["type": .string("daily"), "endDate": .string("2026-10-24")])
        XCTAssertEqual(TaskCompletion.complete(source, tasks: [], at: now).count, 1)
        source["recurrence_pattern"] = .object(["type": .string("daily"), "endDate": .string("2026-10-25")])
        XCTAssertEqual(TaskCompletion.complete(source, tasks: [], at: now).count, 2)
    }
    func testNestedChecklistIDsAreNewStableAndIndependentAcrossSuccessiveOccurrences() throws {
        var source = task(); source["subtasks"] = .array([.object(["id": .string("child"), "title": .string("Step"), "completed": .bool(true), "completed_at": .string("old"), "deadline_date": .string("2026-10-24"), "future": .number(99), "subtasks": .array([.object(["id": .string("grandchild"), "completed": .bool(true)])])])])
        let first = Record(try XCTUnwrap(TaskCompletion.complete(source, tasks: [], at: now).last?.fields))
        let retry = Record(try XCTUnwrap(TaskCompletion.complete(source, tasks: [], at: now).last?.fields))
        let second = Record(try XCTUnwrap(TaskCompletion.complete(first, tasks: [], at: now).last?.fields))
        let child = Record(try XCTUnwrap(first["subtasks"].list.first?.object)), grandchild = Record(try XCTUnwrap(child["subtasks"].list.first?.object))
        XCTAssertNotEqual(child.id, "child"); XCTAssertNotEqual(grandchild.id, "grandchild")
        XCTAssertEqual(first["subtasks"], retry["subtasks"]); XCTAssertNotEqual(first["subtasks"], second["subtasks"])
        XCTAssertFalse(child.completed); XCTAssertFalse(grandchild.completed); XCTAssertEqual(child["completed_at"], .null)
        XCTAssertEqual(child["deadline_date"], .null); XCTAssertEqual(child["future"], .number(99))
        XCTAssertEqual(source["subtasks"].list.first?.object["id"], .string("child"))
    }
    func testChildPlansMoveByOccurrenceDaysAcrossDSTWhileUndatedChildrenStayUndated() throws {
        var source = task(); source["time_zone"] = .string("Europe/Copenhagen")
        source["subtasks"] = .array([.object(["id": .string("planned"), "due_date": .string("2026-10-24"), "due_time": .string("09:00"), "time_zone": .string("Europe/Copenhagen"), "scheduled_at": .string("2026-10-24T07:00:00Z"), "duration_minutes": .number(10)]), .object(["id": .string("undated"), "title": .string("Later")]), .string("future opaque child")])
        let next = Record(try XCTUnwrap(TaskCompletion.complete(source, tasks: [], at: now, calendar: calendar("America/New_York")).last?.fields))
        let children = next["subtasks"].list
        XCTAssertEqual(children[0].object["due_date"], .string("2026-10-25")); XCTAssertEqual(children[0].object["scheduled_at"], .string("2026-10-25T08:00:00Z"))
        XCTAssertEqual(children[0].object["duration_minutes"], .number(10)); XCTAssertNil(children[1].object["due_date"])
        XCTAssertEqual(children[2], .string("future opaque child"))
    }
    func testQueuedCompletionRetainsCreateOnlyMarkerAcrossPersistenceAndDoesNotReplaceUnrelatedWork() throws {
        let source = task(); var snapshot = Snapshot(); snapshot.tables["tasks"] = [source]
        snapshot.pending = TaskCompletion.complete(source, tasks: [source], at: now)
        for change in snapshot.pending { snapshot.apply(change) }
        snapshot.apply(Mutation(table: "tasks", recordID: source.id, method: "PATCH", fields: ["description": .string("Later note")]))
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.pending.last?.insertOnly, true); XCTAssertEqual(decoded.tables["tasks"]?.first?.string("description"), "Later note")
        XCTAssertEqual(decoded.pending.first?.baseline?["completed"], .bool(false))
    }
}
