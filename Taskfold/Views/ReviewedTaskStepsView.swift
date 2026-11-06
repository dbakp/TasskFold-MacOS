import SwiftUI

struct ReviewedTaskStepsOpening: Identifiable {
    let id = UUID()
    let root: String
    var parent: String? = nil
}

/// Operates on saved records, separately from any surrounding editor draft.
struct ReviewedTaskStepsView: View {
    #if os(macOS)
    @Environment(Workspace.self) private var workspace
    #endif
    let opening: ReviewedTaskStepsOpening
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var model: ReviewedTaskStepsModel?
    @State private var read: ChildTaskStructureRead?
    @FocusState private var editing: Bool
    @State private var goal = ""
    @State private var steps: [Step] = []
    @State private var ready = false
    @State private var reading = false
    @State private var readToken = UUID()
    @State private var generating = false
    @State private var token = UUID()
    @State private var generation: Task<Void, Never>?
    #if DEBUG
    @State private var fixtureSeeded = false
    #endif
    @State private var error: String?
    @State private var forgetting: ReviewedTaskStepsCommand?
    private struct Step: Identifiable { let id = UUID(); var title: String; var included = true }
    // Disappearing controls can read their binding after a save/removal clears the row.
    // Resolve by identity on each access instead of retaining an array-index binding.
    private func stepBinding<Value>(_ step: Step, _ path: WritableKeyPath<Step, Value>) -> Binding<Value> {
        Binding(get: { steps.first { $0.id == step.id }?[keyPath: path] ?? step[keyPath: path] }, set: { value in
            guard let index = steps.firstIndex(where: { $0.id == step.id }) else { return }
            steps[index][keyPath: path] = value
        })
    }

