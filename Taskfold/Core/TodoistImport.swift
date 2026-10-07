import Foundation

/// A preview is approval for one token and workspace; neither survives an input change.
struct TodoistImportFlow {
    struct Request {
        let id = UUID()
        let token: String
        let workspace: UUID
        let previewOnly: Bool
        let sourceAccount: String
        var body: [String: JSON] { ["userToken": .string(token), "preview": .bool(previewOnly), "stream": .bool(false), "sourceAccount": sourceAccount.isEmpty ? .null : .string(sourceAccount)] }
    }
    static let countKeys = ["projects", "sections", "labels", "tasks", "subtasks", "comments"]
    static let resultKeys = ["projectsImported", "sectionsImported", "labelsImported", "tasksImported", "subtasksImported", "commentsImported", "projectsSkipped", "sectionsSkipped", "labelsSkipped", "tasksSkipped"]
    private(set) var token = ""
    private(set) var preview: Record?
    private(set) var result: Record?
    private(set) var active: Request?
    private(set) var message: String?
    private var previewWorkspace: UUID?
    var busy: Bool { active != nil }
    var canPreview: Bool { !busy && (16...512).contains(token.trimmingCharacters(in: .whitespacesAndNewlines).count) }
    var warnings: [String] { (preview ?? result)?["warnings"].list.map(\.text) ?? [] }
    mutating func updateToken(_ value: String) {
        guard !busy, value != token else { return }
        token = value; preview = nil; result = nil; previewWorkspace = nil; message = nil
    }
    mutating func begin(previewOnly: Bool, workspace: UUID) throws -> Request {
        guard canPreview else { throw AppFailure(message: "Enter your Todoist API token before previewing.") }
        if !previewOnly {
            guard previewWorkspace == workspace, preview != nil else { throw AppFailure(message: "Preview this import again before importing.") }
        }
        let request = Request(token: token.trimmingCharacters(in: .whitespacesAndNewlines), workspace: workspace, previewOnly: previewOnly, sourceAccount: previewOnly ? "" : preview!.string("sourceAccount"))
        active = request; message = nil
        if previewOnly { preview = nil; result = nil; previewWorkspace = nil }
        return request
    }
    /// Returns true only for a validated import receipt in the originating workspace.
    mutating func accept(_ row: Record, request: Request, workspace: UUID) throws -> Bool {
        guard active?.id == request.id else { return false }
        guard request.workspace == workspace else {
            reset(); message = "The workspace changed. Preview the import again."; return false
        }
        guard case .string(let account) = row["sourceAccount"], !account.isEmpty, account.count <= 200,
              case .array(let warnings) = row["warnings"], warnings.allSatisfy({ if case .string = $0 { return true }; return false }) else {
            throw AppFailure(message: "Taskfold could not verify the import response. Preview and retry safely.")
        }
        let keys = request.previewOnly ? Self.countKeys : Self.resultKeys
        let counts = request.previewOnly ? row["counts"].object : row.fields
        guard keys.allSatisfy({ key in
            guard case .number(let n) = counts[key] else { return false }
            return n.isFinite && n >= 0 && n <= 1_000_000_000 && n.rounded(.towardZero) == n
        }), request.previewOnly ? row["preview"].flag : (row["success"].flag && account == request.sourceAccount) else {
            throw AppFailure(message: "Taskfold did not confirm the import. Preview and retry safely using the same account.")
        }
        active = nil
        if request.previewOnly { preview = row; previewWorkspace = workspace; return false }
        result = row; preview = nil; previewWorkspace = nil; token = ""; return true
    }
    mutating func fail(_ error: Error, request: Request, workspace: UUID) {
        guard active?.id == request.id else { return }
        guard request.workspace == workspace else { reset(); return }
        active = nil; message = error.localizedDescription
        // A lost save response may have committed. Keep this exact approved source for retry.
    }
    mutating func reset() { token = ""; preview = nil; result = nil; previewWorkspace = nil; active = nil; message = nil }
    static func resultTitle(_ key: String) -> String {
        let suffix = key.hasSuffix("Skipped") ? "Skipped" : "Imported"
        let noun = String(key.dropLast(suffix.count)).capitalized
        return noun + (suffix == "Skipped" ? " already imported" : " imported")
    }
}
