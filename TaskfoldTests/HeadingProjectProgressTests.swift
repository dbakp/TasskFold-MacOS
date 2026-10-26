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

extension HeadingProjectProgressTests {
    func testProductivePlannerUsesChildPlansWithoutHeadingOrChecklistDoubleCounts() throws {
        var first = task("first", children: [task("checklist")]), second = task("second"), done = task("done", done: true)
        for row in [0, 1, 2] {
            var value = [first, second, done][row]; value["due_date"] = .string("2026-10-06"); value["duration_minutes"] = .number(Double([30, 45, 90][row]))
            if row == 0 { first = value }; if row == 1 { second = value }; if row == 2 { done = value }
        }
        first["due_time"] = .string("09:00")
        var parent = root([first, task("nested", heading: true, children: [second,done])])
        parent["due_date"] = .string("2026-10-06"); parent["duration_minutes"] = .number(999)
        let read = ProductiveTaskReading(tasks: [parent])
        XCTAssertEqual(read.work.map(\.title), ["first","second","done"]); XCTAssertEqual(read.parents[read.work[1].id], "root › nested")
        XCTAssertTrue(read.presentation.contains { $0.id == parent.id }); XCTAssertFalse(read.incomplete)
        let capacity = TaskPlanner.capacity([parent], events: [], on: now, hours: WorkingHours(), calendar: calendar)
        XCTAssertEqual(capacity.estimatedMinutes, 75); XCTAssertEqual(capacity.unknownTasks, 0); XCTAssertFalse(capacity.incomplete)
        XCTAssertEqual(TaskPlanner.blocks(read.presentation, on: now, calendar: calendar).map { $0.task.title }, ["first"])
    }
    func testProductivePlanningDoesNotInheritDatesOrEstimatesAndKeepsOrdinaryParentWork() {
        var parent = root([task("undated")]); parent["due_date"] = .string("2026-10-06"); parent["duration_minutes"] = .number(80)
        var ordinary = task("ordinary", children: [task("checklist")]); ordinary["due_date"] = .string("2026-10-06"); ordinary["duration_minutes"] = .number(20)
        let value = TaskPlanner.capacity([parent, ordinary], events: [], on: now, hours: WorkingHours(), calendar: calendar)
        XCTAssertEqual(value.estimatedMinutes, 20); XCTAssertEqual(value.unknownTasks, 0)
        XCTAssertNil(ProductiveTaskReading(tasks: [parent]).work.first?.due)
    }
    func testAlreadyProjectedInputsDoNotDoubleCountAndKeepNativeReferences() throws {
        let parent = root([task("child")]), reading = ProductiveTaskReading(tasks: [parent])
        let nested = try XCTUnwrap(reading.work.first)
        XCTAssertEqual(SubtaskTree.referencePath(nested.id), [parent.id,"child"])
        XCTAssertEqual(ProductiveTaskReading(tasks: reading.presentation).work, reading.work)
        XCTAssertEqual(ProductiveTaskReading(tasks: [nested]).work, [nested])
        XCTAssertEqual(ProductiveTaskReading(tasks: [parent,nested,nested,parent]).work, [nested])
    }
    func testLegacyAndFutureGroupedWorkNeverClaimSpareCapacity() throws {
        var parent = root([]); parent["subtasks"] = .array([.object(["title": .string("No identity"), "due_date": .string("2026-10-06"), "duration_minutes": .number(25)]), .string("Legacy")])
        let reading = ProductiveTaskReading(tasks: [parent]); XCTAssertEqual(reading.unavailable, 2); XCTAssertTrue(reading.incomplete)
        XCTAssertEqual(reading.presentation.map(\.id), [parent.id]); XCTAssertEqual(reading.work.count, 2)
        let capacity = TaskPlanner.capacity([parent], events: [], on: now, hours: WorkingHours(), calendar: calendar)
        XCTAssertEqual(capacity.estimatedMinutes, 25); XCTAssertTrue(capacity.incomplete)
        var future = task("future"); future["is_heading"] = .string("future")
        XCTAssertTrue(ProductiveTaskReading(tasks: [root([future])]).incomplete)
        let bytes = try JSONEncoder().encode(WidgetProjection.payload(tasks: [parent], projects: [], account: owner, now: now, calendar: calendar))
        let widget = try JSONDecoder().decode(WidgetSnapshot.self, from: bytes).capacityReading(at: now, calendar: calendar)
        XCTAssertEqual(widget.state, "work"); XCTAssertFalse(widget.canCalculateRoom); XCTAssertEqual(widget.day?.estimated, 25)
    }
    func testCapacityWidgetSharesChildWorkOverdueAndUnknownEstimates() throws {
        var today = task("today"), unknown = task("unknown"), past = task("past"), done = task("done", done: true)
        today["due_date"] = .string("2026-10-06"); today["duration_minutes"] = .number(40)
        unknown["due_date"] = .string("2026-10-06"); unknown["due_time"] = .string("10:00")
        past["due_date"] = .string("2026-10-05"); done["due_date"] = .string("2026-10-05")
        let parent = root([today,unknown,past,done])
        let payload = WidgetProjection.payload(tasks: [parent], projects: [Record(["id": .string(project), "name": .string("Studio")])], account: owner, now: now, calendar: calendar)
        let bytes = try JSONEncoder().encode(payload)
        let widget = try JSONDecoder().decode(WidgetSnapshot.self, from: bytes).capacityReading(at: now, calendar: calendar)
        let native = TaskPlanner.capacity([parent], events: [], on: now, hours: WorkingHours(), calendar: calendar)
        XCTAssertEqual(widget.day?.estimated, native.estimatedMinutes); XCTAssertEqual(widget.day?.unknown, 1); XCTAssertEqual(widget.day?.overdue, 1)
        XCTAssertNil(widget.day?.workIncomplete); XCTAssertTrue(widget.canCalculateRoom)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("workIncomplete"))
    }
    func testProductiveCacheInvalidatesOnCompletionAndProjectVisibility() throws {
        let a = root([task("a")]), b = root([task("b")], id: "second"), cache = TaskCache(); cache.update([a,b])
        XCTAssertEqual(cache.productiveReading().work.count, 2)
        XCTAssertTrue(cache.productiveReading(excluding: [project]).work.isEmpty)
        XCTAssertEqual(cache.productiveReading().work.count, 2)
        var changed = a; changed["subtasks"] = SubtaskTree.changing(a["subtasks"], id: "a", fields: ["completed": .bool(true)])
        cache.update([changed]); XCTAssertEqual(cache.productiveReading().work.filter(\.completed).count, 1)
    }
    func testProductivePlannerActionsPatchOnlyRealRootAndPreserveChildIdentity() throws {
        var child = task("child"); child["due_date"] = .string("2026-10-06"); child["duration_minutes"] = .number(20)
        let parent = root([child]), reading = ProductiveTaskReading(tasks: [parent]), selected = try XCTUnwrap(reading.work.first)
        let workspace = WorkspaceBinding(account: owner, generation: UUID()), projects = [Record(["id": .string(project)])]
        let fields: [String: JSON] = ["duration_minutes": .number(35), "due_time": .string("11:00")]
        let edits = try TaskSelectionPlan.changes([.init(task: selected, action: .patch(fields), workspace: workspace)], accessibleRoots: [parent], projects: projects, workspace: workspace)
        XCTAssertEqual(edits.map(\.recordID), [parent.id]); XCTAssertEqual(Set(edits[0].fields.keys), ["subtasks"])
        let after = edits[0].fields["subtasks"]!.list[0].object
        XCTAssertEqual(after["id"], child["id"]); XCTAssertNil(after["project_id"]); XCTAssertEqual(after["duration_minutes"], .number(35))
        XCTAssertEqual(after["due_date"], child["due_date"])
        let history = EditHistory(changes: edits, snapshot: Snapshot(tables: ["tasks": [parent]]))
        var snapshot = Snapshot(tables: ["tasks": [parent]])
        edits.forEach { snapshot.apply($0) }; history.undo.forEach { snapshot.apply($0) }
        XCTAssertEqual(snapshot.tables["tasks"]?.first?["subtasks"], parent["subtasks"])
        var replaced = parent; replaced["task_generation"] = .string("replacement")
        XCTAssertThrowsError(try TaskSelectionPlan.changes([.init(task: selected, action: .patch(fields), workspace: workspace)], accessibleRoots: [replaced], projects: projects, workspace: workspace))
        var converted = parent; converted["is_heading"] = .bool(false)
        XCTAssertEqual(ProductiveTaskReading(tasks: [converted]).work.map(\.id), [parent.id])
    }
}

