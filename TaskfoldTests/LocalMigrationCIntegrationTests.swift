import XCTest
@testable import TaskfoldCore

/// Runs only against a LOCAL Supabase stack whose schema includes Migration C (`supabase db reset`), never hosted.
/// `TASKFOLD_LOCAL_C_FIXTURE` names a JSON file written by the operator script: the local API URL and anon key, a
/// disposable password, an owner who manages a synthetic team project, and that project's ids.
/// It proves the app's own writers work once `tasks.subtasks` is gone: task insert, patch and delete, child rows,
/// a team lifecycle create with a child, a team edit of `child_order`, and restoring an older backup whose
/// subtasks are JSON.
final class LocalMigrationCIntegrationTests: XCTestCase {
    struct Fixture: Decodable { let url: String; let anonKey: String; let password: String; let owner: String; let email: String; let team: String; let teamProject: String; let origin: String }

    @MainActor func testAppWritersAgainstMigrationC() async throws {
        guard let path = ProcessInfo.processInfo.environment["TASKFOLD_LOCAL_C_FIXTURE"] else { throw XCTSkip("Local Supabase stack with Migration C required") }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard let host = URL(string: fixture.url)?.host, ["127.0.0.1", "localhost"].contains(host) else { throw AppFailure(message: "This test only runs against a local stack") }
        // Backend only speaks https: a test-only protocol forwards https://local.taskfold.test to the local http API.
        LocalForwarding.target = fixture.url
        let transport = URLSessionConfiguration.ephemeral; transport.protocolClasses = [LocalForwarding.self]
        let backend = Backend(configuration: ["URL": "https://" + LocalForwarding.host, "Key": fixture.anonKey], http: URLSession(configuration: transport), session: nil, persistSession: { _ in })
        let signedIn = try await backend.signIn(email: fixture.email, password: fixture.password, signup: false)
        XCTAssertTrue(signedIn); XCTAssertEqual(backend.session?.user.id, fixture.owner)
        let owner = fixture.owner

        // The column really is gone.
        let probe = try? await backend.request("/rest/v1/tasks?select=subtasks&limit=1")
        XCTAssertNil(probe, "Migration C must have dropped tasks.subtasks")

        // Personal: insert a root (Record.task carries no `subtasks`) and a child row.
        var root = Record.task(user: owner, date: Date()); root["title"] = .string("Local C root")
        XCTAssertNil(root.fields["subtasks"])
        let rootReply = try await backend.send(Mutation(table: "tasks", recordID: root.id, method: "POST", fields: root.fields, insertOnly: true))
        let savedRoot = try XCTUnwrap(rootReply)
        XCTAssertNil(savedRoot.fields["subtasks"])
        var child = Record.task(user: owner); child["title"] = .string("Local C child")
        child["parent_id"] = .string(root.id); child["child_order"] = .number(1)
        let childReply = try await backend.send(Mutation(table: "tasks", recordID: child.id, method: "POST", fields: child.fields, insertOnly: true))
        let savedChild = try XCTUnwrap(childReply)
        XCTAssertEqual(savedChild["parent_id"], .string(root.id))

        // Patch through taskfold_patch_task, including a change queued before C that still carries an empty `subtasks`.
        let titleFields: [String: JSON] = ["title": .string("Local C root, renamed"), "subtasks": .array([])]
        var queued = Mutation(table: "tasks", recordID: root.id, method: "PATCH", fields: titleFields, baseline: TaskCompletionRevision.editBaseline(for: titleFields, from: savedRoot))
        queued.baseline?["subtasks"] = .array([])
        let patchReply = try await backend.send(queued)
        let patched = try XCTUnwrap(patchReply)
        XCTAssertEqual(patched.title, "Local C root, renamed")
        let detach: [String: JSON] = ["parent_id": .null, "child_order": .null]
        let detachReply = try await backend.send(Mutation(table: "tasks", recordID: child.id, method: "PATCH", fields: detach, baseline: TaskCompletionRevision.editBaseline(for: detach, from: savedChild)))
        let detached = try XCTUnwrap(detachReply)
        XCTAssertEqual(detached["parent_id"], .null)

        // Delete through taskfold_delete_task with full baselines (an old cached row may still hold an empty `subtasks`).
        var cachedChild = detached.fields; cachedChild["subtasks"] = .array([])
        _ = try await backend.send(Mutation(table: "tasks", recordID: child.id, method: "DELETE", fields: [:], baseline: cachedChild))
        _ = try await backend.send(Mutation(table: "tasks", recordID: root.id, method: "DELETE", fields: [:], baseline: patched.fields))
        let gone = try await backend.request("/rest/v1/tasks?id=in.(\(root.id),\(child.id))&select=id")
        let remaining = try TaskfoldJSONDecoder().decode([Record].self, from: gone)
        XCTAssertEqual(remaining.count, 0)

        // Team: lifecycle create of a parent and a child row, then a saved team edit of child_order (bodies built by the app).
        let scope = TeamTaskEditScope(account: owner, origin: try backend.accountRemovalOrigin, team: fixture.team, project: fixture.teamProject)
        func lifecycle(_ record: Record) async throws -> [String: JSON] {
            let change = Mutation(table: "tasks", recordID: record.id, method: "POST", fields: record.fields, insertOnly: true, teamTaskScope: scope)
            let body = try scope.lifecycleBody(for: change)
            XCTAssertNil(body["record"]?.object["subtasks"])
            let data = try await backend.request("/rest/v1/rpc/taskfold_team_task_lifecycle", method: "POST", body: ["_action": .string("create"), "_body": .object(body)])
            let reply = try TaskfoldJSONDecoder().decode([String: JSON].self, from: data)
            _ = try scope.lifecycleSaved(reply, for: change)
            return reply
        }
        var parent = Record.task(user: owner, project: fixture.teamProject); parent["title"] = .string("Team parent")
        _ = try await lifecycle(parent)
        var teamChild = Record.task(user: owner, project: fixture.teamProject); teamChild["title"] = .string("Team child")
        teamChild["parent_id"] = .string(parent.id); teamChild["child_order"] = .number(1)
        let created = try await lifecycle(teamChild)
        XCTAssertEqual(created["task"]?.object["parent_id"], .string(parent.id))
        let rows = try TaskfoldJSONDecoder().decode([Record].self, from: try await backend.request("/rest/v1/tasks?id=eq.\(teamChild.id)&select=*"))
        let liveChild = try XCTUnwrap(rows.first)
        XCTAssertNil(liveChild.fields["subtasks"]); XCTAssertEqual(liveChild["parent_id"], .string(parent.id))
        let reorder: [String: JSON] = ["child_order": .number(5)]
        var edit = Mutation(table: "tasks", recordID: teamChild.id, method: "PATCH", fields: reorder, baseline: TaskCompletionRevision.editBaseline(for: reorder, from: LegacySubtaskColumn.dropped(liveChild)), teamTaskScope: scope)
        edit = try scope.capturing(edit, existing: liveChild)
        let editData = try await backend.request("/rest/v1/rpc/taskfold_edit_team_task", method: "POST", body: ["_body": .object(try scope.body(for: edit))])
        let edited = try scope.saved(try TaskfoldJSONDecoder().decode([String: JSON].self, from: editData), for: edit)
        XCTAssertEqual(edited["child_order"], .number(5))

        // Backup restore: an older (v2-shaped) backup with a JSON subtask tree becomes rows; nothing sends `subtasks`.
        var legacy = Record.task(user: owner); legacy["id"] = .string(UUID().uuidString.lowercased()); legacy["title"] = .string("Restored parent")
        legacy["subtasks"] = .array([.object(["id": .string("a"), "title": .string("Restored child"), "completed": .bool(false),
                                              "subtasks": .array([.object(["id": .string("b"), "title": .string("Restored grandchild")])])])])
        let backup = WorkspaceBackup.make(Snapshot(tables: ["tasks": [legacy]]), account: owner)
        let plan = try WorkspaceBackup.read(backup.data()).plan(current: Snapshot(), account: owner)
        XCTAssertTrue(plan.changes.allSatisfy { $0.fields["subtasks"] == nil })
        for change in plan.changes { _ = try await backend.send(change) }
        let restoredIDs = plan.changes.filter { $0.table == "tasks" }.map(\.recordID)
        XCTAssertEqual(restoredIDs.count, 3)
        let restored = try TaskfoldJSONDecoder().decode([Record].self, from: try await backend.request("/rest/v1/tasks?id=in.(\(restoredIDs.joined(separator: ",")))&select=*"))
        XCTAssertEqual(restored.count, 3)
        XCTAssertEqual(restored.filter { !$0.string("parent_id").isEmpty }.count, 2)
        let restoredRoot = try XCTUnwrap(restored.first { $0.title == "Restored parent" })
        XCTAssertEqual(restored.first { $0.title == "Restored child" }?["parent_id"], .string(restoredRoot.id))
    }
}

/// Forwards the test's https requests to the local stack's http API (local only; any other host is refused).
private final class LocalForwarding: URLProtocol, @unchecked Sendable {
    static let host = "local.taskfold.test"
    nonisolated(unsafe) static var target = ""
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard var parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false), let local = URLComponents(string: Self.target),
              ["127.0.0.1", "localhost"].contains(local.host ?? "") else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        parts.scheme = local.scheme; parts.host = local.host; parts.port = local.port
        var forwarded = request; forwarded.url = parts.url
        if forwarded.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
            forwarded.httpBody = data
        }
        URLSession(configuration: .ephemeral).dataTask(with: forwarded) { [weak self] data, response, error in
            guard let self else { return }
            if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
            if let http = response as? HTTPURLResponse, let url = self.request.url,
               let mirrored = HTTPURLResponse(url: url, statusCode: http.statusCode, httpVersion: nil, headerFields: http.allHeaderFields as? [String: String]) {
                self.client?.urlProtocol(self, didReceive: mirrored, cacheStoragePolicy: .notAllowed)
            }
            if let data { self.client?.urlProtocol(self, didLoad: data) }
            self.client?.urlProtocolDidFinishLoading(self)
        }.resume()
    }
    override func stopLoading() {}
}
