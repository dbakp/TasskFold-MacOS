import XCTest
@testable import TaskfoldCore

final class BulkDeadlineTests: XCTestCase {
    private func task(_ id: String, deadline: JSON = .null) -> Record {
        Record(["id": .string(id), "title": .string("Work"), "deadline_date": deadline,
            "due_date": .string("2026-10-25"), "due_time": .string("02:30"), "time_zone": .string("Europe/Copenhagen"),
            "scheduled_at": .string("2026-10-25T01:30:00Z"), "duration_minutes": .number(25),
            "reminder_specs": .array([.object(ReminderSpec.relative(-30, id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa").raw)]),
            "completed": .bool(false), "subtasks": .array([.object(["id": .string("child"), "title": .string("Child"), "deadline_date": .string("2026-10-26")])])])
    }
    func testMixedBatchMutatesOnlyDeadlinesAndPreservesFixedInstantAndReminders() throws {
        let rows = [task("a", deadline: .string("2026-10-26")), task("b")]
        var snapshot = Snapshot(); snapshot.tables["tasks"] = rows
        let changes = try TaskDeadlines.changes(tasks: rows, day: "2026-11-01")
        XCTAssertEqual(changes.count, 2)
        for change in changes {
            XCTAssertEqual(Set(change.fields.keys), ["deadline_date"]); XCTAssertEqual(change.method, "PATCH")
            XCTAssertEqual(Set(change.baseline!.keys), ["deadline_date"])
            XCTAssertEqual(TaskPlanning.fields(change.fields, existing: rows.first { $0.id == change.recordID }), change.fields)
            snapshot.apply(change)
        }
        for original in rows {
            let edited = snapshot.tables["tasks"]!.first { $0.id == original.id }!
            XCTAssertEqual(edited.fields.filter { $0.key != "deadline_date" }, original.fields.filter { $0.key != "deadline_date" })
            XCTAssertEqual(TaskPlanning.start(edited), TaskPlanning.start(original))
            XCTAssertEqual(DueReminder.events(tasks: [edited]), DueReminder.events(tasks: [original]))
        }
    }
    func testUndoRedoRestoresMixedDeadlinesWithoutReplacingConcurrentOtherFields() throws {
        let rows = [task("a", deadline: .string("2026-10-26")), task("b")]
        var snapshot = Snapshot(); snapshot.tables["tasks"] = rows
        let changes = try TaskDeadlines.changes(tasks: rows, day: "2026-11-01")
        let history = EditHistory(changes: changes, snapshot: snapshot)
        for change in changes { snapshot.apply(change) }
        snapshot.apply(Mutation(table: "tasks", recordID: "a", method: "PATCH", fields: ["title": .string("New title"), "duration_minutes": .number(45)]))
        for change in history.undo { snapshot.apply(change) }
        XCTAssertEqual(snapshot.tables["tasks"]!.first { $0.id == "a" }?.title, "New title")
        XCTAssertEqual(snapshot.tables["tasks"]!.first { $0.id == "a" }?["deadline_date"], .string("2026-10-26"))
        XCTAssertEqual(snapshot.tables["tasks"]!.first { $0.id == "b" }?["deadline_date"], .null)
        for change in history.redo { snapshot.apply(change) }
        XCTAssertTrue(snapshot.tables["tasks"]!.allSatisfy { $0["deadline_date"] == .string("2026-11-01") })
        XCTAssertEqual(snapshot.tables["tasks"]!.first { $0.id == "a" }?["duration_minutes"], .number(45))
    }
    func testClearSkipsAbsentAndAlreadyNullAndNeverClearsPlanning() throws {
        var absent = task("b"); absent.fields.removeValue(forKey: "deadline_date")
        let rows = [task("a", deadline: .string("2026-10-26")), absent, task("c")]
        let changes = try TaskDeadlines.changes(tasks: rows, day: nil)
        XCTAssertEqual(changes.map(\.recordID), ["a"]); XCTAssertEqual(changes[0].fields, ["deadline_date": .null])
    }
    func testNoOpsDuplicateIDsAndEmptySelectionProduceNoExtraHistoryWork() throws {
        let same = task("b", deadline: .string("2026-11-01")), changed = task("a")
        XCTAssertTrue(try TaskDeadlines.changes(tasks: [], day: "2026-11-01").isEmpty)
        XCTAssertTrue(try TaskDeadlines.changes(tasks: [same], day: "2026-11-01").isEmpty)
        XCTAssertEqual(try TaskDeadlines.changes(tasks: [same, changed, changed, task("")], day: "2026-11-01").map(\.recordID), ["a"])
    }
    func testGregorianValidationRejectsRolloverSuffixYearZeroAndMalformedInputs() throws {
        for invalid in ["2026-02-29", "2026-13-01", "2026-04-31", "2026-10-06T12:00Z", "2026-1-01", "0000-01-01", "2026-10-06 ", "today", ""] {
            XCTAssertThrowsError(try TaskDeadlines.fields(day: invalid), invalid)
        }
        XCTAssertEqual(try TaskDeadlines.fields(day: "2028-02-29"), ["deadline_date": .string("2028-02-29")])
        XCTAssertEqual(try TaskDeadlines.fields(day: "2020-01-01"), ["deadline_date": .string("2020-01-01")], "Past deadlines are valid")
    }
    func testPendingRoundTripPreservesFieldBaselinesAndOtherWork() throws {
        let rows = [task("a", deadline: .string("2026-10-26")), task("b")]
        var snapshot = Snapshot(); snapshot.tables["tasks"] = rows
        snapshot.pending = [Mutation(table: "tasks", recordID: "a", method: "PATCH", fields: ["title": .string("Offline title")], baseline: ["title": .string("Work")])]
        let changes = try TaskDeadlines.changes(tasks: rows, day: "2026-11-01")
        snapshot.pending += changes
        for change in snapshot.pending { snapshot.apply(change) }
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot); XCTAssertEqual(decoded.pending.count, 3)
        XCTAssertEqual(decoded.tables["tasks"]!.first { $0.id == "a" }?.title, "Offline title")
        XCTAssertEqual(decoded.pending.last?.baseline, ["deadline_date": .null])
    }
    func testDeadlineSelectionCapturesIDsAndWorkspaceIndependentlyOfLaterSelection() {
        var ids: Set<String> = ["a", "b"]
        let request = DeadlineSelection(account: "owner", ids: ids)
        ids.insert("c")
        XCTAssertEqual(request.ids, ["a", "b"]); XCTAssertEqual(request.account, "owner")
    }
}
