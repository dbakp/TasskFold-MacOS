import Foundation

/// Team-only checklist metadata records a completion incarnation and revision.
/// Identity changes on recovery, so delayed completions cannot target a restored item.
enum TeamChecklist {
    static let key = "taskfold_completion_v1"
    static let maximumVersion = 9_007_199_254_740_990.0
    static func token(_ value: JSON?) -> (epoch: String, version: Double)? {
        guard case .object(let row)? = value, Set(row.keys) == Set(["epoch", "version"]),
              case .string(let epoch)? = row["epoch"], TeamProjectValue.id(epoch),
              case .number(let version)? = row["version"], version.isFinite,
              version >= 0, version <= maximumVersion, version.rounded(.down) == version else { return nil }
        return (epoch, version)
    }
    static func indexed(_ value: JSON) throws -> [String: [String: JSON]] {
        var result: [String: [String: JSON]] = [:]
        func walk(_ value: JSON, depth: Int) throws {
            guard case .array(let rows) = value else { throw TeamTaskEditScope.invalid }
            guard rows.isEmpty || depth <= 24 else { throw TeamTaskEditScope.invalid }
            for row in rows {
                guard case .object(let fields) = row, case .string(let id)? = fields["id"],
                      !id.isEmpty, id.utf8.count <= 128, result[id] == nil, result.count < 1000 else { throw TeamTaskEditScope.invalid }
                result[id] = fields
                if let children = fields["subtasks"] { try walk(children, depth: depth + 1) }
            }
        }
        try walk(value, depth: 1)
        return result
    }
    static func preparing(_ change: Mutation) throws -> Mutation {
        guard let scope = change.teamTaskScope, change.table == "tasks", let value = change.fields["subtasks"] else { return change }
        // Whole-task Undo is already certified against the original task receipt.
        // Its new root generation fences stale children; preserve the certified tree.
        if change.method == "POST", scope.restoreRequest != nil { return change }
        let base = change.method == "PATCH" ? try indexed(change.baseline?["subtasks"] ?? .null) : [:]
        _ = try indexed(value)
        func walk(_ value: JSON) throws -> JSON {
            .array(try value.list.map { item in
                var row = item.object
                let id = row["id"]!.text
                let old = base[id]
                let freshEpoch = TaskCompletion.successorID(parent: "team-checklist:" + change.id.uuidString.lowercased(), day: id)
                let changed = old != nil && ((old?["completed"] ?? .bool(false)) != (row["completed"] ?? .bool(false)) || TaskKind(Record(old!)) != TaskKind(Record(row)))
                let epoch: String
                let version: Double
                if let original = token(old?[key]) {
                    epoch = original.epoch; version = original.version + (changed ? 1 : 0)
                    guard version <= maximumVersion else { throw TeamTaskEditScope.invalid }
                } else if old != nil {
                    epoch = freshEpoch; version = changed ? 1 : 0
                } else if scope.checklistRestoreRequest == nil, let fresh = token(row[key]), fresh.version == 0 {
                    epoch = fresh.epoch; version = 0
                } else {
                    epoch = freshEpoch; version = 0
                }
                row[key] = .object(["epoch": .string(epoch), "version": .number(version)])
                if let children = row["subtasks"] { row["subtasks"] = try walk(children) }
                return .object(row)
            })
        }
        var result = change; result.fields["subtasks"] = try walk(value)
        return result
    }
    static func validate(_ value: JSON) throws {
        for row in try indexed(value).values {
            if let value = row[key], token(value) == nil { throw TeamTaskEditScope.invalid }
        }
    }
}


