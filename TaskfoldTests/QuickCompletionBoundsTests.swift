import XCTest
@testable import TaskfoldCore

/// Typing "at" used to parse about eighty phrases on every keystroke. These tests bound that work and keep the
/// options people use, and cover saved-place suggestions (names are memory-only context, never a task field).
final class QuickCompletionBoundsTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!; return c }
    var now: Date { ISO8601DateFormatter().date(from: "2026-10-06T10:00:00Z")! }
    func planning(_ text: String, places: [String] = []) -> QuickPlanningCompletion {
        QuickPlanningCompletion(text, now: now, calendar: calendar, context: QuickEntryContext(places: places))
    }

    // MARK: Bounded work

    func testEveryHotFragmentParsesAtMostTenTimesAndShowsAtMostEightOptions() {
        for input in ["Buy milk at", "Buy milk at ", "Buy milk at 1", "Buy milk at 0", "Review every ", "Review every 2 ", "Call !", "Call !1", "Call !every ", "Call in the ", "Call 3 days after "] {
            let result = planning(input)
            XCTAssertLessThanOrEqual(result.parseCount, 10, input)
            XCTAssertLessThanOrEqual(result.options.count, QuickPlanningCompletion.optionLimit, input)
        }
        // Eleven date phrases share the prefix "next ", so that group may show more, still within one spare parse.
        let next = planning("Call next ")
        XCTAssertLessThanOrEqual(next.parseCount, QuickPlanningCompletion.dateOptionLimit + 2); XCTAssertEqual(next.options.count, 11)
    }
    func testNoParseRunsWhenNothingMatchesTheTypedPrefix() {
        for input in ["Call at zzz", "Call at 25", "Call every xyz", "Call !zzz"] { XCTAssertEqual(planning(input).parseCount, 0, input) }
    }
    func testAtStillOffersTheUsualTimesFirstAndChoosingOneWorks() throws {
        let result = planning("Buy milk at")
        let phrases = result.options.map(\.reference)
        XCTAssertEqual(Array(phrases.prefix(3)), ["at 9am", "at noon", "at 3pm"])
        XCTAssertEqual(phrases.count, QuickPlanningCompletion.optionLimit)
        for option in result.options {
            let chosen = try XCTUnwrap(result.choosing(option, in: "Buy milk at"))
            let parsed = QuickEntry(chosen.text, now: now, calendar: calendar)
            XCTAssertEqual(parsed.title, "Buy milk", option.reference)
            XCTAssertNotNil(parsed.updates["due_time"], option.reference)
        }
        let nine = try XCTUnwrap(planning("Buy milk at").options.first { $0.reference == "at 9am" })
        XCTAssertEqual(try XCTUnwrap(planning("Buy milk at").choosing(nine, in: "Buy milk at")).text, "Buy milk at 9am ")
        XCTAssertTrue(planning("Buy milk at 1").options.contains { $0.reference == "at 1pm" })
        XCTAssertTrue(planning("Buy milk at 17:").options.contains { $0.reference == "at 17:30" })
    }
    func testAtCompletionStaysWellUnderTheKeystrokeBudget() {
        let input = "Buy milk at"
        _ = QuickEntryCompletion(input, now: now, calendar: calendar) // warm the regex caches
        let runs = 20, start = Date()
        for _ in 0..<runs { _ = QuickEntryCompletion(input, now: now, calendar: calendar) }
        let average = Date().timeIntervalSince(start) / Double(runs)
        print("TIMING \(input) options=\(QuickEntryCompletion(input, now: now, calendar: calendar).options.count) ms=\(average * 1000)")
        // 20 ms in an optimised build. Debug test builds run these regex parses roughly an order of magnitude slower.
        #if DEBUG
        let budget = 0.25
        #else
        let budget = 0.02
        #endif
        XCTAssertLessThan(average, budget, "QuickEntryCompletion(\"at\") averaged \(average * 1000) ms")
    }

    // MARK: Saved places

    func testSavedPlaceOptionsComeFirstAndTimesStayAvailable() throws {
        let places = ["Home", "Gym"]
        let result = planning("Call mum at Ho", places: places)
        XCTAssertEqual(result.options.map(\.name), ["Arrive at Home", "Leave Home"])
        XCTAssertEqual(result.options.map(\.reference), ["at Home", "leave Home"])
        XCTAssertEqual(result.literalGroups, ["place"])
        XCTAssertEqual(planning("Call mum at Ho").options.count, 0, "no saved places, nothing new")
        // Times still come after a place when both match the same words.
        let both = planning("Call mum at no", places: ["Nora's Cafe"])
        XCTAssertEqual(both.options.map(\.name).prefix(2), ["Arrive at Nora's Cafe", "Leave Nora's Cafe"])
        XCTAssertTrue(both.options.contains { $0.reference == "at noon" })
        // Times are still offered for "at 9", and for a bare "at" even when places exist.
        let nine = planning("Call mum at 9", places: places)
        XCTAssertEqual(nine.options.map(\.reference), ["at 9am", "at 9pm"])
        let bare = planning("Call mum at", places: places)
        XCTAssertTrue(bare.options.allSatisfy { $0.group == "due_time" }); XCTAssertEqual(bare.options.first?.reference, "at 9am")
    }
    func testUnknownWordsOfferNoPlaceAndNoTime() {
        XCTAssertNil(planning("Call mum at Zed", places: ["Home"]).range)
        XCTAssertNil(planning("Call mum at home", places: []).range)
        XCTAssertEqual(planning("Call mum at home", places: []).parseCount, 0)
        XCTAssertNil(planning("Call at Home ", places: ["Home"]).range, "a finished name closes the menu")
    }
    func testChoosingAPlaceRemovesItFromTheTitleAndKeepsItOutOfEveryField() throws {
        let places = ["Home", "Home Depot"]
        let result = planning("Call mum at Ho", places: places)
        XCTAssertEqual(result.options.map(\.name), ["Arrive at Home", "Leave Home", "Arrive at Home Depot", "Leave Home Depot"])
        let arrive = try XCTUnwrap(result.options.first { $0.name == "Arrive at Home" })
        let chosen = try XCTUnwrap(result.choosing(arrive, in: "Call mum at Ho"))
        XCTAssertEqual(chosen.text, "Call mum at Home ")
        let found = try XCTUnwrap(QuickEntry.place(in: QuickEntry(chosen.text, now: now, calendar: calendar).title, names: places))
        XCTAssertEqual(found.title, "Call mum"); XCTAssertEqual(found.choice, .init(name: "Home", transition: .arrive)); XCTAssertEqual(found.raw, "at Home")
        let parsed = QuickEntry(chosen.text, now: now, calendar: calendar, context: QuickEntryContext(places: places))
        XCTAssertTrue(parsed.updates.isEmpty, "a place is never a task field"); XCTAssertEqual(parsed.tokens, [])
        // Leave, and a longer name beats a shorter one that starts it.
        let leave = try XCTUnwrap(result.options.first { $0.name == "Leave Home Depot" })
        let text = try XCTUnwrap(result.choosing(leave, in: "Call mum at Ho")).text
        XCTAssertEqual(text, "Call mum leave Home Depot ")
        let second = try XCTUnwrap(QuickEntry.place(in: text, names: places))
        XCTAssertEqual(second.choice, .init(name: "Home Depot", transition: .leave)); XCTAssertEqual(second.title, "Call mum")
    }
    func testArriveAndLeaveTriggersOfferOnlyTheirOwnDirection() {
        XCTAssertEqual(planning("Pack and leave Ho", places: ["Home"]).options.map(\.name), ["Leave Home"])
        XCTAssertEqual(planning("Pack and leave at Ho", places: ["Home"]).options.map(\.reference), ["leave at Home"])
        XCTAssertEqual(planning("Text when I arrive at Ho", places: ["Home"]).options.map(\.name), ["Arrive at Home"])
        XCTAssertEqual(planning("Text arrive Ho", places: ["Home"]).options.map(\.reference), ["arrive Home"])
    }
    func testPlaceInsideQuotesLinksOrEscapesIsLeftAlone() {
        for input in [#"Read "notes at Ho"#, "See https://a.test/at Ho", #"Call \at Ho"#, "Call a/at Ho", "Mail me@at Ho"] {
            XCTAssertNil(planning(input, places: ["Home"]).range, input)
        }
        XCTAssertNil(QuickEntry.place(in: #"Read "at Home" now"#, names: ["Home"]))
        XCTAssertNil(QuickEntry.place(in: "Buy at Home Depot", names: ["Hom"]))
        XCTAssertEqual(QuickEntry.place(in: "Buy at Home Depot", names: ["Home", "Home Depot"])?.choice.name, "Home Depot")
        XCTAssertEqual(QuickEntry.place(in: "Buy AT home", names: ["Home"])?.title, "Buy")
    }
    func testNoSavedPlacesAddsNoCostAndNoOptions() {
        let start = Date()
        for input in ["Call at home", "Call at hom", "Call leave home", "Call arrive at h"] { XCTAssertNil(planning(input).range, input) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertNil(QuickEntry.place(in: "Call at home", names: []))
    }
    func testPlaceOptionsSurviveTheCombinedMenuAndDecliningTheGroup() throws {
        let context = QuickEntryContext(places: ["Home"])
        let menu = QuickEntryCompletion("Call mum at Ho", now: now, calendar: calendar, context: context)
        XCTAssertEqual(menu.options.map(\.name), ["Arrive at Home", "Leave Home"])
        XCTAssertEqual(menu.literalGroups, ["place"])
        XCTAssertTrue(QuickEntryCompletion("Call mum at Ho", now: now, calendar: calendar, context: context, disabled: ["place"]).options.isEmpty)
        let chosen = try XCTUnwrap(menu.choosing(menu.options[1], in: "Call mum at Ho"))
        XCTAssertEqual(chosen.text, "Call mum leave Home "); XCTAssertEqual(chosen.caretUTF16, chosen.text.utf16.count)
    }
}
