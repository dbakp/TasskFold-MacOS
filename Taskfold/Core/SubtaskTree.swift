import Foundation

/// Checklist operations retain every field and move whole branches by identity.
enum SubtaskTree {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static let maximumDepth = 10
    static let readableDepth = 32
    static func referencePath(_ id: String) -> [String]? {
        guard id.hasPrefix("subtask:"), let data = Data(base64Encoded: String(id.dropFirst(8))),
              let path = try? JSONDecoder().decode([String].self, from: data), (2...readableDepth + 1).contains(path.count), path.allSatisfy({ !$0.isEmpty }) else { return nil }
        return path
    }
    static func reference(parent: String, key: String) -> String {
        let path = (referencePath(parent) ?? [parent]) + [key]
        return "subtask:" + (try! JSONEncoder().encode(path)).base64EncodedString()
    }
    static let childQuickEntryExclusions: Set<String> = ["project_id", "section_id", "labels", "recurrence", "reminder_specs"]
    /// Context is visible in the editor but ownership and containment remain on the parent.
    static func detailDraft(_ child: Record, project: String) -> Record {
        var result = child; result["project_id"] = project.isEmpty ? .null : .string(project)
        return result
    }
    static func detailChanges(original: Record, edited: Record, current: Record) throws -> Record {
        guard !original.id.isEmpty, original.id == edited.id, current.id == original.id else {
            throw Failure(message: "This subtask changed. Reopen its current details before saving.")
        }
        let editable: Set<String> = ["title", "description", "completed", "completed_at", "priority", "due_date", "due_time", "time_zone", "scheduled_at", "deadline_date", "duration_minutes", "assigned_to", "labels", "subtasks", "comments", "attachments"]
        var fields = edited.fields.filter { editable.contains($0.key) && original.fields[$0.key] != $0.value }
        if let title = fields["title"] {
            let value = title.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw Failure(message: "Give the subtask a name.") }
            fields["title"] = .string(value)
        }
        for key in ["due_date", "deadline_date"] {
            if let value = fields[key], value != .null, !value.text.isEmpty {
                guard case .string = value, Dates.parse(value.text) != nil else { throw Failure(message: "Choose a valid date for the subtask.") }
            }
        }
        if let estimate = fields["duration_minutes"], estimate != .null {
            guard case .number(let minutes) = estimate, minutes.rounded() == minutes, (1...10080).contains(minutes) else { throw Failure(message: "Choose an estimate between 1 minute and 7 days.") }
        }
        if let priority = fields["priority"], priority != .null {
            guard case .number(let value) = priority, value.rounded() == value, (1...4).contains(value) else { throw Failure(message: "Choose a priority between 1 and 4.") }
        }
        if let time = fields["due_time"], time != .null, !time.text.isEmpty {
            let parts = time.text.split(separator: ":", omittingEmptySubsequences: false)
            guard case .string = time, parts.count == 2, parts.allSatisfy({ $0.count == 2 }), let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour), (0...59).contains(minute) else { throw Failure(message: "Choose a valid time for the subtask.") }
        }
        if let zone = fields["time_zone"], zone != .null, !zone.text.isEmpty {
            guard case .string = zone, TimeZone(identifier: zone.text) != nil else { throw Failure(message: "Choose a valid time zone for the subtask.") }
        }
        fields = TaskPlanning.fields(fields, existing: current)
        var result = current
        for (key, value) in fields { result[key] = value }
        return result
    }
    static func path(_ value: JSON, id: String) -> [String]? {
        let rows = Dictionary(uniqueKeysWithValues: outline(value).map { ($0.id, $0) })
        guard var item = rows[id] else { return nil }
        var result = [item.id], seen: Set<String> = [item.id]
        while let parent = item.parent {
            guard seen.insert(parent).inserted, let row = rows[parent] else { return nil }
            result.insert(parent, at: 0); item = row
        }
        return result
    }
    struct Item: Identifiable {
        let record: Record
        let parent: String?
        let depth: Int
        var id: String { record.id }
    }
    enum Move { case up, down, indent, outdent }

    static func prepared(_ value: JSON) throws -> JSON {
        guard value == .null || { if case .array = value { return true }; return false }() else {
            throw Failure(message: "This checklist uses an unsupported format. Your saved subtasks are unchanged.")
        }
        var seen = Set<String>()
        func normalize(_ values: [JSON], depth: Int) throws -> [JSON] {
            guard depth <= 32 else { throw Failure(message: "This checklist is too deeply nested to organize here.") }
            return try values.map { value in
                guard case .object(var fields) = value, case .string? = fields["title"] else {
                    throw Failure(message: "A subtask uses an unsupported format. Your saved subtasks are unchanged.")
                }
                if let identity = fields["id"], identity != .null {
                    guard case .string = identity else { throw Failure(message: "A subtask identity is malformed. Your saved subtasks are unchanged.") }
                }
                let id = fields["id"]?.text ?? ""
                guard id.isEmpty || seen.insert(id).inserted else { throw Failure(message: "This checklist contains duplicate subtask identities. Your saved subtasks are unchanged.") }
                if id.isEmpty { let fresh = UUID().uuidString.lowercased(); fields["id"] = .string(fresh); seen.insert(fresh) }
                if let children = fields["subtasks"], children != .null {
                    guard case .array(let rows) = children else { throw Failure(message: "A nested checklist uses an unsupported format.") }
                    fields["subtasks"] = .array(try normalize(rows, depth: depth + 1))
                }
                return .object(fields)
            }
        }
        return .array(try normalize(value.list, depth: 0))
    }

    static func outline(_ value: JSON) -> [Item] {
        var result: [Item] = []
        func visit(_ rows: [JSON], parent: String?, depth: Int) {
            guard depth <= 32 else { return }
            for value in rows {
                let row = Record(value.object)
                result.append(Item(record: row, parent: parent, depth: depth))
                visit(row["subtasks"].list, parent: row.id, depth: depth + 1)
            }
        }
        visit(value.list, parent: nil, depth: 0)
        return result
    }
    static func progress(_ value: JSON) -> (completed: Int, total: Int) {
        let items = outline(value)
        return (items.filter { $0.record.completed }.count, items.count)
    }
    static func changing(_ value: JSON, id: String, fields: [String: JSON]) -> JSON {
        .array(value.list.map { value in
            var row = value.object
            if row["id"]?.text == id { row.merge(fields) { _, new in new } }
            else if case .array? = row["subtasks"] { row["subtasks"] = changing(row["subtasks"]!, id: id, fields: fields) }
            return .object(row)
        })
    }
    private static func siblings(_ value: JSON, parent: String?) -> [JSON] {
        guard let parent else { return value.list }
        return outline(value).first { $0.id == parent }?.record["subtasks"].list ?? []
    }
    private static func replacing(_ value: JSON, parent: String?, rows: [JSON]) -> JSON {
        guard let parent else { return .array(rows) }
        return changing(value, id: parent, fields: ["subtasks": .array(rows)])
    }
    static func removing(_ value: JSON, id: String) -> JSON {
        guard let item = outline(value).first(where: { $0.id == id }) else { return value }
        return replacing(value, parent: item.parent, rows: siblings(value, parent: item.parent).filter { $0.object["id"]?.text != id })
    }
    static func adding(_ value: JSON, title: String, parent: String? = nil, baseDepth: Int = 0) throws -> JSON {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw Failure(message: "Give the subtask a name.") }
        guard baseDepth >= 0, baseDepth < maximumDepth else { throw Failure(message: "Subtasks can be nested up to 10 levels.") }
        if let parent {
            guard let item = outline(value).first(where: { $0.id == parent }), item.depth + baseDepth + 1 < maximumDepth else {
                throw Failure(message: "Subtasks can be nested up to 10 levels.")
            }
        }
        let row: JSON = .object(["id": .string(UUID().uuidString.lowercased()), "title": .string(title), "completed": .bool(false)])
        return replacing(value, parent: parent, rows: siblings(value, parent: parent) + [row])
    }
    static func moving(_ value: JSON, id: String, direction: Move, baseDepth: Int = 0) throws -> JSON {
        let items = outline(value)
        guard let item = items.first(where: { $0.id == id }) else { throw Failure(message: "This subtask is no longer available.") }
        var rows = siblings(value, parent: item.parent)
        guard let index = rows.firstIndex(where: { $0.object["id"]?.text == id }) else { return value }
        switch direction {
        case .up, .down:
            let target = index + (direction == .up ? -1 : 1)
            guard rows.indices.contains(target) else { throw Failure(message: "The subtask is already at the edge of this checklist.") }
            rows.swapAt(index, target)
            return replacing(value, parent: item.parent, rows: rows)
        case .indent:
            guard index > 0 else { throw Failure(message: "Move this subtask below another subtask before indenting it.") }
            let height = (outline(item.record["subtasks"]).map(\.depth).max().map { $0 + 1 }) ?? 0
            guard baseDepth + item.depth + height + 1 < maximumDepth else { throw Failure(message: "Subtasks can be nested up to 10 levels.") }
            var previous = rows[index - 1].object
            previous["subtasks"] = .array((previous["subtasks"]?.list ?? []) + [rows[index]])
            rows[index - 1] = .object(previous); rows.remove(at: index)
            return replacing(value, parent: item.parent, rows: rows)
        case .outdent:
            guard let parentID = item.parent, let parent = items.first(where: { $0.id == parentID }) else {
                throw Failure(message: "This subtask is already at the top level.")
            }
            let branch = rows.remove(at: index)
            var result = replacing(value, parent: parentID, rows: rows)
            var uncles = siblings(result, parent: parent.parent)
            guard let parentIndex = uncles.firstIndex(where: { $0.object["id"]?.text == parentID }) else { return value }
            uncles.insert(branch, at: parentIndex + 1)
            result = replacing(result, parent: parent.parent, rows: uncles)
            return result
        }
    }

    /// Rebase fields by identity even when a child has moved to another parent.
    /// An explicitly reviewed local layout wins; remote-only children are retained.
    static func rebased(base: JSON, desired: JSON, remote: JSON) -> JSON? {
        let values = [base, desired, remote].map { $0 == .null ? JSON.array([]) : $0 }
        guard values.allSatisfy({ (try? prepared($0)) == $0 }) else { return nil }
        let lists = values.map(outline)
        let maps = lists.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.id, $0) }) }
        let before = maps[0], after = maps[1], current = maps[2]
        func layout(_ rows: [Item]) -> [String] { rows.map { ($0.parent ?? "") + ":" + $0.id } }
        let shared = Set(before.keys).intersection(after.keys)
        let localLayoutChanged = layout(lists[0].filter { shared.contains($0.id) }) != layout(lists[1].filter { shared.contains($0.id) })
        let deleted = Set(before.keys).subtracting(after.keys)
        var ids = Set(current.keys).subtracting(deleted)
        for row in lists[1] where before[row.id] == nil || before[row.id]?.record != row.record || before[row.id]?.parent != row.parent {
            ids.insert(row.id)
            var parent = row.parent
            while let id = parent, let ancestor = after[id] { ids.insert(id); parent = ancestor.parent }
        }
        // Follow one valid source tree for each parent chain, so competing moves
        // cannot create a cycle or duplicate the same child under two parents.
        let preferred = localLayoutChanged ? after : current
        let fallback = localLayoutChanged ? current : after
        func parent(_ id: String) -> String? {
            var next = preferred[id]?.parent ?? (preferred[id] == nil ? fallback[id]?.parent : nil)
            var seen: Set<String> = [id]
            while let candidate = next {
                guard seen.insert(candidate).inserted else { return nil }
                if ids.contains(candidate) { return candidate }
                next = preferred[candidate]?.parent ?? (preferred[candidate] == nil ? fallback[candidate]?.parent : nil)
            }
            return nil
        }
        var parents = Dictionary(uniqueKeysWithValues: ids.map { ($0, parent($0) ?? "") })
        // A remote-only node may attach beneath a locally moved known node.
        // If that combination closes a cycle, retain the node at the top level.
        for id in ids.sorted() {
            var cursor = id, seen = Set<String>()
            while !cursor.isEmpty {
                if !seen.insert(cursor).inserted { parents[id] = ""; break }
                cursor = parents[cursor] ?? ""
            }
        }
        let ordering = localLayoutChanged ? lists[1] + lists[2] : lists[2] + lists[1]
        var order: [String] = [], seen = Set<String>()
        for item in ordering where ids.contains(item.id) && seen.insert(item.id).inserted { order.append(item.id) }
        func render(_ parent: String, depth: Int) -> [JSON] {
            guard depth <= 64 else { return [] }
            return order.filter { parents[$0] == parent }.map { id in
                let old = before[id]?.record, local = after[id]?.record, saved = current[id]?.record
                func fields(_ row: Record?) -> JSON { .object((row?.fields ?? [:]).filter { $0.key != "subtasks" }) }
                let merged: JSON
                if let local, let old, saved != nil { merged = TaskEdit.keepingLocal(base: fields(old), desired: fields(local), remote: fields(saved)) }
                else { merged = fields(saved ?? local) }
                var result = merged.object
                let children = render(id, depth: depth + 1)
                let source = (localLayoutChanged ? local ?? saved : saved ?? local)?["subtasks"] ?? .null
                if !children.isEmpty || source != .null { result["subtasks"] = .array(children) }
                else if (saved ?? local)?.fields["subtasks"] != nil { result["subtasks"] = .null }
                return .object(result)
            }
        }
        return .array(render("", depth: 0))
    }
}

