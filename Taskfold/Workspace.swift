import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One entry in the sidebar. Task sections map onto the shared `TaskScope`; Calendar is its own surface.
enum SidebarItem: Hashable {
    case today, inbox, upcoming, calendar, all, completed, project(String), label(String)
    var scope: TaskScope? {
        switch self {
        case .today: return .today
        case .inbox: return .inbox
        case .upcoming: return .upcoming
        case .all: return .all
        case .completed: return .completed
        case .project(let id): return .project(id)
        case .label(let id): return .label(id)
        case .calendar: return nil
        }
    }
    var key: String { scope?.preferenceKey ?? "calendar" }
    init(key: String) {
        if key == "calendar" { self = .calendar; return }
        switch TaskScope(preferenceKey: key) ?? .today {
        case .today: self = .today
        case .inbox: self = .inbox
        case .upcoming: self = .upcoming
        case .all: self = .all
        case .completed: self = .completed
        case .project(let id): self = .project(id)
        case .label(let id): self = .label(id)
        }
    }
    var symbol: String {
        switch self {
        case .today: return "sun.max"
        case .inbox: return "tray"
        case .upcoming: return "calendar.day.timeline.left"
        case .calendar: return "calendar"
        case .all: return "tray.full"
        case .completed: return "checkmark.circle"
        case .project: return "folder.fill"
        case .label: return "tag.fill"
        }
    }
}

extension UTType {
    static let taskfoldTask = UTType(exportedAs: "com.dbakp.taskfold.task")
}

/// Where a dragged task will land: a day, and the task it goes in front of (`nil` = end of day).
struct DragSlot: Equatable {
    var day: String
    var before: String?
}

/// A short, non-blocking confirmation shown at the foot of the list after a change. Undo goes through the
/// system undo manager, so the Edit menu and ⌘Z work exactly the same way.
struct Confirmation: Equatable {
    var id = UUID()
    var message: String
    var undoable = true
}

/// Window-level state shared by the sidebar, the list, the inspector, and the menu bar commands.
@MainActor @Observable
final class Workspace {
    let store: Store
    var section: SidebarItem {
        didSet {
            UserDefaults.standard.set(section.key, forKey: "macSection")
            guard section != oldValue else { return }
            finderTaskID = nil
            navigationSubtitle = ""
            recentDestinations.removeAll { $0 == section }
            recentDestinations.insert(section, at: 0)
            recentDestinations = Array(recentDestinations.prefix(6))
            navigationMemory[oldValue] = NavigationMemory(selection: selection, search: search, draft: quickAdd)
            let remembered = navigationMemory[section] ?? NavigationMemory()
            selection = remembered.selection.filter { store.record("tasks", id: $0) != nil }
            search = remembered.search
            quickAdd = remembered.draft
        }
    }
    var selection = Set<String>() {
        didSet { if selection != oldValue && !selection.isEmpty { finderTaskID = nil } }
    }
    var search = ""
    var quickAdd = ""
    private struct NavigationMemory {
        var selection = Set<String>()
        var search = ""
        var draft = ""
    }
    private var navigationMemory: [SidebarItem: NavigationMemory] = [:]
    var navigationSubtitle = ""
    var navigationTitle: String {
        switch section {
        case .calendar: return "Calendar"
        case .project(let id): return store.record("projects", id: id)?.name ?? "Project"
        case .label(let id): return store.record("labels", id: id)?.name ?? "Label"
        default: return scope.title
        }
    }
    var settingsTab = SettingsTab.general
    var signInRequested = false
    @ObservationIgnored private weak var finderReturnResponder: NSResponder?
    @ObservationIgnored private var finderReturnSelection: NSRange?
    @ObservationIgnored private weak var finderReturnWindow: NSWindow?
    private var finderOpenedTask = false
    var finderPresented = false {
        didSet {
            if finderPresented && !oldValue {
                finderReturnWindow = NSApp.keyWindow
                let responder = NSApp.keyWindow?.firstResponder
                finderReturnResponder = (responder as? NSTextView)?.delegate as? NSView ?? responder
                finderReturnSelection = (responder as? NSTextView)?.selectedRange()
                finderOpenedTask = false
            }
        }
    }
    var pendingFinderCommand: String?
    var finderTaskID: String?
    var recentDestinations: [SidebarItem] = []
    @ObservationIgnored var scrollBookmarks: [String: ListScrollBookmark] = [:]
    var searchPresented = false
    var inspectorShown: Bool { didSet { UserDefaults.standard.set(inspectorShown, forKey: "inspectorShown") } }
    /// Bumping these asks the matching text field to take focus.
    var quickAddFocusRequest = 0
    var titleFocusRequest = 0
    var newProjectRequest = 0
    var confirmation: Confirmation?
    var reduceMotion = false
    /// Tasks the user just checked. They stay visible for a beat so the check animation reads, then leave.
    var completing = Set<String>()
    var calendarDay = Calendar.current.startOfDay(for: Date())
    var calendarMode: CalendarMode { didSet { UserDefaults.standard.set(calendarMode.rawValue, forKey: "calendarMode") } }
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var confirmationTimer: Task<Void, Never>?
    var drag = DragCoordinator()

