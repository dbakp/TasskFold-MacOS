import SwiftUI

struct ChildTaskTransferOpening: Identifiable { let id = UUID(); let nodeKey: String }
struct ChildTaskTransferLink: View {
    let rootID: String, nodeKey: String
    let show: () -> Void
    @Environment(Store.self) private var store
    var body: some View {
        if store.childTaskTransfersEnabled {
            Button(action: show) { Label("Move to another task", systemImage: "arrow.right.square").frame(minHeight: 44) }
                .accessibilityLabel("Move subtask to another task")
                .accessibilityIdentifier("transferChild-" + nodeKey)
        }
    }
}
struct SavedChildTaskTransfersLink: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var showing = false
    private var scope: ChildTaskFieldClientScope? { phase == .active ? store.childTaskFieldRecoveryScope : nil }
    var body: some View {
        Group {
            if scope != nil, store.hasSavedChildRecovery(.transfers) || store.childTaskTransfersEnabled {
                Section {
                    Button("Saved subtask moves", systemImage: "arrow.left.arrow.right") { showing = true }.accessibilityIdentifier("savedChildTransfers")
                        .sheet(isPresented: $showing, onDismiss: { Task { await store.refreshChildTaskRecoveryPresence() } }) { WorkflowShell(title: "Saved subtask moves") { ChildTaskTransferRecoveryView() } }
                }
            }
        }
    }
}

