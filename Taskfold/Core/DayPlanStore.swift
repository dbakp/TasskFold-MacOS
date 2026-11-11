import Foundation

/// The Store side of the daily planning ritual (see DayPlan.swift). Schedule changes are ordinary task patches
/// through `commitSelection` (so undo, sync, reminders, recurrence and shared-task rules all apply). The
/// planned and shutdown markers are written without an undo entry: undoing "Fit my day" must not forget that
/// the day was planned, and a marker is never something a person would want to undo.
extension Store {
    var dayPlanState: DayPlanState { DayPlan.state(rows: rows(DayPlan.table), account: userID, today: calendarContext.today) }

    /// Today's open tasks in the app's default order: priority bands, the manual order inside each band.
    func dayPlanTasks() -> [Record] {
        let today = calendarContext.today
        let order = record(DayPlacement.table, id: today)?["ids"].list.map(\.text) ?? []
        return DayPlacement.arranged(DayPlan.todayTasks(activeTasks, day: today), ids: order)
    }

    /// What the Today header offers now. Cheap enough for a header: one pass over due-date strings.
    func dayPlanPrompt(now: Date = Date()) -> DayPlanPrompt? {
        let today = calendarContext.today
        let hasWork = activeTasks.contains { task in
            let due = task.string("due_date")
            return !task.completed && !due.isEmpty && due <= today && TaskKind.mayComplete(task)
        }
        return DayPlan.prompt(state: dayPlanState, now: now, hours: workingHours, hasWork: hasWork)
    }

    /// Tasks still open after today's work: due today, or in today's plan and not moved on.
    func shutdownTasks() -> [Record] {
        DayPlan.openForShutdown(activeTasks, plannedIDs: dayPlanState.plannedIDs, day: calendarContext.today)
    }
    func completedTodayRoots(now: Date = Date()) -> Int { DayPlan.completedCount(activeTasks, on: now) }

    @discardableResult
    func setEstimate(_ task: Record, minutes: Int) -> Bool {
        do {
            let fields = try DayPlan.estimateFields(minutes: minutes)
            return try commitSelection([task]) { _ in .patch(fields) }
        } catch { self.error = error.localizedDescription; return false }
    }

    /// Gives one task a start time, keeping its estimate. One undoable change.
    @discardableResult
    func place(_ task: Record, at start: Date) -> Bool {
        do {
            let fields = try TaskPlanner.fields(task: task, start: start)
            return try commitSelection([task]) { _ in .patch(fields) }
        } catch { self.error = error.localizedDescription; return false }
    }

    /// Applies every placement of a fit as one undo group.
    @discardableResult
    func applyDayFit(_ fit: DayPlanFit, tasks: [Record]) -> Bool {
        let changes = DayPlan.fieldChanges(fit, tasks: tasks)
        guard !changes.isEmpty else { return true }
        let fields = Dictionary(changes.map { ($0.task.id, $0.fields) }, uniquingKeysWith: { first, _ in first })
        do { return try commitSelection(changes.map(\.task)) { .patch(fields[$0.id] ?? [:]) } }
        catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult
    func moveToTomorrow(_ tasks: [Record], now: Date = Date()) -> Bool {
        guard !tasks.isEmpty else { return true }
        do { return try commitSelection(tasks) { .patch(TaskPlanner.tomorrowFields(task: $0, now: now)) } }
        catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult
    func moveToDay(_ tasks: [Record], day: String) -> Bool {
        guard !tasks.isEmpty else { return true }
        do { return try commitSelection(tasks) { .patch(TaskPlanner.dayFields(task: $0, day: day)) } }
        catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult
    func markDayPlanned(ids: [String]) -> Bool {
        commitDayPlan { try DayPlan.markPlanned(ids: ids, rows: rows(DayPlan.table), account: userID, today: calendarContext.today) }
    }
    @discardableResult
    func markDayShutDown() -> Bool {
        commitDayPlan { try DayPlan.markShutdown(rows: rows(DayPlan.table), account: userID, today: calendarContext.today) }
    }
    private func commitDayPlan(_ build: () throws -> [Mutation]) -> Bool {
        guard signedIn || localMode else { error = "Open your workspace before planning tasks."; return false }
        do {
            let changes = try build()
            return changes.isEmpty ? true : commit(changes, remember: false)
        } catch { self.error = error.localizedDescription; return false }
    }
}
