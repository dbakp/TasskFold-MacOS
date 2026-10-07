import XCTest
@testable import TaskfoldCore

final class QuickNaturalClockTests: XCTestCase {
    func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    func calendar(_ zone: String = "Europe/Copenhagen") -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; return c }
    func parse(_ text: String, now: String = "2026-10-07T10:00:00Z", zone: String = "Europe/Copenhagen", task: Record = Record(), disabled: Set<String> = []) -> QuickEntry {
        QuickEntry(text, now: date(now), calendar: calendar(zone), disabled: disabled, task: task)
    }
    func testNaturalPeriodsPreserveExactChipsAndIndependentMetadata() {
        for (phrase, clock) in [("in the morning", "09:00"), ("in the afternoon", "12:00"), ("in the evening", "19:00"), ("morning", "09:00"), ("afternoon", "12:00"), ("evening", "19:00"), ("night", "22:00")] {
            let value = parse("Brief tomorrow " + phrase + " p2 ~25m {2026-10-12} !30mb")
            XCTAssertEqual(value.title, "Brief", phrase); XCTAssertEqual(value.updates["due_date"], .string("2026-10-08"), phrase)
            XCTAssertEqual(value.updates["due_time"], .string(clock), phrase); XCTAssertEqual(value.tokens.first { $0.group == "due_time" }?.text, phrase)
            XCTAssertEqual(value.updates["priority"], .number(2)); XCTAssertEqual(value.updates["duration_minutes"], .number(25)); XCTAssertEqual(value.updates["deadline_date"], .string("2026-10-12")); XCTAssertTrue(value.warnings.isEmpty)
        }
    }
    func testTimeOnlyChoosesTodayUntilPassedThenTomorrowWithHonestChip() {
        for (phrase, expected) in [("9am", "2026-10-08"), ("at midnight", "2026-10-08"), ("in the morning", "2026-10-08"), ("noon", "2026-10-07"), ("6pm", "2026-10-07")] {
            let value = parse("Brief " + phrase)
            XCTAssertEqual(value.title, "Brief"); XCTAssertEqual(value.updates["due_date"], .string(expected), phrase)
            if expected == "2026-10-08" { XCTAssertTrue(value.tokens.first { $0.group == "due_time" }?.label.contains("Tomorrow") == true, phrase) }
        }
        XCTAssertEqual(parse("Brief noon", now: "2026-10-07T10:00:01Z").updates["due_date"], .string("2026-10-08"))
    }
    func testExistingAndExplicitDatesRemainChosenEvenWhenClockHasPassed() {
        for day in ["2026-10-01", "2026-10-07", "2027-05-20"] {
            let task = Record(["due_date": .string(day), "deadline_date": .string("2027-06-01")])
            let value = parse("Brief in the morning", task: task).applying(to: task)
            XCTAssertEqual(value.string("due_date"), day); XCTAssertEqual(value.string("due_time"), "09:00"); XCTAssertEqual(value.string("deadline_date"), "2027-06-01")
        }
        XCTAssertEqual(parse("Brief today 9am").updates["due_date"], .string("2026-10-07"))
        XCTAssertEqual(parse("Brief yesterday in the evening").updates["due_date"], .string("2026-10-06"))
        XCTAssertEqual(parse("Brief every day in the morning").updates["due_date"], .string("2026-10-07"))
    }
    func testTimeOnlyUsesSourceZoneAndGregorianDayAcrossTravel() {
        let task = Record(["time_zone": .string("America/New_York"), "deadline_date": .string("2026-10-15")])
        let value = parse("Brief at 6pm", now: "2026-10-07T22:30:00Z", zone: "Asia/Tokyo", task: task).applying(to: task)
        XCTAssertEqual(value.string("due_date"), "2026-10-08"); XCTAssertEqual(value.string("due_time"), "18:00"); XCTAssertEqual(value.string("deadline_date"), "2026-10-15")
        let future = parse("Brief at 11pm", now: "2026-10-07T22:30:00Z", zone: "Asia/Tokyo", task: task)
        XCTAssertEqual(future.updates["due_date"], .string("2026-10-07"))
        var c = Calendar(identifier: .buddhist); c.timeZone = calendar().timeZone
        XCTAssertEqual(QuickEntry("Brief 9am", now: date("2026-10-07T10:00:00Z"), calendar: c).updates["due_date"], .string("2026-10-08"))
    }
    func testRolloverUsesResolvedDSTInstantAndCalendarDayNotTwentyFourHours() {
        let rows = [
            ("2026-03-29T00:50:00Z", "Europe/Copenhagen", "at 02:30", "2026-03-29"),
            ("2026-03-29T01:00:01Z", "Europe/Copenhagen", "at 02:30", "2026-03-30"),
            ("2026-10-25T01:10:00Z", "Europe/Copenhagen", "at 02:30", "2026-10-26"),
            ("2026-10-03T15:35:00Z", "Australia/Lord_Howe", "at 02:15", "2026-10-05"),
            ("2011-12-30T09:00:00Z", "Pacific/Apia", "at 09:00", "2011-12-31")
        ]
        for (now, zone, phrase, day) in rows { XCTAssertEqual(parse("Brief " + phrase, now: now, zone: zone).updates["due_date"], .string(day), zone + now) }
    }
    func testDeclinedQuotedEscapedAndAmbiguousPeriodsRemainLiteral() {
        for phrase in ["in the morning", "evening", "night"] {
            let value = parse("Brief " + phrase, disabled: ["due_time"])
            XCTAssertEqual(value.title, "Brief " + phrase); XCTAssertTrue(value.updates.isEmpty); XCTAssertTrue(value.warnings.isEmpty)
        }
        for input in [#"Brief "in the morning""#, #"Brief \in the evening"#, "Brief https://site.test/morning", "Brief morningish"] { XCTAssertTrue(parse(input).updates.isEmpty, input) }
        for input in ["Brief in the morning at 3pm", "Brief evening in 2 hours"] {
            let value = parse(input + " p2"); XCTAssertEqual(value.title, input); XCTAssertNil(value.updates["due_time"]); XCTAssertNil(value.updates["due_date"]); XCTAssertEqual(value.updates["priority"], .number(2)); XCTAssertEqual(value.warnings.count, 1)
        }
    }
    func testPeriodSuggestionsUseRealParserAndRetainFollowingProse() throws {
        for (input, phrase, clock) in [("Brief tomorrow in the mor", "in the morning", "09:00"), ("Brief even", "evening", "19:00"), ("Brief in the aft", "in the afternoon", "12:00")] {
            let menu = QuickPlanningCompletion(input, now: date("2026-10-07T10:00:00Z"), calendar: calendar())
            let option = try XCTUnwrap(menu.options.first { $0.reference == phrase }, input)
            let chosen = try XCTUnwrap(menu.choosing(option, in: input));let value = parse(chosen.text)
            XCTAssertEqual(value.title, "Brief");XCTAssertEqual(value.updates["due_time"], .string(clock))
        }
        XCTAssertTrue(QuickPlanningCompletion("Brief ev", now: date("2026-10-07T10:00:00Z"), calendar: calendar()).options.contains { $0.reference == "every day" })
        let input = "Brief in the morning with Alex", caret = "Brief in the mor".utf16.count
        let menu = QuickPlanningCompletion(input, caretUTF16: caret, now: date("2026-10-07T10:00:00Z"), calendar: calendar())
        let chosen = try XCTUnwrap(menu.choosing(try XCTUnwrap(menu.options.first { $0.reference == "in the morning" }), in: input))
        XCTAssertEqual(parse(chosen.text).title, "Brief with Alex")
    }
    func testPeriodReminderClocksRemainIndependentOfTaskPlanning() throws {
        for (text, hour) in [("!tomorrow morning", 9), ("!tomorrow evening", 19), ("!every day afternoon", 12)] {
            let value = parse("Brief " + text)
            XCTAssertEqual(value.title, "Brief");XCTAssertNil(value.updates["due_date"]);XCTAssertNil(value.updates["due_time"])
            let spec = try XCTUnwrap(value.updates["reminder_specs"]?.list.compactMap(ReminderSpec.init(row:)).first { $0.id != ReminderSpec.plannedID })
            if text.hasPrefix("!every") { XCTAssertEqual(spec.schedule?.time, "12:00") }
            else { XCTAssertEqual(calendar().component(.hour, from: try XCTUnwrap(spec.absolute)), hour) }
        }
    }
}