struct ChildTaskTransferView: View {
    let rootID: String, nodeKey: String
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var model: ChildTaskTransferModel?
    @State private var modelScope: ChildTaskFieldClientScope?
    @State private var destination = ""
    @State private var parent = ""
    @State private var index = 0
    @State private var search = ""
    @State private var sourceRead: ChildTaskStructureRead?
    @State private var destinationRead: ChildTaskStructureRead?
    @State private var reading = false
    @State private var failure: String?
    @State private var activeID: String?
    @State private var ticket = UUID()
    private var scope: ChildTaskFieldClientScope? { phase == .active ? store.childTaskFieldRecoveryScope : nil }
    private var active: ChildTaskTransferState.Entry? {
        guard modelScope == scope else { return nil }
        return model?.entries.first { $0.command.id == activeID } ?? model?.entries.first { ($0.phase == .queued || $0.phase == .attempted) && $0.command.roots.contains(rootID) }
    }
    private var targets: [Record] {
        store.childTaskTransferTargets(source: rootID).filter { search.isEmpty || $0.title.localizedStandardContains(search) }
    }
    private var form: some View {
        List {
            if let failure { Section { Text(failure).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) } }
            if let model, modelScope == scope, scope != nil {
                if let active {
                    Section { ChildTransferSavedRow(entry: active, model: model, undo: { await prepareUndo($0) }) }
                    if active.phase == .closed { Section { Button("Review a new move") { resetDestination(); activeID = nil } } }
                } else if destination.isEmpty {
                    Section {
                        Text("Move a subtask and its nested work into another saved task.").fixedSize(horizontal: false, vertical: true)
                        Text("Only saved content moves. Finish unsent edits first.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Destination task") {
                        if targets.isEmpty { Text("No matching tasks are available in this workspace.").foregroundStyle(.secondary) }
                        ForEach(targets) { target in
                            Button { destination = target.id; parent = ""; index = 0 } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(target.title).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                                    Text(store.record("projects", id: target.string("project_id"))?.name ?? "Inbox").font(.footnote).foregroundStyle(.secondary)
                                }.padding(.vertical, 4)
                            }.accessibilityIdentifier("childTransferTarget-" + target.id)
                        }
                    }
                } else {
                    Section("Destination") {
                        Text(store.record("tasks", id: destination)?.title ?? "Task unavailable").font(.headline).fixedSize(horizontal: false, vertical: true)
                        Button("Choose a different task") { resetDestination() }
                    }
                    if reading { ProgressView("Reading both tasks…") }
                    if let from = sourceRead, let to = destinationRead, let node = from.records.nodes[nodeKey] {
                        Section("Placement") {
                            Picker("Under", selection: $parent) {
                                Text("Top level").tag("")
                                ForEach(to.records.orderedNodes, id: \.key) { n in
                                    Text(String(repeating: "  ", count: min(n.path.count - 1, 5)) + (n.fields["title"]?.text ?? "Subtask")).tag(n.key)
                                }
                            }.accessibilityIdentifier("childTransferParent")
                            Picker("Position", selection: $index) {
                                ForEach(Array(siblings(to).enumerated()), id: \.offset) { slot, n in Text("Before " + (n.fields["title"]?.text ?? "Subtask")).tag(slot) }
                                Text("At the end").tag(siblings(to).count)
                            }.accessibilityIdentifier("childTransferPosition")
                            if !parent.isEmpty, let selected = to.records.nodes[parent] {
                                Text(selected.fields["title"]?.text ?? "Subtask").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Section("Review move") {
                            Text(node.fields["title"]?.text ?? "Subtask").font(.headline).fixedSize(horizontal: false, vertical: true)
                            let count = ChildTaskTransferCommand.versions(node, from).count
                            Text(count == 1 ? "This subtask will move." : count == 2 ? "This subtask and 1 nested item will move." : "This subtask and \(count - 1) nested items will move.").fixedSize(horizontal: false, vertical: true)
                            if from.context.root["project_id"] != to.context.root["project_id"] { Text("Assignments in this branch will be cleared when it changes projects.").font(.footnote).foregroundStyle(.secondary) }
                            Text("You can Undo until either task is reorganized or the moved items change.").font(.footnote).foregroundStyle(.secondary)
                            Button("Move subtask", systemImage: "arrow.right.square") { Task { await move(from: from, to: to) } }
                                .disabled(model.busy || reading || !store.online).accessibilityIdentifier("childTransferSend")
                        }
                    }
                    if !reading { Section { Button("Refresh both tasks", systemImage: "arrow.clockwise") { Task { await readPair() } }.disabled(model.busy || !store.online) } }
                }
            } else { ContentUnavailableView("Move unavailable", systemImage: "arrow.left.arrow.right", description: Text("Return to your signed-in workspace to continue.")) }
        }
    }
    var body: some View {
        Group {
            if destination.isEmpty && active == nil { form.searchable(text: $search, prompt: "Find a destination task") }
            else { form }
        }
        .safeAreaInset(edge: .bottom) {
            if let model, modelScope == scope, scope != nil, let message = model.message { ChildTransferFeedback(message: message) }
        }
        .privacySensitive()
        .task(id: scope) { await open() }
        .task(id: destination) { if !destination.isEmpty { await readPair() } }
        .onChange(of: parent) { _, _ in index = 0 }
        .onDisappear { model?.close(); ticket = UUID(); sourceRead = nil; destinationRead = nil }
    }
    private func siblings(_ read: ChildTaskStructureRead) -> [ChildTaskRecordRead.Node] { read.records.orderedNodes.filter { $0.parent == (parent.isEmpty ? nil : parent) } }
    private func resetDestination() { ticket = UUID(); destination = ""; parent = ""; index = 0; sourceRead = nil; destinationRead = nil; failure = nil; reading = false }
    private func open() async {
        model?.close(); model = nil; modelScope = nil; sourceRead = nil; destinationRead = nil; failure = nil; ticket = UUID()
        guard let captured = scope else { return }
        do { let value = try store.childTaskTransferModel(); model = value; modelScope = captured; await value.load(); if !destination.isEmpty { await readPair() } }
        catch { guard captured == scope else { return }; failure = "Saved moves couldn’t be read. Their originals are kept." }
    }
    private func readPair() async {
        guard let captured = scope, modelScope == captured, !destination.isEmpty else { return }
        let target = destination, request = UUID(); ticket = request; reading = true; failure = nil; sourceRead = nil; destinationRead = nil
        defer { if request == ticket { reading = false } }
        do {
            let (a, b) = try await store.readChildTaskTransferPair(source: rootID, destination: target)
            guard request == ticket, captured == scope, destination == target, !Task.isCancelled else { return }
            guard a.records.nodes[nodeKey] != nil else { failure = "This subtask moved or changed. Return to the current task before reviewing another move."; return }
            sourceRead = a; destinationRead = b; index = 0
        } catch { guard request == ticket, captured == scope else { return }; failure = "Both tasks need a fresh read. Check your connection and refresh to continue." }
    }
    private func move(from: ChildTaskStructureRead, to: ChildTaskStructureRead) async {
        guard let model, modelScope == scope else { return }
        do {
            let command = try ChildTaskTransferCommand(node: nodeKey, parent: parent.isEmpty ? nil : parent, index: index, source: from, destination: to)
            activeID = command.id
            let queued = await model.queue(command, source: from, destination: to)
            guard modelScope == scope else { return }
            if model.entries.contains(where: { $0.command == command }) { sourceRead = nil; destinationRead = nil }
            if queued { _ = await model.run(command, operation: .send) }
            if model.entries.first(where: { $0.command.id == command.id })?.phase == .applied { await store.sync() }
        } catch let error as ChildTaskTransferFailure { failure = error.localizedDescription }
        catch { failure = "This move needs a fresh review. Refresh both tasks or choose another destination." }
    }
    private func prepareUndo(_ entry: ChildTaskTransferState.Entry) async {
        guard let model, let receipt = entry.result, modelScope == scope else { return }
        do {
            let (a, b) = try await store.readChildTaskTransferPair(source: entry.command.body["destination"]!.object["task_id"]!.text, destination: entry.command.body["source"]!.object["task_id"]!.text)
            guard modelScope == scope else { return }
            let undo = try ChildTaskTransferCommand(undo: entry.command, receipt: receipt, source: a, destination: b)
            if await model.queue(undo, source: a, destination: b) { activeID = undo.id; _ = await model.run(undo, operation: .send); await store.sync() }
        } catch { failure = "This move can no longer be undone safely. Your current work is kept." }
    }
}

