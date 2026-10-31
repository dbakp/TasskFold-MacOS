import Foundation
import CryptoKit
import Observation

/// Two-root intent containing identities and revisions, never a copied subtree.
struct ChildTaskTransferCommand: ReviewedTeamCommand, CustomStringConvertible, CustomDebugStringConvertible {
    static let storagePrefix = "child-transfer-command-v1."
    static let maximumStoredBytes = 500_000
    static let maximumRequestBytes = 384_000
    static var invalid: AppFailure { AppFailure(message: "Review this subtask move against both current tasks. Your saved work is kept.") }
    let account: String, origin: String
    let body: [String: JSON]
    var id: String { body["request_id"]!.text }
    var undoing: Bool { body["action"] == .string("undo") }
    var family: String { body["undo_of"]?.text ?? id }
    var roots: Set<String> { Set([body["source"]!.object["task_id"]!.text, body["destination"]!.object["task_id"]!.text]) }
    var description: String { "Private subtask move" }
    var debugDescription: String { description }
    static func == (a: Self, b: Self) -> Bool {
        a.account == b.account && a.origin == b.origin && ChildTaskStructureCommand.exact(.object(a.body), .object(b.body))
    }
    static func slot(_ value: JSON?) throws -> Int {
        guard case .number(let n)? = value, n.isFinite, n >= 0, n <= 1000, n.rounded() == n else { throw invalid }; return Int(n)
    }
    static func endpoint(_ read: ChildTaskStructureRead) -> [String: JSON] {
        ["task_id": .string(read.context.root.id), "task_generation": read.context.root["task_generation"], "project_id": read.context.root["project_id"], "structure_revision": .number(read.structureRevision)]
    }
    static func versions(_ node: ChildTaskRecordRead.Node, _ read: ChildTaskStructureRead) -> [String: JSON] {
        Dictionary(uniqueKeysWithValues: read.records.orderedNodes.filter { $0.path.starts(with: node.path) }.map {
            ($0.key, .object(["incarnation": .string($0.incarnation), "revision": .number($0.revision)]))
        })
    }
    init(node key: String, parent: String?, index: Int, source: ChildTaskStructureRead, destination: ChildTaskStructureRead, requestID: UUID = UUID()) throws {
        guard let node = source.records.nodes[key] else { throw Self.invalid }
        var to = Self.endpoint(destination)
        to["parent_key"] = parent.map(JSON.string) ?? .null
        to["parent_incarnation"] = parent.flatMap { destination.records.nodes[$0] }.map { .string($0.incarnation) } ?? .null
        to["index"] = .number(Double(index))
        try self.init(account: source.context.account, origin: source.context.origin, body: ["protocol": .number(1), "account": .string(source.context.account), "request_id": .string(requestID.uuidString.lowercased()), "source": .object(Self.endpoint(source)), "destination": .object(to), "node_key": .string(key), "incarnation": .string(node.incarnation), "subtree_versions": .object(Self.versions(node, source)), "action": .string("transfer")])
        try review(source: source, destination: destination)
    }
    init(undo original: Self, receipt: ChildTaskTransferResult, source: ChildTaskStructureRead, destination: ChildTaskStructureRead, requestID: UUID = UUID()) throws {
        let proof = try original.result(receipt.raw)
        guard proof.applied, !original.undoing,
              source.context.root.id == original.body["destination"]!.object["task_id"]?.text,
              destination.context.root.id == original.body["source"]!.object["task_id"]?.text,
              source.structureRevision == Double(proof.raw["destination_revision"]!.integer + 1),
              destination.structureRevision == Double(proof.raw["source_revision"]!.integer + 1) else { throw Self.invalid }
        let parent = proof.raw["return_parent"] == .null ? nil : proof.raw["return_parent"]!.text
        let command = try Self(node: original.body["node_key"]!.text, parent: parent, index: proof.raw["return_index"]!.integer, source: source, destination: destination, requestID: requestID)
        var body = command.body; body["action"] = .string("undo"); body["undo_of"] = .string(original.id)
        try self.init(account: command.account, origin: command.origin, body: body)
        try validateUndo(original: original, receipt: proof)
    }
    init(account: String, origin: String, body: [String: JSON]) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        let undo = body["action"] == .string("undo")
        let keys: Set<String> = ["protocol", "account", "request_id", "source", "destination", "node_key", "incarnation", "subtree_versions", "action"]
        guard origin.utf8.count <= 2048, Set(body.keys) == (undo ? keys.union(["undo_of"]) : keys),
              body["protocol"] == .number(1), body["account"] == .string(account), undo || body["action"] == .string("transfer") else { throw Self.invalid }
        _ = try TeamOrganizationValue.id(body["request_id"]); _ = try TeamOrganizationValue.id(body["incarnation"])
        if undo { _ = try TeamOrganizationValue.id(body["undo_of"]); guard body["undo_of"] != body["request_id"] else { throw Self.invalid } }
        _ = try ChildTaskStructureCommand.key(body["node_key"])
        for name in ["source", "destination"] {
            guard case .object(let fields)? = body[name], Set(fields.keys) == (name == "source" ? Set(["task_id", "task_generation", "project_id", "structure_revision"]) : Set(["task_id", "task_generation", "project_id", "structure_revision", "parent_key", "parent_incarnation", "index"])) else { throw Self.invalid }
            _ = try TeamOrganizationValue.id(fields["task_id"])
            for key in ["task_generation", "project_id"] { _ = try TeamProjectValue.optionalID(fields[key]) }
            guard try TeamProjectValue.revision(fields["structure_revision"]) >= 1, try TeamProjectValue.revision(fields["structure_revision"]) < 9_007_199_254_740_991 else { throw Self.invalid }
        }
        let from = body["source"]!.object, to = body["destination"]!.object
        guard from["task_id"] != to["task_id"], try Self.slot(to["index"]) <= 1000 else { throw Self.invalid }
        if to["parent_key"] == .null { guard to["parent_incarnation"] == .null else { throw Self.invalid } }
        else { _ = try ChildTaskStructureCommand.key(to["parent_key"]); _ = try TeamOrganizationValue.id(to["parent_incarnation"]) }
        guard case .object(let versions)? = body["subtree_versions"], !versions.isEmpty, versions.count <= 1000,
              versions[body["node_key"]!.text]?.object["incarnation"] == body["incarnation"] else { throw Self.invalid }
        for (key, value) in versions {
            _ = try ChildTaskStructureCommand.key(.string(key))
            guard case .object(let row) = value, Set(row.keys) == ["incarnation", "revision"], try TeamProjectValue.revision(row["revision"]) >= 1, try TeamProjectValue.revision(row["revision"]) < 9_007_199_254_740_991 else { throw Self.invalid }
            _ = try TeamOrganizationValue.id(row["incarnation"])
        }
        guard try TaskfoldJSONEncoder().encode(body).count <= Self.maximumRequestBytes else { throw Self.invalid }
        self.account = account; self.origin = origin; self.body = body
    }
    func validateUndo(original: Self, receipt: ChildTaskTransferResult) throws {
        let proof = try original.result(receipt.raw)
        guard undoing, !original.undoing, proof.applied, body["undo_of"] == .string(original.id),
              body["node_key"] == original.body["node_key"], body["incarnation"] == original.body["incarnation"],
              body["destination"]!.object["parent_key"] == proof.raw["return_parent"], body["destination"]!.object["index"] == proof.raw["return_index"] else { throw Self.invalid }
        for (here, there) in [("source", "destination"), ("destination", "source")] {
            let actual = body[here]!.object, old = original.body[there]!.object
            for key in ["task_id", "task_generation", "project_id"] { guard ChildTaskStructureCommand.exact(actual[key], old[key]) else { throw Self.invalid } }
            guard actual["structure_revision"] == .number(Double(old["structure_revision"]!.integer + 1)) else { throw Self.invalid }
        }
        let current = body["subtree_versions"]!.object, prior = original.body["subtree_versions"]!.object
        guard Set(current.keys) == Set(prior.keys) else { throw Self.invalid }
        for (key, value) in current {
            guard value.object["incarnation"] == prior[key]?.object["incarnation"],
                  value.object["revision"] == .number(Double(prior[key]!.object["revision"]!.integer + 1)) else { throw Self.invalid }
        }
    }
    func review(source: ChildTaskStructureRead, destination: ChildTaskStructureRead) throws {
        let a = source.context, b = destination.context
        guard ChildTaskFieldClientScope(a) == ChildTaskFieldClientScope(b), a.snapshot == b.snapshot,
              a.account == account, a.origin == origin else { throw Self.invalid }
        for (name, read) in [("source", source), ("destination", destination)] {
            let captured = body[name]!.object
            guard Self.endpoint(read).allSatisfy({ ChildTaskStructureCommand.exact(captured[$0.key], $0.value) }) else { throw Self.invalid }
        }
        guard let node = source.records.nodes[body["node_key"]!.text], node.incarnation == body["incarnation"]!.text,
              ChildTaskStructureCommand.exact(body["subtree_versions"], .object(Self.versions(node, source))),
              Set(Self.versions(node, source).keys).isDisjoint(with: destination.records.nodes.keys) else { throw Self.invalid }
        let to = body["destination"]!.object, parent = to["parent_key"] == .null ? nil : to["parent_key"]!.text
        if let parent { guard destination.records.nodes[parent]?.incarnation == to["parent_incarnation"]?.text else { throw Self.invalid } }
        let siblings = destination.records.orderedNodes.filter { $0.parent == parent }
        guard to["index"]!.integer <= siblings.count else { throw Self.invalid }
        let moved = source.records.orderedNodes.filter { $0.path.starts(with: node.path) }
        let depth = (moved.map { $0.path.count - node.path.count + 1 }.max() ?? 1) + (parent.flatMap { destination.records.nodes[$0]?.path.count } ?? 0)
        guard depth <= 24, destination.records.orderedNodes.count + moved.count <= 1000 else { throw ChildTaskTransferFailure(reason: .limit) }
        // Validate the actual composed tree through the existing bounded tree
        // reader on the server; local previews never mutate either saved root.
    }
    static func counterPaths(_ body: [String: JSON], prefix: [String] = []) -> Set<[String]> {
        var paths: Set<[String]> = [prefix + ["protocol"], prefix + ["source", "structure_revision"], prefix + ["destination", "structure_revision"], prefix + ["destination", "index"]]
        for key in (body["subtree_versions"]?.object ?? [:]).keys { paths.insert(prefix + ["subtree_versions", key, "revision"]) }
        return paths
    }
    init(data: Data) throws {
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: Self.maximumStoredBytes)
        let raw = try TaskfoldJSONDecoder().decode([String: JSON].self, from: data)
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: Self.maximumStoredBytes, integerPaths: Self.counterPaths(raw["body"]?.object ?? [:], prefix: ["body"]))
        self = try TaskfoldJSONDecoder().decode(Self.self, from: data)
    }
    private enum CodingKeys: String, CodingKey { case account, origin, body }
    init(from decoder: Decoder) throws {
        try structureKeys(decoder, ["account", "origin", "body"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), body: c.decode([String: JSON].self, forKey: .body))
    }
    func result(_ raw: [String: JSON]) throws -> ChildTaskTransferResult { try .init(command: self, raw: raw) }
}

