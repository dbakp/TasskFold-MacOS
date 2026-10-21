import Foundation

extension Store {
    func sharedCaptureDisk() throws -> SharedCaptureDisk { try SharedCaptureDisk.system() }
    func publishSharedCaptureWorkspace() {
        do {
            let active = sharedCaptureAvailable
            if !active { sharedCaptureDraftCount = 0 }
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
    func refreshSharedCaptureDraftCount() {
        guard sharedCaptureAvailable else { sharedCaptureDraftCount = 0; return }
        do { sharedCaptureDraftCount = try sharedCaptureDisk().drafts(account: userID).filter { snapshot.sharedCaptureReceipts?[$0.taskID] != $0.taskID }.count }
        catch { sharedCaptureDraftCount = 0 }
    }
    func sharedCaptureDrafts(_ binding: WorkspaceBinding?) throws -> [SharedCaptureDraft] {
        guard binding?.matches(account: userID, generation: workspaceGeneration) == true, sharedCaptureAvailable else { throw SharedCaptureFailure("Reopen shared drafts in your current workspace.") }
        let disk = try sharedCaptureDisk()
        let drafts = try disk.drafts(account: userID)
        for draft in drafts where snapshot.sharedCaptureReceipts?[draft.taskID] == draft.taskID { try? disk.acknowledge(draft, account: userID) }
        let visible = drafts.filter { snapshot.sharedCaptureReceipts?[$0.taskID] != $0.taskID }
        sharedCaptureDraftCount = visible.count
        return visible
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
