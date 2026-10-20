import XCTest
@testable import TaskfoldCore

final class SubtaskTreeTests: XCTestCase {
    private func node(_ id: String, _ children: [JSON] = []) -> JSON {
        .object(["id": .string(id), "title": .string(id), "completed": .bool(false), "subtasks": .array(children),
                 "description": .string("Keep notes"), "due_date": .string("2027-01-04"),
                 "attachments": .array([.object(["id": .string("file-" + id), "name": .string("Brief.pdf")])]),
                 "future_field": .object(["keep": .bool(true)])])
    }
    func testPrepareAddsOnlyMissingIDsAndPreservesOpaqueMetadata() throws {
        var legacy = node("a", [node("b")]).object; legacy.removeValue(forKey: "id")
        let source: JSON = .array([.object(legacy)])
        let prepared = try SubtaskTree.prepared(source)
        XCTAssertFalse(prepared.list[0].object["id"]!.text.isEmpty)
        var withoutID = prepared.list[0].object; withoutID.removeValue(forKey: "id")
        XCTAssertEqual(withoutID, legacy)
        XCTAssertNil(source.list[0].object["id"], "Opening a draft must not mutate its source")
        XCTAssertEqual(try SubtaskTree.prepared(prepared), prepared)
    }
    func testUnsupportedOrDuplicateChildrenFailBeforeAnyWrite() {
        for source: JSON in [.string("future format"), .array([node("same"),node("same")]), .array([.number(4)]),
                             .array([.object(["id": .number(8), "title": .string("Malformed")])]),
                             .array([.object(["id": .string("a"), "title": .string("a"), "subtasks": .object([:])])])] {
            XCTAssertThrowsError(try SubtaskTree.prepared(source))
        }
    }
    func testEditAndCompleteNestedChildPreservesEveryOtherFieldAndSibling() {
        let original: JSON = .array([node("a", [node("b")]), node("c")])
        let updated = SubtaskTree.changing(original, id: "b", fields: ["title": .string("Edited"), "completed": .bool(true)])
        var expected = node("b").object; expected["title"] = .string("Edited"); expected["completed"] = .bool(true)
        XCTAssertEqual(updated.list[0].object["subtasks"]?.list[0], .object(expected))
        XCTAssertEqual(updated.list[1], original.list[1]); XCTAssertEqual(original.list[0].object["subtasks"]?.list[0], node("b"))
    }
    func testIndentAndOutdentMoveWholeBranchWithExactRoundTrip() throws {
        let original: JSON = .array([node("a"), node("b", [node("leaf")]), node("c")])
        let nested = try SubtaskTree.moving(original, id: "b", direction: .indent)
        XCTAssertEqual(SubtaskTree.outline(nested).map(\.id), ["a","b","leaf","c"])
        XCTAssertEqual(SubtaskTree.outline(nested).map(\.depth), [0,1,2,0])
        XCTAssertEqual(try SubtaskTree.moving(nested, id: "b", direction: .outdent), original)
        XCTAssertEqual(nested.list[0].object["subtasks"]?.list[0], node("b", [node("leaf")]))
    }
    func testSiblingMoveKeepsChildrenAndOutdentInsertsAfterParent() throws {
        let original: JSON = .array([node("a", [node("b", [node("leaf")]), node("c")]),node("d")])
        let down = try SubtaskTree.moving(original, id: "b", direction: .down)
        XCTAssertEqual(SubtaskTree.outline(down).map(\.id), ["a","c","b","leaf","d"])
        XCTAssertEqual(try SubtaskTree.moving(down, id: "b", direction: .up), original)
        let out = try SubtaskTree.moving(original, id: "b", direction: .outdent)
        XCTAssertEqual(SubtaskTree.outline(out).map(\.id), ["a","c","b","leaf","d"])
        XCTAssertEqual(SubtaskTree.outline(out).map(\.depth), [0,1,0,1,0])
    }
    func testInvalidMovesDoNotRemoveOrReparentWork() {
        let original: JSON = .array([node("a"),node("b")])
        XCTAssertThrowsError(try SubtaskTree.moving(original,id:"a",direction:.up))
        XCTAssertThrowsError(try SubtaskTree.moving(original,id:"b",direction:.down))
        XCTAssertThrowsError(try SubtaskTree.moving(original,id:"a",direction:.indent))
        XCTAssertThrowsError(try SubtaskTree.moving(original,id:"a",direction:.outdent))
        XCTAssertThrowsError(try SubtaskTree.moving(original,id:"missing",direction:.indent))
        XCTAssertEqual(original, .array([node("a"),node("b")]))
    }
    func testDepthLimitIncludesWholeMovedBranchAndInspectorBaseDepth() throws {
        var branch = node("leaf")
        for level in (0..<8).reversed() { branch = node("n\(level)",[branch]) }
        let original: JSON = .array([node("a"),branch])
        let tenLevels = try SubtaskTree.moving(original,id:"n0",direction:.indent)
        XCTAssertEqual(SubtaskTree.outline(tenLevels).map(\.depth).max(),9)
        XCTAssertThrowsError(try SubtaskTree.adding(tenLevels,title:"Too deep",parent:"leaf"))
        XCTAssertThrowsError(try SubtaskTree.moving(original,id:"n0",direction:.indent,baseDepth:1))
        XCTAssertThrowsError(try SubtaskTree.adding(.array([]),title:"Too deep",baseDepth:10))
    }
    func testAddAndRemoveTouchOnlyChosenBranchAndKeepStableIDsAfterPersistence() throws {
        let original: JSON = .array([node("a"),node("b")])
        let added = try SubtaskTree.adding(original,title:"  New child  ",parent:"a")
        let child = try XCTUnwrap(SubtaskTree.outline(added).first { $0.record.title == "New child" })
        XCTAssertEqual(child.parent,"a");XCTAssertNotNil(UUID(uuidString:child.id))
        XCTAssertEqual(SubtaskTree.removing(added,id:child.id),original)
        let decoded = try JSONDecoder().decode(JSON.self,from:JSONEncoder().encode(added))
        XCTAssertEqual(decoded,added)
        XCTAssertEqual(SubtaskTree.removing(decoded,id:"a"),.array([node("b")]))
        XCTAssertThrowsError(try SubtaskTree.adding(original,title:" "))
        XCTAssertThrowsError(try SubtaskTree.adding(original,title:"Missing parent",parent:"gone"))
    }
    func testReviewedReorderRetainsOrderAndRemoteOnlyRows() throws {
        let base: JSON = .array([node("a"),node("b")])
        let local = try SubtaskTree.moving(base,id:"b",direction:.up)
        let remote: JSON = .array([node("a"),node("b"),node("remote")])
        let merged = TaskEdit.keepingLocal(field:"subtasks",base:base,desired:local,remote:remote)
        XCTAssertEqual(merged,.array([node("b"),node("a"),node("remote")]))
    }
    func testReviewedIndentRetainsRemoteEditsToMovedChildAndNewDescendant() throws {
        let base: JSON = .array([node("a"),node("b")])
        let local = try SubtaskTree.moving(base,id:"b",direction:.indent)
        let remote = SubtaskTree.changing(base,id:"b",fields:["description":.string("New remote notes"),"subtasks":.array([node("remote child")])])
        let merged = TaskEdit.keepingLocal(field:"subtasks",base:base,desired:local,remote:remote)
        let items = SubtaskTree.outline(merged)
        XCTAssertEqual(items.map(\.id),["a","b","remote child"])
        XCTAssertEqual(items.map(\.depth),[0,1,2])
        XCTAssertEqual(items[1].record.string("description"),"New remote notes")
        XCTAssertEqual(Set(items.map(\.id)).count,3)
    }
    func testLocalRenameAfterRemoteReparentDoesNotResurrectOldLocation() throws {
        let base: JSON = .array([node("a",[node("b")]),node("c")])
        let local = SubtaskTree.changing(base,id:"b",fields:["title":.string("Renamed")])
        let moved = try SubtaskTree.moving(base,id:"b",direction:.outdent)
        let remote = try SubtaskTree.moving(try SubtaskTree.moving(moved,id:"c",direction:.up),id:"b",direction:.indent)
        let merged = TaskEdit.keepingLocal(field:"subtasks",base:base,desired:local,remote:remote)
        let items = SubtaskTree.outline(merged)
        XCTAssertEqual(items.map(\.id),["a","c","b"])
        XCTAssertEqual(items.last?.parent,"c");XCTAssertEqual(items.last?.record.title,"Renamed")
        XCTAssertEqual(items.filter{$0.id=="b"}.count,1)
    }
    func testReviewedDeletionKeepsUnknownRemoteDescendantAndRemoteDeletionStaysDeleted() {
        let base: JSON = .array([node("a",[node("b")]),node("c")])
        let local = SubtaskTree.removing(base,id:"a")
        let remote: JSON = .array([node("a",[node("b"),node("new")]),node("c")])
        let merged = TaskEdit.keepingLocal(field:"subtasks",base:base,desired:local,remote:remote)
        XCTAssertEqual(SubtaskTree.outline(merged).map(\.id),["new","c"])
        let renamed = SubtaskTree.changing(base,id:"c",fields:["title":.string("Changed")])
        let deleted = SubtaskTree.removing(base,id:"b")
        let result = TaskEdit.keepingLocal(field:"subtasks",base:base,desired:renamed,remote:deleted)
        XCTAssertFalse(SubtaskTree.outline(result).contains{$0.id=="b"})
    }
    func testProgressCountsEveryLevelWithoutCompletingUnfinishedDescendants() {
        let tree: JSON = .array([node("a",[node("b",[node("leaf")])]),node("c")])
        let completed = SubtaskTree.changing(tree,id:"b",fields:["completed":.bool(true)])
        XCTAssertEqual(SubtaskTree.progress(completed).completed,1)
        XCTAssertEqual(SubtaskTree.progress(completed).total,4)
        XCTAssertEqual(SubtaskTree.progress(.null).total,0)
        XCTAssertFalse(SubtaskTree.outline(completed).first{$0.id=="leaf"}!.record.completed)
    }
}
