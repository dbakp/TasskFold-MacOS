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
}