extension HeadingProjectProgressTests {
    func testDatedNestedHeadingStaysContextWithoutAddingEstimatedWork() {
        var nested = task("phase", heading: true, children: [task("child")]); nested["due_date"] = .string("2026-10-06"); nested["duration_minutes"] = .number(100)
        let parent = root([nested]), reading = ProductiveTaskReading(tasks: [parent])
        XCTAssertEqual(reading.work.map(\.title), ["child"])
        XCTAssertEqual(reading.presentation.filter { TaskKind($0) == .heading }.map(\.title), ["root","phase"])
        XCTAssertEqual(TaskPlanner.allDay(reading.presentation, on: now, calendar: calendar).map(\.title), ["phase"])
        XCTAssertEqual(TaskPlanner.capacity([parent], events: [], on: now, hours: WorkingHours(), calendar: calendar).estimatedMinutes, 0)
    }
    func testGroupedFixedTimeWorkClipsAcrossMidnightAndSharesWidgetDayTotals() throws {
        var child = task("travel"); child["due_date"] = .string("2026-10-05"); child["due_time"] = .string("23:30"); child["duration_minutes"] = .number(90)
        let parent = root([child]), reading = ProductiveTaskReading(tasks: [parent])
        let native = TaskPlanner.capacity([parent], events: [], on: now, hours: WorkingHours(), calendar: calendar)
        XCTAssertEqual(native.estimatedMinutes, 60)
        XCTAssertEqual(TaskPlanner.blocks(reading.presentation, on: now, calendar: calendar).first?.length, 60)
        let payload = WidgetProjection.payload(tasks: [parent], projects: [], account: owner, now: now, calendar: calendar)
        let widget = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(payload)).capacityReading(at: now, calendar: calendar)
        XCTAssertEqual(widget.day?.estimated, 60); XCTAssertEqual(widget.day?.overdue, 0)
    }
}


extension HeadingProjectProgressTests {
    func testHeadingContextDoesNotCreateWorkConflicts() {
        var context = root([]), child = task("child")
        for key in ["due_date", "due_time"] { context[key] = .string(key == "due_date" ? "2026-10-06" : "10:00"); child[key] = context[key] }
        context["duration_minutes"] = .number(60)
        XCTAssertTrue(TaskPlanner.conflicts(task: child, start: TaskPlanning.start(child, calendar: calendar)!, minutes: 30, tasks: [context,child], events: [], calendar: calendar).isEmpty)
        XCTAssertTrue(TaskPlanner.conflicts(task: context, start: TaskPlanning.start(child, calendar: calendar)!, minutes: 60, tasks: [context,child], events: [], calendar: calendar).isEmpty)
    }
}

