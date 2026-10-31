import Foundation
import CryptoKit
import Observation

private struct ChildCompletionKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func completionKeys(_ decoder: Decoder, _ expected: Set<String>) throws {
    let c = try decoder.container(keyedBy: ChildCompletionKey.self)
    guard Set(c.allKeys.map(\.stringValue)) == expected else { throw ChildTaskCompletionDraft.invalid }
}

/// Durable requests bind account/server, rather than a sign-in incarnation.
/// A fresh live sender lease is required on every run, including cold retries.
struct ChildTaskCompletionCommand: ReviewedTeamCommand, CustomStringConvertible, CustomDebugStringConvertible {
    struct Original: Codable, Equatable, Sendable {
        let body: [String: JSON]
        let receipt: [String: JSON]
        init(body: [String: JSON], receipt: [String: JSON]) { self.body = body; self.receipt = receipt }
        private enum CodingKeys: String, CodingKey { case body, receipt }
        init(from decoder: Decoder) throws {
            try completionKeys(decoder, ["body", "receipt"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            body = try c.decode([String: JSON].self, forKey: .body); receipt = try c.decode([String: JSON].self, forKey: .receipt)
        }
    }
    static let storagePrefix = "child-completion-command-v1."
    static let maximumStoredBytes = 32_000
    static var invalid: AppFailure { ChildTaskCompletionDraft.invalid }
    let account: String, origin: String
    let body: [String: JSON]
    let original: Original?
    var id: String { body["request_id"]!.text }
    var isUndo: Bool { original != nil }
    var description: String { "Private child completion request" }
    var debugDescription: String { description }

    init(_ draft: ChildTaskCompletionDraft) throws {
        try self.init(account: draft.account, origin: draft.origin, body: draft.body, original: nil)
    }
    init(undo command: Self, receipt: ChildTaskCompletionReceipt, read: ChildTaskRecordRead, requestID: UUID = UUID()) throws {
        guard command.original == nil else { throw Self.invalid }
        _ = try command.confirmed(receipt.raw)
        guard let node = read.nodes[command.body["node_key"]!.text], read.context.account == command.account,
              read.context.origin == command.origin,
              AuthoredValueComparison.exactJSON(.object(node.fields.filter { ChildTaskCompletionDraft.cohort.contains($0.key) }), receipt.raw["after"]!) else { throw Self.invalid }
        let body: [String: JSON] = ["protocol": .number(1), "account": .string(command.account), "request_id": .string(requestID.uuidString.lowercased()),
            "task_id": .string(read.context.root.id), "task_generation": read.context.root["task_generation"], "project_id": read.context.root["project_id"],
            "node_key": .string(node.key), "incarnation": .string(node.incarnation), "revision": .number(node.revision), "action": .string("undo"), "undo_of": .string(command.id)]
        try self.init(account: command.account, origin: command.origin, body: body, original: Original(body: command.body, receipt: receipt.raw))
    }
    init(account: String, origin: String, body: [String: JSON], original: Original? = nil) throws {
        if let original {
            let source = try Self(account: account, origin: origin, body: original.body)
            let proof = try source.confirmed(original.receipt)
            guard Set(body.keys) == Set(["protocol", "account", "request_id", "task_id", "task_generation", "project_id", "node_key", "incarnation", "revision", "action", "undo_of"]),
                  body["action"] == .string("undo"), body["undo_of"] == .string(source.id), body["request_id"] != .string(source.id) else { throw Self.invalid }
            // Reuse the regular identity/scope/body validator with the inverse
            // action and current certified cohort. This never creates a write.
            var inverse = body; inverse.removeValue(forKey: "undo_of")
            let state = proof.raw["after"]!.object
            let done = try ChildTaskCompletionDraft.completed(state)
            inverse["action"] = .string(done ? "reopen" : "complete"); inverse["baseline"] = .object(state)
            try ChildTaskCompletionDraft.validate(account: account, origin: origin, body: inverse)
            guard Self.identity.allSatisfy({ body[$0] == source.body[$0] }),
                  try TeamProjectValue.revision(body["revision"]) >= TeamProjectValue.revision(proof.raw["revision"]) else { throw Self.invalid }
        } else {
            try ChildTaskCompletionDraft.validate(account: account, origin: origin, body: body)
        }
        self.account = account; self.origin = origin; self.body = body; self.original = original
        guard try TaskfoldJSONEncoder().encode(self).count <= Self.maximumStoredBytes else { throw Self.invalid }
    }
    static let identity = ["protocol", "account", "task_id", "task_generation", "project_id", "node_key", "incarnation"]
    func sameTarget(_ other: Self) -> Bool { account == other.account && origin == other.origin && Self.identity.allSatisfy { body[$0] == other.body[$0] } }
    func review(_ read: ChildTaskRecordRead) throws {
        let revision = try TeamProjectValue.revision(body["revision"])
        guard read.context.account == account, read.context.origin == origin,
              body["task_id"] == .string(read.context.root.id), body["task_generation"] == read.context.root["task_generation"], body["project_id"] == read.context.root["project_id"],
              let node = read.nodes[body["node_key"]!.text], body["incarnation"] == .string(node.incarnation),
              node.revision >= revision else { throw Self.invalid }
        let current = node.fields.filter { ChildTaskCompletionDraft.cohort.contains($0.key) }
        _ = try ChildTaskCompletionDraft.completed(current)
        let expected = original?.receipt["after"] ?? body["baseline"]!
        guard AuthoredValueComparison.exactJSON(.object(current), expected),
              current[TeamChecklist.key] != nil || node.revision == revision else { throw Self.invalid }
    }
    func confirmed(_ raw: [String: JSON]) throws -> ChildTaskCompletionReceipt {
        guard Set(raw.keys) == Set(Self.identity + ["request_id", "revision", "action", "undo_of", "before", "after", "replayed"]),
              (Self.identity + ["request_id", "action"]).allSatisfy({ AuthoredValueComparison.exactJSON(raw[$0] ?? .null, body[$0] ?? .null) }),
              raw["undo_of"] == (body["undo_of"] ?? .null), case .bool? = raw["replayed"],
              try TeamProjectValue.revision(raw["revision"]) > TeamProjectValue.revision(body["revision"]),
              case .object(let before)? = raw["before"], case .object(let after)? = raw["after"],
              Set(after.keys).isSubset(of: ChildTaskCompletionDraft.cohort),
              AuthoredValueComparison.exactJSON(.object(before), original?.receipt["after"] ?? body["baseline"]!) else { throw Self.invalid }
        _ = try ChildTaskCompletionDraft.completed(before)
        _ = try ChildTaskCompletionDraft.completed(after, allowExhausted: true)
        guard let next = TeamChecklist.token(after[TeamChecklist.key]) else { throw Self.invalid }
        if let old = TeamChecklist.token(before[TeamChecklist.key]) {
            guard next.epoch == old.epoch, next.version == old.version + 1 else { throw Self.invalid }
        } else { guard next.version == 1 else { throw Self.invalid } }
        var expected: [String: JSON]
        if let original {
            expected = original.receipt["before"]!.object
        } else {
            expected = before
            let done = body["action"] == .string("complete")
            expected["completed"] = .bool(done)
            expected["completed_at"] = done ? after["completed_at"] : .null
        }
        expected[TeamChecklist.key] = after[TeamChecklist.key]
        guard AuthoredValueComparison.exactJSON(.object(expected), .object(after)) else { throw Self.invalid }
        return ChildTaskCompletionReceipt(raw: raw)
    }
    private enum CodingKeys: String, CodingKey { case account, origin, body, original }
    init(from decoder: Decoder) throws {
        try completionKeys(decoder, ["account", "origin", "body", "original"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), body: c.decode([String: JSON].self, forKey: .body), original: c.decodeIfPresent(Original.self, forKey: .original))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(account, forKey: .account); try c.encode(origin, forKey: .origin); try c.encode(body, forKey: .body); try c.encode(original, forKey: .original)
    }
}
struct ChildTaskCompletionReceipt: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let raw: [String: JSON]
    init(raw: [String: JSON]) { self.raw = raw }
    private enum CodingKeys: String, CodingKey { case raw }
    init(from decoder: Decoder) throws {
        try completionKeys(decoder, ["raw"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        raw = try c.decode([String: JSON].self, forKey: .raw)
    }
    var description: String { "Private child completion confirmation" }
    var debugDescription: String { description }
    func agrees(_ other: Self) -> Bool { AuthoredValueComparison.exactJSON(.object(raw.filter { $0.key != "replayed" }), .object(other.raw.filter { $0.key != "replayed" })) }
}

/// A terminal service decision for the exact saved request. This metadata
/// never changes tasks; durable closure is required before a fresh replacement.
struct ChildTaskCompletionResolution: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let raw: [String: JSON]
    var receipt: ChildTaskCompletionReceipt? { if case .object(let proof)? = raw["receipt"] { return .init(raw: proof) }; return nil }
    var closed: Bool { raw["outcome"] == .string("closed") && raw["receipt"] == .null }
    var description: String { "Private child completion decision" }
    var debugDescription: String { description }
    init(command: ChildTaskCompletionCommand, raw: [String: JSON]) throws {
        let keys = ChildTaskCompletionCommand.identity + ["request_id", "action"]
        guard Set(raw.keys) == Set(keys + ["undo_of", "outcome", "receipt"]),
              keys.allSatisfy({ AuthoredValueComparison.exactJSON(raw[$0] ?? .null, command.body[$0] ?? .null) }),
              AuthoredValueComparison.exactJSON(raw["undo_of"] ?? .null, command.body["undo_of"] ?? .null) else { throw ChildTaskCompletionDraft.invalid }
        switch raw["outcome"] {
        case .string("closed"): guard raw["receipt"] == .null else { throw ChildTaskCompletionDraft.invalid }
        case .string("applied"):
            guard case .object(let proof)? = raw["receipt"] else { throw ChildTaskCompletionDraft.invalid }
            _ = try command.confirmed(proof)
        default: throw ChildTaskCompletionDraft.invalid
        }
        self.raw = raw
    }
    init(command: ChildTaskCompletionCommand, receipt: ChildTaskCompletionReceipt) throws {
        var raw = command.body.filter { !["baseline", "revision"].contains($0.key) }
        raw["undo_of"] = command.body["undo_of"] ?? .null; raw["outcome"] = .string("applied"); raw["receipt"] = .object(receipt.raw)
        try self.init(command: command, raw: raw)
    }
    private enum CodingKeys: String, CodingKey { case raw }
    init(from decoder: Decoder) throws {
        // The owning journal always revalidates this decoded proof against its
        // command; decoding alone is not authority for a replacement.
        try completionKeys(decoder, ["raw"])
        let c = try decoder.container(keyedBy: CodingKeys.self); raw = try c.decode([String: JSON].self, forKey: .raw)
    }
}

struct ChildTaskCompletionJournalState: ReviewedTeamFileCommand, CustomStringConvertible, CustomDebugStringConvertible {
    enum Phase: String, Codable, Sendable { case queued, attempted, confirmed, closed }
    struct Entry: Codable, Equatable, Sendable {
        let command: ChildTaskCompletionCommand
        var phase: Phase
        var receipt: ChildTaskCompletionReceipt?
        var resolution: ChildTaskCompletionResolution?
        init(command: ChildTaskCompletionCommand, phase: Phase, receipt: ChildTaskCompletionReceipt?, resolution: ChildTaskCompletionResolution? = nil) { self.command = command; self.phase = phase; self.receipt = receipt; self.resolution = resolution }
        private enum CodingKeys: String, CodingKey { case command, phase, receipt, resolution }
        init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: ChildCompletionKey.self)
            let names = Set(keys.allKeys.map(\.stringValue))
            guard names == ["command", "phase", "receipt"] || names == ["command", "phase", "receipt", "resolution"] else { throw ChildTaskCompletionDraft.invalid }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            command = try c.decode(ChildTaskCompletionCommand.self, forKey: .command); phase = try c.decode(Phase.self, forKey: .phase)
            receipt = try c.decodeIfPresent(ChildTaskCompletionReceipt.self, forKey: .receipt)
            resolution = try c.decodeIfPresent(ChildTaskCompletionResolution.self, forKey: .resolution)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(command, forKey: .command); try c.encode(phase, forKey: .phase); try c.encode(receipt, forKey: .receipt); try c.encode(resolution, forKey: .resolution)
        }
    }
    static let storagePrefix = "child-completion-journal-v1."
    static let fileName = "requests.taskfoldchildcompletions"
    static let encryptionContext = "com.taskfold.child-completion-journal.v1"
    static let maximumStoredBytes = 2_100_000
    static let maximumEntries = 64
    static var invalid: AppFailure { ChildTaskCompletionDraft.invalid }
    let account: String, origin: String
    var entries: [Entry]
    var description: String { "Private child completion journal" }
    var debugDescription: String { description }
    init(account: String, origin: String, entries: [Entry] = []) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard origin.utf8.count <= 2048, entries.count <= Self.maximumEntries else { throw Self.invalid }
        var ids: Set<String> = []
        for entry in entries {
            let command = entry.command
            guard command.account == account, command.origin == origin, ids.insert(command.id).inserted else { throw Self.invalid }
            if entry.phase == .confirmed { guard let proof = entry.receipt, try command.confirmed(proof.raw) == proof, entry.resolution == nil else { throw Self.invalid } }
            else if entry.phase == .closed { guard entry.receipt == nil, let decision = entry.resolution, try ChildTaskCompletionResolution(command: command, raw: decision.raw) == decision, decision.closed else { throw Self.invalid } }
            else { guard entry.receipt == nil, entry.resolution == nil else { throw Self.invalid } }
        }
        var undoSources: Set<String> = []
        for entry in entries {
            if let source = entry.command.original {
                guard let parent = entries.first(where: { $0.command.id == source.body["request_id"]?.text }), parent.phase == .confirmed,
                      parent.command.original == nil, parent.command.body == source.body,
                      let receipt = parent.receipt, receipt.agrees(ChildTaskCompletionReceipt(raw: source.receipt)) else { throw Self.invalid }
                if entry.phase != .closed { guard undoSources.insert(parent.command.id).inserted else { throw Self.invalid } }
            }
        }
        self.account = account; self.origin = origin; self.entries = entries
    }
    /// Keep uncertainty and review work intact. A confirmed original and all
    /// its Undo records form one retention unit, so pruning cannot orphan proof.
    /// Array order tracks acknowledgement recency without persisting a clock.
    mutating func makeRoom(preserving request: String?) throws {
        func fits() throws -> Bool {
            try entries.count <= Self.maximumEntries && TaskfoldJSONEncoder().encode(self).count <= Self.maximumStoredBytes
        }
        guard try !fits() else { return }
        func group(_ entry: Entry) -> String { entry.command.original?.body["request_id"]?.text ?? entry.command.id }
        var groups: [String: [Int]] = [:]
        for (index, entry) in entries.enumerated() { groups[group(entry), default: []].append(index) }
        let eligible = groups.filter { _, indices in
            indices.allSatisfy { entries[$0].phase == .confirmed && entries[$0].command.id != request }
        }.sorted { $0.value.last! < $1.value.last! }.map(\.key)
        for id in eligible {
            entries.removeAll { group($0) == id }
            if try fits() { return }
        }
        throw ChildTaskCompletionCapacityFailure()
    }
    private enum CodingKeys: String, CodingKey { case version, account, origin, entries }
    init(from decoder: Decoder) throws {
        try completionKeys(decoder, ["version", "account", "origin", "entries"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == 1 else { throw Self.invalid }
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), entries: c.decode([Entry].self, forKey: .entries))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .version); try c.encode(account, forKey: .account); try c.encode(origin, forKey: .origin); try c.encode(entries, forKey: .entries)
    }
}
struct ChildTaskCompletionJournalFileIO: CalendarSecureItemIO {
    let base: ReviewedTeamCommandFileIO<ChildTaskCompletionJournalState>
    init(directory: URL, account: String, origin: String, encryptionKey: @escaping @Sendable () throws -> SymmetricKey) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        base = .init(directory: directory.appendingPathComponent(account).appendingPathComponent(CalendarOAuthConfiguration.digest(origin)), account: account, origin: origin, encryptionKey: encryptionKey)
    }
    var file: URL { base.file }
    func read(key: String) throws -> Data? { try base.read(key: key) }
    func write(_ data: Data, key: String) throws { try base.write(data, key: key) }
    func remove(key: String) throws { try base.remove(key: key) }
}
actor ChildTaskCompletionJournal {
    private let admit: @Sendable (Set<String>) throws -> Void
    private let io: any CalendarSecureItemIO
    private let lock: AutomationEnrollmentProcessLock
    private let removalDirectory: URL
    let account: String, origin: String
    private var key: String { ChildTaskCompletionJournalState.storagePrefix + account + "." + CalendarOAuthConfiguration.digest(origin) }
    init(account: String, origin: String, io: any CalendarSecureItemIO, coordinationDirectory: URL, removalDirectory: URL, admit: @escaping @Sendable (Set<String>) throws -> Void = { _ in }) throws {
        self.admit = admit;
        try TeamOrganizationValue.scope(account: account, origin: origin)
        self.account = account; self.origin = origin; self.io = io; lock = .init(directory: coordinationDirectory); self.removalDirectory = removalDirectory
    }
    private func guarded<T>(lease: CalendarReadLease?, _ action: () throws -> T) throws -> T {
        try lock.withExclusive(account: account, check: { try lease?.check() }) {
            try AccountRemovalDisk(directory: removalDirectory, account: account).writable { try lease?.check(); return try action() }
        }
    }
    private func read() throws -> ChildTaskCompletionJournalState {
        guard let data = try io.read(key: key) else { return try .init(account: account, origin: origin) }
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: ChildTaskCompletionJournalState.maximumStoredBytes)
        let state = try TaskfoldJSONDecoder().decode(ChildTaskCompletionJournalState.self, from: data)
        guard state.account == account, state.origin == origin else { throw ChildTaskCompletionDraft.invalid }; return state
    }
    private func write(_ candidate: ChildTaskCompletionJournalState, lease: CalendarReadLease, preserving request: String? = nil) throws {
        var state = candidate
        try state.makeRoom(preserving: request)
        _ = try ChildTaskCompletionJournalState(account: account, origin: origin, entries: state.entries)
        let data = try TaskfoldJSONEncoder().encode(state)
        guard data.count <= ChildTaskCompletionJournalState.maximumStoredBytes else { throw ChildTaskCompletionDraft.invalid }
        try lease.check(); try io.write(data, key: key)
    }
    func load() throws -> ChildTaskCompletionJournalState { try guarded(lease: nil) { try read() } }
    /// Never coalesce completion transitions, including provably unsent ones.
    func enqueue(_ command: ChildTaskCompletionCommand, lease: CalendarReadLease) throws {
        try guarded(lease: lease) {
            try admit([command.body["task_id"]!.text])
            guard command.account == account, command.origin == origin else { throw ChildTaskCompletionDraft.invalid }
            var state = try read()
            if let old = state.entries.first(where: { $0.command.id == command.id }) {
                guard old.command == command else { throw ChildTaskCompletionDraft.invalid }
                guard old.phase != .closed else { throw ChildTaskCompletionFailure(reason: .closed) }; return
            }
            state.entries.append(.init(command: command, phase: .queued, receipt: nil)); try write(state, lease: lease)
        }
    }
    func attempt(_ command: ChildTaskCompletionCommand, lease: CalendarReadLease) throws -> ChildTaskCompletionJournalState.Entry {
        try guarded(lease: lease) {
            try admit([command.body["task_id"]!.text])
            var state = try read()
            guard let i = state.entries.firstIndex(where: { $0.command == command }),
                  !state.entries[..<i].contains(where: { $0.phase != .confirmed && $0.phase != .closed && $0.command.sameTarget(command) }) else { throw ChildTaskCompletionDraft.invalid }
            guard state.entries[i].phase != .closed else { throw ChildTaskCompletionFailure(reason: .closed) }
            if state.entries[i].phase == .queued { state.entries[i].phase = .attempted; try write(state, lease: lease) }
            return state.entries[i]
        }
    }
    func confirm(_ command: ChildTaskCompletionCommand, receipt: ChildTaskCompletionReceipt, lease: CalendarReadLease) throws {
        try guarded(lease: lease) {
            _ = try command.confirmed(receipt.raw)
            var state = try read()
            guard let i = state.entries.firstIndex(where: { $0.command == command }), state.entries[i].phase != .queued, state.entries[i].phase != .closed else { throw ChildTaskCompletionDraft.invalid }
            if let old = state.entries[i].receipt { guard old.agrees(receipt) else { throw ChildTaskCompletionDraft.invalid }; return }
            var entry = state.entries.remove(at: i); entry.phase = .confirmed; entry.receipt = receipt
            state.entries.append(entry); try write(state, lease: lease, preserving: command.id)
        }
    }
    /// Resolution never sends task changes, so it may settle a later queued
    /// identity independently of an earlier unsettled request for that child.
    func beginResolution(_ command: ChildTaskCompletionCommand, lease: CalendarReadLease) throws -> ChildTaskCompletionJournalState.Entry {
        try guarded(lease: lease) {
            var state = try read()
            guard let i = state.entries.firstIndex(where: { $0.command == command }) else { throw ChildTaskCompletionDraft.invalid }
            if state.entries[i].phase == .queued { state.entries[i].phase = .attempted; try write(state, lease: lease) }
            return state.entries[i]
        }
    }
    func resolve(_ command: ChildTaskCompletionCommand, decision: ChildTaskCompletionResolution, lease: CalendarReadLease) throws {
        try guarded(lease: lease) {
            _ = try ChildTaskCompletionResolution(command: command, raw: decision.raw)
            var state = try read()
            guard let i = state.entries.firstIndex(where: { $0.command == command }) else { throw ChildTaskCompletionDraft.invalid }
            if state.entries[i].phase == .closed { guard state.entries[i].resolution == decision else { throw ChildTaskCompletionDraft.invalid }; return }
            if let old = state.entries[i].receipt { guard let proof = decision.receipt, old.agrees(proof) else { throw ChildTaskCompletionDraft.invalid }; return }
            if let proof = decision.receipt {
                var entry = state.entries.remove(at: i); entry.phase = .confirmed; entry.receipt = proof
                state.entries.append(entry)
            } else {
                state.entries[i].phase = .closed; state.entries[i].resolution = decision
            }
            try write(state, lease: lease, preserving: command.id)
        }
    }
    func replaceClosed(_ original: ChildTaskCompletionCommand, with replacement: ChildTaskCompletionCommand, lease: CalendarReadLease) throws {
        try guarded(lease: lease) {
            try admit([replacement.body["task_id"]!.text])
            var state = try read()
            guard let entry = state.entries.first(where: { $0.command == original }), entry.phase == .closed, entry.resolution?.closed == true,
                  original.sameTarget(replacement), replacement.id != original.id, replacement.body["action"] == original.body["action"],
                  replacement.body["revision"]!.integer >= original.body["revision"]!.integer,
                  !state.entries.contains(where: { $0.command.id == replacement.id || ($0.phase != .closed && $0.phase != .confirmed && $0.command.sameTarget(replacement)) }) else { throw ChildTaskCompletionDraft.invalid }
            if let source = original.original {
                guard let target = replacement.original, source.body == target.body,
                      ChildTaskCompletionReceipt(raw: source.receipt).agrees(ChildTaskCompletionReceipt(raw: target.receipt)) else { throw ChildTaskCompletionDraft.invalid }
            } else { guard replacement.original == nil else { throw ChildTaskCompletionDraft.invalid } }
            state.entries.append(.init(command: replacement, phase: .queued, receipt: nil)); try write(state, lease: lease)
        }
    }
    /// Forgetting attempted work needs a server terminal decision, not deletion.
    func discard(_ command: ChildTaskCompletionCommand, lease: CalendarReadLease) throws {
        try guarded(lease: lease) {
            var state = try read()
            guard let i = state.entries.firstIndex(where: { $0.command == command }), state.entries[i].phase != .attempted,
                  !state.entries.contains(where: { $0.command.body["undo_of"] == .string(command.id) }) else { throw ChildTaskCompletionDraft.invalid }
            state.entries.remove(at: i); try write(state, lease: lease)
        }
    }
    func removeAccount() throws { try lock.withExclusive(account: account) { try io.remove(key: key) } }
}
struct ChildTaskCompletionCapacityFailure: LocalizedError {
    var errorDescription: String? { "Review saved subtask actions before adding another. Pending and stopped actions are kept until you review them." }
}
struct ChildTaskCompletionFailure: LocalizedError {
    let reason: ChildTaskFieldWriteFailure.Reason
    var errorDescription: String? {
        switch reason {
        case .unavailable: return "Completion is unavailable or access changed. Your saved request is kept."
        case .review: return "This completion needs review. Your original saved request is kept."
        case .closed: return "This original completion request is closed. Review current values before saving another action."
        case .busy: return "Another action is finishing. Retry the same saved completion shortly."
        case .limit: return "Completion has reached a service limit. Your saved request is kept."
        case .unconfirmed: return "The completion result couldn’t be confirmed. Your original saved request is kept."
        }
    }
}
@MainActor protocol ChildTaskCompletionCommandService: AnyObject {
    func childTaskCompletionCommand(_ command: ChildTaskCompletionCommand, session: UUID) async throws -> ChildTaskCompletionReceipt
    func closeChildTaskCompletionCommand(_ command: ChildTaskCompletionCommand, session: UUID) async throws -> ChildTaskCompletionResolution
}
extension ChildTaskCompletionCommandService {
    func closeChildTaskCompletionCommand(_ command: ChildTaskCompletionCommand, session: UUID) async throws -> ChildTaskCompletionResolution { throw ChildTaskCompletionFailure(reason: .unavailable) }
}
extension Backend: ChildTaskCompletionCommandService {}
@MainActor final class ChildTaskCompletionSender {
    private let scope: ChildTaskFieldClientScope
    private let current: () -> ChildTaskFieldClientScope?
    private let canSend: (ChildTaskCompletionCommand) -> Bool
    private let journal: ChildTaskCompletionJournal
    private let service: any ChildTaskCompletionCommandService
    private let lease = CalendarReadLease()
    private var closed = false
    init(scope: ChildTaskFieldClientScope, journal: ChildTaskCompletionJournal, service: any ChildTaskCompletionCommandService,
         current: @escaping () -> ChildTaskFieldClientScope?, canSend: @escaping (ChildTaskCompletionCommand) -> Bool) {
        self.scope = scope; self.journal = journal; self.service = service; self.current = current; self.canSend = canSend
    }
    func close() { closed = true; lease.cancel() }
    private func check() throws { try lease.check(); guard !closed, current() == scope else { throw CancellationError() } }
    func resolve(_ command: ChildTaskCompletionCommand) async throws -> ChildTaskCompletionResolution {
        do {
            try check(); guard command.account == scope.account, command.origin == scope.origin else { throw CancellationError() }
            let entry = try await journal.beginResolution(command, lease: lease); try check()
            if let proof = entry.resolution { return try .init(command: command, raw: proof.raw) }
            if let receipt = entry.receipt { return try .init(command: command, receipt: receipt) }
            let decision: ChildTaskCompletionResolution
            do { decision = try await service.closeChildTaskCompletionCommand(command, session: scope.session) }
            catch is CancellationError { throw CancellationError() }
            catch let failure as ChildTaskCompletionFailure { throw failure }
            catch let required as AccountSessionAuthorizationRequired { throw required }
            catch { throw ChildTaskCompletionFailure(reason: .unconfirmed) }
            try check(); guard (try? ChildTaskCompletionResolution(command: command, raw: decision.raw)) == decision else { throw ChildTaskCompletionFailure(reason: .unconfirmed) }
            try await journal.resolve(command, decision: decision, lease: lease); try check(); return decision
        } catch { try check(); throw error }
    }
    func send(_ command: ChildTaskCompletionCommand) async throws -> ChildTaskCompletionReceipt {
        do {
            try check(); guard command.account == scope.account, command.origin == scope.origin else { throw CancellationError() }
            let state = try await journal.load(); try check()
            guard let entry = state.entries.first(where: { $0.command == command }) else { throw ChildTaskCompletionDraft.invalid }
            guard entry.phase != .closed else { throw ChildTaskCompletionFailure(reason: .closed) }
            if let receipt = entry.receipt { return try command.confirmed(receipt.raw) }
            guard canSend(command) else { throw ChildTaskCompletionFailure(reason: .unavailable) }
            _ = try await journal.attempt(command, lease: lease); try check()
            guard canSend(command) else { throw ChildTaskCompletionFailure(reason: .unavailable) }
            let receipt: ChildTaskCompletionReceipt
            do { receipt = try await service.childTaskCompletionCommand(command, session: scope.session) }
            catch is CancellationError { throw CancellationError() }
            catch let failure as ChildTaskCompletionFailure { throw failure }
            catch let required as AccountSessionAuthorizationRequired { throw required }
            catch { throw ChildTaskCompletionFailure(reason: .unconfirmed) }
            try check()
            guard (try? command.confirmed(receipt.raw)) == receipt else { throw ChildTaskCompletionFailure(reason: .unconfirmed) }
            try await journal.confirm(command, receipt: receipt, lease: lease); try check(); return receipt
        } catch { try check(); throw error }
    }
}

