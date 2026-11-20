import XCTest
@testable import TaskfoldCore

/// The day ring as Today's hero (Core/DayPlan.swift): the header figure, the drop preview, the tray's candidates and
/// the overbooked fix. Numbers follow the approved mockup: working hours 9:00–16:30 (7h 30m).
final class DayRingHeroTests: XCTestCase {
    func cal() -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!; return c }
    let hours = WorkingHours(start: 540, end: 990, weekdays: Set(1...7))
    var friday: Date { Dates.parse("2026-11-20", calendar: cal())! }
    func task(_ id: String, minutes: Int? = nil, project: String = "work", date: String? = "2026-11-20", time: String? = nil, done: Bool = false,
              created: String = "2026-11-18T09:00:00Z") -> Record {
        var row = Record.task(user: "owner", createdAt: created)
        row["id"] = .string(id); row["title"] = .string("Task " + id); row["project_id"] = .string(project)
        row["due_date"] = date.map(JSON.string) ?? .null
        if let time { row["due_time"] = .string(time) }
        if let minutes { row["duration_minutes"] = .number(Double(minutes)) }
        if done { row["completed"] = .bool(true); row["completed_at"] = .string("2026-11-20T10:00:00Z") }
        return row
    }
    func ring(_ tasks: [Record], hours: WorkingHours? = nil) -> TodayRing {
        DayPlan.todayRing(tasks, events: [], on: friday, hours: hours ?? self.hours, calendar: cal())
    }
    /// Frame A's day: 4h 30m planned of 7h 30m, 1h 30m of it done.
    var heroDay: [Record] {
        [task("big", minutes: 60, project: "writing", time: "10:00", done: true), task("q4", minutes: 90, time: "13:00"),
         task("sketch", minutes: 45, project: "writing"), task("walk", minutes: 30, project: "health", done: true), task("plan", minutes: 45, project: "home")]
    }

    // MARK: Frame A

    func testHeroFigureWithinHours() {
        let hero = DayPlan.heroFigure(ring(heroDay))
        XCTAssertEqual(hero.figure, DayFigure(lead: "4h 30m", leadIsAlert: false, rest: " of 7h 30m"))
        XCTAssertEqual(hero.meta, "3h free · 1h 30m done")
        XCTAssertFalse(hero.isEmpty)
    }
    func testHeroFigureLeavesDoneOutWhenNothingIsDone() {
        XCTAssertEqual(DayPlan.heroFigure(ring([task("a", minutes: 30)])).meta, "7h free")
    }
    func testHeroFigureWhenTheDayIsExactlyFull() {
        XCTAssertEqual(DayPlan.heroFigure(ring([task("a", minutes: 450)])).meta, "No free time left")
    }
    func testHeroFigureWithoutWorkingHours() {
        let r = DayPlan.todayRing([task("a", minutes: 45, done: true)], events: [], on: friday, hours: WorkingHours(weekdays: []), calendar: cal())
        let hero = DayPlan.heroFigure(r)
        XCTAssertEqual(hero.figure, DayFigure(lead: "45m", rest: " planned"))
        XCTAssertEqual(hero.meta, "45m done")
    }

    // MARK: Frame F

    func testHeroFigureIsEmptyWithoutEstimates() {
        let hero = DayPlan.heroFigure(ring([task("a"), task("b", time: "10:00")]))
        XCTAssertTrue(hero.isEmpty)
        XCTAssertEqual(hero.meta, "")
    }

    // MARK: Frame E

    var overDay: [Record] {
        heroDay + [task("deck", minutes: 120), task("news", minutes: 45, project: "writing"), task("board", minutes: 90, time: "15:00")]
    }
    func testHeroFigureWhenOverbooked() {
        let r = ring(overDay)
        XCTAssertEqual(r.plannedMinutes, 525); XCTAssertEqual(r.overMinutes, 75)
        let fix = DayPlan.overflowFix(overDay, ring: r, on: friday, calendar: cal())
        let hero = DayPlan.heroFigure(r, suggestion: DayPlan.overflowSuggestion(fix))
        XCTAssertEqual(hero.figure, DayFigure(lead: "1h 15m over", leadIsAlert: true, rest: " · 8h 45m of 7h 30m"))
        XCTAssertEqual(hero.meta, "Move \u{201C}Task deck\u{201D} to tomorrow?")
    }
    func testOverflowFixPrefersTheSmallestSingleTaskThatIsBigEnough() {
        // 75m over. Untimed, open candidates: sketch 45, plan 45, deck 120, news 45, and an untimed 90.
        var tasks = overDay
        tasks[tasks.count - 1] = task("board", minutes: 90)
        let r = ring(tasks)
        XCTAssertEqual(r.overMinutes, 75)
        XCTAssertEqual(DayPlan.overflowFix(tasks, ring: r, on: friday, calendar: cal()).map(\.id), ["board"], "90m is the smallest task that clears 75m on its own")
    }
    func testOverflowFixSkipsDoneTimedAndUnestimatedWork() {
        // Hours 9:00–15:00 (6h), 7h 30m planned: 90m over. Done (big 60, walk 30) and timed (q4 90) work never moves,
        // nor does a task without an estimate; nothing open is 90m on its own.
        let short = WorkingHours(start: 540, end: 900, weekdays: Set(1...7))
        let tasks = heroDay + [task("x", minutes: 45), task("y", minutes: 45, project: "home"), task("w", minutes: 45), task("v", minutes: 45), task("z")]
        let r = ring(tasks, hours: short)
        XCTAssertEqual(r.overMinutes, 90)
        let fix = DayPlan.overflowFix(tasks, ring: r, on: friday, calendar: cal())
        XCTAssertFalse(fix.contains { ["big", "walk", "q4", "z"].contains($0.id) })
        XCTAssertEqual(fix.count, 2, "no single task covers 90m, so two do")
        XCTAssertEqual(fix.reduce(0) { $0 + ($1.durationMinutes ?? 0) }, 90)
    }
    func testOverflowFixSwapsTheLastPickForTheSmallestThatStillCovers() {
        // Free 7h 30m, planned 9h 20m: 110m over. Open untimed: 100, 60, 15. Largest first takes 100 + 60; 100 + 15 also covers.
        let tasks = [task("a", minutes: 100), task("b", minutes: 60), task("c", minutes: 15), task("t", minutes: 385, time: "09:00")]
        let r = ring(tasks)
        XCTAssertEqual(r.overMinutes, 110)
        XCTAssertEqual(DayPlan.overflowFix(tasks, ring: r, on: friday, calendar: cal()).map(\.id), ["a", "c"])
    }
    func testOverflowFixMovesEverythingMovableWhenThatIsStillNotEnough() {
        let tasks = [task("a", minutes: 20), task("b", minutes: 10), task("t", minutes: 500, time: "09:00")]
        let r = ring(tasks)
        XCTAssertEqual(DayPlan.overflowFix(tasks, ring: r, on: friday, calendar: cal()).map(\.id), ["a", "b"])
    }
    func testOverflowFixIsEmptyWithinHours() {
        XCTAssertEqual(DayPlan.overflowFix(heroDay, ring: ring(heroDay), on: friday, calendar: cal()), [])
    }
    func testOverflowSuggestionAndToastCopy() {
        let a = task("a"), b = task("b"), c = task("c")
        XCTAssertNil(DayPlan.overflowSuggestion([]))
        XCTAssertEqual(DayPlan.overflowSuggestion([a, b]), "Move \u{201C}Task a\u{201D} and \u{201C}Task b\u{201D} to tomorrow?")
        XCTAssertEqual(DayPlan.overflowSuggestion([a, b, c]), "Move 3 tasks to tomorrow?")
        XCTAssertEqual(DayPlan.overflowFixToast([a]), "Moved \u{201C}Task a\u{201D} to tomorrow")
        XCTAssertEqual(DayPlan.overflowFixToast([a, b]), "Moved 2 tasks to tomorrow")
    }

    // MARK: Frames C and D

    func testDropPreviewAddsAGhostSegmentAndPreviewsTheFigures() {
        let r = ring(heroDay)
        let preview = DayPlan.dropPreview(r, id: "news", projectID: "writing", minutes: 45)
        XCTAssertEqual(preview.tooltip, "Drop to plan · +45m → 5h 15m of 7h 30m")
        XCTAssertEqual(preview.hero.figure, DayFigure(lead: "5h 15m", rest: " of 7h 30m"))
        XCTAssertEqual(preview.hero.meta, "2h 15m free after this")
        XCTAssertEqual(preview.ghostID, "news")
        XCTAssertEqual(preview.ring.segments.last?.id, "news")
        XCTAssertEqual(preview.ring.segments.last?.projectID, "writing")
        XCTAssertEqual(preview.ring.segments.last?.start ?? 0, 270.0 / 450, accuracy: 1e-9, "the ghost lands after the planned work")
        XCTAssertEqual(preview.ring.segments.last?.length ?? 0, 45.0 / 450, accuracy: 1e-9)
        XCTAssertEqual(preview.ring.plannedMinutes, 315)
    }
    func testDropPreviewThatOverbooksRescalesTheRing() {
        let r = ring([task("a", minutes: 420)])
        let preview = DayPlan.dropPreview(r, id: "b", projectID: "home", minutes: 60)
        XCTAssertEqual(preview.tooltip, "Drop to plan · +1h → 8h of 7h 30m")
        XCTAssertEqual(preview.hero.meta, "30m over after this")
        XCTAssertEqual(preview.ring.segments[0].length, 420.0 / 480, accuracy: 1e-9, "an over-full day fills the ring")
        XCTAssertEqual(preview.ring.segments[1].start + preview.ring.segments[1].length, 1, accuracy: 1e-9)
        XCTAssertEqual(preview.ring.overMinutes, 30)
    }
    func testDropPreviewWithoutAnEstimateHasNoGhost() {
        let r = ring(heroDay)
        let preview = DayPlan.dropPreview(r, id: "x", projectID: "work", minutes: nil)
        XCTAssertNil(preview.ghostID)
        XCTAssertEqual(preview.ring, r)
        XCTAssertEqual(preview.tooltip, "Drop to plan · no estimate yet")
        XCTAssertEqual(preview.hero, DayPlan.heroFigure(r))
    }
    func testAddingMatchesTheRingOfTheDayAfterTheDrop() {
        let after = ring(heroDay + [task("news", minutes: 45, project: "writing")])
        let added = ring(heroDay).adding(id: "news", projectID: "writing", minutes: 45)
        XCTAssertEqual(added.plannedMinutes, after.plannedMinutes)
        XCTAssertEqual(added.segments.map(\.id), after.segments.map(\.id))
        for (x, y) in zip(added.segments, after.segments) { XCTAssertEqual(x.length, y.length, accuracy: 1e-9) }
    }
    func testPlannedToastCopy() {
        XCTAssertEqual(DayPlan.plannedToast(title: "Draft the newsletter intro", minutes: 45), "Planned \u{201C}Draft the newsletter intro\u{201D} for today · 45m")
        XCTAssertEqual(DayPlan.plannedToast(title: "Call", minutes: nil), "Planned \u{201C}Call\u{201D} for today")
    }

    // MARK: The tray

    func testPlanCandidatesSortsTasksUnderTheThreeHeadings() {
        let tasks = [
            task("today", minutes: 30),
            task("overdue-recent", date: "2026-11-17"),
            task("overdue-old", date: "2026-11-10"),
            task("tomorrow", minutes: 20, project: "home", date: "2026-11-21"),
            task("next-week", date: "2026-11-27"),
            task("new-undated", minutes: 15, project: "admin", date: nil, created: "2026-11-19T09:00:00Z"),
            task("newer-undated", minutes: 45, project: "writing", date: nil, created: "2026-11-20T08:00:00Z"),
            task("old-undated", minutes: 30, project: "admin", date: nil, created: "2026-10-20T09:00:00Z"),
            task("done-undated", date: nil, done: true),
        ]
        let candidates = DayPlan.planCandidates(tasks, today: friday, calendar: cal())
        XCTAssertEqual(candidates.inbox.map(\.id), ["newer-undated", "new-undated"], "newest first")
        XCTAssertEqual(candidates.tomorrow.map(\.id), ["tomorrow"])
        XCTAssertEqual(candidates.waiting.map(\.id), ["old-undated", "overdue-old"], "oldest first")
        XCTAssertFalse(candidates.all.contains { ["today", "overdue-recent", "next-week", "done-undated"].contains($0.id) })
    }
    func testPlanCandidatesBoundaries() {
        // Exactly 14 days undated and exactly 7 days overdue are "a while".
        let tasks = [task("u14", date: nil, created: "2026-11-05T22:59:00Z"), task("u13", date: nil, created: "2026-11-07T09:00:00Z"),
                     task("o7", date: "2026-11-13"), task("o6", date: "2026-11-14")]
        let candidates = DayPlan.planCandidates(tasks, today: friday, calendar: cal())
        XCTAssertEqual(candidates.waiting.map(\.id), ["u14", "o7"])
        XCTAssertEqual(candidates.inbox.map(\.id), ["u13"])
    }
    func testPlanCandidatesLeaveOutSomedayChildrenAndHeadings() {
        var child = task("child", date: nil); child["parent_id"] = .string("p")
        var heading = task("heading", date: nil); heading["is_heading"] = .bool(true)
        let candidates = DayPlan.planCandidates([task("someday", date: nil), child, heading, task("keep", date: nil)], today: friday, someday: ["someday"], calendar: cal())
        XCTAssertEqual(candidates.all.map(\.id), ["keep"])
    }
    func testPlanCandidatesAreCapped() {
        let tasks = (0..<12).map { task("t\($0)", date: "2026-11-21") }
        XCTAssertEqual(DayPlan.planCandidates(tasks, today: friday, limit: 5, calendar: cal()).tomorrow.count, 5)
        XCTAssertTrue(DayPlan.planCandidates([], today: friday, calendar: cal()).isEmpty)
    }
}
