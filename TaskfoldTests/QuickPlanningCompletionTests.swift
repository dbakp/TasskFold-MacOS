import XCTest
@testable import TaskfoldCore

final class QuickPlanningCompletionTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!; return c }
    var now: Date { ISO8601DateFormatter().date(from: "2026-10-06T10:00:00Z")! }
    func menu(_ text: String, caret: Int? = nil, task: Record = Record()) -> QuickPlanningCompletion { QuickPlanningCompletion(text, caretUTF16: caret, now: now, calendar: calendar, task: task) }
    func choose(_ text: String, phrase: String, task: Record = Record()) throws -> QuickEntry {
        let result = menu(text, task: task)
        let option = try XCTUnwrap(result.options.first { $0.reference == phrase }, text + " → " + result.options.map(\.reference).joined(separator: ", "))
        let chosen = try XCTUnwrap(result.choosing(option, in: text))
        return QuickEntry(chosen.text, now: now, calendar: calendar, task: task)
    }
    func testPlanningSuggestionUsesResolvedDirectoryContext() throws {
        let project = Record(["id": .string("work"), "name": .string("Client Work")])
        let section = Record(["id": .string("ready"), "name": .string("Ready"), "project_id": .string("work")])
        let context = QuickEntryContext(projects: [project], sections: [section])
        let input = #"Review #"Client Work" /"Ready" tomorrow at 09:00 !30mb"#
        let menu = QuickEntryCompletion(input, now: now, calendar: calendar, context: context)
        let option = try XCTUnwrap(menu.options.first { $0.reference == "!30mb" })
        XCTAssertEqual(option.detail, "!30mb")
        let chosen = try XCTUnwrap(menu.choosing(option, in: input))
        let parsed = QuickEntry(chosen.text, now: now, calendar: calendar, context: context)
        XCTAssertEqual(parsed.updates["section_id"], .string("ready"))
        XCTAssertFalse(parsed.warnings.contains { $0.contains("Choose a section") })

        let unresolved = QuickEntryCompletion(#"Review #"Client Work" /"Unknown" tomorrow at 09:00 !30mb"#, now: now, calendar: calendar, context: context)
        XCTAssertTrue(try XCTUnwrap(unresolved.options.first { $0.reference == "!30mb" }).detail.contains("Choose a section"))
    }

    func testDatePreviewsMatchSavedCalendarDates() throws {
        let result = try choose("Call tom", phrase: "tomorrow")
        XCTAssertEqual(result.title, "Call"); XCTAssertEqual(result.updates["due_date"], .string("2026-10-07"))
        XCTAssertEqual(menu("Call mon").options.map(\.reference), ["monday"])
        XCTAssertEqual(Set(menu("Call next ").options.map(\.reference)), Set(["next week", "next weekend", "next month", "next year", "next monday", "next tuesday", "next wednesday", "next thursday", "next friday", "next saturday", "next sunday"]))
        XCTAssertEqual(try choose("Call next wed", phrase: "next wednesday").updates["due_date"], .string("2026-10-07"))
    }
    func testRelativeDateIntervalsAndTimeChoicesUseParser() throws {
        let value = try choose("Call in 2 h", phrase: "in 2 hours")
        XCTAssertEqual(value.updates["due_time"], .string("14:00")); XCTAssertEqual(value.updates["due_date"], .string("2026-10-06"))
        XCTAssertEqual(try choose("Call at 9", phrase: "at 9am").updates["due_time"], .string("09:00"))
        XCTAssertTrue(menu("Call in 999999 days").options.isEmpty)
    }
    func testRepeatTemplatesAndIntervalsHaveTrueRulePreviews() throws {
        let value = try choose("Review every 2 w", phrase: "every 2 weeks")
        XCTAssertEqual(value.updates["recurrence_pattern"]?.object["type"], .string("weekly")); XCTAssertEqual(value.updates["recurrence_pattern"]?.object["interval"], .number(2))
        let ordinal = try choose("Review every month on last f", phrase: "every month on last friday")
        XCTAssertEqual(ordinal.updates["recurrence_pattern"]?.object["weekdayOrdinal"], .number(-1))
        XCTAssertEqual(try choose("Review every! w", phrase: "every! weekdays").updates["recurrence_pattern"]?.object["fromCompletion"], .bool(true))
        XCTAssertFalse(menu("Review ev").options.isEmpty)
    }
    func testReminderAbsoluteBeforeAfterAndWarnings() throws {
        for phrase in ["!30m", "!30mb", "!30ma"] {
            let value = try choose("Call !30", phrase: phrase)
            let spec = try XCTUnwrap(value.updates["reminder_specs"]?.list.compactMap(ReminderSpec.init(row:)).first { $0.id != ReminderSpec.plannedID })
            if phrase == "!30m" { XCTAssertEqual(spec.absolute, now.addingTimeInterval(1800)) }
            else { XCTAssertEqual(spec.offset, phrase == "!30mb" ? -30 : 30); XCTAssertTrue(value.warnings.contains { $0.contains("planned date") }) }
        }
        XCTAssertTrue(menu("Call !30").options.first { $0.reference == "!30mb" }?.detail.contains("planned date") == true)
        XCTAssertEqual(try choose("Call !tom", phrase: "!tomorrow 9am").title, "Call")
        XCTAssertTrue(menu("Call !10081").options.isEmpty)
    }
    func testReminderDuplicatesAndCapacityAreNotOffered() {
        var task = Record.task(user: "owner"); task["reminder_specs"] = .array([.object(ReminderSpec.relative(-30).raw)])
        XCTAssertFalse(menu("Call !30", task: task).options.contains { $0.reference == "!30mb" })
        task["reminder_specs"] = .array((0..<20).map { .object(ReminderSpec.relative($0).raw) })
        XCTAssertTrue(menu("Call !", task: task).options.isEmpty)
    }
    func testPlanningMenuDoesNotHijackLiteralReferencesAndProse() {
        for input in ["Review ordinary", "Review tomato", "https://site.test/tom", "name@tom", "path/tom", "Review \\tom", "Review \"tom", "Review @\"every mo", "Review #project:\"every mo", "Review \\#\"every mo", "Review everything", "Review someone", "2+tom"] {
            XCTAssertNil(menu(input).range, input)
        }
    }
    func testCompletedChoiceAndOrdinaryWhitespaceCloseMenu() throws {
        for value in ["tomorrow", "every day", "!30mb", "next monday", "at 9am"] {
            XCTAssertNil(menu("Call " + value + " ").range, value)
        }
        let option = try XCTUnwrap(menu("Call tom").options.first)
        let chosen = try XCTUnwrap(menu("Call tom").choosing(option, in: "Call tom"))
        XCTAssertNil(menu(chosen.text).range)
    }
    func testUnicodeMiddleCursorPreservesLaterTitleAndMetadata() throws {
        let input = "☎️ Call tomorrow p1 #project:\"Work\""
        let caret = (input as NSString).range(of: "tom").location + 3
        let result = menu(input, caret: caret)
        let option = try XCTUnwrap(result.options.first { $0.reference == "tomorrow" })
        let chosen = try XCTUnwrap(result.choosing(option, in: input))
        XCTAssertEqual(chosen.text, input); XCTAssertEqual((chosen.text as NSString).substring(from: chosen.caretUTF16), " p1 #project:\"Work\"")
        XCTAssertNil(result.choosing(option, in: "Changed tom"))
        XCTAssertNil(menu(input, caret: -1).range); XCTAssertNil(menu("😀 tom", caret: 1).range)
    }
    func testExistingRepeatLimitAndReminderClockAreNeverOverwritten() {
        let input = "Review every monday starting 2027-01-01 for 3 occurrences p1"
        XCTAssertNil(menu(input, caret: (input as NSString).range(of: "mon").location + 3).range)
        let reminder = "Call !tomorrow 3pm p1"
        XCTAssertNil(menu(reminder, caret: (reminder as NSString).range(of: "tom").location + 3).range)
    }
    func testKeepLiteralAndExplicitChoiceReenabling() throws {
        for (input, group) in [("Call tomorrow", "due_date"), ("Call every day", "recurrence"), ("Call !30mb", "reminder_specs")] {
            let active = menu(input)
            XCTAssertTrue(active.literalGroups.contains { $0 == group || $0.hasPrefix(group + ":") })
            let kept = QuickEntry(input, now: now, calendar: calendar, disabled: active.literalGroups)
            XCTAssertEqual(kept.title, input); XCTAssertTrue(kept.updates.isEmpty)
            let offered = QuickPlanningCompletion(input, now: now, calendar: calendar, disabled: [group])
            XCTAssertFalse(offered.options.isEmpty)
        }
    }
    func testInheritedPlanControlsRepeatStartAndReminderPreview() throws {
        var task = Record.task(user: "owner"); task["due_date"] = .string("2027-05-20")
        let result = menu("Review every d", task: task)
        XCTAssertTrue(result.options.first { $0.reference == "every day" }?.detail.contains("2027-05-20") == true)
        XCTAssertEqual(try choose("Review every d", phrase: "every day", task: task).updates["due_date"], .string("2027-05-20"))
        XCTAssertFalse(menu("Review !30", task: task).options.first { $0.reference == "!30mb" }?.detail.contains("wait") == true)
    }
    func testKeepOneCompleteReminderPreservesOtherAcceptedReminder() {
        let input = "Call !15mb !30mb"
        let active = menu(input)
        XCTAssertEqual(active.literalGroups.count, 1)
        XCTAssertFalse(active.literalGroups.contains("reminder_specs"))
        let parsed = QuickEntry(input, now: now, calendar: calendar, disabled: active.literalGroups)
        XCTAssertEqual(parsed.title, "Call !30mb")
        let settings = parsed.updates["reminder_specs"]?.list.compactMap(ReminderSpec.init(row:)) ?? []
        XCTAssertTrue(settings.contains { $0.offset == -15 }); XCTAssertFalse(settings.contains { $0.offset == -30 })
    }
    func testTimeOnlyChoicePreservesExistingFutureDateAndDeadline() throws {
        var task = Record.task(user: "owner"); task["due_date"] = .string("2027-05-20"); task["deadline_date"] = .string("2027-05-25")
        let value = try choose("Call at 9", phrase: "at 9am", task: task).applying(to: task)
        XCTAssertEqual(value.string("due_date"), "2027-05-20"); XCTAssertEqual(value.string("due_time"), "09:00"); XCTAssertEqual(value.string("deadline_date"), "2027-05-25")
        XCTAssertTrue(menu("Call at 9", task: task).options.first { $0.reference == "at 9am" }?.detail.contains("2027-05-20") == true)
    }
    func testTimeWithoutPlanUsesInjectedCalendarDayAndRollover() throws {
        var c = calendar; c.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        let date = ISO8601DateFormatter().date(from: "2026-10-06T23:30:00Z")!
        var task = Record.task(user: "owner"); task["due_date"] = .string("invalid")
        let value = QuickEntry("Call at 9am", now: date, calendar: c, task: task)
        XCTAssertEqual(value.updates["due_date"], .string("2026-10-08"))
        XCTAssertEqual(QuickEntry("Call at 1pm", now: date, calendar: c, task: task).updates["due_date"], .string("2026-10-07"))
    }
    func testOtherClockHoursAndHalfHoursAreAvailable() throws {
        XCTAssertEqual(try choose("Call at 1", phrase: "at 1pm").updates["due_time"], .string("13:00"))
        XCTAssertEqual(try choose("Call at 17:", phrase: "at 17:30").updates["due_time"], .string("17:30"))
        XCTAssertNil(menu("Call at 25").range)
    }
    func testKeepPartialReminderDoesNotDisableEarlierChoice() {
        let input = "Call !15mb !30"
        let active = menu(input); XCTAssertFalse(active.options.isEmpty); XCTAssertTrue(active.literalGroups.isEmpty)
        let parsed = QuickEntry(input, now: now, calendar: calendar, disabled: active.literalGroups)
        XCTAssertEqual(parsed.title, "Call !30")
        XCTAssertTrue(parsed.updates["reminder_specs"]?.list.compactMap(ReminderSpec.init(row:)).contains { $0.offset == -15 } == true)
    }
    func testUnifiedMenuPrefersDirectoryAndKeepsPlanningChoicesSeparate() throws {
        let c = QuickEntryContext(labels: [Record(["id": .string("tom"), "name": .string("Tomorrow")])])
        let directory = QuickEntryCompletion("Call @tom", context: c)
        XCTAssertEqual(directory.options.first?.group, "labels")
        let planning = QuickEntryCompletion("Call tom", now: now, calendar: calendar, context: c)
        XCTAssertEqual(planning.options.first?.group, "due_date")
        XCTAssertEqual(planning.options.first?.reference, "tomorrow")
    }
}

