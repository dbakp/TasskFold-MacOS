import Foundation

/// Child rows outside the lists (phase 5): legacy references, templates, filters, Breakdown, widgets, Watch and
/// local mode. Pure: every function reads and returns values, and callers decide whether `TaskTree.rowsEnabled`.

/// Persisted `subtask:<base64 path>` references (widget links and completion receipts, Spotlight items, list orders)
/// map to the deterministic child row id that Migration B and `LegacySubtaskConversion` give the same node.
enum LegacyTaskReference {
    static func resolve(_ id: String, enabled: Bool = TaskTree.rowsEnabled) -> String {
        guard enabled, id.hasPrefix("subtask:"), let mapped = LegacySubtaskConversion.newID(forReference: id) else { return id }
        return mapped
    }

    /// `taskfold://task/subtask:…?account=A&context=C` becomes `taskfold://task/<row id>?account=A`. Other links are unchanged.
    static func remap(_ url: URL, enabled: Bool = TaskTree.rowsEnabled) -> URL {
        guard enabled, url.scheme == "taskfold", url.host == "task",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let id = String((parts.percentEncodedPath.removingPercentEncoding ?? parts.percentEncodedPath).drop { $0 == "/" })
        let mapped = resolve(id, enabled: true)
        guard mapped != id else { return url }
        var next = URLComponents()
        next.scheme = "taskfold"; next.host = "task"; next.path = "/" + mapped
        if let account = parts.queryItems?.first(where: { $0.name == "account" })?.value { next.queryItems = [URLQueryItem(name: "account", value: account)] }
        return next.url ?? url
    }

    /// An `ids` list (view orders, day plans): legacy references are replaced in place, keeping the first of any duplicates.
    static func remapIDs(_ value: JSON, enabled: Bool = TaskTree.rowsEnabled) -> JSON {
        guard enabled, case .array(let items) = value, items.contains(where: { $0.text.hasPrefix("subtask:") }) else { return value }
        var seen = Set<String>(), result: [JSON] = []
        for item in items {
            guard case .string(let id) = item else { result.append(item); continue }
            let mapped = resolve(id, enabled: true)
            if seen.insert(TaskTree.key(mapped)).inserted { result.append(.string(mapped)) }
        }
        return .array(result)
    }
}

/// Templates keep nested `subtasks` in their document (so older apps and exported files still read them), but a
/// template applied with child rows on creates one task row per node.
enum ChildRowTemplates {
    /// For capture: each selected task whose parent is not also selected, with its child rows nested as `subtasks`
    /// objects (recursively, in sibling order). `all` supplies the descendants.
    static func nest(_ selected: [Record], all: [Record]) -> [Record] {
        let tree = TaskTree(all)
        let chosen = Set(selected.map { TaskTree.key($0.id) })
        func nested(_ row: Record, depth: Int) -> Record {
            var row = row
            let kids = depth < TaskTree.maximumAncestors ? tree.children(of: row.id) : []
            if !kids.isEmpty { row["subtasks"] = .array(kids.map { .object(nested($0, depth: depth + 1).fields) }) }
            row.fields.removeValue(forKey: "parent_id"); row.fields.removeValue(forKey: "child_order")
            return row
        }
        return selected.filter { row in
            !tree.ancestors(of: row.id).contains { chosen.contains(TaskTree.key($0.id)) }
        }.map { nested($0, depth: 0) }
    }

    /// For apply: a created root whose `subtasks` hold created nodes becomes the root (with no JSON subtasks) followed
    /// by its descendants as rows, parents first. Children share the root's owner, project and section.
    static func flatten(_ root: Record) -> [Record] {
        var result: [Record] = []
        func visit(_ row: Record, parent: Record?, order: Int) {
            var row = row
            let kids = row["subtasks"].list
            row["subtasks"] = .array([])
            if let parent {
                row["parent_id"] = .string(parent.id); row["child_order"] = .number(Double(order))
                for field in ["user_id", "project_id", "section_id"] { row[field] = root[field] }
            }
            result.append(row)
            for (index, kid) in kids.enumerated() {
                guard case .object(let fields) = kid else { continue }
                visit(Record(fields), parent: row, order: index + 1)
            }
        }
        visit(root, parent: nil, order: 0)
        return result
    }
}

/// The filter predicates `root`, `subtask` and `parent` read `parent_id` once subtasks are rows. A task row does not
/// know whether it has children, so readers that evaluate filters over a task list bind the parents of that list.
enum ChildRowFilterScope {
    /// Lower-cased ids of tasks that have at least one child row. nil when the caller did not bind any.
    @TaskLocal static var parents: Set<String>? = nil

    static func parents(of tasks: [Record]) -> Set<String> { Set(tasks.compactMap(TaskTree.parentKey(of:))) }
    /// Runs `body` with the parents of `tasks` bound when child rows are on.
    static func with<T>(_ tasks: [Record], enabled: Bool = TaskTree.rowsEnabled, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        return try $parents.withValue(parents(of: tasks), operation: body)
    }
    static func isChildRow(_ task: Record) -> Bool { TaskTree.parentKey(of: task) != nil }
    static func hasChildRows(_ task: Record) -> Bool { parents?.contains(TaskTree.key(task.id)) == true }
}

