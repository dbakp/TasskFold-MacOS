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

extension TaskKindTests {
    func testDraftChoicePreservesAllDetailsAndWorksForEmbeddedChildren() throws {
        var original = task(); original.fields.removeValue(forKey: "task_generation")
        original["description"] = .string("Full notes"); original["opaque"] = .object(["keep": .bool(true)])
        let edited = try TaskKind.setting(original, heading: true)
        XCTAssertEqual(edited.id, original.id); XCTAssertEqual(edited["description"], original["description"]); XCTAssertEqual(edited["opaque"], original["opaque"])
        XCTAssertEqual(edited["is_heading"], .bool(true)); XCTAssertEqual(edited["completed"], .bool(false)); XCTAssertEqual(edited["completed_at"], .null)
        let restored = try TaskKind.setting(edited, heading: false); XCTAssertEqual(restored["is_heading"], .bool(false)); XCTAssertEqual(restored["opaque"], original["opaque"])
    }
    func testDraftChoiceRejectsCompletedAndUnsupportedKindsWithoutChangingSource() throws {
        var original = task(); original["completed"] = .bool(true)
        XCTAssertThrowsError(try TaskKind.setting(original, heading: true)); XCTAssertTrue(original.completed); XCTAssertEqual(original["is_heading"], .null)
        original["is_heading"] = .number(1); XCTAssertThrowsError(try TaskKind.setting(original, heading: false))
    }
    func testTypeEditAdmitsUnrelatedConcurrentDetailsButFencesCompletionCyclesAndReplacement() throws {
        let original = task(), edited = try TaskKind.setting(original, heading: true)
        var current = original; current["description"] = .string("Other device notes"); current["due_date"] = .string("2026-10-30")
        XCTAssertNoThrow(try TaskKind.validateTypeEdit(original: original, edited: edited, current: current))
        current["completion_version"] = .number(2)
        XCTAssertThrowsError(try TaskKind.validateTypeEdit(original: original, edited: edited, current: current))
        current = original; current["is_heading"] = .bool(true)
        XCTAssertThrowsError(try TaskKind.validateTypeEdit(original: original, edited: edited, current: current))
        current = original; current["task_generation"] = .string(UUID().uuidString.lowercased())
        XCTAssertThrowsError(try TaskKind.validateTypeEdit(original: original, edited: edited, current: current))
    }
    func testMalformedCompletionTimestampsCannotCompareAsTwoMissingDates() throws {
        var original = task(); original["completed_at"] = .string("unsupported-old-value")
        let edited = try TaskKind.setting(original, heading: true)
        var current = original; current["completed_at"] = .string("unsupported-new-value")
        XCTAssertThrowsError(try TaskKind.validateTypeEdit(original: original, edited: edited, current: current))
    }
    func testEmbeddedTypeEditMergesCurrentNotesAndKeepsOrdinaryDescendants() throws {
        var original = task(); let leaf = task(); original["subtasks"] = .array([.object(leaf.fields)])
        let edited = try TaskKind.setting(original, heading: true)
        var current = original; current["description"] = .string("Concurrent notes")
        let result = try SubtaskTree.detailChanges(original: original, edited: edited, current: current)
        XCTAssertEqual(result["is_heading"], .bool(true)); XCTAssertEqual(result["description"], current["description"]); XCTAssertEqual(result["subtasks"], original["subtasks"])
        var completed = current; completed["completed"] = .bool(true)
        XCTAssertThrowsError(try SubtaskTree.detailChanges(original: original, edited: edited, current: completed))
    }
    func testHierarchyDetailChoiceWritesOnlyTheExistingRootAndKeepsTheChildIdentity() throws {
        let workspace = WorkspaceBinding(account: "owner", generation: UUID())
        var root = task(); let child = task(); root["subtasks"] = .array([.object(child.fields)])
        let index = try TaskHierarchyIndex(roots: [root], projects: [], workspace: workspace)
        let item = try XCTUnwrap(index.items.first { $0.isSubtask }), selected = try XCTUnwrap(index.selection(item.id))
        let draft = try TaskKind.setting(selected.item.record, heading: true)
        let changes = try TaskHierarchyIndex.changes([.editing(selected, draft: draft)], accessibleRoots: [root], projects: [], workspace: workspace)
        XCTAssertEqual(changes.count, 1); XCTAssertEqual(changes[0].recordID, root.id)
        let saved = changes[0].fields["subtasks"]!.list[0].object
        XCTAssertEqual(saved["id"], .string(child.id)); XCTAssertEqual(saved["is_heading"], .bool(true)); XCTAssertTrue(TaskKind.permits(changes[0], existing: root))
    }
    func testProductiveProjectionExcludesHeadingsWhileAppQueriesRetainDatedContext() throws {
        let now = Date(); var ordinary = task(), header = heading(), unsupported = task()
        for row in [ordinary, header] { XCTAssertFalse(row.completed) }
        ordinary["due_date"] = .string(Dates.day(now)); ordinary["duration_minutes"] = .number(20)
        header["due_date"] = ordinary["due_date"]; header["duration_minutes"] = .number(300)
        unsupported["is_heading"] = .string("future")
        let rows = [ordinary, header, unsupported]
        let payload = WidgetProjection.payload(tasks: rows, projects: [], account: "owner", now: now)
        XCTAssertEqual(payload["tasks"]?.list.map { $0.object["id"] }, [.string(ordinary.id)])
        XCTAssertTrue(InboxReviewRequest.eligible(ordinary)); XCTAssertFalse(InboxReviewRequest.eligible(header)); XCTAssertFalse(InboxReviewRequest.eligible(unsupported))
        let capacity = TaskPlanner.capacity(rows, events: [], on: now, hours: WorkingHours())
        XCTAssertEqual(capacity.estimatedMinutes, 20); XCTAssertEqual(capacity.unknownTasks, 0)
        let catalog = FocusTaskCatalog(tasks: rows, projects: [], sections: [])
        XCTAssertEqual(catalog.choices.map(\.id), [ordinary.id.lowercased()])
        var converted = ordinary; converted["is_heading"] = .bool(true)
        XCTAssertFalse(FocusTaskCatalog.selectable(try XCTUnwrap(catalog.choices.first), tasks: [converted]))
        let cache = TaskCache(); cache.update(rows)
        XCTAssertTrue(cache.matching(TaskQuery(scope: .today)).contains { $0.id == header.id })
    }
    func testProjectCurrentProgressDoesNotTreatHeadingsAsUnfinishedWork() {
        let project = UUID().uuidString.lowercased(); var header = heading(), done = task(), ordinary = task()
        for key in ["project_id"] { header[key] = .string(project); done[key] = .string(project); ordinary[key] = .string(project) }
        done["completed"] = .bool(true)
        let reading = ProjectPulseReading(project: project, tasks: [header, done, ordinary], activity: [])
        XCTAssertEqual(reading.total, 2); XCTAssertEqual(reading.completed, 1)
    }
}


