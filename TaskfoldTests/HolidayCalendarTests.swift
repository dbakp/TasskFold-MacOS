import XCTest
@testable import TaskfoldCore

final class HolidayCalendarTests: XCTestCase {
    func file(_ events: String, year: Int = 2026) throws -> HolidayCalendarFile {
        try HolidayCalendarFile(data: Data(("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nX-WR-CALNAME:Workshop holidays\r\n" + events + "END:VCALENDAR\r\n").utf8), year: year)
    }
    func event(_ id: String = "a", _ body: String) -> String { "BEGIN:VEVENT\r\nUID:" + id + "\r\n" + body + "END:VEVENT\r\n" }
    func policy(_ dates: [String], mode: ReminderHolidayPolicy.Mode = .skip, weekends: Bool = false, year: Int = 2026) throws -> ReminderHolidayPolicy {
        try XCTUnwrap(ReminderHolidayPolicy(raw: ["version": .number(1), "year": .number(Double(year)), "dates": .array(dates.map(JSON.string)), "source": .string("Reviewed workshop dates"), "region": .string("Workshop"), "digest": .string(String(repeating: "a", count: 64)), "mode": .string(mode.rawValue), "avoid_weekends": .bool(weekends)]))
    }
    func spec(_ policy: ReminderHolidayPolicy, phrase: String = "every day for 5 occurrences", start: String = "2026-01-01", time: String = "09:00", zone: String = "Europe/Copenhagen") throws -> ReminderSpec {
        try XCTUnwrap(ReminderSpec.recurring(try XCTUnwrap(ReminderCalendarSchedule.make(phrase, time: time, start: start, zone: zone))).settingHolidayPolicy(policy))
    }
    let before = ISO8601DateFormatter().date(from: "2025-12-30T00:00:00Z")!
    func task(_ spec: ReminderSpec) -> Record { Record(["id": .string("90000000-0000-4000-8000-000000000001"), "task_generation": .string("90000000-0000-4000-8000-000000000002"), "title": .string("Holiday proof"), "reminder_specs": .array([.object(spec.raw)])]) }
    func keys(_ dates: [Date], zone: String = "Europe/Copenhagen") -> [String] { dates.map { ReminderCivilDay.current($0, zone: TimeZone(identifier: zone)!)!.key } }
    func testExpandedDatesFoldedNamesMultiDayAndPrivacySnapshot() throws {
        let f = try file(event("a", "DTSTART;VALUE=DATE:20260101\r\nDTEND;VALUE=DATE:20260103\r\nSUMMARY:New Year\\,\r\n workshop\r\nDESCRIPTION:Private notes never stored\r\nURL:https://example.invalid/private\r\n") + event("b", "DTSTART;VALUE=DATE:20260102\r\nSUMMARY:Second holiday\r\n"))
        XCTAssertEqual(f.days.map(\.date), ["2026-01-01", "2026-01-02"])
        XCTAssertEqual(f.days[0].names, ["New Year,workshop"])
        let p = try XCTUnwrap(f.policy(source: f.name, region: "Workshop", mode: .skip, avoidWeekends: false))
        XCTAssertEqual(p.dates, f.days.map(\.date)); XCTAssertEqual(p.digest.count, 64)
        let raw = try JSONEncoder().encode(JSON.object(p.raw))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("Private")); XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("example.invalid"))
    }
    func testRecurringLeapDateNeverClampsAndYearlyOrdinalUsesSourceMonth() throws {
        let leap = event("leap", "DTSTART;VALUE=DATE:20200229\r\nRRULE:FREQ=YEARLY\r\nSUMMARY:Leap day\r\n")
        XCTAssertTrue(try file(leap).days.isEmpty); XCTAssertEqual(try file(leap, year: 2028).days.map(\.date), ["2028-02-29"])
        let ordinal = event("weekday", "DTSTART;VALUE=DATE:20201126\r\nRRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=4TH\r\n")
        XCTAssertEqual(try file(ordinal).days.map(\.date), ["2026-11-26"])
    }
    func testRDateExDateCountDurationAndCancelledEvents() throws {
        let e = event("a", "DTSTART;VALUE=DATE:20260101\r\nDURATION:P2D\r\nRRULE:FREQ=DAILY;COUNT=3\r\nEXDATE;VALUE=DATE:20260102\r\nRDATE;VALUE=DATE:20260110\r\n") + event("b", "STATUS:CANCELLED\r\n")
        XCTAssertEqual(try file(e).days.map(\.date), ["2026-01-01", "2026-01-02", "2026-01-03", "2026-01-04", "2026-01-10", "2026-01-11"])
    }
    func testInclusiveUntilAndYearBoundarySpan() throws {
        let e = event("a", "DTSTART;VALUE=DATE:20251231\r\nDURATION:P2D\r\nRRULE:FREQ=YEARLY;UNTIL=20261231\r\n")
        XCTAssertEqual(try file(e).days.map(\.date), ["2026-01-01", "2026-12-31"])
    }
    func testMalformedTimedOverridesAndUnsupportedRulesFailWholeFile() throws {
        let good = event("good", "DTSTART;VALUE=DATE:20260101\r\n")
        for bad in ["DTSTART:20260102T090000Z\r\n", "DTSTART;VALUE=DATE:20260230\r\n", "DTSTART;VALUE=DATE;TZID=UTC:20260101\r\n", "DTSTART;VALUE=DATE:20260101\r\nRECURRENCE-ID;VALUE=DATE:20250101\r\n", "DTSTART;VALUE=DATE:20260101\r\nRRULE:FREQ=YEARLY;BYSETPOS=-1\r\n", "DTSTART;VALUE=DATE:20260101\r\nRRULE:FREQ=DAILY;COUNT=1;UNTIL=20261231\r\n", "DTSTART;VALUE=DATE:20260101\r\nDTEND;VALUE=DATE:20251231\r\n", "DTSTART;VALUE=DATE:20260101\r\nDURATION:P0D\r\n", "DTSTART;VALUE=DATE:20260101\r\nRRULE:FREQ=YEARLY;BYMONTH=13\r\n"] {
            XCTAssertThrowsError(try file(good + event("bad", bad)), bad)
        }
        XCTAssertThrowsError(try file(good + good)); XCTAssertThrowsError(try file(good.replacingOccurrences(of: "UID:good\r\n", with: "")))
    }
    func testInputBoundsAndCalendarEnvelope() throws {
        XCTAssertThrowsError(try HolidayCalendarFile(data: Data(repeating: 32, count: HolidayCalendarFile.maximumBytes + 1), year: 2026))
        for raw in ["", "BEGIN:VCALENDAR\nVERSION:2.0\n", "BEGIN:VCALENDAR\nVERSION:1.0\nEND:VCALENDAR", "BEGIN:VCALENDAR\nVERSION:2.0\nMETHOD:REQUEST\nEND:VCALENDAR", "BEGIN:VCALENDAR\nVERSION:2.0\nEND:VEVENT", "BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR\nBEGIN:VCALENDAR\nEND:VCALENDAR"] {
            XCTAssertThrowsError(try HolidayCalendarFile(data: Data(raw.utf8), year: 2026))
        }
    }
    func testUTF8ByteFoldingQuotedParametersAndTooManyOverlappingNames() throws {
        let source = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" + event("a", "DTSTART;VALUE=DATE:20260101\r\nSUMMARY:Årlig holiday\r\nDESCRIPTION;ALTREP=\"https://example.invalid/a;b:c\":Ignored\r\n") + "END:VCALENDAR\r\n"
        var bytes = Array(source.utf8); let position = try XCTUnwrap(bytes.firstIndex(of: 0xC3)); bytes.insert(contentsOf: [13, 10, 32], at: position + 1)
        XCTAssertEqual(try HolidayCalendarFile(data: Data(bytes), year: 2026).days.first?.names, ["Årlig holiday"])
        let crowded = (0..<17).map { event(String($0), "DTSTART;VALUE=DATE:20260101\r\nSUMMARY:Holiday \($0)\r\n") }.joined()
        XCTAssertThrowsError(try file(crowded))
    }
    func testMoveSkipsAnUnavailableCivilDayAndCoverageCanIncludeYearOne() throws {
        let p = try policy(["2011-12-29"], mode: .nextDay, year: 2011)
        let s = try spec(p, phrase: "every day for 1 occurrence", start: "2011-12-29", zone: "Pacific/Apia")
        let dates = s.holidaySchedule!.dates(after: ISO8601DateFormatter().date(from: "2011-12-28T00:00:00Z")!)
        XCTAssertEqual(keys(dates, zone: "Pacific/Apia"), ["2011-12-31"])
        let early = try spec(policy([], year: 1), phrase: "every day for 2 occurrences", start: "0001-01-01", zone: "UTC")
        XCTAssertEqual(early.holidaySchedule!.dates(after: ISO8601DateFormatter().date(from: "0001-01-01T00:00:00Z")!).count, 2)
    }
    func testMonthlyAndYearlyPositionRulesUseWholePeriodsBeforeCountAndUntil() throws {
        let monthly = event("monthly", "DTSTART;VALUE=DATE:20260112\r\nRRULE:FREQ=MONTHLY;BYDAY=MO;BYSETPOS=2;COUNT=2\r\n")
        XCTAssertEqual(try file(monthly).days.map(\.date), ["2026-01-12", "2026-02-09"])
        let yearly = event("yearly", "DTSTART;VALUE=DATE:20250825\r\nRRULE:FREQ=YEARLY;BYMONTH=5,8;BYDAY=MO;BYSETPOS=-1;COUNT=2\r\n")
        XCTAssertEqual(try file(yearly).days.map(\.date), ["2026-08-31"])
        let ended = yearly.replacingOccurrences(of: "COUNT=2", with: "UNTIL=20260630")
        XCTAssertTrue(try file(ended).days.isEmpty)
    }
    func testCoordinatedReaderReturnsExactBytesAndRefusesOversizedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("holiday-reader-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("calendar.ics"), data = Data("BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR\n".utf8)
        try data.write(to: url); XCTAssertEqual(try HolidayCalendarFile.read(url), data)
        try Data(repeating: 32, count: HolidayCalendarFile.maximumBytes + 1).write(to: url)
        XCTAssertThrowsError(try HolidayCalendarFile.read(url))
    }
    func testPolicyStrictOrderingCoverageAndVersion() throws {
        let p = try policy(["2026-01-01"]); XCTAssertEqual(ReminderHolidayPolicy(raw: p.raw), p)
        for (key, value) in [("year", JSON.number(2025)), ("version", .number(2)), ("source", .string(" ")), ("digest", .string("invalid")), ("dates", .array([.string("2026-01-02"), .string("2026-01-01")])), ("dates", .array([.string("2026-01-01"), .string("2026-01-01")]))] {
            var raw = p.raw; raw[key] = value; XCTAssertNil(ReminderHolidayPolicy(raw: raw), key)
        }
    }
    func testSkipConsumesOriginalCountAndDoesNotChangeTaskPlanning() throws {
        let s = try spec(policy(["2026-01-01", "2026-01-02"], weekends: true)), row = task(s)
        let events = DueReminder.events(tasks: [row], now: before)
        XCTAssertEqual(keys(events.map(\.date)), ["2026-01-05"]); XCTAssertEqual(events.first?.signature.hasPrefix("r8:"), true)
        XCTAssertEqual(ReminderSpec.rows(row), [.object(s.raw)]); XCTAssertTrue(row.string("due_date").isEmpty)
    }
    func testMovesCoalesceAndCannotPassInclusiveEndOrCoverage() throws {
        let p = try policy(["2026-01-01", "2026-01-02"], mode: .nextDay, weekends: true)
        let s = try spec(p); XCTAssertEqual(keys(s.holidaySchedule!.dates(after: before)), ["2026-01-05"])
        let ended = try spec(p, phrase: "every day until 2026-01-04")
        XCTAssertTrue(ended.holidaySchedule!.dates(after: before).isEmpty)
        let last = try spec(policy(["2026-12-31"], mode: .nextDay), phrase: "every day", start: "2026-12-31")
        XCTAssertTrue(last.holidaySchedule!.dates(after: before).isEmpty)
        XCTAssertTrue(s.holidaySchedule!.dates(after: ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z")!).isEmpty)
    }
    func testMovedClockUsesDSTResolverAndRejectsStaleResponses() throws {
        let s = try spec(policy(["2026-03-28"], mode: .nextDay), phrase: "every day for 2 occurrences", start: "2026-03-28", time: "02:30")
        let row = task(s), events = DueReminder.events(tasks: [row], now: before), event = try XCTUnwrap(events.first)
        XCTAssertEqual(events.count, 1); XCTAssertEqual(event.date, ISO8601DateFormatter().date(from: "2026-03-29T01:00:00Z")!)
        XCTAssertNotNil(DueReminder.validated(tasks: [row], taskID: row.id, specID: s.id, signature: event.signature, originalAt: event.date))
        let changed = try XCTUnwrap(s.settingHolidayPolicy(policy(["2026-03-28"], mode: .skip)))
        XCTAssertNil(DueReminder.validated(tasks: [task(changed)], taskID: row.id, specID: s.id, signature: event.signature, originalAt: event.date))
        XCTAssertNil(DueReminder.validated(tasks: [row], taskID: row.id, specID: s.id, signature: event.signature, originalAt: event.date.addingTimeInterval(60)))
    }
    func testTimeSensitiveWrapperOffAndSourceExtensionsPreserveSettings() throws {
        var s = try spec(policy(["2026-01-01"])), raw = s.raw["holiday_policy"]!.object
        raw["future"] = .string("keep"); s.raw["holiday_policy"] = .object(raw)
        let elevated = try XCTUnwrap(s.settingTimeSensitive(true)); XCTAssertEqual(elevated.raw["schedule_version"], .number(5))
        XCTAssertEqual(elevated.settingTimeSensitive(false), s)
        let changed = try XCTUnwrap(elevated.settingHolidayPolicy(policy(["2026-01-02"], mode: .nextDay)))
        XCTAssertTrue(changed.timeSensitive); XCTAssertEqual(changed.raw["holiday_policy"]?.object["future"], .string("keep"))
        let normal = try XCTUnwrap(elevated.settingHolidayPolicy(nil)); XCTAssertTrue(normal.timeSensitive); XCTAssertEqual(normal.raw["schedule_version"], .number(2)); XCTAssertNil(normal.raw["holiday_policy"])
        let events = DueReminder.events(tasks: [task(elevated)], now: before); XCTAssertTrue(events.allSatisfy { $0.signature.hasPrefix("r7:") && $0.timeSensitive })
    }
    func testPreviewUsesTransformedDatesWithoutChangingSavedData() throws {
        let s = try spec(policy(["2026-01-01"], mode: .nextDay)), schedule = s.holidaySchedule!, beforeRaw = s.raw
        let dates = schedule.dates(after: before, limit: 5)
        let preview = ReminderClockPreview.rows(schedule.base, after: before, displayZone: TimeZone(identifier: "Asia/Tokyo")!, dates: dates)
        XCTAssertEqual(preview.map(\.instant), dates); XCTAssertEqual(s.raw, beforeRaw)
        XCTAssertEqual(ReminderSpec.successorRows([.object(s.raw)]), [.object(s.raw)])
    }
    func testSnapshotBackupAndMalformedWrapperDoNotFallBack() throws {
        let s = try spec(policy(["2026-01-01"])), fixture = BackupTests(); var snapshot = fixture.fixture(), row = snapshot.tables["tasks"]![0]
        row["reminder_specs"] = .array([.object(s.raw)]); snapshot.tables["tasks"] = [row]
        snapshot.pending = [Mutation(table: "tasks", recordID: row.id, method: "PATCH", fields: ["reminder_specs": row["reminder_specs"]])]
        let saved = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(saved.pending[0].fields["reminder_specs"], row["reminder_specs"])
        let backup = try WorkspaceBackup.read(WorkspaceBackup.make(saved, account: fixture.owner).data())
        XCTAssertEqual(try backup.plan(current: Snapshot(), account: fixture.other).changes.first { $0.table == "tasks" }?.fields["reminder_specs"], row["reminder_specs"])
        var bad = s.raw; bad["holiday_policy"] = .null; XCTAssertNil(ReminderSpec(row: .object(bad)))
        row["reminder_specs"] = .array([.object(bad)]); XCTAssertTrue(DueReminder.events(tasks: [row], now: before).isEmpty)
    }

    func countryData(_ rows: String) -> Data { Data(rows.utf8) }
    func countryRow(_ date: String = "2026-01-01", country: String = "DE", national: Bool = true, codes: String = "null", type: String = "Public", name: String = "Holiday") -> String {
        "{\"date\":\"\(date)\",\"countryCode\":\"\(country)\",\"name\":\"\(name)\",\"nationalHoliday\":\(national),\"subdivisionCodes\":\(codes),\"holidayTypes\":[\"\(type)\"]}"
    }
    func testCountryCatalogValidationAndSorting() throws {
        let values = try CountryHolidayCalendar.countries(data: countryData("[{\"countryCode\":\"DE\",\"name\":\"Germany\"},{\"countryCode\":\"DK\",\"name\":\"Denmark\"}]"))
        XCTAssertEqual(values.map(\.countryCode), ["DK", "DE"])
        for raw in ["[]", "[{\"countryCode\":\"de\",\"name\":\"Germany\"}]", "[{\"countryCode\":\"DE\",\"name\":\"\"}]", "[{\"countryCode\":\"DE\",\"name\":\"Germany\"},{\"countryCode\":\"DE\",\"name\":\"Duplicate\"}]"] { XCTAssertThrowsError(try CountryHolidayCalendar.countries(data: countryData(raw))) }
    }
    func testCountryNationalRegionalAndPublicOnlyCoverage() throws {
        let rows = [countryRow(), countryRow("2026-01-06", national: false, codes: "[\"DE-BY\",\"DE-BW\"]"), countryRow("2026-02-01", type: "Observance"), countryRow("2026-02-02", national: false, codes: "[\"DE-HE\"]"), countryRow("2026-02-03", type: "School")]
        let snapshot = try CountryHolidayCalendar.snapshot(data: countryData("[" + rows.joined(separator: ",") + "]"), year: 2026, country: "DE")
        XCTAssertEqual(snapshot.subdivisions, ["DE-BW", "DE-BY", "DE-HE"])
        XCTAssertEqual(snapshot.days(subdivision: nil).map(\.date), ["2026-01-01"])
        XCTAssertEqual(snapshot.days(subdivision: "DE-BY").map(\.date), ["2026-01-01", "2026-01-06"])
        XCTAssertEqual(snapshot.days(subdivision: "DE-HE").map(\.date), ["2026-01-01", "2026-02-02"])
        XCTAssertEqual(snapshot.digest.count, 64)
    }
    func testCountryMalformedResponsesFailWholeReview() {
        for row in [countryRow(country: "DK"), countryRow("2025-01-01"), countryRow("2026-02-30"), countryRow(national: false), countryRow(national: false, codes: "[\"GB-ENG\"]"), countryRow(type: "Unknown"), countryRow(name: ""), countryRow(name: String(repeating: "x", count: 161))] {
            XCTAssertThrowsError(try CountryHolidayCalendar.snapshot(data: countryData("[" + row + "]"), year: 2026, country: "DE"))
        }
        XCTAssertThrowsError(try CountryHolidayCalendar.snapshot(data: Data(repeating: 32, count: 1_000_001), year: 2026, country: "DE"))
    }
    func testCountryEmptyYearAndDuplicateNamesAreExplicitSnapshots() throws {
        XCTAssertTrue(try CountryHolidayCalendar.snapshot(data: countryData("[]"), year: 2026, country: "DE").days(subdivision: nil).isEmpty)
        let row = countryRow(), snapshot = try CountryHolidayCalendar.snapshot(data: countryData("[" + row + "," + row + "]"), year: 2026, country: "DE")
        XCTAssertEqual(snapshot.days(subdivision: nil), [.init(date: "2026-01-01", names: ["Holiday"])])
    }
    func testCountryRequestsUseVersionFourAndNoTaskData() throws {
        XCTAssertEqual(try CountryHolidayCalendar.request().url?.absoluteString, "https://nagerholidays.com/api/v4/Countries/Available")
        let request = try CountryHolidayCalendar.request(country: "DK", year: 2026)
        XCTAssertEqual(request.url?.absoluteString, "https://nagerholidays.com/api/v4/Holidays/DK/2026")
        XCTAssertNil(request.httpBody); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        for code in ["dk", "../US", "USA", ""] { XCTAssertThrowsError(try CountryHolidayCalendar.request(country: code, year: 2026)) }
        XCTAssertThrowsError(try CountryHolidayCalendar.request(country: "DK", year: 0))
        XCTAssertThrowsError(try CountryHolidayCalendar.request(country: "DK"))
    }
    func testCountryOriginRoundtripRemovalAndUnchangedTiming() throws {
        let normal = try policy(["2026-01-01"])
        var raw = normal.raw; raw["origin"] = .object(["provider": .string("nager-v4"), "country": .string("DE"), "subdivision": .string("DE-BY")])
        let national = try XCTUnwrap(ReminderHolidayPolicy(raw: raw))
        XCTAssertEqual(national.raw, raw); XCTAssertEqual(national.semanticFields, normal.semanticFields)
        var fromCountry = try spec(national)
        var extended = try XCTUnwrap(fromCountry.raw["holiday_policy"]?.object)
        var provenance = try XCTUnwrap(extended["origin"]?.object)
        provenance["future_provenance"] = .string("Preserve this extension")
        extended["origin"] = .object(provenance); fromCountry.raw["holiday_policy"] = .object(extended)
        let edited = try XCTUnwrap(fromCountry.settingHolidayPolicy(national))
        XCTAssertEqual(edited.raw["holiday_policy"]?.object["origin"]?.object["future_provenance"], .string("Preserve this extension"))
        let fromFile = try XCTUnwrap(fromCountry.settingHolidayPolicy(normal))
        XCTAssertNil(fromFile.holidaySchedule?.policy.origin)
        XCTAssertEqual(fromCountry.holidaySchedule?.dates(after: before), fromFile.holidaySchedule?.dates(after: before))
        for origin: [String: JSON] in [["provider": .string("unknown"), "country": .string("DE")], ["provider": .string("nager-v4"), "country": .string("DE"), "subdivision": .string("GB-ENG")]] {
            raw["origin"] = .object(origin); XCTAssertNil(ReminderHolidayPolicy(raw: raw))
        }
    }

}
