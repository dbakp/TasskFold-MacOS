import AppIntents
import SwiftUI

/// Siri and Shortcuts support. Intents run in-process against `Store.shared`.
struct TaskEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Task")
    static let defaultQuery = TaskEntityQuery()
    var id: String
    var title: String
    var due: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: due.isEmpty ? nil : "\(due)")
    }
    @MainActor init(_ record: Record) {
        id = record.id; title = record.title
        due = record.due.map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? ""
    }
}

struct TaskEntityQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [TaskEntity] {
        identifiers.compactMap { Store.shared.record("tasks", id: $0) }.map(TaskEntity.init)
    }
    @MainActor func entities(matching string: String) async throws -> [TaskEntity] {
        Store.shared.tasks.filter { !$0.completed && $0.title.localizedCaseInsensitiveContains(string) }.prefix(20).map(TaskEntity.init)
    }
    @MainActor func suggestedEntities() async throws -> [TaskEntity] {
        let today = Dates.day(Date())
        return Store.shared.tasks.filter { !$0.completed && !$0.string("due_date").isEmpty && $0.string("due_date") <= today }.prefix(10).map(TaskEntity.init)
    }
}

struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Task"
    static let description = IntentDescription("Adds a task to Taskfold. Dates, times, priority (p1–p4), and #labels in the text are understood.")
    static let openAppWhenRun = false
    @Parameter(title: "Task", requestValueDialog: "What needs doing?") var text: String

    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$text)") }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = Store.shared
        guard store.signedIn else { return .result(dialog: "Open Taskfold and sign in first.") }
        let parsed = QuickEntry(text)
        var task = Record.task(user: store.userID)
        task["title"] = .string(parsed.title.isEmpty ? text : parsed.title)
        for (key, value) in parsed.updates { task[key] = value }
        guard !task.title.trimmingCharacters(in: .whitespaces).isEmpty, store.save("tasks", task) else { return .result(dialog: "Taskfold could not add that task.") }
        let when = task.due.map { " for " + $0.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) } ?? ""
        return .result(dialog: "Added “\(task.title)”\(when).")
    }
}

struct TodayTasksIntent: AppIntent {
    static let title: LocalizedStringResource = "What’s Due Today"
    static let description = IntentDescription("Reads back the open tasks due today or overdue.")
    static let openAppWhenRun = false
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

struct TaskfoldShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddTaskIntent(), phrases: ["Add a task to \(.applicationName)", "New \(.applicationName) task"],
                    shortTitle: "Add Task", systemImageName: "plus.circle.fill")
        AppShortcut(intent: TodayTasksIntent(), phrases: ["What’s due today in \(.applicationName)", "Show my \(.applicationName) tasks"],
                    shortTitle: "Due Today", systemImageName: "sun.max.fill")
        AppShortcut(intent: CompleteTaskIntent(), phrases: ["Complete a task in \(.applicationName)"],
                    shortTitle: "Complete Task", systemImageName: "checkmark.circle.fill")
    }
}
