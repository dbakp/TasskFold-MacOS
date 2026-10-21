import Foundation

@MainActor final class CurrentWorkspace { var value: WorkspaceBinding; init(_ value: WorkspaceBinding) { self.value = value } }
@MainActor final class FakeRecording: VoiceRecording {
    var callbacks: [@MainActor (VoiceRecordingEvent) -> Void] = []
    var permits: [@MainActor () -> Bool] = []
    var cancelCount = 0, finishCount = 0
    var suspended = false, denied = false
    var permission: CheckedContinuation<Void, Never>?
    func start(locale: String, isCurrent: @escaping @MainActor () -> Bool, receive: @escaping @MainActor (VoiceRecordingEvent) -> Void) async throws {
        callbacks.append(receive); permits.append(isCurrent)
        if suspended { await withCheckedContinuation { permission = $0 } }
        if denied { throw VoiceRecordingFailure(message: "Permission refused in synthetic driver") }
        receive(.started)
    }
    func finish() { finishCount += 1 }
    func cancel() { cancelCount += 1 }
    func grant() { let continuation = permission; permission = nil; continuation?.resume() }
}
@main struct ControllerProof {
    @MainActor static func settle() async { for _ in 0..<10 { await Task.yield() } }
    @MainActor static func wait(_ predicate: () -> Bool, seconds: Double = 1) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return predicate()
    }
    @MainActor static func main() async throws {
        var checks: [String: Bool] = [:]
        let binding = WorkspaceBinding(account: "a", generation: UUID()), current = CurrentWorkspace(WorkspaceBinding(account: "a", generation: UUID()))
        current.value = binding
        func make(_ driver: FakeRecording) -> VoiceCapture {
            let c = VoiceCapture(request: VoiceDraftRequest(workspace: binding, original: "Original"), driver: driver)
            c.currentWorkspace = { current.value }; return c
        }
        let unavailable = FakeRecording(), noBinding = VoiceCapture(request: VoiceDraftRequest(workspace: binding, original: ""), driver: unavailable)
        noBinding.start(locale: "en-US"); await settle()
        checks["unboundPresentationCannotStart"] = unavailable.callbacks.isEmpty && noBinding.session.phase == .ready
        noBinding.close()

        let pending = FakeRecording(); pending.suspended = true
        let c = make(pending); c.edit("Keep correction"); c.start(locale: "en-US")
        _ = await wait { pending.permission != nil }
        checks["permissionPendingCannotApplyOrOverwrite"] = c.session.phase == .authorizing && c.session.busy && c.session.text == "Keep correction"
        c.stop(); pending.grant(); await settle()
        checks["latePermissionGrantCannotStartCancelledDraft"] = c.session.phase == .review && c.session.text == "Keep correction" && pending.permits.first?() == false
        c.close()

        let denied = FakeRecording(); denied.denied = true
        let d = make(denied); d.edit("Typed transcript"); d.start(locale: "en-US")
        _ = await wait { d.session.phase == .review }
        checks["permissionFailurePreservesEditableText"] = d.session.text == "Typed transcript" && d.notice != nil && !d.session.busy
        d.edit("Corrected after refusal"); checks["typingRemainsAvailableAfterFailure"] = d.session.text == "Corrected after refusal"; d.close()

        let live = FakeRecording(), e = make(FakeRecording())
        e.close()
        let r = make(live); r.start(locale: "en-US"); _ = await wait { r.session.phase == .recording }
        live.callbacks[0](.result("First", final: false)); live.callbacks[0](.result("First task", final: true))
        checks["finalResultStopsInputAndAllowsReview"] = r.session.phase == .review && r.session.text == "First task" && live.cancelCount > 0
        r.start(locale: "en-US"); _ = await wait { live.callbacks.count == 2 }
        live.callbacks[0](.result("Old overwrite", final: true)); live.callbacks[1](.result("Second task", final: false))
        checks["supersededCallbackCannotRetargetNewRecording"] = r.session.text == "First task\nSecond task" && r.session.phase == .recording
        r.stop(); checks["stopEndsAudioBeforeFinalization"] = live.finishCount == 1 && r.session.phase == .finishing
        live.callbacks[1](.result("Second task corrected", final: true))
        checks["finalCorrectionAcceptedBeforeReview"] = r.session.text == "First task\nSecond task corrected" && r.session.phase == .review
        r.edit("Manual correction"); live.callbacks[1](.result("Late correction", final: true))
        checks["lateResultCannotOverwriteManualCorrection"] = r.session.text == "Manual correction"
        r.start(locale: "en-US"); _ = await wait { live.callbacks.count == 3 }
        live.callbacks[2](.result("Retained partial", final: false)); current.value = WorkspaceBinding(account: "b", generation: UUID())
        checks["providerContextGuardChangesImmediately"] = live.permits[2]() == false
        live.callbacks[2](.result("Wrong account words", final: true))
        checks["accountChangeClosesAndReleasesRecorder"] = r.session.phase == .closed && !r.session.text.contains("Wrong account") && live.cancelCount > 1
        r.close(); current.value = binding

        let timeout = FakeRecording(), t = make(timeout); t.start(locale: "en-US"); _ = await wait { t.session.phase == .recording }
        timeout.callbacks[0](.result("Keep the partial", final: false)); t.stop()
        checks["finalizationTimeoutKeepsPartial"] = await wait({ t.session.phase == .review }, seconds: 3) && t.session.text == "Keep the partial"
        t.close()
        let over = FakeRecording(), o = make(over); o.edit("Keep bounded text"); o.start(locale: "en-US"); _ = await wait { o.session.phase == .recording }
        over.callbacks[0](.result(String(repeating: "x", count: 100_001), final: false))
        checks["oversizeEventStopsWithoutLosingEarlierText"] = o.session.phase == .review && o.session.text == "Keep bounded text" && o.notice != nil
        o.close()
        let real = DeviceVoiceRecording(); var rejected = false
        do { try await real.start(locale: "en-US", isCurrent: { false }, receive: { _ in }) } catch is CancellationError { rejected = true }
        checks["realDriverRejectsStaleContextBeforePermissions"] = rejected; real.cancel()

        var cyclic: VoiceCapture? = make(FakeRecording())
        weak var released = cyclic
        cyclic!.currentWorkspace = { [captured = cyclic!] in captured.session.workspace }
        cyclic!.close(); cyclic = nil; await settle()
        checks["closeReleasesContextClosureAndController"] = released == nil
        let limited = FakeRecording(), limit = make(limited); limit.start(locale: "en-US"); _ = await wait { limit.session.phase == .recording }
        limited.callbacks[0](.result("Timed transcript", final: false))
        checks["oneMinuteLimitStopsInputAndKeepsDraft"] = await wait({ limit.session.phase == .review }, seconds: 64) && limited.finishCount == 1 && limit.session.text == "Timed transcript"
        limit.close()
        try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        if checks.count != 17 || !checks.values.allSatisfy({ $0 }) { print(checks); exit(1) }
    }
}
