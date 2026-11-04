import XCTest
@testable import TaskfoldCore

final class WorkflowCaptureUndoTests: XCTestCase {
    let owner = "ca000000-0000-4000-8000-000000000001"
    let origin = "https://native-auth.test"
    func fixture() -> (Snapshot, [Mutation], Record, Record) {
        var old = Record.task(user: owner); old["title"] = .string("Existing work")
        var fresh = Record.task(user: owner); fresh["title"] = .string("Captured work")
        let before = Record(["id": .string("scope:inbox"), "user_id": .string(owner), "ids": .array([.string(old.id)])])
        var after = before; after["ids"] = .array([.string(old.id), .string(fresh.id)])
        let run = UUID()
        let changes = [Mutation(table: "tasks", recordID: fresh.id, method: "POST", fields: fresh.fields, insertOnly: true, workflowRun: run),
                       Mutation(table: "view_orders", recordID: before.id, method: "PATCH", fields: after.fields, workflowRun: run)]
        return (Snapshot(tables: ["tasks": [old], "view_orders": [before]]), changes, old, fresh)
    }
    func testUndoRemovesTheBatchAndRestoresExistingOrderTogether() throws {
        var (snapshot, changes, old, fresh) = fixture()
        let history = EditHistory(changes: changes, snapshot: snapshot)
        let command = try XCTUnwrap(history.undo.first)
        XCTAssertEqual(history.undo.count, 1); XCTAssertEqual(command.table, WorkflowUndo.captureTable)
        changes.forEach { snapshot.apply($0) }
        try WorkflowUndo.validate(command, snapshot: snapshot, account: owner)
        snapshot.apply(command)
        XCTAssertEqual(snapshot.tables["tasks"]?.map(\.id), [old.id])
        XCTAssertFalse(snapshot.tables["tasks"]?.contains { $0.id == fresh.id } ?? true)
        XCTAssertEqual(snapshot.tables["view_orders"]?.first?["ids"], .array([.string(old.id)]))
    }
    func testRedoRestoresTasksAndOrderAndGetsANewUndoRequest() throws {
        var (snapshot, changes, old, fresh) = fixture()
        let first = try XCTUnwrap(WorkflowUndo.deleting(changes, snapshot: snapshot))
        changes.forEach { snapshot.apply($0) }; snapshot.apply(first)
        let redo = try XCTUnwrap(WorkflowUndo.restoring(first))
        let second = try XCTUnwrap(WorkflowUndo.deleting(redo, snapshot: snapshot))
        XCTAssertNotEqual(first.id, second.id)
        redo.forEach { snapshot.apply($0) }
        XCTAssertEqual(Set(snapshot.tables["tasks"]!.map(\.id)), [old.id, fresh.id])
        XCTAssertEqual(snapshot.tables["view_orders"]?.first?["ids"], .array([.string(old.id), .string(fresh.id)]))
        try WorkflowUndo.validate(second, snapshot: snapshot, account: owner)
        snapshot.apply(second)
        XCTAssertEqual(snapshot.tables["tasks"]?.map(\.id), [old.id])
    }
    func testLaterReorderRefusesTheWholeUndo() throws {
        var (snapshot, changes, old, fresh) = fixture()
        let command = try XCTUnwrap(WorkflowUndo.deleting(changes, snapshot: snapshot))
        changes.forEach { snapshot.apply($0) }
        snapshot.tables["view_orders"]?[0]["ids"] = .array([.string(fresh.id), .string(old.id)])
        let current = snapshot
        XCTAssertThrowsError(try WorkflowUndo.validate(command, snapshot: snapshot, account: owner))
        XCTAssertEqual(snapshot, current)
    }
    func testLaterTaskEditRefusesTheWholeUndo() throws {
        var (snapshot, changes, _, fresh) = fixture()
        let command = try XCTUnwrap(WorkflowUndo.deleting(changes, snapshot: snapshot))
        changes.forEach { snapshot.apply($0) }
        let index = try XCTUnwrap(snapshot.tables["tasks"]?.firstIndex { $0.id == fresh.id })
        snapshot.tables["tasks"]?[index]["title"] = .string("Updated elsewhere")
        XCTAssertThrowsError(try WorkflowUndo.validate(command, snapshot: snapshot, account: owner))
    }
    func testOrderRestoreCannotRemoveExistingWorkOrChangeItsOrder() throws {
        let (snapshot, changes, _, _) = fixture()
        var command = try XCTUnwrap(WorkflowUndo.deleting(changes, snapshot: snapshot))
        var orders = command.fields["order_restores"]!.list
        var entry = orders[0].object, restore = entry["restore"]!.object
        restore["ids"] = .array([]); entry["restore"] = .object(restore); orders[0] = .object(entry)
        command.fields["order_restores"] = .array(orders)
        XCTAssertNil(WorkflowUndo.items(command))
    }
    func testCaptureNeedsItsOwnCapabilityAndKeepsTheOrdinaryProtocolSeparate() throws {
        let (snapshot, changes, _, _) = fixture(), command = try XCTUnwrap(WorkflowUndo.deleting(changes, snapshot: snapshot))
        let raw: [String: JSON] = ["protocol": .number(1), "account": .string(owner), "undo_protocol": .number(1), "bulk_protocol": .number(1)]
        let legacy = try WorkflowUndoService(raw, account: owner, origin: origin)
        let current = try WorkflowUndoService(raw.merging(["capture_protocol": .number(1)]) { _, new in new }, account: owner, origin: origin)
        XCTAssertFalse(WorkflowUndo.canSend(command, boundary: nil, service: legacy, origin: origin))
        XCTAssertTrue(WorkflowUndo.canSend(command, boundary: nil, service: current, origin: origin))
        var wrongRoute = command; wrongRoute.table = WorkflowUndo.table; wrongRoute.method = "WORKFLOW_UNDO"
        XCTAssertNil(WorkflowUndo.items(wrongRoute))
        XCTAssertThrowsError(try WorkflowUndoService(raw.merging(["capture_protocol": .number(2)]) { _, new in new }, account: owner, origin: origin))
    }
    func testColdQueueRetainsOrdersAndMissingRemoteOrderDoesNotLeaveAPhantom() throws {
        var (snapshot, changes, _, _) = fixture()
        let command = try XCTUnwrap(WorkflowUndo.deleting(changes, snapshot: snapshot))
        changes.forEach { snapshot.apply($0) }; snapshot.apply(command); snapshot.pending = [command]
        snapshot = try TaskfoldJSONDecoder().decode(Snapshot.self, from: TaskfoldJSONEncoder().encode(snapshot))
        XCTAssertEqual(snapshot.pending, [command])
        let response = Record(["id": .string(command.id.uuidString.lowercased()), "applied": .bool(false), "rows": .array([])])
        XCTAssertTrue(WorkflowUndo.acknowledge(response, change: command, snapshot: &snapshot))
        XCTAssertTrue(snapshot.tables["view_orders"]?.isEmpty ?? false)
        XCTAssertTrue(snapshot.pending.isEmpty)
    }
    func testRepeatedOrderTargetsCannotBeRestoredTwice() throws {
        let (snapshot, changes, _, _) = fixture()
        var command = try XCTUnwrap(WorkflowUndo.deleting(changes, snapshot: snapshot))
        command.fields["order_restores"] = .array(command.fields["order_restores"]!.list + command.fields["order_restores"]!.list)
        XCTAssertNil(WorkflowUndo.items(command))
    }
    func testCaptureCannotBeCommittedWithoutItsInverse() {
        let (snapshot, changes, _, _) = fixture()
        XCTAssertTrue(WorkflowUndo.requiresCreationHistory(changes), "Redo must retain its inverse even when remember is false")
        XCTAssertTrue(WorkflowUndo.missingCreationHistory(changes, snapshot: snapshot, undo: []))
        XCTAssertFalse(WorkflowUndo.missingCreationHistory(changes, snapshot: snapshot, undo: EditHistory(changes: changes, snapshot: snapshot).undo))
    }
    @MainActor func testCaptureUsesItsOwnBoundedAtomicRouteWithoutDeleteFallback() async throws {
        let (snapshot, changes, _, _) = fixture(), command = try XCTUnwrap(WorkflowUndo.deleting(changes, snapshot: snapshot))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthTransportTests.Stub.self]
        let session = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(JSON.object([
            "access_token": .string("synthetic"), "refresh_token": .string("synthetic-refresh"),
            "expires_in": .number(3600), "user": .object(["id": .string(owner)])])))
        let backend = Backend(configuration: ["URL": origin, "Key": "public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        defer { AuthTransportTests.Stub.handler = nil }
        var requests = 0
        AuthTransportTests.Stub.handler = { request in
            requests += 1; XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_undo_capture_workflow")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertFalse(request.httpShouldHandleCookies)
            return (200, try JSONEncoder().encode(Record(["id": .string(command.id.uuidString.lowercased()), "applied": .bool(true), "rows": .array([])])))
        }
        let saved = try await backend.send(command, expectedAccount: owner)
        XCTAssertEqual(WorkflowUndo.reply(saved, change: command)?.applied, true)
        AuthTransportTests.Stub.handler = { _ in requests += 1; return (404, Data("{}".utf8)) }
        do { _ = try await backend.send(command, expectedAccount: owner); XCTFail("Missing service must preserve the command") } catch {}
        XCTAssertEqual(requests, 2, "No individual delete fallback")
    }
    func testOrderNormalizationKeepsTheCaptureInverseAndLegacyUpserts() throws {
        let (snapshot, changes, _, _) = fixture()
        let normalized = changes.map { DayPlacement.preparing($0, account: owner) }
        XCTAssertEqual(normalized.last?.method, "PATCH")
        XCTAssertNotNil(WorkflowUndo.deleting(normalized, snapshot: snapshot))
        var ordinary = changes.last!; ordinary.workflowRun = nil
        XCTAssertEqual(DayPlacement.preparing(ordinary, account: owner).method, "POST")
        var removal = ordinary; removal.method = "DELETE"
        XCTAssertEqual(DayPlacement.preparing(removal, account: owner), removal)
    }

    func testSyncedTimestampAndClockSpellingsDoNotLookLikeLaterEdits() throws {
        var (snapshot, changes, _, fresh) = fixture()
        changes[0].fields["created_at"] = .string("2026-11-04T10:00:00Z")
        changes[0].fields["scheduled_at"] = .string("2026-11-05T09:00:00Z")
        changes[0].fields["due_time"] = .string("09:00")
        let command = try XCTUnwrap(WorkflowUndo.deleting(changes, snapshot: snapshot))
        changes.forEach { snapshot.apply($0) }
        let index = try XCTUnwrap(snapshot.tables["tasks"]?.firstIndex { $0.id == fresh.id })
        snapshot.tables["tasks"]?[index]["created_at"] = .string("2026-11-04T10:00:00.000000+00:00")
        snapshot.tables["tasks"]?[index]["scheduled_at"] = .string("2026-11-05T09:00:00+00:00")
        snapshot.tables["tasks"]?[index]["due_time"] = .string("09:00:00")
        XCTAssertNoThrow(try WorkflowUndo.validate(command, snapshot: snapshot, account: owner))
        snapshot.tables["tasks"]?[index]["created_at"] = .string("2026-11-04T10:00:00.000001+00:00")
        XCTAssertThrowsError(try WorkflowUndo.validate(command, snapshot: snapshot, account: owner), "SQL microseconds remain distinct")
        snapshot.tables["tasks"]?[index]["created_at"] = .string("2026-11-04T10:00:00+00:00")
        snapshot.tables["tasks"]?[index]["due_time"] = .string("09:00:")
        XCTAssertThrowsError(try WorkflowUndo.validate(command, snapshot: snapshot, account: owner))
    }

}
