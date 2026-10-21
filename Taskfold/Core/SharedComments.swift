import Foundation

/// Authenticated conversation records never derive author or recipient identity from legacy text.
private enum SharedWire {
    static let maximumRevision: Int64 = 9_007_199_254_740_991
    static func id(_ value: JSON) -> String? { UUID(uuidString: value.text)?.uuidString.lowercased() }
    static func generation(_ value: JSON) -> Bool { id(value).map { $0 != "00000000-0000-0000-0000-000000000000" } ?? false }
    static func revision(_ value: JSON, zero: Bool = false) -> Int64? {
        guard let n = TaskActivity.integer(value), zero || n > 0 else { return nil }; return n
    }
    static func ids(_ value: JSON) -> [String]? {
        guard case .array(let raw) = value, raw.count <= 25 else { return nil }
        let values = raw.compactMap(id)
        guard values.count == raw.count else { return nil }; return values
    }
    static var invalidChange: AppFailure { AppFailure(message: "This saved conversation change cannot be sent. Review it before trying again.") }
    static var invalidReply: AppFailure { AppFailure(message: "This conversation response could not be verified. Refresh before trying again.") }
    static func reply(_ data: Data) throws -> Record {
        guard let row = try? JSONDecoder().decode(Record.self, from: data) else { throw invalidReply }; return row
    }
    static func acknowledged(_ row: Record, operation: String, expected: Int64, current: Int64) -> Int64? {
        guard id(row["operation_id"]) == operation, let ack = revision(row["acknowledged_revision"]), ack <= current,
              expected == 0 ? ack == 1 : (expected...min(maximumRevision, expected + 1)).contains(ack) else { return nil }
        return ack
    }
}

struct SharedComment: Identifiable, Equatable, Sendable {
    static let table = "task_comments"
    let row: Record
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?
    var id: String { row.id.lowercased() }
    var taskID: String { row.string("task_id").lowercased() }
    var taskGeneration: String { row.string("task_generation").lowercased() }
    var projectID: String { row.string("project_id").lowercased() }
    var authorID: String? { row["author_id"] == .null ? nil : row.string("author_id").lowercased() }
    var body: String { row.string("body") }
    var mentionIDs: [String] { row["mention_ids"].list.map { $0.text.lowercased() } }
    var revision: Int64 { SharedWire.revision(row["revision"])! }
    var isDeleted: Bool { deletedAt != nil }
    init?(_ row: Record) {
        let required: Set<String> = ["id", "task_id", "task_generation", "project_id", "author_id", "body", "mention_ids", "revision", "created_at", "updated_at", "deleted_at"]
        guard required.isSubset(of: Set(row.fields.keys)),
              ["id", "task_id", "task_generation", "project_id"].allSatisfy({ SharedWire.id(row[$0]) != nil }),
              SharedWire.generation(row["task_generation"]), row["author_id"] == .null || SharedWire.id(row["author_id"]) != nil,
              case .string(let body) = row["body"], body.utf8.count <= 16000, !body.unicodeScalars.contains(where: { $0.value == 0 }),
              let people = SharedWire.ids(row["mention_ids"]), Set(people).count == people.count,
              SharedWire.revision(row["revision"]) != nil,
              let created = TaskPlanning.instant(row.string("created_at")), let updated = TaskPlanning.instant(row.string("updated_at")),
              row["deleted_at"] == .null || TaskPlanning.instant(row.string("deleted_at")) != nil else { return nil }
        let deleted = TaskPlanning.instant(row.string("deleted_at"))
        guard deleted == nil ? !body.isEmpty : body.isEmpty && people.isEmpty else { return nil }
        self.row = row; createdAt = created; updatedAt = updated; deletedAt = deleted
    }
}

struct SharedMention: Identifiable, Equatable, Sendable {
    static let table = "task_mentions"
    let row: Record
    let createdAt: Date
    let readAt: Date?
    var id: String { row.id.lowercased() }
    var commentID: String { row.string("comment_id").lowercased() }
    var recipientID: String { row.string("recipient_id").lowercased() }
    var revision: Int64 { SharedWire.revision(row["revision"])! }
    var isRead: Bool { readAt != nil }
    init?(_ row: Record) {
        let required: Set<String> = ["id", "comment_id", "recipient_id", "revision", "created_at", "read_at"]
        guard required.isSubset(of: Set(row.fields.keys)), ["id", "comment_id", "recipient_id"].allSatisfy({ SharedWire.id(row[$0]) != nil }),
              SharedWire.revision(row["revision"]) != nil, let created = TaskPlanning.instant(row.string("created_at")),
              row["read_at"] == .null || TaskPlanning.instant(row.string("read_at")) != nil else { return nil }
        self.row = row; createdAt = created; readAt = TaskPlanning.instant(row.string("read_at"))
    }
}

