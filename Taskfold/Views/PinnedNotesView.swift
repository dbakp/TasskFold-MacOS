import SwiftUI

private struct PinnedNotesActionKey: EnvironmentKey { static let defaultValue: () -> Void = {} }
extension EnvironmentValues {
    var openPinnedNotes: () -> Void {
        get { self[PinnedNotesActionKey.self] }
        set { self[PinnedNotesActionKey.self] = newValue }
    }
}

struct PinnedNotesView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: PinnedNoteRequest
    @State private var creating = false
    private var available: Bool { request.workspace.matches(account: store.userID, generation: store.workspaceGeneration) }
    var body: some View {
        NavigationStack {
            Group {
                if !available {
                    ContentUnavailableView("Workspace changed", systemImage: "person.crop.circle", description: Text("Close this window and open your current pinned notes."))
                } else if let id = request.taskID { PinnedNoteDetail(taskID: id, binding: request.workspace, close: { dismiss() }) }
                else {
                    List {
                        Section {
                            Text("Instructions, a checklist, or an idea worth keeping close. Pins use your task notes and stay available after completion.").font(.callout).foregroundStyle(.secondary)
                            Button("New pinned note", systemImage: "plus") { creating = true }.accessibilityIdentifier("newPinnedNote")
                        }
                        let notes = PinnedNotes.tasks(store.tasks, pins: store.rows("view_orders"), account: store.userID)
                        if notes.isEmpty {
                            ContentUnavailableView("Keep a useful note close", systemImage: "pin", description: Text("Create a note here, or turn on Show notes in widgets in any task's details."))
                        } else {
                            Section("Your pinned notes") {
                                ForEach(notes) { task in
                                    NavigationLink { PinnedNoteDetail(taskID: task.id, binding: request.workspace, close: { dismiss() }) } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(task.title).font(.headline).lineLimit(2)
                                            Text(task.string("description").isEmpty ? "Add note text in task details" : task.string("description")).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                            if task.completed { Label("Task completed", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
                                        }.padding(.vertical, 6)
                                    }.accessibilityIdentifier("pinnedNote-" + task.id)
                                }
                            }
                        }
                    }.navigationTitle("Pinned notes")
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { if request.taskID == nil { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.accessibilityIdentifier("closePinnedNotes") } } }
            .sheet(isPresented: $creating) { NewPinnedNote(binding: request.workspace) }
            .onChange(of: store.workspaceGeneration) { _, _ in creating = false; dismiss() }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 580, minHeight: 500)
        #endif
    }
}

private struct PinnedNoteDetail: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(Workspace.self) private var workspace
    #endif
    let taskID: String
    let binding: WorkspaceBinding
    let close: () -> Void
    @State private var failure: String?
    @State private var editing: Record?
    private var live: Record? {
        binding.matches(account: store.userID, generation: store.workspaceGeneration) && store.isPinnedNote(taskID) ? store.record("tasks", id: taskID) : nil
    }
    var body: some View {
        Group {
            if let task = live {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Label("PINNED NOTE", systemImage: "pin.fill").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(Color.taskfold)
                        Text(task.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("pinnedNoteTitle")
                        if task.completed { Label("Task completed · note still pinned", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary) }
                        if task.string("description").isEmpty {
                            Text("Your note has no text yet. Add instructions or an idea in task details.").foregroundStyle(.secondary).accessibilityIdentifier("pinnedNoteBlank")
                        } else {
                            Text(task.string("description")).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("pinnedNoteText")
                        }
                        Button { editing = task } label: { Label("Edit details", systemImage: "pencil").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }.accessibilityIdentifier("editPinnedNote")
                        Button(action: unpin) { Label("Unpin note", systemImage: "pin.slash").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }.accessibilityIdentifier("unpinNote")
                        Text("Unpinning keeps the task and its notes. Widgets show a shortened preview; this screen shows the full text.").font(.caption).foregroundStyle(.secondary)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Note unavailable", systemImage: "pin.slash", description: Text("This task was removed, unpinned, or belongs to a different workspace. Open Pinned notes to choose another."))
            }
        }.navigationTitle("Pinned note")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: close).accessibilityIdentifier("closePinnedNotes") } }
            .sheet(item: $editing) { task in
                #if os(iOS)
                TaskEditor(task: task)
                #else
                NavigationStack {
                    TaskInspectorForm(taskID: task.id).id(task.id).navigationTitle("Task details")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { editing = nil } } }
                }.frame(minWidth: 460, idealWidth: 560, minHeight: 540)
                #endif
            }
            .alert("Could not unpin note", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK") { failure = nil } } message: { Text(failure ?? "") }
            .onChange(of: store.workspaceGeneration) { _, _ in editing = nil }
    }
    private func unpin() {
        guard live != nil else { return }
        var saved = false
        #if os(macOS)
        workspace.run("Unpin Note") { saved = store.setPinnedNote(taskID, enabled: false) }
        #else
        saved = store.setPinnedNote(taskID, enabled: false)
        #endif
        if saved { dismiss() } else { failure = store.error ?? "Your note is still pinned. Try again after reopening Taskfold."; store.error = nil }
    }
}

/// Creation writes the task and pin as one durable, undoable local change.
private struct NewPinnedNote: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(Workspace.self) private var workspace
    #endif
    let binding: WorkspaceBinding
    @State private var title = ""
    @State private var text = ""
    @State private var discard = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Note title", text: $title).accessibilityIdentifier("newNoteTitle")
                    TextField("Instructions or an idea", text: $text, axis: .vertical).lineLimit(6...16).accessibilityIdentifier("newNoteText")
                }
                Section { Text("Creates a task in Inbox with its notes pinned. Only pin text you want visible on your Home Screen or desktop. Add a Pinned note widget and choose this note.").font(.callout).foregroundStyle(.secondary) }
            }.navigationTitle("New pinned note")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if title.isEmpty && text.isEmpty { dismiss() } else { discard = true } } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("savePinnedNote") }
                }
                .interactiveDismissDisabled(!title.isEmpty || !text.isEmpty)
                .confirmationDialog("Discard your changes?", isPresented: $discard, titleVisibility: .visible) { Button("Discard changes", role: .destructive) { dismiss() } }
                .alert("Could not save note", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK") { failure = nil } } message: { Text(failure ?? "") }
                .onChange(of: store.workspaceGeneration) { _, _ in dismiss() }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 560, minHeight: 440)
        #endif
    }
    private func save() {
        guard binding.matches(account: store.userID, generation: store.workspaceGeneration) else { failure = "The workspace changed. Open your current pinned notes."; return }
        var task = Record.task(user: store.userID)
        task["title"] = .string(title.trimmingCharacters(in: .whitespacesAndNewlines)); task["description"] = .string(text)
        var saved = false
        #if os(macOS)
        workspace.run("Create Pinned Note") { saved = store.saveTaskWithNotePin(task, pin: true) }
        #else
        saved = store.saveTaskWithNotePin(task, pin: true)
        #endif
        if saved { dismiss() } else { failure = store.error ?? "Your note could not be saved. Your text is still here."; store.error = nil }
    }
}
