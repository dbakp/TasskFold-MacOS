import XCTest
@testable import TaskfoldCore

/// A sleeper the test controls: every sleep suspends until released or cancelled. No wall clock involved.
final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [(id: Int, duration: Duration, continuation: CheckedContinuation<Void, Error>)] = []
    private var cancelledEarly = Set<Int>()
    private var nextID = 0
    private(set) var requested: [Duration] = []
    var pending: Int { lock.withLock { waiters.count } }
    func sleep(_ duration: Duration) async throws {
        let id = lock.withLock { () -> Int in nextID += 1; requested.append(duration); return nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelledEarly.remove(id) != nil { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                waiters.append((id, duration, continuation)); lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let index = waiters.firstIndex(where: { $0.id == id }) {
                let waiter = waiters.remove(at: index); lock.unlock(); waiter.continuation.resume(throwing: CancellationError())
            } else { cancelledEarly.insert(id); lock.unlock() }
        }
    }
    func releaseAll() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Error>] in let all = waiters.map(\.continuation); waiters = []; return all }
        released.forEach { $0.resume() }
    }
}

@MainActor
private func settle(_ times: Int = 40) async { for _ in 0..<times { await Task.yield() } }

@MainActor
private func expect(_ condition: @MainActor () -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
    let ok = await waitUntil(condition)
    XCTAssertTrue(ok, message, file: file, line: line)
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 3) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !condition() { if Date() > end { return false }; await Task.yield(); try? await Task.sleep(for: .milliseconds(2)) }
    return true
}

final class ReconnectBackoffTests: XCTestCase {
    func testDelaysDoubleFromOneSecondAndStopAtThirty() {
        // Jitter 0 gives the nominal (full) step; the nominal sequence is 1, 2, 4, 8, 16, then the 30 s cap.
        let nominal = (0..<9).map { ReconnectBackoff.delay(forAttempt: $0, jitter: 0) }
        XCTAssertEqual(nominal, [1, 2, 4, 8, 16, 30, 30, 30, 30])
    }
    func testJitterOnlyShortensAndNeverExceedsTheCap() {
        for attempt in 0..<40 {
            let nominal = ReconnectBackoff.delay(forAttempt: attempt, jitter: 0)
            for jitter in stride(from: 0.0, through: 1.0, by: 0.1) {
                let value = ReconnectBackoff.delay(forAttempt: attempt, jitter: jitter)
                XCTAssertLessThanOrEqual(value, min(30, nominal) + 0.000_001)
                XCTAssertGreaterThanOrEqual(value, nominal * 0.75 - 0.000_001)
            }
        }
    }
    func testResetStartsOverAfterASuccessfulJoin() {
        var backoff = ReconnectBackoff()
        XCTAssertEqual(backoff.next(jitter: 0), 1); XCTAssertEqual(backoff.next(jitter: 0), 2); XCTAssertEqual(backoff.next(jitter: 0), 4)
        backoff.reset()
        XCTAssertEqual(backoff.next(jitter: 0), 1)
    }
    func testPollingRelaxesOnlyWhileRealtimeIsJoined() {
        XCTAssertEqual(SyncTiming.pollInterval(realtimeConnected: true), 120)
        XCTAssertEqual(SyncTiming.pollInterval(realtimeConnected: false), 60)
    }
}

