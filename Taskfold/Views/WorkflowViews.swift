import SwiftUI

/// Workspace-bound workflow tools. Every preview stays local until the user saves.

struct WorkflowShell<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        NavigationStack {
            content.navigationTitle(title)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 580, idealWidth: 640, minHeight: 500, idealHeight: 620)
        #endif
    }
}

struct ArchivedProjectsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(Workspace.self) private var workspace
    #endif
    @State private var editor: Record?
    var body: some View {
        WorkflowShell(title: "Archived projects") {
            List {
                Section { Text("Archived work stays saved. Restore a project to bring its tasks back to daily lists, widgets and reminders.").foregroundStyle(.secondary) }
                if store.archivedProjects.isEmpty { ContentUnavailableView("Nothing archived", systemImage: "archivebox", description: Text("Keep finished projects without cluttering your active work.")) }
                ForEach(store.archivedProjects) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "archivebox").foregroundStyle(Color.project(item.project.string("color")))
                            Text(item.project.name).font(.headline)
                            Spacer()
                            #if os(macOS)
                            Button("Open") { workspace.section = .project(item.id); dismiss() }
                            #else
                            NavigationLink("Open") { TaskScreen(scope: .project(item.id)) }
                            #endif
                        }
                        Text(workflowCount(store.tasks.filter { $0.string("project_id") == item.id }.count, "task", prefix: "Saved: ")).font(.caption).foregroundStyle(.secondary)
                        if item.project.string("user_id") == store.userID {
                            if item.project["is_archived"].flag {
                                Button("Restore project") {
                                    #if os(macOS)
                                    workspace.run("Restore Project") { _ = store.archiveProject(item.project, archived: false) }
                                    #else
                                    _ = store.archiveProject(item.project, archived: false)
                                    #endif
                                }.accessibilityIdentifier("restoreProject-" + item.id)
                            } else { Text("Restore its parent project first, or move this project to the top level.").font(.caption).foregroundStyle(.secondary) }
                            Button("Edit project") { editor = item.project }
                        } else { Text("The project owner manages archiving.").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.leading, CGFloat(item.depth) * 12).padding(.vertical, 5)
                }
            }
        }.sheet(item: $editor) { NamedEditor(table: "projects", record: $0) }
    }
}

struct MultiLineCaptureView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(Workspace.self) private var workspace
    #endif
    @State var text = ""
    @State var project = ""
    var onSaved: () -> Void = {}
    @State private var recognize = true
    @State private var lines: [MultiLineCapture.Line] = []
    @State private var excluded = Set<Int>()
    @State private var binding: WorkspaceBinding?
    @State private var message: String?
    @State private var pending: [Mutation]?
    private var chosen: [MultiLineCapture.Line] { lines.filter { !excluded.contains($0.id) } }
    var body: some View {
        WorkflowShell(title: "Add multiple tasks") {
            Form {
                if lines.isEmpty {
                    Section("One task per line") {
                        TextEditor(text: $text).frame(minHeight: 150).accessibilityLabel("Task lines").accessibilityIdentifier("multiLineText")
                        Text("Paste a checklist or write a few lines. You’ll review every task before adding it.").font(.caption).foregroundStyle(.secondary)
                        Picker("Destination", selection: $project) {
                            Text("Inbox").tag("")
                            ForEach(store.projects) { Text($0.name).tag($0.id) }
                        }
                        Toggle("Recognize dates, priorities and labels", isOn: $recognize)
                        Button("Review tasks", action: preview).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("reviewMultiLine")
                    }
                } else {
                    Section(workflowCount(lines.count, "task", prefix: "Review ")) {
                        Text("Edit titles or exclude a line. Dates, priorities and destinations below are the values that will be saved.").font(.caption).foregroundStyle(.secondary)
                        ForEach($lines) { $line in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    TextField("Task title", text: Binding(get: { line.task.title }, set: { line.task["title"] = .string($0) })).accessibilityLabel("Task on line \(line.number)").accessibilityIdentifier("multiLineTitle-\(line.number)")
                                    Toggle("Include task on line \(line.number)", isOn: Binding(get: { !excluded.contains(line.id) }, set: { if $0 { excluded.remove(line.id) } else { excluded.insert(line.id) } })).labelsHidden().accessibilityLabel("Include task on line \(line.number)")
                                }
                                Text(details(line.task)).font(.caption).foregroundStyle(.secondary)
                                ForEach(line.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.disabled(pending != nil)
                    }
                    Section {
                        Button("Edit original text") { lines = []; excluded = []; pending = nil; message = nil }
                        Button(workflowCount(chosen.count, "task", prefix: "Add "), action: save).disabled(chosen.isEmpty || chosen.contains { $0.task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).accessibilityIdentifier("saveMultiLine")
                    }
                }
                if let message { Text(message).foregroundStyle(.red).accessibilityIdentifier("workflowError") }
            }.formStyle(.grouped)
        }.onAppear { if binding == nil { binding = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration) } }
    }
    private func details(_ task: Record) -> String {
        var parts = [store.record("projects", id: task.string("project_id"))?.name ?? "Inbox"]
        if !task.string("due_date").isEmpty { parts.append(task.string("due_date") + (task.string("due_time").isEmpty ? "" : " " + task.string("due_time"))) }
        if task.priority < 4 { parts.append("Priority \(task.priority)") }
        parts += task["labels"].list.map { "@" + (store.record("labels", id: $0.text)?.name ?? $0.text) }
        return parts.joined(separator: " · ")
    }
    private func preview() {
        guard store.workflowReady(binding) else { message = store.error; return }
        do { lines = try MultiLineCapture.preview(text, account: store.userID, project: project, context: store.quickEntryContext(project: project), recognize: recognize); message = lines.isEmpty ? "Add at least one task line." : nil }
        catch { message = error.localizedDescription }
    }
    private func save() {
        guard store.workflowReady(binding) else { message = store.error; return }
        do {
            guard store.workflowDestinationsAvailable(chosen) else { throw AppFailure(message: "A project or section changed. Review the original text again before saving.") }
            if pending == nil { pending = try store.workflowChanges(chosen) }
            var saved = false
            #if os(macOS)
            workspace.run("Add Multiple Tasks") { saved = store.commit(pending!) }
            #else
            saved = store.commit(pending!)
            #endif
            if saved { store.error = nil; onSaved(); dismiss() } else { message = store.error }
        } catch { message = error.localizedDescription }
    }
}

