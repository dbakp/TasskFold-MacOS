import SwiftUI

struct ProjectColumn: Identifiable {
    var id: String
    var sectionID: String
    var title: String
    var tasks: [Record]
}

struct ProjectBoard: View {
    @Environment(Workspace.self) private var workspace
    let columns: [ProjectColumn]
    let add: (String) -> Void
    private var order: [(day: String, ids: [String])] { columns.map { ($0.id, $0.tasks.map(\.id)) } }
    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(columns) { column in
                    BoardColumn(column: column, order: order, add: { add(column.sectionID) })
                        .frame(width: 320)
                }
            }.padding(.horizontal, 20).padding(.bottom, 12)
        }.accessibilityIdentifier("projectBoard")
    }
}

private struct BoardColumn: View {
    @Environment(Workspace.self) private var workspace
    let column: ProjectColumn
    let order: [(day: String, ids: [String])]
    let add: () -> Void
    @AppStorage("mac.collapsedProjectSections") private var collapsedSections = ""
    private var collapsed: Bool { collapsedSections.split(separator: "\n").contains(Substring(column.id)) }
    private func toggleCollapsed() {
        var keys = Set(collapsedSections.split(separator: "\n").map(String.init))
        if !keys.insert(column.id).inserted { keys.remove(column.id) }
        collapsedSections = keys.sorted().joined(separator: "\n")
    }
    @AppStorage private var overdueCollapsed: Bool
    init(column: ProjectColumn, order: [(day: String, ids: [String])], add: @escaping () -> Void) {
        self.column = column; self.order = order; self.add = add
        _overdueCollapsed = AppStorage(wrappedValue: false, "mac.board.\(column.id).overdueCollapsed")
    }
    private var overdue: [Record] { column.tasks.filter { !$0.completed && $0.due.map { $0 < Calendar.current.startOfDay(for: Date()) } == true } }
    private var regular: [Record] { let ids = Set(overdue.map(\.id)); return column.tasks.filter { !ids.contains($0.id) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { toggleCollapsed() } label: {
                    HStack { Image(systemName: collapsed ? "chevron.right" : "chevron.down"); Text(column.title); Text("\(column.tasks.count)").foregroundStyle(.secondary) }
                }.buttonStyle(.plain).accessibilityIdentifier("board-collapse-" + column.sectionID)
                Spacer()
                Button(action: add) { Image(systemName: "plus") }.buttonStyle(.borderless).help("Add task to \(column.title)").accessibilityIdentifier("board-add-" + column.sectionID)
            }.padding(12).modifier(DayHeaderDrop(day: column.id))
            if !collapsed {
                List(selection: Binding(get: { workspace.selection }, set: { workspace.selection = $0 })) {
                    if !overdue.isEmpty {
                        Section {
                            if !overdueCollapsed { rows(overdue) }
                        } header: {
                            Button {
                                overdueCollapsed.toggle()
                                if overdueCollapsed { workspace.selection.subtract(workspace.visibleTasks(overdue).map(\.id)) }
                            } label: { Label("Overdue · \(overdue.count)", systemImage: overdueCollapsed ? "chevron.right" : "chevron.down") }.buttonStyle(.plain)
                        }
                    }
                    rows(regular)
                    DayEndRow(day: column.id, isEmpty: column.tasks.isEmpty, emptyText: "Drop a task here, or use +", releaseText: "Move to \(column.title)")
                        .selectionDisabled().listRowSeparator(.hidden)
                }.listStyle(.inset).scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: String.self) { ids in
                    if !ids.isEmpty {
                        Button("Complete / Reopen") { workspace.toggle(ids) }
                        if ids.allSatisfy({ Workspace.subtaskPath($0) == nil }) {
                            Menu("Move to Section") {
                                ForEach(order, id: \.day) { destination in
                                    Button(destinationName(destination.day)) {
                                        workspace.drag.order = order
                                        let ordered = order.flatMap(\.ids).filter { ids.contains($0) }
                                        _ = workspace.move(ordered, to: DragSlot(day: destination.day, before: nil))
                                        workspace.drag.end()
                                    }
                                }
                            }
                        }
                        if ids.count == 1, let id = ids.first { Button("Edit Details") { workspace.open(id) } }
                    }
                } primaryAction: { ids in
                    if ids.count == 1, let id = ids.first { workspace.open(id) }
                }
                .onDeleteCommand { workspace.delete(workspace.selection) }
            } else { Spacer(minLength: 0) }
        }.background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
    }
    @ViewBuilder private func rows(_ tasks: [Record]) -> some View {
        ForEach(workspace.visibleTasks(tasks)) { task in
            TaskRowView(task: task)
                .modifier(DayDragRow(task: task, day: column.id, orderProvider: { order }))
                .tag(task.id).listRowSeparator(.hidden)

        }
        .onMove { DayDropHandling(workspace: workspace, day: column.id, tasks: tasks).move(from: $0, to: $1) }
        .onInsert(of: [.taskfoldTask]) { DayDropHandling(workspace: workspace, day: column.id, tasks: tasks).insert(at: $0, providers: $1) }
    }
    private func destinationName(_ key: String) -> String {
        let section = key.split(separator: ":").last.map(String.init) ?? ""
        return workspace.store.record("sections", id: section)?.name ?? "Tasks"
    }
}

struct ProjectSectionHeader: View {
    let key: String
    let title: String
    let count: Int
    @Binding var collapsed: Bool
    let add: () -> Void
    var body: some View {
        HStack {
            Button { collapsed.toggle() } label: { HStack { Image(systemName: collapsed ? "chevron.right" : "chevron.down"); Text(title); Text("\(count)").foregroundStyle(.secondary) } }
                .buttonStyle(.plain).accessibilityIdentifier("section-collapse-" + key).accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            Spacer()
            Button(action: add) { Image(systemName: "plus") }.buttonStyle(.borderless).help("Add task to \(title)").accessibilityIdentifier("section-add-" + key)
        }.modifier(DayHeaderDrop(day: key))
    }
}
