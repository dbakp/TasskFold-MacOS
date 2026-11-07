import XCTest
@testable import TaskfoldCore

final class PlannerTests: XCTestCase {
    func calendar(_ zone: String = "Europe/Copenhagen") -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; return c }
    func day(_ text: String, _ c: Calendar) -> Date { Dates.parse(text, calendar: c)! }
    func task(_ id: String, _ time: String, minutes: Int? = nil, date: String = "2026-10-05") -> Record {
        var t = Record(["id": .string(id), "title": .string(id), "due_date": .string(date), "due_time": .string(time), "deadline_date": .string("2026-10-30")])
        if let minutes { t["duration_minutes"] = .number(Double(minutes)) }; return t
    }
    func testSlotsUseActualDSTDayAndExposeBothRepeatedHours() {
        let c = calendar()
        XCTAssertEqual(TaskPlanner.slots(on: day("2026-03-29", c), calendar: c).count, 92)
        let fall = TaskPlanner.slots(on: day("2026-10-25", c), calendar: c)
        XCTAssertEqual(fall.count, 100)
        XCTAssertEqual(fall.filter { c.component(.hour, from: $0) == 2 && c.component(.minute, from: $0) == 30 }.count, 2)
        XCTAssertTrue(TaskPlanner.slots(on: day("2026-10-05", c), every: 0, calendar: c).isEmpty)
    }
    func testStoredISODateDoesNotChangeWithPreferredDisplayCalendar() throws {
        var buddhist = Calendar(identifier: .buddhist); buddhist.timeZone = calendar().timeZone
        let date = day("2026-10-05", buddhist)
        XCTAssertEqual(TaskPlanner.dayKey(date, calendar: buddhist), "2026-10-05")
        XCTAssertEqual(calendar().component(.year, from: date), 2026)
        XCTAssertEqual(try TaskPlanner.fields(task: Record(), start: date, calendar: buddhist)["due_date"], .string("2026-10-05"))
    }
    func testOverlapLanesReuseSpaceAndNeverAssignUnknownEstimates() {
        let c = calendar(), date = day("2026-10-05", c)
        let blocks = TaskPlanner.blocks([task("a", "09:00", minutes: 60), task("b", "09:30", minutes: 30), task("c", "10:00", minutes: 25), task("unknown", "11:00")], on: date, calendar: c)
        XCTAssertEqual(blocks.map(\.laneCount), [2, 2, 1, 1]); XCTAssertEqual(blocks.map(\.lane), [0, 1, 0, 0])
        XCTAssertNil(blocks.last?.end); XCTAssertEqual(blocks.last?.length, 0)
        let capacity = TaskPlanner.capacity(blocks.map(\.task), events: [], on: date, hours: WorkingHours(), calendar: c)
        XCTAssertEqual(capacity.estimatedMinutes, 115); XCTAssertEqual(capacity.unknownTasks, 1)
    }
    func testCarryOverClipsAtMidnightAndCompletedWorkIsExcluded() {
        let c = calendar(), date = day("2026-10-06", c)
        var done = task("done", "09:00", minutes: 60, date: "2026-10-06"); done["completed"] = .bool(true)
        let blocks = TaskPlanner.blocks([task("carry", "23:30", minutes: 90), task("anchor", "23:30"), done], on: date, calendar: c)
        XCTAssertEqual(blocks.map(\.id), ["carry"]); XCTAssertEqual(blocks.first?.minute, 0); XCTAssertEqual(blocks.first?.length, 60)
    }
    func testWorkingHoursValidateAndBusyIntervalsAreUnioned() throws {
        let c = calendar(), date = day("2026-10-05", c), hours = WorkingHours()
        XCTAssertEqual(try WorkingHours(document: hours.document), hours)
        XCTAssertNil(hours.interval(on: day("2026-10-04", c), calendar: c))
        for doc: JSON in [.object([:]), .object(["version": .number(1), "start": .number(540), "end": .number(500), "days": .array([])]), .object(["version": .number(1), "start": .number(540), "end": .number(1020), "days": .array([.number(8)])])] { XCTAssertThrowsError(try WorkingHours(document: doc)) }
        let nine = TaskPlanning.start(task("a", "09:00"), calendar: c)!
        let intervals = [DateInterval(start: nine.addingTimeInterval(-3600), end: nine.addingTimeInterval(3600)), DateInterval(start: nine, end: nine.addingTimeInterval(7200)), DateInterval(start: nine, end: nine.addingTimeInterval(3600))]
        XCTAssertEqual(TaskPlanner.unionMinutes(intervals, clippedTo: hours.interval(on: date, calendar: c)!), 120)
        let allDay = task("loose", "", minutes: 25)
        XCTAssertEqual(TaskPlanner.capacity([allDay], events: [], on: date, hours: hours, calendar: c).estimatedMinutes, 25)
        let full = WorkingHours(start: 0, end: 1440, weekdays: [1])
        XCTAssertEqual(full.interval(on: day("2026-03-29", c), calendar: c)?.duration, 23 * 3600)
        XCTAssertEqual(full.interval(on: day("2026-10-25", c), calendar: c)?.duration, 25 * 3600)
    }
    func testFixedSchedulingTravelAndDateDropPreserveVisibleClockAndDeadline() throws {
        let source = calendar(), local = calendar("America/New_York")
        var t = task("a", "09:00", minutes: 25)
        let instant = TaskPlanning.start(t, calendar: source)!
        for (k, v) in try TaskPlanner.fields(task: t, start: instant, timeZone: source.timeZone.identifier, calendar: local) { t[k] = v }
        XCTAssertEqual(TaskPlanner.plannedDay(t, calendar: local), "2026-10-05")
        let changes = TaskPlanner.dayFields(task: t, day: "2026-10-06", calendar: local)
        for (k, v) in changes { t[k] = v }
        XCTAssertEqual(local.component(.hour, from: TaskPlanning.start(t, calendar: local)!), 3)
        XCTAssertEqual(t.string("deadline_date"), "2026-10-30"); XCTAssertEqual(t.durationMinutes, 25)
        XCTAssertNil(changes["deadline_date"]); XCTAssertNil(changes["duration_minutes"])
    }
    func testFloatingSecondFoldRequiresExplicitFixedTime() throws {
        let c = calendar(), t = task("a", "02:30", date: "2026-10-25")
        let first = TaskPlanning.instant("2026-10-25T00:30:00Z")!, second = TaskPlanning.instant("2026-10-25T01:30:00Z")!
        XCTAssertNoThrow(try TaskPlanner.fields(task: t, start: first, calendar: c))
        XCTAssertThrowsError(try TaskPlanner.fields(task: t, start: second, calendar: c))
        let fields = try TaskPlanner.fields(task: t, start: second, timeZone: c.timeZone.identifier, calendar: c)
        XCTAssertEqual(fields["scheduled_at"], .string("2026-10-25T01:30:00Z"))
        XCTAssertEqual(TaskPlanner.resizedMinutes(task: t, delta: 15), nil)
        XCTAssertEqual(TaskPlanner.resizedMinutes(task: task("known", "09:00", minutes: 5), delta: -15), 1)
    }
    func testLocalDayQueriesAndDropsAgreeAfterTravelAcrossMidnight() throws {
        let c = calendar("America/New_York")
        var t = task("fixed", "00:30", minutes: 25, date: "2026-10-06")
        t["time_zone"] = .string("Europe/Copenhagen"); t["scheduled_at"] = .string("2026-10-05T22:30:00Z")
        XCTAssertEqual(TaskPlanner.plannedDay(t, calendar: c), "2026-10-05")
        XCTAssertEqual(c.component(.day, from: TaskPlanner.dayDate(t, calendar: c)!), 5)
        XCTAssertEqual(TaskPlanner.clockValue(t, calendar: c), "18:30")
        XCTAssertFalse(TaskPlanner.zoneLabel(t, calendar: c).isEmpty)
        let cache = TaskCache(); cache.update([t])
        XCTAssertEqual(cache.matching(TaskQuery(scope: .today, today: "2026-10-05", timeZone: c.timeZone.identifier)).map(\.id), [t.id])
        XCTAssertTrue(cache.matching(TaskQuery(scope: .upcoming, today: "2026-10-05", selectedDay: "2026-10-06", timeZone: c.timeZone.identifier)).isEmpty)
        let changes = DayPlacement.changes(task: t, day: "2026-10-07", orderedIDs: [], before: nil, calendar: c)
        XCTAssertEqual(changes.count, 2)
        var snapshot = Snapshot(tables: ["tasks": [t]])
        changes.forEach { snapshot.apply($0) }
        let moved = snapshot.tables["tasks"]!.first!
        XCTAssertEqual(TaskPlanner.plannedDay(moved, calendar: c), "2026-10-07")
        XCTAssertEqual(c.component(.hour, from: TaskPlanning.start(moved, calendar: c)!), 18)
        XCTAssertEqual(moved.string("due_date"), "2026-10-08")
    }
    func testDateDropRepairsMissingSpringClockTimeWithoutInventingEstimate() {
        let c = calendar()
        let t = task("float", "02:30", date: "2026-03-28")
        let fields = TaskPlanner.dayFields(task: t, day: "2026-03-29", calendar: c)
        XCTAssertEqual(fields["due_date"], .string("2026-03-29")); XCTAssertEqual(fields["due_time"], .string("03:30"))
        XCTAssertNil(fields["duration_minutes"]); XCTAssertNil(fields["deadline_date"])
        XCTAssertEqual(TaskPlanner.dayFields(task: t, day: "2026-03-30", calendar: c), ["due_date": .string("2026-03-30")])
    }
    func testConflictEndpointsAndOneCommitUndoPreserveIndependentFields() throws {
        let c = calendar(), a = task("a", "09:00", minutes: 60), b = task("b", "10:00", minutes: 25), point = task("point", "09:30")
        let start = TaskPlanning.start(a, calendar: c)!
        XCTAssertEqual(TaskPlanner.conflicts(task: a, start: start, minutes: 60, tasks: [a, b, point], events: [], calendar: c), ["point"])
        let fields = try TaskPlanner.fields(task: a, start: start.addingTimeInterval(900), minutes: 45, calendar: c)
        let changes = [Mutation(table: "tasks", recordID: a.id, method: "PATCH", fields: fields)]
        let original = Snapshot(tables: ["tasks": [a]])
        let history = EditHistory(changes: changes, snapshot: original)
        var changed = original; changes.forEach { changed.apply($0) }
        XCTAssertEqual(changed.tables["tasks"]?.first?.durationMinutes, 45)
        history.undo.forEach { changed.apply($0) }
        XCTAssertEqual(changed.tables["tasks"]?.first?.string("due_time"), "09:00")
        XCTAssertEqual(changed.tables["tasks"]?.first?.string("deadline_date"), "2026-10-30")
    }
}


