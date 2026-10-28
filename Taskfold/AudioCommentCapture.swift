import Foundation
import Observation
#if AUDIO_COMMENT_CONTROLLER_TESTING
@testable import TaskfoldCore
#endif

struct AudioCommentLiveScope: Sendable {
    let workspace: WorkspaceBinding
    let target: AudioCommentTarget
    let origin: String?
    init(workspace: WorkspaceBinding, target: AudioCommentTarget, origin: String? = nil) { self.workspace = workspace; self.target = target; self.origin = origin }
    func matches(_ other: Self) -> Bool {
        let sameOrigin: Bool
        if let origin, let second = other.origin { sameOrigin = origin.utf8.elementsEqual(second.utf8) } else { sameOrigin = origin == nil && other.origin == nil }
        return sameOrigin && workspace.generation == other.workspace.generation && !workspace.account.isEmpty && workspace.account.utf8.elementsEqual(other.workspace.account.utf8) && target == other.target
    }
}
/// Account library scope deliberately has no synthetic task identity.
struct AudioCommentLibraryScope: Sendable {
    let workspace: WorkspaceBinding
    let origin: String?
    func matches(_ other: Self) -> Bool {
        let sameOrigin: Bool
        if let origin, let second = other.origin { sameOrigin = origin.utf8.elementsEqual(second.utf8) }
        else { sameOrigin = origin == nil && other.origin == nil }
        return sameOrigin && workspace.generation == other.workspace.generation && !workspace.account.isEmpty && workspace.account.utf8.elementsEqual(other.workspace.account.utf8)
    }
}
struct AudioCommentLibraryRequest: Identifiable, Sendable {
    let id = UUID()
    let scope: AudioCommentLibraryScope
}

struct AudioCommentDraftRequest: Identifiable, Sendable {
    let id = UUID()
    let scope: AudioCommentLiveScope
    let title: String
}

/// A coordinated external-file read never writes to the recording vault.
/// Cancellation reaches both the provider and the bounded streaming loop.
final class AudioCommentRecordingFileRead: @unchecked Sendable {
    private let coordinator = NSFileCoordinator()
    private let lock = NSLock()
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        coordinator.cancel()
    }
    private func checkCancellation() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
    }
    func read(_ url: URL) throws -> AudioCommentPortableRecording {
        try checkCancellation()
        guard url.isFileURL else { throw AudioCommentFailure.invalid }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<AudioCommentPortableRecording, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            result = Result {
                try self.checkCancellation()
                let values = try readableURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true,
                      (values.fileSize ?? 0) <= AudioCommentPortableRecording.maximumFileBytes else { throw AudioCommentFailure.invalid }
                let file = try FileHandle(forReadingFrom: readableURL)
                defer { try? file.close() }
                var bytes = Data()
                while true {
                    try self.checkCancellation()
                    let chunk = try file.read(upToCount: min(65_536, AudioCommentPortableRecording.maximumFileBytes + 1 - bytes.count)) ?? Data()
                    if chunk.isEmpty { break }
                    bytes.append(chunk)
                    guard bytes.count <= AudioCommentPortableRecording.maximumFileBytes else { throw AudioCommentFailure.invalid }
                }
                try self.checkCancellation()
                return try AudioCommentPortableRecording(encoded: bytes)
            }
        }
        try checkCancellation()
        if let coordinationError { throw coordinationError }
        guard let result else { throw AudioCommentFailure.invalid }
        return try result.get()
    }
    static func load(_ url: URL) async throws -> AudioCommentPortableRecording {
        let operation = AudioCommentRecordingFileRead()
        let worker = Task.detached(priority: .userInitiated) { try operation.read(url) }
        return try await withTaskCancellationHandler {
            let recording = try await worker.value
            try Task.checkCancellation()
            _ = try await AudioCommentDecoding.validate(recording.clip.data)
            try Task.checkCancellation()
            return recording
        } onCancel: { operation.cancel(); worker.cancel() }
    }
}

