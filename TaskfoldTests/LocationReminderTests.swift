import XCTest
@testable import TaskfoldCore

private actor LocationJournalStore {
    var value: LocationReminderJournal
    var writes = 0
    var failWrites: Set<Int> = []
    var heldWrite: Int?
    var writeStarted = false
    var writeGate: CheckedContinuation<Void, Never>?
    var writeWaiters: [CheckedContinuation<Void, Never>] = []
    init(_ value: LocationReminderJournal) { self.value = value }
    func fail(_ numbers: Set<Int>) { failWrites = numbers }
    func hold(write: Int) { heldWrite = write }
    func waitForWrite() async {
        if writeStarted { return }
        await withCheckedContinuation { writeWaiters.append($0) }
    }
    func releaseWrite() { heldWrite = nil; writeGate?.resume(); writeGate = nil }
    func save(_ next: LocationReminderJournal) async throws {
        writes += 1
        if heldWrite == writes {
            writeStarted = true; let callbacks = writeWaiters; writeWaiters = []; callbacks.forEach { $0.resume() }
            await withCheckedContinuation { writeGate = $0 }
        }
        if failWrites.contains(writes) { throw AppFailure(message: "Synthetic persistence refusal") }
        value = try JSONDecoder().decode(LocationReminderJournal.self, from: JSONEncoder().encode(next))
    }
    func state() -> LocationReminderJournal { value }
}
private actor LocationCenterFixture: LocationReminderCenter {
    var observation = LocationReminderObservation(pending: [])
    var additions: [LocationReminderCandidate] = []
    var observationCalls = 0
    var removed: [String] = []
    var failAdd = false
    var failObserve = false
    var blockAdd = false
    var started = false
    var addGate: CheckedContinuation<Void, Never>?
    var startWaiters: [CheckedContinuation<Void, Never>] = []
    let storage: LocationJournalStore?
    var reservationAtAdd: LocationReminderJournal.Phase?
    init(storage: LocationJournalStore? = nil) { self.storage = storage }
    func set(_ observation: LocationReminderObservation) { self.observation = observation }
    func failing(add: Bool = false, observe: Bool = false) { failAdd = add; failObserve = observe }
    func holdAdd() { blockAdd = true }
    func waitForAdd() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func releaseAdd() { blockAdd = false; addGate?.resume(); addGate = nil }
    func observe() throws -> LocationReminderObservation {
        observationCalls += 1
        if failObserve { throw AppFailure(message: "Synthetic OS query refusal") }
        return observation
    }
    func remove(_ ids: [String]) {
        removed += ids; observation.pending.removeAll { ids.contains($0.ticket.identifier) }
        observation.unrecognized.subtract(ids)
    }
    func removeAllOwned() {
        removed += observation.pending.map { $0.ticket.identifier }
        removed += observation.unrecognized.filter { $0.hasPrefix("taskfold.location.") }
        observation.pending = []; observation.unrecognized = observation.unrecognized.filter { !$0.hasPrefix("taskfold.location.") }
    }
    func add(_ candidate: LocationReminderCandidate) async throws {
        reservationAtAdd = await storage?.state().entries[candidate.ticket.identifier]?.phase
        started = true; let callbacks = startWaiters; startWaiters = []; callbacks.forEach { $0.resume() }
        if blockAdd { await withCheckedContinuation { addGate = $0 } }
        if failAdd { throw AppFailure(message: "Synthetic OS add refusal") }
        additions.append(candidate); observation.pending.removeAll { $0.ticket.identifier == candidate.ticket.identifier }; observation.pending.append(candidate)
    }
    func counts() -> (Int, Int) { (additions.count, observation.pending.count) }
    func removals() -> [String] { removed }
    func queries() -> Int { observationCalls }
    func phaseAtAdd() -> LocationReminderJournal.Phase? { reservationAtAdd }
}

