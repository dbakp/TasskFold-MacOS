import Foundation

/// The same persisted rules are owned by each native client. Dates are Gregorian civil days,
/// and fixed-time series use their source zone even after the user travels.
enum Recurrence {
    static let types = ["daily", "weekly", "monthly", "yearly", "custom"]
    static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    static let ordinals = [1: "First", 2: "Second", 3: "Third", 4: "Fourth", 5: "Fifth", -1: "Last"]
    static func number(_ value: JSON, in range: ClosedRange<Int>) -> Int? {
        guard case .number(let n) = value, n.isFinite, n.rounded() == n, n >= Double(range.lowerBound), n <= Double(range.upperBound) else { return nil }
        return Int(n)
    }
    static func valid(_ p: Record) -> Bool {
        guard types.contains(p.string("type")), p["interval"] == .null || number(p["interval"], in: 1...10000) != nil else { return false }
        for (key, range) in [("dayOfMonth", 1...31), ("monthOfYear", 1...12), ("weekday", 0...6), ("count", 1...2147483647)] where p[key] != .null {
            guard number(p[key], in: range) != nil else { return false }
        }
        if p["weekdayOrdinal"] != .null {
            guard let ordinal = number(p["weekdayOrdinal"], in: -1...5), ordinals[ordinal] != nil,
                  p.string("type") == "monthly", number(p["weekday"], in: 0...6) != nil else { return false }
        }
        if p["daysOfWeek"] != .null {
            guard case .array(let days) = p["daysOfWeek"], days.count <= 7, days.allSatisfy({ number($0, in: 0...6) != nil }) else { return false }
        }
        if p["fromCompletion"] != .null { guard case .bool = p["fromCompletion"] else { return false } }
        if p["endDate"] == .null { return true }
        guard case .string(let end) = p["endDate"] else { return false }
        return end.isEmpty || (end.count == 10 && Dates.parse(end) != nil)
    }
    static func monthDate(_ month: Date, day: Int, weekday: Int?, ordinal: Int?, calendar: Calendar) -> Date? {
        var parts = calendar.dateComponents([.year, .month], from: month)
        guard let year = parts.year, (1...9999).contains(year), let range = calendar.range(of: .day, in: .month, for: month) else { return nil }
        if let weekday, let ordinal {
            parts.day = ordinal == -1 ? range.count : 1
            guard let edge = calendar.date(from: parts) else { return nil }
            let edgeDay = calendar.component(.weekday, from: edge) - 1
            parts.day = ordinal == -1 ? range.count - (edgeDay - weekday + 7) % 7 : 1 + (weekday - edgeDay + 7) % 7 + (ordinal - 1) * 7
            guard let value = parts.day, range.contains(value) else { return nil } // A fifth weekday can be absent.
        } else { parts.day = min(day, range.count) }
        return calendar.date(from: parts)
    }
    /// Completion-based calendar rules wait the whole interval, then find the first
    /// chosen calendar day at or after it. A weekday never silently shortens two weeks.
    private static func afterCompletion(_ p: Record, origin: Date, interval: Int, calendar: Calendar) -> Date? {
        let component: Calendar.Component = ["daily": .day, "custom": .day, "weekly": .day, "monthly": .month, "yearly": .year][p.string("type")] ?? .day
        let amount = p.string("type") == "weekly" ? interval * 7 : interval
        guard let waited = calendar.date(byAdding: component, value: amount, to: origin), calendar.component(.year, from: waited) <= 9999 else { return nil }
        if p.string("type") == "weekly", !p["daysOfWeek"].list.isEmpty {
            let weekday = calendar.component(.weekday, from: waited) - 1
            let delta = p["daysOfWeek"].list.compactMap { number($0, in: 0...6) }.map { ($0 - weekday + 7) % 7 }.min() ?? 0
            return calendar.date(byAdding: .day, value: delta, to: waited)
        }
        if p.string("type") == "monthly", p["dayOfMonth"] != .null || p["weekdayOrdinal"] != .null {
            var parts = calendar.dateComponents([.year, .month], from: waited); parts.day = 1
            guard let month = calendar.date(from: parts) else { return nil }
            for offset in 0...400 {
                guard let target = calendar.date(byAdding: .month, value: offset, to: month), calendar.component(.year, from: target) <= 9999 else { return nil }
                if let day = monthDate(target, day: number(p["dayOfMonth"], in: 1...31) ?? 1, weekday: number(p["weekday"], in: 0...6), ordinal: number(p["weekdayOrdinal"], in: -1...5), calendar: calendar), day >= waited { return day }
            }
            return nil
        }
        if p.string("type") == "yearly", p["dayOfMonth"] != .null || p["monthOfYear"] != .null {
            let year = calendar.component(.year, from: waited)
            for offset in 0...1 {
                guard year + offset <= 9999, let month = calendar.date(from: DateComponents(year: year + offset, month: number(p["monthOfYear"], in: 1...12) ?? calendar.component(.month, from: waited), day: 1)) else { return nil }
                if let day = monthDate(month, day: number(p["dayOfMonth"], in: 1...31) ?? calendar.component(.day, from: waited), weekday: nil, ordinal: nil, calendar: calendar), day >= waited { return day }
            }
            return nil
        }
        return waited
    }
    static func effective(_ task: Record) -> Record {
        var p = Record(task["recurrence_pattern"].object)
        if p.string("endDate").isEmpty, !task.string("recurrence_end_date").isEmpty { p["endDate"] = task["recurrence_end_date"] }
        return p
    }
    static func next(_ task: Record, calendar: Calendar, completion: Date? = nil) -> Date? {
        guard task["is_recurring"].flag, let stored = Dates.parse(task.string("due_date"), calendar: calendar) else { return nil }
        let p = Record(task["recurrence_pattern"].object)
        guard valid(p), p["count"] != .number(1) else { return nil }
        let interval = number(p["interval"], in: 1...10000) ?? 1
        let origin = p["fromCompletion"].flag ? completion.map { calendar.startOfDay(for: $0) } ?? stored : stored
        let threshold = max(origin, completion.map { calendar.startOfDay(for: $0) } ?? origin)
        var result: Date?
        if p["fromCompletion"].flag {
            result = afterCompletion(p, origin: origin, interval: interval, calendar: calendar)
        } else {
        switch p.string("type") {
        case "daily", "custom":
            let days = calendar.dateComponents([.day], from: origin, to: threshold).day ?? 0
            result = calendar.date(byAdding: .day, value: (days / interval + 1) * interval, to: origin)
        case "weekly":
            let days = Array(Set(p["daysOfWeek"].list.compactMap { number($0, in: 0...6) })).sorted()
            if days.isEmpty {
                let elapsed = calendar.dateComponents([.day], from: origin, to: threshold).day ?? 0, span = 7 * interval
                result = calendar.date(byAdding: .day, value: (elapsed / span + 1) * span, to: origin)
            } else {
                let weekday = calendar.component(.weekday, from: origin) - 1
                guard let week = calendar.date(byAdding: .day, value: -weekday, to: origin) else { return nil }
                let elapsed = calendar.dateComponents([.day], from: week, to: threshold).day ?? 0
                let cycle = elapsed / (7 * interval)
                for offset in cycle...(cycle + 1) {
                    for day in days {
                        if let date = calendar.date(byAdding: .day, value: offset * 7 * interval + day, to: week), date > threshold { result = date; break }
                    }
                    if result != nil { break }
                }
            }
        case "monthly":
            var parts = calendar.dateComponents([.year, .month], from: origin); parts.day = 1
            guard let month = calendar.date(from: parts) else { return nil }
            let elapsed = calendar.dateComponents([.month], from: month, to: threshold).month ?? 0
            let start = max(1, elapsed / interval)
            for offset in start...(start + 400) {
                guard let target = calendar.date(byAdding: .month, value: offset * interval, to: month), calendar.component(.year, from: target) <= 9999 else { return nil }
                if let date = monthDate(target, day: number(p["dayOfMonth"], in: 1...31) ?? calendar.component(.day, from: origin), weekday: number(p["weekday"], in: 0...6), ordinal: number(p["weekdayOrdinal"], in: -1...5), calendar: calendar), date > threshold { result = date; break }
            }
        case "yearly":
            let originalYear = calendar.component(.year, from: origin)
            let elapsed = calendar.component(.year, from: threshold) - originalYear
            let start = max(1, elapsed / interval)
            for offset in start...(start + 1) {
                let year = originalYear + offset * interval
                guard year <= 9999, let month = calendar.date(from: DateComponents(year: year, month: number(p["monthOfYear"], in: 1...12) ?? calendar.component(.month, from: origin), day: 1)) else { return nil }
                if let date = monthDate(month, day: number(p["dayOfMonth"], in: 1...31) ?? calendar.component(.day, from: origin), weekday: nil, ordinal: nil, calendar: calendar), date > threshold { result = date; break }
            }
        default: return nil
        }
        }
        guard let result, (1...9999).contains(calendar.component(.year, from: result)) else { return nil }
        let end = p.string("endDate").isEmpty ? task.string("recurrence_end_date") : p.string("endDate")
        if !end.isEmpty {
            guard end.count == 10, let limit = Dates.parse(end, calendar: calendar), result <= limit else { return nil }
        }
        return result
    }
    static func summary(_ p: Record) -> String {
        guard valid(p) else { return "Unsupported repeat rule" }
        let interval = number(p["interval"], in: 1...10000) ?? 1
        let unit = ["daily":"day", "weekly":"week", "monthly":"month", "yearly":"year", "custom":"day"][p.string("type")] ?? "day"
        var parts = [interval == 1 ? "Every \(unit)" : "Every \(interval) \(unit)s"]
        let days = Array(Set(p["daysOfWeek"].list.compactMap { number($0, in: 0...6) })).sorted()
        if p.string("type") == "weekly", !days.isEmpty { parts.append(days.map { weekdays[$0].prefix(3).capitalized }.joined(separator: ", ")) }
        if let ordinal = number(p["weekdayOrdinal"], in: -1...5), let day = number(p["weekday"], in: 0...6) { parts.append((ordinals[ordinal] ?? "") + " " + weekdays[day].capitalized) }
        else if let day = number(p["dayOfMonth"], in: 1...31) {
            if let month = number(p["monthOfYear"], in: 1...12) { parts.append(DateFormatter().monthSymbols[month - 1] + " \(day)") }
            else { parts.append("Day \(day)") }
        }
        if p["fromCompletion"].flag { parts.append("From completion") }
        if !p.string("endDate").isEmpty { parts.append("Until " + p.string("endDate")) }
        if let count = number(p["count"], in: 1...2147483647) { parts.append("\(count) left") }
        return parts.joined(separator: " · ")
    }
}

