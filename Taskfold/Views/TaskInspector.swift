import SwiftUI
import UniformTypeIdentifiers
import QuickLook
import AppKit

/// The trailing inspector: edits the selected task in place and saves as you go. Only fields changed here are
/// merged, so concurrent sync changes to untouched fields survive, exactly like the iOS editor's save.
struct TaskInspector: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    var body: some View {
        Group {
            if let task = workspace.primaryTask {
                TaskInspectorForm(taskID: task.id).id(task.id).transition(.panelReveal(distance: 24))
            } else if workspace.selection.count > 1 {
                MultiSelectionInspector(count: workspace.selection.count)
            } else {
                ContentUnavailableView {
                    Label("No Task Selected", systemImage: "sidebar.trailing")
                } description: {
                    Text("Select a task to see and edit its details here.")
                }
            }
        }
        .animation(Transitions.Ease.smoothOut(Transitions.Duration.slow), value: workspace.primaryTask?.id)
        .accessibilityIdentifier("inspector")
    }
}

struct MultiSelectionInspector: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    let count: Int
    var body: some View {
        Form {
            Section {
                Text("\(count) tasks selected").font(.headline)
                Text("Changes apply to every selected task as one undoable step.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Actions") {
                Button("Complete", systemImage: "checkmark.circle") { workspace.toggle(workspace.selection) }.disabled(!workspace.selection.allSatisfy { workspace.taskRecord($0).map(TaskKind.mayComplete) == true })
                Menu("Reschedule") {
                    Button("Today") { workspace.reschedule(workspace.selection, to: Dates.day(Date()), label: "today") }
                    Button("Tomorrow") { workspace.reschedule(workspace.selection, to: Dates.day(Calendar.current.date(byAdding: .day, value: 1, to: Date())!), label: "tomorrow") }
                    Button("Next Week") { if let day = store.datePhraseDay("next week") { workspace.reschedule(workspace.selection, to: Dates.day(day), label: "next week") } }.disabled(store.datePhrasePreferences == nil)
                    Divider()
                    Button("Remove Date") { workspace.reschedule(workspace.selection, to: nil, label: "") }
                }
                Button("Edit Deadlines…", systemImage: "flag.checkered") { workspace.editDeadlines(workspace.selection) }.accessibilityIdentifier("bulkDeadlines")
                if store.hasSharedTaskSelection(workspace.selection) { Button("Assign Shared Tasks…", systemImage: "person.crop.circle.badge.checkmark") { workspace.assignSharedSelection(workspace.selection) }.accessibilityIdentifier("bulkAssignShared") }
                Button("Edit Estimates…", systemImage: "hourglass") { workspace.editEstimates(workspace.selection) }.accessibilityIdentifier("bulkEstimates")
                Menu("Move to") {
                    Button("Inbox") { workspace.move(workspace.selection, toProject: "") }
                    ForEach(store.projects) { project in Button(project.name) { workspace.move(workspace.selection, toProject: project.id) } }
                }
                Menu("Priority") { ForEach(1...4, id: \.self) { n in Button(n == 4 ? "None" : "Priority \(n)") { workspace.setPriority(workspace.selection, n) } } }
                Button("Duplicate", systemImage: "doc.on.doc") { workspace.duplicate(workspace.selection) }
                Button("Delete", systemImage: "trash", role: .destructive) { workspace.delete(workspace.selection) }
            }
        }.formStyle(.grouped)
    }
}

struct TaskInspectorForm: View {
    @State private var showingReminders = false
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    let taskID: String
    var admission: TaskEditorAdmission? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var creationFinished = false
    @State private var discardCreation = false
    @State private var creationFailure: String?
    private var isCreating: Bool { admission?.teamDraft?.kind == .creation }
    @State private var teamDraft: TeamTaskEditorDraft?
    @State private var teamDraftCaptured = false
    private var isTeamTask: Bool { teamDraft != nil }
    private var quickExclusions: Set<String> { isTeamTask ? SubtaskTree.childQuickEntryExclusions.union(["assigned_to", "labels"]) : Workspace.subtaskPath(taskID) != nil ? SubtaskTree.childQuickEntryExclusions : [] }
    @State private var teamMove: TeamTaskMoveRequest?
    @State private var teamDeletion: TeamTaskDeletionRequest?
    @State private var teamRepeat: TeamTaskRecurrenceRequest?
    @State private var teamReminders: TeamTaskRemindersRequest?
    @State private var teamLabels: TeamTaskLabelsRequest?
    @State private var teamAssignee: TeamTaskAssigneeRequest?
    @State private var selectedTeamName: String?
    @State private var selectedTeamID: String?
    @State private var subtaskOrganizing: SubtaskOrganizerRequest?
    @State private var recoverySession: TaskEditorSession?
    @State private var sourceContext: TaskEditorSourceContext?
    @State private var sourceRoot: Record?
    @State private var accessStopped = false
    @State private var sessionFailure: String?
    @State private var draft = Record()
    @State private var notePin: Bool?
    @State private var original = Record()
    @State private var editingGeneration: JSON = .null
    @State private var titleParsingBaseline = ""
    @State private var workspaceBinding: WorkspaceBinding?
    @State private var subtask = ""
    @State private var comment = ""
    @State private var conversation: ConversationRequest?
    @State private var noteFormatting: NoteFormatRequest?
    @State private var headingConversion: TodoistHeadingConversion?
    @State private var pastedImageName: String?
    @State private var importing = false
    @State private var preview: URL?
    @State private var confirmDelete = false
    @State private var saveTask: Task<Void, Never>?
    @State private var declined = Set<String>()
    @State private var titleSelection: TextSelection?
    @State private var referenceChoices: [String: String] = [:]
    @FocusState private var titleFocused: Bool
    @State private var titleChipFocused = false
    /// Parsing runs while the title differs from the saved one; Return (or leaving the field) applies it.
    private var suggestions: QuickEntry? {
        guard draft.title != titleParsingBaseline else { return nil }
        let parsed = QuickEntry(draft.title, disabled: declined.union(quickExclusions),
            context: workspace.quickEntryContext(project: workspace.assignmentProject(draft, contextID: taskID)).choosingReferences(referenceChoices), task: draft)
        return parsed.tokens.isEmpty && parsed.warnings.isEmpty ? nil : parsed
    }

