import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Begins a macOS drag session for one or more tasks. The provider carries the task ids for in-app drops and
/// the titles as plain text so dropping into another app pastes something useful.
@MainActor
func taskItemProvider(for tasks: [Record]) -> NSItemProvider {
    let provider = NSItemProvider(object: tasks.map(\.title).joined(separator: "\n") as NSString)
    let payload = try? JSONEncoder().encode(tasks.map(\.id))
    provider.registerDataRepresentation(forTypeIdentifier: UTType.taskfoldTask.identifier, visibility: .ownProcess) { completion in
        completion(payload, nil); return nil
    }
    return provider
}

/// Makes a list row a table-integrated drag source. `itemProvider` goes through the table's own dragging, so a
/// plain click still selects the row and dragging a selected row drags the whole selection with the system's
/// row snapshot as the drag image. Row drops are handled by the day's `onMove` / `onInsert`.
struct DayDragRow: ViewModifier {
    @Environment(Workspace.self) private var workspace
    @Environment(Store.self) private var store
    let task: Record
    let day: String
    let orderProvider: () -> [(day: String, ids: [String])]
    func body(content: Content) -> some View {
        let drag = workspace.drag
        if Workspace.subtaskPath(task.id) != nil { content } else {
        content
            .overlay(alignment: .top) { if drag.indicatorBefore(task.id, day: day) { InsertionIndicator(hint: drag.bandHint).offset(y: -5) } }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { drag.rowHeights[task.id] = $0 }
            .onDrop(of: [.taskfoldTask], delegate: RowDropDelegate(workspace: workspace, id: task.id, day: day))
            .itemProvider {
                let groups = orderProvider()
                let order = groups.flatMap(\.ids)
                let ids = (workspace.selection.contains(task.id) ? Array(workspace.selection) : [task.id])
                    .sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
                let tasks = ids.compactMap { store.record("tasks", id: $0) }.filter { !$0.completed }
                guard !tasks.isEmpty else { return nil }
                let priorities = Dictionary(uniqueKeysWithValues: store.tasks.map { ($0.id, $0.priority) })
                drag.begin(tasks.map(\.id), order: groups, priorities: priorities)
                return taskItemProvider(for: tasks)
            }
        }
    }
}

/// Resolves the pointer position over a row to "before this task" or "before its successor", drawing the
/// insertion indicator as the pointer moves and landing the drop with the iOS DayPlacement semantics.
struct RowDropDelegate: DropDelegate {
    let workspace: Workspace
    let id: String
    let day: String
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.taskfoldTask]) && workspace.drag.active }
    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? { update(info); return DropProposal(operation: .move) }
    func dropExited(info: DropInfo) {
        let drag = workspace.drag
        if drag.target?.day == day, drag.target?.before == id || drag.target?.before == drag.successor(of: id, in: day) { drag.propose(nil) }
    }
    func performDrop(info: DropInfo) -> Bool {
        let drag = workspace.drag
        defer { drag.end() }
        guard let slot = drag.target, !drag.isNoop(slot) else { return false }
        return workspace.move(drag.ids, to: slot)
    }
    private func update(_ info: DropInfo) {
        let drag = workspace.drag
        guard !drag.ids.contains(id) else { return }
        let height = drag.rowHeights[id] ?? 44
        let before = info.location.y < height / 2 ? id : drag.successor(of: id, in: day)
        // The indicator shows where the task will actually land: the slot snapped into its priority band.
        drag.propose(raw: DragSlot(day: day, before: before))
    }
}

