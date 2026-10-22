import XCTest
import UserNotifications
@testable import TaskfoldCore

final class LocationRepeatTests: XCTestCase {
    let account = "repeat-local"
    func id(_ n: Int) -> String { "96000000-0000-4000-8000-" + String(format: "%012d", n) }
    func fixture(repeats: Bool) throws -> (Record, LocationPrivateArchive, LocationReminderCandidate) {
        let place = try XCTUnwrap(LocationPrivatePlace.make(account: account, name: "Private repeat pin", latitude: 55.676098, longitude: 12.568337, radius: 250, id: id(5), revision: id(6)))
        let settings = try XCTUnwrap(LocationReminderSettings.make(device: id(1), taskID: id(2), taskGeneration: id(3), place: place, transition: .arrive, repeats: repeats, id: id(4), arm: id(7)))
        var task = Record.task(user: account); task["id"] = .string(id(2)); task["task_generation"] = .string(id(3)); task["title"] = .string("Repeat proof"); task["reminder_specs"] = .array([.object(settings.raw)])
        let candidate = try XCTUnwrap(LocationReminderCandidate(account: account, device: id(1), task: task, settings: settings, place: place))
        var archive = LocationPrivateArchive(device: id(1)); archive.version = 2; archive.allowedAccounts = [account]; archive.places = [place.raw]
        return (task, archive, candidate)
    }
    func plan(_ task: Record, _ archive: LocationPrivateArchive) -> LocationReminderPlan { .init(account: account, device: archive.device, tasks: [task], places: archive.places(for: account), availableNotificationSlots: 20, allowed: true) }
    func testOneShotSignatureAndReceiptEnvelopeRemainUnchanged() throws {
        let (_, _, candidate) = try fixture(repeats: false)
        XCTAssertEqual(candidate.ticket.signature, "r9:986872f5216ec01ba32846f44e08456d865182b19aa4dddc2d1521015f5bb588")
        XCTAssertEqual(candidate.ticket.identifier, LocationReminderTicket.prefix + "986872f5216ec01ba32846f44e08456d865182b19aa4dddc2d1521015f5bb588")
        let raw = try JSONDecoder().decode(JSON.self, from: XCTUnwrap(candidate.receipt)).object
        XCTAssertNil(raw["repeats"]); XCTAssertEqual(raw.count, 10)
        XCTAssertFalse(candidate.ticket.isRepeating)
    }
    func testRepeatHasDistinctStrictEnvelopeAndNoTimeFallback() throws {
        let (task, archive, candidate) = try fixture(repeats: true)
        let settings = try XCTUnwrap(LocationReminderSettings(raw: ReminderSpec.rows(task)[0].object))
        XCTAssertEqual(settings.raw["version"], .number(7)); XCTAssertEqual(settings.reference["version"], .number(2)); XCTAssertTrue(settings.repeats)
        XCTAssertTrue(candidate.ticket.signature.hasPrefix("r10:")); XCTAssertTrue(candidate.ticket.identifier.hasPrefix("taskfold.location.v2."))
        XCTAssertTrue(LocationReminderTicket.validSignature(candidate.ticket.signature)); XCTAssertFalse(LocationReminderTicket.validSignature("r10:x:" + String(repeating: "a", count: 64)))
        XCTAssertNotEqual(candidate.ticket.identifier, try fixture(repeats: false).2.ticket.identifier)
        XCTAssertTrue(DueReminder.events(tasks: [task]).isEmpty); XCTAssertNil(ReminderSpec(row: .object(settings.raw)))
        var wrong = settings.raw; wrong["version"] = .number(6); XCTAssertNil(LocationReminderSettings(raw: wrong))
        wrong = settings.raw; var reference = settings.reference; reference["repeats"] = .bool(false); wrong["location_reference"] = .object(reference); XCTAssertNil(LocationReminderSettings(raw: wrong))
        var bad = candidate.ticket; bad.repeats = false; XCTAssertFalse(bad.valid)
        XCTAssertEqual(plan(task, archive).eligible.count, 1)
    }
    func testRepeatedDeliveryKeepsExactlyOneInstalledRegistration() async throws {
        let (task, archive, candidate) = try fixture(repeats: true)
        let center = RepeatCenter(), disk = RepeatJournal(archive.journal)
        let engine = LocationReminderEngine(journal: archive.journal, center: center, persist: { try await disk.save($0) })
        let prepared = await engine.prepare(candidate.ticket); XCTAssertTrue(prepared)
        _ = await engine.update(plan(task, archive))
        for _ in 0..<3 {
            await center.deliver(candidate)
            let report = await engine.update(plan(task, archive)), state = await engine.snapshot(), count = await center.additions
            XCTAssertEqual(report.installed, 1); XCTAssertEqual(state?.entries[candidate.ticket.identifier]?.phase, .installed); XCTAssertEqual(count, 1)
        }
        let saved = await disk.value
        XCTAssertEqual(saved.entries.count, 1); XCTAssertEqual(saved.revoked, []); XCTAssertEqual(saved.entries[candidate.ticket.identifier]?.epoch, 0)
        let raw = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        for key in ["visited", "deliveredAt", "timestamp", "latitude", "longitude", "Private repeat pin"] { XCTAssertFalse(raw.contains(key)) }
    }
    func testOneShotStillClosesOnFirstDelivery() async throws {
        let (task, archive, candidate) = try fixture(repeats: false)
        let center = RepeatCenter(), disk = RepeatJournal(archive.journal)
        let engine = LocationReminderEngine(journal: archive.journal, center: center, persist: { try await disk.save($0) })
        _ = await engine.prepare(candidate.ticket); _ = await engine.update(plan(task, archive)); await center.deliver(candidate)
        _ = await engine.update(plan(task, archive))
        let state = await engine.snapshot(), remaining = await center.pendingCount()
        XCTAssertEqual(state?.entries[candidate.ticket.identifier]?.phase, .closed); XCTAssertEqual(state?.entries[candidate.ticket.identifier]?.reason, .delivered); XCTAssertEqual(remaining, 0)
    }
    func testRepeatRemovalAndCompletionRevokeWithoutUndoRearm() async throws {
        let (task, archive, candidate) = try fixture(repeats: true)
        let center = RepeatCenter(), disk = RepeatJournal(archive.journal)
        let engine = LocationReminderEngine(journal: archive.journal, center: center, persist: { try await disk.save($0) })
        _ = await engine.prepare(candidate.ticket); _ = await engine.update(plan(task, archive))
        var completed = task; completed["completed"] = .bool(true)
        let tickets = LocationReminderTicket.retired(account: account, before: task, after: completed)
        XCTAssertEqual(tickets, [candidate.ticket]); XCTAssertEqual(LocationReminderTicket.retired(account: account, before: task, after: nil), tickets)
        let retired = await engine.retire(tickets); XCTAssertTrue(retired)
        _ = await engine.update(plan(task, archive))
        let state = await engine.snapshot(), count = await center.additions, remaining = await center.pendingCount()
        XCTAssertEqual(state?.entries[candidate.ticket.identifier]?.phase, .closed); XCTAssertEqual(state?.revoked, [candidate.ticket.identifier]); XCTAssertEqual(count, 1); XCTAssertEqual(remaining, 0)
        XCTAssertFalse(state!.permitsResponse(candidate.ticket, eligible: [candidate]))
    }
    func testMissingRepeatRegistrationRestoresExplicitOngoingIntent() async throws {
        let (task, archive, candidate) = try fixture(repeats: true)
        let center = RepeatCenter(), disk = RepeatJournal(archive.journal)
        let engine = LocationReminderEngine(journal: archive.journal, center: center, persist: { try await disk.save($0) })
        _ = await engine.prepare(candidate.ticket); _ = await engine.update(plan(task, archive)); await center.losePending()
        _ = await engine.update(plan(task, archive)); _ = await engine.update(plan(task, archive))
        let state = await engine.snapshot(), count = await center.additions
        XCTAssertEqual(state?.entries[candidate.ticket.identifier]?.phase, .installed); XCTAssertEqual(state?.entries[candidate.ticket.identifier]?.epoch, 1); XCTAssertEqual(count, 2)
    }
    func testEachDeliveredVisitGetsOneOpaqueReplaySource() throws {
        let (task, initial, candidate) = try fixture(repeats: true)
        var archive = initial; archive.journal.version = 3; archive.journal.revoked = []; archive.journal.entries[candidate.ticket.identifier] = .init(ticket: candidate.ticket, phase: .installed)
        let time = Date(timeIntervalSince1970: 1_900_000_000)
        XCTAssertNil(LocationNotificationProof.received(candidate, deliveredAt: nil))
        XCTAssertNil(LocationNotificationProof.received(candidate, deliveredAt: Date(timeIntervalSince1970: .nan)))
        let first = try XCTUnwrap(LocationNotificationProof.received(candidate, deliveredAt: time)), replay = try XCTUnwrap(LocationNotificationProof.received(candidate, deliveredAt: time)), later = try XCTUnwrap(LocationNotificationProof.received(candidate, deliveredAt: time.addingTimeInterval(60)))
        XCTAssertEqual(first.source, replay.source); XCTAssertNotEqual(first.source, later.source)
        XCTAssertNotNil(first.candidate(account: account, tasks: [task], archive: archive, cancellations: [:], actions: [:]))
        XCTAssertNil(LocationNotificationProof.boundary(candidate).candidate(account: account, tasks: [task], archive: archive, cancellations: [:], actions: [:]))
        let receipt = LocationNotificationAction(source: first.source, ticket: candidate.ticket, action: .tomorrow, fireAt: nil, phase: .closed, end: .consumed)
        var before = Snapshot(tables: ["tasks": [task]]); before.locationActions = [receipt.source: receipt]
        XCTAssertThrowsError(try LocationRetirementOutbox.staging(previous: before, proposed: before, account: account, newResponse: receipt))
        let second = LocationNotificationAction(source: later.source, ticket: candidate.ticket, action: .tomorrow, fireAt: nil, phase: .closed, end: .consumed)
        var after = before; after.locationActions?[second.source] = second
        XCTAssertEqual(try LocationRetirementOutbox.staging(previous: before, proposed: after, account: account, newResponse: second).locationActions?.count, 2)
        let raw = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        XCTAssertFalse(raw.contains("1900000000")); XCTAssertFalse(raw.contains("deliveredAt"))
    }
    func testRepeatSnoozeUsesExplicitTimeQueueAndKeepsModeBinding() throws {
        let (_, _, candidate) = try fixture(repeats: true)
        let source = try XCTUnwrap(LocationNotificationProof.received(candidate, deliveredAt: Date(timeIntervalSince1970: 1_900_000_000))).source
        let receipt = LocationNotificationAction(source: source, ticket: candidate.ticket, action: .snooze, fireAt: 1_900_000_600, phase: .installed)
        let request = try XCTUnwrap(receipt.request(title: "Task"))
        let native = UNNotificationRequest(identifier: request.identifier, content: SystemReminderCenter.content(for: request), trigger: SystemReminderCenter.trigger(at: request.fireAt))
        XCTAssertTrue(try XCTUnwrap(SystemReminderCenter.decodeLocationSnooze(native)).matchesSnooze(request))
        let state = ReminderState(revision: 1, account: account, events: [], locationValidationEvents: [request.event])
        XCTAssertTrue(request.valid(state: state)); XCTAssertFalse(state.permitsOriginal(request.event)); XCTAssertTrue(candidate.ticket.isRepeating)
    }
    func testModeReviewPreservesExistingChoiceAndExplicitChangeGetsFreshArm() throws {
        let (task, archive, candidate) = try fixture(repeats: true)
        let settings = try XCTUnwrap(LocationReminderSettings(raw: ReminderSpec.rows(task)[0].object)), workspace = WorkspaceBinding(account: account, generation: UUID())
        let reviewed = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: task, archive: archive, place: candidate.place, transition: .arrive, replacing: settings))
        XCTAssertTrue(reviewed.settings.repeats); XCTAssertNotEqual(reviewed.settings.arm, settings.arm)
        let once = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: task, archive: archive, place: candidate.place, transition: .arrive, repeats: false, replacing: settings))
        XCTAssertFalse(once.settings.repeats); XCTAssertEqual(once.settings.raw["version"], .number(6))
        let changed = try XCTUnwrap(once.applying(to: task, archive: archive, workspace: workspace))
        XCTAssertEqual(LocationReminderTicket.retired(account: account, before: task, after: changed), [candidate.ticket])
    }
    func testPrivateRepeatArchiveRoundTripAndRevocationMonotonicity() async throws {
        let (_, initial, candidate) = try fixture(repeats: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: directory) }
        let file = LocationPrivateFile(applicationSupport: directory); try file.transaction { _ in (initial, ()) }
        let store = LocationPrivateStore(applicationSupport: directory)
        var prepared = initial.journal; XCTAssertTrue(prepared.prepare(candidate.ticket)); try await store.saveJournal(prepared)
        let decoded = try XCTUnwrap(file.read()); XCTAssertEqual(decoded.journal.entries[candidate.ticket.identifier]?.ticket, candidate.ticket)
        let center = RepeatCenter(), engine = LocationReminderEngine(journal: decoded.journal, center: center, persist: { try await store.saveJournal($0) })
        _ = await engine.retire([candidate.ticket]); let retired = try XCTUnwrap(file.read())
        XCTAssertTrue(retired.valid); XCTAssertEqual(retired.journal.revoked, [candidate.ticket.identifier])
        do { try await store.saveJournal(prepared); XCTFail("A repeat retirement was rewound") } catch {}
        XCTAssertEqual(try file.read(), retired)
    }
    func testCapacityPauseRetainsRepeatIntentAndResumesWhenSpaceReturns() async throws {
        let (task, archive, candidate) = try fixture(repeats: true), center = RepeatCenter(), disk = RepeatJournal(archive.journal)
        let engine = LocationReminderEngine(journal: archive.journal, center: center, persist: { try await disk.save($0) })
        _ = await engine.prepare(candidate.ticket); _ = await engine.update(plan(task, archive)); await center.deliver(candidate)
        let paused = plan(task, archive).limited(to: 0, submissions: false)
        _ = await engine.update(paused); _ = await engine.update(paused)
        let waiting = await engine.snapshot(), pending = await center.pendingCount()
        XCTAssertEqual(waiting?.entries[candidate.ticket.identifier]?.phase, .prepared); XCTAssertEqual(waiting?.entries[candidate.ticket.identifier]?.epoch, 1); XCTAssertEqual(pending, 0)
        XCTAssertTrue(waiting!.permitsResponse(candidate.ticket, eligible: [candidate]), "Previously submitted repeat receipts remain actionable during a temporary pause")
        _ = await engine.update(plan(task, archive))
        let resumed = await engine.snapshot(), additions = await center.additions
        XCTAssertEqual(resumed?.entries[candidate.ticket.identifier]?.phase, .installed); XCTAssertEqual(resumed?.entries[candidate.ticket.identifier]?.epoch, 1); XCTAssertEqual(additions, 2)
    }
    func testLeavingAfterPauseEndsIntentAndCannotRearmOnReturn() async throws {
        let (task, archive, candidate) = try fixture(repeats: true), center = RepeatCenter(), disk = RepeatJournal(archive.journal)
        let engine = LocationReminderEngine(journal: archive.journal, center: center, persist: { try await disk.save($0) })
        _ = await engine.prepare(candidate.ticket); _ = await engine.update(plan(task, archive))
        _ = await engine.update(plan(task, archive).limited(to: 0, submissions: false))
        _ = await engine.update(.empty); _ = await engine.update(plan(task, archive))
        let state = await engine.snapshot(), additions = await center.additions
        XCTAssertEqual(state?.entries[candidate.ticket.identifier]?.phase, .closed); XCTAssertEqual(state?.entries[candidate.ticket.identifier]?.reason, .cancelled); XCTAssertEqual(additions, 1)
        XCTAssertFalse(state!.permitsResponse(candidate.ticket, eligible: [candidate]))
    }
    func testTemporaryAddRefusalKeepsRepeatForALaterExplicitRefresh() async throws {
        let (task, archive, candidate) = try fixture(repeats: true), center = RepeatCenter(), disk = RepeatJournal(archive.journal)
        let engine = LocationReminderEngine(journal: archive.journal, center: center, persist: { try await disk.save($0) })
        await center.refuse(permanent: false)
        _ = await engine.prepare(candidate.ticket); let report = await engine.update(plan(task, archive))
        let waiting = await engine.snapshot(); XCTAssertEqual(report.failed, 1); XCTAssertEqual(waiting?.entries[candidate.ticket.identifier]?.phase, .prepared)
        _ = await engine.update(plan(task, archive)); let resumed = await engine.snapshot(), additions = await center.additions
        XCTAssertEqual(resumed?.entries[candidate.ticket.identifier]?.phase, .installed); XCTAssertEqual(additions, 2)
    }
    func testReviewRequiredRefusalDoesNotAutomaticallyRetryRepeat() async throws {
        let (task, archive, candidate) = try fixture(repeats: true), center = RepeatCenter(), disk = RepeatJournal(archive.journal)
        let engine = LocationReminderEngine(journal: archive.journal, center: center, persist: { try await disk.save($0) })
        await center.refuse(permanent: true)
        _ = await engine.prepare(candidate.ticket); _ = await engine.update(plan(task, archive)); _ = await engine.update(plan(task, archive))
        let state = await engine.snapshot(), additions = await center.additions
        XCTAssertEqual(state?.entries[candidate.ticket.identifier]?.phase, .closed); XCTAssertEqual(state?.entries[candidate.ticket.identifier]?.reason, .failed); XCTAssertEqual(additions, 1)
    }
    func testRepeatEpochCannotBeRewoundOrJumpedByStalePrivateWriter() async throws {
        let (_, initial, candidate) = try fixture(repeats: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: directory) }
        let file = LocationPrivateFile(applicationSupport: directory); try file.transaction { _ in (initial, ()) }
        let store = LocationPrivateStore(applicationSupport: directory)
        var state = initial.journal; XCTAssertTrue(state.prepare(candidate.ticket)); try await store.saveJournal(state)
        state.entries[candidate.ticket.identifier]?.phase = .installed; try await store.saveJournal(state); let stale = state
        state.entries[candidate.ticket.identifier] = .init(ticket: candidate.ticket, phase: .prepared, epoch: 1); try await store.saveJournal(state)
        do { try await store.saveJournal(stale); XCTFail("Stale installed state rewound repeat recovery") } catch {}
        var invalid = state; invalid.entries[candidate.ticket.identifier]?.epoch = 2
        do { try await store.saveJournal(invalid); XCTFail("An unsubmitted generation was skipped") } catch {}
        XCTAssertEqual(try file.read()?.journal, state)
        state.entries[candidate.ticket.identifier]?.phase = .closed; state.entries[candidate.ticket.identifier]?.reason = .cancelled; try await store.saveJournal(state)
        invalid = state; invalid.entries[candidate.ticket.identifier] = .init(ticket: candidate.ticket, phase: .prepared, epoch: 2)
        do { try await store.saveJournal(invalid); XCTFail("A closed repeat was reopened") } catch {}
        XCTAssertEqual(try file.read()?.journal, state)
    }

    func testCompatibilityPayloadIsValidForTheNewProducer() throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "repeating-location", withExtension: "json", subdirectory: "Fixtures"))
        let document = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: file)).object
        let task = try JSONDecoder().decode(Record.self, from: JSONEncoder().encode(document["task"]!)), archive = try LocationPrivateArchive.decode(JSONEncoder().encode(document["archive"]!))
        let candidate = try XCTUnwrap(plan(task, archive).eligible.first)
        XCTAssertTrue(candidate.ticket.isRepeating); XCTAssertEqual(archive.journal.version, 3); XCTAssertEqual(archive.journal.entries[candidate.ticket.identifier]?.ticket, candidate.ticket)
    }

}
private actor RepeatJournal {
    var value: LocationReminderJournal
    init(_ value: LocationReminderJournal) { self.value = value }
    func save(_ value: LocationReminderJournal) throws { guard value.valid else { throw LocationStorageFailure.unreadable }; self.value = value }
}
private actor RepeatCenter: LocationReminderCenter {
    var observation = LocationReminderObservation(pending: [])
    var additions = 0
    var refusal: Bool?
    func refuse(permanent: Bool) { refusal = permanent }
    func observe() async throws -> LocationReminderObservation { observation }
    func remove(_ ids: [String]) async { observation.pending.removeAll { ids.contains($0.ticket.identifier) } }
    func removeAllOwned() async { observation.pending = []; observation.delivered = [] }
    func add(_ candidate: LocationReminderCandidate) async throws {
        additions += 1
        if let permanent = refusal { refusal = nil; throw RepeatRefusal(requiresLocationReview: permanent) }
        observation.pending = [candidate]
    }
    func deliver(_ candidate: LocationReminderCandidate) { observation.delivered.insert(candidate.ticket.identifier) }
    func losePending() { observation.pending = [] }
    func pendingCount() -> Int { observation.pending.count }
}

private struct RepeatRefusal: LocationReminderReviewRequiredError { let requiresLocationReview: Bool }
