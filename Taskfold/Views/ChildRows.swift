import SwiftUI
import AppKit

/// Child rows (`tasks.parent_id`) on the Mac: list nesting, the inspector back stack and the tree edits.
/// Everything here is reached only when `TaskTree.rowsEnabled` is true.

// MARK: - Workspace

extension Workspace {
    /// Project and Inbox lists in List layout nest children under their parent. Boards, Today, Upcoming, Calendar, labels,
    /// filters and search stay flat (a child shows a "↳ Parent" line there).
    var nestedRowsList: Bool {
        guard TaskTree.rowsEnabled else { return false }
        switch section { case .inbox, .project: break; default: return false }
        guard let scope = section.scope else { return false }
        return TaskLayout.resolved(store.viewValue(scope, field: "layout", fallback: .string("list")).text, for: scope) == .list
    }

    /// The row's indentation steps in a nested list; zero everywhere else.
    func rowIndent(_ task: Record) -> Int { nestedRowsList ? store.breadcrumb(of: task.id).count : 0 }

    /// Roots in list order, each followed by its expanded children, depth first. A collapsed parent hides its subtree.
    func nestedRows(_ roots: [Record]) -> [Record] {
        let includeCompleted = section.scope.map { store.viewValue($0, field: "include_completed", fallback: .bool(false)).flag } ?? false
        var result: [Record] = [], seen = Set<String>()
        func visit(_ row: Record, depth: Int) {
            guard seen.insert(TaskTree.key(row.id)).inserted else { return }
            result.append(row)
            guard expandedTasks.contains(row.id), depth < TaskTree.maximumAncestors else { return }
            for child in store.children(of: row.id) where includeCompleted || !child.completed || isLingering(child.id) { visit(child, depth: depth + 1) }
        }
        for root in roots { visit(root, depth: 0) }
        return result
    }

    /// In a nested list a child is not a list root: it is never reordered by the list's own drag, only by its parent.
    func isListRoot(_ id: String) -> Bool {
        return !(nestedRowsList && store.parent(of: id) != nil)
    }

    // MARK: Inspector back stack

    /// Moves the inspector to a child (or a parent) and remembers where it came from.
    func pushInspector(from current: String, to target: String) {
        guard taskRecord(target) != nil else { return }
        inspectorNavigating = true; defer { inspectorNavigating = false }
        if inspectorBackStack.last != current { inspectorBackStack.append(current) }
        open(target)
    }
    /// The "‹ Parent" button: back to the task the inspector came from.
    func popInspector() {
        inspectorNavigating = true; defer { inspectorNavigating = false }
        while let previous = inspectorBackStack.popLast() {
            if taskRecord(previous) != nil { open(previous); return }
        }
    }
    var inspectorBackTitle: String? { inspectorBackStack.last.flatMap { taskRecord($0)?.title } }

    // MARK: Tree edits

    @discardableResult
    private func applyTreeEdits(_ name: String, confirmation: String? = nil, _ plan: (TaskTree) throws -> [TaskTree.Edit]) -> Bool {
        do {
            let tasks = store.tasks
            let edits = try plan(TaskTree(tasks))
            guard !edits.isEmpty else { return true }
            var saved = false
            run(name) { withAnimation(layout) { saved = store.commitChildRows(TaskTree.mutations(edits, tasks: tasks)) } }
            if saved, let confirmation { confirm(confirmation) }
            return saved
        } catch { store.error = error.localizedDescription; return false }
    }

    /// The root shown just above `task` in its project section (or Inbox), in the list's manual order.
    func previousRoot(of task: Record) -> String? {
        let project = task.string("project_id"), sectionID = task.string("section_id")
        let siblings = store.tasks.filter {
            $0.string("project_id") == project && $0.string("section_id") == sectionID && !$0.completed
                && store.parent(of: $0.id) == nil
        }
        let key = project.isEmpty ? Placement.scope(.inbox) : Placement.group(project: project, section: sectionID)
        let ordered = arranged(siblings, key: key).map(\.id)
        guard let index = ordered.firstIndex(of: task.id), index > 0 else { return nil }
        return ordered[index - 1]
    }