    private var current: Record? { workspace.taskRecord(taskID) }
    private var currentGeneration: JSON {
        if isCreating { return admission!.source.record["task_generation"] }
        let root = Workspace.subtaskPath(taskID)?.first ?? taskID
        return store.record("tasks", id: root)?["task_generation"] ?? .null
    }
    private func text(_ key: String) -> Binding<String> {
        Binding(get: { draft.string(key) }, set: { draft[key] = $0.isEmpty && ["project_id", "section_id", "due_time", "time_zone"].contains(key) ? .null : .string($0) })
    }
    private var editorAvailable: Bool {
        guard !accessStopped else {return false}
        if let admission,(!admission.matches(account:store.userID,generation:store.workspaceGeneration,currentRoot:store.record("tasks",id:admission.rootID)) || !store.editorMayWrite(source:admission.source.root ?? admission.source.record,proposed:admission.source.record,teamDraft:teamDraft ?? admission.teamDraft)) {return false}
        guard let workspaceBinding else {return true}
        if isCreating {
            return workspaceBinding.matches(account: store.userID, generation: store.workspaceGeneration) && store.editorMayWrite(source: admission!.source.record, proposed: draft, teamDraft: teamDraft ?? admission?.teamDraft)
        }
        guard workspaceBinding.matches(account:store.userID,generation:store.workspaceGeneration),let sourceRoot,
              let live=store.record("tasks",id:sourceRoot.id),live["task_generation"]==sourceRoot["task_generation"],live["project_id"]==sourceRoot["project_id"],current != nil,sourceContext?.matches(live)==true,
              store.editorMayWrite(source:sourceRoot,proposed:draft,teamDraft:teamDraft) else {return false}
        return true
    }
    private var recoveryExtras: [String:JSON] {
        ["new_subtask":.string(subtask),"unsubmitted_comment":.string(comment),"pin":notePin.map(JSON.bool) ?? .null,"declined":.array(declined.sorted().map(JSON.string)),"reference_choices":.object(referenceChoices.mapValues(JSON.string)),"source_identity":sourceContext?.identity ?? .null]
    }
    private func checkpoint() {
        guard !creationFinished, !original.id.isEmpty else {return}
        guard draft != original || (isCreating && !draft.title.isEmpty) || notePin != nil || !subtask.isEmpty || !comment.isEmpty else {_=recoverySession?.finish();return}
        if recoverySession==nil || recoverySession?.closed==true {
            guard workspaceBinding?.matches(account:store.userID,generation:store.workspaceGeneration)==true else {return}
            do {recoverySession=try store.beginEditorSession(original)} catch {sessionFailure="Your draft cannot be protected yet. Keep this inspector open and retry.";return}
        }
        recoverySession?.capture(draft,extras:recoveryExtras)
    }
    private func stopEditing() {checkpoint();accessStopped=true;saveTask?.cancel();titleFocused=false}
    var body: some View {
        Group {
            if editorAvailable {editingBody}
            else {
                ScrollView {VStack(alignment:.leading,spacing:16) {
                    Label("Editing paused",systemImage:"lock.shield").font(.title2.weight(.semibold))
                    Text(isCreating ? "This project or workspace changed. Your task has not been added." : "This task or workspace changed. Reopen its current details before editing again.")
                    if let session=recoverySession,session.latest != nil {
                        Text(session.preserved ? "Your unsent edit is saved privately with its original workspace. Open that workspace’s Backups & restore → Unsent task edits.":"Preserving your unsent edit…").accessibilityIdentifier("editorRecoveryStatus")
                        if let failure=session.failure {Text(failure).foregroundStyle(.red);Button("Retry preserving edit") {_=session.flush()}}
                    }
                    if let sessionFailure {Text(sessionFailure).foregroundStyle(.red)}
                }.frame(maxWidth:.infinity,alignment:.leading).padding(24)}.accessibilityIdentifier("editorAccessStopped")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isCreating {
                HStack {
                    Button("Cancel") {
                        if !draft.title.isEmpty || draft != original { discardCreation = true }
                        else { creationFinished = true; _ = recoverySession?.finish(); dismiss() }
                    }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Add Task", action: createTeamTask).buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction).disabled(!editorAvailable || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("createSharedTask")
                }.padding().background(.bar)
            }
        }
        .alert("Could not add task", isPresented: Binding(get: { creationFailure != nil }, set: { if !$0 { creationFailure = nil } })) {
            Button("OK") { creationFailure = nil }
        } message: { Text(creationFailure ?? "") }
        .confirmationDialog("Discard this task draft?", isPresented: $discardCreation) {
            Button("Discard draft", role: .destructive) { creationFinished = true; _ = recoverySession?.finish(); dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .interactiveDismissDisabled(isCreating && !creationFinished)
        .sheet(item: $teamMove) { TeamTaskMoveView(request: $0) }
        .sheet(item: $teamDeletion) { TeamTaskDeletionReview(request: $0) }
        .sheet(item: $teamRepeat) { TeamTaskRecurrenceEditor(request: $0) }
        .sheet(item: $teamReminders) { TeamTaskRemindersEditor(request: $0) }
        .sheet(item: $teamLabels) { TeamTaskLabelsEditor(request: $0) }
        .sheet(item: $teamAssignee) { TeamTaskAssigneePicker(request: $0) }
        .sheet(item: $headingConversion) { request in
            TodoistHeadingConversionReview(request: request, available: { editorAvailable && store.canAuthorTaskHeadings(teamDraft: teamDraft) && draft == request.captured }, apply: { remove in
                guard editorAvailable else { throw AppFailure(message: "The workspace changed. Reopen the task.") }
                let edited = try request.applying(to: draft, removingMarker: remove, authoringEnabled: store.canAuthorTaskHeadings(teamDraft: teamDraft))
                saveTask?.cancel(); titleParsingBaseline = edited.title; draft = edited
            })
        }
        .sheet(item: $subtaskOrganizing) { SubtaskOrganizerPresentation(request: $0) }
        .onChange(of:editorAvailable) {_,available in if !available {stopEditing()}}
        .onChange(of:recoveryExtras) {_,_ in checkpoint()}
        .onDisappear {checkpoint()}
    }
    private var editingBody: some View {
        Form {
            Section {
                TextField("Title", text: text("title"), selection: $titleSelection, prompt: Text("What needs doing?"), axis: .vertical)
                    .labelsHidden().multilineTextAlignment(.leading)
                    .font(.title3.weight(.semibold)).textFieldStyle(.plain).lineLimit(1...4)
                    .focused($titleFocused)
                    .onChange(of: titleFocused) { _, focused in if !focused { finishTitleWhenUnfocused() } }
                    .accessibilityIdentifier("taskTitle")
                    .referenceCompletions(text: text("title"), selection: $titleSelection, choices: $referenceChoices, declined: $declined, context: workspace.quickEntryContext(project: workspace.assignmentProject(draft, contextID: taskID)), focused: titleFocused, task: draft, excluded: quickExclusions, onChoose: { applyReferenceChoices(); titleFocused = true }, submit: { applySuggestions(); saveNow() }, submitsFromKeyboard: true)
                if store.canAuthorTaskHeadings(teamDraft: teamDraft) {
                    Picker("Task type", selection: Binding(get: { TaskKind(draft) == .heading }, set: { heading in
                        guard editorAvailable else { return }
                        do { draft = try TaskKind.setting(draft, heading: heading) }
                        catch { store.error = error.localizedDescription }
                    })) {
                        Text("Task").tag(false)
                        Text("Heading").tag(true)
                    }.disabled(TaskKind(draft) == .unsupported).accessibilityIdentifier("taskKindPicker")
                    if draft.completed { Text("Reopen this task to turn it into a heading.").font(.caption).foregroundStyle(.secondary) }
                    if let request = TodoistHeadingConversion(draft) {
                        Button("Review imported heading", systemImage: "textformat") { titleFocused = false; headingConversion = request }.accessibilityIdentifier("reviewImportedHeading")
                    }
                }
                if !TaskKind.mayComplete(draft) {
                    Label(TaskKind(draft) == .heading ? "Heading · stays open" : "Task type unavailable", systemImage: TaskKind(draft) == .heading ? "textformat" : "questionmark.square")
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("taskKindStatus")
                }
                Text(isCreating ? "Added only when you choose Add Task" : "Changes save automatically")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("inspectorAutosaveHint")
                if let suggestions {
                    VStack(alignment: .leading, spacing: 4) {
                        QuickEntryChips(tokens: suggestions.tokens, decline: { token in _ = declined.insert(token.group) }, returnFocus: resumeTitleFromChip, focusChanged: { titleChipFocused = $0 }).padding(.vertical, 2)
                        if !suggestions.tokens.isEmpty { Text("Return applies these · ✕ keeps the words in the title").font(.caption2).foregroundStyle(.tertiary) }
                        if suggestions.updates["reminder_specs"] != nil && !store.remindersEnabled {
                            Text("Reminders are off on this device. Enable delivery in Reminders below.").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("quickReminderDeliveryOff")
                        }
                        if let rule = suggestions.updates["recurrence_pattern"] {
                            Text("Repeat: " + Recurrence.summary(Record(rule.object))).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("quickRepeatSummary")
                        }
                        ForEach(suggestions.warnings, id: \.self) { warning in Text(warning).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("quickEntryWarning") }
                    }
                    .transition(.opacity)
                }
                TextEditor(text: text("description"))
                    .font(.body).foregroundStyle(.secondary).scrollContentBackground(.hidden)
                    .frame(minHeight: 52, maxHeight: 180)
                    .overlay(alignment: .topLeading) {
                        if draft.string("description").isEmpty {
                            Text("Notes").foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Notes").accessibilityIdentifier("taskDescription")
                Button("Format notes", systemImage: "textformat") {
                    guard let binding = workspaceBinding else { return }
                    noteFormatting = NoteFormatRequest(taskID: taskID, original: draft.string("description"), workspace: binding, generation: currentGeneration, storedText: current?.string("description"),source:draft,sourceRootID:sourceRoot?.id,admission:TaskEditorAdmission(workspace:binding,record:draft,root:sourceRoot,kind:.nested,teamDraft:teamDraft))
                }.disabled(current == nil && !isCreating).accessibilityIdentifier("openNoteFormatting")
                if !isTeamTask, store.record("tasks", id: taskID) != nil {
                    Toggle("Show notes in widgets", isOn: Binding(get: { notePin ?? store.isPinnedNote(taskID) }, set: { notePin = $0; saveNow() })).accessibilityIdentifier("pinTaskNotes")
                    Text("Pin only text you want visible on your desktop or Home Screen. Choose it in the Pinned note widget; hide its details for privacy.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if TaskKind.mayComplete(draft) {
                    Button(draft.completed ? "Reopen" : "Complete", systemImage: draft.completed ? "arrow.uturn.backward.circle" : "checkmark.circle") {
                        guard editorAvailable,editingGeneration == currentGeneration, workspaceBinding?.matches(account: store.userID, generation: store.workspaceGeneration) == true else { store.error = "This task or workspace changed. Reopen its current details."; return }
                        if workspace.hierarchyPresentation {
                            do { workspace.complete(try store.selectionRecord(taskID)) } catch { store.error = error.localizedDescription }
                        } else if let current { workspace.complete(current) }
                    }
                        .controlSize(.small).disabled(isTeamTask || !TaskKind.mayComplete(draft))
                    }
                    Spacer()
                    if draft.completed, let at = ISO8601DateFormatter().date(from: draft.string("completed_at")) { Text("Completed \(at.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
                }
            }
            let links = Linkify.urls(in: draft.title + "\n" + draft.string("description"))
            if !links.isEmpty {
                Section("Links") {
                    ForEach(links, id: \.absoluteString) { url in
                        Button { LinkOpener.open(url, workspace: workspace) } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(LinkTitles.shared.title(for: url) ?? Linkify.shortLabel(url)).lineLimit(1)
                                    Text(Linkify.host(url)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            } icon: { Image(systemName: "safari") }
                        }
                        .buttonStyle(.plain).pointerStyle(.link)
                        .help(url.absoluteString)
                        .contextMenu {
                            Button("Open Link", systemImage: "arrow.up.right.square") { LinkOpener.open(url, workspace: workspace) }
                            Button("Copy Link", systemImage: "doc.on.doc") { LinkOpener.copy(url); workspace.confirm("Copied link", undoable: false) }
                            ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                        }
                        .accessibilityIdentifier("inspectorLink")
                    }
                }
            }
            Section("Plan") {
                Toggle("Planned date", isOn: Binding(get: { draft.due != nil }, set: { draft["due_date"] = $0 ? .string(Dates.day(Date())) : .null; if !$0 { draft["due_time"] = .null } }))
                if draft.due != nil {
                    DatePicker("Date", selection: Binding(get: { draft.due ?? Date() }, set: { draft["due_date"] = .string(Dates.day($0)) }), displayedComponents: .date)
                    Toggle("Time", isOn: Binding(get: { !draft.string("due_time").isEmpty }, set: { draft["due_time"] = $0 ? .string("09:00") : .null }))
                    if !draft.string("due_time").isEmpty {
                        DatePicker("Time", selection: Binding(get: {
                            let parts = draft.string("due_time").split(separator: ":").compactMap { Int($0) }
                            return Calendar.current.date(bySettingHour: parts.first ?? 9, minute: parts.count > 1 ? parts[1] : 0, second: 0, of: Date()) ?? Date()
                        }, set: { let parts = Calendar.current.dateComponents([.hour, .minute], from: $0); draft["due_time"] = .string(String(format: "%02d:%02d", parts.hour ?? 9, parts.minute ?? 0)) }), displayedComponents: .hourAndMinute)
                    }
                    HStack(spacing: 6) {
                        quickDate("Today", Date()); quickDate("Tomorrow", Calendar.current.date(byAdding: .day, value: 1, to: Date())!); if let day = store.datePhraseDay("next week") { quickDate("Next week", day) }
                    }.controlSize(.small)
                }
                Toggle("Deadline", isOn: Binding(get: { draft.deadline != nil }, set: { draft["deadline_date"] = $0 ? .string(Dates.day(Date())) : .null }))
                if draft.deadline != nil {
                    DatePicker("Must be done by", selection: Binding(get: { draft.deadline ?? Date() }, set: { draft["deadline_date"] = .string(Dates.day($0)) }), displayedComponents: .date)
                        .accessibilityIdentifier("taskDeadline")
                    Text("Rescheduling the plan leaves this deadline in place.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Time estimate", isOn: Binding(get: { draft.durationMinutes != nil }, set: { draft["duration_minutes"] = $0 ? .number(30) : .null }))
                if let minutes = draft.durationMinutes {
                    Stepper("Estimate · \(minutes) min", value: Binding(get: { draft.durationMinutes ?? 30 }, set: { draft["duration_minutes"] = .number(Double($0)) }), in: 1...10080)
                        .accessibilityIdentifier("taskDuration")
                        .accessibilityLabel("Time estimate in minutes")
                        .accessibilityValue("\(minutes)")
                }
                if !draft.string("due_time").isEmpty {
                    Picker("Time zone", selection: text("time_zone")) {
                        Text("Local time · wherever I am").tag("")
                        Text("Fixed · " + TimeZone.current.identifier).tag(TimeZone.current.identifier)
                        if !draft.string("time_zone").isEmpty && draft.string("time_zone") != TimeZone.current.identifier {
                            Text("Fixed · " + draft.string("time_zone")).tag(draft.string("time_zone"))
                        }
                    }.accessibilityIdentifier("taskTimeZone")
                    if !draft.string("time_zone").isEmpty { Text("Date and time are shown in " + draft.string("time_zone") + ".").font(.caption).foregroundStyle(.secondary) }
                }
                Picker("Priority", selection: Binding(get: { draft.priority }, set: { draft["priority"] = .number(Double($0)) })) {
                    ForEach(1...4, id: \.self) { n in Label(n == 4 ? "None" : "Priority \(n)", systemImage: "flag.fill").foregroundStyle(Color.priority(n)).tag(n) }
                }
                LabeledContent("Assigned to") {
                    if isTeamTask {
                        Button(teamAssigneeCaption, action: openTeamAssignee).accessibilityIdentifier("taskAssignee")
                    } else {
                        AssigneeMenu(task: draft, contextID: taskID, showsName: true) { draft["assigned_to"] = $0.isEmpty ? .null : .string($0) }
                    }
                }
                if Workspace.subtaskPath(taskID) == nil {
                Picker("Project", selection: text("project_id")) {
                    Text("Inbox").tag("")
                    ForEach(store.projects) { Text($0.name).tag($0.id) }
                }.disabled(isTeamTask).onChange(of: draft.string("project_id")) { old, new in if old != new && new != original.string("project_id") { draft = Workspace.clearingAssignments(draft); draft["section_id"] = .null } }
                if !draft.string("project_id").isEmpty {
                    Picker("Section", selection: text("section_id")) {
                        Text("No section").tag("")
                        ForEach(store.rows("sections").filter { $0.string("project_id") == draft.string("project_id") }) { Text($0.name).tag($0.id) }
                    }
                }
                } else {
                    LabeledContent("Project", value: store.record("projects", id: workspace.assignmentProject(draft, contextID: taskID))?.name ?? "Inbox")
                    Text("Subtasks stay with the parent task.").font(.caption).foregroundStyle(.secondary)
                }
                if Workspace.subtaskPath(taskID) == nil {
                if isTeamTask {
                    Button(action: openTeamRepeat) { LabeledContent("Repeat", value: draft["is_recurring"].flag ? Recurrence.summary(Recurrence.effective(draft)) : "Never") }.accessibilityIdentifier("taskRepeat")
                } else { RecurrenceEditor(task: $draft) }
                if isTeamTask {
                    Button("Shared reminders…", systemImage: "bell", action: openTeamReminders).accessibilityIdentifier("taskTeamReminders")
                } else {
                    Button("Reminders…", systemImage: "bell") { showingReminders = true }.accessibilityIdentifier("taskReminders")
                }
                } else {
                    Text("Manage repeating schedules and reminders on the parent task.").font(.caption).foregroundStyle(.secondary)
                }

            }
            Section("Labels") {
                if isTeamTask {
                    Button("Edit shared labels", systemImage: "tag", action: openTeamLabels).accessibilityIdentifier("taskTeamLabels")
                } else {
                if store.labels.isEmpty { Text("Create labels from the sidebar.").foregroundStyle(.secondary) }
                ForEach(store.labels) { label in
                    Toggle(isOn: Binding(get: { TaskLabels.normalized(draft["labels"].list, labels: store.labels).contains(.string(label.id)) }, set: { enabled in
                        var labels = TaskLabels.normalized(draft["labels"].list, labels: store.labels).filter { $0 != .string(label.id) }; if enabled { labels.append(.string(label.id)) }; draft["labels"] = .array(labels)
                    })) { Label(label.name, systemImage: "tag.fill").foregroundStyle(Color.project(label.string("color"))) }.accessibilityIdentifier("taskLabel-" + label.id)
                }
                }
            }
            if workspace.taskDepth(taskID) < SubtaskTree.maximumDepth || !draft["subtasks"].list.isEmpty {
            Section("Subtasks") {
                let childIndices = SubtaskTree.uniqueChildIndices(draft["subtasks"])
                        SubtaskOrganizerButton(children: Binding(get: { draft["subtasks"] }, set: { draft["subtasks"] = $0 }), taskID: taskID, baseDepth: workspace.taskDepth(taskID), projectID: workspace.assignmentProject(draft, contextID: taskID),sourceRecord:draft,sourceRootID:sourceRoot?.id,custodyRoot:sourceRoot,admittedWorkspace:workspaceBinding, teamDraft:teamDraft, present: { subtaskOrganizing = $0 }, saveAndOpen: { children, path in
                    let previous = draft
                    draft["subtasks"] = children
                    guard saveNow() else { draft = previous; return false }
                    let childID = path.reduce(taskID) { parent, id in workspace.childID(parent: parent, value: .object(["id": .string(id)]), index: 0) }
                    workspace.open(childID)
                    return true
                })
                ForEach(Array(draft["subtasks"].list.enumerated()), id: \.offset) { index, value in
                    let title = SubtaskTree.inlineTitle(value)
                    let completed = value.object["completed"]?.flag == true
                    let accessibleTitle = title.isEmpty ? "untitled subtask" : title
                    HStack {
                        if TaskKind.mayComplete(Record(value.object)) {
                        Button { var list = draft["subtasks"].list; var item = value.object; item["completed"] = .bool(!(item["completed"]?.flag ?? false)); list[index] = .object(item); draft["subtasks"] = .array(list) } label: {
                            Image(systemName: value.object["completed"]?.flag == true ? "checkmark.circle.fill" : "circle").foregroundStyle(value.object["completed"]?.flag == true ? Color.taskfold : .secondary)
                        }.buttonStyle(.borderless)
                            .accessibilityLabel((completed ? "Reopen " : "Complete ") + accessibleTitle)
                            .accessibilityValue(completed ? "Completed" : "Not completed")
                            .accessibilityIdentifier("subtaskCompletion-\(index)")
                        } else {
                            Image(systemName: TaskKind(Record(value.object)) == .heading ? "textformat" : "questionmark.square")
                                .foregroundStyle(.secondary).accessibilityLabel(TaskKind(Record(value.object)) == .heading ? "Heading, stays open" : "Task type unavailable")
                        }
                        TextField("Subtask", text: Binding(get: { SubtaskTree.inlineTitle(draft["subtasks"].list[index]) }, set: { title in var list = draft["subtasks"].list; var item = list[index].object; item["title"] = .string(title); list[index] = .object(item); draft["subtasks"] = .array(list) }), prompt: Text("Subtask"), axis: .vertical)
                            .labelsHidden().textFieldStyle(.plain)
                        Button {
                            saveNow()
                            workspace.expandedTasks.insert(taskID)
                            workspace.open(workspace.childID(parent: taskID, value: value, index: index))
                        } label: { Image(systemName: "sidebar.trailing") }
                            .buttonStyle(.borderless).accessibilityLabel("Open details for " + accessibleTitle)
                            .disabled(isTeamTask || childIndices[Workspace.childKey(value, index: index)] != index)
                        Button { var list = draft["subtasks"].list; list.remove(at: index); draft["subtasks"] = .array(list) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.borderless).accessibilityLabel("Remove " + accessibleTitle)
                    }.disabled(!SubtaskTree.inlineEditable(value))
                }
                HStack { TextField("Subtask", text: $subtask, prompt: Text("Add a subtask")).accessibilityIdentifier("addSubtask").labelsHidden().textFieldStyle(.plain).onSubmit(addSubtask); Button("Add", action: addSubtask).controlSize(.small).accessibilityLabel("Add subtask").disabled(!SubtaskTree.hasListContainer(draft["subtasks"]) || subtask.trimmingCharacters(in: .whitespaces).isEmpty || workspace.taskDepth(taskID) >= SubtaskTree.maximumDepth) }
            }
            }
            Section("Attachments") {
                ForEach(Array(draft["attachments"].list.enumerated()), id: \.offset) { index, value in
                    HStack {
                        Button { openAttachment(Record(value.object)) } label: { Label(value.object["name"]?.text ?? "Attachment", systemImage: "paperclip") }.buttonStyle(.link)
                        Spacer()
                        Button { var list = draft["attachments"].list; list.remove(at: index); draft["attachments"] = .array(list) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.borderless).disabled(isTeamTask).accessibilityLabel("Remove attachment")
                    }
                }
                Button("Attach a File…", systemImage: "doc.badge.plus") { importing = true }.disabled(isTeamTask)
            }
            if Workspace.subtaskPath(taskID) == nil, store.conversationsAvailable, let saved = current, !saved.string("project_id").isEmpty {
                Section { Button("Shared conversation", systemImage: "bubble.left.and.bubble.right") { conversation = ConversationRequest(task: saved, workspace: WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration)) }.accessibilityIdentifier("openSharedConversation")
                    Text("Share comments and mention teammates here. Earlier task comments stay below.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Comments") {
                ForEach(Array(draft["comments"].list.enumerated()), id: \.offset) { index, value in
                    let row = Record(value.object)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.string("authorName").isEmpty ? "Comment" : row.string("authorName")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Button { var list = draft["comments"].list; list.remove(at: index); draft["comments"] = .array(list) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.borderless).disabled(isTeamTask).accessibilityLabel("Delete comment")
                        }
                        if !row.string("text").isEmpty { Text(.init(row.string("text"))).textSelection(.enabled) }
                        if case .object(let attachment) = row["attachment"] {
                            Button { openAttachment(Record(attachment)) } label: { CommentAttachmentPreview(attachment: Record(attachment)) }
                                .buttonStyle(.plain).help("Open attachment").accessibilityIdentifier("commentImageAttachment")
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Write a comment").font(.caption).foregroundStyle(.secondary)
                    CommentEditor(text: $comment, pasteImage: { data in
                        do {
                            let name = "Pasted image \(UUID().uuidString.prefix(8)).png"
                            guard data.count <= 5 * 1024 * 1024 else { throw AppFailure(message: "Choose an image smaller than 5 MB.") }
                            guard NSImage(data: data) != nil else { throw AppFailure(message: "This clipboard image could not be read.") }
                            let attachment = Record(["id": .string(UUID().uuidString.lowercased()), "name": .string(name), "size": .number(Double(data.count)), "type": .string("image/png"), "url": .string("data:image/png;base64," + data.base64EncodedString()), "uploadedAt": .string(Dates.timestamp())])
                            appendComment(attachment: attachment)
                            saveTask?.cancel()
                            saveNow()
                            if draft == original { pastedImageName = name }
                        } catch { store.error = error.localizedDescription }
                    }, pasteError: { store.error = $0 })
                    .disabled(isTeamTask)
                    .frame(height: 80)
                    .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                    if let pastedImageName {
                        Label("Attached \(pastedImageName)", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("pastedImageConfirmation")
                    }
                    Text("Paste an image with ⌘V to attach it immediately.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Add Comment", systemImage: "text.bubble") {
                    appendComment(text: comment.trimmingCharacters(in: .whitespacesAndNewlines))
                    comment = ""
                }.disabled(isTeamTask || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section {
                if let created = ISO8601DateFormatter().date(from: draft.string("created_at")) { LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .shortened)) }
                if isTeamTask && !isCreating && Workspace.subtaskPath(taskID) == nil {
                    Button("Move shared task…", systemImage: "folder.badge.arrow.forward") {
                        guard editorAvailable, teamDeletionClean, let captured = teamDraft else { return }
                        saveTask?.cancel()
                        teamMove = TeamTaskMoveRequest(draft: captured, current: { editorAvailable && teamDeletionClean }, completed: {
                            _ = recoverySession?.finish(); teamMove = nil; workspace.selection.remove(taskID)
                            if workspace.finderTaskID == taskID { workspace.finderTaskID = nil }
                        })
                    }.disabled(!teamDeletionClean).accessibilityIdentifier("reviewTeamTaskMove")
                    Button("Delete shared task…", systemImage: "trash", role: .destructive, action: openTeamDeletion)
                        .disabled(!teamDeletionClean).accessibilityIdentifier("reviewTeamTaskDeletion")
                    if !teamDeletionClean { Text("Finish saving your edits before moving or deleting this task.").font(.footnote).foregroundStyle(.secondary) }
                } else if isTeamTask && !isCreating {
                    Text("Manage this checklist item from its parent task.").font(.footnote).foregroundStyle(.secondary)
                } else if !isCreating { Button("Delete Task…", systemImage: "trash", role: .destructive) { confirmDelete = true } }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete “\(draft.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {guard editorAvailable else {stopEditing();return};workspace.delete([taskID])}
        } message: { Text("You can undo this from the Edit menu.") }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                try attach(try Data(contentsOf: url), name: url.lastPathComponent, type: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
            } catch { store.error = error.localizedDescription }
        }
        .quickLookPreview($preview)
        .onAppear { workspaceBinding = admission?.workspace ?? WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration); editingGeneration = currentGeneration; sourceRoot=admission?.source.root ?? store.record("tasks",id:Workspace.subtaskPath(taskID)?.first ?? taskID); if !teamDraftCaptured { teamDraftCaptured = true; if let admission { teamDraft = admission.teamDraft } else if Workspace.subtaskPath(taskID) == nil { teamDraft = sourceRoot.flatMap { try? store.captureTeamTaskEditor($0) } } }; load();sourceContext=admission?.source ?? TaskEditorSourceContext(record:draft,root:sourceRoot); if recoverySession==nil {do {recoverySession=try store.beginEditorSession(original)} catch {sessionFailure=error.localizedDescription}}; if draft.title.isEmpty { titleFocused = true } }
        .task(id: suggestions?.updates["project_id"]?.text ?? workspace.assignmentProject(draft, contextID: taskID)) { if !isTeamTask { _ = try? await store.refreshProjectMembers(suggestions?.updates["project_id"]?.text ?? workspace.assignmentProject(draft, contextID: taskID)) } }
        .onChange(of: workspace.titleFocusRequest) { _, _ in titleFocused = true }
        .onChange(of: titleChipFocused) { _, focused in if !focused { finishTitleWhenUnfocused() } }
        .sheet(item: $conversation) { SharedConversationView(request: $0) }
        .sheet(item: $noteFormatting) { request in
            NoteFormattingView(request: request) { value in
                guard editorAvailable else {return "This task’s access changed. Your formatted edit is kept privately."}
                guard request.workspace.matches(account: store.userID, generation: store.workspaceGeneration), request.taskID == taskID, currentGeneration == request.generation, editingGeneration == request.generation else { return "This task or workspace changed. Your formatted draft is still here." }
                if isCreating {
                    guard draft.string("description") == request.original else { return "The notes changed while formatting was open. Your formatted draft is still here." }
                    draft["description"] = .string(value); checkpoint(); return nil
                }
                guard let current, draft.string("description") == request.original,
                      current.string("description") == request.storedText || current.string("description") == request.original else { return "The notes changed while formatting was open. Copy your draft before reopening the current notes." }
                let previous = draft; saveTask?.cancel()
                draft["description"] = .string(value)
                if saveNow() { return nil }
                draft = previous; saveTask?.cancel()
                let failure = store.error ?? "The notes couldn’t be saved. Your formatted draft is still here; please try again."
                store.error = nil
                return failure
            }
        }
        .sheet(isPresented: $showingReminders) {
            NavigationStack {
                TaskReminderEditor(task: $draft).onAppear { draft = store.applyingReminderDefault(draft, previous: original) }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingReminders = false } } }
            }.frame(minWidth: 550, minHeight: 620)
        }
        .onChange(of: draft) { _, _ in checkpoint();scheduleSave() }
        .onChange(of: currentGeneration) { _, _ in stopEditing() }
        .onChange(of: current) { _, value in
            // Untouched fields follow sync; the user's in-progress edits win.
            guard editorAvailable, workspaceBinding?.matches(account: store.userID, generation: store.workspaceGeneration) == true, editingGeneration == currentGeneration, let value else { return }
            var merged = value
            var nextOriginal = value
            for (key, field) in draft.fields where original.fields[key] != field {
                merged[key] = field
                nextOriginal[key] = original[key]
            }
            if draft.title == titleParsingBaseline { titleParsingBaseline = merged.title }
            original = nextOriginal
            if merged != draft { draft = merged }
        }
        .onReceive(NotificationCenter.default.publisher(for: TerminationSaveRequest.notification)) { notification in
            guard let request = notification.object as? TerminationSaveRequest else { return }
            saveTask?.cancel()
            applySuggestions()
            saveNow()
            // Store commits synchronously to its durable cache. A failed save
            // retains this draft and must keep the process alive for a retry.
            checkpoint()
            if (draft != original || notePin != nil || !subtask.isEmpty || !comment.isEmpty),recoverySession?.flush() != true { request.hasUnsavedEdits = true }
        }
        .onDisappear { saveTask?.cancel(); titleFocused = false; applySuggestions(); saveNow() }
    }
    private func quickDate(_ title: String, _ date: Date) -> some View {
        Button(title) { draft["due_date"] = .string(Dates.day(date)) }.buttonStyle(.bordered)
    }
    private func finishTitleWhenUnfocused() {
        // Moving from the title to one of its chips is still editing the title.
        // Wait for both focus bindings before applying the parsed values.
        DispatchQueue.main.async {
            guard !titleFocused, !titleChipFocused else { return }
            applySuggestions()
            saveNow()
        }
    }
    private func resumeTitleFromChip() {
        let title = draft.title
        titleFocused = true
        DispatchQueue.main.async {
            guard titleFocused, draft.title == title else { return }
            titleSelection = TextSelection(insertionPoint: draft.title.endIndex)
        }
    }
    private func load() { if let value = current ?? (isCreating ? admission?.source.record : nil) { draft = value; original = value; titleParsingBaseline = isCreating ? "" : value.title } }
    /// Moves accepted quick-entry pieces out of the title into their fields, like the iOS editor's save.
    private func applySuggestions() {
        guard editorAvailable,workspaceBinding?.matches(account: store.userID, generation: store.workspaceGeneration) == true, (current != nil || isCreating) else { return }
        guard QuickReferenceCompletion(draft.title, context: workspace.quickEntryContext(project: workspace.assignmentProject(draft, contextID: taskID)).choosingReferences(referenceChoices)).range == nil else { titleParsingBaseline = draft.title; return }
        guard let parsed = suggestions, parsed.hasSuggestions else { titleParsingBaseline = draft.title; return }
        withAnimation(workspace.layout) {
            draft = parsed.applying(to: draft)
        }
        for value in parsed.updates["labels"]?.list ?? [] where !store.labels.contains(where: { $0.name == value.text || $0.id == value.text }) {
            _ = store.save("labels", Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(store.userID), "name": value, "color": .string("#e31e4b")]))
        }
        declined = []; titleParsingBaseline = draft.title
    }
    private func applyReferenceChoices() {
        guard editorAvailable,workspaceBinding?.matches(account: store.userID, generation: store.workspaceGeneration) == true, (current != nil || isCreating) else { return }
        let referenceGroups: Set<String> = ["project_id", "section_id", "assigned_to", "labels"]
        let excluded = Set(QuickEntry.groups).subtracting(referenceGroups).union(declined).union(quickExclusions)
        let parsed = QuickEntry(draft.title, disabled: excluded, context: workspace.quickEntryContext(project: workspace.assignmentProject(draft, contextID: taskID)).choosingReferences(referenceChoices), task: draft)
        draft = parsed.applying(to: draft)
        for value in parsed.updates["labels"]?.list ?? [] where !store.labels.contains(where: { $0.id == value.text || $0.name == value.text }) {
            _ = store.save("labels", Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(store.userID), "name": value, "color": .string("#e31e4b")]))
        }
        titleSelection = TextSelection(insertionPoint: draft.title.endIndex)
        saveNow()
    }
    private func createTeamTask() {
        guard isCreating, !creationFinished, editorAvailable, let captured = teamDraft else { checkpoint(); return }
        saveTask?.cancel(); applySuggestions()
        draft["title"] = .string(draft.title.trimmingCharacters(in: .whitespacesAndNewlines))
        var saved = false
        workspace.run("Add Shared Task") { saved = store.saveTeamTaskEditor(draft, draft: captured) }
        if saved {
            creationFinished = true; _ = recoverySession?.finish()
            if workspace.quickAdd == workspace.teamTaskCreationText { workspace.quickAdd = "" }
            workspace.selection = [draft.id]; workspace.confirm("Added “\(draft.title)”"); dismiss()
        } else {
            creationFailure = (store.error ?? "Your task could not be added.") + "\n\nYour draft is still here."
            store.error = nil; checkpoint()
        }
    }
    private func scheduleSave() {
        saveTask?.cancel()
        if isCreating { checkpoint(); return }
        guard editorAvailable else {checkpoint();return}
        saveTask = Task { try? await Task.sleep(for: .milliseconds(600)); guard !Task.isCancelled else { return }; saveNow() }
    }
    private var teamDeletionClean: Bool { draft == original && subtask.isEmpty && comment.isEmpty && notePin == nil }
    private func openTeamDeletion() {
        guard !isCreating, Workspace.subtaskPath(taskID) == nil, editorAvailable, teamDeletionClean, let captured = teamDraft, taskID == captured.source.id else { return }
        saveTask?.cancel()
        teamDeletion = TeamTaskDeletionRequest(draft: captured, current: { editorAvailable && teamDeletionClean }, perform: { requestID in
            guard editorAvailable, teamDeletionClean else { return false }
            var saved = false
            workspace.run("Delete Shared Task") { saved = store.deleteTeamTaskEditor(captured, requestID: requestID) }
            return saved
        }, completed: {
            _ = recoverySession?.finish(); teamDeletion = nil
            workspace.selection.remove(taskID)
            if workspace.finderTaskID == taskID { workspace.finderTaskID = nil }
            workspace.confirm("Deleted “\(captured.source.title)”")
        })
    }
    private func openTeamRepeat() {
        guard editorAvailable, let captured = teamDraft else { return }
        let opening = draft
        teamRepeat = TeamTaskRecurrenceRequest(teamDraft: captured, record: opening, sourceIdentity: sourceContext?.identity ?? .null, current: { editorAvailable }, apply: { value in
            guard editorAvailable else { return "Project access changed. Your repeat draft is still here." }
            do {
                let changes = try TeamTaskRecurrence.reviewedChanges(from: opening, to: value)
                guard !changes.isEmpty else { return nil }
                try TeamTaskRecurrence.requireCurrent(base: TaskCompletionRevision.editBaseline(for: changes, from: opening), current: draft)
                for (key, field) in changes { draft[key] = field }
                if !saveNow() { return "Your repeat edit could not be saved. Keep this draft open and retry." }
                return nil
            } catch { return error.localizedDescription }
        })
    }
    private func openTeamReminders() {
        guard editorAvailable, let captured = teamDraft else { return }
        let opening = draft["reminder_specs"]
        teamReminders = TeamTaskRemindersRequest(teamDraft: captured, record: draft, sourceIdentity: sourceContext?.identity ?? .null, current: { editorAvailable }, apply: { value in
            guard editorAvailable, draft["reminder_specs"] == opening else { return "Reminders changed while this editor was open. Close it and review the current choices." }
            if value == opening { return nil }
            draft["reminder_specs"] = value
            guard saveNow() else { return "Your reminder edit remains in this task draft. Reopen its current details before saving again." }
            return nil
        })
    }
    private func openTeamLabels() {
        guard editorAvailable, let captured = teamDraft else { return }
        let opening = draft["labels"]
        teamLabels = TeamTaskLabelsRequest(teamDraft: captured, record: draft, sourceIdentity: sourceContext?.identity ?? .null, current: { editorAvailable }, apply: { value in
            guard editorAvailable, draft["labels"] == opening else { return "Labels changed while this editor was open. Close it and review the task’s current labels." }
            if value == opening { return nil }
            draft["labels"] = value
            guard saveNow() else { return "Your label edit remains in this task draft. Reopen its current details before saving again." }
            return nil
        })
    }
    private var teamAssigneeCaption: String {
        let id = draft.string("assigned_to")
        if id.isEmpty { return "Unassigned" }
        if id == store.userID { return "You" }
        return selectedTeamID == id ? selectedTeamName ?? "Team member" : "Team member"
    }
    private func openTeamAssignee() {
        guard editorAvailable, let captured = teamDraft else { return }
        teamAssignee = TeamTaskAssigneeRequest(draft: captured,
            selected: Binding(get: { draft.string("assigned_to") }, set: { draft["assigned_to"] = $0.isEmpty ? .null : .string($0) }),
            current: { editorAvailable }, choose: { person in
                guard editorAvailable else { return "Project access changed. Reopen this task before assigning it." }
                draft["assigned_to"] = person.map { .string($0.id) } ?? .null
                selectedTeamID = person?.id; selectedTeamName = person?.displayName
                guard saveNow() else { return "Your assignment is still in this draft. Reopen the task’s current details before saving again." }
                return nil
            })
    }
    @discardableResult private func saveNow() -> Bool {
        if isCreating { checkpoint(); return editorAvailable }
        guard editorAvailable,workspaceBinding?.matches(account: store.userID, generation: store.workspaceGeneration) == true, let current else { checkpoint();return false }
        guard draft != original || notePin != nil else { return true }
        guard editingGeneration == currentGeneration else {
            store.error = "This task was deleted and restored while you were editing. Your draft is still here; reopen the current task before saving."
            return false
        }
        if let captured = teamDraft {
            var desired = captured.source
            for key in Set(original.fields.keys).union(draft.fields.keys) where original[key] != draft[key] { desired[key] = draft[key] }
            let title = desired.title.trimmingCharacters(in: .whitespacesAndNewlines)
            desired["title"] = title.isEmpty ? captured.source["title"] : .string(title)
            let saved = store.saveTeamTaskEditor(desired, draft: captured)
            if saved, let live = store.record("tasks", id: captured.source.id) {
                original = live; draft = live
                teamDraft = try? store.captureTeamTaskEditor(live)
                if subtask.isEmpty && comment.isEmpty { _ = recoverySession?.finish() }
            }
            return saved
        }
        var merged = current
        for (key, value) in draft.fields where original.fields[key] != value { merged[key] = value }
        merged["title"] = .string(merged.title.trimmingCharacters(in: .whitespacesAndNewlines))
        if merged.title.isEmpty { merged["title"] = original["title"] }
        if Workspace.subtaskPath(taskID) == nil && merged["is_recurring"].flag && merged.due == nil { merged["due_date"] = .string(Dates.day(Date())) }
        if Workspace.subtaskPath(taskID) == nil { merged = store.applyingReminderDefault(merged, previous: original) }
        guard merged != current || notePin != nil else { original = merged; draft = merged; return true }
        var saved = false
        if let notePin {
            workspace.run("Edit Pinned Note") { saved = store.saveTaskWithNotePin(merged, pin: notePin, baseline: original) }
            if saved { self.notePin = nil }
        } else { saved = workspace.save("tasks", merged, name: "Edit Task", baseline: original) }
        if saved { original = merged; draft = merged; if subtask.isEmpty && comment.isEmpty {_=recoverySession?.finish()} }
        return saved
    }
    private func addSubtask() {
        guard workspace.taskDepth(taskID) < SubtaskTree.maximumDepth else { return }
        let title = subtask.trimmingCharacters(in: .whitespacesAndNewlines); guard !title.isEmpty else { return }
        do { draft["subtasks"] = try SubtaskTree.adding(draft["subtasks"], title: title, baseDepth: workspace.taskDepth(taskID)); subtask = ""; saveNow(); workspace.expandedTasks.insert(taskID) }
        catch { store.error = error.localizedDescription }
    }
    private func appendComment(text: String = "", attachment: Record? = nil) {
        var fields: [String: JSON] = ["id": .string(UUID().uuidString.lowercased()), "text": .string(text), "createdAt": .string(Dates.timestamp()), "authorId": .string(store.userID), "authorName": .string(store.profile.string("display_name").isEmpty ? (store.localMode ? "You" : store.email) : store.profile.string("display_name"))]
        if let attachment { fields["attachment"] = .object(attachment.fields) }
        var comments = draft["comments"].list
        comments.append(.object(fields))
        draft["comments"] = .array(comments)
    }
    private func attach(_ data: Data, name: String, type: String) throws {
        guard data.count <= 5 * 1024 * 1024 else { throw AppFailure(message: "Choose a file smaller than 5 MB.") }
        var list = draft["attachments"].list
        list.append(.object(["id": .string(UUID().uuidString.lowercased()), "name": .string(name), "size": .number(Double(data.count)), "type": .string(type), "url": .string("data:\(type);base64,\(data.base64EncodedString())"), "uploadedAt": .string(Dates.timestamp())]))
        draft["attachments"] = .array(list)
    }
    private func openAttachment(_ attachment: Record) {
        let value = attachment.string("url")
        if value.hasPrefix("data:"), let comma = value.firstIndex(of: ","), let data = Data(base64Encoded: String(value[value.index(after: comma)...])) {
            let safeName = URL(fileURLWithPath: attachment.string("name")).lastPathComponent
            // Isolate each preview without exposing its internal identifier as the filename.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-attachment-\(UUID().uuidString)", isDirectory: true)
            let name = safeName.isEmpty || safeName == "." || safeName == ".." ? "Attachment" : safeName
            let url = directory.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                preview = url
            } catch {
                try? FileManager.default.removeItem(at: directory)
                store.error = error.localizedDescription
            }
        } else if let url = URL(string: value), url.scheme == "https" { NSWorkspace.shared.open(url) }
        else { store.error = "This attachment cannot be opened." }
    }
}

/// Recurrence editing inline in the inspector, using the shared pattern vocabulary.
struct RecurrenceEditor: View {
    @Binding var task: Record
    @State private var expanded = false
    @FocusState private var headerFocused: Bool
    var body: some View {
        let summary = task["is_recurring"].flag ? Recurrence.summary(Recurrence.effective(task)) : "Never"
        VStack(alignment: .leading, spacing: 12) {
            Button { expanded.toggle(); headerFocused = true } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Repeat")
                        Text(summary).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).focusable().focused($headerFocused)
                .onKeyPress(.space) { expanded.toggle(); return .handled }
                .accessibilityIdentifier("taskRepeat")
                .accessibilityLabel("Repeat")
                .accessibilityValue((expanded ? "Expanded. " : "Collapsed. ") + summary)
                .accessibilityHint(expanded ? "Hide repeat settings" : "Show repeat settings")
            if expanded { RecurrenceFields(task: $task) }
        }
    }
}


struct CommentAttachmentPreview: View {
    let attachment: Record
    @State private var image: NSImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 160)
                    .clipShape(.rect(cornerRadius: 6))
            }
            Label(attachment.name, systemImage: "paperclip").font(.caption).foregroundStyle(.secondary)
        }
        .task(id: attachment.string("url")) {
            image = nil
            let value = attachment.string("url")
            if value.hasPrefix("data:image/"), let comma = value.firstIndex(of: ","),
               let data = Data(base64Encoded: String(value[value.index(after: comma)...])) { image = NSImage(data: data) }
        }
    }
}


