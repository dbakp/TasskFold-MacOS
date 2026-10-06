import XCTest
@testable import TaskfoldCore
@testable import WidgetModel

final class InboxReviewTests: XCTestCase {
    private let account = "owner"
    private var binding: WorkspaceBinding { WorkspaceBinding(account: account, generation: UUID()) }
    private func task(_ id: String, project: String = "", done: Bool = false, priority: Int = 4, date: String = "") -> Record {
        var row = Record.task(user: account); row["id"] = .string(id); row["title"] = .string(id)
        row["project_id"] = project.isEmpty ? .null : .string(project); row["completed"] = .bool(done)
        row["priority"] = .number(Double(priority)); row["due_date"] = date.isEmpty ? .null : .string(date)
        return row
    }
    private func snapshot(_ rows: [Record], account: String = "owner") throws -> WidgetSnapshot {
        try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(WidgetProjection.payload(tasks: rows, projects: [], account: account)))
    }
    func testInboxMembershipIncludesPlannedFutureAndUndatedButNeverProjectsOrCompleted() {
        let rows = [task("undated"), task("past", date: "2026-01-01"), task("future", date: "2030-01-01"), task("done", done: true), task("gone-project", project: "missing-project")]
        let cache = TaskCache(); cache.update(rows)
        let request = InboxReviewRequest(workspace: binding, tasks: cache.tasks, batch: .all)
        XCTAssertEqual(Set(request.ids), Set(cache.matching(TaskQuery(scope: .inbox)).map(\.id)))
        XCTAssertEqual(Set(request.ids), ["undated", "past", "future"])
    }
    func testBatchSelectionAndManualPriorityBandsAreIndependent() {
        let rows = (0..<12).map { task("row-\($0)", priority: $0 == 11 ? 1 : 4) }
        let owner = binding, order = rows.reversed().map(\.id)
        let five = InboxReviewRequest(workspace: owner, tasks: rows, batch: .five, order: order)
        let ten = InboxReviewRequest(workspace: owner, tasks: rows, batch: .ten, order: order)
        let all = InboxReviewRequest(workspace: owner, tasks: rows, batch: .all, order: order)
        XCTAssertEqual(five.ids, ["row-11", "row-10", "row-9", "row-8", "row-7"])
        XCTAssertEqual(ten.ids.count, 10); XCTAssertEqual(all.ids.count, 12)
        XCTAssertEqual(five.batch, .five); XCTAssertEqual(ten.batch, .ten); XCTAssertEqual(all.batch, .all)
        XCTAssertEqual(Array(ten.ids.prefix(5)), five.ids); XCTAssertNotEqual(five.id, ten.id)
    }
    func testNextBatchSkipsKeptCardsAndIncludesNewArrivalsWithoutChangingTheChosenLimit() {
        let scope = binding, rows = (0..<12).map { task("row-\($0)") }
        let first = InboxReviewRequest(workspace: scope, tasks: rows, batch: .five)
        let reviewed = Set(first.ids)
        let next = InboxReviewRequest(workspace: scope, tasks: rows + [task("new-arrival")], batch: first.batch, excluding: reviewed)
        XCTAssertEqual(next.ids, (5..<10).map { "row-\($0)" }); XCTAssertEqual(next.batch, .five)
        let last = InboxReviewRequest(workspace: scope, tasks: rows + [task("new-arrival")], batch: next.batch, excluding: reviewed.union(next.ids))
        XCTAssertEqual(last.ids, ["row-10", "row-11", "new-arrival"])
        XCTAssertEqual(InboxReviewRequest(workspace: scope, tasks: rows, batch: .all, excluding: Set(rows.map(\.id))).ids, [])
    }
    func testLiveRowsReplaceCapturedCardsWithoutResurrectingRemovedMovedCompletedOrNewWork() {
        let rows = [task("first"), task("removed"), task("moved"), task("completed"), task("kept")]
        let request = InboxReviewRequest(workspace: binding, tasks: rows, batch: .all)
        var first = rows[0]; first["title"] = .string("Latest shared title")
        let live = [first, task("moved", project: "project"), task("completed", done: true), rows[4], task("new-arrival")]
        let remaining = request.remaining(tasks: live, decisions: ["kept": .kept])
        XCTAssertEqual(remaining.map(\.id), ["first"]); XCTAssertEqual(remaining.first?.title, "Latest shared title")
        XCTAssertEqual(request.ids.count, 5)
        XCTAssertEqual(request.remaining(tasks: [], decisions: [:]).count, 0)
    }
    func testWorkspaceBindingRejectsOtherAccountAndSameAccountNewIncarnation() {
        let scope = binding
        XCTAssertTrue(scope.matches(account: account, generation: scope.generation))
        XCTAssertFalse(scope.matches(account: "other", generation: scope.generation))
        XCTAssertFalse(scope.matches(account: account, generation: UUID()))
        XCTAssertFalse(WorkspaceBinding(account: "", generation: scope.generation).matches(account: "", generation: scope.generation))
    }
    func testActionableCardsUseLatestContentsAndRejectObservedCompletionCyclesAndWorkspaceChanges() {
        let scope = binding, original = task("one")
        let request = InboxReviewRequest(workspace: scope, tasks: [original])
        var edited = original; edited["description"] = .string("Shared independent edit")
        XCTAssertEqual(request.actionable(original, tasks: [edited], account: account, generation: scope.generation)?.string("description"), "Shared independent edit")
        edited["completion_version"] = .number(2)
        XCTAssertNil(request.actionable(original, tasks: [edited], account: account, generation: scope.generation))
        XCTAssertNil(request.actionable(original, tasks: [original], account: account, generation: UUID()))
        XCTAssertNil(request.actionable(original, tasks: [], account: account, generation: scope.generation))
    }
    func testMoveUsesDurableContractPreservingPlansDeadlinesRemindersAndNotesAndUndo() throws {
        var row = task("move", date: "2026-10-25")
        row["due_time"] = .string("02:30"); row["time_zone"] = .string("Europe/Copenhagen"); row["scheduled_at"] = .string("2026-10-25T01:30:00Z")
        row["deadline_date"] = .string("2026-10-27"); row["duration_minutes"] = .number(45)
        row["description"] = .string("Keep these instructions")
        row["reminder_specs"] = .array([.object(["id": .string("reminder"), "kind": .string("relative"), "anchor": .string("due"), "offset_minutes": .number(-30)])])
        row["subtasks"] = .array([.object(["id": .string("child"), "title": .string("Child"), "assigned_to": .string("old-member")])])
        let move = InboxReviewRequest.move(row, to: "project")
        XCTAssertEqual(Set(move.fields.keys), ["project_id", "section_id"])
        let changes = TaskAssignment.mutations(move, existing: row).map { change -> Mutation in
            var value = change; value.fields = TaskPlanning.fields(value.fields, existing: row); return value
        }
        let original = Snapshot(tables: ["tasks": [row]]), history = EditHistory(changes: changes, snapshot: original)
        var changed = original
        for change in changes { changed.apply(change); changed.pending.append(change) }
        let saved = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(changed))
        let after = try XCTUnwrap(saved.tables["tasks"]?.first)
        XCTAssertEqual(after.string("project_id"), "project"); XCTAssertEqual(after["subtasks"].list.first?.object["assigned_to"], .null)
        for key in ["due_date", "due_time", "time_zone", "scheduled_at", "deadline_date", "duration_minutes", "description", "reminder_specs"] { XCTAssertEqual(after[key], row[key], key) }
        XCTAssertEqual(saved.pending.map(\.recordID), [row.id])
        for inverse in history.undo { changed.apply(inverse) }
        let undone = try XCTUnwrap(changed.tables["tasks"]?.first)
        for key in Set(undone.fields.keys).union(row.fields.keys) { XCTAssertEqual(undone[key], row[key], key) }
    }
    func testKeepAndCompletedDecisionsDoNotInventDatesOrReplayNewRecurringSuccessors() {
        var recurring = task("series", date: "2026-10-06"); recurring["is_recurring"] = .bool(true); recurring["recurrence_pattern"] = .object(["type": .string("daily")])
        let original = Snapshot(tables: ["tasks": [recurring]])
        let request = InboxReviewRequest(workspace: binding, tasks: [recurring], batch: .all)
        XCTAssertEqual(request.remaining(tasks: [recurring], decisions: [recurring.id: .kept]).count, 0)
        XCTAssertEqual(original.tables["tasks"]?.first?.string("due_date"), "2026-10-06")
        var completed = original
        for mutation in TaskCompletion.toggle(recurring, tasks: [recurring]) { completed.apply(mutation) }
        XCTAssertEqual(request.remaining(tasks: completed.tables["tasks"] ?? [], decisions: [recurring.id: .completed]).count, 0)
        XCTAssertEqual((completed.tables["tasks"] ?? []).filter(InboxReviewRequest.eligible).count, 1, "The next recurring occurrence remains in Inbox, outside the captured batch")
    }
    func testWidgetCountMatchesNativeInboxAcrossProjectMetadataAndFutureDates() throws {
        let rows = [task("priority", priority: 1), task("future", date: "2030-01-01"), task("done", done: true), task("project", project: "deleted-project")]
        let reading = try snapshot(rows).inboxReading()
        XCTAssertEqual(reading.count, 2); XCTAssertEqual(reading.undated, 1); XCTAssertEqual(reading.priorities, 1)
        let request = InboxReviewRequest(workspace: binding, tasks: rows, batch: .all)
        XCTAssertEqual(Set(reading.tasks?.map(\.id) ?? []), Set(request.ids))
        XCTAssertEqual(try snapshot([]).inboxReading().count, 0)
        XCTAssertEqual(try snapshot([]).inboxReviewURL(batch: .all).absoluteString, "taskfold://inbox")
        XCTAssertEqual(InboxReviewLink.parse(try snapshot(rows).inboxReviewURL(batch: .ten))?.batch, .ten)
    }
    func testLegacySignedOutMissingScopeInvalidIdentityAndClockNeverClaimEmptyInbox() throws {
        let normal = try snapshot([task("one")])
        var legacy = normal; legacy.version = 1
        var noScope = normal; noScope.tasks[0].projectID = nil
        var badID = normal; badID.tasks[0].id = ""
        var badClock = normal; badClock.updated = .infinity
        for value in [legacy, noScope, badID, badClock, try snapshot([], account: "")] { XCTAssertNil(value.inboxReading().count) }
    }
    func testDuplicateIDsUseFirstLiveIdentityConsistently() throws {
        let rows = [task("one", project: "project"), task("one"), task("two"), task("two")]
        let request = InboxReviewRequest(workspace: binding, tasks: rows, batch: .all)
        XCTAssertEqual(request.ids, ["two"])
        XCTAssertEqual(try snapshot(rows).inboxReading().tasks?.map(\.id), ["two"])
    }
    func testWidgetReviewLinksRoundTripBatchAccountEscapingAndRejectMalformedRoutes() throws {
        let owner = "a b/?#% &ø"
        for batch in InboxWidgetBatch.allCases {
            let link = WidgetLinks.inboxReview(account: owner, batch: batch)
            XCTAssertEqual(InboxReviewLink.parse(link), InboxReviewLink(account: owner, batch: InboxReviewBatch(rawValue: batch.rawValue)!))
        }
        XCTAssertEqual(WidgetLinks.inboxReview(account: "", batch: .all).absoluteString, "taskfold://inbox")
        for value in ["taskfold://review/inbox", "https://review/inbox?account=owner&batch=5", "taskfold://review/inbox?account=&batch=5", "taskfold://review/inbox?account=owner&batch=0", "taskfold://review/inbox?account=owner&account=other&batch=5", "taskfold://review/inbox?account=owner&batch=5&extra=yes", "taskfold://review/inbox/extra?account=owner&batch=5", "taskfold://review/inbox?account=owner&batch=5#fragment"] {
            XCTAssertNil(InboxReviewLink.parse(try XCTUnwrap(URL(string: value))), value)
        }
    }
}
