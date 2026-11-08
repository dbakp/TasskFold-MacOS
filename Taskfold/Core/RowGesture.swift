import Foundation

/// Preferences belong to this Mac, not to the task's cloud contract.
enum RowGestureAction: String, CaseIterable, Identifiable {
    case complete, tomorrow, edit, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .complete: return "Complete / Reopen"
        case .tomorrow: return "Tomorrow"
        case .edit: return "Edit"
        case .none: return "None"
        }
    }
    var permitsFullSwipe: Bool { self == .complete || self == .tomorrow }
    /// A missing completion action must never promote a remaining Delete button
    /// to the system's full-swipe action.
    func permitsFullSwipe(for task: Record) -> Bool {
        switch self {
        case .complete: return TaskKind.mayComplete(task)
        case .tomorrow: return !task.completed
        case .edit, .none: return false
        }
    }
}

enum RowGestureCommand: String {
    case complete, tomorrow, edit, delete
    init?(_ action: RowGestureAction) { self.init(rawValue: action.rawValue) }
}

/// The root also fences legacy positional child IDs and parent relocation/replacement.
struct RowGestureIntent {
    let task: Record
    let root: Record
    let workspace: WorkspaceBinding
    func matches(_ current: Record?, root currentRoot: Record?, account: String, generation: UUID) -> Bool {
        workspace.matches(account: account, generation: generation) && current == task && currentRoot == root
    }
}

/// Logical leading/trailing movement, independent of AppKit event delivery and rendering.
struct RowGestureMotion {
    enum Stage { case idle, pending, rejected, tracking, open }
    var leading: RowGestureAction = .complete
    var trailing: RowGestureAction = .tomorrow
    var fullSwipe = false
    var canReschedule = true
    var canComplete = true
    var rightToLeft = false
    private(set) var stage: Stage = .idle
    private(set) var offset: Double = 0
    private(set) var width: Double = 640
    private var x: Double = 0
    private var y: Double = 0
    private var initial: Double = 0
    static let leadingWidth: Double = 104
    static let trailingWidth: Double = 192
    private func allowed(_ action: RowGestureAction) -> RowGestureAction { (action == .tomorrow && !canReschedule || action == .complete && !canComplete) ? .none : action }
    var action: RowGestureAction { allowed(offset >= 0 ? leading : trailing) }
    var armed: Bool { stage == .tracking && fullSwipe && action.permitsFullSwipe && abs(x) >= 120 && abs(offset) >= max(120, min(240, width * 0.55)) }

    mutating func begin(width: Double, initialOffset: Double = 0) {
        cancel()
        self.width = width.isFinite ? max(1, width) : 640
        initial = initialOffset.isFinite ? initialOffset : 0
        offset = initial; stage = .pending
    }
    /// Deltas describe finger movement, already corrected for the system scroll preference.
    /// Return true only after deliberately claiming a horizontal sequence.
    mutating func move(dx: Double, dy: Double) -> Bool {
        guard dx.isFinite, dy.isFinite else { cancel(); return false }
        guard stage == .pending || stage == .tracking else { return false }
        x += dx; y += dy
        guard x.isFinite, y.isFinite else { cancel(); return false }
        let logical = x * (rightToLeft ? -1 : 1)
        if stage == .pending {
            if abs(x) >= 8 && abs(x) > abs(y) * 1.6 {
                guard allowed(logical > 0 ? leading : trailing) != .none else { stage = .rejected; return false }
                stage = .tracking
            } else if abs(y) >= 6 { stage = .rejected; return false }
            else { return false }
        }
        let raw = initial + logical
        guard allowed(raw >= 0 ? leading : trailing) != .none else { offset = 0; return true }
        let reveal = min(width, raw >= 0 ? Self.leadingWidth : Self.trailingWidth)
        let cap = fullSwipe && allowed(raw >= 0 ? leading : trailing).permitsFullSwipe ? width : min(width, reveal + 24)
        let magnitude = min(cap, abs(raw) <= reveal ? abs(raw) : reveal + (abs(raw) - reveal) * 0.55)
        offset = raw < 0 ? -magnitude : magnitude
        return true
    }
    mutating func finish() -> RowGestureAction? {
        guard stage == .tracking else { cancel(); return nil }
        if armed { let result = action; cancel(); return result }
        let reveal = min(width, offset >= 0 ? Self.leadingWidth : Self.trailingWidth)
        if abs(offset) >= min(36, reveal * 0.35), action != .none {
            offset = offset < 0 ? -reveal : reveal; stage = .open
        } else { cancel() }
        return nil
    }
    mutating func cancel() { stage = .idle; offset = 0; x = 0; y = 0; initial = 0 }
}