/// Owns one live presentation, while immutable intents/proofs survive it on disk.
/// Task data is refreshed from the service after confirmation, never patched
/// from a historical receipt or from the desired completion state.
@MainActor @Observable final class ChildTaskCompletionRecoveryModel {
    private(set) var entries: [ChildTaskCompletionJournalState.Entry] = []
    private(set) var loaded = false
    private(set) var busy = false
    private(set) var message: String?
    private let scope: ChildTaskFieldClientScope
    private let journal: ChildTaskCompletionJournal
    private let sender: ChildTaskCompletionSender
    private let current: () -> ChildTaskFieldClientScope?
    private let canQueue: (ChildTaskCompletionCommand) -> Bool
    private let canSend: (ChildTaskCompletionCommand) -> Bool
    private let refresh: () async -> Void
    private let lease = CalendarReadLease()
    private var closed = false
    init(scope: ChildTaskFieldClientScope, journal: ChildTaskCompletionJournal, service: any ChildTaskCompletionCommandService,
         current: @escaping () -> ChildTaskFieldClientScope?, canQueue: @escaping (ChildTaskCompletionCommand) -> Bool,
         canSend: @escaping (ChildTaskCompletionCommand) -> Bool, refresh: @escaping () async -> Void) {
        self.scope = scope; self.journal = journal; self.current = current; self.canQueue = canQueue; self.canSend = canSend; self.refresh = refresh
        sender = .init(scope: scope, journal: journal, service: service, current: current, canSend: canSend)
    }
    func close() { closed = true; lease.cancel(); sender.close(); entries = []; message = nil; loaded = false; busy = false }
    private func check() throws { try lease.check(); guard !closed, current() == scope else { throw CancellationError() } }
    private func update() async throws { let state = try await journal.load(); try check(); entries = state.entries; loaded = true }
    private func failure(_ error: Error) {
        guard (try? check()) != nil else { close(); return }
        if error is CancellationError { return }
        if error is ChildTaskActionAdmissionFailure { message = ChildTaskActionAdmissionFailure().localizedDescription }
        else if let value = error as? ChildTaskCompletionCapacityFailure { message = value.localizedDescription }
        else if let value = error as? ChildTaskCompletionFailure { message = value.localizedDescription }
        else if error is AccountSessionAuthorizationRequired { message = "Sign in again to check this saved action. Your work is kept." }
        else { message = "This action couldn’t be confirmed. Your saved work is kept; review it before trying again." }
    }
    private func recover(_ error: Error) async {
        do { try check(); try await update() } catch { entries = []; loaded = false }
        failure(error)
    }
    func load() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try check(); try await update() } catch { failure(error) }
    }
    @discardableResult func perform(read: ChildTaskRecordRead, key: String, action: ChildTaskCompletionDraft.Action) async -> ChildTaskCompletionCommand? {
        guard !busy else { return nil }; busy = true; defer { busy = false }
        do {
            try check(); guard ChildTaskFieldClientScope(read.context) == scope else { throw CancellationError() }
            let command = try ChildTaskCompletionCommand(ChildTaskCompletionDraft(read: read, key: key, action: action))
            guard canQueue(command) else { throw ChildTaskCompletionFailure(reason: .unavailable) }
            try await journal.enqueue(command, lease: lease); try check(); try await update()
            if canSend(command) { try await sendSaved(command) }
            else { message = "Saved for later. Open Saved subtask actions when you’re ready to send it." }
            return command
        } catch { await recover(error); return nil }
    }
    private func sendSaved(_ command: ChildTaskCompletionCommand) async throws {
        _ = try await sender.send(command); try check(); try await update()
        await refresh(); try check()
        message = command.isUndo ? "Undo confirmed." : command.body["action"] == .string("complete") ? "Completion confirmed." : "Reopened."
    }
    func send(_ command: ChildTaskCompletionCommand) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try check(); try await sendSaved(command) } catch { await recover(error) }
    }
    func undo(_ entry: ChildTaskCompletionJournalState.Entry, read: ChildTaskRecordRead) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try check(); guard ChildTaskFieldClientScope(read.context) == scope, entry.phase == .confirmed,
                  entries.contains(entry), let receipt = entry.receipt else { throw ChildTaskCompletionDraft.invalid }
            let command = try ChildTaskCompletionCommand(undo: entry.command, receipt: receipt, read: read)
            guard canQueue(command) else { throw ChildTaskCompletionFailure(reason: .unavailable) }
            try await journal.enqueue(command, lease: lease); try check(); try await update()
            if canSend(command) { try await sendSaved(command) } else { message = "Undo saved for later. The task has not changed yet." }
        } catch { await recover(error) }
    }
    func resolve(_ command: ChildTaskCompletionCommand) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try check(); let result = try await sender.resolve(command); try check(); try await update()
            if result.closed { message = "The earlier action was stopped before applying. Review the current task before trying again." }
            else { await refresh(); try check(); message = "The earlier action had already applied. Its confirmation is saved." }
        } catch { await recover(error) }
    }
    @discardableResult func replace(_ entry: ChildTaskCompletionJournalState.Entry, read: ChildTaskRecordRead) async -> ChildTaskCompletionCommand? {
        guard !busy else { return nil }; busy = true; defer { busy = false }
        do {
            try check(); guard ChildTaskFieldClientScope(read.context) == scope, entry.phase == .closed, entries.contains(entry) else { throw ChildTaskCompletionDraft.invalid }
            let command: ChildTaskCompletionCommand
            if let source = entry.command.original {
                let original = try ChildTaskCompletionCommand(account: entry.command.account, origin: entry.command.origin, body: source.body)
                command = try .init(undo: original, receipt: original.confirmed(source.receipt), read: read)
            } else {
                guard let action = ChildTaskCompletionDraft.Action(rawValue: entry.command.body["action"]!.text) else { throw ChildTaskCompletionDraft.invalid }
                command = try .init(ChildTaskCompletionDraft(read: read, key: entry.command.body["node_key"]!.text, action: action))
            }
            guard canQueue(command) else { throw ChildTaskCompletionFailure(reason: .unavailable) }
            try await journal.replaceClosed(entry.command, with: command, lease: lease); try check(); try await update()
            message = "Fresh action saved. Review it before sending."; return command
        } catch { await recover(error); return nil }
    }
    func discard(_ command: ChildTaskCompletionCommand) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try check(); try await journal.discard(command, lease: lease); try check(); try await update(); message = "Saved action removed from this device. This does not undo a task change." }
        catch { await recover(error) }
    }
}