extension PlannerTests {
    func testWorkingHoursEditPreservesExtensionsThroughCacheAndBackup() throws {
        var document = WorkingHours().document.object
        let extensionValue: JSON = .object(["breaks": .array([.number(720), .number(780)]), "zone": .string("Europe/Copenhagen")])
        document["future_options"] = extensionValue
        let changed = try WorkingHours(start: 480, end: 960, weekdays: [1, 3, 5]).replacing(.object(document))
        XCTAssertEqual(changed.object["future_options"], extensionValue)
        XCTAssertEqual(try WorkingHours(document: changed), WorkingHours(start: 480, end: 960, weekdays: [1, 3, 5]))
        var snapshot = Snapshot()
        snapshot.tables["view_preferences"] = [Record(["id": .string("planner"), "user_id": .string("owner"), "working_hours": changed])]
        let cached = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        let backup = try WorkspaceBackup.read(WorkspaceBackup.make(cached, account: "owner").data())
        XCTAssertEqual(backup.tables["view_preferences"]?.first?["working_hours"], changed)
    }
    func testWorkingHoursNeverReplaceUnsupportedOrMalformedDocuments() throws {
        for document: JSON in [.object(["version": .number(2), "future": .string("preserve")]), .object(["version": .number(1), "start": .number(540)]), .string("invalid"), .array([])] {
            XCTAssertFalse(WorkingHours.editable(document))
            XCTAssertThrowsError(try WorkingHours().replacing(document))
        }
        XCTAssertEqual(try WorkingHours().replacing(.null), WorkingHours().document)
        XCTAssertThrowsError(try WorkingHours(start: 1020, end: 540).replacing(WorkingHours().document))
    }
}


