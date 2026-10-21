import Foundation
import Observation
import Speech
import AVFoundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum VoiceRecordingEvent: Sendable { case started, result(String, final: Bool), failed(String) }
struct VoiceRecordingFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
@MainActor protocol VoiceRecording: AnyObject {
    func start(locale: String, isCurrent: @escaping @MainActor () -> Bool, receive: @escaping @MainActor (VoiceRecordingEvent) -> Void) async throws
    func finish()
    func cancel()
}

@MainActor private enum VoiceRecordingLease {
    static var owner: UUID?
    static func claim(_ id: UUID) -> Bool { guard owner == nil || owner == id else { return false }; owner = id; return true }
    static func release(_ id: UUID) { if owner == id { owner = nil } }
}

/// Serializes the tap's final append against endAudio. No audio buffer is retained by Taskfold.
private final class VoiceAudioSink: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest
    private let lock = NSLock()
    private var open = true
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) { lock.lock(); defer { lock.unlock() }; if open { request.append(buffer) } }
    func close() { lock.lock(); defer { lock.unlock() }; if open { open = false; request.endAudio() } }
}

@MainActor final class DeviceVoiceRecording: VoiceRecording {
    private let owner = UUID()
    private var attempt: UUID?
    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var recognition: SFSpeechRecognitionTask?
    private var sink: VoiceAudioSink?
    private var tapped = false
    private var capturing = false
    private var observers: [NSObjectProtocol] = []
    #if os(iOS)
    private var audioState: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    #endif
    func start(locale: String, isCurrent: @escaping @MainActor () -> Bool, receive: @escaping @MainActor (VoiceRecordingEvent) -> Void) async throws {
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        cancel()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.supportsOnDeviceRecognition else {
            throw VoiceRecordingFailure(message: "On-device dictation isn’t available for this language on this device. You can keep typing instead.")
        }
        guard VoiceRecordingLease.claim(owner) else { throw VoiceRecordingFailure(message: "Finish the other Taskfold recording first.") }
        let token = UUID(); attempt = token
        do {
            let speech = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
            try check(token, isCurrent: isCurrent)
            guard speech == .authorized else { throw VoiceRecordingFailure(message: "Speech recognition access is off. You can enable it in system settings or keep typing.") }
            let microphone = await AVCaptureDevice.requestAccess(for: .audio)
            try check(token, isCurrent: isCurrent)
            guard microphone else { throw VoiceRecordingFailure(message: "Microphone access is off. You can enable it in system settings or keep typing.") }
            // Allow the permission sheet to leave the foreground before checking app activity.
            try await Task.sleep(for: .milliseconds(100)); try check(token, isCurrent: isCurrent)
            #if os(iOS)
            guard UIApplication.shared.applicationState == .active else { throw CancellationError() }
            let audio = AVAudioSession.sharedInstance()
            audioState = (audio.category, audio.mode, audio.categoryOptions)
            try audio.setCategory(.record, mode: .measurement, options: [])
            try audio.setActive(true)
            #else
            guard NSApp.isActive else { throw CancellationError() }
            #endif
            guard recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { throw VoiceRecordingFailure(message: "On-device dictation is unavailable right now. Your draft is unchanged.") }
            let engine = AVAudioEngine(), request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            let sink = VoiceAudioSink(request), input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceRecordingFailure(message: "No microphone is available. Your draft is unchanged.") }
            self.engine = engine; self.sink = sink; self.recognizer = recognizer
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in sink.append(buffer) }; tapped = true
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString, final = result?.isFinal ?? false
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard let self, self.attempt == token else { return }
                    guard isCurrent() else { self.cancel(); return }
                    if let text { receive(.result(text, final: final)) }
                    if failed { receive(.failed("Dictation stopped. Your transcript is still here; you can edit it or try again.")) }
                }
            }
            engine.prepare(); try engine.start(); capturing = true
            observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor in if self?.attempt == token && self?.capturing == true { receive(.failed("The audio input changed. Your transcript is still here.")) } }
            })
            #if os(iOS)
            observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in if self?.attempt == token && self?.capturing == true { receive(.failed("Recording was interrupted. Your transcript is still here.")) } }
            })
            #endif
            receive(.started)
        } catch {
            if attempt == token { cancel() }
            throw error
        }
    }
    private func check(_ token: UUID, isCurrent: @MainActor () -> Bool) throws { guard attempt == token, !Task.isCancelled, isCurrent() else { throw CancellationError() } }
    private func stopInput() {
        capturing = false
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        if tapped, let engine { engine.inputNode.removeTap(onBus: 0) }; tapped = false
        sink?.close(); sink = nil
        engine?.stop(); engine = nil
        #if os(iOS)
        if let state = audioState {
            audioState = nil
            let audio = AVAudioSession.sharedInstance()
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            try? audio.setCategory(state.0, mode: state.1, options: state.2)
        }
        #endif
    }
    func finish() { stopInput() }
    func cancel() {
        attempt = nil
        stopInput(); recognition?.cancel(); recognition = nil; recognizer = nil
        VoiceRecordingLease.release(owner)
    }
}

