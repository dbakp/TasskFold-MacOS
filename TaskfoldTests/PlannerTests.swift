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
