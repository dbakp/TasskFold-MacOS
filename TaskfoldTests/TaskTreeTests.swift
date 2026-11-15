import XCTest
@testable import TaskfoldCore

final class TaskTreeTests: XCTestCase {
    func row(_ id: String, parent: String? = nil, order: Double? = nil, project: String? = "p", section: String? = nil, user: String = "u",
             completed: Bool = false, title: String? = nil, created: String = "2026-01-01T00:00:00Z", extra: [String: JSON] = [:]) -> Record {
        var fields: [String: JSON] = ["id": .string(id), "user_id": .string(user), "title": .string(title ?? id), "completed": .bool(completed),
                                      "created_at": .string(created), "task_generation": .string("gen-" + id), "completion_version": .number(0)]
        fields["project_id"] = project.map(JSON.string) ?? .null
        fields["section_id"] = section.map(JSON.string) ?? .null
        fields["parent_id"] = parent.map(JSON.string) ?? .null
        fields["child_order"] = order.map(JSON.number) ?? .null
        for (k, v) in extra { fields[k] = v }
        return Record(fields)
    }
    func patch(_ id: String, _ fields: [String: JSON]) -> Mutation { Mutation(table: "tasks", recordID: id, method: "PATCH", fields: fields) }
    func edits(_ list: [TaskTree.Edit], _ tasks: [Record]) -> [Record] { TaskTree.apply(TaskTree.mutations(list, tasks: tasks), to: tasks) }
    /// A missing field and a null field are the same stored value.
    func normalized(_ rows: [Record]) -> [[String: JSON]] { rows.sorted { $0.id < $1.id }.map { $0.fields.filter { $0.value != .null } } }
    func chain(_ count: Int) -> [Record] { (0..<count).map { row("c\($0)", parent: $0 == 0 ? nil : "c\($0 - 1)", order: $0 == 0 ? nil : 1) } }
    var sample: [Record] {
        [row("root"), row("b", parent: "root", order: 2), row("a", parent: "root", order: 1), row("a1", parent: "a", order: 1), row("a2", parent: "a", order: 2), row("other")]
    }

    // MARK: index
    func testChildrenSortByOrderThenCreatedThenID() {
        let tasks = [row("p"), row("z", parent: "p", order: 1, created: "2026-01-02T00:00:00Z"), row("y", parent: "p", order: 1, created: "2026-01-01T00:00:00Z"),
                     row("x", parent: "p", order: 1, created: "2026-01-01T00:00:00Z"), row("w", parent: "p", order: 0.5), row("n", parent: "p")]
        XCTAssertEqual(TaskTree(tasks).children(of: "p").map(\.id), ["w", "x", "y", "z", "n"])
    }
    func testParentDepthDescendantsBreadcrumb() {
        let tree = TaskTree(sample)
        XCTAssertEqual(tree.parentID(of: "a1"), "a"); XCTAssertNil(tree.parentID(of: "root"))
        XCTAssertEqual(tree.depth(of: "a2"), 2); XCTAssertEqual(tree.depth(of: "root"), 0)
        XCTAssertEqual(tree.descendants(of: "root").map(\.id), ["a", "a1", "a2", "b"])
        XCTAssertEqual(tree.breadcrumb(of: "a1").map(\.id), ["root", "a"])
        XCTAssertEqual(tree.height(of: "root"), 2)
        XCTAssertEqual(tree.roots.map(\.id), ["root", "other"])
    }
    func testIDsAreCaseInsensitiveAndOrphansAreRoots() {
        let tree = TaskTree([row("AA"), row("bb", parent: "aa", order: 1), row("cc", parent: "missing", order: 1)])
        XCTAssertEqual(tree.children(of: "aa").map(\.id), ["bb"])
        XCTAssertEqual(tree.roots.map(\.id), ["AA", "cc"]); XCTAssertNil(tree.parentID(of: "cc"))
    }
    func testCycleAndSelfParentDoNotHang() {
        let tree = TaskTree([row("a", parent: "b", order: 1), row("b", parent: "a", order: 1), row("s", parent: "s", order: 1)])
        XCTAssertLessThanOrEqual(tree.descendants(of: "a").count, 2)
        XCTAssertEqual(tree.ancestors(of: "a").count, 1)
        XCTAssertNil(tree.parentID(of: "s"))
    }
    func testChildProgressCountsAllDescendantsAndSkipsHeadings() {
        let tasks = [row("p"), row("c1", parent: "p", order: 1, completed: true), row("c2", parent: "p", order: 2), row("h", parent: "p", order: 3, extra: ["is_heading": .bool(true)]),
                     row("g", parent: "c2", order: 1, completed: true)]
        let tree = TaskTree(tasks)
        XCTAssertTrue(tree.childProgress(of: "p") == (2, 3)); XCTAssertTrue(tree.directChildProgress(of: "p") == (1, 2))
        XCTAssertTrue(tree.childProgress(of: "g") == (0, 0))
    }
    func testTaskCacheBuildsTheIndexLazilyAndRefreshesOnUpdate() {
        let cache = TaskCache()
        cache.update(sample)
        XCTAssertEqual(cache.tree.children(of: "a").count, 2)
        cache.update(sample + [row("a3", parent: "a", order: 3)])
        XCTAssertEqual(cache.tree.children(of: "a").count, 3)
    }

