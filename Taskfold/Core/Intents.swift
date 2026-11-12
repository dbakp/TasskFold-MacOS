import AppIntents
import CoreSpotlight
import SwiftUI

/// Siri, Shortcuts and Focus support. Intents run in-process against `Store.shared`, and every
/// change goes through the normal Store mutation path so undo, sync and reminders stay correct.
/// The decisions themselves live in `IntentLogic.swift` (unit-tested in Core).
struct TaskEntity: AppEntity, IndexedEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Task")
    static let defaultQuery = TaskEntityQuery()
    var id: String
    var title: String
    var due: String
    var project: String = ""
    var spotlight: SpotlightDocument?
    var displayRepresentation: DisplayRepresentation {
        let subtitle = [due, project].filter { !$0.isEmpty }.joined(separator: " · ")
        return DisplayRepresentation(title: "\(title)", subtitle: subtitle.isEmpty ? nil : "\(subtitle)")
    }
    /// The same fields the Spotlight index stores, so Siri and Spotlight describe a task identically.
    var attributeSet: CSSearchableItemAttributeSet {
        SpotlightAttributes.make(spotlight ?? SpotlightDocument(kind: .task, recordID: id, title: title, textContent: "",
                                                                 contentDescription: subtitleText, keywords: [], dueDate: nil, projectName: nil))
    }
    private var subtitleText: String { [project.isEmpty ? "Inbox" : project, due.isEmpty ? "" : "Due " + due].filter { !$0.isEmpty }.joined(separator: " · ") }
    @MainActor init(_ record: Record) {
        id = record.id; title = record.title
        due = record.due.map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? ""
        let store = Store.shared
        let names = store.spotlightNames
        spotlight = SpotlightMapper.taskDocument(record, projectNames: names.projects, labelNames: names.labels)
        project = spotlight?.projectName ?? ""
    }
}

struct TaskEntityQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [TaskEntity] {
        identifiers.compactMap { Store.shared.record("tasks", id: $0) }.map(TaskEntity.init)
    }
    @MainActor func entities(matching string: String) async throws -> [TaskEntity] {
        IntentTaskSelection.search(Store.shared.tasks, text: string).map(TaskEntity.init)
    }
    @MainActor func suggestedEntities() async throws -> [TaskEntity] {
        let today = Dates.day(Date())
        return Store.shared.tasks.filter { !$0.completed && !$0.string("due_date").isEmpty && $0.string("due_date") <= today }.prefix(10).map(TaskEntity.init)
    }
}

struct ProjectEntity: AppEntity, IndexedEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Project")
    static let defaultQuery = ProjectEntityQuery()
    var id: String
    var name: String
    var openTasks: Int
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: openTasks == 1 ? "1 open task" : "\(openTasks) open tasks")
    }
    var attributeSet: CSSearchableItemAttributeSet {
        SpotlightAttributes.make(SpotlightDocument(kind: .project, recordID: id, title: name, textContent: "",
                                                   contentDescription: "Project · " + (openTasks == 1 ? "1 open task" : "\(openTasks) open tasks"),
                                                   keywords: [], dueDate: nil, projectName: nil))
    }
    @MainActor init(_ record: Record) {
        id = record.id; name = record.name
        openTasks = Store.shared.activeTasks.filter { !$0.completed && $0.string("project_id") == record.id }.count
    }
}

struct ProjectEntityQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [ProjectEntity] {
        let ids = Set(identifiers)
        return Store.shared.projects.filter { ids.contains($0.id) }.map(ProjectEntity.init)
    }
    @MainActor func entities(matching string: String) async throws -> [ProjectEntity] {
        let key = QuickEntryContext.key(string)
        return Store.shared.projects.filter { QuickEntryContext.key($0.name).contains(key) }.prefix(20).map(ProjectEntity.init)
    }
    @MainActor func suggestedEntities() async throws -> [ProjectEntity] {
        Store.shared.projects.prefix(20).map(ProjectEntity.init)
    }
}