/// The captured IDs never expand when selection or scope changes behind this sheet.
struct BulkDeadlineEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    let request: DeadlineSelection
    let records: [Record]
    let apply: (String?) throws -> Bool
    @State private var date = Date()
    @State private var clearing = false
    @State private var message: String?
    private var day: String? { clearing ? nil : TaskPlanner.dayKey(date) }
    private var changedCount: Int { records.filter { $0["deadline_date"] != day.map(JSON.string) ?? .null }.count }
    private var available: Bool { request.account == store.userID && !records.isEmpty }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Action", selection: $clearing) {
                        Text("Set a deadline").tag(false); Text("Clear deadlines").tag(true)
                    }.pickerStyle(.segmented).accessibilityIdentifier("bulkDeadlineAction")
                    if !clearing {
                        DatePicker("Deadline", selection: $date, displayedComponents: .date)
                            .datePickerStyle(.graphical).accessibilityIdentifier("bulkDeadlineDate")
                    }
                } footer: {
                    Text("A deadline is when work must be finished. Planned dates, times, estimates and reminders stay in place.")
                }
                Section("Selected tasks") {
                    if request.account != store.userID { Text("This workspace changed. Close this editor and select tasks again.").foregroundStyle(.secondary) }
                    else {
                        ForEach(records) { task in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.title).font(.body.weight(.medium))
                                Text(task.deadline.map { "Deadline · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "No deadline")
                                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("bulkDeadlineCurrent-" + task.id)
                                Text(TaskPlanner.dayDate(task).map { "Planned · " + $0.formatted(date: .abbreviated, time: .omitted) + (task.string("due_time").isEmpty ? "" : " · " + TaskPlanner.clockValue(task)) } ?? "No planned date")
                                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("bulkDeadlinePlan-" + task.id)
                            }.padding(.vertical, 3)
                        }
                        let missing = request.ids.count - records.count
                        if missing > 0 { Text("\(missing) selected \(missing == 1 ? "task is" : "tasks are") no longer available and will be skipped.").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                Section {
                    Text(changedCount == 0 ? "The selected tasks already match this choice." : "\(changedCount) \(changedCount == 1 ? "task will" : "tasks will") change as one undoable step.").font(.footnote).foregroundStyle(.secondary)
                    if let message { Text(message).foregroundStyle(.red).accessibilityIdentifier("bulkDeadlineError") }
                }
            }.formStyle(.grouped)
            .navigationTitle("Edit deadlines")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("bulkDeadlineCancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button(clearing ? "Clear" : "Apply") {
                        do {
                            if try apply(day) { dismiss() } else { message = "The deadlines could not be saved. Try again." }
                        } catch { message = error.localizedDescription }
                    }.disabled(!available || changedCount == 0).accessibilityIdentifier("bulkDeadlineApply")
                }
            }
            .onAppear {
                let values = Set(records.map { $0.string("deadline_date") })
                if values.count == 1, let value = values.first, let existing = Dates.parse(value) { date = existing }
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        #else
        .frame(width: 460, height: 570)
        #endif
    }
}

