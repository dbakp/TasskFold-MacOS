import XCTest
@testable import TaskfoldCore

final class FocusSessionTests: XCTestCase {
    let account = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let taskID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    let start = Date(timeIntervalSince1970: 1_791_273_600)
    func session(minutes: Int = 25) throws -> FocusSession { try FocusSession(taskID: taskID, minutes: minutes, now: start) }
    func row(_ session: FocusSession?, current: Record? = nil) throws -> Record { Record(try FocusSessionChange.make(session, current: current, account: account).fields) }
    func task() -> Record { Record(["id": .string(taskID), "user_id": .string(account), "title": .string("A useful task"), "completed": .bool(false)]) }
    func testElapsedUsesDurableUTCClockAcrossRelaunchAndTimeZoneChanges() throws {
        let value = try session()
        let restored = try FocusSession(document: JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(value.document)))
        XCTAssertEqual(restored, value)
        XCTAssertEqual(restored.remaining(at: start.addingTimeInterval(61.125)), 1438.875, accuracy: 0.001)
        XCTAssertEqual(restored.endDate, start.addingTimeInterval(1500))
        XCTAssertEqual(restored.elapsed(at: start.addingTimeInterval(-3600)), 0)
        XCTAssertEqual(restored.elapsed(at: start.addingTimeInterval(86400)), 1_500_000)
    }
    func testPauseResumeExcludesPausedTimeAndPreservesMillisecondRemainders() throws {
        let paused = try session().paused(at: start.addingTimeInterval(30.125))
        XCTAssertEqual(paused.remaining(at: start.addingTimeInterval(3600)), 1469.875, accuracy: 0.001)
        let resumed = try FocusSession(document: paused.document).resumed(at: start.addingTimeInterval(3600))
        let secondPause = try resumed.paused(at: start.addingTimeInterval(3620.250))
        XCTAssertEqual(secondPause.elapsedMilliseconds, 50_375)
        XCTAssertNil(secondPause.endDate)
        XCTAssertThrowsError(try secondPause.paused(at: start))
    }
    func testCompletionDoesNotMutateOrCompleteItsTaskAndResumeCannotRestartFinishedTimer() throws {
        let value = try session(minutes: 1), finished = start.addingTimeInterval(61)
        XCTAssertTrue(value.finished(at: finished)); XCTAssertEqual(value.remaining(at: finished), 0)
        let paused = try value.paused(at: finished)
        XCTAssertThrowsError(try paused.resumed(at: finished))
        let stopped = try value.stopped(at: finished)
        XCTAssertEqual(stopped.status, .stopped); XCTAssertEqual(stopped.elapsedMilliseconds, 60_000)
        XCTAssertThrowsError(try stopped.stopped(at: finished))
        let change = try FocusSessionChange.make(stopped, current: nil, account: account)
        var snapshot = Snapshot(tables: ["tasks": [task()]])
        snapshot.apply(change)
        XCTAssertEqual(snapshot.tables["tasks"], [task()])
    }
    func testBackwardDeviceClockDoesNotLoseElapsedOrMoveCommandTimeBackward() throws {
        let pause = try session().paused(at: start.addingTimeInterval(60))
        let resumed = try pause.resumed(at: start.addingTimeInterval(10))
        XCTAssertEqual(resumed.changedAt, pause.changedAt)
        XCTAssertEqual(resumed.elapsed(at: start.addingTimeInterval(40)), 60_000)
        XCTAssertEqual(resumed.elapsed(at: start.addingTimeInterval(70)), 70_000)
        XCTAssertThrowsError(try resumed.paused(at: Date(timeIntervalSince1970: -.infinity)))
    }
    func testStrictDocumentsRejectFutureKeysInconsistentClocksAndNonfiniteNumbers() throws {
        let value = try session().document
        for (key, invalid) in [("duration_seconds", JSON.number(61)), ("duration_seconds", .number(10860)), ("elapsed_ms", .number(-1)), ("elapsed_ms", .number(1_500_001)), ("elapsed_ms", .number(.infinity)), ("status", .string("unknown")), ("running_since_ms", .null), ("changed_at_ms", .number(0)), ("task_id", .string("not-an-id")), ("extra", .bool(true))] {
            var fields = value.object; fields[key] = invalid
            XCTAssertThrowsError(try FocusSession(document: .object(fields)), key)
        }
        var missing = value.object; missing.removeValue(forKey: "elapsed_ms")
        XCTAssertThrowsError(try FocusSession(document: .object(missing)))
        var paused = try session().paused(at: start).document.object; paused["running_since_ms"] = .number(0)
        XCTAssertThrowsError(try FocusSession(document: .object(paused)))
        for minutes in [0,181,Int.max] { XCTAssertThrowsError(try session(minutes: minutes)) }
        XCTAssertThrowsError(try FocusSession(taskID: taskID, minutes: 25, now: Date(timeIntervalSince1970: .infinity)))
    }
    func testCommandsRetainRevisionAcrossPauseStopClearAndNewStart() throws {
        let a = try row(session())
        let b = try row(session().paused(at: start), current: a)
        let c = try row(nil, current: b)
        let restart = try FocusSessionChange.make(session(), current: c, account: account)
        XCTAssertEqual(restart.fields["revision"], .number(4))
        XCTAssertEqual(restart.baseline, ["revision": .number(3), "action_id": c["action_id"]])
        XCTAssertTrue(FocusSessionChange.valid(restart, account: account))
        XCTAssertFalse(FocusSessionChange.valid(restart, account: "other"))
        XCTAssertThrowsError(try FocusSessionChange.make(session(), current: c, account: "other"))
        var bad = restart; bad.baseline = nil; XCTAssertFalse(FocusSessionChange.valid(bad, account: account))
        bad = restart; bad.method = "PATCH"; XCTAssertFalse(FocusSessionChange.valid(bad, account: account))
        bad = restart; bad.fields["revision"] = .number(1); XCTAssertFalse(FocusSessionChange.valid(bad, account: account))
        bad = restart; bad.fields["action_id"] = c["action_id"]; XCTAssertFalse(FocusSessionChange.valid(bad, account: account))
    }
    func testOfflineChainAndServerAcknowledgementRetainLaterPauseAndUnrelatedTaskEdits() throws {
        let first = try FocusSessionChange.make(session(), current: nil, account: account)
        let second = try FocusSessionChange.make(session().paused(at: start.addingTimeInterval(40)), current: Record(first.fields), account: account)
        let edit = Mutation(table: "tasks", recordID: taskID, method: "PATCH", fields: ["title": .string("Still keep my edit")])
        var snapshot = Snapshot(tables: ["tasks": [task()]], pending: [first, edit, second])
        for change in snapshot.pending { snapshot.apply(change) }
        let restored = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        snapshot = restored; snapshot.acknowledge(first, saved: Record(first.fields))
        XCTAssertEqual(snapshot.pending, [edit, second])
        XCTAssertEqual(FocusSessionChange.session(in: snapshot.tables[FocusSessionChange.table]?.first, account: account)?.elapsedMilliseconds, 40_000)
        snapshot.mergeRemote([FocusSessionChange.table: [Record(first.fields)]])
        XCTAssertEqual(snapshot.tables[FocusSessionChange.table]?.first?["revision"], .number(2))
        XCTAssertEqual(snapshot.tables["tasks"]?.first?.title, "Still keep my edit")
    }
    func testConflictUseSyncedDropsDependentTimerCommandsAndKeepsOtherWork() throws {
        let first = try FocusSessionChange.make(session(), current: nil, account: account)
        let second = try FocusSessionChange.make(session().paused(at: start.addingTimeInterval(60)), current: Record(first.fields), account: account)
        let edit = Mutation(table: "tasks", recordID: taskID, method: "PATCH", fields: ["description": .string("Later work")])
        let remote = try row(session(minutes: 45))
        let conflict = FocusSyncConflict(mutation: first, remote: remote)
        let original = Snapshot(tables: [FocusSessionChange.table: [Record(second.fields)]], pending: [first, edit, second])
        let synced = try XCTUnwrap(conflict.resolving(original, account: account, keepLocal: false))
        XCTAssertEqual(synced.pending, [edit]); XCTAssertEqual(synced.tables[FocusSessionChange.table], [remote])
        XCTAssertNil(conflict.resolving(original, account: "other", keepLocal: false))
        XCTAssertNil(conflict.resolving(Snapshot(), account: account, keepLocal: false))
    }
    func testConflictKeepThisDeviceReviewsFinalStateAndRebasesOneGuardedCommand() throws {
        let first = try FocusSessionChange.make(session(), current: nil, account: account)
        let last = try FocusSessionChange.make(session().paused(at: start.addingTimeInterval(12.125)), current: Record(first.fields), account: account)
        let remote = try row(session(minutes: 45))
        let original = Snapshot(tables: [FocusSessionChange.table: [Record(last.fields)]], pending: [first,last])
        let next = try XCTUnwrap(FocusSyncConflict(mutation: first, remote: remote).resolving(original, account: account, keepLocal: true))
        XCTAssertEqual(next.pending.count, 1); XCTAssertEqual(next.pending.first?.baseline, FocusSessionChange.baseline(remote))
        XCTAssertEqual(next.pending.first?.fields["state"], last.fields["state"])
        XCTAssertNotEqual(next.pending.first?.fields["action_id"], first.fields["action_id"])
        XCTAssertNotEqual(next.pending.first?.fields["action_id"], last.fields["action_id"])
        XCTAssertTrue(FocusSessionChange.valid(next.pending[0], account: account))
        var broken = original; broken.pending[1].baseline = FocusSessionChange.baseline(nil)
        XCTAssertNil(FocusSyncConflict(mutation: first, remote: remote).resolving(broken, account: account, keepLocal: true))
    }
    func testUnavailableFirstStartCanUseAnEmptySyncedSlotWithoutDiscardingTasks() throws {
        let change = try FocusSessionChange.make(session(), current: nil, account: account)
        let remote = FocusSessionChange.emptyRow(account: account)
        XCTAssertTrue(FocusSessionChange.validRow(remote, account: account))
        let next = try XCTUnwrap(FocusSyncConflict(mutation: change, remote: remote).resolving(Snapshot(tables: ["tasks": [task()]], pending: [change]), account: account, keepLocal: false))
        XCTAssertTrue(next.pending.isEmpty); XCTAssertEqual(next.tables["tasks"], [task()])
        XCTAssertNil(FocusSessionChange.session(in: next.tables[FocusSessionChange.table]?.first, account: account))
    }
    func testPortableBackupFreezesAndRemapsSessionWithoutRestoringServerRevision() throws {
        let original = try row(session())
        let live = Snapshot(tables: ["tasks": [task()], FocusSessionChange.table: [original]])
        let backup = WorkspaceBackup.make(live, account: account, now: start.addingTimeInterval(30.125))
        let read = try WorkspaceBackup.read(backup.data())
        let checkpoint = try FocusSession(document: XCTUnwrap(read.tables[FocusSessionChange.table]?.first)["state"])
        XCTAssertEqual(checkpoint.status, .paused); XCTAssertEqual(checkpoint.elapsedMilliseconds, 30_125)
        XCTAssertEqual(live.tables[FocusSessionChange.table]?.first, original)
        let other = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let plan = try read.plan(current: Snapshot(), account: other, policy: .backupValues)
        let focus = try XCTUnwrap(plan.changes.first { $0.table == FocusSessionChange.table })
        let mapped = try FocusSession(document: focus.fields["state"]!)
        XCTAssertEqual(mapped.taskID, plan.mappedIDs["tasks"]?[taskID]); XCTAssertNotEqual(mapped.id, checkpoint.id)
        XCTAssertEqual(mapped.elapsedMilliseconds, 30_125); XCTAssertEqual(mapped.status, .paused)
        XCTAssertEqual(focus.fields["revision"], .number(1)); XCTAssertTrue(FocusSessionChange.valid(focus, account: other))
        XCTAssertEqual(try read.plan(current: Snapshot(), account: other, policy: .backupValues).changes.last?.fields, focus.fields, "A restore retry has stable IDs and action identity")
    }
    func testRestoreKeepCurrentAndUseBackupGuardTheCurrentRevision() throws {
        let backup = WorkspaceBackup.make(Snapshot(tables: ["tasks": [task()], FocusSessionChange.table: [try row(session())]]), account: account, now: start)
        let current = try row(session(minutes: 45))
        let snapshot = Snapshot(tables: ["tasks": [task()], FocusSessionChange.table: [current]])
        XCTAssertFalse(try backup.plan(current: snapshot, account: account, policy: .keepCurrent).changes.contains { $0.table == FocusSessionChange.table })
        let change = try XCTUnwrap(backup.plan(current: snapshot, account: account, policy: .backupValues).changes.first { $0.table == FocusSessionChange.table })
        XCTAssertEqual(change.baseline, FocusSessionChange.baseline(current)); XCTAssertEqual(change.fields["revision"], .number(2))
        var invalid = backup; invalid.tables[FocusSessionChange.table]?[0]["revision"] = .number(-1)
        XCTAssertThrowsError(try invalid.validate())
        var missing = backup; missing.tables["tasks"] = []
        XCTAssertThrowsError(try missing.plan(current: Snapshot(), account: "other"))
    }
    @MainActor func testNativeTransportUsesGuardedRPCAndRequiresExactPositiveAcknowledgement() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthTransportTests.Stub.self]
        let signed = try JSONDecoder().decode(Session.self, from: Data(("{\"access_token\":\"test\",\"refresh_token\":\"refresh\",\"expires_in\":3600,\"user\":{\"id\":\"" + account + "\"}}").utf8))
        let backend = Backend(configuration: ["URL":"https://native-auth.test","Key":"public"], http: URLSession(configuration: config), session: signed, persistSession: { _ in })
        let change = try FocusSessionChange.make(session(), current: nil, account: account)
        AuthTransportTests.Stub.handler = { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_set_focus_session"); XCTAssertEqual(request.httpMethod, "POST")
            return (200, try JSONEncoder().encode(Record(change.fields)))
        }
        defer { AuthTransportTests.Stub.handler = nil }
        let saved = try await backend.send(change)
        XCTAssertEqual(saved, Record(change.fields))
        var wrong = Record(change.fields); wrong["action_id"] = .string(UUID().uuidString.lowercased())
        AuthTransportTests.Stub.handler = { _ in (200, try JSONEncoder().encode(wrong)) }
        do { try await backend.send(change); XCTFail("A different session cannot acknowledge this command") } catch { XCTAssertTrue(error.localizedDescription.contains("did not confirm")) }
        var called = false; AuthTransportTests.Stub.handler = { _ in called = true; return (200, Data("{}".utf8)) }
        var unguarded = change; unguarded.baseline = nil
        do { try await backend.send(unguarded); XCTFail("A blind Focus command was sent") } catch { XCTAssertTrue(error.localizedDescription.contains("TASKFOLD_FOCUS_CONFLICT:")) }
        XCTAssertFalse(called)
    }
    func testRestoreRejectsMalformedCurrentRevisionWithoutIntegerConversionTrap() throws {
        let backup = WorkspaceBackup.make(Snapshot(tables: ["tasks": [task()], FocusSessionChange.table: [try row(session())]]), account: account, now: start)
        for value in [Double.infinity, 1e200, -1, 1.5] {
            var current = try row(session(minutes: 45)); current["revision"] = .number(value)
            XCTAssertThrowsError(try backup.plan(current: Snapshot(tables: ["tasks": [task()], FocusSessionChange.table: [current]]), account: account, policy: .backupValues))
        }
    }
}


