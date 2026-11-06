import XCTest
@testable import TaskfoldCore

final class AssignmentTreePreservationTests: XCTestCase {
    private let owner = "a1111111-1111-4111-8111-111111111111"
    private let sourceProject = "a3333333-3333-4333-8333-333333333333"
    private let destination = "a4444444-4444-4444-8444-444444444444"
    private func decode(_ raw: String) throws -> JSON { try TaskfoldJSONDecoder().decode(JSON.self, from: Data(raw.utf8)) }
    private func bytes<T: Encodable>(_ value: T) throws -> Data { let e = TaskfoldJSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(value) }
    private func child() throws -> JSON {
        try decode(#"{ "id":"child", "title":"Keep café", "assigned_to":"old-person", "é":9007199254740993, "e\u0301":1e1000, "future":{"é":1,"é":2}, "subtasks":[{"id":"nested","title":"Nested","assigned_to":"another-person","subtasks":null}] }"#)
    }
    private func root(_ children: JSON? = nil) throws -> Record {
        var row = Record.task(user: owner, project: sourceProject)
        row["title"] = .string("Keep #Destination")
        row["assigned_to"] = .string(owner); row["section_id"] = .string("old-section")
        row["subtasks"] = try children ?? .array([child(), .string("Legacy text"), .object(["id": .string("sparse"), "title": .string("Sparse"), "subtasks": .null])])
        return row
    }
    private func assertUnknowns(_ value: JSON, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try bytes(value)
        for token in [#""é":9007199254740993"#, #""e\u0301":1e1000"#, #""future":{"é":1,"é":2}"#] {
            XCTAssertNotNil(data.range(of: Data(token.utf8)), file: file, line: line)
        }
    }
    func testDraftMoveClearsEveryAssignmentWithoutFlatteningMetadataOrLegacyText() throws {
        let original = try root(), before = try bytes(original)
        let moved = try TaskAssignment.movingDraft(original, to: .string(destination))
        XCTAssertEqual(moved["project_id"], .string(destination)); XCTAssertEqual(moved["section_id"], .null); XCTAssertEqual(moved["assigned_to"], .null)
        let parent = moved["subtasks"].list[0], fields = try parent.fieldEditingProjection()
        XCTAssertEqual(fields["assigned_to"], .null)
        XCTAssertEqual(fields["subtasks"]?.list[0].object["assigned_to"], .null)
        XCTAssertEqual(fields["subtasks"]?.list[0].object["subtasks"], .null)
        XCTAssertEqual(moved["subtasks"].list[1], .string("Legacy text"))
        try assertUnknowns(parent)
        for key in original.fields.keys where !["project_id","section_id","assigned_to","subtasks"].contains(key) { XCTAssertTrue(AuthoredValueComparison.exactJSON(moved[key], original[key]), key) }
        XCTAssertEqual(try bytes(original), before)
    }
    func testServerStyleRemovalPreservesNullAbsenceAndExactUnknownTokens() throws {
        let input = try root()["subtasks"], output = try PersonalTaskMove.clearAssignments(input)
        let fields = try output.list[0].fieldEditingProjection()
        XCTAssertNil(fields["assigned_to"]); XCTAssertNil(fields["subtasks"]?.list[0].object["assigned_to"])
        XCTAssertEqual(fields["subtasks"]?.list[0].object["subtasks"], .null)
        XCTAssertEqual(output.list[1], input.list[1]); XCTAssertEqual(output.list[2].object["subtasks"], .null)
        try assertUnknowns(output.list[0])
        XCTAssertEqual(try PersonalTaskMove.clearAssignments(.null), .null)
    }
    func testSameProjectIsANoOpAndReturningToTheOriginalProjectClearsNewAssignments() throws {
        let original = try root()
        XCTAssertEqual(try bytes(TaskAssignment.movingDraft(original, to: .string(sourceProject))), try bytes(original))
        var elsewhere = try TaskAssignment.movingDraft(original, to: .string(destination))
        elsewhere["assigned_to"] = .string("new-person")
        var children = elsewhere["subtasks"].list
        children[0] = try children[0].editingASCIIFields(["assigned_to": .string("new-person")]); elsewhere["subtasks"] = .array(children)
        for project in [JSON.string(sourceProject), .null] {
            let returned = try TaskAssignment.movingDraft(elsewhere, to: project)
            XCTAssertEqual(returned["assigned_to"], .null); XCTAssertEqual(try returned["subtasks"].list[0].fieldEditingProjection()["assigned_to"], .null)
            try assertUnknowns(returned["subtasks"].list[0])
        }
    }
    func testMalformedBranchesRefuseTheWholeMoveBeforeReturningCommands() throws {
        let bad = try root(.array([.object(["title": .string("Bad"), "subtasks": .string("Future container")])]))
        let before = try bytes(bad)
        XCTAssertThrowsError(try TaskAssignment.movingDraft(bad, to: .string(destination)))
        let change = Mutation(table: "tasks", recordID: bad.id, method: "PATCH", fields: ["project_id": .string(destination)])
        XCTAssertThrowsError(try TaskAssignment.mutations(change, existing: bad))
        var budget = TaskAssignmentTree.Budget()
        let good = try root(.array([])), goodChange = Mutation(table: "tasks", recordID: good.id, method: "PATCH", fields: ["project_id": .string(destination)])
        XCTAssertThrowsError(try [(goodChange, good), (change, bad)].flatMap { try TaskAssignment.mutations($0.0, existing: $0.1, budget: &budget) })
        XCTAssertEqual(try bytes(bad), before)
    }
    func testPersonalProjectionAndHistoryNeverApplyPartOfAnUnsupportedMove() throws {
        let bad = try root(.object(["future": .bool(true)]))
        let change = Mutation(table: "tasks", recordID: bad.id, method: "PATCH", fields: ["project_id": .string(destination)], baseline: ["project_id": bad["project_id"], "task_generation": bad["task_generation"]], personalTaskMove: true)
        XCTAssertThrowsError(try PersonalTaskMove.projectedFields(change, onto: bad))
        var snapshot = Snapshot(); snapshot.tables["tasks"] = [bad]; snapshot.pending = [change]
        let before = try bytes(snapshot); snapshot.apply(change)
        XCTAssertEqual(try bytes(snapshot), before)
        let history = EditHistory(changes: [change], snapshot: snapshot)
        XCTAssertTrue(history.undo.isEmpty); XCTAssertTrue(history.redo.isEmpty)
    }
    func testMetadataOnlyMoveKeepsItsRequestSmallAndProjectsExactCurrentFields() throws {
        let original = try root()
        let change = Mutation(table: "tasks", recordID: original.id, method: "PATCH", fields: ["project_id": .string(destination)], baseline: ["task_generation": original["task_generation"], "project_id": original["project_id"]], personalTaskMove: true)
        let normalized = try XCTUnwrap(TaskAssignment.mutations(change, existing: original).first)
        XCTAssertNil(normalized.fields["subtasks"]); XCTAssertNil(normalized.fields["assigned_to"])
        XCTAssertNil(try PersonalTaskMove.body(normalized, account: owner)["changes"]?.object["subtasks"])
        var snapshot = Snapshot(); snapshot.tables["tasks"] = [original]; snapshot.apply(normalized)
        let moved = try XCTUnwrap(snapshot.tables["tasks"]?.first)
        XCTAssertEqual(moved["project_id"], .string(destination)); XCTAssertNil(try moved["subtasks"].list[0].fieldEditingProjection()["assigned_to"])
        try assertUnknowns(moved["subtasks"].list[0])
        let cold = try TaskfoldJSONDecoder().decode(Snapshot.self, from: bytes(snapshot))
        try assertUnknowns(cold.tables["tasks"]![0]["subtasks"].list[0])
    }
    func testDraftAssignmentCleanupDoesNotReplayAnOldChecklist() throws {
        let original = try root()
        let draft = try TaskAssignment.movingDraft(original, to: .string(destination))
        let fields = ["project_id": draft["project_id"], "subtasks": draft["subtasks"]]
        let baseline = TaskCompletionRevision.editBaseline(for: fields, from: original)
        let change = Mutation(table: "tasks", recordID: original.id, method: "PATCH", fields: fields, baseline: baseline, personalTaskMove: true)
        var current = original
        var children = current["subtasks"].list
        children[0] = try children[0].editingASCIIFields(["notes": .string("Newer remote notes")])
        current["subtasks"] = .array(children)
        let normalized = try XCTUnwrap(TaskAssignment.mutations(change, existing: current).first)
        XCTAssertNil(normalized.fields["subtasks"]); XCTAssertNil(normalized.baseline?["subtasks"])
        let projected = try PersonalTaskMove.projectedFields(normalized, onto: current)
        XCTAssertEqual(try projected["subtasks"]?.list[0].fieldEditingProjection()["notes"], .string("Newer remote notes"))
        try assertUnknowns(try XCTUnwrap(projected["subtasks"]).list[0])

        var edited = change
        var authored = draft["subtasks"].list
        authored[0] = try authored[0].editingASCIIFields(["notes": .string("Deliberate child edit")])
        edited.fields["subtasks"] = .array(authored)
        let retained = try XCTUnwrap(TaskAssignment.mutations(edited, existing: current).first)
        XCTAssertEqual(try retained.fields["subtasks"]?.list[0].fieldEditingProjection()["notes"], .string("Deliberate child edit"))
        XCTAssertTrue(AuthoredValueComparison.exactJSON(try XCTUnwrap(retained.baseline?["subtasks"]), original["subtasks"]))
    }
    func testCheckedQuickEntryKeepsTheTypedInputOnFailureAndPreviewIsReadOnly() throws {
        let bad = try root(.object(["future": .bool(true)]))
        var parsed = QuickEntry(bad.title, task: bad); parsed.updates = ["project_id": .string(destination)]; parsed.title = "Keep"
        XCTAssertThrowsError(try parsed.applyingChecked(to: bad))
        XCTAssertEqual(try bytes(parsed.applying(to: bad)), try bytes(bad))
        let preview = parsed.fieldPreview(to: bad)
        XCTAssertEqual(preview["project_id"], .string(destination)); XCTAssertEqual(preview["subtasks"], bad["subtasks"])
        let changes = preview.fields.filter { bad.fields[$0.key] != $0.value }
        XCTAssertThrowsError(try TaskAssignment.mutations(Mutation(table: "tasks", recordID: bad.id, method: "PATCH", fields: changes), existing: bad))
        let good = try root(); let applied = try parsed.applyingChecked(to: good)
        XCTAssertEqual(applied.title, "Keep"); try assertUnknowns(applied["subtasks"].list[0])
    }
    func testDepthAndSharedNodeBudgetsRefuseWithoutChangingInput() throws {
        var deep: JSON = .array([])
        for _ in 0...SubtaskTree.readableDepth { deep = .array([.object(["subtasks": deep])]) }
        XCTAssertThrowsError(try TaskAssignment.clearChildren(deep))
        var budget = TaskAssignmentTree.Budget()
        let full = JSON.array(Array(repeating: JSON.string("Legacy"), count: TaskHierarchyIndex.maximumItems))
        XCTAssertEqual(try TaskAssignmentTree.cleared(full, removing: false, budget: &budget), full)
        XCTAssertThrowsError(try TaskAssignmentTree.cleared(.array([.string("One more")]), removing: false, budget: &budget))
    }
}
