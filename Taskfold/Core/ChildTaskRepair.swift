import Foundation
import CryptoKit
import Observation

/// Choices contain identities and lifecycle consent only. Source trees/notes
/// remain on their exact, ephemeral comparison/export path.
struct ChildCopyMapping: Codable, Equatable, Sendable {
    let raw: [String: JSON]
    var nodes: [[String: JSON]] { raw["nodes"]!.list.map(\.object) }
    var retired: [[String: JSON]] { raw["retire"]!.list.map(\.object) }
    static func == (a: Self, b: Self) -> Bool { ChildTaskStructureCommand.exact(.object(a.raw), .object(b.raw)) }
    static func key(_ value: JSON?) -> String? {
        guard case .string(let key)? = value, !key.isEmpty, key.utf8.count <= 128,
              key.utf8.elementsEqual(key.precomposedStringWithCanonicalMapping.utf8) else { return nil }; return key
    }
    init(raw: [String: JSON], incomplete: Bool = false) throws {
        guard Set(raw.keys) == ["version", "nodes", "retire"], raw["version"] == .number(1),
              case .array(let nodes)? = raw["nodes"], nodes.count <= 1000,
              case .array(let retired)? = raw["retire"], retired.count <= 1000,
              try TaskfoldJSONEncoder().encode(raw).count <= 512_000 else { throw ChildTaskRepairCommand.invalid }
        var sources = Set<String>(), targets = Set<String>(), removed = Set<String>()
        for value in nodes {
            guard case .object(let n) = value, let source = Self.key(n["source_key"]), sources.insert(source).inserted else { throw ChildTaskRepairCommand.invalid }
            if n["history_key"] == .null {
                guard Set(n.keys) == ["source_key", "history_key", "incarnation", "lifecycle", "new_reference"], n["incarnation"] == .null, n["lifecycle"] == .string("selected"),
                      case .string(let reference)? = n["new_reference"], !reference.isEmpty, reference.utf8.count <= 128,
                      reference.precomposedStringWithCanonicalMapping.utf8.count <= 128,
                      targets.insert(reference.precomposedStringWithCanonicalMapping).inserted else { throw ChildTaskRepairCommand.invalid }
            } else {
                guard Set(n.keys) == ["source_key", "history_key", "incarnation", "lifecycle"], let key = Self.key(n["history_key"]), targets.insert(key).inserted,
                      (try? TeamOrganizationValue.id(n["incarnation"])) != nil,
                      [JSON.string("selected"), .string("recorded")].contains(n["lifecycle"] ?? .null) || incomplete && n["lifecycle"] == .null else { throw ChildTaskRepairCommand.invalid }
            }
        }
        for value in retired {
            guard case .object(let n) = value, Set(n.keys) == ["node_key", "incarnation"], let key = Self.key(n["node_key"]),
                  (try? TeamOrganizationValue.id(n["incarnation"])) != nil, !targets.contains(key), removed.insert(key).inserted else { throw ChildTaskRepairCommand.invalid }
        }
        self.raw = raw
    }
    init(from decoder: Decoder) throws { try self.init(raw: [String: JSON](from: decoder)) }
    func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }
}

struct ChildCopyMappingDraft: Codable, Equatable, Sendable {
    let source: String, digest: String, mapping: ChildCopyMapping
    init(source: String, digest: String, mapping: [String: JSON]) throws {
        guard ["task", "projection", "records"].contains(source), ChildTaskAdoptionCommand.digest(.string(digest)) else { throw ChildTaskRepairCommand.invalid }
        self.source = source; self.digest = digest; self.mapping = try .init(raw: mapping, incomplete: true)
    }
    enum CodingKeys: String, CodingKey { case source, digest, mapping }
    init(from decoder: Decoder) throws {
        try structureKeys(decoder, ["source", "digest", "mapping"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(source: c.decode(String.self, forKey: .source), digest: c.decode(String.self, forKey: .digest), mapping: c.decode([String: JSON].self, forKey: .mapping))
    }
}

struct ChildCopyMappingCatalog: Sendable {
    struct Item: Sendable, Identifiable {
        let id: String, title: String
        var location = ""
        let completed: Bool?, completedAt: String?, heading: Bool?
        let assignee: String?, recurrence: String?
        enum Keys: String, CodingKey { case id, title, completed, completed_at, is_heading, assigned_to, recurrence_parent_id }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            id = try c.decode(String.self, forKey: .id).precomposedStringWithCanonicalMapping
            title = String((try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled item").prefix(200))
            completed = try c.decodeIfPresent(Bool.self, forKey: .completed); completedAt = try c.decodeIfPresent(String.self, forKey: .completed_at)
            heading = try c.decodeIfPresent(Bool.self, forKey: .is_heading); assignee = try c.decodeIfPresent(String.self, forKey: .assigned_to); recurrence = try c.decodeIfPresent(String.self, forKey: .recurrence_parent_id)
        }
        var status: String { heading == true ? "Heading" : completed == true ? "Completed" : "Open" }
    }
    struct Stored: Decodable, Sendable, Identifiable {
        let node_key: String, incarnation: String, identity_path: [String], sibling_order: Int
        var fields: Item
        var id: String { node_key }
    }
    private struct Node: Decodable { let fields: Item, children: [Node]
        enum CodingKeys: String, CodingKey { case subtasks }
        init(from decoder: Decoder) throws { fields = try Item(from: decoder); children = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([Node].self, forKey: .subtasks) ?? [] }
    }
    private struct Bundle: Decodable { let records: [Stored] }
    let source: String, digest: String, selected: [Item], stored: [Stored]
    init(copies: ChildTaskCopyReview, source: String) throws {
        guard copies.omitted.isEmpty, let copy = copies.copies.first(where: { $0.id == source && $0.state == "ready" }) else { throw ChildTaskRepairCommand.invalid }
        var items: [Item] = []
        func walk(_ nodes: [Node], depth: Int, parent: String = "", position: String = "") throws {
            guard depth <= 24 else { throw ChildTaskRepairCommand.invalid }
            for (offset, n) in nodes.enumerated() {
                guard items.count < 1000, ChildCopyMapping.key(.string(n.fields.id)) != nil else { throw ChildTaskRepairCommand.invalid }
                var item = n.fields; let place = position.isEmpty ? String(offset + 1) : position + "." + String(offset + 1)
                item.location = place + (parent.isEmpty ? "" : " · " + parent); items.append(item)
                try walk(n.children, depth: depth + 1, parent: n.fields.title, position: place)
            }
        }
        if copy.tree != Data("null".utf8) { try walk(TaskfoldJSONDecoder().decode([Node].self, from: copy.tree), depth: 1) }
        var stored = try TaskfoldJSONDecoder().decode(Bundle.self, from: copies.exportBundle).records
        guard stored.count <= 1000, Set(items.map(\.id)).count == items.count, Set(stored.map(\.id)).count == stored.count,
              stored.allSatisfy({ ChildCopyMapping.key(.string($0.id)) != nil && $0.fields.id == $0.id && UUID(uuidString: $0.incarnation) != nil }) else { throw ChildTaskRepairCommand.invalid }
        let names = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0.fields.title) })
        for index in stored.indices {
            let parents = stored[index].identity_path.dropLast().compactMap { names[$0.precomposedStringWithCanonicalMapping] }
            stored[index].fields.location = "Item \(stored[index].sibling_order + 1)" + (parents.isEmpty ? "" : " · " + String(parents.joined(separator: " / ").suffix(200)))
        }
        self.source = source; digest = copies.digest; selected = items; self.stored = stored
    }
    func validate(_ draft: ChildCopyMappingDraft, complete: Bool) throws {
        guard draft.source == source, draft.digest == digest else { throw ChildTaskRepairCommand.invalid }
        let mapping = try ChildCopyMapping(raw: draft.mapping.raw, incomplete: !complete)
        let selectedKeys = Set(selected.map(\.id)); var used = Set<String>()
        for n in mapping.nodes {
            guard selectedKeys.contains(n["source_key"]!.text) else { throw ChildTaskRepairCommand.invalid }
            if n["history_key"] != .null {
                guard stored.contains(where: { $0.id == n["history_key"]!.text && $0.incarnation == n["incarnation"]!.text }) else { throw ChildTaskRepairCommand.invalid }; used.insert(n["history_key"]!.text)
            } else { guard !stored.contains(where: { $0.id == n["new_reference"]!.text.precomposedStringWithCanonicalMapping }) else { throw ChildTaskRepairCommand.invalid } }
        }
        for n in mapping.retired { guard stored.contains(where: { $0.id == n["node_key"]!.text && $0.incarnation == n["incarnation"]!.text }) else { throw ChildTaskRepairCommand.invalid }; used.insert(n["node_key"]!.text) }
        if complete { guard mapping.nodes.count == selected.count, used == Set(stored.map(\.id)) else { throw ChildTaskRepairCommand.invalid } }
    }
}
extension ChildCopyMappingCatalog.Item: Decodable {}