final class LocationReminderTests: XCTestCase {
    let device = "81000000-0000-4000-8000-000000000001"
    let account = "81000000-0000-4000-8000-000000000002"
    let taskID = "81000000-0000-4000-8000-000000000003"
    let generation = "81000000-0000-4000-8000-000000000004"
    func place(account: String? = nil) throws -> LocationPrivatePlace {
        try XCTUnwrap(.make(account: account ?? self.account, name: "Private workshop address", latitude: 55.676098, longitude: 12.568337, radius: 250))
    }
    func task() -> Record { Record(["id": .string(taskID), "task_generation": .string(generation), "completion_version": .number(0), "title": .string("Bring the prototype"), "priority": .number(2), "completed": .bool(false), "due_date": .string("2027-01-01"), "due_time": .string("09:00")]) }
    func settings(place: LocationPrivatePlace, transition: LocationReminderSettings.Transition = .arrive) throws -> LocationReminderSettings {
        try XCTUnwrap(.make(device: device, taskID: taskID, taskGeneration: generation, place: place, transition: transition))
    }
    func plan(task: Record, place: LocationPrivatePlace, slots: Int = 20, allowed: Bool = true) -> LocationReminderPlan {
        LocationReminderPlan(account: account, device: device, tasks: [task], places: [place], availableNotificationSlots: slots, allowed: allowed)
    }
    func setup() throws -> (LocationPrivatePlace, Record, LocationReminderPlan) {
        let p = try place(), s = try settings(place: p); var t = task(); t["reminder_specs"] = .array([.object(s.raw)]); return (p, t, plan(task: t, place: p))
    }
    func journal(_ plan: LocationReminderPlan, phase: LocationReminderJournal.Phase = .prepared) throws -> LocationReminderJournal {
        var journal = LocationReminderJournal(device: device)
        for candidate in plan.eligible {
            XCTAssertTrue(journal.prepare(candidate.ticket))
            journal.entries[candidate.ticket.identifier]?.phase = phase
        }
        XCTAssertTrue(journal.valid); return journal
    }
    private func engine(_ journal: LocationReminderJournal, store: LocationJournalStore, center: LocationCenterFixture) -> LocationReminderEngine {
        LocationReminderEngine(journal: journal, center: center, persist: { try await store.save($0) })
    }
    func testPrivatePlaceValidationQuantizationAndBoundaryRevision() throws {
        let p = try place(); XCTAssertEqual(p.latitudeE6, 55_676_098); XCTAssertEqual(p.longitudeE6, 12_568_337)
        let renamed = try XCTUnwrap(p.editing(name: "Workshop", latitude: 55.676098, longitude: 12.568337, radius: 250))
        XCTAssertEqual(renamed.revision, p.revision); XCTAssertEqual(renamed.id, p.id)
        let moved = try XCTUnwrap(p.editing(name: "Workshop", latitude: 55.7, longitude: 12.568337, radius: 250))
        XCTAssertNotEqual(moved.revision, p.revision); XCTAssertEqual(moved.id, p.id)
        for (latitude, longitude, radius) in [(Double.nan, 0.0, 250), (0, .infinity, 250), (90.1, 0, 250), (0, -180.1, 250), (0, 0, 99), (0, 0, 5001)] {
            XCTAssertNil(LocationPrivatePlace.make(account: account, name: "Place", latitude: latitude, longitude: longitude, radius: radius))
        }
        var raw = p.raw; raw["radius_m"] = .number(250.5); XCTAssertNil(LocationPrivatePlace(raw: raw))
        raw = p.raw; raw["latitude_e6"] = .number(1.1); XCTAssertNil(LocationPrivatePlace(raw: raw))
        raw = p.raw; raw["name"] = .string("line\nbreak"); XCTAssertNil(LocationPrivatePlace(raw: raw))
    }
    func testSharedSettingsAndNotificationReceiptsContainNoPlaceGeometryOrLabel() throws {
        let (p, t, plan) = try setup(), candidate = try XCTUnwrap(plan.candidates.first)
        let bytes = try JSONEncoder().encode(t), receipt = try XCTUnwrap(candidate.receipt)
        for data in [bytes, receipt] {
            let text = String(decoding: data, as: UTF8.self)
            for value in [p.name, "latitude", "longitude", "radius_m", "55676098", "12568337"] { XCTAssertFalse(text.contains(value), value) }
        }
        XCTAssertEqual(candidate.title, t.title)
        XCTAssertEqual(try JSONDecoder().decode(LocationReminderTicket.self, from: receipt), candidate.ticket)
    }
    func testStrictOneShotEnvelopeAndOpaqueNativeReaderPreservation() throws {
        let p = try place(), s = try settings(place: p)
        for (field, value): (String, JSON) in [("version", .number(7)), ("kind", .string("relative")), ("enabled", .number(1)), ("channels", .array([.string("push")])), ("id", .string(ReminderSpec.plannedID))] {
            var raw = s.raw; raw[field] = value; XCTAssertNil(LocationReminderSettings(raw: raw))
        }
        for (field, value): (String, JSON) in [("device", .string("bad")), ("version", .number(2)), ("transition", .string("both")), ("repeats", .bool(true)), ("arm", .null)] {
            var raw = s.raw, reference = s.reference; reference[field] = value; raw["location_reference"] = .object(reference); XCTAssertNil(LocationReminderSettings(raw: raw))
        }
        XCTAssertNil(ReminderSpec(row: .object(s.raw))) // Not exposed or time-scheduled by this foundation.
        var t = task(); t["reminder_specs"] = .array([.object(s.raw)]); XCTAssertTrue(DueReminder.events(tasks: [t]).isEmpty)
        XCTAssertTrue(ReminderSpec.setPlanned(false, task: &t)); t["title"] = .string("Edited title")
        XCTAssertEqual(ReminderSpec.rows(t).first, .object(s.raw)); XCTAssertTrue(DueReminder.events(tasks: [t]).isEmpty)
        let restored = try JSONDecoder().decode(Record.self, from: JSONEncoder().encode(t)); XCTAssertEqual(ReminderSpec.rows(restored).first, .object(s.raw))
    }
    func testSettingTogglePreservesUnknownFutureFieldsAndDuplicateIgnoresArm() throws {
        let p = try place(), first = try settings(place: p), second = try settings(place: p)
        XCTAssertNotEqual(first.arm, second.arm); XCTAssertEqual(first.duplicateKey, second.duplicateKey)
        var raw = first.raw, reference = first.reference; raw["future"] = .string("keep"); reference["future_precision"] = .object(["keep": .bool(true)]); raw["location_reference"] = .object(reference)
        let changed = try XCTUnwrap(LocationReminderSettings(raw: raw)).settingEnabled(false)
        XCTAssertEqual(changed.reference, reference); XCTAssertEqual(changed.raw["future"], .string("keep"))
        XCTAssertFalse(changed.enabled)
    }
    func testPlanRejectsWrongAccountDeviceRevisionCompletionAndClonedTask() throws {
        let (p, t, plan) = try setup(); XCTAssertEqual(plan.candidates.count, 1)
        for (field, value): (String, JSON) in [("completed", .bool(true)), ("task_generation", .string(UUID().uuidString.lowercased())), ("id", .string(UUID().uuidString.lowercased())), ("completion_version", .number(-1)), ("completion_version", .string("1"))] {
            var edited = t; edited[field] = value; XCTAssertTrue(self.plan(task: edited, place: p).candidates.isEmpty, field)
        }
        let moved = try XCTUnwrap(p.editing(name: p.name, latitude: 56, longitude: 13, radius: 250))
        XCTAssertTrue(self.plan(task: t, place: moved).candidates.isEmpty)
        XCTAssertTrue(LocationReminderPlan(account: "another", device: device, tasks: [t], places: [p], availableNotificationSlots: 20, allowed: true).candidates.isEmpty)
        XCTAssertTrue(LocationReminderPlan(account: account, device: UUID().uuidString.lowercased(), tasks: [t], places: [p], availableNotificationSlots: 20, allowed: true).candidates.isEmpty)
        XCTAssertTrue(self.plan(task: t, place: p, allowed: false).candidates.isEmpty)
        var repeating = t; repeating["is_recurring"] = .bool(true)
        repeating["recurrence_pattern"] = .object(["type": .string("daily"), "interval": .number(1), "count": .number(3)])
        let changes = TaskCompletion.complete(repeating, tasks: [repeating], at: ISO8601DateFormatter().date(from: "2027-01-01T12:00:00Z")!)
        let successor = Record(try XCTUnwrap(changes.first { $0.method == "POST" }).fields)
        XCTAssertEqual(ReminderSpec.rows(successor), ReminderSpec.rows(t))
        XCTAssertTrue(self.plan(task: successor, place: p).candidates.isEmpty)
    }
    func testPlanDeduplicatesFailsAmbiguousRowsAndUsesCombinedCapacity() throws {
        let p = try place(), a = try settings(place: p), b = try settings(place: p), leave = try settings(place: p, transition: .leave)
        var t = task(); t["reminder_specs"] = .array([.object(a.raw), .object(b.raw), .object(leave.raw)])
        let plan = self.plan(task: t, place: p, slots: 1); XCTAssertEqual(plan.candidates.count, 1); XCTAssertEqual(plan.deferred, 1); XCTAssertEqual(plan.eligible.count, 2)
        XCTAssertTrue(self.plan(task: t, place: p, slots: -1).candidates.isEmpty)
        t["reminder_specs"] = .array([.object(a.raw), .object(a.raw)]); XCTAssertTrue(self.plan(task: t, place: p).candidates.isEmpty)
        t["reminder_specs"] = .array([.object(a.raw)])
        XCTAssertTrue(LocationReminderPlan(account: account, device: device, tasks: [t,t], places: [p], availableNotificationSlots: 20, allowed: true).candidates.isEmpty)
        XCTAssertTrue(LocationReminderPlan(account: account, device: device, tasks: [t], places: [p,p], availableNotificationSlots: 20, allowed: true).candidates.isEmpty)
        let sameBoundary = try XCTUnwrap(LocationPrivatePlace.make(account: account, name: "A second name for the same place", latitude: 55.676098, longitude: 12.568337, radius: 250))
        let other = try settings(place: sameBoundary)
        t["reminder_specs"] = .array([.object(a.raw), .object(other.raw)])
        XCTAssertEqual(LocationReminderPlan(account: account, device: device, tasks: [t], places: [p,sameBoundary], availableNotificationSlots: 20, allowed: true).eligible.count, 1)
        var alpha = t; alpha["id"] = .string("abcdefab-1234-4abc-8abc-abcdefabcdef")
        let alphaSetting = try XCTUnwrap(LocationReminderSettings.make(device: device, taskID: alpha.id, taskGeneration: generation, place: p, transition: .arrive, id: "fedcbaab-1234-4abc-8abc-abcdefabcdef"))
        alpha["reminder_specs"] = .array([.object(alphaSetting.raw)])
        var upper = alpha; upper["id"] = .string(alpha.id.uppercased())
        XCTAssertTrue(LocationReminderPlan(account: account, device: device, tasks: [alpha,upper], places: [p], availableNotificationSlots: 20, allowed: true).eligible.isEmpty)
        var upperSetting = alphaSetting.raw; upperSetting["id"] = .string(alphaSetting.id.uppercased())
        alpha["reminder_specs"] = .array([.object(alphaSetting.raw), .object(upperSetting)])
        XCTAssertTrue(LocationReminderPlan(account: account, device: device, tasks: [alpha], places: [p], availableNotificationSlots: 20, allowed: true).eligible.isEmpty)
    }
    func testJournalRequiresExplicitFreshIntentAndRejectsMalformedStates() throws {
        let (_, _, plan) = try setup(), ticket = try XCTUnwrap(plan.candidates.first).ticket
        var journal = LocationReminderJournal(device: device); XCTAssertFalse(journal.permitsResponse(ticket, eligible: plan.eligible))
        XCTAssertTrue(journal.prepare(ticket)); XCTAssertFalse(journal.prepare(ticket)); XCTAssertTrue(journal.valid)
        XCTAssertFalse(journal.permitsResponse(ticket, eligible: plan.eligible)) // Never submitted.
        journal.entries[ticket.identifier]?.phase = .installed; XCTAssertTrue(journal.permitsResponse(ticket, eligible: plan.eligible))
        journal.entries[ticket.identifier]?.phase = .closed; XCTAssertFalse(journal.valid)
        journal.entries[ticket.identifier]?.reason = .cancelled; XCTAssertTrue(journal.valid); XCTAssertFalse(journal.permitsResponse(ticket, eligible: plan.eligible))
        journal.entries[ticket.identifier]?.reason = .delivered; XCTAssertTrue(journal.permitsResponse(ticket, eligible: plan.eligible))
        XCTAssertFalse(journal.permitsResponse(ticket, eligible: []))
        XCTAssertEqual(try JSONDecoder().decode(LocationReminderJournal.self, from: JSONEncoder().encode(journal)), journal)
        journal.version = 2; XCTAssertFalse(journal.valid)
    }
    func testExplicitPreparationIsDurableDoesNotTouchOSBeforeHydrationAndCannotRepeatNonce() async throws {
        let (_, _, plan) = try setup(), initial = LocationReminderJournal(device: device), storage = LocationJournalStore(initial), center = LocationCenterFixture(storage: storage)
        let engine = self.engine(initial, store: storage, center: center), ticket = plan.candidates[0].ticket
        let prepared = await engine.prepare(ticket); XCTAssertTrue(prepared)
        let snapshot = await storage.state(); XCTAssertEqual(snapshot.entries[ticket.identifier]?.phase, .prepared)
        let before = await center.counts(); XCTAssertEqual(before.0, 0)
        let queries = await center.queries(); XCTAssertEqual(queries, 0)
        let repeated = await engine.prepare(ticket); XCTAssertFalse(repeated)
        let armed = await engine.update(plan); XCTAssertEqual(armed.installed, 1)
        let after = await center.counts(); XCTAssertEqual(after.0, 1)
    }
    func testReservationIsDurableBeforeOSAddAndExistingRequestIsNeverResubmitted() async throws {
        let (_, _, plan) = try setup(), initial = try journal(plan), storage = LocationJournalStore(initial), center = LocationCenterFixture(storage: storage)
        let engine = self.engine(initial, store: storage, center: center)
        let first = await engine.update(plan); XCTAssertEqual(first.installed, 1)
        let phase = await center.phaseAtAdd(); XCTAssertEqual(phase, .reserved)
        _ = await engine.update(plan); let counts = await center.counts(); XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
        let saved = await storage.state(); XCTAssertEqual(saved.entries.values.first?.phase, .installed)
    }
    func testSyncedOrRestoredRowWithoutPreparedIntentCannotArm() async throws {
        let (_, _, plan) = try setup(), initial = LocationReminderJournal(device: device), storage = LocationJournalStore(initial), center = LocationCenterFixture()
        let engine = self.engine(initial, store: storage, center: center)
        let report = await engine.update(plan); XCTAssertEqual(report.failed, 1)
        let counts = await center.counts(); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
    }
    func testStorageFailureBeforeSubmissionCannotArmThenSafeFirstAttemptCanRecover() async throws {
        let (_, _, plan) = try setup(), initial = try journal(plan), storage = LocationJournalStore(initial), center = LocationCenterFixture(storage: storage)
        await storage.fail([1]); let engine = self.engine(initial, store: storage, center: center)
        let failed = await engine.update(plan); XCTAssertEqual(failed.failed, 1)
        let counts = await center.counts(); XCTAssertEqual(counts.0, 0)
        await storage.fail([]); let recovered = await engine.update(plan); XCTAssertEqual(recovered.installed, 1)
        let phase = await center.phaseAtAdd(); XCTAssertEqual(phase, .reserved)
    }
    func testPostAddWriteFailureRecoversExistingOSRequestWithoutAnotherSubmission() async throws {
        let (_, _, plan) = try setup(), initial = try journal(plan), storage = LocationJournalStore(initial), center = LocationCenterFixture(storage: storage)
        await storage.fail([2]); let engine = self.engine(initial, store: storage, center: center)
        _ = await engine.update(plan)
        let reserved = await storage.state(); XCTAssertEqual(reserved.entries.values.first?.phase, .reserved)
        let restarted = self.engine(reserved, store: storage, center: center)
        _ = await restarted.update(plan); let counts = await center.counts(); XCTAssertEqual(counts.0, 1)
        let saved = await storage.state(); XCTAssertEqual(saved.entries.values.first?.phase, .installed)
    }
    func testMissingSubmittedRequestIsConsumedEvenWhenNotificationWasDismissed() async throws {
        let (_, _, plan) = try setup(), initial = try journal(plan, phase: .installed), storage = LocationJournalStore(initial), center = LocationCenterFixture()
        let engine = self.engine(initial, store: storage, center: center)
        _ = await engine.update(plan); _ = await engine.update(plan)
        let counts = await center.counts(); XCTAssertEqual(counts.0, 0)
        let state = await engine.snapshot(); XCTAssertEqual(state?.entries.values.first?.reason, .noLongerPending)
    }
    func testCrashAmbiguityDoesNotRearmAndGenuineResponseStillBindsCurrentTask() async throws {
        let (_, _, plan) = try setup(), initial = try journal(plan, phase: .reserved), storage = LocationJournalStore(initial), center = LocationCenterFixture()
        let engine = self.engine(initial, store: storage, center: center)
        _ = await engine.update(plan); let counts = await center.counts(); XCTAssertEqual(counts.0, 0)
        let captured = await engine.snapshot(); let state = try XCTUnwrap(captured); XCTAssertEqual(state.entries.values.first?.reason, .ambiguous)
        let ticket = try XCTUnwrap(plan.candidates.first).ticket
        XCTAssertTrue(state.permitsResponse(ticket, eligible: plan.eligible)); XCTAssertFalse(state.permitsResponse(ticket, eligible: []))
    }
    func testOSRefusalAndUntrackedRequestsDoNotBecomeAutomaticRetries() async throws {
        let (_, _, plan) = try setup(), initial = try journal(plan), storage = LocationJournalStore(initial), center = LocationCenterFixture()
        await center.failing(add: true); let engine = self.engine(initial, store: storage, center: center)
        _ = await engine.update(plan); await center.failing(); _ = await engine.update(plan)
        let counts = await center.counts(); XCTAssertEqual(counts.0, 0)
        let state = await engine.snapshot(); XCTAssertEqual(state?.entries.values.first?.reason, .failed)
        let otherStore = LocationJournalStore(initial), other = LocationCenterFixture()
        await other.set(.init(pending: plan.candidates))
        let untracked = self.engine(initial, store: otherStore, center: other); _ = await untracked.update(plan)
        let next = await untracked.snapshot(); XCTAssertEqual(next?.entries.values.first?.reason, .untracked)
        XCTAssertFalse(next?.permitsResponse(plan.candidates[0].ticket, eligible: plan.eligible) ?? true)
    }
    func testUnreadableJournalAndOSQueryFailureRemoveOnlyOwnedLocationRequests() async throws {
        let (_, _, plan) = try setup(), initial = try journal(plan), storage = LocationJournalStore(initial), center = LocationCenterFixture()
        await center.set(.init(pending: plan.candidates, unrecognized: ["taskfold.location.v9.unknown", "taskfold.reminder.keep"]))
        let unreadable = LocationReminderEngine(journal: nil, center: center, persist: { try await storage.save($0) })
        let report = await unreadable.update(plan); XCTAssertTrue(report.unreadable)
        let removed = await center.removals(); XCTAssertTrue(removed.contains("taskfold.location.v9.unknown")); XCTAssertFalse(removed.contains("taskfold.reminder.keep"))
        await center.failing(observe: true); let engine = self.engine(initial, store: storage, center: center)
        let query = await engine.update(plan); XCTAssertEqual(query.failed, 1)
        let counts = await center.counts(); XCTAssertEqual(counts.0, 0)
    }
    func testAccountSwitchDuringOSAddRemovesLateRegistrationAndRejectsItsResponse() async throws {
        let (p, t, plan) = try setup(), initial = try journal(plan), storage = LocationJournalStore(initial), center = LocationCenterFixture()
        await center.holdAdd(); let engine = self.engine(initial, store: storage, center: center)
        let first = Task { await engine.update(plan) }; await center.waitForAdd()
        let disabled = self.plan(task: t, place: p, allowed: false)
        let leaving = Task { await engine.update(disabled) }
        for _ in 0..<1000 {
            if await engine.intentRevision() >= 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let revision = await engine.intentRevision(); XCTAssertEqual(revision, 2)
        await center.releaseAdd(); _ = await first.value; _ = await leaving.value
        let counts = await center.counts(); XCTAssertEqual(counts.1, 0)
        let captured = await engine.snapshot(); let state = try XCTUnwrap(captured); XCTAssertFalse(state.permitsResponse(plan.candidates[0].ticket, eligible: plan.eligible))
        XCTAssertEqual(state.entries.values.first?.reason, .cancelled)
    }
    func testConsumedOneShotFreesCapacityForWaitingReminderWithoutRearmingItself() async throws {
        let p = try place(), a = try settings(place: p), b = try settings(place: p, transition: .leave)
        var t = task(); t["reminder_specs"] = .array([.object(a.raw), .object(b.raw)])
        let plan = self.plan(task: t, place: p, slots: 1), initial = try journal(plan), storage = LocationJournalStore(initial), center = LocationCenterFixture()
        let engine = self.engine(initial, store: storage, center: center); _ = await engine.update(plan)
        await center.set(.init(pending: [])); let next = await engine.update(plan)
        let counts = await center.counts(); XCTAssertEqual(counts.0, 2); XCTAssertEqual(counts.1, 1); XCTAssertEqual(next.installed, 1)
        _ = await engine.update(plan); let unchanged = await center.counts(); XCTAssertEqual(unchanged.0, 2)
    }

    func testApplicationRegionCapAndPriorityDoNotUseCurrentLocation() throws {
        let p = try place(); var tasks: [Record] = []
        for index in 0..<25 {
            var t = task(); t["id"] = .string(UUID().uuidString.lowercased()); t["task_generation"] = .string(UUID().uuidString.lowercased()); t["priority"] = .number(index == 24 ? 1 : 4)
            let s = try XCTUnwrap(LocationReminderSettings.make(device: device, taskID: t.id, taskGeneration: t.string("task_generation"), place: p, transition: .arrive))
            t["reminder_specs"] = .array([.object(s.raw)]); tasks.append(t)
        }
        let plan = LocationReminderPlan(account: account, device: device, tasks: tasks, places: [p], availableNotificationSlots: 60, allowed: true)
        XCTAssertEqual(plan.candidates.count, 20); XCTAssertEqual(plan.deferred, 5)
        XCTAssertEqual(plan.candidates.first?.ticket.taskID, tasks.last?.id)
    }
    func testAccountSwitchDuringDurableReservationCannotSubmitOldRequest() async throws {
        let (p, t, plan) = try setup(), initial = try journal(plan), storage = LocationJournalStore(initial), center = LocationCenterFixture()
        await storage.hold(write: 1); let engine = self.engine(initial, store: storage, center: center)
        let registering = Task { await engine.update(plan) }; await storage.waitForWrite()
        let disabled = self.plan(task: t, place: p, allowed: false)
        let leaving = Task { await engine.update(disabled) }
        for _ in 0..<1000 {
            if await engine.intentRevision() >= 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let revision = await engine.intentRevision(); XCTAssertEqual(revision, 2)
        await storage.releaseWrite(); _ = await registering.value; _ = await leaving.value
        let counts = await center.counts(); XCTAssertEqual(counts.0, 0)
        let state = await engine.snapshot(); XCTAssertEqual(state?.entries.values.first?.reason, .cancelled)
    }
    func testDeliveredObservationConsumesPendingRaceAndCompletionRevisionRejectsOldReceipt() async throws {
        let (p, t, plan) = try setup(), candidate = plan.candidates[0], initial = try journal(plan, phase: .installed), storage = LocationJournalStore(initial), center = LocationCenterFixture()
        await center.set(.init(pending: [candidate], delivered: [candidate.ticket.identifier]))
        let engine = self.engine(initial, store: storage, center: center); _ = await engine.update(plan)
        let captured = await engine.snapshot(), state = try XCTUnwrap(captured)
        XCTAssertEqual(state.entries[candidate.ticket.identifier]?.reason, .delivered)
        XCTAssertTrue(state.permitsResponse(candidate.ticket, eligible: plan.eligible))
        var restored = t; restored["completion_version"] = .number(2)
        let afterUndo = self.plan(task: restored, place: p)
        XCTAssertFalse(state.permitsResponse(candidate.ticket, eligible: afterUndo.eligible))
        _ = await engine.update(afterUndo)
        let counts = await center.counts(); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
    }
    func testMismatchedOSBoundaryIsCancelledWithoutSilentlyReplacingIt() async throws {
        let (p, t, plan) = try setup(), initial = try journal(plan, phase: .installed), storage = LocationJournalStore(initial), center = LocationCenterFixture()
        var fields = p.raw; fields["latitude_e6"] = .number(56_000_000)
        let altered = try XCTUnwrap(LocationPrivatePlace(raw: fields)), s = try XCTUnwrap(LocationReminderSettings(raw: ReminderSpec.rows(t)[0].object))
        let observed = try XCTUnwrap(LocationReminderCandidate(account: account, device: device, task: t, settings: s, place: altered))
        await center.set(.init(pending: [observed]))
        let engine = self.engine(initial, store: storage, center: center); _ = await engine.update(plan); _ = await engine.update(plan)
        let counts = await center.counts(); XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
        let state = await engine.snapshot(); XCTAssertEqual(state?.entries.values.first?.reason, .failed)
    }
    func testPreparedTaskDraftCanWaitForSaveWithoutBecomingAnOSRegistration() async throws {
        let (p, t, plan) = try setup(), initial = try journal(plan), storage = LocationJournalStore(initial), center = LocationCenterFixture()
        let engine = self.engine(initial, store: storage, center: center)
        _ = await engine.update(self.plan(task: t, place: p, allowed: false))
        let waiting = await engine.snapshot(); XCTAssertEqual(waiting?.entries.values.first?.phase, .prepared)
        let count = await center.counts(); XCTAssertEqual(count.0, 0)
        _ = await engine.update(plan)
        let saved = await center.counts(); XCTAssertEqual(saved.0, 1)
    }


    func testCleanupPassCanReleaseOldRegionsWithoutSubmittingPreparedIntents() async throws {
        let (p, t, plan) = try setup(), initial = try journal(plan), storage = LocationJournalStore(initial), center = LocationCenterFixture()
        let cleanup = LocationReminderPlan(account: account, device: device, tasks: [t], places: [p], availableNotificationSlots: 20, allowed: true, allowSubmissions: false)
        let engine = self.engine(initial, store: storage, center: center); _ = await engine.update(cleanup)
        let counts = await center.counts(); XCTAssertEqual(counts.0, 0)
        let prepared = await engine.snapshot(); XCTAssertEqual(prepared?.entries.values.first?.phase, .prepared)
        _ = await engine.update(plan); let armed = await center.counts(); XCTAssertEqual(armed.0, 1)
    }
    func testHistoryBoundRefusesNewIntentInsteadOfEvictingConsumedNonce() throws {
        let (_, _, plan) = try setup(), first = plan.candidates[0].ticket
        var journal = LocationReminderJournal(device: device)
        for _ in 0..<LocationReminderJournal.maximumEntries {
            let ticket = LocationReminderTicket(account: first.account, device: first.device, taskID: first.taskID, generation: first.generation, completionVersion: first.completionVersion, specID: first.specID, placeID: first.placeID, placeRevision: first.placeRevision, arm: UUID().uuidString.lowercased(), transition: first.transition)
            journal.entries[ticket.identifier] = .init(ticket: ticket, phase: .closed, reason: .delivered)
        }
        XCTAssertTrue(journal.valid); XCTAssertFalse(journal.prepare(first)); XCTAssertEqual(journal.entries.count, LocationReminderJournal.maximumEntries)
        var malformed = journal; malformed.entries["not-the-ticket-key"] = malformed.entries.values.first
        XCTAssertFalse(malformed.valid)
    }


    func testPortableBackupRetainsOpaqueReferenceButCannotMoveDeviceIntentToRestoredTask() throws {
        let fixture = BackupTests(); var snapshot = fixture.fixture(), row = snapshot.tables["tasks"]![0]
        let privatePlace = try place(account: fixture.owner); row["task_generation"] = .string(generation)
        let settings = try XCTUnwrap(LocationReminderSettings.make(device: device, taskID: row.id, taskGeneration: generation, place: privatePlace, transition: .arrive))
        row["reminder_specs"] = .array([.object(settings.raw)]); snapshot.tables["tasks"] = [row]
        snapshot.pending = [Mutation(table: "tasks", recordID: row.id, method: "PATCH", fields: ["reminder_specs": row["reminder_specs"]])]
        let saved = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(saved.pending[0].fields["reminder_specs"], row["reminder_specs"])
        let bytes = try WorkspaceBackup.make(saved, account: fixture.owner).data(), text = String(decoding: bytes, as: UTF8.self)
        for privateValue in [privatePlace.name, "latitude_e6", "longitude_e6", "radius_m"] { XCTAssertFalse(text.contains(privateValue)) }
        let imported = try WorkspaceBackup.read(bytes).plan(current: Snapshot(), account: fixture.other)
        let restored = Record(try XCTUnwrap(imported.changes.first { $0.table == "tasks" }).fields)
        XCTAssertEqual(restored["reminder_specs"], row["reminder_specs"])
        XCTAssertNotEqual(restored.id, row.id)
        let plan = LocationReminderPlan(account: fixture.other, device: device, tasks: [restored], places: [privatePlace], availableNotificationSlots: 20, allowed: true)
        XCTAssertTrue(plan.eligible.isEmpty)
    }

    func testExplicitRetirementClosesPreparedAndCannotReviveAfterRedo() async throws {
        let p = try place(), t = task(), setting = try settings(place: p)
        let candidate = try XCTUnwrap(LocationReminderCandidate(account: account, device: device, task: t, settings: setting, place: p))
        let disk = LocationJournalStore(.init(device: device)), center = LocationCenterFixture()
        let engine = LocationReminderEngine(journal: .init(device: device), center: center, persist: { try await disk.save($0) })
        let prepared = await engine.prepare(candidate.ticket); XCTAssertTrue(prepared)
        let retired = await engine.retire([candidate.ticket]); XCTAssertTrue(retired)
        var record = t; record["reminder_specs"] = .array([.object(setting.raw)])
        let plan = LocationReminderPlan(account: account, device: device, tasks: [record], places: [p], availableNotificationSlots: 60, allowed: true)
        _ = await engine.update(plan)
        let saved = await disk.state(), counts = await center.counts()
        XCTAssertEqual(saved.entries[candidate.ticket.identifier]?.reason, .cancelled); XCTAssertEqual(saved.revoked, [candidate.ticket.identifier]); XCTAssertEqual(counts.0, 0)
    }
    func testExplicitRetirementDuringNativeAddRemovesLateRegistration() async throws {
        let p = try place(), t = task(), setting = try settings(place: p)
        let candidate = try XCTUnwrap(LocationReminderCandidate(account: account, device: device, task: t, settings: setting, place: p))
        let disk = LocationJournalStore(.init(device: device)), center = LocationCenterFixture(); await center.holdAdd()
        let engine = LocationReminderEngine(journal: .init(device: device), center: center, persist: { try await disk.save($0) })
        _ = await engine.prepare(candidate.ticket)
        var record = t; record["reminder_specs"] = .array([.object(setting.raw)])
        let plan = LocationReminderPlan(account: account, device: device, tasks: [record], places: [p], availableNotificationSlots: 60, allowed: true)
        let running = Task { await engine.update(plan) }; await center.waitForAdd(); let revision = await engine.intentRevision()
        let retiring = Task { await engine.retire([candidate.ticket]) }
        while await engine.intentRevision() == revision { await Task.yield() }
        await center.releaseAdd(); _ = await running.value; let result = await retiring.value; XCTAssertTrue(result)
        let counts = await center.counts(), saved = await disk.state()
        XCTAssertEqual(counts.1, 0); XCTAssertEqual(saved.entries[candidate.ticket.identifier]?.reason, .cancelled); XCTAssertEqual(saved.revoked, [candidate.ticket.identifier])
    }
    func testRetirementRevokesDeliveredResponseWithoutRewritingClosedHistory() async throws {
        let p = try place(), t = task(), setting = try settings(place: p)
        let candidate = try XCTUnwrap(LocationReminderCandidate(account: account, device: device, task: t, settings: setting, place: p))
        var journal = LocationReminderJournal(device: device); _ = journal.prepare(candidate.ticket)
        journal.entries[candidate.ticket.identifier]?.phase = .closed; journal.entries[candidate.ticket.identifier]?.reason = .delivered
        XCTAssertTrue(journal.permitsResponse(candidate.ticket, eligible: [candidate]))
        let disk = LocationJournalStore(journal), center = LocationCenterFixture()
        let engine = LocationReminderEngine(journal: journal, center: center, persist: { try await disk.save($0) })
        let result = await engine.retire([candidate.ticket]); XCTAssertTrue(result)
        let saved = await disk.state()
        XCTAssertEqual(saved.entries, journal.entries); XCTAssertEqual(saved.version, 2); XCTAssertFalse(saved.permitsResponse(candidate.ticket, eligible: [candidate]))
        let restarted = try JSONDecoder().decode(LocationReminderJournal.self, from: JSONEncoder().encode(saved))
        XCTAssertTrue(restarted.valid); XCTAssertFalse(restarted.permitsResponse(candidate.ticket, eligible: [candidate]))
    }

    func testRetireBeforePreparationPersistsCancellationAndRefusesLatePrepare() async throws {
        let p = try place(), t = task(), setting = try settings(place: p)
        let candidate = try XCTUnwrap(LocationReminderCandidate(account: account, device: device, task: t, settings: setting, place: p))
        let disk = LocationJournalStore(.init(device: device)), center = LocationCenterFixture()
        let engine = LocationReminderEngine(journal: .init(device: device), center: center, persist: { try await disk.save($0) })
        let retired = await engine.retire([candidate.ticket]); XCTAssertTrue(retired)
        let late = await engine.prepare(candidate.ticket); XCTAssertFalse(late)
        let saved = await disk.state(); XCTAssertEqual(saved.entries[candidate.ticket.identifier]?.phase, .closed); XCTAssertEqual(saved.revoked, [candidate.ticket.identifier])
        let counts = await center.counts(); XCTAssertEqual(counts.0, 0)
    }

    func testFailedRetirementStaysSuppressedUntilDurableRetry() async throws {
        let p = try place(), t = task(), setting = try settings(place: p)
        let candidate = try XCTUnwrap(LocationReminderCandidate(account: account, device: device, task: t, settings: setting, place: p))
        var journal = LocationReminderJournal(device: device); _ = journal.prepare(candidate.ticket)
        let disk = LocationJournalStore(journal), center = LocationCenterFixture(); await disk.fail([1])
        let engine = LocationReminderEngine(journal: journal, center: center, persist: { try await disk.save($0) })
        let failed = await engine.retire([candidate.ticket]); XCTAssertFalse(failed)
        var record = t; record["reminder_specs"] = .array([.object(setting.raw)])
        let plan = LocationReminderPlan(account: account, device: device, tasks: [record], places: [p], availableNotificationSlots: 60, allowed: true)
        _ = await engine.update(plan)
        let counts = await center.counts(); XCTAssertEqual(counts.0, 0)
        let retry = await engine.retire([candidate.ticket]); XCTAssertTrue(retry)
        let saved = await disk.state(); XCTAssertEqual(saved.entries[candidate.ticket.identifier]?.reason, .cancelled)
    }

}