/// A list click must retain its workspace, full path and observed completion
/// cohort while the fresh independent read is in flight.
struct ChildTaskListCompletionIntent: Equatable, Sendable {
    let opening: ChildTaskFieldOpening
    let scope: ChildTaskFieldClientScope
    let title: String
    let baseline: [String: JSON]
    let completed: Bool
    init(task: Record, root: Record, projects: [Record], scope: ChildTaskFieldClientScope) throws {
        let binding = WorkspaceBinding(account: scope.account, generation: scope.workspace)
        opening = try ChildTaskFieldOpening(reference: task.id, root: root, workspace: binding)
        let index = try TaskHierarchyIndex(roots: [root], projects: projects, workspace: binding)
        guard let item = index.item(task.id), item.isSubtask,
              ["project_id", "user_id", "task_generation"].allSatisfy({ AuthoredValueComparison.exactJSON(task[$0], item.record[$0]) }),
              AuthoredValueComparison.exactJSON(.object(item.record.fields.filter { ChildTaskCompletionDraft.cohort.contains($0.key) }),
                                               .object(task.fields.filter { ChildTaskCompletionDraft.cohort.contains($0.key) })) else { throw ChildTaskCompletionDraft.invalid }
        baseline = item.source.fields.filter { ChildTaskCompletionDraft.cohort.contains($0.key) }
        completed = try ChildTaskCompletionDraft.completed(baseline)
        self.scope = scope; title = item.source.title
    }
    func key(in read: ChildTaskRecordRead) throws -> String {
        guard scope == ChildTaskFieldClientScope(read.context) else { throw CancellationError() }
        let key = try opening.key(in: read)
        guard let node = read.nodes[key],
              AuthoredValueComparison.exactJSON(.object(node.fields.filter { ChildTaskCompletionDraft.cohort.contains($0.key) }), .object(baseline)),
              baseline[TeamChecklist.key] != nil || AuthoredValueComparison.exactJSON(opening.root["subtasks"], read.context.root["subtasks"]) else { throw ChildTaskCompletionDraft.invalid }
        return key
    }
}
struct ChildTaskListCompletionUndo: Equatable, Sendable {
    let scope: ChildTaskFieldClientScope
    let command: ChildTaskCompletionCommand
    let title: String
}
struct ChildTaskListCompletionResult {
    let message: String
    let undo: ChildTaskListCompletionUndo?
    var needsReview = false
}

/// Only retry a read cancelled by an in-place snapshot refresh. The original
/// intent still validates the returned identity/cohort before any command exists.
enum ChildTaskListRead {
    @MainActor static func fresh(scope: ChildTaskFieldClientScope, current: () -> ChildTaskFieldClientScope?, operation: () async throws -> ChildTaskRecordRead) async throws -> ChildTaskRecordRead {
        for attempt in 0...1 {
            try Task.checkCancellation()
            guard current() == scope else { throw CancellationError() }
            do {
                let read = try await operation()
                try Task.checkCancellation()
                guard current() == scope else { throw CancellationError() }
                return read
            } catch is CancellationError {
                try Task.checkCancellation()
                guard attempt == 0, current() == scope else { throw CancellationError() }
            }
        }
        throw CancellationError()
    }
}

/// One atomic selection; its group identity is separate from the original,
/// individually reserved item request identities. No parent tree is sent.
struct ChildTaskCompletionBatchCommand: ReviewedTeamCommand, CustomStringConvertible, CustomDebugStringConvertible {
    static let storagePrefix = "child-completion-batch-v1."
    static let maximumStoredBytes = 524_288
    static let maximumResponseBytes = 524_288
    static var invalid: AppFailure { AppFailure(message: "Review this subtask selection again. Your saved work is unchanged.") }
    let account: String, origin: String, batchID: String
    let items: [ChildTaskCompletionCommand]
    var id: String { batchID }
    var body: [String: JSON] { ["protocol": .number(1), "account": .string(account), "batch_id": .string(batchID), "items": .array(items.map { .object($0.body) })] }
    var description: String { "Private subtask selection request" }
    var debugDescription: String { description }
    init(account: String, origin: String, items: [ChildTaskCompletionCommand], batchID: UUID = UUID()) throws {
        try self.init(account: account, origin: origin, items: items, storedID: batchID.uuidString.lowercased())
    }
    private init(account: String, origin: String, items: [ChildTaskCompletionCommand], storedID: String) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard origin.utf8.count <= 2048, (1...32).contains(items.count), let id = UUID(uuidString: storedID), storedID == id.uuidString.lowercased() else { throw Self.invalid }
        var requests = Set<UUID>(), targets = Set<Data>()
        let action = items[0].body["action"]
        for item in items {
            guard item.account == account, item.origin.utf8.elementsEqual(origin.utf8), item.body["action"] == action,
                  let request = UUID(uuidString: item.id), request != id, requests.insert(request).inserted,
                  let task = UUID(uuidString: item.body["task_id"]!.text) else { throw Self.invalid }
            let target = try TaskfoldJSONEncoder().encode([task.uuidString.lowercased(), item.body["node_key"]!.text])
            guard targets.insert(target).inserted else { throw Self.invalid }
        }
        self.account = account; self.origin = origin; self.items = items; batchID = storedID
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard try encoder.encode(body).count <= 131_072, try TaskfoldJSONEncoder().encode(self).count <= 500_000 else { throw Self.invalid }
    }
    private enum CodingKeys: String, CodingKey { case account, origin, batchID, items }
    init(from decoder: Decoder) throws {
        try completionKeys(decoder, ["account", "origin", "batchID", "items"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), items: c.decode([ChildTaskCompletionCommand].self, forKey: .items), storedID: c.decode(String.self, forKey: .batchID))
    }
    func resolution(_ raw: [String: JSON]) throws -> ChildTaskCompletionBatchResolution {
        try .init(command: self, raw: raw)
    }
}
struct ChildTaskCompletionBatchResolution: Equatable, Sendable {
    let raw: [String: JSON]
    let receipts: [ChildTaskCompletionReceipt]
    var applied: Bool { raw["outcome"] == .string("applied") }
    var closed: Bool { raw["outcome"] == .string("closed") }
    init(command: ChildTaskCompletionBatchCommand, raw: [String: JSON]) throws {
        guard Set(raw.keys) == ["protocol", "account", "batch_id", "outcome", "receipts", "replayed"],
              raw["protocol"] == .number(1), raw["account"] == .string(command.account), raw["batch_id"] == .string(command.id),
              case .bool? = raw["replayed"], case .array(let values)? = raw["receipts"] else { throw ChildTaskCompletionBatchCommand.invalid }
        switch raw["outcome"] {
        case .string("closed"):
            guard values.isEmpty else { throw ChildTaskCompletionBatchCommand.invalid }; receipts = []
        case .string("applied"):
            guard values.count == command.items.count else { throw ChildTaskCompletionBatchCommand.invalid }
            receipts = try zip(command.items, values).map { item, value in
                guard case .object(let proof) = value else { throw ChildTaskCompletionBatchCommand.invalid }
                return try item.confirmed(proof)
            }
        default: throw ChildTaskCompletionBatchCommand.invalid
        }
        self.raw = raw
    }
}
typealias ChildTaskCompletionBatchVault = ReviewedTeamCommandVault<ChildTaskCompletionBatchCommand>

extension ChildTaskCompletionBatchCommand {
    var isUndo: Bool { items[0].isUndo }
    func overlaps(_ other: Self) -> Bool {
        account == other.account && origin == other.origin && items.contains { left in
            other.items.contains { right in
                AuthoredValueComparison.exactJSON(left.body["task_id"]!, right.body["task_id"]!) &&
                AuthoredValueComparison.exactJSON(left.body["node_key"]!, right.body["node_key"]!)
            }
        }
    }
    func undo(reads: [String: ChildTaskRecordRead], decision: ChildTaskCompletionBatchResolution) throws -> Self {
        let proof = try resolution(decision.raw)
        guard !isUndo, proof.applied else { throw Self.invalid }
        let selectedReads = try items.map { item -> ChildTaskRecordRead in
            guard let read = reads[item.body["task_id"]!.text] else { throw Self.invalid }; return read
        }
        guard Set(selectedReads.map { ChildTaskFieldClientScope($0.context) }).count == 1 else { throw Self.invalid }
        let inverses = try zip(items, proof.receipts).map { item, receipt in
            guard let read = reads[item.body["task_id"]!.text] else { throw Self.invalid }
            return try ChildTaskCompletionCommand(undo: item, receipt: receipt, read: read)
        }
        return try .init(account: account, origin: origin, items: inverses)
    }
}
extension ChildTaskCompletionBatchResolution {
    func agrees(_ other: Self) -> Bool {
        guard applied == other.applied, closed == other.closed, receipts.count == other.receipts.count else { return false }
        var left = raw, right = other.raw
        left.removeValue(forKey: "replayed"); right.removeValue(forKey: "replayed")
        left.removeValue(forKey: "receipts"); right.removeValue(forKey: "receipts")
        return AuthoredValueComparison.exactJSON(.object(left), .object(right)) && zip(receipts, other.receipts).allSatisfy { $0.agrees($1) }
    }
}

/// One disk entry represents the entire atomic group. A decoded decision is
/// never trusted until the enclosing state validates it against its command.
struct ChildTaskCompletionBatchState: ReviewedTeamFileCommand, CustomStringConvertible, CustomDebugStringConvertible {
    enum Phase: String, Codable, Sendable { case queued, attempted, confirmed, closed }
    struct Entry: Codable, Equatable, Sendable {
        let command: ChildTaskCompletionBatchCommand
        var phase: Phase
        var decision: [String: JSON]?
        var proof: ChildTaskCompletionBatchResolution? { decision.flatMap { try? command.resolution($0) } }
        init(command: ChildTaskCompletionBatchCommand, phase: Phase, decision: [String: JSON]? = nil) {
            self.command = command; self.phase = phase; self.decision = decision
        }
        private enum CodingKeys: String, CodingKey { case command, phase, decision }
        init(from decoder: Decoder) throws {
            try completionKeys(decoder, ["command", "phase", "decision"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            command = try c.decode(ChildTaskCompletionBatchCommand.self, forKey: .command)
            phase = try c.decode(Phase.self, forKey: .phase)
            decision = try c.decodeIfPresent([String: JSON].self, forKey: .decision)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(command, forKey: .command); try c.encode(phase, forKey: .phase); try c.encode(decision, forKey: .decision)
        }
    }
    static let storagePrefix = "child-completion-groups-v1."
    static let fileName = "requests.taskfoldchildcompletiongroups"
    static let encryptionContext = "com.taskfold.child-completion-groups.v1"
    static let maximumStoredBytes = 4_300_000
    static let maximumEntries = 32
    static var invalid: AppFailure { ChildTaskCompletionBatchCommand.invalid }
    let account: String, origin: String
    var entries: [Entry]
    var description: String { "Private subtask selection journal" }
    var debugDescription: String { description }
    init(account: String, origin: String, entries: [Entry] = []) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard origin.utf8.count <= 2048, entries.count <= Self.maximumEntries else { throw Self.invalid }
        var groups = Set<String>(), members = Set<String>(), undoSources = Set<String>()
        for entry in entries {
            guard entry.command.account == account, entry.command.origin == origin, groups.insert(entry.command.id).inserted else { throw Self.invalid }
            for item in entry.command.items { guard members.insert(item.id).inserted else { throw Self.invalid } }
            switch entry.phase {
            case .queued, .attempted: guard entry.decision == nil else { throw Self.invalid }
            case .confirmed: guard entry.proof?.applied == true else { throw Self.invalid }
            case .closed: guard entry.proof?.closed == true else { throw Self.invalid }
            }
        }
        self.account = account; self.origin = origin; self.entries = entries
        for entry in entries where entry.command.isUndo {
            guard let parent = parent(of: entry.command) else { throw Self.invalid }
            if entry.phase != .closed { guard undoSources.insert(parent.command.id).inserted else { throw Self.invalid } }
        }
    }
    func parent(of command: ChildTaskCompletionBatchCommand) -> Entry? {
        guard command.isUndo, let sourceID = command.items[0].original?.body["request_id"]?.text else { return nil }
        return entries.first { entry in
            guard !entry.command.isUndo, entry.command.items.contains(where: { $0.id == sourceID }), entry.phase == .confirmed, let proof = entry.proof,
                  command.items.count == entry.command.items.count else { return false }
            let sources = Dictionary(uniqueKeysWithValues: zip(entry.command.items, proof.receipts).map { ($0.0.id, ($0.0, $0.1)) })
            return command.items.allSatisfy { undo in
                guard let original = undo.original, let source = sources[original.body["request_id"]!.text] else { return false }
                return AuthoredValueComparison.exactJSON(.object(original.body), .object(source.0.body)) &&
                    (try? source.0.confirmed(original.receipt).agrees(source.1)) == true
            }
        }
    }
    mutating func makeRoom(preserving id: String?) throws {
        func fits() throws -> Bool { try entries.count <= Self.maximumEntries && TaskfoldJSONEncoder().encode(self).count <= Self.maximumStoredBytes }
        guard try !fits() else { return }
        var families: [String: [String]] = [:]
        for entry in entries {
            let family = entry.command.isUndo ? parent(of: entry.command)?.command.id : entry.command.id
            guard let family else { throw Self.invalid }
            families[family, default: []].append(entry.command.id)
        }
        let eligible = families.values.filter { ids in
            !ids.contains(id ?? "") && entries.filter { ids.contains($0.command.id) }.allSatisfy { $0.phase == .confirmed }
        }.sorted { left, right in
            entries.lastIndex { left.contains($0.command.id) }! < entries.lastIndex { right.contains($0.command.id) }!
        }
        for family in eligible {
            entries.removeAll { family.contains($0.command.id) }
            if try fits() { return }
        }
        throw ChildTaskCompletionCapacityFailure()
    }
    private enum CodingKeys: String, CodingKey { case version, account, origin, entries }
    init(from decoder: Decoder) throws {
        try completionKeys(decoder, ["version", "account", "origin", "entries"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == 1 else { throw Self.invalid }
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), entries: c.decode([Entry].self, forKey: .entries))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .version); try c.encode(account, forKey: .account); try c.encode(origin, forKey: .origin); try c.encode(entries, forKey: .entries)
    }
}

