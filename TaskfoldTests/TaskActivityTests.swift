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

extension TaskActivityTests {
    private func goals(zone:String="Europe/Copenhagen") throws -> ProductivityGoals {
        var value=try ProductivityGoals();value.dailyTarget=5;value.weeklyTarget=20;value.timeZone=zone;return try value.validated()
    }
    private func credit(_ snapshot:Snapshot,at instant:Date?=nil,settings:ProductivityGoals?=nil,scope:InsightsReading.Scope = .mine,projectID:String?=nil,accessible:Set<String>=[]) throws -> InsightsReading {
        InsightsReading(account:account,activity:snapshot.tables[TaskActivity.table] ?? [],epoch:snapshot.tables[TaskActivity.epochTable] ?? [],goals:try settings ?? goals(),scope:scope,projectID:projectID,accessibleProjects:accessible,now:instant ?? now)
    }
    private func complete(_ task:Record,in snapshot:inout Snapshot,at instant:Date) {
        record(Mutation(table:"tasks",recordID:task.id,method:"PATCH",fields:["completed":.bool(true),"completed_at":.string(TaskActivity.stamp(instant))]),snapshot:&snapshot,date:instant)
    }
    func testInsightsDuplicateEventsAndLaterVersionReplayNeverDoubleCredit() throws {
        let t=task();var s=Snapshot(tables:["tasks":[t]])
        complete(t,in:&s,at:now.addingTimeInterval(-120))
        s.tables[TaskActivity.table]!.append(s.tables[TaskActivity.table]![0])
        var reading=try credit(s);XCTAssertEqual(reading.today,1);XCTAssertEqual(reading.credits.count,1);XCTAssertEqual(reading.malformed,0)
        var replay=s.tables[TaskActivity.table]![0];replay["id"] = .string(UUID().uuidString);replay["sequence"] = .number(2)
        s.tables[TaskActivity.table]!.append(replay)
        reading=try credit(s);XCTAssertEqual(reading.today,1);XCTAssertEqual(reading.malformed,0)
        let reopen=Mutation(table:"tasks",recordID:t.id,method:"PATCH",fields:["completed":.bool(false),"completed_at":.null]);record(reopen,snapshot:&s)
        replay["id"] = .string(UUID().uuidString);replay["sequence"] = .number(4);s.tables[TaskActivity.table]!.append(replay)
        XCTAssertEqual(try credit(s).today,0)
    }
    func testInsightsReopenCorrectsOriginalDayAndRecompletionMovesCredit() throws {
        let t=task();var s=Snapshot(tables:["tasks":[t]])
        let yesterday=now.addingTimeInterval(-86400)
        complete(t,in:&s,at:yesterday)
        XCTAssertEqual(try credit(s).week,1);XCTAssertEqual(try credit(s).today,0)
        record(Mutation(table:"tasks",recordID:t.id,method:"PATCH",fields:["completed":.bool(false),"completed_at":.null]),snapshot:&s)
        XCTAssertEqual(try credit(s).week,0);XCTAssertTrue(try credit(s).credits.isEmpty)
        complete(t,in:&s,at:now)
        let reading=try credit(s);XCTAssertEqual(reading.today,1);XCTAssertEqual(reading.week,1)
        XCTAssertEqual(reading.days.first{$0.id=="2026-10-05"}?.count,0)
    }
    func testInsightsCompletionTimeCorrectionRetainsCompletingActorAndProject() throws {
        let t=task();var s=Snapshot(tables:["tasks":[t]])
        complete(t,in:&s,at:now.addingTimeInterval(-86400))
        record(Mutation(table:"tasks",recordID:t.id,method:"PATCH",fields:["completed_at":.string(TaskActivity.stamp(now))]),snapshot:&s)
        s.tables[TaskActivity.table]![1]["actor_id"] = .string("collaborator")
        let reading=try credit(s);XCTAssertEqual(reading.today,1);XCTAssertEqual(reading.credits.first?.actor,account)
        record(Mutation(table:"tasks",recordID:t.id,method:"PATCH",fields:["project_id":.string("another-project")]),snapshot:&s)
        XCTAssertEqual(try credit(s,projectID:project).today,1)
        XCTAssertEqual(try credit(s,projectID:"another-project").today,0)
    }
    func testInsightsCompletedImportsAndTimeEditsDoNotInventHistoryAndDeletionKeepsRecordedCredit() throws {
        var imported=task();imported["completed"] = .bool(true);imported["completed_at"] = .string(TaskActivity.stamp(now.addingTimeInterval(-86400)))
        var s=Snapshot();record(Mutation(table:"tasks",recordID:imported.id,method:"POST",fields:imported.fields),snapshot:&s)
        record(Mutation(table:"tasks",recordID:imported.id,method:"PATCH",fields:["completed_at":.string(TaskActivity.stamp(now))]),snapshot:&s)
        XCTAssertEqual(try credit(s).today,0)
        let t=task();s=Snapshot(tables:["tasks":[t]]);complete(t,in:&s,at:now)
        record(Mutation(table:"tasks",recordID:t.id,method:"DELETE",fields:[:]),snapshot:&s)
        XCTAssertEqual(try credit(s).today,1);XCTAssertTrue(s.tables["tasks"]!.isEmpty)
    }
    func testInsightsRecurringOccurrencesKeepDistinctCreditsAndUndoCorrectsOne() throws {
        var t=task();t["due_date"] = .string("2026-10-06");t["is_recurring"] = .bool(true);t["recurrence_pattern"] = .object(["type":.string("daily")])
        var s=Snapshot(tables:["tasks":[t]])
        for change in TaskCompletion.toggle(t,tasks:[t],at:now) { record(change,snapshot:&s) }
        let next=try XCTUnwrap(s.tables["tasks"]!.first{$0.id != t.id})
        complete(next,in:&s,at:now)
        XCTAssertEqual(try credit(s).today,2)
        record(Mutation(table:"tasks",recordID:next.id,method:"PATCH",fields:["completed":.bool(false),"completed_at":.null]),snapshot:&s)
        let reading=try credit(s);XCTAssertEqual(reading.today,1);XCTAssertEqual(reading.credits.first?.taskID,t.id.lowercased())
        XCTAssertEqual(try credit(JSONDecoder().decode(Snapshot.self,from:JSONEncoder().encode(s))).credits,reading.credits)
    }
    func testInsightsScopeExcludesForeignWorkAndCountsAccessibleCollaboratorsExplicitly() throws {
        let t=task();var s=Snapshot(tables:["tasks":[t]]);complete(t,in:&s,at:now)
        s.tables[TaskActivity.table]![0]["actor_id"] = .string("collaborator")
        XCTAssertEqual(try credit(s).today,0);XCTAssertEqual(try credit(s,scope:.workspace).today,1)
        s.tables[TaskActivity.table]![0]["user_id"] = .string("another-owner")
        XCTAssertEqual(try credit(s,scope:.workspace).today,0)
        XCTAssertEqual(try credit(s,scope:.workspace,accessible:[project]).today,1)
        s.tables[TaskActivity.table]![0]["actor_id"] = .string(account)
        XCTAssertEqual(try credit(s,accessible:[project]).today,1)
        s.tables[TaskActivity.table]![0]["actor_id"] = .null
        XCTAssertEqual(try credit(s,accessible:[project]).today,0)
    }
    func testInsightsUnknownAndPartialHistoryNeverBecomesACompleteTrackingWindow() throws {
        let t=task();var s=Snapshot(tables:["tasks":[t]])
        complete(t,in:&s,at:now)
        let reading=try credit(s);XCTAssertTrue(reading.hasHistory);XCTAssertEqual(reading.days.last?.coverage,.partial)
        XCTAssertEqual(reading.days.dropLast().last?.coverage,.untracked)
        s.tables[TaskActivity.epochTable]=[]
        let unknown=try credit(s);XCTAssertFalse(unknown.hasHistory);XCTAssertFalse(unknown.reliable);XCTAssertEqual(unknown.today,0)
        s.tables[TaskActivity.epochTable]=[Record(["id":.string("current"),"recorded_from":.string(TaskActivity.stamp(now.addingTimeInterval(1)))])]
        XCTAssertFalse(try credit(s).reliable);XCTAssertEqual(try credit(s).malformed,1)
    }
    func testInsightsLateBackdatedCompletionIsObservedWithPartialCoverageAndFutureEventsAreIgnored() throws {
        let t=task();var s=Snapshot(tables:["tasks":[t]])
        record(Mutation(table:"tasks",recordID:t.id,method:"PATCH",fields:["completed":.bool(true),"completed_at":.string(TaskActivity.stamp(now.addingTimeInterval(-86400)))]),snapshot:&s)
        let r=try credit(s);XCTAssertEqual(r.week,1);XCTAssertEqual(r.days.first{$0.id=="2026-10-05"}?.coverage,.partial)
        s.tables[TaskActivity.table]![0]["recorded_at"] = .string(TaskActivity.stamp(now.addingTimeInterval(1)))
        XCTAssertEqual(try credit(s).week,0)
    }
    func testInsightsConflictInRepeatedHistoryIdentityMarksCountsUnreliable() throws {
        let t=task();var s=Snapshot(tables:["tasks":[t]]);complete(t,in:&s,at:now)
        var conflicting=s.tables[TaskActivity.table]![0];conflicting["actor_id"] = .string("collaborator");s.tables[TaskActivity.table]!.append(conflicting)
        let reading=try credit(s);XCTAssertFalse(reading.reliable);XCTAssertEqual(reading.malformed,1);XCTAssertEqual(reading.today,0)
    }
    func testInsightsUsesSavedCivilZoneAndCalendarDaysAcrossDST() throws {
        let t=task();var s=Snapshot(tables:["tasks":[t]])
        let instant=TaskPlanning.instant("2026-10-25T23:30:00Z")!
        complete(t,in:&s,at:instant.addingTimeInterval(-3600))
        let cph=try credit(s,at:instant,settings:goals());XCTAssertEqual(cph.days.last?.id,"2026-10-26");XCTAssertEqual(cph.today,0);XCTAssertEqual(cph.week,0)
        let utc=try credit(s,at:instant,settings:goals(zone:"UTC"));XCTAssertEqual(utc.days.last?.id,"2026-10-25");XCTAssertEqual(utc.today,1)
        let ends=cph.days.map(\.date);XCTAssertEqual(ends.last!.timeIntervalSince(ends[ends.count-2]),25*3600)
        let spring=TaskPlanning.instant("2026-03-30T10:00:00Z")!
        let r=try credit(Snapshot(),at:spring,settings:goals());XCTAssertEqual(r.days.last!.date.timeIntervalSince(r.days[r.days.count-2].date),23*3600)
    }
    func testProductivityGoalsValidateRestDaysPreserveMetadataAndSurviveEncoding() throws {
        var original=try goals().document.object;original["metadata"] = .object(["preserve":.bool(true)])
        var settings=try ProductivityGoals(document:.object(original));settings.weeklyTarget=25
        let decoded=try ProductivityGoals(document:JSONDecoder().decode(JSON.self,from:JSONEncoder().encode(settings.document)))
        XCTAssertEqual(decoded.weeklyTarget,25);XCTAssertEqual(decoded.document.object["metadata"],original["metadata"])
        XCTAssertEqual(decoded.target(on:now),5)
        XCTAssertNil(decoded.target(on:TaskPlanning.instant("2026-10-11T10:00:00Z")!))
        for (key,value) in [("version",JSON.number(2)),("daily_target",.number(-1)),("weekly_target",.number(1.5)),("week_start",.number(8)),("time_zone",.string("unavailable/zone")),("active_weekdays",.array([.number(2),.number(2)])),("active_weekdays",.array([]))] {
            var bad=original;bad[key]=value;XCTAssertThrowsError(try ProductivityGoals(document:.object(bad)),key)
        }
        settings.activeWeekdays=[];settings.dailyTarget=0;XCTAssertNoThrow(try settings.validated())
        XCTAssertEqual(try ProductivityGoals().dailyTarget,0)
    }
    func testInsightsInvalidGoalDraftDoesNotOverflowOrInventAWindow() throws {
        var invalid=try goals();invalid.weekStart=Int.min;invalid.dailyTarget=Int.max
        let reading=try credit(Snapshot(),settings:invalid);XCTAssertFalse(reading.reliable);XCTAssertEqual(reading.malformed,1);XCTAssertTrue(reading.days.isEmpty)
    }
}

