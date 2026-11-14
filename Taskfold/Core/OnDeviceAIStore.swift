import Foundation

/// The Store side of Brain dump and Smart reschedule (see BrainDump.swift and SmartReschedule.swift).
/// Both commit through the ordinary Store paths, so undo, sync, reminders and recurrence behave as they do for
/// any other task change, and each confirmed review is one undo group.
extension Store {
    /// Tasks in shared team projects follow the team's own permissions and are never rescheduled here.
    func smartRescheduleIsEditable(_ task: Record) -> Bool {
        guard task.string("user_id") == userID else { return false }
        let project = task.string("project_id")
        return project.isEmpty || nativeConversationTeamCache?.boundary.teamProjects[project] == nil
    }

    /// The deterministic plan for the overdue tasks on screen. `events` are busy times from the connected calendar.
    func smartReschedulePlan(events: [PlannerEvent], workingDays: Int = SmartReschedule.defaultWorkingDays, now: Date = Date(), hours: WorkingHours? = nil, only: Set<String>? = nil) -> SmartReschedule.Plan {
        SmartReschedule.plan(tasks: activeTasks, events: events, hours: hours ?? workingHours, workingDays: workingDays, now: now,
                             held: Set(planningState.evening), only: only, isEditable: { smartRescheduleIsEditable($0) })
    }
    /// How many overdue tasks Smart reschedule could move. Cheap enough for a header: one pass over due-date strings.
    func smartRescheduleCandidateCount(now: Date = Date()) -> Int {
        let today = calendarContext.today, held = Set(planningState.evening)
        return activeTasks.filter { task in
            let due = task.string("due_date")
            return !due.isEmpty && due < today && !held.contains(task.id) && SmartReschedule.isOverdue(task, today: today) && smartRescheduleIsEditable(task)
        }.count
    }

    /// Applies the reviewed plan as one undo group. Tasks that changed since the plan was made (completed, already
    /// rescheduled, no longer editable) are skipped. Returns how many tasks moved, or nil when nothing could be saved.
    @discardableResult
    func applySmartReschedule(_ plan: SmartReschedule.Plan, now: Date = Date()) -> Int? {
        guard signedIn || localMode else { error = "Open your workspace before rescheduling tasks."; return nil }
        let today = TaskPlanner.dayKey(now)
        let current = activeTasks.filter { SmartReschedule.isOverdue($0, today: today) && smartRescheduleIsEditable($0) }
        let changes = SmartReschedule.fieldChanges(plan, tasks: current)
        guard !changes.isEmpty else { return 0 }
        let fields = Dictionary(changes.map { ($0.task.id, $0.fields) }, uniquingKeysWith: { first, _ in first })
        do { return try commitSelection(changes.map(\.task)) { .patch(fields[$0.id] ?? [:]) } ? changes.count : nil }
        catch { self.error = error.localizedDescription; return nil }
    }

    /// The tasks of a reviewed brain dump and the This Evening / Someday entries they asked for, in one commit.
    func brainDumpChanges(_ items: [(line: MultiLineCapture.Line, planning: PlanningSlot?)]) throws -> [Mutation] {
        var changes = try workflowChanges(items.map(\.line))
        let slots = items.compactMap { item in item.planning.map { (task: item.line.task, slot: $0) } }
        guard !slots.isEmpty else { return changes }
        var filing = try BrainDump.filing(slots, tasks: activeTasks, rows: rows(Planning.table), account: userID, today: calendarContext.today)
        let run = changes.first?.workflowRun
        for index in filing.indices {
            filing[index].workflowRun = run
            if filing[index].method == "POST" { filing[index].insertOnly = true }
        }
        changes += filing
        return changes
    }
}