struct ChildTaskTransferResult: Codable, Equatable, Sendable {
    let raw: [String: JSON]
    var applied: Bool { raw["state"] == .string("applied") }
    var closed: Bool { raw["state"] == .string("closed") }
    var unknown: Bool { raw["state"] == .string("unknown") }
    static let counters: Set<[String]> = [["protocol"], ["source_revision"], ["destination_revision"], ["moved_count"], ["return_index"]]
    init(command: ChildTaskTransferCommand, data: Data) throws {
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: 16_384, integerPaths: Self.counters, nullableIntegerPaths: [["return_index"]])
        try self.init(command: command, raw: TaskfoldJSONDecoder().decode([String: JSON].self, from: data))
    }
    init(command: ChildTaskTransferCommand, raw: [String: JSON]) throws {
        guard raw["protocol"] == .number(1), raw["account"] == .string(command.account), raw["request_id"] == .string(command.id) else { throw ChildTaskTransferCommand.invalid }
        if raw["state"] == .string("unknown") {
            guard Set(raw.keys) == ["protocol", "account", "request_id", "state"] else { throw ChildTaskTransferCommand.invalid }; self.raw = raw; return
        }
        guard Set(raw.keys) == ["protocol", "account", "request_id", "state", "replayed", "source_id", "destination_id", "source_generation", "destination_generation", "source_project", "destination_project", "action", "undo_of", "source_revision", "destination_revision", "node_key", "incarnation", "moved_count", "return_parent", "return_index"],
              case .bool? = raw["replayed"], (raw["state"] == .string("applied") || raw["state"] == .string("closed")),
              raw["action"] == command.body["action"], raw["undo_of"] == (command.body["undo_of"] ?? .null), raw["node_key"] == command.body["node_key"], raw["incarnation"] == command.body["incarnation"] else { throw ChildTaskTransferCommand.invalid }
        for name in ["source", "destination"] {
            let endpoint = command.body[name]!.object
            for (field, wire) in [("task_id", "id"), ("task_generation", "generation"), ("project_id", "project"), ("structure_revision", "revision")] {
                guard ChildTaskStructureCommand.exact(raw[name + "_" + wire], endpoint[field]) else { throw ChildTaskTransferCommand.invalid }
            }
        }
        if raw["state"] == .string("applied") {
            guard raw["moved_count"] == .number(Double(command.body["subtree_versions"]!.object.count)), try ChildTaskTransferCommand.slot(raw["return_index"]) <= 1000 else { throw ChildTaskTransferCommand.invalid }
            if raw["return_parent"] != .null { _ = try ChildTaskStructureCommand.key(raw["return_parent"]) }
        } else { guard raw["moved_count"] == .number(0), raw["return_parent"] == .null, raw["return_index"] == .null else { throw ChildTaskTransferCommand.invalid } }
        self.raw = raw
    }
    func agrees(_ other: Self) -> Bool { ChildTaskStructureCommand.exact(.object(raw.filter { $0.key != "replayed" }), .object(other.raw.filter { $0.key != "replayed" })) }
}