private struct ChildTransferSavedRow: View {
    let entry: ChildTaskTransferState.Entry
    let model: ChildTaskTransferModel
    let undo: (ChildTaskTransferState.Entry) async -> Void
    @Environment(Store.self) private var store
    @State private var stopping = false
    @State private var forgetting = false
    private var status: String {
        switch entry.phase { case .queued: return "Saved on this device"; case .attempted: return "Awaiting confirmation"; case .applied: return entry.command.undoing ? "Move undone" : "Move confirmed"; case .closed: return "Move stopped" }
    }
    private func title(_ endpoint: String) -> String {
        let fields = entry.command.body[endpoint]!.object
        guard let root = store.record("tasks", id: fields["task_id"]!.text), root["task_generation"] == fields["task_generation"], root["project_id"] == fields["project_id"] else { return "Task unavailable" }
        return root.title
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(status, systemImage: entry.phase == .applied ? "checkmark.circle" : "arrow.left.arrow.right").font(.headline)
            Text(title("source") + " → " + title("destination")).fixedSize(horizontal: false, vertical: true)
            if entry.phase == .queued || entry.phase == .attempted {
                ViewThatFits(in: .horizontal) { HStack(spacing: 16) { actions }; VStack(alignment: .leading, spacing: 12) { actions } }
                Button("Check and stop move") { stopping = true }.disabled(model.busy || !store.online)
            }
            if entry.phase == .applied, !entry.command.undoing,
               !model.entries.contains(where: { $0.command.undoing && $0.command.family == entry.command.id && $0.phase != .closed }) {
                Button { Task { await undo(entry) } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "arrow.uturn.backward").accessibilityHidden(true)
                        Text("Undo move").fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Undo move")
                .disabled(model.busy || !store.online || !store.childTaskTransfersEnabled)
            }
            if entry.phase != .attempted {
                Menu {
                    Button(entry.phase == .queued ? "Remove unsent move" : "Remove saved history", role: .destructive) { forgetting = true }
                } label: { Label("More", systemImage: "ellipsis").frame(minHeight: 44) }.disabled(model.busy)
            }
        }
        .buttonStyle(.borderless).padding(.vertical, 4)
        .confirmationDialog("Check and stop this move?", isPresented: $stopping, titleVisibility: .visible) {
            Button("Check and stop", role: .destructive) { Task { if await model.run(entry.command, operation: .close) { await store.sync() } } }
        } message: { Text("An applied move keeps its confirmation. A move that has not happened will be permanently stopped before you review a new one.") }
        .confirmationDialog("Remove this saved history?", isPresented: $forgetting, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await model.discard(entry.command) } }
        } message: { Text(entry.phase == .queued ? "This unsent move will be removed from this device. Your tasks won’t change." : "Removing this history also removes its Undo shortcut. Your tasks won’t change.") }
    }
    @ViewBuilder private var actions: some View {
        Button("Check status", systemImage: "arrow.clockwise") { Task { if await model.run(entry.command, operation: .check) { await store.sync() } } }.disabled(model.busy || !store.online)
        Button("Retry original move", systemImage: "arrow.right") { Task { if await model.run(entry.command, operation: .send) { await store.sync() } } }.disabled(model.busy || !store.online || !store.permitsChildTaskTransferRequest(entry.command, sending: true))
    }
}

