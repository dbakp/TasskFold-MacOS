import Foundation
import CryptoKit

/// What is left of the JSON subtask era: the `subtask:<base64 path>` references older builds persisted (widget links,
/// completion receipts, Spotlight items, list orders) and the sibling key their paths use. Nothing creates them now.
enum LegacySubtaskReference {
    static let prefix = "subtask:"
    /// Trees nested deeper than this were never readable.
    static let readableDepth = 32
    /// A node's key among its siblings: its `id`, or `@index` when it has none.
    static func childKey(_ value: JSON, index: Int) -> String { value.object["id"]?.text.isEmpty == false ? value.object["id"]!.text : "@\(index)" }
    /// The root id followed by the child keys, or nil when `id` is not a legacy reference.
    static func path(_ id: String) -> [String]? {
        guard id.hasPrefix(prefix), let data = Data(base64Encoded: String(id.dropFirst(prefix.count))),
              let path = try? TaskfoldJSONDecoder().decode([String].self, from: data), (2...readableDepth + 1).contains(path.count), path.allSatisfy({ !$0.isEmpty }) else { return nil }
        return path
    }
    static func reference(_ path: [String]) -> String { prefix + (try! TaskfoldJSONEncoder().encode(path)).base64EncodedString() }
}

/// Converts the legacy JSON `subtasks` tree of a task into child rows (`parent_id`/`child_order`). The server's
/// Migration B runs the same algorithm in SQL; both are proven equal by `TaskfoldTests/Fixtures/legacy_subtasks.json`.
///
/// Identity: `legacy_child_id(root, path)` = `md5('taskfold.child-row.v1|' + lower(root) + '|' + path joined by U+001F)`
/// formatted as a UUID. A path segment is `LegacySubtaskReference.childKey` (the node's `id`), unless that key is shared by
/// several siblings, in which case the segment is `@index` for each of them.
///
/// Levels: a child of the root is at level 1. A node deeper than ten levels is re-parented to its level-9 ancestor
/// (so it lands at level 10, the most the server's ancestor guard allows); its id still comes from its real path.
enum LegacySubtaskConversion {
    static let namespace = "taskfold.child-row.v1"
    static let separator = "\u{1F}"
    static let maximumLevel = TaskTree.maximumAncestors
    /// Trees nested deeper than this were never readable, so the walk stops here.
    static let readableLevel = 32

    static func legacyChildID(root: String, path: [String]) -> String {
        let text = namespace + "|" + root.lowercased() + "|" + path.joined(separator: separator)
        let hex = Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let h = Array(hex)
        return String(h[0..<8]) + "-" + String(h[8..<12]) + "-" + String(h[12..<16]) + "-" + String(h[16..<20]) + "-" + String(h[20..<32])
    }

    /// The path segment of every node in one sibling array.
    static func segments(_ siblings: [JSON]) -> [String] {
        let keys = siblings.enumerated().map { LegacySubtaskReference.childKey($1, index: $0) }
        var counts: [String: Int] = [:]
        for key in keys { counts[key, default: 0] += 1 }
        return keys.enumerated().map { counts[$1] == 1 ? $1 : "@\($0)" }
    }

    struct Skipped: Equatable, Sendable {
        /// Reasons: not_an_object, missing_title, empty_title, depth_over_32, id_collision.
        let path: [String]
        let reason: String
        /// Nodes below the skipped one that are skipped with it.
        let descendants: Int
        var json: JSON { .object(["path": .array(path.map(JSON.string)), "reason": .string(reason), "descendants": .number(Double(descendants))]) }
    }
    struct Reparented: Equatable, Sendable {
        let id: String
        let path: [String]
        let level: Int
        let parent: String
        var json: JSON { .object(["id": .string(id), "path": .array(path.map(JSON.string)), "level": .number(Double(level)), "parent": .string(parent)]) }
    }
    struct Result: Equatable, Sendable {
        /// Parents before children.
        var rows: [Record] = []
        var skipped: [Skipped] = []
        var reparented: [Reparented] = []
        var childIDs: [String] { rows.map(\.id) }
        /// The `skipped` column of `json_subtask_conversions`: skipped nodes and re-parented nodes.
        var skippedJSON: JSON { .object(["skipped": .array(skipped.map(\.json)), "reparented": .array(reparented.map(\.json))]) }
    }

    private static let textFields = ["title", "description", "completed_at", "due_date", "due_time", "time_zone", "scheduled_at", "deadline_date", "created_at", "assigned_to"]
    private static let flagFields = ["completed", "is_heading"]
    private static let numberFields = ["priority", "duration_minutes"]
    private static let listFields = ["labels", "comments", "attachments", "reminder_specs"]
    private static let handled = Set(textFields + flagFields + numberFields + listFields + ["id", "subtasks"])

