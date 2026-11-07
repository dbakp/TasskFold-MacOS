import XCTest
@testable import TaskfoldCore

final class TaskOrderPreparationTests: XCTestCase {
    private func reference(_ rows: [Record]) -> [Record] {
        rows.sorted { $0.priority == $1.priority ? $0.string("created_at") > $1.string("created_at") : $0.priority < $1.priority }
    }
    private func verify(_ cache: TaskCache, _ rows: [Record], file: StaticString = #filePath, line: UInt = #line) {
        _ = cache.update(rows)
        XCTAssertTrue(AuthoredValueComparison.sameRows(cache.tasks, reference(rows)), "Current rows must match the established stable order exactly", file: file, line: line)
    }
    private func task(_ id: String, _ priority: JSON, _ created: JSON) -> Record {
        Record(["id": .string(id), "title": .string(id), "priority": priority, "created_at": created, "completed": .bool(false), "future": .object(["keep": .string(id)])])
    }
    func testDateNoteAndCompletionEditsPublishCurrentRowsInTheEstablishedOrder() {
        let cache = TaskCache()
        var rows = [task("one", .number(3), .string("2026-11-05")), task("two", .number(1), .string("2026-11-03")), task("three", .number(1), .string("2026-11-06"))]
        verify(cache, rows)
        let order = cache.tasks.map(\.id)
        _ = cache.matching(TaskQuery(scope: .all)); let count = cache.computationCount
        rows[0]["due_date"] = .string("2026-11-08")
        rows[1]["description"] = .string("Current instructions")
        rows[2]["completed"] = .bool(true)
        rows[2]["future"] = .array([.string("Current opaque value")])
        verify(cache, rows)
        XCTAssertEqual(cache.tasks.map(\.id), order)
        XCTAssertEqual(cache.tasks.first?.completed, true)
        XCTAssertEqual(cache.tasks.last?.string("due_date"), "2026-11-08")
        XCTAssertEqual(cache.matching(TaskQuery(scope: .all)).map(\.id), ["two", "one"])
        XCTAssertEqual(cache.computationCount, count + 1)
        XCTAssertEqual(cache.tasks.first?["future"], .array([.string("Current opaque value")]))
    }
    func testPriorityCreationAndMembershipChangesRebuildTheRightOrder() {
        let cache = TaskCache()
        var rows = [task("one", .number(4), .string("A")), task("two", .number(2), .string("B")), task("three", .number(2), .string("C"))]
        verify(cache, rows)
        rows[0]["priority"] = .number(1); verify(cache, rows)
        XCTAssertEqual(cache.tasks.first?.id, "one")
        rows[1]["created_at"] = .string("Z"); verify(cache, rows)
        XCTAssertEqual(cache.tasks.map(\.id), ["one", "two", "three"])
        rows.append(task("new", .number(1), .string("Z"))); verify(cache, rows)
        rows.remove(at: 0); verify(cache, rows)
        verify(cache, []); verify(cache, rows)
        rows.reverse(); verify(cache, rows)
        verify(cache, rows.map { Record($0.fields) })
    }
    func testStableTiesUseSourcePositionsIncludingDuplicateAndMissingIDs() {
        let cache = TaskCache()
        var rows = [task("same", .number(2), .string("Café")), task("same", .number(2), .string("Cafe\u{301}")), task("", .number(2), .string("Café"))]
        for i in rows.indices { rows[i]["title"] = .string("Position \(i)") }
        verify(cache, rows)
        XCTAssertEqual(cache.tasks.map(\.title), ["Position 0", "Position 1", "Position 2"])
        rows.reverse(); verify(cache, rows)
        XCTAssertEqual(cache.tasks.map(\.title), ["Position 2", "Position 1", "Position 0"])
        rows[1]["id"] = .string("renamed"); rows[1]["title"] = .string("Current identity")
        verify(cache, rows)
        XCTAssertEqual(cache.tasks[1].id, "renamed")
        rows[2]["created_at"] = .string("Cafe\u{301}"); verify(cache, rows)
    }
    func testMalformedSortValuesAndFilteredSnapshotsRetainReferenceParity() {
        let cache = TaskCache()
        var rows = [task("one", .null, .null), task("two", .number(-2), .number(3)), task("three", .number(99), .object(["future": .bool(true)])), task("four", .string("2"), .string("Z"))]
        verify(cache, rows)
        for i in rows.indices { rows[i]["title"] = .string("Updated \(i)") }
        verify(cache, rows.map { Record($0.fields) })
        verify(cache, Array(rows.dropFirst()))
        verify(cache, rows)
        rows.swapAt(0, 3); verify(cache, rows)
        rows[1]["priority"] = .number(0); verify(cache, rows)
    }
    func testMixedMutationSequenceRetainsCurrentRowsAndOrder() {
        let cache = TaskCache()
        var rows = (0..<96).map { task("task-\($0)", .number(Double($0 % 4 + 1)), .string(String($0 % 11))) }
        for step in 0..<80 {
            let index = step % rows.count
            switch step % 8 {
            case 0: rows[index]["due_date"] = .string("2026-11-\(step)")
            case 1: rows[index]["priority"] = .number(Double(step % 4 + 1))
            case 2: rows[index]["created_at"] = .string("Changed \(step)")
            case 3: rows[index]["title"] = .string("Edited \(step)")
            case 4: rows.reverse()
            case 5: rows = rows.map { Record($0.fields) }
            case 6: rows.remove(at: index)
            default: rows.append(task("new-\(step)", .number(2), .string("New")))
            }
            verify(cache, rows)
        }
    }
    func testTaskOrderDiagnosticWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["TASKFOLD_TASK_ORDER_REPORT"] else { return }
        let original = (0..<2000).map { task("task-\($0)", .number(Double(($0 * 71) % 4 + 1)), .string(String(format: "%04d", ($0 * 71) % 2000))) }
        var reports: [[String: Any]] = []
        for mode in ["copied-date", "reconstructed-date", "priority-change", "creation-change"] {
            let cache = TaskCache(); _ = cache.update(original)
            var rows = original, seconds = 0.0
            for pass in 0..<10 {
                if mode == "reconstructed-date" { rows = rows.map { Record($0.fields) } }
                let index = rows.count - 1 - pass
                if mode == "priority-change" { rows[index]["priority"] = .number(Double(pass % 4 + 1)) }
                else if mode == "creation-change" { rows[index]["created_at"] = .string("New \(pass)") }
                else { rows[index]["due_date"] = .string("2026-11-\(pass + 10)") }
                let start = ProcessInfo.processInfo.systemUptime
                _ = cache.update(rows)
                seconds += ProcessInfo.processInfo.systemUptime - start
                XCTAssertTrue(AuthoredValueComparison.sameRows(cache.tasks, reference(rows)))
            }
            reports.append(["mode": mode, "seconds": seconds, "referenceParity": true])
        }
        try JSONSerialization.data(withJSONObject: ["rows": 2000, "passes": 10, "modes": reports, "debugPreparationOnly": true, "wholeAppFPSClaim": false], options: [.sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
