import Foundation
import CryptoKit

/// A reviewed, finite civil-date snapshot. It contains no event notes, URLs or attendees.
struct ReminderHolidayPolicy: Equatable, Sendable {
    enum Mode: String, CaseIterable, Sendable { case skip, nextDay = "next-day" }
    let year: Int
    let dates: [String]
    let source: String
    let region: String
    let digest: String
    let mode: Mode
    let avoidWeekends: Bool
    let origin: CountryHolidayCalendar.Origin?
    var firstDay: ReminderCivilDay { ReminderCivilDay(String(format: "%04d-01-01", year))! }
    var lastDay: ReminderCivilDay { ReminderCivilDay(String(format: "%04d-12-31", year))! }
    init?(raw: [String: JSON]) {
        guard raw["version"] == .number(1), let year = Recurrence.number(raw["year"] ?? .null, in: 1...9999),
              let mode = Mode(rawValue: raw["mode"]?.text ?? ""),
              case .bool(let weekends)? = raw["avoid_weekends"],
              case .string(let source)? = raw["source"], !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source.count <= 160,
              case .string(let region)? = raw["region"], !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, region.count <= 160,
              case .string(let digest)? = raw["digest"], digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              case .array(let values)? = raw["dates"], values.count <= 366 else { return nil }
        let origin = raw["origin"].flatMap { CountryHolidayCalendar.Origin(raw: $0.object) }
        guard raw["origin"] == nil || origin != nil else { return nil }
        self.origin = origin
        var dates: [String] = []
        for value in values {
            guard case .string(let key) = value, let day = ReminderCivilDay(key), day.year == year else { return nil }
            dates.append(key)
        }
        guard dates == Array(Set(dates)).sorted() else { return nil }
        self.year = year; self.dates = dates; self.source = source; self.region = region; self.digest = digest
        self.mode = mode; avoidWeekends = weekends
    }
    var raw: [String: JSON] {
        var value: [String: JSON] = ["version": .number(1), "year": .number(Double(year)), "dates": .array(dates.map(JSON.string)), "source": .string(source), "region": .string(region), "digest": .string(digest), "mode": .string(mode.rawValue), "avoid_weekends": .bool(avoidWeekends)]
        if let origin { value["origin"] = .object(origin.raw) }; return value
    }
    var semanticFields: [String] { [String(year), mode.rawValue, avoidWeekends ? "1" : "0"] + dates }
}

struct ReminderHolidaySchedule: Sendable {
    let base: ReminderCalendarSchedule
    let policy: ReminderHolidayPolicy
    init?(raw: [String: JSON]) {
        guard let base = ReminderCalendarSchedule(raw: raw), let policy = ReminderHolidayPolicy(raw: raw["holiday_policy"]?.object ?? [:]) else { return nil }
        self.base = base; self.policy = policy
    }
    /// At most 366 nominal daily slots exist in this explicitly reviewed year.
    /// Limits consume original slots; moves retain the clock, never the task's plan.
    func dates(after now: Date, limit: Int = 60) -> [Date] {
        guard limit > 0, now.timeIntervalSince1970.isFinite else { return [] }
        if let today = ReminderCivilDay.current(now, zone: base.calendar.timeZone), today > policy.lastDay { return [] }
        let blocked = Set(policy.dates)
        func excluded(_ day: ReminderCivilDay) -> Bool { blocked.contains(day.key) || (policy.avoidWeekends && (day.weekday == 0 || day.weekday == 6)) }
        var reviewStart = max(policy.firstDay, ReminderCivilDay.current(now, zone: base.calendar.timeZone) ?? policy.firstDay)
        if policy.mode == .nextDay {
            while reviewStart > policy.firstDay, let previous = reviewStart.adding(-1), excluded(previous) || base.instant(on: previous) == nil { reviewStart = previous }
        }
        let floor = policy.mode == .skip ? max(now, Date(timeIntervalSince1970: Double(policy.firstDay.serial * 86400 - 36 * 3600))) : Date(timeIntervalSince1970: Double(reviewStart.serial * 86400 - 36 * 3600))
        var cursor = floor, result = Set<Date>(), examined = 0
        var initial: [Date]? = ReminderCivilDay.current(floor, zone: base.calendar.timeZone) == nil ? [base.first] : nil
        while examined < 370 {
            let nominal = initial ?? base.dates(after: cursor, limit: 60)
            let wasInitial = initial != nil; initial = nil
            guard !nominal.isEmpty else { break }
            var ended = false
            for instant in nominal {
                examined += 1; cursor = instant
                guard var day = ReminderCivilDay.current(instant, zone: base.calendar.timeZone) else { continue }
                if day > policy.lastDay { ended = true; break }
                guard day >= policy.firstDay else { continue }
                if excluded(day) {
                    if policy.mode == .skip { continue }
                    while (excluded(day) || base.instant(on: day) == nil), day < policy.lastDay { day = day.adding(1)! }
                    if excluded(day) { continue }
                }
                if let end = ReminderCivilDay(base.rule.string("endDate")), day > end { continue }
                guard let moved = base.instant(on: day), moved > now else { continue }
                result.insert(moved)
                if result.count >= min(60, limit) { return result.sorted() }
            }
            if ended || (!wasInitial && nominal.count < 60) { break }
        }
        return Array(result.sorted().prefix(min(60, limit)))
    }
    func contains(_ date: Date) -> Bool { date.timeIntervalSince1970.isFinite && dates(after: date.addingTimeInterval(-0.001), limit: 1).first == date }
    var semanticFields: [String] { base.semanticFields + ["reviewed-holidays"] + policy.semanticFields }
}

