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
        var document: JSON = .object(["version": .number(1), "kind": .string("task"), "projects": .array([]), "sections": .array([]), "tasks": .array([.object(["id": .string("review"), "title": .string(title), "description": .string("Compare the full layout, confirm readable labels, and record the release decision."), "priority": .number(2), "duration_minutes": .number(25), "planned_offset": .number(1), "labels": .array([.object(["name": .string("Design"), "color": .string("#7455b3")])]), "subtasks": .array([])])])])
        if ProcessInfo.processInfo.arguments.contains("--workflow-heading-testing") {
            var root = document.object; root["version"] = .number(2); root["capabilities"] = .array([.string("task_headings")])
            var task = root["tasks"]!.list[0].object; task["is_heading"] = .bool(true)
            task["subtasks"] = .array([.object(["id": .string("phase"), "title": .string("Research phase"), "is_heading": .bool(true), "labels": .array([]), "subtasks": .array([.object(["id": .string("work"), "title": .string("Approve the design"), "labels": .array([]), "subtasks": .array([])])])])])
            root["tasks"] = .array([.object(task)]); document = .object(root)
        }
        return document
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
            var raw: [String: JSON] = ["run_protocol": .number(1), "account": .string(command.account), "team_id": .string(command.team), "request_id": .string(command.id), "projects": .array(body["projects"]!.list.map { $0.object["id"]! }), "sections": .array(body["sections"]!.list.map { $0.object["id"]! }), "tasks": .array(body["tasks"]!.list.map { .object(["id": $0.object["id"]!, "generation": $0.object["task_generation"]!, "project_id": $0.object["project_id"]!]) }), "replayed": .bool(false)]
            if body["workflow_types_protocol"] != nil { raw["workflow_types_protocol"] = .number(1) }
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
            if body["workflow_types_protocol"] != nil { raw["workflow_types_protocol"] = .number(1) }
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

