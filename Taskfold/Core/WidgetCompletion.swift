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
        let children = hierarchy(snapshot, account: "widget-index")?.items.filter(\.isSubtask) ?? []
        let ids = Set(tasks.map { WidgetTaskIdentity.key($0.id) } + children.map(\.id))
        snapshot.widgetCompletion.states = snapshot.widgetCompletion.states.filter { ids.contains($0.key) }
        for task in tasks where !task.id.isEmpty {
            let id = task.id.lowercased()
            var values: [JSON] = [.bool(task.completed), .string(instant(task.string("created_at"))), .string(instant(task.string("completed_at"))), task["completion_version"]]
            if !task.string("task_generation").isEmpty { values.append(task["task_generation"]) }
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
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
    /// Only filters explicitly opting into child results publish child action state.
    static func hierarchy(_ snapshot: Snapshot, account: String) -> TaskHierarchyIndex? {
        guard (snapshot.tables["saved_views"] ?? []).contains(where: { (try? FilterRule(document: $0["query_ast"]).needsChildCandidates) == true }) else { return nil }
        return try? TaskHierarchyIndex(roots: snapshot.tables["tasks"] ?? [], projects: snapshot.tables["projects"] ?? [], workspace: WorkspaceBinding(account: account, generation: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!))
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
                  let state = snapshot.widgetCompletion.states[request.taskID], state.token == request.token,
                  childSignature(selection.item) == state.signature else { return .stale }
            if selection.item.record.completed { return .saved }
            guard let changes = try? TaskHierarchyIndex.changes([.completion(selection, completed: true, at: request.createdAt)], accessibleRoots: snapshot.tables["tasks"] ?? [], projects: snapshot.tables["projects"] ?? [], workspace: index.workspace) else { return .stale }
            return .complete(changes)
        }
        guard let task = snapshot.tables["tasks"]?.first(where: { $0.id.lowercased() == WidgetTaskIdentity.key(request.taskID) }) else { return .stale }
        if task.completed { return .saved }
        guard !ProjectOrganization.archived(task.string("project_id"), in: snapshot.tables["projects"] ?? []) else { return .stale }
        guard snapshot.widgetCompletion.states[task.id.lowercased()]?.token == request.token else { return .stale }
        return .complete(TaskCompletion.complete(task, tasks: snapshot.tables["tasks"] ?? [], at: request.createdAt, calendar: calendar, account: account))
    }
    private static func instant(_ value: String) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return value }
        return formatter.string(from: date)
    }
}
