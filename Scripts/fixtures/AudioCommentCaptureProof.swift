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

/// Holds a real second file-description lock between failed commit and state read.
final class AudioProofLookupLock: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let interrupt: AudioCommentVault.Checkpoint
    private let owner: AudioCommentOwner
    private var enabled: Bool
    private var saves: [AudioCommentSaveIntent] = []
    private var interrupted = false, released = false
    private var fd: Int32 = -1
    init(directory: URL, owner: AudioCommentOwner, interrupt: AudioCommentVault.Checkpoint, enabled: Bool = true) { self.directory = directory; self.owner = owner; self.interrupt = interrupt; self.enabled = enabled }
    var observedSaves: [AudioCommentSaveIntent] { lock.lock(); defer { lock.unlock() }; return saves }
    func armLookupOnly() { lock.lock(); enabled = true; interrupted = true; lock.unlock() }
    var isHolding: Bool { lock.lock(); defer { lock.unlock() }; return fd >= 0 }
    func check(_ point: AudioCommentVault.Checkpoint) throws {
        lock.lock(); defer { lock.unlock() }
        if point == .beforeRename {
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasPrefix(".write-") {
                if let data = try? Data(contentsOf: file), let intent = try? AudioCommentSaveIntent(encoded: data, owner: owner) { saves.append(intent) }
            }
        }
        guard enabled else { return }
        if point == interrupt, !interrupted { interrupted = true; throw AudioCommentStorageFailure.unreadable }
        if point == .beforeSaveState, interrupted, !released, fd < 0 {
            let next = Darwin.open(directory.appendingPathComponent(".lock").path, O_RDWR | O_NOFOLLOW)
            guard next >= 0 else { throw AudioCommentStorageFailure.unreadable }
            guard flock(next, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(next); throw AudioCommentStorageFailure.unreadable }
            fd = next
        }
    }
    func release() {
        lock.lock(); defer { lock.unlock() }; released = true
        if fd >= 0 { _ = flock(fd, LOCK_UN); Darwin.close(fd); fd = -1 }
    }
    deinit { if fd >= 0 { _ = flock(fd, LOCK_UN); Darwin.close(fd) } }
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
        // Commit acknowledgement and the subsequent state lookup can both fail.
        // A later busy retry must not downgrade that unknown outcome to pre-write.
        for (suffix, point) in [("before-draft", AudioCommentVault.Checkpoint.afterSaveJournal), ("after-draft", AudioCommentVault.Checkpoint.afterDraftCommit)] {
            let folder = root.appendingPathComponent("unknown-save-" + suffix, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let vault = AudioCommentVault(applicationSupport: folder, owner: owner)
            let gate = AudioProofLookupLock(directory: vault.directory, owner: owner, interrupt: point)
            defer { gate.release() }
            let lockedDisk = AudioCommentDraftStorage(vault: .init(applicationSupport: folder, owner: owner, fault: { try gate.check($0) }))
            let review = make(AudioProofRecorder(data), AudioProofPlayer(), lockedDisk)
            review.start(); _ = await wait { review.session.phase == .recording }; review.stop(); _ = await wait { review.session.phase == .review }
            let caption = "Frozen unknown Save cafe\u{301} 🪴"
            review.editCaption(caption); _ = await review.preserveReview()
            let first = await review.save()
            let journals = try FileManager.default.contentsOfDirectory(at: vault.directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("save-") }
            guard journals.count == 1 else { throw AudioCommentStorageFailure.unreadable }
            let journalBytes = try Data(contentsOf: journals[0]), original = try AudioCommentSaveIntent(encoded: journalBytes, owner: owner)
            checks["unknownLookupFreezesInitialSave-" + suffix] = !first && gate.isHolding && review.saveUnconfirmed && !review.editable && review.session.caption.utf8.elementsEqual(caption.utf8)
            let second = await review.save()
            review.editCaption("Must not become a second recording")
            checks["unknownBusyRetryRemainsFrozen-" + suffix] = !second && review.saveUnconfirmed && !review.editable && !review.saveConflict && review.session.caption.utf8.elementsEqual(caption.utf8)
            checks["unknownBusyRetryPreservesExactJournal-" + suffix] = try Data(contentsOf: journals[0]) == journalBytes
            gate.release()
            let final = await review.save(), finalDrafts = try await lockedDisk.drafts(), finalIntents = try await lockedDisk.saves()
            checks["unknownLookupRetryFinishesOriginalIDsOnce-" + suffix] = final && finalDrafts == [original.next] && finalIntents.isEmpty && review.saved == original.next && !review.saveUnconfirmed && !review.needsSave
            review.close()
        }
        // A conflict-copy replacement also owns the original operation while
        // the state read is unavailable; busy must not abandon that replacement.
        do {
            let folder = root.appendingPathComponent("unknown-conflict-copy", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let vault = AudioCommentVault(applicationSupport: folder, owner: owner)
            let gate = AudioProofLookupLock(directory: vault.directory, owner: owner, interrupt: .afterSaveJournal, enabled: false)
            defer { gate.release() }
            let disk = AudioCommentDraftStorage(vault: .init(applicationSupport: folder, owner: owner, fault: { try gate.check($0) }))
            let review = make(AudioProofRecorder(data), AudioProofPlayer(), disk)
            review.start(); _ = await wait { review.session.phase == .recording }; review.stop(); _ = await wait { review.session.phase == .review }
            review.editCaption("Earlier saved version"); _ = await review.save()
            guard let earlier = review.saved else { throw AudioCommentStorageFailure.unreadable }
            let concurrent = try earlier.replacing(caption: "Other window’s saved version", clip: earlier.clip)
            try await disk.save(concurrent, replacing: earlier.revision)
            let caption = "Keep my reviewed conflict copy cafe\u{301}"
            review.editCaption(caption); _ = await review.preserveReview(); gate.armLookupOnly()
            let conflicted = await review.save()
            let journals = try FileManager.default.contentsOfDirectory(at: vault.directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("save-") }
            guard journals.count == 1 else { throw AudioCommentStorageFailure.unreadable }
            let journalBytes = try Data(contentsOf: journals[0]), original = try AudioCommentSaveIntent(encoded: journalBytes, owner: owner)
            checks["unknownConflictLookupKeepsOriginalOperation"] = !conflicted && review.saveConflict && gate.isHolding && original.next.id == earlier.id
            let copy = await review.saveSeparateDraft(); review.editCaption("Must not change the frozen copy")
            checks["unknownBusyCopyRemainsFrozen"] = !copy && review.saveUnconfirmed && !review.saveConflict && !review.editable && review.session.caption.utf8.elementsEqual(caption.utf8)
            checks["unknownBusyCopyKeepsOldJournalUntilReplacement"] = try Data(contentsOf: journals[0]) == journalBytes
            gate.release()
            let final = await review.save(), drafts = try await disk.drafts(), intents = try await disk.saves()
            let rewritten = gate.observedSaves.last { $0.id == original.id }
            checks["unknownCopyRetryKeepsBothVersionsAndOriginalOperation"] = final && intents.isEmpty && drafts.count == 2 && drafts.contains(concurrent) && review.saved?.id != earlier.id && review.saved?.caption.utf8.elementsEqual(caption.utf8) == true && rewritten?.next == review.saved && rewritten?.next.id != original.next.id
            review.close()
        }
        // A prepared original Save does not make an unpersisted conflict copy
        // durable. A blocked replacement must keep the window's exact choice.
        do {
            let folder = root.appendingPathComponent("blocked-known-copy", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let vault = AudioCommentVault(applicationSupport: folder, owner: owner)
            let observer = AudioProofLookupLock(directory: vault.directory, owner: owner, interrupt: .afterSaveJournal, enabled: false)
            let disk = AudioCommentDraftStorage(vault: .init(applicationSupport: folder, owner: owner, fault: { try observer.check($0) }))
            let review = make(AudioProofRecorder(data), AudioProofPlayer(), disk)
            review.start(); _ = await wait { review.session.phase == .recording }; review.stop(); _ = await wait { review.session.phase == .review }
            review.editCaption("Saved before a concurrent edit"); _ = await review.save()
            guard let initial = review.saved else { throw AudioCommentStorageFailure.unreadable }
            let concurrent = try initial.replacing(caption: "Keep the other window’s version", clip: initial.clip)
            try await disk.save(concurrent, replacing: initial.revision)
            let caption = "Retain my explicit separate copy"
            review.editCaption(caption); _ = await review.preserveReview(); _ = await review.save()
            let original = try await disk.saves()
            guard original.count == 1 else { throw AudioCommentStorageFailure.unreadable }
            checks["preparedConflictedOriginalRemainsDurable"] = review.saveConflict && review.saveDurable
            let lock = Darwin.open(vault.directory.appendingPathComponent(".lock").path, O_RDWR | O_NOFOLLOW)
            guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw AudioCommentStorageFailure.unreadable }
            let copied = await review.saveSeparateDraft()
            checks["blockedCopyDoesNotInheritOriginalDurability"] = !copied && !review.saveDurable && review.saveUnconfirmed && !review.editable
            _ = flock(lock, LOCK_UN); Darwin.close(lock)
            checks["blockedCopyPreservesOriginalOnDiskAuthorization"] = try await disk.saves() == original
            let final = await review.save(), drafts = try await disk.drafts(), remaining = try await disk.saves()
            let rewritten = observer.observedSaves.last { $0.id == original[0].id }
            checks["blockedCopyFinishesChosenReplacementWithoutAnotherOperation"] = final && remaining.isEmpty && drafts.count == 2 && drafts.contains(concurrent) && review.saved?.caption == caption && review.saved?.id != concurrent.id && rewritten?.next == review.saved
            review.close()
        }
        // A workspace departure with an unknown result clears the UI, while
        // the original journal can be completed from a fresh owner-bound session.
        for (suffix, point) in [("before-draft", AudioCommentVault.Checkpoint.afterSaveJournal), ("after-draft", AudioCommentVault.Checkpoint.afterDraftCommit)] {
            let folder = root.appendingPathComponent("unknown-departure-" + suffix, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let vault = AudioCommentVault(applicationSupport: folder, owner: owner)
            let gate = AudioProofLookupLock(directory: vault.directory, owner: owner, interrupt: point)
            defer { gate.release() }
            let disk = AudioCommentDraftStorage(vault: .init(applicationSupport: folder, owner: owner, fault: { try gate.check($0) }))
            let review = make(AudioProofRecorder(data), AudioProofPlayer(), disk)
            review.start(); _ = await wait { review.session.phase == .recording }; review.stop(); _ = await wait { review.session.phase == .review }
            let caption = "Keep the original owner’s unknown Save"
            review.editCaption(caption); _ = await review.preserveReview(); _ = await review.save()
            let files = try FileManager.default.contentsOfDirectory(at: vault.directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("save-") }
            guard files.count == 1 else { throw AudioCommentStorageFailure.unreadable }
            let original = try AudioCommentSaveIntent(encoded: Data(contentsOf: files[0]), owner: owner)
            context.scope = .init(workspace: .init(account: "another-owner", generation: UUID()), target: target)
            review.contextChanged()
            checks["unknownDepartureClearsVisibleMedia-" + suffix] = review.session.phase == .closed && review.session.clip == nil && review.session.caption.isEmpty
            let blocked = make(AudioProofRecorder(data), AudioProofPlayer(), disk); await blocked.refresh()
            checks["foreignWorkspaceCannotReadUnknownSave-" + suffix] = blocked.pendingSaves.isEmpty && blocked.available.isEmpty && blocked.recoverable.isEmpty
            blocked.close(); gate.release(); context.scope = request.scope
            let fresh = make(AudioProofRecorder(data), AudioProofPlayer(), disk); await fresh.refresh()
            let pending = fresh.pendingSaves
            await fresh.resumeSave(original)
            let drafts = try await disk.drafts(), remaining = try await disk.saves()
            checks["freshOwnerSessionFinishesUnknownSaveExactlyOnce-" + suffix] = pending == [original] && fresh.saved == original.next && drafts == [original.next] && remaining.isEmpty && fresh.pendingSaves.isEmpty
            fresh.close()
        }
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
        checks["relaunchListsOriginalSaveAndHidesItsRecoveryCopies"] = coldReturn.pendingSaves == coldIntents && coldReturn.recoverable.isEmpty && coldReturn.available.isEmpty
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
        let sharedDisk = try store("shared-review")
        let sharedRoot = try AudioCommentSavedDraft(owner: owner, target: target, caption: "Shared exact cafe\u{301}", clip: await AudioCommentDecoding.validate(data))
        try await sharedDisk.checkpoint(sharedRoot)
        let editorA = make(AudioProofRecorder(data), AudioProofPlayer(), sharedDisk), editorB = make(AudioProofRecorder(data), AudioProofPlayer(), sharedDisk)
        await editorA.restore(sharedRoot, recovering: true); await editorB.restore(sharedRoot, recovering: true)
        let firstEditorSave = await editorA.save(), secondEditorSave = await editorB.save()
        let sharedSaved = try await sharedDisk.drafts(), sharedReviews = try await sharedDisk.reviews()
        checks["twoLoadedEditorsSaveSameReviewAsOneAuthoritativeDraft"] = firstEditorSave && secondEditorSave && sharedSaved.count == 1 && editorA.saved?.id == editorB.saved?.id && sharedReviews.isEmpty && sharedSaved.first?.origin == AudioCommentReviewReference(sharedRoot)
        editorA.close(); editorB.close()

        let editedDisk = try store("different-review")
        try await editedDisk.checkpoint(sharedRoot)
        let editedA = make(AudioProofRecorder(data), AudioProofPlayer(), editedDisk), editedB = make(AudioProofRecorder(data), AudioProofPlayer(), editedDisk)
        await editedA.restore(sharedRoot, recovering: true); await editedB.restore(sharedRoot, recovering: true)
        editedB.editCaption("Keep my independently edited caption")
        _ = await editedA.save(); let implicitlyCopied = await editedB.save()
        checks["differentEditorContentIsPreservedBehindExplicitCopyChoice"] = !implicitlyCopied && editedB.reviewClaimed && editedB.saveConflict && editedB.session.caption == "Keep my independently edited caption"
        let explicitEditedCopy = await editedB.saveSeparateDraft(), independentVersions = try await editedDisk.drafts()
        checks["explicitClaimedReviewCopyKeepsBothVersionsWithoutOriginCollision"] = explicitEditedCopy && independentVersions.count == 2 && independentVersions.contains { $0.origin == nil && $0.caption == "Keep my independently edited caption" } && independentVersions.contains { $0.origin == AudioCommentReviewReference(sharedRoot) }
        editedA.close(); editedB.close()

        let joiningDisk = try store("join-prepared-review", fault: { if $0 == .afterSaveJournal { throw AudioCommentStorageFailure.unreadable } })
        try await joiningDisk.checkpoint(sharedRoot)
        let joiningA = make(AudioProofRecorder(data), AudioProofPlayer(), joiningDisk), joiningB = make(AudioProofRecorder(data), AudioProofPlayer(), joiningDisk)
        await joiningA.restore(sharedRoot, recovering: true); await joiningB.restore(sharedRoot, recovering: true)
        _ = await joiningA.save(); let firstPrepared = try await joiningDisk.saves()
        let joinedPrepared = await joiningB.save(), joinedDrafts = try await joiningDisk.drafts(), joinedIntents = try await joiningDisk.saves()
        checks["secondEditorJoinsPreparedOperationWithoutCreatingOwnJournal"] = joinedPrepared && firstPrepared.count == 1 && joinedDrafts.count == 1 && joinedDrafts.first?.id == firstPrepared.first?.next.id && joinedIntents.isEmpty
        joiningA.close(); joiningB.close()

        let discardGate = AudioProofOneShotFault(point: .afterDiscardJournal)
        let discardingDisk = try store("cancel-pending", fault: { point in
            if point == .afterSaveJournal { throw AudioCommentStorageFailure.unreadable }
            try discardGate.check(point)
        })
        let preparingDiscard = make(AudioProofRecorder(data), AudioProofPlayer(), discardingDisk)
        preparingDiscard.start(); _ = await wait { preparingDiscard.session.phase == .recording }; preparingDiscard.stop(); _ = await wait { preparingDiscard.session.phase == .review }
        preparingDiscard.editCaption("Only synthetic unfinished audio")
        _ = await preparingDiscard.save(); let beforeDiscard = try await discardingDisk.saves(); preparingDiscard.close()
        let discardReturn = make(AudioProofRecorder(data), AudioProofPlayer(), discardingDisk); await discardReturn.refresh()
        if let pending = discardReturn.pendingSaves.first { await discardReturn.discardPendingSave(pending) }
        let markedDiscard = try await discardingDisk.saves()
        checks["cancelAcknowledgementLossListsDurableDiscardInsteadOfSave"] = markedDiscard.count == 1 && markedDiscard.first?.phase == .discarding && discardReturn.pendingSaves.first?.phase == .discarding && discardReturn.session.clip == nil
        discardReturn.close()
        let finalDiscardReturn = make(AudioProofRecorder(data), AudioProofPlayer(), discardingDisk); await finalDiscardReturn.refresh()
        if let stale = beforeDiscard.first { await finalDiscardReturn.resumeSave(stale) }
        let discardedFinalDrafts = try await discardingDisk.drafts(), discardedFinalIntents = try await discardingDisk.saves(), discardedFinalReviews = try await discardingDisk.reviews()
        checks["coldStaleFinishCompletesAuthoritativeDiscardWithoutPlaybackOrResurrection"] = discardedFinalDrafts.isEmpty && discardedFinalIntents.isEmpty && discardedFinalReviews.isEmpty && finalDiscardReturn.session.clip == nil
        finalDiscardReturn.close()

        let savedCancelDisk = try store("cancel-already-saved", fault: { if $0 == .afterDraftCommit { throw AudioCommentStorageFailure.unreadable } })
        let alreadySaved = make(AudioProofRecorder(data), AudioProofPlayer(), savedCancelDisk)
        alreadySaved.start(); _ = await wait { alreadySaved.session.phase == .recording }; alreadySaved.stop(); _ = await wait { alreadySaved.session.phase == .review }
        _ = await alreadySaved.save(); alreadySaved.close()
        let savedCancelReturn = make(AudioProofRecorder(data), AudioProofPlayer(), savedCancelDisk); await savedCancelReturn.refresh()
        let primaryBeforeCancel = try await savedCancelDisk.drafts()
        if let pending = savedCancelReturn.pendingSaves.first { await savedCancelReturn.discardPendingSave(pending) }
        let primaryAfterCancel = try await savedCancelDisk.drafts()
        checks["pendingDiscardRefusesAlreadyCommittedAudioAndKeepsFinishAction"] = primaryBeforeCancel == primaryAfterCancel && primaryAfterCancel.count == 1 && savedCancelReturn.pendingSaves.count == 1 && savedCancelReturn.notice == AudioCommentStorageFailure.alreadySaved.localizedDescription
        if let pending = savedCancelReturn.pendingSaves.first { await savedCancelReturn.resumeSave(pending) }
        let finalSavedAfterRefusal = try await savedCancelDisk.drafts()
        checks["alreadySavedRefusalCanFinishWithoutASecondDraft"] = finalSavedAfterRefusal == primaryBeforeCancel && savedCancelReturn.pendingSaves.isEmpty
        savedCancelReturn.close()

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
