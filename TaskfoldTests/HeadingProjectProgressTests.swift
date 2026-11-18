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
    func testOrdinaryParentStillCountsOnceIncludingCompletedParentWithOpenChecklist() {
        var row = task("parent", done: true, children: [task("open"), task("context", heading: true, children: [task("nested")])]); row["project_id"] = .string(project)
        let r = reading([row]); XCTAssertEqual(r.total, 1); XCTAssertEqual(r.completed, 1); XCTAssertFalse(r.countsIncomplete)
    }
    func testEmptyHeadingsAddNoUnfinishedWorkOrAttention() throws {
        var row = root([]); row["due_date"] = .string("2026-01-01"); row["deadline_date"] = .string("2026-01-01")
        XCTAssertEqual(reading([row]).total, 0); XCTAssertTrue(ProjectWorkScope(tasks: [row]).attention(project: project, now: now, calendar: calendar).isEmpty)
        XCTAssertEqual(try pulse([row]).projects[0].total, 0)
    }
    func testAdditiveIncompleteFlagKeepsExistingWidgetSnapshotsReadable() throws {
        let good = try pulse([root([task("open")])]), bytes = try JSONEncoder().encode(good)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("countsIncomplete"))
        let old = try JSONDecoder().decode(ProjectPulseSnapshot.self, from: bytes); XCTAssertNil(old.projects[0].countsIncomplete); XCTAssertTrue(old.valid(for: owner))
        var json = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]; var projects = json["projects"] as! [[String: Any]]; projects[0]["countsIncomplete"] = "future"; json["projects"] = projects
        XCTAssertThrowsError(try JSONDecoder().decode(ProjectPulseSnapshot.self, from: JSONSerialization.data(withJSONObject: json)))
    }
}

extension HeadingProjectProgressTests {
    func testProductivePlanningDoesNotInheritDatesOrEstimatesAndKeepsOrdinaryParentWork() {
        var parent = root([task("undated")]); parent["due_date"] = .string("2026-10-06"); parent["duration_minutes"] = .number(80)
        var ordinary = task("ordinary", children: [task("checklist")]); ordinary["due_date"] = .string("2026-10-06"); ordinary["duration_minutes"] = .number(20)
        let value = TaskPlanner.capacity([parent, ordinary], events: [], on: now, hours: WorkingHours(), calendar: calendar)
        XCTAssertEqual(value.estimatedMinutes, 20); XCTAssertEqual(value.unknownTasks, 0)
        XCTAssertNil(ProductiveTaskReading(tasks: [parent]).work.first?.due)
    }
}

extension HeadingProjectProgressTests {
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
}


extension HeadingProjectProgressTests {
}

extension HeadingProjectProgressTests {
    private func inboxHeading(_ children: [Record]) -> Record { var row=root(children);row["project_id"] = .null;return row }
    private var inboxDestination: Record { Record(["id":.string(project),"name":.string("Studio"),"user_id":.string(owner)]) }
    private func widgetSnapshot(_ snapshot: Snapshot) throws -> WidgetSnapshot {
        let payload=WidgetProjection.payload(tasks:snapshot.tables["tasks"] ?? [],projects:snapshot.tables["projects"] ?? [],account:owner,now:now,savedViews:snapshot.tables["saved_views"] ?? [],calendar:calendar,completionTokens:WidgetCompletion.tokens(snapshot))
        return try JSONDecoder().decode(WidgetSnapshot.self,from:JSONEncoder().encode(payload))
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
}


extension HeadingProjectProgressTests {
}


extension HeadingProjectProgressTests {
}


extension HeadingProjectProgressTests {
}


extension HeadingProjectProgressTests {
}
