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
    @MainActor func testMacEditSendsBaselineAndPropagatesConflict() async throws {
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

}
