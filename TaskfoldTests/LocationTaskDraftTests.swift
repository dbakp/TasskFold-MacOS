import XCTest
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

}

private actor LocationRetirementRecoveryCenter: LocationReminderCenter {
    func observe() async throws -> LocationReminderObservation { .init(pending: []) }
    func remove(_ identifiers: [String]) async {}
    func removeAllOwned() async {}
    func add(_ candidate: LocationReminderCandidate) async throws { XCTFail("Recovery must never submit an old intent") }
}