/// Versioned editing capability. It does not authorize creation, import or rollout.
enum TeamTaskTypes {
    static func requiresProtocol(_ change: Mutation) -> Bool {
        if change.fields["is_heading"] != nil { return true }
        guard let next = change.fields["subtasks"] else { return false }
        let old = (try? TeamChecklist.indexed(change.baseline?["subtasks"] ?? .array([]))) ?? [:]
        guard let nodes = try? TeamChecklist.indexed(next) else { return true }
        return nodes.contains { id, node in
            let kind = TaskKind(Record(node))
            return kind == .unsupported || (old[id].map { TaskKind(Record($0)) } ?? .task) != kind
        }
    }
    static func validate(_ change: Mutation, protocolVersion: Int?) throws {
        guard requiresProtocol(change) else { return }
        guard protocolVersion == 1, change.method == "PATCH", let base = change.baseline else { throw unavailable }
        if let type = change.fields["is_heading"] {
            guard case .bool = type, base["is_heading"] != nil,
                  base["completed"] == .bool(false), base["completed_at"] == .null,
                  change.fields["completed"] == nil, change.fields["completed_at"] == nil,
                  TaskKind(Record(base)) != .unsupported,
                  case .number(let version)? = base["completion_version"], version.isFinite,
                  version >= 0, version <= TeamChecklist.maximumVersion, version.rounded(.down) == version else { throw TeamTaskEditScope.invalid }
        }
        if let tree = change.fields["subtasks"] {
            let old = try TeamChecklist.indexed(base["subtasks"] ?? .array([]))
            for (id, node) in try TeamChecklist.indexed(tree) {
                if let previous = old[id], TaskKind(Record(previous)) != TaskKind(Record(node)) {
                    guard (previous["completed"] ?? .bool(false)) == .bool(false), (previous["completed_at"] ?? .null) == .null,
                          (node["completed"] ?? .bool(false)) == .bool(false), (node["completed_at"] ?? .null) == .null else { throw TeamTaskEditScope.invalid }
                }
            }
        }
        guard TaskKind.permits(change, existing: Record(base)) else { throw TeamTaskEditScope.invalid }
    }
    static func requireCurrent(_ change: Mutation, current: Record) throws {
        guard requiresProtocol(change), let base = change.baseline else { return }
        if change.fields["is_heading"] != nil {
            guard ["is_heading", "completed", "completed_at", "completion_version"].allSatisfy({ (base[$0] ?? .null) == current[$0] }) else { throw TeamTaskEditScope.conflict }
        }
        if let tree = change.fields["subtasks"] {
            let before = try TeamChecklist.indexed(base["subtasks"] ?? .array([]))
            let live = try TeamChecklist.indexed(current["subtasks"])
            for (id, node) in try TeamChecklist.indexed(tree) where TaskKind(Record(node)) != (before[id].map { TaskKind(Record($0)) } ?? .task) {
                if let old = before[id] {
                    guard let now = live[id], ["is_heading", "completed", "completed_at", TeamChecklist.key].allSatisfy({ (old[$0] ?? .null) == (now[$0] ?? .null) }) else { throw TeamTaskEditScope.conflict }
                } else if live[id] != nil { throw TeamTaskEditScope.conflict }
            }
        }
    }
    static var unavailable: AppFailure { AppFailure(message: "Heading editing is not available for this team workspace yet. Your draft is kept on this device.") }
}


extension TeamTaskTypes {
    /// Current capability and custody, separate from the editor's frozen source/session admission.
    static func authoringAvailable(scope: TeamTaskEditScope, cache: TeamWorkspaceCache, enabled: Bool) -> Bool {
        guard enabled, scope.taskTypesProtocol == 1, scope.taskTypeLifecycleProtocol == 1,
              cache.boundary.belongs(account: scope.account, origin: scope.origin),
              cache.boundary.raw["task_types_protocol"] == .number(1), cache.boundary.raw["task_type_lifecycle_protocol"] == .number(1),
              cache.knownTeams[scope.project] == scope.team,
              let project = cache.boundary.projects[scope.project], project.team == scope.team,
              project.canSend, !project.archived, ["manager", "editor"].contains(project.role),
              cache.boundary.raw["teams"]?.list.contains(where: { $0.object["id"] == .string(scope.team) && $0.object["state"] == .string("active") }) == true else { return false }
        return true
    }
}

/// Shared type conversion needs a separately saved reopen, so it cannot reuse
/// a completed item's old checkbox revision as authority for a new type.
extension TeamTaskTypes {
    static func needsSavedReopen(_ item: Record, originalTree: JSON?) -> Bool {
        guard let originalTree else { return false }
        guard let nodes = try? TeamChecklist.indexed(originalTree) else { return true }
        guard let old = nodes[item.id] else { return false }
        return (old["completed"] ?? .bool(false)) != .bool(false) || (old["completed_at"] ?? .null) != .null
    }
}
