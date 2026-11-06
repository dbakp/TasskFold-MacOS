import Foundation

/// Atomic task creation is recorded in the private account cache, outside backup tables and sync.
enum SharedCapturePlan {
    enum Result { case saved, create(Mutation) }
    static func prepare(_ draft: SharedCaptureDraft, content: SharedCaptureContent, account: String, project: String, snapshot: Snapshot) throws -> Result {
        try draft.validate(); try content.validate()
        guard !account.isEmpty, draft.workspace.account == account else { throw SharedCaptureFailure("This draft belongs to another workspace.") }
        if snapshot.sharedCaptureReceipts?[draft.taskID] == draft.taskID { return .saved }
        guard !(snapshot.tables["tasks"] ?? []).contains(where: { $0.id.lowercased() == draft.taskID }) else {
            throw SharedCaptureFailure("A task with this draft’s identity already exists. Your draft is kept for review.")
        }
        if !project.isEmpty {
            let projects = snapshot.tables["projects"] ?? []
            guard projects.contains(where: { $0.id == project }), !ProjectOrganization.archived(project, in: projects) else {
                throw SharedCaptureFailure("This project is no longer available. Choose Inbox or another active project.")
            }
        }
        var task = Record.task(user: account, project: project)
        task["id"] = .string(draft.taskID)
        task["task_generation"] = .string(WorkspaceBackup.stableID("shared-capture-generation", draft.taskID))
        task["title"] = .string(content.title.trimmingCharacters(in: .whitespacesAndNewlines))
        task["description"] = .string(content.taskDescription)
        return .create(Mutation(table: "tasks", recordID: task.id, method: "POST", fields: task.fields, insertOnly: true))
    }
}

// App-side presentation work; the incoming Share extension owns only the mailbox contract.
/// A read-only badge request. File access and decoding never run on the
/// interface executor; retain one active read and only the newest pending read.
@MainActor final class SharedCaptureCountReader {
    struct Context: Equatable, Sendable {
        let workspace: WorkspaceBinding
        let session: UUID
        let access: UUID
        let origin: String
        let receipts: [String: String]
    }
    typealias Read = @Sendable () async throws -> Int
    private struct Request {
        let id: UUID
        let read: Read
        let complete: @MainActor (Result<Int, Error>) -> Void
    }
    private var pending: Request?
    private var latest: UUID?
    private var active: Task<Int, Error>?
    private(set) var isIdle = true

    func refresh(read: @escaping Read, complete: @escaping @MainActor (Result<Int, Error>) -> Void) {
        let request = Request(id: UUID(), read: read, complete: complete)
        latest = request.id; pending = request
        active?.cancel()
        guard isIdle else { return }
        isIdle = false
        Task { await drain() }
    }
    func invalidate() { latest = nil; pending = nil; active?.cancel() }
    private func drain() async {
        while let request = pending {
            pending = nil
            let read = request.read
            let worker = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let count = try await read()
                try Task.checkCancellation()
                guard (0...SharedCaptureDisk.capacity).contains(count) else { throw SharedCaptureFailure("Saved sharing data needs attention.") }
                return count
            }
            active = worker
            let result = await worker.result
            active = nil
            if latest == request.id { request.complete(result) }
        }
        isIdle = true
    }
}
