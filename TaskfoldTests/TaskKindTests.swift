import XCTest
@testable import TaskfoldCore

final class TaskKindTests: XCTestCase {
    func task() -> Record { var row = Record.task(user: UUID().uuidString.lowercased()); row["title"] = .string("* Keep this literal title"); return row }
    func heading() -> Record { var row = task(); row["is_heading"] = .bool(true); return row }
    func patch(_ row: Record, _ fields: [String: JSON]) -> Mutation { Mutation(table: "tasks", recordID: row.id, method: "PATCH", fields: fields, baseline: TaskCompletionRevision.editBaseline(for: fields, from: row)) }
    func testLegacyNilNullAndFalseRemainOrdinaryAndAsteriskIsLiteral() {
        var row = task(); XCTAssertEqual(TaskKind(row), .task); XCTAssertTrue(TaskKind.mayComplete(row)); XCTAssertTrue(row.title.hasPrefix("* "))
        row["is_heading"] = .null; XCTAssertEqual(TaskKind(row), .task)
        row["is_heading"] = .bool(false); XCTAssertEqual(TaskKind(row), .task)
        row["is_heading"] = .string("true"); XCTAssertEqual(TaskKind(row), .unsupported); XCTAssertFalse(TaskKind.mayComplete(row))
    }
    func testHeadingCannotCompleteReopenOrGenerateARecurringSuccessor() {
        var row = heading(); row["is_recurring"] = .bool(true); row["recurrence_pattern"] = .object(["type": .string("daily")]); row["due_date"] = .string(Dates.day(Date()))
        XCTAssertTrue(TaskCompletion.complete(row, tasks: [row]).isEmpty); XCTAssertTrue(TaskCompletion.toggle(row, tasks: [row]).isEmpty)
        row["completed"] = .bool(true); XCTAssertTrue(TaskCompletion.toggle(row, tasks: [row]).isEmpty)
    }
    func testExplicitConversionKeepsEveryOtherFieldAndCapturesCompletionAuthority() throws {
        var row = task(); row["opaque_future"] = .object(["kept": .bool(true)]); row["description"] = .string("Full notes"); row["attachments"] = .array([.object(["name": .string("brief")])]); row["completion_version"] = .number(7)
        let change = try XCTUnwrap(TaskKind.change(row, heading: true)); XCTAssertEqual(change.fields, ["is_heading": .bool(true)])
        XCTAssertEqual(change.baseline?["completed"], .bool(false)); XCTAssertEqual(change.baseline?["completed_at"], .null); XCTAssertEqual(change.baseline?["completion_version"], .number(7)); XCTAssertEqual(change.baseline?["task_generation"], row["task_generation"])
        var expected = row; expected["is_heading"] = .bool(true); expected["completion_version"] = .number(8)
        XCTAssertEqual(TaskCompletionRevision.applying(change.fields, to: row), expected)
    }
    func testRepeatedTypeChoiceIsNoOpAndCompletedTaskNeedsReopening() throws {
        XCTAssertNil(try TaskKind.change(task(), heading: false)); XCTAssertNil(try TaskKind.change(heading(), heading: true))
        var row = task(); row["completed"] = .bool(true); XCTAssertThrowsError(try TaskKind.change(row, heading: true))
        row["is_heading"] = .bool(true); XCTAssertNotNil(try TaskKind.change(row, heading: false))
    }
    func testMalformedTypeOrMissingIncarnationCannotGainAnAction() throws {
        var row = task(); row["is_heading"] = .number(1); XCTAssertThrowsError(try TaskKind.change(row, heading: true)); XCTAssertTrue(TaskCompletion.toggle(row, tasks: [row]).isEmpty)
        row = task(); row.fields.removeValue(forKey: "task_generation"); XCTAssertThrowsError(try TaskKind.change(row, heading: true))
        row = task(); row["id"] = .string("synthetic-child-path"); XCTAssertThrowsError(try TaskKind.change(row, heading: true))
    }
    func testStaleCompletedTimestampIsExplicitlyClearedDuringConversion() throws {
        var row = task(); row["completed_at"] = .string("2026-10-20T10:00:00Z")
        let change = try XCTUnwrap(TaskKind.change(row, heading: true)); XCTAssertEqual(change.fields["completed_at"], .null); XCTAssertEqual(change.baseline?["completed_at"], row["completed_at"])
        XCTAssertTrue(TaskKind.permits(change, existing: row))
    }
    func testLocalSnapshotRefusesOldCompletionWithoutTouchingHeading() {
        let row = heading(); var snapshot = Snapshot(tables: ["tasks": [row]]); let before = snapshot
        snapshot.apply(patch(row, ["completed": .bool(true)])); XCTAssertEqual(snapshot, before)
        snapshot.apply(patch(row, ["completed_at": .string("2026-10-20T10:00:00Z")])); XCTAssertEqual(snapshot, before)
    }
    func testHeadingMetadataChangesRemainAvailableAndOpaqueContainersSurvive() {
        let row = heading(); var snapshot = Snapshot(tables: ["tasks": [row]])
        let fields: [String: JSON] = ["title": .string("Project notes"), "description": .string("Full instructions"), "due_date": .string("2026-10-28"), "subtasks": .object(["future_shape": .string("kept")])]
        snapshot.apply(patch(row, fields)); let after = snapshot.tables["tasks"]![0]
        XCTAssertEqual(TaskKind(after), .heading); XCTAssertEqual(after["subtasks"], fields["subtasks"]); XCTAssertEqual(after.string("description"), "Full instructions"); XCTAssertEqual(after.string("due_date"), "2026-10-28")
    }
    func testCreationRejectsCompletedHeadingButPreservesAnOrdinaryLegacyContainer() {
        var row = heading(); row["completed"] = .bool(true)
        XCTAssertFalse(TaskKind.permits(Mutation(table: "tasks", recordID: row.id, method: "POST", fields: row.fields), existing: nil))
        row = task(); row["subtasks"] = .object(["future_shape": .string("kept")]); XCTAssertTrue(TaskKind.permits(Mutation(table: "tasks", recordID: row.id, method: "POST", fields: row.fields), existing: nil))
    }
    func testNestedHeadingCannotCompleteAndAnOlderWriterCannotEraseItsType() {
        var parent = task(); let child = heading(); parent["subtasks"] = .array([.object(child.fields)])
        var changed = child; changed["completed"] = .bool(true)
        XCTAssertFalse(TaskKind.permits(patch(parent, ["subtasks": .array([.object(changed.fields)])]), existing: parent))
        changed = child; changed.fields.removeValue(forKey: "is_heading"); XCTAssertFalse(TaskKind.permits(patch(parent, ["subtasks": .array([.object(changed.fields)])]), existing: parent))
        changed = child; changed["is_heading"] = .bool(false); XCTAssertTrue(TaskKind.permits(patch(parent, ["subtasks": .array([.object(changed.fields)])]), existing: parent))
    }
    func testNestedPreservationInspectsContainmentOnlyAndAllowsExplicitRemoval() {
        var parent = task(), child = heading(); child["opaque_future"] = .object(["is_heading": .bool(true), "completed": .bool(true)])
        parent["subtasks"] = .array([.object(child.fields)])
        var changed = child; changed["description"] = .string("New note"); XCTAssertTrue(TaskKind.permits(patch(parent, ["subtasks": .array([.object(changed.fields)])]), existing: parent))
        XCTAssertTrue(TaskKind.permits(patch(parent, ["subtasks": .array([])]), existing: parent))
        XCTAssertTrue(TaskKind.permits(Mutation(table: "tasks", recordID: parent.id, method: "DELETE", fields: [:]), existing: parent))
    }
    func testMalformedNestedHeadingAndUnknownFlagAreRefusedWithoutPartialTreeChanges() {
        let parent = task(); var child = heading(); child.fields.removeValue(forKey: "id")
        XCTAssertFalse(TaskKind.permits(patch(parent, ["subtasks": .array([.object(child.fields)])]), existing: parent))
        child = task(); child["is_heading"] = .array([]); XCTAssertFalse(TaskKind.permits(patch(parent, ["subtasks": .array([.object(child.fields)])]), existing: parent))
    }
    func testKindHistoryAdvancesCompletionRevisionButOrdinaryNilToFalseDoesNot() {
        let row = task(); let same = TaskCompletionRevision.applying(["is_heading": .bool(false)], to: row); XCTAssertEqual(same["completion_version"], row["completion_version"])
        let heading = TaskCompletionRevision.applying(["is_heading": .bool(true)], to: row); XCTAssertEqual(heading["completion_version"], .number(1))
        let returned = TaskCompletionRevision.applying(["is_heading": .bool(false)], to: heading); XCTAssertEqual(returned["completion_version"], .number(2))
    }
}