struct ChildTaskTransferRecoveryView: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var model: ChildTaskTransferModel?
    @State private var modelScope: ChildTaskFieldClientScope?
    @State private var failure: String?
    private var scope: ChildTaskFieldClientScope? { phase == .active ? store.childTaskFieldRecoveryScope : nil }
    var body: some View {
        List {
            if let failure { Text(failure).foregroundStyle(.secondary) }
            if let model, scope != nil, modelScope == scope {
                if model.loaded && model.entries.isEmpty { ContentUnavailableView("No saved moves", systemImage: "arrow.left.arrow.right", description: Text("Moves awaiting confirmation and recent Undo shortcuts appear here.")) }
                ForEach(model.entries, id: \.command.id) { entry in Section { ChildTransferSavedRow(entry: entry, model: model, undo: { await undo($0) }) } }
                Section { Button("Read saved moves again", systemImage: "arrow.clockwise") { Task { await model.load() } }.disabled(model.busy) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let model, modelScope == scope, scope != nil, let message = model.message { ChildTransferFeedback(message: message) }
        }
        .privacySensitive()
        .task(id: scope) {
            model?.close(); model = nil; modelScope = nil; failure = nil
            guard let captured = scope else { return }
            do { let value = try store.childTaskTransferModel(); model = value; modelScope = captured; await value.load() }
            catch { guard captured == scope else { return }; failure = "Saved moves couldn’t be read. Their originals are kept." }
        }
        .onDisappear { model?.close() }
    }
    private func undo(_ entry: ChildTaskTransferState.Entry) async {
        guard let model, let receipt = entry.result, modelScope == scope else { return }
        do {
            let (a, b) = try await store.readChildTaskTransferPair(source: entry.command.body["destination"]!.object["task_id"]!.text, destination: entry.command.body["source"]!.object["task_id"]!.text)
            guard modelScope == scope else { return }
            let command = try ChildTaskTransferCommand(undo: entry.command, receipt: receipt, source: a, destination: b)
            if await model.queue(command, source: a, destination: b) { _ = await model.run(command, operation: .send); await store.sync() }
        } catch { failure = "This move can no longer be undone safely. Your current work is kept." }
    }
}

private struct ChildTransferFeedback: View {
    let message: String
    var body: some View {
        Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal).padding(.vertical, 8)
            .accessibilityIdentifier("childTransferStatus")
    }
}
