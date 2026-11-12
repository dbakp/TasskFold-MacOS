import Foundation

/// Named timings for keeping devices in step. The REST snapshot stays the source of truth;
/// these only decide when to ask for it.
enum SyncTiming {
    /// Realtime events closer together than this share one sync (a bulk edit sends many).
    static let realtimeDebounce: Duration = .milliseconds(250)
    /// Safety-net poll while the realtime socket is joined. Realtime already requests a sync for every change.
    static let pollIntervalRealtimeJoined: TimeInterval = 600
    /// The poll waits in slices of this length and re-reads `pollInterval` each time, so a socket that drops
    /// mid-wait falls back to the short poll within one slice instead of after the whole safety-net interval.
    static let pollWaitSlice: TimeInterval = 30
    /// The socket counts as alive only if some frame (event or heartbeat reply) arrived this recently.
    static let realtimeFreshness: TimeInterval = 75
    /// Every table is re-read at least this often while realtime is joined, to catch anything an event could not
    /// signal (a row an access change hid, a missed frame). Below `pollIntervalRealtimeJoined`, so each safety-net poll reconciles.
    static let reconcileInterval: TimeInterval = 540
    /// Append-only history is trusted incrementally for this long before it is read whole again.
    static let deepReadInterval: TimeInterval = 6 * 3600
    /// Incremental history re-reads rows recorded this close to the newest row it already holds.
    static let activityOverlap: TimeInterval = 600
    /// Poll while realtime is down.
    static let pollIntervalRealtimeDown: TimeInterval = 60
    static let reconnectBase: TimeInterval = 1
    static let reconnectCap: TimeInterval = 30
    /// A sync shorter than this never shows a "Syncing" indicator, so quick syncs do not flicker.
    static let syncingIndicatorDelay: Duration = .milliseconds(500)
    /// How long a remotely changed row keeps its tint before it fades out.
    static let remoteHighlightHold: Duration = .milliseconds(150)
    static let remoteHighlightFade: TimeInterval = 1.5
    /// Local edits are not echoed back as "remote" for this long after they were made.
    static let localEditEchoWindow: TimeInterval = 15

    static func pollInterval(realtimeConnected: Bool) -> TimeInterval {
        realtimeConnected ? pollIntervalRealtimeJoined : pollIntervalRealtimeDown
    }
}

/// Exponential reconnect delay: 1, 2, 4, 8 ... capped at 30 s, with downward jitter so a
/// fleet of clients does not reconnect in lockstep. The cap is never exceeded.
struct ReconnectBackoff: Equatable {
    private(set) var attempt = 0
    /// `jitter` is in 0..<1; the delay lands between 75% and 100% of the nominal step.
    static func delay(forAttempt attempt: Int, jitter: Double) -> TimeInterval {
        let exponent = min(max(attempt, 0), 16)
        let nominal = min(SyncTiming.reconnectCap, SyncTiming.reconnectBase * pow(2, Double(exponent)))
        let clamped = min(max(jitter, 0), 0.999_999)
        return nominal * (0.75 + 0.25 * (1 - clamped))
    }
    mutating func next(jitter: Double = .random(in: 0..<1)) -> TimeInterval {
        defer { attempt += 1 }
        return Self.delay(forAttempt: attempt, jitter: jitter)
    }
    mutating func reset() { attempt = 0 }
}

/// Runs `perform` one at a time. A request that arrives while it is running is remembered, and
/// exactly one more run follows, however many requests arrived. Nothing is dropped.
@MainActor
final class CoalescingRunner {
    private let perform: @MainActor () async -> Void
    private(set) var isRunning = false
    private(set) var runAgain = false
    init(perform: @escaping @MainActor () async -> Void) { self.perform = perform }

    /// Returns when this caller's run (and any follow-up it owns) has finished. A request made
    /// while another run is active returns immediately; that run owns the follow-up.
    func request() async {
        if isRunning { runAgain = true; return }
        isRunning = true
        defer { isRunning = false }
        repeat {
            runAgain = false
            await perform()
            if runAgain, Task.isCancelled {
                // This caller was cancelled (a view went away); the request must still be served.
                runAgain = false; isRunning = false
                Task { await self.request() }
                return
            }
        } while runAgain
    }
}