    init(store: Store) {
        self.store = store
        let defaults = UserDefaults.standard
        section = SidebarItem(key: defaults.string(forKey: "macSection") ?? defaults.string(forKey: "defaultView") ?? "today")
        inspectorShown = defaults.object(forKey: "inspectorShown") as? Bool ?? true
        calendarMode = CalendarMode(rawValue: defaults.string(forKey: "calendarMode") ?? "") ?? .week
        if case .project(let id) = section, store.record("projects", id: id) == nil { section = .today }
        if case .label(let id) = section, store.record("labels", id: id) == nil { section = .today }
    }

    func clearNavigationMemory() {
        navigationMemory.removeAll()
        scrollBookmarks.removeAll()
        recentDestinations.removeAll()
        finderTaskID = nil
        finderPresented = false
        pendingFinderCommand = nil
        selection = []
        search = ""
        quickAdd = ""
    }

    var inspectorVisible: Bool { inspectorShown && (!selection.isEmpty || finderTaskID.flatMap { store.record("tasks", id: $0) } != nil) }
    var actionSelection: Set<String> {
        if let id = finderTaskID, store.record("tasks", id: id) != nil { return [id] }
        return selection
    }
    func finishFinderDismissal() {
        if let command = pendingFinderCommand {
            pendingFinderCommand = nil
            switch command {
            case "new": quickAddFocusRequest += 1
            case "project": newProjectRequest += 1
            default: searchPresented = true
            }
        } else if finderOpenedTask {
            titleFocusRequest += 1
        } else if let window = finderReturnWindow, let responder = finderReturnResponder {
            window.makeFirstResponder(responder)
            if let range = finderReturnSelection, let editor = window.firstResponder as? NSTextView, NSMaxRange(range) <= (editor.string as NSString).length {
                editor.setSelectedRange(range)
            }
        }
        finderReturnResponder = nil
        finderReturnWindow = nil
        finderOpenedTask = false
    }
    func openFromFinder(_ id: String) {
        guard store.record("tasks", id: id) != nil else { return }
        selection = []
        finderTaskID = id
        finderOpenedTask = true
        inspectorShown = true
        finderPresented = false
        titleFocusRequest += 1
    }

    var layout: Animation? { Motion.respecting(reduceMotion, Motion.layout) }
    var primaryTask: Record? { actionSelection.count == 1 ? actionSelection.first.flatMap { store.record("tasks", id: $0) } : nil }
    var selectedTasks: [Record] { actionSelection.compactMap { store.record("tasks", id: $0) } }
    var scope: TaskScope { section.scope ?? .today }

    // MARK: Undo bridging

    /// Runs a store change and mirrors it into the window's undo manager so Edit ▸ Undo and ⌘Z work.
    func run(_ name: String, _ body: () -> Void) {
        let depth = store.undoStack.count
        body()
        if store.undoStack.count > depth { register(name) }
    }
    private func register(_ name: String) {
        guard let undoManager else { return }
        undoManager.setActionName(name)
        undoManager.registerUndo(withTarget: self) { workspace in
            withAnimation(workspace.layout) {
                if undoManager.isUndoing { workspace.store.undo() } else { workspace.store.redo() }
            }
            workspace.register(name)
        }
    }