extension QuickPlanningCompletionTests {
    func testCompoundPlanningChoicePreviewsTheWholePhraseAndRetainsLaterText() throws {
        let input = "☎️ Review 1 week after next we p2"
        let caret = (input as NSString).range(of: "next we").location + "next we".utf16.count
        let result = menu(input, caret: caret)
        let option = try XCTUnwrap(result.options.first { $0.reference == "1 week after next week" })
        let chosen = try XCTUnwrap(result.choosing(option, in: input))
        XCTAssertEqual(chosen.text, "☎️ Review 1 week after next week p2")
        let parsed = QuickEntry(chosen.text, now: now, calendar: calendar)
        XCTAssertEqual(parsed.title, "☎️ Review"); XCTAssertEqual(parsed.updates["due_date"], .string("2026-10-19")); XCTAssertEqual(parsed.updates["priority"], .number(2))
        XCTAssertEqual(result.literalGroups, ["due_date"])
        for text in ["Review 3651 days after next we", "Review 522 weeks after next we", "Review \\1 week after next we", "Review \"1 week after next we"] { XCTAssertTrue(menu(text).options.isEmpty, text) }
        let missing = QuickPlanningCompletion("Review 1 week after next we", now: now, calendar: calendar, context: QuickEntryContext(datePreferences: nil))
        XCTAssertFalse(missing.options.contains { QuickNaturalDateText.usesDatePreferences($0.reference) })
        XCTAssertTrue(missing.options.contains { $0.reference == "1 week after next wednesday" }, "Independent weekday anchors remain usable without date preferences")
    }
}
