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
    func testOrdinaryChecklistDetailsHeadingsAndCompletedImportsEarnNoCredit() throws {
        XCTAssertEqual(try insights(children(root(heading: false), root(done: true, heading: false))).today, 0)
        XCTAssertEqual(try insights(children(nil, root(done: true))).today, 0)
        let rows = children(root(done: true, heading: false), root(done: true), sequence: 1)
        XCTAssertEqual(try insights(rows).today, 0)
        let pulse = ProjectPulseReading(project: project, tasks: [], activity: [], now: now, children: .init(rows: rows, epoch: epoch))
        XCTAssertEqual(pulse.completions, 0); XCTAssertEqual(pulse.additions, 0)
    }
    func testUnavailableChildHistoryPreservesRootProgressWithPartialDays() throws {
        var a = root(heading: false), b = a; a["subtasks"] = .array([]); b = a; b["completed"] = .bool(true); b["completed_at"] = .string(TaskActivity.stamp(now))
        let r = try insights(nil, rootRows: [parent(a, b)])
        XCTAssertEqual(r.today, 1); XCTAssertTrue(r.reliable); XCTAssertTrue(r.historyIncomplete); XCTAssertEqual(r.days.last?.coverage, .partial)
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

}
