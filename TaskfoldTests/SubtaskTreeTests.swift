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

    func testChildDetailsPreserveContainmentAndUntouchedConcurrentFields() throws {
        var original = Record(node("b").object)
        original["user_id"] = .string("owner"); original["provider_id"] = .string("imported")
        var edited = SubtaskTree.detailDraft(original, project: "context")
        edited["title"] = .string("  New child title  "); edited["duration_minutes"] = .number(45)
        edited["user_id"] = .string("other"); edited["provider_id"] = .null
        edited["section_id"] = .string("elsewhere"); edited["reminder_specs"] = .array([.string("unsupported")])
        var current = original; current["description"] = .string("Remote notes")
        let saved = try SubtaskTree.detailChanges(original: original, edited: edited, current: current)
        XCTAssertEqual(saved.title, "New child title"); XCTAssertEqual(saved.durationMinutes,45)
        XCTAssertEqual(saved.string("description"), "Remote notes")
        for key in ["id","user_id","provider_id","project_id","section_id","reminder_specs","attachments","future_field"] { XCTAssertEqual(saved[key],current[key],key) }
    }
    func testChildDetailPlanningCanonicalizesInstantAndPreservesFoldOnNoteEdit() throws {
        var original = Record(node("b").object)
        original["due_date"] = .string("2026-10-25"); original["due_time"] = .string("02:30")
        original["time_zone"] = .string("Europe/Copenhagen"); original["scheduled_at"] = .string("2026-10-25T01:30:00Z")
        var edited = original; edited["description"] = .string("New notes")
        let notes = try SubtaskTree.detailChanges(original:original,edited:edited,current:original)
        XCTAssertEqual(notes["scheduled_at"],original["scheduled_at"])
        edited["due_date"] = .string("2026-10-26"); edited["deadline_date"] = .string("2026-10-30")
        edited["priority"] = .number(1)
        let planned = try SubtaskTree.detailChanges(original:original,edited:edited,current:original)
        XCTAssertEqual(planned.string("scheduled_at"),"2026-10-26T01:30:00Z")
        XCTAssertEqual(planned.string("deadline_date"),"2026-10-30"); XCTAssertEqual(planned.priority,1)
    }
    func testChildDetailsRejectInvalidIdentityAndPlanningWithoutChangingSource() {
        let original = Record(node("b").object)
        let invalid: [(String,JSON)] = [("id",.string("other")),("title",.string("  ")),("duration_minutes",.number(0)),("duration_minutes",.number(1.5)),("priority",.number(5)),("due_date",.string("bad")),("due_time",.string("25:90")),("time_zone",.string("Missing/Zone"))]
        for (key,value) in invalid {
            var edited=original; edited[key]=value
            XCTAssertThrowsError(try SubtaskTree.detailChanges(original:original,edited:edited,current:original),key)
        }
        XCTAssertEqual(original,Record(node("b").object))
    }
    func testChildPathFollowsWholeMovedBranch() throws {
        let source: JSON = .array([node("a"),node("b",[node("leaf")])])
        XCTAssertEqual(SubtaskTree.path(source,id:"leaf"),["b","leaf"])
        let moved=try SubtaskTree.moving(source,id:"b",direction:.indent)
        XCTAssertEqual(SubtaskTree.path(moved,id:"leaf"),["a","b","leaf"])
        XCTAssertNil(SubtaskTree.path(moved,id:"missing"))
    }
    func testStaleChildDraftProjectionKeepsRemoteFieldsAndOriginalQueuedIntent() throws {
        let base: JSON = .array([node("a",[node("b")])])
        let desired=SubtaskTree.changing(base,id:"b",fields:["description":.string("Local notes")])
        let remote=SubtaskTree.changing(base,id:"b",fields:["priority":.number(1),"attachments":.array([node("remote-file")])])
        var task=Record.task(user:"test"); task["subtasks"]=remote
        let change=Mutation(table:"tasks",recordID:task.id,method:"PATCH",fields:["subtasks":desired],baseline:["subtasks":base,"task_generation":task["task_generation"]])
        var snapshot=Snapshot(tables:["tasks":[task]],pending:[change]);snapshot.apply(change)
        let child=SubtaskTree.outline(snapshot.tables["tasks"]![0]["subtasks"]).last!.record
        XCTAssertEqual(child.string("description"),"Local notes");XCTAssertEqual(child.priority,1)
        XCTAssertEqual(child["attachments"],SubtaskTree.outline(remote).last!.record["attachments"])
        XCTAssertEqual(snapshot.pending,[change]);XCTAssertEqual(change.fields["subtasks"],desired)
        XCTAssertEqual(try JSONDecoder().decode(Snapshot.self,from:JSONEncoder().encode(snapshot)),snapshot)
    }
    func testDeepChildReferenceRetainsAncestryAcrossEverySupportedLevel() {
        var reference="root", path=["root"]
        for level in 1...SubtaskTree.readableDepth {
            path.append("child-\(level)")
            reference=SubtaskTree.reference(parent:reference,key:path.last!)
            XCTAssertEqual(SubtaskTree.referencePath(reference),path)
        }
        XCTAssertNil(SubtaskTree.referencePath(SubtaskTree.reference(parent:reference,key:"too-deep")))
        XCTAssertNil(SubtaskTree.referencePath("subtask:invalid"))
    }
}

