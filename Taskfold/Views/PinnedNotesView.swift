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
    @State private var session: UUID?
    private var available: Bool { store.workflowPreviewReady(request.workspace) && (session == nil || session == store.backend.reminderSessionIncarnation) }
    var body: some View {
        NavigationStack {
            Group {
                if !available {
                    ContentUnavailableView("Workspace changed", systemImage: "person.crop.circle", description: Text("Close this window and open your current pinned notes."))
                } else if let id = request.taskID { PinnedNoteDetail(taskID: id, binding: request.workspace, close: { dismiss() }) }
                else {
                    PinnedNotesLibrary(binding: request.workspace, session: session ?? store.backend.reminderSessionIncarnation, create: { creating = true }, close: { dismiss() })
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onAppear { if session == nil { session = store.backend.reminderSessionIncarnation } }
            .onChange(of: available) { _, readable in if !readable { creating = false } }
            .sheet(isPresented: $creating) { NewPinnedNote(binding: request.workspace) }
            .onChange(of: store.workspaceGeneration) { _, _ in creating = false; dismiss() }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 580, minHeight: 500)
        #endif
    }
}

private struct PinnedNotesLibrary: View {
    @Environment(Store.self) private var store
    let binding: WorkspaceBinding
    let session: UUID
    let create: () -> Void
    let close: () -> Void
    @State private var query = ""
    @State private var limit = PinnedNoteCatalog.pageSize
    @State private var catalog: PinnedNoteCatalog?
    @State private var loaded: Version?
    @State private var token: UUID?
    @State private var result: SearchResult?
    @State private var searching = false
    @State private var failure: String?
    @FocusState private var focused: Bool
    private struct Version: Equatable {
        let readable: Bool
        let tasks: [Record], pins: [Record], projects: [Record], sections: [Record]
    }
    private struct Key: Equatable { let token: UUID?; let query: String; let limit: Int }
    private struct SearchResult { let key: Key; let page: PinnedNoteCatalog.Page }
    private var readable: Bool { store.workflowPreviewReady(binding) && session == store.backend.reminderSessionIncarnation }
    private var version: Version { Version(readable: readable, tasks: readable ? store.tasks : [], pins: readable ? store.rows("view_orders") : [], projects: readable ? store.allProjects : [], sections: readable ? store.rows("sections") : []) }
    var body: some View {
        let input = version, key = Key(token: token, query: query, limit: limit)
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").font(.system(size: 20)).foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Find a note or project", text: $query).textFieldStyle(.plain).frame(minHeight: 44).focused($focused).onSubmit { focused = false }
                    .accessibilityLabel("Search pinned notes").accessibilityIdentifier("pinnedNotesSearch")
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    #endif
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(.borderless).accessibilityLabel("Clear search").accessibilityIdentifier("clearPinnedNotesSearch") }
            }.padding().background(.bar)
            List {
                Section {
                    Button("New pinned note", systemImage: "plus") { focused = false; query = ""; create() }.accessibilityIdentifier("newPinnedNote")
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text("Find instructions, checklists and ideas by their words or project. Completed tasks can keep their notes pinned.").font(.callout).foregroundStyle(.secondary) }
                }
                if loaded == input, let result, result.key.token == token, result.key.query == query {
                    if result.page.total == 0 {
                        ContentUnavailableView(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Keep a useful note close" : "No notes found", systemImage: "pin", description: Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Create a note here, or turn on Show notes in widgets in any task's details." : "Try another word from the note, task or project."))
                    } else {
                        Section("Your pinned notes") {
                            ForEach(result.page.options) { option in
                                NavigationLink {
                                    PinnedNoteLibraryDestination(option: option, binding: binding, session: session, close: close)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(option.title).font(.headline).lineLimit(2)
                                        Text(option.preview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                        Text(option.location).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                        if option.completed { Label("Task completed", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
                                    }.padding(.vertical, 6)
                                }.accessibilityIdentifier("pinnedNote-" + option.id).accessibilityLabel(option.title).accessibilityValue(option.location + ", " + option.preview + (option.completed ? ", Task completed" : ""))
                            }
                        }
                        if result.page.options.count < result.page.total {
                            Text("Showing \(result.page.options.count) of \(result.page.total) notes").font(.caption).foregroundStyle(.secondary)
                            Button("Show more") { limit += PinnedNoteCatalog.pageSize }.disabled(searching).accessibilityIdentifier("showMorePinnedNotes")
                        }
                    }
                    if searching { ProgressView("Searching notes…") }
                } else if let failure { Text(failure).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                else { ProgressView("Finding notes…") }
            }.accessibilityIdentifier("pinnedNotesLibrary")
        }
        .navigationTitle("Pinned notes")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close", action: close).accessibilityIdentifier("closePinnedNotes") }
            ToolbarItem(placement: .confirmationAction) { Button("Done") { focused = false }.accessibilityIdentifier("pinnedNotesKeyboardDone") }
        }
        .onChange(of: query) { _, _ in limit = PinnedNoteCatalog.pageSize }
        .task(id: input) {
            catalog = nil; loaded = nil; token = nil; result = nil; failure = nil
            guard readable else { query = ""; return }
            do {
                let value = try await PinnedNoteCatalog.load(tasks: input.tasks, pins: input.pins, projects: input.projects, sections: input.sections, account: store.userID)
                try Task.checkCancellation(); guard readable, input == version else { return }
                catalog = value; loaded = input; token = UUID()
            } catch is CancellationError { }
            catch { guard readable, input == version else { return }; failure = error.localizedDescription }
        }
        .task(id: key) {
            guard readable, let catalog, loaded == input, key.token != nil else { return }
            searching = true
            do {
                let page = try await catalog.search(query: key.query, limit: key.limit)
                try Task.checkCancellation(); guard readable, loaded == version, key == Key(token: token, query: query, limit: limit) else { return }
                result = SearchResult(key: key, page: page); searching = false
            } catch is CancellationError { }
            catch { guard key == Key(token: token, query: query, limit: limit) else { return }; searching = false; failure = error.localizedDescription }
        }
    }
}