extension TaskKindTests {
    func testCompoundPinnedHeadingEditKeepsItsCapturedCompletionFence() throws {
        let original = task(), edited = try TaskKind.setting(original, heading: true)
        let command = try XCTUnwrap(PinnedNotes.edit(edited, existing: original, baseline: original))
        XCTAssertNoThrow(try TaskKind.validateCapturedTypeEdit(command, existing: original))
        var current = original; current["completion_version"] = .number(2)
        XCTAssertThrowsError(try TaskKind.validateCapturedTypeEdit(command, existing: current))
        var incomplete = command; incomplete.baseline?.removeValue(forKey: "completed_at")
        XCTAssertThrowsError(try TaskKind.validateCapturedTypeEdit(incomplete, existing: original))
        let metadata = patch(original, ["description": .string("Unrelated notes")])
        XCTAssertNoThrow(try TaskKind.validateCapturedTypeEdit(metadata, existing: current))
    }
}


extension TaskKindTests {
    func testUnknownAndNonFiniteRevisionCannotAuthorizeTypeEditing() throws {
        for version: JSON in [.string("0"), .number(-1), .number(0.5), .number(.infinity), .number(.nan), .number(9_007_199_254_740_991)] {
            var original = task(); original["completion_version"] = version
            let edited = try TaskKind.setting(original, heading: true)
            XCTAssertThrowsError(try TaskKind.validateTypeEdit(original: original, edited: edited, current: original))
        }
    }
}


extension TaskKindTests {
    func testUnavailableCompletionNeverPromotesDeletionToFullSwipe() {
        var ordinary = task(); let heading = heading()
        XCTAssertTrue(RowGestureAction.complete.permitsFullSwipe(for: ordinary))
        XCTAssertFalse(RowGestureAction.complete.permitsFullSwipe(for: heading))
        XCTAssertTrue(RowGestureAction.tomorrow.permitsFullSwipe(for: heading))
        ordinary["completed"] = .bool(true)
        XCTAssertTrue(RowGestureAction.complete.permitsFullSwipe(for: ordinary))
        XCTAssertFalse(RowGestureAction.tomorrow.permitsFullSwipe(for: ordinary))
        XCTAssertFalse(RowGestureAction.edit.permitsFullSwipe(for: heading))
        XCTAssertFalse(RowGestureAction.none.permitsFullSwipe(for: heading))
        var unknown = ordinary; unknown["is_heading"] = .string("future")
        XCTAssertFalse(RowGestureAction.complete.permitsFullSwipe(for: unknown))
    }
}