extension HeadingProjectProgressTests {
    func testTodayAndUpcomingMatchEachChildsOwnPlanAndPriorityWithDatedContext() {
        var first = task("first"), later = task("later"), urgent = task("urgent"), complete = task("done", done: true)
        first["due_date"] = .string("2026-10-05"); first["priority"] = .number(4)
        later["due_date"] = .string("2026-10-07"); later["priority"] = .number(1)
        urgent["due_date"] = .string("2026-10-06"); urgent["priority"] = .number(1)
        complete["due_date"] = .string("2026-10-06")
        var parent = root([first,later,urgent,complete,task("undated")]); parent["due_date"] = .string("2026-10-01"); parent["priority"] = .number(2)
        let cache = TaskCache(); cache.update([parent])
        let today = cache.matching(TaskQuery(scope: .today, today: "2026-10-06", timeZone: calendar.timeZone.identifier))
        XCTAssertEqual(today.map(\.title), ["urgent","root","first"])
        XCTAssertEqual(today.filter(TaskKind.mayComplete).count, 2)
        XCTAssertTrue(today.filter(TaskKind.mayComplete).allSatisfy { SubtaskTree.referencePath($0.id) != nil })
        let next = cache.matching(TaskQuery(scope: .upcoming, today: "2026-10-06", selectedDay: "2026-10-07", timeZone: calendar.timeZone.identifier))
        XCTAssertEqual(next.map(\.title), ["later"])
        var search = TaskQuery(scope: .today, text: "urgent", today: "2026-10-06"); search.priority = 1
        XCTAssertEqual(cache.matching(search).map(\.title), ["urgent"])
    }
    func testDatedQueriesRetainOrdinaryChecklistAndExplicitHierarchyFilterSemantics() throws {
        var ordinary = task("ordinary", children: [task("checklist")]); ordinary["due_date"] = .string("2026-10-06")
        var child = task("child"); child["due_date"] = .string("2026-10-06")
        let parent = root([child]), cache = TaskCache(); cache.update([ordinary,parent])
        XCTAssertEqual(Set(cache.matching(TaskQuery(scope: .today, today: "2026-10-06")).map(\.title)), ["ordinary","child"])
        XCTAssertEqual(Set(cache.matching(TaskQuery(scope: .project(project))).map(\.title)), [parent.title,"child"])
        XCTAssertEqual(cache.matching(TaskQuery(scope: .all)).count, 3)
        XCTAssertEqual(cache.matching(TaskQuery(scope: .inbox)).map(\.id), [ordinary.id])
        var parser = try FilterParser("subtask", context: FilterContext(projects: [Record(["id": .string(project), "name": .string("Studio")])], sections: [], labels: [], userID: owner))
        let rule = try parser.parse()
        let explicit = cache.matching(TaskQuery(scope: .saved("explicit"), filter: rule, filterProjects: [FilterReference(id: project,name:"Studio")], userID: owner))
        XCTAssertEqual(Set(explicit.map(\.title)), ["checklist","child"])
    }
    func testDatedQueriesInvalidateAfterCompletionTypeConversionAndPlanChanges() {
        var child = task("child"); child["due_date"] = .string("2026-10-06")
        let parent = root([child]), cache = TaskCache(), query = TaskQuery(scope: .today, today: "2026-10-06")
        cache.update([parent]); XCTAssertEqual(cache.matching(query).map(\.title), ["child"])
        var changed = parent; changed["subtasks"] = SubtaskTree.changing(parent["subtasks"], id:"child", fields:["completed":.bool(true)])
        cache.update([changed]); XCTAssertTrue(cache.matching(query).isEmpty)
        var including = query; including.includeCompleted = true
        XCTAssertEqual(cache.matching(including).map(\.title), ["child"])
        changed = parent; changed["is_heading"] = .bool(false); cache.update([changed]); XCTAssertTrue(cache.matching(query).isEmpty)
        changed = parent; changed["subtasks"] = SubtaskTree.changing(parent["subtasks"], id:"child", fields:["due_date":.string("2026-10-07")]); cache.update([changed]); XCTAssertTrue(cache.matching(query).isEmpty)
    }
    func testDatedFixedChildUsesDeviceCivilDayAcrossTravelAndNeverHeadingPlan() {
        var child = task("child"); child["due_date"] = .string("2026-10-06"); child["due_time"] = .string("00:30"); child["time_zone"] = .string("Europe/Copenhagen"); child["scheduled_at"] = .string("2026-10-05T22:30:00Z")
        let cache = TaskCache(); cache.update([root([child])])
        let rows = cache.matching(TaskQuery(scope:.today,today:"2026-10-05",timeZone:"America/New_York"))
        XCTAssertEqual(rows.map(\.title), ["child"])
        XCTAssertTrue(cache.matching(TaskQuery(scope:.today,today:"2026-10-05",timeZone:"Europe/Copenhagen")).isEmpty)
    }
    func testChildDatePlacementAndOrderShareOneRealRootTransactionAndUndo() throws {
        var child = task("child"); child["due_date"] = .string("2026-10-06"); child["due_time"] = .string("09:00"); child["duration_minutes"] = .number(30)
        let parent = root([child]), selected = ProductiveTaskReading(tasks:[parent]).work[0]
        let workspace = WorkspaceBinding(account:owner,generation:UUID()), projects = [Record(["id":.string(project)])]
        let changes = try DayPlacement.hierarchyChanges(task:selected,day:"2026-10-07",orderedIDs:["other"],before:"other",roots:[parent],projects:projects,workspace:workspace,calendar:calendar)
        XCTAssertEqual(changes.map(\.table), ["tasks","view_orders"]); XCTAssertEqual(changes[0].recordID,parent.id)
        XCTAssertEqual(changes[1].fields["ids"],.array([.string(selected.id),.string("other")]))
        let after = changes[0].fields["subtasks"]!.list[0].object
        XCTAssertEqual(after["id"],child["id"]); XCTAssertEqual(after["due_date"],.string("2026-10-07")); XCTAssertEqual(after["due_time"],child["due_time"]); XCTAssertNil(after["project_id"])
        var snapshot=Snapshot(tables:["tasks":[parent]]);let history=EditHistory(changes:changes,snapshot:snapshot)
        changes.forEach{snapshot.apply($0)};history.undo.forEach{snapshot.apply($0)}
        XCTAssertEqual(snapshot.tables["tasks"]?.first?["subtasks"],parent["subtasks"])
        var replaced=parent;replaced["task_generation"] = .string("replacement")
        XCTAssertThrowsError(try DayPlacement.hierarchyChanges(task:selected,day:"2026-10-07",orderedIDs:[],before:nil,roots:[replaced],projects:projects,workspace:workspace))
        var completed=parent;completed["subtasks"] = SubtaskTree.changing(parent["subtasks"],id:"child",fields:["completed":.bool(true)])
        XCTAssertThrowsError(try DayPlacement.hierarchyChanges(task:selected,day:"2026-10-07",orderedIDs:[],before:nil,roots:[completed],projects:projects,workspace:workspace))
    }
}

