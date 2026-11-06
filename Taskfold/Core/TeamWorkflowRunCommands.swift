import Foundation
import Observation

struct TeamWorkflowRunCommand: ReviewedTeamCommand, ReviewedTeamFileCommand, CustomStringConvertible, CustomDebugStringConvertible {
    static let storagePrefix = "team-workflow-run-command-v1."
    static let maximumStoredBytes = 4_300_000
    static let fileName = "request.taskfoldworkflowrun"
    static let encryptionContext = "com.taskfold.shared-workflow-request.v1"
    static var invalid: AppFailure { AppFailure(message: "Review this workflow and its destination again before creating it.") }
    let account: String, origin: String
    let body: [String: JSON]
    var id: String { body["request_id"]!.text }
    var team: String { body["team_id"]!.text }
    var description: String { "Private shared workflow request" }
    var debugDescription: String { description }
    init(plan: TeamWorkflowRunPlan, baseOrders: [String: [String]]) throws {
        try self.init(account: plan.account, origin: plan.origin, body: plan.requestBody(baseOrders: baseOrders))
    }
    init(account: String, origin: String, body: [String: JSON]) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        var keys: Set<String> = ["team_id", "request_id", "team_revision", "source", "destination", "projects", "sections", "tasks", "orders"]
        if body["workflow_types_protocol"] != nil { keys.insert("workflow_types_protocol") }
        guard Set(body.keys) == keys,
              try TaskfoldJSONEncoder().encode(body).count <= 4_200_000 else { throw Self.invalid }
        _ = try TeamOrganizationValue.id(body["team_id"]); _ = try TeamOrganizationValue.id(body["request_id"])
        _ = try TeamProjectValue.revision(body["team_revision"])
        guard case .object(let source)? = body["source"], Set(source.keys) == ["kind", "id", "team_id", "revision", "document"], let document = source["document"] else { throw Self.invalid }
        _ = try TeamOrganizationValue.id(source["id"])
        let definition = try WorkflowTemplate(document: document)
        guard definition.requiresHeadingSupport ? body["workflow_types_protocol"] == .number(1) : body["workflow_types_protocol"] == nil else { throw Self.invalid }
        switch source["kind"] {
        case .string("personal"): guard source["team_id"] == .null, source["revision"] == .null else { throw Self.invalid }
        case .string("shared"): _ = try TeamOrganizationValue.id(source["team_id"]); _ = try TeamProjectValue.revision(source["revision"])
        default: throw Self.invalid
        }
        guard case .object(let target)? = body["destination"], Set(target.keys) == ["mode", "project_id", "revision", "visibility", "folder_id", "parent_id", "parent_revision"] else { throw Self.invalid }
        let creating: Bool
        switch target["mode"] {
        case .string("new"):
            creating = true
            guard definition.kind == .project, target["project_id"] == .null, target["revision"] == .null,
                  [JSON.string("team"), .string("private")].contains(target["visibility"]) else { throw Self.invalid }
            _ = try TeamProjectValue.optionalID(target["folder_id"])
            let parent = try TeamProjectValue.optionalID(target["parent_id"])
            if parent != nil { _ = try TeamProjectValue.revision(target["parent_revision"]) }
            else { guard target["parent_revision"] == .null else { throw Self.invalid } }
        case .string("project"):
            creating = false
            guard definition.kind != .project, ["visibility", "folder_id", "parent_id", "parent_revision"].allSatisfy({ target[$0] == .null }) else { throw Self.invalid }
            _ = try TeamOrganizationValue.id(target["project_id"]); _ = try TeamProjectValue.revision(target["revision"])
        default: throw Self.invalid
        }
        let projects = try TeamOrganizationValue.rows(body["projects"], limit: 1000)
        let sections = try TeamOrganizationValue.rows(body["sections"], limit: 5000)
        let tasks = try TeamOrganizationValue.rows(body["tasks"], limit: 5000)
        guard projects.count == (creating ? definition.projects.count : 0), sections.count == definition.sections.count, tasks.count == definition.tasks.count,
              (1...2000).contains(projects.count + sections.count + tasks.count) else { throw Self.invalid }
        var projectIDs = Set<String>(), sectionIDs = Set<String>(), taskIDs = Set<String>()
        for row in projects {
            let id = try TeamOrganizationValue.id(row["id"])
            guard Set(row.keys).isSubset(of: ["id", "user_id", "name", "description", "color", "parent_id", "order_index", "is_archived", "team_id", "visibility"]), projectIDs.insert(id).inserted, row["user_id"] == .string(account),
                  row["team_id"] == .string(body["team_id"]!.text), row["visibility"] == target["visibility"], row["is_archived"] == .bool(false),
                  row["parent_id"] == .null || projectIDs.contains(row["parent_id"]?.text ?? ""), row["parent_id"] != .string(id) else { throw Self.invalid }
            _ = try TeamOrganizationValue.name(row["name"])
        }
        let targets = creating ? projectIDs : [target["project_id"]!.text]
        for row in sections {
            let id = try TeamOrganizationValue.id(row["id"])
            guard Set(row.keys).isSubset(of: ["id", "user_id", "name", "project_id", "order_index"]), sectionIDs.insert(id).inserted, row["user_id"] == .string(account), targets.contains(row["project_id"]?.text ?? "") else { throw Self.invalid }
            _ = try TeamOrganizationValue.name(row["name"])
        }
        for row in tasks {
            let id = try TeamOrganizationValue.id(row["id"])
            _ = try TeamOrganizationValue.id(row["task_generation"])
            guard Set(row.keys).isSubset(of: TeamTaskEditScope.fields.union(["id", "user_id", "project_id", "task_generation", "completion_version", "created_at", "completed_at", "attachments", "comments", "reminders", "recurrence_end_date"])),
                  case .string(let title)? = row["title"], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 10000,
                  taskIDs.insert(id).inserted, row["user_id"] == .string(account), targets.contains(row["project_id"]?.text ?? ""),
                  row["completed"] == .bool(false), row["completion_version"] == .number(0),
                  row["section_id"] == .null || sections.contains(where: { $0["id"] == row["section_id"] && $0["project_id"] == row["project_id"] }),
                  TeamTaskLabelsDraft(row["labels"] ?? .null).supported,
                  ["assigned_to", "completed_at"].allSatisfy({ row[$0] == nil || row[$0] == .null }),
                  ["attachments", "comments"].allSatisfy({ row[$0] == nil || row[$0] == .array([]) }) else { throw Self.invalid }
            let scope = TeamTaskEditScope(account: account, origin: origin, team: body["team_id"]!.text, project: row["project_id"]!.text, taskTypesProtocol: definition.requiresHeadingSupport ? 1 : nil, taskTypeLifecycleProtocol: definition.requiresHeadingSupport ? 1 : nil)
            _ = try scope.lifecycleBody(for: Mutation(table: "tasks", recordID: id, method: "POST", fields: row, insertOnly: true, teamTaskScope: scope))
            let tree = row["subtasks"] ?? .array([])
            try TeamChecklist.validate(tree)
            for child in try TeamChecklist.indexed(tree).values {
                guard Set(child.keys).isSubset(of: ["is_heading", "id", "title", "description", "completed", "completed_at", "priority", "due_date", "due_time", "deadline_date", "duration_minutes", "time_zone", "labels", "subtasks", TeamChecklist.key]),
                      child["completed"] == .bool(false), child["completed_at"] == nil || child["completed_at"] == .null,
                      case .string(let title)? = child["title"], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let token = TeamChecklist.token(child[TeamChecklist.key]), token.version == 0,
                      TeamTaskLabelsDraft(child["labels"] ?? .null).supported else { throw Self.invalid }
            }
        }
        func sameTypes(_ source: Record, _ row: Record) -> Bool {
            guard source.fields["is_heading"] == row.fields["is_heading"], source["subtasks"].list.count == row["subtasks"].list.count else { return false }
            return zip(source["subtasks"].list, row["subtasks"].list).allSatisfy { sameTypes(Record($0.0.object), Record($0.1.object)) }
        }
        guard !definition.requiresHeadingSupport || zip(definition.tasks, tasks).allSatisfy({ sameTypes($0.0, Record($0.1)) }) else { throw Self.invalid }
        guard projectIDs.isDisjoint(with: sectionIDs), projectIDs.isDisjoint(with: taskIDs), sectionIDs.isDisjoint(with: taskIDs) else { throw Self.invalid }
        let orders = try TeamOrganizationValue.rows(body["orders"], limit: 5000)
        var grouped = Set<String>(), ordered = Set<String>()
        for order in orders {
            guard Set(order.keys) == ["project_id", "section_id", "base_ids", "task_ids"] else { throw Self.invalid }
            let project = try TeamOrganizationValue.id(order["project_id"]), section = try TeamProjectValue.optionalID(order["section_id"])
            guard targets.contains(project), grouped.insert(project + ":" + (section ?? "none")).inserted,
                  case .array(let base)? = order["base_ids"], base.count <= 10000, Set(base.map(\.text)).count == base.count,
                  case .array(let added)? = order["task_ids"], !added.isEmpty else { throw Self.invalid }
            for value in base { let id = try TeamOrganizationValue.id(value); guard !taskIDs.contains(id) else { throw Self.invalid } }
            for value in added {
                let id = try TeamOrganizationValue.id(value)
                guard ordered.insert(id).inserted, taskIDs.contains(id), tasks.contains(where: { $0["id"] == .string(id) && $0["project_id"] == .string(project) && $0["section_id"] == (section.map(JSON.string) ?? .null) }) else { throw Self.invalid }
            }
        }
        guard ordered == taskIDs else { throw Self.invalid }
        self.account = account; self.origin = origin; self.body = body
    }
    private enum CodingKeys: String, CodingKey { case account, origin, body }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), body: c.decode([String: JSON].self, forKey: .body))
    }
    func confirmed(_ raw: [String: JSON]) throws -> TeamWorkflowRunReceipt {
        let expected = body["tasks"]!.list.map { row in JSON.object(["id": row.object["id"]!, "generation": row.object["task_generation"]!, "project_id": row.object["project_id"]!]) }
        var keys: Set<String> = ["run_protocol", "account", "team_id", "request_id", "projects", "sections", "tasks", "replayed"]
        if body["workflow_types_protocol"] != nil { keys.insert("workflow_types_protocol"); guard raw["workflow_types_protocol"] == .number(1) else { throw Self.invalid } }
        guard Set(raw.keys) == keys,
              raw["run_protocol"] == .number(1), raw["account"] == .string(account), raw["team_id"] == .string(team), raw["request_id"] == .string(id),
              raw["projects"] == .array(body["projects"]!.list.map { $0.object["id"]! }), raw["sections"] == .array(body["sections"]!.list.map { $0.object["id"]! }),
              raw["tasks"] == .array(expected), case .bool? = raw["replayed"] else { throw Self.invalid }
        return TeamWorkflowRunReceipt(raw: raw)
    }
}
struct TeamWorkflowRunReceipt: Equatable, Sendable { let raw: [String: JSON] }
typealias TeamWorkflowRunVault = ReviewedTeamCommandVault<TeamWorkflowRunCommand>
typealias TeamWorkflowRunFileIO = ReviewedTeamCommandFileIO<TeamWorkflowRunCommand>