extension TaskKindTests {
    func testUndoUsesExplicitTaskTypeAndRedoKeepsHeadingWithoutLosingDetails() throws {
        let row = task(); let change = try XCTUnwrap(TaskKind.change(row, heading: true))
        let history = EditHistory(changes: [change], snapshot: Snapshot(tables: ["tasks": [row]]))
        XCTAssertEqual(history.undo.first?.fields["is_heading"], .bool(false))
        var snapshot = Snapshot(tables: ["tasks": [row]]); snapshot.apply(change)
        let heading = snapshot.tables["tasks"]![0]; XCTAssertEqual(TaskKind(heading), .heading)
        snapshot.apply(history.undo[0]); let undone = snapshot.tables["tasks"]![0]
        XCTAssertEqual(TaskKind(undone), .task); XCTAssertEqual(undone["completion_version"], .number(2)); XCTAssertEqual(undone.title, row.title)
        snapshot.apply(history.redo[0]); XCTAssertEqual(TaskKind(snapshot.tables["tasks"]![0]), .heading)
        XCTAssertEqual(snapshot.tables["tasks"]![0]["completion_version"], .number(3))
    }
    func testOldWholeRowWriterCannotDropTheHeadingFlagOrOverwriteAnUnknownType() {
        let row = heading(); XCTAssertFalse(TaskKind.permits(patch(row, ["is_heading": .null, "completed": .bool(true)]), existing: row))
        var future = task(); future["is_heading"] = .string("future-kind")
        XCTAssertFalse(TaskKind.permits(patch(future, ["is_heading": .bool(true)]), existing: future))
        XCTAssertTrue(TaskKind.permits(patch(future, ["description": .string("Keep my note")]), existing: future))
    }
}


