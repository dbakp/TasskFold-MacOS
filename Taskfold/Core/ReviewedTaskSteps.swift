import Foundation
import Observation

/// Literal reviewed titles, never a replacement task or an NLP capture request.
struct ReviewedTaskStepsCommand: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let account: String, origin: String
    let body: [String: JSON]
    var id: String { body["request_id"]!.text }
    var root: String { body["task_id"]!.text }
    var undoing: Bool { body["action"] == .string("undo") }
    var description: String { "Private reviewed task steps" }
    var debugDescription: String { description }
    static var invalid: AppFailure { .init(message: "Review these steps against the current task. Your saved work is kept.") }
    static let scopeKeys: Set<String> = ["protocol", "account", "task_id", "task_generation", "project_id"]
    static let baseKeys = scopeKeys.union(["request_id", "structure_revision", "action"])
    static func == (a: Self, b: Self) -> Bool {
        a.account == b.account && a.origin == b.origin && ChildTaskStructureCommand.exact(.object(a.body), .object(b.body))
    }
    init(titles: [String], parent: String?, read: ChildTaskStructureRead, index: Int? = nil, requestID: UUID = UUID()) throws {
        let node = parent.flatMap { read.records.nodes[$0] }
        guard parent == nil || node != nil else { throw Self.invalid }
        var b = Self.base(read, requestID: requestID)
        b["action"] = .string("insert"); b["parent_key"] = parent.map(JSON.string) ?? .null
        b["parent_incarnation"] = node.map { .string($0.incarnation) } ?? .null
        b["parent_revision"] = node.map { .number($0.revision) } ?? .null
        b["source_title"] = node?.fields["title"] ?? .string(read.context.root.title)
        b["index"] = .number(Double(index ?? read.records.orderedNodes.filter { $0.parent == parent }.count))
        b["steps"] = .array(try TaskBreakdownRequest.titles(titles).map { .object(["id": .string(UUID().uuidString.lowercased()), "title": .string($0)]) })
        try self.init(account: read.context.account, origin: read.context.origin, body: b)
        try review(read)
    }
    init(undo original: Self, receipt: ReviewedTaskStepsResult, read: ChildTaskStructureRead, requestID: UUID = UUID()) throws {
        guard !original.undoing, try original.result(receipt.raw) == receipt, receipt.applied,
              receipt.receipt!["after_revision"]!.integer <= Int(read.structureRevision) else { throw Self.invalid }
        var b = Self.base(read, requestID: requestID); b["action"] = .string("undo"); b["undo_of"] = .string(original.id)
        try self.init(account: original.account, origin: original.origin, body: b)
        try review(read)
        guard Self.scopeKeys.allSatisfy({ ChildTaskStructureCommand.exact(b[$0], original.body[$0]) }) else { throw Self.invalid }
    }
    init(redo original: Self, receipt: ReviewedTaskStepsResult, undo: Self, undoReceipt: ReviewedTaskStepsResult, read: ChildTaskStructureRead, requestID: UUID = UUID()) throws {
        let parent = original.body["parent_key"] == .null ? nil : original.body["parent_key"]!.text
        try self.init(titles: original.body["steps"]!.list.map { $0.object["title"]!.text }, parent: parent, read: read, index: original.body["index"]!.integer, requestID: requestID)
        try validateRedo(original: original, receipt: receipt, undo: undo, undoReceipt: undoReceipt)
    }
    func validateRedo(original: Self, receipt: ReviewedTaskStepsResult, undo: Self, undoReceipt: ReviewedTaskStepsResult) throws {
        guard !undoing, !original.undoing, undo.undoing, receipt.applied, undoReceipt.applied,
              try original.result(receipt.raw) == receipt, try undo.result(undoReceipt.raw) == undoReceipt,
              undo.body["undo_of"] == .string(original.id), id != original.id, id != undo.id,
              Self.scopeKeys.allSatisfy({ ChildTaskStructureCommand.exact(body[$0], original.body[$0]) && ChildTaskStructureCommand.exact(body[$0], undo.body[$0]) }),
              body["structure_revision"]!.integer >= undoReceipt.receipt!["after_revision"]!.integer, undo.body["structure_revision"]!.integer >= receipt.receipt!["after_revision"]!.integer,
              undoReceipt.receipt?["nodes"] == receipt.receipt?["nodes"],
              ["parent_key", "parent_incarnation", "source_title", "index"].allSatisfy({ ChildTaskStructureCommand.exact(body[$0], original.body[$0]) }),
              ChildTaskStructureCommand.exact(.array(body["steps"]!.list.map { $0.object["title"]! }), .array(original.body["steps"]!.list.map { $0.object["title"]! })),
              Set(body["steps"]!.list.map { $0.object["id"]!.text }).isDisjoint(with: Set(original.body["steps"]!.list.map { $0.object["id"]!.text })) else { throw Self.invalid }
    }
    private static func base(_ read: ChildTaskStructureRead, requestID: UUID) -> [String: JSON] {
        ["protocol": .number(1), "account": .string(read.context.account), "request_id": .string(requestID.uuidString.lowercased()),
         "task_id": .string(read.context.root.id), "task_generation": read.context.root["task_generation"],
         "project_id": read.context.root["project_id"], "structure_revision": .number(read.structureRevision)]
    }
    init(account: String, origin: String, body: [String: JSON]) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard origin.utf8.count <= 2048, body["protocol"] == .number(1), body["account"] == .string(account),
              [.string("insert"), .string("undo")].contains(body["action"]),
              try TeamProjectValue.revision(body["structure_revision"]) < 9_007_199_254_740_991 else { throw Self.invalid }
        for key in ["task_id", "request_id"] { _ = try TeamOrganizationValue.id(body[key]) }
        for key in ["task_generation", "project_id"] { _ = try TeamProjectValue.optionalID(body[key]) }
        let undo = body["action"] == .string("undo")
        guard Set(body.keys) == Self.baseKeys.union(undo ? ["undo_of"] : ["parent_key", "parent_incarnation", "parent_revision", "source_title", "index", "steps"]) else { throw Self.invalid }
        if undo {
            _ = try TeamOrganizationValue.id(body["undo_of"])
            guard body["undo_of"] != body["request_id"] else { throw Self.invalid }
        } else {
            if body["parent_key"] == .null {
                guard body["parent_incarnation"] == .null, body["parent_revision"] == .null else { throw Self.invalid }
            } else {
                _ = try ChildTaskStructureCommand.key(body["parent_key"])
                _ = try TeamOrganizationValue.id(body["parent_incarnation"])
                _ = try TeamProjectValue.revision(body["parent_revision"])
            }
            guard case .string(let title)? = body["source_title"], title.utf8.count <= 2000 else { throw Self.invalid }
            _ = try TaskBreakdownRequest.goal(title); _ = try ChildTaskTransferCommand.slot(body["index"])
            guard case .number(let index)? = body["index"], index.sign == .plus else { throw Self.invalid }
            let rows = try TeamOrganizationValue.rows(body["steps"], limit: 12)
            let titles = try TaskBreakdownRequest.titles(rows.map { $0["title"]?.text ?? "" })
            var ids = Set<String>()
            for (row, title) in zip(rows, titles) {
                let id = try TeamOrganizationValue.id(row["id"])
                guard title.unicodeScalars.count <= 300, Set(row.keys) == ["id", "title"], id == UUID(uuidString: id)?.uuidString.lowercased(), ids.insert(id).inserted,
                      ChildTaskStructureCommand.exact(row["title"], .string(title)) else { throw Self.invalid }
            }
        }
        guard try TaskfoldJSONEncoder().encode(body).count <= 20_000 else { throw Self.invalid }
        self.account = account; self.origin = origin; self.body = body
    }
    private enum CodingKeys: CodingKey { case account, origin, body }
    init(from decoder: Decoder) throws {
        try structureKeys(decoder, ["account", "origin", "body"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), body: c.decode([String: JSON].self, forKey: .body))
    }
    func review(_ read: ChildTaskStructureRead) throws {
        guard account == read.context.account, origin == read.context.origin, root == read.context.root.id,
              ChildTaskStructureCommand.exact(body["task_generation"], read.context.root["task_generation"]),
              ChildTaskStructureCommand.exact(body["project_id"], read.context.root["project_id"]), body["structure_revision"] == .number(read.structureRevision) else { throw Self.invalid }
        guard !undoing else { return }
        let parent = body["parent_key"] == .null ? nil : body["parent_key"]!.text
        let node = parent.flatMap { read.records.nodes[$0] }
        let target = node.map { Record($0.fields) } ?? read.context.root
        guard !read.context.root.completed, TaskKind.mayComplete(read.context.root), !target.completed, TaskKind.mayComplete(target),
              (node?.path.count ?? 0) < 24, read.records.nodes.count + body["steps"]!.list.count <= 1000,
              ChildTaskStructureCommand.exact(body["source_title"], .string(target.title)),
              body["index"]!.integer <= read.records.orderedNodes.filter { $0.parent == parent }.count else { throw Self.invalid }
        if parent != nil {
            guard let node, body["parent_incarnation"] == .string(node.incarnation), body["parent_revision"] == .number(node.revision),
                  ["null", "array", "absent"].contains(node.childrenKind) else { throw Self.invalid }
        }
        for step in body["steps"]!.list { guard read.records.nodes[step.object["id"]!.text] == nil else { throw Self.invalid } }
    }
    func result(_ raw: [String: JSON]) throws -> ReviewedTaskStepsResult { try .init(command: self, raw: raw) }
}