    func confirm(_ message: String, undoable: Bool = true) {
        confirmationTimer?.cancel()
        withAnimation(layout) { confirmation = Confirmation(message: message, undoable: undoable) }
        confirmationTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            withAnimation(self.layout) { self.confirmation = nil }
        }
    }
    func undoFromConfirmation() {
        confirmationTimer?.cancel()
        withAnimation(layout) { confirmation = nil }
        undoManager?.undo()
    }

    // MARK: Task actions

    func open(_ id: String) {
        finderTaskID = nil
        selection = [id]
        inspectorShown = true
        titleFocusRequest += 1
    }

    /// Completing keeps the row for a moment so the check animation reads, then lets the list settle.
    func complete(_ task: Record) {
        if task.completed || completing.contains(task.id) {
            completing.remove(task.id)
            run(task.completed ? "Reopen Task" : "Complete Task") { withAnimation(layout) { store.toggle(task) } }
            if !task.completed { Feedback.complete(); confirm("Completed “\(task.title)”") }
            return
        }
        withAnimation(Motion.respecting(reduceMotion, Motion.quick)) { _ = completing.insert(task.id) }
        Feedback.complete()
        confirm("Completed “\(task.title)”")
        Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 420))
            guard completing.contains(task.id), let current = store.record("tasks", id: task.id), !current.completed else { completing.remove(task.id); return }
            run("Complete Task") { withAnimation(layout) { store.toggle(current); completing.remove(task.id) } }
        }
    }
    func toggle(_ ids: Set<String>) {
        let tasks = ids.compactMap { store.record("tasks", id: $0) }
        guard !tasks.isEmpty else { return }
        if tasks.count == 1 { complete(tasks[0]); return }
        let open = tasks.filter { !$0.completed }
        let items = open.isEmpty ? tasks : open
        run(open.isEmpty ? "Reopen Tasks" : "Complete Tasks") { withAnimation(layout) { store.toggleAll(items) } }
        Feedback.complete()
        confirm(open.isEmpty ? "Reopened \(items.count) tasks" : "Completed \(items.count) tasks")
    }
    func delete(_ ids: Set<String>) {
        let existing = ids.filter { store.record("tasks", id: $0) != nil }
        guard !existing.isEmpty else { return }
        let title = existing.count == 1 ? store.record("tasks", id: existing.first!)?.title ?? "" : ""
        run(existing.count == 1 ? "Delete Task" : "Delete Tasks") { withAnimation(layout) { store.removeAll(Array(existing)) } }
        selection.subtract(existing)
        if let id = finderTaskID, existing.contains(id) { finderTaskID = nil }
        confirm(existing.count == 1 ? "Deleted “\(title)”" : "Deleted \(existing.count) tasks")
    }
    func reschedule(_ ids: Set<String>, to day: String?, label: String) {
        var fields: [String: JSON] = ["due_date": day.map(JSON.string) ?? .null]
        if day == nil { fields["due_time"] = .null }
        run("Reschedule") { withAnimation(Motion.respecting(reduceMotion, Motion.settle)) { store.update(Array(ids), fields: fields) } }
        Feedback.drop()
        confirm(day == nil ? "Removed dates" : ids.count == 1 ? "Moved to \(label)" : "Moved \(ids.count) tasks to \(label)")
    }
    func move(_ ids: Set<String>, toProject project: String) {
        run("Move to Project") { withAnimation(layout) { store.update(Array(ids), fields: ["project_id": project.isEmpty ? .null : .string(project), "section_id": .null]) } }
        Feedback.drop()
        confirm("Moved to \(project.isEmpty ? "Inbox" : store.record("projects", id: project)?.name ?? "project")")
    }
    func setPriority(_ ids: Set<String>, _ value: Int) {
        run("Set Priority") { withAnimation(layout) { store.update(Array(ids), fields: ["priority": .number(Double(value))]) } }
        confirm(value == 4 ? "Priority cleared" : "Priority \(value) set")
    }
    func duplicate(_ ids: Set<String>) {
        let changes = ids.compactMap { store.record("tasks", id: $0) }.map { task -> Mutation in
            var copy = task; copy["id"] = .string(UUID().uuidString.lowercased()); copy["completed"] = .bool(false); copy["completed_at"] = .null; copy["created_at"] = .string(Dates.timestamp())
            return Mutation(table: "tasks", recordID: copy.id, method: "POST", fields: copy.fields)
        }
        guard !changes.isEmpty else { return }
        run("Duplicate") { withAnimation(layout) { _ = store.commit(changes) } }
        selection = Set(changes.map(\.recordID))
        confirm(changes.count == 1 ? "Duplicated" : "Duplicated \(changes.count) tasks")
    }
    /// Saves a record through the store and mirrors the change into the undo manager.
    @discardableResult
    func save(_ table: String, _ record: Record, name: String) -> Bool {
        var saved = false
        run(name) { saved = store.save(table, record) }
        return saved
    }
    /// Creates a task from quick-entry text. Returns the new task's id.
    @discardableResult
    func add(_ input: String, project: String = "", date: Date?) -> String? {
        let parsed = QuickEntry(input)
        guard !parsed.title.isEmpty else { return nil }
        var task = Record.task(user: store.userID, project: project, date: date)
        task["title"] = .string(parsed.title)
        for (key, value) in parsed.updates { task[key] = value }
        for value in parsed.updates["labels"]?.list ?? [] where !store.labels.contains(where: { $0.name == value.text }) {
            _ = store.save("labels", Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(store.userID), "name": value, "color": .string("#e31e4b")]))
        }
        var created = false
        run("Add Task") { withAnimation(layout) { created = store.save("tasks", task) } }
        return created ? task.id : nil
    }

    // MARK: Day placement

    func ordered(_ tasks: [Record], day: String) -> [Record] {
        DayPlacement.ordered(tasks, ids: store.record(DayPlacement.table, id: day)?["ids"].list.map(\.text) ?? [])
    }
    /// Moves tasks into a day at a slot, preserving the iOS DayPlacement semantics (one undoable change).
    @discardableResult
    func move(_ ids: [String], to slot: DragSlot) -> Bool {
        let tasks = ids.compactMap { store.record("tasks", id: $0) }.filter { !$0.completed && $0.id != slot.before }
        guard !tasks.isEmpty else { return false }
        var changes: [Mutation] = []
        var snapshot = store.snapshot
        for task in tasks {
            let current = Record(snapshot.tables["tasks"]?.first(where: { $0.id == task.id })?.fields ?? task.fields)
            let destination = DayPlacement.ordered(snapshot.tables["tasks"]?.filter { $0.string("due_date") == slot.day } ?? [], ids: snapshot.tables[DayPlacement.table]?.first(where: { $0.id == slot.day })?["ids"].list.map(\.text) ?? [])
            let step = DayPlacement.changes(task: current, day: slot.day, orderedIDs: destination.map(\.id), before: slot.before)
            for change in step { snapshot.apply(change) }
            changes += step
        }
        guard !changes.isEmpty else { return false }
        var moved = false
        run("Move Task") { withAnimation(Motion.respecting(reduceMotion, Motion.settle)) { moved = store.commit(changes) } }
        if moved { Feedback.drop() }
        return moved
    }

    static func next(weekday: Int, from date: Date = Date()) -> Date {
        let calendar = Calendar.current
        let today = calendar.component(.weekday, from: date)
        let delta = (weekday - today + 7) % 7
        return calendar.date(byAdding: .day, value: delta == 0 ? 7 : delta, to: calendar.startOfDay(for: date))!
    }
}

