import SwiftUI

struct SavedChildTaskFieldChangesLink: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var visible = false
    @State private var showing = false
    @State private var revision = UUID()
    private var scope: ChildTaskFieldClientScope? { phase == .active ? store.childTaskFieldRecoveryScope : nil }
    var body: some View {
        Group {
            if visible, scope != nil {
                Section { Button("Saved subtask changes", systemImage: "tray.and.arrow.up") { showing = true }.accessibilityIdentifier("savedChildFieldChanges") }
            }
        }
        .task(id: scope) { await discover() }
        .task(id: revision) { await discover() }
        .sheet(isPresented: $showing, onDismiss: { revision = UUID() }) {
            WorkflowShell(title: "Saved subtask changes") { ChildTaskFieldRecoveryView() }
        }
    }
    private func discover() async {
        visible = false; guard let captured = scope else { return }
        do {
            let journal = try store.childTaskFieldJournal(account: captured.account, origin: captured.origin)
            let saved = try await journal.load()
            guard scope == captured, !Task.isCancelled else { return }; visible = !saved.entries.isEmpty
        } catch { guard scope == captured, !Task.isCancelled else { return }; visible = true }
    }
}

private struct ChildFieldRemovalReview {
    let entry: ChildTaskFieldJournalState.Entry
    let model: ChildTaskFieldRecoveryModel
    let scope: ChildTaskFieldClientScope
}

