import XCTest
@testable import TaskfoldCore

final class WidgetCapacityReadingTests: XCTestCase {
    private let account = "ea180000-0000-4000-8000-000000000001"
    private func calendar(_ zone: String = "Europe/Copenhagen") -> Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: zone)!; return value
    }
    /// Previous forecast implementation, kept independent of the prepared path.
    private func reference(_ tasks: [Record], hours: WorkingHours?, window: CalendarCapacityWindow?, now: Date, calendar input: Calendar, fallback: String = "off") -> JSON {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = input.timeZone
        guard let hours else { return .object(["version": .number(1), "timeZone": .string(calendar.timeZone.identifier), "calendarState": .string("settings"), "calendarUpdated": .null, "hours": .string(""), "days": .object([:])]) }
        let usable = window.flatMap { value -> CalendarCapacityWindow? in
            value.account == account && value.timeZone == calendar.timeZone.identifier && now >= value.updated.addingTimeInterval(-300) && now < value.updated.addingTimeInterval(3600) ? value : nil
        }
        let reading = ProductiveTaskReading(tasks: tasks), work = reading.work
        var days: [String: JSON] = [:]
        for offset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }
            let capacity = TaskPlanner.capacity(work, events: usable?.events ?? [], on: day, hours: hours, calendar: calendar, reading: reading)
            let key = TaskPlanner.dayKey(day, calendar: calendar)
            let planned = Set(TaskPlanner.blocks(work, on: day, calendar: calendar).map(\.id) + TaskPlanner.allDay(work, on: day, calendar: calendar).map(\.id))
            let overdue = work.filter { TaskKind.mayComplete($0) && !planned.contains($0.id) && !$0.completed && !$0.string("due_date").isEmpty && Dates.parse(TaskPlanner.plannedDay($0, calendar: calendar)) != nil && TaskPlanner.plannedDay($0, calendar: calendar) < key }.count
            var row: [String: JSON] = ["working": .number(Double(capacity.workingMinutes)), "busy": .number(Double(capacity.busyMinutes)), "estimated": .number(Double(capacity.estimatedMinutes)), "unknown": .number(Double(capacity.unknownTasks)), "overdue": .number(Double(overdue))]
            if reading.incomplete { row["workIncomplete"] = .bool(true) }; days[key] = .object(row)
        }
        return .object(["version": .number(1), "timeZone": .string(calendar.timeZone.identifier), "calendarState": .string(usable?.state ?? fallback), "calendarUpdated": usable.map { .number($0.updated.timeIntervalSinceReferenceDate) } ?? .null, "hours": .string(String(format: "%02d:%02d–%02d:%02d", hours.start / 60, hours.start % 60, hours.end / 60, hours.end % 60)), "days": .object(days)])
    }
    private func task(_ id: String, day: String, time: String = "", minutes: Int? = 25, zone: String = "", instant: String = "") -> Record {
        var row = Record(["id": .string(id), "user_id": .string(account), "title": .string("Work \(id)"), "project_id": .string("ea180000-0000-4000-8000-000000000002"), "due_date": .string(day), "due_time": .string(time), "time_zone": .string(zone), "scheduled_at": .string(instant), "completed": .bool(false), "subtasks": .array([])])
        if let minutes { row["duration_minutes"] = .number(Double(minutes)) }; return row
    }
    func testFullRenderStageDiagnostic() throws {
        let c = calendar(), now = TaskPlanning.instant("2026-10-24T10:00:00Z")!, count = 1000
        var rows: [Record] = []
        for i in 0..<count {
            let date = c.date(byAdding: .day, value: i % 10 - 1, to: now)!, key = TaskPlanner.dayKey(date, calendar: c)
            let timed = i % 3 != 0, fixed = i % 3 == 1
            let zone = fixed ? "Europe/Copenhagen" : ""
            var row = task("t\(i)", day: key, time: timed ? "09:30" : "", minutes: i % 11 == 0 ? nil : 60, zone: zone)
            if fixed, let start = TaskPlanning.start(row, calendar: c) { row["scheduled_at"] = .string(ISO8601DateFormatter().string(from: start)) }
            if i % 13 == 0 { row["completed"] = .bool(true) }; rows.append(row)
        }
        let original = rows, hours = WorkingHours(weekdays: Set(1...7)), clock = ContinuousClock(), start = clock.now
        let result = WidgetProjection.capacityPayload(tasks: rows, account: account, hours: hours, window: nil, fallback: "off", now: now, calendar: c)
        let capacityTime = start.duration(to: clock.now), fullStart = clock.now
        let payload = WidgetProjection.payload(tasks: rows, projects: [Record(["id": .string("ea180000-0000-4000-8000-000000000002"), "name": .string("Work")])], account: account, now: now, calendar: c, workingHours: hours)
        let fullTime = fullStart.duration(to: clock.now)
        XCTAssertEqual(payload["capacity"], result); XCTAssertEqual(result.object["days"]?.object.count, 8)
        XCTAssertTrue(AuthoredValueComparison.sameRows(rows, original))
        func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
        print("WIDGET_RENDER_DIAGNOSTIC " + String(data: try JSONSerialization.data(withJSONObject: ["tasks": count, "capacitySeconds": seconds(capacityTime), "fullPayloadSeconds": seconds(fullTime)], options: .sortedKeys), encoding: .utf8)!)
        if ProcessInfo.processInfo.environment["TASKFOLD_WIDGET_CAPACITY_GOLDEN"] == "1" {
            let expected = reference(rows, hours: hours, window: nil, now: now, calendar: c)
            let golden: JSON = .object(["protocol": .number(1), "account": .string(account), "timeZone": .string(c.timeZone.identifier), "now": .number(now.timeIntervalSinceReferenceDate), "hours": hours.document, "tasks": .array(rows.map { .object($0.fields) }), "projects": .array([.object(["id": .string("ea180000-0000-4000-8000-000000000002"), "name": .string("Work")])]), "expectedCapacity": expected])
            try TaskfoldJSONEncoder().encode(golden).write(to: URL(fileURLWithPath: "/tmp/taskfold-widget-capacity-native-input.json"), options: .atomic)
        }
    }
}

