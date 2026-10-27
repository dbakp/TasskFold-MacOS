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

    func saveIntent(_ next: AudioCommentSavedDraft, base: UUID? = nil, copies: [AudioCommentSavedDraft] = []) throws -> AudioCommentSaveIntent {
        try .init(next: next, base: base, reviews: copies.map(AudioCommentReviewReference.init))
    }
    func testSaveIntentStrictRoundTripAndWrongOwnerRefusal() throws {
        let next = try draft(), intent = try saveIntent(next)
        XCTAssertEqual(try AudioCommentSaveIntent(encoded: intent.encoded(), owner: next.owner), intent)
        XCTAssertThrowsError(try AudioCommentSaveIntent(encoded: intent.encoded(), owner: .init("other")))
        var fields = try XCTUnwrap(PropertyListSerialization.propertyList(from: intent.encoded(), format: nil) as? [String: Any])
        fields["unexpected"] = "refuse"
        let unknown = try PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0)
        XCTAssertThrowsError(try AudioCommentSaveIntent(encoded: unknown, owner: next.owner))
        let ref = AudioCommentReviewReference(next)
        XCTAssertThrowsError(try AudioCommentSaveIntent(next: next, base: nil, reviews: [ref, ref]))
        XCTAssertThrowsError(try AudioCommentSaveIntent(next: next, base: AudioCommentTarget.zero, reviews: []))
    }
    func testPreparedSaveResumesExactIdentityBeforePrimaryWrite() throws {
        var file = try vault(); let next = try draft(), intent = try saveIntent(next)
        file.fault = { if $0 == .afterSaveJournal { throw InjectedFailure() } }
        XCTAssertThrowsError(try file.commitSave(intent))
        XCTAssertEqual(try vault().saves(), [intent]); XCTAssertTrue(try vault().drafts().isEmpty)
        try vault().commitSave(try XCTUnwrap(vault().saves().first))
        XCTAssertEqual(try vault().drafts(), [next]); XCTAssertTrue(try vault().saves().isEmpty)
        try vault().commitSave(intent)
        XCTAssertEqual(try vault().drafts(), [next])
    }
    func testLostPrimaryAcknowledgementResumesWithoutDuplicateAndSettlesRecovery() throws {
        var file = try vault(); let review = try draft(); try file.save(review, recovery: true)
        let next = try AudioCommentSavedDraft(owner: review.owner, target: review.target, caption: review.caption, clip: review.clip)
        let intent = try saveIntent(next, copies: [review])
        file.fault = { if $0 == .afterDraftCommit { throw InjectedFailure() } }
        XCTAssertThrowsError(try file.commitSave(intent))
        XCTAssertEqual(try vault().drafts(), [next]); XCTAssertEqual(try vault().saves(), [intent]); XCTAssertEqual(try vault().drafts(recovery: true), [review])
        try file.commitSave(intent)
        XCTAssertEqual(try vault().drafts(), [next]); XCTAssertTrue(try vault().saves().isEmpty); XCTAssertTrue(try vault().drafts(recovery: true).isEmpty)
    }
    func testConflictCopyReplacesOneJournalAtomicallyAndSurvivesAnotherInterruption() throws {
        var file = try vault(); let original = try draft(); try file.save(original)
        let next = try original.replacing(caption: "My review", clip: original.clip), intent = try saveIntent(next, base: original.revision)
        let concurrent = try original.replacing(caption: "Other window", clip: original.clip); try file.save(concurrent, replacing: original.revision)
        XCTAssertThrowsError(try file.commitSave(intent)); XCTAssertEqual(try file.saves(), [intent])
        let copy = try intent.separateCopy()
        file.fault = { if $0 == .afterSaveJournal { throw InjectedFailure() } }
        XCTAssertThrowsError(try file.commitSave(copy, replacing: intent))
        XCTAssertEqual(try vault().saves(), [copy]); XCTAssertEqual(try vault().drafts(), [concurrent])
        try vault().commitSave(copy)
        let items = try vault().drafts()
        XCTAssertEqual(items.count, 2); XCTAssertTrue(items.contains(concurrent)); XCTAssertTrue(items.contains(copy.next)); XCTAssertTrue(try vault().saves().isEmpty)
    }
    func testJournalIdentityCannotBeSilentlyReboundOrRetargeted() throws {
        var file = try vault(); let next = try draft(), intent = try saveIntent(next)
        file.fault = { if $0 == .afterSaveJournal { throw InjectedFailure() } }
        XCTAssertThrowsError(try file.commitSave(intent))
        let changed = try next.replacing(caption: "Different request", clip: next.clip)
        let other = try AudioCommentSaveIntent(next: changed, base: nil, reviews: [], id: intent.id)
        XCTAssertThrowsError(try vault().commitSave(other))
        XCTAssertEqual(try vault().saves(), [intent]); XCTAssertTrue(try vault().drafts().isEmpty)
        XCTAssertThrowsError(try vault("other").commitSave(intent))
    }
    func testQuotaAfterPrepareRetainsIntentAndCanFinishAfterSpaceIsFreed() throws {
        let file = try vault(); var earlier: [AudioCommentSavedDraft] = []
        for _ in 0..<(AudioCommentVault.maximumEntries - 1) { let item = try draft(); try file.save(item); earlier.append(item) }
        let intent = try saveIntent(draft())
        XCTAssertThrowsError(try file.commitSave(intent)) { XCTAssertEqual($0 as? AudioCommentStorageFailure, .unconfirmedSave) }
        XCTAssertEqual(try file.saves(), [intent]); XCTAssertEqual(try file.drafts().count, earlier.count)
        try file.discardDraft(earlier[0].id, revision: earlier[0].revision)
        try file.commitSave(intent)
        XCTAssertTrue(try file.saves().isEmpty); XCTAssertTrue(try file.drafts().contains(intent.next)); XCTAssertEqual(try file.drafts().count, earlier.count)
    }
    func testSaveCleanupPreservesAnotherReviewRevision() throws {
        var file = try vault(); let review = try draft(); try file.save(review, recovery: true)
        let next = try AudioCommentSavedDraft(owner: review.owner, target: review.target, caption: review.caption, clip: review.clip)
        let intent = try saveIntent(next, copies: [review])
        file.fault = { if $0 == .afterSaveJournal { throw InjectedFailure() } }
        XCTAssertThrowsError(try file.commitSave(intent))
        let changed = try review.replacing(caption: "Newer independent review", clip: review.clip)
        try vault().save(changed, replacing: review.revision, recovery: true)
        try vault().commitSave(intent)
        XCTAssertEqual(try vault().drafts(recovery: true), [changed]); XCTAssertEqual(try vault().drafts(), [next])
    }
    func testPendingSavePreventsDeletionUntilItsExactCommitFinishes() throws {
        var file = try vault(); let next = try draft(), intent = try saveIntent(next)
        file.fault = { if $0 == .afterDraftCommit { throw InjectedFailure() } }
        XCTAssertThrowsError(try file.commitSave(intent))
        XCTAssertThrowsError(try vault().discardDraft(next.id, revision: next.revision))
        XCTAssertEqual(try vault().drafts(), [next])
        try vault().commitSave(intent); try vault().discardDraft(next.id, revision: next.revision)
        XCTAssertTrue(try vault().drafts().isEmpty)
    }
    func testInterruptedLocalSaveJournalRecoversWithoutPublishingOrSavingImplicitly() throws {
        let file = try vault("local"), next = try draft(file.owner), intent = try saveIntent(next)
        _ = try file.drafts()
        let stage = file.directory.appendingPathComponent(".write-" + UUID().uuidString.lowercased())
        try intent.encoded().write(to: stage)
        let items = try file.interruptedWrites(); XCTAssertEqual(items.count, 1)
        guard case .save(let restored) = items[0].payload else { return XCTFail("Expected a local Save intent") }
        XCTAssertEqual(restored, intent); try file.recover(items[0])
        XCTAssertTrue(try file.drafts().isEmpty); XCTAssertEqual(try file.saves(), [intent])
        try file.commitSave(intent); XCTAssertEqual(try file.drafts(), [next]); XCTAssertTrue(try file.saves().isEmpty)
    }
    func testCorruptSaveJournalRefusesWithoutReplacingExistingSavedWork() throws {
        let file = try vault(), next = try draft(); try file.save(next)
        let url = file.directory.appendingPathComponent("save-" + UUID().uuidString.lowercased() + ".bin")
        let bytes = Data("corrupt save authorization".utf8); try bytes.write(to: url)
        XCTAssertThrowsError(try file.saves()); XCTAssertEqual(try file.drafts(), [next]); XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testSaveStateAndStaleResumeDoNotResurrectAnExplicitlyDeletedDraft() throws {
        var file = try vault(); let next = try draft(), intent = try saveIntent(next)
        XCTAssertEqual(try file.saveState(intent), .unprepared)
        file.fault = { if $0 == .afterDraftCommit { throw InjectedFailure() } }
        XCTAssertThrowsError(try file.commitSave(intent))
        XCTAssertEqual(try vault().saveState(intent), .prepared)
        try vault().commitSave(intent, existingOnly: true)
        XCTAssertEqual(try vault().saveState(intent), .settled)
        try vault().commitSave(intent, existingOnly: true)
        try vault().discardDraft(next.id, revision: next.revision)
        XCTAssertEqual(try vault().saveState(intent), .unprepared)
        XCTAssertThrowsError(try vault().commitSave(intent, existingOnly: true))
        XCTAssertTrue(try vault().drafts().isEmpty); XCTAssertTrue(try vault().saves().isEmpty)
    }

    func rootedReview(_ file: AudioCommentVault) throws -> AudioCommentSavedDraft {
        let root = try draft(file.owner); try file.save(root, recovery: true); return root
    }
    func rootedIntent(_ root: AudioCommentSavedDraft, caption: String? = nil) throws -> AudioCommentSaveIntent {
        let next = try AudioCommentSavedDraft(owner: root.owner, target: root.target, caption: caption ?? root.caption, clip: root.clip, origin: .init(root))
        return try saveIntent(next, copies: [root])
    }
    func testSecondEditorReusesDurableReceiptWithoutAnotherDraft() throws {
        let file = try vault(), root = try rootedReview(file), a = try rootedIntent(root), b = try rootedIntent(root)
        let winner = try file.commitSave(a), joined = try file.commitSave(b)
        XCTAssertEqual(winner, joined); XCTAssertNotEqual(joined.id, b.next.id)
        XCTAssertEqual(try file.drafts(), [winner]); XCTAssertTrue(try file.saves().isEmpty)
    }
    func testSecondEditorRedirectsToPreparedOperationAndFinishesItsIDs() throws {
        var file = try vault(); let root = try rootedReview(file), a = try rootedIntent(root), b = try rootedIntent(root)
        file.fault = { if $0 == .afterSaveJournal { throw InjectedFailure() } }
        XCTAssertThrowsError(try file.commitSave(a))
        var redirected: AudioCommentSaveIntent?
        XCTAssertThrowsError(try vault().commitSave(b)) { redirected = ($0 as? AudioCommentSaveRedirect)?.intent }
        XCTAssertEqual(redirected, a); XCTAssertEqual(try vault().saves(), [a])
        let saved = try vault().commitSave(XCTUnwrap(redirected), existingOnly: true)
        XCTAssertEqual(saved, a.next); XCTAssertEqual(try vault().drafts(), [a.next])
    }
    func testDifferentEditedReviewRequiresDeliberateDetachedCopy() throws {
        let file = try vault(), root = try rootedReview(file), first = try rootedIntent(root)
        try file.commitSave(first)
        let changed = try rootedIntent(root, caption: "Different version")
        XCTAssertThrowsError(try file.commitSave(changed)) { XCTAssertEqual($0 as? AudioCommentStorageFailure, .reviewClaimed) }
        XCTAssertTrue(try file.saves().isEmpty)
        let copy = try changed.separateCopy(); XCTAssertNil(copy.next.origin)
        try file.commitSave(copy)
        XCTAssertEqual(try file.drafts().count, 2); XCTAssertTrue(try file.drafts().contains(first.next)); XCTAssertTrue(try file.drafts().contains(copy.next))
    }
    func testConsumedReviewCannotResurrectAfterWinningDraftIsDeleted() throws {
        let file = try vault(), root = try rootedReview(file), first = try rootedIntent(root), stale = try rootedIntent(root)
        try file.commitSave(first); try file.discardDraft(first.next.id, revision: first.next.revision)
        XCTAssertThrowsError(try file.commitSave(stale)) { XCTAssertEqual($0 as? AudioCommentStorageFailure, .reviewClaimed) }
        XCTAssertTrue(try file.drafts().isEmpty); XCTAssertTrue(try file.saves().isEmpty)
    }
    func testReceiptProvenanceSurvivesLegitimateSavedDraftEditing() throws {
        let file = try vault(), root = try rootedReview(file), first = try rootedIntent(root)
        try file.commitSave(first)
        let edited = try first.next.replacing(caption: "Edited saved recording", clip: first.next.clip)
        XCTAssertEqual(edited.origin, first.next.origin)
        try file.commitSave(saveIntent(edited, base: first.next.revision))
        XCTAssertEqual(try file.drafts(), [edited])
        XCTAssertThrowsError(try file.commitSave(rootedIntent(root)))
    }
    func testCatalogDeduplicatesClonesAndTrimsOnlyExactlyCoveredCopies() throws {
        let file = try vault(), root = try rootedReview(file)
        let clone = try AudioCommentSavedDraft(owner: root.owner, target: root.target, caption: root.caption, clip: root.clip, origin: .init(root))
        let changed = try clone.replacing(caption: "Keep independent edited work", clip: clone.clip)
        try file.save(clone, recovery: true)
        XCTAssertEqual(try file.catalog(target: root.target).reviews.count, 1)
        try file.save(changed, replacing: clone.revision, recovery: true)
        XCTAssertEqual(try file.catalog(target: root.target).reviews.count, 2)
        try file.commitSave(rootedIntent(root))
        XCTAssertEqual(try file.catalog(target: root.target).reviews, [changed])
        XCTAssertEqual(try file.drafts(recovery: true), [changed])
    }
    func testCatalogShowsOnePendingCardInsteadOfDuplicateSavedCard() throws {
        var file = try vault(); let root = try rootedReview(file), intent = try rootedIntent(root)
        file.fault = { if $0 == .afterDraftCommit { throw InjectedFailure() } }
        XCTAssertThrowsError(try file.commitSave(intent))
        let catalog = try vault().catalog(target: root.target)
        XCTAssertEqual(catalog.saves, [intent]); XCTAssertTrue(catalog.drafts.isEmpty); XCTAssertTrue(catalog.reviews.isEmpty)
        XCTAssertEqual(try vault().drafts(), [intent.next])
    }
    func testDiscardingIntentSurvivesLostAcknowledgementAndRejectsStaleSave() throws {
        var file = try vault(); let root = try rootedReview(file), intent = try rootedIntent(root)
        file.fault = { if $0 == .afterSaveJournal || $0 == .afterDiscardJournal { throw InjectedFailure() } }
        XCTAssertThrowsError(try file.commitSave(intent))
        XCTAssertThrowsError(try file.discardSave(intent))
        let pending = try XCTUnwrap(vault().saves().first)
        XCTAssertEqual(pending.phase, .discarding); XCTAssertTrue(pending.sameAuthorization(as: intent))
        XCTAssertThrowsError(try vault().commitSave(intent, existingOnly: true)) { XCTAssertEqual($0 as? AudioCommentStorageFailure, .discardPending) }
        XCTAssertTrue(try vault().drafts().isEmpty)
        try vault().discardSave(pending)
        XCTAssertTrue(try vault().saves().isEmpty); XCTAssertTrue(try vault().drafts(recovery: true).isEmpty); XCTAssertTrue(try vault().drafts().isEmpty)
    }
    func testDiscardUnfinishedReplacementKeepsExactEarlierSavedDraft() throws {
        var file = try vault(); let old = try draft(); try file.save(old)
        let review = try old.replacing(caption: "Unfinished edit", clip: old.clip); try file.save(review, recovery: true)
        let intent = try saveIntent(review, base: old.revision, copies: [review])
        file.fault = { if $0 == .afterSaveJournal { throw InjectedFailure() } }
        XCTAssertThrowsError(try file.commitSave(intent)); try vault().discardSave(intent)
        XCTAssertEqual(try vault().drafts(), [old]); XCTAssertTrue(try vault().saves().isEmpty); XCTAssertTrue(try vault().drafts(recovery: true).isEmpty)
    }
    func testDiscardCannotDeleteARecordingThatAlreadyCommitted() throws {
        var file = try vault(); let next = try draft(), intent = try saveIntent(next)
        file.fault = { if $0 == .afterDraftCommit { throw InjectedFailure() } }
        XCTAssertThrowsError(try file.commitSave(intent))
        XCTAssertThrowsError(try vault().discardSave(intent)) { XCTAssertEqual($0 as? AudioCommentStorageFailure, .alreadySaved) }
        XCTAssertEqual(try vault().drafts(), [next]); XCTAssertEqual(try vault().saves(), [intent])
        try vault().commitSave(intent, existingOnly: true); XCTAssertEqual(try vault().drafts(), [next])
    }
    func testFullPendingQuotaCanBeFreedByDiscardWithoutAnotherEntry() throws {
        var file = try vault(); file.fault = { if $0 == .afterSaveJournal { throw InjectedFailure() } }
        var intents: [AudioCommentSaveIntent] = []
        for _ in 0..<AudioCommentVault.maximumEntries { let intent = try saveIntent(draft()); XCTAssertThrowsError(try file.commitSave(intent)); intents.append(intent) }
        XCTAssertEqual(try vault().saves().count, AudioCommentVault.maximumEntries)
        try vault().discardSave(intents[0])
        for intent in intents.dropFirst() { try vault().commitSave(intent, existingOnly: true) }
        XCTAssertTrue(try vault().saves().isEmpty); XCTAssertEqual(try vault().drafts().count, AudioCommentVault.maximumEntries - 1)
    }
    func testPendingSaveOwnsDraftAgainstLowLevelConcurrentReplacement() throws {
        var file = try vault(); let old = try draft(); try file.save(old)
        let update = try old.replacing(caption: "Prepared update", clip: old.clip), intent = try saveIntent(update, base: old.revision)
        file.fault = { if $0 == .afterSaveJournal { throw InjectedFailure() } }
        XCTAssertThrowsError(try file.commitSave(intent))
        XCTAssertThrowsError(try vault().save(old.replacing(caption: "Bypass", clip: old.clip), replacing: old.revision))
        XCTAssertEqual(try vault().drafts(), [old]); try vault().discardSave(intent); XCTAssertEqual(try vault().drafts(), [old])
    }
    func testNewProvenanceAndDiscardPhaseCodecsRetainLegacyReads() throws {
        let root = try draft(), value = try root.carryingOrigin(.init(root))
        XCTAssertEqual(try AudioCommentSavedDraft(encoded: value.encoded(), owner: root.owner).origin, .init(root))
        var fields = try XCTUnwrap(PropertyListSerialization.propertyList(from: root.encoded(), format: nil) as? [String: Any])
        fields.removeValue(forKey: "origin"); fields["format"] = "taskfold-audio-review-v1"
        let legacy = try PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0)
        XCTAssertEqual(try AudioCommentSavedDraft(encoded: legacy, owner: root.owner), root)
        let intent = try saveIntent(value), discarding = try intent.markingDiscard()
        XCTAssertEqual(try AudioCommentSaveIntent(encoded: discarding.encoded(), owner: root.owner), discarding)
        var journal = try XCTUnwrap(PropertyListSerialization.propertyList(from: intent.encoded(), format: nil) as? [String: Any])
        journal.removeValue(forKey: "phase"); journal["format"] = "taskfold-audio-save-v1"; journal["next"] = legacy
        let oldJournal = try PropertyListSerialization.data(fromPropertyList: journal, format: .binary, options: 0)
        XCTAssertEqual(try AudioCommentSaveIntent(encoded: oldJournal, owner: root.owner).phase, .saving)
    }

}
