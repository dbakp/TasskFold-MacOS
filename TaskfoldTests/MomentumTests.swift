import XCTest
@testable import TaskfoldCore

final class MomentumTests: XCTestCase {
    // Wednesday 14 October 2026, midday UTC.
    let now = TaskPlanning.instant("2026-10-14T12:00:00Z")!

    private func goals(zone: String = "UTC", daily: Int = 5, weekly: Int = 0, active: Set<Int> = Set(1...7), weekStart: Int = 2) throws -> ProductivityGoals {
        var value = try ProductivityGoals()
        value.dailyTarget = daily; value.weeklyTarget = weekly; value.activeWeekdays = active; value.weekStart = weekStart; value.timeZone = zone
        return try value.validated()
    }
    /// Oldest first; the last count is today (at `at`, in the goals' zone).
    private func days(_ counts: [Int], goals: ProductivityGoals, at: Date? = nil, coverage: [Int: InsightsReading.Coverage] = [:]) -> [InsightsReading.Day] {
        let calendar = goals.calendar, today = calendar.startOfDay(for: at ?? now)
        return counts.enumerated().map { index, count in
            let date = calendar.date(byAdding: .day, value: -(counts.count - 1 - index), to: today)!
            return InsightsReading.Day(id: TaskPlanner.dayKey(date, calendar: calendar), date: date, count: count, coverage: coverage[index] ?? .recorded,
                                       restDay: !goals.activeWeekdays.contains(calendar.component(.weekday, from: date)))
        }
    }
    private func states(_ counts: [Int], goals: ProductivityGoals, at: Date? = nil, coverage: [Int: InsightsReading.Coverage] = [:]) -> [MomentumDay] {
        Momentum.dayStates(days: days(counts, goals: goals, at: at, coverage: coverage), goals: goals, now: at ?? now)
    }
    private func daily(_ counts: [Int], goals: ProductivityGoals, at: Date? = nil, coverage: [Int: InsightsReading.Coverage] = [:]) -> (current: MomentumStreak, longest: MomentumStreak) {
        Momentum.dailyStreaks(states(counts, goals: goals, at: at, coverage: coverage))
    }

    // MARK: Daily streaks