/// A resolution never turns absence into success or permission to change IDs.
struct ReviewedTaskStepsResult: Codable, Equatable, Sendable {
    let raw: [String: JSON]
    var applied: Bool { raw["outcome"] == .string("applied") }
    var closed: Bool { raw["outcome"] == .string("closed") }
    var receipt: [String: JSON]? { if case .object(let r)? = raw["receipt"] { return r }; return nil }
    init(command: ReviewedTaskStepsCommand, raw: [String: JSON]) throws {
        guard Set(raw.keys) == ["protocol", "account", "request_id", "outcome", "receipt"], raw["protocol"] == .number(1),
              raw["account"] == .string(command.account), raw["request_id"] == .string(command.id),
              [.string("applied"), .string("absent"), .string("closed")].contains(raw["outcome"]) else { throw ReviewedTaskStepsCommand.invalid }
        if raw["outcome"] == .string("applied") {
            guard case .object(let r)? = raw["receipt"], Set(r.keys) == ReviewedTaskStepsCommand.scopeKeys.union(["request_id", "action", "undo_of", "before_revision", "after_revision", "nodes", "count", "replayed"]),
                  ReviewedTaskStepsCommand.scopeKeys.union(["request_id", "action"]).allSatisfy({ ChildTaskStructureCommand.exact(r[$0], command.body[$0]) }),
                  r["undo_of"] == (command.body["undo_of"] ?? .null), r["before_revision"] == command.body["structure_revision"],
                  try TeamProjectValue.revision(r["after_revision"]) == TeamProjectValue.revision(r["before_revision"]) + 1,
                  case .bool? = r["replayed"] else { throw ReviewedTaskStepsCommand.invalid }
            let nodes = try TeamOrganizationValue.rows(r["nodes"], limit: 12)
            guard !nodes.isEmpty, r["count"] == .number(Double(nodes.count)) else { throw ReviewedTaskStepsCommand.invalid }
            var seen = Set<String>()
            for node in nodes {
                guard Set(node.keys) == ["node_key", "incarnation"] else { throw ReviewedTaskStepsCommand.invalid }
                let key = try TeamOrganizationValue.id(node["node_key"]); _ = try TeamOrganizationValue.id(node["incarnation"])
                guard seen.insert(key).inserted else { throw ReviewedTaskStepsCommand.invalid }
            }
            if !command.undoing { guard nodes.map({ $0["node_key"]! }) == command.body["steps"]!.list.map({ $0.object["id"]! }) else { throw ReviewedTaskStepsCommand.invalid } }
        } else { guard raw["receipt"] == .null else { throw ReviewedTaskStepsCommand.invalid } }
        self.raw = raw
    }
    func agrees(_ other: Self) -> Bool {
        var a = raw, b = other.raw
        if var r = receipt { r["replayed"] = .bool(false); a["receipt"] = .object(r) }
        if var r = other.receipt { r["replayed"] = .bool(false); b["receipt"] = .object(r) }
        return ChildTaskStructureCommand.exact(.object(a), .object(b))
    }
    init(data: Data, command: ReviewedTaskStepsCommand, applying: Bool = false) throws {
        var raw = try ReviewedTaskStepsWire.object(data, maximum: 16_000, integerPaths: applying ? [["protocol"], ["before_revision"], ["after_revision"], ["count"]] : [["protocol"], ["receipt", "protocol"], ["receipt", "before_revision"], ["receipt", "after_revision"], ["receipt", "count"]])
        if applying { raw = ["protocol": .number(1), "account": .string(command.account), "request_id": .string(command.id), "outcome": .string("applied"), "receipt": .object(raw)] }
        try self.init(command: command, raw: raw)
    }
}

