import Foundation

/// Local metadata stays in the account cache, outside exported workspace tables and sync.
struct WidgetCompletionCache: Codable, Equatable, Sendable {
    struct State: Codable, Equatable, Sendable { var token: String; var signature: String }
    var states: [String: State] = [:]
    var receipts: [String: String] = [:]
    var receiptOrder: [String] = []
    var feedback: WidgetCompletionFeedback? = nil
    mutating func record(_ request: WidgetCompletionRequest) {
        let id = request.id.uuidString.lowercased()
        receipts[id] = WidgetTaskIdentity.key(request.taskID); receiptOrder.removeAll { $0 == id }; receiptOrder.append(id)
        while receiptOrder.count > 256 { receipts.removeValue(forKey: receiptOrder.removeFirst()) }
    }
    func saved(_ request: WidgetCompletionRequest) -> Bool { receipts[request.id.uuidString.lowercased()] == WidgetTaskIdentity.key(request.taskID) }
}

enum WidgetCompletion {
    enum Plan { case complete([Mutation]), saved, stale }
    static func prepare(_ snapshot: inout Snapshot) {
        let tasks = snapshot.tables["tasks"] ?? []
        let instants = InstantNormalizer()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let children = childItems(snapshot, account: "widget-index")
        let ids = Set(tasks.map { WidgetTaskIdentity.key($0.id) } + children.map(\.id))
        snapshot.widgetCompletion.states = snapshot.widgetCompletion.states.filter { ids.contains($0.key) }
        for task in tasks where !task.id.isEmpty {
            let id = task.id.lowercased()
            var values: [JSON] = [.bool(task.completed), .string(instants.canonical(task.string("created_at"))), .string(instants.canonical(task.string("completed_at"))), task["completion_version"], task["is_heading"]]
            if !task.string("task_generation").isEmpty { values.append(task["task_generation"]) }
            let signature = (try? encoder.encode(values)).map { DueReminder.digest(String(decoding: $0, as: UTF8.self)) } ?? ""
            if snapshot.widgetCompletion.states[id]?.signature != signature {
                snapshot.widgetCompletion.states[id] = .init(token: UUID().uuidString.lowercased(), signature: signature)
            }
        }
        for child in children {
            if let signature = childSignature(child), snapshot.widgetCompletion.states[child.id]?.signature != signature {
                snapshot.widgetCompletion.states[child.id] = .init(token: UUID().uuidString.lowercased(), signature: signature)
            }
        }
    }
    static func hasChildFilter(_ snapshot: Snapshot) -> Bool {
        (snapshot.tables["saved_views"] ?? []).contains { (try? FilterRule(document: $0["query_ast"]).needsChildCandidates) == true }
    }
    /// Primary widgets opt into independent work beneath headings. Ordinary
    /// checklists still require an explicit child filter, including at replay.
    static func hierarchy(_ snapshot: Snapshot, account: String) -> TaskHierarchyIndex? {
        guard hasChildFilter(snapshot) || (snapshot.tables["tasks"] ?? []).contains(where: { TaskKind($0) == .heading }) else { return nil }
        return try? TaskHierarchyIndex(roots: snapshot.tables["tasks"] ?? [], projects: snapshot.tables["projects"] ?? [], workspace: WorkspaceBinding(account: account, generation: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!))
    }
    static func childItems(_ snapshot: Snapshot, account: String) -> [TaskHierarchyIndex.Item] {
        guard let index = hierarchy(snapshot, account: account) else { return [] }
        if hasChildFilter(snapshot) { return index.items.filter(\.isSubtask) }
        let reading = ProductiveTaskReading(tasks: snapshot.tables["tasks"] ?? [])
        return index.items.filter { $0.isSubtask && reading.contains($0.id) }
    }
    /// Root incarnation and path bind a link without making completion/editing invalidate it.
    static func routeContext(_ item: TaskHierarchyIndex.Item) -> String? {
        let values: [JSON] = [.string(item.id), item.root["task_generation"], item.root["created_at"], item.root["project_id"], item.root["section_id"], item.source["task_generation"], item.source["created_at"]]
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(values)).map { DueReminder.digest(String(decoding: $0, as: UTF8.self)) }
    }
    private static func childSignature(_ item: TaskHierarchyIndex.Item) -> String? {
        // Completion changes only this node; a descendant's independent action
        // must not invalidate its parent's still-visible checkbox.
        var own = item.source.fields; own.removeValue(forKey: "subtasks")
        let values: [JSON] = [.string(item.id), .object(own), item.root["task_generation"], item.root["created_at"], item.root["project_id"], item.root["section_id"]]
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(values)).map { DueReminder.digest(String(decoding: $0, as: UTF8.self)) }
    }
    static func tokens(_ snapshot: Snapshot) -> [String: String] { snapshot.widgetCompletion.states.mapValues(\.token) }
    static func plan(_ request: WidgetCompletionRequest, snapshot: Snapshot, account: String, calendar: Calendar = .current) -> Plan {
        guard !account.isEmpty, account == request.account, UUID(uuidString: request.token) == request.id else { return .stale }
        if snapshot.widgetCompletion.saved(request) { return .saved }
        if request.taskID.hasPrefix("subtask:") {
            guard let index = hierarchy(snapshot, account: account), let selection = index.selection(request.taskID),
                  hasChildFilter(snapshot) || ProductiveTaskReading(tasks: snapshot.tables["tasks"] ?? []).contains(request.taskID),
                  let state = snapshot.widgetCompletion.states[request.taskID], state.token == request.token,
                  childSignature(selection.item) == state.signature else { return .stale }
            guard TaskKind.mayComplete(selection.item.record) else { return .stale }
            if selection.item.record.completed { return .saved }
            guard let changes = try? TaskHierarchyIndex.changes([.completion(selection, completed: true, at: request.createdAt)], accessibleRoots: snapshot.tables["tasks"] ?? [], projects: snapshot.tables["projects"] ?? [], workspace: index.workspace) else { return .stale }
            return .complete(changes)
        }
        guard let task = snapshot.tables["tasks"]?.first(where: { $0.id.lowercased() == WidgetTaskIdentity.key(request.taskID) }) else { return .stale }
        guard TaskKind.mayComplete(task) else { return .stale }
        if task.completed { return .saved }
        guard !ProjectOrganization.archived(task.string("project_id"), in: snapshot.tables["projects"] ?? []) else { return .stale }
        guard snapshot.widgetCompletion.states[task.id.lowercased()]?.token == request.token else { return .stale }
        return .complete(TaskCompletion.complete(task, tasks: snapshot.tables["tasks"] ?? [], at: request.createdAt, calendar: calendar, account: account))
    }
    /// One canonicalization pass owns its parsers and memo. Never share mutable
    /// formatters, cached dates or account metadata between saves or workers.
    private final class InstantNormalizer {
        private lazy var fractional: ISO8601DateFormatter = {
            let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value
        }()
        private lazy var whole = ISO8601DateFormatter()
        // Invalid Unicode spellings can compare equal as Swift Strings while
        // producing different persisted signature bytes. Preserve raw UTF-8 keys.
        private var memo: [Data: String] = [:]
        func canonical(_ value: String) -> String {
            guard !value.isEmpty else { return value }
            let key = Data(value.utf8)
            if let cached = memo[key] { return cached }
            let normalized = (fractional.date(from: value) ?? whole.date(from: value)).map { fractional.string(from: $0) } ?? value
            memo[key] = normalized
            return normalized
        }
    }
}
