import XCTest
@testable import TaskfoldCore

final class WorkHistoryTests: XCTestCase {
    let account = "11111111-1111-4111-8111-111111111111", project = "22222222-2222-4222-8222-222222222222"
    let rootID = "33333333-3333-4333-8333-333333333333", generation = "44444444-4444-4444-8444-444444444444", key = "55555555-5555-4555-8555-555555555555"
    let now = TaskPlanning.instant("2026-10-26T12:00:00Z")!
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .gmt; return c }
    var epoch: [Record] { [Record(["id": .string("current"), "recorded_from": .string("2026-10-01T00:00:00Z")])] }
    func root(done: Bool = false, heading: Bool = true, revision: Int = 0) -> Record {
        var r = Record.task(user: account, project: project); r["id"] = .string(rootID); r["task_generation"] = .string(generation); r["is_heading"] = .bool(heading)
        r["subtasks"] = .array([.object(["id": .string(key), "title": .string("Current child title"), "completed": .bool(done), "completed_at": done ? .string(TaskActivity.stamp(now)) : .null, "completion_version": .number(Double(revision)), "subtasks": .array([])])]); return r
    }
    func children(_ before: Record?, _ after: Record?, sequence: Int64 = 0, at: Date? = nil) -> [Record] {
        let r = after ?? before!; return TaskNodeActivity.localRows(Mutation(table: "tasks", recordID: r.id, method: before == nil ? "POST" : after == nil ? "DELETE" : "PATCH", fields: after?.fields ?? [:]), before: before, after: after, account: account, recordedAt: at ?? now, afterSequence: sequence)
    }
    func parent(_ before: Record?, _ after: Record?) throws -> Record {
        let r = after ?? before!; var s = Snapshot(); TaskActivity.recordLocal(Mutation(table: "tasks", recordID: r.id, method: before == nil ? "POST" : after == nil ? "DELETE" : "PATCH", fields: after?.fields ?? [:]), before: before, after: after, snapshot: &s, account: account, now: now)
        return try XCTUnwrap(s.tables[TaskActivity.table]?.first)
    }
    func insights(_ rows: [Record]?, rootRows: [Record] = [], childEpoch: [Record]? = nil, rootEpoch: [Record]? = nil, scope: InsightsReading.Scope = .mine) throws -> InsightsReading {
        var goals = try ProductivityGoals(); goals.timeZone = "UTC"
        return InsightsReading(account: account, activity: rootRows, epoch: rootEpoch ?? epoch, goals: goals, scope: scope, accessibleProjects: [project], now: now, children: ChildWorkHistory(rows: rows, epoch: childEpoch ?? epoch))
    }
    func testSeparateFeedSequencesAndUUIDsNeverCollideOrDoubleCount() throws {
        let child = try XCTUnwrap(children(root(), root(done: true, revision: 1)).first)
        var a = root(heading: false); a["id"] = .string(UUID().uuidString.lowercased()); var b = a; b["completed"] = .bool(true); b["completed_at"] = .string(TaskActivity.stamp(now))
        var p = try parent(a, b); p["id"] = child["id"]; p["sequence"] = child["sequence"]
        let reading = try insights([child, child], rootRows: [p, p])
        XCTAssertEqual(reading.today, 2); XCTAssertEqual(reading.malformed, 0)
        let pulse = ProjectPulseReading(project: project, tasks: [], activity: [p], now: now, children: .init(rows: [child], epoch: epoch))
        XCTAssertEqual(pulse.completions, 2); XCTAssertEqual(Set(pulse.timeline.map(\.id)).count, 2)
    }
    func testChildUndoRedoCorrectsOneCreditAndCountsActualEvents() throws {
        let a = root(), b = root(done: true, revision: 1), c = root(revision: 2), d = root(done: true, revision: 3)
        let rows = children(a, b) + children(b, c, sequence: 1) + children(c, d, sequence: 2)
        XCTAssertEqual(try insights(Array(rows.prefix(2))).today, 0); XCTAssertEqual(try insights(rows).today, 1)
        let pulse = ProjectPulseReading(project: project, tasks: [d], activity: [], now: now, children: .init(rows: rows, epoch: epoch))
        XCTAssertEqual(pulse.completions, 2); XCTAssertEqual(pulse.reopens, 1); XCTAssertEqual(pulse.total, 1); XCTAssertEqual(pulse.completed, 1)
    }
    func testCompletionCorrectionRetainsOriginalActorAndProject() throws {
        let a = root(), b = root(done: true, revision: 1); var c = b; var fields = c["subtasks"].list[0].object
        fields["completed_at"] = .string("2026-10-25T08:00:00Z"); fields["completion_version"] = .number(2); c["subtasks"] = .array([.object(fields)])
        var correction = try XCTUnwrap(children(b, c, sequence: 1).first); correction["actor_id"] = .string(UUID().uuidString.lowercased())
        let r = try insights(children(a, b) + [correction]); XCTAssertEqual(r.today, 0); XCTAssertEqual(r.credits.count, 1); XCTAssertEqual(r.credits.first?.actor, account); XCTAssertEqual(r.credits.first?.projectID, project)
    }
    func testOrdinaryChecklistDetailsHeadingsAndCompletedImportsEarnNoCredit() throws {
        XCTAssertEqual(try insights(children(root(heading: false), root(done: true, heading: false))).today, 0)
        XCTAssertEqual(try insights(children(nil, root(done: true))).today, 0)
        let rows = children(root(done: true, heading: false), root(done: true), sequence: 1)
        XCTAssertEqual(try insights(rows).today, 0)
        let pulse = ProjectPulseReading(project: project, tasks: [], activity: [], now: now, children: .init(rows: rows, epoch: epoch))
        XCTAssertEqual(pulse.completions, 0); XCTAssertEqual(pulse.additions, 0)
    }
    func testDemotionRetainsGenuineCreditAndDetailReopenCannotUndoIt() throws {
        let a = root(), b = root(done: true, revision: 1), c = root(done: true, heading: false, revision: 1), d = root(heading: false, revision: 2)
        let rows = children(a, b) + children(b, c, sequence: 1) + children(c, d, sequence: 2)
        XCTAssertEqual(try insights(rows).today, 1)
        let promoted = root(revision: 2), completed = root(done: true, revision: 3)
        XCTAssertEqual(try insights(rows + children(d, promoted, sequence: 3) + children(promoted, completed, sequence: 4)).today, 2)
    }
    func testDeletionAndNewRootGenerationKeepIndependentCredits() throws {
        let a = root(), b = root(done: true, revision: 1)
        var c = root(), d = root(done: true, revision: 1); let next = UUID().uuidString.lowercased(); c["task_generation"] = .string(next); d["task_generation"] = .string(next)
        let rows = children(a, b) + children(b, nil, sequence: 1) + children(nil, c, sequence: 2) + children(c, d, sequence: 3)
        XCTAssertEqual(try insights(rows).today, 2)
    }
    func testUnavailableChildHistoryPreservesRootProgressWithPartialDays() throws {
        var a = root(heading: false), b = a; a["subtasks"] = .array([]); b = a; b["completed"] = .bool(true); b["completed_at"] = .string(TaskActivity.stamp(now))
        let r = try insights(nil, rootRows: [parent(a, b)])
        XCTAssertEqual(r.today, 1); XCTAssertTrue(r.reliable); XCTAssertTrue(r.historyIncomplete); XCTAssertEqual(r.days.last?.coverage, .partial)
    }
    func testChildOnlyHistoryWorksAndDifferentEpochsStayPartial() throws {
        let rows = children(root(), root(done: true, revision: 1))
        let only = try insights(rows, rootEpoch: []); XCTAssertEqual(only.today, 1); XCTAssertTrue(only.historyIncomplete); XCTAssertTrue(only.hasHistory)
        let late = [Record(["id": .string("current"), "recorded_from": .string("2026-10-25T08:00:00Z")])]
        let r = try insights(rows, childEpoch: late); XCTAssertEqual(r.days.dropLast(2).last?.coverage, .partial); XCTAssertEqual(r.days.last?.coverage, .recorded)
    }
    func testConflictingChildIdentityIsQuarantinedWithoutDiscardingRootHistory() throws {
        let row = try XCTUnwrap(children(root(), root(done: true, revision: 1)).first); var conflict = row; conflict["actor_id"] = .string(UUID().uuidString.lowercased())
        let reading = ChildWorkReading(.init(rows: [row, conflict], epoch: epoch), now: now)
        XCTAssertTrue(reading.incomplete); XCTAssertTrue(reading.credits().isEmpty); XCTAssertEqual(reading.malformed, 1)
    }
    func testGapRetiresUncertainActiveCreditButLaterGenuineCompletionRecovers() throws {
        let a = root(), b = root(done: true, revision: 1); var malformed = b; malformed["subtasks"] = .object(["future": .bool(true)])
        let gap = children(b, malformed, sequence: 1)
        XCTAssertEqual(TaskNodeActivity(row: try XCTUnwrap(gap.first))?.kinds, [.coverage_gap])
        let r = try insights(children(a, b) + gap); XCTAssertEqual(r.today, 0); XCTAssertTrue(r.historyIncomplete)
        let recovered = try insights(children(a, b) + gap + children(root(revision: 2), root(done: true, revision: 3), sequence: 2))
        XCTAssertEqual(recovered.today, 1); XCTAssertTrue(recovered.historyIncomplete)
    }
    func testActorScopeAndUnavailableActorsAreExplicit() throws {
        var row = try XCTUnwrap(children(root(), root(done: true, revision: 1)).first); row["actor_id"] = .null
        XCTAssertEqual(try insights([row]).today, 0); XCTAssertEqual(try insights([row], scope: .workspace).today, 1)
        let work = WorkActivity.child(try XCTUnwrap(TaskNodeActivity(row: row)))
        XCTAssertEqual(work.context(project: project, tasks: [], projects: [Record(["id": .string(project)])], members: [], account: account).actor, "Name unavailable")
    }
    func testFreshChildRouteRejectsRecreatedOwnerAndFindsCurrentStableKey() throws {
        let row = try XCTUnwrap(children(root(), root(done: true, revision: 1)).first), event = WorkActivity.child(try XCTUnwrap(TaskNodeActivity(row: row)))
        let projects = [Record(["id": .string(project), "name": .string("Studio")])]
        XCTAssertNotNil(event.context(project: project, tasks: [root(done: true)], projects: projects, members: [], account: account).task)
        var other = root(); other["task_generation"] = .string(UUID().uuidString.lowercased())
        XCTAssertNil(event.context(project: project, tasks: [other], projects: projects, members: [], account: account).task)
        other = root(); other["user_id"] = .string(UUID().uuidString.lowercased())
        XCTAssertNil(event.context(project: project, tasks: [other], projects: projects, members: [], account: account).task)
    }
    func testWidgetAndNativeCountsShareHistoryAndNoPrivateLedgerLeavesApp() throws {
        let rows = children(root(), root(done: true, revision: 1)), projects = [Record(["id": .string(project), "name": .string("Studio")])]
        let data = WidgetProjection.pulsePayload(tasks: [root(done: true)], projects: projects, activity: [], epoch: epoch, account: account, readable: true, now: now, calendar: calendar, children: .init(rows: rows, epoch: epoch))
        let widget = try JSONDecoder().decode(ProjectPulseSnapshot.self, from: JSONEncoder().encode(data)), card = try XCTUnwrap(widget.projects.first)
        XCTAssertEqual(card.days["2026-10-26"]?.completions, 1); XCTAssertEqual(card.total, 1); XCTAssertEqual(card.completed, 1)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(data), as: UTF8.self).contains("before_state"))
    }
    func testFiveThousandIndependentCompletionsRemainBounded() throws {
        let template = try XCTUnwrap(children(root(), root(done: true, revision: 1)).first)
        let rows = (0..<5000).map { i -> Record in var r = template; r["id"] = .string(UUID().uuidString.lowercased()); r["sequence"] = .number(Double(i+1)); let key = "node-\(i)"; r["node_key"] = .string(key); r["before_path"] = .array([.string(key)]); r["after_path"] = .array([.string(key)]); return r }
        let start = Date(), result = try insights(rows); let seconds = Date().timeIntervalSince(start)
        XCTAssertEqual(result.today, 5000); XCTAssertLessThan(seconds, 10); print("WORK_HISTORY_5000_SECONDS=\(seconds)")
    }
    func testRootDemotionPreservesPriorCreditWithoutInventingAReopen() throws {
        var a = root(heading: false); a["subtasks"] = .array([])
        var b = a; b["completed"] = .bool(true); b["completed_at"] = .string(TaskActivity.stamp(now)); b["completion_version"] = .number(1)
        var c = b; c["is_heading"] = .bool(true); c["completed"] = .bool(false); c["completed_at"] = .null; c["completion_version"] = .number(2)
        var demotion = try parent(b, c); demotion["sequence"] = .number(2)
        let rows = try [parent(a, b), demotion]
        XCTAssertEqual(try insights([], rootRows: rows).today, 1)
        let pulse = ProjectPulseReading(project: project, tasks: [c], activity: rows, now: now, children: .init(rows: [], epoch: epoch))
        XCTAssertEqual(pulse.reopens, 0); XCTAssertEqual(WorkActivity.root(try XCTUnwrap(TaskActivity(row: demotion))).title, "Type changed")
    }
    func testTimelineUsesReceiptTimesRatherThanComparingIndependentSequences() throws {
        var child = try XCTUnwrap(children(root(), root(done: true, revision: 1), at: now.addingTimeInterval(-60)).first)
        child["sequence"] = .number(999)
        var a = root(heading: false); a["subtasks"] = .array([]); var b = a; b["completed"] = .bool(true); b["completed_at"] = .string(TaskActivity.stamp(now))
        let p = try parent(a, b), pulse = ProjectPulseReading(project: project, tasks: [], activity: [p], now: now, children: .init(rows: [child], epoch: epoch))
        XCTAssertFalse(try XCTUnwrap(pulse.timeline.first).isChild)
        var future = child; future["recorded_at"] = .string(TaskActivity.stamp(now.addingTimeInterval(60)))
        XCTAssertTrue(ChildWorkReading(.init(rows: [future], epoch: epoch), now: now).events.isEmpty)
    }
    func testKnownGapDoesNotMarkAnotherProjectsHistoryPartial() throws {
        var broken = root(); broken["subtasks"] = .object(["future": .bool(true)])
        let rows = children(root(), broken)
        let history = ChildWorkReading(.init(rows: rows, epoch: epoch), now: now)
        XCTAssertTrue(history.incomplete(project: project)); XCTAssertFalse(history.incomplete(project: "unrelated"))
        let projects = [Record(["id": .string(project), "name": .string("Needs review")]), Record(["id": .string("unrelated"), "name": .string("Clear")])]
        let data = WidgetProjection.pulsePayload(tasks: [], projects: projects, activity: [], epoch: epoch, account: account, readable: true, now: now, calendar: calendar, children: .init(rows: rows, epoch: epoch))
        let snapshot = try JSONDecoder().decode(ProjectPulseSnapshot.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(snapshot.projects.first { $0.recordID == project }?.historyPartial, true)
        XCTAssertNil(snapshot.projects.first { $0.recordID == "unrelated" }?.historyPartial)
    }
    func testActualRetainedSQLHistoryKeepsChildWorkAndUnknownActors() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "reviewed-history-custody", withExtension: "json", subdirectory: "Fixtures"))
        let tables = try JSONDecoder().decode([String: [Record]].self, from: Data(contentsOf: url))
        let rootRows = tables["root"]!, rows = tables["child"]!
        let events = try rows.map { try XCTUnwrap(TaskNodeActivity(row: $0)) }
        let cutoff = try XCTUnwrap(events.map(\.recordedAt).max()).addingTimeInterval(60)
        let epoch = [Record(["id": .string("current"), "recorded_from": .string(TaskActivity.stamp(cutoff.addingTimeInterval(-86400)))])]
        var goals = try ProductivityGoals(); goals.timeZone = "UTC"
        let scopes = Set(events.flatMap { [$0.before["project_id"]?.text, $0.after["project_id"]?.text].compactMap { $0 } })
        let reading = InsightsReading(account: account, activity: rootRows, epoch: epoch, goals: goals, scope: .workspace, accessibleProjects: scopes, now: cutoff, children: .init(rows: rows, epoch: epoch))
        XCTAssertEqual(reading.credits.count, 1); XCTAssertNil(reading.credits.first?.actor)
        XCTAssertTrue(reading.credits.first?.taskID.hasPrefix("child:") == true)
    }

    func testWidgetKeepsAvailableFeedCountsWhenTheOtherFeedIsMissing() throws {
        let projects = [Record(["id": .string(project), "name": .string("Studio")])]
        var a = root(heading: false); a["subtasks"] = .array([]); var b = a; b["completed"] = .bool(true); b["completed_at"] = .string(TaskActivity.stamp(now))
        let rootRow = try parent(a, b)
        let parentData = WidgetProjection.pulsePayload(tasks: [], projects: projects, activity: [rootRow], epoch: epoch, account: account, readable: true, now: now, calendar: calendar, children: .init(rows: nil, epoch: nil))
        let parentWidget = try JSONDecoder().decode(ProjectPulseSnapshot.self, from: JSONEncoder().encode(parentData))
        XCTAssertEqual(parentWidget.history, "ready"); XCTAssertEqual(parentWidget.projects.first?.historyPartial, true); XCTAssertEqual(parentWidget.projects.first?.days["2026-10-26"]?.completions, 1)
        let childData = WidgetProjection.pulsePayload(tasks: [root(done: true)], projects: projects, activity: [], epoch: [], account: account, readable: true, now: now, calendar: calendar, children: .init(rows: children(root(), root(done: true, revision: 1)), epoch: epoch))
        let childWidget = try JSONDecoder().decode(ProjectPulseSnapshot.self, from: JSONEncoder().encode(childData))
        XCTAssertEqual(childWidget.history, "ready"); XCTAssertEqual(childWidget.projects.first?.historyPartial, true); XCTAssertEqual(childWidget.projects.first?.days["2026-10-26"]?.completions, 1)
    }

    func testUnsupportedNodeIdentityCannotLeaveAnUnverifiedActiveCredit() throws {
        let valid = try XCTUnwrap(children(root(), root(done: true, revision: 1)).first)
        var bad = valid; bad["id"] = .string(UUID().uuidString.lowercased()); bad["sequence"] = .number(2); bad["node_key"] = .null
        var other = valid; other["id"] = .string(UUID().uuidString.lowercased()); other["task_id"] = .string(UUID().uuidString.lowercased()); other["sequence"] = .number(3)
        let reading = try insights([valid, bad, other])
        XCTAssertEqual(reading.today, 1); XCTAssertTrue(reading.historyIncomplete)
        XCTAssertEqual(reading.credits.first?.taskID.contains(other.string("task_id")), true)
    }

}
