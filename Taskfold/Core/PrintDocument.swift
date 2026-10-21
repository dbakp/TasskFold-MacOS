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
    }
    struct Group: Equatable, Sendable { let title: String; let items: [Item] }
    let title: String
    let subtitle: String
    let groups: [Group]
    let noteOnly: Bool
    let hierarchyResults: Bool
    var count: Int { Set(groups.flatMap { $0.items.filter { $0.depth == 0 }.map(\.sourceID) }).count }
    static func capture(title: String, subtitle: String, groups: [(String, [Record])], projects: [Record], labels: [Record], noteOnly: Bool = false, hierarchyRoots: [Record]? = nil, assigneeName: (Record) -> String = { _ in "" }) throws -> Self {
        var parentContext: [String: String] = [:]
        if let hierarchyRoots {
            let displayed = groups.flatMap { $0.1 }
            let childRoots = Set(displayed.compactMap { SubtaskTree.referencePath($0.id)?.first })
            let index = try TaskHierarchyIndex(roots: hierarchyRoots.filter { childRoots.contains($0.id) }, projects: projects, workspace: WorkspaceBinding(account: "print-review", generation: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!))
            for task in displayed {
                if task.id.hasPrefix("subtask:") {
                    guard let item = index.item(task.id), item.record == task else { throw AppFailure(message: "A filtered subtask changed. Refresh the list before printing.") }
                    parentContext[task.id] = item.parentTitles.joined(separator: " › ")
                } else {
                    let roots = hierarchyRoots.filter { $0.id == task.id }
                    guard roots.count == 1, roots[0] == task else { throw AppFailure(message: "A filtered task changed. Refresh the list before printing.") }
                }
            }
        }
        var count = 0, bytes = title.utf8.count + subtitle.utf8.count
        func item(_ task: Record, depth: Int, project: String) throws -> [Item] {
            guard depth <= SubtaskTree.readableDepth else { throw AppFailure(message: "A checklist is too deeply nested to print completely. Export a smaller selection.") }
            count += 1
            guard count <= 10_000 else { throw AppFailure(message: "Choose a smaller list to print. This selection has more than 10,000 items.") }
            let name = task.title.isEmpty ? "Untitled task" : task.title
            let notes = task.string("description")
            var detail: [String] = []
            if depth == 0, !project.isEmpty { detail.append(project) }
            if depth == 0, let parent = parentContext[task.id] { detail.append("Subtask of " + parent) }
            if (1...3).contains(task.priority) { detail.append("P\(task.priority)") }
            let date = task.string("due_date"), time = task.string("due_time"), zone = task.string("time_zone")
            if !date.isEmpty { detail.append("Due " + date + (time.isEmpty ? "" : " " + time) + (time.isEmpty || zone.isEmpty ? "" : " " + zone)) }
            if !task.string("deadline_date").isEmpty { detail.append("Deadline " + task.string("deadline_date")) }
            if let duration = task.durationMinutes { detail.append("\(duration) min") }
            for label in task["labels"].list {
                if let named = labels.first(where: { $0.id == label.text || $0.name == label.text }) { detail.append("@" + named.name) }
            }
            let assigned = task.string("assigned_to").isEmpty ? "" : assigneeName(task)
            if !assigned.isEmpty { detail.append("Assigned to " + assigned) }
            if depth > 6 { detail.append("Checklist level \(depth)") }
            let metadata = detail.joined(separator: " · ")
            bytes += name.utf8.count + notes.utf8.count + metadata.utf8.count
            guard bytes <= 16_000_000 else { throw AppFailure(message: "This selection is too large to print completely. Choose a smaller list.") }
            var result = [Item(sourceID: task.id, title: name, metadata: metadata, notes: notes, completed: task.completed, depth: depth)]
            if noteOnly || hierarchyRoots != nil { return result }
            guard task["subtasks"] == .null || { if case .array = task["subtasks"] { return true }; return false }() else { throw AppFailure(message: "A checklist uses an unsupported format. Its saved content is unchanged.") }
            for value in task["subtasks"].list {
                guard case .object = value else { throw AppFailure(message: "A checklist item uses an unsupported format. Its saved content is unchanged.") }
                var child = Record(value.object); child["project_id"] = task["project_id"]
                result += try item(child, depth: depth + 1, project: "")
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
        return Self(title: title, subtitle: subtitle, groups: captured, noteOnly: noteOnly, hierarchyResults: hierarchyRoots != nil)
    }
}
