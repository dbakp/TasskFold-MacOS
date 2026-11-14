import SwiftUI
import AppKit

/// The content column: a system List with native multi-selection, keyboard navigation, context menus, and
/// day sections that accept drags. Everything the iOS TaskScreen did with sheets happens in the inspector.
/// Empty states ease in with a fade and a slight scale (0.96 to 1); Reduce Motion keeps only the fade.
struct EmptyStateAppear: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown || reduceMotion ? 1 : Transitions.Scale.large)
            .onAppear { withAnimation(Motion.respecting(reduceMotion, Transitions.Ease.smoothOut(Transitions.Duration.medium))) { shown = true } }
    }
}

/// The ids shown on the previous render, so a lingering row can be put back where it was.
final class RowOrderMemory { var ids: [String] = [] }

struct TaskListView: View {
    @Environment(Store.self) private var store
    @Environment(\.openPinnedNotes) private var openPinnedNotes
    @Environment(\.openFocusSession) private var openFocusSession
    @Environment(\.openProjectPulse) private var openProjectPulse
    @Environment(\.startInboxReview) private var startInboxReview
    @Environment(Workspace.self) private var workspace
    @Environment(TaskPrintCommand.self) private var printCommand
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let scope: TaskScope
    let preferenceKey: String
    private var showCompleted: Bool { get { store.viewValue(scope, field: "include_completed", fallback: .bool(false)).flag } nonmutating set { store.setViewValue(scope, field: "include_completed", value: .bool(newValue)) } }
    private var priorityFilter: Int { get { store.viewValue(scope, field: "priority_filter", fallback: .number(0)).integer } nonmutating set { store.setViewValue(scope, field: "priority_filter", value: .number(Double(newValue))) } }
    private var sortBy: String { get { store.viewValue(scope, field: "sort_by", fallback: .string("manual")).text } nonmutating set { store.setViewValue(scope, field: "sort_by", value: .string(newValue)) } }
    @AppStorage("defaultView") private var defaultView = "today"
    /// Device-local, so the shared view-preference rows keep their schema.
    @AppStorage("showBlockedTasks.today") private var showBlockedToday = false
    @AppStorage("showBlockedTasks.upcoming") private var showBlockedUpcoming = false
    private var showBlockedBinding: Binding<Bool>? {
        switch scope { case .today: return $showBlockedToday; case .upcoming: return $showBlockedUpcoming; default: return nil }
    }
    private var overdueCollapsed: Bool { get { store.viewValue(scope, field: "overdue_collapsed", fallback: .bool(false)).flag } nonmutating set { store.setViewValue(scope, field: "overdue_collapsed", value: .bool(newValue)) } }
    private var quickAdd: String {
        get { workspace.quickAdd }
        nonmutating set { workspace.quickAdd = newValue }
    }
    @AppStorage("mac.collapsedProjectSections") private var collapsedSections = ""
    private var storedLayout: String { get { store.viewValue(scope, field: "layout", fallback: .string("list")).text } nonmutating set { store.setViewValue(scope, field: "layout", value: .string(newValue)) } }
    /// What the scope shows now. A stored value the scope cannot show reads as List and is not rewritten.
    private var layoutMode: TaskLayout { TaskLayout.resolved(storedLayout, for: scope) }
    private var boardLayout: Bool { layoutMode == .board && !isSavedFilterScope }
    private var calendarLayout: Bool { layoutMode == .calendar }
    @State private var calendarMonth = Date()
    @State private var calendarDay = Dates.day(Date())
    @State private var captureDateOverride: Date?
    @State private var captureProjectOverride: String?
    @State private var multiLinePresented = false
    @State private var printReview: PrintReviewRequest?
    @State private var printOwner = UUID()
    @State private var printFailure: String?
    @State private var captureSection = ""
    @State private var nativeList = ListNativeHandle()
    @State private var rowSwipe = MacRowSwipeController()
    @State private var orderMemory = RowOrderMemory()
    @AppStorage("mac.rowGesture.leading") private var leadingGesture = "complete"
    @AppStorage("mac.rowGesture.trailing") private var trailingGesture = "tomorrow"
    @AppStorage("mac.rowGesture.fullSwipe") private var fullSwipe = false
    @Environment(\.layoutDirection) private var gestureLayoutDirection
    @State private var bulkDatePicker = false
    @State private var bulkDate = Date()
    @State private var projectEditor: Record?
    @State private var workflowCapture: WorkflowCaptureRequest?
    @State private var collaborationProject: Record?
    @State private var sectionsEditor = false
    @State private var filterEditor: Record?
    @State private var referenceChoices: [String: String] = [:]
    @State private var quickAddVisible = false
    @State private var declinedGroups = Set<String>()
    @FocusState private var filterFocused: Bool
    @State private var momentum = MomentumModel()
    @Environment(\.openInsights) private var openInsights
    @FocusState private var taskListFocused: Bool

    init(scope: TaskScope, preferenceKey: String? = nil) {
        self.scope = scope
        self.preferenceKey = preferenceKey ?? scope.preferenceKey
    }

