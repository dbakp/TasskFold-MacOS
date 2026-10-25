import SwiftUI

struct TeamTaskDeletionRequest: Identifiable {
    let id: UUID
    let drafts: [TeamTaskEditorDraft]
    let selection: TeamTaskDeletionSelection?
    let current: () -> Bool
    let perform: (UUID) -> Bool
    let completed: () -> Void
    var draft: TeamTaskEditorDraft { drafts[0] }
    init(draft: TeamTaskEditorDraft, current: @escaping () -> Bool, perform: @escaping (UUID) -> Bool, completed: @escaping () -> Void) {
        id = UUID(); drafts = [draft]; selection = nil
        self.current = current; self.perform = perform; self.completed = completed
    }
    init(selection: TeamTaskDeletionSelection, current: @escaping () -> Bool, perform: @escaping () -> Bool, completed: @escaping () -> Void) {
        id = selection.requestID; drafts = selection.drafts; self.selection = selection
        self.current = current; self.perform = { _ in perform() }; self.completed = completed
    }
}

struct TeamTaskDeletionReview: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: TeamTaskDeletionRequest
    @State private var message: String?
    @State private var finished = false
    private var refusal: String? {
        guard !finished, request.current() else { return "This review is no longer current. Close it and review the tasks again before deleting." }
        do {
            if let selection = request.selection { _ = try store.reviewedTeamTaskDeletionSelection(selection) }
            else { _ = try store.reviewedTeamTaskDeletion(request.draft, requestID: request.id) }
            return nil
        }
        catch { return error.localizedDescription }
    }
    var body: some View {
        let blocked = refusal
        NavigationStack {
            Form {
                if blocked == nil {
                Section {
                    if request.selection != nil {
                        Text("\(request.drafts.count) shared tasks").font(.title2.weight(.semibold))
                        Text("Delete only the tasks listed below, for everyone in their projects. Their notes, checklists, attachments and conversations stay available for Undo on this device. Unselected repeat occurrences stay in place and are detached when their parent is deleted.").foregroundStyle(.secondary)
                    } else {
                    Text(request.draft.source.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    LabeledContent("Project", value: store.record("projects", id: request.draft.scope.project)?.name ?? "Shared project")
                    Text("This removes the task for everyone in this project, including its saved notes, checklist and attachments. Other tasks in the repeat series stay in place.").foregroundStyle(.secondary)
                    }
                }
                if request.selection != nil {
                    Section("Selected tasks") {
                        ForEach(request.drafts, id: \.source.id) { draft in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(draft.source.title).fixedSize(horizontal: false, vertical: true)
                                Text(store.record("projects", id: draft.scope.project)?.name ?? "Shared project").font(.caption).foregroundStyle(.secondary)
                            }.accessibilityElement(children: .combine)
                        }
                    }.accessibilityIdentifier("teamDeletionSelection")
                }
                Section {
                    Label("Undo stays available on this device", systemImage: "arrow.uturn.backward")
                    Text("The shared conversation is preserved for Undo. Restoring requires current project access.").font(.footnote).foregroundStyle(.secondary)
                }
                }
                if let blocked { Section { Label("Deletion paused", systemImage: "lock.shield"); Text(blocked).foregroundStyle(.secondary) }.accessibilityIdentifier("teamDeletionPaused") }
                if let message { Section { Text(message).foregroundStyle(.red).accessibilityIdentifier("teamDeletionError") } }
                Section {
                    Button(role: .destructive) {
                        guard !finished, refusal == nil else { return }
                        if request.perform(request.id) {
                            finished = true; request.completed(); dismiss()
                        } else {
                            message = store.error ?? "The tasks could not be deleted. Their saved contents are unchanged; try again."
                            store.error = nil
                        }
                    } label: {
                        Label(request.selection == nil ? "Delete task for everyone" : "Delete \(request.drafts.count) tasks for everyone", systemImage: "trash").foregroundStyle(blocked == nil ? Color.red : Color.secondary)
                    }.disabled(blocked != nil).accessibilityIdentifier("confirmTeamTaskDeletion")
                }
                #if DEBUG
                if TeamEditorNativeFixture.enabled, ProcessInfo.processInfo.arguments.contains("--team-delete-testing") {
                    Section {
                        Button("Change test role to viewer") { store.revokeTeamEditorNativeFixture() }.accessibilityIdentifier("revokeTeamDeletionFixture")
                        Button("Change saved test task") { store.changeTeamDeletionFixtureSource() }.accessibilityIdentifier("changeTeamDeletionFixture")
                        Button("Fail the next test save") { store.failTeamDeletionFixtureSave() }.accessibilityIdentifier("failTeamDeletionFixture")
                    }
                }
                #endif
            }.formStyle(.grouped).accessibilityIdentifier("teamDeletionForm")
            .navigationTitle(request.selection == nil ? "Delete shared task?" : "Delete shared tasks?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("cancelTeamTaskDeletion") } }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 430, idealHeight: 580)
        #endif
    }
}


struct TeamTaskPlanningRequest: Identifiable {
    let selection: TeamTaskPlanningSelection
    let title: String
    let perform: () -> Bool
    let completed: () -> Void
    var back: (() -> Void)? = nil
    var assignmentName: String? = nil
    var id: UUID { selection.requestID }
}

struct TeamTaskPlanningReview: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: TeamTaskPlanningRequest
    @State private var message: String?
    @State private var finished = false
    private var changesAssignment: Bool { request.selection.changes.values.contains { $0["assigned_to"] != nil } }
    private var refusal: String? {
        guard !finished else { return "This selection has already been saved." }
        do { _ = try store.reviewedTeamTaskPlanningSelection(request.selection); return nil }
        catch { return error.localizedDescription }
    }
    var body: some View {
        let blocked = refusal
        NavigationStack {
            Form {
                Section {
                    Label(request.title, systemImage: changesAssignment ? "person.crop.circle.badge.checkmark" : "calendar.badge.checkmark").font(.title2.weight(.semibold))
                    Text("Review \(request.selection.drafts.count) shared \(request.selection.drafts.count == 1 ? "task" : "tasks"). This change affects everyone with access. The complete selection saves together; a changed or unavailable task pauses the whole action.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if blocked == nil {
                    Section("Selected tasks and changes") {
                        ForEach(request.selection.drafts, id: \.source.id) { draft in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(draft.source.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                                Text(store.record("projects", id: draft.scope.project)?.name ?? "Shared project").font(.caption).foregroundStyle(.secondary)
                                ForEach(displayKeys(request.selection.changes[draft.source.id] ?? [:]), id: \.self) { key in
                                    LabeledContent(fieldTitle(key), value: valueTitle(request.selection.changes[draft.source.id]![key]!, key: key)).font(.callout)
                                }
                            }.padding(.vertical, 5).accessibilityElement(children: .combine)
                        }
                    }.accessibilityIdentifier("teamPlanningSelection")
                    Section {
                        Label("Undo stays available on this device", systemImage: "arrow.uturn.backward")
                        Text(changesAssignment ? "Undo requires current access and the same saved task contents. Notes, conversations, repeat rules and other planning details are kept." : "Undo requires current access and the same saved task contents. Notes, conversations, assignments and repeat rules are kept.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let blocked { Section { Label("Planning paused", systemImage: "lock.shield"); Text(blocked).foregroundStyle(.secondary) }.accessibilityIdentifier("teamPlanningPaused") }
                if let message { Section { Text(message).foregroundStyle(.red).accessibilityIdentifier("teamPlanningError") } }
                Section {
                    Button("Save changes together") {
                        guard !finished, refusal == nil else { return }
                        if request.perform() { finished = true; request.completed(); dismiss() }
                        else { message = store.error ?? "The selection could not be saved. Your tasks are unchanged; try again."; store.error = nil }
                    }.disabled(blocked != nil || finished).accessibilityIdentifier("confirmTeamPlanning")
                }
                #if DEBUG
                if TeamEditorNativeFixture.enabled, ProcessInfo.processInfo.arguments.contains("--team-planning-testing") {
                    Section("Isolated test controls") {
                        Button("Change saved test task") { store.changeTeamDeletionFixtureSource() }.accessibilityIdentifier("changeTeamPlanningFixture")
                        Button("Fail next test save") { store.failTeamDeletionFixtureSave() }.accessibilityIdentifier("failTeamPlanningFixture")
                    }
                }
                #endif
            }.formStyle(.grouped).accessibilityIdentifier("teamPlanningForm")
            .navigationTitle("Review changes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
             .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("cancelTeamPlanning") }
                if let back = request.back { ToolbarItem(placement: .primaryAction) { Button("Edit choice") { back() }.accessibilityIdentifier("editTeamPlanningChoice") } }
            }
            #if os(macOS)
            .frame(minWidth: 500, idealWidth: 580, minHeight: 440)
            #endif
        }.privacySensitive()
    }
    private func fieldTitle(_ key: String) -> String {
        switch key { case "priority": "Priority"; case "due_date": "Date"; case "due_time": "Time"; case "time_zone": "Time zone"; case "scheduled_at": "Date and time"; case "deadline_date": "Deadline"; case "duration_minutes": "Estimate"; case "assigned_to": "Assign to"; default: "Planning" }
    }
    private func displayKeys(_ fields: [String: JSON]) -> [String] {
        ["priority", "due_date", "due_time", "time_zone", "scheduled_at", "deadline_date", "duration_minutes", "assigned_to"].filter { key in
            guard fields[key] != nil else { return false }
            if key == "scheduled_at", fields["due_date"] != nil || fields["due_time"] != nil { return false }
            if fields["due_date"] == .null, ["due_time", "time_zone"].contains(key), fields[key] == .null { return false }
            return true
        }
    }
    private func valueTitle(_ value: JSON, key: String) -> String {
        switch value {
        case .null: return key == "assigned_to" ? "Unassigned" : "None"
        case .string(let text):
            if key == "assigned_to" { return request.assignmentName ?? "Team member" }
            if ["due_date", "deadline_date"].contains(key), let date = Dates.parse(text) { return date.formatted(date: .abbreviated, time: .omitted) }
            if key == "scheduled_at", let date = ISO8601DateFormatter().date(from: text) { return date.formatted(date: .abbreviated, time: .shortened) }
            return text
        case .number(let number):
            if key == "priority", number == 4 { return "None" }
            return number.formatted(.number) + (key == "duration_minutes" ? " min" : "")
        default: return "Review required"
        }
    }
}


struct TeamTaskPlanningSheet: ViewModifier {
    @Binding var request: TeamTaskPlanningRequest?
    @Binding var input: BulkTaskPlanningRequest?
    @Binding var assignment: BulkTaskAssignmentRequest?
    init(request: Binding<TeamTaskPlanningRequest?>, input: Binding<BulkTaskPlanningRequest?> = .constant(nil), assignment: Binding<BulkTaskAssignmentRequest?> = .constant(nil)) { _request = request; _input = input; _assignment = assignment }
    func body(content: Content) -> some View {
        content.sheet(item: $request) { TeamTaskPlanningReview(request: $0) }.sheet(item: $input) { BulkTaskPlanningEditor(request: $0) }.sheet(item: $assignment) { BulkTaskAssignmentEditor(request: $0) }
    }
}
