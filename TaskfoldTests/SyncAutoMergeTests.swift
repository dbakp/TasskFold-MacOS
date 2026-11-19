import XCTest
@testable import TaskfoldCore

/// Latest edit wins: conflicts rebase on the synced row and retry without a review.
final class SyncAutoMergeTests: XCTestCase {
    private let id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private func task(title: String = "Original", notes: String = "Original notes") -> Record {
        Record(["id": .string(id), "user_id": .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), "title": .string(title),
                "description": .string(notes), "completed": .bool(false), "completion_version": .number(0),
                "task_generation": .string("dddddddd-dddd-4ddd-8ddd-dddddddddddd")])
    }
    private func edit(_ fields: [String: JSON], from original: Record) -> Mutation {
        Mutation(table: "tasks", recordID: original.id, method: "PATCH", fields: fields, baseline: TaskCompletionRevision.editBaseline(for: fields, from: original))
    }
    private func queued(_ original: Record, _ changes: [Mutation]) -> Snapshot {
        var snapshot = Snapshot(tables: ["tasks": [original]], pending: changes)
        for change in changes { snapshot.apply(change) }
        return snapshot
    }

    func testDisjointFieldsMergeAndRebaseTheGuard() throws {
        let original = task(), mine = edit(["title": .string("My title")], from: original)
        let remote = task(notes: "Notes from the other device")
        let plan = try XCTUnwrap(SyncAutoMerge.resolving(SyncConflict(mutation: mine, remote: remote), snapshot: queued(original, [mine]), attempts: 0))
        XCTAssertEqual(plan.outcome, .rebased)
        XCTAssertEqual(plan.snapshot.pending.count, 1)
        XCTAssertEqual(plan.snapshot.pending[0].fields["title"], .string("My title"))
        XCTAssertEqual(plan.snapshot.pending[0].baseline?["title"], remote["title"], "The retry is guarded by the synced value, so the server accepts it")
        XCTAssertNil(plan.snapshot.pending[0].fields["description"], "Fields this device did not change are never sent")
        let row = try XCTUnwrap(plan.snapshot.tables["tasks"]?.first)
        XCTAssertEqual(row.title, "My title"); XCTAssertEqual(row.string("description"), "Notes from the other device")
        XCTAssertFalse(SyncAutoMerge.discards(SyncConflict(mutation: mine, remote: remote), outcome: plan.outcome))
    }

    func testSameFieldTakesTheEditSentLast() throws {
        let original = task(), mine = edit(["title": .string("Mine")], from: original)
        let remote = task(title: "Theirs")
        let plan = try XCTUnwrap(SyncAutoMerge.resolving(SyncConflict(mutation: mine, remote: remote), snapshot: queued(original, [mine]), attempts: 1))
        XCTAssertEqual(plan.outcome, .rebased)
        XCTAssertEqual(plan.snapshot.pending[0].fields["title"], .string("Mine"))
        XCTAssertEqual(plan.snapshot.pending[0].baseline?["title"], .string("Theirs"))
        XCTAssertEqual(plan.snapshot.tables["tasks"]?.first?.title, "Mine")
    }

    func testLaterQueuedEditsReplayAfterTheRebase() throws {
        let original = task(), first = edit(["title": .string("Mine")], from: original)
        var afterFirst = original; afterFirst["title"] = .string("Mine")
        let later = edit(["description": .string("Later offline notes")], from: afterFirst)
        let remote = task(title: "Theirs")
        let plan = try XCTUnwrap(SyncAutoMerge.resolving(SyncConflict(mutation: first, remote: remote), snapshot: queued(original, [first, later]), attempts: 0))
        XCTAssertEqual(plan.snapshot.pending.count, 2); XCTAssertEqual(plan.snapshot.pending[1], later)
        let row = try XCTUnwrap(plan.snapshot.tables["tasks"]?.first)
        XCTAssertEqual(row.title, "Mine"); XCTAssertEqual(row.string("description"), "Later offline notes")
    }

    func testDeletionWinsOverAConcurrentEditAndIsBackedUp() throws {
        let original = task(), deletion = Mutation(table: "tasks", recordID: original.id, method: "DELETE", fields: [:], baseline: original.fields)
        let remote = task(title: "Edited elsewhere", notes: "Edited notes")
        let conflict = SyncConflict(mutation: deletion, remote: remote)
        let plan = try XCTUnwrap(SyncAutoMerge.resolving(conflict, snapshot: Snapshot(tables: ["tasks": []], pending: [deletion]), attempts: 0))
        XCTAssertEqual(plan.outcome, .rebased)
        XCTAssertEqual(plan.snapshot.pending.count, 1); XCTAssertEqual(plan.snapshot.pending[0].method, "DELETE")
        XCTAssertEqual(plan.snapshot.pending[0].baseline, remote.fields, "The retry deletes the version the other device saved")
        XCTAssertEqual(plan.snapshot.tables["tasks"] ?? [], [])
        XCTAssertTrue(SyncAutoMerge.discards(conflict, outcome: plan.outcome), "The edited contents are copied to Backups & restore first")
    }

    func testEditToATaskDeletedElsewhereNeverRecreatesIt() {
        let original = task(), mine = edit(["title": .string("Mine")], from: original)
        let other = Mutation(table: "tasks", recordID: "other", method: "PATCH", fields: ["completed": .bool(true)])
        let next = SyncAutoMerge.droppingEdits(toDeletedTask: original.id.uppercased(), in: queued(original, [mine, other]))
        XCTAssertEqual(next.pending, [other])
        XCTAssertFalse(next.tables["tasks"]?.contains { $0.id == original.id } ?? false)
    }

    func testUndoOfADeleteStillRestoresAfterTheDeletionWins() {
        let original = task(), stale = edit(["title": .string("Mine")], from: original)
        let restore = Mutation(table: "tasks", recordID: original.id, method: "POST", fields: original.fields, insertOnly: true)
        var restored = original; restored["title"] = .string("Restored")
        let after = edit(["title": .string("After restore")], from: restored)
        let snapshot = Snapshot(tables: ["tasks": [original]], pending: [stale, restore, after])
        let next = SyncAutoMerge.droppingEdits(toDeletedTask: original.id, in: snapshot)
        XCTAssertEqual(next.pending, [restore, after])
        XCTAssertEqual(next.tables["tasks"]?.count, 1)
    }

    func testRepeatedConflictsFallBackToTheSyncedVersionSoSyncNeverStalls() throws {
        let original = task(), mine = edit(["title": .string("Mine")], from: original)
        let other = Mutation(table: "tasks", recordID: "other", method: "PATCH", fields: ["completed": .bool(true)])
        let remote = task(title: "Theirs")
        let conflict = SyncConflict(mutation: mine, remote: remote)
        let plan = try XCTUnwrap(SyncAutoMerge.resolving(conflict, snapshot: queued(original, [mine, other]), attempts: SyncAutoMerge.attemptLimit))
        XCTAssertEqual(plan.outcome, .keptSynced)
        XCTAssertEqual(plan.snapshot.pending, [other])
        XCTAssertEqual(plan.snapshot.tables["tasks"]?.first { $0.id == original.id }?.title, "Theirs")
        XCTAssertTrue(SyncAutoMerge.discards(conflict, outcome: plan.outcome))
    }

    func testRetryBudgetIsPerRowNotPerRequest() {
        let a = Mutation(table: "tasks", recordID: id.uppercased(), method: "PATCH", fields: [:])
        let b = Mutation(table: "tasks", recordID: id, method: "PATCH", fields: ["title": .string("x")])
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(SyncAutoMerge.key(a), SyncAutoMerge.key(b))
        XCTAssertNotEqual(SyncAutoMerge.key(a), SyncAutoMerge.key(Mutation(table: "projects", recordID: id, method: "PATCH", fields: [:])))
    }
}

