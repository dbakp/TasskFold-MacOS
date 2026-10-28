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
final class AudioProofOneShotFault: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Bool
    private var writes = 0
    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return writes }
    private let point: AudioCommentVault.Checkpoint
    init(enabled: Bool = true, point: AudioCommentVault.Checkpoint = .afterRename) { remaining = enabled; self.point = point }
    func arm() { lock.lock(); remaining = true; lock.unlock() }
    func check(_ point: AudioCommentVault.Checkpoint) throws {
        guard point == self.point else { return }
        lock.lock(); writes += 1; let fail = remaining; remaining = false; lock.unlock()
        if fail { throw AudioCommentStorageFailure.unreadable }
    }
}
final class AudioProofSaveGate: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var reached = false
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return reached }
    func check(_ point: AudioCommentVault.Checkpoint) throws {
        guard point == .afterSaveJournal else { return }
        lock.lock(); reached = true; lock.unlock()
        guard semaphore.wait(timeout: .now() + 3) == .success else { throw AudioCommentStorageFailure.unreadable }
    }
    func release() { semaphore.signal() }
}

/// Holds a real second file-description lock between failed commit and state read.
final class AudioProofLookupLock: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let interrupt: AudioCommentVault.Checkpoint
    private let owner: AudioCommentOwner
    private var enabled: Bool
    private var saves: [AudioCommentSaveIntent] = []
    private var interrupted = false, released = false
    private var fd: Int32 = -1
    init(directory: URL, owner: AudioCommentOwner, interrupt: AudioCommentVault.Checkpoint, enabled: Bool = true) { self.directory = directory; self.owner = owner; self.interrupt = interrupt; self.enabled = enabled }
    var observedSaves: [AudioCommentSaveIntent] { lock.lock(); defer { lock.unlock() }; return saves }
    func armLookupOnly() { lock.lock(); enabled = true; interrupted = true; lock.unlock() }
    var isHolding: Bool { lock.lock(); defer { lock.unlock() }; return fd >= 0 }
    func check(_ point: AudioCommentVault.Checkpoint) throws {
        lock.lock(); defer { lock.unlock() }
        if point == .beforeRename {
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasPrefix(".write-") {
                if let data = try? Data(contentsOf: file), let intent = try? AudioCommentSaveIntent(encoded: data, owner: owner) { saves.append(intent) }
            }
        }
        guard enabled else { return }
        if point == interrupt, !interrupted { interrupted = true; throw AudioCommentStorageFailure.unreadable }
        if point == .beforeSaveState, interrupted, !released, fd < 0 {
            let next = Darwin.open(directory.appendingPathComponent(".lock").path, O_RDWR | O_NOFOLLOW)
            guard next >= 0 else { throw AudioCommentStorageFailure.unreadable }
            guard flock(next, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(next); throw AudioCommentStorageFailure.unreadable }
            fd = next
        }
    }
    func release() {
        lock.lock(); defer { lock.unlock() }; released = true
        if fd >= 0 { _ = flock(fd, LOCK_UN); Darwin.close(fd); fd = -1 }
    }
    deinit { if fd >= 0 { _ = flock(fd, LOCK_UN); Darwin.close(fd) } }
}

final class PrejournalGate: @unchecked Sendable {
    private let lock = NSLock()
    let directory: URL; let owner: AudioCommentOwner
    private var interrupted = false, released = false
    private var fd: Int32 = -1
    init(_ directory: URL, _ owner: AudioCommentOwner) { self.directory = directory; self.owner = owner }
    func check(_ point: AudioCommentVault.Checkpoint) throws {
        lock.lock(); defer { lock.unlock() }
        if point == .beforeRename, !interrupted {
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasPrefix(".write-") {
                if let data = try? Data(contentsOf: file), (try? AudioCommentSaveIntent(encoded: data, owner: owner)) != nil { interrupted = true; throw AudioCommentStorageFailure.unreadable }
            }
        }
        if point == .beforeSaveState, interrupted, !released, fd < 0 {
            fd = Darwin.open(directory.appendingPathComponent(".lock").path, O_RDWR | O_NOFOLLOW)
            guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AudioCommentStorageFailure.unreadable }
        }
    }
    func release() { lock.lock(); defer { lock.unlock() }; released = true; if fd >= 0 { _ = flock(fd, LOCK_UN); Darwin.close(fd); fd = -1 } }
}
@main struct PrejournalProof {
    @MainActor static func wait(_ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let owner = try AudioCommentOwner("local-prejournal-proof")
        let target = try AudioCommentTarget(task: UUID(), generation: UUID(), project: nil)
        let scope = AudioCommentLiveScope(workspace: .init(account: owner.account, generation: UUID()), target: target)
        let context = AudioProofContext(scope), request = AudioCommentDraftRequest(scope: scope, title: "Synthetic pre-journal review")
        let vault = AudioCommentVault(applicationSupport: root, owner: owner)
        _ = try vault.drafts()
        let gate = PrejournalGate(vault.directory, owner)
        let disk = AudioCommentDraftStorage(vault: .init(applicationSupport: root, owner: owner, fault: { try gate.check($0) }))
        let initial = Darwin.open(vault.directory.appendingPathComponent(".lock").path, O_RDWR | O_NOFOLLOW)
        guard initial >= 0, flock(initial, LOCK_EX | LOCK_NB) == 0 else { throw AudioCommentStorageFailure.unreadable }
        let review = AudioCommentCapture(request: request, recorder: AudioProofRecorder(data), player: AudioProofPlayer(), storage: disk)
        review.currentScope = { context.scope }; review.start(); await wait { review.session.phase == .recording }; review.stop(); await wait { review.session.phase == .review && review.recovery.failure != nil }
        review.editCaption("Keep this not-yet-journaled review")
        _ = flock(initial, LOCK_UN); Darwin.close(initial)
        let result = await review.save(), frozen = review.saveUnconfirmed
        let journals = try FileManager.default.contentsOfDirectory(at: vault.directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("save-") }.count
        context.scope = .init(workspace: .init(account: "other-owner", generation: UUID()), target: target); review.contextChanged(); gate.release()
        context.scope = scope
        let fresh = AudioCommentCapture(request: request, recorder: AudioProofRecorder(data), player: AudioProofPlayer(), storage: disk); fresh.currentScope = { context.scope }
        await fresh.refresh(); await fresh.refresh()
        let readable = try await disk.drafts().isEmpty
        let recovered = !fresh.recoverable.isEmpty
        let facts: [String: Any] = ["saveReturned": result, "initialOutcomeUnconfirmed": frozen, "journalCount": journals, "storageReadableAfterRelease": readable, "returningRecoveryCount": fresh.recoverable.count, "returningRetryWarning": fresh.retainedRecoveryFailed, "manualRecoveryRetry": await review.preserveReview(), "expectedRecoverableReview": true, "observedRecoverableReview": recovered]
        try JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
        print(String(decoding: try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]), as: UTF8.self))
        fresh.close()
        if !recovered { exit(1) }
    }
}