actor ChildTaskCompletionBatchJournal {
    private let admit: @Sendable (Set<String>) throws -> Void
    let account: String, origin: String
    private let io: any CalendarSecureItemIO
    private let lock: AutomationEnrollmentProcessLock
    private let removalDirectory: URL
    private var key: String { ChildTaskCompletionBatchState.storagePrefix + account + "." + CalendarOAuthConfiguration.digest(origin) }
    init(account: String, origin: String, io: any CalendarSecureItemIO, coordinationDirectory: URL, removalDirectory: URL, admit: @escaping @Sendable (Set<String>) throws -> Void = { _ in }) throws {
        self.admit = admit;
        try TeamOrganizationValue.scope(account: account, origin: origin)
        self.account = account; self.origin = origin; self.io = io; self.lock = .init(directory: coordinationDirectory); self.removalDirectory = removalDirectory
    }
    private func guarded<T>(_ lease: CalendarReadLease?, _ operation: () throws -> T) throws -> T {
        try lock.withExclusive(account: account, check: { try lease?.check() }) {
            try AccountRemovalDisk(directory: removalDirectory, account: account).writable { try lease?.check(); return try operation() }
        }
    }
    private func read() throws -> ChildTaskCompletionBatchState {
        guard let data = try io.read(key: key) else { return try .init(account: account, origin: origin) }
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: ChildTaskCompletionBatchState.maximumStoredBytes)
        let state = try TaskfoldJSONDecoder().decode(ChildTaskCompletionBatchState.self, from: data)
        guard state.account == account, state.origin == origin else { throw ChildTaskCompletionBatchState.invalid }
        return state
    }
    private func write(_ candidate: ChildTaskCompletionBatchState, lease: CalendarReadLease, preserving id: String? = nil) throws {
        var state = candidate; try state.makeRoom(preserving: id)
        _ = try ChildTaskCompletionBatchState(account: account, origin: origin, entries: state.entries)
        let data = try TaskfoldJSONEncoder().encode(state)
        guard data.count <= ChildTaskCompletionBatchState.maximumStoredBytes else { throw ChildTaskCompletionBatchState.invalid }
        try lease.check(); try io.write(data, key: key)
    }
    func load() throws -> ChildTaskCompletionBatchState { try guarded(nil) { try read() } }
    func enqueue(_ command: ChildTaskCompletionBatchCommand, lease: CalendarReadLease) throws {
        try guarded(lease) {
            try admit(Set(command.items.map { $0.body["task_id"]!.text }))
            guard command.account == account, command.origin == origin else { throw ChildTaskCompletionBatchState.invalid }
            var state = try read()
            if let old = state.entries.first(where: { $0.command.id == command.id }) {
                guard old.command == command else { throw ChildTaskCompletionBatchState.invalid }
                guard old.phase != .closed else { throw ChildTaskCompletionFailure(reason: .closed) }; return
            }
            let reserved = Set(state.entries.flatMap { $0.command.items.map(\.id) })
            guard command.items.allSatisfy({ !reserved.contains($0.id) }) else { throw ChildTaskCompletionBatchState.invalid }
            state.entries.append(.init(command: command, phase: .queued)); try write(state, lease: lease)
        }
    }
    func begin(_ command: ChildTaskCompletionBatchCommand, resolving: Bool = false, lease: CalendarReadLease) throws -> ChildTaskCompletionBatchState.Entry {
        try guarded(lease) {
            if !resolving { try admit(Set(command.items.map { $0.body["task_id"]!.text })) }
            var state = try read()
            guard let i = state.entries.firstIndex(where: { $0.command == command }) else { throw ChildTaskCompletionBatchState.invalid }
            if !resolving {
                guard state.entries[i].phase != .closed else { throw ChildTaskCompletionFailure(reason: .closed) }
                guard !state.entries[..<i].contains(where: { ($0.phase == .queued || $0.phase == .attempted) && $0.command.overlaps(command) }) else { throw ChildTaskCompletionBatchState.invalid }
            }
            if state.entries[i].phase == .queued { state.entries[i].phase = .attempted; try write(state, lease: lease) }
            return state.entries[i]
        }
    }
    func settle(_ command: ChildTaskCompletionBatchCommand, decision: ChildTaskCompletionBatchResolution, lease: CalendarReadLease) throws {
        try guarded(lease) {
            _ = try command.resolution(decision.raw)
            var state = try read()
            guard let i = state.entries.firstIndex(where: { $0.command == command }), state.entries[i].phase != .queued else { throw ChildTaskCompletionBatchState.invalid }
            if let old = state.entries[i].proof { guard old.agrees(decision) else { throw ChildTaskCompletionBatchState.invalid }; return }
            if decision.applied {
                var entry = state.entries.remove(at: i); entry.phase = .confirmed; entry.decision = decision.raw; state.entries.append(entry)
            } else { state.entries[i].phase = .closed; state.entries[i].decision = decision.raw }
            try write(state, lease: lease, preserving: command.id)
        }
    }
    func discard(_ command: ChildTaskCompletionBatchCommand, lease: CalendarReadLease) throws {
        try guarded(lease) {
            var state = try read()
            guard let i = state.entries.firstIndex(where: { $0.command == command }), state.entries[i].phase != .attempted,
                  !state.entries.contains(where: { $0.command.isUndo && state.parent(of: $0.command)?.command == command }) else { throw ChildTaskCompletionBatchState.invalid }
            state.entries.remove(at: i); try write(state, lease: lease)
        }
    }
    func replaceClosed(_ command: ChildTaskCompletionBatchCommand, with replacement: ChildTaskCompletionBatchCommand, lease: CalendarReadLease) throws {
        try guarded(lease) {
            try admit(Set(replacement.items.map { $0.body["task_id"]!.text }))
            var state = try read()
            guard state.entries.contains(where: { $0.command == command && $0.phase == .closed }),
                  command.id != replacement.id, command.items.count == replacement.items.count,
                  zip(command.items, replacement.items).allSatisfy({ old, fresh in
                      ChildTaskCompletionCommand.identity.allSatisfy({ AuthoredValueComparison.exactJSON(old.body[$0]!, fresh.body[$0]!) }) && old.body["action"] == fresh.body["action"] &&
                      fresh.body["revision"]!.integer >= old.body["revision"]!.integer &&
                      old.original?.body == fresh.original?.body &&
                      (old.original == nil || ChildTaskCompletionReceipt(raw: old.original!.receipt).agrees(.init(raw: fresh.original!.receipt)))
                  }), !state.entries.contains(where: { $0.command.id == replacement.id || (($0.phase == .queued || $0.phase == .attempted) && $0.command.overlaps(replacement)) }) else { throw ChildTaskCompletionBatchState.invalid }
            let reserved = Set(state.entries.flatMap { $0.command.items.map(\.id) })
            guard replacement.items.allSatisfy({ !reserved.contains($0.id) }) else { throw ChildTaskCompletionBatchState.invalid }
            state.entries.append(.init(command: replacement, phase: .queued)); try write(state, lease: lease)
        }
    }
    func removeAccount() throws { try lock.withExclusive(account: account) { try io.remove(key: key) } }
}

@MainActor protocol ChildTaskCompletionBatchService: AnyObject {
    func childTaskCompletionBatch(_ command: ChildTaskCompletionBatchCommand, session: UUID, close: Bool) async throws -> ChildTaskCompletionBatchResolution
}
extension Backend: ChildTaskCompletionBatchService {}
@MainActor final class ChildTaskCompletionBatchSender {
    private let scope: ChildTaskFieldClientScope
    private let journal: ChildTaskCompletionBatchJournal
    private let service: any ChildTaskCompletionBatchService
    private let current: () -> ChildTaskFieldClientScope?
    private let canSend: (ChildTaskCompletionBatchCommand) -> Bool
    private let lease = CalendarReadLease()
    private var closed = false
    init(scope: ChildTaskFieldClientScope, journal: ChildTaskCompletionBatchJournal, service: any ChildTaskCompletionBatchService,
         current: @escaping () -> ChildTaskFieldClientScope?, canSend: @escaping (ChildTaskCompletionBatchCommand) -> Bool) {
        self.scope = scope; self.journal = journal; self.service = service; self.current = current; self.canSend = canSend
    }
    func close() { closed = true; lease.cancel() }
    private func check() throws { try Task.checkCancellation(); try lease.check(); guard !closed, current() == scope else { throw CancellationError() } }
    func send(_ command: ChildTaskCompletionBatchCommand, resolving: Bool = false) async throws -> ChildTaskCompletionBatchResolution {
        do {
            try check(); guard command.account == scope.account, command.origin == scope.origin else { throw CancellationError() }
            let state = try await journal.load(); try check()
            guard let entry = state.entries.first(where: { $0.command == command }) else { throw ChildTaskCompletionBatchState.invalid }
            if let proof = entry.proof {
                if !resolving && proof.closed { throw ChildTaskCompletionFailure(reason: .closed) }
                return proof
            }
            guard resolving || canSend(command) else { throw ChildTaskCompletionFailure(reason: .unavailable) }
            _ = try await journal.begin(command, resolving: resolving, lease: lease); try check()
            guard resolving || canSend(command) else { throw ChildTaskCompletionFailure(reason: .unavailable) }
            let proof: ChildTaskCompletionBatchResolution
            do { proof = try await service.childTaskCompletionBatch(command, session: scope.session, close: resolving) }
            catch is CancellationError { throw CancellationError() }
            catch let failure as ChildTaskCompletionFailure { throw failure }
            catch let required as AccountSessionAuthorizationRequired { throw required }
            catch { throw ChildTaskCompletionFailure(reason: .unconfirmed) }
            try check()
            guard let checked = try? command.resolution(proof.raw), checked == proof, resolving || proof.applied else { throw ChildTaskCompletionFailure(reason: .unconfirmed) }
            try await journal.settle(command, decision: proof, lease: lease); try check(); return proof
        } catch { try check(); throw error }
    }
}

@MainActor @Observable final class ChildTaskCompletionBatchRecoveryModel {
    private(set) var entries: [ChildTaskCompletionBatchState.Entry] = []
    private(set) var loaded = false
    private(set) var busy = false
    private(set) var message: String?
    private let scope: ChildTaskFieldClientScope
    private let journal: ChildTaskCompletionBatchJournal
    private let sender: ChildTaskCompletionBatchSender
    private let current: () -> ChildTaskFieldClientScope?
    private let canQueue: (ChildTaskCompletionBatchCommand) -> Bool
    private let canSend: (ChildTaskCompletionBatchCommand) -> Bool
    private let refresh: () async -> Void
    private let lease = CalendarReadLease()
    private var closed = false
    init(scope: ChildTaskFieldClientScope, journal: ChildTaskCompletionBatchJournal, service: any ChildTaskCompletionBatchService,
         current: @escaping () -> ChildTaskFieldClientScope?, canQueue: @escaping (ChildTaskCompletionBatchCommand) -> Bool,
         canSend: @escaping (ChildTaskCompletionBatchCommand) -> Bool, refresh: @escaping () async -> Void) {
        self.scope = scope; self.journal = journal; self.current = current; self.canQueue = canQueue; self.canSend = canSend; self.refresh = refresh
        sender = .init(scope: scope, journal: journal, service: service, current: current, canSend: canSend)
    }
    func close() { closed = true; lease.cancel(); sender.close(); entries = []; loaded = false; busy = false; message = nil }
    private func check() throws { try Task.checkCancellation(); try lease.check(); guard !closed, current() == scope else { throw CancellationError() } }
    private func update() async throws { let state = try await journal.load(); try check(); entries = state.entries; loaded = true }
    private func recover(_ error: Error) async {
        guard (try? check()) != nil else { close(); return }
        do { try await update() } catch { entries = []; loaded = false }
        guard (try? check()) != nil else { close(); return }
        if error is CancellationError { return }
        if error is ChildTaskActionAdmissionFailure { message = ChildTaskActionAdmissionFailure().localizedDescription }
        else if let value = error as? ChildTaskCompletionCapacityFailure { message = value.localizedDescription }
        else if let value = error as? ChildTaskCompletionFailure { message = value.localizedDescription }
        else if error is AccountSessionAuthorizationRequired { message = "Sign in again to check this saved selection. Your work is kept." }
        else { message = "This selection couldn’t be confirmed. Your saved work is kept; review it before trying again." }
    }
    func load() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try check(); try await update() } catch { await recover(error) }
    }
    private func sendSaved(_ command: ChildTaskCompletionBatchCommand, resolving: Bool = false) async throws {
        let proof = try await sender.send(command, resolving: resolving); try check(); try await update()
        if proof.applied { await refresh(); try check() }
        message = proof.closed ? "The original selection was stopped. Review current tasks before saving a fresh action." : command.isUndo ? "Selection Undo confirmed." : "Selection confirmed."
    }
    @discardableResult func perform(_ command: ChildTaskCompletionBatchCommand) async -> Bool {
        guard !busy else { return false }; busy = true; defer { busy = false }
        do {
            try check(); guard command.account == scope.account, command.origin == scope.origin, canQueue(command) else { throw ChildTaskCompletionFailure(reason: .unavailable) }
            try await journal.enqueue(command, lease: lease); try check(); try await update()
            if canSend(command) { try await sendSaved(command) }
            else { message = "Selection saved for later. No task change is confirmed yet." }
            return entries.contains { $0.command == command && $0.phase == .confirmed }
        } catch { await recover(error); return false }
    }
    func send(_ command: ChildTaskCompletionBatchCommand, resolving: Bool = false) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try check(); try await sendSaved(command, resolving: resolving) } catch { await recover(error) }
    }
    @discardableResult func undo(_ entry: ChildTaskCompletionBatchState.Entry, reads: [String: ChildTaskRecordRead]) async -> ChildTaskCompletionBatchCommand? {
        guard !busy else { return nil }; busy = true; defer { busy = false }
        do {
            try check(); guard entries.contains(entry), entry.phase == .confirmed, let proof = entry.proof,
                  reads.values.allSatisfy({ ChildTaskFieldClientScope($0.context) == scope }) else { throw ChildTaskCompletionBatchState.invalid }
            let command = try entry.command.undo(reads: reads, decision: proof)
            guard canQueue(command) else { throw ChildTaskCompletionFailure(reason: .unavailable) }
            try await journal.enqueue(command, lease: lease); try check(); try await update()
            if canSend(command) { try await sendSaved(command) } else { message = "Selection Undo saved for later. The tasks have not changed yet." }
            return command
        } catch { await recover(error); return nil }
    }
    func replace(_ entry: ChildTaskCompletionBatchState.Entry, with command: ChildTaskCompletionBatchCommand) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try check(); guard entries.contains(entry), entry.phase == .closed, canQueue(command) else { throw ChildTaskCompletionBatchState.invalid }
            try await journal.replaceClosed(entry.command, with: command, lease: lease); try check(); try await update()
            message = "Fresh selection saved. Review it before sending."
        } catch { await recover(error) }
    }
    func discard(_ command: ChildTaskCompletionBatchCommand) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try check(); try await journal.discard(command, lease: lease); try check(); try await update(); message = "Saved record removed from this device. Task changes are kept." }
        catch { await recover(error) }
    }
}