final class TaskHierarchyIndexTests: XCTestCase {
    private let workspace = WorkspaceBinding(account: "viewer", generation: UUID())
    private var projects: [Record] { [Record(["id": .string("project"), "name": .string("Shared"), "user_id": .string("owner")])] }
    private func child(_ id: String, _ children: [JSON] = []) -> JSON {
        .object(["id": .string(id), "title": .string("Child " + id), "completed": .bool(false), "description": .string("Notes " + id), "subtasks": .array(children), "future_field": .object(["preserve": .bool(true)])])
    }
    private var root: Record {
        Record(["id": .string("root"), "title": .string("Parent"), "user_id": .string("owner"), "project_id": .string("project"), "section_id": .string("section"), "task_generation": .string("generation-one"), "created_at": .string("2026-10-21T08:00:00Z"), "completed": .bool(false), "priority": .number(1), "labels": .array([.string("root-label")]), "assigned_to": .string("owner"), "due_date": .string("2026-10-21"), "subtasks": .array([child("a", [child("leaf")]), child("b")])])
    }
    private func index(_ roots: [Record]? = nil, projects: [Record]? = nil) throws -> TaskHierarchyIndex {
        try TaskHierarchyIndex(roots: roots ?? [root], projects: projects ?? self.projects, workspace: workspace)
    }
    private func reference(_ path: String...) -> String { path.reduce("root") { SubtaskTree.reference(parent: $0, key: $1) } }
    private func selection(_ path: String...) throws -> TaskHierarchyIndex.Selection {
        try XCTUnwrap(index().selection(path.reduce("root") { SubtaskTree.reference(parent: $0, key: $1) }))
    }
    private func plan(_ edits: [TaskHierarchyIndex.Edit], roots: [Record]? = nil, projects: [Record]? = nil, workspace: WorkspaceBinding? = nil) throws -> [Mutation] {
        try TaskHierarchyIndex.changes(edits, accessibleRoots: roots ?? [root], projects: projects ?? self.projects, workspace: workspace ?? self.workspace)
    }
    private func applied(_ changes: [Mutation], to original: Record? = nil) -> Snapshot {
        var result = Snapshot(tables: ["tasks": [original ?? root]])
        for change in changes { result.apply(change) }
        return result
    }
    func testHierarchyProjectsFullPathAndOnlyInheritsContainmentWithoutMutatingSource() throws {
        let before = root, hierarchy = try index()
        XCTAssertEqual(hierarchy.items.map(\.id), ["root", reference("a"), reference("a", "leaf"), reference("b")])
        XCTAssertEqual(hierarchy.records(in: .roots).map(\.title), ["Parent"])
        XCTAssertEqual(hierarchy.records(in: .subtasks).map(\.title), ["Child a", "Child leaf", "Child b"])
        XCTAssertEqual(hierarchy.records(in: .parents).map(\.title), ["Parent", "Child a"])
        let leaf = try XCTUnwrap(hierarchy.item(reference("a", "leaf")))
        XCTAssertEqual(leaf.parentTitles, ["Parent", "Child a"])
        XCTAssertEqual(SubtaskTree.referencePath(leaf.id), ["root", "a", "leaf"])
        for field in ["project_id", "section_id", "user_id"] { XCTAssertEqual(leaf.record[field], root[field]) }
        for field in ["due_date", "assigned_to", "labels", "priority", "created_at"] { XCTAssertEqual(leaf.record[field], .null, field) }
        XCTAssertEqual(leaf.source["id"], .string("leaf")); XCTAssertEqual(leaf.source["project_id"], .null)
        XCTAssertEqual(root, before)
        XCTAssertNil(hierarchy.item("subtask:invalid"))
    }
    func testHierarchyCompletionBelongsToEachNodeWithoutCascading() throws {
        var changed = root; changed["completed"] = .bool(true)
        changed["subtasks"] = SubtaskTree.changing(root["subtasks"], id: "a", fields: ["completed": .bool(true)])
        let hierarchy = try index([changed])
        XCTAssertEqual(hierarchy.records(in: .all).map(\.title), ["Child leaf", "Child b"])
        XCTAssertEqual(hierarchy.records(in: .all, includeCompleted: true).count, 4)
        XCTAssertEqual(hierarchy.records(in: .parents).count, 0)
    }
    func testHierarchyStableReferencesSurviveSiblingReorderAndDistinctRoots() throws {
        var reordered = root; reordered["subtasks"] = .array(root["subtasks"].list.reversed())
        XCTAssertEqual(try index([reordered]).item(reference("a", "leaf"))?.source, try index().item(reference("a", "leaf"))?.source)
        var second = root; second["id"] = .string("second-root")
        let both = try index([root, second])
        XCTAssertEqual(both.items.count, 8); XCTAssertEqual(Set(both.items.map(\.id)).count, 8)
        XCTAssertNotNil(both.item(SubtaskTree.reference(parent: "second-root", key: "a")))
    }
    func testHierarchyExcludesArchivedMissingAmbiguousAndInheritedArchivedProjects() throws {
        var archived = projects[0]; archived["is_archived"] = .bool(true)
        for catalog in [[], [archived], projects + projects] {
            let hierarchy = try index(projects: catalog)
            XCTAssertTrue(hierarchy.items.isEmpty); XCTAssertEqual(hierarchy.excludedRootIDs, ["root"])
        }
        var shared = projects[0]; shared["parent_id"] = .string("not-shared")
        XCTAssertEqual(try index(projects: [shared]).items.count, 4)
        shared["ancestor_archived"] = .bool(true)
        XCTAssertTrue(try index(projects: [shared]).items.isEmpty)
        var inbox = root; inbox["project_id"] = .null
        XCTAssertEqual(try index([inbox], projects: []).items.count, 4)
    }
    func testHierarchyRejectsMalformedLegacyDuplicateAndTooDeepTreesWithoutPartialResults() throws {
        for children: JSON in [.string("new-format"), .array([.number(1)]), .array([.object(["title": .string("Legacy without ID")])]), .array([child("a"), child("a")]), .array([child("a", [child("a")])]), .array([.object(["id": .string("a"), "title": .number(1)])])] {
            var malformed = root; malformed["subtasks"] = children
            XCTAssertThrowsError(try index([malformed]))
        }
        XCTAssertThrowsError(try index([root, root]))
        XCTAssertThrowsError(try index(Array(repeating: root, count: TaskHierarchyIndex.maximumItems + 1)))
        var branch = child("leaf")
        for depth in (1...SubtaskTree.readableDepth).reversed() { branch = child("d\(depth)", [branch]) }
        var deep = root; deep["subtasks"] = .array([branch])
        XCTAssertThrowsError(try index([deep]))
        deep["subtasks"] = .array(branch.object["subtasks"]!.list)
        XCTAssertEqual(try index([deep]).items.count, SubtaskTree.readableDepth + 1)
        XCTAssertThrowsError(try TaskHierarchyIndex(roots: [root], projects: projects, workspace: WorkspaceBinding(account: "", generation: UUID())))
    }
    func testHierarchyEditsSiblingFieldsInOneRootPatchAndPreservesOpaqueData() throws {
        let changes = try plan([.patch(selection("a"), ["title": .string("New title")]), .patch(selection("b"), ["description": .string("New notes")])])
        XCTAssertEqual(changes.count, 1); XCTAssertEqual(changes[0].recordID, "root"); XCTAssertEqual(changes[0].method, "PATCH")
        XCTAssertEqual(Set(changes[0].fields.keys), ["subtasks"])
        XCTAssertEqual(changes[0].baseline?["subtasks"], root["subtasks"])
        XCTAssertEqual(changes[0].baseline?["task_generation"], root["task_generation"])
        let result = try index(applied(changes).tables["tasks"])
        XCTAssertEqual(result.item(reference("a"))?.source.title, "New title")
        XCTAssertEqual(result.item(reference("b"))?.source.string("description"), "New notes")
        XCTAssertEqual(result.item(reference("a", "leaf"))?.source, try index().item(reference("a", "leaf"))?.source)
        XCTAssertEqual(result.item(reference("a"))?.source["future_field"], child("a").object["future_field"])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(changes), as: UTF8.self).contains("subtask:"), "Synthetic IDs must never be queued as task rows")
    }
    func testHierarchyParentAndChildDisjointEditsComposeInEitherOrder() throws {
        let parent = TaskHierarchyIndex.Edit.patch(try selection("a"), ["title": .string("Changed parent")])
        let leaf = TaskHierarchyIndex.Edit.patch(try selection("a", "leaf"), ["description": .string("Changed leaf")])
        for edits in [[parent, leaf], [leaf, parent]] {
            let result = try index(applied(plan(edits)).tables["tasks"])
            XCTAssertEqual(result.item(reference("a"))?.source.title, "Changed parent")
            XCTAssertEqual(result.item(reference("a", "leaf"))?.source.string("description"), "Changed leaf")
        }
    }
    func testHierarchyAllowsUnrelatedConcurrentEditsAndRefusesConflictingFieldOrDeletion() throws {
        let selected = try selection("a", "leaf")
        var concurrent = root
        concurrent["subtasks"] = SubtaskTree.changing(root["subtasks"], id: "leaf", fields: ["description": .string("Other client's notes")])
        let edits = try plan([.patch(selected, ["title": .string("My title")])], roots: [concurrent])
        let result = try index(applied(edits, to: concurrent).tables["tasks"])
        XCTAssertEqual(result.item(selected.item.id)?.source.title, "My title")
        XCTAssertEqual(result.item(selected.item.id)?.source.string("description"), "Other client's notes")
        XCTAssertThrowsError(try plan([.patch(selected, ["description": .string("Overwrite")])], roots: [concurrent]))
        XCTAssertThrowsError(try plan([.delete(selected)], roots: [concurrent]))
        XCTAssertTrue(try plan([.patch(selected, ["description": .string("Other client's notes")])], roots: [concurrent]).isEmpty)
    }
    func testHierarchyRefusesWorkspaceIncarnationReplacementMoveAndLostAccess() throws {
        let edit = TaskHierarchyIndex.Edit.completion(try selection("a"), completed: true)
        for field in ["task_generation", "created_at", "project_id", "section_id"] {
            var changed = root; changed[field] = .string("replaced")
            XCTAssertThrowsError(try plan([edit], roots: [changed]), field)
        }
        for binding in [WorkspaceBinding(account: "other", generation: workspace.generation), WorkspaceBinding(account: workspace.account, generation: UUID())] {
            XCTAssertThrowsError(try plan([edit], workspace: binding))
        }
        XCTAssertThrowsError(try plan([edit], roots: [])); XCTAssertThrowsError(try plan([edit], projects: []))
        var moved = root; moved["subtasks"] = try SubtaskTree.moving(root["subtasks"], id: "leaf", direction: .outdent)
        XCTAssertThrowsError(try plan([.patch(selection("a", "leaf"), ["title": .string("Old path")])], roots: [moved]))
        var removed = root; removed["subtasks"] = SubtaskTree.removing(root["subtasks"], id: "a")
        XCTAssertThrowsError(try plan([edit], roots: [removed]))
    }
    func testHierarchyRejectsContainmentInvalidFieldsDuplicateAndOverlappingBranchRequests() throws {
        let selected = try selection("a"), leaf = try selection("a", "leaf")
        for fields: [String: JSON] in [["project_id": .null], ["section_id": .null], ["user_id": .string("other")], ["task_generation": .string("new")], ["title": .string(" ")], ["duration_minutes": .number(0)], ["completed": .string("true")], ["completed": .bool(true), "completed_at": .null]] {
            XCTAssertThrowsError(try plan([.patch(selected, fields)]))
        }
        XCTAssertThrowsError(try plan([.delete(selected), .delete(leaf)]))
        XCTAssertThrowsError(try plan([.patch(selected, ["subtasks": .array([])]), .patch(leaf, ["title": .string("Lost")])]))
        XCTAssertThrowsError(try plan([.patch(selected, [:]), .patch(selected, [:])]))
        XCTAssertThrowsError(try plan([.patch(selected, ["subtasks": .array([child("b")])])]), "A new descendant cannot reuse an existing sibling identity")
        let rootSelection = try XCTUnwrap(index().selection("root"))
        XCTAssertThrowsError(try plan([.delete(rootSelection)]))
    }
    func testHierarchyCompleteDeleteUndoRedoAndOfflineCodecKeepRealRootIdentity() throws {
        let complete = try plan([.completion(selection("a", "leaf"), completed: true, at: Date(timeIntervalSince1970: 1_790_000_000))])
        let before = Snapshot(tables: ["tasks": [root]])
        let history = EditHistory(changes: complete, snapshot: before)
        var saved = before
        for change in complete { saved.apply(change); saved.pending.append(change) }
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(saved, decoded)
        XCTAssertEqual(try index(saved.tables["tasks"]).item(reference("a", "leaf"))?.source.completed, true)
        XCTAssertEqual(saved.tables["tasks"]?.first?["completed"], .bool(false))
        XCTAssertEqual(saved.tables["tasks"]?.count, 1)
        for change in history.undo { saved.apply(change) }
        XCTAssertEqual(saved.tables["tasks"], before.tables["tasks"])
        for change in history.redo { saved.apply(change) }
        XCTAssertEqual(try index(saved.tables["tasks"]).item(reference("a", "leaf"))?.source.completed, true)
        let deletion = try plan([.delete(selection("a"))])
        let deleted = try index(applied(deletion).tables["tasks"])
        XCTAssertEqual(deleted.records(in: .all).map(\.title), ["Parent", "Child b"])
        XCTAssertTrue(try plan([.patch(selection("a"), [:])]).isEmpty)
    }
    func testHierarchyChecksBatchLimitBeforePlanningAnyMutation() throws {
        let edit = TaskHierarchyIndex.Edit.delete(try selection("a"))
        XCTAssertThrowsError(try plan(Array(repeating: edit, count: TaskHierarchyIndex.maximumEdits + 1)))
        XCTAssertTrue(try plan([]).isEmpty)
    }
}


