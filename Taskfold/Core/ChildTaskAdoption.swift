import Foundation
import Observation

/// Read-only discovery metadata. Never insert these partial rows into Snapshot.
struct ChildTaskAdoptionTarget: Identifiable, Sendable {
    let id: String
    let generation: JSON
    let project: JSON
    let title: String
    let titleTruncated: Bool
    init(_ raw: [String: JSON]) throws {
        guard Set(raw.keys) == ["task_id", "task_generation", "project_id", "title", "title_truncated"],
              case .string(let id)? = raw["task_id"], UUID(uuidString: id)?.uuidString.lowercased() == id,
              case .bool(let shortened)? = raw["title_truncated"] else { throw ChildTaskAdoptionCommand.invalid }
        for key in ["task_generation", "project_id"] { _ = try TeamProjectValue.optionalID(raw[key]) }
        let title: String
        switch raw["title"] { case .string(let s)?: title = s; case .null?: title = ""; default: throw ChildTaskAdoptionCommand.invalid }
        guard title.utf8.count <= 2048 else { throw ChildTaskAdoptionCommand.invalid }
        self.id = id; generation = raw["task_generation"]!; project = raw["project_id"]!
        self.title = title.isEmpty ? "Untitled task" : title; titleTruncated = shortened
    }
    func context(scope: ChildTaskFieldClientScope, snapshot: UUID) throws -> ChildTaskRecordContext {
        try .init(account: scope.account, origin: scope.origin, workspace: scope.workspace, session: scope.session,
                  access: scope.access, snapshot: snapshot, root: Record(["id": .string(id), "task_generation": generation, "project_id": project, "title": .string(title)]))
    }
}
struct ChildTaskAdoptionTargetPage: Sendable {
    static let maximumBytes = 300_000
    let targets: [ChildTaskAdoptionTarget]
    let next: String?
    init(data: Data, account: String, after: String?, limit: Int, id: String?) throws {
        guard (1...100).contains(limit), id == nil || after == nil && limit == 1 else { throw ChildTaskAdoptionCommand.invalid }
        for value in [after, id].compactMap({ $0 }) { guard UUID(uuidString: value)?.uuidString.lowercased() == value else { throw ChildTaskAdoptionCommand.invalid } }
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: Self.maximumBytes, integerPaths: [["protocol"]])
        let raw = try TaskfoldJSONDecoder().decode([String: JSON].self, from: data)
        guard Set(raw.keys) == ["protocol", "account", "items", "next_after"], raw["protocol"] == .number(1), raw["account"] == .string(account),
              case .array(let items)? = raw["items"], items.count <= limit else { throw ChildTaskAdoptionCommand.invalid }
        var targets: [ChildTaskAdoptionTarget] = [], previous = after
        for item in items {
            guard case .object(let value) = item else { throw ChildTaskAdoptionCommand.invalid }
            let target = try ChildTaskAdoptionTarget(value)
            guard previous == nil || previous! < target.id, id == nil || id == target.id else { throw ChildTaskAdoptionCommand.invalid }
            targets.append(target); previous = target.id
        }
        let next = try TeamProjectValue.optionalID(raw["next_after"])
        guard next == nil || id == nil && targets.count == limit && next == targets.last?.id else { throw ChildTaskAdoptionCommand.invalid }
        self.targets = targets; self.next = next
    }
}

