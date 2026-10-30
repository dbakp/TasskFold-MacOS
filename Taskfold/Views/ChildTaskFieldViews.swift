import SwiftUI
import Observation
#if os(iOS)
import UIKit
#endif

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

/// SwiftUI List flattens section rows; a field name alone is not a unique
/// identity when several saved requests change the same field.
private struct ChildFieldReviewItem: Identifiable {
    let request: String
    let field: String
    var id: String { request + "-" + field }
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
    @State private var comparing: ChildTaskFieldCommand?
    @State private var reload = UUID()
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
                        ForEach(entry.command.body["changes"]!.object.keys.sorted().map { ChildFieldReviewItem(request: entry.command.id, field: $0) }) { item in
                            let field = item.field
                            VStack(alignment: .leading, spacing: 4) {
                                Text(fieldTitle(field)).font(.caption).foregroundStyle(.secondary)
                                if field == "assigned_to" {
                                    ChildFieldAssigneeReview(command: entry.command)
                                } else {
                                    Text(render(field, entry.command.body["changes"]!.object[field]!, command: entry.command)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                        .accessibilityIdentifier("childFieldValue-" + item.id)
                                }
                            }.id(item.id)
                        }
                        if entry.phase != .confirmed && entry.phase != .closed {
                            Button(entry.phase == .attempted ? "Retry original request" : "Send saved change", systemImage: "arrow.up.circle") { Task { await model.send(entry.command) } }
                                .disabled(model.busy || !store.permitsChildTaskFieldRequest(entry.command, sending: true))
                                .accessibilityIdentifier("sendChildField-" + entry.command.id)
                            if !store.permitsChildTaskFieldRequest(entry.command, sending: true) {
                                Text("Sending requires a connection, current editing access and no pending parent-task save.").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        if entry.phase != .confirmed {
                            Button("Compare with current values", systemImage: "arrow.left.arrow.right") { comparing = entry.command }
                                .disabled(model.busy).accessibilityIdentifier("compareChildField-" + entry.command.id)
                        }
                        Button(entry.phase == .confirmed ? "Remove saved receipt" : entry.phase == .closed ? "Remove closed request" : "Discard saved request", role: .destructive) { if let scope { removing = ChildFieldRemovalReview(entry: entry, model: model, scope: scope) } }
                            .disabled(model.busy).accessibilityIdentifier("discardChildField-" + entry.command.id)
                    }
                }
                if !model.loaded, !model.busy { Section { Button("Read saved requests again") { Task { await model.load() } } } }
                if model.busy { ProgressView("Updating saved requests…") }
            } else if let failure { Section { Text(failure).foregroundStyle(.secondary) } }
            else if scope == nil { ContentUnavailableView("Open your workspace", systemImage: "lock.shield", description: Text("Saved requests belong to their original account.")) }
            else { ProgressView("Reading saved changes…") }
        }
        .task(id: ChildFieldReadRequest(scope: scope, retry: reload)) {
            model?.close(); model = nil; modelScope = nil; failure = nil; removing = nil; comparing = nil
            guard scope != nil else { return }
            do { let value = try store.childTaskFieldRecoveryModel(); modelScope = scope; model = value; await value.load() }
            catch { failure = error.localizedDescription }
        }
        .onChange(of: scope) { _, _ in removing = nil; comparing = nil }
        .onDisappear { removing = nil; model?.close() }
        .sheet(isPresented: Binding(get: { comparing != nil }, set: { if !$0 { comparing = nil } }), onDismiss: { reload = UUID() }) {
            if let comparing, let scope { ChildFieldConflictReview(command: comparing, captured: scope) }
        }
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
        switch phase { case .queued: return "Saved · not sent"; case .attempted: return "Unconfirmed · original request kept"; case .confirmed: return "Confirmed · receipt saved"; case .closed: return "Closed · original request cannot send" }
    }
    private func fieldTitle(_ key: String) -> String {
        ["title": "Title", "description": "Notes", "priority": "Priority", "due_date": "Planned date", "due_time": "Planned time", "deadline_date": "Deadline", "duration_minutes": "Time estimate", "time_zone": "Time zone", "scheduled_at": "Exact time", "assigned_to": "Assigned to", "labels": "Labels", "reminder_specs": "Reminders"][key] ?? "Saved value"
    }
    private func render(_ field: String, _ value: JSON, command: ChildTaskFieldCommand) -> String {
        if field == "labels", case .array(let rows) = value {
            guard !rows.isEmpty else { return "No labels" }
            let root = store.record("tasks", id: command.body["task_id"]!.text)
            let personal = root.map { TeamTaskLabelsDraft.usesPersonalCatalog($0, cache: store.nativeConversationTeamCache) } ?? false
            return rows.map { item in
                if personal, let label = store.labels.first(where: { $0.id == item.text }), !label.name.isEmpty { return label.name }
                return TeamTaskLabelsDraft.displayName(item.text) ?? "Unavailable saved label"
            }.joined(separator: "\n")
        }
        if field == "reminder_specs" { return ChildTaskRemindersDraft.summary(value) }
        if value == .null { return "Cleared" }
        if field == "duration_minutes", case .number(let minutes) = value { return "\(Int(minutes)) min" }
        if field == "priority", case .number(let priority) = value { return priority == 4 ? "None" : "Priority \(Int(priority))" }
        if ["due_date", "deadline_date"].contains(field), case .string(let day) = value, let date = Dates.parse(day) {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        if field == "scheduled_at", case .string(let timestamp) = value, let date = TaskPlanning.instant(timestamp) {
            let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateStyle = .medium; formatter.timeStyle = .short
            return formatter.string(from: date) + " UTC"
        }
        if case .string(let text) = value { return text.isEmpty ? "Empty" : text }
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
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

@MainActor @Observable private final class ChildReminderPresentation {
    let id = UUID()
    private(set) var active = true
    func close(_ reason: String) {
        guard active else { return }; active = false
        #if DEBUG
        ChildFieldNativeIdentity.recordPresentationClose(id, reason: reason)
        #endif
    }
}
@MainActor @Observable private final class ChildReminderOwnership {
    private(set) var current: ChildReminderPresentation?
    var active: Bool { current?.active == true }
    func begin() -> ChildReminderPresentation {
        close("replacement"); let value = ChildReminderPresentation(); current = value; return value
    }
    func close(_ reason: String) { current?.close(reason); current = nil }
}

private struct ChildFieldReadRequest: Hashable { let scope: ChildTaskFieldClientScope?; let retry: UUID }

private struct ChildFieldNoticeRequest: Equatable {
    let ticket = UUID()
    let scope: ChildTaskFieldClientScope
    let key: String
    let session: UUID?
    let revision: UUID
}

/// Starts from verified saved server data, independent of the parent's draft.
/// Saving here checkpoints intent; sending is a separate reviewed action.
struct ChildTaskFieldEditorView: View {
    private enum Field: Hashable { case title, notes, label }
    @FocusState private var editingField: Field?
    @AccessibilityFocusState private var savedNoticeFocused: Bool
    let rootID: String
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var editingRevision = UUID()
    @State private var noticeRequest: ChildFieldNoticeRequest?
    @State private var messageKey: String?
    @State private var noticeBounds = CGRect.zero
    @State private var viewportBounds = CGRect.zero
    @State private var read: ChildTaskRecordRead?
    @State private var model: ChildTaskFieldRecoveryModel?
    @State private var failure: String?
    @State private var key = ""
    @State private var title = ""
    @State private var notes = ""
    @State private var priority = 4
    @State private var planning = ChildTaskPlanningDraft(original: Record())
    @State private var labels = ChildTaskLabelsDraft(original: Record(), kind: .personal)
    @State private var addingLabel = ""
    @State private var labelMessage: String?
    @State private var labelInputs: [String: String] = [:]
    @State private var assignment = ChildTaskAssignmentDraft(original: Record())
    @State private var chosenAssigneeID = ""
    @State private var chosenAssigneeName: String?
    @State private var sharedAssignee: TeamTaskAssigneeRequest?
    @State private var personalAssignee: ChildPersonalAssigneeRequest?
    @State private var reminders = ChildTaskRemindersDraft(original: Record())
    @State private var reminderEditor: TeamTaskRemindersRequest?
    @State private var reminderOwnership = ChildReminderOwnership()
    @State private var choosingChild = false
    @State private var hierarchy = false
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
    private var selectionValue: String {
        guard let node = read?.nodes[key] else { return "Subtask" }
        let name = node.fields["title"]?.text ?? "Subtask"
        return node.path.count > 1 ? "\(name), nested level \(node.path.count)" : name
    }
    private var changes: [String: JSON] {
        guard let node = read?.nodes[key] else { return [:] }; var fields: [String: JSON] = [:]
        if !title.utf8.elementsEqual(node.fields["title"]?.text.utf8 ?? "".utf8) { fields["title"] = .string(title) }
        if !notes.utf8.elementsEqual(node.fields["description"]?.text.utf8 ?? "".utf8) { fields["description"] = .string(notes) }
        if priority != Record(node.fields).priority { fields["priority"] = .number(Double(priority)) }
        fields.merge(planning.changes) { _, new in new }; fields.merge(labels.changes) { _, new in new }; fields.merge(assignment.changes) { _, new in new }; fields.merge(reminders.changes) { _, new in new }; return fields
    }
    var body: some View {
        ScrollViewReader { proxy in
        Form {
            Section { Text("Save a subtask change, then review and send it.").foregroundStyle(.secondary) }
            if let failure { Section { Text(failure).foregroundStyle(.secondary); Button("Read current subtasks again") { reload = UUID() } } }
            if let read, let model, sourceAvailable {
                if store.childTaskStructureEditingEnabled {
                    Section { Button("Organize saved subtasks", systemImage: "list.bullet.indent") {
                        editingField = nil; checkpoint()
                        guard draftSession?.flush() != false else { failure = draftSession?.failure; return }
                        hierarchy = true
                    }.accessibilityIdentifier("childFieldOrganizeStructure") }
                }
                if read.nodes.isEmpty { ContentUnavailableView("No saved subtasks", systemImage: "list.bullet") }
                else {
                    Section {
                        Button {
                            editingField = nil; checkpoint()
                            guard draftSession?.flush() != false else { failure = draftSession?.failure; return }
                            choosingChild = true
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Subtask").font(.caption).foregroundStyle(.secondary)
                                    Text(read.nodes[key]?.fields["title"]?.text ?? "Subtask")
                                        .font(.body).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                                    if let node = read.nodes[key], node.path.count > 1 {
                                        Text("Nested level \(node.path.count)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.up.chevron.down").font(.caption).accessibilityHidden(true)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("independentChildSelection")
                            .accessibilityLabel("Choose subtask")
                            .accessibilityValue(selectionValue)
                        TextField("Title", text: Binding(get: { title }, set: { guard !title.utf8.elementsEqual($0.utf8) else { return }; title = $0; checkpoint(reopen: true) }), axis: .vertical).focused($editingField, equals: .title).accessibilityIdentifier("independentChildTitle")
                        TextField("Notes", text: Binding(get: { notes }, set: { guard !notes.utf8.elementsEqual($0.utf8) else { return }; notes = $0; checkpoint(reopen: true) }), axis: .vertical).lineLimit(3...12).focused($editingField, equals: .notes).accessibilityIdentifier("independentChildNotes")
                        Picker("Priority", selection: Binding(get: { priority }, set: { guard priority != $0 else { return }; priority = $0; checkpoint(reopen: true) })) { ForEach(1...4, id: \.self) { Text("Priority \($0)").tag($0) } }
                        Text("Unsent edits are preserved privately in Backups & restore → Unsent task edits. Only fields you edit are included; checklist structure stays as saved.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if store.childTaskCompletionEnabled, TaskKind.mayComplete(Record(read.nodes[key]?.fields ?? [:])) {
                        ChildTaskCompletionControls(rootID: rootID, key: key, prepareAction: { editingField = nil; checkpoint(); _ = draftSession?.flush() }).id(key)
                    }
                    if TaskKind(Record(read.nodes[key]?.fields ?? [:])) == .task {
                        Section { ChildTaskPlanningFields(draft: $planning, changed: { checkpoint(reopen: true) }, failed: { failure = $0.localizedDescription }) }
                    }
                    Section {
                        Button { openAssignee() } label: {
                            LabeledContent("Assigned to", value: assigneeCaption)
                        }.accessibilityIdentifier("childAssignee")
                    }
                    Section {
                        DisclosureGroup("Labels") {
                            if !labels.supported {
                                Text("These saved labels need a newer app version before editing. Your labels are preserved.").foregroundStyle(.secondary)
                            } else {
                                if labels.entries.isEmpty { Text("No labels yet").foregroundStyle(.secondary) }
                                ForEach(labels.entries) { entry in
                                    HStack {
                                        Label(labels.name(entry, catalog: store.labels), systemImage: "tag").fixedSize(horizontal: false, vertical: true)
                                        Spacer()
                                        Button(role: .destructive) { labels.remove(entry.id); labelMessage = nil; checkpoint(reopen: true) } label: { Image(systemName: "minus.circle").frame(minWidth: 44, minHeight: 44) }
                                            .buttonStyle(.borderless).accessibilityLabel("Remove " + labels.name(entry, catalog: store.labels))
                                            .accessibilityIdentifier("removeChildLabel-\(entry.id)")
                                    }
                                }
                                TextField("Label name", text: Binding(get: { addingLabel }, set: { guard !addingLabel.utf8.elementsEqual($0.utf8) else { return }; addingLabel = $0; labelMessage = nil; checkpoint(reopen: true) }))
                                    .focused($editingField, equals: .label).onSubmit(addLabel).accessibilityIdentifier("childLabelName")
                                Button("Add label", systemImage: "plus", action: addLabel).disabled(addingLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("addChildLabel")
                                if labels.kind == .personal, !store.labels.isEmpty {
                                    Menu("Your labels") {
                                        ForEach(store.labels.filter { label in !labels.entries.contains(where: { $0.value == label.id }) }) { label in
                                            Button(label.name) {
                                                do { try labels.addCatalog(label.id, catalog: store.labels); labelMessage = nil; checkpoint(reopen: true) }
                                                catch { labelMessage = error.localizedDescription }
                                            }
                                        }
                                    }
                                }
                                Text(labels.kind == .shared ? "Shared labels stay with this task; your personal catalog is kept separate." : "Choose an existing label or add a name. Other saved labels keep their original values.").font(.footnote).foregroundStyle(.secondary)
                                if let labelMessage { Text(labelMessage).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("childLabelMessage") }
                                if !addingLabel.isEmpty { Text("Add this label to include it in the saved change. Unfinished input is kept privately.").font(.footnote).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if TaskKind(Record(read.nodes[key]?.fields ?? [:])) == .task {
                        Section { Button("Reminders", systemImage: "bell") { openReminders() }.accessibilityIdentifier("childReminders") }
                    }
                    Section {
                        Button("Save on this device", systemImage: "tray.and.arrow.down") {
                            do {
                                let command = try ChildTaskFieldCommand(read: read, key: key, changes: changes)
                                let session = draftSession, revision = session?.latest?.revision, captured = scope, capturedEditing = editingRevision, unsubmittedLabel = addingLabel
                                savedNoticeFocused = false; messageKey = nil
                                Task {
                                    let saved = await model.save(command)
                                    let unchanged = session?.latest?.revision == revision
                                    if saved != nil, unsubmittedLabel.isEmpty { _ = session?.finish(ifRevision: revision) }
                                    guard unchanged, selectedKey == command.body["node_key"]?.text, scope == captured,
                                          session != nil || editingRevision == capturedEditing else { return }
                                    // A scoped durable result remains true through layout/scene
                                    // changes; only an active, unchanged editor may move focus.
                                    messageKey = selectedKey
                                    guard saved != nil, editingRevision == capturedEditing, appeared, phase == .active, !recovery else { return }
                                    let keyboardWasFocused = editingField != nil
                                    editingField = nil
                                    #if os(iOS)
                                    // A centered iPad sheet changes its viewport during
                                    // keyboard dismissal. Reveal against its settled size.
                                    if keyboardWasFocused { try? await Task.sleep(nanoseconds: 400_000_000) }
                                    #endif
                                    await Task.yield()
                                    guard draftSession === session, editingRevision == capturedEditing, scope == captured, appeared, phase == .active, !recovery, let captured else { return }
                                    noticeRequest = ChildFieldNoticeRequest(scope: captured, key: selectedKey, session: session?.id, revision: capturedEditing)
                                    #if os(macOS)
                                    if reduceMotion { proxy.scrollTo("childFieldSavedNotice", anchor: .bottom) }
                                    else { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("childFieldSavedNotice", anchor: .bottom) } }
                                    #endif
                                }
                            }
                            catch { failure = error.localizedDescription }
                        }.disabled(changes.isEmpty || model.busy).accessibilityIdentifier("saveIndependentChildFields")
                        Button("Review saved changes", systemImage: "tray.and.arrow.up") { recovery = true }
                        if let message = model.message, messageKey == selectedKey {
                            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                .id("childFieldSavedNotice").accessibilityIdentifier("independentChildSaveStatus").accessibilityFocused($savedNoticeFocused)
                                #if os(iOS)
                                .background(ChildFieldNoticeAnchor(ticket: currentNoticeRequest?.ticket, finished: finishNotice))
                                #else
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                                    noticeBounds = frame; revealSavedNotice(proxy)
                                }
                                #endif
                        }
                    }
                }
            } else if read != nil {
                ContentUnavailableView("Editing paused", systemImage: "lock.shield", description: Text("This task or workspace changed. Unsent text is kept privately with its original workspace."))
                if scope != nil { Button("Review saved changes") { recovery = true } }
            } else if failure == nil { ProgressView("Reading saved subtasks…") }
        }
        #if os(iOS)
        .accessibilityIdentifier("childFieldEditorForm")
        #else
        .formStyle(.grouped)
        #endif
        #if os(macOS)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            viewportBounds = frame; revealSavedNotice(proxy)
        }
        .onChange(of: noticeRequest) { _, _ in revealSavedNotice(proxy) }
        #else
        .background(ChildFieldNoticeAnchor(ticket: currentNoticeRequest?.ticket, viewport: true, finished: finishNotice))
        #endif
        .onAppear { appeared = true }
        .privacySensitive()
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: key) { _, _ in select() }
        .onChange(of: sourceAvailable) { _, value in if !value { checkpoint(); _ = draftSession?.flush() } }
        .onChange(of: phase) { _, value in if value != .active { choosingChild = false; reminderOwnership.close("source"); sharedAssignee = nil; personalAssignee = nil; reminderEditor = nil; noticeRequest = nil; editingRevision = UUID(); checkpoint(); _ = draftSession?.flush() } }
        .onChange(of: recovery) { _, value in if value { noticeRequest = nil; editingRevision = UUID() } }
        .task(id: ChildFieldReadRequest(scope: scope, retry: reload)) {
            let preferredSelection = sourceAvailable ? key : ""
            choosingChild = false
            reminderOwnership.close("source"); sharedAssignee = nil; personalAssignee = nil; reminderEditor = nil; noticeRequest = nil; messageKey = nil; editingRevision = UUID(); noticeBounds = .zero
            checkpoint(); for session in draftSessions.values { _ = session.flush() }
            let previousRead = read, previousSessions = draftSessions, previousDrafts = draftValues, previousLabels = labelInputs
            draftSession = nil; draftSessions = [:]; draftValues = [:]; labelInputs = [:]; addingLabel = ""; selectedKey = ""
            model?.close(); model = nil; read = nil; title = ""; notes = ""; key = ""; failure = nil
            guard let captured = scope else { return }
            do {
                guard store.childTaskFieldEditingEnabled else { throw ChildTaskFieldWriteFailure(reason: .unavailable) }
                let value = try await store.readChildTaskRecords(rootID)
                guard captured == scope, !Task.isCancelled else { return }
                var needsRecovery = false
                if let previousRead {
                    let retained = ChildTaskFieldDraftContinuation.retainedKeys(from: previousRead, to: value)
                    if ChildTaskFieldClientScope(previousRead.context) == captured {
                        needsRecovery = previousSessions.contains { !retained.contains($0.key) && !$0.value.closed && $0.value.latest != nil }
                    }
                    draftSessions = previousSessions.filter { retained.contains($0.key) }
                    draftValues = previousDrafts.filter { retained.contains($0.key) }
                    labelInputs = previousLabels.filter { retained.contains($0.key) }
                }
                read = value; model = try store.childTaskFieldRecoveryModel(); key = value.nodes[preferredSelection] != nil ? preferredSelection : value.orderedNodes.first?.key ?? ""; select()
                if needsRecovery { failure = "Unfinished edits for changed subtasks are kept in recovery." }
            } catch { guard captured == scope, !Task.isCancelled else { return }; failure = error.localizedDescription }
        }
        .onDisappear {
            appeared = false; noticeRequest = nil
            // An owned composer can cover this view while continuing the same
            // edit. Its presentation token, not parent visibility, owns Apply.
            if !reminderOwnership.active { editingRevision = UUID() }
            checkpoint(); _ = draftSession?.flush()
        }
        .sheet(isPresented: $choosingChild) {
            WorkflowShell(title: "Subtasks") {
                if let read, sourceAvailable {
                    ScrollViewReader { selectionProxy in
                        List {
                            if let failure { Section { Text(failure).foregroundStyle(.secondary) } }
                            ForEach(read.orderedNodes, id: \.key) { node in
                                Button {
                                    guard sourceAvailable, self.read?.context.matches(read.context) == true,
                                          phase == .active else { failure = "Subtasks changed. Close and reopen selection."; return }
                                    key = node.key; select()
                                    if selectedKey == node.key { choosingChild = false }
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(node.fields["title"]?.text ?? "Subtask").lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                                            if node.path.count > 1 { Text("Nested level \(node.path.count)").font(.caption).foregroundStyle(.secondary) }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                        if node.key == key { Image(systemName: "checkmark").accessibilityHidden(true) }
                                    }.padding(.leading, CGFloat(min(node.path.count - 1, 5)) * 12)
                                        .frame(minHeight: 44).contentShape(Rectangle())
                                }.buttonStyle(.plain).id(node.key)
                                    .accessibilityIdentifier("chooseIndependentChild-" + node.key)
                                    .accessibilityAddTraits(node.key == key ? .isSelected : [])
                            }
                        }.privacySensitive()
                            .task { await Task.yield(); guard choosingChild, sourceAvailable, !Task.isCancelled else { return }; selectionProxy.scrollTo(key, anchor: .center) }
                    }
                } else { ContentUnavailableView("Open your workspace", systemImage: "lock.shield") }
            }
        }
        .sheet(isPresented: $hierarchy, onDismiss: { reload = UUID() }) { WorkflowShell(title: "Organize subtasks") { ChildTaskStructureView(rootID: rootID) } }
        .sheet(isPresented: $recovery) { WorkflowShell(title: "Saved subtask changes") { ChildTaskFieldRecoveryView() } }
        .sheet(item: $sharedAssignee) { TeamTaskAssigneePicker(request: $0) }
        .sheet(item: $personalAssignee) { ChildPersonalAssigneeView(request: $0) }
        .sheet(item: $reminderEditor) { TeamTaskRemindersEditor(request: $0).id($0.id) }
        }
    }
    private func openReminders() {
        guard sourceAvailable, let read, let captured = scope, let original = read.nodes[selectedKey], TaskKind(Record(original.fields)) == .task else { return }
        noticeRequest = nil
        let selected = selectedKey, revision = editingRevision
        let parent = read.context.root
        let shared = !TeamTaskLabelsDraft.usesPersonalCatalog(parent, cache: store.nativeConversationTeamCache)
        let team = shared ? (try? store.captureTeamTaskEditor(parent)) : nil
        guard !shared || team != nil else { failure = "Project access changed. Reopen the task before changing reminders."; return }
        let presentation = reminderOwnership.begin()
        let current = { sourceAvailable && scope == captured && selectedKey == selected && editingRevision == revision && presentation.active && phase == .active && store.editorMayWrite(source: parent, proposed: parent, teamDraft: team) }
        var record = reminders.applying(to: assignment.applying(to: labels.applying(to: planning.applying(to: Record(original.fields)))))
        record["title"] = .string(title); record["description"] = .string(notes); record["priority"] = .number(Double(priority))
        reminderEditor = TeamTaskRemindersRequest(childWorkspace: WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration), record: record, sourceIdentity: draftIdentity, current: current, apply: { settings in
            guard current() else { return "This task changed. Your reminder settings stay in their private draft." }
            do { try reminders.apply(settings); checkpoint(reopen: true); return nil }
            catch { return error.localizedDescription }
        }, presentationID: presentation.id, closed: { presentation.close("composer") })
    }
    private var assigneeCaption: String {
        let id = assignment.selected
        if id.isEmpty { return assignment.value["assigned_to"] == .null ? "Unassigned" : "Saved assignment · unavailable" }; if id == store.userID { return "You" }
        if chosenAssigneeID == id, let chosenAssigneeName { return chosenAssigneeName }
        if let read, TeamTaskLabelsDraft.usesPersonalCatalog(read.context.root, cache: store.nativeConversationTeamCache),
           let person = store.projectMembers(read.context.root.string("project_id")).first(where: { $0.id == id }),
           let name = TeamOrganizationDetail.Member.identity(person["display_name"]) { return name }
        return "Project member"
    }
    private func openAssignee() {
        guard sourceAvailable, let read, let captured = scope else { return }
        noticeRequest = nil
        let selected = selectedKey, revision = editingRevision
        let current = { sourceAvailable && scope == captured && selectedKey == selected && editingRevision == revision && appeared && phase == .active }
        let apply: (String?) -> String? = { user in
            guard current() else { return "This task changed. Reopen assignment before choosing a person." }
            do { try assignment.choose(user); checkpoint(reopen: true); return nil }
            catch { return error.localizedDescription }
        }
        if !TeamTaskLabelsDraft.usesPersonalCatalog(read.context.root, cache: store.nativeConversationTeamCache) {
            do {
                let parent = try store.captureTeamTaskEditor(read.context.root)
                sharedAssignee = TeamTaskAssigneeRequest(draft: parent, selected: Binding(get: { assignment.selected }, set: { _ in }), current: current, choose: { person in
                    let result = apply(person?.id)
                    if result == nil { chosenAssigneeID = person?.id ?? ""; chosenAssigneeName = person?.displayName }
                    return result
                }, intentFooter: "Your choice stays private until you save, review and send it.")
            } catch { failure = error.localizedDescription }
        } else {
            personalAssignee = ChildPersonalAssigneeRequest(account: captured.account, selected: assignment.selected, current: current, read: { try await store.refreshProjectMembers(read.context.root.string("project_id")) }, choose: apply)
        }
    }
    private func addLabel() {
        do { try labels.addName(addingLabel, catalog: store.labels); addingLabel = ""; labelMessage = nil; checkpoint(reopen: true) }
        catch { labelMessage = error.localizedDescription }
    }
    private var currentNoticeRequest: ChildFieldNoticeRequest? {
        guard let request = noticeRequest, request.scope == scope, request.key == selectedKey,
              request.session == draftSession?.id, request.revision == editingRevision,
              sourceAvailable, appeared, phase == .active, !recovery else { return nil }
        return request
    }
    private func finishNotice(_ ticket: UUID, _ visible: Bool) {
        guard currentNoticeRequest?.ticket == ticket else { return }
        noticeRequest = nil
        if visible { savedNoticeFocused = true }
    }
    #if os(macOS)
    private func revealSavedNotice(_ proxy: ScrollViewProxy) {
        guard let request = currentNoticeRequest, !viewportBounds.isEmpty, !noticeBounds.isEmpty else { return }
        if noticeBounds.minY >= viewportBounds.minY - 1, noticeBounds.maxY <= viewportBounds.maxY + 1 {
            finishNotice(request.ticket, true)
        } else {
            Task { @MainActor in
                await Task.yield()
                guard currentNoticeRequest?.ticket == request.ticket else { return }
                proxy.scrollTo("childFieldSavedNotice", anchor: .bottom)
            }
        }
    }
    #endif
    private func select() {
        guard key != selectedKey else { return }
        reminderOwnership.close("selection"); sharedAssignee = nil; personalAssignee = nil; reminderEditor = nil; chosenAssigneeID = ""; chosenAssigneeName = nil
        noticeRequest = nil; editingRevision = UUID(); noticeBounds = .zero
        checkpoint()
        if draftSession?.flush() == false { key = selectedKey; failure = draftSession?.failure; return }
        guard let node = read?.nodes[key], let read else { return }
        selectedKey = key
        let draft = draftValues[key] ?? Record(node.fields)
        title = draft.title; notes = draft["description"].text; priority = draft.priority; planning = ChildTaskPlanningDraft(original: Record(node.fields), restored: draft); assignment = ChildTaskAssignmentDraft(original: Record(node.fields), restored: draft); reminders = ChildTaskRemindersDraft(original: Record(node.fields), restored: draft)
        labels = ChildTaskLabelsDraft(original: Record(node.fields), restored: draft, kind: TeamTaskLabelsDraft.usesPersonalCatalog(read.context.root, cache: store.nativeConversationTeamCache) ? .personal : .shared)
        addingLabel = labelInputs[key] ?? ""; labelMessage = nil; failure = nil
        draftIdentity = .object(["root": .string(read.context.root.id), "generation": read.context.root["task_generation"], "project": read.context.root["project_id"], "node": .string(node.key), "incarnation": .string(node.incarnation), "revision": .number(node.revision)])
        do {
            draftSession = try draftSessions[key] ?? store.beginEditorSession(Record(node.fields))
            draftSessions[key] = draftSession
        } catch { failure = error.localizedDescription }
    }
    private func checkpoint(reopen: Bool = false) {
        if reopen { reminderOwnership.close("edit"); editingRevision = UUID(); noticeRequest = nil; messageKey = nil }
        guard let read, let node = read.nodes[selectedKey] else { return }
        if draftSession?.closed == true {
            guard reopen, ChildTaskFieldClientScope(read.context) == scope else { return }
            do { draftSession = try store.beginEditorSession(Record(node.fields)); draftSessions[selectedKey] = draftSession }
            catch { failure = error.localizedDescription; return }
        }
        guard let session = draftSession else { return }
        var draft = reminders.applying(to: assignment.applying(to: labels.applying(to: planning.applying(to: session.original)))); draft["title"] = .string(title); draft["description"] = .string(notes); draft["priority"] = .number(Double(priority))
        draftValues[selectedKey] = draft; labelInputs[selectedKey] = addingLabel
        guard session.latest != nil || !title.utf8.elementsEqual(session.original.title.utf8) || !notes.utf8.elementsEqual(session.original["description"].text.utf8) || priority != session.original.priority || !planning.changes.isEmpty || !labels.changes.isEmpty || !assignment.changes.isEmpty || !reminders.changes.isEmpty || !addingLabel.isEmpty else { return }
        session.capture(draft, extras: ["independent_child_fields": draftIdentity, "unsubmitted_child_label": .string(addingLabel)])
    }
}

private struct ChildTaskPlanningFields: View {
    @Binding var draft: ChildTaskPlanningDraft
    let changed: () -> Void
    let failed: (Error) -> Void
    private var value: Record { draft.value }
    private func update(_ action: (inout ChildTaskPlanningDraft) throws -> Void) {
        var next = draft
        do {
            try action(&next)
            guard !AuthoredValueComparison.exactJSON(.object(next.value.fields), .object(draft.value.fields)) else { return }
            draft = next; changed()
        } catch { failed(error) }
    }
    var body: some View {
        DisclosureGroup("Plan") {
            Toggle("Planned date", isOn: Binding(get: { value.due != nil }, set: { enabled in update { try $0.plannedDay(enabled ? Dates.day(Date()) : nil) } }))
                .accessibilityIdentifier("childPlannedEnabled")
            if value.due != nil {
                DatePicker("Date", selection: Binding(get: { value.due ?? Date() }, set: { date in update { try $0.plannedDay(Dates.day(date)) } }), displayedComponents: .date)
                    .accessibilityIdentifier("childPlannedDate")
                Toggle("Time", isOn: Binding(get: { !value.string("due_time").isEmpty }, set: { enabled in update { try $0.clock(enabled ? "09:00" : nil) } }))
                    .accessibilityIdentifier("childTimeEnabled")
                if !value.string("due_time").isEmpty {
                    DatePicker("Time", selection: Binding(get: {
                        let parts = value.string("due_time").split(separator: ":").compactMap { Int($0) }
                        return Calendar.current.date(bySettingHour: parts.first ?? 9, minute: parts.count > 1 ? parts[1] : 0, second: 0, of: Date()) ?? Date()
                    }, set: { date in
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                        update { try $0.clock(String(format: "%02d:%02d", parts.hour ?? 9, parts.minute ?? 0)) }
                    }), displayedComponents: .hourAndMinute).accessibilityIdentifier("childPlannedTime")
                    Picker("Time zone", selection: Binding(get: { value.string("time_zone") }, set: { zone in update { try $0.zone(zone.isEmpty ? nil : zone) } })) {
                        Text("Local time · wherever I am").tag("")
                        Text("Fixed · " + TimeZone.current.identifier).tag(TimeZone.current.identifier)
                        if !value.string("time_zone").isEmpty && value.string("time_zone") != TimeZone.current.identifier {
                            Text("Fixed · " + value.string("time_zone")).tag(value.string("time_zone"))
                        }
                    }.accessibilityIdentifier("childPlannedZone")
                    if !value.string("time_zone").isEmpty { Text("Date and time use " + value.string("time_zone") + ".").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            Toggle("Deadline", isOn: Binding(get: { value.deadline != nil }, set: { enabled in update { try $0.deadline(enabled ? Dates.day(Date()) : nil) } }))
                .accessibilityIdentifier("childDeadlineEnabled")
            if value.deadline != nil {
                DatePicker("Must be done by", selection: Binding(get: { value.deadline ?? Date() }, set: { date in update { try $0.deadline(Dates.day(date)) } }), displayedComponents: .date)
                    .accessibilityIdentifier("childDeadlineDate")
                Text("Rescheduling the plan leaves this deadline in place.").font(.footnote).foregroundStyle(.secondary)
            }
            Toggle("Time estimate", isOn: Binding(get: { value.durationMinutes != nil }, set: { enabled in update { try $0.estimate(enabled ? 30 : nil) } }))
                .accessibilityIdentifier("childEstimateEnabled")
            if let minutes = value.durationMinutes {
                Picker("Quick estimate", selection: Binding(get: { minutes }, set: { amount in update { try $0.estimate(amount) } })) {
                    ForEach(Array(Set([15, 30, 45, 60, 90, 120, minutes])).sorted(), id: \.self) { amount in Text("\(amount) min").tag(amount) }
                }.accessibilityIdentifier("childEstimatePresets")
                Stepper("Estimate · \(minutes) min", value: Binding(get: { minutes }, set: { amount in update { try $0.estimate(amount) } }), in: 1...10080)
                    .accessibilityLabel("Time estimate in minutes").accessibilityValue("\(minutes)").accessibilityIdentifier("childEstimateMinutes")
            }
        }
    }
}

#if os(iOS)
/// Form rows are hosted by native collection cells. Measure and reveal in that
/// scroll view's coordinates rather than crossing SwiftUI hosting boundaries.
private struct ChildFieldNoticeAnchor: UIViewRepresentable {
    let ticket: UUID?
    var viewport = false
    let finished: (UUID, Bool) -> Void
    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView(); view.isUserInteractionEnabled = false; view.isAccessibilityElement = false
        return view
    }
    func updateUIView(_ view: AnchorView, context: Context) { view.configure(ticket, viewport: viewport, finished: finished) }
    static func dismantleUIView(_ view: AnchorView, coordinator: ()) { view.configure(nil, viewport: false, finished: { _, _ in }) }
    final class AnchorView: UIView {
        private var ticket: UUID?
        private var viewport = false
        private weak var viewportOwner: UIScrollView?
        private var finished: ((UUID, Bool) -> Void)?
        private var timer: Timer?
        private var started: TimeInterval = 0
        func configure(_ next: UUID?, viewport: Bool, finished: @escaping (UUID, Bool) -> Void) {
            self.finished = finished
            guard ticket != next || self.viewport != viewport else { return }
            timer?.invalidate(); timer = nil; ticket = next; self.viewport = viewport; viewportOwner = nil
            guard next != nil else { return }
            started = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                MainActor.assumeIsolated { self.reveal() }
            }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        private func finish(_ visible: Bool) {
            guard let ticket else { return }
            timer?.invalidate(); timer = nil; self.ticket = nil
            finished?(ticket, visible)
        }
        private func viewportScroll() -> UIScrollView? {
            let frame = convert(bounds, to: nil)
            func candidates(_ view: UIView) -> [UIScrollView] {
                guard !view.isHidden, view.alpha > 0.001, view.window === window else { return [] }
                var result = view.subviews.flatMap(candidates)
                if let scroll = view as? UIScrollView, scroll.isScrollEnabled {
                    let rect = scroll.convert(scroll.bounds, to: nil)
                    // Exclude the background workspace and nested text editors.
                    if abs(rect.width - frame.width) < 2, rect.intersects(frame) { result.append(scroll) }
                }
                return result
            }
            var ancestor = superview
            while let view = ancestor {
                if let match = candidates(view).min(by: {
                    let a = $0.convert($0.bounds, to: nil), b = $1.convert($1.bounds, to: nil)
                    return abs(a.minY - frame.minY) + abs(a.height - frame.height) < abs(b.minY - frame.minY) + abs(b.height - frame.height)
                }) { return match }
                if view is UIWindow { break }; ancestor = view.superview
            }
            return nil
        }
        private func reveal() {
            guard ticket != nil else { return }
            // A disappeared/unavailable host must never retain a polling loop.
            guard ProcessInfo.processInfo.systemUptime - started < 2 else { finish(false); return }
            guard window != nil, !bounds.isEmpty else { return }
            if viewport {
                guard let scroll = viewportOwner ?? viewportScroll() else { return }
                viewportOwner = scroll
                // The success row is last. Bring an uninstantiated lazy cell
                // into view; its own anchor then proves complete visibility.
                let minimum = -scroll.adjustedContentInset.top
                let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: maximum), animated: false)
                return
            }
            var row: UIView = self
            var ancestor = superview
            var owner: UIScrollView?
            while let view = ancestor {
                if view is UICollectionViewCell || view is UITableViewCell { row = view }
                if let scroll = view as? UIScrollView { owner = scroll; break }
                ancestor = view.superview
            }
            guard let scroll = owner, scroll.isScrollEnabled else { return }
            let rect = row.convert(row.bounds, to: scroll)
            let visible = scroll.bounds.inset(by: scroll.adjustedContentInset)
            guard !rect.isEmpty, !visible.isEmpty else { return }
            if rect.minY >= visible.minY - 1, rect.maxY <= visible.maxY + 1 { finish(true); return }
            let delta = rect.height > visible.height || rect.minY < visible.minY ? rect.minY - visible.minY : rect.maxY - visible.maxY
            let minimum = -scroll.adjustedContentInset.top
            let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let next = min(maximum, max(minimum, scroll.contentOffset.y + delta))
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: next), animated: false)
            if rect.height > visible.height { finish(false) }
        }
    }
}
#endif

private struct ChildPersonalAssigneeRequest: Identifiable {
    let id = UUID()
    let account: String
    let selected: String
    let current: () -> Bool
    let read: () async throws -> [Record]
    let choose: (String?) -> String?
}
private struct ChildPersonalAssigneeView: View {
    @Environment(\.dismiss) private var dismiss
    let request: ChildPersonalAssigneeRequest
    @State private var model: ChildTaskPersonalRecipientPicker?
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List {
                if request.current() {
                    choice(nil, "Unassigned"); choice(request.account, "You")
                    ForEach(model?.people.filter { $0.id != request.account && (search.isEmpty || $0.name.localizedStandardContains(search)) } ?? []) { person in choice(person.id, person.name) }
                    if model?.busy == true { ProgressView("Checking assignment…") }
                    if let message = model?.message { Text(message).foregroundStyle(.secondary) }
                    Button("Refresh choices") { Task { await model?.refresh() } }.disabled(model?.busy == true)
                    Text("Your choice stays private until you save, review and send it.").font(.footnote).foregroundStyle(.secondary)
                } else { ContentUnavailableView("Assignment paused", systemImage: "lock.shield", description: Text("This task or workspace changed. Close the picker and reopen the task.")) }
            }
            .searchable(text: $search, prompt: "Find a project member")
            .navigationTitle("Assign subtask")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
        .task { let value = ChildTaskPersonalRecipientPicker(account: request.account, current: request.current, read: request.read, apply: request.choose); model = value; await value.refresh() }
        .onChange(of: request.current()) { _, available in if !available { model?.invalidate() } }
        .onDisappear { model?.invalidate() }
    }
    private func choice(_ id: String?, _ name: String) -> some View {
        Button { Task { if await model?.choose(id) == true { dismiss() } } } label: {
            HStack { Text(name).fixedSize(horizontal: false, vertical: true); Spacer(); if (id ?? "") == request.selected { Image(systemName: "checkmark") } }.frame(minHeight: 44)
        }.disabled(model == nil || model?.busy == true && id != nil && id != request.account).accessibilityIdentifier("childAssignee-" + (id == nil ? "unassigned" : id == request.account ? "self" : id!))
    }
}

private struct ChildFieldAssigneeLookup: Hashable {
    let scope: ChildTaskFieldClientScope?
    let request: String
    let user: String
    let available: Bool
}
/// Resolve names only in the request's current account/project. The identity in
/// the durable command is unchanged, and unavailable names are stated explicitly.
private struct ChildFieldAssigneeReview: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    let command: ChildTaskFieldCommand
    var selection: JSON? = nil
    @State private var name: String?
    private var user: String { (selection ?? command.body["changes"]!.object["assigned_to"])?.text ?? "" }
    private var root: Record? {
        guard let scope = store.childTaskFieldRecoveryScope, scope.account == command.account, scope.origin == command.origin,
              let root = store.record("tasks", id: command.body["task_id"]!.text), root["task_generation"] == command.body["task_generation"], root["project_id"] == command.body["project_id"] else { return nil }
        if !TeamTaskLabelsDraft.usesPersonalCatalog(root, cache: store.nativeConversationTeamCache), (try? store.captureTeamTaskEditor(root)) == nil { return nil }
        return root
    }
    private var available: Bool { phase == .active && store.childTaskFieldEditingEnabled && root != nil }
    private var lookup: ChildFieldAssigneeLookup { .init(scope: store.childTaskFieldRecoveryScope, request: command.id, user: user, available: available) }
    var body: some View {
        Text(user.isEmpty ? "Unassigned" : user == command.account ? "You" : available ? name ?? "Saved person · name unavailable" : "Saved person · name unavailable")
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            .task(id: lookup) {
                name = nil
                guard available, !user.isEmpty, user != command.account, let root else { return }
                let captured = lookup
                do {
                    let resolved: String?
                    if TeamTaskLabelsDraft.usesPersonalCatalog(root, cache: store.nativeConversationTeamCache) {
                        let people = try await store.refreshProjectMembers(root.string("project_id"))
                        resolved = people.first(where: { $0.id == user }).flatMap { TeamOrganizationDetail.Member.identity($0["display_name"]) }
                    } else {
                        let draft = try store.captureTeamTaskEditor(root)
                        let people = try await store.backend.teamTaskRecipients(draft)
                        guard store.editorMayWrite(source: draft.source, proposed: draft.source, teamDraft: draft) else { return }
                        resolved = people.people.first(where: { $0.id == user })?.displayName
                    }
                    guard lookup == captured, !Task.isCancelled else { return }; name = resolved
                } catch { guard lookup == captured else { return }; name = nil }
            }
    }
}