/// Versioned durable intent. The raw envelope can be retained when a newer version is unsupported.
/// Only the explicit RPC arguments are sent; account, author names and legacy metadata cannot leak into writes.
struct SharedCommentChange: Codable, Equatable, Sendable {
    let record: Record
    var account: String { record.string("account") }
    var operationID: String { record.string("operation_id") }
    var commentID: String { record.string("comment_id") }
    var taskID: String { record.string("task_id") }
    var taskGeneration: String { record.string("task_generation") }
    var projectID: String { record.string("project_id") }
    var expectedRevision: Int64 { SharedWire.revision(record["expected_revision"], zero: true)! }
    var body: String { record.string("body") }
    var mentionIDs: [String] { record["mention_ids"].list.map(\.text) }
    var deleting: Bool { record["delete"].flag }
    init(account: String, taskID: String, taskGeneration: String, projectID: String, commentID: String = UUID().uuidString.lowercased(),
         expectedRevision: Int64 = 0, body: String, mentionIDs: [String] = [], deleting: Bool = false,
         operationID: String = UUID().uuidString.lowercased()) throws {
        try self.init(record: Record(["version": .number(1), "kind": .string("comment"), "account": .string(account),
            "operation_id": .string(operationID), "comment_id": .string(commentID), "task_id": .string(taskID),
            "task_generation": .string(taskGeneration), "project_id": .string(projectID), "expected_revision": .number(Double(expectedRevision)),
            "body": .string(body), "mention_ids": .array(mentionIDs.map(JSON.string)), "delete": .bool(deleting)]))
    }
    init(record raw: Record) throws {
        let required: Set<String> = ["version", "kind", "account", "operation_id", "comment_id", "task_id", "task_generation", "project_id", "expected_revision", "body", "mention_ids", "delete"]
        let keys = ["account", "operation_id", "comment_id", "task_id", "task_generation", "project_id"]
        guard Set(raw.fields.keys) == required, raw["version"] == .number(1), raw.string("kind") == "comment",
              keys.allSatisfy({ SharedWire.id(raw[$0]) != nil }), SharedWire.generation(raw["task_generation"]), let revision = SharedWire.revision(raw["expected_revision"], zero: true),
              case .bool(let deleting) = raw["delete"], case .string(let body) = raw["body"],
              body.utf8.count <= 16000, !body.unicodeScalars.contains(where: { $0.value == 0 }), let people = SharedWire.ids(raw["mention_ids"]),
              deleting ? revision > 0 && body.isEmpty && people.isEmpty : !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SharedWire.invalidChange }
        var normalized = raw
        for key in keys { normalized[key] = .string(SharedWire.id(raw[key])!) }
        normalized["mention_ids"] = .array(Set(people).sorted().map(JSON.string)); record = normalized
    }
    var payload: [String: JSON] {
        ["_operation_id": record["operation_id"], "_comment_id": record["comment_id"], "_task_id": record["task_id"],
         "_task_generation": record["task_generation"], "_project_id": record["project_id"], "_expected_revision": record["expected_revision"],
         "_body": record["body"], "_mentions": record["mention_ids"], "_delete": record["delete"]]
    }
    init(from decoder: Decoder) throws { try self.init(record: Record(from: decoder)) }
    func encode(to encoder: Encoder) throws { try record.encode(to: encoder) }
}