/// Exact anchors for the existing priority-band rule, including unsorted input.
/// Build once for a destination; pointer updates need only a dictionary lookup.
struct TaskPriorityBandRead {
    private let priorities: [String: Int]
    private let atOrAbove: [String?], above: [String?]
    private let first: String?
    init(_ rows: [Record], excluding: Set<String> = []) {
        var priorities: [String: Int] = [:]
        var atOrAbove = [String?](repeating: nil, count: 5), above = atOrAbove
        var first: String?
        for row in rows where !excluding.contains(row.id) {
            let priority = row.priority
            if first == nil { first = row.id }
            if priorities[row.id] == nil { priorities[row.id] = priority }
            for p in 1...4 {
                if priority >= p, atOrAbove[p] == nil { atOrAbove[p] = row.id }
                if priority > p, above[p] == nil { above[p] = row.id }
            }
        }
        self.priorities = priorities; self.atOrAbove = atOrAbove; self.above = above; self.first = first
    }
    func constrained(before: String?, priority: Int) -> String? {
        guard priority >= 1 else { return first }
        guard priority <= 4 else { return nil }
        if let before, let target = priorities[before] {
            if target == priority { return before }
            if target < priority { return atOrAbove[priority] }
        }
        return above[priority]
    }
}

/// Owned by one live gesture, never by a workspace or a persistent store.
/// Only current readable presentation rows may populate it. Commit authority
/// remains with the caller's original row intent and ordinary drop writer.
final class DayDragTargetRead {
    struct Context: Equatable {
        let workspace: WorkspaceBinding
        let snapshot: UUID, access: UUID, presentation: UUID, session: UUID
        let timeZone: String
        let manual: Bool, readable: Bool
    }
    private let draggedID: String
    private var context: Context?
    private var groups: [String: [Record]] = [:]
    private var bands: [String: TaskPriorityBandRead] = [:]
    private var priority: Int?
    private(set) var sourceReads = 0
    private(set) var destinationReads = 0
    private(set) var targetReads = 0
    init(draggedID: String) { self.draggedID = draggedID }
    func clear() { context = nil; groups = [:]; bands = [:]; priority = nil }
    func constrained(before: String?, day: String, context next: Context,
                     calendar: Calendar, rows: () -> [Record], order: ([Record], String) -> [Record]) -> String? {
        targetReads += 1
        guard next.readable, next.timeZone == calendar.timeZone.identifier else { clear(); return before }
        if context != next {
            clear(); context = next; sourceReads += 1
            let source = rows()
            priority = source.first { $0.id == draggedID }?.priority
            // Date parsing runs once per source/context, not once per pointer.
            var planning = TaskPlannedDayRead(calendar: calendar)
            for row in source where !row.completed {
                groups[planning.day(row), default: []].append(row)
            }
        }
        guard let priority else { return before }
        let band: TaskPriorityBandRead
        if let existing = bands[day] { band = existing }
        else {
            band = TaskPriorityBandRead(order(groups[day] ?? [], day), excluding: [draggedID])
            bands[day] = band; destinationReads += 1
        }
        return band.constrained(before: before, priority: priority)
    }
}
