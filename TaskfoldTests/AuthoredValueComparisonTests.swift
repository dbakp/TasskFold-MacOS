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