    func testStreakCountsConsecutiveMetDaysEndingToday() throws {
        let g = try goals()
        let result = daily([0, 5, 6, 5, 9], goals: g)
        XCTAssertEqual(result.current.length, 4); XCTAssertNil(result.current.since); XCTAssertEqual(result.longest.length, 4)
    }
    func testTodayNotYetDoneEndsTheStreakYesterdayWithoutBreakingIt() throws {
        let g = try goals()
        XCTAssertEqual(daily([5, 5, 5, 2], goals: g).current.length, 3)
        XCTAssertEqual(daily([5, 5, 5, 0], goals: g).current.length, 3)
        XCTAssertEqual(daily([5, 5, 5, 5], goals: g).current.length, 4)
        XCTAssertEqual(states([5, 2], goals: g).last?.state, .pending)
    }
    func testAMissedDayBreaksTheCurrentStreakButLongestRemembersEarlierRuns() throws {
        let g = try goals()
        let result = daily([5, 5, 5, 5, 0, 5, 5], goals: g)
        XCTAssertEqual(result.current.length, 2); XCTAssertEqual(result.longest.length, 4)
        XCTAssertEqual(daily([0, 5, 5, 0, 5, 5, 5, 5, 5], goals: g).longest.length, 5)
    }
    func testRestDaysNeitherBreakNorExtendTheStreak() throws {
        // Monday to Friday active. Today is Monday 12 October: Mon-Fri met, weekend rest, today pending.
        let g = try goals(active: Set(2...6))
        let monday = TaskPlanning.instant("2026-10-12T09:00:00Z")!
        let result = daily([5, 5, 5, 5, 5, 0, 0, 0], goals: g, at: monday)
        XCTAssertEqual(result.current.length, 5)
        // Completing work on a rest day does not extend it either.
        XCTAssertEqual(daily([5, 5, 5, 5, 5, 3, 4, 5], goals: g, at: monday).current.length, 6)
        XCTAssertEqual(states([5, 5, 5, 5, 5, 3, 4, 0], goals: g, at: monday)[5].state, .rest)
    }
    func testVacationDaysAreSkippedAndPastVacationStaysExcluded() throws {
        var g = try goals()
        // Days: 8 Oct ... 14 Oct. A missed 11-12 Oct falls inside a past vacation.
        g.vacationRanges = [VacationRange(from: "2026-10-11", until: "2026-10-12")]
        let result = daily([5, 5, 5, 0, 0, 5, 5], goals: g)
        XCTAssertEqual(result.current.length, 5)
        XCTAssertEqual(states([5, 5, 5, 0, 0, 5, 5], goals: g)[3].state, .vacation)
        // The same history without the vacation is broken.
        XCTAssertEqual(daily([5, 5, 5, 0, 0, 5, 5], goals: try goals()).current.length, 2)
    }
    func testOpenEndedVacationFreezesTheStreakAtItsValue() throws {
        var g = try goals()
        g.vacationFrom = "2026-10-12"
        let result = daily([5, 5, 5, 5, 0, 0, 0], goals: g)
        XCTAssertEqual(result.current.length, 4)
        XCTAssertEqual(states([5, 5, 5, 5, 0, 0, 0], goals: g).last?.state, .vacation)
    }
    func testUntrackedHistoryEndsTheComputableStreakWithASinceDate() throws {
        let g = try goals()
        let result = daily([0, 0, 5, 5, 5], goals: g, coverage: [0: .untracked, 1: .untracked])
        XCTAssertEqual(result.current.length, 3)
        XCTAssertEqual(result.current.since, days([0, 0, 5, 5, 5], goals: g)[2].date)
        XCTAssertEqual(result.longest.length, 3); XCTAssertNotNil(result.longest.since)
        // A real miss is not a history limit.
        XCTAssertNil(daily([5, 0, 5, 5], goals: g).current.since)
    }
    func testPartialDayCountsAsMetOnlyWhenTheRecordedCountMeetsTheTarget() throws {
        let g = try goals()
        XCTAssertEqual(daily([5, 5, 5, 5], goals: g, coverage: [1: .partial]).current.length, 4)
        XCTAssertEqual(daily([5, 5, 4, 5], goals: g, coverage: [2: .partial]).current.length, 1)
        XCTAssertEqual(states([5, 4, 5], goals: g, coverage: [1: .partial])[1].state, .missed)
    }
    func testNoDailyGoalMeansNoStreaksAndNoChip() throws {
        let g = try goals(daily: 0, weekly: 10)
        let reading = reading(for: [5, 5, 5], goals: g)
        let summary = Momentum.summary(reading: reading, goals: g, now: now)
        XCTAssertFalse(summary.hasDailyGoal); XCTAssertEqual(summary.dailyStreak.length, 0); XCTAssertNil(summary.score); XCTAssertNil(summary.chipText)
    }
    func testStreakChipNeedsAtLeastTwoDays() throws {
        let g = try goals()
        XCTAssertNil(Momentum.summary(reading: reading(for: [0, 5], goals: g), goals: g, now: now).chipText)
        XCTAssertEqual(Momentum.summary(reading: reading(for: [5, 5, 5, 5, 5, 5, 5], goals: g), goals: g, now: now).chipText, "7-day streak")
    }

    // MARK: Time zones, DST and week starts

