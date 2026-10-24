import SwiftUI

struct TeamTaskAssigneeRequest: Identifiable {
    let id = UUID()
    let draft: TeamTaskEditorDraft
    let selected: Binding<String>
    let current: () -> Bool
    let choose: (TeamTaskRecipientCatalog.Person?) -> String?
}

struct TeamTaskAssigneePicker: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: TeamTaskAssigneeRequest
    @State private var picker: TeamTaskRecipientPicker?
    @State private var search = ""
    private var available: Bool {
        request.current() && store.editorMayWrite(source: request.draft.source, proposed: request.draft.source, teamDraft: request.draft)
    }
    private var people: [TeamTaskRecipientCatalog.Person] {
        (picker?.catalog?.people ?? []).filter {
            $0.id != request.draft.scope.account && (search.isEmpty || ($0.displayName ?? "Team member").localizedStandardContains(search))
        }.sorted {
            let comparison = ($0.displayName ?? "Team member").localizedStandardCompare($1.displayName ?? "Team member")
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
    var body: some View {
        NavigationStack {
            Group {
                if available {
                    List {
                        Section {
                            choice(nil, id: "", title: "Unassigned", detail: nil)
                            if search.isEmpty || "You".localizedStandardContains(search) {
                                choice(.init(id: request.draft.scope.account, role: request.draft.role, displayName: nil), id: request.draft.scope.account, title: "You", detail: nil)
                            }
                            ForEach(people) { person in
                                choice(person, id: person.id, title: person.displayName ?? "Team member", detail: person.role == .manager ? "Project manager" : "Project editor")
                            }
                        } footer: {
                            Text("Only teammates with editing access to this project appear here.")
                            #if os(iOS)
                            Text("Your choice stays in the task draft until you save.")
                            #else
                            Text("Your choice saves with the task.")
                            #endif
                        }
                        if picker?.loading == true { ProgressView("Finding teammates…").accessibilityIdentifier("teamAssigneeLoading") }
                        if picker?.applying == true { ProgressView("Checking assignment…") }
                        if let message = picker?.message {
                            Section {
                                Text(message).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("teamAssigneeMessage")
                                Button("Refresh choices") { Task { await picker?.refresh() } }.disabled(picker?.applying == true).accessibilityIdentifier("refreshTeamAssignees")
                            }
                        }
                        #if DEBUG
                        if TeamEditorNativeFixture.enabled {
                            Section {
                                Button("Remove test recipient") { TeamEditorNativeFixture.removeRecipient() }.accessibilityIdentifier("removeTeamRecipientFixture")
                            }
                        }
                        #endif
                    }.accessibilityIdentifier("teamAssigneeList")
                        .searchable(text: $search, prompt: "Find a teammate")
                } else {
                    ContentUnavailableView {
                        Label("Assignment paused", systemImage: "lock.shield")
                    } description: {
                        Text("Project access changed. Close this picker and reopen the task before assigning it.")
                    }.accessibilityIdentifier("teamAssigneePaused")
                }
            }
            .navigationTitle("Assign task")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("cancelTeamAssignee") }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 360, idealHeight: 520)
        #endif
        .task {
            guard picker == nil else { return }
            let model = TeamTaskRecipientPicker(draft: request.draft, current: { available }, read: { try await store.backend.teamTaskRecipients(request.draft) }, apply: request.choose)
            picker = model; await model.refresh()
        }
        .onChange(of: available) { _, value in if !value { picker?.invalidate() } }
        .onDisappear { picker?.invalidate() }
    }
    private func choice(_ person: TeamTaskRecipientCatalog.Person?, id: String, title: String, detail: String?) -> some View {
        Button {
            guard let picker else { return }
            Task { if await picker.choose(id.isEmpty ? nil : id) { dismiss() } }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: person == nil ? "person.crop.circle.badge.minus" : "person.crop.circle.fill")
                    .font(.title2).foregroundStyle(.secondary).frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if request.selected.wrappedValue == id { Image(systemName: "checkmark").foregroundStyle(Color.taskfold) }
            }.frame(minHeight: 44).contentShape(.rect)
        }.buttonStyle(.plain)
            .disabled(picker == nil || picker?.applying == true)
            .accessibilityIdentifier("teamAssignee-" + (id.isEmpty ? "unassigned" : id))
            .accessibilityAddTraits(request.selected.wrappedValue == id ? [.isSelected] : [])
    }
}
