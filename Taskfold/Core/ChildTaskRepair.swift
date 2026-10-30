import Foundation
import CryptoKit
import Observation

/// Only explicit metadata operations enter durable storage; opaque source trees
/// stay ephemeral and are never encoded as the app's floating-point JSON model.
struct ChildTaskRepairChange: Codable, Equatable, Sendable {
    enum Kind: String, Sendable { case makeRootList = "make_root_list", assignReference = "assign_reference", makeChildrenList = "make_children_list", wrapItem = "wrap_item", moveItem = "move_item" }
    let raw: [String: JSON]
    var kind: Kind { Kind(rawValue: raw["kind"]!.text)! }
    var path: [Int] { raw["path"]!.list.map(\.integer) }
    static func positions(_ value: JSON?, empty: Bool = true) throws -> [Int] {
        guard case .array(let values)? = value, values.count <= 64, empty || !values.isEmpty else { throw ChildTaskRepairCommand.invalid }
        return try values.map { try position($0, maximum: 999) }
    }
    static func position(_ value: JSON?, maximum: Double) throws -> Int {
        if case .number(let n)? = value, n.sign == .minus { throw ChildTaskRepairCommand.invalid }
        return try ChildTaskAdoptionReview.count(value, maximum: maximum)
    }
    init(raw: [String: JSON]) throws {
        guard let kind = Kind(rawValue: raw["kind"]?.text ?? "") else { throw ChildTaskRepairCommand.invalid }
        let extra: Set<String>
        switch kind { case .makeRootList, .makeChildrenList: extra = []; case .assignReference: extra = ["reference"]; case .wrapItem: extra = ["reference", "title"]; case .moveItem: extra = ["parent", "index"] }
        guard Set(raw.keys) == extra.union(["kind", "path"]) else { throw ChildTaskRepairCommand.invalid }
        let path = try Self.positions(raw["path"], empty: kind == .makeRootList)
        guard kind != .makeRootList || path.isEmpty else { throw ChildTaskRepairCommand.invalid }
        if kind == .assignReference || kind == .wrapItem {
            guard case .string(let reference)? = raw["reference"], !reference.isEmpty, reference.utf8.count <= 128, reference.precomposedStringWithCanonicalMapping.utf8.count <= 128 else { throw ChildTaskRepairCommand.invalid }
        }
        if kind == .wrapItem {
            guard case .string(let title)? = raw["title"], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.unicodeScalars.count <= 500, title.utf8.count <= 1000 else { throw ChildTaskRepairCommand.invalid }
        }
        if kind == .moveItem {
            let parent = try Self.positions(raw["parent"])
            _ = try Self.position(raw["index"], maximum: 1000)
            guard !parent.starts(with: path) else { throw ChildTaskRepairCommand.invalid }
        }
        self.raw = raw
    }
    init(_ kind: Kind, path: [Int], reference: String? = nil, title: String? = nil, parent: [Int]? = nil, index: Int? = nil) throws {
        var raw: [String: JSON] = ["kind": .string(kind.rawValue), "path": .array(path.map { .number(Double($0)) })]
        if let reference { raw["reference"] = .string(reference) }; if let title { raw["title"] = .string(title) }
        if let parent { raw["parent"] = .array(parent.map { .number(Double($0)) }) }; if let index { raw["index"] = .number(Double(index)) }
        try self.init(raw: raw)
    }
    init(from decoder: Decoder) throws { try self.init(raw: [String: JSON](from: decoder)) }
    func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }
    static func == (a: Self, b: Self) -> Bool { ChildTaskStructureCommand.exact(.object(a.raw), .object(b.raw)) }
    static func validate(_ changes: [Self]) throws {
        guard (1...64).contains(changes.count), try JSONEncoder().encode(changes).count <= 65_536 else { throw ChildTaskRepairCommand.invalid }
    }
    static let counterPaths: Set<[String]> = [["changes", "[]", "path", "[]"], ["changes", "[]", "parent", "[]"], ["changes", "[]", "index"]]
}