extension PlannerTests {
    func testNotificationTomorrowPlansUndatedAndFutureWorkOnActualTomorrow() {
        let c = calendar(), now = day("2026-10-12", c).addingTimeInterval(12 * 3600)
        for originalDay in ["", "2026-10-10", "2026-10-12", "2026-10-13", "2026-10-20"] {
            var original = task("notification", "", minutes: 45, date: originalDay)
            original["description"] = .string("Keep the independent notes")
            original["reminder_specs"] = .array([.object(ReminderSpec.absolute(now).raw)])
            let fields = TaskPlanner.tomorrowFields(task: original, now: now, calendar: c)
            var snapshot = Snapshot(tables: ["tasks": [original]])
            snapshot.apply(Mutation(table: "tasks", recordID: original.id, method: "PATCH", fields: fields))
            let moved = snapshot.tables["tasks"]!.first!
            XCTAssertEqual(moved.string("due_date"), "2026-10-13", originalDay)
            for key in ["id", "title", "description", "duration_minutes", "deadline_date", "reminder_specs", "completed", "due_time"] {
                XCTAssertEqual(moved[key], original[key], key + " from " + originalDay)
            }
            if originalDay == "2026-10-13" { XCTAssertTrue(fields.isEmpty) }
        }
    }
    func testNotificationTomorrowUsesCalendarDayAcrossDSTAndKeepsFixedLocalClock() throws {
        let c = calendar(), now = day("2026-03-28", c).addingTimeInterval(23 * 3600)
        let floating = task("floating", "02:30", date: "2026-04-10")
        let spring = TaskPlanner.tomorrowFields(task: floating, now: now, calendar: c)
        XCTAssertEqual(spring["due_date"], .string("2026-03-29"))
        XCTAssertEqual(spring["due_time"], .string("03:30"))
        let travel = calendar("America/New_York")
        var fixed = task("fixed", "00:30", date: "2026-10-20")
        fixed["time_zone"] = .string("Europe/Copenhagen"); fixed["scheduled_at"] = .string("2026-10-19T22:30:00Z")
        let localNow = day("2026-10-12", travel).addingTimeInterval(22 * 3600)
        let fields = TaskPlanner.tomorrowFields(task: fixed, now: localNow, calendar: travel)
        var snapshot = Snapshot(tables: ["tasks": [fixed]])
        snapshot.apply(Mutation(table: "tasks", recordID: fixed.id, method: "PATCH", fields: fields))
        let moved = try XCTUnwrap(snapshot.tables["tasks"]?.first)
        XCTAssertEqual(TaskPlanner.plannedDay(moved, calendar: travel), "2026-10-13")
        XCTAssertEqual(TaskPlanner.clockValue(moved, calendar: travel), "18:30")
        XCTAssertEqual(moved.string("time_zone"), "Europe/Copenhagen")
        XCTAssertEqual(moved.string("deadline_date"), fixed.string("deadline_date"))
    }
    func testNotificationTomorrowRejectsInvalidClockWithoutChangingWork() {
        XCTAssertTrue(TaskPlanner.tomorrowFields(task: task("invalid", ""), now: Date(timeIntervalSince1970: .nan), calendar: calendar()).isEmpty)
    }
}

final class CalendarWorkReadingTests: XCTestCase {
    private func node(_ id: String, date: String = "2026-10-26", heading: Bool = false, completed: Bool = false, children: [Record] = []) -> Record {
        Record(["id": .string(id), "title": .string(id), "due_date": .string(date), "is_heading": .bool(heading), "completed": .bool(completed), "subtasks": .array(children.map { .object($0.fields) })])
    }
    private func reading(_ roots: [Record], zone: String = "Europe/Copenhagen") -> CalendarWorkReading {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!
        return CalendarWorkReading(work: ProductiveTaskReading(tasks: roots), calendar: calendar)
    }
    func testHeadingDatesDoNotReplaceIndependentChildDatesOrCountChecklists() {
        let child = node("child", date: "2026-10-27", children: [node("checklist", date: "2026-10-28")])
        let root = node("root", heading: true, children: [child, node("nested", heading: true, children: [node("second", date: "2026-11-01")])])
        let value = reading([root])
        XCTAssertEqual(value.open(on: "2026-10-26"), 0)
        XCTAssertEqual(value.open(on: "2026-10-27"), 1)
        XCTAssertEqual(value.open(on: "2026-10-28"), 0)
        XCTAssertEqual(value.open(on: "2026-11-01"), 1)
        XCTAssertFalse(value.incomplete)
        XCTAssertEqual(value.rowsByDay["2026-10-27"]?.first?.id, SubtaskTree.reference(parent: "root", key: "child"))
    }
    func testCompletedRowsRemainReviewableButDoNotInflateDayHeatmaps() {
        let value = reading([node("root", heading: true, children: [node("done", completed: true), node("open")])])
        XCTAssertEqual(value.rowsByDay["2026-10-26"]?.count, 2)
        XCTAssertEqual(value.open(on: "2026-10-26"), 1)
        let open = value.rowsByDay["2026-10-26"]!.first { !$0.completed }!
        XCTAssertEqual(value.open(on: "2026-10-26", excluding: [open.id]), 0)
    }
    func testIdenticalChildKeysInDifferentRootsKeepIndependentRoutes() {
        let value = reading([node("a", heading: true, children: [node("same")]), node("b", heading: true, children: [node("same")])])
        XCTAssertEqual(value.open(on: "2026-10-26"), 2)
        XCTAssertEqual(Set(value.rowsByDay["2026-10-26"]!.map(\.id)).count, 2)
    }
    func testUnreadableIdentityNeverBecomesAnEditableCalendarRow() {
        var child = node("child"); child["id"] = .null
        let value = reading([node("root", heading: true, children: [child])])
        XCTAssertEqual(value.open(on: "2026-10-26"), 1)
        XCTAssertTrue(value.rowsByDay.isEmpty)
        XCTAssertTrue(value.incomplete)
    }
    func testFixedChildSchedulesUseTheViewedTimeZoneAcrossMonthBoundaries() {
        var child = node("child", date: "2026-11-01")
        child["due_time"] = .string("00:30"); child["time_zone"] = .string("Europe/Copenhagen")
        child["scheduled_at"] = .string("2026-10-31T23:30:00Z")
        let root = node("root", heading: true, children: [child])
        XCTAssertEqual(reading([root], zone: "America/New_York").open(on: "2026-10-31"), 1)
        XCTAssertEqual(reading([root]).open(on: "2026-11-01"), 1)
    }
    func testSourceRootWinsOverAlreadyProjectedChildWithoutDuplicateWork() {
        let root = node("root", heading: true, children: [node("child")])
        let projected = ProductiveTaskReading(tasks: [root]).work
        XCTAssertEqual(reading([root] + projected).open(on: "2026-10-26"), 1)
    }
}

