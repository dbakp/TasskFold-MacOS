import XCTest
import CryptoKit
@testable import TaskfoldCore

private final class StructureJournalIO: CalendarSecureItemIO, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: Data] = [:]
    var failWrite = false
    var failAfterWrite = false
    var onWrite: (() -> Void)?
    func read(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return rows[key] }
    func write(_ data: Data, key: String) throws { lock.lock(); defer { lock.unlock() }; if failWrite { throw URLError(.cannotWriteToFile) }; rows[key] = data; onWrite?(); if failAfterWrite { throw URLError(.cannotWriteToFile) } }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; rows.removeValue(forKey: key) }
    var contents: [String: Data] { lock.lock(); defer { lock.unlock() }; return rows }
    func replace(_ data: Data) { lock.lock(); defer { lock.unlock() }; for key in rows.keys { rows[key] = data } }
}

extension ChildTaskStructureRecoveryTests {
    @MainActor private func composerDraft(_ title: String = "", moving: String? = nil) throws -> ChildTaskStructureDraft {
        let read = try presentationRead(scope(command()))
        let draft = try ChildTaskStructureDraft(read: read, moving: moving)
        var body = draft.body; body["title"] = .string(title)
        return try .init(account: draft.account, origin: draft.origin, body: body)
    }
    private func draftJournal(_ draft: ChildTaskStructureDraft, _ io: any CalendarSecureItemIO, _ directory: URL) throws -> ChildTaskStructureDraftJournal {
        try .init(account: draft.account, origin: draft.origin, io: io, coordinationDirectory: directory.appendingPathComponent("locks"), removalDirectory: directory.appendingPathComponent("removal"))
    }
    @MainActor func testComposerDraftReopensExactUnfinishedTextWithoutQueuingAction() async throws {
        let draft = try composerDraft(" \ncafe\u{0301} unfinished \n"), io = StructureJournalIO(), root = try directory()
        let first = try draftJournal(draft, io, root)
        try await first.save(draft, replacing: nil, lease: CalendarReadLease())
        let second = try draftJournal(draft, io, root), reopened = try await second.load()
        XCTAssertEqual(reopened.entries, [draft]); XCTAssertTrue(reopened.entries[0].body["title"]!.text.utf8.elementsEqual(draft.body["title"]!.text.utf8))
        let commands = try journal(command(), io, root)
        let queued = try await commands.load(); XCTAssertTrue(queued.entries.isEmpty)
        XCTAssertFalse(String(describing: draft).contains("unfinished")); XCTAssertFalse(String(reflecting: reopened).contains("unfinished"))
    }
    @MainActor func testComposerBlankAndUnplaceableDraftsPersistButCannotBecomeCommands() async throws {
        let read = try presentationRead(scope(command())), draft = try ChildTaskStructureDraft(read: read)
        let io = StructureJournalIO(), j = try draftJournal(draft, io, directory())
        try await j.save(draft, replacing: nil, lease: CalendarReadLease())
        XCTAssertThrowsError(try draft.reviewedCommand(read))
        var body = draft.body; body["title"] = .string("A title"); body["index"] = .number(999)
        let unplaced = try ChildTaskStructureDraft(account: draft.account, origin: draft.origin, body: body)
        try await j.save(unplaced, replacing: draft.token, lease: CalendarReadLease())
        XCTAssertThrowsError(try unplaced.reviewedCommand(read)); let state = try await j.load(); XCTAssertEqual(state.entries, [unplaced])
    }
    @MainActor func testComposerReviewUsesStableIdentityAndRequiresUnchangedHierarchy() throws {
        let captured = scope(try command()), read = try presentationRead(captured), initial = try ChildTaskStructureDraft(read: read)
        var body = initial.body; body["title"] = .string("Reviewed title")
        let draft = try ChildTaskStructureDraft(account: initial.account, origin: initial.origin, body: body)
        let candidate = try draft.reviewedCommand(read)
        XCTAssertEqual(candidate.id, draft.id); XCTAssertEqual(candidate.body["node"]?.object["title"], body["title"])
        XCTAssertThrowsError(try draft.reviewedCommand(presentationRead(captured, revision: 3)))
        // Session identities are deliberately not durable authority. A future
        // live editor still needs its own lease and current access checks.
        XCTAssertEqual(try draft.reviewedCommand(presentationRead(scope(command()))).id, draft.id)
        for key in ["task_id", "task_generation", "project_id"] {
            var changed = body; changed[key] = .string(UUID().uuidString.lowercased())
            let other = try ChildTaskStructureDraft(account: draft.account, origin: draft.origin, body: changed)
            XCTAssertThrowsError(try other.reviewedCommand(read), key)
        }
        XCTAssertThrowsError(try ChildTaskStructureDraft(account: draft.account, origin: "https://other.test", body: body).reviewedCommand(read))
    }
    @MainActor func testComposerMoveAndDestinationRefuseRecreatedIncarnations() throws {
        let read = try presentationRead(scope(command())), initial = try ChildTaskStructureDraft(read: read, moving: "a")
        var body = initial.body; body["parent_key"] = .string("b"); body["parent_incarnation"] = .string(read.records.nodes["b"]!.incarnation); body["index"] = .number(0)
        let draft = try ChildTaskStructureDraft(account: initial.account, origin: initial.origin, body: body)
        XCTAssertEqual(try draft.reviewedCommand(read).action, .move)
        for key in ["incarnation", "parent_incarnation"] {
            var changed = body; changed[key] = .string(UUID().uuidString.lowercased())
            let other = try ChildTaskStructureDraft(account: draft.account, origin: draft.origin, body: changed)
            XCTAssertThrowsError(try other.reviewedCommand(read), key)
        }
    }
    @MainActor func testComposerTwoWindowsCannotOverwriteOrDiscardNewerDraft() async throws {
        let initial = try composerDraft("First"), io = StructureJournalIO(), root = try directory()
        let a = try draftJournal(initial, io, root), b = try draftJournal(initial, io, root)
        try await a.save(initial, replacing: nil, lease: CalendarReadLease())
        var body = initial.body; body["title"] = .string("Second window")
        let next = try ChildTaskStructureDraft(account: initial.account, origin: initial.origin, body: body)
        try await b.save(next, replacing: initial.token, lease: CalendarReadLease())
        for expected in [nil, initial.token] as [UUID?] {
            do { try await a.save(initial, replacing: expected, lease: CalendarReadLease()); XCTFail("Stale overwrite") } catch { }
        }
        do { try await a.discard(initial, lease: CalendarReadLease()); XCTFail("Stale discard") } catch { }
        let state = try await b.load(); XCTAssertEqual(state.entries, [next])
        try await b.discard(next, lease: CalendarReadLease())
        do { try await a.save(initial, replacing: initial.token, lease: CalendarReadLease()); XCTFail("Recreated removed draft") } catch { }
    }
    @MainActor func testComposerRetryIsIdempotentAndCannotRetargetSameID() async throws {
        let draft = try composerDraft("Kept"), io = StructureJournalIO(), j = try draftJournal(draft, io, directory())
        try await j.save(draft, replacing: nil, lease: CalendarReadLease())
        try await j.save(draft, replacing: nil, lease: CalendarReadLease())
        for key in ["task_id", "task_generation", "project_id"] {
            var body = draft.body; body[key] = .string(UUID().uuidString.lowercased())
            let changed = try ChildTaskStructureDraft(account: draft.account, origin: draft.origin, body: body)
            do { try await j.save(changed, replacing: draft.token, lease: CalendarReadLease()); XCTFail("Retargeted draft") } catch { }
        }
        let state = try await j.load(); XCTAssertEqual(state.entries, [draft])
    }
    @MainActor func testComposerCancelledLeaseAndFailedWriteKeepPriorDraft() async throws {
        let draft = try composerDraft("Kept"), io = StructureJournalIO(), j = try draftJournal(draft, io, directory())
        try await j.save(draft, replacing: nil, lease: CalendarReadLease())
        var body = draft.body; body["title"] = .string("Not saved")
        let next = try ChildTaskStructureDraft(account: draft.account, origin: draft.origin, body: body)
        let lease = CalendarReadLease(); lease.cancel()
        do { try await j.save(next, replacing: draft.token, lease: lease); XCTFail("Cancelled write") } catch { XCTAssertTrue(error is CancellationError) }
        io.failWrite = true
        do { try await j.save(next, replacing: draft.token, lease: CalendarReadLease()); XCTFail("Failed write") } catch { }
        io.failWrite = false
        let state = try await j.load(); XCTAssertEqual(state.entries, [draft])
    }
    @MainActor func testComposerAccountRemovalPreventsRecreationAndCleanupNeedsNoKey() async throws {
        let draft = try composerDraft("Kept"), root = try directory(), secret = SymmetricKey(size: .bits256)
        let io = ReviewedTeamCommandFileIO<ChildTaskStructureDraftState>(directory: root.appendingPathComponent("private"), account: draft.account, origin: draft.origin, encryptionKey: { secret })
        let j = try draftJournal(draft, io, root)
        try await j.save(draft, replacing: nil, lease: CalendarReadLease())
        try AccountRemovalDisk(directory: root.appendingPathComponent("removal"), account: draft.account).removeCache()
        do { try await j.save(draft, replacing: nil, lease: CalendarReadLease()); XCTFail("Removed account write") } catch { }
        let unavailable = ReviewedTeamCommandFileIO<ChildTaskStructureDraftState>(directory: root.appendingPathComponent("private"), account: draft.account, origin: draft.origin, encryptionKey: { throw URLError(.userAuthenticationRequired) })
        try await draftJournal(draft, unavailable, root).removeAccount()
        XCTAssertFalse(FileManager.default.fileExists(atPath: io.file.path))
    }
    @MainActor func testComposerCiphertextScopeAndPermissions() async throws {
        let draft = try composerDraft("Confidential composer title"), root = try directory(), secret = SymmetricKey(size: .bits256)
        let io = ReviewedTeamCommandFileIO<ChildTaskStructureDraftState>(directory: root.appendingPathComponent("private"), account: draft.account, origin: draft.origin, encryptionKey: { secret })
        try await draftJournal(draft, io, root).save(draft, replacing: nil, lease: CalendarReadLease())
        let encrypted = try Data(contentsOf: io.file)
        XCTAssertNil(encrypted.range(of: Data("Confidential composer title".utf8)))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: io.file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let copied = ReviewedTeamCommandFileIO<ChildTaskStructureDraftState>(directory: root.appendingPathComponent("private"), account: draft.account, origin: "https://other.test", encryptionKey: { secret })
        let other = try ChildTaskStructureDraftJournal(account: draft.account, origin: "https://other.test", io: copied, coordinationDirectory: root.appendingPathComponent("locks"), removalDirectory: root.appendingPathComponent("removal"))
        do { _ = try await other.load(); XCTFail("Cross-origin ciphertext") } catch { }
        var corrupt = encrypted; corrupt[corrupt.count / 2] ^= 1; try corrupt.write(to: io.file)
        do { _ = try await draftJournal(draft, io, root).load(); XCTFail("Corrupt ciphertext") } catch { }
    }
    @MainActor func testComposerCapacityNeverPrunesUnsentWork() async throws {
        let draft = try composerDraft("First"), io = StructureJournalIO(), j = try draftJournal(draft, io, directory())
        var expected: [ChildTaskStructureDraft] = []
        for _ in 0..<ChildTaskStructureDraftState.maximumEntries {
            var body = draft.body; body["request_id"] = .string(UUID().uuidString.lowercased())
            let next = try ChildTaskStructureDraft(account: draft.account, origin: draft.origin, body: body)
            try await j.save(next, replacing: nil, lease: CalendarReadLease()); expected.append(next)
        }
        do { try await j.save(draft, replacing: nil, lease: CalendarReadLease()); XCTFail("Silently evicted work") } catch { }
        let state = try await j.load(); XCTAssertEqual(state.entries, expected)
    }
    @MainActor func testComposerWireRejectsUnknownDuplicateAndRoundedNumbers() throws {
        let draft = try composerDraft("Exact"), state = try ChildTaskStructureDraftState(account: draft.account, origin: draft.origin, entries: [draft])
        let data = try JSONEncoder().encode(state), text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(try ChildTaskStructureDraftState(data: data), state)
        for pair in [("\"index\":0", "\"index\":0.00000000000000000001"), ("\"version\":1", "\"version\":1,\"version\":1"), ("\"structure_revision\":2", "\"structure_revision\":2.000000000000000001")] {
            let changed = text.replacingOccurrences(of: pair.0, with: pair.1)
            XCTAssertNotEqual(text, changed); XCTAssertThrowsError(try ChildTaskStructureDraftState(data: Data(changed.utf8)))
        }
        var raw = try JSONDecoder().decode([String: JSON].self, from: data); raw["extra"] = .null
        XCTAssertThrowsError(try ChildTaskStructureDraftState(data: encode(raw)))
        XCTAssertThrowsError(try ChildTaskStructureDraftState(account: draft.account, origin: draft.origin, entries: [draft, draft]))
        var body = draft.body; body["title"] = .string(String(repeating: "a", count: 40_001))
        XCTAssertThrowsError(try ChildTaskStructureDraft(account: draft.account, origin: draft.origin, body: body))
    }
    @MainActor func testComposerConcurrentWindowsKeepIndependentDrafts() async throws {
        let first = try composerDraft("First window"), second = try composerDraft("Second window"), io = StructureJournalIO(), root = try directory()
        let a = try draftJournal(first, io, root), b = try draftJournal(first, io, root)
        async let one: Void = a.save(first, replacing: nil, lease: CalendarReadLease())
        async let two: Void = b.save(second, replacing: nil, lease: CalendarReadLease())
        _ = try await (one, two)
        let state = try await a.load(); XCTAssertEqual(Set(state.entries.map(\.id)), [first.id, second.id])
    }
    @MainActor func testComposerUnreadableStorageIsNeverOverwrittenByNewDraft() async throws {
        let draft = try composerDraft("Keep original"), io = StructureJournalIO(), j = try draftJournal(draft, io, directory())
        try await j.save(draft, replacing: nil, lease: CalendarReadLease())
        let corrupt = Data("unsupported private draft format".utf8); io.replace(corrupt)
        do { try await j.save(composerDraft("New"), replacing: nil, lease: CalendarReadLease()); XCTFail("Replaced unreadable work") } catch { }
        XCTAssertEqual(Array(io.contents.values), [corrupt])
    }
}
private final class ComposerWriteGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var held = false
    func once() {
        lock.lock(); let wait = !held; held = true; lock.unlock()
        if wait { entered.signal(); _ = release.wait(timeout: .now() + 5) }
    }
}
extension ChildTaskStructureRecoveryTests {
    @MainActor func testComposerSessionNewestEditSurvivesSuspendedEarlierWrite() async throws {
        let captured = scope(try command()), read = try presentationRead(captured), draft = try ChildTaskStructureDraft(read: read)
        let io = StructureJournalIO(), gate = ComposerWriteGate(), j = try draftJournal(draft, io, directory())
        io.onWrite = { gate.once() }; defer { gate.release.signal() }
        let session = try ChildTaskStructureDraftSession(scope: captured, draft: draft, saved: false, journal: j, current: { captured })
        try session.stage(draft.editing(title: "First", parent: nil, index: 0))
        let entered = await Task.detached { gate.entered.wait(timeout: .now() + 3) == .success }.value; XCTAssertTrue(entered)
        let latest = try XCTUnwrap(session.draft).editing(title: "Newest cafe\u{0301}", parent: nil, index: 0)
        try session.stage(latest); gate.release.signal()
        let flushed = await session.flush(); XCTAssertTrue(flushed); XCTAssertFalse(session.dirty)
        let reopened = try await j.load(); XCTAssertEqual(reopened.entries, [latest])
    }
    @MainActor func testComposerSessionFailureRetainsTextAndExplicitRetry() async throws {
        let captured = scope(try command()), read = try presentationRead(captured), draft = try ChildTaskStructureDraft(read: read)
        let io = StructureJournalIO(), j = try draftJournal(draft, io, directory())
        let session = try ChildTaskStructureDraftSession(scope: captured, draft: draft, saved: false, journal: j, current: { captured })
        io.failWrite = true
        try session.stage(draft.editing(title: "Keep my unfinished title", parent: nil, index: 0))
        let failed = await session.flush(); XCTAssertFalse(failed); XCTAssertTrue(session.dirty); XCTAssertNotNil(session.message)
        XCTAssertEqual(session.draft?.body["title"], .string("Keep my unfinished title"))
        io.failWrite = false; let retried = await session.flush(); XCTAssertTrue(retried)
        let reopened = try await j.load(); XCTAssertEqual(reopened.entries.first?.body["title"], .string("Keep my unfinished title"))
    }
    @MainActor func testComposerSessionScopeDepartureHidesLateReplyAndRefusesFurtherEdits() async throws {
        let captured = scope(try command()), read = try presentationRead(captured), draft = try ChildTaskStructureDraft(read: read)
        var live: ChildTaskFieldClientScope? = captured
        let io = StructureJournalIO(), gate = ComposerWriteGate(), j = try draftJournal(draft, io, directory())
        io.onWrite = { gate.once() }; defer { gate.release.signal() }
        let session = try ChildTaskStructureDraftSession(scope: captured, draft: draft, saved: false, journal: j, current: { live })
        try session.stage(draft.editing(title: "Original account", parent: nil, index: 0))
        let entered = await Task.detached { gate.entered.wait(timeout: .now() + 3) == .success }.value; XCTAssertTrue(entered)
        live = nil; gate.release.signal()
        let flushed = await session.flush(); XCTAssertFalse(flushed); XCTAssertNil(session.draft)
        XCTAssertThrowsError(try session.stage(draft)); XCTAssertNil(session.message)
    }
    @MainActor func testComposerSessionEmptyOpenDoesNotReserveDraftCapacity() async throws {
        let captured = scope(try command()), draft = try ChildTaskStructureDraft(read: presentationRead(captured)), io = StructureJournalIO()
        let j = try draftJournal(draft, io, directory())
        let session = try ChildTaskStructureDraftSession(scope: captured, draft: draft, saved: false, journal: j, current: { captured })
        let flushed = await session.flush(); XCTAssertTrue(flushed)
        let state = try await j.load(); XCTAssertTrue(state.entries.isEmpty); XCTAssertTrue(io.contents.isEmpty)
    }
    @MainActor func testComposerFrozenPromotionColdResumeKeepsOneOriginalAction() async throws {
        let captured = scope(try command()), read = try presentationRead(captured), draft = try ChildTaskStructureDraft(read: read)
        let draftIO = StructureJournalIO(), root = try directory(), drafts = try draftJournal(draft, draftIO, root)
        let session = try ChildTaskStructureDraftSession(scope: captured, draft: draft, saved: false, journal: drafts, current: { captured })
        try session.stage(draft.editing(title: "Frozen title", parent: nil, index: 0))
        let prepared = await session.prepare(read); let frozen = try XCTUnwrap(prepared)
        let savedState = try await drafts.load(); let saved = try XCTUnwrap(savedState.entries.first); XCTAssertEqual(saved.pendingCommand, frozen)
        XCTAssertThrowsError(try saved.editing(title: "Changed after freeze", parent: nil, index: 0))
        let cold = try ChildTaskStructureDraftSession(scope: captured, draft: saved, saved: true, journal: drafts, current: { captured })
        let resumed = try await cold.prepare(presentationRead(captured, revision: 9)); XCTAssertEqual(resumed, frozen)
        let commandsIO = StructureJournalIO(), commands = try journal(command(), commandsIO, root), peer = StructurePeer()
        let model = ChildTaskStructurePresentation(scope: captured, journal: commands, service: peer, current: { captured }, canQueue: { _ in true }, canSend: { _ in true })
        commandsIO.failAfterWrite = true
        let lost = await model.queueDraftAction(frozen, read: read); XCTAssertFalse(lost)
        commandsIO.failAfterWrite = false
        let recovered = try await model.queueDraftAction(frozen, read: presentationRead(captured, revision: 9)); XCTAssertTrue(recovered)
        let cleaned = await cold.finish(); XCTAssertTrue(cleaned)
        let queued = try await commands.load(); XCTAssertEqual(queued.entries.map(\.command), [frozen]); XCTAssertTrue(peer.calls.isEmpty)
        let remaining = try await drafts.load(); XCTAssertTrue(remaining.entries.isEmpty)
    }
    @MainActor func testComposerFrozenDraftCannotBeUnfrozenOrChangedByOtherWindow() async throws {
        let captured = scope(try command()), read = try presentationRead(captured), original = try ChildTaskStructureDraft(read: read).editing(title: "Keep", parent: nil, index: 0)
        let frozen = try original.preparing(read), io = StructureJournalIO(), j = try draftJournal(original, io, directory())
        try await j.save(original, replacing: nil, lease: CalendarReadLease()); try await j.save(frozen, replacing: original.token, lease: CalendarReadLease())
        let cleared = try ChildTaskStructureDraft(account: frozen.account, origin: frozen.origin, body: frozen.body)
        do { try await j.save(cleared, replacing: frozen.token, lease: CalendarReadLease()); XCTFail("Unfroze original request") } catch { }
        var wrong = frozen.pendingCommand!.body; wrong["index"] = .number(1)
        let changed = try ChildTaskStructureCommand(account: frozen.account, origin: frozen.origin, body: wrong)
        XCTAssertThrowsError(try ChildTaskStructureDraft(account: frozen.account, origin: frozen.origin, body: frozen.body, pendingCommand: changed))
        let state = try await j.load(); XCTAssertEqual(state.entries, [frozen])
    }
    @MainActor func testComposerExplicitPlacementReviewRebasesOnlySameTarget() throws {
        let captured = scope(try command()), oldRead = try presentationRead(captured), fresh = try presentationRead(captured, revision: 6)
        let draft = try ChildTaskStructureDraft(read: oldRead).editing(title: "Keep", parent: nil, index: 0)
        let titleOnly = try draft.editing(title: "Keep typing", parent: nil, index: 0)
        XCTAssertThrowsError(try titleOnly.reviewedCommand(fresh))
        let reviewed = try titleOnly.editing(title: "Keep typing", parent: "b", index: 0, placementRead: fresh)
        XCTAssertNoThrow(try reviewed.reviewedCommand(fresh)); XCTAssertEqual(reviewed.id, draft.id)
        var changed = draft.body; changed["task_generation"] = .string(UUID().uuidString.lowercased())
        let other = try ChildTaskStructureDraft(account: draft.account, origin: draft.origin, body: changed)
        XCTAssertThrowsError(try other.editing(title: "Keep", parent: nil, index: 0, placementRead: fresh))
    }
    @MainActor func testComposerPromotionRefusesCollidingSavedBodyWithoutDeletingDraft() async throws {
        let captured = scope(try command()), read = try presentationRead(captured), draft = try ChildTaskStructureDraft(read: read).editing(title: "Original", parent: nil, index: 0).preparing(read)
        let io = StructureJournalIO(), root = try directory(), j = try journal(command(), io, root), peer = StructurePeer()
        var body = draft.pendingCommand!.body; body["node"] = .object(["id": .string(draft.id), "title": .string("Other body")])
        let other = try ChildTaskStructureCommand(account: draft.account, origin: draft.origin, body: body)
        try await j.enqueue(other, lease: CalendarReadLease())
        let model = ChildTaskStructurePresentation(scope: captured, journal: j, service: peer, current: { captured }, canQueue: { _ in true }, canSend: { _ in true })
        let queued = await model.queueDraftAction(draft.pendingCommand!, read: read); XCTAssertFalse(queued)
        let state = try await j.load(); XCTAssertEqual(state.entries.map(\.command), [other]); XCTAssertTrue(peer.calls.isEmpty)
    }
    @MainActor private func frozenRecoveryFixture() async throws -> (ChildTaskStructureDraft, ChildTaskStructureDraftJournal, ChildTaskStructureJournal, ChildTaskStructurePresentation, StructureJournalIO, StructurePeer) {
        let captured = scope(try command()), read = try presentationRead(captured)
        let draft = try ChildTaskStructureDraft(read: read).editing(title: "Original frozen action", parent: nil, index: 0).preparing(read)
        let root = try directory(), io = StructureJournalIO(), drafts = try draftJournal(draft, io, root), commands = try journal(draft.pendingCommand!, StructureJournalIO(), root), peer = StructurePeer()
        try await drafts.save(draft, replacing: nil, lease: CalendarReadLease())
        let model = ChildTaskStructurePresentation(scope: captured, journal: commands, service: peer, current: { captured }, canQueue: { _ in false }, canSend: { _ in false }, draftJournal: drafts)
        return (draft, drafts, commands, model, io, peer)
    }
    @MainActor func testFinishFrozenDraftPreservesEverySavedActionPhaseWithoutReadOrSend() async throws {
        for phase in [ChildTaskStructureJournalState.Phase.queued, .attempted, .confirmed, .closed] {
            let (draft, drafts, commands, model, _, peer) = try await frozenRecoveryFixture(), command = draft.pendingCommand!
            let lease = CalendarReadLease(); try await commands.enqueue(command, lease: lease)
            if phase == .attempted { _ = try await commands.attempt(command, lease: lease) }
            if phase == .confirmed { _ = try await commands.attempt(command, lease: lease); try await commands.confirm(command, receipt: structureReply(command), lease: lease) }
            if phase == .closed { _ = try await commands.attempt(command, lease: lease); try await commands.resolve(command, decision: structureDecision(command), lease: lease) }
            let before = try await commands.load()
            await model.load(); let finished = await model.finishSavedDraft(draft); XCTAssertTrue(finished)
            let after = try await commands.load(), remaining = try await drafts.load()
            XCTAssertEqual(after.entries, before.entries); XCTAssertEqual(after.disposals, before.disposals); XCTAssertTrue(remaining.entries.isEmpty)
            XCTAssertTrue(peer.calls.isEmpty); XCTAssertTrue(peer.closes.isEmpty); XCTAssertTrue(peer.disposalCalls.isEmpty)
        }
    }
    @MainActor func testFinishFrozenDraftRefusesAbsentOrCollidingSavedAction() async throws {
        for collision in [false, true] {
            let (draft, drafts, commands, model, _, peer) = try await frozenRecoveryFixture()
            if collision {
                var body = draft.pendingCommand!.body; var node = body["node"]!.object; node["title"] = .string("Different saved body"); body["node"] = .object(node)
                try await commands.enqueue(ChildTaskStructureCommand(account: draft.account, origin: draft.origin, body: body), lease: CalendarReadLease())
            }
            let before = try await commands.load(); await model.load()
            let finished = await model.finishSavedDraft(draft); XCTAssertFalse(finished)
            let kept = try await drafts.load(), after = try await commands.load()
            XCTAssertEqual(kept.entries, [draft]); XCTAssertEqual(after.entries, before.entries); XCTAssertTrue(peer.calls.isEmpty)
        }
    }
    @MainActor func testFinishDraftRefusesUnfrozenDraftEvenWithMatchingSavedCommand() async throws {
        let (frozen, drafts, commands, model, _, peer) = try await frozenRecoveryFixture()
        try await drafts.discard(frozen, lease: CalendarReadLease())
        let unfrozen = try ChildTaskStructureDraft(account: frozen.account, origin: frozen.origin, body: frozen.body)
        try await drafts.save(unfrozen, replacing: nil, lease: CalendarReadLease()); try await commands.enqueue(frozen.pendingCommand!, lease: CalendarReadLease())
        await model.load(); let finished = await model.finishSavedDraft(unfrozen); XCTAssertFalse(finished)
        let kept = try await drafts.load(); XCTAssertEqual(kept.entries, [unfrozen]); XCTAssertTrue(peer.calls.isEmpty)
    }
    @MainActor func testFinishFrozenDraftRefusesNewerPrivateRevision() async throws {
        let (draft, drafts, commands, model, _, peer) = try await frozenRecoveryFixture()
        try await commands.enqueue(draft.pendingCommand!, lease: CalendarReadLease()); await model.load()
        let newer = try ChildTaskStructureDraft(account: draft.account, origin: draft.origin, body: draft.body, pendingCommand: draft.pendingCommand)
        try await drafts.save(newer, replacing: draft.token, lease: CalendarReadLease())
        let finished = await model.finishSavedDraft(draft); XCTAssertFalse(finished)
        let kept = try await drafts.load(); XCTAssertEqual(kept.entries, [newer]); XCTAssertEqual(model.drafts, [newer]); XCTAssertTrue(peer.calls.isEmpty)
    }
    @MainActor func testFinishFrozenDraftWriteFailureCanRetryOriginalAction() async throws {
        let (draft, drafts, commands, model, io, peer) = try await frozenRecoveryFixture()
        try await commands.enqueue(draft.pendingCommand!, lease: CalendarReadLease()); await model.load(); io.failWrite = true
        let failed = await model.finishSavedDraft(draft); XCTAssertFalse(failed)
        let kept = try await drafts.load(); XCTAssertEqual(kept.entries, [draft])
        io.failWrite = false; let retried = await model.finishSavedDraft(draft); XCTAssertTrue(retried)
        let after = try await commands.load(); XCTAssertEqual(after.entries.map(\.command), [draft.pendingCommand!]); XCTAssertTrue(peer.calls.isEmpty)
    }
    @MainActor func testFinishFrozenDraftLostCleanupReplyKeepsSavedAction() async throws {
        let (draft, drafts, commands, model, io, peer) = try await frozenRecoveryFixture()
        try await commands.enqueue(draft.pendingCommand!, lease: CalendarReadLease()); await model.load(); io.failAfterWrite = true
        let failed = await model.finishSavedDraft(draft); XCTAssertFalse(failed)
        io.failAfterWrite = false
        let after = try await commands.load(), kept = try await drafts.load()
        XCTAssertTrue(kept.entries.isEmpty); XCTAssertTrue(model.drafts.isEmpty); XCTAssertEqual(after.entries.map(\.command), [draft.pendingCommand!]); XCTAssertTrue(peer.calls.isEmpty)
    }
    @MainActor func testFinishFrozenDraftAfterScopeDepartureKeepsBothCopies() async throws {
        let (draft, drafts, commands, _, _, peer) = try await frozenRecoveryFixture()
        let captured = scope(draft.pendingCommand!); var live: ChildTaskFieldClientScope? = captured
        let model = ChildTaskStructurePresentation(scope: captured, journal: commands, service: peer, current: { live }, canQueue: { _ in false }, canSend: { _ in false }, draftJournal: drafts)
        try await commands.enqueue(draft.pendingCommand!, lease: CalendarReadLease()); await model.load(); live = nil
        let finished = await model.finishSavedDraft(draft); XCTAssertFalse(finished)
        let kept = try await drafts.load(), after = try await commands.load()
        XCTAssertEqual(kept.entries, [draft]); XCTAssertEqual(after.entries.map(\.command), [draft.pendingCommand!]); XCTAssertTrue(peer.calls.isEmpty); XCTAssertNil(model.message)
    }
    @MainActor func testNativeRecoveryLoadsAndDiscardsDraftWithoutChangingActions() async throws {
        let captured = scope(try command()), read = try presentationRead(captured), draft = try ChildTaskStructureDraft(read: read).editing(title: "Unfinished", parent: nil, index: 0)
        let root = try directory(), io = StructureJournalIO(), drafts = try draftJournal(draft, io, root), commands = try journal(command(), StructureJournalIO(), root), peer = StructurePeer()
        try await drafts.save(draft, replacing: nil, lease: CalendarReadLease())
        let model = ChildTaskStructurePresentation(scope: captured, journal: commands, service: peer, current: { captured }, canQueue: { _ in true }, canSend: { _ in true }, draftJournal: drafts)
        await model.load(); XCTAssertEqual(model.drafts, [draft]); XCTAssertNil(model.draftsFailure)
        await model.discardDraft(draft); XCTAssertTrue(model.drafts.isEmpty); XCTAssertTrue(model.entries.isEmpty)
        let saved = try await drafts.load(); XCTAssertTrue(saved.entries.isEmpty); XCTAssertTrue(peer.calls.isEmpty)
    }
    @MainActor func testDiscardReviewedDraftRefusesRefreshedRowAndKeepsSavedAction() async throws {
        let c = try command(), captured = scope(c), read = try presentationRead(captured)
        let reviewed = try ChildTaskStructureDraft(read: read).editing(title: "Reviewed original", parent: nil, index: 0)
        let root = try directory(), io = StructureJournalIO(), drafts = try draftJournal(reviewed, io, root)
        let secondWriter = try draftJournal(reviewed, io, root), commands = try journal(c, StructureJournalIO(), root), peer = StructurePeer()
        try await drafts.save(reviewed, replacing: nil, lease: CalendarReadLease()); try await commands.enqueue(c, lease: CalendarReadLease())
        let model = ChildTaskStructurePresentation(scope: captured, journal: commands, service: peer, current: { captured }, canQueue: { _ in true }, canSend: { _ in true }, draftJournal: drafts)
        await model.load()
        let confirmation = try XCTUnwrap(model.drafts.first)
        let updated = try reviewed.editing(title: "Newer work in another window", parent: nil, index: 0)
        try await secondWriter.save(updated, replacing: reviewed.token, lease: CalendarReadLease())
        await model.load(); XCTAssertEqual(model.drafts, [updated])
        await model.discardDraft(confirmation)
        let kept = try await drafts.load(); XCTAssertEqual(kept.entries, [updated]); XCTAssertEqual(model.drafts, [updated])
        XCTAssertNotEqual(model.message, "Unfinished draft removed. Tasks and saved actions are unchanged.")
        let actions = try await commands.load(); XCTAssertEqual(actions.entries.map(\.command), [c]); XCTAssertTrue(peer.calls.isEmpty)
        // Only a fresh review of the updated row authorizes its removal.
        await model.discardDraft(updated)
        let removed = try await drafts.load(); XCTAssertTrue(removed.entries.isEmpty)
        let unchanged = try await commands.load(); XCTAssertEqual(unchanged.entries.map(\.command), [c]); XCTAssertTrue(peer.calls.isEmpty)
    }
    @MainActor func testDiscardReviewedDraftRefusesSecondWriterBeforeRowRefresh() async throws {
        let c = try command(), captured = scope(c), draft = try ChildTaskStructureDraft(read: presentationRead(captured)).editing(title: "Original", parent: nil, index: 0)
        let root = try directory(), io = StructureJournalIO(), drafts = try draftJournal(draft, io, root), secondWriter = try draftJournal(draft, io, root), peer = StructurePeer()
        let model = ChildTaskStructurePresentation(scope: captured, journal: try journal(c, StructureJournalIO(), root), service: peer, current: { captured }, canQueue: { _ in true }, canSend: { _ in true }, draftJournal: drafts)
        try await drafts.save(draft, replacing: nil, lease: CalendarReadLease()); await model.load()
        let updated = try draft.editing(title: "Saved before refresh", parent: nil, index: 0)
        try await secondWriter.save(updated, replacing: draft.token, lease: CalendarReadLease())
        XCTAssertEqual(model.drafts, [draft])
        await model.discardDraft(draft)
        let kept = try await drafts.load(); XCTAssertEqual(kept.entries, [updated]); XCTAssertEqual(model.drafts, [updated]); XCTAssertTrue(peer.calls.isEmpty)
    }
    @MainActor func testDiscardReviewedDraftCannotActAfterSessionDeparture() async throws {
        let c = try command(), captured = scope(c), draft = try ChildTaskStructureDraft(read: presentationRead(captured)).editing(title: "Keep across departure", parent: nil, index: 0)
        var live: ChildTaskFieldClientScope? = captured
        let root = try directory(), io = StructureJournalIO(), drafts = try draftJournal(draft, io, root), peer = StructurePeer()
        let model = ChildTaskStructurePresentation(scope: captured, journal: try journal(c, StructureJournalIO(), root), service: peer, current: { live }, canQueue: { _ in true }, canSend: { _ in true }, draftJournal: drafts)
        try await drafts.save(draft, replacing: nil, lease: CalendarReadLease()); await model.load()
        live = nil
        await model.discardDraft(draft)
        let kept = try await drafts.load(); XCTAssertEqual(kept.entries, [draft]); XCTAssertTrue(model.drafts.isEmpty); XCTAssertNil(model.message); XCTAssertTrue(peer.calls.isEmpty)
    }
    @MainActor func testNativeDraftFailureKeepsActionRecoveryAndScopeLossClearsAll() async throws {
        let c = try command(), captured = scope(c), read = try presentationRead(captured), draft = try ChildTaskStructureDraft(read: read)
        var live: ChildTaskFieldClientScope? = captured
        let root = try directory(), io = StructureJournalIO(), drafts = try draftJournal(draft, io, root), commands = try journal(c, StructureJournalIO(), root), peer = StructurePeer()
        try await drafts.save(draft, replacing: nil, lease: CalendarReadLease()); io.replace(Data("Unreadable drafts".utf8))
        try await commands.enqueue(c, lease: CalendarReadLease())
        let model = ChildTaskStructurePresentation(scope: captured, journal: commands, service: peer, current: { live }, canQueue: { _ in true }, canSend: { _ in true }, draftJournal: drafts)
        await model.load(); XCTAssertEqual(model.entries.map(\.command), [c]); XCTAssertTrue(model.drafts.isEmpty); XCTAssertNotNil(model.draftsFailure)
        live = nil; await model.load(); XCTAssertTrue(model.entries.isEmpty); XCTAssertTrue(model.drafts.isEmpty); XCTAssertNil(model.draftsFailure)
    }
    @MainActor func testComposerFrozenWireRoundTripAndLegacyDraftRemainReadable() throws {
        let captured = scope(try command()), read = try presentationRead(captured), original = try ChildTaskStructureDraft(read: read).editing(title: "Keep", parent: nil, index: 0)
        let frozen = try original.preparing(read), state = try ChildTaskStructureDraftState(account: frozen.account, origin: frozen.origin, entries: [frozen])
        let data = try JSONEncoder().encode(state); XCTAssertEqual(try ChildTaskStructureDraftState(data: data), state)
        let text = String(decoding: data, as: UTF8.self)
        let bad = text.replacingOccurrences(of: "\"protocol\":1", with: "\"protocol\":1.00000000000000001")
        XCTAssertNotEqual(text, bad); XCTAssertThrowsError(try ChildTaskStructureDraftState(data: Data(bad.utf8)))
        var legacy = try JSONDecoder().decode([String: JSON].self, from: JSONEncoder().encode(original)); legacy.removeValue(forKey: "pendingCommand")
        let reopened = try JSONDecoder().decode(ChildTaskStructureDraft.self, from: encode(legacy)); XCTAssertEqual(reopened, original)
    }
}

