import XCTest
@testable import TaskfoldCore

@MainActor final class SubtaskProgressReadTests: XCTestCase {
    private func node(_ id: String, done: Bool = false, kind: JSON = .null, children: [JSON] = []) -> JSON {
        .object(["id": .string(id), "title": .string(id), "completed": .bool(done), "is_heading": kind,
                 "subtasks": .array(children), "future": .object(["retain": .array([.null, .bool(false)])])])
    }
    private func context(_ account: String = "A", generation: UUID = UUID(), session: UUID = UUID(), access: UUID = UUID()) -> SubtaskProgressReadCache.Context {
        .init(workspace: .init(account: account, generation: generation), session: session, access: access)
    }
    private func legacy(_ value: JSON) -> (completed: Int, total: Int) {
        let rows = SubtaskTree.outline(value).filter { TaskKind.mayComplete($0.record) }
        return (rows.filter { $0.record.completed }.count, rows.count)
    }
    func testOnePassMatchesExistingOutlineAcrossMixedLegacyTrees() async throws {
        let opaque = try TaskfoldJSONDecoder().decode(JSON.self, from: Data("9999999999999999999999999999999999999999".utf8))
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = .sortedKeys
        for seed in 0..<120 {
            let children = (0..<5).map { n in node("leaf-\(n)", done: (seed+n)%3 == 0, kind: n == seed%5 ? .bool(true) : .null) }
            let source: JSON = .array([node("parent", done: seed%2 == 0, children: children),node("heading", done: true, kind: .bool(true), children: [node("under-heading", done: true)]),node("future-kind", kind: .string("future"), children: [node("under-future")]), .string("Legacy text"), .number(2), .null, opaque])
            let before = try encoder.encode(source), expected = legacy(source), actual = SubtaskTree.progress(source)
            XCTAssertEqual(actual.completed, expected.completed); XCTAssertEqual(actual.total, expected.total)
            XCTAssertEqual(try encoder.encode(source), before)
        }
        for source: JSON in [.null, .string("unsupported root"), .object([:])] { XCTAssertEqual(SubtaskTree.progress(source).total, 0) }
    }
    func testCompletionAndNestedCopyOnWriteInvalidateTheRetainedRead() async {
        let cache = SubtaskProgressReadCache(), c = context()
        let source: JSON = .array([node("parent", children: [node("child")])])
        XCTAssertEqual(cache.read(source,id:"root",context:c).completed,0)
        for _ in 0..<100 { XCTAssertEqual(cache.read(source,id:"root",context:c).total,2) }
        XCTAssertEqual(cache.computationCount,1)
        let edited = SubtaskTree.changing(source,id:"child",fields:["completed":.bool(true)])
        XCTAssertEqual(cache.read(edited,id:"root",context:c).completed,1)
        XCTAssertEqual(cache.computationCount,2)
        XCTAssertEqual(cache.read(source,id:"root",context:c).completed,0)
        XCTAssertEqual(cache.computationCount,3)
        var rows = source.list; rows[0] = node("replacement",done:true)
        XCTAssertEqual(cache.read(.array(rows),id:"root",context:c).total,1)
        XCTAssertEqual(cache.read(.array(rows),id:"root",context:c).completed,1)
        XCTAssertEqual(cache.computationCount,4)
    }
    func testSameCountDifferentContentsNeverReusesAResult() async {
        let cache = SubtaskProgressReadCache(), c = context()
        let first: JSON = .array([node("a")]), second: JSON = .array([node("a",done:true)])
        XCTAssertEqual(cache.read(first,id:"root",context:c).completed,0)
        XCTAssertEqual(cache.read(second,id:"root",context:c).completed,1)
        XCTAssertEqual(cache.computationCount,2)
    }
    func testWorkspaceSessionAndAccessBoundariesDiscardOldReadings() async {
        let cache = SubtaskProgressReadCache(), c = context(), source: JSON = .array([node("a")])
        let scopes = [c,context("B",generation:c.workspace.generation,session:c.session,access:c.access),context(generation:UUID(),session:c.session,access:c.access),context(generation:c.workspace.generation,session:UUID(),access:c.access),context(generation:c.workspace.generation,session:c.session,access:UUID())]
        for scope in scopes { XCTAssertEqual(cache.read(source,id:"root",context:scope).total,1); XCTAssertEqual(cache.count,1) }
        XCTAssertEqual(cache.computationCount,5)
        cache.clear(); XCTAssertEqual(cache.count,0); XCTAssertEqual(cache.retainedNodes,0)
    }
    func testEntryAndVisitedNodeBudgetsEvictLeastRecentlyReadRows() async {
        let cache = SubtaskProgressReadCache(maximumEntries:2,maximumNodes:4), c = context(), source: JSON = .array([node("a"),node("b")])
        _ = cache.read(source,id:"A",context:c); _ = cache.read(source,id:"B",context:c); _ = cache.read(source,id:"A",context:c)
        _ = cache.read(source,id:"C",context:c); XCTAssertEqual(cache.count,2); XCTAssertEqual(cache.retainedNodes,4)
        _ = cache.read(source,id:"A",context:c); XCTAssertEqual(cache.computationCount,3)
        _ = cache.read(source,id:"B",context:c); XCTAssertEqual(cache.computationCount,4)
        let large: JSON = .array((0..<5).map { node("large-\($0)") })
        XCTAssertEqual(cache.read(large,id:"large",context:c).total,5); XCTAssertEqual(cache.count,2); XCTAssertEqual(cache.retainedNodes,4)
    }
    func testDepthBoundaryKeepsExistingCountsWithoutRetainingTruncatedTrees() async {
        var value = node("leaf",done:true)
        for n in 0..<35 { value = node("parent-\(n)",children:[value]) }
        let source: JSON = .array([value]), expected = legacy(source), cache = SubtaskProgressReadCache(), c = context()
        XCTAssertEqual(cache.read(source,id:"root",context:c).total,expected.total)
        XCTAssertEqual(SubtaskTree.progress(source).completed,expected.completed)
        XCTAssertTrue(SubtaskTree.progressReading(source).truncated); XCTAssertEqual(cache.count,0)
    }
    func testDisabledCacheAndNonArrayValuesRemainUncached() async {
        let cache = SubtaskProgressReadCache(maximumEntries:0), c = context(), source: JSON = .array([node("a")])
        _ = cache.read(source,id:"A",context:c); _ = cache.read(source,id:"A",context:c)
        XCTAssertEqual(cache.count,0); XCTAssertEqual(cache.computationCount,2)
        let other = SubtaskProgressReadCache(); XCTAssertEqual(other.read(.string("future"),id:"A",context:c).total,0); XCTAssertEqual(other.count,0)
    }
    func testLargeRetainedChecklistDiagnostic() async {
        let source: JSON = .array((0..<4096).map { node("task-\($0)",done:$0%2 == 0) }), cache = SubtaskProgressReadCache(), c = context()
        let start = Date.timeIntervalSinceReferenceDate
        for _ in 0..<100 { let value=legacy(source); XCTAssertEqual(value.completed,2048); XCTAssertEqual(value.total,4096) }
        let baseline = (Date.timeIntervalSinceReferenceDate-start)*1000, current = Date.timeIntervalSinceReferenceDate
        for _ in 0..<100 { let value=cache.read(source,id:"root",context:c); XCTAssertEqual(value.completed,2048); XCTAssertEqual(value.total,4096) }
        let retained = (Date.timeIntervalSinceReferenceDate-current)*1000
        XCTAssertEqual(cache.computationCount,1)
        print("SUBTASK_PROGRESS_DIAGNOSTIC baseline_ms=\(baseline) retained_ms=\(retained) rounds=100 nodes=4096 computations=\(cache.computationCount)")
    }
}