/// Tracks a live macOS drag session so rows can draw the insertion indicator and drops resolve to a slot.
@MainActor @Observable
final class DragCoordinator {
    var ids: [String] = []
    var target: DragSlot?
    @ObservationIgnored var rowHeights: [String: CGFloat] = [:]
    @ObservationIgnored var order: [(day: String, ids: [String])] = []
    var active: Bool { !ids.isEmpty }
    @ObservationIgnored private var endMonitor: Any?
    func begin(_ ids: [String], order: [(day: String, ids: [String])]) {
        self.ids = ids; self.order = order; target = nil
        guard endMonitor == nil else { return }
        // Provider preparation can happen on a plain click. Clear it after AppKit
        // handles mouse-up (and its drop delegate), never by polling button state.
        endMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyDown]) { [weak self] event in
            if event.type == .leftMouseUp || event.keyCode == 53 {
                DispatchQueue.main.async { self?.end() }
            }
            return event
        }
    }
    func end() {
        if let endMonitor { NSEvent.removeMonitor(endMonitor) }
        endMonitor = nil; ids = []; target = nil
    }
    func successor(of id: String, in day: String) -> String? {
        guard let list = order.first(where: { $0.day == day })?.ids, let index = list.firstIndex(of: id) else { return nil }
        var next = index + 1
        while list.indices.contains(next), ids.contains(list[next]) { next += 1 }
        return list.indices.contains(next) ? list[next] : nil
    }
    func propose(_ slot: DragSlot?) {
        guard slot != target else { return }
        withAnimation(Motion.quick) { target = slot }
        if slot != nil { Feedback.tick() }
    }
    func indicatorBefore(_ id: String, day: String) -> Bool { target == DragSlot(day: day, before: id) }
    func indicatorAtEnd(of day: String) -> Bool { target == DragSlot(day: day, before: nil) }
    /// Landing exactly where the task already sits is not a move.
    func isNoop(_ slot: DragSlot) -> Bool {
        guard ids.count == 1, let id = ids.first, let day = order.first(where: { $0.ids.contains(id) })?.day, day == slot.day else { return false }
        return slot.before == id || slot.before == successor(of: id, in: day)
    }
}

enum CalendarMode: String, CaseIterable, Identifiable {
    case threeDay, fiveDay, week, month, year
    var id: String { rawValue }
    var title: String {
        switch self { case .threeDay: return "3 Days"; case .fiveDay: return "5 Days"; case .week: return "Week"; case .month: return "Month"; case .year: return "Year" }
    }
    var days: Int? { switch self { case .threeDay: return 3; case .fiveDay: return 5; case .week: return 7; default: return nil } }
}

enum SettingsTab: String { case general, account, imports, invitations }
