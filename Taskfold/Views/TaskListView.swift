import SwiftUI
import AppKit

/// The content column: a system List with native multi-selection, keyboard navigation, context menus, and
/// day sections that accept drags. Everything the iOS TaskScreen did with sheets happens in the inspector.
struct TaskListView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let scope: TaskScope
    @AppStorage("showCompleted") private var showCompleted = false
    @AppStorage("priorityFilter") private var priorityFilter = 0
    @AppStorage("sortBy") private var sortBy = "manual"
    @AppStorage("defaultView") private var defaultView = "today"
    @AppStorage("overdueCollapsedToday") private var overdueCollapsedToday = false
    @AppStorage("overdueCollapsedUpcoming") private var overdueCollapsedUpcoming = false
    private var quickAdd: String {
        get { workspace.quickAdd }
        nonmutating set { workspace.quickAdd = newValue }
    }
    @State private var bulkDatePicker = false
    @State private var bulkDate = Date()
    @State private var projectEditor: Record?
    @State private var collaborationProject: Record?
    @State private var sectionsEditor = false
    @FocusState private var quickAddFocused: Bool

    private var dated: Bool { scope == .today || scope == .upcoming }
    private var projectID: String { if case .project(let id) = scope { return id }; return "" }
    private var overdueCollapsed: Bool { scope == .today ? overdueCollapsedToday : overdueCollapsedUpcoming }
    private var layout: Animation? { Motion.respecting(reduceMotion, Motion.layout) }
    private var title: String {
        switch scope {
        case .project(let id): return store.record("projects", id: id)?.name ?? "Project"
        case .label(let id): return store.record("labels", id: id)?.name ?? "Label"
        default: return scope.title
        }
    }
    private var filtered: [Record] {
        store.matching(TaskQuery(scope: scope, text: workspace.search, includeCompleted: showCompleted, priority: priorityFilter, sort: sortBy, labelName: title))
    }
    private func ordered(_ tasks: [Record], day: String) -> [Record] { sortBy == "manual" ? workspace.ordered(tasks, day: day) : tasks }
    private var dayGroups: [(String, [Record])] {
        let today = Dates.day(Date())
        let overdue = filtered.filter { !$0.completed && $0.string("due_date") < today }
        if scope == .today { return [("Overdue", overdue), (today, ordered(filtered.filter { $0.string("due_date") == today }, day: today))] }
        let future = filtered.filter { $0.string("due_date") >= today }
        var days = Set(future.map { $0.string("due_date") })
        for offset in 0..<14 { if let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) { days.insert(Dates.day(date)) } }
        return [("Overdue", overdue)] + days.sorted().map { day in (day, ordered(future.filter { $0.string("due_date") == day }, day: day)) }
    }
    private var groups: [(String, [Record])] {
        if !projectID.isEmpty {
            let sections = store.rows("sections").filter { $0.string("project_id") == projectID }.sorted { $0["order_index"].integer < $1["order_index"].integer }
            return [("Tasks", filtered.filter { $0.string("section_id").isEmpty })] + sections.map { section in (section.name, filtered.filter { $0.string("section_id") == section.id }) }
        }
        return [("", filtered)]
    }
    private var order: [(day: String, ids: [String])] { dayGroups.filter { $0.0 != "Overdue" }.map { (day: $0.0, ids: $0.1.map(\.id)) } }
    private var remaining: Int { filtered.filter { !$0.completed && !workspace.completing.contains($0.id) }.count }

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            QuickAddBar(text: $workspace.quickAdd, focused: $quickAddFocused, prompt: quickAddPrompt) { submitQuickAdd() }
                .frame(maxWidth: ReadingColumn.width).frame(maxWidth: .infinity)
                .background(.bar)
            List(selection: Binding(get: { workspace.section.scope == scope ? workspace.selection : [] }, set: { selection in
                guard workspace.section.scope == scope else { return }
                workspace.selection = selection
            })) {
                if !store.online || store.notice != nil { statusRow }
                if store.syncing && store.tasks.isEmpty && store.lastSync == nil && !store.localMode { SkeletonRows().padding(.vertical, 12).selectionDisabled().listRowSeparator(.hidden).transition(.skeletonReveal) }
                if filtered.isEmpty && !dated { emptyState }
                if dated {
                    ForEach(dayGroups, id: \.0) { group in
                        if group.0 == "Overdue" { if !group.1.isEmpty { overdueSection(group.1) } }
                        else { daySection(group.0, group.1) }
                    }
                } else {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        if !group.1.isEmpty || !group.0.isEmpty {
                            Section {
                                ForEach(group.1) { task in row(task).tag(task.id) }
                            } header: { if !group.0.isEmpty { Text(group.0) } }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: ReadingColumn.width).frame(maxWidth: .infinity)
            .contextMenu(forSelectionType: String.self) { ids in contextMenu(ids) } primaryAction: { ids in
                if let id = ids.first, ids.count == 1 { workspace.open(id) }
            }
            .onDeleteCommand { workspace.delete(workspace.selection) }
            .animation(layout, value: filtered.map(\.id))
        }
        .background(Color(nsColor: .textBackgroundColor))
        .safeAreaInset(edge: .bottom) { if let confirmation = workspace.confirmation { ConfirmationBar(confirmation: confirmation).transition(reduceMotion ? .opacity : .toast) } }
        .animation(Transitions.Ease.smoothOut, value: workspace.confirmation)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .animation(Transitions.Ease.smoothOut, value: subtitle)
        .toolbar { toolbar }
        .sheet(item: $projectEditor) { NamedEditor(table: "projects", record: $0) }
        .sheet(item: $collaborationProject) { CollaboratorsView(project: $0) }
        .sheet(isPresented: $sectionsEditor) { SectionsEditor(projectID: projectID) }
        .sheet(isPresented: $bulkDatePicker) { DatePickSheet(date: $bulkDate, count: workspace.selection.count) { workspace.reschedule(workspace.selection, to: Dates.day(bulkDate), label: bulkDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) } }
        .onChange(of: workspace.quickAddFocusRequest) { _, _ in quickAddFocused = true }
        .onChange(of: workspace.selection) { _, selection in if !selection.isEmpty && quickAdd.isEmpty { quickAddFocused = false } }
        .onChange(of: filtered.map(\.id)) { _, ids in
            // Assign only when something actually left the list; re-setting selection during a table update is reentrant.
            guard workspace.section.scope == scope else { return }
            let kept = workspace.selection.intersection(ids)
            if kept != workspace.selection {
                Task { @MainActor in
                    // A departed list must not clear the destination's restored selection.
                    guard workspace.section.scope == scope else { return }
                    workspace.selection.formIntersection(ids)
                }
            }
        }
        .onAppear { if ProcessInfo.processInfo.arguments.contains("--uitesting") == false && filtered.isEmpty && workspace.selection.isEmpty { quickAddFocused = true } }
    }

    private var subtitle: String {
        if scope == .completed { return "\(filtered.count) completed" }
        if scope == .today { return remaining == 0 ? "Nothing left for today" : remaining == 1 ? "1 task to focus on" : "\(remaining) tasks to focus on" }
        return remaining == 1 ? "1 task" : "\(remaining) tasks"
    }
    private var quickAddPrompt: String {
        switch scope {
        case .today: return "Add a task for today — try “Call Sam at 4pm p1 #calls”"
        case .upcoming: return "Add a task — try “Send report friday”"
        case .inbox: return "Add to Inbox"
        default: return "Add a task to \(title)"
        }
    }
    private func submitQuickAdd() {
        let date: Date? = scope == .today ? Date() : scope == .upcoming ? Calendar.current.date(byAdding: .day, value: 1, to: Date()) : nil
        let labelName: String? = { if case .label(let id) = scope { return store.record("labels", id: id)?.name }; return nil }()
        guard let id = workspace.add(quickAdd, project: projectID, date: date) else { return }
        if let labelName, var task = store.record("tasks", id: id), !task["labels"].list.contains(.string(labelName)) {
            task["labels"] = .array(task["labels"].list + [.string(labelName)]); store.save("tasks", task)
        }
        quickAdd = ""
        workspace.selection = [id]
    }

    // MARK: Rows and sections

    @ViewBuilder private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: store.online ? "exclamationmark.icloud" : "wifi.slash").foregroundStyle(.orange)
            Text(!store.online ? "Offline · changes are saved on this Mac and sync later." : store.notice ?? "")
            Spacer()
            if store.notice != nil && store.online { Button("Retry") { Task { await store.sync() } }.buttonStyle(.link) }
        }.font(.callout).foregroundStyle(.secondary).selectionDisabled().listRowSeparator(.hidden)
    }
    private var emptyState: some View {
        ContentUnavailableView {
            Label(workspace.search.isEmpty ? "All clear" : "No matching tasks", systemImage: workspace.search.isEmpty ? "checkmark.seal" : "magnifyingglass")
        } description: {
            Text(workspace.search.isEmpty ? "Press ⌘N to add something new." : "Try a different search or filter.")
        }
        .selectionDisabled().listRowSeparator(.hidden).frame(minHeight: 260)
    }
    private func overdueSection(_ tasks: [Record]) -> some View {
        Section(isExpanded: Binding(get: { !overdueCollapsed }, set: { open in withAnimation(layout) { if scope == .today { overdueCollapsedToday = !open } else { overdueCollapsedUpcoming = !open } } })) {
            ForEach(tasks) { task in row(task).modifier(DayDragRow(task: task, day: task.string("due_date"), orderProvider: { order })).tag(task.id) }
        } header: {
            HStack(spacing: 8) {
                Text("Overdue")
                Text("\(tasks.count)").font(.caption.weight(.semibold)).monospacedDigit().padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.red.opacity(0.14), in: .capsule).foregroundStyle(.red).contentTransition(.numericText())
                    .transition(reduceMotion ? .opacity : .badgePop)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Overdue, \(tasks.count) tasks")
            .accessibilityValue(overdueCollapsed ? "Collapsed" : "Expanded")
            .accessibilityIdentifier("overdueToggle")
        }
    }
    private func daySection(_ day: String, _ tasks: [Record]) -> some View {
        let today = Dates.day(Date())
        let tomorrow = Dates.day(Calendar.current.date(byAdding: .day, value: 1, to: Date())!)
        let date = Dates.parse(day)
        let name = day == today ? "Today" : day == tomorrow ? "Tomorrow" : date?.formatted(.dateTime.weekday(.wide)) ?? day
        let detail = date?.formatted(.dateTime.month(.abbreviated).day()) ?? ""
        let open = tasks.filter { !$0.completed && !workspace.completing.contains($0.id) }.count
        return Section {
            ForEach(tasks) { task in row(task).modifier(DayDragRow(task: task, day: day, orderProvider: { order })).tag(task.id) }
            DayEndRow(day: day, isEmpty: tasks.isEmpty).selectionDisabled().listRowSeparator(.hidden)
        } header: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name).foregroundStyle(day == today ? Color.accentColor : .primary)
                if !(scope == .today && day == today) { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                Spacer()
                if open > 0 { Text("\(open)").font(.caption).monospacedDigit().foregroundStyle(.tertiary).contentTransition(.numericText()) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("day-\(day)")
            .modifier(DayHeaderDrop(day: day))
        }
    }
    /// The selection tag must sit on the outermost row view, after any drag wrapper, or clicks cannot select.
    private func row(_ task: Record) -> some View {
        TaskRowView(task: task, compactDate: dated).listRowSeparator(.hidden)
    }

    // MARK: Menus

    @ViewBuilder private func contextMenu(_ ids: Set<String>) -> some View {
        let targets = ids.isEmpty ? workspace.selection : ids
        let tasks = targets.compactMap { store.record("tasks", id: $0) }
        if tasks.isEmpty {
            Button("New Task") { quickAddFocused = true }
        } else {
            if tasks.count == 1, let task = tasks.first { Button("Edit “\(task.title)”") { workspace.open(task.id) } }
            Button(tasks.allSatisfy(\.completed) ? "Reopen" : "Complete") { workspace.toggle(targets) }
            Divider()
            Menu("Reschedule") {
                Button("Today", systemImage: "sun.max") { workspace.reschedule(targets, to: Dates.day(Date()), label: "today") }
                Button("Tomorrow", systemImage: "sunrise") { workspace.reschedule(targets, to: Dates.day(Calendar.current.date(byAdding: .day, value: 1, to: Date())!), label: "tomorrow") }
                Button("This Weekend", systemImage: "beach.umbrella") { workspace.reschedule(targets, to: Dates.day(Workspace.next(weekday: 7)), label: "the weekend") }
                Button("Next Week", systemImage: "calendar.badge.clock") { workspace.reschedule(targets, to: Dates.day(Workspace.next(weekday: 2)), label: "next week") }
                Button("Pick a Date…", systemImage: "calendar") { workspace.selection = targets; bulkDate = Date(); bulkDatePicker = true }
                Divider()
                Button("Remove Date", systemImage: "calendar.badge.minus") { workspace.reschedule(targets, to: nil, label: "") }
            }
            Menu("Move to") {
                Button("Inbox", systemImage: "tray") { workspace.move(targets, toProject: "") }
                ForEach(store.projects) { project in Button(project.name, systemImage: "folder") { workspace.move(targets, toProject: project.id) } }
            }
            Menu("Priority") { ForEach(1...4, id: \.self) { n in Button(n == 4 ? "None" : "Priority \(n)", systemImage: "flag") { workspace.setPriority(targets, n) } } }
            Button("Duplicate", systemImage: "doc.on.doc") { workspace.duplicate(targets) }
            if tasks.count == 1, let task = tasks.first {
                Button("Copy Title", systemImage: "doc.on.clipboard") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(task.title + (task.string("description").isEmpty ? "" : "\n" + task.string("description")), forType: .string) }
            }
            Divider()
            Button(tasks.count == 1 ? "Delete" : "Delete \(tasks.count) Tasks", systemImage: "trash", role: .destructive) { workspace.delete(targets) }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { quickAddFocused = true } label: { Label("New Task", systemImage: "plus") }
                .help("New Task (⌘N)").accessibilityIdentifier("addTask")
            Menu {
                Button(defaultView == scope.preferenceKey ? "Default View ✓" : "Make Default View", systemImage: "house") { defaultView = scope.preferenceKey }
                Toggle("Show Completed", isOn: $showCompleted)
                Picker("Priority", selection: $priorityFilter) { Text("All Priorities").tag(0); ForEach(1...4, id: \.self) { Text("Priority \($0)").tag($0) } }
                Picker("Sort", selection: $sortBy) { Text("Default Order").tag("manual"); Text("Priority").tag("priority"); Text("Due Date").tag("date"); Text("Title").tag("title") }
                if !projectID.isEmpty {
                    Divider()
                    Button("Edit Project…", systemImage: "pencil") { projectEditor = store.record("projects", id: projectID) }
                    Button("Sections…", systemImage: "rectangle.split.3x1") { sectionsEditor = true }
                    Button("Collaborators…", systemImage: "person.2") { collaborationProject = store.record("projects", id: projectID) }.disabled(store.localMode)
                }
            } label: { Label("View Options", systemImage: "line.3.horizontal.decrease.circle") }
                .help("View options").accessibilityLabel("Task options")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { workspace.inspectorShown.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                .help("Show or hide the inspector (⌥⌘I)")
        }
    }
}

