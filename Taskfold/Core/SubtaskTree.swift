import Foundation

/// Checklist operations retain every field and move whole branches by identity.
enum SubtaskTree {
    struct Failure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }
    static func hasListContainer(_ value: JSON) -> Bool { if value == .null { return true }; if case .array = value { return true }; return false }
    static func inlineEditable(_ value: JSON) -> Bool { if case .object(let fields) = value, case .string? = fields["title"] { return true }; return false }
    static func inlineTitle(_ value: JSON) -> String { if case .string(let text) = value { return text }; return value.object["title"]?.text ?? "" }
    static func childKey(_ value: JSON, index: Int) -> String { value.object["id"]?.text.isEmpty == false ? value.object["id"]!.text : "@\(index)" }
    /// Legacy positional paths remain readable, but neither duplicated references
    /// nor unknown/text-only nodes may become an arbitrary editable child.
    static func uniqueChildIndex(_ value: JSON, key: String) -> Int? {
        guard case .array(let rows) = value else { return nil }
        var found: Int?
        for (index, row) in rows.enumerated() where childKey(row, index: index) == key {
            guard found == nil, inlineEditable(row) else { return nil }; found = index
        }
        return found
    }
    /// One pass for a whole rendered inspector, instead of rescanning all siblings
    /// for each row's enabled state.
    static func uniqueChildIndices(_ value: JSON) -> [String: Int] {
        guard case .array(let rows) = value else { return [:] }
        var counts: [String: Int] = [:], result: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            let key = childKey(row, index: index)
            counts[key, default: 0] += 1
            if counts[key] == 1 && inlineEditable(row) { result[key] = index } else { result[key] = nil }
        }
        return result
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
        guard hasListContainer(value) else { throw Failure(message: "Open Organize subtasks to review this checklist before adding items. Its original content is unchanged.") }
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
            for field in ["project_id", "section_id", "user_id", "task_generation"] { result[field] = root[field] }
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
        /// Native editors receive a contextual projection, never a new backend row.
        static func editing(_ selection: Selection, draft: Record, at date: Date = Date()) throws -> Edit {
            let original = selection.item.record
            guard selection.item.isSubtask, draft.id == original.id else { throw TaskHierarchyIndex.failure("This subtask changed. Reopen its current details.") }
            let keys = Set(original.fields.keys).union(draft.fields.keys).filter { original.fields[$0] != draft.fields[$0] }
            guard keys.isSubset(of: TaskHierarchyIndex.editable) else { throw TaskHierarchyIndex.failure("A subtask keeps its parent's identity, project and section. Reopen its current details.") }
            var fields = Dictionary(uniqueKeysWithValues: keys.map { ($0, draft[$0]) })
            if let state = fields["completed"] {
                guard case .bool(let completed) = state else { throw TaskHierarchyIndex.failure("Choose a valid subtask completion state.") }
                fields["completed_at"] = completed ? .string(ISO8601DateFormatter().string(from: date)) : .null
            }
            return .patch(selection, fields)
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
        ChecklistRecovery.validIdentity(id)
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
                    guard TaskKind.mayComplete(now.source) else { throw failure("Headings stay open. Select tasks to complete.") }
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

/// List actions use the same captured rows on both platforms. Virtual child rows
/// become root subtree patches; overlapping destructive selections never clobber
/// an independently requested edit, and root recurrence keeps its existing engine.
enum TaskSelectionPlan {
    enum Action {
        case patch([String: JSON]), completion(Bool, Date), delete
    }
    struct Request {
        var task: Record
        var action: Action
        var workspace: WorkspaceBinding
    }
    private static func failure(_ message: String) -> SubtaskTree.Failure { .init(message: message) }
    static func changes(_ requests: [Request], accessibleRoots: [Record], projects: [Record], workspace: WorkspaceBinding, calendar: Calendar = .current) throws -> [Mutation] {
        guard !requests.isEmpty else { return [] }
        guard requests.count <= TaskHierarchyIndex.maximumEdits else { throw failure("Select up to 1,000 tasks at a time.") }
        guard !workspace.account.isEmpty, requests.allSatisfy({ $0.workspace == workspace }), Set(requests.map { $0.task.id }).count == requests.count else {
            throw failure("This selection or workspace changed. Select the tasks again.")
        }
        let grouped = Dictionary(grouping: accessibleRoots, by: \.id)
        let projectGroups = Dictionary(grouping: projects, by: \.id)
        let archived = ProjectOrganization.archivedIDs(in: projects)
        func rootID(_ row: Record) throws -> String {
            if let path = SubtaskTree.referencePath(row.id) { return path[0] }
            guard !row.id.isEmpty, !row.id.hasPrefix("subtask:") else { throw failure("This task reference is unavailable. Refresh the list.") }
            return row.id
        }
        var roots: [String: Record] = [:], childRootIDs = Set<String>()
        for request in requests {
            let id = try rootID(request.task)
            guard let rows = grouped[id], rows.count == 1, let root = rows.first,
                  root["task_generation"] == request.task["task_generation"] else { throw failure("A selected task was replaced or is no longer accessible. Select it again.") }
            let project = root.string("project_id")
            guard project.isEmpty || (projectGroups[project]?.count == 1 && !archived.contains(project)) else { throw failure("A selected project is no longer accessible. Refresh the list.") }
            roots[id] = root
            if SubtaskTree.referencePath(request.task.id) != nil { childRootIDs.insert(id) }
        }
        let index = try TaskHierarchyIndex(roots: roots.values.filter { childRootIDs.contains($0.id) }, projects: projects, workspace: workspace)
        var selectedChildren: [String: TaskHierarchyIndex.Selection] = [:]
        var rootRequests: [String: Request] = [:]
        for request in requests {
            let row = request.task
            if case .completion = request.action {
                let current = SubtaskTree.referencePath(row.id) != nil ? index.item(row.id)?.source : roots[row.id]
                guard let current, TaskKind.mayComplete(current) else { throw failure("Headings stay open. Select tasks to complete.") }
            }
            if SubtaskTree.referencePath(row.id) != nil {
                guard let selected = index.selection(row.id), selected.item.record == row else { throw failure("A selected subtask changed. Select its current row again.") }
                selectedChildren[row.id] = selected
            } else {
                guard let root = roots[row.id], root["created_at"] == row["created_at"], root["project_id"] == row["project_id"], root["section_id"] == row["section_id"] else { throw failure("A selected task moved. Select its current row again.") }
                if case .delete = request.action, root != row { throw failure("A selected task changed. Review its current content before deleting it.") }
                if case .completion(let completed, _) = request.action, root.completed != completed,
                   (root.completed != row.completed || root["completion_version"].integer != row["completion_version"].integer) {
                    throw failure("Task completion changed. Select its current row again.")
                }
                rootRequests[row.id] = request
            }
        }
        func isDelete(_ action: Action) -> Bool { if case .delete = action { return true }; return false }
        var childEdits: [TaskHierarchyIndex.Edit] = []
        for request in requests {
            guard let selected = selectedChildren[request.task.id] else { continue }
            if let rootRequest = rootRequests[selected.item.root.id], isDelete(rootRequest.action) {
                guard isDelete(request.action) else { throw failure("Choose a branch deletion or an edit to its children, then try again.") }
                continue
            }
            let deletingAncestor = requests.first { other in
                guard other.task.id != request.task.id, isDelete(other.action), let parent = selectedChildren[other.task.id] else { return false }
                return parent.item.root.id == selected.item.root.id && selected.item.path.starts(with: parent.item.path)
            }
            if deletingAncestor != nil {
                guard isDelete(request.action) else { throw failure("Choose a branch deletion or an edit to its children, then try again.") }
                continue
            }
            switch request.action {
            case .delete: childEdits.append(.delete(selected))
            case .completion(let completed, let date): childEdits.append(.completion(selected, completed: completed, at: date))
            case .patch(let fields): childEdits.append(.patch(selected, fields))
            }
        }
        let childChanges = try TaskHierarchyIndex.changes(childEdits, accessibleRoots: Array(roots.values), projects: projects, workspace: workspace)
        var working = roots
        for change in childChanges { working[change.recordID]?["subtasks"] = change.fields["subtasks"] ?? .null }
        var deleted = Set<String>(), extras: [Mutation] = []
        var completionIDs: [String: UUID] = [:]
        var prospective = accessibleRoots.map { working[$0.id] ?? $0 }
        let allowedRootFields: Set<String> = ["title", "description", "priority", "due_date", "due_time", "time_zone", "scheduled_at", "deadline_date", "duration_minutes", "assigned_to", "labels", "project_id", "section_id"]
        for id in rootRequests.keys.sorted() {
            guard let request = rootRequests[id], let original = roots[id], var value = working[id] else { continue }
            switch request.action {
            case .delete: deleted.insert(id)
            case .patch(let fields):
                guard Set(fields.keys).isSubset(of: allowedRootFields) else { throw failure("This list action needs the task's detail editor.") }
                for (key, desired) in fields where original[key] != request.task[key] && original[key] != desired { throw failure("A selected field changed. Review the current task before applying this action.") }
                for key in ["project_id", "section_id"] {
                    if let field = fields[key], field != .null {
                        guard case .string(let id) = field, !id.isEmpty else { throw failure("Choose a valid project or section.") }
                    }
                }
                var desired = value
                for (key, field) in fields { desired[key] = field }
                // Reuse native detail validation for common planning/priority fields.
                value = try SubtaskTree.detailChanges(original: value, edited: desired, current: value)
                for key in ["project_id", "section_id"] where fields[key] != nil { value[key] = desired[key] }
                let target = value.string("project_id")
                guard target.isEmpty || (projectGroups[target]?.count == 1 && !archived.contains(target)) else { throw failure("Choose an accessible project.") }
                working[id] = value
            case .completion(let completed, let date):
                if value.completed != completed {
                    let changes = TaskCompletion.toggle(value, tasks: prospective, at: date, calendar: calendar, account: workspace.account)
                    for change in changes {
                        if change.recordID == id, change.method == "PATCH" { completionIDs[id] = change.id; for (key, field) in change.fields { value[key] = field } }
                        else { extras.append(change); if change.method == "POST" { prospective.append(Record(change.fields)) } }
                    }
                    working[id] = value
                }
            }
            if let position = prospective.firstIndex(where: { $0.id == id }), let value = working[id] { prospective[position] = value }
        }
        var result: [Mutation] = []
        for id in roots.keys.sorted() {
            guard let before = roots[id], let after = working[id] else { continue }
            if deleted.contains(id) { result.append(Mutation(table: "tasks", recordID: id, method: "DELETE", fields: [:], baseline: before.fields)); continue }
            let fields = after.fields.filter { before.fields[$0.key] != $0.value }
            if !fields.isEmpty {
                var mutation = Mutation(table: "tasks", recordID: id, method: "PATCH", fields: fields, baseline: TaskCompletionRevision.editBaseline(for: fields, from: before))
                if let identity = completionIDs[id] { mutation.id = identity }
                result.append(mutation)
            }
        }
        return result + extras
    }
}

extension TaskSelectionPlan {
    /// A selected branch is copied once. Child copies stay beside their source;
    /// copying a main task creates a fresh root and fresh nested identities.
    static func duplicateChanges(_ tasks: [Record], accessibleRoots: [Record], projects: [Record], workspace: WorkspaceBinding, at date: Date = Date()) throws -> [Mutation] {
        let requests = tasks.map { Request(task: $0, action: .patch([:]), workspace: workspace) }
        _ = try changes(requests, accessibleRoots: accessibleRoots, projects: projects, workspace: workspace)
        guard !tasks.isEmpty else { return [] }
        let selectedRoots = Set(tasks.filter { SubtaskTree.referencePath($0.id) == nil }.map(\.id))
        let wantedRoots = Set(tasks.map { SubtaskTree.referencePath($0.id)?.first ?? $0.id })
        let roots = Dictionary(accessibleRoots.filter { wantedRoots.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let childTasks = tasks.filter { SubtaskTree.referencePath($0.id) != nil }
        let childRootIDs = Set(childTasks.compactMap { SubtaskTree.referencePath($0.id)?.first })
        let index = try TaskHierarchyIndex(roots: roots.values.filter { childRootIDs.contains($0.id) }, projects: projects, workspace: workspace)
        var working = roots, inserts: [Mutation] = [], count = 0
        func freshChildren(_ value: JSON, depth: Int = 1) throws -> JSON {
            guard value == .null || { if case .array = value { return true }; return false }() else { throw failure("This checklist uses an unsupported format. Open its parent before duplicating it.") }
            return .array(try value.list.map { node in
                guard depth <= SubtaskTree.readableDepth, case .object(let fields) = node, case .string? = fields["title"], count < TaskHierarchyIndex.maximumItems else { throw failure("This checklist is too large or uses an unsupported format to duplicate.") }
                count += 1; var row = Record(fields)
                row["id"] = .string(UUID().uuidString.lowercased()); row["completed"] = .bool(false); row["completed_at"] = .null
                if row.fields["task_generation"] != nil { row["task_generation"] = .string(UUID().uuidString.lowercased()) }
                row["subtasks"] = try freshChildren(row["subtasks"], depth: depth + 1)
                return .object(row.fields)
            })
        }
        func insert(_ root: Record, path: [String], copy: JSON) -> Record? {
            guard let key = path.first else { return nil }
            var list = root["subtasks"].list
            guard let position = list.firstIndex(where: { $0.object["id"] == .string(key) }) else { return nil }
            if path.count == 1 { list.insert(copy, at: position + 1) }
            else {
                guard let updated = insert(Record(list[position].object), path: Array(path.dropFirst()), copy: copy) else { return nil }
                list[position] = .object(updated.fields)
            }
            var updated = root; updated["subtasks"] = .array(list); return updated
        }
        for task in tasks {
            if let path = SubtaskTree.referencePath(task.id) {
                if selectedRoots.contains(path[0]) { continue }
                let selectedPath = Array(path.dropFirst())
                if childTasks.contains(where: { other in
                    guard other.id != task.id, let parent = SubtaskTree.referencePath(other.id), parent[0] == path[0] else { return false }
                    return selectedPath.starts(with: parent.dropFirst())
                }) { continue }
                guard let original = index.item(task.id), let current = working[path[0]] else { throw failure("A selected subtask moved. Select its current row again.") }
                let copy = try freshChildren(.array([.object(original.source.fields)]), depth: selectedPath.count).list[0]
                guard let updated = insert(current, path: selectedPath, copy: copy) else { throw failure("A selected subtask moved. Select its current row again.") }
                working[path[0]] = updated
            } else {
                guard let original = roots[task.id], original == task else { throw failure("A selected task changed. Review its current content before duplicating it.") }
                var copy = original
                copy["id"] = .string(UUID().uuidString.lowercased()); copy["task_generation"] = .string(UUID().uuidString.lowercased())
                copy["user_id"] = .string(workspace.account); copy["completion_version"] = .number(0)
                copy["completed"] = .bool(false); copy["completed_at"] = .null; copy["created_at"] = .string(ISO8601DateFormatter().string(from: date))
                copy["notification_sent_at"] = .null; copy["recurrence_parent_id"] = .null; copy.fields.removeValue(forKey: "updated_at")
                if case .object(var metadata) = copy["source_metadata"] { metadata.removeValue(forKey: "taskfold_recurrence_v1"); copy["source_metadata"] = .object(metadata) }
                copy["subtasks"] = try freshChildren(original["subtasks"])
                inserts.append(Mutation(table: "tasks", recordID: copy.id, method: "POST", fields: copy.fields, insertOnly: true))
            }
        }
        _ = try TaskHierarchyIndex(roots: Array(working.values) + inserts.map { Record($0.fields) }, projects: projects, workspace: workspace)
        let patches = working.keys.sorted().compactMap { id -> Mutation? in
            guard let original = roots[id], let updated = working[id], original["subtasks"] != updated["subtasks"] else { return nil }
            let fields = ["subtasks": updated["subtasks"]]
            return Mutation(table: "tasks", recordID: id, method: "PATCH", fields: fields, baseline: TaskCompletionRevision.editBaseline(for: fields, from: original))
        }
        return patches + inserts
    }
}

/// Explicit, lossless recovery of recognizable checklist content. Never guesses
/// unknown node formats or silently drops a field/branch to make a tree editable.
enum ChecklistRecovery {
    static let maximumItems = 10_000
    static let maximumBytes = 2_100_000
    enum Reason: String, Sendable { case missing, duplicate, invalid, textOnly }
    struct Change: Identifiable, Equatable, Sendable {
        let path: [Int]
        let title: String
        let reason: Reason
        var id: String { path.map(String.init).joined(separator: ".") }
        var depth: Int { max(0, path.count - 1) }
    }
    struct Review: Equatable, Sendable {
        let source: JSON
        let proposed: JSON
        let changes: [Change]
        let itemCount: Int
        func applying(to current: JSON) throws -> JSON {
            guard current == source else { throw SubtaskTree.Failure(message: "This checklist changed. Cancel and reopen it before recovering subtasks.") }
            return proposed
        }
    }
    static func validIdentity(_ id: String) -> Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && id.unicodeScalars.count <= 400 &&
            !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    /// Bound opaque metadata as well as the visible tree before rendering a review.
    static func originalData(_ source: JSON) throws -> Data {
        var nodes = 0, remaining = maximumBytes
        func charge(_ count: Int) throws {
            guard count <= remaining else { throw SubtaskTree.Failure(message: "This checklist is too large to recover here. Its original content is kept in the task and workspace backups.") }
            remaining -= count
        }
        func visit(_ value: JSON, depth: Int) throws {
            try Task.checkCancellation()
            nodes += 1
            guard nodes <= 100_000, depth <= 128 else { throw SubtaskTree.Failure(message: "This checklist is too complex to recover here. Your saved content is unchanged.") }
            try charge(8)
            switch value {
            case .string(let text): try charge(text.utf8.count)
            case .number(let number): guard number.isFinite else { throw SubtaskTree.Failure(message: "This checklist contains unreadable data. Your saved content is unchanged.") }
            case .array(let values): for child in values { try visit(child, depth: depth + 1) }
            case .object(let fields): for (key, child) in fields { try charge(key.utf8.count); try visit(child, depth: depth + 1) }
            case .null, .bool: break
            }
        }
        try visit(source, depth: 0)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(source)
        guard data.count <= maximumBytes else { throw SubtaskTree.Failure(message: "This checklist is too large to recover here. Its original content is kept in the task and workspace backups.") }
        return data
    }
    static func review(_ source: JSON, baseDepth: Int = 0, makeID: () -> String = { UUID().uuidString.lowercased() }) throws -> Review {
        _ = try originalData(source)
        guard baseDepth >= 0, baseDepth < SubtaskTree.readableDepth, source == .null || { if case .array = source { return true }; return false }() else {
            throw SubtaskTree.Failure(message: "This checklist uses an unfamiliar format. View its original data; recovery has not changed it.")
        }
        var counts: [String: Int] = [:], count = 0
        func inspect(_ values: [JSON], depth: Int) throws {
            guard values.isEmpty || depth + baseDepth < SubtaskTree.readableDepth else { throw SubtaskTree.Failure(message: "This checklist is too deeply nested to recover here. Your saved content is unchanged.") }
            for value in values {
                try Task.checkCancellation()
                count += 1
                guard count <= maximumItems else { throw SubtaskTree.Failure(message: "Recover up to 10,000 subtasks at once. Your saved checklist is unchanged.") }
                if case .string = value { continue } // Legacy text-only checklist item.
                guard case .object(let fields) = value, case .string? = fields["title"] else {
                    throw SubtaskTree.Failure(message: "A subtask uses an unfamiliar format. View its original data; recovery has not changed it.")
                }
                if case .string(let id)? = fields["id"], validIdentity(id) { counts[id, default: 0] += 1 }
                if let children = fields["subtasks"], children != .null {
                    guard case .array(let rows) = children else { throw SubtaskTree.Failure(message: "A nested checklist uses an unfamiliar format. View its original data; recovery has not changed it.") }
                    try inspect(rows, depth: depth + 1)
                }
            }
        }
        try inspect(source.list, depth: 0)
        var reserved = Set(counts.keys), changes: [Change] = []
        func fresh() throws -> String {
            for _ in 0..<64 {
                let id = makeID()
                guard UUID(uuidString: id)?.uuidString.lowercased() == id else { continue }
                if reserved.insert(id).inserted { return id }
            }
            throw SubtaskTree.Failure(message: "New subtask references could not be prepared. Your checklist is unchanged; try again.")
        }
        func recover(_ values: [JSON], path: [Int]) throws -> [JSON] {
            try values.enumerated().map { index, value in
                try Task.checkCancellation()
                let position = path + [index]
                if case .string(let text) = value {
                    changes.append(Change(path: position, title: text, reason: .textOnly))
                    return .object(["id": .string(try fresh()), "title": .string(text), "completed": .bool(false)])
                }
                var fields = value.object
                let identity = fields["id"], id = identity?.text ?? ""
                let reason: Reason?
                if identity == nil || identity == .null || identity == .string("") { reason = .missing }
                else if case .string = identity, validIdentity(id) { reason = counts[id, default: 0] > 1 ? .duplicate : nil }
                else { reason = .invalid }
                if let reason {
                    fields["id"] = .string(try fresh())
                    changes.append(Change(path: position, title: fields["title"]!.text, reason: reason))
                }
                if case .array(let children)? = fields["subtasks"] { fields["subtasks"] = .array(try recover(children, path: position)) }
                return .object(fields)
            }
        }
        let proposed: JSON = .array(try recover(source.list, path: []))
        _ = try originalData(proposed) // A recovered result must remain editable on its next opening.
        let root = Record(["id": .string("checklist-recovery-root"), "title": .string("Checklist"), "subtasks": proposed])
        _ = try TaskHierarchyIndex(roots: [root], projects: [], workspace: WorkspaceBinding(account: "checklist-review", generation: UUID()))
        return Review(source: source, proposed: proposed, changes: changes, itemCount: count)
    }
}
