import XCTest
@testable import TaskfoldCore

final class ChildCopyReconciliationHistoryTests: XCTestCase {
    struct Timeline: Decodable {
        let before: [Record], afterMapping: [Record]
        let afterNewCompletion: [Record]?, afterReopen: [Record]?
    }
    struct Main: Decodable {
        let root: Record, epoch: [Record], neutral: Record
        let before: [Record], afterMapping: [Record], afterRestoredReopen: [Record]
        let afterNewCompletion: [Record], afterUnchangedReopen: [Record]
    }
    struct Retired: Decodable { let before: [Record], after: [Record] }
    struct Fixture: Decodable {
        let clientFixture: Main, retiredFixture: Retired, rebasedFixture: Timeline
    }
    func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "child-copy-reconciliation-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    func reading(_ rows: [Record], _ f: Fixture) -> ChildWorkReading {
        ChildWorkReading(ChildWorkHistory(rows: rows, epoch: f.clientFixture.epoch), now: .distantFuture)
    }
    func testActualServerRecoveryDoesNotManufactureCompletionCredit() throws {
        let f = try fixture(), original = reading(f.clientFixture.before, f).credits()
        XCTAssertEqual(original.count, 1)
        XCTAssertEqual(reading(f.clientFixture.afterMapping, f).credits(), original)
        XCTAssertFalse(reading(f.clientFixture.afterMapping, f).incomplete)
        XCTAssertEqual(reading(f.clientFixture.afterRestoredReopen, f).credits(), original)
    }
    func testLaterRealCompletionEarnsCreditAndUnchangedReopenStillCorrectsItsOwnCredit() throws {
        let f = try fixture(), original = reading(f.clientFixture.before, f).credits()
        let added = reading(f.clientFixture.afterNewCompletion, f).credits()
        XCTAssertEqual(added.count, 2)
        XCTAssertTrue(added.contains(original[0]))
        let remaining = reading(f.clientFixture.afterUnchangedReopen, f).credits()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertFalse(remaining.contains(original[0]), "Unchanged lifecycle still supports ordinary completion correction")
    }
    func testRetirementPreservesObservedWorkAtOriginalDateActorAndProject() throws {
        let f = try fixture(), original = reading(f.retiredFixture.before, f).credits()
        XCTAssertEqual(original.count, 1)
        XCTAssertEqual(reading(f.retiredFixture.after, f).credits(), original)
    }
    func testRebasedLifecycleCannotEraseEarlierObservedCredit() throws {
        let f = try fixture(), timeline = f.rebasedFixture
        let original = reading(timeline.before, f).credits()
        XCTAssertEqual(original.count, 1)
        XCTAssertEqual(reading(timeline.afterMapping, f).credits(), original)
        let completed = reading(try XCTUnwrap(timeline.afterNewCompletion), f).credits()
        XCTAssertEqual(completed.count, 2)
        XCTAssertTrue(completed.contains(original[0]))
        XCTAssertEqual(reading(try XCTUnwrap(timeline.afterReopen), f).credits(), original)
    }
    func testNeutralAuditHasDistinctPresentationAndSafeRootRoute() throws {
        let f = try fixture(), root = f.clientFixture.root
        let event = try XCTUnwrap(TaskNodeActivity(row: f.clientFixture.neutral))
        XCTAssertEqual(event.kinds, [.reconciled])
        XCTAssertFalse(event.isGap || event.isOrdering || event.workBefore || event.workAfter)
        XCTAssertEqual(WorkActivity.child(event).title, "Saved copies reconciled")
        XCTAssertNotNil(event.reconciliation)
        let projects = [Record(["id": .string(root.string("project_id"))])]
        XCTAssertEqual(event.currentTask(tasks: [root], projects: projects, account: root.string("user_id"))?.id, root.id)
        var replaced = root; replaced["task_generation"] = .string(UUID().uuidString.lowercased())
        XCTAssertNil(event.currentTask(tasks: [replaced], projects: projects, account: root.string("user_id")))
    }
    func testMalformedFutureAndDuplicateReconciliationConsentIsRejected() throws {
        let f = try fixture(), valid = f.clientFixture.neutral
        for value in [JSON.null, .array([]), .object([:]), .string("invalid")] {
            var row = valid; row["order_context"] = value
            XCTAssertNil(TaskNodeActivity(row: row))
        }
        var changes: [[String: JSON]] = [["version": .number(2)], ["extra": .bool(true)], ["request_id": .string("invalid")]]
        guard case .array(let subjects)? = valid["order_context"].object["subjects"] else { return XCTFail("Missing actual server subjects") }
        let subject = try XCTUnwrap(subjects.first)
        changes += [["subjects": .array([subject, subject])], ["subjects": .array([.object(["node_key": .string("first"), "reset_completion": .bool(false), "retired": .bool(false)])])]]
        for change in changes {
            var row = valid; row["order_context"] = .object(valid["order_context"].object.merging(change) { _, new in new })
            XCTAssertNil(TaskNodeActivity(row: row))
        }
    }
    func testNeutralAuditCannotMasqueradeAsOrdinaryCompletionOrOrdering() throws {
        let f = try fixture(), valid = f.clientFixture.neutral
        for change in [
            ["format_version": JSON.number(1)], ["format_version": .number(3)], ["kinds": .array([.string("completed")])],
            ["work_after": .bool(true)], ["node_key": .string("first")], ["completion_version": .number(1)],
            ["type_after": .string("task")], ["after_path": .array([.string("first")])], ["effective_at": .string("2020-01-01T00:00:00Z")]
        ] {
            var row = valid; for (key, value) in change { row[key] = value }
            XCTAssertNil(TaskNodeActivity(row: row))
        }
    }
    func testReconciliationCannotResetAnotherGeneration() throws {
        let f = try fixture(), original = reading(f.clientFixture.before, f).credits()
        var row = f.clientFixture.neutral; row["task_generation"] = .string(UUID().uuidString.lowercased())
        XCTAssertNotNil(TaskNodeActivity(row: row))
        XCTAssertEqual(reading(f.clientFixture.before + [row], f).credits(), original)
    }
    func testBackupPreservesAuditWithoutRestoringHistoricalWrites() throws {
        let f = try fixture(), rows = f.clientFixture.afterMapping, account = f.clientFixture.root.string("user_id")
        let snapshot = Snapshot(tables: [TaskNodeActivity.table: rows, TaskNodeActivity.epochTable: f.clientFixture.epoch])
        let file = try WorkspaceBackup.read(WorkspaceBackup.make(snapshot, account: account).data())
        XCTAssertEqual(file.tables[TaskNodeActivity.table], rows)
        XCTAssertTrue(try file.plan(current: Snapshot(), account: UUID().uuidString.lowercased()).changes.isEmpty)
    }
    func testBackupStillRejectsUnknownOrInvalidChildRecordingEpochs() throws {
        let f = try fixture(), account = f.clientFixture.root.string("user_id")
        for change in [["field_recorded_from": JSON.string("invalid")], ["order_recorded_from": .null], ["future_field": .bool(true)]] {
            var epoch = f.clientFixture.epoch
            for (key, value) in change { epoch[0][key] = value }
            let snapshot = Snapshot(tables: [TaskNodeActivity.table: f.clientFixture.afterMapping, TaskNodeActivity.epochTable: epoch])
            XCTAssertThrowsError(try WorkspaceBackup.read(WorkspaceBackup.make(snapshot, account: account).data()))
        }
    }

}