/// Store factories use one account process lock for all child journals. These
/// synchronous reads run inside that lock, without taking another journal lock.
struct ChildTaskActionAdmission: Sendable {
    let account: String, origin: String
    let directory: URL
    let encryptionKey: @Sendable () throws -> SymmetricKey
    private func read<T: ReviewedTeamFileCommand>(_ type: T.Type, folder: String) throws -> T? {
        let io = ReviewedTeamCommandFileIO<T>(directory: directory.appendingPathComponent(folder)
            .appendingPathComponent(account).appendingPathComponent(CalendarOAuthConfiguration.digest(origin)), account: account, origin: origin, encryptionKey: encryptionKey)
        guard let bytes = try io.read(key: T.storagePrefix + account + "." + CalendarOAuthConfiguration.digest(origin)) else { return nil }
        try ChildTaskRecordRead.validateUniqueJSON(bytes, maximum: T.maximumStoredBytes)
        let state = try TaskfoldJSONDecoder().decode(T.self, from: bytes)
        guard state.account == account, state.origin == origin else { throw ChildTaskCompletionBatchState.invalid }; return state
    }
    private func refuse(_ roots: Set<String>, overlapping pending: Set<String>) throws {
        guard roots.isDisjoint(with: pending) else { throw ChildTaskActionAdmissionFailure() }
    }
    func checkOther(_ roots: Set<String>) throws {
        let groups = try read(ChildTaskCompletionBatchState.self, folder: "Child completion groups")
        let pending = Set((groups?.entries ?? []).filter { $0.phase == .queued || $0.phase == .attempted }.flatMap { $0.command.items.map { $0.body["task_id"]!.text } })
        try refuse(roots, overlapping: pending)
        try checkMixed(roots)
    }
    func checkMixed(_ roots: Set<String>) throws {
        let state = try read(MixedTaskCompletionState.self, folder: "Task selection requests")
        try refuse(roots, overlapping: Set((state?.entries ?? []).filter { $0.phase == .queued || $0.phase == .attempted }.flatMap { $0.command.rootIDs }))
    }
    func checkForMixed(_ roots: Set<String>) throws {
        try checkBatch(roots, includeMixed: false)
        let groups = try read(ChildTaskCompletionBatchState.self, folder: "Child completion groups")
        try refuse(roots, overlapping: Set((groups?.entries ?? []).filter { $0.phase == .queued || $0.phase == .attempted }.flatMap { $0.command.items.map { $0.body["task_id"]!.text } }))
    }
    func checkBatch(_ roots: Set<String>, includeMixed: Bool = true) throws {
        var pending = Set<String>()
        let fields = try read(ChildTaskFieldJournalState.self, folder: "Child field requests")
        pending.formUnion((fields?.entries ?? []).filter { $0.phase == .queued || $0.phase == .attempted }.map { $0.command.body["task_id"]!.text })
        let completions = try read(ChildTaskCompletionJournalState.self, folder: "Child completion requests")
        pending.formUnion((completions?.entries ?? []).filter { $0.phase == .queued || $0.phase == .attempted }.map { $0.command.body["task_id"]!.text })
        let structures = try read(ChildTaskStructureJournalState.self, folder: "Child hierarchy requests")
        pending.formUnion((structures?.entries ?? []).filter { $0.phase == .queued || $0.phase == .attempted }.map { $0.command.body["task_id"]!.text })
        let drafts = try read(ChildTaskStructureDraftState.self, folder: "Child hierarchy drafts")
        pending.formUnion((drafts?.entries ?? []).map { $0.body["task_id"]!.text })
        let moves = try read(ChildTaskTransferState.self, folder: "Child transfer requests")
        pending.formUnion((moves?.entries ?? []).filter { $0.phase == .queued || $0.phase == .attempted }.flatMap { $0.command.roots })
        let adoptions = try read(ChildTaskAdoptionState.self, folder: "Child adoption requests")
        pending.formUnion((adoptions?.entries ?? []).filter { $0.phase == .queued || $0.phase == .attempted }.map { $0.command.body["task_id"]!.text })
        let repairs = try read(ChildTaskRepairState.self, folder: "Child repair requests")
        pending.formUnion((repairs?.entries ?? []).filter { $0.phase == .queued || $0.phase == .attempted }.map { $0.command.body["task_id"]!.text })
        try refuse(roots, overlapping: pending)
        if includeMixed { try checkMixed(roots) }
    }
}

/// A frozen selection, including rows already in the desired state. Preparation
/// has no write/queue API: mixed results require one atomic executor, never a
/// loop of legacy root mutations followed by independent child requests.
struct TaskListCompletionSelectionIntent: Sendable {
    struct Root: Sendable {
        let source: Record
        private let baseline: [String: JSON]
        private static let identity: Set<String> = ["id", "user_id", "task_generation", "project_id", "section_id"]
        private static let cohort: Set<String> = ["completed", "completed_at", "completion_version", "is_heading", "is_recurring"]
        init(task: Record, root: Record) throws {
            guard TeamProjectValue.id(root.id), TaskKind.mayComplete(root) else { throw TaskListCompletionSelectionIntent.invalid }
            _ = try TeamProjectValue.optionalID(root.fields["task_generation"] ?? .null)
            _ = try TeamProjectValue.optionalID(root.fields["project_id"] ?? .null)
            source = root; baseline = Self.values(root)
            guard AuthoredValueComparison.exactJSON(.object(Self.values(task)), .object(baseline)) else { throw TaskListCompletionSelectionIntent.invalid }
            try Self.validate(root)
        }
        private static func values(_ root: Record) -> [String: JSON] {
            // Completing a recurring root can copy its authored content into a
            // successor, so its entire source must still agree. Ordinary roots
            // permit unrelated title/note edits and compare only their cohort.
            root["is_recurring"].flag ? root.fields : root.fields.filter { identity.union(cohort).contains($0.key) }
        }
        private static func validate(_ root: Record) throws {
            for key in ["completed", "is_heading", "is_recurring"] {
                if let value = root.fields[key], value != .null { guard case .bool = value else { throw TaskListCompletionSelectionIntent.invalid } }
            }
            if root.completed {
                guard case .string(let timestamp)? = root.fields["completed_at"], timestamp.utf8.count <= 64,
                      TaskPlanning.instant(timestamp) != nil else { throw TaskListCompletionSelectionIntent.invalid }
            } else {
                guard root.fields["completed_at"] == nil || root.fields["completed_at"] == .null else { throw TaskListCompletionSelectionIntent.invalid }
            }
            if let value = root.fields["completion_version"] {
                guard case .number(let version) = value, version.isFinite, version >= 0,
                      version <= 9_007_199_254_740_990, version.rounded(.down) == version else { throw TaskListCompletionSelectionIntent.invalid }
            }
        }
        func current(_ root: Record) throws -> Record {
            try Self.validate(root)
            guard TaskKind.mayComplete(root), AuthoredValueComparison.exactJSON(.object(Self.values(root)), .object(baseline)) else { throw TaskListCompletionSelectionIntent.invalid }
            return root
        }
    }
    enum Member: Sendable {
        case root(Root), child(ChildTaskListCompletionIntent)
        var rootID: String { switch self { case .root(let value): value.source.id; case .child(let value): value.opening.rootID } }
        var completed: Bool { switch self { case .root(let value): value.source.completed; case .child(let value): value.completed } }
    }
    struct Prepared: Sendable {
        enum Member: Sendable { case root(Record), child(ChildTaskCompletionCommand) }
        enum Observation: Sendable { case root(Record), child(ChildTaskRecordRead, key: String) }
        let scope: ChildTaskFieldClientScope
        let completed: Bool
        /// Every selected row, in user order, including no-ops. A future atomic
        /// executor must carry these guards as well as the changed members.
        let observations: [Observation]
        /// Keeps the user's order across both kinds; contains changed rows only.
        let members: [Member]
    }
    static var invalid: AppFailure { .init(message: "This selection changed. Review its current tasks before trying again.") }
    let scope: ChildTaskFieldClientScope
    let completed: Bool
    let members: [Member]
    var rootIDs: Set<String> { Set(members.map(\.rootID)) }
    var childMembers: [ChildTaskListCompletionIntent] { members.compactMap { if case .child(let value) = $0 { return value }; return nil } }
    init(tasks: [Record], roots: [Record], projects: [Record], scope: ChildTaskFieldClientScope, completed: Bool) throws {
        try TeamOrganizationValue.scope(account: scope.account, origin: scope.origin)
        guard (1...32).contains(tasks.count), Set(tasks.map(\.id)).count == tasks.count else { throw Self.invalid }
        let grouped = Dictionary(grouping: roots, by: \.id)
        let members = try tasks.map { task -> Member in
            let path = SubtaskTree.referencePath(task.id)
            let id = path?.first ?? task.id
            guard !task.id.hasPrefix("subtask:") || path != nil,
                  let matches = grouped[id], matches.count == 1,
                  let root = matches.first else { throw Self.invalid }
            try Self.project(root, projects: projects)
            if path != nil { return .child(try .init(task: task, root: root, projects: projects, scope: scope)) }
            return .root(try .init(task: task, root: root))
        }
        guard members.contains(where: { $0.completed != completed }) else { throw Self.invalid }
        self.scope = scope; self.completed = completed; self.members = members
    }
    private static func project(_ root: Record, projects: [Record]) throws {
        let id = try TeamProjectValue.optionalID(root.fields["project_id"] ?? .null)
        guard let id else { return }
        guard projects.filter({ $0.id == id }).count == 1, !ProjectOrganization.archivedIDs(in: projects).contains(id) else { throw Self.invalid }
    }
    func prepare(roots: [Record], projects: [Record], reads: [String: ChildTaskRecordRead], current: ChildTaskFieldClientScope) throws -> Prepared {
        guard current == scope else { throw CancellationError() }
        let grouped = Dictionary(grouping: roots, by: \.id)
        var resolved: [Prepared.Member] = [], observations: [Prepared.Observation] = []
        for member in members {
            guard let matches = grouped[member.rootID], matches.count == 1, let root = matches.first else { throw Self.invalid }
            try Self.project(root, projects: projects)
            switch member {
            case .root(let intent):
                let fresh = try intent.current(root)
                observations.append(.root(fresh))
                if member.completed != completed { resolved.append(.root(fresh)) }
            case .child(let intent):
                guard let read = reads[member.rootID],
                      AuthoredValueComparison.exactJSON(.object(root.fields), .object(read.context.root.fields)) else { throw Self.invalid }
                let key = try intent.key(in: read) // Validate even a selected no-op.
                observations.append(.child(read, key: key))
                if member.completed != completed {
                    resolved.append(.child(try .init(ChildTaskCompletionDraft(read: read, key: key, action: completed ? .complete : .reopen))))
                }
            }
        }
        return .init(scope: scope, completed: completed, observations: observations, members: resolved)
    }
}

struct ChildTaskListBatchIntent: Sendable {
    private let selection: TaskListCompletionSelectionIntent
    private let projects: [Record]
    let scope: ChildTaskFieldClientScope
    /// Includes selected no-ops so their fresh read cannot be skipped.
    let members: [ChildTaskListCompletionIntent]
    let completed: Bool
    init(tasks: [Record], roots: [Record], projects: [Record], scope: ChildTaskFieldClientScope, completed: Bool) throws {
        guard tasks.allSatisfy({ SubtaskTree.referencePath($0.id) != nil }) else { throw ChildTaskCompletionBatchCommand.invalid }
        selection = try .init(tasks: tasks, roots: roots, projects: projects, scope: scope, completed: completed)
        members = selection.childMembers; self.projects = projects; self.scope = scope; self.completed = completed
    }
    func command(reads: [String: ChildTaskRecordRead]) throws -> ChildTaskCompletionBatchCommand {
        let prepared = try selection.prepare(roots: reads.values.map { $0.context.root }, projects: projects, reads: reads, current: scope)
        let commands = try prepared.members.map { member -> ChildTaskCompletionCommand in
            guard case .child(let command) = member else { throw ChildTaskCompletionBatchCommand.invalid }; return command
        }
        return try .init(account: scope.account, origin: scope.origin, items: commands)
    }
}
struct ChildTaskListBatchUndo: Equatable, Sendable {
    let scope: ChildTaskFieldClientScope
    let command: ChildTaskCompletionBatchCommand
}
struct ChildTaskListBatchResult {
    let message: String
    let undo: ChildTaskListBatchUndo?
    var needsReview = false
}
extension ChildTaskCompletionBatchCommand {
    func fresh(reads: [String: ChildTaskRecordRead]) throws -> Self {
        let updated = try items.map { old -> ChildTaskCompletionCommand in
            guard let read = reads[old.body["task_id"]!.text] else { throw Self.invalid }
            let new: ChildTaskCompletionCommand
            if let source = old.original {
                let original = try ChildTaskCompletionCommand(account: account, origin: origin, body: source.body)
                new = try .init(undo: original, receipt: original.confirmed(source.receipt), read: read)
            } else {
                guard let action = ChildTaskCompletionDraft.Action(rawValue: old.body["action"]!.text) else { throw Self.invalid }
                new = try .init(ChildTaskCompletionDraft(read: read, key: old.body["node_key"]!.text, action: action))
            }
            guard ChildTaskCompletionCommand.identity.allSatisfy({ AuthoredValueComparison.exactJSON(old.body[$0]!, new.body[$0]!) }) else { throw Self.invalid }
            return new
        }
        guard Set(reads.values.map { ChildTaskFieldClientScope($0.context) }).count == 1 else { throw Self.invalid }
        return try .init(account: account, origin: origin, items: updated)
    }
}

struct ChildTaskActionAdmissionFailure: LocalizedError {
    var errorDescription: String? { "Another saved subtask action needs review before these tasks can change." }
}

/// Recovery discovery is independent of write rollout gates and stores no task content.
enum ChildTaskRecoveryKind: CaseIterable, Hashable, Sendable {
    case fields, completions, groups, mixed, hierarchy, transfers, adoptions, repairs
}
@MainActor @Observable final class ChildTaskRecoveryDiscovery {
    private var ticket = UUID()
    private(set) var scope: ChildTaskFieldClientScope?
    private var present = Set<ChildTaskRecoveryKind>()
    func contains(_ kind: ChildTaskRecoveryKind, scope current: ChildTaskFieldClientScope?) -> Bool {
        current != nil && current == scope && present.contains(kind)
    }
    func close() { ticket = UUID(); scope = nil; present = [] }
    func refresh(scope captured: ChildTaskFieldClientScope,
                 current: () -> ChildTaskFieldClientScope?,
                 read: (ChildTaskRecoveryKind) async throws -> Bool) async {
        let request = UUID(); ticket = request
        func valid() -> Bool { !Task.isCancelled && ticket == request && current() == captured }
        guard valid() else { return }
        var found = Set<ChildTaskRecoveryKind>()
        for kind in ChildTaskRecoveryKind.allCases {
            do { if try await read(kind) { found.insert(kind) } }
            catch { found.insert(kind) } // An unreadable journal must remain reachable for recovery.
            guard valid() else { return }
        }
        present = found; scope = captured
    }
}


