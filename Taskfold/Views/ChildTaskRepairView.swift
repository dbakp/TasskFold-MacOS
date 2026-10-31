import SwiftUI
import UniformTypeIdentifiers

struct ChildTaskRepairView: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    @State private var activeID: String?
    @State private var model: ChildTaskRepairModel?
    @State private var modelScope: ChildTaskFieldClientScope?
    @State private var review: ChildTaskAdoptionReview?
    @State private var proposal: ChildTaskRepairPreview?
    @State private var outline: ChildTaskRepairOutline?
    @State private var changes: [ChildTaskRepairChange] = []
    @State private var labels: [String] = []
    @State private var baseDigest: String?
    @State private var draft: ChildTaskRepairDraft?
    @State private var targets: [ChildTaskAdoptionTarget] = []
    @State private var next: String?
    @State private var ticket = UUID()
    @State private var loading = false
    @State private var fetchingOriginal = false
    @State private var failure: String?
    @State private var confirming = false
    @State private var discarding = false
    @State private var document: WorkspaceDocument?
    @State private var exporting = false
    @State private var exportScope: ChildTaskFieldClientScope?
    @State private var exportRoot: String?
    @State private var exportMessage: String?
    init(rootID: String? = nil) { _selected = State(initialValue: rootID) }
    private var scope: ChildTaskFieldClientScope? { store.childTaskFieldRecoveryScope }
    private var usable: Bool { phase == .active && modelScope == scope && scope != nil }
    private var active: ChildTaskRepairState.Entry? { guard usable else { return nil }; return model?.entries.first { $0.command.id == activeID || ($0.command.rootID == selected && ($0.phase == .queued || $0.phase == .attempted)) } }
    private var working: Bool { loading || fetchingOriginal || model?.busy == true }
    private var dirty: Bool { !changes.isEmpty && active == nil }
    private var current: ChildTaskRepairPreview? { guard usable, let proposal, store.childTaskRepairReviewIsCurrent(proposal) else { return nil }; return proposal }
    var body: some View {
        NavigationStack {
            List {
                if usable, let model {
                    if let failure { Section { Text(failure).fixedSize(horizontal: false, vertical: true).foregroundStyle(.secondary).accessibilityIdentifier("childRepairFailure") } }
                    if let message = model.message { Section { Text(message).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("childRepairFeedback") } }
                    if let exportMessage { Section { Text(exportMessage).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("childRepairExportFeedback") } }
                    if let selected {
                        Section {
                            Text(review?.context.root.title ?? store.record("tasks", id: selected)?.title ?? "Review older subtasks").font(.headline).fixedSize(horizontal: false, vertical: true)
                            Button("All tasks and saved repairs") { select(nil) }.disabled(working).accessibilityIdentifier("childRepairAll")
                            if draft != nil { Label("Review saved on this device", systemImage: "doc.badge.clock").accessibilityIdentifier("childRepairDraftSaved"); Button("Discard saved review", role: .destructive) { discarding = true }.disabled(working).accessibilityIdentifier("childRepairDiscardDraft") }
                        }
                        if let active { ChildRepairSavedSection(entry: active, model: model, exporting: working) { Task { await exportSaved(active) } }; if active.phase == .applied || active.phase == .closed { Section { Button("Review current task") { activeID = nil; Task { await refresh() } } } } }
                        else if loading && review == nil { ProgressView("Reviewing original content…") }
                        else if let review {
                            Section("Before you repair") {
                                Label("Your original stays safe", systemImage: "doc.badge.clock").font(.headline)
                                Text("Review each change below. Saving keeps a complete original copy before changing the task.").fixedSize(horizontal: false, vertical: true)
                                Button("Export original content", systemImage: "square.and.arrow.up") { if store.childTaskAdoptionReviewIsCurrent(review), let source = review.originalSource { export(source) } }.disabled(review.originalSource == nil || working).accessibilityIdentifier("childRepairExportBefore")
                            }
                            if loading { ProgressView("Checking your proposal…") }
                            if let outline { outlineSection(outline) }
                            if !changes.isEmpty {
                                Section("Your changes") {
                                    ForEach(Array(labels.enumerated()), id: \.offset) { row in Label(row.element, systemImage: "checkmark.circle").fixedSize(horizontal: false, vertical: true) }
                                    Button("Undo last choice", systemImage: "arrow.uturn.backward") { Task { await undoChoice() } }.disabled(working).accessibilityIdentifier("childRepairUndoChoice")
                                    Button("Reset review") { discarding = true }.disabled(working)
                                }
                            }
                            if let current {
                                Section("After repair") {
                                    if current.valid {
                                        Label(current.items.count == 1 ? "1 task ready" : "\(current.items.count) tasks ready", systemImage: "checkmark.seal").font(.headline).accessibilityIdentifier("childRepairReady")
                                        ForEach(current.items) { item in Text(String(String.UnicodeScalarView((item.title?.isEmpty == false ? item.title! : "Untitled task").unicodeScalars.prefix(160)))).lineLimit(3).padding(.leading, CGFloat(min(item.depth - 1, 6) * 12)) }
                                    } else { Text("There’s another older item to review. Keep working through the list above; nothing has changed yet.").fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("childRepairMoreNeeded") }
                                    if current.metadata["custody_blocker"] != .null { Text("This task needs a separate history or storage review. Neither saved copy will be overwritten.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                                    Button { confirming = true } label: { Label("Save reviewed repair", systemImage: "checkmark.circle.fill").frame(minHeight: 44) }
                                        .disabled(!current.eligible || !store.childTaskRepairWritesAvailable || working).accessibilityIdentifier("childRepairSave")
                                    if !store.childTaskRepairWritesAvailable { Text("This device’s workspace needs recovery before saving. You can still inspect or export the original; pending edits are kept.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                                }
                            }
                            if changes.isEmpty { Section { Button("Refresh review", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(working || !store.online) } }
                        } else { Section { Text(store.childTaskRepairEnabled ? "Refresh to review the current task. Your saved choices stay on this device until you discard them or save the repair." : "New repair reviews are paused on this device. Your saved choices are kept until you can review the current task again.").fixedSize(horizontal: false, vertical: true); Button("Refresh review") { Task { await refresh() } }.disabled(working || !store.online || !store.childTaskRepairEnabled) } }
                    } else {
                        if !model.drafts.isEmpty {
                            Section("Saved reviews") {
                                ForEach(model.drafts, id: \.token) { saved in
                                    Button { select(saved.rootID) } label: {
                                        Label {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(store.record("tasks", id: saved.rootID)?.title ?? "Saved repair review").fixedSize(horizontal: false, vertical: true)
                                                Text(saved.changes.count == 1 ? "Saved review · 1 choice" : "Saved review · \(saved.changes.count) choices").font(.footnote).foregroundStyle(.secondary)
                                            }
                                        } icon: { Image(systemName: "doc.badge.clock") }
                                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                                    }.disabled(working).accessibilityIdentifier("childRepairDraft-" + saved.rootID)
                                }
                            }
                        }
                        if store.childTaskRepairEnabled {
                            Section("Review an older task") {
                                Text("Repair older subtask formats one task at a time, with an original copy kept before saving.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                ForEach(targets.filter { target in !model.drafts.contains { $0.rootID == target.id } }) { target in Button(target.title + (target.titleTruncated ? "…" : "")) { select(target.id) }.disabled(working || !model.loaded).accessibilityIdentifier("childRepairTarget-" + target.id) }
                                if let next { Button("Load more tasks") { Task { await discover(after: next) } }.disabled(working) }
                            }
                        }
                        ForEach(model.entries, id: \.command.id) { entry in ChildRepairSavedSection(entry: entry, model: model, exporting: working) { selected = entry.command.rootID; Task { await exportSaved(entry) } } }
                        if model.entries.isEmpty, model.drafts.isEmpty, !store.childTaskRepairEnabled { ContentUnavailableView("No saved repairs", systemImage: "doc.badge.clock", description: Text("Saved repairs remain available here when new repairs are paused.")) }
                    }
                } else { ContentUnavailableView("Repair review unavailable", systemImage: "doc.badge.clock", description: Text("Return to your signed-in workspace to continue.")) }
            }
            .buttonStyle(.borderless)
            .navigationTitle("Repair older subtasks")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(working) } }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 560, idealHeight: 720)
        #endif
        .privacySensitive().interactiveDismissDisabled(working)
        .task(id: scope) { await open() }
        .onChange(of: phase) { _, value in if value == .active { Task { await open() } } else { hideSensitive() } }
        .onChange(of: scope) { before, after in if before != after { changes = []; labels = []; baseDigest = nil; selected = nil; hideSensitive() } }
        .onChange(of: store.snapshotRevision) { _, _ in
            if !loading, usable, selected != nil, active == nil { Task { await refresh() } }
            else if !loading { review = nil; proposal = nil; outline = nil }
        }
        .onDisappear { hideSensitive() }
        .confirmationDialog("Save these reviewed changes?", isPresented: $confirming, titleVisibility: .visible) { Button("Save repair") { Task { await save() } } } message: { Text("The complete original is saved first. If this task changed since review, saving will stop so you can review it again.") }
        .confirmationDialog("Discard this saved review?", isPresented: $discarding, titleVisibility: .visible) { Button("Discard review", role: .destructive) { Task { await resetReview() } }; Button("Keep reviewing", role: .cancel) {} } message: { Text("Only the saved choices are removed. Your task and any queued repair stay intact.") }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Taskfold-original-" + Dates.day(Date())) { result in
            guard usable, exportScope == scope, exportRoot == selected else { return }; document = nil
            switch result { case .success: exportMessage = "Original exported."; case .failure(let error): exportMessage = (error as NSError).code == NSUserCancelledError ? nil : "Export couldn’t finish. The original is still kept." }
        }
    }
    @ViewBuilder private func outlineSection(_ outline: ChildTaskRepairOutline) -> some View {
        Section(changes.isEmpty ? "Original structure" : "Current proposal") {
            if outline.rootKind != .array && outline.rootKind != .null {
                Text("This older content needs a task list around it. All of its contents will be kept.").fixedSize(horizontal: false, vertical: true)
                Button("Create a task list") { add(.makeRootList, path: [], label: "Create a task list") }.disabled(working).accessibilityIdentifier("childRepairRootList")
            }
            if outline.rootKind == .null || outline.rootKind == .array && outline.items.isEmpty { Text("There are no older items to repair in this task.").foregroundStyle(.secondary) }
            ForEach(outline.items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                    if item.kind != .object {
                        Text("This older value can be kept inside a task, with its complete original content preserved.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Keep as a task") { add(.wrapItem, path: item.path, title: item.title, label: "Keep “\(item.title)” as a task") }.accessibilityIdentifier("childRepairWrap-" + item.id)
                    } else {
                        if item.referenceNeedsRepair { Button("Repair this task") { add(.assignReference, path: item.path, label: "Repair “\(item.title)”") }.accessibilityIdentifier("childRepairReference-" + item.id) }
                        if item.malformedChildren { Button("Repair subtask list") { add(.makeChildrenList, path: item.path, label: "Repair subtasks in “\(item.title)”") }.accessibilityIdentifier("childRepairChildren-" + item.id) }
                        if item.siblings > 1 || item.depth > 1 { Menu("Move") {
                            if item.path.last! > 0 { Button("Move earlier") { move(item, parent: Array(item.path.dropLast()), index: item.path.last! - 1) } }
                            if item.path.last! + 1 < item.siblings { Button("Move later") { move(item, parent: Array(item.path.dropLast()), index: item.path.last! + 1) } }
                            if item.depth > 1 { Button("Move to top level") { move(item, parent: [], index: outline.rootCount) } }
                        }.accessibilityLabel("Move “\(item.title)”") }
                    }
                }.padding(.leading, CGFloat(min(item.depth - 1, 6) * 12)).padding(.vertical, 4).disabled(working)
            }
            Text("Long titles are shortened in this review. Export keeps the full original.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func restoreDraft() {
        draft = model?.drafts.first { $0.rootID == selected }; changes = draft?.changes ?? []; labels = draft?.labels ?? []; baseDigest = draft?.identity["review_digest"]?.text
    }
    private func select(_ root: String?) { activeID = nil; selected = root; review = nil; proposal = nil; outline = nil; restoreDraft(); failure = nil; exportMessage = nil; if root != nil { Task { await refresh() } } }
    private func hideSensitive() { ticket = UUID(); model?.close(); model = nil; modelScope = nil; draft = nil; changes = []; labels = []; baseDigest = nil; review = nil; proposal = nil; outline = nil; targets = []; document = nil; exporting = false; exportScope = nil; exportRoot = nil; loading = false; fetchingOriginal = false }
    private func open() async {
        hideSensitive(); guard phase == .active, let captured = scope else { return }
        do { let m = try store.childTaskRepairModel(); model = m; modelScope = captured; await m.load(); guard usable, captured == scope, model === m, !Task.isCancelled else { return }; restoreDraft(); if selected == nil { await discover() } else if active == nil { await refresh() } }
        catch { guard captured == scope else { return }; failure = "Saved repairs couldn’t be read. Their originals are kept." }
    }
    private func discover(after: String? = nil) async {
        guard usable, store.childTaskRepairEnabled else { return }; let captured = scope
        do { let page = try await store.childTaskAdoptionTargets(after: after); guard usable, captured == scope, !Task.isCancelled else { return }; if after == nil { targets = page.targets } else { targets += page.targets }; next = page.next }
        catch { guard captured == scope else { return }; failure = "Tasks couldn’t be listed. Their saved content is kept." }
    }
    private func refresh() async {
        guard usable, let root = selected, store.childTaskRepairEnabled else { return }; let captured = scope, request = UUID(); ticket = request; loading = true; failure = nil
        defer { if ticket == request { loading = false } }
        do {
            let value = try await store.readChildTaskAdoption(root); guard usable, captured == scope, ticket == request, selected == root, !Task.isCancelled else { return }
            if let draft, !draft.matches(value) { failure = "The task changed since these choices were made. Your saved review is kept. Discard it to review the current content."; review = nil; proposal = nil; outline = nil; return }
            review = value
            if changes.isEmpty { guard let source = value.originalSource else { throw ChildTaskRepairOutline.unavailable }; outline = try await decodeOutline(source) }
            else { try await updateProposal(value, request: request) }
        } catch { guard captured == scope, ticket == request else { return }; failure = (error as? AppFailure)?.localizedDescription ?? "This review couldn’t be loaded. Your original is kept." }
    }
    nonisolated private func decodeOutline(_ data: Data) async throws -> ChildTaskRepairOutline { try Task.checkCancellation(); return try .init(data: data) }
    private func updateProposal(_ read: ChildTaskAdoptionReview, request: UUID) async throws {
        let value = try await store.readChildTaskRepair(read, changes: changes)
        guard usable, ticket == request, !Task.isCancelled else { throw CancellationError() }
        let tree = try await decodeOutline(value.proposed); guard usable, ticket == request, !Task.isCancelled else { throw CancellationError() }; proposal = value; outline = tree
    }
    private func add(_ kind: ChildTaskRepairChange.Kind, path: [Int], title: String? = nil, label: String) {
        guard usable, !working, let read = review, store.childTaskAdoptionReviewIsCurrent(read) else { return }
        do { let change = try ChildTaskRepairChange(kind, path: path, reference: kind == .assignReference || kind == .wrapItem ? UUID().uuidString.lowercased() : nil, title: title); apply(change, label: label, read: read) }
        catch { failure = "This choice needs another review. Your original is kept." }
    }
    private func move(_ item: ChildTaskRepairOutline.Item, parent: [Int], index: Int) {
        guard usable, !working, let read = review, store.childTaskAdoptionReviewIsCurrent(read) else { return }; do { apply(try .init(.moveItem, path: item.path, parent: parent, index: index), label: "Move “\(item.title)”", read: read) } catch { failure = "This move needs another review." }
    }
    private func persistChoices(_ next: [ChildTaskRepairChange], labels nextLabels: [String], read: ChildTaskAdoptionReview?) async -> Bool {
        guard usable, let model, let root = selected else { return false }
        let saved: ChildTaskRepairDraft?
        do {
            if next.isEmpty { saved = nil }
            else { guard let read, store.childTaskAdoptionReviewIsCurrent(read), draft == nil || draft!.matches(read) else { return false }; saved = try .init(review: read, changes: next, labels: nextLabels) }
        } catch { failure = "This review couldn’t be saved. Your previous choices are kept."; return false }
        guard await model.saveDraft(saved, rootID: root, expected: draft?.token), usable, self.model === model, selected == root else { return false }
        draft = saved; changes = next; labels = nextLabels; baseDigest = saved?.identity["review_digest"]?.text; proposal = nil
        return true
    }
    private func apply(_ change: ChildTaskRepairChange, label: String, read: ChildTaskAdoptionReview) {
        guard !working, changes.count < 64 else { return }
        let next = changes + [change], nextLabels = labels + [label], request = UUID(); ticket = request; loading = true; failure = nil
        Task {
            defer { if ticket == request { loading = false } }
            guard await persistChoices(next, labels: nextLabels, read: read), usable, ticket == request else { return }
            do { try await updateProposal(read, request: request) }
            catch { guard usable, ticket == request else { return }; failure = "Your choices are saved. The preview couldn’t be confirmed; refresh or undo the last choice. The original is unchanged." }
        }
    }
    private func undoChoice() async {
        guard !changes.isEmpty, !working else { return }; let request = UUID(); ticket = request; loading = true
        defer { if ticket == request { loading = false } }
        let accepted = await persistChoices(Array(changes.dropLast()), labels: Array(labels.dropLast()), read: review)
        guard usable, ticket == request else { return }; loading = false; if accepted { await refresh() }
    }
    private func resetReview() async {
        guard !working else { return }; let request = UUID(); ticket = request; loading = true
        defer { if ticket == request { loading = false } }
        let accepted = await persistChoices([], labels: [], read: nil)
        guard usable, ticket == request else { return }; loading = false; if accepted { review = nil; outline = nil; await refresh() }
    }
    private func save() async {
        guard let model, let proposal = current, proposal.eligible, store.childTaskRepairWritesAvailable else { return }
        do { let command = try ChildTaskRepairCommand(preview: proposal); guard await model.queue(command, review: proposal, draftToken: draft?.token), usable, self.model === model else { return }; activeID = command.id; draft = nil; changes = []; labels = []; baseDigest = nil; if await model.run(command, operation: .send) { await store.sync() } }
        catch { failure = "The repair couldn’t be saved. The original is kept." }
    }
    private func export(_ data: Data) { guard usable else { return }; document = WorkspaceDocument(data: data); exportScope = scope; exportRoot = selected; exportMessage = nil; exporting = true }
    private func exportSaved(_ entry: ChildTaskRepairState.Entry) async {
        guard usable, !working else { return }; let captured = scope, root = selected; fetchingOriginal = true
        defer { if captured == scope { fetchingOriginal = false } }
        do { let value = try await store.readChildTaskRepairOriginal(entry); guard usable, scope == captured, selected == root, !Task.isCancelled else { return }; export(value.data) }
        catch { guard usable, scope == captured else { return }; exportMessage = "This saved original couldn’t be opened with the current access. Its confirmation is kept." }
    }
}

private struct ChildRepairSavedSection: View {
    let entry: ChildTaskRepairState.Entry, model: ChildTaskRepairModel
    let exporting: Bool
    let exportOriginal: () -> Void
    @Environment(Store.self) private var store
    @State private var stopping = false
    @State private var liveTitle: String?
    @State private var titleScope: ChildTaskFieldClientScope?
    private var status: String { switch entry.phase { case .queued: return "Saved on this device"; case .attempted: return "Awaiting confirmation"; case .applied: return "Repair saved"; case .closed: return "Repair stopped" } }
    var body: some View {
        Section {
            Text(status).font(.headline).accessibilityIdentifier("childRepairStatus")
            Text(titleScope == store.childTaskFieldRecoveryScope ? liveTitle ?? store.childTaskRepairTitle(entry.command) : store.childTaskRepairTitle(entry.command)).fixedSize(horizontal: false, vertical: true)
            if entry.phase == .applied {
                Label("Original copy kept", systemImage: "doc.badge.clock").foregroundStyle(.secondary)
                Button("Export saved original", systemImage: "square.and.arrow.up", action: exportOriginal).disabled(exporting || !store.online).accessibilityIdentifier("childRepairExportSaved")
            } else if entry.phase == .queued || entry.phase == .attempted {
                Button("Check status", systemImage: "arrow.clockwise") { Task { if await model.run(entry.command, operation: .check) { await store.sync() } } }.disabled(model.busy || !store.online).accessibilityIdentifier("childRepairCheck")
                Button("Retry original repair") { Task { if await model.run(entry.command, operation: .send) { await store.sync() } } }.disabled(model.busy || !store.online || !store.permitsChildTaskRepair(entry.command, sending: true)).accessibilityIdentifier("childRepairRetry")
                Button("Check and stop repair") { stopping = true }.disabled(model.busy || !store.online).accessibilityIdentifier("childRepairStop")
            }
        }
        .task(id: store.childTaskFieldRecoveryScope) { liveTitle = nil; titleScope = nil; let captured = store.childTaskFieldRecoveryScope; if let value = try? await store.childTaskRepairLiveTitle(entry.command), captured == store.childTaskFieldRecoveryScope, !Task.isCancelled { liveTitle = value; titleScope = captured } }
        .confirmationDialog("Check and stop this repair?", isPresented: $stopping, titleVisibility: .visible) { Button("Check and stop", role: .destructive) { Task { if await model.run(entry.command, operation: .close) { await store.sync() } } } } message: { Text("An applied repair keeps its confirmation and original. An unapplied request is permanently stopped before you review a new one.") }
    }
}
