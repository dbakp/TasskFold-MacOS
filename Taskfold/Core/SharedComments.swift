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

/// Device-local evidence for a queued mention choice. This is not a permission
/// grant or an RPC payload; it can explain an absent cached discussion only.
struct MentionRecoveryContext: Codable, Equatable, Sendable {
    let version: Int
    let origin: String
    let intent: Record
    let comment: Record
    let mention: Record
    static let field = "mention_recovery"
    private static let commentKeys: Set<String> = ["id", "task_id", "task_generation", "project_id", "author_id", "body", "mention_ids", "revision", "created_at", "updated_at", "deleted_at"]
    private static let mentionKeys: Set<String> = ["id", "comment_id", "recipient_id", "revision", "created_at", "read_at"]
    func validate(_ row: Record) throws {
        let change = try SharedMentionChange(record: intent)
        try TeamOrganizationValue.scope(account: change.account, origin: origin)
        guard version == 1, row.id == change.operationID, row.string("account") == change.account,
              row["intent"] == .object(intent.fields), Set(comment.fields.keys) == Self.commentKeys,
              Set(mention.fields.keys) == Self.mentionKeys,
              let thread = SharedComment(comment), let marker = SharedMention(mention),
              thread.id == change.commentID, marker.id == change.mentionID,
              marker.commentID == thread.id, marker.recipientID == change.account,
              marker.revision == change.expectedRevision,
              try JSONEncoder().encode(self).count <= 64_000 else { throw SharedWire.invalidChange }
    }
    static func saved(in row: Record) throws -> Self? {
        guard let value = row.fields[field] else { return nil }
        guard Set(value.object.keys) == ["version", "origin", "intent", "comment", "mention"] else { throw SharedWire.invalidChange }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 64_000 else { throw SharedWire.invalidChange }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate(row); return result
    }
    static func capturing(_ row: Record, snapshot: Snapshot, origin: String) -> Self? {
        guard let change = ConversationOutbox.mention(row),
              let cache = snapshot.teamWorkspace, cache.boundary.belongs(account: change.account, origin: origin) else { return nil }
        let comments = (snapshot.tables[SharedComment.table] ?? []).filter { $0.id.lowercased() == change.commentID }
        let mentions = (snapshot.tables[SharedMention.table] ?? []).filter { $0.id.lowercased() == change.mentionID }
        guard comments.count == 1, mentions.count == 1, let thread = SharedComment(comments[0]),
              cache.knownTasks.contains(thread.taskID), cache.boundary.projects[thread.projectID] != nil,
              (snapshot.tables["tasks"] ?? []).filter({ $0.id == thread.taskID }).count == 1,
              (snapshot.tables["tasks"] ?? []).filter({ $0.id == thread.taskID && $0.string("task_generation") == thread.taskGeneration && $0.string("project_id") == thread.projectID }).count == 1 else { return nil }
        let result = Self(version: 1, origin: origin, intent: Record(row["intent"].object),
            comment: Record(comments[0].fields.filter { commentKeys.contains($0.key) }),
            mention: Record(mentions[0].fields.filter { mentionKeys.contains($0.key) }))
        guard (try? result.validate(row)) != nil else { return nil }; return result
    }
    /// Only this analysis copy gains missing frozen rows. The live cache never
    /// receives a historical comment/mention or a synthetic access boundary.
    static func resolving(_ original: Snapshot, account: String, origin: String, affected: Set<String>, tasks: [Record]) throws -> Snapshot {
        var result = original
        for row in original.tables[ConversationOutbox.table] ?? [] {
            guard let context = try saved(in: row), let thread = SharedComment(context.comment) else { continue }
            guard affected.contains(thread.taskID) else { continue }
            guard context.origin == origin, row.string("account") == account,
                  tasks.contains(where: { $0.id == thread.taskID && $0.string("task_generation") == thread.taskGeneration && $0.string("project_id") == thread.projectID }) else { throw TeamTaskBatch.conflict }
            for (table, frozen) in [(SharedComment.table, context.comment), (SharedMention.table, context.mention)] {
                let current = (original.tables[table] ?? []).filter { $0.id.lowercased() == frozen.id.lowercased() }
                guard current.count <= 1 else { throw TeamTaskBatch.conflict }
                if let live = current.first {
                    if table == SharedComment.table {
                        guard let value = SharedComment(live), value.taskID == thread.taskID, value.taskGeneration == thread.taskGeneration, value.projectID == thread.projectID else { throw TeamTaskBatch.conflict }
                    } else {
                        guard let value = SharedMention(live), let captured = SharedMention(frozen),
                              value.commentID == captured.commentID, value.recipientID == captured.recipientID,
                              value.revision >= captured.revision else { throw TeamTaskBatch.conflict }
                    }
                } else {
                    // Distinct queued markers may share a comment. They must
                    // agree on its task incarnation, even if the text evolved.
                    if let previous = result.tables[table]?.first(where: { $0.id == frozen.id }) {
                        guard table == SharedComment.table, let value = SharedComment(previous), value.taskID == thread.taskID,
                              value.taskGeneration == thread.taskGeneration, value.projectID == thread.projectID else { throw TeamTaskBatch.conflict }
                    } else { result.tables[table, default: []].append(frozen) }
                }
            }
        }
        // Metadata contains task references; the existing typed edge analysis
        // must inspect the intent itself after the frozen rows are validated.
        result.tables[ConversationOutbox.table] = original.tables[ConversationOutbox.table]?.map { row in var value = row; value.fields.removeValue(forKey: field); return value }
        return result
    }
}

