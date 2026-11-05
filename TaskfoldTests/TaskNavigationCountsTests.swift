import XCTest
@testable import TaskfoldCore

final class TaskNavigationCountsTests: XCTestCase {
    private func task(_ id: String, project: String = "p", labels: [JSON] = [], done: Bool = false, heading: Bool = false, children: [JSON] = []) -> Record {
        Record(["id": .string(id), "user_id": .string("owner"), "title": .string(id), "project_id": .string(project), "labels": .array(labels), "completed": .bool(done), "is_heading": .bool(heading), "subtasks": .array(children)])
    }
    private func label(_ id: String, _ name: String) -> Record { Record(["id": .string(id), "name": .string(name)]) }
    private func baseline(_ counts: TaskNavigationCounts, reading: ProductiveTaskReading, labels: [Record], file: StaticString = #filePath, line: UInt = #line) {
        let open = reading.work.filter { TaskKind.mayComplete($0) && !$0.completed }
        XCTAssertEqual(counts.total, open.count, file: file, line: line)
        for project in Set(reading.work.map { $0.string("project_id") } + ["missing", ""]) {
            XCTAssertEqual(counts.project(project), open.filter { $0.string("project_id") == project }.count, project, file: file, line: line)
        }
        for label in labels {
            XCTAssertEqual(counts.label(label.id), open.filter { $0["labels"].list.contains(.string(label.id)) || $0["labels"].list.contains(.string(label.name)) }.count, label.name, file: file, line: line)
        }
        XCTAssertEqual(counts.label("missing"), 0, file: file, line: line)
    }
    func testLabelAliasesAreAUnionAndPreserveDuplicateNamesCaseAndLiteralValues() {
        let labels = [label("a", "Urgent"), label("b", "Urgent"), label("Urgent", "Other"), label("lower", "urgent"), label("empty", "")]
        let rows = [task("one", labels: [.string("a"), .string("Urgent"), .string("Urgent"), .number(1)]),
                    task("two", labels: [.string("b"), .string("urgent")]), task("three", labels: [.string("")]),
                    task("done", labels: [.string("Urgent")], done: true), task("inbox", project: "")]
        let reading = ProductiveTaskReading(tasks: rows), counts = TaskNavigationCounts(reading: reading, labels: labels)
        baseline(counts, reading: reading, labels: labels)
        XCTAssertEqual(counts.label("a"), 1); XCTAssertEqual(counts.label("b"), 2); XCTAssertEqual(counts.label("Urgent"), 1)
        XCTAssertEqual(counts.label("lower"), 1); XCTAssertEqual(counts.label("empty"), 1); XCTAssertEqual(counts.project(""), 1)
    }
    func testHeadingDescendantsLegacyWorkAndOrdinaryChecklistsKeepExistingSemantics() {
        let child = task("child", labels: [.string("a")]), done = task("done", done: true)
        let heading = task("heading", labels: [.string("b")], heading: true, children: [.object(child.fields), .object(done.fields), .string("Legacy work")])
        let ordinary = task("ordinary", labels: [.string("b")], children: [.object(child.fields)])
        var unreadable = task("unreadable", project: "other", heading: true); unreadable["subtasks"] = .object(["future": .bool(true)])
        let reading = ProductiveTaskReading(tasks: [heading, ordinary, unreadable]), labels = [label("a", "A"), label("b", "B")]
        let counts = TaskNavigationCounts(reading: reading, labels: labels)
        baseline(counts, reading: reading, labels: labels)
        XCTAssertEqual(counts.total, 3); XCTAssertEqual(counts.project("p"), 3)
        XCTAssertEqual(counts.label("a"), 1); XCTAssertEqual(counts.label("b"), 1)
        XCTAssertEqual(reading.countLabel(counts.project("other"), project: "other"), "≥0")
    }
    func testCacheReusesReadsButTracksCompletionMoveAndLabelCatalogChanges() {
        let cache = TaskCache(), labels = [label("a", "Old")]
        var row = task("one", labels: [.string("Old")]); cache.update([row])
        let original = cache.navigationCounts(labels: labels)
        for _ in 0..<100 { _ = cache.navigationCounts(labels: labels) }
        XCTAssertEqual(cache.navigationComputationCount, 1); XCTAssertEqual(original.label("a"), 1)
        XCTAssertFalse(cache.update([row])); _ = cache.navigationCounts(labels: labels)
        XCTAssertEqual(cache.navigationComputationCount, 1)
        let renamed = [label("a", "New")]
        XCTAssertEqual(cache.navigationCounts(labels: renamed).label("a"), 0)
        XCTAssertEqual(cache.navigationCounts(labels: renamed + [label("b", "Old")]).label("b"), 1)
        XCTAssertEqual(cache.navigationCounts(labels: []).label("a"), 0)
        row["completed"] = .bool(true); cache.update([row]); XCTAssertEqual(cache.navigationCounts(labels: labels).total, 0)
        row["completed"] = .bool(false); row["project_id"] = .string("other"); row["labels"] = .array([.string("a")]); cache.update([row])
        let moved = cache.navigationCounts(labels: labels)
        XCTAssertEqual(moved.project("p"), 0); XCTAssertEqual(moved.project("other"), 1); XCTAssertEqual(moved.label("a"), 1)
        XCTAssertEqual(original.project("p"), 1); XCTAssertEqual(original.project("other"), 0)
    }
    func testArchiveAndSourceChangesNeverReturnCountsForAnotherReadScope() {
        let cache = TaskCache(); cache.update([task("one"), task("two", project: "other")])
        XCTAssertEqual(cache.navigationCounts(labels: []).total, 2)
        XCTAssertEqual(cache.navigationCounts(labels: [], excluding: ["p"]).total, 1)
        _ = cache.productiveReading(excluding: ["other"])
        XCTAssertEqual(cache.navigationCounts(labels: [], excluding: ["p"]).project("p"), 0)
        XCTAssertEqual(cache.navigationCounts(labels: [], excluding: ["p", "other"]).total, 0)
        XCTAssertEqual(cache.navigationCounts(labels: []).total, 2)
        cache.update([]); XCTAssertEqual(cache.navigationCounts(labels: []).total, 0)
        cache.update([task("new", project: "new-workspace")]); XCTAssertEqual(cache.navigationCounts(labels: []).project("p"), 0)
    }
    func testColdCopyCompletionUndoAndLabelRenameRoundTripKeepCounts() throws {
        let rows = [task("one", labels: [.string("A")]), task("two", project: "other", done: true)]
        let cache = TaskCache(), labels = [label("a", "A")]
        cache.update(rows); let before = cache.navigationCounts(labels: labels)
        var completed = rows; completed[0]["completed"] = .bool(true); cache.update(completed)
        XCTAssertEqual(cache.navigationCounts(labels: labels).total, 0)
        let cold = try JSONDecoder().decode([Record].self, from: JSONEncoder().encode(rows))
        cache.update(cold); let restored = cache.navigationCounts(labels: labels)
        XCTAssertEqual(restored.total, before.total); XCTAssertEqual(restored.label("a"), before.label("a"))
        let renamed = [label("a", "Renamed")]
        XCTAssertEqual(cache.navigationCounts(labels: renamed).label("a"), 0)
        baseline(restored, reading: ProductiveTaskReading(tasks: cold), labels: labels)
    }
    func testLargeCatalogMatchesOriginalBadgeSemanticsAndRetainedReadsDoNoRecount() {
        let labels = (0..<64).map { label("l\($0)", "Label \($0)") }
        let rows = (0..<4096).map { index in task("t\(index)", project: "p\(index % 128)", labels: [.string("l\(index % 64)"), .string("Label \(index % 64)"), .string("l\((index + 1) % 64)")], done: index % 5 == 0) }
        let cache = TaskCache(); cache.update(rows)
        let counts = cache.navigationCounts(labels: labels)
        baseline(counts, reading: cache.productiveReading(), labels: labels)
        let start = Date()
        var checksum = 0
        for _ in 0..<100 {
            let reading = cache.navigationCounts(labels: labels)
            for index in 0..<128 { checksum += reading.project("p\(index)") }
            for label in labels { checksum += reading.label(label.id) }
        }
        XCTAssertGreaterThan(checksum, 0); XCTAssertEqual(cache.navigationComputationCount, 1)
        print("Navigation retained 4096-task/128-project/64-label reads, 100 rounds: \(Date().timeIntervalSince(start) * 1000) ms; no physical rendering claim")
    }
}
