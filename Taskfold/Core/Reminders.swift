import Foundation
import CryptoKit
import UserNotifications

/// Version 1 uses absolute instants or elapsed minutes relative to the planned time.
/// Version 2 adds independent local calendar schedules; old clients preserve them.
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
    init?(row: JSON) {
        let row = row.object
        guard [JSON.number(1), .number(2)].contains(row["version"] ?? .null), UUID(uuidString: row["id"]?.text ?? "") != nil,
              row["enabled"] == nil || row["enabled"] == .bool(true) || row["enabled"] == .bool(false),
              case .array(let channels)? = row["channels"], !channels.isEmpty,
              channels.allSatisfy({ ["local", "push", "email"].contains($0.text) }) else { return nil }
        raw = row
        switch kind {
        case "relative": guard row["version"] == .number(1), row["anchor"] == .string("planned"), offset != nil else { return nil }
        case "absolute": guard row["version"] == .number(1), absolute != nil, TimeZone(identifier: row["time_zone"]?.text ?? "") != nil else { return nil }
        case "recurring": guard row["version"] == .number(2), row["channels"] == .array([.string("local")]), schedule != nil else { return nil }
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
    var semanticKey: String {
        if let schedule { return "recurring|" + schedule.semanticFields.map { "\($0.utf8.count):\($0)" }.joined() }
        return kind + "|" + (kind == "relative" ? String(offset ?? 0) : absolute.map(ReminderSignature.milliseconds) ?? "")
    }
    var local: Bool { raw["channels"]?.list.contains(.string("local")) == true }
    var locallyEditable: Bool { raw["channels"] == .array([.string("local")]) }
    var label: String {
        if let schedule { return schedule.summary + " · " + schedule.time }
        if kind == "absolute", let date = absolute { return date.formatted(date: .abbreviated, time: .shortened) }
        guard let offset else { return "Unsupported reminder" }
        if offset == 0 { return "At planned time" }
        return "\(abs(offset)) min \(offset < 0 ? "before" : "after")"
    }
    func date(task: Record, calendar: Calendar, now: Date = Date()) -> Date? {
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
            let known = Set(["type", "interval", "daysOfWeek", "dayOfMonth", "monthOfYear", "weekday", "weekdayOrdinal", "count", "endDate", "fromCompletion"])
            var pattern = replacement.raw["recurrence"]?.object ?? [:]
            for (key, value) in raw["recurrence"]?.object ?? [:] where !known.contains(key) { pattern[key] = value }
            result.raw["recurrence"] = .object(pattern)
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
private struct ReminderCivilDay: Comparable {
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
            let elapsed = (threshold.year - year) * 12 + threshold.month - month, first = max(1, elapsed / n)
            for offset in first...(first + 400) {
                if let value = monthOffset(offset * n, rule: rule), value > threshold { result = value; break }
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
            for offset in 0...400 { if let value = monthOffset(offset, rule: rule), value >= self { result = value; break } }
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
        if ["monthly", "yearly"].contains(rule.string("type")), rule["dayOfMonth"] == .null, rule["weekdayOrdinal"] == .null { return nil }
        if rule.string("type") == "yearly", rule["monthOfYear"] == .null { return nil }
        guard day.first(rule) == day, instant(on: day) != nil else { return nil }
    }
    private func instant(on day: ReminderCivilDay) -> Date? {
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
        [startDay, time, timeZone, rule.string("type"), String(rule["interval"].integer == 0 ? 1 : rule["interval"].integer),
         Array(Set(rule["daysOfWeek"].list.map(\.integer))).sorted().map(String.init).joined(separator: ","),
         ["dayOfMonth", "monthOfYear", "weekday", "weekdayOrdinal", "count"].map { rule[$0] == .null ? "" : String(rule[$0].integer) }.joined(separator: ","), rule.string("endDate")]
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
        else if unit == "month" { value += " on \(rule["dayOfMonth"].integer)" }
        else if unit == "year" { value += " on " + QuickRecurrenceText.months[rule["monthOfYear"].integer - 1] + " \(rule["dayOfMonth"].integer)" }
        if !rule.string("endDate").isEmpty { value += " until " + rule.string("endDate") }
        if let count = Recurrence.number(rule["count"], in: 1...999) { value += " for \(count) occurrences" }
        return value
    }
    static func make(_ phrase: String, time: String, start: String, zone: String) -> Self? {
        guard let anchor = ReminderCivilDay(start) else { return nil }
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let now = Dates.parse(start, calendar: c), let parsed = QuickRecurrenceText.parse(phrase, now: now, calendar: c), !parsed.rule["fromCompletion"].flag else { return nil }
        var rule = parsed.rule
        let day = parsed.start.flatMap(ReminderCivilDay.init) ?? anchor
        if ["monthly", "yearly"].contains(rule.string("type")), rule["dayOfMonth"] == .null, rule["weekdayOrdinal"] == .null { rule["dayOfMonth"] = .number(Double(day.day)) }
        if rule.string("type") == "yearly", rule["monthOfYear"] == .null { rule["monthOfYear"] = .number(Double(day.month)) }
        guard let first = day.first(rule) else { return nil }
        return Self(raw: ["start_day": .string(first.key), "time": .string(time), "time_zone": .string(zone), "recurrence": .object(rule.fields)])
    }
    var raw: [String: JSON] { ["start_day": .string(startDay), "time": .string(time), "time_zone": .string(timeZone), "recurrence": .object(rule.fields)] }
}

/// The old device-wide switch migrates to the first active workspace only.
enum ReminderPreferences {
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
        let generation = task.string("task_generation").lowercased()
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
    func hasSignature(_ value: String) -> Bool { signature == value || legacySignature == value }
    static func == (a: Self, b: Self) -> Bool {
        a.kind == b.kind && a.id == b.id && a.title == b.title && a.body == b.body && a.date == b.date &&
        a.taskID == b.taskID && a.specID == b.specID && a.signature == b.signature && a.calendarOccurrence == b.calendarOccurrence
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
        let recurring = spec.schedule != nil
        let id = ReminderSpec.rows(task).isEmpty ? task.id : task.id + "." + spec.id + (recurring ? "." + ReminderSignature.milliseconds(date) : "")
        return DueReminder(id: id, title: task.title, body: task.string("description"), date: date, taskID: task.id, specID: spec.id,
            signature: ReminderSignature.make(task: task, spec: spec, date: date),
            legacySignature: !recurring && task.string("task_generation").isEmpty ? ReminderSignature.legacy(task: task, spec: spec, date: date) : nil,
            calendarOccurrence: recurring)
    }
    static func events(tasks: [Record], calendar: Calendar = .current, channels: Set<String> = ["local"], now: Date = Date()) -> [DueReminder] {
        var result: [DueReminder] = []
        for task in tasks {
            for spec in specifications(task, channels: channels) {
                if let schedule = spec.schedule {
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
        if let schedule = spec.schedule {
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
        let id = (event.kind == .focusFinish ? FocusFinish.prefix : prefix) + DueReminder.digest(account + "|" + event.taskID.lowercased() + "|" + event.specID + (event.calendarOccurrence ? "|" + ReminderSignature.milliseconds(event.date) : ""))
        return Self(identifier: id + (snoozed ? ".snooze" : ""), account: account, event: event, fireAt: fireAt ?? event.date, snoozed: snoozed)
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
    func validated(_ event: DueReminder) -> DueReminder? {
        if let matching = events.first(where: { $0.kind == event.kind && $0.taskID == event.taskID && $0.specID == event.specID && $0.hasSignature(event.signature) }) { return matching }
        guard event.kind == .task else { return nil }
        return DueReminder.validated(tasks: validationTasks, taskID: event.taskID, specID: event.specID, signature: event.signature, originalAt: event.date, calendar: calendar)
    }
}
struct ReminderReport: Equatable, Sendable {
    var revision: Int
    var scheduled = 0
    var deferred = 0
    var failures = 0
    var focusScheduled = false
    var focusFailure = false
    mutating func accepted(_ request: ReminderRequest) {
        if request.event.kind == .focusFinish { focusScheduled = true } else { scheduled += 1 }
    }
    mutating func failed(_ request: ReminderRequest) {
        if request.event.kind == .focusFinish { focusFailure = true } else { failures += 1 }
    }
}
protocol ReminderCenter: Sendable {
    func pending() async -> [ReminderRequest]
    func removeInvalid(_ state: ReminderState) async
    func remove(_ identifiers: [String]) async
    func add(_ request: ReminderRequest) async throws
}

/// A single drain serializes notification mutations even across suspension and account changes.
actor ReminderScheduler {
    private let center: any ReminderCenter
    private var desired = ReminderState(revision: -1, account: "", events: [])
    var currentRevision: Int { desired.revision }
    private var sequence = 0
    private var running = false
    private var snoozes: [ReminderRequest] = []
    private var waiters: [CheckedContinuation<ReminderReport, Never>] = []
    init(center: any ReminderCenter = SystemReminderCenter()) { self.center = center }
    func update(_ state: ReminderState) async -> ReminderReport {
        guard state.revision > desired.revision else { return ReminderReport(revision: desired.revision) }
        desired = state; sequence += 1
        return await sweep()
    }
    func snooze(account: String, taskID: String, specID: String, signature: String, minutes: Int = 60, now: Date = Date(), originalAt: Date? = nil) async -> ReminderReport? {
        guard ReminderSnooze.validMinutes(minutes), now.timeIntervalSince1970.isFinite, account == desired.account, let event = desired.events.first(where: { $0.kind == .task && $0.taskID == taskID && $0.specID == specID && $0.hasSignature(signature) }) ?? DueReminder.validated(tasks: desired.validationTasks, taskID: taskID, specID: specID, signature: signature, originalAt: originalAt, calendar: desired.calendar) else { return nil }
        let request = ReminderRequest.make(account: account, event: event, fireAt: now.addingTimeInterval(TimeInterval(minutes) * 60), snoozed: true)
        snoozes.removeAll { $0.identifier == request.identifier }; snoozes.append(request); sequence += 1
        return await sweep()
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
            let existing = await center.pending()
            guard token == sequence else { continue }
            snoozes.removeAll { !$0.valid(state: state) || $0.fireAt <= state.now }
            let retained = existing.filter { $0.snoozed && $0.valid(state: state) && $0.fireAt > state.now }.compactMap { old -> ReminderRequest? in
                guard let event = state.validated(old.event) else { return nil }
                return ReminderRequest.make(account:state.account,event:event,fireAt:old.fireAt,snoozed:true)
            }
            var requests = state.account.isEmpty ? [] : state.events.filter { $0.date > state.now }.map { ReminderRequest.make(account: state.account, event: $0) }
            requests += retained.filter { old in !snoozes.contains(where: { $0.identifier == old.identifier }) }
            requests += snoozes
            requests.sort {
                if $0.event.kind != $1.event.kind { return $0.event.kind == .focusFinish }
                return $0.fireAt == $1.fireAt ? $0.identifier < $1.identifier : $0.fireAt < $1.fireAt
            }
            var report = ReminderReport(revision: state.revision, deferred: max(0, requests.count - 60))
            requests = Array(requests.prefix(60))
            await center.removeInvalid(state)
            guard token == sequence else { continue }
            let expected = Set(requests.map(\.identifier))
            await center.remove(existing.map(\.identifier).filter { !expected.contains($0) })
            guard token == sequence else { continue }
            var acceptedSnoozes = Set<String>()
            for request in requests {
                if token != sequence { break }
                if existing.contains(request) { report.accepted(request); if request.snoozed { acceptedSnoozes.insert(request.identifier) }; continue }
                do { try await center.add(request); report.accepted(request); if request.snoozed { acceptedSnoozes.insert(request.identifier) } }
                catch { report.failed(request) }
            }
            guard token == sequence else { continue }
            snoozes.removeAll { acceptedSnoozes.contains($0.identifier) }
            let completions = waiters; waiters = []; running = false
            for completion in completions { completion.resume(returning: report) }
            return
        }
    }
}

struct SystemReminderCenter: ReminderCenter {
    private var center: UNUserNotificationCenter { .current() }
    static func decode(_ request: UNNotificationRequest) -> ReminderRequest? {
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
            event: DueReminder(kind: kind, id: info["eventID"] as? String ?? task + "." + spec, title: request.content.title, body: request.content.body, date: Date(timeIntervalSince1970: original), taskID: task, specID: spec, signature: signature, calendarOccurrence: info["calendarOccurrence"] as? Bool ?? false),
            fireAt: Date(timeIntervalSince1970: fire), snoozed: info["snoozed"] as? Bool ?? false)
        if decoded.event.calendarOccurrence && decoded.identifier != ReminderRequest.make(account: account, event: decoded.event, fireAt: decoded.fireAt, snoozed: decoded.snoozed).identifier { return nil }
        if kind == .focusFinish && decoded.identifier != ReminderRequest.make(account: account, event: decoded.event).identifier { return nil }
        return decoded
    }
    func pending() async -> [ReminderRequest] { await center.pendingNotificationRequests().compactMap(Self.decode) }
    func removeInvalid(_ state: ReminderState) async {
        func stale(_ request: UNNotificationRequest) -> Bool {
            // Touch only Taskfold's reminder category and versioned namespace.
            guard request.content.categoryIdentifier == "taskfold.reminder" || request.identifier.hasPrefix(ReminderRequest.prefix) || request.content.categoryIdentifier == FocusFinish.category || request.identifier.hasPrefix(FocusFinish.prefix) else { return false }
            return Self.decode(request)?.valid(state: state) != true
        }
        center.removePendingNotificationRequests(withIdentifiers: await center.pendingNotificationRequests().filter(stale).map(\.identifier))
        center.removeDeliveredNotifications(withIdentifiers: await center.deliveredNotifications().map(\.request).filter(stale).map(\.identifier))
    }
    func remove(_ identifiers: [String]) async { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    static func trigger(at date: Date) -> UNCalendarNotificationTrigger {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        components.timeZone = calendar.timeZone; components.calendar = calendar
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }
    static func content(for request: ReminderRequest) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = request.event.title; content.body = request.event.body; content.sound = .default
        content.categoryIdentifier = request.event.kind == .focusFinish ? FocusFinish.category : "taskfold.reminder"
        content.userInfo = ["eventKind": request.event.kind.rawValue, "eventID": request.event.id, "accountID": request.account, "taskID": request.event.taskID, "specID": request.event.specID, "signature": request.event.signature, "originalAt": request.event.date.timeIntervalSince1970, "fireAt": request.fireAt.timeIntervalSince1970, "snoozed": request.snoozed, "calendarOccurrence": request.event.calendarOccurrence]
        return content
    }
    func add(_ request: ReminderRequest) async throws {
        // An explicit UTC instant preserves both sides of a daylight-saving fold.
        try await center.add(UNNotificationRequest(identifier: request.identifier, content: Self.content(for: request), trigger: Self.trigger(at: request.fireAt)))
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
    func matches(account: String, generation: UUID, events: [DueReminder]) -> Bool {
        workspace.matches(account: account, generation: generation) && events.contains {
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
