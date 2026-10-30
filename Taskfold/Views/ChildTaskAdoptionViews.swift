import SwiftUI
import UniformTypeIdentifiers

struct SavedChildTaskAdoptionsLink: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var visible = false
    @State private var showing = false
    @State private var revision = UUID()
    private var scope: ChildTaskFieldClientScope? { phase == .active ? store.childTaskFieldRecoveryScope : nil }
    var body: some View {
        Group {
            if scope != nil, visible || store.childTaskAdoptionEnabled {
                Section { Button("Subtask storage", systemImage: "arrow.up.circle") { showing = true }.accessibilityIdentifier("savedChildAdoptions") }
            }
        }
        .task(id: scope) { await discover() }
        .task(id: revision) { await discover() }
        .sheet(isPresented: $showing, onDismiss: { revision = UUID() }) { WorkflowShell(title: "Subtask storage") { ChildTaskAdoptionView() } }
    }
    private func discover() async {
        visible = false; guard let captured = scope else { return }
        do {
            let state = try await store.childTaskAdoptionJournal(account: captured.account, origin: captured.origin).load()
            guard captured == scope, !Task.isCancelled else { return }; visible = !state.entries.isEmpty
        } catch { guard captured == scope, !Task.isCancelled else { return }; visible = true }
    }
}

