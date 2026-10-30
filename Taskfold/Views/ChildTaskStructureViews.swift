import SwiftUI

private enum HierarchyReviewSource {
    case add, move(String), remove(String), draft(ChildTaskStructureDraft), saved(ChildTaskStructureJournalState.Entry), archive(ChildTaskStructureReceipt)
}
private struct HierarchyReviewRequest: Identifiable {
    let id = UUID()
    let root: String
    let source: HierarchyReviewSource
    var opening: ChildTaskStructureOpening? = nil
}
private struct HierarchyTargetRequest: Hashable {
    let scope: ChildTaskFieldClientScope?
    let requests: [String]
    let revision: UUID
    let online: Bool
    let tasks: Int
    let snapshot: UUID
}
private struct HierarchyConfirmation {
    enum Action { case stop(ChildTaskStructureCommand), dispose(ChildTaskStructureReceipt), forget(ChildTaskStructureCommand), cancel(ChildTaskStructureJournalState.Disposal) }
    let action: Action
    let model: ChildTaskStructurePresentation
    let scope: ChildTaskFieldClientScope
    var title: String {
        switch action { case .stop: return "Check and stop this action?"; case .dispose: return "Remove saved Undo content?"; case .forget: return "Remove saved history?"; case .cancel: return "Keep this Undo content?" }
    }
    var buttonTitle: String {
        switch action { case .stop: return "Check and stop"; case .dispose: return "Remove Undo content"; case .forget: return "Remove history"; case .cancel: return "Keep Undo content" }
    }
    var destructive: Bool { if case .cancel = action { return false }; return true }
    var explanation: String {
        switch action {
        case .stop: return "An action already applied keeps its confirmation. An unapplied action will be permanently stopped and needs a fresh review."
        case .dispose: return "This permanently removes the saved copy of deleted subtasks. You will no longer be able to restore that copy. Current tasks are unchanged."
        case .forget: return "This removes local recovery history, including its settled Undo records. It does not change your tasks or remove saved deleted content."
        case .cancel: return "The removal has not been sent. Cancelling it keeps the deleted content available for Undo."
        }
    }
}

struct ChildTaskStructureLink: View {
    let rootID: String
    @Environment(Store.self) private var store
    @State private var showing = false
    var body: some View {
        if store.childTaskStructureEditingEnabled, store.childTaskFieldRecoveryScope != nil, store.record("tasks", id: rootID) != nil {
            Button("Organize saved subtasks", systemImage: "list.bullet.indent") { showing = true }
                .accessibilityIdentifier("organizeIndependentChildren")
                .sheet(isPresented: $showing) { WorkflowShell(title: "Organize subtasks") { ChildTaskStructureView(rootID: rootID) } }
        }
    }
}
struct SavedChildTaskStructureLink: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var visible = false
    @State private var showing = false
    @State private var revision = UUID()
    private var scope: ChildTaskFieldClientScope? { phase == .active ? store.childTaskFieldRecoveryScope : nil }
    var body: some View {
        Group {
            if scope != nil, visible || Bundle.main.object(forInfoDictionaryKey: "TaskfoldChildStructureReadsEnabled") as? Bool == true {
                Section { Button("Saved hierarchy actions", systemImage: "square.stack.3d.up") { showing = true }.accessibilityIdentifier("savedChildStructure") }
            }
        }
        .task(id: scope) { await discover() }
        .task(id: revision) { await discover() }
        .sheet(isPresented: $showing, onDismiss: { revision = UUID() }) { WorkflowShell(title: "Saved hierarchy actions") { ChildTaskStructureRecoveryView() } }
    }
    private func discover() async {
        visible = false; guard let captured = scope else { return }
        do {
            let state = try await store.childTaskStructureJournal(account: captured.account, origin: captured.origin).load()
            guard captured == scope, !Task.isCancelled else { return }; let drafts = try await store.childTaskStructureDraftJournal(account: captured.account, origin: captured.origin).load()
            guard captured == scope, !Task.isCancelled else { return }
            visible = !state.entries.isEmpty || !state.disposals.isEmpty || !drafts.entries.isEmpty
        } catch { guard captured == scope, !Task.isCancelled else { return }; visible = true }
    }
}

