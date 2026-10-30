import XCTest
@testable import TaskfoldCore

final class ChildTaskTransferHistoryTests: XCTestCase {
    struct Fixture: Decodable {
        let beforeTransfer: [Record], afterTransfer: [Record], afterReopen: [Record], epoch: [Record]
    }
    func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cross-root-transfer-history-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    func reading(_ rows: [Record], _ f: Fixture) -> ChildWorkReading {
        ChildWorkReading(ChildWorkHistory(rows: rows, epoch: f.epoch), now: .distantFuture)
    }
    func testActualServerTransferRetainsOneObservedCompletionCredit() throws {
        let f = try fixture(), original = reading(f.beforeTransfer, f).credits()
        XCTAssertEqual(original.count, 1)
        XCTAssertEqual(reading(f.afterTransfer, f).credits(), original, "A transfer is neither new work nor a deletion of genuine work")
        XCTAssertFalse(reading(f.afterTransfer, f).incomplete)
        XCTAssertEqual(f.afterTransfer.compactMap(TaskNodeActivity.init).filter { $0.transfer != nil }.count, 2)
    }
    func testActualServerReopenAfterTransferCorrectsOriginalCredit() throws {
        let f = try fixture()
        XCTAssertTrue(reading(f.afterReopen, f).credits().isEmpty)
        XCTAssertFalse(reading(f.afterReopen, f).incomplete)
    }
    func testSourceOnlyHistoryPreservesGenuinePastWork() throws {
        let f = try fixture(), source = try XCTUnwrap(f.beforeTransfer.first?.string("task_id"))
        XCTAssertEqual(reading(f.afterReopen.filter { $0.string("task_id") == source }, f).credits().count, 1)
    }
    func testDestinationOnlyHistoryCannotInventEarlierCompletion() throws {
        let f = try fixture(), source = try XCTUnwrap(f.beforeTransfer.first?.string("task_id"))
        XCTAssertTrue(reading(f.afterTransfer.filter { $0.string("task_id") != source }, f).credits().isEmpty)
    }
    func testUnobservedSourceCompletionCannotBeManufacturedByTransfer() throws {
        let f = try fixture()
        let rows = f.afterTransfer.filter { $0["kinds"] != .array([.string("completed")]) }
        XCTAssertTrue(reading(rows, f).credits().isEmpty)
    }
    func testOldHistoryWithoutTransferMetadataRetainsConservativeBehavior() throws {
        let f = try fixture()
        let rows = f.afterReopen.map { row -> Record in var r = row; r.fields.removeValue(forKey: "transfer_context"); return r }
        XCTAssertEqual(reading(rows, f).credits().count, 1, "No identity link is guessed for older history")
    }
    func testMismatchedTransferIdentityCannotWithdrawUnrelatedCredit() throws {
        let f = try fixture()
        for field in ["request_id", "incarnation"] {
            var rows = f.afterReopen
            let index = try XCTUnwrap(rows.firstIndex { $0["transfer_context"] != .null && $0["kinds"] == .array([.string("created")]) })
            var context = rows[index]["transfer_context"].object; context[field] = .string(UUID().uuidString.lowercased()); rows[index]["transfer_context"] = .object(context)
            XCTAssertEqual(reading(rows, f).credits().count, 1, field)
        }
    }
    func testMalformedAndFutureTransferMetadataIsRejected() throws {
        let f = try fixture(), valid = try XCTUnwrap(f.afterTransfer.first { $0["transfer_context"] != .null })
        for value in [JSON.string("invalid"), .object([:]), .array([]), .bool(true)] {
            var row = valid; row["transfer_context"] = value; XCTAssertNil(TaskNodeActivity(row: row))
        }
        for change in [["version": JSON.number(2)], ["future_field": .bool(true)]] {
            var row = valid; row["transfer_context"] = .object(row["transfer_context"].object.merging(change) { _, new in new })
            XCTAssertNil(TaskNodeActivity(row: row))
        }
    }
    func testTransferContextCannotAttachToOrdinaryCompletion() throws {
        let f = try fixture(), transfer = try XCTUnwrap(f.afterTransfer.first { $0["transfer_context"] != .null })
        var row = try XCTUnwrap(f.beforeTransfer.first { $0["kinds"] == .array([.string("completed")]) })
        row["transfer_context"] = transfer["transfer_context"]; XCTAssertNil(TaskNodeActivity(row: row))
    }
    func testTransferSubjectsMustMatchExactEventAndDifferentRoots() throws {
        let f = try fixture(), valid = try XCTUnwrap(f.afterTransfer.first { $0["transfer_context"] != .null })
        var row = valid, context = row["transfer_context"].object
        context["destination"] = context["source"]; row["transfer_context"] = .object(context); XCTAssertNil(TaskNodeActivity(row: row))
        row = valid; context = row["transfer_context"].object
        var source = context["source"]!.object; source["node_key"] = .string("unrelated"); context["source"] = .object(source)
        row["transfer_context"] = .object(context); XCTAssertNil(TaskNodeActivity(row: row))
    }
    func testTransferredHistoryUsesMovedPresentationRatherThanNewOrDeletedWork() throws {
        let f = try fixture(), events = f.afterTransfer.compactMap(TaskNodeActivity.init).filter { $0.transfer != nil }
        XCTAssertEqual(events.count, 2)
        for event in events { XCTAssertEqual(WorkActivity.child(event).kinds, ["moved"]) }
    }
    func testProjectSummariesCountTransferAsMoveWithoutNewTaskCreation() throws {
        let f = try fixture(), rows = f.afterTransfer
        let transfer = try XCTUnwrap(rows.compactMap(TaskNodeActivity.init).first { $0.transfer != nil }?.transfer)
        let source = try XCTUnwrap(transfer.source.project), destination = try XCTUnwrap(transfer.destination.project)
        XCTAssertNotEqual(source, destination)
        let now = try XCTUnwrap(rows.compactMap { TaskPlanning.instant($0.string("recorded_at")) }.max()).addingTimeInterval(1)
        let children = ChildWorkHistory(rows: rows, epoch: f.epoch)
        let from = ProjectPulseReading(project: source, tasks: [], activity: [], now: now, children: children)
        let to = ProjectPulseReading(project: destination, tasks: [], activity: [], now: now, children: children)
        XCTAssertEqual(from.movedOut, 1); XCTAssertEqual(from.movedIn, 0)
        XCTAssertEqual(to.movedIn, 1); XCTAssertEqual(to.movedOut, 0)
        XCTAssertEqual(to.additions, 0, "A moved subtask was not newly created")
    }
    func testTransferProjectMustMatchTheCapturedEventScope() throws {
        let f = try fixture(), valid = try XCTUnwrap(f.afterTransfer.first { $0["transfer_context"] != .null })
        for field in ["source", "destination"] {
            var row = valid, context = row["transfer_context"].object
            var subject = try XCTUnwrap(context[field]?.object)
            subject["project_id"] = .string("invalid"); context[field] = .object(subject); row["transfer_context"] = .object(context)
            XCTAssertNil(TaskNodeActivity(row: row))
        }
    }
    func testTransferHistorySurvivesBackupWithoutRestoringHistoricalWrites() throws {
        let f = try fixture(), account = try XCTUnwrap(f.afterReopen.first?.string("user_id"))
        let snapshot = Snapshot(tables: [TaskNodeActivity.table: f.afterReopen, TaskNodeActivity.epochTable: f.epoch])
        let file = try WorkspaceBackup.read(WorkspaceBackup.make(snapshot, account: account).data())
        XCTAssertEqual(file.tables[TaskNodeActivity.table], f.afterReopen)
        XCTAssertTrue(try file.plan(current: Snapshot(), account: UUID().uuidString.lowercased()).changes.isEmpty)
    }
}
