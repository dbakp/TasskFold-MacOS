import XCTest
import Darwin
@testable import TaskfoldCore

final class LocationHandoffRecoveryTests: XCTestCase {
    let account = "f083cafe-8100-4000-8000-000000000001"
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-handoff-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    func load(_ store: LocationPrivateStore) async throws -> LocationPrivateArchive {
        let archive = try await store.snapshot(); return try XCTUnwrap(archive)
    }
    func record() throws -> LocationHandoffRecord {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "location-handoff-pending", withExtension: "json", subdirectory: "Fixtures"))
        return try XCTUnwrap(LocationHandoffResponse.read(Data(contentsOf: url), account: account, device: nil).records.first)
    }
    func claimed(_ record: LocationHandoffRecord, ticket: LocationHandoffReviewTicket, state: LocationHandoffRecord.State = .claimed) throws -> LocationHandoffRecord {
        var row = record.raw; row["state"] = .string(state.rawValue); row["claim_device"] = .string(ticket.device)
        if state != .claimed { row["available"] = .bool(false); row["payload"] = .null }
        return try XCTUnwrap(.init(raw: row, account: account, device: ticket.device, serverMilliseconds: row["created_at_ms"]!.integer))
    }
    func task(_ proposal: LocationHandoffProposal) -> Record {
        var task = Record.task(user: account); task["id"] = .string(proposal.taskID); task["task_generation"] = .string(proposal.generation)
        task["completion_version"] = .number(Double(proposal.completion)); task["title"] = .string("Synthetic handoff target")
        return task
    }
    func testReservationPrecedesClaimAndResumesSameNonceAndImportIdentitiesAfterRestart() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), pending = try record()
        let ticket = try await store.reserveHandoffReview(pending, expectedDevice: nil)
        let restarted = LocationPrivateStore(applicationSupport: root), archive = try await load(restarted)
        XCTAssertEqual(archive.version, 4); XCTAssertFalse(archive.allows(account: account)); XCTAssertTrue(archive.places.isEmpty); XCTAssertTrue(archive.journal.entries.isEmpty)
        XCTAssertEqual(archive.handoffReviews?[ticket.key], ticket)
        let retried = try await restarted.reserveHandoffReview(pending, expectedDevice: ticket.device)
        XCTAssertEqual(retried, ticket)
        let recovered = try await restarted.reserveHandoffReview(claimed(pending, ticket: ticket), expectedDevice: ticket.device)
        XCTAssertEqual(recovered, ticket)
        XCTAssertEqual(ticket.reviewedSettings(try XCTUnwrap(pending.proposal))?.arm, ticket.arm)
    }
    func testClaimedDraftCannotCreateReplacementNonceOrStealAnotherDeviceReview() async throws {
        let root = try root(), other = try self.root(); defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        let first = LocationPrivateStore(applicationSupport: root), second = LocationPrivateStore(applicationSupport: other), pending = try record()
        let ticket = try await first.reserveHandoffReview(pending, expectedDevice: nil)
        do { _ = try await second.reserveHandoffReview(claimed(pending, ticket: ticket), expectedDevice: nil); XCTFail("Claimed review acquired a new nonce") } catch {}
        XCTAssertNil(try LocationPrivateFile(applicationSupport: other).read())
        do { _ = try await first.reserveHandoffReview(pending, expectedDevice: nil); XCTFail("Stale installation replaced a saved identity") } catch {}
        XCTAssertEqual(try LocationPrivateFile(applicationSupport: root).read()?.handoffReviews?[ticket.key], ticket)
    }
    func testCorruptOrFuturePrivateReviewIsPreservedWithoutReplacingItsNonce() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), pending = try record(), file = LocationPrivateFile(applicationSupport: root)
        let ticket = try await store.reserveHandoffReview(pending, expectedDevice: nil)
        var json = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: file.url)).object
        var reviews = json["handoffReviews"]!.object, entry = reviews[ticket.key]!.object
        entry["future_authority"] = .bool(true); reviews[ticket.key] = .object(entry); json["handoffReviews"] = .object(reviews)
        let bytes = try JSONEncoder().encode(json); try bytes.write(to: file.url)
        do { _ = try await store.reserveHandoffReview(pending, expectedDevice: ticket.device); XCTFail("Unknown review overwritten") } catch {}
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
    }
    func testExplicitPinSaveRetriesReuseOnePinWithoutConsentOrArmedIntent() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), pending = try record(), proposal = try XCTUnwrap(pending.proposal)
        let ticket = try await store.reserveHandoffReview(pending, expectedDevice: nil)
        _ = try await store.saveReviewedHandoffPlace(ticket, proposal: proposal)
        let saved = try await LocationPrivateStore(applicationSupport: root).saveReviewedHandoffPlace(ticket, proposal: proposal)
        XCTAssertEqual(saved.places.count, 1); XCTAssertEqual(saved.places.first?["id"], .string(ticket.placeID))
        XCTAssertFalse(saved.allows(account: account)); XCTAssertTrue(saved.journal.entries.isEmpty)
        var raw = proposal.raw; raw["radius_m"] = .number(500)
        do { _ = try await store.saveReviewedHandoffPlace(ticket, proposal: XCTUnwrap(.init(account: account, raw: raw))); XCTFail("Changed payload adopted") } catch {}
        XCTAssertEqual(try LocationPrivateFile(applicationSupport: root).read(), saved)
    }
    func testResetFencesOldHeadersPinsAndCommitAuthority() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), pending = try record(), proposal = try XCTUnwrap(pending.proposal)
        let ticket = try await store.reserveHandoffReview(pending, expectedDevice: nil)
        _ = try await store.saveReviewedHandoffPlace(ticket, proposal: proposal)
        let reset = try await store.resetAllPrivateData(confirmed: true)
        XCTAssertNotEqual(reset.device, ticket.device); XCTAssertNil(reset.handoffReviews)
        XCTAssertThrowsError(try LocationPrivateFile(applicationSupport: root).withHandoffAuthority(ticket, proposal: proposal) { _ in XCTFail("Old private authority survived reset") })
        do { _ = try await store.saveReviewedHandoffPlace(ticket, proposal: proposal); XCTFail("Old pin recreated after reset") } catch {}
        let saved = try await store.snapshot(); XCTAssertEqual(saved, reset)
    }
    func testPrivateAuthorityLockCoversTaskCommitAndRefusesConcurrentReset() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), pending = try record(), proposal = try XCTUnwrap(pending.proposal)
        let ticket = try await store.reserveHandoffReview(pending, expectedDevice: nil)
        _ = try await store.saveReviewedHandoffPlace(ticket, proposal: proposal)
        let file = LocationPrivateFile(applicationSupport: root)
        try file.withHandoffAuthority(ticket, proposal: proposal) { archive in
            XCTAssertEqual(archive.handoffReviews?[ticket.key], ticket)
            XCTAssertThrowsError(try file.reset(), "Concurrent reset must not replace commit authority")
        }
        XCTAssertEqual(try file.read()?.device, ticket.device)
    }
    func prepared(_ pending: LocationHandoffRecord, ticket: LocationHandoffReviewTicket, archive: LocationPrivateArchive) throws -> (Record,Record,LocationHandoffImportReceipt,LocationHandoffDeviceReview) {
        let proposal = try XCTUnwrap(pending.proposal), before = task(proposal), workspace = WorkspaceBinding(account: account, generation: UUID())
        let review = try XCTUnwrap(LocationHandoffDeviceReview(ticket: ticket, claimed: claimed(pending, ticket: ticket), task: before, workspace: workspace))
        let normal = try XCTUnwrap(review.preparing(task: before, archive: archive, workspace: workspace))
        let after = try XCTUnwrap(normal.applying(to: before, archive: archive, workspace: workspace))
        let receipt = try XCTUnwrap(LocationHandoffImportReceipt(review: ticket, task: after, settings: normal.settings, recoveryEpoch: archive.allows(account: account) ? archive.handoffEpochs?[account] : nil))
        return (before,after,receipt,review)
    }
    func testAtomicTaskReceiptSurvivesRestartUndoAndSnapshotReplacementWithoutReplay() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), pending = try record(), proposal = try XCTUnwrap(pending.proposal)
        let ticket = try await store.reserveHandoffReview(pending, expectedDevice: nil)
        let archive = try await store.saveReviewedHandoffPlace(ticket, proposal: proposal)
        let (before,after,receipt,_) = try prepared(pending, ticket: ticket, archive: archive)
        let previous = Snapshot(tables: ["tasks":[before]])
        var proposed = Snapshot(tables: ["tasks":[after]]); proposed.locationImports = [receipt.key:receipt]
        proposed.locationImports = try LocationHandoffImportLedger.staging(previous: previous, proposed: proposed, accepting: receipt)
        let url = root.appendingPathComponent("synthetic-task-cache.json")
        try LocationPrivateFile(applicationSupport: root).withHandoffAuthority(ticket, proposal: proposal) { _ in try JSONEncoder().encode(proposed).write(to: url, options: .atomic) }
        let restarted = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(restarted.tables["tasks"], [after]); XCTAssertEqual(restarted.locationImports?[receipt.key], receipt)
        XCTAssertTrue(receipt.matches(ticket))
        var undone = previous; undone.locationImports = try LocationHandoffImportLedger.staging(previous: restarted, proposed: undone)
        XCTAssertEqual(undone.tables["tasks"], [before]); XCTAssertEqual(undone.locationImports?[receipt.key], receipt)
        XCTAssertThrowsError(try LocationHandoffImportLedger.staging(previous: undone, proposed: proposed, accepting: receipt))
        let replaced = try LocationHandoffImportLedger.staging(previous: undone, proposed: Snapshot())
        XCTAssertEqual(replaced?[receipt.key], receipt)
    }
    func testFailedTaskCommitLeavesResumableHeaderAndNoArmedIntentOrReceipt() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), pending = try record(), proposal = try XCTUnwrap(pending.proposal)
        let ticket = try await store.reserveHandoffReview(pending, expectedDevice: nil)
        _ = try await store.saveReviewedHandoffPlace(ticket, proposal: proposal)
        let url = root.appendingPathComponent("synthetic-task-cache.json"), original = Snapshot(tables: ["tasks":[task(proposal)]])
        try JSONEncoder().encode(original).write(to: url)
        XCTAssertThrowsError(try LocationPrivateFile(applicationSupport: root).withHandoffAuthority(ticket, proposal: proposal) { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let reopened = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url)), archive = try await load(store)
        XCTAssertNil(reopened.locationImports); XCTAssertEqual(reopened, original); XCTAssertTrue(archive.journal.entries.isEmpty)
        XCTAssertEqual(archive.handoffReviews?[ticket.key], ticket)
        _ = try prepared(pending, ticket: ticket, archive: archive)
    }
    func testTerminalAcknowledgementDropsOnlyTheMatchingHeaderAfterSavedReceipt() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), pending = try record(), proposal = try XCTUnwrap(pending.proposal)
        let ticket = try await store.reserveHandoffReview(pending, expectedDevice: nil)
        let archive = try await store.saveReviewedHandoffPlace(ticket, proposal: proposal)
        let (_,_,receipt,_) = try prepared(pending, ticket: ticket, archive: archive)
        XCTAssertTrue(receipt.matches(ticket))
        do { try await store.acknowledgeHandoff(ticket, terminal: claimed(pending, ticket: ticket)); XCTFail("Live review forgotten") } catch {}
        XCTAssertEqual(try LocationPrivateFile(applicationSupport: root).read()?.handoffReviews?[ticket.key], ticket)
        try await store.acknowledgeHandoff(ticket, terminal: claimed(pending, ticket: ticket, state: .imported))
        try await store.acknowledgeHandoff(ticket, terminal: claimed(pending, ticket: ticket, state: .imported))
        let saved = try await load(store)
        XCTAssertTrue(saved.handoffReviews?.isEmpty == true); XCTAssertEqual(saved.places, archive.places); XCTAssertEqual(saved.journal, archive.journal)
    }
    func testConcurrentReminderCompletionAndWorkspaceEditsRefuseReview() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), pending = try record(), proposal = try XCTUnwrap(pending.proposal)
        let ticket = try await store.reserveHandoffReview(pending, expectedDevice: nil)
        let archive = try await store.saveReviewedHandoffPlace(ticket, proposal: proposal)
        let (before,_,_,review) = try prepared(pending, ticket: ticket, archive: archive)
        for (key,value) in [("completed",JSON.bool(true)),("completion_version",.number(42)),("task_generation",.string(UUID().uuidString.lowercased())),("reminder_specs",.array([.object(ReminderSpec.relative(-30).raw)]))] {
            var task = before; task[key] = value
            XCTAssertNil(review.preparing(task: task, archive: archive, workspace: review.workspace),key)
        }
        XCTAssertNil(review.preparing(task: before, archive: archive, workspace: .init(account: account, generation: UUID())))
        var renamed = before; renamed["title"] = .string("A harmless title edit")
        XCTAssertNotNil(review.preparing(task: renamed, archive: archive, workspace: review.workspace))
    }
    func testImportMetadataCannotCertifyMissingCompletedDuplicateOrDifferentTask() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), pending = try record(), proposal = try XCTUnwrap(pending.proposal)
        let ticket = try await store.reserveHandoffReview(pending, expectedDevice: nil)
        let archive = try await store.saveReviewedHandoffPlace(ticket, proposal: proposal)
        let (before,after,receipt,_) = try prepared(pending, ticket: ticket, archive: archive)
        let previous = Snapshot(tables:["tasks":[before]])
        var completed = after; completed["completed"] = .bool(true)
        for rows in [[],[before],[completed],[after,after]] {
            var proposed = Snapshot(tables:["tasks":rows]); proposed.locationImports = [receipt.key:receipt]
            XCTAssertThrowsError(try LocationHandoffImportLedger.staging(previous:previous,proposed:proposed,accepting:receipt))
        }
        var raw = try JSONDecoder().decode(JSON.self,from:JSONEncoder().encode(receipt)).object; raw["version"] = .number(2)
        let malformed = try JSONDecoder().decode(LocationHandoffImportReceipt.self,from:JSONEncoder().encode(raw))
        XCTAssertFalse(malformed.valid)
        var snapshot = previous; snapshot.locationImports = [malformed.key:malformed]
        XCTAssertThrowsError(try JSONDecoder().decode(Snapshot.self,from:JSONEncoder().encode(snapshot)))
    }
    func testNonceAndGeometryNeverEnterSharedTaskOrPortableBackup() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), pending = try record(), proposal = try XCTUnwrap(pending.proposal)
        let ticket = try await store.reserveHandoffReview(pending, expectedDevice: nil)
        let archive = try await store.saveReviewedHandoffPlace(ticket, proposal: proposal)
        let (_,after,receipt,_) = try prepared(pending, ticket: ticket, archive: archive)
        var snapshot = Snapshot(tables:["tasks":[after]]);snapshot.locationImports = [receipt.key:receipt]
        let exported = String(decoding:try WorkspaceBackup.make(snapshot,account:account).data(),as:UTF8.self)
        let taskJSON = String(decoding:try JSONEncoder().encode(after),as:UTF8.self)
        for text in [exported,taskJSON] { for word in [ticket.nonce,"locationImports","handoffReviews","latitude_e6","longitude_e6",proposal.raw["place_name"]!.text] { XCTAssertFalse(text.contains(word),word) } }
        let cache = String(decoding:try JSONEncoder().encode(snapshot),as:UTF8.self)
        XCTAssertFalse(cache.contains(ticket.nonce));XCTAssertFalse(cache.contains("latitude_e6"))
    }
    func testLegacyAllowanceAndResetAuthoritySurviveUpgradeWithoutRearming() async throws {
        for version in [1,2,3] {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let pending = try record(), file = LocationPrivateFile(applicationSupport: root)
            let old = try file.transaction { _ in
                var archive = LocationPrivateArchive();archive.version = version
                if version >= 2 {archive.allowedAccounts = [account]}
                if version == 3 {archive.supersedesEarlierInstallations = true}
                return (archive,archive)
            }
            let store = LocationPrivateStore(applicationSupport:root)
            let ticket = try await store.reserveHandoffReview(pending,expectedDevice:old.device)
            let next = try await load(store)
            XCTAssertEqual(next.device,old.device);XCTAssertEqual(next.journal,old.journal);XCTAssertEqual(next.allows(account:account),version>=2)
            XCTAssertEqual(next.handoffReviews?[ticket.key],ticket)
            if version == 3 {_ = try LocationInstallationReset(account:account,archive:next)}
        }
    }

    func testSavedImportRecoversPreparationButNeverAfterRetirementOrPriorSubmission() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), pending = try record(), proposal = try XCTUnwrap(pending.proposal)
        let ticket = try await store.reserveHandoffReview(pending, expectedDevice: nil)
        _ = try await store.setAllowance(account: account, enabled: true, expectedDevice: ticket.device)
        let archive = try await store.saveReviewedHandoffPlace(ticket, proposal: proposal)
        let (before,after,receipt,_) = try prepared(pending, ticket: ticket, archive: archive)
        XCTAssertNotNil(receipt.recoveryCandidate(account:account,tasks:[after],archive:archive,cancellations:[:]))
        XCTAssertNil(receipt.recoveryCandidate(account:account,tasks:[before],archive:archive,cancellations:[:]))
        XCTAssertNil(receipt.recoveryCandidate(account:account,tasks:[after],archive:archive,cancellations:[receipt.ticket.identifier:receipt.ticket]))
        XCTAssertNil(receipt.recoveryCandidate(account:"f083cafe-8100-4000-8000-000000000002",tasks:[after],archive:archive,cancellations:[:]))
        for phase in [LocationReminderJournal.Phase.prepared,.reserved,.installed,.closed] {
            var prior = archive
            prior.journal.entries[receipt.ticket.identifier] = .init(ticket:receipt.ticket,phase:phase,reason:phase == .closed ? .cancelled : nil)
            XCTAssertNil(receipt.recoveryCandidate(account:account,tasks:[after],archive:prior,cancellations:[:]),"An existing intent must own its own recovery, not an import replay")
        }
        var denied = archive;denied.journal.version = 2
        denied.journal.entries[receipt.ticket.identifier] = .init(ticket:receipt.ticket,phase:.closed,reason:.cancelled)
        denied.journal.revoked = [receipt.ticket.identifier]
        XCTAssertNil(receipt.recoveryCandidate(account:account,tasks:[after],archive:denied,cancellations:[:]))
        let reset = LocationPrivateArchive()
        XCTAssertNil(receipt.recoveryCandidate(account:account,tasks:[after],archive:reset,cancellations:[:]))
    }
    func testFailedAckDoesNotEraseReceiptAndSuccessfulAckKeepsRecoveryForCommittedTask() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), pending = try record(), proposal = try XCTUnwrap(pending.proposal)
        let ticket = try await store.reserveHandoffReview(pending, expectedDevice: nil)
        _ = try await store.setAllowance(account: account, enabled: true, expectedDevice: ticket.device)
        let archive = try await store.saveReviewedHandoffPlace(ticket, proposal: proposal)
        let (_,after,receipt,_) = try prepared(pending,ticket:ticket,archive:archive)
        var wrong = try claimed(pending,ticket:ticket,state:.imported).raw
        wrong["task_generation"] = .string(UUID().uuidString.lowercased())
        let terminal = try XCTUnwrap(LocationHandoffRecord(raw:wrong,account:account,device:ticket.device,serverMilliseconds:wrong["created_at_ms"]!.integer))
        do {try await store.acknowledgeHandoff(ticket,terminal:terminal);XCTFail("Mismatched terminal response erased nonce")} catch {}
        XCTAssertEqual(try LocationPrivateFile(applicationSupport:root).read()?.handoffReviews?[ticket.key],ticket)
        try await store.acknowledgeHandoff(ticket,terminal:claimed(pending,ticket:ticket,state:.imported))
        let reopened = try await load(store)
        XCTAssertNotNil(receipt.recoveryCandidate(account:account,tasks:[after],archive:reopened,cancellations:[:]),"The saved receipt, not presence of an unacknowledged nonce, certifies the reviewed save")
    }
    func testAccountPartitionKeepsSameRemoteDraftUUIDAndReviewNoncesSeparate() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at:root)}
        let store = LocationPrivateStore(applicationSupport:root), pending = try record()
        let first = try await store.reserveHandoffReview(pending,expectedDevice:nil)
        let other = "f083cafe-8100-4000-8000-000000000002"
        var raw = pending.raw;raw["account_id"] = .string(other)
        let otherRow = try XCTUnwrap(LocationHandoffRecord(raw:raw,account:other,device:first.device,serverMilliseconds:raw["created_at_ms"]!.integer))
        let second = try await store.reserveHandoffReview(otherRow,expectedDevice:first.device)
        XCTAssertEqual(first.id,second.id);XCTAssertNotEqual(first.nonce,second.nonce);XCTAssertNotEqual(first.key,second.key)
        let archive = try await load(store)
        XCTAssertEqual(archive.handoffReviews?.count,2);XCTAssertFalse(archive.allows(account:account));XCTAssertFalse(archive.allows(account:other))
        XCTAssertNil(first.reviewedPlace(try XCTUnwrap(otherRow.proposal)))
    }

    func testConsentOffAndOnCannotRearmAnInterruptedSavedImport() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at:root)}
        let store = LocationPrivateStore(applicationSupport:root), pending = try record(), proposal = try XCTUnwrap(pending.proposal)
        let ticket = try await store.reserveHandoffReview(pending,expectedDevice:nil)
        _ = try await store.setAllowance(account:account,enabled:true,expectedDevice:ticket.device)
        let archive = try await store.saveReviewedHandoffPlace(ticket,proposal:proposal)
        let (_,after,receipt,_) = try prepared(pending,ticket:ticket,archive:archive)
        XCTAssertNotNil(receipt.recoveryCandidate(account:account,tasks:[after],archive:archive,cancellations:[:]))
        let off = try await store.setAllowance(account:account,enabled:false,expectedDevice:ticket.device)
        XCTAssertNil(receipt.recoveryCandidate(account:account,tasks:[after],archive:off,cancellations:[:]))
        let on = try await store.setAllowance(account:account,enabled:true,expectedDevice:ticket.device)
        XCTAssertNotEqual(on.handoffEpochs?[account],receipt.recoveryEpoch)
        XCTAssertNil(receipt.recoveryCandidate(account:account,tasks:[after],archive:on,cancellations:[:]))
        let candidate = try XCTUnwrap(receipt.recoveryCandidate(account:account,tasks:[after],archive:archive,cancellations:[:]))
        let receipts = [receipt.key:receipt]
        XCTAssertTrue(LocationHandoffImportLedger.permitsDelivery(candidate,receipts:receipts,archive:archive))
        var waiting = on
        waiting.journal.entries[receipt.ticket.identifier] = .init(ticket:receipt.ticket,phase:.prepared)
        XCTAssertFalse(LocationHandoffImportLedger.permitsDelivery(candidate,receipts:receipts,archive:waiting),"Even an in-flight prepared intent must recheck the consent epoch at native submission")
        let plan = LocationReminderPlan(account:account,device:on.device,tasks:[after],places:on.places(for:account),availableNotificationSlots:60,allowed:true)
        XCTAssertTrue(plan.respectingHandoffConsent(receipts,archive:waiting).eligible.isEmpty)

    }
    func testSaveWithoutAllowanceNeverCreatesLaterPreparationAuthority() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at:root)}
        let store = LocationPrivateStore(applicationSupport:root), pending = try record(), proposal = try XCTUnwrap(pending.proposal)
        let ticket = try await store.reserveHandoffReview(pending,expectedDevice:nil)
        let archive = try await store.saveReviewedHandoffPlace(ticket,proposal:proposal)
        let (_,after,receipt,_) = try prepared(pending,ticket:ticket,archive:archive)
        XCTAssertNil(receipt.recoveryEpoch)
        let on = try await store.setAllowance(account:account,enabled:true,expectedDevice:ticket.device)
        XCTAssertNil(receipt.recoveryCandidate(account:account,tasks:[after],archive:on,cancellations:[:]))
    }

    func testConflictingHistoryAndFullLedgerRefuseWithoutForgettingPriorImports() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at:root)}
        let store = LocationPrivateStore(applicationSupport:root), pending = try record(), proposal = try XCTUnwrap(pending.proposal)
        let ticket = try await store.reserveHandoffReview(pending,expectedDevice:nil)
        let archive = try await store.saveReviewedHandoffPlace(ticket,proposal:proposal)
        let (before,after,receipt,_) = try prepared(pending,ticket:ticket,archive:archive)
        var saved = Snapshot(tables:["tasks":[after]]);saved.locationImports = [receipt.key:receipt]
        var raw = try JSONDecoder().decode(JSON.self,from:JSONEncoder().encode(receipt)).object
        raw["expiresMilliseconds"] = .number(Double(receipt.expiresMilliseconds-1))
        let changed = try JSONDecoder().decode(LocationHandoffImportReceipt.self,from:JSONEncoder().encode(raw))
        var restored = saved;restored.locationImports = [changed.key:changed]
        XCTAssertThrowsError(try LocationHandoffImportLedger.staging(previous:saved,proposed:restored))
        var full = Snapshot(tables:["tasks":[before]]);full.locationImports = [:]
        for _ in 0..<LocationHandoffImportLedger.maximum {
            raw = try JSONDecoder().decode(JSON.self,from:JSONEncoder().encode(receipt)).object
            raw["reviewID"] = .string(UUID().uuidString.lowercased())
            let record = try JSONDecoder().decode(LocationHandoffImportReceipt.self,from:JSONEncoder().encode(raw))
            full.locationImports?[record.key] = record
        }
        XCTAssertTrue(LocationHandoffImportLedger.valid(full.locationImports!))
        XCTAssertThrowsError(try LocationHandoffImportLedger.staging(previous:full,proposed:saved,accepting:receipt))
        XCTAssertEqual(full.locationImports?.count,LocationHandoffImportLedger.maximum)
    }
    func testFullProtectedReviewStorageRefusesReservationWithoutChangingBytes() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at:root)}
        let store = LocationPrivateStore(applicationSupport:root), pending = try record(), file = LocationPrivateFile(applicationSupport:root)
        let ticket = try await store.reserveHandoffReview(pending,expectedDevice:nil)
        try file.transaction { old in
            var archive = try XCTUnwrap(old);archive.handoffReviews = [:]
            for _ in 0..<256 {
                var raw = try JSONDecoder().decode(JSON.self,from:JSONEncoder().encode(ticket)).object
                raw["id"] = .string(UUID().uuidString.lowercased())
                let t = try JSONDecoder().decode(LocationHandoffReviewTicket.self,from:JSONEncoder().encode(raw))
                archive.handoffReviews?[t.key] = t
            }
            return (archive,())
        }
        let bytes = try Data(contentsOf:file.url)
        do {_ = try await store.reserveHandoffReview(pending,expectedDevice:ticket.device);XCTFail("Review cap discarded old nonces")} catch {}
        XCTAssertEqual(try Data(contentsOf:file.url),bytes)
    }
}


