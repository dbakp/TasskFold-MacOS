import Foundation
import AVFoundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif
#if AUDIO_COMMENT_CONTROLLER_TESTING
@testable import TaskfoldCore
#endif

enum AudioCommentRecordingEvent: Sendable { case started, finished(Data), failed(String) }
@MainActor protocol AudioCommentRecording: AnyObject {
    var elapsed: TimeInterval { get }
    func start(isCurrent: @escaping @MainActor () -> Bool, receive: @escaping @MainActor (AudioCommentRecordingEvent) -> Void) async throws
    func finish()
    func cancel()
}
@MainActor protocol AudioCommentPlaying: AnyObject {
    func play(_ clip: AudioCommentClip, isCurrent: @escaping @MainActor () -> Bool, ended: @escaping @MainActor () -> Void) throws
    func stop()
}

@MainActor private final class AudioCommentSession {
    private let owner = UUID()
    #if os(iOS)
    private var previous: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    #endif
    func claim() throws {
        guard TaskfoldAudioLease.claim(owner) else { throw AudioCommentFailure(message: "Finish the other Taskfold recording or playback first.") }
    }
    func activate(recording: Bool) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        previous = (session.category, session.mode, session.categoryOptions)
        try session.setCategory(recording ? .record : .playback, mode: .default, options: [])
        try session.setActive(true)
        #endif
    }
    func release() {
        #if os(iOS)
        if let previous {
            self.previous = nil
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(previous.0, mode: previous.1, options: previous.2)
        }
        #endif
        TaskfoldAudioLease.release(owner)
    }
}

@MainActor final class DeviceAudioCommentRecording: NSObject, AudioCommentRecording, AVAudioRecorderDelegate {
    private let audio = AudioCommentSession()
    private var recorder: AVAudioRecorder?
    private var directory: URL?
    private var attempt: UUID?
    private var receive: (@MainActor (AudioCommentRecordingEvent) -> Void)?
    private var current: (@MainActor () -> Bool)?
    private var observers: [NSObjectProtocol] = []
    private var reading: Task<Void, Never>?
    var elapsed: TimeInterval { recorder?.currentTime ?? 0 }
    func start(isCurrent: @escaping @MainActor () -> Bool, receive: @escaping @MainActor (AudioCommentRecordingEvent) -> Void) async throws {
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        cancel(); try audio.claim()
        let token = UUID(); attempt = token; self.current = isCurrent; self.receive = receive
        do {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            try check(token)
            guard allowed else { throw AudioCommentFailure(message: "Microphone access is off. Enable it in system settings to record; your saved draft is unchanged.") }
            try await Task.sleep(for: .milliseconds(100)); try check(token)
            #if os(iOS)
            guard UIApplication.shared.applicationState == .active else { throw CancellationError() }
            #else
            guard NSApp.isActive else { throw CancellationError() }
            #endif
            try audio.activate(recording: true)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-audio-recording-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); directory = folder
            let url = folder.appendingPathComponent("recording.m4a")
            let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
            self.recorder = recorder; recorder.delegate = self
            guard recorder.record(forDuration: 120) else { throw AudioCommentFailure(message: "Recording couldn’t start. Your saved draft is unchanged.") }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification, AVAudioSession.routeChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.finish() } })
            }
            #endif
            receive(.started)
        } catch { if attempt == token { cancel() }; throw error }
    }
    private func check(_ token: UUID) throws { guard attempt == token, current?() == true, !Task.isCancelled else { throw CancellationError() } }
    func finish() {
        guard let recorder, let directory, let token = attempt else { return }
        let url = recorder.url
        recorder.delegate = nil; recorder.stop(); self.recorder = nil; self.directory = nil
        releaseAudio()
        reading = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { () throws -> Data in
                defer { try? FileManager.default.removeItem(at: directory) }
                try Task.checkCancellation()
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                let data = try handle.read(upToCount: AudioCommentDescriptor.maximumBytes + 1) ?? Data()
                guard !data.isEmpty, data.count <= AudioCommentDescriptor.maximumBytes else { throw AudioCommentFailure.invalid }
                try Task.checkCancellation(); return data
            }
            do {
                let data = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self else { return }; try self.check(token)
                let callback = self.receive; self.attempt = nil; self.receive = nil; self.current = nil
                callback?(.finished(data))
            } catch {
                guard let self, self.attempt == token else { return }
                let callback = self.receive, valid = self.current?() == true
                self.cancel(); if valid { callback?(.failed("Recording couldn’t finish. Your previous draft is still here.")) }
            }
        }
    }
    func cancel() {
        attempt = nil; reading?.cancel(); reading = nil; receive = nil; current = nil
        recorder?.delegate = nil; recorder?.stop(); recorder = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }; directory = nil
        releaseAudio()
    }
    private func releaseAudio() { observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll(); audio.release() }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, self.recorder.map(ObjectIdentifier.init) == identity else { return }
            if flag { self.finish() }
            else { let callback = self.receive, valid = self.current?() == true; self.cancel(); if valid { callback?(.failed("Recording stopped unexpectedly. Your previous draft is still here.")) } }
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) { audioRecorderDidFinishRecording(recorder, successfully: false) }
}

@MainActor final class DeviceAudioCommentPlaying: NSObject, AudioCommentPlaying, AVAudioPlayerDelegate {
    private let audio = AudioCommentSession()
    private var player: AVAudioPlayer?
    private var ended: (@MainActor () -> Void)?
    private var observers: [NSObjectProtocol] = []
    func play(_ clip: AudioCommentClip, isCurrent: @escaping @MainActor () -> Bool, ended: @escaping @MainActor () -> Void) throws {
        guard isCurrent() else { throw CancellationError() }
        stop(); try audio.claim()
        do {
            try audio.activate(recording: false)
            let player = try AVAudioPlayer(data: clip.data, fileTypeHint: "com.apple.m4a-audio")
            self.player = player; self.ended = ended; player.delegate = self
            guard isCurrent(), player.play() else { throw AudioCommentFailure(message: "This recording couldn’t play. Your draft is still saved.") }
            #if os(iOS)
            for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification, AVAudioSession.routeChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.finishPlayback() } })
            }
            #endif
        } catch { stop(); throw error }
    }
    func stop() { player?.delegate = nil; player?.stop(); player = nil; ended = nil; observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll(); audio.release() }
    private func finishPlayback() { let callback = ended; stop(); callback?() }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in guard let self, self.player.map(ObjectIdentifier.init) == identity else { return }; self.finishPlayback() }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) { audioPlayerDidFinishPlaying(player, successfully: false) }
}