/// Collapses a burst of signals into one action after a quiet period.
@MainActor
final class SyncDebouncer {
    typealias Sleeper = @Sendable (Duration) async throws -> Void
    private let delay: Duration
    private let sleep: Sleeper
    private let action: @MainActor () async -> Void
    private var timer: Task<Void, Never>?
    init(delay: Duration = SyncTiming.realtimeDebounce,
         sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
         action: @escaping @MainActor () async -> Void) {
        self.delay = delay; self.sleep = sleep; self.action = action
    }
    func signal() {
        timer?.cancel()
        let delay = delay, sleep = sleep
        timer = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            // Detached from the timer: a later signal must never cancel a sync already running.
            let action = self.action
            Task { await action() }
        }
    }
    func cancel() { timer?.cancel(); timer = nil }
}

/// Owns one realtime connection lifecycle: reconnect with backoff, report whether the socket is
/// joined, debounce its change events, and catch up with one sync each time it (re)joins.
@MainActor
final class RealtimeSupervisor {
    typealias Connect = @MainActor (_ joined: @escaping @MainActor () async -> Void,
                                    _ changed: @escaping @MainActor () async -> Void) async throws -> Void
    typealias Sleeper = @Sendable (Duration) async throws -> Void
    private let connect: Connect
    private let setConnected: @MainActor (Bool) -> Void
    private let requestSync: @MainActor () async -> Void
    private let sleep: Sleeper
    private let jitter: @MainActor () -> Double
    private let debouncer: SyncDebouncer
    private var backoff = ReconnectBackoff()
    private var waiting: Task<Void, Never>?

    init(connect: @escaping Connect,
         setConnected: @escaping @MainActor (Bool) -> Void,
         requestSync: @escaping @MainActor () async -> Void,
         debounce: Duration = SyncTiming.realtimeDebounce,
         sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
         jitter: @escaping @MainActor () -> Double = { .random(in: 0..<1) }) {
        self.connect = connect; self.setConnected = setConnected; self.requestSync = requestSync
        self.sleep = sleep; self.jitter = jitter
        self.debouncer = SyncDebouncer(delay: debounce, sleep: sleep, action: requestSync)
    }

    /// Cut a pending reconnect delay short (the network just came back).
    func wake() { waiting?.cancel() }

    func run() async {
        defer { setConnected(false); debouncer.cancel() }
        while !Task.isCancelled {
            do {
                try await connect({ [self] in
                    backoff.reset(); setConnected(true)
                    // Catch up on anything missed while the socket was down, without stalling the receive loop.
                    Task { await requestSync() }
                }, { [self] in debouncer.signal() })
            } catch { if Task.isCancelled { return } }
            setConnected(false)
            guard !Task.isCancelled else { return }
            let delay = backoff.next(jitter: jitter())
            let sleep = sleep
            let wait = Task<Void, Never> { try? await sleep(.seconds(delay)) }
            waiting = wait
            await withTaskCancellationHandler { await wait.value } onCancel: { wait.cancel() }
            waiting = nil
        }
    }
}

/// Which tasks another device or a collaborator changed, so the UI can animate them in.
enum RemoteChanges {
    struct Result: Equatable {
        var changed: Set<String> = []
        var removed: Set<String> = []
        var isEmpty: Bool { changed.isEmpty && removed.isEmpty }
    }
    private static let volatileFields: Set<String> = ["updated_at", "created_at"]
    /// Ids whose content differs between two snapshots, never including this device's own recent edits.
    static func compare(before: [Record], after: [Record], excluding local: Set<String>) -> Result {
        var previous: [String: Record] = [:]
        previous.reserveCapacity(before.count)
        for record in before { previous[record.id] = record }
        var result = Result()
        var seen = Set<String>()
        for record in after {
            let id = record.id
            seen.insert(id)
            guard !local.contains(id) else { continue }
            guard let old = previous[id] else { result.changed.insert(id); continue }
            if old.sharesAuthoredSource(with: record) || old == record { continue }
            if old.fields.filter({ !volatileFields.contains($0.key) }) != record.fields.filter({ !volatileFields.contains($0.key) }) {
                result.changed.insert(id)
            }
        }
        for id in previous.keys where !seen.contains(id) && !local.contains(id) { result.removed.insert(id) }
        return result
    }
}

extension SyncStatus {
    /// "just now" for a fresh sync, otherwise a relative phrase. Evaluated on demand, never ticking.
    static func relativeDescription(of date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: now)
    }
}