    private var scope: ChildTaskFieldClientScope? { phase == .active ? store.childTaskFieldRecoveryScope : nil }
    private var current: Bool { guard let read, model?.scope == scope, scope != nil else { return false }; return store.childTaskFieldComparisonIsCurrent(read.records) }
    private var selected: [String] { steps.filter(\.included).map(\.title) }
    private var pending: Bool { model?.entries.contains { $0.command.root == opening.root && ($0.phase == .queued || $0.phase == .attempted) } == true }
    private var selectionProblem: String? {
        guard !steps.isEmpty else { return nil }
        do { _ = try TaskBreakdownRequest.titles(selected); return nil } catch { return error.localizedDescription }
    }
    private var activity: String? {
        if model?.busy == true { return "Updating saved steps…" }
        return reading ? "Reading task…" : nil
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Work with saved subtasks. Any unsaved changes in the task editor stay separate.").font(.callout).foregroundStyle(.secondary)
                    if let activity {
                        HStack(spacing: 10) {
                            ProgressView().progressViewStyle(.circular).controlSize(.small).accessibilityHidden(true)
                            Text(activity)
                        }.accessibilityElement(children: .combine).accessibilityIdentifier("reviewedStepsWorking")
                    }
                    if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("reviewedStepsError") }
                    if let message = model?.message { Text(message).accessibilityIdentifier("reviewedStepsStatus") }
                }
                if current, ready, !pending {
                    Section("Suggest steps") {
                        TextField("Task to break down", text: $goal, axis: .vertical).lineLimit(2...6).focused($editing).disabled(generating || model?.busy == true)
                            .accessibilityIdentifier("reviewedStepsGoal")
                        Text("Apple Intelligence uses only this text, on this device. Review and edit every step before adding it.").font(.callout).foregroundStyle(.secondary)
                        if !store.online { Text("Connect to check this saved task before suggesting or adding steps.").font(.callout).foregroundStyle(.secondary) }
                        if (try? TaskBreakdownRequest.goal(goal)) == nil { Text("Use a shorter, nonempty task description.").foregroundStyle(.red).accessibilityIdentifier("reviewedStepsGoalWarning") }
                        if let reason = TaskBreakdownEngine.unavailableReason { Text(reason).foregroundStyle(.secondary) }
                        if generating {
                            ProgressView("Suggesting steps…")
                            Button("Stop", action: stopGeneration).accessibilityIdentifier("reviewedStepsStopGeneration")
                        } else {
                            Button(steps.isEmpty ? "Suggest steps" : "Try different steps", systemImage: "wand.and.stars", action: generate)
                                .disabled(!store.online || model?.busy == true || TaskBreakdownEngine.unavailableReason != nil || (try? TaskBreakdownRequest.goal(goal)) == nil)
                                .accessibilityIdentifier("reviewedStepsGenerate")
                        }
                    }
                    if !steps.isEmpty {
                        Section("Review steps") {
                            ForEach(steps) { step in
                                VStack(alignment: .leading, spacing: 8) {
                                    TextField("Step title", text: stepBinding(step, \.title), axis: .vertical).lineLimit(1...4).focused($editing).accessibilityIdentifier("reviewedStepTitle-" + step.id.uuidString)
                                    Toggle("Include this step", isOn: stepBinding(step, \.included)).accessibilityLabel("Include " + step.title).accessibilityIdentifier("reviewedStepIncluded-" + step.id.uuidString)
                                }.disabled(generating || model?.busy == true)
                            }
                            if let selectionProblem { Text(selectionProblem).foregroundStyle(.red) }
                            Text("Selected steps are added together after existing subtasks, with one Undo.").font(.callout).foregroundStyle(.secondary)
                            Button("Add selected") { Task { await add() } }
                                .disabled(!store.online || generating || model?.busy == true || selected.isEmpty || selectionProblem != nil)
                                .accessibilityValue("\(selected.count) steps").accessibilityIdentifier("reviewedStepsApply")
                        }
                    }
                } else if !reading, !pending {
                    Section {
                        Text(ready ? "The task changed. Refresh before suggesting more steps." : "Step suggestions aren’t available for this saved task right now.").foregroundStyle(.secondary)
                    }
                }
                if let model, model.scope == scope, model.loaded {
                    Section("Saved step additions") {
                        let entries = Array(model.entries.filter { $0.command.root == opening.root }.reversed())
                        if entries.isEmpty { Text("No saved additions").foregroundStyle(.secondary) }
                        ForEach(entries, id: \.command.id) { entry in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(entry.command.undoing ? "Undo step addition" : "Add \(entry.command.body["steps"]!.list.count) steps").font(.headline)
                                Text(status(entry.phase)).font(.callout).foregroundStyle(.secondary)
                                if !entry.command.undoing, entry.phase == .applied {
                                    DisclosureGroup("Review added steps") {
                                        ForEach(Array(entry.command.body["steps"]!.list.enumerated()), id: \.offset) { _, row in Text(row.object["title"]!.text).font(.callout) }
                                    }
                                }
                                if entry.phase == .queued || entry.phase == .attempted {
                                    ForEach(Array((entry.command.body["steps"]?.list ?? []).enumerated()), id: \.offset) { _, row in Text(row.object["title"]!.text).font(.callout) }
                                    Text(entry.phase == .queued
                                         ? "This request is saved on this device and hasn’t been sent."
                                         : "The result hasn’t been confirmed. Check status or retry this same saved request. Stopping leaves any confirmed changes in place.")
                                        .font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("reviewedStepsRecoveryHelp")
                                    Button("Check status") { Task { await run(entry.command, .resolve) } }.accessibilityIdentifier("reviewedStepsCheck")
                                    Button(entry.phase == .queued ? "Send saved request" : "Retry original request") { Task { await run(entry.command, .apply) } }.disabled(!store.online || !store.childTaskStructureEditingEnabled).accessibilityIdentifier("reviewedStepsRetry")
                                    Button(entry.command.undoing ? "Stop undo" : "Stop addition", role: .destructive) { Task { await run(entry.command, .close) } }.accessibilityIdentifier("reviewedStepsCloseRequest")
                                } else {
                                    if model.canUndo(entry) { Button("Undo added steps") { Task { await reverse(entry) } }.disabled(!store.online || !store.childTaskStructureEditingEnabled).accessibilityIdentifier("reviewedStepsUndo") }
                                    if model.canRedo(entry) { Button("Redo added steps") { Task { await reverse(entry) } }.disabled(!store.online || !store.childTaskStructureEditingEnabled).accessibilityIdentifier("reviewedStepsRedo") }
                                    Button("Remove saved history", role: .destructive) { forgetting = entry.command }
                                }
                            }.buttonStyle(.borderless).disabled(model.busy).padding(.vertical, 4)
                        }
                    }
                }
                Section {
                    Button("Refresh task") { Task { await refresh() } }.disabled(reading || generating || model?.busy == true || !store.online)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("reviewedStepsForm")
            .formStyle(.grouped).navigationTitle("Reviewed steps")
            #if os(iOS)
            .toolbar { ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editing = false }.accessibilityIdentifier("reviewedStepsKeyboardDone")
            } }
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.accessibilityIdentifier("reviewedStepsDismiss") } }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 540, minHeight: 440, idealHeight: 650)
        #endif
        .privacySensitive()
        .task(id: scope) { await open() }
        #if DEBUG
        .task(id: ready) {
            guard ready, !fixtureSeeded, FullSchemaNativeFixture.enabled, FullSchemaNativeFixture.phase == "step-ui", ProcessInfo.processInfo.arguments.contains("--reviewed-steps-seed") else { return }
            await Task.yield()
            guard ready, current, !Task.isCancelled else { return }
            fixtureSeeded = true
            steps = ["Inspect the brief", "Review workshop layout", "Publish the checklist"].map { Step(title: $0) }
        }
        #endif
        .onChange(of: store.childHistoryNotice?.id) { _, _ in
            guard let notice = store.childHistoryNotice, notice.kind == .steps, notice.scope == scope else { return }
            Task { await model?.load(); await refresh(synchronize: false) }
        }
        .onChange(of: current) { _, value in if !value { stopGeneration(); steps = [] } }
        .onChange(of: goal) { _, _ in stopGeneration(); steps = [] }
        .onChange(of: model?.message) { _, value in if let value { AccessibilityNotification.Announcement(value).post() } }
        .onDisappear { stopGeneration(); model?.close(); model = nil; read = nil; steps = []; goal = "" }
        .confirmationDialog("Remove saved step history?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible) {
            Button("Remove history", role: .destructive) { if let command = forgetting { Task { await model?.forget(command) } }; forgetting = nil }
        } message: { Text("Tasks stay unchanged. The saved addition and its Undo history are removed from this device.") }
    }
    private func status(_ phase: ReviewedTaskStepsState.Phase) -> String {
        switch phase { case .queued: "Saved · not sent"; case .attempted: "Needs attention · original request kept"; case .applied: "Confirmed"; case .closed: "Stopped" }
    }
    private func stopGeneration() { token = UUID(); generation?.cancel(); generation = nil; generating = false }
    private func makeModel() throws -> ReviewedTaskStepsModel {
        #if os(macOS)
        let owner = workspace
        return try store.reviewedTaskStepsModel(didApply: { [weak owner] entry, scope in owner?.rememberReviewedTaskSteps(entry, scope: scope) })
        #else
        let owner = store
        return try store.reviewedTaskStepsModel(didApply: { [weak owner] entry, scope in
            guard let owner, !owner.viewHistory.contains(key: entry.command.id) else { return }
            let step = owner.reviewedTaskStepsHistoryStep(entry, scope: scope)
            if let parent = entry.redoOf ?? entry.command.body["undo_of"]?.text, owner.viewHistory.acceptConfirmedInverse(of: parent, next: step) { return }
            owner.viewHistory.record(step)
        })
        #endif
    }
    private func open() async {
        stopGeneration(); model?.close(); model = nil; read = nil; steps = []; goal = ""; error = nil; ready = false; forgetting = nil; readToken = UUID(); reading = false
        guard let captured = scope else { return }
        do {
            let owner = try makeModel(); guard captured == scope else { owner.close(); return }; model = owner
            await owner.load(); guard captured == scope, !Task.isCancelled else { return }; await refresh()
        } catch { guard captured == scope else { return }; self.error = "Saved step additions couldn’t be read. Your work is kept." }
    }
    private func refresh(synchronize: Bool = true) async {
        guard !reading, let model, model.scope == scope else { return }
        stopGeneration(); steps = []; ready = false; reading = true; let ticket = UUID(); readToken = ticket; defer { if readToken == ticket { reading = false } }
        do {
            let value: ChildTaskStructureRead
            if synchronize { value = try await store.readCurrentChildTaskStructure(opening.root) }
            else { value = try await store.readChildTaskStructure(opening.root) }
            guard model.scope == scope, readToken == ticket, !Task.isCancelled else { return }
            read = value
            let node = opening.parent.flatMap { value.records.nodes[$0] }
            guard opening.parent == nil || node != nil else { throw ReviewedTaskStepsCommand.invalid }
            goal = node?.fields["title"]?.text ?? value.context.root.title
            // Constructing a one-step probe validates destination/depth/capacity without saving or sending it.
            _ = try ReviewedTaskStepsCommand(titles: ["Step"], parent: opening.parent, read: value)
            ready = try await model.available(value); error = nil
        } catch { guard model.scope == scope, readToken == ticket, !Task.isCancelled else { return }; self.error = "This task couldn’t be prepared for suggestions. Saved requests below can still be checked or stopped." }
    }
    private func generate() {
        guard current, ready, !pending, !generating, let read, let model else { return }
        let input = goal, id = UUID(); token = id; generating = true; error = nil
        generation = Task {
            do {
                guard try await model.available(read), current, token == id else { throw ReviewedTaskStepsCommand.invalid }
                let titles = try await TaskBreakdownEngine.generate(input)
                guard !Task.isCancelled, current, token == id else { return }
                steps = titles.map { Step(title: $0) }; generating = false; generation = nil
            } catch {
                guard !Task.isCancelled, current, token == id else { return }
                self.error = error.localizedDescription; generating = false; generation = nil
            }
        }
    }
    private func add() async {
        guard current, let read, let model, !pending else { return }
        do {
            let command = try ReviewedTaskStepsCommand(titles: selected, parent: opening.parent, read: read)
            if let saved = await model.queue(command, read: read) { steps = []; await run(saved, .apply) }
        } catch { self.error = error.localizedDescription }
    }
    private func run(_ command: ReviewedTaskStepsCommand, _ operation: ReviewedTaskStepsOperation) async {
        guard let model, model.scope == scope else { return }
        stopGeneration(); _ = await model.run(command, operation: operation)
        guard model.scope == scope else { return }
        if model.entries.first(where: { $0.command == command })?.phase == .applied { await refresh(synchronize: false) }
    }
    private func reverse(_ entry: ReviewedTaskStepsState.Entry) async {
        guard let model, model.canUndo(entry) || model.canRedo(entry) else { return }
        do {
            let value = try await store.readCurrentChildTaskStructure(entry.command.root)
            guard model.scope == scope else { return }
            if let saved = await model.queueInverse(entry, read: value) { await run(saved, .apply) }
        } catch { self.error = "These steps changed since they were added. Your newer work is kept; refresh before reviewing them." }
    }
}

