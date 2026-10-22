import Foundation
import CryptoKit
import UserNotifications

/// Version 1 uses absolute instants or elapsed minutes relative to the planned time.
/// Version 2 adds independent local calendar schedules; old clients preserve them.
/// Version 3 adds local-only elapsed interval schedules; older clients preserve the opaque row.
/// Unknown rows and additional fields survive edits, backup and sync unchanged.
struct ReminderSpec: Equatable, Identifiable, Sendable {
    static let plannedID = "00000000-0000-4000-8000-000000000001"
    static let maximum = 20
    var raw: [String: JSON]
    var id: String { raw["id"]?.text.lowercased() ?? "" }
    var enabled: Bool { raw["enabled"]?.flag ?? true }
    var offset: Int? {
        guard case .number(let value)? = raw["offset_minutes"], value.isFinite,
              value.rounded() == value, (-10080...10080).contains(value) else { return nil }
        return Int(value)
    }
    var absolute: Date? { TaskPlanning.instant(raw["at"]?.text ?? "") }
    var kind: String { raw["kind"]?.text ?? "" }
    var schedule: ReminderCalendarSchedule? { kind == "recurring" ? ReminderCalendarSchedule(raw: raw) : nil }
    var holidaySchedule: ReminderHolidaySchedule? { (raw["version"] == .number(5) || raw["version"] == .number(4) && raw["schedule_version"] == .number(5)) ? ReminderHolidaySchedule(raw: raw) : nil }
    var intervalSchedule: ReminderIntervalSchedule? { kind == "interval" ? ReminderIntervalSchedule(raw: raw["interval_schedule"]?.object ?? [:]) : nil }
    func settingHolidayPolicy(_ policy: ReminderHolidayPolicy?) -> ReminderSpec? {
        let sensitive = timeSensitive
        guard let base = settingTimeSensitive(false) else { return nil }
        var fields = base.raw
        if let policy {
            guard base.kind == "recurring", base.locallyEditable else { return nil }
            var payload = fields["holiday_policy"]?.object ?? [:]
            if policy.origin == nil { payload.removeValue(forKey: "origin") }
            for (key, value) in policy.raw {
                if key == "origin", let origin = policy.origin, let previous = payload[key], CountryHolidayCalendar.Origin(raw: previous.object) == origin {
                    var preserved = previous.object
                    for (field, updated) in value.object { preserved[field] = updated }
                    payload[key] = .object(preserved)
                } else { payload[key] = value }
            }
            fields["version"] = .number(5); fields["holiday_policy"] = .object(payload)
        } else {
            if fields["version"] == .number(5) { fields["version"] = .number(2) }
            fields.removeValue(forKey: "holiday_policy")
        }
        return ReminderSpec(row: .object(fields))?.settingTimeSensitive(sensitive)
    }
    var timeSensitive: Bool { raw["version"] == .number(4) && raw["presentation"] == .string("time-sensitive") }
    /// Version 4 wraps an otherwise validated local schedule. Previous readers keep it opaque.
    func settingTimeSensitive(_ value: Bool) -> ReminderSpec? {
        var fields = raw
        if timeSensitive { fields["version"] = fields["schedule_version"] }
        fields.removeValue(forKey: "presentation"); fields.removeValue(forKey: "schedule_version")
        guard let base = ReminderSpec(row: .object(fields)) else { return nil }
        guard value else { return base }
        guard base.locallyEditable, base.id != Self.plannedID else { return nil }
        fields["schedule_version"] = fields["version"]; fields["version"] = .number(4)
        fields["presentation"] = .string("time-sensitive")
        return ReminderSpec(row: .object(fields))
    }
    init?(row: JSON) {
        let row = row.object
        if row["version"] == .number(4) {
            guard row["presentation"] == .string("time-sensitive"),
                  [JSON.number(1), .number(2), .number(3), .number(5)].contains(row["schedule_version"] ?? .null),
                  row["channels"] == .array([.string("local")]),
                  row["id"]?.text.lowercased() != Self.plannedID else { return nil }
            var base = row; base["version"] = row["schedule_version"]
            base.removeValue(forKey: "presentation"); base.removeValue(forKey: "schedule_version")
            guard let validated = ReminderSpec(row: .object(base)) else { return nil }
            self = validated; raw = row; return
        }
        guard [JSON.number(1), .number(2), .number(3), .number(5)].contains(row["version"] ?? .null), UUID(uuidString: row["id"]?.text ?? "") != nil,
              row["enabled"] == nil || row["enabled"] == .bool(true) || row["enabled"] == .bool(false),
              case .array(let channels)? = row["channels"], !channels.isEmpty,
              channels.allSatisfy({ ["local", "push", "email"].contains($0.text) }) else { return nil }
        raw = row
        switch kind {
        case "relative": guard row["version"] == .number(1), row["anchor"] == .string("planned"), offset != nil else { return nil }
        case "absolute": guard row["version"] == .number(1), absolute != nil, TimeZone(identifier: row["time_zone"]?.text ?? "") != nil else { return nil }
        case "recurring": guard [JSON.number(2), .number(5)].contains(row["version"] ?? .null), row["channels"] == .array([.string("local")]), schedule != nil, row["version"] != .number(5) || holidaySchedule != nil else { return nil }
        case "interval": guard row["version"] == .number(3), row["channels"] == .array([.string("local")]), intervalSchedule != nil else { return nil }
        default: return nil
        }
        if id == Self.plannedID && (kind != "relative" || offset != 0) { return nil }
    }
    static func relative(_ minutes: Int, id: String = UUID().uuidString.lowercased(), enabled: Bool = true) -> ReminderSpec {
        ReminderSpec(row: .object(["version": .number(1), "id": .string(id), "kind": .string("relative"), "anchor": .string("planned"), "offset_minutes": .number(Double(minutes)), "channels": .array([.string("local")]), "enabled": .bool(enabled)]))!
    }
    static func absolute(_ date: Date, id: String = UUID().uuidString.lowercased(), zone: String = TimeZone.current.identifier) -> ReminderSpec {
        ReminderSpec(row: .object(["version": .number(1), "id": .string(id), "kind": .string("absolute"), "at": .string(ISO8601DateFormatter().string(from: date)), "time_zone": .string(zone), "channels": .array([.string("local")]), "enabled": .bool(true)]))!
    }
    static func recurring(_ schedule: ReminderCalendarSchedule, id: String = UUID().uuidString.lowercased(), enabled: Bool = true) -> ReminderSpec {
        var raw = schedule.raw
        raw.merge(["version": .number(2), "id": .string(id), "kind": .string("recurring"), "channels": .array([.string("local")]), "enabled": .bool(enabled)]) { _, new in new }
        return ReminderSpec(row: .object(raw))!
    }
    static func interval(_ schedule: ReminderIntervalSchedule, id: String = UUID().uuidString.lowercased(), enabled: Bool = true) -> ReminderSpec {
        ReminderSpec(row: .object(["version": .number(3), "id": .string(id), "kind": .string("interval"), "channels": .array([.string("local")]), "enabled": .bool(enabled), "interval_schedule": .object(schedule.raw)]))!
    }
    var semanticKey: String {
        if let holidaySchedule { return "holidays|" + holidaySchedule.semanticFields.map { "\($0.utf8.count):\($0)" }.joined() }
        if let intervalSchedule { return "interval|" + intervalSchedule.semanticFields.map { "\($0.utf8.count):\($0)" }.joined() }
        if let schedule { return "recurring|" + schedule.semanticFields.map { "\($0.utf8.count):\($0)" }.joined() }
        return kind + "|" + (kind == "relative" ? String(offset ?? 0) : absolute.map(ReminderSignature.milliseconds) ?? "")
    }
    var local: Bool { raw["channels"]?.list.contains(.string("local")) == true }
    var locallyEditable: Bool { raw["channels"] == .array([.string("local")]) }
    var label: String {
        if let holidaySchedule { return holidaySchedule.base.summary + " · " + holidaySchedule.base.time + (holidaySchedule.policy.mode == .skip ? " · skip holidays" : " · move around holidays") }
        if let intervalSchedule { return intervalSchedule.summary }
        if let schedule { return schedule.summary + " · " + schedule.time }
        if kind == "absolute", let date = absolute { return date.formatted(date: .abbreviated, time: .shortened) }
        guard let offset else { return "Unsupported reminder" }
        if offset == 0 { return "At planned time" }
        return "\(abs(offset)) min \(offset < 0 ? "before" : "after")"
    }
    func date(task: Record, calendar: Calendar, now: Date = Date()) -> Date? {
        if let holidaySchedule { return holidaySchedule.dates(after: now, limit: 1).first }
        if let intervalSchedule { return intervalSchedule.dates(after: now, limit: 1).first }
        if let schedule { return schedule.dates(after: now, limit: 1).first }
        if kind == "absolute" { return absolute }
        guard let anchor = Self.plannedDate(task, calendar: calendar), let offset else { return nil }
        return anchor.addingTimeInterval(Double(offset) * 60)
    }
    static func plannedDate(_ task: Record, calendar: Calendar) -> Date? {
        if !task.string("due_time").isEmpty { return TaskPlanning.start(task, calendar: calendar) }
        guard let day = Dates.parse(task.string("due_date"), calendar: calendar) else { return nil }
        return TaskPlanning.wallTime(day: day, hour: 8, minute: 0, calendar: calendar)
    }
    static func rows(_ task: Record) -> [JSON] { task["reminder_specs"].list }
    static func plannedEnabled(_ task: Record) -> Bool {
        let rows = rows(task)
        return rows.isEmpty || rows.contains { guard let spec = ReminderSpec(row: $0) else { return false }; return spec.id == plannedID && spec.enabled && spec.local }
    }
    @discardableResult static func setPlanned(_ enabled: Bool, task: inout Record) -> Bool {
        var rows = rows(task)
        if enabled && duplicates(relative(0, id: plannedID), in: rows, excluding: plannedID) { return false }
        if let index = rows.firstIndex(where: { $0.object["id"]?.text.lowercased() == plannedID }), var spec = ReminderSpec(row: rows[index]), spec.locallyEditable {
            spec.raw["enabled"] = .bool(enabled); spec.raw.removeValue(forKey: ReminderAutomatic.placeholder); rows[index] = .object(spec.raw)
        } else if !rows.contains(where: { $0.object["id"]?.text.lowercased() == plannedID }), rows.count < maximum {
            rows.append(.object(relative(0, id: plannedID, enabled: enabled).raw))
        } else { return false }
        task["reminder_specs"] = .array(rows)
        return true
    }
    static func duplicates(_ spec: ReminderSpec, in rows: [JSON], excluding: String? = nil) -> Bool {
        guard spec.enabled && spec.local else { return false }
        return rows.compactMap(ReminderSpec.init(row:)).contains { other in
            guard other.id != excluding, other.enabled && other.local, other.kind == spec.kind else { return false }
            return other.semanticKey == spec.semanticKey
        }
    }
    static func append(_ spec: ReminderSpec, task: inout Record) -> Bool {
        var values = rows(task)
        // Materialize the legacy default before introducing an explicit override.
        if values.isEmpty { values = [ReminderAutomatic.legacyPlaceholder] }
        guard values.count < maximum, !values.contains(where: { $0.object["id"]?.text.lowercased() == spec.id }),
              !duplicates(spec, in: values) else { return false }
        values.append(.object(spec.raw)); task["reminder_specs"] = .array(values); return true
    }
    /// Replace current supported settings while retaining extensions of both the row
    /// and its calendar rule. Old known rule fields cannot leak into a new rule.
    func mergingSettings(from replacement: ReminderSpec) -> ReminderSpec {
        var result = self
        for (key, value) in replacement.raw { result.raw[key] = value }
        if kind == "recurring", replacement.kind == "recurring" {
            let known = Set(["type", "interval", "daysOfWeek", "dayOfMonth", "daysOfMonth", "monthOfYear", "weekday", "weekdayOrdinal", "count", "endDate", "fromCompletion"])
            var pattern = replacement.raw["recurrence"]?.object ?? [:]
            for (key, value) in raw["recurrence"]?.object ?? [:] where !known.contains(key) { pattern[key] = value }
            result.raw["recurrence"] = .object(pattern)
        }
        if kind == "interval", replacement.kind == "interval" {
            var payload = replacement.raw["interval_schedule"]?.object ?? [:]
            let known = Set(["start_ms", "every_minutes", "count", "until_ms"])
            for (key, value) in raw["interval_schedule"]?.object ?? [:] where !known.contains(key) { payload[key] = value }
            result.raw["interval_schedule"] = .object(payload)
        }
        if raw["holiday_policy"] != nil, replacement.raw["holiday_policy"]?.object.isEmpty == false {
            let known = Set(["version", "year", "dates", "source", "region", "digest", "mode", "avoid_weekends"])
            var payload = replacement.raw["holiday_policy"]!.object
            for (key, value) in raw["holiday_policy"]!.object where !known.contains(key) { payload[key] = value }
            result.raw["holiday_policy"] = .object(payload)
        }
        return result
    }
    static func successorRows(_ rows: [JSON]) -> [JSON] {
        guard !rows.isEmpty else { return [] }
        let kept = rows.filter { ReminderSpec(row: $0)?.kind != "absolute" }
        return kept.isEmpty ? [.object(relative(0, id: plannedID, enabled: false).raw)] : kept
    }
}