/// Each comparison owns a fresh recovery model. The underlying saved-request
/// screen may disappear under this sheet without cancelling this review.
private struct ChildFieldConflictReview: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    let command: ChildTaskFieldCommand
    let captured: ChildTaskFieldClientScope
    @State private var model: ChildTaskFieldRecoveryModel?
    @State private var comparison: ChildTaskFieldComparison?
    @State private var chosen: Set<String> = []
    @State private var failure: String?
    @State private var loading = false
    @State private var confirmingClose = false
    @State private var saved = false
    @State private var visible = false
    private var available: Bool { visible && phase == .active && store.childTaskFieldRecoveryScope == captured }
    private var entry: ChildTaskFieldJournalState.Entry? { available ? model?.entries.first(where: { $0.command == command }) : nil }
    private var current: Bool { comparison.map { available && store.childTaskFieldComparisonIsCurrent($0.read) } == true }
    var body: some View {
        NavigationStack {
            Form {
                if let entry {
                    Section {
                        Text("Choose which saved changes you still want. Current values are kept unless you choose a saved change.")
                        if entry.phase == .closed {
                            Label("Original request closed", systemImage: "checkmark.shield")
                                .accessibilityIdentifier("childOriginalClosed")
                        } else if entry.phase == .confirmed {
                            Label("Original change confirmed", systemImage: "checkmark.circle")
                            Text("Closing recovered its confirmation. Open the current task to make another edit.")
                        } else {
                            Text("Before saving a replacement, close the original request. A lost reply may mean it already applied.")
                            Button("Close original request…", systemImage: "stop.circle") { confirmingClose = true }
                                .disabled(loading || model?.busy == true).accessibilityIdentifier("closeOriginalChildField")
                        }
                    }
                    if let comparison, current {
                        ForEach(comparison.groups, id: \.id) { group in
                            Section(groupTitle(group.id)) {
                                ForEach(group.fields, id: \.self) { field in
                                    VStack(alignment: .leading, spacing: 8) {
                                        if group.fields.count > 1 { Text(fieldTitle(field)).font(.headline) }
                                        Text("Current").font(.caption).foregroundStyle(.secondary)
                                        reviewValue(field, comparison.current[field])
                                        Text("Your saved change").font(.caption).foregroundStyle(.secondary)
                                        reviewValue(field, command.body["changes"]!.object[field]!)
                                    }.fixedSize(horizontal: false, vertical: true)
                                }
                                if let warning = group.warning { Text(warning).font(.footnote).foregroundStyle(.secondary) }
                                if group.differs {
                                    Toggle("Use my saved change", isOn: Binding(get: { chosen.contains(group.id) }, set: { value in
                                        saved = false; if value { chosen.insert(group.id) } else { chosen.remove(group.id) }
                                    })).disabled(group.warning != nil || entry.phase != .closed || model?.busy == true || saved)
                                        .accessibilityIdentifier("chooseChildField-" + group.id)
                                } else { Label("Already matches", systemImage: "checkmark").foregroundStyle(.secondary) }
                            }
                        }
                        if entry.phase == .closed {
                            Section {
                                Button("Save reviewed changes", systemImage: "tray.and.arrow.down") {
                                    guard current, let model else { return }
                                    Task {
                                        let result = await model.saveReplacement(comparison, choosing: chosen)
                                        guard available else { return }; if result != nil { saved = true; chosen = [] }
                                    }
                                }.disabled(chosen.isEmpty || model?.busy == true || saved).accessibilityIdentifier("saveReviewedChildFields")
                                Text("This saves a new request on this device. Review it in Saved subtask changes before sending.").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    } else if !loading {
                        Section { Text("Refresh current values before choosing changes. Your original request stays saved.").foregroundStyle(.secondary) }
                    }
                    if let failure { Section { Text(failure).foregroundStyle(.secondary) } }
                    if let message = model?.message { Section { Text(message).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("childComparisonStatus") } }
                    Section {
                        Button("Refresh current values", systemImage: "arrow.clockwise") { Task { await refresh() } }
                            .disabled(loading || model?.busy == true).accessibilityIdentifier("refreshChildComparison")
                    }
                } else if model?.loaded == true || !available {
                    ContentUnavailableView("Reopen saved changes", systemImage: "lock.shield", description: Text("This request or workspace changed. Your saved work is kept."))
                }
                if loading || model?.busy == true || model == nil && available { ProgressView("Checking saved changes…") }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Review saved change")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { visible = true }
        .task(id: available) {
            model?.close(); model = nil; comparison = nil; chosen = []; failure = nil
            guard available else { return }
            do {
                let value = try store.childTaskFieldRecoveryModel(); model = value; await value.load()
                guard available else { value.close(); return }; await refresh()
            } catch { if available { failure = error.localizedDescription } }
        }
        .onChange(of: current) { _, value in if !value { chosen = []; confirmingClose = false } }
        .onDisappear { visible = false; model?.close(); comparison = nil; chosen = []; confirmingClose = false }
        .alert("Close the original request?", isPresented: $confirmingClose) {
            Button("Close original request") {
                guard available, entry != nil, let model else { return }
                Task { await model.closeOriginal(command); guard available else { return }; await refresh() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The service will prevent this request from applying later. If it already applied, closing recovers its confirmation and does not undo the change.") }
    }
    private func refresh() async {
        guard available, !loading, model?.busy != true else { return }
        loading = true; comparison = nil; chosen = []; saved = false; failure = nil
        defer { loading = false }
        do {
            await store.sync(); guard available, !Task.isCancelled else { return }
            let read = try await store.readChildTaskRecords(command.body["task_id"]!.text)
            guard available, !Task.isCancelled else { return }
            comparison = try ChildTaskFieldComparison(original: command, read: read)
        } catch is CancellationError {} catch {
            if available { failure = "Couldn’t compare this task. It may have moved, been recreated, or become unavailable. The original request stays saved." }
        }
    }
    private func groupTitle(_ id: String) -> String { id == "plan" ? "Plan" : fieldTitle(id) }
    private func fieldTitle(_ id: String) -> String {
        ["title":"Title", "description":"Notes", "priority":"Priority", "due_date":"Planned date", "due_time":"Planned time", "deadline_date":"Deadline", "duration_minutes":"Time estimate", "time_zone":"Time zone", "scheduled_at":"Exact time", "assigned_to":"Assigned to", "labels":"Labels", "reminder_specs":"Reminders"][id] ?? "Saved value"
    }
    @ViewBuilder private func reviewValue(_ field: String, _ value: JSON) -> some View {
        if field == "assigned_to" { ChildFieldAssigneeReview(command: command, selection: value) }
        else { Text(self.value(field, value)).textSelection(.enabled) }
    }
    private func value(_ field: String, _ value: JSON) -> String {
        if field == "reminder_specs" { return ChildTaskRemindersDraft.summary(value) }
        if field == "assigned_to" { return value == .null || value.text.isEmpty ? "Unassigned" : value.text == store.userID ? "You" : "Another project member" }
        if field == "labels" {
            let labels = TeamTaskLabelsDraft(value)
            guard labels.supported else { return "Labels unavailable in this version" }
            guard !labels.entries.isEmpty else { return "No labels" }
            let personal = comparison.map { TeamTaskLabelsDraft.usesPersonalCatalog($0.read.context.root, cache: store.nativeConversationTeamCache) } ?? false
            return labels.entries.map { item in
                let name = personal ? store.labels.first(where: { $0.id == item.value })?.name : nil
                return name ?? TeamTaskLabelsDraft.displayName(item.value) ?? "Saved label · name unavailable"
            }.joined(separator: ", ")
        }
        if value == .null { return "None" }
        if field == "duration_minutes" { return "\(value.integer) min" }
        if field == "priority" { return value.integer == 4 ? "None" : "Priority \(value.integer)" }
        if case .string(let text) = value { return text.isEmpty ? "Empty" : text }
        return "Saved value · kept unchanged"
    }
}