extension HeadingProjectProgressTests {
    private func inboxHeading(_ children: [Record]) -> Record { var row=root(children);row["project_id"] = .null;return row }
    private var inboxDestination: Record { Record(["id":.string(project),"name":.string("Studio"),"user_id":.string(owner)]) }
    private func widgetSnapshot(_ snapshot: Snapshot) throws -> WidgetSnapshot {
        let payload=WidgetProjection.payload(tasks:snapshot.tables["tasks"] ?? [],projects:snapshot.tables["projects"] ?? [],account:owner,now:now,savedViews:snapshot.tables["saved_views"] ?? [],calendar:calendar,completionTokens:WidgetCompletion.tokens(snapshot))
        return try JSONDecoder().decode(WidgetSnapshot.self,from:JSONEncoder().encode(payload))
    }
    func testInboxNativeReviewAndPrimaryWidgetsAgreeOnIndependentWork() throws {
        var first=task("first",children:[task("checklist")]),second=task("second"),done=task("done",done:true)
        first["due_date"] = .string("2026-10-06");first["duration_minutes"] = .number(25);first["priority"] = .number(1)
        second["priority"] = .number(2);done["due_date"] = .string("2026-10-06")
        let root=inboxHeading([first,task("phase",heading:true,children:[second,done])]),workspace=WorkspaceBinding(account:owner,generation:UUID())
        var snapshot=Snapshot(tables:["tasks":[root],"projects":[inboxDestination]]);WidgetCompletion.prepare(&snapshot)
        let cache=TaskCache();cache.update([root]);let request=InboxReviewRequest(workspace:workspace,tasks:[root],batch:.all)
        let widget=try widgetSnapshot(snapshot),native=cache.matching(TaskQuery(scope:.inbox)).filter{TaskKind.mayComplete($0) && !$0.completed}
        XCTAssertEqual(widget.inboxReading().count,2);XCTAssertEqual(Set(widget.tasks.map(\.id)),Set(native.map(\.id)));XCTAssertEqual(Set(request.ids),Set(native.map(\.id)))
        XCTAssertEqual(widget.today(at:now,calendar:calendar).map(\.title),["first"])
        XCTAssertEqual(widget.focus(at:now,calendar:calendar)?.title,"first");XCTAssertEqual(widget.week(at:now,calendar:calendar)[0].count,1)
        XCTAssertEqual(widget.smallWindow(minutes:25,scope:.inbox,at:now,calendar:calendar).map(\.title),["first"])
        XCTAssertNil(widget.workIncomplete);XCTAssertFalse(WidgetCompletion.tokens(snapshot).keys.contains(SubtaskTree.reference(parent:native[0].id,key:"checklist")))
        XCTAssertTrue(widget.tasks.allSatisfy{$0.routeContext != nil && $0.completionToken != nil});XCTAssertEqual(widget.nestedTasks?.count,0,"Primary children need no duplicate filter catalog")
    }
    func testInboxChildDecisionsRejectChangedCompletionParentConversionAndWorkspace() throws {
        let root=inboxHeading([task("child")]),workspace=WorkspaceBinding(account:owner,generation:UUID()),request=InboxReviewRequest(workspace:workspace,tasks:[root])
        let row=try XCTUnwrap(request.remaining(tasks:[root],decisions:[:]).first)
        XCTAssertEqual(request.actionable(row,tasks:[root],account:owner,generation:workspace.generation),row)
        var changed=root;changed["subtasks"] = SubtaskTree.changing(root["subtasks"],id:"child",fields:["description":.string("Updated")])
        XCTAssertNil(request.actionable(row,tasks:[changed],account:owner,generation:workspace.generation))
        changed=root;changed["is_heading"] = .bool(false);XCTAssertTrue(request.remaining(tasks:[changed],decisions:[:]).isEmpty)
        XCTAssertNil(request.actionable(row,tasks:[root],account:owner,generation:UUID()))
        XCTAssertThrowsError(try InboxReviewRequest.move(row,to:project))
    }
    func testHeadingMoveReviewRequiresExplicitWholeGroupAndPreservesChildDataAndUndo() throws {
        var child=task("child");child["due_date"] = .string("2026-10-06");child["description"] = .string("Keep full notes");child["duration_minutes"] = .number(30)
        let root=inboxHeading([child,task("phase",heading:true,children:[task("sibling",done:true)])]),workspace=WorkspaceBinding(account:owner,generation:UUID())
        let selected=ProductiveTaskReading(tasks:[root]).work[0],before=Snapshot(tables:["tasks":[root],"projects":[inboxDestination]])
        let review=try InboxHeadingMoveReview(task:selected,tasks:[root],projects:[inboxDestination],destination:project,workspace:workspace)
        XCTAssertEqual(review.taskTitles,["child","sibling"]);XCTAssertEqual(review.taskCount,2);XCTAssertEqual(review.root,root)
        let changes=try review.changes(tasks:[root],projects:[inboxDestination],workspace:workspace)
        XCTAssertTrue(changes.allSatisfy{$0.table == "tasks" && $0.recordID == root.id})
        var saved=before;let history=EditHistory(changes:changes,snapshot:before);changes.forEach{saved.apply($0)}
        XCTAssertEqual(saved.tables["tasks"]?.first?.string("project_id"),project);XCTAssertEqual(saved.tables["tasks"]?.first?["subtasks"],root["subtasks"])
        XCTAssertEqual(saved.tables["tasks"]?.first?["is_heading"],.bool(true));XCTAssertEqual(saved.tables["tasks"]?.count,1)
        XCTAssertTrue(InboxReviewRequest(workspace:workspace,tasks:saved.tables["tasks"] ?? []).ids.isEmpty)
        history.undo.forEach{saved.apply($0)};XCTAssertEqual(saved.tables["tasks"]?.first?["subtasks"],root["subtasks"]);XCTAssertEqual(saved.tables["tasks"]?.first?.string("project_id"),"")
        XCTAssertEqual(before.tables["tasks"]?.first,root,"Opening or cancelling the review has no mutation")
    }
    func testHeadingMoveReviewRejectsSourceDestinationArchiveAndAccountRaces() throws {
        let root=inboxHeading([task("child"),task("sibling")]),workspace=WorkspaceBinding(account:owner,generation:UUID()),selected=ProductiveTaskReading(tasks:[root]).work[0]
        let review=try InboxHeadingMoveReview(task:selected,tasks:[root],projects:[inboxDestination],destination:project,workspace:workspace)
        var changed=root;changed["subtasks"] = SubtaskTree.changing(root["subtasks"],id:"sibling",fields:["title":.string("Changed sibling")])
        XCTAssertThrowsError(try review.changes(tasks:[changed],projects:[inboxDestination],workspace:workspace))
        var target=inboxDestination;target["name"] = .string("Renamed");XCTAssertThrowsError(try review.changes(tasks:[root],projects:[target],workspace:workspace))
        target=inboxDestination;target["is_archived"] = .bool(true);XCTAssertThrowsError(try review.changes(tasks:[root],projects:[target],workspace:workspace))
        XCTAssertThrowsError(try review.changes(tasks:[root],projects:[inboxDestination],workspace:.init(account:owner,generation:UUID())))
        target=inboxDestination;target["team_id"] = .string("team");XCTAssertThrowsError(try InboxHeadingMoveReview(task:selected,tasks:[root],projects:[target],destination:project,workspace:workspace))
        XCTAssertThrowsError(try InboxHeadingMoveReview(task:selected,tasks:[root,root],projects:[inboxDestination],destination:project,workspace:workspace))
        var unreadable=root;unreadable["subtasks"] = SubtaskTree.changing(root["subtasks"],id:"sibling",fields:["is_heading":.string("future")])
        XCTAssertThrowsError(try InboxHeadingMoveReview(task:selected,tasks:[unreadable],projects:[inboxDestination],destination:project,workspace:workspace))
    }
    func testPrimaryChildWidgetCompletesOnlyRealRootAndBindsItsExactRoute() throws {
        let root=inboxHeading([task("child"),task("sibling")]);var snapshot=Snapshot(tables:["tasks":[root],"projects":[inboxDestination]])
        WidgetCompletion.prepare(&snapshot);let widget=try widgetSnapshot(snapshot),row=try XCTUnwrap(widget.tasks.first),token=try XCTUnwrap(row.completionToken)
        let workspace=WorkspaceBinding(account:owner,generation:UUID()),url=row.url(account:owner)
        XCTAssertEqual(try WidgetRecordLink.task(url,roots:[root],projects:[inboxDestination],workspace:workspace).id,row.id)
        let request=try WidgetCompletionRequest(account:owner,taskID:row.id,token:token,at:now)
        guard case .complete(let changes)=WidgetCompletion.plan(request,snapshot:snapshot,account:owner) else{return XCTFail("No primary child action")}
        XCTAssertEqual(changes.map(\.recordID),[root.id]);changes.forEach{snapshot.apply($0)}
        XCTAssertFalse(snapshot.tables["tasks"]![0].completed);XCTAssertTrue(Record(snapshot.tables["tasks"]![0]["subtasks"].list[0].object).completed);XCTAssertFalse(Record(snapshot.tables["tasks"]![0]["subtasks"].list[1].object).completed)
        WidgetCompletion.prepare(&snapshot);XCTAssertEqual(try widgetSnapshot(snapshot).inboxReading().count,1)
        var moved=root;moved["project_id"] = .string(project)
        XCTAssertThrowsError(try WidgetRecordLink.task(url,roots:[moved],projects:[inboxDestination],workspace:workspace))
        guard case .stale=WidgetCompletion.plan(request,snapshot:snapshot,account:"other") else{return XCTFail("Foreign action accepted")}
    }
    func testRemovingChildFilterOrConvertingHeadingInvalidatesOldNonproductiveActions() throws {
        let root=inboxHeading([task("child",children:[task("checklist")])]),other=inboxHeading([task("other")])
        var otherRoot=other;otherRoot["id"] = .string("other-root")
        let view=Record(["id":.string("subtasks"),"query_ast":FilterRule.predicate("subtask","").document])
        var snapshot=Snapshot(tables:["tasks":[root,otherRoot],"projects":[inboxDestination],"saved_views":[view]]);WidgetCompletion.prepare(&snapshot)
        let child=SubtaskTree.reference(parent:root.id,key:"child"),checklist=SubtaskTree.reference(parent:child,key:"checklist")
        let token=try XCTUnwrap(WidgetCompletion.tokens(snapshot)[checklist]);let old=try WidgetCompletionRequest(account:owner,taskID:checklist,token:token,at:now)
        snapshot.tables["saved_views"] = [];guard case .stale=WidgetCompletion.plan(old,snapshot:snapshot,account:owner) else{return XCTFail("Removed filter still authorizes checklist")}
        let childRequest=try WidgetCompletionRequest(account:owner,taskID:child,token:XCTUnwrap(WidgetCompletion.tokens(snapshot)[child]),at:now)
        var converted=root;converted["is_heading"] = .bool(false);snapshot.tables["tasks"] = [converted,otherRoot]
        guard case .stale=WidgetCompletion.plan(childRequest,snapshot:snapshot,account:owner) else{return XCTFail("Converted heading still authorizes independent child")}
        WidgetCompletion.prepare(&snapshot);XCTAssertNil(WidgetCompletion.tokens(snapshot)[child]);XCTAssertNil(WidgetCompletion.tokens(snapshot)[checklist])
    }
    func testUnreadableGroupedWorkNeverClaimsAnEmptyInboxOrDropsLegacyData() throws {
        var root=inboxHeading([]);root["subtasks"] = .array([.string("Legacy")]);let original=root
        let request=InboxReviewRequest(workspace:.init(account:owner,generation:UUID()),tasks:[root]);XCTAssertTrue(request.ids.isEmpty)
        let widget=try widgetSnapshot(Snapshot(tables:["tasks":[root]]));XCTAssertNil(widget.inboxReading().count);XCTAssertEqual(widget.workIncomplete,true)
        XCTAssertEqual(root,original);let cache=TaskCache();cache.update([root]);XCTAssertTrue(cache.inboxProductiveReading().incomplete)
    }
}