@MainActor
final class CoalescingRunnerTests: XCTestCase {
    func testRequestsDuringARunProduceExactlyOneFollowUp() async {
        var runs = 0
        var gate: CheckedContinuation<Void, Never>?
        var runner: CoalescingRunner!
        runner = CoalescingRunner {
            runs += 1
            if runs == 1 { await withCheckedContinuation { gate = $0 } }
        }
        let first = Task { await runner.request() }
        await expect({ gate != nil })
        for _ in 0..<7 { await runner.request() } // all return at once and are remembered
        XCTAssertEqual(runs, 1)
        XCTAssertTrue(runner.runAgain)
        gate?.resume()
        await first.value
        XCTAssertEqual(runs, 2, "seven requests during one sync mean one more sync, not seven")
        XCTAssertFalse(runner.isRunning); XCTAssertFalse(runner.runAgain)
    }
    func testIdleRunnerRunsOncePerRequest() async {
        var runs = 0
        let runner = CoalescingRunner { runs += 1 }
        await runner.request(); await runner.request()
        XCTAssertEqual(runs, 2)
    }
    func testRequestDuringTheFollowUpGetsItsOwnFollowUp() async {
        var runs = 0
        var gate: CheckedContinuation<Void, Never>?
        var runner: CoalescingRunner!
        runner = CoalescingRunner {
            runs += 1
            if runs <= 2 { await withCheckedContinuation { gate = $0 } }
        }
        let first = Task { await runner.request() }
        await expect({ gate != nil })
        await runner.request(); gate?.resume(); gate = nil
        await expect({ gate != nil && runs == 2 })
        await runner.request(); gate?.resume()
        await first.value
        XCTAssertEqual(runs, 3)
    }
    func testACancelledCallerStillGetsItsFollowUpServed() async {
        var runs = 0
        var gate: CheckedContinuation<Void, Never>?
        let runner = CoalescingRunner {
            runs += 1
            if runs == 1 { await withCheckedContinuation { gate = $0 } }
        }
        let first = Task { await runner.request() }
        await expect({ gate != nil })
        await runner.request()
        first.cancel(); gate?.resume()
        await first.value
        await expect({ runs == 2 })
    }
}

@MainActor
final class SyncDebouncerTests: XCTestCase {
    func testABurstOfSignalsFiresOnce() async {
        let sleeper = ManualSleeper()
        var fired = 0
        let debouncer = SyncDebouncer(delay: .milliseconds(250), sleep: { try await sleeper.sleep($0) }) { fired += 1 }
        for _ in 0..<12 { debouncer.signal(); await settle(5) }
        XCTAssertEqual(fired, 0)
        await expect({ sleeper.pending == 1 }, "earlier timers were cancelled; one remains")
        XCTAssertEqual(sleeper.requested.last, .milliseconds(250))
        sleeper.releaseAll()
        await expect({ fired == 1 })
        await settle()
        XCTAssertEqual(fired, 1)
    }
    func testSeparatedBurstsFireSeparately() async {
        let sleeper = ManualSleeper()
        var fired = 0
        let debouncer = SyncDebouncer(delay: .milliseconds(250), sleep: { try await sleeper.sleep($0) }) { fired += 1 }
        debouncer.signal(); await expect({ sleeper.pending == 1 }); sleeper.releaseAll()
        await expect({ fired == 1 })
        debouncer.signal(); await expect({ sleeper.pending == 1 }); sleeper.releaseAll()
        await expect({ fired == 2 })
    }
    func testASignalDuringTheActionDoesNotCancelItAndSchedulesAnother() async {
        let sleeper = ManualSleeper()
        var started = 0, finished = 0
        var gate: CheckedContinuation<Void, Never>?
        var debouncer: SyncDebouncer!
        debouncer = SyncDebouncer(delay: .milliseconds(250), sleep: { try await sleeper.sleep($0) }) {
            started += 1
            await withCheckedContinuation { gate = $0 }
            finished += 1
        }
        debouncer.signal(); await expect({ sleeper.pending == 1 }); sleeper.releaseAll()
        await expect({ started == 1 && gate != nil })
        debouncer.signal() // arrives mid-sync
        await expect({ sleeper.pending == 1 })
        XCTAssertEqual(finished, 0)
        gate?.resume(); gate = nil
        await expect({ finished == 1 })
        sleeper.releaseAll()
        await expect({ started == 2 })
        gate?.resume()
    }
    func testCancelDropsAPendingSignal() async {
        let sleeper = ManualSleeper()
        var fired = 0
        let debouncer = SyncDebouncer(delay: .milliseconds(250), sleep: { try await sleeper.sleep($0) }) { fired += 1 }
        debouncer.signal(); await expect({ sleeper.pending == 1 })
        debouncer.cancel(); await settle()
        XCTAssertEqual(fired, 0)
    }
}