@MainActor protocol TeamWorkflowRunService: AnyObject { func workflowRun(_ command: TeamWorkflowRunCommand) async throws -> TeamWorkflowRunReceipt }
extension Backend: TeamWorkflowRunService {
    func workflowRun(_ command: TeamWorkflowRunCommand) async throws -> TeamWorkflowRunReceipt {
        guard session?.user.id == command.account, command.origin == (try accountRemovalOrigin) else { throw CancellationError() }
        let fence = try reauthenticationContext(account: command.account)
        let data = try await request("/rest/v1/rpc/taskfold_team_workflow_run", method: "POST", body: ["_body": .object(command.body)], expectedAccount: command.account)
        try requireReauthentication(fence)
        guard data.count <= 1_000_000, let raw = try? TaskfoldJSONDecoder().decode([String: JSON].self, from: data) else { throw TeamWorkflowRunCommand.invalid }
        return try command.confirmed(raw)
    }
}

@MainActor @Observable final class TeamWorkflowRunModel {
    private(set) var pending: TeamWorkflowRunCommand?
    private(set) var recoveryLoaded = false
    private(set) var busy = false
    private(set) var message: String?
    private(set) var success: String?
    private(set) var receipt: TeamWorkflowRunReceipt?
    let account: String, origin: String
    private var closed = false
    @ObservationIgnored private let vault: TeamWorkflowRunVault
    @ObservationIgnored private let service: any TeamWorkflowRunService
    @ObservationIgnored private let current: () -> Bool
    @ObservationIgnored private let lease = CalendarReadLease()
    init(account: String, origin: String, vault: TeamWorkflowRunVault, service: any TeamWorkflowRunService, current: @escaping () -> Bool) {
        self.account = account; self.origin = origin; self.vault = vault; self.service = service; self.current = current
    }
    func close() { closed = true; lease.cancel(); pending = nil; recoveryLoaded = false; message = nil; success = nil; receipt = nil }
    private func check() throws { try lease.check(); guard !closed, current() else { throw CancellationError() } }
    private func recover() async throws {
        recoveryLoaded = false; pending = nil
        let saved = try await vault.pending(account: account, origin: origin); try check(); pending = saved; recoveryLoaded = true
    }
    func load() async { await perform { try await self.recover() } }
    func send(_ command: TeamWorkflowRunCommand, canAuthor: () -> Bool) async {
        await perform {
            try await self.recover(); guard self.pending == nil, command.account == self.account, command.origin == self.origin, canAuthor() else { throw TeamWorkflowRunCommand.invalid }
            try await self.vault.begin(command, lease: self.lease); try self.check(); self.pending = command
            guard canAuthor() else { throw TeamWorkflowRunCommand.invalid }
            try await self.finish()
        }
    }
    func retry(_ reviewed: TeamWorkflowRunCommand) async {
        await perform {
            try await self.recover(); guard self.pending == reviewed else { throw TeamWorkflowRunCommand.invalid }
            try await self.finish()
        }
    }
    /// Stopping retry does not cancel a change already accepted by the service.
    func stopRetrying(_ reviewed: TeamWorkflowRunCommand) async {
        await perform {
            try await self.recover(); guard self.pending == reviewed else { throw TeamWorkflowRunCommand.invalid }
            try await self.vault.clear(reviewed, lease: self.lease); try self.check(); try await self.recover()
        }
    }
    private func finish() async throws {
        guard let command = pending else { throw TeamWorkflowRunCommand.invalid }
        try check(); let result = try await service.workflowRun(command); try check()
        guard try command.confirmed(result.raw) == result else { throw TeamWorkflowRunCommand.invalid }
        try await vault.clear(command, lease: lease); try check()
        pending = nil; receipt = result
        success = result.raw["replayed"] == .bool(true) ? "Original workflow confirmed. Its tasks may have changed since then." : "Workflow created"
        try await recover()
    }
    private func perform(_ action: () async throws -> Void) async {
        guard !busy, !closed else { return }
        guard current() else { close(); return }
        busy = true; message = nil; success = nil; receipt = nil; defer { busy = false }
        do { try check(); try await action(); try check() }
        catch {
            guard !closed, current() else { close(); return }
            if receipt != nil { message = "The change was confirmed. Refresh the workspace before creating another workflow." }
            else if error is AccountSessionAuthorizationRequired { message = "Sign in again before retrying your saved workflow request." }
            else if pending != nil { message = "This change couldn’t be confirmed. Your original request is saved. Review the saved workflow before retrying; stopping retry won’t undo a change already made." }
            else { message = "Your saved workflow request couldn’t be opened or prepared. Nothing new was sent." }
        }
    }
}

