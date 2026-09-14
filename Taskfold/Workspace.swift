import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One entry in the sidebar. Task sections map onto the shared `TaskScope`; Calendar is its own surface.
enum SidebarItem: Hashable {
    case today, inbox, upcoming, calendar, all, completed, assigned, project(String), label(String)
    var scope: TaskScope? {
        switch self {
        case .today: return .today
        case .inbox: return .inbox
        case .upcoming: return .upcoming
        case .all, .assigned: return .all
        case .completed: return .completed
        case .project(let id): return .project(id)
        case .label(let id): return .label(id)
        case .calendar: return nil
        }
    }
    var key: String { self == .assigned ? "assigned" : scope?.preferenceKey ?? "calendar" }
    init(key: String) {
        if key == "calendar" { self = .calendar; return }
        if key == "assigned" { self = .assigned; return }
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
        case .assigned: return "person.crop.circle.badge.checkmark"
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
            selection = remembered.selection.filter { taskRecord($0) != nil }
            search = remembered.search
            quickAdd = remembered.draft
        }
    }
    var selection = Set<String>() {
        didSet { if selection != oldValue && !selection.isEmpty { finderTaskID = nil } }
    }
    var expandedTasks = Set<String>()
    var projectMembers: [String: [Record]] = [:]
    var memberLoadError: String?
    var rosterCache = MemberCache()
    var rosterAccount = ""
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
        case .assigned: return "Assigned to Me"
        case .project(let id): return store.record("projects", id: id)?.name ?? "Project"
        case .label(let id): return store.record("labels", id: id)?.name ?? "Label"
        default: return scope.title
        }
    }
    var settingsTab = SettingsTab.general
    /// Debug preview only: shows the signed-in account actions without a session, for screenshots.
    var previewsAccount = false
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
    /// Presents the planning sheet for a day or a week.
    var planning: PlanKind?
    /// Presents the welcome tour.
    var onboarding = false
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
        expandedTasks.removeAll()
        projectMembers.removeAll()
        rosterAccount = ""
        rosterCache = MemberCache()
        memberLoadError = nil
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

    var inspectorVisible: Bool { inspectorShown && (!selection.isEmpty || finderTaskID.flatMap { taskRecord($0) } != nil) }
    var actionSelection: Set<String> {
        if let id = finderTaskID, taskRecord(id) != nil { return [id] }
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
        guard taskRecord(id) != nil else { return }
        selection = []
        finderTaskID = id
        finderOpenedTask = true
        inspectorShown = true
        finderPresented = false
        titleFocusRequest += 1
    }

    var layout: Animation? { Motion.respecting(reduceMotion, Motion.layout) }
    var primaryTask: Record? { actionSelection.count == 1 ? actionSelection.first.flatMap { taskRecord($0) } : nil }
    var selectedTasks: [Record] { actionSelection.compactMap { taskRecord($0) } }
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
        if Self.subtaskPath(task.id) != nil {
            var changed = task
            changed["completed"] = .bool(!task.completed)
            changed["completed_at"] = task.completed ? .null : .string(Dates.timestamp())
            _ = save("tasks", changed, name: task.completed ? "Reopen Subtask" : "Complete Subtask")
            if !task.completed { Feedback.complete() }
            return
        }
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
            guard completing.contains(task.id), let current = taskRecord(task.id), !current.completed else { completing.remove(task.id); return }
            run("Complete Task") { withAnimation(layout) { store.toggle(current); completing.remove(task.id) } }
        }
    }
    func toggle(_ ids: Set<String>) {
        if ids.contains(where: { Self.subtaskPath($0) != nil }) {
            let tasks = ids.compactMap { taskRecord($0) }
            let complete = tasks.contains { !$0.completed }
            updateTasks(ids, fields: ["completed": .bool(complete), "completed_at": complete ? .string(Dates.timestamp()) : .null], name: complete ? "Complete Tasks" : "Reopen Tasks")
            return
        }
        let tasks = ids.compactMap { taskRecord($0) }
        guard !tasks.isEmpty else { return }
        if tasks.count == 1 { complete(tasks[0]); return }
        let open = tasks.filter { !$0.completed }
        let items = open.isEmpty ? tasks : open
        run(open.isEmpty ? "Reopen Tasks" : "Complete Tasks") { withAnimation(layout) { store.toggleAll(items) } }
        Feedback.complete()
        confirm(open.isEmpty ? "Reopened \(items.count) tasks" : "Completed \(items.count) tasks")
    }
    func delete(_ ids: Set<String>) {
        let nested = ids.filter { Self.subtaskPath($0) != nil }
        if !nested.isEmpty {
            var roots: [String: Record] = [:]
            for id in nested.sorted(by: { taskDepth($0) > taskDepth($1) }) {
                guard let path = Self.subtaskPath(id), !ids.contains(path[0]), let root = roots[path[0]] ?? store.record("tasks", id: path[0]), let updated = Self.replacing(root, path: Array(path.dropFirst()), value: nil) else { continue }
                roots[root.id] = updated
            }
            let changes = roots.values.map { Mutation(table: "tasks", recordID: $0.id, method: "PATCH", fields: ["subtasks": $0["subtasks"]]) }
            run("Delete Subtasks") { _ = store.commit(changes) }
            selection.subtract(nested)
            delete(ids.subtracting(nested))
            return
        }
        let existing = ids.filter { taskRecord($0) != nil }
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
        withAnimation(Motion.respecting(reduceMotion, Motion.settle)) { updateTasks(ids, fields: fields, name: "Reschedule") }
        Feedback.drop()
        confirm(day == nil ? "Removed dates" : ids.count == 1 ? "Moved to \(label)" : "Moved \(ids.count) tasks to \(label)")
    }
    func move(_ ids: Set<String>, toProject project: String) {
        withAnimation(layout) { updateTasks(ids, fields: ["project_id": project.isEmpty ? .null : .string(project), "section_id": .null], name: "Move to Project") }
        Feedback.drop()
        confirm("Moved to \(project.isEmpty ? "Inbox" : store.record("projects", id: project)?.name ?? "project")")
    }
    func setPriority(_ ids: Set<String>, _ value: Int) {
        withAnimation(layout) { updateTasks(ids, fields: ["priority": .number(Double(value))], name: "Set Priority") }
        confirm(value == 4 ? "Priority cleared" : "Priority \(value) set")
    }
    func duplicate(_ ids: Set<String>) {
        let changes = ids.compactMap { taskRecord($0) }.map { task -> Mutation in
            var copy = task; copy["user_id"] = .string(store.userID); copy["id"] = .string(UUID().uuidString.lowercased()); copy["completed"] = .bool(false); copy["completed_at"] = .null; copy["created_at"] = .string(Dates.timestamp())
            return Mutation(table: "tasks", recordID: copy.id, method: "POST", fields: copy.fields)
        }
        guard !changes.isEmpty else { return }
        run("Duplicate") { withAnimation(layout) { _ = store.commit(changes) } }
        selection = Set(changes.map(\.recordID))
        confirm(changes.count == 1 ? "Duplicated" : "Duplicated \(changes.count) tasks")
    }
    /// Saves a record through the store and mirrors the change into the undo manager.
    @discardableResult
    func save(_ table: String, _ record: Record, name: String, baseline: Record? = nil) -> Bool {
        var saved = false
        if table == "tasks", let path = Self.subtaskPath(record.id) {
            guard let root = store.record("tasks", id: path[0]), let updated = Self.replacing(root, path: Array(path.dropFirst()), value: record) else { return false }
            let rootBaseline = baseline.flatMap { Self.replacing(root, path: Array(path.dropFirst()), value: $0) }
            run(name) { saved = store.save("tasks", updated, baseline: rootBaseline) }
            return saved
        }
        run(name) { saved = store.save(table, record, baseline: baseline) }
        return saved
    }
    /// Creates a task from quick-entry text. Returns the new task's id.
    @discardableResult
    func add(_ input: String, project: String = "", date: Date?, declined: Set<String> = [], sectionID: String = "") -> String? {
        let parsed = QuickEntry(input, disabled: declined)
        guard !parsed.title.isEmpty else { return nil }
        var task = Record.task(user: store.userID, project: project, date: date)
        task["title"] = .string(parsed.title)
        if !sectionID.isEmpty { task["section_id"] = .string(sectionID) }
        if section == .assigned { task["assigned_to"] = .string(store.userID) }
        for (key, value) in parsed.updates { task[key] = value }
        for value in parsed.updates["labels"]?.list ?? [] where !store.labels.contains(where: { $0.name == value.text }) {
            _ = store.save("labels", Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(store.userID), "name": value, "color": .string("#e31e4b")]))
        }
        var created = false
        run("Add Task") { withAnimation(layout) { created = store.save("tasks", task) } }
        return created ? task.id : nil
    }

    // MARK: Placement

    /// Device-local placement keys. Days use the calendar day (shared with iOS); other lists use a group key.
    enum Placement {
        static func group(project: String, section: String) -> String { "group:\(project):\(section.isEmpty ? "none" : section)" }
        static func scope(_ scope: TaskScope) -> String { "scope:" + scope.preferenceKey }
        static func isDay(_ key: String) -> Bool { Dates.parse(key) != nil }
    }
    private func placementIDs(_ key: String, in snapshot: Snapshot? = nil) -> [String] {
        let rows = snapshot?.tables[DayPlacement.table] ?? store.rows(DayPlacement.table)
        return rows.first { $0.id == key }?["ids"].list.map(\.text) ?? []
    }
    /// The app's default order for any list: priority bands first, the user's manual order inside each band.
    func arranged(_ tasks: [Record], key: String) -> [Record] { DayPlacement.arranged(tasks, ids: placementIDs(key)) }
    func ordered(_ tasks: [Record], day: String) -> [Record] { arranged(tasks, key: day) }

    /// Moves tasks into a list at a slot. Days change the due date through the shared DayPlacement rules;
    /// group keys only re-rank (and adopt the section when the key names one). Every drop stays inside the
    /// task's priority band, and the whole move is one undoable commit.
    @discardableResult
    func move(_ ids: [String], to slot: DragSlot) -> Bool {
        let tasks = ids.compactMap { taskRecord($0) }.filter { !$0.completed && $0.id != slot.before }
        guard !tasks.isEmpty else { return false }
        var changes: [Mutation] = []
        var snapshot = store.snapshot
        let isDay = Placement.isDay(slot.day)
        for task in tasks {
            let current = Record(snapshot.tables["tasks"]?.first(where: { $0.id == task.id })?.fields ?? task.fields)
            let members: [Record]
            if isDay { members = snapshot.tables["tasks"]?.filter { $0.string("due_date") == slot.day && !$0.completed } ?? [] }
            else {
                let visible = drag.order.first { $0.day == slot.day }?.ids ?? []
                let known = Set(visible)
                let all = visible + placementIDs(slot.day, in: snapshot).filter { !known.contains($0) }
                members = all.compactMap { id in snapshot.tables["tasks"]?.first { $0.id == id } }
            }
            let destination = DayPlacement.arranged(members, ids: placementIDs(slot.day, in: snapshot))
            let before = DayPlacement.constrained(before: slot.before, priority: current.priority, in: destination.filter { $0.id != current.id })
            let step: [Mutation]
            if isDay {
                step = DayPlacement.changes(task: current, day: slot.day, orderedIDs: destination.map(\.id), before: before)
            } else {
                var order = destination.map(\.id).filter { $0 != current.id }
                order.insert(current.id, at: before.flatMap { order.firstIndex(of: $0) } ?? order.count)
                var fields: [String: JSON] = [:]
                if slot.day.hasPrefix("group:") {
                    let parts = slot.day.split(separator: ":").map(String.init)
                    if parts.count == 3 {
                        if current.string("project_id") != parts[1] { fields["project_id"] = .string(parts[1]) }
                        let section = parts[2] == "none" ? "" : parts[2]
                        if current.string("section_id") != section { fields["section_id"] = section.isEmpty ? .null : .string(section) }
                    }
                }
                step = (fields.isEmpty ? [] : [Mutation(table: "tasks", recordID: current.id, method: "PATCH", fields: fields)])
                    + [Mutation(table: DayPlacement.table, recordID: slot.day, method: "PATCH", fields: ["id": .string(slot.day), "ids": .array(order.map(JSON.string))])]
            }
            for change in step { snapshot.apply(change) }
            changes += step
        }
        guard !changes.isEmpty else { return false }
        var moved = false
        run(isDay ? "Move Task" : "Reorder Tasks") { withAnimation(Motion.respecting(reduceMotion, Motion.settle)) { moved = store.commit(changes) } }
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
    /// Shown beside the indicator when the pointer is over another priority band and the drop snapped back.
    var bandHint: String?
    @ObservationIgnored var rowHeights: [String: CGFloat] = [:]
    @ObservationIgnored var order: [(day: String, ids: [String])] = []
    @ObservationIgnored var priorities: [String: Int] = [:]
    var active: Bool { !ids.isEmpty }
    /// The band the dragged task belongs to (the first task's, for a mixed multi-drag).
    var priority: Int { ids.first.flatMap { priorities[$0] } ?? 4 }
    @ObservationIgnored private var endMonitor: Any?
    func begin(_ ids: [String], order: [(day: String, ids: [String])], priorities: [String: Int] = [:]) {
        self.ids = ids; self.order = order; self.priorities = priorities; target = nil; bandHint = nil
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
        endMonitor = nil; ids = []; target = nil; bandHint = nil
    }
    /// The destination list as lightweight records (id + priority) so band rules can run without the store.
    func members(of key: String) -> [Record] {
        (order.first { $0.day == key }?.ids ?? []).map { Record(["id": .string($0), "priority": .number(Double(priorities[$0] ?? 4))]) }
    }
    /// Snaps a raw slot into the dragged task's band and remembers whether it moved, so the indicator shows
    /// where the task will really land and the hint explains why.
    func constrain(_ slot: DragSlot) -> (slot: DragSlot, hint: String?) {
        let list = members(of: slot.day).filter { !ids.contains($0.id) }
        let before = DayPlacement.constrained(before: slot.before, priority: priority, in: list)
        let moved = before != slot.before
        return (DragSlot(day: slot.day, before: before), moved ? "Stays with P\(priority)" : nil)
    }
    func propose(raw slot: DragSlot) {
        guard active else { return }
        let result = constrain(slot)
        propose(result.slot, hint: result.hint)
    }
    func successor(of id: String, in day: String) -> String? {
        guard let list = order.first(where: { $0.day == day })?.ids, let index = list.firstIndex(of: id) else { return nil }
        var next = index + 1
        while list.indices.contains(next), ids.contains(list[next]) { next += 1 }
        return list.indices.contains(next) ? list[next] : nil
    }
    func propose(_ slot: DragSlot?, hint: String? = nil) {
        guard active || slot == nil else { return }
        let slotChanged = slot != target
        let hintAppeared = hint != nil && bandHint == nil
        guard slotChanged || hint != bandHint else { return }
        withAnimation(Motion.quick) { target = slot; bandHint = slot == nil ? nil : hint }
        // One tick per new slot, and one when the band hint first appears, never on every pointer move.
        if (slotChanged && slot != nil) || hintAppeared { Feedback.tick() }
    }
    func indicatorBefore(_ id: String, day: String) -> Bool { active && target == DragSlot(day: day, before: id) }
    func indicatorAtEnd(of day: String) -> Bool { active && target == DragSlot(day: day, before: nil) }
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

enum SettingsTab: String { case general, appearance, account, imports, invitations }

extension Workspace {
    /// Paths identify embedded subtasks without creating duplicate backend task records.
    static func subtaskPath(_ id: String) -> [String]? {
        guard id.hasPrefix("subtask:"), let data = Data(base64Encoded: String(id.dropFirst(8))),
              let path = try? JSONDecoder().decode([String].self, from: data), (2...3).contains(path.count) else { return nil }
        return path
    }
    static func childKey(_ value: JSON, index: Int) -> String { value.object["id"]?.text.isEmpty == false ? value.object["id"]!.text : "@\(index)" }
    func childID(parent: String, value: JSON, index: Int) -> String {
        let path = (Self.subtaskPath(parent) ?? [parent]) + [Self.childKey(value, index: index)]
        return "subtask:" + (try! JSONEncoder().encode(path)).base64EncodedString()
    }
    func taskDepth(_ id: String) -> Int { (Self.subtaskPath(id)?.count ?? 1) - 1 }
    func taskRecord(_ id: String) -> Record? {
        guard let path = Self.subtaskPath(id) else { return store.record("tasks", id: id) }
        guard var item = store.record("tasks", id: path[0]) else { return nil }
        for key in path.dropFirst() {
            guard let pair = item["subtasks"].list.enumerated().first(where: { Self.childKey($0.element, index: $0.offset) == key }) else { return nil }
            item = Record(pair.element.object)
        }
        item["id"] = .string(id)
        return item
    }
    func visibleTasks(_ roots: [Record]) -> [Record] {
        if section == .assigned { return roots }
        return roots.flatMap { task -> [Record] in
            guard taskDepth(task.id) < 2, expandedTasks.contains(task.id) else { return [task] }
            let children = task["subtasks"].list.enumerated().map { index, value -> Record in
                var child = Record(value.object); child["id"] = .string(childID(parent: task.id, value: value, index: index)); return child
            }
            return [task] + visibleTasks(children)
        }
    }
    static func replacing(_ root: Record, path: [String], value: Record?) -> Record? {
        guard let key = path.first else { return value }
        var list = root["subtasks"].list
        guard let index = list.enumerated().first(where: { childKey($0.element, index: $0.offset) == key })?.offset else { return nil }
        if path.count == 1 {
            if var value {
                value.fields["id"] = list[index].object["id"]
                list[index] = .object(value.fields)
            } else { list.remove(at: index) }
        } else {
            guard let changed = replacing(Record(list[index].object), path: Array(path.dropFirst()), value: value) else { return nil }
            list[index] = .object(changed.fields)
        }
        var result = root; result["subtasks"] = .array(list); return result
    }
    func updateTasks(_ ids: Set<String>, fields: [String: JSON], name: String) {
        var roots: [String: Record] = [:]
        for id in ids.sorted(by: { taskDepth($0) < taskDepth($1) }) {
            guard var task = taskRecord(id) else { continue }
            if let project = fields["project_id"], project != task["project_id"] { task = Self.clearingAssignments(task) }
            for (key, value) in fields { task[key] = value }
            if let path = Self.subtaskPath(id), let root = roots[path[0]] ?? store.record("tasks", id: path[0]) {
                roots[path[0]] = Self.replacing(root, path: Array(path.dropFirst()), value: task)
            } else { roots[id] = task }
        }
        let changes = roots.values.compactMap { record -> Mutation? in
            guard let original = store.record("tasks", id: record.id) else { return nil }
            let changed = record.fields.filter { original.fields[$0.key] != $0.value }
            return changed.isEmpty ? nil : Mutation(table: "tasks", recordID: record.id, method: "PATCH", fields: changed)
        }
        run(name) { _ = store.commit(changes) }
    }
}