/// Complete phrases are protected as one unit when declined/invalid, so an end date or
/// weekday cannot accidentally be consumed by the ordinary planned-date parser.
enum QuickRecurrenceText {
    static let day = #"(?:sunday|monday|tuesday|wednesday|thursday|friday|saturday|sun|mon|tue|wed|thu|fri|sat)\b"#
    static let ordinal = #"(?:first|second|third|fourth|fifth|last|\d+(?:st|nd|rd|th)?)"#
    static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    static let days = day + #"(?:(?:\s*,\s*(?:and\s+)?|\s+and\s+)(?!(?:every!?|daily|weekly|monthly|yearly)\b)[\p{L}\p{N}_-]+\b)*"#
    static let on = #"(?:the\s+)?(?:"# + ordinal + #"\s+"# + day + #"|[a-z]+\s+\d+(?:st|nd|rd|th)?|"# + days + #"|\S+)"#
    static let pattern = #"(?<![\p{L}\p{N}_!])(?:every!?\s+(?:(?:(?:\d+|other)\s+)?(?:days?|weeks?|months?|years?)\b(?:\s+on\s+"# + on + #")?|(?:weekdays?|workdays?|weekends?)\b|"# + ordinal + #"\s+"# + day + #"|"# + days + #"|\S+(?:\s+"# + day + #")?)|daily\b|weekly\b|monthly\b|yearly\b)(?:\s+(?:(?:starting|from|until|ending)(?:\s+on)?\s+(?:next\s+)?\S+(?:\s+\d{1,2}(?:st|nd|rd|th)?\b)?|for\s+\S+\s+\S+))*"#
    struct Parsed { var rule: Record; var start: String? }
    static func parse(_ raw: String) -> Parsed? {
        var body = raw.lowercased().trimmingCharacters(in: .whitespaces)
        var rule = Record(["interval": .number(1)])
        var start: String?
        let suffix = #"\s+(starting|from|until|ending)(?:\s+on)?\s+(\S+)|\s+for\s+(\S+)\s+(?:occurrences?|times)\b"#
        guard let regex = try? NSRegularExpression(pattern: suffix) else { return nil }
        let matches = regex.matches(in: body, range: NSRange(body.startIndex..., in: body))
        var keys = Set<String>()
        for m in matches.reversed() {
            func value(_ i: Int) -> String { Range(m.range(at: i), in: body).map { String(body[$0]) } ?? "" }
            let kind = value(1), date = value(2)
            let key = kind.isEmpty ? "count" : ["starting", "from"].contains(kind) ? "start" : "endDate"
            guard keys.insert(key).inserted else { return nil }
            if key == "count" { guard let n = Int(value(3)), (1...999).contains(n) else { return nil }; rule["count"] = .number(Double(n)) }
            else { guard date.count == 10, Dates.parse(date) != nil else { return nil }; if key == "start" { start = date } else { rule["endDate"] = .string(date) } }
            if let range = Range(m.range, in: body) { body.removeSubrange(range) }
        }
        func match(_ pattern: String, _ input: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$"), let m = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) else { return nil }
            return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: input).map { String(input[$0]) } ?? "" }
        }
        func weekday(_ value: String) -> Int? { Recurrence.weekdays.firstIndex { $0 == value || String($0.prefix(3)) == value } }
        func weekdays(_ value: String) -> [Int]? {
            let words = value.replacingOccurrences(of: "and", with: ",").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let days = words.compactMap(weekday)
            return !days.isEmpty && words.count == days.count ? Array(Set(days)).sorted() : nil
        }
        if body.hasPrefix("every! ") { rule["fromCompletion"] = .bool(true); body = String(body.dropFirst(7)) }
        else if body.hasPrefix("every ") { body = String(body.dropFirst(6)) }
        if ["daily", "weekly", "monthly", "yearly"].contains(body) { rule["type"] = .string(body) }
        else if ["weekday", "weekdays", "workday", "workdays", "weekend", "weekends"].contains(body) {
            rule["type"] = .string("weekly"); rule["daysOfWeek"] = .array((body.hasPrefix("weekend") ? [0,6] : [1,2,3,4,5]).map { .number(Double($0)) })
        } else if let days = weekdays(body) {
            rule["type"] = .string("weekly"); rule["daysOfWeek"] = .array(days.map { .number(Double($0)) })
        } else {
            var detail = ""
            if let m = match(#"(?:(\d+|other)\s+)?(day|week|month|year)s?(?:\s+on\s+(.+))?"#, body) {
                let interval = m[1] == "other" ? 2 : Int(m[1]) ?? (m[1].isEmpty ? 1 : 0)
                guard (1...365).contains(interval) else { return nil }
                rule["interval"] = .number(Double(interval)); rule["type"] = .string(["day":"daily", "week":"weekly", "month":"monthly", "year":"yearly"][m[2]]!)
                detail = m[3].replacingOccurrences(of: #"^the\s+"#, with: "", options: .regularExpression)
                if detail.isEmpty { return Parsed(rule: rule, start: start) }
            } else { rule["type"] = .string("monthly"); detail = body }
            if rule.string("type") == "weekly", let days = weekdays(detail) { rule["daysOfWeek"] = .array(days.map { .number(Double($0)) }) }
            else if rule.string("type") == "monthly", let m = match("(" + ordinal + ")\\s+(" + day + ")", detail), let day = weekday(m[2]) {
                let names = ["first":1,"second":2,"third":3,"fourth":4,"fifth":5,"last":-1]
                let n = names[m[1]] ?? Int(m[1].filter(\.isNumber)) ?? 0
                guard Recurrence.ordinals[n] != nil else { return nil }
                rule["weekdayOrdinal"] = .number(Double(n)); rule["weekday"] = .number(Double(day))
            } else if rule.string("type") == "monthly", let m = match(#"(\d+)(?:st|nd|rd|th)?"#, detail), let n = Int(m[1]), (1...31).contains(n) { rule["dayOfMonth"] = .number(Double(n)) }
            else if rule.string("type") == "yearly", let m = match(#"([a-z]+)\s+(\d+)(?:st|nd|rd|th)?"#, detail), let month = months.firstIndex(where: { $0 == m[1] || String($0.prefix(3)) == m[1] }), let n = Int(m[2]), (1...31).contains(n) {
                guard Dates.parse(String(format: "2000-%02d-%02d", month + 1, n)) != nil else { return nil }
                rule["monthOfYear"] = .number(Double(month + 1)); rule["dayOfMonth"] = .number(Double(n))
            } else { return nil }
        }
        return Recurrence.valid(rule) ? Parsed(rule: rule, start: start) : nil
    }
    static func first(_ parsed: Parsed, now: Date, existing: String, calendar: Calendar) -> (Record, String)? {
        var rule = parsed.rule
        let anchor = parsed.start.flatMap { Dates.parse($0, calendar: calendar) } ?? Dates.parse(existing, calendar: calendar) ?? calendar.startOfDay(for: now)
        var first = anchor
        let days = rule["daysOfWeek"].list
        if !days.isEmpty {
            let weekday = calendar.component(.weekday, from: anchor) - 1
            // A bare single weekday retains the existing next-weekday behavior. A stated
            // starting day is inclusive, and weekday/workday sets can start today.
            let inclusive = parsed.start != nil || !existing.isEmpty || days.count > 1
            let delta = days.map { ($0.integer - weekday + 7) % 7 }.map { $0 == 0 && !inclusive ? 7 : $0 }.min() ?? 0
            first = calendar.date(byAdding: .day, value: delta, to: anchor) ?? anchor
        } else if rule.string("type") == "monthly", rule["dayOfMonth"] != .null || rule["weekdayOrdinal"] != .null {
            var parts = calendar.dateComponents([.year, .month], from: anchor); parts.day = 1
            guard let month = calendar.date(from: parts) else { return nil }
            var found: Date?
            for offset in 0...400 {
                guard let target = calendar.date(byAdding: .month, value: offset, to: month), calendar.component(.year, from: target) <= 9999 else { return nil }
                if let date = Recurrence.monthDate(target, day: rule["dayOfMonth"].integer, weekday: Recurrence.number(rule["weekday"], in: 0...6), ordinal: Recurrence.number(rule["weekdayOrdinal"], in: -1...5), calendar: calendar), date >= anchor { found = date; break }
            }
            guard let found else { return nil }; first = found
        } else if rule.string("type") == "yearly", rule["monthOfYear"] != .null {
            let year = calendar.component(.year, from: anchor)
            guard let month = calendar.date(from: DateComponents(year: year, month: rule["monthOfYear"].integer, day: 1)) else { return nil }
            first = Recurrence.monthDate(month, day: rule["dayOfMonth"].integer, weekday: nil, ordinal: nil, calendar: calendar) ?? anchor
            if first < anchor {
                guard let nextMonth = calendar.date(byAdding: .year, value: 1, to: month), let date = Recurrence.monthDate(nextMonth, day: rule["dayOfMonth"].integer, weekday: nil, ordinal: nil, calendar: calendar) else { return nil }; first = date
            }
        }
        if !rule["fromCompletion"].flag {
            if ["monthly", "yearly"].contains(rule.string("type")), rule["dayOfMonth"] == .null, rule["weekdayOrdinal"] == .null { rule["dayOfMonth"] = .number(Double(calendar.component(.day, from: first))) }
            if rule.string("type") == "yearly", rule["monthOfYear"] == .null { rule["monthOfYear"] = .number(Double(calendar.component(.month, from: first))) }
        }
        if !rule.string("endDate").isEmpty, let end = Dates.parse(rule.string("endDate"), calendar: calendar), first > end { return nil }
        return (rule, TaskPlanner.dayKey(first, calendar: calendar))
    }
}
