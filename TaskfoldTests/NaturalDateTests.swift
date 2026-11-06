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


extension NaturalDateTests {
    func testDatePreferenceContractBoundsUnknownPreservationAndAccountSelection() throws {
        XCTAssertEqual(try DatePhrasePreferences(document: .null), DatePhrasePreferences())
        var original = DatePhrasePreferences(nextWeek: 6, weekend: 1).document.object; original["future_hint"] = .string("keep")
        let updated = try XCTUnwrap(DatePhrasePreferences.changing(.object(original), field: "weekend", weekday: 3))
        XCTAssertEqual(updated.object["next_week"], .number(6)); XCTAssertEqual(updated.object["future_hint"], .string("keep"))
        XCTAssertEqual(try DatePhrasePreferences(document: updated).weekend, 3)
        for bad in [JSON.number(1), .object(["version": .number(2)]), .object(["version": .number(1), "next_week": .number(1.5), "weekend": .number(7)]), .object(["version": .number(1), "next_week": .string("2"), "weekend": .number(7)])] { XCTAssertThrowsError(try DatePhrasePreferences(document: bad)); XCTAssertNil(DatePhrasePreferences.changing(bad, field: "weekend", weekday: 1)) }
        for day in [0,8] { XCTAssertNil(DatePhrasePreferences.changing(.null, field: "weekend", weekday: day)) }
        var snapshot = Snapshot(); snapshot.tables["view_preferences"] = [Record(["id": .string("dates"), "user_id": .string("other"), "date_preferences": updated]), Record(["id": .string("dates"), "user_id": .string("OWNER"), "date_preferences": .null])]
        XCTAssertEqual(DatePhrasePreferences.row(snapshot, account: "owner")?["date_preferences"], .null); XCTAssertNil(DatePhrasePreferences.row(snapshot, account: "unavailable"))
    }
    func testDatePreferenceStrictWeekInclusiveWeekendAndSkippedOccurrence() throws {
        let c = calendar("UTC"), preferences = DatePhrasePreferences(nextWeek: 6, weekend: 1)
        for (day, phrase, expected) in [("2026-10-08","next week","2026-10-09"),("2026-10-09","next week","2026-10-16"),("2026-10-08","this weekend","2026-10-11"),("2026-10-11","this weekend","2026-10-11"),("2026-10-11","next weekend","2026-10-18"),("2026-10-08","next weekend","2026-10-18")] {
            let date = try XCTUnwrap(QuickNaturalDateText.resolve(phrase, relativeTo: Dates.parse(day, calendar: c)!, calendar: c, datePreferences: preferences))
            XCTAssertEqual(TaskPlanner.dayKey(date, calendar: c),expected)
        }
        XCTAssertEqual(TaskPlanner.dayKey(QuickNaturalDateText.resolve("next week", relativeTo: Dates.parse("2026-10-08", calendar: c)!, calendar: c)!, calendar: c), "2026-10-12")
    }
    func testDatePreferenceCaptureDeadlineRepeatAndCompletionUseOneContract() throws {
        let instant = now("2026-10-08"), context = QuickEntryContext(datePreferences: DatePhrasePreferences(nextWeek: 6, weekend: 1))
        let parsed = QuickEntry("Review next week {this weekend}", now: instant, calendar: calendar(), context: context)
        XCTAssertEqual(parsed.title,"Review"); XCTAssertEqual(parsed.updates["due_date"],.string("2026-10-09")); XCTAssertEqual(parsed.updates["deadline_date"],.string("2026-10-11"))
        let repeated = QuickEntry("Review every day from next week until next weekend", now: instant, calendar: calendar(), context: context)
        XCTAssertEqual(repeated.title,"Review"); XCTAssertEqual(repeated.updates["due_date"],.string("2026-10-09")); XCTAssertEqual(repeated.updates["recurrence_pattern"]?.object["endDate"],.string("2026-10-18"))
        let declined = QuickEntry("Review next weekend", now: instant, calendar: calendar(), disabled:["due_date"], context: context)
        XCTAssertEqual(declined.title,"Review next weekend"); XCTAssertTrue(declined.updates.isEmpty)
        let menu = QuickEntryCompletion("Review next we", now: instant, calendar: calendar(), context: context)
        let option = try XCTUnwrap(menu.options.first { $0.reference == "next week" }); XCTAssertEqual(option.name,"Tomorrow")
        let weekendMenu = QuickEntryCompletion("Review this we", now: instant, calendar: calendar(), context: context)
        XCTAssertTrue(weekendMenu.options.contains { $0.reference == "this weekend" })
        var missing = context; missing.datePreferences = nil
        for text in ["Review next week", "Review this weekend", "Review next weekend", "Review {next week}", "Review every day from next week"] {
            let kept = QuickEntry(text, now: instant, calendar: calendar(), context: missing); XCTAssertEqual(kept.title,text); XCTAssertNil(kept.updates["due_date"]); XCTAssertFalse(kept.warnings.isEmpty)
        }
        XCTAssertFalse(QuickEntryCompletion("Review next we", now: instant, calendar: calendar(), context: missing).options.contains { DatePhrasePreferences.phrases.contains($0.reference) })
    }
    func testDatePreferencesFollowCivilDaysAcrossDSTAndSourceZonesWithoutRewritingAcceptedDates() throws {
        let c = calendar(), origin = Dates.parse("2026-10-24", calendar:c)!, preferences = DatePhrasePreferences(nextWeek:2,weekend:1)
        let resolved = try XCTUnwrap(QuickNaturalDateText.resolve("next week",relativeTo:origin,calendar:c,datePreferences:preferences))
        XCTAssertEqual(TaskPlanner.dayKey(resolved,calendar:c),"2026-10-26"); XCTAssertEqual(resolved.timeIntervalSince(origin),49*3600)
        let context = QuickEntryContext(datePreferences: preferences)
        let accepted = QuickEntry("Review next week",now:origin,calendar:c,context:context).applying(to:Record.task(user:"owner"))
        var next = context; next.datePreferences = DatePhrasePreferences(nextWeek:6,weekend:7)
        let untouched = QuickEntry(accepted.title,now:origin,calendar:c,context:next,task:accepted).applying(to:accepted)
        XCTAssertEqual(untouched["due_date"],accepted["due_date"])
        let rule = try XCTUnwrap(QuickRecurrenceText.parse("every day from next week",now:origin,calendar:calendar("Pacific/Honolulu"),datePreferences:preferences))
        XCTAssertEqual(rule.start,"2026-10-26")
    }
}