/// A scoped read, never a completion receipt or permission to mutate a root.
struct CompletionSelectionRootRead: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let maximumBytes = 4_194_304
    static let maximumRootBytes = 2_000_000
    static let baselineKeys: Set<String> = ["id", "user_id", "task_generation", "project_id", "section_id", "completed", "completed_at", "completion_version", "is_heading", "is_recurring"]
    struct Observation: Sendable {
        let task: Record
        let baseline: [String: JSON]
        let sourceHash: String
        var guardBody: [String: JSON] { ["task_id": .string(task.id), "baseline": .object(baseline), "source_hash": .string(sourceHash)] }
    }
    let scope: ChildTaskFieldClientScope
    let roots: [Observation]
    var description: String { "Private parent completion observations" }
    var debugDescription: String { description }
    var guardBody: [String: JSON] { ["protocol": .number(1), "account": .string(scope.account), "roots": .array(roots.map { .object($0.guardBody) })] }
    static func request(taskIDs: [String], scope: ChildTaskFieldClientScope) throws -> [String: JSON] {
        try TeamOrganizationValue.scope(account: scope.account, origin: scope.origin)
        guard scope.origin.utf8.count <= 2048, (1...32).contains(taskIDs.count), Set(taskIDs).count == taskIDs.count,
              taskIDs.allSatisfy(TeamProjectValue.id) else { throw ChildTaskRecordFailure.review }
        return ["protocol": .number(1), "account": .string(scope.account), "task_ids": .array(taskIDs.map(JSON.string))]
    }
    init(data: Data, taskIDs: [String], scope: ChildTaskFieldClientScope) throws {
        try Task.checkCancellation()
        _ = try Self.request(taskIDs: taskIDs, scope: scope)
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: Self.maximumBytes,
            integerPaths: [["roots", "[]", "task", "completion_version"], ["roots", "[]", "baseline", "completion_version"]],
            preservedValuePaths: [["roots", "[]", "task"]])
        guard let raw = try? TaskfoldJSONDecoder().decode([String: JSON].self, from: data) else { throw ChildTaskRecordFailure.review }
        guard Set(raw.keys) == ["protocol", "account", "roots"], raw["protocol"] == .number(1), raw["account"] == .string(scope.account),
              case .array(let values)? = raw["roots"], values.count == taskIDs.count else { throw ChildTaskRecordFailure.review }
        roots = try zip(values, taskIDs).map { value, id in
            try Task.checkCancellation()
            guard case .object(let row) = value, Set(row.keys) == ["task", "baseline", "source_hash"],
                  case .object(let source)? = row["task"], case .object(let baseline)? = row["baseline"],
                  Set(baseline.keys) == Self.baselineKeys, Self.baselineKeys.isSubset(of: Set(source.keys)),
                  source["id"] == .string(id), case .string(let hash)? = row["source_hash"],
                  hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  source["completed"] == .bool(false) || source["completed"] == .bool(true), source["is_heading"] == .bool(false) || source["is_heading"] == .null,
                  source["is_recurring"] == .bool(false) || source["is_recurring"] == .bool(true) || source["is_recurring"] == .null,
                  AuthoredValueComparison.exactJSON(.object(baseline), .object(source.filter { Self.baselineKeys.contains($0.key) })) else { throw ChildTaskRecordFailure.review }
            _ = try TeamOrganizationValue.id(source["user_id"])
            _ = try TeamOrganizationValue.id(source["task_generation"])
            _ = try TeamProjectValue.optionalID(source["project_id"])
            _ = try TeamProjectValue.optionalID(source["section_id"])
            let task = Record(source)
            _ = try TaskListCompletionSelectionIntent.Root(task: task, root: task)
            guard try TaskfoldJSONEncoder().encode(JSON.object(source)).count <= Self.maximumRootBytes else { throw ChildTaskRecordFailure.oversized }
            return Observation(task: task, baseline: baseline, sourceHash: hash)
        }
        self.scope = scope
    }
    /// Fresh sources remain paired with their server guards. Never stitch roots
    /// from an unrelated request or child snapshot into a prepared selection.
    func prepare(_ selection: TaskListCompletionSelectionIntent, projects: [Record], childReads: [String: ChildTaskRecordRead], current: ChildTaskFieldClientScope) throws -> TaskListCompletionSelectionIntent.Prepared {
        guard current == scope, selection.scope == scope else { throw CancellationError() }
        let selectedRoots = Set(selection.members.compactMap { if case .root(let root) = $0 { return root.source.id }; return nil })
        guard Set(roots.map { $0.task.id }) == selectedRoots else { throw ChildTaskRecordFailure.review }
        var sources = Dictionary(uniqueKeysWithValues: roots.map { ($0.task.id, $0.task) })
        for member in selection.childMembers {
            guard let read = childReads[member.opening.rootID], ChildTaskFieldClientScope(read.context) == scope else { throw ChildTaskRecordFailure.review }
            if let root = sources[member.opening.rootID] {
                guard AuthoredValueComparison.exactJSON(.object(root.fields), .object(read.context.root.fields)) else { throw ChildTaskRecordFailure.review }
            } else { sources[member.opening.rootID] = read.context.root }
        }
        return try selection.prepare(roots: Array(sources.values), projects: projects, reads: childReads, current: current)
    }
}