struct ChildTaskRepairPreview: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let maximumBytes = 4_300_000
    let context: ChildTaskRecordContext
    let workspaceID: String?
    let changes: [ChildTaskRepairChange]
    let metadata: [String: JSON]
    let original: Data
    let proposed: Data
    let items: [ChildTaskAdoptionReview.Item]
    var eligible: Bool { metadata["mutation_available"] == .bool(true) }
    var valid: Bool { metadata["proposal_valid"] == .bool(true) }
    var description: String { "Private reviewed repair preview" }
    var debugDescription: String { description }
    static let issues: Set<String> = ["root_shape", "identity", "duplicate_identity", "children_shape", "node_limit", "depth_limit"]
    static let jsonKinds: Set<String> = ["null", "object", "array", "string", "number", "boolean"]
    static let keys: Set<String> = ["protocol", "account", "task_id", "task_generation", "project_id", "workspace_id", "review_digest", "repair_digest", "original_tree", "original_sql_null", "changes", "proposal_valid", "remaining_issue", "node_count", "proposed_tree", "steps", "custody_blocker", "mutation_available"]
    static func body(review: ChildTaskAdoptionReview, changes: [ChildTaskRepairChange]) throws -> [String: JSON] {
        guard review.originalSource != nil else { throw ChildTaskRepairCommand.invalid }
        try ChildTaskRepairChange.validate(changes)
        var body = review.metadata.filter { ["protocol", "account", "task_id", "task_generation", "project_id", "workspace_id", "review_digest"].contains($0.key) }
        body["changes"] = .array(changes.map { .object($0.raw) }); return body
    }
    private struct Node: Decodable {
        let id: String, title: String?, children: [Node]
        enum CodingKeys: String, CodingKey { case id, title, subtasks }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self); id = try c.decode(String.self, forKey: .id)
            title = try? c.decode(String.self, forKey: .title); children = try c.decodeIfPresent([Node].self, forKey: .subtasks) ?? []
        }
    }
    init(data: Data, review: ChildTaskAdoptionReview, changes: [ChildTaskRepairChange]) throws {
        let expected = try Self.body(review: review, changes: changes)
        let parts = try ChildTaskRecordRead.separatingJSONFields(["original_tree", "proposed_tree"], data: data, maximum: Self.maximumBytes,
            integerPaths: Set<[String]>([["protocol"], ["node_count"], ["steps", "[]", "ordinal"], ["steps", "[]", "path", "[]"]]).union(ChildTaskRepairChange.counterPaths), nullableIntegerPaths: [["node_count"]])
        let raw = try JSONDecoder().decode([String: JSON].self, from: parts.metadata)
        guard Set(raw.keys) == Self.keys, expected.allSatisfy({ ChildTaskStructureCommand.exact(raw[$0.key], $0.value) }),
              ChildTaskAdoptionCommand.digest(raw["repair_digest"]), case .bool(let valid)? = raw["proposal_valid"], case .bool(let mayWrite)? = raw["mutation_available"],
              case .bool(let sqlNull)? = raw["original_sql_null"], case .array(let steps)? = raw["steps"], steps.count == changes.count,
              let original = parts.values["original_tree"], let proposed = parts.values["proposed_tree"], original.count <= 2_000_000, proposed.count <= 2_000_000,
              !sqlNull || original == Data("null".utf8), raw["custody_blocker"] == .null || ["indexed_custody", "history_custody"].contains(raw["custody_blocker"]?.text ?? ""),
              !mayWrite || valid && raw["custody_blocker"] == .null else { throw ChildTaskRepairCommand.invalid }
        // Bind the complete original exactly, allowing harmless wire whitespace.
        guard Self.sameJSONValue(original, try Self.reviewSource(review)) else { throw ChildTaskRepairCommand.invalid }
        for (offset, step) in steps.enumerated() {
            guard case .object(let s) = step, Set(s.keys) == ["ordinal", "kind", "path", "before_kind", "after_kind"],
                  s["ordinal"] == .number(Double(offset + 1)), s["kind"] == changes[offset].raw["kind"],
                  ChildTaskStructureCommand.exact(s["path"], changes[offset].raw["path"]),
                  Self.jsonKinds.contains(s["before_kind"]?.text ?? ""), Self.jsonKinds.contains(s["after_kind"]?.text ?? "") else { throw ChildTaskRepairCommand.invalid }
        }
        var items: [ChildTaskAdoptionReview.Item] = []
        if valid {
            guard raw["remaining_issue"] == .null else { throw ChildTaskRepairCommand.invalid }
            let nodes = proposed == Data("null".utf8) ? [] : try JSONDecoder().decode([Node].self, from: proposed)
            var seen = Set<String>()
            func walk(_ nodes: [Node], depth: Int) throws {
                guard depth <= 24 else { throw ChildTaskRepairCommand.invalid }
                for n in nodes {
                    try Task.checkCancellation(); let key = n.id.precomposedStringWithCanonicalMapping
                    guard !n.id.isEmpty, n.id.utf8.count <= 128, key.utf8.count <= 128, seen.insert(key).inserted, items.count < 1000 else { throw ChildTaskRepairCommand.invalid }
                    items.append(.init(id: n.id, title: n.title, depth: depth)); if !n.children.isEmpty { try walk(n.children, depth: depth + 1) }
                }
            }
            try walk(nodes, depth: 1)
            guard try ChildTaskAdoptionReview.count(raw["node_count"], maximum: 1000) == items.count else { throw ChildTaskRepairCommand.invalid }
        } else { guard raw["node_count"] == .null, Self.issues.contains(raw["remaining_issue"]?.text ?? "") else { throw ChildTaskRepairCommand.invalid } }
        self.context = review.context; workspaceID = review.workspaceID; self.changes = changes; metadata = raw; self.original = original; self.proposed = proposed; self.items = items
    }
    private static func reviewSource(_ review: ChildTaskAdoptionReview) throws -> Data {
        guard let source = review.originalSource else { throw ChildTaskRepairCommand.invalid }; return source
    }
    /// A lexical comparison never rounds numbers, merges Unicode keys, changes
    /// object order or normalizes authored strings. Whitespace outside strings
    /// may differ between the two requests. All other differences need a review.
    static func sameJSONValue(_ a: Data, _ b: Data) -> Bool {
        func compact(_ data: Data) -> Data {
            var result = Data(), quoted = false, escaped = false
            for byte in data {
                if quoted { result.append(byte); if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false } }
                else if byte == 34 { quoted = true; result.append(byte) } else if ![9,10,13,32].contains(byte) { result.append(byte) }
            }
            return result
        }
        return compact(a) == compact(b)
    }
}