extension TaskActivityTests {
    func testGoalCommandScopesAccountAndPreservesNullBaselineAcrossQueueEncoding() throws {
        let change=try ProductivityGoalEdit.command(goals().document,previous:nil,account:account)
        XCTAssertTrue(ProductivityGoalEdit.valid(change,account:account));XCTAssertFalse(ProductivityGoalEdit.valid(change,account:"another"))
        XCTAssertEqual(change.baseline?[ProductivityGoals.field],.null)
        var s=Snapshot(pending:[change]);s.apply(change)
        let restored=try JSONDecoder().decode(Snapshot.self,from:JSONEncoder().encode(s))
        XCTAssertEqual(ProductivityGoals.row(restored,account:account)?[ProductivityGoals.field],try goals().document)
        XCTAssertEqual(restored.pending,[change]);XCTAssertNil(ProductivityGoals.row(restored,account:"another"))
        XCTAssertThrowsError(try ProductivityGoalEdit.command(goals().document,previous:ProductivityGoalEdit.emptyRow(account:"another"),account:account))
    }
    func testReviewedGoalChoiceKeepsIndependentSyncedMetadataAndTaskHistory() throws {
        var before=try goals().document.object;before["metadata"] = .string("old")
        var original=ProductivityGoalEdit.emptyRow(account:account);original[ProductivityGoals.field] = .object(before)
        var desired=try ProductivityGoals(document:.object(before));desired.dailyTarget=6
        let change=try ProductivityGoalEdit.command(desired.document,previous:original,account:account)
        var remoteDoc=before;remoteDoc["metadata"] = .string("new independent metadata");remoteDoc["weekly_target"] = .number(25)
        var remote=original;remote[ProductivityGoals.field] = .object(remoteDoc);remote["sort_by"] = .string("title")
        let work=task();let snapshot=Snapshot(tables:["view_preferences":[original],"tasks":[work]],pending:[change])
        let result=try XCTUnwrap(SyncConflict(mutation:change,remote:remote).resolving(snapshot,keepLocal:true))
        let reviewed=try XCTUnwrap(result.pending.first)
        XCTAssertEqual(reviewed.baseline?[ProductivityGoals.field],remote[ProductivityGoals.field])
        XCTAssertEqual(reviewed.fields[ProductivityGoals.field]?.object["metadata"],.string("new independent metadata"))
        XCTAssertEqual(reviewed.fields[ProductivityGoals.field]?.object["daily_target"],.number(6))
        XCTAssertEqual(ProductivityGoals.row(result,account:account)?.string("sort_by"),"title")
        XCTAssertEqual(result.tables["tasks"],[work])
    }
    func testUseSyncedGoalChoiceRetainsLaterDraftAndItsGuard() throws {
        var original=ProductivityGoalEdit.emptyRow(account:account);original[ProductivityGoals.field]=try goals().document
        var first=try goals();first.dailyTarget=6
        let initial=try ProductivityGoalEdit.command(first.document,previous:original,account:account)
        var intermediate=original;intermediate[ProductivityGoals.field]=first.document
        var last=first;last.weeklyTarget=30
        let later=try ProductivityGoalEdit.command(last.document,previous:intermediate,account:account)
        var remote=original;var remoteGoals=try goals();remoteGoals.dailyTarget=8;remote[ProductivityGoals.field]=remoteGoals.document
        let s=Snapshot(tables:["view_preferences":[intermediate]],pending:[initial,later])
        let result=try XCTUnwrap(SyncConflict(mutation:initial,remote:remote).resolving(s,keepLocal:false))
        XCTAssertEqual(result.pending,[later]);XCTAssertEqual(result.pending[0].baseline?[ProductivityGoals.field],first.document)
        XCTAssertEqual(ProductivityGoals.row(result,account:account)?[ProductivityGoals.field],last.document)
    }
    func testUnknownGoalVersionsCanBeKeptSyncedButCannotBeOverwrittenByAnOlderDraft() throws {
        var original=ProductivityGoalEdit.emptyRow(account:account);original[ProductivityGoals.field]=try goals().document
        let change=try ProductivityGoalEdit.command(goals().document,previous:original,account:account)
        var remote=original;remote[ProductivityGoals.field] = .object(["version":.number(2),"future":.string("preserve")])
        let s=Snapshot(tables:["view_preferences":[original]],pending:[change]),conflict=SyncConflict(mutation:change,remote:remote)
        XCTAssertNil(conflict.resolving(s,keepLocal:true))
        let synced=try XCTUnwrap(conflict.resolving(s,keepLocal:false));XCTAssertTrue(synced.pending.isEmpty);XCTAssertEqual(ProductivityGoals.row(synced,account:account)?[ProductivityGoals.field],remote[ProductivityGoals.field])
        var futureChange=change;futureChange.fields[ProductivityGoals.field]=remote[ProductivityGoals.field]
        let old=Snapshot(tables:["view_preferences":[original]],pending:[futureChange])
        XCTAssertTrue(try XCTUnwrap(SyncConflict(mutation:futureChange,remote:original).resolving(old,keepLocal:false)).pending.isEmpty)
    }
    func testGoalReviewRejectsForeignScopeAndMissingRemoteRowKeepsCompleteDraft() throws {
        let change=try ProductivityGoalEdit.command(goals().document,previous:nil,account:account)
        let s=Snapshot(pending:[change]);XCTAssertNil(SyncConflict(mutation:change,remote:ProductivityGoalEdit.emptyRow(account:"another")).resolving(s,keepLocal:true))
        let recovered=try XCTUnwrap(SyncConflict(mutation:change,remote:ProductivityGoalEdit.emptyRow(account:account)).resolving(s,keepLocal:true))
        XCTAssertEqual(recovered.pending.first?.baseline?[ProductivityGoals.field],.null)
        XCTAssertEqual(ProductivityGoals.row(recovered,account:account)?[ProductivityGoals.field],try goals().document)
    }
}