extension FocusSessionTests {
    func testAutoMergeKeepsThisDevicesNewerFocusSession() throws {
        let first = try FocusSessionChange.make(session(), current: nil, account: account)
        let last = try FocusSessionChange.make(session().paused(at: start.addingTimeInterval(30)), current: Record(first.fields), account: account)
        let edit = Mutation(table: "tasks", recordID: taskID, method: "PATCH", fields: ["description": .string("Later work")])
        let remote = try row(session(minutes: 45))
        let original = Snapshot(tables: [FocusSessionChange.table: [Record(last.fields)]], pending: [first, edit, last])
        let plan = try XCTUnwrap(SyncAutoMerge.resolving(FocusSyncConflict(mutation: first, remote: remote), snapshot: original, account: account, attempts: 0))
        XCTAssertEqual(plan.outcome, .rebased)
        let rebased = try XCTUnwrap(plan.snapshot.pending.first { $0.table == FocusSessionChange.table })
        XCTAssertEqual(rebased.fields["state"], last.fields["state"]); XCTAssertEqual(rebased.baseline, FocusSessionChange.baseline(remote))
        XCTAssertTrue(plan.snapshot.pending.contains(edit))
    }
    func testAutoMergeFocusFallsBackToSyncedAfterRepeatedConflicts() throws {
        let first = try FocusSessionChange.make(session(), current: nil, account: account)
        let remote = try row(session(minutes: 45))
        let original = Snapshot(tables: [FocusSessionChange.table: [Record(first.fields)]], pending: [first])
        let plan = try XCTUnwrap(SyncAutoMerge.resolving(FocusSyncConflict(mutation: first, remote: remote), snapshot: original, account: account, attempts: SyncAutoMerge.attemptLimit))
        XCTAssertEqual(plan.outcome, .keptSynced); XCTAssertTrue(plan.snapshot.pending.isEmpty)
        XCTAssertEqual(plan.snapshot.tables[FocusSessionChange.table], [remote])
    }
}

