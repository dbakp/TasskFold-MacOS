import Foundation

/// An immutable, credential-free representation of a reviewed task list or note.
/// Source access and workspace generation are checked again by the containing view.
struct PrintDocument: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        let sourceID: String
        let title: String
        let metadata: String
        let notes: String
        let completed: Bool
        let depth: Int
        var heading = false
        var completable = true
        var csv: CSVSource? = nil
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.sourceID.utf8.elementsEqual(rhs.sourceID.utf8) && lhs.title.utf8.elementsEqual(rhs.title.utf8) &&
            lhs.metadata.utf8.elementsEqual(rhs.metadata.utf8) && lhs.notes.utf8.elementsEqual(rhs.notes.utf8) &&
            lhs.completed == rhs.completed && lhs.depth == rhs.depth && lhs.heading == rhs.heading &&
            lhs.completable == rhs.completable && lhs.csv == rhs.csv
        }
    }
    struct CSVSource: Equatable, Sendable {
        var values: [String: JSON]
        var project: String, labels: [String], assignee: String, parentPath: String, parentSource: String
        var readable: Bool
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.readable == rhs.readable && lhs.project.utf8.elementsEqual(rhs.project.utf8) &&
            lhs.assignee.utf8.elementsEqual(rhs.assignee.utf8) && lhs.parentPath.utf8.elementsEqual(rhs.parentPath.utf8) &&
            lhs.parentSource.utf8.elementsEqual(rhs.parentSource.utf8) && lhs.labels.count == rhs.labels.count &&
            zip(lhs.labels, rhs.labels).allSatisfy { $0.utf8.elementsEqual($1.utf8) } &&
            AuthoredValueComparison.exactJSON(.object(lhs.values), .object(rhs.values))
        }
    }
    struct Group: Equatable, Sendable {
        let title: String; let items: [Item]
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.title.utf8.elementsEqual(rhs.title.utf8) && lhs.items == rhs.items }
    }
    let title: String
    let subtitle: String
    let groups: [Group]
    let noteOnly: Bool
    let hierarchyResults: Bool
    /// Review fences compare authored bytes, not String's canonical equivalence.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title.utf8.elementsEqual(rhs.title.utf8) && lhs.subtitle.utf8.elementsEqual(rhs.subtitle.utf8) &&
        lhs.noteOnly == rhs.noteOnly && lhs.hierarchyResults == rhs.hierarchyResults && lhs.groups == rhs.groups
    }
    static func matchesSource(_ current: Record?, _ captured: Record) -> Bool {
        guard let current else { return false }
        return AuthoredValueComparison.exactJSON(.object(current.fields), .object(captured.fields))
    }
    var count: Int { Set(groups.flatMap { $0.items.filter { $0.depth == 0 && $0.completable }.map(\.sourceID) }).count }
    static func capture(title: String, subtitle: String, groups: [(String, [Record])], projects: [Record], labels: [Record], noteOnly: Bool = false, hierarchyRoots: [Record]? = nil, expandOrdinaryChecklists: Bool = false, assigneeName: (Record) -> String = { _ in "" }) throws -> Self {
        var parentContext: [String: String] = [:]
        var parentTitlePaths: [String: [String]] = [:]
        if let hierarchyRoots {
            let displayed = groups.flatMap { $0.1 }
            let childRoots = Set(displayed.compactMap { SubtaskTree.referencePath($0.id)?.first })
            let index = try TaskHierarchyIndex(roots: hierarchyRoots.filter { childRoots.contains($0.id) }, projects: projects, workspace: WorkspaceBinding(account: "print-review", generation: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!))
            for task in displayed {
                if task.id.hasPrefix("subtask:") {
                    guard let item = index.item(task.id), matchesSource(item.record, task) else { throw AppFailure(message: "A filtered subtask changed. Refresh the list before printing.") }
                    parentContext[task.id] = item.parentTitles.joined(separator: " › "); parentTitlePaths[task.id] = item.parentTitles
                } else {
                    let roots = hierarchyRoots.filter { $0.id == task.id }
                    guard roots.count == 1, matchesSource(roots[0], task) else { throw AppFailure(message: "A filtered task changed. Refresh the list before printing.") }
                }
            }
        }
        var labelLookup: [String: [Record]] = [:]
        for label in labels {
            labelLookup[label.id, default: []].append(label)
            if label.name != label.id { labelLookup[label.name, default: []].append(label) }
        }
        var count = 0, bytes = title.utf8.count + subtitle.utf8.count
        func item(_ task: Record, depth: Int, project: String, parentTitles: [String] = []) throws -> [Item] {
            guard depth <= SubtaskTree.readableDepth else { throw AppFailure(message: "A checklist is too deeply nested to print completely. Export a smaller selection.") }
            count += 1
            guard count <= 10_000 else { throw AppFailure(message: "Choose a smaller list to print. This selection has more than 10,000 items.") }
            let name = task.title.isEmpty ? "Untitled task" : task.title
            let notes = task.string("description")
            var detail: [String] = []
            if TaskKind(task) == .unsupported { detail.append("Task type needs review") }
            if depth == 0, !project.isEmpty { detail.append(project) }
            if depth == 0, let parent = parentContext[task.id] { detail.append("Subtask of " + parent) }
            if (1...3).contains(task.priority) { detail.append("P\(task.priority)") }
            let date = task.string("due_date"), time = task.string("due_time"), zone = task.string("time_zone")
            if !date.isEmpty { detail.append("Due " + date + (time.isEmpty ? "" : " " + time) + (time.isEmpty || zone.isEmpty ? "" : " " + zone)) }
            if !task.string("deadline_date").isEmpty { detail.append("Deadline " + task.string("deadline_date")) }
            if TaskKind.mayComplete(task), let duration = task.durationMinutes { detail.append("\(duration) min") }
            for label in task["labels"].list {
                if let named = labelLookup[label.text]?.first { detail.append("@" + named.name) }
            }
            let assigned = task.string("assigned_to").isEmpty ? "" : assigneeName(task)
            if !assigned.isEmpty { detail.append("Assigned to " + assigned) }
            if depth > 6 { detail.append("Checklist level \(depth)") }
            let metadata = detail.joined(separator: " · ")
            bytes += name.utf8.count + notes.utf8.count + metadata.utf8.count
            guard bytes <= 16_000_000 else { throw AppFailure(message: "This selection is too large to print completely. Choose a smaller list.") }
            var namedLabels: [String] = [], readable = task.string("project_id").isEmpty || projects.contains { $0.id == task.string("project_id") }
            if task["labels"] != .null {
                if case .array(let values) = task["labels"] {
                    for value in values {
                        if case .object(let object) = value, case .string(let title)? = object["name"], !title.isEmpty { namedLabels.append(title) }
                        else if case .string(let key) = value {
                            let matches = labelLookup[key] ?? []
                            if matches.count == 1, !matches[0].name.isEmpty { namedLabels.append(matches[0].name) } else { readable = false }
                        } else { readable = false }
                    }
                } else { readable = false }
            }
            if task["assigned_to"] != .null {
                if case .string(let id) = task["assigned_to"] { if !id.isEmpty && assigned.isEmpty { readable = false } }
                else { readable = false }
            }
            var parentSource = ""
            if let path = SubtaskTree.referencePath(task.id) {
                parentSource = path[0]
                for key in path.dropFirst().dropLast() { parentSource = SubtaskTree.reference(parent: parentSource, key: key) }
            }
            let fields: Set<String> = ["title", "description", "completed", "priority", "due_date", "due_time", "time_zone", "scheduled_at", "deadline_date", "duration_minutes"]
            let csv = CSVSource(values: task.fields.filter { fields.contains($0.key) }, project: project, labels: namedLabels, assignee: assigned,
                parentPath: depth == 0 ? parentContext[task.id] ?? "" : parentTitles.joined(separator: " › "), parentSource: parentSource, readable: readable)
            var result = [Item(sourceID: task.id, title: name, metadata: metadata, notes: notes, completed: task.completed, depth: depth, heading: TaskKind(task) == .heading, completable: TaskKind.mayComplete(task), csv: csv)]
            if noteOnly || (hierarchyRoots != nil && (!expandOrdinaryChecklists || TaskKind(task) != .task)) { return result }
            guard task["subtasks"] == .null || { if case .array = task["subtasks"] { return true }; return false }() else { throw AppFailure(message: "A checklist uses an unsupported format. Its saved content is unchanged.") }
            for value in task["subtasks"].list {
                guard case .object = value else { throw AppFailure(message: "A checklist item uses an unsupported format. Its saved content is unchanged.") }
                var child = Record(value.object); child["project_id"] = task["project_id"]
                result += try item(child, depth: depth + 1, project: project, parentTitles: (depth == 0 ? parentTitlePaths[task.id] ?? [] : parentTitles) + [name])
            }
            return result
        }
        let captured = try groups.map { title, tasks in
            bytes += title.utf8.count
            return Group(title: title, items: try tasks.flatMap { task in
                try item(task, depth: 0, project: projects.first(where: { $0.id == task.string("project_id") })?.name ?? "")
            })
        }
        guard bytes <= 16_000_000 else { throw AppFailure(message: "Choose a smaller list to print completely.") }
        return Self(title: title, subtitle: subtitle, groups: captured, noteOnly: noteOnly, hierarchyResults: hierarchyRoots != nil && !expandOrdinaryChecklists)
    }
}


