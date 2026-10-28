#if DEBUG
import SwiftUI
import AVFoundation
import Observation
import Darwin

@MainActor enum AudioCommentNativeFixture {
    static var ownerReviewTesting: Bool { TeamEditorNativeFixture.enabled && ProcessInfo.processInfo.arguments.contains("--audio-owner-review-testing") }
    static var conversationTesting: Bool { TeamEditorNativeFixture.enabled && ProcessInfo.processInfo.arguments.contains("--audio-conversation-testing") }
    static var enabled: Bool { TeamEditorNativeFixture.enabled && ProcessInfo.processInfo.arguments.contains("--audio-comment-testing") }
    static var taskEditorTesting: Bool { TeamEditorNativeFixture.enabled && ProcessInfo.processInfo.arguments.contains("--audio-task-editor-testing") }
    static func taskEditorRecorder() -> any AudioCommentRecording { AudioCommentFixtureRecording() }
    static func taskEditorPlayer() -> any AudioCommentPlaying { AudioCommentFixturePlaying() }
    static func recordExportResult(_ url: URL, request: UUID) {
        guard taskEditorTesting, ProcessInfo.processInfo.arguments.contains("--audio-library-export-testing"), url.isFileURL else { return }
        let directory = URL.applicationSupportDirectory.appendingPathComponent("Taskfold", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["url": url.absoluteString, "format": AudioCommentPortableRecording.format, "request": request.uuidString.lowercased()], options: [.sortedKeys])
            try data.write(to: directory.appendingPathComponent("audio-recording-export-proof.json"), options: .atomic)
        } catch { assertionFailure("Synthetic recording export receipt could not be written") }
    }

    static var root: URL { URL.applicationSupportDirectory.appendingPathComponent("TaskfoldAudioNative", isDirectory: true) }
    private static var lookupLocks: [String: AudioCommentFixtureLookupLock] = [:]
    static var removedSaveTesting: Bool { enabled && ProcessInfo.processInfo.arguments.contains("--audio-save-external-discard") }
    static func removePreparedSave(_ scope: AudioCommentLiveScope) throws {
        guard removedSaveTesting, scope.workspace.account == "local-audio-native" else { throw CancellationError() }
        let vault = AudioCommentVault(applicationSupport: root, owner: try AudioCommentOwner(scope.workspace.account))
        let matches = try vault.saves().filter { $0.next.target == scope.target && $0.phase == .saving }
        guard matches.count == 1, let intent = matches.first else { throw AudioCommentStorageFailure.conflict }
        try vault.discardSave(intent)
    }
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
    static func prepare() async throws {
        guard enabled else { throw CancellationError() }
        for value in lookupLocks.values { value.release() }; lookupLocks.removeAll()
        if ProcessInfo.processInfo.arguments.contains("--audio-comment-reset") { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copyTesting = ProcessInfo.processInfo.arguments.contains("--audio-interrupted-copy-testing")
        if (copyTesting || ProcessInfo.processInfo.arguments.contains("--audio-interrupted-stage-testing")), ProcessInfo.processInfo.arguments.contains("--audio-comment-reset") {
            let bytes = try await Task.detached { try syntheticData() }.value
            let scope = AudioCommentFixtureContext().scope
            let owner = try AudioCommentOwner(scope.workspace.account), vault = AudioCommentVault(applicationSupport: root, owner: owner)
            _ = try vault.drafts()
            let entries = copyTesting ? [("1", "Earlier workshop recording", false)] : [("1", "Recovered workshop draft", false), ("2", "Recovered workshop review", true)]
            for (suffix, caption, recovery) in entries {
                let draft = try AudioCommentSavedDraft(owner: owner, target: scope.target, caption: caption, clip: .init(data: bytes), id: UUID(uuidString: "ac281000-0000-4000-8000-00000000000" + suffix)!, revision: UUID(uuidString: "ac283000-0000-4000-8000-00000000000" + suffix)!)
                if copyTesting {
                    try vault.save(.init(owner: owner, target: scope.target, caption: "Latest workshop recording", clip: draft.clip, id: draft.id, revision: UUID(uuidString: "ac284000-0000-4000-8000-000000000001")!))
                }
                let path = vault.directory.appendingPathComponent(".write-ac282000-0000-4000-8000-00000000000" + suffix)
                try draft.encoded(recovery: recovery).write(to: path)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            }
            if !copyTesting {
                let incomplete = vault.directory.appendingPathComponent(".write-ac282000-0000-4000-8000-000000000003")
                try Data("Synthetic incomplete recording payload".utf8).write(to: incomplete)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: incomplete.path)
            }
        }
    }
    nonisolated static func syntheticData() throws -> Data {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-audio-native-tone-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("tone.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!; buffer.frameLength = 44100
        for index in 0..<44100 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 44100) * 0.04) }
        do { let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000]); try file.write(from: buffer) }
        return try Data(contentsOf: url)
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
    @State private var saveRemoved = false
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
        .task { do { try await AudioCommentNativeFixture.prepare(); ready = true } catch { problem = error.localizedDescription } }
        .sheet(item: $opening) { request in
            VStack(spacing: 0) {
                AudioCommentDraftView(request: request,
                                  storage: AudioCommentNativeFixture.storage(request.scope),
                                  recorder: AudioCommentFixtureRecording(), player: AudioCommentFixturePlaying(), liveScope: { context.scope })
                if AudioCommentNativeFixture.removedSaveTesting {
                    Button(saveRemoved ? "Pending Save removed outside this editor" : "Remove pending Save outside this editor") {
                        do { try AudioCommentNativeFixture.removePreparedSave(request.scope); saveRemoved = true }
                        catch { problem = error.localizedDescription }
                    }.disabled(saveRemoved).padding().accessibilityIdentifier("audioFixtureRemovePending")
                }
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
        guard AudioCommentNativeFixture.enabled || AudioCommentNativeFixture.taskEditorTesting else { throw CancellationError() }
        guard isCurrent() else { throw CancellationError() }
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
                    try AudioCommentNativeFixture.syntheticData()
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
        guard AudioCommentNativeFixture.enabled || AudioCommentNativeFixture.taskEditorTesting else { throw CancellationError() }
        guard isCurrent() else { throw CancellationError() }
        stop(); task = Task { do { try await Task.sleep(for: .seconds(ProcessInfo.processInfo.arguments.contains("--audio-library-testing") ? 10 : 2)) } catch { return }; if isCurrent() { ended() } }
    }
    func stop() { task?.cancel(); task = nil }
}
#endif

