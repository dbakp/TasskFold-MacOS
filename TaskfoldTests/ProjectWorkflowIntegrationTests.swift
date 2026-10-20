import XCTest
@testable import TaskfoldCore

/// Runs Mac create → iOS reuse → Mac receive against one disposable account.
/// Credentials stay in a private local file; checkpoints contain record IDs only.
final class ProjectWorkflowIntegrationTests: XCTestCase {
    @MainActor func testWorkflowCloudHandoff() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TASKFOLD_WORKFLOW_LIVE_FIXTURE"],
              let phase = environment["TASKFOLD_WORKFLOW_LIVE_PHASE"],
              ["create", "reuse", "receive"].contains(phase) else {
            throw XCTSkip("Disposable workflow fixture and handoff phase required")
        }
        let url = URL(fileURLWithPath: path)
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0o777) & 0o077, 0)
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        let owner = try XCTUnwrap(fixture["userID"]), email = try XCTUnwrap(fixture["email"])
        guard UUID(uuidString: owner) != nil, email == "taskfold-continuity-" + owner + "@example.invalid" else {
            throw AppFailure(message: "Disposable continuity account required")
        }
        let backend = Backend(configuration: ["URL": try XCTUnwrap(fixture["url"]), "Key": try XCTUnwrap(fixture["key"])],
                              http: URLSession(configuration: .ephemeral), session: nil, persistSession: { _ in })
        let signedIn = try await backend.signIn(email: email, password: try XCTUnwrap(fixture["password"]), signup: false)
        XCTAssertTrue(signedIn); XCTAssertEqual(backend.session?.user.id, owner)
        let tables = ["projects", "sections", "tasks", "labels", "view_orders", WorkflowTemplate.table]
        let checkpointURL = url.appendingPathExtension("checkpoint")
        var checkpoint = phase == "create" ? [:] : try JSONDecoder().decode([String: String].self, from: Data(contentsOf: checkpointURL))
        func fetch() async throws -> Snapshot {
            var snapshot = Snapshot()
            for table in tables { snapshot.tables[table] = try await backend.rows(table) }
            return snapshot
        }
        func upload(_ changes: [Mutation], snapshot: Snapshot) async throws -> Snapshot {
            var durable = snapshot
            for change in changes { durable.apply(change); durable.pending.append(change) }
            // Decode the queue as a restarted client would, then send in stored order.
            durable = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(durable))
            while let change = durable.pending.first {
                let saved = try await backend.send(change, expectedAccount: owner)
                durable.acknowledge(change, saved: saved)
            }
            XCTAssertTrue(durable.pending.isEmpty)
            return durable
        }
        func row(_ snapshot: Snapshot, _ table: String, _ key: String) throws -> Record {
            let id = try XCTUnwrap(checkpoint[key])
            return try XCTUnwrap(snapshot.tables[table]?.first { $0.id == id })
        }
        var snapshot = try await fetch()
        if phase == "create" {
            XCTAssertTrue(snapshot.tables.values.allSatisfy(\.isEmpty), "Use a fresh synthetic account")
            guard snapshot.tables.values.allSatisfy(\.isEmpty) else { return }
            func project(_ name: String, parent: String = "") -> Record {
                Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(owner), "name": .string(name),
                        "parent_id": parent.isEmpty ? .null : .string(parent), "is_archived": .bool(false), "order_index": .number(0)])
            }
            let root = project("Cloud workflow workshop"), child = project("Review studio", parent: root.id)
            let section = Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(owner),
                                  "project_id": .string(child.id), "name": .string("Review"), "order_index": .number(0)])
            var task = Record.task(user: owner, project: child.id)
            task["title"] = .string("Prepare the workflow brief"); task["description"] = .string("Preserve these synthetic instructions.")
            task["section_id"] = .string(section.id); task["due_date"] = .string("2026-11-04"); task["duration_minutes"] = .number(30)
            var changes = [("projects", root), ("projects", child), ("sections", section), ("tasks", task)].map {
                Mutation(table: $0.0, recordID: $0.1.id, method: "POST", fields: $0.1.fields)
            }
            snapshot = try await upload(changes, snapshot: snapshot)
            let template = try WorkflowTemplate.capture(kind: .project, id: root.id, snapshot: snapshot)
            let templateID = UUID().uuidString.lowercased()
            changes = [Mutation(table: WorkflowTemplate.table, recordID: templateID, method: "POST", fields: [
                "id": .string(templateID), "user_id": .string(owner), "name": .string("Cloud launch workflow"), "document": template.document]),
                Mutation(table: "projects", recordID: root.id, method: "PATCH", fields: ["is_archived": .bool(true)])]
            _ = try await upload(changes, snapshot: snapshot)
            checkpoint = ["root": root.id, "child": child.id, "task": task.id, "template": templateID]
        } else if phase == "reuse" {
            let root = try row(snapshot, "projects", "root"), child = try row(snapshot, "projects", "child")
            XCTAssertTrue(root["is_archived"].flag); XCTAssertTrue(child["ancestor_archived"].flag)
            XCTAssertEqual(child.string("parent_id"), root.id)
            XCTAssertTrue(ProjectOrganization.outline(snapshot.tables["projects"] ?? []).isEmpty)
            let savedTemplate = try row(snapshot, WorkflowTemplate.table, "template")
            let template = try WorkflowTemplate(document: savedTemplate["document"])
            let changes = try template.instantiate(account: owner, name: "Reused on iOS", start: Dates.parse("2026-12-01"))
            snapshot = try await upload(changes, snapshot: snapshot)
            let newRoot = try XCTUnwrap(changes.first { $0.table == "projects" && Record($0.fields).string("parent_id").isEmpty })
            let newChild = try XCTUnwrap(changes.first { $0.table == "projects" && Record($0.fields).string("parent_id") == newRoot.recordID })
            let newTask = try XCTUnwrap(changes.first { $0.table == "tasks" })
            XCTAssertNotEqual(newTask.recordID, checkpoint["task"])
            checkpoint["copyRoot"] = newRoot.recordID; checkpoint["copyChild"] = newChild.recordID; checkpoint["copyTask"] = newTask.recordID
            let lines = try MultiLineCapture.preview("- Review handoff\n- Publish workflow p1", account: owner, project: newChild.recordID)
            let bulk = lines.map { Mutation(table: "tasks", recordID: $0.task.id, method: "POST", fields: $0.task.fields) }
            snapshot = try await upload(bulk, snapshot: snapshot)
            checkpoint["bulk0"] = bulk[0].recordID; checkpoint["bulk1"] = bulk[1].recordID
            // Replay after a lost acknowledgement must retain one task per line.
            _ = try await backend.send(bulk[0], expectedAccount: owner)
            _ = try await upload([Mutation(table: "projects", recordID: root.id, method: "PATCH", fields: ["is_archived": .bool(false)])], snapshot: snapshot)
        } else {
            let root = try row(snapshot, "projects", "root"), child = try row(snapshot, "projects", "child")
            XCTAssertFalse(root["is_archived"].flag); XCTAssertFalse(child["ancestor_archived"].flag)
            let original = try row(snapshot, "tasks", "task"), copy = try row(snapshot, "tasks", "copyTask")
            XCTAssertEqual(original.string("due_date"), "2026-11-04"); XCTAssertFalse(original.completed)
            XCTAssertEqual(copy.string("due_date"), "2026-12-01"); XCTAssertFalse(copy.completed)
            XCTAssertEqual(copy.string("description"), original.string("description")); XCTAssertEqual(copy["duration_minutes"], .number(30))
            XCTAssertEqual(copy.string("project_id"), checkpoint["copyChild"])
            XCTAssertEqual(try row(snapshot, "projects", "copyChild").string("parent_id"), checkpoint["copyRoot"])
            XCTAssertEqual(try row(snapshot, "projects", "copyRoot").name, "Reused on iOS")
            XCTAssertEqual(try row(snapshot, "tasks", "bulk0").title, "Review handoff")
            XCTAssertEqual(try row(snapshot, "tasks", "bulk1").title, "Publish workflow")
            XCTAssertEqual(snapshot.tables["tasks"]?.count, 4); XCTAssertEqual(snapshot.tables["projects"]?.count, 4)
            XCTAssertEqual(snapshot.tables["sections"]?.count, 2); XCTAssertEqual(snapshot.tables[WorkflowTemplate.table]?.count, 1)
            XCTAssertEqual(ProjectOrganization.outline(snapshot.tables["projects"] ?? []).count, 4)
            _ = try WorkflowTemplate(document: row(snapshot, WorkflowTemplate.table, "template")["document"])
        }
        try JSONEncoder().encode(checkpoint).write(to: checkpointURL, options: .atomic)
    }
}
