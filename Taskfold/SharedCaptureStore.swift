import Foundation

extension Store {
    func sharedCaptureDisk() throws -> SharedCaptureDisk {
        #if DEBUG
        if SharedCaptureCountNativeFixture.enabled { return SharedCaptureDisk(directory: SharedCaptureCountNativeFixture.directory) }
        if AccountRemovalNativeFixture.enabled { return SharedCaptureDisk(directory: AccountRemovalNativeFixture.sharedRoot) }
        #endif
        return try SharedCaptureDisk.system()
    }
    func publishSharedCaptureWorkspace() {
        do {
            let active = sharedCaptureAvailable
            if !active { sharedCaptureCountReader.invalidate(); sharedCaptureDraftCount = 0 }
            let label = localMode ? "Local workspace" : backend.session?.user.email ?? "Taskfold workspace"
            let context = active ? SharedCaptureWorkspace(account: userID, generation: workspaceGeneration, label: label) : nil
            guard !sharedCapturePublicationReady || sharedCapturePublishedWorkspace != context else { return }
            try sharedCaptureDisk().publish(context)
            sharedCapturePublishedWorkspace = context; sharedCapturePublicationReady = true
            refreshSharedCaptureDraftCount()
        } catch {
            sharedCapturePublicationReady = false
            // The app continues working if extension storage is unavailable. The draft review
            // displays the actual storage error, and the extension rechecks publication on Save.
        }
    }
    var sharedCaptureReadContext: SharedCaptureCountReader.Context? {
        guard sharedCaptureAvailable else { return nil }
        return .init(workspace: .init(account: userID, generation: workspaceGeneration),
                     session: backend.reminderSessionIncarnation, access: workspaceReadRevision,
                     origin: backend.baseURL, receipts: snapshot.sharedCaptureReceipts ?? [:])
    }
    /// Resolve the group in the worker too: the OS can pause file access for a
    /// permission decision. No Store or mutable workspace crosses that boundary.
    private func sharedCaptureCountSource() -> @Sendable () throws -> SharedCaptureDisk {
        #if DEBUG
        if SharedCaptureCountNativeFixture.enabled {
            let directory = SharedCaptureCountNativeFixture.directory
            return { SharedCaptureDisk(directory: directory) }
        }
        if AccountRemovalNativeFixture.enabled {
            let directory = AccountRemovalNativeFixture.sharedRoot
            return { SharedCaptureDisk(directory: directory) }
        }
        #endif
        return { try SharedCaptureDisk.system() }
    }
    func refreshSharedCaptureDraftCount() {
        guard let context = sharedCaptureReadContext else {
            sharedCaptureCountReader.invalidate(); sharedCaptureDraftCount = 0; return
        }
        let source = sharedCaptureCountSource()
        #if DEBUG
        let gate = SharedCaptureCountNativeFixture.enabled ? SharedCaptureCountNativeFixture.gate : nil
        #endif
        sharedCaptureCountReader.refresh(read: {
            #if DEBUG
            await gate?.hold()
            #endif
            return try source().unhandledDraftCount(account: context.workspace.account, receipts: context.receipts)
        }) { [weak self] result in
            guard let self, self.sharedCaptureReadContext == context else { return }
            self.sharedCaptureDraftCount = (try? result.get()) ?? 0
        }
    }
    func loadSharedCaptureDrafts(_ binding: WorkspaceBinding?, reader: SharedCaptureReviewReader,
                                complete: @escaping @MainActor (Result<[SharedCaptureDraft], Error>) -> Void) {
        guard binding?.matches(account: userID, generation: workspaceGeneration) == true,
              let context = sharedCaptureReadContext else {
            reader.invalidate()
            complete(.failure(SharedCaptureFailure("Reopen shared drafts in your current workspace.")))
            return
        }
        sharedCaptureCountReader.invalidate()
        let source = sharedCaptureCountSource()
        #if DEBUG
        let gate = SharedCaptureCountNativeFixture.reviewEnabled ? SharedCaptureCountNativeFixture.reviewGate : nil
        #endif
        reader.refresh(read: {
            #if DEBUG
            await gate?.hold()
            #endif
            return try source().reviewDrafts(account: context.workspace.account, receipts: context.receipts)
        }) { [weak self] result in
            guard let self else { return }
            guard self.sharedCaptureReadContext == context else {
                complete(.failure(SharedCaptureFailure("Your workspace or shared drafts changed. Please try again.")))
                return
            }
            if case .success(let drafts) = result { self.sharedCaptureCountReader.invalidate(); self.sharedCaptureDraftCount = drafts.count }
            complete(result)
        }
    }
    func discardSharedCapture(_ draft: SharedCaptureDraft, binding: WorkspaceBinding?) throws {
        guard binding?.matches(account: userID, generation: workspaceGeneration) == true, sharedCaptureAvailable, draft.workspace.account == userID else { throw SharedCaptureFailure("Reopen this draft in its original workspace.") }
        try sharedCaptureDisk().acknowledge(draft, account: userID)
        refreshSharedCaptureDraftCount()
    }
    @discardableResult func addSharedCapture(_ draft: SharedCaptureDraft, content: SharedCaptureContent, project: String, binding: WorkspaceBinding?) -> Bool {
        guard workflowReady(binding) else { return false }
        do {
            let disk = try sharedCaptureDisk()
            if snapshot.sharedCaptureReceipts?[draft.taskID] == draft.taskID {
                try disk.acknowledge(draft, account: userID); return true
            }
            guard try disk.drafts(account: userID).contains(draft) else { throw SharedCaptureFailure("This draft was already handled. Refresh shared drafts.") }
            switch try SharedCapturePlan.prepare(draft, content: content, account: userID, project: project, snapshot: snapshot) {
            case .saved: break
            case .create(let change):
                guard commit([change], sharedCaptureReceipt: draft) else { return false }
            }
            // A failed acknowledgement leaves a harmless review row. Its atomic receipt
            // prevents a retry from recreating a task after editing, completion, deletion or Undo.
            do { try disk.acknowledge(draft, account: userID) }
            catch { notice = "Task added. The saved draft will clear when shared drafts is refreshed." }
            refreshSharedCaptureDraftCount()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

#if DEBUG
extension Store {
    func seedSharedCaptureFixture() {
        guard ProcessInfo.processInfo.arguments.contains("--shared-capture-fixture"),
              ProcessInfo.processInfo.arguments.contains("--uitesting"), userID == "ui-testing",
              Bundle.main.bundleIdentifier?.contains(".workflowtests") == true else { return }
        do {
            publishSharedCaptureWorkspace()
            let disk = try sharedCaptureDisk()
            guard let context = try disk.workspace(), context.account == userID else { throw SharedCaptureFailure("The isolated sharing workspace is unavailable.") }
            let id = UUID(uuidString: "a174c000-0000-4000-8000-000000000001")!
            for draft in try disk.drafts(account: userID) where draft.id == id { try disk.acknowledge(draft, account: userID) }
            let content = try SharedCaptureContent(title: "Read the accessibility guide", notes: "Compare text size and contrast.", source: "https://example.com/accessibility")
            try disk.save(SharedCaptureDraft(id: id, workspace: context, content: content))
        } catch { self.error = error.localizedDescription }
    }
}
#endif

#if DEBUG
@MainActor enum SharedCaptureCountNativeFixture {
    static var enabled: Bool {
        ["com.dbakp.taskfold.workflowteststeameditbridge", "com.dbakp.taskfold.mac.workflowteststeameditbridge"].contains(Bundle.main.bundleIdentifier ?? "") &&
        ProcessInfo.processInfo.arguments.contains("--team-editor-testing") && (ProcessInfo.processInfo.arguments.contains("--shared-capture-count-native") || reviewEnabled)
    }
    static var directory: URL { URL.applicationSupportDirectory.appendingPathComponent("Shared capture count native", isDirectory: true) }
    static var reviewEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--shared-capture-review-native") }
    static var reviewGate: SharedCaptureCountNativeGate?
    static var gate: SharedCaptureCountNativeGate?
    static var original: Snapshot?
    static var originalMailbox: Data?
}
actor SharedCaptureCountNativeGate {
    private var started = false
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    func hold() async {
        if released { return }
        await withCheckedContinuation { continuation in
            release = continuation; started = true; waiting.forEach { $0.resume() }; waiting = []
        }
    }
    func waitUntilStarted() async { if started { return }; await withCheckedContinuation { waiting.append($0) } }
    func resume() { released = true; release?.resume(); release = nil }
}
extension Store {
    func refreshSharedReviewReceiptNative(restore: Bool = false) {
        guard SharedCaptureCountNativeFixture.enabled, SharedCaptureCountNativeFixture.reviewEnabled,
              let original = SharedCaptureCountNativeFixture.original else { return }
        if restore { snapshot.sharedCaptureReceipts = original.sharedCaptureReceipts }
        else {
            if snapshot.sharedCaptureReceipts == nil { snapshot.sharedCaptureReceipts = [:] }
            snapshot.sharedCaptureReceipts?["da690000-0000-4000-8000-000000000099"] = "da690000-0000-4000-8000-000000000099"
        }
    }
    func prepareSharedCaptureReviewNative() {
        guard SharedCaptureCountNativeFixture.enabled, SharedCaptureCountNativeFixture.reviewEnabled, sharedCaptureAvailable else { return }
        do {
            let folder = SharedCaptureCountNativeFixture.directory
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            let disk = try sharedCaptureDisk()
            let workspace = SharedCaptureWorkspace(account: userID, generation: workspaceGeneration, label: "Review test workspace")
            try disk.publish(workspace)
            for n in 1...2 {
                let id = UUID(uuidString: String(format: "da690000-0000-4000-8000-%012d", n))!
                try disk.save(SharedCaptureDraft(id: id, workspace: workspace, content: SharedCaptureContent(title: "Shared thought \(n)", notes: "Keep every line.\nCafé notes 🪴\nLast instruction.")))
            }
            SharedCaptureCountNativeFixture.original = snapshot
            SharedCaptureCountNativeFixture.reviewGate = SharedCaptureCountNativeGate()
            sharedCaptureCountNativeStatus = "Review ready"
        } catch { sharedCaptureCountNativeStatus = error.localizedDescription }
    }
    func beginSharedCaptureCountNative() async {
        guard SharedCaptureCountNativeFixture.enabled, sharedCaptureAvailable else { return }
        do {
            SharedCaptureCountNativeFixture.gate = nil; sharedCaptureCountReader.invalidate()
            let folder = SharedCaptureCountNativeFixture.directory
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            let disk = try sharedCaptureDisk(), workspace = SharedCaptureWorkspace(account: userID, generation: workspaceGeneration, label: "Count read test workspace")
            try disk.publish(workspace)
            for n in 1...2 {
                let id = UUID(uuidString: String(format: "da690000-0000-4000-8000-%012d", n))!
                try disk.save(SharedCaptureDraft(id: id, workspace: workspace, content: SharedCaptureContent(title: "Shared thought \(n)", notes: String(repeating: "Keep these exact notes. ", count: 3500))))
            }
            SharedCaptureCountNativeFixture.original = snapshot
            SharedCaptureCountNativeFixture.originalMailbox = try Data(contentsOf: folder.appendingPathComponent("shared-capture.json"))
            sharedCaptureDraftCount = 0
            let gate = SharedCaptureCountNativeGate(); SharedCaptureCountNativeFixture.gate = gate
            refreshSharedCaptureDraftCount()
            await gate.waitUntilStarted()
            sharedCaptureCountNativeStatus = "Count read waiting"
        } catch { sharedCaptureCountNativeStatus = error.localizedDescription }
    }
    func finishSharedCaptureCountNative() async {
        guard SharedCaptureCountNativeFixture.enabled, let gate = SharedCaptureCountNativeFixture.gate,
              let original = SharedCaptureCountNativeFixture.original else { return }
        do {
            func idle() async throws {
                let limit = ContinuousClock.now.advanced(by: .seconds(8))
                while !sharedCaptureCountReader.isIdle {
                    guard ContinuousClock.now < limit else { throw SharedCaptureFailure("Count reader did not settle") }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            let id = "da690000-0000-4000-8000-000000000001"
            if snapshot.sharedCaptureReceipts == nil { snapshot.sharedCaptureReceipts = [:] }
            snapshot.sharedCaptureReceipts?[id] = id
            SharedCaptureCountNativeFixture.gate = nil
            await gate.resume(); try await idle()
            guard sharedCaptureDraftCount == 0 else { throw SharedCaptureFailure("An outdated receipt read was displayed") }
            refreshSharedCaptureDraftCount(); try await idle()
            guard sharedCaptureDraftCount == 1 else { throw SharedCaptureFailure("Handled draft was counted again") }
            snapshot = original; refreshSharedCaptureDraftCount(); try await idle()
            guard sharedCaptureDraftCount == 2, snapshot == original,
                  try Data(contentsOf: SharedCaptureCountNativeFixture.directory.appendingPathComponent("shared-capture.json")) == SharedCaptureCountNativeFixture.originalMailbox else { throw SharedCaptureFailure("Count read changed saved work or mailbox bytes") }
            sharedCaptureCountNativeStatus = "Count 2 · stale result refused · originals kept"
        } catch {
            snapshot = original; SharedCaptureCountNativeFixture.gate = nil
            sharedCaptureCountNativeStatus = error.localizedDescription
        }
    }
}
#endif
