import SwiftUI

struct TeamTaskRemindersRequest: Identifiable {
    let id = UUID()
    let teamDraft: TeamTaskEditorDraft
    let record: Record
    let sourceIdentity: JSON
    let current: () -> Bool
    let apply: (JSON) -> String?
}

struct TeamTaskRemindersEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: TeamTaskRemindersRequest
    @State private var draft: TeamTaskRemindersDraft
    @State private var editing: ReminderDraft?
    @State private var childState: JSON = .null
    @State private var session: TaskEditorSession?
    @State private var message: String?
    @State private var stopped = false
    @State private var finished = false
    init(request: TeamTaskRemindersRequest) {
        self.request = request; _draft = State(initialValue: TeamTaskRemindersDraft(request.record["reminder_specs"]))
    }
    private var available: Bool {
        !stopped && request.current() && store.editorMayWrite(source: request.teamDraft.source, proposed: request.teamDraft.source, teamDraft: request.teamDraft)
    }
    private var fixtureRevoke: (() -> Void)? {
        #if DEBUG
        return TeamEditorNativeFixture.enabled ? { store.revokeTeamEditorNativeFixture() } : nil
        #else
        return nil
        #endif
    }
    private var recoveryStatus: String {
        session?.preserved == true ? "Your reminder edit is saved privately with its original workspace. Open Backups & restore → Unsent task edits." : "Preserving your reminder edit…"
    }
    private func checkpoint() {
        guard !finished, let session else { return }
        guard draft.changed || childState != .null else {
            if session.latest != nil, session.finish(), available {
                do { self.session = try store.beginEditorSession(request.record) }
                catch { self.session = nil; message = "Your reminder draft cannot be protected. Close and reopen this editor." }
            }
            return
        }
        var task = request.record; if draft.changed { task["reminder_specs"] = draft.value }
        session.capture(task, extras: ["source_identity": request.sourceIdentity, "team_reminder_source": draft.original, "unsubmitted_reminder_settings": childState])
    }
    var body: some View {
        NavigationStack {
            Group {
                if available {
                    Form {
                        if !draft.supported {
                            Section { Label("These settings can’t be edited here", systemImage: "lock.shield"); Text("The saved reminder choices are preserved.").foregroundStyle(.secondary) }
                        } else {
                            Section {
                                Toggle("At planned time", isOn: Binding(get: { draft.plannedEnabled }, set: { value in
                                    do { try draft.setPlanned(value); message = nil } catch { message = error.localizedDescription }
                                })).disabled(!draft.plannedEditable || session == nil).accessibilityIdentifier("teamReminderPlanned")
                            } footer: {
                                Text("Before and after reminders move with the task’s plan. A date without a time uses 8:00 AM in each device’s time zone.")
                            }
                            Section("Reminder choices") {
                                ForEach(Array(draft.rows.enumerated()), id: \.offset) { index, row in
                                    if let spec = draft.editable(index), spec.id != ReminderSpec.plannedID {
                                        HStack {
                                            Button { begin(spec, index: index) } label: {
                                                VStack(alignment: .leading, spacing: 5) {
                                                    Label(spec.label, systemImage: "bell").fixedSize(horizontal: false, vertical: true)
                                                    Text(spec.enabled ? (spec.timeSensitive ? "Time Sensitive" : "Enabled") : "Off").font(.caption).foregroundStyle(.secondary)
                                                }.frame(minHeight: 44)
                                            }.buttonStyle(.borderless).accessibilityIdentifier("teamReminderEdit-\(index)")
                                            Spacer()
                                            Button(role: .destructive) { do { try draft.remove(index); message = nil } catch { message = error.localizedDescription } } label: {
                                                Image(systemName: "trash").frame(minWidth: 44, minHeight: 44)
                                            }.buttonStyle(.borderless).accessibilityLabel("Remove " + spec.label).accessibilityIdentifier("teamReminderRemove-\(index)")
                                        }
                                    } else if draft.editable(index) == nil {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Label("Saved reminder", systemImage: "lock.shield")
                                            Text("Kept unchanged. Review its settings in the original app or device.").font(.footnote).foregroundStyle(.secondary)
                                        }.accessibilityIdentifier("teamReminderPreserved-\(index)")
                                    }
                                }
                                Button("Add reminder", systemImage: "plus.circle") { begin(.relative(-10), index: nil) }
                                    .disabled(session == nil || draft.rows.count >= ReminderSpec.maximum).accessibilityIdentifier("addTeamReminder")
                                if draft.rows.count >= ReminderSpec.maximum { Text("This task has 20 reminder choices. Remove an editable one before adding another.").font(.footnote).foregroundStyle(.secondary) }
                            }
                            Section {
                                Text("These choices are shared with people who can read this task. Each device controls its own delivery. Device settings and private places stay separate.").font(.footnote).foregroundStyle(.secondary)
                            }
                            if let message { Section { Text(message).foregroundStyle(.red).accessibilityIdentifier("teamReminderMessage") } }
                            if let failure = session?.failure { Section { Text(failure).foregroundStyle(.red); Button("Retry preserving edit") { checkpoint(); _ = session?.flush() } } }
                            #if DEBUG
                            if TeamEditorNativeFixture.enabled {
                                Section { Button("Change test role to viewer") { store.revokeTeamEditorNativeFixture() }.accessibilityIdentifier("revokeTeamRemindersFixture") }
                            }
                            #endif
                        }
                    }.accessibilityIdentifier("teamRemindersForm")
                } else {
                    ScrollView { VStack(alignment: .leading, spacing: 16) {
                        Label("Reminder editing paused", systemImage: "lock.shield").font(.title2)
                        Text("Project access changed. Reopen this task’s current details before editing again.")
                        if session?.latest != nil { Text(recoveryStatus).accessibilityIdentifier("teamReminderRecoveryStatus") }
                        if let failure = session?.failure { Text(failure).foregroundStyle(.red); Button("Retry preserving edit") { checkpoint(); _ = session?.flush() } }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24) }.accessibilityIdentifier("teamRemindersPaused")
                }
            }
            .navigationTitle("Shared reminders")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(available ? "Cancel" : "Close") {
                        if available { if session?.finish() != false { finished = true; dismiss() } }
                        else { checkpoint(); if session == nil || session?.flush() == true { finished = true; dismiss() } }
                    }.disabled(editing != nil).accessibilityIdentifier("cancelTeamReminders")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        guard available, session != nil, editing == nil else { return }
                        if let failure = request.apply(draft.changed ? draft.value : draft.original) { message = failure; return }
                        finished = true; _ = session?.finish(); dismiss()
                    }.disabled(!available || !draft.supported || session == nil || editing != nil).accessibilityIdentifier("saveTeamReminders")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 420, idealHeight: 600)
        #endif
        .sheet(item: $editing) { opening in
            ReminderSpecEditor(draft: opening, context: ReminderSpecEditingContext(current: { available }, capture: { state in
                childState = state; checkpoint()
            }, closed: { childState = .null; checkpoint() }, preserve: { checkpoint(); _ = session?.flush() }, status: { recoveryStatus }, revokeFixture: fixtureRevoke)) { spec in
                guard available, request.teamDraft.workspace == opening.workspace else { return "Project access changed. Your reminder settings are kept privately." }
                do { try draft.save(spec, replacing: opening.index, opening: opening.originalRows); message = nil; return nil }
                catch { return error.localizedDescription }
            }
        }
        .onAppear {
            guard available, session == nil else { return }
            do { session = try store.beginEditorSession(request.record) }
            catch { message = "Your reminder draft cannot be protected. Close and reopen this editor." }
        }
        .onChange(of: draft) { _, _ in checkpoint() }
        .onChange(of: available) { _, value in if !value { checkpoint(); stopped = true; _ = session?.flush() } }
        .interactiveDismissDisabled(draft.changed || childState != .null || session?.failure != nil)
        .onDisappear {
            if !finished, !draft.changed && childState == .null, session?.failure == nil { _ = session?.finish(); finished = true }
            else { checkpoint() }
        }
    }
    private func begin(_ spec: ReminderSpec, index: Int?) {
        guard available, session != nil else { return }
        childState = .null
        editing = ReminderDraft(spec: spec, index: index, workspace: request.teamDraft.workspace, taskID: request.record.id, taskGeneration: request.record["task_generation"], wasPersisted: true, originalRows: draft.rows)
    }
}