extension NaturalDateTests {
    func testCompoundDatesOffsetSupportedAnchorsAndNormalizeWhitespace() throws {
        let c = calendar("UTC"), anchor = Dates.parse("2026-10-08", calendar: c)!
        for (phrase, expected) in [("1 week after next week", "2026-10-19"), ("one day before next weekend", "2026-10-16"), ("2 weeks before 3 January 2027", "2026-12-20"), ("0 days after tomorrow", "2026-10-09"), ("2 days after end of month", "2026-11-02"), ("1 day before 2028-03-01", "2028-02-29"), ("  ONE\tweek AFTER\nnext week  ", "2026-10-19"), ("1 week after 2 days before next week", "2026-10-17")] {
            let value = try XCTUnwrap(QuickNaturalDateText.resolve(phrase, relativeTo: anchor, calendar: c), phrase)
            XCTAssertEqual(TaskPlanner.dayKey(value, calendar: c), expected, phrase)
        }
    }
    func testCompoundDatesRejectUnsupportedUnitsCountsDepthAndOverflow() {
        let c = calendar("UTC"), anchor = Dates.parse("2026-10-08", calendar: c)!
        for phrase in ["two days after today", "-1 day after today", "+1 day after today", "1 month after today", "1 year before today", "3651 days after today", "522 weeks after today", "3650 days after 1 day before today", "99999999999999999999 days after today", String(repeating: "0 days after ", count: 5) + "today", "1 day before 0001-01-01", "1 day after 9999-12-31", "1 day after April 31", "1 day after next holiday"] {
            XCTAssertNil(QuickNaturalDateText.resolve(phrase, relativeTo: anchor, calendar: c), phrase)
        }
        XCTAssertNotNil(QuickNaturalDateText.resolve("3650 days after today", relativeTo: anchor, calendar: c))
        XCTAssertNotNil(QuickNaturalDateText.resolve("521 weeks before today", relativeTo: anchor, calendar: c))
    }
    func testCompoundDatesUseCivilDaysAcrossDSTAndViewerZones() throws {
        for (zone, day, expected, hours) in [("Europe/Copenhagen", "2026-10-24", "2026-10-26", 49.0), ("America/New_York", "2026-03-07", "2026-03-09", 47.0), ("Australia/Lord_Howe", "2026-10-03", "2026-10-05", 47.5)] {
            let c = calendar(zone), anchor = Dates.parse(day, calendar: c)!
            let shifted = try XCTUnwrap(QuickNaturalDateText.resolve("2 days after today", relativeTo: anchor, calendar: c))
            XCTAssertEqual(TaskPlanner.dayKey(shifted, calendar: c), expected); XCTAssertEqual(shifted.timeIntervalSince(anchor), hours * 3600)
        }
        let instant = ISO8601DateFormatter().date(from: "2026-10-08T23:30:00Z")!
        for (zone, expected) in [("Pacific/Auckland", "2026-10-10"), ("America/Los_Angeles", "2026-10-09")] {
            let c = calendar(zone, identifier: .buddhist)
            let value = try XCTUnwrap(QuickNaturalDateText.resolve("1 day after today", relativeTo: instant, calendar: c))
            XCTAssertEqual(TaskPlanner.dayKey(value, calendar: c), expected)
        }
    }
    func testCompoundCaptureAndDeadlineRemainWholeIndependentChips() {
        let parsed = quick("Review 1 week after next week {2 days before end of month} at 9am p2")
        XCTAssertEqual(parsed.title, "Review"); XCTAssertEqual(parsed.updates["due_date"], .string("2026-10-19")); XCTAssertEqual(parsed.updates["deadline_date"], .string("2026-10-29"))
        XCTAssertEqual(parsed.tokens.filter { $0.group == "due_date" }.map(\.text), ["1 week after next week"])
        XCTAssertEqual(parsed.tokens.filter { $0.group == "deadline_date" }.map(\.text), ["{2 days before end of month}"])
        XCTAssertEqual(parsed.updates["due_time"], .string("09:00")); XCTAssertEqual(parsed.updates["priority"], .number(2)); XCTAssertTrue(parsed.warnings.isEmpty)
        for group in ["due_date", "deadline_date"] {
            let declined = quick("Review 1 week after next week {2 days before end of month}", disabled: [group])
            XCTAssertNil(declined.updates[group]); XCTAssertTrue(declined.title.contains(group == "due_date" ? "1 week after next week" : "{2 days before end of month}"))
        }
    }
    func testCompoundInvalidDeclinedQuotedAndEscapedCaptureCannotLeakTheAnchor() {
        for phrase in ["1 month after tomorrow", "3651 days after next week", "two days before January 3", "-2 weeks after today", "1 day after April 31", "1 day after next holiday", String(repeating: "0 days after ", count: 5) + "today"] {
            let parsed = quick("Review " + phrase)
            XCTAssertEqual(parsed.title, "Review " + phrase, phrase); XCTAssertNil(parsed.updates["due_date"], phrase); XCTAssertFalse(parsed.warnings.isEmpty, phrase)
        }
        for phrase in [#""1 week after next week""#, #"\1 week after next week"#] {
            let parsed = quick("Review " + phrase)
            XCTAssertNil(parsed.updates["due_date"]); XCTAssertTrue(parsed.title.contains("1 week after next week")); XCTAssertTrue(parsed.warnings.isEmpty)
        }
        let declined = quick("Review 1 week after next week", disabled: ["due_date"])
        XCTAssertEqual(declined.title, "Review 1 week after next week"); XCTAssertTrue(declined.updates.isEmpty)
    }
    func testCompoundRepeatAndIndependentReminderBoundariesResolveTogether() throws {
        let parsed = quick("Review every day from 1 week after next week until 2 days after 31 October 2026")
        XCTAssertEqual(parsed.title, "Review"); XCTAssertEqual(parsed.updates["due_date"], .string("2026-10-19")); XCTAssertEqual(parsed.updates["recurrence_pattern"]?.object["endDate"], .string("2026-11-02")); XCTAssertTrue(parsed.warnings.isEmpty)
        let declined = quick("Review every day from 1 week after next week until 2 days after 31 October 2026", disabled: ["recurrence"])
        XCTAssertEqual(declined.title, "Review every day from 1 week after next week until 2 days after 31 October 2026"); XCTAssertTrue(declined.updates.isEmpty)
        let reminder = quick("Review !every day 9am from 1 week after next week until 2 days after 31 October 2026")
        XCTAssertEqual(reminder.title, "Review"); XCTAssertNil(reminder.updates["due_date"]); XCTAssertTrue(reminder.warnings.isEmpty)
        let row = try XCTUnwrap(reminder.updates["reminder_specs"]?.list.first { $0.object["kind"] == .string("recurring") })
        XCTAssertEqual(row.object["start_day"], .string("2026-10-19")); XCTAssertEqual(row.object["recurrence"]?.object["endDate"], .string("2026-11-02"))
        let invalid = quick("Review every day from 1 month after tomorrow")
        XCTAssertEqual(invalid.title, "Review every day from 1 month after tomorrow"); XCTAssertTrue(invalid.updates.isEmpty)
    }
    func testCompoundPreferenceChangesDoNotRewriteAcceptedTaskDates() throws {
        let c = calendar("UTC"), anchor = Dates.parse("2026-10-08", calendar: c)!
        let friday = QuickEntryContext(datePreferences: DatePhrasePreferences(nextWeek: 6, weekend: 1))
        let accepted = QuickEntry("Review 1 week after next week", now: anchor, calendar: c, context: friday).applying(to: Record.task(user: "owner"))
        XCTAssertEqual(accepted.string("due_date"), "2026-10-16")
        var monday = friday; monday.datePreferences = DatePhrasePreferences()
        let retained = QuickEntry(accepted.title, now: anchor, calendar: c, context: monday, task: accepted).applying(to: accepted)
        XCTAssertEqual(retained["due_date"], accepted["due_date"])
        var unavailable = friday; unavailable.datePreferences = nil
        for text in ["Review 1 week after next week", "Review {1 day before this weekend}", "Review every day from 1 week after next week"] {
            let failed = QuickEntry(text, now: anchor, calendar: c, context: unavailable)
            XCTAssertEqual(failed.title, text); XCTAssertTrue(failed.updates.isEmpty); XCTAssertFalse(failed.warnings.isEmpty)
        }
    }
}