struct ChildTaskFieldRecoveryView: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var model: ChildTaskFieldRecoveryModel?
    @State private var modelScope: ChildTaskFieldClientScope?
    @State private var failure: String?
    @State private var removing: ChildFieldRemovalReview?
    private var scope: ChildTaskFieldClientScope? { phase == .active ? store.childTaskFieldRecoveryScope : nil }
    var body: some View {
        List {
            Section { Text("Review saved changes. Retrying keeps the original request.").foregroundStyle(.secondary) }
            if let model, scope != nil, modelScope == scope {
                if let message = model.message { Section { Text(message).accessibilityIdentifier("childFieldRecoveryStatus") } }
                if model.loaded, model.entries.isEmpty { ContentUnavailableView("No saved changes", systemImage: "checkmark.circle", description: Text("Subtask requests you save will appear here.")) }
                ForEach(model.entries, id: \.command.id) { entry in
                    Section {
                        Label(status(entry.phase), systemImage: entry.phase == .confirmed ? "checkmark.circle" : entry.phase == .attempted ? "clock.badge.questionmark" : "tray")
                            .font(.headline).accessibilityIdentifier("childFieldPhase-" + entry.command.id)
                        ForEach(entry.command.body["changes"]!.object.keys.sorted(), id: \.self) { field in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(field.replacingOccurrences(of: "_", with: " ").capitalized).font(.caption).foregroundStyle(.secondary)
                                Text(render(entry.command.body["changes"]!.object[field]!)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if entry.phase != .confirmed {
                            Button(entry.phase == .attempted ? "Retry original request" : "Send saved change", systemImage: "arrow.up.circle") { Task { await model.send(entry.command) } }
                                .disabled(model.busy || !store.permitsChildTaskFieldRequest(entry.command, sending: true))
                                .accessibilityIdentifier("sendChildField-" + entry.command.id)
                            if !store.permitsChildTaskFieldRequest(entry.command, sending: true) {
                                Text("Sending requires a connection, current editing access and no pending parent-task save.").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Button(entry.phase == .confirmed ? "Remove saved receipt" : "Discard saved request", role: .destructive) { if let scope { removing = ChildFieldRemovalReview(entry: entry, model: model, scope: scope) } }
                            .disabled(model.busy).accessibilityIdentifier("discardChildField-" + entry.command.id)
                    }
                }
                if !model.loaded, !model.busy { Section { Button("Read saved requests again") { Task { await model.load() } } } }
                if model.busy { ProgressView("Updating saved requests…") }
            } else if let failure { Section { Text(failure).foregroundStyle(.secondary) } }
            else if scope == nil { ContentUnavailableView("Open your workspace", systemImage: "lock.shield", description: Text("Saved requests belong to their original account.")) }
            else { ProgressView("Reading saved changes…") }
        }
        .task(id: scope) {
            model?.close(); model = nil; modelScope = nil; failure = nil; removing = nil
            guard scope != nil else { return }
            do { let value = try store.childTaskFieldRecoveryModel(); modelScope = scope; model = value; await value.load() }
            catch { failure = error.localizedDescription }
        }
        .onChange(of: scope) { _, _ in removing = nil }
        .onDisappear { removing = nil; model?.close() }
        .alert("Remove this saved request?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let removing {
                Button(removing.entry.phase == .attempted ? "Discard unconfirmed request" : "Remove from this device", role: .destructive) {
                    let review = removing; self.removing = nil
                    guard scope == review.scope, modelScope == review.scope, model === review.model else { return }
                    Task { await review.model.discard(review.entry.command, uncertainConfirmed: review.entry.phase == .attempted) }
                }
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text(removing?.entry.phase == .attempted ? "The server may already have applied this change. Removing its recovery request cannot cancel or undo it. Refresh current tasks before editing again." : "This removes only the saved request or receipt on this device. It does not undo a server change.")
        }
    }
    private func status(_ phase: ChildTaskFieldJournalState.Phase) -> String {
        switch phase { case .queued: return "Saved · not sent"; case .attempted: return "Unconfirmed · original request kept"; case .confirmed: return "Confirmed · receipt saved" }
    }
    private func render(_ value: JSON) -> String {
        if case .string(let text) = value { return text.isEmpty ? "Empty" : text }
        if value == .null { return "Cleared" }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "Saved value"
    }
}

struct ChildTaskFieldEditorLink: View {
    let rootID: String
    @Environment(Store.self) private var store
    @State private var showing = false
    var body: some View {
        if store.childTaskFieldEditingEnabled, store.childTaskFieldRecoveryScope != nil, store.record("tasks", id: rootID) != nil {
            Button("Edit saved subtask fields", systemImage: "square.and.pencil") { showing = true }
                .accessibilityIdentifier("editIndependentChildFields")
                .sheet(isPresented: $showing) { WorkflowShell(title: "Subtask changes") { ChildTaskFieldEditorView(rootID: rootID) } }
        }
    }
}

private struct ChildFieldReadRequest: Hashable { let scope: ChildTaskFieldClientScope?; let retry: UUID }

/// Starts from verified saved server data, independent of the parent's draft.
/// Saving here checkpoints intent; sending is a separate reviewed action.
struct ChildTaskFieldEditorView: View {
    private enum Field: Hashable { case title, notes }
    @FocusState private var editingField: Field?
    @AccessibilityFocusState private var savedNoticeFocused: Bool
    let rootID: String
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var read: ChildTaskRecordRead?
    @State private var model: ChildTaskFieldRecoveryModel?
    @State private var failure: String?
    @State private var key = ""
    @State private var title = ""
    @State private var notes = ""
    @State private var priority = 4
    @State private var recovery = false
    @State private var reload = UUID()
    @State private var draftSession: TaskEditorSession?
    @State private var draftIdentity: JSON = .null
    @State private var selectedKey = ""
    @State private var draftSessions: [String: TaskEditorSession] = [:]
    @State private var draftValues: [String: Record] = [:]
    private var scope: ChildTaskFieldClientScope? { store.childTaskFieldRecoveryScope }
    private var sourceAvailable: Bool {
        guard let read, ChildTaskFieldClientScope(read.context) == scope,
              let current = store.record("tasks", id: rootID) else { return false }
        return current["task_generation"] == read.context.root["task_generation"] && current["project_id"] == read.context.root["project_id"]
    }
    private var changes: [String: JSON] {
        guard let node = read?.nodes[key] else { return [:] }; var fields: [String: JSON] = [:]
        if !title.utf8.elementsEqual(node.fields["title"]?.text.utf8 ?? "".utf8) { fields["title"] = .string(title) }
        if !notes.utf8.elementsEqual(node.fields["description"]?.text.utf8 ?? "".utf8) { fields["description"] = .string(notes) }
        if priority != Record(node.fields).priority { fields["priority"] = .number(Double(priority)) }; return fields
    }
    var body: some View {
        ScrollViewReader { proxy in
        Form {
            Section { Text("Save a subtask change, then review and send it.").foregroundStyle(.secondary) }
            if let failure { Section { Text(failure).foregroundStyle(.secondary); Button("Read current subtasks again") { reload = UUID() } } }
            if let read, let model, sourceAvailable {
                if read.nodes.isEmpty { ContentUnavailableView("No saved subtasks", systemImage: "list.bullet") }
                else {
                    Section {
                        Picker("Subtask", selection: $key) {
                            ForEach(read.orderedNodes, id: \.key) { node in
                                let title = node.fields["title"]?.text ?? "Subtask"
                                Text(String(repeating: "  ", count: node.path.count - 1) + title)
                                    .accessibilityLabel(node.path.count > 1 ? "\(title), nested level \(node.path.count)" : title)
                                    .tag(node.key)
                            }
                        }.accessibilityIdentifier("independentChildSelection")
                        TextField("Title", text: Binding(get: { title }, set: { guard !title.utf8.elementsEqual($0.utf8) else { return }; title = $0; checkpoint(reopen: true) }), axis: .vertical).focused($editingField, equals: .title).accessibilityIdentifier("independentChildTitle")
                        TextField("Notes", text: Binding(get: { notes }, set: { guard !notes.utf8.elementsEqual($0.utf8) else { return }; notes = $0; checkpoint(reopen: true) }), axis: .vertical).lineLimit(3...12).focused($editingField, equals: .notes).accessibilityIdentifier("independentChildNotes")
                        Picker("Priority", selection: Binding(get: { priority }, set: { guard priority != $0 else { return }; priority = $0; checkpoint(reopen: true) })) { ForEach(1...4, id: \.self) { Text("Priority \($0)").tag($0) } }
                        Text("Unsent text is preserved privately in Backups & restore → Unsent task edits. Other fields and checklist structure stay as saved.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Section {
                        Button("Save on this device", systemImage: "tray.and.arrow.down") {
                            do {
                                let command = try ChildTaskFieldCommand(read: read, key: key, changes: changes)
                                let session = draftSession, revision = session?.latest?.revision, captured = scope
                                savedNoticeFocused = false
                                Task {
                                    guard let saved = await model.save(command) else { return }
                                    let unchanged = session?.latest?.revision == revision
                                    _ = session?.finish(ifRevision: revision)
                                    guard unchanged, selectedKey == saved.body["node_key"]?.text, scope == captured, appeared, phase == .active, !recovery else { return }
                                    let keyboardWasFocused = editingField != nil
                                    editingField = nil
                                    #if os(iOS)
                                    // A centered iPad sheet changes its viewport during
                                    // keyboard dismissal. Reveal against its settled size.
                                    if keyboardWasFocused { try? await Task.sleep(nanoseconds: 400_000_000) }
                                    #endif
                                    await Task.yield()
                                    guard draftSession === session, scope == captured, appeared, phase == .active, !recovery else { return }
                                    if reduceMotion { proxy.scrollTo("childFieldSavedNotice", anchor: .bottom) }
                                    else { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("childFieldSavedNotice", anchor: .bottom) } }
                                    await Task.yield()
                                    guard draftSession === session, scope == captured, selectedKey == saved.body["node_key"]?.text, appeared, phase == .active, !recovery else { return }; savedNoticeFocused = true
                                }
                            }
                            catch { failure = error.localizedDescription }
                        }.disabled(changes.isEmpty || model.busy).accessibilityIdentifier("saveIndependentChildFields")
                        Button("Review saved changes", systemImage: "tray.and.arrow.up") { recovery = true }
                        if let message = model.message { Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).id("childFieldSavedNotice").accessibilityIdentifier("independentChildSaveStatus").accessibilityFocused($savedNoticeFocused) }
                    }
                }
            } else if read != nil {
                ContentUnavailableView("Editing paused", systemImage: "lock.shield", description: Text("This task or workspace changed. Unsent text is kept privately with its original workspace."))
                if scope != nil { Button("Review saved changes") { recovery = true } }
            } else if failure == nil { ProgressView("Reading saved subtasks…") }
        }
        #if os(iOS)
        .accessibilityIdentifier("childFieldEditorForm")
        #endif
        .onAppear { appeared = true }
        .privacySensitive()
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: key) { _, _ in select() }
        .onChange(of: sourceAvailable) { _, value in if !value { checkpoint(); _ = draftSession?.flush() } }
        .onChange(of: phase) { _, value in if value != .active { checkpoint(); _ = draftSession?.flush() } }
        .task(id: ChildFieldReadRequest(scope: scope, retry: reload)) {
            checkpoint(); for session in draftSessions.values { _ = session.flush() }; draftSession = nil; draftSessions = [:]; draftValues = [:]; selectedKey = ""
            model?.close(); model = nil; read = nil; title = ""; notes = ""; key = ""; failure = nil
            guard let captured = scope else { return }
            do {
                guard store.childTaskFieldEditingEnabled else { throw ChildTaskFieldWriteFailure(reason: .unavailable) }
                let value = try await store.readChildTaskRecords(rootID)
                guard captured == scope, !Task.isCancelled else { return }
                read = value; model = try store.childTaskFieldRecoveryModel(); key = value.orderedNodes.first?.key ?? ""; select()
            } catch { guard captured == scope, !Task.isCancelled else { return }; failure = error.localizedDescription }
        }
        .onDisappear { appeared = false; checkpoint(); _ = draftSession?.flush() }
        .sheet(isPresented: $recovery) { WorkflowShell(title: "Saved subtask changes") { ChildTaskFieldRecoveryView() } }
        }
    }
    private func select() {
        checkpoint()
        if draftSession?.flush() == false { key = selectedKey; failure = draftSession?.failure; return }
        guard let node = read?.nodes[key], let read else { return }
        selectedKey = key
        let draft = draftValues[key] ?? Record(node.fields)
        title = draft.title; notes = draft["description"].text; priority = draft.priority; failure = nil
        draftIdentity = .object(["root": .string(read.context.root.id), "generation": read.context.root["task_generation"], "project": read.context.root["project_id"], "node": .string(node.key), "incarnation": .string(node.incarnation), "revision": .number(node.revision)])
        do {
            draftSession = try draftSessions[key] ?? store.beginEditorSession(Record(node.fields))
            draftSessions[key] = draftSession
        } catch { failure = error.localizedDescription }
    }
    private func checkpoint(reopen: Bool = false) {
        guard let read, let node = read.nodes[selectedKey] else { return }
        if draftSession?.closed == true {
            guard reopen, ChildTaskFieldClientScope(read.context) == scope else { return }
            do { draftSession = try store.beginEditorSession(Record(node.fields)); draftSessions[selectedKey] = draftSession }
            catch { failure = error.localizedDescription; return }
        }
        guard let session = draftSession else { return }
        var draft = session.original; draft["title"] = .string(title); draft["description"] = .string(notes); draft["priority"] = .number(Double(priority))
        draftValues[selectedKey] = draft
        guard session.latest != nil || !title.utf8.elementsEqual(session.original.title.utf8) || !notes.utf8.elementsEqual(session.original["description"].text.utf8) || priority != session.original.priority else { return }
        session.capture(draft, extras: ["independent_child_fields": draftIdentity])
    }
}