struct ChildTaskRepairCommand: ReviewedTeamCommand, CustomStringConvertible, CustomDebugStringConvertible {
    static let storagePrefix = "child-repair-command-v1."
    static let maximumStoredBytes = 120_000
    static var invalid: AppFailure { AppFailure(message: "Review this repair against the current task. Your original work is kept.") }
    static let keys: Set<String> = ["protocol", "account", "request_id", "task_id", "task_generation", "project_id", "workspace_id", "review_digest", "repair_digest", "changes"]
    let account: String, origin: String, body: [String: JSON], nodeCount: Int
    var id: String { body["request_id"]!.text }; var rootID: String { body["task_id"]!.text }
    var description: String { "Private reviewed repair request" }; var debugDescription: String { description }
    init(preview: ChildTaskRepairPreview, requestID: UUID = UUID()) throws {
        guard preview.eligible, preview.valid else { throw Self.invalid }
        var body = preview.metadata.filter { Self.keys.contains($0.key) }; body["request_id"] = .string(requestID.uuidString.lowercased())
        try self.init(account: preview.context.account, origin: preview.context.origin, body: body, nodeCount: preview.items.count)
    }
    init(account: String, origin: String, body: [String: JSON], nodeCount: Int) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard origin.utf8.count <= 2048, Set(body.keys) == Self.keys, body["protocol"] == .number(1), body["account"] == .string(account),
              ChildTaskAdoptionCommand.digest(body["review_digest"]), ChildTaskAdoptionCommand.digest(body["repair_digest"]), (0...1000).contains(nodeCount),
              case .array(let values)? = body["changes"], try JSONEncoder().encode(body).count <= 70_000 else { throw Self.invalid }
        _ = try TeamOrganizationValue.id(body["request_id"]); _ = try TeamOrganizationValue.id(body["task_id"])
        for key in ["task_generation", "project_id", "workspace_id"] { _ = try TeamProjectValue.optionalID(body[key]) }
        let changes = try values.map { value -> ChildTaskRepairChange in guard case .object(let r) = value else { throw Self.invalid }; return try .init(raw: r) }
        try ChildTaskRepairChange.validate(changes)
        self.account = account; self.origin = origin; self.body = body; self.nodeCount = nodeCount
    }
    static func == (a: Self, b: Self) -> Bool { a.account == b.account && a.origin == b.origin && a.nodeCount == b.nodeCount && ChildTaskStructureCommand.exact(.object(a.body), .object(b.body)) }
    func review(_ preview: ChildTaskRepairPreview) throws { guard try Self(preview: preview, requestID: UUID(uuidString: id)!) == self else { throw Self.invalid } }
    private enum CodingKeys: String, CodingKey { case account, origin, body, nodeCount }
    init(from decoder: Decoder) throws {
        try structureKeys(decoder, ["account", "origin", "body", "nodeCount"]); let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), body: c.decode([String: JSON].self, forKey: .body), nodeCount: c.decode(Int.self, forKey: .nodeCount))
    }
    init(data: Data) throws {
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: Self.maximumStoredBytes, integerPaths: Set<[String]>([["nodeCount"], ["body", "protocol"]]).union(Set(ChildTaskRepairChange.counterPaths.map { ["body"] + $0 })))
        self = try JSONDecoder().decode(Self.self, from: data)
    }
    func result(_ raw: [String: JSON]) throws -> ChildTaskRepairResult { try .init(command: self, raw: raw) }
}
struct ChildTaskRepairResult: Codable, Equatable, Sendable {
    let raw: [String: JSON]
    var applied: Bool { raw["state"] == .string("applied") }; var closed: Bool { raw["state"] == .string("closed") }; var unknown: Bool { raw["state"] == .string("unknown") }
    private enum CodingKeys: String, CodingKey { case raw }
    init(from decoder: Decoder) throws { try structureKeys(decoder, ["raw"]); raw = try decoder.container(keyedBy: CodingKeys.self).decode([String: JSON].self, forKey: .raw) }
    init(command: ChildTaskRepairCommand, data: Data) throws {
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: 16_384, integerPaths: [["protocol"], ["node_count"], ["archive_bytes"]], nullableIntegerPaths: [["node_count"], ["archive_bytes"]])
        try self.init(command: command, raw: JSONDecoder().decode([String: JSON].self, from: data))
    }
    init(command: ChildTaskRepairCommand, raw: [String: JSON]) throws {
        guard raw["protocol"] == .number(1), raw["account"] == .string(command.account), raw["request_id"] == .string(command.id) else { throw ChildTaskRepairCommand.invalid }
        if raw["state"] == .string("unknown") { guard Set(raw.keys) == ["protocol", "account", "request_id", "state"] else { throw ChildTaskRepairCommand.invalid }; self.raw = raw; return }
        let receiptKeys = ChildTaskRepairCommand.keys.subtracting(["changes"]).union(["state", "replayed", "archive_id", "archive_digest", "archive_bytes", "node_count"])
        guard Set(raw.keys) == receiptKeys, case .bool? = raw["replayed"], ["applied", "closed"].contains(raw["state"]?.text ?? ""),
              command.body.filter({ $0.key != "changes" }).allSatisfy({ ChildTaskStructureCommand.exact(raw[$0.key], $0.value) }) else { throw ChildTaskRepairCommand.invalid }
        if raw["state"] == .string("applied") {
            _ = try TeamOrganizationValue.id(raw["archive_id"])
            guard ChildTaskAdoptionCommand.digest(raw["archive_digest"]), ChildTaskStructureCommand.exact(raw["node_count"], .number(Double(command.nodeCount))), try ChildTaskAdoptionReview.count(raw["archive_bytes"], maximum: 8_000_000) > 0 else { throw ChildTaskRepairCommand.invalid }
        } else { guard ["archive_id", "archive_digest", "archive_bytes", "node_count"].allSatisfy({ raw[$0] == .null }) else { throw ChildTaskRepairCommand.invalid } }
        self.raw = raw
    }
    func agrees(_ other: Self) -> Bool { ChildTaskStructureCommand.exact(.object(raw.filter { $0.key != "replayed" }), .object(other.raw.filter { $0.key != "replayed" })) }
}

