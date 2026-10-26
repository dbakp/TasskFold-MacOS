import XCTest
@testable import TaskfoldCore
@testable import WidgetModel

final class HeadingProjectProgressTests: XCTestCase {
    let project = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa71", owner = "owner"
    let now = TaskPlanning.instant("2026-10-06T10:00:00Z")!
    var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Europe/Copenhagen")!; return value }
    func task(_ id: String, done: Bool = false, heading: Bool = false, children: [Record] = []) -> Record {
        var row = Record(["id": .string(id), "title": .string(id), "completed": .bool(done), "subtasks": .array(children.map { .object($0.fields) })])
        if heading { row["is_heading"] = .bool(true) }; return row
    }
    func root(_ children: [Record], id: String = "root") -> Record {
        var row = task(id, heading: true, children: children)
        row["project_id"] = .string(project); row["user_id"] = .string(owner); row["task_generation"] = .string("generation"); return row
    }
    func reading(_ rows: [Record]) -> ProjectPulseReading { ProjectPulseReading(project: project, tasks: rows, activity: [], now: now, calendar: calendar) }
    func pulse(_ rows: [Record]) throws -> ProjectPulseSnapshot {
        let p = Record(["id": .string(project), "name": .string("Studio")])
        let value = WidgetProjection.pulsePayload(tasks: rows, projects: [p], activity: [], epoch: [], account: owner, readable: true, now: now, calendar: calendar)
        return try JSONDecoder().decode(ProjectPulseSnapshot.self, from: JSONEncoder().encode(value))
    }
    func testNestedHeadingsExposeNearestOrdinaryWorkWithoutDoubleCountingChecklists() {
        let rows = [root([task("open", children: [task("checklist")]), task("done", done: true), task("context", heading: true, children: [task("nested")])])]
        let r = reading(rows); XCTAssertEqual(r.total, 3); XCTAssertEqual(r.completed, 1); XCTAssertFalse(r.countsIncomplete)
        XCTAssertEqual(ProjectWorkScope(tasks: rows).items.map { $0.task.title }, ["open", "done", "nested"])
    }
    func testOrdinaryParentStillCountsOnceIncludingCompletedParentWithOpenChecklist() {
        var row = task("parent", done: true, children: [task("open"), task("context", heading: true, children: [task("nested")])]); row["project_id"] = .string(project)
        let r = reading([row]); XCTAssertEqual(r.total, 1); XCTAssertEqual(r.completed, 1); XCTAssertFalse(r.countsIncomplete)
    }
    func testEmptyHeadingsAddNoUnfinishedWorkOrAttention() throws {
        var row = root([]); row["due_date"] = .string("2026-01-01"); row["deadline_date"] = .string("2026-01-01")
        XCTAssertEqual(reading([row]).total, 0); XCTAssertTrue(ProjectWorkScope(tasks: [row]).attention(project: project, now: now, calendar: calendar).isEmpty)
        XCTAssertEqual(try pulse([row]).projects[0].total, 0)
    }
    func testOnlyContainmentIsInheritedNotHeadingDatesPriorityEstimatesOrAssignment() {
        var child = task("child"); child["priority"] = .number(4); child["project_id"] = .string("foreign-project"); child["user_id"] = .string("foreign-owner")
        var row = root([child]); row["due_date"] = .string("2026-01-01"); row["deadline_date"] = .string("2026-01-01"); row["priority"] = .number(1); row["duration_minutes"] = .number(500); row["assigned_to"] = .string("someone")
        let scope = ProjectWorkScope(tasks: [row]), item = scope.items[0]
        XCTAssertEqual(item.task.string("project_id"), project); XCTAssertEqual(item.task.string("user_id"), owner); XCTAssertEqual(item.task.priority, 4)
        XCTAssertEqual(item.task["due_date"], .null); XCTAssertEqual(item.task["deadline_date"], .null); XCTAssertEqual(item.task["duration_minutes"], .null); XCTAssertEqual(item.task["assigned_to"], .null)
        XCTAssertTrue(scope.attention(project: project, now: now, calendar: calendar).isEmpty)
    }
    func testChildDatesAndCompletionDriveNativeAndWidgetAttentionWithScopedIdentities() throws {
        var due = task("same"), later = task("later"), done = task("done", done: true)
        due["deadline_date"] = .string("2026-10-12"); later["deadline_date"] = .string("2026-10-13"); done["due_date"] = .string("2026-01-01")
        let rows = [root([due,later,done]), root([due], id: "second")]
        let scope = ProjectWorkScope(tasks: rows), attention = scope.attention(project: project, now: now, calendar: calendar)
        XCTAssertEqual(attention.count, 2); XCTAssertEqual(Set(attention.map(\.id)).count, 2)
        let widget = try pulse(rows), p = widget.projects[0], day = p.days["2026-10-06"]!
        XCTAssertEqual(p.total, reading(rows).total); XCTAssertEqual(p.completed, reading(rows).completed)
        XCTAssertEqual(day.attentionCount, 2); XCTAssertEqual(day.attention.map(\.id), attention.map(\.id)); XCTAssertNil(p.countsIncomplete)
    }
    func testKnownChildNavigationUsesExistingHierarchyProjectionWithoutInventingRootRows() throws {
        let row = root([task("context", heading: true, children: [task("child")])])
        let scope = ProjectWorkScope(tasks: [row]), item = scope.items[0]
        let projects = [Record(["id": .string(project), "name": .string("Studio")])]
        let index = try TaskHierarchyIndex(roots: [row], projects: projects, workspace: WorkspaceBinding(account: owner, generation: UUID()))
        let nav = try XCTUnwrap(item.navigationTask); XCTAssertNotEqual(nav.id, item.id)
        XCTAssertEqual(index.item(nav.id)?.record, nav); XCTAssertEqual(SubtaskTree.referencePath(nav.id), [row.id,"context","child"])
        XCTAssertEqual(row["subtasks"].list[0].object["subtasks"]?.list[0].object["id"], .string("child"))
    }
    func testLegacyTextAndMissingIdentitiesRemainCountedWithParentNavigationFallback() {
        var row = root([]); row["subtasks"] = .array([.string("Legacy task"), .object(["title": .string("Without identity"), "completed": .bool(true)])])
        let work = ProjectWorkScope(tasks: [row]); XCTAssertEqual(work.items.count, 2); XCTAssertEqual(reading([row]).completed, 1)
        XCTAssertTrue(work.items.allSatisfy { $0.navigationTask == nil }); XCTAssertFalse(reading([row]).countsIncomplete)
    }
    func testUnsupportedMalformedAndTooDeepBranchesDoNotClaimCompleteProgress() throws {
        var future = task("future"); future["is_heading"] = .string("future")
        var malformed = root([], id: "malformed"); malformed["subtasks"] = .object(["unexpected": .bool(true)])
        var deep = task("leaf"); for index in 0...SubtaskTree.readableDepth { deep = task("h\(index)", heading: true, children: [deep]) }
        let rows = [root([task("done", done: true),future]), malformed, root([deep], id: "deep")]
        let r = reading(rows); XCTAssertTrue(r.countsIncomplete); XCTAssertEqual(r.total, 1); XCTAssertEqual(r.completed, 1)
        let value = try pulse(rows); XCTAssertTrue(value.valid(for: owner)); XCTAssertEqual(value.projects[0].countsIncomplete, true)
    }
    func testDuplicateRootReplayIsDeduplicatedAndConflictingDuplicateFlagsBothProjects() {
        let row = root([task("open")]); XCTAssertEqual(reading([row,row]).total, 1); XCTAssertFalse(reading([row,row]).countsIncomplete)
        var other = row; other["project_id"] = .string("other")
        let scope = ProjectWorkScope(tasks: [row,other]); XCTAssertTrue(scope.incomplete(project: project)); XCTAssertTrue(scope.incomplete(project: "other"))
        XCTAssertEqual(scope.items.count, 1)
    }
    func testChildCompletionUndoAndColdRoundTripChangeCurrentTotalsWithoutInventingHistory() throws {
        let before = root([task("open")]); var after = before; after["subtasks"] = SubtaskTree.changing(after["subtasks"], id: "open", fields: ["completed": .bool(true)])
        XCTAssertEqual(reading([before]).completed, 0); XCTAssertEqual(reading([after]).completed, 1)
        let cold = try JSONDecoder().decode([Record].self, from: JSONEncoder().encode([after]))
        XCTAssertEqual(reading(cold).completed, 1); XCTAssertEqual(reading(cold).completions, 0); XCTAssertTrue(reading(cold).events.isEmpty)
        XCTAssertEqual(reading([before]).completed, 0); XCTAssertEqual(ProjectWorkScope(tasks: [before]).items[0].id, ProjectWorkScope(tasks: cold).items[0].id)
    }
    func testAdditiveIncompleteFlagKeepsExistingWidgetSnapshotsReadable() throws {
        let good = try pulse([root([task("open")])]), bytes = try JSONEncoder().encode(good)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("countsIncomplete"))
        let old = try JSONDecoder().decode(ProjectPulseSnapshot.self, from: bytes); XCTAssertNil(old.projects[0].countsIncomplete); XCTAssertTrue(old.valid(for: owner))
        var json = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]; var projects = json["projects"] as! [[String: Any]]; projects[0]["countsIncomplete"] = "future"; json["projects"] = projects
        XCTAssertThrowsError(try JSONDecoder().decode(ProjectPulseSnapshot.self, from: JSONSerialization.data(withJSONObject: json)))
    }
    func testWideHeadingPreservesEveryTaskWithoutRepeatedSiblingScans() {
        let start = Date(), row = root((0..<10_000).map { task("task-\($0)", done: $0 % 2 == 0) })
        let work = ProjectWorkScope(tasks: [row]); XCTAssertEqual(work.items.count, 10_000); XCTAssertEqual(work.items.filter { $0.task.completed }.count, 5_000)
        XCTAssertFalse(work.incomplete(project: project)); print("HEADING_PROJECT_10000_SECONDS=\(Date().timeIntervalSince(start))")
    }
}
