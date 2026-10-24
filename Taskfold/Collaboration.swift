import SwiftUI

extension Workspace {
    static func clearingAssignments(_ task: Record) -> Record {
        var result = task; result["assigned_to"] = .null
        if !task["subtasks"].list.isEmpty {
            result["subtasks"] = .array(task["subtasks"].list.map { .object(clearingAssignments(Record($0.object)).fields) })
        }
        return result
    }

    func rootTask(_ id: String) -> Record? {
        store.record("tasks", id: Self.subtaskPath(id)?.first ?? id)
    }
    func parentTitle(_ id: String) -> String? {
        guard Self.subtaskPath(id) != nil else { return nil }
        guard hierarchyFilter, let path = Self.subtaskPath(id), var parent = rootTask(id) else { return rootTask(id)?.title }
        var titles = [parent.title]
        for key in path.dropFirst().dropLast() {
            guard let child = parent["subtasks"].list.enumerated().first(where: { Self.childKey($0.element, index: $0.offset) == key }) else { return nil }
            parent = Record(child.element.object); titles.append(parent.title)
        }
        return titles.joined(separator: " › ")
    }
    var assignedTasks: [Record] {
        var result: [Record] = []
        func visit(_ task: Record, depth: Int) {
            if task.string("assigned_to").lowercased() == store.userID.lowercased() { result.append(task) }
            guard depth < SubtaskTree.readableDepth else { return }
            for (index, value) in task["subtasks"].list.enumerated() {
                let id = childID(parent: task.id, value: value, index: index)
                if let child = taskRecord(id) { visit(child, depth: depth + 1) }
            }
        }
        for task in store.activeTasks { visit(task, depth: 0) }
        return result
    }
    func assignmentProject(_ task: Record, contextID: String? = nil) -> String {
        let id = contextID ?? task.id
        return Self.subtaskPath(id) == nil ? task.string("project_id") : rootTask(id)?.string("project_id") ?? ""
    }
    func assignmentMembers(_ task: Record, contextID: String? = nil) -> [Record] {
        let project = assignmentProject(task, contextID: contextID)
        if project.isEmpty { return [store.accountIdentity] }
        let accepted = Set(store.rows("project_collaborators").filter { $0.string("project_id") == project && $0.string("status") == "accepted" }.map { $0.string("user_id").lowercased() } + [store.record("projects", id: project)?.string("user_id").lowercased() ?? ""])
        var members = (projectMembers[project] ?? []).filter { store.localMode || accepted.contains($0.string("user_id").lowercased()) }
        // Everyone viewing the project can assign themselves even while the directory loads.
        if !members.contains(where: { $0.string("user_id").lowercased() == store.userID.lowercased() }) {
            members.insert(store.accountIdentity, at: 0)
        }
        return members.map { $0.string("user_id").lowercased() == store.userID.lowercased() ? store.accountIdentity : $0 }
    }
    func assigneeName(_ task: Record, contextID: String? = nil) -> String {
        let id = task.string("assigned_to")
        if id.isEmpty { return "Unassigned" }
        if id.lowercased() == store.userID.lowercased() { return store.accountName }
        return assignmentMembers(task, contextID: contextID).first { $0.string("user_id").lowercased() == id.lowercased() }?.string("display_name") ?? "Project member"
    }
    func assign(_ id: String, to user: String) {
        updateTasks([id], fields: ["assigned_to": user.isEmpty ? .null : .string(user)], name: user.isEmpty ? "Remove Assignment" : "Assign Task")
    }
    func loadProjectMembers() async { await refreshMemberDirectory() }

}

