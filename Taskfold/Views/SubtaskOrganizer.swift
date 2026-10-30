import SwiftUI

/// One opening carries its local binding and frozen admission together. The
/// editor owns presentation so removing its editable form cannot discard a sheet.
struct SubtaskOrganizerRequest: Identifiable {
    let id = UUID()
    let children: Binding<JSON>
    let taskID: String
    let baseDepth: Int
    let projectID: String
    let admission: TaskEditorAdmission
    let saveAndOpen: ((JSON, [String]) -> Bool)?
}

struct SubtaskOrganizerPresentation: View {
    let request: SubtaskOrganizerRequest
    var body: some View {
        SubtaskOrganizer(children: request.children, taskID: request.taskID,
                         baseDepth: request.baseDepth, projectID: request.projectID,
                         admission: request.admission, saveAndOpen: request.saveAndOpen)
    }
}

struct SubtaskOrganizerButton: View {
    @Environment(Store.self) private var store
    @State private var opening: SubtaskOrganizerRequest?
    @Binding var children: JSON
    let taskID: String
    var baseDepth = 0
    var projectID = ""
    var sourceRecord: Record? = nil
    var sourceRootID: String? = nil
    var custodyRoot: Record? = nil
    var admittedWorkspace: WorkspaceBinding? = nil
    var teamDraft: TeamTaskEditorDraft? = nil
    var present: ((SubtaskOrganizerRequest) -> Void)? = nil
    var saveAndOpen: ((JSON, [String]) -> Bool)? = nil
    var body: some View {
        Group {
        Button("Organize subtasks", systemImage: "list.bullet.indent") {
            let workspace=admittedWorkspace ?? WorkspaceBinding(account:store.userID,generation:store.workspaceGeneration)
            let root=custodyRoot ?? store.record("tasks",id:sourceRootID ?? SubtaskTree.referencePath(taskID)?.first ?? taskID)
            var record=sourceRecord ?? root.flatMap{TaskEditorSourceContext.projection($0,reference:taskID)} ?? Record(["id":.string(taskID),"title":.string("Recovered checklist"),"project_id":.string(projectID)])
            record["subtasks"] = children
            let admission = TaskEditorAdmission(workspace:workspace,record:record,root:root,kind:.nested,teamDraft:teamDraft)
            let request = SubtaskOrganizerRequest(children: $children, taskID: taskID, baseDepth: baseDepth, projectID: projectID, admission: admission, saveAndOpen: teamDraft == nil ? saveAndOpen : nil)
            if let present { present(request) } else { opening = request }
        }
            .accessibilityIdentifier("organizeSubtasks")
            .sheet(item: $opening) { SubtaskOrganizerPresentation(request: $0) }
        ChildTaskFieldEditorLink(rootID: sourceRootID ?? custodyRoot?.id ?? SubtaskTree.referencePath(taskID)?.first ?? taskID)
        ChildTaskStructureLink(rootID: sourceRootID ?? custodyRoot?.id ?? SubtaskTree.referencePath(taskID)?.first ?? taskID)
        }
    }
}

