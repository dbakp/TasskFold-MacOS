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
    init(request: AudioCommentDraftRequest, recorder: any AudioCommentRecording, player: any AudioCommentPlaying, storage: AudioCommentDraftStorage) {
        self.request = request; self.recorder = recorder; self.player = player; self.storage = storage
        session = .init(workspace: request.scope.workspace, target: request.scope.target)
    }
    var isCurrent: Bool { currentScope().map(request.scope.matches) == true && session.phase != .closed }
    var recordingBusy: Bool { [.authorizing, .recording, .finishing].contains(session.phase) }
    var busy: Bool { recordingBusy || loading || saving }
    var editable: Bool { isCurrent && !busy && !saveUnconfirmed }
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
        do { try session.editCaption(text); notice = nil } catch { notice = error.localizedDescription }
    }
    func refresh() async {
        guard isCurrent, !busy else { return }; loading = true; defer { loading = false }
        do {
            let drafts = try await storage.drafts()
            guard isCurrent else { close(); return }
            available = drafts.filter { $0.target == request.scope.target }
        } catch { if isCurrent { notice = error.localizedDescription } else { close() } }
    }
    func restore(_ draft: AudioCommentSavedDraft) async {
        guard editable, !needsSave, draft.target == request.scope.target, draft.owner.account.utf8.elementsEqual(request.scope.workspace.account.utf8) else { return }
        stopPlayback(); loading = true; defer { loading = false }
        do {
            let clip = try await AudioCommentDecoding.validate(draft.clip.data)
            guard isCurrent else { close(); return }
            try session.restore(clip, caption: draft.caption, workspace: request.scope.workspace, target: request.scope.target)
            saved = draft; candidate = nil; elapsed = Double(clip.descriptor.milliseconds) / 1000; notice = "Saved on this device."
        } catch { if isCurrent { notice = error.localizedDescription } else { close() } }
    }
    @discardableResult func save() async -> Bool {
        guard isCurrent, !busy, let clip = session.clip, session.phase == .review else { return false }
        stopPlayback(); saving = true; defer { saving = false }
        do {
            let next: AudioCommentSavedDraft
            if let candidate { next = candidate }
            else if let saved { next = try saved.replacing(caption: session.caption, clip: clip); candidate = next }
            else { next = try .init(owner: .init(request.scope.workspace.account), target: request.scope.target, caption: session.caption, clip: clip); candidate = next }
            try await storage.save(next, replacing: saved?.revision)
            guard isCurrent else { close(); return false }
            saved = next; candidate = nil; saveUnconfirmed = false
            available.removeAll { $0.id == next.id }; available.insert(next, at: 0)
            notice = "Saved on this device."; return true
        } catch {
            guard isCurrent else { close(); return false }
            saveUnconfirmed = true; notice = "The save couldn’t be confirmed. Retry save before editing or closing; your recording is still here."; return false
        }
    }
    @discardableResult func deleteSaved() async -> Bool {
        guard isCurrent, !busy, !saveUnconfirmed, let saved else { return false }
        stopPlayback(); saving = true; defer { saving = false }
        do {
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
        session.close(); saved = nil; candidate = nil; available = []; notice = nil; elapsed = 0; saveUnconfirmed = false
        currentScope = { nil }
    }
}
