import SwiftUI
import AppKit

extension Workspace {
    /// Layouts the current destination can show. The Calendar destination and "Assigned to me" have none to choose.
    var availableLayouts: [TaskLayout] {
        guard section != .assigned, let scope = section.scope else { return [] }
        let layouts = TaskLayout.available(for: scope)
        return layouts.count > 1 ? layouts : []
    }
    /// The layout the destination shows now. A stored value the scope cannot show reads as List.
    var currentLayout: TaskLayout {
        guard let scope = section.scope else { return .list }
        return TaskLayout.resolved(store.viewValue(scope, field: "layout", fallback: .string("list")).text, for: scope)
    }
    func setLayout(_ layout: TaskLayout) {
        guard let scope = section.scope, availableLayouts.contains(layout), currentLayout != layout else { return }
        store.setViewValue(scope, field: "layout", value: .string(layout.rawValue))
    }
}

/// The single Layout control shown in View Options: icons only, one per layout valid for the scope.
struct LayoutPicker: View {
    let layouts: [TaskLayout]
    @Binding var selection: TaskLayout
    var body: some View {
        Picker("Layout", selection: $selection) {
            ForEach(layouts) { layout in
                Label(layout.title, systemImage: layout.symbol).tag(layout)
            }
        }
        .pickerStyle(.palette)
        .accessibilityIdentifier("layoutPicker")
    }
}

