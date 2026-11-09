import XCTest
@testable import TaskfoldCore

final class HierarchyProjectionCacheTests: XCTestCase {
    private let workspace = WorkspaceBinding(account: "local", generation: UUID(uuidString: "a1000000-0000-4000-8000-000000000001")!)
    private let projects = [Record(["id": .string("p"), "name": .string("Studio")]), Record(["id": .string("q"), "name": .string("Other")])]
    private func root(_ id: String = "root", children: Int = 2) -> Record {
        Record(["id": .string(id), "title": .string("Café"), "user_id": .string("local"), "project_id": .string("p"), "created_at": .string("2026-11-01T10:00:00Z"), "opaque": .object(["Café": .number(-0.0)]),
                "subtasks": .array((0..<children).map { .object(["id": .string("child-\($0)"), "title": .string("Review \($0)"), "description": .string(String(repeating: "Keep the exact instructions. ", count: 20)), "completed": .bool(false)]) })])
    }
    private func index(_ roots: [Record], cache: TaskHierarchyIndex.ProjectionCache? = nil, projects other: [Record]? = nil, workspace context: WorkspaceBinding? = nil) throws -> TaskHierarchyIndex {
        try TaskHierarchyIndex(roots: roots, projects: other ?? projects, workspace: context ?? workspace, projections: cache)
    }
    private func assertParity(_ lhs: TaskHierarchyIndex, _ rhs: TaskHierarchyIndex, file: StaticString = #filePath, line: UInt = #line) throws {
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = .sortedKeys
        func values(_ index: TaskHierarchyIndex) -> [JSON] {
            index.items.map { .object(["id": .string($0.id), "source": .object($0.source.fields), "raw": $0.sourceFields, "root": .object($0.root.fields), "shown": .object($0.record.fields), "path": .array($0.path.map(JSON.string)), "parents": .array($0.parentTitles.map(JSON.string)), "independent": .bool($0.requiresIndependentWriter)]) }
        }
        XCTAssertEqual(lhs.workspace, rhs.workspace, file: file, line: line)
        XCTAssertEqual(lhs.excludedRootIDs, rhs.excludedRootIDs, file: file, line: line)
        XCTAssertEqual(try encoder.encode(values(lhs)), try encoder.encode(values(rhs)), file: file, line: line)
    }
    private func snapshot(_ rows: [Record]) -> Snapshot {
        Snapshot(tables: ["tasks": rows, "projects": projects, "saved_views": [Record(["id": .string("children"), "query_ast": FilterRule.predicate("subtask", "").document])]])
    }
    private func scope() -> WidgetCompletion.SignatureCache.Scope { .init(workspace: workspace, session: UUID(), access: UUID()) }

