import SwiftUI

/// Calendar for a wide window: the period on the left (day columns for 3/5/week, a grid for month, twelve heat
/// months for year) and the selected day's tasks alongside. Tasks open in the inspector; days accept drops.
struct CalendarView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var quickAdd = ""
    @FocusState private var quickAddFocused: Bool
    @Namespace private var dayNamespace

    private var calendar: Calendar { Calendar.current }
    private var today: Date { calendar.startOfDay(for: Date()) }
    private var mode: CalendarMode { workspace.calendarMode }
    private var selected: Date { workspace.calendarDay }
    private var layout: Animation? { Motion.respecting(reduceMotion, Motion.layout) }

    private var byDay: [String: [Record]] {
        var map: [String: [Record]] = [:]
        for task in store.tasks where !task.string("due_date").isEmpty { map[String(task.string("due_date").prefix(10)), default: []].append(task) }
        return map
    }
    private func tasks(on day: Date) -> [Record] {
        let key = Dates.day(day)
        return workspace.ordered(byDay[key] ?? [], day: key).sorted { a, b in
            if a.completed != b.completed { return !a.completed }
            return false
        }
    }
    private func open(on day: Date) -> Int { tasks(on: day).filter { !$0.completed && !workspace.completing.contains($0.id) }.count }

    // MARK: Period math

    private func start(of page: Int, mode: CalendarMode) -> Date {
        switch mode {
        case .threeDay, .fiveDay: return calendar.date(byAdding: .day, value: page * (mode.days ?? 1), to: today)!
        case .week: return calendar.date(byAdding: .day, value: page * 7, to: startOfWeek(today))!
        case .month: return calendar.date(byAdding: .month, value: page, to: startOfMonth(today))!
        case .year: return calendar.date(byAdding: .year, value: page, to: startOfYear(today))!
        }
    }
    private func page(containing day: Date, mode: CalendarMode) -> Int {
        switch mode {
        case .threeDay, .fiveDay:
            let delta = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: day)).day ?? 0
            return Int((Double(delta) / Double(mode.days ?? 1)).rounded(.down))
        case .week: return calendar.dateComponents([.weekOfYear], from: startOfWeek(today), to: startOfWeek(day)).weekOfYear ?? 0
        case .month: return calendar.dateComponents([.month], from: startOfMonth(today), to: startOfMonth(day)).month ?? 0
        case .year: return calendar.dateComponents([.year], from: startOfYear(today), to: startOfYear(day)).year ?? 0
        }
    }
    private func startOfWeek(_ date: Date) -> Date { calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date }
    private func startOfMonth(_ date: Date) -> Date { calendar.dateInterval(of: .month, for: date)?.start ?? date }
    private func startOfYear(_ date: Date) -> Date { calendar.dateInterval(of: .year, for: date)?.start ?? date }
    private func days(from start: Date, count: Int) -> [Date] { (0..<count).map { calendar.date(byAdding: .day, value: $0, to: start)! } }
    private var periodTitle: String {
        let start = start(of: page, mode: mode)
        switch mode {
        case .year: return start.formatted(.dateTime.year())
        case .month: return start.formatted(.dateTime.month(.wide).year())
        default:
            let end = calendar.date(byAdding: .day, value: (mode.days ?? 7) - 1, to: start)!
            if calendar.isDate(start, equalTo: end, toGranularity: .month) { return start.formatted(.dateTime.month(.wide).year()) }
            return start.formatted(.dateTime.month(.abbreviated).day()) + " – " + end.formatted(.dateTime.month(.abbreviated).day().year())
        }
    }

    // MARK: Body

    var body: some View {
        @Bindable var workspace = workspace
        HSplitView {
            VStack(spacing: 0) {
                header
                Divider()
                Group {
                    switch mode {
                    case .threeDay, .fiveDay, .week: dayColumns(days(from: start(of: page, mode: mode), count: mode.days ?? 7))
                    case .month: monthGrid(start(of: page, mode: mode))
                    case .year: yearGrid(start(of: page, mode: mode))
                    }
                }
                .id("\(mode.rawValue)-\(page)")
                .transition(reduceMotion ? .opacity : .panelReveal(distance: 24))
                .animation(layout, value: page)
                .animation(layout, value: mode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            dayPanel
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 420, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Calendar")
        .navigationSubtitle(periodTitle)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { shift(-1) } label: { Label("Previous", systemImage: "chevron.left") }.help("Previous period (←)")
                Button { shift(1) } label: { Label("Next", systemImage: "chevron.right") }.help("Next period (→)")
                Button("Today") { jump(to: today) }.disabled(calendar.isDate(selected, inSameDayAs: today) && page == 0).help("Jump to today (⌘T)").keyboardShortcut("t", modifiers: .command)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { quickAddFocused = true } label: { Label("New Task", systemImage: "plus") }.help("Add a task on the selected day (⌘N)")
                Button { workspace.inspectorShown.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }.help("Show or hide the inspector (⌥⌘I)")
            }
        }
        .onAppear { page = page(containing: selected, mode: mode) }
        .onChange(of: workspace.calendarMode) { _, _ in withAnimation(layout) { page = page(containing: selected, mode: mode) } }
        .onChange(of: workspace.quickAddFocusRequest) { _, _ in quickAddFocused = true }
        .onKeyPress(.leftArrow) { shift(-1); return .handled }
        .onKeyPress(.rightArrow) { shift(1); return .handled }
        .onChange(of: page) { _, new in
            let start = start(of: new, mode: mode)
            switch mode {
            case .year:
                if !calendar.isDate(selected, equalTo: start, toGranularity: .year) { workspace.calendarDay = calendar.isDate(start, equalTo: today, toGranularity: .year) ? today : start }
            case .month:
                if !calendar.isDate(selected, equalTo: start, toGranularity: .month) { workspace.calendarDay = calendar.isDate(start, equalTo: today, toGranularity: .month) ? today : start }
            default:
                let end = calendar.date(byAdding: .day, value: mode.days ?? 7, to: start)!
                if selected < start || selected >= end { workspace.calendarDay = (today >= start && today < end) ? today : start }
            }
        }
    }

    private var header: some View {
        HStack {
            SlidingTabs(options: CalendarMode.allCases, selection: mode, title: { $0.title }) { workspace.calendarMode = $0 }
                .accessibilityLabel("Calendar view")
            Spacer()
            Text(periodTitle).font(.title3.weight(.semibold)).id(periodTitle).transition(.textSwap)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
    private func shift(_ delta: Int) { withAnimation(layout) { page += delta } }
    private func jump(to day: Date) { withAnimation(layout) { workspace.calendarDay = day; page = page(containing: day, mode: mode) } }
    private func select(_ day: Date) { withAnimation(Motion.respecting(reduceMotion, Motion.quick)) { workspace.calendarDay = calendar.startOfDay(for: day) } }

    // MARK: Day columns (3 / 5 / week)

    private func dayColumns(_ days: [Date]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(days, id: \.self) { day in
                dayColumn(day)
                if day != days.last { Divider() }
            }
        }
    }
    private func dayColumn(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selected)
        let isToday = calendar.isDate(day, inSameDayAs: today)
        let items = tasks(on: day)
        return VStack(alignment: .leading, spacing: 8) {
            Button { select(day) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased()).font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(isToday ? Color.accentColor : .secondary)
                    Text(day.formatted(.dateTime.day())).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                        .foregroundStyle(isSelected ? Color.white : isToday ? Color.accentColor : .primary)
                        .frame(width: 30, height: 30)
                        .background { if isSelected { Circle().fill(Color.accentColor).matchedGeometryEffect(id: "selectedDay", in: dayNamespace) } }
                    Spacer()
                    let count = open(on: day)
                    if count > 0 { Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.tertiary) }
                }
                .padding(.horizontal, 10).padding(.top, 10)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
            .accessibilityValue(open(on: day) == 0 ? "No tasks" : "\(open(on: day)) tasks")
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(items) { task in calendarCard(task, day: day) }
                    if items.isEmpty {
                        Text("Nothing planned").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.top, 20)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 12)
                .animation(layout, value: items.map(\.id))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(isSelected ? Color.accentColor.opacity(0.05) : isToday ? Color.primary.opacity(0.02) : Color.clear)
        .modifier(CalendarDayDrop(day: day))
        .accessibilityIdentifier("calendar-day-\(Dates.day(day))")
    }
    private func calendarCard(_ task: Record, day: Date) -> some View {
        let selectedTask = workspace.selection.contains(task.id)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { workspace.complete(task) } label: { CheckMark(checked: task.completed || workspace.completing.contains(task.id), color: Color.priority(task.priority), emphasized: task.priority < 4, size: 16) }
                .buttonStyle(GlyphStyle()).pointerStyle(.link)
                .accessibilityLabel(task.completed ? "Reopen \(task.title)" : "Complete \(task.title)")
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(.callout).lineLimit(2).foregroundStyle(task.completed ? .secondary : .primary).strikethrough(task.completed)
                HStack(spacing: 6) {
                    if !task.string("due_time").isEmpty { Text(TaskRowView.timeText(task.string("due_time"))) }
                    if let project = store.record("projects", id: task.string("project_id")) {
                        HStack(spacing: 4) { Circle().fill(Color.project(project.string("color"))).frame(width: 6, height: 6); Text(project.name).lineLimit(1) }
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .modifier(CardSurface(radius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor, lineWidth: selectedTask ? 1.5 : 0))
        .contentShape(.rect)
        .onTapGesture { select(day); workspace.selection = [task.id] }
        .onTapGesture(count: 2) { workspace.open(task.id) }
        .onDrag {
            workspace.drag.begin([task.id], order: [])
            return taskItemProvider(for: [task])
        } preview: { DragPreview(tasks: [task]) }
        .contextMenu {
            Button("Open in Inspector") { workspace.open(task.id) }
            Button(task.completed ? "Reopen" : "Complete") { workspace.complete(task) }
            Divider()
            Button("Delete", role: .destructive) { workspace.delete([task.id]) }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selectedTask ? .isSelected : [])
    }

    // MARK: Month

    private func monthGrid(_ month: Date) -> some View {
        let first = startOfWeek(month)
        let cells = days(from: first, count: 42)
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let firstWeekday = calendar.firstWeekday - 1
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in Text(symbols[(firstWeekday + i) % 7].uppercased()).font(.caption.weight(.semibold)).tracking(0.5).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 6) }
            }
            Divider()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(cells, id: \.self) { day in
                    monthCell(day, inMonth: calendar.isDate(day, equalTo: month, toGranularity: .month))
                        .frame(maxWidth: .infinity, minHeight: 88, maxHeight: .infinity, alignment: .topLeading)
                        .overlay(alignment: .trailing) { Divider() }
                        .overlay(alignment: .bottom) { Divider() }
                }
            }
        }
    }
    private func monthCell(_ day: Date, inMonth: Bool) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selected)
        let isToday = calendar.isDate(day, inSameDayAs: today)
        let items = tasks(on: day).filter { !$0.completed }
        return Button { select(day) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(day.formatted(.dateTime.day())).font(.callout.weight(isSelected || isToday ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(dayNumberColor(selected: isSelected, today: isToday, inMonth: inMonth))
                    .frame(width: 24, height: 24)
                    .background { if isSelected { Circle().fill(Color.accentColor) } }
                ForEach(items.prefix(3)) { task in
                    HStack(spacing: 4) {
                        Circle().fill(projectColor(task)).frame(width: 5, height: 5)
                        Text(task.title).font(.caption).lineLimit(1).foregroundStyle(inMonth ? .primary : .tertiary)
                    }
                }
                if items.count > 3 { Text("+\(items.count - 3) more").font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(isSelected ? Color.accentColor.opacity(0.06) : Color.clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .modifier(CalendarDayDrop(day: day))
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
        .accessibilityValue(items.isEmpty ? "No tasks" : "\(items.count) tasks")
        .accessibilityIdentifier("calendar-day-\(Dates.day(day))")
    }

    private func dayNumberColor(selected: Bool, today: Bool, inMonth: Bool) -> AnyShapeStyle {
        if selected { return AnyShapeStyle(Color.white) }
        if today { return AnyShapeStyle(Color.accentColor) }
        return inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
    }
    private func projectColor(_ task: Record) -> Color {
        store.record("projects", id: task.string("project_id")).map { Color.project($0.string("color")) } ?? .taskfold
    }

    // MARK: Year

    private func yearGrid(_ year: Date) -> some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                ForEach(0..<12, id: \.self) { offset in miniMonth(calendar.date(byAdding: .month, value: offset, to: year)!) }
            }.padding(16)
        }
    }
    private func miniMonth(_ month: Date) -> some View {
        let first = startOfWeek(month)
        let cells = days(from: first, count: 42)
        let isCurrent = calendar.isDate(month, equalTo: today, toGranularity: .month)
        let total = cells.filter { calendar.isDate($0, equalTo: month, toGranularity: .month) }.reduce(0) { $0 + open(on: $1) }
        return Button {
            withAnimation(layout) {
                workspace.calendarDay = isCurrent ? today : month
                workspace.calendarMode = .month
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(month.formatted(.dateTime.month(.wide))).font(.callout.weight(.semibold)).foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    Spacer()
                    if total > 0 { Text("\(total)").font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                    ForEach(cells, id: \.self) { day in
                        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
                        let count = inMonth ? open(on: day) : 0
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(count == 0 ? Color.primary.opacity(0.07) : Color.accentColor.opacity(min(1, 0.35 + Double(count) * 0.2)))
                            .aspectRatio(1, contentMode: .fit)
                            .opacity(inMonth ? 1 : 0)
                            .overlay { if calendar.isDate(day, inSameDayAs: today) { RoundedRectangle(cornerRadius: 2).strokeBorder(Color.accentColor, lineWidth: 1) } }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .modifier(CardSurface(radius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(month.formatted(.dateTime.month(.wide).year()))
        .accessibilityValue(total == 0 ? "No tasks" : "\(total) tasks")
    }

    // MARK: Selected day panel

    private var dayPanel: some View {
        @Bindable var workspace = workspace
        let items = tasks(on: selected)
        let count = open(on: selected)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(calendar.isDate(selected, inSameDayAs: today) ? "Today" : selected.formatted(.dateTime.weekday(.wide)))
                    .font(.headline).id(Dates.day(selected)).transition(.textSwap)
                HStack(spacing: 4) {
                    Text(selected.formatted(.dateTime.month(.wide).day().year()))
                    Text("·")
                    Text(count == 0 ? "Nothing planned" : count == 1 ? "1 task" : "\(count) tasks").id(count).transition(.textSwap)
                }.font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            .animation(Transitions.Ease.smoothOut, value: count)
            .animation(Transitions.Ease.smoothOut, value: selected)
            QuickAddBar(text: $quickAdd, focused: $quickAddFocused, prompt: "Add a task for this day") {
                if let id = workspace.add(quickAdd, date: selected) { quickAdd = ""; workspace.selection = [id] }
            }
            List(selection: $workspace.selection) {
                ForEach(items) { task in
                    TaskRowView(task: task, compactDate: true).tag(task.id).listRowSeparator(.hidden)
                        .modifier(DayDragRow(task: task, day: Dates.day(selected), orderProvider: { [(day: Dates.day(selected), ids: items.map(\.id))] }))
                }
                DayEndRow(day: Dates.day(selected), isEmpty: items.isEmpty).selectionDisabled().listRowSeparator(.hidden)
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, ids.count == 1 {
                    Button("Open in Inspector") { workspace.open(id) }
                    Button("Complete") { workspace.toggle(ids) }
                    Divider()
                    Button("Delete", role: .destructive) { workspace.delete(ids) }
                }
            } primaryAction: { ids in if let id = ids.first, ids.count == 1 { workspace.open(id) } }
            .onKeyPress(.space) { guard !workspace.selection.isEmpty else { return .ignored }; workspace.toggle(workspace.selection); return .handled }
            .onKeyPress(.return) { guard let id = workspace.selection.first, workspace.selection.count == 1 else { return .ignored }; workspace.open(id); return .handled }
            .onDeleteCommand { workspace.delete(workspace.selection) }
            .animation(layout, value: items.map(\.id))
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .safeAreaInset(edge: .bottom) { if let confirmation = workspace.confirmation { ConfirmationBar(confirmation: confirmation).transition(.toast) } }
        .accessibilityIdentifier("calendarDayPanel")
    }
}

/// Dropping tasks on a calendar day reschedules them to that day (end of the day's order).
struct CalendarDayDrop: ViewModifier {
    @Environment(Workspace.self) private var workspace
    let day: Date
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.accentColor.opacity(targeted ? 0.9 : 0), lineWidth: 2).padding(2))
            .background(Color.accentColor.opacity(targeted ? 0.08 : 0))
            .animation(Motion.quick, value: targeted)
            .onDrop(of: [.taskfoldTask], isTargeted: $targeted) { _ in
                let ids = workspace.drag.ids
                defer { workspace.drag.end() }
                guard !ids.isEmpty else { return false }
                return workspace.move(ids, to: DragSlot(day: Dates.day(day), before: nil))
            }
    }
}
