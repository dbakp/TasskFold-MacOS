import Foundation

/// An opt-in reference to canonical task notes. Independent rows prevent pins to different
/// tasks from overwriting each other when two devices work offline.
enum PinnedNotes {
    static func validID(_ id: String) -> Bool { !id.isEmpty && id.utf8.count <= 200 && !id.contains(":") && !id.contains("|") }
    static func key(_ taskID: String) -> String { "widget-note:" + taskID }
    static func contains(_ taskID: String, pins: [Record], account: String) -> Bool {
        guard !account.isEmpty, validID(taskID) else { return false }
        return pins.first(where: { $0.id == key(taskID) }).map { $0.string("user_id") == account && $0["ids"] == .array([.string(taskID)]) } == true
    }
    static func tasks(_ tasks: [Record], pins: [Record], account: String) -> [Record] {
        guard !account.isEmpty else { return [] }
        // Preserve the first registry row even if foreign or malformed. Filtering
        // before indexing could let a later duplicate expose an unselected note.
        let registry = Dictionary(pins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return tasks.filter { task in
            let id = task.id
            guard seen.insert(id).inserted, validID(id), let pin = registry[key(id)] else { return false }
            return pin.string("user_id") == account && pin["ids"] == .array([.string(id)])
        }
    }
    static func change(taskID: String, enabled: Bool, pins: [Record], account: String) -> Mutation? {
        guard !account.isEmpty, validID(taskID) else { return nil }
        let existing = pins.first { $0.id == key(taskID) }
        guard existing == nil || existing?.string("user_id") == account else { return nil }
        if enabled {
            guard !contains(taskID, pins: pins, account: account) else { return nil }
            return Mutation(table: "view_orders", recordID: key(taskID), method: "POST", fields: ["id": .string(key(taskID)), "user_id": .string(account), "ids": .array([.string(taskID)])])
        }
        return existing == nil ? nil : Mutation(table: "view_orders", recordID: key(taskID), method: "DELETE", fields: [:])
    }
    /// Keep completion revision baselines and merge only edited fields, like ordinary task edits.
    static func edit(_ record: Record, existing: Record?, baseline: Record?) -> Mutation? {
        let editable = record.fields.filter { $0.key != "completion_version" && (existing == nil || $0.key != "task_generation") }
        let changed = (baseline ?? existing).map { old in editable.filter { old.fields[$0.key] != $0.value } } ?? editable
        guard !changed.isEmpty else { return nil }
        return Mutation(table: "tasks", recordID: record.id, method: existing == nil ? "POST" : "PATCH", fields: changed,
                        baseline: baseline.map { TaskCompletionRevision.editBaseline(for: changed, from: $0) })
    }
    /// Both grapheme and byte bounds matter: one combining sequence can be enormous.
    static func excerpt(_ raw: String, characters: Int, bytes: Int) -> (String, Bool) {
        NoteMarkup.excerpt(raw, characters: characters, bytes: bytes)
    }
    static func payload(tasks: [Record], pins: [Record], account: String) -> [JSON] {
        self.tasks(tasks, pins: pins, account: account).map { task in
            let title = excerpt(task.title, characters: 160, bytes: 1000)
            let text = NoteMarkup.preview(task.string("description"), characters: 1200, bytes: 6000)
            let id = (try? TaskfoldJSONEncoder().encode([account, "note", task.id]).base64EncodedString()) ?? ""
            return .object(["id": .string(id), "taskID": .string(task.id), "title": .string(title.0), "text": .string(text.0), "truncated": .bool(text.1), "completed": .bool(task.completed)])
        }
    }
}

/// Untouched editors follow sync. The first tap captures the visible selection, so a
/// deliberate choice still applies when another device changed it after this sheet opened.
struct PinnedNoteSelection {
    private var baseline: Bool?
    private(set) var desired: Bool?
    var change: Bool? { guard let baseline, let desired, baseline != desired else { return nil }; return desired }
    mutating func choose(_ value: Bool, current: Bool) {
        if desired == nil { baseline = current }
        desired = value
    }
}

struct PinnedNoteRequest: Identifiable {
    var id = UUID()
    var workspace: WorkspaceBinding
    var taskID: String?
}
struct PinnedNoteLink: Equatable {
    var account: String
    var taskID: String?
    static func parse(_ url: URL) -> Self? {
        guard url.scheme == "taskfold", url.host == "note" || url.host == "notes", url.fragment == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.user == nil, parts.password == nil, parts.port == nil,
              let query = parts.queryItems, query.count == 1, query[0].name == "account",
              let account = query[0].value, !account.isEmpty, account.utf8.count <= 256 else { return nil }
        if url.host == "notes" { return parts.percentEncodedPath.isEmpty ? Self(account: account, taskID: nil) : nil }
        let path = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 2, path[0].isEmpty, let id = String(path[1]).removingPercentEncoding, PinnedNotes.validID(id) else { return nil }
        return Self(account: account, taskID: id)
    }
}

/// Device-local recovery evidence for an account-owned list arrangement. This
/// metadata is never a row field or a service write and grants no task access.
struct TaskOrderRecovery: Codable, Equatable, Sendable {
    struct TaskIdentity: Codable, Equatable, Sendable {
        let id: String
        /// Missing rows remain opaque references, never inferred incarnations.
        let generation: String?
        let project: String?
    }
    let version: Int
    let commandID: UUID
    let account: String
    let origin: String
    let before: Record?
    let after: Record?
    let tasks: [TaskIdentity]
    var taskIDs: Set<String> { Set(tasks.map(\.id)) }
    static var invalid: AppFailure { AppFailure(message: "This saved list choice needs review. Your queued work is kept.") }
    private static func ids(_ row: Record) throws -> [String] {
        guard Set(row.fields.keys).isSubset(of: ["id", "user_id", "ids", "updated_at"]),
              case .array(let raw) = row["ids"], raw.count <= 10000,
              raw.allSatisfy({ if case .string(let id) = $0 { return TeamProjectValue.id(id) }; return false }),
              Set(raw.map(\.text)).count == raw.count,
              row.fields["updated_at"].map({ $0 == .null || TaskPlanning.instant($0.text) != nil }) ?? true else { throw invalid }
        return raw.map(\.text)
    }
    private static func projected(_ change: Mutation, before: Record?, account: String) throws -> Record? {
        guard change.table == "view_orders", !change.recordID.isEmpty, change.recordID.utf8.count <= 300,
              change.teamTaskScope == nil, change.teamTaskBatch == nil, change.teamCompletion == nil,
              change.organizationOrder == nil, change.reminderPreferenceField == nil, change.insertOnly != true,
              ["POST", "PATCH", "DELETE"].contains(change.method),
              before.map({ $0.id == change.recordID && $0.string("user_id") == account }) ?? true else { throw invalid }
        if let before { _ = try ids(before) }
        if let baseline = change.baseline {
            let row = Record(baseline); _ = try ids(row)
            guard row.id == change.recordID, row.string("user_id") == account else { throw invalid }
        }
        if change.method == "DELETE" {
            guard change.fields.isEmpty, before != nil else { throw invalid }; return nil
        }
        guard Set(change.fields.keys) == ["id", "user_id", "ids"], change.fields["id"] == .string(change.recordID), change.fields["user_id"] == .string(account) else { throw invalid }
        let after = Record((before?.fields ?? [:]).merging(change.fields) { _, desired in desired }); _ = try ids(after)
        return after
    }
    static func capturing(_ change: Mutation, snapshot: Snapshot, account: String, origin: String) throws -> Mutation {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        let rows = (snapshot.tables["view_orders"] ?? []).filter { $0.id == change.recordID }
        guard rows.count <= 1 else { throw invalid }
        let before = rows.first, after = try projected(change, before: before, account: account)
        let ids = Set(try [before, after].compactMap { $0 }.flatMap(Self.ids))
        guard !ids.isEmpty else { throw invalid }
        var indexed: [String: Record] = [:]
        for row in snapshot.tables["tasks"] ?? [] where ids.contains(row.id) {
            guard indexed.updateValue(row, forKey: row.id) == nil else { throw invalid }
        }
        var bindings: [TaskIdentity] = []
        for id in ids.sorted() {
            if let task = indexed[id] {
                guard TeamProjectValue.id(task.string("task_generation")), task.string("project_id").isEmpty || TeamProjectValue.id(task.string("project_id")) else { throw invalid }
                bindings.append(TaskIdentity(id: id, generation: task.string("task_generation"), project: task.string("project_id")))
            } else { bindings.append(TaskIdentity(id: id, generation: nil, project: nil)) }
        }
        var result = change
        result.orderRecovery = Self(version: 1, commandID: change.id, account: account, origin: origin, before: before, after: after, tasks: bindings)
        try result.orderRecovery!.validate(result); return result
    }
    func validate(_ change: Mutation) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard version == 1, commandID == change.id, change.orderRecovery == self,
              after == (try Self.projected(change, before: before, account: account)),
              !tasks.isEmpty, tasks.count <= 10000, Set(tasks.map(\.id)).count == tasks.count,
              tasks.allSatisfy({ task in
                  guard TeamProjectValue.id(task.id) else { return false }
                  if let generation = task.generation, let project = task.project { return TeamProjectValue.id(generation) && (project.isEmpty || TeamProjectValue.id(project)) }
                  return task.generation == nil && task.project == nil
              }),
              Set(try [before, after].compactMap { $0 }.flatMap(Self.ids)) == taskIDs else { throw Self.invalid }
        if change.recordID.hasPrefix("widget-note:") {
            let id = String(change.recordID.dropFirst("widget-note:".count))
            guard TeamProjectValue.id(id), taskIDs == [id], [before, after].compactMap({ $0 }).allSatisfy({ $0["ids"] == .array([.string(id)]) }) else { throw Self.invalid }
        }
    }
    static func references(_ change: Mutation, tasks: Set<String>) -> Bool {
        func contains(_ value: JSON) -> Bool {
            switch value {
            case .string(let text): return tasks.contains { text.lowercased().contains($0.lowercased()) }
            case .array(let values): return values.contains(where: contains)
            case .object(let fields): return fields.values.contains(where: contains)
            default: return false
            }
        }
        guard let data = try? TaskfoldJSONEncoder().encode(change), let value = try? TaskfoldJSONDecoder().decode(JSON.self, from: data) else { return true }
        return contains(value)
    }
    /// Entire same-row histories are parked. Splitting a user's ordering vector
    /// would invent a different choice, so its exact prior row is restored.
    static func parking(_ changes: [Mutation], snapshot: Snapshot, affected: Set<String>, taskRows: [Record], account: String, origin: String) throws -> (indices: Set<Int>, restored: [String: Record], removed: Set<String>) {
        let keys = Set(changes.filter { $0.table == "view_orders" && references($0, tasks: affected) }.map(\.recordID))
        var selected = Set<Int>(), first: [String: TaskOrderRecovery] = [:], last: [String: TaskOrderRecovery] = [:]
        for (i, change) in changes.enumerated() where change.table == "view_orders" && keys.contains(change.recordID) {
            guard let value = change.orderRecovery, value.account == account, value.origin == origin else { throw invalid }
            try value.validate(change)
            for task in value.tasks where affected.contains(task.id) {
                guard let generation = task.generation, let project = task.project,
                      taskRows.contains(where: { $0.id == task.id && $0.string("task_generation") == generation && $0.string("project_id") == project }) else { throw invalid }
            }
            if let previous = last[change.recordID] { guard previous.after == value.before else { throw invalid } }
            if first[change.recordID] == nil { first[change.recordID] = value }
            last[change.recordID] = value; selected.insert(i)
        }
        var restored: [String: Record] = [:], removed = Set<String>()
        for key in keys {
            let rows = (snapshot.tables["view_orders"] ?? []).filter { $0.id == key }
            guard rows.count <= 1, rows.first == last[key]?.after else { throw invalid }
            if let row = first[key]?.before { restored[key] = row } else { removed.insert(key) }
        }
        return (selected, restored, removed)
    }
    static func reviewText(_ changes: [Mutation], snapshot: Snapshot, records: [Record] = []) -> [String] {
        let titles = Dictionary(((snapshot.tables["tasks"] ?? []) + records).map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var latest: [String: TaskOrderRecovery] = [:], order: [String] = []
        for change in changes where change.orderRecovery != nil {
            if latest[change.recordID] == nil { order.append(change.recordID) }; latest[change.recordID] = change.orderRecovery
        }
        return order.compactMap { key in
            guard let value = latest[key] else { return nil }
            if key.hasPrefix("widget-note:") {
                let id = String(key.dropFirst("widget-note:".count)), title = titles[id] ?? "Unavailable task"
                return "Pinned note choice: " + title + (value.after == nil ? " — unpinned" : " — pinned")
            }
            let names = value.after?["ids"].list.map { id in titles[id.text] ?? "Unavailable task" } ?? []
            return "Saved list order: " + (names.isEmpty ? "Cleared" : names.joined(separator: " → ")) + "\nThe previous list arrangement was restored. This saved choice will not be sent automatically."
        }
    }
}