    func testUnchangedRootsReuseAndEditedParentShowsCurrentFields() throws {
        var rows = [root("one"), root("two"), root("three")]; let cache = TaskHierarchyIndex.ProjectionCache()
        _ = try index(rows, cache: cache)
        try assertParity(index(rows, cache: cache), index(rows)); XCTAssertEqual(cache.statistics.reused, 3)
        rows[0].mergeFields(["due_date": .string("2026-11-10"), "title": .string("Current parent")])
        let current = try index(rows, cache: cache)
        XCTAssertEqual(cache.statistics.reused, 2); XCTAssertEqual(cache.statistics.computed, 1)
        XCTAssertEqual(current.items[1].parentTitles.first, "Current parent")
        try assertParity(current, index(rows))
    }
    func testAuthoredWritesEqualValueWritesAndDecodeRequireFreshProof() throws {
        let original = root(); var variants: [Record] = []
        for (field, value) in [("title", JSON.string("Cafe\u{301}")), ("due_date", .string("2026-11-10")), ("id", .string("other-root")), ("project_id", .string("q")), ("section_id", .string("new")), ("is_heading", .bool(true)), ("opaque", .object(["Cafe\u{301}": .number(-0.0)])), ("opaque", .object(["Café": .number(0.0)])), ("subtasks", .array([]))] {
            var changed = original; changed[field] = value; variants.append(changed)
        }
        var same = original; same.fields = original.fields; variants.append(same)
        same = original; same["title"] = original["title"]; variants.append(same)
        variants.append(try TaskfoldJSONDecoder().decode(Record.self, from: TaskfoldJSONEncoder().encode(original)))
        for changed in variants {
            let cache = TaskHierarchyIndex.ProjectionCache(); _ = try index([original], cache: cache)
            let current = try index([changed], cache: cache)
            XCTAssertEqual(cache.statistics.reused, 0); XCTAssertEqual(cache.statistics.computed, 1)
            try assertParity(current, index([changed]))
        }
    }
    func testProjectVisibilityRootOrderAndInvalidIdentitiesStayFresh() throws {
        let rows = [root("one"), root("two")], cache = TaskHierarchyIndex.ProjectionCache()
        _ = try index(rows, cache: cache)
        try assertParity(index(rows.reversed(), cache: cache), index(rows.reversed()))
        XCTAssertEqual(cache.statistics.reused, 2)
        var archived = projects; archived[0]["is_archived"] = .bool(true)
        let hidden = try index(rows, cache: cache, projects: archived)
        XCTAssertTrue(hidden.items.isEmpty); XCTAssertEqual(hidden.excludedRootIDs, ["one", "two"])
        XCTAssertEqual(cache.statistics.retainedItems, 0)
        _ = try index(rows, cache: cache); XCTAssertEqual(cache.statistics.reused, 0)
        XCTAssertThrowsError(try index([rows[0], rows[0]], cache: cache)); XCTAssertEqual(cache.statistics.retainedItems, 0)
        let missing = try index(rows, cache: cache, projects: [])
        XCTAssertTrue(missing.items.isEmpty); XCTAssertEqual(missing.excludedRootIDs.count, 2)
    }
    func testWorkspaceAndBoundedRetentionFallBackWithoutRejectingTasks() throws {
        let rows = [root("one"), root("two"), root("three")], cache = TaskHierarchyIndex.ProjectionCache(maximumItems: 3)
        _ = try index(rows, cache: cache); XCTAssertEqual(cache.statistics.retainedItems, 3)
        try assertParity(index(rows, cache: cache), index(rows)); XCTAssertEqual(cache.statistics.reused, 1)
        _ = try index(rows, cache: cache, workspace: .init(account: "other", generation: workspace.generation))
        XCTAssertEqual(cache.statistics.reused, 0)
        for bytes in [0, 1, 1024] {
            var row = root(); row["large"] = .string(String(repeating: "x", count: 2048))
            let bounded = TaskHierarchyIndex.ProjectionCache(maximumBytes: bytes)
            _ = try index([row], cache: bounded); try assertParity(index([row], cache: bounded), index([row]))
            XCTAssertEqual(bounded.statistics.reused, 0); XCTAssertLessThanOrEqual(bounded.statistics.chargedBytes, bytes)
        }
        var deep: JSON = .bool(true); for _ in 0..<200 { deep = .array([deep]) }
        for extra in [deep, JSON.array(Array(repeating: .bool(true), count: 5000))] {
            var row = root(); row["opaque_large"] = extra
            let bounded = TaskHierarchyIndex.ProjectionCache()
            _ = try index([row], cache: bounded); try assertParity(index([row], cache: bounded), index([row]))
            XCTAssertEqual(bounded.statistics.retainedItems, 0)
        }
    }
    func testPreservedObjectsKeepExactRawFieldsAndIndependentWriterRequirement() throws {
        let opaque = try TaskfoldJSONDecoder().decode(JSON.self, from: Data(#"{"id":"opaque","title":"Keep","é":1,"é":2,"big":9007199254740993,"subtasks":[{"id":"nested","title":"Descendant"}]}"#.utf8))
        var row = root(); row["subtasks"] = .array([opaque])
        let cache = TaskHierarchyIndex.ProjectionCache(); _ = try index([row], cache: cache)
        let warm = try index([row], cache: cache)
        XCTAssertEqual(cache.statistics.reused, 1); XCTAssertTrue(warm.items[1].requiresIndependentWriter); XCTAssertTrue(warm.items[2].requiresIndependentWriter)
        try assertParity(warm, index([row]))
    }
    func testWidgetScopeAndWorkerSeedDoNotCarryTaskProjections() throws {
        let context = scope(), initial = snapshot([root()])
        for changed in [WidgetCompletion.SignatureCache.Scope(workspace: .init(account: "other", generation: workspace.generation), session: context.session, access: context.access), .init(workspace: .init(account: "local", generation: UUID()), session: context.session, access: context.access), .init(workspace: workspace, session: UUID(), access: context.access), .init(workspace: workspace, session: context.session, access: UUID())] {
            var value = initial; let cache = WidgetCompletion.SignatureCache()
            WidgetCompletion.prepare(&value, signatures: cache, scope: context); WidgetCompletion.prepare(&value, signatures: cache, scope: context)
            XCTAssertEqual(cache.hierarchyStatistics.reused, 1)
            WidgetCompletion.prepare(&value, signatures: cache, scope: changed)
            XCTAssertEqual(cache.hierarchyStatistics.reused, 0); XCTAssertEqual(cache.hierarchyStatistics.computed, 1)
        }
        var value = initial; let cache = WidgetCompletion.SignatureCache()
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        let seeded = WidgetCompletion.SignatureCache(seed: try XCTUnwrap(cache.seed(matching: context)))
        WidgetCompletion.prepare(&value, signatures: seeded, scope: context)
        XCTAssertEqual(seeded.statistics.reused, 3); XCTAssertEqual(seeded.hierarchyStatistics.reused, 0); XCTAssertEqual(seeded.hierarchyStatistics.computed, 1)
        WidgetCompletion.prepare(&value, signatures: cache)
        XCTAssertEqual(cache.hierarchyStatistics.retainedItems, 0)
    }
    func testVisibilityRemovalAndActualActionAdmissionIgnoreOldProjections() throws {
        var value = snapshot([root()]); let context = scope(), cache = WidgetCompletion.SignatureCache()
        WidgetCompletion.prepare(&value, signatures: cache, scope: context); WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        XCTAssertEqual(cache.hierarchyStatistics.reused, 1)
        let id = try XCTUnwrap(WidgetCompletion.childItems(value, account: "local").first?.id)
        let request = try WidgetCompletionRequest(account: "local", taskID: id, token: XCTUnwrap(value.widgetCompletion.states[id]?.token), at: Date(timeIntervalSince1970: 1_790_000_000))
        value.tables["tasks"]![0]["subtasks"] = SubtaskTree.changing(value.tables["tasks"]![0]["subtasks"], id: "child-0", fields: ["description": .string("Current instructions")])
        guard case .stale = WidgetCompletion.plan(request, snapshot: value, account: "local") else { return XCTFail("Cached display data authorized an old action") }
        value.tables["saved_views"] = []
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        XCTAssertEqual(cache.hierarchyStatistics.retainedItems, 0); XCTAssertNil(value.widgetCompletion.states[id])
        value.tables["tasks"]![0]["is_heading"] = .bool(true)
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        var reference = value; WidgetCompletion.prepare(&reference)
        XCTAssertEqual(value.widgetCompletion, reference.widgetCompletion)
        value.tables["tasks"] = []; WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        XCTAssertTrue(value.widgetCompletion.states.isEmpty); XCTAssertEqual(cache.hierarchyStatistics.retainedItems, 0)
    }
    func testCombinedItemLimitUsesOriginalRefusalAndDropsPartialCache() throws {
        let branch = root(children: 1), cache = TaskHierarchyIndex.ProjectionCache()
        _ = try index([branch], cache: cache)
        let rows = (0..<(TaskHierarchyIndex.maximumItems - 1)).map { Record(["id": .string("plain-\($0)"), "title": .string("Plain")]) } + [branch]
        var expected: String?
        do { _ = try index(rows); XCTFail("Oversized hierarchy accepted") } catch { expected = error.localizedDescription }
        XCTAssertThrowsError(try index(rows, cache: cache)) { XCTAssertEqual($0.localizedDescription, expected) }
        XCTAssertEqual(cache.statistics.retainedItems, 0)
        _ = try index([branch], cache: cache); XCTAssertEqual(cache.statistics.reused, 0)
    }
    func testCounterbalancedWidgetPreparationDiagnostic() throws {
        guard ProcessInfo.processInfo.environment["TASKFOLD_HIERARCHY_TIMING"] == "1" else { throw XCTSkip("Optional component timing") }
        var frame = snapshot((0..<100).map { root("profile-\($0)", children: 20) })
        WidgetCompletion.prepare(&frame)
        let context = scope(), control = WidgetCompletion.SignatureCache(maximumProjectionBytes: 0), candidate = WidgetCompletion.SignatureCache()
        var a = frame, b = frame; WidgetCompletion.prepare(&a, signatures: control, scope: context); WidgetCompletion.prepare(&b, signatures: candidate, scope: context)
        var samples: [[String: Any]] = []
        for pass in 0..<7 {
            let old = frame.tables["tasks"]![0]
            frame.apply(TaskCompletionRevision.capturing(Mutation(table: "tasks", recordID: old.id, method: "PATCH", fields: ["due_date": .string("2026-11-\(11 + pass)")]), existing: old))
            var times: [String: Double] = [:]; var results: [Bool: WidgetCompletionCache] = [:]
            for cached in (pass.isMultiple(of: 2) ? [false, true] : [true, false]) {
                var value = frame; let start = ProcessInfo.processInfo.systemUptime
                WidgetCompletion.prepare(&value, signatures: cached ? candidate : control, scope: context)
                times[cached ? "candidateSeconds" : "controlSeconds"] = ProcessInfo.processInfo.systemUptime - start; results[cached] = value.widgetCompletion
            }
            XCTAssertEqual(results[true], results[false]); XCTAssertEqual(results[true], frame.widgetCompletion)
            XCTAssertEqual(candidate.hierarchyStatistics.reused, 99); XCTAssertEqual(candidate.hierarchyStatistics.computed, 1)
            samples.append(["pass": pass, "times": times, "rootsReused": candidate.hierarchyStatistics.reused, "rootsComputed": candidate.hierarchyStatistics.computed, "chargedBytes": candidate.hierarchyStatistics.chargedBytes])
        }
        if let path = ProcessInfo.processInfo.environment["TASKFOLD_HIERARCHY_TIMING_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: ["componentOnly": true, "roots": 100, "children": 2000, "counterbalancedSameBuild": true, "samples": samples], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
