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
        let failing = try store("lost-save", fault: { if $0 == .afterRename { throw LostAcknowledgement() } })
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