// Current move draft labels
extension ChildTaskStructureRecoveryTests {
    @MainActor func testMoveDraftLabelUsesLiveTitleWithoutChangingPrivateDraft() throws {
        let captured = scope(try command()), read = try presentationRead(captured)
        let draft = try ChildTaskStructureDraft(read: read, moving: "a")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(draft)
        let label = try XCTUnwrap(ChildTaskStructureDraftTargetTitle(draft: draft, read: read))
        XCTAssertEqual(label.value(for: draft, scope: captured, snapshot: read.context.snapshot), read.records.nodes["a"]?.fields["title"]?.text)
        XCTAssertEqual(try encoder.encode(draft), before); XCTAssertEqual(draft.body["title"], .string(""))
        let moved = try draft.editing(title: "", parent: "b", index: 0, placementRead: read)
        XCTAssertEqual(label.value(for: moved, scope: captured, snapshot: read.context.snapshot), read.records.nodes["a"]?.fields["title"]?.text)
        XCTAssertEqual(String(describing: label), "Private current subtask label")
        XCTAssertEqual(String(reflecting: label), "Private current subtask label")
    }
    @MainActor func testMoveDraftLabelRefusesRecreatedAndForeignTargets() throws {
        let captured = scope(try command()), read = try presentationRead(captured), draft = try ChildTaskStructureDraft(read: read, moving: "a")
        for field in ["task_id", "task_generation", "project_id", "incarnation"] {
            var body = draft.body; body[field] = .string(UUID().uuidString.lowercased())
            let changed = try ChildTaskStructureDraft(account: draft.account, origin: draft.origin, body: body)
            XCTAssertNil(ChildTaskStructureDraftTargetTitle(draft: changed, read: read), field)
        }
        var missing = draft.body; missing["node_key"] = .string("missing")
        XCTAssertNil(ChildTaskStructureDraftTargetTitle(draft: try .init(account: draft.account, origin: draft.origin, body: missing), read: read))
        XCTAssertNil(ChildTaskStructureDraftTargetTitle(draft: try .init(account: draft.account, origin: "https://other.test", body: draft.body), read: read))
        XCTAssertNil(ChildTaskStructureDraftTargetTitle(draft: try .init(read: read), read: read))
    }
    @MainActor func testMoveDraftLabelInvalidatesOnSnapshotAndEveryScopeDeparture() throws {
        let captured = scope(try command()), read = try presentationRead(captured), draft = try ChildTaskStructureDraft(read: read, moving: "a")
        let label = try XCTUnwrap(ChildTaskStructureDraftTargetTitle(draft: draft, read: read))
        let variants: [ChildTaskFieldClientScope?] = [nil,
            .init(account: UUID().uuidString.lowercased(), origin: captured.origin, workspace: captured.workspace, session: captured.session, access: captured.access),
            .init(account: captured.account, origin: "https://other.test", workspace: captured.workspace, session: captured.session, access: captured.access),
            .init(account: captured.account, origin: captured.origin, workspace: UUID(), session: captured.session, access: captured.access),
            .init(account: captured.account, origin: captured.origin, workspace: captured.workspace, session: UUID(), access: captured.access),
            .init(account: captured.account, origin: captured.origin, workspace: captured.workspace, session: captured.session, access: UUID())]
        for scope in variants { XCTAssertNil(label.value(for: draft, scope: scope, snapshot: read.context.snapshot)) }
        XCTAssertNil(label.value(for: draft, scope: captured, snapshot: UUID()))
        var body = draft.body; body["request_id"] = .string(UUID().uuidString.lowercased())
        XCTAssertNil(label.value(for: try .init(account: draft.account, origin: draft.origin, body: body), scope: captured, snapshot: read.context.snapshot))
        body = draft.body; body["title"] = .string("Spoofed source title")
        XCTAssertEqual(label.value(for: try .init(account: draft.account, origin: draft.origin, body: body), scope: captured, snapshot: read.context.snapshot), read.records.nodes["a"]?.fields["title"]?.text)
    }
}

