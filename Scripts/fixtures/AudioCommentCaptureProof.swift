import Foundation
import Darwin
@testable import TaskfoldCore


@MainActor final class AudioRemoteProofTransport: AudioCommentReadingTransport {
    var rows: [AudioCommentRemote] = []
    var clip: AudioCommentClip
    var lists = 0, downloads = 0, removals = 0
    var failRemoval = false, holdList = false, holdDownload = false
    var continuation: CheckedContinuation<Void, Never>?
    init(_ clip: AudioCommentClip) { self.clip = clip }
    func release() { continuation?.resume(); continuation = nil }
    func listAudio(account: UUID, target: AudioCommentTarget, origin: String, incarnation: UUID) async throws -> [AudioCommentRemote] {
        lists += 1; if holdList { await withCheckedContinuation { continuation = $0 } }; return rows
    }
    func downloadAudio(_ comment: AudioCommentRemote, origin: String, incarnation: UUID) async throws -> AudioCommentClip {
        downloads += 1; if holdDownload { await withCheckedContinuation { continuation = $0 } }; return clip
    }
    func removeAudio(_ comment: AudioCommentRemote, origin: String, incarnation: UUID) async throws -> AudioCommentRemoteRemoval {
        removals += 1; if failRemoval { throw URLError(.networkConnectionLost) }
        rows.removeAll { $0.id == comment.id }
        return try .init(data: JSONEncoder().encode(Record(["protocol":.number(1),"account":.string(comment.publication.account.uuidString.lowercased()),"operation_id":.string(comment.publication.operation.uuidString.lowercased()),"comment_id":.string(comment.id.uuidString.lowercased()),"state":.string("retired")])), expected: comment)
    }
}

@MainActor final class AudioProofContext { var scope: AudioCommentLiveScope; init(_ scope: AudioCommentLiveScope) { self.scope = scope } }
@MainActor final class AudioProofRecorder: AudioCommentRecording {
    var callbacks: [@MainActor (AudioCommentRecordingEvent) -> Void] = []
    var permits: [@MainActor () -> Bool] = []
    var elapsed: TimeInterval = 0
    var denied = false, suspended = false, finishDelay = false
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
    func finish() {
        if finishDelay { let callback = callbacks.last, bytes = data; Task { @MainActor in try? await Task.sleep(for:.milliseconds(40)); callback?(.finished(bytes)) } }
        else { callbacks.last?(.finished(data)) }
    }
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

/// Refuses only the Save journal rename, then holds a separate real lookup lock.
final class AudioProofPrejournalGate: @unchecked Sendable {
    private let lock = NSLock()
    let directory: URL; let owner: AudioCommentOwner
    private var interrupted = false, released = false
    private var fd: Int32 = -1
    private var proposal: AudioCommentSaveIntent?
    init(_ directory: URL, _ owner: AudioCommentOwner) { self.directory = directory; self.owner = owner }
    var submitted: AudioCommentSaveIntent? { lock.lock(); defer { lock.unlock() }; return proposal }
    func check(_ point: AudioCommentVault.Checkpoint) throws {
        lock.lock(); defer { lock.unlock() }
        if point == .beforeRename, !interrupted {
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasPrefix(".write-") {
                if let data = try? Data(contentsOf: file), let intent = try? AudioCommentSaveIntent(encoded: data, owner: owner) {
                    proposal = intent; interrupted = true; throw AudioCommentStorageFailure.unreadable
                }
            }
        }
        if point == .beforeSaveState, interrupted, !released, fd < 0 {
            let next = Darwin.open(directory.appendingPathComponent(".lock").path, O_RDWR | O_NOFOLLOW)
            guard next >= 0 else { throw AudioCommentStorageFailure.unreadable }
            guard flock(next, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(next); throw AudioCommentStorageFailure.unreadable }
            fd = next
        }
    }
    func arm() { lock.lock(); defer { lock.unlock() }; interrupted = false; released = false }
    func release() { lock.lock(); defer { lock.unlock() }; released = true; if fd >= 0 { _ = flock(fd, LOCK_UN); Darwin.close(fd); fd = -1 } }
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
        checks.merge(try await libraryChecks(root: root, data: data, request: request)) { _, new in new }
        checks.merge(try await portableImportChecks(root: root, data: data, request: request)) { _, new in new }
        checks.merge(try await portableExportChecks(root: root, data: data, request: request)) { _, new in new }
        checks.merge(try await departureChecks(root:root,data:data,request:request,context:context)) { _, new in new }
        checks.merge(try await interruptedChecks(root: root, data: data, request: request)) { _, new in new }
        checks.merge(try await interruptedCopyChecks(root: root, data: data, request: request)) { _, new in new }
        checks.merge(try await appOriginChecks(root: root, data: data, request: request)) { _, new in new }
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


