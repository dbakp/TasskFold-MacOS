import SwiftUI
import UniformTypeIdentifiers

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
    @State private var voiceRequest: VoiceDraftRequest?
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
                        Button("Dictate tasks", systemImage: "mic") {
                            guard store.workflowReady(binding) else { message = store.error; return }
                            #if os(iOS)
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            #endif
                            voiceRequest = VoiceDraftRequest(workspace: WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration), original: text)
                        }.accessibilityIdentifier("openVoiceDraft")
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
        .sheet(item: $voiceRequest) { request in
            VoiceDraftView(request: request) { proposed in
                guard store.workflowReady(request.workspace), text == request.original else { return false }
                text = proposed; return true
            }
        }
        .onChange(of: store.workspaceGeneration) { _, _ in voiceRequest = nil }
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
    @State private var editingTemplate: Record?
    @State private var importing = false
    @State private var imported: ImportedWorkflowTemplate?
    @State private var exportRequest: ExportedWorkflowTemplate?
    @State private var readingFile: UUID?
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
                        .contextMenu { Button("Edit template") { editingTemplate = row }; Button("Export template…") { export(row) }; Button("Delete template", role: .destructive) { deleting = row } }
                        .swipeActions(edge:.leading) { Button("Edit") { editingTemplate=row }.tint(.accentColor) }
                    }
                }
                Section {
                    Button { importing = true } label: { Label("Import template…", systemImage: "square.and.arrow.down") }
                        .accessibilityIdentifier("importWorkflowTemplate")
                    Text("Review a workflow file before saving a private copy. Importing does not create any tasks.").font(.caption).foregroundStyle(.secondary)
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
        .safeAreaInset(edge: .bottom) {
            if readingFile != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Opening template…")
                    Spacer()
                    Button("Cancel") { readingFile = nil }
                }.padding().background(.regularMaterial)
            }
        }
        .onDisappear { readingFile = nil }
        .onChange(of: store.workspaceGeneration) { _, _ in
            readingFile = nil; importing = false; imported = nil; exportRequest = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard store.workflowReady(binding) else { message = store.error; return }
            do {
                let url = try result.get(), request = UUID()
                readingFile = request; message = nil
                Task {
                    do {
                        let file = try await Task.detached(priority: .userInitiated) {
                            try WorkflowTemplateFile.read(url)
                        }.value
                        guard readingFile == request else { return }
                        readingFile = nil
                        guard store.workflowReady(binding) else { message = store.error; return }
                        imported = ImportedWorkflowTemplate(file: file)
                    } catch {
                        guard readingFile == request else { return }
                        readingFile = nil; message = error.localizedDescription
                    }
                }
            } catch {
                if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
            }
        }
        .sheet(item: $exportRequest) { request in TemplateFileExportReview(request: request, binding: binding) }
        .sheet(item: $imported) { request in TemplateFileReview(request: request, binding: binding) }
        .sheet(item: $selected) { TemplateRunView(template: $0) }
        .sheet(item: $editingTemplate) { TemplateDefinitionEditor(template: $0) }
        .confirmationDialog("Delete this template?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete template", role: .destructive) { if store.workflowReady(binding), let row = deleting { workspace.run("Delete Template") { store.remove(WorkflowTemplate.table, row.id) } }; deleting = nil }
        } message: { Text("Tasks and projects created from it stay saved.") }
    }
    private func export(_ row: Record) {
        guard store.workflowReady(binding) else { message = store.error; return }
        do {
            guard let current = store.record(WorkflowTemplate.table, id: row.id) else { throw AppFailure(message: "This template is no longer available.") }
            let file = try WorkflowTemplateFile(name: current.name, document: current["document"])
            exportRequest = ExportedWorkflowTemplate(file: file, data: try file.encoded())
            message = nil
        } catch { message = error.localizedDescription }
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

private struct ExportedWorkflowTemplate: Identifiable {
    let id = UUID()
    let file: WorkflowTemplateFile
    let data: Data
}

private struct TemplateFileExportReview: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: ExportedWorkflowTemplate
    let binding: WorkspaceBinding?
    @State private var exporting = false
    @State private var message: String?
    var body: some View {
        WorkflowShell(title: "Export template") {
            if binding?.matches(account: store.userID, generation: store.workspaceGeneration) == true {
            Form {
                Section {
                    Text(request.file.name).font(.headline)
                    Text("This file includes workflow notes, label names and relative dates. Review its content before sharing it with someone.").foregroundStyle(.secondary)
                    Text("Account details, discussions, attachments, assignments and completion history are excluded.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Workflow preview") { TemplateDefinitionPreview(document: request.file.template.document, scope: "export") }
                Section {
                    Button("Save file…", action: beginExport).accessibilityIdentifier("saveTemplateFile")
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                if let message { Text(message).foregroundStyle(.red) }
            }.formStyle(.grouped)
            } else {
                ContentUnavailableView("Workspace changed", systemImage: "person.crop.circle", description: Text("Reopen templates in your current workspace."))
            }
        }
        .fileExporter(isPresented: $exporting, document: WorkspaceDocument(data: request.data), contentType: .json, defaultFilename: "Taskfold-template") { result in
            switch result {
            case .success: dismiss()
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
            }
        }
    }
    private func beginExport() {
        guard store.workflowReady(binding) else { message = store.error; return }
        exporting = true
    }
}


private struct ImportedWorkflowTemplate: Identifiable {
    let id = UUID()
    let file: WorkflowTemplateFile
}

private struct TemplateFileReview: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(Workspace.self) private var workspace
    #endif
    let request: ImportedWorkflowTemplate
    let binding: WorkspaceBinding?
    @State private var name = ""
    @State private var message: String?
    var body: some View {
        WorkflowShell(title: "Review template") {
            if binding?.matches(account: store.userID, generation: store.workspaceGeneration) == true {
            Form {
                Section {
                    TextField("Template name", text: $name).accessibilityIdentifier("importTemplateName")
                    Text("Only this reusable definition will be added. Start a run later to choose its destination and dates.").font(.callout).foregroundStyle(.secondary)
                }
                Section("Workflow preview") {
                    TemplateDefinitionPreview(document: request.file.template.document, scope: "import")
                }
                Section {
                    Button("Add to templates", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 160)
                        .accessibilityIdentifier("confirmImportTemplate")
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                if let message { Text(message).foregroundStyle(.red).accessibilityIdentifier("templateImportError") }
            }.formStyle(.grouped)
            } else {
                ContentUnavailableView("Workspace changed", systemImage: "person.crop.circle", description: Text("Reopen templates in your current workspace."))
            }
        }.onAppear { name = request.file.name }
    }
    private func save() {
        guard store.workflowReady(binding) else { message = store.error; return }
        do {
            let file = try WorkflowTemplateFile(name: name, document: request.file.template.document)
            let row = Record(["id": .string(request.id.uuidString.lowercased()), "user_id": .string(store.userID), "name": .string(file.name), "document": file.template.document])
            var saved = false
            #if os(macOS)
            workspace.run("Import Template") { saved = store.save(WorkflowTemplate.table, row) }
            #else
            saved = store.save(WorkflowTemplate.table, row)
            #endif
            if saved { dismiss() } else { message = store.error }
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
    @State private var editingDefinition = false
    var body: some View {
        Group {
            if editingDefinition {
                TemplateDefinitionEditor(template:template,onCancel:{editingDefinition=false})
            } else {
        WorkflowShell(title: "Use template") {
            Form {
                Text(template.name).font(.title2.bold())
                Button("Edit template",systemImage:"pencil") { editingDefinition=true }.accessibilityIdentifier("editTemplateDefinition").disabled(pending != nil)
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
                        Button { apply(definition) } label: { Text("Create workflow").frame(maxWidth:.infinity,minHeight:44) }
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("applyWorkflowTemplate")
                    }
                } else { ContentUnavailableView("Template needs an update", systemImage: "arrow.down.app", description: Text("Update Taskfold to use this template. Its definition is still saved.")) }
                if let message { Text(message).foregroundStyle(.red) }
            }.formStyle(.grouped)
        }.onAppear { if binding == nil { binding = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration); name = template.name; project = "__choose__" } }
            }
        }
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

struct TemplateDefinitionEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(Workspace.self) private var workspace
    #endif
    let template: Record
    var onSaved: () -> Void = {}
    var onCancel: (() -> Void)? = nil
    @State private var supported: Bool
    @State private var baseline: Record
    @State private var latest: Record?
    @State private var name: String
    @State private var document: JSON
    @State private var binding: WorkspaceBinding?
    @State private var message: String?
    @State private var editing: TemplateEditing.TaskItem?
    @State private var removing: TemplateEditing.TaskItem?
    @State private var refreshing = false
    @State private var discard = false
    init(template: Record, onSaved: @escaping () -> Void = {}, onCancel: (() -> Void)? = nil) {
        self.template=template;self.onSaved=onSaved;self.onCancel=onCancel;_supported=State(initialValue:(try? WorkflowTemplate(document:template["document"])) != nil);_baseline=State(initialValue:template);_name=State(initialValue:template.name);_document=State(initialValue:template["document"])
    }
    private var changed: Bool { name != baseline.name || document != baseline["document"] }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Template name",text:$name).accessibilityIdentifier("editTemplateName")
                    Label("Existing runs stay unchanged",systemImage:"shield.lefthalf.filled").font(.callout).foregroundStyle(.secondary)
                    Text("Edit the reusable definition here. These changes apply only to workflows you create later.").font(.caption).foregroundStyle(.secondary)
                }
                if supported {
                    organization("projects",title:"Projects")
                    organization("sections",title:"Sections")
                    Section("Tasks and subtasks") {
                        ForEach(TemplateEditing.tasks(document)) { item in
                            HStack(alignment:.top) {
                                Button { editing=item } label: {
                                    VStack(alignment:.leading,spacing:4) {
                                        Text(item.record.title).font(.headline)
                                        if !item.record.string("description").isEmpty { Text(item.record.string("description")).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                    }.frame(maxWidth:.infinity,minHeight:44,alignment:.leading).contentShape(.rect)
                                }.buttonStyle(.plain).padding(.leading,CGFloat(min(item.depth,5))*12).accessibilityIdentifier("editTemplateTask-"+item.id)
                                Menu {
                                    Button("Edit details") { editing=item }
                                    Button("Add subtask") { addTask(parent:item) }.disabled(item.depth>=10)
                                    Button("Move up") { change { try TemplateEditing.moving(document,item:item,delta:-1) } }.disabled((item.path.last ?? item.root)==0)
                                    Button("Move down") { change { try TemplateEditing.moving(document,item:item,delta:1) } }.disabled((item.path.last ?? item.root)+1>=item.siblingCount)
                                    Button("Delete task",role:.destructive) { removing=item }.disabled(item.path.isEmpty && document.object["kind"]?.text == "task")
                                } label: { Image(systemName:"ellipsis.circle").frame(minWidth:44,minHeight:44) }.accessibilityLabel("Actions for "+item.record.title)
                            }
                        }
                        if document.object["kind"]?.text != "task" {
                            Button("Add task",systemImage:"plus") { addTask(parent:nil) }.accessibilityIdentifier("addTemplateTask")
                        }
                    }
                    Section("Refresh definition") {
                        Button("Replace from a source…",systemImage:"arrow.triangle.2.circlepath") { refreshing=true }.accessibilityIdentifier("refreshTemplateSource")
                        Text("Choose a current project, section or task and review the replacement. It stays in this draft until Save.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView("Template needs an update",systemImage:"arrow.down.app",description:Text("Its definition is preserved. Use a newer Taskfold version to edit it."))
                }
                if let current=store.record(WorkflowTemplate.table,id:template.id), current["name"] != baseline["name"] || current["document"] != baseline["document"] {
                    Section("Changed on another device") {
                        Text("Your draft is kept here. Compare the latest definition before choosing what to save.").font(.callout).foregroundStyle(.secondary)
                        Button("Review latest template") { latest=current }.accessibilityIdentifier("reviewLatestTemplate")
                    }
                }
                if store.record(WorkflowTemplate.table,id:template.id) == nil {
                    Section("Template removed") {
                        Text("Your draft is still here. Save it as a new template to keep it without restoring the removed identity.").font(.callout).foregroundStyle(.secondary)
                        Button("Save draft as new template",action:saveCopy).disabled(!supported).accessibilityIdentifier("saveTemplateDraftCopy")
                    }
                }
                if let message { Text(message).foregroundStyle(.red).accessibilityIdentifier("templateEditError") }
            }
            .navigationTitle("Edit template")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancel") { if changed { discard=true } else { cancel() } }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement:.confirmationAction) { Button("Save",action:save).disabled(!supported || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).keyboardShortcut("s",modifiers:.command).accessibilityIdentifier("saveTemplateDefinition") }
            }
            .sheet(item:$editing) { item in
                TemplateTaskDefinitionEditor(item:item,document:document) { fields in
                    document = try TemplateEditing.changing(document,item:item,fields:fields)
                }
            }
            .sheet(item:$latest) { current in
                NavigationStack {
                    List {
                        Section("My draft · \(name)") { TemplateDefinitionPreview(document:document, scope:"draft") }
                        Section("Latest · \(current.name)") { TemplateDefinitionPreview(document:current["document"], scope:"latest") }
                        Section {
                            Button("Keep my draft") {
                                guard store.workflowReady(binding),let now=store.record(WorkflowTemplate.table,id:template.id),now["name"]==current["name"],now["document"]==current["document"] else { message="The template changed again. Reopen the latest review.";latest=nil;return }
                                baseline=current;latest=nil;save()
                            }.disabled(!supported || (try? WorkflowTemplate(document:current["document"])) == nil)
                            Button("Use latest in editor") { guard store.workflowReady(binding) else { latest=nil;return };baseline=current;name=current.name;document=current["document"];supported=(try? WorkflowTemplate(document:current["document"])) != nil;latest=nil }
                            Text("Keep my draft saves the definition shown above. Existing runs stay unchanged. Unsupported newer definitions need a newer Taskfold version.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.navigationTitle("Review template changes")
                    .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Cancel") { latest=nil } } }
                }
                #if os(macOS)
                .frame(width:620,height:680)
                #endif
            }
            .sheet(isPresented:$refreshing) {
                TemplateSourceReplacement(document:document) { replacement in document=replacement }
            }
            .confirmationDialog("Discard template changes?",isPresented:$discard,titleVisibility:.visible) { Button("Discard changes",role:.destructive) { cancel() } }
            .confirmationDialog("Delete this task and its subtasks?",isPresented:Binding(get:{removing != nil},set:{if !$0 { removing=nil }}),titleVisibility:.visible) {
                Button("Delete task",role:.destructive) { if let item=removing { change { try TemplateEditing.changing(document,item:item,fields:[:],remove:true) } };removing=nil }
            } message: { Text("Existing runs keep their saved tasks.") }
            .interactiveDismissDisabled(changed)
            .onAppear { if binding == nil { binding=WorkspaceBinding(account:store.userID,generation:store.workspaceGeneration) } }
            .onChange(of:store.workspaceGeneration) { _,_ in dismiss() }
        }
        #if os(macOS)
        .frame(minWidth:580,idealWidth:660,minHeight:500,idealHeight:700)
        #endif
    }
    @ViewBuilder private func organization(_ table: String,title: String) -> some View {
        let rows=document.object[table,default:.null].list.map { Record($0.object) }
        if !rows.isEmpty {
            Section(title) { ForEach(rows) { row in
                TextField(table == "projects" ? "Project name" : "Section name",text:Binding(get:{document.object[table,default:.null].list.first{$0.object["id"]?.text==row.id}?.object["name"]?.text ?? ""},set:{ value in
                    var root=document.object,list=root[table,default:.null].list
                    if let index=list.firstIndex(where:{$0.object["id"]?.text==row.id}) { var fields=list[index].object;fields["name"] = .string(value);list[index] = .object(fields);root[table] = .array(list);document = .object(root) }
                })).accessibilityIdentifier("templateOrganization-"+row.id)
            } }
        }
    }
    private func cancel() { if let onCancel { onCancel() } else { dismiss() } }
    private func addTask(parent:TemplateEditing.TaskItem?) {
        do {
            let previous=Set(TemplateEditing.tasks(document).map{$0.record.id})
            document=try TemplateEditing.adding(document,parent:parent)
            editing=TemplateEditing.tasks(document).first{!previous.contains($0.record.id)};message=nil
        } catch { message=error.localizedDescription }
    }
    private func change(_ work: () throws -> JSON) { do { document=try work();message=nil } catch { message=error.localizedDescription } }
    private func saveCopy() {
        guard store.workflowReady(binding),supported else { message=store.error;return }
        do {
            let copy=Record(["id":.string(UUID().uuidString.lowercased()),"user_id":.string(store.userID),"name":.string(name),"document":document])
            let savedCopy=try TemplateEditing.edit(original:copy,name:name,document:document,current:copy)
            var saved=false
            #if os(macOS)
            workspace.run("Save Template Copy") { saved=store.save(WorkflowTemplate.table,savedCopy) }
            #else
            saved=store.save(WorkflowTemplate.table,savedCopy)
            #endif
            if saved { onSaved();dismiss() } else { message=store.error }
        } catch { message=error.localizedDescription }
    }
    private func save() {
        guard store.workflowReady(binding) else { message=store.error;return }
        do {
            let row=try TemplateEditing.edit(original:baseline,name:name,document:document,current:store.record(WorkflowTemplate.table,id:template.id))
            var saved=false
            #if os(macOS)
            workspace.run("Edit Template") { saved=store.save(WorkflowTemplate.table,row,baseline:baseline) }
            #else
            saved=store.save(WorkflowTemplate.table,row,baseline:baseline)
            #endif
            if saved { onSaved();dismiss() } else { message=store.error }
        } catch { message=error.localizedDescription }
    }
}

private struct TemplateTaskDefinitionEditor: View {
    @Environment(\.dismiss) private var dismiss
    let item: TemplateEditing.TaskItem
    let document: JSON
    let onSave: ([String:JSON]) throws -> Void
    @State private var title: String
    @State private var notes: String
    @State private var priority: Int
    @State private var project: String
    @State private var section: String
    @State private var estimate: String
    @State private var planned: String
    @State private var deadline: String
    @State private var message: String?
    init(item: TemplateEditing.TaskItem,document:JSON,onSave:@escaping ([String:JSON]) throws -> Void) {
        self.item=item;self.document=document;self.onSave=onSave
        _title=State(initialValue:item.record.title);_notes=State(initialValue:item.record.string("description"));_priority=State(initialValue:item.record.priority)
        _project=State(initialValue:item.record.string("project_id"));_section=State(initialValue:item.record.string("section_id"))
        func number(_ key:String)->String { if case .number(let value)=item.record[key] { return String(Int(value)) };return "" }
        _estimate=State(initialValue:number("duration_minutes"));_planned=State(initialValue:number("planned_offset"));_deadline=State(initialValue:number("deadline_offset"))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Task details") {
                    TextField("Task name",text:$title).accessibilityIdentifier("templateTaskTitle")
                    TextField("Notes",text:$notes,axis:.vertical).lineLimit(3...8).accessibilityIdentifier("templateTaskNotes")
                    Picker("Priority",selection:$priority) { ForEach(1...4,id:\.self) { Text($0==4 ? "None" : "Priority \($0)").tag($0) } }
                    if item.path.isEmpty && document.object["kind"]?.text == "project" {
                        Picker("Project",selection:$project) { ForEach(document.object["projects",default:.null].list.map{Record($0.object)}) { Text($0.name).tag($0.id) } }.onChange(of:project){_,_ in section=""}
                        Picker("Section",selection:$section) { Text("No section").tag("");ForEach(document.object["sections",default:.null].list.map{Record($0.object)}.filter{$0.string("project_id")==project}) { Text($0.name).tag($0.id) } }
                    }
                    TextField("Estimate in minutes",text:$estimate).accessibilityIdentifier("templateTaskEstimate")
                }
                Section("Relative schedule") {
                    TextField("Planned day offset",text:$planned).accessibilityIdentifier("templateTaskPlannedOffset")
                    TextField("Deadline day offset",text:$deadline).accessibilityIdentifier("templateTaskDeadlineOffset")
                    Text("Day 0 is the workflow’s starting day. Use 2 for two days later or −1 for the day before. Leave a field empty to keep that date unscheduled. Estimates are 1 minute to 7 days.").font(.caption).foregroundStyle(.secondary)
                }
                if let message { Text(message).foregroundStyle(.red) }
            }.formStyle(.grouped).accessibilityIdentifier("templateTaskDefinitionForm").navigationTitle("Template task")
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement:.confirmationAction) { Button("Save") {
                    do {
                        var fields:[String:JSON]=["title":.string(title.trimmingCharacters(in:.whitespacesAndNewlines)),"description":.string(notes),"priority":.number(Double(priority))]
                        if item.path.isEmpty && document.object["kind"]?.text == "project" { fields["project_id"] = .string(project);fields["section_id"] = section.isEmpty ? .null : .string(section) }
                        for (key,text) in [("duration_minutes",estimate),("planned_offset",planned),("deadline_offset",deadline)] {
                            if text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { fields[key] = .null }
                            else if let value=Int(text), (key=="duration_minutes" ? (1...10080).contains(value) : (-365000...365000).contains(value)) { fields[key] = .number(Double(value)) }
                            else { throw AppFailure(message:"Use whole minutes from 1 to 10080, and whole day offsets between −365000 and 365000.") }
                        }
                        try onSave(fields);dismiss()
                    } catch { message=error.localizedDescription }
                }.disabled(title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).keyboardShortcut("s",modifiers:.command).accessibilityIdentifier("saveTemplateTask") }
            }
        }
        #if os(macOS)
        .frame(width:560,height:560)
        #endif
    }
}