struct ChildTaskTransferFailure: LocalizedError {
    let reason: ChildTaskFieldWriteFailure.Reason
    var errorDescription: String? {
        switch reason {
        case .unavailable: return "Moving subtasks is unavailable or access changed. Your saved move is kept."
        case .review: return "A task changed. Check and stop the saved move before reviewing a new one."
        case .busy: return "Another change is finishing. Retry the original saved move shortly."
        case .limit: return "This move reached a size or storage limit. Your saved work is kept."
        case .closed: return "This move was stopped. Review a new move from the current tasks."
        case .unconfirmed: return "The move couldn’t be confirmed. Check its status or retry the original saved move."
        }
    }
}
struct ChildTaskTransferState: ReviewedTeamFileCommand {
    enum Phase: String, Codable, Sendable { case queued, attempted, applied, closed }
    struct Entry: Codable, Equatable, Sendable {
        let command: ChildTaskTransferCommand
        var phase: Phase = .queued
        var result: ChildTaskTransferResult?
        init(command: ChildTaskTransferCommand, phase: Phase = .queued, result: ChildTaskTransferResult? = nil) { self.command = command; self.phase = phase; self.result = result }
        private enum CodingKeys: String, CodingKey { case command, phase, result }
        init(from decoder: Decoder) throws {
            try structureKeys(decoder, ["command", "phase", "result"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            command = try c.decode(ChildTaskTransferCommand.self, forKey: .command); phase = try c.decode(Phase.self, forKey: .phase); result = try c.decodeIfPresent(ChildTaskTransferResult.self, forKey: .result)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(command, forKey: .command); try c.encode(phase, forKey: .phase); try c.encode(result, forKey: .result)
        }
    }
    static let storagePrefix = "child-transfer-journal-v1."
    static let fileName = "moves.taskfoldchildtransfers"
    static let encryptionContext = "com.taskfold.child-transfer-journal.v1"
    static let maximumStoredBytes = 8_400_000
    static var invalid: AppFailure { ChildTaskTransferCommand.invalid }
    let account: String, origin: String
    var entries: [Entry]
    init(account: String, origin: String, entries: [Entry] = []) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard entries.count <= 64 else { throw ChildTaskTransferFailure(reason: .limit) }
        var ids = Set<String>(), undos = Set<String>()
        for entry in entries {
            guard entry.command.account == account, entry.command.origin == origin, ids.insert(entry.command.id).inserted else { throw Self.invalid }
            if let result = entry.result {
                _ = try entry.command.result(result.raw)
                guard entry.phase == .applied && result.applied || entry.phase == .closed && result.closed else { throw Self.invalid }
            } else { guard entry.phase == .queued || entry.phase == .attempted else { throw Self.invalid } }
            if entry.command.undoing {
                guard let original = entries.first(where: { $0.command.id == entry.command.family }), original.phase == .applied, !original.command.undoing,
                      let result = original.result, result.applied,
                      entry.command.body["source"]!.object["task_id"] == original.command.body["destination"]!.object["task_id"],
                      entry.command.body["destination"]!.object["task_id"] == original.command.body["source"]!.object["task_id"],
                      entry.command.body["node_key"] == original.command.body["node_key"],
                      entry.command.body["incarnation"] == original.command.body["incarnation"] else { throw Self.invalid }
                try entry.command.validateUndo(original: original.command, receipt: result)
                if entry.phase != .closed { guard undos.insert(entry.command.family).inserted else { throw Self.invalid } }
            }
        }
        self.account = account; self.origin = origin; self.entries = entries
    }
    init(data: Data) throws {
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: Self.maximumStoredBytes)
        let raw = try TaskfoldJSONDecoder().decode([String: JSON].self, from: data)
        var paths: Set<[String]> = [["version"]]
        for row in raw["entries"]?.list ?? [] {
            paths.formUnion(ChildTaskTransferCommand.counterPaths(row.object["command"]?.object["body"]?.object ?? [:], prefix: ["entries", "[]", "command", "body"]))
        }
        paths.formUnion(ChildTaskTransferResult.counters.map { ["entries", "[]", "result", "raw"] + $0 })
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: Self.maximumStoredBytes, integerPaths: paths, nullableIntegerPaths: [["entries", "[]", "result", "raw", "return_index"]])
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
        var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(1, forKey: .version)
        try c.encode(account, forKey: .account); try c.encode(origin, forKey: .origin); try c.encode(entries, forKey: .entries)
    }
}

