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
    @State private var savedCopies: ChildTaskCopyReview?
    @State private var comparingCopies = false
    @State private var copiesRequested = false
    @State private var expandedCopyIDs: Set<String> = []
    @State private var outline: ChildTaskRepairOutline?
    @State private var changes: [ChildTaskRepairChange] = []
    @State private var labels: [String] = []
    @State private var baseDigest: String?
    @State private var draft: ChildTaskRepairDraft?
    @State private var mappingCatalog: ChildCopyMappingCatalog?
    @State private var mappingHistorySelection: ChildCopyMappingCatalog.Item?
    @State private var mappingHistoryQuery = ""
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
    private var working: Bool { loading || fetchingOriginal || comparingCopies || model?.busy == true }
    private var choosingCopy: Bool { changes.contains { $0.kind == .chooseCopy } }
    private var dirty: Bool { !changes.isEmpty && active == nil }
    private var current: ChildTaskRepairPreview? { guard usable, let proposal, store.childTaskRepairReviewIsCurrent(proposal) else { return nil }; return proposal }
    private var currentCopies: ChildTaskCopyReview? { guard usable, let savedCopies, store.childTaskCopiesAreCurrent(savedCopies) else { return nil }; return savedCopies }
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
                                Button { if store.childTaskAdoptionReviewIsCurrent(review), let source = review.originalSource { export(source) } } label: { ChildRepairActionLabel(title: "Export original content", symbol: "square.and.arrow.up") }.disabled(review.originalSource == nil || working).accessibilityIdentifier("childRepairExportBefore")
                            }
                            if review.metadata["projection_revision"] != .null || ["projection_mismatch", "authority_mismatch"].contains(review.metadata["issue"]?.text ?? "") {
                                Section("Saved copies") {
                                    Text("Compare the saved task lists before choosing a repair. Reviewing them keeps every copy unchanged.").fixedSize(horizontal: false, vertical: true)
                                    Button { Task { await compareCopies(review) } } label: { ChildRepairActionLabel(title: "Compare saved copies", symbol: "doc.on.doc") }
                                        .disabled(working).accessibilityIdentifier("childCopyReviewLoad")
                                    if comparingCopies { ProgressView("Reading saved copies…") }
                                    if let copies = currentCopies {
                                        ChildCopyComparison(copies: copies, expanded: $expandedCopyIDs, selectedSource: choosingCopy && changes.first?.raw["copy_digest"] == .string(copies.digest) ? changes.first?.raw["source"]?.text : nil, canChoose: changes.isEmpty && draft?.mappingReview == nil && !working, choose: { copy in chooseCopy(copy, from: copies, review: review) }, reviewHistory: { copy in beginMapping(copy, copies: copies, read: review) })
                                        Button { Task { await compareCopies(review, exportCurrent: true) } } label: { ChildRepairActionLabel(title: "Export readable copies", symbol: "square.and.arrow.up") }
                                            .disabled(working).accessibilityIdentifier("childCopyReviewExport")
                                        Text("The export keeps exact saved content, including fields that are shortened in this review. Copies needing an access review stay private and unchanged.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            if let partial = draft?.mappingReview, let catalog = mappingCatalog, currentCopies?.digest == partial.digest, catalog.digest == partial.digest {
                                ChildMappingEditor(catalog: catalog, draft: partial, enabled: !working, assignee: { id in
                                    if id == store.userID { return "You" }
                                    return store.assigneeName(Record(["assigned_to": id.map(JSON.string) ?? .null, "project_id": review.metadata["project_id"] ?? .null]))
                                }, update: { value in saveMapping(value) }, preview: { finishMapping(catalog, partial) }, chooseHistory: { item in
                                    mappingHistoryQuery = ""; mappingHistorySelection = item
                                })
                            }
                            if loading { ProgressView("Checking your proposal…") }
                            if !choosingCopy, draft?.mappingReview == nil, let outline { outlineSection(outline) }
                            if !changes.isEmpty {
                                Section("Your changes") {
                                    ForEach(Array(labels.enumerated()), id: \.offset) { row in Label(row.element, systemImage: "checkmark.circle").fixedSize(horizontal: false, vertical: true) }
                                    if changes.count == 1, changes[0].raw["mapping"] != nil {
                                        Button("Edit history choices", systemImage: "pencil") { editMapping() }.disabled(working || currentCopies == nil).accessibilityIdentifier("childMappingEdit")
                                    }
                                    Button("Reset review") { discarding = true }.disabled(working)
                                }
                            }
                            if let current {
                                Section("After repair") {
                                    if current.metadata["custody_blocker"] == .string("history_custody"), changes.count == 1, changes[0].kind == .chooseCopy, changes[0].raw["mapping"] == nil {
                                        Button("Review task histories", systemImage: "clock.arrow.circlepath") { editMapping() }.disabled(working || currentCopies == nil).accessibilityIdentifier("childMappingResolve")
                                    }
                                    if let summary = current.mappingSummary {
                                        Text("\(summary.newCount) new histories · \(summary.retiredCount) recorded histories retired").fixedSize(horizontal: false, vertical: true)
                                        Text("Earlier earned work stays in history. Recovered completed tasks won’t add to work totals.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                    if current.valid {
                                        Label(current.items.count == 1 ? "1 task ready" : "\(current.items.count) tasks ready", systemImage: "checkmark.seal").font(.headline).accessibilityIdentifier("childRepairReady")
                                        ForEach(current.items) { item in Text(String(String.UnicodeScalarView((item.title?.isEmpty == false ? item.title! : "Untitled task").unicodeScalars.prefix(160)))).lineLimit(3).padding(.leading, CGFloat(min(item.depth - 1, 6) * 12)) }
                                    } else { Text("There’s another older item to review. Keep working through the list above; nothing has changed yet.").fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("childRepairMoreNeeded") }
                                    ForEach(current.historyRetention) { retained in
                                        Text("The chosen original item keeps \(retained.eventCount) recorded \(retained.eventCount == 1 ? "event" : "events"), including \(retained.completedCount) completion \(retained.completedCount == 1 ? "event" : "events"). Original dates stay unchanged.")
                                            .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                            .accessibilityIdentifier("childRepairHistory-\(retained.ordinal)")
                                    }
                                    if current.metadata["custody_blocker"] != .null { Text("This task needs a separate history or storage review. Neither saved copy will be overwritten.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                                    Button { confirming = true } label: { ChildRepairActionLabel(title: "Save reviewed repair", symbol: "checkmark.circle.fill") }
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
                        ForEach(model.entries, id: \.command.id) { entry in ChildRepairSavedSection(entry: entry, model: model, exporting: working) { selected = entry.command.rootID; activeID = entry.command.id; Task { await exportSaved(entry) } } }
                        if model.entries.isEmpty, model.drafts.isEmpty, !store.childTaskRepairEnabled { ContentUnavailableView("No saved repairs", systemImage: "doc.badge.clock", description: Text("Saved repairs remain available here when new repairs are paused.")) }
                    }
                } else { ContentUnavailableView("Repair review unavailable", systemImage: "doc.badge.clock", description: Text("Return to your signed-in workspace to continue.")) }
            }
            .buttonStyle(.borderless)
            .navigationTitle("Repair older subtasks")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .bottom) {
                if usable, review != nil, active == nil, !changes.isEmpty {
                    HStack {
                        Button("Undo last choice", systemImage: "arrow.uturn.backward") { Task { await undoChoice() } }
                            .disabled(working).keyboardShortcut("z", modifiers: .command)
                            .accessibilityIdentifier("childRepairUndoChoice")
                        Spacer()
                    }.padding(.horizontal).padding(.vertical, 8).background(.bar)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(working).keyboardShortcut(.cancelAction) }
                if let current, active == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save…") { confirming = true }
                            .disabled(!current.eligible || !store.childTaskRepairWritesAvailable || working)
                            .keyboardShortcut(.return, modifiers: .command).accessibilityIdentifier("childRepairSaveShortcut")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 560, idealHeight: 720)
        #endif
        .privacySensitive().interactiveDismissDisabled(working)
        .sheet(item: $mappingHistorySelection) { item in
            if usable, let catalog = mappingCatalog, let partial = draft?.mappingReview,
               currentCopies?.digest == partial.digest, catalog.digest == partial.digest {
                ChildMappingHistoryPicker(catalog: catalog, draft: partial, item: item, query: $mappingHistoryQuery,
                    details: mappingHistoryDetails, select: { target in chooseMappingHistory(target, for: item) },
                    cancel: { mappingHistorySelection = nil })
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 420)
                #else
                .presentationDetents([.large])
                #endif
            }
        }
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
            switch result { case .success: exportMessage = "Original exported."; case .failure(let error): exportMessage = (error as NSError).code == NSUserCancelledError ? nil : "Export couldn’t finish. Please try again." }
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
                        if !outline.historyKeepers(for: item).isEmpty {
                            Menu("Separate duplicate and keep history…") {
                                ForEach(outline.historyKeepers(for: item)) { keeper in
                                    Button("Keep history with “\(keeper.title)” (item \(keeper.path.map { String($0 + 1) }.joined(separator: ".")))") { separate(item, keeping: keeper) }
                                }
                            }.accessibilityIdentifier("childRepairSeparate-" + item.id)
                            Text("This item gets a fresh identity. Prior activity stays with the item you choose, including its original completion dates. Nothing is copied or reassigned.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
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
        draft = model?.drafts.first { $0.rootID == selected }; changes = draft?.changes ?? []; labels = draft?.labels ?? []; baseDigest = draft?.identity["review_digest"]?.text; if draft?.mappingReview != nil || changes.first?.raw["mapping"] != nil { copiesRequested = true }
    }
    private func select(_ root: String?) { mappingHistorySelection = nil; mappingHistoryQuery = ""; mappingCatalog = nil; copiesRequested = false; expandedCopyIDs = []; activeID = nil; selected = root; review = nil; proposal = nil; savedCopies = nil; outline = nil; restoreDraft(); failure = nil; exportMessage = nil; if root != nil { Task { await refresh() } } }
    private func hideSensitive() { mappingHistorySelection = nil; mappingHistoryQuery = ""; mappingCatalog = nil; copiesRequested = false; expandedCopyIDs = []; ticket = UUID(); model?.close(); model = nil; modelScope = nil; draft = nil; changes = []; labels = []; baseDigest = nil; review = nil; proposal = nil; savedCopies = nil; comparingCopies = false; outline = nil; targets = []; document = nil; exporting = false; exportScope = nil; exportRoot = nil; loading = false; fetchingOriginal = false }
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
        guard usable, let root = selected, store.childTaskRepairEnabled else { return }; mappingHistorySelection = nil; mappingHistoryQuery = ""; let captured = scope, request = UUID(); ticket = request; loading = true; comparingCopies = false; failure = nil; savedCopies = nil; proposal = nil; outline = nil; mappingCatalog = nil
        defer { if ticket == request { loading = false } }
        do {
            let value = try await store.readChildTaskAdoption(root); guard usable, captured == scope, ticket == request, selected == root, !Task.isCancelled else { return }
            if let draft, !draft.matches(value) { failure = "The task changed since these choices were made. Your saved review is kept. Discard it to review the current content."; review = nil; proposal = nil; outline = nil; return }
            review = value
            if changes.isEmpty { guard let source = value.originalSource else { throw ChildTaskRepairOutline.unavailable }; outline = try await decodeOutline(source) }
            // Snapshot refreshes revoke the old read immediately. Restore only
            // a newly authorized comparison, retaining the user's open groups.
            if copiesRequested {
                let copies = try await store.readChildTaskCopies(value)
                guard usable, captured == scope, ticket == request, selected == root, store.childTaskCopiesAreCurrent(copies), !Task.isCancelled else { return }
                savedCopies = copies
                if let partial = draft?.mappingReview {
                    let catalog = try await decodeMapping(copies, source: partial.source)
                    guard usable, captured == scope, ticket == request else { return }
                    try catalog.validate(partial, complete: false); mappingCatalog = catalog
                }
            }
            if !changes.isEmpty { try await updateProposal(value, request: request) }
        } catch { guard captured == scope, ticket == request else { return }; failure = (error as? AppFailure)?.localizedDescription ?? "This review couldn’t be loaded. Your original is kept." }
    }
    nonisolated private func decodeOutline(_ data: Data) async throws -> ChildTaskRepairOutline { try Task.checkCancellation(); return try .init(data: data) }
    private func updateProposal(_ read: ChildTaskAdoptionReview, request: UUID) async throws {
        let value = try await store.readChildTaskRepair(read, changes: changes)
        guard usable, ticket == request, !Task.isCancelled else { throw CancellationError() }
        let tree = try await decodeOutline(value.proposed); guard usable, ticket == request, !Task.isCancelled else { throw CancellationError() }; proposal = value; outline = tree
    }
    private func chooseCopy(_ copy: ChildTaskCopyReview.Copy, from copies: ChildTaskCopyReview, review read: ChildTaskAdoptionReview) {
        guard usable, !working, changes.isEmpty, draft?.mappingReview == nil, copy.state == "ready", !copies.omitted.contains(copy.id),
              store.childTaskCopiesAreCurrent(copies), currentCopies?.digest == copies.digest,
              store.childTaskAdoptionReviewIsCurrent(read) else { return }
        do { apply(try .choosing(copy.id, digest: copies.digest), label: "Use \(copy.title.lowercased())", read: read) }
        catch { failure = "These saved copies need another comparison. All originals are kept." }
    }
    nonisolated private func decodeMapping(_ copies: ChildTaskCopyReview, source: String) async throws -> ChildCopyMappingCatalog { try Task.checkCancellation(); return try .init(copies: copies, source: source) }
    private func beginMapping(_ copy: ChildTaskCopyReview.Copy, copies: ChildTaskCopyReview, read: ChildTaskAdoptionReview) {
        guard usable, !working, changes.isEmpty, draft?.mappingReview == nil, currentCopies?.digest == copies.digest else { return }
        let request = UUID(); ticket = request; loading = true
        Task {
            defer { if ticket == request { loading = false } }
            do {
                let catalog = try await decodeMapping(copies, source: copy.id)
                guard usable, ticket == request, store.childTaskAdoptionReviewIsCurrent(read), currentCopies?.digest == copies.digest else { return }
                let partial = try ChildCopyMappingDraft(source: copy.id, digest: copies.digest, mapping: ["version": .number(1), "nodes": .array([]), "retire": .array([])])
                if await persistMapping(partial, read: read) { mappingCatalog = catalog }
            } catch { guard usable, ticket == request else { return }; failure = "History choices need a fresh comparison. All originals are kept." }
        }
    }
    private func persistMapping(_ partial: ChildCopyMappingDraft, read: ChildTaskAdoptionReview) async -> Bool {
        guard usable, let model, let root = selected, changes.isEmpty || changes.count == 1 && changes[0].kind == .chooseCopy && changes[0].raw["source"] == .string(partial.source) && changes[0].raw["copy_digest"] == .string(partial.digest), store.childTaskAdoptionReviewIsCurrent(read), currentCopies?.digest == partial.digest else { return false }
        do {
            let saved = try ChildTaskRepairDraft(review: read, changes: [], labels: [], mappingReview: partial)
            guard await model.saveDraft(saved, rootID: root, expected: draft?.token), usable, self.model === model, selected == root else { return false }
            draft = saved; changes = []; labels = []; baseDigest = saved.identity["review_digest"]?.text; proposal = nil; return true
        } catch { failure = "Your last saved history choices are kept. This change couldn’t be saved."; return false }
    }
    private func mappingHistoryDetails(_ item: ChildCopyMappingCatalog.Item) -> String {
        let assignee = item.assignee == store.userID ? "You" : store.assigneeName(Record(["assigned_to": item.assignee.map(JSON.string) ?? .null, "project_id": review?.metadata["project_id"] ?? .null]))
        var text = item.status + " · " + assignee
        if let date = item.completedAt.flatMap(TaskPlanning.instant) { text += " · " + date.formatted(date: .abbreviated, time: .shortened) }
        if item.recurrence != nil { text += " · Recurring task" }; return text
    }
    private func chooseMappingHistory(_ target: String, for item: ChildCopyMappingCatalog.Item) {
        guard usable, !working, let catalog = mappingCatalog, let partial = draft?.mappingReview,
              currentCopies?.digest == partial.digest, catalog.digest == partial.digest,
              catalog.selected.contains(where: { $0.id == item.id }) else { mappingHistorySelection = nil; return }
        defer { mappingHistorySelection = nil }
        let old = partial.mapping.nodes.first { $0["source_key"] == .string(item.id) }
        let previous = old.map { $0["history_key"] == .null ? "new" : "stored:" + $0["history_key"]!.text } ?? ""
        guard target != previous else { return }
        var nodes = partial.mapping.nodes.filter { $0["source_key"] != .string(item.id) }, retired = partial.mapping.retired
        if target == "new" {
            nodes.append(["source_key": .string(item.id), "history_key": .null, "incarnation": .null, "lifecycle": .string("selected"), "new_reference": .string(UUID().uuidString.lowercased())])
        } else if let stored = catalog.stored.first(where: { "stored:" + $0.id == target }) {
            nodes.append(["source_key": .string(item.id), "history_key": .string(stored.id), "incarnation": .string(stored.incarnation), "lifecycle": .null])
            retired.removeAll { $0["node_key"] == .string(stored.id) }
        } else if !target.isEmpty { return }
        guard let value = try? ChildCopyMappingDraft(source: partial.source, digest: partial.digest,
            mapping: ["version": .number(1), "nodes": .array(nodes.map(JSON.object)), "retire": .array(retired.map(JSON.object))]) else { return }
        saveMapping(value)
    }
    private func saveMapping(_ partial: ChildCopyMappingDraft) {
        guard usable, !working, let read = review, let catalog = mappingCatalog else { return }
        do { try catalog.validate(partial, complete: false) } catch { failure = "Choose each history only once. Your saved choices are kept."; return }
        let request = UUID(); ticket = request; loading = true
        Task { defer { if ticket == request { loading = false } }; _ = await persistMapping(partial, read: read) }
    }
    private func editMapping() {
        guard usable, !working, let read = review, let copies = currentCopies, let choice = changes.first, choice.kind == .chooseCopy else { return }
        let request = UUID(); ticket = request; loading = true
        Task {
            defer { if ticket == request { loading = false } }
            do {
                let partial = try ChildCopyMappingDraft(source: choice.raw["source"]!.text, digest: choice.raw["copy_digest"]!.text, mapping: choice.raw["mapping"]?.object ?? ["version": .number(1), "nodes": .array([]), "retire": .array([])])
                let catalog = try await decodeMapping(copies, source: partial.source); try catalog.validate(partial, complete: false)
                guard usable, ticket == request else { return }; if await persistMapping(partial, read: read) { mappingCatalog = catalog }
            } catch { guard usable, ticket == request else { return }; failure = "These choices need a fresh comparison. Your saved review and originals are kept." }
        }
    }
    private func finishMapping(_ catalog: ChildCopyMappingCatalog, _ partial: ChildCopyMappingDraft) {
        guard usable, !working, let read = review, currentCopies?.digest == partial.digest else { return }
        do {
            try catalog.validate(partial, complete: true)
            let complete = try ChildCopyMapping(raw: partial.mapping.raw)
            apply(try .choosing(partial.source, digest: partial.digest, mapping: complete), label: "Use reviewed task histories", read: read)
        } catch { failure = "Choose every task’s history and review each task retiring from this list." }
    }
    private func add(_ kind: ChildTaskRepairChange.Kind, path: [Int], title: String? = nil, label: String) {
        guard usable, !working, let read = review, store.childTaskAdoptionReviewIsCurrent(read) else { return }
        do { let change = try ChildTaskRepairChange(kind, path: path, reference: kind == .assignReference || kind == .wrapItem ? UUID().uuidString.lowercased() : nil, title: title); apply(change, label: label, read: read) }
        catch { failure = "This choice needs another review. Your original is kept." }
    }
    private func separate(_ item: ChildTaskRepairOutline.Item, keeping keeper: ChildTaskRepairOutline.Item) {
        guard usable, !working, let read = review, store.childTaskAdoptionReviewIsCurrent(read) else { return }
        do {
            let change = try ChildTaskRepairChange(.separateDuplicate, path: item.path, reference: UUID().uuidString.lowercased(), keepPath: keeper.path)
            apply(change, label: "Separate “\(item.title)”; keep prior activity with “\(keeper.title)” (item \(keeper.path.map { String($0 + 1) }.joined(separator: ".")))", read: read)
        } catch { failure = "These duplicate items need another review. Your original is kept." }
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
    private func compareCopies(_ read: ChildTaskAdoptionReview, exportCurrent: Bool = false) async {
        guard usable, !working, selected == read.context.root.id, store.childTaskAdoptionReviewIsCurrent(read) else { return }
        let capturedDigest = currentCopies?.digest, request = UUID(); copiesRequested = true; ticket = request; comparingCopies = true; failure = nil
        if choosingCopy { proposal = nil }
        defer { if ticket == request { comparingCopies = false } }
        do {
            let value = try await store.readChildTaskCopies(read)
            guard usable, ticket == request, selected == read.context.root.id, store.childTaskCopiesAreCurrent(value), !Task.isCancelled else { return }
            savedCopies = value
            if let partial = draft?.mappingReview {
                let catalog = try await decodeMapping(value, source: partial.source)
                guard usable, ticket == request else { return }; try catalog.validate(partial, complete: false); mappingCatalog = catalog
            }
            if choosingCopy {
                if changes.first?.raw["copy_digest"] == .string(value.digest) { try await updateProposal(read, request: request) }
                else { failure = "These saved copies changed after your choice. Undo the choice or reset this review, then compare and choose again. Your saved choice and all originals are kept." }
            }
            if exportCurrent {
                guard capturedDigest == value.digest else { failure = "These saved copies changed. Review the updated lists before exporting."; return }
                export(value.exportBundle)
            }
        } catch {
            guard usable, ticket == request else { return }; savedCopies = nil
            failure = "Saved copies couldn’t be read with current access. Refresh the task review to try again; all content is unchanged."
        }
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
                Label("Original saved with this repair", systemImage: "doc.badge.clock").foregroundStyle(.secondary)
                Button(action: exportOriginal) { ChildRepairActionLabel(title: "Export saved original", symbol: "square.and.arrow.up") }.disabled(exporting || !store.online).accessibilityIdentifier("childRepairExportSaved")
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

/// Explicit intrinsic icon width and a wrapping title keep these actions
/// readable in a narrow sheet at accessibility text sizes.
private struct ChildRepairActionLabel: View {
    let title: Text
    let symbol: String
    init(title: LocalizedStringKey, symbol: String) { self.title = Text(title); self.symbol = symbol }
    init(text: Text, symbol: String) { title = text; self.symbol = symbol }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).fixedSize().accessibilityHidden(true)
            title.fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct ChildCopyComparison: View {
    let copies: ChildTaskCopyReview
    @Binding var expanded: Set<String>
    let selectedSource: String?
    let canChoose: Bool
    let choose: (ChildTaskCopyReview.Copy) -> Void
    let reviewHistory: (ChildTaskCopyReview.Copy) -> Void
    var body: some View {
        Group {
            if copies.metadata["state"] == .string("aligned") {
                Text("The readable lists contain the same tasks. Their saved storage state may still need a review.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if copies.metadata["state"] == .string("different") {
                Label("The saved lists differ", systemImage: "doc.on.doc").font(.headline)
            }
            ForEach(copies.copies) { copy in
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(copy.id) }, set: { open in
                    if open { expanded.insert(copy.id) } else { expanded.remove(copy.id) }
                })) {
                    if copy.state == "unavailable" { Text("This copy needs an access review before its content can be shown. It stays unchanged.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    else if copy.state == "absent" { Text("No separate copy is saved here.").foregroundStyle(.secondary) }
                    else if copy.state == "review" { Text("This copy has an older format. Its exact readable content is preserved in the export.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    else {
                        ForEach(copy.items) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                                if let completed = item.completed { Label(completed ? "Completed" : "Open", systemImage: completed ? "checkmark.circle" : "circle").font(.caption).foregroundStyle(.secondary) }
                                if let notes = item.notes, !notes.isEmpty { Text(notes).fixedSize(horizontal: false, vertical: true) }
                                if let due = item.due, !due.isEmpty { Text("Due \(due)").font(.caption).foregroundStyle(.secondary) }
                                if let priority = item.priority { Text("Priority \(priority)").font(.caption).foregroundStyle(.secondary) }
                            }.padding(.leading, CGFloat(min(item.depth - 1, 6) * 12)).padding(.vertical, 4)
                        }
                    }
                    if copy.state == "ready", !copies.omitted.contains(copy.id) {
                        if selectedSource == copy.id {
                            Label("Chosen for review", systemImage: "checkmark.circle").fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("childCopyChosen-" + copy.id)
                        } else {
                            Button { choose(copy) } label: { ChildRepairActionLabel(title: "Use this copy", symbol: "checkmark.circle") }
                                .disabled(!canChoose).accessibilityLabel("Use \(copy.title.lowercased())")
                                .accessibilityIdentifier("childCopyChoose-" + copy.id)
                            Button { reviewHistory(copy) } label: { ChildRepairActionLabel(title: "Review task histories", symbol: "clock.arrow.circlepath") }
                                .disabled(!canChoose || !copies.omitted.isEmpty).accessibilityIdentifier("childCopyMap-" + copy.id)
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(copy.title).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                        Text(copy.state == "unavailable" ? "Needs access review" : copy.state == "absent" ? "No saved copy" : copy.state == "review" ? "Needs format review" : copy.count == 1 ? "1 task" : "\(copy.count ?? 0) tasks").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("childCopyReview-" + copy.id)
                }
            }
        }
    }
}

private struct ChildMappingEditor: View {
    let catalog: ChildCopyMappingCatalog
    let draft: ChildCopyMappingDraft
    let enabled: Bool
    let assignee: (String?) -> String
    let update: (ChildCopyMappingDraft) -> Void
    let preview: () -> Void
    let chooseHistory: (ChildCopyMappingCatalog.Item) -> Void
    private func choice(_ id: String) -> [String: JSON]? { draft.mapping.nodes.first { $0["source_key"] == .string(id) } }
    private var complete: Bool { (try? catalog.validate(draft, complete: true)) != nil }
    private func submit(nodes: [[String: JSON]], retired: [[String: JSON]]) {
        guard let value = try? ChildCopyMappingDraft(source: draft.source, digest: draft.digest, mapping: ["version": .number(1), "nodes": .array(nodes.map(JSON.object)), "retire": .array(retired.map(JSON.object))]) else { return }
        update(value)
    }
    private func lifecycle(_ value: String, for item: ChildCopyMappingCatalog.Item) {
        let nodes = draft.mapping.nodes.map { node -> [String: JSON] in
            guard node["source_key"] == .string(item.id) else { return node }; var updated = node; updated["lifecycle"] = value.isEmpty ? .null : .string(value); return updated
        }
        submit(nodes: nodes, retired: draft.mapping.retired)
    }
    private func target(_ item: ChildCopyMappingCatalog.Item) -> String {
        guard let n = choice(item.id) else { return "" }; return n["history_key"] == .null ? "new" : "stored:" + n["history_key"]!.text
    }
    private func historyTitle(_ item: ChildCopyMappingCatalog.Item) -> Text {
        let selected = target(item)
        if selected == "new" { return item.heading == true ? Text("New heading history") : Text("New task history") }
        if let stored = catalog.stored.first(where: { "stored:" + $0.id == selected }) { return Text(verbatim: stored.fields.title) }
        return Text("Choose history…")
    }
    private func details(_ item: ChildCopyMappingCatalog.Item) -> String {
        var text = item.status + " · " + assignee(item.assignee)
        if let date = item.completedAt.flatMap(TaskPlanning.instant) { text += " · " + date.formatted(date: .abbreviated, time: .shortened) }
        if item.recurrence != nil { text += " · Recurring task" }; return text
    }
    var body: some View {
        Section("Match task histories") {
            Text("Choose an existing history for each task, or treat it as a new task. Nothing is saved to your task list until you review and confirm the proposal.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(catalog.selected) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                    Text(item.location).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Selected copy: " + details(item)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button {
                        chooseHistory(item)
                    } label: {
                        ChildRepairActionLabel(text: historyTitle(item), symbol: "clock.arrow.circlepath")
                    }.accessibilityLabel("Choose history for “\(item.title)”").accessibilityValue(historyTitle(item)).accessibilityIdentifier("childMappingIdentity-" + item.id)
                    if let n = choice(item.id), n["history_key"] != .null, let stored = catalog.stored.first(where: { $0.id == n["history_key"]?.text }) {
                        Text("Recorded: " + details(stored.fields)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Picker("Completion, type and assignee for “\(item.title)”", selection: Binding(get: { choice(item.id)?["lifecycle"]?.text ?? "" }, set: { lifecycle($0, for: item) })) {
                            Text("Choose details…").tag("")
                            Text("Keep recorded details").tag("recorded")
                            Text("Use selected copy’s details").tag("selected")
                        }.pickerStyle(.menu).accessibilityIdentifier("childMappingLifecycle-" + item.id)
                    }
                }.padding(.vertical, 4).disabled(!enabled)
            }
            Text("Details include completion, task type, assignee and any recurring-task relationship. Unresolved recurring-task conflicts will stop for a separate review.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Section("Histories leaving this list") {
            ForEach(catalog.stored.filter { stored in !draft.mapping.nodes.contains { $0["history_key"] == .string(stored.id) } }) { stored in
                Toggle(isOn: Binding(get: { draft.mapping.retired.contains { $0["node_key"] == .string(stored.id) } }, set: { selected in
                    var retired = draft.mapping.retired.filter { $0["node_key"] != .string(stored.id) }
                    if selected { retired.append(["node_key": .string(stored.id), "incarnation": .string(stored.incarnation)]) }
                    submit(nodes: draft.mapping.nodes, retired: retired)
                })) {
                    VStack(alignment: .leading, spacing: 3) { Text(stored.fields.title).fixedSize(horizontal: false, vertical: true); Text("Retire from this list; keep its original and prior activity").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }.disabled(!enabled).accessibilityIdentifier("childMappingRetire-" + stored.id)
            }
            Button("Preview reviewed histories", action: preview).disabled(!enabled || !complete).accessibilityIdentifier("childMappingPreview")
            if !complete { Text("Choose every task’s history and details, and confirm each unused history above.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

private struct ChildMappingHistoryPicker: View {
    let catalog: ChildCopyMappingCatalog
    let draft: ChildCopyMappingDraft
    let item: ChildCopyMappingCatalog.Item
    @Binding var query: String
    let details: (ChildCopyMappingCatalog.Item) -> String
    let select: (String) -> Void
    let cancel: () -> Void
    private var candidates: [ChildCopyMappingCatalog.Stored] {
        let used = Set(draft.mapping.nodes.filter { $0["source_key"] != .string(item.id) }.compactMap { row -> String? in
            guard case .string(let key)? = row["history_key"] else { return nil }; return key
        })
        return catalog.stored.filter { stored in
            guard !used.contains(stored.id) else { return false }
            if query.isEmpty { return true }
            let text = stored.fields.title + " " + stored.fields.location + " " + details(stored.fields)
            return text.localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(item.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text("Choose the recorded history that belongs to this task, or give it a new history.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(item.heading == true ? "Treat as a new heading" : "Treat as a new task") { select("new") }.accessibilityIdentifier("childMappingNewHistory")
                    Button("Leave unresolved") { select("") }
                }
                Section("Existing histories") { ForEach(candidates) { stored in historyRow(stored) } }
            }
            #if os(iOS)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a recorded task")
            .navigationBarTitleDisplayMode(.inline)
            #else
            .searchable(text: $query, prompt: "Find a recorded task")
            #endif
            .navigationTitle("Choose history")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) } }
        }
    }
    private func historyRow(_ stored: ChildCopyMappingCatalog.Stored) -> some View {
        Button { select("stored:" + stored.id) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(stored.fields.title).foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
                Text(stored.fields.location + " · " + details(stored.fields)).font(.caption).foregroundStyle(Color.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityIdentifier("childMappingHistory-" + stored.id)
    }
}

/// A fresh device can browse originals without recreating old repair commands.
/// Metadata is ephemeral; original bytes are fetched only for explicit export.
struct ChildTaskRepairArchivesView: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ChildTaskRepairArchive] = []
    @State private var next: String?
    @State private var loaded = false
    @State private var busy = false
    @State private var ticket = UUID()
    @State private var message: String?
    @State private var document: WorkspaceDocument?
    @State private var exporting = false
    @State private var exportScope: ChildTaskFieldClientScope?
    @State private var comparison: ChildTaskRepairOriginalComparison?
    @State private var showingRestoration = false
    @State private var restorationArchive: ChildTaskRepairArchive?
    @State private var removingOriginal = false
    @State private var cleanupID: String?
    @State private var cleanupReview: ChildTaskRepairOriginalCleanup?
    @State private var cleanupAcknowledged = false
    @State private var visible = true
    private var scope: ChildTaskFieldClientScope? { phase == .active ? store.childTaskFieldRecoveryScope : nil }
    var body: some View {
        NavigationStack {
            List {
                if scope != nil {
                    Section {
                        Text("Find originals saved before a repair, even on a new device. Names reflect current tasks; exports keep their original content and check your current access.")
                            .fixedSize(horizontal: false, vertical: true).foregroundStyle(.secondary)
                        Button("Saved restore requests") { restorationArchive = nil; showingRestoration = true }
                            .disabled(busy).accessibilityIdentifier("childRestoreRequests")
                        Button("Refresh") { Task { await load() } }.disabled(busy).accessibilityIdentifier("childRepairArchivesRefresh")
                    }
                    if busy { ProgressView(removingOriginal ? "Removing saved original…" : "Reading saved originals…").accessibilityIdentifier("childRepairArchivesProgress") }
                    if let message { Text(message).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("childRepairArchivesFeedback") }
                    if loaded && entries.isEmpty && !busy {
                        ContentUnavailableView("No saved originals", systemImage: "archivebox", description: Text("Original copies appear after a subtask repair is saved to this account."))
                            .accessibilityIdentifier("childRepairArchivesEmpty")
                    }
                    ForEach(entries.filter { $0.scope == scope }.sorted { $0.createdAt == $1.createdAt ? $0.requestID < $1.requestID : $0.createdAt > $1.createdAt }) { entry in
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(archiveTitle(entry)).font(.headline).fixedSize(horizontal: false, vertical: true)
                                Text(entry.createdAt, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.bytes), countStyle: .file))
                                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            if entry.contentRetained {
                                Button { Task { await compare(entry) } } label: { ChildRepairActionLabel(title: "Compare subtasks", symbol: "arrow.left.arrow.right") }
                                    .disabled(busy).accessibilityLabel("Compare subtasks: \(archiveTitle(entry))")
                                    .accessibilityHint("Review the saved and current structures without changing your tasks.")
                                    .accessibilityIdentifier("childRepairArchiveCompare-" + entry.id)
                                Button { Task { await export(entry) } } label: { ChildRepairActionLabel(title: "Export original", symbol: "square.and.arrow.up") }
                                    .disabled(busy).accessibilityLabel("Export original: \(archiveTitle(entry))")
                                    .accessibilityHint("Save a copy of this original without changing your tasks.")
                                    .accessibilityIdentifier("childRepairArchiveExport-" + entry.id)
                                if store.childTaskOriginalRestorationEnabled {
                                    Button("Review restoration") { restorationArchive = entry; showingRestoration = true }
                                        .disabled(busy).accessibilityIdentifier("childRestoreArchive-" + entry.id)
                                }
                                if store.childTaskRepairArchiveCleanupEnabled { cleanupControls(entry) }
                            } else {
                                Text("Original content is no longer available. Its repair confirmation is kept.")
                                    .fixedSize(horizontal: false, vertical: true).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("childRepairArchiveUnavailable-" + entry.id)
                            }
                        }
                    }
                    if let next {
                        Button(entries.count >= 500 ? "Continue to next page" : "Load more") { Task { await load(after: next) } }
                            .disabled(busy).accessibilityIdentifier("childRepairArchivesMore")
                    }
                } else {
                    Text("Return to your signed-in workspace to view saved originals.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Saved originals")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) } }
        }
        .onAppear { visible = true }
        .task { await load() }
        .onChange(of: scope) { _, after in clear(); if after != nil { Task { await load() } } }
        .onDisappear { visible = false; clear() }
        .onChange(of: store.snapshotRevision) { _, _ in comparison = nil }
        .sheet(item: $comparison) { value in
            if visible, scope == value.archive.scope, store.snapshotRevision == value.snapshot {
                ChildRepairOriginalComparisonView(comparison: value, close: { comparison = nil })
            }
        }
        .sheet(isPresented: $showingRestoration) {
            if visible, scope != nil { ChildTaskOriginalRestoreView(archive: restorationArchive) }
        }
        .fileExporter(isPresented: $exporting, document: scope == exportScope ? document : nil, contentType: .json, defaultFilename: "Taskfold-original-" + Dates.day(Date())) { result in
            guard let scope, exportScope == scope else { return }; document = nil; exportScope = nil
            switch result {
            case .success: message = "Original exported."
            case .failure(let error): message = (error as NSError).code == NSUserCancelledError ? nil : "Export couldn’t finish. Please try again."
            }
        }
    }
    private func archiveTitle(_ entry: ChildTaskRepairArchive) -> String {
        guard let title = entry.title, !title.isEmpty else { return "Saved original" }
        return title + (entry.titleTruncated ? "…" : "")
    }
    private func clear() {
        ticket = UUID(); entries = []; next = nil; loaded = false; busy = false
        message = nil; document = nil; exportScope = nil; exporting = false
        cleanupID = nil; cleanupReview = nil; cleanupAcknowledged = false; removingOriginal = false; comparison = nil; showingRestoration = false; restorationArchive = nil
    }
    private func load(after: String? = nil) async {
        guard visible, let captured = scope, !busy else { return }; let work = UUID(); ticket = work; busy = true; message = nil
        cleanupID = nil; cleanupReview = nil; cleanupAcknowledged = false
        defer { if ticket == work { busy = false } }
        do {
            let page = try await store.readChildTaskRepairArchives(after: after)
            guard scope == captured, ticket == work, !Task.isCancelled else { return }
            let replacing = after == nil || entries.count >= 500
            guard replacing || Set(entries.map(\.id)).isDisjoint(with: page.entries.map(\.id)) else { throw ChildTaskRepairCommand.invalid }
            entries = replacing ? page.entries : entries + page.entries; next = page.next; loaded = true
        } catch {
            guard scope == captured, ticket == work, !Task.isCancelled else { return }
            message = "Saved originals couldn’t be loaded. Check your connection and account access, then refresh."
        }
    }
    private func compare(_ entry: ChildTaskRepairArchive) async {
        guard visible, let captured = scope, captured == entry.scope, !busy, entry.contentRetained else { return }
        let work = UUID(); ticket = work; busy = true; message = nil
        cleanupID = nil; cleanupReview = nil; cleanupAcknowledged = false
        defer { if ticket == work { busy = false } }
        do {
            let value = try await store.compareChildTaskRepairOriginal(entry)
            guard visible, scope == captured, ticket == work, value.snapshot == store.snapshotRevision, !Task.isCancelled else { return }
            comparison = value
        } catch {
            guard visible, scope == captured, ticket == work, !Task.isCancelled else { return }
            message = "The original and current subtasks couldn’t be compared. Check your connection and current task access, then retry."
        }
    }
    private func export(_ entry: ChildTaskRepairArchive) async {
        guard visible, let captured = scope, captured == entry.scope, !busy else { return }; let work = UUID(); ticket = work; busy = true; message = nil
        defer { if ticket == work { busy = false } }
        do {
            let original = try await store.readDiscoveredChildTaskRepairOriginal(entry)
            guard scope == captured, ticket == work, !Task.isCancelled else { return }
            document = WorkspaceDocument(data: original.data); exportScope = captured; exporting = true
        } catch {
            guard scope == captured, ticket == work, !Task.isCancelled else { return }
            message = "This original couldn’t be opened with your current access. Its repair confirmation is kept."
        }
    }
    @ViewBuilder private func cleanupControls(_ entry: ChildTaskRepairArchive) -> some View {
        if cleanupID == entry.id {
            Text("Remove this saved original?").font(.headline)
            Text("Only the retained copy saved before this repair will be removed. Your current task and repair confirmation stay. Export the original first if you may need it. Removal is permanent and cannot be undone.")
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("childRepairCleanupWarning")
            if let review = cleanupReview, review.archive.id == entry.id, review.archive.scope == scope {
                if review.allowsRemoval {
                    Toggle("I understand this cannot be undone", isOn: $cleanupAcknowledged).accessibilityIdentifier("childRepairCleanupAcknowledged")
                    Button("Remove original", role: .destructive) { Task { await removeOriginal(entry) } }
                        .disabled(busy || !cleanupAcknowledged).accessibilityLabel("Permanently remove original: \(archiveTitle(entry))")
                        .accessibilityIdentifier("childRepairCleanupRemove")
                } else {
                    Text("Original cleanup is temporarily paused. This copy is still kept.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Cancel removal") { cleanupID = nil; cleanupReview = nil; cleanupAcknowledged = false }
                .disabled(busy).accessibilityIdentifier("childRepairCleanupCancel")
        } else {
            Button { Task { await reviewCleanup(entry) } } label: { ChildRepairActionLabel(title: "Review removal", symbol: "trash") }
                .disabled(busy).accessibilityLabel("Review removal of original: \(archiveTitle(entry))")
                .accessibilityIdentifier("childRepairCleanupReview-" + entry.id)
        }
    }
    private func reviewCleanup(_ entry: ChildTaskRepairArchive) async {
        guard visible, let captured = scope, captured == entry.scope, !busy, entry.contentRetained else { return }
        let work = UUID(); ticket = work; busy = true; message = nil
        cleanupID = entry.id; cleanupReview = nil; cleanupAcknowledged = false
        defer { if ticket == work { busy = false } }
        do {
            let review = try await store.childTaskRepairOriginalCleanup(entry, operation: .review)
            guard scope == captured, ticket == work, !Task.isCancelled else { return }
            if review.retained { cleanupReview = review }
            else { entries = entries.map { $0.id == entry.id ? $0.withoutOriginal() : $0 }; cleanupID = nil; message = "This original is no longer retained. Its repair confirmation is kept." }
        } catch {
            guard scope == captured, ticket == work, !Task.isCancelled else { return }
            cleanupID = nil; message = "Removal couldn’t be reviewed. Check your connection and permission to manage this copy, then refresh."
        }
    }
    private func removeOriginal(_ entry: ChildTaskRepairArchive) async {
        guard visible, let captured = scope, captured == entry.scope, !busy, cleanupAcknowledged,
              cleanupID == entry.id, cleanupReview?.archive.id == entry.id, cleanupReview?.archive.scope == captured,
              cleanupReview?.allowsRemoval == true else { return }
        let work = UUID(); ticket = work; busy = true; message = nil; removingOriginal = true
        defer { if ticket == work { busy = false; removingOriginal = false } }
        do {
            _ = try await store.childTaskRepairOriginalCleanup(entry, operation: .remove)
            guard scope == captured, ticket == work, !Task.isCancelled else { return }
            entries = entries.map { $0.id == entry.id ? $0.withoutOriginal() : $0 }
            cleanupID = nil; cleanupReview = nil; cleanupAcknowledged = false
            message = "Original removed. Your current task and repair confirmation are unchanged."
        } catch {
            guard scope == captured, ticket == work, !Task.isCancelled else { return }
            message = "Removal wasn’t confirmed. Refresh to check what is retained, or retry this same original."
        }
    }

}

private struct ChildRepairOriginalComparisonView: View {
    let comparison: ChildTaskRepairOriginalComparison
    let close: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showingCurrent = false
    private var side: ChildTaskRepairOriginalComparison.Side { showingCurrent ? comparison.current : comparison.saved }
    private var sidePicker: some View {
        Picker("Structure", selection: $showingCurrent) {
            Text("Saved original").tag(false)
            Text("Current").tag(true)
        }.accessibilityIdentifier("childRepairComparisonSide")
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(comparison.valuesMatch ? "Subtask values match" : "Subtask data differs", systemImage: comparison.valuesMatch ? "equal.circle" : "arrow.left.arrow.right.circle")
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("childRepairComparisonSummary")
                    Text("Compare the saved subtask structure with a fresh reading of the current task. Export the original for its complete task details and history.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if typeSize.isAccessibilitySize { sidePicker.pickerStyle(.menu) }
                    else { sidePicker.pickerStyle(.segmented) }
                }
                Section(showingCurrent ? "Current structure" : "Saved before repair") {
                    if let outline = side.outline, outline.rootKind == .array {
                        if outline.items.isEmpty { Text("No subtasks").foregroundStyle(.secondary) }
                        ForEach(outline.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).fixedSize(horizontal: false, vertical: true)
                                Text(item.path.map { String($0 + 1) }.joined(separator: " › "))
                                    .font(.caption).foregroundStyle(.secondary).accessibilityLabel("Position " + item.path.map { String($0 + 1) }.joined(separator: ", "))
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } else {
                        Text(side.outline?.rootKind == .null ? "No subtasks" : "This older structure needs its original-data view below.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.accessibilityIdentifier("childRepairComparisonStructure")
                Section {
                    DisclosureGroup("Source data") {
                        Text(side.excerpt).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("childRepairComparisonSource")
                        if side.shortened {
                            Text("Data preview shortened. Export the original to keep the complete saved copy.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }.id(showingCurrent)
                }
            }
            .navigationTitle("Compare subtasks")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done", action: close).keyboardShortcut(.cancelAction).accessibilityIdentifier("childRepairComparisonDone") } }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 540, minHeight: 420, idealHeight: 620)
        #endif
    }
}

/// Reviews are ephemeral; unresolved commands and confirmed reversal identities
/// are recovered from the encrypted account journal after closing or relaunch.
struct ChildTaskOriginalRestoreView: View {
    let archive: ChildTaskRepairArchive?
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var model: ChildTaskRestoreModel?
    @State private var review: ChildTaskRestoreReview?
    @State private var busy = false
    @State private var message: String?
    @State private var ticket = UUID()
    private var scope: ChildTaskFieldClientScope? { phase == .active ? store.childTaskFieldRecoveryScope : nil }
    var body: some View {
        NavigationStack {
            List {
                if let model, model.scope == scope {
                    Section {
                        Text("Restore only the saved subtask structure. Current task notes and priority stay current. Both versions are retained; an older structure stays read-only until Undo.")
                            .fixedSize(horizontal: false, vertical: true).foregroundStyle(.secondary)
                        if let archive, archive.scope == scope, archive.contentRetained, store.childTaskOriginalRestorationEnabled {
                            Button("Review saved structure") { Task { await prepare(identity: ChildTaskRestoreCommand.identity(archive), mode: .restore) } }
                                .disabled(busy || model.busy).accessibilityIdentifier("childRestorePrepare")
                        }
                        Button("Check saved requests") { Task { await model.load() } }.disabled(busy || model.busy)
                    }
                    if busy || model.busy { ProgressView("Checking subtask restoration…") }
                    if let feedback = message ?? model.message {
                        Text(feedback).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("childRestoreFeedback")
                    }
                    if model.loaded && model.entries.isEmpty { Text("No restoration requests saved on this device.").foregroundStyle(.secondary) }
                    ForEach(model.entries, id: \.command.id) { entry in
                        Section {
                            Text(store.record("tasks", id: entry.command.rootID)?.title ?? "Saved task").font(.headline).fixedSize(horizontal: false, vertical: true)
                            Text(status(entry)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if entry.phase == .queued || entry.phase == .attempted {
                                Button("Check status") { Task { await run(entry.command, .check) } }.accessibilityIdentifier("childRestoreCheck-" + entry.command.id)
                                Button("Retry this request") { Task { await run(entry.command, .send) } }.accessibilityIdentifier("childRestoreRetry-" + entry.command.id)
                                Button("Stop this request") { Task { await run(entry.command, .close) } }.accessibilityIdentifier("childRestoreStop-" + entry.command.id)
                            } else if entry.phase == .applied, latest(entry, in: model), store.childTaskOriginalReversalsEnabled, let result = entry.result {
                                Button(result.raw["phase"] == .string("restored") ? "Review Undo" : "Review Redo") {
                                    Task { await prepare(identity: entry.command.identity, mode: result.raw["phase"] == .string("restored") ? .undo : .redo, restorationID: result.raw["restoration_id"]!.text) }
                                }.accessibilityIdentifier("childRestoreReverse-" + entry.command.id)
                            }
                        }.disabled(busy || model.busy)
                    }
                } else if scope == nil {
                    Text("Return to your signed-in workspace to check saved restoration requests.").foregroundStyle(.secondary)
                } else { ProgressView("Reading saved requests…") }
            }
            .navigationTitle("Restore subtasks")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) } }
        }
        .task(id: scope) {
            close()
            guard scope != nil else { return }
            do { let value = try store.childTaskRestoreModel(); model = value; await value.load() }
            catch { message = "Saved restoration requests couldn’t be read. They are kept on this device." }
        }
        .onChange(of: store.snapshotRevision) { _, _ in review = nil }
        .onDisappear { close() }
        .sheet(item: $review) { value in
            if value.scope == scope, store.childTaskRestoreReviewIsCurrent(value) {
                ChildTaskRestoreReviewView(review: value, close: { review = nil }, apply: { Task { await apply(value) } })
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 560, minHeight: 420, idealHeight: 620)
        #endif
    }
    private func close() { ticket = UUID(); model?.close(); model = nil; review = nil; busy = false; message = nil }
    private func status(_ entry: ChildTaskRestoreState.Entry) -> String {
        if entry.phase == .queued { return "Saved on this device; not yet confirmed." }
        if entry.phase == .attempted { return "Confirmation needed. Check status before starting another request." }
        if entry.phase == .closed { return "Stopped. This request made no change." }
        return entry.result?.raw["phase"] == .string("restored") ? "Saved structure restored. Both versions are kept." : "Restoration undone. Both versions are kept."
    }
    private func latest(_ entry: ChildTaskRestoreState.Entry, in model: ChildTaskRestoreModel) -> Bool {
        guard let result = entry.result else { return false }
        return !model.entries.contains { other in other.result?.raw["restoration_id"] == result.raw["restoration_id"] && (other.result?.raw["next_revision"]?.integer ?? 0) > result.raw["next_revision"]!.integer }
    }
    private func prepare(identity: [String: JSON], mode: ChildTaskRestoreMode, restorationID: String? = nil) async {
        guard !busy, let captured = scope else { return }; let work = UUID(); ticket = work; busy = true; message = nil
        defer { if ticket == work { busy = false } }
        do {
            let value = try await store.readChildTaskRestoreReview(identity: identity, mode: mode, restorationID: restorationID)
            guard ticket == work, scope == captured, !Task.isCancelled else { return }; review = value
        } catch {
            guard ticket == work, scope == captured, !Task.isCancelled else { return }
            message = "This version couldn’t be reviewed. Refresh the task and check access. Newer subtask work and both saved copies are kept."
        }
    }
    private func apply(_ value: ChildTaskRestoreReview) async {
        guard let model, review?.id == value.id, store.childTaskRestoreReviewIsCurrent(value) else { return }
        do {
            let command = try ChildTaskRestoreCommand(review: value)
            review = nil
            if await model.queue(command, review: value) { await run(command, .send) }
        } catch { message = "This review is no longer current. Review it again before applying." }
    }
    private func run(_ command: ChildTaskRestoreCommand, _ operation: ChildTaskRepairOperation) async {
        guard let model, model.scope == scope else { return }
        message = nil; review = nil
        if await model.run(command, operation: operation), model.scope == scope,
           model.entries.first(where: { $0.command == command })?.result?.applied == true { await store.sync() }
    }
}

private struct ChildTaskRestoreReviewView: View {
    let review: ChildTaskRestoreReview
    let close: () -> Void
    let apply: () -> Void
    @State private var target = true
    @State private var acknowledged = false
    private var side: ChildTaskRepairOriginalComparison.Side { target ? review.target : review.current }
    private var action: String { review.mode == .restore ? "Restore saved structure" : review.mode == .undo ? "Undo restoration" : "Redo restoration" }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Only subtasks change. Task notes, priority and other root details stay current. Both versions are retained.").fixedSize(horizontal: false, vertical: true)
                    if review.mode != .undo { Text("The restored older structure will be read-only. Use Undo to return to the editable version.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    if review.fileCount > 0 { Text("\(review.fileCount) stored file(s) will remain retained for reversal.").fixedSize(horizontal: false, vertical: true) }
                    Picker("Structure", selection: $target) { Text("After this action").tag(true); Text("Current").tag(false) }.pickerStyle(.menu)
                }
                Section(target ? "After this action" : "Current structure") {
                    if let outline = side.outline, outline.rootKind == .array {
                        if outline.items.isEmpty { Text("No subtasks").foregroundStyle(.secondary) }
                        ForEach(outline.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).fixedSize(horizontal: false, vertical: true)
                                Text(item.path.map { String($0 + 1) }.joined(separator: " › ")).font(.caption).foregroundStyle(.secondary)
                            }.accessibilityElement(children: .combine)
                        }
                    } else { Text("This older structure needs its source-data view below.").foregroundStyle(.secondary) }
                    DisclosureGroup("Source data") {
                        Text(side.excerpt).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if side.shortened { Text("Source preview shortened. The complete source stays retained.").foregroundStyle(.secondary) }
                    }.id(target)
                }
                Section {
                    if review.enabled {
                        Toggle("I reviewed this subtask version", isOn: $acknowledged).accessibilityIdentifier("childRestoreAcknowledged")
                        Button(action, action: apply).disabled(!acknowledged).accessibilityIdentifier("childRestoreApply")
                    } else {
                        Text(review.metadata["availability"] == .string("paused") ? "Restoration is temporarily paused. Both copies are kept." : "This version needs a storage review before restoration. Both copies are kept.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle("Review subtask version")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close).keyboardShortcut(.cancelAction) } }
        }
    }
}
