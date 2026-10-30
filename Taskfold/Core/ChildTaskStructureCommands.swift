import Foundation

private struct ChildStructureKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
func structureKeys(_ decoder: Decoder, _ expected: Set<String>) throws {
    let container = try decoder.container(keyedBy: ChildStructureKey.self)
    guard Set(container.allKeys.map(\.stringValue)) == expected else { throw ChildTaskStructureCommand.invalid }
}

/// A durable intent, not a replacement task. Sending still requires a current
/// live lease; neither construction nor receipt validation changes saved work.
struct ChildTaskStructureCommand: ReviewedTeamCommand, CustomStringConvertible, CustomDebugStringConvertible {
    enum Action: String, Sendable { case insert, move, delete, undo }
    struct Original: Codable, Equatable, Sendable {
        let body: [String: JSON]?
        let receipt: [String: JSON]
        init(body: [String: JSON]?, receipt: [String: JSON]) { self.body = body; self.receipt = receipt }
        static func == (a: Self, b: Self) -> Bool {
            ChildTaskStructureCommand.exact(a.body.map(JSON.object), b.body.map(JSON.object)) && ChildTaskStructureCommand.exact(.object(a.receipt), .object(b.receipt))
        }
        private enum CodingKeys: String, CodingKey { case body, receipt }
        init(from decoder: Decoder) throws {
            try structureKeys(decoder, ["body", "receipt"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            body = try c.decodeIfPresent([String: JSON].self, forKey: .body)
            receipt = try c.decode([String: JSON].self, forKey: .receipt)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(body, forKey: .body); try c.encode(receipt, forKey: .receipt)
        }
    }
    static let storagePrefix = "child-structure-command-v1."
    static let maximumStoredBytes = 800_000
    static let maximumRequestBytes = 384_000
    static var invalid: AppFailure { AppFailure(message: "Review this saved hierarchy change before sending it. Your saved work is unchanged.") }
    static let scopeKeys = ["protocol", "account", "task_id", "task_generation", "project_id"]
    static let baseKeys = Set(scopeKeys + ["request_id", "structure_revision", "action"])
    let account: String, origin: String
    let body: [String: JSON]
    let original: Original?
    var id: String { body["request_id"]!.text }
    var action: Action { Action(rawValue: body["action"]!.text)! }
    var description: String { "Private child hierarchy request" }
    var debugDescription: String { description }

    init(insert node: JSON, parent: String?, index: Int, read: ChildTaskStructureRead, requestID: UUID = UUID()) throws {
        var body = Self.base(read, .insert, requestID)
        body["parent_key"] = parent.map(JSON.string) ?? .null; body["index"] = .number(Double(index)); body["node"] = node
        try self.init(account: read.context.account, origin: read.context.origin, body: body)
        try review(read)
    }
    init(move key: String, parent: String?, index: Int, read: ChildTaskStructureRead, requestID: UUID = UUID()) throws {
        guard let node = read.records.nodes[key] else { throw Self.invalid }
        var body = Self.base(read, .move, requestID)
        body["node_key"] = .string(key); body["incarnation"] = .string(node.incarnation)
        body["parent_key"] = parent.map(JSON.string) ?? .null; body["index"] = .number(Double(index))
        try self.init(account: read.context.account, origin: read.context.origin, body: body)
        try review(read)
    }
    init(delete key: String, read: ChildTaskStructureRead, requestID: UUID = UUID()) throws {
        guard let node = read.records.nodes[key] else { throw Self.invalid }
        var body = Self.base(read, .delete, requestID)
        body["node_key"] = .string(key); body["incarnation"] = .string(node.incarnation)
        body["subtree_versions"] = .object(Self.versions(node, read))
        try self.init(account: read.context.account, origin: read.context.origin, body: body)
        try review(read)
    }
    init(undo command: Self, receipt: ChildTaskStructureReceipt, read: ChildTaskStructureRead, requestID: UUID = UUID()) throws {
        guard command.action != .undo else { throw Self.invalid }
        _ = try command.confirmed(receipt.raw)
        var body = Self.base(read, .undo, requestID); body["undo_of"] = .string(command.id)
        try self.init(account: command.account, origin: command.origin, body: body, original: .init(body: command.body, receipt: receipt.raw))
        try review(read)
    }
    /// Recovery after device/journal loss uses the server's bounded deletion
    /// metadata. No archived title, fields or subtree is downloaded or invented.
    init(restoring archive: ChildTaskStructureReceipt, read: ChildTaskStructureRead, requestID: UUID = UUID()) throws {
        guard archive.raw["action"] == .string("delete"), archive.raw["replayed"] == .bool(true) else { throw Self.invalid }
        var body = Self.base(read, .undo, requestID); body["undo_of"] = archive.raw["request_id"]
        try self.init(account: read.context.account, origin: read.context.origin, body: body, original: .init(body: nil, receipt: archive.raw))
        try review(read)
    }
    private static func base(_ read: ChildTaskStructureRead, _ action: Action, _ requestID: UUID) -> [String: JSON] {
        ["protocol": .number(1), "account": .string(read.context.account), "task_id": .string(read.context.root.id),
         "task_generation": read.context.root["task_generation"], "project_id": read.context.root["project_id"],
         "request_id": .string(requestID.uuidString.lowercased()), "structure_revision": .number(read.structureRevision), "action": .string(action.rawValue)]
    }
    init(account: String, origin: String, body: [String: JSON], original: Original? = nil) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard origin.utf8.count <= 2048, body["protocol"] == .number(1), body["account"] == .string(account),
              case .string(let value)? = body["action"], let action = Action(rawValue: value) else { throw Self.invalid }
        for key in ["request_id", "task_id"] { _ = try TeamOrganizationValue.id(body[key]) }
        for key in ["task_generation", "project_id"] { _ = try TeamProjectValue.optionalID(body[key]) }
        guard try TeamProjectValue.revision(body["structure_revision"]) < 9_007_199_254_740_991 else { throw Self.invalid }
        let extra: Set<String>
        switch action {
        case .insert: extra = ["parent_key", "index", "node"]
        case .move: extra = ["parent_key", "index", "node_key", "incarnation"]
        case .delete: extra = ["node_key", "incarnation", "subtree_versions"]
        case .undo: extra = ["undo_of"]
        }
        guard Set(body.keys) == Self.baseKeys.union(extra) else { throw Self.invalid }
        if action == .insert || action == .move {
            if body["parent_key"] != .null { _ = try Self.key(body["parent_key"]) }
            guard case .number(let index)? = body["index"], index.isFinite, index.sign == .plus, index.rounded() == index, (0...1000).contains(index) else { throw Self.invalid }
        }
        if action == .move || action == .delete {
            _ = try Self.key(body["node_key"]); _ = try TeamOrganizationValue.id(body["incarnation"])
        }
        if action == .insert { _ = try Self.newNodes(body["node"]) }
        if action == .delete {
            guard case .object(let versions)? = body["subtree_versions"], !versions.isEmpty, versions.count <= 1000 else { throw Self.invalid }
            for (key, value) in versions {
                _ = try Self.key(.string(key))
                guard case .object(let version) = value, Set(version.keys) == ["incarnation", "revision"] else { throw Self.invalid }
                _ = try TeamOrganizationValue.id(version["incarnation"]); _ = try TeamProjectValue.revision(version["revision"])
            }
            guard versions[body["node_key"]!.text]?.object["incarnation"] == body["incarnation"] else { throw Self.invalid }
        }
        if action == .undo {
            guard let original else { throw Self.invalid }
            let receipt: ChildTaskStructureReceipt
            if let sourceBody = original.body {
                let source = try Self(account: account, origin: origin, body: sourceBody)
                receipt = try source.confirmed(original.receipt)
            } else {
                receipt = try ChildTaskStructureReceipt(account: account, raw: original.receipt)
                guard receipt.raw["action"] == .string("delete"), receipt.raw["replayed"] == .bool(true) else { throw Self.invalid }
            }
            guard body["undo_of"] == receipt.raw["request_id"], body["request_id"] != receipt.raw["request_id"],
                  Self.scopeKeys.allSatisfy({ Self.exact(body[$0], receipt.raw[$0]) }),
                  body["structure_revision"] == receipt.raw["after_revision"] else { throw Self.invalid }
        } else if original != nil { throw Self.invalid }
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard try encoder.encode(body).count <= Self.maximumRequestBytes else { throw Self.invalid }
        self.account = account; self.origin = origin; self.body = body; self.original = original
        guard try TaskfoldJSONEncoder().encode(self).count <= Self.maximumStoredBytes else { throw Self.invalid }
    }
    /// Encrypted storage readers must use this bounded entry point before
    /// Codable decoding; Double decoding alone cannot certify wire counters.
    init(data: Data) throws {
        let raw = try ChildTaskStructureWire.object(data, maximum: Self.maximumStoredBytes, integerPaths: [])
        var paths = Self.counterPaths(raw["body"]?.object ?? [:], prefix: ["body"])
        if case .object(let original)? = raw["original"] {
            paths.formUnion(Self.counterPaths(original["body"]?.object ?? [:], prefix: ["original", "body"]))
            paths.formUnion(ChildTaskStructureReceipt.integerPaths.map { ["original", "receipt"] + $0 })
        }
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: Self.maximumStoredBytes, integerPaths: paths)
        self = try TaskfoldJSONDecoder().decode(Self.self, from: data)
    }
    static func counterPaths(_ body: [String: JSON], prefix: [String]) -> Set<[String]> {
        var paths: Set<[String]> = [prefix + ["protocol"], prefix + ["structure_revision"], prefix + ["index"]]
        if case .object(let versions)? = body["subtree_versions"] {
            for key in versions.keys { paths.insert(prefix + ["subtree_versions", key, "revision"]) }
        }
        return paths
    }
    static func key(_ value: JSON?) throws -> String {
        guard case .string(let text)? = value, !text.isEmpty, text.utf8.count <= 128,
              text.utf8.elementsEqual(text.precomposedStringWithCanonicalMapping.utf8) else { throw invalid }
        return text
    }
    static func exact(_ a: JSON?, _ b: JSON?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return AuthoredValueComparison.exactJSON(a, b)
    }
    /// Only new authored fields are accepted. Existing opaque/history/file data
    /// is preserved by server moves and archive restoration, never resubmitted.
    private static func newNodes(_ value: JSON?) throws -> [(key: String, depth: Int)] {
        guard let value else { throw invalid }
        var result: [(String, Int)] = [], keys = Set<String>()
        func visit(_ value: JSON, depth: Int) throws {
            guard depth <= 24, result.count < 1000, case .object(let fields) = value,
                  case .string(let rawID)? = fields["id"], fields["title"] != nil else { throw invalid }
            guard !rawID.isEmpty, rawID.utf8.count <= 128 else { throw invalid }
            let key = try Self.key(.string(rawID.precomposedStringWithCanonicalMapping))
            guard keys.insert(key).inserted else { throw invalid }
            for (name, value) in fields {
                switch name {
                case "id": break
                case "subtasks": guard value == .null || { if case .array = value { return true }; return false }() else { throw invalid }
                case "is_heading": guard case .bool = value else { throw invalid }
                case "completed": guard value == .bool(false) else { throw invalid }
                case "completed_at": guard value == .null else { throw invalid }
                default: guard ChildTaskFieldCommand.fields.contains(name) else { throw invalid }; try ChildTaskFieldCommand.validate(name, value)
                }
            }
            result.append((key, depth))
            for child in fields["subtasks"]?.list ?? [] { try visit(child, depth: depth + 1) }
        }
        try visit(value, depth: 1); return result
    }
    private static func versions(_ node: ChildTaskRecordRead.Node, _ read: ChildTaskStructureRead) -> [String: JSON] {
        Dictionary(uniqueKeysWithValues: read.records.orderedNodes.filter { $0.path.starts(with: node.path) }.map {
            ($0.key, .object(["incarnation": .string($0.incarnation), "revision": .number($0.revision)]))
        })
    }
    func review(_ read: ChildTaskStructureRead) throws {
        guard read.context.account == account, read.context.origin == origin,
              body["task_id"] == .string(read.context.root.id), Self.exact(body["task_generation"], read.context.root["task_generation"]),
              Self.exact(body["project_id"], read.context.root["project_id"]), body["structure_revision"] == .number(read.structureRevision) else { throw Self.invalid }
        let node = read.records.nodes[body["node_key"]?.text ?? ""]
        if action == .move || action == .delete {
            guard let node, body["incarnation"] == .string(node.incarnation) else { throw Self.invalid }
        }
        if action == .delete {
            guard let node, Self.exact(body["subtree_versions"], .object(Self.versions(node, read))) else { throw Self.invalid }
        }
        if action == .insert || action == .move {
            let parentKey = body["parent_key"] == .null ? nil : body["parent_key"]!.text
            let destination = parentKey.flatMap { read.records.nodes[$0] }
            guard parentKey == nil || destination != nil else { throw Self.invalid }
            if let node, let destination, destination.path.starts(with: node.path) { throw Self.invalid }
            let siblings = read.records.orderedNodes.filter { $0.parent == parentKey && $0.key != node?.key }
            guard case .number(let index)? = body["index"], index <= Double(siblings.count) else { throw Self.invalid }
            if let node, node.parent == parentKey, Double(node.position) == index { throw Self.invalid }
            let depth = destination?.path.count ?? 0
            if action == .insert {
                let new = try Self.newNodes(body["node"])
                guard read.records.nodes.count + new.count <= 1000,
                      new.allSatisfy({ read.records.nodes[$0.key] == nil && depth + $0.depth <= 24 }) else { throw Self.invalid }
            } else if let node {
                guard read.records.orderedNodes.filter({ $0.path.starts(with: node.path) }).allSatisfy({ depth + $0.path.count - node.path.count + 1 <= 24 }) else { throw Self.invalid }
            }
        }
        if action == .undo {
            guard let original else { throw Self.invalid }
            let key = try Self.key(original.receipt["node_key"])
            if original.receipt["action"] == .string("delete") {
                guard read.records.nodes[key] == nil else { throw Self.invalid }
            } else {
                guard let current = read.records.nodes[key], original.receipt["incarnation"] == .string(current.incarnation) else { throw Self.invalid }
            }
            // The server alone owns the archived subtree and insertion digest.
            // This local check cannot certify that private content is restorable.
        }
    }
    func confirmed(_ raw: [String: JSON]) throws -> ChildTaskStructureReceipt {
        let receipt = try ChildTaskStructureReceipt(account: account, raw: raw)
        guard (Self.scopeKeys + ["request_id", "action"]).allSatisfy({ Self.exact(raw[$0], body[$0]) }),
              raw["before_revision"] == body["structure_revision"], raw["undo_of"] == (body["undo_of"] ?? .null) else { throw Self.invalid }
        switch action {
        case .insert:
            guard raw["node_key"] == .string(body["node"]!.object["id"]!.text.precomposedStringWithCanonicalMapping), raw["incarnation"] != .null else { throw Self.invalid }
        case .move:
            guard Self.exact(raw["node_key"], body["node_key"]), raw["incarnation"] == body["incarnation"] else { throw Self.invalid }
        case .delete:
            guard Self.exact(raw["node_key"], body["node_key"]), raw["incarnation"] == .null else { throw Self.invalid }
        case .undo:
            guard let original, Self.exact(raw["node_key"], original.receipt["node_key"]) else { throw Self.invalid }
            switch original.receipt["action"] {
            case .string("insert"): guard raw["incarnation"] == .null else { throw Self.invalid }
            case .string("move"): guard raw["incarnation"] == original.receipt["incarnation"] else { throw Self.invalid }
            case .string("delete"): guard raw["incarnation"] != .null, (original.body == nil || raw["incarnation"] != original.body?["incarnation"]) else { throw Self.invalid }
            default: throw Self.invalid
            }
        }
        return receipt
    }
    static func == (a: Self, b: Self) -> Bool {
        a.account == b.account && a.origin == b.origin && exact(.object(a.body), .object(b.body)) && a.original == b.original
    }
    private enum CodingKeys: String, CodingKey { case account, origin, body, original }
    init(from decoder: Decoder) throws {
        try structureKeys(decoder, ["account", "origin", "body", "original"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), body: c.decode([String: JSON].self, forKey: .body), original: c.decodeIfPresent(Original.self, forKey: .original))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(account, forKey: .account); try c.encode(origin, forKey: .origin)
        try c.encode(body, forKey: .body); try c.encode(original, forKey: .original)
    }
}