#if DEBUG
/// Reserved-host personal transport peer. Real SQL contract acceptance is separate.
@MainActor enum PersonalHeadingNativePeer {
    static var enabled: Bool { TeamEditorNativeFixture.enabled && ProcessInfo.processInfo.arguments.contains("--personal-heading-testing") }
    static var file: URL { URL.applicationSupportDirectory.appendingPathComponent("TaskfoldPersonalHeadingNativeFixture-workflowteststeameditbridge.json") }
    struct State: Codable {
        var row: Record
        var support = 1
        var attempts: [[String: JSON]] = []
        var transitions = 0
        var loseNext = false
    }
    static func read() throws -> State { try JSONDecoder().decode(State.self, from: Data(contentsOf: file)) }
    static func write(_ value: State) throws { try JSONEncoder().encode(value).write(to: file, options: .atomic) }
    static func reset(_ row: Record) throws {
        var state = State(row: row)
        if ProcessInfo.processInfo.arguments.contains("--personal-heading-capability-off") { state.support = 0 }
        state.loseNext = ProcessInfo.processInfo.arguments.contains("--personal-heading-lose-reply")
        try write(state)
        if WorkflowUndoNativePeer.enabled { try WorkflowUndoNativePeer.reset(row) }
    }
    static func boundary() throws -> TeamWorkspaceBoundary {
        if WorkflowUndoNativePeer.enabled { return try WorkflowUndoNativePeer.boundary() }
        let support = (try? read().support) ?? 1
        return try TeamWorkspaceBoundary(["workspace_boundary_protocol": .number(1), "account": .string(TeamEditorNativeFixture.account),
            "native_team_reads_enabled": .bool(false), "setup_paused": .bool(true), "task_types_protocol": .number(0), "task_type_lifecycle_protocol": .number(0),
            "personal_task_types_protocol": .number(Double(support)), "projects": .array([]), "teams": .array([]), "token": .string(String(repeating: support == 1 ? "a" : "b", count: 64))],
            account: TeamEditorNativeFixture.account, origin: "https://synthetic.example")
    }
    static func body(_ request: URLRequest) throws -> [String: JSON] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096), result = Data()
            while stream.hasBytesAvailable && result.count < 2_100_000 {
                let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; result.append(contentsOf: bytes.prefix(count))
            }; data = result
        }
        return try JSONDecoder().decode([String: JSON].self, from: data ?? Data("{}".utf8))
    }
    static func response(_ request: URLRequest) throws -> (Data, Bool) {
        guard enabled, request.url?.host == "synthetic.example", request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-auth" else { throw URLError(.userAuthenticationRequired) }
        if let response = try WorkflowUndoNativePeer.response(request) { return response }
        let path = request.url!.path
        let value: JSON
        if path == "/rest/v1/rpc/taskfold_workspace_boundary" { value = .object(try boundary().raw) }
        else if path == "/auth/v1/user" { value = .object(["id": .string(TeamEditorNativeFixture.account), "email": .string("personal-heading@example.invalid")]) }
        else if path == "/rest/v1/rpc/taskfold_patch_task" {
            let request = try body(request); var state = try read()
            state.attempts.append(request)
            let fields = request["_changes"]!.object, base = request["_base"]!.object
            let change = Mutation(table: "tasks", recordID: state.row.id, method: "PATCH", fields: fields, baseline: base)
            guard (!PersonalTaskTypes.requiresService(change) || state.support == 1), request["_id"] == state.row["id"], base["task_generation"] == state.row["task_generation"] else { try write(state); throw URLError(.badServerResponse) }
            let replay = fields.allSatisfy { state.row[$0.key] == $0.value }
            if !replay {
                guard !TaskCompletionRevision.touches(fields) || base["completion_version"] == state.row["completion_version"] else { try write(state); throw URLError(.badServerResponse) }
                let before = TaskKind(state.row)
                for (key, value) in fields { state.row[key] = value }
                guard TaskKind(state.row) != .heading || !state.row.completed else { throw URLError(.badServerResponse) }
                if before != TaskKind(state.row) { state.row["completion_version"] = .number(Double(state.row["completion_version"].integer + 1)); state.transitions += 1 }
            }
            let lose = state.loseNext; state.loseNext = false
            if lose { state.support = 0 }
            try write(state)
            return (try JSONEncoder().encode(state.row), lose)
        }
        else if path == "/rest/v1/tasks" { value = .array([.object(try read().row.fields)]) }
        else { value = .array([]) }
        return (try JSONEncoder().encode(value), false)
    }
}
#endif

#if DEBUG
extension Store {
    func setPersonalHeadingSupportFixture(_ support: Int) {
        guard PersonalHeadingNativePeer.enabled, [0, 1].contains(support) else { return }
        do { var state = try PersonalHeadingNativePeer.read(); state.support = support; try PersonalHeadingNativePeer.write(state) }
        catch { self.error = error.localizedDescription }
    }
}
#endif

#if DEBUG
import SwiftUI
import CryptoKit