/// Ephemeral review. Original content stays as raw JSON bytes, never as a
/// replacement task or part of the durable request.
struct ChildTaskAdoptionReview: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let maximumBytes = 2_100_000
    static let counters: Set<[String]> = [["protocol"], ["node_count"], ["max_depth"], ["source_bytes"], ["projection_revision"], ["structure_revision"]]
    static let nullableCounters: Set<[String]> = [["node_count"], ["max_depth"], ["projection_revision"], ["structure_revision"]]
    let context: ChildTaskRecordContext
    let workspaceID: String?
    let metadata: [String: JSON]
    let originalSource: Data?
    let preview: [Item]
    struct Item: Identifiable, Sendable { let id: String; let title: String?; let depth: Int }
    private struct Node: Decodable {
        let id: String; let title: String?; let children: [Node]
        private enum CodingKeys: String, CodingKey { case id, title, subtasks }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try? c.decode(String.self, forKey: .title)
            children = try c.decodeIfPresent([Node].self, forKey: .subtasks) ?? []
        }
    }
    var eligible: Bool { metadata["can_adopt"] == .bool(true) }
    var description: String { "Private subtask migration review" }
    var debugDescription: String { description }
    static func count(_ value: JSON?, maximum: Double) throws -> Int {
        guard case .number(let n)? = value, n.isFinite, n >= 0, n <= maximum, n.rounded() == n else { throw ChildTaskAdoptionCommand.invalid }; return Int(n)
    }
    init(data: Data, context: ChildTaskRecordContext, workspaceID: String?) throws {
        if let workspaceID { _ = try TeamOrganizationValue.id(.string(workspaceID)) }
        let parts = try ChildTaskRecordRead.separatingJSONField("source_tree", data: data, maximum: Self.maximumBytes, integerPaths: Self.counters, nullableIntegerPaths: Self.nullableCounters)
        let raw = try TaskfoldJSONDecoder().decode([String: JSON].self, from: parts.metadata)
        guard Set(raw.keys) == ["protocol", "account", "task_id", "task_generation", "project_id", "workspace_id", "review_digest", "state", "issue", "node_count", "max_depth", "source_bytes", "root_kind", "source_included", "source_tree", "projection_revision", "structure_revision", "can_adopt"],
              raw["protocol"] == .number(1), raw["account"] == .string(context.account), raw["task_id"] == .string(context.root.id),
              raw["task_generation"] == context.root["task_generation"], raw["project_id"] == context.root["project_id"],
              raw["workspace_id"] == (workspaceID.map(JSON.string) ?? .null), ChildTaskAdoptionCommand.digest(raw["review_digest"]),
              case .bool(let included)? = raw["source_included"], case .bool(let canAdopt)? = raw["can_adopt"],
              let state = raw["state"]?.text, ["ready", "review", "records"].contains(state) else { throw ChildTaskAdoptionCommand.invalid }
        let sourceBytes = try Self.count(raw["source_bytes"], maximum: 2_147_483_647)
        guard ["null", "array", "object", "string", "number", "boolean"].contains(raw["root_kind"]?.text ?? ""), sourceBytes > 0, included == (sourceBytes <= 2_000_000),
              (raw["projection_revision"] == .null) == (raw["structure_revision"] == .null) else { throw ChildTaskAdoptionCommand.invalid }
        for key in ["projection_revision", "structure_revision"] where raw[key] != .null { _ = try TeamProjectValue.revision(raw[key]) }
        let first = parts.value.first
        let kind = first == 110 ? "null" : first == 91 ? "array" : first == 123 ? "object" : first == 34 ? "string" : first == 116 || first == 102 ? "boolean" : "number"
        guard included ? raw["root_kind"] == .string(kind) : parts.value == Data("null".utf8) else { throw ChildTaskAdoptionCommand.invalid }
        var preview: [Item] = []
        if state != "review" {
            guard included, raw["issue"] == .null, kind == "null" || kind == "array", state != "records" || !canAdopt else { throw ChildTaskAdoptionCommand.invalid }
            let nodes = kind == "null" ? [] : try TaskfoldJSONDecoder().decode([Node].self, from: parts.value)
            var seen = Set<String>()
            func walk(_ rows: [Node], depth: Int) throws {
                guard depth <= 24 else { throw ChildTaskAdoptionCommand.invalid }
                for node in rows {
                    try Task.checkCancellation()
                    let canonical = node.id.precomposedStringWithCanonicalMapping
                    guard !node.id.isEmpty, node.id.utf8.count <= 128, canonical.utf8.count <= 128, seen.insert(canonical).inserted, preview.count < 1000 else { throw ChildTaskAdoptionCommand.invalid }
                    preview.append(.init(id: node.id, title: node.title, depth: depth))
                    if !node.children.isEmpty { try walk(node.children, depth: depth + 1) }
                }
            }
            try walk(nodes, depth: 1)
            guard try Self.count(raw["node_count"], maximum: 1000) == preview.count,
                  try Self.count(raw["max_depth"], maximum: 24) == (preview.map(\.depth).max() ?? 0) else { throw ChildTaskAdoptionCommand.invalid }
        } else {
            let issues = ["root_shape", "identity", "duplicate_identity", "children_shape", "node_limit", "depth_limit", "source_size", "projection_mismatch", "authority_mismatch"]
            guard !canAdopt, issues.contains(raw["issue"]?.text ?? ""), included || ["source_size", "authority_mismatch"].contains(raw["issue"]!.text),
                  (raw["node_count"] == .null) == (raw["max_depth"] == .null) else { throw ChildTaskAdoptionCommand.invalid }
            if raw["node_count"] != .null {
                guard ["projection_mismatch", "authority_mismatch"].contains(raw["issue"]!.text) else { throw ChildTaskAdoptionCommand.invalid }
                _ = try Self.count(raw["node_count"], maximum: 1000); _ = try Self.count(raw["max_depth"], maximum: 24)
            }
        }
        self.context = context; self.workspaceID = workspaceID; metadata = raw; originalSource = included ? parts.value : nil; self.preview = preview
    }
}