    private var dated: Bool { scope == .today || scope == .upcoming }
    private var projectID: String { if case .project(let id) = scope { return id }; return "" }
    private var overdueKey: String { "overdue:" + preferenceKey }
    private var overdueTasks: [Record] {
        if case .saved = scope { return [] }
        let today = Dates.day(Date()); var planningRead = TaskPlannedDayRead()
        return ordered(filtered.filter { task in
            guard !task.completed else { return false }
            let day = planningRead.day(task)
            return !day.isEmpty && day < today
        }, day: overdueKey)
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
        case .saved(let id): return store.record("saved_views", id: id)?.name ?? "Unavailable filter"
        default: return scope.title
        }
    }
    /// "priority" was a sort option before bands became the default order; treat a stored value as default.
    private var manualOrder: Bool { sortBy == "manual" || sortBy == "priority" }
    /// Rows that were just checked keep their place for a beat. Their pre-completion record is put back where it
    /// was (the order seen on the previous render) while the store already holds the completed or advanced record.
    private var filtered: [Record] {
        let base = unlingeredRows
        let pending = workspace.activeLingering(scopeKey: preferenceKey)
        guard !pending.isEmpty else { return base }
        var rows = base.filter { row in !pending.contains { $0.before.id == row.id } }
        for entry in pending.sorted(by: { (orderMemory.ids.firstIndex(of: $0.before.id) ?? .max) < (orderMemory.ids.firstIndex(of: $1.before.id) ?? .max) }) {
            guard let position = orderMemory.ids.firstIndex(of: entry.before.id) else { continue }
            let predecessor = orderMemory.ids[..<position].last { id in rows.contains { $0.id == id } }
            let index = predecessor.flatMap { id in rows.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
            rows.insert(entry.before, at: min(index, rows.count))
        }
        return rows
    }
    private var unlingeredRows: [Record] {
        if workspace.section == .assigned {
            return workspace.assignedTasks.filter {
                (showCompleted || !$0.completed) && (priorityFilter == 0 || $0.priority == priorityFilter) &&
                (workspace.search.isEmpty || ($0.title + " " + $0.string("description")).localizedStandardContains(workspace.search))
            }
        }
        return store.matching(taskQuery)
    }
    private var taskQuery: TaskQuery {
        TaskQuery(scope: scope, text: workspace.search, includeCompleted: showCompleted, priority: priorityFilter, sort: manualOrder ? "manual" : sortBy, labelName: title, showBlocked: showBlockedBinding?.wrappedValue ?? false)
    }
    private func ordered(_ tasks: [Record], day: String) -> [Record] { manualOrder ? workspace.arranged(tasks, key: day) : tasks }
    /// Non-dated lists rank inside device-local groups: one per project section, one per scope.
    private func groupKey(section: String?) -> String {
        if !projectID.isEmpty { return Workspace.Placement.group(project: projectID, section: section ?? "") }
        return Workspace.Placement.scope(scope)
    }
    private var dayGroups: [(String, [Record])] {
        let now = Date(), calendar = Calendar.current, today = Dates.day(now)
        let read = workspace.section == .assigned ? TaskDayGroupsRead(tasks: filtered, today: today, calendar: calendar) : store.taskDayGroups(taskQuery, today: today, calendar: calendar)
        if scope == .today {
            // This Evening takes its tasks out of Overdue and Today without touching their dates.
            let evening = store.eveningPartition(read.overdue + (read.rowsByDay[today] ?? [])).evening
            let eveningIDs = Set(evening.map(\.id))
            let overdue = ordered(read.overdue.filter { !eveningIDs.contains($0.id) }, day: overdueKey)
            return [("Overdue", overdue), (today, ordered((read.rowsByDay[today] ?? []).filter { !eveningIDs.contains($0.id) }, day: today)), (Workspace.Placement.evening, evening)]
        }
        let overdue = ordered(read.overdue, day: overdueKey)
        let horizon = (0..<14).compactMap { calendar.date(byAdding: .day, value: $0, to: now).map(Dates.day) }
        return [("Overdue", overdue)] + read.upcomingDays(adding: horizon).map { day in (day, ordered(read.rowsByDay[day] ?? [], day: day)) }
    }
    private struct Group { var title: String; var key: String; var tasks: [Record] }
    private var groups: [Group] {
        if case .saved = scope {
            return store.filterGroups(scope, tasks: filtered, includeCompleted: showCompleted).map { Group(title: $0.name, key: "scope:" + scope.preferenceKey + ":group:" + $0.id, tasks: ordered($0.tasks, day: "scope:" + scope.preferenceKey + ":group:" + $0.id)) }
        }
        if !projectID.isEmpty {
            let read = ProjectSectionTaskRead(project: projectID, sections: store.rows("sections"), tasks: regularTasks)
            let loose = Group(title: "Tasks", key: groupKey(section: nil), tasks: ordered(read.tasks(in: ""), day: groupKey(section: nil)))
            return [loose] + read.sections.map { section in
                let key = groupKey(section: section.id)
                return Group(title: section.name, key: key, tasks: ordered(read.tasks(in: section.id), day: key))
            }
        }
        let key = groupKey(section: nil)
        return [Group(title: "", key: key, tasks: ordered(regularTasks, day: key))]
    }
    private func collapsed(_ key: String) -> Bool { collapsedSections.split(separator: "\n").contains(Substring(key)) }
    private func collapseBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { collapsed(key) }, set: { value in
            var keys = Set(collapsedSections.split(separator: "\n").map(String.init))
            if value { keys.insert(key) } else { keys.remove(key) }
            collapsedSections = keys.sorted().joined(separator: "\n")
        })
    }
    private var boardColumns: [ProjectColumn] {
        switch scope {
        case .project: return projectBoardColumns
        case .upcoming:
            return UpcomingColumns.build(tasks: boardRows).map { column in
                let key: String, add: String
                switch column.kind {
                case .overdue: key = overdueKey; add = ""
                case .day(let day): key = day; add = day
                default: key = column.id; add = ""
                }
                return ProjectColumn(id: key, sectionID: add, title: column.title, subtitle: column.subtitle, tasks: ordered(column.tasks, day: key),
                                     groupsOverdue: false, receivesDrops: column.kind != .overdue)
            }
        case .today, .label:
            return ProjectColumns.build(tasks: boardRows, projects: store.allProjects).map { column in
                var project = ""; if case .project(let id) = column.kind { project = id }
                return ProjectColumn(id: column.id, sectionID: project, title: column.title, tasks: ordered(column.tasks, day: column.id))
            }
        default:
            return groups.map { group in ProjectColumn(id: group.key, sectionID: "", title: group.title.isEmpty ? title : group.title, tasks: group.tasks) }
        }
    }
    private var projectBoardColumns: [ProjectColumn] {
        // Board columns include overdue work; list groups intentionally omit it.
        let rowsBySection = Dictionary(grouping: boardRows, by: { $0.string("section_id") })
        return groups.map { group in
            let section = group.key.split(separator: ":").last.map(String.init) ?? "none"
            return ProjectColumn(id: group.key, sectionID: section == "none" ? "" : section, title: group.title.isEmpty ? "Tasks" : group.title,
                                 tasks: ordered(rowsBySection[section == "none" ? "" : section] ?? [], day: group.key))
        }
    }
    private var boardIdentifier: String {
        switch scope {
        case .project: return "projectBoard"
        case .upcoming: return "upcomingBoard"
        case .today: return "todayBoard"
        case .label: return "labelBoard"
        default: return "inboxBoard"
        }
    }
    private var boardMoveTitle: String {
        switch scope { case .upcoming: return "Move to Day"; case .today, .label: return "Move to Project"; default: return "Move to Section" }
    }
    /// Shared tasks never drag-reschedule: their changes go through the shared-task review in the context menu.
    private func canDragReschedule(_ task: Record) -> Bool { !store.hasSharedTaskSelection([task.id]) }
    /// Someday tasks are muted in lists that keep them (projects, labels, All, filters) and hidden from boards.
    private var somedayListed: Set<String> { Planning.listedSomeday(rows: store.rows(Planning.table), account: store.userID) }
    private var mutedSomeday: Set<String> {
        switch scope { case .project, .label, .all, .saved: return somedayListed; default: return [] }
    }
    private var boardRows: [Record] { let hidden = somedayListed; return hidden.isEmpty ? filtered : filtered.filter { !Planning.hides($0, listed: hidden) } }
    private var calendarTasks: [Record] { filtered.filter { Workspace.subtaskPath($0.id) == nil && TaskKind.mayComplete($0) } }
    private var captureProjectID: String { captureProjectOverride ?? projectID }
    private func beginBoardAdd(_ column: ProjectColumn) {
        captureSection = ""; captureDateOverride = nil; captureProjectOverride = nil
        switch scope {
        case .project: captureSection = column.sectionID
        case .upcoming: captureDateOverride = Dates.parse(column.sectionID)
        case .today, .label: captureProjectOverride = column.sectionID
        default: break
        }
        quickAddVisible = true
    }
    private func beginCalendarAdd(_ day: String) {
        captureSection = ""; captureProjectOverride = nil; captureDateOverride = Dates.parse(day)
        quickAddVisible = true
    }
    private var displayedTaskIDs: [String] {
        if calendarLayout { return calendarTasks.map(\.id) }
        if boardLayout && (!projectID.isEmpty || !boardColumns.isEmpty) { return boardColumns.filter { !collapsed($0.id) }.flatMap { workspace.visibleTasks($0.tasks).map(\.id) } }
        if dated { return dayGroups.filter { ($0.0 != "Overdue" || !overdueCollapsed) && ($0.0 != Workspace.Placement.evening || !collapsed($0.0)) }.flatMap { workspace.visibleTasks($0.1).map(\.id) } }
        return (overdueCollapsed ? [] : workspace.visibleTasks(overdueTasks).map(\.id)) + groups.filter { !collapsed($0.key) }.flatMap { workspace.visibleTasks($0.tasks).map(\.id) }
    }
    private var order: [(day: String, ids: [String])] {
        if dated { return dayGroups.map { (day: $0.0 == "Overdue" ? overdueKey : $0.0, ids: $0.1.map(\.id)) } }
        return [(day: overdueKey, ids: overdueTasks.map(\.id))] + groups.map { (day: $0.key, ids: $0.tasks.map(\.id)) }
    }
    private var remaining: Int { filtered.filter { TaskKind.mayComplete($0) && !$0.completed && !workspace.completing.contains($0.id) }.count }

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                if scope == .today { DayPlanTodayPrompt(plan: { workspace.planning = .day }, shutdown: { workspace.shuttingDown = true }) }
                if scope == .today, let summary = momentum.summary, summary.chipText != nil { StreakChip(summary: summary, open: openInsights) }
                if scope == .today, let habits = store.habitTodaySummary { HabitsChip(summary: habits) { workspace.section = .habits } }
                Spacer(minLength: 0)
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "magnifyingglass").foregroundStyle(DS.Palette.textSecondary)
                    TextField("Filter current list", text: $workspace.search)
                        .textFieldStyle(.plain).focused($filterFocused)
                        .accessibilityIdentifier("listFilter")
                    if !workspace.search.isEmpty {
                        Button { workspace.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(DS.Palette.textSecondary).help("Clear filter")
                    }
                }
                .padding(DS.Space.s).frame(maxWidth: 220)
                .background(.quaternary, in: .rect(cornerRadius: DS.Radius.s, style: .continuous))
                viewOptions
            }
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
            .frame(maxWidth: ReadingColumn.width).frame(maxWidth: .infinity)
            if let failure = store.filterError(scope) {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        Label("Filter unavailable", systemImage: "exclamationmark.triangle").font(DS.Font.screenTitle).accessibilityAddTraits(.isHeader)
                        Text(failure).fixedSize(horizontal: false, vertical: true)
                        Text("Your saved filter is preserved. Its results cannot be shown in this version of Taskfold.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if case .saved(let id) = scope, let view = store.record("saved_views", id: id) { Button("Edit Filter…") { filterEditor = view } }
                    }.padding(DS.Space.xxl).frame(maxWidth: ReadingColumn.width, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
                }.accessibilityIdentifier("savedFilterError")
            } else if case .saved = scope, layoutMode == .board { SavedFilterBoard(scope: scope, tasks: boardRows, open: { workspace.selection = [$0.id] }, toggle: { workspace.toggle([$0.id]) }) }
            else if calendarLayout {
                MonthCalendarView(tasks: calendarTasks, month: $calendarMonth, selectedDay: $calendarDay, identifier: scope == .upcoming ? "upcomingCalendar" : "projectCalendar",
                                  canDrag: canDragReschedule, add: beginCalendarAdd)
            }
            else if boardLayout && (!projectID.isEmpty || !boardColumns.isEmpty) {
                ProjectBoard(columns: boardColumns, identifier: boardIdentifier, moveMenuTitle: boardMoveTitle, compactDate: dated, showsProject: scope == .upcoming,
                             canDrag: projectID.isEmpty ? canDragReschedule : { _ in true }, add: beginBoardAdd)
            } else {
            List(selection: Binding(get: { workspace.section.scope == scope ? workspace.selection : [] }, set: { selection in
                guard workspace.section.scope == scope else { return }
                workspace.selection = selection
            })) {
                if workspace.scope.usesProductiveWork && store.productiveReading.incomplete {
                    Label("Some grouped tasks need review. Open their heading in All Tasks.", systemImage: "exclamationmark.circle")
                        .font(DS.Font.taskNote).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("datedGroupedWorkReview").selectionDisabled()
                }
                if !store.online || (store.notice != nil && store.syncConflict == nil && store.focusSyncConflict == nil) { statusRow }
                if store.syncing && store.tasks.isEmpty && store.lastSync == nil && !store.localMode { SkeletonRows().padding(.vertical, DS.Space.m).selectionDisabled().listRowSeparator(.hidden).transition(.skeletonReveal) }
                if filtered.isEmpty && !dated || datedEmpty { emptyState }
                if dated {
                    ForEach(datedEmpty ? [] : dayGroups, id: \.0) { group in
                        if group.0 == "Overdue" { if !group.1.isEmpty { overdueSection(group.1) } }
                        else if group.0 == Workspace.Placement.evening { if !group.1.isEmpty || workspace.drag.active { eveningSection(group.1) } }
                        else { daySection(group.0, group.1) }
                    }
                } else {
                    if !overdueTasks.isEmpty { overdueSection(overdueTasks) }
                    ForEach(bareEmptyProject ? [] : groups, id: \.key) { group in
                        if scope != .completed || !group.tasks.isEmpty || !group.title.isEmpty {
                            Section {
                                if projectID.isEmpty || !collapsed(group.key) {
                                if group.tasks.isEmpty && group.key.contains(":group:query:") { Text("No matching tasks").foregroundStyle(DS.Palette.textSecondary) }
                                ForEach(workspace.visibleTasks(group.tasks)) { task in row(task).modifier(DayDragRow(task: task, day: group.key, orderProvider: { order })).tag(task.id) }
                                    .onMove { DayDropHandling(workspace: workspace, day: group.key, tasks: group.tasks).move(from: $0, to: $1) }
                                    .onInsert(of: [.taskfoldTask]) { DayDropHandling(workspace: workspace, day: group.key, tasks: group.tasks).insert(at: $0, providers: $1) }
                                if scope != .completed && manualOrder  {
                                    DayEndRow(day: group.key, isEmpty: group.tasks.isEmpty, emptyText: "No tasks", releaseText: "Release to move here").selectionDisabled().listRowSeparator(.hidden)
                                }
                                }
                            } header: {
                                if !projectID.isEmpty {
                                    ProjectSectionHeader(key: group.key, title: group.title, count: TaskKind.listCountLabel(group.tasks), collapsed: collapseBinding(group.key)) {
                                        captureSection = group.key.split(separator: ":").last.map(String.init).flatMap { $0 == "none" ? nil : $0 } ?? ""
                                        quickAddVisible = true
                                    }
                                } else if !group.title.isEmpty { Text(group.title).font(DS.Font.sectionHeader).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true) }
                            }
                        }
                    }
                }
            }
            .background(MacSwipeEventHost(controller: rowSwipe))
            .background(ListScrollMemory(key: preferenceKey, workspace: workspace, taskIDs: displayedTaskIDs, handle: nativeList))
            .focused($taskListFocused)
            .environment(\.taskListFocused, taskListFocused)
            .environment(\.taskRowScope, scope)
            .environment(\.somedayMuted, mutedSomeday)
            .accessibilityIdentifier("taskList")
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(QuietNativeSelection())
            .frame(maxWidth: DS.Size.contentMaxWidth).frame(maxWidth: .infinity)
            .contextMenu(forSelectionType: String.self) { ids in contextMenu(ids) } primaryAction: { ids in
                if let id = ids.first, ids.count == 1 { workspace.open(id) }
            }
            .onDeleteCommand { workspace.delete(workspace.selection) }
            .animation(layout, value: filtered.map(\.id))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .safeAreaInset(edge: .bottom) { if let confirmation = workspace.confirmation { ConfirmationBar(confirmation: confirmation) } }
        .animation(Transitions.Ease.smoothOut, value: workspace.confirmation)
        .task(id: MomentumModel.trigger(store)) { if scope == .today { momentum.refresh(store: store) } }
        .onAppear { if workspace.section.scope == scope { workspace.navigationSubtitle = subtitle } }
        .onChange(of: subtitle) { _, value in if workspace.section.scope == scope { workspace.navigationSubtitle = value } }
        .animation(Transitions.Ease.smoothOut, value: subtitle)
        .toolbar { if workspace.section.scope == scope { toolbar } }
        .onAppear {
            printCommand.install(owner: printOwner, enabled: canPrint, action: { preparePrint() })
        }
        .onChange(of: canPrint) { _, enabled in printCommand.update(owner: printOwner, enabled: enabled) }
        .onDisappear { printCommand.remove(owner: printOwner) }
        .sheet(item: $printReview) { PrintReviewView(request: $0) }
        .alert("Could not prepare document", isPresented: Binding(get: { printFailure != nil }, set: { if !$0 { printFailure = nil } })) { Button("OK") { printFailure = nil } } message: { Text(printFailure ?? "") }
        .onChange(of: store.workspaceGeneration) { _, _ in printReview = nil; printFailure = nil; rowSwipe.cancel() }
        .onAppear { configureRowSwipes() }
        .onChange(of: filtered.map(\.id), initial: true) { _, ids in orderMemory.ids = ids }
        .onChange(of: leadingGesture) { _, _ in configureRowSwipes() }
        .onChange(of: trailingGesture) { _, _ in configureRowSwipes() }
        .onChange(of: fullSwipe) { _, _ in configureRowSwipes() }
        .onChange(of: gestureLayoutDirection) { _, _ in configureRowSwipes() }
        .onChange(of: reduceMotion) { _, _ in configureRowSwipes() }
        .onChange(of: workspace.section.key) { _, _ in configureRowSwipes() }
        .onChange(of: preferenceKey) { _, _ in configureRowSwipes() }
        .onChange(of: workspace.search) { _, _ in rowSwipe.cancel() }
        .onChange(of: workspace.selection) { _, _ in rowSwipe.cancel() }
        .onChange(of: workspace.drag.active) { _, _ in rowSwipe.cancel() }
        .sheet(isPresented: $multiLinePresented) { MultiLineCaptureView(text: workspace.quickAdd, project: captureDraft.string("project_id"), section: captureDraft.string("section_id"), defaults: captureDraft.fields, onSaved: { workspace.quickAdd = "" }) }
        .sheet(isPresented: $quickAddVisible) {
            TaskCapturePanel(text: $workspace.quickAdd, declined: $declinedGroups, choices: $referenceChoices, prompt: quickAddPrompt,
                context: workspace.quickEntryContext(project: captureDraft.string("project_id")), task: captureDraft, submit: submitQuickAdd)
        }
        .sheet(item: $projectEditor) { NamedEditor(table: "projects", record: $0) }
        .sheet(item: $workflowCapture) { WorkflowCaptureSheet(request: $0) }
        .sheet(item: $filterEditor) { SavedViewEditor(record: $0) }
        .sheet(item: $collaborationProject) { CollaboratorsView(project: $0) }
        .sheet(isPresented: $sectionsEditor) { SectionsEditor(projectID: projectID) }
        .sheet(isPresented: $bulkDatePicker) { DatePickSheet(date: $bulkDate, count: workspace.selection.count) { workspace.reschedule(workspace.selection, to: Dates.day(bulkDate), label: bulkDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) } }
        .onChange(of: workspace.quickAddFocusRequest, initial: true) { _, _ in
            if workspace.section.key == preferenceKey, workspace.consumeQuickAddRequest(destination: preferenceKey) { revealQuickAdd() }
        }
        .onChange(of: workspace.searchPresented) { _, requested in
            if requested && workspace.section.scope == scope { filterFocused = true; workspace.searchPresented = false }
        }
        .onDisappear { quickAddVisible = false; rowSwipe.cancel(); rowSwipe.isAvailable = { false } }
        .onChange(of: quickAddVisible) { _, shown in if !shown { captureDateOverride = nil; captureProjectOverride = nil } }
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
        if store.filterError(scope) != nil { return "Filter unavailable" }
        if scope == .completed { return "\(filtered.count) completed" }
        let headings = filtered.filter { TaskKind($0) == .heading }.count
        let count = (remaining == 1 ? "1 task" : "\(remaining) tasks") + (headings == 0 ? "" : headings == 1 ? " · 1 heading" : " · \(headings) headings")
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
    private func revealQuickAdd() { captureSection = ""; captureDateOverride = nil; captureProjectOverride = nil; quickAddVisible = true }

    private var captureDate: Date? { captureDateOverride ?? (scope == .today ? Date() : scope == .upcoming ? Calendar.current.date(byAdding: .day, value: 1, to: Date()) : nil) }
    private var captureDraft: Record {
        var task = workspace.captureTask(project: captureProjectID, date: captureDate, sectionID: captureSection)
        if case .label(let id) = scope, store.record("labels", id: id) != nil {
            task["labels"] = .array(TaskLabels.normalized(task["labels"].list + [.string(id)], labels: store.labels))
        }
        return task
    }
    private func submitQuickAdd() {
        if workspace.quickAdd.contains(where: { $0.isNewline }) { quickAddVisible = false; multiLinePresented = true; return }
        let date = captureDate
        let labelName: String? = { if case .label(let id) = scope { return store.record("labels", id: id)?.name }; return nil }()
        guard let id = workspace.add(quickAdd, project: captureProjectID, date: date, declined: declinedGroups, sectionID: captureSection, referenceChoices: referenceChoices, manual: workspace.quickAddManual) else { return }
        declinedGroups = []; workspace.quickAddManual = [:]
        if let labelName, var task = store.record("tasks", id: id), !task["labels"].list.contains(.string(labelName)) {
            task["labels"] = .array(task["labels"].list + [.string(labelName)]); store.save("tasks", task)
        }
        quickAdd = ""
        referenceChoices = [:]
        quickAddVisible = false
        captureDateOverride = nil; captureProjectOverride = nil
        workspace.selection = [id]
    }

    // MARK: Rows and sections

    @ViewBuilder private var statusRow: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: store.online ? (store.localMode ? "exclamationmark.triangle" : "exclamationmark.icloud") : "wifi.slash").foregroundStyle(DS.Palette.dateTomorrow).accessibilityHidden(true)
            Text(!store.online ? "Offline · changes are saved on this Mac and sync later." : store.notice ?? "")
            Spacer()
            if store.notice != nil && store.online && store.syncConflict == nil && store.focusSyncConflict == nil { Button("Retry") { Task { await store.sync() } }.buttonStyle(.link) }
        }.font(DS.Font.taskNote).foregroundStyle(DS.Palette.textSecondary).selectionDisabled().listRowSeparator(.hidden)
    }
    private var isSavedFilterScope: Bool { if case .saved = scope { return true }; return false }
    /// A list with no tasks and no sections shows only its empty state, not an empty group beneath it.
    private var bareEmptyProject: Bool { !dated && layoutMode != .board && filtered.isEmpty && groups.count == 1 }
    /// Today and Upcoming show a per-scope empty state once every day group is empty.
    private var datedEmpty: Bool { dated && filtered.isEmpty && dayGroups.allSatisfy { $0.1.isEmpty } }
    private struct EmptyContent { var symbol: String; var tint: Color; var title: String; var line: String?; var addTask = false }
    private var emptyContent: EmptyContent {
        let quiet = DS.Palette.textTertiary
        if !workspace.search.isEmpty { return EmptyContent(symbol: "magnifyingglass", tint: quiet, title: "No matching tasks", line: "Try a different search or filter.") }
        if isSavedFilterScope { return EmptyContent(symbol: "magnifyingglass", tint: quiet, title: "No matching tasks", line: "Edit the filter or add a task that matches.") }
        switch scope {
        case .today:
            if workspace.completedTodayCount() > 0 { return EmptyContent(symbol: "sparkles", tint: DS.Palette.dateToday, title: "You did it", line: "Everything for today is done.") }
            return EmptyContent(symbol: "sun.max", tint: DS.Palette.dateToday, title: "All clear for today", line: "Enjoy the rest of your day.")
        case .inbox: return EmptyContent(symbol: "tray", tint: DS.Palette.accent, title: "Inbox zero", line: "Everything has a place.")
        case .upcoming: return EmptyContent(symbol: "calendar", tint: DS.Palette.dateThisWeek, title: "Nothing planned", line: "Add a task with a date to see it here.")
        case .project(let id): return EmptyContent(symbol: "folder", tint: Color.project(store.record("projects", id: id)?.string("color") ?? ""), title: "No tasks yet", line: nil, addTask: true)
        case .label(let id): return EmptyContent(symbol: "tag", tint: Color.project(store.record("labels", id: id)?.string("color") ?? ""), title: "Nothing with this label", line: nil)
        case .completed: return EmptyContent(symbol: "checkmark.circle", tint: quiet, title: "Nothing completed yet", line: nil)
        default: return EmptyContent(symbol: "checkmark.seal", tint: quiet, title: "All clear", line: "Press ⌘N to add something new.")
        }
    }
    private var emptyState: some View {
        let content = emptyContent
        return ContentUnavailableView {
            Label { Text(content.title) } icon: { Image(systemName: content.symbol).foregroundStyle(content.tint.opacity(0.75)) }
        } description: {
            if let line = content.line { Text(line) }
        } actions: {
            if content.addTask { Button("Add task") { revealQuickAdd() }.accessibilityIdentifier("emptyStateAddTask") }
        }
        .modifier(EmptyStateAppear())
        .id(content.title)
        .selectionDisabled().listRowSeparator(.hidden).frame(maxWidth: .infinity, minHeight: 260)
        .accessibilityIdentifier("emptyState")
    }
    private func overdueSection(_ tasks: [Record]) -> some View {
        let count = tasks.filter(TaskKind.mayComplete).count
        return Section {
            if !overdueCollapsed {
                ForEach(workspace.visibleTasks(tasks)) { task in row(task).modifier(DayDragRow(task: task, day: overdueKey, orderProvider: { order })).tag(task.id) }
                    .onMove { DayDropHandling(workspace: workspace, day: overdueKey, tasks: tasks).move(from: $0, to: $1) }
                    .onInsert(of: [.taskfoldTask]) { DayDropHandling(workspace: workspace, day: overdueKey, tasks: tasks).insert(at: $0, providers: $1) }
            }
        } header: {
            HStack(spacing: DS.Space.m) {
            Button { withAnimation(layout) { overdueCollapsed.toggle() } } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: overdueCollapsed ? "chevron.right" : "chevron.down").font(DS.Font.chip)
                Text(count == 0 ? "Earlier" : "Overdue").font(DS.Font.sectionHeader)
                if count > 0 {
                    Text("\(count)").font(DS.Font.badge).padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xxs)
                        .background(DS.Palette.dateOverdue.opacity(0.14), in: .capsule).foregroundStyle(DS.Palette.dateOverdue).contentTransition(.numericText())
                        .transition(reduceMotion ? .opacity : .badgePop)
                }
            }
            }.buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(count == 0 ? "Earlier dates" : "Overdue, \(count) \(count == 1 ? "task" : "tasks")")
            .accessibilityValue(overdueCollapsed ? "Collapsed" : "Expanded")
            .accessibilityIdentifier("overdueToggle")
            if tasks.contains(where: { Planning.eligible($0) && store.smartRescheduleIsEditable($0) }) {
                Button { workspace.openSmartReschedule() } label: { Label("Reschedule smartly…", systemImage: "sparkles").font(DS.Font.chip) }
                        .buttonStyle(.borderless).foregroundStyle(DS.Palette.accent).help("Spread overdue tasks over your next working days")
                        .accessibilityIdentifier("rescheduleSmartly")
                }
                Spacer(minLength: 0)
            }
        }
    }
    private func eveningSection(_ tasks: [Record]) -> some View {
        let key = Workspace.Placement.evening
        let count = tasks.filter { TaskKind.mayComplete($0) && !$0.completed && !workspace.completing.contains($0.id) }.count
        let isCollapsed = collapsed(key) && !workspace.drag.active
        return Section {
            if !isCollapsed {
                ForEach(workspace.visibleTasks(tasks)) { task in row(task).modifier(DayDragRow(task: task, day: key, orderProvider: { order })).tag(task.id) }
                    .onMove { DayDropHandling(workspace: workspace, day: key, tasks: tasks).move(from: $0, to: $1) }
                    .onInsert(of: [.taskfoldTask]) { DayDropHandling(workspace: workspace, day: key, tasks: tasks).insert(at: $0, providers: $1) }
                DayEndRow(day: key, isEmpty: tasks.isEmpty, emptyText: "Nothing for this evening", releaseText: "Release to plan for this evening").selectionDisabled().listRowSeparator(.hidden)
            }
        } header: {
            Button { withAnimation(layout) { collapseBinding(key).wrappedValue.toggle() } } label: {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down").font(DS.Font.chip)
                    Image(systemName: "moon.fill").font(DS.Font.chip).foregroundStyle(DS.Palette.accentSecondary)
                    Text("This Evening").font(DS.Font.sectionHeader)
                    Spacer()
                    if count > 0 { Text("\(count)").font(DS.Font.badge).foregroundStyle(DS.Palette.textTertiary).contentTransition(.numericText()) }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("This Evening, \(count) \(count == 1 ? "task" : "tasks")")
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            .accessibilityIdentifier("eveningToggle")
            .modifier(DayHeaderDrop(day: key))
        }
    }
    private func daySection(_ day: String, _ tasks: [Record]) -> some View {
        let today = Dates.day(Date())
        let tomorrow = Dates.day(Calendar.current.date(byAdding: .day, value: 1, to: Date())!)
        let date = Dates.parse(day)
        let name = day == today ? "Today" : day == tomorrow ? "Tomorrow" : date?.formatted(.dateTime.weekday(.wide)) ?? day
        let detail = date?.formatted(.dateTime.month(.abbreviated).day()) ?? ""
        let open = tasks.filter { TaskKind.mayComplete($0) && !$0.completed && !workspace.completing.contains($0.id) }.count
        return Section {
            ForEach(workspace.visibleTasks(tasks)) { task in row(task).modifier(DayDragRow(task: task, day: day, orderProvider: { order })).tag(task.id) }
                .onMove { DayDropHandling(workspace: workspace, day: day, tasks: tasks).move(from: $0, to: $1) }
                .onInsert(of: [.taskfoldTask]) { DayDropHandling(workspace: workspace, day: day, tasks: tasks).insert(at: $0, providers: $1) }
            DayEndRow(day: day, isEmpty: tasks.isEmpty).selectionDisabled().listRowSeparator(.hidden)
        } header: {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(name).font(DS.Font.sectionHeader).foregroundStyle(day == today ? DS.Palette.accent : DS.Palette.textPrimary)
                if !(scope == .today && day == today) { Text(detail).font(DS.Font.taskNote).foregroundStyle(DS.Palette.textSecondary) }
                Spacer()
                if open > 0 { Text("\(open)").font(DS.Font.badge).foregroundStyle(DS.Palette.textTertiary).contentTransition(.numericText()) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("day-\(day)")
            .modifier(DayHeaderDrop(day: day))
        }
    }
    /// The selection tag must sit on the outermost row view, after any drag wrapper, or clicks cannot select.
    private func row(_ task: Record) -> some View {
        let intent = rowGestureIntent(task)
        return MacSwipeRow(controller: rowSwipe, completed: task.completed, canComplete: TaskKind.mayComplete(task), selected: workspace.selection.contains(task.id), prepare: {
            guard let intent else { return nil }
            return { command in performRowGesture(command, intent: intent) }
        }) { TaskRowView(task: task, compactDate: dated).modifier(SomedayMute(task: task)) }
        .remoteChangeHighlight(task.id)
        .background(ListScrollRowMarker(id: task.id, handle: nativeList)).id(task.id).listRowSeparator(.hidden)
        .accessibilityActions { if TaskKind.mayComplete(task) { Button(task.completed ? "Reopen" : "Complete") { if let intent { performRowGesture(.complete, intent: intent) } } } }
        .accessibilityAction(named: "Move to tomorrow") { if let intent { performRowGesture(.tomorrow, intent: intent) } }
        .accessibilityAction(named: store.isInEvening(task) ? "Back to Today" : "Move to This Evening") {
            if store.isInEvening(task) { workspace.removeFromEvening([task.id]) } else if store.canMoveToEvening([task.id]) { workspace.moveToEvening([task.id]) }
        }
        .accessibilityAction(named: "Move to Someday") { if store.canMoveToSomeday([task.id]) { workspace.moveToSomeday([task.id]) } }
        .accessibilityAction(named: "Edit") { if let intent { performRowGesture(.edit, intent: intent) } }
        .accessibilityAction(named: "Delete") { if let intent { performRowGesture(.delete, intent: intent) } }
    }
    private func configureRowSwipes() {
        rowSwipe.reduceMotion = reduceMotion
        rowSwipe.configure(leading: RowGestureAction(rawValue: leadingGesture) ?? .none, trailing: RowGestureAction(rawValue: trailingGesture) ?? .none, fullSwipe: fullSwipe, rightToLeft: gestureLayoutDirection == .rightToLeft)
        rowSwipe.isAvailable = { store.signedIn && workspace.section.key == preferenceKey && workspace.selection.count <= 1 && !workspace.drag.active && !quickAddVisible }
    }
    private func rowGestureIntent(_ task: Record) -> RowGestureIntent? {
        let rootID = SubtaskTree.referencePath(task.id)?.first ?? task.id
        guard let root = store.activeTasks.first(where: { $0.id == rootID }) else { return nil }
        return RowGestureIntent(task: task, root: root, workspace: WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration))
    }
    private func performRowGesture(_ command: RowGestureCommand, intent: RowGestureIntent) {
        let root = store.activeTasks.first { $0.id == intent.root.id }
        let current = workspace.hierarchyPresentation ? try? store.selectionRecord(intent.task.id) : workspace.taskRecord(intent.task.id)
        guard store.signedIn, workspace.section.key == preferenceKey, !workspace.drag.active, workspace.selection.count <= 1,
              intent.matches(current, root: root, account: store.userID, generation: store.workspaceGeneration) else { return }
        switch command {
        case .complete: workspace.complete(intent.task)
        case .tomorrow:
            guard !intent.task.completed, let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) else { return }
            if workspace.updateTasks([intent.task.id], fields: TaskPlanner.dayFields(task: intent.task, day: Dates.day(tomorrow)), name: "Reschedule") {
                Feedback.drop(); workspace.confirm("Moved to tomorrow")
            }
        case .edit: workspace.open(intent.task.id)
        case .delete: workspace.delete([intent.task.id])
        }
    }

    private func printableDocument() throws -> PrintDocument {
        if let error = store.filterError(scope) { throw AppFailure(message: error) }
        let sections: [(String, [Record])]
        if !projectID.isEmpty && layoutMode == .board { sections = boardColumns.map { ($0.title, $0.tasks) } }
        else if dated { sections = dayGroups }
        else { sections = (overdueTasks.isEmpty ? [] : [("Overdue", overdueTasks)]) + groups.map { ($0.title, $0.tasks) } }
        let named = sections.map { name, tasks in (name == Workspace.Placement.evening ? "This Evening" : Dates.parse(name)?.formatted(.dateTime.weekday(.wide).day().month(.wide).year()) ?? name, tasks) }
        let detail = Date().formatted(.dateTime.day().month(.wide).year()) + (workspace.search.isEmpty ? "" : " · Search: " + workspace.search) + (priorityFilter == 0 ? "" : " · Priority \(priorityFilter)")
        return try PrintDocument.capture(title: workspace.section == .assigned ? "Assigned to me" : title, subtitle: detail, groups: named, projects: store.allProjects, labels: store.labels, hierarchyRoots: workspace.hierarchyPresentation ? store.tasks : nil, expandOrdinaryChecklists: !workspace.hierarchyFilter, assigneeName: store.assigneeName)
    }
    private var canPrint: Bool { printReview == nil && store.filterError(scope) == nil }
    private func preparePrint() {
        do {
            let document = try printableDocument(), binding = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration)
            printReview = PrintReviewRequest(document: document, workspace: binding, isCurrent: { (try? printableDocument()) == document })
        } catch { printFailure = error.localizedDescription }
    }
    private func captureWorkflow(_ kind: WorkflowTemplate.Kind, _ source: Record) {
        do { workflowCapture = try WorkflowCaptureRequest(kind: kind, source: source, store: store) }
        catch { store.error = error.localizedDescription }
    }

    // MARK: Menus

    @ViewBuilder private func contextMenu(_ ids: Set<String>) -> some View {
        let targets = ids.isEmpty ? workspace.selection : ids
        let tasks = targets.compactMap { workspace.taskRecord($0) }
        if tasks.isEmpty {
            Button("New Task") { revealQuickAdd() }
        } else {
            if tasks.count == 1, let task = tasks.first { Button("Edit “\(task.title)”") { workspace.open(task.id) } }
            Button(tasks.allSatisfy(\.completed) ? "Reopen" : "Complete") { workspace.toggle(targets) }.disabled(!tasks.allSatisfy(TaskKind.mayComplete))
            Divider()
            Menu("Reschedule") {
                Button("Today", systemImage: "sun.max") { workspace.reschedule(targets, to: Dates.day(Date()), label: "today") }
                Button("Tomorrow", systemImage: "sunrise") { workspace.reschedule(targets, to: Dates.day(Calendar.current.date(byAdding: .day, value: 1, to: Date())!), label: "tomorrow") }
                Button("This Weekend", systemImage: "beach.umbrella") { if let day = store.datePhraseDay("this weekend") { workspace.reschedule(targets, to: Dates.day(day), label: "the weekend") } }.disabled(store.datePhrasePreferences == nil)
                Button("Next Week", systemImage: "calendar.badge.clock") { if let day = store.datePhraseDay("next week") { workspace.reschedule(targets, to: Dates.day(day), label: "next week") } }.disabled(store.datePhrasePreferences == nil)
                Button("Pick a Date…", systemImage: "calendar") { workspace.selection = targets; bulkDate = Date(); bulkDatePicker = true }
                Divider()
                Button("Remove Date", systemImage: "calendar.badge.minus") { workspace.reschedule(targets, to: nil, label: "") }
            }
            if store.canMoveToEvening(targets) { Button("This Evening", systemImage: "moon.fill") { workspace.moveToEvening(targets) }.accessibilityIdentifier("moveToEvening") }
            if tasks.allSatisfy({ store.isInEvening($0) }) { Button("Back to Today", systemImage: "sun.max") { workspace.removeFromEvening(targets) }.accessibilityIdentifier("backToToday") }
            if store.canMoveToSomeday(targets) { Button("Move to Someday", systemImage: "moon.zzz") { workspace.moveToSomeday(targets) }.accessibilityIdentifier("moveToSomeday") }
            if tasks.count == 1, let task = tasks.first, store.isHabit(task) || store.canTrackHabit(task) {
                let tracked = store.isHabit(task)
                Button(tracked ? "Stop Tracking Habit" : "Track as Habit", systemImage: "circle.hexagongrid") { workspace.run(tracked ? "Stop Tracking Habit" : "Track as Habit") { _ = store.setHabit(task, tracked: !tracked) } }.accessibilityIdentifier("trackHabit")
            }
            Button("Edit Deadlines…", systemImage: "flag.checkered") { workspace.editDeadlines(targets) }.accessibilityIdentifier("bulkDeadlines")
            Button("Edit Estimates…", systemImage: "hourglass") { workspace.editEstimates(targets) }.accessibilityIdentifier("bulkEstimates")
            if store.hasSharedTaskSelection(targets) {
                Button("Assign Shared Tasks…", systemImage: "person.crop.circle.badge.checkmark") { workspace.assignSharedSelection(targets) }.accessibilityIdentifier("bulkAssignShared")
                Button("Edit Shared Labels…", systemImage: "tag") { workspace.editSharedLabels(targets) }.accessibilityIdentifier("bulkSharedLabels")
            }
            Menu("Move to") {
                Button("Inbox", systemImage: "tray") { workspace.move(targets, toProject: "") }
                ForEach(store.projects) { project in Button(project.name, systemImage: "folder") { workspace.move(targets, toProject: project.id) } }
            }
            .disabled(workspace.hierarchyPresentation && targets.contains { Workspace.subtaskPath($0) != nil })
            .help("Subtasks stay in their parent's project")
            Menu("Priority") { ForEach(1...4, id: \.self) { n in Button(n == 4 ? "None" : "Priority \(n)", systemImage: "flag") { workspace.setPriority(targets, n) } } }
            Button("Duplicate", systemImage: "doc.on.doc") { workspace.duplicate(targets) }
            if tasks.count == 1, let task = tasks.first, Workspace.subtaskPath(task.id) == nil {
                Button("Save as Template…", systemImage: "square.stack.3d.up") { captureWorkflow(.task, task) }
                    .accessibilityIdentifier("captureTaskTemplate")
            }
            if tasks.count == 1, let task = tasks.first {
                Button("Copy Title", systemImage: "doc.on.clipboard") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(task.title + (task.string("description").isEmpty ? "" : "\n" + task.string("description")), forType: .string) }
            }
            Divider()
            Button(tasks.count == 1 ? "Delete" : "Delete \(tasks.count) Tasks", systemImage: "trash", role: .destructive) { workspace.delete(targets) }
        }
    }

    private var viewOptions: some View {
            Menu {
                Button("Print or Export…", systemImage: "printer") { preparePrint() }.disabled(store.filterError(scope) != nil).accessibilityIdentifier("openPrintReview")
                if store.teamTaskMovesAvailable { Button("Recent Shared Task Moves", systemImage: "arrow.left.arrow.right") { workspace.teamTaskMove = TeamTaskMoveRequest() }.accessibilityIdentifier("openRecentTeamTaskMoves") }
                Divider()
                Button(store.isFavorite(scope) ? "Remove Favorite" : "Add Favorite", systemImage: "star") { store.toggleFavorite(scope) }.accessibilityIdentifier("toggleFavorite")
                if case .saved(let id) = scope { Button("Edit Filter…") { filterEditor = store.record("saved_views", id: id) } }
                Button(defaultView == preferenceKey ? "Default View ✓" : "Make Default View", systemImage: "house") { defaultView = preferenceKey }
                Menu("Filter") {
                Toggle("Show Completed", isOn: Binding(get: { showCompleted }, set: { showCompleted = $0 }))
                if let showBlocked = showBlockedBinding { Toggle("Show Blocked Tasks", isOn: showBlocked).accessibilityIdentifier("viewShowBlocked") }
                Picker("Priority", selection: Binding(get: { priorityFilter }, set: { priorityFilter = $0 })) { Text("All Priorities").tag(0); ForEach(1...4, id: \.self) { Text("Priority \($0)").tag($0) } }
                }
                Picker("Sort", selection: Binding(get: { manualOrder ? "manual" : sortBy }, set: { sortBy = $0 })) { Text("Default Order").tag("manual"); Text("Due Date").tag("date"); Text("Title").tag("title"); Text("Deadline").tag("deadline"); Text("Estimate").tag("duration") }
                let layouts = TaskLayout.available(for: scope)
                if layouts.count > 1 { LayoutPicker(layouts: layouts, selection: Binding(get: { layoutMode }, set: { storedLayout = $0.rawValue })) }
                if !projectID.isEmpty {
                    Divider()
                    Button("Edit Project…", systemImage: "pencil") { projectEditor = store.record("projects", id: projectID) }
                    if let project = store.record("projects", id: projectID) {
                        Button("Save as Template…", systemImage: "square.stack.3d.up") { captureWorkflow(.project, project) }
                            .accessibilityIdentifier("captureProjectTemplate")
                    }
                    Button("Sections…", systemImage: "rectangle.split.3x1") { sectionsEditor = true }
                    Button("Collaborators…", systemImage: "person.2") { collaborationProject = store.record("projects", id: projectID) }.disabled(store.localMode)
                }
            } label: { Label("View Options", systemImage: "line.3.horizontal.decrease.circle") }
                .help("View options").accessibilityLabel("Task options")
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Pinned notes", systemImage: "pin") { openPinnedNotes() }.accessibilityIdentifier("openPinnedNotes")
            Button("Project pulse", systemImage: "chart.bar") { if case .project(let id) = scope { openProjectPulse(id) } else { openProjectPulse(nil) } }.accessibilityIdentifier("openProjectPulse")
            Button("Focus session", systemImage: "timer") { openFocusSession() }.accessibilityIdentifier("openFocusSession")
            if scope == .inbox {
                Button { startInboxReview(.five) } label: { Label("Review Inbox", systemImage: "tray") }
                    .accessibilityIdentifier("reviewInbox")
            }
            if scope == .today || scope == .upcoming {
                Button { workspace.planning = scope == .today ? .day : .week } label: { Label(scope == .today ? "Plan Your Day" : "Review This Week", systemImage: "sparkles") }
                    .help(scope == .today ? "Triage, estimate and time-block today (⌥⌘P)" : "Review the next seven days one task at a time (⌥⌘W)")
                    .disabled(scope == .upcoming && workspace.planQueue(.week).isEmpty)
                    .accessibilityIdentifier("planButton")
            }
            Button("Add Multiple Tasks…", systemImage: "text.badge.plus") { multiLinePresented = true }.accessibilityIdentifier("openMultiLineCaptureInList")
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
enum ReadingColumn { static let width: CGFloat = DS.Size.contentMaxWidth }

/// A brief confirmation at the foot of the list. It never blocks; it just names what happened and offers Undo.
struct ConfirmationBar: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let confirmation: Confirmation
    @State private var sparkle = false
    var body: some View {
        HStack(spacing: DS.Space.m) {
            if confirmation.celebration != nil {
                Image(systemName: "sparkles").foregroundStyle(DS.Palette.accent)
                    .scaleEffect(sparkle ? 1 : 0.4).rotationEffect(.degrees(sparkle || reduceMotion ? 0 : -20))
                    .symbolEffect(.bounce, options: .nonRepeating, isActive: sparkle && !reduceMotion)
                    .id(confirmation.id).transition(.iconSwap)
                    .onAppear { if reduceMotion { sparkle = true } else { withAnimation(Motion.settle) { sparkle = true } } }
                    .accessibilityHidden(true)
                Text(confirmation.message).fontWeight(.semibold).lineLimit(1).id(confirmation.id).transition(.textSwap)
                Text(confirmation.celebration ?? "").foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
            } else {
            Image(systemName: confirmation.mixedGroupReview ? "clock.arrow.circlepath" : "checkmark.circle.fill").foregroundStyle(DS.Palette.accent).id(confirmation.id).transition(.iconSwap)
            Text(confirmation.message).lineLimit(1).id(confirmation.id).transition(.textSwap)
            }
            Spacer()
            if confirmation.mixedGroupReview { Button("Review") { workspace.reviewMixedGroup() }.buttonStyle(.link).accessibilityIdentifier("reviewListMixedGroup") }
            if confirmation.childGroupReview {
                Button("Review") { workspace.reviewChildGroup() }.buttonStyle(.link).accessibilityIdentifier("reviewListChildGroup")
            }
            if confirmation.childCompletionReview {
                Button("Review") { workspace.reviewChildCompletion() }.buttonStyle(.link).accessibilityIdentifier("reviewListChildCompletion")
            }
            if let token = confirmation.mixedGroup, workspace.canUndoMixedGroup(token) {
                Button("Undo") { workspace.undoMixedGroup(token) }.buttonStyle(.link).accessibilityIdentifier("undoConfirmation")
                Text("⌘Z").foregroundStyle(DS.Palette.textTertiary)
            } else if let token = confirmation.childGroup, workspace.canUndoChildGroup(token) {
                Button("Undo") { workspace.undoChildGroup(token) }.buttonStyle(.link).accessibilityIdentifier("undoConfirmation")
                Text("⌘Z").foregroundStyle(DS.Palette.textTertiary)
            } else if let token = confirmation.childCompletion, workspace.canUndoChildCompletion(token) {
                Button("Undo") { workspace.undoChildCompletion(token) }.buttonStyle(.link).accessibilityIdentifier("undoConfirmation")
                Text("⌘Z").foregroundStyle(DS.Palette.textTertiary)
            } else if confirmation.undoable, let request = confirmation.historyRequest, store.canApplyHistory(request) {
                Button("Undo") { workspace.undoFromConfirmation(request, confirmationID: confirmation.id) }.buttonStyle(.link).accessibilityIdentifier("undoConfirmation")
                Text("⌘Z").foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .font(DS.Font.taskNote)
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .onHover { workspace.confirmationHovering = $0 }
        .onDisappear { workspace.confirmationHovering = false }
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        .task(id: confirmation.id) {
            guard NSApp.isActive, NSWorkspace.shared.isVoiceOverEnabled else { return }
            // A removed row can announce “no row selected”; keep the action's result audible.
            var announcement = AttributedString(confirmation.message + (confirmation.celebration.map { ", " + $0 } ?? ""))
            announcement.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(announcement).post()
        }
    }
}

/// Graphical date picker for rescheduling several tasks at once.
struct DatePickSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var date: Date
    let count: Int
    var verb = "Reschedule"
    let confirm: () -> Void
    var body: some View {
        VStack(spacing: DS.Space.l) {
            Text("Pick a date").font(.headline)
            DatePicker("Date", selection: $date, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(count == 1 ? "\(verb) Task" : "\(verb) \(count) Tasks") { confirm(); dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(DS.Space.xl).frame(width: 320)
    }
}

/// Each app owns this native presentation. Suggestions are explicit draft choices;
/// the normal parser, Save and durable queue remain the authority for task changes.
struct QuickReferenceCompletionModifier: ViewModifier {
    @Binding var text: String
    @Binding var selection: TextSelection?
    @Binding var choices: [String: String]
    @Binding var declined: Set<String>
    let context: QuickEntryContext
    let focused: Bool
    var task = Record()
    var excluded: Set<String> = []
    var onChoose: () -> Void = {}
    var submit: () -> Void = {}
    var submitsFromKeyboard = false
    @State private var optionListHeight: CGFloat = 44
    @State private var highlighted = 0
    @State private var dismissedText: String?
    private var completion: QuickEntryCompletion {
        var c = context; c.referenceChoices = choices
        var caret: Int?
        if let selection {
            guard selection.isInsertion, case .selection(let range) = selection.indices,
                  range.lowerBound <= text.endIndex, let index = range.lowerBound.samePosition(in: text.utf16) else { return QuickEntryCompletion("") }
            caret = text.utf16.distance(from: text.utf16.startIndex, to: index)
        }
        var result = QuickEntryCompletion(text, caretUTF16: caret, context: c, task: task, disabled: declined)
        result.options.removeAll { excluded.contains($0.group) }
        return result
    }
    private var visible: Bool { focused && dismissedText != text && completion.range != nil }
    func body(content: Content) -> some View {
        let menu = completion
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            content
            if visible {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack {
                        Text(menu.prompt).font(DS.Font.chip).foregroundStyle(DS.Palette.textSecondary)
                        Spacer()
                        Button { keepLiteral() } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .semibold) /* SF Symbol optical size */).frame(width: 44, height: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Keep suggestion as text").accessibilityIdentifier("dismissReferenceSuggestions")
                    }
                    if menu.options.isEmpty {
                        Text("No matches. Keep typing, or choose from the field controls.").font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("referenceNoMatches")
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: DS.Space.xxs) {
                                    ForEach(menu.options) { option in
                                        QuickReferenceOptionRow(option: option, highlighted: menu.options.firstIndex(of: option) == highlighted) { choose(option) }.id(option.id)
                                    }
                                }
                                .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { optionListHeight = $0 }
                            }.frame(height: min(190, max(44, optionListHeight))).scrollIndicators(.visible).accessibilityIdentifier("referenceSuggestionList")
                                .onChange(of: highlighted) { _, value in
                                    if menu.options.indices.contains(value) { proxy.scrollTo(menu.options[value].id, anchor: .center) }
                                }
                        }
                    }
                }.padding(DS.Space.s).background(DS.Palette.accent.opacity(0.04), in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
            }
        }
        .onSubmit {
            if visible, menu.options.indices.contains(highlighted) { choose(menu.options[highlighted]) }
            else { submit() }
        }
        .onChange(of: text) { old, new in
            if focused, let caret = QuickReferenceCompletion.returnInsertion(before: old, after: new) {
                var c = context; c.referenceChoices = choices
                var previous = QuickEntryCompletion(old, caretUTF16: caret, context: c, task: task, disabled: declined)
                previous.options.removeAll { excluded.contains($0.group) }
                if dismissedText != old, previous.options.indices.contains(highlighted) {
                    choose(previous.options[highlighted], using: previous, input: old)
                } else if submitsFromKeyboard {
                    text = old
                    if let point = Range(NSRange(location: caret, length: 0), in: text)?.lowerBound { selection = TextSelection(insertionPoint: point) }
                    submit()
                }
            }
            highlighted = 0; dismissedText = nil
        }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.return) {
            if visible, !menu.options.isEmpty { return acceptHighlighted() }
            if focused && submitsFromKeyboard { submit(); return .handled }
            return .ignored
        }
        .onKeyPress(.tab) { acceptHighlighted() }
        .onKeyPress(.escape) {
            guard visible else { return .ignored }; keepLiteral(); return .handled
        }
    }
    private func keepLiteral() { declined.formUnion(completion.literalGroups); dismissedText = text }
    private func move(_ delta: Int) -> KeyPress.Result {
        guard visible, !completion.options.isEmpty else { return .ignored }
        highlighted = (highlighted + delta + completion.options.count) % completion.options.count
        return .handled
    }
    private func acceptHighlighted() -> KeyPress.Result {
        guard visible, completion.options.indices.contains(highlighted) else { return .ignored }
        choose(completion.options[highlighted]); return .handled
    }
    private func choose(_ option: QuickReferenceCompletion.Option, using candidate: QuickEntryCompletion? = nil, input: String? = nil) {
        guard let result = (candidate ?? completion).choosing(option, in: input ?? text) else { return }
        if ["project_id", "section_id", "labels", "assigned_to"].contains(option.group) { choices[option.reference] = option.recordID }
        declined.remove(option.group)
        if option.group == "reminder_specs" {
            let accepted = QuickEntry(result.text, context: context, task: task)
            for token in accepted.tokens where token.text.lowercased() == option.reference && token.group.hasPrefix("reminder_specs:") { declined.remove(token.group) }
        }
        text = result.text
        // Native text storage updates after the binding. Apply the caret on the
        // next main-loop turn so that update cannot restore the old insertion point.
        DispatchQueue.main.async {
            guard text == result.text,
                  let caret = Range(NSRange(location: result.caretUTF16, length: 0), in: text)?.lowerBound else { return }
            selection = TextSelection(insertionPoint: caret)
        }
        onChoose()
    }
    private func symbol(_ group: String) -> String {
        switch group { case "project_id": return "folder"; case "section_id": return "rectangle.stack"; case "assigned_to": return "person.crop.circle"; case "due_date": return "calendar"; case "due_time": return "clock"; case "recurrence": return "repeat"; case "reminder_specs": return "bell"; default: return "tag" }
    }
}