extension NaturalDateTests {
    private func compoundRule(_ text: String, context: FilterContext = FilterContext()) throws -> FilterRule {
        var parser = try FilterParser(text, context: context); return try parser.parse()
    }
    private func compoundTask(_ id: String, plan: String? = nil, deadline: String? = nil) -> Record {
        Record(["id": .string(id), "title": .string(id), "due_date": plan.map(JSON.string) ?? .null, "deadline_date": deadline.map(JSON.string) ?? .null, "completed": .bool(false)])
    }
    func testCompoundFiltersPersistRelativeExpressionsAndSeparatePlanFromDeadline() throws {
        let context = FilterContext(), rows = [compoundTask("plan", plan: "2026-10-19"), compoundTask("deadline", deadline: "2026-10-19"), compoundTask("both", plan: "2026-10-18", deadline: "2026-10-19"), compoundTask("none")]
        for (text, expected) in [("date:1 week after next week", ["plan"]), ("effective-due:1 week after next week", ["plan", "deadline"]), ("deadline on:1 week after next week", ["deadline", "both"])] {
            let rule = try compoundRule(text)
            XCTAssertEqual(rows.filter { rule.resultMatches($0, context: context, today: "2026-10-08", timeZone: "UTC") }.map(\.id), expected, text)
            XCTAssertEqual(try compoundRule(rule.expression(in: context)), rule)
            XCTAssertEqual(try FilterRule(document: rule.document), rule)
            XCTAssertEqual(rule.captureDefaults(in: context, today: "2026-10-08", timeZone: "UTC")[text.hasPrefix("deadline") ? "deadline_date" : "due_date"], text.hasPrefix("effective") ? nil : .string("2026-10-19"))
        }
        let window = try compoundRule("(date:next week OR date after:next week) AND date before:1 week after next week")
        let days = (11...20).map { compoundTask(String($0), plan: "2026-10-\($0)") }
        XCTAssertEqual(days.filter { window.resultMatches($0, context: context, today: "2026-10-08", timeZone: "UTC") }.map(\.id), (12...18).map(String.init))
    }
    func testCompoundFilterPreferenceBindingsFailClosedAndInvalidateCache() throws {
        let rule = try compoundRule("date:1 week after next week"), cache = TaskCache()
        cache.update([compoundTask("friday", plan: "2026-10-16"), compoundTask("monday", plan: "2026-10-19")])
        var query = TaskQuery(scope: .all, today: "2026-10-08", filter: rule, datePreferences: DatePhrasePreferences(nextWeek: 6), timeZone: "UTC")
        XCTAssertTrue(rule.usesDatePreferences); XCTAssertEqual(cache.matching(query).map(\.id), ["friday"])
        let computations = cache.computationCount; query.datePreferences = DatePhrasePreferences()
        XCTAssertEqual(cache.matching(query).map(\.id), ["monday"]); XCTAssertGreaterThan(cache.computationCount, computations)
        var unavailable = FilterContext(); unavailable.datePreferences = nil
        for value in [rule, .not(rule), .or([.predicate("all", ""), rule])] {
            XCTAssertThrowsError(try value.validate(in: unavailable))
            XCTAssertFalse(value.resultMatches(compoundTask("friday", plan: "2026-10-16"), context: unavailable, today: "2026-10-08", timeZone: "UTC"))
        }
        let independent = FilterRule.sections([rule, .predicate("all", "")])
        XCTAssertTrue(independent.resultMatches(compoundTask("safe"), context: unavailable, today: "2026-10-08", timeZone: "UTC"))
        XCTAssertFalse(try compoundRule("date:1 day after today").usesDatePreferences)
    }
    func testCompoundTimedAndCreationFiltersRetainBoundarySemantics() throws {
        let c = calendar("UTC"), context = FilterContext()
        var row = compoundTask("planned", plan: "2026-10-09"); row["due_time"] = .string("14:00"); row["time_zone"] = .string("UTC"); row["created_at"] = .string("2026-10-07T23:30:00Z")
        XCTAssertTrue(try compoundRule("date:1 day after today at 2pm").resultMatches(row, context: context, today: "2026-10-08", timeZone: c.timeZone.identifier))
        XCTAssertFalse(try compoundRule("date before:1 day after today at 2pm").resultMatches(row, context: context, today: "2026-10-08", timeZone: "UTC"))
        XCTAssertFalse(try compoundRule("date after:1 day after today at 2pm").resultMatches(row, context: context, today: "2026-10-08", timeZone: "UTC"))
        XCTAssertTrue(try compoundRule("created:1 day before today").resultMatches(row, context: context, today: "2026-10-08", timeZone: "UTC"))
        XCTAssertTrue(try compoundRule("created:0 days after today").resultMatches(row, context: context, today: "2026-10-08", timeZone: "Pacific/Auckland"))
        for text in ["date:3651 days after today", "date:1 month after today", "deadline on:1 day after today at 2pm", "date:1 day after next holiday"] { XCTAssertThrowsError(try compoundRule(text), text) }
    }
    func testCompoundWidgetDailyMembershipAndSnapshotWireRoundTrip() throws {
        let c = calendar("UTC"), rows = (8...16).map { compoundTask(String($0), plan: "2026-10-\(String(format: "%02d", $0))") }
        let rule = try compoundRule("date:1 day after today")
        let view = Record(["id": .string("v"), "user_id": .string("owner"), "name": .string("Tomorrow"), "query_ast": rule.document])
        let payload = WidgetProjection.listPayload(tasks: rows, projects: [], labels: [], sections: [], savedViews: [view], account: "owner", now: Dates.parse("2026-10-08", calendar: c)!, calendar: c)
        let days = try XCTUnwrap(payload.first?.object["days"]?.object); XCTAssertEqual(days.count, 8)
        for day in 8...15 { XCTAssertEqual(days["2026-10-\(String(format: "%02d", day))"]?.list.map(\.text), [String(day + 1)]) }
        let encoded = String(data: try JSONEncoder().encode(payload), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("1 day after today")); XCTAssertFalse(encoded.contains("query_ast"))
        var snapshot = Snapshot(); snapshot.tables["tasks"] = rows; snapshot.tables["saved_views"] = [view]; snapshot.pending = [Mutation(table: "saved_views", recordID: view.id, method: "POST", fields: view.fields)]
        let wire = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(wire.tables["saved_views"]?.first?["query_ast"], rule.document); XCTAssertEqual(wire.pending.first?.fields["query_ast"], rule.document); XCTAssertEqual(wire.tables["tasks"], rows)
        let file = try WorkspaceBackup.read(WorkspaceBackup.make(snapshot, account: "owner").data())
        XCTAssertEqual(file.tables["saved_views"]?.first?["query_ast"], rule.document)
    }
}
