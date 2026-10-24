import SwiftUI

struct TeamTaskDeletionRequest: Identifiable {
    let id = UUID()
    let draft: TeamTaskEditorDraft
    let current: () -> Bool
    let perform: (UUID) -> Bool
    let completed: () -> Void
}

struct TeamTaskDeletionReview: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: TeamTaskDeletionRequest
    @State private var message: String?
    @State private var finished = false
    private var refusal: String? {
        guard !finished, request.current() else { return "This task or its draft changed. Close this review and reopen its current details before deleting." }
        do { _ = try store.reviewedTeamTaskDeletion(request.draft, requestID: request.id); return nil }
        catch { return error.localizedDescription }
    }
    var body: some View {
        let blocked = refusal
        NavigationStack {
            Form {
                if blocked == nil {
                Section {
                    Text(request.draft.source.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    LabeledContent("Project", value: store.record("projects", id: request.draft.scope.project)?.name ?? "Shared project")
                    Text("This removes the task for everyone in this project, including its saved notes, checklist and attachments. Other tasks in the repeat series stay in place.").foregroundStyle(.secondary)
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
                        } else { message = store.error ?? "The task could not be deleted. Its saved contents are unchanged; try again." }
                    } label: {
                        Label("Delete task for everyone", systemImage: "trash").foregroundStyle(blocked == nil ? Color.red : Color.secondary)
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
            .navigationTitle("Delete shared task?")
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
