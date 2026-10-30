import Foundation
import CryptoKit

/// Private composer content is not a queued command. Invalid/unfinished titles
/// and destinations can be kept without granting permission to mutate a task.
struct ChildTaskStructureDraft: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let account: String, origin: String
    let body: [String: JSON]
    let token: UUID
    var id: String { body["request_id"]!.text }
    var description: String { "Private subtask organizer draft" }
    var debugDescription: String { description }
    static var invalid: AppFailure { .init(message: "This subtask draft needs review. Your saved work is kept.") }
    private static let identityKeys = ["account", "request_id", "task_id", "task_generation", "project_id", "action", "node_key", "incarnation"]

    init(read: ChildTaskStructureRead, moving: String? = nil, id: UUID = UUID()) throws {
        let node = moving.flatMap { read.records.nodes[$0] }
        guard moving == nil || node != nil else { throw Self.invalid }
        let parent = node?.parent
        try self.init(account: read.context.account, origin: read.context.origin, body: [
            "account": .string(read.context.account), "request_id": .string(id.uuidString.lowercased()),
            "task_id": .string(read.context.root.id), "task_generation": read.context.root["task_generation"], "project_id": read.context.root["project_id"],
            "action": .string(moving == nil ? "insert" : "move"), "node_key": moving.map(JSON.string) ?? .null,
            "incarnation": node.map { .string($0.incarnation) } ?? .null,
            "structure_revision": .number(read.structureRevision), "parent_key": parent.map(JSON.string) ?? .null,
            "parent_incarnation": parent.flatMap { read.records.nodes[$0] }.map { .string($0.incarnation) } ?? .null,
            "index": .number(Double(node?.position ?? 0)), "title": .string("")
        ])
    }
    init(account: String, origin: String, body: [String: JSON], token: UUID = UUID()) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard origin.utf8.count <= 2048, body["account"] == .string(account),
              Set(body.keys) == Set(Self.identityKeys + ["structure_revision", "parent_key", "parent_incarnation", "index", "title"]),
              body["action"] == .string("insert") || body["action"] == .string("move"),
              case .string(let title)? = body["title"], title.utf8.count <= 40_000 else { throw Self.invalid }
        for key in ["request_id", "task_id"] { _ = try TeamOrganizationValue.id(body[key]) }
        for key in ["task_generation", "project_id"] { _ = try TeamProjectValue.optionalID(body[key]) }
        guard try TeamProjectValue.revision(body["structure_revision"]) < 9_007_199_254_740_991,
              case .number(let position)? = body["index"], position.isFinite, position.sign == .plus,
              position.rounded() == position, position <= 1000 else { throw Self.invalid }
        if body["action"] == .string("insert") {
            guard body["node_key"] == .null, body["incarnation"] == .null else { throw Self.invalid }
        } else {
            _ = try ChildTaskStructureCommand.key(body["node_key"]); _ = try TeamOrganizationValue.id(body["incarnation"])
        }
        if body["parent_key"] == .null { guard body["parent_incarnation"] == .null else { throw Self.invalid } }
        else { _ = try ChildTaskStructureCommand.key(body["parent_key"]); _ = try TeamOrganizationValue.id(body["parent_incarnation"]) }
        self.account = account; self.origin = origin; self.body = body; self.token = token
    }
    func sameTarget(as other: Self) -> Bool {
        account == other.account && origin == other.origin && Self.identityKeys.allSatisfy { ChildTaskStructureCommand.exact(body[$0], other.body[$0]) }
    }
    /// Reopening never rebases a positional edit or follows a recreated node.
    /// The caller must explicitly choose/review a new destination if it changed.
    func reviewedCommand(_ read: ChildTaskStructureRead) throws -> ChildTaskStructureCommand {
        guard account == read.context.account, origin == read.context.origin,
              body["task_id"] == .string(read.context.root.id), body["task_generation"] == read.context.root["task_generation"],
              body["project_id"] == read.context.root["project_id"], body["structure_revision"] == .number(read.structureRevision) else { throw Self.invalid }
        let parent = body["parent_key"] == .null ? nil : body["parent_key"]!.text
        if let parent { guard read.records.nodes[parent]?.incarnation == body["parent_incarnation"]?.text else { throw Self.invalid } }
        let request = UUID(uuidString: id)!
        if body["action"] == .string("insert") {
            return try .init(insert: .object(["id": .string(id), "title": body["title"]!]), parent: parent, index: body["index"]!.integer, read: read, requestID: request)
        }
        guard read.records.nodes[body["node_key"]!.text]?.incarnation == body["incarnation"]?.text else { throw Self.invalid }
        return try .init(move: body["node_key"]!.text, parent: parent, index: body["index"]!.integer, read: read, requestID: request)
    }
    private enum CodingKeys: String, CodingKey { case account, origin, body, token }
    init(from decoder: Decoder) throws {
        try structureKeys(decoder, ["account", "origin", "body", "token"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), body: c.decode([String: JSON].self, forKey: .body), token: c.decode(UUID.self, forKey: .token))
    }
    static func == (a: Self, b: Self) -> Bool {
        a.account == b.account && a.origin == b.origin && a.token == b.token && AuthoredValueComparison.exactJSON(.object(a.body), .object(b.body))
    }
}

