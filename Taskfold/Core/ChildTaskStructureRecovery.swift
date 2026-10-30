import Foundation
import CryptoKit

struct ChildTaskStructureFailure: LocalizedError {
    let reason: ChildTaskFieldWriteFailure.Reason
    var errorDescription: String? {
        switch reason {
        case .unavailable: return "Hierarchy editing is unavailable or access changed. Your saved request is kept."
        case .review: return "This hierarchy change needs review. Your original saved request is kept."
        case .closed: return "This original hierarchy request is closed. Review current values before saving another action."
        case .busy: return "Another action is finishing. Retry the same saved hierarchy request shortly."
        case .limit: return "Review saved hierarchy actions and Undo content before adding more. Your saved work is kept."
        case .unconfirmed: return "The hierarchy result couldn’t be confirmed. Your original saved request is kept."
        }
    }
}
struct ChildTaskStructureCapacityFailure: LocalizedError {
    var errorDescription: String? { "Review saved hierarchy actions before adding another. Pending, stopped and restorable deleted work is kept." }
}
extension ChildTaskStructureCommand {
    func sameRoot(_ other: Self) -> Bool {
        account == other.account && origin == other.origin && ["task_id", "task_generation", "project_id"].allSatisfy { Self.exact(body[$0], other.body[$0]) }
    }
    var familyID: String { original?.receipt["request_id"]?.text ?? id }
    func replaces(_ old: Self) -> Bool {
        guard sameRoot(old), action == old.action, id != old.id, body["structure_revision"]!.integer >= old.body["structure_revision"]!.integer else { return false }
        switch action {
        case .insert: return Self.exact(body["node"], old.body["node"])
        case .move, .delete: return ["node_key", "incarnation"].allSatisfy { Self.exact(body[$0], old.body[$0]) }
        case .undo:
            guard let a = original, let b = old.original,
                  let first = try? ChildTaskStructureReceipt(account: account, raw: a.receipt),
                  let second = try? ChildTaskStructureReceipt(account: account, raw: b.receipt) else { return false }
            return first.agrees(second)
        }
    }
}