/// Read-only identities for independently queried checklist items. These projections
/// never become backend task rows; every edit is translated into its current root.
struct TaskHierarchyIndex {
    enum Scope { case all, roots, subtasks, parents }
    struct Item: Equatable, Sendable {
        let source: Record
        let root: Record
        let path: [String]
        let parentTitles: [String]
        let id: String
        var isSubtask: Bool { !path.isEmpty }
        var isParent: Bool { !source["subtasks"].list.isEmpty }
        /// Only containment is inherited. A child's dates, labels, assignment,
        /// priority and completion remain its own recorded values.
        var record: Record {
            guard isSubtask else { return source }
            var result = source; result["id"] = .string(id)
            for field in ["project_id", "section_id", "user_id"] { result[field] = root[field] }
            return result
        }
    }
    struct Selection: Equatable, Sendable {
        let item: Item
        let workspace: WorkspaceBinding
    }
    enum Edit {
        case patch(Selection, [String: JSON])
        case delete(Selection)
        var selection: Selection { switch self { case .patch(let value, _), .delete(let value): return value } }
        var replacesBranch: Bool {
            switch self { case .delete: return true; case .patch(_, let fields): return fields["subtasks"] != nil }
        }
        static func completion(_ selection: Selection, completed: Bool, at date: Date = Date()) -> Edit {
            .patch(selection, ["completed": .bool(completed), "completed_at": completed ? .string(ISO8601DateFormatter().string(from: date)) : .null])
        }
    }
    static let maximumItems = 100_000
    static let maximumEdits = 1_000
    static let maximumReferenceBytes = 32 * 1_024 * 1_024
    private(set) var items: [Item] = []
    private(set) var excludedRootIDs = Set<String>()
    let workspace: WorkspaceBinding
    private var positions: [String: Int] = [:]
    private static let editable: Set<String> = ["title", "description", "completed", "completed_at", "priority", "due_date", "due_time", "time_zone", "scheduled_at", "deadline_date", "duration_minutes", "assigned_to", "labels", "subtasks", "comments", "attachments"]
    private static func failure(_ message: String) -> SubtaskTree.Failure { SubtaskTree.Failure(message: message) }
    private static func validIdentity(_ id: String) -> Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && id.unicodeScalars.count <= 400 && !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    init(roots: [Record], projects: [Record], workspace: WorkspaceBinding) throws {
        guard !workspace.account.isEmpty else { throw Self.failure("Open a workspace before filtering subtasks.") }
        guard roots.count <= Self.maximumItems else { throw Self.failure("This task hierarchy is too large to filter here.") }
        self.workspace = workspace
        let projectGroups = Dictionary(grouping: projects, by: \.id)
        let hidden = ProjectOrganization.archivedIDs(in: projects)
        var rootIDs = Set<String>(), referenceBytes = 0
        for root in roots {
            guard Self.validIdentity(root.id), !root.id.hasPrefix("subtask:"), rootIDs.insert(root.id).inserted else {
                throw Self.failure("Task identities are unavailable. Refresh your tasks before filtering subtasks.")
            }
            let project = root.string("project_id")
            guard project.isEmpty || (projectGroups[project]?.count == 1 && !hidden.contains(project)) else {
                excludedRootIDs.insert(root.id); continue
            }
            var childIDs = Set<String>()
            func visit(_ source: Record, path: [String], parents: [String], reference: String) throws {
                guard path.count <= SubtaskTree.readableDepth, items.count < Self.maximumItems, reference.utf8.count <= Self.maximumReferenceBytes - referenceBytes else {
                    throw Self.failure("This task hierarchy is too large or deeply nested to filter here. Your saved tasks are unchanged.")
                }
                referenceBytes += reference.utf8.count
                let item = Item(source: source, root: root, path: path, parentTitles: parents, id: reference)
                positions[item.id] = items.count; items.append(item)
                let children = source["subtasks"]
                guard children == .null || { if case .array = children { return true }; return false }() else {
                    throw Self.failure("A checklist uses an unsupported format. Open its parent task to review it.")
                }
                for child in children.list {
                    guard case .object(let fields) = child, case .string(let id)? = fields["id"],
                          Self.validIdentity(id),
                          case .string? = fields["title"], childIDs.insert(id).inserted else {
                        throw Self.failure("A checklist needs stable subtask identities. Open its parent task, save the subtask organizer, then try again.")
                    }
                    try visit(Record(fields), path: path + [id], parents: parents + [source.title], reference: SubtaskTree.reference(parent: item.id, key: id))
                }
            }
            try visit(root, path: [], parents: [], reference: root.id)
        }
    }
    func item(_ id: String) -> Item? { positions[id].map { items[$0] } }
    func selection(_ id: String) -> Selection? { item(id).map { Selection(item: $0, workspace: workspace) } }
    func records(in scope: Scope, includeCompleted: Bool = false) -> [Record] {
        items.filter { item in
            guard includeCompleted || !item.source.completed else { return false }
            switch scope { case .all: return true; case .roots: return !item.isSubtask; case .subtasks: return item.isSubtask; case .parents: return item.isParent }
        }.map(\.record)
    }