struct ChildTaskStructureView: View {
    let rootID: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var model: ChildTaskStructurePresentation?
    @State private var modelScope: ChildTaskFieldClientScope?
    @State private var read: ChildTaskStructureRead?
    @State private var review: HierarchyReviewRequest?
    @State private var recovery = false
    @State private var appeared = false
    @State private var reading = false
    @State private var ticket = UUID()
    @State private var failure: String?
    @State private var notice: String?
    private var scope: ChildTaskFieldClientScope? { phase == .active ? store.childTaskFieldRecoveryScope : nil }
    private var pending: Bool { model?.entries.contains { $0.command.body["task_id"] == .string(rootID) && ($0.phase == .queued || $0.phase == .attempted) } == true }
    var body: some View {
        List {
            if let failure { Section { Text(failure).foregroundStyle(.secondary) } }
            if let model, modelScope == scope, scope != nil {
                Section("Unfinished drafts") {
                    if let failure = model.draftsFailure {
                        Text(failure).foregroundStyle(.secondary)
                        Button("Read drafts again") { Task { await model.load() } }.disabled(model.busy)
                    } else if model.drafts.filter({ $0.body["task_id"] == .string(rootID) }).isEmpty { Text("No unfinished drafts").font(.footnote).foregroundStyle(.secondary) }
                    ForEach(model.drafts.filter { $0.body["task_id"] == .string(rootID) }, id: \.hierarchyRecoveryRowID) { draft in
                        ChildHierarchyDraftRow(draft: draft, model: model, targetTitle: currentDraftTitle(draft)) {
                            review = .init(root: rootID, source: .draft(draft))
                        }
                    }
                }
            }
            if let read, modelScope == scope, scope != nil {
                Section {
                    Text(read.context.root.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text("Arrange the saved hierarchy. Unsent field edits stay separate.").font(.footnote).foregroundStyle(.secondary)
                    Button("Add subtask", systemImage: "plus") { review = .init(root: rootID, source: .add, opening: try? .init(read: read)) }
                        .disabled(pending || model?.busy == true).accessibilityIdentifier("childStructureAdd")
                }
                if read.records.orderedNodes.isEmpty { ContentUnavailableView("Room for your next step", systemImage: "list.bullet", description: Text("Add a subtask to start shaping this task.")) }
                ForEach(read.records.orderedNodes, id: \.hierarchyRecoveryRowID) { node in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(node.fields["title"]?.text ?? "Subtask", systemImage: TaskKind(Record(node.fields)) == .heading ? "textformat" : "circle")
                            .font(.body).fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(node.fields["title"]?.text ?? "Subtask"), level \(node.path.count)")
                            .accessibilityIdentifier("childStructureNode-" + node.key)
                        HStack(spacing: 16) {
                            Button { review = .init(root: rootID, source: .move(node.key), opening: try? .init(read: read, node: node.key)) } label: { Label("Move", systemImage: "arrow.up.arrow.down").frame(minHeight: 44) }
                                .accessibilityIdentifier("moveChildStructure-" + node.key)
                            Button(role: .destructive) { review = .init(root: rootID, source: .remove(node.key), opening: try? .init(read: read, node: node.key)) } label: { Label("Remove", systemImage: "minus.circle").frame(minHeight: 44) }
                                .accessibilityIdentifier("removeChildStructure-" + node.key)
                        }.font(.callout).buttonStyle(.borderless)
                            .disabled(pending || model?.busy == true)
                    }.padding(.leading, CGFloat(min(node.path.count - 1, 5)) * 12).padding(.vertical, 5)
                }
                if pending { Section { Label("A saved action needs attention", systemImage: "tray"); Text("Review it before arranging more subtasks.").font(.footnote).foregroundStyle(.secondary) } }
            } else if reading { ProgressView("Reading saved subtasks…") }
            Section {
                Button("Saved hierarchy actions", systemImage: "tray") { recovery = true }.accessibilityIdentifier("childStructureRecovery")
                Button("Refresh subtasks", systemImage: "arrow.clockwise") { Task { await model?.load(); await refresh(sync: true) } }.disabled(reading || model?.busy == true || !store.online)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let notice {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) {
                            HierarchyNotice(message: notice).accessibilityIdentifier("childStructureNotice")
                            HStack { Spacer(minLength: 0); noticeButtons }
                        }
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            HierarchyNotice(message: notice).accessibilityIdentifier("childStructureNotice")
                            Spacer(minLength: 0)
                            noticeButtons
                        }
                    }
                }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal).padding(.vertical, 8)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("childStructureStatusCard")
            }
        }
        .privacySensitive()
        .onAppear { appeared = true }
        .task(id: scope) { if model == nil || modelScope != scope { await open() } }
        .onDisappear { appeared = false; if review == nil && !recovery { clear() } }
        .sheet(item: $review, onDismiss: { Task { await returned() } }) { request in
            if let model, modelScope == scope { ChildHierarchyReviewView(request: request, model: model, feedback: { notice = $0 }) }
        }
        .sheet(isPresented: $recovery, onDismiss: { Task { await returned() } }) { WorkflowShell(title: "Saved hierarchy actions") { ChildTaskStructureRecoveryView() } }
    }
    private var noticeButtons: some View {
        HStack(spacing: 12) {
            Button { recovery = true } label: { Image(systemName: "tray").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }.accessibilityLabel("Open saved hierarchy actions")
            Button { notice = nil } label: { Image(systemName: "xmark.circle.fill").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }.accessibilityLabel("Dismiss status")
        }
    }
    private func currentDraftTitle(_ draft: ChildTaskStructureDraft) -> String? {
        guard store.online, let read else { return nil }
        return ChildTaskStructureDraftTargetTitle(draft: draft, read: read)?.value(for: draft, scope: scope, snapshot: store.snapshotRevision)
    }
    private func clear() { ticket = UUID(); model?.close(); model = nil; read = nil; modelScope = nil; reading = false; review = nil; recovery = false }
    private func sameSession(_ a: ChildTaskFieldClientScope?, _ b: ChildTaskFieldClientScope?) -> Bool {
        guard let a, let b else { return false }; return a.account == b.account && a.origin == b.origin && a.workspace == b.workspace && a.session == b.session
    }
    private func open() async {
        let old = modelScope
        if !sameSession(old, scope) { notice = nil }
        clear(); failure = nil; guard let captured = scope else { return }
        do {
            let value = try store.childTaskStructurePresentation(); model = value; modelScope = captured; await value.load()
            guard modelScope == scope, !Task.isCancelled else { return }; await refresh(sync: false)
        } catch { guard scope == captured else { return }; failure = "Saved subtasks could not be read. Your work is unchanged." }
    }
    private func returned() async {
        await Task.yield()
        guard appeared, let owner = model, let captured = scope, modelScope == captured else { clear(); return }
        let before = Dictionary(uniqueKeysWithValues: owner.entries.map { ($0.command.id, $0.phase) })
        let beforeDisposals = Dictionary(uniqueKeysWithValues: owner.disposals.map { ($0.id, $0.phase) })
        await owner.load()
        guard captured == scope, owner === model else { return }
        let affected = owner.entries.filter { $0.command.body["task_id"] == .string(rootID) && before[$0.command.id] != $0.phase }
        if owner.disposals.contains(where: { $0.source.raw["task_id"] == .string(rootID) && $0.phase == .confirmed && beforeDisposals[$0.id] != .confirmed }) { notice = "Saved Undo content removed." }
        else if affected.contains(where: { $0.phase == .confirmed }) { notice = "Hierarchy change confirmed." }
        else if affected.contains(where: { $0.phase == .attempted }) { notice = "Action needs attention." }
        else if affected.contains(where: { $0.phase == .closed }) { notice = "Action stopped." }
        else if affected.contains(where: { $0.phase == .queued }) { notice = "Fresh action saved." }
        await refresh(sync: true)
    }
    private func refresh(sync: Bool) async {
        guard let captured = scope, captured == modelScope, !reading else { return }
        let token = ticket; reading = true; defer { if token == ticket { reading = false } }
        guard captured == scope, token == ticket, !Task.isCancelled else { return }
        do {
            let value = try await store.readCurrentChildTaskStructure(rootID)
            guard captured == scope, token == ticket, !Task.isCancelled else { return }; read = value; failure = nil
        } catch { guard captured == scope, token == ticket, !Task.isCancelled else { return }; read = nil; failure = "Refresh when connected with access to this task. Saved actions and unsent edits are kept." }
    }
}