/// Proleptic Gregorian civil dates. UTC seconds are an arithmetic representation,
/// never the reminder's actual fire instant. No locale cutover or skipped zone day
/// may change weekday/interval/count semantics.
struct ReminderCivilDay: Comparable, Hashable {
    let year: Int, month: Int, day: Int
    var key: String { String(format: "%04d-%02d-%02d", year, month, day) }
    static func monthLength(_ year: Int, _ month: Int) -> Int {
        if month == 2 { return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28 }
        return [4, 6, 9, 11].contains(month) ? 30 : 31
    }
    init?(_ key: String) {
        guard key.count == 10, key.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]), (1...12).contains(parts[1]), (1...Self.monthLength(parts[0], parts[1])).contains(parts[2]) else { return nil }
        year = parts[0]; month = parts[1]; day = parts[2]
    }
    var serial: Int {
        let y = year - (month <= 2 ? 1 : 0), era = y / 400, yo = y - era * 400
        let m = month + (month > 2 ? -3 : 9)
        return era * 146097 + yo * 365 + yo / 4 - yo / 100 + (153 * m + 2) / 5 + day - 1 - 719468
    }
    init?(serial: Int) {
        let z = serial + 719468
        guard z >= 306, z <= 3652364 else { return nil }
        let era = z / 146097, doe = z - era * 146097
        let yo = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yo + era * 400, doy = doe - (yo * 365 + yo / 4 - yo / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1, m = mp + (mp < 10 ? 3 : -9)
        let yr = y + (m <= 2 ? 1 : 0)
        guard (1...9999).contains(yr) else { return nil }
        year = yr; month = m; day = d
    }
    var weekday: Int { ((serial + 4) % 7 + 7) % 7 }
    func adding(_ days: Int) -> Self? { Self(serial: serial + days) }
    static func < (a: Self, b: Self) -> Bool { a.serial < b.serial }
    static func monthDay(year: Int, month: Int, rule: Record, fallback: Int) -> Self? {
        guard (1...9999).contains(year), (1...12).contains(month) else { return nil }
        let length = monthLength(year, month)
        var day = min(rule["dayOfMonth"] == .null ? fallback : rule["dayOfMonth"].integer, length)
        if let ordinal = Recurrence.number(rule["weekdayOrdinal"], in: -1...5), let weekday = Recurrence.number(rule["weekday"], in: 0...6) {
            let edge = Self(String(format: "%04d-%02d-%02d", year, month, ordinal == -1 ? length : 1))!
            day = ordinal == -1 ? length - (edge.weekday - weekday + 7) % 7 : 1 + (weekday - edge.weekday + 7) % 7 + (ordinal - 1) * 7
        }
        guard (1...length).contains(day) else { return nil }
        return Self(String(format: "%04d-%02d-%02d", year, month, day))
    }
    func monthOffset(_ n: Int, rule: Record) -> Self? {
        let index = (year - 1) * 12 + month - 1 + n
        guard (0..<9999 * 12).contains(index) else { return nil }
        return Self.monthDay(year: index / 12 + 1, month: index % 12 + 1, rule: rule, fallback: day)
    }
    func monthOptions(_ offset:Int,rule:Record)->[Self] {
        guard rule["daysOfMonth"] != .null else {return monthOffset(offset,rule:rule).map{[$0]} ?? []}
        let index=(year-1)*12+month-1+offset
        guard (0..<9999*12).contains(index) else{return []}
        let year=index/12+1,month=index%12+1,length=Self.monthLength(year,month)
        let selected=Set(rule["daysOfMonth"].list.map{min($0.integer,length)}).sorted()
        return selected.compactMap{Self(String(format:"%04d-%02d-%02d",year,month,$0))}
    }
    func next(_ rule: Record, after: Self) -> Self? {
        let threshold = max(self, after), n = rule["interval"] == .null ? 1 : rule["interval"].integer
        let selected = Array(Set(rule["daysOfWeek"].list.map(\.integer))).sorted()
        var result: Self?
        switch rule.string("type") {
        case "daily", "custom": result = adding(((threshold.serial - serial) / n + 1) * n)
        case "weekly":
            if selected.isEmpty { let span = 7 * n; result = adding(((threshold.serial - serial) / span + 1) * span) }
            else {
                let week = serial - weekday, span = 7 * n, cycle = (threshold.serial - week) / span
                for offset in cycle...(cycle + 1) {
                    for day in selected {
                        if let value = Self(serial: week + offset * span + day), value > threshold { result = value; break }
                    }
                    if result != nil { break }
                }
            }
        case "monthly":
            let elapsed = (threshold.year - year) * 12 + threshold.month - month, first = max(rule["daysOfMonth"] == .null ? 1 : 0, elapsed / n)
            for offset in first...(first + 400) {
                if let value=monthOptions(offset*n,rule:rule).first(where:{$0>threshold}) {result=value;break}
                if (year - 1) * 12 + month - 1 + offset * n >= 9999 * 12 { break }
            }
        case "yearly":
            let first = max(1, (threshold.year - year) / n)
            for offset in first...(first + 1) {
                if let value = Self.monthDay(year: year + offset * n, month: rule["monthOfYear"].integer, rule: rule, fallback: day), value > threshold { result = value; break }
            }
        default: break
        }
        if let end = Self(rule.string("endDate")), let value = result, value > end { return nil }
        return result
    }
    func first(_ rule: Record) -> Self? {
        var result: Self? = self
        let selected = rule["daysOfWeek"].list.map(\.integer)
        if !selected.isEmpty { result = adding(selected.map { ($0 - weekday + 7) % 7 }.min()!) }
        else if rule.string("type") == "monthly" {
            result = nil
            for offset in 0...400 {if let value=monthOptions(offset,rule:rule).first(where:{$0>=self}) {result=value;break}}
        } else if rule.string("type") == "yearly" {
            result = Self.monthDay(year: year, month: rule["monthOfYear"].integer, rule: rule, fallback: day)
            if let value = result, value < self { result = Self.monthDay(year: year + 1, month: rule["monthOfYear"].integer, rule: rule, fallback: day) }
        }
        if let end = Self(rule.string("endDate")), let value = result, value > end { return nil }
        return result
    }
    static func current(_ date: Date, zone: TimeZone) -> Self? {
        let wall = date.timeIntervalSince1970 + Double(zone.secondsFromGMT(for: date))
        guard wall.isFinite, wall < 253402300800 else { return nil }
        if wall < -62135596800 { return Self("0001-01-01") }
        return Self(serial: Int(floor(wall / 86400)))
    }
}