private struct SubtaskOrganizer: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var children: JSON
    let taskID: String
    let baseDepth: Int
    let projectID: String
    let admission: TaskEditorAdmission
    private var sourceWorkspace: WorkspaceBinding {admission.workspace}
    let saveAndOpen: ((JSON, [String]) -> Bool)?
    private struct ChildRequest: Identifiable { let record: Record; let depth: Int; var id: String { record.id } }
    @State private var recoverySession: TaskEditorSession?
    @State private var sourceRecord: Record?
    @State private var sourceContext: TaskEditorSourceContext?
    @State private var accessStopped = false
    @State private var editingChild: ChildRequest?
    @State private var source: JSON
    @State private var originalTaskID: String
    @State private var draft: JSON
    @State private var binding: WorkspaceBinding?
    @State private var preparing = true
    @State private var prepared = false
    @State private var loadError: String?
    @State private var recovery: ChecklistRecovery.Review?
    @State private var recoveredCount: Int?
    @State private var originalText: String?
    @State private var showingOriginal = false
    @State private var message: String?
    @State private var newTitle = ""
    @State private var addingTo: String?
    @State private var addingChild = false
    @State private var removing: SubtaskTree.Item?
    @State private var childTitle = ""

    init(children: Binding<JSON>, taskID: String, baseDepth: Int, projectID: String, admission:TaskEditorAdmission, saveAndOpen: ((JSON, [String]) -> Bool)?) {
        _children = children; self.taskID = taskID; self.baseDepth = baseDepth; self.projectID = projectID; self.admission=admission;self.saveAndOpen = saveAndOpen
        _source = State(initialValue: admission.source.record["subtasks"])
        _originalTaskID = State(initialValue: taskID)
        _draft = State(initialValue: .array([]))
    }
    private var items: [SubtaskTree.Item] { SubtaskTree.outline(draft) }
    private var available: Bool {
        guard !accessStopped,admission.matches(account:store.userID,generation:store.workspaceGeneration,currentRoot:store.record("tasks",id:admission.rootID)),store.editorMayWrite(source:admission.source.root ?? admission.source.record,proposed:admission.source.record,teamDraft:admission.teamDraft) else {return false}
        guard let binding,let sourceRecord else {return true}
        guard binding.matches(account:store.userID,generation:store.workspaceGeneration),let sourceContext,
              store.editorMayWrite(source:sourceContext.root ?? sourceRecord,proposed:sourceRecord,teamDraft:admission.teamDraft),
              sourceContext.matches(sourceContext.root.flatMap{store.record("tasks",id:$0.id)}) else {return false}
        return true
    }
    private func checkpoint() {
        guard let session=recoverySession,draft != source || !newTitle.isEmpty || !childTitle.isEmpty else {return}
        var task=session.original;task["subtasks"] = draft
        session.capture(task,extras:["source_identity":sourceContext?.identity ?? .null,"organizer_source":source,"new_subtask":.string(newTitle),"new_child":.string(childTitle),"adding_to":addingTo.map(JSON.string) ?? .null])
    }
    var body: some View {
        Group {
            if available {editingBody}
            else {
                ScrollView {VStack(alignment:.leading,spacing:16) {
                    Label("Editing paused",systemImage:"lock.shield").font(.title2)
                    Text("This task or workspace changed. Reopen its current checklist before editing again.")
                    if let session = recoverySession, session.latest != nil {
                        Text(session.preserved ? "Your checklist edit is saved privately with its original workspace. Open that workspace’s Backups & restore → Unsent task edits." : "Preserving your checklist edit…")
                            .accessibilityIdentifier("organizerRecoveryStatus")
                    }
                    if let session=recoverySession,let failure=session.failure {Text(failure).foregroundStyle(.red);Button("Retry preserving edit") {_=session.flush()}}
                    Button("Close") {checkpoint();if recoverySession?.latest==nil || recoverySession?.flush()==true {dismiss()}}
                }.frame(maxWidth:.infinity,alignment:.leading).padding(24)}
            }
        }
        #if os(iOS)
        .sheet(item: $editingChild) { request in
            TaskEditor(task: SubtaskTree.detailDraft(request.record, project: projectID), embeddedSave: { edited in
                guard binding?.matches(account: store.userID, generation: store.workspaceGeneration) == true,
                  taskID == originalTaskID, let current = items.first(where: { $0.id == request.id })?.record else {
                throw SubtaskTree.Failure(message: "This task or workspace changed. Reopen its current details before saving.")
                }
                let saved = try SubtaskTree.detailChanges(original: request.record, edited: edited, current: current)
                draft = SubtaskTree.changing(draft, id: request.id, fields: saved.fields)
            }, embeddedDepth: request.depth)
        }
        #endif
        .onChange(of:draft) {_,_ in checkpoint()}
        .onChange(of:newTitle) {_,_ in checkpoint()}
        .onChange(of:childTitle) {_,_ in checkpoint()}
        .onChange(of:available) {_,value in if !value {checkpoint();accessStopped=true}}
        .onDisappear {checkpoint()}
    }
    private var editingBody: some View {
        NavigationStack {
            Form {
                if preparing {
                    Section { ProgressView("Reading checklist…").accessibilityIdentifier("preparingChecklist") }
                } else if let recovery {
                    ChecklistRecoveryReview(review: recovery, recover: applyRecovery, original: showOriginal)
                } else if let loadError {
                    Section {
                        Text(loadError).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("subtaskRecoveryRefusal")
                        Button("View original data", action: showOriginal).accessibilityIdentifier("viewOriginalChecklist")
                    }
                } else {
                    if let recoveredCount {
                        Section { Text("\(recoveredCount) subtasks recovered in this draft. Save when you’re ready.").font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("subtaskRecoveryDraftNotice") }
                    }
                    Section {
                        ForEach(items) { item in
                            HStack(alignment: .center, spacing: 8) {
                                if TaskKind.mayComplete(item.record) {
                                Button {
                                    draft = SubtaskTree.changing(draft, id: item.id, fields: ["completed": .bool(!item.record.completed)])
                                } label: {
                                    Image(systemName: item.record.completed ? "checkmark.circle.fill" : "circle")
                                        .frame(minWidth: 32, minHeight: 36).contentShape(Rectangle())
                                }.buttonStyle(.borderless)
                                .accessibilityLabel((item.record.completed ? "Reopen " : "Complete ") + item.record.title)
                                .accessibilityValue(item.record.completed ? "Completed" : "Not completed")
                                .accessibilityIdentifier("organizedCompletion-" + item.id)
                                } else {
                                    Image(systemName: TaskKind(item.record) == .heading ? "textformat" : "questionmark.square")
                                        .foregroundStyle(.secondary).frame(minWidth: 32, minHeight: 36)
                                        .accessibilityLabel(TaskKind(item.record) == .heading ? "Heading, stays open" : "Task type unavailable")
                                }
                                TextField("Subtask", text: Binding(get: {
                                    SubtaskTree.outline(draft).first { $0.id == item.id }?.record.title ?? ""
                                }, set: { title in draft = SubtaskTree.changing(draft, id: item.id, fields: ["title": .string(title)]) }), axis: .vertical)
                                    .labelsHidden().textFieldStyle(.plain).multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityLabel("Subtask name")
                                    .accessibilityHint("Level \(baseDepth + item.depth + 1). Use the actions menu to move or nest this subtask.")
                                    .accessibilityIdentifier("organizedTitle-" + item.id)
                                .fontWeight(TaskKind(item.record) == .heading ? .semibold : .regular)
                                Menu {
                                    #if os(iOS)
                                    Button("Edit details", systemImage: "slider.horizontal.3") { editingChild = ChildRequest(record: item.record, depth: baseDepth + item.depth + 1) }
                                    #else
                                    if saveAndOpen != nil {
                                        Button("Save and open details", systemImage: "sidebar.trailing") { commit(opening: item.id) }
                                    }
                                    #endif
                                    if store.canAuthorTaskHeadings(teamDraft: admission.teamDraft), TaskKind(item.record) != .unsupported {
                                        Button(TaskKind(item.record) == .heading ? "Make task" : "Make heading", systemImage: "textformat") {
                                            guard available, store.canAuthorTaskHeadings(teamDraft: admission.teamDraft), let current = items.first(where: { $0.id == item.id })?.record, current == item.record else { return }
                                            guard !TeamTaskTypes.needsSavedReopen(current, originalTree: admission.teamDraft?.source["subtasks"]) else {
                                                message = "Save the reopened subtask and its parent task first. Then reopen Organize subtasks to change its type."
                                                return
                                            }
                                            do {
                                                let edited = try TaskKind.setting(current, heading: TaskKind(current) != .heading)
                                                draft = SubtaskTree.changing(draft, id: item.id, fields: edited.fields.filter { current.fields[$0.key] != $0.value })
                                            } catch { message = error.localizedDescription }
                                        }.disabled(item.record.completed).accessibilityIdentifier("organizedType-" + item.id)
                                    }
                                    Button("Add child subtask", systemImage: "plus") { addingTo = item.id; childTitle = ""; addingChild = true }
                                        .disabled(baseDepth + item.depth + 1 >= SubtaskTree.maximumDepth)
                                    Button("Move up", systemImage: "arrow.up") { move(item, .up) }.disabled(!canMove(item, .up))
                                    Button("Move down", systemImage: "arrow.down") { move(item, .down) }.disabled(!canMove(item, .down))
                                    Button("Indent", systemImage: "increase.indent") { move(item, .indent) }.disabled(!canMove(item, .indent))
                                    Button("Outdent", systemImage: "decrease.indent") { move(item, .outdent) }.disabled(item.parent == nil)
                                    Divider()
                                    Button("Delete subtask", role: .destructive) { removing = item }
                                } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 32, minHeight: 36).contentShape(Rectangle()) }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                                .accessibilityLabel("Actions for " + item.record.title)
                                .accessibilityIdentifier("organizedActions-" + item.id)
                            }.padding(.leading, CGFloat(min(item.depth, 4)) * 12)
                        }
                        HStack {
                            TextField("Add a subtask", text: $newTitle, axis: .vertical)
                                .accessibilityIdentifier("organizedNewTitle")
                            Button("Add", systemImage: "plus") { add(title: newTitle, parent: nil); newTitle = "" }
                                .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || baseDepth >= SubtaskTree.maximumDepth)
                                .accessibilityIdentifier("organizedAdd")
                        }
                    } footer: { Text(helpText) }
                }
                if let message { Section { Text(message).foregroundStyle(.red).accessibilityIdentifier("subtaskOrganizerError") } }
            }.formStyle(.grouped).accessibilityIdentifier("subtaskOrganizerForm")
            .navigationTitle("Organize subtasks")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") {if recoverySession?.finish() != false {dismiss()}}.keyboardShortcut(.cancelAction).accessibilityIdentifier("cancelSubtaskOrganizer") }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).keyboardShortcut("s", modifiers: .command).disabled(preparing || recovery != nil || loadError != nil || items.contains { $0.record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).accessibilityIdentifier("saveSubtaskOrganizer") }
            }
            .sheet(isPresented: $showingOriginal) { if let originalText { OriginalChecklistView(text: originalText) } }

            .alert("Add child subtask", isPresented: $addingChild) {
                TextField("Subtask name", text: $childTitle)
                Button("Cancel", role: .cancel) { addingTo = nil }
                Button("Add") { add(title: childTitle, parent: addingTo); addingTo = nil }
                    .disabled(childTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .confirmationDialog("Delete this subtask and its children?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Delete subtask", role: .destructive) { if let removing { draft = SubtaskTree.removing(draft, id: removing.id) }; removing = nil }
                Button("Cancel", role: .cancel) { removing = nil }
            }
        }
        #if os(macOS)
        .frame(minWidth: 580, idealWidth: 660, minHeight: 440, idealHeight: 600)
        #endif
        .task { await prepare() }
    }
    @MainActor private func prepare() async {
        guard !prepared else { return }; prepared = true
        let workspace=sourceWorkspace
        guard workspace.matches(account:store.userID,generation:store.workspaceGeneration) else {accessStopped=true;preparing=false;return}
        binding = workspace
        var original=admission.source.record;original["subtasks"] = source
        sourceRecord=original;sourceContext=admission.source
        do {recoverySession=try store.beginEditorSession(original)} catch {loadError="Your checklist cannot be protected. Keep this editor open and retry.";preparing=false;return}
        let input = source, depth = baseDepth
        let job = Task.detached(priority: .userInitiated) { () -> Result<ChecklistRecovery.Review, SubtaskTree.Failure> in
            do { return .success(try ChecklistRecovery.review(input, baseDepth: depth)) }
            catch { return .failure(SubtaskTree.Failure(message: error.localizedDescription)) }
        }
        let result = await withTaskCancellationHandler(operation: { await job.value }, onCancel: { job.cancel() })
        guard !Task.isCancelled else { return }
        preparing = false
        guard workspace.matches(account: store.userID, generation: store.workspaceGeneration), taskID == originalTaskID, children == input else {
            loadError = "The task or workspace changed. Cancel and reopen this checklist."; return
        }
        switch result {
        case .success(let review): recovery = review.changes.isEmpty ? nil : review; draft = review.changes.isEmpty ? review.proposed : .array([])
        case .failure(let error): loadError = error.localizedDescription
        }
    }
    private func showOriginal() {
        do { originalText = String(decoding: try ChecklistRecovery.originalData(source), as: UTF8.self); showingOriginal = true }
        catch { message = error.localizedDescription }
    }
    private func applyRecovery() {
        guard let recovery, binding?.matches(account: store.userID, generation: store.workspaceGeneration) == true,
              taskID == originalTaskID else { message = "The task or workspace changed. Cancel and reopen this checklist."; return }
        do {
            draft = try recovery.applying(to: children)
            recoveredCount = recovery.changes.count
            self.recovery = nil; loadError = nil; message = nil
        } catch { message = error.localizedDescription }
    }
    private var helpText: String {
        let actions = "Move a subtask with all of its children. Indent places it inside the subtask above; Outdent places it after its parent. "
        #if os(macOS)
        return actions + "Changes apply when you save."
        #else
        return actions + "Save returns to the task editor. Save the task to keep your changes."
        #endif
    }
    private func canMove(_ item: SubtaskTree.Item, _ direction: SubtaskTree.Move) -> Bool {
        (try? SubtaskTree.moving(draft, id: item.id, direction: direction, baseDepth: baseDepth)) != nil
    }
    private func move(_ item: SubtaskTree.Item, _ direction: SubtaskTree.Move) {
        do { draft = try SubtaskTree.moving(draft, id: item.id, direction: direction, baseDepth: baseDepth); message = nil }
        catch { message = error.localizedDescription }
    }
    private func add(title: String, parent: String?) {
        do { draft = try SubtaskTree.adding(draft, title: title, parent: parent, baseDepth: baseDepth); message = nil }
        catch { message = error.localizedDescription }
    }
    private func save() { commit(opening: nil) }
    private func commit(opening childID: String?) {
        guard available,!preparing, recovery == nil, loadError == nil, binding?.matches(account: store.userID, generation: store.workspaceGeneration) == true,
              taskID == originalTaskID, children == source else {
            message = "The task or workspace changed. Cancel and reopen the organizer to keep the latest work."; return
        }
        do {
            let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let saved = title.isEmpty ? draft : try SubtaskTree.adding(draft, title: title, baseDepth: baseDepth)
            guard !SubtaskTree.outline(saved).contains(where: { $0.record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw SubtaskTree.Failure(message: "Give each subtask a name before saving.")
            }
            if let childID, let saveAndOpen, let path = SubtaskTree.path(saved, id: childID) {
                guard saveAndOpen(saved, path) else { message = store.error ?? "The task could not be saved. Your checklist draft is still here."; return }
            } else { children = saved }
            _=recoverySession?.finish();dismiss()
        } catch { message = error.localizedDescription }
    }
}