private struct TemplateSourceReplacement: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let document: JSON
    let onReplace: (JSON)->Void
    @State private var source=""
    @State private var preview: JSON?
    @State private var message:String?
    private var kind:WorkflowTemplate.Kind { WorkflowTemplate.Kind(rawValue:document.object["kind"]?.text ?? "") ?? .project }
    private var sources:[Record] { switch kind { case .project:return store.allProjects;case .section:return store.rows("sections");case .task:return store.tasks } }
    var body:some View {
        NavigationStack {
            List {
                Section("Choose source") {
                    Picker("Source",selection:$source) { Text("Choose a source").tag("");ForEach(sources) { Text(kind == .task ? $0.title : $0.name).tag($0.id) } }.onChange(of:source){_,_ in preview=nil}.accessibilityIdentifier("replacementTemplateSource")
                    Button("Review replacement") { do { preview=try WorkflowTemplate.capture(kind:kind,id:source,snapshot:store.snapshot).document;message=nil } catch { message=error.localizedDescription } }.disabled(source.isEmpty).accessibilityIdentifier("reviewTemplateReplacement")
                }
                if let preview {
                    Section("Current definition") { TemplateDefinitionPreview(document:document, scope:"draft") }
                    Section("Replacement definition") { TemplateDefinitionPreview(document:preview, scope:"replacement") }
                    Section { Button("Use replacement in draft",role:.destructive) { onReplace(preview);dismiss() }.accessibilityIdentifier("acceptTemplateReplacement");Text("This replaces the definition in your draft. Save the template to apply it. Existing runs stay unchanged.").font(.caption).foregroundStyle(.secondary) }
                }
                if let message { Text(message).foregroundStyle(.red) }
            }.navigationTitle("Review replacement")
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width:620,height:660)
        #endif
    }
}

