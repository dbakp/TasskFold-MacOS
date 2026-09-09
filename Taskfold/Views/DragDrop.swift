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

/// Makes a list row draggable and a slot-aware drop target within a day.
struct DayDragRow: ViewModifier {
    @Environment(Workspace.self) private var workspace
    @Environment(Store.self) private var store
    let task: Record
    let day: String
    let orderProvider: () -> [(day: String, ids: [String])]
    func body(content: Content) -> some View {
        let drag = workspace.drag
        content
            .overlay(alignment: .top) { if drag.indicatorBefore(task.id, day: day) { InsertionIndicator().offset(y: -4) } }
            .opacity(drag.ids.contains(task.id) ? 0.4 : 1)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { drag.rowHeights[task.id] = $0 }
            .onDrag {
                let ids = workspace.selection.contains(task.id) ? Array(workspace.selection).sorted { a, b in
                    let order = orderProvider().flatMap(\.ids); return (order.firstIndex(of: a) ?? 0) < (order.firstIndex(of: b) ?? 0) } : [task.id]
                let tasks = ids.compactMap { store.record("tasks", id: $0) }.filter { !$0.completed }
                drag.begin(tasks.map(\.id), order: orderProvider())
                return taskItemProvider(for: tasks)
            } preview: { DragPreview(tasks: workspace.selection.contains(task.id) ? workspace.selectedTasks : [task]) }
            .onDrop(of: [.taskfoldTask], delegate: RowDropDelegate(workspace: workspace, id: task.id, day: day))
    }
}

/// Resolves the pointer position over a row to "before this task" or "before its successor".
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
    func performDrop(info: DropInfo) -> Bool { finishDrop(workspace) }
    private func update(_ info: DropInfo) {
        let drag = workspace.drag
        guard !drag.ids.contains(id) else { return }
        let height = drag.rowHeights[id] ?? 44
        let before = info.location.y < height / 2 ? id : drag.successor(of: id, in: day)
        drag.propose(DragSlot(day: day, before: before))
    }
}

/// The tail of a day: an inviting drop zone when the day is empty, otherwise a slim landing strip.
struct DayEndRow: View {
    @Environment(Workspace.self) private var workspace
    let day: String
    let isEmpty: Bool
    var body: some View {
        let drag = workspace.drag
        let targeted = drag.indicatorAtEnd(of: day)
        Group {
            if isEmpty {
                HStack {
                    Spacer()
                    Text(targeted ? "Release to schedule" : drag.active ? "Drop here" : "Nothing planned")
                        .font(.callout.weight(targeted ? .semibold : .regular))
                        .foregroundStyle(targeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    Spacer()
                }
                .frame(minHeight: 40)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(targeted ? Color.accentColor.opacity(0.08) : Color.clear)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: drag.active ? [5, 4] : [])).foregroundStyle(targeted ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor).opacity(drag.active ? 1 : 0.6)))
                }
            } else {
                Color.clear.frame(height: 8).overlay(alignment: .top) { if targeted { InsertionIndicator() } }
            }
        }
        .animation(Motion.quick, value: targeted)
        .animation(Motion.quick, value: drag.active)
        .accessibilityIdentifier("day-end-\(day)")
        .accessibilityLabel(isEmpty ? "No tasks planned" : "End of day")
        .onDrop(of: [.taskfoldTask], delegate: EndDropDelegate(workspace: workspace, day: day))
    }
}

struct EndDropDelegate: DropDelegate {
    let workspace: Workspace
    let day: String
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.taskfoldTask]) && workspace.drag.active }
    func dropEntered(info: DropInfo) { workspace.drag.propose(DragSlot(day: day, before: nil)) }
    func dropUpdated(info: DropInfo) -> DropProposal? { workspace.drag.propose(DragSlot(day: day, before: nil)); return DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { if workspace.drag.target == DragSlot(day: day, before: nil) { workspace.drag.propose(nil) } }
    func performDrop(info: DropInfo) -> Bool { finishDrop(workspace) }
}

/// Day section headers accept drops as "end of this day" so an entire day is a target, not only its rows.
struct DayHeaderDrop: ViewModifier {
    @Environment(Workspace.self) private var workspace
    let day: String
    func body(content: Content) -> some View {
        content.onDrop(of: [.taskfoldTask], delegate: EndDropDelegate(workspace: workspace, day: day))
    }
}

@MainActor
private func finishDrop(_ workspace: Workspace) -> Bool {
    let drag = workspace.drag
    defer { drag.end() }
    guard let slot = drag.target, !drag.isNoop(slot) else { return false }
    return workspace.move(drag.ids, to: slot)
}
