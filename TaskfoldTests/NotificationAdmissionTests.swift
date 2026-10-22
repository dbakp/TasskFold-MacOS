import XCTest
@testable import TaskfoldCore

private actor AdmissionJournal {
    var value: LocationReminderJournal
    var writes = 0
    var holdReservation = false
    var reservationStarted = false
    var gate: CheckedContinuation<Void, Never>?
    var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ value: LocationReminderJournal) { self.value = value }
    func save(_ next: LocationReminderJournal) async {
        if holdReservation && next.entries.values.contains(where: { $0.phase == .reserved }) {
            holdReservation = false; reservationStarted = true
            let callbacks = waiters; waiters = []; callbacks.forEach { $0.resume() }
            await withCheckedContinuation { gate = $0 }
        }
        value = next; writes += 1
    }
    func holdNextReservation() { holdReservation = true }
    func waitForReservation() async { if reservationStarted { return }; await withCheckedContinuation { waiters.append($0) } }
    func releaseReservation() { gate?.resume(); gate = nil }
    func snapshot() -> LocationReminderJournal { value }
}

/// One modeled OS queue for both protocols. Every write records the total, so a
/// final count of 60 cannot hide a transient overfill during a scheduler handoff.
private actor AdmissionQueue: ReminderCenter, LocationReminderCenter {
    var times: [String: ReminderRequest] = [:]
    var regions: [String: LocationReminderCandidate] = [:]
    var foreign = Set<String>()
    var delivered = Set<String>()
    var totals: [Int] = []
    var regionAdds: [LocationReminderCandidate] = []
    var reads = 0
    var failRegions = false
    var refuseNextTime = false
    var timeAttempts = 0
    var holdNextRegion = false
    var started = false
    var gate: CheckedContinuation<Void, Never>?
    var startWaiters: [CheckedContinuation<Void, Never>] = []
    func seed(times: [ReminderRequest] = [], regions: [LocationReminderCandidate] = [], foreign: Int = 0) {
        self.times = Dictionary(uniqueKeysWithValues: times.map { ($0.identifier, $0) })
        self.regions = Dictionary(uniqueKeysWithValues: regions.map { ($0.ticket.identifier, $0) })
        self.foreign = Set((0..<foreign).map { "unrelated.\($0)" }); record()
    }
    private func record() { totals.append(times.count + regions.count + foreign.count) }
    func pending() -> [ReminderRequest] { reads += 1; return Array(times.values) }
    func occupiedOutsideTimeAndFocus() -> [String] { reads += 1; return Array(regions.keys) + foreign }
    func removeInvalid(_ state: ReminderState) { times = times.filter { $0.value.valid(state: state) }; record() }
    func remove(_ ids: [String]) { for id in ids { times[id] = nil; regions[id] = nil; foreign.remove(id) }; record() }
    func add(_ request: ReminderRequest) throws {
        timeAttempts += 1
        if refuseNextTime { refuseNextTime = false; throw ReminderSchedulingFailure.noRoom }
        times[request.identifier] = request; record()
    }
    func refuseTimeForRoom() { refuseNextTime = true }
    func attemptedTimes() -> Int { timeAttempts }
    func observe() -> LocationReminderObservation { reads += 1; return .init(pending: Array(regions.values), delivered: delivered) }
    func removeAllOwned() { regions = [:]; delivered = []; record() }
    func add(_ candidate: LocationReminderCandidate) async throws {
        regionAdds.append(candidate)
        if holdNextRegion {
            holdNextRegion = false; started = true
            let callbacks = startWaiters; startWaiters = []; callbacks.forEach { $0.resume() }
            await withCheckedContinuation { gate = $0 }
        }
        if failRegions { throw AppFailure(message: "Synthetic registration refusal") }
        regions[candidate.ticket.identifier] = candidate; record()
    }
    func holdRegion() { holdNextRegion = true }
    func waitForRegion() async {
        if started { return }; await withCheckedContinuation { startWaiters.append($0) }
    }
    func releaseRegion() { gate?.resume(); gate = nil }
    func refuseRegions() { failRegions = true }
    func consume(_ candidate: LocationReminderCandidate) { regions[candidate.ticket.identifier] = nil; delivered.insert(candidate.ticket.identifier); record() }
    func snapshot() -> (times: [ReminderRequest], regions: [LocationReminderCandidate], foreign: Int, maximum: Int, attempts: Int, reads: Int) {
        (Array(times.values), Array(regions.values), foreign.count, totals.max() ?? 0, regionAdds.count, reads)
    }
}