/// Content reads best in a bounded column centered in the window, the way Todoist lays out its lists.
enum ReadingColumn { static let width: CGFloat = 860 }

/// The entry field above the list. Quick-entry grammar is parsed by the shared `QuickEntry` type.
struct QuickAddBar: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let prompt: String
    let submit: () -> Void
    private var parsed: QuickEntry { QuickEntry(text) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill").foregroundStyle(text.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor)).font(.title3)
                    .animation(Motion.quick, value: text.isEmpty)
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .focused(focused)
                    .onSubmit(submit)
                    .accessibilityIdentifier("quickAdd")
                if !text.isEmpty {
                    if parsed.hasSuggestions { suggestions }
                    Button("Add", action: submit).keyboardShortcut(.defaultAction).controlSize(.small).buttonStyle(.borderedProminent)
                        .disabled(parsed.title.isEmpty)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .animation(Motion.quick, value: text.isEmpty)
            Divider()
        }
    }
    private var suggestions: some View {
        HStack(spacing: 6) {
            if let date = parsed.updates["due_date"]?.text, let day = Dates.parse(date) { chip(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), "calendar") }
            if let time = parsed.updates["due_time"]?.text { chip(TaskRowView.timeText(time), "clock") }
            if let priority = parsed.updates["priority"]?.integer { chip("P\(priority)", "flag") }
            if parsed.updates["is_recurring"]?.flag == true { chip("Repeats", "repeat") }
            ForEach(parsed.updates["labels"]?.list.map(\.text) ?? [], id: \.self) { label in chip(label, "tag") }
        }
        .font(.caption).foregroundStyle(.secondary)
        .transition(.opacity)
    }
    private func chip(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).padding(.horizontal, 7).padding(.vertical, 3).background(Color.secondary.opacity(0.1), in: .capsule)
    }
}

/// A brief confirmation at the foot of the list. It never blocks; it just names what happened and offers Undo.
struct ConfirmationBar: View {
    @Environment(Workspace.self) private var workspace
    let confirmation: Confirmation
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).id(confirmation.id).transition(.iconSwap)
            Text(confirmation.message).lineLimit(1).id(confirmation.id).transition(.textSwap)
            Spacer()
            if confirmation.undoable {
                Button("Undo") { workspace.undoFromConfirmation() }.buttonStyle(.link).accessibilityIdentifier("undoConfirmation")
                Text("⌘Z").foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

/// Graphical date picker for rescheduling several tasks at once.
struct DatePickSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var date: Date
    let count: Int
    let confirm: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Text("Pick a date").font(.headline)
            DatePicker("Date", selection: $date, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(count == 1 ? "Reschedule Task" : "Reschedule \(count) Tasks") { confirm(); dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 320)
    }
}