/// Reorders within a day from a table `onMove`, preserving the iOS DayPlacement semantics.
@MainActor struct DayDropHandling {
    let workspace: Workspace
    let day: String
    let tasks: [Record]
    func move(from source: IndexSet, to destination: Int) {
        defer { workspace.drag.end() }
        let visible = workspace.visibleTasks(tasks)
        var ids = visible.map(\.id)
        let moved = source.compactMap { visible.indices.contains($0) ? visible[$0].id : nil }.filter { Workspace.subtaskPath($0) == nil }
        guard !moved.isEmpty else { return }
        ids.move(fromOffsets: source, toOffset: destination)
        let roots = ids.filter { Workspace.subtaskPath($0) == nil }
        guard let last = roots.lastIndex(where: { moved.contains($0) }) else { return }
        let before = roots.indices.contains(last + 1) ? roots[last + 1] : nil
        workspace.move(moved, to: DragSlot(day: day, before: before))
        workspace.drag.end()
    }
    func insert(at index: Int, providers: [NSItemProvider]) {
        let visible = workspace.visibleTasks(tasks)
        let before = visible.indices.contains(index) ? (Workspace.subtaskPath(visible[index].id)?.first ?? visible[index].id) : nil
        let ids = workspace.drag.ids
        if !ids.isEmpty {
            workspace.move(ids, to: DragSlot(day: day, before: before)); workspace.drag.end(); return
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.taskfoldTask.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.taskfoldTask.identifier) { data, _ in
                guard let data, let ids = try? JSONDecoder().decode([String].self, from: data) else { return }
                Task { @MainActor in workspace.move(ids, to: DragSlot(day: day, before: before)) }
            }
        }
    }
}

/// The tail of a day: an inviting drop zone when the day is empty, otherwise a slim landing strip.
struct DayEndRow: View {
    @Environment(Workspace.self) private var workspace
    let day: String
    let isEmpty: Bool
    var emptyText = "Nothing planned"
    var releaseText = "Release to schedule"
    @State private var targeted = false
    var body: some View {
        let drag = workspace.drag
        Group {
            if isEmpty {
                HStack {
                    Spacer()
                    Text(targeted ? releaseText : drag.active ? "Drop here" : emptyText)
                        .font(.callout.weight(targeted ? .semibold : .regular))
                        .foregroundStyle(targeted ? AnyShapeStyle(Color.taskfold) : AnyShapeStyle(.tertiary))
                        .contentTransition(.interpolate)
                    Spacer()
                }
                .frame(minHeight: 40)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(targeted ? Color.taskfold.opacity(0.08) : Color.clear)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: drag.active ? [5, 4] : [])).foregroundStyle(targeted ? Color.taskfold.opacity(0.7) : Color(nsColor: .separatorColor).opacity(drag.active ? 1 : 0.6)))
                }
                .scaleEffect(targeted ? 1.01 : 1)
            } else {
                Color.clear.frame(height: 10)
                    .overlay(alignment: .top) { if drag.indicatorAtEnd(of: day) { InsertionIndicator(hint: drag.bandHint) } }
            }
        }
        .onChange(of: drag.active) { _, active in if !active { targeted = false } }
        .animation(Motion.quick, value: targeted)
        .animation(Motion.quick, value: drag.active)
        .accessibilityIdentifier("day-end-\(day)")
        .accessibilityLabel(isEmpty ? emptyText : "End of list")
        .onDrop(of: [.taskfoldTask], delegate: EndDropDelegate(workspace: workspace, day: day, targeted: $targeted))
    }
}

/// The end of a list is "after the last task", which the band rules may pull up to the end of the task's band.
struct EndDropDelegate: DropDelegate {
    let workspace: Workspace
    let day: String
    @Binding var targeted: Bool
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.taskfoldTask]) && workspace.drag.active }
    func dropEntered(info: DropInfo) { targeted = true; workspace.drag.propose(raw: DragSlot(day: day, before: nil)) }
    func dropUpdated(info: DropInfo) -> DropProposal? { workspace.drag.propose(raw: DragSlot(day: day, before: nil)); return DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { targeted = false; if workspace.drag.target?.day == day { workspace.drag.propose(nil) } }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        let drag = workspace.drag
        defer { drag.end() }
        guard let slot = drag.target, !drag.isNoop(slot) else { return false }
        return workspace.move(drag.ids, to: slot)
    }
}

/// Day section headers accept drops as "end of this day" so an entire day is a target, not only its rows.
struct DayHeaderDrop: ViewModifier {
    @Environment(Workspace.self) private var workspace
    let day: String
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.taskfold.opacity(targeted ? 0.12 : 0)).padding(-4))
            .onChange(of: workspace.drag.active) { _, active in if !active { targeted = false } }
            .animation(Motion.quick, value: targeted)
            .onDrop(of: [.taskfoldTask], isTargeted: $targeted) { _ in
                targeted = false
                let ids = workspace.drag.ids
                defer { workspace.drag.end() }
                guard !ids.isEmpty else { return false }
                return workspace.move(ids, to: workspace.drag.constrain(DragSlot(day: day, before: nil)).slot)
            }
    }
}