extension HeadingProjectProgressTests {
    func listWorkFixture() -> (rows: [Record], projects: [Record], labels: [Record]) {
        var first = task("first", children: [task("checklist")]); first["priority"] = .number(1); first["labels"] = .array([.string("child-label")])
        var second = task("second"); second["priority"] = .number(2)
        var heading = root([first, task("phase", heading: true, children: [second, task("finished", done: true)])]); heading["priority"] = .number(3); heading["labels"] = .array([.string("heading-label")]); heading["section_id"] = .string("design")
        var ordinary = task("ordinary", children: [task("ordinary-checklist")]); ordinary["project_id"] = .string(project); ordinary["priority"] = .number(4)
        let projects = [Record(["id":.string(project),"name":.string("Studio"),"user_id":.string(owner)])]
        let labels = [Record(["id":.string("child-label"),"name":.string("Child")]),Record(["id":.string("heading-label"),"name":.string("Heading")])]
        return ([heading,ordinary],projects,labels)
    }
    func listRule(_ text: String, fixture: (rows: [Record], projects: [Record], labels: [Record])) throws -> FilterRule {
        var parser = try FilterParser(text, context: FilterContext(projects:fixture.projects,sections:[],labels:fixture.labels,userID:owner)); return try parser.parse()
    }
    func listQuery(_ rule: FilterRule, fixture: (rows: [Record], projects: [Record], labels: [Record])) -> TaskQuery {
        TaskQuery(scope:.saved("view"),filter:rule,filterLabels:fixture.labels.map{FilterReference(id:$0.id,name:$0.name)},filterProjects:fixture.projects.map{FilterReference(id:$0.id,name:$0.name)},userID:owner)
    }
    func testProjectAllCompletedAndLabelQueriesReadOwnIndependentWork() {
        let f=listWorkFixture(),cache=TaskCache();cache.update(f.rows)
        let rows=cache.matching(TaskQuery(scope:.project(project)))
        XCTAssertEqual(Set(rows.filter{TaskKind.mayComplete($0)}.map(\.title)),["first","second","ordinary"])
        XCTAssertEqual(Set(cache.matching(TaskQuery(scope:.all)).map(\.id)),Set(rows.map(\.id)))
        XCTAssertEqual(cache.matching(TaskQuery(scope:.completed)).map(\.title),["finished"])
        XCTAssertEqual(cache.matching(TaskQuery(scope:.label("child-label"),labelName:"Child")).map(\.title),["first"])
        XCTAssertEqual(cache.matching(TaskQuery(scope:.label("heading-label"),labelName:"Heading")).map(\.title),["root"])
        let first=rows.first{$0.title=="first"}!
        XCTAssertEqual(first.string("project_id"),project);XCTAssertEqual(first.string("section_id"),"design");XCTAssertEqual(first.priority,1)
        XCTAssertFalse(rows.contains{$0.title.contains("checklist")})
    }
    func testDefaultSavedFiltersMatchChildMetadataAndDoNotFlattenOrdinaryChecklists() throws {
        let f=listWorkFixture(),cache=TaskCache();cache.update(f.rows)
        for (text,expected) in [("p1",Set(["first"])),("search:second",Set(["second"])),("completed",Set(["finished"]))] {
            let rule=try listRule(text,fixture:f);var query=listQuery(rule,fixture:f);query.includeCompleted=rule.includesCompletion
            XCTAssertEqual(Set(cache.matching(query).map(\.title)),expected,text)
        }
        let rule=try listRule("p3",fixture:f)
        XCTAssertEqual(cache.matching(listQuery(rule,fixture:f)).map(\.title),["root"])
        // The general parser matcher retains its root-only default unless a list
        // provides explicit productive membership.
        let first=cache.productiveReading().presentation.first{$0.title=="first"}!
        XCTAssertFalse(try listRule("p1",fixture:f).matches(first,today:"2026-10-06",userID:owner,labels:[],timeZone:calendar.timeZone.identifier))
    }
    func testMixedRootAndDefaultQuerySectionsKeepTheirDistinctMembership() throws {
        let f=listWorkFixture(),cache=TaskCache();cache.update(f.rows)
        let rule=try listRule("root, p1",fixture:f),rows=cache.matching(listQuery(rule,fixture:f))
        XCTAssertEqual(Set(rows.map(\.title)),["root","ordinary","first"])
        let context=FilterContext(projects:f.projects,sections:[],labels:f.labels,userID:owner)
        let groups=TaskGrouping.queryGroups(rows,rule:rule,by:"none",context:context,today:"2026-10-06",timeZone:calendar.timeZone.identifier,work:cache.productiveReading())
        XCTAssertEqual(groups.count,2);XCTAssertEqual(Set(groups[0].tasks.map(\.title)),["root","ordinary"]);XCTAssertEqual(groups[1].tasks.map(\.title),["first"])
    }
    func testExplicitSubtaskAndParentFiltersRetainChecklistAuthorityInMixedSections() throws {
        let f=listWorkFixture(),cache=TaskCache();cache.update(f.rows)
        let rule=try listRule("subtask, p1",fixture:f),rows=cache.matching(listQuery(rule,fixture:f))
        XCTAssertTrue(rows.contains{$0.title=="checklist"});XCTAssertTrue(rows.contains{$0.title=="ordinary-checklist"})
        let context=FilterContext(projects:f.projects,sections:[],labels:f.labels,userID:owner)
        let groups=TaskGrouping.queryGroups(rows,rule:rule,by:"none",context:context,today:"2026-10-06",timeZone:calendar.timeZone.identifier,work:cache.productiveReading())
        XCTAssertTrue(groups[0].tasks.contains{$0.title=="checklist"});XCTAssertEqual(groups[1].tasks.map(\.title),["first"])
        let parent=try listRule("parent & !subtask",fixture:f)
        XCTAssertEqual(Set(cache.matching(listQuery(parent,fixture:f)).map(\.title)),["root","ordinary"])
    }
    func testManualProjectOutlineRetainsHeadingOrderAndOwnChecklistContainment() {
        let f=listWorkFixture(),cache=TaskCache();cache.update(f.rows)
        let rows=cache.matching(TaskQuery(scope:.project(project),sort:"manual"))
        XCTAssertEqual(rows.map(\.title),["root","first","phase","second","ordinary"])
        XCTAssertEqual(rows.first{$0.title=="first"}?["subtasks"].list.count,1)
    }
    func testProjectLabelAndDefaultFilterWidgetsResolvePublishedPrimaryChildren() throws {
        let f=listWorkFixture(),rule=try listRule("p1",fixture:f)
        let view=Record(["id":.string("view"),"name":.string("Priority"),"query_ast":rule.document])
        var prepared=Snapshot(tables:["tasks":f.rows,"projects":f.projects,"saved_views":[view]]);WidgetCompletion.prepare(&prepared)
        let payload=WidgetProjection.payload(tasks:f.rows,projects:f.projects,account:owner,now:now,labels:f.labels,savedViews:[view],calendar:calendar,completionTokens:WidgetCompletion.tokens(prepared))
        let snapshot=try JSONDecoder().decode(WidgetModel.WidgetSnapshot.self,from:JSONEncoder().encode(payload))
        XCTAssertTrue(snapshot.nestedTasks?.isEmpty==true)
        for (kind,id,titles) in [("project",project,Set(["first","second","ordinary"])),("label","child-label",Set(["first"])),("filter","view",Set(["first"]))] {
            let list=try XCTUnwrap(snapshot.lists.first{$0.kind==kind && $0.recordID==id})
            XCTAssertEqual(snapshot.listStatus(list.id,at:now,calendar:calendar),.ready)
            let rows=snapshot.listTasks(list.id,at:now,calendar:calendar)
            XCTAssertEqual(Set(rows.map(\.title)),titles);XCTAssertTrue(rows.filter{$0.id.hasPrefix("subtask:")}.allSatisfy{$0.completionToken != nil && $0.routeContext != nil})
        }
    }
    func testMissingPublishedListMembersNeverProduceFalseAllClear() throws {
        let f=listWorkFixture(),payload=WidgetProjection.payload(tasks:f.rows,projects:f.projects,account:owner,now:now,labels:f.labels,calendar:calendar)
        var snapshot=try JSONDecoder().decode(WidgetModel.WidgetSnapshot.self,from:JSONEncoder().encode(payload));let list=try XCTUnwrap(snapshot.lists.first{$0.kind=="project"})
        snapshot.tasks.removeAll{$0.title=="first"}
        XCTAssertEqual(snapshot.listStatus(list.id,at:now,calendar:calendar),.unavailable);XCTAssertTrue(snapshot.listTasks(list.id,at:now,calendar:calendar).isEmpty)
        var legacy=f.rows[0];legacy["subtasks"] = .array([.string("Legacy work")])
        let damaged=WidgetProjection.payload(tasks:[legacy],projects:f.projects,account:owner,now:now,labels:f.labels,calendar:calendar)
        let partial=try JSONDecoder().decode(WidgetModel.WidgetSnapshot.self,from:JSONEncoder().encode(damaged));let projectList=try XCTUnwrap(partial.lists.first{$0.kind=="project"})
        XCTAssertTrue(projectList.invalid);XCTAssertEqual(partial.listStatus(projectList.id,at:now,calendar:calendar),.unavailable)
    }
    func testProductiveListCacheInvalidatesAfterKindLabelsAndCompletionChanges() throws {
        let f=listWorkFixture(),cache=TaskCache();cache.update(f.rows);let rule=try listRule("p1",fixture:f),query=listQuery(rule,fixture:f)
        XCTAssertEqual(cache.matching(query).map(\.title),["first"])
        var ordinary=f.rows[0];ordinary["is_heading"] = .bool(false);cache.update([ordinary,f.rows[1]])
        XCTAssertTrue(cache.matching(query).isEmpty);XCTAssertTrue(cache.matching(TaskQuery(scope:.label("child-label"))).isEmpty)
        var changed=f.rows[0];changed["subtasks"] = SubtaskTree.changing(changed["subtasks"],id:"first",fields:["completed":.bool(true),"labels":.array([.string("new-label")])]);cache.update([changed,f.rows[1]])
        XCTAssertTrue(cache.matching(query).isEmpty);XCTAssertTrue(cache.matching(TaskQuery(scope:.label("child-label"))).isEmpty)
        XCTAssertEqual(Set(cache.matching(TaskQuery(scope:.completed)).map(\.title)),["first","finished"])
    }
}


