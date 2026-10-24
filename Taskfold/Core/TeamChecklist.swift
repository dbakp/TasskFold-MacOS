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
                let changed = old != nil && (old?["completed"] ?? .bool(false)) != (row["completed"] ?? .bool(false))
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