/// Immutable metadata only. Standalone decoding is not authority to Undo a
/// request; commands must bind this proof to their original exact intent.
struct ChildTaskStructureReceipt: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let maximumBytes = 8_000
    let raw: [String: JSON]
    var description: String { "Private child hierarchy confirmation" }
    var debugDescription: String { description }
    init(account: String, raw: [String: JSON]) throws {
        guard TeamProjectValue.id(account), Set(raw.keys) == Set(ChildTaskStructureCommand.scopeKeys + ["request_id", "action", "undo_of", "before_revision", "after_revision", "node_key", "incarnation", "replayed"]),
              raw["protocol"] == .number(1), raw["account"] == .string(account), case .bool? = raw["replayed"],
              case .string(let text)? = raw["action"], let action = ChildTaskStructureCommand.Action(rawValue: text) else { throw ChildTaskStructureCommand.invalid }
        for key in ["request_id", "task_id"] { _ = try TeamOrganizationValue.id(raw[key]) }
        for key in ["task_generation", "project_id", "incarnation"] { _ = try TeamProjectValue.optionalID(raw[key]) }
        let before = try TeamProjectValue.revision(raw["before_revision"]), after = try TeamProjectValue.revision(raw["after_revision"])
        guard before < 9_007_199_254_740_991, after == before + 1 else { throw ChildTaskStructureCommand.invalid }
        _ = try ChildTaskStructureCommand.key(raw["node_key"])
        if action == .undo {
            _ = try TeamOrganizationValue.id(raw["undo_of"])
            guard raw["undo_of"] != raw["request_id"] else { throw ChildTaskStructureCommand.invalid }
        } else {
            guard raw["undo_of"] == .null, (action == .delete) == (raw["incarnation"] == .null) else { throw ChildTaskStructureCommand.invalid }
        }
        guard try TaskfoldJSONEncoder().encode(raw).count <= Self.maximumBytes else { throw ChildTaskStructureCommand.invalid }
        self.raw = raw
    }
    init(command: ChildTaskStructureCommand, data: Data) throws {
        let raw = try ChildTaskStructureWire.object(data, maximum: Self.maximumBytes, integerPaths: Self.integerPaths)
        self = try command.confirmed(raw)
    }
    static let integerPaths: Set<[String]> = [["protocol"], ["before_revision"], ["after_revision"]]
    func agrees(_ other: Self) -> Bool {
        ChildTaskStructureCommand.exact(.object(raw.filter { $0.key != "replayed" }), .object(other.raw.filter { $0.key != "replayed" }))
    }
    private enum CodingKeys: String, CodingKey { case raw }
    init(from decoder: Decoder) throws {
        try structureKeys(decoder, ["raw"])
        let c = try decoder.container(keyedBy: CodingKeys.self), raw = try c.decode([String: JSON].self, forKey: .raw)
        try self.init(account: try TeamOrganizationValue.id(raw["account"]), raw: raw)
    }
}