/// Which tables realtime reported since the last read, and whether the socket stayed provably alive.
/// It only decides how much to re-read; the REST read remains the source of truth.
@MainActor
final class RealtimeChangeLedger {
    struct Evidence: Equatable, Sendable {
        /// Changes whenever the socket (re)joined, dropped, or went quiet longer than `freshness`.
        var continuity: UUID
        var joined: Bool
        /// A frame arrived recently enough that no change can have slipped by unnoticed.
        var fresh: Bool
        var dirty: Set<String>
        /// An event arrived that named no table, so nothing can be ruled out.
        var unknown: Bool
    }
    private(set) var continuity = UUID()
    private var joined = false
    private var lastFrame: Date?
    private var dirty: Set<String> = []
    private var unknown = false
    private let now: () -> Date
    private let freshness: TimeInterval
    init(now: @escaping () -> Date = { Date() }, freshness: TimeInterval = SyncTiming.realtimeFreshness) {
        self.now = now; self.freshness = freshness
    }
    func noteJoined() { continuity = UUID(); joined = true; lastFrame = now() }
    func noteDisconnected() { if joined { continuity = UUID() }; joined = false }
    /// Any received frame. A silence longer than `freshness` (a suspended app, a sleeping Mac) or a clock that
    /// moved backwards breaks continuity, because events may have been lost without a close frame.
    func noteFrame() {
        let t = now()
        if joined, let last = lastFrame, t < last || t.timeIntervalSince(last) > freshness { continuity = UUID() }
        lastFrame = t
    }
    func noteEvent(table: String?) {
        noteFrame()
        if let table, !table.isEmpty { dirty.insert(table) } else { unknown = true }
    }
    func evidence() -> Evidence {
        var fresh = false
        if joined, let last = lastFrame { let age = now().timeIntervalSince(last); fresh = age >= 0 && age <= freshness }
        return Evidence(continuity: continuity, joined: joined, fresh: fresh, dirty: dirty, unknown: unknown)
    }
    /// Takes the pending changes before a read starts, so an event arriving during it is kept for the next one.
    func consume() -> Evidence { let value = evidence(); dirty = []; unknown = false; return value }
    func restore(_ value: Evidence) { dirty.formUnion(value.dirty); unknown = unknown || value.unknown }
}

/// What one workspace read must fetch. `full` is today's behaviour: every table, the whole history.
struct WorkspaceReadPlan: Equatable, Sendable {
    enum Reason: String, Sendable {
        case requested, mutation, conflict, noBase, accountChanged, boundaryChanged, realtimeGap, unknownChange, deepDue, clockMoved
    }
    var full: Bool
    var reason: Reason?
    /// Ordinary tables to read whole again. Ignored for a full read.
    var tables: Set<String> = []
    /// Read append-only history after its overlap, and re-read the assignment provenance that task edits change.
    var activity = false
    static func full(_ reason: Reason) -> Self { Self(full: true, reason: reason) }
    var isSkip: Bool { !full && tables.isEmpty && !activity }
}

/// Server-side effects of mutations this sync sent, beyond the row they name.
enum SentChanges: Equatable, Sendable {
    case none
    case tables(Set<String>)
    /// An RPC or a shape whose side effects this client cannot enumerate.
    case unknown

    /// An ordinary single-row task or label write. Everything else (team scope, batches, workflow Undo, project
    /// moves, ordering, projects, sections, preferences) is `unknown`, which forces a full read.
    static func effects(of change: Mutation) -> SentChanges {
        guard change.teamTaskScope == nil, change.teamCompletion == nil, change.teamTaskBatch == nil,
              change.organizationOrder == nil, change.personalTaskMove != true, change.workflowRun == nil,
              !WorkflowUndo.matches(change), change.reminderPreferenceField == nil,
              ["POST", "PATCH", "DELETE"].contains(change.method) else { return .unknown }
        switch change.table {
        case "tasks": return .tables(["tasks"])
        case "labels": return .tables(["labels"])
        default: return .unknown
        }
    }
    func adding(_ change: Mutation) -> Self {
        switch (self, Self.effects(of: change)) {
        case (.unknown, _), (_, .unknown): return .unknown
        case (.none, let next): return next
        case (let current, .none): return current
        case (.tables(let a), .tables(let b)): return .tables(a.union(b))
        }
    }
    var tables: Set<String> { if case .tables(let value) = self { return value }; return [] }
}