extension ProjectWorkflowsTests {
    func testAutoMergeTemplateEditKeepsIndependentRemoteName() throws {
        let original = try templateRow(); var remote = original; remote["name"] = .string("Remote name")
        let item = TemplateEditing.tasks(original["document"]).first!
        let document = try TemplateEditing.changing(original["document"], item: item, fields: ["title": .string("Local definition")])
        let change = Mutation(table: WorkflowTemplate.table, recordID: original.id, method: "PATCH", fields: ["document": document], baseline: original.fields)
        var snapshot = Snapshot(tables: [WorkflowTemplate.table: [original]], pending: [change]); snapshot.apply(change)
        let plan = try XCTUnwrap(SyncAutoMerge.resolving(SyncConflict(mutation: change, remote: remote), snapshot: snapshot, attempts: 0))
        XCTAssertEqual(plan.outcome, .rebased)
        XCTAssertEqual(plan.snapshot.tables[WorkflowTemplate.table]?.first?.name, "Remote name")
        XCTAssertEqual(plan.snapshot.tables[WorkflowTemplate.table]?.first?["document"], document)
        XCTAssertEqual(plan.snapshot.pending.first?.baseline, remote.fields)
    }
    func testAutoMergeNeverResurrectsATemplateRemovedElsewhere() throws {
        let row = try templateRow(), change = Mutation(table: WorkflowTemplate.table, recordID: row.id, method: "PATCH", fields: ["name": .string("Edited")], baseline: row.fields)
        let missing = Record(["id": .string(row.id), "name": .string("Deleted template")])
        let conflict = SyncConflict(mutation: change, remote: missing)
        let plan = try XCTUnwrap(SyncAutoMerge.resolving(conflict, snapshot: Snapshot(tables: [WorkflowTemplate.table: [row]], pending: [change]), attempts: 0))
        XCTAssertEqual(plan.outcome, .keptSynced)
        XCTAssertTrue(plan.snapshot.pending.isEmpty, "No new template is created from the stale edit")
        XCTAssertEqual(plan.snapshot.tables[WorkflowTemplate.table] ?? [], [])
        XCTAssertTrue(SyncAutoMerge.discards(conflict, outcome: plan.outcome))
    }
}