struct AssigneeMenu: View {
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(Workspace.self) private var workspace
    let task: Record
    var contextID: String? = nil
    var selected = false
    var showsName = false
    var select: (String) -> Void
    private var name: String { workspace.assigneeName(task, contextID: contextID) }
    private var identity: Record {
        if task.string("assigned_to").lowercased() == workspace.store.userID.lowercased() { return workspace.store.accountIdentity }
        return workspace.assignmentMembers(task, contextID: contextID).first { $0.string("user_id") == task.string("assigned_to") } ?? Record(["display_name": .string(name)])
    }
    @State private var choosing = false
    @State private var photoLoaded = false
    var body: some View {
        Button { choosing.toggle() } label: {
            HStack(spacing: 5) {
                if task.string("assigned_to").isEmpty { Image(systemName: "person.crop.circle.badge.plus") }
                else { PersonAvatar(person: identity, size: showsName ? 22 : 20, didLoad: { photoLoaded = $0 }).accessibilityHidden(true) }
                if showsName { Text(name).lineLimit(1) }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }.foregroundStyle(selected ? Color(nsColor: controlActiveState == .inactive ? .labelColor : .alternateSelectedControlTextColor) : .secondary)
        }
        .buttonStyle(.borderless).fixedSize()
        .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
        .accessibilityValue(task.string("assigned_to").isEmpty ? "" : photoLoaded ? "Photo loaded" : "Photo placeholder")
        .help("Assigned to \(name)").accessibilityLabel("Assigned to \(name)")
        .accessibilityIdentifier(showsName ? "taskAssignee" : "assignee-" + task.id)
        .popover(isPresented: $choosing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Assign task").font(.headline)
                Button("Unassigned") { select(""); choosing = false }
                Divider()
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(Array(workspace.assignmentMembers(task, contextID: contextID).enumerated()), id: \.offset) { _, member in
                            let id = member.string("user_id")
                            Button { select(id); choosing = false } label: {
                                HStack(spacing: 10) {
                                    PersonAvatar(person: member, size: 30).accessibilityHidden(true)
                                    Text(member.string("display_name").isEmpty ? "Project member" : member.string("display_name")).foregroundStyle(.primary)
                                    Spacer()
                                    if id == task.string("assigned_to") { Image(systemName: "checkmark") }
                                }.padding(6).contentShape(.rect)
                            }.buttonStyle(.plain).accessibilityIdentifier("assign-member-" + id)
                        }
                    }
                }.frame(maxHeight: 240)
                if let error = workspace.memberLoadError { Text(error).font(.caption).foregroundStyle(.secondary) }
                Button("Refresh Members") { Task { await workspace.refreshMemberDirectory(force: [workspace.assignmentProject(task, contextID: contextID)]) } }
                    .disabled(workspace.store.localMode)
            }.padding(16).frame(width: 270)
        }
    }

}