/// Version 2 is an independent Gregorian wall-clock schedule in its source zone.
/// Finite limits count actual calendar occurrences from the original anchor. Unlimited
/// rules jump to the current period. Missing civil days never drift weekday anchors.
struct ReminderCalendarSchedule: Equatable, Sendable {
    let startDay: String
    let time: String
    let timeZone: String
    let rule: Record
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: timeZone)!; return c }
    var first: Date { instant(on: ReminderCivilDay(startDay)!)! }
    init?(raw: [String: JSON]) {
        guard case .string(let start)? = raw["start_day"], let day = ReminderCivilDay(start),
              case .string(let time)? = raw["time"], time.range(of: #"^([01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) != nil,
              case .string(let zone)? = raw["time_zone"], TimeZone(identifier: zone) != nil,
              !zone.hasPrefix("GMT+"), !zone.hasPrefix("GMT-"),
              case .object(let fields)? = raw["recurrence"] else { return nil }
        startDay = start; self.time = time; timeZone = zone; rule = Record(fields)
        guard Recurrence.valid(rule), !rule["fromCompletion"].flag,
              rule["count"] == .null || Recurrence.number(rule["count"], in: 1...999) != nil,
              rule.string("endDate").isEmpty || ReminderCivilDay(rule.string("endDate")) != nil else { return nil }
        if rule["daysOfWeek"] != .null && rule.string("type") != "weekly" { return nil }
        if rule["dayOfMonth"] != .null && !["monthly", "yearly"].contains(rule.string("type")) { return nil }
        if rule["monthOfYear"] != .null && rule.string("type") != "yearly" { return nil }
        if rule["weekday"] != .null && rule["weekdayOrdinal"] == .null { return nil }
        if ["monthly", "yearly"].contains(rule.string("type")), rule["dayOfMonth"] == .null, rule["weekdayOrdinal"] == .null, rule["daysOfMonth"] == .null { return nil }
        if rule.string("type") == "yearly", rule["monthOfYear"] == .null { return nil }
        guard day.first(rule) == day, instant(on: day) != nil else { return nil }
    }
    func instant(on day: ReminderCivilDay) -> Date? {
        let zone = TimeZone(identifier: timeZone)!, wall = Double(day.serial * 86400 + Int(time.prefix(2))! * 3600 + Int(time.suffix(2))! * 60)
        let offsets = Set(stride(from: -36, through: 36, by: 6).map { zone.secondsFromGMT(for: Date(timeIntervalSince1970: wall + Double($0 * 3600))) })
        // Match adjacent actual offsets. Earliest exact match is the first autumn fold;
        // advance to the next valid minute in a spring gap, never into another civil day.
        for shift in 0..<1440 {
            let requested = wall + Double(shift * 60)
            guard Int(floor(requested / 86400)) == day.serial else { return nil }
            let matches = offsets.compactMap { offset -> Date? in
                let value = Date(timeIntervalSince1970: requested - Double(offset))
                return zone.secondsFromGMT(for: value) == offset ? value : nil
            }
            if let date = matches.min() { return date }
        }
        return nil
    }
    func dates(after now: Date, limit: Int = 60) -> [Date] {
        guard limit > 0, now.timeIntervalSince1970.isFinite, let today = ReminderCivilDay.current(now, zone: calendar.timeZone) else { return [] }
        let anchor = ReminderCivilDay(startDay)!, cap = min(limit, 60)
        var day = anchor, result: [Date] = []
        if let count = Recurrence.number(rule["count"], in: 1...999) {
            var consumed = 0
            while consumed < count {
                if let date = instant(on: day) { consumed += 1; if date > now { result.append(date); if result.count == cap { break } } }
                guard let next = anchor.next(rule, after: day) else { break }; day = next
            }
        } else {
            if first > now { result.append(first) }
            var threshold = max(anchor, today.adding(-1) ?? today)
            while result.count < cap {
                guard let next = anchor.next(rule, after: threshold) else { break }
                if let date = instant(on: next), date > now { result.append(date) }
                threshold = next
            }
        }
        return result
    }
    func contains(_ date: Date) -> Bool {
        guard date.timeIntervalSince1970.isFinite else { return false }
        return dates(after: date.addingTimeInterval(-0.001), limit: 1).first == date
    }
    var semanticFields: [String] {
        let fields=[startDay, time, timeZone, rule.string("type"), String(rule["interval"].integer == 0 ? 1 : rule["interval"].integer),
         Array(Set(rule["daysOfWeek"].list.map(\.integer))).sorted().map(String.init).joined(separator: ","),
         ["dayOfMonth", "monthOfYear", "weekday", "weekdayOrdinal", "count"].map { rule[$0] == .null ? "" : String(rule[$0].integer) }.joined(separator: ","), rule.string("endDate")]
        // Keep existing signatures byte-for-byte for unchanged schedules.
        return fields+(rule["daysOfMonth"] == .null ? [] : ["monthly-dates",rule["daysOfMonth"].list.map(\.integer).sorted().map(String.init).joined(separator:",")])
    }
    func formatted(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        formatter.gregorianStartDate = Date(timeIntervalSince1970: -62135596800)
        return formatter.string(from: date)
    }
    /// Calendar limits are totals from the original anchor, not remaining task cycles.
    var summary: String {
        var pattern = rule; pattern["count"] = .null
        let text = Recurrence.summary(pattern)
        guard let count = Recurrence.number(rule["count"], in: 1...999) else { return text }
        return text + " · \(count) occurrences total"
    }
    var expression: String {
        let n = rule["interval"].integer == 0 ? 1 : rule["interval"].integer
        let unit = ["daily": "day", "custom": "day", "weekly": "week", "monthly": "month", "yearly": "year"][rule.string("type")] ?? "day"
        var value = "every " + (n == 1 ? unit : "\(n) \(unit)s")
        let days = Array(Set(rule["daysOfWeek"].list.map(\.integer))).sorted()
        if unit == "week", !days.isEmpty { value += " on " + days.map { Recurrence.weekdays[$0] }.joined(separator: " and ") }
        if unit == "month", let ordinal = Recurrence.number(rule["weekdayOrdinal"], in: -1...5), let weekday = Recurrence.number(rule["weekday"], in: 0...6) { value += " on " + (Recurrence.ordinals[ordinal] ?? "") + " " + Recurrence.weekdays[weekday] }
        else if unit == "month",rule["daysOfMonth"] != .null {value += " on "+rule["daysOfMonth"].list.map(\.integer).sorted().map(String.init).joined(separator:" and ")}
        else if unit == "month" { value += " on \(rule["dayOfMonth"].integer)" }
        else if unit == "year" { value += " on " + QuickRecurrenceText.months[rule["monthOfYear"].integer - 1] + " \(rule["dayOfMonth"].integer)" }
        if !rule.string("endDate").isEmpty { value += " until " + rule.string("endDate") }
        if let count = Recurrence.number(rule["count"], in: 1...999) { value += " for \(count) occurrences" }
        return value
    }
    static func make(_ phrase: String, time: String, start: String, zone: String, datePreferences: DatePhrasePreferences? = DatePhrasePreferences()) -> Self? {
        guard let anchor = ReminderCivilDay(start) else { return nil }
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let now = Dates.parse(start, calendar: c), let parsed = QuickRecurrenceText.parse(phrase, now: now, calendar: c, datePreferences: datePreferences), !parsed.rule["fromCompletion"].flag else { return nil }
        var rule = parsed.rule
        let day = parsed.start.flatMap(ReminderCivilDay.init) ?? anchor
        if ["monthly", "yearly"].contains(rule.string("type")), rule["dayOfMonth"] == .null, rule["weekdayOrdinal"] == .null, rule["daysOfMonth"] == .null { rule["dayOfMonth"] = .number(Double(day.day)) }
        if rule.string("type") == "yearly", rule["monthOfYear"] == .null { rule["monthOfYear"] = .number(Double(day.month)) }
        guard let first = day.first(rule) else { return nil }
        return Self(raw: ["start_day": .string(first.key), "time": .string(time), "time_zone": .string(zone), "recurrence": .object(rule.fields)])
    }
    var raw: [String: JSON] { ["start_day": .string(startDay), "time": .string(time), "time_zone": .string(timeZone), "recurrence": .object(rule.fields)] }
}


/// Calendar reminders keep a chosen civil day and clock, rather than the device's zone.
enum ReminderTimeZones {
    private static let known = Array(Set(TimeZone.knownTimeZoneIdentifiers + ["UTC"])).sorted()
    static func valid(_ identifier: String) -> Bool {
        identifier.utf8.count <= 100 && !identifier.hasPrefix("GMT+") && !identifier.hasPrefix("GMT-") && TimeZone(identifier: identifier) != nil
    }
    static func sourceIdentifier(for deviceZone: TimeZone) -> String { valid(deviceZone.identifier) ? deviceZone.identifier : "UTC" }
    static func choices(including selection: String, query: String = "") -> [String] {
        let values = known.contains(selection) || !valid(selection) ? known : (known + [selection]).sorted()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? values : values.filter { $0.replacingOccurrences(of: "_", with: " ").localizedCaseInsensitiveContains(query.replacingOccurrences(of: "_", with: " ")) }
    }
    /// A date picker's instant represents a civil day. Preserve that day explicitly.
    /// A skipped date fails instead of silently becoming tomorrow in the new zone.
    private static let pickerBounds: ClosedRange<Double> = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!
        let first = c.date(from: DateComponents(era: 1, year: 1, month: 1, day: 1))!.timeIntervalSince1970
        let end = c.date(from: DateComponents(era: 1, year: 10000, month: 1, day: 1))!.timeIntervalSince1970
        return (first - 129600)...(end + 129600)
    }()
    static func movingCivilDay(_ date: Date, from old: String, to new: String) throws -> Date {
        let seconds = date.timeIntervalSince1970
        guard valid(old), valid(new), seconds.isFinite, pickerBounds.contains(seconds) else { throw AppFailure(message: "Choose a supported time zone and start date.") }
        // This is the picker's date representation, not the notification's instant.
        // Read/write through the same calendar, including its historical cutover.
        var source = Calendar(identifier: .gregorian); source.timeZone = TimeZone(identifier: old)!
        var target = source; target.timeZone = TimeZone(identifier: new)!
        let parts = source.dateComponents([.era, .year, .month, .day], from: date)
        guard parts.era == 1, let year = parts.year, (1...9999).contains(year), let month = parts.month, let day = parts.day,
              ReminderCivilDay(String(format: "%04d-%02d-%02d", year, month, day)) != nil,
              let moved = target.date(from: DateComponents(era: 1, year: year, month: month, day: day, hour: 12)) else {
            throw AppFailure(message: "Choose a supported start date before changing the time zone.")
        }
        let check = target.dateComponents([.era, .year, .month, .day], from: moved)
        guard check == parts else { throw AppFailure(message: "That start date does not exist in the selected time zone. Choose another start date first.") }
        return moved
    }
}