struct ChildCopyMappingSummary: Sendable {
    let newCount: Int, resetCount: Int, retiredCount: Int
    init(value: JSON, mapping: ChildCopyMapping) throws {
        guard case .object(let r) = value, Set(r.keys) == ["protocol", "nodes", "retired", "new_identity_count", "reset_completion_count", "subjects"], r["protocol"] == .number(1),
              case .array(let rows)? = r["nodes"], rows.count == mapping.nodes.count,
              r["retired"] == .array(mapping.retired.map { $0["node_key"]! }) else { throw ChildTaskRepairCommand.invalid }
        var fresh = 0, reset = 0, resetKeys = Set<String>()
        for (value, choice) in zip(rows, mapping.nodes) {
            guard case .object(let row) = value, Set(row.keys) == ["source_key", "history_key", "target_key", "incarnation", "lifecycle", "new_identity", "reset_completion"],
                  ["source_key", "history_key", "incarnation", "lifecycle"].allSatisfy({ ChildTaskStructureCommand.exact(row[$0], choice[$0]) }),
                  case .bool(let resets)? = row["reset_completion"] else { throw ChildTaskRepairCommand.invalid }
            let isNew = choice["history_key"] == .null
            let target = isNew ? choice["new_reference"]!.text.precomposedStringWithCanonicalMapping : choice["history_key"]!.text
            guard row["new_identity"] == .bool(isNew), row["target_key"] == .string(target), !isNew || resets else { throw ChildTaskRepairCommand.invalid }
            if isNew { fresh += 1 }; if resets { reset += 1; resetKeys.insert(target) }
        }
        guard r["new_identity_count"] == .number(Double(fresh)), r["reset_completion_count"] == .number(Double(reset)),
              let subjects = r["subjects"], let context = TaskNodeActivity.Reconciliation(.object(["version": .number(1), "request_id": .string("11111111-1111-1111-1111-111111111111"), "archive_id": .string("22222222-2222-2222-2222-222222222222"), "subjects": subjects])),
              Set(context.subjects.filter { !$0.retired }.map(\.key)) == resetKeys,
              Set(mapping.retired.map { $0["node_key"]!.text }).isSubset(of: Set(context.subjects.filter(\.retired).map(\.key))) else { throw ChildTaskRepairCommand.invalid }
        newCount = fresh; resetCount = reset; retiredCount = mapping.retired.count
    }
}