/// A review is tied to one queued mutation; Later leaves synchronization paused.
struct ConflictReview: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let conflict: SyncConflict
    @State private var message: String?
    private var current: Bool { store.syncConflict?.id == conflict.id && store.snapshot.pending.contains(conflict.mutation) }
    private var goalConflict:Bool { ProductivityGoalEdit.matches(conflict.mutation) }
    private var unsupportedGoals:Bool { goalConflict && (!ProductivityGoalEdit.valid(conflict.mutation,account:store.userID) || (try? ProductivityGoals(document:conflict.remote[ProductivityGoals.field])) == nil) }
    private var templateConflict: Bool { conflict.mutation.table == WorkflowTemplate.table }
    private var unsupportedTemplate: Bool { templateConflict && conflict.remote["document"] != .null && (try? WorkflowTemplate(document:conflict.remote["document"])) == nil && conflict.mutation.fields["document"] != nil }
    private var missingTemplate: Bool { templateConflict && conflict.remote["document"] == .null }
    private var deleting: Bool { conflict.mutation.method == "DELETE" }
    private var bothCompleted: Bool { !deleting && conflict.remote.completed && conflict.mutation.fields["completed"] == .bool(true) && conflict.mutation.fields["completed_at"] != nil }
    private var keys: [String] {
        if goalConflict { return [ProductivityGoals.field] }
        let fields = deleting ? conflict.remote.fields : conflict.mutation.fields
        let visible = fields.keys.filter { !["completion_version", "task_generation"].contains($0) && (!deleting || !["id", "user_id", "source_metadata", "created_at", "notification_sent_at"].contains($0)) }
        guard deleting else {
            if bothCompleted, visible.contains("completed_at") { return ["completed_at"] + visible.filter { $0 != "completed_at" }.sorted() }
            return visible.sorted()
        }
        let contentOrder = ["description", "title", "comments", "subtasks", "due_date", "due_time", "deadline_date", "duration_minutes", "priority"]
        return visible.sorted { lhs, rhs in
            let leftChanged = changedSinceDeletion(lhs), rightChanged = changedSinceDeletion(rhs)
            if leftChanged != rightChanged { return leftChanged }
            let leftRank = contentOrder.firstIndex(of: lhs) ?? contentOrder.count
            let rightRank = contentOrder.firstIndex(of: rhs) ?? contentOrder.count
            return leftRank == rightRank ? lhs < rhs : leftRank < rightRank
        }
    }
    private func changedSinceDeletion(_ key: String) -> Bool {
        guard deleting, let baseline = conflict.mutation.baseline else { return false }
        return (baseline[key] ?? .null) != conflict.remote[key]
    }
    var body: some View {
        if let review=conflict.completionReview { TeamCompletionReviewContent(review:review) }
        else { ordinaryReview }
    }
    private var ordinaryReview: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Your work is saved", systemImage: "checkmark.icloud").font(.headline).foregroundStyle(Color.taskfold)
                    Text(goalConflict ? "Productivity goals" : templateConflict ? conflict.remote.name : conflict.remote.title).font(.headline)
                    if goalConflict {
                        Text("Goals changed on another device. Compare both choices before saving. Your draft and recorded task history are kept.").foregroundStyle(.secondary)
                    } else if templateConflict {
                        Text(missingTemplate ? "This template was removed on another device. Keep your edits as a new template, or accept the deletion. Existing runs stay unchanged." : "This reusable definition changed on another device. Compare both versions before continuing. Existing runs stay unchanged.").foregroundStyle(.secondary)
                    } else {
                    Text(deleting ? "This task changed before it could be deleted. Review its current contents before choosing how to continue." : bothCompleted ? "Both devices completed this task. Compare the completion times below, then choose which time to keep." : "Changes from another device overlap with this edit. Compare the values below, then choose how to continue.").foregroundStyle(.secondary)
                    }
                }
                ForEach(keys, id: \.self) { key in
                    Section(fieldName(key)) {
                        if !deleting { VStack(alignment: .leading, spacing: 6) {
                            Text("My edit").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            Text(summary(conflict.mutation.fields[key] ?? .null, key: key)).textSelection(.enabled)
                        } }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(changedSinceDeletion(key) ? "Changed since deletion" : "Synced version").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            Text(summary(conflict.remote[key], key: key)).textSelection(.enabled)
                        }
                    }
                }
                Section {
                    if goalConflict {
                        Text("Keep my goals saves the targets, weekdays and time zone shown above. Use synced goals discards only this queued choice. Independent settings and later queued changes are retained.").font(.callout).foregroundStyle(.secondary)
                    } else if templateConflict {
                        Text("Keep my edit replaces the changed definition fields shown above. Use synced discards this queued edit. Later offline work is retained. A removed template can be saved under a new identity.").font(.callout).foregroundStyle(.secondary)
                    } else if deleting {
                        Text("Keep task cancels this queued deletion and restores the synced task. Delete task removes the contents shown here; if another device changes them again, you will be asked to review again. Later offline edits and other tasks are kept.").font(.callout).foregroundStyle(.secondary)
                    } else if bothCompleted {
                        Text("Keep my edit keeps your completion time. Use synced keeps the other device’s completion time. Either choice removes an unedited next occurrence created only on this device. Later edits to that occurrence are kept as an independent task. Existing synced tasks and later offline work are kept.").font(.callout).foregroundStyle(.secondary)
                    } else if TaskCompletionRevision.touches(conflict.mutation.fields) {
                        Text((conflict.mutation.baseline?["completion_version"] == nil ? "This older completion needs review. " : "Completion changed on another device. ") + "Keep my edit applies the completion shown above. Use synced version keeps the synced task and removes an unedited next occurrence created by this completion. Any later edits to that occurrence are kept as an independent task. Later offline work is retained.").font(.callout).foregroundStyle(.secondary)
                    } else if conflict.mutation.fields.keys.contains(where: { conflict.mutation.baseline?[$0] == nil }) {
                        Text("This edit came from an older app version. Keep my edit uses the values shown above, including any comments or subtasks in this edit. Use synced version keeps the current synced values. Later offline edits and other tasks are kept.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("Keep my edit applies your changes and retains independent labels, comments and subtask edits. Use synced version discards this queued edit. Later offline edits and other tasks are kept with either choice.").font(.callout).foregroundStyle(.secondary)
                    }
                    if unsupportedGoals { Text("A goal definition needs a newer Taskfold version. Keep the synced choice or update Taskfold.").foregroundStyle(.secondary) }
                    if unsupportedTemplate { Text("The synced definition needs a newer Taskfold version. It cannot be replaced by this older draft.").foregroundStyle(.secondary) }
                    if !current { Text("This edit is no longer waiting for review. Close this screen and reopen the current review.").foregroundStyle(.secondary) }
                }
            }.formStyle(.grouped)
            .navigationTitle(goalConflict ? "Review goals" : templateConflict ? "Review template edit" : deleting ? "Review task deletion" : "Review sync edit")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Divider()
                    Button(goalConflict ? "Keep my goals" : templateConflict ? (deleting ? "Delete template" : missingTemplate ? "Save as new template" : "Keep my edit") : (deleting ? "Delete task" : "Keep my edit"), role: deleting ? .destructive : nil) { resolve(keepLocal: true) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("keepMyEdit").disabled(!current || unsupportedTemplate || unsupportedGoals)
                    Button(goalConflict ? "Use synced goals" : templateConflict ? (deleting ? "Keep template" : "Use synced") : (deleting ? "Keep task" : "Use synced")) { resolve(keepLocal: false) }
                        .buttonStyle(.bordered).accessibilityIdentifier("useSharedEdit").disabled(!current)
                    Button { dismiss() } label: { Text("Later").frame(minHeight: 44) }
                        .buttonStyle(.plain).accessibilityIdentifier("conflictLater")
                        .keyboardShortcut(.cancelAction)
                }.controlSize(.large).padding([.horizontal, .bottom]).frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
            .alert("Review could not finish", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
        }
        #if os(macOS)
        .frame(width: 620, height: 680)
        #endif
        .onChange(of: store.workspaceGeneration) { _, _ in dismiss() }
    }
    private func resolve(keepLocal: Bool) {
        if store.resolveConflict(id: conflict.id, keepLocal: keepLocal) { dismiss() }
        else { message = store.error ?? "Reopen the current sync review."; store.error = nil }
    }
    private func fieldName(_ key: String) -> String {
        [ProductivityGoals.field:"Productivity goals", "document":"Workflow definition", "name":"Template name", "title":"Task title", "description":"Notes", "due_date":"Planned date", "due_time":"Planned time", "deadline_date":"Deadline", "duration_minutes":"Estimate", "project_id":"Project", "section_id":"Section", "assigned_to":"Assigned to", "subtasks":"Subtasks", "comments":"Comments", "scheduled_at":"Scheduled instant", "time_zone":"Time zone", "recurrence_pattern":"Repeat rule", "reminder_specs":"Reminders", "completed":"Status", "completed_at":"Completed at", "priority":"Priority", "labels":"Labels"][key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
    }
    private func summary(_ value: JSON, key: String = "") -> String {
        if key == ProductivityGoals.field { return ProductivityGoalEdit.summary(value) }
        if key == "document" { return TemplateEditing.reviewText(value) }
        if key == "completed", case .bool(let flag) = value { return flag ? "Completed" : "Open" }
        if key == "completed_at", let date = TaskPlanning.instant(value.text) { return date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().second().timeZone(.specificName(.short))) }
        if value == .null { return "None" }
        if key == "duration_minutes", case .number(let minutes) = value { return "\(Int(minutes)) minutes" }
        if key == "priority", case .number(let number) = value { return "P\(Int(number))" }
        if let table = ["project_id":"projects", "section_id":"sections", "labels":"labels"][key] {
            if case .array(let items) = value { return items.isEmpty ? "No labels" : items.map { store.record(table, id: $0.text)?.name ?? $0.text }.joined(separator: ", ") }
            return store.record(table, id: value.text)?.name ?? "Unavailable \(key == "project_id" ? "project" : "section")"
        }
        switch value {
        case .null: return "None"
        case .string(let text): return text.isEmpty ? "Empty" : text
        case .bool(let flag): return flag ? "Yes" : "No"
        case .number(let number): return String(format: "%g", number)
        case .array(let items): return items.isEmpty ? "No items" : items.map { summary($0) }.joined(separator: "\n\n")
        case .object(let fields):
            return fields.keys.sorted().filter { !["id", "authorId", "data"].contains($0) }.map { "\(fieldName($0)): \(summary(fields[$0]!))" }.joined(separator: " · ")
        }
    }
}