/// A bounded all-day iCalendar review, independent of network/Calendar permissions.
/// Unsupported recurrence/override semantics fail the entire review, never a partial calendar.
struct HolidayCalendarFile: Sendable {
    static let maximumBytes = 1_000_000
    struct Day: Equatable, Sendable { let date: String; let names: [String] }
    let year: Int
    let name: String
    let digest: String
    let days: [Day]
    private struct Property { let name: String; let parameters: [String: String]; let value: String }
    private static func failure(_ detail: String) -> AppFailure { AppFailure(message: detail) }
    static func read(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumBytes { throw failure("Choose a holiday calendar no larger than 1 MB.") }
        let coordinator = NSFileCoordinator(); var coordination: NSError?, result: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordination) { url in
            result = Result {
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                var data = Data()
                while data.count <= maximumBytes {
                    guard let next = try file.read(upToCount: min(65_536, maximumBytes + 1 - data.count)), !next.isEmpty else { break }
                    data.append(next)
                }
                guard data.count <= maximumBytes else { throw failure("Choose a holiday calendar no larger than 1 MB.") }
                return data
            }
        }
        if let coordination { throw coordination }
        guard let result else { throw failure("Download the calendar file, then choose it again.") }
        return try result.get()
    }
    private static func property(_ line: String) throws -> Property {
        var quoted = false; var separator: String.Index?
        for i in line.indices {
            if line[i] == "\"" { quoted.toggle() }
            if line[i] == ":" && !quoted { separator = i; break }
        }
        guard let separator, !quoted else { throw failure("The calendar has a malformed property.") }
        var header: [String] = [], field = "", inQuotes = false
        for c in line[..<separator] {
            if c == "\"" { inQuotes.toggle() }
            if c == ";" && !inQuotes { header.append(field); field = "" } else { field.append(c) }
        }
        header.append(field)
        let name = header[0].uppercased()
        guard name.range(of: "^[A-Z0-9-]+$", options: .regularExpression) != nil else { throw failure("The calendar has an invalid property name.") }
        var parameters: [String: String] = [:]
        for field in header.dropFirst() {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw failure("The calendar has a malformed parameter.") }
            let key = parts[0].uppercased(); guard parameters[key] == nil else { throw failure("The calendar repeats a property parameter.") }
            parameters[key] = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return Property(name: name, parameters: parameters, value: String(line[line.index(after: separator)...]))
    }
    private static func civil(_ value: String) throws -> ReminderCivilDay {
        guard value.range(of: "^[0-9]{8}$", options: .regularExpression) != nil else { throw failure("Use an all-day holiday calendar, with date-only events.") }
        let key = String(value.prefix(4)) + "-" + String(value.dropFirst(4).prefix(2)) + "-" + String(value.suffix(2))
        guard let day = ReminderCivilDay(key) else { throw failure("The calendar contains an invalid date.") }
        return day
    }
    private static func dateProperty(_ property: Property) throws -> [ReminderCivilDay] {
        guard property.parameters["VALUE"]?.uppercased() == "DATE", property.parameters["TZID"] == nil,
              Set(property.parameters.keys).isSubset(of: ["VALUE"]) else { throw failure("Use a calendar whose holiday events are all-day dates.") }
        return try property.value.split(separator: ",", omittingEmptySubsequences: false).map { try civil(String($0)) }
    }
    private static func text(_ value: String) throws -> String {
        var result = "", escaping = false
        for c in value {
            if escaping {
                switch c { case "n", "N": result.append(" "); case "\\", ",", ";": result.append(c); default: throw failure("The calendar contains an invalid text escape.") }
                escaping = false
            } else if c == "\\" { escaping = true } else { result.append(c) }
        }
        guard !escaping else { throw failure("The calendar contains an incomplete text escape.") }
        return String(result.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
    }
    init(data: Data, year: Int) throws {
        guard data.count <= Self.maximumBytes, (1...9999).contains(year) else { throw Self.failure("Choose a holiday calendar up to 1 MB and a year from 1 to 9999.") }
        // Unfold bytes before UTF-8 decoding, including folds within a multibyte character.
        let bytes = Array(data); var unfolded = Data(), index = 0
        while index < bytes.count {
            let newline = bytes[index] == 13 && index + 1 < bytes.count && bytes[index + 1] == 10 ? 2 : bytes[index] == 10 ? 1 : 0
            if newline > 0, index + newline < bytes.count, bytes[index + newline] == 32 || bytes[index + newline] == 9 { index += newline + 1 }
            else { unfolded.append(bytes[index]); index += 1 }
        }
        guard var source = String(data: unfolded, encoding: .utf8) else { throw Self.failure("Choose a UTF-8 holiday calendar.") }
        if source.first == "\u{feff}" { source.removeFirst() }
        source = source.replacingOccurrences(of: "\r\n", with: "\n")
        guard !source.contains("\r"), !source.contains("\0") else { throw Self.failure("The calendar contains invalid line endings or characters.") }
        var lines: [String] = []
        for line in source.components(separatedBy: "\n") where !line.isEmpty {
            if line.first == " " || line.first == "\t" {
                guard !lines.isEmpty else { throw Self.failure("The calendar begins with an incomplete folded line.") }
                lines[lines.count - 1] += line.dropFirst()
            } else { lines.append(line) }
            guard lines.count <= 30_000, lines.last!.utf8.count <= 16_384 else { throw Self.failure("The calendar has too many or excessively long properties.") }
        }
        var stack: [String] = [], events: [[Property]] = [], event: [Property] = [], metadata: [String: String] = [:], finished = false
        for line in lines {
            let p = try Self.property(line)
            if p.name == "BEGIN" {
                guard !finished, stack.count < 8 else { throw Self.failure("The calendar has invalid component nesting.") }
                if stack.isEmpty { guard p.value == "VCALENDAR" else { throw Self.failure("Choose an iCalendar (.ics) file.") } }
                else if stack == ["VCALENDAR"] { guard ["VEVENT", "VTIMEZONE"].contains(p.value) else { throw Self.failure("Use an event calendar, not invitations or to-do records.") } }
                else if stack.last == "VEVENT" { guard p.value == "VALARM" else { throw Self.failure("The calendar has an unsupported nested event.") } }
                stack.append(p.value); if p.value == "VEVENT" { event = [] }
            } else if p.name == "END" {
                guard stack.last == p.value else { throw Self.failure("The calendar has an unmatched component.") }
                if p.value == "VEVENT" { events.append(event); guard events.count <= 4000 else { throw Self.failure("Review a calendar with at most 4,000 events.") } }
                stack.removeLast(); if stack.isEmpty { finished = true }
            } else if stack == ["VCALENDAR"] {
                if ["VERSION", "METHOD", "X-WR-CALNAME"].contains(p.name) { guard metadata[p.name] == nil else { throw Self.failure("The calendar repeats its metadata.") }; metadata[p.name] = p.value }
            } else if stack == ["VCALENDAR", "VEVENT"] { event.append(p) }
            else if stack.isEmpty { throw Self.failure("The calendar contains data outside its calendar component.") }
        }
        guard finished, stack.isEmpty, metadata["VERSION"] == "2.0", metadata["METHOD"] == nil || metadata["METHOD"] == "PUBLISH" else { throw Self.failure("Use a complete published iCalendar 2.0 holiday calendar.") }
        let first = ReminderCivilDay(String(format: "%04d-01-01", year))!, last = ReminderCivilDay(String(format: "%04d-12-31", year))!
        var calendar: [String: Set<String>] = [:], identifiers = Set<String>(), work = 0
        for properties in events {
            func one(_ key: String) throws -> Property? {
                let values = properties.filter { $0.name == key }; guard values.count <= 1 else { throw Self.failure("An event repeats " + key + ".") }; return values.first
            }
            guard let uid = try one("UID")?.value, !uid.isEmpty, uid.utf8.count <= 1024, identifiers.insert(uid).inserted else { throw Self.failure("The calendar has missing or repeated event identities. Export its current expanded dates first.") }
            guard try one("RECURRENCE-ID") == nil, try one("EXRULE") == nil else { throw Self.failure("This calendar uses recurrence overrides that cannot be reviewed safely. Export its expanded all-day dates instead.") }
            let status = try one("STATUS")?.value
            if status == "CANCELLED" { continue }
            guard status == nil || status == "CONFIRMED" else { throw Self.failure("Use a confirmed holiday calendar; tentative events need a separate review.") }
            guard let startProperty = try one("DTSTART"), let start = try Self.dateProperty(startProperty).only else { throw Self.failure("Each holiday needs one all-day start date.") }
            var duration = 1
            if let endProperty = try one("DTEND") {
                guard try one("DURATION") == nil, let end = try Self.dateProperty(endProperty).only else { throw Self.failure("Each holiday needs a single end date or duration.") }
                duration = end.serial - start.serial
            } else if let p = try one("DURATION") {
                let value = p.value
                guard value.range(of: "^P[0-9]{1,3}[DW]$", options: .regularExpression) != nil, let n = Int(value.dropFirst().dropLast()) else { throw Self.failure("Use whole-day holiday durations.") }
                duration = n * (value.last == "W" ? 7 : 1)
            }
            guard (1...366).contains(duration) else { throw Self.failure("Holiday events must last between 1 and 366 days.") }
            let name = try one("SUMMARY").map { try Self.text($0.value) } ?? "Holiday"
            var starts = Set([start])
            if let rule = try one("RRULE") { starts.formUnion(try Self.expand(rule.value, start: start, through: last, work: &work)) }
            for p in properties where p.name == "RDATE" { starts.formUnion(try Self.dateProperty(p)) }
            for p in properties where p.name == "EXDATE" { starts.subtract(try Self.dateProperty(p)) }
            for start in starts {
                if start > last || start.serial + duration - 1 < first.serial { continue }
                for serial in max(first.serial, start.serial)...min(last.serial, start.serial + duration - 1) {
                    let key = ReminderCivilDay(serial: serial)!.key
                    calendar[key, default: []].insert(name.isEmpty ? "Holiday" : name)
                    guard calendar[key]!.count <= 16 else { throw Self.failure("Use a dedicated holiday calendar with at most 16 events on each date.") }
                }
            }
        }
        self.year = year; name = try metadata["X-WR-CALNAME"].map(Self.text) ?? "Holiday calendar"
        digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        days = calendar.keys.sorted().map { Day(date: $0, names: calendar[$0]!.sorted()) }
    }
    private static func expand(_ text: String, start: ReminderCivilDay, through end: ReminderCivilDay, work: inout Int) throws -> [ReminderCivilDay] {
        var rule: [String: String] = [:]
        for token in text.split(separator: ";", omittingEmptySubsequences: false) {
            let pair = token.split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2, rule[String(pair[0])] == nil else { throw failure("The holiday repeat rule is malformed.") }
            rule[String(pair[0])] = String(pair[1])
        }
        guard Set(rule.keys).isSubset(of: ["FREQ", "INTERVAL", "BYMONTH", "BYMONTHDAY", "BYDAY", "BYSETPOS", "COUNT", "UNTIL", "WKST"]),
              let frequency = rule["FREQ"], ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"].contains(frequency),
              rule["WKST"] == nil || rule["WKST"] == "MO", rule["COUNT"] == nil || rule["UNTIL"] == nil,
              let interval = Int(rule["INTERVAL"] ?? "1"), (1...999).contains(interval),
              rule["COUNT"] == nil || (Int(rule["COUNT"]!) != nil && (1...100_000).contains(Int(rule["COUNT"]!)!)) else { throw failure("This calendar uses an unsupported holiday repeat rule. Export expanded all-day dates instead.") }
        func integers(_ key: String, allowed: ClosedRange<Int>, negative: Bool = false) throws -> [Int]? {
            guard let value = rule[key] else { return nil }
            let parts = value.split(separator: ",", omittingEmptySubsequences: false), values = parts.compactMap { Int($0) }
            guard !values.isEmpty, values.count == parts.count, values.allSatisfy({ allowed.contains($0) || (negative && allowed.contains(-$0)) }) else { throw failure("The calendar has an invalid holiday repeat value.") }
            return values
        }
        let months = try integers("BYMONTH", allowed: 1...12), monthDays = try integers("BYMONTHDAY", allowed: 1...31, negative: true)
        let positions = try integers("BYSETPOS", allowed: 1...366, negative: true)
        guard positions == nil || (["MONTHLY", "YEARLY"].contains(frequency) && (rule["BYDAY"] != nil || monthDays != nil)) else { throw failure("Export expanded dates for this holiday position rule.") }
        let weekdays = ["SU": 0, "MO": 1, "TU": 2, "WE": 3, "TH": 4, "FR": 5, "SA": 6]
        var days: [(Int?, Int)] = []
        if let value = rule["BYDAY"] {
            for item in value.split(separator: ",", omittingEmptySubsequences: false) {
                guard item.count >= 2, let weekday = weekdays[String(item.suffix(2))] else { throw failure("The calendar has an invalid repeated weekday.") }
                let prefix = item.dropLast(2), ordinal = prefix.isEmpty ? nil : Int(prefix)
                guard prefix.isEmpty || (ordinal != nil && ordinal != 0 && (-5...5).contains(ordinal!)), ordinal == nil || (["MONTHLY", "YEARLY"].contains(frequency)), !(frequency == "YEARLY" && ordinal != nil && months == nil) else { throw failure("Export expanded dates for this holiday weekday rule.") }
                days.append((ordinal, weekday))
            }
        }
        guard !(frequency == "WEEKLY" && monthDays != nil) else { throw failure("The calendar combines unsupported weekly repeat fields.") }
        let until = try rule["UNTIL"].map(civil)
        guard until == nil || until! >= start else { throw failure("The holiday repeat end precedes its start.") }
        let maximum = min(end, until ?? end), count = rule["COUNT"].flatMap(Int.init)
        if start > maximum { return [] }
        var day = start, result: [ReminderCivilDay] = [], consumed = 0
        var candidates: [ReminderCivilDay] = [], group: Int?
        let expansionEnd: ReminderCivilDay
        if positions != nil {
            day = ReminderCivilDay(String(format: "%04d-%02d-01", start.year, frequency == "YEARLY" ? 1 : start.month))!
            let month = frequency == "YEARLY" ? 12 : maximum.month
            expansionEnd = ReminderCivilDay(String(format: "%04d-%02d-%02d", maximum.year, month, ReminderCivilDay.monthLength(maximum.year, month)))!
        } else { expansionEnd = maximum }
        func flush() {
            guard let positions else { return }
            let selected = Set(positions.map { $0 > 0 ? $0 - 1 : candidates.count + $0 })
            for (index, value) in candidates.enumerated() where selected.contains(index) && value >= start && value <= maximum {
                if let count, consumed >= count { break }; result.append(value); consumed += 1
            }
            candidates = []
        }
        while day <= expansionEnd {
            if positions != nil {
                let key = frequency == "YEARLY" ? day.year : day.year * 12 + day.month
                if group != key { flush(); group = key; if let count, consumed >= count { break } }
            }
            work += 1; guard work <= 2_000_000 else { throw failure("This calendar needs too much recurrence expansion. Export the selected year’s expanded dates instead.") }
            let yearOffset = day.year - start.year, monthOffset = yearOffset * 12 + day.month - start.month, serialOffset = day.serial - start.serial
            let startMonday = start.serial - (start.weekday + 6) % 7, monday = day.serial - (day.weekday + 6) % 7
            let periodMatches = frequency == "DAILY" ? serialOffset % interval == 0 : frequency == "WEEKLY" ? ((monday - startMonday) / 7) % interval == 0 : frequency == "MONTHLY" ? monthOffset % interval == 0 : yearOffset % interval == 0
            let length = ReminderCivilDay.monthLength(day.year, day.month)
            let monthMatches = months?.contains(day.month) ?? !(frequency == "YEARLY" && monthDays == nil && days.isEmpty && day.month != start.month)
            let dayMatches = monthDays?.contains(where: { $0 > 0 ? day.day == $0 : day.day == length + $0 + 1 }) ?? !(["MONTHLY", "YEARLY"].contains(frequency) && days.isEmpty && day.day != start.day)
            let weekdayMatches = days.isEmpty ? (frequency != "WEEKLY" || day.weekday == start.weekday) : days.contains { ordinal, weekday in
                day.weekday == weekday && (ordinal == nil || (ordinal! > 0 ? (day.day - 1) / 7 + 1 == ordinal! : -((length - day.day) / 7 + 1) == ordinal!))
            }
            if periodMatches && monthMatches && dayMatches && weekdayMatches {
                if positions != nil { candidates.append(day) }
                else { consumed += 1; result.append(day); if let count, consumed >= count { break } }
            }
            guard let next = day.adding(1) else { break }; day = next
        }
        flush()
        guard start > end || result.first == start else { throw failure("The holiday start does not match its repeat rule. Export expanded dates instead.") }
        return result
    }
    func policy(source: String, region: String, mode: ReminderHolidayPolicy.Mode, avoidWeekends: Bool) -> ReminderHolidayPolicy? {
        ReminderHolidayPolicy(raw: ["version": .number(1), "year": .number(Double(year)), "dates": .array(days.map { .string($0.date) }), "source": .string(source.trimmingCharacters(in: .whitespacesAndNewlines)), "region": .string(region.trimmingCharacters(in: .whitespacesAndNewlines)), "digest": .string(digest), "mode": .string(mode.rawValue), "avoid_weekends": .bool(avoidWeekends)])
    }
}
private extension Array { var only: Element? { count == 1 ? first : nil } }