struct ChildTaskStructureDraftState: ReviewedTeamFileCommand, CustomStringConvertible, CustomDebugStringConvertible {
    static let storagePrefix = "child-structure-drafts-v1."
    static let fileName = "drafts.taskfoldchildstructure"
    static let encryptionContext = "com.taskfold.child-structure-drafts.v1"
    static let maximumStoredBytes = 1_600_000
    static let maximumEntries = 32
    static var invalid: AppFailure { ChildTaskStructureDraft.invalid }
    let account: String, origin: String
    var entries: [ChildTaskStructureDraft]
    var description: String { "Private subtask organizer drafts" }
    var debugDescription: String { description }
    init(account: String, origin: String, entries: [ChildTaskStructureDraft] = []) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard origin.utf8.count <= 2048, entries.count <= Self.maximumEntries,
              Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ $0.account == account && $0.origin == origin }) else { throw Self.invalid }
        self.account = account; self.origin = origin; self.entries = entries
    }
    init(data: Data) throws {
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: Self.maximumStoredBytes, integerPaths: [["version"], ["entries", "[]", "body", "structure_revision"], ["entries", "[]", "body", "index"]])
        self = try JSONDecoder().decode(Self.self, from: data)
    }
    private enum CodingKeys: String, CodingKey { case version, account, origin, entries }
    init(from decoder: Decoder) throws {
        try structureKeys(decoder, ["version", "account", "origin", "entries"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == 1 else { throw Self.invalid }
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), entries: c.decode([ChildTaskStructureDraft].self, forKey: .entries))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .version); try c.encode(account, forKey: .account); try c.encode(origin, forKey: .origin); try c.encode(entries, forKey: .entries)
    }
}

/// Reuse authenticated file encryption, process coordination and removal fences.
/// Unsent drafts are never evicted to make room for another draft.
actor ChildTaskStructureDraftJournal {
    private let io: any CalendarSecureItemIO
    private let lock: AutomationEnrollmentProcessLock
    private let removalDirectory: URL
    let account: String, origin: String
    private var key: String { ChildTaskStructureDraftState.storagePrefix + account + "." + CalendarOAuthConfiguration.digest(origin) }
    init(account: String, origin: String, io: any CalendarSecureItemIO, coordinationDirectory: URL, removalDirectory: URL) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        self.account = account; self.origin = origin; self.io = io; lock = .init(directory: coordinationDirectory); self.removalDirectory = removalDirectory
    }
    private func guarded<T>(lease: CalendarReadLease?, _ action: () throws -> T) throws -> T {
        try lock.withExclusive(account: account, check: { try lease?.check() }) {
            try AccountRemovalDisk(directory: removalDirectory, account: account).writable { try lease?.check(); return try action() }
        }
    }
    private func read() throws -> ChildTaskStructureDraftState {
        guard let data = try io.read(key: key) else { return try .init(account: account, origin: origin) }
        let state = try ChildTaskStructureDraftState(data: data)
        guard state.account == account, state.origin == origin else { throw ChildTaskStructureDraft.invalid }; return state
    }
    private func write(_ entries: [ChildTaskStructureDraft], lease: CalendarReadLease) throws {
        let state = try ChildTaskStructureDraftState(account: account, origin: origin, entries: entries)
        let data = try JSONEncoder().encode(state)
        guard data.count <= ChildTaskStructureDraftState.maximumStoredBytes else { throw ChildTaskStructureDraft.invalid }
        try lease.check(); try io.write(data, key: key)
    }
    func load() throws -> ChildTaskStructureDraftState { try guarded(lease: nil) { try read() } }
    func save(_ draft: ChildTaskStructureDraft, replacing expected: UUID?, lease: CalendarReadLease) throws {
        try guarded(lease: lease) {
            guard draft.account == account, draft.origin == origin else { throw ChildTaskStructureDraft.invalid }
            var state = try read()
            if let index = state.entries.firstIndex(where: { $0.id == draft.id }) {
                let old = state.entries[index]
                // Exact retry of an acknowledged-or-lost local write is safe.
                if old == draft { return }
                guard old.token == expected, draft.token != expected, old.sameTarget(as: draft) else { throw ChildTaskStructureDraft.invalid }
                state.entries[index] = draft
            } else {
                guard expected == nil else { throw ChildTaskStructureDraft.invalid }
                state.entries.append(draft)
            }
            try write(state.entries, lease: lease)
        }
    }
    func discard(_ draft: ChildTaskStructureDraft, lease: CalendarReadLease) throws {
        try guarded(lease: lease) {
            var state = try read()
            guard let index = state.entries.firstIndex(where: { $0.id == draft.id }) else { return }
            guard state.entries[index] == draft else { throw ChildTaskStructureDraft.invalid }
            state.entries.remove(at: index); try write(state.entries, lease: lease)
        }
    }
    func removeAccount() throws { try lock.withExclusive(account: account) { try io.remove(key: key) } }
}
