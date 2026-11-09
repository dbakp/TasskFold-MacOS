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
    /// Caller-confined, bounded memo of computed hashes, never saved widget
    /// tokens or task text. A fresh Store/scope always computes its own values.
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
        fileprivate func signature(for child: TaskHierarchyIndex.Item, compute: () -> String?) -> String? {
            // Prove the original child tree and routing inputs, not unrelated
            // root dates/notes. Projections and current visibility still rebuild
            // every pass; action admission independently checks current data.
            signature(key: "child:" + child.id, source: child.root.widgetChildSignatureSourceToken,
                cacheable: child.id.utf8.count <= 256, compute: compute)
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
        let children = childItems(snapshot, account: "widget-index")
        let ids = Set(tasks.map { WidgetTaskIdentity.key($0.id) } + children.map(\.id))
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
        for child in children {
            let signature = signatures.map { $0.signature(for: child) { childSignature(child) } } ?? childSignature(child)
            if let signature, snapshot.widgetCompletion.states[child.id]?.signature != signature {
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
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(values)).map { DueReminder.digest(String(decoding: $0, as: UTF8.self)) }
    }
    private static func childSignature(_ item: TaskHierarchyIndex.Item) -> String? {
        // Completion changes only this node; a descendant's independent action
        // must not invalidate its parent's still-visible checkbox.
        var own = item.source.fields; own.removeValue(forKey: "subtasks")
        var values: [JSON] = []; values.reserveCapacity(6)
        values.append(.string(item.id)); values.append(.object(own))
        item.root.appendWidgetChildSignatureContext(to: &values)
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = .sortedKeys
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