/// Recorded outcomes can be acknowledged without repeating the action. A read
/// that finds no receipt permits only an exact retry, never a destructive discard.
private struct TeamCompletionReviewContent: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let review: TeamCompletion.Review
    @State private var checking=false
    @State private var message:String?
    private var current:Bool {store.syncConflict?.completionReview == review && store.snapshot.pending.first == review.mutation}
    private var canContinue:Bool {current && !review.isCancelled && (!review.isRecorded || review.acknowledging(store.snapshot) != nil)}
    private var canUseSynced:Bool {current && review.canRequestCancellation(store.snapshot)}
    private var command:TeamCompletion {review.mutation.teamCompletion!}
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    Label("Your work is saved",systemImage:"checkmark.icloud").font(.headline).foregroundStyle(Color.taskfold)
                    Text(command.source.title).font(.headline)
                    Text(review.isCancelled ? "This saved action was cancelled. Keep the synced task to continue." : review.isRecorded ? "This action was recorded. Check the current task below before continuing sync." : "This action has no recorded result yet. You can check again or retry the same saved action.").foregroundStyle(.secondary)
                }
                Section("Your saved action") {
                    Label(command.operation == .complete ? "Complete task" : "Reopen task",systemImage:command.operation == .complete ? "checkmark.circle":"arrow.uturn.backward.circle")
                    if let date=TaskPlanning.instant(command.completedAt) {LabeledContent("Completion time",value:date.formatted(date:.abbreviated,time:.shortened))}
                }
                Section("Current synced task") { taskSummary(review.task,missing:"The original task is no longer available here.") }
                if command.proposed != nil {
                    Section("Current synced next occurrence") {taskSummary(review.successor,missing:"No next occurrence is available in this review.")}
                    if let local=store.record("tasks",id:command.proposed!.id),local["task_generation"] == command.proposed?["task_generation"],!TeamCompletion.sameLocal(local,command.proposed!) {
                        Section("Your saved next occurrence") {taskSummary(local,missing:"")}
                    }
                }
                Section {
                    if (review.isRecorded && !canContinue) || (!review.isRecorded && !canUseSynced) {Text("Additional task changes are saved on this device. They need a separate review before sync can resume.").foregroundStyle(.secondary)}
                    if !review.isRecorded && !review.isCancelled {Text("Retry keeps your original action and completion time. If the task changed, your work stays saved for review.").foregroundStyle(.secondary)}
                    if !review.isRecorded {Text("Use synced task cancels only this saved action and removes its untouched local next occurrence. A recovery copy is saved first. Related edits and comment drafts stay protected.").foregroundStyle(.secondary)}
                    if review.role == .viewer {Text("You currently have view access to this project.").foregroundStyle(.secondary)}
                }
            }.formStyle(.grouped)
            .navigationTitle("Review completion")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge:.bottom) {
                VStack(spacing:10) {
                    Divider()
                    if !review.isCancelled { Button(review.isRecorded ? "Continue sync":"Retry saved action") {
                        if store.continueTeamCompletionReview(review) {dismiss()}
                        else {message=store.error ?? "Reopen the current sync review.";store.error=nil}
                    }.buttonStyle(.borderedProminent).disabled(!canContinue || checking || (!review.isRecorded && review.role == .viewer)).accessibilityIdentifier("continueTeamCompletionReview") }
                    if !review.isRecorded {
                        Button("Use synced task") {
                            checking=true
                            Task {
                                let success=await store.cancelTeamCompletionReview(review);checking=false
                                if success {dismiss()}
                                else if store.syncConflict?.completionReview == review {message=store.error ?? "Your task changed. Check again before continuing.";store.error=nil}
                            }
                        }.buttonStyle(.bordered).disabled(!canUseSynced || checking).accessibilityIdentifier("cancelSavedTeamCompletion")
                    }
                    Button("Check again") {checking=true;Task {let success=await store.refreshTeamCompletionReview(review);checking=false;if !success {message=store.error ?? "Reopen the current sync review.";store.error=nil}}}
                        .buttonStyle(.bordered).disabled(!current || checking).accessibilityIdentifier("refreshTeamCompletionReview")
                    Button("Later") {dismiss()}.buttonStyle(.plain).keyboardShortcut(.cancelAction).frame(minHeight:44)
                }.controlSize(.large).padding([.horizontal,.bottom]).frame(maxWidth:.infinity).background(.regularMaterial)
            }
            .alert("Review could not finish",isPresented:Binding(get:{message != nil},set:{if !$0 {message=nil}})) {Button("OK"){message=nil}} message:{Text(message ?? "")}
        }
        #if os(macOS)
        .frame(width:620,height:680)
        #endif
        .onChange(of:store.workspaceGeneration){_,_ in dismiss()}
    }
    @ViewBuilder private func taskSummary(_ task:Record?,missing:String) -> some View {
        if let task {
            Text(task.title).font(.headline).textSelection(.enabled)
            Text(task.completed ? "Completed":"Open").foregroundStyle(.secondary)
            if !task.string("description").isEmpty {Text(task.string("description")).textSelection(.enabled)}
            if !task.string("due_date").isEmpty {LabeledContent("Planned date",value:task.string("due_date"))}
        } else {Text(missing).foregroundStyle(.secondary)}
    }
}