/// Stage a complete destination catalog behind the workspace/session fence.
@MainActor @Observable final class TeamWorkflowDestinations {
    private(set) var overview: TeamOrganizationOverview?
    private(set) var organization: TeamOrganizationDetail?
    private(set) var projects: [TeamProjectAccess] = []
    private(set) var loading = false
    private(set) var message: String?
    private var attempt = UUID()
    let account: String, origin: String
    @ObservationIgnored private let current: () -> Bool
    @ObservationIgnored private let fence: () async throws -> String
    @ObservationIgnored private let readOverview: () async throws -> TeamOrganizationOverview
    @ObservationIgnored private let readTeam: (String) async throws -> TeamOrganizationDetail
    @ObservationIgnored private let page: (String, String?) async throws -> TeamProjectPage
    init(account: String, origin: String, current: @escaping () -> Bool, fence: @escaping () async throws -> String,
         overview: @escaping () async throws -> TeamOrganizationOverview, team: @escaping (String) async throws -> TeamOrganizationDetail,
         page: @escaping (String, String?) async throws -> TeamProjectPage) {
        self.account = account; self.origin = origin; self.current = current; self.fence = fence
        readOverview = overview; readTeam = team; self.page = page
    }
    func invalidate() { attempt = UUID(); overview = nil; organization = nil; projects = []; loading = false; message = nil }
    func load(team: String? = nil) async {
        invalidate(); guard current() else { return }; let request = attempt; loading = true
        func check() throws { guard current(), request == attempt else { throw CancellationError() } }
        do {
            let before = try await fence(); try check()
            guard before.utf8.count == 64, before.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw TeamWorkflowRunCommand.invalid }
            let overview = try await readOverview(); try check()
            guard overview.account == account, overview.origin == origin, overview.enabled else { throw TeamWorkflowRunCommand.invalid }
            var organization: TeamOrganizationDetail?, projects: [TeamProjectAccess] = []
            if let team {
                guard overview.teams.contains(where: { $0.id == team && !$0.archived }) else { throw TeamWorkflowRunCommand.invalid }
                let detail = try await readTeam(team); try check()
                guard detail.account == account, detail.origin == origin, overview.teams.contains(detail.team), !detail.team.archived else { throw TeamWorkflowRunCommand.invalid }
                organization = detail
                var cursor: String?
                repeat {
                    let result = try await page(team, cursor); try check()
                    guard result.account == account, result.origin == origin, result.team == team,
                          result.teamRevision == detail.team.revision, result.state == .active, !result.setupPaused,
                          projects.count + result.projects.count <= 1000 else { throw TeamWorkflowRunCommand.invalid }
                    projects += result.projects
                    guard Set(projects.map(\.id)).count == projects.count else { throw TeamWorkflowRunCommand.invalid }
                    cursor = result.next
                    if cursor != nil, result.projects.isEmpty { throw TeamWorkflowRunCommand.invalid }
                } while cursor != nil
            }
            let after = try await fence(); try check(); guard before == after else { throw TeamWorkspaceChanged() }
            self.overview = overview; self.organization = organization; self.projects = projects
        } catch {
            guard request == attempt else { return }
            if current() { message = error is AccountSessionAuthorizationRequired ? "Sign in again to choose a shared destination." : "Destinations couldn’t be verified. Refresh to try again." }
        }
        if request == attempt { loading = false }
    }
    static func editable(_ project: TeamProjectAccess) -> Bool {
        project.name != nil && project.state == .active && !project.setupPaused && project.role != .viewer && project.archive?.effective == false && project.hierarchy?.parentUnavailable == false
    }
}