struct ChildTaskAdoptionCommand: ReviewedTeamCommand, CustomStringConvertible, CustomDebugStringConvertible {
    static let storagePrefix = "child-adoption-command-v1."
    static let maximumStoredBytes = 10_000
    static var invalid: AppFailure { AppFailure(message: "Review this subtask migration against the current task. Your original work is kept.") }
    static let keys: Set<String> = ["protocol", "account", "request_id", "task_id", "task_generation", "project_id", "workspace_id", "review_digest"]
    static func digest(_ value: JSON?) -> Bool { if case .string(let s)? = value { return s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }; return false }
    let account: String, origin: String, body: [String: JSON]
    let nodeCount: Int
    var id: String { body["request_id"]!.text }
    var rootID: String { body["task_id"]!.text }
    var description: String { "Private subtask migration request" }
    var debugDescription: String { description }
    static func == (a: Self, b: Self) -> Bool { a.account == b.account && a.origin == b.origin && a.nodeCount == b.nodeCount && ChildTaskStructureCommand.exact(.object(a.body), .object(b.body)) }
    init(review: ChildTaskAdoptionReview, requestID: UUID = UUID()) throws {
        guard review.eligible else { throw Self.invalid }
        var body = review.metadata.filter { Self.keys.contains($0.key) }; body["request_id"] = .string(requestID.uuidString.lowercased())
        try self.init(account: review.context.account, origin: review.context.origin, body: body, nodeCount: ChildTaskAdoptionReview.count(review.metadata["node_count"], maximum: 1000))
    }
    init(account: String, origin: String, body: [String: JSON], nodeCount: Int) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard origin.utf8.count <= 2048, Set(body.keys) == Self.keys, body["protocol"] == .number(1), body["account"] == .string(account), Self.digest(body["review_digest"]), (0...1000).contains(nodeCount), try TaskfoldJSONEncoder().encode(body).count <= 2000 else { throw Self.invalid }
        _ = try TeamOrganizationValue.id(body["request_id"]); _ = try TeamOrganizationValue.id(body["task_id"])
        for key in ["task_generation", "project_id", "workspace_id"] { _ = try TeamProjectValue.optionalID(body[key]) }
        self.account = account; self.origin = origin; self.body = body; self.nodeCount = nodeCount
    }
    func review(_ read: ChildTaskAdoptionReview) throws {
        guard try Self(review: read, requestID: UUID(uuidString: id)!) == self else { throw Self.invalid }
    }
    private enum CodingKeys: String, CodingKey { case account, origin, body, nodeCount }
    init(from decoder: Decoder) throws {
        try structureKeys(decoder, ["account", "origin", "body", "nodeCount"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), body: c.decode([String: JSON].self, forKey: .body), nodeCount: c.decode(Int.self, forKey: .nodeCount))
    }
    init(data: Data) throws {
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: Self.maximumStoredBytes, integerPaths: [["nodeCount"], ["body", "protocol"]])
        self = try TaskfoldJSONDecoder().decode(Self.self, from: data)
    }
    func result(_ raw: [String: JSON]) throws -> ChildTaskAdoptionResult { try .init(command: self, raw: raw) }
}
struct ChildTaskAdoptionResult: Codable, Equatable, Sendable {
    let raw: [String: JSON]
    private enum CodingKeys: String, CodingKey { case raw }
    init(from decoder: Decoder) throws {
        try structureKeys(decoder, ["raw"])
        raw = try decoder.container(keyedBy: CodingKeys.self).decode([String: JSON].self, forKey: .raw)
    }
    var applied: Bool { raw["state"] == .string("applied") }
    var closed: Bool { raw["state"] == .string("closed") }
    var unknown: Bool { raw["state"] == .string("unknown") }
    init(command: ChildTaskAdoptionCommand, data: Data) throws {
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: 16_384, integerPaths: [["protocol"], ["node_count"]], nullableIntegerPaths: [["node_count"]])
        try self.init(command: command, raw: TaskfoldJSONDecoder().decode([String: JSON].self, from: data))
    }
    init(command: ChildTaskAdoptionCommand, raw: [String: JSON]) throws {
        guard raw["protocol"] == .number(1), raw["account"] == .string(command.account), raw["request_id"] == .string(command.id) else { throw ChildTaskAdoptionCommand.invalid }
        if raw["state"] == .string("unknown") {
            guard Set(raw.keys) == ["protocol", "account", "request_id", "state"] else { throw ChildTaskAdoptionCommand.invalid }; self.raw = raw; return
        }
        guard Set(raw.keys) == ChildTaskAdoptionCommand.keys.union(["state", "node_count", "replayed"]),
              case .bool? = raw["replayed"], raw["state"] == .string("applied") || raw["state"] == .string("closed"),
              command.body.allSatisfy({ ChildTaskStructureCommand.exact(raw[$0.key], $0.value) }),
              raw["node_count"] == (raw["state"] == .string("applied") ? .number(Double(command.nodeCount)) : .null) else { throw ChildTaskAdoptionCommand.invalid }
        self.raw = raw
    }
    func agrees(_ other: Self) -> Bool { ChildTaskStructureCommand.exact(.object(raw.filter { $0.key != "replayed" }), .object(other.raw.filter { $0.key != "replayed" })) }
}