/// Original retrieval is separately authorized by the server. Its opaque bytes
/// are suitable for exact export, never for installing partial editable rows.
struct ChildTaskRepairOriginal: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let maximumBytes = 8_100_000
    let data: Data
    var description: String { "Private saved repair original" }; var debugDescription: String { description }
    private struct ArrayMarker: Decodable { init(from d: Decoder) throws { _ = try d.unkeyedContainer() } }
    private struct RootIdentity: Decodable {
        let id: String, task_generation: String?, project_id: String?
        enum CodingKeys: String, CodingKey { case id, task_generation, project_id }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            guard c.contains(.id), c.contains(.task_generation), c.contains(.project_id) else { throw ChildTaskRepairCommand.invalid }
            id = try c.decode(String.self, forKey: .id); task_generation = try c.decodeIfPresent(String.self, forKey: .task_generation); project_id = try c.decodeIfPresent(String.self, forKey: .project_id)
        }
    }
    private struct Header: Decodable {
        let protocolVersion: Int, root: RootIdentity, subtasksSQLNull: Bool, reviewDigest: String, repairDigest: String
        enum CodingKeys: String, CodingKey { case protocolVersion = "protocol", root, subtasksSQLNull = "subtasks_sql_null", projection, records, authority, childHistory = "child_history", reviewDigest = "review_digest", repairDigest = "repair_digest" }
        init(from d: Decoder) throws {
            try structureKeys(d, ["protocol", "root", "subtasks_sql_null", "projection", "records", "authority", "child_history", "review_digest", "repair_digest"])
            let c = try d.container(keyedBy: CodingKeys.self); protocolVersion = try c.decode(Int.self, forKey: .protocolVersion); root = try c.decode(RootIdentity.self, forKey: .root)
            subtasksSQLNull = try c.decode(Bool.self, forKey: .subtasksSQLNull); reviewDigest = try c.decode(String.self, forKey: .reviewDigest); repairDigest = try c.decode(String.self, forKey: .repairDigest)
            guard try c.decodeNil(forKey: .projection), try c.decodeNil(forKey: .authority) else { throw ChildTaskRepairCommand.invalid }
            let records = try c.nestedUnkeyedContainer(forKey: .records); guard records.isAtEnd else { throw ChildTaskRepairCommand.invalid }
            _ = try c.decode(ArrayMarker.self, forKey: .childHistory)
        }
    }
    init(data: Data, command: ChildTaskRepairCommand, result: ChildTaskRepairResult) throws {
        _ = try command.result(result.raw); guard result.applied else { throw ChildTaskRepairCommand.invalid }
        let parts = try ChildTaskRecordRead.separatingJSONField("original", data: data, maximum: Self.maximumBytes, integerPaths: [["protocol"], ["original", "protocol"]], nullableIntegerPaths: [])
        let raw = try JSONDecoder().decode([String: JSON].self, from: parts.metadata)
        guard Set(raw.keys) == ["protocol", "account", "request_id", "archive_id", "archive_digest", "original"], raw["protocol"] == .number(1),
              raw["account"] == .string(command.account), raw["request_id"] == .string(command.id), raw["archive_id"] == result.raw["archive_id"],
              raw["archive_digest"] == result.raw["archive_digest"], parts.value.count == (try ChildTaskAdoptionReview.count(result.raw["archive_bytes"], maximum: 8_000_000)),
              SHA256.hash(data: parts.value).map({ String(format: "%02x", $0) }).joined() == result.raw["archive_digest"]?.text else { throw ChildTaskRepairCommand.invalid }
        let header = try JSONDecoder().decode(Header.self, from: parts.value)
        guard header.protocolVersion == 1, header.root.id == command.rootID, header.root.task_generation == (try TeamProjectValue.optionalID(command.body["task_generation"])),
              header.root.project_id == (try TeamProjectValue.optionalID(command.body["project_id"])), header.reviewDigest == command.body["review_digest"]!.text, header.repairDigest == command.body["repair_digest"]!.text else { throw ChildTaskRepairCommand.invalid }
        self.data = parts.value
    }
}