/// Only explicit metadata operations enter durable storage; opaque source trees
/// stay ephemeral and are never encoded as the app's floating-point JSON model.
struct ChildTaskRepairChange: Codable, Equatable, Sendable {
    enum Kind: String, Sendable { case chooseCopy = "choose_copy", separateDuplicate = "separate_duplicate", makeRootList = "make_root_list", assignReference = "assign_reference", makeChildrenList = "make_children_list", wrapItem = "wrap_item", moveItem = "move_item" }
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
        switch kind { case .chooseCopy: extra = raw["mapping"] == nil ? ["source", "copy_digest"] : ["source", "copy_digest", "mapping"]; case .makeRootList, .makeChildrenList: extra = []; case .assignReference: extra = ["reference"]; case .separateDuplicate: extra = ["reference", "keep_path"]; case .wrapItem: extra = ["reference", "title"]; case .moveItem: extra = ["parent", "index"] }
        guard Set(raw.keys) == extra.union(["kind", "path"]) else { throw ChildTaskRepairCommand.invalid }
        let path = try Self.positions(raw["path"], empty: kind == .makeRootList || kind == .chooseCopy)
        guard (kind != .makeRootList && kind != .chooseCopy) || path.isEmpty else { throw ChildTaskRepairCommand.invalid }
        if let mapping = raw["mapping"] { guard case .object(let value) = mapping else { throw ChildTaskRepairCommand.invalid }; _ = try ChildCopyMapping(raw: value) }
        if kind == .chooseCopy {
            guard case .string(let source)? = raw["source"], ["task", "projection", "records"].contains(source),
                  ChildTaskAdoptionCommand.digest(raw["copy_digest"]) else { throw ChildTaskRepairCommand.invalid }
        }
        if kind == .assignReference || kind == .wrapItem || kind == .separateDuplicate {
            guard case .string(let reference)? = raw["reference"], !reference.isEmpty, reference.utf8.count <= 128, reference.precomposedStringWithCanonicalMapping.utf8.count <= 128 else { throw ChildTaskRepairCommand.invalid }
        }
        if kind == .separateDuplicate {
            let kept = try Self.positions(raw["keep_path"], empty: false)
            guard kept != path else { throw ChildTaskRepairCommand.invalid }
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
    init(_ kind: Kind, path: [Int], reference: String? = nil, title: String? = nil, parent: [Int]? = nil, index: Int? = nil, keepPath: [Int]? = nil) throws {
        var raw: [String: JSON] = ["kind": .string(kind.rawValue), "path": .array(path.map { .number(Double($0)) })]
        if let keepPath { raw["keep_path"] = .array(keepPath.map { .number(Double($0)) }) }
        if let reference { raw["reference"] = .string(reference) }; if let title { raw["title"] = .string(title) }
        if let parent { raw["parent"] = .array(parent.map { .number(Double($0)) }) }; if let index { raw["index"] = .number(Double(index)) }
        try self.init(raw: raw)
    }
    static func choosing(_ source: String, digest: String, mapping: ChildCopyMapping? = nil) throws -> Self {
        var raw: [String: JSON] = ["kind": .string(Kind.chooseCopy.rawValue), "path": .array([]), "source": .string(source), "copy_digest": .string(digest)]
        if let mapping { raw["mapping"] = .object(mapping.raw) }; return try .init(raw: raw)
    }
    init(from decoder: Decoder) throws { try self.init(raw: [String: JSON](from: decoder)) }
    func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }
    static func == (a: Self, b: Self) -> Bool { ChildTaskStructureCommand.exact(.object(a.raw), .object(b.raw)) }
    static func validate(_ changes: [Self]) throws {
        guard (1...64).contains(changes.count), !changes.contains(where: { $0.kind == .chooseCopy }) || changes.count == 1, try TaskfoldJSONEncoder().encode(changes).count <= (changes.count == 1 && changes[0].raw["mapping"] != nil ? 550_000 : 65_536) else { throw ChildTaskRepairCommand.invalid }
    }
    static let counterPaths: Set<[String]> = [["changes", "[]", "mapping", "version"], ["changes", "[]", "keep_path", "[]"], ["changes", "[]", "path", "[]"], ["changes", "[]", "parent", "[]"], ["changes", "[]", "index"]]
}