    func canIndent(_ id: String) -> Bool {
        guard TaskTree.rowsEnabled, let task = taskRecord(id), !task.completed else { return false }
        let tree = TaskTree(store.tasks)
        if let parent = tree.parentID(of: id) { return tree.childIDs(of: parent).first.map { TaskTree.key($0) != TaskTree.key(id) } ?? false }
        return previousRoot(of: task) != nil
    }
    func canOutdent(_ id: String) -> Bool { TaskTree.rowsEnabled && store.parent(of: id) != nil }

    func indentTask(_ id: String) {
        guard let task = taskRecord(id) else { return }
        applyTreeEdits("Indent Task", confirmation: "Made “\(task.title)” a subtask") { tree in
            try tree.indent(id, previousSibling: tree.parentID(of: id) == nil ? previousRoot(of: task) : nil)
        }
    }
    func outdentTask(_ id: String) {
        guard let task = taskRecord(id) else { return }
        applyTreeEdits("Outdent Task", confirmation: "Moved “\(task.title)” up a level") { try $0.outdent(id) }
    }
    func makeTask(_ id: String) {
        guard let task = taskRecord(id) else { return }
        applyTreeEdits("Make Task", confirmation: "“\(task.title)” is now a task") { try $0.makeTask(id) }
    }
    /// Drag reorder inside one parent: `id` lands before (or, moving down, after) `anchor`.
    func reorderChild(_ id: String, relativeTo anchor: String) {
        guard id != anchor else { return }
        applyTreeEdits("Reorder Subtasks") { tree in
            guard let parent = tree.parentID(of: anchor), tree.parentID(of: id).map({ TaskTree.key($0) == TaskTree.key(parent) }) == true else { return [] }
            let siblings = tree.childIDs(of: parent).map(TaskTree.key)
            guard let from = siblings.firstIndex(of: TaskTree.key(id)), let to = siblings.firstIndex(of: TaskTree.key(anchor)) else { return [] }
            return try tree.move(id, under: parent, at: from < to ? .after(anchor) : .before(anchor))
        }
    }
    func moveChild(_ id: String, by offset: Int) {
        applyTreeEdits("Reorder Subtasks") { tree in
            guard let parent = tree.parentID(of: id) else { return [] }
            let siblings = tree.childIDs(of: parent)
            guard let from = siblings.firstIndex(where: { TaskTree.key($0) == TaskTree.key(id) }), siblings.indices.contains(from + offset) else { return [] }
            return try tree.move(id, under: parent, at: offset > 0 ? .after(siblings[from + offset]) : .before(siblings[from + offset]))
        }
    }

    /// Adds a subtask under `parentID`. The text parses like Quick Add, without a project or section (the child lives in the parent's).
    @discardableResult
    func addChild(to parentID: String, text input: String) -> String? {
        guard let parent = store.record("tasks", id: parentID) else { return nil }
        // A team subtask is created through the team RPCs; its labels, repeat, reminders and assignee use the team editors.
        let team = store.isTeamTask(parent)
        var task = team ? Record.task(user: store.userID, project: parent.string("project_id")) : captureTask(project: parent.string("project_id"), date: nil, sectionID: parent.string("section_id"), scope: .inbox)
        task["section_id"] = parent["section_id"]
        task["parent_id"] = .string(parent.id)
        task["child_order"] = .number(TaskTree(store.tasks).nextOrder(under: parent.id))
        let disabled: Set<String> = team ? ["project_id", "section_id", "planning", "labels", "recurrence", "reminder_specs", "assigned_to"] : ["project_id", "section_id", "planning"]
        let parsed = QuickEntry(input, disabled: disabled, context: quickEntryContext(project: task.string("project_id")), task: task)
        guard !parsed.title.isEmpty else { return nil }
        task = parsed.applying(to: task)
        // Parsing never moves the child out of its parent's container.
        task["project_id"] = parent["project_id"]; task["section_id"] = parent["section_id"]; task["parent_id"] = .string(parent.id)
        for value in parsed.updates["labels"]?.list ?? [] where !team && !store.labels.contains(where: { $0.name == value.text || $0.id == value.text }) {
            _ = store.save("labels", Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(store.userID), "name": value, "color": .string("#e31e4b")]))
        }
        var created = false
        run("Add Subtask") { withAnimation(layout) { created = team ? store.commitChildRows([Mutation(table: "tasks", recordID: task.id, method: "POST", fields: task.fields, insertOnly: true)]) : store.save("tasks", task) } }
        guard created else { return nil }
        expandedTasks.insert(parent.id)
        return task.id
    }
}