actor ChildTaskTransferJournal {
    private let admit: @Sendable (Set<String>) throws -> Void
    let account: String, origin: String
    private let io: any CalendarSecureItemIO, lock: AutomationEnrollmentProcessLock, removalDirectory: URL
    private var key: String { ChildTaskTransferState.storagePrefix + account + "." + CalendarOAuthConfiguration.digest(origin) }
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
    private func read() throws -> ChildTaskTransferState {
        guard let data = try io.read(key: key) else { return try .init(account: account, origin: origin) }
        let state = try ChildTaskTransferState(data: data)
        guard state.account == account, state.origin == origin else { throw ChildTaskTransferCommand.invalid }; return state
    }
    private func write(_ entries: [ChildTaskTransferState.Entry], lease: CalendarReadLease) throws {
        let state = try ChildTaskTransferState(account: account, origin: origin, entries: entries), data = try TaskfoldJSONEncoder().encode(state)
        guard data.count <= ChildTaskTransferState.maximumStoredBytes else { throw ChildTaskTransferFailure(reason: .limit) }
        try lease.check(); try io.write(data, key: key)
    }
    func load() throws -> ChildTaskTransferState { try guarded(nil) { try read() } }
    func enqueue(_ command: ChildTaskTransferCommand, lease: CalendarReadLease) throws {
        try guarded(lease) {
            try admit(command.roots)
            guard command.account == account, command.origin == origin else { throw ChildTaskTransferCommand.invalid }
            var state = try read()
            if let old = state.entries.first(where: { $0.command.id == command.id }) { guard old.command == command, old.phase != .closed else { throw ChildTaskTransferCommand.invalid }; return }
            guard !state.entries.contains(where: { ($0.phase == .queued || $0.phase == .attempted) && !$0.command.roots.isDisjoint(with: command.roots) }) else { throw ChildTaskTransferFailure(reason: .busy) }
            state.entries.append(.init(command: command)); try write(state.entries, lease: lease)
        }
    }
    func attempt(_ command: ChildTaskTransferCommand, lease: CalendarReadLease, resolving: Bool = false) throws -> ChildTaskTransferState.Entry {
        try guarded(lease) {
            if !resolving { try admit(command.roots) }
            var state = try read(); guard let i = state.entries.firstIndex(where: { $0.command == command }) else { throw ChildTaskTransferCommand.invalid }
            if state.entries[i].phase == .queued { state.entries[i].phase = .attempted; try write(state.entries, lease: lease) }
            return state.entries[i]
        }
    }
    func settle(_ command: ChildTaskTransferCommand, result: ChildTaskTransferResult, lease: CalendarReadLease) throws {
        try guarded(lease) {
            _ = try command.result(result.raw); guard !result.unknown else { throw ChildTaskTransferCommand.invalid }
            var state = try read(); guard let i = state.entries.firstIndex(where: { $0.command == command }), state.entries[i].phase != .queued else { throw ChildTaskTransferCommand.invalid }
            if let old = state.entries[i].result { guard old.agrees(result) else { throw ChildTaskTransferCommand.invalid }; return }
            state.entries[i].phase = result.applied ? .applied : .closed; state.entries[i].result = result; try write(state.entries, lease: lease)
        }
    }
    func discard(_ command: ChildTaskTransferCommand, lease: CalendarReadLease) throws {
        try guarded(lease) {
            var state = try read(); guard let i = state.entries.firstIndex(where: { $0.command == command }), state.entries[i].phase != .attempted else { throw ChildTaskTransferCommand.invalid }
            if state.entries[i].phase == .queued { guard !command.undoing else { state.entries.remove(at: i); try write(state.entries, lease: lease); return }; state.entries.remove(at: i) }
            else {
                guard !state.entries.contains(where: { $0.command.family == command.family && ($0.phase == .queued || $0.phase == .attempted) }) else { throw ChildTaskTransferCommand.invalid }
                state.entries.removeAll { $0.command.family == command.family }
            }
            try write(state.entries, lease: lease)
        }
    }
    func removeAccount() throws { try lock.withExclusive(account: account) { try io.remove(key: key) } }
}

