import SwiftUI

struct ProjectColumn: Identifiable {
    /// The drop key: a project group key, a day, `project:<id>` or an overdue list key.
    var id: String
    /// What the column's Add button hands back (a section id, a day, or a project id).
    var sectionID: String
    var title: String
    var subtitle: String? = nil
    var tasks: [Record]
    /// The Overdue column of Upcoming holds only late work, so a nested Overdue band would repeat it.
    var groupsOverdue = true
    var receivesDrops = true
}

struct ProjectBoard: View {
    @Environment(Workspace.self) private var workspace
    let columns: [ProjectColumn]
    var identifier = "projectBoard"
    var moveMenuTitle = "Move to Section"
    var compactDate = false
    var canDrag: (Record) -> Bool = { _ in true }
    let add: (ProjectColumn) -> Void
    private var order: [(day: String, ids: [String])] { columns.map { ($0.id, $0.tasks.map(\.id)) } }
    private var selectedColumn: String? {
        guard workspace.selection.count == 1, let selected = workspace.selection.first else { return nil }
        let root = Workspace.subtaskPath(selected)?.first ?? selected
        return columns.first { $0.tasks.contains(where: { $0.id == root }) }?.id
    }
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: DS.Space.l) {
                ForEach(columns) { column in
                    BoardColumn(column: column, order: order, moveMenuTitle: moveMenuTitle, compactDate: compactDate, canDrag: canDrag, destinations: columns.filter(\.receivesDrops), add: { add(column) })
                        .frame(width: 280).id(column.id)
                }
            }.padding(.horizontal, DS.Space.xl).padding(.bottom, DS.Space.m)
        }.accessibilityIdentifier(identifier)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in
            reveal(selectedColumn, using: proxy)
        }
        .onChange(of: selectedColumn) { _, column in reveal(column, using: proxy) }
        .onChange(of: workspace.inspectorVisible) { _, _ in reveal(selectedColumn, using: proxy) }
        }
    }
    private func reveal(_ column: String?, using proxy: ScrollViewProxy) {
        guard let column else { return }
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(column, anchor: .trailing)
        }
    }
}

