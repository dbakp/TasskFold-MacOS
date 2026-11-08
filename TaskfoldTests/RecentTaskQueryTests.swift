import XCTest
@testable import TaskfoldCore

final class RecentTaskQueryTests: XCTestCase {
    private func row(_ id: Int, project: String = "p0") -> Record {
        Record(["id": .string("task-\(id)"), "user_id": .string("owner"), "title": .string("Task \(id)"),
                "project_id": .string(project), "completed": .bool(false), "priority": .number(1)])
    }
    private func query(_ index: Int) -> TaskQuery {
        var result = TaskQuery(scope: .project("p\(index)")); result.today = "2026-11-08"; return result
    }
    func testFrequentlyVisitedProjectsSurviveSearchChurn() {
        let cache = TaskCache(); cache.update((0..<144).map { row($0, project: "p\($0 % 36)") })
        for index in 0..<36 { XCTAssertEqual(cache.matching(query(index)).count, 4) }
        for index in 0..<128 {
            var search = TaskQuery(scope: .all); search.text = "No matching task \(index)"
            XCTAssertTrue(cache.matching(search).isEmpty)
            for hot in 0..<36 { XCTAssertEqual(cache.matching(query(hot)).count, 4) }
        }
        XCTAssertEqual(cache.computationCount, 36 + 128, "Searches must not flush recently used projects")
    }
    func testEvictsOneLeastRecentlyUsedQueryAndPromotesHits() {
        let cache = TaskCache(); cache.update([row(1)])
        for index in 0..<64 { _ = cache.matching(query(index)) }
        _ = cache.matching(query(0))
        _ = cache.matching(query(64)); XCTAssertEqual(cache.computationCount, 65)
        _ = cache.matching(query(0)); _ = cache.matching(query(2)); XCTAssertEqual(cache.computationCount, 65)
        _ = cache.matching(query(1)); XCTAssertEqual(cache.computationCount, 66, "Only the least recently used query was evicted")
        _ = cache.matching(query(4)); XCTAssertEqual(cache.computationCount, 66)
    }
    func testCapacityRemainsBoundedAndTaskChangesInvalidateAllResults() {
        let cache = TaskCache(); var task = row(1); cache.update([task])
        for index in 0..<128 { _ = cache.matching(query(index)) }
        XCTAssertEqual(cache.computationCount, 128)
        for index in 64..<128 { _ = cache.matching(query(index)) }
        XCTAssertEqual(cache.computationCount, 128)
        _ = cache.matching(query(0)); XCTAssertEqual(cache.computationCount, 129)
        XCTAssertFalse(cache.update([task])); _ = cache.matching(query(127)); XCTAssertEqual(cache.computationCount, 129)
        task["title"] = .string("Edited task"); XCTAssertTrue(cache.update([task]))
        XCTAssertEqual(cache.matching(query(0)).first?.title, "Edited task")
        XCTAssertEqual(cache.computationCount, 130)
        cache.update([]); XCTAssertTrue(cache.matching(query(0)).isEmpty)
    }
    func testNonClockQueriesIgnoreTimestampButSeparateText() {
        let cache = TaskCache(); cache.update([row(1)])
        var first = query(0); first.now = Date(timeIntervalSince1970: 100)
        var later = first; later.now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(cache.matching(first), cache.matching(later))
        XCTAssertEqual(cache.computationCount, 1)
        later.text = "missing"; XCTAssertTrue(cache.matching(later).isEmpty)
        XCTAssertEqual(cache.computationCount, 2)
        XCTAssertEqual(cache.matching(first).count, 1)
    }
    func testSustainedProjectSearchJourneyReportsActualRecomputations() {
        let cache = TaskCache(); cache.update((0..<2004).map { row($0, project: "p\($0 % 36)") })
        let start = Date.timeIntervalSinceReferenceDate
        for index in 0..<36 { _ = cache.matching(query(index)) }
        for index in 0..<128 {
            var search = TaskQuery(scope: .all); search.text = "Task \(index)"; _ = cache.matching(search)
            for hot in 0..<36 { XCTAssertFalse(cache.matching(query(hot)).isEmpty) }
        }
        print("RECENT_QUERY_JOURNEY computations=\(cache.computationCount) seconds=\(Date.timeIntervalSinceReferenceDate - start)")
        XCTAssertEqual(cache.matching(query(0)).first?.string("project_id"), "p0")
    }
}