    func testStreakIsContinuousAcrossSpringAndAutumnDaylightSavingChanges() throws {
        let spring = try goals(zone: "America/New_York")
        let springNow = TaskPlanning.instant("2026-03-12T15:00:00Z")!  // days around 8 March (23-hour day)
        let springDays = days(Array(repeating: 5, count: 10), goals: spring, at: springNow)
        XCTAssertTrue(springDays.contains { $0.id == "2026-03-08" })
        XCTAssertEqual(Set(springDays.map(\.id)).count, 10)
        XCTAssertEqual(daily(Array(repeating: 5, count: 10), goals: spring, at: springNow).current.length, 10)
        let autumn = try goals(zone: "Europe/Copenhagen")
        let autumnNow = TaskPlanning.instant("2026-10-28T11:00:00Z")!  // around 25 October (25-hour day)
        XCTAssertEqual(daily(Array(repeating: 5, count: 8), goals: autumn, at: autumnNow).current.length, 8)
        XCTAssertTrue(days(Array(repeating: 5, count: 8), goals: autumn, at: autumnNow).contains { $0.id == "2026-10-25" })
    }
    func testVacationRangesUseCivilDaysInTheSavedZone() throws {
        var g = try goals(zone: "Pacific/Auckland")
        g.vacationRanges = [VacationRange(from: "2026-10-13", until: "2026-10-13")]
        XCTAssertTrue(g.isOnVacation(dayKey: "2026-10-13")); XCTAssertFalse(g.isOnVacation(dayKey: "2026-10-14"))
        let instant = TaskPlanning.instant("2026-10-13T20:00:00Z")!  // already 14 October in Auckland
        XCTAssertEqual(g.vacationStatus(now: instant), .off)
    }
    // The weekly tests use a 21-day window ending Wednesday 14 October 2026, so index i is 24 September + i.
    // Monday-started weeks: 21-27 Sep (partial head, idx 0-3), 28 Sep-4 Oct (4-10), 5-11 Oct (11-17), 12-14 Oct (18-20, current).
    // Sunday-started weeks: 20-26 Sep (head), 27 Sep-3 Oct (3-9), 4-10 Oct (10-16), 11-17 Oct (17-20, current).
    func testWeeklyStreakFollowsSundayAndMondayWeekStarts() throws {
        var c = Array(repeating: 0, count: 21)
        c[10] = 10; c[11] = 10   // Sunday 4 Oct and Monday 5 Oct
        let monday = try goals(weekly: 10, weekStart: 2), sunday = try goals(weekly: 10, weekStart: 1)
        // Monday weeks split them into two met weeks; Sunday weeks put both in one, and the week before is empty.
        XCTAssertEqual(Momentum.weeklyStreaks(states(c, goals: monday), goals: monday, now: now).current.length, 2)
        XCTAssertEqual(Momentum.weeklyStreaks(states(c, goals: sunday), goals: sunday, now: now).current.length, 1)
    }
    func testWeeklyStreakCurrentWeekCountsOnlyOnceMetAndRestDayWorkCounts() throws {
        let g = try goals(weekly: 10, active: Set(2...6))
        var c = Array(repeating: 0, count: 21)
        c[9] = 10   // Saturday 3 October: a rest day, but weekly goals include it
        var result = Momentum.weeklyStreaks(states(c, goals: g), goals: g, now: now)
        XCTAssertEqual(result.longest.length, 1)
        XCTAssertEqual(result.current.length, 0)         // 5-11 Oct was missed; the current week is simply skipped
        c[20] = 10                                       // reaching the target this week counts at once
        result = Momentum.weeklyStreaks(states(c, goals: g), goals: g, now: now)
        XCTAssertEqual(result.current.length, 1)
    }
    func testWeeklyStreakUsesExactWeeksForAKnownHistory() throws {
        let g = try goals(weekly: 10)
        var c = Array(repeating: 0, count: 21)
        c[5] = 10; c[12] = 10   // 29 Sep and 6 Oct
        XCTAssertEqual(Momentum.weeklyStreaks(states(c, goals: g), goals: g, now: now).current.length, 2)
        c[12] = 0               // 5-11 Oct unmet: the streak is broken
        let broken = Momentum.weeklyStreaks(states(c, goals: g), goals: g, now: now)
        XCTAssertEqual(broken.current.length, 0); XCTAssertEqual(broken.longest.length, 1)
        c[20] = 10
        XCTAssertEqual(Momentum.weeklyStreaks(states(c, goals: g), goals: g, now: now).current.length, 1)
    }
    func testWeeklyStreakStopsAtTheFirstWeekHistoryCannotJudge() throws {
        let g = try goals(weekly: 10)
        var c = Array(repeating: 0, count: 21)
        c[5] = 10; c[12] = 10
        let untracked = Dictionary(uniqueKeysWithValues: (0...3).map { ($0, InsightsReading.Coverage.untracked) })
        let result = Momentum.weeklyStreaks(states(c, goals: g, coverage: untracked), goals: g, now: now)
        XCTAssertEqual(result.current.length, 2)
        XCTAssertEqual(result.current.since, days(c, goals: g)[4].date)  // since Monday 28 September
        // With no weekly goal there is no weekly streak.
        let off = try goals(weekly: 0)
        XCTAssertEqual(Momentum.weeklyStreaks(states(c, goals: off), goals: off, now: now).current.length, 0)
    }