/// A month of tasks by due date, with the selected day's list beside it.
struct MonthCalendarView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.calendar) private var calendar
    let tasks: [Record]
    @Binding var month: Date
    @Binding var selectedDay: String
    var identifier = "projectCalendar"
    var canDrag: (Record) -> Bool = { _ in true }
    let add: (String) -> Void
    @FocusState private var listFocused: Bool
    @State private var targetedDay: String?

    private var grid: MonthGrid { MonthGrid.build(month: month, tasks: tasks, calendar: calendar) }
    private var priorities: [String: Int] { Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.priority) }) }

    var body: some View {
        let grid = grid
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                weekdayHeader(grid)
                VStack(spacing: 0) {
                    ForEach(grid.weeks.indices, id: \.self) { week in
                        HStack(spacing: 0) {
                            ForEach(grid.weeks[week]) { cell in dayCell(cell) }
                        }.frame(maxHeight: .infinity)
                    }
                }
                .overlay(Rectangle().strokeBorder(DS.Palette.separator.opacity(0.6), lineWidth: 0.5))
                .padding(.horizontal, DS.Space.l)
                if let footer = grid.undatedFooter {
                    Text(footer).font(DS.Font.taskNote).foregroundStyle(DS.Palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
                        .accessibilityIdentifier("calendarUndatedFooter")
                } else { Color.clear.frame(height: DS.Space.m) }
            }
            Divider()
            dayPanel(grid)
        }
        .accessibilityIdentifier(identifier)
    }

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Text(month.formatted(.dateTime.month(.wide).year())).font(DS.Font.screenTitle)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("calendarMonthTitle")
            Spacer(minLength: 0)
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .help("Previous month").accessibilityLabel("Previous month").accessibilityIdentifier("calendarPreviousMonth")
            Button("Today") { jumpToToday() }.help("Show this month").accessibilityIdentifier("calendarJumpToday")
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .help("Next month").accessibilityLabel("Next month").accessibilityIdentifier("calendarNextMonth")
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
    }
    private func weekdayHeader(_ grid: MonthGrid) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(grid.weekdaySymbols.enumerated()), id: \.offset) { _, name in
                Text(name).font(DS.Font.chip).foregroundStyle(DS.Palette.textSecondary).frame(maxWidth: .infinity)
            }
        }.padding(.horizontal, DS.Space.l).padding(.bottom, DS.Space.xs).accessibilityHidden(true)
    }

    private func dayCell(_ cell: MonthGrid.Cell) -> some View {
        let selected = cell.id == selectedDay, targeted = targetedDay == cell.id
        return VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack(spacing: DS.Space.xs) {
                Text("\(cell.dayNumber)").font(DS.Font.chip.monospacedDigit())
                    .foregroundStyle(cell.isToday ? Color.onAccent : cell.inMonth ? DS.Palette.textPrimary : DS.Palette.textTertiary)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(cell.isToday ? DS.Palette.accent : Color.clear, in: .circle)
                Spacer(minLength: 0)
                if cell.overdueCount > 0 {
                    Text("\(cell.overdueCount)").font(DS.Font.badge).foregroundStyle(DS.Palette.dateOverdue)
                        .padding(.horizontal, DS.Space.xs).background(DS.Palette.dateOverdue.opacity(0.14), in: .capsule)
                        .accessibilityHidden(true)
                }
            }
            ForEach(cell.visibleTasks) { task in chip(task, in: cell) }
            if cell.overflow > 0 {
                Text("+\(cell.overflow)").font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary)
                    .padding(.horizontal, DS.Space.xs).accessibilityLabel("\(cell.overflow) more tasks")
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(targeted ? DS.Palette.accent.opacity(0.16) : selected ? DS.Palette.selectionFill : cell.inMonth ? Color.clear : DS.Palette.surfaceSunken.opacity(0.4))
        .overlay(Rectangle().strokeBorder(DS.Palette.separator.opacity(0.6), lineWidth: 0.5))
        .overlay { if selected { Rectangle().strokeBorder(DS.Palette.accent, lineWidth: 1.5) } }
        .contentShape(Rectangle())
        .onTapGesture { selectedDay = cell.id }
        .onDrop(of: [.taskfoldTask], isTargeted: Binding(get: { targetedDay == cell.id }, set: { targetedDay = $0 ? cell.id : (targetedDay == cell.id ? nil : targetedDay) })) { _ in
            targetedDay = nil
            let ids = workspace.drag.ids
            defer { workspace.drag.end() }
            guard !ids.isEmpty else { return false }
            let moved = workspace.move(ids, to: DragSlot(day: cell.id, before: nil))
            if moved { selectedDay = cell.id }
            return moved
        }
        .animation(Motion.respecting(reduceMotion, Motion.quick), value: targeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityName(cell))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Show tasks for this day") { selectedDay = cell.id }
        .accessibilityIdentifier("calendarDay-" + cell.id)
    }
    private func accessibilityName(_ cell: MonthGrid.Cell) -> String {
        let count = cell.tasks.count
        var parts = [cell.date.formatted(.dateTime.weekday(.wide).month(.wide).day()), count == 0 ? "no tasks" : count == 1 ? "1 task" : "\(count) tasks"]
        if cell.isToday { parts.append("today") }
        if cell.overdueCount > 0 { parts.append("\(cell.overdueCount) overdue") }
        return parts.joined(separator: ", ")
    }

    private func chip(_ task: Record, in cell: MonthGrid.Cell) -> some View {
        let overdue = cell.isOverdue(task)
        return HStack(spacing: DS.Space.xs) {
            Circle().fill(Color.priority(task.priority)).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(task.title).font(DS.Font.taskMeta).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(overdue ? DS.Palette.dateOverdue : task.completed ? DS.Palette.textTertiary : DS.Palette.textPrimary)
                .strikethrough(task.completed)
        }
        .padding(.horizontal, DS.Space.xs).padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(workspace.selection.contains(task.id) ? DS.Palette.selectionFill : DS.Palette.surfaceSunken.opacity(0.5), in: .rect(cornerRadius: DS.Radius.xs, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { selectedDay = cell.id; workspace.open(task.id) }
        .onTapGesture { selectedDay = cell.id; workspace.selection = [task.id] }
        .itemProvider {
            guard canDrag(task), !task.completed else { return nil }
            workspace.drag.begin([task.id], order: [(day: cell.id, ids: cell.tasks.map(\.id))], priorities: priorities)
            return taskItemProvider(for: [task])
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(task.title + (overdue ? ", overdue" : ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Edit") { workspace.open(task.id) }
        .accessibilityIdentifier("calendarTask-" + task.id)
    }

    // MARK: Day panel

    private func dayPanel(_ grid: MonthGrid) -> some View {
        let dayTasks = grid.cell(selectedDay)?.tasks ?? []
        let date = Dates.parse(selectedDay, calendar: calendar)
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(date?.formatted(.dateTime.weekday(.wide)) ?? selectedDay).font(DS.Font.sectionHeader)
                    Text(date?.formatted(.dateTime.month(.wide).day()) ?? "").font(DS.Font.taskNote).foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer(minLength: 0)
                Text(TaskKind.listCountLabel(dayTasks)).font(DS.Font.badge).foregroundStyle(DS.Palette.textTertiary)
                Button { add(selectedDay) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("Add task on this day").accessibilityLabel("Add task on this day").accessibilityIdentifier("calendarAddTask")
            }
            .padding(DS.Space.m).accessibilityElement(children: .contain).accessibilityAddTraits(.isHeader)
            Divider()
            if dayTasks.isEmpty {
                Text("Nothing planned").foregroundStyle(DS.Palette.textTertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onDrop(of: [.taskfoldTask], isTargeted: nil) { _ in
                        let ids = workspace.drag.ids; defer { workspace.drag.end() }
                        guard !ids.isEmpty else { return false }
                        return workspace.move(ids, to: DragSlot(day: selectedDay, before: nil))
                    }
            } else {
                List(selection: Binding(get: { workspace.selection }, set: { workspace.selection = $0 })) {
                    ForEach(dayTasks) { task in
                        TaskRowView(task: task, compactDate: true)
                            .modifier(DayDragRow(task: task, day: selectedDay, enabled: canDrag(task), orderProvider: { [(day: selectedDay, ids: dayTasks.map(\.id))] }))
                            .tag(task.id).listRowSeparator(.hidden)
                    }
                }
                .focused($listFocused).environment(\.taskListFocused, listFocused)
                .accessibilityIdentifier("layoutCalendarDayList")
                .listStyle(.inset).scrollContentBackground(.hidden).background(QuietNativeSelection())
                .contextMenu(forSelectionType: String.self) { ids in
                    if !ids.isEmpty {
                        Button("Complete / Reopen") { workspace.toggle(ids) }
                        Menu("Reschedule") {
                            Button("Today", systemImage: "sun.max") { workspace.reschedule(ids, to: Dates.day(Date()), label: "today") }
                            Button("Tomorrow", systemImage: "sunrise") { workspace.reschedule(ids, to: Dates.day(calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()), label: "tomorrow") }
                            Divider()
                            Button("Remove Date", systemImage: "calendar.badge.minus") { workspace.reschedule(ids, to: nil, label: "") }
                        }
                        if ids.count == 1, let id = ids.first { Button("Edit Details") { workspace.open(id) } }
                    }
                } primaryAction: { ids in
                    if ids.count == 1, let id = ids.first { workspace.open(id) }
                }
                .onDeleteCommand { workspace.delete(workspace.selection) }
            }
        }
        .frame(width: 300)
        .background(DS.Palette.surfaceRaised.opacity(0.5))
    }

    // MARK: Navigation

    private func shift(_ offset: Int) {
        month = MonthGrid.shifted(month, by: offset, calendar: calendar)
        let today = Date()
        if calendar.isDate(month, equalTo: today, toGranularity: .month) { selectedDay = Dates.day(today) }
        else { selectedDay = TaskPlanner.dayKey(month, calendar: calendar) }
    }
    private func jumpToToday() {
        month = MonthGrid.shifted(Date(), by: 0, calendar: calendar)
        selectedDay = TaskPlanner.dayKey(Date(), calendar: calendar)
    }
}

#if DEBUG
/// Capture-only stand-in for the View Options menu, which cannot be rendered offscreen.
struct LayoutPickerCaptureCard: View {
    let layouts: [TaskLayout]
    @State var selected: TaskLayout
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("View Options").font(DS.Font.screenTitle)
            Text("Layout").font(DS.Font.chip).foregroundStyle(DS.Palette.textSecondary)
            Picker("Layout", selection: $selected) {
                ForEach(layouts) { layout in Label(layout.title, systemImage: layout.symbol).tag(layout) }
            }.pickerStyle(.segmented).labelsHidden()
            Text("Only the layouts that work for this view are offered. ⌃⌘1, ⌃⌘2 and ⌃⌘3 switch between them.").font(DS.Font.taskNote).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.l)
        .background(DS.Palette.surfaceRaised, in: .rect(cornerRadius: DS.Radius.l, style: .continuous))
    }
}
#endif