extension Backend {
    func workflowPersonalSource(id: String, account: String, origin: String) async throws -> TeamWorkflowRunPlan.Source {
        guard TeamProjectValue.id(id), session?.user.id == account, origin == (try accountRemovalOrigin) else { throw CancellationError() }
        let fence = try reauthenticationContext(account: account)
        var query = URLComponents(); query.queryItems = [URLQueryItem(name: "select", value: "id,user_id,name,document"), URLQueryItem(name: "id", value: "eq." + id), URLQueryItem(name: "user_id", value: "eq." + account), URLQueryItem(name: "limit", value: "1")]
        let bytes = try await request("/rest/v1/project_templates?" + query.percentEncodedQuery!, expectedAccount: account, workflowReadLimit: 3_000_000)
        try requireReauthentication(fence)
        let rows = try TaskfoldJSONDecoder().decode([Record].self, from: bytes)
        guard rows.count == 1, let row = rows.first, Set(row.fields.keys) == ["id", "user_id", "name", "document"], row.id == id, row["user_id"] == .string(account) else { throw TeamWorkflowRunCommand.invalid }
        _ = try WorkflowTemplate(document: row["document"])
        return .personal(row)
    }
    func workflowBaseOrders(_ plan: TeamWorkflowRunPlan) async throws -> [String: [String]] {
        guard session?.user.id == plan.account, plan.origin == (try accountRemovalOrigin), reminderSessionIncarnation == plan.session else { throw CancellationError() }
        let fence = try reauthenticationContext(account: plan.account)
        let keys = plan.orders.map { "group:" + $0.project + ":" + ($0.section ?? "none") }
        guard Set(keys).count == keys.count else { throw TeamWorkflowRunCommand.invalid }
        var result = Dictionary(uniqueKeysWithValues: keys.map { ($0, [String]()) }), seen = Set<String>(), received = 0
        for start in stride(from: 0, to: keys.count, by: 50) {
            let batch = Array(keys[start..<min(start + 50, keys.count)])
            var query = URLComponents(); query.queryItems = [URLQueryItem(name: "select", value: "user_id,id,ids"), URLQueryItem(name: "user_id", value: "eq." + plan.account), URLQueryItem(name: "id", value: "in.(" + batch.map { "\"" + $0 + "\"" }.joined(separator: ",") + ")"), URLQueryItem(name: "limit", value: "50")]
            let bytes = try await request("/rest/v1/view_orders?" + query.percentEncodedQuery!, expectedAccount: plan.account, workflowReadLimit: 4_200_000)
            try requireReauthentication(fence); received += bytes.count
            guard received <= 4_200_000 else { throw TeamWorkflowRunCommand.invalid }
            let rows = try TaskfoldJSONDecoder().decode([Record].self, from: bytes)
            guard rows.count <= batch.count else { throw TeamWorkflowRunCommand.invalid }
            for row in rows {
                guard Set(row.fields.keys) == ["id", "user_id", "ids"], row["user_id"] == .string(plan.account), batch.contains(row.id), seen.insert(row.id).inserted,
                      case .array(let ids) = row["ids"], ids.count <= 10000 else { throw TeamWorkflowRunCommand.invalid }
                let names = try ids.map { try TeamOrganizationValue.id($0) }
                guard Set(names).count == names.count else { throw TeamWorkflowRunCommand.invalid }; result[row.id] = names
            }
        }
        return result
    }
}