    /// All requests validate before a mutation is returned. Siblings coalesce into
    /// one root patch, preserving the normal durable queue and Undo transaction.
    static func changes(_ edits: [Edit], accessibleRoots: [Record], projects: [Record], workspace: WorkspaceBinding) throws -> [Mutation] {
        guard !edits.isEmpty else { return [] }
        guard edits.count <= maximumEdits else { throw failure("Select up to 1,000 subtasks at a time.") }
        guard !workspace.account.isEmpty,
              edits.allSatisfy({ $0.selection.workspace == workspace && $0.selection.item.isSubtask }) else {
            throw failure("This workspace changed. Reopen the subtask before editing it.")
        }
        let rootIDs = Set(edits.map { $0.selection.item.root.id })
        let current = try TaskHierarchyIndex(roots: accessibleRoots.filter { rootIDs.contains($0.id) }, projects: projects, workspace: workspace)
        var references = Set<String>()
        for (index, edit) in edits.enumerated() {
            let saved = edit.selection.item
            guard references.insert(saved.id).inserted, let now = current.item(saved.id),
                  now.root["task_generation"] == saved.root["task_generation"], now.root["created_at"] == saved.root["created_at"],
                  now.root["project_id"] == saved.root["project_id"], now.root["section_id"] == saved.root["section_id"] else {
                throw failure("This task moved, was replaced or is no longer accessible. Reopen its current details.")
            }
            for other in edits.prefix(index) where other.selection.item.root.id == saved.root.id {
                let oldPath = other.selection.item.path
                if (other.replacesBranch && saved.path.starts(with: oldPath)) || (edit.replacesBranch && oldPath.starts(with: saved.path)) {
                    throw failure("Select the parent or its descendants for a branch edit, then try again.")
                }
            }
            switch edit {
            case .delete:
                guard now.source == saved.source else { throw failure("This subtask changed. Review its current content before deleting it.") }
            case .patch(_, let fields):
                guard Set(fields.keys).isSubset(of: editable) else { throw failure("A subtask keeps its parent's project and section. Open the parent to move the whole task.") }
                for (field, desired) in fields where now.source[field] != saved.source[field] && now.source[field] != desired {
                    throw failure("This subtask changed while you were editing it. Reopen its current details to keep both versions.")
                }
                if fields["completed"] != nil || fields["completed_at"] != nil {
                    guard case .bool(let completed)? = fields["completed"], let stamp = fields["completed_at"],
                          completed ? (stamp.text.isEmpty == false && ISO8601DateFormatter().date(from: stamp.text) != nil) : stamp == .null else {
                        throw failure("Choose a valid subtask completion state and timestamp.")
                    }
                }
            }
        }
        let roots = Dictionary(current.items.filter { !$0.isSubtask }.map { ($0.root.id, $0.root) }, uniquingKeysWith: { first, _ in first })
        var updated = roots
        for edit in edits {
            let item = edit.selection.item
            guard let root = updated[item.root.id], let working = source(in: root, path: item.path) else { throw failure("This subtask is no longer accessible.") }
            let replacement: Record?
            switch edit {
            case .delete: replacement = nil
            case .patch(_, let fields):
                var edited = item.source
                for (field, value) in fields { edited[field] = value }
                replacement = try SubtaskTree.detailChanges(original: item.source, edited: edited, current: working)
            }
            guard let changed = replacing(root, path: item.path, value: replacement) else { throw failure("This subtask moved. Reopen its current details.") }
            updated[item.root.id] = changed
        }
        // A branch edit may introduce new children. Never return a mutation
        // whose resulting identities or depth cannot be queried safely.
        _ = try TaskHierarchyIndex(roots: Array(updated.values), projects: projects, workspace: workspace)
        return rootIDs.sorted().compactMap { id in
            guard let original = roots[id], let changed = updated[id], changed["subtasks"] != original["subtasks"] else { return nil }
            let fields = ["subtasks": changed["subtasks"]]
            return Mutation(table: "tasks", recordID: id, method: "PATCH", fields: fields, baseline: TaskCompletionRevision.editBaseline(for: fields, from: original))
        }
    }
    private static func source(in root: Record, path: [String]) -> Record? {
        var value = root
        for key in path {
            guard let child = value["subtasks"].list.first(where: { $0.object["id"] == .string(key) }) else { return nil }
            value = Record(child.object)
        }
        return value
    }
    private static func replacing(_ root: Record, path: [String], value: Record?) -> Record? {
        guard let key = path.first else { return value }
        var list = root["subtasks"].list
        guard let index = list.firstIndex(where: { $0.object["id"] == .string(key) }) else { return nil }
        if path.count == 1 { if let value { list[index] = .object(value.fields) } else { list.remove(at: index) } }
        else {
            guard let child = replacing(Record(list[index].object), path: Array(path.dropFirst()), value: value) else { return nil }
            list[index] = .object(child.fields)
        }
        var result = root; result["subtasks"] = .array(list); return result
    }
}
