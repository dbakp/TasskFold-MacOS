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