extension WidgetCapacityReadingTests {
    private func assertParity(_ rows: [Record], now: Date, calendar: Calendar, hours: WorkingHours? = WorkingHours(weekdays: Set(1...7)), window: CalendarCapacityWindow? = nil, fallback: String = "off", file: StaticString = #filePath, line: UInt = #line) {
        let original = rows
        XCTAssertEqual(WidgetProjection.capacityPayload(tasks: rows, account: account, hours: hours, window: window, fallback: fallback, now: now, calendar: calendar), reference(rows, hours: hours, window: window, now: now, calendar: calendar, fallback: fallback), file: file, line: line)
        XCTAssertTrue(AuthoredValueComparison.sameRows(rows, original), file: file, line: line)
    }
    func testForecastMatchesExistingPlannerAcrossZonesDSTAndCarryOver() {
        for zone in ["Europe/Copenhagen", "America/New_York", "Australia/Lord_Howe", "Pacific/Apia"] {
            let c = calendar(zone)
            for stamp in ["2026-03-29", "2026-10-25", "2026-10-04", "2011-12-29"] {
                let now = Dates.parse(stamp, calendar: c)!, yesterday = TaskPlanner.dayKey(c.date(byAdding: .day, value: -1, to: now)!, calendar: c)
                var done = task("done", day: stamp, time: "10:00", minutes: 60); done["completed"] = .bool(true)
                let rows = [task("carry", day: yesterday, time: "23:45", minutes: 180), task("loose", day: stamp, minutes: 7), task("point", day: stamp, time: "13:00", minutes: nil), task("gap-fold", day: stamp, time: "02:15", minutes: 30), task("fixed", day: stamp, time: "01:30", minutes: 90, zone: "America/New_York", instant: stamp + "T06:30:00.500Z"), done]
                assertParity(rows, now: now, calendar: c, hours: WorkingHours(start: 0, end: 1440, weekdays: Set(1...7)))
            }
        }
    }
    func testUnknownInvalidAndDuplicateIdentitiesKeepExactCountingRules() {
        let c = calendar(), now = Dates.parse("2026-10-24", calendar: c)!
        let rows = [task("same", day: "2026-10-23", time: "23:30", minutes: 120), task("same", day: "2026-10-22", time: "invalid", minutes: nil), task("", day: "2026-10-22"), task("", day: "2026-10-24"), task("bad-day", day: "2026-02-31"), task("bad-zone", day: "2026-10-23", time: "10:00", zone: "Invalid/Zone"), task("no-day", day: "", time: "10:00"), task("bad-time", day: "2026-10-23", time: "25:00"), task("no-estimate", day: "2026-10-24", minutes: nil)]
        assertParity(rows, now: now, calendar: c)
    }
    func testFractionalInstantsPreserveClippingSummationAndRounding() {
        let c = calendar(), now = Dates.parse("2026-10-25", calendar: c)!
        let rows = (0..<37).map { i in task("fraction-\(i)", day: "2026-10-24", time: "23:50", minutes: 25, zone: "Europe/Copenhagen", instant: String(format: "2026-10-24T21:50:00.%03dZ", i * 23)) }
        assertParity(rows, now: now, calendar: c)
    }
    func testIncompleteHeadingAndUnaddressableWorkRetainTotalsAndFlag() {
        let c = calendar(), now = Dates.parse("2026-10-24", calendar: c)!
        var heading = task("heading", day: "2026-10-24", time: "09:00", minutes: 180)
        heading["is_heading"] = .bool(true)
        heading["subtasks"] = .array([.object(["title": .string("No identity"), "due_date": .string("2026-10-24"), "duration_minutes": .number(25)]), .string("Legacy instruction")])
        assertParity([heading, task("regular", day: "2026-10-24")], now: now, calendar: c)
        let value = WidgetProjection.capacityPayload(tasks: [heading], account: account, hours: WorkingHours(), window: nil, fallback: "off", now: now, calendar: c)
        XCTAssertTrue(value.object["days"]!.object.values.allSatisfy { $0.object["workIncomplete"] == .bool(true) })
    }
    func testHoursCalendarFreshnessAccountAndSettingsStayUnchanged() {
        let c = calendar(), now = TaskPlanning.instant("2026-10-24T10:00:00Z")!
        let rows = [task("timed", day: "2026-10-24", time: "09:00", minutes: 90), task("unknown", day: "2026-10-24", minutes: nil)]
        let events = [PlannerEvent(id: "a", calendarID: "private", title: "Private title", start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(3600)), PlannerEvent(id: "b", calendarID: "private", start: now, end: now.addingTimeInterval(7200))]
        for (account, zone, updated) in [(self.account, c.timeZone.identifier, now), ("other", c.timeZone.identifier, now), (self.account, "Asia/Tokyo", now), (self.account, c.timeZone.identifier, now.addingTimeInterval(-3600)), (self.account, c.timeZone.identifier, now.addingTimeInterval(301))] {
            let window = CalendarCapacityWindow(account: account, timeZone: zone, updated: updated, state: "ready", events: events)
            assertParity(rows, now: now, calendar: c, window: window, fallback: "refresh")
        }
        assertParity(rows, now: now, calendar: c, hours: nil)
        assertParity(rows, now: now, calendar: c, hours: WorkingHours(weekdays: []))
    }
    func testSeparateRendersReadMovedCompletedTasksAndTravelImmediately() {
        let c = calendar(), now = Dates.parse("2026-10-24", calendar: c)!
        var row = task("current", day: "2026-10-24", time: "09:00", minutes: 60, zone: "Europe/Copenhagen", instant: "2026-10-24T07:00:00Z")
        let first = WidgetProjection.capacityPayload(tasks: [row], account: account, hours: WorkingHours(), window: nil, fallback: "off", now: now, calendar: c)
        row["duration_minutes"] = .number(120); row["due_date"] = .string("2026-10-25"); row["scheduled_at"] = .string("2026-10-25T08:00:00Z")
        assertParity([row], now: now, calendar: c); XCTAssertNotEqual(first, WidgetProjection.capacityPayload(tasks: [row], account: account, hours: WorkingHours(), window: nil, fallback: "off", now: now, calendar: c))
        assertParity([row], now: now, calendar: calendar("America/New_York"))
        row["completed"] = .bool(true); assertParity([row], now: now, calendar: c)
    }
}
