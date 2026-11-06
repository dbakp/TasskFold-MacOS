import XCTest
import UserNotifications
@testable import TaskfoldCore

final class LocationTaskDraftTests: XCTestCase {
    let account = "draft-local"
    let device = "95000000-0000-4000-8000-000000000001"
    func fixture() throws -> (Record, LocationPrivateArchive, LocationPrivatePlace, WorkspaceBinding) {
        var task = Record.task(user: account); task["title"] = .string("Bring the concept")
        let pin = try XCTUnwrap(LocationPrivatePlace.make(account: account, name: "Secret private pin", latitude: 55.676098, longitude: 12.568337, radius: 250))
        var archive = LocationPrivateArchive(device: device); archive.places = [pin.raw]
        return (task, archive, pin, .init(account: account, generation: UUID()))
    }
    func testReviewedProposalChangesOnlyDraftAndStoresNoPrivatePinInTask() throws {
        let (task, archive, pin, workspace) = try fixture()
        let review = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: task, archive: archive, place: pin, transition: .leave))
        let draft = try XCTUnwrap(review.applying(to: task, archive: archive, workspace: workspace))
        XCTAssertTrue(ReminderSpec.rows(task).isEmpty); XCTAssertTrue(archive.journal.entries.isEmpty)
        XCTAssertEqual(ReminderSpec.rows(draft).count, 2); XCTAssertTrue(ReminderSpec.plannedEnabled(draft)); XCTAssertTrue(review.permitsSaved(draft, archive: archive, workspace: workspace))
        XCTAssertNil(ReminderSpec(row: .object(review.settings.raw)))
        let data = String(decoding: try JSONEncoder().encode(draft), as: UTF8.self)
        for forbidden in [pin.name, "latitude", "longitude", "radius_m", "allowedAccounts", "journal"] { XCTAssertFalse(data.contains(forbidden), forbidden) }
    }
    func testWorkspaceTaskCompletionAndIdentityChangesRefuseReview() throws {
        let (task, archive, pin, workspace) = try fixture()
        let review = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: task, archive: archive, place: pin, transition: .arrive))
        XCTAssertNil(review.applying(to: task, archive: archive, workspace: .init(account: account, generation: UUID())))
        XCTAssertNil(review.applying(to: task, archive: archive, workspace: .init(account: "another", generation: workspace.generation)))
        for (key, value) in [("id", JSON.string(UUID().uuidString.lowercased())), ("task_generation", .string(UUID().uuidString.lowercased())), ("completed", .bool(true)), ("completion_version", .number(2))] {
            var changed = task; changed[key] = value
            XCTAssertNil(review.applying(to: changed, archive: archive, workspace: workspace), key)
        }
        var reset = LocationPrivateArchive(); reset.places = archive.places
        XCTAssertNil(review.applying(to: task, archive: reset, workspace: workspace))
    }
    func testMovingDeletingAndConcurrentReminderEditsRefuseButRenameKeepsBoundary() throws {
        let (task, archive, pin, workspace) = try fixture()
        let review = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: task, archive: archive, place: pin, transition: .arrive))
        var changed = archive; changed.places = []; XCTAssertNil(review.applying(to: task, archive: changed, workspace: workspace))
        changed.places = [try XCTUnwrap(pin.editing(name: pin.name, latitude: 55.7, longitude: 12.56, radius: 500)).raw]
        XCTAssertNil(review.applying(to: task, archive: changed, workspace: workspace))
        changed.places = [try XCTUnwrap(pin.editing(name: "Renamed", latitude: 55.676098, longitude: 12.568337, radius: 250)).raw]
        XCTAssertNotNil(review.applying(to: task, archive: changed, workspace: workspace))
        var edited = task; edited["reminder_specs"] = .array([.object(ReminderSpec.relative(-30).raw)])
        XCTAssertNil(review.applying(to: edited, archive: archive, workspace: workspace))
    }
    func testFreshReviewRotatesArmPreservesExtensionsAndSupportsBothExplicitDirections() throws {
        let (task, archive, pin, workspace) = try fixture()
        let first = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: task, archive: archive, place: pin, transition: .arrive))
        var fields = first.settings.raw; fields["future_label"] = .string("keep")
        var reference = first.settings.reference; reference["future_reference"] = .bool(true); fields["location_reference"] = .object(reference)
        let original = try XCTUnwrap(LocationReminderSettings(raw: fields))
        var saved = task; saved["reminder_specs"] = .array([.object(original.raw)])
        let review = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: saved, archive: archive, place: pin, transition: .leave, replacing: original))
        let updated = try XCTUnwrap(review.applying(to: saved, archive: archive, workspace: workspace))
        XCTAssertEqual(review.settings.id, original.id); XCTAssertNotEqual(review.settings.arm, original.arm); XCTAssertEqual(review.settings.transition, .leave)
        XCTAssertEqual(review.settings.raw["future_label"], .string("keep")); XCTAssertEqual(review.settings.reference["future_reference"], .bool(true))
        XCTAssertEqual(ReminderSpec.rows(updated).count, 1)
        XCTAssertFalse(first.permitsSaved(updated, archive: archive, workspace: workspace))
    }
    func testDuplicateBoundaryDifferentPinNamesRefusedAndOppositeDirectionIsExplicit() throws {
        let (task, archive, pin, workspace) = try fixture()
        let first = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: task, archive: archive, place: pin, transition: .arrive))
        let saved = try XCTUnwrap(first.applying(to: task, archive: archive, workspace: workspace))
        let duplicate = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: saved, archive: archive, place: pin, transition: .arrive))
        XCTAssertNil(duplicate.applying(to: saved, archive: archive, workspace: workspace))
        let other = try XCTUnwrap(LocationPrivatePlace.make(account: account, name: "Other pin name", latitude: 55.676098, longitude: 12.568337, radius: 250))
        var two = archive; two.places.append(other.raw)
        let sameBoundary = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: saved, archive: two, place: other, transition: .arrive))
        XCTAssertNil(sameBoundary.applying(to: saved, archive: two, workspace: workspace))
        let leave = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: saved, archive: archive, place: pin, transition: .leave))
        XCTAssertNotNil(leave.applying(to: saved, archive: archive, workspace: workspace))
    }
    func testOpaqueRowsSurviveAndFullCollectionCannotGrow() throws {
        let (task, archive, pin, workspace) = try fixture()
        var future = task; let opaque = JSON.object(["version": .number(99), "extension": .object(["keep": .bool(true)])]); future["reminder_specs"] = .array([opaque])
        let review = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: future, archive: archive, place: pin, transition: .arrive))
        XCTAssertEqual(review.applying(to: future, archive: archive, workspace: workspace)?["reminder_specs"].list.first, opaque)
        future["reminder_specs"] = .array((0..<20).map { .object(ReminderSpec.relative(-$0).raw) })
        let full = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: future, archive: archive, place: pin, transition: .arrive))
        XCTAssertNil(full.applying(to: future, archive: archive, workspace: workspace))
    }
    func testRetirementTracksRemovalDisableCompletionAndPreservesTitleAndPlanEdits() throws {
        let (task, archive, pin, workspace) = try fixture()
        let review = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: task, archive: archive, place: pin, transition: .arrive))
        let saved = try XCTUnwrap(review.applying(to: task, archive: archive, workspace: workspace))
        let ticket = try XCTUnwrap(LocationReminderTicket.bound(account: account, task: saved, settings: review.settings))
        XCTAssertEqual(LocationReminderTicket.retired(account: account, before: saved, after: task), [ticket])
        XCTAssertEqual(LocationReminderTicket.retired(account: account, before: saved, after: nil), [ticket])
        var renamed = saved; renamed["title"] = .string("Other title"); renamed["due_date"] = .string("2027-01-01")
        XCTAssertTrue(LocationReminderTicket.retired(account: account, before: saved, after: renamed).isEmpty)
        var disabled = saved; disabled["reminder_specs"] = .array([.object(review.settings.settingEnabled(false).raw)])
        XCTAssertEqual(LocationReminderTicket.retired(account: account, before: saved, after: disabled), [ticket])
        var completed = saved; completed["completed"] = .bool(true); completed["completion_version"] = .number(1)
        XCTAssertEqual(LocationReminderTicket.retired(account: account, before: saved, after: completed), [ticket])
    }
    func testMalformedRevocationCannotAuthorizeOrAdmitAnOpenIntent() throws {
        let (task, archive, pin, workspace) = try fixture()
        let review = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: task, archive: archive, place: pin, transition: .arrive))
        let ticket = try XCTUnwrap(LocationReminderTicket.bound(account: account, task: task, settings: review.settings))
        var journal = archive.journal; XCTAssertTrue(journal.prepare(ticket)); journal.version = 2; journal.revoked = [ticket.identifier]
        XCTAssertFalse(journal.valid)
        journal.entries[ticket.identifier]?.phase = .closed; journal.entries[ticket.identifier]?.reason = .cancelled
        XCTAssertTrue(journal.valid)
        journal.revoked = [ticket.identifier, ticket.identifier]; XCTAssertFalse(journal.valid)
        journal.revoked = ["taskfold.location.unknown"]; XCTAssertFalse(journal.valid)
    }

    func retirementFixture() throws -> (Snapshot, Record, LocationReminderTicket) {
        let (task, archive, pin, workspace) = try fixture()
        let review = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: task, archive: archive, place: pin, transition: .arrive))
        let saved = try XCTUnwrap(review.applying(to: task, archive: archive, workspace: workspace))
        return (Snapshot(tables: ["tasks": [saved]]), saved, try XCTUnwrap(LocationReminderTicket.bound(account: account, task: saved, settings: review.settings)))
    }
    func testCancellationIsInSameSnapshotAsRemovalAndSurvivesDecode() throws {
        let (before, _, ticket) = try retirementFixture()
        let next = try LocationRetirementOutbox.staging(previous: before, proposed: Snapshot(), account: account)
        let recovered = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(next))
        XCTAssertEqual(recovered.locationRetirements, [ticket.identifier: ticket]); XCTAssertNil(recovered.tables["tasks"])
        let text = String(decoding: try JSONEncoder().encode(recovered), as: UTF8.self)
        for key in ["Secret private pin", "latitude", "longitude", "radius"] { XCTAssertFalse(text.contains(key)) }
        XCTAssertFalse(String(decoding: try WorkspaceBackup.make(recovered, account: account).data(), as: UTF8.self).contains("locationRetirements"))
    }
    func testUndoAndLaterSnapshotReplacementCannotDropCancellation() throws {
        let (before, _, ticket) = try retirementFixture()
        let removed = try LocationRetirementOutbox.staging(previous: before, proposed: Snapshot(), account: account)
        let undone = try LocationRetirementOutbox.staging(previous: removed, proposed: before, account: account)
        XCTAssertEqual(undone.tables, before.tables); XCTAssertEqual(undone.locationRetirements?[ticket.identifier], ticket)
        let replaced = try LocationRetirementOutbox.staging(previous: undone, proposed: before, account: account)
        XCTAssertEqual(replaced.locationRetirements, undone.locationRetirements)
        let acked = try LocationRetirementOutbox.staging(previous: replaced, proposed: replaced, account: account, acknowledged: [ticket])
        XCTAssertNil(acked.locationRetirements)
        XCTAssertEqual(acked.tables, before.tables)
    }
    func testFailedTaskSaveLeavesPreviousIntentAndOutboxUnchanged() throws {
        let (before, _, ticket) = try retirementFixture()
        let proposed = try LocationRetirementOutbox.staging(previous: before, proposed: Snapshot(), account: account)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tasks.json"); try JSONEncoder().encode(before).write(to: file, options: .atomic)
        // Force failure before the atomic task/outbox replacement can take effect.
        XCTAssertThrowsError(try JSONEncoder().encode(proposed).write(to: directory.appendingPathComponent("missing/tasks.json"), options: .atomic))
        let recovered = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
        XCTAssertEqual(recovered, before); XCTAssertNil(recovered.locationRetirements)
        XCTAssertEqual(proposed.locationRetirements?[ticket.identifier], ticket)
    }
    func testCompletionWithoutVersionBumpStillRetiresWhileTitleEditDoesNot() throws {
        let (before, task, ticket) = try retirementFixture()
        var completed = task; completed["completed"] = .bool(true)
        let changed = try LocationRetirementOutbox.staging(previous: before, proposed: Snapshot(tables: ["tasks": [completed]]), account: account)
        XCTAssertEqual(changed.locationRetirements?[ticket.identifier], ticket)
        var renamed = task; renamed["title"] = .string("New title")
        XCTAssertNil(try LocationRetirementOutbox.staging(previous: before, proposed: Snapshot(tables: ["tasks": [renamed]]), account: account).locationRetirements)
    }
    func testInvalidOutboxFailsClosedAndLegacySnapshotsDecode() throws {
        let (before, _, ticket) = try retirementFixture()
        var bad = before; bad.locationRetirements = ["wrong": ticket]
        XCTAssertThrowsError(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(bad)))
        XCTAssertThrowsError(try LocationRetirementOutbox.staging(previous: bad, proposed: before, account: account))
        let legacy = try JSONDecoder().decode(Snapshot.self, from: Data(#"{"tables":{},"pending":[]}"#.utf8))
        XCTAssertNil(legacy.locationRetirements)
    }
    func testOutboxBoundRefusesOverflowWithoutDiscardingExistingJobs() throws {
        let (before, task, ticket) = try retirementFixture()
        var full = before; full.locationRetirements = [:]
        for _ in 0..<LocationReminderJournal.maximumEntries {
            let copy = LocationReminderTicket(account: account, device: device, taskID: task.id, generation: ticket.generation, completionVersion: 0,
                specID: UUID().uuidString.lowercased(), placeID: ticket.placeID, placeRevision: ticket.placeRevision, arm: UUID().uuidString.lowercased(), transition: "arrive")
            full.locationRetirements?[copy.identifier] = copy
        }
        XCTAssertThrowsError(try LocationRetirementOutbox.staging(previous: full, proposed: Snapshot(), account: account))
        XCTAssertEqual(full.locationRetirements?.count, LocationReminderJournal.maximumEntries)
        let releasing = try XCTUnwrap(full.locationRetirements?.values.first)
        XCTAssertEqual(try LocationRetirementOutbox.staging(previous: full, proposed: Snapshot(), account: account, acknowledged: [releasing]).locationRetirements?.count, LocationReminderJournal.maximumEntries)
    }
    func testCrashRecoveryReplaysPrivateRetirementBeforeAndAfterJournalSave() async throws {
        let (before, _, ticket) = try retirementFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = LocationPrivateFile(applicationSupport: directory)
        var archive = LocationPrivateArchive(device: device); XCTAssertTrue(archive.journal.prepare(ticket))
        try file.transaction { _ in (archive, ()) }
        let store = LocationPrivateStore(applicationSupport: directory)
        let removed = try LocationRetirementOutbox.staging(previous: before, proposed: Snapshot(), account: account)
        // Recovered raw task rows may already have been restored by Undo.
        let restored = try LocationRetirementOutbox.staging(previous: removed, proposed: before, account: account)
        let cache = directory.appendingPathComponent("cache.json"); try JSONEncoder().encode(restored).write(to: cache, options: .atomic)
        for _ in 0..<2 {
            // First restart: private write has not happened. Second: it happened,
            // but the process ended before acknowledging the snapshot outbox.
            let disk = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: cache))
            let privateState = try XCTUnwrap(file.read())
            let engine = LocationReminderEngine(journal: privateState.journal, center: LocationRetirementRecoveryCenter(), persist: { try await store.saveJournal($0) })
            let retired = await engine.retire(Array(disk.locationRetirements!.values)); XCTAssertTrue(retired)
            XCTAssertEqual(try file.read()?.journal.entries[ticket.identifier]?.phase, .closed)
            XCTAssertEqual(try file.read()?.journal.revoked, [ticket.identifier])
            let rearmed = await engine.prepare(ticket); XCTAssertFalse(rearmed)
        }
        let disk = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: cache))
        let acked = try LocationRetirementOutbox.staging(previous: disk, proposed: disk, account: account, acknowledged: [ticket])
        try JSONEncoder().encode(acked).write(to: cache, options: .atomic)
        XCTAssertNil(try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: cache)).locationRetirements)
        XCTAssertEqual(acked.tables, before.tables)
    }

    func notificationFixture() throws -> (Record, LocationPrivateArchive, LocationReminderCandidate) {
        let (task, initial, pin, workspace) = try fixture()
        let review = try XCTUnwrap(LocationReminderReview(workspace: workspace, task: task, archive: initial, place: pin, transition: .arrive))
        let saved = try XCTUnwrap(review.applying(to: task, archive: initial, workspace: workspace))
        let candidate = try XCTUnwrap(LocationReminderCandidate(account: account, device: device, task: saved, settings: review.settings, place: pin))
        var archive = initial; archive.version = 2; archive.allowedAccounts = [account]
        archive.journal.entries[candidate.ticket.identifier] = .init(ticket: candidate.ticket, phase: .closed, reason: .delivered)
        return (saved, archive, candidate)
    }
    func snoozeRecord(_ candidate: LocationReminderCandidate, phase: LocationNotificationAction.Phase = .queued, fire: Double = 1_900_000_000) -> LocationNotificationAction {
        .init(source: LocationNotificationProof.boundary(candidate).source, ticket: candidate.ticket, action: .snooze, fireAt: fire, phase: phase)
    }
    func testLocationResponseRequiresCurrentConsentJournalTaskPinAndNoCancellation() throws {
        let (task, archive, candidate) = try notificationFixture(); let proof = LocationNotificationProof.boundary(candidate)
        func valid(_ a: LocationPrivateArchive, task t: Record = task, account user: String? = nil, jobs: [String: LocationReminderTicket] = [:]) -> Bool { proof.candidate(account: user ?? account, tasks: [t], archive: a, cancellations: jobs, actions: [:]) != nil }
        XCTAssertTrue(valid(archive)); XCTAssertFalse(valid(archive, account: "other"))
        XCTAssertFalse(valid(archive, jobs: [candidate.ticket.identifier: candidate.ticket]))
        var changed = archive; changed.allowedAccounts = []; XCTAssertFalse(valid(changed))
        changed = archive; changed.journal.entries[candidate.ticket.identifier] = .init(ticket: candidate.ticket, phase: .prepared); XCTAssertFalse(valid(changed))
        changed = archive; changed.journal.version = 2; changed.journal.revoked = [candidate.ticket.identifier]; XCTAssertFalse(valid(changed))
        changed = archive; changed.places = []; XCTAssertFalse(valid(changed))
        var completed = task; completed["completed"] = .bool(true); XCTAssertFalse(valid(archive, task: completed))
        var regenerated = task; regenerated["task_generation"] = .string(UUID().uuidString.lowercased()); XCTAssertFalse(valid(archive, task: regenerated))
        let moved = try XCTUnwrap(LocationPrivatePlace.make(account: account, name: "Elsewhere", latitude: 56, longitude: 12, radius: candidate.place.radius, id: candidate.place.id, revision: candidate.place.revision))
        let settings = try XCTUnwrap(ReminderSpec.rows(task).compactMap { LocationReminderSettings(raw: $0.object) }.first)
        let forged = try XCTUnwrap(LocationReminderCandidate(account: account, device: device, task: task, settings: settings, place: moved))
        XCTAssertNil(LocationNotificationProof.boundary(forged).candidate(account: account, tasks: [task], archive: archive, cancellations: [:], actions: [:]))
    }
    func testSnoozeProofNeedsDurableReservationAndExactFireTime() throws {
        let (task, archive, candidate) = try notificationFixture(); let record = snoozeRecord(candidate, phase: .installed)
        let request = try XCTUnwrap(record.request(title: "Task")); let proof = LocationNotificationProof.snooze(request)
        XCTAssertNotNil(proof.candidate(account: account, tasks: [task], archive: archive, cancellations: [:], actions: [record.source: record]))
        XCTAssertNil(proof.candidate(account: account, tasks: [task], archive: archive, cancellations: [:], actions: [:]))
        var queued = record; queued.phase = .queued
        XCTAssertNil(proof.candidate(account: account, tasks: [task], archive: archive, cancellations: [:], actions: [record.source: queued]))
        var retimed = request; retimed.fireAt.addTimeInterval(1)
        XCTAssertNil(LocationNotificationProof.snooze(retimed).candidate(account: account, tasks: [task], archive: archive, cancellations: [:], actions: [record.source: record]))
        let consumed = record.advancing(.closed, end: .consumed)
        XCTAssertNotNil(proof.candidate(account: account, tasks: [task], archive: archive, cancellations: [:], actions: [record.source: consumed]))
        let failed = record.advancing(.closed, end: .failed)
        XCTAssertNil(proof.candidate(account: account, tasks: [task], archive: archive, cancellations: [:], actions: [record.source: failed]))
    }
    func testLedgerCannotForgetSpentResponsesOrRewindSnoozeOnUndo() throws {
        let (_, _, candidate) = try notificationFixture(); let queued = snoozeRecord(candidate)
        var before = Snapshot(); before.locationActions = [queued.source: queued]
        var next = before; let reserved = queued.advancing(.reserved); next.locationActions?[queued.source] = reserved
        let saved = try LocationRetirementOutbox.staging(previous: before, proposed: next, account: account)
        let undone = try LocationRetirementOutbox.staging(previous: saved, proposed: before, account: account)
        XCTAssertEqual(undone.locationActions?[queued.source], reserved)
        XCTAssertEqual(try LocationRetirementOutbox.staging(previous: saved, proposed: Snapshot(), account: account).locationActions?[queued.source], reserved)
        let released = reserved.advancing(.queued)
        XCTAssertEqual(try LocationNotificationLedger.merging([queued.source: reserved], [queued.source: released])[queued.source], released)
        let installed = reserved.advancing(.installed)
        XCTAssertThrowsError(try LocationNotificationLedger.merging([queued.source: installed], [queued.source: installed.advancing(.queued)]))
        let spent = LocationNotificationAction(source: queued.source, ticket: candidate.ticket, action: .complete, fireAt: nil, phase: .closed, end: .consumed)
        var durable = Snapshot(); durable.locationActions = [spent.source: spent]
        var recovered = Snapshot(); recovered.locationActions = [spent.source: spent]
        XCTAssertThrowsError(try LocationRetirementOutbox.staging(previous: durable, proposed: recovered, account: account, newResponse: spent), "A replaced in-memory snapshot cannot repeat a spent task mutation")
        let closed = installed.advancing(.closed, end: .consumed)
        XCTAssertThrowsError(try LocationNotificationLedger.merging([queued.source: closed], [queued.source: closed.advancing(.reserved)]))
    }
    func testLedgerRoundTripContainsNoPlaceGeometryAndPortableExportOmitsIt() throws {
        let (task, _, candidate) = try notificationFixture(); let record = snoozeRecord(candidate)
        var snapshot = Snapshot(tables: ["tasks": [task]]); snapshot.locationActions = [record.source: record]
        let encoded = try JSONEncoder().encode(snapshot), decoded = try JSONDecoder().decode(Snapshot.self, from: encoded)
        XCTAssertEqual(snapshot, decoded)
        let raw = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        for forbidden in ["Secret private pin", "latitude", "longitude", "radius", "visited", "deliveredAt"] { XCTAssertFalse(raw.contains(forbidden)) }
        XCTAssertFalse(String(decoding: try WorkspaceBackup.make(snapshot, account: account).data(), as: UTF8.self).contains("locationActions"))
        var invalid = record; invalid.phase = .closed; XCTAssertFalse(invalid.valid)
        snapshot.locationActions = ["wrong": record]
        XCTAssertThrowsError(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot)))
    }
    func testSnoozeRecoveryNeverResubmitsAnAmbiguousOrConsumedOpportunity() throws {
        let (_, _, candidate) = try notificationFixture(); let queued = snoozeRecord(candidate), request = try XCTUnwrap(queued.request(title: "Task")), now = Date(timeIntervalSince1970: queued.fireAt! - 60)
        func recover(_ record: LocationNotificationAction, pending: [ReminderRequest] = [], candidates: [LocationReminderCandidate] = [candidate]) throws -> LocationNotificationAction {
            try XCTUnwrap(LocationNotificationLedger.reconciled([record.source: record], pending: pending, candidates: candidates, now: now)[record.source])
        }
        XCTAssertEqual(try recover(queued), queued)
        XCTAssertEqual(try recover(queued, pending: [request]).end, .failed, "A queued, never-reserved request cannot certify an OS registration")
        let reserved = queued.advancing(.reserved)
        XCTAssertEqual(try recover(reserved).end, .ambiguous)
        XCTAssertEqual(try recover(reserved, pending: [request]).phase, .installed)
        let installed = reserved.advancing(.installed)
        XCTAssertEqual(try recover(installed).end, .consumed)
        XCTAssertEqual(try recover(installed, candidates: []).end, .cancelled)
        var expired = queued; expired = .init(source: expired.source, ticket: expired.ticket, action: .snooze, fireAt: now.timeIntervalSince1970 - 1, phase: .queued)
        XCTAssertEqual(try recover(expired).end, .expired)
    }
    func testNativeLocationSnoozeCodecRejectsCopiedPayloadAndChangedTrigger() throws {
        let (_, _, candidate) = try notificationFixture(); let record = snoozeRecord(candidate), request = try XCTUnwrap(record.request(title: "Task"))
        let content = SystemReminderCenter.content(for: request)
        func native(_ trigger: UNNotificationTrigger?, identifier: String? = nil) -> UNNotificationRequest { .init(identifier: identifier ?? request.identifier, content: content, trigger: trigger) }
        let correct = native(SystemReminderCenter.trigger(at: request.fireAt))
        XCTAssertTrue(try XCTUnwrap(SystemReminderCenter.decodeLocationSnooze(correct)).matchesSnooze(request))
        XCTAssertNil(SystemReminderCenter.decodeLocationSnooze(native(nil)))
        XCTAssertNil(SystemReminderCenter.decodeLocationSnooze(native(UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false))))
        XCTAssertNil(SystemReminderCenter.decodeLocationSnooze(native(SystemReminderCenter.trigger(at: request.fireAt.addingTimeInterval(1)))))
        XCTAssertNil(SystemReminderCenter.decodeLocationSnooze(native(SystemReminderCenter.trigger(at: request.fireAt), identifier: "other")))
        content.userInfo["latitude"] = 1
        XCTAssertNil(SystemReminderCenter.decodeLocationSnooze(native(SystemReminderCenter.trigger(at: request.fireAt))))
        content.userInfo.removeValue(forKey: "latitude"); content.userInfo["snoozed"] = false
        XCTAssertNil(SystemReminderCenter.decodeLocationSnooze(native(SystemReminderCenter.trigger(at: request.fireAt))))
        content.userInfo["snoozed"] = true; content.categoryIdentifier = "taskfold.reminder"
        XCTAssertNil(SystemReminderCenter.decodeLocationSnooze(native(SystemReminderCenter.trigger(at: request.fireAt))))
    }
    func testLocationSnoozeCannotBecomeAnAutomaticOriginalTimeReminder() async throws {
        let (_, _, candidate) = try notificationFixture(); let record = snoozeRecord(candidate), request = try XCTUnwrap(record.request(title: "Task")), now = Date(timeIntervalSince1970: request.fireAt.timeIntervalSince1970 - 60)
        let center = LocationSnoozeTestCenter(); let scheduler = ReminderScheduler(center: center)
        var state = ReminderState(revision: 1, account: account, events: [request.event], now: now)
        _ = await scheduler.update(state); let initialCount = await center.count(); XCTAssertEqual(initialCount, 0)
        state.revision += 1; state.events = []; state.locationSnoozes = [request]; state.locationValidationEvents = [request.event]; state.locationPendingIDs = [request.identifier]
        let ledger = LocationSnoozeTestLedger(record); state.locationSnoozeTransition = { request, transition in await ledger.transition(request, transition) }
        _ = await scheduler.update(state)
        let finalCount = await center.count(), finalPhase = await ledger.phase(); XCTAssertEqual(finalCount, 1); XCTAssertEqual(finalPhase, .installed)
    }

    func testPersistentSnoozeWaitsForCapacityWithoutChangingItsTarget() async throws {
        let (_, _, candidate) = try notificationFixture(); let record = snoozeRecord(candidate), request = try XCTUnwrap(record.request(title: "Task"))
        let center = LocationSnoozeTestCenter(); await center.occupy(60)
        let ledger = LocationSnoozeTestLedger(record), scheduler = ReminderScheduler(center: center)
        var state = ReminderState(revision: 1, account: account, events: [], now: request.fireAt.addingTimeInterval(-60), locationSnoozes: [request], locationValidationEvents: [request.event], locationPendingIDs: [request.identifier], locationSnoozeTransition: { request, transition in await ledger.transition(request, transition) })
        let full = await scheduler.update(state), waitingPhase = await ledger.phase(), before = await center.count()
        XCTAssertEqual(full.deferredSnoozes.count, 1); XCTAssertEqual(waitingPhase, .queued); XCTAssertEqual(before, 0)
        await center.occupy(0); await center.refuseNoRoomOnce(); state.revision += 1
        let drift = await scheduler.update(state), afterDrift = await ledger.phase()
        XCTAssertEqual(drift.deferredSnoozes.count, 1); XCTAssertEqual(afterDrift, .queued, "A proved native no-room refusal releases its reservation without retiming")
        state.revision += 1; _ = await scheduler.update(state)
        let pending = await center.pending(), phase = await ledger.phase()
        XCTAssertEqual(phase, .installed); XCTAssertEqual(pending.first?.fireAt, request.fireAt)
    }
    func testSnoozeRefusesUnrecordedReservationAndRecoversMissingAcknowledgement() async throws {
        let (_, _, candidate) = try notificationFixture(); let record = snoozeRecord(candidate), request = try XCTUnwrap(record.request(title: "Task"))
        let center = LocationSnoozeTestCenter(), ledger = LocationSnoozeTestLedger(record), scheduler = ReminderScheduler(center: center)
        await ledger.fail(reservation: true)
        var state = ReminderState(revision: 1, account: account, events: [], now: request.fireAt.addingTimeInterval(-60), locationSnoozes: [request], locationValidationEvents: [request.event], locationPendingIDs: [request.identifier], locationSnoozeTransition: { request, transition in await ledger.transition(request, transition) })
        let refused = await scheduler.update(state), firstCount = await center.count()
        XCTAssertEqual(firstCount, 0); XCTAssertEqual(refused.failedSnoozes.count, 1)
        await ledger.fail(acknowledgement: true); state.revision += 1
        let accepted = await scheduler.update(state), phase = await ledger.phase(), pending = await center.pending()
        XCTAssertEqual(accepted.acceptedSnoozes.count, 1); XCTAssertEqual(phase, .reserved); XCTAssertEqual(pending.count, 1)
        let reserved = await ledger.value()
        XCTAssertEqual(LocationNotificationLedger.reconciled([record.source: reserved], pending: pending, candidates: [candidate], now: state.now)[record.source]?.phase, .installed)
        state.revision += 1; _ = await scheduler.update(state)
        let additions = await center.additionsCount(); XCTAssertEqual(additions, 1, "An accepted OS request is not submitted a second time after a missed acknowledgement")
    }
    func testSnoozeHeldAddIsRemovedWhenWorkspaceChanges() async throws {
        let (_, _, candidate) = try notificationFixture(); let record = snoozeRecord(candidate), request = try XCTUnwrap(record.request(title: "Task"))
        let center = LocationSnoozeTestCenter(), ledger = LocationSnoozeTestLedger(record), scheduler = ReminderScheduler(center: center)
        await center.holdAdd()
        let state = ReminderState(revision: 1, account: account, events: [], now: request.fireAt.addingTimeInterval(-60), locationSnoozes: [request], locationValidationEvents: [request.event], locationPendingIDs: [request.identifier], locationSnoozeTransition: { request, transition in await ledger.transition(request, transition) })
        let first = Task { await scheduler.update(state) }; await center.waitForAdd()
        let changed = Task { await scheduler.update(ReminderState(revision: 2, account: "other", events: [])) }
        // Confirm the newer workspace has reached the actor before releasing the OS add.
        for _ in 0..<1000 { if await scheduler.currentRevision >= 2 { break }; await Task.yield() }
        await center.releaseAdd(); _ = await first.value; _ = await changed.value
        let count = await center.count(), phase = await ledger.phase()
        XCTAssertEqual(count, 0); XCTAssertEqual(phase, .reserved)
    }

}