struct ChildTaskAdoptionFailure: LocalizedError {
    let reason: ChildTaskFieldWriteFailure.Reason
    var errorDescription: String? {
        switch reason {
        case .unavailable: return "Subtask migration is unavailable or access changed. Your original work and saved request are kept."
        case .review: return "This task changed or needs review. Check and stop the original migration before reviewing a new one."
        case .busy: return "Another change is finishing. Retry the original migration shortly."
        case .limit: return "This migration reached a service or storage limit. Your original work is kept."
        case .closed: return "This migration was stopped. Review the current task before starting another."
        case .unconfirmed: return "Migration couldn’t be confirmed. Check its status or retry the original saved request."
        }
    }
}


struct ChildTaskAdoptionState: ReviewedTeamFileCommand {
    enum Phase: String, Codable, Sendable { case queued, attempted, applied, closed }
    struct Entry: Codable, Equatable, Sendable {
        let command: ChildTaskAdoptionCommand
        var phase: Phase = .queued
        var result: ChildTaskAdoptionResult?
        init(command: ChildTaskAdoptionCommand, phase: Phase = .queued, result: ChildTaskAdoptionResult? = nil) { self.command = command; self.phase = phase; self.result = result }
        private enum CodingKeys: String, CodingKey { case command, phase, result }
        init(from decoder: Decoder) throws {
            try structureKeys(decoder, ["command", "phase", "result"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            command = try c.decode(ChildTaskAdoptionCommand.self, forKey: .command); phase = try c.decode(Phase.self, forKey: .phase); result = try c.decodeIfPresent(ChildTaskAdoptionResult.self, forKey: .result)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(command, forKey: .command); try c.encode(phase, forKey: .phase); try c.encode(result, forKey: .result)
        }
    }
    static let storagePrefix = "child-adoption-state-v1."
    static let fileName = "requests.taskfoldchildadoption"
    static let encryptionContext = "com.taskfold.child-adoption-state.v1"
    static let maximumStoredBytes = 1_000_000
    static var invalid: AppFailure { ChildTaskAdoptionCommand.invalid }
    let account: String, origin: String
    var entries: [Entry]
    init(account: String, origin: String, entries: [Entry] = []) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard entries.count <= 64 else { throw ChildTaskAdoptionFailure(reason: .limit) }
        var ids = Set<String>(), pendingRoots = Set<String>()
        for entry in entries {
            guard entry.command.account == account, entry.command.origin == origin, ids.insert(entry.command.id).inserted else { throw Self.invalid }
            if entry.phase == .queued || entry.phase == .attempted { guard pendingRoots.insert(entry.command.rootID).inserted else { throw Self.invalid } }
            if let result = entry.result {
                _ = try entry.command.result(result.raw)
                guard entry.phase == .applied && result.applied || entry.phase == .closed && result.closed else { throw Self.invalid }
            } else { guard entry.phase == .queued || entry.phase == .attempted else { throw Self.invalid } }
        }
        self.account = account; self.origin = origin; self.entries = entries
    }
    init(data: Data) throws {
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: Self.maximumStoredBytes, integerPaths: [["version"], ["entries", "[]", "command", "nodeCount"], ["entries", "[]", "command", "body", "protocol"], ["entries", "[]", "result", "raw", "protocol"], ["entries", "[]", "result", "raw", "node_count"]], nullableIntegerPaths: [["entries", "[]", "result", "raw", "node_count"]])
        self = try TaskfoldJSONDecoder().decode(Self.self, from: data)
    }
    private enum CodingKeys: String, CodingKey { case version, account, origin, entries }
    init(from decoder: Decoder) throws {
        try structureKeys(decoder, ["version", "account", "origin", "entries"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == 1 else { throw Self.invalid }
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), entries: c.decode([Entry].self, forKey: .entries))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(1, forKey: .version); try c.encode(account, forKey: .account); try c.encode(origin, forKey: .origin); try c.encode(entries, forKey: .entries)
    }
}

