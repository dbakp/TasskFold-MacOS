import Foundation
import CryptoKit

/// "Dependencies lite": a task may be blocked by other tasks and may carry a short "Waiting on" note.
///
/// Everything here is pure so it can be tested without a store. This file is identical in the iOS and
/// Mac repositories. The synced `task_dependencies` rows are `(id, user_id, task_id, blocked_by_task_id,
/// created_at)`; the note is the nullable `tasks.waiting_on` column.
///
/// Visibility rules, in one place:
/// - A task is blocked while at least one of its blockers is an open task this device can read.
/// - A blocker that is completed, deleted, or not readable (for example in a project the viewer cannot see)
///   never hides work. The server only returns a dependency row when the reader can access both tasks, so
///   this is a second line of defence, and an unreadable blocker is never named.
enum TaskDependencies {
    static let table = "task_dependencies"
    /// Blockers per task. The database enforces the same cap.
    static let maximumBlockers = 10
    /// Characters (Unicode scalars, as PostgreSQL counts them) in a "Waiting on" note.
    static let maximumWaitingOnLength = 140
    static let hiddenBlockerTitle = "a task you can't see"

    struct Edge: Hashable, Sendable {
        let task: String
        let blocker: String
    }

    enum Rejection: Error, Equatable, LocalizedError, Sendable {
        case selfBlock, duplicate, tooMany, cycle, unavailable
        var errorDescription: String? {
            switch self {
            case .selfBlock: return "A task can't block itself."
            case .duplicate: return "This task already blocks that one."
            case .tooMany: return "A task can be blocked by at most \(TaskDependencies.maximumBlockers) tasks."
            case .cycle: return "That would create a loop: the other task is already waiting on this one."
            case .unavailable: return "Dependencies are not available for this task."
            }
        }
    }

    static func normalized(_ id: String) -> String { id.lowercased() }

    /// Well-formed rows only; a malformed or self-referencing row is ignored rather than trusted.
    static func edges(_ rows: [Record]) -> [Edge] {
        rows.compactMap { row in
            let task = normalized(row.string("task_id")), blocker = normalized(row.string("blocked_by_task_id"))
            guard !task.isEmpty, !blocker.isEmpty, task != blocker else { return nil }
            return Edge(task: task, blocker: blocker)
        }
    }

