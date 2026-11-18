import SwiftUI
import UniformTypeIdentifiers

// Child rows cutover (identical on iOS and macOS): Store helpers for satellites that create subtasks, and the one
// review that offers offline edits saved by the retired JSON child-record system for export.

extension Store {
    /// Adds titled subtasks under a saved parent as one undoable commit (Suggest steps / on-device AI).
    @discardableResult
    func addChildTasks(_ titles: [String], to parentID: String) -> Bool {
        guard TaskTree.rowsEnabled, let parent = record("tasks", id: parentID) else { error = "This task is no longer available."; return false }
        guard !titles.isEmpty else { return false }
        let rows = ChildRowSteps.rows(titles, under: parent, tree: TaskTree(tasks), account: userID)
        return commitChildRows(rows.map { Mutation(table: "tasks", recordID: $0.id, method: "POST", fields: $0.fields) })
    }

    /// Every legacy child journal that still holds saved work, as saved. Empty when there is nothing to offer.
    func legacyChildJournals() async throws -> [String: Data] {
        guard TaskTree.rowsEnabled, let scope = childTaskFieldRecoveryScope else { return [:] }
        return try legacyChildJournalBlobs(scope)
    }
}

// MARK: - Team projects

/// Subtasks in a team project are rows too (Migration T), but team tasks are closed to direct writes: every change
/// goes through the team RPCs with the editor scope captured from the row (docs/TEAM_CHILD_ROWS.md). Viewers can read
/// subtasks but cannot add, edit, reorder or delete them.
extension Store {
    /// True for a task in a team project.
    func isTeamTask(_ task: Record) -> Bool {
        guard let cache = nativeConversationTeamCache else { return false }
        return cache.knownTasks.contains(task.id) || cache.knownTeams[task.string("project_id")] != nil
    }
    /// Whether the subtasks of `parentID` can be added to or changed here: always for a personal or shared task, and for a
    /// team task only with a current manager or editor role.
    func canEditSubtasks(of parentID: String) -> Bool {
        guard let parent = record("tasks", id: parentID) else { return false }
        guard isTeamTask(parent) else { return true }
        return (try? captureTeamTaskEditor(parent)) != nil
    }
    /// Commits child-row changes as one undoable step; team rows go through the team RPCs.
    @discardableResult
    func commitChildRows(_ changes: [Mutation]) -> Bool {
        do { return commit(try teamScopedChildChanges(changes)) }
        catch { self.error = error.localizedDescription; return false }
    }
    private func isTeamRowChange(_ change: Mutation) -> Bool {
        guard change.table == "tasks", change.teamTaskScope == nil, change.teamCompletion == nil, change.teamTaskBatch == nil else { return false }
        if let row = record("tasks", id: change.recordID) { return isTeamTask(row) }
        return change.method == "POST" && nativeConversationTeamCache?.knownTeams[change.fields["project_id"]?.text ?? ""] != nil
    }
    /// The same changes, with every change to a team row captured by that row's team editor: a new subtask is a lifecycle
    /// `create` with `parent_id`/`child_order`, a structure or date edit is a saved team edit, and a deleted parent takes
    /// its subtasks with it, deepest first, each with its own certified deletion (Undo restores the parent first).
    func teamScopedChildChanges(_ changes: [Mutation]) throws -> [Mutation] {
        guard changes.contains(where: isTeamRowChange) else { return changes }
        guard let cache = nativeConversationTeamCache else { throw TeamTaskEditorDraft.unavailable }
        let workspace = WorkspaceBinding(account: userID, generation: workspaceGeneration), session = backend.reminderSessionIncarnation
        var result: [Mutation] = [], deleted = Set<String>()
        for change in changes {
            guard isTeamRowChange(change) else { result.append(change); continue }
            switch change.method {
            case "POST":
                var row = Record(change.fields)
                row["id"] = .string(change.recordID); row["user_id"] = .string(userID)
                let draft = try captureTeamTaskCreation(row)
                if let created = try draft.mutation(desired: row, current: nil, workspace: workspace, session: session, cache: cache, enabled: nativeTeamEditorEnabled, requestID: change.id) { result.append(created) }
            case "DELETE":
                for member in TaskTree.deletionExpansion(of: change.recordID, tasks: tasks) where deleted.insert(TaskTree.key(member.recordID)).inserted {
                    guard let row = record("tasks", id: member.recordID) else { continue }
                    let requestID = TaskTree.key(member.recordID) == TaskTree.key(change.recordID) ? change.id : UUID()
                    result.append(try captureTeamTaskEditor(row).deletion(current: row, workspace: workspace, session: session, cache: cache, enabled: nativeTeamEditorEnabled, requestID: requestID))
                }
            case "PATCH":
                guard let row = record("tasks", id: change.recordID) else { throw TeamTaskEditorDraft.unavailable }
                var desired = row
                for (key, value) in change.fields { desired[key] = value }
                if let edit = try captureTeamTaskEditor(row).mutation(desired: desired, current: row, workspace: workspace, session: session, cache: cache, enabled: nativeTeamEditorEnabled, requestID: change.id) { result.append(edit) }
            default: result.append(change)
            }
        }
        return result
    }
    /// Deleting a team parent deletes its subtasks with it: the descendants of every team deletion in `changes` that
    /// the same commit does not already delete, deepest first, ahead of their parent. Nil when there are none.
    func teamSubtaskDeletions(for changes: [Mutation]) throws -> [Mutation]? {
        let deleting = Set(changes.filter { $0.table == "tasks" && $0.method == "DELETE" }.map { TaskTree.key($0.recordID) })
        let missing = changes.filter { $0.table == "tasks" && $0.method == "DELETE" && $0.teamTaskScope != nil }
            .flatMap { TaskTree(tasks).descendants(of: $0.recordID) }.filter { !deleting.contains(TaskTree.key($0.id)) }
        guard !missing.isEmpty else { return nil }
        var result: [Mutation] = []
        for change in changes {
            if change.table == "tasks", change.method == "DELETE", change.teamTaskScope != nil {
                let extra = try teamScopedChildChanges([Mutation(table: "tasks", recordID: change.recordID, method: "DELETE", fields: [:])])
                result += extra.filter { TaskTree.key($0.recordID) != TaskTree.key(change.recordID) && !deleting.contains(TaskTree.key($0.recordID)) }
            }
            result.append(change)
        }
        return result
    }
    /// Completing a team parent completes its open subtasks in the same step (one batch, one Undo); reopening a subtask
    /// under a completed parent reopens its completed ancestors. Nil when the task has no such relatives.
    func teamTreeCompletion(_ task: Record) throws -> [Mutation]? {
        let tree = TaskTree(tasks)
        guard let cache = nativeConversationTeamCache else { return nil }
        let workspace = WorkspaceBinding(account: userID, generation: workspaceGeneration), session = backend.reminderSessionIncarnation
        if !task.completed {
            let open = tree.descendants(of: task.id).filter { !$0.completed && TaskKind.mayComplete($0) }
            guard !open.isEmpty else { return nil }
            let rows = [task] + open
            if rows.count <= 100 { return [try reviewedTeamTaskCompletionSelection(try captureTeamTaskCompletionSelection(rows))] }
            return try rows.map { try captureTeamTaskEditor($0).completionMutation(current: $0, tasks: tasks, workspace: workspace, session: session, cache: cache, enabled: nativeTeamEditorEnabled) }
        }
        let closed = tree.ancestors(of: task.id).filter { $0.completed && TaskKind.mayComplete($0) }
        guard !closed.isEmpty else { return nil }
        return try ([task] + closed).map { try captureTeamTaskEditor($0).completionMutation(current: $0, tasks: tasks, workspace: workspace, session: session, cache: cache, enabled: nativeTeamEditorEnabled) }
    }
    /// A team selection includes the subtasks of every selected task, so one batch (and its Undo) covers whole subtrees.
    func withTeamSubtasks(_ records: [Record], openOnly: Bool = false) -> [Record] {
        let tree = TaskTree(tasks)
        var seen = Set<String>(), result: [Record] = []
        for row in records where seen.insert(TaskTree.key(row.id)).inserted { result.append(row) }
        for row in records {
            for child in tree.descendants(of: row.id) where (!openOnly || !child.completed) && seen.insert(TaskTree.key(child.id)).inserted { result.append(child) }
        }
        return result
    }
}

