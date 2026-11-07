import XCTest
@testable import TaskfoldCore

final class AuthoredValueComparisonTests: XCTestCase {
    func testCopyOnWriteNestedMutationCannotReuseTheOriginalResult() {
        let original: [JSON] = [.object(["name": .string("Guide"), "rows": .array([.string("Keep"), .number(-0.0)])])]
        let same = JSON.array(original)
        XCTAssertTrue(AuthoredValueComparison.exactJSON(same, .array(original)))
        var changed = original
        changed[0] = .object(["name": .string("Guide"), "rows": .array([.string("Changed"), .number(-0.0)])])
        XCTAssertFalse(AuthoredValueComparison.exactJSON(same, .array(changed)))
        XCTAssertTrue(AuthoredValueComparison.exactJSON(same, .array(original)))
    }
    func testIndependentEqualArraysAndDifferentLengthsRemainCorrect() {
        func make(_ count: Int) -> JSON { .array((0..<count).map { .object(["id": .number(Double($0)), "text": .string("Row \($0)")]) }) }
        XCTAssertTrue(AuthoredValueComparison.exactJSON(make(200), make(200)))
        XCTAssertFalse(AuthoredValueComparison.exactJSON(make(200), make(199)))
        XCTAssertTrue(AuthoredValueComparison.exactJSON(.array([]), .array([])))
        XCTAssertFalse(AuthoredValueComparison.exactJSON(.array([]), .array([.null])))
    }
    func testNestedAuthoredUnicodeAndObjectKeySpellingsAreNotNormalized() {
        let composed = JSON.array([.object(["text": .string("café")])])
        let decomposed = JSON.array([.object(["text": .string("cafe\u{301}")])])
        XCTAssertFalse(AuthoredValueComparison.exactJSON(composed, decomposed))
        XCTAssertFalse(AuthoredValueComparison.exactJSON(.array([.object(["é": .bool(true)])]), .array([.object(["e\u{301}": .bool(true)])])))
        XCTAssertTrue(AuthoredValueComparison.exactJSON(composed, composed))
    }
    func testNumericBitPatternsStayExactThroughSharedAndCopiedArrays() {
        let nan = Double(bitPattern: 0x7ff8000000000042)
        let values: [JSON] = [.number(-0.0), .number(nan)]
        XCTAssertTrue(AuthoredValueComparison.exactJSON(.array(values), .array(values)))
        XCTAssertTrue(AuthoredValueComparison.exactJSON(.array(values), .array([.number(-0.0), .number(nan)])))
        XCTAssertFalse(AuthoredValueComparison.exactJSON(.array(values), .array([.number(0.0), .number(nan)])))
        XCTAssertFalse(AuthoredValueComparison.exactJSON(.array(values), .array([.number(-0.0), .number(Double(bitPattern: 0x7ff8000000000043))])))
    }
    func testOpaqueValuesKeepTheirExistingExactContentContract() throws {
        let a = try TaskfoldJSONDecoder().decode(JSON.self, from: Data(#"[{"é":9007199254740993,"e\u0301":1,"future":1e1000}]"#.utf8))
        let b = try TaskfoldJSONDecoder().decode(JSON.self, from: Data(#"[{"é":9007199254740993,"e\u0301":1,"future":2e1000}]"#.utf8))
        XCTAssertTrue(AuthoredValueComparison.exactJSON(a, a))
        XCTAssertFalse(AuthoredValueComparison.exactJSON(a, b))
    }
    func testRecordReadReuseStillRefusesAChangedSiblingField() {
        let payload: [JSON] = (0..<1000).map { .object(["index": .number(Double($0)), "title": .string("Keep all details")]) }
        let one = Record(["id": .string("task"), "title": .string("Original"), "future": .array(payload)])
        let copy = Record(one.fields)
        XCTAssertTrue(AuthoredValueComparison.sameRows([one], [copy]))
        var edited = copy; edited["title"] = .string("Changed")
        XCTAssertFalse(AuthoredValueComparison.sameRows([one], [edited]))
        XCTAssertTrue(AuthoredValueComparison.sameRows([one], [copy]))
    }
    func testSharedNestedReadDiagnostic() throws {
        let payload: [JSON] = (0..<4096).map { .object(["id": .number(Double($0)), "title": .string("Workshop \($0) café"), "flags": .array([.bool(true), .number(-0.0)])]) }
        let source = Record(["id": .string("source"), "title": .string("Reference"), "future": .array(payload)])
        let left = [source], right = [Record(source.fields)]
        var samples: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            for _ in 0..<3 { XCTAssertTrue(AuthoredValueComparison.sameRows(left, right)) }
            let value = start.duration(to: .now).components
            samples.append((Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15) / 3)
        }
        guard let raw = ProcessInfo.processInfo.environment["TASKFOLD_COMPARE_DIAGNOSTIC"] else { return }
        let path = URL(fileURLWithPath: raw).resolvingSymlinksInPath()
        guard ["/tmp", "/private/tmp"].contains(path.deletingLastPathComponent().path), path.lastPathComponent.hasPrefix("taskfold-nested-read-"), path.pathExtension == "json", !FileManager.default.fileExists(atPath: path.path) else { throw NSError(domain: "TaskfoldSyntheticDiagnostic", code: 1) }
        let result: [String: Any] = ["syntheticOnly": true, "configuration": "SwiftPM Debug", "rows": 4096, "comparisonsPerSample": 3, "samplesMillisecondsPerComparison": samples, "medianMillisecondsPerComparison": samples.sorted()[2], "actualProductionComparison": true, "uiFPSAccepted": false]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: path, options: .atomic)
    }
    func testTaskCacheReusesSharedPayloadAndInvalidatesCopiedNestedEdits() {
        let payload: [JSON] = (0..<1000).map { .object(["index": .number(Double($0)), "note": .string("Keep this source")]) }
        let source = Record(["id": .string("task"), "title": .string("Guide"), "completed": .bool(false), "future": .array(payload)])
        let cache = TaskCache(), query = TaskQuery(scope: .inbox)
        XCTAssertTrue(cache.update([source]))
        XCTAssertEqual(cache.matching(query).map(\.id), ["task"])
        let count = cache.computationCount
        XCTAssertFalse(cache.update([Record(source.fields)]))
        XCTAssertEqual(cache.matching(query).map(\.id), ["task"]); XCTAssertEqual(cache.computationCount, count)
        var changedPayload = payload; changedPayload[500] = .object(["index": .number(500), "note": .string("Changed child")])
        var changed = source; changed["future"] = .array(changedPayload)
        XCTAssertTrue(cache.update([changed]))
        let rows = cache.matching(query)
        XCTAssertTrue(AuthoredValueComparison.exactJSON(rows[0]["future"], .array(changedPayload)))
        XCTAssertEqual(cache.computationCount, count + 1)
        XCTAssertFalse(cache.update([Record(changed.fields)]))
        XCTAssertEqual(cache.matching(query).map(\.id), ["task"]); XCTAssertEqual(cache.computationCount, count + 1)
    }

}

extension AuthoredValueComparisonTests {
    private func exactRowsReference(_ a: [Record], _ b: [Record]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { AuthoredValueComparison.exactJSON(.object($0.fields), .object($1.fields)) }
    }
    private func detached(_ rows: [Record]) -> [Record] {
        var output: [Record] = []; output.reserveCapacity(rows.count)
        for row in rows { output.append(row) }
        return output
    }
    func testCopiedRecordsKeepExactReferenceParityAcrossEveryFieldsWrite() {
        let nan = Double(bitPattern: 0x7ff8000000000042)
        let source = Record(["id": .string("a"), "title": .string("Café"), "zero": .number(-0.0), "nan": .number(nan), "future": .object(["nested": .array([.string("Keep"), .number(1)])])])
        let rows = [source, Record(["id": .string("b")])]
        let copy = detached(rows)
        XCTAssertFalse(rows.withUnsafeBufferPointer { a in copy.withUnsafeBufferPointer { a.baseAddress == $0.baseAddress } })
        XCTAssertTrue(AuthoredValueComparison.sameRows(rows, copy))
        let writes: [(inout Record) -> Void] = [
            { $0["title"] = .string("Changed") },
            { $0.fields["title"] = .string("Cafe\u{301}") },
            { $0["zero"] = .number(0) },
            { $0["nan"] = .number(Double(bitPattern: 0x7ff8000000000043)) },
            { $0.fields = source.fields },
            { $0.fields.merge(["extra": .bool(true)], uniquingKeysWith: { _, b in b }) },
            { $0.fields.removeValue(forKey: "title") },
            { var value = $0["future"].object; value["nested"] = .array([.string("Changed")]); $0["future"] = .object(value) },
            { $0.fields.removeAll() }
        ]
        for write in writes {
            var changed = detached(rows); write(&changed[0])
            XCTAssertFalse(changed[0].sharesAuthoredSource(with: source))
            XCTAssertEqual(AuthoredValueComparison.sameRows(rows, changed), exactRowsReference(rows, changed))
            XCTAssertTrue(AuthoredValueComparison.sameRows(rows, copy))
        }
        for candidate in [Array(rows.reversed()), Array(rows.dropLast()), rows + [source], [], rows.map { Record($0.fields) }] {
            XCTAssertEqual(AuthoredValueComparison.sameRows(rows, candidate), exactRowsReference(rows, candidate))
        }
    }
    func testReconstructedOpaqueRecordsRemainEqualButChangedOpaqueValuesRefuseReuse() throws {
        let data = Data(#"{"id":"opaque","future":{"é":9007199254740993,"e\u0301":1,"huge":1e1000},"zero":-0.0}"#.utf8)
        let original = try TaskfoldJSONDecoder().decode(Record.self, from: data)
        let reconstructed = try TaskfoldJSONDecoder().decode(Record.self, from: data)
        XCTAssertFalse(original.sharesAuthoredSource(with: reconstructed))
        XCTAssertTrue(AuthoredValueComparison.sameRows([original], [reconstructed]))
        let changedData = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "1e1000", with: "2e1000").utf8)
        let changed = try TaskfoldJSONDecoder().decode(Record.self, from: changedData)
        XCTAssertFalse(AuthoredValueComparison.sameRows([original], [changed]))
        XCTAssertTrue(AuthoredValueComparison.sameRows([original], [original]))
    }
    func testTaskCacheEqualRefreshKeepsQueriesThenTailAndOpaqueChangesInvalidate() {
        let rows = (0..<64).map { Record(["id": .string("task-\($0)"), "title": .string("Task \($0)"), "completed": .bool(false), "future": .object(["zero": .number(-0.0)])]) }
        let cache = TaskCache(), query = TaskQuery(scope: .inbox)
        XCTAssertTrue(cache.update(rows)); XCTAssertEqual(cache.matching(query).count, 64)
        let count = cache.computationCount
        let refreshed = rows.map { Record($0.fields) }
        XCTAssertFalse(cache.update(refreshed)); XCTAssertEqual(cache.matching(query).count, 64); XCTAssertEqual(cache.computationCount, count)
        var changed = detached(refreshed); changed[63]["title"] = .string("Current tail edit")
        XCTAssertTrue(cache.update(changed)); XCTAssertEqual(cache.matching(query).first { $0.id == "task-63" }?.title, "Current tail edit")
        XCTAssertEqual(cache.computationCount, count + 1)
        var opaque = detached(changed); opaque[63]["future"] = .object(["zero": .number(0)])
        XCTAssertTrue(cache.update(opaque)); let current = cache.matching(query)
        XCTAssertEqual(current.first { $0.id == "task-63" }?["future"].object["zero"], .number(0))
        XCTAssertEqual(cache.computationCount, count + 2)
        XCTAssertFalse(cache.update(opaque.map { Record($0.fields) })); XCTAssertEqual(cache.matching(query).count, 64); XCTAssertEqual(cache.computationCount, count + 2)
        XCTAssertEqual(rows[63].title, "Task 63")
    }
    func testRecordCopyComparisonDiagnosticWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["TASKFOLD_RECORD_COPY_REPORT"] else { return }
        let payload: [JSON] = (0..<12).map { .object(["index": .number(Double($0)), "label": .string("Keep the exact authored reference Café"), "flags": .array([.number(-0.0), .bool(true)])]) }
        let rows = (0..<2000).map { Record(["id": .string("task-\($0)"), "title": .string("Task \($0)"), "description": .string(String(repeating: "Keep the original notes. ", count: 8)), "future": .array(payload)]) }
        let copies = detached(rows), rebuilt = rows.map { Record($0.fields) }
        var tail = detached(rows); tail[1999]["title"] = .string("Edited tail")
        var first = detached(rows); first[0]["title"] = .string("Edited first")
        let modes: [(String, [Record], Bool)] = [("copied-unchanged", copies, true), ("tail-edit", tail, false), ("reconstructed-equal", rebuilt, true), ("first-edit", first, false)]
        var reports: [[String: Any]] = []
        for (name, candidate, expected) in modes {
            XCTAssertFalse(rows.withUnsafeBufferPointer { a in candidate.withUnsafeBufferPointer { a.baseAddress == $0.baseAddress } })
            var oldMatches = 0, newMatches = 0
            let oldStart = ProcessInfo.processInfo.systemUptime
            for _ in 0..<5 { if exactRowsReference(rows, candidate) { oldMatches += 1 } }
            let oldSeconds = ProcessInfo.processInfo.systemUptime - oldStart, newStart = ProcessInfo.processInfo.systemUptime
            for _ in 0..<5 { if AuthoredValueComparison.sameRows(rows, candidate) { newMatches += 1 } }
            let newSeconds = ProcessInfo.processInfo.systemUptime - newStart
            XCTAssertEqual(oldMatches, expected ? 5 : 0); XCTAssertEqual(oldMatches, newMatches)
            reports.append(["mode": name, "referenceSeconds": oldSeconds, "currentSeconds": newSeconds, "sameAnswer": oldMatches == newMatches])
        }
        try JSONSerialization.data(withJSONObject: ["rows": 2000, "passes": 5, "modes": reports, "debugPreparationOnly": true, "wholeAppFPSClaim": false], options: [.sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

extension AuthoredValueComparisonTests {
    func testEqualOpaqueRefreshPreservesCachedAuthoredBytesUntilContentChanges() throws {
        let a = Data(#"{"id":"task","future":{"é":9007199254740993,"e\u0301":1,"huge":1e1000}}"#.utf8)
        let b = Data(#"{"id":"task","future":{ "huge":10e999, "e\u0301":1, "é":9007199254740993 }}"#.utf8)
        let original = try TaskfoldJSONDecoder().decode(Record.self, from: a)
        let refreshed = try TaskfoldJSONDecoder().decode(Record.self, from: b)
        let encoder = TaskfoldJSONEncoder()
        let originalBytes = try encoder.encode(original["future"]), refreshedBytes = try encoder.encode(refreshed["future"])
        XCTAssertNotEqual(originalBytes, refreshedBytes)
        XCTAssertTrue(AuthoredValueComparison.sameRows([original], [refreshed]), "JSONB formatting and exact decimal equivalents keep the established content contract")
        let cache = TaskCache(), query = TaskQuery(scope: .inbox)
        XCTAssertTrue(cache.update([original])); _ = cache.matching(query)
        let count = cache.computationCount
        XCTAssertFalse(cache.update([refreshed]))
        XCTAssertEqual(try encoder.encode(try XCTUnwrap(cache.matching(query).first)["future"]), originalBytes)
        XCTAssertEqual(cache.computationCount, count)
        let copy = detached([refreshed])
        XCTAssertFalse(cache.update(copy)); XCTAssertEqual(cache.computationCount, count)
        let changed = try TaskfoldJSONDecoder().decode(Record.self, from: Data(String(decoding: b, as: UTF8.self).replacingOccurrences(of: "10e999", with: "2e1000").utf8))
        XCTAssertTrue(cache.update([changed]))
        XCTAssertEqual(try encoder.encode(try XCTUnwrap(cache.matching(query).first)["future"]), try encoder.encode(changed["future"]))
        XCTAssertEqual(cache.computationCount, count + 1)
        XCTAssertEqual(try encoder.encode(original["future"]), originalBytes)
    }
}
