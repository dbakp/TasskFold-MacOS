import Foundation
import CryptoKit

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
        guard try JSONEncoder().encode(self).count <= Self.maximumStoredBytes else { throw Self.invalid }
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

struct ChildTaskCompletionJournalState: ReviewedTeamFileCommand, CustomStringConvertible, CustomDebugStringConvertible {
    enum Phase: String, Codable, Sendable { case queued, attempted, confirmed }
    struct Entry: Codable, Equatable, Sendable {
        let command: ChildTaskCompletionCommand
        var phase: Phase
        var receipt: ChildTaskCompletionReceipt?
        init(command: ChildTaskCompletionCommand, phase: Phase, receipt: ChildTaskCompletionReceipt?) { self.command = command; self.phase = phase; self.receipt = receipt }
        private enum CodingKeys: String, CodingKey { case command, phase, receipt }
        init(from decoder: Decoder) throws {
            try completionKeys(decoder, ["command", "phase", "receipt"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            command = try c.decode(ChildTaskCompletionCommand.self, forKey: .command); phase = try c.decode(Phase.self, forKey: .phase)
            receipt = try c.decodeIfPresent(ChildTaskCompletionReceipt.self, forKey: .receipt)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(command, forKey: .command); try c.encode(phase, forKey: .phase); try c.encode(receipt, forKey: .receipt)
        }
    }
    static let storagePrefix = "child-completion-journal-v1."
    static let fileName = "requests.taskfoldchildcompletions"
    static let encryptionContext = "com.taskfold.child-completion-journal.v1"
    static let maximumStoredBytes = 2_100_000
    static var invalid: AppFailure { ChildTaskCompletionDraft.invalid }
    let account: String, origin: String
    var entries: [Entry]
    var description: String { "Private child completion journal" }
    var debugDescription: String { description }
    init(account: String, origin: String, entries: [Entry] = []) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard origin.utf8.count <= 2048, entries.count <= 64 else { throw Self.invalid }
        var ids: Set<String> = []
        for entry in entries {
            let command = entry.command
            guard command.account == account, command.origin == origin, ids.insert(command.id).inserted else { throw Self.invalid }
            if entry.phase == .confirmed { guard let proof = entry.receipt, try command.confirmed(proof.raw) == proof else { throw Self.invalid } }
            else { guard entry.receipt == nil else { throw Self.invalid } }
        }
        var undoSources: Set<String> = []
        for entry in entries {
            if let source = entry.command.original {
                guard let parent = entries.first(where: { $0.command.id == source.body["request_id"]?.text }), parent.phase == .confirmed,
                      parent.command.original == nil, parent.command.body == source.body,
                      let receipt = parent.receipt, receipt.agrees(ChildTaskCompletionReceipt(raw: source.receipt)),
                      undoSources.insert(parent.command.id).inserted else { throw Self.invalid }
            }
        }
        self.account = account; self.origin = origin; self.entries = entries
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
        let state = try JSONDecoder().decode(ChildTaskCompletionJournalState.self, from: data)
        guard state.account == account, state.origin == origin else { throw ChildTaskCompletionDraft.invalid }; return state
    }
    private func write(_ state: ChildTaskCompletionJournalState, lease: CalendarReadLease) throws {
        _ = try ChildTaskCompletionJournalState(account: account, origin: origin, entries: state.entries)
        let data = try JSONEncoder().encode(state)
        guard data.count <= ChildTaskCompletionJournalState.maximumStoredBytes else { throw ChildTaskCompletionDraft.invalid }
        try lease.check(); try io.write(data, key: key)
    }
    func load() throws -> ChildTaskCompletionJournalState { try guarded(lease: nil) { try read() } }
    /// Never coalesce completion transitions, including provably unsent ones.
    func enqueue(_ command: ChildTaskCompletionCommand, lease: CalendarReadLease) throws {
        try guarded(lease: lease) {
            guard command.account == account, command.origin == origin else { throw ChildTaskCompletionDraft.invalid }
            var state = try read()
            if let old = state.entries.first(where: { $0.command.id == command.id }) { guard old.command == command else { throw ChildTaskCompletionDraft.invalid }; return }
            state.entries.append(.init(command: command, phase: .queued, receipt: nil)); try write(state, lease: lease)
        }
    }
    func attempt(_ command: ChildTaskCompletionCommand, lease: CalendarReadLease) throws -> ChildTaskCompletionJournalState.Entry {
        try guarded(lease: lease) {
            var state = try read()
            guard let i = state.entries.firstIndex(where: { $0.command == command }),
                  !state.entries[..<i].contains(where: { $0.phase != .confirmed && $0.command.sameTarget(command) }) else { throw ChildTaskCompletionDraft.invalid }
            if state.entries[i].phase == .queued { state.entries[i].phase = .attempted; try write(state, lease: lease) }
            return state.entries[i]
        }
    }
    func confirm(_ command: ChildTaskCompletionCommand, receipt: ChildTaskCompletionReceipt, lease: CalendarReadLease) throws {
        try guarded(lease: lease) {
            _ = try command.confirmed(receipt.raw)
            var state = try read()
            guard let i = state.entries.firstIndex(where: { $0.command == command }), state.entries[i].phase != .queued else { throw ChildTaskCompletionDraft.invalid }
            if let old = state.entries[i].receipt { guard old.agrees(receipt) else { throw ChildTaskCompletionDraft.invalid }; return }
            state.entries[i].phase = .confirmed; state.entries[i].receipt = receipt; try write(state, lease: lease)
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
struct ChildTaskCompletionFailure: LocalizedError {
    let reason: ChildTaskFieldWriteFailure.Reason
    var errorDescription: String? {
        switch reason {
        case .unavailable: return "Completion is unavailable or access changed. Your saved request is kept."
        case .review, .closed: return "This completion needs review. Your original saved request is kept."
        case .busy: return "Another action is finishing. Retry the same saved completion shortly."
        case .limit: return "Completion has reached a service limit. Your saved request is kept."
        case .unconfirmed: return "The completion result couldn’t be confirmed. Your original saved request is kept."
        }
    }
}
@MainActor protocol ChildTaskCompletionCommandService: AnyObject {
    func childTaskCompletionCommand(_ command: ChildTaskCompletionCommand, session: UUID) async throws -> ChildTaskCompletionReceipt
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
    func send(_ command: ChildTaskCompletionCommand) async throws -> ChildTaskCompletionReceipt {
        do {
            try check(); guard command.account == scope.account, command.origin == scope.origin else { throw CancellationError() }
            let state = try await journal.load(); try check()
            guard let entry = state.entries.first(where: { $0.command == command }) else { throw ChildTaskCompletionDraft.invalid }
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
