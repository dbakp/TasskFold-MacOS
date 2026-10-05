import XCTest
@testable import WidgetModel

final class WidgetTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1791194400) // 2026-10-05 10:00 UTC
    func task(_ id: String, due: String = "", priority: Int = 4, time: String = "") -> WidgetTask {
        WidgetTask(id: id, title: id, due: due, time: time, priority: priority, project: "", color: "")
    }
    func testFocusRespectsScheduledWorkAndExcludesFuturePriorities() {
        let day = WidgetSnapshot.day(date)
        let snapshot = WidgetSnapshot(updated: 1, tasks: [task("future", due: "2099-01-01", priority: 1), task("undated", priority: 1), task("today", due: day), task("overdue", due: "2026-10-01", priority: 3)])
        XCTAssertEqual(snapshot.focus(at: date)?.id, "overdue")
        XCTAssertEqual(snapshot.today(at: date).map(\.id), ["overdue", "today"])
        XCTAssertEqual(WidgetSnapshot(updated: 1, tasks: [task("future", due: "2099-01-01", priority: 1), task("undated", priority: 2)]).focus(at: date)?.id, "undated")
        XCTAssertNil(WidgetSnapshot(updated: 1, tasks: [task("low"), task("future", due: "2099-01-01", priority: 1)]).focus(at: date))
    }
    func testWeekExcludesOverdueUndatedAndOutsideWindow() {
        let snapshot = WidgetSnapshot(updated: 1, tasks: [task("a", due: WidgetSnapshot.day(date)), task("b", due: WidgetSnapshot.day(date)), task("old", due: "2020-01-01"), task("none"), task("late", due: "2099-01-01")])
        let week = snapshot.week(at: date)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.map(\.count), [2, 0, 0, 0, 0, 0, 0])
    }
    func testMidnightUsesEntryDateAndLocalTimeZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Copenhagen"))
        let nearMidnight = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-24T22:30:00Z"))
        XCTAssertEqual(WidgetSnapshot.day(nearMidnight, calendar: calendar), "2026-10-25")
        let week = WidgetSnapshot.empty.week(at: nearMidnight, calendar: calendar)
        XCTAssertEqual(week.map { WidgetSnapshot.day($0.date, calendar: calendar) }, ["2026-10-25", "2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30", "2026-10-31"])
        let snapshot = WidgetSnapshot(updated: 1, tasks: [task("rollover", due: "2026-10-26")])
        XCTAssertTrue(snapshot.today(at: week[0].date, calendar: calendar).isEmpty)
        XCTAssertEqual(snapshot.today(at: week[1].date, calendar: calendar).count, 1)
    }
    func testLegacySnapshotStillDecodesAndOrderingIsStable() throws {
        let data = Data(##"{"updated":1,"tasks":[{"id":"a","title":"A","due":"2026-10-05","time":"","priority":1,"project":"Work","color":"#ffffff"}]}"##.utf8)
        XCTAssertEqual(try JSONDecoder().decode(WidgetSnapshot.self, from: data).tasks.count, 1)
        let snapshot = WidgetSnapshot(updated: 1, tasks: [task("b", due: "2026-10-05", priority: 1), task("a", due: "2026-10-05", priority: 1, time: "09:00")])
        XCTAssertEqual(snapshot.today(at: date).map(\.id), ["a", "b"])
    }
}
