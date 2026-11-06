import XCTest
@testable import TaskfoldCore

@MainActor final class SubtaskOrganizerReadTests: XCTestCase {
    private func node(_ id: String, title: String? = nil, children: [JSON] = []) -> JSON {
        .object(["id": .string(id), "title": .string(title ?? id), "subtasks": .array(children),
                 "future": .object(["keep": .array([.null, .bool(false)])])])
    }
    private func context(_ account: String = "A", generation: UUID = UUID(), session: UUID = UUID(), access: UUID = UUID(), taskID: String = "root") -> SubtaskOrganizerReadCache.Context {
        .init(workspace: .init(account: account, generation: generation), session: session, access: access, taskID: taskID)
    }
    func testIndexedMoveAvailabilityMatchesCanonicalPreparedTrees() async throws {
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = .sortedKeys
        for seed in 0..<30 {
            var serial = 0
            func branch(_ depth: Int) -> JSON {
                serial += 1; let id = "s\(seed)-\(serial)"
                return node(id, title: serial % 5 == 0 ? "👩🏽‍💻 Café\r\n" : id,
                    children: depth > 0 ? (0..<(seed % 3 + 1)).map { _ in branch(depth - 1) } : [])
            }
            let source = try SubtaskTree.prepared(.array((0..<3).map { _ in branch(seed % 4) }))
            let before = try encoder.encode(source)
            for depth in [0, 1, 5, 8, 9] {
                let reading = SubtaskTree.OrganizerReading(source, baseDepth: depth)
                XCTAssertEqual(reading.items, SubtaskTree.outline(source)); XCTAssertFalse(reading.hasEmptyTitle)
                for item in reading.items {
                    XCTAssertEqual(reading.item(item.id), item)
                    for direction in SubtaskTree.Move.allCases {
                        XCTAssertEqual(reading.canMove(item.id, direction), (try? SubtaskTree.moving(source, id: item.id, direction: direction, baseDepth: depth)) != nil, "\(seed):\(item.id):\(direction):\(depth)")
                    }
                }
            }
            XCTAssertEqual(try encoder.encode(source), before)
        }
    }
    func testMalformedAndAmbiguousRowsNeverOfferMoves() async {
        let bad: [JSON] = [.string("legacy"), .object(["id": .string("x"), "title": .number(1)]), node(""),
            .object(["id": .string("x"), "title": .string("x"), "subtasks": .string("opaque")])]
        for row in bad {
            let reading = SubtaskTree.OrganizerReading(.array([node("first"), row, node("last")]), baseDepth: 0)
            for item in reading.items { for direction in SubtaskTree.Move.allCases { XCTAssertFalse(reading.canMove(item.id, direction)) } }
        }
        let duplicate = SubtaskTree.OrganizerReading(.array([node("same"), node("same")]), baseDepth: 0)
        XCTAssertNil(duplicate.item("same")); XCTAssertFalse(duplicate.canMove("same", .down))
        let empty = SubtaskTree.OrganizerReading(.array([node("blank", title: " \n\t")]), baseDepth: 0)
        XCTAssertTrue(empty.hasEmptyTitle); XCTAssertNil(empty.item("missing"))
        for depth in [Int.min, Int.max] { XCTAssertFalse(SubtaskTree.OrganizerReading(.array([node("a"), node("b")]), baseDepth: depth).canMove("b", .indent)) }
    }
    func testRetainedSourceReusesReadingAndCopyOnWriteInvalidates() async {
        let source: JSON = .array([node("parent", children: [node("child")]), node("other")])
        let cache = SubtaskOrganizerReadCache(), c = context()
        for _ in 0..<100 { XCTAssertEqual(cache.read(source, baseDepth: 0, context: c).item("child")?.record.title, "child") }
        XCTAssertEqual(cache.computationCount, 1); XCTAssertEqual(cache.retainedNodes, 3)
        let edited = SubtaskTree.changing(source, id: "child", fields: ["title": .string("Changed"), "completed": .bool(true)])
        XCTAssertEqual(cache.read(edited, baseDepth: 0, context: c).item("child")?.record.title, "Changed")
        XCTAssertEqual(cache.computationCount, 2)
        XCTAssertEqual(cache.read(source, baseDepth: 0, context: c).item("child")?.record.title, "child")
        let moved = try! SubtaskTree.moving(source, id: "child", direction: .outdent)
        XCTAssertNil(cache.read(moved, baseDepth: 0, context: c).item("child")?.parent)
        XCTAssertEqual(cache.computationCount, 4)
        let replacement: JSON = .array([node("replacement"), node("other")])
        XCTAssertNil(cache.read(replacement, baseDepth: 0, context: c).item("parent"))
        XCTAssertEqual(cache.computationCount, 5)
    }
    func testScopeDepthAndExplicitClearDiscardRetainedReading() async {
        let cache = SubtaskOrganizerReadCache(), c = context(), source: JSON = .array([node("a")])
        let scopes = [c, context("B", generation: c.workspace.generation, session: c.session, access: c.access),
            context(generation: UUID(), session: c.session, access: c.access),
            context(generation: c.workspace.generation, session: UUID(), access: c.access),
            context(generation: c.workspace.generation, session: c.session, access: UUID()),
            context(generation: c.workspace.generation, session: c.session, access: c.access, taskID: "other")]
        for scope in scopes { _ = cache.read(source, baseDepth: 0, context: scope); XCTAssertEqual(cache.retainedNodes, 1) }
        XCTAssertEqual(cache.computationCount, 6)
        _ = cache.read(source, baseDepth: 1, context: scopes.last!); XCTAssertEqual(cache.computationCount, 7)
        cache.clear(); XCTAssertEqual(cache.retainedNodes, 0)
        _ = cache.read(source, baseDepth: 1, context: scopes.last!); XCTAssertEqual(cache.computationCount, 8)
    }
    func testBudgetsNonArraysAndTruncationDoNotRetain() async {
        let c = context(), source: JSON = .array([node("a"), node("b")])
        for budget in [-1, 0, 1] {
            let cache = SubtaskOrganizerReadCache(maximumNodes: budget)
            for _ in 0..<2 { XCTAssertEqual(cache.read(source, baseDepth: 0, context: c).items.count, 2) }
            XCTAssertEqual(cache.retainedNodes, 0); XCTAssertEqual(cache.computationCount, 2)
        }
        let cache = SubtaskOrganizerReadCache()
        for value: JSON in [.null, .string("opaque"), .object([:])] { _ = cache.read(value, baseDepth: 0, context: c); XCTAssertEqual(cache.retainedNodes, 0) }
        var deep = node("leaf")
        for n in 0..<35 { deep = node("ancestor-\(n)", children: [deep]) }
        let reading = cache.read(.array([deep]), baseDepth: 0, context: c)
        XCTAssertTrue(reading.truncated); XCTAssertEqual(cache.retainedNodes, 0)
        for item in reading.items { for direction in SubtaskTree.Move.allCases { XCTAssertFalse(reading.canMove(item.id, direction)) } }
    }
    func testOrganizerPresentationWorkDiagnostic() async {
        let source: JSON = .array((0..<256).map { node("row-\($0)") }), cache = SubtaskOrganizerReadCache(), c = context()
        let ids = SubtaskTree.outline(source).map(\.id), start = Date.timeIntervalSinceReferenceDate
        var legacyEnabled = 0
        for id in ids {
            XCTAssertNotNil(SubtaskTree.outline(source).first { $0.id == id })
            for direction in SubtaskTree.Move.allCases { if (try? SubtaskTree.moving(source, id: id, direction: direction)) != nil { legacyEnabled += 1 } }
        }
        let baseline = (Date.timeIntervalSinceReferenceDate - start) * 1000, now = Date.timeIntervalSinceReferenceDate
        var enabled = 0
        for id in ids {
            let reading = cache.read(source, baseDepth: 0, context: c)
            XCTAssertNotNil(reading.item(id))
            for direction in SubtaskTree.Move.allCases { if reading.canMove(id, direction) { enabled += 1 } }
        }
        XCTAssertEqual(enabled, legacyEnabled); XCTAssertEqual(cache.computationCount, 1)
        print("ORGANIZER_READ_DIAGNOSTIC nodes=256 baseline_ms=\(baseline) indexed_ms=\((Date.timeIntervalSinceReferenceDate-now)*1000) computations=\(cache.computationCount)")
    }
}
