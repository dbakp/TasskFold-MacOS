import XCTest
@testable import TaskfoldCore

final class SubtaskTransportIntegrationTests: XCTestCase {
    @MainActor func testMovedChildAndReviewedOrderKeepSecondClientWork() async throws {
        guard let path = ProcessInfo.processInfo.environment["TASKFOLD_SUBTASK_LIVE_FIXTURE"] else { throw XCTSkip("Disposable subtask fixture required") }
        let f = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let owner = try XCTUnwrap(f["userID"]), email = try XCTUnwrap(f["email"])
        guard UUID(uuidString: owner) != nil, email == "taskfold-continuity-" + owner + "@example.invalid" else { throw SubtaskTree.Failure(message: "Synthetic account required") }
        let config = ["URL": try XCTUnwrap(f["url"]), "Key": try XCTUnwrap(f["key"])]
        func client() -> Backend { Backend(configuration: config, http: URLSession(configuration: .ephemeral), session: nil, persistSession: { _ in }) }
        let a = client(), b = client()
        let first = try await a.signIn(email: email, password: try XCTUnwrap(f["password"]), signup: false)
        let second = try await b.signIn(email: email, password: try XCTUnwrap(f["password"]), signup: false)
        XCTAssertTrue(first && second); XCTAssertEqual(a.session?.user.id, owner); XCTAssertEqual(b.session?.user.id, owner)
        func child(_ id: String, _ children: [JSON] = []) -> JSON {
            .object(["id": .string(id), "title": .string(id), "completed": .bool(false), "description": .string("Original notes"), "subtasks": .array(children)])
        }
        var draft = Record.task(user: owner); draft["title"] = .string("Synthetic P1 subtask transport")
        draft["subtasks"] = .array([child("a",[child("b",[child("leaf")])]),child("c")])
        let inserted = try await a.send(Mutation(table: "tasks", recordID: draft.id, method: "POST", fields: draft.fields, insertOnly: true))
        let original = try XCTUnwrap(inserted)
        func current(_ backend: Backend) async throws -> Record {
            let rows = try await backend.rows("tasks")
            return try XCTUnwrap(rows.first { $0.id == original.id })
        }
        func change(_ value: JSON, from task: Record) -> Mutation {
            Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: ["subtasks": value], baseline: ["subtasks": task["subtasks"], "task_generation": task["task_generation"]])
        }
        func reviewAndSend(_ mutation: Mutation) async throws -> Record {
            let previous = try await current(b)
            do {
                let acknowledgement = try await a.send(mutation)
                let expected = SubtaskTree.rebased(base: mutation.baseline!["subtasks"]!, desired: mutation.fields["subtasks"]!, remote: previous["subtasks"])
                XCTAssertEqual(acknowledgement?["subtasks"], expected, "An acknowledged hierarchy edit must not lose its order or remote fields")
                XCTFail("Concurrent hierarchy changes must require review")
            }
            catch { XCTAssertTrue(error.localizedDescription.contains("TASKFOLD_CONFLICT:")) }
            let remote = try await current(b)
            var queue = Snapshot(); queue.tables["tasks"] = [remote]; queue.pending = [mutation]
            let reviewed = try XCTUnwrap(SyncConflict(mutation: mutation, remote: remote).resolving(queue, keepLocal: true))
            let durable = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(reviewed))
            let pending = try XCTUnwrap(durable.pending.first)
            _ = try await a.send(pending); _ = try await a.send(pending)
            return try await current(b)
        }
        func cleanup() async throws {
            let task = try await current(a)
            _ = try await a.send(Mutation(table: "tasks", recordID: task.id, method: "DELETE", fields: [:], baseline: task.fields))
        }
        do {
            let moved = try SubtaskTree.moving(original["subtasks"], id: "b", direction: .outdent)
            let remote = SubtaskTree.changing(original["subtasks"], id: "b", fields: ["description": .string("Second client notes")])
            _ = try await b.send(change(remote, from: original))
            let saved = try await reviewAndSend(change(moved, from: original))
            let items = SubtaskTree.outline(saved["subtasks"])
            XCTAssertEqual(items.map(\.id), ["a","b","leaf","c"])
            XCTAssertEqual(items.map(\.depth), [0,0,1,0])
            XCTAssertEqual(items.first { $0.id == "b" }?.record.string("description"), "Second client notes")
            let ordered = try SubtaskTree.moving(saved["subtasks"], id: "b", direction: .up)
            var appended = saved["subtasks"].list; appended.append(child("remote addition"))
            _ = try await b.send(change(.array(appended), from: saved))
            let final = try await reviewAndSend(change(ordered, from: saved))
            XCTAssertEqual(SubtaskTree.outline(final["subtasks"]).map(\.id), ["b","leaf","a","c","remote addition"])
            XCTAssertEqual(SubtaskTree.outline(final["subtasks"]).first { $0.id == "b" }?.record.string("description"), "Second client notes")
            try await cleanup()
        } catch { try? await cleanup(); throw error }
    }
}
