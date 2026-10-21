import XCTest
@testable import TaskfoldCore

final class ReminderIntervalScheduleTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func testStartsAtAnchorThenUsesElapsedMinutesAndExclusiveBoundary() throws {
        let s = try XCTUnwrap(ReminderIntervalSchedule(start: anchor, everyMinutes: 30))
        XCTAssertEqual(s.dates(after: anchor.addingTimeInterval(-1), limit: 3), [anchor, anchor.addingTimeInterval(1800), anchor.addingTimeInterval(3600)])
        XCTAssertEqual(s.dates(after: anchor, limit: 2), [anchor.addingTimeInterval(1800), anchor.addingTimeInterval(3600)])
        XCTAssertEqual(s.dates(after: anchor.addingTimeInterval(1799.999), limit: 1), [anchor.addingTimeInterval(1800)])
    }
    func testMissedSlotsConsumeCountWithoutCatchUp() throws {
        let s = try XCTUnwrap(ReminderIntervalSchedule(start: anchor, everyMinutes: 5, count: 4))
        XCTAssertEqual(s.dates(after: anchor.addingTimeInterval(600), limit: 60), [anchor.addingTimeInterval(900)])
        XCTAssertTrue(s.dates(after: anchor.addingTimeInterval(900)).isEmpty)
        let single = try XCTUnwrap(ReminderIntervalSchedule(start: anchor, everyMinutes: 5, count: 1))
        XCTAssertEqual(single.dates(after: anchor.addingTimeInterval(-1)), [anchor])
        XCTAssertTrue(single.dates(after: anchor).isEmpty)
    }
    func testEndIsInclusiveAndEarlierOfCountAndEndWins() throws {
        let end = anchor.addingTimeInterval(600)
        let s = try XCTUnwrap(ReminderIntervalSchedule(start: anchor, everyMinutes: 5, count: 10, until: end))
        XCTAssertEqual(s.dates(after: anchor.addingTimeInterval(-1)), [anchor, anchor.addingTimeInterval(300), end])
        let short = try XCTUnwrap(ReminderIntervalSchedule(start: anchor, everyMinutes: 5, count: 2, until: end))
        XCTAssertEqual(short.dates(after: anchor.addingTimeInterval(-1)).count, 2)
        XCTAssertEqual(ReminderIntervalSchedule(start: anchor, everyMinutes: 5, until: anchor)?.dates(after: anchor.addingTimeInterval(-1)), [anchor])
    }
    func testProjectionBudgetAndEmptyRequests() throws {
        let s = try XCTUnwrap(ReminderIntervalSchedule(start: anchor, everyMinutes: 5))
        XCTAssertEqual(s.dates(after: anchor, limit: Int.max).count, 60)
        XCTAssertEqual(s.dates(after: anchor, limit: 3).count, 3)
        XCTAssertTrue(s.dates(after: anchor, limit: 0).isEmpty)
        XCTAssertTrue(s.dates(after: anchor, limit: -1).isEmpty)
    }
    func testValidationDoesNotClampInvalidChoices() {
        for minutes in [Int.min, -1, 0, 1, 4, 10081, Int.max] { XCTAssertNil(ReminderIntervalSchedule(start: anchor, everyMinutes: minutes)) }
        for count in [Int.min, -1, 0, 1000, Int.max] { XCTAssertNil(ReminderIntervalSchedule(start: anchor, everyMinutes: 5, count: count)) }
        XCTAssertNil(ReminderIntervalSchedule(start: anchor, everyMinutes: 5, until: anchor.addingTimeInterval(-1)))
        XCTAssertNotNil(ReminderIntervalSchedule(start: anchor, everyMinutes: 10080, count: 999))
    }
    func testInvalidAndExtremeDateInputsAreBounded() throws {
        for seconds in [Double.nan, Double.infinity, -Double.infinity, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude] {
            let d = Date(timeIntervalSince1970: seconds)
            XCTAssertNil(ReminderIntervalSchedule(start: d, everyMinutes: 5))
            XCTAssertNil(ReminderIntervalSchedule(start: anchor, everyMinutes: 5, until: d))
        }
        let s = try XCTUnwrap(ReminderIntervalSchedule(start: anchor, everyMinutes: 5))
        for seconds in [Double.nan, Double.infinity, -Double.infinity, Double.greatestFiniteMagnitude] {
            XCTAssertTrue(s.dates(after: Date(timeIntervalSince1970: seconds)).isEmpty)
        }
        XCTAssertEqual(s.dates(after: Date(timeIntervalSince1970: -Double.greatestFiniteMagnitude), limit: 1), [anchor])
    }
    func testCalendarDomainEdgesCannotOverflowOrInventYearTenThousand() throws {
        let latest = Date(timeIntervalSince1970: 253_402_300_799.999)
        let s = try XCTUnwrap(ReminderIntervalSchedule(start: latest, everyMinutes: 5))
        XCTAssertEqual(s.dates(after: latest.addingTimeInterval(-1)), [s.start])
        XCTAssertTrue(s.dates(after: latest).isEmpty)
        let earliest = Date(timeIntervalSince1970: -62_135_596_800)
        let ancient = try XCTUnwrap(ReminderIntervalSchedule(start: earliest, everyMinutes: 5))
        XCTAssertEqual(ancient.dates(after: anchor, limit: 2).count, 2)
        XCTAssertNil(ReminderIntervalSchedule(start: earliest.addingTimeInterval(-1), everyMinutes: 5))
        XCTAssertNil(ReminderIntervalSchedule(start: latest.addingTimeInterval(1), everyMinutes: 5))
    }
    func testSpringAndAutumnTransitionsKeepElapsedSpacing() throws {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
        let spring = try XCTUnwrap(ReminderIntervalSchedule(start: date("2026-03-29T00:30:00Z"), everyMinutes: 60))
        let a = spring.dates(after: spring.start.addingTimeInterval(-1), limit: 3)
        XCTAssertEqual(a.map { c.component(.hour, from: $0) }, [1, 3, 4])
        XCTAssertEqual(a[1].timeIntervalSince(a[0]), 3600)
        let fall = try XCTUnwrap(ReminderIntervalSchedule(start: date("2026-10-25T00:30:00Z"), everyMinutes: 60))
        let b = fall.dates(after: fall.start.addingTimeInterval(-1), limit: 3)
        XCTAssertEqual(b.map { c.component(.hour, from: $0) }, [2, 2, 3])
        XCTAssertEqual(Set(b).count, 3)
        XCTAssertEqual(b[1].timeIntervalSince(b[0]), 3600)
    }
    func testTravelOnlyChangesDisplayNotInstantsOrIdentity() throws {
        let s = try XCTUnwrap(ReminderIntervalSchedule(start: anchor, everyMinutes: 45, count: 3))
        let before = s.semanticFields, dates = s.dates(after: anchor.addingTimeInterval(-1))
        var west = Calendar(identifier: .gregorian); west.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var east = west; east.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertNotEqual(west.component(.hour, from: dates[0]), east.component(.hour, from: dates[0]))
        XCTAssertEqual(s.dates(after: anchor.addingTimeInterval(-1)), dates)
        XCTAssertEqual(s.semanticFields, before)
    }
    func testMillisecondCanonicalizationAndSubmillisecondBoundary() throws {
        let s = try XCTUnwrap(ReminderIntervalSchedule(start: anchor.addingTimeInterval(0.1234), everyMinutes: 5))
        XCTAssertEqual(s.start.timeIntervalSince1970, anchor.timeIntervalSince1970 + 0.123, accuracy: 0.0001)
        XCTAssertEqual(s.dates(after: s.start.addingTimeInterval(-0.0001), limit: 1), [s.start])
        XCTAssertEqual(s.dates(after: s.start, limit: 1), [s.start.addingTimeInterval(300)])
        XCTAssertNotEqual(s.semanticFields, ReminderIntervalSchedule(start: s.start, everyMinutes: 6)?.semanticFields)
        XCTAssertNotEqual(s.semanticFields, ReminderIntervalSchedule(start: s.start, everyMinutes: 5, count: 1)?.semanticFields)
        XCTAssertNotEqual(s.semanticFields, ReminderIntervalSchedule(start: s.start, everyMinutes: 5, until: s.start)?.semanticFields)
    }
    func testArithmeticSeekMatchesIndependentEnumeratedSchedule() throws {
        for minutes in [5, 17, 30, 1440, 10080] {
            let all = (0..<80).map { anchor.addingTimeInterval(Double($0 * minutes * 60)) }
            let s = try XCTUnwrap(ReminderIntervalSchedule(start: anchor, everyMinutes: minutes, count: 80))
            for slot in [-1, 0, 1, 25, 78, 79, 100] {
                for fraction in [-0.01, 0, 0.01] {
                    let now = anchor.addingTimeInterval(Double(slot * minutes * 60) + fraction)
                    XCTAssertEqual(s.dates(after: now, limit: 9), Array(all.filter { $0 > now }.prefix(9)))
                }
            }
        }
    }
    func testReceiptRequiresExactSlotAndCurrentLimits() throws {
        let s = try XCTUnwrap(ReminderIntervalSchedule(start: anchor.addingTimeInterval(0.123), everyMinutes: 5, count: 3))
        for value in s.dates(after: anchor.addingTimeInterval(-1)) {
            XCTAssertTrue(s.contains(value))
            XCTAssertFalse(s.contains(value.addingTimeInterval(0.0001)))
            XCTAssertFalse(s.contains(value.addingTimeInterval(-0.0001)))
        }
        XCTAssertFalse(s.contains(s.start.addingTimeInterval(-300)))
        XCTAssertFalse(s.contains(s.start.addingTimeInterval(900)))
        XCTAssertFalse(s.contains(Date(timeIntervalSince1970: .nan)))
        let changed = try XCTUnwrap(ReminderIntervalSchedule(start: s.start, everyMinutes: 5, until: s.start))
        XCTAssertFalse(changed.contains(s.start.addingTimeInterval(300)))
    }
    func testFutureMillisecondNearUpperDateBoundaryIsNotSkipped() throws {
        let s = try XCTUnwrap(ReminderIntervalSchedule(start: Date(timeIntervalSince1970: 253_402_300_799.999), everyMinutes: 5))
        XCTAssertEqual(s.dates(after: s.start.addingTimeInterval(-0.0001), limit: 1), [s.start])
    }

}
