import Foundation
import Observation

/// The Store side of Habits (see Habits.swift). Tracking a habit is an ordinary `commit` of one `view_orders`
/// row, so undo, the offline queue and conflict handling behave as they do for any other change. A check-in is the
/// normal task completion: same Store path, the recurrence advances, and undo works.
extension Store {
    /// Per-account habit ids in saved order, without series that are gone or no longer repeating.
    var habitIDs: [String] { Habits.pruned(Habits.ids(rows: rows(Habits.table), account: userID), tasks: tasks, account: userID) }
    var habitCount: Int { habitIDs.count }

    /// Week start and time zone for habit readings: the person's saved week start, the device's current zone.
    var habitCalendar: Calendar {
        var calendar = productivityGoals?.calendar ?? { var c = Calendar(identifier: .gregorian); c.firstWeekday = Calendar.current.firstWeekday; return c }()
        calendar.timeZone = TimeZone(identifier: calendarContext.timeZone) ?? calendar.timeZone
        return calendar
    }
    /// The instant readings treat as now: midday of the Store's civil today, so a reading and the Today list never
    /// disagree about the day, even in the minutes around midnight.
    var habitReference: Date {
        let calendar = habitCalendar
        return Dates.parse(calendarContext.today, calendar: calendar).flatMap { calendar.date(byAdding: .hour, value: 12, to: $0) } ?? Date()
    }

    func habitReading(_ id: String) -> HabitReading? {
        Habits.read(habit: id, tasks: tasks, calendar: habitCalendar, vacations: productivityGoals?.allVacationRanges ?? [], now: habitReference)
    }
    func habitReadings() -> [HabitReading] { habitIDs.compactMap(habitReading) }

    func isHabit(_ task: Record) -> Bool { Habits.isTracked(task, ids: Habits.ids(rows: rows(Habits.table), account: userID)) }
    /// A repeating task you own, outside shared projects.
    func canTrackHabit(_ task: Record) -> Bool { Habits.eligible(task, account: userID) && !hasSharedTaskSelection([task.id]) }

