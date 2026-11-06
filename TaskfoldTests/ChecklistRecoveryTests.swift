import XCTest
@testable import TaskfoldCore

final class ChecklistRecoveryTests: XCTestCase {
    private func node(_ id: JSON? = nil, title: String = "Review layout", children: [JSON]? = nil) -> JSON {
        var fields: [String: JSON] = ["title": .string(title), "completed": .bool(true), "description": .string("Keep **every** note.\n東京 🙂"),
            "labels": .array([.string("label")]), "assigned_to": .string("member"), "due_date": .string("2027-01-04"),
            "comments": .array([.object(["body": .string("Keep discussion"), "future": .number(3)])]), "attachments": .array([.object(["name": .string("brief.pdf"), "url": .string("https://example.invalid/brief")])]), "future": .object(["keep": .bool(true)])]
        if let id { fields["id"] = id }; if let children { fields["subtasks"] = .array(children) }
        return .object(fields)
    }
    private func withoutIDs(_ value: JSON) -> JSON {
        guard case .array(let rows) = value else { return value }
        return .array(rows.map { row in
            var fields = row.object; fields.removeValue(forKey: "id")
            if let children = fields["subtasks"], case .array = children { fields["subtasks"] = withoutIDs(children) }
            return .object(fields)
        })
    }
    func testDuplicateReferencesAreAllReplacedIncludingNestedFirstOccurrence() throws {
        let source: JSON = .array([node(.string("duplicate"), children: [node(.string("keep")), node(.string("duplicate"))]), node(.string("duplicate")), node(.string("stable"))])
        let review = try ChecklistRecovery.review(source)
        XCTAssertEqual(review.changes.map(\.reason), [.duplicate,.duplicate,.duplicate])
        XCTAssertEqual(review.changes.map(\.path), [[0],[0,1],[1]])
        let rows = SubtaskTree.outline(review.proposed), ids = rows.map(\.id)
        XCTAssertEqual(Set(ids).count, 5); XCTAssertFalse(ids.contains("duplicate")); XCTAssertTrue(ids.contains("keep")); XCTAssertTrue(ids.contains("stable"))
        XCTAssertEqual(withoutIDs(review.proposed), withoutIDs(source), "Every non-identity field, branch, sibling and completion must survive")
        XCTAssertEqual(try review.applying(to: source), review.proposed)
    }
    func testMissingMalformedEmptyControlAndOversizedReferencesAreReviewed() throws {
        let identities: [JSON?] = [nil,.null,.string(""),.number(42),.bool(false),.array([]),.string("   "),.string("bad\nreference"),.string(String(repeating:"x",count:401))]
        let review = try ChecklistRecovery.review(.array(identities.map { node($0) }))
        XCTAssertEqual(review.changes.count, identities.count)
        XCTAssertEqual(Array(review.changes.prefix(3)).map(\.reason), [.missing,.missing,.missing])
        XCTAssertTrue(review.changes.dropFirst(3).allSatisfy { $0.reason == .invalid })
        XCTAssertTrue(SubtaskTree.outline(review.proposed).allSatisfy { UUID(uuidString: $0.id) != nil })
    }
    func testUniqueLegacyReferencesAndOpaqueFieldsRemainExactlyUnchanged() throws {
        let source: JSON = .array([node(.string("legacy-id"), children: [node(.string(String(repeating:"東",count:400)))]), node(.string("  readable  "))])
        let review = try ChecklistRecovery.review(source)
        XCTAssertTrue(review.changes.isEmpty); XCTAssertEqual(review.proposed, source)
        XCTAssertEqual(try ChecklistRecovery.review(review.proposed).proposed, source)
    }
    func testTextOnlyLegacyItemsBecomeOpenNamedSubtasksOnlyAfterApply() throws {
        let source: JSON = .array([.string("First line\nKeep the second line"), node(.string("stable"), children: [.string("Nested 🙂")])])
        let review = try ChecklistRecovery.review(source)
        XCTAssertEqual(review.changes.map(\.reason), [.textOnly,.textOnly]); XCTAssertEqual(review.itemCount, 3)
        XCTAssertEqual(review.proposed.list[0].object["title"], source.list[0]); XCTAssertEqual(review.proposed.list[0].object["completed"], .bool(false))
        XCTAssertEqual(source.list[0], .string("First line\nKeep the second line"))
        let data = try ChecklistRecovery.originalData(source)
        XCTAssertEqual(try JSONDecoder().decode(JSON.self, from: data), source)
    }
    func testUnrecognizedNodesRefuseWholeReviewWithoutPartialSalvage() throws {
        for unsupported: JSON in [.number(4),.null,.bool(true),.array([]),.object(["title":.number(7)]),.object(["title":.string("Keep"),"subtasks":.string("not a list")])] {
            let source: JSON = .array([node(nil),unsupported])
            XCTAssertThrowsError(try ChecklistRecovery.review(source))
            XCTAssertEqual(try JSONDecoder().decode(JSON.self, from: ChecklistRecovery.originalData(source)), source)
        }
        XCTAssertThrowsError(try ChecklistRecovery.review(.object(["future_checklist":.array([])])))
    }
    func testCancelledOrChangedSourceCannotApplyAnOlderReview() throws {
        let source: JSON = .array([node(.string("duplicate")),node(.string("duplicate"))])
        let review = try ChecklistRecovery.review(source)
        var edited = source.list; var row = edited[1].object; row["description"] = .string("Changed elsewhere"); edited[1] = .object(row)
        XCTAssertThrowsError(try review.applying(to: .array(edited)))
        XCTAssertThrowsError(try review.applying(to: .array(Array(source.list.reversed()) + [node(.string("new"))])))
        XCTAssertEqual(source.list[0].object["id"], .string("duplicate"), "Review/Cancel has no source mutation")
    }
    func testGeneratedReferencesCannotCollideWithAnySavedReference() throws {
        let reserved = "81000000-0000-4000-8000-000000000001", fresh = "81000000-0000-4000-8000-000000000002"
        var calls = 0
        let review = try ChecklistRecovery.review(.array([node(nil),node(.string(reserved))]), makeID: { calls += 1; return calls == 1 ? reserved : fresh })
        XCTAssertEqual(review.proposed.list[0].object["id"], .string(fresh)); XCTAssertEqual(calls, 2)
        XCTAssertThrowsError(try ChecklistRecovery.review(.array([node(nil)]), makeID: { "invalid" }))
        XCTAssertThrowsError(try ChecklistRecovery.review(.array([node(nil),node(.string(reserved))]), makeID: { reserved }))
    }
    func testNestingAndOpaquePayloadBoundsRejectWithoutTruncation() throws {
        var branch = node(.string("leaf"))
        for index in 0..<31 { branch = node(.string("n\(index)"), children:[branch]) }
        XCTAssertNoThrow(try ChecklistRecovery.review(.array([branch])))
        XCTAssertThrowsError(try ChecklistRecovery.review(.array([branch]), baseDepth: 1))
        XCTAssertThrowsError(try ChecklistRecovery.review(.array([node(.string("one-more"),children:[branch])])))
        XCTAssertThrowsError(try ChecklistRecovery.review(.array([]), baseDepth: -1))
        var large = node(nil).object; large["future"] = .string(String(repeating:"x",count:ChecklistRecovery.maximumBytes+1))
        XCTAssertThrowsError(try ChecklistRecovery.review(.array([.object(large)])))
        XCTAssertThrowsError(try ChecklistRecovery.originalData(.number(.infinity)))
        XCTAssertThrowsError(try ChecklistRecovery.review(.array((0...ChecklistRecovery.maximumItems).map { .string("item \($0)") })))
    }
    func testRecoveredTreeSupportsHierarchyQueriesAndRejectsOldAmbiguousRoutes() throws {
        let source: JSON = .array([node(.string("duplicate")),node(.string("duplicate"))])
        var root = Record.task(user:"local"); root["title"] = .string("Checklist recovery"); root["subtasks"] = source
        let workspace = WorkspaceBinding(account:"local",generation:UUID())
        XCTAssertThrowsError(try TaskHierarchyIndex(roots:[root],projects:[],workspace:workspace))
        let review = try ChecklistRecovery.review(source); root["subtasks"] = try review.applying(to: source)
        let index = try TaskHierarchyIndex(roots:[root],projects:[],workspace:workspace)
        XCTAssertEqual(index.records(in:.subtasks,includeCompleted:true).count,2)
        XCTAssertNil(index.item(SubtaskTree.reference(parent:root.id,key:"duplicate")))
        XCTAssertEqual(index.records(in:.subtasks,includeCompleted:true).map(\.title),["Review layout","Review layout"])
    }
    func testSnapshotMutationUndoAndSerializationPreserveOriginalDamagedContent() throws {
        let source: JSON = .array([node(.number(42)),node(.string("duplicate")),node(.string("duplicate"))])
        var root = Record.task(user:"local"); root["subtasks"] = source
        let recovered = try ChecklistRecovery.review(source).proposed
        var cache = Snapshot(tables:["tasks":[root]])
        cache.apply(Mutation(table:"tasks",recordID:root.id,method:"PATCH",fields:["subtasks":recovered]))
        let read = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(cache))
        XCTAssertEqual(read.tables["tasks"]?.first?["subtasks"],recovered)
        cache.apply(Mutation(table:"tasks",recordID:root.id,method:"PATCH",fields:["subtasks":source]))
        XCTAssertEqual(cache.tables["tasks"]?.first?["subtasks"],source)
        XCTAssertEqual(try JSONDecoder().decode(JSON.self,from:ChecklistRecovery.originalData(source)),source)
    }
    func testUnknownContainersAndTextNodesCannotBeOverwrittenByInlineEditing() throws {
        let original: JSON = .object(["future_list": .array([.string("Keep every word")])])
        XCTAssertFalse(SubtaskTree.hasListContainer(original))
        XCTAssertThrowsError(try SubtaskTree.adding(original, title: "New item"))
        XCTAssertFalse(SubtaskTree.inlineEditable(.string("Keep a legacy title")))
        XCTAssertEqual(SubtaskTree.inlineTitle(.string("Keep a legacy title")), "Keep a legacy title")
        XCTAssertFalse(SubtaskTree.inlineEditable(.object(["title": .number(7)])))
        XCTAssertTrue(SubtaskTree.inlineEditable(node(.number(7))), "Position-bound root fields preserve an opaque ID instead of coercing it")
        XCTAssertEqual(original, .object(["future_list": .array([.string("Keep every word")])]))
    }
    func testMacPathPrimitivesRejectDuplicateAndPositionalCollisions() throws {
        let duplicates: JSON = .array([node(.string("same")),node(.string("same"))])
        XCTAssertNil(SubtaskTree.uniqueChildIndex(duplicates,key:"same"))
        let positional: JSON = .array([node(nil),node(.string("stable"))])
        XCTAssertEqual(SubtaskTree.uniqueChildIndex(positional,key:"@0"),0)
        XCTAssertEqual(SubtaskTree.uniqueChildIndex(positional,key:"stable"),1)
        XCTAssertNil(SubtaskTree.uniqueChildIndex(.array([node(nil),node(.string("@0"))]),key:"@0"))
        XCTAssertNil(SubtaskTree.uniqueChildIndex(.array([.string("Legacy text")]),key:"@0"))
        XCTAssertNil(SubtaskTree.uniqueChildIndex(.object([:]),key:"@0"))
        for value: JSON in [duplicates, positional, .array([node(nil),node(.string("@0"))]), .array([.string("Legacy text")]), .object([:])] {
            let index = SubtaskTree.uniqueChildIndices(value)
            for key in ["same", "@0", "@1", "stable", "missing"] { XCTAssertEqual(index[key], SubtaskTree.uniqueChildIndex(value,key:key)) }
        }

    }
    func testCancelledBackgroundReviewReturnsNoProposal() async throws {
        let source: JSON = .array([node(nil),node(nil)])
        let work = Task.detached { () throws -> ChecklistRecovery.Review in
            withUnsafeCurrentTask { $0?.cancel() }
            return try ChecklistRecovery.review(source)
        }
        do { _ = try await work.value; XCTFail("Cancelled review must stop without a partial proposal") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(source.list[0].object["id"])
    }

    func testExpandedLegacyResultMustFitTheNextOpeningBounds() throws {
        let source: JSON = .array((0..<ChecklistRecovery.maximumItems).map { _ in .string(String(repeating: "x", count: 130)) })
        XCTAssertNoThrow(try ChecklistRecovery.originalData(source))
        XCTAssertThrowsError(try ChecklistRecovery.review(source), "Converting text entries must not create a result that the organizer cannot reopen")
    }

}