final class PlannerTaskSearchTests: XCTestCase {
    private let binding = WorkspaceBinding(account: "owner", generation: UUID())
    private let session = UUID()
    private func task(_ id: String = "task", title: String = "Review the layout", project: String = "") -> Record {
        Record(["id": .string(id), "user_id": .string("owner"), "task_generation": .string("generation"), "title": .string(title), "project_id": project.isEmpty ? .null : .string(project), "completed": .bool(false), "description": .string("Keep these notes"), "opaque": .bool(true)])
    }
    private func project(_ id: String, _ name: String, parent: String = "") -> Record {
        Record(["id": .string(id), "name": .string(name), "parent_id": parent.isEmpty ? .null : .string(parent)])
    }
    func testSearchMatchesUnicodeProjectSectionAndParentContext() throws {
        let projects = [project("a", "Design"), project("b", "Research", parent: "a")]
        let sections = [Record(["id": .string("s"), "project_id": .string("b"), "name": .string("Ready for review")])]
        var row = task("first", title: "Résumé layout", project: "b"); row["section_id"] = .string("s"); row["duration_minutes"] = .number(30)
        let catalog = try PlannerTaskCatalog(tasks: [row, task("second", title: row.title)], projects: projects, sections: sections, parents: [row.id: "Website launch"])
        let page = try catalog.page(query: "resume Research launch")
        XCTAssertEqual(page.options.map(\.id), [row.id]); XCTAssertEqual(page.options[0].location, "Design › Research › Ready for review › Website launch")
        XCTAssertEqual(page.options[0].summary, "30 min · Unscheduled"); XCTAssertEqual(try catalog.page(query: "Inbox").options.map(\.id), ["second"])
    }
    func testCompletedUnsupportedArchivedMissingAndAmbiguousRowsStayOut() throws {
        var done = task("duplicate"); done["completed"] = .bool(true)
        var unsupported = task("future"); unsupported["is_heading"] = .string("future")
        var archived = project("a", "Archive"); archived["is_archived"] = .bool(true)
        let rows = [task("duplicate"), done, unsupported, task("archived", project: "b"), task("missing", project: "gone"), task("ambiguous", project: "c"), task("okay")]
        let projects = [archived, project("b", "Child", parent: "a"), project("c", "First"), project("c", "Second")]
        XCTAssertEqual(try PlannerTaskCatalog(tasks: rows, projects: projects, sections: []).options.map(\.id), ["okay"])
    }
    func testHeadingContextRemainsSchedulableWithoutInventingEstimates() throws {
        var row = task(); row["is_heading"] = .bool(true)
        let catalog = try PlannerTaskCatalog(tasks: [row], projects: [], sections: [])
        XCTAssertEqual(catalog.options.first?.summary, "Heading · context only · Unscheduled")
        XCTAssertNotNil(PlannerTaskCatalog.current(catalog.options[0], tasks: [row], projects: []))
    }
    func testDisplayedChoiceRejectsChangedOwnerProjectGenerationAndCompletion() throws {
        let row = task(), option = try PlannerTaskCatalog(tasks: [row], projects: [], sections: []).options[0]
        var renamed = row; renamed["title"] = .string("Current name")
        XCTAssertEqual(PlannerTaskCatalog.current(option, tasks: [renamed], projects: [])?.title, "Current name")
        for key in ["user_id", "task_generation", "project_id", "section_id", "is_heading"] {
            var changed = row; changed[key] = .string("changed")
            XCTAssertNil(PlannerTaskCatalog.current(option, tasks: [changed], projects: []), key)
        }
        var done = row; done["completed"] = .bool(true)
        XCTAssertNil(PlannerTaskCatalog.current(option, tasks: [done], projects: [])); XCTAssertNil(PlannerTaskCatalog.current(option, tasks: [row, row], projects: []))
    }
    func testLargeCatalogPagesAreBoundedAndSearchCancellationIsCooperative() async throws {
        let rows = (0..<5000).map { task("task-\($0)", title: String(format: "Design task %05d", $0)) }
        let catalog = try await PlannerTaskCatalog.load(tasks: rows, projects: [], sections: [], parents: [:])
        XCTAssertEqual(try catalog.page(query: "").options.count, 60)
        XCTAssertEqual(try catalog.page(query: "", limit: 120).options.count, 120)
        XCTAssertEqual(try catalog.page(query: "", limit: -1).total, 5000)
        XCTAssertTrue(try catalog.page(query: "", limit: -1).options.isEmpty)
        let found = try await catalog.search(query: "04999", limit: 60); XCTAssertEqual(found.options.map(\.id), ["task-4999"])
        var checks = 0
        XCTAssertThrowsError(try catalog.page(query: "no match", checkCancellation: { checks += 1; if checks == 10 { throw CancellationError() } }))
        XCTAssertEqual(checks, 10)
        let worker = Task { try await PlannerTaskCatalog.load(tasks: rows, projects: [], sections: [], parents: [:]) }; worker.cancel()
        do { _ = try await worker.value; XCTFail("Cancelled index must not publish") } catch is CancellationError { }
    }
    func testPlanningSelectionPreservesDisjointFieldsButRejectsNewerSchedule() throws {
        let original = task(), selected = try PlannerTaskSelection(task: original, roots: [original], workspace: binding, session: session)
        var live = original; live["title"] = .string("Renamed"); live["description"] = .string("New notes")
        let fields: [String: JSON] = ["due_date": .string("2026-11-06"), "due_time": .string("09:00")]
        XCTAssertEqual(selected.current(tasks: [live], roots: [live], workspace: binding, session: session, fields: fields), live)
        live["due_date"] = .string("2026-11-07")
        XCTAssertNil(selected.current(tasks: [live], roots: [live], workspace: binding, session: session, fields: fields))
        live["due_date"] = fields["due_date"]!
        XCTAssertNotNil(selected.current(tasks: [live], roots: [live], workspace: binding, session: session, fields: fields))
    }
    func testSelectionRejectsWorkspaceSessionRemovalReplacementAndAmbiguity() throws {
        let row = task(), selected = try PlannerTaskSelection(task: row, roots: [row], workspace: binding, session: session)
        XCTAssertNil(selected.current(tasks: [row], roots: [row], workspace: .init(account: "other", generation: binding.generation), session: session))
        XCTAssertNil(selected.current(tasks: [row], roots: [row], workspace: .init(account: binding.account, generation: UUID()), session: session))
        XCTAssertNil(selected.current(tasks: [row], roots: [row], workspace: binding, session: UUID()))
        XCTAssertNil(selected.current(tasks: [], roots: [], workspace: binding, session: session))
        XCTAssertNil(selected.current(tasks: [row, row], roots: [row], workspace: binding, session: session))
        var restored = row; restored["task_generation"] = .string("restored")
        XCTAssertNil(selected.current(tasks: [restored], roots: [restored], workspace: binding, session: session))
        XCTAssertThrowsError(try PlannerTaskSelection(task: row, roots: [restored], workspace: binding, session: session))
        XCTAssertThrowsError(try PlannerTaskSelection(task: row, roots: [row, row], workspace: binding, session: session))
    }
    func testNestedSelectionKeepsItsExactCurrentChildBoundary() throws {
        var root = task("root"); root["is_heading"] = .bool(true)
        let child = task("child"); root["subtasks"] = .array([.object(child.fields)])
        let projected = try XCTUnwrap(TaskEditorSourceContext.projection(root, reference: SubtaskTree.reference(parent: root.id, key: child.id)))
        let selected = try PlannerTaskSelection(task: projected, roots: [root], workspace: binding, session: session)
        XCTAssertNotNil(selected.current(tasks: [projected], roots: [root], workspace: binding, session: session))
        var changed = child; changed["title"] = .string("Changed child"); root["subtasks"] = .array([.object(changed.fields)])
        let changedProjection = try XCTUnwrap(TaskEditorSourceContext.projection(root, reference: projected.id))
        XCTAssertNil(selected.current(tasks: [changedProjection], roots: [root], workspace: binding, session: session))
    }
}