struct SavedReviewedTaskStepsLink: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var hasHistory = false
    @State private var historyUnavailable = false
    private var scope: ChildTaskFieldClientScope? { phase == .active ? store.childTaskFieldRecoveryScope : nil }
    @State private var showing = false
    @State private var model: ReviewedTaskStepsModel?
    @State private var selected: ReviewedTaskStepsOpening?
    var body: some View {
        Group {
        if scope != nil, store.childTaskStructureEditingEnabled || hasHistory || historyUnavailable {
            Section {
                Button("Saved step additions", systemImage: "wand.and.stars") { showing = true }
                    .sheet(isPresented: $showing) {
                        NavigationStack {
                            List {
                                if let model, model.scope == scope {
                                    if let message = model.message { Text(message) }
                                    if model.loaded, model.entries.isEmpty { Text("No saved additions").foregroundStyle(.secondary) }
                                    ForEach(Array(Set(model.entries.map { $0.command.root })).sorted(), id: \.self) { root in
                                        Button(store.record("tasks", id: root)?.title ?? "Saved task addition") { selected = .init(root: root) }
                                    }
                                }
                            }.navigationTitle("Saved step additions")
                                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showing = false } } }
                        }
                        .task(id: scope) { model?.close(); model = nil; if scope != nil { model = try? store.reviewedTaskStepsModel(); await model?.load() } }
                        .onDisappear { model?.close(); model = nil }
                        .sheet(item: $selected, onDismiss: { Task { await model?.load() } }) { ReviewedTaskStepsView(opening: $0) }
                        .privacySensitive()
                    }
            }
        }
        }
        .task(id: scope) {
            hasHistory = false; historyUnavailable = false
            guard let captured = scope else { selected = nil; showing = false; model?.close(); model = nil; return }
            do {
                let state = try await store.reviewedTaskStepsJournal(account: captured.account, origin: captured.origin).load()
                guard captured == scope, !Task.isCancelled else { return }; hasHistory = !state.entries.isEmpty
            } catch { guard captured == scope, !Task.isCancelled else { return }; historyUnavailable = true }
        }
    }
}
