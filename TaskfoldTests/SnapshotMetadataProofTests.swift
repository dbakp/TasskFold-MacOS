import XCTest
@testable import TaskfoldCore

final class SnapshotMetadataProofTests: XCTestCase {
    private let account = "a7200000-0000-4000-8000-000000000001"
    private func seed() -> Snapshot {
        Snapshot(tables: ["tasks": [Record(["id": .string("a7100000-0000-4000-8000-000000000001"),
            "user_id": .string(account), "title": .string("Café")])]])
    }
    func testCopiesTableEditsAndFreshDecodesKeepValueAndWireSemantics() throws {
        let original = seed()
        var copied = original
        XCTAssertTrue(original.sharesMetadataSource(with: copied))
        copied.tables["tasks"]![0]["title"] = .string("Changed task")
        XCTAssertTrue(original.sharesMetadataSource(with: copied), "Table buffers have their own admission proof")
        let wire = try TaskfoldJSONEncoder().encode(original)
        let decoded = try TaskfoldJSONDecoder().decode(Snapshot.self, from: wire)
        XCTAssertEqual(original, decoded)
        XCTAssertFalse(original.sharesMetadataSource(with: decoded), "A decoder cannot import a private in-memory proof")
        let object = try TaskfoldJSONDecoder().decode([String: JSON].self, from: wire)
        XCTAssertEqual(Set(object.keys), Set(["tables", "pending", "widgetCompletion"]))
    }
    func testEveryMetadataWriteIncludingNestedValuesInvalidatesProof() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-workspace-boundary-v1", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try TaskfoldJSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        let owner = fixture["account"]!.text
        let boundary = try TeamWorkspaceBoundary(fixture["active"]!.object, account: owner, origin: "https://backend.example")
        let workspace = try TeamWorkspaceCache(boundary: boundary, previous: nil, pending: [], tasks: [])
        let service = try WorkflowUndoService(["protocol": .number(1), "account": .string(account), "undo_protocol": .number(1), "bulk_protocol": .number(1)], account: account, origin: "https://backend.example")
        let mutations: [(inout Snapshot) -> Void] = [
            { $0.pending = [] }, { $0.teamWorkspace = workspace }, { $0.workflowUndoService = service },
            { $0.widgetCompletion.states["sample"] = .init(token: "proof", signature: "signature") },
            { $0.widgetCompletion.receipts["receipt"] = "sample" }, { $0.widgetCompletion.receiptOrder.append("receipt") },
            { $0.sharedCaptureReceipts = [:] }, { $0.wearableReceipts = [:] }, { $0.wearableReceiptGeneration = 0 },
            { $0.locationRetirements = [:] }, { $0.locationActions = [:] }, { $0.timeSnoozes = [:] }, { $0.locationImports = [:] }
        ]
        let source = seed()
        for mutate in mutations {
            var changed = source; mutate(&changed)
            XCTAssertFalse(source.sharesMetadataSource(with: changed))
            XCTAssertTrue(source.sharesMetadataSource(with: source), "A copy's write cannot invalidate its original")
        }
        var pending = source
        pending.pending = [Mutation(table: "future", recordID: "sample", method: "POST", fields: ["text": .string("é"), "zero": .number(-0.0)])]
        var revised = pending; revised.pending[0].fields["text"] = .string("e\u{301}")
        XCTAssertEqual(pending, revised); XCTAssertFalse(pending.sharesMetadataSource(with: revised))
        revised = pending; revised.pending[0].fields["zero"] = .number(0)
        XCTAssertEqual(pending, revised); XCTAssertFalse(pending.sharesMetadataSource(with: revised))
    }
    func testClearingAlreadyAbsentOptionalLedgersRetainsProof() {
        let original = seed(); var cleared = original
        cleared.teamWorkspace = nil; cleared.workflowUndoService = nil; cleared.sharedCaptureReceipts = nil
        cleared.wearableReceipts = nil; cleared.wearableReceiptGeneration = nil; cleared.locationRetirements = nil
        cleared.locationActions = nil; cleared.timeSnoozes = nil; cleared.locationImports = nil
        XCTAssertTrue(original.sharesMetadataSource(with: cleared)); XCTAssertEqual(original, cleared)
    }
    func testWorkerValidatedMetadataIsReusedAfterRealEmptyLedgerStaging() throws {
        let prepared = try PreparedSnapshotEncoding(preparingWidgetCompletion: seed())
        let original = prepared.snapshot
        var staged = try LocationRetirementOutbox.staging(previous: original, proposed: original, account: account)
        staged.locationImports = try LocationHandoffImportLedger.staging(previous: original, proposed: staged)
        staged.timeSnoozes = nil
        staged = try WearableReceiptLedger.applying(previous: original, proposed: staged)
        XCTAssertTrue(original.sharesMetadataSource(with: staged))
        let cache = DurableSnapshotReadCache()
        let data = try cache.encode(staged, prepared: prepared)
        XCTAssertEqual(cache.metadataValidationCount, 0, "Validated worker bytes need no interface-thread decode")
        XCTAssertEqual(try cache.decode(data), staged); XCTAssertEqual(cache.decodeCount, 0)
        XCTAssertEqual(try TaskfoldJSONDecoder().decode(Snapshot.self, from: data), staged)
    }
    func testEqualRecreatedMetadataStillUsesExactByteFallback() throws {
        let prepared = try PreparedSnapshotEncoding(preparingWidgetCompletion: seed())
        var current = prepared.snapshot
        current.pending = prepared.snapshot.pending.map { $0 }
        XCTAssertFalse(current.sharesMetadataSource(with: prepared.snapshot)); XCTAssertEqual(current, prepared.snapshot)
        XCTAssertNotNil(try prepared.matching(current))
        let cache = DurableSnapshotReadCache(), data = try cache.encode(current, prepared: prepared)
        XCTAssertEqual(cache.metadataValidationCount, 0); XCTAssertEqual(try cache.decode(data), current)
    }
    func testInvalidWorkerMetadataNeverBypassesPrivateLedgerDecoder() throws {
        var invalid = seed()
        let receipt = WearableMutationReceipt(phone: UUID(), watch: UUID(), command: UUID(), epoch: UUID(), account: account,
            digest: "invalid", task: UUID(), generation: UUID(), action: "complete")
        invalid.wearableReceipts = [receipt.key: receipt]
        let prepared = try PreparedSnapshotEncoding(preparingWidgetCompletion: invalid)
        let cache = DurableSnapshotReadCache(), data = try cache.encode(prepared.snapshot, prepared: prepared)
        XCTAssertEqual(cache.metadataValidationCount, 1)
        XCTAssertThrowsError(try cache.decode(data), "Invalid receipt metadata must never be admitted through a read memo")
    }
    func testChangedMetadataCannotBorrowAnEarlierValidation() throws {
        let prepared = try PreparedSnapshotEncoding(preparingWidgetCompletion: seed())
        var changed = prepared.snapshot
        changed.sharedCaptureReceipts = ["é": "é"]
        XCTAssertNil(try prepared.matching(changed))
        let cache = DurableSnapshotReadCache(), data = try cache.encode(changed, prepared: prepared)
        XCTAssertEqual(cache.metadataValidationCount, 1); XCTAssertEqual(try cache.decode(data), changed)
    }
    func testOversizedMetadataKeepsExistingReadMemoLimit() throws {
        var value = seed(); value.sharedCaptureReceipts = ["large": String(repeating: "x", count: 512 * 1024 + 64)]
        let prepared = try PreparedSnapshotEncoding(preparingWidgetCompletion: value)
        let cache = DurableSnapshotReadCache(), data = try cache.encode(prepared.snapshot, prepared: prepared)
        XCTAssertEqual(try cache.decode(data), prepared.snapshot); XCTAssertEqual(cache.decodeCount, 1)
    }
}
