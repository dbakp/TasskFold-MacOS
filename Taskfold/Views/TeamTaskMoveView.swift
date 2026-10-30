import SwiftUI

struct TeamTaskMoveRequest: Identifiable {
    let id = UUID()
    var draft: TeamTaskEditorDraft?
    var destination: String?
    var current: () -> Bool = { true }
    var completed: () -> Void = {}
}

struct TeamTaskMoveView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    var request = TeamTaskMoveRequest()
    @State private var model: TeamTaskMoveModel?
    @State private var loadedLifecycle: String?
    @State private var review: TeamTaskMoveReview?
    @State private var command: TeamTaskMoveCommand?
    @State private var boundaryToken: String?
    @State private var actionTitle = "Move task"
    @State private var preparing = false
    @State private var message: String?
    @State private var success: String?
    @State private var needsRefresh = false
    @State private var accepted = false
    @State private var completionDelivered = false
    @State private var reviewEpoch = UUID()
    @State private var clearing: TeamTaskMoveCommand?
    private var lifecycle: String { "\(store.userID)|\(store.workspaceGeneration)|\(store.backend.reminderSessionIncarnation)|\((try? store.backend.accountRemovalOrigin) ?? "")" }
    private var current: Bool { loadedLifecycle == lifecycle && store.teamTaskMovesAvailable && phase == .active }
    private var admission: TeamTaskMoveAdmission? { request.draft.flatMap { try? TeamTaskMoveAdmission($0) } }
    private var choices: [Record] { guard current, request.current(), let admission else { return [] }; return (try? store.teamTaskMoveDestinations(admission)) ?? [] }
    private var reviewCurrent: Bool {
        guard current, let review, let boundaryToken, store.teamTaskMoveReviewCurrent(review.scope, token: boundaryToken) else { return false }
        if review.scope.undoes == nil, let admission {
            return request.current() && review.task == admission.draft.source && (try? store.teamTaskMoveScope(admission, destination: review.scope.destination)) == review.scope
        }
        return true
    }
    var body: some View {
        NavigationStack {
            Form {
                if current, let model {
                    if let success { Section { Label(success, systemImage: "checkmark.circle.fill").foregroundStyle(.green).accessibilityIdentifier("teamMoveSuccess") } }
                    if needsRefresh {
                        Section {
                            Text("The move is confirmed. Refresh your workspace to see its current contents.").foregroundStyle(.secondary)
                            Button("Refresh workspace") { Task { await refresh() } }.accessibilityIdentifier("refreshTeamMoveWorkspace")
                        }
                    }
                    if let pending = model.pending {
                        Section("Saved move request") {
                            Label("Waiting for confirmation", systemImage: "arrow.triangle.2.circlepath")
                            Text("Retry safely to check the result. Closing this screen keeps the saved request for later.").foregroundStyle(.secondary)
                            Button("Retry saved move") { Task { await model.retry(); await received() } }.accessibilityIdentifier("retryTeamTaskMove")
                            Button("Review clearing this request", role: .destructive) { clearing = pending }.accessibilityIdentifier("clearTeamTaskMove")
                        }
                    } else if let review {
                        if reviewCurrent {
                            Section {
                                Text(review.task.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                                LabeledContent("From", value: review.sourceName)
                                LabeledContent("To", value: review.destinationName)
                                Label(review.visibility == .team ? "Team-visible destination" : "Private destination", systemImage: review.visibility == .team ? "person.2" : "lock")
                                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Text("People with access to the destination will be able to see the task and its discussion.").font(.footnote).foregroundStyle(.secondary)
                            }.accessibilityIdentifier("teamMoveContentsReview")
                            Section("What moves with it") {
                                Text("Notes, checklist, dates, reminders and the saved discussion stay with the task.")
                                LabeledContent("Discussion comments", value: String(review.discussionCount))
                                if review.keepsSubtaskUndoPrivate, review.privateSubtaskUndoCount > 0 {
                                    Text("Your saved copies of deleted subtasks stay private in their original projects.")
                                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("teamMovePrivateSubtaskUndo")
                                }
                                if review.clearedAssignments > 0 { Text("\(review.clearedAssignments) assignments will be cleared. The task will have no section in the destination.").foregroundStyle(.secondary) }
                                if review.restoredAssignments > 0 { Text("\(review.restoredAssignments) original assignments will be restored.").foregroundStyle(.secondary) }
                                if review.scope.undoes != nil { Text("The previously reviewed placement is restored if the task and discussion have stayed unchanged.").font(.footnote).foregroundStyle(.secondary) }
                            }
                            Section {
                                Button(actionTitle, systemImage: "folder.badge.arrow.forward") { Task { await confirm() } }.accessibilityIdentifier("confirmTeamTaskMove")
                                Button("Back to destinations") { self.review = nil; command = nil; boundaryToken = nil }.accessibilityIdentifier("cancelTeamTaskMoveReview")
                            }
                        } else {
                            Section { Label("Move paused", systemImage: "lock.shield"); Text("The task, project access or local work changed. Close this review and refresh before trying again.").foregroundStyle(.secondary) }.accessibilityIdentifier("teamMovePaused")
                            Section { Button("Close this review") { self.review = nil; command = nil; boundaryToken = nil } }
                        }
                    } else if !accepted, let admission {
                        if request.current(), !choices.isEmpty {
                            Section("Choose a destination") {
                                Text(admission.draft.source.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                                Text("Move this task to another project in the same team. You’ll review the changes before saving.").foregroundStyle(.secondary)
                                ForEach(choices) { project in
                                    Button { Task { await prepare(admission: admission, destination: project.id) } } label: { Label(project.name, systemImage: "folder") }
                                        .accessibilityIdentifier("teamMoveDestination-" + project.id)
                                }
                            }
                        } else {
                            Section { Label("No destination available", systemImage: "folder"); Text("Finish syncing and save or discard your edits. Moving requires editing access to another active project in this team.").foregroundStyle(.secondary) }.accessibilityIdentifier("teamMoveNoDestination")
                        }
                    }
                    if preparing || model.busy { Section { ProgressView(preparing ? "Preparing review…" : "Confirming move…") }.accessibilityIdentifier("teamMoveProgress") }
                    if let message = message ?? model.message { Section { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("teamMoveError") } }
                    if review == nil, model.pending == nil {
                        Section("Recent moves on this device") {
                            if model.history.isEmpty { Text("Your confirmed moves appear here, with reviewed Undo and Redo.").foregroundStyle(.secondary) }
                            ForEach(model.history.reversed()) { entry in
                                Button {
                                    Task { do { try await prepare(scope: entry.inverseScope(), title: entry.isUndone ? "Redo move" : "Undo move") } catch { message = error.localizedDescription } }
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Label(entry.isUndone ? "Review Redo" : "Review Undo", systemImage: entry.isUndone ? "arrow.uturn.forward" : "arrow.uturn.backward")
                                        if let task = store.record("tasks", id: entry.latest.scope.task), task.string("task_generation") == entry.latest.scope.generation, store.nativeConversationTeamCache?.boundary.projects[task.string("project_id")] != nil {
                                            Text(task.title).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                                        } else { Text("Shared task move").foregroundStyle(.secondary) }
                                    }
                                }.accessibilityIdentifier("reviewTeamMoveHistory-" + entry.id)
                            }
                            Text("The 20 most recent moves are kept privately on this device. Undo needs current project access and an unchanged task and discussion. Recovery expires after 30 days.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    #if DEBUG
                    if TeamTaskMoveNativePeer.enabled {
                        Section {
                            Button("Change test role to viewer") { store.revokeTeamEditorNativeFixture() }.accessibilityIdentifier("revokeTeamMoveFixture")
                            Button("Change saved test task") { store.changeTeamTaskMoveNativeSource() }.accessibilityIdentifier("changeTeamMoveFixture")
                            Button("Lose the next move reply") { UserDefaults.standard.set(true, forKey: "teamMoveLoseReply") }.accessibilityIdentifier("loseTeamMoveFixtureReply")
                        }
                    }
                    #endif
                } else {
                    Section { ContentUnavailableView("Move unavailable", systemImage: "lock.shield", description: Text("Return to the original synced workspace to review this move.")) }
                }
            }.formStyle(.grouped).accessibilityIdentifier("teamTaskMoveForm")
            .disabled(preparing || model?.busy == true)
            .navigationTitle("Shared task moves")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(accepted ? "Done" : model?.pending != nil ? "Close" : "Cancel") { finishPresentation(); dismiss() }.disabled(preparing || model?.busy == true).accessibilityIdentifier("closeTeamTaskMove") } }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 540, minHeight: 460, idealHeight: 650)
        #endif
        .interactiveDismissDisabled(preparing || model?.busy == true)
        .task { await setup() }
        .onChange(of: lifecycle) { _, _ in reviewEpoch = UUID(); model?.close(); review = nil; command = nil }
        .onChange(of: phase) { _, phase in if phase != .active { reviewEpoch = UUID(); review = nil; command = nil; boundaryToken = nil } }
        .onDisappear { model?.close(); finishPresentation() }
        .confirmationDialog("Clear saved move request?", isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } })) {
            if let clearing { Button("Clear saved request", role: .destructive) { Task { await model?.clearReviewedRequest(clearing); self.clearing = nil } } }
        } message: { Text("Check the latest task and project first. Clearing this device’s retry request does not undo a move the server may already have accepted. Confirmed move history is kept.") }
    }
    private func finishPresentation() {
        if accepted, !completionDelivered { completionDelivered = true; request.completed() }
    }
    private func setup() async {
        guard model == nil, store.teamTaskMovesAvailable, let origin = try? store.backend.accountRemovalOrigin,
              request.draft == nil || request.draft?.scope.account == store.userID else { return }
        #if DEBUG
        await store.prepareTeamTaskMoveNativeJournal()
        #endif
        let captured = lifecycle, account = store.userID, workspace = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration), session = store.backend.reminderSessionIncarnation
        loadedLifecycle = captured
        let value = TeamTaskMoveModel(account: account, origin: origin, vault: store.teamTaskMoveVault, service: store.teamTaskMoveService, isCurrent: { store.teamTaskMoveContextCurrent(account: account, origin: origin, workspace: workspace, session: session) })
        model = value; await value.load()
        if value.pending == nil, let admission, let destination = request.destination { await prepare(admission: admission, destination: destination) }
    }
    private func prepare(admission: TeamTaskMoveAdmission, destination: String) async {
        do { try await prepare(scope: store.teamTaskMoveScope(admission, destination: destination), title: "Move task") }
        catch { message = error.localizedDescription }
    }
    private func prepare(scope: TeamTaskMoveScope, title: String) async throws {
        guard current, !preparing, model?.busy == false, model?.pending == nil, let token = store.nativeConversationTeamCache?.boundary.raw["token"]?.text,
              store.teamTaskMoveReviewCurrent(scope, token: token) else { throw TeamTaskMoveCommand.invalid }
        preparing = true; message = nil; success = nil; defer { preparing = false }
        let epoch = reviewEpoch
        let value = try await store.teamTaskMoveService.teamTaskMoveReview(scope)
        guard epoch == reviewEpoch, current, store.teamTaskMoveReviewCurrent(scope, token: token), scope.undoes != nil || admission?.draft.source == value.task && request.current() else { throw AppFailure(message: "The task changed. Refresh your workspace and open a new move review.") }
        let proposed = try TeamTaskMoveCommand(review: value)
        review = value; command = proposed; boundaryToken = token; actionTitle = title
    }
    private func confirm() async {
        guard reviewCurrent, let command, let model else { return }
        await model.send(command); await received()
    }
    private func received() async {
        guard current, let receipt = model?.receipt else { return }
        accepted = true; success = actionTitle == "Move task" ? "Task moved" : actionTitle == "Undo move" ? "Move undone" : "Move redone"
        review = nil; command = nil; boundaryToken = nil; message = nil
        needsRefresh = !(await store.refreshAfterTeamTaskMove(receipt))
    }
    private func refresh() async {
        guard current, let receipt = model?.receipt else { return }; preparing = true
        needsRefresh = !(await store.refreshAfterTeamTaskMove(receipt)); preparing = false
    }
}
