import Foundation

enum TeamProjectRole: String, Codable, Sendable, CaseIterable { case manager, editor, viewer; var title: String { rawValue.capitalized } }
enum TeamProjectVisibility: String, Codable, Sendable { case team, `private` }
enum TeamProjectState: String, Sendable { case active, archived }

struct TeamConversationRecoveryExpired: LocalizedError {
    var errorDescription: String? { "Discussion recovery has expired. Your saved task is still on this device." }
}

struct TeamTaskReviewRequired: LocalizedError {
    var errorDescription: String? { "TASKFOLD_CONFLICT: Review this team action in a supported Taskfold app. Your saved change remains on this device." }
}

struct TeamProjectAccessUnavailable: LocalizedError {
    var errorDescription: String? { "This project is no longer available to your account." }
}

enum TeamProjectValue {
    static var invalid: AppFailure { AppFailure(message: "Project access couldn’t be verified. Reload your projects.") }
    static func id(_ value: String) -> Bool {
        AutomationKey.canonicalID(value) && value != "00000000-0000-0000-0000-000000000000"
    }
    static func revision(_ value: JSON?) throws -> Double {
        guard case .number(let n)? = value, n.isFinite, n >= 1, n <= 9_007_199_254_740_991, n.rounded(.down) == n else { throw invalid }
        return n
    }
    static func optionalID(_ value: JSON?) throws -> String? {
        if value == .null { return nil }
        guard case .string(let text)? = value, id(text) else { throw invalid }
        return text
    }
    struct Context {
        let revision: Double
        let state: TeamProjectState
        let paused: Bool
        init(_ root: [String: JSON], account: String, team: String) throws {
            guard TeamProjectValue.id(account), TeamProjectValue.id(team), root["protocol"] == .number(1),
                  root["account"] == .string(account), root["team_id"] == .string(team),
                  case .string(let text)? = root["team_state"], let state = TeamProjectState(rawValue: text),
                  case .bool(let paused)? = root["setup_paused"] else { throw TeamProjectValue.invalid }
            revision = try TeamProjectValue.revision(root["team_revision"])
            self.state = state; self.paused = paused
        }
    }
}

/// Absence means an older service, never an invented active project.
struct TeamProjectArchiveState: Equatable, Sendable {
    let own: Bool
    let inherited: Bool
    var effective: Bool { own || inherited }
    var title: String { inherited ? (own ? "Archived · parent also archived" : "Archived with parent") : own ? "Archived" : "Active" }
    static func read(_ row: [String: JSON]) throws -> Self? {
        let keys = ["project_state_protocol", "is_archived", "ancestor_archived"]
        if keys.allSatisfy({ row[$0] == nil }) { return nil }
        guard row["project_state_protocol"] == .number(1), case .bool(let own)? = row["is_archived"], case .bool(let inherited)? = row["ancestor_archived"] else { throw TeamProjectValue.invalid }
        return Self(own: own, inherited: inherited)
    }
}

struct TeamProjectHierarchy: Equatable, Sendable {
    let parent: String?
    let parentUnavailable: Bool
    static func read(_ row: [String: JSON], project: String) throws -> Self? {
        if ["project_hierarchy_protocol", "parent_id", "parent_unavailable"].allSatisfy({ row[$0] == nil }) { return nil }
        guard row["project_hierarchy_protocol"] == .number(1), case .bool(let unavailable)? = row["parent_unavailable"] else { throw TeamProjectValue.invalid }
        let parent = try TeamProjectValue.optionalID(row["parent_id"])
        guard parent != project, !unavailable || parent == nil else { throw TeamProjectValue.invalid }
        return Self(parent: parent, parentUnavailable: unavailable)
    }
}

/// Context is part of the value: a caller must not reuse it in another account,
/// server or workspace. A creator UUID never implies any of these permissions.
struct TeamProjectAccess: Equatable, Sendable {
    let id: String
    let team: String
    let account: String
    let origin: String
    let revision: Double
    let teamRevision: Double
    let state: TeamProjectState
    let setupPaused: Bool
    let role: TeamProjectRole
    let visibility: TeamProjectVisibility
    let folder: String?
    let canManageAccess: Bool
    let name: String?
    let archive: TeamProjectArchiveState?
    let hierarchy: TeamProjectHierarchy?
    var canEditTasks: Bool { false } // Enable after complete commands and workspace refresh acceptance.