enum ChildTaskTransferOperation: String, Sendable { case send, check, close }
@MainActor protocol ChildTaskTransferService: AnyObject {
    func childTaskTransfer(_ command: ChildTaskTransferCommand, operation: ChildTaskTransferOperation, session: UUID) async throws -> ChildTaskTransferResult
}
extension Backend: ChildTaskTransferService {}
@MainActor @Observable final class ChildTaskTransferModel {
    private(set) var entries: [ChildTaskTransferState.Entry] = []
    private(set) var busy = false
    private(set) var loaded = false
    private(set) var message: String?
    let scope: ChildTaskFieldClientScope
    private let journal: ChildTaskTransferJournal, service: any ChildTaskTransferService
    private let current: () -> ChildTaskFieldClientScope?
    private let canSend: (ChildTaskTransferCommand) -> Bool
    private let admit: (ChildTaskTransferCommand, ChildTaskStructureRead, ChildTaskStructureRead) async throws -> Void
    private let lease = CalendarReadLease()
    private var closed = false
    init(scope: ChildTaskFieldClientScope, journal: ChildTaskTransferJournal, service: any ChildTaskTransferService, current: @escaping () -> ChildTaskFieldClientScope?, canSend: @escaping (ChildTaskTransferCommand) -> Bool, admit: @escaping (ChildTaskTransferCommand, ChildTaskStructureRead, ChildTaskStructureRead) async throws -> Void) {
        self.scope = scope; self.journal = journal; self.service = service; self.current = current; self.canSend = canSend; self.admit = admit
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
            if error is AccountSessionAuthorizationRequired { message = "Sign in again to check your saved move." }
            else if let failure = error as? ChildTaskTransferFailure { message = failure.localizedDescription }
            else if let failure = error as? AppFailure { message = failure.localizedDescription }
            else { message = "The move couldn’t be confirmed. Your saved request is kept; check its status before starting another." }
            return false
        }
    }
    func load() async { _ = await work { try await update() } }
    func queue(_ command: ChildTaskTransferCommand, source: ChildTaskStructureRead, destination: ChildTaskStructureRead) async -> Bool {
        await work {
            guard ChildTaskFieldClientScope(source.context) == scope, ChildTaskFieldClientScope(destination.context) == scope else { throw CancellationError() }
            try command.review(source: source, destination: destination)
            try await admit(command, source, destination); try check()
            try await journal.enqueue(command, lease: lease); try check(); try await update(); message = "Move saved on this device."
        }
    }
    func run(_ command: ChildTaskTransferCommand, operation: ChildTaskTransferOperation) async -> Bool {
        let completed = await work {
            guard command.account == scope.account, command.origin == scope.origin else { throw CancellationError() }
            if operation == .send { guard canSend(command) else { throw ChildTaskTransferFailure(reason: .unavailable) } }
            let entry = try await journal.attempt(command, lease: lease, resolving: operation != .send); try check()
            let result: ChildTaskTransferResult
            if let old = entry.result { result = try command.result(old.raw) }
            else {
                if operation == .send { guard canSend(command) else { throw ChildTaskTransferFailure(reason: .unavailable) } }
                result = try await service.childTaskTransfer(command, operation: operation, session: scope.session); try check()
                _ = try command.result(result.raw)
                guard operation == .check || !result.unknown else { throw ChildTaskTransferFailure(reason: .unconfirmed) }
                if !result.unknown { try await journal.settle(command, result: result, lease: lease); try check() }
            }
            try await update()
            message = result.applied ? (command.undoing ? "Move undone." : "Subtask moved.") : result.closed ? "Move stopped. Your tasks are unchanged by this request." : "No confirmation yet. Retry the original move, or stop it before making a new one."
        }
        // A file write can finish before reporting an I/O error. Trust only the
        // reloaded, fully validated proof; never retry with a different identity.
        if !completed, (try? check()) != nil, let result = entries.first(where: { $0.command == command })?.result {
            message = result.applied ? (command.undoing ? "Move undone." : "Subtask moved.") : "Move stopped. Your tasks are unchanged by this request."
            return true
        }
        return completed
    }
    func discard(_ command: ChildTaskTransferCommand) async {
        _ = await work { try await journal.discard(command, lease: lease); try check(); try await update(); message = "Saved move history removed. Your tasks are unchanged." }
    }
}
