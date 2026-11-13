import Foundation

/// What the menu bar shows at a glance: the running Focus session, otherwise the next timed block, otherwise the next
/// task due today. Pure: it reads a Focus session and task rows and never writes.
enum NowNext {
    struct Focus: Equatable, Sendable {
        var taskID: String
        var title: String
        var remaining: TimeInterval
        var paused: Bool
    }
    struct Next: Equatable, Sendable {
        var taskID: String
        var title: String
        /// "HH:mm" for a timed block, nil for an untimed task.
        var time: String?
        /// A timed block that has started and is still inside its duration.
        var inProgress: Bool
    }
    enum Item: Equatable, Sendable { case focus(Focus), next(Next), clear }

    static func resolve(focus: FocusSession?, tasks: [Record], now: Date, calendar: Calendar = .current) -> Item {
        let open = tasks.filter { TaskKind.mayComplete($0) && !$0.completed && !$0.id.isEmpty }
        if let focus, focus.status != .stopped, !focus.finished(at: now),
           let task = open.first(where: { $0.id.lowercased() == focus.taskID.lowercased() }) {
            return .focus(Focus(taskID: task.id, title: displayTitle(task), remaining: focus.remaining(at: now), paused: focus.status == .paused))
        }
        let today = Dates.day(now)
        let todays = open.filter { $0.string("due_date") == today }
        var timed: [(task: Record, start: Date, end: Date)] = []
        for task in todays {
            guard let start = clock(task.string("due_time"), on: today, calendar: calendar) else { continue }
            timed.append((task, start, start.addingTimeInterval(Double(task.durationMinutes ?? 0) * 60)))
        }
        // In progress first, then the soonest upcoming block.
        if let running = timed.filter({ $0.start <= now && $0.end > now }).min(by: { $0.start > $1.start }) {
            return .next(Next(taskID: running.task.id, title: displayTitle(running.task), time: running.task.string("due_time"), inProgress: true))
        }
        if let upcoming = timed.filter({ $0.start > now }).min(by: { ($0.start, $0.task.id) < ($1.start, $1.task.id) }) {
            return .next(Next(taskID: upcoming.task.id, title: displayTitle(upcoming.task), time: upcoming.task.string("due_time"), inProgress: false))
        }
        let untimed = todays.filter { clock($0.string("due_time"), on: today, calendar: calendar) == nil }
            .sorted { ($0.priority, $0.title.lowercased(), $0.id) < ($1.priority, $1.title.lowercased(), $1.id) }
        if let task = untimed.first { return .next(Next(taskID: task.id, title: displayTitle(task), time: nil, inProgress: false)) }
        // Timed blocks that already passed today are still due today; show the most recent one.
        if let late = timed.max(by: { $0.start < $1.start }) {
            return .next(Next(taskID: late.task.id, title: displayTitle(late.task), time: late.task.string("due_time"), inProgress: false))
        }
        return .clear
    }

    /// The task a quick action (complete, start focus, snooze) applies to, if any.
    static func taskID(_ item: Item) -> String? {
        switch item { case .focus(let value): value.taskID; case .next(let value): value.taskID; case .clear: nil }
    }

    /// "18m", "1h 05m", "45s": remaining time rounded up so it never reads 0 while the timer still runs.
    static func remainingText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        if total < 60 { return "\(total)s" }
        let minutes = (total + 59) / 60
        return minutes < 60 ? "\(minutes)m" : String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    /// The optional title next to the menu bar icon, e.g. "▸ Write report · 18m". Long titles are cut with an ellipsis.
    static func compactTitle(_ item: Item, limit: Int = 24) -> String? {
        switch item {
        case .clear: return nil
        case .focus(let value):
            return "▸ " + truncated(value.title, limit) + " · " + (value.paused ? "paused " : "") + remainingText(value.remaining)
        case .next(let value):
            return (value.inProgress ? "▸ " : "") + (value.time.map { "\($0) " } ?? "") + truncated(value.title, limit)
        }
    }

    /// One spoken line for VoiceOver and the menu's header.
    static func summary(_ item: Item) -> String {
        switch item {
        case .clear: return "Nothing due today"
        case .focus(let value): return "Focusing on \(value.title), \(remainingText(value.remaining)) left" + (value.paused ? ", paused" : "")
        case .next(let value): return (value.inProgress ? "Now: " : "Next: ") + value.title + (value.time.map { " at \($0)" } ?? "")
        }
    }

    static func truncated(_ text: String, _ limit: Int) -> String {
        guard limit > 1, text.count > limit else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
    private static func displayTitle(_ task: Record) -> String {
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled task" : title
    }
    private static func clock(_ text: String, on day: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]), let date = Dates.parse(day, calendar: calendar) else { return nil }
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: date)
    }
}