/// Read-only comparison of actual upcoming instants; no schedule or setting is changed.
enum ReminderClockPreview {
    struct Row: Equatable, Sendable {
        let instant: Date
        let sourceText: String
        let deviceText: String?
        let sourceOffset: Int
        let deviceOffset: Int
    }
    static func rows(_ schedule: ReminderCalendarSchedule, after now: Date, displayZone: TimeZone, limit: Int = 5, locale: Locale = .current, dates: [Date]? = nil) -> [Row] {
        let dates = Array((dates ?? schedule.dates(after: now, limit: min(5, max(0, limit)))).prefix(min(5, max(0, limit))))
        let source = schedule.calendar.timeZone
        func formatter(_ zone: TimeZone) -> DateFormatter {
            let f = DateFormatter(); f.locale = locale
            var c = Calendar(identifier: .gregorian); c.timeZone = zone
            f.calendar = c; f.timeZone = zone; f.dateStyle = .medium; f.timeStyle = .short
            f.gregorianStartDate = Date(timeIntervalSince1970: -62_135_596_800)
            return f
        }
        let a = formatter(source), b = formatter(displayZone)
        return dates.map { Row(instant: $0, sourceText: a.string(from: $0), deviceText: source.identifier == displayZone.identifier ? nil : b.string(from: $0), sourceOffset: source.secondsFromGMT(for: $0), deviceOffset: displayZone.secondsFromGMT(for: $0)) }
    }
    static func clocksChange(_ rows: [Row]) -> Bool {
        zip(rows, rows.dropFirst()).contains { $0.sourceOffset != $1.sourceOffset || $0.deviceOffset != $1.deviceOffset }
    }
}

/// The old device-wide switch migrates to the first active workspace only.
enum ReminderPreferences {
    static func timeSensitiveKey(_ account: String) -> String { "taskfold.reminders.timeSensitive." + account.lowercased() }
    static func timeSensitiveEnabled(account: String, defaults: UserDefaults = .standard) -> Bool {
        !account.isEmpty && defaults.bool(forKey: timeSensitiveKey(account))
    }
    static func key(_ account: String) -> String { "taskfold.reminders.enabled." + account.lowercased() }
    static func enabled(account: String, fixture: Bool = false, defaults: UserDefaults = .standard) -> Bool {
        guard !account.isEmpty else { return false }
        let ownerKey = "taskfold.reminders.legacyOwner" + (fixture ? ".fixture" : "")
        if defaults.string(forKey: ownerKey) == nil { defaults.set(account.lowercased(), forKey: ownerKey) }
        let key = key(account)
        if defaults.object(forKey: key) == nil {
            defaults.set(defaults.string(forKey: ownerKey) == account.lowercased() && defaults.bool(forKey: "remindersEnabled"), forKey: key)
        }
        return defaults.bool(forKey: key)
    }
}

/// Versioned semantic fields use UTF-8 byte-length framing, independent of JSON spelling,
/// key order, number formatting and platform calendar serialization. Unknown extension fields
/// are preserved but cannot change version-1 scheduling semantics.
enum ReminderSignature {
    static func milliseconds(_ date: Date) -> String { String(Int64((date.timeIntervalSince1970 * 1000).rounded())) }
    static func legacy(task: Record, spec: ReminderSpec, date: Date) -> String {
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        let encoded=(try? encoder.encode(JSON.object(spec.raw))).flatMap { String(data:$0,encoding:.utf8) } ?? ""
        return DueReminder.digest(encoded+"|"+String(date.timeIntervalSince1970)+"|completion:"+String(task["completion_version"].integer))
    }
    static func make(task: Record, spec: ReminderSpec, date: Date) -> String {
        if spec.timeSensitive, let base = spec.settingTimeSensitive(false) {
            let fields = ["taskfold.reminder.v7", make(task: task, spec: base, date: date), "time-sensitive"]
            return "r7:" + DueReminder.digest(fields.map { "\($0.utf8.count):\($0)" }.joined())
        }
        if let schedule = spec.holidaySchedule {
            let fields = ["taskfold.reminder.v8", task.id.lowercased(), spec.id] + schedule.semanticFields + ["local", "1", milliseconds(date), String(task["completion_version"].integer), task.string("task_generation").lowercased()]
            return "r8:" + DueReminder.digest(fields.map { "\($0.utf8.count):\($0)" }.joined())
        }
        let generation = task.string("task_generation").lowercased()
        if let schedule = spec.intervalSchedule {
            let fields = ["taskfold.reminder.v6", task.id.lowercased(), spec.id] + schedule.semanticFields + ["local", "1", milliseconds(date), String(task["completion_version"].integer), generation]
            return "r6:" + DueReminder.digest(fields.map { "\($0.utf8.count):\($0)" }.joined())
        }
        if let schedule = spec.schedule {
            let fields = ["taskfold.reminder.v5", task.id.lowercased(), spec.id] + schedule.semanticFields + ["local", "1", milliseconds(date), String(task["completion_version"].integer), generation]
            return "r5:" + DueReminder.digest(fields.map { "\($0.utf8.count):\($0)" }.joined())
        }
        var fields = [generation.isEmpty ? "taskfold.reminder.v3" : "taskfold.reminder.v4", task.id.lowercased(), spec.id, spec.kind,
                      spec.kind == "relative" ? "planned" : "", spec.kind == "relative" ? spec.offset.map(String.init) ?? "" : "",
                      spec.kind == "absolute" ? spec.absolute.map(milliseconds) ?? "" : "", spec.kind == "absolute" ? spec.raw["time_zone"]?.text ?? "" : "",
                      (spec.raw["channels"]?.list ?? []).map(\.text).sorted().joined(separator: ","), "1",
                      milliseconds(date), String(task["completion_version"].integer)]
        if !generation.isEmpty { fields.append(generation) }
        return (generation.isEmpty ? "r3:" : "r4:") + DueReminder.digest(fields.map { "\($0.utf8.count):\($0)" }.joined())
    }
}

enum ReminderEventKind: String, Sendable { case task, focusFinish }