@MainActor @Observable final class AudioCommentCapture {
    private final class LiveCapture { weak var value: AudioCommentCapture?; init(_ value: AudioCommentCapture) { self.value = value } }
    @ObservationIgnored private let lifecycleID = UUID()
    @ObservationIgnored private static var live: [UUID: LiveCapture] = [:]
    static var hasUnpreservedWork: Bool {
        live.values.compactMap(\.value).contains { $0.busy || !$0.recovery.preservedForDeparture } || AudioCommentReviewRecovery.hasUnpreservedWork
    }
    /// Every operation keeps its original private store. This never discovers or
    /// completes a Save in a different account and never sends audio remotely.
    static func stopPlaybackForInactivity() { AudioCommentLibraryController.stopForInactivity(); for capture in live.values.compactMap(\.value) { capture.stopPlayback() } }
    static func preserveForDeparture() async -> Bool {
        AudioCommentLibraryController.stopForInactivity()
        var success = true
        let captures = live.values.compactMap(\.value)
        for capture in captures { if !(await capture.prepareForDeparture()) { success = false } }
        if !(await AudioCommentReviewRecovery.preserveAllForDeparture()) { success = false }
        return success && !hasUnpreservedWork
    }
    let request: AudioCommentDraftRequest
    private(set) var session: AudioCommentDraft
    private(set) var saved: AudioCommentSavedDraft?
    private(set) var available: [AudioCommentSavedDraft] = []
    private(set) var recoverable: [AudioCommentSavedDraft] = []
    private(set) var pendingSaves: [AudioCommentSaveIntent] = []
    private(set) var interrupted: [AudioCommentInterruptedWrite] = []
    private(set) var interruptionFailure: String?
    private(set) var interruptedActionsNeedAttention = false
    private(set) var saveDurable = false
    @ObservationIgnored private var saveRequiresExisting = false
    @ObservationIgnored private var saveExpired = false
    private(set) var saveConflict = false
    private(set) var reviewClaimed = false
    private(set) var retainedRecoveryFailed = false
    let recovery: AudioCommentReviewRecovery
    private(set) var loading = false
    private(set) var saving = false
    private(set) var playing = false
    private(set) var saveUnconfirmed = false
    private(set) var elapsed: TimeInterval = 0
    var notice: String?
    @ObservationIgnored var currentScope: () -> AudioCommentLiveScope? = { nil }
    @ObservationIgnored private let recorder: any AudioCommentRecording
    @ObservationIgnored private let player: any AudioCommentPlaying
    @ObservationIgnored private let storage: AudioCommentDraftStorage
    @ObservationIgnored private var starting: Task<Void, Never>?
    @ObservationIgnored private var decoding: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var candidate: AudioCommentSavedDraft?
    @ObservationIgnored private var candidateBase: UUID?
    @ObservationIgnored private var saveIntent: AudioCommentSaveIntent?
    @ObservationIgnored private var replacingIntent: AudioCommentSaveIntent?
    @ObservationIgnored private var restoredRecovery: AudioCommentSavedDraft?
    init(request: AudioCommentDraftRequest, recorder: any AudioCommentRecording, player: any AudioCommentPlaying, storage: AudioCommentDraftStorage) {
        self.request = request; self.recorder = recorder; self.player = player; self.storage = storage
        recovery = .init(account: request.scope.workspace.account, target: request.scope.target, storage: storage)
        session = .init(workspace: request.scope.workspace, target: request.scope.target)
        Self.live = Self.live.filter { $0.value.value != nil }
        Self.live[lifecycleID] = LiveCapture(self)
    }
    var isCurrent: Bool { storage.owner.account.utf8.elementsEqual(request.scope.workspace.account.utf8) && currentScope().map(request.scope.matches) == true && session.phase != .closed }
    var recordingBusy: Bool { [.authorizing, .recording, .finishing].contains(session.phase) }
    var busy: Bool { recordingBusy || loading || saving }
    var editable: Bool { isCurrent && !busy && !saveUnconfirmed && !saveConflict }
    private var reviewOrigin: AudioCommentReviewReference? {
        if let saved { return saved.origin }
        if let restoredRecovery { return restoredRecovery.origin ?? .init(restoredRecovery) }
        return nil
    }
    var needsSave: Bool {
        guard let clip = session.clip else { return false }
        return saveUnconfirmed || saved?.clip.data != clip.data || saved?.caption.utf8.elementsEqual(session.caption.utf8) != true
    }
    func start() {
        guard editable else { return }; stopPlayback()
        do {
            let token = try session.begin(workspace: request.scope.workspace, target: request.scope.target)
            notice = nil; elapsed = 0
            starting = Task { [weak self, recorder] in
                do { try await recorder.start(isCurrent: { [weak self] in self?.accepts(token) == true }) { [weak self] event in self?.receive(event, token: token) } }
                catch { self?.fail(error is CancellationError ? "Recording cancelled. Your earlier draft is still here." : error.localizedDescription, token: token) }
            }
        } catch { notice = error.localizedDescription }
    }
    private func accepts(_ token: UUID) -> Bool { isCurrent && session.accepts(token, workspace: request.scope.workspace, target: request.scope.target) }
    private func receive(_ event: AudioCommentRecordingEvent, token: UUID) {
        guard session.token == token else { return }
        guard isCurrent else { close(); return }
        guard accepts(token) else { return }
        switch event {
        case .started:
            guard session.phase == .authorizing else { return }
            session.started(token, workspace: request.scope.workspace, target: request.scope.target)
            ticker?.cancel(); ticker = Task { [weak self] in
                let started = ContinuousClock.now
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    guard let self, self.session.token == token, self.isCurrent else { self?.close(); return }
                    self.elapsed = max(self.elapsed, self.recorder.elapsed)
                    if started.duration(to: .now) >= .seconds(121) { self.stop(); return }
                }
            }
        case .finished(let data):
            guard session.phase == .recording || session.phase == .finishing else { return }
            session.finishing(); ticker?.cancel()
            decoding = Task { [weak self] in
                do {
                    let clip = try await AudioCommentDecoding.validate(data)
                    guard let self else { return }; guard self.isCurrent else { self.close(); return }
                    guard self.accepts(token), self.session.phase == .finishing else { return }
                    try self.recovery.submit(clip: clip, caption: self.session.caption, origin: self.reviewOrigin)
                    guard self.session.receive(clip, token: token, workspace: self.request.scope.workspace, target: self.request.scope.target) else { return }
                    self.recorder.cancel(); self.elapsed = Double(clip.descriptor.milliseconds) / 1000
                    self.notice = "Ready to review. Save the draft to keep it on this device."
                } catch { self?.fail("This recording couldn’t be read. Your earlier draft is still here.", token: token) }
            }
        case .failed(let message): fail(message, token: token)
        }
    }
    private func fail(_ message: String, token: UUID) {
        guard session.token == token else { return }; guard isCurrent else { close(); return }
        starting?.cancel(); ticker?.cancel(); decoding?.cancel(); recorder.cancel(); session.failed(token); elapsed = Double(session.clip?.descriptor.milliseconds ?? 0) / 1000; notice = message
    }
    func stop() {
        guard isCurrent else { close(); return }
        if session.phase == .authorizing, let token = session.token { fail("Recording cancelled. Your earlier draft is still here.", token: token) }
        else if session.phase == .recording { session.finishing(); ticker?.cancel(); recorder.finish() }
    }
    func cancelRecording() { if let token = session.token { fail("Recording cancelled. Your earlier draft is still here.", token: token) } }
    func editCaption(_ text: String) {
        guard editable else { return }
        do {
            if let clip = session.clip { try recovery.submit(clip: clip, caption: text, origin: reviewOrigin) }
            try session.editCaption(text); notice = nil
        } catch { notice = error.localizedDescription }
    }
    func refresh() async {
        guard isCurrent, !busy else { return }; loading = true; defer { loading = false }
        do {
            let owner = try AudioCommentOwner(request.scope.workspace.account)
            retainedRecoveryFailed = AudioCommentReviewRecovery.hasRetainedFailure(owner: owner, target: request.scope.target)
            let before = try await storage.catalog(target: request.scope.target)
            guard isCurrent else { close(); return }
            let protectedIDs = Set(before.saves.flatMap { $0.reviews.map(\.id) })
            let retried = await AudioCommentReviewRecovery.retryRetained(owner: owner, target: request.scope.target, excluding: protectedIDs)
            guard isCurrent else { close(); return }
            retainedRecoveryFailed = !retried
            let catalog = try await storage.catalog(target: request.scope.target)
            guard isCurrent else { close(); return }
            let retained = AudioCommentReviewRecovery.retainedSaves(owner: owner, target: request.scope.target)
            let retainedIDs = Set(retained.map { $0.intent.id })
            pendingSaves = (catalog.saves.filter { !retainedIDs.contains($0.id) } + retained.map(\.intent)).sorted { $0.id.uuidString < $1.id.uuidString }
            available = catalog.drafts.filter { draft in !pendingSaves.contains { $0.next.id == draft.id } }
            recoverable = catalog.reviews.filter { review in !pendingSaves.contains { $0.reviews.contains(.init(review)) } }
            do {
                let catalog = try await storage.interruptedCatalog()
                guard isCurrent else { close(); return }
                let stagedClaims = catalog.writes.compactMap { write -> AudioCommentStageReference? in
                    if case .save(let intent) = write.payload { return intent.stage }; return nil
                }
                interrupted = catalog.writes.filter { write in
                    let ref = try? AudioCommentStageReference(write)
                    return interruptedDraft(write) != nil && !stagedClaims.contains(where: { $0 == ref }) &&
                        !pendingSaves.contains { $0.stage != nil && $0.stage == ref }
                }
                interruptedActionsNeedAttention = catalog.writes.contains { write in
                    switch write.payload {
                    case .save(let intent): return intent.next.target == request.scope.target
                    case .pending(let pending): return pending.publication.target == request.scope.target
                    default: return false
                    }
                }
                interruptionFailure = catalog.unreadableCount == 0 ? nil : "Some recordings can’t be opened. Original files are kept."
            } catch {
                guard isCurrent else { close(); return }
                interrupted = []; interruptedActionsNeedAttention = false
                interruptionFailure = "Recovery is unavailable. Original files are kept. Try again."
            }
            if !retried { notice = hasUnwrittenSaves ? "Finish saving the recording below to keep it on this device." : "An interrupted review still needs a recovery retry. Keep Taskfold open before quitting." }
        } catch { interrupted = []; interruptionFailure = nil; interruptedActionsNeedAttention = false; if isCurrent { notice = error.localizedDescription } else { close() } }
    }
    func interruptedDraft(_ write: AudioCommentInterruptedWrite) -> AudioCommentSavedDraft? {
        let draft: AudioCommentSavedDraft
        switch write.payload { case .draft(let value), .review(let value): draft = value; default: return nil }
        guard draft.owner == storage.owner, draft.target == request.scope.target else { return nil }
        return draft
    }
    /// Recover only a displayed local draft/review. Journal/publication stages
    /// require their separate authorization workflow and are never auto-finished.
    @discardableResult func recoverInterrupted(_ write: AudioCommentInterruptedWrite) async -> Bool {
        guard editable, !needsSave, interrupted.contains(where: { $0.id == write.id }), let draft = interruptedDraft(write) else { return false }
        stopPlayback(); loading = true; defer { loading = false }
        do {
            _ = try await AudioCommentDecoding.validate(draft.clip.data)
            guard isCurrent else { close(); return false }
            try await storage.recover(write)
            guard isCurrent else { close(); return false }
            notice = "Interrupted recording recovered privately. Choose it below to review."
            loading = false; await refresh()
            return isCurrent
        } catch { if isCurrent { notice = error.localizedDescription } else { close() }; return false }
    }
    /// The explicit Keep both action authorizes one independent local Save.
    /// Its journal binds cleanup to the exact original staged bytes.
    @discardableResult func saveInterruptedCopy(_ write: AudioCommentInterruptedWrite) async -> Bool {
        guard editable, !needsSave, interrupted.contains(where: { $0.id == write.id }), let draft = interruptedDraft(write) else { return false }
        stopPlayback(); loading = true
        do {
            let clip = try await AudioCommentDecoding.validate(draft.clip.data)
            guard isCurrent else { close(); loading = false; return false }
            let next = try AudioCommentSavedDraft(owner: storage.owner, target: request.scope.target, caption: draft.caption, clip: draft.clip)
            let intent = try AudioCommentSaveIntent(next: next, base: nil, reviews: [], stage: .init(write))
            try session.restore(clip, caption: draft.caption, workspace: request.scope.workspace, target: request.scope.target)
            saved = nil; restoredRecovery = nil; candidate = next; candidateBase = nil; saveIntent = intent; replacingIntent = nil
            elapsed = Double(clip.descriptor.milliseconds) / 1000
            loading = false
            let success = await save()
            if success || !needsSave { await refresh() }
            return success
        } catch { loading = false; if isCurrent { notice = error.localizedDescription } else { close() }; return false }
    }
    /// Import starts a fresh review only. Existing drafts and source files are
    /// never replacement candidates; the normal Save journal owns confirmation.
    var canImportRecording: Bool { editable && session.phase == .ready && session.clip == nil && !needsSave }
    @discardableResult func importRecording(_ recording: AudioCommentPortableRecording) async -> Bool {
        guard canImportRecording, !Task.isCancelled else { return false }
        stopPlayback(); loading = true; defer { loading = false }
        do {
            let clip = try await AudioCommentDecoding.validate(recording.clip.data)
            try Task.checkCancellation()
            guard isCurrent else { close(); return false }
            // No await between the final scope check and binding the new review.
            try recovery.submit(clip: clip, caption: recording.caption)
            try session.restore(clip, caption: recording.caption, workspace: request.scope.workspace, target: request.scope.target)
            elapsed = Double(clip.descriptor.milliseconds) / 1000
            notice = "Recording imported for review. Save a separate draft when ready."
            return true
        } catch {
            if isCurrent { notice = error is CancellationError ? "Import cancelled." : "This recording could not be imported. Choose a valid Taskfold recording backup." }
            else { close() }
            return false
        }
    }
    func restore(_ draft: AudioCommentSavedDraft, recovering: Bool = false) async {
        guard editable, !needsSave, draft.target == request.scope.target, draft.owner.account.utf8.elementsEqual(request.scope.workspace.account.utf8) else { return }
        stopPlayback(); loading = true; defer { loading = false }
        do {
            let clip = try await AudioCommentDecoding.validate(draft.clip.data)
            guard isCurrent else { close(); return }
            try session.restore(clip, caption: draft.caption, workspace: request.scope.workspace, target: request.scope.target)
            saved = recovering ? nil : draft; restoredRecovery = recovering ? draft : nil; candidate = nil; candidateBase = nil
            elapsed = Double(clip.descriptor.milliseconds) / 1000; notice = recovering ? "Recovered review. Save a draft when you’re ready." : "Saved on this device."
            if recovering { try recovery.submit(clip: clip, caption: draft.caption, origin: reviewOrigin) }
        } catch { if isCurrent { notice = error.localizedDescription } else { close() } }
    }
    func resumeSave(_ requested: AudioCommentSaveIntent) async {
        guard editable, !needsSave, requested.next.owner.account.utf8.elementsEqual(request.scope.workspace.account.utf8), requested.next.target == request.scope.target else { return }
        loading = true
        do {
            if let current = AudioCommentReviewRecovery.retainedSaves(owner: storage.owner, target: request.scope.target).first(where: { $0.intent.id == requested.id }), current.intent != requested {
                throw AudioCommentStorageFailure.conflict
            }
            let stored = try await storage.saves().first { $0.id == requested.id }
            guard isCurrent else { close(); loading = false; return }
            let intent: AudioCommentSaveIntent
            var replacement: AudioCommentSaveIntent?, durable = true
            if let held = AudioCommentReviewRecovery.retainedSave(requested) {
                // The in-memory authorization can precede its first durable journal,
                // or be an explicit copy replacing the older on-disk authorization.
                let state = try? await storage.saveState(held.intent)
                guard isCurrent else { close(); loading = false; return }
                if stored == held.intent || state == .settled { intent = held.intent }
                else if (stored == held.replacing && stored != nil) || (stored == nil && state == .unprepared) {
                    intent = held.intent; replacement = held.replacing; durable = held.existingOnly
                } else if let stored, stored.phase == .discarding { intent = stored }
                else { throw AudioCommentStorageFailure.unreadable }
            } else if let stored {
                guard stored.next.owner == requested.next.owner, stored.next.target == requested.next.target,
                      stored.next.caption.utf8.elementsEqual(requested.next.caption.utf8), stored.next.clip.data == requested.next.clip.data else { throw AudioCommentStorageFailure.conflict }
                intent = stored
            } else {
                let state = try await storage.saveState(requested)
                guard isCurrent else { close(); loading = false; return }
                guard state == .settled else {
                    pendingSaves.removeAll { $0.id == requested.id }; notice = "This Save is no longer pending. Reopen the current draft."; loading = false; return
                }
                intent = requested
            }
            if intent.phase == .discarding { loading = false; await discardPendingSave(intent); return }
            let clip = try await AudioCommentDecoding.validate(intent.next.clip.data)
            guard isCurrent else { close(); loading = false; return }
            try session.restore(clip, caption: intent.next.caption, workspace: request.scope.workspace, target: request.scope.target)
            saveIntent = intent; candidate = intent.next; candidateBase = intent.base; saved = nil; replacingIntent = replacement
            saveDurable = durable; saveRequiresExisting = durable; saveExpired = false; saveUnconfirmed = true; elapsed = Double(clip.descriptor.milliseconds) / 1000
            loading = false; _ = await save()
        } catch { loading = false; if isCurrent { notice = error.localizedDescription } else { close() } }
    }
    @discardableResult func save() async -> Bool {
        guard isCurrent, !busy, !saveExpired, let clip = session.clip, session.phase == .review else { return false }
        if !needsSave, saved != nil, saveIntent == nil { return true }
        // An unreadable lookup is not evidence that a preceding Save never wrote.
        let retryingSave = saveIntent != nil || replacingIntent != nil || saveUnconfirmed || saveDurable
        saveRequiresExisting = saveRequiresExisting || saveDurable
        stopPlayback(); saving = true; defer { saving = false }
        var submittedIntent: AudioCommentSaveIntent?
        do {
            // Capture before the explicit attempt. A later automatic checkpoint
            // must not revive work discarded by another window/process.
            let departureFence = try? await storage.departureFence()
            guard isCurrent else { recovery.resumeAfterSave(); close(); return false }
            let next: AudioCommentSavedDraft
            if let candidate { next = candidate }
            else if let saved { next = try saved.replacing(caption: session.caption, clip: clip); candidate = next; candidateBase = saved.revision }
            else { next = try .init(owner: .init(request.scope.workspace.account), target: request.scope.target, caption: session.caption, clip: clip, origin: reviewOrigin); candidate = next; candidateBase = nil }
            if saveIntent == nil {
                var refs = await recovery.freezeForSave()
                guard isCurrent else { recovery.resumeAfterSave(); close(); return false }
                if let restoredRecovery { refs.append(.init(restoredRecovery)) }
                if reviewClaimed, let origin = reviewOrigin { refs.removeAll { $0 == origin } }
                refs = Array(Set(refs)).sorted { $0.id.uuidString + $0.revision.uuidString < $1.id.uuidString + $1.revision.uuidString }
                saveIntent = try .init(next: next, base: candidateBase, reviews: refs)
            }
            guard let intent = saveIntent else { throw AudioCommentStorageFailure.unreadable }
            try recovery.holdSave(intent, replacing: replacingIntent, fence: departureFence, existingOnly: saveRequiresExisting)
            saveRequiresExisting = recovery.requiresExistingSave
            submittedIntent = intent
            let committed = try await storage.commitSave(intent, replacing: replacingIntent, existingOnly: saveRequiresExisting)
            recovery.finishSave()
            AudioCommentReviewRecovery.settleRetained(intent)
            retainedRecoveryFailed = AudioCommentReviewRecovery.hasRetainedFailure(owner: intent.next.owner, target: intent.next.target)
            guard isCurrent else { close(); return false }
            saved = committed; candidate = nil; candidateBase = nil; saveUnconfirmed = false; saveConflict = false; reviewClaimed = false
            restoredRecovery = nil; saveIntent = nil; replacingIntent = nil; saveDurable = false; saveRequiresExisting = false; saveExpired = false
            let catalog = try? await storage.catalog(target: request.scope.target)
            guard isCurrent else { close(); return false }
            if let catalog { pendingSaves = catalog.saves; recoverable = catalog.reviews; available = catalog.drafts }
            if !available.contains(where: { $0.id == committed.id }) { available.insert(committed, at: 0) }
            notice = "Saved on this device."; return true
        } catch {
            let failure = error
            if let redirect = failure as? AudioCommentSaveRedirect {
                guard isCurrent else { close(); return false }
                // The durable operation belongs to the same owner, target and
                // exact content. Its IDs, not this editor's volatile proposal,
                // are authoritative through a second interruption/relaunch.
                if let original = submittedIntent { AudioCommentReviewRecovery.redirectRetained(original, to: redirect.intent) }
                saveIntent = redirect.intent; candidate = redirect.intent.next; candidateBase = redirect.intent.base
                replacingIntent = nil; saveDurable = true; saveUnconfirmed = true
                saving = false
                return await save()
            }
            let original = submittedIntent ?? saveIntent
            let state: AudioCommentLocalSaveState?
            if let original { state = try? await storage.saveState(original) } else { state = nil }
            if state == .settled, let original {
                recovery.finishSave()
                AudioCommentReviewRecovery.settleRetained(original)
                retainedRecoveryFailed = AudioCommentReviewRecovery.hasRetainedFailure(owner: original.next.owner, target: original.next.target)
                guard isCurrent else { close(); return false }
                saved = original.next; saveIntent = nil; replacingIntent = nil; candidate = nil; candidateBase = nil
                saveDurable = false; saveRequiresExisting = false; saveExpired = false; saveConflict = false; saveUnconfirmed = false; notice = "Saved on this device."
                pendingSaves.removeAll { $0.id == original.id }
                recoverable.removeAll { original.reviews.contains(.init($0)) }
                available.removeAll { $0.id == original.next.id }; available.insert(original.next, at: 0)
                return true
            }
            if state == .unprepared, !isCurrent, !saveRequiresExisting { recovery.resumeAfterSave() }
            if state == .prepared { recovery.finishSave() }
            guard isCurrent else { close(); return false }
            if state == .prepared { saveDurable = true; saveRequiresExisting = true }
            else if state == .unprepared { saveDurable = false }
            if state == .unprepared, saveRequiresExisting {
                saveExpired = true; saveConflict = true; saveUnconfirmed = false
                notice = "This pending Save was removed or changed in another window. Your recording is still here. Save a separate draft to keep this version."
            } else if (failure as? AudioCommentStorageFailure) == .reviewClaimed {
                reviewClaimed = true; saveConflict = true; saveUnconfirmed = false
                if state == .unprepared { saveIntent = nil; candidate = nil; candidateBase = nil; replacingIntent = nil; saveDurable = false; recovery.resumeAfterSave() }
                notice = AudioCommentStorageFailure.reviewClaimed.localizedDescription
            } else if (failure as? AudioCommentStorageFailure) == .discardPending {
                saveIntent = nil; candidate = nil; candidateBase = nil; replacingIntent = nil; saved = nil; restoredRecovery = nil
                session = .init(workspace: request.scope.workspace, target: request.scope.target); elapsed = 0
                saveDurable = false; saveRequiresExisting = false; saveExpired = false; saveUnconfirmed = false; saveConflict = false; reviewClaimed = false; recovery.finishSave()
                let catalog = try? await storage.catalog(target: request.scope.target)
                guard isCurrent else { close(); return false }
                if let catalog { pendingSaves = catalog.saves; recoverable = catalog.reviews; available = catalog.drafts }
                notice = AudioCommentStorageFailure.discardPending.localizedDescription
            } else if (failure as? AudioCommentStorageFailure) == .conflict {
                saveConflict = true; saveUnconfirmed = false
                notice = "This draft changed in another window. Your review is still here. Save a separate draft to keep both versions."
            } else if !saveDurable, state == .unprepared, let stage = original?.stage,
                      let failure = failure as? AudioCommentStorageFailure, failure == .full || failure == .busy || failure == .stageNeedsRecovery {
                // A refused new copy can close safely only while its exact source
                // is still durable. Otherwise retain the frozen authorization.
                let kept = try? await storage.interruptedCatalog().writes.contains { (try? AudioCommentStageReference($0)) == stage }
                if kept == true {
                    recovery.finishSave()
                    saveIntent = nil; candidate = nil; candidateBase = nil; replacingIntent = nil; saved = nil; restoredRecovery = nil
                    saveUnconfirmed = false; saveConflict = false; saveRequiresExisting = false; saveExpired = false; saveDurable = false
                    session = .init(workspace: request.scope.workspace, target: request.scope.target); elapsed = 0
                } else { saveUnconfirmed = true; saveConflict = false }
                guard isCurrent else { close(); return false }
                notice = kept == true ? failure.localizedDescription + " The interrupted file is kept. Try Keep both again later." : "The copy couldn’t be confirmed. Retry save before closing."
            } else if !saveDurable, original?.stage == nil, (state == .unprepared || !retryingSave), let failure = failure as? AudioCommentStorageFailure, failure == .full || failure == .busy {
                // A fresh pre-write refusal, or a positively unprepared lookup,
                // permits editing. Unknown retries keep their exact authorization.
                candidate = nil; candidateBase = nil; saveIntent = nil; replacingIntent = nil; recovery.resumeAfterSave(); saveUnconfirmed = false; saveConflict = false
                notice = failure.localizedDescription + " Your review is still here."
            } else {
                saveUnconfirmed = true; saveConflict = false; notice = saveDurable ? "Save is kept on this device. Retry now, or close and finish saving later." : "The save couldn’t be confirmed. Retry save before editing or closing; your recording is still here."
            }
            return false
        }
    }
    @discardableResult func saveSeparateDraft() async -> Bool {
        guard isCurrent, !busy, saveConflict, let clip = session.clip else { return false }
        do {
            if saveExpired, let expired = saveIntent {
                // This is a new, explicit authorization, never a replacement of
                // a journal that another window removed/changed. Claim no old
                // recovery revisions and leave all on-disk versions untouched.
                let next = try AudioCommentSavedDraft(owner: storage.owner, target: request.scope.target, caption: session.caption, clip: clip)
                let copy = try AudioCommentSaveIntent(next: next, base: nil, reviews: [])
                try recovery.holdSave(copy, replacing: nil)
                AudioCommentReviewRecovery.retireRetainedAuthorization(expired)
                saveIntent = copy; candidate = next; replacingIntent = nil; saved = nil; restoredRecovery = nil; reviewClaimed = false
            } else if let intent = saveIntent {
                replacingIntent = intent; let copy = try intent.separateCopy(); saveIntent = copy; candidate = copy.next
            } else { candidate = try .init(owner: .init(request.scope.workspace.account), target: request.scope.target, caption: session.caption, clip: clip) }
            // The original journal may be durable, but this newly chosen copy
            // is not durable until its exact replacement is confirmed.
            candidateBase = nil; saveConflict = false; saveDurable = false; saveRequiresExisting = false; saveExpired = false
            return await save()
        } catch { notice = error.localizedDescription; return false }
    }
    func isRetainedSave(_ intent: AudioCommentSaveIntent) -> Bool { AudioCommentReviewRecovery.retainedSave(intent) != nil }
    var hasUnwrittenSaves: Bool { pendingSaves.contains(where: isRetainedSave) }
    func discardPendingSave(_ intent: AudioCommentSaveIntent) async {
        guard !isRetainedSave(intent) else { notice = "Finish saving this recording before discarding it."; return }
        guard isCurrent, !busy, !needsSave, intent.next.owner == storage.owner, intent.next.target == request.scope.target else { return }
        saving = true; stopPlayback()
        var message = "Pending recording discarded."
        do { try await storage.discardSave(intent) }
        catch { message = error.localizedDescription }
        guard isCurrent else { saving = false; close(); return }
        let catalog = try? await storage.catalog(target: request.scope.target)
        guard isCurrent else { saving = false; close(); return }
        if let catalog { pendingSaves = catalog.saves; recoverable = catalog.reviews; available = catalog.drafts }
        notice = message; saving = false
    }
    var canDiscardReview: Bool {
        isCurrent && !busy && !saveUnconfirmed && !saveDurable &&
            (saveExpired && saveRequiresExisting && saveIntent != nil || !saveConflict && saveIntent == nil)
    }
    @discardableResult func discardReviewAndClose() async -> Bool {
        guard canDiscardReview else { return false }
        saving = true; stopPlayback(); defer { saving = false }
        if saveExpired, let expired = saveIntent {
            do {
                try await storage.discardExpiredReview(expired)
                AudioCommentReviewRecovery.retireRetainedAuthorization(expired)
                recovery.finishSave()
                let current = isCurrent
                close(); return current
            } catch {
                if isCurrent { notice = error.localizedDescription + " Your review is still here. Retry before closing." }
                else { close() }
                return false
            }
        }
        guard await recovery.clear() else { notice = recovery.failure; return false }
        guard isCurrent else { close(); return false }
        close(); return true
    }
    @discardableResult func prepareForDeparture() async -> Bool {
        stopPlayback()
        if session.phase == .authorizing || session.phase == .recording { stop() }
        while recordingBusy || loading || saving {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        guard !Task.isCancelled, !recordingBusy else { return false }
        return await recovery.preserveForDeparture()
    }
    @discardableResult func preserveReview() async -> Bool { await recovery.flush(retry: true) }
    @discardableResult func deleteSaved() async -> Bool {
        guard isCurrent, !busy, !saveUnconfirmed, !needsSave, let saved else { return false }
        stopPlayback(); saving = true; defer { saving = false }
        guard await recovery.clear() else { notice = recovery.failure; return false }
        guard isCurrent else { close(); return false }
        do {
            if let restoredRecovery { try await storage.discardReview(restoredRecovery.id, revision: restoredRecovery.revision); self.restoredRecovery = nil }
            guard isCurrent else { close(); return false }
            try await storage.discardDraft(saved.id, revision: saved.revision)
            guard isCurrent else { close(); return false }
            available.removeAll { $0.id == saved.id }; self.saved = nil; candidate = nil
            session = .init(workspace: request.scope.workspace, target: request.scope.target); elapsed = 0; notice = "Recording draft deleted."; return true
        } catch { if isCurrent { notice = error.localizedDescription } else { close() }; return false }
    }
    func play() {
        guard editable, let clip = session.clip else { return }
        stopPlayback()
        do { playing = true; try player.play(clip, isCurrent: { [weak self] in self?.isCurrent == true }) { [weak self] in self?.playing = false } }
        catch { playing = false; notice = error.localizedDescription }
    }
    func stopPlayback() { player.stop(); playing = false }
    func contextChanged() { if !isCurrent { close() } }
    func close() {
        Self.live.removeValue(forKey: lifecycleID)
        starting?.cancel(); ticker?.cancel(); decoding?.cancel(); recorder.cancel(); stopPlayback()
        if saveDurable { recovery.finishSave() } else { recovery.detachSave() }
        saveRequiresExisting = false; saveExpired = false
        session.close(); saved = nil; candidate = nil; available = []; recoverable = []; pendingSaves = []; interrupted = []; interruptionFailure = nil; interruptedActionsNeedAttention = false; saveIntent = nil; replacingIntent = nil; saveDurable = false; restoredRecovery = nil; notice = nil; elapsed = 0; saveUnconfirmed = false; saveConflict = false; reviewClaimed = false; retainedRecoveryFailed = false
        currentScope = { nil }
    }
}