extension TaskActivityTests {
    func testInsightsFixtureHasMatchingPersonalGoalsAndWindowsAfterCrossDeviceEncoding() throws {
        let s=Snapshot.insightsFixture(account:account,now:now)
        let restored=try JSONDecoder().decode(Snapshot.self,from:JSONEncoder().encode(s))
        let document=try XCTUnwrap(ProductivityGoals.row(restored,account:account)?[ProductivityGoals.field])
        var deviceCalendar=Calendar(identifier:.gregorian);deviceCalendar.timeZone=TimeZone(identifier:"Asia/Tokyo")!
        let saved=try ProductivityGoals(document:document,calendar:deviceCalendar)
        let reading=try credit(restored,settings:saved);XCTAssertEqual(reading.today,2);XCTAssertEqual(reading.week,2);XCTAssertEqual(reading.days.reduce(0){$0+$1.count},2)
        let longer=InsightsReading(account:account,activity:restored.tables[TaskActivity.table]!,epoch:restored.tables[TaskActivity.epochTable]!,goals:saved,windowDays:28,now:now)
        XCTAssertEqual(longer.days.reduce(0){$0+$1.count},3);XCTAssertTrue(longer.reliable);XCTAssertTrue(longer.days.allSatisfy{$0.coverage == .recorded})
        XCTAssertEqual(saved.timeZone,"UTC");XCTAssertEqual(saved.dailyTarget,5);XCTAssertEqual(saved.weeklyTarget,10)
    }
    func testInsightsWeekStartAndRestDaysDoNotDiscardRecordedWork() throws {
        let t=task();var s=Snapshot(tables:["tasks":[t]])
        complete(t,in:&s,at:TaskPlanning.instant("2026-10-04T10:00:00Z")!)
        var saved=try goals();saved.activeWeekdays=Set(2...6);XCTAssertEqual(try credit(s,settings:saved).week,0)
        saved.weekStart=1;let reading=try credit(s,settings:saved);XCTAssertEqual(reading.week,1)
        XCTAssertEqual(reading.days.first{$0.id=="2026-10-04"}?.count,1);XCTAssertEqual(reading.days.first{$0.id=="2026-10-04"}?.restDay,true)
    }
}