        let workspaceChecks = try await workspaceReturnChecks(root: root, data: data, workspace: workspace, target: target, request: request, context: context)
        for (name, passed) in workspaceChecks { checks[name] = passed }

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
        checks.merge(try await pendingPublicationChecks(root: root, data: data)) { _, new in new }
        checks.merge(try await remoteConversationChecks(data: data)) { _, new in new }
        try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
        guard checks.values.allSatisfy({ $0 }) else { fputs("Failed audio checks: " + checks.filter { !$0.value }.keys.sorted().joined(separator: ", ") + "\n", stderr); exit(1) }
    }
    @MainActor private static func departureChecks(root: URL, data: Data, request: AudioCommentDraftRequest, context: AudioProofContext) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let owner = try AudioCommentOwner(request.scope.workspace.account)
        let folder = root.appendingPathComponent("departure", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let disk = AudioCommentDraftStorage(applicationSupport:folder,owner:owner)
        func make(_ driver: AudioProofRecorder, _ store: AudioCommentDraftStorage) -> AudioCommentCapture {
            let c = AudioCommentCapture(request:request,recorder:driver,player:AudioProofPlayer(),storage:store)
            c.currentScope = { context.scope }; return c
        }
        let recorder = AudioProofRecorder(data); recorder.finishDelay = true
        let c = make(recorder,disk), sameRequest = make(AudioProofRecorder(data),disk)
        c.start(); _ = await wait { c.session.phase == .recording }
        checks["departureTracksTwoControllersSharingOneRequestWithoutLosingActiveRecording"] = AudioCommentCapture.hasUnpreservedWork
        let kept = await AudioCommentCapture.preserveForDeparture()
        checks["departureAwaitsDelayedRecorderFinishAndDecode"] = kept && c.session.phase == .review && c.session.clip?.data == data
        let initialDrafts = try await disk.drafts(), initialReviews = try await disk.reviews()
        checks["departureCheckpointsReviewWithoutExplicitDraftSave"] = initialDrafts.isEmpty && initialReviews.count == 1
        c.editCaption("Exact cafe\u{301} before background 🪴"); c.play()
        AudioCommentCapture.stopPlaybackForInactivity()
        checks["inactivityStopsPlaybackSynchronouslyBeforeBackgroundWork"] = !c.playing
        c.play()
        let captionKept = await AudioCommentCapture.preserveForDeparture()
        let reviews = try await disk.reviews()
        checks["departureStopsPlaybackAndKeepsExactCaption"] = captionKept && !c.playing && reviews.first?.caption.utf8.elementsEqual(c.session.caption.utf8) == true
        checks["durableReviewNoLongerBlocksNormalQuit"] = !AudioCommentCapture.hasUnpreservedWork
        sameRequest.close(); c.close()

        let pendingFolder = root.appendingPathComponent("departure-pending",isDirectory:true)
        try FileManager.default.createDirectory(at:pendingFolder,withIntermediateDirectories:false)
        let vault = AudioCommentVault(applicationSupport:pendingFolder,owner:owner)
        let gate = AudioProofPrejournalGate(vault.directory,owner)
        let pendingStore = AudioCommentDraftStorage(vault:.init(applicationSupport:pendingFolder,owner:owner,fault:{ try gate.check($0) }))
        let pending = make(AudioProofRecorder(data),pendingStore)
        pending.start(); _ = await wait { pending.session.phase == .recording }; pending.stop(); _ = await wait { pending.session.phase == .review }
        pending.editCaption("Unwritten Save before Quit")
        _ = await pending.preserveReview(); gate.arm(); _ = await pending.save()
        guard let intent = gate.submitted else { throw AudioCommentStorageFailure.unreadable }
        let blocked = await AudioCommentCapture.preserveForDeparture()
        checks["departureFailureBlocksQuitWhileExactSaveExistsOnlyInMemory"] = !blocked && AudioCommentCapture.hasUnpreservedWork && pending.saveUnconfirmed
        context.scope = .init(workspace:.init(account:"foreign-departure-owner",generation:UUID()),target:request.scope.target)
        pending.contextChanged(); gate.release()
        let journalKept = await AudioCommentCapture.preserveForDeparture()
        let journals = try await pendingStore.saves(), drafts = try await pendingStore.drafts()
        checks["detachedOriginalOwnerSaveBecomesDurableWithoutFinishingOrRetargeting"] = journalKept && journals == [intent] && drafts.isEmpty && pending.session.clip == nil
        checks["durableDetachedAuthorizationDoesNotBlockQuit"] = !AudioCommentCapture.hasUnpreservedWork
        context.scope = request.scope
        let returned = make(AudioProofRecorder(data),pendingStore); await returned.refresh()
        checks["departureJournalReturnsAsOneExplicitFinishAction"] = returned.pendingSaves == [intent] && returned.session.clip == nil
        await returned.resumeSave(intent)
        let finalDrafts = try await pendingStore.drafts(), finalJournals = try await pendingStore.saves()
        checks["departureJournalFinishesExactOriginalDraftOnce"] = returned.saved == intent.next && finalDrafts == [intent.next] && finalJournals.isEmpty
        returned.close()

        let revokedFolder = root.appendingPathComponent("departure-revoked",isDirectory:true)
        try FileManager.default.createDirectory(at:revokedFolder,withIntermediateDirectories:false)
        let revokedVault = AudioCommentVault(applicationSupport:revokedFolder,owner:owner)
        let revokedGate = AudioProofLookupLock(directory:revokedVault.directory,owner:owner,interrupt:.afterSaveJournal,enabled:true)
        let revokedStore = AudioCommentDraftStorage(vault:.init(applicationSupport:revokedFolder,owner:owner,fault:{ try revokedGate.check($0) }))
        let revoked = make(AudioProofRecorder(data),revokedStore)
        revoked.start(); _ = await wait { revoked.session.phase == .recording }; revoked.stop(); _ = await wait { revoked.session.phase == .review }
        revoked.editCaption("This pending Save is discarded in another editor"); _ = await revoked.preserveReview(); _ = await revoked.save()
        revokedGate.release()
        guard let revokedIntent = try await revokedStore.saves().first else { throw AudioCommentStorageFailure.unreadable }
        try revokedVault.discardSave(revokedIntent)
        let revived = await revoked.prepareForDeparture(), revokedJournals = try await revokedStore.saves()
        checks["departureNeverAutomaticallyRevivesAnotherEditorsCompletedDiscard"] = !revived && revokedJournals.isEmpty
        revoked.recovery.finishSave(); revoked.close()
        // Dispose only the synthetic reproduction if the old implementation revived it.
        for journal in revokedJournals { try revokedVault.discardSave(journal) }

        let unfencedFolder = root.appendingPathComponent("departure-unfenced",isDirectory:true)
        try FileManager.default.createDirectory(at:unfencedFolder,withIntermediateDirectories:false)
        let unfencedVault = AudioCommentVault(applicationSupport:unfencedFolder,owner:owner)
        let unfencedStore = AudioCommentDraftStorage(vault:unfencedVault)
        let unfenced = make(AudioProofRecorder(data),unfencedStore)
        unfenced.start(); _ = await wait { unfenced.session.phase == .recording }; unfenced.stop(); _ = await wait { unfenced.session.phase == .review }
        unfenced.editCaption("Explicit Finish required when the initial fence was unreadable"); _ = await unfenced.preserveReview()
        let external = Darwin.open(unfencedVault.directory.appendingPathComponent(".lock").path,O_RDWR | O_NOFOLLOW)
        guard external >= 0, flock(external,LOCK_EX | LOCK_NB) == 0 else { throw AudioCommentStorageFailure.unreadable }
        _ = await unfenced.save()
        _ = flock(external,LOCK_UN); Darwin.close(external)
        let untrusted = await unfenced.prepareForDeparture(), untrustedJournals = try await unfencedStore.saves()
        checks["freshPrewriteRefusalPreservesReviewWithoutInventingSaveAuthorization"] = untrusted && untrustedJournals.isEmpty && !unfenced.saveUnconfirmed
        let explicitRetry = await unfenced.save(), explicitDrafts = try await unfencedStore.drafts()
        checks["explicitRetryCanCaptureFreshFenceAndFinishPreviouslyUnwrittenSave"] = explicitRetry && explicitDrafts.count == 1 && explicitDrafts.first == unfenced.saved
        unfenced.close()

        let knownFolder = root.appendingPathComponent("departure-existing-only",isDirectory:true)
        try FileManager.default.createDirectory(at:knownFolder,withIntermediateDirectories:false)
        let knownVault = AudioCommentVault(applicationSupport:knownFolder,owner:owner)
        let knownFault = AudioProofOneShotFault(point:.afterSaveJournal)
        let knownStore = AudioCommentDraftStorage(vault:.init(applicationSupport:knownFolder,owner:owner,fault:{ try knownFault.check($0) }))
        let known = make(AudioProofRecorder(data),knownStore)
        known.start(); _ = await wait { known.session.phase == .recording }; known.stop(); _ = await wait { known.session.phase == .review }
        _ = await known.preserveReview(); _ = await known.save()
        guard known.saveDurable, let knownIntent = try await knownStore.saves().first else { throw AudioCommentStorageFailure.unreadable }
        try knownVault.discardSave(knownIntent)
        _ = await known.save() // A retry may read the new nonce, but remains existing-only.
        let existingOnlyKept = await known.prepareForDeparture(), existingOnlyJournals = try await knownStore.saves()
        checks["departureCannotWidenKnownPreparedRetryEvenWithFreshNonce"] = !existingOnlyKept && existingOnlyJournals.isEmpty
        // Repeated explicit Retry must not drop the existing-only restriction
        // after a positively missing lookup. A reopen must carry it as well.
        let retryResults = [await known.save(), await known.save(), await known.save()]
        let retryDrafts = try await knownStore.drafts(), retryJournals = try await knownStore.saves()
        checks["repeatedRetryCannotRecreateAnExternallyDiscardedPreparedSave"] = retryResults.allSatisfy { !$0 } && retryDrafts.isEmpty && retryJournals.isEmpty
        checks["missingPreparedSaveKeepsOriginalReviewInMemoryForExplicitChoice"] = known.session.clip?.data == data && known.session.caption == knownIntent.next.caption && known.saveConflict && !known.saveDurable
        known.close()
        let reopened = make(AudioProofRecorder(data),knownStore); await reopened.refresh()
        checks["removedPreparedAuthorizationRemainsDiscoverableAfterViewReopen"] = reopened.pendingSaves == [knownIntent]
        await reopened.resumeSave(knownIntent)
        let reopenedDrafts = try await knownStore.drafts(), reopenedJournals = try await knownStore.saves()
        checks["reopeningRemovedPreparedSaveDoesNotWidenFinishAuthorization"] = reopenedDrafts.isEmpty && reopenedJournals.isEmpty && reopened.saveConflict && reopened.session.clip?.data == data
        knownFault.arm()
        let copied = await reopened.saveSeparateDraft(), copyJournal = try await knownStore.saves().first
        checks["explicitCopyOfRemovedSaveGetsNewOperationAndDraftWithoutOldCleanup"] = !copied && copyJournal?.id != knownIntent.id && copyJournal?.next.id != knownIntent.next.id && copyJournal?.reviews.isEmpty == true && copyJournal?.next.origin == nil && copyJournal?.next.clip.data == data && copyJournal?.next.caption.utf8.elementsEqual(knownIntent.next.caption.utf8) == true
        let finishedCopy = await reopened.save(), copiedDrafts = try await knownStore.drafts(), copiedJournals = try await knownStore.saves()
        checks["interruptedExplicitCopyFinishesOnlyItsNewFrozenAuthorization"] = finishedCopy && copiedDrafts.count == 1 && copiedDrafts.first == copyJournal?.next && copiedJournals.isEmpty && !copiedDrafts.contains(where: { $0.id == knownIntent.next.id })
        checks["successfulExplicitCopyRetiresOnlyTheExpiredRetainedAuthorization"] = AudioCommentReviewRecovery.retainedSave(knownIntent) == nil && !AudioCommentCapture.hasUnpreservedWork
        reopened.recovery.finishSave(); reopened.close(); known.recovery.finishSave()
        for journal in try await knownStore.saves() { try knownVault.discardSave(journal) }

        let discardFolder = root.appendingPathComponent("expired-review-discard",isDirectory:true)
        try FileManager.default.createDirectory(at:discardFolder,withIntermediateDirectories:false)
        let discardVault = AudioCommentVault(applicationSupport:discardFolder,owner:owner)
        let discardFault = AudioProofOneShotFault(point:.afterSaveJournal)
        let discardAck = AudioProofOneShotFault(enabled:false,point:.afterExpiredReviewDiscard)
        let discardStore = AudioCommentDraftStorage(vault:.init(applicationSupport:discardFolder,owner:owner,fault:{ try discardFault.check($0); try discardAck.check($0) }))
        let abandoned = make(AudioProofRecorder(data),discardStore)
        abandoned.start(); _ = await wait { abandoned.session.phase == .recording }; abandoned.stop(); _ = await wait { abandoned.session.phase == .review }
        abandoned.editCaption("Discard only this cafe\u{301} review"); _ = await abandoned.preserveReview(); _ = await abandoned.save()
        guard let abandonedIntent = try await discardStore.saves().first else { throw AudioCommentStorageFailure.unreadable }
        try discardVault.discardSave(abandonedIntent); _ = await abandoned.save()
        var unrelated: [AudioCommentSavedDraft] = []
        for index in 0..<AudioCommentVault.maximumEntries {
            let next = try AudioCommentSavedDraft(owner:owner,target:request.scope.target,caption:"Unrelated saved recording \(index)",clip:abandonedIntent.next.clip)
            try discardVault.save(next); unrelated.append(next)
        }
        let discardLock = Darwin.open(discardVault.directory.appendingPathComponent(".lock").path,O_RDWR | O_NOFOLLOW)
        guard discardLock >= 0, flock(discardLock,LOCK_EX | LOCK_NB) == 0 else { throw AudioCommentStorageFailure.unreadable }
        let blockedDiscard = await abandoned.discardReviewAndClose()
        _ = flock(discardLock,LOCK_UN); Darwin.close(discardLock)
        checks["expiredDiscardBusyRefusalKeepsTheReviewAndRetryChoice"] = !blockedDiscard && abandoned.canDiscardReview && abandoned.session.clip?.data == data
        discardAck.arm(); let uncertainDiscard = await abandoned.discardReviewAndClose()
        let uncertainDeparture = await abandoned.prepareForDeparture()
        checks["expiredDiscardLostAcknowledgementKeepsMemoryAndCannotClaimQuitSafety"] = !uncertainDiscard && !uncertainDeparture && abandoned.canDiscardReview && abandoned.session.clip?.data == data
        let didDiscard = await abandoned.discardReviewAndClose()
        let remaining = try discardVault.drafts(), remainingJournals = try discardVault.saves()
        checks["removedSaveReviewCanBeDiscardedDirectlyAtEntryQuota"] = didDiscard && remainingJournals.isEmpty
        checks["explicitExpiredDiscardClosesAndReleasesRetainedAuthorization"] = abandoned.session.phase == .closed && abandoned.session.clip == nil && !AudioCommentCapture.hasUnpreservedWork
        checks["expiredDiscardPreservesEveryUnrelatedRecordingAtQuota"] = remaining.count == unrelated.count && remaining.allSatisfy(unrelated.contains)
        abandoned.recovery.finishSave(); abandoned.close()

        let cancelFolder = root.appendingPathComponent("departure-cancel",isDirectory:true)
        try FileManager.default.createDirectory(at:cancelFolder,withIntermediateDirectories:false)
        let cancelStore = AudioCommentDraftStorage(applicationSupport:cancelFolder,owner:owner)
        let delayed = AudioProofRecorder(data); delayed.finishDelay = true
        let interrupted = make(delayed,cancelStore); interrupted.start(); _ = await wait { interrupted.session.phase == .recording }
        let waiting = Task { @MainActor in await interrupted.prepareForDeparture() }
        await Task.yield(); waiting.cancel()
        checks["backgroundAllowanceCancellationDoesNotClaimDurability"] = !(await waiting.value)
        let retry = await interrupted.prepareForDeparture()
        let cancelReviews = try await cancelStore.reviews()
        checks["interruptedBackgroundWaitCanRetryWithoutDroppingAudio"] = retry && interrupted.session.clip?.data == data && cancelReviews.count == 1
        interrupted.close()
        return checks
    }
    @MainActor private static func workspaceReturnChecks(root: URL, data: Data, workspace: WorkspaceBinding, target: AudioCommentTarget, request: AudioCommentDraftRequest, context: AudioProofContext) async throws -> [String: Bool] {
        let owner = try AudioCommentOwner(workspace.account)
        var checks: [String: Bool] = [:]
        func make(_ recorder: AudioProofRecorder, _ player: AudioProofPlayer, _ storage: AudioCommentDraftStorage) -> AudioCommentCapture {
            let capture = AudioCommentCapture(request: request, recorder: recorder, player: player, storage: storage)
            capture.currentScope = { context.scope }; return capture
        }
        // A failed automatic checkpoint plus a Save that never reached its
        // journal still needs the exact explicit authorization after scope loss.
        do {
            let folder = root.appendingPathComponent("prejournal-workspace-return", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let vault = AudioCommentVault(applicationSupport: folder, owner: owner)
            _ = try vault.drafts()
            let gate = AudioProofPrejournalGate(vault.directory, owner)
            defer { gate.release() }
            let disk = AudioCommentDraftStorage(vault: .init(applicationSupport: folder, owner: owner, fault: { try gate.check($0) }))
            let locked = Darwin.open(vault.directory.appendingPathComponent(".lock").path, O_RDWR | O_NOFOLLOW)
            guard locked >= 0, flock(locked, LOCK_EX | LOCK_NB) == 0 else { throw AudioCommentStorageFailure.unreadable }
            let review = make(AudioProofRecorder(data), AudioProofPlayer(), disk)
            review.start(); _ = await wait { review.session.phase == .recording }; review.stop()
            _ = await wait { review.session.phase == .review && review.recovery.failure != nil }
            let caption = "Keep the exact pre-journal Save cafe\u{301} 🪴"
            review.editCaption(caption)
            _ = flock(locked, LOCK_UN); Darwin.close(locked)
            let saved = await review.save()
            guard let original = gate.submitted else { throw AudioCommentStorageFailure.unreadable }
            checks["prejournalSaveRefusalKeepsOriginalFrozenAuthorization"] = !saved && review.saveUnconfirmed && !review.editable && review.session.caption.utf8.elementsEqual(caption.utf8)
            let journalFiles = try FileManager.default.contentsOfDirectory(at: vault.directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("save-") }
            checks["prejournalReproductionHasNoDurableSaveJournal"] = journalFiles.isEmpty
            context.scope = .init(workspace: .init(account: "foreign-prejournal-owner", generation: UUID()), target: target)
            review.contextChanged(); gate.release()
            checks["prejournalDepartureErasesVisiblePrivateContent"] = review.session.clip == nil && review.session.caption.isEmpty && review.session.phase == .closed
            let foreign = make(AudioProofRecorder(data), AudioProofPlayer(), disk); await foreign.refresh(); await foreign.resumeSave(original)
            let foreignDrafts = try await disk.drafts()
            checks["foreignOwnerCannotDiscoverOrFinishPrejournalSave"] = foreign.pendingSaves.isEmpty && foreign.session.clip == nil && foreignDrafts.isEmpty
            foreign.close(); context.scope = request.scope
            let returned = make(AudioProofRecorder(data), AudioProofPlayer(), disk); await returned.refresh(); await returned.refresh()
            checks["returningOwnerSeesOneExactPrejournalSave"] = returned.pendingSaves == [original] && returned.available.isEmpty
            let discoveryDrafts = try await disk.drafts(), discoverySaves = try await disk.saves()
            checks["prejournalDiscoveryDoesNotAutoSaveOrRewriteAuthorization"] = discoveryDrafts.isEmpty && discoverySaves.isEmpty
            checks["unwrittenSaveWarnsBeforeQuitAndRefusesPrematureDiscard"] = returned.hasUnwrittenSaves && returned.isRetainedSave(original)
            await returned.discardPendingSave(original)
            let afterDiscard = try await disk.drafts(), afterDiscardIntents = try await disk.saves()
            checks["volatileDiscardCannotForgetOrPretendToDeleteThePendingSave"] = returned.pendingSaves == [original] && afterDiscard.isEmpty && afterDiscardIntents.isEmpty
            let changed = try original.next.replacing(caption: "Forged pending caption", clip: original.next.clip)
            let forged = try AudioCommentSaveIntent(next: changed, base: original.base, reviews: original.reviews, id: original.id)
            await returned.resumeSave(forged)
            checks["sameOperationWithDifferentAuthorizationCannotReadOrReplaceRetainedSave"] = returned.session.clip == nil && returned.pendingSaves == [original]
            let otherTarget = try AudioCommentTarget(task: target.task, generation: UUID(), project: target.project)
            let otherContext = AudioProofContext(.init(workspace: workspace, target: otherTarget))
            let other = AudioCommentCapture(request: .init(scope: otherContext.scope, title: "Different task incarnation"), recorder: AudioProofRecorder(data), player: AudioProofPlayer(), storage: disk)
            other.currentScope = { otherContext.scope }; await other.refresh(); await other.resumeSave(original)
            checks["newTaskIncarnationCannotDiscoverOrFinishRetainedSave"] = other.pendingSaves.isEmpty && other.session.clip == nil
            other.close(); returned.close()
            var retriesPreserveOneAuthorization = true
            for _ in 0..<(AudioCommentVault.maximumEntries + 3) {
                let retry = make(AudioProofRecorder(data), AudioProofPlayer(), disk); await retry.refresh()
                retriesPreserveOneAuthorization = retriesPreserveOneAuthorization && retry.pendingSaves == [original]
                gate.arm(); await retry.resumeSave(original)
                retriesPreserveOneAuthorization = retriesPreserveOneAuthorization && retry.saveUnconfirmed && retry.session.caption.utf8.elementsEqual(caption.utf8) && gate.submitted == original
                retry.close(); gate.release()
            }
            checks["repeatedFailedPresentationsDoNotConsumeAnotherRetainedSlotOrMintIDs"] = retriesPreserveOneAuthorization
            checks["frozenRecoveryCannotCheckpointAroundUnresolvedSave"] = !(await review.preserveReview())
            returned.close()
            let reopened = make(AudioProofRecorder(data), AudioProofPlayer(), disk); await reopened.refresh()
            checks["repeatedPresentationRetainsSamePrejournalOperation"] = reopened.pendingSaves == [original]
            await reopened.resumeSave(original)
            let drafts = try await disk.drafts(), journals = try await disk.saves(), reviews = try await disk.reviews()
            checks["finishingUnwrittenSaveClearsRecoveryWarningInCurrentPresentation"] = !reopened.retainedRecoveryFailed
            checks["prejournalFinishSavesOriginalIDsAndCaptionExactlyOnce"] = reopened.saved == original.next && drafts == [original.next] && journals.isEmpty && reviews.isEmpty && reopened.pendingSaves.isEmpty
            reopened.close()
            let final = make(AudioProofRecorder(data), AudioProofPlayer(), disk); await final.refresh()
            checks["settledPrejournalAttemptDoesNotReturnAsRetainedFailure"] = final.pendingSaves.isEmpty && !final.retainedRecoveryFailed && final.available == [original.next] && final.recoverable.isEmpty
            final.close()
        }

        do {
            let folder = root.appendingPathComponent("copy-workspace-return", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let vault = AudioCommentVault(applicationSupport: folder, owner: owner)
            let observer = AudioProofLookupLock(directory: vault.directory, owner: owner, interrupt: .afterSaveJournal, enabled: false)
            let disk = AudioCommentDraftStorage(vault: .init(applicationSupport: folder, owner: owner, fault: { try observer.check($0) }))
            let review = make(AudioProofRecorder(data), AudioProofPlayer(), disk)
            review.start(); _ = await wait { review.session.phase == .recording }; review.stop(); _ = await wait { review.session.phase == .review }
            review.editCaption("Earlier local recording"); _ = await review.save()
            guard let initial = review.saved else { throw AudioCommentStorageFailure.unreadable }
            let concurrent = try initial.replacing(caption: "Preserve the other window’s version", clip: initial.clip)
            try await disk.save(concurrent, replacing: initial.revision)
            let caption = "My explicit separate copy after a workspace switch"
            review.editCaption(caption); _ = await review.preserveReview(); _ = await review.save()
            guard let old = try await disk.saves().first else { throw AudioCommentStorageFailure.unreadable }
            let locked = Darwin.open(vault.directory.appendingPathComponent(".lock").path, O_RDWR | O_NOFOLLOW)
            guard locked >= 0, flock(locked, LOCK_EX | LOCK_NB) == 0 else { throw AudioCommentStorageFailure.unreadable }
            let copied = await review.saveSeparateDraft()
            checks["workspaceCopyReproductionIsUnconfirmedBeforeJournalReplacement"] = !copied && review.saveUnconfirmed && !review.saveDurable
            context.scope = .init(workspace: .init(account: "other-copy-owner", generation: UUID()), target: target)
            review.contextChanged(); _ = flock(locked, LOCK_UN); Darwin.close(locked)
            checks["workspaceCopyDepartureClearsVisiblePrivateContent"] = review.session.clip == nil && review.session.caption.isEmpty
            context.scope = request.scope
            let fresh = make(AudioProofRecorder(data), AudioProofPlayer(), disk); await fresh.refresh()
            let chosen = fresh.pendingSaves.first
            checks["returningCopyKeepsOperationButRetainsChosenNewDraftIdentity"] = fresh.pendingSaves.count == 1 && chosen?.id == old.id && chosen?.next.id != old.next.id && chosen?.next.caption == caption
            checks["discoveringChosenCopyDoesNotRewriteOriginalOnDiskJournal"] = try await disk.saves() == [old]
            await fresh.resumeSave(old)
            checks["staleOldAuthorizationCannotSupersedeChosenRetainedCopy"] = fresh.session.clip == nil && fresh.pendingSaves == (chosen.map { [$0] } ?? [])
            if let chosen { await fresh.resumeSave(chosen) }
            let drafts = try await disk.drafts(), pending = try await disk.saves()
            checks["returnedSeparateCopyCompletesExactChosenDraftAndPreservesOtherWindow"] = chosen != nil && fresh.saved == chosen?.next && drafts.count == 2 && drafts.contains(concurrent) && drafts.contains(where: { $0 == chosen?.next }) && pending.isEmpty
            fresh.close()
            let final = make(AudioProofRecorder(data), AudioProofPlayer(), disk); await final.refresh()
            checks["settledCopyReleasesOriginalRetainedWriterWithoutStaleRecoveryRow"] = !final.retainedRecoveryFailed && final.pendingSaves.isEmpty && final.recoverable.isEmpty && final.available.count == 2
            final.close()
        }

        return checks
    }

}

extension AudioControllerProof {
    @MainActor private static func interruptedChecks(root: URL, data: Data, request: AudioCommentDraftRequest) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let folder = root.appendingPathComponent("interrupted-stage-ui", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let owner = try AudioCommentOwner(request.scope.workspace.account)
        let vault = AudioCommentVault(applicationSupport: folder, owner: owner)
        let disk = AudioCommentDraftStorage(vault: vault), clip = try AudioCommentClip(data: data)
        _ = try vault.drafts()
        func stage(_ bytes: Data) throws -> URL {
            let path = vault.directory.appendingPathComponent(".write-" + UUID().uuidString.lowercased())
            try bytes.write(to: path); return path
        }
        let scope = AudioProofContext(request.scope)
        func capture() -> AudioCommentCapture {
            let value = AudioCommentCapture(request: request, recorder: AudioProofRecorder(data), player: AudioProofPlayer(), storage: disk)
            value.currentScope = { scope.scope }; return value
        }
        let original = try AudioCommentSavedDraft(owner: owner, target: request.scope.target, caption: "Interrupted primary recording", clip: clip)
        let path = try stage(original.encoded())
        let foreign = try AudioCommentSavedDraft(owner: owner, target: .init(task: UUID(), generation: UUID(), project: nil), caption: "Other task", clip: clip)
        let foreignPath = try stage(foreign.encoded())
        let brokenBytes = Data("unfinished file payload".utf8), brokenPath = try stage(brokenBytes)
        let journal = try AudioCommentSaveIntent(next: .init(owner: owner, target: request.scope.target, caption: "Pending action remains separate", clip: clip), base: nil, reviews: [])
        let journalPath = try stage(journal.encoded())
        let value = capture(); await value.refresh()
        checks["interruptedDiscoveryShowsOnlyCurrentTaskAndDoesNotPromoteFiles"] = value.interrupted.count == 1 && value.available.isEmpty && value.recoverable.isEmpty && value.pendingSaves.isEmpty && FileManager.default.fileExists(atPath: path.path)
        checks["corruptStageWarningDoesNotHideReadableCandidate"] = try value.interruptionFailure != nil && value.interrupted.count == 1 && (Data(contentsOf: brokenPath)) == brokenBytes
        checks["journalStageIsNotReinterpretedAsARecordingOrAutoFinished"] = try value.interruptedActionsNeedAttention && (vault.saves()).isEmpty && (Data(contentsOf: journalPath)) == journal.encoded()
        let other = try vault.interruptedCatalog().writes.first { if case .draft(let draft) = $0.payload { return draft.id == foreign.id }; return false }
        if let other { checks["foreignTaskCannotBeRecoveredThroughCurrentController"] = !(await value.recoverInterrupted(other)) && FileManager.default.fileExists(atPath: foreignPath.path) }
        let item = value.interrupted[0]
        let recovered = await value.recoverInterrupted(item)
        checks["explicitInterruptedPrimaryRecoveryListsExactSavedDraft"] = recovered && value.available == [original] && value.interrupted.isEmpty && !FileManager.default.fileExists(atPath: path.path)
        checks["recoveryLeavesCurrentEditorEmptyUntilExplicitSelection"] = value.session.clip == nil && value.session.caption.isEmpty && value.saved == nil
        checks["recoveryPreservesUnreadableForeignAndJournalFiles"] = try (Data(contentsOf: brokenPath)) == brokenBytes && FileManager.default.fileExists(atPath: foreignPath.path) && (Data(contentsOf: journalPath)) == journal.encoded()
        value.close()
        let reopened = capture(); await reopened.refresh()
        checks["recoveredPrimarySurvivesASecondControllerAndCanBeReviewed"] = reopened.available == [original] && reopened.interruptionFailure != nil
        await reopened.restore(original)
        checks["explicitRecoveredPrimarySelectionDecodesSameAudioAndCaption"] = reopened.saved == original && reopened.session.clip?.data == original.clip.data && reopened.session.caption == original.caption
        reopened.close()
        let review = try AudioCommentSavedDraft(owner: owner, target: request.scope.target, caption: "Unfinished review remains unsaved", clip: clip)
        _ = try stage(review.encoded(recovery: true))
        let reviewCapture = capture(); await reviewCapture.refresh()
        if let candidate = reviewCapture.interrupted.first {
            let result = await reviewCapture.recoverInterrupted(candidate)
            checks["recoveredReviewRemainsAReviewRatherThanBecomingSaved"] = result && reviewCapture.recoverable == [review] && reviewCapture.available == [original]
        }
        reviewCapture.close()
        let stale = try original.replacing(caption: "Stage changes after discovery", clip: original.clip)
        let stalePath = try stage(stale.encoded())
        let staleCapture = capture(); await staleCapture.refresh()
        let replacement = try stale.replacing(caption: "A newer stage", clip: clip), replacementBytes = try replacement.encoded()
        try replacementBytes.write(to: stalePath)
        if let candidate = staleCapture.interrupted.first {
            let result = await staleCapture.recoverInterrupted(candidate)
            checks["changedStageIsRefusedAndItsNewBytesRemainIntact"] = try !result && (Data(contentsOf: stalePath)) == replacementBytes && (vault.drafts()) == [original]
        }
        staleCapture.close()
        let offScope = capture(); await offScope.refresh()
        if let candidate = offScope.interrupted.first {
            scope.scope = .init(workspace: .init(account: "foreign-stage-workspace", generation: UUID()), target: request.scope.target)
            offScope.contextChanged()
            let result = await offScope.recoverInterrupted(candidate)
            checks["workspaceDepartureClearsStageContentAndRefusesOldAction"] = try !result && offScope.interrupted.isEmpty && offScope.interruptionFailure == nil && offScope.session.clip == nil && (Data(contentsOf: stalePath)) == replacementBytes
        }
        offScope.close()
        return checks
    }
}

extension AudioControllerProof {
    @MainActor private static func interruptedCopyChecks(root: URL, data: Data, request: AudioCommentDraftRequest) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let owner = try AudioCommentOwner(request.scope.workspace.account), clip = try AudioCommentClip(data: data)
        for (index, checkpoint) in [nil, AudioCommentVault.Checkpoint.afterSaveJournal, .afterDraftCommit].enumerated() {
            let folder = root.appendingPathComponent("interrupted-copy-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let vault = AudioCommentVault(applicationSupport: folder, owner: owner)
            let original = try AudioCommentSavedDraft(owner: owner, target: request.scope.target, caption: "Newer saved recording", clip: clip)
            try vault.save(original)
            let source = try original.replacing(caption: "Interrupted cafe\u{301} 🪴\nEarlier recording", clip: clip)
            let path = vault.directory.appendingPathComponent(".write-" + UUID().uuidString.lowercased())
            try source.encoded().write(to: path)
            let scope = AudioProofContext(request.scope)
            func capture(_ fault: AudioCommentVault.Checkpoint? = nil) -> AudioCommentCapture {
                let disk = AudioCommentDraftStorage(vault: .init(applicationSupport: folder, owner: owner, fault: { if let fault, $0 == fault { throw AudioCommentStorageFailure.unreadable } }))
                let value = AudioCommentCapture(request: request, recorder: AudioProofRecorder(data), player: AudioProofPlayer(), storage: disk)
                value.currentScope = { scope.scope }; return value
            }
            let value = capture(checkpoint); await value.refresh()
            let write = value.interrupted[0]
            if checkpoint == nil {
                checks["conflictedStageStaysAvailableBeforeExplicitKeepBoth"] = try !(await value.recoverInterrupted(write)) && (vault.drafts()) == [original] && value.interrupted.count == 1
            }
            let result = await value.saveInterruptedCopy(write)
            if checkpoint == nil {
                checks["explicitKeepBothSavesAnIndependentExactRecording"] = result && value.saved?.id != original.id && value.saved?.sameContent(as: source) == true && value.saved?.origin == nil
                checks["keepBothPreservesOriginalAndClearsOnlyExactStage"] = try (vault.drafts()).contains(original) && (vault.drafts()).count == 2 && !FileManager.default.fileExists(atPath: path.path) && value.interrupted.isEmpty && (vault.saves()).isEmpty
                value.close()
            } else {
                let journal = try vault.saves(), ids = journal.map { $0.next.id }
                checks["interruptedCopyIsFrozenUnderOneJournal-\(index)"] = !result && value.saveDurable && value.saveUnconfirmed && journal.count == 1 && journal[0].stage != nil && journal[0].next.sameContent(as: source)
                value.close()
                let returned = capture(); await returned.refresh()
                checks["coldCopyHidesProtectedStageAndDoesNotAutoFinish-\(index)"] = try returned.pendingSaves.count == 1 && returned.interrupted.isEmpty && (vault.saves()).count == 1 && FileManager.default.fileExists(atPath: path.path)
                if let pending = returned.pendingSaves.first { await returned.resumeSave(pending) }
                checks["coldExplicitCopyFinishUsesSameIDWithoutReplacingOriginal-\(index)"] = try returned.saved?.id == ids.first && (vault.drafts()).count == 2 && (vault.drafts()).contains(original) && (vault.saves()).isEmpty && !FileManager.default.fileExists(atPath: path.path)
                returned.close()
            }
        }
        let folder = root.appendingPathComponent("interrupted-copy-stale", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let vault = AudioCommentVault(applicationSupport: folder, owner: owner); _ = try vault.drafts()
        let source = try AudioCommentSavedDraft(owner: owner, target: request.scope.target, caption: "Original discovered stage", clip: clip)
        let path = vault.directory.appendingPathComponent(".write-" + UUID().uuidString.lowercased()); try source.encoded().write(to: path)
        let scope = AudioProofContext(request.scope), value = AudioCommentCapture(request: request, recorder: AudioProofRecorder(data), player: AudioProofPlayer(), storage: .init(vault: vault))
        value.currentScope = { scope.scope }; await value.refresh(); let write = value.interrupted[0]
        let changed = try source.replacing(caption: "New staged version", clip: clip).encoded(); try changed.write(to: path)
        let result = await value.saveInterruptedCopy(write)
        checks["changedStageCannotGrantCleanupOrOverwriteThroughKeepBoth"] = try !result && value.saveConflict && value.session.clip?.data == data && (vault.saves()).isEmpty && (vault.drafts()).isEmpty && (Data(contentsOf: path)) == changed
        let copied = await value.saveSeparateDraft()
        checks["explicitCopyAfterStageChangeKeepsNewStageAndReviewedVersion"] = try copied && value.saved?.caption == source.caption && (Data(contentsOf: path)) == changed && (vault.drafts()).count == 1
        value.close()
        let offScope = AudioCommentCapture(request: request, recorder: AudioProofRecorder(data), player: AudioProofPlayer(), storage: .init(vault: vault))
        offScope.currentScope = { scope.scope }; await offScope.refresh()
        if let item = offScope.interrupted.first {
            scope.scope = .init(workspace: .init(account: "other-copy-workspace", generation: UUID()), target: request.scope.target)
            offScope.contextChanged(); let refused = await offScope.saveInterruptedCopy(item)
            checks["oldWorkspaceCannotStartAnInterruptedCopy"] = try !refused && offScope.session.clip == nil && offScope.interrupted.isEmpty && (Data(contentsOf: path)) == changed
        }
        offScope.close()
        let claimFolder = root.appendingPathComponent("interrupted-copy-staged-claim", isDirectory: true)
        try FileManager.default.createDirectory(at: claimFolder, withIntermediateDirectories: false)
        let claimedVault = AudioCommentVault(applicationSupport: claimFolder, owner: owner); _ = try claimedVault.drafts()
        let claimedSource = try AudioCommentSavedDraft(owner: owner, target: request.scope.target, caption: "One interrupted source", clip: clip)
        let claimedPath = claimedVault.directory.appendingPathComponent(".write-" + UUID().uuidString.lowercased()), claimedBytes = try claimedSource.encoded()
        try claimedBytes.write(to: claimedPath)
        let claimScope = AudioProofContext(request.scope)
        func claimCapture() -> AudioCommentCapture {
            let value = AudioCommentCapture(request: request, recorder: AudioProofRecorder(data), player: AudioProofPlayer(), storage: .init(vault: claimedVault))
            value.currentScope = { claimScope.scope }; return value
        }
        let staleCopy = claimCapture(); await staleCopy.refresh(); let claimedWrite = staleCopy.interrupted[0]
        let originalCopy = try AudioCommentSaveIntent(next: .init(owner: owner, target: request.scope.target, caption: claimedSource.caption, clip: clip), base: nil, reviews: [], stage: .init(claimedWrite))
        let stagedJournal = claimedVault.directory.appendingPathComponent(".write-" + UUID().uuidString.lowercased()), stagedJournalBytes = try originalCopy.encoded()
        try stagedJournalBytes.write(to: stagedJournal)
        let refused = await staleCopy.saveInterruptedCopy(claimedWrite)
        checks["preRenameCopyAuthorizationRefusesASecondCopyWithoutTrappingTheEditor"] = !refused && staleCopy.editable && !staleCopy.needsSave && staleCopy.interrupted.isEmpty && staleCopy.interruptedActionsNeedAttention
        checks["refusedSecondCopyDoesNotPromoteOrRemoveEitherSource"] = try (claimedVault.drafts()).isEmpty && (claimedVault.saves()).isEmpty && (Data(contentsOf: claimedPath)) == claimedBytes && (Data(contentsOf: stagedJournal)) == stagedJournalBytes
        staleCopy.close()
        let discovering = claimCapture(); await discovering.refresh()
        checks["freshDiscoveryProtectsAStageClaimedByAnUnpromotedJournal"] = discovering.interrupted.isEmpty && discovering.pendingSaves.isEmpty && discovering.interruptedActionsNeedAttention && discovering.session.clip == nil
        _ = try claimedVault.commitSave(originalCopy)
        await discovering.refresh()
        checks["onlyTheOriginalExplicitAuthorizationCanFinishThePreRenameCopy"] = try discovering.available == [originalCopy.next] && discovering.interruptedActionsNeedAttention && (Data(contentsOf: stagedJournal)) == stagedJournalBytes && !(FileManager.default.fileExists(atPath: claimedPath.path))
        discovering.close()
        let quotaFolder = root.appendingPathComponent("interrupted-copy-full", isDirectory: true)
        try FileManager.default.createDirectory(at: quotaFolder, withIntermediateDirectories: false)
        let full = AudioCommentVault(applicationSupport: quotaFolder, owner: owner)
        var drafts: [AudioCommentSavedDraft] = []
        for number in 0..<20 {
            let draft = try AudioCommentSavedDraft(owner: owner, target: request.scope.target, caption: "Kept recording \(number)", clip: clip)
            try full.save(draft); drafts.append(draft)
        }
        let fullSource = try drafts[0].replacing(caption: "Interrupted at quota", clip: clip)
        let fullPath = full.directory.appendingPathComponent(".write-" + UUID().uuidString.lowercased()), fullBytes = try fullSource.encoded()
        try fullBytes.write(to: fullPath)
        let quotaScope = AudioProofContext(request.scope)
        let quota = AudioCommentCapture(request: request, recorder: AudioProofRecorder(data), player: AudioProofPlayer(), storage: .init(vault: full))
        quota.currentScope = { quotaScope.scope }; await quota.refresh()
        let quotaResult = await quota.saveInterruptedCopy(quota.interrupted[0])
        checks["refusedStageCopyAtQuotaReturnsToAnEditableSafeList"] = !quotaResult && quota.editable && !quota.needsSave && quota.session.clip == nil && quota.interrupted.count == 1
        let departure = await quota.prepareForDeparture()
        checks["quotaCopyRefusalKeepsOriginalFilesWithoutBlockingDeparture"] = try departure && (Data(contentsOf: fullPath)) == fullBytes && (full.saves()).isEmpty && (full.drafts()) == drafts.sorted { $0.id.uuidString < $1.id.uuidString }
        quota.close()
        return checks
    }
}

extension AudioControllerProof {
    @MainActor private static func appOriginChecks(root: URL, data: Data, request: AudioCommentDraftRequest) async throws -> [String: Bool] {
        let first = AudioCommentLiveScope(workspace: request.scope.workspace, target: request.scope.target, origin: "https://first.example.invalid")
        let second = AudioCommentLiveScope(workspace: request.scope.workspace, target: request.scope.target, origin: "https://second.example.invalid")
        let unicodeA = AudioCommentLiveScope(workspace: request.scope.workspace, target: request.scope.target, origin: "https://café.example.invalid")
        let unicodeB = AudioCommentLiveScope(workspace: request.scope.workspace, target: request.scope.target, origin: "https://cafe\u{301}.example.invalid")
        var checks = ["sameAudioOriginKeepsTheExactWorkspaceTarget": first.matches(first), "anotherServerCannotReuseTheSameAccountAndTaskAudioScope": !first.matches(second) && !first.matches(request.scope), "audioOriginBindingUsesExactUTF8": !unicodeA.matches(unicodeB)]
        let folder = root.appendingPathComponent("app-origin-context", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let owner = try AudioCommentOwner(first.workspace.account), vault = AudioCommentVault(applicationSupport: folder, owner: owner)
        let draft = try AudioCommentSavedDraft(owner: owner, target: first.target, caption: "Private original server recording", clip: .init(data: data)); try vault.save(draft)
        let scope = AudioProofContext(first)
        let value = AudioCommentCapture(request: .init(scope: first, title: "Original task"), recorder: AudioProofRecorder(data), player: AudioProofPlayer(), storage: .init(vault: vault))
        value.currentScope = { scope.scope }; await value.refresh(); await value.restore(draft); value.play()
        scope.scope = second; value.contextChanged()
        checks["serverChangeStopsAndErasesPreviewWithoutChangingOriginalDiskAudio"] = try !value.isCurrent && value.session.clip == nil && value.session.caption.isEmpty && !value.playing && (vault.drafts()) == [draft]
        value.close(); return checks
    }
}

@MainActor private final class AudioLibraryProofContext {
    var scope: AudioCommentLibraryScope?
    init(_ scope: AudioCommentLibraryScope?) { self.scope = scope }
}
@MainActor private final class AudioLibraryProofDecodeGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func decode(_ data: Data) async throws -> AudioCommentClip {
        entered = true; await withCheckedContinuation { continuation = $0 }
        return try await AudioCommentDecoding.validate(data)
    }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor private final class AudioLibraryProofPlayer: AudioCommentPlaying {
    var plays = 0, stops = 0
    var callbacks: [@MainActor () -> Void] = []
    var permits: [@MainActor () -> Bool] = []
    func play(_ clip: AudioCommentClip, isCurrent: @escaping @MainActor () -> Bool, ended: @escaping @MainActor () -> Void) throws {
        guard isCurrent() else { throw CancellationError() }; plays += 1; callbacks.append(ended); permits.append(isCurrent)
    }
    func stop() { stops += 1 }
}
extension AudioControllerProof {
    @MainActor private static func libraryChecks(root: URL, data: Data, request: AudioCommentDraftRequest) async throws -> [String: Bool] {
        let scope = AudioCommentLibraryScope(workspace: request.scope.workspace, origin: "https://library.example.invalid")
        let second = AudioCommentLibraryScope(workspace: scope.workspace, origin: "https://other.example.invalid")
        let newIncarnation = AudioCommentLibraryScope(workspace: .init(account: scope.workspace.account, generation: UUID()), origin: scope.origin)
        let folder = root.appendingPathComponent("saved-library-controller", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let owner = try AudioCommentOwner(scope.workspace.account), vault = AudioCommentVault(applicationSupport: folder, owner: owner)
        let original = try AudioCommentSavedDraft(owner: owner, target: request.scope.target, caption: "Original cafe\u{301} caption\nKeep the complete instructions 🪴", clip: .init(data: data))
        try vault.save(original)
        let storage = AudioCommentDraftStorage(vault: vault), context = AudioLibraryProofContext(scope), player = AudioLibraryProofPlayer()
        func make(gate: AudioLibraryProofDecodeGate? = nil) -> AudioCommentLibraryController {
            let value: AudioCommentLibraryController
            if let gate { value = .init(scope: scope, storage: storage, player: player, decode: { try await gate.decode($0) }) }
            else { value = .init(scope: scope, storage: storage, player: player) }
            value.currentScope = { context.scope }; return value
        }
        var checks: [String: Bool] = [:]
        checks["libraryScopeNeedsExactServerAndWorkspaceIncarnation"] = scope.matches(scope) && !scope.matches(second) && !scope.matches(newIncarnation)
        let rawA = AudioCommentLibraryScope(workspace: .init(account: "café", generation: scope.workspace.generation), origin: scope.origin)
        let rawB = AudioCommentLibraryScope(workspace: .init(account: "cafe\u{301}", generation: scope.workspace.generation), origin: scope.origin)
        checks["libraryScopeUsesRawAccountIdentity"] = !rawA.matches(rawB)
        let unbound = AudioCommentLibraryController(scope: scope, storage: storage, player: player)
        await unbound.refresh(); await unbound.select(original); await unbound.play()
        checks["unboundLibraryCannotReadOrPlay"] = unbound.library == nil && unbound.selected == nil && player.plays == 0
        unbound.close()
        let value = make(); await value.refresh()
        checks["libraryLoadsSavedRecordingsWithoutCurrentTaskAdmission"] = value.library?.drafts == [original]
        await value.select(original)
        checks["librarySelectionKeepsFullCaptionBytesAndOriginalTarget"] = value.selected == original && value.selected?.caption.utf8.elementsEqual(original.caption.utf8) == true
        var localPublicationBlocked = false
        do { _ = try await value.preparePublicationSource(original) } catch { localPublicationBlocked = true }
        checks["publicationCannotUseLocalWorkspaceRecording"] = localPublicationBlocked

        await value.play()
        checks["libraryPlaysOnlyAnAdmittedDecodedSavedSelection"] = player.plays == 1 && value.playing && player.permits.last?() == true
        value.stopPlayback(); player.callbacks.last?()
        checks["libraryStopRevokesDelayedPlayerCallbacks"] = !value.playing && player.permits.last?() == false && value.selected == original
        await value.play(); context.scope = second; value.contextChanged()
        checks["libraryServerSwitchClearsPreviewAndStopsPlayback"] = value.library == nil && value.selected == nil && !value.playing && !value.isCurrent && player.permits.last?() == false
        checks["libraryContextDeparturePreservesOriginalDiskRecording"] = try vault.drafts() == [original] && vault.saves().isEmpty
        context.scope = scope
        let changed = try original.replacing(caption: "Other editor changed the caption", clip: original.clip)
        try vault.save(changed, replacing: original.revision)
        let stale = make(); await stale.refresh(); await stale.select(original)
        checks["libraryStaleSelectionRefusesReplacementCaptionAndBytes"] = stale.selected == nil && stale.notice != nil
        var stalePublicationBlocked = false
        do { _ = try await stale.preparePublicationSource(original) } catch { stalePublicationBlocked = true }
        checks["publicationCannotUseStaleSelectedSource"] = stalePublicationBlocked

        await stale.select(changed)
        checks["librarySelectionBeforePendingSaveIsValid"] = stale.selected == changed
        let next = try changed.replacing(caption: "Pending save", clip: changed.clip)
        let intent = try AudioCommentSaveIntent(next: next, base: changed.revision, reviews: [])
        try vault.prepareSave(intent, fence: vault.departureFence())
        let playsBefore = player.plays; await stale.play()
        checks["libraryRechecksPendingSaveAtPlaybackHandoff"] = player.plays == playsBefore && stale.selected == nil && stale.notice != nil
        _ = try vault.commitSave(intent); stale.close()
        let switchGate = AudioLibraryProofDecodeGate(), switching = make(gate: switchGate)
        await switching.refresh()
        let selection = Task { await switching.select(next) }
        guard await wait({ switchGate.entered }) else { throw AudioCommentStorageFailure.unreadable }
        context.scope = newIncarnation; switching.contextChanged(); switchGate.release(); await selection.value
        checks["libraryAccountAwayAndBackCannotReviveSuspendedDecode"] = switching.selected == nil && switching.library == nil && !switching.working
        context.scope = scope
        let editGate = AudioLibraryProofDecodeGate(), editing = make(gate: editGate)
        await editing.refresh(); let editSelection = Task { await editing.select(next) }
        guard await wait({ editGate.entered }) else { throw AudioCommentStorageFailure.unreadable }
        let newer = try next.replacing(caption: "Changed during full codec decode", clip: next.clip)
        try vault.save(newer, replacing: next.revision); editGate.release(); await editSelection.value
        checks["libraryRevalidatesExactSourceAfterCodecDecode"] = editing.selected == nil && editing.notice != nil
        editing.close()
        let cancelGate = AudioLibraryProofDecodeGate(), cancelling = make(gate: cancelGate)
        await cancelling.refresh(); let cancelled = Task { await cancelling.select(newer) }
        guard await wait({ cancelGate.entered }) else { throw AudioCommentStorageFailure.unreadable }
        cancelled.cancel(); cancelGate.release(); await cancelled.value
        checks["cancelledLibraryDecodeCannotInstallPreview"] = cancelling.selected == nil && !cancelling.working
        cancelling.close()
        let backgroundGate = AudioLibraryProofDecodeGate(), background = make(gate: backgroundGate)
        await background.refresh(); let backgroundSelection = Task { await background.select(newer) }
        guard await wait({ backgroundGate.entered }) else { throw AudioCommentStorageFailure.unreadable }
        background.setActive(false); backgroundGate.release(); await backgroundSelection.value
        checks["backgroundingRevokesInFlightLibrarySelection"] = background.selected == nil && !background.working
        background.close()
        let active = make(); await active.refresh(); await active.select(newer); await active.play()
        AudioCommentCapture.stopPlaybackForInactivity()
        checks["appInactivityStopsLibraryPlaybackThroughSharedLifecycleHook"] = !active.playing && active.selected == nil && player.permits.last?() == false
        active.setActive(true); await active.refresh(); await active.select(newer); await active.play()
        checks["foregroundReturnNeedsFreshSelectionAndRevalidatedPlayback"] = active.playing && active.selected == newer
        _ = await AudioCommentCapture.preserveForDeparture()
        checks["backgroundPreservationSuspendsLibraryWithoutPermanentlyClosingItsScope"] = active.isCurrent && !active.playing && active.selected == nil
        active.setActive(true); await active.refresh(); await active.select(newer); await active.play()
        checks["libraryCanReopenAfterTheActualBackgroundPreservationHook"] = active.playing && active.selected == newer
        context.scope = nil; active.contextChanged()
        checks["libraryDepartureClosesPreviewWithoutDeletingSavedBytes"] = try !active.isCurrent && active.library == nil && active.selected == nil && !active.playing && vault.drafts() == [newer]
        let cloudOwner = try AudioCommentOwner(UUID().uuidString.lowercased())
        let cloudScope = AudioCommentLibraryScope(workspace: .init(account: cloudOwner.account, generation: UUID()), origin: "https://publication.example.invalid")
        let cloudFolder = root.appendingPathComponent("publication-library-source", isDirectory: true); try FileManager.default.createDirectory(at: cloudFolder, withIntermediateDirectories: false)
        let cloudVault = AudioCommentVault(applicationSupport: cloudFolder, owner: cloudOwner)
        let cloudSource = try AudioCommentSavedDraft(owner: cloudOwner, target: newer.target, caption: newer.caption, clip: newer.clip); try cloudVault.save(cloudSource)
        let gate = AudioCommentLibraryController(scope: cloudScope, storage: .init(vault: cloudVault), player: AudioLibraryProofPlayer()); gate.currentScope = { cloudScope }
        await gate.refresh(); await gate.select(cloudSource)
        checks["publicationRevalidatesExactSelectedSavedSource"] = try await gate.preparePublicationSource(cloudSource) == cloudSource
        let legacy = try AudioCommentPending(publication: .init(account: UUID(uuidString: cloudOwner.account)!, target: cloudSource.target, caption: cloudSource.caption, descriptor: cloudSource.clip.descriptor), clip: cloudSource.clip)
        try cloudVault.store(legacy)
        var legacyBlocked = false
        do { _ = try await gate.preparePublicationSource(cloudSource) } catch { legacyBlocked = true }
        let retained = try cloudVault.pending()
        checks["publicationRefusesUnboundLegacyPendingWork"] = legacyBlocked && retained.count == 1
        gate.setActive(false); checks["publicationImmediatelyLosesInactiveSelectionAuthority"] = !gate.publicationSourceIsCurrent(cloudSource)
        gate.close()
        return checks
    }
}

extension AudioControllerProof {
    @MainActor private static func portableImportChecks(root: URL, data: Data, request: AudioCommentDraftRequest) async throws -> [String: Bool] {
        let folder = root.appendingPathComponent("portable-recording-import", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let owner = try AudioCommentOwner(request.scope.workspace.account)
        let vault = AudioCommentVault(applicationSupport: folder, owner: owner)
        let original = try AudioCommentSavedDraft(owner: owner, target: request.scope.target, caption: "Original stays", clip: .init(data: data))
        try vault.save(original)
        let storage = AudioCommentDraftStorage(vault: vault)
        let context = AudioProofContext(request.scope)
        let player = AudioProofPlayer(), recorder = AudioProofRecorder(data)
        func make() -> AudioCommentCapture {
            let value = AudioCommentCapture(request: request, recorder: recorder, player: player, storage: storage)
            value.currentScope = { context.scope }; return value
        }
        let caption = "  cafe\u{301}\nمراجعة 🪴 literal https://example.invalid  "
        let portable = try AudioCommentPortableRecording(caption: caption, clip: .init(data: data))
        let file = folder.appendingPathComponent("external-recording.json"), bytes = try portable.encoded()
        try bytes.write(to: file)
        var checks: [String: Bool] = [:]
        let read = try await AudioCommentRecordingFileRead.load(file)
        checks["externalRecordingReadKeepsExactCaptionAudioAndDescriptor"] = read.caption.utf8.elementsEqual(caption.utf8) && read.clip.data == data && read.clip.descriptor == portable.clip.descriptor
        checks["externalRecordingReviewDoesNotWriteThePrivateVault"] = try vault.drafts() == [original] && vault.drafts(recovery: true).isEmpty && vault.saves().isEmpty
        let stopped = AudioCommentRecordingFileRead(); stopped.cancel()
        do { _ = try stopped.read(file); checks["cancelledRecordingReadRefusesBeforeProviderAccess"] = false }
        catch { checks["cancelledRecordingReadRefusesBeforeProviderAccess"] = true }
        do { _ = try AudioCommentRecordingFileRead().read(URL(string: "https://example.invalid/recording.json")!); checks["recordingImportRefusesNetworkURLs"] = false }
        catch { checks["recordingImportRefusesNetworkURLs"] = true }
        do { _ = try AudioCommentRecordingFileRead().read(folder); checks["recordingImportRefusesDirectories"] = false }
        catch { checks["recordingImportRefusesDirectories"] = true }
        let large = folder.appendingPathComponent("oversized.json")
        try Data().write(to: large)
        let handle = try FileHandle(forWritingTo: large); try handle.truncate(atOffset: UInt64(AudioCommentPortableRecording.maximumFileBytes + 1)); try handle.close()
        do { _ = try AudioCommentRecordingFileRead().read(large); checks["recordingImportRefusesOversizedFilesBeforeDecode"] = false }
        catch { checks["recordingImportRefusesOversizedFilesBeforeDecode"] = true }
        let malformed = folder.appendingPathComponent("malformed.json"); try Data("{}".utf8).write(to: malformed)
        do { _ = try await AudioCommentRecordingFileRead.load(malformed); checks["recordingImportRefusesMalformedFiles"] = false }
        catch { checks["recordingImportRefusesMalformedFiles"] = true }
        let cancelled = Task { try await AudioCommentRecordingFileRead.load(file) }; cancelled.cancel()
        do { _ = try await cancelled.value; checks["cancelledImportLoadCannotReturnALateReview"] = false }
        catch { checks["cancelledImportLoadCannotReturnALateReview"] = true }
        let stale = make(); var calls = 0
        stale.currentScope = { calls += 1; return calls == 1 ? request.scope : nil }
        let staleResult = await stale.importRecording(read)
        checks["importRechecksCurrentTaskAfterNativeDecode"] = !staleResult && stale.session.phase == .closed && stale.session.clip == nil
        let cancelledCapture = make(), cancelledAction = Task { await cancelledCapture.importRecording(read) }; cancelledAction.cancel()
        let cancelledResult = await cancelledAction.value
        checks["cancelledImportConfirmationCannotCreateAReview"] = !cancelledResult && cancelledCapture.session.clip == nil
        cancelledCapture.close()
        let c = make(); await c.refresh()
        let accepted = await c.importRecording(read)
        checks["recordingImportCreatesBoundedNativeReviewWithoutHardware"] = accepted && c.needsSave && c.saved == nil && c.session.clip?.data == data && c.session.clip?.descriptor.milliseconds == 1000 && c.session.caption.utf8.elementsEqual(caption.utf8) && player.plays == 0 && recorder.callbacks.isEmpty
        checks["importReviewCannotBeReplacedByASecondFile"] = !(await c.importRecording(read)) && c.session.caption.utf8.elementsEqual(caption.utf8)
        let saved = await c.save(), imported = c.saved
        checks["recordingImportSavesIndependentIDsForTheCurrentTask"] = saved && imported?.id != original.id && imported?.revision != original.revision && imported?.target == request.scope.target && imported?.owner == owner && imported?.origin == nil
        checks["recordingImportKeepsThePriorSavedDraftExactly"] = try vault.drafts().contains(original) && vault.drafts().count == 2 && vault.saves().isEmpty
        checks["importNeverModifiesItsExternalSourceFile"] = try Data(contentsOf: file) == bytes
        let again = await c.save()
        checks["importSaveRetryDoesNotDuplicateTheDraft"] = try again && c.saved == imported && vault.drafts().count == 2
        checks["savedRecordingMustBeClosedBeforeAnotherImport"] = !(await c.importRecording(read)) && c.saved == imported
        c.close()
        let returned = make(); await returned.refresh()
        checks["importedDraftRemainsAvailableAfterReopening"] = returned.available.count == 2 && returned.available.contains(where: { $0.id == imported?.id && $0.caption.utf8.elementsEqual(caption.utf8) && $0.clip.data == data })
        returned.close()
        let foreign = make(); context.scope = .init(workspace: .init(account: "another-account", generation: request.scope.workspace.generation), target: request.scope.target)
        checks["recordingImportCannotBindToAnotherAccount"] = !(await foreign.importRecording(read))
        foreign.close()
        return checks
    }
    @MainActor private static func portableExportChecks(root: URL, data: Data, request: AudioCommentDraftRequest) async throws -> [String: Bool] {
        let scope = AudioCommentLibraryScope(workspace: request.scope.workspace, origin: "https://export.example.invalid")
        let folder = root.appendingPathComponent("portable-recording-export", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let owner = try AudioCommentOwner(scope.workspace.account), vault = AudioCommentVault(applicationSupport: folder, owner: owner)
        let source = try AudioCommentSavedDraft(owner: owner, target: request.scope.target, caption: "Keep cafe\u{301} 🪴\nLiteral https://example.invalid/review", clip: .init(data: data))
        try vault.save(source)
        let storage = AudioCommentDraftStorage(vault: vault), context = AudioLibraryProofContext(scope)
        func make() -> AudioCommentLibraryController {
            let value = AudioCommentLibraryController(scope: scope, storage: storage, player: AudioLibraryProofPlayer())
            value.currentScope = { context.scope }; return value
        }
        func refused(_ permit: AudioCommentRecordingExport) async -> Bool {
            do { _ = try await permit.release(); return false } catch { return true }
        }
        var checks: [String: Bool] = [:]
        let value = make(); await value.refresh()
        do { _ = try await value.prepareExport(); checks["unselectedLibraryCannotPrepareRecordingExport"] = false }
        catch { checks["unselectedLibraryCannotPrepareRecordingExport"] = true }
        await value.select(source)
        let first = try await value.prepareExport(), bytes = try await first.release()
        let portable = try AudioCommentPortableRecording(encoded: bytes)
        checks["recordingExportKeepsExactCaptionAudioAndOriginalDescriptor"] = portable.caption.utf8.elementsEqual(source.caption.utf8) && portable.clip.data == data && portable.clip.descriptor == source.clip.descriptor
        checks["recordingProviderRetryReturnsByteIdenticalPortableCopy"] = try await first.release() == bytes
        let object = try JSONDecoder().decode(Record.self, from: bytes)
        checks["portableExportCarriesNoSourceTaskAccountOrServerFields"] = Set(object.fields.keys) == ["format", "caption", "descriptor", "audio_base64"]
        value.setActive(false)
        checks["explicitExportSurvivesPickerFocusWithoutKeepingAnAudioPreview"] = try await first.release() == bytes && value.selected == nil && !value.playing
        value.setActive(true); await value.refresh(preservingExports: true)
        checks["foregroundRefreshDoesNotRevokeAnOutstandingExplicitSave"] = try await first.release() == bytes
        await value.select(source)
        checks["newLibrarySelectionRevokesOlderProviderPermission"] = await refused(first)
        let cancelled = try await value.prepareExport(); cancelled.invalidate()
        checks["cancelledRecordingSaveRejectsLateProviderRequests"] = await refused(cancelled) && !cancelled.isAllowed
        let again = try await value.prepareExport()
        checks["cancelDoesNotPreventAFreshExplicitRecordingExport"] = try await again.release() == bytes
        let latest = try await value.prepareExport()
        let oldRefused = await refused(again), latestBytes = try await latest.release()
        checks["newExportRevokesAnOlderOutstandingProviderItem"] = oldRefused && latestBytes == bytes
        value.clearSelection()
        checks["leavingSelectedRecordingRevokesPreparedOutput"] = await refused(latest)
        await value.select(source); let refreshed = try await value.prepareExport(); await value.refresh()
        checks["manualLibraryRefreshRevokesAnOldOutput"] = await refused(refreshed)
        await value.select(source); let editedPermit = try await value.prepareExport()
        let edited = try source.replacing(caption: "Edited after export preparation", clip: source.clip)
        try vault.save(edited, replacing: source.revision)
        checks["providerHandoffRejectsAnEditedSourceRevision"] = await refused(editedPermit)
        await value.refresh(); await value.select(edited)
        let pendingPermit = try await value.prepareExport(), next = try edited.replacing(caption: "Pending replacement", clip: edited.clip)
        let intent = try AudioCommentSaveIntent(next: next, base: edited.revision, reviews: [])
        try vault.prepareSave(intent, fence: vault.departureFence())
        checks["providerHandoffRefusesASourceCoveredByAnUnfinishedSave"] = await refused(pendingPermit)
        _ = try vault.commitSave(intent)
        await value.refresh(); await value.select(next)
        let switched = try await value.prepareExport()
        context.scope = .init(workspace: scope.workspace, origin: "https://another.example.invalid")
        checks["providerHandoffRejectsAnotherServerWithTheSameAccount"] = await refused(switched)
        value.contextChanged(); context.scope = scope
        checks["returningToAnOldScopeCannotReviveAClosedExport"] = await refused(switched) && !switched.isAllowed
        let closing = make(); await closing.refresh(); await closing.select(next)
        let closed = try await closing.prepareExport(); closing.close()
        checks["closingLibraryRevokesOutstandingRecordingBytes"] = await refused(closed)
        var allowed = true
        let boundary = AudioCommentRecordingExport(bytes: bytes, source: next, storage: storage, allowed: { let result = allowed; allowed = false; return result })
        checks["providerRechecksLivePermissionAfterItsStorageAwait"] = await refused(boundary)
        let cancelledValue = make(); await cancelledValue.refresh(); await cancelledValue.select(next)
        let task = Task { try await cancelledValue.prepareExport() }; task.cancel()
        do { _ = try await task.value; checks["cancelledExportPreparationCannotReturnAProviderPermit"] = false }
        catch { checks["cancelledExportPreparationCannotReturnAProviderPermit"] = true }
        cancelledValue.close()
        checks["allRecordingExportActionsPreserveTheCurrentPrivateSource"] = try vault.drafts() == [next] && vault.saves().isEmpty && vault.drafts(recovery: true).isEmpty
        return checks
    }
    @MainActor private static func pendingPublicationChecks(root: URL, data: Data) async throws -> [String: Bool] {
        let folder = root.appendingPathComponent("pending-publication-review", isDirectory: true); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let owner = try AudioCommentOwner(UUID().uuidString.lowercased()), account = UUID(uuidString: owner.account)!, origin = "https://pending.example.invalid"
        let scope = AudioCommentLibraryScope(workspace: .init(account: owner.account, generation: UUID()), origin: origin)
        let target = try AudioCommentTarget(task: UUID(), generation: UUID(), project: nil)
        let source = try AudioCommentSavedDraft(owner: owner, target: target, caption: "Original cafe\u{301} recording\nKeep this version 🪴", clip: .init(data: data))
        let publicationDisk = try AudioCommentPublicationDisk(root: folder, account: account, origin: origin), journal = try publicationDisk.prepare(source)
        let draftVault = AudioCommentVault(applicationSupport: folder, owner: owner), drafts = AudioCommentDraftStorage(vault: draftVault), storage = AudioCommentPublicationStorage(disk: publicationDisk), player = AudioLibraryProofPlayer()
        let context = AudioLibraryProofContext(scope)
        func make() -> AudioCommentPendingLibrary {
            let value = AudioCommentPendingLibrary(scope: scope, storage: storage, drafts: drafts, player: player)
            value.currentScope = { context.scope }; return value
        }
        var checks: [String: Bool] = [:]
        let unbound = AudioCommentPendingLibrary(scope: scope, storage: storage, drafts: drafts, player: player)
        await unbound.refresh(); await unbound.select(journal)
        checks["pendingReviewNeedsExplicitAccountServerBinding"] = unbound.entries.isEmpty && unbound.selected == nil
        unbound.close()
        let review = make(); await review.refresh()
        let initialDrafts = try draftVault.drafts()
        checks["pendingListFindsOrphanedOriginalWithoutSavedDraft"] = review.entries.count == 1 && initialDrafts.isEmpty
        await review.select(journal)
        checks["pendingReviewPreservesOriginalCaptionAndBytes"] = review.selected?.publication.caption.utf8.elementsEqual(source.caption.utf8) == true && review.selected?.clip?.data == data
        await review.play(); checks["pendingReviewUsesDecodedOriginalForPlayback"] = player.plays == 1 && review.playing
        review.stopPlayback(); checks["pendingStopRevokesDelayedPlayback"] = !review.playing && player.permits.last?() == false
        try await review.keepPrivateCopy(); try await review.keepPrivateCopy()
        let copies = try draftVault.drafts()
        checks["pendingPrivateCopyIsDurableAndIdempotent"] = copies.count == 1 && copies[0].id == journal.publication.asset && copies[0].clip.data == data && copies[0].caption.utf8.elementsEqual(source.caption.utf8)
        var denied = false; do { try await review.removeConfirmedCopy() } catch { denied = true }
        let stillPending = try publicationDisk.journals()
        checks["pendingCannotDiscardUnconfirmedAudio"] = denied && stillPending.first?.clip != nil
        let edited = try AudioCommentSavedDraft(owner: owner, target: target, caption: "Edited saved draft", clip: source.clip, id: source.id)
        try draftVault.save(edited)
        try await review.keepPrivateCopy()
        checks["pendingKeepDoesNotOverwriteEditedSource"] = try draftVault.drafts().contains(edited)
        var fields = journal.publication.record.fields; fields.removeValue(forKey: "version"); fields["protocol"] = .number(1); fields["author_id"] = .string(owner.account); fields["state"] = .string("published"); fields["reserved_at"] = .string("2026-10-28T15:00:00Z"); fields["expires_at"] = .string("2026-10-29T15:00:00Z"); fields["published_at"] = .string("2026-10-28T15:00:01Z")
        _ = try publicationDisk.confirm(journal, receipt: .init(record: Record(fields), publication: journal.publication), retainingAudio: true)
        try await review.updateAfterConfirmation()
        checks["pendingConfirmationStillKeepsOriginalAudio"] = review.selected?.receipt != nil && review.selected?.clip?.data == data
        await review.play(); checks["pendingConfirmedCopyStillPlaysWithoutServerRead"] = player.plays == 2
        context.scope = .init(workspace: .init(account: owner.account, generation: UUID()), origin: origin)
        checks["pendingContextDepartureImmediatelyRevokesActions"] = !review.isCurrent && player.permits.last?() == false
        var copyBlocked = false; do { try await review.keepPrivateCopy() } catch { copyBlocked = true }
        checks["pendingDepartedContextCannotKeepCopy"] = copyBlocked
        review.close(); context.scope = scope
        let returned = make(); await returned.refresh(); await returned.select(journal)
        checks["pendingReturnReopensRetainedConfirmation"] = returned.selected?.receipt != nil && returned.selected?.clip?.data == data
        AudioCommentLibraryController.stopForInactivity()
        checks["pendingBackgroundHookClearsVisiblePrivateData"] = returned.entries.isEmpty && returned.selected == nil && !returned.isCurrent
        returned.setActive(true); await returned.refresh(); await returned.select(journal)
        try await returned.removeConfirmedCopy()
        let removed = try publicationDisk.journals(), keptDrafts = try draftVault.drafts()
        checks["pendingExplicitRemovalKeepsReceiptAndSavedCopies"] = removed.first?.receipt != nil && removed.first?.clip == nil && keptDrafts.count == 2
        checks["pendingRemovedCopyLeavesVisibleQueue"] = returned.selected == nil && returned.entries.isEmpty
        let secondSource = try AudioCommentSavedDraft(owner: owner, target: target, caption: "Another original", clip: source.clip)
        let second = try publicationDisk.prepare(secondSource)
        var nextFields = fields; for (key, value) in second.publication.record.fields where key != "version" { nextFields[key] = value }
        let secondConfirmed = try publicationDisk.confirm(second, receipt: .init(record: Record(nextFields), publication: second.publication), retainingAudio: true)
        await returned.refresh(); await returned.select(secondConfirmed)
        _ = try publicationDisk.releaseConfirmedAudio(secondConfirmed)
        try await returned.updateAfterConfirmation()
        checks["pendingOtherWindowRemovalClearsStalePlayableSelection"] = returned.selected == nil && returned.entries.isEmpty && !returned.playing
        checks["pendingOtherWindowRemovalKeepsSavedDrafts"] = try draftVault.drafts().count == 2
        returned.close(); return checks
    }

    @MainActor private static func remoteConversationChecks(data: Data) async throws -> [String: Bool] {
        let account = UUID(), clip = try AudioCommentClip(data: data), target = try AudioCommentTarget(task: UUID(), generation: UUID(), project: nil)
        let scope = AudioCommentLiveScope(workspace: .init(account: account.uuidString.lowercased(), generation: UUID()), target: target, origin: "https://remote.example.invalid")
        let context = AudioProofContext(scope), player = AudioLibraryProofPlayer(), transport = AudioRemoteProofTransport(clip)
        let publication = try AudioCommentPublication(account: account, target: target, caption: "Literal cafe\u{301}\nRemote 🪴", descriptor: clip.descriptor)
        var fields = publication.record.fields; fields.removeValue(forKey: "version")
        fields["protocol"] = .number(1); fields["author_id"] = .string(account.uuidString.lowercased()); fields["state"] = .string("published"); fields["reserved_at"] = .string("2026-10-28T15:00:00Z"); fields["expires_at"] = .string("2026-10-29T15:00:00Z"); fields["published_at"] = .string("2026-10-28T15:00:01Z")
        let remote = try AudioCommentRemote(record: Record(fields), account: account, target: target); transport.rows = [remote]
        var sessionCurrent = true
        func make() throws -> AudioCommentConversationController {
            let value = try AudioCommentConversationController(scope: scope, incarnation: UUID(), transport: transport, player: player)
            value.currentScope = { context.scope }; value.sessionIsCurrent = { sessionCurrent }; return value
        }
        var checks: [String: Bool] = [:]
        let unbound = try AudioCommentConversationController(scope: scope, incarnation: UUID(), transport: transport, player: player)
        await unbound.refresh(); checks["remoteConversationRequiresExplicitLiveBinding"] = transport.lists == 0 && unbound.entries.isEmpty; unbound.close()
        let value = try make(); await value.refresh()
        checks["remoteConversationListsExactTargetAndLiteralCaption"] = value.entries == [remote] && value.entries.first?.publication.caption.utf8.elementsEqual(publication.caption.utf8) == true
        await value.play(remote); checks["remoteConversationPlaysVerifiedFreshDownload"] = transport.downloads == 1 && player.plays == 1 && value.playing == remote.id
        value.stop(); checks["remoteStopRevokesDelayedPlaybackAuthority"] = player.permits.last?() == false && value.playing == nil
        await value.play(remote); checks["remoteReplayAlwaysReauthorizesDownload"] = transport.downloads == 2
        sessionCurrent = false; let before = transport.downloads; await value.play(remote); await value.remove(remote)
        checks["remoteSessionDepartureRejectsPlaybackAndRemoval"] = transport.downloads == before && transport.removals == 0 && player.permits.last?() == false
        sessionCurrent = true
        AudioCommentLibraryController.stopForInactivity()
        checks["remoteBackgroundHookClearsPrivateRowsAndStopsPlayback"] = value.entries.isEmpty && value.playing == nil && !value.isCurrent
        value.setActive(true); await value.refresh(); transport.failRemoval = true; await value.remove(remote)
        checks["remoteUncertainRemovalRetainsRowAndOffersRefresh"] = value.entries == [remote] && value.notice?.contains("couldn’t be confirmed") == true
        transport.failRemoval = false; await value.remove(remote)
        checks["remoteExactAcknowledgementRemovesVisibleComment"] = value.entries.isEmpty && value.notice?.contains("removed") == true
        let removedCalls = transport.removals; await value.remove(remote)
        checks["remoteRemovedOrForeignSelectionCannotSendAgain"] = transport.removals == removedCalls
        transport.rows = [remote]; transport.holdList = true
        let pending = Task { await value.refresh() }
        for _ in 0..<500 { if transport.continuation != nil { break }; await Task.yield() }
        context.scope = .init(workspace: .init(account: account.uuidString.lowercased(), generation: UUID()), target: target, origin: scope.origin)
        transport.release(); await pending.value
        checks["remoteLateListCannotEnterAnotherWorkspaceIncarnation"] = value.entries.isEmpty
        value.close(); context.scope = scope; transport.holdList = false
        let returned = try make(); await returned.refresh(); transport.holdDownload = true
        let downloading = Task { await returned.play(remote) }
        for _ in 0..<500 { if transport.continuation != nil { break }; await Task.yield() }
        let previousPlays = player.plays; returned.close(); transport.release(); await downloading.value
        checks["remoteClosedReviewCannotStartLatePlayback"] = player.plays == previousPlays && returned.entries.isEmpty && returned.playing == nil
        return checks
    }

}
