import XCTest
@testable import TaskfoldCore

final class TeamTaskRecurrenceTests: XCTestCase {
    func testActualSQLReplyConfirmsFrozenRepeatIntent() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-task-repeat-v1", withExtension: "json", subdirectory: "Fixtures"))
        let raw = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url)), body = raw["body"]!.object
        let scope = TeamTaskEditScope(account: raw["account"]!.text, origin: raw["origin"]!.text, team: raw["team"]!.text, project: raw["project"]!.text)
        let change = Mutation(id: UUID(uuidString: body["request_id"]!.text)!, table: "tasks", recordID: body["task_id"]!.text, method: "PATCH", fields: body["changes"]!.object, baseline: body["base"]!.object, teamTaskScope: scope)
        let saved = try scope.saved(raw["reply"]!.object, for: change)
        XCTAssertEqual(saved["is_recurring"], .bool(true)); XCTAssertEqual(saved["recurrence_pattern"], body["changes"]!.object["recurrence_pattern"])
        XCTAssertEqual(saved["user_id"], body["base"]!.object["user_id"])
    }
    private func task() -> Record {
        var t = Record.task(user: "ec270000-0000-4000-8000-000000000001")
        t["title"] = .string("Review shared designs"); t["project_id"] = .string("ec270000-0000-4000-8000-000000000002")
        t["due_date"] = .string("2026-10-25"); t["due_time"] = .string("09:00"); t["time_zone"] = .string("Europe/Copenhagen")
        t["recurrence_pattern"] = .null; t["recurrence_end_date"] = .null; t["completed_at"] = .null
        return t
    }
    private func base(_ t: Record, _ fields: [String: JSON]) -> [String: JSON] { TaskCompletionRevision.editBaseline(for: fields, from: t) }
    func testEveryNativeRuleAndLegacyEndDateIsRepresentable() throws {
        for rule: [String: JSON] in [
            ["type": .string("daily"), "interval": .number(2)],
            ["type": .string("weekly"), "daysOfWeek": .array([.number(1), .number(5)]), "fromCompletion": .bool(true)],
            ["type": .string("monthly"), "daysOfMonth": .array([.number(1), .number(15), .number(31)])],
            ["type": .string("monthly"), "weekday": .number(5), "weekdayOrdinal": .number(-1)],
            ["type": .string("yearly"), "monthOfYear": .number(2), "dayOfMonth": .number(29), "count": .number(10)],
            ["type": .string("custom"), "interval": .number(3), "endDate": .string("2027-02-28")]
        ] {
            let t = task(), changes: [String: JSON] = ["is_recurring": .bool(true), "recurrence_pattern": .object(rule)]
            XCTAssertNoThrow(try TeamTaskRecurrence.validate(base: base(t, changes), changes: changes))
            var legacy = t; legacy["is_recurring"] = .bool(true); legacy["recurrence_pattern"] = .object(rule); legacy["recurrence_end_date"] = .string("2027-12-31")
            XCTAssertTrue(TeamTaskRecurrence.supported(legacy))
        }
    }
    func testMissingPlanCanBeAddedWithEnableAndDisablePreservesRule() throws {
        var t = task(); t["due_date"] = .null
        var changes: [String: JSON] = ["is_recurring": .bool(true), "recurrence_pattern": .object(["type": .string("daily")])]
        XCTAssertThrowsError(try TeamTaskRecurrence.validate(base: base(t, changes), changes: changes))
        changes["due_date"] = .string("2026-10-26")
        XCTAssertNoThrow(try TeamTaskRecurrence.validate(base: base(t, changes), changes: changes))
        for (k,v) in changes { t[k] = v }; let off: [String: JSON] = ["is_recurring": .bool(false)]
        XCTAssertNoThrow(try TeamTaskRecurrence.validate(base: base(t, off), changes: off))
        XCTAssertEqual(t["recurrence_pattern"], changes["recurrence_pattern"])
    }
    func testUnknownAndMalformedRulesAreNeverRewritten() throws {
        for value: JSON in [.string("daily"), .array([]), .object(["type": .string("hourly")]), .object(["type": .string("daily"), "future": .bool(true)]), .object(["type": .string("monthly"), "daysOfMonth": .array([.number(31), .number(31)])]), .object(["type": .string("daily"), "endDate": .string("2026-02-30")])] {
            var t = task(); t["recurrence_pattern"] = value
            XCTAssertFalse(TeamTaskRecurrence.supported(t))
            XCTAssertThrowsError(try TeamTaskRecurrence.validate(base: base(t, ["is_recurring": .bool(true)]), changes: ["is_recurring": .bool(true)]))
            XCTAssertEqual(t["recurrence_pattern"], value)
        }
    }
    func testPartialBaselineAndInvalidStatesCannotReachAdapter() throws {
        let t = task(), changes: [String: JSON] = ["is_recurring": .bool(false)], captured = base(t, changes)
        for key in TeamTaskRecurrence.cohort { var incomplete = captured; incomplete.removeValue(forKey: key); XCTAssertThrowsError(try TeamTaskRecurrence.validate(base: incomplete, changes: changes)) }
        for flag: JSON in [.null, .number(1), .string("true")] { XCTAssertThrowsError(try TeamTaskRecurrence.validate(base: captured, changes: ["is_recurring": flag])) }
        for version: JSON in [.null, .number(-1), .number(0.5), .number(.infinity), .string("0")] { var b = captured; b["completion_version"] = version; XCTAssertThrowsError(try TeamTaskRecurrence.validate(base: b, changes: changes)) }
        XCTAssertThrowsError(try TeamTaskRecurrence.validate(base: captured, changes: ["is_recurring": .bool(false), "completed": .bool(true)]))
    }
    func testEachConcurrentContextChangeStopsDraftButUnrelatedNotesCanMerge() throws {
        let t = task(), captured = base(t, ["is_recurring": .bool(false)])
        for (key, value): (String, JSON) in [("due_date", .string("2026-10-26")), ("due_time", .string("10:00")), ("time_zone", .string("UTC")), ("completed", .bool(true)), ("completed_at", .string("2026-10-25T12:00:00Z")), ("completion_version", .number(2)), ("recurrence_pattern", .object(["type": .string("weekly")])), ("is_recurring", .bool(true)), ("recurrence_end_date", .string("2026-12-31"))] {
            var live = t; live[key] = value; XCTAssertThrowsError(try TeamTaskRecurrence.requireCurrent(base: captured, current: live), key)
        }
        var live = t; live["description"] = .string("New notes"); live["due_time"] = .string("09:00:00")
        XCTAssertNoThrow(try TeamTaskRecurrence.requireCurrent(base: captured, current: live))
    }
    func testTimestampSpellingAndNoRepeatBaselineRemainCompatible() throws {
        var t = task(); t["completed_at"] = .string("2026-10-25T10:00:00Z")
        let captured = base(t, ["is_recurring": .bool(false)]); t["completed_at"] = .string("2026-10-25T10:00:00+00:00")
        XCTAssertNoThrow(try TeamTaskRecurrence.requireCurrent(base: captured, current: t))
        XCTAssertEqual(Set(base(t, ["title": .string("Other")]).keys), ["title", "task_generation"])
    }
    func testScopeCapturesFullContextAndRejectsStaleRepeat() throws {
        let t = task(), scope = TeamTaskEditScope(account: t.string("user_id"), origin: "https://synthetic.example", team: "ec270000-0000-4000-8000-000000000003", project: t.string("project_id"))
        let fields: [String: JSON] = ["is_recurring": .bool(true), "recurrence_pattern": .object(["type": .string("daily")])]
        let change = Mutation(table: "tasks", recordID: t.id, method: "PATCH", fields: fields, baseline: base(t, fields), teamTaskScope: scope)
        let captured = try scope.capturing(change, existing: t)
        XCTAssertEqual(try scope.body(for: captured)["changes"], .object(fields))
        XCTAssertEqual(captured.baseline?["completion_version"], .number(0))
        XCTAssertNil(captured.fields["recurrence_parent_id"]); XCTAssertNil(captured.fields["completion_version"])
        var live = t; live["completion_version"] = .number(2)
        XCTAssertThrowsError(try scope.capturing(change, existing: live))
        XCTAssertEqual(try JSONDecoder().decode(Mutation.self, from: JSONEncoder().encode(captured)), captured)
    }
    func testReviewedChangesOnlyApplyTheAuthoredRuleAndPlanFields() throws {
        let original = task()
        XCTAssertTrue(try TeamTaskRecurrence.reviewedChanges(from: original, to: original).isEmpty)
        var desired = original; desired["is_recurring"] = .bool(true); desired["recurrence_pattern"] = .object(["type": .string("daily")])
        let changes = try TeamTaskRecurrence.reviewedChanges(from: original, to: desired)
        XCTAssertEqual(Set(changes.keys), ["is_recurring", "recurrence_pattern"])
        for key in ["id", "user_id", "project_id", "description", "recurrence_parent_id", "completion_version", "reminder_specs", "opaque_future"] {
            var forged = desired; forged[key] = .string("unexpected")
            XCTAssertThrowsError(try TeamTaskRecurrence.reviewedChanges(from: original, to: forged), key)
        }
        var planOnly = original; planOnly["due_date"] = .string("2026-10-26")
        XCTAssertThrowsError(try TeamTaskRecurrence.reviewedChanges(from: original, to: planOnly))
    }
    func testUndoAndRedoHistoryRetainFullReviewedContext() throws {
        let t = task(), scope = TeamTaskEditScope(account: t.string("user_id"), origin: "https://synthetic.example", team: "ec270000-0000-4000-8000-000000000003", project: t.string("project_id"))
        let fields: [String: JSON] = ["is_recurring": .bool(true), "recurrence_pattern": .object(["type": .string("weekly")])]
        let mutation = Mutation(table: "tasks", recordID: t.id, method: "PATCH", fields: fields, baseline: base(t, fields), teamTaskScope: scope)
        let snapshot = Snapshot(tables: ["tasks": [t]])
        let history = EditHistory(changes: [mutation], snapshot: snapshot)
        var applied = snapshot; applied.apply(mutation)
        let undo = try XCTUnwrap(history.undo.first), live = try XCTUnwrap(applied.tables["tasks"]?.first)
        XCTAssertEqual(undo.baseline?["is_recurring"], .bool(true)); XCTAssertEqual(undo.baseline?["recurrence_pattern"], fields["recurrence_pattern"])
        XCTAssertNoThrow(try scope.capturing(undo, existing: live))
        XCTAssertNoThrow(try scope.body(for: undo)); applied.apply(undo)
        XCTAssertEqual(applied.tables["tasks"]?.first, t)
        let redo = try XCTUnwrap(history.redo.first)
        XCTAssertNoThrow(try scope.capturing(redo, existing: t))
        XCTAssertTrue(TeamTaskRecurrence.cohort.isSubset(of: redo.baseline!.keys))
    }
}