/// The complete remote read of the last successful sync. Held in memory only: a launch always starts from a
/// full read, so nothing here can outlive the process or leak across accounts.
struct WorkspaceReadBase: Sendable {
    var account: String
    var origin: String
    var generation: UUID
    /// `nil` while the service has no team boundary (an older deployment): that absence is itself the state compared.
    var boundary: TeamWorkspaceBoundary?
    var continuity: UUID
    /// Every table exactly as the server returned it, before access filtering.
    var tables: [String: [Record]]
    /// Last time every ordinary table was read whole.
    var lastFull: Date
    /// Last time history was read whole.
    var lastDeep: Date
}

enum WorkspaceReadPlanner {
    /// History and the rows derived from task edits. Everything else is read whole when it changes.
    static let derivedTables: Set<String> = [TaskActivity.table, TaskActivity.epochTable, TaskNodeActivity.table, TaskNodeActivity.epochTable, TaskAssignmentProvenance.table]
    static let ordinaryTables: Set<String> = ["projects", "sections", "labels", "tasks", "profiles", "project_collaborators", "saved_views", "favorites", "view_preferences", "view_orders", WorkflowTemplate.table, ReminderSnooze.table, FocusSessionChange.table]
    /// A project change may also move or remove its sections and members.
    static let related: [String: Set<String>] = ["projects": ["sections", "project_collaborators"]]

    struct Input {
        var base: WorkspaceReadBase?
        var account: String
        var origin: String
        var generation: UUID
        var boundary: TeamWorkspaceBoundary?
        var evidence: RealtimeChangeLedger.Evidence
        var requestedFull: Bool
        var sent: SentChanges
        var hadConflict: Bool
        var now: Date
        var reconcileInterval: TimeInterval = SyncTiming.reconcileInterval
        var deepInterval: TimeInterval = SyncTiming.deepReadInterval
    }

    static func plan(_ input: Input) -> WorkspaceReadPlan {
        if input.requestedFull { return .full(.requested) }
        if input.sent == .unknown { return .full(.mutation) }
        if input.hadConflict { return .full(.conflict) }
        guard let base = input.base else { return .full(.noBase) }
        guard base.account == input.account, base.origin == input.origin, base.generation == input.generation else { return .full(.accountChanged) }
        guard base.boundary == input.boundary else { return .full(.boundaryChanged) }
        let e = input.evidence
        guard e.joined, e.fresh, e.continuity == base.continuity else { return .full(.realtimeGap) }
        if e.unknown { return .full(.unknownChange) }
        let sinceDeep = input.now.timeIntervalSince(base.lastDeep), sinceFull = input.now.timeIntervalSince(base.lastFull)
        if sinceDeep < 0 || sinceFull < 0 { return .full(.clockMoved) }
        if sinceDeep >= input.deepInterval { return .full(.deepDue) }
        if sinceFull >= input.reconcileInterval { return WorkspaceReadPlan(full: false, tables: ordinaryTables, activity: true) }
        var touched = e.dirty.union(input.sent.tables)
        for (table, more) in related where touched.contains(table) { touched.formUnion(more) }
        // Changing a task appends history and can change who assigned it.
        let activity = touched.contains("tasks") || !touched.isDisjoint(with: derivedTables)
        return WorkspaceReadPlan(full: false, tables: touched.intersection(ordinaryTables), activity: activity)
    }
}

/// Append-only history carries a global identity sequence, which commits out of order. Reading only above the newest
/// sequence seen could skip a row that committed late, so the read starts below every row recorded within `overlap`
/// of the newest one and replaces that window wholesale.
enum ActivityIncrement {
    /// Highest sequence that may stay as held; rows above it are read again. `nil` when nothing is held.
    static func floor(_ held: [Record], overlap: TimeInterval = SyncTiming.activityOverlap) -> Int64? {
        let rows: [(sequence: Int64, at: Date)] = held.compactMap { row in
            guard let sequence = TaskActivity.integer(row["sequence"]), let at = TaskPlanning.instant(row.string("recorded_at")) else { return nil }
            return (sequence, at)
        }
        // A held row that cannot be placed in time makes the window unknowable: read the whole history.
        guard rows.count == held.count, let newest = rows.map(\.at).max() else { return held.isEmpty ? nil : 0 }
        let start = newest.addingTimeInterval(-overlap)
        guard let first = rows.filter({ $0.at >= start }).map(\.sequence).min() else { return 0 }
        return max(0, first - 1)
    }
    static func kept(_ held: [Record], through floor: Int64) -> [Record] {
        held.filter { (TaskActivity.integer($0["sequence"]) ?? .max) <= floor }
    }
}
