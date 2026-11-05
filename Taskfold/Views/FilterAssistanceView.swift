import SwiftUI

struct FilterAssistanceView: View {
    let request: FilterAssistanceRequest
    let source: () -> JSON
    let onApply: (FilterSuggestion) throws -> Void
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var description = ""
    @State private var expression: String
    @State private var run: FilterAssistanceRun
    @State private var work: Task<Void, Never>?
    @State private var busy: String?
    @State private var activeQuery: String?
    @State private var generatedDescription: String?
    @State private var proposal: FilterSuggestion?
    @State private var previewCount: Int?
    @State private var previewCaption: String?
    @State private var unavailable: String?
    @State private var error: String?
    @State private var applied = false
    @State private var refreshedProjects: [String]?

    init(request: FilterAssistanceRequest, source: @escaping () -> JSON, onApply: @escaping (FilterSuggestion) throws -> Void) {
        self.request = request; self.source = source; self.onApply = onApply
        _expression = State(initialValue: request.expression)
        _run = State(initialValue: FilterAssistanceRun(request: request))
    }
    private var workspace: WorkspaceBinding { .init(account: store.userID, generation: store.workspaceGeneration) }
    private var isCurrent: Bool {
        store.workflowPreviewReady(request.workspace) && request.matches(source(), workspace: workspace, session: store.backend.reminderSessionIncarnation)
    }
    private var descriptionIssue: String? {
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do { _ = try TaskBreakdownRequest.goal(description); return nil }
        catch { return "Use a shorter description of the tasks you want to see." }
    }
    var body: some View {
        NavigationStack {
            Form {
                if isCurrent {
                    Section("Describe what to show") {
                        TextField("For example, overdue high-priority tasks in Inbox", text: $description, axis: .vertical)
                            .lineLimit(2...6).disabled(busy != nil).accessibilityIdentifier("filterAssistanceDescription")
                        Text("Apple Intelligence uses only the description above, on this device. Your tasks, saved query and project directory aren’t sent to the model.")
                            .font(.callout).foregroundStyle(.secondary)
                        if let descriptionIssue { Text(descriptionIssue).foregroundStyle(.red) }
                        if let unavailable {
                            Text(unavailable).foregroundStyle(.secondary).accessibilityIdentifier("filterAssistanceUnavailable")
                            Button("Check availability") { self.unavailable = OnDeviceAssistance.unavailableReason }
                        } else {
                            Button("Suggest expression", systemImage: "wand.and.stars", action: generate)
                                .disabled(busy != nil || run.closed || descriptionIssue != nil || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityIdentifier("filterAssistanceGenerate")
                        }
                    }
                    Section("Review expression") {
                        TextField("today AND p1", text: $expression, axis: .vertical)
                            .lineLimit(2...8).autocorrectionDisabled().disabled(busy != nil)
                            .accessibilityIdentifier("filterAssistanceExpression")
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        Button("Check preview") { check() }
                            .disabled(busy != nil || run.closed || (try? FilterSuggestion.boundedExpression(expression)) == nil)
                            .accessibilityIdentifier("filterAssistancePreview")
                        if let previewCount, let previewCaption {
                            Text("\(previewCount) matching tasks").font(.headline).accessibilityIdentifier("filterAssistanceCount")
                            Text(previewCaption).foregroundStyle(.secondary).accessibilityIdentifier("filterAssistanceMeaning")
                        }
                        Text("Use expression updates this draft. Save in the filter editor to keep it.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let busy {
                        Section {
                            ProgressView(busy).accessibilityIdentifier("filterAssistanceProgress")
                            Button("Stop", action: stop).accessibilityIdentifier("filterAssistanceStop")
                        }
                    }
                    if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("filterAssistanceError") } }
                } else { Text("This filter is no longer available.") }
            }
            .formStyle(.grouped)
            .navigationTitle("Suggest a filter")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { close(); dismiss() }.accessibilityIdentifier("filterAssistanceCancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use expression") { check(applying: true) }
                        .disabled(busy != nil || proposal == nil || applied || run.closed || !isCurrent)
                        .accessibilityIdentifier("filterAssistanceApply")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 540, minHeight: 460, idealHeight: 660)
        #endif
        .task { unavailable = OnDeviceAssistance.unavailableReason }
        .onChange(of: isCurrent, initial: true) { _, current in
            if !current { close(); description = ""; expression = ""; clearPreview(); dismiss() }
        }
        .onChange(of: expression) { _, value in
            if let proposal, !proposal.expression.utf8.elementsEqual(value.utf8) { clearPreview() }
            if let activeQuery, !activeQuery.utf8.elementsEqual(value.utf8) { stop(); clearPreview(); error = nil }
        }
        .onChange(of: description) { _, value in
            if let generatedDescription, !generatedDescription.utf8.elementsEqual(value.utf8) {
                stop(); clearPreview(); expression = ""; self.generatedDescription = nil; activeQuery = nil; error = nil
            }
        }
        .onChange(of: phase) { _, value in
            if value == .background { stop() }
            if value == .active { unavailable = OnDeviceAssistance.unavailableReason; refreshedProjects = nil }
        }
        .onChange(of: error) { _, value in if isCurrent, let value { AccessibilityNotification.Announcement(value).post() } }
        .onDisappear(perform: close)
    }
    private func clearPreview() { proposal = nil; previewCount = nil; previewCaption = nil }
    private func stop() { work?.cancel(); work = nil; run.stop(); busy = nil }
    private func close() { stop(); run.close() }
    private func failed(_ failure: Error, token: UUID, checking: Bool) {
        guard !Task.isCancelled, run.accepts(token), isCurrent else { return }
        error = checking && failure is FilterFailure ? failure.localizedDescription : "An expression couldn’t be suggested. Try a shorter description or edit the expression yourself. Your saved filter is unchanged."
        run.stop(); busy = nil; work = nil; unavailable = OnDeviceAssistance.unavailableReason
    }
    private func generate() {
        guard isCurrent, busy == nil, let token = run.begin() else { return }
        let input = description
        generatedDescription = input; busy = "Suggesting expression…"; error = nil; clearPreview()
        work = Task {
            var checking = false
            do {
                let text = try await FilterAssistanceEngine.generate(input)
                guard !Task.isCancelled, run.accepts(token), isCurrent, input.utf8.elementsEqual(description.utf8) else { return }
                activeQuery = text; expression = text; checking = true; busy = "Checking expression…"
                try await prepare(text, token: token, reviewed: nil, applying: false)
            } catch { failed(error, token: token, checking: checking) }
        }
    }
    private func check(applying: Bool = false) {
        guard isCurrent, busy == nil, !applied, !applying || proposal != nil, let token = run.begin() else { return }
        let text = expression, reviewed = applying ? proposal : nil
        activeQuery = text; error = nil; busy = "Checking expression…"
        work = Task {
            do { try await prepare(text, token: token, reviewed: reviewed, applying: applying) }
            catch { failed(error, token: token, checking: true) }
        }
    }
    private func refreshPeople(token: UUID) async throws {
        let projects = store.projects
        busy = "Loading project members…"
        for project in projects {
            try Task.checkCancellation()
            guard run.accepts(token), isCurrent else { throw CancellationError() }
            do { _ = try await store.refreshProjectMembers(project.id) }
            catch is CancellationError { throw CancellationError() }
            catch { throw FilterFailure(message: "Project members couldn’t be refreshed. Your saved filter is unchanged. Check your connection and try the preview again.") }
        }
        try Task.checkCancellation()
        guard run.accepts(token), isCurrent, AuthoredValueComparison.sameRows(projects, store.projects) else {
            throw FilterFailure(message: "Your projects changed during the check. Check the preview again.")
        }
        refreshedProjects = projects.map(\.id).sorted()
        busy = "Checking expression…"
    }
    private func prepare(_ text: String, token: UUID, reviewed: FilterSuggestion?, applying: Bool) async throws {
        var context = store.filterContext
        var value: FilterSuggestion
        do {
            value = try await FilterSuggestion.prepare(text, context: context, reviewed: reviewed)
        } catch let problem as FilterFailure where problem.needsPeopleDirectory && !store.localMode && refreshedProjects != store.projects.map(\.id).sorted() {
            try await refreshPeople(token: token)
            context = store.filterContext
            value = try await FilterSuggestion.prepare(text, context: context, reviewed: reviewed)
        }
        if value.needsPeopleDirectory, !store.localMode, refreshedProjects != store.projects.map(\.id).sorted() {
            try await refreshPeople(token: token)
            context = store.filterContext
            value = try await FilterSuggestion.prepare(text, context: context, reviewed: reviewed)
        }
        guard !Task.isCancelled, run.accepts(token), isCurrent, text.utf8.elementsEqual(expression.utf8) else { throw CancellationError() }
        guard FilterSuggestion.sameInputs(context, store.filterContext) else { throw FilterFailure(message: "Your workspace changed during the check. Check the preview again.") }
        if let problem = store.hierarchyFilterError(value.rule) { throw FilterFailure(message: problem) }
        if applying {
            try onApply(value); applied = true; close(); dismiss()
        } else {
            proposal = value
            let count = store.previewFilterCount(value.rule, includeCompleted: request.includeCompleted)
            previewCount = count; previewCaption = value.rule.sectionTitle(in: context)
            run.stop(); busy = nil; work = nil
            AccessibilityNotification.Announcement("Preview ready. \(count) matching tasks.").post()
        }
    }
}
