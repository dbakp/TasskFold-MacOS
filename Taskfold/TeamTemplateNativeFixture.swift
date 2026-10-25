#if DEBUG
import Foundation

/// Exact disposable namespace and explicit flag only. No request leaves this
/// local URLProtocol peer; it is native client acceptance, not service acceptance.
@MainActor enum TeamTemplateNativeFixture {
    static var enabled: Bool { TeamEditorNativeFixture.enabled && ProcessInfo.processInfo.arguments.contains("--team-library-testing") }
    static let definitionID = "ec240000-0000-4000-8000-000000000061"
    static let futureID = "ec240000-0000-4000-8000-000000000062"
    static let personalID = "ec240000-0000-4000-8000-000000000063"
    static var root: URL { URL.applicationSupportDirectory.appendingPathComponent("TaskfoldTeamLibraryNativeFixture-workflowteststeameditbridge", isDirectory: true) }
    static var file: URL { root.appendingPathComponent("state.json") }
    struct State: Codable {
        var items: [[String: JSON]] = []
        var receipts: [String: [String: JSON]] = [:]
        var requests: [String: [String: JSON]] = [:]
        var revision = 1
        var getReads = 0
        var unavailable = false
        var loseNext = false
        var workflowReceipts: [String: [String: JSON]] = [:]
        var workflowRequests: [String: [String: JSON]] = [:]
        var workflowOrders: [String: [String]] = [:]
        var workflowCalls = 0
        var loseNextWorkflow = false
    }
    static func document(title: String = "Review the launch") -> JSON {
        .object(["version": .number(1), "kind": .string("task"), "projects": .array([]), "sections": .array([]), "tasks": .array([.object(["id": .string("review"), "title": .string(title), "description": .string("Compare the full layout, confirm readable labels, and record the release decision."), "priority": .number(2), "duration_minutes": .number(25), "planned_offset": .number(1), "labels": .array([.object(["name": .string("Design"), "color": .string("#7455b3")])]), "subtasks": .array([])])])])
    }
    static var personal: Record { Record(["id": .string(personalID), "user_id": .string(TeamEditorNativeFixture.account), "name": .string("Release routine"), "document": document(title: "Check release notes")]) }
    static func item(_ id: String, name: String, document: JSON) -> [String: JSON] {
        ["id": .string(id), "name": .string(name), "document": document, "revision": .number(1), "created_at": .string("2026-10-25T10:00:00Z"), "updated_at": .string("2026-10-25T10:00:00Z")]
    }
    static func save(_ state: State) throws { guard enabled else { throw CancellationError() }; try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try JSONEncoder().encode(state).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    static func load() throws -> State { guard enabled else { throw CancellationError() }; return try JSONDecoder().decode(State.self, from: Data(contentsOf: file)) }
    static func reset() throws {
        var initial = State(items: [item(definitionID, name: "Design review kit", document: document()), item(futureID, name: "Future workflow", document: .object(["version": .number(2), "future": .string("Preserve these instructions")]))], loseNext: ProcessInfo.processInfo.arguments.contains("--team-library-lose-reply"))
        initial.loseNextWorkflow = ProcessInfo.processInfo.arguments.contains("--workflow-run-lose-reply")
        try save(initial)
    }
    static func backend() -> Backend {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [TeamTemplateNativeHTTP.self]
        let session = try! JSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(TeamEditorNativeFixture.account)\"}}".utf8))
        return Backend(configuration: ["URL": "https://synthetic.example", "Key": "synthetic-public"], http: URLSession(configuration: configuration), session: session, persistSession: { _ in })
    }
    static func read(_ request: URLRequest) throws -> JSON {
        guard enabled, request.httpMethod == "GET", request.url?.scheme == "https", request.url?.host == "synthetic.example" else { throw URLError(.notConnectedToInternet) }
        let state = try load(); guard !state.unavailable else { throw URLError(.userAuthenticationRequired) }
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        guard values["user_id"] == "eq." + TeamEditorNativeFixture.account else { throw URLError(.badServerResponse) }
        if request.url?.path == "/rest/v1/project_templates" {
            guard values["id"] == "eq." + personalID else { return .array([]) }; return .array([.object(personal.fields)])
        }
        if request.url?.path == "/rest/v1/view_orders" {
            let filter = values["id"] ?? ""
            return .array(state.workflowOrders.keys.sorted().filter { filter.contains("\"" + $0 + "\"") }.map { .object(["id": .string($0), "user_id": .string(TeamEditorNativeFixture.account), "ids": .array(state.workflowOrders[$0]!.map(JSON.string))]) })
        }
        throw URLError(.notConnectedToInternet)
    }
    static func handle(_ request: URLRequest, data: Data) throws -> (raw: [String: JSON], status: Int, lose: Bool) {
        guard enabled, request.url?.scheme == "https", request.url?.host == "synthetic.example", request.httpMethod == "POST" else { throw URLError(.notConnectedToInternet) }
        let path = request.url!.path, params = try JSONDecoder().decode([String: JSON].self, from: data)
        var state = try load()
        if path == "/rest/v1/rpc/taskfold_workspace_boundary" { return (try TeamEditorNativeFixture.boundary(viewer: state.unavailable).raw, 200, false) }
        if path == "/rest/v1/rpc/taskfold_teams", ["list", "invitations"].contains(params["_action"]?.text ?? "") {
            guard !state.unavailable else { return (["code": .string("PT404")], 403, false) }
            if params["_action"] == .string("invitations") { return (["enabled": .bool(true), "invitations": .array([])], 200, false) }
            return (["enabled": .bool(true), "teams": .array([.object(["id": .string(TeamEditorNativeFixture.teamID), "name": .string("Widget Studio"), "role": .string("owner"), "state": .string("active"), "revision": .number(1)])])], 200, false)
        }
        guard params["_body"]?.object["team_id"] == .string(TeamEditorNativeFixture.teamID) else { throw URLError(.badServerResponse) }
        if state.unavailable { return (["code": .string("PT404"), "message": .string("Synthetic access withdrawn")], 403, false) }
        if path == "/rest/v1/rpc/taskfold_teams", params["_action"] == .string("get") {
            return (["id": .string(TeamEditorNativeFixture.teamID), "name": .string("Widget Studio"), "role": .string("owner"), "state": .string("active"), "revision": .number(1), "folders": .array([]), "members": .array([.object(["user_id": .string(TeamEditorNativeFixture.account), "role": .string("owner")])]), "invitations": .array([])], 200, false)
        }
        if path == "/rest/v1/rpc/taskfold_team_projects" {
            var project: [String: JSON] = ["id": .string(TeamEditorNativeFixture.projectID), "name": .string("Design board"), "team_id": .string(TeamEditorNativeFixture.teamID), "revision": .number(1), "role": .string("editor"), "visibility": .string("team"), "folder_id": .null, "can_edit_tasks": .bool(false), "can_manage_access": .bool(false), "project_state_protocol": .number(1), "is_archived": .bool(false), "ancestor_archived": .bool(false), "project_hierarchy_protocol": .number(1), "parent_id": .null, "parent_unavailable": .bool(false)]
            let context: [String: JSON] = ["protocol": .number(1), "account": .string(TeamEditorNativeFixture.account), "team_id": .string(TeamEditorNativeFixture.teamID), "team_revision": .number(1), "team_state": .string("active"), "setup_paused": .bool(false)]
            if params["_action"] == .string("get") { project.merge(context) { _, new in new }; return (project, 200, false) }
            var result = context; result["task_writes_enabled"] = .bool(false); result["projects"] = .array([.object(project)]); result["next_cursor"] = .null; return (result, 200, false)
        }
        if path == "/rest/v1/rpc/taskfold_team_workflow_run" {
            let body = params["_body"]!.object
            let command = try TeamWorkflowRunCommand(account: TeamEditorNativeFixture.account, origin: "https://synthetic.example", body: body)
            state.workflowCalls += 1; try save(state)
            if var receipt = state.workflowReceipts[command.id] {
                guard state.workflowRequests[command.id] == params else { return (["code": .string("PT409")], 409, false) }
                receipt["replayed"] = .bool(true); try save(state); return (receipt, 200, false)
            }
            let source = body["source"]!.object
            if source["kind"] == .string("shared") {
                guard let item = state.items.first(where: { $0["id"] == source["id"] }), item["document"] == source["document"], item["revision"] == source["revision"] else { return (["code": .string("PT409")], 409, false) }
            } else { guard source["document"] == personal["document"] else { return (["code": .string("PT409")], 409, false) } }
            for value in body["orders"]!.list {
                let row = value.object, key = "group:" + row["project_id"]!.text + ":" + (row["section_id"] == .null ? "none" : row["section_id"]!.text)
                guard row["base_ids"] == .array((state.workflowOrders[key] ?? []).map(JSON.string)) else { return (["code": .string("PT409")], 409, false) }
                state.workflowOrders[key] = (state.workflowOrders[key] ?? []) + row["task_ids"]!.list.map(\.text)
            }
            let raw: [String: JSON] = ["run_protocol": .number(1), "account": .string(command.account), "team_id": .string(command.team), "request_id": .string(command.id), "projects": .array(body["projects"]!.list.map { $0.object["id"]! }), "sections": .array(body["sections"]!.list.map { $0.object["id"]! }), "tasks": .array(body["tasks"]!.list.map { .object(["id": $0.object["id"]!, "generation": $0.object["task_generation"]!, "project_id": $0.object["project_id"]!]) }), "replayed": .bool(false)]
            state.workflowRequests[command.id] = params; state.workflowReceipts[command.id] = raw
            let lose = state.loseNextWorkflow; state.loseNextWorkflow = false; try save(state); return (raw, 200, lose)
        }
        guard path == "/rest/v1/rpc/taskfold_team_templates", let operation = params["_operation"]?.text else { throw URLError(.notConnectedToInternet) }
        let body = params["_body"]!.object
        var raw: [String: JSON] = ["library_protocol": .number(1), "account": .string(TeamEditorNativeFixture.account), "team_id": .string(TeamEditorNativeFixture.teamID), "team_state": .string("active"), "role": .string("owner"), "can_manage": .bool(true)]
        switch operation {
        case "list":
            raw["library_revision"] = .number(Double(state.revision)); raw["items"] = .array(state.items.sorted { $0["id"]!.text < $1["id"]!.text }.map { var item = $0; item.removeValue(forKey: "document"); return .object(item) }); raw["next_cursor"] = .null
        case "get":
            guard let item = state.items.first(where: { $0["id"] == body["template_id"] }) else { return (["code": .string("PT404")], 404, false) }
            raw["item"] = .object(item); state.getReads += 1; try save(state)
        case "publish", "replace", "delete":
            let action = TeamTemplateCommand.Action(rawValue: operation)!
            let command = try TeamTemplateCommand(account: TeamEditorNativeFixture.account, origin: "https://synthetic.example", action: action, body: body)
            if var receipt = state.receipts[command.id] {
                guard state.requests[command.id] == params else { return (["code": .string("PT409")], 409, false) }
                receipt["replayed"] = .bool(true); return (receipt, 200, false)
            }
            let index = state.items.firstIndex { $0["id"] == body["template_id"] }
            let revision: Double
            if action == .publish { guard index == nil else { return (["code": .string("PT409")], 409, false) }; revision = 1 }
            else { guard let index, state.items[index]["revision"] == body["revision"] else { return (["code": .string("PT409")], 409, false) }; revision = try TeamTemplateLibraryValue.revision(body["revision"]) + (action == .replace ? 1 : 0) }
            if action == .delete { state.items.remove(at: index!) }
            else { var item = self.item(command.template, name: body["name"]!.text, document: body["document"]!); item["revision"] = .number(revision); if let index { state.items[index] = item } else { state.items.append(item) } }
            raw = ["library_protocol": .number(1), "account": .string(command.account), "team_id": .string(command.team), "request_id": .string(command.id), "template_id": .string(command.template), "operation": .string(operation), "revision": .number(revision), "deleted": .bool(action == .delete), "replayed": .bool(false)]
            state.receipts[command.id] = raw; state.requests[command.id] = params; state.revision += 1
            let lose = state.loseNext; state.loseNext = false; try save(state); return (raw, 200, lose)
        default: throw URLError(.notConnectedToInternet)
        }
        return (raw, 200, false)
    }
}
private final class TeamTemplateNativeHTTP: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = self.request
        Task { @MainActor in
            do {
                if request.httpMethod == "GET" {
                    let value = try TeamTemplateNativeFixture.read(request)
                    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: try JSONEncoder().encode(value)); client?.urlProtocolDidFinishLoading(self); return
                }
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable, data.count <= 4_300_000 { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) } }
                guard data.count <= 4_300_000 else { throw URLError(.dataLengthExceedsMaximum) }
                let reply = try TeamTemplateNativeFixture.handle(request, data: data)
                guard !reply.lose else { throw URLError(.networkConnectionLost) }
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: try JSONEncoder().encode(reply.raw)); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
}
#endif
#if DEBUG
@MainActor extension Store {
    func changeTeamTemplatePrivateSourceFixture() {
        guard TeamTemplateNativeFixture.enabled, var row = record(WorkflowTemplate.table, id: TeamTemplateNativeFixture.personalID) else { return }
        row["document"] = TeamTemplateNativeFixture.document(title: "Changed private release notes")
        _ = save(WorkflowTemplate.table, row)
    }
    func changeTeamTemplateSharedSourceFixture() {
        guard TeamTemplateNativeFixture.enabled else { return }
        do {
            var state = try TeamTemplateNativeFixture.load()
            guard let i = state.items.firstIndex(where: { $0["id"] == .string(TeamTemplateNativeFixture.definitionID) }) else { return }
            state.items[i]["document"] = TeamTemplateNativeFixture.document(title: "Changed shared review")
            state.items[i]["revision"] = .number(try TeamTemplateLibraryValue.revision(state.items[i]["revision"]) + 1)
            state.revision += 1; try TeamTemplateNativeFixture.save(state)
        } catch { self.error = error.localizedDescription }
    }
    func withdrawTeamTemplateAccessFixture() {
        guard TeamTemplateNativeFixture.enabled else { return }
        do { var state = try TeamTemplateNativeFixture.load(); state.unavailable = true; try TeamTemplateNativeFixture.save(state); revokeTeamEditorNativeFixture() }
        catch { self.error = error.localizedDescription }
    }
}
#endif