private struct PinnedNoteLibraryDestination: View {
    @Environment(Store.self) private var store
    let option: PinnedNoteCatalog.Option
    let binding: WorkspaceBinding
    let session: UUID
    let close: () -> Void
    var body: some View {
        if store.workflowPreviewReady(binding), session == store.backend.reminderSessionIncarnation,
           PinnedNoteCatalog.current(option, tasks: store.tasks, pins: store.rows("view_orders"), account: store.userID) != nil {
            PinnedNoteDetail(taskID: option.id, binding: binding, close: close)
        } else {
            ContentUnavailableView("Note unavailable", systemImage: "pin.slash", description: Text("This note changed or is no longer available. Return to Pinned notes and choose its current entry.")).navigationTitle("Pinned note")
        }
    }
}

private struct PinnedNoteTextRequest: Identifiable {
    let format: NoteFormatRequest
    let session: UUID
    var id: UUID { format.id }
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
    @State private var editing: TaskEditorOpening?
    @State private var noteEditing: PinnedNoteTextRequest?
    @State private var failureTitle = "Could not unpin note"
    @State private var printReview: PrintReviewRequest?
    @State private var noteScrollID: String?
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
                            Text("Your note has no text yet. Add instructions or an idea with Edit note.").foregroundStyle(.secondary).accessibilityIdentifier("pinnedNoteBlank")
                        } else {
                            NoteMarkupPreview(text: task.string("description"), offersOriginalText: true, scrollToHeading: { noteScrollID = NoteMarkup.scrollID($0) })
                        }
                        Button(action: editText) { Label("Edit note", systemImage: "square.and.pencil").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }.accessibilityIdentifier("editPinnedNoteText")
                        Button {guard binding.matches(account:store.userID,generation:store.workspaceGeneration) else {return};editing=TaskEditorOpening(task:task,admission:store.editorAdmission(task,workspace:binding)) } label: { Label("Edit details", systemImage: "pencil").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }.accessibilityIdentifier("editPinnedNote")
                        Button("Print or export", systemImage: "printer") { preparePrint() }.accessibilityIdentifier("printPinnedNote")
                        Button(action: unpin) { Label("Unpin note", systemImage: "pin.slash").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }.accessibilityIdentifier("unpinNote")
                        Text("Unpinning keeps the task and its notes. Widgets show a shortened preview; this screen shows the full text.").font(.caption).foregroundStyle(.secondary)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }.scrollPosition(id: $noteScrollID, anchor: .top)
                    .accessibilityIdentifier("pinnedNoteReader")
            } else {
                ContentUnavailableView("Note unavailable", systemImage: "pin.slash", description: Text("This task was removed, unpinned, or belongs to a different workspace. Open Pinned notes to choose another."))
            }
        }.onChange(of: live.map { NoteMarkup.Source($0.string("description")) }) { _, _ in noteScrollID = nil }
            .navigationTitle("Pinned note")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", action: close).accessibilityIdentifier("closePinnedNotes") } }
            .sheet(item: $printReview) { PrintReviewView(request: $0) }
            .sheet(item: $noteEditing) { request in
                NoteFormattingView(request: request.format) { text in
                    guard let admission = request.format.admission else { return "Reopen the current note before saving. Your text is still here." }
                    var saved = false
                    #if os(macOS)
                    workspace.run("Edit Note") { saved = store.savePinnedNoteText(text, admission: admission, session: request.session) }
                    #else
                    saved = store.savePinnedNoteText(text, admission: admission, session: request.session)
                    #endif
                    if saved { return nil }
                    let message = store.error ?? "The note could not be saved. Your text is still here; try again."
                    store.error = nil
                    return message
                }
            }
            .sheet(item: $editing) { opening in
                #if os(iOS)
                TaskEditor(task:opening.task,admission:opening.admission)
                #else
                NavigationStack {
                    TaskInspectorForm(taskID: opening.task.id,admission:opening.admission).id(opening.id).navigationTitle("Task details")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { editing = nil } } }
                }.frame(minWidth: 460, idealWidth: 560, minHeight: 540)
                #endif
            }
            .alert(failureTitle, isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK") { failure = nil } } message: { Text(failure ?? "") }
            .onChange(of: store.workspaceGeneration) { _, _ in editing = nil }
    }
    private func editText() {
        guard let task = live else { return }
        let admission = store.editorAdmission(task, workspace: binding)
        guard admission.matches(account: store.userID, generation: store.workspaceGeneration, currentRoot: task),
              store.editorMayWrite(source: task, proposed: task, teamDraft: admission.teamDraft) else {
            failureTitle = "Could not edit note"; failure = "Reopen the current note with editing access."; return
        }
        let format = NoteFormatRequest(taskID: task.id, original: task.string("description"), workspace: binding,
            generation: task["task_generation"], storedText: task.string("description"), source: task, sourceRootID: task.id,
            admission: admission, title: "Edit note", confirmation: "Save", focusOnOpen: true)
        noteEditing = PinnedNoteTextRequest(format: format, session: store.backend.reminderSessionIncarnation)
    }
    private func preparePrint() {
        guard let task = live else { return }
        do {
            let document = try PrintDocument.capture(title: task.title, subtitle: "Pinned note", groups: [("", [task])], projects: [], labels: [], noteOnly: true)
            printReview = PrintReviewRequest(document: document, workspace: binding, isCurrent: { PrintDocument.matchesSource(live, task) })
        } catch { failureTitle = "Could not prepare document"; failure = error.localizedDescription }
    }
    private func unpin() {
        guard live != nil else { return }
        var saved = false
        #if os(macOS)
        workspace.run("Unpin Note") { saved = store.setPinnedNote(taskID, enabled: false) }
        #else
        saved = store.setPinnedNote(taskID, enabled: false)
        #endif
        if saved { dismiss() } else { failureTitle = "Could not unpin note"; failure = store.error ?? "Your note is still pinned. Try again after reopening Taskfold."; store.error = nil }
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
    @State private var formatting: NoteFormatRequest?
    private enum Field: Hashable { case title, text }
    @FocusState private var focusedField: Field?
    @State private var discard = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Note title", text: $title).focused($focusedField, equals: .title).accessibilityIdentifier("newNoteTitle")
                    TextField("Instructions or an idea", text: $text, axis: .vertical).lineLimit(6...16).focused($focusedField, equals: .text).accessibilityIdentifier("newNoteText")
                    Button("Format notes", systemImage: "textformat") { focusedField = nil; formatting = NoteFormatRequest(taskID: "new-pinned-note", original: text, workspace: binding, generation: .null, storedText: nil) }.accessibilityIdentifier("openNewNoteFormatting")
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
                .sheet(item: $formatting) { request in
                    NoteFormattingView(request: request) { value in
                        guard request.workspace.matches(account: store.userID, generation: store.workspaceGeneration), text == request.original else { return "The note or workspace changed. Your formatted draft is still here." }
                        text = value; return nil
                    }
                }
                .onChange(of: store.workspaceGeneration) { _, _ in formatting = nil; dismiss() }
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