extension HeadingProjectProgressTests {
    func testMixedDefaultSectionsDoNotReintroduceUnavailableProjectRoots() throws {
        let f=listWorkFixture(),cache=TaskCache();var hidden=root([task("hidden-child")],id:"hidden");hidden["project_id"] = .string("unavailable");hidden["priority"] = .number(1)
        cache.update(f.rows+[hidden]);let rule=try listRule("root, p1",fixture:f)
        XCTAssertEqual(Set(cache.matching(listQuery(rule,fixture:f)).map(\.title)),["root","ordinary","first"])
    }
    func testProductivePrintKeepsOrdinaryChecklistOnceAndHeadingsOutOfWorkTotals() throws {
        let f=listWorkFixture(),cache=TaskCache();cache.update(f.rows)
        let rows=cache.matching(TaskQuery(scope:.project(project),sort:"manual"))
        let document=try PrintDocument.capture(title:"Studio",subtitle:"",groups:[("",rows)],projects:f.projects,labels:f.labels,hierarchyRoots:f.rows,expandOrdinaryChecklists:true)
        XCTAssertEqual(document.count,3);XCTAssertFalse(document.hierarchyResults)
        let items=document.groups.flatMap(\.items)
        XCTAssertEqual(items.map(\.title),["root","first","checklist","phase","second","ordinary","ordinary-checklist"])
        XCTAssertEqual(items.filter(\.heading).map(\.title),["root","phase"])
        let explicit=try PrintDocument.capture(title:"Filtered",subtitle:"",groups:[("",rows.filter{$0.title=="first"})],projects:f.projects,labels:f.labels,hierarchyRoots:f.rows)
        XCTAssertEqual(explicit.groups.flatMap(\.items).map(\.title),["first"]);XCTAssertTrue(explicit.hierarchyResults)
    }
}