private struct BoardColumn: View {
    @FocusState private var taskListFocused: Bool
    @Environment(Workspace.self) private var workspace
    let column: ProjectColumn
    let order: [(day: String, ids: [String])]
    let moveMenuTitle: String
    let compactDate: Bool
    let canDrag: (Record) -> Bool
    let destinations: [ProjectColumn]
    let add: () -> Void
    @AppStorage("mac.collapsedProjectSections") private var collapsedSections = ""
    private var collapsed: Bool { collapsedSections.split(separator: "\n").contains(Substring(column.id)) }
    private func toggleCollapsed() {
        var keys = Set(collapsedSections.split(separator: "\n").map(String.init))
        if !keys.insert(column.id).inserted { keys.remove(column.id) }
        collapsedSections = keys.sorted().joined(separator: "\n")
    }
    @AppStorage private var overdueCollapsed: Bool
    init(column: ProjectColumn, order: [(day: String, ids: [String])], moveMenuTitle: String, compactDate: Bool, canDrag: @escaping (Record) -> Bool, destinations: [ProjectColumn], add: @escaping () -> Void) {
        self.column = column; self.order = order; self.moveMenuTitle = moveMenuTitle; self.compactDate = compactDate; self.canDrag = canDrag; self.destinations = destinations; self.add = add
        _overdueCollapsed = AppStorage(wrappedValue: false, "mac.board.\(column.id).overdueCollapsed")
    }
    private var overdue: [Record] { !column.groupsOverdue ? [] : column.tasks.filter { TaskKind.mayComplete($0) && !$0.completed && $0.due.map { $0 < Calendar.current.startOfDay(for: Date()) } == true } }
    private var regular: [Record] { let ids = Set(overdue.map(\.id)); return column.tasks.filter { !ids.contains($0.id) } }
    private var headerLabel: String {
        var label = column.title
        if let subtitle = column.subtitle { label += ", " + subtitle }
        return label + ", " + TaskKind.listCountLabel(column.tasks) + " tasks"
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { toggleCollapsed() } label: {
                    HStack { Image(systemName: collapsed ? "chevron.right" : "chevron.down"); Text(column.title); if let subtitle = column.subtitle { Text(subtitle).font(DS.Font.taskNote).foregroundStyle(DS.Palette.textSecondary) }; Text(TaskKind.listCountLabel(column.tasks)).foregroundStyle(.secondary) }
                }.buttonStyle(.plain).accessibilityIdentifier("board-collapse-" + column.sectionID)
                    .accessibilityLabel(headerLabel)
                    .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
                Spacer()
                if column.receivesDrops { Button(action: add) { Image(systemName: "plus") }.buttonStyle(.borderless).help("Add task to \(column.title)").accessibilityLabel("Add task to \(column.title)").accessibilityIdentifier("board-add-" + column.sectionID) }
            }.padding(12).modifier(DropHeader(day: column.id, enabled: column.receivesDrops))
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
                    if column.receivesDrops {
                        DayEndRow(day: column.id, isEmpty: column.tasks.isEmpty, emptyText: "Drop a task here, or use +", releaseText: "Move to \(column.title)")
                            .selectionDisabled().listRowSeparator(.hidden)
                    }
                }.focused($taskListFocused)
                .environment(\.taskListFocused, taskListFocused)
                .accessibilityIdentifier("boardTaskList")
                .listStyle(.inset).scrollContentBackground(.hidden).background(QuietNativeSelection())
                .contextMenu(forSelectionType: String.self) { ids in
                    if !ids.isEmpty {
                        Button("Complete / Reopen") { workspace.toggle(ids) }
                        if ids.allSatisfy({ Workspace.subtaskPath($0) == nil }) {
                            Menu(moveMenuTitle) {
                                ForEach(destinations) { destination in
                                    Button(destination.title + (destination.subtitle.map { " · " + $0 } ?? "")) {
                                        workspace.drag.order = order
                                        let ordered = order.flatMap(\.ids).filter { ids.contains($0) }
                                        _ = workspace.move(ordered, to: DragSlot(day: destination.id, before: nil))
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
            TaskRowView(task: task, compactDate: compactDate)
                .modifier(DayDragRow(task: task, day: column.id, enabled: canDrag(task), orderProvider: { order }))
                .tag(task.id).listRowSeparator(.hidden)

        }
        .onMove { DayDropHandling(workspace: workspace, day: column.id, tasks: tasks).move(from: $0, to: $1) }
        .onInsert(of: [.taskfoldTask]) { DayDropHandling(workspace: workspace, day: column.id, tasks: tasks).insert(at: $0, providers: $1) }
    }
}

/// Header drop target that can be switched off for columns that only display work.
private struct DropHeader: ViewModifier {
    let day: String
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.modifier(DayHeaderDrop(day: day)) } else { content }
    }
}

struct ProjectSectionHeader: View {
    let key: String
    let title: String
    let count: String
    @Binding var collapsed: Bool
    let add: () -> Void
    var body: some View {
        HStack {
            Button { collapsed.toggle() } label: { HStack(spacing: DS.Space.s) { Image(systemName: collapsed ? "chevron.right" : "chevron.down"); Text(title); Text("\(count)").foregroundStyle(DS.Palette.textSecondary) }.font(DS.Font.sectionHeader) }
                .buttonStyle(.plain).accessibilityIdentifier("section-collapse-" + key).accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            Spacer()
            Button(action: add) { Image(systemName: "plus") }.buttonStyle(.borderless).help("Add task to \(title)").accessibilityIdentifier("section-add-" + key)
        }.modifier(DayHeaderDrop(day: key))
    }
}