#if DEBUG
/// Actual Store/task editors and production storage; only media drivers are synthetic.
@MainActor struct AudioTaskEditorFixtureScreen: View {
    @State private var library: AudioCommentLibraryRequest?
    @Environment(Store.self) private var store
    @State private var opening: Record?
    @State private var failure: String?
    static let inbox = "ac290000-0000-4000-8000-000000000001"
    static let project = "ac290000-0000-4000-8000-000000000002"
    static let projectTask = "ac290000-0000-4000-8000-000000000003"
    var body: some View {
        NavigationStack {
            Form {
                Button("Open local audio workspace") { prepare() }.accessibilityIdentifier("audioEditorPrepareLocal")
                if store.localMode {
                    Text("On-device test workspace").accessibilityIdentifier("audioEditorWorkspace")
                    Button("Private recordings") { if let scope = store.audioLibraryScope() { library = .init(scope: scope) } }.accessibilityIdentifier("audioEditorOpenLibrary")
                    if ProcessInfo.processInfo.arguments.contains("--audio-library-testing") {
                        if store.record("tasks", id: Self.inbox) != nil {
                            Button("Move test task to workshop") { changeFixtureTask(remove: false) }.accessibilityIdentifier("audioLibraryFixtureMove")
                            Button("Remove test task") { changeFixtureTask(remove: true) }.accessibilityIdentifier("audioLibraryFixtureRemove")
                        }
                    }

                    if let task = store.record("tasks", id: Self.inbox) { Button("Edit Inbox audio task") { opening = task }.accessibilityIdentifier("audioEditorOpenInbox") }
                    if let task = store.record("tasks", id: Self.projectTask) { Button("Edit project audio task") { opening = task }.accessibilityIdentifier("audioEditorOpenProject") }
                }
                if let failure { Text(failure).accessibilityIdentifier("audioEditorFixtureFailure") }
            }.accessibilityIdentifier("audioEditorFixtureForm").navigationTitle("Task recordings")
        }
        .sheet(item: $library) { PrivateAudioLibraryView(request: $0) }
        .sheet(item: $opening) { task in
            #if os(macOS)
            TaskInspectorForm(taskID: task.id, admission: store.editorAdmission(task, kind: .existing))
                .frame(minWidth: 620, minHeight: 720)
            #else
            TaskEditorPresentation(request: .init(store: store, task: task))
            #endif
        }
    }
    private func changeFixtureTask(remove: Bool) {
        guard AudioCommentNativeFixture.taskEditorTesting, ProcessInfo.processInfo.arguments.contains("--audio-library-testing"),
              store.localMode, store.userID == "ui-testing", let task = store.record("tasks", id: Self.inbox),
              task.string("task_generation") == "ac290000-0000-4000-8000-000000000004" else { return }
        let change = Mutation(table: "tasks", recordID: task.id, method: remove ? "DELETE" : "PATCH", fields: remove ? [:] : ["project_id": .string(Self.project)])
        if !store.commit([change]) { failure = store.error ?? "Synthetic task change failed" }
    }
    private func prepare() {
        guard AudioCommentNativeFixture.taskEditorTesting else { return }
        store.dailyBackupsEnabled = false; store.online = false; store.startLocal()
        guard store.localMode else { failure = "Local workspace did not open"; return }
        do {
            if ProcessInfo.processInfo.arguments.contains("--audio-task-editor-reset") {
                guard store.userID == "ui-testing" else { throw AudioCommentFailure.changed }
                let folder = try store.audioDraftBaseDirectory()
                    .appendingPathComponent(AudioCommentTaskAdmission.storageDirectory(origin: nil), isDirectory: true)
                    .appendingPathComponent("AudioCommentsPrivate", isDirectory: true)
                    .appendingPathComponent(AudioCommentOwner(store.userID).directoryName, isDirectory: true)
                if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            }
            let resetting = ProcessInfo.processInfo.arguments.contains("--audio-task-editor-reset")
            var changes: [Mutation] = []
            let oldProject = store.record("projects", id: Self.project)
            if oldProject == nil || resetting {
                if let oldProject { guard oldProject.string("user_id") == store.userID, oldProject.string("team_id").isEmpty else { throw AudioCommentFailure.changed } }
                let project = Record(["id": .string(Self.project), "user_id": .string(store.userID), "name": .string("Audio workshop"), "is_archived": .bool(false)])
                changes.append(Mutation(table: "projects", recordID: project.id, method: oldProject == nil ? "POST" : "PATCH", fields: project.fields))
            }
            for (id, title, project) in [(Self.inbox, "Keep the Inbox workshop notes", Optional<String>.none), (Self.projectTask, "Prepare the project workshop", Self.project)] where store.record("tasks", id: id) == nil || resetting {
                if id == Self.inbox, ProcessInfo.processInfo.arguments.contains("--audio-library-keep-removed-task"), !ProcessInfo.processInfo.arguments.contains("--audio-task-editor-reset") { continue }
                let oldTask = store.record("tasks", id: id)
                if let oldTask { guard oldTask.string("user_id") == store.userID, oldTask.string("task_generation") == "ac290000-0000-4000-8000-000000000004" else { throw AudioCommentFailure.changed } }
                var task = Record.task(user: store.userID, project: project ?? "")
                task["id"] = .string(id); task["task_generation"] = .string("ac290000-0000-4000-8000-000000000004")
                task["title"] = .string(title); task["description"] = .string("Keep these original task notes unchanged.")
                changes.append(Mutation(table: "tasks", recordID: id, method: oldTask == nil ? "POST" : "PATCH", fields: task.fields))
            }
            guard changes.isEmpty || store.commit(changes) else { failure = store.error ?? "Fixture tasks did not save"; return }
            failure = nil
        } catch { failure = error.localizedDescription }
    }
}
#endif