actor ChildTaskAdoptionJournal {
    private let admit: @Sendable (Set<String>) throws -> Void
    let account: String, origin: String
    private let io: any CalendarSecureItemIO, lock: AutomationEnrollmentProcessLock, removalDirectory: URL
    private var key: String { ChildTaskAdoptionState.storagePrefix + account + "." + CalendarOAuthConfiguration.digest(origin) }
    init(account: String, origin: String, io: any CalendarSecureItemIO, coordinationDirectory: URL, removalDirectory: URL, admit: @escaping @Sendable (Set<String>) throws -> Void = { _ in }) throws {
        self.admit = admit;
        try TeamOrganizationValue.scope(account: account, origin: origin)
        self.account = account; self.origin = origin; self.io = io; lock = .init(directory: coordinationDirectory); self.removalDirectory = removalDirectory
    }
    private func guarded<T>(_ lease: CalendarReadLease?, _ work: () throws -> T) throws -> T {
        try lock.withExclusive(account: account, check: { try lease?.check() }) {
            try AccountRemovalDisk(directory: removalDirectory, account: account).writable { try lease?.check(); return try work() }
        }
    }
    private func read() throws -> ChildTaskAdoptionState {
        guard let data = try io.read(key: key) else { return try .init(account: account, origin: origin) }
        let state = try ChildTaskAdoptionState(data: data)
        guard state.account == account, state.origin == origin else { throw ChildTaskAdoptionCommand.invalid }; return state
    }
    private func write(_ entries: [ChildTaskAdoptionState.Entry], lease: CalendarReadLease) throws {
        let state = try ChildTaskAdoptionState(account: account, origin: origin, entries: entries), data = try TaskfoldJSONEncoder().encode(state)
        guard data.count <= ChildTaskAdoptionState.maximumStoredBytes else { throw ChildTaskAdoptionFailure(reason: .limit) }
        try lease.check(); try io.write(data, key: key)
    }
    func load() throws -> ChildTaskAdoptionState { try guarded(nil) { try read() } }
    func enqueue(_ command: ChildTaskAdoptionCommand, lease: CalendarReadLease) throws {
        try guarded(lease) {
            try admit([command.body["task_id"]!.text])
            guard command.account == account, command.origin == origin else { throw ChildTaskAdoptionCommand.invalid }
            var state = try read()
            if let old = state.entries.first(where: { $0.command.id == command.id }) { guard old.command == command, old.phase != .closed else { throw ChildTaskAdoptionCommand.invalid }; return }
            guard !state.entries.contains(where: { ($0.phase == .queued || $0.phase == .attempted) && $0.command.rootID == command.rootID }) else { throw ChildTaskAdoptionFailure(reason: .busy) }
            state.entries.append(.init(command: command)); try write(state.entries, lease: lease)
        }
    }
    func attempt(_ command: ChildTaskAdoptionCommand, lease: CalendarReadLease, resolving: Bool = false) throws -> ChildTaskAdoptionState.Entry {
        try guarded(lease) {
            if !resolving { try admit([command.body["task_id"]!.text]) }
            var state = try read(); guard let i = state.entries.firstIndex(where: { $0.command == command }) else { throw ChildTaskAdoptionCommand.invalid }
            if state.entries[i].phase == .queued { state.entries[i].phase = .attempted; try write(state.entries, lease: lease) }
            return state.entries[i]
        }
    }
    func settle(_ command: ChildTaskAdoptionCommand, result: ChildTaskAdoptionResult, lease: CalendarReadLease) throws {
        try guarded(lease) {
            _ = try command.result(result.raw); guard !result.unknown else { throw ChildTaskAdoptionCommand.invalid }
            var state = try read(); guard let i = state.entries.firstIndex(where: { $0.command == command }), state.entries[i].phase != .queued else { throw ChildTaskAdoptionCommand.invalid }
            if let old = state.entries[i].result { guard old.agrees(result) else { throw ChildTaskAdoptionCommand.invalid }; return }
            state.entries[i].phase = result.applied ? .applied : .closed; state.entries[i].result = result; try write(state.entries, lease: lease)
        }
    }
    func discard(_ command: ChildTaskAdoptionCommand, lease: CalendarReadLease) throws {
        try guarded(lease) {
            var state = try read(); guard let i = state.entries.firstIndex(where: { $0.command == command }), state.entries[i].phase != .attempted else { throw ChildTaskAdoptionCommand.invalid }
            state.entries.remove(at: i)
            try write(state.entries, lease: lease)
        }
    }
    func removeAccount() throws { try lock.withExclusive(account: account) { try io.remove(key: key) } }
}