struct DueReminder: Equatable, Sendable {
    var kind: ReminderEventKind = .task
    var id: String
    var title: String
    var body: String
    var date: Date
    var taskID: String
    var specID: String
    var signature: String
    var legacySignature: String? = nil
    var calendarOccurrence = false
    var timeSensitive = false
    func hasSignature(_ value: String) -> Bool { signature == value || legacySignature == value }
    static func == (a: Self, b: Self) -> Bool {
        a.kind == b.kind && a.id == b.id && a.title == b.title && a.body == b.body && a.date == b.date &&
        a.taskID == b.taskID && a.specID == b.specID && a.signature == b.signature && a.calendarOccurrence == b.calendarOccurrence && a.timeSensitive == b.timeSensitive
    }
    static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func specifications(_ task: Record, channels: Set<String>) -> [ReminderSpec] {
        guard !task.completed else { return [] }
        if let generation = task.fields["task_generation"], generation != .null {
            guard case .string(let value) = generation, UUID(uuidString: value) != nil else { return [] }
        }
        let raw = ReminderSpec.rows(task)
        let specs = raw.isEmpty ? [ReminderSpec.relative(0, id: ReminderSpec.plannedID)] : raw.prefix(ReminderSpec.maximum).compactMap(ReminderSpec.init(row:))
        var seen = Set<String>()
        return specs.filter { seen.insert($0.id).inserted && $0.enabled && !channels.isDisjoint(with: ($0.raw["channels"]?.list ?? []).map(\.text)) }
    }
    private static func event(task: Record, spec: ReminderSpec, date: Date) -> DueReminder {
        let recurring = spec.schedule != nil || spec.intervalSchedule != nil
        let id = ReminderSpec.rows(task).isEmpty ? task.id : task.id + "." + spec.id + (recurring ? "." + ReminderSignature.milliseconds(date) : "")
        return DueReminder(id: id, title: task.title, body: task.string("description"), date: date, taskID: task.id, specID: spec.id,
            signature: ReminderSignature.make(task: task, spec: spec, date: date),
            legacySignature: !spec.timeSensitive && !recurring && task.string("task_generation").isEmpty ? ReminderSignature.legacy(task: task, spec: spec, date: date) : nil,
            calendarOccurrence: recurring, timeSensitive: spec.timeSensitive)
    }
    static func events(tasks: [Record], calendar: Calendar = .current, channels: Set<String> = ["local"], now: Date = Date()) -> [DueReminder] {
        var result: [DueReminder] = []
        for task in tasks {
            for spec in specifications(task, channels: channels) {
                if let schedule = spec.holidaySchedule {
                    for date in schedule.dates(after: now) { result.append(event(task: task, spec: spec, date: date)) }
                } else if let schedule = spec.intervalSchedule {
                    for date in schedule.dates(after: now) { result.append(event(task: task, spec: spec, date: date)) }
                } else if let schedule = spec.schedule {
                    for date in schedule.dates(after: now) { result.append(event(task: task, spec: spec, date: date)) }
                } else if let date = spec.date(task: task, calendar: calendar) { result.append(event(task: task, spec: spec, date: date)) }
            }
        }
        return result.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
    /// Reconstruct a receipt against current accessible rows, not only the future queue.
    /// An independent schedule must prove the exact original occurrence (including DST fold).
    static func validated(tasks: [Record], taskID: String, specID: String, signature: String, originalAt: Date?, calendar: Calendar = .current) -> DueReminder? {
        guard let task = tasks.first(where: { $0.id == taskID }),
              let spec = specifications(task, channels: ["local"]).first(where: { $0.id == specID }) else { return nil }
        let date: Date?
        if let schedule = spec.holidaySchedule {
            guard let originalAt, schedule.contains(originalAt) else { return nil }; date = originalAt
        } else if let schedule = spec.intervalSchedule {
            guard let originalAt, schedule.contains(originalAt) else { return nil }; date = originalAt
        } else if let schedule = spec.schedule {
            guard let originalAt, schedule.contains(originalAt) else { return nil }; date = originalAt
        } else { date = spec.date(task: task, calendar: calendar) }
        guard let date else { return nil }
        let result = event(task: task, spec: spec, date: date)
        return result.hasSignature(signature) ? result : nil
    }
    static func plan(tasks: [Record], now: Date = Date(), calendar: Calendar = .current, limit: Int = 60) -> [DueReminder] {
        Array(events(tasks: tasks, calendar: calendar, now: now).filter { $0.date > now }.prefix(max(0, limit)))
    }
}

struct ReminderRequest: Equatable, Sendable {
    static let prefix = "taskfold.r2."
    var identifier: String
    var account: String
    var event: DueReminder
    var fireAt: Date
    var snoozed = false
    static func make(account: String, event: DueReminder, fireAt: Date? = nil, snoozed: Bool = false) -> Self {
        let id = LocationReminderTicket.isLocationSignature(event.signature) && snoozed
            ? LocationNotificationAction.prefix + DueReminder.digest(account + "|" + event.id)
            : (event.kind == .focusFinish ? FocusFinish.prefix : prefix) + DueReminder.digest(account + "|" + event.taskID.lowercased() + "|" + event.specID + (event.calendarOccurrence ? "|" + ReminderSignature.milliseconds(event.date) : ""))
        return Self(identifier: id + (snoozed ? ".snooze" : ""), account: account, event: event, fireAt: fireAt ?? event.date, snoozed: snoozed)
    }
    func matchesSnooze(_ other: Self) -> Bool {
        snoozed && other.snoozed && identifier == other.identifier && account == other.account &&
        event.kind == other.event.kind && event.taskID == other.event.taskID && event.specID == other.event.specID &&
        event.hasSignature(other.event.signature) && abs(event.date.timeIntervalSince(other.event.date)) < 0.001 &&
        abs(fireAt.timeIntervalSince(other.fireAt)) < 0.001
    }
    func valid(state: ReminderState) -> Bool { account == state.account && state.validated(event) != nil }
    func valid(account: String, events: [DueReminder]) -> Bool {
        self.account == account && events.contains { $0.taskID == event.taskID && $0.specID == event.specID && $0.hasSignature(event.signature) && $0.kind == event.kind }
    }
}
struct ReminderState: Sendable {
    var revision: Int
    var account: String
    var events: [DueReminder]
    var now = Date()
    var validationTasks: [Record] = []
    var calendar = Calendar.current
    var deliveryAuthority: ReminderDeliveryAuthority? = nil
    var deliveryAuthorityUnreadable = false
    var deliveryAuthorityAccount: String? = nil
    var timeSensitiveAllowed = false
    var locationPlan: LocationReminderPlan? = nil
    var locationSnoozes: [ReminderRequest] = []
    var queuedTimeSnoozes: [ReminderRequest] = []
    var timeSnoozeTransition: @Sendable (ReminderRequest, LocationSnoozeTransition) async -> LocationSnoozeAcknowledgement = { _, _ in .obsolete }
    var locationValidationEvents: [DueReminder] = []
    var locationPendingIDs: Set<String> = []
    var locationSnoozeTransition: @Sendable (ReminderRequest, LocationSnoozeTransition) async -> LocationSnoozeAcknowledgement = { _, _ in .obsolete }
    var locationWorkspace: UUID? = nil
    var locationContextIsCurrent: @Sendable () async -> Bool = { true }
    func permitsOriginal(_ event: DueReminder) -> Bool {
        if LocationReminderTicket.isLocationSignature(event.signature) { return false } // Only explicit ledger snoozes are time requests.
        // Interval and Time Sensitive specs are explicitly local-only; the server excludes them.
        return event.kind == .focusFinish || (event.kind == .task && (event.signature.hasPrefix("r6:") || event.signature.hasPrefix("r7:") || event.signature.hasPrefix("r8:"))) || (!deliveryAuthorityUnreadable && (deliveryAuthority?.allowsLocalOriginal(account: deliveryAuthorityAccount ?? account, at: event.date) ?? true))
    }
    func validated(_ event: DueReminder) -> DueReminder? {
        if LocationReminderTicket.isLocationSignature(event.signature) {
            return locationValidationEvents.first { $0.id == event.id && $0.kind == event.kind && $0.taskID == event.taskID && $0.specID == event.specID && $0.signature == event.signature && $0.date == event.date && !event.calendarOccurrence && !event.timeSensitive }
        }
        if let matching = events.first(where: { $0.kind == event.kind && $0.taskID == event.taskID && $0.specID == event.specID && $0.hasSignature(event.signature) }) { return matching }
        guard event.kind == .task else { return nil }
        return DueReminder.validated(tasks: validationTasks, taskID: event.taskID, specID: event.specID, signature: event.signature, originalAt: event.date, calendar: calendar)
    }
}
enum ReminderSnoozeOutcome: Sendable { case scheduled, waitingForSpace, failed, obsolete }
struct ReminderReport: Equatable, Sendable {
    var revision: Int
    var scheduled = 0
    var deferred = 0
    var failures = 0
    var focusScheduled = false
    var focusFailure = false
    var focusDeferred = false
    var locations: LocationReminderReport? = nil
    var reservedLocationSlots = 0
    var otherPendingSlots = 0
    var snoozeOutcome: ReminderSnoozeOutcome? = nil
    var acceptedSnoozes: [ReminderRequest] = []
    var deferredSnoozes: [ReminderRequest] = []
    var failedSnoozes: [ReminderRequest] = []
    mutating func accepted(_ request: ReminderRequest) {
        if request.snoozed { acceptedSnoozes.append(request) }
        if request.event.kind == .focusFinish { focusScheduled = true } else { scheduled += 1 }
    }
    mutating func failed(_ request: ReminderRequest) {
        if request.snoozed { failedSnoozes.append(request) }
        if request.event.kind == .focusFinish { focusFailure = true } else { failures += 1 }
    }
}
protocol ReminderCenter: Sendable {
    func pending() async -> [ReminderRequest]
    func removeInvalid(_ state: ReminderState) async
    func remove(_ identifiers: [String]) async
    func add(_ request: ReminderRequest) async throws
    /// All pending identifiers outside decodable time/Focus requests, including
    /// malformed owned requests. Their capacity cannot be assumed to be free.
    func occupiedOutsideTimeAndFocus() async -> [String]
}
extension ReminderCenter {
    func occupiedOutsideTimeAndFocus() async -> [String] { [] }
}

/// One drain admits time, snoozed, Focus and optional location requests. Location
/// cleanup precedes time admission; new geofences wait until time capacity is freed.
actor ReminderScheduler {
    private let center: any ReminderCenter
    private var locationEngine: LocationReminderEngine?
    private var pendingLocationEngine: LocationReminderEngine?
    private var desired = ReminderState(revision: -1, account: "", events: [])
    private var hasDesiredState = false
    var currentRevision: Int { desired.revision }
    func intentRevision() -> Int { sequence }
    private var sequence = 0
    private var running = false
    private var snoozes: [ReminderRequest] = []
    private var waiters: [CheckedContinuation<ReminderReport, Never>] = []
    init(center: any ReminderCenter = SystemReminderCenter(), locationEngine: LocationReminderEngine? = nil) {
        self.center = center; self.locationEngine = locationEngine
    }
    func prepareLocation(_ ticket: LocationReminderTicket) async -> Bool {
        guard pendingLocationEngine == nil, let locationEngine, locationEngine.deviceIdentity == ticket.device,
              await locationEngine.prepare(ticket) else { return false }
        guard pendingLocationEngine == nil, self.locationEngine === locationEngine else { return false }
        sequence += 1
        if hasDesiredState { _ = await sweep() }
        return true
    }
    func retireLocations(_ tickets: [LocationReminderTicket]) async -> Bool {
        guard pendingLocationEngine == nil, let locationEngine else { return tickets.isEmpty }
        let result = await locationEngine.retire(tickets)
        sequence += 1
        if hasDesiredState { _ = await sweep() }
        return result
    }
    private func permitsLocation(_ candidate: LocationReminderCandidate, engine: LocationReminderEngine, workspace: UUID?) async -> Bool {
        guard pendingLocationEngine == nil, locationEngine === engine, desired.locationWorkspace == workspace else { return false }
        let current = desired.locationContextIsCurrent
        guard await current() else { return false }
        // Recheck after the external workspace validator suspends this actor.
        guard pendingLocationEngine == nil, locationEngine === engine, desired.locationWorkspace == workspace, let plan = desired.locationPlan, candidate.ticket.account == desired.account, plan.allowSubmissions, plan.capacity > 0 else { return false }
        return plan.eligible.contains { $0.matches(candidate) }
    }
    func update(_ state: ReminderState, installing engine: LocationReminderEngine? = nil) async -> ReminderReport {
        guard state.revision > desired.revision else { return ReminderReport(revision: desired.revision) }
        if let engine {
            // Keep the current journal actor for the same installation. A newly read
            // snapshot may predate an in-flight reservation or acknowledgement.
            if let current = locationEngine, current.deviceIdentity == engine.deviceIdentity { pendingLocationEngine = nil }
            else { pendingLocationEngine = engine }
        }
        desired = state; hasDesiredState = true; sequence += 1
        return await sweep()
    }
    func snooze(account: String, taskID: String, specID: String, signature: String, minutes: Int = 60, now: Date = Date(), originalAt: Date? = nil) async -> ReminderReport? {
        guard ReminderSnooze.validMinutes(minutes), now.timeIntervalSince1970.isFinite, account == desired.account, let event = desired.events.first(where: { $0.kind == .task && $0.taskID == taskID && $0.specID == specID && $0.hasSignature(signature) }) ?? DueReminder.validated(tasks: desired.validationTasks, taskID: taskID, specID: specID, signature: signature, originalAt: originalAt, calendar: desired.calendar) else { return nil }
        let request = ReminderRequest.make(account: account, event: event, fireAt: now.addingTimeInterval(TimeInterval(minutes) * 60), snoozed: true)
        snoozes.removeAll { $0.identifier == request.identifier }; snoozes.append(request); sequence += 1
        var report = await sweep()
        if report.acceptedSnoozes.contains(where: { $0.matchesSnooze(request) }) { report.snoozeOutcome = .scheduled }
        else if report.failedSnoozes.contains(where: { $0.matchesSnooze(request) }) { report.snoozeOutcome = .failed }
        else if report.deferredSnoozes.contains(where: { $0.matchesSnooze(request) }) { report.snoozeOutcome = .waitingForSpace }
        else { report.snoozeOutcome = .obsolete }
        return report
    }
    private func sweep() async -> ReminderReport {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if !running { running = true; Task { await self.drain() } }
        }
    }
    private func drain() async {
        while true {
            let token = sequence, state = desired
            if let replacement = pendingLocationEngine { locationEngine = replacement; pendingLocationEngine = nil }
            let existing = await center.pending()
            guard token == sequence else { continue }
            snoozes.removeAll { !$0.valid(state: state) || $0.fireAt <= state.now }
            let retained = existing.filter { $0.snoozed && $0.valid(state: state) && (!LocationReminderTicket.isLocationSignature($0.event.signature) || state.locationPendingIDs.contains($0.identifier)) && $0.fireAt > state.now }.compactMap { old -> ReminderRequest? in
                guard let event = state.validated(old.event) else { return nil }
                return ReminderRequest.make(account:state.account,event:event,fireAt:old.fireAt,snoozed:true)
            }
            var requests = state.account.isEmpty ? [] : state.events.filter { $0.date > state.now && state.permitsOriginal($0) }.map { ReminderRequest.make(account: state.account, event: $0) }
            requests += retained.filter { old in !snoozes.contains(where: { $0.identifier == old.identifier }) && !state.queuedTimeSnoozes.contains(where: { $0.identifier == old.identifier }) }
            requests += snoozes
            requests += state.locationSnoozes.filter { queued in queued.snoozed && queued.fireAt > state.now && queued.valid(state: state) && !requests.contains(where: { $0.identifier == queued.identifier }) }
            requests += state.queuedTimeSnoozes.filter { queued in queued.snoozed && queued.fireAt > state.now && queued.valid(state: state) && !requests.contains(where: { $0.identifier == queued.identifier }) }
            // A synced task cannot opt another device/account into elevated presentation.
            requests = requests.map { request in
                var request = request
                request.event.timeSensitive = request.event.kind == .task && request.event.timeSensitive && state.timeSensitiveAllowed
                return request
            }
            requests.sort {
                if $0.event.kind != $1.event.kind { return $0.event.kind == .focusFinish }
                if $0.snoozed != $1.snoozed { return $0.snoozed }
                return $0.fireAt == $1.fireAt ? $0.identifier < $1.identifier : $0.fireAt < $1.fireAt
            }
            await center.removeInvalid(state)
            guard token == sequence else { continue }
            let plan = (state.locationPlan ?? .empty).scoped(to: state.account)
            var admission = plan
            let priorityTimeSlots = requests.filter { $0.event.kind == .focusFinish || $0.snoozed }.count
            var outside = await center.occupiedOutsideTimeAndFocus()
            guard token == sequence else { continue }
            var reserved = 0
            if let locationEngine {
                let foreign = outside.filter { !$0.hasPrefix(LocationReminderTicket.namespace) }.count
                admission = plan.limited(to: max(0, 60 - foreign - priorityTimeSlots), submissions: true)
                _ = await locationEngine.update(admission.limited(to: admission.capacity, submissions: false), permitsSubmission: { [weak self, weak locationEngine] candidate in
                    guard let locationEngine else { return false }
                    return await self?.permitsLocation(candidate, engine: locationEngine, workspace: state.locationWorkspace) ?? false
                })
                guard token == sequence else { continue }
                reserved = await locationEngine.reservations(for: admission).count
                outside = await center.occupiedOutsideTimeAndFocus()
                guard token == sequence else { continue }
            }
            let other = locationEngine == nil ? outside.count : outside.filter { !$0.hasPrefix(LocationReminderTicket.namespace) }.count
            let existingLocations = locationEngine == nil ? 0 : outside.filter { $0.hasPrefix(LocationReminderTicket.namespace) }.count
            let timeLimit = max(0, 60 - other - max(reserved, existingLocations))
            let deferred = requests.dropFirst(timeLimit)
            var report = ReminderReport(revision: state.revision, deferred: deferred.filter { $0.event.kind == .task }.count,
                focusDeferred: deferred.contains { $0.event.kind == .focusFinish }, reservedLocationSlots: reserved, otherPendingSlots: other)
            report.deferredSnoozes = deferred.filter(\.snoozed)
            requests = Array(requests.prefix(timeLimit))
            let expected = Set(requests.map(\.identifier))
            await center.remove(existing.map(\.identifier).filter { !expected.contains($0) })
            guard token == sequence else { continue }
            var acceptedSnoozes = Set<String>()
            var capacityBlocked = false
            for request in requests {
                if token != sequence { break }
                if existing.contains(request) || LocationReminderTicket.isLocationSignature(request.event.signature) && existing.contains(where: { $0.matchesSnooze(request) }) { report.accepted(request); if request.snoozed { acceptedSnoozes.insert(request.identifier) }; continue }
                if capacityBlocked {
                    if request.snoozed { report.deferredSnoozes.append(request) }
                    if request.event.kind == .focusFinish { report.focusDeferred = true } else { report.deferred += 1 }
                    continue
                }
                let location = LocationReminderTicket.isLocationSignature(request.event.signature)
                let durableTime = !location && state.queuedTimeSnoozes.contains { $0.matchesSnooze(request) }
                if durableTime {
                    guard await state.timeSnoozeTransition(request, .reserve) == .saved else { report.failed(request); continue }
                    guard token == sequence else { break }
                }
                if location {
                    guard await state.locationSnoozeTransition(request, .reserve) == .saved else { report.failed(request); continue }
                    guard token == sequence else { break }
                }
                do {
                    try await center.add(request)
                    if location {
                        let current = await state.locationContextIsCurrent()
                        guard token == sequence, current else { await center.remove([request.identifier]); continue }
                        let ack = await state.locationSnoozeTransition(request, .installed)
                        if ack == .obsolete { await center.remove([request.identifier]); continue }
                    }
                    if durableTime {
                        let ack = await state.timeSnoozeTransition(request, .installed)
                        guard token == sequence else { if ack == .obsolete { await center.remove([request.identifier]) }; continue }
                        if ack == .obsolete { await center.remove([request.identifier]); continue }
                    }
                    report.accepted(request); if request.snoozed { acceptedSnoozes.insert(request.identifier) }
                }
                catch ReminderSchedulingFailure.noRoom {
                    if durableTime, await state.timeSnoozeTransition(request, .notSubmitted) != .saved { report.failed(request); continue }
                    if location, await state.locationSnoozeTransition(request, .notSubmitted) != .saved { report.failed(request); continue }
                    if request.snoozed { report.deferredSnoozes.append(request) }
                    capacityBlocked = true
                    if request.event.kind == .focusFinish { report.focusDeferred = true } else { report.deferred += 1 }
                }
                catch {
                    if durableTime { _ = await state.timeSnoozeTransition(request, .failed) }
                    if location { _ = await state.locationSnoozeTransition(request, .failed) }
                    report.failed(request)
                }
            }
            guard token == sequence else { continue }
            snoozes.removeAll { acceptedSnoozes.contains($0.identifier) }
            let latestOutside = await center.occupiedOutsideTimeAndFocus()
            guard token == sequence else { continue }
            let currentOther = locationEngine == nil ? latestOutside.count : latestOutside.filter { !$0.hasPrefix(LocationReminderTicket.namespace) }.count
            if currentOther != other { continue }
            if let locationEngine {
                let actualTimeCount = await center.pending().count
                guard token == sequence else { continue }
                let finalPlan = admission.limited(to: max(0, 60 - currentOther - actualTimeCount), submissions: !report.focusDeferred)
                report.locations = await locationEngine.update(finalPlan, permitsSubmission: { [weak self, weak locationEngine] candidate in
                    guard let locationEngine else { return false }
                    return await self?.permitsLocation(candidate, engine: locationEngine, workspace: state.locationWorkspace) ?? false
                })
                guard token == sequence else { continue }
                let after = await locationEngine.reservations(for: finalPlan).count
                guard token == sequence else { continue }
                // Failed/consumed one-shots release their reserved time slots in this
                // same drain rather than leaving the queue artificially underfilled.
                if after != reserved { continue }
                report.reservedLocationSlots = after
            }
            let completions = waiters; waiters = []; running = false
            for completion in completions { completion.resume(returning: report) }
            return
        }
    }
}

