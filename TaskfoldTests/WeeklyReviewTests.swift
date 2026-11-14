import XCTest
@testable import TaskfoldCore

/// Weekly review (Core/WeeklyReview.swift): slipped-task selection, projects without a next action, the next-week
/// load, the last-reviewed row, step selection and the done-screen wording.
final class WeeklyReviewTests: XCTestCase {
    let account = "owner"
    let zone = "Europe/Copenhagen"
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; c.firstWeekday = 2; return c }
    func at(_ day: String, _ hhmm: String = "08:00") -> Date {
        let parts = hhmm.split(separator: ":").map { Int($0)! }
        return calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: Int(day.prefix(4)), month: Int(day.dropFirst(5).prefix(2)), day: Int(day.suffix(2)), hour: parts[0], minute: parts[1]))!
    }
    // Wednesday 11 November 2026.
    let today = "2026-11-11"
    func task(_ id: String, date: String? = "2026-11-09", minutes: Int? = nil, priority: Int = 4, project: String? = nil, extra: [String: JSON] = [:]) -> Record {
        var row = Record.task(user: account, project: project ?? "", createdAt: "2026-11-01T09:00:00Z")
        row["id"] = .string(id); row["title"] = .string("Task " + id); row["priority"] = .number(Double(priority))
        row["due_date"] = date.map { .string($0) } ?? .null
        if let minutes { row["duration_minutes"] = .number(Double(minutes)) }
        for (key, value) in extra { row[key] = value }
        return row
    }
    func project(_ id: String, name: String = "P", extra: [String: JSON] = [:]) -> Record {
        var row = Record(["id": .string(id), "user_id": .string(account), "name": .string(name), "team_id": .null, "is_archived": .bool(false)])
        for (key, value) in extra { row[key] = value }
        return row
    }
    func slipped(_ tasks: [Record], held: Set<String> = [], editable: @escaping (Record) -> Bool = { _ in true }) -> [String] {
        WeeklyReview.slipped(tasks, today: today, held: held, calendar: calendar, isEditable: editable).map(\.id)
    }

    // MARK: Slipped

    func testSlippedIsOpenWorkPlannedInTheSevenDaysBeforeToday() {
        let rows = [task("edge-first", date: "2026-11-04"), task("yesterday", date: "2026-11-10"), task("too-old", date: "2026-11-03"),
                    task("today", date: "2026-11-11"), task("future", date: "2026-11-12"), task("undated", date: nil),
                    task("done", date: "2026-11-09", extra: ["completed": .bool(true)])]
        XCTAssertEqual(Set(slipped(rows)), ["edge-first", "yesterday"])
    }
    func testSlippedCountsTimedTasksAndSkipsHeldReadOnlyAndChecklistChildren() {
        let timed = task("timed", date: "2026-11-08", extra: ["due_time": .string("10:00"), "time_zone": .string(zone)])
        let child = task(SubtaskTree.reference(parent: "root", key: "child"), date: "2026-11-09")
        let rows = [timed, task("evening", date: "2026-11-09"), task("shared", date: "2026-11-09"), child]
        XCTAssertEqual(slipped(rows, held: ["evening"], editable: { $0.id != "shared" }), ["timed"])
    }
    func testSlippedOrdersByPriorityThenDeadlineThenOldestDay() {
        let rows = [task("low-old", date: "2026-11-05", priority: 4), task("high", date: "2026-11-10", priority: 1),
                    task("low-deadline", date: "2026-11-09", priority: 4, extra: ["deadline_date": .string("2026-11-12")]),
                    task("low-new", date: "2026-11-10", priority: 4)]
        XCTAssertEqual(slipped(rows), ["high", "low-deadline", "low-old", "low-new"])
    }

    func testSmartRescheduleRestrictedToSlippedLeavesOlderOverdueAlone() {
        let rows = [task("a", date: "2026-11-09", minutes: 60), task("b", date: "2026-11-02", minutes: 60)]
        let plan = SmartReschedule.plan(tasks: rows, events: [], hours: WorkingHours(), now: at(today), only: Set(slipped(rows)), calendar: calendar)
        XCTAssertEqual(plan.placements.map(\.taskID), ["a"])
        XCTAssertTrue(plan.unplaced.isEmpty)
        let all = SmartReschedule.plan(tasks: rows, events: [], hours: WorkingHours(), now: at(today), calendar: calendar)
        XCTAssertEqual(Set(all.placements.map(\.taskID)), ["a", "b"])
    }

    // MARK: Projects

    func testProjectsWithoutNextActionNeedAnOpenUndatedTask() {
        let projects = [project("empty", name: "Empty"), project("dated", name: "Dated"), project("ready", name: "Ready"), project("done", name: "Done")]
        let tasks = [task("t1", date: "2026-11-12", project: "dated"), task("t2", date: nil, project: "ready"),
                     task("t3", date: nil, project: "done", extra: ["completed": .bool(true)])]
        let result = WeeklyReview.projectsWithoutNextAction(projects: projects, tasks: tasks, account: account, calendar: calendar).map(\.id)
        XCTAssertEqual(result, ["dated", "done", "empty"], "Sorted by name; a dated or finished task is not a next action")
    }
    func testProjectsSkipArchivedSharedForeignAndSomedayOnlyProjects() {
        let projects = [project("archived", extra: ["is_archived": .bool(true)]), project("child", extra: ["parent_id": .string("archived")]),
                        project("team", extra: ["team_id": .string("t")]), project("other", extra: ["user_id": .string("someone")]),
                        project("shelf", name: "Shelf")]
        let tasks = [task("idea", date: nil, project: "shelf")]
        XCTAssertEqual(WeeklyReview.projectsWithoutNextAction(projects: projects, tasks: tasks, someday: ["idea"], account: account, calendar: calendar).map(\.id), ["shelf"])
        XCTAssertEqual(WeeklyReview.projectsWithoutNextAction(projects: projects, tasks: tasks, account: account, calendar: calendar).map(\.id), [])
    }

    // MARK: Next week

    func testLoadCoversTheNextSevenDaysAndFlagsAnOverfullDay() {
        // Thursday 12 is overfull: 9h of estimates against 8h of working hours. Saturday and Sunday are days off.
        let rows = [task("big", date: "2026-11-12", minutes: 540), task("small", date: "2026-11-13", minutes: 60), task("unestimated", date: "2026-11-13")]
        let load = WeeklyReview.load(tasks: rows, events: [], hours: WorkingHours(), now: at(today), calendar: calendar)
        XCTAssertEqual(load.days.map(\.day), ["2026-11-12", "2026-11-13", "2026-11-14", "2026-11-15", "2026-11-16", "2026-11-17", "2026-11-18"])
        XCTAssertEqual(load.days.map(\.state), [.over, .comfortable, .off, .off, .clear, .clear, .clear])
        XCTAssertEqual(load.plannedMinutes, 600); XCTAssertEqual(load.taskCount, 3); XCTAssertEqual(load.unestimatedCount, 1)
        XCTAssertEqual(load.busiest?.day, "2026-11-12"); XCTAssertEqual(load.overDays.map(\.day), ["2026-11-12"])
        XCTAssertTrue(load.message().contains("about 1h more than your free time"), load.message())
    }
    func testLoadSubtractsTimedEventsAndIgnoresAllDay() {
        let busy = PlannerEvent(id: "e", calendarID: "c", start: at("2026-11-12", "09:00"), end: at("2026-11-12", "15:00"))
        let allDay = PlannerEvent(id: "a", calendarID: "c", start: at("2026-11-13", "00:00"), end: at("2026-11-14", "00:00"), allDay: true)
        let rows = [task("t", date: "2026-11-12", minutes: 180), task("u", date: "2026-11-13", minutes: 180)]
        let load = WeeklyReview.load(tasks: rows, events: [busy, allDay], hours: WorkingHours(), now: at(today), calendar: calendar)
        XCTAssertEqual(load.days[0].totals.freeMinutes, 120); XCTAssertEqual(load.days[0].state, .over)
        XCTAssertEqual(load.days[1].totals.freeMinutes, 480); XCTAssertEqual(load.days[1].state, .comfortable)
    }
    func testLoadMessagesAreCalm() {
        let empty = WeeklyReview.load(tasks: [], events: [], hours: WorkingHours(), now: at(today), calendar: calendar)
        XCTAssertEqual(empty.message(), "Nothing is planned for the next 7 days yet.")
        let light = WeeklyReview.load(tasks: [task("t", date: "2026-11-12", minutes: 60)], events: [], hours: WorkingHours(), now: at(today), calendar: calendar)
        XCTAssertEqual(light.message(), "The week looks comfortable: 1h planned, 40h free.")
        let full = WeeklyReview.load(tasks: [task("t", date: "2026-11-12", minutes: 420)], events: [], hours: WorkingHours(), now: at(today), calendar: calendar)
        XCTAssertTrue(full.message().hasSuffix("is your fullest day. The rest of the week has room."), full.message())
    }

    // MARK: Last reviewed

    func testMarkReviewedWritesOneRowAndReadsBack() throws {
        let now = at(today, "17:30")
        let first = try WeeklyReview.markReviewed(at: now, rows: [], account: account)
        XCTAssertEqual(first.table, "view_orders"); XCTAssertEqual(first.method, "POST"); XCTAssertEqual(first.recordID, "weekly:review")
        let rows = [Record(first.fields)]
        XCTAssertEqual(WeeklyReview.lastReviewed(rows: rows, account: account), Date(timeIntervalSince1970: floor(now.timeIntervalSince1970)))
        let later = try WeeklyReview.markReviewed(at: now.addingTimeInterval(86_400), rows: rows, account: account)
        XCTAssertEqual(later.method, "PATCH")
    }
    func testLastReviewedIgnoresForeignMalformedAndMissingRows() throws {
        let row = Record(try WeeklyReview.markReviewed(at: at(today), rows: [], account: account).fields)
        XCTAssertNil(WeeklyReview.lastReviewed(rows: [row], account: "someone"))
        XCTAssertNil(WeeklyReview.lastReviewed(rows: [], account: account))
        XCTAssertNil(WeeklyReview.lastReviewed(rows: [Record(["id": .string("weekly:review"), "user_id": .string(account), "ids": .array([.string("yesterday")])])], account: account))
        XCTAssertThrowsError(try WeeklyReview.markReviewed(at: at(today), rows: [row], account: "someone"))
        XCTAssertThrowsError(try WeeklyReview.markReviewed(at: at(today), rows: [], account: ""))
    }
    func testDueAfterSevenDaysAndStatusWording() {
        let last = at("2026-11-04", "17:00")
        XCTAssertFalse(WeeklyReview.isDue(lastReviewed: last, now: at("2026-11-10"), calendar: calendar))
        XCTAssertTrue(WeeklyReview.isDue(lastReviewed: last, now: at("2026-11-11"), calendar: calendar))
        XCTAssertTrue(WeeklyReview.isDue(lastReviewed: nil, now: at(today), calendar: calendar))
        XCTAssertEqual(WeeklyReview.statusText(lastReviewed: nil, now: at(today), calendar: calendar), "Last review: never")
        XCTAssertEqual(WeeklyReview.statusText(lastReviewed: at(today, "07:00"), now: at(today, "20:00"), calendar: calendar), "Reviewed today")
        XCTAssertEqual(WeeklyReview.statusText(lastReviewed: at("2026-11-10"), now: at(today), calendar: calendar), "Reviewed yesterday")
        XCTAssertEqual(WeeklyReview.statusText(lastReviewed: last, now: at(today), calendar: calendar), "Reviewed 7 days ago")
    }
    func testNextReminderIsTheNextFridayAtFour() {
        let friday = WeeklyReview.nextReminder(after: at(today), weekday: 6, minutes: 960, calendar: calendar)
        XCTAssertEqual(friday, at("2026-11-13", "16:00"))
        XCTAssertEqual(WeeklyReview.nextReminder(after: at("2026-11-13", "16:00"), weekday: 6, minutes: 960, calendar: calendar), at("2026-11-20", "16:00"))
        XCTAssertNil(WeeklyReview.nextReminder(after: at(today), weekday: 9, minutes: 960, calendar: calendar))
    }

    // MARK: Steps and the done screen

    func testStepsKeepOnlyWhatHasSomethingToDoAndNextWeekAlways() {
        XCTAssertEqual(WeeklyReview.steps(inbox: 0, slipped: 0, estimatesReliable: false, projectsWithoutNext: 0, somedayStale: 0), [.nextWeek])
        XCTAssertEqual(WeeklyReview.steps(inbox: 3, slipped: 2, estimatesReliable: true, projectsWithoutNext: 1, somedayStale: 4), WeeklyReviewStep.allCases)
        XCTAssertEqual(WeeklyReview.steps(inbox: 0, slipped: 2, estimatesReliable: false, projectsWithoutNext: 0, somedayStale: 1), [.slipped, .someday, .nextWeek])
    }
    func testStepIdentifiersAreStableAndOneBased() {
        XCTAssertEqual(WeeklyReviewStep.allCases.map(\.identifier), (1...6).map { "weeklyReviewStep-\($0)" })
        XCTAssertEqual(WeeklyReviewStep.allCases.map(\.title), ["Inbox", "Slipped last week", "Estimates", "Next actions", "Someday", "Next week"])
    }
    func testDoneSummaryNamesOnlyWhatChangedWithoutScoring() {
        XCTAssertEqual(WeeklyReviewProgress().summary, "Nothing needed changing this week.")
        XCTAssertEqual(WeeklyReviewProgress().headline, "You’re up to date")
        var progress = WeeklyReviewProgress(); progress.inboxCleared = 1; progress.rescheduled = 4; progress.deleted = 1; progress.skipped = 2
        XCTAssertEqual(progress.lines, ["1 inbox task sorted", "4 slipped tasks rescheduled", "1 task deleted"])
        XCTAssertEqual(progress.summary, "1 inbox task sorted. 4 slipped tasks rescheduled. 1 task deleted.")
        XCTAssertEqual(progress.headline, "Review finished")
    }
    func testStaleSomedayIdsMatchTheExistingReview() {
        let now = at(today)
        let old = task("old", date: nil, extra: ["created_at": .string("2026-09-01T09:00:00Z")]), fresh = task("fresh", date: nil, extra: ["created_at": .string("2026-11-01T09:00:00Z")])
        XCTAssertEqual(Planning.staleIDs([old, fresh], now: now, calendar: calendar), ["old"])
        XCTAssertEqual(Planning.review([old, fresh], now: now, lastReviewed: nil, calendar: calendar)?.staleIDs, ["old"])
        XCTAssertNil(Planning.review([old, fresh], now: now, lastReviewed: now.addingTimeInterval(-86_400), calendar: calendar))
    }

    // MARK: This week in rings (round 6)

    var monday: Calendar { var c = calendar; c.firstWeekday = 2; c.locale = Locale(identifier: "en_US_POSIX"); return c }
    let sevenDays = WorkingHours(start: 9 * 60, end: 15 * 60, weekdays: [2, 3, 4, 5, 6, 7]) // Sunday is the day off
    func planned(_ id: String, _ date: String, _ minutes: Int, done: Bool = false) -> Record {
        var row = task(id, date: date, minutes: minutes)
        if done { row["completed"] = .bool(true) }
        return row
    }
    func summary(_ tasks: [Record], now: String = "2026-11-13", hours: WorkingHours? = nil, calendar custom: Calendar? = nil) -> WeekSummary {
        WeeklyReview.weekSummary(tasks: tasks, events: [], hours: hours ?? sevenDays, now: at(now, "12:00"), calendar: custom ?? monday)
    }
    /// Friday 13 Nov. Tuesday is the fullest day; Wednesday (3h open) and Monday (2h open) slipped; Sunday is a day off with a task.
    var fullWeek: [Record] {
        [planned("m1", "2026-11-09", 60, done: true), planned("m2", "2026-11-09", 120),
         planned("t1", "2026-11-10", 360, done: true),
         planned("w1", "2026-11-11", 60, done: true), planned("w2", "2026-11-11", 180),
         planned("th", "2026-11-12", 120, done: true),
         planned("f", "2026-11-13", 60), planned("s", "2026-11-14", 30), planned("su", "2026-11-15", 25)]
    }

    func testWeekHasSevenDaysFromTheFirstWeekdayAndMarksToday() {
        let s = summary(fullWeek)
        XCTAssertEqual(s.days.map(\.key), (9...15).map { "2026-11-\(String(format: "%02d", $0))" })
        XCTAssertEqual(s.days.map(\.letter), ["M", "T", "W", "T", "F", "S", "S"])
        XCTAssertEqual(s.days.filter(\.isToday).map(\.name), ["Friday"])
        var sundayFirst = monday; sundayFirst.firstWeekday = 1
        let other = summary(fullWeek, calendar: sundayFirst)
        XCTAssertEqual(other.days.first?.key, "2026-11-08"); XCTAssertEqual(other.days.map(\.letter).first, "S"); XCTAssertEqual(other.rangeLabel, "8–14 Nov")
    }
    func testWeekTotalsAndRangeLabel() {
        let s = summary(fullWeek)
        XCTAssertEqual(s.plannedMinutes, 1015); XCTAssertEqual(s.doneMinutes, 600)
        XCTAssertEqual(s.figure, "10h"); XCTAssertEqual(s.rest, "done of 16h 55m planned · 9–15 Nov")
        XCTAssertFalse(s.isEmpty)
        XCTAssertEqual(summary([], now: "2026-12-02").rangeLabel, "30 Nov – 6 Dec", "a week across two months names both")
    }
    func testFullestDayAndSlippedDaysMakeOnePlainSentence() {
        let s = summary(fullWeek)
        XCTAssertEqual(s.fullestDay?.name, "Tuesday")
        XCTAssertEqual(s.slippedDays.map(\.name), ["Monday", "Wednesday"])
        XCTAssertEqual(s.days.map(\.slippedMinutes), [120, 0, 180, 0, 0, 0, 0], "only days that have passed can slip; today and later never do")
        XCTAssertEqual(s.sentence, "Tuesday was your fullest day. Monday and Wednesday slipped the most.")
    }
    func testSecondSlippedDayNeedsAtLeastHalfTheFirst() {
        let s = summary([planned("a", "2026-11-09", 300, done: true), planned("b", "2026-11-10", 400), planned("c", "2026-11-11", 100)])
        XCTAssertEqual(s.slippedDays.map(\.name), ["Tuesday"], "100m is under half of 400m")
        XCTAssertEqual(s.sentence, "Tuesday was your fullest day and slipped the most.")
    }
    func testSentenceLeavesOutPartsThatDoNotApply() {
        let noSlip = summary([planned("a", "2026-11-09", 60, done: true), planned("b", "2026-11-10", 120, done: true)])
        XCTAssertEqual(noSlip.sentence, "Tuesday was your fullest day.")
        let oneDay = summary([planned("a", "2026-11-09", 60)])
        XCTAssertNil(oneDay.fullestDay, "one planned day is not a fullest day")
        XCTAssertEqual(oneDay.sentence, "Monday slipped the most.")
        XCTAssertNil(summary([planned("a", "2026-11-14", 60)]).sentence, "nothing passed, one day planned")
    }
    func testFullestDayTieGoesToTheEarlierDay() {
        let s = summary([planned("a", "2026-11-10", 120, done: true), planned("b", "2026-11-12", 120, done: true)])
        XCTAssertEqual(s.fullestDay?.name, "Tuesday")
    }
    func testNothingPlannedAllWeek() {
        let s = summary([task("noEstimate", date: "2026-11-10")])
        XCTAssertTrue(s.isEmpty); XCTAssertEqual(s.emptyLine, "Nothing planned this week yet."); XCTAssertNil(s.sentence)
        XCTAssertEqual(s.days.count, 7, "the strip still shows")
        XCTAssertEqual(s.accessibilityLabel, "Nothing planned this week yet.")
    }
    func testEachDaySpeaksItsOwnRing() {
        let s = summary(fullWeek)
        XCTAssertEqual(s.days[1].accessibilityLabel, "Tuesday 10 Nov: 6h, all done")
        XCTAssertEqual(s.days[0].accessibilityLabel, "Monday 9 Nov: 1h done of 3h")
        XCTAssertEqual(s.days[2].accessibilityLabel, "Wednesday 11 Nov: 1h done of 4h")
        XCTAssertEqual(summary([planned("a", "2026-11-11", 110, done: true), planned("b", "2026-11-11", 150)]).days[2].accessibilityLabel, "Wednesday 11 Nov: 1h 50m done of 4h 20m")
        XCTAssertEqual(s.days[3].accessibilityLabel, "Thursday 12 Nov: 2h, all done")
        XCTAssertEqual(summary([]).days[0].accessibilityLabel, "Monday 9 Nov: nothing planned")
    }
    func testDayOffIsHoursSetButNotThisDay() {
        let s = summary(fullWeek)
        XCTAssertTrue(s.days[6].isDayOff); XCTAssertFalse(s.days[5].isDayOff)
        XCTAssertFalse(s.days[6].ring.hasWorkingHours)
        XCTAssertEqual(summary([]).days[6].accessibilityLabel, "Sunday 15 Nov: day off")
        XCTAssertEqual(s.days[6].accessibilityLabel, "Sunday 15 Nov: day off, 25m planned")
    }
    func testDayRingsAreTheSameRingsTodayAndUpcomingUse() {
        let s = summary(fullWeek)
        let direct = DayPlan.ring(for: at("2026-11-10"), tasks: fullWeek, events: [], hours: sevenDays, calendar: monday)
        XCTAssertEqual(s.days[1].ring, direct)
    }
}