/// Installed client acceptance only. Exact reserved host/explicit flags are
/// required; the enclosing URLProtocol never connects to a real service.
@MainActor enum WorkflowUndoNativePeer {
    static var enabled: Bool { PersonalHeadingNativePeer.enabled && ProcessInfo.processInfo.arguments.contains("--personal-workflow-undo-testing") }
    static var file: URL { URL.applicationSupportDirectory.appendingPathComponent("TaskfoldWorkflowUndoNativeFixture-workflowteststeameditbridge.json") }
    static let templateID = "ec240000-0000-4000-8000-000000000081"
    static let incomingID = "ec240000-0000-4000-8000-000000000082"
    struct State: Codable {
        var rows: [String: [Record]]
        var support = 1
        var attempts: [[String: JSON]] = []
        var receipts: [String: Record] = [:]
        var transitions = 0
        var loseUndo = false
    }
    static var template: Record {
        let document: JSON = .object(["version": .number(2), "capabilities": .array([.string("task_headings")]), "kind": .string("project"),
            "projects": .array([.object(["id": .string("root"), "name": .string("Native workflow proof"), "parent_id": .null]), .object(["id": .string("child"), "name": .string("Delivery"), "parent_id": .string("root")])]),
            "sections": .array([.object(["id": .string("section"), "name": .string("Design"), "project_id": .string("root"), "order_index": .number(0)])]),
            "tasks": .array([
                .object(["id": .string("heading"), "is_heading": .bool(true), "title": .string("Design instructions"), "description": .string("Keep the layout readable.\nCheck contrast and spacing."), "priority": .number(4), "project_id": .string("root"), "section_id": .string("section"), "labels": .array([.object(["name": .string("Studio"), "color": .string("#7455b3")])]), "subtasks": .array([.object(["id": .string("work"), "title": .string("Approve the layout"), "priority": .number(2), "labels": .array([]), "subtasks": .array([])])])]),
                .object(["id": .string("delivery"), "title": .string("Publish the design"), "priority": .number(3), "project_id": .string("child"), "labels": .array([]), "subtasks": .array([])])])])
        return Record(["id": .string(templateID), "user_id": .string(TeamEditorNativeFixture.account), "name": .string("Native workflow proof"), "document": document])
    }
    static func read() throws -> State { try JSONDecoder().decode(State.self, from: Data(contentsOf: file)) }
    static func write(_ state: State) throws { try JSONEncoder().encode(state).write(to: file, options: .atomic) }
    static func reset(_ original: Record) throws {
        var state = State(rows: ["tasks": [original], WorkflowTemplate.table: [template]])
        state.loseUndo = ProcessInfo.processInfo.arguments.contains("--workflow-undo-lose-reply")
        try write(state)
    }
    static func boundary() throws -> TeamWorkspaceBoundary {
        let state = try read()
        let projects = (state.rows["projects"] ?? []).sorted { $0.id < $1.id }.map { row in JSON.object(["id": .string(row.id), "team_id": .null, "role": .string("owner"), "archived": .bool(false), "can_send_tasks": .bool(true)]) }
        var raw: [String: JSON] = ["workspace_boundary_protocol": .number(1), "account": .string(TeamEditorNativeFixture.account), "native_team_reads_enabled": .bool(false), "setup_paused": .bool(true), "task_types_protocol": .number(0), "task_type_lifecycle_protocol": .number(0), "personal_task_types_protocol": .number(1), "personal_workflow_undo_protocol": .number(Double(state.support)), "projects": .array(projects), "teams": .array([])]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        raw["token"] = .string(SHA256.hash(data: try encoder.encode(JSON.object(raw))).map { String(format: "%02x", $0) }.joined())
        return try TeamWorkspaceBoundary(raw, account: TeamEditorNativeFixture.account, origin: "https://synthetic.example")
    }
    static func response(_ request: URLRequest) throws -> (Data, Bool)? {
        guard enabled else { return nil }
        let path = request.url!.path
        if path == "/rest/v1/rpc/taskfold_undo_private_workflow" {
            let body = try PersonalHeadingNativePeer.body(request); var state = try read()
            guard state.support == 1, let id = body["_request"]?.text, let nonce = UUID(uuidString: id) else { throw URLError(.badServerResponse) }
            state.attempts.append(body)
            if let receipt = state.receipts[id] { try write(state); return (try JSONEncoder().encode(receipt), false) }
            // The peer models outcome/transport. Actual SQL semantics are tested
            // against PostgreSQL independently, not inferred from this helper.
            let run = UUID(), fields = body["_body"]!.object
            let command = Mutation(id: nonce, table: WorkflowUndo.table, recordID: run.uuidString.lowercased(), method: "WORKFLOW_UNDO", fields: fields, workflowRun: run)
            let items = try require(WorkflowUndo.items(command)); var snapshot = Snapshot(tables: state.rows)
            let applied: Bool
            do { try WorkflowUndo.validate(command, snapshot: snapshot, account: TeamEditorNativeFixture.account); applied = true }
            catch { applied = false }
            var current: [JSON] = []
            if applied {
                WorkflowUndo.apply(command, snapshot: &snapshot); state.rows = snapshot.tables; state.transitions += 1
            } else {
                for item in items { if let row = state.rows[item.table]?.first(where: { $0.id == item.recordID }) { current.append(.object(["table": .string(item.table), "row": .object(row.fields)])) } }
            }
            let reply = Record(["id": .string(id), "applied": .bool(applied), "rows": .array(current)])
            state.receipts[id] = reply
            let lose = state.loseUndo; state.loseUndo = false; if lose { state.support = 0 }
            try write(state); return (try JSONEncoder().encode(reply), lose)
        }
        guard path.hasPrefix("/rest/v1/") else { return nil }
        let table = String(path.dropFirst("/rest/v1/".count))
        guard ["projects", "sections", "labels", "tasks", "view_orders", WorkflowTemplate.table].contains(table) else { return nil }
        var state = try read(), rows = state.rows[table] ?? []
        if request.httpMethod == "POST" {
            let fields = try PersonalHeadingNativePeer.body(request), id = fields["id"]?.text ?? ""
            guard !id.isEmpty, fields["user_id"]?.text == TeamEditorNativeFixture.account else { throw URLError(.badServerResponse) }
            if let index = rows.firstIndex(where: { $0.id == id }) {
                if request.value(forHTTPHeaderField: "Prefer")?.contains("resolution=ignore-duplicates") == true { return (Data("[]".utf8), false) }
                rows[index] = Record(fields)
            } else { rows.append(Record(fields)) }
            state.rows[table] = rows; try write(state)
            return (try JSONEncoder().encode(rows.filter { $0.id == id }), false)
        }
        guard request.httpMethod == "GET" else { throw URLError(.unsupportedURL) }
        for query in URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            if query.name == "id", let value = query.value, value.hasPrefix("eq.") { rows = rows.filter { $0.id == String(value.dropFirst(3)) } }
            if query.name == "user_id", let value = query.value, value.hasPrefix("eq.") { rows = rows.filter { $0.string("user_id") == String(value.dropFirst(3)) } }
        }
        return (try JSONEncoder().encode(rows), false)
    }
    static func require<T>(_ value: T?) throws -> T { guard let value else { throw URLError(.badServerResponse) }; return value }
}