extension HeadingProjectProgressTests {
    func testIncompleteBadgesKeepKnownCountsAndScopeUncertaintyToTheirProject() {
        var legacy=root([]);legacy["subtasks"] = .array([.string("Legacy work")])
        var healthy=task("healthy");healthy["project_id"] = .string("other")
        let reading=ProductiveTaskReading(tasks:[legacy,healthy])
        XCTAssertEqual(reading.countLabel(2),"≥2");XCTAssertEqual(reading.countLabel(1,project:project),"≥1");XCTAssertEqual(reading.countLabel(1,project:"other"),"1")
    }
}


extension HeadingProjectProgressTests {
    func testUnknownTypesRemainReachableReviewContextWithoutWorkOrPrintCredit() throws {
        var opaque=task("future");opaque["is_heading"] = .string("future-type");opaque["description"] = .string("Keep my opaque notes")
        var nested=task("future-child");nested["is_heading"] = .number(2)
        let heading=root([task("known"),nested]),cache=TaskCache();cache.update([opaque,heading])
        let rows=cache.matching(TaskQuery(scope:.all));XCTAssertEqual(Set(rows.map(\.title)),["future","root","known","future-child"])
        XCTAssertEqual(cache.productiveReading().work.map(\.title),["known"]);XCTAssertTrue(cache.productiveReading().incomplete)
        XCTAssertEqual(rows.first{$0.title=="future"}?.string("description"),"Keep my opaque notes")
        let document=try PrintDocument.capture(title:"Work",subtitle:"",groups:[("",[opaque])],projects:[],labels:[])
        XCTAssertEqual(document.count,0);XCTAssertFalse(document.groups[0].items[0].completable);XCTAssertTrue(document.groups[0].items[0].metadata.contains("needs review"))
    }
}


