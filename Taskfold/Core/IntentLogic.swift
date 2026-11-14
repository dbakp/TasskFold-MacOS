import Foundation

/// The decisions behind Taskfold's Shortcuts and Siri actions, kept free of the Store so
/// they are unit-tested against fixture records. Each App Intent's `perform()` reads the
/// workspace, asks these functions what to do, then applies the result through the normal
/// Store mutation path (undo, sync and reminders stay correct).
enum IntentListFilter: String, CaseIterable, Sendable { case today, overdue, upcoming, project }

enum IntentTaskSelection {
    /// Open, ordinary, titled tasks only.
    static func open(_ tasks: [Record]) -> [Record] {
        tasks.filter { TaskKind.mayComplete($0) && !$0.completed && !$0.id.isEmpty && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Priority first, then the nearest due date, then title.
    static func ordered(_ tasks: [Record]) -> [Record] {
        tasks.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            let a = $0.string("due_date"), b = $1.string("due_date")
            if a != b { return (a.isEmpty ? "9999" : a) < (b.isEmpty ? "9999" : b) }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    static func search(_ tasks: [Record], text: String, limit: Int = 20) -> [Record] {
        let words = key(text).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let hits = open(tasks).filter { task in
            let haystack = key(task.title + " " + task.string("description"))
            return words.allSatisfy { haystack.contains($0) }
        }
        return Array(ordered(hits).prefix(max(0, limit)))
    }

    /// Resolves a spoken or typed task name to open tasks. Only titles count (a name refers to a
    /// title, not to notes). Better matches come first: exact, then starts with the words, then a word
    /// starts with them, then the words appear anywhere in order-free fashion. Ties keep the usual
    /// priority, due date and title order. Case, accents and punctuation are ignored.
    static func match(_ tasks: [Record], text: String, limit: Int = 20) -> [Record] {
        let query = key(text)
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var tiers: [(rank: Int, task: Record)] = []
        for task in ordered(open(tasks)) {
            let title = key(task.title)
            let titleWords = title.split(whereSeparator: \.isWhitespace).map(String.init)
            let rank: Int
            if title == query { rank = 0 }
            else if title.hasPrefix(query) { rank = 1 }
            else if words.allSatisfy({ word in titleWords.contains { $0.hasPrefix(word) } }) { rank = 2 }
            else if words.allSatisfy({ title.contains($0) }) { rank = 3 }
            else { continue }
            tiers.append((rank, task))
        }
        // `sorted` is not stable, so the index keeps the incoming order inside a tier.
        let sorted = tiers.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
        return Array(sorted.prefix(max(0, limit)).map(\.element.task))
    }

    /// What Siri and Shortcuts offer before anyone types: tasks due today or overdue first, then the
    /// next dated tasks, then the rest, never more than `limit`.
    static func suggested(_ tasks: [Record], today: String, limit: Int = 10) -> [Record] {
        let rows = open(tasks)
        let due = ordered(rows.filter { let d = $0.string("due_date"); return !d.isEmpty && d <= today })
        let later = ordered(rows.filter { let d = $0.string("due_date"); return !d.isEmpty && d > today })
        let undated = ordered(rows.filter { $0.string("due_date").isEmpty })
        return Array((due + later + undated).prefix(max(0, limit)))
    }

    /// `today` is due today; `overdue` is before today; `upcoming` is the next seven days
    /// including today. A project shows every open task in it and its subprojects.
    static func filter(_ tasks: [Record], _ kind: IntentListFilter, today: String, calendar: Calendar = Calendar(identifier: .gregorian),
                       project: String? = nil, projects: [Record] = []) -> [Record] {
        let rows = open(tasks)
        switch kind {
        case .today: return ordered(rows.filter { $0.string("due_date") == today })
        case .overdue: return ordered(rows.filter { let d = $0.string("due_date"); return !d.isEmpty && d < today })
        case .upcoming:
            guard let start = Dates.parse(today, calendar: calendar), let end = calendar.date(byAdding: .day, value: 6, to: start) else { return [] }
            let last = Dates.day(end)
            return ordered(rows.filter { let d = $0.string("due_date"); return !d.isEmpty && d >= today && d <= last })
        case .project:
            guard let project, !project.isEmpty else { return [] }
            let ids = ProjectOrganization.descendants(project, in: projects)
            return ordered(rows.filter { ids.contains($0.string("project_id")) })
        }
    }

    private static func key(_ text: String) -> String { QuickEntryContext.key(text) }
}

enum IntentDate {
    /// Accepts a calendar date, an ISO day, or a phrase the quick-add parser understands
    /// ("tomorrow", "next friday", "in the end of month"). Returns a stored day string.
    static func day(phrase: String?, date: Date?, now: Date = Date(), calendar: Calendar = .current,
                    preferences: DatePhrasePreferences? = DatePhrasePreferences()) -> String? {
        if let date { return Dates.day(date) }
        let text = (phrase ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let resolved = QuickNaturalDateText.resolve(text, relativeTo: now, calendar: calendar, inclusiveWeekday: true, datePreferences: preferences) else { return nil }
        return Dates.day(resolved)
    }
}

extension IntentDate {
    /// The day after `now`, as a stored day string, in the given calendar.
    static func tomorrow(now: Date = Date(), calendar: Calendar = .current) -> String {
        let next = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        // Read the day in the caller's calendar and zone, so "tomorrow" is the person's tomorrow.
        var iso = Calendar(identifier: .gregorian); iso.timeZone = calendar.timeZone
        let parts = iso.dateComponents([.year, .month, .day], from: next)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// What a "move this task to a day" action should do with the task it was given.
enum IntentMovePlan: Equatable {
    case move([String: JSON]), alreadySet, heading, shared

    /// `shared` is true for tasks in shared or team projects, which are reviewed in the app rather
    /// than changed by voice (the same rule Reschedule has always followed).
    static func resolve(task: Record, day: String, shared: Bool, calendar: Calendar = .current) -> IntentMovePlan {
        guard TaskKind.mayComplete(task) else { return .heading }
        guard !shared else { return .shared }
        let fields = TaskPlanner.dayFields(task: task, day: day, calendar: calendar)
        return fields.isEmpty ? .alreadySet : .move(fields)
    }
}

/// Whether the task entity may describe tasks to the system right now. Signed-out and locked
/// devices (protected data unavailable) show nothing, on top of the intents' own passcode rule.
enum IntentEntityAccess {
    static func allowed(signedIn: Bool, protectedDataAvailable: Bool) -> Bool { signedIn && protectedDataAvailable }
}

enum IntentAddOptions {
    /// Applies the optional Add Task parameters over what the text already set.
    /// A chosen project replaces a `#project` typed in the text; a due phrase replaces a typed date.
    static func apply(to task: Record, project: String?, dueDay: String?, priority: Int?) -> Record {
        var task = task
        if let project, !project.isEmpty { task["project_id"] = .string(project); task["section_id"] = .null }
        if let dueDay, Dates.parse(dueDay) != nil { task["due_date"] = .string(dueDay) }
        if let priority, (1...4).contains(priority) { task["priority"] = .number(Double(priority)) }
        return task
    }
}

enum IntentSummary {
    /// "3 tasks due today: A, B, C and 2 more."
    static func list(_ tasks: [Record], empty: String, label: String) -> String {
        guard !tasks.isEmpty else { return empty }
        let names = tasks.prefix(5).map(\.title).joined(separator: ", ")
        let more = tasks.count > 5 ? " and \(tasks.count - 5) more" : ""
        return "\(tasks.count == 1 ? "1 task" : "\(tasks.count) tasks") \(label): \(names)\(more)."
    }
}

/// Which open task a Focus session should start on when the person gives none.
enum FocusNextTask {
    static func pick(_ tasks: [Record], today: String) -> Record? {
        let rows = IntentTaskSelection.open(tasks).filter { UUID(uuidString: $0.id) != nil }
        let due = rows.filter { let d = $0.string("due_date"); return !d.isEmpty && d <= today }
        if let first = IntentTaskSelection.ordered(due).first { return first }
        return IntentTaskSelection.ordered(rows.filter { !$0.string("due_date").isEmpty }).first ?? IntentTaskSelection.ordered(rows).first
    }
}

/// What the app does with a Focus timer control tap, judged against the session it holds now.
enum FocusControlPlan: Equatable, Sendable {
    case start(taskID: String), stop(sessionID: String), ignore(String)

    static func resolve(_ request: FocusControlRequest, current: FocusSession?, tasks: [Record], today: String, now: Date = Date()) -> FocusControlPlan {
        guard request.isFresh(at: now) else { return .ignore("That timer tap is out of date.") }
        switch request.action {
        case .start:
            if let current, current.status == .running, !current.finished(at: now) { return .ignore("A Focus session is already running.") }
            guard let task = FocusNextTask.pick(tasks, today: today) else { return .ignore("Add an open task to focus on.") }
            return .start(taskID: task.id.lowercased())
        case .stop:
            guard let current, current.status != .stopped else { return .ignore("No Focus session to stop.") }
            // Stop only the session the control showed. A newer one is left alone.
            if let seen = request.sessionID, seen != current.id { return .ignore("A newer Focus session is running.") }
            return .stop(sessionID: current.id)
        }
    }
}