enum TaskPriorityOption: Int, AppEnum {
    case urgent = 1, high = 2, medium = 3, none = 4
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Priority")
    static let caseDisplayRepresentations: [TaskPriorityOption: DisplayRepresentation] = [
        .urgent: "P1 Urgent", .high: "P2 High", .medium: "P3 Medium", .none: "P4 None"]
}

enum TaskListFilterOption: String, AppEnum {
    case today, overdue, upcoming, project
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Tasks")
    static let caseDisplayRepresentations: [TaskListFilterOption: DisplayRepresentation] = [
        .today: "Due today", .overdue: "Overdue", .upcoming: "Next 7 days", .project: "In a project"]
    var logic: IntentListFilter { IntentListFilter(rawValue: rawValue) ?? .today }
}

enum TaskfoldListOption: String, AppEnum {
    case today, upcoming, inbox
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "List")
    static let caseDisplayRepresentations: [TaskfoldListOption: DisplayRepresentation] = [
        .today: "Today", .upcoming: "Upcoming", .inbox: "Inbox"]
}

/// A small, readable result card for Siri and Shortcuts. System text styles keep it correct
/// in light and dark, with Dynamic Type.
struct TaskListSnippet: View {
    let heading: String
    let tasks: [TaskEntity]
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(heading).font(DS.Font.sectionHeader).foregroundStyle(DS.Palette.textSecondary)
            if tasks.isEmpty {
                Text("Nothing here").font(DS.Font.taskTitle).foregroundStyle(DS.Palette.textPrimary)
            }
            ForEach(tasks.prefix(5)) { task in
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(task.title).font(DS.Font.taskTitle).foregroundStyle(DS.Palette.textPrimary).lineLimit(2)
                    let detail = [task.due, task.project].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !detail.isEmpty { Text(detail).font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary) }
                }
                .accessibilityElement(children: .combine)
            }
            if tasks.count > 5 { Text("and \(tasks.count - 5) more").font(DS.Font.taskMeta).foregroundStyle(DS.Palette.textSecondary) }
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Task"
    static let description = IntentDescription("Adds a task to Taskfold. Dates, times, priority (p1–p4), and #labels in the text are understood. Optionally choose a project, a due date or phrase, and a priority.")
    static let openAppWhenRun = false
    @Parameter(title: "Task", requestValueDialog: "What needs doing?") var text: String
    @Parameter(title: "Project") var project: ProjectEntity?
    @Parameter(title: "Due", description: "A date or a phrase such as tomorrow or next Friday.") var due: String?
    @Parameter(title: "Priority") var priority: TaskPriorityOption?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text)") { \.$project; \.$due; \.$priority }
    }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = Store.shared
        guard store.signedIn else { return .result(dialog: "Open Taskfold and sign in first.") }
        let initial = QuickEntry(text, context: store.quickEntryContext())
        if let project = initial.updates["project_id"], text.contains("+") { _ = try? await store.refreshProjectMembers(project.text) }
        let parsed = QuickEntry(text, context: store.quickEntryContext())
        if let warning = parsed.warnings.first { return .result(dialog: "\(warning)") }
        var dueDay: String?
        if let due, !due.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let day = IntentDate.day(phrase: due, date: nil, preferences: store.datePhrasePreferences ?? DatePhrasePreferences()) else {
                return .result(dialog: "I couldn’t read “\(due)” as a date. Try tomorrow or next Friday.")
            }
            dueDay = day
        }
        if let project, store.record("projects", id: project.id) == nil { return .result(dialog: "That project is no longer available.") }
        let task = IntentAddOptions.apply(to: parsed.applying(to: Record.task(user: store.userID)), project: project?.id, dueDay: dueDay, priority: priority?.rawValue)
        guard !task.title.isEmpty else { return .result(dialog: "Include a task name as well as its details.") }
        for label in parsed.updates["labels"]?.list ?? [] where !store.labels.contains(where: { $0.name == label.text }) {
            guard store.save("labels", Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(store.userID), "name": label, "color": .string("#e31e4b")])) else { return .result(dialog: "Taskfold could not save that label.") }
        }
        guard !task.title.trimmingCharacters(in: .whitespaces).isEmpty, store.save("tasks", task) else { return .result(dialog: "Taskfold could not add that task.") }
        let when = task.due.map { " for " + $0.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) } ?? ""
        return .result(dialog: "Added “\(task.title)”\(when).")
    }
}