extension HeadingProjectProgressTests {
    func testSparseProjectHeadingOrderKeepsWorkTogetherAndRespectsExplicitChildOrder() throws {
        let a=root([task("a-child")],id:"a"),b=root([task("b-child")],id:"b"),cache=TaskCache();cache.update([a,b])
        let rows=cache.matching(TaskQuery(scope:.project(project),sort:"manual"))
        XCTAssertEqual(DayPlacement.arrangedOutline(rows,ids:["b","a"]).map(\.title),["b","b-child","a","a-child"])
        XCTAssertEqual(DayPlacement.arrangedOutline(rows.filter{TaskKind.mayComplete($0)},ids:["b","a"]).map(\.title),["b-child","a-child"],"Search may hide headings without losing their saved anchors")
        let child=try XCTUnwrap(rows.first{$0.title=="a-child"})
        XCTAssertEqual(DayPlacement.arrangedOutline(rows,ids:[child.id,"b","a"]).map(\.title),["a-child","b","b-child","a"])
        let projects=[Record(["id":.string(project),"name":.string("Studio")])]
        let order=Record(["id":.string("group:"+project+":none"),"user_id":.string(owner),"ids":.array([.string("b"),.string("a")])])
        let payload=WidgetProjection.payload(tasks:[a,b],projects:projects,account:owner,now:now,calendar:calendar,viewOrders:[order])
        let snapshot=try JSONDecoder().decode(WidgetModel.WidgetSnapshot.self,from:JSONEncoder().encode(payload)),list=try XCTUnwrap(snapshot.lists.first)
        XCTAssertEqual(snapshot.listTasks(list.id,at:now,calendar:calendar).map(\.title),["b-child","a-child"])
    }
}
