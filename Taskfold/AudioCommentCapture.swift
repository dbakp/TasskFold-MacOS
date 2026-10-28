import Foundation
import Observation
#if AUDIO_COMMENT_CONTROLLER_TESTING
@testable import TaskfoldCore
#endif

struct AudioCommentLiveScope: Sendable {
    let workspace: WorkspaceBinding
    let target: AudioCommentTarget
    func matches(_ other: Self) -> Bool { workspace.generation == other.workspace.generation && !workspace.account.isEmpty && workspace.account.utf8.elementsEqual(other.workspace.account.utf8) && target == other.target }
}
struct AudioCommentDraftRequest: Identifiable, Sendable {
    let id = UUID()
    let scope: AudioCommentLiveScope
    let title: String
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
    static func stopPlaybackForInactivity() { for capture in live.values.compactMap(\.value) { capture.stopPlayback() } }
    static func preserveForDeparture() async -> Bool {
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
            if !retried { notice = hasUnwrittenSaves ? "Finish saving the recording below to keep it on this device." : "An interrupted review still needs a recovery retry. Keep Taskfold open before quitting." }
        } catch { if isCurrent { notice = error.localizedDescription } else { close() } }
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
            } else if !saveDurable, (state == .unprepared || !retryingSave), let failure = failure as? AudioCommentStorageFailure, failure == .full || failure == .busy {
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
    @discardableResult func discardReviewAndClose() async -> Bool {
        guard isCurrent, !busy, !saveUnconfirmed, !saveDurable, saveIntent == nil else { return false }
        saving = true; defer { saving = false }
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
        session.close(); saved = nil; candidate = nil; available = []; recoverable = []; pendingSaves = []; saveIntent = nil; replacingIntent = nil; saveDurable = false; restoredRecovery = nil; notice = nil; elapsed = 0; saveUnconfirmed = false; saveConflict = false; reviewClaimed = false; retainedRecoveryFailed = false
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