extension TaskActivityTests {
    func testInsightsRecordedDeletionAndRecreationKeepSeparateCompletionLifecycles() throws {
        let t=task();var s=Snapshot(tables:["tasks":[t]])
        complete(t,in:&s,at:now.addingTimeInterval(-10))
        record(Mutation(table:"tasks",recordID:t.id,method:"DELETE",fields:[:]),snapshot:&s)
        let next=task();record(Mutation(table:"tasks",recordID:next.id,method:"POST",fields:next.fields),snapshot:&s)
        complete(next,in:&s,at:now)
        var reading=try credit(s);XCTAssertTrue(reading.reliable);XCTAssertEqual(reading.today,2)
        XCTAssertEqual(Set(reading.credits.map(\.lifecycle)).count,2)
        record(Mutation(table:"tasks",recordID:next.id,method:"PATCH",fields:["completed":.bool(false),"completed_at":.null]),snapshot:&s)
        reading=try credit(s);XCTAssertTrue(reading.reliable);XCTAssertEqual(reading.today,1)
        XCTAssertEqual(reading.credits.first?.date,TaskPlanning.instant(TaskActivity.stamp(now.addingTimeInterval(-10))))
    }
}

extension TaskActivityTests {
    func testInsightsLargeHistoryCountsDistinctRecordedOccurrences() throws {
        let t=task();var seed=Snapshot(tables:["tasks":[t]]);complete(t,in:&seed,at:now)
        let template=seed.tables[TaskActivity.table]![0]
        let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        let rows=(1...5000).map { index -> Record in
            var row=template;row["id"] = .string(UUID().uuidString);row["sequence"] = .number(Double(index));row["task_id"] = .string(String(format:"f1751000-0000-4000-8000-%012d",index))
            let stamp=formatter.string(from:now.addingTimeInterval(-Double(index)))
            row["recorded_at"] = .string(stamp);row["effective_at"] = .string(stamp)
            var after=row["after_state"].object;after["completed_at"] = .string(stamp);row["after_state"] = .object(after);return row
        }
        let epoch=[Record(["id":.string("current"),"recorded_from":.string(TaskActivity.stamp(now.addingTimeInterval(-86400)))])]
        let start=Date();let reading=InsightsReading(account:account,activity:rows,epoch:epoch,goals:try goals(),now:now)
        let elapsed=Date().timeIntervalSince(start);print("INSIGHTS_HISTORY_5000_SECONDS=\(elapsed)")
        XCTAssertTrue(reading.reliable);XCTAssertEqual(reading.today,5000);XCTAssertEqual(reading.week,5000);XCTAssertEqual(reading.credits.count,5000)
    }
}