extension TaskHierarchyIndexTests {
    func testHierarchyCompletionRetryAndReopenDoNotCreateRowsOrChangeParentCompletion() throws {
        let selected = try selection("a", "leaf")
        let edit = TaskHierarchyIndex.Edit.completion(selected, completed: true, at: Date(timeIntervalSince1970: 1_790_000_000))
        let completed = applied(try plan([edit])).tables["tasks"]!
        XCTAssertTrue(try plan([edit], roots: completed).isEmpty)
        let fresh = try XCTUnwrap(index(completed).selection(selected.item.id))
        let reopened = applied(try plan([.completion(fresh, completed: false)], roots: completed), to: completed[0]).tables["tasks"]!
        XCTAssertEqual(reopened.count, 1)
        XCTAssertEqual(reopened[0]["completed"], .bool(false))
        let leaf = try XCTUnwrap(index(reopened).item(selected.item.id))
        XCTAssertFalse(leaf.source.completed); XCTAssertEqual(leaf.source["completed_at"], .null)
    }
    func testHierarchyBoundsEncodedReferenceMemoryAndRejectsOversizedIdentities() throws {
        var invalid = root; invalid["subtasks"] = .array([child(String(repeating: "a", count: 401))])
        XCTAssertThrowsError(try index([invalid]))
        let leaves = (0..<2_100).map { child("leaf-\($0)-" + String(repeating: "x", count: 380)) }
        var children = leaves
        for depth in (1...31).reversed() { children = [child("level-\(depth)-" + String(repeating: "y", count: 380), children)] }
        var large = root; large["subtasks"] = .array(children)
        XCTAssertThrowsError(try index([large]), "Refuse the complete projection rather than returning a partial hierarchy")
    }
}