struct ChildTaskAdoptionView: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var selected: String?
    @State private var model: ChildTaskAdoptionModel?
    @State private var modelScope: ChildTaskFieldClientScope?
    @State private var read: ChildTaskAdoptionReview?
    @State private var reading = false
    @State private var ticket = UUID()
    @State private var activeID: String?
    @State private var failure: String?
    @State private var search = ""
    @State private var exportDocument: WorkspaceDocument?
    @State private var exporting = false
    @State private var exportScope: ChildTaskFieldClientScope?
    @State private var exportRoot: String?
    @State private var exportMessage: String?
    init(rootID: String? = nil) { _selected = State(initialValue: rootID) }
    private var scope: ChildTaskFieldClientScope? { store.childTaskFieldRecoveryScope }
    private var usable: Bool { phase == .active && scope != nil && modelScope == scope }
    private var currentRead: ChildTaskAdoptionReview? { guard usable, let read, store.childTaskAdoptionReviewIsCurrent(read) else { return nil }; return read }
    private var active: ChildTaskAdoptionState.Entry? {
        guard usable else { return nil }
        return model?.entries.first { $0.command.id == activeID } ?? model?.entries.first { $0.command.rootID == selected && ($0.phase == .queued || $0.phase == .attempted) }
    }
    private var form: some View {
        List {
            if usable, let model {
                if let failure { Section { Text(failure).fixedSize(horizontal: false, vertical: true).foregroundStyle(.secondary) } }
                if let message = model.message, active?.phase != .applied { Section { Text(message).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("childAdoptionFeedback") } }
                if let exportMessage { Section { Text(exportMessage).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("childAdoptionExportFeedback") } }
                if let selected {
                    Section {
                        Text(active != nil ? "Saved upgrade" : store.record("tasks", id: selected)?.title ?? "Task unavailable").font(.headline).fixedSize(horizontal: false, vertical: true)
                        Button("All tasks and saved decisions") { select(nil) }.accessibilityIdentifier("childAdoptionAll")
                    }
                    if let active {
                        Section { ChildAdoptionSavedRow(entry: active, model: model) }
                        if active.phase == .closed { Section { Button("Review the current task") { activeID = nil; Task { await refresh() } } } }
                    } else if reading { ProgressView("Reviewing saved subtasks…") }
                    else if let read = currentRead {
                        Section("Review") {
                            if read.metadata["state"] == .string("records") {
                                Label("Already up to date", systemImage: "checkmark.circle").font(.headline).accessibilityIdentifier("childAdoptionCurrent")
                            } else if read.metadata["state"] == .string("review") {
                                Label("Some older items need review", systemImage: "text.magnifyingglass").font(.headline).accessibilityIdentifier("childAdoptionNeedsReview")
                                Text(explanation(read.metadata["issue"]?.text ?? "")).fixedSize(horizontal: false, vertical: true)
                                Text("Your original content is kept. Export it before making repairs.").font(.footnote).foregroundStyle(.secondary)
                            } else {
                                Text(read.preview.count == 1 ? "1 saved subtask" : "\(read.preview.count) saved subtasks").font(.headline).accessibilityIdentifier("childAdoptionCount")
                                Text("Your task’s content stays the same. The upgrade enables newer subtask editing and recovery.").fixedSize(horizontal: false, vertical: true)
                                Text("Close this task’s editors and finish unsent changes first. Use a current Taskfold app for future subtask edits.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                if read.eligible {
                                    Button { Task { await upgrade(read) } } label: { ChildAdoptionActionLabel(title: "Upgrade subtasks", icon: "arrow.up.circle") }
                                        .disabled(model.busy || !store.online || !store.childTaskAdoptionReviewIsCurrent(read)).accessibilityIdentifier("childAdoptionSend")
                                } else { Text("Upgrade is unavailable with the current workspace permissions or settings.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                            }
                        }
                        if !read.preview.isEmpty {
                            Section("Saved order") {
                                ForEach(read.preview) { item in
                                    Text(item.title?.isEmpty == false ? item.title! : "Untitled subtask")
                                        .fixedSize(horizontal: false, vertical: true).padding(.leading, CGFloat(min(item.depth - 1, 6) * 12))
                                        .accessibilityLabel((item.title ?? "Untitled subtask") + (item.depth > 1 ? ", nested subtask" : ""))
                                }
                            }
                        }
                        if let source = read.originalSource {
                            Section {
                                Button { export(source) } label: { ChildAdoptionActionLabel(title: "Export original content", icon: "square.and.arrow.up") }
                                    .disabled(model.busy).accessibilityIdentifier("childAdoptionExport")
                                if read.metadata["state"] == .string("review") {
                                    DisclosureGroup("Original content · read-only") {
                                        Text(String(decoding: source.prefix(16_384), as: UTF8.self)).font(.caption.monospaced()).textSelection(.enabled).lineLimit(12)
                                        Text("The preview is shortened. Export keeps the complete original content.").font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } else { Section { Text("This content is too large to include in the review. Its original stays saved; this review cannot upgrade it or export a partial copy.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) } }
                    } else if !reading { Section { Text("Refresh to review the current saved content.").foregroundStyle(.secondary) } }
                    Section { Button("Refresh review", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(model.busy || reading || !store.online || !store.childTaskAdoptionEnabled).accessibilityIdentifier("childAdoptionRefresh") }
                } else {
                    if store.childTaskAdoptionEnabled {
                        Section("Review a task") {
                            Text("Upgrade saved subtasks one task at a time. Private drafts and unfinished actions stay protected.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            ForEach(store.childTaskAdoptionTargets().filter { search.isEmpty || $0.title.localizedStandardContains(search) }) { root in
                                Button(root.title) { select(root.id) }.disabled(model.busy || !model.loaded).accessibilityIdentifier("childAdoptionTarget-" + root.id)
                            }
                        }
                    }
                    if !model.entries.isEmpty {
                        ForEach(model.entries, id: \.command.id) { entry in Section { ChildAdoptionSavedRow(entry: entry, model: model) } }
                    } else if model.loaded { ContentUnavailableView("No saved upgrades", systemImage: "arrow.up.circle", description: Text("Upgrades awaiting confirmation and recent decisions appear here.")) }
                }
            } else { ContentUnavailableView("Subtask storage unavailable", systemImage: "arrow.up.circle", description: Text("Return to your signed-in workspace to continue.")) }
        }
    }
    var body: some View {
        Group { if selected == nil { form.searchable(text: $search, prompt: "Find a task") } else { form } }
            .privacySensitive()
            .task(id: scope) { await open() }
            .onChange(of: phase) { _, value in if value == .active { Task { await open() } } else { close() } }
            .onChange(of: scope) { before, after in
                exporting = false; exportDocument = nil; exportScope = nil; exportRoot = nil; exportMessage = nil
                if before?.account != after?.account || before?.origin != after?.origin || before?.workspace != after?.workspace || after == nil { selected = nil; activeID = nil }
            }
            .onChange(of: store.snapshotRevision) { _, _ in if !reading { read = nil } }
            .onDisappear { close() }
            .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "original-subtasks-" + Dates.day(Date())) { result in
                guard exportScope == scope, exportRoot == selected else { return }
                exportDocument = nil
                switch result {
                case .success: exportMessage = "Original content exported. Your saved task is unchanged."
                case .failure(let error): exportMessage = (error as NSError).code == NSUserCancelledError ? nil : "Export couldn’t finish. Your original content is still saved."
                }
            }
    }
    private func select(_ root: String?) { ticket = UUID(); selected = root; activeID = nil; read = nil; failure = nil; exportMessage = nil; reading = false; if root != nil { Task { await refresh() } } }
    private func close() { model?.close(); model = nil; modelScope = nil; read = nil; ticket = UUID(); reading = false; failure = nil }
    private func open() async {
        close(); guard phase == .active, let captured = scope else { return }
        do {
            let value = try store.childTaskAdoptionModel(); model = value; modelScope = captured; await value.load()
            guard captured == scope, model === value, phase == .active, !Task.isCancelled else { return }
            if selected != nil, active == nil { await refresh() }
        } catch { guard captured == scope else { return }; failure = "Saved upgrades couldn’t be read. Their originals are kept." }
    }
    private func refresh() async {
        guard usable, let root = selected else { return }
        let captured = scope, request = UUID(); ticket = request; reading = true; read = nil; failure = nil
        defer { if ticket == request { reading = false } }
        do {
            let value = try await store.readChildTaskAdoption(root)
            guard captured == scope, ticket == request, selected == root, phase == .active, !Task.isCancelled else { return }; read = value
        } catch {
            guard captured == scope, ticket == request, selected == root, phase == .active else { return }
            failure = (error as? AppFailure)?.localizedDescription ?? (error as? ChildTaskAdoptionFailure)?.localizedDescription ?? "The current review couldn’t be loaded. Saved work is kept; try refreshing."
        }
    }
    private func upgrade(_ read: ChildTaskAdoptionReview) async {
        guard usable, let model else { return }
        do {
            let command = try ChildTaskAdoptionCommand(review: read); activeID = command.id
            if await model.queue(command, review: read) { _ = await model.run(command, operation: .send) }
            if usable, model.entries.first(where: { $0.command.id == command.id })?.phase == .applied { self.read = nil; await store.sync() }
        } catch { failure = "This task needs a fresh review. Your original content is kept." }
    }
    private func export(_ source: Data) {
        guard usable, currentRead != nil else { return }
        exportScope = scope; exportRoot = selected; exportMessage = nil; exportDocument = WorkspaceDocument(data: source); exporting = true
    }
    private func explanation(_ issue: String) -> String {
        switch issue {
        case "identity": return "Some items don’t have a supported reference. They haven’t been renamed or replaced."
        case "duplicate_identity": return "Some items share the same reference. No item has been chosen over another."
        case "root_shape", "children_shape": return "Some saved content uses an older format that needs an explicit repair."
        case "node_limit", "depth_limit", "source_size": return "This hierarchy exceeds the supported size or nesting limit. No part has been dropped."
        default: return "The saved hierarchy and its separate records need review together. Neither copy has been overwritten."
        }
    }
}

private struct ChildAdoptionActionLabel: View {
    let title: String, icon: String
    var body: some View { HStack(alignment: .firstTextBaseline, spacing: 8) { Image(systemName: icon).accessibilityHidden(true); Text(title).fixedSize(horizontal: false, vertical: true) }.frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44).contentShape(Rectangle()) }
}
private struct ChildAdoptionSavedRow: View {
    let entry: ChildTaskAdoptionState.Entry
    let model: ChildTaskAdoptionModel
    @Environment(Store.self) private var store
    @State private var stopping = false
    @State private var forgetting = false
    private var title: String { store.childTaskAdoptionTitle(entry.command) }
    private var status: String { switch entry.phase { case .queued: return "Saved on this device"; case .attempted: return "Awaiting confirmation"; case .applied: return "Subtasks upgraded"; case .closed: return "Upgrade stopped" } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(status).font(.headline).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("childAdoptionStatus")
            Text(title).fixedSize(horizontal: false, vertical: true)
            if entry.phase == .applied { Text("Your task’s content is unchanged.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if entry.phase == .queued || entry.phase == .attempted {
                Button { Task { if await model.run(entry.command, operation: .check) { await store.sync() } } } label: { ChildAdoptionActionLabel(title: "Check status", icon: "arrow.clockwise") }.disabled(model.busy || !store.online)
                Button { Task { if await model.run(entry.command, operation: .send) { await store.sync() } } } label: { ChildAdoptionActionLabel(title: "Retry original upgrade", icon: "arrow.up.circle") }.disabled(model.busy || !store.online || !store.permitsChildTaskAdoption(entry.command, sending: true))
                Button("Check and stop upgrade") { stopping = true }.disabled(model.busy || !store.online)
            }
            if entry.phase != .attempted {
                Menu { Button(entry.phase == .queued ? "Remove unsent upgrade" : "Remove saved history", role: .destructive) { forgetting = true } } label: { ChildAdoptionActionLabel(title: "More", icon: "ellipsis") }.disabled(model.busy)
            }
        }.padding(.vertical, 4).buttonStyle(.borderless)
        .confirmationDialog("Check and stop this upgrade?", isPresented: $stopping, titleVisibility: .visible) {
            Button("Check and stop", role: .destructive) { Task { if await model.run(entry.command, operation: .close) { await store.sync() } } }
        } message: { Text("An upgrade already applied keeps its confirmation. An unapplied request will be permanently stopped before you review a new one.") }
        .confirmationDialog("Remove this saved history?", isPresented: $forgetting, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await model.discard(entry.command) } }
        } message: { Text("This removes local recovery history. It does not change the task or reverse its upgrade.") }
    }
}
