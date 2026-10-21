import XCTest
@testable import TaskfoldCore

final class ReminderTravelTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func zone(_ id: String) -> TimeZone { TimeZone(identifier: id)! }
    private func key(_ date: Date, _ id: String) -> String { var c = Calendar(identifier: .gregorian); c.timeZone = zone(id); return TaskPlanner.dayKey(date, calendar: c) }
    private func hours(_ rows: [ReminderClockPreview.Row], _ id: String) -> [Int] { var c = Calendar(identifier: .gregorian); c.timeZone = zone(id); return rows.map { c.component(.hour, from: $0.instant) } }
    private func schedule(_ source: String = "America/New_York", start: String = "2026-10-24") throws -> ReminderCalendarSchedule {
        try XCTUnwrap(ReminderCalendarSchedule.make("every day for 5 occurrences", time: "09:00", start: start, zone: source))
    }
    func testSearchableNamedChoicesIncludeSupportedSelectionAndNormalizeCitySpaces() {
        let choices = ReminderTimeZones.choices(including: "UTC")
        XCTAssertEqual(choices, Array(Set(choices)).sorted()); XCTAssertTrue(choices.contains("UTC"))
        XCTAssertTrue(ReminderTimeZones.choices(including: "UTC", query: "new york").contains("America/New_York"))
        XCTAssertEqual(ReminderTimeZones.choices(including: "UTC", query: " new_york "), ReminderTimeZones.choices(including: "UTC", query: "new york"))
        XCTAssertFalse(ReminderTimeZones.choices(including: "Not/A_Zone").contains("Not/A_Zone"))
        XCTAssertTrue(ReminderTimeZones.choices(including: "UTC", query: "no such time zone at all").isEmpty)
    }
    func testChangingZoneKeepsCivilDayInsteadOfOriginalInstant() throws {
        let original = date("2026-10-24T22:00:00Z") // Copenhagen midnight on the 25th.
        let moved = try ReminderTimeZones.movingCivilDay(original, from: "Europe/Copenhagen", to: "America/New_York")
        XCTAssertEqual(key(moved, "America/New_York"), "2026-10-25")
        XCTAssertNotEqual(moved, original)
        let returned = try ReminderTimeZones.movingCivilDay(moved, from: "America/New_York", to: "Europe/Copenhagen")
        XCTAssertEqual(key(returned, "Europe/Copenhagen"), "2026-10-25")
    }
    func testSkippedCivilDayRefusesRatherThanRollingToTomorrow() {
        let original = date("2011-12-30T12:00:00Z")
        XCTAssertThrowsError(try ReminderTimeZones.movingCivilDay(original, from: "UTC", to: "Pacific/Apia"))
        XCTAssertEqual(original, date("2011-12-30T12:00:00Z"))
    }
    func testMidnightGapStillKeepsAnExistingCivilDay() throws {
        let moved = try ReminderTimeZones.movingCivilDay(date("2018-11-04T12:00:00Z"), from: "UTC", to: "America/Sao_Paulo")
        XCTAssertEqual(key(moved, "America/Sao_Paulo"), "2018-11-04")
    }
    func testInvalidZonesAndNonfiniteDatesAreRejected() {
        for id in ["", "Not/A_Zone", "GMT+02:00", "GMT-03:00"] {
            XCTAssertFalse(ReminderTimeZones.valid(id))
            XCTAssertThrowsError(try ReminderTimeZones.movingCivilDay(date("2026-10-21T12:00:00Z"), from: "UTC", to: id))
        }
        for n in [Double.nan, Double.infinity, -Double.infinity, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(try ReminderTimeZones.movingCivilDay(Date(timeIntervalSince1970: n), from: "UTC", to: "America/New_York"))
        }
    }
    func testDomainEdgesKeepTheirCivilYear() throws {
        for day in ["0001-01-01", "9999-12-31"] {
            let original = date(day + "T12:00:00Z")
            let moved = try ReminderTimeZones.movingCivilDay(original, from: "UTC", to: "America/New_York")
            XCTAssertEqual(key(moved, "America/New_York"), day)
        }
    }
    func testDeviceClockChangeIsVisibleWhileSourceClockStaysNine() throws {
        let s = try schedule()
        let rows = ReminderClockPreview.rows(s, after: date("2026-10-23T00:00:00Z"), displayZone: zone("Europe/Copenhagen"), locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(rows.count, 5); XCTAssertEqual(hours(rows, "America/New_York"), Array(repeating: 9, count: 5))
        XCTAssertEqual(hours(rows, "Europe/Copenhagen"), [15, 14, 14, 14, 14])
        XCTAssertTrue(rows.allSatisfy { $0.deviceText != nil }); XCTAssertTrue(ReminderClockPreview.clocksChange(rows))
        XCTAssertEqual(rows.map(\.instant), s.dates(after: date("2026-10-23T00:00:00Z"), limit: 5))
    }
    func testSourceClockChangeAltersInstantsButNotAuthoredClock() throws {
        let rows = ReminderClockPreview.rows(try schedule("Europe/Copenhagen"), after: date("2026-10-23T00:00:00Z"), displayZone: zone("Asia/Tokyo"))
        XCTAssertEqual(hours(rows, "Europe/Copenhagen"), Array(repeating: 9, count: 5))
        XCTAssertEqual(hours(rows, "Asia/Tokyo"), [16, 17, 17, 17, 17]); XCTAssertTrue(ReminderClockPreview.clocksChange(rows))
    }
    func testSameZoneOmitsDuplicateClockAndBoundsPreviewWork() throws {
        let s = try schedule(start: "2026-10-21"), now = date("2026-10-20T00:00:00Z")
        let rows = ReminderClockPreview.rows(s, after: now, displayZone: zone("America/New_York"), limit: Int.max)
        XCTAssertEqual(rows.count, 5); XCTAssertTrue(rows.allSatisfy { $0.deviceText == nil })
        XCTAssertFalse(ReminderClockPreview.clocksChange(rows))
        XCTAssertTrue(ReminderClockPreview.rows(s, after: now, displayZone: zone("UTC"), limit: -1).isEmpty)
        XCTAssertEqual(ReminderClockPreview.rows(s, after: s.first, displayZone: zone("UTC")).count, 4)
    }
    func testPreviewDoesNotChangeSpecOrItsOriginalNotificationSignature() throws {
        let s = try schedule(), spec = ReminderSpec.recurring(s)
        var task = Record(["id": .string(UUID().uuidString), "task_generation": .string(UUID().uuidString), "reminder_specs": .array([.object(spec.raw)])])
        let before = task, now = date("2026-10-23T00:00:00Z"), event = try XCTUnwrap(DueReminder.events(tasks: [task], now: date("2026-10-23T00:00:00Z")).first)
        _ = ReminderClockPreview.rows(s, after: now, displayZone: zone("Asia/Tokyo"))
        XCTAssertEqual(task, before)
        XCTAssertNotNil(DueReminder.validated(tasks: [task], taskID: task.id, specID: spec.id, signature: event.signature, originalAt: event.date))
        var raw = spec.raw; raw["time_zone"] = .string("Europe/Copenhagen")
        XCTAssertNotNil(ReminderSpec(row: .object(raw))); task["reminder_specs"] = .array([.object(raw)])
        XCTAssertNil(DueReminder.validated(tasks: [task], taskID: task.id, specID: spec.id, signature: event.signature, originalAt: event.date))
    }
    func testLocaleAndFixedDeviceOffsetAffectPresentationOnly() throws {
        let s = try schedule(), now = date("2026-10-23T00:00:00Z"), display = TimeZone(secondsFromGMT: 19800)!
        let a = ReminderClockPreview.rows(s, after: now, displayZone: display, locale: Locale(identifier: "ar_SA"))
        let b = ReminderClockPreview.rows(s, after: now, displayZone: display, locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(a.map(\.instant), b.map(\.instant)); XCTAssertTrue(a.allSatisfy { !$0.sourceText.isEmpty && $0.deviceText?.isEmpty == false })
        XCTAssertEqual(ReminderTimeZones.sourceIdentifier(for: display), "UTC")
        XCTAssertEqual(ReminderTimeZones.sourceIdentifier(for: zone("Europe/Copenhagen")), "Europe/Copenhagen")
    }
}
