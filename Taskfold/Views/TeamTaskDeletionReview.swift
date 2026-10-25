import SwiftUI

struct TeamTaskDeletionRequest: Identifiable {
    let id: UUID
    let drafts: [TeamTaskEditorDraft]
    let selection: TeamTaskDeletionSelection?
    let current: () -> Bool
    let perform: (UUID) -> Bool
    let completed: () -> Void
    var draft: TeamTaskEditorDraft { drafts[0] }
    init(draft: TeamTaskEditorDraft, current: @escaping () -> Bool, perform: @escaping (UUID) -> Bool, completed: @escaping () -> Void) {
        id = UUID(); drafts = [draft]; selection = nil
        self.current = current; self.perform = perform; self.completed = completed
    }
    init(selection: TeamTaskDeletionSelection, current: @escaping () -> Bool, perform: @escaping () -> Bool, completed: @escaping () -> Void) {
        id = selection.requestID; drafts = selection.drafts; self.selection = selection
        self.current = current; self.perform = { _ in perform() }; self.completed = completed
    }
}

struct TeamTaskDeletionReview: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: TeamTaskDeletionRequest
    @State private var message: String?
    @State private var finished = false
    private var refusal: String? {
        guard !finished, request.current() else { return "This review is no longer current. Close it and review the tasks again before deleting." }
        do {
            if let selection = request.selection { _ = try store.reviewedTeamTaskDeletionSelection(selection) }
            else { _ = try store.reviewedTeamTaskDeletion(request.draft, requestID: request.id) }
            return nil
        }
        catch { return error.localizedDescription }
    }
    var body: some View {
        let blocked = refusal
        NavigationStack {
            Form {
                if blocked == nil {
                Section {
                    if request.selection != nil {
                        Text("\(request.drafts.count) shared tasks").font(.title2.weight(.semibold))
                        Text("Delete only the tasks listed below, for everyone in their projects. Their notes, checklists, attachments and conversations stay available for Undo on this device. Unselected repeat occurrences stay in place and are detached when their parent is deleted.").foregroundStyle(.secondary)
                    } else {
                    Text(request.draft.source.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    LabeledContent("Project", value: store.record("projects", id: request.draft.scope.project)?.name ?? "Shared project")
                    Text("This removes the task for everyone in this project, including its saved notes, checklist and attachments. Other tasks in the repeat series stay in place.").foregroundStyle(.secondary)
                    }
                }
                if request.selection != nil {
                    Section("Selected tasks") {
                        ForEach(request.drafts, id: \.source.id) { draft in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(draft.source.title).fixedSize(horizontal: false, vertical: true)
                                Text(store.record("projects", id: draft.scope.project)?.name ?? "Shared project").font(.caption).foregroundStyle(.secondary)
                            }.accessibilityElement(children: .combine)
                        }
                    }.accessibilityIdentifier("teamDeletionSelection")
                }
                Section {
                    Label("Undo stays available on this device", systemImage: "arrow.uturn.backward")
                    Text("The shared conversation is preserved for Undo. Restoring requires current project access.").font(.footnote).foregroundStyle(.secondary)
                }
                }
                if let blocked { Section { Label("Deletion paused", systemImage: "lock.shield"); Text(blocked).foregroundStyle(.secondary) }.accessibilityIdentifier("teamDeletionPaused") }
                if let message { Section { Text(message).foregroundStyle(.red).accessibilityIdentifier("teamDeletionError") } }
                Section {
                    Button(role: .destructive) {
                        guard !finished, refusal == nil else { return }
                        if request.perform(request.id) {
                            finished = true; request.completed(); dismiss()
                        } else {
                            message = store.error ?? "The tasks could not be deleted. Their saved contents are unchanged; try again."
                            store.error = nil
                        }
                    } label: {
                        Label(request.selection == nil ? "Delete task for everyone" : "Delete \(request.drafts.count) tasks for everyone", systemImage: "trash").foregroundStyle(blocked == nil ? Color.red : Color.secondary)
                    }.disabled(blocked != nil).accessibilityIdentifier("confirmTeamTaskDeletion")
                }
                #if DEBUG
                if TeamEditorNativeFixture.enabled, ProcessInfo.processInfo.arguments.contains("--team-delete-testing") {
                    Section {
                        Button("Change test role to viewer") { store.revokeTeamEditorNativeFixture() }.accessibilityIdentifier("revokeTeamDeletionFixture")
                        Button("Change saved test task") { store.changeTeamDeletionFixtureSource() }.accessibilityIdentifier("changeTeamDeletionFixture")
                        Button("Fail the next test save") { store.failTeamDeletionFixtureSave() }.accessibilityIdentifier("failTeamDeletionFixture")
                    }
                }
                #endif
            }.formStyle(.grouped).accessibilityIdentifier("teamDeletionForm")
            .navigationTitle(request.selection == nil ? "Delete shared task?" : "Delete shared tasks?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("cancelTeamTaskDeletion") } }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 430, idealHeight: 580)
        #endif
    }
}
