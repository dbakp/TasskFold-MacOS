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
        var seen = Set<String>()
        return tasks.filter { seen.insert($0.id).inserted && contains($0.id, pins: pins, account: account) }
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
        let editable = record.fields.filter { $0.key != "completion_version" }
        let changed = (baseline ?? existing).map { old in editable.filter { old.fields[$0.key] != $0.value } } ?? editable
        guard !changed.isEmpty else { return nil }
        return Mutation(table: "tasks", recordID: record.id, method: existing == nil ? "POST" : "PATCH", fields: changed,
                        baseline: baseline.map { TaskCompletionRevision.editBaseline(for: changed, from: $0) })
    }
    /// Both grapheme and byte bounds matter: one combining sequence can be enormous.
    static func excerpt(_ raw: String, characters: Int, bytes: Int) -> (String, Bool) {
        let value = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var result = "", count = 0, used = 0
        for character in value {
            let chunk = String(character), size = chunk.utf8.count
            guard count < characters, used + size <= bytes else { return (result, true) }
            result += chunk; count += 1; used += size
        }
        return (result, false)
    }
    static func payload(tasks: [Record], pins: [Record], account: String) -> [JSON] {
        self.tasks(tasks, pins: pins, account: account).map { task in
            let title = excerpt(task.title, characters: 160, bytes: 1000)
            let text = excerpt(task.string("description"), characters: 1200, bytes: 6000)
            let id = (try? JSONEncoder().encode([account, "note", task.id]).base64EncodedString()) ?? ""
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