enum ReminderSchedulingFailure: LocalizedError {
    case noRoom
    var errorDescription: String? { "There’s no room for another alert yet. Taskfold will retry when space is available." }
}
struct SystemReminderCenter: ReminderCenter {
    private var center: UNUserNotificationCenter { .current() }
    static func decode(_ request: UNNotificationRequest) -> ReminderRequest? {
        if request.identifier.hasPrefix(LocationNotificationAction.prefix) || request.content.categoryIdentifier == LocationNotificationAction.category { return decodeLocationSnooze(request) }
        let info = request.content.userInfo
        guard (request.identifier.hasPrefix(ReminderRequest.prefix) || request.identifier.hasPrefix(FocusFinish.prefix)),
              let account = info["accountID"] as? String, let task = info["taskID"] as? String,
              let spec = info["specID"] as? String, let signature = info["signature"] as? String,
              let original = info["originalAt"] as? Double, let fire = info["fireAt"] as? Double, original.isFinite, fire.isFinite else { return nil }
        let kind: ReminderEventKind = request.identifier.hasPrefix(FocusFinish.prefix) ? .focusFinish : .task
        guard (kind == .focusFinish ? request.content.categoryIdentifier == FocusFinish.category && info["eventKind"] as? String == kind.rawValue : request.content.categoryIdentifier == "taskfold.reminder" && (info["eventKind"] == nil || info["eventKind"] as? String == kind.rawValue)) else { return nil }
        if kind == .focusFinish {
            guard FocusFinishReceipt(info: info) != nil, info["snoozed"] as? Bool == false, original.isFinite, fire.isFinite,
                  original == fire, (0...(Double(FocusSession.maximumTimestamp) / 1000 + 180 * 60)).contains(original) else { return nil }
        }
        let decoded = ReminderRequest(identifier: request.identifier, account: account,
            event: DueReminder(kind: kind, id: info["eventID"] as? String ?? task + "." + spec, title: request.content.title, body: request.content.body, date: Date(timeIntervalSince1970: original), taskID: task, specID: spec, signature: signature, calendarOccurrence: info["calendarOccurrence"] as? Bool ?? false, timeSensitive: request.content.interruptionLevel == .timeSensitive),
            fireAt: Date(timeIntervalSince1970: fire), snoozed: info["snoozed"] as? Bool ?? false)
        if decoded.event.calendarOccurrence && decoded.identifier != ReminderRequest.make(account: account, event: decoded.event, fireAt: decoded.fireAt, snoozed: decoded.snoozed).identifier { return nil }
        if kind == .focusFinish && decoded.identifier != ReminderRequest.make(account: account, event: decoded.event).identifier { return nil }
        return decoded
    }
    /// A location snooze is a separately versioned, one-shot UTC time request.
    /// Push/interval/location triggers and merely copied receipt fields are refused.
    static func decodeLocationSnooze(_ request: UNNotificationRequest) -> ReminderRequest? {
        let info = request.content.userInfo
        guard request.identifier.hasPrefix(LocationNotificationAction.prefix), request.content.categoryIdentifier == LocationNotificationAction.category,
              Set(info.keys.compactMap { $0 as? String }) == ["eventKind", "eventID", "accountID", "taskID", "specID", "signature", "originalAt", "fireAt", "snoozed", "calendarOccurrence"], info.count == 10,
              info["eventKind"] as? String == "task", let source = info["eventID"] as? String, LocationNotificationAction.sourceValid(source),
              let account = info["accountID"] as? String, LocationReminderIdentity.account(account),
              let task = info["taskID"] as? String, LocationReminderIdentity.uuid(.string(task)),
              let spec = info["specID"] as? String, LocationReminderIdentity.uuid(.string(spec)),
              let signature = info["signature"] as? String, LocationReminderTicket.isLocationSignature(signature), LocationReminderTicket.validSignature(signature),
              info["originalAt"] as? Double == 0, info["snoozed"] as? Bool == true, info["calendarOccurrence"] as? Bool == false,
              let fire = info["fireAt"] as? Double, fire.isFinite, (1...Double(FocusSession.maximumTimestamp) / 1000).contains(fire), fire.rounded() == fire,
              request.content.interruptionLevel == .active,
              let trigger = request.trigger as? UNCalendarNotificationTrigger, !trigger.repeats,
              trigger.dateComponents == Self.trigger(at: Date(timeIntervalSince1970: fire)).dateComponents else { return nil }
        let event = DueReminder(id: source, title: request.content.title, body: request.content.body, date: Date(timeIntervalSince1970: 0), taskID: task, specID: spec, signature: signature)
        let decoded = ReminderRequest.make(account: account, event: event, fireAt: Date(timeIntervalSince1970: fire), snoozed: true)
        return decoded.identifier == request.identifier ? decoded : nil
    }
    func pending() async -> [ReminderRequest] { await center.pendingNotificationRequests().compactMap(Self.decode) }
    func occupiedOutsideTimeAndFocus() async -> [String] {
        await center.pendingNotificationRequests().filter { Self.decode($0) == nil }.map(\.identifier)
    }
    func removeInvalid(_ state: ReminderState) async {
        func stale(_ request: UNNotificationRequest, pending: Bool) -> Bool {
            // Touch only Taskfold's reminder category and versioned namespace.
            guard request.content.categoryIdentifier == "taskfold.reminder" || request.identifier.hasPrefix(ReminderRequest.prefix) || request.content.categoryIdentifier == FocusFinish.category || request.identifier.hasPrefix(FocusFinish.prefix) || request.content.categoryIdentifier == LocationNotificationAction.category || request.identifier.hasPrefix(LocationNotificationAction.prefix) else { return false }
            guard let decoded = Self.decode(request), decoded.valid(state: state) else { return true }
            return pending && LocationReminderTicket.isLocationSignature(decoded.event.signature) && !state.locationPendingIDs.contains(decoded.identifier)
        }
        center.removePendingNotificationRequests(withIdentifiers: await center.pendingNotificationRequests().filter { stale($0, pending: true) }.map(\.identifier))
        center.removeDeliveredNotifications(withIdentifiers: await center.deliveredNotifications().map(\.request).filter { stale($0, pending: false) }.map(\.identifier))
    }
    func remove(_ identifiers: [String]) async { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    static func trigger(at date: Date) -> UNCalendarNotificationTrigger {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Calendar triggers resolve to whole seconds. Round forward so a fractional
        // task instant or explicit snooze cannot fire before its handoff cutoff.
        let scheduled = Date(timeIntervalSince1970: ceil(date.timeIntervalSince1970))
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: scheduled)
        components.timeZone = calendar.timeZone; components.calendar = calendar
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }
    static func content(for request: ReminderRequest) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = request.event.title; content.body = request.event.body; content.sound = .default
        content.interruptionLevel = request.event.kind == .task && request.event.timeSensitive ? .timeSensitive : .active
        content.categoryIdentifier = request.event.kind == .focusFinish ? FocusFinish.category : (LocationReminderTicket.isLocationSignature(request.event.signature) ? LocationNotificationAction.category : "taskfold.reminder")
        content.userInfo = ["eventKind": request.event.kind.rawValue, "eventID": request.event.id, "accountID": request.account, "taskID": request.event.taskID, "specID": request.event.specID, "signature": request.event.signature, "originalAt": request.event.date.timeIntervalSince1970, "fireAt": request.fireAt.timeIntervalSince1970, "snoozed": request.snoozed, "calendarOccurrence": request.event.calendarOccurrence]
        return content
    }
    func add(_ request: ReminderRequest) async throws {
        let current = await center.pendingNotificationRequests()
        guard current.count < 60 || current.contains(where: { $0.identifier == request.identifier }) else { throw ReminderSchedulingFailure.noRoom }
        // An explicit UTC instant preserves both sides of a daylight-saving fold.
        let native = UNNotificationRequest(identifier: request.identifier, content: Self.content(for: request), trigger: Self.trigger(at: request.fireAt))
        guard !LocationReminderTicket.isLocationSignature(request.event.signature) || Self.decodeLocationSnooze(native)?.matchesSnooze(request) == true else { throw AppFailure(message: "This location snooze is invalid.") }
        try await center.add(native)
    }
}