struct ChildTaskRepairFailure: LocalizedError {
    let reason: ChildTaskFieldWriteFailure.Reason
    var errorDescription: String? {
        switch reason {
        case .unavailable: return "Subtask repair is unavailable or access changed. Your original work and saved request are kept."
        case .review: return "This task changed or needs review. Check and stop the original repair before reviewing a new one."
        case .busy: return "Another change is finishing. Retry the original repair shortly."
        case .limit: return "This repair reached a service or storage limit. Your original work is kept."
        case .closed: return "This repair was stopped. Review the current task before starting another."
        case .unconfirmed: return "Repair couldn’t be confirmed. Check its status or retry the original saved request."
        }
    }
}


struct ChildTaskRepairState: ReviewedTeamFileCommand {
    enum Phase: String, Codable, Sendable { case queued, attempted, applied, closed }
    struct Entry: Codable, Equatable, Sendable {
        let command: ChildTaskRepairCommand
        var phase: Phase = .queued
        var result: ChildTaskRepairResult?
        init(command: ChildTaskRepairCommand, phase: Phase = .queued, result: ChildTaskRepairResult? = nil) { self.command = command; self.phase = phase; self.result = result }
        private enum CodingKeys: String, CodingKey { case command, phase, result }
        init(from decoder: Decoder) throws {
            try structureKeys(decoder, ["command", "phase", "result"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            command = try c.decode(ChildTaskRepairCommand.self, forKey: .command); phase = try c.decode(Phase.self, forKey: .phase); result = try c.decodeIfPresent(ChildTaskRepairResult.self, forKey: .result)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(command, forKey: .command); try c.encode(phase, forKey: .phase); try c.encode(result, forKey: .result)
        }
    }
    static let storagePrefix = "child-repair-state-v1."
    static let fileName = "requests.taskfoldchildrepair"
    static let encryptionContext = "com.taskfold.child-repair-state.v1"
    static let maximumStoredBytes = 5_000_000
    static var invalid: AppFailure { ChildTaskRepairCommand.invalid }
    let account: String, origin: String
    var entries: [Entry]
    init(account: String, origin: String, entries: [Entry] = []) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard entries.count <= 64 else { throw ChildTaskRepairFailure(reason: .limit) }
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
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: Self.maximumStoredBytes, integerPaths: Set<[String]>([["version"], ["entries", "[]", "command", "nodeCount"], ["entries", "[]", "command", "body", "protocol"], ["entries", "[]", "result", "raw", "protocol"], ["entries", "[]", "result", "raw", "node_count"], ["entries", "[]", "result", "raw", "archive_bytes"]]).union(Set(ChildTaskRepairChange.counterPaths.map { ["entries", "[]", "command", "body"] + $0 })), nullableIntegerPaths: [["entries", "[]", "result", "raw", "node_count"], ["entries", "[]", "result", "raw", "archive_bytes"]])
        self = try JSONDecoder().decode(Self.self, from: data)
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

actor ChildTaskRepairJournal {
    let account: String, origin: String
    private let io: any CalendarSecureItemIO, lock: AutomationEnrollmentProcessLock, removalDirectory: URL
    private var key: String { ChildTaskRepairState.storagePrefix + account + "." + CalendarOAuthConfiguration.digest(origin) }
    init(account: String, origin: String, io: any CalendarSecureItemIO, coordinationDirectory: URL, removalDirectory: URL) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        self.account = account; self.origin = origin; self.io = io; lock = .init(directory: coordinationDirectory); self.removalDirectory = removalDirectory
    }
    private func guarded<T>(_ lease: CalendarReadLease?, _ work: () throws -> T) throws -> T {
        try lock.withExclusive(account: account, check: { try lease?.check() }) {
            try AccountRemovalDisk(directory: removalDirectory, account: account).writable { try lease?.check(); return try work() }
        }
    }
    private func read() throws -> ChildTaskRepairState {
        guard let data = try io.read(key: key) else { return try .init(account: account, origin: origin) }
        let state = try ChildTaskRepairState(data: data)
        guard state.account == account, state.origin == origin else { throw ChildTaskRepairCommand.invalid }; return state
    }
    private func write(_ entries: [ChildTaskRepairState.Entry], lease: CalendarReadLease) throws {
        let state = try ChildTaskRepairState(account: account, origin: origin, entries: entries), data = try JSONEncoder().encode(state)
        guard data.count <= ChildTaskRepairState.maximumStoredBytes else { throw ChildTaskRepairFailure(reason: .limit) }
        try lease.check(); try io.write(data, key: key)
    }
    func load() throws -> ChildTaskRepairState { try guarded(nil) { try read() } }
    func enqueue(_ command: ChildTaskRepairCommand, lease: CalendarReadLease) throws {
        try guarded(lease) {
            guard command.account == account, command.origin == origin else { throw ChildTaskRepairCommand.invalid }
            var state = try read()
            if let old = state.entries.first(where: { $0.command.id == command.id }) { guard old.command == command, old.phase != .closed else { throw ChildTaskRepairCommand.invalid }; return }
            guard !state.entries.contains(where: { ($0.phase == .queued || $0.phase == .attempted) && $0.command.rootID == command.rootID }) else { throw ChildTaskRepairFailure(reason: .busy) }
            state.entries.append(.init(command: command)); try write(state.entries, lease: lease)
        }
    }
    func attempt(_ command: ChildTaskRepairCommand, lease: CalendarReadLease) throws -> ChildTaskRepairState.Entry {
        try guarded(lease) {
            var state = try read(); guard let i = state.entries.firstIndex(where: { $0.command == command }) else { throw ChildTaskRepairCommand.invalid }
            if state.entries[i].phase == .queued { state.entries[i].phase = .attempted; try write(state.entries, lease: lease) }
            return state.entries[i]
        }
    }
    func settle(_ command: ChildTaskRepairCommand, result: ChildTaskRepairResult, lease: CalendarReadLease) throws {
        try guarded(lease) {
            _ = try command.result(result.raw); guard !result.unknown else { throw ChildTaskRepairCommand.invalid }
            var state = try read(); guard let i = state.entries.firstIndex(where: { $0.command == command }), state.entries[i].phase != .queued else { throw ChildTaskRepairCommand.invalid }
            if let old = state.entries[i].result { guard old.agrees(result) else { throw ChildTaskRepairCommand.invalid }; return }
            state.entries[i].phase = result.applied ? .applied : .closed; state.entries[i].result = result; try write(state.entries, lease: lease)
        }
    }
    func discard(_ command: ChildTaskRepairCommand, lease: CalendarReadLease) throws {
        try guarded(lease) {
            var state = try read(); guard let i = state.entries.firstIndex(where: { $0.command == command }), state.entries[i].phase != .attempted else { throw ChildTaskRepairCommand.invalid }
            state.entries.remove(at: i)
            try write(state.entries, lease: lease)
        }
    }
    func removeAccount() throws { try lock.withExclusive(account: account) { try io.remove(key: key) } }
}

enum ChildTaskRepairOperation: String, Sendable { case send, check, close }
@MainActor protocol ChildTaskRepairService: AnyObject {
    func childTaskRepair(_ command: ChildTaskRepairCommand, operation: ChildTaskRepairOperation, session: UUID) async throws -> ChildTaskRepairResult
}
extension Backend: ChildTaskRepairService {}
@MainActor @Observable final class ChildTaskRepairModel {
    private(set) var entries: [ChildTaskRepairState.Entry] = []
    private(set) var busy = false
    private(set) var loaded = false
    private(set) var message: String?
    let scope: ChildTaskFieldClientScope
    private let journal: ChildTaskRepairJournal, service: any ChildTaskRepairService
    private let current: () -> ChildTaskFieldClientScope?
    private let canSend: (ChildTaskRepairCommand) -> Bool
    private let admit: (ChildTaskRepairCommand) async throws -> Void
    private let reviewCurrent: (ChildTaskRepairPreview) -> Bool
    private let lease = CalendarReadLease()
    private var closed = false
    init(scope: ChildTaskFieldClientScope, journal: ChildTaskRepairJournal, service: any ChildTaskRepairService, current: @escaping () -> ChildTaskFieldClientScope?, canSend: @escaping (ChildTaskRepairCommand) -> Bool, admit: @escaping (ChildTaskRepairCommand) async throws -> Void, reviewCurrent: @escaping (ChildTaskRepairPreview) -> Bool) {
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
            if error is AccountSessionAuthorizationRequired { message = "Sign in again to check your saved repair." }
            else if let failure = error as? ChildTaskRepairFailure { message = failure.localizedDescription }
            else if let failure = error as? AppFailure { message = failure.localizedDescription }
            else { message = "Repair couldn’t be confirmed. Your saved request is kept; check its status before starting another." }
            return false
        }
    }
    func load() async { _ = await work { try await update() } }
    func queue(_ command: ChildTaskRepairCommand, review: ChildTaskRepairPreview) async -> Bool {
        await work {
            guard ChildTaskFieldClientScope(review.context) == scope, reviewCurrent(review) else { throw CancellationError() }
            try command.review(review)
            try await admit(command); try check()
            guard reviewCurrent(review) else { throw CancellationError() }
            try await journal.enqueue(command, lease: lease); try check(); try await update(); message = "Repair saved on this device."
        }
    }
    func run(_ command: ChildTaskRepairCommand, operation: ChildTaskRepairOperation) async -> Bool {
        let completed = await work {
            guard command.account == scope.account, command.origin == scope.origin else { throw CancellationError() }
            if operation == .send { guard canSend(command) else { throw ChildTaskRepairFailure(reason: .unavailable) }; try await admit(command); try check() }
            let entry = try await journal.attempt(command, lease: lease); try check()
            let result: ChildTaskRepairResult
            if let old = entry.result { result = try command.result(old.raw) }
            else {
                if operation == .send { guard canSend(command) else { throw ChildTaskRepairFailure(reason: .unavailable) }; try await admit(command); try check() }
                result = try await service.childTaskRepair(command, operation: operation, session: scope.session); try check()
                _ = try command.result(result.raw)
                guard operation == .check || !result.unknown else { throw ChildTaskRepairFailure(reason: .unconfirmed) }
                if !result.unknown { try await journal.settle(command, result: result, lease: lease); try check() }
            }
            try await update()
            message = result.applied ? "Repair saved. Your original is kept." : result.closed ? "Repair stopped. Your original task is unchanged by this request." : "No confirmation yet. Retry the original repair, or stop it before making a new one."
        }
        // A file write can finish before reporting an I/O error. Trust only the
        // reloaded, fully validated proof; never retry with a different identity.
        if !completed, (try? check()) != nil, let result = entries.first(where: { $0.command == command })?.result {
            message = result.applied ? "Repair saved. Your original is kept." : "Repair stopped. Your original task is unchanged by this request."
            return true
        }
        return completed
    }
    func discard(_ command: ChildTaskRepairCommand) async {
        _ = await work { try await journal.discard(command, lease: lease); try check(); try await update(); message = "Saved repair history removed. Your tasks are unchanged." }
    }
}