#if DEBUG
/// View-only dependency seam. Available solely in DEBUG; the reserved fixture
/// gate is still required before constructing any synthetic context or driver.
@MainActor struct AudioConversationPresentationFixture {
    let session: UUID
    let isCurrent: () -> Bool
    let makeController: () throws -> AudioCommentConversationController
    let authorName: (UUID?) -> String
}
@MainActor @Observable private final class AudioConversationNativeContext: AudioCommentReadingTransport {
    let scope: AudioCommentLiveScope
    let session=UUID()
    let clip: AudioCommentClip
    let owner: Bool
    let deniedPages: Bool
    let departOnPlay: Bool
    var active=true
    var rows: [AudioCommentRemote]=[]
    var plays=0
    var removals=0
    var pageReads=0
    init(clip:AudioCommentClip,ownerOverride:Bool?=nil,countOverride:Int?=nil,deniedOverride:Bool?=nil,departureOverride:Bool?=nil) throws {
        guard AudioCommentNativeFixture.conversationTesting else { throw CancellationError() }
        self.clip=clip;owner=ownerOverride ?? ProcessInfo.processInfo.arguments.contains("--audio-conversation-owner");deniedPages=deniedOverride ?? ProcessInfo.processInfo.arguments.contains("--audio-conversation-denied-page");departOnPlay=departureOverride ?? ProcessInfo.processInfo.arguments.contains("--audio-conversation-departure")
        let account=UUID(uuidString:"ad310000-0000-4000-8000-000000000001")!,target=try AudioCommentTarget(task:UUID(uuidString:"ad310000-0000-4000-8000-000000000002")!,generation:UUID(uuidString:"ad310000-0000-4000-8000-000000000003")!,project:ProcessInfo.processInfo.arguments.contains("--audio-timeline-testing") ? UUID(uuidString:"ad310000-0000-4000-8000-000000000004"):nil)
        scope = .init(workspace:.init(account:account.uuidString.lowercased(),generation:UUID()),target:target,origin:"https://conversation-fixture.example.invalid")
        let count=countOverride ?? (ProcessInfo.processInfo.arguments.contains("--audio-conversation-short") ? 2 : 21)
        for index in 1...count {
            let suffix=String(format:"%012d",index),id=UUID(uuidString:"ad311000-0000-4000-8000-"+suffix)!
            let caption=String(format:"Design review %02d",index)+(index == 1 ? "\nKeep the cafe\u{301} notes literal.\nمراجعة التصميم 🪴" : "")
            let intent=try AudioCommentPublication(account:account,target:target,caption:caption,descriptor:clip.descriptor,operation:UUID(uuidString:"ad312000-0000-4000-8000-"+suffix)!,comment:id,asset:UUID(uuidString:"ad313000-0000-4000-8000-"+suffix)!)
            var fields=intent.record.fields;fields.removeValue(forKey:"version");fields["protocol"] = .number(1);fields["author_id"] = .string(account.uuidString.lowercased());fields["state"] = .string("published");fields["reserved_at"] = .string("2026-10-28T12:00:00Z");fields["expires_at"] = .string("2026-10-29T12:00:00Z");fields["published_at"] = .string(ProcessInfo.processInfo.arguments.contains("--audio-timeline-testing") && index > 1 ? "2026-10-28T12:03:00.123456Z":"2026-10-28T12:01:00.123456Z")
            rows.append(try .init(record:Record(fields),account:account,target:target))
        }
    }
    var request: AudioCommentConversationRequest { .init(scope:scope) }
    var timelineRequest: ConversationRequest {
        .init(task:Record(["id":.string(scope.target.task.uuidString.lowercased()),"task_generation":.string(scope.target.generation.uuidString.lowercased()),"project_id":.string(scope.target.project?.uuidString.lowercased() ?? "")]),workspace:scope.workspace)
    }
    var textComments: [SharedComment] {
        [("ad314000-0000-4000-8000-000000000001","Shared text before the recording","2026-10-28T12:00:00Z"),
         ("ad314000-0000-4000-8000-000000000002","Shared text after the recording","2026-10-28T12:02:00Z")].compactMap {id,body,date in
            SharedComment(Record(["id":.string(id),"task_id":.string(scope.target.task.uuidString.lowercased()),"task_generation":.string(scope.target.generation.uuidString.lowercased()),"project_id":.string(scope.target.project?.uuidString.lowercased() ?? ""),"author_id":.string(scope.workspace.account),"body":.string(body),"mention_ids":.array([]),"revision":.number(1),"created_at":.string(date),"updated_at":.string(date),"deleted_at":.null]))
        }
    }