struct ChildTaskStructureRecoveryView: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var model: ChildTaskStructurePresentation?
    @State private var modelScope: ChildTaskFieldClientScope?
    @State private var confirmation: HierarchyConfirmation?
    @State private var review: HierarchyReviewRequest?
    @State private var appeared = false
    @State private var targetNames: [String: String] = [:]
    @State private var draftTargetNames: [String: ChildTaskStructureDraftTargetTitle] = [:]
    @State private var targetRevision = UUID()
    @State private var synchronizedTargetRevision: UUID?
    @State private var failure: String?
    private var scope: ChildTaskFieldClientScope? { phase == .active ? store.childTaskFieldRecoveryScope : nil }
    private var targetRequest: HierarchyTargetRequest {
        // snapshotRevision is intentionally not observable itself.
        _ = store.snapshot
        return .init(scope: scope, requests: modelScope == scope ? (model?.entries.map(\.command.id) ?? []) + (model?.drafts.map { $0.id + $0.token.uuidString } ?? []) : [], revision: targetRevision, online: store.online, tasks: store.taskRevision, snapshot: store.snapshotRevision)
    }
    private var ordered: [ChildTaskStructureJournalState.Entry] {
        (model?.entries ?? []).enumerated().sorted {
            func rank(_ phase: ChildTaskStructureJournalState.Phase) -> Int { phase == .queued || phase == .attempted ? 0 : phase == .closed ? 1 : 2 }
            let a = rank($0.element.phase), b = rank($1.element.phase)
            return a == b ? (a == 0 ? $0.offset < $1.offset : $0.offset > $1.offset) : a < b
        }.map(\.element)
    }
    var body: some View {
        List {
            Section { Text("Review saved actions and their current tasks. Retrying keeps the original action.").foregroundStyle(.secondary) }
            if let model, modelScope == scope, scope != nil {
                Section("Unfinished drafts") {
                    if let failure = model.draftsFailure {
                        Text(failure).foregroundStyle(.secondary)
                        Button("Read drafts again") { Task { await model.load() } }.disabled(model.busy)
                    } else if model.drafts.isEmpty { Text("No unfinished drafts").font(.footnote).foregroundStyle(.secondary) }
                    ForEach(model.drafts, id: \.hierarchyRecoveryRowID) { draft in
                        ChildHierarchyDraftRow(draft: draft, model: model, targetTitle: store.online ? draftTargetNames[draft.id]?.value(for: draft, scope: scope, snapshot: store.snapshotRevision) : nil) {
                            review = .init(root: draft.body["task_id"]!.text, source: .draft(draft))
                        }
                    }
                }
            }
            if let model, modelScope == scope, scope != nil {
                if let message = model.message { Section { HierarchyNotice(message: message, announces: review == nil).accessibilityIdentifier("childStructureRecoveryStatus") } }
                if model.loaded, model.entries.isEmpty, model.disposals.isEmpty { ContentUnavailableView("No saved actions", systemImage: "checkmark.circle", description: Text("Unfinished drafts appear separately.")) }
                ForEach(ordered, id: \.hierarchyRecoveryRowID) { entry in
                    Section {
                        Label(ChildTaskStructureReview.title(entry.command), systemImage: entry.command.action == .undo ? "arrow.uturn.backward" : entry.phase == .attempted ? "clock.badge.questionmark" : "square.stack.3d.up")
                            .font(.headline)
                        Text(taskName(entry.command.body)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let target = targetNames[entry.command.id] { Text(target).fixedSize(horizontal: false, vertical: true) }
                        if let title = entry.command.body["node"]?.object["title"]?.text { Text(title).fixedSize(horizontal: false, vertical: true) }
                        Text(ChildTaskStructureReview.status(entry.phase)).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("childStructurePhase-" + entry.command.id)
                        if entry.phase == .queued || entry.phase == .attempted {
                            Button(entry.phase == .queued ? "Send saved action" : "Retry original action", systemImage: "arrow.up.circle") { Task { _ = await model.send(entry.command) } }
                                .disabled(model.busy || !store.permitsChildTaskStructureRequest(entry.command, sending: true)).accessibilityIdentifier("sendChildStructure-" + entry.command.id)
                            Button("Check and stop if pending", systemImage: "hand.raised") { confirm(.stop(entry.command), model) }.disabled(model.busy || !store.online)
                        }
                        if entry.phase == .confirmed, entry.command.action != .undo, model.hasUndoOrDisposal(entry.command.id) {
                            Text("Undo is already saved or its content has been removed.").font(.footnote).foregroundStyle(.secondary)
                        } else if entry.command.action != .undo || entry.phase != .confirmed {
                            Button(entry.phase == .confirmed ? "Review Undo" : entry.phase == .closed ? "Review a fresh action" : "Review current values", systemImage: "arrow.left.arrow.right") {
                                review = .init(root: entry.command.body["task_id"]!.text, source: .saved(entry))
                            }.disabled(model.busy || !store.online || !store.childTaskStructureEditingEnabled)
                        }
                        if entry.phase == .confirmed, entry.command.action == .delete, let receipt = entry.receipt, !model.hasUndoOrDisposal(entry.command.id) {
                            Button("Remove saved Undo content…", role: .destructive) { confirm(.dispose(receipt), model) }.disabled(model.busy || !store.online)
                        }
                        if canForget(entry, model) { Button("Remove saved history…", role: .destructive) { confirm(.forget(entry.command), model) }.disabled(model.busy) }
                    }
                }
                ForEach(model.disposals, id: \.hierarchyRecoveryRowID) { item in
                    Section("Saved Undo content") {
                        Text(item.phase == .confirmed ? "Undo content removed" : item.phase == .attempted ? "Removal needs confirmation" : "Removal saved · not sent")
                        if item.phase != .confirmed {
                            Button("Retry content removal", systemImage: "arrow.clockwise") { Task { await model.retryDisposal(item) } }.disabled(model.busy || !store.online)
                            if item.phase == .queued { Button("Keep Undo content") { confirm(.cancel(item), model) }.disabled(model.busy) }
                        }
                    }
                }
                Section("Restore deleted subtasks") {
                    Text("Find saved Undo content for this account, including actions from another device. Current editing access is needed to restore it.").font(.footnote).foregroundStyle(.secondary)
                    Button(model.archivesLoaded ? "Refresh saved Undo" : "Find saved Undo", systemImage: "arrow.clockwise") { Task { await model.discoverArchives() } }
                        .disabled(model.busy || !store.online).accessibilityIdentifier("discoverChildStructureUndo")
                    ForEach(model.availableArchives, id: \.hierarchyRecoveryRowID) { receipt in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(taskName(receipt.raw)).font(.headline)
                            Button { review = .init(root: receipt.raw["task_id"]!.text, source: .archive(receipt)) } label: {
                                Label("Review restore", systemImage: "arrow.uturn.backward").frame(minHeight: 44)
                            }.disabled(model.busy || !store.online || !store.childTaskStructureEditingEnabled)
                            Button(role: .destructive) { confirm(.dispose(receipt), model) } label: {
                                Text("Remove saved Undo content…").frame(minHeight: 44)
                            }.disabled(model.busy || !store.online)
                        }.buttonStyle(.borderless)
                    }
                }
                if model.busy { ProgressView("Updating saved actions…") }
            } else if let failure { Text(failure).foregroundStyle(.secondary) }
            else if scope == nil { ContentUnavailableView("Open your workspace", systemImage: "lock.shield") }
            else { ProgressView("Reading saved actions…") }
        }
        .privacySensitive()
        .onAppear { appeared = true }
        .task(id: scope) {
            if model != nil, modelScope == scope { return }
            clear(); guard let captured = scope else { return }
            do { let value = try store.childTaskStructurePresentation(); model = value; modelScope = captured; await value.load() }
            catch { guard captured == scope else { return }; failure = "Saved hierarchy actions could not be loaded. Your work is kept." }
        }
        .task(id: targetRequest) { await readTargetNames(targetRequest) }
        .onChange(of: model?.message) { _, _ in targetRevision = UUID() }
        .onDisappear { appeared = false; if review == nil { clear() } }
        .alert(confirmation?.title ?? "Review action", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            Button(confirmation?.buttonTitle ?? "Continue", role: confirmation?.destructive == true ? .destructive : nil) { executeConfirmation() }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: { Text(confirmation?.explanation ?? "") }
        .sheet(item: $review, onDismiss: { targetRevision = UUID(); Task { await Task.yield(); if !appeared { clear() } else { await model?.load() } } }) { request in
            if let model, scope == modelScope { ChildHierarchyReviewView(request: request, model: model) }
        }
    }
    private func clear() { model?.close(); model = nil; modelScope = nil; confirmation = nil; review = nil; failure = nil; targetNames = [:]; draftTargetNames = [:]; synchronizedTargetRevision = nil }
    private func readTargetNames(_ request: HierarchyTargetRequest) async {
        targetNames = [:]; draftTargetNames = [:]
        guard let captured = request.scope, captured == modelScope, request.online else { synchronizedTargetRevision = nil; return }
        // Sync once for a user/action revision. A sync changes the snapshot;
        // the replacement read task must not start an endless sync/read loop.
        if synchronizedTargetRevision != request.revision {
            synchronizedTargetRevision = request.revision
            do { try await store.synchronizeChildTaskStructureReads() } catch { return }
        }
        guard request == targetRequest, scope == captured, !Task.isCancelled else { return }
        let entries = ordered, drafts = model?.drafts ?? []
        let roots = Set(entries.map { $0.command.body["task_id"]!.text } + drafts.map { $0.body["task_id"]!.text })
        for root in roots.sorted() {
            do {
                let read = try await store.readChildTaskStructure(root)
                guard request == targetRequest, scope == captured, !Task.isCancelled else { return }
                for draft in drafts where draft.body["task_id"] == .string(root) {
                    draftTargetNames[draft.id] = ChildTaskStructureDraftTargetTitle(draft: draft, read: read)
                }
                for candidate in entries where candidate.command.body["task_id"] == .string(root) {
                    let command = candidate.command
                    guard read.context.root["task_generation"] == command.body["task_generation"], read.context.root["project_id"] == command.body["project_id"] else { continue }
                    let key = command.body["node_key"]?.text ?? command.original?.receipt["node_key"]?.text ?? ""
                    let incarnation = candidate.receipt?.raw["incarnation"] ?? command.body["incarnation"] ?? command.original?.receipt["incarnation"]
                    guard let node = read.records.nodes[key], incarnation == .string(node.incarnation) else { continue }
                    targetNames[command.id] = node.fields["title"]?.text ?? "Subtask"
                }
            } catch { guard request == targetRequest, scope == captured, !Task.isCancelled else { return } }
        }
    }
    private func taskName(_ body: [String: JSON]) -> String {
        guard let root = store.record("tasks", id: body["task_id"]!.text), root["task_generation"] == body["task_generation"], root["project_id"] == body["project_id"] else { return "Original task unavailable" }
        return root.title
    }
    private func canForget(_ entry: ChildTaskStructureJournalState.Entry, _ model: ChildTaskStructurePresentation) -> Bool {
        guard entry.phase != .attempted else { return false }
        if entry.phase == .confirmed, entry.command.action == .delete { return model.disposals.contains { $0.id == entry.command.id && $0.phase == .confirmed } }
        return !model.entries.contains { $0.command.body["undo_of"] == .string(entry.command.id) }
    }
    private func confirm(_ action: HierarchyConfirmation.Action, _ model: ChildTaskStructurePresentation) { guard let scope, scope == modelScope else { return }; confirmation = .init(action: action, model: model, scope: scope) }
    private func executeConfirmation() {
        guard let value = confirmation, value.scope == scope, value.model === model else { confirmation = nil; return }
        confirmation = nil
        Task {
            switch value.action { case .stop(let command): await value.model.stop(command); case .dispose(let receipt): await value.model.dispose(receipt); case .forget(let command): await value.model.discard(command); case .cancel(let item): await value.model.cancelUnsentDisposal(item) }
        }
    }
}

