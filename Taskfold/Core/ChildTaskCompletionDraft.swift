import Foundation

/// An immutable, account-bound completion intent. This is a review value, not
/// mutation authority: only a dedicated server command may apply or certify it.
/// No parent tree, task title, note or unrelated child fields are persisted here.
struct ChildTaskCompletionDraft: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Action: String, Codable, Sendable { case complete, reopen }
    static let cohort: Set<String> = ["completed", "completed_at", "is_heading", TeamChecklist.key]
    static var invalid: AppFailure { AppFailure(message: "Review this child’s completion again. Your saved work is unchanged.") }
    let account: String
    let origin: String
    let workspace: UUID
    let session: UUID
    let access: UUID
    let body: [String: JSON]
    var id: String { body["request_id"]!.text }
    var action: Action { Action(rawValue: body["action"]!.text)! }
    var desiredCompleted: Bool { action == .complete }
    var description: String { "Private child completion intent" }
    var debugDescription: String { description }

    init(read: ChildTaskRecordRead, key: String, action: Action, requestID: UUID = UUID()) throws {
        guard let node = read.nodes[key] else { throw Self.invalid }
        let baseline = node.fields.filter { Self.cohort.contains($0.key) }
        let completed = try Self.completed(baseline)
        guard completed != (action == .complete) else { throw Self.invalid }
        try self.init(account: read.context.account, origin: read.context.origin,
                      workspace: read.context.workspace, session: read.context.session, access: read.context.access,
                      body: ["protocol": .number(1), "account": .string(read.context.account),
                             "request_id": .string(requestID.uuidString.lowercased()),
                             "task_id": .string(read.context.root.id), "task_generation": read.context.root["task_generation"],
                             "project_id": read.context.root["project_id"], "node_key": .string(node.key),
                             "incarnation": .string(node.incarnation), "revision": .number(node.revision),
                             "action": .string(action.rawValue), "baseline": .object(baseline)])
    }

    private init(account: String, origin: String, workspace: UUID, session: UUID, access: UUID, body: [String: JSON]) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard origin.utf8.count <= 2048,
              Set(body.keys) == Set(["protocol", "account", "request_id", "task_id", "task_generation", "project_id", "node_key", "incarnation", "revision", "action", "baseline"]),
              body["protocol"] == .number(1), body["account"] == .string(account),
              case .string(let action)? = body["action"], let action = Action(rawValue: action),
              case .string(let key)? = body["node_key"], !key.isEmpty, key.utf8.count <= 128,
              key.utf8.elementsEqual(key.precomposedStringWithCanonicalMapping.utf8),
              case .object(let baseline)? = body["baseline"], Set(baseline.keys).isSubset(of: Self.cohort),
              try Self.completed(baseline) != (action == .complete) else { throw Self.invalid }
        for key in ["request_id", "task_id", "incarnation"] { _ = try TeamOrganizationValue.id(body[key]) }
        _ = try TeamProjectValue.optionalID(body["task_generation"])
        _ = try TeamProjectValue.optionalID(body["project_id"])
        guard try TeamProjectValue.revision(body["revision"]) < 9_007_199_254_740_991 else { throw Self.invalid }
        guard try JSONEncoder().encode(body).count <= 4096 else { throw Self.invalid }
        self.account = account; self.origin = origin; self.workspace = workspace
        self.session = session; self.access = access; self.body = body
    }

    /// A changed general revision can be a disjoint edit. A valid completion
    /// token proves its cohort did not cycle; legacy rows without a token need
    /// the exact captured revision until their server adoption is implemented.
    func review(_ read: ChildTaskRecordRead) throws {
        let context = read.context
        guard account == context.account, origin == context.origin,
              workspace == context.workspace, session == context.session, access == context.access,
              body["task_id"] == .string(context.root.id), body["task_generation"] == context.root["task_generation"],
              body["project_id"] == context.root["project_id"], let node = read.nodes[body["node_key"]!.text],
              body["incarnation"] == .string(node.incarnation), case .number(let revision)? = body["revision"],
              node.revision >= revision else { throw Self.invalid }
        let current = node.fields.filter { Self.cohort.contains($0.key) }
        _ = try Self.completed(current)
        guard AuthoredValueComparison.exactJSON(.object(current), body["baseline"]!),
              current[TeamChecklist.key] != nil || node.revision == revision else { throw Self.invalid }
    }

    private static func completed(_ fields: [String: JSON]) throws -> Bool {
        guard TaskKind.mayComplete(Record(fields)) else { throw invalid }
        let completed: Bool
        switch fields["completed"] {
        case nil: completed = false
        case .bool(let value)?: completed = value
        default: throw invalid
        }
        if completed {
            guard case .string(let timestamp)? = fields["completed_at"], TaskPlanning.instant(timestamp) != nil else { throw invalid }
        } else {
            guard fields["completed_at"] == nil || fields["completed_at"] == .null else { throw invalid }
        }
        if let value = fields[TeamChecklist.key] {
            guard let token = TeamChecklist.token(value), token.version < TeamChecklist.maximumVersion else { throw invalid }
        }
        return completed
    }

    private enum CodingKeys: String, CodingKey { case account, origin, workspace, session, access, body }
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: AnyKey.self)
        guard Set(keys.allKeys.map(\.stringValue)) == Set(["account", "origin", "workspace", "session", "access", "body"]) else { throw Self.invalid }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(c.allKeys) == Set([.account, .origin, .workspace, .session, .access, .body]) else { throw Self.invalid }
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin),
                      workspace: c.decode(UUID.self, forKey: .workspace), session: c.decode(UUID.self, forKey: .session),
                      access: c.decode(UUID.self, forKey: .access), body: c.decode([String: JSON].self, forKey: .body))
    }
}