/// The list sends one saved request for parents and children together. A saved
/// request contains guards and completion cohorts, never task titles or notes.
struct MixedTaskCompletionCommand: ReviewedTeamCommand, CustomStringConvertible, CustomDebugStringConvertible {
    struct Original: Codable, Equatable, Sendable {
        let body: [String: JSON], receipt: [String: JSON]
        private enum CodingKeys: String, CodingKey { case body, receipt }
        init(body: [String: JSON], receipt: [String: JSON]) { self.body = body; self.receipt = receipt }
        init(from decoder: Decoder) throws {
            try completionKeys(decoder, ["body", "receipt"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            body = try c.decode([String: JSON].self, forKey: .body); receipt = try c.decode([String: JSON].self, forKey: .receipt)
        }
    }
    struct Member: Sendable {
        let kind: String, body: [String: JSON]
        var id: String { body["request_id"]!.text }
        var rootID: String { body["task_id"]!.text }
    }
    static let storagePrefix = "mixed-completion-command-v1."
    static let maximumStoredBytes = 524_288
    static let maximumResponseBytes = 524_288
    static var invalid: AppFailure { .init(message: "Review this task selection again. Your saved work is unchanged.") }
    let account: String, origin: String, body: [String: JSON]
    let original: Original?
    var id: String { body["batch_id"]!.text }
    var isUndo: Bool { original != nil }
    var description: String { "Private task selection request" }
    var debugDescription: String { description }
    var items: [Member] { body["items"]!.list.map { value in let row = value.object; return .init(kind: row["kind"]!.text, body: row["kind"] == .string("root") ? row.filter { $0.key != "kind" } : row["command"]!.object) } }
    var rootIDs: Set<String> {
        if let original {
            let created = original.receipt["receipts"]?.list.compactMap { value -> String? in
                let next = value.object["successor"]?.object ?? [:]
                return next["created"] == .bool(true) ? next["id"]?.text : nil
            } ?? []
            return Set(items.map(\.rootID)).union(created)
        }
        return Set((body["roots"]!.list + body["children"]!.list).map { $0.object["task_id"]!.text })
    }
    func overlaps(_ other: Self) -> Bool { account == other.account && origin == other.origin && !rootIDs.isDisjoint(with: other.rootIDs) }
    init(prepared: TaskListCompletionSelectionIntent.Prepared, roots: CompletionSelectionRootRead?, completedAt: Date = Date(), timeZone: TimeZone = .current) throws {
        if let roots { guard roots.scope == prepared.scope else { throw Self.invalid } }
        var parents: [JSON] = [], children: [JSON] = []
        for observation in prepared.observations {
            switch observation {
            case .root(let root):
                guard let proof = roots?.roots.first(where: { $0.task.id == root.id }), AuthoredValueComparison.exactJSON(.object(proof.task.fields), .object(root.fields)) else { throw Self.invalid }
                parents.append(.object(proof.guardBody))
            case .child(let read, let key):
                guard ChildTaskFieldClientScope(read.context) == prepared.scope, let node = read.nodes[key] else { throw Self.invalid }
                let done = try ChildTaskCompletionDraft.completed(node.fields.filter { ChildTaskCompletionDraft.cohort.contains($0.key) })
                let guardCommand = try ChildTaskCompletionCommand(ChildTaskCompletionDraft(read: read, key: key, action: done ? .reopen : .complete))
                children.append(.object(guardCommand.body.filter { !["protocol", "account", "request_id", "action"].contains($0.key) }))
            }
        }
        let members: [JSON] = prepared.members.map { member in
            switch member {
            case .root(let root): .object(["kind": .string("root"), "request_id": .string(UUID().uuidString.lowercased()), "task_id": .string(root.id)])
            case .child(let command): .object(["kind": .string("child"), "command": .object(command.body)])
            }
        }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try self.init(account: prepared.scope.account, origin: prepared.scope.origin, body: ["protocol": .number(1), "account": .string(prepared.scope.account), "batch_id": .string(UUID().uuidString.lowercased()), "action": .string(prepared.completed ? "complete" : "reopen"), "completed_at": .string(formatter.string(from: completedAt)), "input_zone": .string(timeZone.identifier), "roots": .array(parents), "children": .array(children), "items": .array(members)])
    }
    init(account: String, origin: String, body: [String: JSON], original: Original? = nil) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard origin.utf8.count <= 2048, body["protocol"] == .number(1), body["account"] == .string(account),
              TeamProjectValue.id(body["batch_id"]?.text ?? ""), case .array(let rows)? = body["items"], (1...32).contains(rows.count) else { throw Self.invalid }
        if let original {
            let source = try Self(account: account, origin: origin, body: original.body)
            let proof = try source.resolution(original.receipt)
            guard Set(body.keys) == ["protocol", "account", "batch_id", "undo_of", "items"], proof.applied,
                  body["undo_of"] == .string(source.id), body["batch_id"] != .string(source.id), rows.count == source.items.count else { throw Self.invalid }
        } else {
            guard Set(body.keys) == ["protocol", "account", "batch_id", "action", "completed_at", "input_zone", "roots", "children", "items"],
                  body["action"] == .string("complete") || body["action"] == .string("reopen"),
                  case .string(let stamp)? = body["completed_at"], stamp.utf8.count <= 64, TaskPlanning.instant(stamp) != nil,
                  case .string(let zone)? = body["input_zone"], zone.utf8.count <= 128, TimeZone(identifier: zone) != nil,
                  case .array(let parents)? = body["roots"], case .array(let children)? = body["children"], (1...32).contains(parents.count + children.count) else { throw Self.invalid }
            for value in parents {
                let guardBody = value.object
                guard Set(guardBody.keys) == ["task_id", "baseline", "source_hash"], case .object(let baseline)? = guardBody["baseline"], guardBody["task_id"] == baseline["id"],
                      case .string(let hash)? = guardBody["source_hash"], Self.hash(hash) else { throw Self.invalid }
                try Self.baseline(baseline)
            }
            for value in children {
                let guardBody = value.object
                let done = try ChildTaskCompletionDraft.completed(guardBody["baseline"]?.object ?? [:])
                _ = try ChildTaskCompletionCommand(account: account, origin: origin, body: guardBody.merging(["protocol": .number(1), "account": .string(account), "request_id": .string(UUID().uuidString.lowercased()), "action": .string(done ? "reopen" : "complete")]) { _, new in new })
            }
        }
        // Validate all row shapes before any computed member can read them.
        for value in rows {
            guard case .object(let row) = value, case .string(let kind)? = row["kind"], ["root", "child"].contains(kind),
                  Set(row.keys) == (kind == "root" ? ["kind", "request_id", "task_id"] : ["kind", "command"]) else { throw Self.invalid }
            let fields: [String: JSON]
            if kind == "child" { guard case .object(let child)? = row["command"] else { throw Self.invalid }; fields = child }
            else { fields = row }
            guard case .string? = fields["request_id"], case .string? = fields["task_id"] else { throw Self.invalid }
        }
        self.account = account; self.origin = origin; self.body = body; self.original = original
        var requests: Set<String> = [id], targets = Set<Data>()
        var expected = Set<Data>()
        if original == nil {
            for kind in ["root", "child"] {
                let guards = body[kind == "root" ? "roots" : "children"]!.list
                var seen = Set<Data>()
                for value in guards {
                    let target = try Self.target(kind, value.object)
                    guard seen.insert(target).inserted else { throw Self.invalid }
                    let done = kind == "root" ? value.object["baseline"]!.object["completed"]!.flag : try ChildTaskCompletionDraft.completed(value.object["baseline"]!.object)
                    if done != (body["action"] == .string("complete")) { expected.insert(target) }
                }
            }
        }
        for (index, value) in rows.enumerated() {
            guard case .object(let row) = value, let kind = row["kind"]?.text, ["root", "child"].contains(kind),
                  Set(row.keys) == (kind == "root" ? ["kind", "request_id", "task_id"] : ["kind", "command"]) else { throw Self.invalid }
            let member = items[index]
            guard TeamProjectValue.id(member.id), member.id != body["undo_of"]?.text, requests.insert(member.id).inserted, TeamProjectValue.id(member.rootID), targets.insert(try Self.target(kind, member.body)).inserted else { throw Self.invalid }
            if let original {
                let source = try Self(account: account, origin: origin, body: original.body)
                let sourceMember = source.items[index]
                guard kind == sourceMember.kind, member.rootID == sourceMember.rootID else { throw Self.invalid }
                if kind == "child" { _ = try childCommand(at: index) }
            } else if kind == "root" {
                guard body["roots"]!.list.contains(where: { $0.object["task_id"] == member.body["task_id"] }) else { throw Self.invalid }
            } else {
                let child = try childCommand(at: index)
                guard child.body["action"] == body["action"], body["children"]!.list.contains(where: { AuthoredValueComparison.exactJSON($0, .object(child.body.filter { !["protocol", "account", "request_id", "action"].contains($0.key) })) }) else { throw Self.invalid }
            }
        }
        guard original != nil || targets == expected else { throw Self.invalid }
        let wire = TaskfoldJSONEncoder(); wire.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard try wire.encode(body).count <= 131_072, try TaskfoldJSONEncoder().encode(self).count <= Self.maximumStoredBytes else { throw Self.invalid }
    }
    private static func target(_ kind: String, _ value: [String: JSON]) throws -> Data { try TaskfoldJSONEncoder().encode([JSON.string(kind), value["task_id"] ?? .null, kind == "child" ? value["node_key"] ?? .null : .null]) }
    fileprivate static func hash(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    fileprivate static func rootVersion(_ value: JSON?) throws -> Double {
        guard case .number(let version)? = value, version.isFinite, version >= 0, version <= 9_007_199_254_740_991, version.rounded(.down) == version else { throw invalid }
        return version
    }
    fileprivate static func baseline(_ value: [String: JSON], allowExhausted: Bool = false) throws {
        guard Set(value.keys) == CompletionSelectionRootRead.baselineKeys, value["completed"] == .bool(true) || value["completed"] == .bool(false), value["is_heading"] == .bool(false) || value["is_heading"] == .null, value["is_recurring"] == .bool(true) || value["is_recurring"] == .bool(false) || value["is_recurring"] == .null else { throw invalid }
        for key in ["id", "user_id", "task_generation"] { _ = try TeamOrganizationValue.id(value[key]) }
        for key in ["project_id", "section_id"] { _ = try TeamProjectValue.optionalID(value[key]) }
        _ = try rootVersion(value["completion_version"])
        var checked = value
        if allowExhausted { checked["completion_version"] = .number(0) }
        _ = try TaskListCompletionSelectionIntent.Root(task: Record(checked), root: Record(checked))
    }
    func childCommand(at index: Int) throws -> ChildTaskCompletionCommand {
        let item = items[index]; guard item.kind == "child" else { throw Self.invalid }
        if let original {
            let source = try Self(account: account, origin: origin, body: original.body)
            let proof = try source.resolution(original.receipt)
            return try .init(account: account, origin: origin, body: item.body, original: .init(body: source.items[index].body, receipt: proof.receipts[index].raw["receipt"]!.object))
        }
        return try .init(account: account, origin: origin, body: item.body)
    }
    func resolution(_ raw: [String: JSON]) throws -> MixedTaskCompletionResolution { try .init(command: self, raw: raw) }
    func undo(reads: [String: ChildTaskRecordRead], decision: MixedTaskCompletionResolution) throws -> Self {
        let proof = try resolution(decision.raw); guard !isUndo, proof.applied else { throw Self.invalid }
        let inverse: [JSON] = try items.enumerated().map { index, item in
            if item.kind == "root" { return .object(["kind": .string("root"), "task_id": .string(item.rootID), "request_id": .string(UUID().uuidString.lowercased())]) }
            guard let read = reads[item.rootID] else { throw Self.invalid }
            let child = try childCommand(at: index)
            let undo = try ChildTaskCompletionCommand(undo: child, receipt: child.confirmed(proof.receipts[index].raw["receipt"]!.object), read: read)
            return .object(["kind": .string("child"), "command": .object(undo.body)])
        }
        return try .init(account: account, origin: origin, body: ["protocol": .number(1), "account": .string(account), "batch_id": .string(UUID().uuidString.lowercased()), "undo_of": .string(id), "items": .array(inverse)], original: .init(body: body, receipt: proof.raw))
    }
    /// Redo is a fresh operation, guarded by the state certified by Undo. It
    /// never resends the old completion or restores an old task document.
    func redo(roots: CompletionSelectionRootRead, reads: [String: ChildTaskRecordRead], decision: MixedTaskCompletionResolution) throws -> Self {
        let proof = try resolution(decision.raw)
        guard let original, proof.applied, roots.scope.account == account, roots.scope.origin == origin,
              reads.values.allSatisfy({ ChildTaskFieldClientScope($0.context) == roots.scope }) else { throw Self.invalid }
        let source = try Self(account: account, origin: origin, body: original.body)
        var body = source.body
        body["batch_id"] = .string(UUID().uuidString.lowercased())
        let oldRoots = source.body["roots"]!.list
        guard Set(roots.roots.map { $0.task.id }) == Set(oldRoots.map { $0.object["task_id"]!.text }) else { throw Self.invalid }
        body["roots"] = .array(try oldRoots.map { value in
            let old = value.object
            guard let fresh = roots.roots.first(where: { .string($0.task.id) == old["task_id"] }) else { throw Self.invalid }
            let index = source.items.firstIndex { $0.kind == "root" && .string($0.rootID) == old["task_id"] }
            let expected = index.map { proof.receipts[$0].raw["after"]! } ?? old["baseline"]!
            guard AuthoredValueComparison.exactJSON(.object(fresh.baseline), expected) else { throw Self.invalid }
            return .object(fresh.guardBody)
        })
        var childCommands: [Data: ChildTaskCompletionCommand] = [:]
        body["children"] = .array(try source.body["children"]!.list.map { value in
            let old = value.object, rootID = old["task_id"]!.text, key = old["node_key"]!.text
            guard let read = reads[rootID], let node = read.nodes[key],
                  old["task_generation"] == read.context.root["task_generation"],
                  old["project_id"] == (read.context.root.fields["project_id"] ?? .null), old["incarnation"] == .string(node.incarnation) else { throw Self.invalid }
            let index = source.items.firstIndex { $0.kind == "child" && $0.rootID == rootID && $0.body["node_key"] == old["node_key"] }
            let expected = index.map { proof.receipts[$0].raw["receipt"]!.object["after"]! } ?? old["baseline"]!
            let baseline = node.fields.filter { ChildTaskCompletionDraft.cohort.contains($0.key) }
            let expectedRevision = index.map { Double(proof.receipts[$0].raw["receipt"]!.object["revision"]!.integer) } ?? Double(old["revision"]!.integer)
            guard AuthoredValueComparison.exactJSON(.object(baseline), expected), node.revision >= expectedRevision else { throw Self.invalid }
            let done = try ChildTaskCompletionDraft.completed(baseline)
            let child = try ChildTaskCompletionCommand(ChildTaskCompletionDraft(read: read, key: key, action: done ? .reopen : .complete))
            childCommands[try Self.target("child", old)] = child
            return .object(child.body.filter { !["protocol", "account", "request_id", "action"].contains($0.key) })
        })
        body["items"] = .array(try source.items.map { item in
            if item.kind == "root" { return .object(["kind": .string("root"), "request_id": .string(UUID().uuidString.lowercased()), "task_id": .string(item.rootID)]) }
            guard let child = childCommands[try Self.target("child", item.body)] else { throw Self.invalid }
            return .object(["kind": .string("child"), "command": .object(child.body)])
        })
        return try .init(account: account, origin: origin, body: body)
    }
    private enum CodingKeys: String, CodingKey { case account, origin, body, original }
    init(from decoder: Decoder) throws {
        try completionKeys(decoder, ["account", "origin", "body", "original"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), body: c.decode([String: JSON].self, forKey: .body), original: c.decodeIfPresent(Original.self, forKey: .original))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(account, forKey: .account); try c.encode(origin, forKey: .origin); try c.encode(body, forKey: .body); try c.encode(original, forKey: .original)
    }
}
struct MixedTaskCompletionReceipt: Equatable, Sendable {
    let raw: [String: JSON]
    func agrees(_ other: Self) -> Bool { AuthoredValueComparison.exactJSON(Self.stable(.object(raw)), Self.stable(.object(other.raw))) }
    fileprivate static func stable(_ value: JSON) -> JSON {
        switch value {
        case .object(let values): .object(values.filter { $0.key != "replayed" }.mapValues(stable))
        case .array(let values): .array(values.map(stable))
        default: value
        }
    }
}
struct MixedTaskCompletionResolution: Equatable, Sendable {
    let raw: [String: JSON], receipts: [MixedTaskCompletionReceipt]
    var applied: Bool { raw["outcome"] == .string("applied") }
    var closed: Bool { raw["outcome"] == .string("closed") }
    init(command: MixedTaskCompletionCommand, raw: [String: JSON]) throws {
        guard Set(raw.keys) == ["protocol", "account", "batch_id", "outcome", "replayed", "receipts"], raw["protocol"] == .number(1), raw["account"] == .string(command.account), raw["batch_id"] == .string(command.id), case .bool? = raw["replayed"], case .array(let values)? = raw["receipts"] else { throw MixedTaskCompletionCommand.invalid }
        if raw["outcome"] == .string("closed") { guard values.isEmpty else { throw MixedTaskCompletionCommand.invalid }; receipts = [] }
        else {
            guard raw["outcome"] == .string("applied"), values.count == command.items.count else { throw MixedTaskCompletionCommand.invalid }
            receipts = try values.enumerated().map { index, value in
                guard case .object(let row) = value, row["kind"] == .string(command.items[index].kind), row["request_id"] == .string(command.items[index].id), row["replayed"] == raw["replayed"] else { throw MixedTaskCompletionCommand.invalid }
                if command.items[index].kind == "child" {
                    guard Set(row.keys) == ["kind", "request_id", "receipt", "replayed"], row["receipt"]?.object["replayed"] == raw["replayed"] else { throw MixedTaskCompletionCommand.invalid }
                    _ = try command.childCommand(at: index).confirmed(row["receipt"]!.object)
                } else { try Self.root(row, command: command, index: index) }
                return .init(raw: row)
            }
        }
        self.raw = raw
    }
    private static func root(_ row: [String: JSON], command: MixedTaskCompletionCommand, index: Int) throws {
        guard Set(row.keys) == ["kind", "request_id", "task_id", "task_generation", "project_id", "action", "before", "after", "successor", "replayed"], row["task_id"] == .string(command.items[index].rootID), case .object(let before)? = row["before"], case .object(let after)? = row["after"], case .object(let next)? = row["successor"], Set(next.keys) == ["state", "planned_id", "id", "generation", "created", "hash"] else { throw MixedTaskCompletionCommand.invalid }
        try MixedTaskCompletionCommand.baseline(before); try MixedTaskCompletionCommand.baseline(after, allowExhausted: true)
        guard row["task_id"] == before["id"], row["task_generation"] == before["task_generation"], row["project_id"] == before["project_id"], try MixedTaskCompletionCommand.rootVersion(after["completion_version"]) == MixedTaskCompletionCommand.rootVersion(before["completion_version"]) + 1 else { throw MixedTaskCompletionCommand.invalid }
        var expected = before
        if let original = command.original {
            let source = try MixedTaskCompletionCommand(account: command.account, origin: command.origin, body: original.body)
            let proof = try source.resolution(original.receipt).receipts[index].raw
            guard row["action"] == .string("undo"), AuthoredValueComparison.exactJSON(.object(before), proof["after"]!), next["created"] == .bool(false), next["hash"] == .null,
                  next["planned_id"] == proof["successor"]?.object["planned_id"], next["id"] == proof["successor"]?.object["id"], next["generation"] == proof["successor"]?.object["generation"] else { throw MixedTaskCompletionCommand.invalid }
            let created = proof["successor"]!.object["created"] == .bool(true)
            guard created ? [.string("removed"), .string("absent")].contains(next["state"]!) : next["state"] == .string("none") else { throw MixedTaskCompletionCommand.invalid }
            expected["completed"] = proof["before"]!.object["completed"]; expected["completed_at"] = proof["before"]!.object["completed_at"]
        } else {
            guard let original = command.body["roots"]!.list.first(where: { $0.object["task_id"] == row["task_id"] }), AuthoredValueComparison.exactJSON(.object(before), original.object["baseline"]!), row["action"] == command.body["action"] else { throw MixedTaskCompletionCommand.invalid }
            let done = command.body["action"] == .string("complete")
            expected["completed"] = .bool(done); expected["completed_at"] = done ? after["completed_at"] : .null
            if done { guard TaskPlanning.instant(after["completed_at"]?.text ?? "") == TaskPlanning.instant(command.body["completed_at"]!.text) else { throw MixedTaskCompletionCommand.invalid } }
            guard case .string(let state)? = next["state"], ["none", "created", "existing", "retired"].contains(state), next["created"] == .bool(state == "created") else { throw MixedTaskCompletionCommand.invalid }
            for key in ["planned_id", "id", "generation"] { _ = try TeamProjectValue.optionalID(next[key]) }
            if state == "created" || state == "existing" { guard next["id"] != .null, next["generation"] != .null, case .string(let hash)? = next["hash"], MixedTaskCompletionCommand.hash(hash), done, before["is_recurring"] == .bool(true), next["id"] != row["task_id"] else { throw MixedTaskCompletionCommand.invalid } }
            else { guard next["id"] == .null, next["generation"] == .null, next["hash"] == .null else { throw MixedTaskCompletionCommand.invalid } }
            if state == "none" { guard next["planned_id"] == .null else { throw MixedTaskCompletionCommand.invalid } }
        }
        expected["completion_version"] = after["completion_version"]
        guard AuthoredValueComparison.exactJSON(.object(expected), .object(after)) else { throw MixedTaskCompletionCommand.invalid }
    }
    func agrees(_ other: Self) -> Bool { MixedTaskCompletionReceipt(raw: raw).agrees(.init(raw: other.raw)) }
}

struct MixedTaskCompletionState: ReviewedTeamFileCommand, CustomStringConvertible, CustomDebugStringConvertible {
    enum Phase: String, Codable, Sendable { case queued, attempted, confirmed, closed }
    struct Entry: Codable, Equatable, Sendable {
        let command: MixedTaskCompletionCommand
        var phase: Phase
        var decision: [String: JSON]?
        var proof: MixedTaskCompletionResolution? { decision.flatMap { try? command.resolution($0) } }
        init(command: MixedTaskCompletionCommand, phase: Phase, decision: [String: JSON]? = nil) {
            self.command = command; self.phase = phase; self.decision = decision
        }
        private enum CodingKeys: String, CodingKey { case command, phase, decision }
        init(from decoder: Decoder) throws {
            try completionKeys(decoder, ["command", "phase", "decision"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            command = try c.decode(MixedTaskCompletionCommand.self, forKey: .command)
            phase = try c.decode(Phase.self, forKey: .phase)
            decision = try c.decodeIfPresent([String: JSON].self, forKey: .decision)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(command, forKey: .command); try c.encode(phase, forKey: .phase); try c.encode(decision, forKey: .decision)
        }
    }
    static let storagePrefix = "mixed-completion-groups-v1."
    static let fileName = "requests.taskfoldmixedcompletiongroups"
    static let encryptionContext = "com.taskfold.mixed-completion-groups.v1"
    static let maximumStoredBytes = 4_300_000
    static let maximumEntries = 32
    static var invalid: AppFailure { MixedTaskCompletionCommand.invalid }
    let account: String, origin: String
    var entries: [Entry]
    var description: String { "Private task selection journal" }
    var debugDescription: String { description }
    init(account: String, origin: String, entries: [Entry] = []) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard origin.utf8.count <= 2048, entries.count <= Self.maximumEntries else { throw Self.invalid }
        var groups = Set<String>(), members = Set<String>(), undoSources = Set<String>()
        for entry in entries {
            guard entry.command.account == account, entry.command.origin == origin, groups.insert(entry.command.id).inserted else { throw Self.invalid }
            for item in entry.command.items { guard members.insert(item.id).inserted else { throw Self.invalid } }
            switch entry.phase {
            case .queued, .attempted: guard entry.decision == nil else { throw Self.invalid }
            case .confirmed: guard entry.proof?.applied == true else { throw Self.invalid }
            case .closed: guard entry.proof?.closed == true else { throw Self.invalid }
            }
        }
        self.account = account; self.origin = origin; self.entries = entries
        for entry in entries where entry.command.isUndo {
            guard let parent = parent(of: entry.command) else { throw Self.invalid }
            if entry.phase != .closed { guard undoSources.insert(parent.command.id).inserted else { throw Self.invalid } }
        }
    }
    func parent(of command: MixedTaskCompletionCommand) -> Entry? {
        guard let original = command.original else { return nil }
        return entries.first { entry in
            !entry.command.isUndo && entry.phase == .confirmed && entry.command.id == command.body["undo_of"]?.text &&
            AuthoredValueComparison.exactJSON(.object(entry.command.body), .object(original.body)) &&
            (try? entry.command.resolution(original.receipt).agrees(entry.proof!)) == true
        }
    }
    mutating func makeRoom(preserving id: String?) throws {
        func fits() throws -> Bool { try entries.count <= Self.maximumEntries && TaskfoldJSONEncoder().encode(self).count <= Self.maximumStoredBytes }
        guard try !fits() else { return }
        var families: [String: [String]] = [:]
        for entry in entries {
            let family = entry.command.isUndo ? parent(of: entry.command)?.command.id : entry.command.id
            guard let family else { throw Self.invalid }
            families[family, default: []].append(entry.command.id)
        }
        let eligible = families.values.filter { ids in
            !ids.contains(id ?? "") && entries.filter { ids.contains($0.command.id) }.allSatisfy { $0.phase == .confirmed }
        }.sorted { left, right in
            entries.lastIndex { left.contains($0.command.id) }! < entries.lastIndex { right.contains($0.command.id) }!
        }
        for family in eligible {
            entries.removeAll { family.contains($0.command.id) }
            if try fits() { return }
        }
        throw ChildTaskCompletionCapacityFailure()
    }
    private enum CodingKeys: String, CodingKey { case version, account, origin, entries }
    init(from decoder: Decoder) throws {
        try completionKeys(decoder, ["version", "account", "origin", "entries"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == 1 else { throw Self.invalid }
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), entries: c.decode([Entry].self, forKey: .entries))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .version); try c.encode(account, forKey: .account); try c.encode(origin, forKey: .origin); try c.encode(entries, forKey: .entries)
    }
}

actor MixedTaskCompletionJournal {
    private let admit: @Sendable (Set<String>) throws -> Void
    let account: String, origin: String
    private let io: any CalendarSecureItemIO
    private let lock: AutomationEnrollmentProcessLock
    private let removalDirectory: URL
    private var key: String { MixedTaskCompletionState.storagePrefix + account + "." + CalendarOAuthConfiguration.digest(origin) }
    init(account: String, origin: String, io: any CalendarSecureItemIO, coordinationDirectory: URL, removalDirectory: URL, admit: @escaping @Sendable (Set<String>) throws -> Void = { _ in }) throws {
        self.admit = admit;
        try TeamOrganizationValue.scope(account: account, origin: origin)
        self.account = account; self.origin = origin; self.io = io; self.lock = .init(directory: coordinationDirectory); self.removalDirectory = removalDirectory
    }
    private func guarded<T>(_ lease: CalendarReadLease?, _ operation: () throws -> T) throws -> T {
        try lock.withExclusive(account: account, check: { try lease?.check() }) {
            try AccountRemovalDisk(directory: removalDirectory, account: account).writable { try lease?.check(); return try operation() }
        }
    }
    private func read() throws -> MixedTaskCompletionState {
        guard let data = try io.read(key: key) else { return try .init(account: account, origin: origin) }
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: MixedTaskCompletionState.maximumStoredBytes)
        let state = try TaskfoldJSONDecoder().decode(MixedTaskCompletionState.self, from: data)
        guard state.account == account, state.origin == origin else { throw MixedTaskCompletionState.invalid }
        return state
    }
    private func write(_ candidate: MixedTaskCompletionState, lease: CalendarReadLease, preserving id: String? = nil) throws {
        var state = candidate; try state.makeRoom(preserving: id)
        _ = try MixedTaskCompletionState(account: account, origin: origin, entries: state.entries)
        let data = try TaskfoldJSONEncoder().encode(state)
        guard data.count <= MixedTaskCompletionState.maximumStoredBytes else { throw MixedTaskCompletionState.invalid }
        try lease.check(); try io.write(data, key: key)
    }
    func load() throws -> MixedTaskCompletionState { try guarded(nil) { try read() } }
    func enqueue(_ command: MixedTaskCompletionCommand, lease: CalendarReadLease) throws {
        try guarded(lease) {
            try admit(command.rootIDs)
            guard command.account == account, command.origin == origin else { throw MixedTaskCompletionState.invalid }
            var state = try read()
            if let old = state.entries.first(where: { $0.command.id == command.id }) {
                guard old.command == command else { throw MixedTaskCompletionState.invalid }
                guard old.phase != .closed else { throw ChildTaskCompletionFailure(reason: .closed) }; return
            }
            let reserved = Set(state.entries.flatMap { $0.command.items.map(\.id) })
            guard command.items.allSatisfy({ !reserved.contains($0.id) }) else { throw MixedTaskCompletionState.invalid }
            state.entries.append(.init(command: command, phase: .queued)); try write(state, lease: lease)
        }
    }
    func begin(_ command: MixedTaskCompletionCommand, resolving: Bool = false, lease: CalendarReadLease) throws -> MixedTaskCompletionState.Entry {
        try guarded(lease) {
            if !resolving { try admit(command.rootIDs) }
            var state = try read()
            guard let i = state.entries.firstIndex(where: { $0.command == command }) else { throw MixedTaskCompletionState.invalid }
            if !resolving {
                guard state.entries[i].phase != .closed else { throw ChildTaskCompletionFailure(reason: .closed) }
                guard !state.entries[..<i].contains(where: { ($0.phase == .queued || $0.phase == .attempted) && $0.command.overlaps(command) }) else { throw MixedTaskCompletionState.invalid }
            }
            if state.entries[i].phase == .queued { state.entries[i].phase = .attempted; try write(state, lease: lease) }
            return state.entries[i]
        }
    }
    func settle(_ command: MixedTaskCompletionCommand, decision: MixedTaskCompletionResolution, lease: CalendarReadLease) throws {
        try guarded(lease) {
            _ = try command.resolution(decision.raw)
            var state = try read()
            guard let i = state.entries.firstIndex(where: { $0.command == command }), state.entries[i].phase != .queued else { throw MixedTaskCompletionState.invalid }
            if let old = state.entries[i].proof { guard old.agrees(decision) else { throw MixedTaskCompletionState.invalid }; return }
            if decision.applied {
                var entry = state.entries.remove(at: i); entry.phase = .confirmed; entry.decision = decision.raw; state.entries.append(entry)
            } else { state.entries[i].phase = .closed; state.entries[i].decision = decision.raw }
            try write(state, lease: lease, preserving: command.id)
        }
    }
    func discard(_ command: MixedTaskCompletionCommand, lease: CalendarReadLease) throws {
        try guarded(lease) {
            var state = try read()
            guard let i = state.entries.firstIndex(where: { $0.command == command }), state.entries[i].phase != .attempted,
                  !state.entries.contains(where: { $0.command.isUndo && state.parent(of: $0.command)?.command == command }) else { throw MixedTaskCompletionState.invalid }
            state.entries.remove(at: i); try write(state, lease: lease)
        }
    }
    func removeAccount() throws { try lock.withExclusive(account: account) { try io.remove(key: key) } }
}

@MainActor protocol MixedTaskCompletionService: AnyObject {
    func mixedTaskCompletion(_ command: MixedTaskCompletionCommand, session: UUID, close: Bool) async throws -> MixedTaskCompletionResolution
}
extension Backend: MixedTaskCompletionService {}
@MainActor final class MixedTaskCompletionSender {
    private let scope: ChildTaskFieldClientScope
    private let journal: MixedTaskCompletionJournal
    private let service: any MixedTaskCompletionService
    private let current: () -> ChildTaskFieldClientScope?
    private let canSend: (MixedTaskCompletionCommand) -> Bool
    private let lease = CalendarReadLease()
    private var closed = false
    init(scope: ChildTaskFieldClientScope, journal: MixedTaskCompletionJournal, service: any MixedTaskCompletionService,
         current: @escaping () -> ChildTaskFieldClientScope?, canSend: @escaping (MixedTaskCompletionCommand) -> Bool) {
        self.scope = scope; self.journal = journal; self.service = service; self.current = current; self.canSend = canSend
    }
    func close() { closed = true; lease.cancel() }
    private func check() throws { try Task.checkCancellation(); try lease.check(); guard !closed, current() == scope else { throw CancellationError() } }
    func send(_ command: MixedTaskCompletionCommand, resolving: Bool = false) async throws -> MixedTaskCompletionResolution {
        do {
            try check(); guard command.account == scope.account, command.origin == scope.origin else { throw CancellationError() }
            let state = try await journal.load(); try check()
            guard let entry = state.entries.first(where: { $0.command == command }) else { throw MixedTaskCompletionState.invalid }
            if let proof = entry.proof {
                if !resolving && proof.closed { throw ChildTaskCompletionFailure(reason: .closed) }
                return proof
            }
            guard resolving || canSend(command) else { throw ChildTaskCompletionFailure(reason: .unavailable) }
            _ = try await journal.begin(command, resolving: resolving, lease: lease); try check()
            guard resolving || canSend(command) else { throw ChildTaskCompletionFailure(reason: .unavailable) }
            let proof: MixedTaskCompletionResolution
            do { proof = try await service.mixedTaskCompletion(command, session: scope.session, close: resolving) }
            catch is CancellationError { throw CancellationError() }
            catch let failure as ChildTaskCompletionFailure { throw failure }
            catch let required as AccountSessionAuthorizationRequired { throw required }
            catch { throw ChildTaskCompletionFailure(reason: .unconfirmed) }
            try check()
            guard let checked = try? command.resolution(proof.raw), checked == proof, resolving || proof.applied else { throw ChildTaskCompletionFailure(reason: .unconfirmed) }
            try await journal.settle(command, decision: proof, lease: lease); try check(); return proof
        } catch { try check(); throw error }
    }
}

@MainActor @Observable final class MixedTaskCompletionRecoveryModel {
    private(set) var entries: [MixedTaskCompletionState.Entry] = []
    private(set) var loaded = false
    private(set) var busy = false
    private(set) var message: String?
    private let scope: ChildTaskFieldClientScope
    private let journal: MixedTaskCompletionJournal
    private let sender: MixedTaskCompletionSender
    private let current: () -> ChildTaskFieldClientScope?
    private let canQueue: (MixedTaskCompletionCommand) -> Bool
    private let canSend: (MixedTaskCompletionCommand) -> Bool
    private let refresh: () async -> Void
    private let lease = CalendarReadLease()
    private var closed = false
    init(scope: ChildTaskFieldClientScope, journal: MixedTaskCompletionJournal, service: any MixedTaskCompletionService,
         current: @escaping () -> ChildTaskFieldClientScope?, canQueue: @escaping (MixedTaskCompletionCommand) -> Bool,
         canSend: @escaping (MixedTaskCompletionCommand) -> Bool, refresh: @escaping () async -> Void) {
        self.scope = scope; self.journal = journal; self.current = current; self.canQueue = canQueue; self.canSend = canSend; self.refresh = refresh
        sender = .init(scope: scope, journal: journal, service: service, current: current, canSend: canSend)
    }
    func close() { closed = true; lease.cancel(); sender.close(); entries = []; loaded = false; busy = false; message = nil }
    private func check() throws { try Task.checkCancellation(); try lease.check(); guard !closed, current() == scope else { throw CancellationError() } }
    private func update() async throws { let state = try await journal.load(); try check(); entries = state.entries; loaded = true }
    private func recover(_ error: Error) async {
        guard (try? check()) != nil else { close(); return }
        do { try await update() } catch { entries = []; loaded = false }
        guard (try? check()) != nil else { close(); return }
        if error is CancellationError { return }
        if error is ChildTaskActionAdmissionFailure { message = ChildTaskActionAdmissionFailure().localizedDescription }
        else if let value = error as? ChildTaskCompletionCapacityFailure { message = value.localizedDescription }
        else if let value = error as? ChildTaskCompletionFailure { message = value.localizedDescription }
        else if error is AccountSessionAuthorizationRequired { message = "Sign in again to check this saved selection. Your work is kept." }
        else { message = "This selection couldn’t be confirmed. Your saved work is kept; review it before trying again." }
    }
    func load() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try check(); try await update() } catch { await recover(error) }
    }
    private func sendSaved(_ command: MixedTaskCompletionCommand, resolving: Bool = false) async throws {
        let proof = try await sender.send(command, resolving: resolving); try check(); try await update()
        if proof.applied { await refresh(); try check() }
        message = proof.closed ? "The original selection was stopped. Review current tasks before saving a fresh action." : command.isUndo ? "Selection Undo confirmed." : "Selection confirmed."
    }
    @discardableResult func perform(_ command: MixedTaskCompletionCommand) async -> Bool {
        guard !busy else { return false }; busy = true; defer { busy = false }
        do {
            try check(); guard command.account == scope.account, command.origin == scope.origin, canQueue(command) else { throw ChildTaskCompletionFailure(reason: .unavailable) }
            try await journal.enqueue(command, lease: lease); try check(); try await update()
            if canSend(command) { try await sendSaved(command) }
            else { message = "Selection saved for later. No task change is confirmed yet." }
            return entries.contains { $0.command == command && $0.phase == .confirmed }
        } catch { await recover(error); return false }
    }
    func send(_ command: MixedTaskCompletionCommand, resolving: Bool = false) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try check(); try await sendSaved(command, resolving: resolving) } catch { await recover(error) }
    }
    @discardableResult func undo(_ entry: MixedTaskCompletionState.Entry, reads: [String: ChildTaskRecordRead]) async -> MixedTaskCompletionCommand? {
        guard !busy else { return nil }; busy = true; defer { busy = false }
        do {
            try check(); guard entries.contains(entry), entry.phase == .confirmed, let proof = entry.proof,
                  reads.values.allSatisfy({ ChildTaskFieldClientScope($0.context) == scope }) else { throw MixedTaskCompletionState.invalid }
            let command = try entry.command.undo(reads: reads, decision: proof)
            guard canQueue(command) else { throw ChildTaskCompletionFailure(reason: .unavailable) }
            try await journal.enqueue(command, lease: lease); try check(); try await update()
            if canSend(command) { try await sendSaved(command) } else { message = "Selection Undo saved for later. The tasks have not changed yet." }
            return command
        } catch { await recover(error); return nil }
    }
    func discard(_ command: MixedTaskCompletionCommand) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try check(); try await journal.discard(command, lease: lease); try check(); try await update(); message = "Saved record removed from this device. Task changes are kept." }
        catch { await recover(error) }
    }
}

