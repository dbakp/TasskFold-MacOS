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