enum ChildTaskAdoptionOperation: String, Sendable { case send, check, close }
@MainActor protocol ChildTaskAdoptionService: AnyObject {
    func childTaskAdoption(_ command: ChildTaskAdoptionCommand, operation: ChildTaskAdoptionOperation, session: UUID) async throws -> ChildTaskAdoptionResult
}
extension Backend: ChildTaskAdoptionService {}
@MainActor @Observable final class ChildTaskAdoptionModel {
    private(set) var entries: [ChildTaskAdoptionState.Entry] = []
    private(set) var busy = false
    private(set) var loaded = false
    private(set) var message: String?
    let scope: ChildTaskFieldClientScope
    private let journal: ChildTaskAdoptionJournal, service: any ChildTaskAdoptionService
    private let current: () -> ChildTaskFieldClientScope?
    private let canSend: (ChildTaskAdoptionCommand) -> Bool
    private let admit: (ChildTaskAdoptionCommand) async throws -> Void
    private let reviewCurrent: (ChildTaskAdoptionReview) -> Bool
    private let lease = CalendarReadLease()
    private var closed = false
    init(scope: ChildTaskFieldClientScope, journal: ChildTaskAdoptionJournal, service: any ChildTaskAdoptionService, current: @escaping () -> ChildTaskFieldClientScope?, canSend: @escaping (ChildTaskAdoptionCommand) -> Bool, admit: @escaping (ChildTaskAdoptionCommand) async throws -> Void, reviewCurrent: @escaping (ChildTaskAdoptionReview) -> Bool) {
        self.scope = scope; self.journal = journal; self.service = service; self.current = current; self.canSend = canSend; self.admit = admit; self.reviewCurrent = reviewCurrent
    }
    func close() { closed = true; lease.cancel(); entries = []; message = nil; loaded = false; busy = false }
    private func check() throws { try lease.check(); guard !closed, current() == scope else { throw CancellationError() } }
    private func update() async throws { let state = try await journal.load(); try check(); entries = state.entries; loaded = true }
    private func work(_ action: () async throws -> Void) async -> Bool {
        guard !busy else { return false }; busy = true; defer { busy = false }
        do { try check(); try await action(); try check(); return true }
        catch {
            guard (try? check()) != nil else { close(); return false }
            do { try await update() } catch { entries = []; loaded = false }
            guard (try? check()) != nil else { close(); return false }
            if error is AccountSessionAuthorizationRequired { message = "Sign in again to check your saved migration." }
            else if let failure = error as? ChildTaskAdoptionFailure { message = failure.localizedDescription }
            else if let failure = error as? AppFailure { message = failure.localizedDescription }
            else { message = "Migration couldn’t be confirmed. Your saved request is kept; check its status before starting another." }
            return false
        }
    }
    func load() async { _ = await work { try await update() } }
    func queue(_ command: ChildTaskAdoptionCommand, review: ChildTaskAdoptionReview) async -> Bool {
        await work {
            guard ChildTaskFieldClientScope(review.context) == scope, reviewCurrent(review) else { throw CancellationError() }
            try command.review(review)
            try await admit(command); try check()
            guard reviewCurrent(review) else { throw CancellationError() }
            try await journal.enqueue(command, lease: lease); try check(); try await update(); message = "Migration saved on this device."
        }
    }
    func run(_ command: ChildTaskAdoptionCommand, operation: ChildTaskAdoptionOperation) async -> Bool {
        let completed = await work {
            guard command.account == scope.account, command.origin == scope.origin else { throw CancellationError() }
            if operation == .send { guard canSend(command) else { throw ChildTaskAdoptionFailure(reason: .unavailable) }; try await admit(command); try check() }
            let entry = try await journal.attempt(command, lease: lease, resolving: operation != .send); try check()
            let result: ChildTaskAdoptionResult
            if let old = entry.result { result = try command.result(old.raw) }
            else {
                if operation == .send { guard canSend(command) else { throw ChildTaskAdoptionFailure(reason: .unavailable) }; try await admit(command); try check() }
                result = try await service.childTaskAdoption(command, operation: operation, session: scope.session); try check()
                _ = try command.result(result.raw)
                guard operation == .check || !result.unknown else { throw ChildTaskAdoptionFailure(reason: .unconfirmed) }
                if !result.unknown { try await journal.settle(command, result: result, lease: lease); try check() }
            }
            try await update()
            message = result.applied ? "Subtask storage updated." : result.closed ? "Migration stopped. Your original task is unchanged by this request." : "No confirmation yet. Retry the original migration, or stop it before making a new one."
        }
        // A file write can finish before reporting an I/O error. Trust only the
        // reloaded, fully validated proof; never retry with a different identity.
        if !completed, (try? check()) != nil, let result = entries.first(where: { $0.command == command })?.result {
            message = result.applied ? "Subtask storage updated." : "Migration stopped. Your original task is unchanged by this request."
            return true
        }
        return completed
    }
    func discard(_ command: ChildTaskAdoptionCommand) async {
        _ = await work { try await journal.discard(command, lease: lease); try check(); try await update(); message = "Saved migration history removed. Your tasks are unchanged." }
    }
}