/// Native rule controls expose every property produced by quick entry.
struct RecurrenceFields: View {
    @Binding var task: Record
    private var pattern: Record { Recurrence.effective(task) }
    private func field(_ key: String, _ value: JSON) { var p = pattern.fields; p[key] = value; task["recurrence_pattern"] = .object(p); task["recurrence_end_date"] = .null }
    private func type(_ value: String) {
        var p = pattern.fields
        for key in ["daysOfWeek", "weekday", "weekdayOrdinal", "dayOfMonth", "daysOfMonth", "monthOfYear"] { p.removeValue(forKey: key) }
        p["type"] = .string(value)
        if ["monthly", "yearly"].contains(value), !pattern["fromCompletion"].flag {
            p["dayOfMonth"] = .number(Double(Calendar(identifier: .gregorian).component(.day, from: task.due ?? Date())))
        }
        if value == "yearly", !pattern["fromCompletion"].flag { p["monthOfYear"] = .number(Double(Calendar(identifier: .gregorian).component(.month, from: task.due ?? Date()))) }
        task["recurrence_pattern"] = .object(p)
    }
    var body: some View {
        Toggle("Repeat task", isOn: Binding(get: { task["is_recurring"].flag }, set: { enabled in
            task["is_recurring"] = .bool(enabled)
            if enabled {
                if pattern.string("type").isEmpty { task["recurrence_pattern"] = .object(["type": .string("daily"), "interval": .number(1)]) }
                if task.string("due_date").isEmpty { task["due_date"] = .string(Dates.day(Date())) }
            }
        })).accessibilityIdentifier("repeatEnabled")
        if task["is_recurring"].flag {
            Text(Recurrence.summary(pattern)).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("repeatRuleSummary")
            Picker("Frequency", selection: Binding(get: { pattern.string("type") }, set: type)) {
                Text("Daily").tag("daily"); Text("Weekly").tag("weekly"); Text("Monthly").tag("monthly"); Text("Yearly").tag("yearly"); Text("Custom days").tag("custom")
            }.accessibilityIdentifier("repeatFrequency")
            RepeatStepper(title: "Every \(max(1, pattern["interval"].integer)) \(unit)", value: Binding(get: { max(1, pattern["interval"].integer) }, set: { field("interval", .number(Double($0))) }), range: 1...365, identifier: "repeatInterval")
            Toggle("Repeat from completion", isOn: Binding(get: { pattern["fromCompletion"].flag }, set: { field("fromCompletion", .bool($0)) })).accessibilityIdentifier("repeatFromCompletion")
            Text(pattern["fromCompletion"].flag ? "Wait the full interval from completion, then use the next chosen weekday or calendar day." : "Keep the planned rhythm. Missed dates are skipped when you complete the task late.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if pattern["fromCompletion"].flag, ["monthly", "yearly"].contains(pattern.string("type")) {
                Toggle("Use completion calendar day", isOn: Binding(get: { followsCompletionDay }, set: { enabled in
                    for key in ["weekday", "weekdayOrdinal", "dayOfMonth", "daysOfMonth", "monthOfYear"] { field(key, .null) }
                    if !enabled {
                        let calendar = TaskCompletion.calendar(for: task)
                        field("dayOfMonth", .number(Double(calendar.component(.day, from: task.due ?? Date()))))
                        if pattern.string("type") == "yearly" { field("monthOfYear", .number(Double(calendar.component(.month, from: task.due ?? Date())))) }
                    }
                })).accessibilityIdentifier("repeatCompletionCalendarDay")
            }
            if pattern.string("type") == "weekly" {
                ForEach(0..<7, id: \.self) { day in
                    Toggle(DateFormatter().weekdaySymbols[day], isOn: Binding(get: { pattern["daysOfWeek"].list.contains(.number(Double(day))) }, set: { enabled in
                        var days = pattern["daysOfWeek"].list.filter { $0 != .number(Double(day)) }; if enabled { days.append(.number(Double(day))) }; field("daysOfWeek", .array(days))
                    })).accessibilityIdentifier("repeatWeekday-\(day)")
                }
                Text("With no weekdays selected, repeat every chosen number of weeks from the task’s date.").font(.caption).foregroundStyle(.secondary)
            }
            if pattern.string("type") == "monthly", !followsCompletionDay {
                Picker("Repeat on",selection:Binding(get:{monthlyMode},set:setMonthlyMode)) {
                    Text("Day of month").tag("day");Text("Multiple dates").tag("dates");Text("Weekday of month").tag("weekday")
                }.accessibilityIdentifier("repeatMonthlyMode")
                if monthlyMode=="dates" {
                    MonthlyDateChoices(days:Set(pattern["daysOfMonth"].list.map(\.integer))) { days in field("daysOfMonth",.array(days.sorted().map{.number(Double($0))})) }
                    Text("Choose at least one date. Short months use their last day; dates landing on the same day count once.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                if pattern["weekdayOrdinal"] != .null {
                    Picker("Which", selection: Binding(get: { pattern["weekdayOrdinal"].integer }, set: { field("weekdayOrdinal", .number(Double($0))) })) {
                        ForEach([1,2,3,4,5,-1], id: \.self) { value in Text(Recurrence.ordinals[value] ?? "").tag(value) }
                    }.accessibilityIdentifier("repeatOrdinal")
                    Picker("Weekday", selection: Binding(get: { pattern["weekday"].integer }, set: { field("weekday", .number(Double($0))) })) {
                        ForEach(0..<7, id: \.self) { day in Text(DateFormatter().weekdaySymbols[day]).tag(day) }
                    }.accessibilityIdentifier("repeatMonthlyWeekday")
                }
            }
            if pattern.string("type") == "yearly", !followsCompletionDay {
                Picker("Month", selection: Binding(get: { Recurrence.number(pattern["monthOfYear"], in: 1...12) ?? Calendar(identifier: .gregorian).component(.month, from: task.due ?? Date()) }, set: { field("monthOfYear", .number(Double($0))) })) {
                    ForEach(1...12, id: \.self) { month in Text(DateFormatter().monthSymbols[month - 1]).tag(month) }
                }.accessibilityIdentifier("repeatMonth")
            }
            if ["monthly", "yearly"].contains(pattern.string("type")), pattern["weekdayOrdinal"] == .null, pattern["daysOfMonth"] == .null, !followsCompletionDay {
                RepeatStepper(title: "Day \(Recurrence.number(pattern["dayOfMonth"], in: 1...31) ?? Calendar(identifier: .gregorian).component(.day, from: task.due ?? Date()))", value: Binding(get: { Recurrence.number(pattern["dayOfMonth"], in: 1...31) ?? Calendar(identifier: .gregorian).component(.day, from: task.due ?? Date()) }, set: { field("dayOfMonth", .number(Double($0))) }), range: 1...31, identifier: "repeatDayOfMonth")
            }
            Toggle("End date", isOn: Binding(get: { !pattern.string("endDate").isEmpty }, set: { field("endDate", $0 ? .string(task.string("due_date").isEmpty ? Dates.day(Date()) : task.string("due_date")) : .null); task["recurrence_end_date"] = .null })).accessibilityIdentifier("repeatEndDateEnabled")
            if !pattern.string("endDate").isEmpty { DatePicker("Ends (inclusive)", selection: Binding(get: { Dates.parse(pattern.string("endDate")) ?? Date() }, set: { field("endDate", .string(Dates.day($0))) }), displayedComponents: .date).accessibilityIdentifier("repeatEndDate") }
            Toggle("Limit occurrences", isOn: Binding(get: { pattern["count"].integer > 0 }, set: { field("count", $0 ? .number(10) : .null) })).accessibilityIdentifier("repeatCountEnabled")
            if pattern["count"].integer > 0 { RepeatStepper(title: "\(pattern["count"].integer) occurrences remaining", value: Binding(get: { pattern["count"].integer }, set: { field("count", .number(Double($0))) }), range: 1...999, identifier: "repeatCount") }
            Text("Completing creates one next occurrence. Shorter months use their last day; months without a fifth chosen weekday are skipped. The occurrence limit includes this task.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            let dates=Recurrence.preview(task,completion:Date())
            if let date=dates.first {
                Text("If completed today: "+previewDate(date)).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("repeatNextPreview")
                VStack(alignment:.leading,spacing:8) {
                    Text("Upcoming occurrences").font(.subheadline.weight(.semibold))
                    ForEach(Array(dates.enumerated()),id:\.offset) { index,day in
                        Text("\(index+1). "+previewDate(day)).monospacedDigit().accessibilityIdentifier("repeatPreview-\(index)")
                    }
                    Text(pattern["fromCompletion"].flag ? "After the first date, this preview assumes each task is completed on its scheduled day. Later completions move the next date." : "Dates follow the planned rhythm. Completing late skips missed dates.").font(.caption).foregroundStyle(.secondary)
                    if !task.string("due_time").isEmpty {Text("Task time: "+task.string("due_time")+" · "+previewCalendar.timeZone.identifier).font(.caption).foregroundStyle(.secondary)}
                }.fixedSize(horizontal:false,vertical:true)
            } else { Text("No next occurrence within this rule’s limits.").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("repeatNextPreview") }
        }
    }
    private var followsCompletionDay: Bool { pattern["fromCompletion"].flag && pattern["dayOfMonth"] == .null && pattern["monthOfYear"] == .null && pattern["weekdayOrdinal"] == .null && pattern["daysOfMonth"] == .null }
    private var previewCalendar:Calendar {TaskCompletion.calendar(for:task)}
    private var plannedDay:Int {previewCalendar.component(.day,from:Dates.parse(task.string("due_date"),calendar:previewCalendar) ?? Date())}
    private var monthlyMode:String {pattern["daysOfMonth"] != .null ? "dates" : pattern["weekdayOrdinal"] != .null ? "weekday" : "day"}
    private func setMonthlyMode(_ mode:String) {
        var values=pattern.fields
        for key in ["dayOfMonth","daysOfMonth","weekday","weekdayOrdinal","daysOfWeek","monthOfYear"] {values.removeValue(forKey:key)}
        switch mode {
        case "dates":values["daysOfMonth"] = .array([.number(Double(Recurrence.number(pattern["dayOfMonth"],in:1...31) ?? plannedDay))])
        case "weekday":values["weekdayOrdinal"] = .number(1);values["weekday"] = .number(Double(previewCalendar.component(.weekday,from:Dates.parse(task.string("due_date"),calendar:previewCalendar) ?? Date())-1))
        default:values["dayOfMonth"] = .number(Double(pattern["daysOfMonth"].list.compactMap{Recurrence.number($0,in:1...31)}.min() ?? plannedDay))
        }
        task["recurrence_pattern"] = .object(values);task["recurrence_end_date"] = .null
    }
    private func previewDate(_ date:Date)->String {let formatter=DateFormatter();formatter.calendar=previewCalendar;formatter.timeZone=previewCalendar.timeZone;formatter.dateStyle = .medium;return formatter.string(from:date)}
    private var unit: String {
        let singular = ["daily":"day", "weekly":"week", "monthly":"month", "yearly":"year", "custom":"day"][pattern.string("type")] ?? "interval"
        return pattern["interval"].integer > 1 ? singular + "s" : singular
    }
}

/// Selected calendar dates, with touch targets and an explicit nonempty choice.
struct MonthlyDateChoices:View {
    let days:Set<Int>
    let change:(Set<Int>)->Void
    @Environment(\.dynamicTypeSize) private var textSize
    var body:some View {
        LazyVGrid(columns:[GridItem(.adaptive(minimum:textSize.isAccessibilitySize ? 88:44),spacing:4)],spacing:8) {
            ForEach(1...31,id:\.self) { day in
                let selected=days.contains(day)
                Button {
                    var next=days;if selected {next.remove(day)}else{next.insert(day)}
                    if !next.isEmpty {change(next)}
                } label: {
                    Text("\(day)").font(.body.weight(selected ? .semibold:.regular)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? Color.white:Color.primary).frame(maxWidth:.infinity,minHeight:44)
                        .background(selected ? Color.taskfold:Color.secondary.opacity(0.1),in:RoundedRectangle(cornerRadius:12)).contentShape(.rect)
                }.buttonStyle(MonthlyDateButtonStyle())
                    .accessibilityLabel("Day \(day)").accessibilityValue(selected ? "Selected":"Not selected")
                    .disabled(selected && days.count==1)
                    .accessibilityHint(selected && days.count==1 ? "Select another date before removing this one.":"")
                    .accessibilityIdentifier("repeatMonthDate-\(day)")
            }
        }.accessibilityElement(children:.contain).accessibilityLabel("Dates of month")
    }
}

/// Preserve readable selected ink when the minimum one-date choice cannot be removed.
private struct MonthlyDateButtonStyle:ButtonStyle {
    func makeBody(configuration:Configuration)->some View {configuration.label.opacity(configuration.isPressed ? 0.75:1)}
}

/// Keep native Mac controls; give iPhone increment/decrement actions full touch targets.
struct RepeatStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let identifier: String
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        #if os(iOS)
        Group {
            if textSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title).fixedSize(horizontal: false, vertical: true)
                    controls
                }
            } else {
                HStack(spacing: 12) {
                    Text(title).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    controls
                }
            }
        }.frame(minHeight: 44).accessibilityElement(children: .contain).accessibilityIdentifier(identifier)
        #else
        Stepper(title, value: $value, in: range).accessibilityIdentifier(identifier)
        #endif
    }
    #if os(iOS)
    private var controls: some View {
        HStack(spacing: 0) {
            Button { value = max(range.lowerBound, value - 1) } label: {
                Image(systemName: "minus").font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
            }.disabled(value <= range.lowerBound).accessibilityLabel("Decrease " + title).accessibilityIdentifier(identifier + "-decrease")
            Divider().frame(height: 20)
            Button { value = min(range.upperBound, value + 1) } label: {
                Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
            }.disabled(value >= range.upperBound).accessibilityLabel("Increase " + title).accessibilityIdentifier(identifier + "-increase")
        }.buttonStyle(.plain).fixedSize().background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
    }
    #endif
}

