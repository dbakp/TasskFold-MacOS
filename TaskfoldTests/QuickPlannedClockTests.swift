import XCTest
@testable import TaskfoldCore

final class QuickPlannedClockTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!; return c }
    var now: Date { ISO8601DateFormatter().date(from: "2026-10-07T10:00:00Z")! }
    func parse(_ value: String, disabled: Set<String> = [], task: Record = Record()) -> QuickEntry { QuickEntry(value, now: now, calendar: calendar, disabled: disabled, task: task) }
    func testInvalidWholeClocksNeverBecomeAPlanOrPartialClock() {
        for clock in ["13pm", "0am", "24:00", "9:60", "at 25", "at 13pm", "at 0am", "at 12:00:30", "at 9:5", "123pm", "9.61", "at 99999999999999999999999"] {
            let value = parse("Call " + clock)
            XCTAssertEqual(value.title, "Call " + clock, clock)
            XCTAssertNil(value.updates["due_time"], clock); XCTAssertNil(value.updates["due_date"], clock)
            XCTAssertTrue(value.warnings.contains { $0.contains("valid planned time") }, clock)
        }
    }
    func testNoonMidnightAndNumericBoundaryClocksUseOneCanonicalMinute() {
        for (clock, expected) in [("noon", "12:00"), ("at midnight", "00:00"), ("12am", "00:00"), ("12 pm", "12:00"), ("1pm", "13:00"), ("23:59", "23:59"), ("at 0", "00:00"), ("9.30am", "09:30")] {
            let value = parse("Call tomorrow " + clock)
            XCTAssertEqual(value.title, "Call"); XCTAssertEqual(value.updates["due_time"], .string(expected)); XCTAssertEqual(value.updates["due_date"], .string("2026-10-08")); XCTAssertTrue(value.warnings.isEmpty, clock)
        }
        XCTAssertEqual(parse("Call at noon.").title, "Call .")
    }
    func testMultipleClocksAreLiteralRatherThanSilentlyChoosingOne() {
        let value = parse("Call tomorrow at noon or 3pm p2")
        XCTAssertEqual(value.title, "Call at noon or 3pm"); XCTAssertNil(value.updates["due_time"])
        XCTAssertEqual(value.updates["due_date"], .string("2026-10-08")); XCTAssertEqual(value.updates["priority"], .number(2))
        XCTAssertEqual(value.warnings.filter { $0.contains("Choose one planned time") }.count, 1)
    }
    func testDeclineEscapesReferencesAndInvalidTimeKeepIndependentMetadata() {
        let kept = parse("Discuss tomorrow at midnight", disabled: ["due_time"])
        XCTAssertEqual(kept.title, "Discuss at midnight"); XCTAssertNil(kept.updates["due_time"]); XCTAssertTrue(kept.warnings.isEmpty)
        for value in [#"Discuss "at noon tomorrow""#, #"Discuss \midnight"#, "Discuss https://site.test/9am", "Discuss 9am.com", "Discuss 9amish"] { XCTAssertTrue(parse(value).updates.isEmpty, value) }
        let invalid = parse("Call tomorrow 13pm !30mb ~25m {2026-10-12}")
        XCTAssertEqual(invalid.title, "Call 13pm"); XCTAssertNil(invalid.updates["due_time"])
        XCTAssertEqual(invalid.updates["due_date"], .string("2026-10-08")); XCTAssertEqual(invalid.updates["deadline_date"], .string("2026-10-12")); XCTAssertEqual(invalid.updates["duration_minutes"], .number(25))
        XCTAssertTrue(invalid.updates["reminder_specs"]?.list.compactMap(ReminderSpec.init(row:)).contains { $0.offset == -30 } == true)
    }
    func testClockOnlyPreservesPlanDeadlineAndRepeatUsesAcceptedClock() {
        var task = Record.task(user: "owner"); task["due_date"] = .string("2027-05-20"); task["deadline_date"] = .string("2027-05-25")
        let value = parse("Call at midnight", task: task).applying(to: task)
        XCTAssertEqual(value.string("due_date"), "2027-05-20"); XCTAssertEqual(value.string("due_time"), "00:00"); XCTAssertEqual(value.string("deadline_date"), "2027-05-25")
        let repeatValue = parse("Review every day at noon !30mb")
        XCTAssertEqual(repeatValue.title, "Review"); XCTAssertEqual(repeatValue.updates["due_time"], .string("12:00")); XCTAssertEqual(repeatValue.updates["is_recurring"], .bool(true)); XCTAssertTrue(repeatValue.updates["reminder_specs"]?.list.compactMap(ReminderSpec.init(row:)).contains { $0.offset == -30 } == true)
    }
    func testNoonMidnightSuggestionsAndDeclinedChoiceUseActualParser() throws {
        for phrase in ["at noon", "at midnight"] {
            let input = "Call " + String(phrase.dropLast(2))
            let menu = QuickPlanningCompletion(input, now: now, calendar: calendar)
            let option = try XCTUnwrap(menu.options.first { $0.reference == phrase })
            let selected = try XCTUnwrap(menu.choosing(option, in: input))
            let parsed = parse(selected.text)
            XCTAssertEqual(parsed.title, "Call"); XCTAssertEqual(parsed.updates["due_time"], .string(phrase == "at noon" ? "12:00" : "00:00"))
            let kept = parse(selected.text, disabled: ["due_time"]); XCTAssertEqual(kept.title, "Call " + phrase); XCTAssertTrue(kept.updates.isEmpty)
        }
        XCTAssertNil(QuickPlanningCompletion("Call at 13pm", now: now, calendar: calendar).range)
    }
    func testElapsedAndExplicitClocksCannotOverwriteTheirOwnChips() {
        for input in ["Call at noon in 2 hours", "Call in 2 hours or in 3 hours"] {
            let value = parse(input)
            XCTAssertEqual(value.title, input); XCTAssertNil(value.updates["due_date"]); XCTAssertNil(value.updates["due_time"])
            XCTAssertEqual(value.warnings.filter { $0.contains("Choose one planned time") }.count, 1)
        }
        let normal = parse("Call in 2 hours"); XCTAssertEqual(normal.updates["due_time"], .string("14:00"))
        let declined = parse("Call at noon in 2 hours", disabled: ["due_time"])
        XCTAssertEqual(declined.title, "Call at noon"); XCTAssertEqual(declined.updates["due_time"], .string("14:00")); XCTAssertTrue(declined.warnings.isEmpty)
    }
    func testReminderNoonMidnightClocksRemainIndependentFromTaskPlan() throws {
        for input in ["!tomorrow noon", "!midnight", "!every day noon"] {
            let value = parse("Call " + input)
            XCTAssertEqual(value.title, "Call"); XCTAssertNil(value.updates["due_date"]); XCTAssertNil(value.updates["due_time"])
            let spec = try XCTUnwrap(value.updates["reminder_specs"]?.list.compactMap(ReminderSpec.init(row:)).first { $0.id != ReminderSpec.plannedID })
            if input.hasPrefix("!every") { XCTAssertEqual(spec.schedule?.time, "12:00") }
            else { XCTAssertEqual(spec.absolute, ISO8601DateFormatter().date(from: input == "!midnight" ? "2026-10-07T22:00:00Z" : "2026-10-08T10:00:00Z")) }
        }
        for input in ["!tomorrow 13pm", "!tomorrow 12:00:30", "!every day 0am"] {
            let value = parse("Call " + input); XCTAssertEqual(value.title, "Call " + input)
            XCTAssertNil(value.updates["reminder_specs"]); XCTAssertNil(value.updates["due_time"]); XCTAssertNil(value.updates["due_date"])
        }
    }

}