/// Checkpoints are independent of explicit saved drafts. A writer is retained
/// while its bounded snapshot is not durably acknowledged, even if its view
/// disappears. It never consults a newer workspace or publishes to the network.
@MainActor @Observable final class AudioCommentReviewRecovery {
    @ObservationIgnored private static var retained: [UUID: AudioCommentReviewRecovery] = [:]
    let account: String
    var owner: AudioCommentOwner? { try? .init(account) }
    let target: AudioCommentTarget
    private(set) var failure: String?
    private(set) var pending = false
    @ObservationIgnored private let storage: AudioCommentDraftStorage
    @ObservationIgnored private let id = UUID()
    @ObservationIgnored private var desired: AudioCommentSavedDraft?
    @ObservationIgnored private var attempt: AudioCommentSavedDraft?
    @ObservationIgnored private var committed: AudioCommentSavedDraft?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var clearing = false
    struct HeldSave: Equatable {
        let intent: AudioCommentSaveIntent
        let replacing: AudioCommentSaveIntent?
        let fence: UUID?
        let existingOnly: Bool
        // A preservation nonce/constraint is not a different authored request.
        // Explicit retries may refresh the nonce and tighten existing-only scope.
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.intent == rhs.intent && lhs.replacing == rhs.replacing }
    }
    @ObservationIgnored private var heldSave: HeldSave?
    @ObservationIgnored private var heldSaveDurable = false
    @ObservationIgnored private var detached = false
    private var retainedBytes: Int { (desired?.clip.data.count ?? heldSave?.intent.next.clip.data.count ?? 0) + (attempt?.clip.data.count ?? 0) }
    init(account: String, target: AudioCommentTarget, storage: AudioCommentDraftStorage) {
        self.account = account; self.target = target; self.storage = storage
    }
    var durable: Bool { desired != nil && desired == committed && !pending && failure == nil }
    var requiresExistingSave: Bool { heldSave?.existingOnly == true }
    var preservedForDeparture: Bool {
        if heldSave != nil { return heldSaveDurable }
        return desired == nil || durable
    }
    static var hasUnpreservedWork: Bool { retained.values.contains { !$0.preservedForDeparture } }
    static func preserveAllForDeparture() async -> Bool {
        var success = true
        for writer in Array(retained.values) { if !(await writer.preserveForDeparture()) { success = false } }
        return success && !hasUnpreservedWork
    }
    @discardableResult func preserveForDeparture() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let held = heldSave else { return await flush(retry: true) }
        // Preparing the existing authorization does not commit a draft or clear
        // any review. Explicit Finish saving remains necessary after relaunch.
        do { try await storage.prepareSave(held.intent, replacing: held.replacing, fence: held.fence, existingOnly: held.existingOnly) } catch { }
        let state = try? await storage.saveState(held.intent)
        guard heldSave == held else { return preservedForDeparture }
        heldSaveDurable = state == .prepared || state == .settled
        if heldSaveDurable { failure = nil }
        else { failure = "The recording’s recovery copy couldn’t be confirmed. Keep Taskfold open and Finish saving before quitting." }
        return heldSaveDurable
    }

    func submit(clip: AudioCommentClip, caption: String, origin: AudioCommentReviewReference? = nil) throws {
        guard !clearing else { throw AudioCommentStorageFailure.busy }
        guard let owner else { throw AudioCommentFailure.changed }
        let next = try (desired?.replacing(caption: caption, clip: clip) ?? AudioCommentSavedDraft(owner: owner, target: target, caption: caption, clip: clip, id: id)).carryingOrigin(origin)
        if next == desired { return }
        let others = Self.retained.values.filter { $0 !== self }
        let bytes = others.reduce(0) { $0 + $1.retainedBytes }
        guard others.count < AudioCommentVault.maximumEntries,
              bytes + next.clip.data.count + (attempt?.clip.data.count ?? 0) <= AudioCommentVault.maximumTotalBytes else { throw AudioCommentStorageFailure.full }
        desired = next; pending = true; Self.retained[id] = self
        // A failed write may have committed. Retry that frozen attempt before
        // advancing to a newer caption/revision, never silently fork it.
        if failure == nil { run() }
    }
    private func run() {
        guard !clearing, task == nil, desired != nil else { return }
        failure = nil; pending = true; Self.retained[id] = self
        task = Task {
            var forked = false
            while let latest = desired, latest != committed {
                let next = attempt ?? latest; attempt = next
                do {
                    try await storage.checkpoint(next, replacing: committed?.revision)
                    committed = next; attempt = nil
                } catch {
                    if (error as? AudioCommentStorageFailure) == .conflict, !forked, let latest = desired, let owner,
                       let copy = try? AudioCommentSavedDraft(owner: owner, target: target, caption: latest.caption, clip: latest.clip, origin: latest.origin) {
                        // Another window may have explicitly settled/deleted the
                        // source copy. Keep this window's review independently;
                        // never overwrite a changed recovery revision.
                        desired = copy; attempt = nil; committed = nil; forked = true
                        continue
                    }
                    failure = "The recovery copy couldn’t be confirmed. Keep this window open and retry before quitting."; pending = false; task = nil; return
                }
            }
            pending = false; task = nil; Self.retained.removeValue(forKey: id)
        }
    }
    @discardableResult func flush(retry: Bool = false) async -> Bool {
        if retry || failure == nil { run() }
        while let task { await task.value }
        return desired == nil || durable
    }
    func freezeForSave() async -> [AudioCommentReviewReference] {
        clearing = true
        while let task { await task.value }
        return Array(Set([attempt, committed].compactMap { $0 }.map(AudioCommentReviewReference.init)))
    }
    /// Keep the exact explicit request if its state lookup cannot be read. This
    /// shares the bounded recovery registry, never a second unbounded payload cache.
    func holdSave(_ intent: AudioCommentSaveIntent, replacing old: AudioCommentSaveIntent?, fence: UUID? = nil, existingOnly: Bool = false) throws {
        guard intent.next.owner == owner, intent.next.target == target else { throw AudioCommentFailure.changed }
        let peers = Self.retained.values.filter { $0 !== self }
        let sameOperation = peers.filter { $0.heldSave?.intent.id == intent.id }
        let requiresExisting = existingOnly || sameOperation.contains { $0.heldSave?.existingOnly == true }
        let entry = HeldSave(intent: intent, replacing: old, fence: fence, existingOnly: requiresExisting)
        guard sameOperation.allSatisfy({ $0.heldSave == entry || $0.heldSave?.intent == old }) else { throw AudioCommentStorageFailure.conflict }
        let shared = sameOperation.contains { $0.heldSave == entry || $0.heldSave?.intent == old }
        let needsSlot = desired != nil || !shared
        if needsSlot, Self.retained[id] == nil {
            guard peers.count < AudioCommentVault.maximumEntries,
                  peers.reduce(0, { $0 + $1.retainedBytes }) + intent.next.clip.data.count <= AudioCommentVault.maximumTotalBytes else { throw AudioCommentStorageFailure.full }
        }
        for peer in sameOperation where peer.heldSave == entry || peer.heldSave?.intent == old { peer.heldSave = entry; peer.heldSaveDurable = false }
        heldSave = entry; heldSaveDurable = false; clearing = true; detached = false
        if needsSlot { Self.retained[id] = self }
    }
    func detachSave() { if heldSave != nil { detached = true } }
    func resumeAfterSave() {
        let previous = heldSave
        heldSave = nil; heldSaveDurable = false; detached = false; clearing = false
        if let previous {
            let matches = Self.retained.values.filter { $0 !== self && $0.detached && $0.heldSave == previous }
            for writer in matches { writer.heldSave = nil; writer.heldSaveDurable = false; writer.detached = false; writer.clearing = false; if writer.failure == nil { writer.run() } }
        }
        if desired == nil && attempt == nil && committed == nil { Self.retained.removeValue(forKey: id) }
        else if failure == nil { run() }
    }
    func finishSave() {
        desired = nil; committed = nil; attempt = nil; failure = nil; pending = false; clearing = false; heldSave = nil; heldSaveDurable = false; detached = false
        Self.retained.removeValue(forKey: id)
    }
    static func settleRetained(_ intent: AudioCommentSaveIntent) {
        let ids = Set(intent.reviews.map(\.id))
        let matches = retained.values.filter { writer in
            guard writer.owner == intent.next.owner, writer.target == intent.next.target, writer.clearing else { return false }
            if let held = writer.heldSave { return held.intent == intent }
            return [writer.desired, writer.attempt, writer.committed].compactMap({ $0?.id }).contains(where: ids.contains)
        }
        for writer in matches { writer.finishSave() }
    }
    /// An explicit independent copy supersedes only this exact volatile
    /// authorization. Other reviews/revisions and all disk records stay intact.
    static func retireRetainedAuthorization(_ intent: AudioCommentSaveIntent) {
        let matches = retained.values.filter { $0.heldSave?.intent == intent }
        for writer in matches { writer.finishSave() }
    }
    static func redirectRetained(_ original: AudioCommentSaveIntent, to winner: AudioCommentSaveIntent) {
        let matches = retained.values.filter { $0.heldSave?.intent == original }
        for writer in matches { writer.heldSave = .init(intent: winner, replacing: nil, fence: nil, existingOnly: true); writer.heldSaveDurable = false }
    }
    static func retainedSaves(owner: AudioCommentOwner, target: AudioCommentTarget) -> [HeldSave] {
        var unique: [UUID: HeldSave] = [:]
        for writer in retained.values where writer.owner == owner && writer.target == target && writer.detached {
            if let held = writer.heldSave { unique[held.intent.id] = held }
        }
        return unique.values.sorted { $0.intent.id.uuidString < $1.intent.id.uuidString }
    }
    static func retainedSave(_ requested: AudioCommentSaveIntent) -> HeldSave? {
        retainedSaves(owner: requested.next.owner, target: requested.next.target).first { $0.intent == requested }
    }
    /// Only an explicit Save/Discard removes an exact recovery revision. A
    /// failed removal leaves a harmless discoverable copy rather than losing it.
    @discardableResult func clear() async -> Bool {
        guard !clearing else { return false }
        clearing = true; defer { clearing = false }
        // Finish an already issued write, but never create another copy merely
        // to discard it. This also works at the account's storage quota.
        while let task { await task.value }
        let expected = [attempt, committed].compactMap { $0 }
        if !expected.isEmpty {
            do { try await storage.discardReviewCopies(expected) }
            catch { failure = "Your recovery copy could not be cleared. Retry before discarding it."; Self.retained[id] = self; return false }
        }
        desired = nil; committed = nil; attempt = nil; failure = nil; pending = false; Self.retained.removeValue(forKey: id); return true
    }
    /// Resume only the exact raw owner and task incarnation. This does not return
    /// private captions to another account, and all IO uses the original store.
    static func hasRetainedFailure(owner: AudioCommentOwner, target: AudioCommentTarget) -> Bool {
        retained.values.contains { $0.owner == owner && $0.target == target && ($0.failure != nil || $0.detached && $0.heldSave != nil) }
    }
    static func retryRetained(owner: AudioCommentOwner, target: AudioCommentTarget, excluding ids: Set<UUID> = []) async -> Bool {
        let matches = retained.values.filter { $0.owner == owner && $0.target == target }
        var success = true
        for writer in matches {
            if let held = writer.heldSave {
                guard writer.detached else { continue }
                let state = try? await writer.storage.saveState(held.intent)
                guard writer.heldSave == held, writer.detached else { continue }
                // Only an exact durable journal or settled draft can replace the
                // volatile authorization. Unknown/unprepared copies stay frozen
                // and discoverable through Finish saving, without an automatic Save.
                if state == .prepared || state == .settled { writer.finishSave() }
                else { success = false }
            } else if ![writer.desired, writer.attempt, writer.committed].compactMap({ $0?.id }).contains(where: ids.contains),
                      !(await writer.flush(retry: true)) { success = false }
        }
        return success
    }
}