@MainActor
final class RealtimeSupervisorTests: XCTestCase {
    private struct Down: Error {}

    func testBackoffGrowsAcrossFailuresAndResetsAfterAJoin() async {
        let sleeper = ManualSleeper()
        var attempts = 0
        var connected: [Bool] = []
        var syncs = 0
        let supervisor = RealtimeSupervisor(
            connect: { joined, _ in
                attempts += 1
                if attempts == 4 { await joined(); throw Down() } // joins, then drops
                throw Down()
            },
            setConnected: { connected.append($0) },
            requestSync: { syncs += 1 },
            sleep: { try await sleeper.sleep($0) }, jitter: { 0 })
        let run = Task { await supervisor.run() }
        for expected in 1...5 {
            await expect({ sleeper.pending == 1 && attempts == expected })
            sleeper.releaseAll()
            await expect({ sleeper.pending == 0 })
        }
        run.cancel(); sleeper.releaseAll(); await run.value
        // 1, 2, 4 s while failing; the join on attempt 4 resets, so its drop waits 1 s again, then 2 s.
        XCTAssertEqual(sleeper.requested.prefix(5).map { $0 }, [.seconds(1), .seconds(2), .seconds(4), .seconds(1), .seconds(2)])
        await expect({ syncs == 1 }, "exactly one catch-up sync for the one join")
        XCTAssertEqual(connected.last, false, "a stopped supervisor never claims to be connected")
        XCTAssertTrue(connected.contains(true))
    }

    func testJoinRunsOneCatchUpSyncAndReportsConnected() async {
        let sleeper = ManualSleeper()
        var syncs = 0
        var connected = false
        var release: CheckedContinuation<Void, Error>?
        let supervisor = RealtimeSupervisor(
            connect: { joined, _ in
                await joined()
                try await withCheckedThrowingContinuation { release = $0 }
            },
            setConnected: { connected = $0 },
            requestSync: { syncs += 1 },
            sleep: { try await sleeper.sleep($0) }, jitter: { 0 })
        let run = Task { await supervisor.run() }
        await expect({ connected && syncs == 1 })
        run.cancel(); release?.resume(throwing: CancellationError()); await run.value
        XCTAssertFalse(connected)
        XCTAssertEqual(syncs, 1)
    }

    func testEventBurstsDebounceIntoOneSync() async {
        let sleeper = ManualSleeper()
        var syncs = 0
        var emit: (@MainActor () async -> Void)?
        var release: CheckedContinuation<Void, Error>?
        let supervisor = RealtimeSupervisor(
            connect: { joined, changed in
                emit = changed
                await joined()
                try await withCheckedThrowingContinuation { release = $0 }
            },
            setConnected: { _ in }, requestSync: { syncs += 1 },
            sleep: { try await sleeper.sleep($0) }, jitter: { 0 })
        let run = Task { await supervisor.run() }
        await expect({ syncs == 1 && emit != nil })
        for _ in 0..<30 { await emit?(); await settle(2) } // a bulk edit on another device
        await expect({ sleeper.pending == 1 })
        XCTAssertEqual(syncs, 1)
        sleeper.releaseAll()
        await expect({ syncs == 2 })
        await settle()
        XCTAssertEqual(syncs, 2, "thirty events, one sync")
        run.cancel(); release?.resume(throwing: CancellationError()); await run.value
    }

    func testWakeCutsTheReconnectDelayShort() async {
        let sleeper = ManualSleeper()
        var attempts = 0
        let supervisor = RealtimeSupervisor(
            connect: { _, _ in attempts += 1; throw Down() },
            setConnected: { _ in }, requestSync: {},
            sleep: { try await sleeper.sleep($0) }, jitter: { 0 })
        let run = Task { await supervisor.run() }
        await expect({ attempts == 1 && sleeper.pending == 1 })
        supervisor.wake() // the network came back
        await expect({ attempts == 2 })
        run.cancel(); sleeper.releaseAll(); await run.value
    }
}

