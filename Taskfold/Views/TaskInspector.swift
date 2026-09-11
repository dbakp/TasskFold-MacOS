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
                    Button("Next Week") { workspace.reschedule(workspace.selection, to: Dates.day(Workspace.next(weekday: 2)), label: "next week") }
                    Divider()
                    Button("Remove Date") { workspace.reschedule(workspace.selection, to: nil, label: "") }
                }
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
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    let taskID: String
    @State private var draft = Record()
    @State private var original = Record()
    @State private var subtask = ""
    @State private var comment = ""
    @State private var pastedImageName: String?
    @State private var importing = false
    @State private var preview: URL?
    @State private var confirmDelete = false
    @State private var saveTask: Task<Void, Never>?
    @State private var declined = Set<String>()
    @FocusState private var titleFocused: Bool
    /// Parsing runs while the title differs from the saved one; Return (or leaving the field) applies it.
    private var suggestions: QuickEntry? {
        guard draft.title != original.title else { return nil }
        let parsed = QuickEntry(draft.title, disabled: declined)
        return parsed.tokens.isEmpty ? nil : parsed
    }

    private var current: Record? { store.record("tasks", id: taskID) }
    private func text(_ key: String) -> Binding<String> {
        Binding(get: { draft.string(key) }, set: { draft[key] = $0.isEmpty && ["project_id", "section_id", "due_time"].contains(key) ? .null : .string($0) })
    }
    var body: some View {
        Form {
            Section {
                TextField("Title", text: text("title"), prompt: Text("What needs doing?"), axis: .vertical)
                    .labelsHidden().multilineTextAlignment(.leading)
                    .font(.title3.weight(.semibold)).textFieldStyle(.plain).lineLimit(1...4)
                    .focused($titleFocused).onSubmit { applySuggestions(); saveNow() }
                    .onChange(of: titleFocused) { _, focused in if !focused { applySuggestions() } }
                    .accessibilityIdentifier("taskTitle")
                if let suggestions {
                    VStack(alignment: .leading, spacing: 4) {
                        ScrollView(.horizontal) {
                            QuickEntryChips(tokens: suggestions.tokens, decline: { token in _ = declined.insert(token.group) }, returnFocus: { titleFocused = true }).padding(.vertical, 2)
                        }.scrollIndicators(.hidden).scrollClipDisabled()
                        Text("Return applies these · ✕ keeps the words in the title").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .transition(.opacity)
                }
                TextField("Notes", text: text("description"), prompt: Text("Notes"), axis: .vertical).labelsHidden().multilineTextAlignment(.leading).textFieldStyle(.plain).lineLimit(2...10).foregroundStyle(.secondary)
                HStack {
                    Button(draft.completed ? "Reopen" : "Complete", systemImage: draft.completed ? "arrow.uturn.backward.circle" : "checkmark.circle") { if let current { workspace.complete(current) } }
                        .controlSize(.small)
                    Spacer()
                    if draft.completed, let at = ISO8601DateFormatter().date(from: draft.string("completed_at")) { Text("Completed \(at.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Plan") {
                Toggle("Due date", isOn: Binding(get: { draft.due != nil }, set: { draft["due_date"] = $0 ? .string(Dates.day(Date())) : .null; if !$0 { draft["due_time"] = .null } }))
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
                        quickDate("Today", Date()); quickDate("Tomorrow", Calendar.current.date(byAdding: .day, value: 1, to: Date())!); quickDate("Next week", Workspace.next(weekday: 2))
                    }.controlSize(.small)
                }
                Picker("Priority", selection: Binding(get: { draft.priority }, set: { draft["priority"] = .number(Double($0)) })) {
                    ForEach(1...4, id: \.self) { n in Label(n == 4 ? "None" : "Priority \(n)", systemImage: "flag.fill").foregroundStyle(Color.priority(n)).tag(n) }
                }
                Picker("Project", selection: text("project_id")) {
                    Text("Inbox").tag("")
                    ForEach(store.projects) { Text($0.name).tag($0.id) }
                }.onChange(of: draft.string("project_id")) { old, new in if old != new { draft["section_id"] = .null } }
                if !draft.string("project_id").isEmpty {
                    Picker("Section", selection: text("section_id")) {
                        Text("No section").tag("")
                        ForEach(store.rows("sections").filter { $0.string("project_id") == draft.string("project_id") }) { Text($0.name).tag($0.id) }
                    }
                }
                RecurrenceEditor(task: $draft)
                if draft.due != nil {
                    Label(draft.string("due_time").isEmpty ? "Reminder at 8:00 AM" : "Reminder at the due time", systemImage: "bell").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Labels") {
                if store.labels.isEmpty { Text("Create labels from the sidebar.").foregroundStyle(.secondary) }
                ForEach(store.labels) { label in
                    Toggle(isOn: Binding(get: { draft["labels"].list.contains(.string(label.id)) || draft["labels"].list.contains(.string(label.name)) }, set: { enabled in
                        var labels = draft["labels"].list.filter { $0 != .string(label.id) && $0 != .string(label.name) }; if enabled { labels.append(.string(label.name)) }; draft["labels"] = .array(labels)
                    })) { Label(label.name, systemImage: "tag.fill").foregroundStyle(Color.project(label.string("color"))) }
                }
            }
            Section("Subtasks") {
                ForEach(Array(draft["subtasks"].list.enumerated()), id: \.offset) { index, value in
                    HStack {
                        Button { var list = draft["subtasks"].list; var item = value.object; item["completed"] = .bool(!(item["completed"]?.flag ?? false)); list[index] = .object(item); draft["subtasks"] = .array(list) } label: {
                            Image(systemName: value.object["completed"]?.flag == true ? "checkmark.circle.fill" : "circle").foregroundStyle(value.object["completed"]?.flag == true ? Color.accentColor : .secondary)
                        }.buttonStyle(.borderless).accessibilityLabel("Toggle subtask")
                        TextField("Subtask", text: Binding(get: { draft["subtasks"].list[index].object["title"]?.text ?? "" }, set: { title in var list = draft["subtasks"].list; var item = list[index].object; item["title"] = .string(title); list[index] = .object(item); draft["subtasks"] = .array(list) }), prompt: Text("Subtask"))
                            .labelsHidden().textFieldStyle(.plain)
                        Button { var list = draft["subtasks"].list; list.remove(at: index); draft["subtasks"] = .array(list) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.borderless).accessibilityLabel("Remove subtask")
                    }
                }
                HStack { TextField("Subtask", text: $subtask, prompt: Text("Add a subtask")).labelsHidden().textFieldStyle(.plain).onSubmit(addSubtask); Button("Add", action: addSubtask).controlSize(.small).disabled(subtask.trimmingCharacters(in: .whitespaces).isEmpty) }
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
        .onAppear { load(); if draft.title.isEmpty { titleFocused = true } }
        .onChange(of: workspace.titleFocusRequest) { _, _ in titleFocused = true }
        .onChange(of: draft) { _, _ in scheduleSave() }
        .onChange(of: current) { _, value in
            // Untouched fields follow sync; the user's in-progress edits win.
            guard let value else { return }
            var merged = value
            for (key, field) in draft.fields where original.fields[key] != field { merged[key] = field }
            original = value
            if merged != draft { draft = merged }
        }
        .onDisappear { saveTask?.cancel(); saveNow() }
    }
    private func quickDate(_ title: String, _ date: Date) -> some View {
        Button(title) { draft["due_date"] = .string(Dates.day(date)) }.buttonStyle(.bordered)
    }
    private func load() { if let current { draft = current; original = current } }
    /// Moves accepted quick-entry pieces out of the title into their fields, like the iOS editor's save.
    private func applySuggestions() {
        guard let parsed = suggestions, parsed.hasSuggestions else { return }
        withAnimation(workspace.layout) {
            draft["title"] = .string(parsed.title)
            for (key, value) in parsed.updates { draft[key] = value }
        }
        for value in parsed.updates["labels"]?.list ?? [] where !store.labels.contains(where: { $0.name == value.text }) {
            _ = store.save("labels", Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(store.userID), "name": value, "color": .string("#e31e4b")]))
        }
        declined = []
    }
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(for: .milliseconds(600)); guard !Task.isCancelled else { return }; saveNow() }
    }
    private func saveNow() {
        guard draft != original, let current else { return }
        var merged = current
        for (key, value) in draft.fields where original.fields[key] != value { merged[key] = value }
        merged["title"] = .string(merged.title.trimmingCharacters(in: .whitespacesAndNewlines))
        if merged.title.isEmpty { merged["title"] = original["title"] }
        if merged["is_recurring"].flag && merged.due == nil { merged["due_date"] = .string(Dates.day(Date())) }
        guard merged != current else { original = merged; draft = merged; return }
        if workspace.save("tasks", merged, name: "Edit Task") {
            original = merged; draft = merged
            if merged.due != nil && !UserDefaults.standard.bool(forKey: "remindersAsked") {
                UserDefaults.standard.set(true, forKey: "remindersAsked")
                Task { await store.enableNotifications() }
            }
        }
    }
    private func addSubtask() {
        let title = subtask.trimmingCharacters(in: .whitespacesAndNewlines); guard !title.isEmpty else { return }
        var list = draft["subtasks"].list; list.append(.object(["id": .string(UUID().uuidString.lowercased()), "title": .string(title), "completed": .bool(false)])); draft["subtasks"] = .array(list); subtask = ""
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
    private var pattern: Record { Record(task["recurrence_pattern"].object) }
    private func field(_ key: String, _ value: JSON) { var p = task["recurrence_pattern"].object; p[key] = value; task["recurrence_pattern"] = .object(p) }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Toggle("Repeat task", isOn: Binding(get: { task["is_recurring"].flag }, set: { enabled in
                task["is_recurring"] = .bool(enabled)
                if enabled && pattern.string("type").isEmpty { task["recurrence_pattern"] = .object(["type": .string("daily"), "interval": .number(1)]) }
            }))
            if task["is_recurring"].flag {
                Picker("Frequency", selection: Binding(get: { pattern.string("type") }, set: { field("type", .string($0)) })) {
                    Text("Daily").tag("daily"); Text("Weekly").tag("weekly"); Text("Monthly").tag("monthly"); Text("Custom days").tag("custom")
                }
                Stepper("Every \(max(1, pattern["interval"].integer))", value: Binding(get: { max(1, pattern["interval"].integer) }, set: { field("interval", .number(Double($0))) }), in: 1...365)
                if pattern.string("type") == "weekly" {
                    HStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { day in
                            let on = pattern["daysOfWeek"].list.contains(.number(Double(day)))
                            Toggle(Calendar.current.veryShortWeekdaySymbols[day], isOn: Binding(get: { on }, set: { enabled in var days = pattern["daysOfWeek"].list.filter { $0 != .number(Double(day)) }; if enabled { days.append(.number(Double(day))) }; field("daysOfWeek", .array(days)) }))
                                .toggleStyle(.button).controlSize(.small)
                                .accessibilityLabel(Calendar.current.weekdaySymbols[day])
                        }
                    }
                }
                if pattern.string("type") == "monthly" { Stepper("Day \(max(1, pattern["dayOfMonth"].integer))", value: Binding(get: { max(1, pattern["dayOfMonth"].integer) }, set: { field("dayOfMonth", .number(Double($0))) }), in: 1...31) }
                Toggle("End date", isOn: Binding(get: { !pattern.string("endDate").isEmpty }, set: { field("endDate", $0 ? .string(Dates.day(Date())) : .null) }))
                if !pattern.string("endDate").isEmpty { DatePicker("Ends", selection: Binding(get: { Dates.parse(pattern.string("endDate")) ?? Date() }, set: { field("endDate", .string(Dates.day($0))) }), displayedComponents: .date) }
                Toggle("Limit occurrences", isOn: Binding(get: { pattern["count"].integer > 0 }, set: { field("count", $0 ? .number(10) : .null) }))
                if pattern["count"].integer > 0 { Stepper("\(pattern["count"].integer) remaining", value: Binding(get: { pattern["count"].integer }, set: { field("count", .number(Double($0))) }), in: 1...999) }
                Text("Completing a recurring task creates the next occurrence. Monthly dates clamp to the last day of shorter months.").font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            LabeledContent("Repeat", value: task["is_recurring"].flag ? (pattern.string("type").isEmpty ? "Custom" : pattern.string("type").capitalized) : "Never")
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
