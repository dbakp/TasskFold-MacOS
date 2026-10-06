import XCTest
@testable import TaskfoldCore

final class NaturalDateTests: XCTestCase {
    private func calendar(_ zone: String = "Europe/Copenhagen", identifier: Calendar.Identifier = .gregorian) -> Calendar {
        var calendar = Calendar(identifier: identifier); calendar.timeZone = TimeZone(identifier: zone)!; return calendar
    }
    private func now(_ day: String = "2026-10-06", zone: String = "Europe/Copenhagen") -> Date {
        Dates.parse(day, calendar: calendar(zone))!.addingTimeInterval(12 * 3600)
    }
    private func quick(_ input: String, day: String = "2026-10-06", disabled: Set<String> = []) -> QuickEntry {
        QuickEntry(input, now: now(day), calendar: calendar(), disabled: disabled)
    }
    func testNamedDatesWithBothOrdersYearsAndOrdinalsAreOneChip() {
        for (phrase, expected) in [("January 3", "2027-01-03"), ("3 Jan", "2027-01-03"), ("January 3rd, 2028", "2028-01-03"), ("3rd January 2028", "2028-01-03"), ("Oct 6", "2026-10-06"), ("May 1 2025", "2025-05-01")] {
            let parsed = quick("☎️ Review " + phrase + " p2 ~25m")
            XCTAssertEqual(parsed.title, "☎️ Review", phrase); XCTAssertEqual(parsed.updates["due_date"], .string(expected), phrase)
            XCTAssertEqual(parsed.tokens.filter { $0.group == "due_date" }.map(\.text), [phrase]); XCTAssertTrue(parsed.warnings.isEmpty, phrase)
            XCTAssertEqual(parsed.updates["priority"], .number(2)); XCTAssertEqual(parsed.updates["duration_minutes"], .number(25))
            if phrase.contains("2028") { XCTAssertTrue(parsed.tokens.first { $0.group == "due_date" }?.label.contains("2028") == true) }
        }
    }
    func testInvalidNamedDatesStayLiteralWithoutCalendarNormalization() {
        for phrase in ["April 31", "31 February", "January 0", "Feb 29 2027", "Jan 999999999999999999999", "May 3 0000"] {
            let parsed = quick("Review " + phrase)
            XCTAssertEqual(parsed.title, "Review " + phrase, phrase); XCTAssertNil(parsed.updates["due_date"], phrase)
            XCTAssertFalse(parsed.warnings.isEmpty, phrase)
        }
    }
    func testOmittedLeapYearFindsNextRealDayIncludingCenturyGap() {
        XCTAssertEqual(quick("Birthday Feb 29", day: "2029-03-01").updates["due_date"], .string("2032-02-29"))
        XCTAssertEqual(quick("Birthday Feb 29", day: "2097-03-01").updates["due_date"], .string("2104-02-29"))
    }
    func testNamedDeadlineRemainsSeparateFromPlannedDateAndDeclinesIndependently() {
        let parsed = quick("Review tomorrow {end of month} at 9am")
        XCTAssertEqual(parsed.title, "Review"); XCTAssertEqual(parsed.updates["due_date"], .string("2026-10-07"))
        XCTAssertEqual(parsed.updates["deadline_date"], .string("2026-10-31")); XCTAssertEqual(parsed.updates["due_time"], .string("09:00"))
        let kept = quick("Review tomorrow {3 January}", disabled: ["deadline_date"])
        XCTAssertEqual(kept.title, "Review {3 January}"); XCTAssertNil(kept.updates["deadline_date"]); XCTAssertEqual(kept.updates["due_date"], .string("2026-10-07"))
        for phrase in ["{April 31}", "{May 3 0000}", "{tomorrow at 9am}"] {
            let invalid = quick("Review " + phrase)
            XCTAssertEqual(invalid.title, "Review " + phrase); XCTAssertTrue(invalid.updates.isEmpty); XCTAssertFalse(invalid.warnings.isEmpty)
        }
    }
    func testPeriodDatesUseExplicitMondayMonthClampAndYearBoundary() {
        for (phrase, expected) in [("next week", "2026-10-12"), ("next month", "2026-11-06"), ("next year", "2027-01-01"), ("end of month", "2026-10-31"), ("end of year", "2026-12-31")] {
            let parsed = quick("Review " + phrase)
            XCTAssertEqual(parsed.title, "Review"); XCTAssertEqual(parsed.updates["due_date"], .string(expected))
        }
        XCTAssertEqual(quick("Review next week", day: "2026-10-12").updates["due_date"], .string("2026-10-19"))
        XCTAssertEqual(quick("Review next month", day: "2027-01-31").updates["due_date"], .string("2027-02-28"))
        XCTAssertEqual(quick("Review end of month", day: "2028-02-29").updates["due_date"], .string("2028-02-29"))
    }
    func testNamedRepeatBoundariesResolveEndRelativeToStartAcrossNewYear() {
        let parsed = quick("Review every day from 31 December until 3 January for 4 occurrences at 9am !30mb")
        XCTAssertEqual(parsed.title, "Review"); XCTAssertEqual(parsed.updates["due_date"], .string("2026-12-31"))
        let rule = parsed.updates["recurrence_pattern"]?.object
        XCTAssertEqual(rule?["endDate"], .string("2027-01-03")); XCTAssertEqual(rule?["count"], .number(4))
        XCTAssertEqual(parsed.tokens.filter { $0.group == "recurrence" }.count, 1); XCTAssertTrue(parsed.warnings.isEmpty)
        XCTAssertEqual(parsed.updates["due_time"], .string("09:00"))
        XCTAssertTrue(parsed.updates["reminder_specs"]?.list.compactMap(ReminderSpec.init(row:)).contains { $0.offset == -30 } == true)
        let reverse = quick("Review every day until 3 January from 31 December")
        XCTAssertEqual(reverse.updates["recurrence_pattern"]?.object["endDate"], .string("2027-01-03"))
        XCTAssertEqual(reverse.updates["due_date"], .string("2026-12-31"))
    }
    func testNamedRepeatBoundsRemainOneLiteralWhenInvalidDeclinedOrEscaped() {
        for (phrase, disabled) in [("every day starting 3 January until 9 January", Set(["recurrence"])), ("every day from April 31 until December 31", Set<String>()), ("every day from 3 January 2027 until 2 January 2027", Set<String>()), ("every day from 3 January starting 4 January", Set<String>())] {
            let parsed = quick("Review " + phrase, disabled: disabled)
            XCTAssertEqual(parsed.title, "Review " + phrase, phrase); XCTAssertTrue(parsed.updates.isEmpty, phrase)
        }
        let escaped = quick(#"Review \every day from 3 January until 9 January"#)
        XCTAssertEqual(escaped.title, "Review every day from 3 January until 9 January"); XCTAssertTrue(escaped.updates.isEmpty)
        XCTAssertTrue(quick(#"Review "every day from 3 January until 9 January""#).updates.isEmpty)
    }
    func testRelativeAndPeriodRepeatBoundariesAreInclusive() {
        let period = quick("Review every day from next month ending end of month")
        XCTAssertEqual(period.updates["due_date"], .string("2026-11-06"))
        XCTAssertEqual(period.updates["recurrence_pattern"]?.object["endDate"], .string("2026-11-30"))
        let weekday = quick("Review every friday starting next friday until 23 October")
        XCTAssertEqual(weekday.updates["due_date"], .string("2026-10-09"))
        XCTAssertEqual(weekday.updates["recurrence_pattern"]?.object["endDate"], .string("2026-10-23"))
        var task = quick("Review every day from 31 December until 3 January for 4 occurrences").applying(to: Record.task(user: "owner"))
        for expected in ["2027-01-01", "2027-01-02", "2027-01-03"] {
            let next = TaskCompletion.complete(task, tasks: [], at: now(task.string("due_date")), calendar: calendar()).last!
            XCTAssertEqual(next.fields["due_date"], .string(expected)); task = Record(next.fields)
        }
        XCTAssertEqual(TaskCompletion.complete(task, tasks: [], at: now(task.string("due_date")), calendar: calendar()).count, 1)
    }
    func testInjectedZoneAndNonGregorianCalendarKeepStoredCivilDays() {
        let instant = ISO8601DateFormatter().date(from: "2026-10-06T23:30:00Z")!
        for zone in ["Pacific/Auckland", "America/Los_Angeles", "Asia/Kathmandu"] {
            let c = calendar(zone, identifier: .buddhist)
            for phrase in ["7 October 2026", "2026-10-07"] {
                let parsed = QuickEntry("Review " + phrase + " {end of month}", now: instant, calendar: c)
                XCTAssertEqual(parsed.updates["due_date"], .string("2026-10-07"), zone + phrase)
                XCTAssertEqual(parsed.updates["deadline_date"], .string("2026-10-31"), zone)
                XCTAssertNotNil(parsed.tokens.first { $0.group == "deadline_date" }?.label.range(of: #"\b31\b"#, options: .regularExpression), zone)
            }
        }
        let dst = quick("Review next month", day: "2026-09-30")
        XCTAssertEqual(dst.updates["due_date"], .string("2026-10-30"))
    }
    func testLiteralProtectionRetainsNamedDatesAndDoesNotConsumeOrdinaryMonthWords() {
        for phrase in [#""January 3""#, #"\January 3"#, "https://example.test/January-3", "Discuss March plans", "May we proceed", "April report"] {
            let parsed = quick("Review " + phrase)
            XCTAssertTrue(parsed.updates.isEmpty, phrase)
        }
        XCTAssertEqual(quick("Review January 3", disabled: ["due_date"]).title, "Review January 3")
        XCTAssertTrue(quick("Review January 3", disabled: ["due_date"]).updates.isEmpty)
    }
    func testPeriodCompletionChoicesPreviewTheSameAcceptedDates() throws {
        for (fragment, phrase, expected) in [("next w", "next week", "2026-10-12"), ("next m", "next month", "2026-11-06"), ("end of m", "end of month", "2026-10-31"), ("end of y", "end of year", "2026-12-31")] {
            let input = "Review " + fragment
            let menu = QuickPlanningCompletion(input, now: now(), calendar: calendar())
            let option = try XCTUnwrap(menu.options.first { $0.reference == phrase }, fragment)
            let chosen = try XCTUnwrap(menu.choosing(option, in: input))
            XCTAssertEqual(quick(chosen.text).updates["due_date"], .string(expected)); XCTAssertEqual(quick(chosen.text).title, "Review")
        }
    }
    func testBareWeekdayBoundariesAreInclusiveAndNextRemainsStrictlyFuture() {
        let parsed = quick("Review every day from tuesday until tuesday")
        XCTAssertEqual(parsed.updates["due_date"], .string("2026-10-06"))
        XCTAssertEqual(parsed.updates["recurrence_pattern"]?.object["endDate"], .string("2026-10-06"))
        let future = quick("Review every day until next tuesday")
        XCTAssertEqual(future.updates["recurrence_pattern"]?.object["endDate"], .string("2026-10-13"))
    }
    func testRepeatBoundaryResolutionUsesTheTasksSourceZone() {
        var task = Record.task(user: "owner"); task["time_zone"] = .string("America/Los_Angeles"); task["due_time"] = .string("09:00")
        let instant = ISO8601DateFormatter().date(from: "2026-10-06T23:30:00Z")!
        let parsed = QuickEntry("Review every day from today until end of month", now: instant, calendar: calendar("Pacific/Auckland"), task: task)
        XCTAssertEqual(parsed.updates["due_date"], .string("2026-10-06"))
        XCTAssertEqual(parsed.updates["recurrence_pattern"]?.object["endDate"], .string("2026-10-31"))
    }
    func testNamedFieldsRetainExistingMutationWireContract() throws {
        let original = quick("Review every day from 31 December until 3 January {end of year} ~25m").applying(to: Record.task(user: "owner"))
        let mutation = Mutation(table: "tasks", recordID: original.id, method: "POST", fields: original.fields)
        let decoded = try JSONDecoder().decode(Mutation.self, from: JSONEncoder().encode(mutation))
        XCTAssertEqual(decoded.fields["due_date"], .string("2026-12-31"))
        XCTAssertEqual(decoded.fields["deadline_date"], .string("2026-12-31"))
        XCTAssertEqual(decoded.fields["recurrence_pattern"]?.object["endDate"], .string("2027-01-03"))
        XCTAssertEqual(decoded.fields["duration_minutes"], .number(25))
    }
}