final class RemoteChangesTests: XCTestCase {
    private func task(_ id: String, _ title: String, updated: String = "t0") -> Record {
        Record(["id": .string(id), "title": .string(title), "updated_at": .string(updated)])
    }
    func testOnlyContentChangesInsertionsAndRemovalsCount() {
        let before = [task("a", "A"), task("b", "B"), task("c", "C")]
        let after = [task("a", "A", updated: "t9"), task("b", "B renamed"), task("d", "D")]
        let result = RemoteChanges.compare(before: before, after: after, excluding: [])
        XCTAssertEqual(result.changed, ["b", "d"], "a timestamp-only difference is not a visible change")
        XCTAssertEqual(result.removed, ["c"])
    }
    func testThisDevicesOwnEditsAreNeverReportedAsRemote() {
        let before = [task("a", "A"), task("b", "B")]
        let after = [task("a", "A edited here"), task("b", "B edited elsewhere")]
        let result = RemoteChanges.compare(before: before, after: after, excluding: ["a"])
        XCTAssertEqual(result.changed, ["b"])
    }
    func testIdenticalSnapshotsReportNothing() {
        let rows = [task("a", "A"), task("b", "B")]
        XCTAssertTrue(RemoteChanges.compare(before: rows, after: rows, excluding: []).isEmpty)
    }
}

final class SyncStatusPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    func testUpToDateIsQuietWithRelativeTimeOnlyInTheHelp() {
        let status = SyncStatus.presentation(local: false, online: true, syncing: false, needsAttention: false, pending: 0, lastSync: now.addingTimeInterval(-5), now: now)
        XCTAssertEqual(status.title, "Synced"); XCTAssertEqual(status.symbol, "checkmark.icloud")
        XCTAssertEqual(status.state, .synced); XCTAssertEqual(status.help, "Synced just now")
        let later = SyncStatus.presentation(local: false, online: true, syncing: false, needsAttention: false, pending: 0, lastSync: now.addingTimeInterval(-300), now: now)
        XCTAssertEqual(later.title, "Synced", "the visible text never ticks")
        XCTAssertEqual(later.help, "Synced 5 minutes ago")
    }
    func testOfflineNamesTheQueuedChanges() {
        let one = SyncStatus.presentation(local: false, online: false, syncing: false, needsAttention: false, pending: 1, lastSync: now, now: now)
        XCTAssertEqual(one.title, "Offline. 1 change will sync when you're back online."); XCTAssertEqual(one.symbol, "icloud.slash"); XCTAssertEqual(one.state, .offline)
        let three = SyncStatus.presentation(local: false, online: false, syncing: false, needsAttention: true, pending: 3, lastSync: now, now: now)
        XCTAssertEqual(three.title, "Offline. 3 changes will sync when you're back online.")
        let none = SyncStatus.presentation(local: false, online: false, syncing: false, needsAttention: false, pending: 0, lastSync: now, now: now)
        XCTAssertEqual(none.title, "Offline. Changes will sync when you're back online.")
    }
    func testSyncingAndAttentionKeepTheirPrecedence() {
        XCTAssertEqual(SyncStatus.presentation(local: false, online: true, syncing: true, needsAttention: true, pending: 2, lastSync: now, now: now).state, .syncing)
        XCTAssertEqual(SyncStatus.presentation(local: false, online: true, syncing: false, needsAttention: true, pending: 2, lastSync: now, now: now).state, .needsAttention)
        XCTAssertEqual(SyncStatus.presentation(local: false, online: true, syncing: false, needsAttention: false, pending: 2, lastSync: now, now: now).title, "2 changes waiting to sync")
    }
}