struct TodayTasksIntent: AppIntent {
    static let title: LocalizedStringResource = "What’s Due Today"
    static let description = IntentDescription("Reads back the open tasks due today or overdue.")
    static let openAppWhenRun = false
    /// Task titles and changes stay behind the device passcode (Siri, Shortcuts, lock screen).
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[TaskEntity]> {
        let store = Store.shared
        guard store.signedIn else { return .result(value: [], dialog: "Open Taskfold and sign in first.") }
        let today = Dates.day(Date())
        let due = store.tasks.filter { !$0.completed && !$0.string("due_date").isEmpty && $0.string("due_date") <= today }
        let entities = due.map(TaskEntity.init)
        if due.isEmpty { return .result(value: entities, dialog: "Nothing is due today. A little space to breathe.") }
        let names = due.prefix(5).map(\.title).joined(separator: ", ")
        let more = due.count > 5 ? " and \(due.count - 5) more" : ""
        return .result(value: entities, dialog: "\(due.count == 1 ? "1 task" : "\(due.count) tasks") today: \(names)\(more).")
    }
}

struct CompleteTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete Task"
    static let description = IntentDescription("Marks a task as done.")
    static let openAppWhenRun = false
    /// Task titles and changes stay behind the device passcode (Siri, Shortcuts, lock screen).
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Task") var task: TaskEntity
    static var parameterSummary: some ParameterSummary { Summary("Complete \(\.$task)") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = Store.shared
        guard let record = store.record("tasks", id: task.id) else { return .result(dialog: "That task is gone.") }
        if record.completed { return .result(dialog: "“\(record.title)” is already done.") }
        store.toggle(record)
        return .result(dialog: "Completed “\(record.title)”.")
    }
}

struct SearchTasksIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Tasks"
    static let description = IntentDescription("Finds open tasks whose title or notes contain your words.")
    static let openAppWhenRun = false
    /// Task titles and changes stay behind the device passcode (Siri, Shortcuts, lock screen).
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Search", requestValueDialog: "What are you looking for?") var query: String
    static var parameterSummary: some ParameterSummary { Summary("Search tasks for \(\.$query)") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[TaskEntity]> & ShowsSnippetView {
        let store = Store.shared
        guard store.signedIn else { return .result(value: [], dialog: "Open Taskfold and sign in first.", view: TaskListSnippet(heading: "Search", tasks: [])) }
        let found = IntentTaskSelection.search(store.activeTasks, text: query)
        let entities = found.map(TaskEntity.init)
        return .result(value: entities, dialog: "\(IntentSummary.list(found, empty: "No open tasks match “\(query)”.", label: "match “\(query)”"))",
                       view: TaskListSnippet(heading: "Search: \(query)", tasks: entities))
    }
}

struct GetTasksIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Tasks"
    static let description = IntentDescription("Returns open tasks that are due today, overdue, due in the next 7 days, or in a project.")
    static let openAppWhenRun = false
    /// Task titles and changes stay behind the device passcode (Siri, Shortcuts, lock screen).
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Tasks", default: .today) var filter: TaskListFilterOption
    @Parameter(title: "Project") var project: ProjectEntity?
    static var parameterSummary: some ParameterSummary {
        Switch(\.$filter) {
            Case(.project) { Summary("Get tasks in \(\.$project)") }
            DefaultCase { Summary("Get \(\.$filter) tasks") }
        }
    }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[TaskEntity]> & ShowsSnippetView {
        let store = Store.shared
        guard store.signedIn else { return .result(value: [], dialog: "Open Taskfold and sign in first.", view: TaskListSnippet(heading: "Tasks", tasks: [])) }
        if filter == .project, project == nil { return .result(value: [], dialog: "Choose a project first.", view: TaskListSnippet(heading: "Tasks", tasks: [])) }
        let rows = IntentTaskSelection.filter(store.activeTasks, filter.logic, today: Dates.day(Date()), project: project?.id, projects: store.projects)
        let entities = rows.map(TaskEntity.init)
        let heading: String, empty: String, label: String
        switch filter {
        case .today: heading = "Due today"; empty = "Nothing is due today."; label = "due today"
        case .overdue: heading = "Overdue"; empty = "Nothing is overdue."; label = "overdue"
        case .upcoming: heading = "Next 7 days"; empty = "Nothing is due in the next 7 days."; label = "due in the next 7 days"
        case .project: heading = project?.name ?? "Project"; empty = "No open tasks in \(project?.name ?? "that project")."; label = "in \(project?.name ?? "that project")"
        }
        return .result(value: entities, dialog: "\(IntentSummary.list(rows, empty: empty, label: label))", view: TaskListSnippet(heading: heading, tasks: entities))
    }
}