final class DurableSnapshotReadCacheTests: XCTestCase {
    private func snapshot(_ title: String = "Old") -> Snapshot { Snapshot(tables: ["tasks": [Record(["id": .string("task"), "title": .string(title), "subtasks": .array([])])]]) }
    func testOwnEncodedDataHitsAndSnapshotValueIsImmutable() throws {
        let cache = DurableSnapshotReadCache(); var original = snapshot()
        let data = try cache.encode(original)
        original.tables["tasks"]![0]["title"] = .string("Edited")
        XCTAssertEqual(try cache.decode(data), snapshot()); XCTAssertEqual(cache.decodeCount, 0)
    }
    func testSameSizeExternalReplacementAndRestorationAreReadExactly() throws {
        let cache = DurableSnapshotReadCache(), old = try cache.encode(snapshot("Old"))
        let external = try TaskfoldJSONEncoder().encode(snapshot("New")); XCTAssertEqual(old.count, external.count)
        XCTAssertEqual(try cache.decode(external), snapshot("New")); XCTAssertEqual(cache.decodeCount, 1)
        XCTAssertEqual(try cache.decode(old), snapshot("Old")); XCTAssertEqual(cache.decodeCount, 2)
        XCTAssertThrowsError(try cache.decode(Data("{broken".utf8)))
        XCTAssertEqual(try cache.decode(old), snapshot("Old")); XCTAssertEqual(cache.decodeCount, 4)
    }
    func testFailedWriteCannotMakeSpeculativeSnapshotLookDurable() throws {
        let cache = DurableSnapshotReadCache(), actualDisk = try cache.encode(snapshot())
        _ = try cache.encode(snapshot("Speculative")) // Simulate write failure: disk stays old.
        XCTAssertEqual(try cache.decode(actualDisk), snapshot()); XCTAssertEqual(cache.decodeCount, 1)
    }
    func testInvalidPrivateLedgerStillFailsTheOrdinaryDecoder() throws {
        let cache = DurableSnapshotReadCache(); var invalid = snapshot()
        invalid.timeSnoozes = ["bad": try TaskfoldJSONDecoder().decode(TimeSnoozeIntent.self, from: Data(#"{"version":1,"id":"bad","account":"bad","epoch":"bad","taskID":"bad","specID":"bad","signature":"bad","originalAt":0,"fireAt":0,"phase":"queued","revision":0}"#.utf8))]
        let data = try cache.encode(invalid)
        XCTAssertThrowsError(try cache.decode(data)); XCTAssertEqual(cache.decodeCount, 1)
    }
    func testOversizeEnvelopesAndMetadataBypassMemo() throws {
        let cache = DurableSnapshotReadCache(maximumBytes: 0), data = try cache.encode(snapshot())
        _ = try cache.decode(data); _ = try cache.decode(data); XCTAssertEqual(cache.decodeCount, 2)
        let headerCache = DurableSnapshotReadCache(); var pending = snapshot()
        pending.pending = [Mutation(table: "tasks", recordID: "task", method: "PATCH", fields: ["description": .string(String(repeating: "x", count: 600_000))])]
        let header = try headerCache.encode(pending)
        XCTAssertEqual(try headerCache.decode(header), pending); XCTAssertEqual(headerCache.decodeCount, 1)
    }
    func testPreparedEncodingMustMatchAndOpaqueNumbersRemainExact() throws {
        let cache = DurableSnapshotReadCache(), old = snapshot(), prepared = try PreparedSnapshotEncoding(old)
        var current = snapshot("New")
        current.tables["tasks"]![0]["opaque"] = try TaskfoldJSONDecoder().decode(JSON.self, from: Data("9007199254740993".utf8))
        let data = try cache.encode(current, prepared: prepared)
        XCTAssertEqual(try cache.decode(data), current)
        XCTAssertEqual(try TaskfoldJSONDecoder().decode(Snapshot.self, from: data), current)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("9007199254740993"))
    }
    func testLargeAttachmentFileReadsReuseParsingWithoutSkippingDiskRead() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: folder) }
        var value = snapshot(); value.tables["tasks"]![0]["attachments"] = .array([.object(["url": .string("data:image/jpeg;base64," + String(repeating: String(repeating: "A", count: 79) + "/", count: 32_000))])])
        let path = folder.appendingPathComponent("cache.json"), data = try TaskfoldJSONEncoder().encode(value)
        try data.write(to: path, options: .atomic)
        let cache = DurableSnapshotReadCache(), start = Date()
        XCTAssertEqual(try cache.decode(Data(contentsOf: path)), value)
        let cold = Date().timeIntervalSince(start), warmStart = Date()
        for _ in 0..<20 { XCTAssertEqual(try cache.decode(Data(contentsOf: path)), value) }
        let warm = Date().timeIntervalSince(warmStart) / 20
        XCTAssertEqual(cache.decodeCount, 1)
        print("DURABLE_READ_TIMING bytes=\(data.count) cold=\(cold) warmFileRead=\(warm)")
    }
}

