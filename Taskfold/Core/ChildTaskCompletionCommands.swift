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
    private let io: any CalendarSecureItemIO
    private let lock: AutomationEnrollmentProcessLock
    private let removalDirectory: URL
    let account: String, origin: String
    private var key: String { ChildTaskCompletionJournalState.storagePrefix + account + "." + CalendarOAuthConfiguration.digest(origin) }
    init(account: String, origin: String, io: any CalendarSecureItemIO, coordinationDirectory: URL, removalDirectory: URL) throws {
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
        if let value = error as? ChildTaskCompletionCapacityFailure { message = value.localizedDescription }
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
    let account: String, origin: String
    private let io: any CalendarSecureItemIO
    private let lock: AutomationEnrollmentProcessLock
    private let removalDirectory: URL
    private var key: String { ChildTaskCompletionBatchState.storagePrefix + account + "." + CalendarOAuthConfiguration.digest(origin) }
    init(account: String, origin: String, io: any CalendarSecureItemIO, coordinationDirectory: URL, removalDirectory: URL) throws {
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
        if let value = error as? ChildTaskCompletionCapacityFailure { message = value.localizedDescription }
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