private struct ChildHierarchyDraftRow: View {
    let draft: ChildTaskStructureDraft
    let model: ChildTaskStructurePresentation
    var targetTitle: String? = nil
    var resume: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var removing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(draft.body["action"] == .string("move") ? targetTitle ?? "Move subtask" : draft.body["title"]!.text.isEmpty ? "Untitled subtask" : draft.body["title"]!.text)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("childStructureDraftTitle-" + draft.id)
            if draft.body["action"] == .string("move"), targetTitle != nil { Text("Move subtask").font(.caption).foregroundStyle(.secondary) }
            Text(draft.pendingCommand == nil ? "Kept on this device; no action sent." : "Original action kept for recovery; check saved actions before retrying.")
                .font(.footnote).foregroundStyle(.secondary)
            Group {
                if textSize.isAccessibilitySize { VStack(alignment: .leading, spacing: 8) { actions } }
                else { HStack(spacing: 16) { actions } }
            }.buttonStyle(.borderless).disabled(model.busy)
        }.padding(.vertical, 4)
            .alert("Discard this unfinished draft?", isPresented: $removing) {
                Button("Discard draft", role: .destructive) { Task { await model.discardDraft(draft) } }
                Button("Cancel", role: .cancel) { removing = false }
            } message: { Text("This removes only the unfinished draft on this device. It does not change tasks or remove an action already saved in Saved hierarchy actions.") }
    }
    @ViewBuilder private var actions: some View {
        Button(action: resume) { Text("Resume").frame(minHeight: 44).contentShape(Rectangle()) }
            .accessibilityIdentifier("resumeChildStructureDraft-" + draft.id)
        Button(role: .destructive) { removing = true } label: { Text("Discard").frame(minHeight: 44).contentShape(Rectangle()) }
            .accessibilityIdentifier("discardChildStructureDraft-" + draft.id)
    }
}

