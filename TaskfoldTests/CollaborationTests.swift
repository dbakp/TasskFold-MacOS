import XCTest
@testable import TaskfoldCore

final class CollaborationTests: XCTestCase {
    func testAssignmentRosterUsesPersonIDsAndAcceptedMembers() {
        let project = Record(["user_id": .string("owner")])
        let members = TaskAssignment.members(project: project, collaborators: [
            Record(["id": .string("membership"), "user_id": .string("member"), "status": .string("accepted"), "display_name": .string("Alex")]),
            Record(["user_id": .string("pending"), "status": .string("pending")]),
            Record(["status": .string("accepted")])
        ], currentUser: "owner", profile: Record())
        XCTAssertEqual(Set(members.map(\.id)), ["owner", "member"])
        XCTAssertEqual(members.first { $0.id == "owner" }?.string("display_name"), "You")
    }
    func testOwnerNameAndPhotoSurviveRosterAndEmptyLocalProfile() {
        let project = Record(["user_id": .string("owner")])
        let owner = Record(["user_id": .string("owner"), "status": .string("accepted"), "display_name": .string("Morgan Lee"), "avatar_url": .string("https://example.com/photo.jpg")])
        for viewer in ["owner", "collaborator"] {
            let members = TaskAssignment.members(project: project, collaborators: [owner], currentUser: viewer, profile: Record())
            XCTAssertEqual(members.first?.string("display_name"), "Morgan Lee")
            XCTAssertEqual(members.first?.string("avatar_url"), "https://example.com/photo.jpg")
        }
        let custom = Record(["display_name": .string("Morgan"), "avatar_url": .string("https://example.com/custom.jpg")])
        let member = TaskAssignment.members(project: project, collaborators: [owner], currentUser: "owner", profile: custom).first
        XCTAssertEqual(member?.string("display_name"), "Morgan")
        XCTAssertEqual(member?.string("avatar_url"), "https://example.com/custom.jpg")
    }
    func testProjectMoveClearsOldAssignmentsAndQueuesNewMemberAfterMove() {
        let old = Record(["id": .string("task"), "project_id": .string("a"), "assigned_to": .string("old-person"), "subtasks": .array([.object(["title": .string("Child"), "assigned_to": .string("old-person")])])])
        var change = Mutation(table: "tasks", recordID: "task", method: "PATCH", fields: ["project_id": .string("b"), "assigned_to": .string("new-person")])
        let mutations = TaskAssignment.mutations(change, existing: old)
        XCTAssertEqual(mutations.count, 2)
        XCTAssertEqual(mutations[0].fields["assigned_to"], .null)
        XCTAssertEqual(mutations[0].fields["subtasks"]?.list.first?.object["assigned_to"], .null)
        XCTAssertEqual(mutations[1].fields, ["assigned_to": .string("new-person")])
        XCTAssertEqual(mutations[1].baseline, ["assigned_to": .null])
        change.fields = ["project_id": .null]
        XCTAssertEqual(TaskAssignment.mutations(change, existing: old).count, 1)
        XCTAssertEqual(TaskAssignment.mutations(change, existing: old)[0].fields["assigned_to"], .null)
    }
    func json(_ string: String) throws -> JSON { try JSONDecoder().decode(JSON.self, from: Data(string.utf8)) }
    func testConflictResolutionPreservesIndependentCommentsAndNestedEdits() throws {
        let base = try json("""
        [{"id":"a","text":"Original"}]
        """)
        let local = try json("""
        [{"id":"a","text":"My edit"}]
        """)
        let remote = try json("""
        [{"id":"a","text":"Their edit"},{"id":"b","text":"New remote comment"}]
        """)
        let merged = TaskEdit.keepingLocal(base: base, desired: local, remote: remote)
        XCTAssertEqual(merged.list.count, 2)
        XCTAssertEqual(merged.list[0].object["text"], .string("My edit"))
        XCTAssertEqual(merged.list[1], remote.list[1])
        let before = try json("""
        {"title":"Child","subtasks":[{"id":"grand","completed":false}]}
        """)
        let ours = try json("""
        {"title":"Renamed","subtasks":[{"id":"grand","completed":false}]}
        """)
        let theirs = try json("""
        {"title":"Child","subtasks":[{"id":"grand","completed":true}]}
        """)
        let nested = TaskEdit.keepingLocal(base: before, desired: ours, remote: theirs)
        XCTAssertEqual(nested.object["title"], .string("Renamed"))
        XCTAssertEqual(nested.object["subtasks"], theirs.object["subtasks"])
    }
    func testUndoCommentAdditionPreservesRemoteComment() throws {
        let original = Record(["id": .string("task"), "comments": .array([])])
        let added = try json("""
        [{"id":"mine","text":"My comment"}]
        """)
        var snapshot = Snapshot(); snapshot.tables["tasks"] = [original]
        let history = EditHistory(changes: [Mutation(table: "tasks", recordID: "task", method: "PATCH", fields: ["comments": added])], snapshot: snapshot)
        let remote = try json("""
        [{"id":"mine","text":"My comment"},{"id":"theirs","text":"Their comment"}]
        """)
        let undo = try XCTUnwrap(history.undo.first)
        let merged = TaskEdit.keepingLocal(base: undo.baseline!["comments"]!, desired: undo.fields["comments"]!, remote: remote)
        XCTAssertEqual(merged.list.map { $0.object["id"]!.text }, ["theirs"])
    }
    func testOldQueueDecodesAndNewBaselinePersists() throws {
        let data = Data("""
        {"id":"00000000-0000-4000-8000-000000000001","table":"tasks","recordID":"task","method":"PATCH","fields":{"title":"Edit"}}
        """.utf8)
        var change = try JSONDecoder().decode(Mutation.self, from: data)
        XCTAssertNil(change.baseline)
        change.baseline = ["title": .string("Before")]
        XCTAssertEqual(try JSONDecoder().decode(Mutation.self, from: JSONEncoder().encode(change)), change)
    }
    @MainActor func testNativeEditSendsBaselineAndPropagatesConflict() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthTransportTests.Stub.self]
        let session = try JSONDecoder().decode(Session.self, from: Data(#"{"access_token":"test","refresh_token":"refresh","expires_in":3600,"user":{"id":"one","email":"native@example.com"}}"#.utf8))
        let backend = Backend(configuration: ["URL": "https://native-auth.test", "Key": "public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        var called = false
        AuthTransportTests.Stub.handler = { request in
            called = true
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_patch_task")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test")
            // URLSession may place encoded body in a stream when a URLProtocol intercepts it.
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
            }
            let body = try JSONDecoder().decode(Record.self, from: data)
            XCTAssertEqual(body["_base"].object["title"], .string("Before"))
            XCTAssertEqual(body["_changes"].object["title"], .string("After"))
            return (409, Data(#"{"message":"TASKFOLD_CONFLICT: Same field changed"}"#.utf8))
        }
        defer { AuthTransportTests.Stub.handler = nil }
        do {
            try await backend.send(Mutation(table: "tasks", recordID: "task", method: "PATCH", fields: ["title": .string("After")], baseline: ["title": .string("Before")]))
            XCTFail("A conflict must remain in the queue")
        } catch { XCTAssertTrue(error.localizedDescription.contains("TASKFOLD_CONFLICT:")) }
        XCTAssertTrue(called)
    }

    func testQueuedResolutionPreservesRemoteFieldsCommentsAndLaterOfflineEdits() throws {
        let base = try json(#"[{"id":"a","text":"Before"}]"#)
        let local = try json(#"[{"id":"a","text":"Mine"}]"#)
        let remoteComments = try json(#"[{"id":"a","text":"Theirs"},{"id":"b","text":"Independent"}]"#)
        let mutation = Mutation(table: "tasks", recordID: "task", method: "PATCH", fields: ["comments": local], baseline: ["comments": base])
        let later = Mutation(table: "tasks", recordID: "task", method: "PATCH", fields: ["duration_minutes": .number(45)], baseline: ["duration_minutes": .null])
        let remote = Record(["id": .string("task"), "title": .string("Remote title"), "comments": remoteComments, "deadline_date": .string("2026-10-25")])
        var snapshot = Snapshot(); snapshot.tables["tasks"] = [Record(["id": .string("task"), "title": .string("Old title"), "comments": local])]; snapshot.pending = [mutation, later]
        let conflict = SyncConflict(mutation: mutation, remote: remote)
        let next = try XCTUnwrap(conflict.resolving(snapshot, keepLocal: true))
        XCTAssertEqual(next.pending.count, 2)
        XCTAssertEqual(next.pending[0].baseline?["comments"], remoteComments)
        XCTAssertEqual(next.pending[0].fields["comments"]?.list.map { $0.object["text"]?.text }, ["Mine", "Independent"])
        XCTAssertEqual(next.pending[1], later)
        let task = try XCTUnwrap(next.tables["tasks"]?.first)
        XCTAssertEqual(task.title, "Remote title"); XCTAssertEqual(task["deadline_date"], .string("2026-10-25")); XCTAssertEqual(task.durationMinutes, 45)
        let persisted = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(next))
        XCTAssertEqual(persisted, next)
        XCTAssertEqual(snapshot.pending[0], mutation, "Planning a resolution must not mutate the input")
    }
    func testUsingSyncedVersionDropsOnlyReviewedMutation() throws {
        let edit = Mutation(table: "tasks", recordID: "task", method: "PATCH", fields: ["title": .string("Mine")], baseline: ["title": .string("Before")])
        let later = Mutation(table: "tasks", recordID: "task", method: "PATCH", fields: ["title": .string("Later offline title")], baseline: ["title": .string("Mine")])
        let other = Mutation(table: "tasks", recordID: "other", method: "PATCH", fields: ["completed": .bool(true)])
        var snapshot = Snapshot(); snapshot.tables["tasks"] = [Record(["id": .string("task"), "title": .string("Later offline title")])]; snapshot.pending = [edit, later, other]
        let conflict = SyncConflict(mutation: edit, remote: Record(["id": .string("task"), "title": .string("Synced title"), "duration_minutes": .number(25)]))
        let next = try XCTUnwrap(conflict.resolving(snapshot, keepLocal: false))
        XCTAssertEqual(next.pending, [later, other]); XCTAssertEqual(next.tables["tasks"]?.first?.title, "Later offline title")
        XCTAssertEqual(next.tables["tasks"]?.first?.durationMinutes, 25)
        var stale = snapshot; stale.pending[0].fields["title"] = .string("Changed since review")
        XCTAssertNil(conflict.resolving(stale, keepLocal: true))
        stale.pending.removeFirst(); XCTAssertNil(conflict.resolving(stale, keepLocal: false))
        var mismatched = conflict; mismatched.remote["id"] = .string("another-task")
        XCTAssertNil(mismatched.resolving(snapshot, keepLocal: true))
    }
    @MainActor func testNativeGuardedEditChecksServerConfirmationAndProtectsOldQueues() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthTransportTests.Stub.self]
        let session = try JSONDecoder().decode(Session.self, from: Data(#"{"access_token":"test","refresh_token":"refresh","expires_in":3600,"user":{"id":"one","email":"native@example.com"}}"#.utf8))
        let backend = Backend(configuration: ["URL": "https://native-auth.test", "Key": "public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        let change = Mutation(table: "tasks", recordID: "task", method: "PATCH", fields: ["title": .string("After")], baseline: ["title": .string("Before")])
        AuthTransportTests.Stub.handler = { request in XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_patch_task"); return (200, Data(#"{"id":"task","title":"After"}"#.utf8)) }
        defer { AuthTransportTests.Stub.handler = nil }
        try await backend.send(change)
        AuthTransportTests.Stub.handler = { _ in (200, Data(#"{"id":"other"}"#.utf8)) }
        do { try await backend.send(change); XCTFail("A different task must never acknowledge this edit") } catch { XCTAssertTrue(error.localizedDescription.contains("did not confirm")) }
        var legacySent = false
        AuthTransportTests.Stub.handler = { _ in legacySent = true; return (200, Data(#"{"id":"task"}"#.utf8)) }
        var legacy = change; legacy.baseline = nil
        do { try await backend.send(legacy); XCTFail("Old edits must remain guarded") } catch { XCTAssertTrue(error.localizedDescription.contains("TASKFOLD_CONFLICT:")) }
        XCTAssertFalse(legacySent)
    }
    func testUnknownLegacyBaselineRequiresExplicitValueChoiceIncludingClear() throws {
        let change = Mutation(table: "tasks", recordID: "task", method: "PATCH", fields: ["description": .null])
        let remote = Record(["id": .string("task"), "description": .string("Synced note"), "title": .string("Another edit")])
        var snapshot = Snapshot(); snapshot.tables["tasks"] = [remote]; snapshot.pending = [change]
        let conflict = SyncConflict(mutation: change, remote: remote)
        let keep = try XCTUnwrap(conflict.resolving(snapshot, keepLocal: true))
        XCTAssertEqual(keep.pending.first?.fields["description"], .null)
        XCTAssertEqual(keep.pending.first?.baseline?["description"], .string("Synced note"))
        XCTAssertEqual(keep.tables["tasks"]?.first?.title, "Another edit")
        let shared = try XCTUnwrap(conflict.resolving(snapshot, keepLocal: false))
        XCTAssertTrue(shared.pending.isEmpty); XCTAssertEqual(shared.tables["tasks"]?.first?["description"], .string("Synced note"))
    }

    func testReviewTreatsUUIDSpellingsAsOneTaskDuringLaterReplay() throws {
        let id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let edit = Mutation(table: "tasks", recordID: id.uppercased(), method: "PATCH", fields: ["title": .string("My choice")], baseline: ["title": .string("Before")])
        let later = Mutation(table: "tasks", recordID: id, method: "PATCH", fields: ["duration_minutes": .number(45)], baseline: ["duration_minutes": .null])
        let remote = Record(["id": .string(id), "title": .string("Synced choice")])
        var snapshot = Snapshot(); snapshot.tables["tasks"] = [remote]; snapshot.pending = [edit, later]
        let next = try XCTUnwrap(SyncConflict(mutation: edit, remote: remote).resolving(snapshot, keepLocal: true))
        XCTAssertEqual(next.tables["tasks"]?.count, 1)
        XCTAssertEqual(next.tables["tasks"]?.first?.title, "My choice")
        XCTAssertEqual(next.tables["tasks"]?.first?.durationMinutes, 45)
        XCTAssertEqual(next.pending[1], later)
        let persisted = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(next))
        XCTAssertEqual(persisted, next)
    }

}
