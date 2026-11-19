import XCTest
@testable import TaskfoldCore

/// "Skip holidays" keeps covering the years a reminder reaches without anyone turning it off and on.
final class HolidayYearCoverageTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock(); private var values: [String] = []
        func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }
    let zone = "Europe/Copenhagen"
    func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func snapshot(_ year: Int, country: String = "DK", dates: [String]? = nil) throws -> CountryHolidayCalendar.Snapshot { try Self.snapshot(year, country: country, dates: dates) }
    static func snapshot(_ year: Int, country: String = "DK", dates: [String]? = nil) throws -> CountryHolidayCalendar.Snapshot {
        let days = dates ?? ["\(year)-01-01", "\(year)-12-25"]
        let json = "[" + days.map { #"{"date":"\#($0)","name":"Holiday","countryCode":"\#(country)","nationalHoliday":true,"subdivisionCodes":null,"holidayTypes":["Public"]}"# }.joined(separator: ",") + "]"
        return try CountryHolidayCalendar.snapshot(data: Data(json.utf8), year: year, country: country)
    }
    func countryPolicy(_ year: Int, mode: ReminderHolidayPolicy.Mode = .skip) throws -> ReminderHolidayPolicy {
        try XCTUnwrap(CountryHolidayCalendar.policy(snapshot(year), countryName: "Denmark", mode: mode))
    }
    func spec(_ policy: ReminderHolidayPolicy, phrase: String = "every day", start: String = "2026-01-01") throws -> ReminderSpec {
        try XCTUnwrap(ReminderSpec.recurring(try XCTUnwrap(ReminderCalendarSchedule.make(phrase, time: "09:00", start: start, zone: zone))).settingHolidayPolicy(policy))
    }
    func task(_ spec: ReminderSpec) -> Record {
        Record(["id": .string("91000000-0000-4000-8000-000000000001"), "task_generation": .string("91000000-0000-4000-8000-000000000002"), "title": .string("Standup"), "reminder_specs": .array([.object(spec.raw)])])
    }
    func schedule(_ task: Record) throws -> ReminderHolidaySchedule {
        try XCTUnwrap(ReminderSpec(row: try XCTUnwrap(ReminderSpec.rows(task).first))?.holidaySchedule)
    }
    func keys(_ dates: [Date]) -> [String] { dates.map { ReminderCivilDay.current($0, zone: TimeZone(identifier: zone)!)!.key } }
    private func fetcher(_ calls: Calls, failing: Set<Int> = []) -> HolidayYearCoverage.Fetch {
        { country, year in
            calls.add(country + "|" + String(year))
            if failing.contains(year) { throw URLError(.notConnectedToInternet) }
            return try Self.snapshot(year, country: country)
        }
    }

    func testDecemberLoadsNextYearAheadAndJanuaryPromotesIt() async throws {
        let saved = task(try spec(countryPolicy(2026)))
        let december = at("2026-12-20T12:00:00Z")
        XCTAssertEqual(HolidayYearCoverage.needed(try schedule(saved), now: december), [2026, 2027])
        XCTAssertEqual(HolidayYearCoverage.missing(try schedule(saved), now: december), [2027])
        XCTAssertTrue(HolidayYearCoverage.needsRefresh(saved, now: december))
        let calls = Calls()
        let first = await HolidayYearCoverage.refreshing(saved, now: december, fetch: fetcher(calls)).task
        let loaded = try XCTUnwrap(first)
        XCTAssertEqual(calls.all, ["DK|2027"])
        let policy = try schedule(loaded).policy
        XCTAssertEqual(policy.year, 2026); XCTAssertEqual(policy.coveredYears, [2026, 2027])
        XCTAssertEqual(policy.laterYears.first?.dates, ["2027-01-01", "2027-12-25"])
        // Across New Year both years' holidays are skipped, with no gap or stop.
        XCTAssertEqual(keys(try schedule(loaded).dates(after: at("2026-12-23T12:00:00Z"), limit: 6)), ["2026-12-24", "2026-12-26", "2026-12-27", "2026-12-28", "2026-12-29", "2026-12-30"])
        XCTAssertEqual(keys(try schedule(loaded).dates(after: at("2026-12-30T12:00:00Z"), limit: 3)), ["2026-12-31", "2027-01-02", "2027-01-03"])
        // In January the new year becomes the policy's year, the past one is dropped and the following one loads.
        let january = at("2027-01-02T12:00:00Z")
        XCTAssertEqual(HolidayYearCoverage.missing(try schedule(loaded), now: january), [2028])
        let second = await HolidayYearCoverage.refreshing(loaded, now: january, fetch: fetcher(calls)).task
        let rolled = try XCTUnwrap(second)
        let next = try schedule(rolled).policy
        XCTAssertEqual(next.year, 2027); XCTAssertEqual(next.coveredYears, [2027, 2028]); XCTAssertEqual(next.dates, ["2027-01-01", "2027-12-25"])
        XCTAssertEqual(next.region, "Denmark · Nationwide"); XCTAssertEqual(next.origin?.country, "DK")
        XCTAssertEqual(calls.all, ["DK|2027", "DK|2028"])
    }

    func testMoveToNextDayCrossesIntoTheLoadedYear() throws {
        let policy = try XCTUnwrap(countryPolicy(2026, mode: .nextDay).covering([
            XCTUnwrap(ReminderHolidayPolicy.Year(year: 2026, dates: ["2026-12-31"], digest: String(repeating: "a", count: 64))),
            XCTUnwrap(ReminderHolidayPolicy.Year(year: 2027, dates: ["2027-01-01"], digest: String(repeating: "b", count: 64)))]))
        let weekly = task(try spec(policy, phrase: "every week on thursday", start: "2026-12-03"))
        // Thu 31 Dec and Fri 1 Jan are both holidays: the alert lands on Sat 2 Jan.
        XCTAssertEqual(keys(try schedule(weekly).dates(after: at("2026-12-28T12:00:00Z"), limit: 2)), ["2027-01-02", "2027-01-07"])
    }

    func testMultiYearRecurrenceNeedsOnlyTheYearsItReaches() throws {
        let policy = try countryPolicy(2026)
        let yearly = try schedule(task(try spec(policy, phrase: "every year", start: "2026-01-01")))
        // Next occurrence 1 Jan 2027; the next 12 months stay in 2027.
        XCTAssertEqual(HolidayYearCoverage.needed(yearly, now: at("2026-06-01T12:00:00Z")), [2027])
        let biennial = try schedule(task(try spec(policy, phrase: "every 3 years", start: "2026-03-01")))
        XCTAssertEqual(HolidayYearCoverage.needed(biennial, now: at("2026-06-01T12:00:00Z")), [2029], "an occurrence beyond 12 months needs its own year")
        let ended = try schedule(task(try spec(policy, phrase: "every day until 2026-12-24", start: "2026-01-01")))
        XCTAssertEqual(HolidayYearCoverage.needed(ended, now: at("2026-12-01T12:00:00Z")), [2026], "an ended schedule never fetches next year")
        XCTAssertTrue(HolidayYearCoverage.needed(ended, now: at("2026-12-26T12:00:00Z")).isEmpty)
        // A long-running daily reminder in mid-year already holds next year once loaded, and never more than three years.
        let daily = try schedule(task(try spec(policy)))
        XCTAssertEqual(HolidayYearCoverage.needed(daily, now: at("2026-06-01T12:00:00Z")), [2026, 2027])
    }

    func testOfflineKeepsStoredDatesRetriesLaterAndNeverStopsAlerts() async throws {
        let saved = task(try spec(countryPolicy(2026)))
        let december = at("2026-12-20T12:00:00Z"), calls = Calls()
        let result = await HolidayYearCoverage.refreshing(saved, now: december, fetch: fetcher(calls, failing: [2027]))
        XCTAssertNil(result.task, "nothing is written when the fetch fails"); XCTAssertEqual(result.failed, [2027])
        XCTAssertTrue(HolidayYearCoverage.needsRefresh(saved, now: december), "the next pass retries")
        // Alerts keep coming past the loaded year; a day there is not known to be a holiday yet.
        XCTAssertEqual(keys(try schedule(saved).dates(after: at("2026-12-30T12:00:00Z"), limit: 3)), ["2026-12-31", "2027-01-01", "2027-01-02"])
        XCTAssertEqual(keys(try schedule(saved).dates(after: at("2027-03-01T12:00:00Z"), limit: 1)), ["2027-03-02"])
        let footer = HolidayYearCoverage.footer(try schedule(saved).policy, schedule: try schedule(saved).base, now: december)
        XCTAssertEqual(footer, "Public holidays in Denmark are skipped. Next year’s holidays will load when you’re online.")
        // A reviewed calendar file cannot load more years: it keeps stopping at its year and never fetches.
        let file = try XCTUnwrap(ReminderHolidayPolicy(raw: countryPolicy(2026).raw.filter { $0.key != "origin" }))
        let reviewed = task(try spec(file))
        XCTAssertFalse(HolidayYearCoverage.needsRefresh(reviewed, now: december))
        XCTAssertTrue(try schedule(reviewed).dates(after: at("2027-01-05T12:00:00Z")).isEmpty)
        // The session cache waits before asking again, unless a person asks or the device comes back online.
        let cache = HolidaySnapshotCache(retryInterval: 300), cached = Calls()
        for _ in 0..<2 { _ = try? await cache.snapshot(country: "DK", year: 2027, now: december, load: fetcher(cached, failing: [2027])) }
        XCTAssertEqual(cached.all.count, 1)
        _ = try? await cache.snapshot(country: "DK", year: 2027, now: december, retrying: true, load: fetcher(cached, failing: [2027]))
        XCTAssertEqual(cached.all.count, 2)
        await cache.forgetFailures()
        let loaded = try await cache.snapshot(country: "DK", year: 2027, now: december, load: fetcher(cached))
        XCTAssertEqual(loaded.year, 2027); XCTAssertEqual(cached.all.count, 3)
        _ = try await cache.snapshot(country: "DK", year: 2027, now: december, load: fetcher(cached))
        XCTAssertEqual(cached.all.count, 3, "a loaded year is asked for once")
    }

    func testRefreshIsIdempotentAndKeepsEstablishedSignatures() async throws {
        let original = try spec(countryPolicy(2026)), saved = task(original), december = at("2026-12-20T12:00:00Z"), calls = Calls()
        let fields = try schedule(saved).semanticFields
        let first = await HolidayYearCoverage.refreshing(saved, now: december, fetch: fetcher(calls)).task
        let loaded = try XCTUnwrap(first)
        XCTAssertFalse(HolidayYearCoverage.needsRefresh(loaded, now: december))
        let again = await HolidayYearCoverage.refreshing(loaded, now: december, fetch: fetcher(calls))
        XCTAssertNil(again.task); XCTAssertTrue(again.failed.isEmpty); XCTAssertEqual(calls.all, ["DK|2027"])
        XCTAssertNil(HolidayYearCoverage.updated(try schedule(loaded).policy, adding: [], currentYear: 2026))
        // A policy without later years keeps its signature fields; loading a year changes them once.
        XCTAssertEqual(try schedule(saved).semanticFields, fields)
        XCTAssertNotEqual(try schedule(loaded).semanticFields, fields)
        XCTAssertEqual(HolidayYearCoverage.footer(try schedule(loaded).policy, schedule: try schedule(loaded).base, now: december), "Public holidays in Denmark are skipped.")
    }

    func testPoliciesSavedBeforeLaterYearsRoundTripAndReplaceCleanly() throws {
        // Saved before this change: no `later_years`. Older readers keep the extension; this reader validates it.
        let old = try countryPolicy(2026)
        XCTAssertNil(old.raw[ReminderHolidayPolicy.laterYearsKey]); XCTAssertTrue(old.laterYears.isEmpty)
        var raw = old.raw
        raw[ReminderHolidayPolicy.laterYearsKey] = .array([.object(["year": .number(2027), "dates": .array([.string("2027-01-01")]), "digest": .string(String(repeating: "c", count: 64))])])
        let extended = try XCTUnwrap(ReminderHolidayPolicy(raw: raw))
        XCTAssertEqual(extended.coveredYears, [2026, 2027]); XCTAssertEqual(ReminderHolidayPolicy(raw: extended.raw), extended)
        for bad: JSON in [.array([.object(["year": .number(2026), "dates": .array([]), "digest": .string(String(repeating: "c", count: 64))])]),
                          .array([.object(["year": .number(2027), "dates": .array([.string("2028-01-01")]), "digest": .string(String(repeating: "c", count: 64))])]),
                          .string("2027")] {
            var value = raw; value[ReminderHolidayPolicy.laterYearsKey] = bad
            let policy = try XCTUnwrap(ReminderHolidayPolicy(raw: value), "a malformed extension never invalidates the reminder")
            XCTAssertTrue(policy.laterYears.isEmpty)
        }
        // Choosing another calendar drops the years loaded for the previous one.
        let loaded = try XCTUnwrap(try spec(old).settingHolidayPolicy(extended))
        XCTAssertEqual(loaded.holidaySchedule?.policy.coveredYears, [2026, 2027])
        let replaced = try XCTUnwrap(loaded.settingHolidayPolicy(try XCTUnwrap(CountryHolidayCalendar.policy(snapshot(2026, country: "SE"), countryName: "Sweden"))))
        XCTAssertNil(replaced.raw["holiday_policy"]?.object[ReminderHolidayPolicy.laterYearsKey])
        XCTAssertEqual(replaced.holidaySchedule?.policy.coveredYears, [2026])
    }

    func testFooterNeverAsksToToggle() throws {
        let policy = try countryPolicy(2026), base = try XCTUnwrap(ReminderCalendarSchedule.make("every day for 5 occurrences", time: "09:00", start: "2026-11-20", zone: zone))
        XCTAssertEqual(HolidayYearCoverage.footer(policy, schedule: base, now: at("2026-11-19T12:00:00Z")), "Public holidays in Denmark are skipped.")
        XCTAssertEqual(HolidayYearCoverage.footer(try countryPolicy(2026, mode: .nextDay), schedule: base, now: at("2026-11-19T12:00:00Z")), "Alerts on public holidays in Denmark move to the next day.")
        let daily = try XCTUnwrap(ReminderCalendarSchedule.make("every day", time: "09:00", start: "2026-01-01", zone: zone))
        let both = HolidayYearCoverage.footer(try countryPolicy(2028), schedule: daily, now: at("2026-11-19T12:00:00Z"))
        XCTAssertEqual(both, "Public holidays in Denmark are skipped. Holidays for 2026 and 2027 will load when you’re online.")
        for text in [both, HolidayYearCoverage.footer(policy, schedule: daily, now: at("2026-11-19T12:00:00Z"))] {
            XCTAssertFalse(text.contains("Turn"), text); XCTAssertFalse(text.contains("off and on"), text)
        }
    }
}