    init(detail: [String: JSON], account: String, origin: String, team: String, project: String) throws {
        let context = try TeamProjectValue.Context(detail, account: account, team: team)
        try self.init(row: detail, context: context, account: account, origin: origin, team: team)
        guard id == project else { throw TeamProjectValue.invalid }
    }
    fileprivate init(row: [String: JSON], context: TeamProjectValue.Context, account: String, origin: String, team: String) throws {
        guard case .string(let id)? = row["id"], TeamProjectValue.id(id), row["team_id"] == .string(team),
              case .string(let roleText)? = row["role"], let role = TeamProjectRole(rawValue: roleText),
              case .string(let visibilityText)? = row["visibility"], let visibility = TeamProjectVisibility(rawValue: visibilityText),
              case .bool(false)? = row["can_edit_tasks"], case .bool(let manage)? = row["can_manage_access"],
              manage == (role == .manager) else { throw TeamProjectValue.invalid }
        archive = try TeamProjectArchiveState.read(row)
        hierarchy = try TeamProjectHierarchy.read(row, project: id)
        self.id = id; self.team = team; self.account = account; self.origin = origin
        revision = try TeamProjectValue.revision(row["revision"]); teamRevision = context.revision
        folder = try TeamProjectValue.optionalID(row["folder_id"])
        self.role = role; self.visibility = visibility; state = context.state; setupPaused = context.paused; canManageAccess = manage; name = TeamOrganizationDetail.Member.identity(row["name"])
    }
    func belongs(to account: String, origin: String, team: String) -> Bool {
        self.account == account && self.origin == origin && self.team == team
    }
}

struct TeamProjectPage: Sendable {
    let account: String
    let origin: String
    let team: String
    let projects: [TeamProjectAccess]
    let next: String?
    let teamRevision: Double
    let state: TeamProjectState
    let setupPaused: Bool
    init(_ root: [String: JSON], account: String, origin: String, team: String, after: String?, limit: Int = 50) throws {
        let context = try TeamProjectValue.Context(root, account: account, team: team)
        guard (1...100).contains(limit), after == nil || TeamProjectValue.id(after!),
              root["task_writes_enabled"] == .bool(false), case .array(let values)? = root["projects"], values.count <= limit else { throw TeamProjectValue.invalid }
        let rows = try values.map { value -> TeamProjectAccess in
            guard case .object(let row) = value else { throw TeamProjectValue.invalid }
            return try TeamProjectAccess(row: row, context: context, account: account, origin: origin, team: team)
        }
        let ids = rows.map(\.id)
        guard Set(ids).count == ids.count, ids == ids.sorted(), after == nil || ids.allSatisfy({ $0 > after! }) else { throw TeamProjectValue.invalid }
        let cursor = try TeamProjectValue.optionalID(root["next_cursor"])
        guard cursor == nil || (rows.count == limit && cursor == ids.last) else { throw TeamProjectValue.invalid }
        self.account = account; self.origin = origin; self.team = team; projects = rows; next = cursor
        teamRevision = context.revision; state = context.state; setupPaused = context.paused
    }
}

/// Captured when the user edits, never inferred from a later project listing.
/// Persisting context prevents a saved intent from changing account or workspace.
struct TeamTaskEditScope: Codable, Equatable, Sendable {
    let account: String
    let origin: String
    let team: String
    let project: String
    var restoreRequest: UUID? = nil
    var parentGeneration: String? = nil
    var checklistRestoreRequest: UUID? = nil

    static let fields: Set<String> = ["title", "description", "priority", "due_date", "due_time", "completed", "completed_at", "deadline_date", "duration_minutes", "time_zone", "scheduled_at", "assigned_to", "section_id", "labels", "reminder_specs", "subtasks", "is_recurring", "recurrence_pattern", "recurrence_end_date"]
    static var invalid: AppFailure { AppFailure(message: "This saved team edit needs review. Your changes remain on this device.") }
    static var conflict: AppFailure { AppFailure(message: "TASKFOLD_CONFLICT: This team task changed. Review the synced task and your saved edit.") }