extension View {
    func referenceCompletions(text: Binding<String>, selection: Binding<TextSelection?>, choices: Binding<[String: String]>, declined: Binding<Set<String>>, context: QuickEntryContext, focused: Bool, task: Record = Record(), excluded: Set<String> = [], onChoose: @escaping () -> Void = {}, submit: @escaping () -> Void = {}, submitsFromKeyboard: Bool = false) -> some View {
        modifier(QuickReferenceCompletionModifier(text: text, selection: selection, choices: choices, declined: declined, context: context, focused: focused, task: task, excluded: excluded, onChoose: onChoose, submit: submit, submitsFromKeyboard: submitsFromKeyboard))
    }
}


private struct QuickReferenceOptionRow: View {
    let option: QuickReferenceCompletion.Option
    let highlighted: Bool
    let choose: () -> Void
    var body: some View {
        Button(action: choose) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: symbol).font(.system(size: DS.Size.iconL, weight: .medium)).foregroundStyle(DS.Palette.accent).frame(width: DS.Space.xxl).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(option.name).font(DS.Font.chip).fixedSize(horizontal: false, vertical: true)
                    Text(option.detail).font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if highlighted { Image(systemName: "return").font(.system(size: DS.Size.iconS, weight: .medium)).foregroundStyle(DS.Palette.textSecondary).frame(width: DS.Space.xl).accessibilityHidden(true) }
            }.padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                .background(highlighted ? DS.Palette.accent.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        }.buttonStyle(.plain).accessibilityIdentifier("referenceSuggestion-" + option.id)
            .accessibilityLabel(option.name + ", " + option.detail)
            .accessibilityHint("Use this result in the task")
    }
    private var symbol: String {
        switch option.group { case "project_id": return "folder"; case "section_id": return "rectangle.stack"; case "assigned_to": return "person.crop.circle"; case "due_date": return "calendar"; case "due_time": return "clock"; case "recurrence": return "repeat"; case "reminder_specs": return "bell"; default: return "tag" }
    }
}