extension TaskActivityTests {
    func testInsightsCachedParsingMatchesExistingActivityDecoderForOffsetsAndFractionalInstants() throws {
        let t=task();var source=Snapshot(tables:["tasks":[t]]);complete(t,in:&source,at:now)
        for stamp in ["2026-10-06T10:00:00Z","2026-10-06T10:00:00.123456Z","2026-10-06T12:00:00.123+02:00","2026-10-06T15:45:00+05:45"] {
            var snapshot=source,row=source.tables[TaskActivity.table]![0]
            row["recorded_at"] = .string(stamp);row["effective_at"] = .string(stamp)
            var after=row["after_state"].object;after["completed_at"] = .string(stamp);after["due_date"] = .string("2026-10-06");after["deadline_date"] = .string("2026-10-07");row["after_state"] = .object(after)
            var before=row["before_state"].object;before["due_date"] = .string("2026-10-06");before["deadline_date"] = .string("2026-10-07");row["before_state"] = .object(before)
            snapshot.tables[TaskActivity.table]=[row]
            let original=try XCTUnwrap(TaskActivity(row:row)),reading=try credit(snapshot,at:now.addingTimeInterval(2))
            XCTAssertTrue(reading.reliable,stamp);XCTAssertEqual(reading.today,1);XCTAssertEqual(reading.credits.first?.date,original.effectiveAt)
            after["deadline_date"] = .string("2026-02-29");row["after_state"] = .object(after);snapshot.tables[TaskActivity.table]=[row]
            XCTAssertNil(TaskActivity(row:row));XCTAssertFalse(try credit(snapshot,at:now.addingTimeInterval(2)).reliable)
        }
    }
}