    func capturing(_ original: Mutation, existing: Record?) throws -> Mutation {
        let change = try TeamChecklist.preparing(original)
        if change.method != "PATCH" {
            if change.method == "DELETE" {
                guard let existing, existing.id == change.recordID, existing["project_id"] == .string(project),
                      existing["task_generation"] == change.baseline?["task_generation"] else { throw Self.conflict }
            } else if existing != nil { throw Self.conflict }
            _ = try lifecycleBody(for: change)
            return change
        }
        guard let existing, existing.id == change.recordID, existing["project_id"] == .string(project),
              change.baseline?["task_generation"] == existing["task_generation"] else { throw Self.conflict }
        var captured = change
        if TeamTaskRecurrence.touches(captured.fields) {
            try TeamTaskRecurrence.validate(base: captured.baseline ?? [:], changes: captured.fields)
            try TeamTaskRecurrence.requireCurrent(base: captured.baseline ?? [:], current: existing)
        }
        if captured.baseline?["project_id"] == nil { captured.baseline?["project_id"] = .string(project) }
        _ = try body(for: captured)
        return captured
    }
    func body(for change: Mutation) throws -> [String: JSON] {
        guard [account, team, project, change.recordID].allSatisfy(TeamProjectValue.id),
              change.table == "tasks", change.method == "PATCH", change.organizationOrder == nil,
              !change.fields.isEmpty, Set(change.fields.keys).isSubset(of: Self.fields),
              let base = change.baseline, base["project_id"] == .string(project),
              case .string(let generation)? = base["task_generation"], TeamProjectValue.id(generation),
              change.fields.keys.allSatisfy({ base[$0] != nil }) else { throw Self.invalid }
        for key in ["assigned_to", "section_id"] {
            if let value = change.fields[key], value != .null {
                guard case .string(let id) = value, TeamProjectValue.id(id) else { throw Self.invalid }
            }
        }
        if let value = change.fields["labels"] {
            guard case .array(let labels) = value, labels.count <= 256,
                  labels.allSatisfy({ if case .string(let text) = $0 { return !text.isEmpty && text.utf8.count <= 1024 }; return false }) else { throw Self.invalid }
        }
        if let value = change.fields["reminder_specs"] {
            guard case .array(let reminders) = value, reminders.count <= 20 else { throw Self.invalid }
            var ids = Set<UUID>()
            for reminder in reminders {
                guard case .object(let row) = reminder, case .string(let text)? = row["id"],
                      let id = UUID(uuidString: text), ids.insert(id).inserted else { throw Self.invalid }
            }
        }
        try TeamTaskRecurrence.validate(base: base, changes: change.fields)
        if let tree = change.fields["subtasks"] { try TeamChecklist.validate(tree) }
        if checklistRestoreRequest != nil, change.fields["subtasks"] == nil { throw Self.invalid }
        if TaskCompletionRevision.touches(change.fields) {
            guard case .number(let version)? = base["completion_version"], version.isFinite,
                  version >= 0, version <= 9_007_199_254_740_991, version.rounded(.down) == version else { throw Self.conflict }
        }
        var body: [String: JSON] = ["team_id": .string(team), "project_id": .string(project), "task_id": .string(change.recordID),
            "request_id": .string(change.id.uuidString.lowercased()), "task_generation": .string(generation), "base": .object(base), "changes": .object(change.fields)]
        if let checklistRestoreRequest { body["checklist_restore_from"] = .string(checklistRestoreRequest.uuidString.lowercased()) }
        guard try JSONEncoder().encode(body).count <= 128000 else { throw Self.invalid }
        return body
    }
    func saved(_ reply: [String: JSON], for change: Mutation) throws -> Record {
        let body = try body(for: change)
        guard reply["protocol"] == .number(1), reply["account"] == .string(account),
              reply["team_id"] == .string(team), reply["project_id"] == .string(project),
              reply["request_id"] == body["request_id"], reply["task_generation"] == body["task_generation"],
              case .bool? = reply["replayed"], case .object(let fields)? = reply["task"],
              fields["id"] == .string(change.recordID), fields["project_id"] == .string(project),
              fields["task_generation"] == body["task_generation"], case .string(let creator)? = fields["user_id"],
              TeamProjectValue.id(creator), case .string? = fields["title"], case .bool? = fields["completed"],
              case .number(let version)? = fields["completion_version"], version.isFinite, version >= 0,
              version <= 9_007_199_254_740_991, version.rounded(.down) == version else { throw Self.invalid }
        // A replay can return another person's newer values. Confirm identity,
        // not equality with our desired edit, so a retry cannot overwrite them.
        return Record(fields)
    }
}