extension LocationHandoffRecoveryTests {
    func testHeadingAndUnknownTypeCannotCertifyOrRecoverAnImportedPlaceReminder() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocationPrivateStore(applicationSupport: root), pending = try record(), proposal = try XCTUnwrap(pending.proposal)
        let ticket = try await store.reserveHandoffReview(pending, expectedDevice: nil)
        _ = try await store.setAllowance(account: account, enabled: true, expectedDevice: ticket.device)
        let archive = try await store.saveReviewedHandoffPlace(ticket, proposal: proposal)
        let (before, after, receipt, _) = try prepared(pending, ticket: ticket, archive: archive)
        let settings = try XCTUnwrap(ReminderSpec.rows(after).compactMap { LocationReminderSettings(raw: $0.object) }.first)
        XCTAssertNotNil(receipt.recoveryCandidate(account: account, tasks: [after], archive: archive, cancellations: [:]))
        for type in [JSON.bool(true), .string("future")] {
            var changed = after; changed["is_heading"] = type
            XCTAssertNil(LocationHandoffImportReceipt(review: ticket, task: changed, settings: settings, recoveryEpoch: receipt.recoveryEpoch))
            XCTAssertNil(receipt.recoveryCandidate(account: account, tasks: [changed], archive: archive, cancellations: [:]))
            let previous = Snapshot(tables: ["tasks": [before]])
            var proposed = Snapshot(tables: ["tasks": [changed]]); proposed.locationImports = [receipt.key: receipt]
            XCTAssertThrowsError(try LocationHandoffImportLedger.staging(previous: previous, proposed: proposed, accepting: receipt))
            XCTAssertEqual(changed["reminder_specs"], after["reminder_specs"])
        }
        let unchanged = try await load(store); XCTAssertEqual(unchanged, archive)
    }
}
