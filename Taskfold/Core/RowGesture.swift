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
    var rightToLeft = false
    private(set) var stage: Stage = .idle
    private(set) var offset: Double = 0
    private(set) var width: Double = 640
    private var x: Double = 0
    private var y: Double = 0
    private var initial: Double = 0
    static let leadingWidth: Double = 104
    static let trailingWidth: Double = 192
    private func allowed(_ action: RowGestureAction) -> RowGestureAction { action == .tomorrow && !canReschedule ? .none : action }
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
