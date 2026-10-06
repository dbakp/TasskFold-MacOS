import Foundation

/// A presentation belongs to one workspace incarnation, including an account → other → account switch.
struct WorkspaceBinding: Equatable, Sendable {
    var account: String
    var generation: UUID
    func matches(account: String, generation: UUID) -> Bool { !self.account.isEmpty && self.account == account && self.generation == generation }
}

enum InboxReviewBatch: String, CaseIterable, Codable, Sendable {
    case five = "5", ten = "10", all = "all"
    var limit: Int? { Int(rawValue) }
}

enum InboxReviewDecision: String, Sendable { case kept, moved, completed }

/// IDs are captured once. Removed/completed/moved tasks are never reconstructed from stale cards.
struct InboxReviewRequest: Identifiable, Sendable {
    var id = UUID()
    var workspace: WorkspaceBinding
    var ids: [String]
    var batch: InboxReviewBatch
    init(workspace: WorkspaceBinding, tasks: [Record], batch: InboxReviewBatch = .five, order: [String] = [], excluding: Set<String> = []) {
        self.workspace = workspace; self.batch = batch
        var seen = Set<String>()
        let inbox = tasks.filter { !$0.id.isEmpty && seen.insert($0.id).inserted && Self.eligible($0) && !excluding.contains($0.id) }
        let ranked = DayPlacement.arranged(inbox.enumerated().sorted { $0.element.priority == $1.element.priority ? $0.offset < $1.offset : $0.element.priority < $1.element.priority }.map(\.element), ids: order)
        ids = Array(ranked.prefix(batch.limit ?? ranked.count)).map(\.id)
    }
    static func eligible(_ task: Record) -> Bool { !task.completed && task.string("project_id").isEmpty }
    func remaining(tasks: [Record], decisions: [String: InboxReviewDecision]) -> [Record] {
        let rows = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { decisions[$0] == nil ? rows[$0] : nil }.filter(Self.eligible)
    }
    func actionable(_ shown: Record, tasks: [Record], account: String, generation: UUID) -> Record? {
        guard workspace.matches(account: account, generation: generation), ids.contains(shown.id),
              let row = tasks.first(where: { $0.id == shown.id }), Self.eligible(row),
              row["task_generation"] == shown["task_generation"],
              row["completion_version"].integer == shown["completion_version"].integer else { return nil }
        return row
    }
    /// A move changes organization only. Existing dates, estimates, deadlines and reminders survive.
    static func move(_ task: Record, to project: String) -> Mutation {
        Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: ["project_id": .string(project), "section_id": .null])
    }
}

struct InboxReviewLink: Equatable, Sendable {
    var account: String
    var batch: InboxReviewBatch
    static func parse(_ url: URL) -> InboxReviewLink? {
        guard url.scheme == "taskfold", url.host == "review", url.path == "/inbox", url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = components.queryItems,
              items.count == 2, Set(items.map(\.name)) == ["account", "batch"],
              let account = items.first(where: { $0.name == "account" })?.value, !account.isEmpty, account.count <= 256,
              let value = items.first(where: { $0.name == "batch" })?.value, let batch = InboxReviewBatch(rawValue: value) else { return nil }
        return InboxReviewLink(account: account, batch: batch)
    }
}