#if DEBUG
struct TeamEditorNativeFixtureView: View {
    @Environment(Store.self) private var store
    @State private var recoveryPresented = false
    @State private var draftsPresented = false
    @State private var storageStatus = ""
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--team-batch-recovery-testing") {
            NavigationStack {
                Form {
                    Text("Queued edits: \(store.snapshot.pending.count)").accessibilityIdentifier("macRecoveryPending")
                    if let notice = store.notice { Text(notice).accessibilityIdentifier("macRecoveryNotice") }
                    if let error = store.error { Text(error).accessibilityIdentifier("macRecoveryError") }
                    if ProcessInfo.processInfo.arguments.contains("--team-recorded-draft-testing") {
                        Button("Check draft review binding") { Task { await store.checkRecordedDraftAdmissionFixture() } }.accessibilityIdentifier("checkRecordedDraftAdmission")
                        Text(store.recordedDraftAdmissionStatus).accessibilityIdentifier("recordedDraftAdmissionStatus")
                    }
                    if TeamRecoveryRaceNativeFixture.mode != nil {
                        Button("Run delayed recovery check") { Task { await store.runTeamRecoveryRaceFixture() } }.accessibilityIdentifier("runTeamRecoveryRace")
                        Text(store.teamRecoveryRaceStatus).accessibilityIdentifier("teamRecoveryRaceStatus")
                    }
                    Button("Review saved action") { Task { await store.prepareTeamBatchRecoveryFixture(); recoveryPresented = store.syncConflict != nil } }.accessibilityIdentifier("openMacCompletionRecovery")
                    Button("Check paused sync") { Task { await store.sync(); recoveryPresented = store.syncConflict != nil } }.accessibilityIdentifier("discoverMacCompletionRecovery")
                    Button("Saved team drafts") { draftsPresented = true }.accessibilityIdentifier("openMacSavedDrafts")
                }.formStyle(.grouped).navigationTitle("Completion recovery test")
            }
            .sheet(isPresented: $recoveryPresented) {
                if let conflict = store.syncConflict {
                    VStack(spacing: 0) {
                        ConflictReview(conflict: conflict)
                        if TeamRecoveryStorageNativeFixture.fault != nil {
                            HStack {
                                Button("Block test storage") { do { try TeamRecoveryStorageNativeFixture.block(); storageStatus = "Storage blocked" } catch { storageStatus = error.localizedDescription } }.accessibilityIdentifier("blockNativeRecoveryStorage")
                                Button("Repair test storage") { do { try TeamRecoveryStorageNativeFixture.repair(); storageStatus = "Storage available" } catch { storageStatus = error.localizedDescription } }.accessibilityIdentifier("repairNativeRecoveryStorage")
                                Text(storageStatus).accessibilityIdentifier("nativeRecoveryStorageStatus")
                            }.padding(8)
                        }
                    }
                }
            }
            .sheet(isPresented: $draftsPresented) { SavedTeamDraftsView() }
            .onChange(of: store.syncConflict?.completionBatchReview, initial: true) { _, value in
                if ProcessInfo.processInfo.arguments.contains("--team-batch-recovery-blocked-sync"), value != nil { recoveryPresented = true }
            }
            .onChange(of: store.syncConflict?.completionReview, initial: true) { _, value in
                if ProcessInfo.processInfo.arguments.contains("--team-batch-recovery-blocked-sync"), value != nil { recoveryPresented = true }
            }
            .task {
                // Connectivity may discover the saved review before this window opens.
                if ProcessInfo.processInfo.arguments.contains("--team-batch-recovery-blocked-sync"), store.syncConflict == nil { await store.sync() }
            }
        } else if TeamTemplateNativeFixture.enabled {
            NavigationStack {
                Form {
                    NavigationLink("Open template library") { TemplateLibraryView() }.accessibilityIdentifier("openSharedTemplateFixture")
                    NavigationLink("Open team template library") { TeamTemplateLibraryView(teamID: TeamEditorNativeFixture.teamID) }.accessibilityIdentifier("openTeamTemplateLibraryFixture")
                    NavigationLink("Open private workflow run") { TemplateRunView(template: TeamTemplateNativeFixture.personal) }.accessibilityIdentifier("openPrivateWorkflowRunFixture")
                    NavigationLink("Open workflow recovery") { WorkflowShell(title: "Workflow recovery") { Form { SavedTeamWorkflowRequestLink() } } }.accessibilityIdentifier("openWorkflowRecoveryFixture")
                    NavigationLink("Open saved template request") { TeamTemplateLibraryView() }.accessibilityIdentifier("openSavedTeamTemplateFixture")
                }.navigationTitle("Team template test")
            }
        } else {
        TaskInspectorForm(taskID: TeamEditorNativeFixture.taskID)
             .safeAreaInset(edge: .top) {
                if ProcessInfo.processInfo.arguments.contains("--team-heading-testing") {
                    HStack {
                        if PersonalHeadingNativePeer.enabled {
                            Button("Pause personal support") { store.setPersonalHeadingSupportFixture(0) }.accessibilityIdentifier("pausePersonalHeadingSupport")
                            Button("Restore personal support") { store.setPersonalHeadingSupportFixture(1) }.accessibilityIdentifier("restorePersonalHeadingSupport")
                        } else {
                        Button("Pause heading support") { store.pauseTeamHeadingCapabilityFixture() }.accessibilityIdentifier("pauseTeamHeadingCapability")
                        }
                        Button("Undo task edit") { store.undo() }.disabled(store.undoStack.isEmpty).accessibilityIdentifier("undoTeamHeading")
                        Button("Redo task edit") { store.redo() }.disabled(store.redoStack.isEmpty).accessibilityIdentifier("redoTeamHeading")
                    }.padding(8)
                }
            }
            .safeAreaInset(edge: .bottom) { Button("Revoke test editing") { store.revokeTeamEditorNativeFixture() }.accessibilityIdentifier("revokeTeamEditorFixture") }
        }
    }
}
#endif
