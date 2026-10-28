#if DEBUG
import SwiftUI
import AVFoundation
import Observation
import Darwin

@MainActor enum AudioCommentNativeFixture {
    static var enabled: Bool { TeamEditorNativeFixture.enabled && ProcessInfo.processInfo.arguments.contains("--audio-comment-testing") }
    static var root: URL { URL.applicationSupportDirectory.appendingPathComponent("TaskfoldAudioNative", isDirectory: true) }
    private static var lookupLocks: [String: AudioCommentFixtureLookupLock] = [:]
    static var beforeJournalTesting: Bool { enabled && ProcessInfo.processInfo.arguments.contains("--audio-save-before-journal") }
    static func releaseCheckpoint(_ scope: AudioCommentLiveScope) {
        if let owner = try? AudioCommentOwner(scope.workspace.account) { lookupLocks[owner.directoryName]?.releaseCheckpoint() }
    }
    static var lookupTesting: Bool { enabled && ProcessInfo.processInfo.arguments.contains("--audio-save-lookup-lock") }
    static func lookupProbe(_ scope: AudioCommentLiveScope) -> String {
        let state = (try? AudioCommentOwner(scope.workspace.account)).flatMap { lookupLocks[$0.directoryName] }?.state ?? (0, false)
        return "Storage reads: \(state.0) · \(state.1 ? "locked" : "ready")"
    }
    static func resumeStorage(_ scope: AudioCommentLiveScope) {
        if let owner = try? AudioCommentOwner(scope.workspace.account) { lookupLocks[owner.directoryName]?.release() }
    }
    static func storage(_ scope: AudioCommentLiveScope) -> AudioCommentDraftStorage {
        let fail = enabled && ProcessInfo.processInfo.arguments.contains("--audio-save-lost-ack")
        let before = enabled && ProcessInfo.processInfo.arguments.contains("--audio-save-before-draft")
        let discard = enabled && ProcessInfo.processInfo.arguments.contains("--audio-discard-lost-ack")
        let owner = try! AudioCommentOwner(scope.workspace.account)
        let lookup: AudioCommentFixtureLookupLock?
        if lookupTesting {
            if lookupLocks[owner.directoryName] == nil {
                let vault = AudioCommentVault(applicationSupport: root, owner: owner)
                let prejournal = beforeJournalTesting && owner.account == "local-audio-native"
                if prejournal { _ = try? vault.drafts() }
                lookupLocks[owner.directoryName] = .init(directory: vault.directory, owner: owner, interrupt: before ? .afterSaveJournal : .afterDraftCommit, beforeJournal: prejournal)
            }
            lookup = lookupLocks[owner.directoryName]
        } else { lookup = nil }
        return .init(vault: .init(applicationSupport: root, owner: owner, fault: { point in
            try lookup?.check(point)
            if discard && point == .afterDiscardJournal { throw AudioCommentStorageFailure.unreadable }
            if fail && point == (before ? .afterSaveJournal : .afterDraftCommit) { throw AudioCommentStorageFailure.unreadable }
        }))
    }
    static func prepare() throws {
        guard enabled else { throw CancellationError() }
        for value in lookupLocks.values { value.release() }; lookupLocks.removeAll()
        if ProcessInfo.processInfo.arguments.contains("--audio-comment-reset") { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

/// Exact isolated-host contention, independent of the vault's own lock descriptor.
private final class AudioCommentFixtureLookupLock: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let interrupt: AudioCommentVault.Checkpoint
    private let owner: AudioCommentOwner
    private let beforeJournal: Bool
    private var interrupted = false, released = false
    private var fd: Int32 = -1
    private var lookups = 0
    init(directory: URL, owner: AudioCommentOwner, interrupt: AudioCommentVault.Checkpoint, beforeJournal: Bool = false) {
        self.directory = directory; self.owner = owner; self.interrupt = interrupt; self.beforeJournal = beforeJournal
        if beforeJournal {
            let next = Darwin.open(directory.appendingPathComponent(".lock").path, O_RDWR | O_NOFOLLOW)
            if next >= 0 {
                if flock(next, LOCK_EX | LOCK_NB) == 0 { fd = next } else { Darwin.close(next) }
            }
        }
    }
    var state: (Int, Bool) { lock.lock(); defer { lock.unlock() }; return (lookups, fd >= 0) }
    func check(_ point: AudioCommentVault.Checkpoint) throws {
        lock.lock(); defer { lock.unlock() }
        if beforeJournal, point == .beforeRename, !interrupted {
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasPrefix(".write-") {
                if let data = try? Data(contentsOf: file), (try? AudioCommentSaveIntent(encoded: data, owner: owner)) != nil { interrupted = true; throw AudioCommentStorageFailure.unreadable }
            }
        }
        if !beforeJournal, point == interrupt, !interrupted { interrupted = true; throw AudioCommentStorageFailure.unreadable }
        if point == .beforeSaveState {
            lookups += 1
            if interrupted, !released, fd < 0 {
                let next = Darwin.open(directory.appendingPathComponent(".lock").path, O_RDWR | O_NOFOLLOW)
                guard next >= 0 else { throw AudioCommentStorageFailure.unreadable }
                guard flock(next, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(next); throw AudioCommentStorageFailure.unreadable }
                fd = next
            }
        }
    }
    func releaseCheckpoint() {
        lock.lock(); defer { lock.unlock() }
        if beforeJournal, !interrupted, fd >= 0 { _ = flock(fd, LOCK_UN); Darwin.close(fd); fd = -1 }
    }
    func release() { lock.lock(); defer { lock.unlock() }; released = true; if fd >= 0 { _ = flock(fd, LOCK_UN); Darwin.close(fd); fd = -1 } }
    deinit { if fd >= 0 { _ = flock(fd, LOCK_UN); Darwin.close(fd) } }
}

@MainActor @Observable private final class AudioCommentFixtureContext {
    var scope = AudioCommentLiveScope(workspace: .init(account: "local-audio-native", generation: UUID()), target: try! .init(task: UUID(uuidString: "ac270000-0000-4000-8000-000000000001")!, generation: UUID(uuidString: "ac270000-0000-4000-8000-000000000002")!, project: nil))
    func leave() { scope = .init(workspace: .init(account: "other-audio-workspace", generation: UUID()), target: scope.target) }
    func returnToLocal() { scope = .init(workspace: .init(account: "local-audio-native", generation: UUID()), target: scope.target) }
    var request: AudioCommentDraftRequest { .init(scope: scope, title: "Keep the design review in your own words") }
}
struct AudioCommentNativeFixtureView: View {
    @State private var context = AudioCommentFixtureContext()
    @State private var opening: AudioCommentDraftRequest?
    @State private var ready = false
    @State private var storageResumed = false
    @State private var checkpointReleased = false
    @State private var problem: String?
    var body: some View {
        VStack(spacing: 20) {
            Text("Audio draft workshop").font(.title)
            Text("Synthetic recording and silent playback; no microphone access.").foregroundStyle(.secondary)
            Button("Open audio draft") { opening = context.request }.disabled(!ready).accessibilityIdentifier("audioFixtureOpen")
            Button("Change workspace") { context.leave() }.accessibilityIdentifier("audioFixtureSwitch")
            if AudioCommentNativeFixture.beforeJournalTesting {
                Button("Return to workspace") { context.returnToLocal() }.accessibilityIdentifier("audioFixtureReturn")
            }
            if let problem { Text(problem).accessibilityIdentifier("audioFixtureError") }
        }.padding(24)
        .task { do { try AudioCommentNativeFixture.prepare(); ready = true } catch { problem = error.localizedDescription } }
        .sheet(item: $opening) { request in
            VStack(spacing: 0) {
                AudioCommentDraftView(request: request,
                                  storage: AudioCommentNativeFixture.storage(request.scope),
                                  recorder: AudioCommentFixtureRecording(), player: AudioCommentFixturePlaying(), liveScope: { context.scope })
                if AudioCommentNativeFixture.lookupTesting {
                    VStack(spacing: 8) {
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in Text(AudioCommentNativeFixture.lookupProbe(request.scope)).font(.caption).accessibilityIdentifier("audioFixtureLookupProbe") }
                        if AudioCommentNativeFixture.beforeJournalTesting {
                            HStack {
                                Button("Release checkpoint lock") { AudioCommentNativeFixture.releaseCheckpoint(request.scope); checkpointReleased = true }
                                    .disabled(checkpointReleased || request.scope.workspace.account != "local-audio-native").accessibilityIdentifier("audioFixtureReleaseCheckpoint")
                                Button("Leave workspace") { context.leave() }.accessibilityIdentifier("audioFixtureLeave")
                            }.buttonStyle(.bordered)
                        }
                        Button("Resume storage") { AudioCommentNativeFixture.resumeStorage(request.scope); storageResumed = true }
                            .buttonStyle(.bordered).disabled(storageResumed).accessibilityIdentifier("audioFixtureResumeStorage")
                    }.padding().frame(maxWidth: .infinity).background(.bar)
                }
            }
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
