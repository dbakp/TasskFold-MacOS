import SwiftUI

struct FilterAssistanceView: View {
    let request: FilterAssistanceRequest
    let source: () -> JSON
    let onApply: (FilterSuggestion) throws -> Void
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var description = ""
    @State private var expression: String
    @State private var run: FilterAssistanceRun
    @State private var work: Task<Void, Never>?
    @State private var busy: String?
    @State private var activeQuery: String?
    @State private var generatedDescription: String?
    @State private var localDescriptionAvailable = false
    @State private var suggestionOrigin: FilterAssistanceEngine.Origin?
    @State private var proposal: FilterSuggestion?
    private struct PreviewStamp: Equatable {
        let tasks: Int
        let access: UUID
        let minute: Date?
        let day: String
        let timeZone: String
        let dates: DatePhrasePreferences?
    }
    private var previewStamp: PreviewStamp {
        .init(tasks: store.taskRevision, access: store.workspaceReadRevision,
              minute: proposal?.rule.usesClockWindow == true ? store.calendarContext.minute : nil,
              day: store.calendarContext.today, timeZone: store.calendarContext.timeZone, dates: store.datePhrasePreferences)
    }
    @State private var checkedStamp: PreviewStamp?
    @State private var previewTasks: [Record] = []
    private enum Field: Hashable { case description, expression }
    @FocusState private var focusedField: Field?
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
            ScrollViewReader { proxy in
                Form {
                    if isCurrent {
                        Section("Describe what to show") {
                            TextField("For example, unfinished priority 1 tasks planned today", text: $description, axis: .vertical)
                                .lineLimit(2...6).focused($focusedField, equals: .description).disabled(busy != nil).accessibilityIdentifier("filterAssistanceDescription")
                            VStack(alignment: .leading, spacing: DS.Space.s) {
                                OnDeviceBadge()
                                Text("Common descriptions are prepared on this device. Apple Intelligence can help with other wording. Your tasks, saved query and project directory aren’t sent to the model.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            if let descriptionIssue { Text(descriptionIssue).foregroundStyle(.red) }
                            if let unavailable {
                                Text("Apple Intelligence: " + unavailable + " Common descriptions can still be prepared here.").foregroundStyle(.secondary).accessibilityIdentifier("filterAssistanceUnavailable")
                                Button("Check availability") { self.unavailable = OnDeviceAssistance.unavailableReason }
                            }
                            Button("Suggest expression", systemImage: "sparkles", action: generate)
                                .disabled(busy != nil || run.closed || descriptionIssue != nil || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (unavailable != nil && !localDescriptionAvailable))
                                .accessibilityIdentifier("filterAssistanceGenerate")
                        }
                        Section("Review expression") {
                            HStack(alignment: .top) {
                                TextField("today AND p1", text: $expression, axis: .vertical)
                                    .lineLimit(2...8).focused($focusedField, equals: .expression).autocorrectionDisabled().disabled(busy != nil)
                                    .accessibilityIdentifier("filterAssistanceExpression")
                                    #if os(iOS)
                                    .textInputAutocapitalization(.never)
                                    #endif
                                if !expression.isEmpty {
                                    Button { expression = ""; focusedField = .expression } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                        .buttonStyle(.borderless).disabled(busy != nil)
                                        .accessibilityLabel("Clear expression").accessibilityIdentifier("filterAssistanceClear")
                                }
                            }
                            Button("Check preview") { check() }
                                .disabled(busy != nil || run.closed || (try? FilterSuggestion.boundedExpression(expression)) == nil)
                                .accessibilityIdentifier("filterAssistancePreview")
                            if let previewCount, let previewCaption {
                                Text(previewCount == 1 ? "1 matching task" : "\(previewCount) matching tasks").font(.headline).accessibilityIdentifier("filterAssistanceCount").id("filterAssistanceCountAnchor")
                                if let suggestionOrigin {
                                    Label(suggestionOrigin == .localDescription ? "From your description" : "Apple Intelligence suggestion",
                                          systemImage: suggestionOrigin == .localDescription ? "text.magnifyingglass" : "sparkles")
                                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("filterAssistanceSource")
                                }

                                Text(previewCaption).foregroundStyle(.secondary).accessibilityIdentifier("filterAssistanceMeaning")
                                if previewCount == 0 {
                                    Text("No tasks match yet. You can still use this expression for future tasks.")
                                        .foregroundStyle(.secondary).accessibilityIdentifier("filterAssistanceEmpty")
                                } else {
                                    Text(previewCount > previewTasks.count ? "A few matches" : "Matching tasks")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    ForEach(Array(previewTasks.enumerated()), id: \.offset) { index, task in
                                        HStack(alignment: .top, spacing: 10) {
                                            Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(.secondary).accessibilityHidden(true)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(task.title.isEmpty ? "Untitled task" : task.title)
                                                    .lineLimit(3)
                                                Text(task.string("project_id").isEmpty ? "Inbox" : store.record("projects", id: task.string("project_id"))?.name ?? "Project unavailable")
                                                    .font(.caption).foregroundStyle(.secondary)
                                                if task.completed { Text("Completed").font(.caption).foregroundStyle(.secondary) }
                                            }
                                        }.accessibilityElement(children: .combine)
                                            .accessibilityIdentifier("filterAssistanceMatch-" + String(index))
                                    }
                                    if previewCount > previewTasks.count {
                                        Text("Showing \(previewTasks.count) of \(previewCount) matching tasks.")
                                            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("filterAssistanceSampleLimit")
                                    }
                                }
                                Text("Read-only preview. Checking or using an expression never changes these tasks.")
                                    .font(.caption).foregroundStyle(.secondary)
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
                        if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("filterAssistanceError").id("filterAssistanceErrorAnchor") } }
                    } else { Text("This filter is no longer available.") }
                }
                .onChange(of: previewCount) { _, count in
                    guard count != nil, isCurrent, focusedField == nil, checkedStamp == previewStamp else { return }
                    withAnimation(Motion.respecting(reduceMotion, Motion.layout)) {
                        proxy.scrollTo("filterAssistanceCountAnchor", anchor: .top)
                    }
                }
                .onChange(of: error) { _, message in
                    guard message != nil, isCurrent, focusedField == nil else { return }
                    withAnimation(Motion.respecting(reduceMotion, Motion.layout)) {
                        proxy.scrollTo("filterAssistanceErrorAnchor", anchor: .top)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Suggest a filter")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { close(); dismiss() }.accessibilityIdentifier("filterAssistanceCancel") }
                ToolbarItem(placement: .confirmationAction) {
                    #if os(iOS)
                    if focusedField != nil {
                        Button("Done") { focusedField = nil }
                            .accessibilityLabel("Hide keyboard").accessibilityIdentifier("filterAssistanceKeyboardDone")
                    } else { useExpressionAction }
                    #else
                    useExpressionAction
                    #endif
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
            localDescriptionAvailable = LocalFilterDescription.expression(for: value) != nil
            if let generatedDescription, !generatedDescription.utf8.elementsEqual(value.utf8) {
                stop(); clearPreview(); expression = ""; self.generatedDescription = nil; activeQuery = nil; error = nil
            }
        }
        .onChange(of: previewStamp) { _, current in
            if let checkedStamp, checkedStamp != current {
                stop(); clearPreview()
                error = "Tasks or date settings changed. Check the preview again before using this expression."
            }
        }
        .onChange(of: phase) { _, value in
            if value == .background { stop() }
            if value == .active { unavailable = OnDeviceAssistance.unavailableReason; refreshedProjects = nil }
        }
        .onChange(of: error) { _, value in if isCurrent, let value { AccessibilityNotification.Announcement(value).post() } }
        .onDisappear(perform: close)
    }
    private var useExpressionAction: some View {
        Button("Use") { check(applying: true) }
            .disabled(busy != nil || proposal == nil || checkedStamp != previewStamp || applied || run.closed || !isCurrent)
            .accessibilityLabel("Use expression").accessibilityIdentifier("filterAssistanceApply")
    }
    private func clearPreview() { suggestionOrigin = nil; proposal = nil; previewCount = nil; previewCaption = nil; previewTasks = []; checkedStamp = nil }
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
                let draft = try await FilterAssistanceEngine.draft(input)
                let text = draft.expression
                guard !Task.isCancelled, run.accepts(token), isCurrent, input.utf8.elementsEqual(description.utf8) else { return }
                suggestionOrigin = draft.origin
                activeQuery = text; expression = text; checking = true; busy = "Checking expression…"
                try await prepare(text, token: token, reviewed: nil, applying: false)
            } catch { failed(error, token: token, checking: checking) }
        }
    }
    private func check(applying: Bool = false) {
        if applying, checkedStamp != previewStamp {
            clearPreview()
            error = "Tasks or date settings changed. Check the preview again before using this expression."
            return
        }
        guard isCurrent, busy == nil, !applied, !applying || proposal != nil, let token = run.begin() else { return }
        focusedField = nil
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
            guard checkedStamp == previewStamp else {
                throw FilterFailure(message: "Tasks or date settings changed. Check the preview again before using this expression.")
            }
            try onApply(value); applied = true; close(); dismiss()
        } else {
            proposal = value
            let matches = store.previewFilterMatches(value.rule, includeCompleted: request.includeCompleted)
            let count = matches.count
            previewCount = count; previewTasks = Array(matches.prefix(5)); checkedStamp = previewStamp
            previewCaption = value.rule.reviewSummary(in: context, includeCompleted: request.includeCompleted)
            run.stop(); busy = nil; work = nil
            AccessibilityNotification.Announcement("Preview ready. \(count) matching tasks.").post()
        }
    }
}
