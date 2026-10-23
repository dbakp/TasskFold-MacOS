import XCTest
@testable import TaskfoldCore

final class WearableReceiptTests: XCTestCase {
    func receipt() -> WearableMutationReceipt {
        .init(phone: UUID(), watch: UUID(), command: UUID(), epoch: UUID(), account: "owner",
              digest: String(repeating: "a", count: 64), task: UUID(), generation: UUID(), action: "capture")
    }
    func testReceiptMustEnterOnlyWithExplicitAcceptance() throws {
        let proof = receipt(); var proposed = Snapshot(); proposed.wearableReceipts = [proof.key: proof]
        XCTAssertThrowsError(try WearableReceiptLedger.staging(previous: Snapshot(), proposed: proposed))
        XCTAssertEqual(try WearableReceiptLedger.staging(previous: Snapshot(), proposed: proposed, accepting: proof), [proof.key: proof])
        XCTAssertEqual(try WearableReceiptLedger.staging(previous: Snapshot(), proposed: Snapshot(), accepting: proof), [proof.key: proof])
    }
    func testUndoAndRestoreCannotEraseOrReplaceProof() throws {
        let proof = receipt(); var previous = Snapshot(); previous.wearableReceipts = [proof.key: proof]
        XCTAssertEqual(try WearableReceiptLedger.staging(previous: previous, proposed: Snapshot()), previous.wearableReceipts)
        var changed = proof; changed.digest = String(repeating: "b", count: 64)
        var proposed = previous; proposed.wearableReceipts = [proof.key: changed]
        XCTAssertThrowsError(try WearableReceiptLedger.staging(previous: previous, proposed: proposed))
        XCTAssertThrowsError(try WearableReceiptLedger.staging(previous: previous, proposed: proposed, accepting: changed))
    }
    func testUnknownInvalidAndOversizeReceiptsFailClosed() throws {
        var proof = receipt(); proof.version = 2
        XCTAssertFalse(proof.valid)
        var proposed = Snapshot(); proposed.wearableReceipts = [proof.key: proof]
        XCTAssertThrowsError(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(proposed)))
        proof = receipt(); proof.action = "arbitrary-patch"; XCTAssertFalse(proof.valid)
        proof = receipt(); proof.digest = String(repeating: "g", count: 64); XCTAssertFalse(proof.valid)
        proof = receipt(); XCTAssertFalse(WearableReceiptLedger.valid(["other-key": proof]))
        var full: [String: WearableMutationReceipt] = [:]
        for _ in 0..<WearableReceiptLedger.maximum { let item = receipt(); full[item.key] = item }
        var old = Snapshot(); old.wearableReceipts = full
        XCTAssertThrowsError(try WearableReceiptLedger.staging(previous: old, proposed: old, accepting: receipt()))
    }
    func testLegacySnapshotAndExactNewSnapshotRoundtrip() throws {
        let legacy = Data(#"{"tables":{},"pending":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Snapshot.self, from: legacy).wearableReceipts)
        let proof = receipt(); var snapshot = Snapshot(); snapshot.wearableReceipts = [proof.key: proof]
        XCTAssertEqual(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }
    func fullSnapshot() -> Snapshot {
        var snapshot = Snapshot()
        for _ in 0..<WearableReceiptLedger.maximum { let proof = receipt(); snapshot.wearableReceipts = (snapshot.wearableReceipts ?? [:]).merging([proof.key: proof]) { $1 } }
        return snapshot
    }
    func testExplicitFullRestartAdvancesFenceAndPreservesWork() throws {
        var full = fullSnapshot()
        let task = Record.task(user: "owner"); full.tables["tasks"] = [task]
        full.pending = [.init(table: "tasks", recordID: task.id, method: "POST", fields: task.fields)]
        let restarted = try WearableReceiptLedger.applying(previous: full, proposed: full, restarting: 0)
        XCTAssertEqual(restarted.wearableReceiptGeneration, 1); XCTAssertNil(restarted.wearableReceipts)
        XCTAssertEqual(restarted.tables, full.tables); XCTAssertEqual(restarted.pending, full.pending)
        XCTAssertEqual(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(restarted)), restarted)
    }
    func testOldUndoAndRestoreCannotLowerFenceOrResurrectReceipts() throws {
        let full = fullSnapshot()
        let restarted = try WearableReceiptLedger.applying(previous: full, proposed: full, restarting: 0)
        let restored = try WearableReceiptLedger.applying(previous: restarted, proposed: full)
        XCTAssertEqual(restored.wearableReceiptGeneration, 1); XCTAssertNil(restored.wearableReceipts)
        XCTAssertThrowsError(try WearableReceiptLedger.applying(previous: restarted, proposed: full, accepting: receipt()))
    }
    func testOrdinaryMergeCannotAdvanceFenceOrEraseCurrentProof() throws {
        var previous = Snapshot(); previous.wearableReceiptGeneration = 3
        let proof = receipt(); previous.wearableReceipts = [proof.key: proof]
        var proposed = Snapshot(); proposed.wearableReceiptGeneration = 4
        XCTAssertThrowsError(try WearableReceiptLedger.applying(previous: previous, proposed: proposed))
        let result = try WearableReceiptLedger.applying(previous: previous, proposed: Snapshot())
        XCTAssertEqual(result.wearableReceiptGeneration, 3); XCTAssertEqual(result.wearableReceipts, previous.wearableReceipts)
    }
    func testRestartRequiresFullHistoryExactGenerationAndNoNewMutation() throws {
        XCTAssertThrowsError(try WearableReceiptLedger.applying(previous: Snapshot(), proposed: Snapshot(), restarting: 0))
        let full = fullSnapshot()
        XCTAssertThrowsError(try WearableReceiptLedger.applying(previous: full, proposed: full, restarting: 1))
        XCTAssertThrowsError(try WearableReceiptLedger.applying(previous: full, proposed: full, accepting: receipt(), restarting: 0))
        var overflow = full; overflow.wearableReceiptGeneration = UInt64.max
        XCTAssertThrowsError(try WearableReceiptLedger.applying(previous: overflow, proposed: overflow, restarting: UInt64.max))
    }
    func testPrivateFenceIsNotInPortableBackup() throws {
        var snapshot = Snapshot(); snapshot.wearableReceiptGeneration = 9
        let proof = receipt(); snapshot.wearableReceipts = [proof.key: proof]
        let data = try WorkspaceBackup.make(snapshot, account: "owner").data()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("wearableReceipt"))
    }

}
