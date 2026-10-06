import XCTest
@testable import TaskfoldCore

final class TaskGenerationTests: XCTestCase {
    let owner = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    func task() -> Record {
        var row = Record.task(user: owner)
        row["id"] = .string("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        row["title"] = .string("A restored task"); row["due_date"] = .string("2026-10-25")
        row["due_time"] = .string("09:00"); row["time_zone"] = .string("Europe/Copenhagen")
        return row
    }
    func testRestoredSameIDCannotAcceptOldReminderSnoozeOrWidgetTap() throws {
        let old = task(), event = try XCTUnwrap(DueReminder.events(tasks: [old]).first)
        var snapshot = Snapshot(tables: ["tasks": [old]]); WidgetCompletion.prepare(&snapshot)
        let token = try XCTUnwrap(WidgetCompletion.tokens(snapshot)[old.id])
        let tap = try WidgetCompletionRequest(account: owner, taskID: old.id, token: token)
        let restored = Record(TaskGeneration.restoring(Mutation(table: "tasks", recordID: old.id, method: "POST", fields: old.fields), existing: nil).fields)
        XCTAssertEqual(old.id, restored.id); XCTAssertNotEqual(old["task_generation"], restored["task_generation"])
        let current = try XCTUnwrap(DueReminder.events(tasks: [restored]).first)
        XCTAssertTrue(current.signature.hasPrefix("r4:")); XCTAssertNil(current.legacySignature)
        XCTAssertFalse(current.hasSignature(event.signature))
        let spec = ReminderSpec.relative(0, id: ReminderSpec.plannedID)
        XCTAssertFalse(current.hasSignature(ReminderSignature.legacy(task: old, spec: spec, date: event.date)))
        XCTAssertFalse(ReminderRequest.make(account: owner, event: event).valid(account: owner, events: [current]))
        snapshot.tables["tasks"] = [restored]; WidgetCompletion.prepare(&snapshot)
        guard case .stale = WidgetCompletion.plan(tap, snapshot: snapshot, account: owner) else { return XCTFail("Old widget tap completed restored work") }
    }
    func testBackupMissingTaskGetsFreshGenerationWhileExistingTaskKeepsItsIdentity() throws {
        let row = task(), backup = WorkspaceBackup.make( Snapshot(tables: ["tasks": [row]]), account: owner)
        let first = try backup.plan(current: Snapshot(), account: owner, policy: .backupValues)
        let second = try backup.plan(current: Snapshot(), account: owner, policy: .backupValues)
        let creation = try XCTUnwrap(first.changes.first { $0.table == "tasks" })
        XCTAssertEqual(creation.recordID, row.id); XCTAssertEqual(creation.insertOnly, true)
        XCTAssertNotEqual(creation.fields["task_generation"], row["task_generation"])
        XCTAssertNotEqual(creation.fields["task_generation"], second.changes.first { $0.table == "tasks" }?.fields["task_generation"])
        var current = row; current["title"] = .string("Newer title")
        let edits = try backup.plan(current: Snapshot(tables: ["tasks": [current]]), account: owner, policy: .backupValues)
        XCTAssertNil(edits.changes.first { $0.table == "tasks" }?.fields["task_generation"])
        let captured = TaskCompletionRevision.capturing(try XCTUnwrap(edits.changes.first { $0.table == "tasks" }), existing: current)
        XCTAssertEqual(captured.baseline?["task_generation"], current["task_generation"])
    }
    func testOldQueuedEditAndDeleteDoNotOverlayRecreatedRemoteWorkAfterRelaunch() throws {
        let old = task(); var remote = task(); remote["title"] = .string("Work from the other device")
        let edit = TaskCompletionRevision.capturing(Mutation(table: "tasks", recordID: old.id, method: "PATCH", fields: ["title": .string("Offline old title")]), existing: old)
        let deletion = Mutation(table: "tasks", recordID: old.id, method: "DELETE", fields: [:], baseline: old.fields)
        XCTAssertFalse(TaskGeneration.permitsLocalAction(edit, existing: remote))
        XCTAssertFalse(TaskGeneration.permitsLocalAction(deletion, existing: remote))
        XCTAssertTrue(TaskGeneration.permitsLocalAction(edit, existing: old))
        var snapshot = Snapshot(tables: ["tasks": [old]], pending: [edit, deletion])
        snapshot = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        snapshot.mergeRemote(["tasks": [remote]])
        XCTAssertEqual(snapshot.tables["tasks"], [remote]); XCTAssertEqual(snapshot.pending, [edit, deletion])
        var legacy = edit; legacy.baseline?.removeValue(forKey: "task_generation")
        var olderQueue = Snapshot(tables: ["tasks": [old]], pending: [legacy])
        olderQueue.mergeRemote(["tasks": [remote]])
        XCTAssertEqual(olderQueue.tables["tasks"], [remote]); XCTAssertEqual(olderQueue.pending, [legacy])

        let oldCache = Snapshot(tables: ["tasks": [old]], pending: [edit, deletion])
        let usingSynced = try XCTUnwrap(SyncConflict(mutation: edit, remote: remote).resolving(oldCache, keepLocal: false))
        XCTAssertEqual(usingSynced.tables["tasks"], [remote]); XCTAssertEqual(usingSynced.pending, [deletion])
        let review = try XCTUnwrap(SyncConflict(mutation: edit, remote: remote).resolving(oldCache, keepLocal: true))
        XCTAssertEqual(review.tables["tasks"]?.first?.title, "Offline old title")
        XCTAssertEqual(review.pending.first?.baseline?["task_generation"], remote["task_generation"])
        XCTAssertEqual(review.tables["tasks"]?.first?["task_generation"], remote["task_generation"])
    }
    func testNewCreationIdentitySurvivesQueueRetryAndImmutableEdits() throws {
        var fields = task().fields; fields.removeValue(forKey: "task_generation")
        let raw = Mutation(table: "tasks", recordID: fields["id"]!.text, method: "POST", fields: fields)
        let captured = TaskCompletionRevision.capturing(raw, existing: nil)
        XCTAssertEqual(captured, TaskCompletionRevision.capturing(raw, existing: nil))
        let queued = try JSONDecoder().decode(Mutation.self, from: JSONEncoder().encode(captured))
        XCTAssertEqual(queued, captured); XCTAssertEqual(queued.insertOnly, true)
        let row = Record(queued.fields)
        let edited = TaskCompletionRevision.applying(["task_generation": .string(UUID().uuidString), "title": .string("Rename")], to: row)
        XCTAssertEqual(edited["task_generation"], row["task_generation"])
        XCTAssertEqual(DueReminder.events(tasks: [edited]).first?.signature, DueReminder.events(tasks: [row]).first?.signature)
    }
    func testBackupRejectsMalformedOrReservedGenerations() throws {
        for invalid in [JSON.number(1), .string("wrong"), .string("00000000-0000-0000-0000-000000000000")] {
            var row = task(); row["task_generation"] = invalid
            let backup = WorkspaceBackup.make( Snapshot(tables: ["tasks": [row]]), account: owner)
            XCTAssertThrowsError(try WorkspaceBackup.read(backup.data()))
        }
    }
}
