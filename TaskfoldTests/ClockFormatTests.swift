import XCTest
@testable import TaskfoldCore

final class ClockFormatTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!; return c }
    private func day() -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12))! }

    func testTwentyFourHourLocalesKeepTheirCycleAndUseAColon() {
        for id in ["en_GB", "da_DK", "de_DE"] {
            XCTAssertEqual(ClockFormat.string(clock: "10:00", on: day(), locale: Locale(identifier: id), calendar: calendar), "10:00", id)
            XCTAssertEqual(ClockFormat.string(clock: "20:51", on: day(), locale: Locale(identifier: id), calendar: calendar), "20:51", id)
            XCTAssertFalse(ClockFormat.usesTwelveHourClock(locale: Locale(identifier: id)), id)
        }
    }
    func testTwelveHourLocalesKeepAmPm() {
        let text = ClockFormat.string(clock: "20:51", on: day(), locale: Locale(identifier: "en_US"), calendar: calendar)!
        XCTAssertTrue(text.hasPrefix("8:51"), text)
        XCTAssertTrue(text.uppercased().contains("PM"), text)
        XCTAssertTrue(ClockFormat.usesTwelveHourClock(locale: Locale(identifier: "en_US")))
    }
    func testFullStopSeparatorBecomesColon() {
        XCTAssertEqual(ClockFormat.normalized("10.00"), "10:00")
        XCTAssertEqual(ClockFormat.normalized("9.05 pm"), "9:05 pm")
        XCTAssertEqual(ClockFormat.normalized("Fri. 10.00"), "Fri. 10:00")
    }
    func testInvalidClocksAreRejected() {
        XCTAssertNil(ClockFormat.string(clock: "", calendar: calendar))
        XCTAssertNil(ClockFormat.string(clock: "25:00", calendar: calendar))
        XCTAssertNil(ClockFormat.string(clock: "10:61", calendar: calendar))
    }
    func testListDetailAndQuickAddShareOneFormat() {
        let locale = Locale(identifier: "da_DK")
        let fromClock = ClockFormat.string(clock: "09:00", on: day(), locale: locale, calendar: calendar)
        let fromHour = ClockFormat.string(hour: 9, minute: 0, on: day(), locale: locale, calendar: calendar)
        XCTAssertEqual(fromClock, fromHour)
        XCTAssertTrue(["09:00", "9:00"].contains(fromClock ?? ""), fromClock ?? "nil")
    }
}
