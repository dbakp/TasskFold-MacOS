import XCTest
@testable import TaskfoldCore

extension AudioCommentVaultTests {
    func copyIntent(_ write: AudioCommentInterruptedWrite, source: AudioCommentSavedDraft) throws -> AudioCommentSaveIntent {
        try .init(next: .init(owner: source.owner, target: source.target, caption: source.caption, clip: source.clip), base: nil, reviews: [], stage: .init(write))
    }
    func testInterruptedKeepBothPreservesSavedVersionForEitherLocalStageKind() throws {
        for review in [false, true] {
            let file = try vault(UUID().uuidString), original = try draft(file.owner); try file.save(original)
            let originalBytes = try Data(contentsOf: draftFile(original, in: file))
            let earlier = try original.replacing(caption: "Earlier cafe\u{301} recording", clip: original.clip)
            let path = try stage(earlier.encoded(recovery: review), in: file), write = try XCTUnwrap(file.interruptedWrites().first)
            let intent = try copyIntent(write, source: earlier)
            XCTAssertEqual(try AudioCommentSaveIntent(encoded: intent.encoded(), owner: file.owner), intent)
            XCTAssertEqual(try file.commitSave(intent), intent.next)
            XCTAssertEqual(try file.drafts().count, 2); XCTAssertEqual(try Data(contentsOf: draftFile(original, in: file)), originalBytes)
            XCTAssertTrue(intent.next.sameContent(as: earlier)); XCTAssertNil(intent.next.origin)
            XCTAssertNotEqual(intent.next.id, earlier.id); XCTAssertNotEqual(intent.next.revision, earlier.revision)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.path)); XCTAssertTrue(try file.saves().isEmpty)
            guard case .settled = try file.saveState(intent) else { return XCTFail("Expected fully settled copy") }
            XCTAssertEqual(try file.commitSave(intent), intent.next); XCTAssertEqual(try file.drafts().count, 2)
        }
    }
    func testInterruptedCopyJournalFinishesExactIDsAcrossEveryCommitCheckpoint() throws {
        for point in [AudioCommentVault.Checkpoint.afterSaveJournal, .afterDraftCommit, .afterStageCleanup] {
            var file = try vault(UUID().uuidString); let original = try draft(file.owner); try file.save(original)
            let earlier = try original.replacing(caption: "Preserve interrupted version", clip: original.clip)
            let path = try stage(earlier.encoded(), in: file), write = try XCTUnwrap(file.interruptedWrites().first), intent = try copyIntent(write, source: earlier)
            file.fault = { if $0 == point { throw InjectedFailure() } }
            XCTAssertThrowsError(try file.commitSave(intent)); let fresh = try vault(file.owner.account)
            XCTAssertEqual(try fresh.saves(), [intent]); XCTAssertTrue(try fresh.drafts().contains(original))
            XCTAssertEqual(try fresh.commitSave(intent, existingOnly: true), intent.next)
            XCTAssertEqual(try fresh.commitSave(intent, existingOnly: true), intent.next)
            XCTAssertEqual(Set(try fresh.drafts().map(\.id)), [original.id, intent.next.id]); XCTAssertTrue(try fresh.saves().isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        }
    }
    func testInterruptedCopyRefusesChangedOrMissingSourceBeforePreparingSave() throws {
        let file = try vault(), source = try draft(); _ = try file.drafts()
        let path = try stage(source.encoded(), in: file), write = try XCTUnwrap(file.interruptedWrites().first), intent = try copyIntent(write, source: source)
        let changed = try source.replacing(caption: "A different staged version", clip: source.clip).encoded()
        try changed.write(to: path)
        XCTAssertThrowsError(try file.commitSave(intent)); XCTAssertTrue(try file.saves().isEmpty); XCTAssertTrue(try file.drafts().isEmpty)
        XCTAssertEqual(try Data(contentsOf: path), changed)
        try FileManager.default.removeItem(at: path)
        XCTAssertThrowsError(try file.commitSave(intent)); XCTAssertTrue(try file.saves().isEmpty)
    }
    func testInterruptedCopyDoesNotRemoveAChangedStageAfterAuthorization() throws {
        let file = try vault(), source = try draft(); _ = try file.drafts()
        let path = try stage(source.encoded(), in: file), write = try XCTUnwrap(file.interruptedWrites().first), intent = try copyIntent(write, source: source)
        try file.prepareSave(intent, fence: file.departureFence())
        let changed = try source.replacing(caption: "New staged bytes", clip: source.clip).encoded()
        try changed.write(to: path)
        XCTAssertEqual(try file.commitSave(intent, existingOnly: true), intent.next)
        XCTAssertEqual(try Data(contentsOf: path), changed); XCTAssertEqual(try file.drafts(), [intent.next]); XCTAssertTrue(try file.saves().isEmpty)
    }
    func testIndependentCopyEditorsJoinTheFirstDurableStageAuthorization() throws {
        let file = try vault(), source = try draft(); _ = try file.drafts()
        _ = try stage(source.encoded(recovery: true), in: file); let write = try XCTUnwrap(file.interruptedWrites().first)
        let winner = try copyIntent(write, source: source), later = try copyIntent(write, source: source)
        try file.prepareSave(winner, fence: file.departureFence())
        XCTAssertThrowsError(try file.commitSave(later)) { error in XCTAssertEqual((error as? AudioCommentSaveRedirect)?.intent, winner) }
        XCTAssertEqual(try file.saves(), [winner]); XCTAssertEqual(try file.commitSave(winner), winner.next)
        XCTAssertThrowsError(try file.commitSave(later)); XCTAssertEqual(try file.drafts(), [winner.next]); XCTAssertTrue(try file.saves().isEmpty)
    }
    func testCancellingInterruptedCopyKeepsOriginalStageAndSavedDraft() throws {
        let file = try vault(), source = try draft(); try file.save(source)
        let bytes = try source.replacing(caption: "Copy to cancel", clip: source.clip).encoded()
        let path = try stage(bytes, in: file), write = try XCTUnwrap(file.interruptedWrites().first)
        let intent = try copyIntent(write, source: try AudioCommentSavedDraft(encoded: bytes, owner: file.owner))
        try file.prepareSave(intent, fence: file.departureFence()); try file.discardSave(intent)
        XCTAssertEqual(try file.drafts(), [source]); XCTAssertTrue(try file.saves().isEmpty); XCTAssertEqual(try Data(contentsOf: path), bytes)
        XCTAssertThrowsError(try file.commitSave(intent, existingOnly: true))
    }
    func testInterruptedCopyKeepsAnUnrelatedSaveForTheOriginalDraft() throws {
        let file = try vault(), original = try draft(); try file.save(original)
        let pending = try AudioCommentSaveIntent(next: original.replacing(caption: "Other editor", clip: original.clip), base: original.revision, reviews: [])
        try file.prepareSave(pending, fence: file.departureFence())
        let earlier = try original.replacing(caption: "Earlier stage", clip: original.clip)
        _ = try stage(earlier.encoded(), in: file); let write = try XCTUnwrap(file.interruptedWrites().first), intent = try copyIntent(write, source: earlier)
        XCTAssertEqual(try file.commitSave(intent), intent.next)
        XCTAssertEqual(try file.saves(), [pending]); XCTAssertTrue(try file.drafts().contains(original))
    }
    func testInterruptedCopyQuotaRefusalRetainsOneJournalAndCanFinishAfterSpaceIsFreed() throws {
        let file = try vault(); var originals: [AudioCommentSavedDraft] = []
        for _ in 0..<18 { let item = try draft(); try file.save(item); originals.append(item) }
        let source = try originals[0].replacing(caption: "Quota stage", clip: originals[0].clip), path = try stage(source.encoded(), in: file)
        let write = try XCTUnwrap(file.interruptedWrites().first), intent = try copyIntent(write, source: source)
        XCTAssertThrowsError(try file.commitSave(intent)); XCTAssertEqual(try file.saves(), [intent])
        XCTAssertEqual(try file.drafts().count, 18); XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        let disposable = originals.removeLast(); try file.discardDraft(disposable.id, revision: disposable.revision)
        XCTAssertEqual(try file.commitSave(intent, existingOnly: true), intent.next)
        XCTAssertEqual(try file.drafts().count, 18); XCTAssertTrue(try file.drafts().contains(originals[0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
    func testStageCleanupAuthorizationCannotReplaceOrRetargetTheSource() throws {
        let file = try vault(), source = try draft(); _ = try file.drafts()
        _ = try stage(source.encoded(), in: file); let write = try XCTUnwrap(file.interruptedWrites().first), ref = try AudioCommentStageReference(write)
        for next in [source, try source.replacing(caption: "Different text", clip: source.clip), try draft()] {
            let intent = try AudioCommentSaveIntent(next: next, base: nil, reviews: [], stage: ref)
            XCTAssertThrowsError(try file.commitSave(intent)); XCTAssertTrue(try file.saves().isEmpty)
        }
        XCTAssertThrowsError(try AudioCommentSaveIntent(next: source, base: source.revision, reviews: [], stage: ref))
        XCTAssertThrowsError(try AudioCommentSaveIntent(next: source, base: nil, reviews: [.init(source)], stage: ref))
        let pending = try self.pending(); _ = try stage(pending.encoded(), in: file)
        let publication = try XCTUnwrap(file.interruptedWrites().first { if case .pending = $0.payload { return true }; return false })
        XCTAssertThrowsError(try AudioCommentStageReference(publication))
    }
}

extension AudioCommentVaultTests {
    func testInterruptedCopyJournalRejectsMalformedOrWidenedStageReferences() throws {
        let file = try vault(), source = try draft(); _ = try file.drafts()
        _ = try stage(source.encoded(), in: file)
        let write = try XCTUnwrap(file.interruptedWrites().first), intent = try copyIntent(write, source: source)
        var fields = try XCTUnwrap(try PropertyListSerialization.propertyList(from: intent.encoded(), format: nil) as? [String: Any])
        let original = fields
        let ref = try XCTUnwrap(fields["stage"] as? Data), object = try XCTUnwrap(try JSONSerialization.jsonObject(with: ref) as? [String: Any])
        for (key, value) in [("kind", "pending"), ("sha256", "../untrusted"), ("id", AudioCommentTarget.zero.uuidString), ("unexpected", "field")] {
            var changed = object; changed[key] = value
            fields = original; fields["stage"] = try JSONSerialization.data(withJSONObject: changed)
            let bytes = try PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0)
            XCTAssertThrowsError(try AudioCommentSaveIntent(encoded: bytes, owner: file.owner))
        }
        fields = original; fields.removeValue(forKey: "stage")
        XCTAssertThrowsError(try AudioCommentSaveIntent(encoded: PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0), owner: file.owner))
        fields = original; fields["format"] = "taskfold-audio-save-v2"
        XCTAssertThrowsError(try AudioCommentSaveIntent(encoded: PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0), owner: file.owner))
        let ordinary = try AudioCommentSaveIntent(next: source, base: nil, reviews: [])
        let oldFields = try XCTUnwrap(try PropertyListSerialization.propertyList(from: ordinary.encoded(), format: nil) as? [String: Any])
        XCTAssertEqual(oldFields["format"] as? String, "taskfold-audio-save-v2"); XCTAssertNil(oldFields["stage"])
        XCTAssertEqual(try AudioCommentSaveIntent(encoded: ordinary.encoded(), owner: file.owner), ordinary)
        XCTAssertEqual(try intent.markingDiscard().stage, intent.stage); XCTAssertEqual(try intent.separateCopy().stage, intent.stage)
        let zeroPath = file.directory.appendingPathComponent(".write-" + AudioCommentTarget.zero.uuidString.lowercased())
        try source.encoded().write(to: zeroPath)
        let zero = try XCTUnwrap(file.interruptedWrites().first { $0.id == AudioCommentTarget.zero })
        XCTAssertThrowsError(try AudioCommentStageReference(zero)); XCTAssertTrue(try file.saves().isEmpty)
    }
}

extension AudioCommentVaultTests {
    func testPreRenameCopyJournalBlocksAnotherCopyWithoutBeingAutoPromoted() throws {
        let file = try vault(), source = try draft(); _ = try file.drafts()
        let originalPath = try stage(source.encoded(), in: file), write = try XCTUnwrap(file.interruptedWrites().first)
        let original = try copyIntent(write, source: source), competing = try copyIntent(write, source: source)
        let journalBytes = try original.encoded(), journalStage = try stage(journalBytes, in: file)
        XCTAssertThrowsError(try file.commitSave(competing)) { XCTAssertEqual($0 as? AudioCommentStorageFailure, .stageNeedsRecovery) }
        XCTAssertTrue(try file.saves().isEmpty); XCTAssertTrue(try file.drafts().isEmpty)
        XCTAssertEqual(try Data(contentsOf: originalPath), try source.encoded()); XCTAssertEqual(try Data(contentsOf: journalStage), journalBytes)
        XCTAssertEqual(try file.commitSave(original), original.next)
        XCTAssertEqual(try file.drafts(), [original.next]); XCTAssertFalse(FileManager.default.fileExists(atPath: originalPath.path))
        XCTAssertEqual(try Data(contentsOf: journalStage), journalBytes, "Unpromoted authorization remains for its own reviewed recovery")
    }
    func testPreRenameDiscardStageCannotBeBypassedByFinishingTheCopy() throws {
        let file = try vault(), source = try draft(); _ = try file.drafts()
        let originalPath = try stage(source.encoded(), in: file), write = try XCTUnwrap(file.interruptedWrites().first), intent = try copyIntent(write, source: source)
        try file.prepareSave(intent, fence: file.departureFence())
        let discardBytes = try intent.markingDiscard().encoded(), journalStage = try stage(discardBytes, in: file)
        XCTAssertThrowsError(try file.commitSave(intent, existingOnly: true)) { XCTAssertEqual($0 as? AudioCommentStorageFailure, .stageNeedsRecovery) }
        XCTAssertEqual(try file.saves(), [intent]); XCTAssertTrue(try file.drafts().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalPath.path)); XCTAssertEqual(try Data(contentsOf: journalStage), discardBytes)
        try file.discardSave(intent)
        XCTAssertTrue(try file.saves().isEmpty); XCTAssertTrue(try file.drafts().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalPath.path)); XCTAssertEqual(try Data(contentsOf: journalStage), discardBytes)
    }
}
