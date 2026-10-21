import XCTest
@testable import TaskfoldCore

/// Opt-in genuine HTTP proof. Accepts only newly provisioned example.invalid accounts.
final class ConversationTransportIntegrationTests: XCTestCase {
    struct Fixture: Decodable { let url: String; let key: String; let accounts: [Account] }
    struct Account: Decodable { let userID: String; let emailIdentity: String; let email: String; let password: String }
    @MainActor func testSharedCommentRetryReviewPaginationAndRecipientReadState() async throws {
        guard let path = ProcessInfo.processInfo.environment["TASKFOLD_CONVERSATION_LIVE_FIXTURE"] else { throw XCTSkip("Disposable shared-conversation accounts required") }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard fixture.accounts.count == 2, fixture.url == "https://zqxflydiyfjeedqvyova.supabase.co", fixture.accounts.allSatisfy({ UUID(uuidString: $0.userID) != nil && UUID(uuidString: $0.emailIdentity) != nil && $0.email == "taskfold-continuity-" + $0.emailIdentity + "@example.invalid" }) else { throw AppFailure(message: "Synthetic conversation accounts required") }
        func check<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(actual, expected, message, file: file, line: line) }
        let owner = fixture.accounts[0], member = fixture.accounts[1]
        func client() -> Backend { Backend(configuration: ["URL": fixture.url, "Key": fixture.key], http: URLSession(configuration: .ephemeral), session: nil, persistSession: { _ in }) }
        let a = client(), b = client(), recipient = client()
        let signedA = try await a.signIn(email: owner.email, password: owner.password, signup: false)
        let signedB = try await b.signIn(email: owner.email, password: owner.password, signup: false)
        let signedRecipient = try await recipient.signIn(email: member.email, password: member.password, signup: false)
        XCTAssertTrue(signedA && signedB && signedRecipient)
        check(a.session?.user.id, owner.userID); check(recipient.session?.user.id, member.userID)
        let projectID = UUID().uuidString.lowercased(), membershipID = UUID().uuidString.lowercased()
        var task = Record.task(user: owner.userID, project: projectID); task["title"] = .string("Synthetic conversation transport proof")
        task["comments"] = .array([.object(["id": .string("historical"), "text": .string("Imported @name remains historical"), "opaque": .number(7)])])
        func cleanup() async throws {
            if let current = try await a.rows("tasks").first(where: { $0.id == task.id }) { _ = try await a.send(Mutation(table: "tasks", recordID: task.id, method: "DELETE", fields: [:], baseline: current.fields)) }
            _ = try await a.request("/rest/v1/projects?id=eq." + projectID, method: "DELETE", expectedAccount: owner.userID)
        }
        do {
            _ = try await a.send(Mutation(table: "projects", recordID: projectID, method: "POST", fields: ["id": .string(projectID), "user_id": .string(owner.userID), "name": .string("Synthetic conversation studio")], insertOnly: true))
            _ = try await a.request("/rest/v1/project_collaborators", method: "POST", body: ["id": .string(membershipID), "project_id": .string(projectID), "user_id": .string(member.userID), "invited_email": .string(member.email), "invited_by": .string(owner.userID), "role": .string("collaborator"), "status": .string("pending")], expectedAccount: owner.userID)
            _ = try await recipient.request("/rest/v1/project_collaborators?id=eq." + membershipID, method: "PATCH", body: ["status": .string("accepted")], expectedAccount: member.userID)
            let inserted = try await a.send(Mutation(table: "tasks", recordID: task.id, method: "POST", fields: task.fields, insertOnly: true))
            task = try XCTUnwrap(inserted)
            func write(_ text: String, revision: Int64 = 0, comment: String = UUID().uuidString.lowercased(), mentions: [String] = []) throws -> SharedCommentChange {
                try SharedCommentChange(account: owner.userID, taskID: task.id, taskGeneration: task.string("task_generation"), projectID: projectID, commentID: comment, expectedRevision: revision, body: text, mentionIDs: mentions)
            }
            let original = try write("Please review the final notes.\nLiteral @name is just text.", mentions: [member.userID])
            let sent = try await a.writeSharedComment(original); check(sent.status, .saved); check(sent.current?.authorID, owner.userID)
            check(try await a.writeSharedComment(original).acknowledgedRevision, 1)
            check(try await recipient.sharedMentionsSummary(account: member.userID).unread, 1)
            let inbox = try await recipient.sharedMentionsPage(account: member.userID, unreadOnly: true)
            let mention = try XCTUnwrap(inbox.rows.first.flatMap(SharedMention.init)); check(mention.commentID, original.commentID)
            let fetched = try await recipient.sharedComments(ids: [original.commentID], account: member.userID)
            check(fetched.first?.string("body"), original.body)
            let read = try SharedMentionChange(mention: mention, account: member.userID, read: true)
            check(try await recipient.markSharedMention(read).current?.isRead, true)
            check(try await recipient.markSharedMention(read).acknowledgedRevision, 2)
            check(try await recipient.sharedMentionsSummary(account: member.userID).unread, 0)
            let concurrent = try write("Second device’s updated notes", revision: 1, comment: original.commentID, mentions: [member.userID])
            check(try await b.writeSharedComment(concurrent).current?.revision, 2)
            let late = try await a.writeSharedComment(original); check(late.acknowledgedRevision, 1); check(late.current?.body, concurrent.body)
            let stale = try write("My retained offline draft", revision: 1, comment: original.commentID, mentions: [member.userID])
            var snapshot = Snapshot(); try ConversationOutbox.enqueue(stale.record, into: &snapshot)
            let conflict = try await a.writeSharedComment(stale); check(conflict.status, .conflict)
            ConversationOutbox.apply(conflict, change: stale, to: &snapshot)
            snapshot = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
            check(ConversationOutbox.comment(snapshot.tables[ConversationOutbox.table]![0])?.body, stale.body)
            let reviewed = try write(stale.body, revision: try XCTUnwrap(conflict.current).revision, comment: stale.commentID, mentions: stale.mentionIDs)
            check(try await a.writeSharedComment(reviewed).current?.revision, 3)
            check(try await recipient.sharedMentionsSummary(account: member.userID).unread, 0, "Editing must not reset read state")
            for n in 1...50 { check(try await a.writeSharedComment(write("Pagination proof \(n)")).status, .saved) }
            let newest = try await recipient.sharedCommentsPage(task: task, account: member.userID)
            check(newest.rows.count, 50); XCTAssertTrue(newest.hasMore)
            let older = try await recipient.sharedCommentsPage(task: task, account: member.userID, cursor: XCTUnwrap(newest.cursor))
            check(older.rows.count, 1); XCTAssertFalse(older.hasMore)
            check(Set((newest.rows + older.rows).map(\.id)).count, 51)
            let deletion = try SharedCommentChange(account: owner.userID, taskID: task.id, taskGeneration: task.string("task_generation"), projectID: projectID, commentID: original.commentID, expectedRevision: 3, body: "", deleting: true)
            let removed = try await a.writeSharedComment(deletion)
            XCTAssertTrue(try XCTUnwrap(removed.current).isDeleted)
            check(try await recipient.sharedMentionsSummary(account: member.userID).total, 0)
            check(try await a.rows("tasks").first(where: { $0.id == task.id })?["comments"], task["comments"])
            try await cleanup()
        } catch { try? await cleanup(); throw error }
    }
}
