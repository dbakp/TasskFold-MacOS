import Foundation

/// The Store side of the Weekly review (see WeeklyReview.swift). Every change is an ordinary `commit`, so undo,
/// the offline queue and conflict handling behave as they do for any other task edit.
extension Store {
    var weeklyLastReviewed: Date? { WeeklyReview.lastReviewed(rows: rows(WeeklyReview.table), account: userID) }

    /// Stamps a finished review. Quiet and outside the undo history: finishing a review is never "undone".
    @discardableResult
    func markWeeklyReviewed(at now: Date = Date()) -> Bool {
        guard signedIn || localMode, !userID.isEmpty else { return false }
        do {
            let change = try WeeklyReview.markReviewed(at: now, rows: rows(WeeklyReview.table), account: userID)
            let shown = error
            guard commit([change], remember: false) else { error = shown; return false }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    /// Open tasks planned in the last 7 days, still open, that the person may edit.
    func weeklySlipped(now: Date = Date()) -> [Record] {
        WeeklyReview.slipped(activeTasks, today: TaskPlanner.dayKey(now), held: Set(planningState.evening), isEditable: { smartRescheduleIsEditable($0) })
    }
    func weeklyProjectsWithoutNextAction() -> [Record] {
        WeeklyReview.projectsWithoutNextAction(projects: projects, tasks: activeTasks, someday: Planning.listedSomeday(rows: rows(Planning.table), account: userID), account: userID)
    }
    /// Someday ideas older than a month, oldest first as filed.
    func weeklyStaleSomeday(now: Date = Date()) -> [Record] {
        let stale = Set(Planning.staleIDs(somedayTasks, now: now))
        return somedayTasks.filter { stale.contains($0.id) }
    }
    func weeklyLoad(events: [PlannerEvent], now: Date = Date()) -> WeeklyLoad {
        WeeklyReview.load(tasks: activeTasks, events: events, hours: workingHours, now: now, calendar: habitCalendar)
    }
    /// Deletes one ordinary personal task after the person confirmed. Shared and grouped tasks never reach here.
    @discardableResult
    func weeklyDelete(_ id: String) -> Bool {
        guard signedIn || localMode, let task = record("tasks", id: id), Planning.eligible(task), smartRescheduleIsEditable(task) else {
            error = "This task can’t be deleted here. Open it from its list instead."; return false
        }
        return commit([Mutation(table: "tasks", recordID: id, method: "DELETE", fields: [:])])
    }
}