struct ChildTaskRepairPreview: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let maximumBytes = 10_000_000
    let context: ChildTaskRecordContext
    let workspaceID: String?
    let changes: [ChildTaskRepairChange]
    let metadata: [String: JSON]
    let original: Data
    let proposed: Data
    let items: [ChildTaskAdoptionReview.Item]
    struct HistoryRetention: Sendable, Identifiable {
        let ordinal: Int, path: [Int], eventCount: Int, completedCount: Int
        var id: Int { ordinal }
    }
    let historyRetention: [HistoryRetention]
    let mappingSummary: ChildCopyMappingSummary?
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
            integerPaths: Set<[String]>([["mapping_plan", "protocol"], ["mapping_plan", "new_identity_count"], ["mapping_plan", "reset_completion_count"], ["history_retention", "[]", "ordinal"], ["history_retention", "[]", "event_count"], ["history_retention", "[]", "completed_count"], ["history_retention", "[]", "keep_path", "[]"], ["protocol"], ["node_count"], ["steps", "[]", "ordinal"], ["steps", "[]", "path", "[]"]]).union(ChildTaskRepairChange.counterPaths), nullableIntegerPaths: [["node_count"]])
        let raw = try TaskfoldJSONDecoder().decode([String: JSON].self, from: parts.metadata)
        guard Set(raw.keys).subtracting(["history_retention", "mapping_plan"]) == Self.keys, expected.allSatisfy({ ChildTaskStructureCommand.exact(raw[$0.key], $0.value) }),
              ChildTaskAdoptionCommand.digest(raw["repair_digest"]), case .bool(let valid)? = raw["proposal_valid"], case .bool(let mayWrite)? = raw["mutation_available"],
              case .bool(let sqlNull)? = raw["original_sql_null"], case .array(let steps)? = raw["steps"], steps.count == changes.count,
              let original = parts.values["original_tree"], let proposed = parts.values["proposed_tree"], original.count <= 2_000_000, proposed.count <= 2_000_000,
              !sqlNull || original == Data("null".utf8), raw["custody_blocker"] == .null || ["indexed_custody", "history_custody"].contains(raw["custody_blocker"]?.text ?? ""),
              !mayWrite || valid && raw["custody_blocker"] == .null else { throw ChildTaskRepairCommand.invalid }
        if let mapping = changes.first?.raw["mapping"] {
            guard changes.count == 1, let value = raw["mapping_plan"] else { throw ChildTaskRepairCommand.invalid }
            mappingSummary = try .init(value: value, mapping: ChildCopyMapping(raw: mapping.object))
        } else {
            guard raw["mapping_plan"] == nil, data.count <= 4_300_000 else { throw ChildTaskRepairCommand.invalid }; mappingSummary = nil
        }
        var retained: [HistoryRetention] = []
        let separating = changes.enumerated().filter { $0.element.kind == .separateDuplicate }
        if let retention = raw["history_retention"] {
            guard case .array(let rows) = retention, rows.count == separating.count, !separating.isEmpty else { throw ChildTaskRepairCommand.invalid }
            for (value, choice) in zip(rows, separating) {
                guard case .object(let r) = value, Set(r.keys) == ["ordinal", "node_key", "keep_path", "event_count", "completed_count", "digest"],
                      r["ordinal"] == .number(Double(choice.offset + 1)), ChildTaskStructureCommand.exact(r["keep_path"], choice.element.raw["keep_path"]),
                      case .string(let key)? = r["node_key"], !key.isEmpty, key.utf8.count <= 128, key.utf8.elementsEqual(key.precomposedStringWithCanonicalMapping.utf8),
                      ChildTaskAdoptionCommand.digest(r["digest"]) else { throw ChildTaskRepairCommand.invalid }
                let count = try ChildTaskAdoptionReview.count(r["event_count"], maximum: 1_000_000)
                let completed = try ChildTaskAdoptionReview.count(r["completed_count"], maximum: Double(count))
                retained.append(.init(ordinal: choice.offset + 1, path: try ChildTaskRepairChange.positions(r["keep_path"], empty: false), eventCount: count, completedCount: completed))
            }
        } else if mayWrite && !separating.isEmpty { throw ChildTaskRepairCommand.invalid }
        historyRetention = retained
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
            let nodes = proposed == Data("null".utf8) ? [] : try TaskfoldJSONDecoder().decode([Node].self, from: proposed)
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
    static let maximumStoredBytes = 700_000
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
              case .array(let values)? = body["changes"], try TaskfoldJSONEncoder().encode(body).count <= (values.count == 1 && values[0].object["mapping"] != nil ? 600_000 : 70_000) else { throw Self.invalid }
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
        self = try TaskfoldJSONDecoder().decode(Self.self, from: data)
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
        try self.init(command: command, raw: TaskfoldJSONDecoder().decode([String: JSON].self, from: data))
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
    private struct ObjectMarker: Decodable { enum Key: String, CodingKey { case unused }; init(from d: Decoder) throws { _ = try d.container(keyedBy: Key.self) } }
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
        let copyChoice: ChildTaskRepairChange?
        let mappingContext: TaskNodeActivity.Reconciliation?
        enum CodingKeys: String, CodingKey { case protocolVersion = "protocol", root, subtasksSQLNull = "subtasks_sql_null", projection, records, authority, rootHistory = "root_history", copyChoice = "copy_choice", mappingContext = "mapping_context", childHistory = "child_history", reviewDigest = "review_digest", repairDigest = "repair_digest" }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            let hasChoice = c.contains(.copyChoice)
            let mapped = try hasChoice && c.decode(ChildTaskRepairChange.self, forKey: .copyChoice).raw["mapping"] != nil
            if mapped { guard let context = TaskNodeActivity.Reconciliation(try c.decode(JSON.self, forKey: .mappingContext)) else { throw ChildTaskRepairCommand.invalid }; mappingContext = context }
            else { mappingContext = nil }
            try structureKeys(d, Set(["protocol", "root", "subtasks_sql_null", "projection", "records", "authority", "child_history", "review_digest", "repair_digest"]).union(hasChoice ? ["root_history", "copy_choice"] : []).union(mapped ? ["mapping_context"] : []))
            protocolVersion = try c.decode(Int.self, forKey: .protocolVersion); root = try c.decode(RootIdentity.self, forKey: .root)
            subtasksSQLNull = try c.decode(Bool.self, forKey: .subtasksSQLNull); reviewDigest = try c.decode(String.self, forKey: .reviewDigest); repairDigest = try c.decode(String.self, forKey: .repairDigest)
            if hasChoice {
                let choice = try c.decode(ChildTaskRepairChange.self, forKey: .copyChoice)
                guard choice.kind == .chooseCopy else { throw ChildTaskRepairCommand.invalid }; copyChoice = choice
                _ = try c.decode(ObjectMarker.self, forKey: .projection); _ = try c.decode(ObjectMarker.self, forKey: .authority)
                _ = try c.decode(ArrayMarker.self, forKey: .records); _ = try c.decode(ArrayMarker.self, forKey: .rootHistory)
            } else {
                copyChoice = nil
                guard try c.decodeNil(forKey: .projection), try c.decodeNil(forKey: .authority) else { throw ChildTaskRepairCommand.invalid }
                let records = try c.nestedUnkeyedContainer(forKey: .records); guard records.isAtEnd else { throw ChildTaskRepairCommand.invalid }
            }
            _ = try c.decode(ArrayMarker.self, forKey: .childHistory)
        }
    }
    init(data: Data, command: ChildTaskRepairCommand, result: ChildTaskRepairResult) throws {
        _ = try command.result(result.raw); guard result.applied else { throw ChildTaskRepairCommand.invalid }
        let parts = try ChildTaskRecordRead.separatingJSONField("original", data: data, maximum: Self.maximumBytes, integerPaths: [["protocol"], ["original", "protocol"]], nullableIntegerPaths: [])
        let raw = try TaskfoldJSONDecoder().decode([String: JSON].self, from: parts.metadata)
        guard Set(raw.keys) == ["protocol", "account", "request_id", "archive_id", "archive_digest", "original"], raw["protocol"] == .number(1),
              raw["account"] == .string(command.account), raw["request_id"] == .string(command.id), raw["archive_id"] == result.raw["archive_id"],
              raw["archive_digest"] == result.raw["archive_digest"], parts.value.count == (try ChildTaskAdoptionReview.count(result.raw["archive_bytes"], maximum: 8_000_000)),
              SHA256.hash(data: parts.value).map({ String(format: "%02x", $0) }).joined() == result.raw["archive_digest"]?.text else { throw ChildTaskRepairCommand.invalid }
        let header = try TaskfoldJSONDecoder().decode(Header.self, from: parts.value)
        guard header.protocolVersion == 1, header.root.id == command.rootID, header.root.task_generation == (try TeamProjectValue.optionalID(command.body["task_generation"])),
              header.root.project_id == (try TeamProjectValue.optionalID(command.body["project_id"])), header.reviewDigest == command.body["review_digest"]!.text, header.repairDigest == command.body["repair_digest"]!.text else { throw ChildTaskRepairCommand.invalid }
        if let context = header.mappingContext { guard context.request == command.id, context.archive == result.raw["archive_id"]?.text else { throw ChildTaskRepairCommand.invalid } }
        let choice = command.body["changes"]!.list.first?.object
        if choice?["kind"] == .string(ChildTaskRepairChange.Kind.chooseCopy.rawValue) {
            guard let archived = header.copyChoice, ChildTaskStructureCommand.exact(.object(archived.raw), .object(choice!)) else { throw ChildTaskRepairCommand.invalid }
        } else { guard header.copyChoice == nil else { throw ChildTaskRepairCommand.invalid } }
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


/// A local review is not a queued mutation. Only small explicit choices are saved;
/// opaque original content stays on its existing read/export path.
struct ChildTaskRepairDraft: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let account: String, origin: String
    let identity: [String: JSON]
    let changes: [ChildTaskRepairChange], labels: [String]
    let mappingReview: ChildCopyMappingDraft?
    let token: UUID
    var rootID: String { identity["task_id"]!.text }
    var description: String { "Private saved repair review" }
    var debugDescription: String { description }
    static let identityKeys: Set<String> = ["task_id", "task_generation", "project_id", "workspace_id", "review_digest"]
    init(account: String, origin: String, identity: [String: JSON], changes: [ChildTaskRepairChange], labels: [String], token: UUID = UUID(), mappingReview: ChildCopyMappingDraft? = nil) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard Set(identity.keys) == Self.identityKeys, ChildTaskAdoptionCommand.digest(identity["review_digest"]),
              labels.count == changes.count, labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2048 }) else { throw ChildTaskRepairCommand.invalid }
        _ = try TeamOrganizationValue.id(identity["task_id"])
        for key in ["task_generation", "project_id", "workspace_id"] { _ = try TeamProjectValue.optionalID(identity[key]) }
        if mappingReview != nil { guard changes.isEmpty && labels.isEmpty else { throw ChildTaskRepairCommand.invalid } } else { try ChildTaskRepairChange.validate(changes) }
        self.mappingReview = mappingReview
        self.account = account; self.origin = origin; self.identity = identity; self.changes = changes; self.labels = labels; self.token = token
    }
    init(review: ChildTaskAdoptionReview, changes: [ChildTaskRepairChange], labels: [String], mappingReview: ChildCopyMappingDraft? = nil) throws {
        try self.init(account: review.context.account, origin: review.context.origin, identity: review.metadata.filter { Self.identityKeys.contains($0.key) }, changes: changes, labels: labels, mappingReview: mappingReview)
    }
    func matches(_ review: ChildTaskAdoptionReview) -> Bool {
        account == review.context.account && origin == review.context.origin && Self.identityKeys.allSatisfy { ChildTaskStructureCommand.exact(identity[$0], review.metadata[$0]) }
    }
    private enum CodingKeys: String, CodingKey { case account, origin, identity, changes, labels, token, mappingReview }
    init(from decoder: Decoder) throws {
        let keys: Set<String> = ["account", "origin", "identity", "changes", "labels", "token"]
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try structureKeys(decoder, keys.union(fields.contains(.mappingReview) ? ["mappingReview"] : []))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), identity: c.decode([String: JSON].self, forKey: .identity), changes: c.decode([ChildTaskRepairChange].self, forKey: .changes), labels: c.decode([String].self, forKey: .labels), token: c.decode(UUID.self, forKey: .token), mappingReview: c.decodeIfPresent(ChildCopyMappingDraft.self, forKey: .mappingReview))
    }
    static func == (a: Self, b: Self) -> Bool {
        a.account == b.account && a.origin == b.origin && a.token == b.token && a.mappingReview == b.mappingReview && a.changes == b.changes && a.labels == b.labels && ChildTaskStructureCommand.exact(.object(a.identity), .object(b.identity))
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
    var drafts: [ChildTaskRepairDraft]
    init(account: String, origin: String, entries: [Entry] = [], drafts: [ChildTaskRepairDraft] = []) throws {
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
        guard drafts.count <= 32, Set(drafts.map(\.rootID)).count == drafts.count,
              drafts.allSatisfy({ $0.account == account && $0.origin == origin && !pendingRoots.contains($0.rootID) }) else { throw Self.invalid }
        self.account = account; self.origin = origin; self.entries = entries; self.drafts = drafts
    }
    init(data: Data) throws {
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: Self.maximumStoredBytes, integerPaths: Set<[String]>([["drafts", "[]", "mappingReview", "mapping", "version"], ["version"], ["entries", "[]", "command", "nodeCount"], ["entries", "[]", "command", "body", "protocol"], ["entries", "[]", "result", "raw", "protocol"], ["entries", "[]", "result", "raw", "node_count"], ["entries", "[]", "result", "raw", "archive_bytes"]]).union(Set(ChildTaskRepairChange.counterPaths.map { ["entries", "[]", "command", "body"] + $0 } + ChildTaskRepairChange.counterPaths.map { ["drafts", "[]"] + $0 })), nullableIntegerPaths: [["entries", "[]", "result", "raw", "node_count"], ["entries", "[]", "result", "raw", "archive_bytes"]])
        self = try TaskfoldJSONDecoder().decode(Self.self, from: data)
    }
    private enum CodingKeys: String, CodingKey { case version, account, origin, entries, drafts }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try structureKeys(decoder, c.contains(.drafts) ? ["version", "account", "origin", "entries", "drafts"] : ["version", "account", "origin", "entries"])
        guard try c.decode(Int.self, forKey: .version) == 1 else { throw Self.invalid }
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), entries: c.decode([Entry].self, forKey: .entries), drafts: c.contains(.drafts) ? c.decode([ChildTaskRepairDraft].self, forKey: .drafts) : [])
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(1, forKey: .version); try c.encode(account, forKey: .account); try c.encode(origin, forKey: .origin); try c.encode(entries, forKey: .entries); if !drafts.isEmpty { try c.encode(drafts, forKey: .drafts) }
    }
}