/// Suggest steps (Breakdown, on-device AI) adds its steps as child rows under a saved parent.
enum ChildRowSteps {
    /// The titles the review added: entries of `proposed` beyond what `previous` already held.
    static func addedTitles(_ proposed: JSON, previous: JSON) -> [String] {
        Array(proposed.list.dropFirst(previous.list.count)).compactMap { value in
            switch value {
            case .string(let title): return title
            case .object(let fields): return fields["title"]?.text
            default: return nil
            }
        }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// New child rows appended under `parent`, in order. Each copies the parent's owner, project and section.
    static func rows(_ titles: [String], under parent: Record, tree: TaskTree, account: String, now: Date = Date()) -> [Record] {
        var order = tree.nextOrder(under: parent.id)
        let stamp = ISO8601DateFormatter().string(from: now)
        return titles.map { title in
            var row = Record.task(user: account, project: parent.string("project_id"), createdAt: stamp)
            row["title"] = .string(title)
            row["user_id"] = parent["user_id"] == .null || parent.string("user_id").isEmpty ? .string(account) : parent["user_id"]
            row["section_id"] = parent["section_id"]
            row["parent_id"] = .string(parent.id); row["child_order"] = .number(order)
            order += 1
            return row
        }
    }
}

/// Widgets and the Watch show a child row as a plain task with an optional parent title.
enum ChildRowDisplay {
    /// The direct parent's title ("Untitled task" when empty), or nil for a root.
    static func parentTitle(of task: Record, tree: TaskTree) -> String? {
        guard TaskTree.parentKey(of: task) != nil, let parent = tree.parent(of: task.id) else { return nil }
        let title = parent.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled task" : title
    }
}

/// Signed-out (local) workspaces convert their JSON subtasks into rows once, on load, the way Migration B does on
/// the server. A marker row records the conversion so it is never repeated; it is device-local and never backed up.
enum LocalChildRows {
    static let markerTable = "_local_child_rows"
    static let markerID = "v1"

    static func converted(_ tables: [String: [Record]]) -> Bool { tables[markerTable]?.contains { $0.id == markerID } == true }

    struct Outcome: Equatable {
        var tables: [String: [Record]]
        var roots = 0
        var rows = 0
        var skipped = 0
    }

    /// nil when the marker is already present or nothing is in the old shape. Otherwise every root with JSON subtasks gains its child rows
    /// (deterministic ids, parents first), keeps `subtasks = []`, and legacy references in list orders are remapped.
    static func convert(_ tables: [String: [Record]], now: Date = Date()) -> Outcome? {
        guard !converted(tables) else { return nil }
        var tasks = tables["tasks"] ?? []
        var present = Set(tasks.map { TaskTree.key($0.id) })
        var added: [Record] = [], archive: [String: JSON] = [:]
        var outcome = Outcome(tables: tables)
        for index in tasks.indices {
            let root = tasks[index]
            guard SubtaskTree.referencePath(root.id) == nil, case .array(let top) = root["subtasks"], !top.isEmpty else { continue }
            let result = LegacySubtaskConversion.convert(root: root)
            for row in result.rows where present.insert(TaskTree.key(row.id)).inserted { added.append(row); outcome.rows += 1 }
            outcome.skipped += result.skipped.count
            archive[root.id] = .object(["original": root["subtasks"], "skipped": result.skippedJSON])
            tasks[index]["subtasks"] = .array([])
            outcome.roots += 1
        }
        // Nothing saved in the old shape: leave the workspace untouched (no marker), so loading stays a no-op.
        let legacyOrders = (tables["view_orders"] ?? []).contains { $0["ids"].list.contains { $0.text.hasPrefix("subtask:") } }
        guard outcome.roots > 0 || legacyOrders else { return nil }
        outcome.tables["tasks"] = tasks + added
        if let orders = outcome.tables["view_orders"] {
            outcome.tables["view_orders"] = orders.map { row in
                var row = row
                if row.fields["ids"] != nil { row["ids"] = LegacyTaskReference.remapIDs(row["ids"], enabled: true) }
                return row
            }
        }
        outcome.tables[markerTable] = [Record(["id": .string(markerID), "converted_at": .string(ISO8601DateFormatter().string(from: now)),
                                                "roots": .number(Double(outcome.roots)), "rows": .number(Double(outcome.rows)), "archive": .object(archive)])]
        return outcome
    }
}

/// Offline edits the JSON child-record system saved before the update cannot be sent any more. They are offered
/// once, together, for export as they were saved.
enum LegacyChildJournalExport {
    static let title = "Subtask edits saved before the update"
    static let message = "Taskfold saved these subtask edits on this device before subtasks became tasks. They can’t be sent now. Export them to keep a copy, then re-enter anything still needed."

    /// One JSON document: `{"version":1,"exported_at":…,"journals":{kind: saved state}}`, keys sorted.
    static func document(_ journals: [String: Data], now: Date = Date()) throws -> Data {
        var entries: [String: JSON] = [:]
        for (kind, data) in journals { entries[kind] = try TaskfoldJSONDecoder().decode(JSON.self, from: data) }
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(JSON.object(["version": .number(1), "exported_at": .string(ISO8601DateFormatter().string(from: now)), "journals": .object(entries)]))
    }
}

/// Completing from a widget or the Watch follows the same rule as the app: a parent completes its open descendants.
enum ChildRowCompletion {
    static func complete(_ task: Record, tasks: [Record], at now: Date, calendar: Calendar, account: String, enabled: Bool = TaskTree.rowsEnabled) -> [Mutation] {
        // Only a task with child rows takes the tree plan; any other task completes exactly as before.
        if enabled, !task.completed, tasks.contains(where: { TaskTree.parentKey(of: $0) == TaskTree.key(task.id) }),
           let plan = TaskTree.completion(of: task, tasks: tasks, at: now, calendar: calendar, account: account) { return plan.mutations }
        return TaskCompletion.complete(task, tasks: tasks, at: now, calendar: calendar, account: account)
    }
}
