import SwiftUI

private struct ChildCompletionTargetsRequest: Hashable {
    let scope: ChildTaskFieldClientScope?
    let requests: [String]
    let revision: UUID
    let online: Bool
    let enabled: Bool
}

struct SavedChildTaskCompletionsLink: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var visible = false
    @State private var showing = false
    @State private var revision = UUID()
    private var scope: ChildTaskFieldClientScope? { phase == .active ? store.childTaskFieldRecoveryScope : nil }
    var body: some View {
        Group {
            if visible, scope != nil {
                Section { Button("Saved subtask actions", systemImage: "checkmark.circle") { showing = true }.accessibilityIdentifier("savedChildCompletions") }
            }
        }
        .task(id: scope) { await discover() }
        .task(id: revision) { await discover() }
        .sheet(isPresented: $showing, onDismiss: { revision = UUID() }) {
            WorkflowShell(title: "Saved subtask actions") { ChildTaskCompletionRecoveryView() }
        }
    }
    private func discover() async {
        visible = false; guard let captured = scope else { return }
        do {
            let journal = try store.childTaskCompletionJournal(account: captured.account, origin: captured.origin)
            let state = try await journal.load()
            guard captured == scope, !Task.isCancelled else { return }; visible = !state.entries.isEmpty
        } catch { guard captured == scope, !Task.isCancelled else { return }; visible = true }
    }
}

