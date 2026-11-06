import Foundation

/// Shared task labels are portable text. Personal label IDs/catalogs never
/// participate in editing or normalizing these values.
struct TeamTaskLabelsDraft: Equatable {
    struct Entry: Identifiable, Equatable {
        let id: Int
        let value: String
        var name: String? { TeamTaskLabelsDraft.displayName(value) }
    }
    let original: JSON
    private(set) var entries: [Entry]
    let supported: Bool
    private var nextID: Int
    init(_ value: JSON) {
        original = value
        if case .array(let rows) = value, rows.count <= 256,
           rows.allSatisfy({ if case .string(let name) = $0 { return !name.isEmpty && name.utf8.count <= 1024 }; return false }) {
            entries = rows.enumerated().map { Entry(id: $0.offset, value: $0.element.text) }; supported = true
        } else if value == .null { entries = []; supported = true }
        else { entries = []; supported = false }
        nextID = entries.count
    }
    var value: JSON { supported ? .array(entries.map { .string($0.value) }) : original }
    var changed: Bool { supported && (original == .null ? !entries.isEmpty : value != original) }
    static func displayName(_ value: String) -> String? {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              UUID(uuidString: value) == nil,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }) else { return nil }
        return value
    }
    static func name(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100, name.utf8.count <= 400, displayName(name) != nil else {
            throw AppFailure(message: "Use a label name of 1–100 characters without line breaks or hidden formatting.")
        }
        return name
    }
    mutating func add(_ input: String) throws {
        guard supported else { throw AppFailure(message: "These saved labels need a newer version before editing.") }
        let name = try Self.name(input)
        guard entries.count < 256 else { throw AppFailure(message: "A task can have up to 256 labels. Remove one before adding another.") }
        guard !entries.contains(where: { $0.value == name }) else { throw AppFailure(message: "That label is already on this task.") }
        entries.append(Entry(id: nextID, value: name)); nextID += 1
    }
    mutating func remove(_ id: Int) { guard supported else { return }; entries.removeAll { $0.id == id } }
    /// Suggestions are only a convenience, never an authority or an account
    /// catalog. Inspect bounded visible project data, including nested children.
    static func suggestions(project: String, roots: [Record]) -> [String] {
        var names = Set<String>(), visited = 0, inspectedValues = 0
        func read(_ record: Record, depth: Int) {
            guard depth <= SubtaskTree.maximumDepth, visited < 2048, inspectedValues < 4096, names.count < 200 else { return }; visited += 1
            for value in record["labels"].list.prefix(256) {
                guard inspectedValues < 4096, names.count < 200 else { return }; inspectedValues += 1
                guard case .string(let text) = value, let name = try? Self.name(text), name == text else { continue }
                if names.count < 200 { names.insert(name) }
            }
            for child in record["subtasks"].list.prefix(2048) {
                if case .object(let fields) = child { read(Record(fields), depth: depth + 1) }
                if visited >= 2048 || inspectedValues >= 4096 || names.count >= 200 { break }
            }
        }
        for root in roots where root.string("project_id") == project {
            read(root, depth: 0); if visited >= 2048 || inspectedValues >= 4096 || names.count >= 200 { break }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

extension TeamTaskLabelsDraft {
    static func usesPersonalCatalog(_ task: Record, cache: TeamWorkspaceCache?) -> Bool {
        cache?.knownTasks.contains(task.id) != true && cache?.knownTeams[task.string("project_id")] == nil
    }
    static func normalizing(_ mutation: Mutation, existing: Record?, catalog: [Record], cache: TeamWorkspaceCache?) -> Mutation {
        guard mutation.table == "tasks", mutation.teamTaskScope == nil,
              usesPersonalCatalog(existing ?? Record(mutation.fields), cache: cache),
              cache?.knownTeams[mutation.fields["project_id"]?.text ?? ""] == nil,
              case .array(let values)? = mutation.fields["labels"] else { return mutation }
        var result = mutation; result.fields["labels"] = .array(TaskLabels.normalized(values, labels: catalog)); return result
    }
}

/// Names are portable shared values; the personal catalog is never consulted.
enum TeamTaskLabelAction: String, CaseIterable, Identifiable {
    case add, remove, clear
    var id: String { rawValue }
    var title: String { switch self { case .add: "Add"; case .remove: "Remove"; case .clear: "Clear all" } }
}
struct TeamTaskBulkLabels {
    static func name(action: TeamTaskLabelAction, input: String) throws -> String {
        switch action {
        case .clear: return ""
        case .add: return try TeamTaskLabelsDraft.name(input)
        case .remove:
            guard input.utf8.count <= 1024, TeamTaskLabelsDraft.displayName(input) != nil else {
                throw AppFailure(message: "Choose an exact saved label name without hidden formatting.")
            }
            return input
        }
    }
    static func changes(records: [Record], action: TeamTaskLabelAction, input: String) throws -> [String: [String: JSON]] {
        guard (1...100).contains(records.count), Set(records.map(\.id)).count == records.count else { throw TeamTaskBatch.invalid }
        let name = try Self.name(action: action, input: input)
        return try Dictionary(uniqueKeysWithValues: records.map { row in
            // Shared server rows have an array. A missing/newer shape cannot
            // provide an exact reversible baseline; refresh it before editing.
            guard case .array(let original) = row["labels"], TeamTaskLabelsDraft(row["labels"]).supported else {
                throw AppFailure(message: "A selected task’s saved labels need to be refreshed before editing this selection.")
            }
            let desired: [JSON]
            switch action {
            case .add:
                if original.contains(.string(name)) { desired = original }
                else {
                    guard original.count < 256 else { throw AppFailure(message: "A selected task already has 256 labels. Remove one before adding another.") }
                    desired = original + [.string(name)]
                }
            case .remove: desired = original.filter { $0 != .string(name) }
            case .clear: desired = []
            }
            return (row.id, ["labels": .array(desired)])
        })
    }
    static func suggestions(records: [Record], action: TeamTaskLabelAction = .add) -> [String] {
        var names = Set<String>()
        for row in records.prefix(100) {
            for value in row["labels"].list.prefix(256) {
                guard case .string(let text) = value, let name = try? Self.name(action: action, input: text), name == text else { continue }
                names.insert(name)
                if names.count >= 200 { return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
            }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
