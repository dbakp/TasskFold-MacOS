import XCTest
@testable import TaskfoldCore

final class ConcurrentRecurrenceIntegrationTests: XCTestCase {
    /// Disposable fixture only. Native Backend requests; no GUI or Keychain access.
    @MainActor func testDifferentCompletionDaysReviewBothChoicesAndRetryWithoutExtraSuccessor() async throws {
        guard let path = ProcessInfo.processInfo.environment["TASKFOLD_CONCURRENT_RECURRENCE_FIXTURE"] else { throw XCTSkip("Disposable recurrence fixture not supplied") }
        let f = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let owner = try XCTUnwrap(f["userID"]), email = try XCTUnwrap(f["email"])
        guard UUID(uuidString: owner) != nil, email == "taskfold-continuity-" + owner + "@example.invalid" else { throw AppFailure(message: "Use a disposable continuity account") }
        let config = ["URL": try XCTUnwrap(f["url"]), "Key": try XCTUnwrap(f["key"])]
        let a = Backend(configuration: config, http: URLSession(configuration: .ephemeral), session: nil, persistSession: { _ in })
        let b = Backend(configuration: config, http: URLSession(configuration: .ephemeral), session: nil, persistSession: { _ in })
        let signedA = try await a.signIn(email: email, password: try XCTUnwrap(f["password"]), signup: false)
        let signedB = try await b.signIn(email: email, password: try XCTUnwrap(f["password"]), signup: false)
        XCTAssertTrue(signedA && signedB); XCTAssertEqual(a.session?.user.id, owner); XCTAssertEqual(b.session?.user.id, owner)
        let firstDate = ISO8601DateFormatter().date(from: "2026-10-10T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
        for keepLocal in [false, true] {
            var draft = Record.task(user: owner); draft["title"] = .string("Different-day recurrence transport fixture")
            draft["due_date"] = .string("2026-10-01"); draft["duration_minutes"] = .number(25)
            draft["is_recurring"] = .bool(true); draft["recurrence_pattern"] = .object(["type": .string("daily"), "interval": .number(1), "count": .number(3), "fromCompletion": .bool(true)])
            var owned = Set([draft.id])
            func cleanup() async throws {
                let rows = try await a.rows("tasks")
                for row in rows.filter({ owned.contains($0.id) }).sorted(by: { $0.id == draft.id ? false : $1.id == draft.id }) {
                    try await a.send(Mutation(table: "tasks", recordID: row.id, method: "DELETE", fields: [:], baseline: row.fields))
                }
            }
            do {
                let created = try await a.send(Mutation(table: "tasks", recordID: draft.id, method: "POST", fields: draft.fields, insertOnly: true))
                let original = try XCTUnwrap(created)
                let local = TaskCompletion.complete(original, tasks: [original], at: firstDate, calendar: calendar)
                let remote = TaskCompletion.complete(original, tasks: [original], at: firstDate.addingTimeInterval(86400), calendar: calendar)
                owned.formUnion([local[1].recordID, remote[1].recordID]); XCTAssertNotEqual(local[1].recordID, remote[1].recordID)
                let completed = try await b.send(remote[0]); let confirmed = try XCTUnwrap(completed)
                let repeatedCompletion = try await b.send(remote[0])
                XCTAssertEqual(repeatedCompletion?["completion_version"], confirmed["completion_version"])
                XCTAssertEqual(repeatedCompletion?["completed_at"], confirmed["completed_at"])
                let inserted = try await b.send(remote[1]); let winner = try XCTUnwrap(inserted)
                let repeatedInsert = try await b.send(remote[1]); XCTAssertEqual(repeatedInsert, winner)
                do { try await a.send(local[0]); XCTFail("A different completion timestamp must require review") }
                catch { XCTAssertTrue(error.localizedDescription.contains("TASKFOLD_CONFLICT:")) }
                var offline = Snapshot(tables: ["tasks": [original, winner]], pending: local)
                for change in local { offline.apply(change) }
                let resolved = try XCTUnwrap(SyncConflict(mutation: local[0], remote: confirmed).resolving(offline, keepLocal: keepLocal))
                let durable = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(resolved))
                XCTAssertFalse(durable.pending.contains { $0.method == "POST" })
                for change in durable.pending { try await a.send(change) }
                let retryAfterReview = try await a.send(remote[1]); XCTAssertEqual(retryAfterReview, winner)
                let rows = try await b.rows("tasks")
                let successors = rows.filter { $0.string("recurrence_parent_id") == original.id }
                XCTAssertEqual(successors, [winner]); XCTAssertFalse(rows.contains { $0.id == local[1].recordID })
                let root = try XCTUnwrap(rows.first { $0.id == original.id }); XCTAssertTrue(root.completed)
                XCTAssertEqual(TaskPlanning.instant(root.string("completed_at")), TaskPlanning.instant((keepLocal ? local[0].fields["completed_at"] : confirmed["completed_at"])!.text))
                XCTAssertEqual(winner["duration_minutes"], .number(25)); XCTAssertEqual(winner["recurrence_pattern"].object["count"], .number(2))
                try await cleanup()
                let remaining = try await a.rows("tasks"); XCTAssertFalse(remaining.contains { owned.contains($0.id) })
            } catch { try? await cleanup(); throw error }
        }
    }
}