final class TaskRowPlanningReadTests: XCTestCase {
    private func calendar(_ zone: String = "UTC", identifier: Calendar.Identifier = .gregorian) -> Calendar {
        var value = Calendar(identifier: identifier); value.timeZone = TimeZone(identifier: zone)!; return value
    }
    private func task(_ day: String = "2026-11-09", time: String = "09:30", zone: String = "UTC", instant: String = "2026-11-09T09:30:00Z") -> Record {
        Record(["id": .string("row"), "title": .string("Keep this title"), "due_date": .string(day), "due_time": .string(time), "time_zone": .string(zone), "scheduled_at": .string(instant), "completed": .bool(false), "deadline_date": .string("2026-11-08")])
    }
    private let now = Date(timeIntervalSince1970: 1_794_266_100) // Fixed, never the test machine's current day.
    private func assertOriginalReads(_ task: Record, compact: Bool = false, calendar: Calendar, now: Date) {
        let read = TaskRowPlanningRead(task: task, compactDate: compact, calendar: calendar, now: now)
        let day = TaskPlanner.dayDate(task, calendar: calendar)
        let overdue = TaskKind.mayComplete(task) && !task.completed && day.map { $0 < calendar.startOfDay(for: now) } == true
        XCTAssertEqual(read.day, day); XCTAssertEqual(read.clock, TaskPlanner.clockValue(task, calendar: calendar)); XCTAssertEqual(read.zone, TaskPlanner.zoneLabel(task, calendar: calendar))
        XCTAssertEqual(read.overdue, overdue)
        XCTAssertEqual(read.dueToday, TaskPlanner.plannedDay(task, calendar: calendar) == TaskPlanner.dayKey(now, calendar: calendar))
        XCTAssertEqual(read.showsDate, day != nil && (!compact || overdue || !task.string("due_time").isEmpty || task["is_recurring"].flag))
        XCTAssertEqual(read.deadline, Dates.parse(task.string("deadline_date"), calendar: calendar))
        XCTAssertEqual(read.deadlineOverdue, !task.completed && read.deadline.map { $0 < calendar.startOfDay(for: now) } == true)
    }
    func testFloatingAndMissingDatesKeepTheirOriginalClockFallback() {
        for day in ["", "2026-11-09", "not a date", "2026-02-30", "2026-11-09T12:00:00Z"] {
            for time in ["", "9:0", "09:30", "bad clock"] {
                assertOriginalReads(task(day, time: time, zone: "", instant: "ignored"), compact: true, calendar: calendar(), now: now)
            }
        }
    }
    func testFixedTimeCrossesDisplayedDayAndKeepsZoneAbbreviation() {
        let row = task("2026-11-09", time: "23:30", zone: "America/New_York", instant: "2026-11-10T04:30:00Z")
        for zone in ["Europe/Copenhagen", "Pacific/Auckland", "America/Los_Angeles"] { assertOriginalReads(row, calendar: calendar(zone), now: now) }
        let read = TaskRowPlanningRead(task: row, calendar: calendar("Europe/Copenhagen"), now: now)
        XCTAssertEqual(TaskPlanner.dayKey(read.day!, calendar: calendar("Europe/Copenhagen")), "2026-11-10"); XCTAssertEqual(read.clock, "05:30")
    }
    func testInvalidZoneClockOrSavedInstantUsesTheSameSafeFallback() {
        for row in [task(zone: "Unknown/Zone"), task(time: "29:99"), task(instant: ""), task(instant: "invalid"), task(instant: "2026-11-08T09:30:00Z")] {
            assertOriginalReads(row, calendar: calendar("Europe/Copenhagen"), now: now)
        }
    }
    func testSavedDSTFoldAndHalfHourGapUseExistingPlanningRules() {
        for row in [task("2026-10-25", time: "02:30", zone: "Europe/Copenhagen", instant: "2026-10-25T01:30:00Z"), task("2026-10-04", time: "02:15", zone: "Australia/Lord_Howe", instant: "")] {
            for zone in ["UTC", "Europe/Copenhagen", "Australia/Lord_Howe"] { assertOriginalReads(row, calendar: calendar(zone), now: now) }
        }
    }
    func testDisplayCalendarDoesNotReinterpretStoredGregorianDates() {
        let row = task("2026-11-09", time: "20:30", zone: "Asia/Bangkok", instant: "2026-11-09T13:30:00Z")
        assertOriginalReads(row, calendar: calendar("Europe/Copenhagen", identifier: .buddhist), now: now)
        assertOriginalReads(row, calendar: calendar("Asia/Tokyo", identifier: .japanese), now: now)
    }
    func testCompletionHeadingRecurrenceAndCompactFlagsStayConsistent() {
        let c = calendar(), today = Dates.parse("2026-11-09", calendar: calendar())!
        for completed in [false, true] {
            for kind in [JSON.null, .bool(true), .string("future")] {
                for compact in [false, true] {
                    var row = task("2026-11-08", time: "", zone: "", instant: ""); row["completed"] = .bool(completed); row["is_heading"] = kind
                    assertOriginalReads(row, compact: compact, calendar: c, now: today)
                    row["is_recurring"] = .bool(true); assertOriginalReads(row, compact: compact, calendar: c, now: today)
                }
            }
        }
    }
    func testNewRecordClockAndZoneAreReadFreshWithoutMutatingSource() throws {
        var row = task(); row["description"] = .string("Café e\u{301} 🪴"); row["future"] = try TaskfoldJSONDecoder().decode(JSON.self, from: Data("9007199254740993".utf8))
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let beforeFields = row.fields
        let before = try encoder.encode(row), first = TaskRowPlanningRead(task: row, calendar: calendar(), now: now)
        let tomorrow = TaskRowPlanningRead(task: row, calendar: calendar(), now: Dates.parse("2026-11-10", calendar: calendar())!)
        XCTAssertNotEqual(first.overdue, tomorrow.overdue)
        var edited = row; edited["due_time"] = .string("14:45"); edited["scheduled_at"] = .null
        let changed = TaskRowPlanningRead(task: edited, calendar: calendar(), now: now)
        XCTAssertEqual(changed.clock, "14:45"); XCTAssertNotEqual(changed.clock, first.clock)
        let travel = TaskRowPlanningRead(task: row, calendar: calendar("America/New_York"), now: now)
        XCTAssertNotEqual(travel.clock, first.clock)
        XCTAssertEqual(try encoder.encode(row), before)
        XCTAssertTrue(AuthoredValueComparison.exactJSON(.object(row.fields), .object(beforeFields)))
    }
    func testRepeatedRowDateWorkloadMatchesSingleReadAndRecordsTiming() {
        let c = calendar("Europe/Copenhagen"), rows = (0..<40).map { n -> Record in var row = task(); row["id"] = .string("row-\(n)"); return row }
        func legacy(_ row: Record) -> Int {
            let visible = TaskPlanner.dayDate(row, calendar: c) != nil
            let day = TaskPlanner.dayDate(row, calendar: c)
            let clock = TaskPlanner.clockValue(row, calendar: c)
            let zone = TaskPlanner.zoneLabel(row, calendar: c).isEmpty ? "" : TaskPlanner.zoneLabel(row, calendar: c)
            let overdue = TaskPlanner.dayDate(row, calendar: c).map { $0 < c.startOfDay(for: now) } == true
            let today = TaskPlanner.plannedDay(row, calendar: c) == TaskPlanner.dayKey(now, calendar: c)
            return (visible ? 1 : 0) + (day == nil ? 0 : 1) + clock.count + zone.count + (overdue ? 1 : 0) + (today ? 1 : 0)
        }
        var oldTimes: [Double] = [], newTimes: [Double] = []
        for _ in 0..<5 {
            var old = 0, fresh = 0; let a = Date()
            for row in rows { old += legacy(row) }; let b = Date()
            for row in rows {
                let read = TaskRowPlanningRead(task: row, calendar: c, now: now)
                fresh += (read.showsDate ? 1 : 0) + (read.day == nil ? 0 : 1) + read.clock.count + read.zone.count + (read.overdue ? 1 : 0) + (read.dueToday ? 1 : 0)
            }; let end = Date()
            XCTAssertEqual(old, fresh); oldTimes.append(b.timeIntervalSince(a)); newTimes.append(end.timeIntervalSince(b))
        }
        print("ROW_PLANNING_READ_TIMING rows=40 repeated=\(oldTimes.sorted()[2]) single=\(newTimes.sorted()[2])")
    }
}

