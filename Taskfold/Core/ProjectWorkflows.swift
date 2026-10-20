import Foundation

/// Account-compatible project organization. Archive inheritance is computed from the
/// available graph; the server projection covers an inaccessible shared ancestor.
enum ProjectOrganization {
    static let maximumDepth = 20
    struct Item: Identifiable, Equatable {
        var project: Record
        var depth: Int
        var id: String { project.id }
    }
    static func archived(_ id: String, in projects: [Record]) -> Bool { archivedIDs(in: projects).contains(id) }
    static func archivedIDs(in projects: [Record]) -> Set<String> {
        let rows = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var results: [String: Bool] = [:]
        for start in projects where results[start.id] == nil {
            var cursor = start.id, path: [String] = [], seen = Set<String>(), hidden = false
            while let row = rows[cursor] {
                if let saved = results[cursor] { hidden = saved; break }
                guard seen.insert(cursor).inserted else { hidden = true; break }
                path.append(cursor)
                if row["is_archived"].flag { hidden = true; break }
                let parent = row.string("parent_id")
                if parent.isEmpty { break }
                if rows[parent] == nil { hidden = row["ancestor_archived"].flag; break }
                cursor = parent
            }
            for id in path { results[id] = hidden }
        }
        return Set(results.filter(\.value).map(\.key))
    }
    static func descendants(_ id: String, in projects: [Record]) -> Set<String> {
        var result: Set<String> = [id], queue = [id], index = 0
        let children = Dictionary(grouping: projects, by: { $0.string("parent_id") })
        while index < queue.count {
            for row in children[queue[index]] ?? [] where result.insert(row.id).inserted { queue.append(row.id) }
            index += 1
        }
        return result
    }
    static func outline(_ projects: [Record], archived showArchived: Bool = false) -> [Item] {
        let rows = OrganizationOrder.sorted(projects)
        let archived = archivedIDs(in: projects)
        let visible = rows.filter { archived.contains($0.id) == showArchived }
        let ids = Set(visible.map(\.id)), grouped = Dictionary(grouping: visible, by: { $0.string("parent_id") })
        var result: [Item] = [], seen = Set<String>()
        func append(_ row: Record, depth: Int) {
            guard seen.insert(row.id).inserted else { return }
            result.append(Item(project: row, depth: depth))
            for child in grouped[row.id] ?? [] { append(child, depth: min(maximumDepth, depth + 1)) }
        }
        for row in visible where !ids.contains(row.string("parent_id")) { append(row, depth: 0) }
        // Malformed/legacy cycles never hide records or recurse forever in management.
        for row in visible where !seen.contains(row.id) { append(row, depth: 0) }
        return result
    }
    static func validate(_ project: Record, previous: Record?, account: String, projects: [Record]) throws {
        guard !project.id.isEmpty, !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure(message: "Give the project a name.") }
        let organizationChanged = previous == nil || previous?["parent_id"] != project["parent_id"] || previous?["is_archived"].flag != project["is_archived"].flag
        guard organizationChanged else { return }
        guard project.string("user_id") == account else { throw AppFailure(message: "Only the project owner can move or archive it.") }
        let proposed = projects.filter { $0.id != project.id } + [project]
        let rows = Dictionary(proposed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in descendants(project.id, in: proposed) {
            var current = id, seen = Set<String>(), depth = 0
            while let row = rows[current] {
                guard seen.insert(current).inserted else { throw AppFailure(message: "A project cannot be placed inside itself or one of its subprojects.") }
                let parent = row.string("parent_id")
                if parent.isEmpty { break }
                guard let next = rows[parent], next.string("user_id") == project.string("user_id") else { throw AppFailure(message: "Choose an available parent project that you own.") }
                depth += 1
                guard depth < maximumDepth else { throw AppFailure(message: "Projects can be nested up to 20 levels.") }
                current = parent
            }
        }
    }
    static func parentChoices(for project: Record, account: String, projects: [Record]) -> [Item] {
        let excluded = descendants(project.id, in: projects)
        return outline(projects).filter { item in
            guard !excluded.contains(item.id), item.project.string("user_id") == account else { return false }
            var draft = project; draft["parent_id"] = .string(item.id)
            return (try? validate(draft, previous: nil, account: account, projects: projects)) != nil
        }
    }
}