struct MixedTaskListUndo: Equatable, Sendable {
    let scope: ChildTaskFieldClientScope
    let command: MixedTaskCompletionCommand
}
struct MixedTaskListResult {
    let message: String
    let undo: MixedTaskListUndo?
    var needsReview = false
    var redo: MixedTaskListUndo? = nil
}

/// Bridges confirmed asynchronous changes into native Undo/Redo. The inverse is
/// registered synchronously while UndoManager is undoing; its payload becomes
/// available only after the asynchronous operation confirms the next state.
@MainActor @Observable final class ConfirmedHistoryBridge {
    struct Step {
        let name: String
        let key: String?
        let retained: () -> Bool
        let available: () -> Bool
        let immediate: (() -> Step?)?
        let perform: () async -> Step?
        init(name: String, key: String? = nil, retained: @escaping () -> Bool, available: @escaping () -> Bool = { true }, immediate: (() -> Step?)? = nil, perform: @escaping () async -> Step? = { nil }) {
            self.name = name; self.key = key; self.retained = retained; self.available = available; self.immediate = immediate; self.perform = perform
        }
    }
    private final class Frame: NSObject {
        var step: Step?
        init(_ step: Step) { self.step = step }
    }
    let manager: UndoManager
    private var frames: [Frame] = []
    private var cursor = 0
    private var generation = UUID()
    private(set) var busy = false
    private let unavailable: () -> Void
    var canUndo: Bool { !busy && manager.canUndo && cursor > 0 && frames[cursor - 1].step.map { $0.retained() && $0.available() } == true }
    var canRedo: Bool { !busy && manager.canRedo && cursor < frames.count && frames[cursor].step.map { $0.retained() && $0.available() } == true }
    init(manager: UndoManager, unavailable: @escaping () -> Void = {}) { self.manager = manager; self.unavailable = unavailable }
    func record(_ step: Step) {
        guard step.retained() else { return }
        if busy { clear() } // A new edit owns history; late confirmations stay in saved recovery.
        for frame in frames.dropFirst(cursor) { manager.removeAllActions(withTarget: frame) }
        frames.removeSubrange(cursor...)
        let frame = Frame(step); frames.append(frame); cursor = frames.count
        manager.beginUndoGrouping(); install(frame); manager.endUndoGrouping()
        while frames.count > 30 { let old = frames.removeFirst(); manager.removeAllActions(withTarget: old); cursor -= 1 }
    }
    func contains(key: String) -> Bool { frames.contains { $0.step?.key == key } }
    func canRedo(key: String) -> Bool { canRedo && frames[cursor].step?.key == key }
    func canUndo(key: String) -> Bool { canUndo && frames[cursor - 1].step?.key == key }
    func undo() { guard canUndo else { return }; manager.undo() }
    func redo() { guard canRedo else { return }; manager.redo() }
    func clear() {
        generation = UUID()
        for frame in frames { frame.step = nil; manager.removeAllActions(withTarget: frame) }
        frames = []; cursor = 0; busy = false
    }
    private func remove(_ frame: Frame) {
        manager.removeAllActions(withTarget: frame)
        if let index = frames.firstIndex(where: { $0 === frame }) { frames.remove(at: index); if index < cursor { cursor -= 1 } }
        frame.step = nil
    }
    private func install(_ frame: Frame) {
        manager.registerUndo(withTarget: frame) { [weak self] target in self?.invoke(target) }
        if let step = frame.step { manager.setActionName(step.name) }
    }
    private func invoke(_ frame: Frame) {
        if busy { generation = UUID(); busy = false; remove(frame); unavailable(); return }
        let undoing = manager.isUndoing
        let expected = undoing ? (cursor > 0 ? frames[cursor - 1] : nil) : (cursor < frames.count ? frames[cursor] : nil)
        guard !busy, expected === frame, let step = frame.step, step.retained(), step.available() else {
            remove(frame); unavailable(); return
        }
        let captured = generation
        cursor += undoing ? -1 : 1
        // Must happen before returning to UndoManager, never after awaiting.
        install(frame); frame.step = nil; busy = true
        if let immediate = step.immediate {
            let next = immediate(); busy = false
            guard step.retained(), let next, next.retained() else { remove(frame); return }
            frame.step = next; return
        }
        Task { [weak self, weak frame] in
            let next = await step.perform()
            guard let self, let frame, self.generation == captured, self.frames.contains(where: { $0 === frame }) else { return }
            self.busy = false
            guard step.retained(), let next, next.retained() else { self.remove(frame); return }
            frame.step = next
        }
    }
}
