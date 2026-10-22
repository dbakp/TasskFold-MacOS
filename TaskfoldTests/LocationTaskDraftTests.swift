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

}