final class PlannerDayReadingTests: XCTestCase {
    private func calendar(_ zone: String = "Europe/Copenhagen") -> Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: zone)!; return value
    }
    private func task(_ id: String, day: String, time: String = "", minutes: Int? = 25) -> Record {
        var fields: [String: JSON] = ["id": .string(id), "title": .string(id), "due_date": .string(day), "due_time": .string(time), "opaque": .object(["future": .string("e\u{301}")])]
        if let minutes { fields["duration_minutes"] = .number(Double(minutes)) }
        return Record(fields)
    }
    private func assertBlocks(_ lhs: [PlannerBlock], _ rhs: [PlannerBlock], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(AuthoredValueComparison.sameRows(lhs.map(\.task), rhs.map(\.task)), file: file, line: line)
        XCTAssertEqual(lhs.map { [$0.start.timeIntervalSince1970, $0.end?.timeIntervalSince1970 ?? -1, $0.minute, $0.length, Double($0.lane), Double($0.laneCount)] }, rhs.map { [$0.start.timeIntervalSince1970, $0.end?.timeIntervalSince1970 ?? -1, $0.minute, $0.length, Double($0.lane), Double($0.laneCount)] }, file: file, line: line)
    }
    func testDisplayKeepsCapacityLanesCarryOverAndDSTParity() {
        for zone in ["Europe/Copenhagen", "America/New_York", "Asia/Tokyo"] {
            let c = calendar(zone)
            for date in ["2026-03-29", "2026-10-25", "2026-10-05"] {
                let day = Dates.parse(date, calendar: c)!, prior = c.date(byAdding: .day, value: -1, to: day)!
                var done = task("done", day: date, time: "09:00"); done["completed"] = .bool(true)
                let rows = [task("loose", day: date), task("unknown", day: date, time: "10:00", minutes: nil), task("a", day: date, time: "09:00", minutes: 90), task("b", day: date, time: "09:30", minutes: 60), task("carry", day: TaskPlanner.dayKey(prior, calendar: c), time: "23:30", minutes: 90), done]
                let work = ProductiveTaskReading(tasks: rows), bounds = c.dateInterval(of: .day, for: day)!
                let events = [PlannerEvent(id: "meeting", calendarID: "c", start: day.addingTimeInterval(9*3600), end: day.addingTimeInterval(10*3600)), PlannerEvent(id: "holiday", calendarID: "c", start: bounds.start, end: bounds.end, allDay: true)]
                let result = PlannerDayReading(work: work, events: events, on: day, hours: WorkingHours(weekdays: Set(1...7)), calendar: c)
                assertBlocks(result.blocks, TaskPlanner.blocks(work.presentation, on: day, calendar: c))
                XCTAssertEqual(result.allDay.map(\.id), ["loose"])
                XCTAssertEqual(result.capacity, TaskPlanner.capacity(work.presentation, events: events, on: day, hours: WorkingHours(weekdays: Set(1...7)), calendar: c, reading: work))
                XCTAssertEqual(result.timeline.map(\.id), PlannerTimelineItem.layout(blocks: result.blocks, events: events, on: day, calendar: c).map(\.id))
                XCTAssertEqual(result.allDayEvents.map(\.id), ["holiday"]); XCTAssertEqual(result.timedEvents.map(\.id), ["meeting"])
                XCTAssertEqual(result.ticks.count, Int(bounds.duration / 3600)); XCTAssertEqual(result.laneCount, result.timeline.map(\.laneCount).max() ?? 1)
                XCTAssertEqual(rows.last, done)
            }
        }
    }
    func testAgendaKeepsSameTasksCapacityAndInitialPositionWithoutGraphicalLayout() {
        let c = calendar(), day = Dates.parse("2026-10-05", calendar: c)!
        let work = ProductiveTaskReading(tasks: [task("early", day: "2026-10-05", time: "07:00"), task("loose", day: "2026-10-05")])
        let graph = PlannerDayReading(work: work, events: [], on: day, hours: WorkingHours(), calendar: c)
        let agenda = PlannerDayReading(work: work, events: [], on: day, hours: WorkingHours(), calendar: c, includeTimeline: false)
        assertBlocks(graph.blocks, agenda.blocks); XCTAssertEqual(graph.capacity, agenda.capacity)
        XCTAssertEqual(graph.allDay, agenda.allDay); XCTAssertEqual(agenda.initialHourIndex, 6)
        XCTAssertEqual(graph.initialHourIndex, agenda.initialHourIndex); XCTAssertTrue(agenda.timeline.isEmpty)
    }
    func testNewRenderReadsMovedCompletedTasksEventsDayZoneAndHoursImmediately() {
        let c = calendar(), day = Dates.parse("2026-10-05", calendar: c)!
        var row = task("move", day: "2026-10-05", time: "09:00", minutes: 60)
        let old = PlannerDayReading(work: ProductiveTaskReading(tasks: [row]), events: [], on: day, hours: WorkingHours(), calendar: c)
        row["due_time"] = .string("11:00"); row["duration_minutes"] = .number(90)
        let event = PlannerEvent(id: "fresh", calendarID: "c", start: day.addingTimeInterval(11*3600), end: day.addingTimeInterval(12*3600))
        let next = PlannerDayReading(work: ProductiveTaskReading(tasks: [row]), events: [event], on: day, hours: WorkingHours(start: 600, end: 900), calendar: c)
        XCTAssertNotEqual(old.blocks.first?.start, next.blocks.first?.start); XCTAssertEqual(next.capacity.estimatedMinutes, 90)
        XCTAssertEqual(next.capacity.workingMinutes, 300); XCTAssertEqual(next.timedEvents.map(\.id), ["fresh"])
        XCTAssertEqual(old.capacity.estimatedMinutes, 60); XCTAssertEqual(old.blocks.first?.task.string("due_time"), "09:00")
        row["completed"] = .bool(true)
        let completed = PlannerDayReading(work: ProductiveTaskReading(tasks: [row]), events: [], on: day, hours: nil, calendar: c)
        XCTAssertTrue(completed.blocks.isEmpty); XCTAssertEqual(completed.capacity.estimatedMinutes, 0); XCTAssertEqual(completed.capacity.workingMinutes, 0)
        let tomorrow = PlannerDayReading(work: ProductiveTaskReading(tasks: [row]), events: [], on: c.date(byAdding: .day, value: 1, to: day)!, hours: WorkingHours(), calendar: calendar("America/New_York"))
        XCTAssertTrue(tomorrow.blocks.isEmpty); XCTAssertTrue(tomorrow.allDay.isEmpty)
    }
    func testHeadingAndUnaddressableWorkKeepSeparateDisplayAndCapacitySemantics() {
        let c = calendar(), day = Dates.parse("2026-10-05", calendar: c)!
        var heading = task("heading", day: "2026-10-05", time: "09:00", minutes: 120)
        heading["is_heading"] = .bool(true)
        XCTAssertEqual(TaskKind(heading), .heading)
        heading["subtasks"] = .array([.object(["title": .string("No identity"), "due_date": .string("2026-10-05"), "duration_minutes": .number(25)]), .string("Legacy")])
        let rows = [heading, task("ordinary", day: "2026-10-05", minutes: 25)]
        let original = rows, work = ProductiveTaskReading(tasks: rows)
        let result = PlannerDayReading(work: work, events: [], on: day, hours: WorkingHours(), calendar: c)
        XCTAssertEqual(result.capacity, TaskPlanner.capacity(work.presentation, events: [], on: day, hours: WorkingHours(), calendar: c, reading: work))
        XCTAssertTrue(AuthoredValueComparison.sameRows(rows, original))
        XCTAssertTrue(work.incomplete); XCTAssertEqual(work.unavailable, 2)
        XCTAssertTrue(result.capacity.incomplete); XCTAssertEqual(result.capacity.estimatedMinutes, 50)
        XCTAssertEqual(result.blocks.map(\.id), TaskPlanner.blocks(work.presentation, on: day, calendar: c).map(\.id))
    }
    func testScopedRepeatedPlannerRenderDiagnostic() throws {
        let c = calendar(), day = Dates.parse("2026-10-05", calendar: c)!
        var rows: [Record] = []
        for i in 0..<400 {
            let time: String = i % 4 == 0 ? "" : String(format: "%02d:%02d", 8 + (i % 10), (i % 4)*15)
            let minutes: Int? = i % 9 == 0 ? nil : 25
            rows.append(task("t\(i)", day: "2026-10-05", time: time, minutes: minutes))
        }
        let work = ProductiveTaskReading(tasks: rows), repetitions = 5
        var baselineTotal = 0, preparedTotal = 0
        let baselineStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<repetitions {
            // Conservative repeated reads from the previous summary/timeline:
            // each capacity, block scan, all-day scan and lane layout read twice.
            for _ in 0..<2 {
                let blocks = TaskPlanner.blocks(work.presentation, on: day, calendar: c)
                baselineTotal += blocks.count + TaskPlanner.allDay(work.presentation, on: day, calendar: c).count
                baselineTotal += TaskPlanner.capacity(work.presentation, events: [], on: day, hours: WorkingHours(), calendar: c, reading: work).estimatedMinutes
                baselineTotal += PlannerTimelineItem.layout(blocks: blocks, events: [], on: day, calendar: c).count
            }
        }
        let baselineSeconds = ProcessInfo.processInfo.systemUptime - baselineStart, preparedStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<repetitions {
            let reading = PlannerDayReading(work: work, events: [], on: day, hours: WorkingHours(), calendar: c)
            for _ in 0..<2 { preparedTotal += reading.blocks.count + reading.allDay.count + reading.capacity.estimatedMinutes + reading.timeline.count }
        }
        let preparedSeconds = ProcessInfo.processInfo.systemUptime - preparedStart
        XCTAssertEqual(baselineTotal, preparedTotal)
        if let path = ProcessInfo.processInfo.environment["TASKFOLD_PLANNER_READING_REPORT"] {
            let report: [String: Any] = ["tasks": rows.count, "renderPasses": repetitions, "previousRepeatedReadsSeconds": baselineSeconds, "oneReadingSeconds": preparedSeconds, "sameObservedOutput": baselineTotal == preparedTotal, "debugPreparationOnly": true, "fpsClaim": false]
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
