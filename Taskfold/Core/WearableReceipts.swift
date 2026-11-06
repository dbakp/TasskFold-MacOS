import Foundation

/// Device-private mutation proof, never a shared task field or portable backup.
struct WearableMutationReceipt: Codable, Equatable, Sendable {
    var version = 1
    var phone: UUID
    var watch: UUID
    var command: UUID
    var epoch: UUID
    var account: String
    var digest: String
    var task: UUID
    var generation: UUID
    var action: String
    var key: String { [phone, watch, command].map { $0.uuidString.lowercased() }.joined(separator: ":") }
    var valid: Bool {
        version == 1 && !account.isEmpty && account.utf8.count <= 200 &&
        digest.count == 64 && digest.allSatisfy { "0123456789abcdef".contains($0) } &&
        ["capture", "complete"].contains(action)
    }
}

enum WearableReceiptLedger {
    static let maximum = 4_096
    static func valid(_ receipts: [String: WearableMutationReceipt]) -> Bool {
        receipts.count <= maximum && receipts.allSatisfy { $0.key == $0.value.key && $0.value.valid }
    }
    /// Preserve acknowledgements through Undo/restore/merge. New receipts enter
    /// only with the explicit atomic mutation; there is no silent pruning/reset.
    static func staging(previous: Snapshot, proposed: Snapshot, accepting: WearableMutationReceipt? = nil) throws -> [String: WearableMutationReceipt]? {
        try applying(previous: previous, proposed: proposed, accepting: accepting).wearableReceipts
    }
    /// The generation fence and reclaimed receipts share the same atomic cache
    /// transaction. Ordinary Undo/restore may never lower or advance this fence.
    static func applying(previous: Snapshot, proposed: Snapshot, accepting: WearableMutationReceipt? = nil,
                         restarting expected: UInt64? = nil) throws -> Snapshot {
        let generation = previous.wearableReceiptGeneration ?? 0
        let proposedGeneration = proposed.wearableReceiptGeneration ?? 0
        let old = previous.wearableReceipts ?? [:]
        guard valid(old), valid(proposed.wearableReceipts ?? [:]), proposedGeneration <= generation,
              accepting == nil || proposedGeneration == generation else { throw failure() }
        var durable = proposed
        if let expected {
            guard accepting == nil, expected == generation, generation < UInt64.max,
                  old.count == maximum else { throw failure() }
            durable.wearableReceiptGeneration = generation + 1
            durable.wearableReceipts = nil
            return durable
        }
        // A baseline from before a reset cannot reintroduce old receipts.
        let next = proposedGeneration == generation ? proposed.wearableReceipts ?? [:] : [:]
        guard valid(old), valid(next), accepting?.valid != false else { throw failure() }
        if let accepting, let saved = old[accepting.key], saved != accepting { throw failure() }
        var result = old
        for (key, receipt) in next {
            guard old[key] == receipt || accepting == receipt else { throw failure() }
            result[key] = receipt
        }
        if let accepting {
            guard result[accepting.key] == nil || result[accepting.key] == accepting else { throw failure() }
            result[accepting.key] = accepting
        }
        guard valid(result) else { throw failure() }
        durable.wearableReceiptGeneration = previous.wearableReceiptGeneration
        durable.wearableReceipts = result.isEmpty ? nil : result
        return durable
    }
    static func failure() -> CocoaError { CocoaError(.fileReadCorruptFile) }
}
