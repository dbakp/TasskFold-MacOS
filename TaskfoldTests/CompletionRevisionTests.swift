import XCTest
@testable import TaskfoldCore

final class CompletionRevisionTests: XCTestCase {
    private let owner = "11111111-1111-4111-8111-111111111111"
    private let now = ISO8601DateFormatter().date(from: "2026-10-06T12:00:00Z")!
    private func root(version: Int = 0) -> Record {
        var task = Record.task(user: owner); task["id"] = .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        task["title"] = .string("Recurring review"); task["due_date"] = .string("2026-10-06")
        task["task_generation"] = .string("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")
        task["completed_at"] = .null; task["completion_version"] = .number(Double(version))
        task["is_recurring"] = .bool(true); task["recurrence_pattern"] = .object(["type": .string("daily"), "interval": .number(1)])
        return task
    }
    private func queued() -> (Snapshot, [Mutation]) {
        var snapshot = Snapshot(); let task = root(); snapshot.tables["tasks"] = [task]
        let changes = TaskCompletion.complete(task, tasks: [task], at: now)
        for change in changes { snapshot.apply(change); snapshot.pending.append(change) }
        return (snapshot, changes)
    }
    func testPredictionCanonicalizesInstantsAndNeverBumpsForUnrelatedOrConfirmedEdits() {
        var task = root(version: 4); task["completed"] = .bool(true); task["completed_at"] = .string("2026-10-06T12:00:00Z")
        XCTAssertEqual(TaskCompletionRevision.applying(["completed_at": .string("2026-10-06T14:00:00+02:00")], to: task)["completion_version"], .number(4))
        XCTAssertEqual(TaskCompletionRevision.applying(["title": .string("New title")], to: task)["completion_version"], .number(4))
        let reopened = TaskCompletionRevision.applying(["completed": .bool(false), "completed_at": .null], to: task)
        XCTAssertEqual(reopened["completion_version"], .number(5))
        XCTAssertEqual(TaskCompletionRevision.applying(["completed": .bool(false), "completed_at": .null, "completion_version": .number(8)], to: task)["completion_version"], .number(8))
    }
    func testCapturingPreservesExplicitStaleBaselineAndServerOwnedFieldCannotBecomeAnEdit() {
        let task = root(version: 8)
        var change = Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: ["completed": .bool(true), "completion_version": .number(0)])
        let captured = TaskCompletionRevision.capturing(change, existing: task)
        XCTAssertEqual(captured.baseline?["completion_version"], .number(8)); XCTAssertNil(captured.fields["completion_version"])
        change.baseline = ["completed": .bool(false), "completion_version": .number(4)]
        XCTAssertEqual(TaskCompletionRevision.capturing(change, existing: task).baseline?["completion_version"], .number(4))
        var legacy = task; legacy.fields.removeValue(forKey: "completion_version")
        change.baseline = nil
        XCTAssertEqual(TaskCompletionRevision.capturing(change, existing: legacy).baseline?["completion_version"], .number(0))
    }
    func testEditorBaselineKeepsOriginalRevisionAfterRemoteCompletionAndReopen() {
        let original = root(version: 0), refreshed = root(version: 2)
        let fields: [String: JSON] = ["completed": .bool(true), "completed_at": .string("2026-10-06T12:00:00Z")]
        let baseline = TaskCompletionRevision.editBaseline(for: fields, from: original)
        let edit = Mutation(table: "tasks", recordID: original.id, method: "PATCH", fields: fields, baseline: baseline)
        XCTAssertEqual(TaskCompletionRevision.capturing(edit, existing: refreshed).baseline?["completion_version"], .number(0))
        XCTAssertNil(TaskCompletionRevision.editBaseline(for: ["title": .string("New title")], from: original)["completion_version"])
        var legacy = original; legacy.fields.removeValue(forKey: "completion_version")
        XCTAssertEqual(TaskCompletionRevision.editBaseline(for: fields, from: legacy)["completion_version"], .number(0))
    }
    func testAcknowledgementReplaysLaterOfflineReopenWithoutDoubleIncrementAndSurvivesRelaunch() throws {
        var task = root(); task["is_recurring"] = .bool(false)
        var snapshot = Snapshot(); snapshot.tables["tasks"] = [task]
        let complete = try XCTUnwrap(TaskCompletion.complete(task, tasks: [task], at: now).first)
        snapshot.apply(complete); snapshot.pending.append(complete)
        let local = try XCTUnwrap(snapshot.tables["tasks"]?.first)
        let reopen = try XCTUnwrap(TaskCompletion.toggle(local, tasks: [local], at: now).first)
        XCTAssertEqual(reopen.baseline?["completion_version"], .number(1))
        snapshot.apply(reopen); snapshot.pending.append(reopen)
        var confirmed = TaskCompletionRevision.applying(complete.fields, to: task)
        confirmed["description"] = .string("Independent synced note")
        snapshot.acknowledge(complete, saved: confirmed)
        let relaunched = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(relaunched.pending, [reopen]); XCTAssertEqual(relaunched.tables["tasks"]?.first?.completed, false)
        XCTAssertEqual(relaunched.tables["tasks"]?.first?["completion_version"], .number(2))
        XCTAssertEqual(relaunched.tables["tasks"]?.first?.string("description"), "Independent synced note")
        var replay = Snapshot(); replay.pending = [complete, reopen]; replay.mergeRemote(["tasks": [confirmed]])
        XCTAssertEqual(replay.tables["tasks"]?.first?["completion_version"], .number(2))
    }
    func testCreateOnlyReplayNeverOverwritesAnExistingRemoteSuccessor() throws {
        let (original, changes) = queued(); let create = changes[1]
        var remote = Record(create.fields); remote["title"] = .string("Other device work"); remote["completion_version"] = .number(6)
        var snapshot = original; snapshot.mergeRemote(["tasks": [root(), remote]])
        XCTAssertEqual(snapshot.tables["tasks"]?.last?.title, "Other device work")
        XCTAssertEqual(snapshot.tables["tasks"]?.last?["completion_version"], .number(6))
        snapshot.acknowledge(create, saved: remote)
        XCTAssertEqual(snapshot.tables["tasks"]?.last?.title, "Other device work")
    }
    func testUseSyncedReopenedTaskCancelsOnlyTheUneditedUnacceptedOccurrence() throws {
        var (snapshot, changes) = queued(); var remote = root(version: 2); remote["description"] = .string("Synced notes")
        let other = Mutation(table: "tasks", recordID: "other", method: "POST", fields: ["id": .string("other"), "title": .string("Unrelated work")])
        snapshot.pending.append(other)
        let resolved = try XCTUnwrap(SyncConflict(mutation: changes[0], remote: remote).resolving(snapshot, keepLocal: false))
        XCTAssertEqual(resolved.pending, [other]); XCTAssertEqual(resolved.tables["tasks"]?.count, 1)
        XCTAssertEqual(resolved.tables["tasks"]?.first?.completed, false)
        XCTAssertEqual(resolved.tables["tasks"]?.first?["completion_version"], .number(2))
        XCTAssertEqual(resolved.tables["tasks"]?.first?.string("description"), "Synced notes")
    }
    func testUseSyncedPreservesEditedOccurrenceAsIndependentWorkWithFutureMetadataAndLaterQueue() throws {
        var (snapshot, changes) = queued(); var child = Record(changes[1].fields)
        var metadata = child["source_metadata"].object; metadata["future"] = .string("Keep me")
        child["source_metadata"] = .object(metadata)
        let edit = Mutation(table: "tasks", recordID: child.id, method: "PATCH", fields: ["title": .string("Keep my draft"), "source_metadata": child["source_metadata"]], baseline: ["task_generation": child["task_generation"], "title": changes[1].fields["title"]!, "source_metadata": changes[1].fields["source_metadata"]!])
        snapshot.apply(edit); snapshot.pending.append(edit)
        let resolved = try XCTUnwrap(SyncConflict(mutation: changes[0], remote: root(version: 2)).resolving(snapshot, keepLocal: false))
        let durable = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(resolved))
        XCTAssertEqual(durable.pending.count, 2); XCTAssertEqual(durable.pending[1].id, edit.id)
        XCTAssertEqual(durable.pending[0].fields["recurrence_parent_id"], .null)
        XCTAssertNil(durable.pending[0].fields["source_metadata"]?.object["taskfold_recurrence_v1"])
        XCTAssertEqual(durable.pending[1].fields["source_metadata"]?.object["future"], .string("Keep me"))
        XCTAssertEqual(durable.tables["tasks"]?.last?.title, "Keep my draft")
        XCTAssertEqual(durable.tables["tasks"]?.last?["recurrence_parent_id"], .null)
        XCTAssertEqual(durable.tables["tasks"]?.last?["source_metadata"].object["future"], .string("Keep me"))
    }
    func testKeepMyCompletionRebasesRevisionAndUseSyncedCancelsUnacceptedSuccessor() throws {
        let (snapshot, changes) = queued(); let remote = root(version: 2)
        let keep = try XCTUnwrap(SyncConflict(mutation: changes[0], remote: remote).resolving(snapshot, keepLocal: true))
        XCTAssertEqual(keep.pending[0].baseline?["completion_version"], .number(2))
        XCTAssertEqual(keep.tables["tasks"]?.first?["completion_version"], .number(3))
        XCTAssertEqual(keep.pending[1], changes[1])
        var done = remote; done["completed"] = .bool(true); done["completed_at"] = .string("2026-10-06T13:00:00Z")
        let use = try XCTUnwrap(SyncConflict(mutation: changes[0], remote: done).resolving(snapshot, keepLocal: false))
        XCTAssertTrue(use.pending.isEmpty)
    }
    func testRemoteUnseenCompletionCycleInvalidatesWidgetTokenEvenWhenVisibleStateMatches() throws {
        var snapshot = Snapshot(); snapshot.tables["tasks"] = [root()]; WidgetCompletion.prepare(&snapshot)
        let token = try XCTUnwrap(WidgetCompletion.tokens(snapshot)[root().id])
        let request = try WidgetCompletionRequest(account: owner, taskID: root().id, token: token)
        snapshot.mergeRemote(["tasks": [root(version: 2)]]); WidgetCompletion.prepare(&snapshot)
        XCTAssertNotEqual(WidgetCompletion.tokens(snapshot)[root().id], token)
        guard case .stale = WidgetCompletion.plan(request, snapshot: snapshot, account: owner) else { return XCTFail("Old tap survived unseen cycle") }
        let changes = TaskCompletion.complete(root(version: 7), tasks: [], at: now)
        XCTAssertEqual(changes[0].baseline?["completion_version"], .number(7)); XCTAssertEqual(changes[1].fields["completion_version"], .number(0))
    }
    func testKeepingCompletionRebasesLaterOfflineUndoRevisionsWhileKeepingStaleEditsForReview() throws {
        var (snapshot, changes) = queued()
        let local = try XCTUnwrap(snapshot.tables["tasks"]?.first)
        let undo = try XCTUnwrap(TaskCompletion.toggle(local, tasks: [local], at: now).first)
        snapshot.apply(undo); snapshot.pending.append(undo)
        let resolved = try XCTUnwrap(SyncConflict(mutation: changes[0], remote: root(version: 2)).resolving(snapshot, keepLocal: true))
        XCTAssertEqual(resolved.pending.last?.baseline?["completion_version"], .number(3))
        XCTAssertEqual(resolved.tables["tasks"]?.first?["completion_version"], .number(4))
        XCTAssertEqual(resolved.tables["tasks"]?.first?.completed, false)
    }
    func testBackupKeepsHistoricalRevisionButRestoreDoesNotReplaceAnExistingCounter() throws {
        var snapshot = Snapshot(); snapshot.tables["tasks"] = [root(version: 9)]
        let backup = WorkspaceBackup.make(snapshot, account: owner)
        let read = try WorkspaceBackup.read(backup.data())
        XCTAssertEqual(read.tables["tasks"]?.first?["completion_version"], .number(9))
        let plan = try read.plan(current: Snapshot(), account: owner, policy: .keepCurrent)
        XCTAssertEqual(plan.changes.first { $0.table == "tasks" }?.fields["completion_version"], .number(0))
        for invalid in [JSON.number(-1), .number(1.5), .string("2")] {
            var bad = backup; bad.tables["tasks"]?[0]["completion_version"] = invalid
            XCTAssertThrowsError(try WorkspaceBackup.read(bad.data()))
        }
    }
    @MainActor func testOlderOrInvalidCompletionQueueCannotMakeARequestBeforeReview() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthTransportTests.Stub.self]
        let session = try JSONDecoder().decode(Session.self, from: Data(#"{"access_token":"test","refresh_token":"refresh","expires_in":3600,"user":{"id":"owner"}}"#.utf8))
        let backend = Backend(configuration: ["URL": "https://native-auth.test", "Key": "public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        var called = false; AuthTransportTests.Stub.handler = { _ in called = true; return (200, Data("{}".utf8)) }; defer { AuthTransportTests.Stub.handler = nil }
        for version in [Optional<JSON>.none, .some(.null), .some(.number(-1)), .some(.number(1.5))] {
            var base: [String: JSON] = ["completed": .bool(false)]; base["completion_version"] = version
            do { try await backend.send(Mutation(table: "tasks", recordID: root().id, method: "PATCH", fields: ["completed": .bool(true)], baseline: base)); XCTFail("Older completion was sent") }
            catch { XCTAssertTrue(error.localizedDescription.contains("TASKFOLD_CONFLICT:")) }
        }
        XCTAssertFalse(called)
    }
}


extension CompletionRevisionTests {
    func testUseSyncedCompletionDropsDifferentDayUneditedLocalSuccessor() throws {
        var original = root(); original["recurrence_pattern"] = .object(["type": .string("daily"), "interval": .number(1), "fromCompletion": .bool(true)])
        let local = TaskCompletion.complete(original, tasks: [original], at: now)
        let remote = TaskCompletion.complete(original, tasks: [original], at: now.addingTimeInterval(86400))
        XCTAssertNotEqual(local[1].recordID, remote[1].recordID)
        var snapshot = Snapshot(tables: ["tasks": [original]], pending: local)
        for change in local { snapshot.apply(change) }
        let confirmed = TaskCompletionRevision.applying(remote[0].fields, to: original)
        let winner = Record(remote[1].fields); snapshot.tables["tasks", default: []].append(winner)
        let result = try XCTUnwrap(SyncConflict(mutation: local[0], remote: confirmed).resolving(snapshot, keepLocal: false))
        let durable = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(result))
        XCTAssertTrue(durable.pending.isEmpty)
        XCTAssertEqual(Set(durable.tables["tasks", default: []].map(\.id)), [original.id, winner.id])
        XCTAssertEqual(durable.tables["tasks"]?.first { $0.id == winner.id }, winner)
        XCTAssertEqual(durable.tables["tasks"]?.first { $0.id == original.id }, confirmed)
    }
}


extension CompletionRevisionTests {
    func testKeepMyCompletionTimestampRetainsSyncedSuccessorAcrossDifferentDays() throws {
        var original = root(); original["recurrence_pattern"] = .object(["type": .string("daily"), "interval": .number(1), "fromCompletion": .bool(true)])
        let local = TaskCompletion.complete(original, tasks: [original], at: now)
        let remote = TaskCompletion.complete(original, tasks: [original], at: now.addingTimeInterval(86400))
        var snapshot = Snapshot(tables: ["tasks": [original]], pending: local)
        for change in local { snapshot.apply(change) }
        let winner = Record(remote[1].fields); snapshot.tables["tasks", default: []].append(winner)
        let confirmed = TaskCompletionRevision.applying(remote[0].fields, to: original)
        let result = try XCTUnwrap(SyncConflict(mutation: local[0], remote: confirmed).resolving(snapshot, keepLocal: true))
        XCTAssertEqual(result.pending.count, 1); XCTAssertEqual(result.pending.first?.fields["completed_at"], local[0].fields["completed_at"])
        XCTAssertEqual(result.pending.first?.baseline?["completion_version"], confirmed["completion_version"])
        XCTAssertEqual(Set(result.tables["tasks", default: []].map(\.id)), [original.id, winner.id])
        XCTAssertEqual(result.tables["tasks"]?.first { $0.id == winner.id }, winner)
    }
    func testAlreadyCachedSyncedSuccessorIsNeverRemovedOrDetachedDuringReview() throws {
        let (snapshot, changes) = queued()
        var winner = Record(changes[1].fields); winner["task_generation"] = .string("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"); winner["title"] = .string("Synced next task")
        var cached = snapshot; cached.tables["tasks"] = [snapshot.tables["tasks"]!.first!, winner]
        var done = root(version: 1); done["completed"] = .bool(true); done["completed_at"] = .string("2026-10-06T13:00:00Z")
        for keepLocal in [false, true] {
            let result = try XCTUnwrap(SyncConflict(mutation: changes[0], remote: done).resolving(cached, keepLocal: keepLocal))
            XCTAssertFalse(result.pending.contains { $0.method == "POST" })
            XCTAssertEqual(result.tables["tasks"]?.first { $0.id == winner.id }, winner)
        }
    }
    func testEditedDifferentDaySuccessorRemainsIndependentForBothReviewChoices() throws {
        var original = root(); original["recurrence_pattern"] = .object(["type": .string("daily"), "interval": .number(1), "fromCompletion": .bool(true)])
        let local = TaskCompletion.complete(original, tasks: [original], at: now)
        let remote = TaskCompletion.complete(original, tasks: [original], at: now.addingTimeInterval(86400))
        var snapshot = Snapshot(tables: ["tasks": [original]], pending: local)
        for change in local { snapshot.apply(change) }
        let edit = Mutation(table: "tasks", recordID: local[1].recordID, method: "PATCH", fields: ["description": .string("Keep this draft")], baseline: ["description": local[1].fields["description"] ?? .null, "task_generation": local[1].fields["task_generation"]!])
        snapshot.pending.append(edit); snapshot.apply(edit)
        let confirmed = TaskCompletionRevision.applying(remote[0].fields, to: original)
        for keepLocal in [false, true] {
            let result = try XCTUnwrap(SyncConflict(mutation: local[0], remote: confirmed).resolving(snapshot, keepLocal: keepLocal))
            let durable = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(result))
            XCTAssertTrue(durable.pending.contains { $0.id == edit.id })
            let creation = try XCTUnwrap(durable.pending.first { $0.method == "POST" })
            XCTAssertEqual(creation.recordID, local[1].recordID); XCTAssertEqual(creation.fields["recurrence_parent_id"], .null)
            XCTAssertNil(creation.fields["source_metadata"]?.object["taskfold_recurrence_v1"])
            let draft = try XCTUnwrap(durable.tables["tasks"]?.first { $0.id == local[1].recordID })
            XCTAssertEqual(draft.string("description"), "Keep this draft"); XCTAssertEqual(draft["recurrence_parent_id"], .null)
        }
    }
}