final class TodoistHeadingConversionTests: XCTestCase {
    func imported(_ title: String = "* Plan tomorrow #work p1") -> Record {
        var row = Record.task(user: "synthetic-user")
        row["title"] = .string(title)
        row["source_metadata"] = .object(["provider": .string("todoist"), "account": .string("synthetic-account"), "original": .object(["content": .string("* Plan tomorrow #work p1"), "id": .string("synthetic-source")])])
        return row
    }
    func testOnlyKnownImportEvidenceOffersReview() {
        var row = imported(); XCTAssertNotNil(TodoistHeadingConversion(row))
        row["source_metadata"] = .null; XCTAssertNil(TodoistHeadingConversion(row))
        row = imported(); row["source_metadata"] = .object(["provider": .string("other"), "original": .object(["content": .string(row.title)])]); XCTAssertNil(TodoistHeadingConversion(row))
        for value in [JSON.string("ordinary"), .string("* "), .string("* \n"), .number(4), .null] {
            row = imported(); row["source_metadata"] = .object(["provider": .string("todoist"), "original": .object(["content": value])]); XCTAssertNil(TodoistHeadingConversion(row))
        }
    }
    func testReviewDoesNotMutateAndApplyChangesOnlyTypeAndReviewedTitle() throws {
        var row = imported(); row["description"] = .string("Full notes"); row["opaque"] = .object(["future": .bool(true)])
        row["subtasks"] = .array([.object(["id": .string("child"), "title": .string("Work"), "completed": .bool(false)])])
        row["attachments"] = .array([.object(["name": .string("brief.pdf")])]); row["comments"] = .array([.string("Keep")])
        row["is_recurring"] = .bool(true); row["recurrence_pattern"] = .object(["type": .string("daily")]); row["due_date"] = .string("2026-10-27")
        let before = row, review = try XCTUnwrap(TodoistHeadingConversion(row))
        XCTAssertTrue(review.removeMarkerByDefault); XCTAssertEqual(row, before)
        let edited = try review.applying(to: row, removingMarker: true, authoringEnabled: true)
        XCTAssertEqual(edited.title, "Plan tomorrow #work p1"); XCTAssertEqual(TaskKind(edited), .heading)
        for (key, value) in row.fields where !["title", "is_heading"].contains(key) { XCTAssertEqual(edited[key], value, key) }
        XCTAssertEqual(row, before); XCTAssertTrue(TaskCompletion.complete(edited, tasks: [edited]).isEmpty)
        XCTAssertTrue(TaskKind.permits(Mutation(table: "tasks", recordID: row.id, method: "PATCH", fields: ["title": edited["title"], "is_heading": .bool(true)]), existing: row))
    }
    func testLiteralMarkerCanBeKeptAndOnlyOneMarkerIsRemoved() throws {
        let row = imported("* * Keep the second marker"), review = try XCTUnwrap(TodoistHeadingConversion(row))
        XCTAssertFalse(review.removeMarkerByDefault)
        XCTAssertEqual(try review.applying(to: row, removingMarker: false, authoringEnabled: true).title, row.title)
        XCTAssertEqual(try review.applying(to: row, removingMarker: true, authoringEnabled: true).title, "* Keep the second marker")
    }
    func testEditedTitleIsNeverReplacedBySourceTitle() throws {
        let row = imported("My current wording"), review = try XCTUnwrap(TodoistHeadingConversion(row))
        XCTAssertFalse(review.canRemoveMarker); XCTAssertFalse(review.removeMarkerByDefault)
        XCTAssertEqual(try review.applying(to: row, removingMarker: false, authoringEnabled: true).title, row.title)
        XCTAssertThrowsError(try review.applying(to: row, removingMarker: true, authoringEnabled: true))
    }
    func testCompletedUnsupportedAndInvalidStateNeedExplicitRecoveryFirst() {
        for pair in [("completed", JSON.bool(true)), ("completed", .string("false")), ("completed_at", .string("2026-10-25T12:00:00Z")), ("is_heading", .bool(true)), ("is_heading", .string("future")), ("title", .string(""))] {
            var row = imported(); row[pair.0] = pair.1; XCTAssertNil(TodoistHeadingConversion(row), pair.0)
        }
    }
    func testWholeDraftAndCapabilityAreRechecked() throws {
        let row = imported(), review = try XCTUnwrap(TodoistHeadingConversion(row))
        XCTAssertThrowsError(try review.applying(to: row, removingMarker: true, authoringEnabled: false))
        for pair in [("title", JSON.string("Changed")), ("completed", .bool(true)), ("completion_version", .number(8)), ("task_generation", .string("replaced")), ("description", .string("New work")), ("source_metadata", .null)] {
            var changed = row; changed[pair.0] = pair.1
            XCTAssertThrowsError(try review.applying(to: changed, removingMarker: true, authoringEnabled: true), pair.0)
        }
    }
    func testReviewedLiteralTitleDoesNotCreateQuickEntryEdits() throws {
        let row = imported(), review = try XCTUnwrap(TodoistHeadingConversion(row))
        let edited = try review.applying(to: row, removingMarker: true, authoringEnabled: true)
        let parsed = QuickEntry(edited.title, disabled: Set(QuickEntry.groups), task: edited)
        XCTAssertEqual(parsed.title, edited.title); XCTAssertTrue(parsed.updates.isEmpty)
    }
}