private func structureReply(_ c: ChildTaskStructureCommand, replayed: Bool = false) throws -> ChildTaskStructureReceipt {
    var raw = c.body.filter { ChildTaskStructureCommand.scopeKeys.contains($0.key) || ["request_id", "action"].contains($0.key) }
    raw["before_revision"] = c.body["structure_revision"]; raw["after_revision"] = .number(Double(c.body["structure_revision"]!.integer + 1))
    raw["undo_of"] = c.body["undo_of"] ?? .null; raw["replayed"] = .bool(replayed)
    raw["node_key"] = c.body["node_key"] ?? c.body["node"]?.object["id"] ?? c.original?.receipt["node_key"]
    switch c.action {
    case .delete: raw["incarnation"] = .null
    case .move: raw["incarnation"] = c.body["incarnation"]
    case .insert: raw["incarnation"] = .string(UUID().uuidString.lowercased())
    case .undo:
        switch c.original!.receipt["action"] {
        case .string("insert"): raw["incarnation"] = .null
        case .string("move"): raw["incarnation"] = c.original!.receipt["incarnation"]
        default: raw["incarnation"] = .string(UUID().uuidString.lowercased())
        }
    }
    return try c.confirmed(raw)
}
private func structureDecision(_ c: ChildTaskStructureCommand, receipt: ChildTaskStructureReceipt? = nil) throws -> ChildTaskStructureResolution {
    try .init(command: c, raw: ["protocol": .number(1), "account": .string(c.account), "request_id": .string(c.id), "outcome": .string(receipt == nil ? "closed" : "applied"), "receipt": receipt.map { .object($0.raw) } ?? .null])
}
private func disposalReply(_ action: ChildTaskStructureUndoDisposal) throws -> ChildTaskStructureUndoDisposalReceipt {
    try action.confirmed(["protocol": .number(1), "account": .string(action.account), "request_id": .string(action.requestID), "outcome": .string("forgotten")])
}
@MainActor private final class StructurePeer: ChildTaskStructureCommandService {
    var calls: [ChildTaskStructureCommand] = [], closes: [ChildTaskStructureCommand] = []
    var applied: [String: ChildTaskStructureReceipt] = [:], closed: Set<String> = []
    var disposalCalls: [String] = [], forgotten: Set<String> = []
    var lose = false, loseClose = false, loseDisposal = false
    var onSend: (() -> Void)?, onClose: (() -> Void)?, onDisposal: (() -> Void)?, onArchives: (() -> Void)?
    var archiveData: Data = Data(), badProof = false
    func childTaskStructureCommand(_ command: ChildTaskStructureCommand, session: UUID) async throws -> ChildTaskStructureReceipt {
        calls.append(command); guard !closed.contains(command.id) else { throw ChildTaskStructureFailure(reason: .closed) }
        let replay = applied[command.id] != nil
        let proof = try applied[command.id] ?? structureReply(command); applied[command.id] = proof
        onSend?(); if lose { lose = false; throw URLError(.networkConnectionLost) }
        if badProof { var raw = proof.raw; raw["request_id"] = .string(UUID().uuidString.lowercased()); return try .init(account: command.account, raw: raw) }
        var raw = proof.raw; raw["replayed"] = .bool(replay); return try command.confirmed(raw)
    }
    func closeChildTaskStructureCommand(_ command: ChildTaskStructureCommand, session: UUID) async throws -> ChildTaskStructureResolution {
        closes.append(command)
        let result: ChildTaskStructureResolution
        if let proof = applied[command.id] { result = try structureDecision(command, receipt: proof) }
        else { closed.insert(command.id); result = try structureDecision(command) }
        onClose?(); if loseClose { loseClose = false; throw URLError(.networkConnectionLost) }; return result
    }
    func childTaskStructureUndoArchives(account: String, origin: String, session: UUID) async throws -> ChildTaskStructureUndoArchives {
        onArchives?(); return try .init(account: account, data: archiveData)
    }
    func forgetChildTaskStructureUndo(_ disposal: ChildTaskStructureUndoDisposal, session: UUID) async throws -> ChildTaskStructureUndoDisposalReceipt {
        disposalCalls.append(disposal.requestID); forgotten.insert(disposal.requestID)
        onDisposal?(); if loseDisposal { loseDisposal = false; throw URLError(.networkConnectionLost) }; return try disposalReply(disposal)
    }
}
private final class StructureRecoveryHTTP: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var callback: ((URLRequest, StructureRecoveryHTTP) -> Void)?
    static var handler: ((URLRequest, StructureRecoveryHTTP) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return callback }
        set { lock.lock(); callback = newValue; lock.unlock() }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func finish(_ status: Int, _ data: Data, headers: [String: String] = [:]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}