/// A system provider can ask for bytes long after the Save button was tapped.
/// This permit survives the picker taking focus, but not presentation revocation,
/// a new export/selection, a source revision change, or account/realm departure.
@MainActor final class AudioCommentRecordingExport {
    private var bytes: Data?
    private var source: AudioCommentSavedDraft?
    private let storage: AudioCommentDraftStorage
    private let allowed: @MainActor () -> Bool
    init(bytes: Data, source: AudioCommentSavedDraft, storage: AudioCommentDraftStorage, allowed: @escaping @MainActor () -> Bool) {
        self.bytes = bytes; self.source = source; self.storage = storage; self.allowed = allowed
    }
    var isAllowed: Bool { bytes != nil && source != nil && allowed() }
    func invalidate() { bytes = nil; source = nil }
    func release() async throws -> Data {
        try Task.checkCancellation()
        guard let bytes, let source, isAllowed else { throw AudioCommentFailure(message: "This recording or workspace changed. Reopen the recording before exporting.") }
        _ = try await storage.savedLibraryRecording(source)
        try Task.checkCancellation()
        guard isAllowed else { throw AudioCommentFailure(message: "This recording or workspace changed. Reopen the recording before exporting.") }
        return bytes
    }
}

/// Saved private library. It can explicitly export an account-free backup; it
/// cannot Save, retarget, discard, publish or repair a recording.
@MainActor @Observable final class AudioCommentLibraryController {
    private final class WeakLibrary { weak var value: AudioCommentLibraryController?; init(_ value: AudioCommentLibraryController) { self.value = value } }
    @ObservationIgnored private static var live: [UUID: WeakLibrary] = [:]
    @ObservationIgnored private let lifecycleID = UUID()
    let scope: AudioCommentLibraryScope
    private(set) var library: AudioCommentSavedLibrary?
    private(set) var selected: AudioCommentSavedDraft?
    private(set) var working = false
    private(set) var playing = false
    var notice: String?
    @ObservationIgnored var currentScope: () -> AudioCommentLibraryScope? = { nil }
    @ObservationIgnored private let storage: AudioCommentDraftStorage
    @ObservationIgnored private let player: any AudioCommentPlaying
    @ObservationIgnored private let decode: @Sendable (Data) async throws -> AudioCommentClip
    @ObservationIgnored private var validated: AudioCommentClip?
    @ObservationIgnored private var operation = UUID()
    @ObservationIgnored private var exportGeneration = UUID()
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var active = true
    init(scope: AudioCommentLibraryScope, storage: AudioCommentDraftStorage, player: any AudioCommentPlaying, decode: @escaping @Sendable (Data) async throws -> AudioCommentClip = { try await AudioCommentDecoding.validate($0) }) {
        self.scope = scope; self.storage = storage; self.player = player; self.decode = decode
        Self.live = Self.live.filter { $0.value.value != nil }
        Self.live[lifecycleID] = WeakLibrary(self)
    }
    var isCurrent: Bool { !closed && storage.owner.account.utf8.elementsEqual(scope.workspace.account.utf8) && currentScope().map(scope.matches) == true }
    private func accepts(_ token: UUID) -> Bool { token == operation && active && isCurrent && !Task.isCancelled }
    private func invalidate() { operation = UUID(); working = false; player.stop(); playing = false }
    func stopPlayback() { invalidate() }
    func clearSelection(revokeExports: Bool = true) { invalidate(); if revokeExports { exportGeneration = UUID() }; selected = nil; validated = nil }
    func close() { clearSelection(); library = nil; notice = nil; closed = true; Self.live.removeValue(forKey: lifecycleID) }
    func contextChanged() { if !isCurrent { close() } }
    func setActive(_ value: Bool) { active = value; if !value { clearSelection(revokeExports: false) } }
    static func stopForInactivity() { for value in live.values.compactMap(\.value) { value.setActive(false) }; AudioCommentPendingLibrary.stopForInactivity(); AudioCommentConversationController.stopForInactivity() }
    func refresh(preservingExports: Bool = false) async {
        guard active, isCurrent else { contextChanged(); return }
        clearSelection(revokeExports: !preservingExports); library = nil; notice = nil; working = true
        let token = operation
        defer { if token == operation { working = false } }
        do {
            let value = try await storage.savedLibrary()
            guard accepts(token) else { contextChanged(); return }
            library = value
        } catch { if accepts(token) { notice = error.localizedDescription } else { contextChanged() } }
    }
    func select(_ expected: AudioCommentSavedDraft) async {
        guard active, isCurrent, !working else { contextChanged(); return }
        clearSelection(); notice = nil; working = true
        let token = operation
        defer { if token == operation { working = false } }
        do {
            let source = try await storage.savedLibraryRecording(expected)
            guard accepts(token) else { contextChanged(); return }
            let clip = try await decode(source.clip.data)
            guard accepts(token) else { contextChanged(); return }
            // Native presentation duration can differ from an older container-
            // measured descriptor because AAC includes priming/remainder frames.
            // Full decode validates the codec; exact bytes bind the original file.
            guard clip.data == source.clip.data else { throw AudioCommentFailure.invalid }
            _ = try await storage.savedLibraryRecording(source)
            guard accepts(token) else { contextChanged(); return }
            validated = clip; selected = source
        } catch { if accepts(token) { notice = error.localizedDescription } else { contextChanged() } }
    }
    /// Selected bytes were fully decoded by select(). Revalidate the exact disk
    /// revision and legacy pending work immediately before preparing publication.
    func publicationSourceIsCurrent(_ expected: AudioCommentSavedDraft) -> Bool {
        active && isCurrent && selected == expected && validated?.data == expected.clip.data
    }
    func preparePublicationSource(_ expected: AudioCommentSavedDraft) async throws -> AudioCommentSavedDraft {
        guard publicationSourceIsCurrent(expected), !working, UUID(uuidString: expected.owner.account) != nil else { throw AudioCommentFailure.changed }
        invalidate(); working = true; let token = operation
        defer { if token == operation { working = false } }
        let pending = try await storage.pending()
        guard accepts(token), selected == expected else { throw CancellationError() }
        guard !pending.contains(where: { $0.publication.target == expected.target }) else { throw AudioCommentFailure(message: "An earlier publication needs review. Its original recording and operation are preserved.") }
        let current = try await storage.savedLibraryRecording(expected)
        guard accepts(token), selected == expected else { throw CancellationError() }; return current
    }
    func prepareExport() async throws -> AudioCommentRecordingExport {
        guard active, isCurrent, !working, let selected, let clip = validated, clip.data == selected.clip.data else { throw AudioCommentFailure.changed }
        invalidate(); exportGeneration = UUID(); working = true; notice = nil
        let token = operation, authorization = exportGeneration
        defer { if token == operation { working = false } }
        do {
            _ = try await storage.savedLibraryRecording(selected)
            guard accepts(token), self.selected == selected else { throw CancellationError() }
            let worker = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let bytes = try AudioCommentPortableRecording(caption: selected.caption, clip: selected.clip).encoded()
                try Task.checkCancellation(); return bytes
            }
            let bytes = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            guard accepts(token), self.selected == selected else { throw CancellationError() }
            _ = try await storage.savedLibraryRecording(selected)
            guard accepts(token), self.selected == selected else { throw CancellationError() }
            return AudioCommentRecordingExport(bytes: bytes, source: selected, storage: storage, allowed: { [weak self] in
                guard let self else { return false }; return self.isCurrent && self.exportGeneration == authorization
            })
        } catch {
            if isCurrent, token == operation { clearSelection() } else { contextChanged() }
            throw error
        }
    }
    func play() async {
        guard active, isCurrent, !working, let selected, let clip = validated else { contextChanged(); return }
        invalidate(); working = true; notice = nil
        let token = operation
        defer { if token == operation { working = false } }
        do {
            _ = try await storage.savedLibraryRecording(selected)
            guard accepts(token), self.selected == selected else { contextChanged(); return }
            playing = true
            try player.play(clip, isCurrent: { [weak self] in self?.accepts(token) == true }, ended: { [weak self] in
                guard let self, self.accepts(token) else { return }; self.playing = false
            })
        } catch {
            if accepts(token) { clearSelection(); notice = error.localizedDescription }
            else { contextChanged() }
        }
    }
}