private actor LocationRetirementRecoveryCenter: LocationReminderCenter {
    func observe() async throws -> LocationReminderObservation { .init(pending: []) }
    func remove(_ identifiers: [String]) async {}
    func removeAllOwned() async {}
    func add(_ candidate: LocationReminderCandidate) async throws { XCTFail("Recovery must never submit an old intent") }
}

private actor LocationSnoozeTestCenter: ReminderCenter {
    var requests: [ReminderRequest] = []
    var occupied = 0
    var additions = 0
    var noRoomOnce = false
    func refuseNoRoomOnce() { noRoomOnce = true }
    var held = false
    var started = false
    var gate: CheckedContinuation<Void, Never>?
    var waiters: [CheckedContinuation<Void, Never>] = []
    func occupy(_ count: Int) { occupied = count }
    func occupiedOutsideTimeAndFocus() async -> [String] { (0..<occupied).map { "foreign-" + String($0) } }
    func additionsCount() -> Int { additions }
    func holdAdd() { held = true }
    func waitForAdd() async { if started { return }; await withCheckedContinuation { waiters.append($0) } }
    func releaseAdd() { held = false; gate?.resume(); gate = nil }
    func pending() async -> [ReminderRequest] { requests }
    func removeInvalid(_ state: ReminderState) async { requests.removeAll { !$0.valid(state: state) } }
    func remove(_ ids: [String]) async { requests.removeAll { ids.contains($0.identifier) } }
    func add(_ request: ReminderRequest) async throws {
        additions += 1
        if noRoomOnce { noRoomOnce = false; throw ReminderSchedulingFailure.noRoom }
        if held {
            started = true; let callbacks = waiters; waiters = []; callbacks.forEach { $0.resume() }
            await withCheckedContinuation { gate = $0 }
        }
        requests.append(request)
    }
    func count() -> Int { requests.count }
}
private actor LocationSnoozeTestLedger {
    var record: LocationNotificationAction
    var failReservation = false
    var failAcknowledgement = false
    func fail(reservation: Bool = false, acknowledgement: Bool = false) { failReservation = reservation; failAcknowledgement = acknowledgement }
    func value() -> LocationNotificationAction { record }
    init(_ record: LocationNotificationAction) { self.record = record }
    func phase() -> LocationNotificationAction.Phase { record.phase }
    func transition(_ request: ReminderRequest, _ transition: LocationSnoozeTransition) -> LocationSnoozeAcknowledgement {
        guard record.matches(request) else { return .obsolete }
        switch transition {
        case .reserve: if failReservation { return .retry }; guard record.phase == .queued else { return .obsolete }; record = record.advancing(.reserved)
        case .installed: if failAcknowledgement { return .retry }; guard record.phase == .reserved else { return .obsolete }; record = record.advancing(.installed)
        case .notSubmitted: record = record.advancing(.queued)
        case .failed: record = record.advancing(.closed, end: .failed)
        }
        return .saved
    }
}