    // MARK: validation
    func assertFails(_ changes: [Mutation], _ tasks: [Record], _ code: TaskTree.Failure.Code, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try TaskTree.validate(changes, tasks: tasks), file: file, line: line) { XCTAssertEqual(($0 as? TaskTree.Failure)?.code, code, file: file, line: line) }
    }
    func testValidateRejectsMissingParentSelfParentAndCycle() throws {
        assertFails([patch("other", ["parent_id": .string("ghost"), "child_order": .number(1)])], sample, .missingParent)
        XCTAssertEqual(TaskTree.Failure(code: .missingParent, taskID: "", message: "").serverCode, "23503")
        assertFails([patch("other", ["parent_id": .string("other")])], sample, .selfParent)
        assertFails([patch("root", ["parent_id": .string("a1"), "child_order": .number(1)])], sample, .cycle)
        try TaskTree.validate([patch("other", ["parent_id": .string("a1"), "child_order": .number(1)])], tasks: sample)
    }
    func testValidateAllowsTenAncestorsAndRejectsEleven() throws {
        let tasks = chain(11) // c0 root ... c10 has ten ancestors
        try TaskTree.validate([patch("c10", ["child_order": .number(2)])], tasks: tasks)
        let deeper = tasks + [row("extra")]
        assertFails([patch("extra", ["parent_id": .string("c10"), "child_order": .number(1)])], deeper, .tooDeep)
    }
    func testValidateCountsTheMovedSubtreesHeight() {
        let tasks = chain(8) + [row("x"), row("y", parent: "x", order: 1), row("z", parent: "y", order: 1), row("w", parent: "z", order: 1)]
        // x's subtree is 3 levels tall; c7 has 7 ancestors, so x at depth 8 puts w at depth 11.
        assertFails([patch("x", ["parent_id": .string("c7"), "child_order": .number(1)])], tasks, .tooDeep)
        XCTAssertNoThrow(try TaskTree.validate([patch("x", ["parent_id": .string("c6"), "child_order": .number(1)])], tasks: tasks))
    }
    func testValidateRequiresSameProjectSectionOrUser() throws {
        let tasks = [row("p", section: "s1"), row("q", section: "s2"), row("n1", project: nil), row("n2", project: nil), row("n3", project: nil, user: "other"), row("pj", project: "p2")]
        assertFails([patch("q", ["parent_id": .string("p"), "child_order": .number(1)])], tasks, .differentContainer)
        assertFails([patch("pj", ["parent_id": .string("p"), "child_order": .number(1)])], tasks, .differentContainer)
        XCTAssertNoThrow(try TaskTree.validate([patch("n2", ["parent_id": .string("n1"), "child_order": .number(1)])], tasks: tasks))
        assertFails([patch("n3", ["parent_id": .string("n1"), "child_order": .number(1)])], tasks, .differentContainer)
    }
    func testValidateJudgesTheStateAfterAWholeBatch() throws {
        // A parent created in the same batch, and a parent and its child moving together.
        let create = Mutation(table: "tasks", recordID: "new", method: "POST", fields: row("new").fields, insertOnly: true)
        try TaskTree.validate([create, patch("other", ["parent_id": .string("new"), "child_order": .number(1)])], tasks: sample)
        try TaskTree.validate([patch("root", ["section_id": .string("s9")]), patch("a", ["section_id": .string("s9")]), patch("a1", ["section_id": .string("s9")]),
                               patch("a2", ["section_id": .string("s9")]), patch("b", ["section_id": .string("s9")])], tasks: sample)
    }
    func testParentMoveCascadesButAChildAloneCannotLeave() throws {
        try TaskTree.validate([patch("root", ["project_id": .string("p2"), "section_id": .string("s2")])], tasks: sample)
        assertFails([patch("a", ["project_id": .string("p2")])], sample, .differentContainer)
    }
    func testDeletingAParentNeedsItsChildren() throws {
        let delete = { (id: String) in Mutation(table: "tasks", recordID: id, method: "DELETE", fields: [:]) }
        assertFails([delete("a")], sample, .childrenRemain)
        try TaskTree.validate(TaskTree.deletionExpansion(of: "a", tasks: sample), tasks: sample)
        try TaskTree.validate([delete("other")], tasks: sample)
    }
    func testChangesThatCannotAffectStructureAreSkipped() throws {
        try TaskTree.validate([patch("a1", ["title": .string("x")])], tasks: [row("a1", parent: "ghost", order: 1)])
        try TaskTree.validate([patch("a", ["parent_id": .null, "child_order": .null])], tasks: [row("a")])
    }

    // MARK: fractional ordering
    func testMidpointAndAppend() {
        XCTAssertEqual(TaskTree.midpoint(nil, nil), 1); XCTAssertEqual(TaskTree.midpoint(2, nil), 3)
        XCTAssertEqual(TaskTree.midpoint(nil, 2), 1); XCTAssertEqual(TaskTree.midpoint(1, 2), 1.5)
        XCTAssertEqual(TaskTree(sample).nextOrder(under: "root"), 3); XCTAssertEqual(TaskTree(sample).nextOrder(under: "other"), 1)
    }
    func testMoveBetweenSiblingsUsesTheMidpoint() throws {
        let tasks = [row("p"), row("a", parent: "p", order: 1), row("b", parent: "p", order: 2), row("m")]
        let result = try TaskTree(tasks).move("m", under: "p", at: .after("a"))
        XCTAssertEqual(result, [TaskTree.Edit(id: "m", fields: ["parent_id": .string("p"), "child_order": .number(1.5)])])
        XCTAssertEqual(TaskTree(edits(result, tasks)).children(of: "p").map(\.id), ["a", "m", "b"])
        XCTAssertEqual(try TaskTree(tasks).move("m", under: "p", at: .first).first?.fields["child_order"], .number(0))
        XCTAssertEqual(try TaskTree(tasks).move("m", under: "p", at: .last).first?.fields["child_order"], .number(3))
        XCTAssertEqual(try TaskTree(tasks).move("m", under: "p", at: .before("b")).first?.fields["child_order"], .number(1.5))
    }
    func testCrowdedNeighboursRenumberEverySibling() throws {
        let tasks = [row("p"), row("a", parent: "p", order: 1), row("b", parent: "p", order: 1 + 1e-9), row("c", parent: "p", order: 5), row("m")]
        let plan = try TaskTree(tasks).move("m", under: "p", at: .after("a"))
        XCTAssertEqual(Set(plan.map(\.id)), ["m", "b", "c"])
        let after = TaskTree(edits(plan, tasks))
        XCTAssertEqual(after.children(of: "p").map(\.id), ["a", "m", "b", "c"])
        XCTAssertEqual(after.children(of: "p").map { TaskTree.childOrder(of: $0) }, [1, 2, 3, 4])
    }
    func testRootsHaveNoChildOrder() throws {
        let plan = try TaskTree(sample).makeTask("a")
        XCTAssertEqual(plan, [TaskTree.Edit(id: "a", fields: ["parent_id": .null, "child_order": .null])])
    }

    // MARK: indent / outdent / make a task
    func testIndentMakesTheTaskTheLastChildOfItsPreviousSibling() throws {
        let tree = TaskTree(sample)
        let plan = try tree.indent("b")
        XCTAssertEqual(plan, [TaskTree.Edit(id: "b", fields: ["parent_id": .string("a"), "child_order": .number(3)])])
        XCTAssertEqual(TaskTree(edits(plan, sample)).children(of: "a").map(\.id), ["a1", "a2", "b"])
        XCTAssertThrowsError(try tree.indent("a")) { XCTAssertEqual(($0 as? TaskTree.Failure)?.code, .noPreviousSibling) }
        // A root takes its previous displayed root.
        let root = try tree.indent("other", previousSibling: "root")
        XCTAssertEqual(root.first?.fields["parent_id"], .string("root")); XCTAssertEqual(root.first?.fields["child_order"], .number(3))
    }
    func testIndentRefusesToGoPastTenLevels() {
        let tasks = chain(11) + [row("s")]
        let withSibling = tasks.map { $0.id == "c10" ? row("c10", parent: "c9", order: 2) : $0 } + [row("c10a", parent: "c9", order: 1)]
        XCTAssertThrowsError(try TaskTree(withSibling).indent("c10")) { XCTAssertEqual(($0 as? TaskTree.Failure)?.code, .tooDeep) }
    }
    func testOutdentBecomesTheNextSiblingOfItsOldParent() throws {
        let tasks = sample
        let plan = try TaskTree(tasks).outdent("a1")
        XCTAssertEqual(plan.count, 1); XCTAssertEqual(plan[0].fields["parent_id"], .string("root")); XCTAssertEqual(plan[0].fields["child_order"], .number(1.5))
        XCTAssertEqual(TaskTree(edits(plan, tasks)).children(of: "root").map(\.id), ["a", "a1", "b"])
        let toRoot = try TaskTree(tasks).outdent("a")
        XCTAssertEqual(toRoot, [TaskTree.Edit(id: "a", fields: ["parent_id": .null, "child_order": .null])])
        XCTAssertThrowsError(try TaskTree(tasks).outdent("root")) { XCTAssertEqual(($0 as? TaskTree.Failure)?.code, .notNested) }
    }
    func testMakeItATaskKeepsItsSubtree() throws {
        let after = TaskTree(edits(try TaskTree(sample).makeTask("a"), sample))
        XCTAssertNil(after.parentID(of: "a")); XCTAssertEqual(after.children(of: "a").map(\.id), ["a1", "a2"])
        XCTAssertThrowsError(try TaskTree(sample).makeTask("other")) { XCTAssertEqual(($0 as? TaskTree.Failure)?.code, .notNested) }
    }
    func testMovingAParentInsideItsOwnSubtreeFails() {
        XCTAssertThrowsError(try TaskTree(sample).move("root", under: "a1")) { XCTAssertEqual(($0 as? TaskTree.Failure)?.code, .cycle) }
    }
    func testEditsBecomeMutationsWithBaselines() {
        let list = TaskTree.mutations([TaskTree.Edit(id: "b", fields: ["child_order": .number(9)])], tasks: sample)
        XCTAssertEqual(list[0].method, "PATCH"); XCTAssertEqual(list[0].baseline?["child_order"], .number(2)); XCTAssertEqual(list[0].baseline?["task_generation"], .string("gen-b"))
    }

    // MARK: project and section moves
    func testCascadeLocalMovesDescendantsAndClearsAssignees() {
        var tasks = sample; tasks[3] = row("a1", parent: "a", order: 1, extra: ["assigned_to": .string("someone")])
        let plan = TaskTree.cascadeLocal([patch("root", ["project_id": .string("p2"), "section_id": .string("s2")])], tasks: tasks)
        XCTAssertEqual(Set(plan.map(\.id)), ["a", "a1", "a2", "b"])
        let a1 = plan.first { $0.id == "a1" }!
        XCTAssertEqual(a1.fields["project_id"], .string("p2")); XCTAssertEqual(a1.fields["section_id"], .string("s2")); XCTAssertEqual(a1.fields["assigned_to"], .null)
        XCTAssertNil(plan.first { $0.id == "a" }!.fields["assigned_to"])
        XCTAssertTrue(TaskTree.cascadeLocal([patch("root", ["title": .string("x")])], tasks: tasks).isEmpty)
        let sectionOnly = TaskTree.cascadeLocal([patch("root", ["section_id": .string("s3")])], tasks: tasks)
        XCTAssertNil(sectionOnly.first!.fields["project_id"]); XCTAssertNil(sectionOnly.first!.fields["assigned_to"])
    }
    func testMovingAChildToAnotherProjectDetachesItAndMovesItsSubtree() throws {
        let plan = try TaskTree(sample).moveToProject("a", project: "p2", section: nil)
        let result = edits(plan, sample)
        XCTAssertEqual(Set(plan.map(\.id)), ["a", "a1", "a2"])
        let tree = TaskTree(result)
        XCTAssertNil(tree.parentID(of: "a")); XCTAssertEqual(tree.task("a1")?.string("project_id"), "p2"); XCTAssertEqual(tree.children(of: "a").count, 2)
        XCTAssertNoThrow(try TaskTree.validate(TaskTree.mutations(plan, tasks: sample), tasks: sample))
        // A root move keeps no parent edit.
        XCTAssertNil(try TaskTree(sample).moveToProject("root", project: "p2", section: nil).first?.fields["parent_id"])
    }

    // MARK: completion
    func completedPlan(_ id: String, _ tasks: [Record]) throws -> TaskTree.CompletionPlan {
        try XCTUnwrap(TaskTree.completion(of: try XCTUnwrap(tasks.first { $0.id == id }), tasks: tasks, at: Date(timeIntervalSince1970: 1_800_000_000)))
    }
    func testCompletingAParentCompletesOpenDescendantsOnly() throws {
        var tasks = sample; tasks[2] = row("a", parent: "root", order: 1, completed: true)
        tasks.append(row("h", parent: "root", order: 9, extra: ["is_heading": .bool(true)]))
        let plan = try completedPlan("root", tasks)
        XCTAssertEqual(Set(plan.cascaded), ["a1", "a2", "b"])
        XCTAssertEqual(plan.mutations.first?.recordID, "root")
        let after = TaskTree.apply(plan.mutations, to: tasks)
        for id in ["root", "a1", "a2", "b"] { XCTAssertTrue(after.first { $0.id == id }!.completed, id) }
        XCTAssertFalse(after.first { $0.id == "h" }!.completed); XCTAssertFalse(after.first { $0.id == "other" }!.completed)
        let stamp = try XCTUnwrap(plan.mutations.first?.fields["completed_at"])
        XCTAssertTrue(plan.mutations.dropFirst().allSatisfy { $0.fields["completed_at"] == stamp })
    }
    func testUndoOfACascadeRestoresEveryRecordExactly() throws {
        let tasks = sample
        let plan = try completedPlan("root", tasks)
        let after = TaskTree.apply(plan.mutations, to: tasks)
        let restored = TaskTree.apply(plan.inverse, to: after)
        XCTAssertEqual(normalized(restored), normalized(tasks))
        XCTAssertEqual(plan.inverse.count, plan.mutations.count)
    }
    func testReopeningAChildReopensCompletedAncestors() throws {
        let tasks = sample.map { $0.id == "root" || $0.id == "a" || $0.id == "a1" ? row($0.id, parent: $0.string("parent_id").isEmpty ? nil : $0.string("parent_id"), order: TaskTree.childOrder(of: $0), completed: true) : $0 }
        let plan = try completedPlan("a1", tasks)
        XCTAssertEqual(Set(plan.cascaded), ["a", "root"])
        let after = TaskTree.apply(plan.mutations, to: tasks)
        XCTAssertFalse(after.first { $0.id == "a1" }!.completed); XCTAssertFalse(after.first { $0.id == "a" }!.completed); XCTAssertFalse(after.first { $0.id == "root" }!.completed)
        XCTAssertEqual(TaskTree.apply(plan.inverse, to: after).map(\.completed), tasks.map(\.completed))
    }
    func testCompletingAChildLeavesItsParentAlone() throws {
        let plan = try completedPlan("a1", sample)
        XCTAssertEqual(plan.mutations.map(\.recordID), ["a1"]); XCTAssertTrue(plan.cascaded.isEmpty)
    }
    func recurring(_ tasks: [Record]) -> [Record] {
        tasks.map { $0.id == "root" ? row("root", extra: ["is_recurring": .bool(true), "recurrence_pattern": .object(["type": .string("daily")]), "due_date": .string("2026-10-31")]) :
            $0.id == "a1" ? row("a1", parent: "a", order: 1, extra: ["due_date": .string("2026-11-02"), "comments": .array([.string("c")])]) : $0 }
    }
    func testRecurringParentCreatesDeterministicSuccessorChildrenParentFirst() throws {
        let tasks = recurring(sample)
        let plan = try completedPlan("root", tasks), again = try completedPlan("root", tasks)
        let posts = plan.mutations.filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 5) // successor + a, a1, a2, b
        let successor = posts[0]
        XCTAssertNotEqual(successor.recordID, "root")
        XCTAssertEqual(posts.map(\.recordID), again.mutations.filter { $0.method == "POST" }.map(\.recordID))
        XCTAssertEqual(Set(posts.map(\.recordID)).count, 5)
        XCTAssertEqual(posts[1].fields["parent_id"], .string(successor.recordID))
        let a = posts.first { $0.fields["title"] == .string("a") }!, a1 = posts.first { $0.fields["title"] == .string("a1") }!
        XCTAssertEqual(a1.fields["parent_id"], .string(a.recordID))
        XCTAssertLessThan(posts.firstIndex { $0.recordID == a.recordID }!, posts.firstIndex { $0.recordID == a1.recordID }!)
        XCTAssertEqual(a1.fields["completed"], .bool(false)); XCTAssertEqual(a1.fields["comments"], .array([]));
        XCTAssertEqual(a1.insertOnly, true)
        XCTAssertEqual(a1.recordID, TaskTree.successorChildID(successorParent: successor.recordID, source: "a1"))
        // The new tree validates against the old one.
        XCTAssertNoThrow(try TaskTree.validate(plan.mutations, tasks: tasks))
        let after = TaskTree(TaskTree.apply(plan.mutations, to: tasks))
        XCTAssertEqual(after.descendants(of: successor.recordID).count, 4); XCTAssertEqual(after.descendants(of: successor.recordID).filter(\.completed).count, 0)
    }
    func testSuccessorChildrenShiftTheirDatesWithTheParent() throws {
        let tasks = recurring(sample)
        let plan = try completedPlan("root", tasks)
        let successorDue = plan.mutations.first { $0.method == "POST" }!.fields["due_date"]!.text
        XCTAssertGreaterThan(successorDue, "2026-10-31")
        let a1 = plan.mutations.first { $0.method == "POST" && $0.fields["title"] == .string("a1") }!
        XCTAssertGreaterThan(a1.fields["due_date"]!.text, "2026-11-02")
    }
    func testRecurringUndoDeletesSuccessorsChildrenFirstAndIsExact() throws {
        let tasks = recurring(sample)
        let plan = try completedPlan("root", tasks)
        let after = TaskTree.apply(plan.mutations, to: tasks)
        let deletes = plan.inverse.filter { $0.method == "DELETE" }
        XCTAssertEqual(deletes.count, 5)
        XCTAssertEqual(deletes.last?.recordID, plan.mutations.first { $0.method == "POST" }!.recordID, "the successor parent is deleted last")
        XCTAssertTrue(deletes.allSatisfy { $0.baseline != nil })
        let tree = TaskTree(after)
        for (index, delete) in deletes.enumerated() {
            let later = Set(deletes[(index + 1)...].map(\.recordID))
            XCTAssertTrue(tree.descendants(of: delete.recordID).allSatisfy { !later.contains($0.id) }, "children go before their parent")
        }
        XCTAssertEqual(normalized(TaskTree.apply(plan.inverse, to: after)), normalized(tasks))
    }
    func testSuccessorRowsAreIdempotent() throws {
        let tasks = recurring(sample)
        let first = try completedPlan("root", tasks)
        let existing = tasks + first.mutations.filter { $0.method == "POST" && !$0.fields["title"]!.text.hasPrefix("root") }.map { Record($0.fields) }
        let successor = first.mutations.first { $0.method == "POST" }!
        XCTAssertTrue(TaskTree.successorRows(of: tasks[0], successor: successor, tasks: existing).isEmpty)
    }

    // MARK: deletion
    func testDeletionExpansionIsDeepestFirstWithFullBaselines() {
        let list = TaskTree.deletionExpansion(of: "root", tasks: sample)
        XCTAssertEqual(list.map(\.recordID).last, "root")
        XCTAssertEqual(Set(list.map(\.recordID)), ["root", "a", "a1", "a2", "b"])
        let tree = TaskTree(sample)
        let depths = list.map { tree.depth(of: $0.recordID) }
        XCTAssertEqual(depths, depths.sorted(by: >))
        for change in list { XCTAssertEqual(change.method, "DELETE"); XCTAssertEqual(change.baseline, sample.first { $0.id == change.recordID }?.fields) }
        XCTAssertTrue(TaskTree.deletionExpansion(of: "nope", tasks: sample).isEmpty)
        XCTAssertEqual(TaskTree.deletionExpansion(of: "other", tasks: sample).map(\.recordID), ["other"])
    }
    func testDeletionUndoRecreatesParentFirstAndRestoresEverything() {
        let undo = TaskTree.deletionUndo(of: "root", tasks: sample)
        XCTAssertEqual(undo.first?.recordID, "root")
        XCTAssertTrue(undo.allSatisfy { $0.method == "POST" && $0.insertOnly == true })
        let tree = TaskTree(sample)
        let depths = undo.map { tree.depth(of: $0.recordID) }
        XCTAssertEqual(depths, depths.sorted())
        let deleted = TaskTree.apply(TaskTree.deletionExpansion(of: "root", tasks: sample), to: sample)
        XCTAssertEqual(deleted.map(\.id), ["other"])
        let restored = TaskTree.apply(undo, to: deleted).sorted { $0.id < $1.id }
        XCTAssertEqual(restored.map(\.fields), sample.sorted { $0.id < $1.id }.map(\.fields))
        XCTAssertNoThrow(try TaskTree.validate(undo, tasks: deleted))
    }
    func testInverseOfPatchRestoresPreviousValues() {
        let change = patch("b", ["title": .string("new"), "child_order": .number(7), "missing_before": .string("x")])
        let back = TaskTree.inverse(of: [change], before: sample)
        XCTAssertEqual(back.count, 1); XCTAssertEqual(back[0].fields["title"], .string("b")); XCTAssertEqual(back[0].fields["child_order"], .number(2)); XCTAssertEqual(back[0].fields["missing_before"], .null)
    }
}
