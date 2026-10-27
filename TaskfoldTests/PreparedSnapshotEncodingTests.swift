import Foundation
import XCTest
@testable import TaskfoldCore

final class PreparedSnapshotEncodingTests: XCTestCase {
    private func seed() -> Snapshot {
        Snapshot(tables: ["tasks": [Record(["id": .string("a"), "user_id": .string("local"), "title": .string("é"), "future": .object(["raw": .string("e\u{301}"), "zero": .number(-0.0)])]), Record(["id": .string("b"), "title": .string("Second")])], "future_table": [Record(["id": .string("future"), "value": .array([.null, .bool(true), .number(1.25)])])]])
    }
    private func sorted(_ snapshot: Snapshot) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(snapshot)
    }
    func testRetainedSnapshotReusesExactWorkerBytesAndRoundTripsUnknownValues() async throws {
        let original = seed()
        let prepared = try await Task.detached { try PreparedSnapshotEncoding(original) }.value
        let data = try XCTUnwrap(prepared.matching(original))
        XCTAssertEqual(data, try prepared.matching(prepared.snapshot))
        let decoded = try JSONDecoder().decode(Snapshot.self, from: data)
        XCTAssertEqual(try sorted(decoded), try sorted(original))
        XCTAssertEqual(decoded.tables["tasks"]?[0]["title"].text.utf8.map { $0 }, Array("é".utf8))
        XCTAssertEqual(decoded.tables["tasks"]?[0]["future"].object["raw"]?.text.utf8.map { $0 }, Array("e\u{301}".utf8))
        if case .number(let number) = decoded.tables["tasks"]?[0]["future"].object["zero"] { XCTAssertEqual(number.bitPattern, (-0.0).bitPattern) }
        else { XCTFail("Unknown signed zero was lost") }
    }
    func testChangedTableBuffersAlwaysFallBackIncludingEqualCopiesAndRawEdits() throws {
        let original = seed(), prepared = try PreparedSnapshotEncoding(original)
        var changed = original
        changed.tables["tasks"] = original.tables["tasks"]!.map { $0 }
        XCTAssertEqual(changed, original); XCTAssertNil(try prepared.matching(changed))
        changed = original; changed.tables["tasks"]?[0]["title"] = .string("e\u{301}")
        XCTAssertEqual(changed, original); XCTAssertNil(try prepared.matching(changed))
        changed = original; changed.tables["tasks"]?[0]["future"] = .object(["raw": .string("e\u{301}"), "zero": .number(0)])
        XCTAssertEqual(changed, original); XCTAssertNil(try prepared.matching(changed))
        changed = original; changed.tables["tasks"]?.reverse(); XCTAssertNil(try prepared.matching(changed))
        changed = original; changed.tables["tasks"]?.removeLast(); XCTAssertNil(try prepared.matching(changed))
        changed = original; changed.tables["extra"] = []; XCTAssertNil(try prepared.matching(changed))
        changed = original; changed.tables["future_table"] = nil; XCTAssertNil(try prepared.matching(changed))
        XCTAssertNotNil(try prepared.matching(original), "A rejected proposal must not invalidate the retained capture")
    }
    func testCanonicalEquivalentTableKeyDoesNotReuseWrongSpelling() throws {
        let original = Snapshot(tables: ["é": [Record(["id": .string("a")])]])
        let prepared = try PreparedSnapshotEncoding(original)
        var changed = original; let rows = changed.tables.removeValue(forKey: "é")!
        changed.tables["e\u{301}"] = rows
        XCTAssertEqual(changed, original); XCTAssertNil(try prepared.matching(changed))
    }
    func testMetadataNeedsExactRawBytesAcrossAllPrivateLedgers() throws {
        var original = seed()
        original.sharedCaptureReceipts = ["é": "é"]
        original.pending = [Mutation(table: "future", recordID: "a", method: "POST", fields: ["raw": .string("é"), "zero": .number(0)])]
        let prepared = try PreparedSnapshotEncoding(original)
        var changed = original; changed.sharedCaptureReceipts = ["e\u{301}": "é"]
        XCTAssertEqual(changed, original); XCTAssertNil(try prepared.matching(changed))
        changed = original; changed.sharedCaptureReceipts = ["é": "e\u{301}"]
        XCTAssertEqual(changed, original); XCTAssertNil(try prepared.matching(changed))
        changed = original; changed.pending[0].fields["raw"] = .string("e\u{301}")
        XCTAssertEqual(changed, original); XCTAssertNil(try prepared.matching(changed))
        changed = original; changed.pending[0].fields["zero"] = .number(-0.0)
        XCTAssertEqual(changed, original); XCTAssertNil(try prepared.matching(changed))
        let edits: [(inout Snapshot) -> Void] = [
            { $0.pending = [] }, { $0.wearableReceipts = [:] }, { $0.wearableReceiptGeneration = 1 },
            { $0.locationRetirements = [:] }, { $0.locationActions = [:] }, { $0.timeSnoozes = [:] },
            { $0.locationImports = [:] }, { $0.widgetCompletion.receipts = ["request": "task"] },
            { $0.widgetCompletion.receiptOrder = ["request"] },
            { $0.widgetCompletion.states = ["a": .init(token: "token", signature: "signature")] }
        ]
        for edit in edits { changed = original; edit(&changed); XCTAssertNil(try prepared.matching(changed)) }
        XCTAssertNotNil(try prepared.matching(original))
    }
    func testEmptySnapshotAndEmptyTablesHaveValidOrdinaryEncoding() throws {
        for original in [Snapshot(), Snapshot(tables: ["tasks": []])] {
            let prepared = try PreparedSnapshotEncoding(original)
            let data = try XCTUnwrap(prepared.matching(original))
            XCTAssertEqual(try JSONDecoder().decode(Snapshot.self, from: data), original)
        }
    }
    func testNonEncodableFieldsKeepEncoderFailure() throws {
        var original = seed(); original.tables["tasks"]?[0]["invalid"] = .number(.nan)
        XCTAssertThrowsError(try PreparedSnapshotEncoding(original))
        original = seed(); let prepared = try PreparedSnapshotEncoding(original)
        original.pending = [Mutation(table: "future", recordID: "a", method: "POST", fields: ["invalid": .number(.infinity)])]
        XCTAssertThrowsError(try prepared.matching(original))
    }
    func test5000RootEncodingAdmissionMatchesOrdinaryEncoding() throws {
        var original = Snapshot()
        original.tables["tasks"] = (0..<5000).map { Record(["id": .string("task-\($0)"), "title": .string("Workflow \($0)"), "description": .string("Review Unicode é / e\u{301}"), "subtasks": .array([])]) }
        original.widgetCompletion.states = Dictionary(uniqueKeysWithValues: (0..<5000).map { ("task-\($0)", .init(token: "token-\($0)", signature: "signature-\($0)")) })
        let prepared = try PreparedSnapshotEncoding(original), clock = ContinuousClock()
        func seconds(_ duration: Duration) -> Double { Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 }
        var reuse: [Double] = [], ordinary: [Double] = []
        for _ in 0..<3 {
            let start = clock.now, data = try XCTUnwrap(prepared.matching(original)); reuse.append(seconds(start.duration(to: clock.now)))
            let next = clock.now, fresh = try JSONEncoder().encode(original); ordinary.append(seconds(next.duration(to: clock.now)))
            XCTAssertEqual(try sorted(JSONDecoder().decode(Snapshot.self, from: data)), try sorted(JSONDecoder().decode(Snapshot.self, from: fresh)))
        }
        print("SNAPSHOT_ENCODING_ADMIT_5000_SECONDS \(reuse)")
        print("SNAPSHOT_ENCODING_ORDINARY_5000_SECONDS \(ordinary)")
    }
}