/// Device-private review of frozen operations, independent of a surviving saved
/// draft or current task permission. Network retry has a separate Store gate.
@MainActor @Observable final class AudioCommentPendingLibrary {
    private final class Weak { weak var value: AudioCommentPendingLibrary?; init(_ value: AudioCommentPendingLibrary) { self.value = value } }
    @ObservationIgnored private static var live: [UUID: Weak] = [:]
    @ObservationIgnored private let id = UUID()
    let scope: AudioCommentLibraryScope
    private(set) var entries: [AudioCommentPublicationJournal] = []
    private(set) var selected: AudioCommentPublicationJournal?
    private(set) var working = false
    private(set) var playing = false
    var notice: String?
    @ObservationIgnored var currentScope: () -> AudioCommentLibraryScope? = { nil }
    @ObservationIgnored let storage: AudioCommentPublicationStorage
    @ObservationIgnored private let drafts: AudioCommentDraftStorage
    @ObservationIgnored private let player: any AudioCommentPlaying
    @ObservationIgnored private let decode: @Sendable (Data) async throws -> AudioCommentClip
    @ObservationIgnored private var validated: AudioCommentClip?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var active = true
    @ObservationIgnored private var closed = false
    init(scope: AudioCommentLibraryScope, storage: AudioCommentPublicationStorage, drafts: AudioCommentDraftStorage, player: any AudioCommentPlaying, decode: @escaping @Sendable (Data) async throws -> AudioCommentClip = { try await AudioCommentDecoding.validate($0) }) {
        self.scope = scope; self.storage = storage; self.drafts = drafts; self.player = player; self.decode = decode
        Self.live = Self.live.filter { $0.value.value != nil }; Self.live[id] = Weak(self)
    }
    var isCurrent: Bool {
        !closed && active && scope.workspace.account == storage.account.uuidString.lowercased() && drafts.owner.account == scope.workspace.account &&
        scope.origin.flatMap { try? AudioCommentPublicationJournal.canonicalOrigin($0) } == storage.origin && currentScope().map(scope.matches) == true
    }
    private func same(_ a: AudioCommentPublicationJournal, _ b: AudioCommentPublicationJournal) -> Bool { a.origin == b.origin && a.source == b.source && a.revision == b.revision && a.publication.sameIntent(as: b.publication) }
    func selectedIsCurrent(_ value: AudioCommentPublicationJournal) -> Bool { isCurrent && selected.map { same($0, value) } == true }
    private func accepts(_ token: UUID) -> Bool { generation == token && isCurrent && !Task.isCancelled }
    func stopPlayback() { generation = UUID(); player.stop(); playing = false; working = false }
    func clearSelection() { stopPlayback(); selected = nil; validated = nil; notice = nil }
    func close() { clearSelection(); entries = []; closed = true; Self.live.removeValue(forKey: id) }
    func setActive(_ value: Bool) { active = value; if !value { clearSelection(); entries = [] } }
    static func stopForInactivity() { for item in live.values.compactMap(\.value) { item.setActive(false) } }
    private func read(_ expected: AudioCommentPublicationJournal) async throws -> AudioCommentPublicationJournal {
        let rows = try await storage.journals()
        guard let value = rows.first(where: { same($0, expected) }) else { throw AudioCommentStorageFailure.conflict }; return value
    }
    func refresh() async {
        guard isCurrent else { clearSelection(); entries = []; return }
        clearSelection(); working = true; let token = generation
        defer { if generation == token { working = false } }
        do {
            let rows = try await storage.journals(); guard accepts(token) else { return }
            entries = rows.filter { $0.isPending || $0.clip != nil }
        } catch { if accepts(token) { notice = error.localizedDescription } }
    }
    func select(_ expected: AudioCommentPublicationJournal) async {
        guard isCurrent, !working else { return }; clearSelection(); working = true; let token = generation
        defer { if generation == token { working = false } }
        do {
            let value = try await read(expected); guard accepts(token), let clip = value.clip else { throw CancellationError() }
            let decoded = try await decode(clip.data); guard accepts(token), decoded.data == clip.data else { throw CancellationError() }
            let current = try await read(value); guard accepts(token), let currentClip = current.clip, currentClip.data == clip.data else { throw AudioCommentStorageFailure.conflict }
            selected = current; validated = decoded
        } catch { if accepts(token) { notice = "This publication changed. Reload its current local copy." } }
    }
    func play() async {
        guard isCurrent, !working, let expected = selected, let decoded = validated else { return }
        stopPlayback(); working = true; let token = generation
        defer { if generation == token { working = false } }
        do {
            let value = try await read(expected); guard accepts(token), value.clip?.data == decoded.data else { throw AudioCommentStorageFailure.conflict }
            selected = value; playing = true
            try player.play(decoded, isCurrent: { [weak self] in self?.accepts(token) == true }, ended: { [weak self] in guard let self, self.accepts(token) else { return }; self.playing = false })
        } catch { if accepts(token) { stopPlayback(); notice = "This publication changed. Reload before playing it." } }
    }
    func keepPrivateCopy() async throws {
        guard isCurrent, !working, let expected = selected, let decoded = validated else { throw AudioCommentFailure.changed }
        stopPlayback(); working = true; let token = generation
        defer { if generation == token { working = false } }
        let value = try await read(expected); guard accepts(token), let clip = value.clip, clip.data == decoded.data else { throw AudioCommentStorageFailure.conflict }
        // Stable IDs make retries idempotent; a newer/foreign existing file must
        // conflict rather than be overwritten. Original edited drafts are untouched.
        let copy = try AudioCommentSavedDraft(owner: .init(scope.workspace.account), target: value.publication.target, caption: value.publication.caption, clip: clip, id: value.publication.asset, revision: value.publication.operation)
        try await drafts.save(copy); guard accepts(token) else { throw CancellationError() }
        _ = try await drafts.savedLibraryRecording(copy); guard accepts(token) else { throw CancellationError() }
        notice = "Private copy saved. It is available in Saved recordings."
    }
    func removeConfirmedCopy() async throws {
        guard selected?.receipt != nil else {throw AudioCommentStorageFailure.conflict}
        try await removeResolvedCopy()
    }
    func removeResolvedCopy() async throws {
        guard isCurrent, !working, let value = selected, value.isResolved else { throw AudioCommentStorageFailure.conflict }
        stopPlayback(); working = true; let token = generation
        defer { if generation == token { working = false } }
        _ = try await storage.releaseResolvedAudio(value); guard accepts(token) else { throw CancellationError() }
        selected = nil; validated = nil; entries.removeAll { same($0, value) }; notice = "Private publication copy removed."
    }
    func updateAfterConfirmation() async throws {
        guard isCurrent, let expected = selected else { throw CancellationError() }
        let token = generation, rows = try await storage.journals(); guard accepts(token) else { throw CancellationError() }
        guard let value = rows.first(where: { same($0, expected) }) else { throw AudioCommentStorageFailure.conflict }
        entries = rows.filter { $0.isPending || $0.clip != nil }
        if value.clip == nil {
            player.stop(); playing = false; validated = nil; selected = nil
            notice = "This private publication copy was removed in another window."
        } else { selected = value }
    }
}