/// One optional device-local finish alert shares the existing serialized 60-request budget.
/// State and task completion revisions invalidate old alerts; task titles are not signature inputs.
enum FocusFinish {
    static let prefix = "taskfold.f1."
    static let category = "taskfold.focus.finished"
    static func preferenceKey(_ account: String) -> String { "taskfold.focus.alerts.enabled." + account.lowercased() }
    static func event(row: Record?, tasks: [Record], account: String, available: Bool = true, conflict: Bool = false) -> DueReminder? {
        guard available, !conflict, !account.isEmpty, let row,
              let session = FocusSessionChange.session(in: row, account: account), session.status == .running,
              let end = session.endDate, let task = tasks.first(where: { $0.id.lowercased() == session.taskID && !$0.completed }) else { return nil }
        var fields: [String: JSON] = ["state": session.document, "baseline": .object(FocusSessionChange.baseline(row)), "completion": task["completion_version"]]
        if !task.string("task_generation").isEmpty { fields["task_generation"] = task["task_generation"] }
        let document: JSON = .object(fields)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(document), let encoded = String(data: data, encoding: .utf8) else { return nil }
        // Calendar notification triggers resolve to whole seconds. Never alert before the timer ends.
        return DueReminder(kind: .focusFinish, id: "focus." + session.id, title: "Time well spent",
            body: PinnedNotes.excerpt(task.title, characters: 160, bytes: 1000).0 + "\nYour Focus timer is finished.",
            date: Date(timeIntervalSince1970: ceil(end.timeIntervalSince1970)), taskID: session.taskID,
            specID: session.id, signature: DueReminder.digest(encoded))
    }
}
struct FocusFinishReceipt: Equatable, Sendable {
    var account: String
    var task: String
    var session: String
    var signature: String
    init?(info: [AnyHashable: Any]) {
        guard let account = info["accountID"] as? String, !account.isEmpty, account.utf8.count <= 256,
              let task = info["taskID"] as? String, UUID(uuidString: task) != nil,
              let session = info["specID"] as? String, UUID(uuidString: session) != nil,
              let signature = info["signature"] as? String, signature.count == 64,
              signature.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        self.account = account; self.task = task; self.session = session; self.signature = signature
    }
    func valid(account: String, event: DueReminder?, now: Date = Date()) -> Bool {
        self.account == account && event?.kind == .focusFinish && event?.taskID == task && event?.specID == session && event?.signature == signature && (event?.date ?? .distantFuture) <= now
    }
}

/// A notification's validated Open action keeps its workspace incarnation through scene activation.
struct ReminderTaskRoute: Equatable, Sendable {
    var workspace: WorkspaceBinding
    var taskID: String
    var specID: String
    var signature: String
    var originalAt: Date? = nil
    var locationTicket: LocationReminderTicket? = nil
    func matches(account: String, generation: UUID, events: [DueReminder]) -> Bool {
        guard locationTicket == nil else { return false } // Private routes require a fresh protected-file check.
        return workspace.matches(account: account, generation: generation) && events.contains {
            $0.kind == .task && $0.taskID == taskID && $0.specID == specID && $0.signature == signature
        }
    }
}


