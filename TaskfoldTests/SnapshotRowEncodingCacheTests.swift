import Foundation
import XCTest
@testable import TaskfoldCore

final class SnapshotRowEncodingCacheTests: XCTestCase {
    private func seed() -> Snapshot {
        Snapshot(tables: ["tasks": [Record(["id": .string("same"), "title": .string("Café"), "zero": .number(-0.0)]), Record(["id": .string("same"), "title": .string("Second")]), Record(["title": .string("No ID")])], "empty": []])
    }
    private func primed(_ source: Snapshot, maximumBytes: Int = 16 * 1024 * 1024) throws -> (DurableSnapshotReadCache, Snapshot) {
        let cache = DurableSnapshotReadCache(maximumBytes: maximumBytes, minimumFieldEncodingBytes: 0)
        let value = try cache.decode(TaskfoldJSONEncoder().encode(source))
        let request = try XCTUnwrap(cache.rowPreparationRequest())
        XCTAssertTrue(cache.adoptRows(try DurableSnapshotReadCache.prepareRows(request)))
        return (cache, value)
    }
    private func exact(_ data: Data, _ expected: Snapshot, file: StaticString = #filePath, line: UInt = #line) throws {
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(TaskfoldJSONDecoder().decode(Snapshot.self, from: data)), try encoder.encode(expected), file: file, line: line)
    }
    func testCurrentEditsReuseOnlyUnchangedRowsAndKeepEveryAuthoredValue() throws {
        let (cache, original) = try primed(seed()); var value = original
        value.tables["tasks"]![0]["due_date"] = .string("2026-11-09")
        value.tables["tasks"]![0]["title"] = .string("Cafe\u{301}")
        value.tables["tasks"]![0]["zero"] = .number(0)
        try exact(cache.encode(value), value)
        XCTAssertEqual(cache.rowEncodingStatistics.reused, 2); XCTAssertEqual(cache.rowEncodingStatistics.encoded, 1)
        XCTAssertEqual(original.tables["tasks"]![0].title, "Café")
        value.tables["tasks"]![1]["future"] = .object(["keep": .array([.string("Current opaque-shaped plain JSON")])])
        try exact(cache.encode(value), value)
        XCTAssertEqual(cache.rowEncodingStatistics.reused, 2)
    }
    func testReorderingDuplicatesMissingIDsMembershipAndTableNamesStayExact() throws {
        let (cache, initial) = try primed(seed()); var value = initial
        value.tables["tasks"]!.reverse(); try exact(cache.encode(value), value)
        value.tables["tasks"]!.remove(at: 1); try exact(cache.encode(value), value)
        value.tables["tasks"]!.append(Record(["title": .string("New no-ID row")]))
        try exact(cache.encode(value), value)
        value.tables = ["table\"\\\ne\u{301}": value.tables["tasks"]!, "empty": []]
        try exact(cache.encode(value), value)
        value.tables = [:]; try exact(cache.encode(value), value)
    }
    func testEqualReconstructedRowsCannotReuseUnrelatedSourceBytes() throws {
        let (cache, initial) = try primed(seed()); var value = initial
        value.tables = value.tables.mapValues { $0.map { Record($0.fields) } }
        try exact(cache.encode(value), value)
        XCTAssertEqual(cache.rowEncodingStatistics.reused, 0); XCTAssertEqual(cache.rowEncodingStatistics.encoded, 3)
    }
    func testHeaderAndPendingChangesRebuildOnlyTheStructuralTablesSlot() throws {
        let (cache, initial) = try primed(seed()); var value = initial
        value.pending = [Mutation(table: "future", recordID: "p", method: "POST", fields: ["tables": .object([:]), "literal": .string("\"tables\":{}")])]
        value.sharedCaptureReceipts = ["request": "task"]
        try exact(cache.encode(value), value)
        XCTAssertEqual(cache.rowEncodingStatistics.reused, 3); XCTAssertEqual(cache.rowEncodingStatistics.encoded, 0)
    }
    func testStalePreparationSameSizeExternalReplacementAndClearRefuseAdoption() throws {
        let cache = DurableSnapshotReadCache(minimumFieldEncodingBytes: 0)
        let old = try TaskfoldJSONEncoder().encode(seed()); _ = try cache.decode(old)
        let request = try XCTUnwrap(cache.rowPreparationRequest()), prepared = try DurableSnapshotReadCache.prepareRows(request)
        var changed = seed(); changed.tables["tasks"]![0]["title"] = .string("Other")
        let external = try TaskfoldJSONEncoder().encode(changed); _ = try cache.decode(external)
        XCTAssertFalse(cache.adoptRows(prepared)); cache.declineRows(request)
        XCTAssertNotNil(cache.rowPreparationRequest(), "An old failed job must not disable the current source")
        let current = try XCTUnwrap(cache.rowPreparationRequest()); cache.clear()
        XCTAssertFalse(cache.adoptRows(try DurableSnapshotReadCache.prepareRows(current)))
        XCTAssertEqual(cache.rowEncodingStatistics, .init())
        _ = try cache.decode(old); XCTAssertNotNil(cache.rowPreparationRequest())
    }
    func testOpaqueRowsPrepareReuseAndPreserveExactLexicalValues() throws {
        let raw = #"{"exact":9007199254740993.0,"huge":1e500,"zero":-0,"é":1,"é":2,"nested":{"n":9007199254740995}}"#
        let opaque = try TaskfoldJSONDecoder().decode(JSON.self, from: Data(raw.utf8))
        var source = seed()
        for i in source.tables["tasks"]!.indices { source.tables["tasks"]![i]["opaque"] = opaque }
        let (cache, initial) = try primed(source); var value = initial
        value.tables["tasks"]![0]["due_date"] = .string("2026-11-12")
        let bytes = try cache.encode(value); try exact(bytes, value)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains(raw))
        XCTAssertEqual(cache.rowEncodingStatistics.reused, 2)
        XCTAssertEqual(cache.rowEncodingStatistics.encoded, 1)
        value.tables["tasks"]![1]["opaque"] = try TaskfoldJSONDecoder().decode(JSON.self, from: Data(raw.replacingOccurrences(of: "1e500", with: "2e500").utf8))
        let edited = try cache.encode(value); try exact(edited, value)
        XCTAssertTrue(String(decoding: edited, as: UTF8.self).contains("2e500"))
        XCTAssertEqual(cache.rowEncodingStatistics.reused, 2)
        value.tables = value.tables.mapValues { $0.map { Record($0.fields) } }
        try exact(cache.encode(value), value)
        XCTAssertEqual(cache.rowEncodingStatistics.reused, 0)
        let decoded = try TaskfoldJSONDecoder().decode(Snapshot.self, from: edited)
        try exact(cache.encode(decoded), decoded)
        XCTAssertEqual(cache.rowEncodingStatistics.reused, 0)
    }
    func testFieldWriterLeavesOpaqueSavedBytesEligibleForBackgroundRows() throws {
        var value = seed()
        // The field writer requires unique, nonempty row IDs.
        for i in value.tables["tasks"]!.indices { value.tables["tasks"]![i]["id"] = .string("field-row-\(i)") }
        value.tables["tasks"]![0]["opaque"] = try TaskfoldJSONDecoder().decode(JSON.self, from: Data("1e500".utf8))
        let cache = DurableSnapshotReadCache(minimumFieldEncodingBytes: 0)
        // A real save encodes before requesting preparation; direct decode-only
        // priming does not exercise the immediate field writer's handoff.
        try exact(cache.encode(value), value)
        let request = try XCTUnwrap(cache.rowPreparationRequest())
        XCTAssertGreaterThan(cache.fieldEncodingStatistics.retained, 0)
        XCTAssertTrue(cache.adoptRows(try DurableSnapshotReadCache.prepareRows(request)))
        value.tables["tasks"]![1]["title"] = .string("Changed")
        try exact(cache.encode(value), value)
        XCTAssertEqual(cache.rowEncodingStatistics.reused, 2)
        XCTAssertEqual(cache.rowEncodingStatistics.encoded, 1)
        XCTAssertEqual(cache.fieldEncodingStatistics.retained, 0)
        cache.clear(); _ = try cache.encode(value)
        let declined = try XCTUnwrap(cache.rowPreparationRequest()); cache.declineRows(declined)
        _ = try cache.encode(value)
        XCTAssertNil(cache.rowPreparationRequest(), "Selecting the field writer must not retry a declined source")
    }
    func testPreparedRowOptOutSurvivesClearAndRejectsMatchingPreparation() throws {
        let wire = try TaskfoldJSONEncoder().encode(seed())
        let donor = DurableSnapshotReadCache(minimumFieldEncodingBytes: 0)
        _ = try donor.decode(wire)
        let prepared = try DurableSnapshotReadCache.prepareRows(try XCTUnwrap(donor.rowPreparationRequest()))
        let control = DurableSnapshotReadCache(minimumFieldEncodingBytes: 0, preparedRowsEnabled: false)
        for _ in 0..<2 {
            let value = try control.decode(wire)
            XCTAssertNil(control.rowPreparationRequest()); XCTAssertFalse(control.adoptRows(prepared))
            try exact(control.encode(value), value)
            XCTAssertEqual(control.rowEncodingStatistics.retained, 0)
            control.clear()
        }
    }
    func testOpaqueDepthAtTheCompletedEnvelopeKeepsOrdinarySuccessAndFailure() throws {
        let leaf = try TaskfoldJSONDecoder().decode(JSON.self, from: Data(#"{"é":1,"é":2,"n":1e500}"#.utf8))
        for depth in 502...511 {
            let (cache, initial) = try primed(seed()); var value = initial, nested = leaf
            for _ in 0..<depth { nested = .array([nested]) }
            value.tables["tasks"]![0]["deep"] = nested
            switch Result(catching: { try TaskfoldJSONEncoder().encode(value) }) {
            case .failure: XCTAssertThrowsError(try cache.encode(value), "depth=\(depth)")
            case .success(let reference):
                let actual = try cache.encode(value)
                XCTAssertEqual(String(decoding: actual, as: UTF8.self).contains("1e500"), true)
                if (try? TaskfoldJSONDecoder().decode(Snapshot.self, from: reference)) == nil {
                    XCTAssertThrowsError(try TaskfoldJSONDecoder().decode(Snapshot.self, from: actual))
                } else { try exact(actual, value) }
            }
        }
    }
    func testBudgetAndLargeHeaderFallbackNeverOmitWork() throws {
        let (cache, initial) = try primed(seed(), maximumBytes: 4096); var value = initial
        value.tables["tasks"]![0]["description"] = .string(String(repeating: "Keep", count: 2000))
        try exact(cache.encode(value), value)
        XCTAssertEqual(cache.rowEncodingStatistics.retained, 0); XCTAssertNil(cache.rowPreparationRequest())
        let (headerCache, current) = try primed(seed()); var largeHeader = current
        largeHeader.pending = [Mutation(table: "tasks", recordID: "same", method: "PATCH", fields: ["description": .string(String(repeating: "X", count: 600_000))])]
        try exact(headerCache.encode(largeHeader), largeHeader)
        XCTAssertNil(headerCache.rowPreparationRequest())
        let disabled = DurableSnapshotReadCache(maximumBytes: 0, minimumFieldEncodingBytes: 0)
        _ = try disabled.decode(TaskfoldJSONEncoder().encode(seed())); XCTAssertNil(disabled.rowPreparationRequest())
    }
    func testFailedDurableWriteCannotReapplySpeculativeRows() throws {
        let (cache, initial) = try primed(seed()), disk = try TaskfoldJSONEncoder().encode(seed())
        var proposed = initial; proposed.tables["tasks"]![0]["title"] = .string("Speculative")
        _ = try cache.encode(proposed)
        let restored = try cache.decode(disk)
        try exact(cache.encode(restored), seed()); XCTAssertEqual(cache.rowEncodingStatistics.retained, 0)
    }
    func testMetadataValidationReuseRequiresExactBytesAndChangedPrivateLedgersStillFail() throws {
        let cache = DurableSnapshotReadCache(minimumFieldEncodingBytes: 0)
        var value = seed()
        _ = try cache.encode(value); XCTAssertEqual(cache.metadataValidationCount, 1)
        value.tables["tasks"]![0]["due_date"] = .string("2026-11-10")
        try exact(cache.encode(value), value); XCTAssertEqual(cache.metadataValidationCount, 1)
        value.sharedCaptureReceipts = ["Café": "receipt"]
        _ = try cache.encode(value); XCTAssertEqual(cache.metadataValidationCount, 2)
        value.sharedCaptureReceipts = ["Cafe\u{301}": "receipt"]
        let revised = try cache.encode(value); XCTAssertEqual(cache.metadataValidationCount, 3)
        let current = try cache.decode(revised)
        XCTAssertEqual(Data(try XCTUnwrap(current.sharedCaptureReceipts?.keys.first).utf8), Data("Cafe\u{301}".utf8))
        value.timeSnoozes = ["bad": try TaskfoldJSONDecoder().decode(TimeSnoozeIntent.self, from: Data(#"{"version":1,"id":"bad","account":"bad","epoch":"bad","taskID":"bad","specID":"bad","signature":"bad","originalAt":0,"fireAt":0,"phase":"queued","revision":0}"#.utf8))]
        let invalid = try cache.encode(value)
        XCTAssertEqual(cache.metadataValidationCount, 4)
        XCTAssertThrowsError(try cache.decode(invalid), "A previous valid header must never certify changed invalid private recovery data")
    }
    func testInvalidNumbersAndDepthKeepTheOrdinaryFailureContract() throws {
        let (cache, initial) = try primed(seed()); var value = initial
        value.tables["tasks"]![0]["invalid"] = .number(.nan)
        XCTAssertThrowsError(try cache.encode(value))
        var deep: JSON = .null
        for _ in 0..<512 { deep = .array([deep]) }
        value = initial; value.tables["tasks"]![0]["deep"] = deep
        XCTAssertThrowsError(try TaskfoldJSONEncoder().encode(value)); XCTAssertThrowsError(try cache.encode(value))
    }
    func testCancelledPreparationDoesNotProduceAdoptableRows() async throws {
        let cache = DurableSnapshotReadCache(minimumFieldEncodingBytes: 0)
        _ = try cache.decode(TaskfoldJSONEncoder().encode(seed()))
        let request = try XCTUnwrap(cache.rowPreparationRequest()), gate = DispatchSemaphore(value: 0)
        func awaitGate() { gate.wait() }
        let work = Task.detached { awaitGate(); return try DurableSnapshotReadCache.prepareRows(request) }
        work.cancel(); gate.signal()
        do { _ = try await work.value; XCTFail("Cancelled preparation must not succeed") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(cache.rowEncodingStatistics.retained, 0)
    }
    func testLargeEditedRowKeepsItsTextAndOtherRowsExact() throws {
        var source = seed()
        source.tables["tasks"]![0]["description"] = .string(String(repeating: "Keep this exact plain text. ", count: 100_000))
        let (cache, original) = try primed(source); var value = original
        value.tables["tasks"]![0]["due_date"] = .string("2026-11-10")
        try exact(cache.encode(value), value)
        XCTAssertEqual(cache.rowEncodingStatistics.reused, 2)
        XCTAssertEqual(cache.rowEncodingStatistics.encoded, 1)
        XCTAssertEqual(value.tables["tasks"]![0]["description"], original.tables["tasks"]![0]["description"])
    }
    func testPlainRowDepthBoundaryMatchesWholeEnvelopeValidation() throws {
        for depth in [506, 507, 508, 509, 510] {
            let (cache, original) = try primed(seed()); var value = original, nested: JSON = .null
            for _ in 0..<depth { nested = .array([nested]) }
            value.tables["tasks"]![0]["deep"] = nested
            let expected = Result { try TaskfoldJSONEncoder().encode(value) }
            switch expected {
            case .failure: XCTAssertThrowsError(try cache.encode(value), "depth=\(depth)")
            case .success(let reference):
                let actual = try cache.encode(value)
                if (try? TaskfoldJSONDecoder().decode(Snapshot.self, from: reference)) == nil {
                    XCTAssertThrowsError(try TaskfoldJSONDecoder().decode(Snapshot.self, from: actual))
                } else { try exact(actual, value) }
            }
        }
    }
    func testPreparedRowsDiagnosticWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["TASKFOLD_ROW_ENCODING_REPORT"] else { return }
        var reports: [[String: Any]] = []
        for payloadOnEditedRow in [false, true] {
            var source = Snapshot(tables: ["tasks": (0..<2004).map { index in
                var row = Record.task(user: "local", createdAt: "2026-11-01T10:00:00Z")
                row["id"] = .string("task-\(index)"); row["title"] = .string("Task \(index)")
                if index == (payloadOnEditedRow ? 0 : 4) { row["future"] = .string(String(repeating: "Keep this exact synthetic reference. ", count: 80000)) }
                return row
            }])
            WidgetCompletion.prepare(&source)
            let wire = try TaskfoldJSONEncoder().encode(source), cached = DurableSnapshotReadCache(), ordinary = DurableSnapshotReadCache()
            var value = try cached.decode(wire); _ = try ordinary.decode(wire)
            XCTAssertTrue(cached.adoptRows(try DurableSnapshotReadCache.prepareRows(try XCTUnwrap(cached.rowPreparationRequest()))))
            _ = try cached.encode(value); _ = try ordinary.encode(value)
            var referenceSeconds = 0.0, cachedSeconds = 0.0
            for pass in 0..<5 {
                value.tables["tasks"]![0]["due_date"] = .string("2026-11-\(pass + 10)")
                var start = ProcessInfo.processInfo.systemUptime
                let reference = try ordinary.encode(value); referenceSeconds += ProcessInfo.processInfo.systemUptime - start
                start = ProcessInfo.processInfo.systemUptime
                let result = try cached.encode(value); cachedSeconds += ProcessInfo.processInfo.systemUptime - start
                try exact(reference, value); try exact(result, value)
                XCTAssertGreaterThanOrEqual(cached.rowEncodingStatistics.reused, 2003)
            }
            reports.append(["payloadOnEditedRow": payloadOnEditedRow, "ordinarySeconds": referenceSeconds, "preparedSeconds": cachedSeconds, "rowsReused": cached.rowEncodingStatistics.reused, "sameValues": true])
        }
        try JSONSerialization.data(withJSONObject: ["rows": 2004, "passes": 5, "modes": reports, "debugPreparationOnly": true, "reference": "Same codec without prepared rows; identical metadata-validation policy in both", "physicalFPSClaim": false], options: [.sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
