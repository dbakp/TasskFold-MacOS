import XCTest
@testable import TaskfoldCore

final class DayOrderPreparationTests: XCTestCase {
    /// Frozen pre-change ordering: manual rank first, then stable priority bands.
    private func legacy(_ rows: [Record], ids: [String]) -> [Record] {
        DayPlacement.ordered(rows, ids: ids).enumerated().sorted { a, b in
            a.element.priority == b.element.priority ? a.offset < b.offset : a.element.priority < b.element.priority
        }.map(\.element)
    }
    private func row(_ id: String, priority: JSON, marker: Int) -> Record {
        Record(["id": .string(id), "priority": priority, "title": .string("Task \(marker)"),
                "future": .object(["position": .number(Double(marker))]),
                "subtasks": .array([.object(["id": .string("child-\(marker)"), "title": .string("Keep exact child")])])])
    }
    func testPriorityBandsManualAnchorsAndStableDuplicateRows() {
        let rows = [row("a", priority: .number(3), marker: 0), row("b", priority: .number(1), marker: 1),
                    row("a", priority: .number(3), marker: 2), row("c", priority: .number(1), marker: 3),
                    row("", priority: .number(4), marker: 4)]
        let result = DayPlacement.arranged(rows, ids: ["a", "missing", "c", "a", "b"])
        XCTAssertEqual(result.map(\.title), ["Task 3", "Task 1", "Task 0", "Task 2", "Task 4"])
        XCTAssertTrue(AuthoredValueComparison.sameRows(result, legacy(rows, ids: ["a", "missing", "c", "a", "b"])))
    }
    func testMixedMalformedValuesAndMutationSequencesKeepEveryExactRow() {
        let priorities: [JSON] = [.null, .number(-3), .number(0), .number(1), .number(4), .number(99), .string("2"), .object(["future": .bool(true)])]
        var rows = (0..<192).map { row(["same", "", "Café", "Cafe\u{301}", "task-\($0)"][$0 % 5], priority: priorities[$0 % priorities.count], marker: $0) }
        for pass in 0..<36 {
            let ids = pass % 3 == 0 ? [] : ["deleted", "same", "Café", "", "same", "task-7", "Cafe\u{301}"]
            let actual = DayPlacement.arranged(rows, ids: ids)
            XCTAssertTrue(AuthoredValueComparison.sameRows(actual, legacy(rows, ids: ids)), "Pass \(pass)")
            XCTAssertEqual(actual.count, rows.count)
            switch pass % 6 {
            case 0: rows.reverse()
            case 1: rows[pass % rows.count]["priority"] = priorities[(pass + 1) % priorities.count]
            case 2: rows[pass % rows.count]["title"] = .string("Edited \(pass)")
            case 3: rows.remove(at: pass % rows.count)
            case 4: rows.append(row("new-\(pass)", priority: .number(2), marker: pass + 1000))
            default: rows = rows.map { Record($0.fields) }
            }
        }
        XCTAssertTrue(DayPlacement.arranged([], ids: ["stale"]).isEmpty)
    }
    func testSparseHeadingAnchorsRetainOutlineOrder() {
        var heading = row("heading", priority: .number(2), marker: 0)
        heading["is_heading"] = .bool(true)
        let childID = SubtaskTree.reference(parent: "heading", key: "child")
        let rows = [heading, row(childID, priority: .number(2), marker: 1), row("other", priority: .number(2), marker: 2)]
        let ids = ["heading", "other"]
        // The existing outline expansion still supplies the same explicit order.
        XCTAssertEqual(DayPlacement.arrangedOutline(rows, ids: ids).map(\.id), ["heading", childID, "other"])
    }
    func testPreparationDiagnosticWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["TASKFOLD_DAY_ORDER_REPORT"] else { return }
        var cases: [[String: Any]] = []
        for count in [2000, 10000] {
            let rows = (0..<count).map { row("task-\($0)", priority: .number(Double(($0 * 71) % 4 + 1)), marker: $0) }
            for mode in ["no-manual-order", "sparse", "full-reverse"] {
                let ids = mode == "no-manual-order" ? [] : mode == "sparse" ? stride(from: 0, to: count, by: 7).map { "task-\($0)" } : rows.reversed().map(\.id)
                var oldTimes: [Double] = [], newTimes: [Double] = []
                for pass in 0..<9 {
                    var expected: [Record] = [], actual: [Record] = []
                    func old() { let start = ProcessInfo.processInfo.systemUptime; expected = legacy(rows, ids: ids); oldTimes.append(ProcessInfo.processInfo.systemUptime - start) }
                    func new() { let start = ProcessInfo.processInfo.systemUptime; actual = DayPlacement.arranged(rows, ids: ids); newTimes.append(ProcessInfo.processInfo.systemUptime - start) }
                    if pass.isMultiple(of: 2) { old(); new() } else { new(); old() }
                    XCTAssertTrue(AuthoredValueComparison.sameRows(actual, expected))
                }
                cases.append(["rows": count, "mode": mode, "legacyMedianMS": oldTimes.sorted()[4] * 1000,
                              "preparedMedianMS": newTimes.sorted()[4] * 1000, "exactParity": true])
            }
        }
        try JSONSerialization.data(withJSONObject: ["cases": cases, "debugPreparationOnly": true, "wholeAppSmoothnessClaim": false], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