    var driver: AudioConversationPresentationFixture {
        .init(session:session,isCurrent:{self.active},makeController:{
            let value=try AudioCommentConversationController(scope:self.scope,incarnation:self.session,transport:self,player:AudioConversationSilentPlayer(context:self))
            value.currentScope = { [weak self] in self?.active == true ? self?.scope : nil }
            value.sessionIsCurrent = { [weak self] in self?.active == true }
            value.removalAuthority = { [weak self] _ in self?.active == true && self?.owner == true }
            return value
        },authorName:{ _ in "You" })
    }
    func pageAudio(account:UUID,target:AudioCommentTarget,after:AudioCommentPageCursor?,origin:String,incarnation:UUID) async throws -> AudioCommentPage {
        guard active, account.uuidString.lowercased()==scope.workspace.account,target==scope.target,origin==scope.origin,incarnation==session else { throw CancellationError() }
        pageReads += 1
        if after != nil, deniedPages { throw AudioCommentReadAccessUnavailable() }
        let start=after.flatMap { cursor in rows.firstIndex { $0.record["comment_id"]==cursor.position["comment_id"] }.map { $0+1 } } ?? 0
        let values=Array(rows.dropFirst(start).prefix(20)),next:JSON
        if start+20<rows.count,let last=values.last {next = .object(["published_at":last.record["published_at"],"comment_id":last.record["comment_id"]])}else{next = .null}
        return try .init(data:JSONEncoder().encode(Record(["protocol":.number(1),"account":.string(account.uuidString.lowercased()),"items":.array(values.map { .object($0.record.fields) }),"next":next])),account:account,target:target,after:after)
    }
    func listAudio(account:UUID,target:AudioCommentTarget,origin:String,incarnation:UUID) async throws -> [AudioCommentRemote] { try await pageAudio(account:account,target:target,after:nil,origin:origin,incarnation:incarnation).items }
    func downloadAudio(_ comment:AudioCommentRemote,origin:String,incarnation:UUID) async throws -> AudioCommentClip {
        guard active,rows.contains(comment) else { throw AudioCommentReadAccessUnavailable() }
        if departOnPlay {active=false;await Task.yield()}
        return clip
    }
    func removeAudio(_ comment:AudioCommentRemote,origin:String,incarnation:UUID) async throws -> AudioCommentRemoteRemoval {
        guard active,owner,rows.contains(comment) else { throw AudioCommentReadAccessUnavailable() }
        removals += 1;rows.removeAll { $0.id==comment.id }
        return try .init(data:JSONEncoder().encode(Record(["protocol":.number(1),"account":.string(scope.workspace.account),"comment_id":.string(comment.id.uuidString.lowercased()),"operation_id":.string(comment.publication.operation.uuidString.lowercased()),"state":.string("retired")])),expected:comment)
    }
}
@MainActor private final class AudioConversationSilentPlayer: AudioCommentPlaying {
    let context: AudioConversationNativeContext
    init(context:AudioConversationNativeContext){self.context=context}
    func play(_ clip:AudioCommentClip,isCurrent:@escaping @MainActor ()->Bool,ended:@escaping @MainActor ()->Void) throws {
        guard AudioCommentNativeFixture.conversationTesting,isCurrent() else {throw CancellationError()};context.plays += 1
    }
    func stop() {}
}
@MainActor struct AudioConversationNativeFixtureView: View {
    @State private var context:AudioConversationNativeContext?
    @State private var opening:AudioCommentConversationRequest?
    @State private var failure:String?
    @State private var largeText=false
    var body:some View {
        NavigationStack {
            #if os(macOS)
            VStack(alignment:.leading,spacing:20) {
                if let context {
                    HStack {
                        Button("Reader fixture") {preset(context.clip,owner:false,count:2)}.accessibilityIdentifier("audioConversationFixtureReader")
                        Button("Owner and paging fixture") {preset(context.clip,owner:true,count:21)}.accessibilityIdentifier("audioConversationFixtureOwner")
                        Toggle("Large text",isOn:$largeText).accessibilityIdentifier("audioConversationFixtureLarge")
                    }
                    HStack {
                        Button("Denied page fixture") {preset(context.clip,owner:false,count:21,denied:true)}.accessibilityIdentifier("audioConversationFixtureDenied")
                        Button("Departure fixture") {preset(context.clip,owner:false,count:2,departure:true)}.accessibilityIdentifier("audioConversationFixtureDeparture")
                    }
                }


                if let context {
                    Button("Open audio conversation") {opening=context.request}.accessibilityIdentifier("audioConversationFixtureOpen")
                    Text("Records kept: \(context.rows.count)").accessibilityIdentifier("audioConversationFixtureCount")
                    Text("Removals: \(context.removals)").accessibilityIdentifier("audioConversationFixtureRemovals")
                    Text("Plays: \(context.plays)").accessibilityIdentifier("audioConversationFixturePlays")
                    Text(context.active ? "Workspace active" : "Workspace closed").accessibilityIdentifier("audioConversationFixtureScope")
                } else {ProgressView("Preparing synthetic conversation…")}
                if let failure {Text(failure)}

            }.padding(30).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).navigationTitle("Audio conversation fixture")
            #else
            Form {

                if let context {
                    Button("Open audio conversation") {opening=context.request}.accessibilityIdentifier("audioConversationFixtureOpen")
                    Text("Records kept: \(context.rows.count)").accessibilityIdentifier("audioConversationFixtureCount")
                    Text("Removals: \(context.removals)").accessibilityIdentifier("audioConversationFixtureRemovals")
                    Text("Plays: \(context.plays)").accessibilityIdentifier("audioConversationFixturePlays")
                    Text(context.active ? "Workspace active" : "Workspace closed").accessibilityIdentifier("audioConversationFixtureScope")
                } else {ProgressView("Preparing synthetic conversation…")}
                if let failure {Text(failure)}

            }.navigationTitle("Audio conversation fixture")
            #endif
        }.task {
            guard AudioCommentNativeFixture.conversationTesting else {return}
            do {let bytes=try await Task.detached {try AudioCommentNativeFixture.syntheticData()}.value;context=try AudioConversationNativeContext(clip:await AudioCommentDecoding.validate(bytes))}catch{failure=error.localizedDescription}
        }.sheet(item:$opening) {request in
            if let context {
                Group {
                    if ProcessInfo.processInfo.arguments.contains("--audio-timeline-testing") {AudioConversationTimelineFixture(context:context)}
                    else {AudioCommentConversationView(request:request,fixture:context.driver)}
                }.environment(\.dynamicTypeSize, largeText || ProcessInfo.processInfo.arguments.contains("UICTContentSizeCategoryAccessibilityXXXL") ? .accessibility5 : .large)
            }
        }
        #if os(macOS)
        .dynamicTypeSize(largeText || ProcessInfo.processInfo.arguments.contains("UICTContentSizeCategoryAccessibilityXXXL") ? .accessibility5 : .large)
        .frame(minWidth:650,minHeight:650)
        #endif
    }
    private func preset(_ clip:AudioCommentClip,owner:Bool,count:Int,denied:Bool=false,departure:Bool=false) {
        do {context=try AudioConversationNativeContext(clip:clip,ownerOverride:owner,countOverride:count,deniedOverride:denied,departureOverride:departure);failure=nil} catch {failure=error.localizedDescription}
    }

}

