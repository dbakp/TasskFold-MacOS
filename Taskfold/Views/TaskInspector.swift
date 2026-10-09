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
                Button("Complete", systemImage: "checkmark.circle") { workspace.toggle(workspace.selection) }
                Menu("Reschedule") {
                    Button("Today") { workspace.reschedule(workspace.selection, to: Dates.day(Date()), label: "today") }
                    Button("Tomorrow") { workspace.reschedule(workspace.selection, to: Dates.day(Calendar.current.date(byAdding: .day, value: 1, to: Date())!), label: "tomorrow") }
                    Button("Next Week") { if let day = store.datePhraseDay("next week") { workspace.reschedule(workspace.selection, to: Dates.day(day), label: "next week") } }.disabled(store.datePhrasePreferences == nil)
                    Divider()
                    Button("Remove Date") { workspace.reschedule(workspace.selection, to: nil, label: "") }
                }
                Button("Edit Deadlines…", systemImage: "flag.checkered") { workspace.editDeadlines(workspace.selection) }.accessibilityIdentifier("bulkDeadlines")
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
    @State private var draft = Record()
    @State private var notePin: Bool?
    @State private var original = Record()
    @State private var editingGeneration: JSON = .null
    @State private var titleParsingBaseline = ""
    @State private var workspaceBinding: WorkspaceBinding?
    @State private var subtask = ""
    @State private var comment = ""
    @State private var pastedImageName: String?
    @State private var importing = false
    @State private var preview: URL?
    @State private var confirmDelete = false
    @State private var saveTask: Task<Void, Never>?
    @State private var declined = Set<String>()
    @State private var titleSelection: TextSelection?
    @State private var referenceChoices: [String: String] = [:]
    @FocusState private var titleFocused: Bool
    /// Parsing runs while the title differs from the saved one; Return (or leaving the field) applies it.
    private var suggestions: QuickEntry? {
        guard draft.title != titleParsingBaseline else { return nil }
        let nested = Workspace.subtaskPath(taskID) != nil
        let parsed = QuickEntry(draft.title, disabled: nested ? declined.union(["project_id", "section_id"]) : declined,
            context: workspace.quickEntryContext(project: workspace.assignmentProject(draft, contextID: taskID)).choosingReferences(referenceChoices), task: draft)
        return parsed.tokens.isEmpty && parsed.warnings.isEmpty ? nil : parsed
    }

    private var current: Record? { workspace.taskRecord(taskID) }
    private var currentGeneration: JSON {
        let root = Workspace.subtaskPath(taskID)?.first ?? taskID
        return store.record("tasks", id: root)?["task_generation"] ?? .null
    }
    private func text(_ key: String) -> Binding<String> {
        Binding(get: { draft.string(key) }, set: { draft[key] = $0.isEmpty && ["project_id", "section_id", "due_time", "time_zone"].contains(key) ? .null : .string($0) })
    }
    var body: some View {
        Form {
            Section {
                TextField("Title", text: text("title"), selection: $titleSelection, prompt: Text("What needs doing?"), axis: .vertical)
                    .labelsHidden().multilineTextAlignment(.leading)
                    .font(.title3.weight(.semibold)).textFieldStyle(.plain).lineLimit(1...4)
                    .focused($titleFocused)
                    .onChange(of: titleFocused) { _, focused in if !focused { applySuggestions(); saveNow() } }
                    .accessibilityIdentifier("taskTitle")
                    .referenceCompletions(text: text("title"), selection: $titleSelection, choices: $referenceChoices, declined: $declined, context: workspace.quickEntryContext(project: workspace.assignmentProject(draft, contextID: taskID)), focused: titleFocused, task: draft, excluded: Workspace.subtaskPath(taskID) == nil ? [] : ["project_id", "section_id"], onChoose: { applyReferenceChoices(); titleFocused = true }, submit: { applySuggestions(); saveNow() }, submitsFromKeyboard: true)
                if let suggestions {
                    VStack(alignment: .leading, spacing: 4) {
                        QuickEntryChips(tokens: suggestions.tokens, decline: { token in _ = declined.insert(token.group) }, returnFocus: { titleFocused = true }).padding(.vertical, 2)
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
                TextField("Notes", text: text("description"), prompt: Text("Notes"), axis: .vertical).labelsHidden().multilineTextAlignment(.leading).textFieldStyle(.plain).lineLimit(2...10).foregroundStyle(.secondary).accessibilityIdentifier("taskDescription")
                if store.record("tasks", id: taskID) != nil {
                    Toggle("Show notes in widgets", isOn: Binding(get: { notePin ?? store.isPinnedNote(taskID) }, set: { notePin = $0; saveNow() })).accessibilityIdentifier("pinTaskNotes")
                    Text("Pin only text you want visible on your desktop or Home Screen. Choose it in the Pinned note widget; hide its details for privacy.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(draft.completed ? "Reopen" : "Complete", systemImage: draft.completed ? "arrow.uturn.backward.circle" : "checkmark.circle") { if let current { workspace.complete(current) } }
                        .controlSize(.small)
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
                    AssigneeMenu(task: draft, contextID: taskID, showsName: true) { draft["assigned_to"] = $0.isEmpty ? .null : .string($0) }
                }
                Picker("Project", selection: text("project_id")) {
                    Text("Inbox").tag("")
                    ForEach(store.projects) { Text($0.name).tag($0.id) }
                }.onChange(of: draft.string("project_id")) { old, new in if old != new && new != original.string("project_id") { draft = Workspace.clearingAssignments(draft); draft["section_id"] = .null } }
                if !draft.string("project_id").isEmpty {
                    Picker("Section", selection: text("section_id")) {
                        Text("No section").tag("")
                        ForEach(store.rows("sections").filter { $0.string("project_id") == draft.string("project_id") }) { Text($0.name).tag($0.id) }
                    }
                }
                RecurrenceEditor(task: $draft)
                Button("Reminders…", systemImage: "bell") { showingReminders = true }.accessibilityIdentifier("taskReminders")
            }
            Section("Labels") {
                if store.labels.isEmpty { Text("Create labels from the sidebar.").foregroundStyle(.secondary) }
                ForEach(store.labels) { label in
                    Toggle(isOn: Binding(get: { TaskLabels.normalized(draft["labels"].list, labels: store.labels).contains(.string(label.id)) }, set: { enabled in
                        var labels = TaskLabels.normalized(draft["labels"].list, labels: store.labels).filter { $0 != .string(label.id) }; if enabled { labels.append(.string(label.id)) }; draft["labels"] = .array(labels)
                    })) { Label(label.name, systemImage: "tag.fill").foregroundStyle(Color.project(label.string("color"))) }
                }
            }
            if workspace.taskDepth(taskID) < 2 {
            Section("Subtasks") {
                ForEach(Array(draft["subtasks"].list.enumerated()), id: \.offset) { index, value in
                    HStack {
                        Button { var list = draft["subtasks"].list; var item = value.object; item["completed"] = .bool(!(item["completed"]?.flag ?? false)); list[index] = .object(item); draft["subtasks"] = .array(list) } label: {
                            Image(systemName: value.object["completed"]?.flag == true ? "checkmark.circle.fill" : "circle").foregroundStyle(value.object["completed"]?.flag == true ? Color.taskfold : .secondary)
                        }.buttonStyle(.borderless).accessibilityLabel("Toggle subtask")
                        TextField("Subtask", text: Binding(get: { draft["subtasks"].list[index].object["title"]?.text ?? "" }, set: { title in var list = draft["subtasks"].list; var item = list[index].object; item["title"] = .string(title); list[index] = .object(item); draft["subtasks"] = .array(list) }), prompt: Text("Subtask"))
                            .labelsHidden().textFieldStyle(.plain)
                        Button {
                            saveNow()
                            workspace.expandedTasks.insert(taskID)
                            workspace.open(workspace.childID(parent: taskID, value: value, index: index))
                        } label: { Image(systemName: "sidebar.trailing") }
                            .buttonStyle(.borderless).accessibilityLabel("Open subtask details")
                        Button { var list = draft["subtasks"].list; list.remove(at: index); draft["subtasks"] = .array(list) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.borderless).accessibilityLabel("Remove subtask")
                    }
                }
                HStack { TextField("Subtask", text: $subtask, prompt: Text("Add a subtask")).accessibilityIdentifier("addSubtask").labelsHidden().textFieldStyle(.plain).onSubmit(addSubtask); Button("Add", action: addSubtask).controlSize(.small).disabled(subtask.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
            }
            Section("Attachments") {
                ForEach(Array(draft["attachments"].list.enumerated()), id: \.offset) { index, value in
                    HStack {
                        Button { openAttachment(Record(value.object)) } label: { Label(value.object["name"]?.text ?? "Attachment", systemImage: "paperclip") }.buttonStyle(.link)
                        Spacer()
                        Button { var list = draft["attachments"].list; list.remove(at: index); draft["attachments"] = .array(list) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.borderless).accessibilityLabel("Remove attachment")
                    }
                }
                Button("Attach a File…", systemImage: "doc.badge.plus") { importing = true }
            }
            Section("Comments") {
                ForEach(Array(draft["comments"].list.enumerated()), id: \.offset) { index, value in
                    let row = Record(value.object)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.string("authorName").isEmpty ? "Comment" : row.string("authorName")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Button { var list = draft["comments"].list; list.remove(at: index); draft["comments"] = .array(list) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.borderless).accessibilityLabel("Delete comment")
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
                }.disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section {
                if let created = ISO8601DateFormatter().date(from: draft.string("created_at")) { LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .shortened)) }
                Button("Delete Task…", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete “\(draft.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { workspace.delete([taskID]) }
        } message: { Text("You can undo this from the Edit menu.") }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                try attach(try Data(contentsOf: url), name: url.lastPathComponent, type: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
            } catch { store.error = error.localizedDescription }
        }
        .quickLookPreview($preview)
        .onAppear { workspaceBinding = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration); editingGeneration = currentGeneration; load(); if draft.title.isEmpty { titleFocused = true } }
        .task(id: suggestions?.updates["project_id"]?.text ?? workspace.assignmentProject(draft, contextID: taskID)) { _ = try? await store.refreshProjectMembers(suggestions?.updates["project_id"]?.text ?? workspace.assignmentProject(draft, contextID: taskID)) }
        .onChange(of: workspace.titleFocusRequest) { _, _ in titleFocused = true }
        .sheet(isPresented: $showingReminders) {
            NavigationStack {
                TaskReminderEditor(task: $draft).onAppear { draft = store.applyingReminderDefault(draft, previous: original) }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingReminders = false } } }
            }.frame(minWidth: 550, minHeight: 620)
        }
        .onChange(of: draft) { _, _ in scheduleSave() }
        .onChange(of: currentGeneration) { _, value in
            if draft == original && notePin == nil { editingGeneration = value; load() }
            else {
                saveTask?.cancel()
                store.error = "This task was deleted and restored while you were editing. Your draft is still here; reopen the current task before saving."
            }
        }
        .onChange(of: current) { _, value in
            // Untouched fields follow sync; the user's in-progress edits win.
            guard workspaceBinding?.matches(account: store.userID, generation: store.workspaceGeneration) == true, editingGeneration == currentGeneration, let value else { return }
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
        .onDisappear { saveTask?.cancel(); titleFocused = false; applySuggestions(); saveNow() }
    }
    private func quickDate(_ title: String, _ date: Date) -> some View {
        Button(title) { draft["due_date"] = .string(Dates.day(date)) }.buttonStyle(.bordered)
    }
    private func load() { if let current { draft = current; original = current; titleParsingBaseline = current.title } }
    /// Moves accepted quick-entry pieces out of the title into their fields, like the iOS editor's save.
    private func applySuggestions() {
        guard workspaceBinding?.matches(account: store.userID, generation: store.workspaceGeneration) == true, current != nil else { return }
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
        guard workspaceBinding?.matches(account: store.userID, generation: store.workspaceGeneration) == true, current != nil else { return }
        let referenceGroups: Set<String> = ["project_id", "section_id", "assigned_to", "labels"]
        let excluded = Set(QuickEntry.groups).subtracting(referenceGroups).union(declined).union(Workspace.subtaskPath(taskID) == nil ? [] : ["project_id", "section_id"])
        let parsed = QuickEntry(draft.title, disabled: excluded, context: workspace.quickEntryContext(project: workspace.assignmentProject(draft, contextID: taskID)).choosingReferences(referenceChoices), task: draft)
        draft = parsed.applying(to: draft)
        for value in parsed.updates["labels"]?.list ?? [] where !store.labels.contains(where: { $0.id == value.text || $0.name == value.text }) {
            _ = store.save("labels", Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(store.userID), "name": value, "color": .string("#e31e4b")]))
        }
        titleSelection = TextSelection(insertionPoint: draft.title.endIndex)
        saveNow()
    }
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(for: .milliseconds(600)); guard !Task.isCancelled else { return }; saveNow() }
    }
    private func saveNow() {
        guard workspaceBinding?.matches(account: store.userID, generation: store.workspaceGeneration) == true else { return }
        guard draft != original || notePin != nil, let current else { return }
        guard editingGeneration == currentGeneration else {
            store.error = "This task was deleted and restored while you were editing. Your draft is still here; reopen the current task before saving."
            return
        }
        var merged = current
        for (key, value) in draft.fields where original.fields[key] != value { merged[key] = value }
        merged["title"] = .string(merged.title.trimmingCharacters(in: .whitespacesAndNewlines))
        if merged.title.isEmpty { merged["title"] = original["title"] }
        if merged["is_recurring"].flag && merged.due == nil { merged["due_date"] = .string(Dates.day(Date())) }
        merged = store.applyingReminderDefault(merged, previous: original)
        guard merged != current || notePin != nil else { original = merged; draft = merged; return }
        var saved = false
        if let notePin {
            workspace.run("Edit Pinned Note") { saved = store.saveTaskWithNotePin(merged, pin: notePin, baseline: original) }
            self.notePin = nil
        } else { saved = workspace.save("tasks", merged, name: "Edit Task", baseline: original) }
        if saved { original = merged; draft = merged }
    }
    private func addSubtask() {
        guard workspace.taskDepth(taskID) < 2 else { return }
        let title = subtask.trimmingCharacters(in: .whitespacesAndNewlines); guard !title.isEmpty else { return }
        var list = draft["subtasks"].list; list.append(.object(["id": .string(UUID().uuidString.lowercased()), "title": .string(title), "completed": .bool(false)])); draft["subtasks"] = .array(list); subtask = ""; saveNow(); workspace.expandedTasks.insert(taskID)
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
            let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(safeName)")
            do { try data.write(to: url, options: .atomic); preview = url } catch { store.error = error.localizedDescription }
        } else if let url = URL(string: value), url.scheme == "https" { NSWorkspace.shared.open(url) }
        else { store.error = "This attachment cannot be opened." }
    }
}