extension TaskKindTests {
    func testWidgetRefusesHeadingAndInvalidatesExistingActionAfterTypeChange() throws {
        var row = task(); var snapshot = Snapshot(tables: ["tasks": [row]])
        WidgetCompletion.prepare(&snapshot)
        let oldToken = try XCTUnwrap(WidgetCompletion.tokens(snapshot)[row.id.lowercased()])
        let oldRequest = try WidgetCompletionRequest(account: "owner", taskID: row.id, token: oldToken)
        row["is_heading"] = .bool(true); snapshot.tables["tasks"] = [row]
        if case .stale = WidgetCompletion.plan(oldRequest, snapshot: snapshot, account: "owner") {} else { XCTFail("No completion or success feedback for a heading") }
        WidgetCompletion.prepare(&snapshot)
        let newToken = try XCTUnwrap(WidgetCompletion.tokens(snapshot)[row.id.lowercased()])
        XCTAssertNotEqual(newToken, oldToken)
        let request = try WidgetCompletionRequest(account: "owner", taskID: row.id, token: newToken)
        if case .stale = WidgetCompletion.plan(request, snapshot: snapshot, account: "owner") {} else { XCTFail("Even a fresh token cannot complete a heading") }
    }
    func testMixedRootCompletionRefusesWholeSelectionBeforeReturningAnyChanges() throws {
        let ordinary = task(), heading = heading(); let workspace = WorkspaceBinding(account: "owner", generation: UUID())
        let requests = [ordinary, heading].map { TaskSelectionPlan.Request(task: $0, action: .completion(true, Date()), workspace: workspace) }
        XCTAssertThrowsError(try TaskSelectionPlan.changes(requests, accessibleRoots: [ordinary, heading], projects: [], workspace: workspace))
        let staleRequest = TaskSelectionPlan.Request(task: ordinary, action: .completion(true, Date()), workspace: workspace)
        var changed = ordinary; changed["is_heading"] = .bool(true)
        XCTAssertThrowsError(try TaskSelectionPlan.changes([staleRequest], accessibleRoots: [changed], projects: [], workspace: workspace))
    }
    func testMixedChildCompletionRefusesHeadingButItsOrdinaryChildRemainsActionable() throws {
        let workspace = WorkspaceBinding(account: "owner", generation: UUID())
        var root = task(), heading = heading(); let child = task()
        heading["subtasks"] = .array([.object(child.fields)]); root["subtasks"] = .array([.object(heading.fields)])
        let index = try TaskHierarchyIndex(roots: [root], projects: [], workspace: workspace)
        let header = try XCTUnwrap(index.items.first { $0.source.id == heading.id && $0.isSubtask })
        let leaf = try XCTUnwrap(index.items.first { $0.source.id == child.id && $0.isSubtask })
        let selection = try XCTUnwrap(index.selection(header.id)), leafSelection = try XCTUnwrap(index.selection(leaf.id))
        XCTAssertThrowsError(try TaskHierarchyIndex.changes([.completion(leafSelection, completed: true), .completion(selection, completed: true)], accessibleRoots: [root], projects: [], workspace: workspace))
        let mutations = try TaskHierarchyIndex.changes([.completion(leafSelection, completed: true)], accessibleRoots: [root], projects: [], workspace: workspace)
        XCTAssertEqual(mutations.count, 1); XCTAssertTrue(TaskKind.permits(mutations[0], existing: root))
        let updated = mutations[0].fields["subtasks"]!.list[0].object
        XCTAssertEqual(updated["completed"], .bool(false)); XCTAssertEqual(updated["is_heading"], .bool(true))
        XCTAssertEqual(updated["subtasks"]!.list[0].object["completed"], .bool(true))
    }
}