extension TeamTaskEditScope {
    static func historyAction(_ original: Mutation) -> Mutation {
        var change = original
        if change.teamTaskScope != nil { change.id = UUID() }
        return change
    }
    func lifecycleAction(for change: Mutation) throws -> String {
        guard change.table == "tasks", change.organizationOrder == nil else { throw Self.invalid }
        if change.method == "DELETE" { return "delete" }
        if change.method == "POST", change.insertOnly == true { return restoreRequest == nil ? "create" : "restore" }
        throw Self.invalid
    }
    func lifecycleBody(for change: Mutation) throws -> [String: JSON] {
        let action = try lifecycleAction(for: change)
        guard [account,team,project,change.recordID].allSatisfy(TeamProjectValue.id) else { throw Self.invalid }
        let record = action == "delete" ? change.baseline : change.fields
        guard let record, record["id"] == .string(change.recordID), record["project_id"] == .string(project),
              case .string(let creator)? = record["user_id"], TeamProjectValue.id(creator),
              case .string? = record["title"], case .string(let generation)? = record["task_generation"],
              TeamProjectValue.id(generation), action != "create" || creator == account else { throw Self.invalid }
        var body: [String: JSON] = ["team_id":.string(team),"project_id":.string(project),"task_id":.string(change.recordID),
            "request_id":.string(change.id.uuidString.lowercased()),"task_generation":.string(generation),"record":.object(record)]
        if action == "restore", let restoreRequest { body["restore_from"] = .string(restoreRequest.uuidString.lowercased()) }
        if action == "create", let parent = record["recurrence_parent_id"], parent != .null {
            guard case .string(let parentID) = parent, TeamProjectValue.id(parentID), let parentGeneration,
                  TeamProjectValue.id(parentGeneration) else { throw Self.conflict }
            body["parent_generation"] = .string(parentGeneration)
        }
        guard try JSONEncoder().encode(body).count <= 128000 else { throw Self.invalid }
        return body
    }
    func lifecycleSaved(_ reply: [String: JSON], for change: Mutation) throws -> Record? {
        let action = try lifecycleAction(for: change), body = try lifecycleBody(for: change)
        guard reply["protocol"] == .number(1), reply["operation"] == .string(action), reply["account"] == .string(account),
              reply["team_id"] == .string(team), reply["project_id"] == .string(project), reply["task_id"] == .string(change.recordID),
              reply["request_id"] == body["request_id"], reply["task_generation"] == body["task_generation"],
              case .bool(let unavailable)? = reply["unavailable"], case .bool(let replayed)? = reply["replayed"] else { throw Self.invalid }
        if unavailable {
            guard reply["task"] == .null, action == "delete" || replayed else { throw Self.invalid }
            return nil
        }
        guard action != "delete", case .object(let row)? = reply["task"], row["id"] == .string(change.recordID),
              row["project_id"] == .string(project), row["task_generation"] == body["task_generation"],
              case .string(let creator)? = row["user_id"], TeamProjectValue.id(creator), row["user_id"] == body["record"]?.object["user_id"], case .string? = row["title"],
              case .bool? = row["completed"], case .number(let revision)? = row["completion_version"], revision.isFinite,
              revision >= 0, revision <= 9_007_199_254_740_991, revision.rounded(.down) == revision else { throw Self.invalid }
        return Record(row)
    }
}