@MainActor struct WorkflowUndoNativeFixtureView: View {
    @Environment(Store.self) private var store
    @State private var presenting = false
    @State private var scaleOriginal: Snapshot?
    var body: some View {
        NavigationStack {
            Form {
                Text("Private workflow acceptance").font(.title2)
                if ProcessInfo.processInfo.arguments.contains("--workflow-commit-scale") {
                    Button("Measure workflow commit", action: measureCommit).accessibilityIdentifier("measureWorkflowCommit")
                    Button("Restore scale fixture", action: restoreScale).disabled(scaleOriginal == nil).accessibilityIdentifier("restoreScaleFixture")
                }
                Button("Use native workflow") { presenting = true }.accessibilityIdentifier("openNativeWorkflow")
                Button("Attempt oversized workflow") {
                    var row = Record.task(user: store.userID); row["title"] = .string("Oversized workflow proof")
                    row["description"] = .string(String(repeating: "x", count: WorkflowUndo.maximumBytes))
                    _ = store.commit([Mutation(table: "tasks", recordID: row.id, method: "POST", fields: row.fields, insertOnly: true, workflowRun: UUID())])
                }.accessibilityIdentifier("oversizedNativeWorkflow")
                Button("Fail next workflow save") { store.failNextWorkflowNativeSave() }.accessibilityIdentifier("failNativeWorkflowSave")
                Button("Undo workflow") { store.undo() }.disabled(store.undoStack.isEmpty).accessibilityIdentifier("undoNativeWorkflow")
                Button("Redo workflow") { store.redo() }.disabled(store.redoStack.isEmpty).accessibilityIdentifier("redoNativeWorkflow")
                Button("Add incoming task remotely") { update { state in
                    guard let project = state.rows["projects"]?.first else { return }
                    var row = Record.task(user: TeamEditorNativeFixture.account, project: project.id); row["id"] = .string(WorkflowUndoNativePeer.incomingID); row["title"] = .string("Later incoming work")
                    state.rows["tasks", default: []].append(row)
                } }.accessibilityIdentifier("addIncomingWorkflowTask")
                Button("Pause workflow support") { support(0) }.accessibilityIdentifier("pauseNativeWorkflowSupport")
                Button("Restore workflow support") { support(1) }.accessibilityIdentifier("restoreNativeWorkflowSupport")
                Text(store.error ?? store.notice ?? "Ready").accessibilityIdentifier("nativeWorkflowStatus")
                Text("Queued edits: \(store.snapshot.pending.count)").accessibilityIdentifier("nativeWorkflowPending")
                ForEach(store.projects) { project in Text(project.name) }
                if ProcessInfo.processInfo.arguments.contains("--workflow-commit-scale") {
                    Text("Saved tasks: \(store.tasks.count)")
                } else { ForEach(store.tasks) { task in Text(task.title) } }
            }.navigationTitle("Workflow test")
        }.sheet(isPresented: $presenting) { TemplateRunView(template: WorkflowUndoNativePeer.template) }
            .alert("Workflow needs attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("OK") { store.error = nil }
            } message: { Text(store.error ?? "") }
    }
    private func restoreScale() {
        guard WorkflowUndoNativePeer.enabled, ProcessInfo.processInfo.arguments.contains("--workflow-commit-scale"), let scaleOriginal else { return }
        store.snapshot = scaleOriginal
        do { try store.persist(); self.scaleOriginal = nil; store.error = nil }
        catch { store.error = error.localizedDescription }
    }
    private func measureCommit() {
        guard WorkflowUndoNativePeer.enabled, ProcessInfo.processInfo.arguments.contains("--workflow-commit-scale"),
              let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--workflow-commit-count=") }),
              let count = Int(argument.split(separator: "=").last ?? ""), [1000, 5000].contains(count),
              let proofArgument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--workflow-commit-proof=") }),
              let proof = UUID(uuidString: String(proofArgument.dropFirst("--workflow-commit-proof=".count))) else { return }
        do {
            let document: JSON = .object(["version": .number(1), "kind": .string("project"),
                "projects": .array([.object(["id": .string("root"), "name": .string("Scale workflow")])]),
                "sections": .array((0..<count).map { .object(["id": .string("s\($0)"), "name": .string("Section \($0)"), "project_id": .string("root"), "order_index": .number(Double($0))]) }),
                "tasks": .array((0..<count).map { .object(["id": .string("t\($0)"), "title": .string("Task \($0)"), "project_id": .string("root"), "section_id": .string("s\($0)"), "labels": .array([.object(["name": .string("Label \($0)")])]), "subtasks": .array([])]) })])
            let changes = try WorkflowTemplate(document: document).instantiate(account: store.userID, name: "Scale workflow")
            scaleOriginal = store.snapshot
            let revision = store.taskRevision, clock = ContinuousClock(), started = clock.now
            let saved = store.commit(changes), elapsed = started.duration(to: clock.now)
            let data: JSON = .object(["proof": .string(proof.uuidString.lowercased()), "count": .number(Double(count)), "commands": .number(Double(changes.count)), "saved": .bool(saved),
                "seconds": .number(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18),
                "taskRevisionDelta": .number(Double(store.taskRevision - revision)),
                "tasks": .number(Double(store.tasks.count)), "pending": .number(Double(store.snapshot.pending.count)),
                "undoCommands": .number(Double(store.undoStack.last?.undo.count ?? 0)), "error": store.error.map(JSON.string) ?? .null])
            try FileManager.default.createDirectory(at: TeamTemplateNativeFixture.root, withIntermediateDirectories: true)
            try JSONEncoder().encode(data).write(to: TeamTemplateNativeFixture.root.appendingPathComponent("commit-scale-\(proof.uuidString.lowercased()).json"), options: .atomic)
        } catch { store.error = error.localizedDescription }
    }
    private func update(_ edit: (inout WorkflowUndoNativePeer.State) -> Void) {
        do { var state = try WorkflowUndoNativePeer.read(); edit(&state); try WorkflowUndoNativePeer.write(state) } catch { store.error = error.localizedDescription }
    }
    private func support(_ value: Int) { update { $0.support = value }; Task { await store.sync() } }
}
#endif
