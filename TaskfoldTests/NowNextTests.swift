import XCTest
@testable import TaskfoldCore

final class NowNextTests: XCTestCase {
    let id1 = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", id2 = "cccccccc-cccc-4ccc-8ccc-cccccccccccc", id3 = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 10, minute: 0))! }
    var today: String { Dates.day(now) }
    func task(_ id: String, _ title: String, time: String? = nil, minutes: Int? = nil, priority: Int = 4, due: String? = nil, done: Bool = false) -> Record {
        var f: [String: JSON] = ["id": .string(id), "title": .string(title), "completed": .bool(done), "priority": .number(Double(priority)), "due_date": .string(due ?? today)]
        if let time { f["due_time"] = .string(time) }
        if let minutes { f["duration_minutes"] = .number(Double(minutes)) }
        return Record(f)
    }

    func testRunningFocusWinsAndShowsRemainingTime() throws {
        let session = try FocusSession(taskID: id1, minutes: 25, now: now.addingTimeInterval(-7 * 60))
        let item = NowNext.resolve(focus: session, tasks: [task(id1, "Write report"), task(id2, "Other", time: "10:30")], now: now, calendar: calendar)
        guard case .focus(let focus) = item else { return XCTFail("\(item)") }
        XCTAssertEqual(focus.title, "Write report"); XCTAssertEqual(focus.remaining, 18 * 60, accuracy: 1); XCTAssertFalse(focus.paused)
        XCTAssertEqual(NowNext.compactTitle(item), "▸ Write report · 18m")
        XCTAssertEqual(NowNext.taskID(item), id1)
    }
    func testPausedFocusIsLabelledAndFinishedStoppedOrCompletedFocusFallsThrough() throws {
        let paused = try FocusSession(taskID: id1, minutes: 25, now: now).paused(at: now.addingTimeInterval(60))
        XCTAssertEqual(NowNext.compactTitle(NowNext.resolve(focus: paused, tasks: [task(id1, "Write")], now: now, calendar: calendar)), "▸ Write · paused 24m")
        let finished = try FocusSession(taskID: id1, minutes: 1, now: now.addingTimeInterval(-3600))
        XCTAssertEqual(NowNext.resolve(focus: finished, tasks: [task(id1, "Write")], now: now, calendar: calendar), .next(.init(taskID: id1, title: "Write", time: nil, inProgress: false)))
        let stopped = try FocusSession(taskID: id1, minutes: 25, now: now).stopped(at: now)
        XCTAssertEqual(NowNext.taskID(NowNext.resolve(focus: stopped, tasks: [], now: now, calendar: calendar)), nil)
        let running = try FocusSession(taskID: id1, minutes: 25, now: now)
        XCTAssertEqual(NowNext.resolve(focus: running, tasks: [task(id1, "Done", done: true)], now: now, calendar: calendar), .clear)
    }
    func testNextTimedBlockBeatsUntimedAndPicksSoonestUpcoming() {
        let tasks = [task(id1, "Untimed", priority: 1), task(id2, "Later", time: "15:00"), task(id3, "Soon", time: "11:00")]
        XCTAssertEqual(NowNext.resolve(focus: nil, tasks: tasks, now: now, calendar: calendar), .next(.init(taskID: id3, title: "Soon", time: "11:00", inProgress: false)))
        XCTAssertEqual(NowNext.compactTitle(.next(.init(taskID: id3, title: "Soon", time: "11:00", inProgress: false))), "11:00 Soon")
    }
    func testBlockInProgressIsNowAndPassedBlockWithoutDurationIsNotCurrent() {
        let tasks = [task(id1, "Meeting", time: "09:30", minutes: 60), task(id2, "Earlier", time: "08:00")]
        XCTAssertEqual(NowNext.resolve(focus: nil, tasks: tasks, now: now, calendar: calendar), .next(.init(taskID: id1, title: "Meeting", time: "09:30", inProgress: true)))
        XCTAssertEqual(NowNext.resolve(focus: nil, tasks: [tasks[1]], now: now, calendar: calendar), .next(.init(taskID: id2, title: "Earlier", time: "08:00", inProgress: false)))
    }
    func testUntimedOrderedByPriorityThenTitleAndIgnoresOtherDaysCompletedAndHeadings() {
        var heading = task("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", "Heading", priority: 1); heading["is_heading"] = .bool(true)
        let tasks = [task(id1, "Zed", priority: 2), task(id2, "Alpha", priority: 2), task(id3, "Top", priority: 3, due: "2020-01-01"), task("ffffffff-ffff-4fff-8fff-ffffffffffff", "Done", priority: 1, done: true), heading]
        XCTAssertEqual(NowNext.resolve(focus: nil, tasks: tasks, now: now, calendar: calendar), .next(.init(taskID: id2, title: "Alpha", time: nil, inProgress: false)))
        XCTAssertEqual(NowNext.resolve(focus: nil, tasks: [], now: now, calendar: calendar), .clear)
        XCTAssertNil(NowNext.compactTitle(.clear))
    }
    func testFormattingHelpers() {
        XCTAssertEqual(NowNext.remainingText(0), "0s"); XCTAssertEqual(NowNext.remainingText(45.2), "46s"); XCTAssertEqual(NowNext.remainingText(61), "2m")
        XCTAssertEqual(NowNext.remainingText(3600), "1h 00m"); XCTAssertEqual(NowNext.remainingText(3900), "1h 05m")
        XCTAssertEqual(NowNext.truncated("Short", 24), "Short")
        XCTAssertEqual(NowNext.truncated("A very long task title that goes on", 10), "A very lo…")
        XCTAssertEqual(NowNext.summary(.clear), "Nothing due today")
        XCTAssertEqual(NowNext.summary(.next(.init(taskID: id1, title: "X", time: "09:00", inProgress: true))), "Now: X at 09:00")
    }
}
