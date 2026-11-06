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
    init(workspace: WorkspaceBinding, tasks: [Record], batch: InboxReviewBatch = .five, order: [String] = [], excluding: Set<String> = [], reading: ProductiveTaskReading? = nil) {
        self.workspace = workspace; self.batch = batch
        var seen = Set<String>()
        let inbox = Self.candidates(tasks: tasks, reading: reading).filter { seen.insert($0.id).inserted && !excluding.contains($0.id) }
        let ranked = DayPlacement.arranged(inbox.enumerated().sorted { $0.element.priority == $1.element.priority ? $0.offset < $1.offset : $0.element.priority < $1.element.priority }.map(\.element), ids: order)
        ids = Array(ranked.prefix(batch.limit ?? ranked.count)).map(\.id)
    }
    static func candidates(tasks: [Record], reading: ProductiveTaskReading? = nil) -> [Record] {
        (reading ?? ProductiveTaskReading(tasks: tasks)).presentation.filter(eligible)
    }
    static func eligible(_ task: Record) -> Bool { TaskKind.mayComplete(task) && !task.completed && task.string("project_id").isEmpty }
    func remaining(tasks: [Record], decisions: [String: InboxReviewDecision], reading: ProductiveTaskReading? = nil) -> [Record] {
        let rows = Dictionary(Self.candidates(tasks: tasks, reading: reading).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { decisions[$0] == nil ? rows[$0] : nil }.filter(Self.eligible)
    }
    func actionable(_ shown: Record, tasks: [Record], account: String, generation: UUID) -> Record? {
        guard workspace.matches(account: account, generation: generation), ids.contains(shown.id),
              let row = Self.candidates(tasks: tasks).first(where: { $0.id == shown.id }), Self.eligible(row),
              SubtaskTree.referencePath(shown.id) == nil || row == shown,
              row["task_generation"] == shown["task_generation"],
              row["completion_version"].integer == shown["completion_version"].integer else { return nil }
        return row
    }
    /// A move changes organization only. Existing dates, estimates, deadlines and reminders survive.
    static func move(_ task: Record, to project: String) throws -> Mutation {
        guard !task.id.hasPrefix("subtask:"), !task.id.hasPrefix("work:"), !task.id.isEmpty else { throw PlannerFailure(message: "Review the containing heading before moving this grouped task.") }
        return Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: ["project_id": .string(project), "section_id": .null])
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


/// A grouped child never silently detaches or moves its siblings. The native
/// review captures the entire root/destination and revalidates both at Confirm.
struct InboxHeadingMoveReview: Identifiable {
    let id = UUID()
    let workspace: WorkspaceBinding
    let root: Record
    let destination: Record
    let previewTasks: [Record]
    let assignmentCount: Int
    var taskTitles: [String] { previewTasks.map(\.title) }
    var taskCount: Int { previewTasks.count }
    init(task: Record, tasks: [Record], projects: [Record], destination: String, workspace: WorkspaceBinding) throws {
        guard let path = SubtaskTree.referencePath(task.id),
              let root = tasks.first(where: { $0.id == path[0] }), tasks.filter({ $0.id == root.id }) == [root], TaskKind(root) == .heading,
              root.string("project_id").isEmpty, !root.completed,
              root.string("user_id").isEmpty || root.string("user_id") == workspace.account,
              projects.filter({ $0.id == destination }).count == 1,
              let target = projects.first(where: { $0.id == destination }), target["team_id"] == .null,
              !ProjectOrganization.archivedIDs(in: projects).contains(destination) else { throw Self.changed }
        let index = try TaskHierarchyIndex(roots: [root], projects: projects, workspace: workspace)
        let reading = ProductiveTaskReading(tasks: [root])
        guard index.item(task.id)?.record == task, !reading.incomplete,
              reading.contains(task.id), InboxReviewRequest.eligible(task) else { throw Self.changed }
        self.workspace = workspace; self.root = root; self.destination = target
        previewTasks = ProjectWorkScope(tasks: [root]).items.map(\.task)
        assignmentCount = index.items.filter { !$0.source.string("assigned_to").isEmpty }.count
    }
    static var changed: PlannerFailure { PlannerFailure(message: "This group or destination changed. Close this review and choose its current contents again.") }
    func changes(tasks: [Record], projects: [Record], workspace: WorkspaceBinding) throws -> [Mutation] {
        guard workspace == self.workspace, tasks.filter({ $0.id == root.id }) == [root],
              projects.filter({ $0.id == destination.id }) == [destination],
              !ProjectOrganization.archivedIDs(in: projects).contains(destination.id) else { throw Self.changed }
        return try TaskSelectionPlan.changes([.init(task: root, action: .patch(["project_id": .string(destination.id), "section_id": .null]), workspace: workspace)], accessibleRoots: tasks, projects: projects, workspace: workspace)
    }
    func contains(_ reference: String) -> Bool { SubtaskTree.referencePath(reference)?.first == root.id }
}
