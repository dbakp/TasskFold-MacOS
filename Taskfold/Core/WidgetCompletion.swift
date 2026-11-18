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
    /// Caller-confined hash proofs and separately bounded task projections.
    /// Projections stay in this scope; the immutable worker seed carries only
    /// hashes/empty source identities, never task text or saved widget tokens.
    final class SignatureCache {
        struct Scope: Equatable, Sendable {
            let workspace: WorkspaceBinding
            let session: UUID
            let access: UUID
        }
        struct Statistics: Equatable { var reused = 0, computed = 0, retained = 0 }
        fileprivate struct Entry: Sendable { let source: Record.SourceToken; let signature: String }
        struct Seed: Sendable {
            fileprivate let scope: Scope
            fileprivate let entries: [String: Entry]
        }
        private let maximumEntries: Int
        private var scope: Scope?
        private var entries: [String: Entry] = [:], next: [String: Entry] = [:]
        private(set) var statistics = Statistics()
        init(maximumEntries: Int = 4096, seed: Seed? = nil) {
            self.maximumEntries = max(0, maximumEntries)
            if let seed {
                scope = seed.scope
                entries = Dictionary(uniqueKeysWithValues: seed.entries.prefix(self.maximumEntries).map { ($0.key, $0.value) })
            }
        }
        /// Only immutable, bounded hash proofs cross into a worker. The mutable
        /// cache stays confined to its caller and carries no completion authority.
        func seed(matching current: Scope?) -> Seed? {
            guard let current, current == scope else { return nil }
            return Seed(scope: current, entries: entries)
        }
        func clear() { scope = nil; entries = [:]; next = [:]; statistics = Statistics() }
        fileprivate func begin(_ current: Scope?) {
            if current == nil || current != scope { entries = [:] }
            scope = current; next = [:]; statistics = Statistics()
        }
        fileprivate func signature(for row: Record, compute: () -> String) -> String {
            let id = row.id.lowercased()
            return signature(key: "root:" + id, source: row.authoredSourceToken,
                cacheable: id.utf8.count <= 256, compute: compute) ?? ""
        }
        private func signature(key: String, source: Record.SourceToken, cacheable: Bool, compute: () -> String?) -> String? {
            guard cacheable else { statistics.computed += 1; return compute() }
            let value: String
            if scope != nil, let saved = entries[key], saved.source == source {
                value = saved.signature; statistics.reused += 1
            } else {
                statistics.computed += 1
                guard let computed = compute() else { return nil }; value = computed
            }
            if scope != nil, next.count < maximumEntries || next[key] != nil {
                next[key] = Entry(source: source, signature: value)
            }
            return value
        }
        fileprivate func finish() { entries = next; next = [:]; statistics.retained = entries.count }
    }
    static func prepare(_ snapshot: inout Snapshot, signatures: SignatureCache? = nil, scope: SignatureCache.Scope? = nil) {
        signatures?.begin(scope)
        defer { signatures?.finish() }

        let tasks = snapshot.tables["tasks"] ?? []
        let instants = InstantNormalizer()
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = .sortedKeys
        let ids = Set(tasks.map { WidgetTaskIdentity.key($0.id) })
        snapshot.widgetCompletion.states = snapshot.widgetCompletion.states.filter { ids.contains($0.key) }
        for task in tasks where !task.id.isEmpty {
            let id = task.id.lowercased()
            func compute() -> String {
                var values: [JSON] = [.bool(task.completed), .string(instants.canonical(task.string("created_at"))), .string(instants.canonical(task.string("completed_at"))), task["completion_version"], task["is_heading"]]
                if !task.string("task_generation").isEmpty { values.append(task["task_generation"]) }
                return (try? encoder.encode(values)).map { DueReminder.digest(String(decoding: $0, as: UTF8.self)) } ?? ""
            }
            let signature = signatures.map { $0.signature(for: task, compute: compute) } ?? compute()
            if snapshot.widgetCompletion.states[id]?.signature != signature {
                snapshot.widgetCompletion.states[id] = .init(token: UUID().uuidString.lowercased(), signature: signature)
            }
        }
    }
    static func tokens(_ snapshot: Snapshot) -> [String: String] { snapshot.widgetCompletion.states.mapValues(\.token) }
    static func plan(_ request: WidgetCompletionRequest, snapshot: Snapshot, account: String, calendar: Calendar = .current) -> Plan {
        guard !account.isEmpty, account == request.account, UUID(uuidString: request.token) == request.id else { return .stale }
        if snapshot.widgetCompletion.saved(request) { return .saved }
        if request.taskID.hasPrefix(LegacySubtaskReference.prefix), TaskTree.rowsEnabled {
            // Child rows: a checkbox from an older widget timeline carries the legacy id and the token issued for it.
            let id = LegacyTaskReference.resolve(request.taskID, enabled: true)
            guard id != request.taskID, snapshot.widgetCompletion.states[request.taskID]?.token == request.token,
                  let task = snapshot.tables["tasks"]?.first(where: { TaskTree.key($0.id) == TaskTree.key(id) }), TaskKind.mayComplete(task) else { return .stale }
            if task.completed { return .saved }
            guard !ProjectOrganization.archived(task.string("project_id"), in: snapshot.tables["projects"] ?? []) else { return .stale }
            return .complete(ChildRowCompletion.complete(task, tasks: snapshot.tables["tasks"] ?? [], at: request.createdAt, calendar: calendar, account: account))
        }
        if request.taskID.hasPrefix(LegacySubtaskReference.prefix) { return .stale }
        guard let task = snapshot.tables["tasks"]?.first(where: { $0.id.lowercased() == WidgetTaskIdentity.key(request.taskID) }) else { return .stale }
        guard TaskKind.mayComplete(task) else { return .stale }
        if task.completed { return .saved }
        guard !ProjectOrganization.archived(task.string("project_id"), in: snapshot.tables["projects"] ?? []) else { return .stale }
        guard snapshot.widgetCompletion.states[task.id.lowercased()]?.token == request.token else { return .stale }
        return .complete(ChildRowCompletion.complete(task, tasks: snapshot.tables["tasks"] ?? [], at: request.createdAt, calendar: calendar, account: account))
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