struct OpenProjectIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Project"
    static let description = IntentDescription("Opens a project in Taskfold.")
    static let openAppWhenRun = true
    @Parameter(title: "Project") var project: ProjectEntity
    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$project)") }
    @MainActor func perform() async throws -> some IntentResult & OpensIntent {
        let store = Store.shared
        let url = store.signedIn && store.record("projects", id: project.id) != nil ? SpotlightRoute.project(project.id).url(account: store.userID) : nil
        return .result(opensIntent: OpenURLIntent(url ?? SystemControlRoute.today))
    }
}

struct ShowListIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Today, Upcoming or Inbox"
    static let description = IntentDescription("Opens Taskfold on Today, Upcoming or Inbox.")
    static let openAppWhenRun = true
    @Parameter(title: "List", default: .today) var list: TaskfoldListOption
    static var parameterSummary: some ParameterSummary { Summary("Show \(\.$list)") }
    @MainActor func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "taskfold://" + list.rawValue)!))
    }
}

struct RescheduleTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Reschedule Task"
    static let description = IntentDescription("Moves a task to another day. Give a date, or a phrase such as tomorrow or next Friday.")
    static let openAppWhenRun = false
    /// Task titles and changes stay behind the device passcode (Siri, Shortcuts, lock screen).
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Task") var task: TaskEntity
    @Parameter(title: "Phrase", description: "A phrase such as tomorrow, next Friday or Dec 3.") var phrase: String?
    @Parameter(title: "Date") var date: Date?
    static var parameterSummary: some ParameterSummary {
        Summary("Reschedule \(\.$task) to \(\.$phrase)") { \.$date }
    }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = Store.shared
        guard store.signedIn else { return .result(dialog: "Open Taskfold and sign in first.") }
        guard let record = store.record("tasks", id: task.id) else { return .result(dialog: "That task is gone.") }
        guard TaskKind.mayComplete(record) else { return .result(dialog: "Headings don’t have a date. Open Taskfold to edit it.") }
        guard !store.hasSharedTaskSelection([record.id]) else { return .result(dialog: "“\(record.title)” is shared. Open Taskfold to review its date change.") }
        guard let day = IntentDate.day(phrase: phrase, date: date, preferences: store.datePhrasePreferences ?? DatePhrasePreferences()) else {
            return .result(dialog: "I couldn’t read that as a date. Try tomorrow, next Friday or Dec 3.")
        }
        let fields = TaskPlanner.dayFields(task: record, day: day)
        let label = (Dates.parse(day) ?? Date()).formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        if fields.isEmpty { return .result(dialog: "“\(record.title)” is already set for \(label).") }
        store.update([record.id], fields: fields)
        return .result(dialog: "Moved “\(record.title)” to \(label).")
    }
}