actor ChildTaskRepairJournal {
    private let admit: @Sendable (Set<String>) throws -> Void
    let account: String, origin: String
    private let io: any CalendarSecureItemIO, lock: AutomationEnrollmentProcessLock, removalDirectory: URL
    private var key: String { ChildTaskRepairState.storagePrefix + account + "." + CalendarOAuthConfiguration.digest(origin) }
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
    private func read() throws -> ChildTaskRepairState {
        guard let data = try io.read(key: key) else { return try .init(account: account, origin: origin) }
        let state = try ChildTaskRepairState(data: data)
        guard state.account == account, state.origin == origin else { throw ChildTaskRepairCommand.invalid }; return state
    }
    private func write(_ value: ChildTaskRepairState, lease: CalendarReadLease) throws {
        let state = try ChildTaskRepairState(account: account, origin: origin, entries: value.entries, drafts: value.drafts), data = try TaskfoldJSONEncoder().encode(state)
        guard data.count <= ChildTaskRepairState.maximumStoredBytes else { throw ChildTaskRepairFailure(reason: .limit) }
        try lease.check(); try io.write(data, key: key)
    }
    func load() throws -> ChildTaskRepairState { try guarded(nil) { try read() } }
    func enqueue(_ command: ChildTaskRepairCommand, lease: CalendarReadLease, draftToken: UUID? = nil) throws {
        try guarded(lease) {
            try admit([command.body["task_id"]!.text])
            guard command.account == account, command.origin == origin else { throw ChildTaskRepairCommand.invalid }
            var state = try read()
            if let old = state.entries.first(where: { $0.command.id == command.id }) { guard old.command == command, old.phase != .closed else { throw ChildTaskRepairCommand.invalid }; return }
            guard !state.entries.contains(where: { ($0.phase == .queued || $0.phase == .attempted) && $0.command.rootID == command.rootID }) else { throw ChildTaskRepairFailure(reason: .busy) }
            if let draft = state.drafts.first(where: { $0.rootID == command.rootID }) {
                guard draft.token == draftToken, ChildTaskStructureCommand.exact(.array(draft.changes.map { .object($0.raw) }), command.body["changes"]),
                      ChildTaskRepairDraft.identityKeys.allSatisfy({ ChildTaskStructureCommand.exact(draft.identity[$0], command.body[$0]) }) else { throw ChildTaskRepairCommand.invalid }
                state.drafts.removeAll { $0.rootID == command.rootID }
            } else { guard draftToken == nil else { throw ChildTaskRepairCommand.invalid } }
            state.entries.append(.init(command: command)); try write(state, lease: lease)
        }
    }
    func attempt(_ command: ChildTaskRepairCommand, lease: CalendarReadLease, resolving: Bool = false) throws -> ChildTaskRepairState.Entry {
        try guarded(lease) {
            if !resolving { try admit([command.body["task_id"]!.text]) }
            var state = try read(); guard let i = state.entries.firstIndex(where: { $0.command == command }) else { throw ChildTaskRepairCommand.invalid }
            if state.entries[i].phase == .queued { state.entries[i].phase = .attempted; try write(state, lease: lease) }
            return state.entries[i]
        }
    }
    func settle(_ command: ChildTaskRepairCommand, result: ChildTaskRepairResult, lease: CalendarReadLease) throws {
        try guarded(lease) {
            _ = try command.result(result.raw); guard !result.unknown else { throw ChildTaskRepairCommand.invalid }
            var state = try read(); guard let i = state.entries.firstIndex(where: { $0.command == command }), state.entries[i].phase != .queued else { throw ChildTaskRepairCommand.invalid }
            if let old = state.entries[i].result { guard old.agrees(result) else { throw ChildTaskRepairCommand.invalid }; return }
            state.entries[i].phase = result.applied ? .applied : .closed; state.entries[i].result = result; try write(state, lease: lease)
        }
    }
    func discard(_ command: ChildTaskRepairCommand, lease: CalendarReadLease) throws {
        try guarded(lease) {
            var state = try read(); guard let i = state.entries.firstIndex(where: { $0.command == command }), state.entries[i].phase != .attempted else { throw ChildTaskRepairCommand.invalid }
            state.entries.remove(at: i)
            try write(state, lease: lease)
        }
    }
    /// Compare-and-swap prevents another window from replacing newer choices.
    func saveDraft(_ draft: ChildTaskRepairDraft?, rootID: String, expected: UUID?, lease: CalendarReadLease) throws {
        try guarded(lease) {
            var state = try read()
            guard state.drafts.first(where: { $0.rootID == rootID })?.token == expected,
                  !state.entries.contains(where: { $0.command.rootID == rootID && ($0.phase == .queued || $0.phase == .attempted) }) else { throw ChildTaskRepairCommand.invalid }
            if let draft { guard draft.rootID == rootID, draft.account == account, draft.origin == origin else { throw ChildTaskRepairCommand.invalid } }
            state.drafts.removeAll { $0.rootID == rootID }; if let draft { state.drafts.append(draft) }
            try write(state, lease: lease)
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
    private(set) var drafts: [ChildTaskRepairDraft] = []
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
    func close() { closed = true; lease.cancel(); entries = []; drafts = []; message = nil; loaded = false; busy = false }
    private func check() throws { try lease.check(); guard !closed, current() == scope else { throw CancellationError() } }
    private func update() async throws { let state = try await journal.load(); try check(); entries = state.entries; drafts = state.drafts; loaded = true }
    private func work(_ action: () async throws -> Void) async -> Bool {
        guard !busy else { return false }; busy = true; defer { busy = false }
        do { try check(); try await action(); try check(); return true }
        catch {
            guard (try? check()) != nil else { close(); return false }
            do { try await update() } catch { entries = []; drafts = []; loaded = false }
            guard (try? check()) != nil else { close(); return false }
            if error is AccountSessionAuthorizationRequired { message = "Sign in again to check your saved repair." }
            else if let failure = error as? ChildTaskRepairFailure { message = failure.localizedDescription }
            else if let failure = error as? AppFailure { message = failure.localizedDescription }
            else { message = "Repair couldn’t be confirmed. Your saved request is kept; check its status before starting another." }
            return false
        }
    }
    func load() async { _ = await work { try await update() } }
    func queue(_ command: ChildTaskRepairCommand, review: ChildTaskRepairPreview, draftToken: UUID? = nil) async -> Bool {
        await work {
            guard ChildTaskFieldClientScope(review.context) == scope, reviewCurrent(review) else { throw CancellationError() }
            try command.review(review)
            try await admit(command); try check()
            guard reviewCurrent(review) else { throw CancellationError() }
            try await journal.enqueue(command, lease: lease, draftToken: draftToken); try check(); try await update(); message = "Repair saved on this device."
        }
    }
    func saveDraft(_ draft: ChildTaskRepairDraft?, rootID: String, expected: UUID?) async -> Bool {
        let completed = await work {
            try await journal.saveDraft(draft, rootID: rootID, expected: expected, lease: lease); try check(); try await update()
        }
        // A secure write may finish before reporting an error. Accept only the
        // complete validated draft read back from disk, never the attempted value.
        guard (completed || loaded), (try? check()) != nil, drafts.first(where: { $0.rootID == rootID }) == draft else {
            if (try? check()) != nil { message = "This review couldn’t be saved. Your previous saved choices are kept. Close and reopen to review them." }
            return false
        }
        message = draft == nil ? "Saved review removed. Your task is unchanged." : "Review saved on this device. Your task is unchanged."
        return true
    }
    func run(_ command: ChildTaskRepairCommand, operation: ChildTaskRepairOperation) async -> Bool {
        let completed = await work {
            guard command.account == scope.account, command.origin == scope.origin else { throw CancellationError() }
            if operation == .send { guard canSend(command) else { throw ChildTaskRepairFailure(reason: .unavailable) }; try await admit(command); try check() }
            let entry = try await journal.attempt(command, lease: lease, resolving: operation != .send); try check()
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
        let path: [Int], title: String, kind: Kind, reference: String?, referenceNeedsRepair: Bool, malformedChildren: Bool, siblings: Int
        var id: String { path.map(String.init).joined(separator: ".") }
        var depth: Int { path.count }
    }
    func historyKeepers(for item: Item) -> [Item] {
        guard item.referenceNeedsRepair, let key = item.reference else { return [] }
        return items.filter { $0.path != item.path && $0.reference == key }
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
        let decoder = TaskfoldJSONDecoder(); decoder.userInfo[Self.budgetKey] = Budget(); let root = try decoder.decode(Root.self, from: data)
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
                items.append(.init(path: path + [position], title: node.title, kind: node.kind, reference: key, referenceNeedsRepair: node.kind == .object && (key == nil || (key.flatMap { references[$0] } ?? 0) > 1), malformedChildren: node.malformedChildren, siblings: nodes.count))
                try walk(node.children, path: path + [position])
            }
        }
        try walk(root.nodes, path: []); rootKind = root.kind; self.items = items; rootCount = root.nodes.count
    }
}

/// Ephemeral comparison only. Raw copies and export bytes never enter Snapshot
/// or a floating-point dictionary, and descriptions never disclose their content.
struct ChildTaskCopyReview: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let maximumBytes = 14_300_000
    static let fields: Set<String> = ["protocol", "account", "task_id", "task_generation", "project_id", "workspace_id", "review_digest"]
    static var invalid: AppFailure { AppFailure(message: "These saved copies need a fresh review. All content is unchanged.") }
    let context: ChildTaskRecordContext
    let metadata: [String: JSON]
    let copies: [Copy]
    let exportBundle: Data
    let omitted: Set<String>
    var digest: String { metadata["copy_digest"]!.text }
    var description: String { "Private saved-copy comparison" }
    var debugDescription: String { description }
    struct Item: Sendable, Identifiable {
        let id: String, title: String, depth: Int
        let notes: String?, completed: Bool?, due: String?, priority: Int?
    }
    struct Copy: Sendable, Identifiable {
        let id: String, state: String, issue: String?
        let count: Int?, depth: Int?, bytes: Int?
        let tree: Data
        let items: [Item]
        var visible: Bool { state == "ready" || state == "review" }
        var title: String { switch id { case "task": "Task list"; case "projection": "Saved snapshot"; default: "Stored subtasks" } }
    }
    static func body(_ review: ChildTaskAdoptionReview) -> [String: JSON] { review.metadata.filter { fields.contains($0.key) } }
    private struct RowIdentity: Decodable { let task_id: String }
    private struct Node: Decodable {
        let id: String, title: String?, children: [Node]
        let notes: String?, completed: Bool?, due: String?, priority: Int?
        enum CodingKeys: String, CodingKey { case id, title, subtasks, description, completed, due_date, priority }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id); title = try? c.decode(String.self, forKey: .title)
            notes = try? c.decode(String.self, forKey: .description)
            completed = try? c.decode(Bool.self, forKey: .completed)
            due = try? c.decode(String.self, forKey: .due_date)
            let p = try? c.decode(Int.self, forKey: .priority); priority = p.flatMap { (1...4).contains($0) ? $0 : nil }
            children = try c.decodeIfPresent([Node].self, forKey: .subtasks) ?? []
        }
    }
    init(data: Data, review: ChildTaskAdoptionReview) throws {
        let parts = try ChildTaskRecordRead.separatingJSONFields(["task_tree", "projection_tree", "record_tree", "export_bundle"], data: data, maximum: Self.maximumBytes,
            integerPaths: [["protocol"], ["copies", "[]", "node_count"], ["copies", "[]", "max_depth"], ["copies", "[]", "bytes"]],
            nullableIntegerPaths: [["copies", "[]", "node_count"], ["copies", "[]", "max_depth"], ["copies", "[]", "bytes"]])
        let raw = try TaskfoldJSONDecoder().decode([String: JSON].self, from: parts.metadata)
        guard Set(raw.keys) == Self.fields.union(["copy_digest", "state", "authoritative_source", "copies", "task_tree", "projection_tree", "record_tree", "export_bundle"]),
              Self.body(review).allSatisfy({ ChildTaskStructureCommand.exact(raw[$0.key], $0.value) }),
              ChildTaskAdoptionCommand.digest(raw["copy_digest"]), ["single", "aligned", "different", "limited"].contains(raw["state"]?.text ?? ""),
              ["task", "records", "unavailable"].contains(raw["authoritative_source"]?.text ?? ""),
              case .array(let rows)? = raw["copies"], rows.count == 3, let original = review.originalSource,
              let taskTree = parts.values["task_tree"], ChildTaskRepairPreview.sameJSONValue(taskTree, original),
              let bundle = parts.values["export_bundle"], bundle.count <= 8_000_000 else { throw Self.invalid }
        let names = ["task", "projection", "records"], treeNames = ["task_tree", "projection_tree", "record_tree"]
        var copies: [Copy] = []
        for (index,value) in rows.enumerated() {
            guard case .object(let row) = value, Set(row.keys) == ["id", "state", "issue", "node_count", "max_depth", "bytes"],
                  row["id"] == .string(names[index]), let state = row["state"]?.text, ["ready", "review", "unavailable", "absent"].contains(state),
                  let tree = parts.values[treeNames[index]], tree.count <= 2_000_000 else { throw Self.invalid }
            let visible = state == "ready" || state == "review"
            guard index != 0 || visible else { throw Self.invalid }
            var count: Int?, depth: Int?, byteCount: Int?, items: [Item] = []
            if visible {
                byteCount = try ChildTaskAdoptionReview.count(row["bytes"], maximum: 4_000_000)
                guard byteCount! > 0 else { throw Self.invalid }
                if state == "ready" {
                    guard row["issue"] == .null else { throw Self.invalid }
                    count = try ChildTaskAdoptionReview.count(row["node_count"], maximum: 1000)
                    depth = try ChildTaskAdoptionReview.count(row["max_depth"], maximum: 24)
                    let nodes = tree == Data("null".utf8) ? [] : try TaskfoldJSONDecoder().decode([Node].self, from: tree)
                    var seen = Set<String>(), deepest = 0
                    func walk(_ nodes: [Node], level: Int) throws {
                        guard nodes.isEmpty || level <= 24 else { throw Self.invalid }
                        for node in nodes {
                            try Task.checkCancellation(); let key = node.id.precomposedStringWithCanonicalMapping
                            guard !node.id.isEmpty, node.id.utf8.count <= 128, key.utf8.count <= 128, seen.insert(key).inserted, items.count < 1000 else { throw Self.invalid }
                            deepest = max(deepest, level)
                            let name = String(String.UnicodeScalarView((node.title ?? "").unicodeScalars.prefix(160)))
                            items.append(.init(id: node.id, title: name.isEmpty ? "Untitled task" : name, depth: level,
                                notes: node.notes.map { String(String.UnicodeScalarView($0.unicodeScalars.prefix(600))) }, completed: node.completed,
                                due: node.due.map { String(String.UnicodeScalarView($0.unicodeScalars.prefix(64))) }, priority: node.priority))
                            try walk(node.children, level: level + 1)
                        }
                    }
                    try walk(nodes, level: 1)
                    guard count == items.count, depth == deepest else { throw Self.invalid }
                } else {
                    guard row["node_count"] == .null, row["max_depth"] == .null,
                          ChildTaskRepairPreview.issues.union(["record_shape"]).contains(row["issue"]?.text ?? "") else { throw Self.invalid }
                    if row["issue"] == .string("record_shape") { guard names[index] == "records", tree == Data("null".utf8) else { throw Self.invalid } }
                }
            } else {
                guard row["node_count"] == .null, row["max_depth"] == .null, row["bytes"] == .null,
                      tree == Data("null".utf8), row["issue"] == (state == "absent" ? .null : .string("access_review")) else { throw Self.invalid }
            }
            copies.append(.init(id: names[index], state: state, issue: row["issue"] == .null ? nil : row["issue"]?.text, count: count, depth: depth, bytes: byteCount, tree: tree, items: items))
        }
        let exported = try ChildTaskRecordRead.separatingJSONFields(["root", "projection", "records", "authority"], data: bundle, maximum: 8_000_000, integerPaths: [["protocol"]], nullableIntegerPaths: [])
        let header = try TaskfoldJSONDecoder().decode([String: JSON].self, from: exported.metadata)
        guard Set(header.keys) == Self.fields.union(["kind", "copy_digest", "root", "subtasks_sql_null", "projection", "records", "authority", "omitted"]),
              header["kind"] == .string("taskfold_saved_child_copies"), Self.fields.allSatisfy({ ChildTaskStructureCommand.exact(header[$0], raw[$0]) }),
              header["copy_digest"] == raw["copy_digest"], case .bool(let sqlNull)? = header["subtasks_sql_null"],
              case .array(let missing)? = header["omitted"], missing.count <= 3,
              missing.allSatisfy({ if case .string(let s) = $0 { return ["projection", "records", "authority"].contains(s) }; return false }),
              Set(missing.map(\.text)).count == missing.count, let root = exported.values["root"] else { throw Self.invalid }
        let rootParts = try ChildTaskRecordRead.separatingJSONFields(["id", "task_generation", "project_id", "subtasks"], data: root, maximum: 8_000_000, integerPaths: [], nullableIntegerPaths: [])
        for (key,expected) in [("id", raw["task_id"]!), ("task_generation", raw["task_generation"]!), ("project_id", raw["project_id"]!)] {
            guard let bytes = rootParts.values[key], ChildTaskStructureCommand.exact(try TaskfoldJSONDecoder().decode(JSON.self, from: bytes), expected) else { throw Self.invalid }
        }
        guard let exportedTree = rootParts.values["subtasks"], ChildTaskRepairPreview.sameJSONValue(exportedTree, taskTree), !sqlNull || taskTree == Data("null".utf8) else { throw Self.invalid }
        for (key,index) in [("projection",1),("records",2)] {
            guard let content = exported.values[key] else { throw Self.invalid }
            if !copies[index].visible { guard content == Data((key == "records" ? "[]" : "null").utf8) else { throw Self.invalid } }
            else if key == "projection" {
                let p = try ChildTaskRecordRead.separatingJSONFields(["task_id", "task_generation", "source_tree"], data: content, maximum: 4_000_000, integerPaths: [], nullableIntegerPaths: [])
                for identity in ["task_id", "task_generation"] { guard let bytes = p.values[identity], ChildTaskStructureCommand.exact(try TaskfoldJSONDecoder().decode(JSON.self, from: bytes), raw[identity]) else { throw Self.invalid } }
                guard let source = p.values["source_tree"], ChildTaskRepairPreview.sameJSONValue(source, copies[index].tree) else { throw Self.invalid }
            } else {
                guard content.first == 91 else { throw Self.invalid }
                let identities = try TaskfoldJSONDecoder().decode([RowIdentity].self, from: content)
                guard identities.count <= 1000, identities.allSatisfy({ $0.task_id == raw["task_id"]?.text }), copies[index].count == nil || copies[index].count == identities.count else { throw Self.invalid }
            }
        }
        guard let authority = exported.values["authority"] else { throw Self.invalid }
        if raw["authoritative_source"] == .string("records") {
            let a = try TaskfoldJSONDecoder().decode([String: JSON].self, from: authority)
            guard Set(a.keys) == ["task_id", "task_generation", "project_id", "root_kind"], ["task_id", "task_generation", "project_id"].allSatisfy({ ChildTaskStructureCommand.exact(a[$0], raw[$0]) }), ["array", "null"].contains(a["root_kind"]?.text ?? "") else { throw Self.invalid }
        } else { guard authority == Data("null".utf8) else { throw Self.invalid } }
        let omitted = Set(missing.map(\.text))
        if raw["state"] == .string("limited") { guard !omitted.isEmpty else { throw Self.invalid } }
        else { guard omitted.isEmpty else { throw Self.invalid } }
        if raw["state"] == .string("single") { guard copies[1].state == "absent", copies[2].state == "absent" else { throw Self.invalid } }
        if raw["state"] == .string("aligned") {
            guard copies.allSatisfy({ $0.state == "ready" }),
                  ChildTaskStructureCommand.exact(try TaskfoldJSONDecoder().decode(JSON.self, from: copies[0].tree), try TaskfoldJSONDecoder().decode(JSON.self, from: copies[1].tree)),
                  ChildTaskStructureCommand.exact(try TaskfoldJSONDecoder().decode(JSON.self, from: copies[0].tree), try TaskfoldJSONDecoder().decode(JSON.self, from: copies[2].tree)) else { throw Self.invalid }
        }
        context = review.context; metadata = raw; self.copies = copies; exportBundle = bundle; self.omitted = omitted
    }
}
