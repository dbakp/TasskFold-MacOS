import Foundation

/// Immutable inputs retained only while a workflow is being prepared. A result
/// must be reviewed against the current workspace before entering the save path.
struct WorkflowPreparationContext: Sendable {
    let workspace: WorkspaceBinding
    let session: UUID
    let document: JSON
    let labels: [Record]
    let target: String
    func matches(workspace: WorkspaceBinding, session: UUID, document: JSON?, labels: [Record], projects: [Record]) -> Bool {
        self.workspace == workspace && self.session == session && self.document == document && self.labels == labels &&
        (target.isEmpty || projects.contains { $0.id == target })
    }
}

/// One immutable preview read, scoped to the presentation's workspace and session.
/// Validation runs off the main actor; cancellation reaches the bounded tree walk.
struct WorkflowDefinitionRequest: Equatable, Sendable {
    let workspace: WorkspaceBinding
    let session: UUID
    let source: Record

    func matches(workspace: WorkspaceBinding, session: UUID, source: Record?) -> Bool {
        !self.workspace.account.isEmpty && self.workspace == workspace && self.session == session && self.source == source
    }
    func load() async throws -> WorkflowTemplate {
        try Task.checkCancellation()
        let document = source["document"]
        let worker = Task.detached(priority: .userInitiated) {
            try WorkflowTemplate(document: document, checkCancellation: { try Task.checkCancellation() })
        }
        return try await withTaskCancellationHandler(operation: {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        }, onCancel: { worker.cancel() })
    }
}

/// A workflow file contains a definition, never an account snapshot or live records.
struct WorkflowTemplateFile: Sendable {
    static let maximumBytes = 2_100_000
    let name: String
    let template: WorkflowTemplate

    init(name: String, document: JSON) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 160 else { throw AppFailure(message: "Use a template name between 1 and 160 characters.") }
        self.name = name
        template = try WorkflowTemplate(document: document)
        let repeatFields: Set<String> = ["type", "interval", "dayOfMonth", "daysOfMonth", "monthOfYear", "weekday", "weekdayOrdinal", "daysOfWeek", "count", "fromCompletion"]
        func validateRepeat(_ row: Record) throws {
            guard Set(row["recurrence_pattern"].object.keys).isSubset(of: repeatFields) else {
                throw AppFailure(message: "This template has repeat details that this version cannot share. Its saved definition is unchanged.")
            }
            for child in row["subtasks"].list { try validateRepeat(Record(child.object)) }
        }
        for row in template.tasks { try validateRepeat(row) }
    }

    init(data: Data) throws {
        guard data.count <= Self.maximumBytes else { throw AppFailure(message: "Choose a template file no larger than 2.1 MB.") }
        let prefix = String(decoding: data.prefix(80), as: UTF8.self).replacingOccurrences(of: "\u{feff}", with: "")
        if prefix.hasPrefix("format,document_version,") || prefix.hasPrefix("\"format\",\"document_version\",") { self = try WorkflowTemplateCSV.decode(data); return }
        let value: JSON
        do { value = try TaskfoldJSONDecoder().decode(JSON.self, from: data) }
        catch { throw AppFailure(message: "This isn’t a readable Taskfold template file.") }
        let root = value.object
        guard Set(root.keys) == ["format", "version", "name", "document"], root["format"] == .string("taskfold-template"), [JSON.number(1), .number(2)].contains(root["version"] ?? .null), root["document"]?.object["version"] == root["version"], case .string? = root["name"] else {
            throw AppFailure(message: "Choose a supported Taskfold template file. Workspace backups belong in Restore from file.")
        }
        try self.init(name: root["name"]!.text, document: root["document"]!)
    }

    /// Coordinate provider-backed reads; never load an unbounded file into memory.
    static func read(_ url: URL) throws -> Self { try Self(data: readData(url)) }
    static func readData(_ url: URL) throws -> Data {
        try WorkflowTemplateReadOperation().readData(url)
    }

    func encoded() throws -> Data {
        // Replace source identifiers with file-local references, including nested tasks.
        let projectIDs = Dictionary(uniqueKeysWithValues: template.projects.map(\.id).sorted().enumerated().map { ($0.element, String(format: "project-%04d", $0.offset + 1)) })
        let sectionIDs = Dictionary(uniqueKeysWithValues: template.sections.map(\.id).sorted().enumerated().map { ($0.element, String(format: "section-%04d", $0.offset + 1)) })
        var document = template.document.object
        document["projects"] = .array(template.projects.map { source in
            var row = source
            row["id"] = .string(projectIDs[source.id]!)
            row["parent_id"] = projectIDs[source.string("parent_id")].map(JSON.string) ?? .null
            return .object(row.fields)
        })
        document["sections"] = .array(template.sections.map { source in
            var row = source
            row["id"] = .string(sectionIDs[source.id]!)
            row["project_id"] = .string(projectIDs[source.string("project_id")]!)
            return .object(row.fields)
        })
        func task(_ source: Record, path: String) -> JSON {
            var row = source
            row["id"] = .string(path)
            row["project_id"] = projectIDs[source.string("project_id")].map(JSON.string) ?? .null
            row["section_id"] = sectionIDs[source.string("section_id")].map(JSON.string) ?? .null
            row["labels"] = .array(source["labels"].list.map { label in
                .object(["name": .string(label.object["name"]!.text), "color": .string(label.object["color"]?.text.isEmpty == false ? label.object["color"]!.text : "#e31e4b")])
            })
            row["subtasks"] = .array(source["subtasks"].list.enumerated().map { task(Record($0.element.object), path: path + "-\($0.offset + 1)") })
            return .object(row.fields)
        }
        document["tasks"] = .array(template.tasks.enumerated().map { task($0.element, path: "task-\($0.offset + 1)") })
        let portable = JSON.object(document)
        _ = try WorkflowTemplate(document: portable)
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(JSON.object(["format": .string("taskfold-template"), "version": template.document.object["version"]!, "name": .string(name), "document": portable]))
        guard data.count <= Self.maximumBytes else { throw AppFailure(message: "This template is too large to share as a file.") }
        return data
    }
}

/// Owns one external read so dismissing a review also cancels provider coordination.
/// Security-scoped access remains paired with the actual read, even if a provider
/// finishes late. The UI separately fences results by request and workspace.
final class WorkflowTemplateReadOperation: @unchecked Sendable {
    private let coordinator = NSFileCoordinator()
    private let lock = NSLock()
    private var cancelled = false
    private static var unavailable: AppFailure {
        AppFailure(message: "The template file could not be opened. Make sure it is downloaded and available, then choose it again. Your saved templates are unchanged.")
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        coordinator.cancel()
    }
    private func checkCancellation() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CocoaError(.userCancelled) }
    }
    func readData(_ url: URL) throws -> Data {
        try checkCancellation()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            result = Result {
                try self.checkCancellation()
                do {
                    if let size = try readableURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                       size > WorkflowTemplateFile.maximumBytes {
                        throw AppFailure(message: "Choose a template file no larger than 2.1 MB.")
                    }
                    let handle = try FileHandle(forReadingFrom: readableURL)
                    defer { try? handle.close() }
                    var data = Data()
                    while data.count <= WorkflowTemplateFile.maximumBytes {
                        try self.checkCancellation()
                        let count = min(65_536, WorkflowTemplateFile.maximumBytes + 1 - data.count)
                        guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                        data.append(chunk)
                    }
                    guard data.count <= WorkflowTemplateFile.maximumBytes else {
                        throw AppFailure(message: "Choose a template file no larger than 2.1 MB.")
                    }
                    return data
                } catch let error as AppFailure { throw error }
                catch {
                    try self.checkCancellation()
                    throw Self.unavailable
                }
            }
        }
        try checkCancellation()
        if coordinationError != nil { throw Self.unavailable }
        guard let result else { throw Self.unavailable }
        return try result.get()
    }
}