/// The exported file: the saved journals as one JSON document.
struct LegacySubtaskEditsFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// "Subtask edits saved before the update": shown once per account and launch when legacy journals hold saved work.
struct LegacySubtaskEditsReview: ViewModifier {
    @Environment(Store.self) private var store
    @State private var journals: [String: Data] = [:]
    @State private var presented = false
    @State private var exporting = false
    @State private var file: LegacySubtaskEditsFile?
    @State private var failure: String?
    private var dismissedKey: String { "taskfold.legacySubtaskEditsDismissed." + store.userID }

    func body(content: Content) -> some View {
        content
            .task(id: store.childTaskFieldRecoveryScope?.account ?? "") {
                guard TaskTree.rowsEnabled, store.childTaskFieldRecoveryScope != nil, !UserDefaults.standard.bool(forKey: dismissedKey) else { return }
                guard let found = try? await store.legacyChildJournals(), !found.isEmpty, !Task.isCancelled else { return }
                journals = found; presented = true
            }
            .sheet(isPresented: $presented) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(LegacyChildJournalExport.message).fixedSize(horizontal: false, vertical: true)
                        Text(journals.count == 1 ? "1 saved group of edits" : "\(journals.count) saved groups of edits").foregroundStyle(.secondary)
                        if let failure { Text(failure).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                        Spacer(minLength: 0)
                    }
                    .padding()
                    .navigationTitle(LegacyChildJournalExport.title)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Not now") { presented = false }.accessibilityIdentifier("legacySubtaskEditsLater")
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Export…") {
                                do { file = LegacySubtaskEditsFile(data: try LegacyChildJournalExport.document(journals)); exporting = true }
                                catch { failure = "These edits couldn’t be prepared for export. They are still saved on this device." }
                            }.accessibilityIdentifier("legacySubtaskEditsExport")
                        }
                    }
                    .fileExporter(isPresented: $exporting, document: file, contentType: .json, defaultFilename: "Taskfold subtask edits") { result in
                        switch result {
                        case .success: UserDefaults.standard.set(true, forKey: dismissedKey); presented = false
                        case .failure: failure = "The export didn’t finish. The edits are still saved on this device."
                        }
                    }
                }
                .frame(minWidth: 360, minHeight: 220)
            }
    }
}

extension View {
    /// Offers legacy child journals for export once subtasks are rows.
    func legacySubtaskEditsReview() -> some View { modifier(LegacySubtaskEditsReview()) }
}