struct AudioCommentConversationRequest: Identifiable {
    let id = UUID()
    let scope: AudioCommentLiveScope
}
/// In-memory live conversation only. Every Play reauthorizes through the server;
/// recordings are never persisted into drafts or task exports by this reader.
@MainActor @Observable final class AudioCommentConversationController {
    private final class Weak { weak var value: AudioCommentConversationController?; init(_ value: AudioCommentConversationController) { self.value = value } }
    private static var live: [UUID: Weak] = [:]
    private let id = UUID()
    let scope: AudioCommentLiveScope
    let account: UUID
    let origin: String
    private let incarnation: UUID
    private let transport: any AudioCommentReadingTransport
    private let player: any AudioCommentPlaying
    @ObservationIgnored var currentScope: () -> AudioCommentLiveScope? = { nil }
    @ObservationIgnored var removalAuthority: (AudioCommentRemote) -> Bool = { _ in false }
    @ObservationIgnored var sessionIsCurrent: () -> Bool = { false }
    private(set) var entries: [AudioCommentRemote] = []
    private(set) var hasMore = false
    private var next: AudioCommentPageCursor?
    private(set) var playing: UUID?
    private(set) var working = false
    private(set) var notice: String?
    @ObservationIgnored private var active = true
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var token = UUID()
    init(scope: AudioCommentLiveScope, incarnation: UUID, transport: any AudioCommentReadingTransport, player: any AudioCommentPlaying) throws {
        guard let account = UUID(uuidString: scope.workspace.account), account != AudioCommentTarget.zero, account.uuidString.lowercased() == scope.workspace.account, let origin = scope.origin, try AudioCommentPublicationJournal.canonicalOrigin(origin) == origin else { throw AudioCommentFailure.changed }
        self.scope = scope; self.account = account; self.origin = origin; self.incarnation = incarnation; self.transport = transport; self.player = player
        Self.live = Self.live.filter { $0.value.value != nil }; Self.live[id] = Weak(self)
    }
    var isCurrent: Bool { !closed && active && sessionIsCurrent() && currentScope().map(scope.matches) == true }
    private func accepts(_ value: UUID) -> Bool { token == value && isCurrent && !Task.isCancelled }
    func stop() { token = UUID(); player.stop(); playing = nil; working = false }
    func close() { stop(); entries = []; next = nil; hasMore = false; notice = nil; closed = true; Self.live.removeValue(forKey: id) }
    func setActive(_ value: Bool) { active = value; if !value { stop(); entries = []; next = nil; hasMore = false; notice = nil } }
    static func stopForInactivity() { for item in live.values.compactMap(\.value) { item.setActive(false) } }
    func refresh() async {
        guard isCurrent else { setActive(false); return }; stop(); entries = []; next = nil; hasMore = false; notice = nil
        await fetch(after:nil)
    }
    func loadMore() async {
        guard isCurrent, !working, hasMore, let next else { return }; stop(); notice=nil
        await fetch(after:next)
    }
    private func fetch(after: AudioCommentPageCursor?) async {
        working=true; let generation=token
        defer { if token==generation { working=false } }
        do {
            let page=try await transport.pageAudio(account:account,target:scope.target,after:after,origin:origin,incarnation:incarnation)
            guard accepts(generation) else { return }
            let combined=(after == nil ? [] : entries)+page.items
            guard page.items.count<=20, Set(combined.map(\.id)).count==combined.count,
                  combined.allSatisfy({ $0.publication.account==account && $0.publication.target==scope.target }),
                  page.next == nil || page.next?.account==account && page.next?.target==scope.target && page.next != after else { throw AudioCommentFailure.invalid }
            entries=combined;next=page.next;hasMore=next != nil
        } catch { if accepts(generation), !clearDeniedAccess(error) { notice="Recordings couldn’t be loaded. Try again or refresh the conversation." } }
    }
    private func clearDeniedAccess(_ error: Error) -> Bool {
        guard error is AudioCommentReadAccessUnavailable || error is AccountSessionAuthorizationRequired else { return false }
        stop(); entries=[]; next=nil; hasMore=false; notice="This conversation is no longer available. Refresh access before reopening it."; return true
    }
    private func contains(_ value: AudioCommentRemote) -> Bool { isCurrent && value.publication.account == account && value.publication.target == scope.target && entries.contains(value) }
    func play(_ value: AudioCommentRemote) async {
        guard contains(value), !working else { return }; stop(); notice = nil; working = true; let generation = token
        defer { if token == generation { working = false } }
        do {
            let clip = try await transport.downloadAudio(value, origin: origin, incarnation: incarnation)
            guard accepts(generation), contains(value), clip.descriptor == value.publication.descriptor else { throw CancellationError() }
            playing = value.id
            try player.play(clip, isCurrent: { [weak self] in self?.accepts(generation) == true }, ended: { [weak self] in guard let self, self.accepts(generation) else { return }; self.playing = nil })
        } catch { if accepts(generation), !clearDeniedAccess(error) { stop(); notice = "This recording couldn’t be played. Refresh its current conversation before trying again." } }
    }
    func mayRemove(_ value: AudioCommentRemote) -> Bool { contains(value) && removalAuthority(value) }
    func remove(_ value: AudioCommentRemote) async {
        guard mayRemove(value), !working else { return }; stop(); notice = nil; working = true; let generation = token
        defer { if token == generation { working = false } }
        do {
            let removed = try await transport.removeAudio(value, origin: origin, incarnation: incarnation)
            guard accepts(generation), removed.comment == value.id, removed.operation == value.publication.operation else { throw CancellationError() }
            entries.removeAll { $0.id == value.id }; notice = "Audio comment removed. Private saved recordings are unchanged."
        } catch { if accepts(generation), !clearDeniedAccess(error) { notice = "Removal couldn’t be confirmed. Refresh before trying again; private saved recordings are unchanged." } }
    }
}

