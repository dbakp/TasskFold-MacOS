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
    let request: AudioCommentDraftRequest
    private(set) var session: AudioCommentDraft
    private(set) var saved: AudioCommentSavedDraft?
    private(set) var available: [AudioCommentSavedDraft] = []
    private(set) var recoverable: [AudioCommentSavedDraft] = []
    private(set) var saveConflict = false
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
    @ObservationIgnored private var restoredRecovery: AudioCommentSavedDraft?
    init(request: AudioCommentDraftRequest, recorder: any AudioCommentRecording, player: any AudioCommentPlaying, storage: AudioCommentDraftStorage) {
        self.request = request; self.recorder = recorder; self.player = player; self.storage = storage
        recovery = .init(account: request.scope.workspace.account, target: request.scope.target, storage: storage)
        session = .init(workspace: request.scope.workspace, target: request.scope.target)
    }
    var isCurrent: Bool { currentScope().map(request.scope.matches) == true && session.phase != .closed }
    var recordingBusy: Bool { [.authorizing, .recording, .finishing].contains(session.phase) }
    var busy: Bool { recordingBusy || loading || saving }
    var editable: Bool { isCurrent && !busy && !saveUnconfirmed && !saveConflict }
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
                    try self.recovery.submit(clip: clip, caption: self.session.caption)
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
            if let clip = session.clip { try recovery.submit(clip: clip, caption: text) }
            try session.editCaption(text); notice = nil
        } catch { notice = error.localizedDescription }
    }
    func refresh() async {
        guard isCurrent, !busy else { return }; loading = true; defer { loading = false }
        do {
            let owner = try AudioCommentOwner(request.scope.workspace.account)
            let retried = await AudioCommentReviewRecovery.retryRetained(owner: owner, target: request.scope.target)
            guard isCurrent else { close(); return }
            retainedRecoveryFailed = !retried
            let drafts = try await storage.drafts()
            guard isCurrent else { close(); return }
            available = drafts.filter { $0.target == request.scope.target }
            let reviews = try await storage.reviews()
            guard isCurrent else { close(); return }
            recoverable = reviews.filter { $0.target == request.scope.target }
            if !retried { notice = "An interrupted review still needs a recovery retry. Keep Taskfold open before quitting." }
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
            if recovering { try recovery.submit(clip: clip, caption: draft.caption) }
        } catch { if isCurrent { notice = error.localizedDescription } else { close() } }
    }
    @discardableResult func save() async -> Bool {
        guard isCurrent, !busy, let clip = session.clip, session.phase == .review else { return false }
        stopPlayback(); saving = true; defer { saving = false }
        do {
            let next: AudioCommentSavedDraft
            if let candidate { next = candidate }
            else if let saved { next = try saved.replacing(caption: session.caption, clip: clip); candidate = next; candidateBase = saved.revision }
            else { next = try .init(owner: .init(request.scope.workspace.account), target: request.scope.target, caption: session.caption, clip: clip); candidate = next; candidateBase = nil }
            try await storage.save(next, replacing: candidateBase)
            guard isCurrent else { close(); return false }
            saved = next; candidate = nil; candidateBase = nil; saveUnconfirmed = false; saveConflict = false
            let cleared = await recovery.clear()
            if let restoredRecovery {
                do { try await storage.discardReview(restoredRecovery.id, revision: restoredRecovery.revision); self.restoredRecovery = nil }
                catch { /* Keep the exact copy discoverable if cleanup cannot be confirmed. */ }
            }
            guard isCurrent else { close(); return false }
            let remainingReviews = try? await storage.reviews()
            guard isCurrent else { close(); return false }
            if let remainingReviews { recoverable = remainingReviews.filter { $0.target == request.scope.target } }
            available.removeAll { $0.id == next.id }; available.insert(next, at: 0)
            notice = cleared ? "Saved on this device." : "Draft saved. A recovery copy remains on this device."; return true
        } catch {
            guard isCurrent else { close(); return false }
            if (error as? AudioCommentStorageFailure) == .conflict {
                saveConflict = true; saveUnconfirmed = false
                notice = "This draft changed in another window. Your review is still here. Save a separate draft to keep both versions."
            } else if let failure = error as? AudioCommentStorageFailure, failure == .full || failure == .busy {
                // These failures occur before any payload replacement. Keep the
                // review editable and allow deliberate discard/storage cleanup.
                candidate = nil; candidateBase = nil; saveUnconfirmed = false; saveConflict = false
                notice = failure.localizedDescription + " Your review is still here."
            } else {
                saveUnconfirmed = true; notice = "The save couldn’t be confirmed. Retry save before editing or closing; your recording is still here."
            }
            return false
        }
    }
    @discardableResult func saveSeparateDraft() async -> Bool {
        guard isCurrent, !busy, saveConflict, let clip = session.clip else { return false }
        do {
            candidate = try .init(owner: .init(request.scope.workspace.account), target: request.scope.target, caption: session.caption, clip: clip)
            candidateBase = nil; saveConflict = false
            return await save()
        } catch { notice = error.localizedDescription; return false }
    }
    @discardableResult func discardReviewAndClose() async -> Bool {
        guard isCurrent, !busy, !saveUnconfirmed else { return false }
        saving = true; defer { saving = false }
        guard await recovery.clear() else { notice = recovery.failure; return false }
        guard isCurrent else { close(); return false }
        close(); return true
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
        starting?.cancel(); ticker?.cancel(); decoding?.cancel(); recorder.cancel(); stopPlayback()
        session.close(); saved = nil; candidate = nil; available = []; recoverable = []; restoredRecovery = nil; notice = nil; elapsed = 0; saveUnconfirmed = false; saveConflict = false; retainedRecoveryFailed = false
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
    init(account: String, target: AudioCommentTarget, storage: AudioCommentDraftStorage) {
        self.account = account; self.target = target; self.storage = storage
    }
    var durable: Bool { desired != nil && desired == committed && !pending && failure == nil }
    func submit(clip: AudioCommentClip, caption: String) throws {
        guard !clearing else { throw AudioCommentStorageFailure.busy }
        guard let owner else { throw AudioCommentFailure.changed }
        let next = try desired?.replacing(caption: caption, clip: clip) ?? AudioCommentSavedDraft(owner: owner, target: target, caption: caption, clip: clip, id: id)
        if next == desired { return }
        let others = Self.retained.values.filter { $0 !== self }
        let bytes = others.reduce(0) { $0 + ($1.desired?.clip.data.count ?? 0) + ($1.attempt?.clip.data.count ?? 0) }
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
                       let copy = try? AudioCommentSavedDraft(owner: owner, target: target, caption: latest.caption, clip: latest.clip) {
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
    static func retryRetained(owner: AudioCommentOwner, target: AudioCommentTarget) async -> Bool {
        let matches = retained.values.filter { $0.owner == owner && $0.target == target }
        var success = true
        for writer in matches { if !(await writer.flush(retry: true)) { success = false } }
        return success
    }
}