struct TemplateLibraryView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @State private var sourceKind = "project"
    @State private var source = ""
    @State private var name = ""
    @State private var binding: WorkspaceBinding?
    @State private var message: String?
    @State private var selected: Record?
    @State private var deleting: Record?
    private var sources: [Record] {
        switch sourceKind {
        case "section": return OrganizationOrder.sorted(store.rows("sections").filter { row in store.allProjects.contains { $0.id == row.string("project_id") } })
        case "task": return store.tasks
        default: return store.allProjects
        }
    }
    var body: some View {
        WorkflowShell(title: "Templates") {
            List {
                Section {
                    Text("Save a workflow once, then start fresh each time. New runs keep structure, notes, labels and relative dates; completion, discussion, files and assignments stay with the originals.").font(.callout).foregroundStyle(.secondary)
                }
                Section("Your templates") {
                    if store.workflowTemplates.isEmpty { Text("No templates yet. Save a project, section or task below.").foregroundStyle(.secondary) }
                    ForEach(store.workflowTemplates) { row in
                        Button { selected = row } label: {
                            HStack { Image(systemName: "square.stack.3d.up"); VStack(alignment: .leading) { Text(row.name).font(.headline); Text(summary(row)).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }.contentShape(.rect)
                        }.buttonStyle(.plain).accessibilityIdentifier("workflowTemplate-" + row.id)
                        .contextMenu { Button("Delete template", role: .destructive) { deleting = row } }
                    }
                }
                Section("Save a workflow") {
                    Picker("Type", selection: $sourceKind) { Text("Project and subprojects").tag("project"); Text("Section").tag("section"); Text("Task").tag("task") }.onChange(of: sourceKind) { _, _ in source = "" }
                    Picker("Source", selection: $source) {
                        Text("Choose a source").tag("")
                        ForEach(sources) { row in Text(sourceKind == "task" ? row.title : row.name).tag(row.id) }
                    }
                    .accessibilityIdentifier("templateSource")
                    TextField("Template name", text: $name).accessibilityIdentifier("templateName")
                    Button("Save template", action: capture).disabled(source.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("saveWorkflowTemplate")
                }
                if let message { Text(message).foregroundStyle(.red) }
            }
        }.onAppear { if binding == nil { binding = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration) }; if source.isEmpty { source = sources.first?.id ?? "" } }
        .sheet(item: $selected) { TemplateRunView(template: $0) }
        .confirmationDialog("Delete this template?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete template", role: .destructive) { if store.workflowReady(binding), let row = deleting { workspace.run("Delete Template") { store.remove(WorkflowTemplate.table, row.id) } }; deleting = nil }
        } message: { Text("Tasks and projects created from it stay saved.") }
    }
    private func summary(_ row: Record) -> String {
        guard let template = try? WorkflowTemplate(document: row["document"]) else { return "Update Taskfold to use this template" }
        return [workflowCount(template.projects.count, "project"), workflowCount(template.sections.count, "section"), workflowCount(template.tasks.count, "task")].joined(separator: " · ")
    }
    private func capture() {
        guard store.workflowReady(binding) else { message = store.error; return }
        do {
            guard sources.contains(where: { $0.id == source }), let kind = WorkflowTemplate.Kind(rawValue: sourceKind) else { throw AppFailure(message: "Choose an available source.") }
            let template = try WorkflowTemplate.capture(kind: kind, id: source, snapshot: store.snapshot)
            let row = Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(store.userID), "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)), "document": template.document])
            guard row.name.count <= 160 else { throw AppFailure(message: "Use up to 160 characters for the template name.") }
            var saved = false
            workspace.run("Save Template") { saved = store.save(WorkflowTemplate.table, row) }
            if saved { name = ""; source = ""; message = nil } else { message = store.error }
        } catch { message = error.localizedDescription }
    }
}