// MARK: - Inspector section

/// The inspector's "Subtasks" content: real child rows, the add field, reorder and structure actions.
struct ChildRowsList: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    let parentID: String
    /// Saves the parent's pending edits before the inspector moves to another task.
    let flush: () -> Bool
    let canAdd: Bool
    @State private var text = ""
    @State private var dropTarget: String?
    @FocusState private var addFocused: Bool
    @Environment(\.inspectorFieldRequest) private var fieldRequest

    private var children: [Record] { store.children(of: parentID) }
    private var atDepthLimit: Bool { store.breadcrumb(of: parentID).count >= TaskTree.maximumAncestors - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(children) { child in row(child) }
            if canAdd { addField }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("childRows")
        .onChange(of: fieldRequest, initial: true) { _, request in
            if request?.field == .subtask, canAdd, !atDepthLimit { DispatchQueue.main.async { addFocused = true } }
        }
    }

    private func row(_ child: Record) -> some View {
        TaskRowView(task: child, inInspector: true)
            .contentShape(.rect)
            .onTapGesture { open(child) }
            .overlay(alignment: .top) { if dropTarget == child.id { InsertionIndicator().offset(y: -4) } }
            .draggable(child.id)
            .dropDestination(for: String.self, action: { ids, _ in
                guard let dragged = ids.first, children.contains(where: { $0.id == dragged }) else { return false }
                workspace.reorderChild(dragged, relativeTo: child.id); return true
            }, isTargeted: { dropTarget = $0 ? child.id : (dropTarget == child.id ? nil : dropTarget) })
            .contextMenu { menu(child) }
            .accessibilityAction(named: "Open details") { open(child) }
            .accessibilityIdentifier("childRow-" + child.id)
    }

    private func open(_ child: Record) {
        guard flush() else { return }
        workspace.pushInspector(from: parentID, to: child.id)
    }

    @ViewBuilder private func menu(_ child: Record) -> some View {
        Button("Open Details") { open(child) }
        // A team viewer reads subtasks but cannot change them (`canAdd` is false for them).
        if canAdd { changeMenu(child) }
    }
    @ViewBuilder private func changeMenu(_ child: Record) -> some View {
        Divider()
        Button("Move Up", systemImage: "arrow.up") { workspace.moveChild(child.id, by: -1) }.disabled(children.first?.id == child.id)
        Button("Move Down", systemImage: "arrow.down") { workspace.moveChild(child.id, by: 1) }.disabled(children.last?.id == child.id)
        Button("Indent", systemImage: "increase.indent") { workspace.indentTask(child.id) }.disabled(!workspace.canIndent(child.id))
        Button("Outdent", systemImage: "decrease.indent") { workspace.outdentTask(child.id) }.disabled(!workspace.canOutdent(child.id))
        Button("Make it a Task", systemImage: "arrow.up.right.square") { workspace.makeTask(child.id) }.disabled(!workspace.canOutdent(child.id))
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { workspace.delete([child.id]) }
    }

    private var addField: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "plus").font(.body).foregroundStyle(DS.Palette.textTertiary).frame(width: DS.Space.xxxl, height: DS.Space.xxxl).accessibilityHidden(true)
            TextField("Add subtask", text: $text, prompt: Text(atDepthLimit ? "Subtasks can go ten levels deep" : "Add subtask"))
                .labelsHidden().textFieldStyle(.plain).focused($addFocused).disabled(atDepthLimit)
                .onSubmit(submit)
                .accessibilityIdentifier("addSubtask")
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Add", action: submit).controlSize(.small).accessibilityLabel("Add subtask").accessibilityIdentifier("addSubtaskButton")
            }
        }
        .padding(.horizontal, DS.Space.xs).frame(minHeight: DS.Size.rowMinHeight)
    }

    private func submit() {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, flush() else { return }
        if workspace.addChild(to: parentID, text: title) != nil { text = ""; addFocused = true }
    }
}