/// Account-owned delay preference. Notification actions carry the shown delay independently
/// of later preference edits; pending requests retain their exact existing fire instant.
/// Account default captured as an ordinary relative spec when a task first gains
/// a valid date and time. Subsequent edits and preference changes keep that choice.
enum ReminderAutomatic {
    static let field = "automatic_before_minutes"
    static let specID = "00000000-0000-4000-8000-000000000002"
    static let placeholder = "taskfold_default_placeholder"
    static let presets = [-1, 0, 5, 10, 15, 30, 60, 120, 1440]
    static func validMinutes(_ value: Int) -> Bool { (-1...10080).contains(value) }
    static func minutes(_ document: JSON) -> Int? {
        guard ReminderSnooze.version(document) == 1 else { return nil }
        guard let field = document.object[field] else { return 0 } // Legacy default.
        guard case .number(let value) = field, value.isFinite, value.rounded() == value,
              (-1...10080).contains(value) else { return nil }
        return Int(value)
    }
    static func changing(_ document: JSON, minutes: Int) -> JSON? {
        guard validMinutes(minutes), document == .null || ReminderSnooze.validDocument(document) && ReminderSnooze.version(document) == 1 else { return nil }
        var fields = document == .null ? ["version": JSON.number(1), "snooze_minutes": .number(60)] : document.object
        fields[field] = .number(Double(minutes))
        let result = JSON.object(fields)
        return ReminderSnooze.validDocument(result) ? result : nil
    }
    static func label(_ minutes: Int) -> String {
        minutes == -1 ? "No automatic reminder" : minutes == 0 ? "At planned time" : ReminderSnooze.label(minutes) + " before"
    }
    static func timed(_ task: Record, calendar: Calendar) -> Bool {
        !task.string("due_date").isEmpty && !task.string("due_time").isEmpty && TaskPlanning.start(task, calendar: calendar) != nil
    }
    /// A temporary legacy default added alongside a manual reminder is distinguishable
    /// from an explicit at-planned-time choice. Never replace unmarked/manual rows.
    static var legacyPlaceholder: JSON {
        var spec = ReminderSpec.relative(0, id: ReminderSpec.plannedID)
        spec.raw[placeholder] = .bool(true)
        return .object(spec.raw)
    }
    static func applying(to task: Record, previous: Record?, minutes: Int, calendar: Calendar = .current) -> Record {
        guard validMinutes(minutes) else { return task }
        if let previous, timed(previous, calendar: calendar) {
            var result = task
            var rows = ReminderSpec.rows(task)
            // Removing a clock does not reset an existing task's legacy choice.
            if rows.isEmpty && !timed(task, calendar: calendar) {
                rows = [.object(ReminderSpec.relative(0, id: ReminderSpec.plannedID).raw)]
            }
            rows = rows.map { value in
                guard let spec = ReminderSpec(row: value), spec.id == ReminderSpec.plannedID,
                      spec.locallyEditable, spec.raw[placeholder] == .bool(true) else { return value }
                var raw = spec.raw; raw.removeValue(forKey: placeholder); return .object(raw)
            }
            if rows != ReminderSpec.rows(task) { result["reminder_specs"] = .array(rows) }
            return result
        }
        guard timed(task, calendar: calendar) else { return task }
        var rows = ReminderSpec.rows(task)
        let index = rows.firstIndex { value in
            guard let spec = ReminderSpec(row: value) else { return false }
            return spec.id == ReminderSpec.plannedID && spec.enabled && spec.locallyEditable && spec.raw[placeholder] == .bool(true)
        }
        guard rows.isEmpty || index != nil else { return task }
        let id = minutes > 0 ? specID : ReminderSpec.plannedID
        guard !rows.enumerated().contains(where: { $0.offset != index && $0.element.object["id"]?.text.lowercased() == id }) else { return task }
        var spec = ReminderSpec.relative(minutes > 0 ? -minutes : 0, id: id, enabled: minutes != -1)
        if let index {
            // Preserve extension metadata of the recognized legacy placeholder.
            let old = rows.remove(at: index).object
            for (key, value) in old where spec.raw[key] == nil && key != placeholder { spec.raw[key] = value }
        }
        if !ReminderSpec.duplicates(spec, in: rows) { rows.append(.object(spec.raw)) }
        guard rows.count <= ReminderSpec.maximum else { return task }
        var result = task; result["reminder_specs"] = .array(rows)
        return result
    }
    /// Replaying a queued semantic choice overlays only its field onto latest settings.
    /// Restores retain their separate create-only contract, and future documents stay opaque.
    static func replay(_ change: Mutation, onto row: Record?) -> Record? {
        guard change.recordID == ReminderSnooze.recordID,
              row == nil || row?.string("user_id").lowercased() == change.fields["user_id"]?.text.lowercased() else { return nil }
        let queued = change.fields["settings"] ?? .null
        guard ReminderSnooze.validDocument(queued), ReminderSnooze.version(queued) == 1 else { return nil }
        let settings: JSON?
        switch change.reminderPreferenceField {
        case nil, "snooze_minutes": settings = ReminderSnooze.minutes(queued).flatMap { ReminderSnooze.changing(row?["settings"] ?? .null, minutes: $0) }
        case field: settings = minutes(queued).flatMap { changing(row?["settings"] ?? .null, minutes: $0) }
        default: return nil
        }
        guard let settings else { return nil }
        var result = row ?? Record(change.fields)
        result["settings"] = settings
        return result
    }
}

enum ReminderSnooze {
    static let table = "reminder_preferences"
    static let recordID = "current"
    static let presets = [5, 15, 30, 60, 120, 240, 1440]
    static let actionPrefix = "taskfold.snooze.minutes."
    static func validMinutes(_ minutes: Int) -> Bool { (1...1440).contains(minutes) }
    static func version(_ document: JSON) -> Int? {
        guard case .object = document, case .number(let value)? = document.object["version"], value.isFinite,
              value.rounded() == value, (1...1000).contains(value) else { return nil }
        return Int(value)
    }
    static func minutes(_ document: JSON) -> Int? {
        guard version(document) == 1, case .number(let value)? = document.object["snooze_minutes"],
              value.isFinite, value.rounded() == value, (1...1440).contains(value) else { return nil }
        return Int(value)
    }
    static func validDocument(_ document: JSON) -> Bool {
        // Compact UTF-8 must accept every server-approved 8 KB frame, including opaque metadata.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let version = version(document), let data = try? encoder.encode(document), data.count <= 8192 else { return false }
        return version != 1 || minutes(document) != nil && ReminderAutomatic.minutes(document) != nil
    }
    static func changing(_ document: JSON, minutes: Int) -> JSON? {
        guard validMinutes(minutes), document == .null || validDocument(document) && version(document) == 1 else { return nil }
        var fields = document.object
        fields["version"] = .number(1); fields["snooze_minutes"] = .number(Double(minutes))
        let result = JSON.object(fields)
        return validDocument(result) ? result : nil
    }
    static func row(_ rows: [Record], account: String) -> Record? {
        rows.first { $0.id == recordID && $0.string("user_id").lowercased() == account.lowercased() && !account.isEmpty }
    }
    static func action(minutes: Int) -> String? {
        validMinutes(minutes) ? actionPrefix + String(minutes) : nil
    }
    static func minutes(action: String) -> Int? {
        if action == "taskfold.snooze.hour" { return 60 } // Already delivered legacy buttons.
        guard action.hasPrefix(actionPrefix), let value = Int(action.dropFirst(actionPrefix.count)),
              validMinutes(value), action == self.action(minutes: value) else { return nil }
        return value
    }
    static func label(_ minutes: Int) -> String {
        if minutes == 1 { return "1 minute" }
        if minutes == 60 { return "1 hour" }
        if minutes % 60 == 0 { return "\(minutes / 60) hours" }
        return "\(minutes) minutes"
    }
}

/// Device-local recovery for explicitly requested ordinary time snoozes. No title,
/// notes, geometry or credentials are stored. An ambiguous submission never rearms.
struct TimeSnoozeIntent: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case queued, reserved, installed, closed }
    var version = 1
    let id: String
    let account: String
    let epoch: String
    let taskID: String
    let specID: String
    let signature: String
    let originalAt: Double
    let fireAt: Double
    var phase: Phase = .queued
    var revision = 0
    var valid: Bool {
        func text(_ value: String, limit: Int) -> Bool {
            !value.isEmpty && value.utf8.count <= limit && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        return version == 1 && LocationReminderIdentity.uuid(.string(id)) && LocationReminderIdentity.uuid(.string(epoch)) &&
            LocationReminderIdentity.account(account) && text(taskID, limit: 200) && text(specID, limit: 200) &&
            text(signature, limit: 4096) && !LocationReminderTicket.isLocationSignature(signature) &&
            originalAt.isFinite && fireAt.isFinite && (0...253_402_300_799).contains(originalAt) &&
            (0...253_402_300_799).contains(fireAt) && revision >= 0 && revision <= 1000
    }
    init?(request: ReminderRequest, epoch: String, id: String = UUID().uuidString.lowercased()) {
        guard request.snoozed, request.event.kind == .task else { return nil }
        self.id = id; account = request.account; self.epoch = epoch
        taskID = request.event.taskID; specID = request.event.specID; signature = request.event.signature
        originalAt = request.event.date.timeIntervalSince1970; fireAt = request.fireAt.timeIntervalSince1970
        guard valid else { return nil }
    }
    func request(account: String, epoch: String, tasks: [Record], now: Date, calendar: Calendar = .current) -> ReminderRequest? {
        guard valid, self.account == account, self.epoch == epoch, fireAt > now.timeIntervalSince1970,
              let event = DueReminder.validated(tasks: tasks, taskID: taskID, specID: specID, signature: signature,
                  originalAt: Date(timeIntervalSince1970: originalAt), calendar: calendar) else { return nil }
        return .make(account: account, event: event, fireAt: Date(timeIntervalSince1970: fireAt), snoozed: true)
    }
    func sameIntent(_ other: Self) -> Bool {
        var a = self, b = other; a.phase = .queued; b.phase = .queued; a.revision = 0; b.revision = 0
        return a == b
    }
    func changing(to phase: Phase) -> Self { var next = self; next.phase = phase; next.revision += 1; return next }
}

enum TimeSnoozeOutbox {
    static let maximum = 128
    static func valid(_ entries: [String: TimeSnoozeIntent]) -> Bool {
        entries.count <= maximum && entries.allSatisfy { $0.key == $0.value.id && $0.value.valid }
    }
    /// Local writes, Undo, sync and encrypted recovery may not rewind an intent.
    /// Only explicit notification input can introduce a new record.
    static func staging(previous: [String: TimeSnoozeIntent], proposed: [String: TimeSnoozeIntent], newIntent: TimeSnoozeIntent? = nil, now: Date = Date()) throws -> [String: TimeSnoozeIntent] {
        guard valid(previous), proposed.count <= maximum + (newIntent == nil ? 0 : 1), proposed.allSatisfy({ $0.key == $0.value.id && $0.value.valid }), now.timeIntervalSince1970.isFinite else { throw AppFailure(message: "Snooze recovery could not be read. Your tasks have not been replaced.") }
        if let newIntent { guard newIntent.valid, newIntent.phase == .queued, newIntent.revision == 0, proposed[newIntent.id] == newIntent else { throw AppFailure(message: "The new snooze could not be saved. Open its task to try again.") } }
        var next = previous.filter { $0.value.fireAt > now.timeIntervalSince1970 }
        for (id, value) in proposed where value.fireAt > now.timeIntervalSince1970 {
            if let old = next[id] {
                guard old.sameIntent(value), old.revision != value.revision || old == value else { throw AppFailure(message: "This snooze changed. Reopen its task before retrying.") }
                if value.revision > old.revision { next[id] = value }
            } else if let newIntent, newIntent == value, newIntent.phase == .queued, newIntent.revision == 0 {
                next[id] = value
            }
            // An imported/undone cache cannot introduce an unsubmitted alert.
        }
        guard valid(next) else { throw AppFailure(message: "Too many snoozes are waiting. Review your reminders before snoozing another alert.") }
        return next
    }
    static func reconciling(_ entries: [String: TimeSnoozeIntent], account: String, epoch: String, tasks: [Record], enabled: Bool, pending: [ReminderRequest], now: Date = Date(), calendar: Calendar = .current) -> [String: TimeSnoozeIntent] {
        entries.mapValues { entry in
            guard entry.phase != .closed else { return entry }
            guard enabled, let request = entry.request(account: account, epoch: epoch, tasks: tasks, now: now, calendar: calendar) else { return entry.changing(to: .closed) }
            if entry.phase == .queued && pending.contains(where: { $0.matchesSnooze(request) }) { return entry.changing(to: .installed) }
            if entry.phase == .reserved {
                return entry.changing(to: pending.contains { $0.matchesSnooze(request) } ? .installed : .closed)
            }
            // Installed requests belong to the OS. Missing/delivered ones never retry.
            if entry.phase == .installed && !pending.contains(where: { $0.matchesSnooze(request) }) { return entry.changing(to: .closed) }
            return entry
        }
    }
}