struct TemplateRunView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(Workspace.self) private var workspace
    #endif
    let template: Record
    @State private var name = ""
    @State private var project = ""
    @State private var dated = false
    @State private var date = Date()
    @State private var binding: WorkspaceBinding?
    @State private var message: String?
    @State private var pending: [Mutation]?
    @State private var run = UUID()
    var body: some View {
        WorkflowShell(title: "Use template") {
            Form {
                Text(template.name).font(.title2.bold())
                if let definition = try? WorkflowTemplate(document: template["document"]) {
                    Section("New workflow") {
                        if definition.kind == .project { TextField("New project name", text: $name).accessibilityIdentifier("templateProjectName") }
                        else {
                            Picker("Destination", selection: $project) { if definition.kind == .task { Text("Inbox").tag("") }; Text("Choose a project").tag("__choose__"); ForEach(store.projects) { Text($0.name).tag($0.id) } }
                        }
                        Toggle("Schedule from a start date", isOn: $dated)
                        if dated { DatePicker("Start date", selection: $date, displayedComponents: .date) }
                        Text(dated ? "Dated tasks keep their spacing from the first planned day, or first deadline. Tasks without dates stay unscheduled." : "New tasks start without planned dates or deadlines.").font(.caption).foregroundStyle(.secondary)
                    }.disabled(pending != nil)
                    Section("Preview") {
                        ForEach(definition.tasks.prefix(25)) { Text($0.title) }
                        if definition.tasks.count > 25 { Text("And \(definition.tasks.count - 25) more tasks").foregroundStyle(.secondary) }
                        Button("Create workflow") { apply(definition) }.accessibilityIdentifier("applyWorkflowTemplate")
                    }
                } else { ContentUnavailableView("Template needs an update", systemImage: "arrow.down.app", description: Text("Update Taskfold to use this template. Its definition is still saved.")) }
                if let message { Text(message).foregroundStyle(.red) }
            }.formStyle(.grouped)
        }.onAppear { if binding == nil { binding = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration); name = template.name; project = "__choose__" } }
    }
    private func apply(_ definition: WorkflowTemplate) {
        guard store.workflowReady(binding), store.record(WorkflowTemplate.table, id: template.id)?["document"] == template["document"] else { message = "The workspace or template changed. Reopen it before creating a workflow."; return }
        do {
            let target = project == "__choose__" ? "" : project
            guard definition.kind == .project || (definition.kind == .task && project != "__choose__") || !target.isEmpty else { throw AppFailure(message: "Choose a destination first.") }
            guard target.isEmpty || store.projects.contains(where: { $0.id == target }) else { throw AppFailure(message: "This destination is no longer active.") }
            if pending == nil { pending = try definition.instantiate(account: store.userID, name: name, targetProject: target, start: dated ? date : nil, labels: store.labels, run: run) }
            var saved = false
            #if os(macOS)
            workspace.run("Create Workflow") { saved = store.commit(pending!) }
            #else
            saved = store.commit(pending!)
            #endif
            if saved { store.error = nil; dismiss() } else { message = store.error }
        } catch { message = error.localizedDescription }
    }
}

private func workflowCount(_ count: Int, _ noun: String, prefix: String = "") -> String { prefix + String(count) + " " + noun + (count == 1 ? "" : "s") }