final class FocusTaskCatalogTests: XCTestCase {
    private func task(_ number: Int, title: String = "Review proposal", project: String = "p") -> Record {
        Record(["id": .string(String(format: "aaaaaaaa-aaaa-4aaa-8aaa-%012d", number)), "title": .string(title), "project_id": .string(project), "completed": .bool(false), "task_generation": .string("generation-\(number)")])
    }
    private let projects = [Record(["id": .string("p"), "name": .string("Studio")]), Record(["id": .string("h"), "name": .string("Home")])]
    func testDuplicateNamesKeepStableTaskIdentitiesAndProjectSectionParentContext() {
        var studio = task(1), home = task(2, project: "h"), child = task(3)
        studio["section_id"] = .string("launch"); child["parent_id"] = .string(studio.id)
        home["description"] = .string("Paint colours")
        let sections = [Record(["id": .string("launch"), "project_id": .string("p"), "name": .string("Client launch")])]
        let choices = FocusTaskCatalog(tasks: [child,studio,home], projects: projects, sections: sections).choices
        XCTAssertEqual(choices.map(\.id), [home.id,studio.id,child.id])
        XCTAssertEqual(choices.map(\.context), ["Home", "Studio · Client launch", "Studio · Review proposal"])
        XCTAssertEqual(FocusTaskCatalog(tasks: [home,studio,child], projects: projects, sections: sections).choices, choices)
    }
    func testSearchMatchesEveryWordAcrossTitleContextAndNotesWithAccentsAndUnicode() {
        var studio = task(1); studio["description"] = .string("Review the café launch 東京 🥐")
        let sections = [Record(["id": .string("launch"), "project_id": .string("p"), "name": .string("Client launch")])]
        studio["section_id"] = .string("launch")
        for query in ["  CAFE \n studio proposal ", "client 東京", "🥐 review"] {
            XCTAssertEqual(FocusTaskCatalog(tasks: [task(2,project: "h"),studio], projects: projects, sections: sections, search: query).choices.map(\.id), [studio.id])
        }
        XCTAssertTrue(FocusTaskCatalog(tasks: [studio], projects: projects, sections: sections, search: "studio absent").choices.isEmpty)
        XCTAssertEqual(FocusTaskCatalog(tasks: [studio], projects: projects, sections: sections, search: " \n ").choices.count, 1)
    }
    func testMissingAndForeignDirectoryReferencesNeverUseAnotherProjectsSection() {
        var unknown = task(1, project: "gone"), wrongSection = task(2), inbox = task(3, project: "")
        unknown["section_id"] = .string("foreign"); wrongSection["section_id"] = .string("foreign")
        inbox["parent_id"] = .string(wrongSection.id)
        let sections = [Record(["id": .string("foreign"), "project_id": .string("h"), "name": .string("Private home section")])]
        let choices = FocusTaskCatalog(tasks: [unknown,wrongSection,inbox], projects: projects, sections: sections).choices
        XCTAssertEqual(Set(choices.map(\.context)), ["Project unavailable", "Studio", "Inbox"])
        XCTAssertTrue(FocusTaskCatalog(tasks: [unknown,wrongSection,inbox], projects: projects, sections: sections, search: "private").choices.isEmpty)
        XCTAssertEqual(FocusTaskCatalog(tasks: [], projects: projects, sections: sections).choices, [])
    }
    func testCompletedInvalidAndRepeatedIDsAreExcludedWithoutChangingTasks() {
        var done = task(2), invalid = task(3), untitled = task(4)
        done["completed"] = .bool(true); invalid["id"] = .string("bad"); untitled["title"] = .string(" \n ")
        let tasks = [done,task(1),invalid,task(1),untitled], before = tasks
        let choices = FocusTaskCatalog(tasks: tasks, projects: projects, sections: []).choices
        XCTAssertEqual(choices.map(\.title), ["Review proposal", "Untitled task"])
        XCTAssertEqual(tasks, before)
    }
    func testNaturalNumberOrderingAndStableTiesSurviveDirectoryReordering() {
        let rows = [task(3,title: "Task 10"),task(2,title: "TASK 2"),task(1,title: "Task 2")]
        let expected = [rows[2].id,rows[1].id,rows[0].id]
        XCTAssertEqual(FocusTaskCatalog(tasks: rows,projects: projects,sections: []).choices.map(\.id), expected)
        XCTAssertEqual(FocusTaskCatalog(tasks: Array(rows.reversed()),projects: projects,sections: []).choices.map(\.id), expected)
    }
    func testLargeCatalogueSearchIncludesLastTaskAndFullNotesBeyondDisplayExcerpt() {
        var rows = (1...5000).map { task($0,title: "Task \($0)") }
        rows[4999]["description"] = .string(String(repeating: "intro ",count: 100) + "lastneedle")
        let choices = FocusTaskCatalog(tasks: rows, projects: projects, sections: [], search: "studio lastneedle").choices
        XCTAssertEqual(choices.map(\.id), [rows[4999].id])
    }
    func testSelectionAllowsRenamesButRejectsDeletionCompletionAndTaskRecreation() throws {
        var row = task(1)
        let choice = try XCTUnwrap(FocusTaskCatalog(tasks: [row], projects: projects, sections: []).choices.first)
        row["title"] = .string("Renamed task"); row["project_id"] = .string("h")
        XCTAssertTrue(FocusTaskCatalog.selectable(choice, tasks: [row]))
        XCTAssertFalse(FocusTaskCatalog.selectable(choice, tasks: []))
        row["completed"] = .bool(true); XCTAssertFalse(FocusTaskCatalog.selectable(choice, tasks: [row]))
        row["completed"] = .bool(false); row["task_generation"] = .string("replacement")
        XCTAssertFalse(FocusTaskCatalog.selectable(choice, tasks: [row]))
        row["task_generation"] = .null
        let legacy = try XCTUnwrap(FocusTaskCatalog(tasks: [row], projects: projects, sections: []).choices.first)
        XCTAssertTrue(FocusTaskCatalog.selectable(legacy, tasks: [row]))
        row["task_generation"] = .string("new-incarnation"); XCTAssertFalse(FocusTaskCatalog.selectable(legacy, tasks: [row]))
    }
}