    // MARK: Score

    func testScoreIsExponentiallyWeightedAndScaledToOneHundred() throws {
        let g = try goals()
        XCTAssertEqual(Momentum.score(states([5, 5, 5, 5, 5, 5, 5], goals: g)), 67)   // meeting the goal every day
        XCTAssertEqual(Momentum.score(states([8, 8, 8, 8, 8, 8, 8], goals: g)), 100)  // 1.5x cap
        XCTAssertEqual(Momentum.score(states([50, 50, 50], goals: g)), 100)           // never above 100
        XCTAssertNil(Momentum.score(states([0], goals: g)))                           // today in progress, nothing else to score
        // Recent days outweigh old ones: a miss yesterday costs more than a miss a week ago.
        let missYesterday = Momentum.score(states([5, 5, 5, 5, 5, 5, 0, 0], goals: g))!
        let missLongAgo = Momentum.score(states([0, 5, 5, 5, 5, 5, 5, 0], goals: g))!
        XCTAssertLessThan(missYesterday, missLongAgo)
    }
    func testScoreHalfLifeIsSevenDays() throws {
        let g = try goals()
        // Two scorable days: today (1.5x, weight 1) and a miss seven days ago (weight 0.5).
        let value = Momentum.score(states([0, 0, 0, 0, 0, 0, 0, 0, 8], goals: g).enumerated().map { index, day in
            var copy = day; if index != 1 && index != 8 { copy.state = .rest; copy.target = nil }; return copy
        })!
        XCTAssertEqual(value, 67)  // 100 * 1.5 / (1.5 * 1.5)
    }
    func testScoreIgnoresRestVacationPendingAndIncompleteDaysAndNeverPunishesOverdue() throws {
        var g = try goals(active: Set(2...6))
        g.vacationRanges = [VacationRange(from: "2026-10-05", until: "2026-10-06")]
        let monday = TaskPlanning.instant("2026-10-12T09:00:00Z")!
        let mixed = Momentum.score(states([0, 0, 5, 5, 5, 0, 0, 2], goals: g, at: monday))  // vacation Mon-Tue, rest weekend, today pending
        XCTAssertEqual(mixed, 67)
        // A partial day short of the target is not scored as a miss.
        XCTAssertEqual(Momentum.score(states([2, 5, 5], goals: try goals(), coverage: [0: .partial])), 67)
    }

    // MARK: Levels

    func testLevelBoundariesAndProgress() {
        let names = Momentum.levelNames
        XCTAssertEqual(names, ["Starting", "Steady", "Focused", "Flowing", "Unstoppable", "Luminous"])
        for (points, name) in [(0, "Starting"), (49, "Starting"), (50, "Steady"), (249, "Steady"), (250, "Focused"), (999, "Focused"), (1000, "Flowing"), (2499, "Flowing"), (2500, "Unstoppable"), (4999, "Unstoppable"), (5000, "Luminous"), (90000, "Luminous")] {
            XCTAssertEqual(Momentum.level(totalCompletions: points, longestDailyStreak: 0).name, name, "\(points)")
        }
        let steady = Momentum.level(totalCompletions: 150, longestDailyStreak: 0)
        XCTAssertEqual(steady.progress, 0.5, accuracy: 0.0001); XCTAssertEqual(steady.remaining, 100); XCTAssertEqual(steady.next?.name, "Focused")
        let top = Momentum.level(totalCompletions: 6000, longestDailyStreak: 0)
        XCTAssertEqual(top.progress, 1); XCTAssertNil(top.next); XCTAssertNil(top.remaining)
        XCTAssertEqual(Momentum.level(totalCompletions: 0, longestDailyStreak: 0).progress, 0)
    }
    func testStreakMilestonesAddAModestBonusButCompletionsDriveLevels() {
        XCTAssertEqual(Momentum.level(totalCompletions: 45, longestDailyStreak: 6).name, "Starting")
        XCTAssertEqual(Momentum.level(totalCompletions: 45, longestDailyStreak: 7).name, "Steady")
        XCTAssertEqual(Momentum.level(totalCompletions: 0, longestDailyStreak: 365).points, 10 + 40 + 150 + 500)
        XCTAssertEqual(Momentum.level(totalCompletions: -4, longestDailyStreak: 0).points, 0)
    }

