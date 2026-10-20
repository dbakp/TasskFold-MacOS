import SwiftUI

struct SubtaskOrganizerButton: View {
    @Binding var children: JSON
    let taskID: String
    var baseDepth = 0
    @State private var showing = false
    var body: some View {
        Button("Organize subtasks", systemImage: "list.bullet.indent") { showing = true }
            .accessibilityIdentifier("organizeSubtasks")
            .sheet(isPresented: $showing) { SubtaskOrganizer(children: $children, taskID: taskID, baseDepth: baseDepth) }
    }
}

private struct SubtaskOrganizer: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var children: JSON
    let taskID: String
    let baseDepth: Int
    @State private var source: JSON
    @State private var originalTaskID: String
    @State private var draft: JSON
    @State private var binding: WorkspaceBinding?
    @State private var loadError: String?
    @State private var message: String?
    @State private var newTitle = ""
    @State private var addingTo: String?
    @State private var addingChild = false
    @State private var removing: SubtaskTree.Item?
    @State private var childTitle = ""

    init(children: Binding<JSON>, taskID: String, baseDepth: Int) {
        _children = children; self.taskID = taskID; self.baseDepth = baseDepth
        _source = State(initialValue: children.wrappedValue)
        _originalTaskID = State(initialValue: taskID)
        do { _draft = State(initialValue: try SubtaskTree.prepared(children.wrappedValue)); _loadError = State(initialValue: nil) }
        catch { _draft = State(initialValue: .array([])); _loadError = State(initialValue: error.localizedDescription) }
    }
    private var items: [SubtaskTree.Item] { SubtaskTree.outline(draft) }
    var body: some View {
        NavigationStack {
            Form {
                if let loadError { Section { Text(loadError).foregroundStyle(.secondary) } }
                else {
                    Section {
                        ForEach(items) { item in
                            HStack(alignment: .center, spacing: 8) {
                                Button {
                                    draft = SubtaskTree.changing(draft, id: item.id, fields: ["completed": .bool(!item.record.completed)])
                                } label: {
                                    Image(systemName: item.record.completed ? "checkmark.circle.fill" : "circle")
                                        .frame(minWidth: 32, minHeight: 36).contentShape(Rectangle())
                                }.buttonStyle(.borderless)
                                .accessibilityLabel((item.record.completed ? "Reopen " : "Complete ") + item.record.title)
                                .accessibilityValue(item.record.completed ? "Completed" : "Not completed")
                                .accessibilityIdentifier("organizedCompletion-" + item.id)
                                TextField("Subtask", text: Binding(get: {
                                    SubtaskTree.outline(draft).first { $0.id == item.id }?.record.title ?? ""
                                }, set: { title in draft = SubtaskTree.changing(draft, id: item.id, fields: ["title": .string(title)]) }), axis: .vertical)
                                    .labelsHidden().textFieldStyle(.plain).multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityLabel("Subtask name")
                                    .accessibilityHint("Level \(baseDepth + item.depth + 1). Use the actions menu to move or nest this subtask.")
                                    .accessibilityIdentifier("organizedTitle-" + item.id)
                                Menu {
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
            }.formStyle(.grouped)
            .navigationTitle("Organize subtasks")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).keyboardShortcut("s", modifiers: .command).disabled(loadError != nil || items.contains { $0.record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).accessibilityIdentifier("saveSubtaskOrganizer") }
            }
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
        .onAppear { if binding == nil { binding = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration) } }
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
    private func save() {
        guard binding?.matches(account: store.userID, generation: store.workspaceGeneration) == true,
              taskID == originalTaskID, children == source else {
            message = "The task or workspace changed. Cancel and reopen the organizer to keep the latest work."; return
        }
        do {
            let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let saved = title.isEmpty ? draft : try SubtaskTree.adding(draft, title: title, baseDepth: baseDepth)
            children = saved; dismiss()
        } catch { message = error.localizedDescription }
    }
}
