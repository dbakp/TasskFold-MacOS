import Foundation
import XCTest
@testable import TaskfoldCore

final class SnapshotFieldEncodingCacheTests: XCTestCase {
    private func seed() throws -> Snapshot {
        Snapshot(tables: ["tasks": [Record(["id": .string("a"), "title": .string("é"), "future": try TaskfoldJSONDecoder().decode(JSON.self, from: Data("9007199254740993".utf8)), "attachments": .array([.object(["data": .string(String(repeating: "A/", count: 320_000))])]), "nested": .object(["é": .array([.number(-0.0), .bool(true)])])]), Record(["id": .string("b"), "title": .string("Second")])], "empty": []])
    }
    private func exact(_ data: Data, _ expected: Snapshot, file: StaticString = #filePath, line: UInt = #line) throws {
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = .sortedKeys
        let actual = try TaskfoldJSONDecoder().decode(Snapshot.self, from: data)
        XCTAssertEqual(try encoder.encode(actual), try encoder.encode(expected), file: file, line: line)
    }
    func testEditedAttachmentBearingTaskReusesUnchangedFields() throws {
        var value = try seed(); let cache = SnapshotFieldEncodingCache()
        try exact(cache.encode(value), value); XCTAssertEqual(cache.statistics.reused, 0)
        value.tables["tasks"]![0]["title"] = .string("Edited")
        value.tables["tasks"]![0]["due_date"] = .string("2026-11-09")
        try exact(cache.encode(value), value)
        XCTAssertEqual(cache.statistics.encoded, 2); XCTAssertEqual(cache.statistics.reused, 6)
        value.tables["tasks"]![0]["attachments"] = .array([.string("Replacement")])
        try exact(cache.encode(value), value); XCTAssertEqual(cache.statistics.encoded, 1)
    }
    func testUnicodeSignedZeroAndOpaqueLexicalEditsAreNotSemanticCacheHits() throws {
        let cache = SnapshotFieldEncodingCache(); var value = try seed()
        _ = try cache.encode(value)
        value.tables["tasks"]![0]["title"] = .string("e\u{301}")
        value.tables["tasks"]![0]["nested"] = .object(["e\u{301}": .array([.number(0), .bool(true)])])
        try exact(cache.encode(value), value); XCTAssertEqual(cache.statistics.encoded, 2)
        value.tables["tasks"]![0]["future"] = try TaskfoldJSONDecoder().decode(JSON.self, from: Data("9007199254740993.0".utf8))
        let data = try cache.encode(value); try exact(data, value)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("9007199254740993.0")); XCTAssertEqual(cache.statistics.encoded, 1)
        value.tables["tasks"]![0]["opaque_object"] = try TaskfoldJSONDecoder().decode(JSON.self, from: Data(#"{"é":1,"e\u0301":2}"#.utf8))
        _ = try cache.encode(value)
        let revised = #"{ "e\u0301":2, "é":1 }"#
        value.tables["tasks"]![0]["opaque_object"] = try TaskfoldJSONDecoder().decode(JSON.self, from: Data(revised.utf8))
        let objectData = try cache.encode(value); try exact(objectData, value)
        XCTAssertTrue(String(decoding: objectData, as: UTF8.self).contains(revised)); XCTAssertEqual(cache.statistics.encoded, 1)
    }
    func testEscapedTableAndFieldNamesRowOrderDuplicatesAndEmptyIDs() throws {
        let cache = SnapshotFieldEncodingCache()
        var value = Snapshot(tables: ["table\"\\\né": [Record(["id": .string("same"), "v\"\\": .string("one")]), Record(["id": .string("same"), "v\"\\": .string("two")]), Record(["title": .string("No ID")])]])
        try exact(cache.encode(value), value)
        value.tables["table\"\\\né"]!.reverse()
        try exact(cache.encode(value), value)
        value.tables["table\"\\\né"]![1].fields.removeValue(forKey: "v\"\\")
        try exact(cache.encode(value), value)
        let rows = value.tables.removeValue(forKey: "table\"\\\né")!
        value.tables["table\"\\\ne\u{301}"] = rows
        try exact(cache.encode(value), value)
    }
    func testHeaderIsRebuiltAndOnlyStructuralRootTablesSlotIsReplaced() throws {
        var value = try seed(); let cache = SnapshotFieldEncodingCache()
        value.pending = [Mutation(table: "future", recordID: "p", method: "POST", fields: ["tables": .object([:]), "literal": .string("\"tables\":{}")])]
        _ = try cache.encode(value)
        value.pending[0].fields["new"] = .string("new header")
        value.sharedCaptureReceipts = ["request": "task"]
        try exact(cache.encode(value), value)
        XCTAssertEqual(cache.statistics.encoded, 0)
    }
    func testBudgetsNeverOmitFieldsAndClearReleasesRetainedState() throws {
        var value = try seed()
        for cache in [SnapshotFieldEncodingCache(maximumBytes: 0), SnapshotFieldEncodingCache(maximumBytes: 512, maximumEntries: 1)] {
            _ = try cache.encode(value); try exact(cache.encode(value), value)
            XCTAssertLessThanOrEqual(cache.statistics.retained, 1); XCTAssertLessThanOrEqual(cache.statistics.retainedBytes, 512)
            cache.clear(); XCTAssertEqual(cache.statistics, .init())
        }
        let cache = SnapshotFieldEncodingCache(); _ = try cache.encode(value)
        value.tables = [:]; try exact(cache.encode(value), value); XCTAssertEqual(cache.statistics.retained, 0)
        value.tables = [String(repeating: "table", count: 100): [Record(["id": .string(String(repeating: "id", count: 200)), String(repeating: "field", count: 200): .string("keep")])]]
        try exact(cache.encode(value), value); XCTAssertEqual(cache.statistics.retained, 0)
        var many: [String: JSON] = ["id": .string("many")]
        for n in 0..<600 { many["field-\(n)\"\\"] = .number(Double(n)) }
        value = Snapshot(tables: ["tasks": [Record(many), Record(many)]])
        try exact(cache.encode(value), value); try exact(cache.encode(value), value)
    }
    func testDefaultAdmissionSmallOversizeAndLargeHeaderKeepOrdinaryWriter() throws {
        let cache = DurableSnapshotReadCache(); let small = Snapshot(tables: ["tasks": [Record(["id": .string("a")])]])
        _ = try cache.encode(small); _ = try cache.encode(small); XCTAssertEqual(cache.fieldEncodingStatistics, .init())
        let bounded = DurableSnapshotReadCache(maximumBytes: 10, minimumFieldEncodingBytes: 0)
        try exact(bounded.encode(seed()), seed()); XCTAssertEqual(bounded.fieldEncodingStatistics.retained, 0)
        var header = small; header.pending = [Mutation(table: "future", recordID: "x", method: "POST", fields: ["large": .string(String(repeating: "x", count: 530_000))])]
        let fallback = DurableSnapshotReadCache(minimumFieldEncodingBytes: 0)
        try exact(fallback.encode(header), header); XCTAssertEqual(fallback.fieldEncodingStatistics, .init())
    }
    func testAdmissionBypassesUncacheableKeysAndEntryOrByteBudget() throws {
        let cache = SnapshotFieldEncodingCache(maximumBytes: 1024, maximumEntries: 2)
        let row = Record(["id": .string("a"), "title": .string("Keep")])
        XCTAssertTrue(cache.admits(Snapshot(tables: ["tasks": [row]]), knownBytes: 100))
        XCTAssertFalse(cache.admits(Snapshot(tables: ["tasks": [row, row]]), knownBytes: 100))
        XCTAssertFalse(cache.admits(Snapshot(tables: ["tasks": [row]]), knownBytes: 1000))
        XCTAssertFalse(cache.admits(Snapshot(tables: ["tasks": [Record(["title": .string("Missing ID")])]]), knownBytes: 100))
        XCTAssertFalse(cache.admits(Snapshot(tables: [String(repeating: "x", count: 257): [row]]), knownBytes: 100))
        var large = row; large[String(repeating: "x", count: 513)] = .bool(true)
        XCTAssertFalse(cache.admits(Snapshot(tables: ["tasks": [large]]), knownBytes: 100))
    }
    func testLargePlainWorkspacesUseOrdinaryWriterUnlessOpaqueValuesNeedScanning() throws {
        var fields: [String: JSON] = [:]
        for n in 0..<10 { fields["field-\(n)"] = .string("Keep") }
        var value = Snapshot(tables: ["tasks": (0..<1000).map { n in var f = fields; f["id"] = .string("r-\(n)"); return Record(f) }])
        let memo = SnapshotFieldEncodingCache()
        XCTAssertFalse(memo.admits(value, knownBytes: 1024 * 1024))
        let writer = DurableSnapshotReadCache(minimumFieldEncodingBytes: 0)
        _ = try writer.encode(value); try exact(writer.encode(value), value)
        XCTAssertEqual(writer.fieldEncodingStatistics, .init())
        value.tables["tasks"]![0]["nested"] = .array([.object(["future": try TaskfoldJSONDecoder().decode(JSON.self, from: Data("9007199254740993".utf8))])])
        XCTAssertTrue(memo.admits(value, knownBytes: 1024 * 1024))
    }
    func testFailedWriteExternalReplacementCorruptionAndRetryReadActualDisk() throws {
        let cache = DurableSnapshotReadCache(minimumFieldEncodingBytes: 0); var value = try seed()
        let oldDisk = try cache.encode(value); value.tables["tasks"]![0]["title"] = .string("New")
        _ = try cache.encode(value) // Atomic write failed; oldDisk is still authoritative.
        try exact(TaskfoldJSONEncoder().encode(cache.decode(oldDisk)), seed()); XCTAssertEqual(cache.decodeCount, 1)
        XCTAssertEqual(cache.fieldEncodingStatistics, .init())
        let retry = try cache.encode(value); try exact(retry, value)
        XCTAssertEqual(try cache.decode(retry), value)
        var external = value; external.tables["tasks"]![0]["title"] = .string("Old")
        let externalData = try TaskfoldJSONEncoder().encode(external)
        try exact(TaskfoldJSONEncoder().encode(cache.decode(externalData)), external)
        XCTAssertThrowsError(try cache.decode(Data("{broken".utf8)))
        try exact(TaskfoldJSONEncoder().encode(cache.decode(retry)), value); XCTAssertEqual(cache.decodeCount, 4)
    }
    func testPreparedBytesRemainExactAndInvalidPrivateLedgerIsNotMemoized() throws {
        let cache = DurableSnapshotReadCache(minimumFieldEncodingBytes: 0); var value = try seed()
        _ = try cache.encode(value); let prepared = try PreparedSnapshotEncoding(value)
        XCTAssertEqual(try cache.encode(value, prepared: prepared), try prepared.matching(value)); XCTAssertEqual(cache.fieldEncodingStatistics, .init())
        value.timeSnoozes = ["bad": try TaskfoldJSONDecoder().decode(TimeSnoozeIntent.self, from: Data(#"{"version":1,"id":"bad","account":"bad","epoch":"bad","taskID":"bad","specID":"bad","signature":"bad","originalAt":0,"fireAt":0,"phase":"queued","revision":0}"#.utf8))]
        let invalid = try cache.encode(value); XCTAssertThrowsError(try cache.decode(invalid))
    }
    func testInvalidNumbersAndTotalDepthCannotBeSmuggledThroughFieldReuse() throws {
        let cache = SnapshotFieldEncodingCache(); var value = try seed(); _ = try cache.encode(value)
        value.tables["tasks"]![0]["invalid"] = .number(.nan); XCTAssertThrowsError(try cache.encode(value))
        var leaf: JSON = .number(1)
        for _ in 0..<507 { leaf = .array([leaf]) }
        value = Snapshot(tables: ["tasks": [Record(["id": .string("a"), "deep": leaf])]])
        _ = try cache.encode(value)
        leaf = .array([.array([leaf])]); value.tables["tasks"]![0]["deep"] = leaf
        XCTAssertThrowsError(try cache.encode(value))
    }
    func testLargeEditedTaskEncodingTimingAndColdReadback() throws {
        for count in [200, 2_000] {
            var value = try seed()
            value.tables["tasks"]![0]["attachments"] = .array([.object(["data": .string(String(repeating: "A/", count: 1_280_000))])])
            value.tables["tasks"]! += (2..<count).map { n in
                var row = Record.task(user: "local", createdAt: "2026-11-07T00:00:00Z")
                row["id"] = .string("t\(n)"); row["title"] = .string("Task \(n)"); return row
            }
            WidgetCompletion.prepare(&value)
            let cache = DurableSnapshotReadCache(), ordinary = DurableSnapshotReadCache(minimumFieldEncodingBytes: Int.max)
            _ = try cache.encode(value); _ = try ordinary.encode(value)
            let coldStart = Date(); _ = try cache.encode(value); let cold = Date().timeIntervalSince(coldStart)
            var before: [Double] = [], after: [Double] = [], data = Data()
            for n in 0..<3 {
                value.tables["tasks"]![0]["title"] = .string("Edited \(n)")
                let a = Date(); _ = try ordinary.encode(value); before.append(Date().timeIntervalSince(a))
                let b = Date(); data = try cache.encode(value); after.append(Date().timeIntervalSince(b))
                XCTAssertEqual(cache.fieldEncodingStatistics.encoded, 1)
            }
            try exact(data, value)
            print("FIELD_ENCODING_TIMING tasks=\(count) bytes=\(data.count) cold=\(cold) ordinary=\(before) cached=\(after) reused=\(cache.fieldEncodingStatistics.reused) retainedBytes=\(cache.fieldEncodingStatistics.retainedBytes)")
        }
    }
}
