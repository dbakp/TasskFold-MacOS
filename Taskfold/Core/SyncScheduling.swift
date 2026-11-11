import Foundation

/// Named timings for keeping devices in step. The REST snapshot stays the source of truth;
/// these only decide when to ask for it.
enum SyncTiming {
    /// Realtime events closer together than this share one sync (a bulk edit sends many).
    static let realtimeDebounce: Duration = .milliseconds(250)
    /// Safety-net poll while the realtime socket is joined.
    static let pollIntervalRealtimeJoined: TimeInterval = 120
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