struct ReviewedTaskStepsAvailability: Sendable {
    let enabled: Bool
    init(data: Data, read: ChildTaskStructureRead) throws {
        let r = try ReviewedTaskStepsWire.object(data, maximum: 4_000, integerPaths: [["protocol"], ["structure_revision"], ["maximum_steps"]])
        guard Set(r.keys) == ["protocol", "account", "task_id", "task_generation", "project_id", "structure_revision", "maximum_steps", "enabled"],
              r["protocol"] == .number(1), r["account"] == .string(read.context.account), r["task_id"] == .string(read.context.root.id),
              r["task_generation"] == read.context.root["task_generation"], r["project_id"] == read.context.root["project_id"],
              r["structure_revision"] == .number(read.structureRevision), r["maximum_steps"] == .number(12), case .bool(let value)? = r["enabled"] else { throw ReviewedTaskStepsCommand.invalid }
        enabled = value
    }
}

struct ReviewedTaskStepsState: ReviewedTeamFileCommand, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "Private reviewed step history" }
    var debugDescription: String { description }
    enum Phase: String, Codable, Sendable { case queued, attempted, applied, closed }
    struct Entry: Codable, Equatable, Sendable {
        let command: ReviewedTaskStepsCommand
        var phase: Phase = .queued
        var result: ReviewedTaskStepsResult?
        let redoOf: String?
        init(command: ReviewedTaskStepsCommand, phase: Phase = .queued, result: ReviewedTaskStepsResult? = nil, redoOf: String? = nil) { self.command = command; self.phase = phase; self.result = result; self.redoOf = redoOf }
        private enum CodingKeys: CodingKey { case command, phase, result, redoOf }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            try structureKeys(decoder, c.contains(.redoOf) ? ["command", "phase", "result", "redoOf"] : ["command", "phase", "result"])
            redoOf = try c.decodeIfPresent(String.self, forKey: .redoOf)
            if c.contains(.redoOf), redoOf == nil { throw ReviewedTaskStepsState.invalid }
            command = try c.decode(ReviewedTaskStepsCommand.self, forKey: .command); phase = try c.decode(Phase.self, forKey: .phase); result = try c.decodeIfPresent(ReviewedTaskStepsResult.self, forKey: .result)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(command, forKey: .command); try c.encode(phase, forKey: .phase); try c.encode(result, forKey: .result); try c.encodeIfPresent(redoOf, forKey: .redoOf)
        }
    }
    static let storagePrefix = "reviewed-task-steps-v1."
    static let fileName = "requests.taskfoldsteps"
    static let encryptionContext = "com.taskfold.reviewed-task-steps.v1"
    static let maximumStoredBytes = 1_600_000
    static var invalid: AppFailure { ReviewedTaskStepsCommand.invalid }
    let account: String, origin: String
    let entries: [Entry]
    init(account: String, origin: String, entries: [Entry] = []) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard entries.count <= 32 else { throw AppFailure(message: "Remove settled step history before adding more steps.") }
        var ids = Set<String>(), pending = Set<String>(), undos = Set<String>()
        for entry in entries {
            let c = entry.command
            guard c.account == account, c.origin == origin, ids.insert(c.id).inserted else { throw Self.invalid }
            if entry.phase == .applied || entry.phase == .closed {
                guard let r = entry.result, try c.result(r.raw) == r, (entry.phase == .applied ? r.applied : r.closed) else { throw Self.invalid }
            } else { guard entry.result == nil, pending.insert(c.root).inserted else { throw Self.invalid } }
            if let parent = entry.redoOf {
                guard !c.undoing, let undo = entries.first(where: { $0.command.id == parent }), undo.phase == .applied, let reversed = undo.result,
                      let original = entries.first(where: { $0.command.id == undo.command.body["undo_of"]?.text }), original.phase == .applied, let proof = original.result else { throw Self.invalid }
                try c.validateRedo(original: original.command, receipt: proof, undo: undo.command, undoReceipt: reversed)
                if entry.phase != .closed { guard undos.insert("redo:" + parent).inserted else { throw Self.invalid } }
            }
            if c.undoing {
                guard let original = entries.first(where: { $0.command.id == c.body["undo_of"]!.text }), !original.command.undoing,
                      original.phase == .applied, let r = original.result?.receipt,
                      ReviewedTaskStepsCommand.scopeKeys.allSatisfy({ ChildTaskStructureCommand.exact(c.body[$0], original.command.body[$0]) }),
                      c.body["structure_revision"]!.integer >= r["after_revision"]!.integer else { throw Self.invalid }
                if entry.phase != .closed { guard undos.insert(original.command.id).inserted else { throw Self.invalid } }
                if let nodes = entry.result?.receipt?["nodes"] { guard nodes == r["nodes"] else { throw Self.invalid } }
            }
        }
        _ = try Self.families(entries)
        self.account = account; self.origin = origin; self.entries = entries
    }
    static func families(_ entries: [Entry]) throws -> [String: String] {
        var rows: [String: Entry] = [:], result: [String: String] = [:]
        for e in entries { guard rows.updateValue(e, forKey: e.command.id) == nil else { throw invalid } }
        for entry in entries {
            var id = entry.command.id, seen = Set<String>()
            while true {
                guard seen.insert(id).inserted, let row = rows[id] else { throw invalid }
                guard let parent = row.redoOf ?? row.command.body["undo_of"]?.text else { result[entry.command.id] = id; break }
                id = parent
            }
        }
        return result
    }
    private enum CodingKeys: CodingKey { case version, account, origin, entries }
    init(from decoder: Decoder) throws {
        try structureKeys(decoder, ["version", "account", "origin", "entries"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version), entries = try c.decode([Entry].self, forKey: .entries)
        guard [1, 2].contains(version), version != 1 || !entries.contains(where: { $0.redoOf != nil }) else { throw Self.invalid }
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), entries: entries)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(entries.contains(where: { $0.redoOf != nil }) ? 2 : 1, forKey: .version); try c.encode(account, forKey: .account); try c.encode(origin, forKey: .origin); try c.encode(entries, forKey: .entries)
    }
    init(data: Data) throws {
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: Self.maximumStoredBytes, integerPaths: [["version"], ["entries", "[]", "command", "body", "protocol"], ["entries", "[]", "command", "body", "structure_revision"], ["entries", "[]", "command", "body", "index"], ["entries", "[]", "result", "raw", "protocol"], ["entries", "[]", "result", "raw", "receipt", "protocol"], ["entries", "[]", "result", "raw", "receipt", "before_revision"], ["entries", "[]", "result", "raw", "receipt", "after_revision"], ["entries", "[]", "result", "raw", "receipt", "count"]], nullableIntegerPaths: [["entries", "[]", "command", "body", "parent_revision"]])
        self = try TaskfoldJSONDecoder().decode(Self.self, from: data)
    }
}

