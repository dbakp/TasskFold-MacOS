import Foundation
import Darwin
@testable import TaskfoldCore

@MainActor final class AudioProofContext { var scope: AudioCommentLiveScope; init(_ scope: AudioCommentLiveScope) { self.scope = scope } }
@MainActor final class AudioProofRecorder: AudioCommentRecording {
    var callbacks: [@MainActor (AudioCommentRecordingEvent) -> Void] = []
    var permits: [@MainActor () -> Bool] = []
    var elapsed: TimeInterval = 0
    var denied = false, suspended = false
    var continuation: CheckedContinuation<Void, Never>?
    var data: Data
    var cancellations = 0
    init(_ data: Data) { self.data = data }
    func start(isCurrent: @escaping @MainActor () -> Bool, receive: @escaping @MainActor (AudioCommentRecordingEvent) -> Void) async throws {
        callbacks.append(receive); permits.append(isCurrent)
        if suspended { await withCheckedContinuation { continuation = $0 } }
        if denied { throw AudioCommentFailure(message: "Synthetic permission refusal") }
        receive(.started)
    }
    func grant() { continuation?.resume(); continuation = nil }
    func finish() { callbacks.last?(.finished(data)) }
    func cancel() { cancellations += 1 }
}
@MainActor final class AudioProofPlayer: AudioCommentPlaying {
    var plays = 0, stops = 0
    func play(_ clip: AudioCommentClip, isCurrent: @escaping @MainActor () -> Bool, ended: @escaping @MainActor () -> Void) throws { guard isCurrent() else { throw CancellationError() }; plays += 1 }
    func stop() { stops += 1 }
}
final class AudioProofOneShotFault: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Bool
    private var writes = 0
    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return writes }
    private let point: AudioCommentVault.Checkpoint
    init(enabled: Bool = true, point: AudioCommentVault.Checkpoint = .afterRename) { remaining = enabled; self.point = point }
    func arm() { lock.lock(); remaining = true; lock.unlock() }
    func check(_ point: AudioCommentVault.Checkpoint) throws {
        guard point == self.point else { return }
        lock.lock(); writes += 1; let fail = remaining; remaining = false; lock.unlock()
        if fail { throw AudioCommentStorageFailure.unreadable }
    }
}
final class AudioProofSaveGate: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var reached = false
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return reached }
    func check(_ point: AudioCommentVault.Checkpoint) throws {
        guard point == .afterSaveJournal else { return }
        lock.lock(); reached = true; lock.unlock()
        guard semaphore.wait(timeout: .now() + 3) == .success else { throw AudioCommentStorageFailure.unreadable }
    }
    func release() { semaphore.signal() }
}
@main struct AudioControllerProof {
    @MainActor static func wait(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let workspace = WorkspaceBinding(account: "local-audio-proof", generation: UUID())
        let target = try AudioCommentTarget(task: UUID(), generation: UUID(), project: nil)
        let context = AudioProofContext(.init(workspace: workspace, target: target))
        let request = AudioCommentDraftRequest(scope: context.scope, title: "Synthetic audio review")
        let owner = try AudioCommentOwner(workspace.account)
        var checks: [String: Bool] = [:]
        func store(_ suffix: String, fault: (@Sendable (AudioCommentVault.Checkpoint) throws -> Void)? = nil) throws -> AudioCommentDraftStorage {
            let folder = root.appendingPathComponent(suffix, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            return AudioCommentDraftStorage(vault: .init(applicationSupport: folder, owner: owner, fault: fault))
        }
        func make(_ driver: AudioProofRecorder, _ player: AudioProofPlayer, _ store: AudioCommentDraftStorage, bound: Bool = true) -> AudioCommentCapture {
            let c = AudioCommentCapture(request: request, recorder: driver, player: player, storage: store)
            if bound { c.currentScope = { context.scope } }; return c
        }
        let recording = AudioProofRecorder(data), player = AudioProofPlayer(), disk = try store("ordinary")
        let unbound = make(recording, player, disk, bound: false); unbound.start()
        checks["unboundCannotRequestMicrophone"] = recording.callbacks.isEmpty
        unbound.close()
        let c = make(recording, player, disk); c.start(); _ = await wait { c.session.phase == .recording }
        c.stop(); _ = await wait { c.session.phase == .review }
        checks["stopDecodesRealAACBeforeReview"] = c.session.clip?.descriptor.milliseconds == 1000 && recording.cancellations > 0
        c.editCaption("  cafe\u{301}\nمراجعة 🪴  "); c.play()
        checks["playbackIsExplicitAndStops"] = player.plays == 1 && c.playing
        c.stopPlayback(); checks["stopPlaybackClearsUI"] = !c.playing && player.stops > 0
        let saved = await c.save(); let first = c.saved
        checks["savePersistsExactReviewedClipAndCaption"] = saved && first?.clip.data == data && first?.caption.utf8.elementsEqual(c.session.caption.utf8) == true
        c.close(); checks["closeClearsPrivatePreviewAndCaption"] = c.session.clip == nil && c.session.caption.isEmpty && c.available.isEmpty && c.saved == nil
        let fresh = make(recording, player, disk); await fresh.refresh()
        if let first { await fresh.restore(first) }
        checks["newPresentationRestoresAndDecodesSavedRecording"] = fresh.saved == first && fresh.session.phase == .review && !fresh.needsSave
        recording.denied = true; fresh.start(); _ = await wait { fresh.session.phase == .review }
        checks["permissionRefusalPreservesEarlierRecording"] = fresh.session.clip?.data == data && fresh.notice != nil
        checks["permissionRefusalRestoresEarlierDuration"] = fresh.elapsed == 1
        recording.denied = false; recording.data = Data("broken".utf8)
        fresh.start(); _ = await wait { fresh.session.phase == .recording }; fresh.stop(); _ = await wait { fresh.session.phase == .review }
        checks["invalidReplacementKeepsEarlierRecording"] = fresh.session.clip?.data == data && fresh.saved == first
        recording.data = data; fresh.start(); _ = await wait { fresh.session.phase == .recording }
        let old = recording.callbacks[recording.callbacks.count - 2]
        old(.finished(Data("stale".utf8)))
        checks["oldCallbackCannotReplaceCurrentRecording"] = fresh.session.phase == .recording
        context.scope = .init(workspace: .init(account: "other-workspace", generation: UUID()), target: target)
        fresh.contextChanged()
        recording.callbacks.last?(.finished(data))
        checks["workspaceChangeStopsAndErasesPrivatePreview"] = fresh.session.phase == .closed && fresh.session.clip == nil && fresh.session.caption.isEmpty && !fresh.playing && recording.permits.last?() == false
        context.scope = request.scope
        let pending = AudioProofRecorder(data); pending.suspended = true
        let p = make(pending, AudioProofPlayer(), try store("permission")); p.start(); _ = await wait { pending.continuation != nil }
        p.cancelRecording(); pending.grant(); _ = await wait { p.session.phase != .authorizing }
        checks["cancelledPermissionCannotStartLateRecording"] = p.session.phase == .ready && p.session.clip == nil && pending.permits.first?() == false
        p.close()
        struct LostAcknowledgement: Error {}
        let failing = try store("lost-save", fault: { if $0 == .afterDraftCommit { throw LostAcknowledgement() } })
        let retry = make(AudioProofRecorder(data), AudioProofPlayer(), failing)
        retry.start(); _ = await wait { retry.session.phase == .recording }; retry.stop(); _ = await wait { retry.session.phase == .review }
        retry.editCaption("Frozen retry caption")
        let firstSave = await retry.save(), afterFailure = try await failing.drafts()
        retry.editCaption("Must not overwrite")
        checks["uncertainSaveFreezesEditingAndKeepsAudio"] = !firstSave && retry.saveUnconfirmed && !retry.editable && retry.session.caption == "Frozen retry caption" && retry.session.clip?.data == data
        let retried = await retry.save(), afterRetry = try await failing.drafts()
        checks["retryConfirmsOneStableDraftWithoutDuplication"] = retried && !retry.saveUnconfirmed && afterFailure == afterRetry && afterRetry.count == 1
        if let original = retry.saved {
            let concurrent = try original.replacing(caption: "Other window", clip: original.clip)
            let otherWindow = AudioCommentDraftStorage(applicationSupport: root.appendingPathComponent("lost-save", isDirectory: true), owner: owner)
            try await otherWindow.save(concurrent, replacing: original.revision)
            let deleted = await retry.deleteSaved()
            let preserved = try await failing.drafts()
            checks["staleDeleteCannotRemoveAnotherWindowsEdit"] = !deleted && preserved == [concurrent]
        }
        retry.close()
        // Real private recovery files, without explicit Save: close/context loss
        // must not discard the last admitted recording or its exact caption.
        let recoveryDisk = try store("recovery-lifecycle")
        let review = make(AudioProofRecorder(data), AudioProofPlayer(), recoveryDisk)
        review.start(); _ = await wait { review.session.phase == .recording }; review.stop(); _ = await wait { review.session.phase == .review }
        for index in 0..<30 { review.editCaption("Recovery \(index) cafe\u{301}\nمراجعة 🪴") }
        let reviewedCaption = review.session.caption
        let kept = await review.preserveReview()
        let automatic = try await recoveryDisk.reviews()
        checks["reviewAndRapidCaptionEditsCheckpointWithoutExplicitSave"] = kept && automatic.count == 1 && automatic.first?.caption.utf8.elementsEqual(reviewedCaption.utf8) == true && automatic.first?.clip.data == data
        checks["recoveryDoesNotPretendToBeAnExplicitSavedDraft"] = try await recoveryDisk.drafts().isEmpty
        context.scope = .init(workspace: .init(account: "other-workspace", generation: UUID()), target: target)
        review.contextChanged()
        let observedRecoveryState1 = try await recoveryDisk.reviews()
        checks["scopeChangeErasesPreviewAndRetainsOriginalPrivateRecovery"] = review.session.phase == .closed && review.session.clip == nil && review.session.caption.isEmpty && observedRecoveryState1 == automatic
        context.scope = request.scope
        let recovered = make(AudioProofRecorder(data), AudioProofPlayer(), recoveryDisk)
        await recovered.refresh()
        if let first = recovered.recoverable.first { await recovered.restore(first, recovering: true) }
        checks["freshPresentationFullyDecodesRecoveredUnsavedReview"] = recovered.session.phase == .review && recovered.session.caption.utf8.elementsEqual(reviewedCaption.utf8) && recovered.session.clip?.data == data && recovered.saved == nil && recovered.needsSave
        let savedRecovery = await recovered.save()
        let observedRecoveryState2 = try await recoveryDisk.drafts()
        let observedRecoveryState3 = try await recoveryDisk.reviews()
        checks["explicitSaveSettlesRecoveryWithoutDuplicatingSavedDraft"] = savedRecovery && observedRecoveryState2.count == 1 && observedRecoveryState3.isEmpty
        recovered.editCaption("Discard only this edit")
        _ = await recovered.preserveReview()
        let discarded = await recovered.discardReviewAndClose()
        let observedRecoveryState4 = try await recoveryDisk.reviews()
        let observedRecoveryState5 = try await recoveryDisk.drafts()
        checks["explicitDiscardRemovesOnlyReviewAndKeepsSavedDraft"] = discarded && observedRecoveryState4.isEmpty && observedRecoveryState5.first?.caption.utf8.elementsEqual(reviewedCaption.utf8) == true

        // Actual writer-lock failure: process-owned retention is scoped and
        // resumes when the original owner/task is reopened, not on logout.
        let retainedDisk = try store("retained-lock")
        let retainedVault = AudioCommentVault(applicationSupport: root.appendingPathComponent("retained-lock"), owner: owner)
        _ = try await retainedDisk.drafts()
        let lockedFD = Darwin.open(retainedVault.directory.appendingPathComponent(".lock").path, O_RDWR)
        guard lockedFD >= 0, flock(lockedFD, LOCK_EX | LOCK_NB) == 0 else { throw AudioCommentStorageFailure.unreadable }
        let retainedReview = make(AudioProofRecorder(data), AudioProofPlayer(), retainedDisk)
        retainedReview.start(); _ = await wait { retainedReview.session.phase == .recording }; retainedReview.stop(); _ = await wait { retainedReview.session.phase == .review }
        retainedReview.editCaption("Keep through writer lock")
        let lockedSave = await retainedReview.preserveReview()
        let explicitlyLocked = await retainedReview.save()
        checks["knownPrewriteBusyFailureKeepsReviewEditable"] = !explicitlyLocked && !retainedReview.saveUnconfirmed && retainedReview.editable
        retainedReview.close()
        checks["failedCheckpointIsRetainedAfterViewCloses"] = !lockedSave && retainedReview.recovery.failure != nil && retainedReview.session.clip == nil
        let attention = make(AudioProofRecorder(data), AudioProofPlayer(), retainedDisk)
        await attention.refresh()
        checks["returningWhileWriteIsBlockedExposesExplicitRecoveryRetry"] = attention.retainedRecoveryFailed && attention.notice != nil && attention.session.clip == nil
        _ = flock(lockedFD, LOCK_UN); Darwin.close(lockedFD)
        let stranger = try AudioCommentOwner("other-workspace")
        _ = await AudioCommentReviewRecovery.retryRetained(owner: stranger, target: target)
        let observedRecoveryState6 = try await retainedDisk.reviews()
        checks["anotherAccountCannotRetryOrReadRetainedReview"] = observedRecoveryState6.isEmpty && retainedReview.recovery.failure != nil
        let nextGeneration = try AudioCommentTarget(task: target.task, generation: UUID(), project: target.project)
        _ = await AudioCommentReviewRecovery.retryRetained(owner: owner, target: nextGeneration)
        let observedRecoveryState7 = try await retainedDisk.reviews()
        checks["anotherTaskIncarnationCannotRetryRetainedReview"] = observedRecoveryState7.isEmpty
        let returning = attention
        await returning.refresh()
        checks["originalOwnerAndTaskResumeRetainedRecovery"] = !returning.retainedRecoveryFailed && returning.recoverable.count == 1 && returning.recoverable.first?.caption == "Keep through writer lock" && retainedReview.recovery.durable
        returning.close()

        // Conflicts are different from uncertain acknowledgements. A deliberate
        // copy preserves both exact versions, while Delete cannot drop dirty work.
        let copyFault = AudioProofOneShotFault(enabled: false, point: .afterDraftCommit)
        let conflictDisk = try store("save-conflict", fault: { try copyFault.check($0) })
        let base = try AudioCommentSavedDraft(owner: owner, target: target, caption: "Original saved caption", clip: await AudioCommentDecoding.validate(data))
        try await conflictDisk.save(base)
        let conflictReview = make(AudioProofRecorder(data), AudioProofPlayer(), conflictDisk)
        await conflictReview.restore(base); conflictReview.editCaption("My unsaved cafe\u{301}")
        _ = await conflictReview.preserveReview()
        let dirtyDelete = await conflictReview.deleteSaved()
        let observedRecoveryState8 = try await conflictDisk.drafts()
        let observedRecoveryState9 = try await conflictDisk.reviews()
        checks["modelRejectsDeletionWhileReviewHasUnsavedChanges"] = !dirtyDelete && observedRecoveryState8 == [base] && !observedRecoveryState9.isEmpty
        let concurrent = try base.replacing(caption: "Another window", clip: base.clip)
        try await conflictDisk.save(concurrent, replacing: base.revision)
        let conflictSave = await conflictReview.save()
        checks["saveConflictIsDistinguishedFromUncertainCommit"] = !conflictSave && conflictReview.saveConflict && !conflictReview.saveUnconfirmed && !conflictReview.editable && conflictReview.session.caption == "My unsaved cafe\u{301}"
        copyFault.arm()
        let firstCopySave = await conflictReview.saveSeparateDraft()
        let unconfirmedCopy = try await conflictDisk.drafts()
        let frozenCopyCaption = conflictReview.session.caption
        conflictReview.editCaption("Cannot change an uncertain copy")
        checks["uncertainConflictCopyFreezesExactReviewForRetry"] = !firstCopySave && conflictReview.saveUnconfirmed && !conflictReview.saveConflict && conflictReview.session.caption.utf8.elementsEqual(frozenCopyCaption.utf8) && unconfirmedCopy.count == 2
        let copySave = await conflictReview.save()
        let copies = try await conflictDisk.drafts()
        checks["uncertainConflictCopyRetryDoesNotDuplicateEitherVersion"] = copySave && Set(copies.map(\.id)) == Set(unconfirmedCopy.map(\.id)) && copies.count == 2
        checks["explicitConflictCopyKeepsBothExactVersions"] = copySave && !conflictReview.saveConflict && copies.count == 2 && copies.contains(concurrent) && copies.contains { $0.id != base.id && $0.caption.utf8.elementsEqual("My unsaved cafe\u{301}".utf8) && $0.clip.data == data }
        conflictReview.close()

        let checkpointFault = AudioProofOneShotFault()
        let uncertainDisk = try store("recovery-uncertain", fault: { try checkpointFault.check($0) })
        let uncertainReview = make(AudioProofRecorder(data), AudioProofPlayer(), uncertainDisk)
        uncertainReview.start(); _ = await wait { uncertainReview.session.phase == .recording }; uncertainReview.stop(); _ = await wait { uncertainReview.session.phase == .review }
        _ = await wait { uncertainReview.recovery.failure != nil }
        let committedBeforeRetry = try await uncertainDisk.reviews()
        uncertainReview.editCaption("Newest caption after lost acknowledgement")
        let recoveredUncertain = await uncertainReview.preserveReview()
        let committedAfterRetry = try await uncertainDisk.reviews()
        checks["recoveryRetriesFrozenCommitBeforeAdvancingToLatestCaption"] = recoveredUncertain && committedBeforeRetry.count == 1 && committedAfterRetry.count == 1 && committedBeforeRetry.first?.id == committedAfterRetry.first?.id && committedAfterRetry.first?.caption == "Newest caption after lost acknowledgement" && committedAfterRetry.first?.clip.data == data
        let sourceRecovery = try await uncertainDisk.reviews()
        if let current = sourceRecovery.first { try await uncertainDisk.discardReview(current.id, revision: current.revision) }
        uncertainReview.editCaption("Keep reviewing after another window settled the copy")
        let keptAfterConcurrentSettlement = await uncertainReview.preserveReview()
        let afterConcurrentSettlement = try await uncertainDisk.reviews()
        checks["concurrentRecoverySettlementForksWithoutLosingActiveReview"] = keptAfterConcurrentSettlement && afterConcurrentSettlement.count == 1 && afterConcurrentSettlement.first?.id != sourceRecovery.first?.id && afterConcurrentSettlement.first?.caption == "Keep reviewing after another window settled the copy"
        uncertainReview.editCaption("Last keystroke before switching workspace")
        context.scope = .init(workspace: .init(account: "other-workspace", generation: UUID()), target: target)
        uncertainReview.contextChanged()
        let lastKeystrokeSaved = await uncertainReview.preserveReview()
        let afterImmediateSwitch = try await uncertainDisk.reviews()
        let foreignDisk = AudioCommentDraftStorage(applicationSupport: root.appendingPathComponent("recovery-uncertain"), owner: stranger)
        let foreignReviews = try await foreignDisk.reviews()
        checks["queuedLastKeystrokeFinishesOnlyInFrozenOwnerAfterScopeLoss"] = lastKeystrokeSaved && afterImmediateSwitch.first?.caption == "Last keystroke before switching workspace" && foreignReviews.isEmpty && uncertainReview.session.clip == nil && uncertainReview.session.caption.isEmpty
        context.scope = request.scope
        uncertainReview.close()
        let fullDisk = try store("quota-exit")
        for _ in 0..<AudioCommentVault.maximumEntries {
            let item = try AudioCommentSavedDraft(owner: owner, target: target, caption: "Keep earlier saved recording", clip: AudioCommentClip(data: data))
            try await fullDisk.save(item)
        }
        let beforeFullReview = try await fullDisk.drafts()
        let fullReview = make(AudioProofRecorder(data), AudioProofPlayer(), fullDisk)
        fullReview.start(); _ = await wait { fullReview.session.phase == .recording }; fullReview.stop(); _ = await wait { fullReview.session.phase == .review }
        _ = await fullReview.preserveReview()
        let fullSave = await fullReview.save()
        checks["knownPrewriteQuotaFailureDoesNotFreezeReviewAsUncertainSave"] = !fullSave && !fullReview.saveUnconfirmed && fullReview.editable && fullReview.session.clip?.data == data
        fullReview.editCaption("Deliberately discard only this unsaved review")
        let fullDiscard = await fullReview.discardReviewAndClose()
        let afterFullReview = try await fullDisk.drafts(), afterFullRecoveries = try await fullDisk.reviews()
        checks["explicitDiscardWorksAtFullQuotaWithoutWritingAnotherCopy"] = fullDiscard && afterFullRecoveries.isEmpty && afterFullReview == beforeFullReview
        let discardFault = AudioProofOneShotFault()
        let uncertainDiscardDisk = try store("discard-uncertain", fault: { try discardFault.check($0) })
        let uncertainDiscardReview = make(AudioProofRecorder(data), AudioProofPlayer(), uncertainDiscardDisk)
        uncertainDiscardReview.start(); _ = await wait { uncertainDiscardReview.session.phase == .recording }; uncertainDiscardReview.stop(); _ = await wait { uncertainDiscardReview.session.phase == .review }
        _ = await wait { uncertainDiscardReview.recovery.failure != nil }
        let beforeUncertainDiscard = try await uncertainDiscardDisk.reviews()
        uncertainDiscardReview.editCaption("Discard this newer unsaved caption too")
        let writesBeforeDiscard = discardFault.writeCount
        let explicitlyDiscardedUncertain = await uncertainDiscardReview.discardReviewAndClose()
        let afterUncertainDiscard = try await uncertainDiscardDisk.reviews()
        checks["explicitDiscardSettlesExactUnacknowledgedRecoveryWithoutSavingNewerCaption"] = explicitlyDiscardedUncertain && beforeUncertainDiscard.count == 1 && afterUncertainDiscard.isEmpty && discardFault.writeCount == writesBeforeDiscard

        let coldDisk = try store("cold-save", fault: { if $0 == .afterDraftCommit { throw AudioCommentStorageFailure.unreadable } })
        let cold = make(AudioProofRecorder(data), AudioProofPlayer(), coldDisk)
        cold.start(); _ = await wait { cold.session.phase == .recording }; cold.stop(); _ = await wait { cold.session.phase == .review }
        cold.editCaption("Exact cafe\u{301}\nKeep this Save once")
        let coldSaved = await cold.save(), coldIntents = try await coldDisk.saves(), coldDrafts = try await coldDisk.drafts()
        checks["uncertainPrimarySaveHasDurableIntentAndSafeClose"] = !coldSaved && cold.saveDurable && cold.saveUnconfirmed && coldIntents.count == 1 && coldDrafts.count == 1
        cold.close()
        let coldReturn = make(AudioProofRecorder(data), AudioProofPlayer(), coldDisk)
        await coldReturn.refresh()
        checks["relaunchListsOriginalSaveAndHidesItsRecoveryCopies"] = coldReturn.pendingSaves == coldIntents && coldReturn.recoverable.isEmpty && coldReturn.available == coldDrafts
        let foreignScope = AudioCommentLiveScope(workspace: .init(account: "another-save-account", generation: UUID()), target: target)
        let foreign = AudioCommentCapture(request: .init(scope: foreignScope, title: "Other account"), recorder: AudioProofRecorder(data), player: AudioProofPlayer(), storage: coldDisk)
        foreign.currentScope = { foreignScope }
        if let intent = coldIntents.first { await foreign.resumeSave(intent) }
        checks["pendingSaveCannotExposeClipUnderAnotherAccountEvenWithWrongStoreInjection"] = foreign.session.clip == nil && foreign.pendingSaves.isEmpty
        await foreign.refresh()
        checks["wrongStoreCannotExposeAnotherOwnersPendingOrSavedRows"] = foreign.pendingSaves.isEmpty && foreign.available.isEmpty && foreign.recoverable.isEmpty
        foreign.close()
        let nextScope = AudioCommentLiveScope(workspace: workspace, target: nextGeneration)
        let laterTask = AudioCommentCapture(request: .init(scope: nextScope, title: "New task incarnation"), recorder: AudioProofRecorder(data), player: AudioProofPlayer(), storage: coldDisk)
        laterTask.currentScope = { nextScope }
        if let intent = coldIntents.first { await laterTask.resumeSave(intent) }
        checks["pendingSaveCannotExposeClipUnderAnotherTaskGeneration"] = laterTask.session.clip == nil
        laterTask.close()
        if let intent = coldReturn.pendingSaves.first { await coldReturn.resumeSave(intent) }
        let afterColdSave = try await coldDisk.drafts(), afterColdJournals = try await coldDisk.saves(), afterColdReviews = try await coldDisk.reviews()
        checks["relaunchFinishesExactOriginalDraftWithoutDuplicate"] = afterColdSave == coldDrafts && afterColdJournals.isEmpty && afterColdReviews.isEmpty && coldReturn.saved == coldDrafts.first && !coldReturn.saveUnconfirmed
        if let intent = coldIntents.first { await coldReturn.resumeSave(intent) }
        checks["lateFinishCallbackIsIdempotentForAlreadySavedDraft"] = try await coldDisk.drafts() == afterColdSave
        coldReturn.close()
        if let saved = afterColdSave.first { try await coldDisk.discardDraft(saved.id, revision: saved.revision) }
        let afterDeletion = make(AudioProofRecorder(data), AudioProofPlayer(), coldDisk)
        if let intent = coldIntents.first { await afterDeletion.resumeSave(intent) }
        let afterStaleResume = try await coldDisk.drafts()
        checks["lateFinishCallbackCannotResurrectDeletedAudio"] = afterStaleResume.isEmpty && afterDeletion.session.clip == nil && afterDeletion.notice != nil
        afterDeletion.close()

        let quotaDisk = try store("prepared-quota")
        for _ in 0..<(AudioCommentVault.maximumEntries - 2) {
            try await quotaDisk.save(AudioCommentSavedDraft(owner: owner, target: target, caption: "Earlier recording", clip: AudioCommentClip(data: data)))
        }
        let earlierQuota = try await quotaDisk.drafts()
        let quotaSave = make(AudioProofRecorder(data), AudioProofPlayer(), quotaDisk)
        quotaSave.start(); _ = await wait { quotaSave.session.phase == .recording }; quotaSave.stop(); _ = await wait { quotaSave.session.phase == .review }
        quotaSave.editCaption("Durable Save waiting for space")
        let savedAtQuota = await quotaSave.save(), pendingAtQuota = try await quotaDisk.saves()
        checks["quotaAfterJournalIsDurableUncertainSaveNotEditableNewIntent"] = !savedAtQuota && quotaSave.saveDurable && quotaSave.saveUnconfirmed && !quotaSave.editable && pendingAtQuota.count == 1
        quotaSave.close()
        let quotaReturn = make(AudioProofRecorder(data), AudioProofPlayer(), quotaDisk); await quotaReturn.refresh()
        if let earlier = earlierQuota.first { await quotaReturn.restore(earlier); _ = await quotaReturn.deleteSaved() }
        if let pending = quotaReturn.pendingSaves.first { await quotaReturn.resumeSave(pending) }
        let quotaCompleted = try await quotaDisk.drafts(), quotaCompletedIntents = try await quotaDisk.saves()
        checks["returnedEditorCanFreeSpaceThenFinishSamePreparedSave"] = quotaCompleted.count == earlierQuota.count && quotaCompletedIntents.isEmpty && quotaCompleted.contains { $0.id == pendingAtQuota.first?.next.id && $0.caption == "Durable Save waiting for space" }
        quotaReturn.close()

        let replacementFault = AudioProofOneShotFault(enabled: false, point: .afterSaveJournal)
        let replacementDisk = try store("cold-conflict-copy", fault: { try replacementFault.check($0) })
        let originalCopy = try AudioCommentSavedDraft(owner: owner, target: target, caption: "Original", clip: AudioCommentClip(data: data))
        try await replacementDisk.save(originalCopy)
        let replacement = make(AudioProofRecorder(data), AudioProofPlayer(), replacementDisk)
        await replacement.restore(originalCopy); replacement.editCaption("My exact cafe\u{301} copy")
        let changedCopy = try originalCopy.replacing(caption: "Other window", clip: originalCopy.clip)
        try await replacementDisk.save(changedCopy, replacing: originalCopy.revision)
        _ = await replacement.save(); replacementFault.arm(); _ = await replacement.saveSeparateDraft()
        let preparedCopy = try await replacementDisk.saves()
        replacement.close()
        let replacementReturn = make(AudioProofRecorder(data), AudioProofPlayer(), replacementDisk); await replacementReturn.refresh()
        if let pending = replacementReturn.pendingSaves.first { await replacementReturn.resumeSave(pending) }
        let completedCopies = try await replacementDisk.drafts(), remainingCopyIntents = try await replacementDisk.saves()
        checks["interruptedSeparateCopyResumesPersistedCopyIdentity"] = preparedCopy.count == 1 && completedCopies.count == 2 && completedCopies.contains(changedCopy) && completedCopies.contains { $0.id == preparedCopy.first?.next.id && $0.caption.utf8.elementsEqual("My exact cafe\u{301} copy".utf8) } && remainingCopyIntents.isEmpty
        replacementReturn.close()

        let scopeGate = AudioProofSaveGate()
        let scopeDisk = try store("save-scope-change", fault: { try scopeGate.check($0) })
        let scopedSave = make(AudioProofRecorder(data), AudioProofPlayer(), scopeDisk)
        scopedSave.start(); _ = await wait { scopedSave.session.phase == .recording }; scopedSave.stop(); _ = await wait { scopedSave.session.phase == .review }
        scopedSave.editCaption("Frozen original owner Save")
        let inFlightSave = Task { await scopedSave.save() }
        let reachedSave = await wait { scopeGate.entered }
        context.scope = .init(workspace: .init(account: "another-save-account", generation: UUID()), target: target)
        scopedSave.contextChanged(); scopeGate.release()
        let shownSave = await inFlightSave.value
        let originalOwnerSaved = try await scopeDisk.drafts(), originalOwnerJournals = try await scopeDisk.saves()
        let otherOwnerStore = AudioCommentDraftStorage(applicationSupport: root.appendingPathComponent("save-scope-change"), owner: try .init("another-save-account"))
        let otherOwnerSaved = try await otherOwnerStore.drafts()
        checks["inFlightDurableSaveFinishesOnlyOriginalOwnerAndClearsClosedPreview"] = reachedSave && !shownSave && originalOwnerSaved.count == 1 && originalOwnerSaved.first?.caption == "Frozen original owner Save" && originalOwnerJournals.isEmpty && otherOwnerSaved.isEmpty && scopedSave.session.clip == nil && !scopedSave.recovery.durable
        context.scope = request.scope
        let realRecorder = DeviceAudioCommentRecording(), realPlayer = DeviceAudioCommentPlaying()
        var falseGate = false, falsePlay = false
        do { try await realRecorder.start(isCurrent: { false }, receive: { _ in }) } catch is CancellationError { falseGate = true }
        do { try realPlayer.play(try AudioCommentClip(data: data), isCurrent: { false }, ended: {}) } catch is CancellationError { falsePlay = true }
        checks["realDriversRejectFalseScopeBeforeAudioAccess"] = falseGate && falsePlay
        let lease = UUID(); _ = TaskfoldAudioLease.claim(lease)
        var recordBusy = false, playBusy = false
        do { try await realRecorder.start(isCurrent: { true }, receive: { _ in }) } catch is AudioCommentFailure { recordBusy = true }
        do { try realPlayer.play(try AudioCommentClip(data: data), isCurrent: { true }, ended: {}) } catch is AudioCommentFailure { playBusy = true }
        checks["sharedAudioLeaseRefusesOverlapWithoutTakingOwnership"] = recordBusy && playBusy && TaskfoldAudioLease.owner == lease
        realRecorder.cancel(); realPlayer.stop(); TaskfoldAudioLease.release(lease)
        checks["allMediaLeasesReleased"] = TaskfoldAudioLease.owner == nil
        try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
        guard checks.values.allSatisfy({ $0 }) else { fputs("Failed audio checks: " + checks.filter { !$0.value }.keys.sorted().joined(separator: ", ") + "\n", stderr); exit(1) }
    }
}