struct ChildTaskStructureJournalState: ReviewedTeamFileCommand, CustomStringConvertible, CustomDebugStringConvertible {
    enum Phase: String, Codable, Sendable { case queued, attempted, confirmed, closed }
    struct Entry: Codable, Equatable, Sendable {
        let command: ChildTaskStructureCommand
        var phase: Phase
        var receipt: ChildTaskStructureReceipt?
        var resolution: ChildTaskStructureResolution?
        init(command: ChildTaskStructureCommand, phase: Phase = .queued, receipt: ChildTaskStructureReceipt? = nil, resolution: ChildTaskStructureResolution? = nil) {
            self.command = command; self.phase = phase; self.receipt = receipt; self.resolution = resolution
        }
        private enum CodingKeys: String, CodingKey { case command, phase, receipt, resolution }
        init(from decoder: Decoder) throws {
            try structureKeys(decoder, ["command", "phase", "receipt", "resolution"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            command = try c.decode(ChildTaskStructureCommand.self, forKey: .command); phase = try c.decode(Phase.self, forKey: .phase)
            receipt = try c.decodeIfPresent(ChildTaskStructureReceipt.self, forKey: .receipt); resolution = try c.decodeIfPresent(ChildTaskStructureResolution.self, forKey: .resolution)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(command, forKey: .command); try c.encode(phase, forKey: .phase)
            try c.encode(receipt, forKey: .receipt); try c.encode(resolution, forKey: .resolution)
        }
    }
    struct Disposal: Codable, Equatable, Sendable {
        let source: ChildTaskStructureReceipt
        var phase: Phase
        var receipt: ChildTaskStructureUndoDisposalReceipt?
        var id: String { source.raw["request_id"]!.text }
        init(source: ChildTaskStructureReceipt, phase: Phase = .queued, receipt: ChildTaskStructureUndoDisposalReceipt? = nil) { self.source = source; self.phase = phase; self.receipt = receipt }
        private enum CodingKeys: String, CodingKey { case source, phase, receipt }
        init(from decoder: Decoder) throws {
            try structureKeys(decoder, ["source", "phase", "receipt"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = try c.decode(ChildTaskStructureReceipt.self, forKey: .source); phase = try c.decode(Phase.self, forKey: .phase)
            receipt = try c.decodeIfPresent(ChildTaskStructureUndoDisposalReceipt.self, forKey: .receipt)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(source, forKey: .source); try c.encode(phase, forKey: .phase); try c.encode(receipt, forKey: .receipt)
        }
    }
    static let storagePrefix = "child-structure-journal-v1."
    static let fileName = "requests.taskfoldchildstructure"
    static let encryptionContext = "com.taskfold.child-structure-journal.v1"
    static let maximumStoredBytes = 8_400_000
    static let maximumEntries = 64
    static var invalid: AppFailure { ChildTaskStructureCommand.invalid }
    let account: String, origin: String
    var entries: [Entry]
    var disposals: [Disposal]
    var description: String { "Private child hierarchy journal" }
    var debugDescription: String { description }
    init(account: String, origin: String, entries: [Entry] = [], disposals: [Disposal] = []) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard origin.utf8.count <= 2048, entries.count <= Self.maximumEntries, disposals.count <= Self.maximumEntries else { throw Self.invalid }
        var ids = Set<String>(), undoIDs = Set<String>(), disposalIDs = Set<String>()
        for entry in entries {
            let command = entry.command
            guard command.account == account, command.origin == origin, ids.insert(command.id).inserted else { throw Self.invalid }
            switch entry.phase {
            case .confirmed: guard let receipt = entry.receipt, try command.confirmed(receipt.raw) == receipt, entry.resolution == nil else { throw Self.invalid }
            case .closed: guard entry.receipt == nil, let result = entry.resolution, try ChildTaskStructureResolution(command: command, raw: result.raw) == result, result.closed else { throw Self.invalid }
            case .queued, .attempted: guard entry.receipt == nil, entry.resolution == nil else { throw Self.invalid }
            }
            if let original = command.original {
                if entry.phase != .closed { guard undoIDs.insert(command.familyID).inserted else { throw Self.invalid } }
                if let parent = entries.first(where: { $0.command.id == command.familyID }) {
                    guard parent.phase == .confirmed, let proof = parent.receipt,
                          let expected = try? ChildTaskStructureReceipt(account: account, raw: original.receipt), proof.agrees(expected) else { throw Self.invalid }
                    if let body = original.body { guard ChildTaskStructureCommand.exact(.object(body), .object(parent.command.body)) else { throw Self.invalid } }
                }
            }
        }
        for item in disposals {
            guard item.source.raw["account"] == .string(account), item.source.raw["action"] == .string("delete"),
                  disposalIDs.insert(item.id).inserted, !undoIDs.contains(item.id), item.phase != .closed else { throw Self.invalid }
            _ = try ChildTaskStructureReceipt(account: account, raw: item.source.raw)
            if let parent = entries.first(where: { $0.command.id == item.id }) {
                guard parent.phase == .confirmed, let receipt = parent.receipt, receipt.agrees(item.source) else { throw Self.invalid }
            }
            let action = try ChildTaskStructureUndoDisposal(account: account, origin: origin, requestID: item.id)
            if item.phase == .confirmed { guard let receipt = item.receipt, try action.confirmed(receipt.raw) == receipt else { throw Self.invalid } }
            else { guard item.receipt == nil else { throw Self.invalid } }
        }
        self.account = account; self.origin = origin; self.entries = entries; self.disposals = disposals
    }
    /// Families retain complete Undo lineage. A confirmed deletion still owns
    /// private server content until Undo/disposal is confirmed; never prune it
    /// merely because its original task mutation was acknowledged.
    mutating func makeRoom(preserving request: String? = nil) throws {
        func fits() throws -> Bool {
            try entries.count <= Self.maximumEntries && disposals.count <= Self.maximumEntries && JSONEncoder().encode(self).count <= Self.maximumStoredBytes
        }
        guard try !fits() else { return }
        let order = entries.map { $0.command.familyID } + disposals.map(\.id)
        var latest: [String: Int] = [:]
        for (index, family) in order.enumerated() { latest[family] = index }
        for family in latest.sorted(by: { $0.value < $1.value }).map(\.key) {
            let rows = entries.filter { $0.command.familyID == family }, cleanup = disposals.filter { $0.id == family }
            guard !rows.contains(where: { $0.command.id == request }), !cleanup.contains(where: { $0.id == request }),
                  rows.allSatisfy({ $0.phase == .confirmed }), cleanup.allSatisfy({ $0.phase == .confirmed }) else { continue }
            let deleted = rows.contains { $0.command.action == .delete }
            let undone = rows.contains { $0.command.action == .undo && $0.phase == .confirmed }
            guard !deleted || undone || !cleanup.isEmpty else { continue }
            entries.removeAll { $0.command.familyID == family }; disposals.removeAll { $0.id == family }
            if try fits() { return }
        }
        throw ChildTaskStructureCapacityFailure()
    }
    init(data: Data) throws {
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: Self.maximumStoredBytes)
        let raw = try JSONDecoder().decode([String: JSON].self, from: data)
        var paths: Set<[String]> = [["version"]]
        for entry in raw["entries"]?.list ?? [] {
            let command = entry.object["command"]?.object ?? [:], prefix = ["entries", "[]", "command"]
            paths.formUnion(ChildTaskStructureCommand.counterPaths(command["body"]?.object ?? [:], prefix: prefix + ["body"]))
            if case .object(let original)? = command["original"] {
                paths.formUnion(ChildTaskStructureCommand.counterPaths(original["body"]?.object ?? [:], prefix: prefix + ["original", "body"]))
                paths.formUnion(ChildTaskStructureReceipt.integerPaths.map { prefix + ["original", "receipt"] + $0 })
            }
        }
        for prefix in [["entries", "[]", "receipt", "raw"], ["entries", "[]", "resolution", "raw", "receipt"], ["disposals", "[]", "source", "raw"]] {
            paths.formUnion(ChildTaskStructureReceipt.integerPaths.map { prefix + $0 })
        }
        paths.formUnion([["entries", "[]", "resolution", "raw", "protocol"], ["disposals", "[]", "receipt", "raw", "protocol"]])
        try ChildTaskRecordRead.validateUniqueJSON(data, maximum: Self.maximumStoredBytes, integerPaths: paths)
        self = try JSONDecoder().decode(Self.self, from: data)
    }
    private enum CodingKeys: String, CodingKey { case version, account, origin, entries, disposals }
    init(from decoder: Decoder) throws {
        try structureKeys(decoder, ["version", "account", "origin", "entries", "disposals"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .version) == 1 else { throw Self.invalid }
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), entries: c.decode([Entry].self, forKey: .entries), disposals: c.decode([Disposal].self, forKey: .disposals))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .version); try c.encode(account, forKey: .account); try c.encode(origin, forKey: .origin)
        try c.encode(entries, forKey: .entries); try c.encode(disposals, forKey: .disposals)
    }
}
struct ChildTaskStructureJournalFileIO: CalendarSecureItemIO {
    let base: ReviewedTeamCommandFileIO<ChildTaskStructureJournalState>
    init(directory: URL, account: String, origin: String, encryptionKey: @escaping @Sendable () throws -> SymmetricKey) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        base = .init(directory: directory.appendingPathComponent(account).appendingPathComponent(CalendarOAuthConfiguration.digest(origin)), account: account, origin: origin, encryptionKey: encryptionKey)
    }
    var file: URL { base.file }
    func read(key: String) throws -> Data? { try base.read(key: key) }
    func write(_ data: Data, key: String) throws { try base.write(data, key: key) }
    func remove(key: String) throws { try base.remove(key: key) }
}
actor ChildTaskStructureJournal {
    private let io: any CalendarSecureItemIO
    private let lock: AutomationEnrollmentProcessLock
    private let removalDirectory: URL
    let account: String, origin: String
    private var key: String { ChildTaskStructureJournalState.storagePrefix + account + "." + CalendarOAuthConfiguration.digest(origin) }
    init(account: String, origin: String, io: any CalendarSecureItemIO, coordinationDirectory: URL, removalDirectory: URL) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        self.account = account; self.origin = origin; self.io = io; lock = .init(directory: coordinationDirectory); self.removalDirectory = removalDirectory
    }
    private func guarded<T>(lease: CalendarReadLease?, _ action: () throws -> T) throws -> T {
        try lock.withExclusive(account: account, check: { try lease?.check() }) {
            try AccountRemovalDisk(directory: removalDirectory, account: account).writable { try lease?.check(); return try action() }
        }
    }
    private func read() throws -> ChildTaskStructureJournalState {
        guard let data = try io.read(key: key) else { return try .init(account: account, origin: origin) }
        let state = try ChildTaskStructureJournalState(data: data)
        guard state.account == account, state.origin == origin else { throw ChildTaskStructureCommand.invalid }; return state
    }
    private func write(_ candidate: ChildTaskStructureJournalState, lease: CalendarReadLease, preserving request: String? = nil) throws {
        var state = candidate; try state.makeRoom(preserving: request)
        _ = try ChildTaskStructureJournalState(account: account, origin: origin, entries: state.entries, disposals: state.disposals)
        let data = try JSONEncoder().encode(state)
        guard data.count <= ChildTaskStructureJournalState.maximumStoredBytes else { throw ChildTaskStructureCapacityFailure() }
        try lease.check(); try io.write(data, key: key)
    }
    func load() throws -> ChildTaskStructureJournalState { try guarded(lease: nil) { try read() } }
    func enqueue(_ command: ChildTaskStructureCommand, lease: CalendarReadLease) throws {
        try guarded(lease: lease) {
            guard command.account == account, command.origin == origin else { throw ChildTaskStructureCommand.invalid }
            var state = try read()
            if let old = state.entries.first(where: { $0.command.id == command.id }) {
                guard old.command == command else { throw ChildTaskStructureCommand.invalid }
                guard old.phase != .closed else { throw ChildTaskStructureFailure(reason: .closed) }; return
            }
            state.entries.append(.init(command: command)); try write(state, lease: lease)
        }
    }
    func attempt(_ command: ChildTaskStructureCommand, lease: CalendarReadLease) throws -> ChildTaskStructureJournalState.Entry {
        try guarded(lease: lease) {
            var state = try read()
            guard let index = state.entries.firstIndex(where: { $0.command == command }),
                  !state.entries[..<index].contains(where: { $0.phase != .confirmed && $0.phase != .closed && $0.command.sameRoot(command) }) else { throw ChildTaskStructureCommand.invalid }
            guard state.entries[index].phase != .closed else { throw ChildTaskStructureFailure(reason: .closed) }
            if state.entries[index].phase == .queued { state.entries[index].phase = .attempted; try write(state, lease: lease) }
            return state.entries[index]
        }
    }
    func confirm(_ command: ChildTaskStructureCommand, receipt: ChildTaskStructureReceipt, lease: CalendarReadLease) throws {
        try guarded(lease: lease) {
            _ = try command.confirmed(receipt.raw)
            var state = try read()
            guard let index = state.entries.firstIndex(where: { $0.command == command }), state.entries[index].phase != .queued, state.entries[index].phase != .closed else { throw ChildTaskStructureCommand.invalid }
            if let old = state.entries[index].receipt { guard old.agrees(receipt) else { throw ChildTaskStructureCommand.invalid }; return }
            var entry = state.entries.remove(at: index); entry.phase = .confirmed; entry.receipt = receipt
            state.entries.append(entry); try write(state, lease: lease, preserving: command.id)
        }
    }
    func beginResolution(_ command: ChildTaskStructureCommand, lease: CalendarReadLease) throws -> ChildTaskStructureJournalState.Entry {
        try guarded(lease: lease) {
            var state = try read()
            guard let index = state.entries.firstIndex(where: { $0.command == command }) else { throw ChildTaskStructureCommand.invalid }
            if state.entries[index].phase == .queued { state.entries[index].phase = .attempted; try write(state, lease: lease) }
            return state.entries[index]
        }
    }
    func resolve(_ command: ChildTaskStructureCommand, decision: ChildTaskStructureResolution, lease: CalendarReadLease) throws {
        try guarded(lease: lease) {
            _ = try ChildTaskStructureResolution(command: command, raw: decision.raw)
            var state = try read()
            guard let index = state.entries.firstIndex(where: { $0.command == command }), state.entries[index].phase != .queued else { throw ChildTaskStructureCommand.invalid }
            if state.entries[index].phase == .closed { guard state.entries[index].resolution == decision else { throw ChildTaskStructureCommand.invalid }; return }
            if let old = state.entries[index].receipt { guard let proof = decision.receipt, old.agrees(proof) else { throw ChildTaskStructureCommand.invalid }; return }
            if let proof = decision.receipt {
                var entry = state.entries.remove(at: index); entry.phase = .confirmed; entry.receipt = proof; state.entries.append(entry)
            } else { state.entries[index].phase = .closed; state.entries[index].resolution = decision }
            try write(state, lease: lease, preserving: command.id)
        }
    }
    func replaceClosed(_ original: ChildTaskStructureCommand, with replacement: ChildTaskStructureCommand, lease: CalendarReadLease) throws {
        try guarded(lease: lease) {
            var state = try read()
            guard let entry = state.entries.first(where: { $0.command == original }), entry.phase == .closed, entry.resolution?.closed == true,
                  replacement.replaces(original), !state.entries.contains(where: { $0.command.id == replacement.id || ($0.phase != .confirmed && $0.phase != .closed && $0.command.sameRoot(replacement)) }) else { throw ChildTaskStructureCommand.invalid }
            state.entries.append(.init(command: replacement)); try write(state, lease: lease)
        }
    }
    func discard(_ command: ChildTaskStructureCommand, lease: CalendarReadLease) throws {
        try guarded(lease: lease) {
            var state = try read()
            guard let index = state.entries.firstIndex(where: { $0.command == command }), state.entries[index].phase != .attempted else { throw ChildTaskStructureCommand.invalid }
            let family = state.entries.filter { $0.command.familyID == command.familyID }
            if state.entries[index].phase == .confirmed && family.contains(where: { $0.command.action == .undo && $0.phase == .confirmed }) {
                guard family.allSatisfy({ $0.phase == .confirmed }) else { throw ChildTaskStructureCommand.invalid }
                state.entries.removeAll { $0.command.familyID == command.familyID }
            } else {
                guard !state.entries.contains(where: { $0.command.body["undo_of"] == .string(command.id) }) else { throw ChildTaskStructureCommand.invalid }
                if state.entries[index].phase == .confirmed && command.action == .delete {
                    guard state.disposals.contains(where: { $0.id == command.id && $0.phase == .confirmed }) else { throw ChildTaskStructureCommand.invalid }
                }
                state.entries.remove(at: index)
            }
            try write(state, lease: lease)
        }
    }
    /// Called only after explicit permanent-disposal confirmation in the UI.
    /// Server-owned discovery permits this even after local journal loss.
    func enqueueDisposal(_ source: ChildTaskStructureReceipt, lease: CalendarReadLease) throws {
        try guarded(lease: lease) {
            var state = try read()
            if let old = state.disposals.first(where: { $0.id == source.raw["request_id"]?.text }) {
                guard old.source.agrees(source) else { throw ChildTaskStructureCommand.invalid }; return
            }
            state.disposals.append(.init(source: source)); try write(state, lease: lease)
        }
    }
    func attemptDisposal(_ requestID: String, lease: CalendarReadLease) throws -> ChildTaskStructureJournalState.Disposal {
        try guarded(lease: lease) {
            var state = try read()
            guard let index = state.disposals.firstIndex(where: { $0.id == requestID }) else { throw ChildTaskStructureCommand.invalid }
            if state.disposals[index].phase == .queued { state.disposals[index].phase = .attempted; try write(state, lease: lease) }
            return state.disposals[index]
        }
    }
    func confirmDisposal(_ requestID: String, receipt: ChildTaskStructureUndoDisposalReceipt, lease: CalendarReadLease) throws {
        try guarded(lease: lease) {
            let action = try ChildTaskStructureUndoDisposal(account: account, origin: origin, requestID: requestID)
            _ = try action.confirmed(receipt.raw)
            var state = try read()
            guard let index = state.disposals.firstIndex(where: { $0.id == requestID }), state.disposals[index].phase != .queued else { throw ChildTaskStructureCommand.invalid }
            if let old = state.disposals[index].receipt { guard old == receipt else { throw ChildTaskStructureCommand.invalid }; return }
            var entry = state.disposals.remove(at: index); entry.phase = .confirmed; entry.receipt = receipt; state.disposals.append(entry)
            try write(state, lease: lease, preserving: requestID)
        }
    }
    func discardDisposal(_ requestID: String, lease: CalendarReadLease) throws {
        try guarded(lease: lease) {
            var state = try read()
            guard let index = state.disposals.firstIndex(where: { $0.id == requestID }), state.disposals[index].phase == .queued else { throw ChildTaskStructureCommand.invalid }
            state.disposals.remove(at: index); try write(state, lease: lease)
        }
    }
    func removeAccount() throws { try lock.withExclusive(account: account) { try io.remove(key: key) } }
}