struct ChildTaskStructureResolution: Codable, Equatable, Sendable {
    let raw: [String: JSON]
    let receipt: ChildTaskStructureReceipt?
    var closed: Bool { receipt == nil }
    init(command: ChildTaskStructureCommand, raw: [String: JSON]) throws {
        guard Set(raw.keys) == ["protocol", "account", "request_id", "outcome", "receipt"], raw["protocol"] == .number(1),
              raw["account"] == .string(command.account), raw["request_id"] == .string(command.id) else { throw ChildTaskStructureCommand.invalid }
        switch raw["outcome"] {
        case .string("closed"): guard raw["receipt"] == .null else { throw ChildTaskStructureCommand.invalid }; receipt = nil
        case .string("applied"):
            guard case .object(let proof)? = raw["receipt"] else { throw ChildTaskStructureCommand.invalid }
            receipt = try command.confirmed(proof)
        default: throw ChildTaskStructureCommand.invalid
        }
        self.raw = raw
    }
    init(command: ChildTaskStructureCommand, data: Data) throws {
        let paths = Set(ChildTaskStructureReceipt.integerPaths.map { ["receipt"] + $0 }).union([["protocol"]])
        try self.init(command: command, raw: ChildTaskStructureWire.object(data, maximum: 12_000, integerPaths: paths))
    }
}
extension ChildTaskStructureResolution {
    private enum CodingKeys: String, CodingKey { case raw }
    init(from decoder: Decoder) throws {
        try structureKeys(decoder, ["raw"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        raw = try c.decode([String: JSON].self, forKey: .raw)
        if case .object(let proof)? = raw["receipt"] {
            receipt = try .init(account: try TeamOrganizationValue.id(raw["account"]), raw: proof)
        } else { receipt = nil }
        // The owning journal revalidates this decoded decision against its exact
        // command. Decoding alone never authorizes replacement or forgetting.
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(raw, forKey: .raw)
    }
    init(command: ChildTaskStructureCommand, receipt: ChildTaskStructureReceipt) throws {
        try self.init(command: command, raw: ["protocol": .number(1), "account": .string(command.account), "request_id": .string(command.id), "outcome": .string("applied"), "receipt": .object(receipt.raw)])
    }
}
struct ChildTaskStructureUndoArchives: Sendable {
    let account: String
    let entries: [ChildTaskStructureReceipt]
    init(account: String, data: Data) throws {
        let paths = Set(ChildTaskStructureReceipt.integerPaths.map { ["entries", "[]"] + $0 }).union([["protocol"]])
        let raw = try ChildTaskStructureWire.object(data, maximum: 65_536, integerPaths: paths)
        guard TeamProjectValue.id(account), Set(raw.keys) == ["protocol", "account", "entries"], raw["protocol"] == .number(1),
              raw["account"] == .string(account), case .array(let values)? = raw["entries"], values.count <= 64 else { throw ChildTaskStructureCommand.invalid }
        var ids = Set<String>()
        entries = try values.map {
            guard case .object(let row) = $0, row["action"] == .string("delete"), row["replayed"] == .bool(true),
                  ids.insert(row["request_id"]?.text ?? "").inserted else { throw ChildTaskStructureCommand.invalid }
            return try ChildTaskStructureReceipt(account: account, raw: row)
        }
        self.account = account
    }
}
struct ChildTaskStructureUndoDisposal: Sendable {
    let account: String, origin: String, requestID: String
    init(account: String, origin: String, requestID: String) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard origin.utf8.count <= 2048, TeamProjectValue.id(requestID) else { throw ChildTaskStructureCommand.invalid }
        self.account = account; self.origin = origin; self.requestID = requestID
    }
    func confirmed(_ data: Data) throws -> ChildTaskStructureUndoDisposalReceipt {
        try confirmed(ChildTaskStructureWire.object(data, maximum: 4_000, integerPaths: [["protocol"]]))
    }
    func confirmed(_ raw: [String: JSON]) throws -> ChildTaskStructureUndoDisposalReceipt {
        guard Set(raw.keys) == ["protocol", "account", "request_id", "outcome"], raw["protocol"] == .number(1),
              raw["account"] == .string(account), raw["request_id"] == .string(requestID), raw["outcome"] == .string("forgotten") else { throw ChildTaskStructureCommand.invalid }
        return .init(raw: raw)
    }
}
struct ChildTaskStructureUndoDisposalReceipt: Codable, Equatable, Sendable {
    let raw: [String: JSON]
    private enum CodingKeys: String, CodingKey { case raw }
    init(raw: [String: JSON]) { self.raw = raw }
    init(from decoder: Decoder) throws {
        try structureKeys(decoder, ["raw"])
        let c = try decoder.container(keyedBy: CodingKeys.self); raw = try c.decode([String: JSON].self, forKey: .raw)
    }
}
private enum ChildTaskStructureWire {
    static func object(_ data: Data, maximum: Int, integerPaths: Set<[String]>) throws -> [String: JSON] {
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: maximum, integerPaths: integerPaths)
        return try TaskfoldJSONDecoder().decode([String: JSON].self, from: data)
    }
}
