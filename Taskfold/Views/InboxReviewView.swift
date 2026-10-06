import SwiftUI

private struct InboxReviewActionKey: EnvironmentKey {
    static let defaultValue: (InboxReviewBatch) -> Void = { _ in }
}
extension EnvironmentValues {
    var startInboxReview: (InboxReviewBatch) -> Void {
        get { self[InboxReviewActionKey.self] }
        set { self[InboxReviewActionKey.self] = newValue }
    }
}

/// Decisions use the normal durable queue. Keeping a card does not manufacture a task change.
struct InboxReviewView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(Workspace.self) private var workspace
    #endif
    @State private var request: InboxReviewRequest
    @State private var decisions: [String: InboxReviewDecision] = [:]
    @State private var editing: Record?
    @State private var failure: String?
    @State private var feedback: String?
    @State private var lastDecision: (String, [String: InboxReviewDecision], [UUID]?)?
    init(request: InboxReviewRequest) { _request = State(initialValue: request) }
    private var available: Bool { request.workspace.matches(account: store.userID, generation: store.workspaceGeneration) }
    private var remaining: [Record] { available ? request.remaining(tasks: store.tasks, decisions: decisions) : [] }
    private var current: Record? { remaining.first }
    private var inboxCount: Int { store.tasks.filter(InboxReviewRequest.eligible).count }
    private var reviewedCount: Int { request.ids.filter { decisions[$0] != nil }.count }
    private var hasUnreviewed: Bool { store.tasks.contains { InboxReviewRequest.eligible($0) && decisions[$0.id] == nil } }
    private var undoIDs: [UUID]? { store.undoStack.last?.redo.map(\.id) }
    private var canUndo: Bool { available && lastDecision.map { $0.2 == nil || $0.2 == undoIDs } == true }
    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !available {
                        ContentUnavailableView("Workspace changed", systemImage: "person.crop.circle.badge.exclamationmark", description: Text("Close this review and open your current Inbox."))
                    } else if let task = current {
                        progress
                        card(task)
                        actions(task)
                    } else { summary }
                    if let feedback {
                        Text(feedback).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("inboxReviewFeedback")
                    }
                    if canUndo {
                        Button(action: undoDecision) { actionLabel("Undo last decision", "arrow.uturn.backward") }
                            .buttonStyle(.plain).accessibilityIdentifier("inboxReviewUndo")
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).id("review-top")
            }
            .onChange(of: current?.id) { _, _ in reader.scrollTo("review-top", anchor: .top) }
            .onChange(of: editing?.id) { _, value in if value == nil { reader.scrollTo("review-top", anchor: .top) } }
            }
            .navigationTitle("Review Inbox")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(current == nil ? "Done" : "Close") { dismiss() }.accessibilityIdentifier("inboxReviewClose")
                }
            }
            .alert("Could not save decision", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK") { failure = nil } } message: { Text(failure ?? "") }
            .sheet(item: $editing) { task in
                #if os(iOS)
                TaskEditor(task: task)
                #else
                NavigationStack {
                    TaskInspectorForm(taskID: task.id).id(task.id)
                        .navigationTitle("Task details")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { editing = nil }.accessibilityIdentifier("inboxReviewEditorDone") } }
                }.frame(minWidth: 460, idealWidth: 560, minHeight: 540)
                #endif
            }
            .onChange(of: store.workspaceGeneration) { _, _ in editing = nil; dismiss() }
            #if DEBUG
            .onAppear { if ProcessInfo.processInfo.arguments.contains("--inbox-review-fail-save") { store.inboxFixtureFailSave = true } }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 560, minHeight: 500, idealHeight: 640)
        #endif
    }
    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(reviewedCount) reviewed · \(remaining.count) left").font(.subheadline.weight(.semibold)).monospacedDigit().accessibilityIdentifier("inboxReviewProgress")
            ProgressView(value: Double(request.ids.count - remaining.count), total: Double(max(1, request.ids.count))).tint(Color.taskfold).accessibilityLabel("Captured batch").accessibilityValue("\(request.ids.count - remaining.count) of \(request.ids.count) settled")
            Text("Choose a home, finish it, or keep it here.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func card(_ task: Record) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(task.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("inboxReviewTitle")
            if task.priority < 4 { Label("Priority \(task.priority)", systemImage: "flag").foregroundStyle(Color.taskfold) }
            if let date = Dates.parse(TaskPlanner.plannedDay(task)) {
                let time = TaskPlanner.clockValue(task), zone = TaskPlanner.zoneLabel(task)
                Label("Planned " + date.formatted(date: .abbreviated, time: .omitted) + (time.isEmpty ? "" : " · " + time) + (zone.isEmpty ? "" : " · " + zone), systemImage: "calendar")
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("inboxReviewPlan")
            }
            if let deadline = task.deadline { Label("Deadline " + deadline.formatted(date: .abbreviated, time: .omitted), systemImage: "flag.checkered") }
            if let estimate = task.durationMinutes { Label("\(estimate) min estimate", systemImage: "hourglass") }
            if !task.string("description").isEmpty { Text(task.string("description")).font(.body).foregroundStyle(.secondary).lineLimit(8).fixedSize(horizontal: false, vertical: true) }
        }.font(.caption).padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(CardSurface(radius: 20, elevated: true))
    }
    private func actions(_ task: Record) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Menu {
                if store.projects.isEmpty { Text("Create a project from Browse to organize tasks.") }
                ForEach(store.projects) { project in
                    Button(project.name) { move(task, to: project.id) }.accessibilityIdentifier("inboxReviewProject-" + project.id)
                }
            } label: { actionLabel("Move to project", "folder", primary: true) }
                .accessibilityIdentifier("inboxReviewMove").disabled(store.projects.isEmpty)
            if store.projects.isEmpty { Text("No projects yet. You can edit, finish, or keep this task here.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Button { guard let row = live(task) else { return }; editing = row } label: { actionLabel("Edit details", "pencil") }.accessibilityIdentifier("inboxReviewEdit")
            Button { complete(task) } label: { actionLabel("Complete", "checkmark.circle") }.accessibilityIdentifier("inboxReviewComplete")
            Button { keep(task) } label: { actionLabel("Keep in Inbox", "tray") }.accessibilityIdentifier("inboxReviewKeep")
        }.buttonStyle(.plain)
    }
    private var onAccent: Color {
        #if os(macOS)
        Color.onAccent
        #else
        Color.taskfold.accentCheckmark
        #endif
    }
    private func actionLabel(_ title: String, _ symbol: String, primary: Bool = false) -> some View {
        Label(title, systemImage: symbol).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(primary ? onAccent : Color.primary)
            .background(primary ? Color.taskfold : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
    }
    private func live(_ shown: Record) -> Record? {
        guard let row = request.actionable(shown, tasks: store.tasks, account: store.userID, generation: store.workspaceGeneration) else {
            feedback = "This task changed. Review its current contents before deciding."; return nil
        }
        return row
    }
    private func save(_ changes: [Mutation], name: String) -> Bool {
        var saved = false
        #if os(macOS)
        workspace.run(name) { saved = store.commit(changes) }
        #else
        saved = store.commit(changes)
        #endif
        if !saved { failure = store.error ?? "Your decision could not be saved. Try again."; store.error = nil }
        return saved
    }
    private func finish(_ row: Record, decision: InboxReviewDecision, message: String, undo: [UUID]?) {
        lastDecision = (row.id, decisions, undo)
        decisions[row.id] = decision; feedback = message
    }
    private func move(_ shown: Record, to project: String) {
        guard let row = live(shown), store.record("projects", id: project) != nil else { return }
        guard save([InboxReviewRequest.move(row, to: project)], name: "Move Inbox Task") else { return }
        finish(row, decision: .moved, message: "Moved to " + (store.record("projects", id: project)?.name ?? "project"), undo: undoIDs)
    }
    private func complete(_ shown: Record) {
        guard let row = live(shown) else { return }
        guard save(store.toggleChanges(row), name: "Complete Inbox Task") else { return }
        finish(row, decision: .completed, message: "Completed “\(row.title)”", undo: undoIDs)
    }
    private func keep(_ shown: Record) {
        guard let row = live(shown) else { return }
        finish(row, decision: .kept, message: "Kept in Inbox", undo: nil)
    }
    private func undoDecision() {
        guard canUndo, let last = lastDecision else { return }
        if last.2 != nil {
            #if os(macOS)
            if let manager = workspace.undoManager, manager.canUndo { manager.undo() } else { store.undo() }
            #else
            store.undo()
            #endif
            guard last.2 != undoIDs else { return }
        }
        decisions = last.1; lastDecision = nil; feedback = "Decision undone"
    }
    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: inboxCount == 0 ? "tray" : "sparkles").font(.system(size: 40)).foregroundStyle(Color.taskfold)
            Text(inboxCount == 0 ? "Inbox is clear" : "Review finished").font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("inboxReviewSummary")
            Text(inboxCount == 0 ? "A little room for what comes next." : "\(inboxCount) open \(inboxCount == 1 ? "task remains" : "tasks remain") in Inbox.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("inboxReviewRemaining")
            if !decisions.isEmpty {
                Text([InboxReviewDecision.moved, .completed, .kept].compactMap { decision -> String? in
                    let count = decisions.values.filter { $0 == decision }.count
                    return count > 0 ? "\(count) \(decision.rawValue)" : nil
                }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
            }
            if inboxCount > 0 {
                Button {
                    let continuing = hasUnreviewed
                    guard let fresh = store.makeInboxReview(batch: request.batch, excluding: continuing ? Set(decisions.keys) : []) else { return }
                    request = fresh; if !continuing { decisions = [:] }; lastDecision = nil; feedback = nil
                } label: { actionLabel(hasUnreviewed ? "Review more" : "Review again", "tray", primary: true) }
                    .buttonStyle(.plain).accessibilityIdentifier("inboxReviewMore")
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).modifier(CardSurface(radius: 20))
    }
}
