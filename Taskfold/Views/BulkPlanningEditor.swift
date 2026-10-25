import SwiftUI

@MainActor struct BulkTaskPlanningRequest: Identifiable {
    enum Outcome { case saved, review(TeamTaskPlanningRequest) }
    let id = UUID()
    let field: BulkPlanningField
    let records: [Record]
    let shared: Bool
    let validate: () throws -> Void
    let submit: ([String: JSON]) throws -> Outcome

    static func shared(store: Store, admission: TeamTaskPlanningAdmission, field: BulkPlanningField, save: @escaping (TeamTaskPlanningSelection) -> Bool, completed: @escaping () -> Void) -> Self {
        Self(field: field, records: admission.drafts.map(\.source), shared: true, validate: { try store.reviewedTeamTaskPlanningAdmission(admission) }, submit: { fields in
            try store.reviewedTeamTaskPlanningAdmission(admission)
            let selection = try admission.selecting(fields); _ = try store.reviewedTeamTaskPlanningSelection(selection)
            return .review(TeamTaskPlanningRequest(selection: selection, title: field.title, perform: { save(selection) }, completed: completed))
        })
    }
    static func personal(store: Store, records: [Record], field: BulkPlanningField, apply: @escaping ([String: JSON]) throws -> Bool, completed: @escaping () -> Void) throws -> Self {
        let workspace = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration), session = store.backend.reminderSessionIncarnation, origin = try? store.backend.accountRemovalOrigin
        let validate: () throws -> Void = { try store.reviewedPersonalTaskPlanning(records, workspace: workspace, session: session, origin: origin) }
        try validate()
        return Self(field: field, records: records, shared: false, validate: validate, submit: { fields in
            try validate()
            guard try apply(fields) else { throw AppFailure(message: store.error ?? "The selected tasks could not be saved. Try again.") }
            completed(); return .saved
        })
    }
}

