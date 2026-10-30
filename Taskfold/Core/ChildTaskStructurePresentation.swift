import Foundation
import Observation

/// Native screens share one scoped owner. Values are refreshed from the actual
/// task read; journal receipts are never used to patch the surrounding editor.
@MainActor @Observable final class ChildTaskStructurePresentation {
    private(set) var entries: [ChildTaskStructureJournalState.Entry] = []
    private(set) var disposals: [ChildTaskStructureJournalState.Disposal] = []
    private(set) var archives: [ChildTaskStructureReceipt] = []
    private(set) var loaded = false
    private(set) var archivesLoaded = false
    private(set) var busy = false
    private(set) var message: String?
    let scope: ChildTaskFieldClientScope
    private let journal: ChildTaskStructureJournal
    private let sender: ChildTaskStructureSender
    private let current: () -> ChildTaskFieldClientScope?
    private let canQueue: (ChildTaskStructureCommand) -> Bool
    private let lease = CalendarReadLease()
    private var closed = false
    init(scope: ChildTaskFieldClientScope, journal: ChildTaskStructureJournal, service: any ChildTaskStructureCommandService,
         current: @escaping () -> ChildTaskFieldClientScope?, canQueue: @escaping (ChildTaskStructureCommand) -> Bool,
         canSend: @escaping (ChildTaskStructureCommand) -> Bool) {
        self.scope = scope; self.journal = journal; self.current = current; self.canQueue = canQueue
        sender = .init(scope: scope, journal: journal, service: service, current: current, canSend: canSend)
    }
    func close() { closed = true; lease.cancel(); sender.close(); entries = []; disposals = []; archives = []; loaded = false; archivesLoaded = false; message = nil; busy = false }
    private func check() throws { try lease.check(); guard !closed, current() == scope else { throw CancellationError() } }
    private func update() async throws {
        let state = try await journal.load(); try check(); entries = state.entries; disposals = state.disposals; loaded = true
    }
    private func failure(_ error: Error) {
        guard (try? check()) != nil else { close(); return }
        if error is CancellationError { return }
        if error is AccountSessionAuthorizationRequired { message = "Sign in again to check saved actions. Your work is kept." }
        else if let error = error as? ChildTaskStructureFailure { message = error.localizedDescription }
        else if let error = error as? ChildTaskStructureCapacityFailure { message = error.localizedDescription }
        else { message = "This action couldn’t be completed. Your saved work is kept; review it before trying again." }
    }
    private func work(_ action: () async throws -> Void) async -> Bool {
        guard !busy else { return false }; busy = true; defer { busy = false }
        do { try check(); try await action(); try check(); return true }
        catch {
            do { try check(); try await update() } catch { entries = []; disposals = []; loaded = false }
            failure(error); return false
        }
    }
    func load() async { _ = await work { try await update() } }
    func discoverArchives() async {
        _ = await work {
            let values = try await sender.archives(); try check(); archives = values.entries; archivesLoaded = true
            message = values.entries.isEmpty ? "No saved deleted content to restore." : nil
        }
    }
    @discardableResult func queue(_ command: ChildTaskStructureCommand, read: ChildTaskStructureRead) async -> Bool {
        await work {
            guard ChildTaskFieldClientScope(read.context) == scope else { throw CancellationError() }
            try command.review(read)
            guard canQueue(command) else { throw ChildTaskStructureFailure(reason: .unavailable) }
            try await journal.enqueue(command, lease: lease); try check(); try await update()
            message = "Action saved on this device. Review and send it when ready."
        }
    }
    @discardableResult func send(_ command: ChildTaskStructureCommand) async -> Bool {
        await work {
            _ = try await sender.send(command); try check(); try await update()
            message = command.action == .undo ? "Undo confirmed." : command.action == .insert ? "Subtask added." : command.action == .move ? "Subtask moved." : "Subtasks removed."
        }
    }
    func stop(_ command: ChildTaskStructureCommand) async {
        _ = await work {
            let result = try await sender.resolve(command); try check(); try await update()
            message = result.closed ? "The action was stopped before applying. Review current values to save a fresh action." : "The action had already applied. Its confirmation is saved."
        }
    }
    @discardableResult func replace(_ entry: ChildTaskStructureJournalState.Entry, with command: ChildTaskStructureCommand, read: ChildTaskStructureRead) async -> Bool {
        await work {
            guard entries.contains(entry), entry.phase == .closed, ChildTaskFieldClientScope(read.context) == scope else { throw ChildTaskStructureCommand.invalid }
            try command.review(read)
            guard canQueue(command) else { throw ChildTaskStructureFailure(reason: .unavailable) }
            try await journal.replaceClosed(entry.command, with: command, lease: lease); try check(); try await update()
            message = "Fresh action saved. Review it before sending."
        }
    }
    func discard(_ command: ChildTaskStructureCommand) async {
        _ = await work { try await journal.discard(command, lease: lease); try check(); try await update(); message = "Saved history removed from this device. Your tasks are unchanged." }
    }
    /// The native caller must show permanent-disposal confirmation first.
    func dispose(_ source: ChildTaskStructureReceipt) async {
        _ = await work {
            guard source.raw["account"] == .string(scope.account) else { throw CancellationError() }
            try await journal.enqueueDisposal(source, lease: lease); try check(); try await update()
            _ = try await sender.dispose(source.raw["request_id"]!.text); try check(); try await update()
            archives.removeAll { $0.raw["request_id"] == source.raw["request_id"] }
            message = "Saved Undo content removed. This does not change your current tasks."
        }
    }
    func retryDisposal(_ entry: ChildTaskStructureJournalState.Disposal) async {
        _ = await work {
            guard disposals.contains(entry) else { throw ChildTaskStructureCommand.invalid }
            _ = try await sender.dispose(entry.id); try check(); try await update()
            archives.removeAll { $0.raw["request_id"] == .string(entry.id) }
            message = "Saved Undo content removed. This does not change your current tasks."
        }
    }
    func cancelUnsentDisposal(_ entry: ChildTaskStructureJournalState.Disposal) async {
        _ = await work { guard disposals.contains(entry) else { throw ChildTaskStructureCommand.invalid }; try await journal.discardDisposal(entry.id, lease: lease); try check(); try await update(); message = "Undo content kept." }
    }
    func hasUndoOrDisposal(_ request: String) -> Bool {
        entries.contains { $0.command.body["undo_of"] == .string(request) && $0.phase != .closed } || disposals.contains { $0.id == request }
    }
    var availableArchives: [ChildTaskStructureReceipt] { archives.filter { !hasUndoOrDisposal($0.raw["request_id"]!.text) } }
}

