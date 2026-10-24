import SwiftUI

struct TeamTaskLabelsRequest: Identifiable {
    let id = UUID()
    let teamDraft: TeamTaskEditorDraft
    let record: Record
    let sourceIdentity: JSON
    let current: () -> Bool
    let apply: (JSON) -> String?
}

struct TeamTaskLabelsEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: TeamTaskLabelsRequest
    @State private var draft: TeamTaskLabelsDraft
    @State private var adding = ""
    @State private var message: String?
    @State private var session: TaskEditorSession?
    @State private var finished = false
    @State private var stopped = false
    @FocusState private var nameFocused: Bool
    init(request: TeamTaskLabelsRequest) {
        self.request = request; _draft = State(initialValue: TeamTaskLabelsDraft(request.record["labels"]))
    }
    private var available: Bool {
        !stopped && request.current() && store.editorMayWrite(source: request.teamDraft.source, proposed: request.teamDraft.source, teamDraft: request.teamDraft)
    }
    private var suggestions: [String] {
        guard available else { return [] }
        return TeamTaskLabelsDraft.suggestions(project: request.teamDraft.scope.project, roots: store.tasks)
            .filter { name in !draft.entries.contains { $0.value == name } && (adding.isEmpty || name.localizedStandardContains(adding)) }
    }
    private func checkpoint() {
        guard !finished, let session else { return }
        guard draft.changed || !adding.isEmpty else {
            if session.latest != nil, session.finish(), available {
                do { self.session = try store.beginEditorSession(request.record) }
                catch { message = "Your label draft cannot be protected. Close and reopen this editor."; self.session = nil }
            }
            return
        }
        var task = request.record; if draft.changed { task["labels"] = draft.value }
        session.capture(task, extras: ["source_identity": request.sourceIdentity, "team_label_source": draft.original, "unsubmitted_team_label": .string(adding)])
    }
    var body: some View {
        NavigationStack {
            Group {
                if available {
                    Form {
                        if let failure = session?.failure {
                            Section { Text(failure).foregroundStyle(.red); Button("Retry preserving edit") { checkpoint(); _ = session?.flush() } }
                        }
                        if !draft.supported {
                            Section { Label("These labels use a newer format", systemImage: "tag.slash"); Text("Your saved labels are preserved. Use a newer app version to edit them.").foregroundStyle(.secondary) }
                        } else {
                            Section {
                                if draft.entries.isEmpty { Text("No shared labels yet").foregroundStyle(.secondary) }
                                ForEach(draft.entries) { entry in
                                    HStack {
                                        Label(entry.name ?? "Saved label", systemImage: "tag")
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer()
                                        Button(role: .destructive) { draft.remove(entry.id) } label: { Image(systemName: "minus.circle").frame(minWidth: 44, minHeight: 44) }
                                            .buttonStyle(.borderless).accessibilityLabel("Remove " + (entry.name ?? "saved label"))
                                            .accessibilityIdentifier("removeTeamLabel-\(entry.id)")
                                    }
                                }
                            } header: { Text("On this task") } footer: {
                                Text("Shared labels belong to this task. Your personal label catalog is kept separate.")
                            }
                            Section("Add a label") {
                                TextField("Label name", text: $adding).focused($nameFocused).onSubmit(add)
                                    .accessibilityIdentifier("teamLabelName")
                                Button("Add label", systemImage: "plus", action: add).disabled(adding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session == nil)
                                    .accessibilityIdentifier("addTeamLabel")
                                if let message { Text(message).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("teamLabelMessage") }
                            }
                            if !suggestions.isEmpty {
                                Section("Used in this project") {
                                    ForEach(suggestions, id: \.self) { name in
                                        Button { adding = name; add() } label: { Label(name, systemImage: "plus.circle").fixedSize(horizontal: false, vertical: true) }
                                    }
                                }
                            }
                            #if DEBUG
                            if TeamEditorNativeFixture.enabled {
                                Section {
                                    Button("Change test role to viewer") { store.revokeTeamEditorNativeFixture() }.accessibilityIdentifier("revokeTeamLabelsFixture")
                                    if ProcessInfo.processInfo.arguments.contains("--team-label-testing") {
                                        Button("Change personal test labels") { store.changeTeamLabelCatalogFixture() }.accessibilityIdentifier("changePersonalTeamLabelFixture")
                                    }
                                }
                            }
                            #endif
                        }
                    }.accessibilityIdentifier("teamLabelsForm")
                } else {
                    ScrollView { VStack(alignment: .leading, spacing: 16) {
                        Label("Label editing paused", systemImage: "lock.shield").font(.title2)
                        Text("Project access changed. Reopen the task’s current details before editing again.")
                        if let session, session.latest != nil {
                            Text(session.preserved ? "Your label edit is saved privately with its original workspace. Open Backups & restore → Unsent task edits." : "Preserving your label edit…")
                                .accessibilityIdentifier("teamLabelRecoveryStatus")
                            if let failure = session.failure { Text(failure).foregroundStyle(.red); Button("Retry preserving edit") { checkpoint(); _ = session.flush() } }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24) }.accessibilityIdentifier("teamLabelsPaused")
                }
            }
            .navigationTitle("Shared labels")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(available ? "Cancel" : "Close") {
                        if available { if session?.finish() != false { finished = true; dismiss() } }
                        else { checkpoint(); if session?.latest == nil || session?.flush() == true { finished = true; dismiss() } }
                    }.accessibilityIdentifier("cancelTeamLabels")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        guard available, session != nil else { return }
                        if !adding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            do { try draft.add(adding); adding = ""; nameFocused = false; message = nil }
                            catch { message = error.localizedDescription; return }
                        }
                        if let failure = request.apply(draft.changed ? draft.value : draft.original) { message = failure; return }
                        finished = true; _ = session?.finish(); dismiss()
                    }.disabled(!available || !draft.supported || session == nil).accessibilityIdentifier("saveTeamLabels")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 500, minHeight: 400, idealHeight: 560)
        #endif
        .onAppear {
            guard available, session == nil else { return }
            do { session = try store.beginEditorSession(request.record) }
            catch { message = "Your label draft cannot be protected yet. Close and reopen this editor to retry." }
        }
        .onChange(of: draft) { _, _ in checkpoint() }
        .onChange(of: adding) { _, _ in checkpoint() }
        .onChange(of: available) { _, value in if !value { checkpoint(); stopped = true; nameFocused = false; _ = session?.flush() } }
        .onDisappear { checkpoint() }
    }
    private func add() {
        guard available, session != nil else { return }
        do { try draft.add(adding); adding = ""; message = nil; nameFocused = false }
        catch { message = error.localizedDescription }
    }
}