/// Separate from task mutations: a blocked conversation never discards or rewrites its authored intent.
enum ConversationOutbox {
    static let table = "_conversation_outbox"
    static let viewsTable = "_conversation_views"
    static let states: Set<String> = ["pending", "draft", "conflict", "unavailable", "archived", "forbidden", "recipients_changed"]
    static func rows(_ snapshot: Snapshot, account: String) -> [Record] {
        (snapshot.tables[table] ?? []).filter { $0.string("account").lowercased() == account.lowercased() }
    }
    static func comment(_ row: Record) -> SharedCommentChange? { try? SharedCommentChange(record: Record(row["intent"].object)) }
    static func mention(_ row: Record) -> SharedMentionChange? { try? SharedMentionChange(record: Record(row["intent"].object)) }
    static func valid(_ row: Record) -> Bool {
        guard row["version"] == .number(1), UUID(uuidString: row.id) != nil, states.contains(row.string("state")),
              TaskPlanning.instant(row.string("created_at")) != nil else { return false }
        if row.fields[MentionRecoveryContext.field] != nil, (try? MentionRecoveryContext.saved(in: row)) == nil { return false }
        if let value = comment(row) { return row.id == value.operationID && row.string("account") == value.account }
        if let value = mention(row) { return row.id == value.operationID && row.string("account") == value.account }
        return false
    }
    static func enqueue(_ intent: Record, into snapshot: inout Snapshot, now: Date = Date(), origin: String? = nil) throws {
        var row = Record(["id": intent["operation_id"], "version": .number(1), "account": intent["account"], "intent": .object(intent.fields), "state": .string("pending"), "created_at": .string(TaskActivity.stamp(now))])
        if let origin, let captured = MentionRecoveryContext.capturing(row, snapshot: snapshot, origin: origin) {
            row[MentionRecoveryContext.field] = try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(captured))
        }
        guard valid(row) else { throw AppFailure(message: "This conversation change needs a valid account and identity.") }
        let existing = snapshot.tables[table] ?? []
        if let previous = existing.first(where: { $0.id == row.id }) {
            guard previous["intent"] == row["intent"], previous["account"] == row["account"] else { throw AppFailure(message: "This attempt no longer matches its saved change.") }; return
        }
        let entity = comment(row)?.commentID ?? mention(row)?.mentionID
        guard !existing.contains(where: { $0.string("account") == row.string("account") && ($0["intent"].object["kind"] == intent["kind"]) && (comment($0)?.commentID ?? mention($0)?.mentionID) == entity }) else {
            throw AppFailure(message: "Review the saved change for this conversation first.")
        }
        snapshot.tables[table, default: []].append(row)
    }
    static func remove(_ id: String, account: String, from snapshot: inout Snapshot) {
        snapshot.tables[table]?.removeAll { $0.id == id && $0.string("account") == account }
    }
    static func setState(_ id: String, account: String, state: String, in snapshot: inout Snapshot) {
        guard states.contains(state), let i = snapshot.tables[table]?.firstIndex(where: { $0.id == id && $0.string("account") == account }) else { return }
        snapshot.tables[table]![i]["state"] = .string(state)
    }
    static func apply(_ reply: SharedCommentReply, change: SharedCommentChange, to snapshot: inout Snapshot) {
        guard rows(snapshot, account: change.account).contains(where: { $0.id == change.operationID && comment($0) == change }) else { return }
        if let current = reply.current { ConversationCache.upsert(current.row, table: SharedComment.table, in: &snapshot) }
        if reply.status == .saved { remove(change.operationID, account: change.account, from: &snapshot) }
        else { setState(change.operationID, account: change.account, state: reply.status.rawValue, in: &snapshot) }
    }
    static func apply(_ reply: SharedMentionReply, change: SharedMentionChange, to snapshot: inout Snapshot) {
        guard rows(snapshot, account: change.account).contains(where: { $0.id == change.operationID && mention($0) == change }) else { return }
        if let current = reply.current { ConversationCache.upsert(current.row, table: SharedMention.table, in: &snapshot) }
        // Read-state conflicts use the verified newer state; no authored content is discarded.
        remove(change.operationID, account: change.account, from: &snapshot)
    }
}