/// A reviewable import of lines. Parsing never writes, and one commit can save
/// the chosen rows and labels as a single durable, undoable operation.
enum MultiLineCapture {
    static let maximumLines = 200
    struct Line: Identifiable, Equatable {
        var number: Int
        var task: Record
        var warnings: [String]
        var id: Int { number }
    }
    static func preview(_ text: String, account: String, project: String = "", context: QuickEntryContext = QuickEntryContext(), recognize: Bool = true, now: Date = Date()) throws -> [Line] {
        guard text.utf8.count <= 100_000 else { throw AppFailure(message: "Paste up to 100 KB of task text at a time.") }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines).enumerated().compactMap { index, raw -> (Int, String)? in
            var title = raw.trimmingCharacters(in: .whitespaces)
            title = title.replacingOccurrences(of: #"^(?:[-*•]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
            title = title.replacingOccurrences(of: #"^\[[ xX]\]\s*"#, with: "", options: .regularExpression)
            return title.isEmpty ? nil : (index + 1, title)
        }
        guard lines.count <= maximumLines else { throw AppFailure(message: "Review up to 200 tasks at a time. Nothing has been added.") }
        return lines.map { number, title in
            var task = Record.task(user: account, project: project); task["title"] = .string(title)
            let parsed = QuickEntry(title, now: now, context: context, task: task)
            return Line(number: number, task: recognize ? parsed.applying(to: task) : task, warnings: recognize ? parsed.warnings : [])
        }
    }
}

/// Private, versioned, reusable workflow definitions. Source IDs are internal
/// references only; every use creates new records and task generations.
struct WorkflowTemplate {
    enum Kind: String { case project, section, task }
    static let table = "project_templates"
    let document: JSON
    var kind: Kind { Kind(rawValue: document.object["kind"]?.text ?? "")! }
    var projects: [Record] { document.object["projects"]?.list.map { Record($0.object) } ?? [] }
    var sections: [Record] { document.object["sections"]?.list.map { Record($0.object) } ?? [] }
    var tasks: [Record] { document.object["tasks"]?.list.map { Record($0.object) } ?? [] }
    private static let taskFields: Set<String> = ["id","title","description","priority","project_id","section_id","duration_minutes","labels","subtasks","is_recurring","recurrence_pattern","due_time","time_zone","planned_offset","deadline_offset","repeat_start_offset","repeat_end_offset"]
    init(document: JSON) throws {
        let root = document.object
        guard root["version"] == .number(1), Kind(rawValue: root["kind"]?.text ?? "") != nil,
              Set(root.keys).isSubset(of: ["version","kind","projects","sections","tasks"]),
              ["projects","sections","tasks"].allSatisfy({ if case .array? = root[$0] { return true }; return false }) else {
            throw AppFailure(message: "This template needs a newer version of Taskfold.")
        }
        self.document = document
        guard projects.count <= 1000, sections.count <= 5000, tasks.count <= 5000,
              (try JSONEncoder().encode(document)).count <= 2_000_000 else { throw AppFailure(message: "This template is too large.") }
        func unique(_ rows: [Record]) -> Bool { rows.allSatisfy { !$0.id.isEmpty } && Set(rows.map(\.id)).count == rows.count }
        guard unique(projects), unique(sections), unique(tasks) else { throw AppFailure(message: "The template has missing or duplicate references.") }
        let projectIDs = Set(projects.map(\.id)), sectionRows = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard projects.allSatisfy({ Set($0.fields.keys).isSubset(of: ["id","name","description","color","parent_id","order_index"]) && ($0.string("parent_id").isEmpty || projectIDs.contains($0.string("parent_id"))) }),
              sections.allSatisfy({ Set($0.fields.keys).isSubset(of: ["id","name","project_id","order_index"]) && projectIDs.contains($0.string("project_id")) }) else { throw AppFailure(message: "The template contains an unavailable project or section.") }
        for row in projects + sections {
            if let value = row.fields["order_index"] {
                guard case .number(let number) = value, number.rounded() == number, (0...2147483647).contains(number) else { throw AppFailure(message: "A template order is invalid.") }
            }
            guard !row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure(message: "A template project or section needs a name.") }
            for field in ["id", "name", "description", "color", "parent_id", "project_id"] where row.fields[field] != nil && row[field] != .null {
                guard case .string = row[field] else { throw AppFailure(message: "A template organization field is invalid.") }
            }
        }
        let roots = projects.filter { $0.string("parent_id").isEmpty }
        guard kind != .project || roots.count == 1,
              kind != .section || projects.count == 1 && sections.count == 1,
              kind != .task || tasks.count == 1 && projects.count <= 1 && sections.isEmpty else {
            throw AppFailure(message: "The template structure is incomplete.")
        }
        for project in projects {
            var cursor = project.id, seen = Set<String>()
            while let row = projects.first(where: { $0.id == cursor }) {
                guard seen.insert(cursor).inserted, seen.count <= ProjectOrganization.maximumDepth else { throw AppFailure(message: "The template project hierarchy is invalid.") }
                cursor = row.string("parent_id")
            }
        }
        func checkTask(_ task: Record, depth: Int) throws {
            guard depth <= 10, Set(task.fields.keys).isSubset(of: Self.taskFields), !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  task.title.count <= 10000, (task.string("project_id").isEmpty || projectIDs.contains(task.string("project_id"))) else { throw AppFailure(message: "The template contains an invalid task.") }
            if !task.string("section_id").isEmpty { guard sectionRows[task.string("section_id")]?.string("project_id") == task.string("project_id") else { throw AppFailure(message: "A template section belongs to another project.") } }
            if let value = task.fields["priority"] { guard case .number(let n) = value, n.rounded() == n, (1...4).contains(n) else { throw AppFailure(message: "A template priority is invalid.") } }
            if let value = task.fields["duration_minutes"], value != .null { guard case .number(let n) = value, n.rounded() == n, (1...10080).contains(n) else { throw AppFailure(message: "A template estimate is invalid.") } }
            for field in ["title","description","due_time","time_zone"] where task.fields[field] != nil && task[field] != .null {
                guard case .string = task[field] else { throw AppFailure(message: "A template text field is invalid.") }
            }
            for field in ["planned_offset","deadline_offset","repeat_start_offset","repeat_end_offset"] where task.fields[field] != nil {
                guard case .number(let n) = task[field], n.isFinite, n.rounded() == n, abs(n) <= 365000 else { throw AppFailure(message: "A template date offset is invalid.") }
            }
            guard case .array = task["labels"], task["labels"].list.allSatisfy({ if case .object = $0 { return !$0.object["name", default: .null].text.isEmpty }; return false }), case .array = task["subtasks"] else { throw AppFailure(message: "The template task details are invalid.") }
            if let value = task.fields["is_recurring"], case .bool = value {} else if task.fields["is_recurring"] != nil { throw AppFailure(message: "A template repeat value is invalid.") }
            if !task.string("time_zone").isEmpty, TimeZone(identifier: task.string("time_zone")) == nil { throw AppFailure(message: "A template time zone is unknown.") }
            if !task.string("due_time").isEmpty, task.string("due_time").range(of: #"^(?:[01][0-9]|2[0-3]):[0-5][0-9](?::[0-5][0-9](?:\.[0-9]+)?)?$"#, options: .regularExpression) == nil { throw AppFailure(message: "A template time is invalid.") }
            if task["is_recurring"].flag, !Recurrence.valid(Record(task["recurrence_pattern"].object)) { throw AppFailure(message: "The template repeat rule is unsupported.") }
            for child in task["subtasks"].list { try checkTask(Record(child.object), depth: depth + 1) }
        }
        for task in tasks { try checkTask(task, depth: 0) }
    }
    static func capture(kind: Kind, id: String, snapshot: Snapshot, now: Date = Date()) throws -> Self {
        let allProjects = snapshot.tables["projects"] ?? [], allTasks = snapshot.tables["tasks"] ?? [], allSections = snapshot.tables["sections"] ?? [], labels = snapshot.tables["labels"] ?? []
        let selectedTasks: [Record], selectedProjects: [Record], selectedSections: [Record]
        switch kind {
        case .project:
            guard allProjects.contains(where: { $0.id == id }) else { throw AppFailure(message: "This project is no longer available.") }
            let ids = ProjectOrganization.descendants(id, in: allProjects)
            selectedProjects = ProjectOrganization.outline(allProjects.filter { ids.contains($0.id) }).map(\.project) + ProjectOrganization.outline(allProjects.filter { ids.contains($0.id) }, archived: true).map(\.project)
            selectedSections = allSections.filter { ids.contains($0.string("project_id")) }; selectedTasks = allTasks.filter { ids.contains($0.string("project_id")) }
        case .section:
            guard let section = allSections.first(where: { $0.id == id }), let project = allProjects.first(where: { $0.id == section.string("project_id") }) else { throw AppFailure(message: "This section is no longer available.") }
            selectedProjects = [project]; selectedSections = [section]; selectedTasks = allTasks.filter { $0.string("section_id") == id }
        case .task:
            guard let task = allTasks.first(where: { $0.id == id }) else { throw AppFailure(message: "This task is no longer available.") }
            selectedProjects = allProjects.filter { $0.id == task.string("project_id") }; selectedSections = []; selectedTasks = [task]
        }
        let calendar = Calendar(identifier: .gregorian)
        let anchor = selectedTasks.compactMap(\.due).min() ?? selectedTasks.compactMap(\.deadline).min() ?? calendar.startOfDay(for: now)
        func offset(_ day: String) -> JSON? { Dates.parse(day).flatMap { calendar.dateComponents([.day], from: anchor, to: $0).day }.map { .number(Double($0)) } }
        func clean(_ task: Record, depth: Int) throws -> Record {
            guard depth <= 10 else { throw AppFailure(message: "This task has too many subtask levels for a template.") }
            var fields = task.fields.filter { Self.taskFields.contains($0.key) }
            fields["labels"] = .array(TaskLabels.normalized(task["labels"].list, labels: labels).compactMap { value in
                guard let label = labels.first(where: { $0.id == value.text || $0.name == value.text }) else { return nil }
                return .object(["name": .string(label.name), "color": .string(label.string("color").isEmpty ? "#e31e4b" : label.string("color"))])
            })
            fields["subtasks"] = .array(try task["subtasks"].list.map { .object(try clean(Record($0.object), depth: depth + 1).fields) })
            fields["planned_offset"] = offset(task.string("due_date")); fields["deadline_offset"] = offset(task.string("deadline_date"))
            var repeatFields = task["recurrence_pattern"].object
            fields["repeat_start_offset"] = offset(repeatFields["startDate"]?.text ?? "")
            fields["repeat_end_offset"] = offset(repeatFields["endDate"]?.text ?? task.string("recurrence_end_date"))
            repeatFields.removeValue(forKey: "startDate"); repeatFields.removeValue(forKey: "endDate")
            if task["is_recurring"].flag { fields["recurrence_pattern"] = .object(repeatFields) }
            if kind == .task { fields["section_id"] = .null }
            return Record(fields)
        }
        let taskGroups = Dictionary(grouping: selectedTasks) { "group:" + $0.string("project_id") + ":" + ($0.string("section_id").isEmpty ? "none" : $0.string("section_id")) }
        let orderedTasks = taskGroups.keys.sorted().flatMap { key in
            DayPlacement.ordered(taskGroups[key]!, ids: snapshot.tables["view_orders"]?.first(where: { $0.id == key })?["ids"].list.map(\.text) ?? [])
        }
        let projectIDs = Set(selectedProjects.map(\.id))
        let projectRows = selectedProjects.map { row -> JSON in
            var fields = row.fields.filter { ["id","name","description","color","parent_id","order_index"].contains($0.key) }
            if !projectIDs.contains(row.string("parent_id")) { fields["parent_id"] = .null }
            return .object(fields)
        }
        return try Self(document: .object(["version": .number(1), "kind": .string(kind.rawValue), "projects": .array(projectRows), "sections": .array(selectedSections.map { .object($0.fields.filter { ["id","name","project_id","order_index"].contains($0.key) }) }), "tasks": .array(try orderedTasks.map { .object(try clean($0, depth: 0).fields) })]))
    }
    func instantiate(account: String, name: String, targetProject: String = "", start: Date? = nil, labels: [Record] = [], run: UUID = UUID()) throws -> [Mutation] {
        guard !account.isEmpty, kind != .project || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, kind != .section || !targetProject.isEmpty else { throw AppFailure(message: "Choose a project name or destination before using this template.") }
        func fresh(_ kind: String, _ id: String) -> String { WorkspaceBackup.stableID("template-run:" + run.uuidString + ":" + kind, id) }
        var changes: [Mutation] = [], labelIDs = Dictionary(labels.map { ($0.name.lowercased(), $0.id) }, uniquingKeysWith: { first, _ in first })
        var projectIDs: [String: String] = [:], sectionIDs: [String: String] = [:]
        for project in projects { projectIDs[project.id] = kind == .project ? fresh("project", project.id) : targetProject }
        if kind == .project {
            let pending = projects.map { row -> Record in
                var row = row; row["id"] = .string(projectIDs[row.id]!); row["user_id"] = .string(account)
                row["parent_id"] = projectIDs[row.string("parent_id")].map(JSON.string) ?? .null
                if row.string("parent_id").isEmpty { row["name"] = .string(name.trimmingCharacters(in: .whitespacesAndNewlines)) }
                row["is_archived"] = .bool(false); return row
            }
            for item in ProjectOrganization.outline(pending) { changes.append(Mutation(table: "projects", recordID: item.id, method: "POST", fields: item.project.fields)) }
        }
        for section in OrganizationOrder.sorted(sections) {
            let id = fresh("section", section.id); sectionIDs[section.id] = id
            var row = section; row["id"] = .string(id); row["user_id"] = .string(account); row["project_id"] = .string(projectIDs[section.string("project_id")] ?? targetProject)
            changes.append(Mutation(table: "sections", recordID: id, method: "POST", fields: row.fields))
        }
        let calendar = Calendar(identifier: .gregorian)
        func day(_ row: Record, _ field: String) -> String? { guard let start, row.fields[field] != nil, let date = calendar.date(byAdding: .day, value: row[field].integer, to: start) else { return nil }; return Dates.day(date) }
        func task(_ source: Record, path: String) -> Record {
            var row = Record.task(user: account, project: projectIDs[source.string("project_id")] ?? targetProject)
            row["id"] = .string(fresh("task", path)); row["task_generation"] = .string(fresh("generation", path))
            for field in ["title","description","priority","duration_minutes"] where source.fields[field] != nil { row[field] = source[field] }
            row["section_id"] = sectionIDs[source.string("section_id")].map(JSON.string) ?? .null
            row["due_date"] = day(source, "planned_offset").map(JSON.string) ?? .null; row["deadline_date"] = day(source, "deadline_offset").map(JSON.string) ?? .null
            if row["due_date"] != .null { row["due_time"] = source["due_time"]; row["time_zone"] = source["time_zone"] }
            if source["is_recurring"].flag {
                var pattern = source["recurrence_pattern"].object
                pattern["startDate"] = day(source, "repeat_start_offset").map(JSON.string)
                pattern["endDate"] = day(source, "repeat_end_offset").map(JSON.string)
                row["is_recurring"] = .bool(true); row["recurrence_pattern"] = .object(pattern); row["recurrence_end_date"] = pattern["endDate"] ?? .null
            }
            row["labels"] = .array(source["labels"].list.map { value in
                let name = value.object["name", default: .null].text, key = name.lowercased()
                if let id = labelIDs[key] { return .string(id) }
                let id = fresh("label", key); labelIDs[key] = id
                changes.append(Mutation(table: "labels", recordID: id, method: "POST", fields: ["id": .string(id), "user_id": .string(account), "name": .string(name), "color": .string(value.object["color"]?.text.isEmpty == false ? value.object["color"]!.text : "#e31e4b")]))
                return .string(id)
            })
            row["subtasks"] = .array(source["subtasks"].list.enumerated().map { index, child in .object(task(Record(child.object), path: path + ":" + String(index)).fields) })
            return row
        }
        var taskChanges: [Mutation] = []
        for source in tasks { let row = task(source, path: fresh("source", source.id)); taskChanges.append(Mutation(table: "tasks", recordID: row.id, method: "POST", fields: row.fields)) }
        var orders: [Mutation] = []
        if kind != .task {
            let groups = Dictionary(grouping: taskChanges) { change in
                let row = Record(change.fields)
                return "group:" + row.string("project_id") + ":" + (row.string("section_id").isEmpty ? "none" : row.string("section_id"))
            }
            for key in groups.keys.sorted() {
                orders.append(Mutation(table: "view_orders", recordID: key, method: "POST", fields: ["id": .string(key), "user_id": .string(account), "ids": .array(groups[key]!.map { .string($0.recordID) })]))
            }
        }
        return changes + taskChanges + orders
    }
}
