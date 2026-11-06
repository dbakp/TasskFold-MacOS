import XCTest
@testable import TaskfoldCore

final class LocationActionCleanupTests: XCTestCase {
    func fixture(reason: LocationReminderJournal.Closure? = .cancelled, repeating: Bool = true) throws -> (Record, LocationPrivateArchive, LocationReminderCandidate, LocationNotificationAction) {
        let account = "cleanup-local", device = "97000000-0000-4000-8000-000000000001"
        let place = try XCTUnwrap(LocationPrivatePlace.make(account: account, name: "Synthetic private pin", latitude: 55, longitude: 12, radius: 250))
        var task = Record.task(user: account); task["task_generation"] = .string(UUID().uuidString.lowercased())
        let settings = try XCTUnwrap(LocationReminderSettings.make(device: device, taskID: task.id, taskGeneration: task.string("task_generation"), place: place, transition: .arrive, repeats: repeating))
        task["reminder_specs"] = .array([.object(settings.raw)])
        let candidate = try XCTUnwrap(LocationReminderCandidate(account: account, device: device, task: task, settings: settings, place: place))
        var archive = LocationPrivateArchive(device: device); archive.version = 2; archive.allowedAccounts = [account]; archive.places = [place.raw]
        XCTAssertTrue(archive.journal.prepare(candidate.ticket))
        archive.journal.entries[candidate.ticket.identifier]?.phase = reason == nil ? .installed : .closed
        archive.journal.entries[candidate.ticket.identifier]?.reason = reason
        let source = "la1:" + LocationReminderIdentity.digest(["cleanup", candidate.ticket.identifier])
        let action = LocationNotificationAction(source: source, ticket: candidate.ticket, action: .tomorrow, fireAt: nil, phase: .closed, end: .consumed)
        XCTAssertTrue(archive.valid); XCTAssertTrue(action.valid)
        return (task, archive, candidate, action)
    }
    func testOnlyPermanentlyDeniedExactTicketsCanBeCleared() throws {
        for reason in [LocationReminderJournal.Closure.cancelled, .failed, .untracked] {
            let (_, archive, _, action) = try fixture(reason: reason)
            XCTAssertTrue(try LocationActionCleanup(account: action.ticket.account, archive: archive).permitsRemoval(action))
        }
        for reason in [LocationReminderJournal.Closure.delivered, .noLongerPending, .ambiguous] {
            let (_, archive, _, action) = try fixture(reason: reason, repeating: false)
            XCTAssertFalse(try LocationActionCleanup(account: action.ticket.account, archive: archive).permitsRemoval(action))
        }
    }
    func testActiveRepeatAndPreparedTicketsRetainReplayProtection() throws {
        var (_, archive, candidate, action) = try fixture(reason: nil)
        for phase in [LocationReminderJournal.Phase.prepared, .reserved, .installed] {
            archive.journal.entries[candidate.ticket.identifier]?.phase = phase
            XCTAssertEqual(try LocationActionCleanup(account: action.ticket.account, archive: archive).retaining([action.source: action]), [action.source: action])
        }
    }
    func testRevokedDeliveredReceiptCanBeClearedWithoutRevivingItsResponse() throws {
        var (task, archive, candidate, action) = try fixture(reason: .delivered, repeating: false)
        archive.journal.version = 2; archive.journal.revoked = [candidate.ticket.identifier]
        let cleanup = try LocationActionCleanup(account: action.ticket.account, archive: archive)
        XCTAssertTrue(try cleanup.retaining([action.source: action]).isEmpty)
        XCTAssertNil(LocationNotificationProof.boundary(candidate).candidate(account: action.ticket.account, tasks: [task], archive: archive, cancellations: [:], actions: [:]))
    }
    func testOtherAccountsInstallationsAndUnknownTicketsStayUntouched() throws {
        let (_, archive, _, action) = try fixture()
        let otherAccount = try LocationActionCleanup(account: "another-account", archive: archive)
        XCTAssertFalse(otherAccount.permitsRemoval(action))
        var otherDevice = archive; otherDevice = LocationPrivateArchive()
        XCTAssertFalse(try LocationActionCleanup(account: action.ticket.account, archive: otherDevice).permitsRemoval(action))
        var noEntry = archive; noEntry.journal.entries = [:]
        XCTAssertFalse(try LocationActionCleanup(account: action.ticket.account, archive: noEntry).permitsRemoval(action))
    }
    func testCleanupRequiresReadableValidatedAuthorityAndRecords() throws {
        let (_, archive, candidate, action) = try fixture()
        var bad = archive; bad.journal.entries[candidate.ticket.identifier]?.reason = nil
        XCTAssertThrowsError(try LocationActionCleanup(account: action.ticket.account, archive: bad))
        XCTAssertThrowsError(try LocationActionCleanup(account: "", archive: archive))
        XCTAssertThrowsError(try LocationActionCleanup(account: action.ticket.account, archive: archive).retaining(["bad-key": action]))
    }
    func testOrdinaryWritesCannotForgetHistoryButExplicitCleanupFiltersBothMergeInputs() throws {
        let (task, archive, _, action) = try fixture()
        var previous = Snapshot(tables: ["tasks": [task]]); previous.locationActions = [action.source: action]
        let proposed = Snapshot(tables: ["tasks": [task]])
        XCTAssertEqual(try LocationRetirementOutbox.staging(previous: previous, proposed: proposed, account: action.ticket.account).locationActions, previous.locationActions)
        let cleanup = try LocationActionCleanup(account: action.ticket.account, archive: archive)
        let cleaned = try LocationRetirementOutbox.staging(previous: previous, proposed: previous, account: action.ticket.account, cleanup: cleanup)
        XCTAssertNil(cleaned.locationActions); XCTAssertEqual(cleaned.tables, previous.tables); XCTAssertEqual(cleaned.pending, previous.pending)
    }
    func testCleanupCannotBeCombinedWithAMutatingResponseOrAnotherAccount() throws {
        let (_, archive, _, action) = try fixture(); let cleanup = try LocationActionCleanup(account: action.ticket.account, archive: archive)
        var proposed = Snapshot(); proposed.locationActions = [action.source: action]
        XCTAssertThrowsError(try LocationRetirementOutbox.staging(previous: Snapshot(), proposed: proposed, account: action.ticket.account, newResponse: action, cleanup: cleanup))
        XCTAssertThrowsError(try LocationRetirementOutbox.staging(previous: proposed, proposed: proposed, account: "another-account", cleanup: cleanup))
    }
    func testFullRetiredLedgerCanMakeRoomWhileActiveReceiptIsKept() throws {
        var (_, archive, _, action) = try fixture()
        let (_, activeArchive, activeCandidate, active) = try fixture(reason: nil)
        archive.journal.entries[activeCandidate.ticket.identifier] = activeArchive.journal.entries[activeCandidate.ticket.identifier]
        var full: [String: LocationNotificationAction] = [:]
        for n in 0..<(LocationNotificationAction.maximum - 1) {
            let source = "la1:" + LocationReminderIdentity.digest([String(n)])
            full[source] = LocationNotificationAction(source: source, ticket: action.ticket, action: .tomorrow, fireAt: nil, phase: .closed, end: .consumed)
        }
        full[active.source] = active
        XCTAssertEqual(full.count, LocationNotificationAction.maximum)
        XCTAssertTrue(LocationNotificationLedger.valid(full))
        var previous = Snapshot(); previous.locationActions = full
        XCTAssertThrowsError(try LocationNotificationLedger.merging(full, [action.source: action]))
        let cleanup = try LocationActionCleanup(account: action.ticket.account, archive: archive)
        let cleaned = try LocationRetirementOutbox.staging(previous: previous, proposed: previous, account: action.ticket.account, cleanup: cleanup)
        XCTAssertEqual(cleaned.locationActions, [active.source: active])
        XCTAssertEqual(try LocationNotificationLedger.merging(cleaned.locationActions ?? [:], [action.source: action]).count, 2)
    }
    func testRestoredReceiptsCanBeClearedAgainButNeverRestorePrivateAuthority() throws {
        let (task, archive, candidate, action) = try fixture()
        let cleanup = try LocationActionCleanup(account: action.ticket.account, archive: archive)
        var old = Snapshot(tables: ["tasks": [task]]); old.locationActions = [action.source: action]
        let cleaned = try LocationRetirementOutbox.staging(previous: old, proposed: old, account: action.ticket.account, cleanup: cleanup)
        let restored = try LocationRetirementOutbox.staging(previous: cleaned, proposed: old, account: action.ticket.account)
        XCTAssertEqual(restored.locationActions, old.locationActions)
        XCTAssertFalse(archive.journal.permitsResponse(candidate.ticket, eligible: [candidate]))
        XCTAssertNil(try LocationRetirementOutbox.staging(previous: restored, proposed: restored, account: action.ticket.account, cleanup: cleanup).locationActions)
    }
}
