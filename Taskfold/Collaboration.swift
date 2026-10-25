import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
        if let review = conflict.completionBatchReview {
            if let latest = store.syncConflict?.completionBatchReview, latest.mutation == review.mutation { TeamCompletionBatchReviewContent(review: latest) }
            else { TeamCompletionBatchReviewContent(review: review) }
        }
        else if let review=conflict.completionReview { TeamCompletionReviewContent(review:review) }
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
        let preview=review.previewRebase(store.snapshot)
        let park=TeamCompletionDraft.Candidate(review:review,snapshot:store.snapshot)
        NavigationStack {
            Form {
                Section {
                    Label("Your work is saved",systemImage:"checkmark.icloud").font(.headline).foregroundStyle(Color.taskfold)
                    Text(command.source.title).font(.headline)
                    Text(review.isCancelled ? "This saved action was cancelled. Keep the synced task to continue." : review.isRecorded ? "This action was recorded. Check the current task below before continuing sync." : "This action has no recorded result yet. You can check again or retry the same saved action.").foregroundStyle(.secondary)
                }
                if park != nil {
                    Section("Keep your edited next task") {
                        Text("Save your local edits and comment drafts separately on this device, keep the shared task unchanged, and let sync continue. Saved team drafts are available in Backups & restore.").foregroundStyle(.secondary)
                    }
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
                if let preview {
                    Section("Apply to the current version") {
                        if command.operation == .complete {
                            Text("Complete the task shown above using your original completion time. Its current notes, repeat rule and other details are kept.").foregroundStyle(.secondary)
                            if let next=preview.teamCompletion?.proposed {LabeledContent("Next planned date",value:next.string("due_date"))}
                            else {Text("No new occurrence is planned.").foregroundStyle(.secondary)}
                            Text("Existing shared occurrences are kept.").font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text("Reopen the task shown above. Its current notes and existing next occurrence are kept.").foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    if park == nil && ((review.isRecorded && !canContinue) || (!review.isRecorded && !canUseSynced)) {Text("Additional task changes are saved on this device. They need a separate review before sync can resume.").foregroundStyle(.secondary)}
                    if !review.isRecorded && !review.isCancelled {Text("Retry keeps your original action and completion time. If the task changed, your work stays saved for review.").foregroundStyle(.secondary)}
                    if !review.isRecorded {Text("Use synced task cancels only this saved action and removes its untouched local next occurrence. A recovery copy is saved first. Related edits and comment drafts stay protected.").foregroundStyle(.secondary)}
                    if !review.isRecorded && !review.canEditCurrent && review.task != nil {Text("Editing is not available for this task right now. You can keep the synced version or check again after project access changes.").foregroundStyle(.secondary)}
                    if !review.isRecorded && review.canEditCurrent && !review.hasRebaseProject(in:store.snapshot) {Text("This project isn’t in your current workspace. Your saved action is protected; reopen the project before applying it to the current task.").foregroundStyle(.secondary).accessibilityIdentifier("teamCompletionProjectUnavailable")}
                    if preview == nil && review.canEditCurrent && command.operation == .complete && review.task?.completed == false && review.task?["is_recurring"].flag == true && review.task?.string("recurrence_parent_id").isEmpty == false && !review.canEditSeries {Text("Editing access to the repeat series is needed before this completion can be applied.").foregroundStyle(.secondary)}
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
                    if park != nil {
                        Button("Keep edits as draft") {
                            checking=true;Task {let success=await store.parkTeamCompletionDraft(review);checking=false;if success {dismiss()} else {message=store.error ?? "Your draft remains saved for review.";store.error=nil}}
                        }.buttonStyle(.borderedProminent).disabled(!current || checking).accessibilityIdentifier("parkTeamCompletionDraft")
                    }
                    if let _=preview {
                        Button(command.operation == .complete ? "Complete current task":"Reopen current task") {resolve(rebase:true)}
                            .buttonStyle(.borderedProminent).disabled(!current || checking).accessibilityIdentifier("rebaseTeamCompletion")
                    }
                    if !review.isCancelled && park == nil {
                        if review.isRecorded {
                            Button("Continue sync") {continueReview()}.buttonStyle(.borderedProminent).disabled(!canContinue || checking).accessibilityIdentifier("continueTeamCompletionReview")
                        } else {
                            Button("Retry saved action") {continueReview()}.buttonStyle(.bordered).disabled(!canContinue || checking || review.role == .viewer).accessibilityIdentifier("continueTeamCompletionReview")
                        }
                    }
                    if !review.isRecorded {
                        Button("Use synced task") {resolve(rebase:false)}.buttonStyle(.bordered).disabled(!canUseSynced || checking).accessibilityIdentifier("cancelSavedTeamCompletion")
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
    private func continueReview() {
        if store.continueTeamCompletionReview(review) {dismiss()}
        else {message=store.error ?? "Reopen the current sync review.";store.error=nil}
    }
    private func resolve(rebase:Bool) {
        checking=true
        Task {
            let success:Bool
            if rebase {success=await store.rebaseTeamCompletionReview(review)}
            else {success=await store.cancelTeamCompletionReview(review)}
            checking=false
            if success {dismiss()}
            else if store.syncConflict?.completionReview == review {message=store.error ?? "Your task changed. Check again before continuing.";store.error=nil}
        }
    }
    @ViewBuilder private func taskSummary(_ task:Record?,missing:String) -> some View {
        if let task {
            Text(task.title).font(.headline).textSelection(.enabled)
            Text(task.completed ? "Completed":"Open").foregroundStyle(.secondary)
            if task.completed,let date=TaskPlanning.instant(task.string("completed_at")) {LabeledContent("Completed at",value:date.formatted(date:.abbreviated,time:.shortened))}
            if !task.string("description").isEmpty {Text(task.string("description")).textSelection(.enabled)}
            if !task.string("due_date").isEmpty {LabeledContent("Planned date",value:task.string("due_date"))}
        } else {Text(missing).foregroundStyle(.secondary)}
    }
}

struct SavedTeamDraftsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var drafts:[TeamCompletionDraft]=[]
    @State private var loadedScope=""
    @State private var message:String?
    @State private var deleting:TeamCompletionDraft?
    @State private var copiedKey:String?
    @State private var copyReset:UUID?
    private var scopeKey:String {store.teamDraftVault.map{$0.account+"|"+$0.origin} ?? ""}
    var body:some View {
        NavigationStack {
            List {
                Section {
                    Text("These edits stay on this device and are never sent automatically. Open a draft to review a separate task copy or copy its text.").foregroundStyle(.secondary)
                }
                if scopeKey == loadedScope && !scopeKey.isEmpty {
                    ForEach(drafts) {draft in
                        NavigationLink {
                            Form {
                                Section("Saved text preview") {Text(previewText(draft.text)).textSelection(.enabled);Text("Copy or share includes the full saved text.").foregroundStyle(.secondary)}
                                if !draft.historyText.isEmpty {Section {DisclosureGroup("Earlier saved text changes") {Text(previewText(draft.historyText)).textSelection(.enabled);Button(copiedKey == draft.id.uuidString+"history" ? "Copied":"Copy earlier text"){copy(draft.historyText,key:draft.id.uuidString+"history")};ShareLink("Share earlier text",item:draft.historyText)}}}
                                Section("Saved task details") {
                                    LabeledContent("State",value:draft.record.completed ? "Completed":"Open")
                                    if case .number(let p)=draft.record["priority"],(1...4).contains(p) {LabeledContent("Priority",value:"P\(Int(p))")}
                                    if !draft.record.string("due_date").isEmpty {LabeledContent("Planned date",value:draft.record.string("due_date"))}
                                    if !draft.record.string("due_time").isEmpty {LabeledContent("Planned time",value:draft.record.string("due_time"))}
                                    if !draft.record.string("deadline_date").isEmpty {LabeledContent("Deadline",value:draft.record.string("deadline_date"))}
                                    if draft.record["duration_minutes"].integer>0 {LabeledContent("Estimate",value:"\(draft.record["duration_minutes"].integer) minutes")}
                                    LabeledContent("Attachments retained",value:String(draft.record["attachments"].list.count))
                                    LabeledContent("Reminder choices retained",value:String(draft.record["reminder_specs"].list.count))
                                }
                                Section {Text("The full task details and earlier edits remain in this encrypted draft. Copying text never changes a shared task.").foregroundStyle(.secondary)}
                                NavigationLink {SavedTeamDraftCopyView(draft:draft)} label:{Label("Review task copy",systemImage:"doc.badge.plus")}.accessibilityIdentifier("reviewSavedTeamDraftCopy")
                                Button(copiedKey == draft.id.uuidString ? "Copied":"Copy saved text",systemImage:"doc.on.doc"){copy(draft.text,key:draft.id.uuidString)}.accessibilityIdentifier("copyTeamDraftText")
                                ShareLink("Share saved text",item:draft.text).accessibilityIdentifier("shareTeamDraftText")
                            }.formStyle(.grouped).navigationTitle(draft.record.title)
                        } label: {
                            VStack(alignment:.leading,spacing:5) {
                                Text(draft.record.title).font(.headline).lineLimit(2)
                                Text(draft.createdAt.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)
                                Text("\(draft.edits.count) saved changes · \(draft.conversations.count) comment drafts").font(.caption).foregroundStyle(.secondary)
                            }
                        }.swipeActions {Button("Delete",role:.destructive){deleting=draft}}
                        .contextMenu {Button("Delete saved draft",role:.destructive){deleting=draft}}
                    }
                    if drafts.isEmpty {Text("No saved team drafts.").foregroundStyle(.secondary)}
                } else if scopeKey.isEmpty {Text("Open the original signed-in workspace to view its saved team drafts.").foregroundStyle(.secondary)}
                if let message {Text(message).foregroundStyle(.secondary)}
            }
            .navigationTitle("Saved team drafts")
            .toolbar {ToolbarItem(placement:.confirmationAction){Button("Done"){dismiss()}}}
            .task(id:scopeKey){await reload()}
            .confirmationDialog("Delete saved draft?",isPresented:Binding(get:{deleting != nil},set:{if !$0 {deleting=nil}})) {
                Button("Delete saved draft",role:.destructive){if let draft=deleting {Task {await remove(draft)}}}
                Button("Cancel",role:.cancel){deleting=nil}
            } message:{Text(deleting?.copyAttempt == nil ? "This removes only the saved copy on this device. Shared tasks stay unchanged." : "A task copy may already exist. Deleting this draft removes its saved retry request and does not undo that task copy.")}
        }
        #if os(macOS)
        .frame(minWidth:560,minHeight:520)
        #endif
        .onChange(of:store.workspaceGeneration){_,_ in drafts=[];dismiss()}
        .onChange(of:scopeKey){_,_ in drafts=[];loadedScope="";dismiss()}
    }
    private func copy(_ text:String,key:String) {
        #if os(macOS)
        NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)
        #else
        UIPasteboard.general.string=text
        #endif
        let reset=UUID();copiedKey=key;copyReset=reset
        Task {try? await Task.sleep(for:.seconds(3));if copyReset == reset {copiedKey=nil}}
    }
    private func previewText(_ text:String) -> String {String(String.UnicodeScalarView(text.unicodeScalars.prefix(12000)))}
    private func reload() async {
        drafts=[];message=nil;loadedScope=""
        let scope=scopeKey,generation=store.workspaceGeneration
        guard let vault=store.teamDraftVault else {return}
        do {
            let values=try await Task.detached(priority:.utility){try vault.entries()}.value
            guard generation == store.workspaceGeneration,scope == scopeKey else {return}
            drafts=values;loadedScope=scope
        } catch {
            guard generation == store.workspaceGeneration,scope == scopeKey else {return}
            message="Saved drafts could not be opened on this device. Your saved files are kept."
        }
    }
    private func remove(_ draft:TeamCompletionDraft) async {
        let scope=scopeKey,generation=store.workspaceGeneration
        guard let vault=store.teamDraftVault,draft.scope.account == vault.account,draft.scope.origin == vault.origin else {return}
        do {try await Task.detached(priority:.utility){try vault.remove(draft.id)}.value
            guard generation == store.workspaceGeneration,scope == scopeKey else {return}
            deleting=nil;await reload()
        } catch {if generation == store.workspaceGeneration,scope == scopeKey {message="This saved draft could not be removed. It is still kept on this device."}}
    }
}


/// An explicit preview precedes every first copy. A saved attempt keeps its
/// choices locked so a timeout cannot turn a retry into another task.
struct SavedTeamDraftCopyView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let draft:TeamCompletionDraft
    @State private var command:TeamCompletionDraft.CopyCommand?
    @State private var review:TeamCompletionDraft.CopyReview?
    @State private var assignments=false
    @State private var reminders=false
    @State private var busy=false
    @State private var message:String?
    @State private var finished=false
    @State private var requestSaved=false
    @State private var initialized=false
    var body:some View {
        Form {
            Section {
                Label("A separate task, with your details",systemImage:"doc.badge.plus").font(.headline)
                Text(draft.record.title).font(.headline)
                Text("Creates a new independent task in the original project. Your shared tasks and this encrypted draft are kept.").foregroundStyle(.secondary)
                if draft.markedForDeletion {Text("You had marked this draft for deletion. Creating a copy brings its saved content back as a separate task.").foregroundStyle(.secondary)}
            }
            Section("Copy choices") {
                Toggle("Include assignments",isOn:$assignments)
                Toggle("Include reminders",isOn:$reminders)
                Text("Assignments must still belong to current project editors. Private or unsupported reminders need separate setup and cannot be activated by copying.").font(.callout).foregroundStyle(.secondary)
                if requestSaved {Text("These choices belong to a saved copy request. Retrying checks the same task, so it cannot create a duplicate.").font(.callout).foregroundStyle(.secondary)}
            }.disabled(busy || requestSaved || finished)
            Section("Details kept") {
                Text("Task notes, checklist details and checked states, labels, planning, repeat settings, file references and supported extension data stay with the copy.")
                Text("The copy starts fresh completion history. Old discussion and saved comment drafts stay in this archive and are never published automatically.").foregroundStyle(.secondary)
            }
            if let review {
                Section(review.recorded ? "Saved copy":"New task preview") {
                    if let task=review.task {
                        Text(task.title).font(.headline)
                        taskDetails(task)
                        LabeledContent("Checklist items",value:String((try? TeamChecklist.indexed(task["subtasks"]).count) ?? 0))
                        LabeledContent("Task attachments",value:String(task["attachments"].list.count))
                    } else {Text(review.cancelled ? "The saved copy request was cancelled. You can review new choices." : "This copy was created, but it is no longer available here. Retrying will not recreate it. Your full draft is kept.").foregroundStyle(.secondary)}
                }
            }
            if let task=review?.task,!task["subtasks"].list.isEmpty {
                Section("Checklist preview") {
                    ForEach(checklist(task["subtasks"])) {item in
                        VStack(alignment:.leading,spacing:8) {
                            Label(item.record.title,systemImage:item.record.completed ? "checkmark.circle.fill":"circle").font(.headline)
                            taskDetails(item.record)
                        }.padding(.leading,CGFloat(min(item.depth,6))*12)
                    }
                }
            }
            if let message {Section {Text(message).foregroundStyle(.secondary).accessibilityIdentifier("teamDraftCopyMessage")}}
            Section {
                if !finished {
                    if requestSaved {Button("Change copy choices") {Task {await changeChoices()}}.disabled(busy).accessibilityIdentifier("changeSavedTeamDraftCopyChoices")}
                    Button(requestSaved ? "Check saved copy":"Review copy") {Task {await preview()}}.disabled(busy).accessibilityIdentifier("previewSavedTeamDraftCopy")
                    if let review,review.task != nil {
                        Button(review.recorded ? "Finish saved copy":"Create task copy") {Task {await create(review)}}
                            .buttonStyle(.borderedProminent).disabled(busy).accessibilityIdentifier("createSavedTeamDraftCopy")
                    }
                } else {Label("Copy saved. Your draft is kept.",systemImage:"checkmark.circle.fill").foregroundStyle(Color.taskfold)}
                if busy {ProgressView().accessibilityLabel("Checking saved task copy")}
            }
        }.formStyle(.grouped).navigationTitle("Review task copy")
        .onAppear {if !initialized {initialized=true;command=draft.copyAttempt;assignments=draft.copyAttempt?.assignments ?? false;reminders=draft.copyAttempt?.reminders ?? false;requestSaved=draft.copyAttempt != nil}}
        .onChange(of:assignments){_,_ in if !requestSaved {review=nil;command=nil}}
        .onChange(of:reminders){_,_ in if !requestSaved {review=nil;command=nil}}
        .onChange(of:store.workspaceGeneration){_,_ in review=nil;dismiss()}
    }
    private struct ChecklistItem: Identifiable {let record:Record;let depth:Int;var id:String {record.id}}
    private func checklist(_ value:JSON,depth:Int=0) -> [ChecklistItem] {
        guard depth<24 else {return []}
        return value.list.flatMap {item -> [ChecklistItem] in
            var record=Record(item.object);record["project_id"] = .string(draft.scope.project)
            return [ChecklistItem(record:record,depth:depth)]+checklist(record["subtasks"],depth:depth+1)
        }
    }
    @ViewBuilder private func taskDetails(_ task:Record) -> some View {
        if !task.string("description").isEmpty {
            Text(String(task.string("description").prefix(4000))).textSelection(.enabled)
            if task.string("description").count>4000 {Text("Preview shows the first 4,000 characters. The copy keeps the full notes.").font(.caption).foregroundStyle(.secondary)}
        }
        LabeledContent("State",value:task.completed ? "Completed":"Open")
        LabeledContent("Project",value:store.record("projects",id:draft.scope.project)?.name ?? "Original project")
        if case .number(let priority)=task["priority"],(1...4).contains(priority) {LabeledContent("Priority",value:"P\(Int(priority))")}
        if !task.string("due_date").isEmpty {LabeledContent("Planned date",value:task.string("due_date"))}
        if !task.string("due_time").isEmpty {LabeledContent("Planned time",value:task.string("due_time"))}
        if !task.string("time_zone").isEmpty {LabeledContent("Time zone",value:task.string("time_zone"))}
        if !task.string("deadline_date").isEmpty {LabeledContent("Deadline",value:task.string("deadline_date"))}
        if task["duration_minutes"].integer>0 {LabeledContent("Estimate",value:"\(task["duration_minutes"].integer) minutes")}
        if !task.string("section_id").isEmpty {LabeledContent("Section",value:store.record("sections",id:task.string("section_id"))?.name ?? "Saved section")}
        if !task["labels"].list.isEmpty {LabeledContent("Labels",value:task["labels"].list.map(\.text).joined(separator:", "))}
        if task["is_recurring"].flag {LabeledContent("Repeat",value:Recurrence.summary(Recurrence.effective(task)))}
        LabeledContent("Assigned to",value:store.assigneeName(task))
        ForEach(Array(task["reminder_specs"].list.enumerated()),id:\.offset) {_,value in
            if let spec=ReminderSpec(row:value) {LabeledContent(spec.enabled ? "Reminder":"Reminder (off)",value:spec.label)}
            else {Text("Saved reminder choice").foregroundStyle(.secondary)}
        }
        if !task["reminders"].list.isEmpty {LabeledContent("Other reminder choices",value:task["reminders"].list.map(\.text).joined(separator:", "))}
    }
    private func preview() async {
        busy=true;message=nil;defer{busy=false}
        let value=command ?? TeamCompletionDraft.CopyCommand(assignments:assignments,reminders:reminders)
        command=value
        do {
            let result=try await store.reviewSavedTeamDraft(draft,command:value)
            if result.cancelled {resetCancelled()} else {review=result}
        }
        catch {
            review=nil
            if let vault=store.teamDraftVault,let latest=try? vault.load(draft.id),let saved=latest.copyAttempt {
                command=saved;assignments=saved.assignments;reminders=saved.reminders;requestSaved=true
            }
            message=SyncStatus.failureMessage(error)
        }
    }
    private func create(_ expected:TeamCompletionDraft.CopyReview) async {
        busy=true;message=nil;defer{busy=false}
        do {
            let result=try await store.createSavedTeamDraftCopy(draft,review:expected)
            if result.cancelled {resetCancelled()}
            else {review=result;requestSaved=true;finished=result.task != nil
                if result.task == nil {message="The original copy is no longer available. Your draft remains saved."}}

        } catch {
            // Persistence may have succeeded before a network failure. Reload
            // its exact request before allowing another attempt or choice.
            if let vault=store.teamDraftVault,let latest=try? vault.load(draft.id),let saved=latest.copyAttempt {
                command=saved;assignments=saved.assignments;reminders=saved.reminders;requestSaved=true
            }
            review=nil;message=SyncStatus.failureMessage(error)
        }
    }
    private func resetCancelled() {
        review=nil;command=nil;requestSaved=false;finished=false
        message="Saved copy request cancelled. Review your new choices before creating a task copy."
    }
    private func changeChoices() async {
        guard let command else {return}
        busy=true;message=nil;defer{busy=false}
        do {
            let result=try await store.cancelSavedTeamDraftCopy(draft,command:command)
            if result.cancelled {resetCancelled()}
            else {review=result;requestSaved=true;finished=result.task != nil;message="The copy was already created. Your original draft is kept."}
        } catch {message=SyncStatus.failureMessage(error)}
    }

}

private struct TeamCompletionBatchReviewContent: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let review: TeamTaskBatch.Review
    @State private var checking = false
    @State private var message: String?
    private var current: Bool { store.currentTeamCompletionBatchReview(review) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Your work is saved", systemImage: "checkmark.icloud").font(.headline).foregroundStyle(Color.taskfold)
                    Text(review.isCancelled ? "This selection was cancelled. Keep the synced tasks to continue." : review.isRecorded ? "This selection reached the server. Review its result before continuing sync." : "No synced result is available yet. Retrying keeps the changes and completion time you chose.").foregroundStyle(.secondary)
                }
                if current {
                    Section("Saved selection") {
                        ForEach(review.members, id: \.mutation.id) { member in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(member.mutation.teamCompletion!.source.title).font(.headline)
                                Text(member.mutation.teamCompletion!.operation == .complete ? "Complete task" : "Undo completion").font(.caption).foregroundStyle(.secondary)
                                if let task = member.task {
                                    Label(task.completed ? "Synced: completed" : "Synced: open", systemImage: task.completed ? "checkmark.circle" : "circle")
                                    if task.title != member.mutation.teamCompletion!.source.title { Text(task.title).foregroundStyle(.secondary) }
                                } else { Text("This task is no longer available under its saved identity.").foregroundStyle(.secondary) }
                                if let next = member.successor { Text("Next occurrence: \(next.title)").font(.caption).foregroundStyle(.secondary) }
                            }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
                        }
                    }
                    Section {
                        Text("The whole selection is reviewed together. Later edits stay saved. Changes that depend on this selection need their own review before you can keep the synced tasks.").font(.footnote).foregroundStyle(.secondary)
                        if !review.isRecorded { Text("Keep synced tasks saves a recovery copy and sets aside this device’s completion changes. If they have already synced, you’ll see the result before continuing.").font(.footnote).foregroundStyle(.secondary) }
                    }
                } else { Section { Label("Review paused", systemImage: "lock.shield"); Text("Your workspace or project access changed. Reopen the current review to continue.").foregroundStyle(.secondary) } }
                if let message { Section { Text(message).foregroundStyle(.red) }.accessibilityIdentifier("teamBatchRecoveryError") }
                Section {
                    if !review.isCancelled {
                        Button(review.isRecorded ? "Continue sync" : "Retry saved selection") { perform { await store.continueTeamCompletionBatchReview(review) } }
                            .buttonStyle(.borderedProminent).disabled(!current || checking).accessibilityIdentifier("continueTeamBatchRecovery")
                    }
                    if !review.isRecorded {
                        Button("Keep synced tasks") { perform { await store.cancelTeamCompletionBatchReview(review) } }
                            .disabled(!current || checking).accessibilityIdentifier("cancelTeamBatchRecovery")
                    }
                    Button("Check again") { perform(dismissOnSuccess: false) { await store.refreshTeamCompletionBatchReview(review) } }
                        .disabled(!current || checking).accessibilityIdentifier("refreshTeamBatchRecovery")
                    Button("Later") { dismiss() }.disabled(checking).accessibilityIdentifier("laterTeamBatchRecovery")
                }
                if checking { Section { ProgressView("Checking saved selection…") } }
            }.formStyle(.grouped).accessibilityIdentifier("teamBatchRecoveryForm")
            .navigationTitle("Review task selection")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .interactiveDismissDisabled(checking)
        }
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 620, minHeight: 500, idealHeight: 680)
        #endif
        .onChange(of: store.workspaceGeneration) { _, _ in dismiss() }
    }
    private func perform(dismissOnSuccess: Bool = true, _ action: @escaping () async -> Bool) {
        guard !checking, current else { return }; checking = true; message = nil
        Task {
            let saved = await action(); checking = false
            if saved, dismissOnSuccess { dismiss() }
            else if !saved { message = store.error ?? "The selection remains saved. Check the current result before continuing."; store.error = nil }
        }
    }
}