private struct TemplatePreviewRow<Value>: Identifiable {
    let id:String
    let value:Value
}

private struct TemplateDefinitionPreview: View {
    let document:JSON
    let scope:String
    var body:some View {
        if (try? WorkflowTemplate(document:document)) != nil {
        Text(TemplateEditing.summary(document)).font(.headline)
        ForEach(ProjectOrganization.outline(document.object["projects",default:.null].list.map{Record($0.object)}).map { TemplatePreviewRow(id:scope+":project:"+$0.id,value:$0) }) { row in
            let item = row.value
            VStack(alignment:.leading,spacing:4) {
                Label(item.project.name,systemImage:"folder").foregroundStyle(Color.project(item.project.string("color")))
                if !item.project.string("description").isEmpty { Text(item.project.string("description")) }
                if !item.project.string("parent_id").isEmpty { Text("Inside "+(document.object["projects",default:.null].list.first{$0.object["id"]?.text==item.project.string("parent_id")}?.object["name"]?.text ?? "project")).font(.caption).foregroundStyle(.secondary) }
            }.padding(.leading,CGFloat(min(item.depth,5))*10)
        }
        ForEach(OrganizationOrder.sorted(document.object["sections",default:.null].list.map{Record($0.object)}).map { TemplatePreviewRow(id:scope+":section:"+$0.id,value:$0) }) { row in Label(row.value.name,systemImage:"rectangle.split.3x1") }
        ForEach(TemplateEditing.tasks(document).map { TemplatePreviewRow(id:scope+":task:"+$0.id,value:$0) }) { row in
            let item = row.value
            VStack(alignment:.leading,spacing:5) {
                Text(item.record.title).font(.headline).accessibilityIdentifier("templatePreview-"+scope+"-task-"+item.id)
                if !item.record.string("description").isEmpty { Text(item.record.string("description")) }
                Text(TemplateEditing.taskSummary(item.record)).font(.caption).foregroundStyle(.secondary)
            }.padding(.leading,CGFloat(min(item.depth,5))*10)
        }
        } else { Text("This definition needs a newer Taskfold version. Its saved content is preserved.").foregroundStyle(.secondary) }
    }
}