final class NotificationAdmissionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_791_281_600)
    let account = "joint-a"
    func id(_ index: Int) -> String { "93000000-0000-4000-8000-" + String(format: "%012x", index) }
    func times(_ count: Int, offset: TimeInterval = 100) -> [DueReminder] {
        (0..<count).map { DueReminder(id: "time-\($0)", title: "Synthetic time \($0)", body: "", date: now.addingTimeInterval(offset + Double($0)), taskID: "time-\($0)", specID: "planned", signature: "time-\($0)") }
    }
    func group(_ count: Int, priorities: [Int] = []) throws -> (plan: LocationReminderPlan, candidates: [LocationReminderCandidate], tasks: [Record], places: [LocationPrivatePlace]) {
        let place = try XCTUnwrap(LocationPrivatePlace.make(account: account, name: "Synthetic place", latitude: 55.676098, longitude: 12.568337, radius: 250, id: id(2), revision: id(3)))
        let tasks = try (0..<count).map { index -> Record in
            let setting = try XCTUnwrap(LocationReminderSettings.make(device: id(1), taskID: id(100+index), taskGeneration: id(4), place: place, transition: .arrive, id: id(200+index), arm: id(300+index)))
            return Record(["id": .string(id(100+index)), "task_generation": .string(id(4)), "title": .string("Synthetic place task"), "priority": .number(Double(priorities.indices.contains(index) ? priorities[index] : 4)), "reminder_specs": .array([.object(setting.raw)])])
        }
        let plan = LocationReminderPlan(account: account, device: id(1), tasks: tasks, places: [place], availableNotificationSlots: 60, allowed: true)
        return (plan, plan.eligible, tasks, [place])
    }
    func journal(_ candidates: [LocationReminderCandidate], installed: Bool = false) -> LocationReminderJournal {
        var result = LocationReminderJournal(device: id(1))
        for candidate in candidates { XCTAssertTrue(result.prepare(candidate.ticket)); if installed { result.entries[candidate.ticket.identifier]?.phase = .installed } }
        return result
    }
    func focus() throws -> DueReminder {
        let task = Record(["id": .string(id(90)), "title": .string("Synthetic focus task")])
        let session = try FocusSession(taskID: task.id, minutes: 25, now: now)
        let row = Record(try FocusSessionChange.make(session, current: nil, account: account).fields)
        return try XCTUnwrap(FocusFinish.event(row: row, tasks: [task], account: account))
    }
    fileprivate func scheduler(_ queue: AdmissionQueue, journal: LocationReminderJournal?) -> (ReminderScheduler, AdmissionJournal) {
        let disk = AdmissionJournal(journal ?? LocationReminderJournal(device: id(1)))
        let engine = LocationReminderEngine(journal: journal, center: queue, persist: { await disk.save($0) })
        return (ReminderScheduler(center: queue, locationEngine: engine), disk)
    }
    func testLiveEngineInstallationWaitsForTimeCapacityBeforeAddingRegions() async throws {
        let group = try group(20), queue = AdmissionQueue(), events = times(60)
        let scheduler = ReminderScheduler(center: queue)
        _ = await scheduler.update(.init(revision: 1, account: account, events: events, now: now))
        let disk = AdmissionJournal(journal(group.candidates))
        let engine = LocationReminderEngine(journal: journal(group.candidates), center: queue, persist: { await disk.save($0) })
        _ = await scheduler.update(.init(revision: 2, account: account, events: events, now: now, locationPlan: group.plan), installing: engine)
        let pending = await queue.snapshot(); XCTAssertEqual(pending.maximum, 60); XCTAssertEqual(pending.times.count, 40); XCTAssertEqual(pending.regions.count, 20)
    }
    func testSameDeviceSnapshotCannotReplaceActorWithUnacknowledgedRegistration() async throws {
        let group = try group(1), queue = AdmissionQueue(); await queue.holdRegion()
        let (scheduler, disk) = scheduler(queue, journal: journal(group.candidates))
        let first = Task { await scheduler.update(.init(revision: 1, account: account, events: times(60), now: now, locationPlan: group.plan)) }
        await queue.waitForRegion()
        let staleDisk = AdmissionJournal(journal(group.candidates))
        let stale = LocationReminderEngine(journal: journal(group.candidates), center: queue, persist: { await staleDisk.save($0) })
        let next = Task { await scheduler.update(.init(revision: 2, account: account, events: times(60), now: now, locationPlan: group.plan), installing: stale) }
        while await scheduler.currentRevision < 2 { await Task.yield() }
        await queue.releaseRegion(); _ = await first.value; _ = await next.value
        let pending = await queue.snapshot(), saved = await disk.snapshot(), ignored = await staleDisk.snapshot()
        XCTAssertEqual(pending.maximum, 60); XCTAssertEqual(pending.attempts, 1); XCTAssertEqual(pending.regions.count, 1)
        XCTAssertEqual(saved.entries.values.first?.phase, .installed); XCTAssertEqual(ignored.entries.values.first?.phase, .prepared)
    }
    func testPrivateIdentityResetDuringAddCancelsOldActorBeforeInstallingNewOne() async throws {
        let group = try group(1), queue = AdmissionQueue(); await queue.holdRegion()
        let (scheduler, _) = scheduler(queue, journal: journal(group.candidates))
        let first = Task { await scheduler.update(.init(revision: 1, account: account, events: times(60), now: now, locationPlan: group.plan)) }
        await queue.waitForRegion()
        let fresh = LocationReminderJournal(device: id(99)), disk = AdmissionJournal(fresh)
        let replacement = LocationReminderEngine(journal: fresh, center: queue, persist: { await disk.save($0) })
        let next = Task { await scheduler.update(.init(revision: 2, account: account, events: times(60), now: now, locationPlan: group.plan), installing: replacement) }
        while await scheduler.currentRevision < 2 { await Task.yield() }
        await queue.releaseRegion(); _ = await first.value; _ = await next.value
        let pending = await queue.snapshot(), saved = await disk.snapshot()
        XCTAssertEqual(pending.maximum, 60); XCTAssertEqual(pending.times.count, 60); XCTAssertTrue(pending.regions.isEmpty); XCTAssertTrue(saved.entries.isEmpty)
    }
    func testPreparationBeforeHydrationDoesNotReadOrMutateOSQueue() async throws {
        let group = try group(1), queue = AdmissionQueue()
        let (scheduler, disk) = scheduler(queue, journal: journal([]))
        let prepared = await scheduler.prepareLocation(group.candidates[0].ticket)
        let before = await queue.snapshot(), saved = await disk.snapshot()
        XCTAssertTrue(prepared); XCTAssertEqual(before.reads, 0); XCTAssertEqual(before.attempts, 0)
        XCTAssertEqual(saved.entries.values.first?.phase, .prepared)
        _ = await scheduler.update(.init(revision: 1, account: account, events: times(60), now: now, locationPlan: group.plan))
        let after = await queue.snapshot(); XCTAssertEqual(after.maximum, 60); XCTAssertEqual(after.regions.count, 1)
    }
    func testAccountChangeWhileReservationPersistsCannotStartOldOSAdd() async throws {
        let group = try group(1), queue = AdmissionQueue()
        let (scheduler, disk) = scheduler(queue, journal: journal(group.candidates)); await disk.holdNextReservation()
        let first = Task { await scheduler.update(.init(revision: 1, account: account, events: times(60), now: now, locationPlan: group.plan)) }
        await disk.waitForReservation()
        let next = Task { await scheduler.update(.init(revision: 2, account: "joint-b", events: times(60), now: now)) }
        while await scheduler.currentRevision < 2 { await Task.yield() }
        await disk.releaseReservation(); _ = await first.value; _ = await next.value
        let pending = await queue.snapshot(), saved = await disk.snapshot()
        XCTAssertEqual(pending.maximum, 60); XCTAssertEqual(pending.attempts, 0); XCTAssertEqual(pending.times.count, 60)
        XCTAssertTrue(pending.times.allSatisfy { $0.account == "joint-b" }); XCTAssertEqual(saved.entries.values.first?.reason, .cancelled)
    }
    func testTitleEditDuringAddRetainsOriginalRegistrationWithoutRearming() async throws {
        let group = try group(1), queue = AdmissionQueue(); await queue.holdRegion()
        let (scheduler, disk) = scheduler(queue, journal: journal(group.candidates))
        let first = Task { await scheduler.update(.init(revision: 1, account: account, events: times(60), now: now, locationPlan: group.plan)) }
        await queue.waitForRegion()
        var renamed = group.tasks[0]; renamed["title"] = .string("Renamed task")
        let changed = LocationReminderPlan(account: account, device: id(1), tasks: [renamed], places: group.places, availableNotificationSlots: 60, allowed: true)
        let next = Task { await scheduler.update(.init(revision: 2, account: account, events: times(60), now: now, locationPlan: changed)) }
        while await scheduler.currentRevision < 2 { await Task.yield() }
        await queue.releaseRegion(); _ = await first.value; _ = await next.value
        let pending = await queue.snapshot(), saved = await disk.snapshot()
        XCTAssertEqual(pending.maximum, 60); XCTAssertEqual(pending.attempts, 1); XCTAssertEqual(pending.regions.first?.title, group.candidates[0].title)
        XCTAssertEqual(saved.entries.values.first?.phase, .installed)
    }
    func testSixtyTimeRequestsMakeRoomForTwentyRegionsAndPreserveFocusWithoutTransientOverfill() async throws {
        let group = try group(20), events = times(60), queue = AdmissionQueue()
        await queue.seed(times: events.map { .make(account: account, event: $0) })
        let (scheduler, _) = scheduler(queue, journal: journal(group.candidates))
        let report = await scheduler.update(.init(revision: 1, account: account, events: events + [try focus()], now: now, locationPlan: group.plan))
        let pending = await queue.snapshot()
        XCTAssertEqual(pending.maximum, 60); XCTAssertEqual(pending.regions.count, 20); XCTAssertEqual(pending.times.count, 40)
        XCTAssertTrue(report.focusScheduled); XCTAssertEqual(report.scheduled, 39); XCTAssertEqual(report.deferred, 21)
        XCTAssertEqual(report.reservedLocationSlots, 20); XCTAssertEqual(report.locations?.installed, 20)
    }
    func testRegionCleanupPrecedesTimeExpansionAndRemovedIntentCannotRevive() async throws {
        let group = try group(20), events = times(60), queue = AdmissionQueue()
        await queue.seed(times: Array(events.prefix(40)).map { .make(account: account, event: $0) }, regions: group.candidates)
        let (scheduler, disk) = scheduler(queue, journal: journal(group.candidates, installed: true))
        _ = await scheduler.update(.init(revision: 1, account: account, events: events, now: now))
        let pending = await queue.snapshot(), closed = await disk.snapshot()
        XCTAssertEqual(pending.maximum, 60); XCTAssertEqual(pending.times.count, 60); XCTAssertTrue(pending.regions.isEmpty)
        XCTAssertTrue(closed.entries.values.allSatisfy { $0.phase == .closed && $0.reason == .cancelled })
        _ = await scheduler.update(.init(revision: 2, account: account, events: events, now: now, locationPlan: group.plan))
        let returned = await queue.snapshot(); XCTAssertEqual(returned.attempts, 0); XCTAssertTrue(returned.regions.isEmpty)
    }
    func testForeignRequestsShareCapacityAndRemainUntouched() async throws {
        let group = try group(20), events = times(60), queue = AdmissionQueue()
        await queue.seed(times: Array(events.prefix(50)).map { .make(account: account, event: $0) }, foreign: 10)
        let (scheduler, _) = scheduler(queue, journal: journal(group.candidates))
        let report = await scheduler.update(.init(revision: 1, account: account, events: events, now: now, locationPlan: group.plan))
        let pending = await queue.snapshot()
        XCTAssertEqual(pending.maximum, 60); XCTAssertEqual(pending.foreign, 10); XCTAssertEqual(pending.regions.count, 20); XCTAssertEqual(pending.times.count, 30)
        XCTAssertEqual(report.otherPendingSlots, 10); XCTAssertEqual(report.deferred, 30)
    }
    func testNativeCapacityRefusalDefersFocusWithoutSubmittingNewLowerPriorityAlerts() async throws {
        let group = try group(1), queue = AdmissionQueue(); await queue.refuseTimeForRoom()
        let (scheduler, _) = scheduler(queue, journal: journal(group.candidates)), events = times(2) + [try focus()]
        let report = await scheduler.update(.init(revision: 1, account: account, events: events, now: now, locationPlan: group.plan))
        let pending = await queue.snapshot(), attempts = await queue.attemptedTimes()
        XCTAssertTrue(report.focusDeferred); XCTAssertFalse(report.focusFailure); XCTAssertEqual(report.failures, 0); XCTAssertEqual(report.deferred, 2)
        XCTAssertEqual(attempts, 1); XCTAssertTrue(pending.times.isEmpty); XCTAssertTrue(pending.regions.isEmpty)
        let retry = await scheduler.update(.init(revision: 2, account: account, events: events, now: now, locationPlan: group.plan))
        let ready = await queue.snapshot(); XCTAssertTrue(retry.focusScheduled); XCTAssertFalse(retry.focusDeferred); XCTAssertEqual(ready.times.count, 3); XCTAssertEqual(ready.regions.count, 1)
    }
    func testFullForeignQueueDefersFocusThenAdmitsFocusBeforeLocationWhenSpaceReturns() async throws {
        let group = try group(1), queue = AdmissionQueue(); await queue.seed(foreign: 60)
        let (scheduler, _) = scheduler(queue, journal: journal(group.candidates)), events = times(2) + [try focus()]
        let blocked = await scheduler.update(.init(revision: 1, account: account, events: events, now: now, locationPlan: group.plan))
        XCTAssertTrue(blocked.focusDeferred); XCTAssertFalse(blocked.focusScheduled); XCTAssertEqual(blocked.deferred, 2)
        await queue.remove(["unrelated.59"])
        let focusOnly = await scheduler.update(.init(revision: 2, account: account, events: events, now: now, locationPlan: group.plan))
        let first = await queue.snapshot(); XCTAssertEqual(first.times.count, 1); XCTAssertTrue(first.regions.isEmpty)
        XCTAssertTrue(focusOnly.focusScheduled); XCTAssertFalse(focusOnly.focusDeferred)
        await queue.remove(["unrelated.58"])
        _ = await scheduler.update(.init(revision: 3, account: account, events: events, now: now, locationPlan: group.plan))
        let ready = await queue.snapshot(); XCTAssertEqual(ready.maximum, 60); XCTAssertEqual(ready.times.count, 1); XCTAssertEqual(ready.regions.count, 1); XCTAssertEqual(ready.foreign, 58)
    }
    func testFocusTakesLastAvailableSlotBeforeLocationAndTimeRequests() async throws {
        let group = try group(1), queue = AdmissionQueue()
        await queue.seed(regions: group.candidates, foreign: 59)
        let (scheduler, _) = scheduler(queue, journal: journal(group.candidates, installed: true))
        let report = await scheduler.update(.init(revision: 1, account: account, events: times(2) + [try focus()], now: now, locationPlan: group.plan))
        let pending = await queue.snapshot()
        XCTAssertEqual(pending.maximum, 60); XCTAssertEqual(pending.foreign, 59); XCTAssertTrue(pending.regions.isEmpty)
        XCTAssertEqual(pending.times.count, 1); XCTAssertEqual(pending.times.first?.event.kind, .focusFinish); XCTAssertTrue(report.focusScheduled)
    }
    func testUnpreparedHighPriorityRowCannotStarveValidIntentOrReserveTimeSlots() async throws {
        let group = try group(2, priorities: [1, 2]), queue = AdmissionQueue()
        let prepared = try XCTUnwrap(group.candidates.first { $0.ticket.taskID == id(101) })
        let (scheduler, _) = scheduler(queue, journal: journal([prepared]))
        let report = await scheduler.update(.init(revision: 1, account: account, events: times(60), now: now, locationPlan: group.plan))
        let pending = await queue.snapshot()
        XCTAssertEqual(pending.maximum, 60); XCTAssertEqual(pending.regions.map(\.ticket), [prepared.ticket]); XCTAssertEqual(pending.times.count, 59)
        XCTAssertEqual(report.reservedLocationSlots, 1); XCTAssertEqual(report.locations?.failed, 1)
    }
    func testNativeRefusalReleasesReservedSlotInSameDrain() async throws {
        let group = try group(1), queue = AdmissionQueue(); await queue.refuseRegions()
        let (scheduler, disk) = scheduler(queue, journal: journal(group.candidates))
        let report = await scheduler.update(.init(revision: 1, account: account, events: times(60), now: now, locationPlan: group.plan))
        let pending = await queue.snapshot(), saved = await disk.snapshot()
        XCTAssertEqual(pending.maximum, 60); XCTAssertEqual(pending.times.count, 60); XCTAssertEqual(pending.attempts, 1)
        XCTAssertTrue(pending.regions.isEmpty); XCTAssertEqual(report.reservedLocationSlots, 0); XCTAssertEqual(report.locations?.failed, 1)
        XCTAssertEqual(saved.entries.values.first?.phase, .closed)
    }
    func testConsumedOneShotReleasesTimeCapacityWithoutRearming() async throws {
        let group = try group(1), queue = AdmissionQueue(), candidate = try XCTUnwrap(group.candidates.first)
        let (scheduler, _) = scheduler(queue, journal: journal(group.candidates))
        _ = await scheduler.update(.init(revision: 1, account: account, events: times(60), now: now, locationPlan: group.plan))
        await queue.consume(candidate)
        let report = await scheduler.update(.init(revision: 2, account: account, events: times(60), now: now, locationPlan: group.plan))
        let pending = await queue.snapshot()
        XCTAssertEqual(pending.maximum, 60); XCTAssertEqual(pending.times.count, 60); XCTAssertEqual(pending.attempts, 1); XCTAssertEqual(report.reservedLocationSlots, 0)
    }
    func testAccountChangeDuringLocationAddRemovesLateRequestBeforeNewAccountFillsQueue() async throws {
        let group = try group(1), queue = AdmissionQueue(); await queue.holdRegion()
        let (scheduler, disk) = scheduler(queue, journal: journal(group.candidates))
        let first = Task { await scheduler.update(.init(revision: 1, account: account, events: times(60), now: now, locationPlan: group.plan)) }
        await queue.waitForRegion()
        let next = Task { await scheduler.update(.init(revision: 2, account: "joint-b", events: times(60), now: now)) }
        while await scheduler.currentRevision < 2 { await Task.yield() }
        await queue.releaseRegion(); _ = await first.value; let report = await next.value
        let pending = await queue.snapshot(), saved = await disk.snapshot()
        XCTAssertEqual(pending.maximum, 60); XCTAssertEqual(pending.times.count, 60); XCTAssertTrue(pending.times.allSatisfy { $0.account == "joint-b" })
        XCTAssertTrue(pending.regions.isEmpty); XCTAssertEqual(saved.entries.values.first?.reason, .cancelled); XCTAssertEqual(report.revision, 2)
    }
    func testSnoozeDuringLocationAddDoesNotCancelUnchangedLocationIntent() async throws {
        let group = try group(1), queue = AdmissionQueue(), events = times(60, offset: 3600); await queue.holdRegion()
        let (scheduler, disk) = scheduler(queue, journal: journal(group.candidates))
        let first = Task { await scheduler.update(.init(revision: 1, account: account, events: events, now: now, locationPlan: group.plan)) }
        await queue.waitForRegion()
        let beforeSnooze = await scheduler.intentRevision()
        let snooze = Task { await scheduler.snooze(account: account, taskID: events[0].taskID, specID: events[0].specID, signature: events[0].signature, minutes: 5, now: now) }
        // The actor must receive the snooze before the held add completes.
        while await scheduler.intentRevision() == beforeSnooze { await Task.yield() }
        await queue.releaseRegion(); _ = await first.value; let report = await snooze.value
        let pending = await queue.snapshot(), saved = await disk.snapshot()
        XCTAssertNotNil(report); XCTAssertEqual(report?.snoozeOutcome, .scheduled); XCTAssertEqual(pending.maximum, 60); XCTAssertEqual(pending.attempts, 1); XCTAssertEqual(pending.regions.count, 1)
        XCTAssertEqual(saved.entries.values.first?.phase, .installed); XCTAssertEqual(pending.times.filter(\.snoozed).count, 1)
    }
    func testSnoozeWaitingForForeignCapacityDoesNotClaimItWasScheduled() async throws {
        let queue = AdmissionQueue(), events = times(1, offset: 3600); await queue.seed(foreign: 60)
        let scheduler = ReminderScheduler(center: queue)
        _ = await scheduler.update(.init(revision: 1, account: account, events: events, now: now))
        let waiting = await scheduler.snooze(account: account, taskID: events[0].taskID, specID: events[0].specID, signature: events[0].signature, minutes: 5, now: now)
        XCTAssertEqual(waiting?.snoozeOutcome, .waitingForSpace); XCTAssertEqual(waiting?.failures, 0)
        await queue.remove(["unrelated.59", "unrelated.58"])
        _ = await scheduler.update(.init(revision: 2, account: account, events: events, now: now))
        let pending = await queue.snapshot(); XCTAssertEqual(pending.maximum, 60); XCTAssertEqual(pending.times.filter(\.snoozed).count, 1)
    }
    func testExplicitSnoozesTakeCapacityBeforeRegionsAndOrdinaryTimeAlerts() async throws {
        let group = try group(20), queue = AdmissionQueue(), events = times(41, offset: 3600)
        let (scheduler, _) = scheduler(queue, journal: journal(group.candidates))
        _ = await scheduler.update(.init(revision: 1, account: account, events: events, now: now, locationPlan: group.plan))
        for event in events {
            let report = await scheduler.snooze(account: account, taskID: event.taskID, specID: event.specID, signature: event.signature, minutes: 5, now: now)
            XCTAssertEqual(report?.snoozeOutcome, .scheduled)
        }
        let pending = await queue.snapshot(); XCTAssertEqual(pending.maximum, 60); XCTAssertEqual(pending.times.filter(\.snoozed).count, 41); XCTAssertEqual(pending.regions.count, 19)
    }
    func testSupersededSnoozeDoesNotAcknowledgeNewerSnoozeWithSameIdentifier() async throws {
        let group = try group(1), queue = AdmissionQueue(), events = times(1, offset: 3600); await queue.holdRegion()
        let (scheduler, _) = scheduler(queue, journal: journal(group.candidates))
        let start = Task { await scheduler.update(.init(revision: 1, account: account, events: events, now: now, locationPlan: group.plan)) }
        await queue.waitForRegion(); let revision = await scheduler.intentRevision()
        let first = Task { await scheduler.snooze(account: account, taskID: events[0].taskID, specID: events[0].specID, signature: events[0].signature, minutes: 5, now: now) }
        while await scheduler.intentRevision() < revision + 1 { await Task.yield() }
        let second = Task { await scheduler.snooze(account: account, taskID: events[0].taskID, specID: events[0].specID, signature: events[0].signature, minutes: 5, now: now.addingTimeInterval(1)) }
        while await scheduler.intentRevision() < revision + 2 { await Task.yield() }
        await queue.releaseRegion(); _ = await start.value; let obsolete = await first.value, current = await second.value
        XCTAssertEqual(obsolete?.snoozeOutcome, .obsolete); XCTAssertEqual(current?.snoozeOutcome, .scheduled)
        let pending = await queue.snapshot(); XCTAssertEqual(pending.times.filter(\.snoozed).count, 1)
    }
    func testForeignAndExistingRegionsReserveCapacityEvenWithoutLocationEngine() async throws {
        let group = try group(20), queue = AdmissionQueue(); await queue.seed(regions: group.candidates, foreign: 5)
        let scheduler = ReminderScheduler(center: queue)
        let report = await scheduler.update(.init(revision: 1, account: account, events: times(60) + [try focus()], now: now))
        let pending = await queue.snapshot()
        XCTAssertEqual(pending.maximum, 60); XCTAssertEqual(pending.regions.count, 20); XCTAssertEqual(pending.foreign, 5); XCTAssertEqual(pending.times.count, 35)
        XCTAssertEqual(report.otherPendingSlots, 25); XCTAssertTrue(report.focusScheduled); XCTAssertNil(report.locations)
    }
    func testMismatchedAccountPlanIsCleanedInsteadOfRetained() async throws {
        let group = try group(1), queue = AdmissionQueue(); await queue.seed(regions: group.candidates)
        let (scheduler, _) = scheduler(queue, journal: journal(group.candidates, installed: true))
        _ = await scheduler.update(.init(revision: 1, account: "joint-b", events: times(60), now: now, locationPlan: group.plan))
        let pending = await queue.snapshot(); XCTAssertEqual(pending.maximum, 60); XCTAssertEqual(pending.times.count, 60); XCTAssertTrue(pending.regions.isEmpty)
    }
}