private struct ChildHierarchyReviewView: View {
    let request: HierarchyReviewRequest
    let model: ChildTaskStructurePresentation
    var feedback: (String) -> Void = { _ in }
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var read: ChildTaskStructureRead?
    @State private var composer: ChildTaskStructureDraftSession?
    @State private var acting = false
    @State private var checkpointFailure = false
    @State private var title = ""
    @State private var newID = UUID()
    @State private var parent = ""
    @State private var index = 0
    @State private var failure: String?
    @State private var captured: ChildTaskFieldClientScope?
    @FocusState private var titleFocused: Bool
    private var scope: ChildTaskFieldClientScope? { phase == .active ? store.childTaskFieldRecoveryScope : nil }
    private var saved: ChildTaskStructureJournalState.Entry? { if case .saved(let value) = request.source { return value }; return nil }
    private var moving: String? {
        switch request.source { case .draft(let value) where value.body["action"] == .string("move"): return value.body["node_key"]!.text; case .move(let key): return key; case .saved(let value) where value.command.action == .move: return value.command.body["node_key"]!.text; default: return nil }
    }
    private var placement: Bool { if case .add = request.source { return true }; if case .draft(let value) = request.source, value.body["action"] == .string("insert") { return true }; return moving != nil || saved?.command.action == .insert }
    private var proposal: ChildTaskStructureCommand? {
        guard let read, captured == scope, scope == model.scope else { return nil }
        return try? make(read)
    }
    private func make(_ read: ChildTaskStructureRead) throws -> ChildTaskStructureCommand {
        switch request.source {
        case .add, .move, .remove:
            guard let opening = request.opening else { throw ChildTaskStructureCommand.invalid }; try opening.validate(read)
        default: break
        }
        if let draft = composer?.draft { return try draft.pendingCommand ?? draft.reviewedCommand(read) }
        switch request.source {
        case .draft: throw ChildTaskStructureDraft.invalid
        case .add: return try .init(insert: .object(["id": .string(newID.uuidString.lowercased()), "title": .string(title)]), parent: parent.isEmpty ? nil : parent, index: index, read: read, requestID: newID)
        case .move(let key): return try .init(move: key, parent: parent.isEmpty ? nil : parent, index: index, read: read, requestID: newID)
        case .remove(let key): return try .init(delete: key, read: read, requestID: newID)
        case .archive(let receipt):
            guard !model.hasUndoOrDisposal(receipt.raw["request_id"]!.text) else { throw ChildTaskStructureCommand.invalid }
            return try .init(restoring: receipt, read: read, requestID: newID)
        case .saved(let entry):
            if entry.phase == .queued || entry.phase == .attempted { try entry.command.review(read); return entry.command }
            if entry.phase == .confirmed { guard !model.hasUndoOrDisposal(entry.command.id), let receipt = entry.receipt else { throw ChildTaskStructureCommand.invalid }; return try .init(undo: entry.command, receipt: receipt, read: read, requestID: newID) }
            return try ChildTaskStructureReview.fresh(entry.command, read: read, parent: parent.isEmpty ? nil : parent, index: index, requestID: newID)
        }
    }
    private var reviewProblem: String {
        switch request.source {
        case .add: return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Add a title to continue." : "Choose a supported title and destination. Your current work is kept."
        case .draft: return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && moving == nil ? "Add a title to continue." : "Review a current destination and position. Your saved draft stays unchanged until you choose them."
        case .move: return "Choose a different parent or position. A subtask cannot move inside itself."
        case .remove: return "This subtask changed. Reopen its current details before removing it."
        case .archive: return "This saved Undo is no longer available for the current hierarchy. Keep its content, or explicitly remove it from Saved hierarchy actions."
        case .saved(let entry):
            if entry.phase == .confirmed { return "The hierarchy changed after this action, or Undo is already saved. Your current work is kept." }
            if entry.phase == .closed { return "The original target or destination changed. Open the current task to choose a new action." }
            return "The saved action needs a new review. Check and stop it if pending before saving a fresh action."
        }
    }
    var body: some View {
        NavigationStack {
            form.navigationTitle("Review hierarchy change")
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { Task { await closeReview() } }
                        .disabled(acting || model.busy)
                } }
        }
        #if os(macOS)
        .frame(minWidth: 580, idealWidth: 640, minHeight: 500, idealHeight: 620)
        #endif
    }
    private var form: some View {
        Form {
            if let composer, let draft = composer.draft, captured == scope, scope != nil {
                if draft.body["action"] == .string("insert") {
                    Section {
                        TextField("Subtask title", text: Binding(get: { title }, set: { title = $0; checkpoint() }), axis: .vertical)
                            .focused($titleFocused).disabled(draft.pendingCommand != nil || acting).accessibilityIdentifier("childStructureNewTitle")
                    }
                }
                Section {
                    if composer.saving { ProgressView("Saving draft…") }
                    else if let message = composer.message { Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("childStructureDraftStatus") }
                    else if draft.pendingCommand != nil { Text("This action keeps its original contents. Finish saving it, or review Saved hierarchy actions.").foregroundStyle(.secondary) }
                    else { Text("Unfinished changes stay on this device. Saving an action is separate.").foregroundStyle(.secondary) }
                }
            }
            if let read, scope != nil, captured == scope, scope == model.scope {
                Section { Text(read.context.root.title).font(.headline); Text("Review the current saved hierarchy before applying this change.").font(.footnote).foregroundStyle(.secondary) }
                if placement, composer?.draft?.pendingCommand == nil, saved == nil || saved?.phase == .closed {
                    Section("Destination") {
                        Picker("Parent", selection: Binding(get: { parent }, set: { parent = $0; index = 0; checkpoint(placement: true) })) {
                            Text("Top level").tag("")
                            ForEach(ChildTaskStructureReview.destinations(read, moving: moving), id: \.key) { node in Text(String(repeating: "  ", count: node.path.count - 1) + (node.fields["title"]?.text ?? "Subtask")).tag(node.key) }
                            if !parent.isEmpty, !ChildTaskStructureReview.destinations(read, moving: moving).contains(where: { $0.key == parent }) { Text("Saved destination unavailable").tag(parent) }
                        }.accessibilityIdentifier("childStructureParent")
                        Picker("Position", selection: Binding(get: { index }, set: { index = $0; checkpoint(placement: true) })) {
                            let siblings = ChildTaskStructureReview.siblings(read, parent: parent.isEmpty ? nil : parent, moving: moving)
                            ForEach(Array(siblings.enumerated()), id: \.element.key) { position, node in Text("Before \(node.fields["title"]?.text ?? "subtask")").tag(position) }
                            Text("At end").tag(siblings.count)
                            if index > siblings.count { Text("Saved position unavailable").tag(index) }
                        }.accessibilityIdentifier("childStructurePosition")
                        if let draft = composer?.draft, draft.body["structure_revision"] != .number(read.structureRevision) {
                            Button("Review this placement") { checkpoint(placement: true) }.accessibilityIdentifier("reviewDraftPlacement")
                        }
                    }.disabled(acting)
                }
                if let command = proposal {
                    Section("Change") {
                        Label(ChildTaskStructureReview.title(command), systemImage: command.action == .undo ? "arrow.uturn.backward" : "square.stack.3d.up")
                        if command.action == .insert { Text(command.body["node"]!.object["title"]!.text).fixedSize(horizontal: false, vertical: true) }
                        else if command.action != .delete, let node = read.records.nodes[command.body["node_key"]?.text ?? command.original?.receipt["node_key"]?.text ?? ""] { Text(node.fields["title"]?.text ?? "Subtask").fixedSize(horizontal: false, vertical: true) }
                        if command.action == .delete {
                            Text(command.body["subtree_versions"]!.object.count == 1 ? "1 item will be removed." : "\(command.body["subtree_versions"]!.object.count) items will be removed, including nested subtasks.")
                            Text("A saved Undo copy can restore this change while the hierarchy remains unchanged. You can remove that saved content later.").font(.footnote).foregroundStyle(.secondary)
                        }
                        if command.action == .delete, let branch = read.records.nodes[command.body["node_key"]!.text] {
                            ForEach(read.records.orderedNodes.filter { $0.path.starts(with: branch.path) }, id: \.key) { affected in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(affected.fields["title"]?.text ?? "Subtask").font(.callout)
                                    if let notes = affected.fields["description"]?.text, !notes.isEmpty { Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                                }.padding(.leading, CGFloat(affected.path.count - branch.path.count) * 12).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if command.action == .move { Text("Current notes and other fields move with this subtask.").font(.footnote).foregroundStyle(.secondary) }
                    }
                    Section {
                        Button(composer?.draft?.pendingCommand != nil ? "Finish saving action" : saved?.phase == .closed ? "Save fresh action" : saved == nil || saved?.phase == .confirmed ? "Save action" : "Send original action", systemImage: "checkmark.circle") { act(command) }
                            .buttonStyle(.borderedProminent).frame(minHeight: 44)
                            .disabled(checkpointFailure || acting || model.busy || !store.permitsChildTaskStructureRequest(command, sending: saved?.phase == .queued || saved?.phase == .attempted))
                            .accessibilityIdentifier("childStructureReviewApply")
                        if saved == nil || saved?.phase == .confirmed || saved?.phase == .closed {
                            Text("This saves the reviewed action first. Send it from Saved hierarchy actions when ready.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section { Text(reviewProblem).foregroundStyle(.secondary).accessibilityIdentifier("childStructureReviewProblem") }
                }
            } else if failure == nil { ProgressView("Reading current hierarchy…") }
            if let failure { Section { HierarchyNotice(message: failure) } }
        }
        .privacySensitive().scrollDismissesKeyboard(.interactively)
        .task(id: store.childTaskFieldRecoveryScope) {
            composer?.close(); composer = nil; read = nil; failure = nil
            guard let current = store.childTaskFieldRecoveryScope, current == model.scope else { return }; captured = current
            if case .draft(let value) = request.source {
                do { try beginComposer(value, scope: current, saved: true) }
                catch { failure = "This saved draft could not be opened. Keep it in Saved hierarchy actions."; return }
            }
            do {
                let value = try await store.readCurrentChildTaskStructure(request.root)
                guard captured == scope, scope == model.scope, !Task.isCancelled else { return }
                guard captured == scope, !Task.isCancelled else { return }
                try request.opening?.validate(value)
                if let saved {
                    guard saved.command.body["task_generation"] == value.context.root["task_generation"], saved.command.body["project_id"] == value.context.root["project_id"] else { throw ChildTaskStructureCommand.invalid }
                    parent = saved.command.body["parent_key"]?.text ?? ""; index = saved.command.body["index"]?.integer ?? 0
                } else if composer == nil, let moving, let node = value.records.nodes[moving] { parent = node.parent ?? ""; index = node.position }
                if composer == nil {
                    switch request.source {
                    case .add: try beginComposer(.init(read: value, id: newID), scope: current, saved: false)
                    case .move(let key): try beginComposer(.init(read: value, moving: key, id: newID), scope: current, saved: false)
                    default: break
                    }
                }
                read = value
            } catch { guard captured == scope, !Task.isCancelled else { return }; failure = "Current values aren’t available. Refresh the task when connected; your saved work is kept." }
        }
        .onChange(of: phase) { _, phase in if phase != .active, let composer { Task { _ = await composer.flush() } } }
        .onDisappear { if let composer { Task { _ = await composer.flush() } } }
        .interactiveDismissDisabled(acting || model.busy || composer?.dirty == true || composer?.saving == true)
    }
    private func beginComposer(_ value: ChildTaskStructureDraft, scope: ChildTaskFieldClientScope, saved: Bool) throws {
        composer = try .init(scope: scope, draft: value, saved: saved,
                            journal: store.childTaskStructureDraftJournal(account: scope.account, origin: scope.origin),
                            current: { [weak store] in store?.childTaskFieldRecoveryScope })
        title = value.body["title"]!.text; parent = value.body["parent_key"] == .null ? "" : value.body["parent_key"]!.text
        index = value.body["index"]!.integer; newID = UUID(uuidString: value.id)!
    }
    private func closeReview() async {
        if composer?.draft?.pendingCommand == nil { checkpoint() }
        guard !checkpointFailure else { return }
        if let composer, !(await composer.flush()) { return }
        dismiss()
    }
    private func checkpoint(placement: Bool = false) {
        guard let composer, let draft = composer.draft, captured == store.childTaskFieldRecoveryScope else { return }
        do {
            let next = try draft.editing(title: title, parent: parent.isEmpty ? nil : parent, index: index, placementRead: placement ? read : nil)
            if !AuthoredValueComparison.exactJSON(.object(next.body), .object(draft.body)) { try composer.stage(next) }
            if checkpointFailure { failure = nil }; checkpointFailure = false
        } catch { checkpointFailure = true; failure = "This draft could not be updated. Keep this window open and review its current title and destination." }
    }
    private func act(_ command: ChildTaskStructureCommand) {
        guard let read, captured == scope, scope == model.scope else { return }; titleFocused = false
        acting = true
        Task {
            defer { acting = false }
            if let composer {
                guard let frozen = await composer.prepare(read), captured == scope else { failure = composer.message; return }
                let saved = await model.queueDraftAction(frozen, read: read)
                guard captured == scope else { return }
                if saved {
                    if await composer.finish() { feedback("Action saved."); dismiss() }
                    else { failure = composer.message }
                } else { failure = model.message }
                return
            }
            let success: Bool
            if let saved, saved.phase == .queued || saved.phase == .attempted { success = await model.send(command) }
            else if let saved, saved.phase == .closed { success = await model.replace(saved, with: command, read: read) }
            else { success = await model.queue(command, read: read) }
            guard captured == scope, !Task.isCancelled else { return }
            if success { feedback(saved?.phase == .queued || saved?.phase == .attempted ? model.message ?? "Change confirmed." : "Action saved."); dismiss() } else { failure = model.message }
        }
    }
}
private struct HierarchyNotice: View {
    let message: String
    var announces = true
    @AccessibilityFocusState private var focused: Bool
    var body: some View {
        Text(message).font(.callout).fixedSize(horizontal: false, vertical: true).accessibilityFocused($focused)
            .task(id: message + (announces ? "-visible" : "-covered")) { guard announces else { return }; focused = false; await Task.yield(); guard !Task.isCancelled else { return }; focused = true }
    }
}

// Presentation IDs are separate from transport request IDs. The same request
// can legitimately have a draft, action, archive and disposal row at once.
private extension ChildTaskStructureDraft { var hierarchyRecoveryRowID: String { "draft:" + id } }
private extension ChildTaskStructureJournalState.Entry { var hierarchyRecoveryRowID: String { "action:" + command.id } }
private extension ChildTaskStructureJournalState.Disposal { var hierarchyRecoveryRowID: String { "disposal:" + id } }
private extension ChildTaskStructureReceipt { var hierarchyRecoveryRowID: String { "archive:" + raw["request_id"]!.text } }
private extension ChildTaskRecordRead.Node { var hierarchyRecoveryRowID: String { "node:" + key } }