    @discardableResult
    func setHabit(_ task: Record, tracked: Bool) -> Bool {
        guard signedIn || localMode else { error = "Open your workspace before tracking habits."; return false }
        if tracked, !canTrackHabit(task) { error = "Only repeating tasks you own can be tracked as habits."; return false }
        do {
            let changes = try Habits.setTracked(task, tracked: tracked, tasks: tasks, rows: rows(Habits.table), account: userID)
            return changes.isEmpty ? true : commit(changes)
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult
    func moveHabits(_ ordered: [String]) -> Bool {
        guard signedIn || localMode else { return false }
        do {
            let changes = try Habits.reorder(ordered, tasks: tasks, rows: rows(Habits.table), account: userID)
            return changes.isEmpty ? true : commit(changes)
        } catch { self.error = error.localizedDescription; return false }
    }

    /// The open occurrence a check-in completes.
    func habitOccurrence(_ id: String) -> Record? { Habits.openOccurrence(id, in: tasks) }

    /// "Habits 2/4" for the Today header, nil with no habit due.
    var habitTodaySummary: Habits.TodaySummary? {
        Habits.todaySummary(ids: habitIDs, tasks: tasks, today: calendarContext.today, calendar: habitCalendar)
    }

    // MARK: Pomodoro hand-off to the widget

    /// The Focus record the widget projection reads: the synced row plus the device-local Pomodoro overlay.
    /// The overlay lives only in this in-memory copy, never in the synced row.
    var widgetFocusRecord: Record? {
        guard var row = focusRecord, let cycle = PomodoroStorage.loadCycle(account: userID) else { return focusRecord }
        row["pomodoro"] = cycle.widgetDocument(rounds: PomodoroSettings.load().roundsBeforeLongBreak)
        return row
    }
}

/// Pomodoro state for the Focus view. Device-local (see Pomodoro.swift); the work interval itself is an ordinary
/// synced Focus session written through `Store.changeFocus`.
@MainActor @Observable
final class PomodoroModel {
    private(set) var mode: PomodoroMode = .single
    private(set) var settings = PomodoroSettings()
    private(set) var cycle: PomodoroCycle?
    private(set) var tally = PomodoroTally()
    private var account = ""
    private var defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Loads this account's device-local state. A Pomodoro launch fixture can force the mode.
    func load(account: String) {
        guard self.account != account else { return }
        self.account = account
        mode = PomodoroSettings.loadMode(from: defaults); settings = PomodoroSettings.load(from: defaults)
        cycle = PomodoroStorage.loadCycle(account: account, defaults: defaults); tally = PomodoroStorage.loadTally(account: account, defaults: defaults)
    }
    func setMode(_ value: PomodoroMode) { mode = value; PomodoroSettings.saveMode(value, to: defaults) }
    func setSettings(_ value: PomodoroSettings) { settings = value.clamped(); settings.save(to: defaults) }
    /// Replaces local state without touching storage; used by fixtures and previews.
    func preview(mode: PomodoroMode, settings: PomodoroSettings, cycle: PomodoroCycle?, tally: PomodoroTally) {
        self.mode = mode; self.settings = settings; self.cycle = cycle; self.tally = tally
    }

    var rounds: Int { settings.roundsBeforeLongBreak }
    func today(_ store: Store) -> String { store.calendarContext.today }
    func rounds(task: String, store: Store) -> Int { tally.rounds(task: task, day: today(store)) }

    private func persist(_ store: Store) {
        PomodoroStorage.saveCycle(cycle, account: account, defaults: defaults)
        var kept = tally; kept.prune(); tally = kept
        PomodoroStorage.saveTally(tally, account: account, defaults: defaults)
        store.refreshFocusWidgetForPomodoro()
    }

    /// Reconciles the cycle with the synced session and the clock; called every second while Focus is open, on
    /// launch and after a sync. Also starts the next work round when auto-start is on.
    func reconcile(_ store: Store, workspace: WorkspaceBinding, now: Date = Date()) {
        load(account: store.userID)
        guard cycle != nil else { return }
        let outcome = PomodoroCycle.reconcile(cycle, session: store.focusSession, settings: settings, now: now)
        var changed = outcome.cycle != cycle
        cycle = outcome.cycle
        if let done = outcome.completed {
            let day = TaskPlanner.dayKey(done.end, calendar: store.habitCalendar)
            if tally.record(sessionID: done.sessionID, taskID: done.taskID, day: day) { changed = true }
        }
        if settings.autoStart, let current = cycle, current.phase == .work, current.stage == .ready { _ = backToWork(store, workspace: workspace, now: now); return }
        if changed { persist(store) }
    }

    /// Starts the first work round of a cycle as a normal Focus session.
    @discardableResult
    func startCycle(_ store: Store, taskID: String, workspace: WorkspaceBinding, expected: Record?) -> Bool {
        guard let session = try? FocusSession(taskID: taskID, minutes: settings.workMinutes) else { return false }
        guard store.changeFocus(session, expected: expected, workspace: workspace) else { return false }
        cycle = PomodoroCycle.start(taskID: taskID, sessionID: session.id); persist(store); return true
    }
    func startBreak(_ store: Store, now: Date = Date()) {
        guard var next = cycle else { return }
        next.startBreak(settings: settings, at: now); cycle = next; persist(store)
    }
    func skipBreak(_ store: Store) {
        guard var next = cycle else { return }
        next.skipBreak(settings: settings); cycle = next; persist(store)
    }
    func pauseBreak(_ store: Store, now: Date = Date()) {
        guard var next = cycle else { return }
        next.pauseBreak(at: now); cycle = next; persist(store)
    }
    func resumeBreak(_ store: Store, now: Date = Date()) {
        guard var next = cycle else { return }
        next.resumeBreak(at: now); cycle = next; persist(store)
    }
    /// "Back to work": the next round is a new Focus session for the same task.
    @discardableResult
    func backToWork(_ store: Store, workspace: WorkspaceBinding, now: Date = Date()) -> Bool {
        guard var next = cycle, next.phase == .work, next.stage == .ready,
              let session = try? FocusSession(taskID: next.taskID, minutes: settings.workMinutes, now: now) else { return false }
        guard store.changeFocus(session, expected: store.focusRecord, workspace: workspace) else { return false }
        next.beginWork(sessionID: session.id); cycle = next; persist(store); return true
    }
    /// Ends the cycle (the Focus session itself is ended by its own control).
    func endCycle(_ store: Store) { guard cycle != nil else { return }; cycle = nil; persist(store) }
}