enum ConversationCache {
    static func upsert(_ incoming: Record, table: String, in snapshot: inout Snapshot) {
        guard (table == SharedComment.table && SharedComment(incoming) != nil) || (table == SharedMention.table && SharedMention(incoming) != nil) else { return }
        let revision = TaskActivity.integer(incoming["revision"]) ?? 0
        if let i = snapshot.tables[table]?.firstIndex(where: { $0.id.lowercased() == incoming.id.lowercased() }) {
            let old = snapshot.tables[table]![i], prior = TaskActivity.integer(old["revision"]) ?? 0
            guard revision >= prior else { return }
            var row = incoming
            // Account deletion can clear attribution without incrementing the comment revision.
            if table == SharedComment.table, revision == prior, old["author_id"] == .null { row["author_id"] = .null }
            snapshot.tables[table]![i] = row
        } else { snapshot.tables[table, default: []].append(incoming) }
    }
    static func accessible(_ comment: SharedComment, snapshot: Snapshot) -> Record? {
        guard snapshot.tables["projects"]?.contains(where: { $0.id.lowercased() == comment.projectID }) == true else { return nil }
        return snapshot.tables["tasks"]?.first { $0.id.lowercased() == comment.taskID && $0.string("task_generation").lowercased() == comment.taskGeneration && $0.string("project_id").lowercased() == comment.projectID }
    }
    static func prune(_ snapshot: inout Snapshot) {
        guard snapshot.tables[SharedComment.table] != nil || snapshot.tables[SharedMention.table] != nil else { return }
        let priorMentions = snapshot.tables[SharedMention.table]?.count ?? 0
        let before = snapshot.tables[SharedComment.table] ?? []
        snapshot.tables[SharedComment.table] = before.filter { row in
            guard let value = SharedComment(row) else { return true } // Unsupported cache records remain recoverable, never rendered.
            return accessible(value, snapshot: snapshot) != nil
        }
        let ids = Set((snapshot.tables[SharedComment.table] ?? []).compactMap { SharedComment($0) }.filter { !$0.isDeleted }.map(\.id))
        snapshot.tables[SharedMention.table]?.removeAll { row in
            guard let mention = SharedMention(row) else { return false }
            return !ids.contains(mention.commentID)
        }
        if before.count != (snapshot.tables[SharedComment.table]?.count ?? 0) || priorMentions != (snapshot.tables[SharedMention.table]?.count ?? 0) {
            snapshot.tables[ConversationOutbox.viewsTable]?.removeAll { $0.id.hasPrefix("inbox") || $0.id == "summary" }
        }
    }
}

