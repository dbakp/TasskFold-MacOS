import SwiftUI
import AppKit

/// The content column: a system List with native multi-selection, keyboard navigation, context menus, and
/// day sections that accept drags. Everything the iOS TaskScreen did with sheets happens in the inspector.
struct TaskListView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let scope: TaskScope
    let preferenceKey: String
    @AppStorage private var showCompleted: Bool
    @AppStorage private var priorityFilter: Int
    @AppStorage private var sortBy: String
    @AppStorage("defaultView") private var defaultView = "today"
    @AppStorage private var overdueCollapsed: Bool
    private var quickAdd: String {
        get { workspace.quickAdd }
        nonmutating set { workspace.quickAdd = newValue }
    }
    @State private var nativeList = ListNativeHandle()
    @State private var bulkDatePicker = false
    @State private var bulkDate = Date()
    @State private var projectEditor: Record?
    @State private var collaborationProject: Record?
    @State private var sectionsEditor = false
    @State private var quickAddVisible = false
    @State private var declinedGroups = Set<String>()
    @FocusState private var filterFocused: Bool

    init(scope: TaskScope, preferenceKey: String? = nil) {
        self.scope = scope
        self.preferenceKey = preferenceKey ?? scope.preferenceKey
        let prefix = "mac.view.\(preferenceKey ?? scope.preferenceKey)."
        _showCompleted = AppStorage(wrappedValue: false, prefix + "showCompleted")
        _priorityFilter = AppStorage(wrappedValue: 0, prefix + "priorityFilter")
        _sortBy = AppStorage(wrappedValue: "manual", prefix + "sortBy")
        _overdueCollapsed = AppStorage(wrappedValue: false, prefix + "overdueCollapsed")
    }

    private var dated: Bool { scope == .today || scope == .upcoming }
    private var projectID: String { if case .project(let id) = scope { return id }; return "" }
    private var overdueKey: String { "overdue:" + preferenceKey }
    private var overdueTasks: [Record] {
        ordered(filtered.filter { !$0.completed && !$0.string("due_date").isEmpty && $0.string("due_date") < Dates.day(Date()) }, day: overdueKey)
    }
    private var regularTasks: [Record] {
        let overdueIDs = Set(overdueTasks.map(\.id))
        return filtered.filter { !overdueIDs.contains($0.id) }
    }
    private var layout: Animation? { Motion.respecting(reduceMotion, Motion.layout) }
    private var title: String {
        switch scope {
        case .project(let id): return store.record("projects", id: id)?.name ?? "Project"
        case .label(let id): return store.record("labels", id: id)?.name ?? "Label"
        default: return scope.title
        }
    }
    /// "priority" was a sort option before bands became the default order; treat a stored value as default.
    private var manualOrder: Bool { sortBy == "manual" || sortBy == "priority" }
    private var filtered: [Record] {
        if workspace.section == .assigned {
            return workspace.assignedTasks.filter {
                (showCompleted || !$0.completed) && (priorityFilter == 0 || $0.priority == priorityFilter) &&
                (workspace.search.isEmpty || ($0.title + " " + $0.string("description")).localizedStandardContains(workspace.search))
            }
        }
        return store.matching(TaskQuery(scope: scope, text: workspace.search, includeCompleted: showCompleted, priority: priorityFilter, sort: manualOrder ? "manual" : sortBy, labelName: title))
    }
    private func ordered(_ tasks: [Record], day: String) -> [Record] { manualOrder ? workspace.arranged(tasks, key: day) : tasks }
    /// Non-dated lists rank inside device-local groups: one per project section, one per scope.
    private func groupKey(section: String?) -> String {
        if !projectID.isEmpty { return Workspace.Placement.group(project: projectID, section: section ?? "") }
        return Workspace.Placement.scope(scope)
    }
    private var dayGroups: [(String, [Record])] {
        let today = Dates.day(Date())
        let overdue = overdueTasks
        if scope == .today { return [("Overdue", overdue), (today, ordered(filtered.filter { $0.string("due_date") == today }, day: today))] }
        let future = filtered.filter { $0.string("due_date") >= today }
        var days = Set(future.map { $0.string("due_date") })
        for offset in 0..<14 { if let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) { days.insert(Dates.day(date)) } }
        return [("Overdue", overdue)] + days.sorted().map { day in (day, ordered(future.filter { $0.string("due_date") == day }, day: day)) }
    }
    private struct Group { var title: String; var key: String; var tasks: [Record] }
    private var groups: [Group] {
        if !projectID.isEmpty {
            let sections = store.rows("sections").filter { $0.string("project_id") == projectID }.sorted { $0["order_index"].integer < $1["order_index"].integer }
            let loose = Group(title: "Tasks", key: groupKey(section: nil), tasks: ordered(regularTasks.filter { $0.string("section_id").isEmpty }, day: groupKey(section: nil)))
            return [loose] + sections.map { section in
                let key = groupKey(section: section.id)
                return Group(title: section.name, key: key, tasks: ordered(regularTasks.filter { $0.string("section_id") == section.id }, day: key))
            }
        }
        let key = groupKey(section: nil)
        return [Group(title: "", key: key, tasks: ordered(regularTasks, day: key))]
    }
    private var displayedTaskIDs: [String] {
        if dated { return dayGroups.filter { $0.0 != "Overdue" || !overdueCollapsed }.flatMap { workspace.visibleTasks($0.1).map(\.id) } }
        return (overdueCollapsed ? [] : workspace.visibleTasks(overdueTasks).map(\.id)) + groups.flatMap { workspace.visibleTasks($0.tasks).map(\.id) }
    }
    private var order: [(day: String, ids: [String])] {
        if dated { return dayGroups.map { (day: $0.0 == "Overdue" ? overdueKey : $0.0, ids: $0.1.map(\.id)) } }
        return [(day: overdueKey, ids: overdueTasks.map(\.id))] + groups.map { (day: $0.key, ids: $0.tasks.map(\.id)) }
    }
    private var remaining: Int { filtered.filter { !$0.completed && !workspace.completing.contains($0.id) }.count }

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter current list", text: $workspace.search)
                        .textFieldStyle(.plain).focused($filterFocused)
                        .accessibilityIdentifier("listFilter")
                    if !workspace.search.isEmpty {
                        Button { workspace.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear filter")
                    }
                }
                .padding(7).frame(maxWidth: 220)
                .background(.quaternary, in: .rect(cornerRadius: 7))
                viewOptions
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: ReadingColumn.width).frame(maxWidth: .infinity)
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
                    if !overdueTasks.isEmpty { overdueSection(overdueTasks) }
                    ForEach(groups, id: \.key) { group in
                        if scope != .completed || !group.tasks.isEmpty || !group.title.isEmpty {
                            Section {
                                ForEach(workspace.visibleTasks(group.tasks)) { task in row(task).modifier(DayDragRow(task: task, day: group.key, orderProvider: { order })).tag(task.id) }
                                    .onMove { DayDropHandling(workspace: workspace, day: group.key, tasks: group.tasks).move(from: $0, to: $1) }
                                    .onInsert(of: [.taskfoldTask]) { DayDropHandling(workspace: workspace, day: group.key, tasks: group.tasks).insert(at: $0, providers: $1) }
                                if scope != .completed && manualOrder  {
                                    DayEndRow(day: group.key, isEmpty: group.tasks.isEmpty, emptyText: "No tasks", releaseText: "Release to move here").selectionDisabled().listRowSeparator(.hidden)
                                }
                            } header: { if !group.title.isEmpty { Text(group.title) } }
                        }
                    }
                }
            }
            .background(ListScrollMemory(key: preferenceKey, workspace: workspace, taskIDs: displayedTaskIDs, handle: nativeList))
            .accessibilityIdentifier("taskList")
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
        .onAppear { if workspace.section.scope == scope { workspace.navigationSubtitle = subtitle } }
        .onChange(of: subtitle) { _, value in if workspace.section.scope == scope { workspace.navigationSubtitle = value } }
        .animation(Transitions.Ease.smoothOut, value: subtitle)
        .toolbar { if workspace.section.scope == scope { toolbar } }
        .sheet(isPresented: $quickAddVisible) {
            TaskCapturePanel(text: $workspace.quickAdd, declined: $declinedGroups, destination: title, prompt: quickAddPrompt, submit: submitQuickAdd)
        }
        .sheet(item: $projectEditor) { NamedEditor(table: "projects", record: $0) }
        .sheet(item: $collaborationProject) { CollaboratorsView(project: $0) }
        .sheet(isPresented: $sectionsEditor) { SectionsEditor(projectID: projectID) }
        .sheet(isPresented: $bulkDatePicker) { DatePickSheet(date: $bulkDate, count: workspace.selection.count) { workspace.reschedule(workspace.selection, to: Dates.day(bulkDate), label: bulkDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) } }
        .onChange(of: workspace.quickAddFocusRequest) { _, _ in if workspace.section.scope == scope { revealQuickAdd() } }
        .onChange(of: workspace.searchPresented) { _, requested in
            if requested && workspace.section.scope == scope { filterFocused = true; workspace.searchPresented = false }
        }
        .onDisappear { quickAddVisible = false }
        .onChange(of: displayedTaskIDs) { _, ids in
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
    }

    /// A date line and a count; no tagline copy.
    private var subtitle: String {
        if scope == .completed { return "\(filtered.count) completed" }
        let count = remaining == 1 ? "1 task" : "\(remaining) tasks"
        if scope == .today { return Date().formatted(.dateTime.weekday(.wide).day().month(.wide)) + " · " + count }
        return count
    }
    private var quickAddPrompt: String {
        switch scope {
        case .today: return "Add a task for today — try “Call Sam at 4pm p1 #calls”"
        case .upcoming: return "Add a task — try “Send report friday”"
        case .inbox: return "Add to Inbox"
        default: return "Add a task to \(title)"
        }
    }
    private func revealQuickAdd() { quickAddVisible = true }

    private func submitQuickAdd() {
        let date: Date? = scope == .today ? Date() : scope == .upcoming ? Calendar.current.date(byAdding: .day, value: 1, to: Date()) : nil
        let labelName: String? = { if case .label(let id) = scope { return store.record("labels", id: id)?.name }; return nil }()
        guard let id = workspace.add(quickAdd, project: projectID, date: date, declined: declinedGroups) else { return }
        declinedGroups = []
        if let labelName, var task = store.record("tasks", id: id), !task["labels"].list.contains(.string(labelName)) {
            task["labels"] = .array(task["labels"].list + [.string(labelName)]); store.save("tasks", task)
        }
        quickAdd = ""
        quickAddVisible = false
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
        Section {
            if !overdueCollapsed {
                ForEach(workspace.visibleTasks(tasks)) { task in row(task).modifier(DayDragRow(task: task, day: overdueKey, orderProvider: { order })).tag(task.id) }
                    .onMove { DayDropHandling(workspace: workspace, day: overdueKey, tasks: tasks).move(from: $0, to: $1) }
                    .onInsert(of: [.taskfoldTask]) { DayDropHandling(workspace: workspace, day: overdueKey, tasks: tasks).insert(at: $0, providers: $1) }
            }
        } header: {
            Button { withAnimation(layout) { overdueCollapsed.toggle() } } label: {
            HStack(spacing: 8) {
                Image(systemName: overdueCollapsed ? "chevron.right" : "chevron.down").font(.caption.weight(.semibold))
                Text("Overdue")
                Text("\(tasks.count)").font(.caption.weight(.semibold)).monospacedDigit().padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.red.opacity(0.14), in: .capsule).foregroundStyle(.red).contentTransition(.numericText())
                    .transition(reduceMotion ? .opacity : .badgePop)
            }
            }.buttonStyle(.plain)
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
            ForEach(workspace.visibleTasks(tasks)) { task in row(task).modifier(DayDragRow(task: task, day: day, orderProvider: { order })).tag(task.id) }
                .onMove { DayDropHandling(workspace: workspace, day: day, tasks: tasks).move(from: $0, to: $1) }
                .onInsert(of: [.taskfoldTask]) { DayDropHandling(workspace: workspace, day: day, tasks: tasks).insert(at: $0, providers: $1) }
            DayEndRow(day: day, isEmpty: tasks.isEmpty).selectionDisabled().listRowSeparator(.hidden)
        } header: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name).foregroundStyle(day == today ? Color.taskfold : .primary)
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
        TaskRowView(task: task, compactDate: dated).background(ListScrollRowMarker(id: task.id, handle: nativeList)).id(task.id).listRowSeparator(.hidden)
    }

    // MARK: Menus

    @ViewBuilder private func contextMenu(_ ids: Set<String>) -> some View {
        let targets = ids.isEmpty ? workspace.selection : ids
        let tasks = targets.compactMap { workspace.taskRecord($0) }
        if tasks.isEmpty {
            Button("New Task") { revealQuickAdd() }
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

    private var viewOptions: some View {
            Menu {
                Button(defaultView == preferenceKey ? "Default View ✓" : "Make Default View", systemImage: "house") { defaultView = preferenceKey }
                Toggle("Show Completed", isOn: $showCompleted)
                Picker("Priority", selection: $priorityFilter) { Text("All Priorities").tag(0); ForEach(1...4, id: \.self) { Text("Priority \($0)").tag($0) } }
                Picker("Sort", selection: Binding(get: { manualOrder ? "manual" : sortBy }, set: { sortBy = $0 })) { Text("Default Order").tag("manual"); Text("Due Date").tag("date"); Text("Title").tag("title") }
                if !projectID.isEmpty {
                    Divider()
                    Button("Edit Project…", systemImage: "pencil") { projectEditor = store.record("projects", id: projectID) }
                    Button("Sections…", systemImage: "rectangle.split.3x1") { sectionsEditor = true }
                    Button("Collaborators…", systemImage: "person.2") { collaborationProject = store.record("projects", id: projectID) }.disabled(store.localMode)
                }
            } label: { Label("View Options", systemImage: "line.3.horizontal.decrease.circle") }
                .help("View options").accessibilityLabel("Task options")
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if scope == .today || scope == .upcoming {
                Button { workspace.planning = scope == .today ? .day : .week } label: { Label(scope == .today ? "Plan Your Day" : "Review This Week", systemImage: "sparkles") }
                    .help(scope == .today ? "Triage overdue and today's tasks one at a time (⌥⌘P)" : "Review the next seven days one task at a time (⌥⌘W)")
                    .disabled(workspace.planQueue(scope == .today ? .day : .week).isEmpty)
                    .accessibilityIdentifier("planButton")
            }
            Button { revealQuickAdd() } label: { Label("New Task", systemImage: "plus") }
                .help("New Task (⌘N)").accessibilityIdentifier("addTask")

        }
        ToolbarItem(placement: .primaryAction) {
            Button { workspace.inspectorShown.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                .help("Show or hide the inspector (⌥⌘I)")
        }
    }
}

/// Content reads best in a bounded column centered in the window, the way Todoist lays out its lists.
enum ReadingColumn { static let width: CGFloat = 860 }

/// A focused, native sheet keeps capture prominent without moving the task list.
struct TaskCapturePanel: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    @Binding var declined: Set<String>
    let destination: String
    let prompt: String
    let submit: () -> Void
    @FocusState private var focused: Bool
    private var parsed: QuickEntry { QuickEntry(text, disabled: declined) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Task").font(.title2.weight(.semibold))
                    Label(destination, systemImage: "tray").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.body.weight(.medium)) }
                    .buttonStyle(.plain).help("Close (Esc)").accessibilityLabel("Close task entry")
            }
            TextField(prompt, text: $text, axis: .vertical)
                .font(.title3).lineLimit(2...4).textFieldStyle(.plain)
                .focused($focused).accessibilityIdentifier("quickAdd")
                .padding(16)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.taskfold.opacity(focused ? 0.6 : 0.2), lineWidth: 1))
                .onSubmit(submit)
            if !parsed.tokens.isEmpty {
                QuickEntryChips(tokens: parsed.tokens, compact: true, decline: { token in _ = declined.insert(token.group) }, returnFocus: { focused = true })
            }
            HStack {
                Text("Try “Call Sam tomorrow at 4pm p1”").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add Task", action: submit).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(parsed.title.isEmpty)
            }
        }
        .padding(24).frame(width: 540)
        .onAppear { focused = true }
        .onExitCommand { dismiss() }
        .onChange(of: text) { _, value in if value.isEmpty { declined = [] } }
    }
}

/// A brief confirmation at the foot of the list. It never blocks; it just names what happened and offers Undo.
struct ConfirmationBar: View {
    @Environment(Workspace.self) private var workspace
    let confirmation: Confirmation
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.taskfold).id(confirmation.id).transition(.iconSwap)
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
