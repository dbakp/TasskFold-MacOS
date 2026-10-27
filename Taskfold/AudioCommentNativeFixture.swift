#if DEBUG
import SwiftUI
import AVFoundation
import Observation

@MainActor enum AudioCommentNativeFixture {
    static var enabled: Bool { TeamEditorNativeFixture.enabled && ProcessInfo.processInfo.arguments.contains("--audio-comment-testing") }
    static var root: URL { URL.applicationSupportDirectory.appendingPathComponent("TaskfoldAudioNative", isDirectory: true) }
    static func storage(_ scope: AudioCommentLiveScope) -> AudioCommentDraftStorage {
        let fail = enabled && ProcessInfo.processInfo.arguments.contains("--audio-save-lost-ack")
        return .init(vault: .init(applicationSupport: root, owner: try! .init(scope.workspace.account), fault: { point in
            if fail && point == .afterDraftCommit { throw AudioCommentStorageFailure.unreadable }
        }))
    }
    static func prepare() throws {
        guard enabled else { throw CancellationError() }
        if ProcessInfo.processInfo.arguments.contains("--audio-comment-reset") { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
@MainActor @Observable private final class AudioCommentFixtureContext {
    var scope = AudioCommentLiveScope(workspace: .init(account: "local-audio-native", generation: UUID()), target: try! .init(task: UUID(uuidString: "ac270000-0000-4000-8000-000000000001")!, generation: UUID(uuidString: "ac270000-0000-4000-8000-000000000002")!, project: nil))
    var request: AudioCommentDraftRequest { .init(scope: scope, title: "Keep the design review in your own words") }
}
struct AudioCommentNativeFixtureView: View {
    @State private var context = AudioCommentFixtureContext()
    @State private var opening: AudioCommentDraftRequest?
    @State private var ready = false
    @State private var problem: String?
    var body: some View {
        VStack(spacing: 20) {
            Text("Audio draft workshop").font(.title)
            Text("Synthetic recording and silent playback; no microphone access.").foregroundStyle(.secondary)
            Button("Open audio draft") { opening = context.request }.disabled(!ready).accessibilityIdentifier("audioFixtureOpen")
            Button("Change workspace") { context.scope = .init(workspace: .init(account: "other-audio-workspace", generation: UUID()), target: context.scope.target) }.accessibilityIdentifier("audioFixtureSwitch")
            if let problem { Text(problem).accessibilityIdentifier("audioFixtureError") }
        }.padding(24)
        .task { do { try AudioCommentNativeFixture.prepare(); ready = true } catch { problem = error.localizedDescription } }
        .sheet(item: $opening) { request in
            AudioCommentDraftView(request: request,
                                  storage: AudioCommentNativeFixture.storage(request.scope),
                                  recorder: AudioCommentFixtureRecording(), player: AudioCommentFixturePlaying(), liveScope: { context.scope })
        }
    }
}
@MainActor private final class AudioCommentFixtureRecording: AudioCommentRecording {
    private var token: UUID?
    private var started: Date?
    private var current: (@MainActor () -> Bool)?
    private var receive: (@MainActor (AudioCommentRecordingEvent) -> Void)?
    private var finishing: Task<Void, Never>?
    var elapsed: TimeInterval { started.map { min(120, max(0, Date().timeIntervalSince($0))) } ?? 0 }
    func start(isCurrent: @escaping @MainActor () -> Bool, receive: @escaping @MainActor (AudioCommentRecordingEvent) -> Void) async throws {
        guard AudioCommentNativeFixture.enabled, isCurrent() else { throw CancellationError() }
        if ProcessInfo.processInfo.arguments.contains("--audio-comment-denied") { throw AudioCommentFailure(message: "Microphone access is off. This is a synthetic refusal; your saved draft is unchanged.") }
        let token = UUID(); self.token = token; current = isCurrent; self.receive = receive
        try await Task.sleep(for: .milliseconds(150))
        guard self.token == token, !Task.isCancelled, isCurrent() else { throw CancellationError() }
        started = Date(); receive(.started)
    }
    func finish() {
        guard let token else { return }
        finishing = Task { [weak self] in
            do {
                let data = try await Task.detached(priority: .utility) {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-audio-native-tone-" + UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); defer { try? FileManager.default.removeItem(at: folder) }
                    let url = folder.appendingPathComponent("tone.m4a")
                    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!; buffer.frameLength = 44100
                    for index in 0..<44100 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 44100) * 0.04) }
                    do { let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000]); try file.write(from: buffer) }
                    return try Data(contentsOf: url)
                }.value
                guard let self, self.token == token, self.current?() == true, !Task.isCancelled else { return }
                self.receive?(.finished(data))
            } catch { guard let self, self.token == token else { return }; self.receive?(.failed("Synthetic recording unavailable.")) }
        }
    }
    func cancel() { token = nil; current = nil; receive = nil; started = nil; finishing?.cancel(); finishing = nil }
}
@MainActor private final class AudioCommentFixturePlaying: AudioCommentPlaying {
    private var task: Task<Void, Never>?
    func play(_ clip: AudioCommentClip, isCurrent: @escaping @MainActor () -> Bool, ended: @escaping @MainActor () -> Void) throws {
        guard AudioCommentNativeFixture.enabled, isCurrent() else { throw CancellationError() }
        stop(); task = Task { do { try await Task.sleep(for: .seconds(2)) } catch { return }; if isCurrent() { ended() } }
    }
    func stop() { task?.cancel(); task = nil }
}
#endif