actor ReviewedTaskStepsJournal {
    let account: String, origin: String
    private let io: any CalendarSecureItemIO, lock: AutomationEnrollmentProcessLock, removalDirectory: URL
    private let admit: @Sendable (Set<String>) throws -> Void
    private var key: String { ReviewedTaskStepsState.storagePrefix + account + "." + CalendarOAuthConfiguration.digest(origin) }
    init(account: String, origin: String, io: any CalendarSecureItemIO, coordinationDirectory: URL, removalDirectory: URL, admit: @escaping @Sendable (Set<String>) throws -> Void = { _ in }) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin); self.account = account; self.origin = origin; self.io = io; self.removalDirectory = removalDirectory; self.admit = admit; lock = .init(directory: coordinationDirectory)
    }
    private func guarded<T>(_ lease: CalendarReadLease?, _ action: () throws -> T) throws -> T {
        try lock.withExclusive(account: account, check: { try lease?.check() }) { try AccountRemovalDisk(directory: removalDirectory, account: account).writable { try lease?.check(); return try action() } }
    }
    private func read() throws -> ReviewedTaskStepsState {
        guard let data = try io.read(key: key) else { return try .init(account: account, origin: origin) }
        let state = try ReviewedTaskStepsState(data: data); guard state.account == account, state.origin == origin else { throw ReviewedTaskStepsState.invalid }; return state
    }
    private func write(_ entries: [ReviewedTaskStepsState.Entry], lease: CalendarReadLease) throws {
        let data = try TaskfoldJSONEncoder().encode(ReviewedTaskStepsState(account: account, origin: origin, entries: entries))
        guard data.count <= ReviewedTaskStepsState.maximumStoredBytes else { throw ReviewedTaskStepsState.invalid }
        try lease.check(); try io.write(data, key: key)
    }
    func load() throws -> ReviewedTaskStepsState { try guarded(nil) { try read() } }
    /// Exact Undo recovery is chosen while holding the shared account lock.
    func enqueue(_ command: ReviewedTaskStepsCommand, lease: CalendarReadLease, redoOf: String? = nil) throws -> ReviewedTaskStepsCommand {
        try guarded(lease) {
            guard command.account == account, command.origin == origin else { throw ReviewedTaskStepsState.invalid }
            var entries = try read().entries
            if let prior = entries.first(where: { $0.command.id == command.id }) { guard prior.command == command, prior.redoOf == redoOf, prior.phase != .closed else { throw ReviewedTaskStepsState.invalid }; return prior.command }
            if let redoOf {
                guard let undo = entries.first(where: { $0.command.id == redoOf }), undo.phase == .applied, let reversed = undo.result,
                      let original = entries.first(where: { $0.command.id == undo.command.body["undo_of"]?.text }), original.phase == .applied, let proof = original.result else { throw ReviewedTaskStepsState.invalid }
                try command.validateRedo(original: original.command, receipt: proof, undo: undo.command, undoReceipt: reversed)
                if let existing = entries.first(where: { $0.redoOf == redoOf && $0.phase != .closed }) { return existing.command }
            }
            if command.undoing {
                guard redoOf == nil else { throw ReviewedTaskStepsState.invalid }
                guard let original = entries.first(where: { $0.command.id == command.body["undo_of"]?.text }), original.phase == .applied, !original.command.undoing,
                      ReviewedTaskStepsCommand.scopeKeys.allSatisfy({ ChildTaskStructureCommand.exact(command.body[$0], original.command.body[$0]) }),
                      command.body["structure_revision"]!.integer >= original.result!.receipt!["after_revision"]!.integer else { throw ReviewedTaskStepsState.invalid }
                if let existing = entries.first(where: { $0.command.body["undo_of"] == command.body["undo_of"] && $0.phase != .closed }) { return existing.command }
            }
            try admit([command.root]); entries.append(.init(command: command, redoOf: redoOf)); try write(entries, lease: lease); return command
        }
    }
    func attempt(_ command: ReviewedTaskStepsCommand, lease: CalendarReadLease, resolving: Bool) throws -> ReviewedTaskStepsState.Entry {
        try guarded(lease) {
            if !resolving { try admit([command.root]) }
            var entries = try read().entries; guard let i = entries.firstIndex(where: { $0.command == command }) else { throw ReviewedTaskStepsState.invalid }
            if entries[i].phase == .queued { entries[i].phase = .attempted; try write(entries, lease: lease) }; return entries[i]
        }
    }
    func settle(_ command: ReviewedTaskStepsCommand, result: ReviewedTaskStepsResult, lease: CalendarReadLease) throws {
        try guarded(lease) {
            _ = try command.result(result.raw); guard result.applied || result.closed else { throw ReviewedTaskStepsState.invalid }
            var entries = try read().entries; guard let i = entries.firstIndex(where: { $0.command == command }), entries[i].phase != .queued else { throw ReviewedTaskStepsState.invalid }
            if let old = entries[i].result { guard old.agrees(result) else { throw ReviewedTaskStepsState.invalid }; return }
            entries[i].phase = result.applied ? .applied : .closed; entries[i].result = result; try write(entries, lease: lease)
        }
    }
    func forget(_ command: ReviewedTaskStepsCommand, lease: CalendarReadLease) throws {
        try guarded(lease) {
            var entries = try read().entries
            let families = try ReviewedTaskStepsState.families(entries)
            guard let family = families[command.id] else { throw ReviewedTaskStepsState.invalid }
            let rows = entries.filter { families[$0.command.id] == family }
            guard rows.contains(where: { $0.command == command }), rows.allSatisfy({ $0.phase == .applied || $0.phase == .closed }) else { throw ReviewedTaskStepsState.invalid }
            entries.removeAll { families[$0.command.id] == family }; try write(entries, lease: lease)
        }
    }
    func removeAccount() throws { try lock.withExclusive(account: account) { try io.remove(key: key) } }
}