    /// The same pair always yields the same row ID, so two devices adding one dependency converge on one
    /// row instead of tripping the unique constraint.
    static func id(task: String, blocker: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(("com.taskfold.dependency.v1|" + normalized(task) + "|" + normalized(blocker)).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString.lowercased()
    }

    // MARK: Cycles and the cap

    /// True when `target` can be reached from `start` by following "is blocked by" edges.
    static func reaches(from start: String, to target: String, edges: [Edge]) -> Bool {
        let start = normalized(start), target = normalized(target)
        var next: [String: [String]] = [:]
        for edge in edges { next[edge.task, default: []].append(edge.blocker) }
        var seen: Set<String> = [start], queue = [start]
        while let current = queue.popLast() {
            if current == target { return true }
            for blocker in next[current] ?? [] where seen.insert(blocker).inserted { queue.append(blocker) }
        }
        return false
    }

    /// Why `blocker` may not be added to `task`, or nil when it may. Checked in a fixed order so the message
    /// is stable: self, duplicate, cap, then cycle.
    static func rejection(adding blocker: String, to task: String, edges: [Edge]) -> Rejection? {
        let task = normalized(task), blocker = normalized(blocker)
        if task.isEmpty || blocker.isEmpty { return .unavailable }
        if task == blocker { return .selfBlock }
        if edges.contains(Edge(task: task, blocker: blocker)) { return .duplicate }
        if edges.filter({ $0.task == task }).count >= maximumBlockers { return .tooMany }
        // Adding task -> blocker closes a loop exactly when blocker already (transitively) waits on task.
        if reaches(from: blocker, to: task, edges: edges) { return .cycle }
        return nil
    }

    // MARK: Visibility

    /// Lower-cased IDs of tasks hidden by an open, readable blocker. Missing, deleted, completed or unreadable
    /// blockers do not hide anything.
    static func blockedTaskIDs(tasks: [Record], dependencies: [Record]) -> Set<String> {
        guard !dependencies.isEmpty else { return [] }
        var open = Set<String>()
        for task in tasks where !task.completed { open.insert(normalized(task.id)) }
        var blocked = Set<String>()
        for edge in edges(dependencies) where open.contains(edge.blocker) { blocked.insert(edge.task) }
        return blocked
    }

    /// Today and Upcoming drop blocked tasks unless the viewer chose to show them.
    static func visible(_ rows: [Record], blocked: Set<String>, showBlocked: Bool) -> [Record] {
        guard !showBlocked, !blocked.isEmpty else { return rows }
        return rows.filter { !blocked.contains(normalized($0.id)) }
    }

    // MARK: Presentation

    struct BlockerLine: Identifiable, Equatable, Sendable {
        /// The dependency row ID, used to remove it.
        let id: String
        let blockerID: String
        /// The blocker's title, or `hiddenBlockerTitle` when this reader cannot see the task.
        let title: String
        let completed: Bool
        let readable: Bool
    }

    private static func line(_ row: Record, task: String, tasks byID: [String: Record]) -> BlockerLine? {
        guard normalized(row.string("task_id")) == task else { return nil }
        let blocker = normalized(row.string("blocked_by_task_id"))
        guard !blocker.isEmpty, blocker != task else { return nil }
        guard let found = byID[blocker] else {
            return BlockerLine(id: row.id, blockerID: blocker, title: hiddenBlockerTitle, completed: false, readable: false)
        }
        let title = found.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return BlockerLine(id: row.id, blockerID: blocker, title: title.isEmpty ? "Untitled task" : title, completed: found.completed, readable: true)
    }
    private static func ordered(_ lines: [BlockerLine]) -> [BlockerLine] {
        lines.sorted { ($0.completed ? 1 : 0, $0.title.lowercased(), $0.id) < ($1.completed ? 1 : 0, $1.title.lowercased(), $1.id) }
    }

    static func blockerLines(for task: String, dependencies: [Record], tasks: [Record]) -> [BlockerLine] {
        let task = normalized(task)
        var byID: [String: Record] = [:]
        for row in tasks { byID[normalized(row.id)] = row }
        return ordered(dependencies.compactMap { line($0, task: task, tasks: byID) })
    }

    /// One pass over the readable tasks and links, shared by the list filter, the row markers and the editor.
    struct Index: Sendable {
        /// Lower-cased IDs of tasks hidden by an open, readable blocker.
        let blocked: Set<String>
        private let lines: [String: [BlockerLine]]
        static let empty = Index(tasks: [], dependencies: [])
        init(tasks: [Record], dependencies: [Record]) {
            guard !dependencies.isEmpty else { blocked = []; lines = [:]; return }
            var byID: [String: Record] = [:]
            for row in tasks { byID[TaskDependencies.normalized(row.id)] = row }
            var grouped: [String: [BlockerLine]] = [:]
            for row in dependencies {
                let task = TaskDependencies.normalized(row.string("task_id"))
                if let value = TaskDependencies.line(row, task: task, tasks: byID) { grouped[task, default: []].append(value) }
            }
            lines = grouped.mapValues(TaskDependencies.ordered)
            blocked = Set(lines.filter { $0.value.contains { $0.readable && !$0.completed } }.keys)
        }
        func lines(for task: String) -> [BlockerLine] { lines[TaskDependencies.normalized(task)] ?? [] }
        func isBlocked(_ task: String) -> Bool { blocked.contains(TaskDependencies.normalized(task)) }
    }

    /// Open tasks the picker may offer for `task`: found by the shared task search, minus the task itself,
    /// its current blockers, and anything that would be rejected (cap, loop).
    static func candidates(for task: String, search text: String, tasks: [Record], dependencies: [Record], limit: Int = 20) -> [Record] {
        let all = edges(dependencies)
        let hits = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? IntentTaskSelection.ordered(IntentTaskSelection.open(tasks))
            : IntentTaskSelection.search(tasks, text: text, limit: max(limit, 1) * 5)
        return Array(hits.filter { rejection(adding: $0.id, to: task, edges: all) == nil }.prefix(max(0, limit)))
    }

    /// The short note: whitespace collapsed, empty as nil, capped to the database limit.
    static func normalizedWaitingOn(_ text: String) -> String? {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: collapsed.unicodeScalars.prefix(maximumWaitingOnLength))
        return String(scalars)
    }

    struct Indicator: Equatable, Sendable {
        let symbol: String
        /// The complete VoiceOver label.
        let label: String
    }

    /// A subtle row marker for a blocked and/or waiting task; nil when it is neither.
    static func indicator(openBlockers: [BlockerLine], waitingOn: String?) -> Indicator? {
        // An unreadable blocker never hides a task, so it is not announced as blocking either.
        let open = openBlockers.filter { $0.readable && !$0.completed }
        let note = waitingOn.flatMap(normalizedWaitingOn)
        var parts: [String] = []
        if let first = open.first {
            parts.append(open.count == 1 ? "Blocked by \(first.title)" : "Blocked by \(open.count) tasks")
        }
        if let note { parts.append("Waiting on \(note)") }
        guard !parts.isEmpty else { return nil }
        return Indicator(symbol: open.isEmpty ? "hourglass" : "lock", label: parts.joined(separator: ". "))
    }
}