    /// `canAssign` stands in for the server's `check_task_assignment`: an assignee survives only when it says so.
    /// Without a membership list the default keeps assignees of tasks that belong to a project.
    static func convert(root: Record, canAssign: (_ assignee: String, _ project: String) -> Bool = { _, project in !project.isEmpty }) -> Result {
        var result = Result()
        let rootID = root.id
        guard !rootID.isEmpty, case .array(let top) = root["subtasks"] else { return result }
        var used: Set<String> = [rootID.lowercased()], reparentCounter = 0
        func descendantCount(_ value: JSON) -> Int {
            guard case .object(let fields) = value, case .array(let rows)? = fields["subtasks"] else { return 0 }
            return rows.reduce(0) { $0 + 1 + descendantCount($1) }
        }
        func build(_ node: JSON, id: String, parent: String, order: Double, path: [String]) -> Record? {
            var row = Record()
            var extra: [String: JSON] = [:]
            switch node {
            case .string(let value): row["title"] = .string(value)
            case .object(let fields):
                guard case .string? = fields["title"] else { return nil }
                for (key, value) in fields.sorted(by: { $0.key < $1.key }) where value != .null {
                    if textFields.contains(key) { if case .string = value { row[key] = value } else { extra[key] = value } }
                    else if flagFields.contains(key) { if case .bool = value { row[key] = value } else { extra[key] = value } }
                    else if numberFields.contains(key) { if case .number = value { row[key] = value } else { extra[key] = value } }
                    else if listFields.contains(key) { if case .array = value { row[key] = value } else { extra[key] = value } }
                    else if key == "subtasks" { if case .array = value {} else { extra[key] = value } }
                    else if !handled.contains(key) { extra[key] = value }
                }
            default: return nil
            }
            for (key, fallback) in [("description", JSON.string("")), ("completed", .bool(false)), ("priority", .number(4)), ("labels", .array([])),
                                    ("comments", .array([])), ("attachments", .array([])), ("reminder_specs", .array([]))] where row.fields[key] == nil { row[key] = fallback }
            row["id"] = .string(id); row["parent_id"] = .string(parent); row["child_order"] = .number(order)
            row["user_id"] = root["user_id"]; row["project_id"] = root["project_id"]; row["section_id"] = root["section_id"]
            if row.fields["created_at"] == nil { row["created_at"] = root["created_at"] }
            row["is_recurring"] = .bool(false); row["reminders"] = .array([]); row["completion_version"] = .number(0)
            row["task_generation"] = .string(legacyChildID(root: rootID, path: path + ["generation"]))
            if case .string(let assignee)? = row.fields["assigned_to"], !canAssign(assignee, row.string("project_id")) { row["assigned_to"] = .null }
            row["source_metadata"] = .object(extra.isEmpty ? [:] : ["taskfold_legacy_child": .object(extra)])
            return row
        }
        func walk(_ siblings: [JSON], parent: String, level: Int, path: [String], anchor: String) {
            let names = segments(siblings)
            for (index, node) in siblings.enumerated() {
                let here = path + [names[index]]
                let id = legacyChildID(root: rootID, path: here)
                func skip(_ reason: String) { result.skipped.append(Skipped(path: here, reason: reason, descendants: descendantCount(node))) }
                if level > readableLevel { skip("depth_over_32"); continue }
                var parentID = parent, order = Double(index + 1)
                if level > maximumLevel { parentID = anchor; reparentCounter += 1; order = 1000 + Double(reparentCounter) }
                guard let row = build(node, id: id, parent: parentID, order: order, path: here) else {
                    var reason = "not_an_object"
                    if case .object = node { reason = "missing_title" }
                    skip(reason); continue
                }
                if row.string("title").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { skip("empty_title"); continue }
                guard used.insert(id).inserted else { skip("id_collision"); continue }
                result.rows.append(row)
                if level > maximumLevel { result.reparented.append(Reparented(id: id, path: here, level: level, parent: parentID)) }
                if case .object(let fields) = node, case .array(let nested)? = fields["subtasks"] {
                    // Children of a node at level 10 or deeper hang from the level-9 anchor, never from a level-10 node.
                    walk(nested, parent: id, level: level + 1, path: here, anchor: level == maximumLevel ? parent : anchor)
                }
            }
        }
        walk(top, parent: rootID, level: 1, path: [], anchor: rootID)
        return result
    }

    /// Maps a persisted `subtask:<base64 path>` reference (path = root id, then keys) to the new row id. With the
    /// root record, the answer is checked against the conversion and is nil when the node was not converted.
    static func newID(forReference reference: String, root: Record? = nil) -> String? {
        guard let path = LegacySubtaskReference.path(reference) else { return nil }
        let id = legacyChildID(root: path[0], path: Array(path.dropFirst()))
        if let root { return convert(root: root).rows.contains { $0.id == id } ? id : nil }
        return id
    }
}

/// Migration C drops `tasks.subtasks`. A row cached, or a change queued, before then may still carry an empty value;
/// it is removed wherever rows enter the workspace and wherever a change leaves for the server. A non-empty tree is
/// kept: only signed-out data saved before the update holds one, and that is converted into rows on load.
enum LegacySubtaskColumn {
    static let key = "subtasks"
    static func isEmpty(_ value: JSON?) -> Bool {
        guard let value else { return false }
        if value == .null { return true }
        if case .array(let items) = value { return items.isEmpty }
        return false
    }
    static func dropped(_ fields: [String: JSON]) -> [String: JSON] {
        guard isEmpty(fields[key]) else { return fields }
        var result = fields; result.removeValue(forKey: key); return result
    }
    static func dropped(_ row: Record) -> Record { isEmpty(row.fields[key]) ? Record(dropped(row.fields)) : row }
    static func dropped(_ rows: [Record]) -> [Record] {
        guard rows.contains(where: { isEmpty($0.fields[key]) }) else { return rows }
        return rows.map(dropped)
    }
    /// The task-row writers (POST, PATCH, DELETE, team lifecycle and edits) never send an empty `subtasks`.
    static func outbound(_ change: Mutation) -> Mutation {
        guard change.table == "tasks", change.teamCompletion == nil, change.teamTaskBatch == nil, change.organizationOrder == nil,
              isEmpty(change.fields[key]) || isEmpty(change.baseline?[key]) else { return change }
        var result = change
        result.fields = dropped(change.fields)
        if let baseline = change.baseline { result.baseline = dropped(baseline) }
        return result
    }
}
