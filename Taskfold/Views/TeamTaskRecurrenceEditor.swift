import SwiftUI

struct TeamTaskRecurrenceRequest: Identifiable {
    let id = UUID()
    let teamDraft: TeamTaskEditorDraft
    let record: Record
    let sourceIdentity: JSON
    let current: () -> Bool
    let apply: (Record) -> String?
}

/// Reuses the complete native rule controls, with an explicit shared-task review.
struct TeamTaskRecurrenceEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: TeamTaskRecurrenceRequest
    @State private var draft: Record
    @State private var session: TaskEditorSession?
    @State private var stopped = false
    @State private var finished = false
    @State private var message: String?
    init(request: TeamTaskRecurrenceRequest) { self.request = request; _draft = State(initialValue: request.record) }
    private var available: Bool { !stopped && request.current() && store.editorMayWrite(source: request.teamDraft.source, proposed: request.teamDraft.source, teamDraft: request.teamDraft) }
    private var changed: Bool { draft != request.record }
    private func checkpoint() {
        guard !finished, changed else { return }
        session?.capture(draft, extras: ["source_identity": request.sourceIdentity, "team_repeat_source": .object(request.record.fields)])
    }
    var body: some View {
        NavigationStack {
            Group {
                if available {
                    Form {
                        if TeamTaskRecurrence.supported(request.record) {
                            Section { RecurrenceFields(task: $draft).disabled(session == nil) }
                            Section {
                                Text("This repeat rule is shared with the project. When enabled, completing the task creates its next occurrence until the rule ends. Changing the rule leaves the current task in place.").font(.footnote).foregroundStyle(.secondary)
                            }
                        } else {
                            Section {
                                Label("Saved repeat rule", systemImage: "lock.shield")
                                Text("These settings can’t be edited here. The original rule is kept unchanged; review it in the app or version that created it.").foregroundStyle(.secondary)
                            }.accessibilityIdentifier("teamRepeatUnsupported")
                        }
                        if let message { Section { Text(message).foregroundStyle(.red).accessibilityIdentifier("teamRepeatError") } }
                        if let failure = session?.failure { Section { Text(failure).foregroundStyle(.red); Button("Retry preserving edit") { checkpoint(); _ = session?.flush() } } }
                        #if DEBUG
                        if TeamEditorNativeFixture.enabled {
                            Section { Button("Change test role to viewer") { store.revokeTeamEditorNativeFixture() }.accessibilityIdentifier("revokeTeamRepeatFixture") }
                        }
                        #endif
                    }.formStyle(.grouped).accessibilityIdentifier("teamRepeatForm")
                } else {
                    ScrollView { VStack(alignment: .leading, spacing: 16) {
                        Label("Repeat editing paused", systemImage: "lock.shield").font(.title2)
                        Text("Project access changed. Reopen the task’s current details before editing again.")
                        if session?.latest != nil {
                            Text(session?.preserved == true ? "Your repeat edit is saved privately with its original workspace. Open Backups & restore → Unsent task edits." : "Preserving your repeat edit…").accessibilityIdentifier("teamRepeatRecoveryStatus")
                        }
                        if let failure = session?.failure { Text(failure).foregroundStyle(.red); Button("Retry preserving edit") { checkpoint(); _ = session?.flush() } }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24) }.accessibilityIdentifier("teamRepeatPaused")
                }
            }
            .navigationTitle("Repeat")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(available ? "Cancel" : "Close") {
                        if available { if session?.finish() != false { finished = true; dismiss() } }
                        else { checkpoint(); if session == nil || session?.flush() == true { finished = true; dismiss() } }
                    }.accessibilityIdentifier("cancelTeamRepeat")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        guard available, session != nil else { return }
                        do {
                            _ = try TeamTaskRecurrence.reviewedChanges(from: request.record, to: draft)
                            if let error = request.apply(draft) { message = error; return }
                            finished = true; _ = session?.finish(); dismiss()
                        } catch { message = error.localizedDescription }
                    }.disabled(!available || session == nil || !TeamTaskRecurrence.supported(request.record)).accessibilityIdentifier("saveTeamRepeat")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 420, idealHeight: 600)
        #endif
        .onAppear {
            guard available, session == nil else { return }
            do { session = try store.beginEditorSession(request.record) }
            catch { message = "Your repeat draft cannot be protected. Close and reopen this editor." }
        }
        .onChange(of: draft) { _, _ in checkpoint() }
        .onChange(of: available) { _, value in if !value { checkpoint(); stopped = true; _ = session?.flush() } }
        .interactiveDismissDisabled(changed || session?.failure != nil)
        .onDisappear {
            if !finished, !changed, session?.failure == nil { _ = session?.finish(); finished = true }
            else { checkpoint() }
        }
    }
}