/// Read-only structure for guided repairs. Unknown values remain in the opaque
/// source; numbers are classified without ever decoding them as Double.
struct ChildTaskRepairOutline: Sendable {
    enum Kind: String, Sendable { case object, array, string, number, boolean, null }
    struct Item: Identifiable, Sendable {
        let path: [Int], title: String, kind: Kind, referenceNeedsRepair: Bool, malformedChildren: Bool, siblings: Int
        var id: String { path.map(String.init).joined(separator: ".") }
        var depth: Int { path.count }
    }
    let rootKind: Kind
    let items: [Item]
    let rootCount: Int
    private final class Budget { var count = 0 }
    private static let budgetKey = CodingUserInfoKey(rawValue: "taskfold.repair-outline-budget")!
    private enum Keys: String, CodingKey { case id, title, subtasks }
    private static func kind(_ d: Decoder) throws -> Kind {
        if (try? d.container(keyedBy: Keys.self)) != nil { return .object }
        if (try? d.unkeyedContainer()) != nil { return .array }
        let c = try d.singleValueContainer()
        if c.decodeNil() { return .null }; if (try? c.decode(String.self)) != nil { return .string }; if (try? c.decode(Bool.self)) != nil { return .boolean }; return .number
    }
    private static func label(_ value: String) -> String {
        let limited = String(String.UnicodeScalarView(value.unicodeScalars.prefix(160)))
        return limited.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private struct Node: Decodable {
        let kind: Kind, reference: String?, title: String, malformedChildren: Bool, children: [Node]
        init(from d: Decoder) throws {
            try Task.checkCancellation()
            guard let budget = d.userInfo[budgetKey] as? Budget, budget.count < 1000, d.codingPath.count <= 128 else { throw ChildTaskRepairOutline.unavailable }
            budget.count += 1; kind = try ChildTaskRepairOutline.kind(d)
            if kind == .object {
                let c = try d.container(keyedBy: Keys.self); reference = try? c.decode(String.self, forKey: .id)
                let name = ChildTaskRepairOutline.label((try? c.decode(String.self, forKey: .title)) ?? "")
                title = name.isEmpty ? "Untitled task" : name
                if !c.contains(.subtasks) { children = []; malformedChildren = false }
                else if try c.decodeNil(forKey: .subtasks) { children = []; malformedChildren = false }
                else if (try? c.nestedUnkeyedContainer(forKey: .subtasks)) != nil { children = try c.decode([Node].self, forKey: .subtasks); malformedChildren = false }
                else { children = []; malformedChildren = true }
            } else {
                reference = nil; children = []; malformedChildren = false
                let value = kind == .string ? (try d.singleValueContainer().decode(String.self)) : ""
                let name = ChildTaskRepairOutline.label(value); title = name.isEmpty ? "Recovered item" : name
            }
        }
    }
    private struct Root: Decodable {
        let kind: Kind, nodes: [Node]
        init(from d: Decoder) throws {
            kind = try ChildTaskRepairOutline.kind(d)
            if kind == .array { var c = try d.unkeyedContainer(); var rows: [Node] = []; while !c.isAtEnd { rows.append(try c.decode(Node.self)) }; nodes = rows }
            else { nodes = [] }
        }
    }
    static var unavailable: AppFailure { AppFailure(message: "This older structure needs a larger-work review. Its complete original is kept; export it to continue.") }
    init(data: Data) throws {
        guard data.count <= 2_000_000 else { throw Self.unavailable }
        _ = try ChildTaskRecordRead.separatingJSONField("tree", data: Data("{\"tree\":".utf8) + data + Data("}".utf8), maximum: 2_000_020, integerPaths: [], nullableIntegerPaths: [])
        let decoder = JSONDecoder(); decoder.userInfo[Self.budgetKey] = Budget(); let root = try decoder.decode(Root.self, from: data)
        var references: [String: Int] = [:]
        func valid(_ reference: String?) -> String? {
            guard let reference, !reference.isEmpty, reference.utf8.count <= 128 else { return nil }; let key = reference.precomposedStringWithCanonicalMapping
            return key.utf8.count <= 128 ? key : nil
        }
        func count(_ nodes: [Node]) { for node in nodes { if let key = valid(node.reference) { references[key, default: 0] += 1 }; count(node.children) } }
        count(root.nodes); var items: [Item] = []
        func walk(_ nodes: [Node], path: [Int]) throws {
            guard path.count < 64 || nodes.isEmpty else { throw Self.unavailable }
            for (position,node) in nodes.enumerated() {
                let key = valid(node.reference)
                items.append(.init(path: path + [position], title: node.title, kind: node.kind, referenceNeedsRepair: node.kind == .object && (key == nil || (key.flatMap { references[$0] } ?? 0) > 1), malformedChildren: node.malformedChildren, siblings: nodes.count))
                try walk(node.children, path: path + [position])
            }
        }
        try walk(root.nodes, path: []); rootKind = root.kind; self.items = items; rootCount = root.nodes.count
    }
}