/// Completion has its own fresh read and journal. Updating it never replaces
/// the surrounding editor's privately preserved, unsent field drafts.
struct ChildTaskCompletionControls: View {
    let rootID: String
    let key: String
    var simple = false
    let prepareAction: () -> Void
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var model: ChildTaskCompletionRecoveryModel?
    @State private var modelScope: ChildTaskFieldClientScope?
    @State private var read: ChildTaskRecordRead?
    @State private var reading = false
    @State private var presentation = UUID()
    @State private var failure: String?
    @State private var showing = false
    private var scope: ChildTaskFieldClientScope? { phase == .active ? store.childTaskFieldRecoveryScope : nil }
    private var node: ChildTaskRecordRead.Node? { read?.nodes[key] }
    private var pending: Bool { model?.entries.contains { $0.command.body["task_id"] == .string(rootID) && $0.command.body["node_key"] == .string(key) && ($0.phase == .queued || $0.phase == .attempted) } == true }
    private var undoEntry: ChildTaskCompletionJournalState.Entry? {
        guard let read else { return nil }
        return model?.entries.last { entry in
            guard entry.phase == .confirmed, !entry.command.isUndo, entry.command.body["task_id"] == .string(rootID), entry.command.body["node_key"] == .string(key), !hasUndo(entry.command.id), let receipt = entry.receipt else { return false }
            return (try? ChildTaskCompletionCommand(undo: entry.command, receipt: receipt, read: read)) != nil
        }
    }
    private func hasUndo(_ id: String) -> Bool { model?.entries.contains { $0.command.body["undo_of"] == .string(id) && $0.phase != .closed } == true }
    var body: some View {
        Section("Completion") {
            if modelScope == scope, scope != nil, let model {
                if let node, let completed = try? ChildTaskCompletionDraft.completed(node.fields) {
                    Label(completed ? "Completed" : "Open", systemImage: completed ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(completed ? .green : .secondary).accessibilityIdentifier("childCompletionState")
                    Button(completed ? "Reopen subtask" : "Complete subtask", systemImage: completed ? "arrow.uturn.backward" : "checkmark") {
                        guard let read else { return }; prepareAction()
                        Task { _ = await model.perform(read: read, key: key, action: completed ? .reopen : .complete); await refresh() }
                    }.disabled(model.busy || reading || pending).accessibilityIdentifier("childCompletionAction")
                    if let entry = undoEntry {
                        Button("Undo last action", systemImage: "arrow.uturn.backward") {
                            guard let read else { return }; prepareAction(); Task { await model.undo(entry, read: read); await refresh() }
                        }.disabled(model.busy || reading || pending).accessibilityIdentifier("childCompletionUndo")
                    }
                } else if reading { ProgressView("Reading completion…") }
                if let message = model.message { ChildCompletionNotice(message: message).font(.callout).accessibilityIdentifier("childCompletionStatus") }
                if let failure { Text(failure).font(.footnote).foregroundStyle(.secondary) }
                if pending { Text("A saved action is waiting. Review it before making another completion change.").font(.footnote).foregroundStyle(.secondary) }
                if !simple || pending {
                    Button("Saved subtask actions", systemImage: "tray") { prepareAction(); showing = true }.accessibilityIdentifier("childCompletionRecovery")
                }
                if !simple || failure != nil {
                    Button("Refresh completion", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(model.busy || reading || !store.online)
                }
                if !simple { Text("Completion applies only to this subtask. Your unsent title and notes stay in the editor.").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .task(id: scope) {
            clear(); guard let captured = scope else { return }
            do { let value = try store.childTaskCompletionRecoveryModel(); model = value; modelScope = captured; await value.load(); await refresh() }
            catch { guard scope == captured else { return }; failure = "Completion could not be loaded. Your edits are kept." }
        }
        .onDisappear { clear() }
        .sheet(isPresented: $showing, onDismiss: { Task { await model?.load(); await refresh() } }) {
            WorkflowShell(title: "Saved subtask actions") { ChildTaskCompletionRecoveryView() }
        }
    }
    private func clear() { presentation = UUID(); reading = false; model?.close(); model = nil; modelScope = nil; read = nil; failure = nil; showing = false }
    private func refresh() async {
        guard let captured = scope, captured == modelScope, !reading, store.online else { return }
        let ticket = presentation; reading = true; defer { if ticket == presentation { reading = false } }
        do {
            await store.sync()
            guard scope == captured, modelScope == captured, presentation == ticket, !Task.isCancelled else { return }
            let value = try await store.readChildTaskRecords(rootID)
            guard scope == captured, modelScope == captured, presentation == ticket, !Task.isCancelled else { return }
            read = value; failure = nil
        } catch { guard scope == captured, modelScope == captured, presentation == ticket, !Task.isCancelled else { return }; read = nil; failure = "Refresh completion when connected with editing access." }
    }
}

struct ChildTaskCompletionRecoveryView: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var model: ChildTaskCompletionRecoveryModel?
    @State private var modelScope: ChildTaskFieldClientScope?
    @State private var stopping: ChildTaskCompletionCommand?
    @State private var reviewing: ChildTaskCompletionJournalState.Entry?
    @State private var failure: String?
    @State private var targetReadRevision = UUID()
    @State private var targetNames: [String: String] = [:]
    private var scope: ChildTaskFieldClientScope? { phase == .active ? store.childTaskFieldRecoveryScope : nil }
    private var targetRequest: ChildCompletionTargetsRequest {
        .init(scope: scope, requests: modelScope == scope ? (model?.entries.map(\.command.id) ?? []) : [], revision: targetReadRevision, online: store.online, enabled: store.childTaskFieldEditingEnabled)
    }
    private var orderedEntries: [ChildTaskCompletionJournalState.Entry] {
        func priority(_ phase: ChildTaskCompletionJournalState.Phase) -> Int {
            switch phase { case .queued, .attempted: return 0; case .closed: return 1; case .confirmed: return 2 }
        }
        return (model?.entries ?? []).enumerated().sorted {
            let left = priority($0.element.phase), right = priority($1.element.phase)
            if left != right { return left < right }
            return left == 0 ? $0.offset < $1.offset : $0.offset > $1.offset
        }.map(\.element)
    }
    var body: some View {
        List {
            Section {
                Text("Each saved action belongs to its original account and subtask. Retrying uses the same request.").foregroundStyle(.secondary)
                Text("Older confirmations are cleared automatically. Pending and stopped actions stay here until reviewed.").font(.footnote).foregroundStyle(.secondary)
            }
            if let model, scope != nil, scope == modelScope {
                if let message = model.message { Section { ChildCompletionNotice(message: message, announces: reviewing == nil).accessibilityIdentifier("childCompletionRecoveryStatus") } }
                if model.loaded, model.entries.isEmpty { ContentUnavailableView("All clear", systemImage: "checkmark.circle", description: Text("Saved subtask actions will appear here.")) }
                ForEach(orderedEntries, id: \.command.id) { entry in
                    Section {
                        Label(entry.command.isUndo ? "Undo subtask action" : entry.command.body["action"] == .string("complete") ? "Complete subtask" : "Reopen subtask", systemImage: entry.command.isUndo ? "arrow.uturn.backward" : "checkmark.circle")
                            .font(.headline)
                        Text(targetNames[entry.command.id] ?? "Review the current subtask when connected.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).privacySensitive()
                        Text(status(entry.phase)).foregroundStyle(.secondary)
                        if entry.phase == .queued || entry.phase == .attempted {
                            Button(entry.phase == .queued ? "Send saved action" : "Retry original action", systemImage: "arrow.up.circle") { Task { await model.send(entry.command) } }
                                .disabled(model.busy || !store.permitsChildTaskCompletionRequest(entry.command, sending: true)).accessibilityIdentifier("sendChildCompletion-" + entry.command.id)
                            Button("Check and stop if pending", systemImage: "hand.raised") { stopping = entry.command }.disabled(model.busy || !store.online)
                        }
                        if entry.phase != .confirmed || !entry.command.isUndo {
                            Button(entry.phase == .closed ? "Review a fresh action" : entry.phase == .confirmed ? "Review Undo" : "Review current subtask", systemImage: "arrow.left.arrow.right") { reviewing = entry }.disabled(model.busy || !store.online || !store.childTaskCompletionEnabled)
                        }
                        if entry.phase != .attempted, !model.entries.contains(where: { $0.command.body["undo_of"] == .string(entry.command.id) }) {
                            Button("Forget saved record", role: .destructive) { Task { await model.discard(entry.command) } }.disabled(model.busy)
                        }
                    }
                }
                if model.busy { ProgressView("Updating saved actions…") }
                if !model.loaded, !model.busy { Button("Read saved actions again") { Task { await model.load() } } }
            } else if let failure { Text(failure) }
            else if scope == nil { ContentUnavailableView("Open your workspace", systemImage: "lock.shield") }
            else { ProgressView("Reading saved actions…") }
        }
        .task(id: scope) {
            model?.close(); model = nil; modelScope = nil; stopping = nil; reviewing = nil; failure = nil
            guard let captured = scope else { return }
            do { let value = try store.childTaskCompletionRecoveryModel(); model = value; modelScope = captured; await value.load() }
            catch { guard scope == captured else { return }; failure = "Saved actions could not be loaded. Your work is kept." }
        }
        .task(id: targetRequest) { await readTargetNames(targetRequest) }
        .onDisappear { targetNames = [:]; model?.close(); model = nil; modelScope = nil; stopping = nil; reviewing = nil }
        .onChange(of: scope) { _, _ in stopping = nil; reviewing = nil }
        .onChange(of: model?.message) { _, _ in targetReadRevision = UUID() }
        .alert("Check this action and stop it if pending?", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } })) {
            Button("Check and stop", role: .destructive) {
                guard let command = stopping, scope == modelScope, let model else { return }; stopping = nil
                Task { await model.resolve(command) }
            }
            Button("Cancel", role: .cancel) { stopping = nil }
        } message: { Text("An action already applied will keep its confirmation. An unapplied action will be permanently stopped; it will need a fresh review before you can try again.") }
        .sheet(isPresented: Binding(get: { reviewing != nil }, set: { if !$0 { reviewing = nil } })) {
            if let entry = reviewing, let model, scope == modelScope {
                WorkflowShell(title: "Review subtask action") { ChildCompletionCurrentReview(entry: entry, model: model) }
            }
        }
    }
    /// Fetch each parent once per live presentation revision, rather than once
    /// per saved action. Names remain in scoped memory and are never journaled.
    private func readTargetNames(_ request: ChildCompletionTargetsRequest) async {
        targetNames = [:]
        guard let captured = request.scope, captured == modelScope, request.online, request.enabled else { return }
        let commands = orderedEntries.map(\.command)
        var visited: Set<String> = []
        for command in commands {
            let root = command.body["task_id"]!.text
            guard visited.insert(root).inserted else { continue }
            do {
                let read = try await store.readChildTaskRecords(root)
                guard request == targetRequest, scope == captured, !Task.isCancelled else { return }
                for candidate in commands where candidate.body["task_id"] == .string(root) {
                    guard read.context.root["task_generation"] == candidate.body["task_generation"], read.context.root["project_id"] == candidate.body["project_id"],
                          let node = read.nodes[candidate.body["node_key"]!.text], candidate.body["incarnation"] == .string(node.incarnation) else { continue }
                    targetNames[candidate.id] = node.fields["title"]?.text ?? "Subtask"
                }
            } catch { guard request == targetRequest, scope == captured, !Task.isCancelled else { return } }
        }
    }
    private func status(_ phase: ChildTaskCompletionJournalState.Phase) -> String {
        switch phase { case .queued: return "Saved · not sent"; case .attempted: return "Unconfirmed · original action kept"; case .confirmed: return "Confirmed · task may have changed since"; case .closed: return "Stopped · cannot send again" }
    }
}

private struct ChildCompletionCurrentReview: View {
    let entry: ChildTaskCompletionJournalState.Entry
    let model: ChildTaskCompletionRecoveryModel
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var read: ChildTaskRecordRead?
    @State private var captured: ChildTaskFieldClientScope?
    @State private var failure: String?
    @State private var feedback: String?
    @State private var presentation = UUID()
    private var scope: ChildTaskFieldClientScope? { phase == .active ? store.childTaskFieldRecoveryScope : nil }
    /// Only an action started in this sheet may create its feedback. A prior
    /// parent-list confirmation must not be repeated as a new review outcome.
    private func act(_ work: () async -> Bool) async {
        guard let current = scope, captured == current else { return }
        let ticket = presentation; feedback = nil
        let finished = await work()
        guard ticket == presentation, scope == current, !Task.isCancelled else { return }
        if finished { dismiss() } else { feedback = model.message }
    }
    private var reviewProblem: String? {
        guard entry.phase == .closed || entry.phase == .confirmed, let read else { return nil }
        if entry.phase == .confirmed, model.entries.contains(where: { $0.command.body["undo_of"] == .string(entry.command.id) && $0.phase != .closed }) {
            return "Undo is already saved for this action. Review its saved record to check the result."
        }
        do {
            if entry.phase == .confirmed, let receipt = entry.receipt {
                _ = try ChildTaskCompletionCommand(undo: entry.command, receipt: receipt, read: read)
            } else if let source = entry.command.original {
                let original = try ChildTaskCompletionCommand(account: entry.command.account, origin: entry.command.origin, body: source.body)
                _ = try ChildTaskCompletionCommand(undo: original, receipt: original.confirmed(source.receipt), read: read)
            } else {
                guard let action = ChildTaskCompletionDraft.Action(rawValue: entry.command.body["action"]!.text) else { return "This action is unavailable." }
                if let node = read.nodes[entry.command.body["node_key"]!.text], let completed = try? ChildTaskCompletionDraft.completed(node.fields), completed == (action == .complete) {
                    return completed ? "This subtask is already completed. No new action is needed." : "This subtask is already open. No new action is needed."
                }
                _ = try ChildTaskCompletionDraft(read: read, key: entry.command.body["node_key"]!.text, action: action)
            }
            return nil
        } catch { return "The subtask has changed since this action. Review it in the editor before making another completion change." }
    }
    private var saveUnavailable: Bool { model.busy || reviewProblem != nil || !store.childTaskCompletionEnabled }
    private var sendUnavailable: Bool { model.busy || !store.permitsChildTaskCompletionRequest(entry.command, sending: true) }
    var body: some View {
        Form {
            if captured == scope, scope != nil, let read, let node = read.nodes[entry.command.body["node_key"]!.text] {
                Section("Current subtask") {
                    Text(node.fields["title"]?.text ?? "Subtask").font(.headline)
                    if let completed = try? ChildTaskCompletionDraft.completed(node.fields) { Text(completed ? "Completed" : "Open") }
                }
                if let reviewProblem { Text(reviewProblem).foregroundStyle(.secondary) }
                if entry.phase == .closed {
                    Section {
                        Text("Save a fresh version of the stopped action using these current values. It will wait in Saved subtask actions for you to send.")
                        Button {
                            Task { await act { await model.replace(entry, read: read) != nil } }
                        } label: { ChildCompletionReviewActionLabel("Save fresh action", image: "tray.and.arrow.down", unavailable: saveUnavailable) }
                            .disabled(saveUnavailable)
                    }
                } else if entry.phase == .queued || entry.phase == .attempted {
                    Section {
                        Text("Sending keeps the original saved action. Current values do not replace it; the service will check whether it can still apply.")
                        Button {
                            Task { await act {
                                await model.send(entry.command)
                                return model.entries.contains { $0.command == entry.command && $0.phase == .confirmed }
                            } }
                        } label: { ChildCompletionReviewActionLabel(entry.phase == .attempted ? "Retry original action" : "Send saved action", image: "arrow.up.circle", unavailable: sendUnavailable) }
                            .disabled(sendUnavailable).accessibilityIdentifier("reviewSendChildCompletion")
                    }
                } else {
                    Section {
                        Text("Undo restores the completion state from before this saved action. It does not change other subtask fields.")
                        Button {
                            let previous = Set(model.entries.map(\.command.id))
                            Task { await act {
                                await model.undo(entry, read: read)
                                return model.entries.contains { !previous.contains($0.command.id) && $0.command.body["undo_of"] == .string(entry.command.id) && $0.phase == .confirmed }
                            } }
                        } label: { ChildCompletionReviewActionLabel("Undo this action", image: "arrow.uturn.backward", unavailable: saveUnavailable) }
                            .disabled(saveUnavailable).accessibilityIdentifier("reviewUndoChildCompletion")
                    }
                }
                if let feedback { ChildCompletionNotice(message: feedback).accessibilityIdentifier("childCompletionReviewStatus") }
            } else if let failure { Text(failure) }
            else { ProgressView("Reading current subtask…") }
        }
        .task(id: scope) {
            presentation = UUID(); feedback = nil; read = nil; captured = nil; failure = nil; guard let current = scope else { return }; captured = current
            do {
                await store.sync(); guard scope == current, !Task.isCancelled else { return }
                let value = try await store.readChildTaskRecords(entry.command.body["task_id"]!.text)
                guard scope == current, !Task.isCancelled else { return }
                guard value.context.root["task_generation"] == entry.command.body["task_generation"], value.context.root["project_id"] == entry.command.body["project_id"],
                      let node = value.nodes[entry.command.body["node_key"]!.text], entry.command.body["incarnation"] == .string(node.incarnation) else {
                    failure = "The original subtask is no longer available. Your saved action is kept."; return
                }
                read = value
            } catch { guard scope == current, !Task.isCancelled else { return }; failure = "Current values aren’t available. Your saved action is kept." }
        }
        .onDisappear { presentation = UUID(); feedback = nil; read = nil; captured = nil }
        .privacySensitive()
    }
}

private struct ChildCompletionNotice: View {
    let message: String
    var announces = true
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Text(message).fixedSize(horizontal: false, vertical: true)
            .task(id: announces ? message : nil) {
                guard phase == .active, announces else { return }
                var announcement = AttributedString(message)
                announcement.accessibilitySpeechAnnouncementPriority = .high
                AccessibilityNotification.Announcement(announcement).post()
            }
    }
}

private struct ChildCompletionReviewActionLabel: View {
    let title: String
    let image: String
    let unavailable: Bool
    init(_ title: String, image: String, unavailable: Bool) { self.title = title; self.image = image; self.unavailable = unavailable }
    var body: some View {
        Label(title, systemImage: image).foregroundStyle(unavailable ? Color.secondary : Color.accentColor)
    }
}