/// Restore as historical task content only. Never insert authenticated rows, replay receipts or send mentions.
enum ConversationArchive {
    static func comments(task: Record, tables: [String: [Record]]) -> [JSON] {
        var values = task["comments"].list
        var ids = Set(values.compactMap { $0.object["id"]?.text })
        func append(_ fields: [String: JSON], archiveKey: String) {
            guard !values.contains(where: { $0.object[archiveKey] == fields[archiveKey] }) else { return }
            var fields = fields; let base = fields["id"]!.text; var id = base; var suffix = 1
            while !ids.insert(id).inserted { id = base + "-" + String(suffix); suffix += 1 }
            fields["id"] = .string(id); values.append(.object(fields))
        }
        for row in tables[SharedComment.table] ?? [] {
            guard let comment = SharedComment(row), !comment.isDeleted, comment.taskID == task.id.lowercased(),
                  comment.taskGeneration == task.string("task_generation").lowercased(), comment.projectID == task.string("project_id").lowercased() else { continue }
            let id = "shared-archive-" + comment.id
            append(["id": .string(id), "text": .string(comment.body), "authorName": .string("Archived shared comment"),
                "authorId": comment.authorID.map(JSON.string) ?? .null, "createdAt": row["created_at"], "sharedCommentArchive": .object(row.fields)], archiveKey: "sharedCommentArchive")
        }
        for row in tables[ConversationOutbox.table] ?? [] {
            guard let change = ConversationOutbox.comment(row), !change.deleting, change.taskID == task.id.lowercased(),
                  change.taskGeneration == task.string("task_generation").lowercased(), change.projectID == task.string("project_id").lowercased() else { continue }
            let id = "unsent-archive-" + change.operationID
            append(["id": .string(id), "text": .string(change.body), "authorName": .string("Unsent comment draft"),
                "createdAt": row["created_at"], "sharedDraftArchive": row["intent"]], archiveKey: "sharedDraftArchive")
        }
        return values
    }
}

struct ConversationCursor: Equatable, Sendable {
    let createdAt: String
    let id: String
    init?(_ row: Record) {
        guard TaskPlanning.instant(row.string("created_at")) != nil, let id = SharedWire.id(row["id"]) else { return nil }
        createdAt = row.string("created_at"); self.id = id
    }
    var document: JSON { .object(["id": .string(id), "created_at": .string(createdAt)]) }
}
struct ConversationPage: Sendable {
    let rows: [Record]
    let cursor: ConversationCursor?
    var hasMore: Bool { rows.count == 50 }
}
extension Backend {
    private func conversationPath(_ table: String, filters: [URLQueryItem], cursor: ConversationCursor? = nil) -> String {
        var parts = URLComponents(); parts.path = "/rest/v1/" + table
        parts.queryItems = [URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "order", value: "created_at.desc,id.desc"), URLQueryItem(name: "limit", value: "50")] + filters
        if let cursor {
            parts.queryItems?.append(URLQueryItem(name: "or", value: "(created_at.lt.\(cursor.createdAt),and(created_at.eq.\(cursor.createdAt),id.lt.\(cursor.id)))"))
        }
        return parts.path + "?" + (parts.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }
    func sharedCommentsPage(task: Record, account: String, cursor: ConversationCursor? = nil) async throws -> ConversationPage {
        guard session?.user.id == account else { throw CancellationError() }
        guard let taskID = SharedWire.id(task["id"]), let generation = SharedWire.id(task["task_generation"]), let project = SharedWire.id(task["project_id"]) else { throw SharedWire.invalidChange }
        let path = conversationPath(SharedComment.table, filters: [URLQueryItem(name: "task_id", value: "eq." + taskID), URLQueryItem(name: "task_generation", value: "eq." + generation), URLQueryItem(name: "project_id", value: "eq." + project)], cursor: cursor)
        let data = try await request(path, expectedAccount: account)
        let rows = try JSONDecoder().decode([Record].self, from: data)
        guard rows.count <= 50, Set(rows.map(\.id)).count == rows.count, rows.allSatisfy({ row in
            guard let value = SharedComment(row) else { return false }; return value.taskID == taskID && value.taskGeneration == generation && value.projectID == project
        }) else { throw SharedWire.invalidReply }
        let next = rows.last.flatMap(ConversationCursor.init); guard next == nil || next != cursor else { throw SharedWire.invalidReply }
        return ConversationPage(rows: rows, cursor: next)
    }
    func sharedMentionsPage(account: String, cursor: ConversationCursor? = nil, unreadOnly: Bool = false) async throws -> ConversationPage {
        guard session?.user.id == account else { throw CancellationError() }
        guard UUID(uuidString: account) != nil else { throw SharedWire.invalidChange }
        var filters = [URLQueryItem(name: "recipient_id", value: "eq." + account)]
        if unreadOnly { filters.append(URLQueryItem(name: "read_at", value: "is.null")) }
        let data = try await request(conversationPath(SharedMention.table, filters: filters, cursor: cursor), expectedAccount: account)
        let rows = try JSONDecoder().decode([Record].self, from: data)
        guard rows.count <= 50, Set(rows.map(\.id)).count == rows.count, rows.allSatisfy({ row in SharedMention(row).map { $0.recipientID == account && (!unreadOnly || !$0.isRead) } == true }) else { throw SharedWire.invalidReply }
        let next = rows.last.flatMap(ConversationCursor.init); guard next == nil || next != cursor else { throw SharedWire.invalidReply }
        return ConversationPage(rows: rows, cursor: next)
    }
    func sharedComments(ids: [String], account: String) async throws -> [Record] {
        guard session?.user.id == account else { throw CancellationError() }
        guard ids.count <= 50, ids.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw SharedWire.invalidChange }
        if ids.isEmpty { return [] }
        let path = "/rest/v1/task_comments?select=*&id=in.(" + Set(ids.map { $0.lowercased() }).sorted().joined(separator: ",") + ")&limit=50"
        let data = try await request(path, expectedAccount: account), rows = try JSONDecoder().decode([Record].self, from: data)
        let requested = Set(ids.map { $0.lowercased() })
        guard rows.count <= 50, Set(rows.map(\.id)).count == rows.count, rows.allSatisfy({ SharedComment($0).map { requested.contains($0.id) } == true }) else { throw SharedWire.invalidReply }
        return rows
    }
}

