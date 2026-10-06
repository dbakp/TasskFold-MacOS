import XCTest
@testable import TaskfoldCore

final class TaskDeletionTests: XCTestCase {
    private func task(_ title: String = "Next occurrence") -> Record {
        Record(["id": .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), "user_id": .string("owner"), "title": .string(title), "comments": .array([])])
    }
    func testUndoOfCreationCarriesOriginalWholeTaskAndRestoreIsCreateOnly() throws {
        let original = task(), create = Mutation(table: "tasks", recordID: original.id, method: "POST", fields: original.fields, insertOnly: true)
        let undo = try XCTUnwrap(EditHistory(changes: [create], snapshot: Snapshot()).undo.first)
        XCTAssertEqual(undo.method, "DELETE"); XCTAssertEqual(undo.baseline, original.fields)
        let restore = try XCTUnwrap(EditHistory(changes: [undo], snapshot: Snapshot(tables: ["tasks": [original]])).undo.first)
        XCTAssertEqual(restore.method, "POST"); XCTAssertEqual(restore.insertOnly, true)
        XCTAssertEqual(restore.fields, original.fields)
    }
    func testIndependentCompletionsHaveDifferentCreationProvenanceWithSameOccurrenceID() throws {
        var source = task(); source["due_date"] = .string("2026-10-24"); source["is_recurring"] = .bool(true)
        source["recurrence_pattern"] = .object(["type": .string("daily")]); source["source_metadata"] = .object(["future": .number(2)])
        let now = ISO8601DateFormatter().date(from: "2026-10-24T12:00:00Z")!
        let a = TaskCompletion.complete(source, tasks: [source], at: now), b = TaskCompletion.complete(source, tasks: [source], at: now)
        XCTAssertEqual(a[1].recordID, b[1].recordID)
        XCTAssertNotEqual(a[1].fields["source_metadata"], b[1].fields["source_metadata"])
        let metadata = try XCTUnwrap(a[1].fields["source_metadata"]?.object)
        XCTAssertEqual(metadata["future"], .number(2))
        XCTAssertEqual(metadata["taskfold_recurrence_v1"]?.object["action_id"], .string(a[0].id.uuidString.lowercased()))
        let undo = EditHistory(changes: a, snapshot: Snapshot(tables: ["tasks": [source]])).undo
        XCTAssertEqual(undo.first?.baseline?["source_metadata"], a[1].fields["source_metadata"])
    }
    func testKeepTaskRestoresAllRemoteContentsAndReplaysLaterOfflineWork() throws {
        let original = task(), deletion = Mutation(table: "tasks", recordID: original.id, method: "DELETE", fields: [:], baseline: original.fields)
        var remote = task("Edited on another device"); remote["comments"] = .array([.object(["id": .string("c"), "text": .string("Keep")])])
        let later = Mutation(table: "tasks", recordID: original.id, method: "PATCH", fields: ["duration_minutes": .number(45)], baseline: ["duration_minutes": .null])
        let other = Mutation(table: "tasks", recordID: "other", method: "PATCH", fields: ["completed": .bool(true)])
        let snapshot = Snapshot(tables: ["tasks": []], pending: [deletion, later, other])
        let next = try XCTUnwrap(SyncConflict(mutation: deletion, remote: remote).resolving(snapshot, keepLocal: false))
        XCTAssertEqual(next.pending, [later, other]); XCTAssertEqual(next.tables["tasks"]?.first?.title, remote.title)
        XCTAssertEqual(next.tables["tasks"]?.first?["comments"], remote["comments"]); XCTAssertEqual(next.tables["tasks"]?.first?.durationMinutes, 45)
        XCTAssertEqual(snapshot.pending.count, 3)
        XCTAssertEqual(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(next)), next)
    }
    func testExplicitDeletionRebasesWholeTaskAndRejectsStaleReview() throws {
        let original = task(), deletion = Mutation(table: "tasks", recordID: original.id, method: "DELETE", fields: [:], baseline: original.fields)
        let remote = task("Changed")
        let snapshot = Snapshot(tables: ["tasks": []], pending: [deletion])
        let review = SyncConflict(mutation: deletion, remote: remote)
        let next = try XCTUnwrap(review.resolving(snapshot, keepLocal: true))
        XCTAssertEqual(next.pending.first?.baseline, remote.fields); XCTAssertEqual(next.pending.first?.method, "DELETE")
        XCTAssertTrue(next.tables["tasks"]?.isEmpty == true)
        var stale = snapshot; stale.pending[0].baseline?["title"] = .string("Already reviewed")
        XCTAssertNil(review.resolving(stale, keepLocal: true)); XCTAssertNil(review.resolving(Snapshot(), keepLocal: false))
        var wrong = review; wrong.remote["id"] = .string("another")
        XCTAssertNil(wrong.resolving(snapshot, keepLocal: false))
    }
    @MainActor func testNativeDeletionSendsWholeBaselineAndRequiresPositiveAcknowledgement() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthTransportTests.Stub.self]
        let session = try JSONDecoder().decode(Session.self, from: Data(#"{"access_token":"test","refresh_token":"refresh","expires_in":3600,"user":{"id":"owner"}}"#.utf8))
        let backend = Backend(configuration: ["URL": "https://native-auth.test", "Key": "public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        let original = task(), change = Mutation(table: "tasks", recordID: original.id, method: "DELETE", fields: [:], baseline: original.fields)
        AuthTransportTests.Stub.handler = { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_delete_task"); XCTAssertEqual(request.httpMethod, "POST")
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
            }
            let body = try JSONDecoder().decode(Record.self, from: data)
            XCTAssertEqual(body["_base"], .object(original.fields)); XCTAssertEqual(body["_id"], .string(original.id))
            return (200, Data("true".utf8))
        }
        defer { AuthTransportTests.Stub.handler = nil }
        try await backend.send(change)
        AuthTransportTests.Stub.handler = { _ in (200, Data("false".utf8)) }
        do { try await backend.send(change); XCTFail("A refused deletion cannot be acknowledged") } catch { XCTAssertTrue(error.localizedDescription.contains("did not confirm")) }
        AuthTransportTests.Stub.handler = { _ in (409, Data(#"{"message":"TASKFOLD_CONFLICT: Task changed"}"#.utf8)) }
        do { try await backend.send(change); XCTFail("Keep conflicts queued") } catch { XCTAssertTrue(error.localizedDescription.contains("TASKFOLD_CONFLICT:")) }
        var called = false; AuthTransportTests.Stub.handler = { request in
            called = true; XCTAssertEqual(request.url?.path, "/rest/v1/tasks"); XCTAssertEqual(request.httpMethod, "GET")
            return (200, Data("[{\"id\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\"}]".utf8))
        }
        var legacy = change; legacy.baseline = nil
        do { try await backend.send(legacy); XCTFail("Legacy deletions require review") } catch { XCTAssertTrue(error.localizedDescription.contains("TASKFOLD_CONFLICT:")) }
        XCTAssertTrue(called)
        AuthTransportTests.Stub.handler = { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/tasks"); XCTAssertEqual(request.httpMethod, "GET")
            return (200, Data("[]".utf8))
        }
        try await backend.send(legacy) // No blind delete, no permanently stuck already-deleted row.
    }
}
