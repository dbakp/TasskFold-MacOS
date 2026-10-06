import XCTest
@testable import TaskfoldCore

final class TaskActivityTests: XCTestCase {
    let account = "owner"
    let project = "11111111-1111-4111-8111-111111111111"
    let taskID = "22222222-2222-4222-8222-222222222222"
    let now = TaskPlanning.instant("2026-10-06T10:00:00Z")!
    func task() -> Record {
        var t = Record.task(user: account, project: project); t["id"] = .string(taskID); t["title"] = .string("Useful work"); t["description"] = .string("Private full notes"); return t
    }
    func record(_ change: Mutation, snapshot: inout Snapshot, date: Date? = nil) {
        let before = snapshot.tables["tasks"]?.first { $0.id == change.recordID }; snapshot.apply(change)
        TaskActivity.recordLocal(change, before: before, after: snapshot.tables["tasks"]?.first { $0.id == change.recordID }, snapshot: &snapshot, account: account, now: date ?? now)
    }
    func event() throws -> Record {
        var s = Snapshot(); let t = task(); record(Mutation(table: "tasks", recordID: t.id, method: "POST", fields: t.fields), snapshot: &s); return try XCTUnwrap(s.tables[TaskActivity.table]?.first)
    }
    func testDurableLocalCompletionReopenUndoAndRepeatOccurrencesHaveDistinctHistory() throws {
        var t = task(); t["due_date"] = .string("2026-10-06"); t["is_recurring"] = .bool(true); t["recurrence_pattern"] = .object(["type": .string("daily"), "interval": .number(1)])
        var s = Snapshot(tables: ["tasks": [t]])
        let changes = TaskCompletion.toggle(t, tasks: [t], at: now)
        XCTAssertEqual(changes.count, 2)
        for c in changes { record(c, snapshot: &s) }
        var reading = ProjectPulseReading(project: project, tasks: s.tables["tasks"]!, activity: s.tables[TaskActivity.table]!, now: now)
        XCTAssertEqual(reading.total, 2); XCTAssertEqual(reading.completed, 1); XCTAssertEqual(reading.completions, 1); XCTAssertEqual(reading.additions, 1)
        let reopen = Mutation(table: "tasks", recordID: t.id, method: "PATCH", fields: ["completed": .bool(false), "completed_at": .null])
        record(reopen, snapshot: &s); record(reopen, snapshot: &s) // Equivalent state/replay is not another transition.
        let restored = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(s))
        reading = ProjectPulseReading(project: project, tasks: restored.tables["tasks"]!, activity: restored.tables[TaskActivity.table]!, now: now)
        XCTAssertEqual(reading.completed, 0); XCTAssertEqual(reading.reopens, 1); XCTAssertEqual(reading.completions, 1); XCTAssertEqual(reading.events.count, 3)
        XCTAssertEqual(Set(reading.events.map(\.id)).count, 3); XCTAssertEqual(reading.events.first?.completionVersion, 2)
        XCTAssertFalse(String(data: try JSONEncoder().encode(restored.tables[TaskActivity.table]), encoding: .utf8)!.contains("Private full notes"))
    }
    func testCompletionInstantAndRecordedInstantStaySeparateAndNotesProduceNoEvent() throws {
        let t = task(); var s = Snapshot(tables: ["tasks": [t], TaskActivity.epochTable: []])
        record(Mutation(table: "tasks", recordID: t.id, method: "PATCH", fields: ["description": .string("Changed notes")]), snapshot: &s)
        XCTAssertNil(s.tables[TaskActivity.table]); XCTAssertEqual(s.tables[TaskActivity.epochTable], [])
        let earlier = now.addingTimeInterval(-10 * 86400)
        record(Mutation(table: "tasks", recordID: t.id, method: "PATCH", fields: ["completed": .bool(true), "completed_at": .string(TaskActivity.stamp(earlier))]), snapshot: &s)
        let e = try XCTUnwrap(TaskActivity(row: s.tables[TaskActivity.table]![0]))
        XCTAssertEqual(e.recordedAt, now); XCTAssertEqual(e.effectiveAt, earlier)
        XCTAssertEqual(s.tables[TaskActivity.epochTable]?.count, 1)
        XCTAssertEqual(s.tables[TaskActivity.epochTable]?.first?.string("recorded_from"), TaskActivity.stamp(now))
        XCTAssertEqual(ProjectPulseReading(project: project, tasks: s.tables["tasks"]!, activity: s.tables[TaskActivity.table]!, now: now).completions, 1)
    }
    func testMovedAndRescheduledInOneWriteExplainChangingScopeWithoutChangingCompletedWork() throws {
        var t = task(); t["completed"] = .bool(true); t["completed_at"] = .string(TaskActivity.stamp(now)); var s = Snapshot(tables: ["tasks": [t]])
        var added = task(); added["id"] = .string(UUID().uuidString); added["completed"] = .bool(false)
        record(Mutation(table: "tasks", recordID: added.id, method: "POST", fields: added.fields), snapshot: &s)
        var r = ProjectPulseReading(project: project, tasks: s.tables["tasks"]!, activity: s.tables[TaskActivity.table]!, now: now)
        XCTAssertEqual(r.total, 2); XCTAssertEqual(r.completed, 1); XCTAssertEqual(r.additions, 1); XCTAssertEqual(r.completions, 0)
        record(Mutation(table: "tasks", recordID: added.id, method: "PATCH", fields: ["project_id": .string("another"), "due_date": .string("2026-10-08")]), snapshot: &s)
        r = ProjectPulseReading(project: project, tasks: s.tables["tasks"]!, activity: s.tables[TaskActivity.table]!, now: now)
        XCTAssertEqual(r.total, 1); XCTAssertEqual(r.completed, 1); XCTAssertEqual(r.movedOut, 1); XCTAssertEqual(r.events.first?.kinds, [.moved, .rescheduled])
        let other = ProjectPulseReading(project: "another", tasks: s.tables["tasks"]!, activity: s.tables[TaskActivity.table]!, now: now)
        XCTAssertEqual(other.total, 1); XCTAssertEqual(other.movedIn, 1)
    }
    func testCompletedCreationNeverBackfillsCompletionAndDeletionRetainsMetadata() throws {
        var t = task(); t["completed"] = .bool(true); t["completed_at"] = .string("2020-01-01T10:00:00Z"); var s = Snapshot()
        record(Mutation(table: "tasks", recordID: t.id, method: "POST", fields: t.fields), snapshot: &s)
        XCTAssertEqual(TaskActivity(row: s.tables[TaskActivity.table]![0])?.kinds, [.created])
        XCTAssertEqual(ProjectPulseReading(project: project, tasks: s.tables["tasks"]!, activity: s.tables[TaskActivity.table]!, now: now).completions, 0)
        record(Mutation(table: "tasks", recordID: t.id, method: "DELETE", fields: [:]), snapshot: &s)
        XCTAssertEqual(s.tables[TaskActivity.table]?.count, 2); XCTAssertEqual(TaskActivity(row: s.tables[TaskActivity.table]![1])?.kinds, [.deleted])
        XCTAssertEqual(ProjectPulseReading(project: project, tasks: [], activity: s.tables[TaskActivity.table]!, now: now).total, 0)
    }
    func testStrictDecoderRejectsMalformedHistoryAndReportsIncompleteCounts() throws {
        let good = try event(); XCTAssertNotNil(TaskActivity(row: good))
        for mode in ["sequence", "version", "kind", "private", "missing", "date", "contradiction", "duplicate"] {
            var bad = good
            switch mode {
            case "sequence": bad["sequence"] = .number(1.5)
            case "version": bad["completion_version"] = .number(.infinity)
            case "kind": bad["kinds"] = .array([.string("future")])
            case "private": var state = bad["after_state"].object; state["description"] = .string("Private"); bad["after_state"] = .object(state)
            case "missing": bad["after_state"] = .object([:])
            case "date": bad["recorded_at"] = .string("not a date")
            case "contradiction": bad["kinds"] = .array([.string("completed")])
            default: bad["kinds"] = .array([.string("created"), .string("created")])
            }
            XCTAssertNil(TaskActivity(row: bad), mode)
            XCTAssertEqual(ProjectPulseReading(project: project, tasks: [], activity: [good, bad], now: now).malformed, 1)
        }
    }
    func testCalendarWindowCrossesDSTAndCountsEventsOnceWithFutureClockExcluded() throws {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
        let at = TaskPlanning.instant("2026-03-30T10:00:00Z")!
        var s = Snapshot(); let t = task()
        record(Mutation(table: "tasks", recordID: t.id, method: "POST", fields: t.fields), snapshot: &s, date: at)
        let row = s.tables[TaskActivity.table]![0]
        var future = row; future["id"] = .string(UUID().uuidString); future["sequence"] = .number(2); future["recorded_at"] = .string(TaskActivity.stamp(at.addingTimeInterval(1)))
        let r = ProjectPulseReading(project: project, tasks: [t, t], activity: [row, row, future], now: at, calendar: c)
        XCTAssertEqual(r.total, 1); XCTAssertEqual(r.additions, 1); XCTAssertEqual(r.events.count, 2)
        XCTAssertEqual(r.end.timeIntervalSince(r.start), 7 * 86400 - 3600)
        XCTAssertEqual(TaskPlanner.dayKey(r.start, calendar: c), "2026-03-24")
    }
    func testSemanticTimeSpellingsDoNotCreateFalseLocalReschedules() {
        var t = task(); t["due_time"] = .string("10:00"); t["scheduled_at"] = .string("2026-10-06T10:00:00Z")
        var next = t; next["due_time"] = .string("10:00:00"); next["scheduled_at"] = .string("2026-10-06T12:00:00+02:00")
        XCTAssertEqual(TaskActivity.changes(before: TaskActivity.state(t), after: TaskActivity.state(next)), [])
    }
    func testBackupRetainsValidatedArchiveWithoutReplayingItAsActivity() throws {
        let t = task(); var s = Snapshot(); record(Mutation(table: "tasks", recordID: t.id, method: "POST", fields: t.fields), snapshot: &s)
        s.tables["projects"] = [Record(["id": .string(project), "user_id": .string(account), "name": .string("Studio")])]
        let backup = WorkspaceBackup.make(s, account: account, now: now)
        let decoded = try WorkspaceBackup.read(backup.data())
        XCTAssertEqual(decoded.tables[TaskActivity.table], s.tables[TaskActivity.table])
        let plan = try decoded.plan(current: Snapshot(), account: "another")
        XCTAssertFalse(plan.changes.contains { $0.table == TaskActivity.table || $0.table == TaskActivity.epochTable })
        XCTAssertTrue(plan.warnings.contains { $0.contains("archive") })
        var duplicate = backup; duplicate.tables[TaskActivity.table]!.append(duplicate.tables[TaskActivity.table]![0])
        XCTAssertThrowsError(try WorkspaceBackup.read(duplicate.data()))
        var bad = backup; bad.tables[TaskActivity.table]![0]["kinds"] = .array([.string("completed")])
        XCTAssertThrowsError(try WorkspaceBackup.read(bad.data()))
    }
    func testSequencePaginationBeyondOnePageRejectsNonadvancingOrFractionalCursors() throws {
        let page = (1...500).map { Record(["sequence": .number(Double($0))]) }
        XCTAssertEqual(try TaskActivityPage.cursor(page, after: 0), 500)
        XCTAssertTrue(TaskActivityPage.query(after: 500).contains("sequence=gt.500")); XCTAssertFalse(TaskActivityPage.query(after: 500).contains("offset"))
        XCTAssertEqual(try TaskActivityPage.cursor([Record(["sequence": .number(900)])], after: 500), 900)
        XCTAssertThrowsError(try TaskActivityPage.cursor([Record(["sequence": .number(500)])], after: 500))
        XCTAssertThrowsError(try TaskActivityPage.cursor([Record(["sequence": .number(501.5)])], after: 500))
        XCTAssertThrowsError(try TaskActivityPage.cursor([Record(["sequence": .number(.nan)])], after: 0))
    }
}
