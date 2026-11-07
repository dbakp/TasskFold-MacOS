import XCTest
@testable import TaskfoldCore

final class TaskWorkloadCacheTests: XCTestCase {
    private func assertReading(_ actual: ProductiveTaskReading, _ expected: ProductiveTaskReading, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(AuthoredValueComparison.sameRows(actual.work, expected.work), file: file, line: line)
        XCTAssertTrue(AuthoredValueComparison.sameRows(actual.presentation, expected.presentation), file: file, line: line)
        XCTAssertTrue(AuthoredValueComparison.sameRows(actual.outline, expected.outline), file: file, line: line)
        XCTAssertEqual(actual.parents, expected.parents, file: file, line: line)
        XCTAssertEqual(actual.incompleteProjects, expected.incompleteProjects, file: file, line: line)
        XCTAssertEqual(actual.incomplete, expected.incomplete, file: file, line: line)
        XCTAssertEqual(actual.unavailable, expected.unavailable, file: file, line: line)
        for id in Set(actual.work.map(\.id) + expected.work.map(\.id) + ["missing"]) {
            XCTAssertEqual(actual.contains(id), expected.contains(id), file: file, line: line)
        }
    }
    func testAlternatingAllAndActiveWorkRetainsIndependentBoundedReadings() {
        let child: JSON = .object(["id": .string("child"), "title": .string("Design"), "completed": .bool(false)])
        let heading = Record(["id": .string("heading"), "title": .string("Heading"), "project_id": .string("active"), "is_heading": .bool(true), "subtasks": .array([child, .string("Legacy")])])
        let archived = Record(["id": .string("archived"), "project_id": .string("archived"), "title": .string("Private"), "is_heading": .bool(true), "subtasks": .object(["future": .bool(true)])])
        let inbox = Record(["id": .string("inbox"), "title": .string("Inbox"), "opaque": .object(["keep": .string("Café 🪴")])])
        let cache = TaskCache(), source = [heading, archived, inbox]
        cache.update(source)
        let all = ProductiveTaskReading(tasks: cache.tasks), active = ProductiveTaskReading(tasks: cache.tasks.filter { $0.string("project_id") != "archived" })
        for project in 0..<24 {
            assertReading(cache.productiveReading(), all)
            _ = cache.matching(TaskQuery(scope: .project("project-\(project)")))
            assertReading(cache.productiveReading(excluding: ["archived"]), active)
        }
        XCTAssertEqual(cache.productiveComputationCount, 2)
        XCTAssertTrue(all.incompleteProjects.contains("archived"))
        XCTAssertFalse(active.incompleteProjects.contains("archived"))
        // A different visibility mask replaces only the one filtered slot.
        assertReading(cache.productiveReading(excluding: ["active"]), ProductiveTaskReading(tasks: cache.tasks.filter { $0.string("project_id") != "active" }))
        assertReading(cache.productiveReading(), all)
        XCTAssertEqual(cache.productiveComputationCount, 3)
        assertReading(cache.productiveReading(excluding: ["archived"]), active)
        XCTAssertEqual(cache.productiveComputationCount, 4)
        XCTAssertFalse(cache.update(source))
        assertReading(cache.productiveReading(), all)
        assertReading(cache.productiveReading(excluding: ["archived"]), active)
        XCTAssertEqual(cache.productiveComputationCount, 4)
    }
    func testBothReadingsInvalidateAfterTaskEditsWorkspaceClearAndReplacement() {
        var first = Record(["id": .string("first"), "project_id": .string("active"), "title": .string("Before"), "completed": .bool(false)])
        let other = Record(["id": .string("other"), "project_id": .string("archived"), "completed": .bool(false)])
        let cache = TaskCache(); cache.update([first, other])
        let retained = cache.productiveReading()
        _ = cache.productiveReading(excluding: ["archived"])
        first["title"] = .string("After"); first["completed"] = .bool(true); first["project_id"] = .string("archived")
        cache.update([first, other])
        assertReading(cache.productiveReading(), ProductiveTaskReading(tasks: cache.tasks))
        XCTAssertTrue(cache.productiveReading(excluding: ["archived"]).work.isEmpty)
        XCTAssertEqual(cache.productiveComputationCount, 4)
        XCTAssertEqual(retained.work.first { $0.id == "first" }?.title, "Before")
        XCTAssertEqual(retained.work.first { $0.id == "first" }?.completed, false)
        cache.update([])
        XCTAssertTrue(cache.productiveReading().work.isEmpty)
        XCTAssertTrue(cache.productiveReading(excluding: ["archived"]).work.isEmpty)
        let next = Record(["id": .string("new-workspace"), "title": .string("New")])
        cache.update([next])
        XCTAssertEqual(cache.productiveReading().work.map(\.id), ["new-workspace"])
        XCTAssertEqual(cache.productiveReading(excluding: ["archived"]).work.map(\.id), ["new-workspace"])
        XCTAssertEqual(cache.productiveComputationCount, 8)
    }

    func testArchivedProjectNavigationMeasurementWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["TASKFOLD_WORKLOAD_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in same-host Debug workload measurement, not physical FPS") }
        let rows: [Record] = (0..<1600).map { i in
            let fields: [String: JSON] = ["id": .string("work-\(i)"), "title": .string("Task \(i)"), "project_id": .string("project-\(i % 32)"), "priority": .number(Double(i % 4 + 1)), "completed": .bool(i % 7 == 0), "opaque": .object(["keep": .string("Café 🪴")])]
            return Record(fields)
        }
        let original = rows, excluded: Set<String> = ["project-31"]
        var elapsed: [Double] = [], orderedIDs: [[String]] = []
        for _ in 0..<3 {
            let cache = TaskCache(); cache.update(rows)
            let cachedSource = cache.tasks
            let expectedActive = ProductiveTaskReading(tasks: cache.tasks.filter { !excluded.contains($0.string("project_id")) })
            let expected = (0..<24).map { project in cache.tasks.filter { $0.string("project_id") == "project-\(project)" && !$0.completed }.map(\.id) }
            var readings: [ProductiveTaskReading] = [], results: [[Record]] = []
            let start = ContinuousClock.now
            for project in 0..<24 {
                results.append(cache.matching(TaskQuery(scope: .project("project-\(project)"), sort: "manual")))
                readings.append(cache.productiveReading(excluding: excluded))
            }
            let duration = start.duration(to: .now).components
            elapsed.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
            for reading in readings {
                XCTAssertEqual(reading.work, expectedActive.work)
                XCTAssertEqual(reading.presentation, expectedActive.presentation)
                XCTAssertEqual(reading.outline, expectedActive.outline)
            }
            let orders = results.map { $0.map(\.id) }
            XCTAssertEqual(orders, expected)
            if orderedIDs.isEmpty { orderedIDs = orders } else { XCTAssertEqual(orders, orderedIDs) }
            XCTAssertTrue(AuthoredValueComparison.sameRows(cache.tasks, cachedSource))
        }
        XCTAssertEqual(rows, original)
        let observation: [String: Any] = ["taskCount": rows.count, "projectCount": 32, "queriedProjects": 24, "navigationMilliseconds": elapsed, "medianMilliseconds": elapsed.sorted()[1], "orderedIDs": orderedIDs, "sameHostDebugOnly": true, "physicalFPSClaim": false]
        print("TASKFOLD_WORKLOAD_MEASUREMENT " + String(data: try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