@MainActor private struct AudioConversationTimelineFixture: View {
    let context:AudioConversationNativeContext
    @Environment(\.dismiss) private var dismiss
    @State private var refresh=UUID()
    var body:some View {
        NavigationStack {
            ScrollView {
                UnifiedConversationTimeline(request:context.timelineRequest,comments:context.textComments,audioRequest:context.request,textHasMore:false,refresh:refresh,textRow:{comment in
                    VStack(alignment:.leading,spacing:10) {
                        Text("You").font(.subheadline.weight(.semibold))
                        Text(comment.body).fixedSize(horizontal:false,vertical:true)
                        Text(comment.createdAt.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)
                    }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(Color.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:18)).accessibilityIdentifier("timelineText-"+comment.id)
                },fixture:context.driver).padding(20)
            }.accessibilityIdentifier("timelineFixtureScroll").navigationTitle("Conversation")
                .toolbar {ToolbarItem(placement:.cancellationAction) {Button("Close") {dismiss()}.accessibilityIdentifier("timelineFixtureClose")}}
        }
        #if os(macOS)
        .frame(minWidth:560,minHeight:650)
        #endif
    }
}

// The reserved DEBUG host presents the production review, with real private vault
// writes/full AAC validation and a metadata-only synthetic sender transport.
@MainActor @Observable private final class AudioOwnerReviewContext: AudioCommentPublishingTransport {
    let scope: AudioCommentLibraryScope
    let storage: AudioCommentPublicationStorage
    let journal: AudioCommentPublicationJournal
    let controller: AudioCommentPendingLibrary
    let session = UUID()
    var active = true
    var checks = 0
    var closes = 0
    var uploads = 0
    var savedState = ""
    init(clip: AudioCommentClip) async throws {
        guard AudioCommentNativeFixture.ownerReviewTesting else { throw CancellationError() }
        let owner = try AudioCommentOwner("ad410000-0000-4000-8000-000000000001")
        let root = AudioCommentNativeFixture.root.appendingPathComponent("owner-review", isDirectory: true)
        if ProcessInfo.processInfo.arguments.contains("--audio-owner-reset"), FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let origin = "https://owner-review.example.invalid"
        scope = .init(workspace: .init(account: owner.account, generation: UUID()), origin: origin)
        storage = .init(disk: try .init(root: root, account: UUID(uuidString: owner.account)!, origin: origin))
        let existing = try await storage.journals()
        if let saved = existing.first { journal = saved }
        else {
            let target = try AudioCommentTarget(task: UUID(), generation: UUID(), project: nil)
            let source = try AudioCommentSavedDraft(owner: owner, target: target, caption: "Original cafe\u{301} recording\nKeep the workshop notes 🪴", clip: clip)
            journal = try await storage.prepare(source)
        }
        controller = .init(scope: scope, storage: storage, drafts: .init(vault: AudioCommentVault(applicationSupport: root, owner: owner)), player: AudioOwnerSilentPlayer())
        controller.currentScope = { [weak self] in self?.active == true ? self?.scope : nil }
        await snapshot()
    }
    func snapshot() async {
        guard let value = try? await storage.journals().first else { savedState = "Journal unavailable"; return }
        savedState = (value.closedReceipt != nil ? "Closed" : (value.receipt != nil ? "Published" : "Pending")) + (value.clip != nil ? " · private audio kept" : " · private audio removed")
    }
    func flow(_ value: AudioCommentPublicationJournal, publishing: Bool) throws -> AudioCommentPublicationFlow {
        guard active, controller.selectedIsCurrent(value) else { throw AudioCommentFailure.changed }
        return .init(storage: storage, transport: self, incarnation: session, target: value.publication.target, retainAudioOnConfirmation: true, allowsPublishing: publishing, isCurrent: { [weak self] in self?.active == true && self?.controller.selectedIsCurrent(value) == true })
    }
    func checkAudioPublication(_ publication: AudioCommentPublication, closing: Bool, origin: String, incarnation: UUID) async throws -> AudioCommentPublicationStatus {
        guard active, origin == scope.origin, incarnation == session, publication.sameIntent(as: journal.publication) else { throw AudioCommentFailure.changed }
        checks += 1; if closing { closes += 1 }
        #if os(iOS)
        // Hold a real asynchronous result while the test starts VoiceOver. This
        // checks result focus without pretending an XCTest tap is a VO gesture.
        if ProcessInfo.processInfo.arguments.contains("--audio-owner-wait-for-voiceover") {
            let ready = AudioCommentNativeFixture.root.appendingPathComponent("owner-review/voiceover-ready")
            while !FileManager.default.fileExists(atPath: ready.path) { try await Task.sleep(for: .milliseconds(100)) }
            guard active, !Task.isCancelled else { throw CancellationError() }
        }
        #endif
        if ProcessInfo.processInfo.arguments.contains("--audio-owner-error") { throw AudioCommentFailure(message: "Publication couldn’t be confirmed. Your private recording is preserved.") }
        if ProcessInfo.processInfo.arguments.contains("--audio-owner-published") { return .published(try receipt(publication)) }
        if closing { return .closed(try .init(record: .init(["protocol": .number(1), "intent": .object(publication.record.fields), "state": .string("closed")]), publication: publication)) }
        return .unconfirmed
    }
    func publishAudio(_ upload: AudioCommentPending, origin: String, incarnation: UUID) async throws -> AudioCommentPublishedReceipt {
        guard active, ProcessInfo.processInfo.arguments.contains("--audio-owner-resumable"), origin == scope.origin, incarnation == session else { throw AudioCommentFailure.changed }
        uploads += 1; return try receipt(upload.publication)
    }
    private func receipt(_ publication: AudioCommentPublication) throws -> AudioCommentPublishedReceipt {
        var fields = publication.record.fields; fields.removeValue(forKey: "version")
        fields["protocol"] = .number(1); fields["author_id"] = .string(publication.account.uuidString.lowercased()); fields["state"] = .string("published")
        fields["reserved_at"] = .string("2026-10-28T12:00:00Z"); fields["published_at"] = .string("2026-10-28T12:01:00Z"); fields["expires_at"] = .string("2026-10-29T12:00:00Z")
        return try .init(record: .init(fields), publication: publication)
    }
}
@MainActor private final class AudioOwnerSilentPlayer: AudioCommentPlaying {
    func play(_ clip: AudioCommentClip, isCurrent: @escaping @MainActor () -> Bool, ended: @escaping @MainActor () -> Void) throws { guard AudioCommentNativeFixture.ownerReviewTesting, isCurrent() else { throw CancellationError() } }
    func stop() {}
}
@MainActor struct AudioOwnerReviewNativeFixtureView: View {
    @State private var context: AudioOwnerReviewContext?
    @State private var opening = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                if let context {
                    Button("Review original send") { opening = true }.accessibilityIdentifier("audioOwnerFixtureOpen")
                    Text(context.savedState).accessibilityIdentifier("audioOwnerFixtureSaved")
                    Text("Checks: \(context.checks) · closures: \(context.closes) · uploads: \(context.uploads)").accessibilityIdentifier("audioOwnerFixtureRequests")
                }
                if let failure { Text(failure) }
            }.navigationTitle("Sender recovery fixture")
        }
        .task {
            guard AudioCommentNativeFixture.ownerReviewTesting else { return }
            do { let bytes = try await Task.detached { try AudioCommentNativeFixture.syntheticData() }.value; context = try await AudioOwnerReviewContext(clip: AudioCommentDecoding.validate(bytes)) }
            catch { failure = error.localizedDescription }
        }
        .sheet(isPresented: $opening, onDismiss: { Task { await context?.snapshot() } }) {
            if let context {
                AudioPendingPublicationReview(journal: context.journal, controller: context.controller, taskTitle: { _ in nil }, canResume: { _ in ProcessInfo.processInfo.arguments.contains("--audio-owner-resumable") }, checker: { try context.flow($0, publishing: false) }, publisher: { try context.flow($0, publishing: true) })
            }
        }
        #if os(macOS)
        .frame(minWidth: 650, minHeight: 650)
        #endif
    }
}

#endif