final class ChildTaskStructureRecoveryTests: XCTestCase {
    private func equalAsync<T: Equatable>(_ value: @autoclosure () async throws -> T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await value(); XCTAssertEqual(actual, expected, file: file, line: line)
    }
    private func trueAsync(_ value: @autoclosure () async throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await value(); XCTAssertTrue(actual, file: file, line: line)
    }
    private func falseAsync(_ value: @autoclosure () async throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await value(); XCTAssertFalse(actual, file: file, line: line)
    }

    private let origin = "https://child-record.test"
    private func fixture() throws -> [String: JSON] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "child-task-structure-proofs", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
    }
    private func command(_ stem: String = "", changes: [String: JSON] = [:]) throws -> ChildTaskStructureCommand {
        var body = try fixture()["fixture" + stem + "Command"]!.object
        for (key, value) in changes { body[key] = value }
        return try .init(account: body["account"]!.text, origin: origin, body: body)
    }
    private func undo(_ c: ChildTaskStructureCommand, proof: ChildTaskStructureReceipt? = nil, recovered: Bool = false) throws -> ChildTaskStructureCommand {
        let proof = try proof ?? structureReply(c)
        var raw = c.body.filter { ChildTaskStructureCommand.scopeKeys.contains($0.key) }
        raw["action"] = .string("undo"); raw["structure_revision"] = proof.raw["after_revision"]; raw["request_id"] = .string(UUID().uuidString.lowercased()); raw["undo_of"] = .string(c.id)
        var parent = proof.raw; if recovered { parent["replayed"] = .bool(true) }
        return try .init(account: c.account, origin: c.origin, body: raw, original: .init(body: recovered ? nil : c.body, receipt: parent))
    }
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-structure-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }; return value
    }
    private func journal(_ c: ChildTaskStructureCommand, _ io: any CalendarSecureItemIO, _ root: URL) throws -> ChildTaskStructureJournal {
        try .init(account: c.account, origin: c.origin, io: io, coordinationDirectory: root.appendingPathComponent("locks"), removalDirectory: root.appendingPathComponent("removal"))
    }
    private func encode(_ raw: [String: JSON]) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try e.encode(raw) }
    private func confirmed(_ c: ChildTaskStructureCommand) throws -> ChildTaskStructureJournalState.Entry { try .init(command: c, phase: .confirmed, receipt: structureReply(c)) }
    @MainActor private func scope(_ c: ChildTaskStructureCommand) -> ChildTaskFieldClientScope { .init(account: c.account, origin: c.origin, workspace: UUID(), session: UUID(), access: UUID()) }

    func testStateRequiresExactPhaseProofAndScope() throws {
        let c = try command(), proof = try structureReply(c), decision = try structureDecision(c)
        for entry in [ChildTaskStructureJournalState.Entry(command: c, phase: .confirmed), .init(command: c, phase: .queued, receipt: proof), .init(command: c, phase: .attempted, resolution: decision), .init(command: c, phase: .closed)] {
            XCTAssertThrowsError(try ChildTaskStructureJournalState(account: c.account, origin: origin, entries: [entry]))
        }
        XCTAssertThrowsError(try ChildTaskStructureJournalState(account: UUID().uuidString.lowercased(), origin: origin, entries: [try confirmed(c)]))
        XCTAssertThrowsError(try ChildTaskStructureJournalState(account: c.account, origin: origin, entries: [try confirmed(c), try confirmed(c)]))
    }
    func testSavedWireRejectsUnknownKeysAndRoundedCommandOrProofCounters() throws {
        let c = try command(), state = try ChildTaskStructureJournalState(account: c.account, origin: origin, entries: [confirmed(c)])
        let data = try JSONEncoder().encode(state), text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(try ChildTaskStructureJournalState(data: data), state)
        for (key, value) in [("structure_revision", "1"), ("before_revision", "1"), ("version", "1")] {
            let bad = text.replacingOccurrences(of: "\"\(key)\":\(value)", with: "\"\(key)\":1.00000000000000000000001")
            XCTAssertNotEqual(text, bad); XCTAssertThrowsError(try ChildTaskStructureJournalState(data: Data(bad.utf8)))
        }
        var raw = try JSONDecoder().decode([String: JSON].self, from: data); raw["unknown"] = .null
        XCTAssertThrowsError(try ChildTaskStructureJournalState(data: encode(raw)))
    }
    func testUndoLineageAndOneActiveUndoPerOriginal() throws {
        let c = try command(), original = try confirmed(c), inverse = try undo(c, proof: original.receipt), second = try undo(c, proof: original.receipt)
        XCTAssertNoThrow(try ChildTaskStructureJournalState(account: c.account, origin: origin, entries: [original, .init(command: inverse)]))
        XCTAssertThrowsError(try ChildTaskStructureJournalState(account: c.account, origin: origin, entries: [original, .init(command: inverse), .init(command: second)]))
        XCTAssertThrowsError(try ChildTaskStructureJournalState(account: c.account, origin: origin, entries: [.init(command: c), .init(command: inverse)]))
        let deleted = try command("Delete"), recovered = try undo(deleted, recovered: true)
        XCTAssertNoThrow(try ChildTaskStructureJournalState(account: c.account, origin: origin, entries: [.init(command: recovered)]))
    }
    func testDurableQueueAttemptConfirmationAndColdReplay() async throws {
        let c = try command(), io = StructureJournalIO(), root = try directory(), lease = CalendarReadLease(), j = try journal(c, io, root)
        try await j.enqueue(c, lease: lease); try await equalAsync(try await j.load().entries.first?.phase, .queued)
        _ = try await j.attempt(c, lease: lease); try await equalAsync(try await j.load().entries.first?.phase, .attempted)
        let proof = try structureReply(c); try await j.confirm(c, receipt: proof, lease: lease)
        let cold = try journal(c, io, root); try await equalAsync(try await cold.load().entries.first?.receipt, proof)
        var replay = proof.raw; replay["replayed"] = .bool(true)
        try await cold.confirm(c, receipt: c.confirmed(replay), lease: lease)
        try await equalAsync(try await cold.load().entries.first?.receipt, proof)
    }
    func testSameRootOrderingIncludesDifferentChildrenButNotOtherRoots() async throws {
        let first = try command(), io = StructureJournalIO(), j = try journal(first, io, directory()), lease = CalendarReadLease()
        let sibling = try command("Move", changes: ["request_id": .string(UUID().uuidString.lowercased())])
        let other = try command(changes: ["task_id": .string(UUID().uuidString.lowercased()), "request_id": .string(UUID().uuidString.lowercased())])
        try await j.enqueue(first, lease: lease); try await j.enqueue(sibling, lease: lease); try await j.enqueue(other, lease: lease)
        do { _ = try await j.attempt(sibling, lease: lease); XCTFail("Earlier unsettled root action") } catch {}
        _ = try await j.attempt(other, lease: lease)
        _ = try await j.attempt(first, lease: lease); try await j.confirm(first, receipt: structureReply(first), lease: lease)
        _ = try await j.attempt(sibling, lease: lease)
    }
    func testAttemptedActionsCannotBeDiscardedAndConfirmedDeletesStayProtected() async throws {
        let c = try command("Delete"), io = StructureJournalIO(), j = try journal(c, io, directory()), lease = CalendarReadLease()
        try await j.enqueue(c, lease: lease); _ = try await j.attempt(c, lease: lease)
        do { try await j.discard(c, lease: lease); XCTFail("Uncertain action") } catch {}
        try await j.confirm(c, receipt: structureReply(c), lease: lease)
        do { try await j.discard(c, lease: lease); XCTFail("Private archive") } catch {}
    }
    func testStoppedOriginalMustCloseBeforeSaveOnlyFreshReplacement() async throws {
        let c = try command(), io = StructureJournalIO(), j = try journal(c, io, directory()), lease = CalendarReadLease()
        let replacement = try command(changes: ["request_id": .string(UUID().uuidString.lowercased()), "structure_revision": .number(4), "index": .number(1)])
        try await j.enqueue(c, lease: lease)
        do { try await j.replaceClosed(c, with: replacement, lease: lease); XCTFail("Missing terminal decision") } catch {}
        _ = try await j.beginResolution(c, lease: lease); try await j.resolve(c, decision: structureDecision(c), lease: lease)
        do { try await j.enqueue(c, lease: lease); XCTFail("Revived closed original") } catch {}
        try await j.replaceClosed(c, with: replacement, lease: lease)
        let state = try await j.load(); XCTAssertEqual(state.entries.map(\.phase), [.closed, .queued]); XCTAssertEqual(state.entries.last?.command.id, replacement.id)
    }
    func testFreshReplacementCannotChangeInsertedContentOrRoot() async throws {
        let c = try command(), io = StructureJournalIO(), j = try journal(c, io, directory()), lease = CalendarReadLease()
        try await j.enqueue(c, lease: lease); _ = try await j.beginResolution(c, lease: lease); try await j.resolve(c, decision: structureDecision(c), lease: lease)
        for changes in [["node": JSON.object(["id": .string("fresh"), "title": .string("Changed intent")])], ["task_id": .string(UUID().uuidString.lowercased())]] {
            var patch = changes; patch["request_id"] = .string(UUID().uuidString.lowercased())
            let candidate = try command(changes: patch)
            do { try await j.replaceClosed(c, with: candidate, lease: lease); XCTFail("Changed original intent") } catch {}
        }
    }
    func testClosedProofCannotOverrideConfirmedAppliedReceipt() async throws {
        let c = try command(), io = StructureJournalIO(), j = try journal(c, io, directory()), lease = CalendarReadLease()
        try await j.enqueue(c, lease: lease); _ = try await j.attempt(c, lease: lease); try await j.confirm(c, receipt: structureReply(c), lease: lease)
        do { try await j.resolve(c, decision: structureDecision(c), lease: lease); XCTFail("Contradictory terminal proof") } catch {}
        try await equalAsync(try await j.load().entries.first?.phase, .confirmed)
    }
    @MainActor func testLostSendReplyColdRetryUsesSameRequestAndSingleMutation() async throws {
        let c = try command(), io = StructureJournalIO(), root = try directory(), j = try journal(c, io, root), peer = StructurePeer(), s = scope(c)
        let sender = ChildTaskStructureSender(scope: s, journal: j, service: peer, current: { s }, canSend: { _ in true })
        try await j.enqueue(c, lease: CalendarReadLease()); peer.lose = true
        do { _ = try await sender.send(c); XCTFail("Lost reply") } catch {}
        try await equalAsync(try await j.load().entries.first?.phase, .attempted); sender.close()
        let coldJournal = try journal(c, io, root), cold = ChildTaskStructureSender(scope: s, journal: coldJournal, service: peer, current: { s }, canSend: { _ in true })
        let proof = try await cold.send(c); XCTAssertEqual(proof.raw["replayed"], .bool(true)); XCTAssertEqual(peer.calls.map(\.id), [c.id, c.id]); XCTAssertEqual(peer.applied.count, 1)
        _ = try await cold.send(c); XCTAssertEqual(peer.calls.count, 2)
    }
    @MainActor func testFailedAttemptWriteAndUnqueuedSendMakeNoServiceCall() async throws {
        let c = try command(), io = StructureJournalIO(), j = try journal(c, io, directory()), peer = StructurePeer(), s = scope(c)
        let sender = ChildTaskStructureSender(scope: s, journal: j, service: peer, current: { s }, canSend: { _ in true })
        do { _ = try await sender.send(c); XCTFail("Unqueued") } catch {}
        try await j.enqueue(c, lease: CalendarReadLease()); io.failWrite = true
        do { _ = try await sender.send(c); XCTFail("Failed attempted state") } catch {}
        XCTAssertEqual(peer.calls.count, 0); io.failWrite = false
        try await equalAsync(try await j.load().entries.first?.phase, .queued)
    }
    @MainActor func testFailedProofWriteRetainsUncertaintyUntilExactRetry() async throws {
        let c = try command(), io = StructureJournalIO(), j = try journal(c, io, directory()), peer = StructurePeer(), s = scope(c)
        let sender = ChildTaskStructureSender(scope: s, journal: j, service: peer, current: { s }, canSend: { _ in true })
        try await j.enqueue(c, lease: CalendarReadLease()); peer.onSend = { io.failWrite = true }
        do { _ = try await sender.send(c); XCTFail("Failed proof save") } catch {}
        io.failWrite = false; try await equalAsync(try await j.load().entries.first?.phase, .attempted)
        peer.onSend = nil; _ = try await sender.send(c); XCTAssertEqual(peer.applied.count, 1)
        try await equalAsync(try await j.load().entries.first?.phase, .confirmed)
    }
    @MainActor func testMalformedServiceProofKeepsOriginalAttempt() async throws {
        let c = try command(), io = StructureJournalIO(), j = try journal(c, io, directory()), peer = StructurePeer(), s = scope(c)
        let sender = ChildTaskStructureSender(scope: s, journal: j, service: peer, current: { s }, canSend: { _ in true })
        try await j.enqueue(c, lease: CalendarReadLease()); peer.badProof = true
        do { _ = try await sender.send(c); XCTFail("Foreign receipt") } catch {}
        try await equalAsync(try await j.load().entries.first?.phase, .attempted)
    }
    @MainActor func testLostCloseReplyColdRecoveryNeverSendsTaskChanges() async throws {
        let c = try command(), io = StructureJournalIO(), root = try directory(), j = try journal(c, io, root), peer = StructurePeer(), s = scope(c)
        try await j.enqueue(c, lease: CalendarReadLease()); peer.loseClose = true
        let sender = ChildTaskStructureSender(scope: s, journal: j, service: peer, current: { s }, canSend: { _ in false })
        do { _ = try await sender.resolve(c); XCTFail("Lost terminal reply") } catch {}
        let cold = ChildTaskStructureSender(scope: s, journal: try journal(c, io, root), service: peer, current: { s }, canSend: { _ in false })
        try await trueAsync(try await cold.resolve(c).closed); XCTAssertEqual(peer.calls.count, 0); XCTAssertEqual(peer.closes.count, 2)
        do { _ = try await cold.send(c); XCTFail("Closed request sent") } catch {}
    }
    @MainActor func testAppliedResolutionWorksWhenWriteAdmissionIsLost() async throws {
        let c = try command(), io = StructureJournalIO(), j = try journal(c, io, directory()), peer = StructurePeer(), s = scope(c)
        try await j.enqueue(c, lease: CalendarReadLease()); peer.applied[c.id] = try structureReply(c)
        let sender = ChildTaskStructureSender(scope: s, journal: j, service: peer, current: { s }, canSend: { _ in false })
        try await falseAsync(try await sender.resolve(c).closed); try await equalAsync(try await j.load().entries.first?.phase, .confirmed)
        XCTAssertEqual(peer.calls.count, 0)
    }
    @MainActor func testLateSuccessAndFailureAcrossScopeChangeAreCancelled() async throws {
        let c = try command()
        for lose in [false, true] {
            let io = StructureJournalIO(), j = try journal(c, io, directory()), peer = StructurePeer(), captured = scope(c)
            var live: ChildTaskFieldClientScope? = captured
            try await j.enqueue(c, lease: CalendarReadLease()); peer.lose = lose; peer.onSend = { live = nil }
            let sender = ChildTaskStructureSender(scope: captured, journal: j, service: peer, current: { live }, canSend: { _ in true })
            do { _ = try await sender.send(c); XCTFail("Departed workspace") } catch { XCTAssertTrue(error is CancellationError) }
            try await equalAsync(try await j.load().entries.first?.phase, .attempted)
        }
    }
    @MainActor func testLateTerminalAndDisposalResultsCannotPersistAcrossDeparture() async throws {
        let c = try command("Delete"), io = StructureJournalIO(), j = try journal(c, io, directory()), peer = StructurePeer(), captured = scope(c)
        var live: ChildTaskFieldClientScope? = captured
        try await j.enqueue(c, lease: CalendarReadLease()); peer.onClose = { live = nil }
        let sender = ChildTaskStructureSender(scope: captured, journal: j, service: peer, current: { live }, canSend: { _ in false })
        do { _ = try await sender.resolve(c); XCTFail("Late closure") } catch { XCTAssertTrue(error is CancellationError) }
        try await equalAsync(try await j.load().entries.first?.phase, .attempted)
        let separateIO = StructureJournalIO(), separate = try journal(c, separateIO, directory())
        try await separate.enqueueDisposal(structureReply(c), lease: CalendarReadLease()); live = captured; peer.onDisposal = { live = nil }
        let disposalSender = ChildTaskStructureSender(scope: captured, journal: separate, service: peer, current: { live }, canSend: { _ in false })
        do { _ = try await disposalSender.dispose(c.id); XCTFail("Late disposal") } catch { XCTAssertTrue(error is CancellationError) }
        try await equalAsync(try await separate.load().disposals.first?.phase, .attempted)
    }
    @MainActor func testDurableDisposalLostReplyRetriesOnlyDisposal() async throws {
        let c = try command("Delete"), io = StructureJournalIO(), root = try directory(), j = try journal(c, io, root), peer = StructurePeer(), s = scope(c)
        try await j.enqueueDisposal(structureReply(c), lease: CalendarReadLease()); peer.loseDisposal = true
        let sender = ChildTaskStructureSender(scope: s, journal: j, service: peer, current: { s }, canSend: { _ in false })
        do { _ = try await sender.dispose(c.id); XCTFail("Lost disposal acknowledgement") } catch {}
        do { try await j.discardDisposal(c.id, lease: CalendarReadLease()); XCTFail("Uncertain disposal") } catch {}
        let cold = ChildTaskStructureSender(scope: s, journal: try journal(c, io, root), service: peer, current: { s }, canSend: { _ in false })
        _ = try await cold.dispose(c.id); _ = try await cold.dispose(c.id)
        XCTAssertEqual(peer.forgotten, [c.id]); XCTAssertEqual(peer.disposalCalls, [c.id, c.id]); XCTAssertTrue(peer.calls.isEmpty)
    }
    func testUndoAndDisposalAreMutuallyExclusiveInBothDirections() async throws {
        let c = try command("Delete"), proof = try structureReply(c), inverse = try undo(c, proof: proof, recovered: true), lease = CalendarReadLease()
        for disposalFirst in [false, true] {
            let io = StructureJournalIO(), j = try journal(c, io, directory())
            if disposalFirst {
                try await j.enqueueDisposal(proof, lease: lease)
                do { try await j.enqueue(inverse, lease: lease); XCTFail("Undo while disposal queued") } catch {}
                try await j.discardDisposal(c.id, lease: lease); try await j.enqueue(inverse, lease: lease)
            } else {
                try await j.enqueue(inverse, lease: lease)
                do { try await j.enqueueDisposal(proof, lease: lease); XCTFail("Disposal while Undo queued") } catch {}
            }
        }
    }
    func testDisposalProofSaveFailureLeavesAttemptedAndCanRecover() async throws {
        let c = try command("Delete"), io = StructureJournalIO(), j = try journal(c, io, directory()), lease = CalendarReadLease()
        try await j.enqueueDisposal(structureReply(c), lease: lease); _ = try await j.attemptDisposal(c.id, lease: lease)
        let action = try ChildTaskStructureUndoDisposal(account: c.account, origin: origin, requestID: c.id)
        io.failWrite = true
        do { try await j.confirmDisposal(c.id, receipt: disposalReply(action), lease: lease); XCTFail("Proof save fails") } catch {}
        io.failWrite = false; try await equalAsync(try await j.load().disposals.first?.phase, .attempted)
        try await j.confirmDisposal(c.id, receipt: disposalReply(action), lease: lease)
        try await equalAsync(try await j.load().disposals.first?.phase, .confirmed)
    }
    func testConfirmedDeletionCanBeDiscardedAfterConfirmedDisposal() async throws {
        let c = try command("Delete"), io = StructureJournalIO(), j = try journal(c, io, directory()), lease = CalendarReadLease(), proof = try structureReply(c)
        try await j.enqueue(c, lease: lease); _ = try await j.attempt(c, lease: lease); try await j.confirm(c, receipt: proof, lease: lease)
        try await j.enqueueDisposal(proof, lease: lease); _ = try await j.attemptDisposal(c.id, lease: lease)
        let action = try ChildTaskStructureUndoDisposal(account: c.account, origin: origin, requestID: c.id)
        try await j.confirmDisposal(c.id, receipt: disposalReply(action), lease: lease); try await j.discard(c, lease: lease)
        try await trueAsync(try await j.load().entries.isEmpty)
    }
    func testRetentionKeepsOutstandingDeleteAndUncertainOrStoppedFamilies() throws {
        let deleted = try command("Delete"), pending = try command(changes: ["request_id": .string(UUID().uuidString.lowercased())])
        var state = try ChildTaskStructureJournalState(account: deleted.account, origin: origin, entries: [confirmed(deleted), .init(command: pending, phase: .attempted)])
        for _ in 0..<63 { state.entries.append(try confirmed(command(changes: ["request_id": .string(UUID().uuidString.lowercased())]))) }
        try state.makeRoom(); XCTAssertEqual(state.entries.count, 64)
        XCTAssertTrue(state.entries.contains { $0.command.id == deleted.id }); XCTAssertTrue(state.entries.contains { $0.command.id == pending.id })
    }
    func testArchiveProtectedCapacityRefusesWithoutPruningWork() throws {
        let c = try command("Delete")
        var state = try ChildTaskStructureJournalState(account: c.account, origin: origin)
        for _ in 0..<65 { state.entries.append(try confirmed(command("Delete", changes: ["request_id": .string(UUID().uuidString.lowercased())]))) }
        let before = state.entries
        XCTAssertThrowsError(try state.makeRoom()); XCTAssertEqual(state.entries, before)
    }
    func testRetentionPrunesCompleteUndoFamilyTogether() throws {
        let c = try command(), parent = try confirmed(c), inverse = try undo(c, proof: parent.receipt)
        var state = try ChildTaskStructureJournalState(account: c.account, origin: origin, entries: [parent, confirmed(inverse)])
        for _ in 0..<63 { state.entries.append(try confirmed(command(changes: ["request_id": .string(UUID().uuidString.lowercased())]))) }
        try state.makeRoom(); XCTAssertFalse(state.entries.contains { $0.command.familyID == c.id })
        XCTAssertNoThrow(try ChildTaskStructureJournalState(account: c.account, origin: origin, entries: state.entries))
    }
    func testCancelledLeaseAndRemovalTombstoneFenceJournalWrites() async throws {
        let c = try command(), io = StructureJournalIO(), root = try directory(), j = try journal(c, io, root), lease = CalendarReadLease()
        lease.cancel(); do { try await j.enqueue(c, lease: lease); XCTFail("Cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        try AccountRemovalDisk(directory: root.appendingPathComponent("removal"), account: c.account).removeCache()
        do { try await j.enqueue(c, lease: CalendarReadLease()); XCTFail("Removed account") } catch {}
        XCTAssertTrue(io.contents.isEmpty); try await j.removeAccount()
    }
    func testEncryptedColdFileOriginIsolationAndKeylessCleanup() async throws {
        let c = try command(), root = try directory(), key = SymmetricKey(size: .bits256)
        let io = try ChildTaskStructureJournalFileIO(directory: root.appendingPathComponent("vault"), account: c.account, origin: origin, encryptionKey: { key })
        let j = try journal(c, io, root); try await j.enqueue(c, lease: CalendarReadLease())
        XCTAssertFalse(String(decoding: try Data(contentsOf: io.file), as: UTF8.self).contains("Fresh subtask"))
        try await equalAsync(try await journal(c, io, root).load().entries.first?.command, c)
        let attrs = try FileManager.default.attributesOfItem(atPath: io.file.path); XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let foreign = try ChildTaskStructureJournalFileIO(directory: root.appendingPathComponent("vault"), account: c.account, origin: "https://other.test", encryptionKey: { key })
        XCTAssertNotEqual(io.file, foreign.file)
        let noKey = try ChildTaskStructureJournalFileIO(directory: root.appendingPathComponent("vault"), account: c.account, origin: origin, encryptionKey: { throw URLError(.cannotDecodeContentData) })
        try await journal(c, noKey, root).removeAccount(); XCTAssertFalse(FileManager.default.fileExists(atPath: io.file.path))
    }
    func testTwoJournalInstancesSerializeWithoutLostCommands() async throws {
        let first = try command(), second = try command(changes: ["request_id": .string(UUID().uuidString.lowercased())]), io = StructureJournalIO(), root = try directory()
        let a = try journal(first, io, root), b = try journal(first, io, root), lease = CalendarReadLease()
        async let x: Void = a.enqueue(first, lease: lease); async let y: Void = b.enqueue(second, lease: lease)
        _ = try await (x, y); try await equalAsync(Set(try await a.load().entries.map { $0.command.id }), [first.id, second.id])
    }
    private func requestBody(_ request: URLRequest) throws -> [String: JSON] {
        if let data = request.httpBody { return try JSONDecoder().decode([String: JSON].self, from: data) }
        let stream = try XCTUnwrap(request.httpBodyStream); stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0, result.count + max(0, count) <= 400_000 else { throw ChildTaskStructureCommand.invalid }
            if count == 0 { break }; result.append(contentsOf: buffer.prefix(count))
        }
        return try JSONDecoder().decode([String: JSON].self, from: result)
    }
    @MainActor private func backend(_ account: String) throws -> Backend {
        let user: [String: JSON] = ["access_token": .string("synthetic"), "refresh_token": .string("synthetic"), "expires_in": .number(3600), "user": .object(["id": .string(account)])]
        let session = try JSONDecoder().decode(Session.self, from: encode(user))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StructureRecoveryHTTP.self]
        return Backend(configuration: ["URL": origin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
    }
    @MainActor func testActualFourBackendRoutesUseBoundedPrivateTransport() async throws {
        let f = try fixture(), c = try command(), api = try backend(c.account), session = api.reminderSessionIncarnation
        let archiveBytes = try encode(f["fixtureUndoArchives"]!.object); XCTAssertGreaterThan(archiveBytes.count, 16_384)
        let terminal = try structureDecision(c, receipt: c.confirmed(f["fixtureReceipt"]!.object))
        let disposalRaw = f["fixtureDisposal"]!.object, disposal = try ChildTaskStructureUndoDisposal(account: c.account, origin: origin, requestID: disposalRaw["request_id"]!.text)
        var calls: [String] = []
        StructureRecoveryHTTP.handler = { request, transport in
            let path = request.url!.path; calls.append(path)
            XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.timeoutInterval, 25)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store"); XCTAssertFalse(request.httpShouldHandleCookies)
            let sent = try! self.requestBody(request)
            if path.hasSuffix("taskfold_edit_child_structure") || path.hasSuffix("taskfold_close_child_structure") {
                XCTAssertTrue(AuthoredValueComparison.exactJSON(.object(sent), .object(["_body": .object(c.body)])))
            } else if path.hasSuffix("taskfold_forget_child_structure_undo") {
                XCTAssertEqual(sent, ["_request_id": .string(disposal.requestID)])
            } else { XCTAssertTrue(sent.isEmpty) }
            let raw: [String: JSON]
            switch path {
            case "/rest/v1/rpc/taskfold_edit_child_structure": raw = f["fixtureReceipt"]!.object
            case "/rest/v1/rpc/taskfold_close_child_structure": raw = terminal.raw
            case "/rest/v1/rpc/taskfold_child_structure_undo_archives": raw = f["fixtureUndoArchives"]!.object
            default: raw = disposalRaw
            }
            transport.finish(200, try! self.encode(raw))
        }; defer { StructureRecoveryHTTP.handler = nil }
        _ = try await api.childTaskStructureCommand(c, session: session)
        _ = try await api.closeChildTaskStructureCommand(c, session: session)
        try await equalAsync(try await api.childTaskStructureUndoArchives(account: c.account, origin: origin, session: session).entries.count, 64)
        _ = try await api.forgetChildTaskStructureUndo(disposal, session: session)
        XCTAssertEqual(Set(calls).count, 4)
    }
    @MainActor func testBackendSanitizesServiceReasonsWithoutServerText() async throws {
        let c = try command(), api = try backend(c.account), session = api.reminderSessionIncarnation
        defer { StructureRecoveryHTTP.handler = nil }
        for (code, reason) in [("PT503", "unavailable"), ("42501", "unavailable"), ("PT409", "review"), ("PT410", "closed"), ("55P03", "busy"), ("PT429", "limit"), ("54000", "limit"), ("XX000", "unconfirmed")] {
            StructureRecoveryHTTP.handler = { _, transport in transport.finish(403, Data("{\"code\":\"\(code)\",\"message\":\"Private diagnostic must stay private\"}".utf8)) }
            do { _ = try await api.childTaskStructureCommand(c, session: session); XCTFail("Refused \(code)") }
            catch let failure as ChildTaskStructureFailure { XCTAssertEqual(String(describing: failure.reason), reason); XCTAssertFalse(failure.localizedDescription.contains("Private diagnostic")) }
        }
        StructureRecoveryHTTP.handler = { _, transport in transport.finish(403, Data("{\"code\":\"28000\"}".utf8)) }
        do { _ = try await api.closeChildTaskStructureCommand(c, session: session); XCTFail("Expired session") } catch { XCTAssertTrue(error is AccountSessionAuthorizationRequired) }
    }
    @MainActor func testBackendRejectsAmbiguousAndOversizedReplies() async throws {
        let c = try command(), api = try backend(c.account), session = api.reminderSessionIncarnation
        let text = String(decoding: try encode(fixture()["fixtureReceipt"]!.object), as: UTF8.self)
        defer { StructureRecoveryHTTP.handler = nil }
        for raw in [String(text.dropLast()) + ",\"protocol\":1}", text.replacingOccurrences(of: "\"before_revision\":1", with: "\"before_revision\":1.00000000000000000001")] {
            StructureRecoveryHTTP.handler = { _, transport in transport.finish(200, Data(raw.utf8)) }
            do { _ = try await api.childTaskStructureCommand(c, session: session); XCTFail("Unverified proof") } catch let failure as ChildTaskStructureFailure { XCTAssertEqual(String(describing: failure.reason), "unconfirmed") }
        }
        StructureRecoveryHTTP.handler = { _, transport in transport.finish(200, Data("{}".utf8), headers: ["Content-Length": "16385"]) }
        do { _ = try await api.childTaskStructureCommand(c, session: session); XCTFail("Oversized declared proof") } catch {}
        StructureRecoveryHTTP.handler = { _, transport in transport.finish(200, Data(repeating: 32, count: 65_537)) }
        do { _ = try await api.childTaskStructureUndoArchives(account: c.account, origin: origin, session: session); XCTFail("Oversized streamed archive list") } catch {}
    }
    @MainActor func testBackendRefusesWrongOriginSessionAndRedirect() async throws {
        let c = try command(), api = try backend(c.account); var calls = 0
        StructureRecoveryHTTP.handler = { _, transport in calls += 1; transport.finish(302, Data(), headers: ["Location": "https://other.test/receipt"]) }
        defer { StructureRecoveryHTTP.handler = nil }
        do { _ = try await api.childTaskStructureCommand(c, session: UUID()); XCTFail("Wrong session") } catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await api.childTaskStructureUndoArchives(account: c.account, origin: "https://other.test", session: api.reminderSessionIncarnation); XCTFail("Wrong server") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 0)
        do { _ = try await api.childTaskStructureCommand(c, session: api.reminderSessionIncarnation); XCTFail("Redirect") } catch {}
        XCTAssertEqual(calls, 1)
    }
    @MainActor func testBackendHeldSuccessAndFailureCannotEscapeAccountSwitch() async throws {
        let c = try command(), data = try encode(fixture()["fixtureReceipt"]!.object)
        defer { StructureRecoveryHTTP.handler = nil }
        for status in [200, 403] {
            let api = try backend(c.account), session = api.reminderSessionIncarnation, started = expectation(description: "Held actual transport")
            var held: StructureRecoveryHTTP?
            StructureRecoveryHTTP.handler = { _, transport in held = transport; started.fulfill() }
            let task = Task { @MainActor in try await api.childTaskStructureCommand(c, session: session) }
            await fulfillment(of: [started], timeout: 3)
            api.session = try backend(UUID().uuidString.lowercased()).session
            held?.finish(status, status == 200 ? data : Data("{\"code\":\"PT409\"}".utf8))
            do { _ = try await task.value; XCTFail("Late account result") } catch { XCTAssertTrue(error is CancellationError) }
        }
    }
    @MainActor func testArchiveDiscoveryCancelsOnScopeDeparture() async throws {
        let c = try command(), io = StructureJournalIO(), j = try journal(c, io, directory()), peer = StructurePeer(), captured = scope(c)
        peer.archiveData = try encode(fixture()["fixtureUndoArchives"]!.object)
        var live: ChildTaskFieldClientScope? = captured; peer.onArchives = { live = nil }
        let sender = ChildTaskStructureSender(scope: captured, journal: j, service: peer, current: { live }, canSend: { _ in false })
        do { _ = try await sender.archives(); XCTFail("Departed recovery") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testExplicitSettledHistoryRemovalKeepsUndoFamilyAtomic() async throws {
        let c = try command("Delete"), io = StructureJournalIO(), j = try journal(c, io, directory()), lease = CalendarReadLease(), proof = try structureReply(c)
        try await j.enqueue(c, lease: lease); _ = try await j.attempt(c, lease: lease); try await j.confirm(c, receipt: proof, lease: lease)
        let inverse = try undo(c, proof: proof); try await j.enqueue(inverse, lease: lease); _ = try await j.attempt(inverse, lease: lease)
        try await j.confirm(inverse, receipt: structureReply(inverse), lease: lease)
        try await j.discard(inverse, lease: lease); try await trueAsync(try await j.load().entries.isEmpty)
    }
    func testEncryptedSustainedHistoryKeepsPrivateArchiveAndRecentUndo() async throws {
        let deleted = try command("Delete"), root = try directory(), key = SymmetricKey(size: .bits256), lease = CalendarReadLease()
        let io = try ChildTaskStructureJournalFileIO(directory: root.appendingPathComponent("vault"), account: deleted.account, origin: origin, encryptionKey: { key })
        var j = try journal(deleted, io, root)
        try await j.enqueue(deleted, lease: lease); _ = try await j.attempt(deleted, lease: lease); try await j.confirm(deleted, receipt: structureReply(deleted), lease: lease)
        var latest: ChildTaskStructureCommand?, latestProof: ChildTaskStructureReceipt?
        for index in 0..<70 {
            j = try journal(deleted, io, root)
            let next = try command(changes: ["request_id": .string(UUID().uuidString.lowercased()), "structure_revision": .number(Double(13 + index)), "node": .object(["id": .string("new-\(index)"), "title": .string("Synthetic retained work")])])
            try await j.enqueue(next, lease: lease); _ = try await j.attempt(next, lease: lease)
            let proof = try structureReply(next); try await j.confirm(next, receipt: proof, lease: lease); latest = next; latestProof = proof
        }
        let state = try await j.load(); XCTAssertEqual(state.entries.count, 64); XCTAssertTrue(state.entries.contains { $0.command.id == deleted.id })
        let inverse = try undo(XCTUnwrap(latest), proof: XCTUnwrap(latestProof))
        try await j.enqueue(inverse, lease: lease); _ = try await j.attempt(inverse, lease: lease); try await j.confirm(inverse, receipt: structureReply(inverse), lease: lease)
        let cold = try await journal(deleted, io, root).load()
        XCTAssertTrue(cold.entries.contains { $0.command.id == inverse.id && $0.phase == .confirmed }); XCTAssertTrue(cold.entries.contains { $0.command.id == latest!.id })
        XCTAssertLessThanOrEqual(try Data(contentsOf: io.file).count, ChildTaskStructureJournalState.maximumStoredBytes + 1024)
    }
    func testByteBudgetPrunesSettledFamiliesBeforeEntryCountLimit() throws {
        let c = try command(); var state = try ChildTaskStructureJournalState(account: c.account, origin: origin)
        let notes = String(repeating: "😀", count: 80_000)
        for _ in 0..<30 {
            let value = try command(changes: ["request_id": .string(UUID().uuidString.lowercased()), "node": .object(["id": .string(UUID().uuidString.lowercased()), "title": .string("Large private draft"), "description": .string(notes)])])
            state.entries.append(try confirmed(value))
        }
        XCTAssertLessThan(state.entries.count, 64); try state.makeRoom()
        XCTAssertLessThan(state.entries.count, 30); XCTAssertLessThanOrEqual(try JSONEncoder().encode(state).count, ChildTaskStructureJournalState.maximumStoredBytes)
    }
    func testFileSymlinkRefusalPreservesUnrelatedContent() async throws {
        let c = try command(), root = try directory(), key = SymmetricKey(size: .bits256)
        let io = try ChildTaskStructureJournalFileIO(directory: root.appendingPathComponent("vault"), account: c.account, origin: origin, encryptionKey: { key })
        let j = try journal(c, io, root); try await j.enqueue(c, lease: CalendarReadLease())
        let unrelated = root.appendingPathComponent("unrelated.txt"); try Data("Leave this intact".utf8).write(to: unrelated)
        try FileManager.default.removeItem(at: io.file); try FileManager.default.createSymbolicLink(at: io.file, withDestinationURL: unrelated)
        do { _ = try await j.load(); XCTFail("Symlink followed") } catch {}
        do { try await j.enqueue(c, lease: CalendarReadLease()); XCTFail("Symlink overwritten") } catch {}
        XCTAssertEqual(try String(contentsOf: unrelated), "Leave this intact")
        try await j.removeAccount(); XCTAssertEqual(try String(contentsOf: unrelated), "Leave this intact")
    }

    func testRecentlyConfirmedUndoKeepsWholeFamilyRecentForRetention() throws {
        let c = try command(), parent = try confirmed(c), inverse = try undo(c, proof: parent.receipt)
        var state = try ChildTaskStructureJournalState(account: c.account, origin: origin, entries: [parent])
        var middle: [ChildTaskStructureCommand] = []
        for _ in 0..<63 { let next = try command(changes: ["request_id": .string(UUID().uuidString.lowercased())]); middle.append(next); state.entries.append(try confirmed(next)) }
        state.entries.append(try confirmed(inverse)); try state.makeRoom()
        XCTAssertTrue(state.entries.contains { $0.command.id == c.id }); XCTAssertTrue(state.entries.contains { $0.command.id == inverse.id })
        XCTAssertFalse(state.entries.contains { $0.command.id == middle[0].id })
    }
    func testEncryptedCiphertextCannotMoveBetweenOriginsWithSameKey() throws {
        let c = try command(), root = try directory(), key = SymmetricKey(size: .bits256)
        let first = try ChildTaskStructureJournalFileIO(directory: root, account: c.account, origin: origin, encryptionKey: { key })
        let second = try ChildTaskStructureJournalFileIO(directory: root, account: c.account, origin: "https://other.test", encryptionKey: { key })
        let a = ChildTaskStructureJournalState.storagePrefix + c.account + "." + CalendarOAuthConfiguration.digest(origin)
        let b = ChildTaskStructureJournalState.storagePrefix + c.account + "." + CalendarOAuthConfiguration.digest("https://other.test")
        let data = try JSONEncoder().encode(ChildTaskStructureJournalState(account: c.account, origin: origin, entries: [.init(command: c)]))
        try first.write(data, key: a)
        try FileManager.default.createDirectory(at: second.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: first.file).write(to: second.file)
        XCTAssertThrowsError(try second.read(key: b)); XCTAssertEqual(try first.read(key: a), data)
    }

    @MainActor func testAdmissionLossAfterAttemptPreventsNetworkCall() async throws {
        let c = try command(), io = StructureJournalIO(), j = try journal(c, io, directory()), peer = StructurePeer(), captured = scope(c)
        var permitted = true
        try await j.enqueue(c, lease: CalendarReadLease()); io.onWrite = { permitted = false }
        let sender = ChildTaskStructureSender(scope: captured, journal: j, service: peer, current: { captured }, canSend: { _ in permitted })
        do { _ = try await sender.send(c); XCTFail("Admission lost") } catch {}
        XCTAssertTrue(peer.calls.isEmpty); try await equalAsync(try await j.load().entries.first?.phase, .attempted)
    }
    @MainActor func testEveryLiveScopeComponentFencesLateProof() async throws {
        let c = try command(), captured = scope(c)
        let changed: [ChildTaskFieldClientScope] = [
            .init(account: UUID().uuidString.lowercased(), origin: captured.origin, workspace: captured.workspace, session: captured.session, access: captured.access),
            .init(account: captured.account, origin: "https://other.test", workspace: captured.workspace, session: captured.session, access: captured.access),
            .init(account: captured.account, origin: captured.origin, workspace: UUID(), session: captured.session, access: captured.access),
            .init(account: captured.account, origin: captured.origin, workspace: captured.workspace, session: UUID(), access: captured.access),
            .init(account: captured.account, origin: captured.origin, workspace: captured.workspace, session: captured.session, access: UUID())]
        for target in changed {
            let io = StructureJournalIO(), j = try journal(c, io, directory()), peer = StructurePeer()
            var live = captured; try await j.enqueue(c, lease: CalendarReadLease()); peer.onSend = { live = target }
            let sender = ChildTaskStructureSender(scope: captured, journal: j, service: peer, current: { live }, canSend: { _ in true })
            do { _ = try await sender.send(c); XCTFail("Changed live scope") } catch { XCTAssertTrue(error is CancellationError) }
            try await equalAsync(try await j.load().entries.first?.phase, .attempted)
        }
    }
    @MainActor func testAccountRemovalDuringReplyCannotRecreateProofFile() async throws {
        let c = try command(), io = StructureJournalIO(), root = try directory(), j = try journal(c, io, root), peer = StructurePeer(), captured = scope(c)
        try await j.enqueue(c, lease: CalendarReadLease()); var removalError: Error?
        peer.onSend = { do { try AccountRemovalDisk(directory: root.appendingPathComponent("removal"), account: c.account).removeCache() } catch { removalError = error } }
        let sender = ChildTaskStructureSender(scope: captured, journal: j, service: peer, current: { captured }, canSend: { _ in true })
        do { _ = try await sender.send(c); XCTFail("Removal fence") } catch {}
        XCTAssertNil(removalError)
        let stored = try ChildTaskStructureJournalState(data: XCTUnwrap(io.contents.values.first)); XCTAssertEqual(stored.entries.first?.phase, .attempted)
        try await j.removeAccount(); XCTAssertTrue(io.contents.isEmpty)
    }
    @MainActor func testFailedCloseProofSaveRecoversSameTerminalIdentity() async throws {
        let c = try command(), io = StructureJournalIO(), j = try journal(c, io, directory()), peer = StructurePeer(), captured = scope(c)
        try await j.enqueue(c, lease: CalendarReadLease()); peer.onClose = { io.failWrite = true }
        let sender = ChildTaskStructureSender(scope: captured, journal: j, service: peer, current: { captured }, canSend: { _ in false })
        do { _ = try await sender.resolve(c); XCTFail("Failed close proof save") } catch {}
        io.failWrite = false; peer.onClose = nil; try await equalAsync(try await j.load().entries.first?.phase, .attempted)
        try await trueAsync(try await sender.resolve(c).closed); XCTAssertEqual(peer.closes.map(\.id), [c.id, c.id]); XCTAssertTrue(peer.calls.isEmpty)
    }
    @MainActor func testClosedSenderCannotStartAnyServiceOperation() async throws {
        let c = try command("Delete"), io = StructureJournalIO(), j = try journal(c, io, directory()), peer = StructurePeer(), captured = scope(c)
        try await j.enqueue(c, lease: CalendarReadLease())
        let sender = ChildTaskStructureSender(scope: captured, journal: j, service: peer, current: { captured }, canSend: { _ in true }); sender.close()
        do { _ = try await sender.send(c); XCTFail("Closed sender") } catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await sender.resolve(c); XCTFail("Closed resolution") } catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await sender.archives(); XCTFail("Closed discovery") } catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await sender.dispose(c.id); XCTFail("Closed disposal") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(peer.calls.isEmpty); XCTAssertTrue(peer.closes.isEmpty); XCTAssertTrue(peer.disposalCalls.isEmpty)
        try await equalAsync(try await j.load().entries.first?.phase, .queued)
    }

    @MainActor private func presentationRead(_ scope: ChildTaskFieldClientScope, revision: Double = 2) throws -> ChildTaskStructureRead {
        let f = try fixture(); var raw = f["fixtureRead"]!.object; raw["structure_revision"] = .number(revision)
        let context = try ChildTaskRecordContext(account: scope.account, origin: scope.origin, workspace: scope.workspace, session: scope.session, access: scope.access, snapshot: UUID(), root: Record(f["fixtureRoot"]!.object))
        return try .init(data: encode(raw), context: context)
    }
    @MainActor func testNativePresentationSavesThenExplicitlySendsWithoutPatchingSource() async throws {
        let c = try command(), captured = scope(c), read = try presentationRead(captured), io = StructureJournalIO(), j = try journal(c, io, directory()), peer = StructurePeer()
        let model = ChildTaskStructurePresentation(scope: captured, journal: j, service: peer, current: { captured }, canQueue: { _ in true }, canSend: { _ in true })
        let next = try ChildTaskStructureCommand(insert: .object(["id": .string("new-native"), "title": .string("Native reviewed change")]), parent: nil, index: 0, read: read)
        try await trueAsync(await model.queue(next, read: read)); XCTAssertEqual(model.entries.first?.phase, .queued); XCTAssertTrue(peer.calls.isEmpty)
        try await trueAsync(await model.send(next)); XCTAssertEqual(model.entries.first?.phase, .confirmed); XCTAssertEqual(peer.calls.map(\.id), [next.id])
        XCTAssertNil(read.records.nodes["new-native"]); XCTAssertEqual(model.message, "Subtask added.")
    }
    @MainActor func testNativePresentationStopAndFreshReviewAreSaveOnly() async throws {
        let c = try command(), captured = scope(c), read = try presentationRead(captured), io = StructureJournalIO(), j = try journal(c, io, directory()), peer = StructurePeer()
        let model = ChildTaskStructurePresentation(scope: captured, journal: j, service: peer, current: { captured }, canQueue: { _ in true }, canSend: { _ in true })
        let move = try ChildTaskStructureCommand(move: "a", parent: "b", index: 0, read: read)
        try await trueAsync(await model.queue(move, read: read)); await model.stop(move)
        let entry = try XCTUnwrap(model.entries.first); XCTAssertEqual(entry.phase, .closed)
        let stable = UUID(), fresh = try ChildTaskStructureReview.fresh(move, read: read, parent: nil, index: 2, requestID: stable)
        XCTAssertEqual(fresh.id, stable.uuidString.lowercased()); try await trueAsync(await model.replace(entry, with: fresh, read: read))
        XCTAssertEqual(model.entries.last?.phase, .queued); XCTAssertTrue(peer.calls.isEmpty); XCTAssertEqual(peer.closes.count, 1)
    }
    @MainActor func testNativePresentationRefusesQueueAfterAdmissionOrScopeLoss() async throws {
        let c = try command(), captured = scope(c), read = try presentationRead(captured), io = StructureJournalIO(), j = try journal(c, io, directory()), peer = StructurePeer()
        let move = try ChildTaskStructureCommand(move: "a", parent: "b", index: 0, read: read)
        let model = ChildTaskStructurePresentation(scope: captured, journal: j, service: peer, current: { captured }, canQueue: { _ in false }, canSend: { _ in true })
        try await falseAsync(await model.queue(move, read: read)); try await trueAsync(try await j.load().entries.isEmpty)
        let foreign = try presentationRead(scope(c))
        let other = ChildTaskStructurePresentation(scope: captured, journal: j, service: peer, current: { captured }, canQueue: { _ in true }, canSend: { _ in true })
        try await falseAsync(await other.queue(move, read: foreign)); XCTAssertTrue(peer.calls.isEmpty)
    }
    @MainActor func testNativePresentationCloseFencesLateSendAndClearsVisibleData() async throws {
        let c = try command(), captured = scope(c), read = try presentationRead(captured), io = StructureJournalIO(), j = try journal(c, io, directory()), peer = StructurePeer()
        let model = ChildTaskStructurePresentation(scope: captured, journal: j, service: peer, current: { captured }, canQueue: { _ in true }, canSend: { _ in true })
        let move = try ChildTaskStructureCommand(move: "a", parent: "b", index: 0, read: read)
        try await trueAsync(await model.queue(move, read: read)); peer.onSend = { model.close() }
        try await falseAsync(await model.send(move)); XCTAssertTrue(model.entries.isEmpty); XCTAssertNil(model.message); XCTAssertFalse(model.loaded)
        try await equalAsync(try await j.load().entries.first?.phase, .attempted)
    }
    @MainActor func testNativePresentationDiscoveryDoesNotDisposeUntilExplicitAction() async throws {
        let c = try command(), captured = scope(c), io = StructureJournalIO(), j = try journal(c, io, directory()), peer = StructurePeer()
        peer.archiveData = try encode(fixture()["fixtureUndoArchives"]!.object)
        let model = ChildTaskStructurePresentation(scope: captured, journal: j, service: peer, current: { captured }, canQueue: { _ in false }, canSend: { _ in false })
        await model.load(); await model.discoverArchives(); XCTAssertEqual(model.availableArchives.count, 64); XCTAssertTrue(peer.forgotten.isEmpty)
        let source = try XCTUnwrap(model.availableArchives.first); await model.dispose(source)
        XCTAssertEqual(peer.forgotten, [source.raw["request_id"]!.text]); XCTAssertEqual(model.disposals.first?.phase, .confirmed); XCTAssertEqual(model.availableArchives.count, 63)
        XCTAssertTrue(peer.calls.isEmpty)
    }
    @MainActor func testNativePresentationUnsentDisposalCanBeCancelledWithoutServiceCall() async throws {
        let c = try command("Delete"), captured = scope(c), io = StructureJournalIO(), j = try journal(c, io, directory()), peer = StructurePeer()
        try await j.enqueueDisposal(structureReply(c), lease: CalendarReadLease())
        let model = ChildTaskStructurePresentation(scope: captured, journal: j, service: peer, current: { captured }, canQueue: { _ in false }, canSend: { _ in false })
        await model.load(); let item = try XCTUnwrap(model.disposals.first); await model.cancelUnsentDisposal(item); XCTAssertTrue(model.disposals.isEmpty); XCTAssertTrue(peer.disposalCalls.isEmpty)
    }
    @MainActor func testNativePresentationArchiveFailureAfterDepartureClearsMetadata() async throws {
        let c = try command(), captured = scope(c), io = StructureJournalIO(), j = try journal(c, io, directory()), peer = StructurePeer()
        peer.archiveData = try encode(fixture()["fixtureUndoArchives"]!.object); var live: ChildTaskFieldClientScope? = captured
        let model = ChildTaskStructurePresentation(scope: captured, journal: j, service: peer, current: { live }, canQueue: { _ in false }, canSend: { _ in false })
        await model.load(); peer.onArchives = { live = nil }; await model.discoverArchives()
        XCTAssertTrue(model.archives.isEmpty); XCTAssertFalse(model.loaded); XCTAssertNil(model.message)
    }
    @MainActor func testNativeDestinationChoicesExcludeMovingBranchAndUseAuthoredOrder() throws {
        let read = try presentationRead(scope(command()))
        XCTAssertEqual(ChildTaskStructureReview.destinations(read, moving: "a").map(\.key), ["fresh", "b"])
        XCTAssertEqual(ChildTaskStructureReview.siblings(read, parent: nil, moving: "a").map(\.key), ["fresh", "b"])
        XCTAssertEqual(ChildTaskStructureReview.siblings(read, parent: "a", moving: nil).map(\.key), ["nested"])
    }

    @MainActor func testNativeOpeningRefusesRecreatedNodeAndMissingSelection() throws {
        let captured = scope(try command()), read = try presentationRead(captured), opening = try ChildTaskStructureOpening(read: read, node: "a")
        var raw = try fixture()["fixtureRead"]!.object, rows = raw["records"]!.list
        let index = try XCTUnwrap(rows.firstIndex { $0.object["node_key"] == .string("a") })
        var row = rows[index].object; row["incarnation"] = .string(UUID().uuidString.lowercased()); rows[index] = .object(row); raw["records"] = .array(rows)
        let changed = try ChildTaskStructureRead(data: encode(raw), context: read.context)
        XCTAssertThrowsError(try opening.validate(changed)); XCTAssertThrowsError(try ChildTaskStructureOpening(read: read, node: "missing"))
        let oldMove = try ChildTaskStructureCommand(move: "a", parent: "b", index: 0, read: read)
        XCTAssertThrowsError(try ChildTaskStructureReview.fresh(oldMove, read: changed, parent: "b", index: 0))
    }
    @MainActor func testNativeOpeningRefusesRootGenerationAndProjectReplacement() throws {
        let captured = scope(try command()), read = try presentationRead(captured), opening = try ChildTaskStructureOpening(read: read)
        for key in ["task_generation", "project_id"] {
            var root = read.context.root, raw = try fixture()["fixtureRead"]!.object
            let replacement = JSON.string(UUID().uuidString.lowercased()); root[key] = replacement; raw[key] = replacement
            let context = try ChildTaskRecordContext(account: captured.account, origin: captured.origin, workspace: captured.workspace, session: captured.session, access: captured.access, snapshot: UUID(), root: root)
            let changed = try ChildTaskStructureRead(data: encode(raw), context: context)
            XCTAssertThrowsError(try opening.validate(changed), key)
        }
    }
    @MainActor func testNativeOpeningAllowsFreshReviewOfSameIncarnationAfterStructureChange() throws {
        let captured = scope(try command()), read = try presentationRead(captured), opening = try ChildTaskStructureOpening(read: read, node: "a")
        XCTAssertNoThrow(try opening.validate(presentationRead(captured, revision: 4)))
        XCTAssertThrowsError(try opening.validate(presentationRead(scope(command()))))
    }

    @MainActor private func continuationRead(_ captured: ChildTaskFieldClientScope, root: Record? = nil, change: (inout [String: JSON]) -> Void = { _ in }) throws -> ChildTaskRecordRead {
        var raw = try fixture()["fixtureRead"]!.object
        var original = try root ?? Record(fixture()["fixtureRoot"]!.object)
        raw["account"] = .string(captured.account); raw["task_id"] = .string(original.id)
        raw["task_generation"] = original["task_generation"]; raw["project_id"] = original["project_id"]
        change(&raw)
        func branch(_ parent: String?) -> JSON {
            let rows = raw["records"]!.list.map(\.object).filter { $0["parent_key"] == (parent.map(JSON.string) ?? .null) }.sorted { $0["sibling_order"]!.integer < $1["sibling_order"]!.integer }
            return .array(rows.map { row in
                var fields = row["fields"]!.object
                if row["children_kind"] == .string("array") { fields["subtasks"] = branch(row["node_key"]!.text) }
                else if row["children_kind"] == .string("null") { fields["subtasks"] = .null }
                return .object(fields)
            })
        }
        original["subtasks"] = raw["root_kind"] == .string("null") ? .null : branch(nil)
        let context = try ChildTaskRecordContext(account: captured.account, origin: captured.origin, workspace: captured.workspace, session: captured.session, access: captured.access, snapshot: UUID(), root: original)
        return try ChildTaskStructureRead(data: encode(raw), context: context).records
    }
    @MainActor func testFieldDraftContinuationFollowsIdentityAcrossSiblingReordering() throws {
        let captured = scope(try command()), before = try continuationRead(captured)
        let after = try continuationRead(captured) { raw in
            raw["structure_revision"] = .number(3); raw["projection_revision"] = .number(4)
            raw["records"] = .array(raw["records"]!.list.map { item in
                var row = item.object
                if row["node_key"] == .string("fresh") { row["sibling_order"] = .number(2) }
                if row["node_key"] == .string("b") { row["sibling_order"] = .number(0) }
                return .object(row)
            })
        }
        XCTAssertNotEqual(before.orderedNodes.map(\.key), after.orderedNodes.map(\.key))
        XCTAssertEqual(ChildTaskFieldDraftContinuation.retainedKeys(from: before, to: after), Set(before.nodes.keys))
    }
    @MainActor func testFieldDraftContinuationRejectsRecreatedRevisedAndChangedTargets() throws {
        let captured = scope(try command()), before = try continuationRead(captured)
        for variant in 0..<3 {
            let after = try continuationRead(captured) { raw in
                raw["records"] = .array(raw["records"]!.list.map { item in
                    var row = item.object; guard row["node_key"] == .string("a") else { return item }
                    if variant == 0 { row["incarnation"] = .string(UUID().uuidString.lowercased()) }
                    if variant == 1 { row["revision"] = .number(Double(row["revision"]!.integer + 1)) }
                    if variant == 2 { var fields = row["fields"]!.object; fields["title"] = .string("Changed elsewhere"); row["fields"] = .object(fields) }
                    return .object(row)
                })
            }
            let retained = ChildTaskFieldDraftContinuation.retainedKeys(from: before, to: after)
            XCTAssertFalse(retained.contains("a")); XCTAssertTrue(retained.contains("b"))
        }
    }
    @MainActor func testFieldDraftContinuationRefusesEveryScopeDeparture() throws {
        let captured = scope(try command()), before = try continuationRead(captured)
        let variants: [ChildTaskFieldClientScope] = [
            .init(account: UUID().uuidString.lowercased(), origin: captured.origin, workspace: captured.workspace, session: captured.session, access: captured.access),
            .init(account: captured.account, origin: "https://other.test", workspace: captured.workspace, session: captured.session, access: captured.access),
            .init(account: captured.account, origin: captured.origin, workspace: UUID(), session: captured.session, access: captured.access),
            .init(account: captured.account, origin: captured.origin, workspace: captured.workspace, session: UUID(), access: captured.access),
            .init(account: captured.account, origin: captured.origin, workspace: captured.workspace, session: captured.session, access: UUID())]
        for changed in variants { XCTAssertTrue(ChildTaskFieldDraftContinuation.retainedKeys(from: before, to: try continuationRead(changed)).isEmpty) }
    }
    @MainActor func testFieldDraftContinuationRefusesRootReplacementAndProjectTransfer() throws {
        let captured = scope(try command()), before = try continuationRead(captured)
        for field in ["id", "task_generation", "project_id"] {
            var root = before.context.root; root[field] = .string(UUID().uuidString.lowercased())
            XCTAssertTrue(ChildTaskFieldDraftContinuation.retainedKeys(from: before, to: try continuationRead(captured, root: root)).isEmpty)
        }
    }
    @MainActor func testFieldDraftContinuationPreservesExactTextAndExcludesRemovedNodes() throws {
        let captured = scope(try command())
        func read(_ title: String, remove: Bool = false) throws -> ChildTaskRecordRead {
            try continuationRead(captured) { raw in
                raw["records"] = .array(raw["records"]!.list.compactMap { item in
                    var row = item.object
                    if remove && row["node_key"] == .string("nested") { return nil }
                    if row["node_key"] == .string("a") { var fields = row["fields"]!.object; fields["title"] = .string(title); row["fields"] = .object(fields) }
                    return .object(row)
                })
            }
        }
        let before = try read("caf\u{00e9}"), after = try read("cafe\u{0301}", remove: true)
        let retained = ChildTaskFieldDraftContinuation.retainedKeys(from: before, to: after)
        XCTAssertFalse(retained.contains("a")); XCTAssertFalse(retained.contains("nested")); XCTAssertTrue(retained.contains("b"))
    }

}