/// Flat, reviewed task rows. References are file-local, never account or live task IDs.
enum TaskRowCSV {
    struct Options: Equatable, Sendable { var notes = true; var checklists = true }
    struct Output: Sendable { let data: Data; let rows: [[String]] }
    static func make(_ document: PrintDocument, options: Options = Options()) throws -> Output {
        guard !document.noteOnly else { throw AppFailure(message: "Choose a task list for CSV export.") }
        var rows: [[String]] = []
        for group in document.groups {
            let items = group.items.filter { options.checklists || $0.depth == 0 }
            let references = items.indices.map { "row-\(rows.count + $0 + 1)" }
            var topRefs: [String: [String]] = [:]
            for (index, item) in items.enumerated() where item.depth == 0 { topRefs[item.sourceID, default: []].append(references[index]) }
            var stack: [Int: String] = [:]
            for (index, item) in items.enumerated() {
                try Task.checkCancellation()
                guard rows.count < 5000, let source = item.csv, source.readable else { throw AppFailure(message: "Choose up to 5,000 readable task rows. Refresh unavailable project, label or collaborator details before exporting.") }
                func text(_ field: String) throws -> String {
                    switch source.values[field] ?? .null {
                    case .null: return ""
                    case .string(let value): return value
                    default: throw AppFailure(message: "A task’s \(field.replacingOccurrences(of: "_", with: " ")) uses an unsupported format. Its saved work is unchanged.")
                    }
                }
                func number(_ field: String, bounds: ClosedRange<Int>) throws -> String {
                    guard let value = source.values[field], value != .null else { return "" }
                    guard case .number(let n) = value, n.isFinite, n.rounded() == n, n >= Double(bounds.lowerBound), n <= Double(bounds.upperBound) else { throw AppFailure(message: "A task’s \(field == "duration_minutes" ? "estimate" : "priority") needs review before CSV export.") }
                    return String(Int(n))
                }
                let completion: String
                switch source.values["completed"] ?? .null {
                case .null: completion = "false"
                case .bool(let done): completion = done ? "true" : "false"
                default: throw AppFailure(message: "A task’s completion state needs review before CSV export.")
                }
                let parent: String
                if item.depth > 0 {
                    guard let ref = stack[item.depth - 1] else { throw AppFailure(message: "The displayed checklist hierarchy changed. Reopen the export from the list.") }
                    parent = ref
                } else if let candidates = topRefs[source.parentSource], candidates.count == 1 { parent = candidates[0] }
                else { parent = "" }
                stack = stack.filter { $0.key < item.depth }; stack[item.depth] = references[index]
                rows.append([TaskRowCSVFormat.marker, references[index], parent, group.title, source.parentPath,
                    item.heading ? "heading" : item.completable ? "task" : "unavailable", try text("title"), options.notes ? try text("description") : "", completion, source.project,
                    try number("priority", bounds: 1...4), try text("due_date"), try text("due_time"), try text("time_zone"), try text("scheduled_at"), try text("deadline_date"), try number("duration_minutes", bounds: 1...10080), String(decoding: try JSONEncoder().encode(source.labels), as: UTF8.self), source.assignee])
            }
        }
        guard !rows.isEmpty else { throw AppFailure(message: "There are no task rows to export.") }
        let text = ([TaskRowCSVFormat.columns] + rows.map { $0.map(WorkflowTemplateCSV.escape) }).map { $0.map(WorkflowTemplateCSV.quote).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        let data = Data(text.utf8)
        guard data.count <= WorkflowTemplateFile.maximumBytes else { throw AppFailure(message: "This CSV exceeds 2.1 MB. Exclude notes or choose a smaller list; no rows have been truncated.") }
        return Output(data: data, rows: rows)
    }
}
