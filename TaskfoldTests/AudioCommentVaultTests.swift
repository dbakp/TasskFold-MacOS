import XCTest
import Darwin
@testable import TaskfoldCore

final class AudioCommentVaultTests: XCTestCase {
    struct InjectedFailure: Error {}
    var root: URL!
    let account = "11111111-1111-4111-8111-111111111111"
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-audio-vault-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    func vault(_ account: String? = nil) throws -> AudioCommentVault { try .init(applicationSupport: root, owner: .init(account ?? self.account)) }
    func clip() throws -> AudioCommentClip { try AudioCommentClip(data: Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "audio-comment-synthetic-tone", withExtension: "m4a", subdirectory: "Fixtures")))) }
    func draft(_ owner: AudioCommentOwner? = nil) throws -> AudioCommentSavedDraft {
        try .init(owner: owner ?? .init(account), target: .init(task: UUID(), generation: UUID(), project: nil), caption: "Keep cafe\u{301} 🪴\nReviewed wording", clip: clip())
    }
    func pending() throws -> AudioCommentPending {
        let draft = try draft()
        return try .init(publication: .init(account: UUID(uuidString: account)!, target: draft.target, caption: draft.caption, descriptor: draft.clip.descriptor), clip: draft.clip)
    }
    func draftFile(_ draft: AudioCommentSavedDraft, in vault: AudioCommentVault) -> URL { vault.directory.appendingPathComponent("draft-" + draft.id.uuidString.lowercased() + ".bin") }
    func testLocalReviewedRecordingSurvivesANewStoreInstanceWithExactCaption() throws {
        let file = try vault("local"), original = try draft(file.owner)
        try file.save(original)
        let restored = try vault("local").drafts()
        XCTAssertEqual(restored, [original]); XCTAssertTrue(restored[0].caption.utf8.elementsEqual(original.caption.utf8)); XCTAssertEqual(restored[0].clip.data, original.clip.data)
        XCTAssertThrowsError(try file.pending())
    }
    func testRawOwnerIsolationIncludesCanonicallyEquivalentNames() throws {
        let a = try vault("café"), b = try vault("cafe\u{301}")
        XCTAssertEqual(a.owner.account, b.owner.account); XCTAssertNotEqual(a.owner, b.owner); XCTAssertNotEqual(a.directory, b.directory)
        let original = try draft(a.owner); try a.save(original)
        XCTAssertEqual(try b.drafts(), [])
        XCTAssertThrowsError(try b.save(original))
        let copied = draftFile(original, in: b)
        try FileManager.default.copyItem(at: draftFile(original, in: a), to: copied)
        XCTAssertThrowsError(try b.drafts())
        XCTAssertEqual(try a.drafts(), [original])
    }
    func testDraftRevisionPreventsLostEditsAndSilentRetargeting() throws {
        let file = try vault(), original = try draft(); try file.save(original)
        let changed = try original.replacing(caption: "Changed", clip: original.clip)
        try file.save(changed, replacing: original.revision)
        let stale = try original.replacing(caption: "Stale edit", clip: original.clip)
        XCTAssertThrowsError(try file.save(stale, replacing: original.revision))
        let retargeted = try AudioCommentSavedDraft(owner: original.owner, target: .init(task: UUID(), generation: UUID(), project: nil), caption: changed.caption, clip: changed.clip, id: original.id)
        XCTAssertThrowsError(try file.save(retargeted, replacing: changed.revision))
        XCTAssertEqual(try file.drafts(), [changed])
    }
    func testUnchangedDraftAndRetryDoNotMintAnotherRevision() throws {
        let file = try vault(), original = try draft(); try file.save(original)
        XCTAssertEqual(try original.replacing(caption: original.caption, clip: original.clip), original)
        try file.save(original); try file.save(original, replacing: UUID())
        XCTAssertEqual(try file.drafts(), [original])
        let rawChange = try original.replacing(caption: "Keep café 🪴\nReviewed wording", clip: original.clip)
        XCTAssertEqual(rawChange.caption, original.caption); XCTAssertNotEqual(rawChange.revision, original.revision)
    }
    func testFailureBeforeRenameKeepsPriorDraftAndRemovesOnlyOwnedStage() throws {
        var file = try vault(); let original = try draft(); try file.save(original)
        let changed = try original.replacing(caption: "New", clip: original.clip)
        file.fault = { if $0 == .beforeRename { throw InjectedFailure() } }
        XCTAssertThrowsError(try file.save(changed, replacing: original.revision))
        XCTAssertEqual(try vault().drafts(), [original])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: file.directory.path).contains { $0.hasPrefix(".write-") })
    }
    func testUncertainRenameCanRetryExactDraftWithoutDuplicateOrOverwrite() throws {
        var file = try vault(); let original = try draft(); try file.save(original)
        let changed = try original.replacing(caption: "Saved before lost acknowledgement", clip: original.clip)
        file.fault = { if $0 == .afterRename { throw InjectedFailure() } }
        XCTAssertThrowsError(try file.save(changed, replacing: original.revision))
        let fresh = try vault(); XCTAssertEqual(try fresh.drafts(), [changed])
        try fresh.save(changed, replacing: original.revision)
        XCTAssertEqual(try fresh.drafts(), [changed])
    }
    func testPendingIsImmutableAndWrongAccountCannotWriteOrSettleIt() throws {
        let file = try vault(), original = try pending(); try file.store(original)
        let p = original.publication
        let changed = try AudioCommentPublication(account: p.account, target: p.target, caption: p.caption + " changed", descriptor: p.descriptor, operation: p.operation, comment: p.comment, asset: p.asset)
        XCTAssertThrowsError(try file.store(.init(publication: changed, clip: original.clip)))
        XCTAssertThrowsError(try file.removeSettled(changed))
        XCTAssertThrowsError(try vault(UUID().uuidString).store(original))
        XCTAssertThrowsError(try vault(UUID().uuidString).removeSettled(p))
        XCTAssertTrue(try file.pending()[0].publication.sameIntent(as: p))
    }
    func testUncertainPendingSaveRecoversExactlyOneOperationAndAudio() throws {
        var file = try vault(); let original = try pending()
        file.fault = { if $0 == .afterRename { throw InjectedFailure() } }
        XCTAssertThrowsError(try file.store(original))
        let fresh = try vault(); try fresh.store(original)
        let restored = try fresh.pending(); XCTAssertEqual(restored.count, 1)
        XCTAssertTrue(restored[0].publication.sameIntent(as: original.publication)); XCTAssertEqual(restored[0].clip.data, original.clip.data)
        try fresh.removeSettled(original.publication); try fresh.removeSettled(original.publication)
        XCTAssertTrue(try fresh.pending().isEmpty)
    }
    func testDiscardRequiresCurrentRevisionAndNeverRemovesPending() throws {
        let file = try vault(), original = try draft(), publication = try pending()
        try file.save(original); try file.store(publication)
        XCTAssertThrowsError(try file.discardDraft(original.id, revision: UUID()))
        XCTAssertEqual(try file.drafts(), [original]); XCTAssertEqual(try file.pending().count, 1)
        try file.discardDraft(original.id, revision: original.revision); try file.discardDraft(original.id, revision: original.revision)
        XCTAssertTrue(try file.drafts().isEmpty); XCTAssertEqual(try file.pending().count, 1)
    }
    func testProcessLockIsNonblockingAndLeavesTheCurrentDraftIntact() throws {
        let file = try vault(), original = try draft(); try file.save(original)
        let fd = Darwin.open(file.directory.appendingPathComponent(".lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { Darwin.close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try file.save(original)) { XCTAssertEqual(($0 as? AudioCommentStorageFailure)?.message, AudioCommentStorageFailure.busy.message) }
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        XCTAssertEqual(try file.drafts(), [original])
    }
    func testRootAndAccountSymlinksRefuseWithoutTouchingOtherFolder() throws {
        let foreign = root.appendingPathComponent("foreign", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        let privateRoot = root.appendingPathComponent("AudioCommentsPrivate", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: privateRoot, withDestinationURL: foreign)
        XCTAssertThrowsError(try vault().save(draft()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: foreign.path).isEmpty)
        try FileManager.default.removeItem(at: privateRoot)
        let file = try vault(); _ = try file.drafts()
        try FileManager.default.removeItem(at: file.directory)
        try FileManager.default.createSymbolicLink(at: file.directory, withDestinationURL: foreign)
        XCTAssertThrowsError(try file.save(draft()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: foreign.path).isEmpty)
    }
    func testSymlinkAndHardLinkedDraftsAreNeverFollowedOrReplaced() throws {
        let file = try vault(), original = try draft(); _ = try file.drafts()
        let external = root.appendingPathComponent("other.bin"), bytes = Data("do not overwrite".utf8)
        try bytes.write(to: external)
        let path = draftFile(original, in: file)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: external)
        XCTAssertThrowsError(try file.save(original)); XCTAssertThrowsError(try file.drafts())
        XCTAssertEqual(try Data(contentsOf: external), bytes)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.linkItem(at: external, to: path)
        XCTAssertThrowsError(try file.save(original)); XCTAssertThrowsError(try file.drafts())
        XCTAssertEqual(try Data(contentsOf: external), bytes)
    }
    func testCorruptDraftIsPreservedRatherThanReplacedByAnEmptyList() throws {
        let file = try vault(), original = try draft(); try file.save(original)
        let path = draftFile(original, in: file), bytes = Data("incomplete audio".utf8)
        try bytes.write(to: path)
        XCTAssertThrowsError(try file.drafts()); XCTAssertThrowsError(try file.save(original)); XCTAssertThrowsError(try file.discardDraft(original.id, revision: original.revision))
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }
    func testEntryQuotaRefusesWholeNewDraftAndRecoversAfterReviewedDiscard() throws {
        let file = try vault(); var originals: [AudioCommentSavedDraft] = []
        for _ in 0..<AudioCommentVault.maximumEntries { let entry = try draft(); try file.save(entry); originals.append(entry) }
        let extra = try draft(); XCTAssertThrowsError(try file.save(extra))
        XCTAssertEqual(Set(try file.drafts().map(\.id)), Set(originals.map(\.id)))
        try file.discardDraft(originals[0].id, revision: originals[0].revision)
        try file.save(extra); XCTAssertEqual(try file.drafts().count, AudioCommentVault.maximumEntries)
    }
    func testSparseOversizedFileRefusesBeforeReadingPayload() throws {
        let file = try vault(), original = try draft(); _ = try file.drafts()
        let path = draftFile(original, in: file)
        let fd = Darwin.open(path.path, O_CREAT | O_WRONLY, 0o600); XCTAssertGreaterThanOrEqual(fd, 0); defer { Darwin.close(fd) }
        XCTAssertEqual(ftruncate(fd, off_t(AudioCommentVault.maximumFileBytes + 1)), 0)
        XCTAssertThrowsError(try file.drafts()); XCTAssertThrowsError(try file.save(original))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.intValue, AudioCommentVault.maximumFileBytes + 1)
    }
    func testAggregateByteQuotaIncludesInterruptedStagingFiles() throws {
        let file = try vault(); _ = try file.drafts()
        for _ in 0..<7 {
            let path = file.directory.appendingPathComponent(".write-" + UUID().uuidString.lowercased())
            let fd = Darwin.open(path.path, O_CREAT | O_WRONLY, 0o600); XCTAssertGreaterThanOrEqual(fd, 0)
            XCTAssertEqual(ftruncate(fd, off_t(AudioCommentVault.maximumFileBytes)), 0); Darwin.close(fd)
        }
        XCTAssertThrowsError(try file.save(draft())) { XCTAssertEqual(($0 as? AudioCommentStorageFailure)?.message, AudioCommentStorageFailure.full.message) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.directory.path).filter { $0.hasPrefix(".write-") }.count, 7)
    }
    func testFileAndDirectoryPermissionsArePrivate() throws {
        let file = try vault(), original = try draft(); try file.save(original)
        for (path, permissions) in [(file.directory, 0o700), (draftFile(original, in: file), 0o600), (file.directory.appendingPathComponent(".lock"), 0o600)] {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue, permissions)
        }
    }
    func testRenamedPayloadCannotMasqueradeAsAnotherDraftOrOperation() throws {
        let file = try vault(), original = try draft(); try file.save(original)
        let renamed = file.directory.appendingPathComponent("draft-" + UUID().uuidString.lowercased() + ".bin")
        try FileManager.default.moveItem(at: draftFile(original, in: file), to: renamed)
        XCTAssertThrowsError(try file.drafts())
        let pending = try pending(); try FileManager.default.removeItem(at: renamed); try file.store(pending)
        let source = file.directory.appendingPathComponent("pending-" + pending.publication.operation.uuidString.lowercased() + ".bin")
        try FileManager.default.moveItem(at: source, to: file.directory.appendingPathComponent("pending-" + UUID().uuidString.lowercased() + ".bin"))
        XCTAssertThrowsError(try file.pending())
    }
    func stage(_ data: Data, in file: AudioCommentVault) throws -> URL {
        _ = try file.drafts()
        let path = file.directory.appendingPathComponent(".write-" + UUID().uuidString.lowercased())
        try data.write(to: path); return path
    }
    func testCompleteInterruptedLocalReviewCanRecoverWithoutCloudIdentity() throws {
        let file = try vault("local"), original = try draft(file.owner)
        let path = try stage(original.encoded(), in: file)
        XCTAssertTrue(try file.drafts().isEmpty)
        let candidates = try file.interruptedWrites(); XCTAssertEqual(candidates.count, 1)
        guard case .draft(let recovered) = candidates[0].payload else { return XCTFail("Expected local review") }
        XCTAssertEqual(recovered, original)
        try file.recover(candidates[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(try vault("local").drafts(), [original]); XCTAssertTrue(try file.interruptedWrites().isEmpty)
    }
    func testInterruptedUpdateNeedsReviewedCurrentRevisionAndDoesNotHideSavedWork() throws {
        let file = try vault(), original = try draft(); try file.save(original)
        let updated = try original.replacing(caption: "Recovered wording", clip: original.clip)
        let path = try stage(updated.encoded(), in: file)
        XCTAssertEqual(try file.drafts(), [original])
        let candidate = try XCTUnwrap(file.interruptedWrites().first)
        XCTAssertThrowsError(try file.recover(candidate))
        XCTAssertThrowsError(try file.recover(candidate, replacing: UUID()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path)); XCTAssertEqual(try file.drafts(), [original])
        try file.recover(candidate, replacing: original.revision)
        XCTAssertEqual(try file.drafts(), [updated]); XCTAssertTrue(try file.interruptedWrites().isEmpty)
    }
    func testInterruptedPendingPromotesSameOperationAndDeduplicatesAnIdenticalStage() throws {
        let file = try vault(), original = try pending()
        _ = try stage(original.encoded(), in: file)
        try file.recover(XCTUnwrap(file.interruptedWrites().first))
        XCTAssertEqual(try file.pending().count, 1)
        XCTAssertTrue(try file.pending()[0].publication.sameIntent(as: original.publication))
        _ = try stage(original.encoded(), in: file)
        try file.recover(XCTUnwrap(file.interruptedWrites().first))
        XCTAssertEqual(try file.pending().count, 1); XCTAssertTrue(try file.interruptedWrites().isEmpty)
    }
    func testIncompleteStageRemainsRecoverableWithoutHidingTheSavedDraft() throws {
        let file = try vault(), original = try draft(); try file.save(original)
        let bytes = Data("partial write".utf8), path = try stage(bytes, in: file)
        XCTAssertThrowsError(try file.interruptedWrites())
        XCTAssertEqual(try file.drafts(), [original]); XCTAssertEqual(try Data(contentsOf: path), bytes)
    }
    func testChangedStageCannotReplaceAnAlreadyReviewedRecovery() throws {
        let file = try vault(), original = try draft()
        let path = try stage(original.encoded(), in: file)
        let candidate = try XCTUnwrap(file.interruptedWrites().first)
        let changed = try original.replacing(caption: "Changed after review", clip: original.clip)
        let changedBytes = try changed.encoded(); try changedBytes.write(to: path)
        XCTAssertThrowsError(try file.recover(candidate))
        XCTAssertTrue(try file.drafts().isEmpty); XCTAssertEqual(try Data(contentsOf: path), changedBytes)
    }

    func testActorStorageRoundTripUsesIndependentAccountAndCurrentRevision() async throws {
        let owner = try AudioCommentOwner(account), original = try draft()
        let store = AudioCommentDraftStorage(applicationSupport: root, owner: owner)
        try await store.save(original)
        let loaded = try await store.drafts(); XCTAssertEqual(loaded, [original])
        let changed = try original.replacing(caption: "Actor save", clip: original.clip)
        try await store.save(changed, replacing: original.revision)
        let reloaded = try await store.drafts(); XCTAssertEqual(reloaded, [changed])
        let publication = try pending(); try await store.store(publication)
        let sent = try await store.pending(); XCTAssertEqual(sent.count, 1)
        try await store.removeSettled(publication.publication)
        try await store.discardDraft(changed.id, revision: changed.revision)
        let empty = try await store.drafts(); XCTAssertTrue(empty.isEmpty)
        let emptyPending = try await store.pending(); XCTAssertTrue(emptyPending.isEmpty)
    }

    func testRecoveryCopiesHaveSeparateStrictNamespaceAndNeverReplaceSavedDrafts() throws {
        let file = try vault("local"), original = try draft(file.owner)
        try file.save(original)
        let review = try original.replacing(caption: "Unsaved review", clip: original.clip)
        try file.save(review, recovery: true)
        XCTAssertEqual(try file.drafts(), [original])
        XCTAssertEqual(try file.drafts(recovery: true), [review])
        XCTAssertThrowsError(try AudioCommentSavedDraft(encoded: review.encoded(recovery: true), owner: file.owner))
        XCTAssertThrowsError(try AudioCommentSavedDraft(encoded: original.encoded(), owner: file.owner, recovery: true))
        try file.discardDraft(review.id, revision: review.revision, recovery: true)
        XCTAssertEqual(try file.drafts(), [original]); XCTAssertTrue(try file.drafts(recovery: true).isEmpty)
    }
    func testRecoveryRevisionsRefuseStaleReplacementAndDeletion() throws {
        let file = try vault(), initial = try draft(); try file.save(initial, recovery: true)
        let newer = try initial.replacing(caption: "New recovery", clip: initial.clip)
        try file.save(newer, replacing: initial.revision, recovery: true)
        XCTAssertThrowsError(try file.save(initial, replacing: initial.revision, recovery: true))
        XCTAssertThrowsError(try file.discardDraft(initial.id, revision: initial.revision, recovery: true))
        XCTAssertEqual(try file.drafts(recovery: true), [newer])
    }
    func testRecoveryLostAcknowledgementRetriesExactRevision() throws {
        var file = try vault(); let initial = try draft()
        file.fault = { if $0 == .afterRename { throw InjectedFailure() } }
        XCTAssertThrowsError(try file.save(initial, recovery: true))
        XCTAssertEqual(try vault().drafts(recovery: true), [initial])
        try file.save(initial, recovery: true)
        XCTAssertEqual(try file.drafts(recovery: true), [initial]); XCTAssertTrue(try file.drafts().isEmpty)
    }
    func testRecoveryInterruptedStageRestoresOnlyToRecoveryNamespace() throws {
        let file = try vault("local"), review = try draft(file.owner)
        _ = try file.drafts()
        let id = UUID(), stage = file.directory.appendingPathComponent(".write-" + id.uuidString.lowercased())
        try review.encoded(recovery: true).write(to: stage)
        let candidates = try file.interruptedWrites()
        XCTAssertEqual(candidates.count, 1)
        guard case .review(let recovered) = candidates[0].payload else { return XCTFail("Expected a recovery copy") }
        XCTAssertEqual(recovered, review)
        try file.recover(candidates[0])
        XCTAssertTrue(try file.drafts().isEmpty)
        XCTAssertEqual(try file.drafts(recovery: true), [review])
    }
    func testRecoverySharesAccountQuotaAndDoesNotReplaceAnotherAccount() throws {
        let file = try vault(), initial = try draft()
        for _ in 0..<AudioCommentVault.maximumEntries {
            let item = try AudioCommentSavedDraft(owner: file.owner, target: initial.target, caption: "Review", clip: initial.clip)
            try file.save(item, recovery: true)
        }
        XCTAssertThrowsError(try file.save(initial)) { XCTAssertEqual($0 as? AudioCommentStorageFailure, .full) }
        let other = try vault("other")
        XCTAssertTrue(try other.drafts(recovery: true).isEmpty)
        XCTAssertThrowsError(try other.save(initial, recovery: true))
        XCTAssertEqual(try file.drafts(recovery: true).count, AudioCommentVault.maximumEntries)
    }
    func testCorruptRecoveryRefusesWithoutHidingOrReplacingSavedDraft() throws {
        let file = try vault(), initial = try draft(); try file.save(initial)
        let url = file.directory.appendingPathComponent("review-" + UUID().uuidString.lowercased() + ".bin")
        try Data("corrupt".utf8).write(to: url)
        XCTAssertThrowsError(try file.drafts(recovery: true))
        XCTAssertEqual(try file.drafts(), [initial])
        XCTAssertEqual(try Data(contentsOf: url), Data("corrupt".utf8))
    }

    func testExplicitRecoveryDiscardNeedsNoFreeQuotaAndKeepsEverySavedDraft() throws {
        let file = try vault(), review = try draft()
        var saved: [AudioCommentSavedDraft] = []
        for _ in 0..<AudioCommentVault.maximumEntries {
            let item = try draft(); try file.save(item); saved.append(item)
        }
        XCTAssertThrowsError(try file.save(review, recovery: true))
        try file.discardReviewCopies([review])
        XCTAssertEqual(try file.drafts(), saved.sorted { $0.id.uuidString < $1.id.uuidString })
        XCTAssertTrue(try file.drafts(recovery: true).isEmpty)
    }
    func testExplicitRecoveryDiscardAcceptsOnlyExactPossibleCommitAndLeavesChangedBytes() throws {
        let file = try vault(), original = try draft(); try file.save(original, recovery: true)
        let attempted = try original.replacing(caption: "Uncertain replacement", clip: original.clip)
        let other = try original.replacing(caption: "Other window", clip: original.clip)
        try file.save(other, replacing: original.revision, recovery: true)
        XCTAssertThrowsError(try file.discardReviewCopies([original, attempted]))
        XCTAssertEqual(try file.drafts(recovery: true), [other])
        try file.discardReviewCopies([attempted, other])
        XCTAssertTrue(try file.drafts(recovery: true).isEmpty)
        XCTAssertThrowsError(try file.discardReviewCopies([]))
        XCTAssertThrowsError(try file.discardReviewCopies([try draft(), try draft()]))
    }

}