/// Account-compatible project organization. Archive inheritance is computed from the
/// available graph; the server projection covers an inaccessible shared ancestor.
enum ProjectOrganization {
    static let maximumDepth = 20
    struct Item: Identifiable, Equatable, Sendable {
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
    /// One immutable projection of the current readable project graph. This is
    /// display data, never a cached permission or mutation authorization.
    struct Catalog: Sendable {
        let all: [Record]
        let active: [Record]
        let archived: [Item]
        let archivedIDs: Set<String>
        init(_ projects: [Record]) {
            all = OrganizationOrder.sorted(projects)
            archivedIDs = ProjectOrganization.archivedIDs(in: all)
            active = ProjectOrganization.outline(sorted: all, archivedIDs: archivedIDs, showArchived: false).map(\.project)
            archived = ProjectOrganization.outline(sorted: all, archivedIDs: archivedIDs, showArchived: true)
        }
    }
    static func outline(_ projects: [Record], archived showArchived: Bool = false) -> [Item] {
        outline(sorted: OrganizationOrder.sorted(projects), archivedIDs: archivedIDs(in: projects), showArchived: showArchived)
    }
    private static func outline(sorted rows: [Record], archivedIDs: Set<String>, showArchived: Bool) -> [Item] {
        let visible = rows.filter { archivedIDs.contains($0.id) == showArchived }
        let ids = Set(visible.map(\.id)), grouped = Dictionary(grouping: visible, by: { $0.string("parent_id") })
        var result: [Item] = [], seen = Set<String>()
        func append(_ row: Record, depth: Int) {
            var pending: [(Record, Int)] = [(row, depth)]
            while let (next, level) = pending.popLast() {
                guard seen.insert(next.id).inserted else { continue }
                result.append(Item(project: next, depth: level))
                // Reverse the stack insertion to preserve the existing sibling order.
                for child in (grouped[next.id] ?? []).reversed() {
                    pending.append((child, min(maximumDepth, level + 1)))
                }
            }
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
        guard !project.id.isEmpty, !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              project.string("user_id") == account else { return [] }
        let excluded = descendants(project.id, in: projects)
        // Match validate's canonical rows after replacing every old root copy.
        // Rebuilding this index for each candidate makes large pickers quadratic.
        let rows = Dictionary(projects.filter { $0.id != project.id }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var longestRootPath = 0
        for start in excluded {
            var cursor = start, distance = 0, seen = Set<String>()
            while cursor != project.id, let row = rows[cursor] {
                guard seen.insert(cursor).inserted else { return [] }
                let parent = row.string("parent_id")
                if parent.isEmpty { break }
                guard parent == project.id || rows[parent]?.string("user_id") == account else { return [] }
                distance += 1
                guard distance < maximumDepth else { return [] }
                cursor = parent
            }
            // Duplicate legacy edges can put a raw descendant on an independent
            // canonical ancestry. Validate it above, without charging its depth
            // to the moved root unless that ancestry actually reaches the root.
            if cursor == project.id { longestRootPath = max(longestRootPath, distance) }
        }
        return outline(projects).filter { item in
            guard !excluded.contains(item.id), item.project.string("user_id") == account else { return false }
            // An empty legacy ID produces a top-level draft, just as in validate.
            if item.id.isEmpty { return longestRootPath < maximumDepth }
            var cursor = item.id, depth = 1, seen = Set<String>()
            while let row = rows[cursor] {
                guard cursor != project.id, depth + longestRootPath < maximumDepth,
                      seen.insert(cursor).inserted, row.string("user_id") == account else { return false }
                let parent = row.string("parent_id")
                if parent.isEmpty { return true }
                cursor = parent
                depth += 1
            }
            return false
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
    static func preview(_ text: String, account: String, project: String = "", context: QuickEntryContext = QuickEntryContext(), recognize: Bool = true, defaults: [String: JSON] = [:], now: Date = Date()) throws -> [Line] {
        guard text.utf8.count <= 100_000 else { throw AppFailure(message: "Paste up to 100 KB of task text at a time.") }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines).enumerated().compactMap { index, raw -> (Int, String)? in
            var title = raw.trimmingCharacters(in: .whitespaces)
            title = title.replacingOccurrences(of: #"^(?:[-*•]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
            title = title.replacingOccurrences(of: #"^\[[ xX]\]\s*"#, with: "", options: .regularExpression)
            return title.isEmpty ? nil : (index + 1, title)
        }
        guard lines.count <= maximumLines else { throw AppFailure(message: "Review up to 200 tasks at a time. Nothing has been added.") }
        return lines.map { number, title in
            var task = Record.task(user: account, project: project)
            // Inherit capture choices only. Never reuse identity, completion,
            // notes, discussion, files or child trees from the source draft.
            for key in ["due_date", "due_time", "scheduled_at", "time_zone", "deadline_date", "duration_minutes", "priority", "labels", "reminders", "reminder_specs", "is_recurring", "recurrence_pattern", "recurrence_end_date"] {
                if let value = defaults[key] { task[key] = value }
            }
            if defaults["project_id"]?.text == project {
                task["section_id"] = defaults["section_id"] ?? .null
                task["assigned_to"] = defaults["assigned_to"] ?? .null
            }
            task["title"] = .string(title)
            let parsed = QuickEntry(title, now: now, context: context, task: task)
            return Line(number: number, task: recognize ? parsed.applying(to: task) : task, warnings: recognize ? parsed.warnings : [])
        }
    }
}

/// Private, versioned, reusable workflow definitions. Source IDs are internal
/// references only; every use creates new records and task generations.
struct WorkflowTemplate: Sendable {
    enum Kind: String, Sendable { case project, section, task }
    static let table = "project_templates"
    let document: JSON
    var requiresHeadingSupport: Bool { document.object["version"] == .number(2) }
    var kind: Kind { Kind(rawValue: document.object["kind"]?.text ?? "")! }
    var projects: [Record] { document.object["projects"]?.list.map { Record($0.object) } ?? [] }
    var sections: [Record] { document.object["sections"]?.list.map { Record($0.object) } ?? [] }
    var tasks: [Record] { document.object["tasks"]?.list.map { Record($0.object) } ?? [] }
    private static let taskFields: Set<String> = ["is_heading","id","title","description","priority","project_id","section_id","duration_minutes","labels","subtasks","is_recurring","recurrence_pattern","due_time","time_zone","planned_offset","deadline_offset","repeat_start_offset","repeat_end_offset"]
    init(document: JSON) throws {
        try self.init(document: document, checkCancellation: {})
    }
    init(document: JSON, checkCancellation: () throws -> Void) throws {
        try checkCancellation()
        let root = document.object
        let headingFormat = root["version"] == .number(2) && root["capabilities"] == .array([.string("task_headings")])
        guard (root["version"] == .number(1) && root["capabilities"] == nil || headingFormat), Kind(rawValue: root["kind"]?.text ?? "") != nil,
              Set(root.keys).isSubset(of: ["version","capabilities","kind","projects","sections","tasks"]),
              ["projects","sections","tasks"].allSatisfy({ if case .array? = root[$0] { return true }; return false }) else {
            throw AppFailure(message: "This template needs a newer version of Taskfold.")
        }
        self.document = document
        guard projects.count <= 1000, sections.count <= 5000, tasks.count <= 5000,
              (try TaskfoldJSONEncoder().encode(document)).count <= 2_000_000 else { throw AppFailure(message: "This template is too large.") }
        try checkCancellation()
        func unique(_ rows: [Record]) -> Bool { rows.allSatisfy { !$0.id.isEmpty } && Set(rows.map(\.id)).count == rows.count }
        guard unique(projects), unique(sections), unique(tasks) else { throw AppFailure(message: "The template has missing or duplicate references.") }
        let projectIDs = Set(projects.map(\.id)), sectionRows = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard projects.allSatisfy({ Set($0.fields.keys).isSubset(of: ["id","name","description","color","parent_id","order_index"]) && ($0.string("parent_id").isEmpty || projectIDs.contains($0.string("parent_id"))) }),
              sections.allSatisfy({ Set($0.fields.keys).isSubset(of: ["id","name","project_id","order_index"]) && projectIDs.contains($0.string("project_id")) }) else { throw AppFailure(message: "The template contains an unavailable project or section.") }
        for row in projects + sections {
            try checkCancellation()
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
            try checkCancellation()
            var cursor = project.id, seen = Set<String>()
            while let row = projects.first(where: { $0.id == cursor }) {
                try checkCancellation()
                guard seen.insert(cursor).inserted, seen.count <= ProjectOrganization.maximumDepth else { throw AppFailure(message: "The template project hierarchy is invalid.") }
                cursor = row.string("parent_id")
            }
        }
        func checkTask(_ task: Record, depth: Int) throws {
            try checkCancellation()
            if let type = task.fields["is_heading"] {
                guard headingFormat, case .bool = type else { throw AppFailure(message: "This template task type needs a supported heading format.") }
            }
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
    fileprivate static func captureSources(kind: Kind, id: String, snapshot: Snapshot) throws -> [String: [Record]] {
        let allProjects = snapshot.tables["projects"] ?? [], allTasks = snapshot.tables["tasks"] ?? [], allSections = snapshot.tables["sections"] ?? []
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
        for rows in [selectedProjects, selectedSections, selectedTasks] {
            guard Set(rows.map(\.id)).count == rows.count else { throw AppFailure(message: "This workflow has ambiguous references. Review the source before saving a template.") }
        }
        let groups = Set(selectedTasks.map { "group:" + $0.string("project_id") + ":" + ($0.string("section_id").isEmpty ? "none" : $0.string("section_id")) })
        return ["projects": selectedProjects, "sections": selectedSections, "tasks": selectedTasks,
                "view_orders": (snapshot.tables["view_orders"] ?? []).filter { groups.contains($0.id) }]
    }
    static func capture(kind: Kind, id: String, snapshot: Snapshot, now: Date = Date(), teamCache: TeamWorkspaceCache? = nil) throws -> Self {
        let sources = try captureSources(kind: kind, id: id, snapshot: snapshot)
        let selectedProjects = sources["projects"]!, selectedSections = sources["sections"]!, selectedTasks = sources["tasks"]!, labels = snapshot.tables["labels"] ?? []
        let calendar = Calendar(identifier: .gregorian)
        let anchor = selectedTasks.compactMap(\.due).min() ?? selectedTasks.compactMap(\.deadline).min() ?? calendar.startOfDay(for: now)
        func offset(_ day: String) -> JSON? { Dates.parse(day).flatMap { calendar.dateComponents([.day], from: anchor, to: $0).day }.map { .number(Double($0)) } }
        func clean(_ task: Record, depth: Int, shared: Bool) throws -> Record {
            guard depth <= 10 else { throw AppFailure(message: "This task has too many subtask levels for a template.") }
            guard TaskKind(task) != .unsupported else { throw AppFailure(message: "This task type cannot be copied into a template yet. Its source is unchanged.") }
            var fields = task.fields.filter { Self.taskFields.contains($0.key) }
            if TaskKind(task) != .heading { fields.removeValue(forKey: "is_heading") }
            if shared {
                let draft = TeamTaskLabelsDraft(task["labels"])
                guard draft.supported else { throw AppFailure(message: "These shared labels need a newer version before saving a template. The source is unchanged.") }
                fields["labels"] = .array(try draft.entries.map { entry in
                    guard let name = TeamTaskLabelsDraft.displayName(entry.value) else { throw AppFailure(message: "Review unsupported shared labels before saving a template. The source is unchanged.") }
                    return .object(["name": .string(name), "color": .string("#e31e4b")])
                })
            } else {
            fields["labels"] = .array(TaskLabels.normalized(task["labels"].list, labels: labels).compactMap { value in
                guard let label = labels.first(where: { $0.id == value.text || $0.name == value.text }) else { return nil }
                return .object(["name": .string(label.name), "color": .string(label.string("color").isEmpty ? "#e31e4b" : label.string("color"))])
            })
            }
            fields["subtasks"] = .array(try task["subtasks"].list.map { .object(try clean(Record($0.object), depth: depth + 1, shared: shared).fields) })
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
        let cleaned = try orderedTasks.map { try clean($0, depth: 0, shared: !TeamTaskLabelsDraft.usesPersonalCatalog($0, cache: teamCache)) }
        let headings = TaskKind.containsTypeMetadata(cleaned)
        var definition: [String: JSON] = ["version": .number(headings ? 2 : 1), "kind": .string(kind.rawValue), "projects": .array(projectRows), "sections": .array(selectedSections.map { .object($0.fields.filter { ["id","name","project_id","order_index"].contains($0.key) }) }), "tasks": .array(cleaned.map { .object($0.fields) })]
        if headings { definition["capabilities"] = .array([.string("task_headings")]) }
        return try Self(document: .object(definition))
    }
    func instantiate(account: String, name: String, targetProject: String = "", start: Date? = nil, labels: [Record] = [], run: UUID = UUID(), checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> [Mutation] {
        try checkCancellation()
        guard !account.isEmpty, kind != .project || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, kind != .section || !targetProject.isEmpty else { throw AppFailure(message: "Choose a project name or destination before using this template.") }
        func fresh(_ kind: String, _ id: String) -> String { WorkspaceBackup.stableID("template-run:" + run.uuidString + ":" + kind, id) }
        var changes: [Mutation] = [], labelIDs = Dictionary(labels.map { ($0.name.lowercased(), $0.id) }, uniquingKeysWith: { first, _ in first })
        var projectIDs: [String: String] = [:], sectionIDs: [String: String] = [:]
        for project in projects { try checkCancellation(); projectIDs[project.id] = kind == .project ? fresh("project", project.id) : targetProject }
        if kind == .project {
            let pending = try projects.map { row -> Record in
                try checkCancellation()
                var row = row; row["id"] = .string(projectIDs[row.id]!); row["user_id"] = .string(account)
                row["parent_id"] = projectIDs[row.string("parent_id")].map(JSON.string) ?? .null
                if row.string("parent_id").isEmpty { row["name"] = .string(name.trimmingCharacters(in: .whitespacesAndNewlines)) }
                row["is_archived"] = .bool(false); return row
            }
            for item in ProjectOrganization.outline(pending) { try checkCancellation(); changes.append(Mutation(table: "projects", recordID: item.id, method: "POST", fields: item.project.fields)) }
        }
        for section in OrganizationOrder.sorted(sections) {
            try checkCancellation()
            let id = fresh("section", section.id); sectionIDs[section.id] = id
            var row = section; row["id"] = .string(id); row["user_id"] = .string(account); row["project_id"] = .string(projectIDs[section.string("project_id")] ?? targetProject)
            changes.append(Mutation(table: "sections", recordID: id, method: "POST", fields: row.fields))
        }
        let calendar = Calendar(identifier: .gregorian)
        // This formatter belongs only to this synchronous instantiation. Keep a
        // separate current-time sample for each task, including nested children.
        let creationTimestamps = ISO8601DateFormatter()
        func day(_ row: Record, _ field: String) -> String? { guard let start, row.fields[field] != nil, let date = calendar.date(byAdding: .day, value: row[field].integer, to: start) else { return nil }; return Dates.day(date) }
        func task(_ source: Record, path: String) throws -> Record {
            try checkCancellation()
            var row = Record.task(user: account, project: projectIDs[source.string("project_id")] ?? targetProject, createdAt: creationTimestamps.string(from: Date()))
            row["id"] = .string(fresh("task", path)); row["task_generation"] = .string(fresh("generation", path))
            for field in ["is_heading","title","description","priority","duration_minutes"] where source.fields[field] != nil { row[field] = source[field] }
            row["section_id"] = sectionIDs[source.string("section_id")].map(JSON.string) ?? .null
            row["due_date"] = day(source, "planned_offset").map(JSON.string) ?? .null; row["deadline_date"] = day(source, "deadline_offset").map(JSON.string) ?? .null
            if row["due_date"] != .null { row["due_time"] = source["due_time"]; row["time_zone"] = source["time_zone"] }
            if source["is_recurring"].flag {
                var pattern = source["recurrence_pattern"].object
                pattern["startDate"] = day(source, "repeat_start_offset").map(JSON.string)
                pattern["endDate"] = day(source, "repeat_end_offset").map(JSON.string)
                row["is_recurring"] = .bool(true); row["recurrence_pattern"] = .object(pattern); row["recurrence_end_date"] = pattern["endDate"] ?? .null
            }
            row["labels"] = .array(try source["labels"].list.map { value in
                try checkCancellation()
                let name = value.object["name", default: .null].text, key = name.lowercased()
                if let id = labelIDs[key] { return .string(id) }
                let id = fresh("label", key); labelIDs[key] = id
                changes.append(Mutation(table: "labels", recordID: id, method: "POST", fields: ["id": .string(id), "user_id": .string(account), "name": .string(name), "color": .string(value.object["color"]?.text.isEmpty == false ? value.object["color"]!.text : "#e31e4b")]))
                return .string(id)
            })
            row["subtasks"] = .array(try source["subtasks"].list.enumerated().map { index, child in .object(try task(Record(child.object), path: path + ":" + String(index)).fields) })
            return row
        }
        var taskChanges: [Mutation] = []
        for source in tasks { let row = try task(source, path: fresh("source", source.id)); taskChanges.append(Mutation(table: "tasks", recordID: row.id, method: "POST", fields: row.fields)) }
        var orders: [Mutation] = []
        if kind != .task {
            let groups = Dictionary(grouping: taskChanges) { change in
                let row = Record(change.fields)
                return "group:" + row.string("project_id") + ":" + (row.string("section_id").isEmpty ? "none" : row.string("section_id"))
            }
            for key in groups.keys.sorted() {
                try checkCancellation()
                orders.append(Mutation(table: "view_orders", recordID: key, method: "POST", fields: ["id": .string(key), "user_id": .string(account), "ids": .array(groups[key]!.map { .string($0.recordID) })]))
            }
        }
        // Every row belongs to this run's fresh identities (including its list
        // order). A retry after a lost reply must not upsert over later edits.
        return try (changes + taskChanges + orders).map { change in
            try checkCancellation()
            var change = change; change.insertOnly = true; change.workflowRun = run; return change
        }
    }
}

/// Template edits change a definition, never the tasks created by a previous run.
enum TemplateEditing {
    struct TaskItem: Identifiable {
        let root: Int
        let path: [Int]
        let record: Record
        let siblingCount: Int
        var depth: Int { path.count }
        var id: String { ([root] + path).map(String.init).joined(separator: ".") }
    }
    static func tasks(_ document: JSON) -> [TaskItem] {
        var result: [TaskItem] = []
        func visit(_ row: Record, root: Int, path: [Int], count: Int) {
            guard path.count <= 10 else { return }
            result.append(TaskItem(root: root, path: path, record: row, siblingCount:count))
            for (index, child) in row["subtasks"].list.enumerated() { visit(Record(child.object), root: root, path: path + [index],count:row["subtasks"].list.count) }
        }
        for (index, row) in document.object["tasks", default: .null].list.enumerated() { visit(Record(row.object), root: index, path: [],count:document.object["tasks",default:.null].list.count) }
        return result
    }
    /// One draft edit, with explicit format promotion only when a heading is introduced.
    /// A sheet captured before a move/replacement cannot edit a different item at that path.
    static func editingTask(_ document: JSON, item: TaskItem, fields: [String: JSON], headingsEnabled: Bool) throws -> JSON {
        _ = try WorkflowTemplate(document: document)
        guard let current = tasks(document).first(where: { $0.id == item.id }), current.record == item.record else {
            throw AppFailure(message: "This template task changed. Reopen its current details before saving.")
        }
        var fields = fields, root = document.object
        if let type = fields["is_heading"] {
            guard case .bool(let heading) = type else { throw AppFailure(message: "Choose a supported template task type.") }
            if TaskKind(item.record) == (heading ? .heading : .task) { fields.removeValue(forKey: "is_heading") }
            else {
                guard headingsEnabled else { throw AppFailure(message: "Changing template task types isn’t available in this app version. Your definition is unchanged.") }
                if root["version"] == .number(1) {
                    root["version"] = .number(2); root["capabilities"] = .array([.string("task_headings")])
                }
            }
        }
        return try changing(.object(root), item: item, fields: fields)
    }
    static func changing(_ document: JSON, item: TaskItem, fields: [String: JSON], remove: Bool = false) throws -> JSON {
        var root = document.object, rows = root["tasks", default: .null].list
        func change(_ rows: inout [JSON], path: [Int]) throws {
            guard let index = path.first, rows.indices.contains(index) else { throw AppFailure(message: "This template changed. Reopen its current task.") }
            if path.count == 1 {
                if remove { rows.remove(at:index) }
                else {
                    var row=rows[index].object.merging(fields) { _, new in new }
                    for key in ["planned_offset","deadline_offset"] where row[key] == .null { row.removeValue(forKey:key) }
                    rows[index] = .object(row)
                }
            } else {
                var row=rows[index].object, children=row["subtasks",default:.null].list
                try change(&children,path:Array(path.dropFirst()));row["subtasks"] = .array(children);rows[index] = .object(row)
            }
        }
        try change(&rows,path:[item.root]+item.path);root["tasks"] = .array(rows)
        return try WorkflowTemplate(document:.object(root)).document
    }
    static func moving(_ document:JSON,item:TaskItem,delta:Int) throws -> JSON {
        guard [-1,1].contains(delta) else { throw AppFailure(message:"Choose a sibling move.") }
        var root=document.object
        func move(_ rows:[JSON],path:[Int]) throws -> [JSON] {
            var rows=rows;guard let index=path.first,rows.indices.contains(index) else { throw AppFailure(message:"This template changed.") }
            if path.count==1 {
                guard rows.indices.contains(index+delta) else { throw AppFailure(message:"This task is already at the end of its group.") }
                rows.swapAt(index,index+delta)
            } else {
                var row=rows[index].object;row["subtasks"] = .array(try move(row["subtasks",default:.null].list,path:Array(path.dropFirst())));rows[index] = .object(row)
            }
            return rows
        }
        root["tasks"] = .array(try move(root["tasks",default:.null].list,path:[item.root]+item.path))
        return try WorkflowTemplate(document:.object(root)).document
    }
    static func adding(_ document: JSON, parent: TaskItem? = nil) throws -> JSON {
        let definition=try WorkflowTemplate(document:document)
        var row=Record(["id":.string(UUID().uuidString.lowercased()),"title":.string("New task"),"description":.string(""),"priority":.number(4),"labels":.array([]),"subtasks":.array([])])
        if let parent {
            guard parent.depth < 10 else { throw AppFailure(message:"Use up to ten subtask levels in a template.") }
            row["project_id"]=parent.record["project_id"]
            var children=parent.record["subtasks"].list;children.append(.object(row.fields))
            return try changing(document,item:parent,fields:["subtasks":.array(children)])
        }
        guard definition.kind != .task else { throw AppFailure(message:"A task template has one main task. Add a subtask instead.") }
        row["project_id"] = definition.projects.first.map { .string($0.id) } ?? .null
        row["section_id"] = definition.kind == .section ? definition.sections.first.map { .string($0.id) } ?? .null : .null
        var root=document.object, rows=definition.tasks.map { JSON.object($0.fields) };rows.append(.object(row.fields));root["tasks"] = .array(rows)
        return try WorkflowTemplate(document:.object(root)).document
    }
    static func renamed(_ document: JSON, table: String, id: String, name: String) throws -> JSON {
        guard ["projects","sections"].contains(table) else { throw AppFailure(message:"Choose a project or section.") }
        var root=document.object, rows=root[table,default:.null].list
        guard let index=rows.firstIndex(where:{$0.object["id"]?.text==id}) else { throw AppFailure(message:"This template changed.") }
        var row=rows[index].object;row["name"] = .string(name.trimmingCharacters(in:.whitespacesAndNewlines));rows[index] = .object(row);root[table] = .array(rows)
        return try WorkflowTemplate(document:.object(root)).document
    }
    static func edit(original: Record, name: String, document: JSON, current: Record?) throws -> Record {
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard (1...160).contains(name.count) else { throw AppFailure(message:"Use a template name between 1 and 160 characters.") }
        guard let current, current.id==original.id,
              current["name"]==original["name"],current["document"]==original["document"] else {
            throw AppFailure(message:"The template changed or was removed. Your draft is still here; reopen the current template before saving.")
        }
        _ = try WorkflowTemplate(document:document)
        var saved=current;saved["name"] = .string(name);saved["document"]=document;return saved
    }
    static func resolving(_ conflict: SyncConflict, snapshot: Snapshot, keepLocal: Bool) -> Snapshot? {
        let change=conflict.mutation, remote=conflict.remote
        guard change.table==WorkflowTemplate.table,["POST","PATCH","DELETE"].contains(change.method),remote.id.lowercased()==change.recordID.lowercased(),
              let index=snapshot.pending.firstIndex(of:change) else { return nil }
        var result=snapshot
        let missing=remote["document"] == .null
        if keepLocal, !missing, change.fields["document"] != nil, (try? WorkflowTemplate(document:remote["document"])) == nil { return nil }
        if missing && keepLocal {
            guard change.method=="PATCH",let base=change.baseline,base["document"] != nil,base["name"] != nil else { return nil }
            let newID=UUID().uuidString.lowercased()
            var fields=base.merging(change.fields){_,new in new};fields["id"] = .string(newID)
            fields = fields.filter { ["id","user_id","name","document"].contains($0.key) }
            guard fields["user_id"] != nil,(try? WorkflowTemplate(document:fields["document"] ?? .null)) != nil else { return nil }
            result.pending[index]=Mutation(table:WorkflowTemplate.table,recordID:newID,method:"POST",fields:fields,insertOnly:true)
            for later in result.pending.indices where later>index && result.pending[later].table==WorkflowTemplate.table && result.pending[later].recordID==change.recordID {
                result.pending[later].recordID=newID
                if result.pending[later].fields["id"] != nil { result.pending[later].fields["id"] = .string(newID) }
                if result.pending[later].baseline?["id"] != nil { result.pending[later].baseline?["id"] = .string(newID) }
            }
        } else if keepLocal {
            if change.method=="POST" {
                guard let name=change.fields["name"],let document=change.fields["document"],(try? WorkflowTemplate(document:document)) != nil else { return nil }
                result.pending[index].method="PATCH";result.pending[index].fields=["name":name,"document":document]
            }
            result.pending[index].baseline=remote.fields
        } else {
            result.pending.remove(at:index)
            if missing { result.pending.removeAll{$0.table==WorkflowTemplate.table && $0.recordID==change.recordID} }
        }
        var rows=result.tables[WorkflowTemplate.table] ?? [];rows.removeAll{$0.id.lowercased()==change.recordID.lowercased()}
        if !missing { var row=remote;row["id"] = .string(change.recordID);rows.append(row) }
        result.tables[WorkflowTemplate.table]=rows
        for pending in result.pending where pending.table==WorkflowTemplate.table { result.apply(pending) }
        return result
    }
    static func taskSummary(_ task: Record) -> String {
        var parts=[task.priority==4 ? "No priority" : "Priority \(task.priority)"]
        if TaskKind(task) == .heading { parts.insert("Heading · stays open", at: 0) }
        if let minutes=task.durationMinutes { parts.append("\(minutes) min") }
        for (key,title) in [("planned_offset","Planned day"),("deadline_offset","Deadline day"),("repeat_start_offset","Repeat starts day"),("repeat_end_offset","Repeat ends day")] {
            if case .number(let value)=task[key] { parts.append(title+" "+String(Int(value))) }
        }
        if !task.string("due_time").isEmpty { parts.append(task.string("due_time")+(task.string("time_zone").isEmpty ? " local time" : " "+task.string("time_zone"))) }
        let labels=task["labels"].list.map{$0.object["name",default:.null].text}.filter{!$0.isEmpty};if !labels.isEmpty { parts.append(labels.joined(separator:", ")) }
        if task["is_recurring"].flag { parts.append(Recurrence.summary(Record(task["recurrence_pattern"].object))) }
        return parts.joined(separator:" · ")
    }
    static func reviewText(_ document:JSON) -> String {
        guard let definition=try? WorkflowTemplate(document:document) else { return "This definition needs a newer Taskfold version. Its content is preserved." }
        let projects=Dictionary(uniqueKeysWithValues:definition.projects.map{($0.id,$0.name)}),sections=Dictionary(uniqueKeysWithValues:definition.sections.map{($0.id,$0.name)})
        var lines=[summary(document)]
        for item in ProjectOrganization.outline(definition.projects) {
            let row=item.project
            lines.append("Project: "+row.name+(row.string("parent_id").isEmpty ? "" : " · inside "+(projects[row.string("parent_id")] ?? "project")))
            if !row.string("description").isEmpty { lines.append(row.string("description")) }
            if !row.string("color").isEmpty { lines.append("Color: "+row.string("color")) }
        }
        for row in OrganizationOrder.sorted(definition.sections) { lines.append("Section: "+row.name+" · "+(projects[row.string("project_id")] ?? "Chosen destination")) }
        for item in tasks(document) {
            let row=item.record
            lines.append((item.depth==0 ? "Task: " : "Subtask level \(item.depth): ")+row.title)
            if !row.string("description").isEmpty { lines.append(row.string("description")) }
            if definition.kind == .project && item.depth==0 { lines.append((projects[row.string("project_id")] ?? "Project")+(sections[row.string("section_id")].map{" · "+$0} ?? "")) }
            lines.append(taskSummary(row))
        }
        return lines.joined(separator:"\n\n")
    }
    static func summary(_ document: JSON) -> String {
        guard let definition=try? WorkflowTemplate(document:document) else { return "Unsupported template definition" }
        return summary(definition)
    }
    static func summary(_ definition: WorkflowTemplate) -> String {
        let items=tasks(definition.document), headings=items.filter { TaskKind($0.record) == .heading }.count
        let count=items.count-headings
        func label(_ count:Int,_ noun:String) -> String { "\(count) "+noun+(count==1 ? "" : "s") }
        return label(definition.projects.count,"project")+" · "+label(definition.sections.count,"section")+" · "+(count==1 ? "1 task" : "\(count) tasks and subtasks")+(headings == 0 ? "" : " · "+label(headings,"heading"))
    }
}

/// In-memory admission for copying readable shared work into a private template.
/// It is never encoded or treated as permission to create tasks in a team project.
struct WorkflowTemplateCapture: Identifiable {
    let id = UUID()
    let workspace: WorkspaceBinding
    let template: WorkflowTemplate
    let shared: Bool
    private let kind: WorkflowTemplate.Kind
    private let sourceID: String
    private let opened: Date
    private let session: UUID
    private let origin: String?
    private let sources: [String: [Record]]
    private let sharedProjects: Set<String>
    private let sharedTasks: Set<String>
    private let token: String?
    static var changed: AppFailure { AppFailure(message: "The source or its access changed. Close this review and capture the current workflow again. No template was saved.") }
    init(kind: WorkflowTemplate.Kind, sourceID: String, snapshot: Snapshot, workspace: WorkspaceBinding, session: UUID, origin: String?, teamCache: TeamWorkspaceCache?, now: Date = Date()) throws {
        self.kind = kind; self.sourceID = sourceID; self.workspace = workspace; self.session = session; self.origin = origin; opened = now
        let raw = try WorkflowTemplate.captureSources(kind: kind, id: sourceID, snapshot: snapshot)
        sources = raw.mapValues { $0.sorted { $0.id < $1.id } }
        sharedProjects = Set((raw["projects"] ?? []).map(\.id)).intersection(Set(teamCache?.knownTeams.keys.map { $0 } ?? []))
        sharedTasks = Set((raw["tasks"] ?? []).map(\.id)).intersection(teamCache?.knownTasks ?? [])
        shared = !sharedProjects.isEmpty || !sharedTasks.isEmpty
        if shared {
            guard let teamCache, let origin, teamCache.boundary.belongs(account: workspace.account, origin: origin),
                  (raw["tasks"] ?? []).allSatisfy({ task in
                      TeamTaskLabelsDraft.usesPersonalCatalog(task, cache: teamCache) || teamCache.boundary.projects[task.string("project_id")]?.team != nil
                  }), sharedProjects.allSatisfy({ teamCache.boundary.projects[$0]?.team != nil }) else { throw Self.changed }
            token = teamCache.boundary.raw["token"]?.text
        } else { token = nil }
        template = try WorkflowTemplate.capture(kind: kind, id: sourceID, snapshot: snapshot, now: now, teamCache: teamCache)
    }
    func reviewed(snapshot: Snapshot, workspace: WorkspaceBinding, session: UUID, origin: String?, teamCache: TeamWorkspaceCache?) throws {
        guard self.workspace == workspace, self.session == session, self.origin == origin else { throw Self.changed }
        let current = try Self(kind: kind, sourceID: sourceID, snapshot: snapshot, workspace: workspace, session: session, origin: origin, teamCache: teamCache, now: opened)
        guard sources == current.sources, sharedProjects == current.sharedProjects, sharedTasks == current.sharedTasks,
              token == current.token, template.document == current.template.document else { throw Self.changed }
    }
}

/// Frozen preview for a future atomic team-workflow command. These are content
/// rows, deliberately not personal Mutations: a caller cannot commit a partial
/// shared run through the personal writer. Service admission is still required.
struct TeamWorkflowRunPlan: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Source: Equatable, Sendable {
        case personal(Record)
        case shared(TeamTemplateDetail)
        var document: JSON {
            switch self { case .personal(let row): row["document"]; case .shared(let detail): detail.document }
        }
    }
    enum Destination: Equatable, Sendable {
        case newProject(TeamProjectVisibility, folder: String? = nil, parent: TeamProjectAccess? = nil)
        case project(TeamProjectAccess)
    }
    struct Order: Equatable, Sendable {
        let project: String
        let section: String?
        let tasks: [String]
    }
    let account: String
    let origin: String
    let team: TeamOrganization
    let source: Source
    let supportsHeadings: Bool
    let destination: Destination
    let workspace: WorkspaceBinding
    let session: UUID
    let run: UUID
    let projects: [Record]
    let sections: [Record]
    let tasks: [Record]
    let orders: [Order]
    var contentsSummary: String {
        var roots = 0, checklist = 0, headings = 0
        for row in tasks {
            if TaskKind(row) == .heading { headings += 1 } else { roots += 1 }
            for child in (try? TeamChecklist.indexed(row["subtasks"]))?.values ?? [:].values {
                if TaskKind(Record(child)) == .heading { headings += 1 } else { checklist += 1 }
            }
        }
        let groups: [(Int, String)] = [(projects.count, "project"), (sections.count, "section"), (roots, "task"), (checklist, "checklist item"), (headings, "heading")]
        var parts: [String] = []
        for (count, noun) in groups where count > 0 { parts.append(String(count) + " " + noun + (count == 1 ? "" : "s")) }
        return parts.joined(separator: " · ")
    }
    var description: String { "Private shared workflow run preview" }
    var debugDescription: String { description }
    static let headingClientUnavailableMessage = "Creating shared workflows with headings isn’t available in this app version. Your template is unchanged."
    static let headingWorkspaceUnavailableMessage = "Headings aren’t available in this shared workspace yet. Your template is unchanged."
    static var invalid: AppFailure { AppFailure(message: "The template or destination changed. Review the workflow again before creating it.") }

    init(source: Source, account: String, origin: String, team: TeamOrganization,
         destination: Destination, name: String, start: Date? = nil,
         workspace: WorkspaceBinding, session: UUID, run: UUID = UUID(),
         createdAt: Date = Date(), supportsHeadings: Bool = false) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard workspace.account == account, !team.archived, TeamProjectValue.id(run.uuidString.lowercased()),
              (-62135596800...253402214400).contains(createdAt.timeIntervalSince1970), start == nil || (-62135596800...253402214400).contains(start!.timeIntervalSince1970) else { throw Self.invalid }
        switch source {
        case .personal(let row):
            guard TeamProjectValue.id(row.id), row["user_id"] == .string(account), row["team_id"] == .null else { throw Self.invalid }
        case .shared(let detail):
            guard detail.scope.account == account, detail.scope.origin == origin else { throw Self.invalid }
        }
        let definition = try WorkflowTemplate(document: source.document)
        guard !definition.requiresHeadingSupport || supportsHeadings else { throw Self.invalid }
        let target: String
        switch destination {
        case .newProject(_, let folder, let parent):
            guard definition.kind == .project, team.role != .guest, folder == nil || TeamProjectValue.id(folder!) else { throw Self.invalid }
            if let parent {
                guard parent.belongs(to: account, origin: origin, team: team.id), parent.role == .manager,
                      parent.state == .active, !parent.setupPaused, parent.teamRevision == team.revision,
                      let archive = parent.archive, !archive.effective, let hierarchy = parent.hierarchy,
                      !hierarchy.parentUnavailable else { throw Self.invalid }
            }
            _ = try TeamOrganizationValue.name(.string(name.trimmingCharacters(in: .whitespacesAndNewlines)))
            target = ""
        case .project(let access):
            guard definition.kind != .project, access.belongs(to: account, origin: origin, team: team.id),
                  access.state == .active, !access.setupPaused, access.teamRevision == team.revision,
                  access.role != .viewer, let archive = access.archive, !archive.effective,
                  let hierarchy = access.hierarchy, !hierarchy.parentUnavailable else { throw Self.invalid }
            target = access.id
        }
        let changes = try definition.instantiate(account: account, name: name, targetProject: target, start: start, run: run)
        let stamp = ISO8601DateFormatter().string(from: createdAt)
        var projectRows: [Record] = [], sectionRows: [Record] = [], taskRows: [Record] = [], orderRows: [Order] = []
        func task(_ row: Record, source: Record, child: Bool = false) throws -> Record {
            guard !child || !source["is_recurring"].flag else { throw AppFailure(message: "Repeating checklist items need a newer shared-workflow format. The template is unchanged.") }
            var row = row
            let labels = source["labels"].list.map { $0.object["name"] ?? .null }
            let value = JSON.array(labels)
            guard TeamTaskLabelsDraft(value).supported else { throw Self.invalid }
            row["labels"] = value
            // Retain spelling and case, including child-specific names. Never
            // resolve through the user's personal label IDs or catalog colors.
            row["created_at"] = .string(stamp)
            let children = row["subtasks"].list, original = source["subtasks"].list
            guard children.count == original.count else { throw Self.invalid }
            row["subtasks"] = .array(try zip(children, original).map { .object(try task(Record($0.0.object), source: Record($0.1.object), child: true).fields) })
            if child {
                let fields: Set<String> = ["is_heading", "id", "title", "description", "completed", "completed_at", "priority", "due_date", "due_time", "deadline_date", "duration_minutes", "time_zone", "labels", "subtasks"]
                row = Record(row.fields.filter { fields.contains($0.key) })
            }
            return row
        }
        var sourceIndex = 0
        for change in changes {
            var row = Record(change.fields)
            switch change.table {
            case "projects":
                row["team_id"] = .string(team.id)
                guard case .newProject(let visibility, _, _) = destination else { throw Self.invalid }
                row["visibility"] = .string(visibility.rawValue)
                projectRows.append(row)
            case "sections": sectionRows.append(row)
            case "tasks":
                guard sourceIndex < definition.tasks.count else { throw Self.invalid }
                row = try task(row, source: definition.tasks[sourceIndex])
                let scope = TeamTaskEditScope(account: account, origin: origin, team: team.id, project: row.string("project_id"), taskTypesProtocol: supportsHeadings ? 1 : nil, taskTypeLifecycleProtocol: supportsHeadings ? 1 : nil)
                let requestID = WorkspaceBackup.stableID("template-checklist:" + run.uuidString, row.id)
                guard let nonce = UUID(uuidString: requestID) else { throw Self.invalid }
                let mutation = try TeamChecklist.preparing(Mutation(id: nonce, table: "tasks", recordID: row.id, method: "POST", fields: row.fields, insertOnly: true, teamTaskScope: scope))
                _ = try scope.lifecycleBody(for: mutation)
                try TeamChecklist.validate(mutation.fields["subtasks"] ?? .array([]))
                taskRows.append(Record(mutation.fields)); sourceIndex += 1
            case "view_orders":
                let ids = row["ids"].list.map(\.text)
                guard let first = ids.first, let task = taskRows.first(where: { $0.id == first }) else { throw Self.invalid }
                orderRows.append(Order(project: task.string("project_id"), section: task["section_id"] == .null ? nil : task.string("section_id"), tasks: ids))
            case "labels": break // Shared labels are inline names, never catalog writes.
            default: throw Self.invalid
            }
        }
        guard sourceIndex == definition.tasks.count else { throw Self.invalid }
        // A one-task template has no personal order mutation; its shared command
        // still needs an explicit append group for the destination.
        if definition.kind == .task, let task = taskRows.first {
            orderRows = [Order(project: task.string("project_id"), section: nil, tasks: [task.id])]
        }
        let identities = projectRows.map(\.id) + sectionRows.map(\.id) + taskRows.map(\.id)
        guard Set(identities).count == identities.count, identities.allSatisfy(TeamProjectValue.id),
              identities.allSatisfy({ $0 != target }),
              try TaskfoldJSONEncoder().encode(projectRows.map(\.fields) + sectionRows.map(\.fields) + taskRows.map(\.fields)).count <= 2_000_000 else { throw Self.invalid }
        self.account = account; self.origin = origin; self.team = team; self.source = source; self.supportsHeadings = definition.requiresHeadingSupport
        self.destination = destination; self.workspace = workspace; self.session = session; self.run = run
        projects = projectRows; sections = sectionRows; tasks = taskRows; orders = orderRows
    }

    /// Freeze the actor's existing group orders along with the reviewed rows.
    /// The caller must persist this exact envelope before dispatching it.
    func requestBody(baseOrders: [String: [String]]) throws -> [String: JSON] {
        let keys = orders.map { "group:" + $0.project + ":" + ($0.section ?? "none") }
        guard Set(keys).count == keys.count, Set(baseOrders.keys) == Set(keys),
              baseOrders.values.allSatisfy({ $0.count <= 10000 && Set($0).count == $0.count && $0.allSatisfy(TeamProjectValue.id) && Set($0).isDisjoint(with: Set(tasks.map(\.id))) }) else { throw Self.invalid }
        let sourceBody: JSON
        switch source {
        case .personal(let row):
            sourceBody = .object(["kind": .string("personal"), "id": .string(row.id), "team_id": .null, "revision": .null, "document": row["document"]])
        case .shared(let detail):
            sourceBody = .object(["kind": .string("shared"), "id": .string(detail.metadata.id), "team_id": .string(detail.scope.team), "revision": .number(detail.metadata.revision), "document": detail.document])
        }
        var target: [String: JSON] = ["project_id": .null, "revision": .null, "visibility": .null, "folder_id": .null, "parent_id": .null, "parent_revision": .null]
        switch destination {
        case .newProject(let visibility, let folder, let parent):
            target["mode"] = .string("new"); target["visibility"] = .string(visibility.rawValue)
            target["folder_id"] = folder.map(JSON.string) ?? .null
            target["parent_id"] = parent.map { .string($0.id) } ?? .null
            target["parent_revision"] = parent.map { .number($0.revision) } ?? .null
        case .project(let access):
            target["mode"] = .string("project"); target["project_id"] = .string(access.id); target["revision"] = .number(access.revision)
        }
        var body: [String: JSON] = ["team_id": .string(team.id), "team_revision": .number(team.revision), "request_id": .string(run.uuidString.lowercased()),
            "source": sourceBody, "destination": .object(target), "projects": .array(projects.map { .object($0.fields) }),
            "sections": .array(sections.map { .object($0.fields) }), "tasks": .array(tasks.map { .object($0.fields) }),
            "orders": .array(zip(orders, keys).map { order, key in .object(["project_id": .string(order.project), "section_id": order.section.map(JSON.string) ?? .null,
                "base_ids": .array(baseOrders[key]!.map(JSON.string)), "task_ids": .array(order.tasks.map(JSON.string))]) })]
        if supportsHeadings { body["workflow_types_protocol"] = .number(1) }
        guard try TaskfoldJSONEncoder().encode(body).count <= 4_200_000 else { throw Self.invalid }
        return body
    }

    /// Compare the complete fresh review, not just a project ID or a creator UUID.
    /// The eventual server transaction must independently recheck live authority.
    func verify(source: Source, team: TeamOrganization, destination: Destination,
                workspace: WorkspaceBinding, session: UUID) throws {
        guard self.source == source, self.team == team, self.destination == destination,
              self.workspace == workspace, self.session == session else { throw Self.invalid }
    }
}

/// A readable, explicitly versioned workflow table. It contains definitions,
/// never live account IDs, completion history or executable mutation queues.
enum WorkflowTemplateCSV {
    static let columns = ["format", "document_version", "workflow", "name", "capabilities", "entity", "id", "parent_id", "project_id", "section_id", "title", "notes", "type", "priority", "estimate_minutes", "color", "order_index", "labels", "planned_offset", "deadline_offset", "repeat_start_offset", "repeat_end_offset", "due_time", "time_zone", "is_recurring", "recurrence_pattern"]
    static let maximumRows = 20_000
    static func failure(_ message: String) -> AppFailure { AppFailure(message: message) }
    /// Protect spreadsheet text while retaining literal apostrophes on roundtrip.
    static func needsEscape(_ value: String) -> Bool {
        value.hasPrefix("'") || value.first.map { "=+-@\t\r\n".contains($0) } == true || value.drop(while: { $0.isWhitespace }).first.map { "=+-@".contains($0) } == true
    }
    static func escape(_ value: String) -> String { needsEscape(value) ? "'" + value : value }
    static func unescape(_ value: String) -> String { value.hasPrefix("'") && needsEscape(String(value.dropFirst())) ? String(value.dropFirst()) : value }
    static func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    static func string(_ value: JSON) throws -> String {
        if value == .null { return "" }
        if case .string(let text) = value { return escape(text) }
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    static func encode(_ file: WorkflowTemplateFile) throws -> Data {
        let portable = try WorkflowTemplateFile(data: file.encoded()).template
        let version = portable.document.object["version"]!.integer
        let metadata = ["format": "taskfold-workflow-v1", "document_version": String(version), "workflow": portable.kind.rawValue, "name": escape(file.name), "capabilities": version == 2 ? "task_headings" : ""]
        var rows = [columns]
        func append(_ entity: String, _ row: Record, parent: String = "") throws {
            var cells = metadata; cells["entity"] = entity
            if entity != "workflow" {
                for key in ["id", "project_id", "section_id", "color", "order_index", "labels", "planned_offset", "deadline_offset", "repeat_start_offset", "repeat_end_offset", "due_time", "time_zone", "is_recurring", "recurrence_pattern", "priority"] { cells[key] = try string(row[key]) }
                cells["parent_id"] = escape(entity == "project" ? row.string("parent_id") : parent)
                cells["title"] = escape(entity == "task" ? row.title : row.name)
                cells["notes"] = escape(row.string("description"))
                cells["estimate_minutes"] = try string(row["duration_minutes"])
                if entity == "task" { cells["type"] = TaskKind(row) == .heading ? "heading" : "task" }
            }
            rows.append(columns.map { cells[$0] ?? "" })
            guard rows.count <= maximumRows + 2 else { throw failure("This workflow is too large for CSV. Use its JSON file instead.") }
        }
        try append("workflow", Record())
        for project in portable.projects { try append("project", project) }
        for section in portable.sections { try append("section", section) }
        func task(_ row: Record, parent: String = "") throws {
            try append("task", row, parent: parent)
            for child in row["subtasks"].list { try task(Record(child.object), parent: row.id) }
        }
        for row in portable.tasks { try task(row) }
        let data = Data((rows.map { $0.map(quote).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n").utf8)
        guard data.count <= WorkflowTemplateFile.maximumBytes else { throw failure("This CSV exceeds 2.1 MB. Use the workflow’s JSON file instead.") }
        return data
    }
    /// Strict bounded UTF-8 CSV parsing, including quoted newlines and doubled quotes.
    static func rows(_ data: Data, maximumColumns: Int = columns.count) throws -> [[String]] {
        guard data.count <= WorkflowTemplateFile.maximumBytes else { throw failure("Choose template text no larger than 2.1 MB.") }
        var bytes = Array(data); if bytes.starts(with: [239,187,191]) { bytes.removeFirst(3) }
        var result: [[String]] = [], row: [String] = [], cell: [UInt8] = [], quoted = false, closed = false, started = false, index = 0
        func field() throws {
            guard let text = String(bytes: cell, encoding: .utf8) else { throw failure("This CSV is not valid UTF-8 text.") }
            row.append(text); cell.removeAll(keepingCapacity: true); closed = false; started = false
            guard row.count <= maximumColumns else { throw failure("The CSV has extra columns. Its source is unchanged.") }
        }
        func record() throws {
            try field(); result.append(row); row.removeAll(keepingCapacity: true)
            guard result.count <= maximumRows + 2 else { throw failure("Review up to 20,000 workflow rows at a time.") }
        }
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if quoted {
                if byte == 34 {
                    if index < bytes.count && bytes[index] == 34 { cell.append(34); index += 1 }
                    else { quoted = false; closed = true }
                } else { cell.append(byte) }
            } else if byte == 44 { try field() }
            else if byte == 10 || byte == 13 {
                if byte == 13 && index < bytes.count && bytes[index] == 10 { index += 1 }
                try record()
            } else if byte == 34 && !started && !closed { quoted = true; started = true }
            else {
                guard !closed && byte != 34 else { throw failure("The CSV has an invalid quoted field. Check its quotes before importing.") }
                started = true; cell.append(byte)
            }
        }
        guard !quoted else { throw failure("The CSV ends inside a quoted field. Nothing has been imported.") }
        if started || closed || !cell.isEmpty || !row.isEmpty { try record() }
        return result
    }
    static func decode(_ data: Data) throws -> WorkflowTemplateFile {
        let rows = try rows(data)
        guard rows.count >= 2, rows[0] == columns, rows.allSatisfy({ $0.count == columns.count }) else { throw failure("Choose a Taskfold workflow CSV with its complete header. Other task CSV formats need a reviewed mapping.") }
        let tables = rows.dropFirst().map { Dictionary(uniqueKeysWithValues: zip(columns, $0)) }
        let metadata = tables[0]
        guard metadata["format"] == "taskfold-workflow-v1", ["1", "2"].contains(metadata["document_version"] ?? ""), metadata["entity"] == "workflow",
              let kind = WorkflowTemplate.Kind(rawValue: metadata["workflow"] ?? ""),
              metadata["capabilities"] == (metadata["document_version"] == "2" ? "task_headings" : "") else { throw failure("This workflow CSV requires a supported format and heading capability.") }
        let metaKeys = ["format", "document_version", "workflow", "name", "capabilities"]
        guard tables.allSatisfy({ row in metaKeys.allSatisfy { row[$0] == metadata[$0] } }) else { throw failure("The CSV combines different workflow definitions. Import each file separately.") }
        func text(_ row: [String:String], _ key: String) -> String { unescape(row[key] ?? "") }
        func integer(_ row: [String:String], _ key: String) throws -> JSON? {
            guard let raw = row[key], !raw.isEmpty else { return nil }
            guard let number = Int(raw), String(number) == raw, abs(Double(number)) <= 9_007_199_254_740_991 else { throw failure("The CSV’s \(key) must be a whole number.") }
            return .number(Double(number))
        }
        func structured(_ row: [String:String], _ key: String) throws -> JSON? {
            guard let raw = row[key], !raw.isEmpty else { return nil }
            guard let value = try? TaskfoldJSONDecoder().decode(JSON.self, from: Data(raw.utf8)) else { throw failure("The CSV’s \(key) is not a valid structured value.") }
            return value
        }
        let common = Set(metaKeys + ["entity"])
        guard columns.filter({ !common.contains($0) }).allSatisfy({ metadata[$0]?.isEmpty == true }) else { throw failure("The workflow metadata row contains unexpected task fields.") }
        let allowed: [String:Set<String>] = [
            "project": Set(["id", "parent_id", "title", "notes", "color", "order_index"]),
            "section": Set(["id", "project_id", "title", "order_index"]),
            "task": Set(["id", "parent_id", "project_id", "section_id", "title", "notes", "type", "priority", "estimate_minutes", "labels", "planned_offset", "deadline_offset", "repeat_start_offset", "repeat_end_offset", "due_time", "time_zone", "is_recurring", "recurrence_pattern"])
        ]
        var projects: [Record] = [], sections: [Record] = [], tasks: [String:Record] = [:], parents: [String:String] = [:], order: [String] = []
        for row in tables.dropFirst() {
            guard let entity = row["entity"], ["project", "section", "task"].contains(entity), !text(row,"id").isEmpty else { throw failure("The CSV has an unsupported row or missing reference.") }
            guard columns.allSatisfy({ common.contains($0) || allowed[entity]!.contains($0) || row[$0]?.isEmpty == true }) else { throw failure("A CSV row contains fields that do not belong to its entity. Nothing has been discarded or imported.") }
            var item = Record(["id": .string(text(row,"id"))])
            item[entity == "task" ? "title" : "name"] = .string(text(row,"title"))
            if entity != "section" { item["description"] = .string(text(row,"notes")) }
            for key in ["project_id", "section_id", "color"] where row[key]?.isEmpty == false { item[key] = .string(text(row,key)) }
            if let number = try integer(row,"order_index") { item["order_index"] = number }
            if entity == "project" { if !text(row,"parent_id").isEmpty { item["parent_id"] = .string(text(row,"parent_id")) }; projects.append(item) }
            else if entity == "section" { sections.append(item) }
            else {
                guard tasks[item.id] == nil, ["task", "heading"].contains(row["type"] ?? ""), row["type"] != "heading" || metadata["document_version"] == "2" else { throw failure("The CSV has a duplicate task or unsupported task type.") }
                if metadata["document_version"] == "2" { item["is_heading"] = .bool(row["type"] == "heading") }
                for key in ["priority", "planned_offset", "deadline_offset", "repeat_start_offset", "repeat_end_offset"] { if let number = try integer(row,key) { item[key] = number } }
                if let number = try integer(row,"estimate_minutes") { item["duration_minutes"] = number }
                for key in ["due_time", "time_zone"] where row[key]?.isEmpty == false { item[key] = .string(text(row,key)) }
                item["labels"] = try structured(row,"labels") ?? .array([])
                if let value = try structured(row,"recurrence_pattern") { item["recurrence_pattern"] = value }
                if row["is_recurring"]?.isEmpty == false {
                    guard ["true", "false"].contains(row["is_recurring"] ?? "") else { throw failure("The CSV’s repeat setting must be true or false.") }
                    item["is_recurring"] = .bool(row["is_recurring"] == "true")
                }
                tasks[item.id] = item; parents[item.id] = text(row,"parent_id"); order.append(item.id)
            }
        }
        var children: [String:[String]] = [:], roots: [String] = []
        for id in order {
            if let parent = parents[id], !parent.isEmpty { guard tasks[parent] != nil else { throw failure("A CSV subtask refers to a missing parent.") }; children[parent,default:[]].append(id) }
            else { roots.append(id) }
        }
        var seen = Set<String>()
        func build(_ id: String, depth: Int) throws -> JSON {
            guard depth <= 10, seen.insert(id).inserted, var row = tasks[id] else { throw failure("The CSV task hierarchy is cyclic or too deep.") }
            row["subtasks"] = .array(try (children[id] ?? []).map { try build($0, depth: depth + 1) }); return .object(row.fields)
        }
        let nested = try roots.map { try build($0, depth: 0) }
        guard seen.count == tasks.count else { throw failure("The CSV contains a disconnected task cycle.") }
        var document: [String:JSON] = ["version": .number(metadata["document_version"] == "2" ? 2 : 1), "kind": .string(kind.rawValue), "projects": .array(projects.map { .object($0.fields) }), "sections": .array(sections.map { .object($0.fields) }), "tasks": .array(nested)]
        if metadata["document_version"] == "2" { document["capabilities"] = .array([.string("task_headings")]) }
        return try WorkflowTemplateFile(name: text(metadata,"name"), document: .object(document))
    }
}

extension WorkflowTemplateFile {
    func encodedCSV() throws -> Data { try WorkflowTemplateCSV.encode(self) }
}


/// An explicitly mapped source CSV becomes a reusable project definition, never live tasks.
struct WorkflowCSVSource: Identifiable, Sendable {
    let id = UUID()
    let headers: [String]
    let records: [[String]]
    let taskRowLabelsColumn: Int?
    init(data: Data) throws {
        let rows = try WorkflowTemplateCSV.rows(data, maximumColumns: 64)
        guard let header = rows.first, !header.isEmpty else { throw AppFailure(message: "Choose a CSV with column names on its first row.") }
        let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard names.allSatisfy({ !$0.isEmpty && $0.count <= 160 }), Set(names).count == names.count else {
            throw AppFailure(message: "Give every CSV column a unique, nonempty name of up to 160 characters.")
        }
        // Versioned Taskfold files retain their strict schema; mapping cannot bypass it.
        guard !names.starts(with: ["format", "document_version"]) else {
            throw AppFailure(message: "Use Import template for versioned Taskfold files. Column mapping is for other CSV workflows.")
        }
        let content = rows.dropFirst().filter { !$0.allSatisfy(\.isEmpty) }
        guard !content.isEmpty, content.count <= 5000, content.allSatisfy({ $0.count == header.count }) else {
            throw AppFailure(message: "Review 1–5,000 task rows with the same number of columns as the header. No rows have been imported.")
        }
        if names.contains(TaskRowCSVFormat.columns[0]) {
            guard names == TaskRowCSVFormat.columns, content.allSatisfy({ $0[0] == TaskRowCSVFormat.marker }) else {
                throw AppFailure(message: "This task-row CSV needs its complete supported header and format marker. Nothing has been imported.")
            }
            headers = names; records = content.map { $0.map(WorkflowTemplateCSV.unescape) }
            taskRowLabelsColumn = TaskRowCSVFormat.columns.firstIndex(of: "Labels")
        } else { headers = names; records = content; taskRowLabelsColumn = nil }
    }
    func ignoredColumns(_ mapping: WorkflowCSVMapping) -> [String] {
        headers.indices.filter { !mapping.columns.values.contains($0) }.map { headers[$0] }
    }
    func template(name: String, mapping: WorkflowCSVMapping, anchor: Date, headings: Bool, calendar: Calendar = .current) throws -> WorkflowTemplateFile {
        let chosen = Array(mapping.columns.values)
        guard mapping.columns[.title] != nil, chosen.allSatisfy(headers.indices.contains), Set(chosen).count == chosen.count,
              mapping.columns[.parent] == nil || mapping.columns[.identifier] != nil else {
            throw AppFailure(message: "Choose a distinct column for each mapped field. Parent reference also needs a row reference column.")
        }
        let taskType = mapping.taskValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let headingType = mapping.headingValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if mapping.columns[.type] != nil {
            guard !taskType.isEmpty, !headingType.isEmpty, taskType != headingType, taskType.count <= 160, headingType.count <= 160 else {
                throw AppFailure(message: "Use different nonempty values for Task and Heading, up to 160 characters each.")
            }
        }
        var gregorian = Calendar(identifier: .gregorian); gregorian.timeZone = calendar.timeZone
        let referenceDay = gregorian.startOfDay(for: anchor)
        var tasks: [String: Record] = [:], parents: [String: String] = [:], order: [String] = [], hasHeadings = false
        func value(_ row: [String], _ field: WorkflowCSVMapping.Field) -> String { mapping.columns[field].map { row[$0] } ?? "" }
        func trimmed(_ row: [String], _ field: WorkflowCSVMapping.Field) -> String { value(row, field).trimmingCharacters(in: .whitespacesAndNewlines) }
        for (index, row) in records.enumerated() {
            func fail(_ message: String) -> AppFailure { AppFailure(message: "CSV row \(index + 2): " + message) }
            let title = value(row, .title)
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw fail("give this task a title.") }
            let key = mapping.columns[.identifier] == nil ? "row-\(index)" : trimmed(row, .identifier)
            guard !key.isEmpty, tasks[key] == nil else { throw fail("row references must be nonempty and unique.") }
            var task = Record(["id": .string("csv-task-\(index + 1)"), "title": .string(title), "description": .string(value(row, .notes)), "project_id": .string("csv-project"), "labels": .array([]), "subtasks": .array([])])
            if mapping.columns[.type] != nil {
                let type = trimmed(row, .type)
                guard type.isEmpty || type == taskType || type == headingType else { throw fail("the type must match your Task or Heading value; blank means Task.") }
                if type == headingType {
                    guard headings else { throw fail("this app version cannot create heading templates. Keep this CSV for a supported version.") }
                    task["is_heading"] = .bool(true); hasHeadings = true
                }
            }
            for (field, target, bounds) in [(WorkflowCSVMapping.Field.priority, "priority", 1...4), (.estimate, "duration_minutes", 1...10080)] {
                let text = trimmed(row, field)
                if !text.isEmpty {
                    guard text.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(text), bounds.contains(number) else { throw fail("\(field.title) must be a whole number from \(bounds.lowerBound) to \(bounds.upperBound).") }
                    task[target] = .number(Double(number))
                }
            }
            for (field, target) in [(WorkflowCSVMapping.Field.plannedDate, "planned_offset"), (.deadlineDate, "deadline_offset")] {
                let text = trimmed(row, field)
                if !text.isEmpty {
                    guard text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                          let day = Dates.parse(text, calendar: gregorian), TaskPlanner.dayKey(day, calendar: gregorian) == text,
                          let offset = gregorian.dateComponents([.day], from: referenceDay, to: day).day, abs(offset) <= 365000 else {
                        throw fail("\(field.title) needs a valid YYYY-MM-DD date within 1,000 years of the reference date.")
                    }
                    task[target] = .number(Double(offset))
                }
            }
            for (field, target) in [(WorkflowCSVMapping.Field.dueTime, "due_time"), (.timeZone, "time_zone")] {
                let text = trimmed(row, field); if !text.isEmpty { task[target] = .string(text) }
            }
            guard (task.string("due_time").isEmpty && task.string("time_zone").isEmpty) || task.fields["planned_offset"] != nil else {
                throw fail("a time or time zone also needs a planned date so it can be retained in each run.")
            }
            var labels: [JSON] = [], seen = Set<String>()
            let labelParts: [String], canonicalLabels = taskRowLabelsColumn.map { mapping.columns[.labels] == $0 } ?? false
            if canonicalLabels {
                guard let parsed = try? TaskfoldJSONDecoder().decode([String].self, from: Data(value(row, .labels).utf8)) else { throw fail("the Taskfold labels cell is not a supported list of names.") }
                labelParts = parsed
            } else { labelParts = value(row, .labels).split(separator: ";").map(String.init) }
            for part in labelParts {
                let label = canonicalLabels ? part : part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard label.count <= 160 else { throw fail("use label names up to 160 characters.") }
                if !label.isEmpty, seen.insert(label).inserted { labels.append(.object(["name": .string(label), "color": .string("#e31e4b")])) }
            }
            guard labels.count <= 100 else { throw fail("use at most 100 labels per task.") }
            task["labels"] = .array(labels)
            tasks[key] = task; parents[key] = trimmed(row, .parent); order.append(key)
        }
        var children: [String: [String]] = [:], roots: [String] = []
        for key in order {
            let parent = parents[key] ?? ""
            if parent.isEmpty { roots.append(key) }
            else {
                guard tasks[parent] != nil else { throw AppFailure(message: "A CSV parent reference does not match any row. Nothing has been imported.") }
                children[parent, default: []].append(key)
            }
        }
        var visited = Set<String>()
        func build(_ key: String, depth: Int) throws -> JSON {
            guard depth <= 10, visited.insert(key).inserted, var task = tasks[key] else { throw AppFailure(message: "The CSV hierarchy contains a cycle or is deeper than 10 levels.") }
            task["subtasks"] = .array(try (children[key] ?? []).map { try build($0, depth: depth + 1) })
            return .object(task.fields)
        }
        let nested = try roots.map { try build($0, depth: 0) }
        guard visited.count == tasks.count else { throw AppFailure(message: "The CSV hierarchy contains a disconnected cycle. Nothing has been imported.") }
        var document: [String: JSON] = ["version": .number(hasHeadings ? 2 : 1), "kind": .string("project"), "projects": .array([.object(["id": .string("csv-project"), "name": .string(name)])]), "sections": .array([]), "tasks": .array(nested)]
        if hasHeadings { document["capabilities"] = .array([.string("task_headings")]) }
        return try WorkflowTemplateFile(name: name, document: .object(document))
    }
}

struct WorkflowCSVMapping: Sendable, Equatable {
    enum Field: String, CaseIterable, Identifiable, Sendable {
        case title, notes, identifier, parent, type, priority, estimate, labels, plannedDate, deadlineDate, dueTime, timeZone
        var id: String { rawValue }
        var title: String {
            switch self {
            case .title: "Task title"
            case .notes: "Notes"
            case .identifier: "Row reference"
            case .parent: "Parent reference"
            case .type: "Task or heading"
            case .priority: "Priority (1–4)"
            case .estimate: "Estimate in minutes"
            case .labels: "Labels"
            case .plannedDate: "Planned date (YYYY-MM-DD)"
            case .deadlineDate: "Deadline (YYYY-MM-DD)"
            case .dueTime: "Time (HH:mm)"
            case .timeZone: "Time zone name"
            }
        }
    }
    var columns: [Field: Int] = [:]
    var taskValue = "task", headingValue = "heading"
}


/// Reversible spreadsheet-safe text transport; not a task restore or completion-history format.
enum TaskRowCSVFormat {
    static let marker = "taskfold-task-rows-v1"
    static let columns = ["Taskfold format", "Row reference", "Parent reference", "Group", "Parent path", "Type", "Title", "Notes", "Completed", "Project", "Priority", "Planned date", "Time", "Time zone", "Scheduled instant", "Deadline", "Estimate minutes", "Labels", "Assigned to"]
}


/// A one-use append plan for wholly fresh personal workflow identities. Keeping
/// the working snapshot local avoids a linear lookup and array copy per insert.
/// Collisions, retries and mixed commands keep the ordinary projection path.
struct FreshWorkflowCreation: Sendable {
    private let run: UUID
    private let account: String
    private var remaining: Set<String>
    init?(_ changes: [Mutation], snapshot: Snapshot, account: String) {
        guard let run = WorkflowUndo.creationRun(changes), !account.isEmpty else { return nil }
        // Only destination tables can collide with this run. Activity, comments,
        // private recovery and future tables may be large but cannot contribute
        // an identity to an insertion into another table.
        let destinations = Set(changes.map(\.table))
        let existing = Dictionary(uniqueKeysWithValues: destinations.map { table in
            (table, Set((snapshot.tables[table] ?? []).map(\.id)))
        })
        var keys = Set<String>(), taskNamespaces = Set<String>()
        for change in changes {
            // Local assignment history uses case-folded root identities. Aliases
            // must keep sequential invalidate/record ordering on the ordinary path.
            if change.table == "tasks", !taskNamespaces.insert(change.recordID.lowercased()).inserted { return nil }
            guard change.fields["id"]?.text == change.recordID, !change.recordID.isEmpty,
                  change.fields["user_id"]?.text == account,
                  !(existing[change.table] ?? []).contains(change.recordID),
                  keys.insert(change.table + ":" + change.recordID).inserted else { return nil }
        }
        self.run = run; self.account = account; remaining = keys
    }
    mutating func append(_ change: Mutation, to snapshot: inout Snapshot) -> Record? {
        guard WorkflowUndo.creationRun([change]) == run, change.fields["id"]?.text == change.recordID,
              change.fields["user_id"]?.text == account,
              TaskGeneration.permitsLocalAction(change, existing: nil), TaskKind.permits(change, existing: nil),
              remaining.remove(change.table + ":" + change.recordID) != nil else { return nil }
        var fields = change.fields
        if change.table == "tasks" { fields["completion_version"] = .number(0) }
        let row = Record(fields)
        snapshot.tables[change.table, default: []].append(row)
        if change.table == "tasks" { TaskAssignmentProvenance.invalidate(before: nil, after: row, snapshot: &snapshot) }
        return row
    }
}

/// Cached compatibility metadata, never task authority. Every send refreshes
/// support and the service independently checks live session/access and rows.
struct WorkflowUndoService: Equatable, Sendable, Codable {
    let raw: [String: JSON]
    let account: String
    let origin: String
    var supported: Bool { raw["undo_protocol"] == .number(1) }
    var bulk: Bool { raw["bulk_protocol"] == .number(1) }
    var capture: Bool { raw["capture_protocol"] == .number(1) }
    init(_ raw: [String: JSON], account: String, origin: String) throws {
        guard TeamProjectValue.id(account), raw["protocol"] == .number(1), raw["account"] == .string(account),
              [JSON.number(0), JSON.number(1)].contains(raw["undo_protocol"] ?? .null),
              [JSON.number(0), JSON.number(1)].contains(raw["bulk_protocol"] ?? .null),
              raw["undo_protocol"] == .number(1) || raw["bulk_protocol"] == .number(0),
              [JSON.number(0), JSON.number(1)].contains(raw["capture_protocol"] ?? .number(0)),
              raw["capture_protocol"] != .number(1) || raw["undo_protocol"] == .number(1),
              let url = URL(string: origin), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", !origin.hasSuffix("/") else { throw TeamProjectValue.invalid }
        self.raw = raw; self.account = account; self.origin = origin
    }
    func belongs(account: String, origin: String) -> Bool { self.account == account && self.origin == origin }
    private enum CodingKeys: String, CodingKey { case raw, origin }
    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try value.decode([String: JSON].self, forKey: .raw)
        try self.init(raw, account: raw["account"]?.text ?? "", origin: value.decode(String.self, forKey: .origin))
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(raw, forKey: .raw); try value.encode(origin, forKey: .origin)
    }
}
struct WorkflowUndoServiceUnavailable: Error {}

@MainActor extension Backend {
    func workflowUndoService(account: String) async throws -> WorkflowUndoService? {
        guard session?.user.id == account else { throw CancellationError() }
        let origin = try accountRemovalOrigin
        let data: Data
        do { data = try await request("/rest/v1/rpc/taskfold_workflow_undo_capabilities", method: "POST", body: [:], expectedAccount: account) }
        catch is WorkflowUndoServiceUnavailable { return nil }
        guard data.count <= 16384 else { throw TeamProjectValue.invalid }
        return try WorkflowUndoService(TaskfoldJSONDecoder().decode([String: JSON].self, from: data), account: account, origin: origin)
    }
}

/// One durable, atomic Undo for the fresh personal records of a workflow run.
/// The server checks the complete set before deleting any of it.
enum WorkflowUndo {
    /// Redo commits without adding a new UI history entry, but fresh records
    /// still require a retained inverse, including capture's existing order edits.
    static func requiresCreationHistory(_ changes: [Mutation]) -> Bool {
        guard let run = changes.first?.workflowRun else { return false }
        var inserts = false
        for change in changes {
            guard change.workflowRun == run else { return false }
            if change.method == "POST" { inserts = true }
            else if change.table != "view_orders" || change.method != "PATCH" { return false }
        }
        return inserts
    }
    /// Preserve the Store's refusal of a new workflow without retained Undo.
    static func missingCreationHistory(_ changes: [Mutation], snapshot: @autoclosure () -> Snapshot, undo: [Mutation]?) -> Bool {
        guard undo?.isEmpty != false, requiresCreationHistory(changes) else { return false }
        let tables = snapshot().tables
        var existing: [String: Set<String>] = [:]
        for change in changes where change.method == "POST" {
            if existing[change.table] == nil {
                existing[change.table] = Set((tables[change.table] ?? []).map(\.id))
            }
            if existing[change.table]?.contains(change.recordID) != true { return true }
        }
        return false
    }

    static let table = "_private_workflow_undo"
    static let captureTable = "_private_capture_undo"
    /// Only ordinary insert-only personal workflow runs can defer presentation.
    /// Validation and sequential snapshot mutation still happen for every row.
    static func creationRun(_ changes: [Mutation]) -> UUID? {
        guard let run = changes.first?.workflowRun, !changes.isEmpty,
              changes.allSatisfy({ $0.workflowRun == run && $0.method == "POST" && $0.insertOnly == true &&
                  ["projects", "sections", "labels", "tasks", "view_orders"].contains($0.table) &&
                  $0.teamTaskScope == nil && $0.teamTaskBatch == nil && $0.teamCompletion == nil && $0.organizationOrder == nil }) else { return nil }
        return run
    }

    static let unavailable = "Refresh this workspace after its service is updated to safely undo workflows. Your work is unchanged."
    static func available(boundary: TeamWorkspaceBoundary?, account: String, origin: String?, service: WorkflowUndoService? = nil) -> Bool {
        if let service { return origin.map { service.belongs(account: account, origin: $0) && service.supported } ?? false }
        guard let boundary, let origin, boundary.belongs(account: account, origin: origin) else { return false }
        return boundary.raw["personal_workflow_undo_protocol"] == .number(1)
    }
    static func canSend(_ change: Mutation, boundary: TeamWorkspaceBoundary?, service: WorkflowUndoService? = nil, origin: String? = nil) -> Bool {
        guard matches(change) else { return true }
        if let service {
            guard let account = change.fields["user_id"]?.text, let origin, service.belongs(account: account, origin: origin), service.supported else { return false }
            guard change.table != captureTable || service.capture else { return false }
            return (change.fields["items"]?.list.count ?? 0) <= 12000 || service.bulk
        }
        guard change.table != captureTable, boundary?.raw["personal_workflow_undo_protocol"] == .number(1) else { return false }
        return (change.fields["items"]?.list.count ?? 0) <= 12000 || boundary?.raw["personal_workflow_undo_bulk_protocol"] == .number(1)
    }
    static let maximumResponseBytes = 32_000_000
    static let maximumBytes = 16_800_000
    static let tooLarge = "This workflow is too large to create in one step. Your template is kept and no work was created."
    static let message = "This workflow changed after it was created. Undo was cancelled and your current work was kept."
    static func matches(_ change: Mutation) -> Bool { [table, captureTable].contains(change.table) || ["WORKFLOW_UNDO", "CAPTURE_UNDO"].contains(change.method) }
    static func items(_ change: Mutation) -> [Mutation]? {
        let capture = change.table == captureTable && change.method == "CAPTURE_UNDO"
        guard (capture || (change.table == table && change.method == "WORKFLOW_UNDO" && change.fields["order_restores"] == nil)), let run = change.workflowRun,
              change.recordID == run.uuidString.lowercased(), case .array(let rows) = change.fields["items"],
              !rows.isEmpty, let owner = change.fields["user_id"]?.text, !owner.isEmpty else { return nil }
        var seen = Set<String>(), result: [Mutation] = []
        for value in rows {
            let raw = value.object, name = raw["table"]?.text ?? "", id = raw["id"]?.text ?? ""
            guard ["projects", "sections", "labels", "tasks", "view_orders"].contains(name), !id.isEmpty,
                  case .object(let base) = raw["base"], base["id"]?.text == id, base["user_id"]?.text == owner,
                  seen.insert(name + ":" + id).inserted else { return nil }
            result.append(Mutation(table: name, recordID: id, method: "DELETE", fields: [:], baseline: base, workflowRun: run))
        }
        if capture {
            guard case .array(let orders) = change.fields["order_restores"], !orders.isEmpty else { return nil }
            let tasks = Set(result.filter { $0.table == "tasks" }.map(\.recordID))
            for value in orders {
                let raw = value.object, id = raw["id"]?.text ?? ""
                guard id == "scope:inbox" || id.hasPrefix("group:"),
                      case .object(let after) = raw["base"], case .object(let before) = raw["restore"],
                      Set(after.keys) == ["id", "user_id", "ids"], Set(before.keys) == Set(after.keys),
                      after["id"] == .string(id), before["id"] == .string(id),
                      after["user_id"] == .string(owner), before["user_id"] == .string(owner),
                      case .array(let afterIDs) = after["ids"], case .array(let beforeIDs) = before["ids"],
                      afterIDs.allSatisfy({ if case .string = $0 { return true }; return false }),
                      beforeIDs == afterIDs.filter({ !tasks.contains($0.text) }), beforeIDs != afterIDs,
                      seen.insert("view_orders:" + id).inserted else { return nil }
                result.append(Mutation(table: "view_orders", recordID: id, method: "PATCH", fields: before, baseline: after, workflowRun: run))
            }
        }
        return result
    }
    /// PostgreSQL jsonb::text adds a space after structural separators and
    /// expands exponent notation. Count that representation before admitting a
    /// durable command, without changing whitespace inside authored strings.
    static func bodyBytes(_ change: Mutation) -> Int? {
        var counter = BodySizeCounter()
        // Keep the original encoder path for unusual depth or values the direct
        // counter cannot certify. This is an optimization, not a new quota.
        return counter.bytes(.object(change.fields)) ?? encodedBodyBytes(change)
    }
    private struct BodySizeCounter {
        private let numbersEncoder = TaskfoldJSONEncoder()
        private var numbers: [UInt64: Int] = [:]
        mutating func bytes(_ value: JSON, depth: Int = 0) -> Int? {
            guard depth < 128 else { return nil }
            switch value {
            case .preserved: return nil
            case .null: return 4
            case .bool(let value): return value ? 4 : 5
            case .string(let value): return stringBytes(value)
            case .number(let value):
                if let size = numbers[value.bitPattern] { return size }
                // Let Foundation choose the same shortest spelling as the old
                // full encoder. Cache only within this one count, by raw bits.
                guard let data = try? numbersEncoder.encode(value) else { return nil }
                let text = String(decoding: data, as: UTF8.self)
                let size: Int
                if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }), let exponent = Int(text[text.index(after: e)...]) {
                    let mantissa = String(text[..<e]), sign = mantissa.hasPrefix("-") ? 1 : 0
                    let unsigned = sign == 1 ? String(mantissa.dropFirst()) : mantissa
                    let parts = unsigned.split(separator: ".", omittingEmptySubsequences: false)
                    let digits = parts.reduce(0) { $0 + $1.utf8.count }, addition = parts[0].utf8.count.addingReportingOverflow(exponent)
                    guard !addition.overflow, abs(Double(addition.partialValue)) < Double(Int.max/2) else { return nil }; let position = addition.partialValue
                    size = sign + (position >= digits ? position : position > 0 ? digits + 1 : 2 - position + digits)
                } else if text.contains(where: { $0 == "e" || $0 == "E" }) { return nil
                } else if text.hasPrefix("-"), text.dropFirst().allSatisfy({ $0 == "0" || $0 == "." }) {
                    size = text.utf8.count - 1
                } else { size = text.utf8.count }
                numbers[value.bitPattern] = size
                return size
            case .array(let values):
                var size = 2 + max(0, values.count - 1) * 2
                for value in values {
                    guard let count = bytes(value, depth: depth + 1) else { return nil }
                    size += count
                }
                return size
            case .object(let values):
                var size = 2 + max(0, values.count - 1) * 2
                for (key, value) in values {
                    guard let count = bytes(value, depth: depth + 1) else { return nil }
                    size += stringBytes(key) + 2 + count
                }
                return size
            }
        }
        private func stringBytes(_ value: String) -> Int {
            var size = 2
            for byte in value.utf8 {
                switch byte {
                case 8, 9, 10, 12, 13, 34, 92: size += 2
                case 0...31: size += 6
                default: size += 1
                }
            }
            return size
        }
    }
    static func encodedBodyBytes(_ change: Mutation) -> Int? {
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(JSON.object(change.fields)) else { return nil }
        let bytes = Array(data)
        var size = bytes.count, index = 0, quoted = false, escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 44 || byte == 58 { size += 1 }
            else if byte == 45 || (48...57).contains(byte) {
                let start = index
                while index < bytes.count && (bytes[index] == 45 || bytes[index] == 43 || bytes[index] == 46 || bytes[index] == 69 || bytes[index] == 101 || (48...57).contains(bytes[index])) { index += 1 }
                let text = String(decoding: bytes[start..<index], as: UTF8.self)
                if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }), let exponent = Int(text[text.index(after: e)...]) {
                    let mantissa = String(text[..<e]), sign = mantissa.hasPrefix("-") ? 1 : 0
                    let unsigned = sign == 1 ? String(mantissa.dropFirst()) : mantissa
                    let parts = unsigned.split(separator: ".", omittingEmptySubsequences: false)
                    let digits = parts.reduce(0) { $0 + $1.utf8.count }, addition = parts[0].utf8.count.addingReportingOverflow(exponent)
                    guard !addition.overflow, abs(Double(addition.partialValue)) < Double(Int.max/2) else { return nil }; let position = addition.partialValue
                    let expanded = sign + (position >= digits ? position : position > 0 ? digits + 1 : 2 - position + digits)
                    let next = size.addingReportingOverflow(expanded - text.utf8.count); guard !next.overflow else { return nil }; size = next.partialValue
                } else if text.contains(where: { $0 == "e" || $0 == "E" }) { return nil
                } else if text.hasPrefix("-"), text.dropFirst().allSatisfy({ $0 == "0" || $0 == "." }) {
                    size -= 1 // jsonb normalizes a negative zero's sign.
                }
                continue
            }
            index += 1
        }
        return size
    }
    static func fitsBody(_ change: Mutation) -> Bool { bodyBytes(change).map { $0 <= maximumBytes } ?? false }
    static func deleting(_ changes: [Mutation], snapshot: Snapshot) -> Mutation? {
        guard let run = changes.first?.workflowRun, !changes.isEmpty,
              changes.allSatisfy({ $0.workflowRun == run && ($0.method == "POST" && $0.insertOnly == true || $0.table == "view_orders" && $0.method == "PATCH") && $0.teamTaskScope == nil && $0.teamTaskBatch == nil && $0.teamCompletion == nil }),
              let owner = changes.first?.fields["user_id"]?.text else { return nil }
        let existing = snapshot.tables.mapValues { Dictionary($0.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
        let created = changes.filter { $0.method == "POST" && existing[$0.table]?[$0.recordID] == nil }
        guard !created.isEmpty else { return nil }
        var orders: [JSON] = []
        for change in changes where change.method == "PATCH" {
            guard let before = existing["view_orders"]?[change.recordID], before.string("user_id") == owner else { return nil }
            let old = Dictionary(uniqueKeysWithValues: ["id", "user_id", "ids"].map { ($0, before[$0]) })
            orders.append(.object(["id": .string(change.recordID), "base": .object(change.fields), "restore": .object(old)]))
        }
        var fields: [String: JSON] = ["user_id": .string(owner), "items": .array(created.reversed().map { .object(["table": .string($0.table), "id": .string($0.recordID), "base": .object($0.fields)]) })]
        if !orders.isEmpty { fields["order_restores"] = .array(orders) }
        let command = Mutation(table: orders.isEmpty ? table : captureTable, recordID: run.uuidString.lowercased(), method: orders.isEmpty ? "WORKFLOW_UNDO" : "CAPTURE_UNDO", fields: fields, workflowRun: run)
        return items(command) != nil && fitsBody(command) ? command : nil
    }
    static func restoring(_ change: Mutation) -> [Mutation]? {
        items(change)?.reversed().map { item in
            Mutation(table: item.table, recordID: item.recordID, method: item.method == "PATCH" ? "PATCH" : "POST", fields: item.baseline!, baseline: item.method == "PATCH" ? item.fields : nil, insertOnly: item.method == "PATCH" ? nil : true, workflowRun: item.workflowRun)
        }
    }
    /// PostgREST spells UTC as +00:00 and time values with seconds. Compare
    /// those equivalent spellings exactly, including all six SQL fractional digits.
    /// Every other value remains an exact comparison; the service rechecks typed rows.
    private static func sameField(_ key: String, _ lhs: JSON, _ rhs: JSON) -> Bool {
        if lhs == rhs { return true }
        guard case .string(let a) = lhs, case .string(let b) = rhs else { return false }
        func fraction(_ text: String) -> String? {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            let value = parts.count == 2 ? String(parts[1]) : ""
            guard value.count <= 6, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return String(parts[0]) + "." + value + String(repeating: "0", count: 6 - value.count)
        }
        func utc(_ text: String) -> String? {
            let body: String
            if text.hasSuffix("Z") { body = String(text.dropLast()) }
            else if text.hasSuffix("+00:00") { body = String(text.dropLast(6)) }
            else { return nil }
            let bytes = Array(body.utf8), separators: [Int: UInt8] = [4: 45, 7: 45, 10: 84, 13: 58, 16: 58]
            guard bytes.count >= 19, bytes.count == 19 || bytes[19] == 46,
                  (0..<19).allSatisfy({ index in separators[index].map { bytes[index] == $0 } ?? (48...57).contains(bytes[index]) }) else { return nil }
            return fraction(body)
        }
        if ["created_at", "updated_at", "scheduled_at", "completed_at"].contains(key) {
            guard let value = utc(a) else { return false }; return value == utc(b)
        }
        if key == "due_time" {
            func clock(_ value: String) -> String? {
                let parts = value.split(separator: ":", omittingEmptySubsequences: false)
                guard (2...3).contains(parts.count), parts[0].count == 2, parts[1].count == 2,
                      let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
                let seconds = parts.count == 3 ? String(parts[2]) : "00"
                guard let part = seconds.split(separator: ".").first, let whole = Int(part), (0...59).contains(whole),
                      let result = fraction(seconds) else { return nil }
                return String(parts[0]) + ":" + String(parts[1]) + ":" + result
            }
            guard let value = clock(a) else { return false }; return value == clock(b)
        }
        return false
    }
    static func validate(_ change: Mutation, snapshot: Snapshot, account: String) throws {
        guard let items = items(change), fitsBody(change), change.fields["user_id"]?.text == account else { throw AppFailure(message: "Reopen this workflow's current Undo action.") }
        let ids = Dictionary(grouping: items, by: \.table).mapValues { Set($0.map(\.recordID)) }
        func external(_ table: String, _ row: Record) -> Bool { !(ids[table] ?? []).contains(row.id) }
        let currentRows = snapshot.tables.mapValues { Dictionary($0.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
        for item in items {
            if let current = currentRows[item.table]?[item.recordID],
               !item.baseline!.allSatisfy({ sameField($0.key, current[$0.key], $0.value) }) { throw AppFailure(message: message) }
        }
        for row in snapshot.tables["projects"] ?? [] where external("projects", row) && (ids["projects"] ?? []).contains(row.string("parent_id")) { throw AppFailure(message: message) }
        for row in snapshot.tables["sections"] ?? [] where external("sections", row) && (ids["projects"] ?? []).contains(row.string("project_id")) { throw AppFailure(message: message) }
        func usesLabel(_ row: Record) -> Bool {
            !Set(row["labels"].list.map(\.text)).isDisjoint(with: ids["labels"] ?? []) || row["subtasks"].list.contains { usesLabel(Record($0.object)) }
        }
        for row in snapshot.tables["tasks"] ?? [] where external("tasks", row) {
            if (ids["projects"] ?? []).contains(row.string("project_id")) || (ids["sections"] ?? []).contains(row.string("section_id")) || usesLabel(row) { throw AppFailure(message: message) }
        }
    }
    static func apply(_ change: Mutation, snapshot: inout Snapshot) {
        guard let items = items(change) else { return }
        let grouped = Dictionary(grouping: items, by: \.table).mapValues { Dictionary($0.map { ($0.recordID, $0) }, uniquingKeysWith: { first, _ in first }) }
        for (table, changes) in grouped {
            for item in changes.values where item.method == "PATCH" { snapshot.apply(item) }
            snapshot.tables[table] = (snapshot.tables[table] ?? []).filter { row in
                guard let item = changes[row.id], item.method == "DELETE" else { return true }
                return !TaskGeneration.permitsLocalAction(item, existing: row) || !TaskKind.permits(item, existing: row)
            }
        }
    }
    static func reply(_ saved: Record?, change: Mutation) -> (applied: Bool, rows: [Mutation])? {
        guard let items = items(change), let saved, saved.id == change.id.uuidString.lowercased(),
              case .bool(let applied) = saved["applied"], case .array(let values) = saved["rows"] else { return nil }
        let expected = Set(items.map { $0.table + ":" + $0.recordID })
        var seen = Set<String>(), rows: [Mutation] = []
        for value in values {
            let raw = value.object, table = raw["table"]?.text ?? "", row = Record(raw["row"]?.object ?? [:])
            guard expected.contains(table + ":" + row.id),
                  row.string("user_id") == change.fields["user_id"]?.text, seen.insert(table + ":" + row.id).inserted else { return nil }
            rows.append(Mutation(table: table, recordID: row.id, method: "POST", fields: row.fields))
        }
        guard !applied || rows.isEmpty else { return nil }
        return (applied, rows)
    }
    static func acknowledge(_ saved: Record?, change: Mutation, snapshot: inout Snapshot) -> Bool {
        guard let reply = reply(saved, change: change) else { return false }
        snapshot.pending.removeAll { $0.id == change.id }
        if !reply.applied {
            // Reconcile every affected identity, including an order removed on another device.
            // Missing/inaccessible rows must not leave an optimistic order behind.
            for (table, items) in Dictionary(grouping: items(change) ?? [], by: \.table) {
                let ids = Set(items.map(\.recordID))
                snapshot.tables[table] = (snapshot.tables[table] ?? []).filter { !ids.contains($0.id) }
            }
            for (table, rows) in Dictionary(grouping: reply.rows, by: \.table) {
                let ids = Set(rows.map(\.recordID))
                snapshot.tables[table] = (snapshot.tables[table] ?? []).filter { !ids.contains($0.id) } + rows.map { Record($0.fields) }
            }
            for queued in snapshot.pending { snapshot.apply(queued) }
        }
        return true
    }
}

/// Display-only, bounded to one library presentation. This actor serializes
/// validation away from the main actor and never authorizes Use/Edit/Export.
actor WorkflowLibrarySummaryCache {
    private struct Context: Equatable { let workspace: WorkspaceBinding; let session: UUID }
    private struct Entry { let source: Record; let text: String }
    private let capacity: Int
    private var context: Context?
    private var entries: [String: Entry] = [:]
    private var recent: [String] = []
    private(set) var preparationCount = 0
    init(capacity: Int = 24) { self.capacity = max(1, min(capacity, 64)) }

    func summary(for request: WorkflowDefinitionRequest) throws -> String {
        try Task.checkCancellation()
        guard !request.workspace.account.isEmpty else { throw CancellationError() }
        let next = Context(workspace: request.workspace, session: request.session)
        if context != next { clear(); context = next }
        let id = request.source.id
        if let entry = entries[id], entry.source == request.source {
            touch(id); return entry.text
        }
        preparationCount += 1
        let text = try Self.describe(request.source["document"])
        try Task.checkCancellation()
        entries[id] = Entry(source: request.source, text: text); touch(id)
        while recent.count > capacity { entries.removeValue(forKey: recent.removeFirst()) }
        return text
    }
    func clear() { context = nil; entries = [:]; recent = [] }
    private func touch(_ id: String) { recent.removeAll { $0 == id }; recent.append(id) }
    static func describe(_ document: JSON) throws -> String {
        do {
            let definition = try WorkflowTemplate(document: document, checkCancellation: { try Task.checkCancellation() })
            if definition.requiresHeadingSupport { return TemplateEditing.summary(definition) }
            func label(_ n: Int, _ noun: String) -> String { "\(n) \(noun)" + (n == 1 ? "" : "s") }
            return [label(definition.projects.count, "project"), label(definition.sections.count, "section"), label(definition.tasks.count, "task")].joined(separator: " · ")
        } catch is CancellationError { throw CancellationError() }
        catch { return "Update Taskfold to use this template" }
    }
}

/// Bundled, account-free definitions. Opening one only previews a reusable copy;
/// the ordinary save and run flows retain workspace checks and fresh identities.
enum WorkflowStarter: String, CaseIterable, Identifiable, Sendable {
    case weeklyReset, projectKickoff, meetingFollowUp, tripPreparation
    var id: String { rawValue }
    var name: String {
        switch self {
        case .weeklyReset: return "Weekly reset"
        case .projectKickoff: return "Project kickoff"
        case .meetingFollowUp: return "Meeting follow-up"
        case .tripPreparation: return "Trip preparation"
        }
    }
    var summary: String {
        switch self {
        case .weeklyReset: return "Clear loose ends and choose what matters next."
        case .projectKickoff: return "Turn an idea into a clear first milestone."
        case .meetingFollowUp: return "Capture decisions and turn discussion into action."
        case .tripPreparation: return "Keep bookings, documents and departure details together."
        }
    }
    var symbol: String {
        switch self {
        case .weeklyReset: return "arrow.triangle.2.circlepath"
        case .projectKickoff: return "flag"
        case .meetingFollowUp: return "bubble.left.and.bubble.right"
        case .tripPreparation: return "suitcase"
        }
    }
    static func matching(_ query: String) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.filter { query.isEmpty || $0.name.localizedStandardContains(query) || $0.summary.localizedStandardContains(query) }
    }
    func file() throws -> WorkflowTemplateFile {
        typealias Step = (title: String, note: String, minutes: Int)
        let sections: [(name: String, steps: [Step])]
        switch self {
        case .weeklyReset:
            sections = [
                ("Clear the decks", [
                    ("Collect loose tasks", "Check your notes and messages. Capture anything that still needs action.", 10),
                    ("Review the Inbox", "Give each task a next step, a project or a deliberate decision to let it go.", 10),
                    ("Close last week", "Review unfinished work. Reschedule consciously and archive finished projects.", 10)]),
                ("Shape the week", [
                    ("Review the calendar", "Look for commitments, deadlines and time you need to protect.", 5),
                    ("Choose three outcomes", "Write down the few results that would make this a good week.", 10),
                    ("Plan the first next step", "Choose one concrete action for each outcome and give it a realistic place in your day.", 10)])]
        case .projectKickoff:
            sections = [
                ("Define the work", [
                    ("Write the outcome", "Describe what will be different when this project is finished.", 15),
                    ("Define done", "List the acceptance criteria and what is outside the scope.", 15),
                    ("Identify dependencies", "Note the people, decisions and materials needed before work can move forward.", 10)]),
                ("Make a start", [
                    ("Choose the first milestone", "Pick a small, useful result that can be reviewed early.", 15),
                    ("Break down the next actions", "Use specific actions with a clear result. Add owners or dates when ready.", 20),
                    ("Schedule a review", "Choose when to check progress and decide what comes next.", 5)])]
        case .meetingFollowUp:
            sections = [
                ("Capture", [
                    ("Summarize the decisions", "Record what was agreed and why. Link the relevant notes in this task.", 10),
                    ("List the open questions", "Separate unresolved questions from decisions already made.", 5)]),
                ("Follow through", [
                    ("Confirm the next actions", "Make each action concrete, then agree an owner and a realistic due date.", 10),
                    ("Share the follow-up", "Send the decisions, open questions and next actions to the relevant people.", 10),
                    ("Set a progress check", "Choose when to revisit outstanding actions and dependencies.", 5)])]
        case .tripPreparation:
            sections = [
                ("Before you go", [
                    ("Confirm the itinerary", "Check dates, bookings, arrival times and cancellation details.", 15),
                    ("Check travel documents", "Check the requirements for your destination and that your documents are valid.", 15),
                    ("Plan transport and arrival", "Keep transfer details and arrival instructions somewhere easy to find.", 10)]),
                ("Ready to leave", [
                    ("Make a packing checklist", "Include essentials, chargers and anything specific to the trip.", 15),
                    ("Save useful details offline", "Keep the information you need accessible without a connection.", 10),
                    ("Check departure essentials", "Review the itinerary, documents, keys and transport before leaving.", 5)])]
        }
        let project = "starter-project"
        var sectionRows: [JSON] = [], taskRows: [JSON] = []
        for (index, section) in sections.enumerated() {
            let sectionID = "starter-section-\(index)"
            sectionRows.append(.object(["id": .string(sectionID), "name": .string(section.name), "project_id": .string(project), "order_index": .number(Double(index))]))
            for (stepIndex, step) in section.steps.enumerated() {
                taskRows.append(.object(["id": .string("starter-task-\(index)-\(stepIndex)"), "title": .string(step.title), "description": .string(step.note),
                    "project_id": .string(project), "section_id": .string(sectionID), "priority": .number(4), "duration_minutes": .number(Double(step.minutes)), "labels": .array([]), "subtasks": .array([])]))
            }
        }
        return try WorkflowTemplateFile(name: name, document: .object(["version": .number(1), "kind": .string("project"),
            "projects": .array([.object(["id": .string(project), "name": .string(name), "description": .string(summary), "color": .string("#8b5cf6"), "order_index": .number(0)])]),
            "sections": .array(sectionRows), "tasks": .array(taskRows)]))
    }
}

/// A presentation-only index of already-readable sources. It is built on demand,
/// never from the library's body, and is not permission to capture a workflow.
struct WorkflowSourceCatalog: Sendable {
    struct Option: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let location: String
    }
    struct Page: Equatable, Sendable {
        let options: [Option]
        let total: Int
    }
    let kind: WorkflowTemplate.Kind
    let options: [Option]
    static let pageSize = 100

    private static func unique(_ rows: [Record], check: () throws -> Void) throws -> [String: Record] {
        var index: [String: Record] = [:], duplicates = Set<String>()
        for row in rows where !row.id.isEmpty {
            try check()
            if index.updateValue(row, forKey: row.id) != nil { duplicates.insert(row.id) }
        }
        for id in duplicates { index.removeValue(forKey: id) }
        return index
    }
    init(kind: WorkflowTemplate.Kind, projects: [Record], sections: [Record], tasks: [Record], checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
        self.kind = kind
        let projects = try Self.unique(projects, check: checkCancellation)
        let sections = try Self.unique(sections, check: checkCancellation).filter { projects[$0.value.string("project_id")] != nil }
        let archived = ProjectOrganization.archivedIDs(in: Array(projects.values))
        var paths: [String: String] = [:]
        for id in projects.keys {
            try checkCancellation()
            var cursor = id, names: [String] = [], seen = Set<String>()
            while let row = projects[cursor], seen.insert(cursor).inserted, names.count < ProjectOrganization.maximumDepth {
                try checkCancellation()
                names.append(row.name.isEmpty ? "Untitled project" : row.name)
                cursor = row.string("parent_id")
            }
            paths[id] = names.reversed().joined(separator: " › ")
        }
        func projectPath(_ id: String) -> String {
            let path = id.isEmpty ? "Inbox" : paths[id] ?? ""
            return archived.contains(id) ? "Archived · " + path : path
        }
        let rows: [String: Record]
        switch kind {
        case .project: rows = projects
        case .section: rows = sections
        case .task: rows = try Self.unique(tasks, check: checkCancellation).filter { $0.value.string("project_id").isEmpty || projects[$0.value.string("project_id")] != nil }
        }
        var options: [Option] = []
        for row in rows.values {
            try checkCancellation()
            let title = kind == .task ? row.title : row.name
            let location: String
            switch kind {
            case .project:
                let parent = paths[row.string("parent_id")] ?? "Top level"
                location = archived.contains(row.id) ? "Archived · " + parent : parent
            case .section: location = projectPath(row.string("project_id"))
            case .task:
                var path = projectPath(row.string("project_id"))
                if let section = sections[row.string("section_id")], section.string("project_id") == row.string("project_id") { path += " › " + section.name }
                location = path
            }
            options.append(Option(id: row.id, title: title.isEmpty ? "Untitled " + kind.rawValue : title, location: location))
        }
        self.options = try options.sorted {
            try checkCancellation()
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            let locationOrder = $0.location.localizedStandardCompare($1.location)
            return locationOrder == .orderedSame ? $0.id < $1.id : locationOrder == .orderedAscending
        }
        try checkCancellation()
    }
    static func load(kind: WorkflowTemplate.Kind, projects: [Record], sections: [Record], tasks: [Record]) async throws -> Self {
        let worker = Task.detached(priority: .userInitiated) { try Self(kind: kind, projects: projects, sections: sections, tasks: tasks) }
        return try await withTaskCancellationHandler(operation: {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        }, onCancel: { worker.cancel() })
    }
    func page(query: String, limit: Int = pageSize) -> Page {
        let words = Set(query.split(whereSeparator: { $0.isWhitespace }).map { String($0).lowercased() })
        var total = 0, visible: [Option] = []
        for option in options where words.allSatisfy({ option.title.localizedStandardContains($0) || option.location.localizedStandardContains($0) }) {
            total += 1
            if visible.count < max(0, limit) { visible.append(option) }
        }
        return Page(options: visible, total: total)
    }
    /// Re-read just the chosen identity. Never admit a deleted, ambiguous or
    /// inaccessible source using a previously displayed catalog entry.
    static func current(_ id: String, kind: WorkflowTemplate.Kind, projects: [Record], sections: [Record], tasks: [Record]) -> Record? {
        guard !id.isEmpty else { return nil }
        func one(_ id: String, in rows: [Record]) -> Record? {
            let matches = Array(rows.lazy.filter { $0.id == id }.prefix(2))
            return matches.count == 1 ? matches[0] : nil
        }
        switch kind {
        case .project: return one(id, in: projects)
        case .section:
            guard let row = one(id, in: sections), one(row.string("project_id"), in: projects) != nil else { return nil }
            return row
        case .task:
            guard let row = one(id, in: tasks), row.string("project_id").isEmpty || one(row.string("project_id"), in: projects) != nil else { return nil }
            return row
        }
    }
}

/// One readable project graph for a specific user gesture. Order changes never
/// edit parent/access/archive fields, and stale callbacks cannot cross sessions.
struct ProjectOrderRequest: Sendable {
    let workspace: WorkspaceBinding
    let session: UUID
    let projects: [Record]
    let ordering: ProjectOrganization.Ordering
    init(workspace: WorkspaceBinding, session: UUID, projects: [Record]) {
        self.workspace = workspace; self.session = session; self.projects = projects
        ordering = ProjectOrganization.Ordering(projects)
    }
    func matches(workspace: WorkspaceBinding, session: UUID, projects: [Record]) -> Bool {
        self.workspace == workspace && self.session == session && self.projects == projects
    }
}

extension ProjectOrganization {
    struct Ordering: Sendable {
        let rows: [Record]
        let visible: [Item]
        private let parents: [String: String]
        private let peerIDs: [String: [String]]
        private let valid: Bool
        init(_ projects: [Record]) {
            rows = OrganizationOrder.sorted(projects)
            valid = projects.count <= 10000 && projects.allSatisfy { !$0.id.isEmpty } && Set(projects.map(\.id)).count == projects.count
            let items = valid ? ProjectOrganization.outline(projects) : []
            visible = items
            let visibleIDs = Set(items.map(\.id))
            let keys = Dictionary(uniqueKeysWithValues: items.map { ($0.id, visibleIDs.contains($0.project.string("parent_id")) ? $0.project.string("parent_id") : "") })
            parents = keys
            peerIDs = Dictionary(grouping: items, by: { keys[$0.id]! }).mapValues { $0.map(\.id) }
        }
        private func parent(_ row: Record) -> String {
            // Unavailable ancestors are displayed as roots, without detaching them.
            parents[row.id] ?? ""
        }
        func siblings(of id: String) -> [String] {
            guard let key = parents[id] else { return [] }
            return peerIDs[key] ?? []
        }
        func shifting(_ id: String, by distance: Int) throws -> [String] {
            guard valid, [-1, 1].contains(distance) else { throw OrganizationOrder.StaleList() }
            var ids = siblings(of: id)
            guard let index = ids.firstIndex(of: id) else { throw OrganizationOrder.StaleList() }
            let next = index + distance
            guard ids.indices.contains(next) else { return rows.map(\.id) }
            ids.swapAt(index, next)
            return replacing(ids)
        }
        func moving(from offsets: IndexSet, to destination: Int) throws -> [String] {
            guard valid, !offsets.isEmpty, offsets.allSatisfy({ visible.indices.contains($0) }),
                  (0...visible.count).contains(destination) else { throw OrganizationOrder.StaleList() }
            let selected = Set(offsets.map { visible[$0].id })
            let index = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0.project) })
            var roots = Set<String>()
            for id in selected {
                var cursor = index[id]!.string("parent_id"), seen = Set([id]), covered = false
                while let ancestor = index[cursor] {
                    guard seen.insert(cursor).inserted, seen.count <= ProjectOrganization.maximumDepth else { throw OrganizationOrder.StaleList() }
                    if selected.contains(cursor) { covered = true; break }
                    cursor = ancestor.string("parent_id")
                }
                if !covered { roots.insert(id) }
            }
            guard let first = visible.first(where: { roots.contains($0.id) }) else { throw OrganizationOrder.StaleList() }
            let key = parent(first.project), peers = siblings(of: first.id)
            guard roots.isSubset(of: Set(peers)) else { throw Self.differentParent }
            if !key.isEmpty {
                let branch = ProjectOrganization.descendants(key, in: rows)
                let start = visible.firstIndex { $0.id == key }! + 1
                let end = visible[start...].firstIndex { !branch.contains($0.id) } ?? visible.count
                guard (start...end).contains(destination) else { throw Self.differentParent }
            }
            let positions = Dictionary(uniqueKeysWithValues: visible.enumerated().map { ($0.element.id, $0.offset) })
            var remainder = peers.filter { !roots.contains($0) }
            let insertion = remainder.filter { positions[$0]! < destination }.count
            remainder.insert(contentsOf: peers.filter { roots.contains($0) }, at: insertion)
            return replacing(remainder)
        }
        private func replacing(_ siblings: [String]) -> [String] {
            let selected = Set(siblings)
            var cursor = 0
            return rows.map { row in
                guard selected.contains(row.id) else { return row.id }
                defer { cursor += 1 }
                return siblings[cursor]
            }
        }
        private static var differentParent: AppFailure {
            AppFailure(message: "Reorder projects within the same parent. Use Edit to choose another parent project.")
        }
    }
}
