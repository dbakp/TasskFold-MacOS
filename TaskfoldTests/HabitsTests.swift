import XCTest
@testable import TaskfoldCore

/// Habits (Core/Habits.swift): the habit list, schedules, streaks over scheduled days, missed and pending days,
/// rates, the heatmap, vacation, untracked history, time zones and pruning. Histories are produced by the real
/// completion path (`TaskCompletion.toggle`), so these tests also prove that the series' history is recoverable
/// from task rows alone.
final class HabitsTests: XCTestCase {
    let account = "owner"
    let zone = "Europe/Copenhagen"
    func cal(_ zone: String = "Europe/Copenhagen", firstWeekday: Int = 2) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; c.firstWeekday = firstWeekday; return c
    }
    func day(_ text: String, _ c: Calendar) -> Date { Dates.parse(text, calendar: c)! }
    func at(_ text: String, hour: Int = 9, _ c: Calendar) -> Date { c.date(byAdding: .hour, value: hour, to: day(text, c))! }
    func add(_ text: String, _ n: Int, _ c: Calendar) -> String { TaskPlanner.dayKey(c.date(byAdding: .day, value: n, to: day(text, c))!, calendar: c) }
    let en = Locale(identifier: "en_GB")

    func series(type: String = "daily", interval: Int = 1, days: [Int]? = nil, start: String, from: Bool = false, extra: [String: JSON] = [:]) -> Record {
        var row = Record.task(user: account, createdAt: "2026-01-01T09:00:00Z")
        row["id"] = .string("00000000-0000-4000-8000-000000000001"); row["title"] = .string("Read 20 pages")
        row["due_date"] = .string(start); row["is_recurring"] = .bool(true)
        var pattern: [String: JSON] = ["type": .string(type), "interval": .number(Double(interval))]
        if let days { pattern["daysOfWeek"] = .array(days.map { .number(Double($0)) }) }
        if from { pattern["fromCompletion"] = .bool(true) }
        row["recurrence_pattern"] = .object(pattern)
        for (k, v) in extra { row[k] = v }
        return row
    }
    /// Completes the open occurrence of the series at `when`, through the real completion path.
    func complete(_ tasks: inout [Record], at when: Date, _ c: Calendar) {
        var snapshot = Snapshot(); snapshot.tables["tasks"] = tasks
        let open = tasks.filter { !$0.completed }.min { $0.string("due_date") < $1.string("due_date") }!
        for change in TaskCompletion.complete(open, tasks: tasks, at: when, calendar: c, account: account) { snapshot.apply(change) }
        tasks = snapshot.tables["tasks"]!
    }
    func read(_ tasks: [Record], today: String, _ c: Calendar, vacations: [VacationRange] = []) -> HabitReading {
        Habits.read(habit: Habits.root(of: tasks[0]), tasks: tasks, calendar: c, vacations: vacations, now: at(today, hour: 12, c), locale: en)!
    }
    func states(_ reading: HabitReading) -> [HabitDayState] { reading.week.map(\.state) }

    // MARK: Identity, eligibility, list

    func testSeriesIdentityFollowsTheRecurrenceRoot() {
        let c = cal(); var tasks = [series(start: "2026-11-02")]
        complete(&tasks, at: at("2026-11-02", c), c)
        XCTAssertEqual(tasks.count, 2)
        let root = tasks[0].id
        XCTAssertEqual(Habits.root(of: tasks[0]), root)
        XCTAssertEqual(Habits.root(of: tasks[1]), root, "the successor points at the first task")
        complete(&tasks, at: at("2026-11-03", c), c)
        XCTAssertEqual(Set(tasks.map(Habits.root(of:))), [root])
        XCTAssertEqual(Habits.family(root, in: tasks).count, 3)
        XCTAssertEqual(Habits.openOccurrence(root, in: tasks)?.string("due_date"), "2026-11-04")
    }

    func testEligibilityNeedsARepeatingOwnedOrdinaryTask() {
        let plain = Record.task(user: account)
        XCTAssertFalse(Habits.eligible(plain, account: account))
        XCTAssertTrue(Habits.eligible(series(start: "2026-11-02"), account: account))
        XCTAssertFalse(Habits.eligible(series(start: "2026-11-02"), account: "someone-else"))
        XCTAssertFalse(Habits.eligible(series(start: "2026-11-02", extra: ["is_heading": .bool(true)]), account: account))
        XCTAssertFalse(Habits.eligible(series(type: "nonsense", start: "2026-11-02"), account: account))
        XCTAssertFalse(Habits.eligible(series(start: "2026-11-02"), account: ""))
    }

    func order(_ ids: [String], user: String = "owner") -> Record {
        Record(["id": .string(Habits.key), "user_id": .string(user), "ids": .array(ids.map(JSON.string))])
    }

    func testSetTrackedWritesOneOrderedRowAndIsIdempotent() throws {
        let task = series(start: "2026-11-02")
        let add = try Habits.setTracked(task, tracked: true, tasks: [task], rows: [], account: account)
        XCTAssertEqual(add.count, 1)
        XCTAssertEqual(add[0].table, "view_orders"); XCTAssertEqual(add[0].recordID, "planning:habits"); XCTAssertEqual(add[0].method, "POST")
        XCTAssertEqual(add[0].fields["ids"], .array([.string(task.id)]))
        XCTAssertEqual(add[0].fields["user_id"], .string(account))
        let row = Record(add[0].fields)
        XCTAssertTrue(try Habits.setTracked(task, tracked: true, tasks: [task], rows: [row], account: account).isEmpty, "already tracked")
        let remove = try Habits.setTracked(task, tracked: false, tasks: [task], rows: [row], account: account)
        XCTAssertEqual(remove[0].method, "PATCH"); XCTAssertEqual(remove[0].fields["ids"], .array([]))
        XCTAssertTrue(try Habits.setTracked(task, tracked: false, tasks: [task], rows: [], account: account).isEmpty)
    }

    func testTrackingAnIneligibleTaskIsRefusedAndAnotherWorkspaceRowIsNotTouched() {
        let plain = Record.task(user: account)
        XCTAssertThrowsError(try Habits.setTracked(plain, tracked: true, tasks: [plain], rows: [], account: account))
        let task = series(start: "2026-11-02")
        XCTAssertThrowsError(try Habits.setTracked(task, tracked: true, tasks: [task], rows: [order([], user: "another")], account: account))
    }

    func testTheKeyAndListFitTheServerLimits() {
        XCTAssertLessThanOrEqual(Habits.key.utf8.count, Planning.maxKeyBytes)
        XCTAssertLessThanOrEqual(Habits.maxHabits, Planning.maxIDs)
        XCTAssertTrue(Planning.isPlanningKey(Habits.key), "habits share the planning prefix, so older clients ignore the key")
    }

    func testPruningDropsDeletedFinishedAndNonRepeatingSeriesKeepingOrder() throws {
        let c = cal()
        var a = [series(start: "2026-11-02")]
        var b = series(start: "2026-11-02"); b["id"] = .string("00000000-0000-4000-8000-000000000002")
        var gone = series(start: "2026-11-02"); gone["id"] = .string("00000000-0000-4000-8000-000000000003")
        gone["is_recurring"] = .bool(false)
        complete(&a, at: at("2026-11-02", c), c)
        let tasks = a + [b, gone]
        let ids = [gone.id, b.id, "deleted-task", a[0].id, b.id]
        XCTAssertEqual(Habits.pruned(ids, tasks: tasks, account: account), [b.id, a[0].id], "stale, non-repeating and duplicate ids go; order stays")
        XCTAssertEqual(Habits.pruned([b.id], tasks: tasks, account: "other"), [])
        // A write drops the stale ids in the same mutation.
        let write = try Habits.setTracked(b, tracked: true, tasks: tasks, rows: [order(ids)], account: account)
        XCTAssertEqual(write[0].fields["ids"], .array([b.id, a[0].id].map(JSON.string)))
    }

    func testReorderKeepsUnknownIdsOutAndMissingOnesAtTheEnd() throws {
        var b = series(start: "2026-11-02"); b["id"] = .string("00000000-0000-4000-8000-000000000002")
        let a = series(start: "2026-11-02")
        let changes = try Habits.reorder([b.id, "ghost"], tasks: [a, b], rows: [order([a.id, b.id])], account: account)
        XCTAssertEqual(changes[0].fields["ids"], .array([b.id, a.id].map(JSON.string)))
        XCTAssertTrue(try Habits.reorder([a.id, b.id], tasks: [a, b], rows: [order([a.id, b.id])], account: account).isEmpty)
    }

    // MARK: Schedule

    func testScheduleSummaries() {
        XCTAssertEqual(Habits.scheduleSummary(series(start: "2026-11-02")), "Every day")
        XCTAssertEqual(Habits.scheduleSummary(series(interval: 3, start: "2026-11-02")), "Every 3 days")
        XCTAssertEqual(Habits.scheduleSummary(series(type: "weekly", days: [1, 2, 3, 4, 5], start: "2026-11-02")), "Every weekday")
        XCTAssertEqual(Habits.scheduleSummary(series(type: "weekly", days: [6, 0], start: "2026-11-02")), "Every weekend")
        XCTAssertEqual(Habits.scheduleSummary(series(type: "weekly", days: [1, 3, 5], start: "2026-11-02")), "Every Mon, Wed, Fri")
        XCTAssertEqual(Habits.scheduleSummary(series(type: "weekly", interval: 2, days: [2], start: "2026-11-02")), "Every 2 weeks on Tue")
        XCTAssertEqual(Habits.scheduleSummary(series(type: "weekly", start: "2026-11-02")), "Every week")
    }

    func testScheduledDaysSkipDaysTheRuleDoesNotHit() {
        let c = cal()
        let weekdays = Habits.scheduledDays(rule: series(type: "weekly", days: [1, 2, 3, 4, 5], start: "2026-11-02"), anchor: "2026-11-02", through: "2026-11-15", calendar: c)
        XCTAssertEqual(weekdays.count, 10)
        XCTAssertFalse(weekdays.contains("2026-11-07")); XCTAssertFalse(weekdays.contains("2026-11-08"))
        let mwf = Habits.scheduledDays(rule: series(type: "weekly", days: [1, 3, 5], start: "2026-11-02"), anchor: "2026-11-02", through: "2026-11-15", calendar: c)
        XCTAssertEqual(mwf, ["2026-11-02", "2026-11-04", "2026-11-06", "2026-11-09", "2026-11-11", "2026-11-13"])
        let everyOther = Habits.scheduledDays(rule: series(interval: 2, start: "2026-11-02"), anchor: "2026-11-02", through: "2026-11-09", calendar: c)
        XCTAssertEqual(everyOther, ["2026-11-02", "2026-11-04", "2026-11-06", "2026-11-08"])
        let afterCompletion = Habits.scheduledDays(rule: series(interval: 3, start: "2026-11-02", from: true), anchor: "2026-11-02", through: "2026-11-30", calendar: c)
        XCTAssertEqual(afterCompletion, ["2026-11-02"], "a completion-based rule has no calendar of its own")
        let ended = Habits.scheduledDays(rule: series(start: "2026-11-02", extra: ["recurrence_end_date": .string("2026-11-04")]), anchor: "2026-11-02", through: "2026-11-30", calendar: c)
        XCTAssertEqual(ended, ["2026-11-02", "2026-11-03", "2026-11-04"])
        XCTAssertTrue(Habits.scheduledDays(rule: series(start: "2026-11-02"), anchor: "2026-11-10", through: "2026-11-02", calendar: c).isEmpty)
    }

    // MARK: Streaks, missed and pending

    func testDailyStreakCountsConsecutiveDaysAndTodayPendingNeverBreaksIt() {
        let c = cal(); var tasks = [series(start: "2026-11-02")]
        for d in 2...6 { complete(&tasks, at: at("2026-11-0\(d)", c), c) }
        let reading = read(tasks, today: "2026-11-07", c)
        XCTAssertEqual(reading.currentStreak.length, 5)
        XCTAssertEqual(reading.week.last?.state, .pending)
        XCTAssertFalse(reading.doneToday); XCTAssertTrue(reading.scheduledToday); XCTAssertTrue(reading.canCheckIn)
        XCTAssertEqual(reading.occurrenceID, tasks.last?.id)
        complete(&tasks, at: at("2026-11-07", c), c)
        let done = read(tasks, today: "2026-11-07", c)
        XCTAssertEqual(done.currentStreak.length, 6); XCTAssertTrue(done.doneToday); XCTAssertFalse(done.canCheckIn)
        XCTAssertEqual(done.bestStreak.length, 6)
    }

    func testAMissedDayEndsTheStreakButNotTheBest() {
        let c = cal(); var tasks = [series(start: "2026-11-02")]
        for d in 2...5 { complete(&tasks, at: at("2026-11-0\(d)", c), c) }     // Mon-Thu
        complete(&tasks, at: at("2026-11-07", c), c)                           // Sat; Fri was missed
        let reading = read(tasks, today: "2026-11-08", c)
        XCTAssertEqual(reading.currentStreak, HabitStreak(length: 1, since: nil))
        XCTAssertEqual(reading.bestStreak.length, 4)
        let day = reading.week.first { $0.id == "2026-11-06" }
        XCTAssertEqual(day?.state, .missed)
    }

    func testWeekdayHabitSkipsTheWeekendWithoutBreakingTheStreak() {
        let c = cal(); var tasks = [series(type: "weekly", days: [1, 2, 3, 4, 5], start: "2026-11-02")]
        for d in ["2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06", "2026-11-09", "2026-11-10"] { complete(&tasks, at: at(d, c), c) }
        let reading = read(tasks, today: "2026-11-11", c)   // Wednesday, pending
        XCTAssertEqual(reading.currentStreak.length, 7, "Sat and Sun are skipped, never broken")
        XCTAssertEqual(reading.week.map(\.state), [.done, .done, .notScheduled, .notScheduled, .done, .done, .pending])
        XCTAssertEqual(reading.schedule, "Every weekday")
        // On a Saturday nothing is due and nothing is broken.
        let saturday = read(tasks, today: "2026-11-14", c)
        XCTAssertFalse(saturday.scheduledToday); XCTAssertFalse(saturday.canCheckIn)
        XCTAssertEqual(saturday.week.last?.state, .notScheduled)
        XCTAssertEqual(saturday.currentStreak.length, 0, "Wed to Fri were missed")
    }

    func testMissingAScheduledWeekdayBreaksAWeekdayStreak() {
        let c = cal(); var tasks = [series(type: "weekly", days: [1, 3, 5], start: "2026-11-02")]
        complete(&tasks, at: at("2026-11-02", c), c)   // Mon
        complete(&tasks, at: at("2026-11-04", c), c)   // Wed
        // Fri 6 missed; Mon 9 done
        complete(&tasks, at: at("2026-11-09", c), c)
        let reading = read(tasks, today: "2026-11-10", c)
        XCTAssertEqual(reading.currentStreak.length, 1)
        XCTAssertEqual(reading.bestStreak.length, 2)
    }

    // MARK: Late and early completions

    func testACompletionCountsForTheDayItHappenedWhenThatDayIsScheduled() {
        let c = cal(); var tasks = [series(start: "2026-11-02")]
        complete(&tasks, at: at("2026-11-02", c), c)
        complete(&tasks, at: at("2026-11-05", c), c)   // occurrence due Tue 3rd, done Thu 5th
        let reading = read(tasks, today: "2026-11-06", c)
        let states = Dictionary(uniqueKeysWithValues: reading.week.map { ($0.id, $0.state) })
        XCTAssertEqual(states["2026-11-05"], .done)
        XCTAssertEqual(states["2026-11-03"], .missed); XCTAssertEqual(states["2026-11-04"], .missed)
    }

    func testAnEarlyCompletionCountsForTheDayItWasDue() {
        let c = cal()
        var tasks = [series(type: "weekly", days: [1, 3, 5], start: "2026-11-02")]
        complete(&tasks, at: at("2026-11-02", c), c)
        // Wednesday's occurrence, done early on Tuesday.
        complete(&tasks, at: at("2026-11-03", c), c)
        let reading = read(tasks, today: "2026-11-04", c)
        let states = Dictionary(uniqueKeysWithValues: reading.week.map { ($0.id, $0.state) })
        XCTAssertEqual(states["2026-11-04"], .done, "credited to its due day")
        XCTAssertEqual(states["2026-11-03"], .notScheduled)
        XCTAssertEqual(reading.currentStreak.length, 2)
    }

    // MARK: Untracked history

    func testHistoryBeforeTheFirstOccurrenceIsUntrackedAndStreaksReportSince() {
        let c = cal(); var tasks = [series(start: "2026-11-05")]
        complete(&tasks, at: at("2026-11-05", c), c); complete(&tasks, at: at("2026-11-06", c), c)
        let reading = read(tasks, today: "2026-11-07", c)
        XCTAssertEqual(reading.trackedSince, "2026-11-05")
        XCTAssertEqual(states(reading), [.untracked, .untracked, .untracked, .untracked, .done, .done, .pending])
        XCTAssertEqual(reading.currentStreak, HabitStreak(length: 2, since: "2026-11-05"), "bounded by history, not by a miss")
        XCTAssertEqual(reading.bestStreak.since, "2026-11-05")
        XCTAssertEqual(reading.monthScheduled, 2); XCTAssertEqual(reading.monthRate, 100)
        XCTAssertEqual(Habits.streakText(reading.currentStreak, since: { $0 }), "2-day streak, since 2026-11-05")
    }

    func testAMissEndsAStreakWithoutASinceDate() {
        let c = cal(); var tasks = [series(start: "2026-11-01")]
        complete(&tasks, at: at("2026-11-01", c), c)
        complete(&tasks, at: at("2026-11-04", c), c)
        let reading = read(tasks, today: "2026-11-05", c)
        XCTAssertEqual(reading.currentStreak, HabitStreak(length: 1, since: nil))
    }

    func testABrandNewHabitHasNoStreakAndTodayPending() {
        let c = cal(); let tasks = [series(start: "2026-11-07")]
        let reading = read(tasks, today: "2026-11-07", c)
        XCTAssertEqual(reading.currentStreak, .none); XCTAssertEqual(reading.bestStreak, .none)
        XCTAssertEqual(reading.week.last?.state, .pending)
        XCTAssertNil(reading.monthRate, "nothing can be judged yet")
        XCTAssertTrue(reading.recent.isEmpty)
    }

    // MARK: Vacation

    func testVacationFreezesStreaksAndStillCountsACheckIn() {
        let c = cal(); var tasks = [series(start: "2026-11-02")]
        complete(&tasks, at: at("2026-11-02", c), c); complete(&tasks, at: at("2026-11-03", c), c)
        // Tue the 3rd was the last check-in; 4th-6th are on vacation, 7th is done.
        complete(&tasks, at: at("2026-11-07", c), c)
        let vacation = [VacationRange(from: "2026-11-04", until: "2026-11-06")]
        let frozen = read(tasks, today: "2026-11-08", c, vacations: vacation)
        let states = Dictionary(uniqueKeysWithValues: frozen.week.map { ($0.id, $0.state) })
        XCTAssertEqual(states["2026-11-04"], .vacation); XCTAssertEqual(states["2026-11-06"], .vacation)
        XCTAssertEqual(frozen.currentStreak.length, 3, "2, 3 and 7 count; the vacation days neither add nor break")
        XCTAssertEqual(read(tasks, today: "2026-11-08", c).currentStreak.length, 1, "without vacation the same days are missed")
        // A check-in during vacation still counts.
        var during = [series(start: "2026-11-02")]
        complete(&during, at: at("2026-11-02", c), c); complete(&during, at: at("2026-11-03", c), c); complete(&during, at: at("2026-11-04", c), c)
        let r = read(during, today: "2026-11-05", c, vacations: [VacationRange(from: "2026-11-03", until: "2026-11-04")])
        XCTAssertEqual(r.week.first { $0.id == "2026-11-04" }?.state, .done)
        XCTAssertEqual(r.currentStreak.length, 3)
    }

    func testVacationDaysAreOutOfTheMonthRate() {
        let c = cal(); var tasks = [series(start: "2026-11-02")]
        complete(&tasks, at: at("2026-11-02", c), c)
        let reading = read(tasks, today: "2026-11-06", c, vacations: [VacationRange(from: "2026-11-03", until: "2026-11-04")])
        XCTAssertEqual(reading.monthDone, 1); XCTAssertEqual(reading.monthScheduled, 2, "the 5th was missed; the 3rd and 4th were on vacation")
        XCTAssertEqual(reading.monthRate, 50)
    }

    // MARK: Rate

    func testMonthRateCountsOnlyScheduledJudgedDaysThisMonth() {
        let c = cal(); var tasks = [series(type: "weekly", days: [1, 3, 5], start: "2026-10-26")]
        for d in ["2026-10-26", "2026-10-28", "2026-10-30", "2026-11-02"] { complete(&tasks, at: at(d, c), c) }
        // Nov: Mon 2 done, Wed 4 missed, Fri 6 missed, Mon 9 pending (today).
        let reading = read(tasks, today: "2026-11-09", c)
        XCTAssertEqual(reading.monthDone, 1); XCTAssertEqual(reading.monthScheduled, 3)
        XCTAssertEqual(reading.monthRate, 33)
    }

    // MARK: Heatmap

    func testHeatmapIsTwelveWeeksOfSevenDaysEndingThisWeek() {
        let c = cal(); var tasks = [series(start: "2026-08-24")]
        for offset in 0..<30 { complete(&tasks, at: at(add("2026-08-24", offset, c), c), c) }
        let reading = read(tasks, today: "2026-11-11", c)
        XCTAssertEqual(reading.heatmap.count, 12)
        XCTAssertTrue(reading.heatmap.allSatisfy { $0.days.count == 7 })
        XCTAssertEqual(reading.heatmap.last?.id, "2026-11-09", "the week starts on Monday")
        XCTAssertEqual(reading.heatmap.first?.id, "2026-08-24")
        let last = reading.heatmap.last!.days.map(\.state)
        XCTAssertEqual(last, [.missed, .missed, .pending, .future, .future, .future, .future])
        XCTAssertEqual(reading.heatmap[0].days.map(\.state), Array(repeating: .done, count: 7))
        XCTAssertEqual(reading.heatmap[0].summary, "Week of 24 Aug: 7 of 7 scheduled days done")
        XCTAssertEqual(reading.heatmap.last?.summary, "Week of 9 Nov: 0 of 2 scheduled days done, today still to do")
    }

    func testHeatmapFollowsTheWeekStartAndTheEarlierWeeksAreUntracked() {
        let tasks = [series(start: "2026-11-04")]
        let sunday = read(tasks, today: "2026-11-11", cal(firstWeekday: 1))
        XCTAssertEqual(sunday.heatmap.last?.id, "2026-11-08")
        XCTAssertEqual(sunday.heatmap.last?.days.first?.date, day("2026-11-08", cal()))
        XCTAssertEqual(sunday.heatmap.first?.days.map(\.state), Array(repeating: .untracked, count: 7))
        XCTAssertEqual(sunday.heatmap.first?.summary.hasSuffix("not tracked yet"), true)
        let notScheduled = read([series(type: "weekly", days: [1], start: "2026-11-02")], today: "2026-11-13", cal())
        XCTAssertEqual(notScheduled.heatmap.last?.summary, "Week of 9 Nov: 0 of 1 scheduled day done")
    }

    // MARK: Time zones and DST

    func testDaysAreKeyedInTheCalendarZoneAcrossTheClockChange() {
        // Copenhagen leaves summer time on 2026-10-25: a 25-hour day.
        let c = cal(); var tasks = [series(start: "2026-10-23")]
        let completionTimes = ["2026-10-23", "2026-10-24", "2026-10-25", "2026-10-26"].map { at($0, hour: 23, c) }
        for time in completionTimes { complete(&tasks, at: time, c) }
        let reading = read(tasks, today: "2026-10-27", c)
        XCTAssertEqual(reading.currentStreak.length, 4)
        XCTAssertEqual(reading.week.map(\.id), ["2026-10-21", "2026-10-22", "2026-10-23", "2026-10-24", "2026-10-25", "2026-10-26", "2026-10-27"])
        XCTAssertEqual(reading.recent.map(\.day), ["2026-10-26", "2026-10-25", "2026-10-24", "2026-10-23"])
    }

    func testALateEveningCheckInDoesNotSlideIntoTheNextDayInAnotherZone() {
        let tokyo = cal("Asia/Tokyo"); var tasks = [series(start: "2026-11-02")]
        // 23:30 in Tokyo is 14:30 UTC the same day.
        complete(&tasks, at: at("2026-11-02", hour: 23, tokyo).addingTimeInterval(1800), tokyo)
        let reading = read(tasks, today: "2026-11-03", tokyo)
        XCTAssertEqual(reading.recent.first?.day, "2026-11-02")
        XCTAssertEqual(reading.currentStreak.length, 1)
    }

    func testTheSpringForwardDayKeepsAllSevenDaysDistinct() {
        let ny = cal("America/New_York")  // 2026-03-08, 23-hour day
        var tasks = [series(start: "2026-03-05")]
        for d in ["2026-03-05", "2026-03-06", "2026-03-07", "2026-03-08", "2026-03-09"] { complete(&tasks, at: at(d, hour: 20, ny), ny) }
        let reading = read(tasks, today: "2026-03-10", ny)
        XCTAssertEqual(Set(reading.week.map(\.id)).count, 7)
        XCTAssertEqual(reading.currentStreak.length, 5)
    }

    // MARK: Today chip, recent completions, accessibility

    func testTodaySummaryCountsHabitsDueOrDoneToday() {
        let c = cal()
        var a = [series(start: "2026-11-09")]
        var b = series(start: "2026-11-09"); b["id"] = .string("00000000-0000-4000-8000-000000000002")
        var later = series(start: "2026-11-12"); later["id"] = .string("00000000-0000-4000-8000-000000000003")
        var tasks = a + [b, later]
        XCTAssertNil(Habits.todaySummary(ids: [], tasks: tasks, today: "2026-11-09", calendar: c), "no chip without a habit")
        XCTAssertEqual(Habits.todaySummary(ids: [a[0].id, b.id, later.id], tasks: tasks, today: "2026-11-09", calendar: c), Habits.TodaySummary(done: 0, total: 2))
        complete(&a, at: at("2026-11-09", c), c); tasks = a + [b, later]
        let summary = Habits.todaySummary(ids: [a[0].id, b.id, later.id], tasks: tasks, today: "2026-11-09", calendar: c)
        XCTAssertEqual(summary, Habits.TodaySummary(done: 1, total: 2)); XCTAssertEqual(summary?.label, "Habits 1/2")
        XCTAssertNil(Habits.todaySummary(ids: [later.id], tasks: tasks, today: "2026-11-09", calendar: c), "nothing due today")
    }

    func testRecentCompletionsAreNewestFirstAndBounded() {
        let c = cal(); var tasks = [series(start: "2026-09-01")]
        for offset in 0..<40 { complete(&tasks, at: at(add("2026-09-01", offset, c), c), c) }
        let reading = read(tasks, today: "2026-10-12", c)
        XCTAssertEqual(reading.recent.count, Habits.recentLimit)
        XCTAssertEqual(reading.recent.first?.day, "2026-10-10")
        XCTAssertEqual(reading.recent.map(\.completedAt), reading.recent.map(\.completedAt).sorted(by: >))
    }

    func testSpokenSummaryNamesTheStreakAndToday() {
        let c = cal(); var tasks = [series(start: "2026-10-27")]
        for offset in 0..<12 { complete(&tasks, at: at(add("2026-10-27", offset, c), c), c) }
        let done = read(tasks, today: "2026-11-07", c)
        XCTAssertEqual(Habits.spoken(done), "Read 20 pages, 12-day streak, done today")
        let pending = read(tasks, today: "2026-11-08", c)
        XCTAssertEqual(Habits.spoken(pending), "Read 20 pages, 12-day streak, not done today")
        let none = read([series(type: "weekly", days: [1], start: "2026-11-02")], today: "2026-11-04", c)
        XCTAssertEqual(Habits.spoken(none), "Read 20 pages, no streak yet, not scheduled today")
    }

    func testAFinishedSeriesStillReadsButCannotCheckIn() {
        let c = cal(); var tasks = [series(start: "2026-11-02", extra: ["recurrence_end_date": .string("2026-11-03")])]
        complete(&tasks, at: at("2026-11-02", c), c); complete(&tasks, at: at("2026-11-03", c), c)
        XCTAssertNil(Habits.openOccurrence(tasks[0].id, in: tasks))
        let reading = read(tasks, today: "2026-11-04", c)
        XCTAssertNil(reading.occurrenceID); XCTAssertFalse(reading.canCheckIn)
        XCTAssertEqual(Habits.pruned([tasks[0].id], tasks: tasks, account: account), [], "a series with nothing left to do leaves the list")
    }

    func testAnUnknownSeriesReadsAsNothing() {
        XCTAssertNil(Habits.read(habit: "nope", tasks: [series(start: "2026-11-02")], calendar: cal(), now: Date()))
    }

    func testLongHistoriesStayBounded() {
        let c = cal(); var tasks = [series(start: "2024-01-01")]
        var rows = tasks[0]; rows["completed"] = .bool(false); tasks = [rows]
        let reading = read(tasks, today: "2026-11-11", c)
        XCTAssertEqual(reading.heatmap.count, 12)
        XCTAssertLessThanOrEqual(reading.week.count, 7)
        XCTAssertNotNil(reading.trackedSince)
    }
}