/// Admission inspects recovery data without modifying or retiring any draft.
enum ChildTaskAdoptionAdmission {
    static var unfinished: AppFailure { AppFailure(message: "Close this task’s editors and finish or review its saved edits in Account before upgrading. Your drafts are kept.") }
    static func roots(_ edit: TaskEditorRecovery) -> Set<String> {
        var explicit = Set<String>()
        for name in ["source_identity", "independent_child_fields"] {
            if let identity = edit.extras[name], let root = identity.object["root"] {
                guard case .string(let id) = root, TeamProjectValue.id(id) else { return ["*"] }
                explicit.insert(id)
            }
        }
        if !explicit.isEmpty { return explicit }
        if let root = SubtaskTree.referencePath(edit.original.id)?.first { return [root] }
        return TeamProjectValue.id(edit.original.id) ? [edit.original.id] : ["*"]
    }
    static func requireClear(root: String, pending: Set<String>, openEditors: Set<String>, preserved: [TaskEditorRecovery] = []) throws {
        guard !pending.contains(root), !openEditors.contains(root), !openEditors.contains("*"),
              !preserved.contains(where: { roots($0).contains(root) || roots($0).contains("*") }) else { throw unfinished }
    }
    nonisolated static func checkPreservedEdits(root: String, vault: BackupVault, origin: String) async throws {
        try Task.checkCancellation()
        for entry in try vault.editorEntries() {
            try Task.checkCancellation()
            let edit = try vault.editorDraft(entry.id, origin: origin)
            try requireClear(root: root, pending: [], openEditors: [], preserved: [edit])
        }
    }
}