struct SharedMentionChange: Codable, Equatable, Sendable {
    let record: Record
    var account: String { record.string("account") }
    var operationID: String { record.string("operation_id") }
    var mentionID: String { record.string("mention_id") }
    var commentID: String { record.string("comment_id") }
    var expectedRevision: Int64 { SharedWire.revision(record["expected_revision"])! }
    var read: Bool { record["read"].flag }
    init(mention: SharedMention, account: String, read: Bool, operationID: String = UUID().uuidString.lowercased()) throws {
        guard mention.recipientID == UUID(uuidString: account)?.uuidString.lowercased() else { throw SharedWire.invalidChange }
        try self.init(record: Record(["version": .number(1), "kind": .string("mention-read"), "account": .string(account), "operation_id": .string(operationID),
            "mention_id": .string(mention.id), "comment_id": .string(mention.commentID), "expected_revision": .number(Double(mention.revision)), "read": .bool(read)]))
    }
    init(record raw: Record) throws {
        let required: Set<String> = ["version", "kind", "account", "operation_id", "mention_id", "comment_id", "expected_revision", "read"]
        let keys = ["account", "operation_id", "mention_id", "comment_id"]
        guard Set(raw.fields.keys) == required, raw["version"] == .number(1), raw.string("kind") == "mention-read",
              keys.allSatisfy({ SharedWire.id(raw[$0]) != nil }), SharedWire.revision(raw["expected_revision"]) != nil,
              case .bool = raw["read"] else { throw SharedWire.invalidChange }
        var normalized = raw; for key in keys { normalized[key] = .string(SharedWire.id(raw[key])!) }; record = normalized
    }
    var payload: [String: JSON] {
        ["_operation_id": record["operation_id"], "_mention_id": record["mention_id"], "_expected_revision": record["expected_revision"], "_read": record["read"]]
    }
    init(from decoder: Decoder) throws { try self.init(record: Record(from: decoder)) }
    func encode(to encoder: Encoder) throws { try record.encode(to: encoder) }
}

enum SharedCommentStatus: String, Sendable { case saved, conflict, unavailable, archived, forbidden; case recipientsChanged = "recipients_changed" }
struct SharedCommentReply: Sendable {
    let status: SharedCommentStatus
    let current: SharedComment?
    let acknowledgedRevision: Int64?
    init(data: Data, change: SharedCommentChange) throws {
        let row = try SharedWire.reply(data)
        guard let status = SharedCommentStatus(rawValue: row.string("status")) else { throw SharedWire.invalidReply }
        var current: SharedComment?, ack: Int64?
        if status == .saved || status == .conflict {
            guard case .object(let fields) = row["current"], let value = SharedComment(Record(fields)),
                  value.id == change.commentID, value.taskID == change.taskID, value.taskGeneration == change.taskGeneration, value.projectID == change.projectID,
                  change.deleting || value.authorID == change.account else { throw SharedWire.invalidReply }
            current = value
            if status == .saved {
                guard let revision = SharedWire.acknowledged(row, operation: change.operationID, expected: change.expectedRevision, current: value.revision),
                      !change.deleting || value.isDeleted else { throw SharedWire.invalidReply }
                if value.revision == revision, !change.deleting {
                    guard !value.isDeleted, value.body == change.body, Set(value.mentionIDs) == Set(change.mentionIDs) else { throw SharedWire.invalidReply }
                }
                ack = revision
            }
        } else if row["current"] != .null { throw SharedWire.invalidReply }
        self.status = status; self.current = current; acknowledgedRevision = ack
    }
}
struct SharedMentionReply: Sendable {
    let status: SharedCommentStatus
    let current: SharedMention?
    let acknowledgedRevision: Int64?
    init(data: Data, change: SharedMentionChange) throws {
        let row = try SharedWire.reply(data)
        guard let status = SharedCommentStatus(rawValue: row.string("status")), [.saved, .conflict, .unavailable].contains(status) else { throw SharedWire.invalidReply }
        var current: SharedMention?, ack: Int64?
        if status == .saved || status == .conflict {
            guard case .object(let fields) = row["current"], let value = SharedMention(Record(fields)), value.id == change.mentionID,
                  value.commentID == change.commentID, value.recipientID == change.account else { throw SharedWire.invalidReply }
            current = value
            if status == .saved {
                guard let revision = SharedWire.acknowledged(row, operation: change.operationID, expected: change.expectedRevision, current: value.revision),
                      value.revision > revision || value.isRead == change.read else { throw SharedWire.invalidReply }
                ack = revision
            }
        } else if row["current"] != .null { throw SharedWire.invalidReply }
        self.status = status; self.current = current; acknowledgedRevision = ack
    }
}

extension Backend {
    func writeSharedComment(_ change: SharedCommentChange) async throws -> SharedCommentReply {
        guard session?.user.id == change.account else { throw CancellationError() }
        let data = try await request("/rest/v1/rpc/taskfold_write_comment", method: "POST", body: change.payload, expectedAccount: change.account)
        return try SharedCommentReply(data: data, change: change)
    }
    func markSharedMention(_ change: SharedMentionChange) async throws -> SharedMentionReply {
        guard session?.user.id == change.account else { throw CancellationError() }
        let data = try await request("/rest/v1/rpc/taskfold_mark_mention", method: "POST", body: change.payload, expectedAccount: change.account)
        return try SharedMentionReply(data: data, change: change)
    }
}