/// Public country calendars are fetched only when requested, then reviewed as an offline snapshot.
/// A saved policy never depends on a later network response to calculate an alert.
enum CountryHolidayCalendar {
    struct Country: Decodable, Equatable, Identifiable, Sendable {
        let countryCode: String
        let name: String
        var id: String { countryCode }
    }
    struct Origin: Equatable, Sendable {
        let country: String
        let subdivision: String?
        init?(raw: [String: JSON]) {
            guard raw["provider"] == .string("nager-v4"), let country = raw["country"]?.text, CountryHolidayCalendar.validCountry(country) else { return nil }
            let subdivision = raw["subdivision"]?.text
            guard raw["subdivision"] == nil || subdivision != nil,
                  subdivision == nil || CountryHolidayCalendar.validSubdivision(subdivision!, country: country) else { return nil }
            self.country = country; self.subdivision = subdivision
        }
        var raw: [String: JSON] {
            var raw: [String: JSON] = ["provider": .string("nager-v4"), "country": .string(country)]
            if let subdivision { raw["subdivision"] = .string(subdivision) }; return raw
        }
    }
    struct Snapshot: Sendable {
        let year: Int
        let country: String
        let digest: String
        let holidays: [Holiday]
        var subdivisions: [String] { Array(Set(holidays.filter { $0.holidayTypes.contains("Public") }.flatMap { $0.subdivisionCodes ?? [] })).sorted() }
        func days(subdivision: String?) -> [HolidayCalendarFile.Day] {
            var values: [String: Set<String>] = [:]
            for holiday in holidays where holiday.holidayTypes.contains("Public") && (holiday.nationalHoliday || subdivision.map { holiday.subdivisionCodes?.contains($0) == true } == true) {
                values[holiday.date, default: []].insert(holiday.name)
            }
            return values.keys.sorted().map { .init(date: $0, names: values[$0]!.sorted()) }
        }
    }
    struct Holiday: Decodable, Sendable {
        let date: String
        let name: String
        let countryCode: String
        let nationalHoliday: Bool
        let subdivisionCodes: [String]?
        let holidayTypes: [String]
    }
    static func validCountry(_ code: String) -> Bool { code.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil }
    static func validSubdivision(_ code: String, country: String) -> Bool {
        code.hasPrefix(country + "-") && code.range(of: "^[A-Z]{2}-[A-Z0-9]{1,3}$", options: .regularExpression) != nil
    }
    static func countries(data: Data) throws -> [Country] {
        guard data.count <= HolidayCalendarFile.maximumBytes else { throw failure }
        let result = try JSONDecoder().decode([Country].self, from: data)
        guard !result.isEmpty, result.count <= 300, Set(result.map(\.countryCode)).count == result.count,
              result.allSatisfy({ validCountry($0.countryCode) && validName($0.name) }) else { throw failure }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func snapshot(data: Data, year: Int, country: String) throws -> Snapshot {
        guard (1...9999).contains(year), validCountry(country), data.count <= HolidayCalendarFile.maximumBytes else { throw failure }
        let values = try JSONDecoder().decode([Holiday].self, from: data)
        let types: Set<String> = ["Public", "Bank", "School", "Authorities", "Optional", "Observance"]
        guard values.count <= 1000, values.allSatisfy({ value in
            guard let day = ReminderCivilDay(value.date), day.year == year, value.countryCode == country, validName(value.name),
                  !value.holidayTypes.isEmpty, value.holidayTypes.count <= 6, Set(value.holidayTypes).isSubset(of: types),
                  (value.subdivisionCodes?.count ?? 0) <= 300,
                  (value.subdivisionCodes ?? []).allSatisfy({ validSubdivision($0, country: country) }),
                  value.nationalHoliday || !(value.subdivisionCodes ?? []).isEmpty else { return false }
            return true
        }) else { throw failure }
        return Snapshot(year: year, country: country, digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), holidays: values)
    }
    private static func validName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 160 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private static var failure: AppFailure { AppFailure(message: "The holiday service returned an unsupported calendar. Your saved reminder has not changed. Try again or use a calendar file.") }
    static func request(country: String? = nil, year: Int? = nil) throws -> URLRequest {
        let path: String
        if let country, let year, validCountry(country), (1...9999).contains(year) { path = "Holidays/\(country)/\(year)" }
        else if country == nil, year == nil { path = "Countries/Available" }
        else { throw failure }
        var request = URLRequest(url: URL(string: "https://nagerholidays.com/api/v4/" + path)!)
        request.timeoutInterval = 25; request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Taskfold/1.0 (holiday calendars)", forHTTPHeaderField: "User-Agent")
        return request
    }
    static func fetch(_ request: URLRequest) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == request.url, http.mimeType?.lowercased() == "application/json",
              http.expectedContentLength <= HolidayCalendarFile.maximumBytes else {
            throw AppFailure(message: "The holiday service is unavailable. Try again later; your saved dates are unchanged.")
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < HolidayCalendarFile.maximumBytes else { throw failure }
            data.append(byte)
        }
        return data
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