enum ReviewedTaskStepsOperation: String, Sendable { case apply, resolve, close }
@MainActor protocol ReviewedTaskStepsService: AnyObject {
    func reviewedTaskSteps(_ command: ReviewedTaskStepsCommand, operation: ReviewedTaskStepsOperation, session: UUID) async throws -> ReviewedTaskStepsResult
    func reviewedTaskStepsAvailability(_ read: ChildTaskStructureRead) async throws -> ReviewedTaskStepsAvailability
}
extension Backend: ReviewedTaskStepsService {}

@MainActor @Observable final class ReviewedTaskStepsModel {
    private(set) var entries: [ReviewedTaskStepsState.Entry] = []
    private(set) var busy = false
    private(set) var loaded = false
    private(set) var message: String?
    let scope: ChildTaskFieldClientScope
    private let journal: ReviewedTaskStepsJournal, service: any ReviewedTaskStepsService
    private let current: () -> ChildTaskFieldClientScope?
    private let canSend: (ReviewedTaskStepsCommand) -> Bool
    private let isCurrent: (ChildTaskStructureRead) -> Bool
    private let didApply: (ReviewedTaskStepsState.Entry, ChildTaskFieldClientScope) -> Void
    private let refresh: () async -> Void
    private let lease = CalendarReadLease()
    private var closed = false
    init(scope: ChildTaskFieldClientScope, journal: ReviewedTaskStepsJournal, service: any ReviewedTaskStepsService, current: @escaping () -> ChildTaskFieldClientScope?, canSend: @escaping (ReviewedTaskStepsCommand) -> Bool, isCurrent: @escaping (ChildTaskStructureRead) -> Bool, refresh: @escaping () async -> Void, didApply: @escaping (ReviewedTaskStepsState.Entry, ChildTaskFieldClientScope) -> Void = { _, _ in }) {
        self.scope = scope; self.journal = journal; self.service = service; self.current = current; self.canSend = canSend; self.isCurrent = isCurrent; self.refresh = refresh; self.didApply = didApply
    }
    func close() { closed = true; lease.cancel(); entries = []; busy = false; loaded = false; message = nil }
    private func check() throws { try lease.check(); try Task.checkCancellation(); guard !closed, current() == scope else { throw CancellationError() } }
    private func update() async throws { let state = try await journal.load(); try check(); entries = state.entries; loaded = true }
    private func work(_ action: () async throws -> Void) async -> Bool {
        guard !busy else { return false }; busy = true; defer { busy = false }
        do { try check(); try await action(); try check(); return true }
        catch {
            guard (try? check()) != nil else { close(); return false }
            do { try await update() } catch { loaded = false; entries = [] }
            guard (try? check()) != nil else { close(); return false }
            message = error is AccountSessionAuthorizationRequired ? "Sign in again to check your saved steps." : (error as? AppFailure)?.localizedDescription ?? "The result couldn’t be confirmed. Your original request is kept; check or retry it before adding more steps."
            return false
        }
    }
    func load() async { _ = await work { try await update() } }
    func available(_ read: ChildTaskStructureRead) async throws -> Bool {
        try check(); guard ChildTaskFieldClientScope(read.context) == scope, isCurrent(read) else { throw CancellationError() }
        let result = try await service.reviewedTaskStepsAvailability(read); try check(); guard isCurrent(read) else { throw CancellationError() }; return result.enabled
    }
    func queue(_ command: ReviewedTaskStepsCommand, read: ChildTaskStructureRead, redoOf: String? = nil) async -> ReviewedTaskStepsCommand? {
        var saved: ReviewedTaskStepsCommand?
        let success = await work {
            guard ChildTaskFieldClientScope(read.context) == scope, isCurrent(read), canSend(command) else { throw ReviewedTaskStepsCommand.invalid }
            try command.review(read)
            if !command.undoing { guard try await available(read) else { throw AppFailure(message: "Adding reviewed steps is unavailable right now. Your task is unchanged.") } }
            saved = try await journal.enqueue(command, lease: lease, redoOf: redoOf); try check(); try await update()
        }
        return success ? saved : nil
    }
    @discardableResult func run(_ command: ReviewedTaskStepsCommand, operation: ReviewedTaskStepsOperation) async -> Bool {
        var alreadyApplied = false
        let completed = await work {
            guard command.account == scope.account, command.origin == scope.origin else { throw CancellationError() }
            if operation == .apply { guard canSend(command) else { throw ReviewedTaskStepsCommand.invalid } }
            let entry = try await journal.attempt(command, lease: lease, resolving: operation != .apply); try check(); alreadyApplied = entry.phase == .applied
            let result: ReviewedTaskStepsResult
            if let old = entry.result { result = old }
            else {
                if operation == .apply { guard canSend(command) else { throw ReviewedTaskStepsCommand.invalid } }
                result = try await service.reviewedTaskSteps(command, operation: operation, session: scope.session); try check()
                _ = try command.result(result.raw)
                guard operation == .resolve || result.applied || result.closed else { throw ReviewedTaskStepsCommand.invalid }
                if result.applied || result.closed { try await journal.settle(command, result: result, lease: lease); try check() }
            }
            try await update()
            message = result.applied ? (command.undoing ? "Added steps removed." : "\(result.receipt!["count"]!.integer) steps added.") : result.closed ? "Addition stopped. This request can’t add steps later." : "No saved confirmation yet. Retry the original request or stop it before starting another."
            if result.applied { await refresh(); try check() }
        }
        if (try? check()) != nil, let applied = entries.first(where: { $0.command == command && $0.phase == .applied }) {
            if !alreadyApplied { didApply(applied, scope) }; return true
        }
        return completed
    }
    func canRedo(_ entry: ReviewedTaskStepsState.Entry) -> Bool {
        entries.contains(entry) && entry.phase == .applied && entry.command.undoing && !entries.contains { $0.redoOf == entry.command.id && $0.phase != .closed }
    }
    func queueInverse(_ entry: ReviewedTaskStepsState.Entry, read: ChildTaskStructureRead) async -> ReviewedTaskStepsCommand? {
        do {
            try check(); guard entries.contains(entry), let receipt = entry.result else { throw ReviewedTaskStepsCommand.invalid }
            if !entry.command.undoing {
                guard canUndo(entry) else { throw ReviewedTaskStepsCommand.invalid }
                return await queue(try .init(undo: entry.command, receipt: receipt, read: read), read: read)
            }
            guard canRedo(entry), let original = entries.first(where: { $0.command.id == entry.command.body["undo_of"]?.text }), let proof = original.result else { throw ReviewedTaskStepsCommand.invalid }
            return await queue(try .init(redo: original.command, receipt: proof, undo: entry.command, undoReceipt: receipt, read: read), read: read, redoOf: entry.command.id)
        } catch { guard (try? check()) != nil else { close(); return nil }; message = "This change needs review. Your original steps and saved requests are kept."; return nil }
    }
    func canUndo(_ entry: ReviewedTaskStepsState.Entry) -> Bool {
        entries.contains(entry) && entry.phase == .applied && !entry.command.undoing && !entries.contains { $0.command.body["undo_of"] == .string(entry.command.id) && $0.phase != .closed }
    }
    func forget(_ command: ReviewedTaskStepsCommand) async { _ = await work { try await journal.forget(command, lease: lease); try await update(); message = "Saved step history removed. Your tasks are unchanged." } }
}

private enum ReviewedTaskStepsWire {
    static func object(_ data: Data, maximum: Int, integerPaths: Set<[String]>) throws -> [String: JSON] {
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: maximum, integerPaths: integerPaths)
        return try TaskfoldJSONDecoder().decode([String: JSON].self, from: data)
    }
}