enum ChildTaskStructureReview {
    static func fresh(_ command: ChildTaskStructureCommand, read: ChildTaskStructureRead, parent: String?, index: Int, requestID: UUID = UUID()) throws -> ChildTaskStructureCommand {
        let candidate: ChildTaskStructureCommand
        switch command.action {
        case .insert: candidate = try .init(insert: command.body["node"]!, parent: parent, index: index, read: read, requestID: requestID)
        case .move: candidate = try .init(move: command.body["node_key"]!.text, parent: parent, index: index, read: read, requestID: requestID)
        case .delete: candidate = try .init(delete: command.body["node_key"]!.text, read: read, requestID: requestID)
        case .undo:
            guard let original = command.original else { throw ChildTaskStructureCommand.invalid }
            let receipt = try ChildTaskStructureReceipt(account: command.account, raw: original.receipt)
            if let body = original.body { candidate = try .init(undo: .init(account: command.account, origin: command.origin, body: body), receipt: receipt, read: read, requestID: requestID) }
            else { candidate = try .init(restoring: receipt, read: read, requestID: requestID) }
        }
        guard candidate.replaces(command) else { throw ChildTaskStructureCommand.invalid }
        return candidate
    }
    static func title(_ command: ChildTaskStructureCommand) -> String {
        switch command.action { case .insert: return "Add subtask"; case .move: return "Move subtask"; case .delete: return "Remove subtasks"; case .undo: return "Undo hierarchy change" }
    }
    static func status(_ phase: ChildTaskStructureJournalState.Phase) -> String {
        switch phase { case .queued: return "Saved · not sent"; case .attempted: return "Needs attention · original action kept"; case .confirmed: return "Confirmed · current tasks may have changed"; case .closed: return "Stopped · review to try again" }
    }
    static func destinations(_ read: ChildTaskStructureRead, moving key: String?) -> [ChildTaskRecordRead.Node] {
        let source = key.flatMap { read.records.nodes[$0] }
        return read.records.orderedNodes.filter { node in source == nil || !node.path.starts(with: source!.path) }
    }
    static func siblings(_ read: ChildTaskStructureRead, parent: String?, moving key: String?) -> [ChildTaskRecordRead.Node] {
        read.records.orderedNodes.filter { $0.parent == parent && $0.key != key }
    }
}

/// A row selection is not authority to retarget a later recreated task/node.
struct ChildTaskStructureOpening: Sendable {
    let scope: ChildTaskFieldClientScope
    let root: String
    let generation: JSON
    let project: JSON
    let node: String?
    let incarnation: String?
    init(read: ChildTaskStructureRead, node: String? = nil) throws {
        guard node == nil || read.records.nodes[node!] != nil else { throw ChildTaskStructureCommand.invalid }
        scope = .init(read.context); root = read.context.root.id; generation = read.context.root["task_generation"]; project = read.context.root["project_id"]
        self.node = node; incarnation = node.flatMap { read.records.nodes[$0]?.incarnation }
    }
    func validate(_ read: ChildTaskStructureRead) throws {
        guard scope == ChildTaskFieldClientScope(read.context), root == read.context.root.id,
              generation == read.context.root["task_generation"], project == read.context.root["project_id"] else { throw ChildTaskStructureCommand.invalid }
        if let node { guard read.records.nodes[node]?.incarnation == incarnation else { throw ChildTaskStructureCommand.invalid } }
    }
}