    // MARK: Vacation document

    func testVacationFieldsRoundTripWithoutBumpingVersionAndUnknownFieldsSurvive() throws {
        var g = try goals()
        g.vacationFrom = "2026-10-10"; g.vacationUntil = "2026-10-20"
        g.vacationRanges = [VacationRange(from: "2026-08-01", until: "2026-08-10")]
        var object = g.document.object
        XCTAssertEqual(object["version"], .number(1))
        XCTAssertEqual(object["vacation_from"], .string("2026-10-10")); XCTAssertEqual(object["vacation_until"], .string("2026-10-20"))
        object["something_new"] = .string("kept")
        let decoded = try ProductivityGoals(document: JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(JSON.object(object))))
        XCTAssertEqual(decoded.vacationFrom, "2026-10-10"); XCTAssertEqual(decoded.vacationUntil, "2026-10-20")
        XCTAssertEqual(decoded.vacationRanges, g.vacationRanges)
        XCTAssertEqual(decoded.document.object["something_new"], .string("kept"))
        var open = g; open.vacationUntil = nil
        XCTAssertNil(open.document.object["vacation_until"])
        XCTAssertEqual(try ProductivityGoals(document: open.document).vacationUntil, nil)
    }
    func testOlderDocumentsWithoutVacationFieldsStillLoad() throws {
        let g = try goals()
        let loaded = try ProductivityGoals(document: g.document)
        XCTAssertNil(loaded.vacationFrom); XCTAssertTrue(loaded.vacationRanges.isEmpty); XCTAssertEqual(loaded.vacationStatus(now: now), .off)
        XCTAssertNil(loaded.document.object["vacation_ranges"])
    }
    func testMalformedVacationDataIsIgnoredAndNeverDiscardsTheGoals() throws {
        let base = try goals().document.object
        let cases: [[String: JSON]] = [
            ["vacation_from": .string("not a date")],
            ["vacation_from": .string("2026-02-30")],
            ["vacation_from": .string("2026-10-10"), "vacation_until": .string("2026-10-01")],
            ["vacation_until": .string("2026-10-01")],
            ["vacation_from": .number(5)],
            ["vacation_ranges": .string("nope")],
            ["vacation_ranges": .array([.object(["from": .string("2026-09-02"), "until": .string("2026-09-01")])])],
        ]
        for extra in cases {
            let loaded = try ProductivityGoals(document: .object(base.merging(extra) { $1 }))
            XCTAssertEqual(loaded.dailyTarget, 5, "\(extra)"); XCTAssertNil(loaded.vacationFrom); XCTAssertTrue(loaded.vacationRanges.isEmpty)
            XCTAssertEqual(loaded.vacationStatus(now: now), .off)
            XCTAssertNil(loaded.document.object["vacation_from"])
        }
    }
    func testOverlappingStoredRangesKeepTheEarlierAndTheCapKeepsTheNewestTen() throws {
        let base = try goals().document.object
        func range(_ from: String, _ until: String) -> JSON { .object(["from": .string(from), "until": .string(until)]) }
        let overlapping = try ProductivityGoals(document: .object(base.merging(["vacation_ranges": .array([range("2026-05-01", "2026-05-10"), range("2026-05-05", "2026-05-12"), range("2026-06-01", "2026-06-02")])]) { $1 }))
        XCTAssertEqual(overlapping.vacationRanges, [VacationRange(from: "2026-05-01", until: "2026-05-10"), VacationRange(from: "2026-06-01", until: "2026-06-02")])
        let many = (1...12).map { range(String(format: "2026-%02d-01", $0), String(format: "2026-%02d-03", $0)) }
        let capped = try ProductivityGoals(document: .object(base.merging(["vacation_ranges": .array(many)]) { $1 }))
        XCTAssertEqual(capped.vacationRanges.count, 10); XCTAssertEqual(capped.vacationRanges.first?.from, "2026-03-01")
        let data = try TaskfoldJSONEncoder().encode(capped.document)
        XCTAssertLessThan(data.count, 4096)
    }
    func testBuiltValuesAreValidatedWithTheExistingMessageStyle() throws {
        var g = try goals()
        g.vacationFrom = "2026-10-10"; g.vacationUntil = "2026-10-01"
        XCTAssertThrowsError(try g.validated()) { XCTAssertTrue($0.localizedDescription.contains("vacation")) }
        g.vacationUntil = nil; g.vacationRanges = [VacationRange(from: "2026-10-05", until: "2026-10-12")]
        XCTAssertThrowsError(try g.validated())  // overlaps the open-ended current vacation
        g.vacationRanges = [VacationRange(from: "2026-10-01", until: "2026-10-05")]
        XCTAssertNoThrow(try g.validated())
        g.vacationRanges = (0..<11).map { VacationRange(from: "2026-0\(1 + $0 % 9)-0\(1 + $0 / 9)", until: "2026-0\(1 + $0 % 9)-0\(1 + $0 / 9)") }
        XCTAssertThrowsError(try g.validated())
    }
    func testStartingAndEndingVacationArchivesHistoryAndTurnsOffAfterTheEndDate() throws {
        var g = try goals()
        try g.startVacation(until: "2026-10-16", now: now)
        XCTAssertEqual(g.vacationStatus(now: now), .on(from: "2026-10-14", until: "2026-10-16"))
        // Changing the end date keeps the start.
        try g.startVacation(until: nil, now: now)
        XCTAssertEqual(g.vacationStatus(now: now), .on(from: "2026-10-14", until: nil))
        try g.startVacation(until: "2026-10-15", now: now)
        // After the end date it is off by itself and the range stays excluded.
        let later = TaskPlanning.instant("2026-10-17T09:00:00Z")!
        XCTAssertEqual(g.vacationStatus(now: later), .off); XCTAssertTrue(g.isOnVacation(dayKey: "2026-10-15"))
        // Starting again archives the finished one first.
        try g.startVacation(until: nil, now: later)
        XCTAssertEqual(g.vacationRanges, [VacationRange(from: "2026-10-14", until: "2026-10-15")])
        XCTAssertEqual(g.vacationStatus(now: later), .on(from: "2026-10-17", until: nil))
        // Turning off later keeps past days frozen but today and later live again.
        let end = TaskPlanning.instant("2026-10-20T09:00:00Z")!
        g.endVacation(now: end)
        XCTAssertEqual(g.vacationStatus(now: end), .off)
        XCTAssertTrue(g.isOnVacation(dayKey: "2026-10-19")); XCTAssertFalse(g.isOnVacation(dayKey: "2026-10-20"))
        XCTAssertEqual(g.vacationRanges.count, 2); XCTAssertNoThrow(try g.validated())
        // Turning it on and off the same day leaves no trace.
        var same = try goals()
        try same.startVacation(until: nil, now: now); same.endVacation(now: now)
        XCTAssertTrue(same.vacationRanges.isEmpty); XCTAssertNil(same.vacationFrom)
        // An end before the start is rejected and leaves the goals unchanged.
        var reject = try goals()
        XCTAssertThrowsError(try reject.startVacation(until: "2026-10-01", now: now))
        XCTAssertNil(reject.vacationFrom)
    }
    func testScheduledVacationDoesNotFreezeYet() throws {
        var g = try goals()
        g.vacationFrom = "2026-10-20"
        XCTAssertEqual(g.vacationStatus(now: now), .scheduled(from: "2026-10-20", until: nil))
        XCTAssertEqual(states([5, 5], goals: g).last?.state, .met)
    }
    func testKeepingKnownFieldsTakesTheDraftsVacationOverTheRemote() throws {
        var remote = try goals(); remote.vacationFrom = "2026-10-01"
        var mine = try goals(); mine.dailyTarget = 6; mine.vacationFrom = "2026-10-12"; mine.vacationUntil = "2026-10-18"
        let merged = try ProductivityGoals(document: ProductivityGoalEdit.keepingKnownFields(mine.document, over: remote.document))
        XCTAssertEqual(merged.vacationFrom, "2026-10-12"); XCTAssertEqual(merged.vacationUntil, "2026-10-18"); XCTAssertEqual(merged.dailyTarget, 6)
        let ended = try ProductivityGoals(document: ProductivityGoalEdit.keepingKnownFields(try goals().document, over: remote.document))
        XCTAssertNil(ended.vacationFrom)
    }

    // MARK: Milestones

    private func defaultsSuite() -> UserDefaults {
        let name = "momentum-tests-" + UUID().uuidString
        let suite = UserDefaults(suiteName: name)!
        addTeardownBlock { suite.removePersistentDomain(forName: name) }
        return suite
    }
    private func summary(streak: Int, total: Int, goals g: ProductivityGoals, vacation: VacationStatus = .off) -> MomentumSummary {
        var value = Momentum.summary(reading: reading(for: [5], goals: g), goals: g, now: now)
        value.dailyStreak = MomentumStreak(length: streak, since: nil); value.level = Momentum.level(totalCompletions: total, longestDailyStreak: streak)
        value.vacation = vacation; value.reliable = true
        return value
    }
    func testStreakMilestoneFiresOnceOnTheCompletionThatMeetsTheGoal() throws {
        let g = try goals(), defaults = defaultsSuite()
        for length in [7, 30, 100, 365] {
            let suite = defaultsSuite()
            XCTAssertEqual(MomentumCelebration.milestone(summary: summary(streak: length, total: 20, goals: g), goals: g, todayCount: 5, account: "me", now: now, defaults: suite), .streak(length))
            XCTAssertNil(MomentumCelebration.milestone(summary: summary(streak: length, total: 20, goals: g), goals: g, todayCount: 5, account: "me", now: now, defaults: suite))
        }
        for length in [1, 2, 6, 8, 29] { XCTAssertNil(MomentumCelebration.milestone(summary: summary(streak: length, total: 20, goals: g), goals: g, todayCount: 5, account: "me", now: now, defaults: defaults)) }
        // Not on the completion that merely adds more work after the goal.
        XCTAssertNil(MomentumCelebration.milestone(summary: summary(streak: 7, total: 20, goals: g), goals: g, todayCount: 6, account: "me", now: now, defaults: defaults))
        // The next day it can fire again for the next milestone.
        let suite = defaultsSuite()
        _ = MomentumCelebration.milestone(summary: summary(streak: 7, total: 20, goals: g), goals: g, todayCount: 5, account: "me", now: now, defaults: suite)
        XCTAssertEqual(MomentumCelebration.milestone(summary: summary(streak: 30, total: 20, goals: g), goals: g, todayCount: 5, account: "me", now: now.addingTimeInterval(86400), defaults: suite), .streak(30))
    }
    func testLevelUpFiresOncePerLevelAndTheFirstReadOnlyRecords() throws {
        let g = try goals(), defaults = defaultsSuite()
        XCTAssertNil(MomentumCelebration.milestone(summary: summary(streak: 0, total: 400, goals: g), goals: g, todayCount: 1, account: "me", now: now, defaults: defaults))  // first read: silent
        XCTAssertNil(MomentumCelebration.milestone(summary: summary(streak: 0, total: 999, goals: g), goals: g, todayCount: 1, account: "me", now: now, defaults: defaults))
        XCTAssertEqual(MomentumCelebration.milestone(summary: summary(streak: 0, total: 1000, goals: g), goals: g, todayCount: 1, account: "me", now: now, defaults: defaults), .level(name: "Flowing"))
        XCTAssertNil(MomentumCelebration.milestone(summary: summary(streak: 0, total: 1000, goals: g), goals: g, todayCount: 1, account: "me", now: now, defaults: defaults))
        // Undoing and completing again does not repeat it, and accounts are separate.
        XCTAssertNil(MomentumCelebration.milestone(summary: summary(streak: 0, total: 999, goals: g), goals: g, todayCount: 1, account: "me", now: now, defaults: defaults))
        XCTAssertNil(MomentumCelebration.milestone(summary: summary(streak: 0, total: 999, goals: g), goals: g, todayCount: 1, account: "other", now: now, defaults: defaults))
    }
    func testAStreakOutranksALevelUpOnTheSameCompletionAndVacationSilencesBoth() throws {
        let g = try goals(), defaults = defaultsSuite()
        _ = MomentumCelebration.milestone(summary: summary(streak: 0, total: 10, goals: g), goals: g, todayCount: 1, account: "me", now: now, defaults: defaults)
        XCTAssertEqual(MomentumCelebration.milestone(summary: summary(streak: 7, total: 60, goals: g), goals: g, todayCount: 5, account: "me", now: now, defaults: defaults), .streak(7))
        let quiet = defaultsSuite()
        _ = MomentumCelebration.milestone(summary: summary(streak: 0, total: 10, goals: g), goals: g, todayCount: 1, account: "me", now: now, defaults: quiet)
        XCTAssertNil(MomentumCelebration.milestone(summary: summary(streak: 7, total: 60, goals: g, vacation: .on(from: "2026-10-14", until: nil)), goals: g, todayCount: 5, account: "me", now: now, defaults: quiet))
        XCTAssertEqual(MomentumMilestone.streak(7).title, "7-day streak"); XCTAssertEqual(MomentumMilestone.level(name: "Steady").title, "Level up")
    }

    // MARK: Whole history

    private func reading(for counts: [Int], goals g: ProductivityGoals) -> InsightsReading {
        var value = InsightsReading(account: "me", activity: [], epoch: [], goals: g, scope: .mine, windowDays: 1, now: now)
        value.days = days(counts, goals: g)
        value.credits = (0..<counts.reduce(0, +)).map { InsightsReading.Credit(taskID: "t\($0)", lifecycle: "l", version: 1, date: now, projectID: "", actor: "me") }
        return value
    }
    func testSummaryCombinesStreaksScoreLevelAndTheLastSevenDays() throws {
        let g = try goals(weekly: 20)
        let counts = Array(repeating: 5, count: 8)
        let summary = Momentum.summary(reading: reading(for: counts, goals: g), goals: g, now: now)
        XCTAssertEqual(summary.dailyStreak.length, 8); XCTAssertEqual(summary.longestDailyStreak.length, 8); XCTAssertEqual(summary.week.count, 7); XCTAssertEqual(summary.week.map(\.state), Array(repeating: .met, count: 7))
        XCTAssertEqual(summary.totalCompletions, 40); XCTAssertEqual(summary.level.points, 50); XCTAssertEqual(summary.level.name, "Steady"); XCTAssertEqual(summary.score, 67)  // 40 completions + the 7-day milestone
        XCTAssertEqual(summary.vacation, .off); XCTAssertEqual(summary.chipText, "8-day streak")
    }
    func testDayStatesCoverMetMissedRestVacationAndPending() throws {
        var g = try goals(active: Set(2...6))
        g.vacationRanges = [VacationRange(from: "2026-10-07", until: "2026-10-07")]
        let monday = TaskPlanning.instant("2026-10-12T09:00:00Z")!
        // 6 Oct Tue ... 12 Oct Mon.
        let result = states([5, 0, 0, 5, 0, 0, 1], goals: g, at: monday).map(\.state)
        XCTAssertEqual(result, [.met, .vacation, .missed, .met, .rest, .rest, .pending])
    }

    #if DEBUG
    func testPreparedInsightsCarriesPersonalMomentumFromOneFold() throws {
        let account = "f1740000-0000-4000-8000-000000000001"
        let snapshot = Snapshot.insightsFixture(account: account, now: now)
        let goalsValue = try XCTUnwrap(ProductivityGoals.row(snapshot, account: account).flatMap { try? ProductivityGoals(document: $0[ProductivityGoals.field] ?? .null) })
        let input = PreparedInsights.Input(account: account, activity: snapshot.tables[TaskActivity.table] ?? [], epoch: snapshot.tables[TaskActivity.epochTable] ?? [],
                                           goals: goalsValue, accessibleProjects: [], children: ChildWorkHistory(rows: nil, epoch: nil), now: now)
        let prepared = try PreparedInsights(input, shouldStop: { false })
        // The fixture holds 2 of the user's own completions today and 1 eight days ago; a teammate's is not theirs.
        XCTAssertEqual(prepared.momentum.totalCompletions, 3)
        XCTAssertEqual(prepared.reading(scope: .mine, windowDays: 7).today, 2)
        XCTAssertEqual(prepared.reading(scope: .mine, windowDays: 28).days.count, 28)
        XCTAssertEqual(prepared.reading(scope: .mine, windowDays: 7).days.count, 7)
        XCTAssertEqual(prepared.momentum.week.count, 7)
        XCTAssertEqual(prepared.momentum.dailyStreak.length, 0)
        XCTAssertEqual(prepared.momentum.vacation, .off)
    }
    #endif
}
