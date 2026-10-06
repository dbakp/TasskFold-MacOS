import XCTest
@testable import TaskfoldCore
@testable import WidgetModel

final class ProductivityWidgetTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-05T21:30:00Z")!
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!; return calendar
    }
    private func task(_ id: String, due: String = "", deadline: String? = nil, minutes: Int? = nil, project: String = "") -> WidgetTask {
        WidgetTask(id: id, title: id, due: due, time: "", priority: 2, project: project.isEmpty ? "" : "Project", color: "#e31e4b", projectID: project, deadline: deadline, duration: minutes)
    }
    func testProducerDecoderContractAndSignedOutClear() throws {
        var row = Record.task(user: "owner", project: "project")
        row["title"] = .string("Draft"); row["deadline_date"] = .string("2026-10-09"); row["duration_minutes"] = .number(25)
        row["due_date"] = .string("2026-10-06"); row["due_time"] = .string("00:30:00"); row["time_zone"] = .string("Europe/Copenhagen")
        var complete = row; complete["id"] = .string("done"); complete["completed"] = .bool(true)
        let project = Record(["id": .string("project"), "name": .string("Studio"), "color": .string("#112233")])
        let payload = WidgetProjection.payload(tasks: [row, complete], projects: [project], account: "owner", now: now)
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(payload))
        XCTAssertEqual(snapshot.version, 2); XCTAssertEqual(snapshot.account, "owner"); XCTAssertEqual(snapshot.tasks.count, 1)
        let task = try XCTUnwrap(snapshot.tasks.first)
        XCTAssertEqual(task.deadline, "2026-10-09"); XCTAssertEqual(task.duration, 25); XCTAssertEqual(task.projectID, "project")
        XCTAssertEqual(task.project, "Studio"); XCTAssertEqual(task.time, "00:30"); XCTAssertEqual(task.scheduledAt, "2026-10-05T22:30:00Z")
        XCTAssertEqual(task.displayed(calendar: calendar("America/New_York")).due, TaskPlanner.plannedDay(row, calendar: calendar("America/New_York")))
        let cleared = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(WidgetProjection.payload(tasks: [row], projects: [project], account: "", now: now)))
        XCTAssertTrue(cleared.tasks.isEmpty); XCTAssertEqual(cleared.updated, 0); XCTAssertEqual(cleared.account, "")
        XCTAssertEqual(Set(payload.keys), ["version", "updated", "account", "tasks", "lists"])
    }
    func testFixedTimeTravelAndFloatingTimeUseTheSameLocalDayAsPlanner() {
        var fixed = task("fixed", due: "2026-10-06", deadline: "2026-10-09", minutes: 25)
        fixed.time = "00:30"; fixed.timeZone = "Europe/Copenhagen"; fixed.scheduledAt = "2026-10-05T22:30:00.000Z"
        var floating = fixed; floating.id = "floating"; floating.timeZone = nil; floating.scheduledAt = nil
        let snapshot = WidgetSnapshot(updated: 1, tasks: [floating, fixed])
        let ny = calendar("America/New_York"), cph = calendar("Europe/Copenhagen")
        XCTAssertEqual(snapshot.today(at: now, calendar: ny).map(\.id), ["fixed"])
        XCTAssertTrue(snapshot.today(at: now, calendar: cph).isEmpty)
        let projected = fixed.displayed(calendar: ny)
        XCTAssertEqual(projected.time, "18:30"); XCTAssertEqual(projected.due, "2026-10-05"); XCTAssertEqual(projected.deadlineDay, "2026-10-09")
        XCTAssertEqual(snapshot.week(at: now, calendar: ny).map(\.count).prefix(2), [1, 1])
    }
    func testRepeatedClocksOrderByTheirRealInstant() {
        var first = task("z-first", due: "2026-10-25"); first.time = "02:45"; first.timeZone = "Europe/Copenhagen"; first.scheduledAt = "2026-10-25T00:45:00Z"
        var last = task("a-last", due: "2026-10-25"); last.time = "02:15"; last.timeZone = first.timeZone; last.scheduledAt = "2026-10-25T01:15:00+00:00"
        let day = ISO8601DateFormatter().date(from: "2026-10-25T10:00:00Z")!
        XCTAssertEqual(WidgetSnapshot(updated: 1, tasks: [last, first]).today(at: day, calendar: calendar("Europe/Copenhagen")).map(\.id), ["z-first", "a-last"])
    }
    func testDeadlineRadarUsesHardCutoffsAndInclusiveWindow() {
        let rows = [task("planned-only", due: "2026-10-05"), task("tomorrow", due: "2099-01-01", deadline: "2026-10-06"), task("missed", deadline: "2026-10-01"), task("last", deadline: "2026-10-11"), task("outside", deadline: "2026-10-12"), task("invalid", deadline: "2026-02-31")]
        let snapshot = WidgetSnapshot(updated: 1, tasks: rows)
        XCTAssertEqual(snapshot.deadlines(at: now, calendar: calendar("UTC")).map(\.id), ["missed", "tomorrow", "last"])
        XCTAssertEqual(snapshot.deadlines(at: now, days: 1, calendar: calendar("UTC")).map(\.id), ["missed"])
        XCTAssertTrue(snapshot.deadlines(at: now, days: 0).isEmpty); XCTAssertTrue(snapshot.deadlines(at: now, days: 31).isEmpty)
        XCTAssertTrue(WidgetSnapshot.validDay("2024-02-29")); XCTAssertFalse(WidgetSnapshot.validDay("2026-02-29"))
        XCTAssertFalse(WidgetSnapshot.validDay("2026-2-09")); XCTAssertFalse(WidgetSnapshot.validDay("2026-10-05extra"))
    }
    func testSmallWindowRequiresAnHonestEstimateAndNeverIncludesFutureReadyWork() {
        let rows = [task("ten", minutes: 10), task("exact", due: "2026-10-05", minutes: 25), task("too-long", minutes: 26), task("unknown"), task("zero", minutes: 0), task("negative", minutes: -5), task("invalid", minutes: 10081), task("future", due: "2026-10-06", minutes: 5)]
        let snapshot = WidgetSnapshot(updated: 1, tasks: rows)
        XCTAssertEqual(snapshot.smallWindow(minutes: 10, at: now, calendar: calendar("UTC")).map(\.id), ["ten"])
        XCTAssertEqual(snapshot.smallWindow(minutes: 25, at: now, calendar: calendar("UTC")).map(\.id), ["exact", "ten"])
        XCTAssertTrue(snapshot.smallWindow(minutes: 0, at: now).isEmpty)
        XCTAssertEqual(snapshot.windowTasks(scope: .ready, at: now, calendar: calendar("UTC")).filter { $0.estimate == nil }.count, 4)
    }
    func testInvalidPlannedDateIsNotPretendedToBeReadyUndatedWork() {
        let malformed = task("malformed", due: "2026-00-01", minutes: 10)
        let snapshot = WidgetSnapshot(updated: 1, tasks: [malformed])
        XCTAssertEqual(malformed.displayed(calendar: calendar("UTC")).due, "2026-00-01")
        XCTAssertTrue(snapshot.today(at: now).isEmpty)
        XCTAssertNil(snapshot.focus(at: now))
        XCTAssertTrue(snapshot.smallWindow(minutes: 10, scope: .ready, at: now).isEmpty)
        XCTAssertEqual(snapshot.smallWindow(minutes: 10, scope: .all, at: now).map(\.id), ["malformed"])
    }
    func testIndependentBudgetsAndScopesUseIDsAndStableRanking() {
        let snapshot = WidgetSnapshot(updated: 1, tasks: [task("b", deadline: "2026-10-08", minutes: 10), task("a", deadline: "2026-10-08", minutes: 10), task("project", deadline: "2026-10-06", minutes: 25, project: "p"), task("later", due: "2026-10-20", minutes: 45)])
        XCTAssertEqual(snapshot.smallWindow(minutes: 10, scope: .inbox, at: now).map(\.id), ["a", "b"])
        XCTAssertEqual(snapshot.smallWindow(minutes: 25, scope: .ready, at: now).map(\.id), ["project", "a", "b"])
        XCTAssertEqual(snapshot.smallWindow(minutes: 45, scope: .all, at: now).map(\.id), ["project", "a", "b", "later"])
        XCTAssertEqual(snapshot.smallWindow(minutes: 10, scope: .inbox, at: now).map(\.id), ["a", "b"])
    }
    func testLegacyAndFutureVersionsCannotClaimPlanningFields() throws {
        let legacy = Data(##"{"updated":1,"tasks":[{"id":"a","title":"A","due":"2026-10-05","time":"","priority":1,"project":"Work","color":"#ffffff"}]}"##.utf8)
        let old = try JSONDecoder().decode(WidgetSnapshot.self, from: legacy)
        XCTAssertEqual(old.version, 1); XCTAssertFalse(old.hasPlanningFields)
        XCTAssertTrue(old.deadlines(at: now).isEmpty); XCTAssertTrue(old.smallWindow(minutes: 25, at: now).isEmpty)
        XCTAssertEqual(old.today(at: now, calendar: calendar("UTC")).map(\.id), ["a"])
        let future = Data(#"{"version":99,"updated":1,"account":"owner","tasks":[]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(WidgetSnapshot.self, from: future))
        let modern = WidgetSnapshot(updated: 5, tasks: [task("new", deadline: "2026-10-09", minutes: 25)], account: "owner")
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(modern))
        XCTAssertTrue(decoded.hasPlanningFields); XCTAssertEqual(decoded.tasks.first?.estimate, 25); XCTAssertEqual(decoded.account, "owner")
    }
    func testDailyTimelineCrossesRealDSTMidnightsAndPreferredCalendars() {
        for value in ["2026-03-28T12:00:00Z", "2026-10-24T12:00:00Z"] {
            let date = ISO8601DateFormatter().date(from: value)!, cph = calendar("Europe/Copenhagen")
            let dates = WidgetSnapshot.timelineDates(from: date, calendar: cph)
            XCTAssertEqual(dates.count, 8); XCTAssertEqual(dates.first, date)
            XCTAssertTrue(zip(dates, dates.dropFirst()).allSatisfy { $0 < $1 })
            XCTAssertTrue(dates.dropFirst().allSatisfy { cph.component(.hour, from: $0) == 0 })
            let interval = dates[2].timeIntervalSince(dates[1])
            XCTAssertEqual(interval, value.contains("03-") ? 23 * 3600 : 25 * 3600)
        }
        var buddhist = Calendar(identifier: .buddhist); buddhist.timeZone = calendar("UTC").timeZone
        XCTAssertEqual(WidgetSnapshot.day(now, calendar: buddhist), "2026-10-05")
    }
    func testTaskLinksEncodeReservedCharactersWithoutChangingTheirIdentity() throws {
        let url = WidgetLinks.task("task name/#?%")
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "taskfold"); XCTAssertEqual(parts.host, "task")
        XCTAssertEqual(parts.percentEncodedPath, "/task%20name%2F%23%3F%25"); XCTAssertNil(parts.query); XCTAssertNil(parts.fragment)
    }
}