struct ConversationSummary: Equatable, Sendable {
    let total: Int
    let unread: Int
    init(_ row: Record) throws {
        guard let total = TaskActivity.integer(row["total"]), let unread = TaskActivity.integer(row["unread"]), unread <= total,
              let count = Int(exactly: total), let pending = Int(exactly: unread) else { throw SharedWire.invalidReply }
        self.total = count; self.unread = pending
    }
}
extension Backend {
    func sharedMentionsSummary(account: String) async throws -> ConversationSummary {
        guard session?.user.id == account else { throw CancellationError() }
        let data = try await request("/rest/v1/rpc/taskfold_mentions_summary", method: "POST", body: [:], expectedAccount: account)
        return try ConversationSummary(SharedWire.reply(data))
    }
}

/// Explicit review/export only. These cached rows explain a saved read marker;
/// they never become authenticated rows or newly queued conversation commands.
enum ConversationRecoveryExport {
    static func context(_ rows: [Record], snapshot: Snapshot) -> [JSON] {
        let changes = rows.compactMap(ConversationOutbox.mention)
        let mentionIDs = Set(changes.map(\.mentionID)), commentIDs = Set(changes.map(\.commentID))
        let frozen = rows.compactMap { try? MentionRecoveryContext.saved(in: $0) }
        return [(SharedComment.table, commentIDs), (SharedMention.table, mentionIDs)].flatMap { table, ids in
            ids.sorted().compactMap { id -> JSON? in
                if let live = snapshot.tables[table]?.first(where: { $0.id.lowercased() == id }) {
                    return .object(["table": .string(table), "row": .object(live.fields)])
                }
                let row = frozen.map { table == SharedComment.table ? $0.comment : $0.mention }.first { $0.id.lowercased() == id }
                return row.map { .object(["table": .string(table), "row": .object($0.fields), "source": .string("captured")]) }
            }
        }
    }
    static func text(_ rows: [Record], snapshot: Snapshot) -> [String] {
        rows.compactMap { row in
            if let comment = ConversationOutbox.comment(row) { return comment.deleting ? "Comment marked for deletion: " + comment.body : "Comment draft: " + comment.body }
            guard let mention = ConversationOutbox.mention(row) else { return nil }
            let comment = (snapshot.tables[SharedComment.table] ?? []).compactMap(SharedComment.init).first { $0.id == mention.commentID }
            let saved = (try? MentionRecoveryContext.saved(in: row)).flatMap { SharedComment($0.comment) }
            let detail = comment.map { $0.isDeleted ? "Deleted comment" : $0.body } ?? saved.map { "Saved comment: " + ($0.isDeleted ? "Deleted comment" : $0.body) } ?? mention.commentID
            return (mention.read ? "Mention marked read: " : "Mention marked unread: ") + detail + "\nSaved for review only; this read state will not be sent automatically."
        }
    }
}
