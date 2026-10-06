import XCTest
@testable import TaskfoldCore

final class NativeConflictIntegrationTests: XCTestCase {
    /// Opt-in fixture credentials belong to a disposable example.invalid account.
    @MainActor func testTwoAuthenticatedNativeClientsMergeRetryAndReviewConflicts() async throws {
        guard let path = ProcessInfo.processInfo.environment["TASKFOLD_CONFLICT_LIVE_FIXTURE"] else { throw XCTSkip("Disposable conflict fixture not supplied") }
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let email = try XCTUnwrap(fixture["email"]), password = try XCTUnwrap(fixture["password"]), owner = try XCTUnwrap(fixture["userID"])
        guard email.hasPrefix("taskfold-conflict-"), email.hasSuffix("@example.invalid"), UUID(uuidString: owner) != nil else { throw AppFailure(message: "Use a disposable conflict fixture account.") }
        let configuration = ["URL": try XCTUnwrap(fixture["url"]), "Key": try XCTUnwrap(fixture["key"])]
        let a = Backend(configuration: configuration, http: URLSession(configuration: .ephemeral), session: nil, persistSession: { _ in })
        let b = Backend(configuration: configuration, http: URLSession(configuration: .ephemeral), session: nil, persistSession: { _ in })
        let signedA = try await a.signIn(email: email, password: password, signup: false)
        let signedB = try await b.signIn(email: email, password: password, signup: false)
        XCTAssertTrue(signedA && signedB); XCTAssertEqual(a.session?.user.id, owner); XCTAssertEqual(b.session?.user.id, owner)
        XCTAssertNotEqual(a.session?.access_token, b.session?.access_token)
        var task = Record.task(user: owner, date: Date().addingTimeInterval(86400)); task["title"] = .string("Native conflict fixture"); task["comments"] = .array([])
        let deletion = Mutation(table: "tasks", recordID: task.id, method: "DELETE", fields: [:])
        try await a.send(Mutation(table: "tasks", recordID: task.id, method: "POST", fields: task.fields))
        do {
            // A pre-upgrade queue with no baseline cannot silently replace work.
            do { try await a.send(Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: ["title": .string("Unreviewed legacy title")])); XCTFail("Legacy edits need review") } catch { XCTAssertTrue(error.localizedDescription.contains("TASKFOLD_CONFLICT:")) }
            try await b.send(Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: ["title": .string("First device title")], baseline: ["title": task["title"]]))
            try await a.send(Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: ["deadline_date": .string("2026-10-25")], baseline: ["deadline_date": .null]))
            let mine: JSON = .array([.object(["id": .string("a"), "text": .string("First comment")])])
            let theirs: JSON = .array([.object(["id": .string("b"), "text": .string("Independent comment")])])
            try await a.send(Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: ["comments": mine], baseline: ["comments": .array([])]))
            let second = Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: ["comments": theirs], baseline: ["comments": .array([])])
            try await b.send(second); try await b.send(second)
            let remoteRows = try await b.rows("tasks")
            let remote = try XCTUnwrap(remoteRows.first { $0.id == task.id })
            XCTAssertEqual(remote.title, "First device title"); XCTAssertEqual(remote["deadline_date"], .string("2026-10-25")); XCTAssertEqual(remote["comments"].list.count, 2)
            let desired = Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: ["title": .string("My chosen title")], baseline: ["title": task["title"]])
            do { try await a.send(desired); XCTFail("An overlapping edit must pause") } catch { XCTAssertTrue(error.localizedDescription.contains("TASKFOLD_CONFLICT:")) }
            var queue = Snapshot(); queue.tables["tasks"] = [remote]; queue.pending = [desired]
            let reviewed = try XCTUnwrap(SyncConflict(mutation: desired, remote: remote).resolving(queue, keepLocal: true))
            let saved = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(reviewed))
            let rebased = try XCTUnwrap(saved.pending.first)
            // An edit made after the review must conflict again, rather than be overwritten.
            try await b.send(Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: ["title": .string("Changed during review")], baseline: ["title": remote["title"]]))
            do { try await a.send(rebased); XCTFail("A newer overlapping edit must pause again") } catch { XCTAssertTrue(error.localizedDescription.contains("TASKFOLD_CONFLICT:")) }
            let latestRows = try await a.rows("tasks")
            let latest = try XCTUnwrap(latestRows.first { $0.id == task.id })
            let refreshed = try XCTUnwrap(SyncConflict(mutation: rebased, remote: latest).resolving(saved, keepLocal: true))
            try await a.send(try XCTUnwrap(refreshed.pending.first))
            let finalRows = try await b.rows("tasks")
            let final = try XCTUnwrap(finalRows.first { $0.id == task.id })
            XCTAssertEqual(final.title, "My chosen title"); XCTAssertEqual(final["deadline_date"], .string("2026-10-25"))
            XCTAssertEqual(Set(final["comments"].list.map { $0.object["id"]?.text ?? "" }), ["a", "b"])
        } catch { try? await a.send(deletion); throw error }
        try await a.send(deletion)
        let remaining = try await b.rows("tasks"); XCTAssertFalse(remaining.contains { $0.id == task.id })
    }
}