/// Recurrence editing inline in the inspector, using the shared pattern vocabulary.
struct RecurrenceEditor: View {
    @Binding var task: Record
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) { RecurrenceFields(task: $task) } label: {
            LabeledContent("Repeat", value: task["is_recurring"].flag ? Recurrence.summary(Recurrence.effective(task)) : "Never")
        }.accessibilityIdentifier("taskRepeat")
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
        for key in ["daysOfWeek", "weekday", "weekdayOrdinal", "dayOfMonth", "monthOfYear"] { p.removeValue(forKey: key) }
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
                    for key in ["weekday", "weekdayOrdinal", "dayOfMonth", "monthOfYear"] { field(key, .null) }
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
                Picker("Repeat on", selection: Binding(get: { pattern["weekdayOrdinal"] != .null }, set: { useWeekday in
                    field("weekdayOrdinal", useWeekday ? .number(1) : .null)
                    field("weekday", useWeekday ? .number(Double(Calendar(identifier: .gregorian).component(.weekday, from: task.due ?? Date()) - 1)) : .null)
                    field("dayOfMonth", useWeekday ? .null : .number(Double(Calendar(identifier: .gregorian).component(.day, from: task.due ?? Date()))))
                })) { Text("Day of month").tag(false); Text("Weekday of month").tag(true) }.accessibilityIdentifier("repeatMonthlyMode")
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
            if ["monthly", "yearly"].contains(pattern.string("type")), pattern["weekdayOrdinal"] == .null, !followsCompletionDay {
                RepeatStepper(title: "Day \(Recurrence.number(pattern["dayOfMonth"], in: 1...31) ?? Calendar(identifier: .gregorian).component(.day, from: task.due ?? Date()))", value: Binding(get: { Recurrence.number(pattern["dayOfMonth"], in: 1...31) ?? Calendar(identifier: .gregorian).component(.day, from: task.due ?? Date()) }, set: { field("dayOfMonth", .number(Double($0))) }), range: 1...31, identifier: "repeatDayOfMonth")
            }
            Toggle("End date", isOn: Binding(get: { !pattern.string("endDate").isEmpty }, set: { field("endDate", $0 ? .string(task.string("due_date").isEmpty ? Dates.day(Date()) : task.string("due_date")) : .null); task["recurrence_end_date"] = .null })).accessibilityIdentifier("repeatEndDateEnabled")
            if !pattern.string("endDate").isEmpty { DatePicker("Ends (inclusive)", selection: Binding(get: { Dates.parse(pattern.string("endDate")) ?? Date() }, set: { field("endDate", .string(Dates.day($0))) }), displayedComponents: .date).accessibilityIdentifier("repeatEndDate") }
            Toggle("Limit occurrences", isOn: Binding(get: { pattern["count"].integer > 0 }, set: { field("count", $0 ? .number(10) : .null) })).accessibilityIdentifier("repeatCountEnabled")
            if pattern["count"].integer > 0 { RepeatStepper(title: "\(pattern["count"].integer) occurrences remaining", value: Binding(get: { pattern["count"].integer }, set: { field("count", .number(Double($0))) }), range: 1...999, identifier: "repeatCount") }
            Text("Completing creates one next occurrence. Shorter months use their last day; months without a fifth chosen weekday are skipped. The occurrence limit includes this task.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let date = Dates.next(task, completion: Date()) {
                Text("If completed today: " + date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("repeatNextPreview")
            } else { Text("No next occurrence within this rule’s limits.").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("repeatNextPreview") }
        }
    }
    private var followsCompletionDay: Bool { pattern["fromCompletion"].flag && pattern["dayOfMonth"] == .null && pattern["monthOfYear"] == .null && pattern["weekdayOrdinal"] == .null }
    private var unit: String {
        let singular = ["daily":"day", "weekly":"week", "monthly":"month", "yearly":"year", "custom":"day"][pattern.string("type")] ?? "interval"
        return pattern["interval"].integer > 1 ? singular + "s" : singular
    }
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