struct StartFocusSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Focus Session"
    static let description = IntentDescription("Starts a Focus timer on one task.")
    static let openAppWhenRun = false
    @Parameter(title: "Task") var task: TaskEntity
    @Parameter(title: "Minutes", default: 25, inclusiveRange: (1, 180)) var minutes: Int
    static var parameterSummary: some ParameterSummary { Summary("Start a \(\.$minutes) minute focus session on \(\.$task)") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = Store.shared
        guard store.signedIn, store.focusAvailable else { return .result(dialog: "Open Taskfold and sign in first.") }
        guard let record = store.record("tasks", id: task.id), TaskKind.mayComplete(record), !record.completed else { return .result(dialog: "Choose an open task to focus on.") }
        if let current = store.focusSession, current.status == .running, !current.finished(at: Date()) {
            return .result(dialog: "A Focus session is already running. Stop it in Taskfold first.")
        }
        do {
            let session = try FocusSession(taskID: record.id, minutes: minutes)
            guard store.changeFocus(session, expected: store.focusRecord, workspace: WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration)) else {
                return .result(dialog: "Taskfold could not start that session.")
            }
        } catch { return .result(dialog: "\(error.localizedDescription)") }
        return .result(dialog: "Focusing on “\(record.title)” for \(minutes) \(minutes == 1 ? "minute" : "minutes").")
    }
}

/// While a Focus is on, Taskfold narrows its lists, sidebar and widgets to the chosen projects.
/// The filter is view-only: nothing is changed, hidden from sync, or rewritten in a saved filter.
struct TaskfoldFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Taskfold Focus filter"
    static let description = IntentDescription("Show only chosen projects (and their subprojects) in Taskfold while this Focus is on.")
    @Parameter(title: "Projects to show", description: "Tasks in other projects stay safe and reappear when the Focus ends.") var projects: [ProjectEntity]?
    @Parameter(title: "Hide badge count for other projects", default: false) var hideOtherBadges: Bool
    @Parameter(title: "Name in Taskfold", description: "Shown in the banner, for example Work.") var name: String?

    var displayRepresentation: DisplayRepresentation {
        let count = projects?.count ?? 0
        return DisplayRepresentation(title: "Taskfold: \(count == 1 ? "1 project" : "\(count) projects")",
                                     subtitle: count == 0 ? "Showing everything" : "Hides other projects from view")
    }

    @MainActor func perform() async throws -> some IntentResult {
        let store = Store.shared
        let ids = (projects ?? []).map(\.id)
        let state = ids.isEmpty ? nil : FocusFilterState(account: store.signedIn ? store.userID : "", name: (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines), projectIDs: ids, hideOtherBadges: hideOtherBadges)
        store.applyFocusFilter(state)
        return .result()
    }
}

struct TaskfoldShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddTaskIntent(), phrases: ["Add a task to \(.applicationName)", "New \(.applicationName) task"],
                    shortTitle: "Add Task", systemImageName: "plus.circle.fill")
        AppShortcut(intent: TodayTasksIntent(), phrases: ["What’s due today in \(.applicationName)", "Show my \(.applicationName) tasks"],
                    shortTitle: "Due Today", systemImageName: "sun.max.fill")
        AppShortcut(intent: CompleteTaskIntent(), phrases: ["Complete a task in \(.applicationName)"],
                    shortTitle: "Complete Task", systemImageName: "checkmark.circle.fill")
        AppShortcut(intent: SearchTasksIntent(), phrases: ["Search \(.applicationName) tasks", "Find a task in \(.applicationName)"],
                    shortTitle: "Search Tasks", systemImageName: "magnifyingglass")
        AppShortcut(intent: GetTasksIntent(), phrases: ["Get \(\.$filter) tasks from \(.applicationName)"],
                    shortTitle: "Get Tasks", systemImageName: "list.bullet")
        AppShortcut(intent: OpenProjectIntent(), phrases: ["Open \(\.$project) in \(.applicationName)"],
                    shortTitle: "Open Project", systemImageName: "folder.fill")
        AppShortcut(intent: ShowListIntent(), phrases: ["Show \(\.$list) in \(.applicationName)"],
                    shortTitle: "Show List", systemImageName: "tray.fill")
        AppShortcut(intent: RescheduleTaskIntent(), phrases: ["Reschedule a task in \(.applicationName)"],
                    shortTitle: "Reschedule Task", systemImageName: "calendar.badge.clock")
        AppShortcut(intent: StartFocusSessionIntent(), phrases: ["Start a focus session in \(.applicationName)"],
                    shortTitle: "Start Focus", systemImageName: "timer")
    }
}