@MainActor @Observable final class VoiceCapture {
    private(set) var session: VoiceDraftSession
    var notice: String?
    @ObservationIgnored var currentWorkspace: () -> WorkspaceBinding = { WorkspaceBinding(account: "", generation: UUID()) }
    @ObservationIgnored private let driver: any VoiceRecording
    @ObservationIgnored private var starting: Task<Void, Never>?
    @ObservationIgnored private var duration: Task<Void, Never>?
    @ObservationIgnored private var finishing: Task<Void, Never>?
    init(request: VoiceDraftRequest, driver: any VoiceRecording) { session = VoiceDraftSession(request: request); self.driver = driver }
    func start(locale: String) {
        let current = currentWorkspace()
        guard let token = session.begin(account: current.account, generation: current.generation) else { return }
        notice = nil
        starting = Task { [weak self, driver] in
            do { try await driver.start(locale: locale, isCurrent: { [weak self] in
                guard let self else { return false }; let current = self.currentWorkspace()
                return self.session.accepts(token, account: current.account, generation: current.generation)
            }) { [weak self] event in self?.receive(event, token: token) } }
            catch is CancellationError { self?.fail("Recording cancelled. Your draft is still here.", token: token) }
            catch { self?.fail((error as? VoiceRecordingFailure)?.message ?? "Recording couldn’t start. You can keep editing this draft.", token: token) }
        }
    }
    private func receive(_ event: VoiceRecordingEvent, token: UUID) {
        let current = currentWorkspace()
        guard session.token == token else { return }
        guard session.workspace.matches(account: current.account, generation: current.generation) else { close(); return }
        guard session.accepts(token, account: current.account, generation: current.generation) else { return }
        switch event {
        case .started:
            guard session.phase == .authorizing else { return }
            session.started(token, account: current.account, generation: current.generation)
            duration?.cancel(); duration = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard self?.session.token == token else { return }; self?.stop()
            }
        case .result(let text, let final):
            do { _ = try session.receive(text, token: token, account: current.account, generation: current.generation) }
            catch { fail("The transcript reached the draft limit. Your earlier text is still here.", token: token); return }
            if final { review() }
        case .failed(let message): fail(message, token: token)
        }
    }
    private func fail(_ message: String, token: UUID) {
        let current = currentWorkspace()
        guard session.accepts(token, account: current.account, generation: current.generation) else { return }
        review(); notice = message
    }
    func stop() {
        if session.phase == .authorizing { review(); return }
        guard session.phase == .recording else { return }
        duration?.cancel(); session.finishing(); driver.finish()
        let token = session.token
        finishing = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled, self?.session.token == token, self?.session.phase == .finishing else { return }
            self?.review()
        }
    }
    private func review() {
        starting?.cancel(); duration?.cancel(); finishing?.cancel()
        driver.cancel(); session.stop()
    }
    func edit(_ text: String) {
        do { try session.edit(text); notice = nil }
        catch { notice = error.localizedDescription }
    }
    func close() {
        starting?.cancel(); duration?.cancel(); finishing?.cancel(); driver.cancel(); session.close()
        currentWorkspace = { WorkspaceBinding(account: "", generation: UUID()) }
    }
}

@MainActor enum VoiceRecordingFactory {
    static func make(workspace: WorkspaceBinding) -> any VoiceRecording {
        #if DEBUG
        let bundles = ["com.dbakp.taskfold.workflowtestsp1", "com.dbakp.taskfold.mac.workflowtestsnotes1"]
        let args = ProcessInfo.processInfo.arguments
        if workspace.account == "ui-testing", bundles.contains(Bundle.main.bundleIdentifier ?? ""), args.contains("--uitesting"), args.contains("--voice-fixture") {
            return FixtureVoiceRecording(denied: args.contains("--voice-denial-fixture"))
        }
        #endif
        return DeviceVoiceRecording()
    }
}
#if DEBUG
/// Exact isolated account/bundles only. Does not request permission or open a microphone.
@MainActor private final class FixtureVoiceRecording: VoiceRecording {
    let denied: Bool
    private var task: Task<Void, Never>?
    init(denied: Bool) { self.denied = denied }
    func start(locale: String, isCurrent: @escaping @MainActor () -> Bool, receive: @escaping @MainActor (VoiceRecordingEvent) -> Void) async throws {
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        if denied { throw VoiceRecordingFailure(message: "Microphone access is off. You can enable it in system settings or keep typing.") }
        receive(.started)
        task = Task {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            receive(.result("Review the", final: false))
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            receive(.result("Review the layout tomorrow p2\nSend the design notes", final: true))
        }
    }
    func finish() { }
    func cancel() { task?.cancel(); task = nil }
}
#endif
