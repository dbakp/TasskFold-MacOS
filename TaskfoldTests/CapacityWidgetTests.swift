import XCTest
@testable import TaskfoldCore
@testable import WidgetModel

final class CapacityWidgetTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!; return c }
    private let now = ISO8601DateFormatter().date(from: "2026-10-06T08:00:00Z")!
    private func task(_ id: String, date: String = "2026-10-06", time: String = "", minutes: Int? = nil) -> Record {
        var row = Record.task(user: "owner"); row["id"] = .string(id); row["title"] = .string(id)
        row["due_date"] = date.isEmpty ? .null : .string(date); row["due_time"] = time.isEmpty ? .null : .string(time)
        row["duration_minutes"] = minutes.map { .number(Double($0)) } ?? .null; return row
    }
    private func event(_ id: String, _ start: String, _ end: String) -> PlannerEvent {
        PlannerEvent(id: id, calendarID: "secret-calendar", title: "Private calendar title", source: "Secret provider", start: TaskPlanning.instant(start)!, end: TaskPlanning.instant(end)!)
    }
    private func decode(tasks: [Record], events: [PlannerEvent] = [], state: String = "ready", hours: WorkingHours = WorkingHours(), at date: Date? = nil) throws -> WidgetSnapshot {
        let date = date ?? now
        let window = CalendarCapacityWindow(account: "owner", timeZone: calendar.timeZone.identifier, updated: date, state: state, events: events)
        let payload = WidgetProjection.payload(tasks: tasks, projects: [], account: "owner", now: date, calendar: calendar, workingHours: hours, calendarWindow: window)
        return try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(payload))
    }
    func testCapacityMatchesPlannerUnionClippingWorkloadAndMissingEstimates() throws {
        let tasks = [task("timed", time: "09:00", minutes: 90), task("overlapping-task", time: "09:45", minutes: 60), task("all-day", minutes: 30), task("unknown"), task("overdue", date: "2026-10-05", minutes: 90), task("future", date: "2026-10-07", minutes: 45), task("undated", date: "", minutes: 60)]
        let events = [event("a", "2026-10-06T07:30:00Z", "2026-10-06T08:30:00Z"), event("b", "2026-10-06T08:00:00Z", "2026-10-06T09:30:00Z"), event("early", "2026-10-06T06:00:00Z", "2026-10-06T07:00:00Z"), event("late", "2026-10-06T14:30:00Z", "2026-10-06T16:00:00Z")]
        let snapshot = try decode(tasks: tasks, events: events)
        let reading = snapshot.capacityReading(at: now, calendar: calendar), day = try XCTUnwrap(reading.day)
        let planner = TaskPlanner.capacity(tasks, events: events, on: now, hours: WorkingHours(), calendar: calendar)
        XCTAssertEqual(day.working, 480); XCTAssertEqual(day.busy, 150); XCTAssertEqual(day.estimated, 180)
        XCTAssertEqual(day.unknown, 1); XCTAssertEqual(day.overdue, 1); XCTAssertEqual(day.afterKnownWork, 150)
        XCTAssertEqual(day.afterKnownWork, planner.afterKnownWork); XCTAssertTrue(reading.canCalculateRoom)
        let tomorrow = try XCTUnwrap(snapshot.capacityReading(at: now, day: .tomorrow, calendar: calendar).day)
        XCTAssertEqual(tomorrow.estimated, 45); XCTAssertEqual(snapshot.capacity?.days.count, 8)
    }
    func testCrossMidnightFixedTaskAndCompletedWorkAgreeWithEachLocalDay() throws {
        var fixed = task("night", date: "2026-10-05", time: "23:30", minutes: 120)
        fixed["time_zone"] = .string("Europe/Copenhagen"); fixed["scheduled_at"] = .string("2026-10-05T21:30:00Z")
        var done = task("done", minutes: 240); done["completed"] = .bool(true)
        let snapshot = try decode(tasks: [fixed, done, task("invalid", date: "2026-02-31", minutes: 60)])
        XCTAssertEqual(snapshot.capacityReading(at: now, calendar: calendar).day?.estimated, 90)
        var ny = Calendar(identifier: .gregorian); ny.timeZone = TimeZone(identifier: "America/New_York")!
        XCTAssertNil(snapshot.capacityReading(at: now, calendar: ny).day)
        XCTAssertFalse(snapshot.capacityReading(at: now, calendar: ny).canCalculateRoom)
    }
    func testDSTWholeDayHoursUseRealElapsedTimeAndOffDaysDoNotInventCapacity() throws {
        let hours = WorkingHours(start: 0, end: 1440, weekdays: Set(1...7))
        for (stamp, expected) in [("2026-03-29T10:00:00Z",1380),("2026-10-25T10:00:00Z",1500)] {
            let date = TaskPlanning.instant(stamp)!
            let snapshot = try decode(tasks: [], hours: hours, at: date)
            XCTAssertEqual(snapshot.capacityReading(at: date, calendar: calendar).day?.working, expected)
        }
        let saturday = TaskPlanning.instant("2026-10-10T10:00:00Z")!
        let snapshot = try decode(tasks: [task("rest-day", date: "2026-10-10", minutes: 60)], at: saturday)
        XCTAssertEqual(snapshot.capacityReading(at: saturday, calendar: calendar).day?.working, 0)
        XCTAssertEqual(snapshot.capacityReading(at: saturday, calendar: calendar).day?.estimated, 60)
        let overloaded = try decode(tasks: [task("too-much", minutes: 600)])
        XCTAssertEqual(overloaded.capacityReading(at: now, calendar: calendar).day?.afterKnownWork, -120)
    }
    func testCalendarOmissionUnavailableAndPartialDataNeverClaimCompleteRoom() throws {
        for state in ["off", "choose", "unavailable", "incomplete", "future-setting"] {
            let reading = try decode(tasks: [task("work", minutes: 90)], state: state).capacityReading(at: now, calendar: calendar)
            XCTAssertEqual(reading.canCalculateRoom, state == "off")
            XCTAssertNotEqual(reading.calendarNote, "Calendar busy time included")
            XCTAssertEqual(reading.day?.estimated, 90)
        }
        let wrong = CalendarCapacityWindow(account: "other", timeZone: calendar.timeZone.identifier, updated: now, state: "ready", events: [event("secret", "2026-10-06T07:00:00Z", "2026-10-06T17:00:00Z")])
        let payload = WidgetProjection.payload(tasks: [], projects: [], account: "owner", now: now, calendar: calendar, calendarWindow: wrong, calendarFallback: "refresh")
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(payload))
        XCTAssertEqual(snapshot.capacityReading(at: now, calendar: calendar).day?.busy, 0)
        XCTAssertFalse(snapshot.capacityReading(at: now, calendar: calendar).canCalculateRoom)
    }
    func testExpiryIsAnExplicitTimelineEntryAndOldDaysOrTravelRequireRefresh() throws {
        let snapshot = try decode(tasks: [task("work", minutes: 90)])
        let expiry = now.addingTimeInterval(3600)
        XCTAssertTrue(snapshot.capacityTimelineDates(from: now, calendar: calendar).contains(expiry))
        XCTAssertTrue(snapshot.capacityReading(at: expiry.addingTimeInterval(-1), calendar: calendar).canCalculateRoom)
        XCTAssertEqual(snapshot.capacityReading(at: expiry, calendar: calendar).state, "refresh")
        XCTAssertFalse(snapshot.capacityReading(at: expiry, calendar: calendar).canCalculateRoom)
        XCTAssertNil(snapshot.capacityReading(at: now.addingTimeInterval(9 * 86400), calendar: calendar).day)
        XCTAssertFalse(snapshot.capacityReading(at: now.addingTimeInterval(-600), calendar: calendar).canCalculateRoom)
        let off = try decode(tasks: [], state: "off")
        XCTAssertFalse(off.capacityTimelineDates(from: now, calendar: calendar).contains(expiry))
    }
    func testProjectionRetainsOnlyTotalsAndSignOutOmitsCalendarData() throws {
        let event = event("private-event-id", "2026-10-06T07:00:00Z", "2026-10-06T08:00:00Z")
        let window = CalendarCapacityWindow(account: "owner", timeZone: calendar.timeZone.identifier, updated: now, state: "ready", events: [event])
        let payload = WidgetProjection.payload(tasks: [], projects: [], account: "owner", now: now, calendar: calendar, calendarWindow: window)
        let data = try JSONEncoder().encode(payload), text = String(decoding: data, as: UTF8.self)
        for value in [event.id,event.calendarID,event.title,event.source,"events","session","password"] { XCTAssertFalse(text.contains(value)) }
        XCTAssertEqual(Set(payload["capacity"]!.object.keys), ["version","timeZone","calendarState","calendarUpdated","hours","days"])
        let cleared = WidgetProjection.payload(tasks: [], projects: [], account: "", calendarWindow: window)
        XCTAssertNil(cleared["capacity"])
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(cleared))
        XCTAssertNil(snapshot.capacityReading(at: now, calendar: calendar).day)
    }
    func testOldOrUnsupportedCapacityDoesNotBreakOtherWidgets() throws {
        var snapshot = try decode(tasks: [task("old", minutes: 30)])
        snapshot.capacity = nil
        let old = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(old.today(at: now, calendar: calendar).count, 1); XCTAssertNil(old.capacityReading(at: now, calendar: calendar).day)
        snapshot.capacity = WidgetCapacity(version: 99, timeZone: calendar.timeZone.identifier, calendarState: "ready", calendarUpdated: now.timeIntervalSinceReferenceDate, hours: "09:00–17:00", days: [:])
        XCTAssertNil(snapshot.capacityReading(at: now, calendar: calendar).day)
        snapshot.capacity?.version = 1; snapshot.capacity?.days["2026-10-06"] = WidgetCapacityDay(working: 480, busy: 600, estimated: 0, unknown: 0, overdue: 0)
        XCTAssertNil(snapshot.capacityReading(at: now, calendar: calendar).day)
    }
    func testDayLinksValidateGregorianDatesAndMinuteLabelsKeepOverloadSignSeparate() throws {
        XCTAssertNotNil(PlannerWidgetRoute.day(WidgetLinks.scoped("day", id: "2026-10-07")))
        for value in ["taskfold://day/2026-02-31", "taskfold://day/2026-10-07/extra", "taskfold://day/2026-10-07?move=1", "https://day/2026-10-07", "taskfold://today/2026-10-07", "taskfold://day/2026-2-01"] { XCTAssertNil(PlannerWidgetRoute.day(URL(string: value)!)) }
        XCTAssertEqual(WidgetCapacityReading.minutes(-120), "2h"); XCTAssertEqual(WidgetCapacityReading.minutes(150), "2h 30m"); XCTAssertEqual(WidgetCapacityReading.minutes(0), "0m")
    }
}


extension CapacityWidgetTests {
    func testUnreadableWorkingHoursDoNotInventCapacityOrHideTasks() throws {
        let tasks = [task("work", minutes: 90), task("unknown")]
        let payload = WidgetProjection.payload(tasks: tasks, projects: [], account: "owner", now: now, calendar: calendar, workingHours: nil)
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(payload))
        for day: CapacityDay in [.today, .tomorrow] {
            let reading = snapshot.capacityReading(at: now, day: day, calendar: calendar)
            XCTAssertNil(reading.day); XCTAssertFalse(reading.canCalculateRoom)
            XCTAssertEqual(reading.state, "settings"); XCTAssertTrue(reading.calendarNote.contains("Update Taskfold"))
        }
        XCTAssertEqual(snapshot.today(at: now, calendar: calendar).count, 2)
        XCTAssertTrue(snapshot.capacity?.days.isEmpty == true)
        XCTAssertEqual(snapshot.capacity?.hours, "")
        let workload = TaskPlanner.capacity(tasks, events: [], on: now, hours: nil, calendar: calendar)
        XCTAssertEqual(workload.estimatedMinutes, 90); XCTAssertEqual(workload.unknownTasks, 1)
    }
}
