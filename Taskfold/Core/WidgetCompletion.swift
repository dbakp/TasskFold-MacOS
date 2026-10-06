import Foundation

/// Local metadata stays in the account cache, outside exported workspace tables and sync.
struct WidgetCompletionCache: Codable, Equatable, Sendable {
    struct State: Codable, Equatable, Sendable { var token: String; var signature: String }
    var states: [String: State] = [:]
    var receipts: [String: String] = [:]
    var receiptOrder: [String] = []
    mutating func record(_ request: WidgetCompletionRequest) {
        let id = request.id.uuidString.lowercased()
        receipts[id] = request.taskID.lowercased(); receiptOrder.removeAll { $0 == id }; receiptOrder.append(id)
        while receiptOrder.count > 256 { receipts.removeValue(forKey: receiptOrder.removeFirst()) }
    }
    func saved(_ request: WidgetCompletionRequest) -> Bool { receipts[request.id.uuidString.lowercased()] == request.taskID.lowercased() }
}

enum WidgetCompletion {
    enum Plan { case complete([Mutation]), saved, stale }
    static func prepare(_ snapshot: inout Snapshot) {
        let tasks = snapshot.tables["tasks"] ?? []
        let ids = Set(tasks.map { $0.id.lowercased() })
        snapshot.widgetCompletion.states = snapshot.widgetCompletion.states.filter { ids.contains($0.key) }
        for task in tasks where !task.id.isEmpty {
            let id = task.id.lowercased()
            let values: [JSON] = [.bool(task.completed), .string(instant(task.string("created_at"))), .string(instant(task.string("completed_at"))), task["completion_version"]]
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let signature = (try? encoder.encode(values)).map { DueReminder.digest(String(decoding: $0, as: UTF8.self)) } ?? ""
            if snapshot.widgetCompletion.states[id]?.signature != signature {
                snapshot.widgetCompletion.states[id] = .init(token: UUID().uuidString.lowercased(), signature: signature)
            }
        }
    }
    static func tokens(_ snapshot: Snapshot) -> [String: String] { snapshot.widgetCompletion.states.mapValues(\.token) }
    static func plan(_ request: WidgetCompletionRequest, snapshot: Snapshot, account: String, calendar: Calendar = .current) -> Plan {
        guard !account.isEmpty, account == request.account, UUID(uuidString: request.token) == request.id else { return .stale }
        if snapshot.widgetCompletion.saved(request) { return .saved }
        guard let task = snapshot.tables["tasks"]?.first(where: { $0.id.lowercased() == request.taskID.lowercased() }) else { return .stale }
        if task.completed { return .saved }
        guard snapshot.widgetCompletion.states[task.id.lowercased()]?.token == request.token else { return .stale }
        return .complete(TaskCompletion.complete(task, tasks: snapshot.tables["tasks"] ?? [], at: request.createdAt, calendar: calendar))
    }
    private static func instant(_ value: String) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return value }
        return formatter.string(from: date)
    }
}
