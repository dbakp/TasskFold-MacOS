import Foundation

/// A preview is approval for one token and workspace; neither survives an input change.
struct TodoistImportFlow {
    struct Request {
        let id = UUID()
        let token: String
        let workspace: UUID
        let previewOnly: Bool
        let sourceAccount: String
        let supportsHeadings: Bool
        let headingApproval: JSON?
        var body: [String: JSON] {
            var value: [String: JSON] = ["userToken": .string(token), "preview": .bool(previewOnly), "stream": .bool(false), "sourceAccount": sourceAccount.isEmpty ? .null : .string(sourceAccount)]
            if supportsHeadings { value["capabilities"] = .array([.string("task_headings")]) }
            if let headingApproval { value["headingApproval"] = headingApproval }
            return value
        }
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
    var headingCount: Int { (preview?["headings"].object["roots"]?.integer ?? 0) + (preview?["headings"].object["subtasks"]?.integer ?? 0) }
    var headingImportAvailable: Bool { headingCount == 0 || preview?["headings"].object["available"] == .bool(true) }
    var canImport: Bool { !busy && preview != nil && headingImportAvailable }

    var canPreview: Bool { !busy && (16...512).contains(token.trimmingCharacters(in: .whitespacesAndNewlines).count) }
    var warnings: [String] { (preview ?? result)?["warnings"].list.map(\.text) ?? [] }
    mutating func updateToken(_ value: String) {
        guard !busy, value != token else { return }
        token = value; preview = nil; result = nil; previewWorkspace = nil; message = nil
    }
    mutating func begin(previewOnly: Bool, workspace: UUID, supportsHeadings: Bool = false) throws -> Request {
        guard canPreview else { throw AppFailure(message: "Enter your Todoist API token before previewing.") }
        if !previewOnly {
            guard previewWorkspace == workspace, preview != nil else { throw AppFailure(message: "Preview this import again before importing.") }
            guard headingImportAvailable, headingCount == 0 || supportsHeadings else { throw AppFailure(message: "This import contains headings. Keep this preview and use a supported workspace after heading import is enabled.") }

        }
        let request = Request(token: token.trimmingCharacters(in: .whitespacesAndNewlines), workspace: workspace, previewOnly: previewOnly, sourceAccount: previewOnly ? "" : preview!.string("sourceAccount"), supportsHeadings: supportsHeadings,
                              headingApproval: !previewOnly && preview?.fields["headings"] != nil ? .object(["roots": preview!["headings"].object["roots"] ?? .number(0), "subtasks": preview!["headings"].object["subtasks"] ?? .number(0)]) : nil)
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
        if request.previewOnly && request.supportsHeadings && row.fields["headings"] == nil {
            throw AppFailure(message: "The import service does not support heading review yet. Your source is unchanged; try again after the service is updated.")
        }
        if request.previewOnly, let headingInfo = row.fields["headings"] {
            let info = headingInfo.object
            guard info["version"] == .number(1), case .bool = info["available"],
                  ["roots", "subtasks"].allSatisfy({ key in
                      guard case .number(let n) = info[key] else { return false }
                      let bound = counts[key == "roots" ? "tasks" : "subtasks"]?.integer ?? 0
                      return n.isFinite && n >= 0 && n <= Double(bound) && n.rounded(.towardZero) == n
                  }), info["available"] != .bool(true) || request.supportsHeadings else {
                throw AppFailure(message: "Taskfold could not verify this heading preview. Preview again with a supported app.")
            }
        }
        if !request.previewOnly, let approval = request.headingApproval, (approval.object["roots"]?.integer ?? 0) + (approval.object["subtasks"]?.integer ?? 0) > 0 {
            guard row["formatVersion"] == .number(2), row["capabilities"] == .array([.string("task_headings")]) else {
                throw AppFailure(message: "Taskfold could not confirm the heading format. Your approved preview is kept for a safe retry.")
            }
        }
        active = nil
        if request.previewOnly { preview = row; previewWorkspace = workspace; return false }
        result = row; preview = nil; previewWorkspace = nil; token = ""; return true
    }
    mutating func fail(_ error: Error, request: Request, workspace: UUID) {
        guard active?.id == request.id else { return }
        guard request.workspace == workspace else { reset(); return }
        active = nil
        let transport = error as NSError
        if !request.previewOnly, transport.domain == NSURLErrorDomain,
           [URLError.networkConnectionLost.rawValue, URLError.timedOut.rawValue,
            URLError.notConnectedToInternet.rawValue].contains(transport.code) {
            message = "Taskfold couldn’t confirm the import. It may already have saved. Retry this import safely: previously imported items and your Taskfold edits are preserved."
        } else { message = error.localizedDescription }
        // A lost save response may have committed. Keep this exact approved source for retry.
    }
    mutating func reset() { token = ""; preview = nil; result = nil; previewWorkspace = nil; active = nil; message = nil }
    static func resultTitle(_ key: String) -> String {
        let suffix = key.hasSuffix("Skipped") ? "Skipped" : "Imported"
        let noun = String(key.dropLast(suffix.count)).capitalized
        return noun + (suffix == "Skipped" ? " already imported" : " imported")
    }
}


/// Explicit repair for old imported copies; literal Taskfold text never implies a type.
struct TodoistHeadingConversion: Identifiable, Sendable {
    let id = UUID()
    let captured: Record
    let sourceTitle: String
    init?(_ row: Record) {
        guard TaskKind(row) == .task,
              row["completed"] == .null || row["completed"] == .bool(false),
              row["completed_at"] == .null,
              row["source_metadata"].object["provider"] == .string("todoist"),
              case .string(let title)? = row["source_metadata"].object["original"]?.object["content"],
              title.hasPrefix("* "), !title.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .string(let current) = row["title"], !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        captured = row; sourceTitle = title
    }
    var canRemoveMarker: Bool { captured.title.hasPrefix("* ") && !captured.title.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var titleChangedSinceImport: Bool { !captured.title.utf8.elementsEqual(sourceTitle.utf8) }
    var removeMarkerByDefault: Bool { canRemoveMarker && !titleChangedSinceImport }
    /// A review binds the complete draft, including raw Unicode spelling and
    /// future fields. Iteration avoids imposing a new nesting limit on metadata.
    func matches(_ current: Record) -> Bool {
        var pending: [(JSON, JSON)] = [(.object(captured.fields), .object(current.fields))]
        while let (original, current) = pending.popLast() {
            switch (original, current) {
            case (.null, .null): break
            case (.bool(let a), .bool(let b)): if a != b { return false }
            case (.number(let a), .number(let b)): if a.bitPattern != b.bitPattern { return false }
            case (.string(let a), .string(let b)): if !a.utf8.elementsEqual(b.utf8) { return false }
            case (.array(let a), .array(let b)):
                guard a.count == b.count else { return false }
                pending.append(contentsOf: zip(a, b))
            case (.object(let a), .object(let b)):
                guard a.count == b.count else { return false }
                for (key, value) in a {
                    guard let index = b.index(forKey: key), key.utf8.elementsEqual(b[index].key.utf8) else { return false }
                    pending.append((value, b[index].value))
                }
            default: return false
            }
        }
        return true
    }
    func title(removingMarker: Bool) -> String { removingMarker && canRemoveMarker ? String(captured.title.dropFirst(2)) : captured.title }
    func applying(to current: Record, removingMarker: Bool, authoringEnabled: Bool) throws -> Record {
        guard authoringEnabled, matches(current), Self(current) != nil else {
            throw AppFailure(message: "This task or heading availability changed. Close this review and reopen it from the current task. Your work is unchanged.")
        }
        guard !removingMarker || canRemoveMarker else { throw AppFailure(message: "Keep the current title; it has no removable imported marker.") }
        var edited = try TaskKind.setting(current, heading: true)
        edited["title"] = .string(title(removingMarker: removingMarker))
        return edited
    }
}