@MainActor protocol ChildTaskStructureCommandService: AnyObject {
    func childTaskStructureCommand(_ command: ChildTaskStructureCommand, session: UUID) async throws -> ChildTaskStructureReceipt
    func closeChildTaskStructureCommand(_ command: ChildTaskStructureCommand, session: UUID) async throws -> ChildTaskStructureResolution
    func childTaskStructureUndoArchives(account: String, origin: String, session: UUID) async throws -> ChildTaskStructureUndoArchives
    func forgetChildTaskStructureUndo(_ disposal: ChildTaskStructureUndoDisposal, session: UUID) async throws -> ChildTaskStructureUndoDisposalReceipt
}
extension Backend: ChildTaskStructureCommandService {}
@MainActor final class ChildTaskStructureSender {
    private let scope: ChildTaskFieldClientScope
    private let current: () -> ChildTaskFieldClientScope?
    private let canSend: (ChildTaskStructureCommand) -> Bool
    private let journal: ChildTaskStructureJournal
    private let service: any ChildTaskStructureCommandService
    private let lease = CalendarReadLease()
    private var closed = false
    init(scope: ChildTaskFieldClientScope, journal: ChildTaskStructureJournal, service: any ChildTaskStructureCommandService,
         current: @escaping () -> ChildTaskFieldClientScope?, canSend: @escaping (ChildTaskStructureCommand) -> Bool) {
        self.scope = scope; self.journal = journal; self.service = service; self.current = current; self.canSend = canSend
    }
    func close() { closed = true; lease.cancel() }
    private func check() throws { try lease.check(); guard !closed, current() == scope else { throw CancellationError() } }
    private func perform<T>(_ action: () async throws -> T) async throws -> T {
        do { try check(); let result = try await action(); try check(); return result }
        catch { try check(); if error is CancellationError || error is ChildTaskStructureFailure || error is ChildTaskStructureCapacityFailure || error is AccountSessionAuthorizationRequired { throw error }; throw ChildTaskStructureFailure(reason: .unconfirmed) }
    }
    func send(_ command: ChildTaskStructureCommand) async throws -> ChildTaskStructureReceipt {
        try await perform {
            guard command.account == scope.account, command.origin == scope.origin else { throw CancellationError() }
            let state = try await journal.load(); try check()
            guard let entry = state.entries.first(where: { $0.command == command }) else { throw ChildTaskStructureCommand.invalid }
            guard entry.phase != .closed else { throw ChildTaskStructureFailure(reason: .closed) }
            if let receipt = entry.receipt { return try command.confirmed(receipt.raw) }
            guard canSend(command) else { throw ChildTaskStructureFailure(reason: .unavailable) }
            _ = try await journal.attempt(command, lease: lease); try check()
            guard canSend(command) else { throw ChildTaskStructureFailure(reason: .unavailable) }
            let receipt = try await service.childTaskStructureCommand(command, session: scope.session); try check()
            _ = try command.confirmed(receipt.raw)
            try await journal.confirm(command, receipt: receipt, lease: lease); try check(); return receipt
        }
    }
    func resolve(_ command: ChildTaskStructureCommand) async throws -> ChildTaskStructureResolution {
        try await perform {
            guard command.account == scope.account, command.origin == scope.origin else { throw CancellationError() }
            let entry = try await journal.beginResolution(command, lease: lease); try check()
            if let resolution = entry.resolution { return try .init(command: command, raw: resolution.raw) }
            if let receipt = entry.receipt { return try .init(command: command, receipt: receipt) }
            let result = try await service.closeChildTaskStructureCommand(command, session: scope.session); try check()
            _ = try ChildTaskStructureResolution(command: command, raw: result.raw)
            try await journal.resolve(command, decision: result, lease: lease); try check(); return result
        }
    }
    func archives() async throws -> ChildTaskStructureUndoArchives {
        try await perform {
            let result = try await service.childTaskStructureUndoArchives(account: scope.account, origin: scope.origin, session: scope.session); try check()
            guard result.account == scope.account else { throw ChildTaskStructureCommand.invalid }; return result
        }
    }
    func dispose(_ requestID: String) async throws -> ChildTaskStructureUndoDisposalReceipt {
        try await perform {
            let entry = try await journal.attemptDisposal(requestID, lease: lease); try check()
            let action = try ChildTaskStructureUndoDisposal(account: scope.account, origin: scope.origin, requestID: requestID)
            if let receipt = entry.receipt { return try action.confirmed(receipt.raw) }
            let result = try await service.forgetChildTaskStructureUndo(action, session: scope.session); try check()
            _ = try action.confirmed(result.raw)
            try await journal.confirmDisposal(requestID, receipt: result, lease: lease); try check(); return result
        }
    }
}