extension TaskHierarchyIndexTests {
    func testHierarchyNativeDraftChangesOnlyAuthoredFieldsAndPreservesRawContainment() throws {
        let selected = try selection("a", "leaf")
        XCTAssertEqual(selected.item.record["task_generation"], root["task_generation"])
        XCTAssertEqual(selected.item.source["task_generation"], .null)
        var draft = selected.item.record; draft["title"] = .string("Edited through native details")
        let changes = try plan([.editing(selected, draft: draft)])
        let result = try index(applied(changes).tables["tasks"])
        let child = try XCTUnwrap(result.item(selected.item.id))
        XCTAssertEqual(child.source.title, "Edited through native details")
        for field in ["project_id", "section_id", "user_id", "task_generation"] { XCTAssertEqual(child.source[field], selected.item.source[field]) }
        XCTAssertTrue(try plan([.editing(selected, draft: selected.item.record)]).isEmpty)
    }
    func testHierarchyNativeDraftRejectsIdentityContainmentAndOpaqueFieldChanges() throws {
        let selected = try selection("a")
        for field in ["id", "project_id", "section_id", "user_id", "task_generation", "future_field"] {
            var draft = selected.item.record; draft[field] = .string("Changed")
            XCTAssertThrowsError(try TaskHierarchyIndex.Edit.editing(selected, draft: draft), field)
        }
    }
    func testHierarchyNativeCompletionDraftAddsOwnTimestampWithoutRootCompletion() throws {
        let selected = try selection("a")
        var draft = selected.item.record; draft["completed"] = .bool(true)
        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        let changes = try plan([.editing(selected, draft: draft, at: stamp)])
        let result = try index(applied(changes).tables["tasks"])
        XCTAssertEqual(result.item(selected.item.id)?.source["completed_at"], .string(ISO8601DateFormatter().string(from: stamp)))
        XCTAssertEqual(result.item("root")?.source.completed, false)
        XCTAssertEqual(result.item(reference("a", "leaf"))?.source.completed, false)
    }
    func testHierarchyProjectedIncarnationChangesWhenRootIsRecreated() throws {
        let old = try index().item(reference("a"))!.record
        var replaced = root; replaced["task_generation"] = .string("next-generation")
        let new = try index([replaced]).item(reference("a"))!.record
        XCTAssertEqual(old.id, new.id); XCTAssertNotEqual(old, new)
        XCTAssertEqual(new["task_generation"], .string("next-generation"))
    }
}