#if !AUDIO_COMMENT_CONTROLLER_TESTING
@MainActor extension Store {
    var audioDraftsEnabled: Bool {
        #if DEBUG
        if AudioCommentNativeFixture.taskEditorTesting { return true }
        #endif
        return Bundle.main.object(forInfoDictionaryKey: "TaskfoldAudioDraftsEnabled") as? Bool == true
    }
    var audioPublishingEnabled: Bool {
        audioDraftsEnabled && Bundle.main.object(forInfoDictionaryKey: "TaskfoldAudioPublishingEnabled") as? Bool == true
    }
    func audioPublishingScope(_ target: AudioCommentTarget) -> AudioCommentLiveScope? {
        guard audioPublishingEnabled, !localMode, signedIn, !workspaceNeedsRepair,
              let scope = audioDraftScope(taskID: target.task.uuidString.lowercased()), scope.target == target,
              UUID(uuidString: scope.workspace.account) != nil, backend.audioPublicationSessionMatches(scope.workspace.account),
              scope.origin != nil else { return nil }; return scope
    }
    func audioPublisher(for scope: AudioCommentLiveScope, source: AudioCommentSavedDraft, library: AudioCommentLibraryController) throws -> AudioCommentPublicationFlow {
        guard let current = audioPublishingScope(scope.target), scope.matches(current), let origin = scope.origin,
              let account = UUID(uuidString: scope.workspace.account), source.target == scope.target,
              library.scope.matches(.init(workspace: scope.workspace, origin: scope.origin)), library.publicationSourceIsCurrent(source) else { throw AudioCommentFailure.changed }
        let root = try audioDraftDirectory(for: scope, taskID: scope.target.task.uuidString.lowercased())
        let disk = try AudioCommentPublicationDisk(root: root, account: account, origin: origin), incarnation = backend.reminderSessionIncarnation
        return AudioCommentPublicationFlow(storage: .init(disk: disk), transport: backend, incarnation: incarnation, target: scope.target, retainAudioOnConfirmation: true, isCurrent: { [weak self, weak library] in
            guard let self, let library, library.publicationSourceIsCurrent(source), self.backend.reminderSessionIncarnation == incarnation,
                  let current = self.audioPublishingScope(scope.target) else { return false }; return scope.matches(current)
        })
    }
    func audioReadScope(_ target: AudioCommentTarget) -> AudioCommentLiveScope? {
        guard audioPublishingEnabled, teamOrganizationReadable, !workspaceNeedsRepair,
              backend.audioPublicationSessionMatches(userID), let task=record("tasks",id:target.task.uuidString.lowercased()),
              let origin=try? backend.accountRemovalOrigin,
              let admitted=try? AudioCommentReadAdmission.target(account:userID,origin:origin,task:task,projects:rows("projects"),cache:nativeConversationTeamCache,teamsEnabled:Bundle.main.object(forInfoDictionaryKey:"TaskfoldTeamsEnabled") as? Bool == true), admitted==target else { return nil }
        return .init(workspace:.init(account:userID,generation:workspaceGeneration),target:target,origin:origin)
    }
    func audioConversationRequest(taskID: String) -> AudioCommentConversationRequest? {
        guard let task=record("tasks",id:taskID), let id=UUID(uuidString:task.id), let generation=UUID(uuidString:task.string("task_generation")),
              task.string("project_id").isEmpty || UUID(uuidString:task.string("project_id")) != nil,
              let target=try? AudioCommentTarget(task:id,generation:generation,project:UUID(uuidString:task.string("project_id"))),
              let scope=audioReadScope(target) else { return nil }
        return .init(scope:scope)
    }
    func audioConversation(scope: AudioCommentLiveScope, player: any AudioCommentPlaying) throws -> AudioCommentConversationController {
        guard let current = audioReadScope(scope.target), scope.matches(current) else { throw AudioCommentFailure.changed }
        let incarnation = backend.reminderSessionIncarnation
        let controller = try AudioCommentConversationController(scope: scope, incarnation: incarnation, transport: backend, player: player)
        controller.currentScope = { [weak self] in self?.audioReadScope(scope.target) }
        controller.sessionIsCurrent = { [weak self] in self?.backend.reminderSessionIncarnation == incarnation && self?.backend.audioPublicationSessionMatches(scope.workspace.account) == true }
        controller.removalAuthority = { [weak self] comment in
            guard let self, let current=self.audioReadScope(scope.target), scope.matches(current) else { return false }
            return AudioCommentReadAdmission.mayRemove(author:comment.author,account:self.userID,target:scope.target,projects:self.rows("projects"),cache:self.nativeConversationTeamCache)
        }
        return controller
    }
    func audioPendingScope() -> AudioCommentLibraryScope? {
        guard audioPublishingEnabled, !localMode, signedIn, let scope = audioLibraryScope(), UUID(uuidString: scope.workspace.account) != nil, backend.audioPublicationSessionMatches(scope.workspace.account) else { return nil }; return scope
    }
    func audioPendingLibrary(scope: AudioCommentLibraryScope, player: any AudioCommentPlaying) async throws -> AudioCommentPendingLibrary {
        guard let current = audioPendingScope(), scope.matches(current), let account = UUID(uuidString: scope.workspace.account), let origin = scope.origin else { throw AudioCommentFailure.changed }
        let root = try audioLibraryDirectory(for: scope)
        let drafts = try await AudioCommentDraftStorage.open(applicationSupport: root, owner: .init(scope.workspace.account))
        guard let current = audioPendingScope(), scope.matches(current) else { throw CancellationError() }
        let pending = AudioCommentPendingLibrary(scope: scope, storage: .init(disk: try .init(root: root, account: account, origin: origin)), drafts: drafts, player: player)
        pending.currentScope = { [weak self] in self?.audioPendingScope() }; return pending
    }
    /// Sender-only status has no current task read/write authority and cannot publish.
    func audioPendingChecker(_ journal:AudioCommentPublicationJournal,library:AudioCommentPendingLibrary) throws -> AudioCommentPublicationFlow {
        guard let scope=audioPendingScope(),library.selectedIsCurrent(journal),scope.matches(library.scope),
              journal.origin==library.storage.origin,journal.publication.account==library.storage.account else {throw AudioCommentFailure.changed}
        let incarnation=backend.reminderSessionIncarnation
        return AudioCommentPublicationFlow(storage:library.storage,transport:backend,incarnation:incarnation,target:journal.publication.target,retainAudioOnConfirmation:true,allowsPublishing:false,isCurrent:{[weak self,weak library] in
            guard let self,let library,library.selectedIsCurrent(journal),self.backend.reminderSessionIncarnation==incarnation,let current=self.audioPendingScope() else {return false}
            return scope.matches(current)
        })
    }
    func audioPendingPublisher(_ journal: AudioCommentPublicationJournal, library: AudioCommentPendingLibrary) throws -> AudioCommentPublicationFlow {
        guard let scope = audioPublishingScope(journal.publication.target), library.selectedIsCurrent(journal),
              library.scope.matches(.init(workspace: scope.workspace, origin: scope.origin)), journal.origin == library.storage.origin, journal.publication.account == library.storage.account else { throw AudioCommentFailure.changed }
        let incarnation = backend.reminderSessionIncarnation
        return AudioCommentPublicationFlow(storage: library.storage, transport: backend, incarnation: incarnation, target: scope.target, retainAudioOnConfirmation: true, isCurrent: { [weak self, weak library] in
            guard let self, let library, library.selectedIsCurrent(journal), self.backend.reminderSessionIncarnation == incarnation,
                  let current = self.audioPublishingScope(scope.target) else { return false }; return scope.matches(current)
        })
    }
    func audioLibraryScope() -> AudioCommentLibraryScope? {
        guard audioDraftsEnabled, !workspaceNeedsRepair, (try? AudioCommentOwner(userID)) != nil else { return nil }
        let origin: String?
        if localMode { origin = nil } else { guard let value = try? backend.accountRemovalOrigin else { return nil }; origin = value }
        guard (try? AudioCommentTaskAdmission.storageDirectory(origin: origin)) != nil else { return nil }
        return .init(workspace: .init(account: userID, generation: workspaceGeneration), origin: origin)
    }
    func audioLibraryDirectory(for scope: AudioCommentLibraryScope) throws -> URL {
        guard let current = audioLibraryScope(), scope.matches(current) else { throw AudioCommentFailure.changed }
        return try audioDraftBaseDirectory().appendingPathComponent(AudioCommentTaskAdmission.storageDirectory(origin: scope.origin), isDirectory: true)
    }
    func audioLibraryTask(_ target: AudioCommentTarget) -> (title: String, location: AudioCommentSavedLibrary.TaskLocation)? {
        let matches = (snapshot.tables["tasks"] ?? []).filter { UUID(uuidString: $0.id) == target.task }
        guard matches.count == 1, let task = matches.first,
              let admitted = audioDraftScope(taskID: task.id)?.target else { return nil }
        let location = AudioCommentSavedLibrary.location(of: target, admitted: [admitted])
        guard location != .unavailable else { return nil }
        return (task.title, location)
    }
    func audioDraftScope(taskID: String) -> AudioCommentLiveScope? {
        guard audioDraftsEnabled, let current = record("tasks", id: taskID),
              editorMayWrite(source: current, proposed: current),
              let target = try? AudioCommentTaskAdmission.target(account: userID, task: current, projects: snapshot.tables["projects"] ?? []) else { return nil }
        let origin: String?
        if localMode { origin = nil } else { guard let value = try? backend.accountRemovalOrigin else { return nil }; origin = value }
        guard (try? AudioCommentTaskAdmission.storageDirectory(origin: origin)) != nil else { return nil }
        return .init(workspace: .init(account: userID, generation: workspaceGeneration), target: target, origin: origin)
    }
    func audioDraftRequest(taskID: String) -> AudioCommentDraftRequest? {
        guard let scope = audioDraftScope(taskID: taskID), let current = record("tasks", id: taskID) else { return nil }
        return .init(scope: scope, title: current.title)
    }
    func audioDraftBaseDirectory() throws -> URL {
        guard let identifier = Bundle.main.bundleIdentifier else { throw AudioCommentFailure.changed }
        return cacheURL.deletingLastPathComponent().appendingPathComponent("PrivateAudioDrafts", isDirectory: true)
            .appendingPathComponent(try AudioCommentTaskAdmission.applicationDirectory(bundleIdentifier: identifier), isDirectory: true)
    }
    func audioDraftDirectory(for scope: AudioCommentLiveScope, taskID: String) throws -> URL {
        guard let current = audioDraftScope(taskID: taskID), scope.matches(current) else { throw AudioCommentFailure.changed }
        return try audioDraftBaseDirectory().appendingPathComponent(AudioCommentTaskAdmission.storageDirectory(origin: scope.origin), isDirectory: true)
    }
}
#endif
