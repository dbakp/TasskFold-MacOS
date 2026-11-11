import Foundation

/// The Store side of This Evening and Someday (see Planning.swift). Every change is an ordinary `commit`, so
/// undo, the offline queue and conflict handling behave as they do for any other task edit.
extension Store {
    var planningState: PlanningState { Planning.state(rows: rows(Planning.table), account: userID, today: calendarContext.today) }

    /// Today's rows split into the regular list and This Evening (manual order).
    func eveningPartition(_ todayRows: [Record]) -> (regular: [Record], evening: [Record]) {
        Planning.partition(todayRows, state: planningState)
    }

    /// Someday tasks, newest first, honouring Focus filters and archived projects like every other list.
    var somedayTasks: [Record] {
        let state = planningState
        guard !state.someday.isEmpty else { return [] }
        return Planning.somedayTasks(matching(TaskQuery(scope: .all, sort: "manual")), state: state)
    }
    var somedayCount: Int { somedayTasks.filter { TaskKind.mayComplete($0) }.count }
    func isInSomeday(_ task: Record) -> Bool { Planning.hides(task, listed: Planning.listedSomeday(rows: rows(Planning.table), account: userID)) }
    func isInEvening(_ task: Record) -> Bool { Planning.isEvening(task, state: planningState) }

    /// Whether the action may apply: open top-level tasks, due today or earlier for This Evening.
    func canMoveToEvening(_ ids: Set<String>) -> Bool {
        let state = planningState
        return !ids.isEmpty && ids.contains { id in record("tasks", id: id).map { task in
            let day = TaskPlanner.plannedDay(task)
            return Planning.eligible(task) && !day.isEmpty && day <= state.today && !state.evening.contains(id)
        } ?? false }
    }
    func canMoveToSomeday(_ ids: Set<String>) -> Bool {
        !ids.isEmpty && ids.contains { id in record("tasks", id: id).map { Planning.eligible($0) && !Planning.isRepeating($0) && !hasSharedTaskSelection([id]) } ?? false }
    }

    @discardableResult
    func moveToEvening(_ ids: [String], before: String? = nil) -> Bool {
        commitPlanning { try Planning.moveToEvening(ids, before: before, tasks: tasks, rows: rows(Planning.table), account: userID, today: calendarContext.today) }
    }
    @discardableResult
    func removeFromEvening(_ ids: [String]) -> Bool {
        commitPlanning { try Planning.removeFromEvening(ids, tasks: tasks, rows: rows(Planning.table), account: userID, today: calendarContext.today) }
    }
    @discardableResult
    func moveToSomeday(_ ids: [String]) -> Bool {
        // Shared tasks keep their date for everyone; Someday is a personal, undated shelf.
        let personal = ids.filter { !hasSharedTaskSelection([$0]) }
        guard !personal.isEmpty else { error = "Shared tasks keep their date for the whole team, so they can’t move to Someday."; return false }
        return commitPlanning { try Planning.moveToSomeday(personal, tasks: tasks, rows: rows(Planning.table), account: userID, today: calendarContext.today) }
    }
    /// Scheduling a Someday task: the date change and the list release commit together.
    @discardableResult
    func scheduleFromSomeday(_ ids: [String], day: String) -> Bool {
        commitPlanning {
            let changes = try ids.compactMap { id -> Mutation? in
                guard let task = record("tasks", id: id) else { return nil }
                let fields = TaskPlanner.dayFields(task: task, day: day)
                return fields.isEmpty ? nil : Mutation(table: "tasks", recordID: id, method: "PATCH", fields: fields)
            }
            return changes + (try Planning.removeFromSomeday(ids, tasks: tasks, rows: rows(Planning.table), account: userID, today: calendarContext.today))
        }
    }
    /// Release without scheduling (for example a project move that keeps no date): used by "Remove from Someday".
    @discardableResult
    func removeFromSomeday(_ ids: [String]) -> Bool {
        commitPlanning { try Planning.removeFromSomeday(ids, tasks: tasks, rows: rows(Planning.table), account: userID, today: calendarContext.today) }
    }
    /// Planning rows that must be written with a task being created.
    func planningMutations(forNew task: Record, slot: PlanningSlot) throws -> [Mutation] {
        try Planning.filingNewTask(task, slot: slot, tasks: tasks, rows: rows(Planning.table), account: userID, today: calendarContext.today)
    }

    private func commitPlanning(_ build: () throws -> [Mutation]) -> Bool {
        guard signedIn || localMode else { error = "Open your workspace before planning tasks."; return false }
        do {
            let changes = try build()
            return changes.isEmpty ? true : commit(changes)
        } catch { self.error = error.localizedDescription; return false }
    }
}