struct BulkTaskPlanningEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: BulkTaskPlanningRequest
    @State private var date = Date()
    @State private var minutes = "25"
    @State private var clearing = false
    @State private var initialised = false
    @State private var message: String?
    @State private var review: TeamTaskPlanningRequest?
    @FocusState private var editingMinutes: Bool
    private var fields: [String: JSON]? { try? request.field.fields(day: TaskPlanner.dayKey(date), minutes: minutes, clearing: clearing) }
    private var refusal: String? { do { try request.validate(); return nil } catch { return error.localizedDescription } }
    private var changed: Int { guard let fields else { return 0 }; return request.records.filter { row in fields.contains { row[$0.key] != $0.value } }.count }
    var body: some View {
        Group {
            if let review { TeamTaskPlanningReview(request: review) }
            else { input }
        }.privacySensitive()
    }
    private var input: some View {
        let blocked = refusal
        return NavigationStack {
            Form {
                if let blocked {
                    Section { Label("Selection needs review", systemImage: "lock.shield"); Text(blocked).foregroundStyle(.secondary) }.accessibilityIdentifier("bulkPlanningPaused")
                } else {
                    Section {
                        Picker("Action", selection: $clearing) {
                            Text(request.field == .deadline ? "Set deadline" : "Set estimate").tag(false)
                            Text(request.field == .deadline ? "Clear deadlines" : "Clear estimates").tag(true)
                        }.pickerStyle(.segmented).accessibilityIdentifier("bulkPlanningAction")
                        if !clearing {
                            if request.field == .deadline {
                                DatePicker("Deadline", selection: $date, displayedComponents: .date).datePickerStyle(.graphical).accessibilityIdentifier("bulkPlanningDate")
                            } else {
                                LabeledContent("Minutes") {
                                    TextField("Minutes", text: $minutes).multilineTextAlignment(.trailing).focused($editingMinutes).onSubmit { editingMinutes = false }
                                        #if os(iOS)
                                        .keyboardType(.numberPad)
                                        #endif
                                        .accessibilityIdentifier("bulkPlanningMinutes")
                                }
                                HStack { ForEach([15, 25, 30, 60], id: \.self) { value in Button("\(value) min") { minutes = String(value); editingMinutes = false }.buttonStyle(.bordered).accessibilityIdentifier("bulkPlanningPreset\(value)") } }
                                if fields == nil { Text("Choose an estimate between 1 minute and 7 days (10,080 minutes).").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("bulkPlanningValidation") }
                            }
                        }
                    } footer: {
                        Text(request.field == .deadline ? "A deadline is when work must be finished. Planned dates, times, estimates and reminders stay in place." : "An estimate is how long the task may take. Planned dates, deadlines and reminders stay in place.")
                    }
                    Section("Selected tasks") {
                        ForEach(request.records) { task in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.title).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                                Text(currentValue(task)).font(.caption).foregroundStyle(.secondary)
                                if request.field == .deadline {
                                    Text(TaskPlanner.dayDate(task).map { "Planned · " + $0.formatted(date: .abbreviated, time: .omitted) + (task.string("due_time").isEmpty ? "" : " · " + TaskPlanner.clockValue(task)) } ?? "No planned date").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }.accessibilityElement(children: .combine)
                        }
                    }
                    Section {
                        Text(changed == 0 && fields != nil ? "The selected tasks already match this choice." : "\(changed) of \(request.records.count) tasks will change.").foregroundStyle(.secondary)
                        if request.shared { Text("Review every shared task before saving the whole selection together.").font(.footnote).foregroundStyle(.secondary) }
                        else { Text("Save this selection as one undoable step.").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                if let message { Section { Text(message).foregroundStyle(.red).accessibilityIdentifier("bulkPlanningError") } }
                #if DEBUG
                if TeamEditorNativeFixture.enabled, ProcessInfo.processInfo.arguments.contains("--team-planning-input-testing") {
                    Section("Isolated test control") { Button("Change saved test task") { store.changeTeamDeletionFixtureSource() }.accessibilityIdentifier("changeBulkPlanningFixture") }
                }
                #endif
            }.formStyle(.grouped).accessibilityIdentifier("bulkPlanningForm")
            .navigationTitle(request.field.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("bulkPlanningCancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.shared ? "Review" : "Apply") { submit() }.disabled(blocked != nil || fields == nil || changed == 0).accessibilityIdentifier("bulkPlanningSubmit")
                }
            }
            .onAppear { initialise() }
            #if os(iOS)
            .safeAreaInset(edge: .bottom) { if editingMinutes { HStack { Spacer(); Button("Done") { editingMinutes = false }.accessibilityIdentifier("bulkPlanningKeyboardDone") }.padding().background(.bar) } }
            #else
            .frame(minWidth: 500, idealWidth: 580, minHeight: 540)
            #endif
        }
    }
    private func currentValue(_ task: Record) -> String {
        if request.field == .deadline { return task.deadline.map { "Deadline · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "No deadline" }
        return task.durationMinutes.map { "Estimate · \($0) min" } ?? (task["duration_minutes"] == .null ? "No estimate" : "Estimate needs review")
    }
    private func initialise() {
        guard !initialised else { return }; initialised = true
        let values = request.records.map { $0[request.field.key] }
        if let value = values.first, values.allSatisfy({ $0 == value }) {
            if request.field == .deadline, let existing = Dates.parse(value.text) { date = existing }
            if request.field == .estimate, case .number(let n) = value, n.isFinite, n >= 1, n <= 10080, n.rounded(.down) == n { minutes = String(Int(n)) }
        }
    }
    private func submit() {
        editingMinutes = false; message = nil
        guard refusal == nil, let fields, changed > 0 else { return }
        do {
            switch try request.submit(fields) {
            case .saved: dismiss()
            case .review(var next): next.back = { review = nil }; review = next
            }
        } catch { message = error.localizedDescription; store.error = nil }
    }
}

@MainActor struct BulkTaskAssignmentRequest: Identifiable {
    let id = UUID()
    let admission: TeamTaskPlanningAdmission
    let save: (TeamTaskPlanningSelection) -> Bool
    let completed: () -> Void
}

struct BulkTaskAssignmentEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: BulkTaskAssignmentRequest
    @State private var picker: TeamTaskBatchRecipientPicker?
    @State private var search = ""
    @State private var review: TeamTaskPlanningRequest?
    private var available: Bool { (try? store.reviewedTeamTaskPlanningAdmission(request.admission)) != nil }
    private var account: String { request.admission.drafts[0].scope.account }
    private var people: [TeamTaskRecipientCatalog.Person] {
        (picker?.people ?? []).filter { $0.id != account && (search.isEmpty || ($0.displayName ?? "Team member").localizedStandardContains(search)) }
            .sorted { let a = $0.displayName ?? "Team member", b = $1.displayName ?? "Team member"; return a == b ? $0.id < $1.id : a.localizedStandardCompare(b) == .orderedAscending }
    }
    var body: some View {
        Group {
            if let review { TeamTaskPlanningReview(request: review) }
            else { input }
        }.privacySensitive()
    }
    private var input: some View {
        NavigationStack {
            Group {
                if available {
                    List {
                        Section {
                            choice(nil, title: "Unassigned")
                            choice(.init(id: account, role: .editor, displayName: nil), title: "You")
                            ForEach(people) { person in choice(person, title: person.displayName ?? "Team member") }
                        } header: { Text("Assign \(request.admission.drafts.count) shared tasks") }
                        footer: { Text("Only people who can edit every selected project appear here. Review the complete selection before saving.") }
                        if picker?.loading == true { ProgressView("Finding teammates…").accessibilityIdentifier("bulkAssigneeLoading") }
                        if picker?.applying == true { ProgressView("Checking assignment…") }
                        if let message = picker?.message {
                            Section { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("bulkAssigneeMessage") }
                        }
                        Section("Selected tasks") {
                            ForEach(request.admission.drafts, id: \.source.id) { draft in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(draft.source.title).fixedSize(horizontal: false, vertical: true)
                                    Text(store.record("projects", id: draft.scope.project)?.name ?? "Shared project").font(.caption).foregroundStyle(.secondary)
                                }.accessibilityElement(children: .combine)
                            }
                        }
                        #if DEBUG
                        if TeamEditorNativeFixture.enabled, ProcessInfo.processInfo.arguments.contains("--team-planning-input-testing") {
                            Section("Isolated test controls") {
                                Button("Remove test recipient") { TeamEditorNativeFixture.removeRecipient() }.accessibilityIdentifier("removeBulkRecipientFixture")
                                Button("Change saved test task") { store.changeTeamDeletionFixtureSource() }.accessibilityIdentifier("changeBulkAssignmentFixture")
                            }
                        }
                        #endif
                    }.accessibilityIdentifier("bulkAssigneeList").searchable(text: $search, prompt: "Find a teammate")
                } else {
                    ContentUnavailableView("Assignment paused", systemImage: "lock.shield", description: Text("A selected task or its project access changed. Close this review and select the current tasks again.")).accessibilityIdentifier("bulkAssigneePaused")
                }
            }.navigationTitle("Assign shared tasks")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("cancelBulkAssignee") }
                ToolbarItem { Button("Refresh choices", systemImage: "arrow.clockwise") { Task { await picker?.refresh() } }.disabled(!available || picker?.applying == true).accessibilityIdentifier("refreshBulkAssignees") }
            }
            #if os(macOS)
            .frame(minWidth: 500, idealWidth: 580, minHeight: 500)
            #endif
        }
        .task {
            if picker == nil {
                picker = TeamTaskBatchRecipientPicker(admission: request.admission, current: { available }, read: { try await store.backend.teamTaskRecipients($0) }, apply: { person in
                    do {
                        try store.reviewedTeamTaskPlanningAdmission(request.admission)
                        let selection = try request.admission.selecting(["assigned_to": person.map { .string($0.id) } ?? .null])
                        _ = try store.reviewedTeamTaskPlanningSelection(selection)
                        review = TeamTaskPlanningRequest(selection: selection, title: "Assign shared tasks", perform: { request.save(selection) }, completed: request.completed, back: { review = nil }, assignmentName: person.map { $0.id == account ? "You" : $0.displayName ?? "Team member" })
                        return nil
                    } catch { return error.localizedDescription }
                })
            }
            await picker?.refresh()
        }
        .onChange(of: available) { _, value in if !value { picker?.invalidate() } }
        .onDisappear { picker?.invalidate() }
    }
    private func choice(_ person: TeamTaskRecipientCatalog.Person?, title: String) -> some View {
        let value = person.map { JSON.string($0.id) } ?? .null
        let unchanged = request.admission.drafts.allSatisfy { $0.source["assigned_to"] == value }
        return Button {
            Task { _ = await picker?.choose(person?.id) }
        } label: {
            HStack { Text(title).fixedSize(horizontal: false, vertical: true); Spacer(); if unchanged { Image(systemName: "checkmark").accessibilityLabel("Already assigned") } }
        }.disabled(picker == nil || picker?.loading == true && person?.id != account && person != nil || picker?.applying == true || unchanged)
            .accessibilityIdentifier("bulkAssignee-" + (person?.id ?? "unassigned"))
    }
}
