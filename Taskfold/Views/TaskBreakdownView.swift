import SwiftUI

struct TaskBreakdownView: View {
    let request: TaskBreakdownRequest
    let current: () -> Record?
    let onApply: (JSON) throws -> Void
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var generation: TaskBreakdownSession
    @State private var goal: String
    @State private var steps: [Step] = []
    @State private var work: Task<Void, Never>?
    @State private var busy = false
    @State private var generatedGoal: String?
    @State private var applied = false
    @State private var error: String?
    @State private var unavailable: String?
    private struct Step: Identifiable { let id = UUID(); var title: String; var included = true }
    // Disappearing controls can read their binding after a save/removal clears the row.
    // Resolve by identity on each access instead of retaining an array-index binding.
    private func stepBinding<Value>(_ step: Step, _ path: WritableKeyPath<Step, Value>) -> Binding<Value> {
        Binding(get: { steps.first { $0.id == step.id }?[keyPath: path] ?? step[keyPath: path] }, set: { value in
            guard let index = steps.firstIndex(where: { $0.id == step.id }) else { return }
            steps[index][keyPath: path] = value
        })
    }

    init(request: TaskBreakdownRequest, current: @escaping () -> Record?, onApply: @escaping (JSON) throws -> Void) {
        self.request = request; self.current = current; self.onApply = onApply
        _generation = State(initialValue: TaskBreakdownSession(request: request))
        _goal = State(initialValue: request.source.title)
    }
    private var workspace: WorkspaceBinding { .init(account: store.userID, generation: store.workspaceGeneration) }
    private var session: UUID { store.backend.reminderSessionIncarnation }
    private var isCurrent: Bool { current().map { request.matches($0, workspace: workspace, session: session) } ?? false }
    private var selected: [String] { steps.filter(\.included).map(\.title) }
    private var goalProblem: String? {
        do { _ = try TaskBreakdownRequest.goal(goal); return nil }
        catch { return error.localizedDescription }
    }
    private var selectionProblem: String? {
        guard !steps.isEmpty else { return nil }
        do { _ = try TaskBreakdownRequest.titles(selected); return nil }
        catch { return error.localizedDescription }
    }
    var body: some View {
        NavigationStack {
            Form {
                if isCurrent {
                Section {
                    TextField("Task to break down", text: $goal, axis: .vertical)
                        .lineLimit(2...6).disabled(busy || generation.closed).accessibilityIdentifier("breakdownGoal")
                    if let goalProblem {
                        Text(goalProblem).foregroundStyle(.red).accessibilityIdentifier("breakdownGoalWarning")
                    }
                    Text("Suggestions run on this device using Apple Intelligence. Only the text above is used. Review and edit the steps before adding them to this task.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let unavailable {
                        Text(unavailable).foregroundStyle(.secondary).accessibilityIdentifier("breakdownUnavailable")
                        Button("Check availability") { self.unavailable = TaskBreakdownEngine.unavailableReason }
                    } else if busy {
                        ProgressView("Suggesting steps…").accessibilityIdentifier("breakdownProgress")
                        Button("Stop") { stop() }.accessibilityIdentifier("breakdownStop")
                    } else {
                        Button(steps.isEmpty ? "Suggest steps" : "Try different steps", systemImage: "wand.and.stars") { generate() }
                            .disabled(!isCurrent || generation.closed || goalProblem != nil)
                            .accessibilityIdentifier("breakdownGenerate")
                    }
                }
                if !steps.isEmpty {
                    Section("Review steps") {
                        ForEach(steps) { step in
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("Step title", text: stepBinding(step, \.title), axis: .vertical).lineLimit(1...4)
                                    .accessibilityIdentifier("breakdownStep-" + step.id.uuidString)
                                HStack {
                                    Toggle("Include this step", isOn: stepBinding(step, \.included)).accessibilityLabel("Include " + step.title)
                                    Button(role: .destructive) {
                                        let id = step.id; steps.removeAll { $0.id == id }
                                    } label: { Image(systemName: "trash").frame(minWidth: 44, minHeight: 44) }
                                        .buttonStyle(.borderless).accessibilityLabel("Remove " + step.title)
                                }
                            }.disabled(busy).deleteDisabled(busy)
                        }
                        .onDelete { steps.remove(atOffsets: $0) }
                        if let selectionProblem {
                            Text(selectionProblem).foregroundStyle(.red).accessibilityIdentifier("breakdownSelectionWarning")
                        }
                        Text("Existing subtasks stay in place. Selected steps will be appended.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("breakdownError") } }
                } else {
                    Text("This task is no longer available.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Suggest steps")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { close(); dismiss() }.accessibilityIdentifier("breakdownCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add selected") { apply() }
                        .disabled(busy || applied || generation.closed || !isCurrent || selected.isEmpty || selectionProblem != nil)
                        .accessibilityValue("\(selected.count) steps").accessibilityIdentifier("breakdownApply")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 520, minHeight: 420, idealHeight: 620)
        #endif
        .task { unavailable = TaskBreakdownEngine.unavailableReason }
        .onChange(of: isCurrent, initial: true) { _, value in
            if !value { close(); steps = []; goal = ""; dismiss() }
        }
        .onChange(of: goal) { _, value in
            if let generatedGoal, !generatedGoal.utf8.elementsEqual(value.utf8) {
                stop(); steps = []; self.generatedGoal = nil; error = nil
            }
        }
        .onChange(of: phase) { _, value in
            if value == .background { stop() }
            if value == .active { unavailable = TaskBreakdownEngine.unavailableReason }
        }
        .onChange(of: error) { _, value in if let value { AccessibilityNotification.Announcement(value).post() } }
        .onDisappear { close() }
    }
    private func generate() {
        guard isCurrent, !busy, let token = generation.begin(workspace: workspace, session: session) else { return }
        let input = goal
        error = nil; busy = true; generatedGoal = input
        work = Task {
            do {
                let response = try await TaskBreakdownEngine.generate(input)
                guard !Task.isCancelled, isCurrent,
                      let titles = try generation.receive(response, token: token, workspace: workspace, session: session) else { return }
                steps = titles.map { Step(title: $0) }; busy = false; work = nil
                AccessibilityNotification.Announcement("\(titles.count) steps ready to review").post()
            } catch {
                guard !Task.isCancelled, generation.token == token, isCurrent else { return }
                generation.stop(); busy = false; work = nil
                self.error = "Steps couldn’t be suggested. Try a shorter description or try again. Your task is unchanged."
                unavailable = TaskBreakdownEngine.unavailableReason
            }
        }
    }
    private func stop() { work?.cancel(); work = nil; generation.stop(); busy = false }
    private func close() { stop(); generation.close() }
    private func apply() {
        guard !busy, !applied, !generation.closed, let current = current() else { return }
        do {
            let children = try request.applying(selected, to: current, workspace: workspace, session: session)
            try onApply(children)
            applied = true; close(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