// MARK: Checklist recovery review
/// Pure review content shared by the native organizer and component layout checks.
struct ChecklistRecoveryReview: View {
    let review: ChecklistRecovery.Review
    let recover: () -> Void
    let original: () -> Void
    var body: some View {
        Section {
            Label("Make this checklist editable", systemImage: "list.bullet.clipboard").font(.headline)
            Text("Recovery keeps the checklist’s text, details, order and completion. It gives affected subtasks separate references so changes reach the right item.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("\(review.changes.count) of \(review.itemCount) subtasks need recovery.").font(.subheadline.weight(.medium))
                .accessibilityIdentifier("subtaskRecoverySummary")
        } footer: {
            Text("Text-only checklist items become open subtasks. Existing shortcuts to recovered items need to be opened again. No task is saved at this step.")
        }
        Section("Review affected subtasks") {
            ForEach(review.changes) { change in
                VStack(alignment: .leading, spacing: 4) {
                    Text(change.title.isEmpty ? "Untitled subtask" : change.title).fixedSize(horizontal: false, vertical: true)
                    Text(reason(change.reason)).font(.caption).foregroundStyle(.secondary)
                }.padding(.leading, CGFloat(min(change.depth, 4)) * 12)
                .accessibilityElement(children: .combine)
            }
        }
        Section {
            Button("Recover in this draft", action: recover).frame(minHeight: 44).accessibilityIdentifier("applySubtaskRecovery")
            Button("View original data", action: original).frame(minHeight: 44).accessibilityIdentifier("viewOriginalChecklist")
        }
    }
    private func reason(_ reason: ChecklistRecovery.Reason) -> String {
        switch reason {
        case .missing: "Missing reference"
        case .duplicate: "Shared reference — each affected item gets its own"
        case .invalid: "Unreadable reference"
        case .textOnly: "Text-only checklist item"
        }
    }
}

private struct OriginalChecklistView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(verbatim: text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding().accessibilityIdentifier("originalChecklistData")
            }.navigationTitle("Original checklist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("closeOriginalChecklist") }
                ToolbarItem(placement: .primaryAction) { ShareLink(item: text) { Label("Share original", systemImage: "square.and.arrow.up") } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 440)
        #endif
    }
}
