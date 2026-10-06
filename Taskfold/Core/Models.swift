import Foundation

/// Lossless JSON keeps optional and future backend fields intact across edits.
enum JSON: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([JSON]), object([String: JSON]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var text: String { if case .string(let v) = self { return v }; return "" }
    var flag: Bool { if case .bool(let v) = self { return v }; return false }
    var integer: Int { if case .number(let v) = self { return Int(v) }; return 0 }
    var list: [JSON] { if case .array(let v) = self { return v }; return [] }
    var object: [String: JSON] { if case .object(let v) = self { return v }; return [:] }
}

struct Record: Codable, Identifiable, Equatable, Sendable {
    var fields: [String: JSON]
    var id: String { string("id") }
    init(_ fields: [String: JSON] = [:]) { self.fields = fields }
    init(from decoder: Decoder) throws { fields = try [String: JSON](from: decoder) }
    func encode(to encoder: Encoder) throws { try fields.encode(to: encoder) }
    subscript(_ key: String) -> JSON {
        get { fields[key] ?? .null }
        set { fields[key] = newValue }
    }
    func string(_ key: String) -> String { self[key].text }
    var title: String { string("title") }
    var name: String { string("name") }
    var completed: Bool { self["completed"].flag }
    var priority: Int { max(1, min(4, self["priority"].integer == 0 ? 4 : self["priority"].integer)) }
    var due: Date? { Dates.parse(string("due_date")) }
    var deadline: Date? { Dates.parse(string("deadline_date")) }
    var durationMinutes: Int? { (1...10080).contains(self["duration_minutes"].integer) ? self["duration_minutes"].integer : nil }
    static func task(user: String, project: String = "", date: Date? = nil) -> Record {
        Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(user),
                "title": .string(""), "description": .string(""), "completed": .bool(false),
                "priority": .number(4), "project_id": project.isEmpty ? .null : .string(project),
                "due_date": date.map { .string(Dates.day($0)) } ?? .null,
                "created_at": .string(Dates.timestamp()), "labels": .array([]),
                "subtasks": .array([]), "comments": .array([]), "attachments": .array([]),
                "reminders": .array([]), "is_recurring": .bool(false)])
    }
}

enum Dates {
    static func day(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    static func parse(_ string: String, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date? {
        // Stored dates are ISO Gregorian days, independent of the user's display calendar.
        var calendar = calendar
        if calendar.identifier != .gregorian {
            let zone = calendar.timeZone; calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        }
        let pieces = String(string.prefix(10)).split(separator: "-")
        guard pieces.count == 3, let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]),
              pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2 else { return nil }
        let parts = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: parts) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        return actual.year == year && actual.month == month && actual.day == day ? date : nil
    }
    static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
    static func next(_ task: Record, calendar: Calendar = .current) -> Date? {
        guard task["is_recurring"].flag, let current = task.due else { return nil }
        let p = Record(task["recurrence_pattern"].object)
        let interval = max(1, p["interval"].integer)
        var next: Date?
        switch p.string("type") {
        case "weekly":
            let days = p["daysOfWeek"].list.map(\.integer).filter { (0...6).contains($0) }.sorted()
            if let first = days.first {
                let weekday = calendar.component(.weekday, from: current) - 1
                let delta = days.first(where: { $0 > weekday }).map { $0 - weekday }
                    ?? (7 - weekday + first + (interval - 1) * 7)
                next = calendar.date(byAdding: .day, value: delta, to: current)
            } else { next = calendar.date(byAdding: .day, value: 7 * interval, to: current) }
        case "monthly":
            next = calendar.date(byAdding: .month, value: interval, to: current)
            if let n = next, p["dayOfMonth"].integer > 0,
               let range = calendar.range(of: .day, in: .month, for: n) {
                var parts = calendar.dateComponents([.year, .month], from: n)
                parts.day = min(p["dayOfMonth"].integer, range.count)
                next = calendar.date(from: parts)
            }
        case "daily", "custom": next = calendar.date(byAdding: .day, value: interval, to: current)
        default: return nil
        }
        guard let next else { return nil }
        let endString = p.string("endDate").isEmpty ? task.string("recurrence_end_date") : p.string("endDate")
        if let end = parse(endString), day(next) > day(end) { return nil }
        if p["count"].integer == 1 { return nil }
        return next
    }
}

struct Mutation: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var table: String
    var recordID: String
    var method: String
    var fields: [String: JSON]
    /// Optional for caches written before collaboration support. Captured before applying an edit.
    var baseline: [String: JSON]? = nil
    /// Restore creates never overwrite an already present server row on retry.
    var insertOnly: Bool? = nil
}

/// Applies only the user's changes when explicitly resolving a conflict. Remote-only items survive.
enum TaskEdit {
    static func keepingLocal(base: JSON, desired: JSON, remote: JSON) -> JSON {
        if desired == base { return remote }
        if remote == base || remote == desired { return desired }
        if case .object(let b) = base, case .object(let d) = desired, case .object(let c) = remote {
            var result = c
            for key in Set(b.keys).union(d.keys) where b[key] != d[key] {
                if let value = d[key] { result[key] = keepingLocal(base: b[key] ?? .null, desired: value, remote: c[key] ?? .null) }
                else { result.removeValue(forKey: key) }
            }
            return .object(result)
        }
        if case .array(let b) = base, case .array(let d) = desired, case .array(let c) = remote,
           [b, d, c].allSatisfy({ items in
               let ids = items.map { $0.object["id"]?.text ?? "" }
               return !ids.contains("") && Set(ids).count == ids.count
           }) {
            let before = Dictionary(uniqueKeysWithValues: b.map { ($0.object["id"]!.text, $0) })
            let after = Dictionary(uniqueKeysWithValues: d.map { ($0.object["id"]!.text, $0) })
            var result: [JSON] = c.compactMap { item in
                let id = item.object["id"]!.text
                guard let old = before[id] else { return after[id] ?? item }
                guard let desired = after[id] else { return nil }
                return keepingLocal(base: old, desired: desired, remote: item)
            }
            let remoteIDs = Set(c.map { $0.object["id"]!.text })
            result += d.filter { item in
                let id = item.object["id"]!.text
                return !remoteIDs.contains(id) && (before[id] == nil || before[id] != item)
            }
            return .array(result)
        }
        return desired
    }
}

struct SyncConflict: Identifiable {
    var mutation: Mutation
    var remote: Record
    var id: UUID { mutation.id }

    /// Resolve only the edit that was reviewed, then replay later offline work.
    /// Returning nil leaves stale or mismatched review requests untouched.
    func resolving(_ snapshot: Snapshot, keepLocal: Bool) -> Snapshot? {
        guard mutation.table == "tasks", mutation.method == "PATCH",
              remote.id.lowercased() == mutation.recordID.lowercased(),
              let index = snapshot.pending.firstIndex(where: { $0 == mutation }) else { return nil }
        var result = snapshot
        if keepLocal {
            result.pending[index].fields = Dictionary(uniqueKeysWithValues: mutation.fields.map { key, value in
                (key, mutation.baseline?[key].map { TaskEdit.keepingLocal(base: $0, desired: value, remote: remote[key]) } ?? value)
            })
            result.pending[index].baseline = Dictionary(uniqueKeysWithValues: mutation.fields.keys.map { ($0, remote[$0]) })
        } else { result.pending.remove(at: index) }
        // PostgreSQL spells UUIDs in lowercase. Retain one cache identity while
        // replaying a pre-upgrade queue that may use a different UUID spelling.
        result.tables["tasks"] = (result.tables["tasks"] ?? []).map { value in
            var row = value
            if row.id.lowercased() == mutation.recordID.lowercased() { row["id"] = .string(mutation.recordID) }
            return row
        }
        var remoteFields = remote.fields; remoteFields["id"] = .string(mutation.recordID)
        result.apply(Mutation(table: "tasks", recordID: mutation.recordID, method: "PATCH", fields: remoteFields))
        for change in result.pending where change.table == "tasks" && change.recordID.lowercased() == mutation.recordID.lowercased() {
            var local = change; local.recordID = mutation.recordID
            if local.fields["id"] != nil { local.fields["id"] = .string(mutation.recordID) }
            result.apply(local)
        }
        return result
    }
}

struct Snapshot: Codable, Equatable, Sendable {
    var tables: [String: [Record]] = [:]
    var pending: [Mutation] = []
    mutating func apply(_ change: Mutation) {
        var rows = tables[change.table] ?? []
        if change.method == "DELETE" { rows.removeAll { $0.id == change.recordID } }
        else if let i = rows.firstIndex(where: { $0.id == change.recordID }) {
            rows[i].fields.merge(change.fields) { _, new in new }
        } else { rows.append(Record(change.fields)) }
        tables[change.table] = rows
    }
    mutating func mergeRemote(_ remote: [String: [Record]]) {
        tables.merge(remote) { _, new in new }
        for change in pending { apply(change) }
    }
}

struct QuickEntry {
    /// One recognised piece of the title: which field group it feeds and the exact text it came from.
    struct Token: Equatable, Identifiable {
        var group: String
        var text: String
        var label: String
        var id: String { group + ":" + text }
    }
    static let groups = ["priority", "labels", "due_time", "recurrence", "due_date", "deadline_date", "duration_minutes", "project_id", "section_id", "assigned_to"]
    var title: String
    var updates: [String: JSON] = [:]
    var tokens: [Token] = []
    var warnings: [String] = []
    private var knownLabels: [Record] = []
    var hasSuggestions: Bool { !updates.isEmpty }
    /// Parses `input`. Groups in `disabled` are left untouched in the title and produce no updates,
    /// so a user can decline a single suggestion (for example keep "tomorrow" as part of the name).
    init(_ input: String, now: Date = Date(), calendar: Calendar = .current, disabled: Set<String> = [], context: QuickEntryContext = QuickEntryContext()) {
        let references = QuickEntryReferences(input, context: context, disabled: disabled)
        title = references.title; updates = references.updates; tokens = references.tokens; warnings = references.warnings; knownLabels = context.labels
        var literals = references.literals
        func protect(_ pattern: String, removeEscape: Bool = false) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            while let found = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)), let range = Range(found.range, in: title) {
                let original = String(title[range])
                let marker = "\u{E000}" + UUID().uuidString + "\u{E001}"
                literals.append((marker, removeEscape ? String(original.dropFirst()) : original))
                title.replaceSubrange(range, with: marker)
            }
        }
        protect(#"\\(?:[#/@%+](?:"[^"\n]*"|[^\s]+)|\{[^}]+\}|[^\s]+)"#, removeEscape: true)
        protect(#""[^"\n]*""#)
        func match(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let m = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) else { return nil }
            return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: title).map { String(title[$0]) } ?? "" }
        }
        func take(_ group: String, _ text: String, _ label: String) {
            if let range = title.range(of: text) { title.removeSubrange(range) }
            tokens.append(Token(group: group, text: text, label: label))
        }
        func enabled(_ group: String) -> Bool { !disabled.contains(group) }
        func timeLabel(_ hour: Int, _ minute: Int) -> String {
            let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
            return date.formatted(date: .omitted, time: .shortened)
        }
        func dayLabel(_ date: Date) -> String {
            if calendar.isDate(date, inSameDayAs: now) { return "Today" }
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        if enabled("deadline_date"), let m = match(#"\{(\d{4}-\d{2}-\d{2})\}"#), let date = Dates.parse(m[1], calendar: calendar) {
            updates["deadline_date"] = .string(m[1]); take("deadline_date", m[0], "Deadline " + dayLabel(date))
        }
        // A declined or unrecognized deadline stays literal and cannot become a planned date.
        protect(#"\{[^}]*\}"#)
        if enabled("duration_minutes"), let m = match(#"~(\d+)\s*(min(?:ute)?s?|m|hours?|hrs?|h)\b"#), let value = Int(m[1]), value <= 10080 {
            let minutes = value * (m[2].lowercased().hasPrefix("h") ? 60 : 1)
            if (1...10080).contains(minutes) { updates["duration_minutes"] = .number(Double(minutes)); take("duration_minutes", m[0], "\(minutes) min") }
        }
        if enabled("priority"), let m = match(#"\b(?:p|priority\s*)([1-4])\b"#) { updates["priority"] = .number(Double(m[1]) ?? 4); take("priority", m[0], "P" + m[1]) }
        if enabled("due_time"), let m = match(#"\b(?:at\s+)?(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm)\b|\bat\s+(\d{1,2})(?:[:.](\d{2}))?\b|\b(\d{1,2})[:.](\d{2})\b"#) {
            let hourText = [m[1], m[4], m[6]].first { !$0.isEmpty } ?? ""
            let minuteText = [m[2], m[5], m[7]].first { !$0.isEmpty } ?? ""
            if let h = Int(hourText), h < 24, (Int(minuteText) ?? 0) < 60 {
                var hour = h
                let suffix = m[3].lowercased()
                if suffix == "pm" && hour < 12 { hour += 12 }
                if suffix == "am" && hour == 12 { hour = 0 }
                let minute = Int(minuteText) ?? 0
                updates["due_time"] = .string(String(format: "%02d:%02d", hour, minute))
                take("due_time", m[0], timeLabel(hour, minute))
            }
        }
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        if enabled("recurrence"), let m = match(#"\bevery\s+(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b"#), let day = weekdays.firstIndex(of: m[1].lowercased()) {
            let delta = (day - (calendar.component(.weekday, from: now) - 1) + 7) % 7
            updates["due_date"] = .string(Dates.day(calendar.date(byAdding: .day, value: delta == 0 ? 7 : delta, to: now)!))
            updates["is_recurring"] = .bool(true)
            updates["recurrence_pattern"] = .object(["type": .string("weekly"), "interval": .number(1), "daysOfWeek": .array([.number(Double(day))])])
            take("recurrence", m[0], "Every " + m[1].capitalized)
        } else if enabled("recurrence"), let m = match(#"\b(?:every\s+(?:(\d+)\s+)?(day|week|month)s?|daily|weekly|monthly)\b"#) {
            let kind = m[2].isEmpty ? m[0].lowercased() : ["day": "daily", "week": "weekly", "month": "monthly"][m[2].lowercased()] ?? "daily"
            updates["is_recurring"] = .bool(true); updates["recurrence_pattern"] = .object(["type": .string(kind), "interval": .number(max(1, Double(m[1]) ?? 1))]); updates["due_date"] = .string(Dates.day(now))
            take("recurrence", m[0], m[0].capitalized)
        }
        if enabled("due_date") {
            if let m = match(#"\b(today|tomorrow|yesterday)\b"#) {
                let delta = ["today": 0, "tomorrow": 1, "yesterday": -1][m[1].lowercased()] ?? 0
                let date = calendar.date(byAdding: .day, value: delta, to: now)!
                updates["due_date"] = .string(Dates.day(date)); take("due_date", m[0], dayLabel(date))
            } else if let m = match(#"\bin\s+(\d+)\s+(day|week|month|hour|minute)s?\b"#), let count = Int(m[1]), count < 10000 {
                let component: Calendar.Component = ["day": .day, "week": .weekOfYear, "month": .month, "hour": .hour, "minute": .minute][m[2].lowercased()] ?? .day
                if let date = calendar.date(byAdding: component, value: count, to: now) {
                    updates["due_date"] = .string(Dates.day(date))
                    if component == .hour || component == .minute { updates["due_time"] = .string(String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))) }
                    take("due_date", m[0], component == .hour || component == .minute ? dayLabel(date) + " " + date.formatted(date: .omitted, time: .shortened) : dayLabel(date))
                }
            } else if let m = match(#"\b(?:next\s+)?(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b"#), let day = weekdays.firstIndex(of: m[1].lowercased()) {
                let delta = (day - (calendar.component(.weekday, from: now) - 1) + 7) % 7
                let date = calendar.date(byAdding: .day, value: delta == 0 ? 7 : delta, to: now)!
                updates["due_date"] = .string(Dates.day(date)); take("due_date", m[0], dayLabel(date))
            } else if let m = match(#"\b\d{4}-\d{2}-\d{2}\b"#), let date = Dates.parse(m[0]) { updates["due_date"] = .string(Dates.day(date)); take("due_date", m[0], dayLabel(date)) }
        }
        if updates["due_time"] != nil && updates["due_date"] == nil { updates["due_date"] = .string(Dates.day(now)) }
        // Drop a dangling "at" left behind when only the time was declined or accepted.
        if updates["due_time"] != nil { title = title.replacingOccurrences(of: #"\s+at\s*$"#, with: "", options: .regularExpression) }
        for (marker, original) in literals { title = title.replacingOccurrences(of: marker, with: original) }
        title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Accepted references are applied together. Moving projects clears incompatible destinations
    /// and assignments, while additional labels preserve the task's existing labels.
    func applying(to task: Record) -> Record {
        var result = task
        if let project = updates["project_id"], project != task["project_id"] {
            result["section_id"] = .null; result["assigned_to"] = .null
            if !result["subtasks"].list.isEmpty { result["subtasks"] = TaskAssignment.clearChildren(result["subtasks"]) }
        }
        result["title"] = .string(title.trimmingCharacters(in: .whitespacesAndNewlines))
        for (key, value) in updates where key != "labels" { result[key] = value }
        if let labels = updates["labels"] {
            let additions = labels.list.map { value in knownLabels.first { $0.name == value.text }.map { JSON.string($0.id) } ?? value }
            result["labels"] = .array(TaskLabels.normalized(task["labels"].list + additions, labels: knownLabels))
        }
        return result
    }
}

#if DEBUG
extension Snapshot {
    static func quickEntryFixture(user: String) -> Snapshot {
        var snapshot = Snapshot()
        snapshot.tables["projects"] = [("qe-work", "Client Work"), ("qe-home", "Home")].map { Record(["id": .string($0.0), "name": .string($0.1), "user_id": .string(user)]) }
        snapshot.tables["sections"] = [("qe-next", "qe-work"), ("qe-home-next", "qe-home")].map { Record(["id": .string($0.0), "name": .string("Next steps"), "project_id": .string($0.1), "user_id": .string(user)]) }
        snapshot.tables["labels"] = [("qe-home-label", "Home"), ("qe-client-label", "Client notes")].map { Record(["id": .string($0.0), "name": .string($0.1), "user_id": .string(user)]) }
        snapshot.tables["project_collaborators"] = [Record(["id": .string("qe-member"), "project_id": .string("qe-work"), "user_id": .string("alex"), "status": .string("accepted"), "display_name": .string("Alex Morgan")])]
        snapshot.tables["project_members:qe-work"] = [Record(["user_id": .string(user), "display_name": .string("Morgan Lee"), "status": .string("accepted")]), Record(["user_id": .string("alex"), "display_name": .string("Alex Morgan"), "status": .string("accepted")])]
        snapshot.tables["tasks"] = []
        return snapshot
    }
}
#endif

enum TaskLabels {
    /// Existing IDs and unknown legacy values survive. Only unambiguous known names become IDs.
    static func normalized(_ values: [JSON], labels: [Record]) -> [JSON] {
        var result: [JSON] = []
        for value in values {
            var resolved = value
            if case .string(let name) = value, !labels.contains(where: { $0.id == name }) {
                let matches = labels.filter { $0.name == name }
                if matches.count == 1 { resolved = .string(matches[0].id) }
            }
            if !result.contains(resolved) { result.append(resolved) }
        }
        return result
    }
}

struct QuickEntryContext {
    var projects: [Record] = []
    var sections: [Record] = []
    var labels: [Record] = []
    /// Members are already permission-filtered by the platform's directory. IDs identify users.
    var members: [String: [Record]] = [:]
    var currentProject = ""
    var currentUser = ""
    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

private struct QuickEntryReferences {
    var title: String
    var updates: [String: JSON] = [:]
    var tokens: [QuickEntry.Token] = []
    var warnings: [String] = []
    var literals: [(String, String)] = []
    private struct Reference {
        var raw: String, symbol: String, qualifier: String, name: String, marker: String
    }
    init(_ input: String, context: QuickEntryContext, disabled: Set<String>) {
        title = input
        // The first two alternatives skip escaped pieces and ordinary quoted literals. URLs,
        // email addresses, arithmetic and file paths are not reference-token boundaries.
        let pattern = #"\\(?:[#/@%+](?:"[^"\n]*"|[^\s]+)|\{[^}]+\}|[^\s]+)|"[^"\n]*"|(?<!\S)([#/@%+])(?:(project|label|section|person):)?(?:"([^"\n]+)"|([\p{L}\p{N}_@.-]+))(?![\p{L}\p{N}_@./-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return }
        let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
        var references: [Reference] = []
        for match in matches.reversed() {
            func value(_ index: Int) -> String { Range(match.range(at: index), in: input).map { String(input[$0]) } ?? "" }
            guard !value(1).isEmpty, let range = Range(match.range, in: title) else { continue }
            let marker = "\u{E002}" + UUID().uuidString + "\u{E003}"
            references.insert(Reference(raw: value(0), symbol: value(1), qualifier: value(2).lowercased(), name: value(3).isEmpty ? value(4) : value(3), marker: marker), at: 0)
            title.replaceSubrange(range, with: marker)
        }
        func named(_ records: [Record], _ name: String) -> [Record] { records.filter { QuickEntryContext.key($0.name) == QuickEntryContext.key(name) } }
        func projects(_ reference: Reference) -> [Record] { named(context.projects.filter { !$0["is_archived"].flag }, reference.name) }
        var replacements: [String: String] = [:]
        func keep(_ reference: Reference, warning: String? = nil) {
            literals.append((reference.marker, reference.raw))
            if let warning, !warnings.contains(warning) { warnings.append(warning) }
        }
        func take(_ reference: Reference, group: String, label: String) {
            replacements[reference.marker] = ""
            let token = QuickEntry.Token(group: group, text: reference.raw, label: label)
            if !tokens.contains(where: { $0.id == token.id }) { tokens.append(token) }
        }
        let projectRefs = references.filter { $0.symbol == "#" && ($0.qualifier == "project" || ($0.qualifier.isEmpty && !projects($0).isEmpty)) }
        var effectiveProject = context.currentProject
        var blockedProject = false
        let targetIDs = Set(projectRefs.flatMap { projects($0).map(\.id) })
        for reference in projectRefs {
            let candidates = projects(reference)
            if disabled.contains("project_id") { keep(reference); blockedProject = blockedProject || candidates.contains { $0.id != context.currentProject }; continue }
            let labelCollision = reference.qualifier.isEmpty && !named(context.labels, reference.name).isEmpty
            guard candidates.count == 1, targetIDs.count == 1, !labelCollision else {
                blockedProject = true
                let message = labelCollision ? "“\(reference.name)” is a project and a label. Use #project:\"\(reference.name)\" or @\"\(reference.name)\"." : candidates.isEmpty ? "Project “\(reference.name)” is unavailable. Its text stays in the title." : "Choose one project in the Project menu. Its text stays in the title."
                keep(reference, warning: message); continue
            }
            effectiveProject = candidates[0].id
            updates["project_id"] = .string(effectiveProject)
            take(reference, group: "project_id", label: candidates[0].name)
        }
        let remaining = references.filter { reference in !projectRefs.contains(where: { $0.marker == reference.marker }) }
        let sectionRefs = remaining.filter { $0.symbol == "/" && ($0.qualifier.isEmpty || $0.qualifier == "section") }
        let sectionTargets = Set(sectionRefs.flatMap { named(context.sections.filter { $0.string("project_id") == effectiveProject }, $0.name).map(\.id) })
        for reference in sectionRefs {
            if disabled.contains("section_id") || blockedProject { keep(reference); continue }
            let candidates = named(context.sections.filter { $0.string("project_id") == effectiveProject }, reference.name)
            guard !effectiveProject.isEmpty, candidates.count == 1, sectionTargets.count == 1 else { keep(reference, warning: "Choose a section in the selected project. “\(reference.raw)” stays in the title."); continue }
            updates["section_id"] = .string(candidates[0].id)
            take(reference, group: "section_id", label: candidates[0].name)
        }
        let personRefs = remaining.filter { $0.symbol == "+" && ($0.qualifier.isEmpty || $0.qualifier == "person") }
        func people(_ reference: Reference) -> [Record] {
            let members = (context.members[effectiveProject] ?? []).filter { !["pending", "declined", "revoked"].contains($0.string("status")) }
            let exact = members.filter { member in
                let key = QuickEntryContext.key(reference.name)
                return (key == "me" && member.id == context.currentUser) || [member.string("display_name"), member.string("email"), member.string("invited_email")].contains { !$0.isEmpty && QuickEntryContext.key($0) == key }
            }
            if !exact.isEmpty { return exact }
            return members.filter { QuickEntryContext.key($0.string("display_name").split(separator: " ").first.map(String.init) ?? "") == QuickEntryContext.key(reference.name) }
        }
        let personTargets = Set(personRefs.flatMap { people($0).map(\.id) })
        for reference in personRefs {
            if disabled.contains("assigned_to") || blockedProject { keep(reference); continue }
            let candidates = people(reference)
            guard !effectiveProject.isEmpty, candidates.count == 1, personTargets.count == 1 else { keep(reference, warning: "Choose one current project member in Assign to. “\(reference.raw)” stays in the title."); continue }
            updates["assigned_to"] = .string(candidates[0].id)
            take(reference, group: "assigned_to", label: candidates[0].string("display_name"))
        }
        for reference in remaining where !sectionRefs.contains(where: { $0.marker == reference.marker }) && !personRefs.contains(where: { $0.marker == reference.marker }) {
            guard reference.symbol == "@" || reference.symbol == "%" || (reference.symbol == "#" && (reference.qualifier.isEmpty || reference.qualifier == "label")) else { keep(reference); continue }
            if disabled.contains("labels") { keep(reference); continue }
            let candidates = named(context.labels, reference.name)
            guard candidates.count <= 1, !(candidates.isEmpty && context.labels.contains(where: { $0.id == reference.name })) else { keep(reference, warning: "Choose the label in Labels. “\(reference.raw)” stays in the title."); continue }
            let name = candidates.first?.name ?? reference.name
            var labels = updates["labels"]?.list ?? []
            if !labels.contains(.string(name)) { labels.append(.string(name)) }
            updates["labels"] = .array(labels)
            take(reference, group: "labels", label: name)
        }
        for (marker, replacement) in replacements { title = title.replacingOccurrences(of: marker, with: replacement) }
    }
}


struct EditHistory {
    var undo: [Mutation]
    var redo: [Mutation]
    init(changes: [Mutation], snapshot: Snapshot) {
        redo = []
        var current = snapshot
        var inverse: [Mutation] = []
        for change in changes {
            if let old = current.tables[change.table]?.first(where: { $0.id == change.recordID }) {
                let fields = change.method == "DELETE" ? old.fields : Dictionary(uniqueKeysWithValues: change.fields.keys.map { ($0, old.fields[$0] ?? .null) })
                inverse.append(Mutation(table: change.table, recordID: change.recordID, method: change.method == "DELETE" ? "POST" : "PATCH", fields: fields, baseline: change.method == "DELETE" ? nil : change.fields))
                var forward = change
                if change.method == "PATCH" { forward.baseline = Dictionary(uniqueKeysWithValues: change.fields.keys.map { ($0, old[$0]) }) }
                redo.append(forward)
            } else {
                redo.append(change)
                inverse.append(Mutation(table: change.table, recordID: change.recordID, method: "DELETE", fields: [:]))
            }
            current.apply(change)
        }
        undo = inverse.reversed()
    }
}


struct Session: Codable, Sendable {
    var access_token: String
    var refresh_token: String
    var expires_at: Double
    var user: User
    struct User: Codable, Sendable {
        var id: String
        var email: String?
        var user_metadata: [String: JSON]? = nil
        var app_metadata: [String: JSON]? = nil
        var identities: [Identity]? = nil
        struct Identity: Codable, Sendable {
            var provider: String
            var identity_data: [String: JSON]?
        }
        /// Provider metadata is display data only, never authorization data.
        var googleAvatarURL: URL? {
            let google = identities?.first { $0.provider == "google" }
            let providers = app_metadata?["providers"]?.list.map(\.text) ?? []
            guard google != nil || app_metadata?["provider"]?.text == "google" || providers.contains("google") else { return nil }
            for metadata in [google?.identity_data, user_metadata] {
                for key in ["avatar_url", "picture"] {
                    if let url = ProfileAvatar.url(metadata?[key]?.text ?? "") { return url }
                }
            }
            return nil
        }
    }
    enum CodingKeys: String, CodingKey { case access_token, refresh_token, expires_at, expires_in, user }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        access_token = try values.decode(String.self, forKey: .access_token)
        refresh_token = try values.decode(String.self, forKey: .refresh_token)
        user = try values.decode(User.self, forKey: .user)
        guard !access_token.isEmpty, !refresh_token.isEmpty, !user.id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .access_token, in: values, debugDescription: "Incomplete sign-in session")
        }
        expires_at = try values.decodeIfPresent(Double.self, forKey: .expires_at)
            ?? Date().timeIntervalSince1970 + (values.decodeIfPresent(Double.self, forKey: .expires_in) ?? 3600)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(access_token, forKey: .access_token)
        try values.encode(refresh_token, forKey: .refresh_token)
        try values.encode(expires_at, forKey: .expires_at)
        try values.encode(user, forKey: .user)
    }
}

enum OAuthCallback {
    struct InvalidCallback: LocalizedError {
        var errorDescription: String? { "Sign-in did not return to Taskfold. Please try again." }
    }
    static func code(from url: URL) throws -> String {
        guard url.scheme == "taskfold", url.host == "auth", url.path == "/callback",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !parts.queryItems.orEmpty.contains(where: { $0.name == "error" }),
              let code = parts.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw InvalidCallback() }
        return code
    }
}
private extension Optional where Wrapped == [URLQueryItem] { var orEmpty: [URLQueryItem] { self ?? [] } }

struct DueReminder: Equatable, Sendable {
    var id: String
    var title: String
    var body: String
    var date: Date
    static func plan(tasks: [Record], now: Date = Date(), calendar: Calendar = .current, limit: Int = 60) -> [DueReminder] {
        tasks.compactMap { task -> DueReminder? in
            guard !task.completed, let day = Dates.parse(task.string("due_date"), calendar: calendar) else { return nil }
            let text = task.string("due_time")
            let pieces = text.split(separator: ":")
            var hour = 8, minute = 0
            if !text.isEmpty {
                guard pieces.count >= 2, let h = Int(pieces[0]), let m = Int(pieces[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
                hour = h; minute = m
            }
            guard let date = text.isEmpty ? calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) : TaskPlanning.start(task, calendar: calendar), date > now else { return nil }
            return DueReminder(id: task.id, title: task.title, body: task.string("description"), date: date)
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }.prefix(max(0, limit)).map { $0 }
    }
}

enum TaskScope: Hashable {
    case today, inbox, upcoming, all, completed, project(String), label(String), saved(String)
    var title: String {
        switch self { case .today: return "Today"; case .inbox: return "Inbox"; case .upcoming: return "Upcoming"; case .all: return "All tasks"; case .completed: return "Completed"; case .project: return "Project"; case .label: return "Label"; case .saved: return "Saved filter" }
    }
}

struct TaskQuery: Hashable {
    var scope: TaskScope
    var text = ""
    var includeCompleted = false
    var priority = 0
    var sort = "priority"
    var today = Dates.day(Date())
    var selectedDay: String?
    var labelName = ""
    var filter: FilterRule?
    var filterLabels: [FilterReference] = []
    var userID = ""
    var timeZone = TimeZone.current.identifier
}

/// Shared by tabs. Results survive navigation and invalidate only when task data changes.
final class TaskCache {
    private var source: [Record] = []
    private var results: [TaskQuery: [Record]] = [:]
    private(set) var tasks: [Record] = []
    private(set) var computationCount = 0
    @discardableResult func update(_ rows: [Record]) -> Bool {
        guard source != rows else { return false }
        source = rows
        tasks = rows.sorted { $0.priority == $1.priority ? $0.string("created_at") > $1.string("created_at") : $0.priority < $1.priority }
        results.removeAll(keepingCapacity: true)
        return true
    }
    func matching(_ query: TaskQuery) -> [Record] {
        if let cached = results[query] { return cached }
        computationCount += 1
        let matched = tasks.filter { task in
            if query.scope == .completed { if !task.completed { return false } }
            else if !query.includeCompleted && task.completed { return false }
            if query.priority > 0 && task.priority != query.priority { return false }
            if !query.text.isEmpty && !(task.title + " " + task.string("description")).localizedCaseInsensitiveContains(query.text) { return false }
            if let filter = query.filter, !filter.matches(task, today: query.today, userID: query.userID, labels: query.filterLabels, timeZone: query.timeZone) { return false }
            let day = FilterRule.plannedDay(task, timeZone: query.timeZone)
            switch query.scope {
            case .inbox: return task.string("project_id").isEmpty
            case .today: return !day.isEmpty && day <= query.today
            case .upcoming: return query.selectedDay.map { day == $0 } ?? !day.isEmpty
            case .project(let id): return task.string("project_id") == id
            case .label(let id): return task["labels"].list.contains(.string(id)) || task["labels"].list.contains(.string(query.labelName))
            default: return true
            }
        }
        let sorted: [Record]
        if query.sort == "title" { sorted = matched.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
        else if query.sort == "date" { sorted = matched.sorted { ($0.string("due_date").isEmpty ? "9999" : $0.string("due_date")) < ($1.string("due_date").isEmpty ? "9999" : $1.string("due_date")) } }
        else if query.sort == "deadline" { sorted = matched.sorted { ($0.string("deadline_date").isEmpty ? "9999" : $0.string("deadline_date")) < ($1.string("deadline_date").isEmpty ? "9999" : $1.string("deadline_date")) } }
        else if query.sort == "duration" { sorted = matched.sorted { ($0.durationMinutes ?? Int.max) < ($1.durationMinutes ?? Int.max) } }
        else { sorted = matched }
        if results.count >= 64 { results.removeAll(keepingCapacity: true) }
        results[query] = sorted
        return sorted
    }
}


/// Day placement and due-date mutations share the durable, account-owned sync queue.
enum DayPlacement {
    static let table = "view_orders"
    static func ordered(_ tasks: [Record], ids: [String]) -> [Record] {
        let ranks = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return tasks.enumerated().sorted {
            let a = ranks[$0.element.id] ?? (ids.count + $0.offset)
            let b = ranks[$1.element.id] ?? (ids.count + $1.offset)
            return a < b
        }.map(\.element)
    }
    /// The app's default order: priority bands (P1 first), and inside each band the user's manual order.
    static func arranged(_ tasks: [Record], ids: [String]) -> [Record] {
        ordered(tasks, ids: ids).enumerated().sorted { a, b in
            a.element.priority == b.element.priority ? a.offset < b.offset : a.element.priority < b.element.priority
        }.map(\.element)
    }
    /// Keeps a drop inside the dragged task's priority band. A slot among other priorities snaps to the
    /// end of the task's own band (which is also where a newly re-prioritised task lands).
    static func constrained(before: String?, priority: Int, in tasks: [Record]) -> String? {
        if let before, let target = tasks.first(where: { $0.id == before }) {
            if target.priority == priority { return before }
            // Aimed above the band: top of the band. Aimed below it: fall through to the band's end.
            if target.priority < priority { return tasks.first { $0.priority >= priority }?.id }
        }
        return tasks.first { $0.priority > priority }?.id
    }
    static func changes(task: Record, day: String, orderedIDs: [String], before: String?, calendar: Calendar = .current) -> [Mutation] {
        guard !task.completed, Dates.parse(day, calendar: calendar) != nil else { return [] }
        var ids = orderedIDs.filter { $0 != task.id }
        let index = before.flatMap { ids.firstIndex(of: $0) } ?? ids.count
        ids.insert(task.id, at: index)
        var changes: [Mutation] = []
        let fields = TaskPlanner.dayFields(task: task, day: day, calendar: calendar)
        if !fields.isEmpty { changes.append(Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: fields)) }
        changes.append(Mutation(table: table, recordID: day, method: "PATCH", fields: ["id": .string(day), "ids": .array(ids.map(JSON.string))]))
        return changes
    }
}

extension TaskScope {
    var preferenceKey: String {
        switch self {
        case .today: return "today"
        case .inbox: return "inbox"
        case .upcoming: return "upcoming"
        case .all: return "all"
        case .completed: return "completed"
        case .project(let id): return "project:" + id
        case .label(let id): return "label:" + id
        case .saved(let id): return "view:" + id
        }
    }
    init?(preferenceKey: String) {
        switch preferenceKey {
        case "today": self = .today
        case "inbox": self = .inbox
        case "upcoming": self = .upcoming
        case "all": self = .all
        case "completed": self = .completed
        default:
            if preferenceKey.hasPrefix("project:"), preferenceKey.count > 8 { self = .project(String(preferenceKey.dropFirst(8))) }
            else if preferenceKey.hasPrefix("label:"), preferenceKey.count > 6 { self = .label(String(preferenceKey.dropFirst(6))) }
            else if preferenceKey.hasPrefix("view:"), preferenceKey.count > 5 { self = .saved(String(preferenceKey.dropFirst(5))) }
            else { return nil }
        }
    }
}


/// An uploaded profile photo always takes precedence over the provider default.
enum ProfileAvatar {
    static func url(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }
    static func resolved(uploaded: String, google: URL?) -> URL? { url(uploaded) ?? google }
}


/// Only accepted memberships identify people who can receive project tasks.
enum TaskAssignment {
    static func members(project: Record, collaborators: [Record], currentUser: String, profile: Record) -> [Record] {
        let owner = project.string("user_id")
        var people: [String: Record] = [:]
        if !owner.isEmpty { people[owner] = Record(["id": .string(owner), "display_name": .string("Project owner")]) }
        for person in collaborators where person.string("status") == "accepted" && !person.string("user_id").isEmpty {
            let id = person.string("user_id")
            var member = person; member["id"] = .string(id)
            if member.string("display_name").isEmpty {
                member["display_name"] = .string(person.string("invited_email").isEmpty ? "Project collaborator" : person.string("invited_email"))
            }
            people[id] = member
        }
        if people[currentUser] != nil {
            if !profile.string("display_name").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                people[currentUser]?["display_name"] = profile["display_name"]
            } else if people[currentUser]?.string("display_name") == "Project owner" {
                people[currentUser]?["display_name"] = .string("You")
            }
            if !profile.string("avatar_url").isEmpty { people[currentUser]?["avatar_url"] = profile["avatar_url"] }
        }
        return people.values.sorted { $0.string("display_name").localizedStandardCompare($1.string("display_name")) == .orderedAscending }
    }
    static func clearChildren(_ value: JSON) -> JSON {
        .array(value.list.map { child in
            var fields = child.object
            fields["assigned_to"] = .null
            if fields["subtasks"] != nil { fields["subtasks"] = clearChildren(fields["subtasks"]!) }
            return .object(fields)
        })
    }
    /// The server clears assignments on a project move. Send an explicit new
    /// assignment after the move so both writes obey the existing membership guard.
    static func mutations(_ change: Mutation, existing: Record?) -> [Mutation] {
        guard change.table == "tasks", change.method == "PATCH", let existing,
              let project = change.fields["project_id"], project != existing["project_id"] else { return [change] }
        var move = change
        move.fields["assigned_to"] = .null
        move.fields["subtasks"] = clearChildren(change.fields["subtasks"] ?? existing["subtasks"])
        if move.baseline != nil {
            for field in ["assigned_to", "subtasks"] where move.baseline?[field] == nil { move.baseline?[field] = existing[field] }
        }
        if let person = change.fields["assigned_to"], !person.text.isEmpty, !project.text.isEmpty {
            return [move, Mutation(table: "tasks", recordID: change.recordID, method: "PATCH", fields: ["assigned_to": person], baseline: ["assigned_to": .null])]
        }
        return [move]
    }
}


/// A date-only plan floats with the user's calendar. Timed plans with a zone retain
/// a canonical instant, so travelling or crossing a DST fold does not shift reminders.
enum TaskPlanning {
    static let keys: Set<String> = ["due_date", "due_time", "time_zone"]
    static func instant(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func start(_ task: Record, calendar: Calendar = .current) -> Date? {
        var sourceCalendar = calendar
        let zone = task.string("time_zone")
        if !zone.isEmpty {
            guard let timeZone = TimeZone(identifier: zone) else { return nil }
            sourceCalendar.timeZone = timeZone
        }
        guard let day = Dates.parse(task.string("due_date"), calendar: sourceCalendar) else { return nil }
        let pieces = task.string("due_time").split(separator: ":").compactMap { Int($0) }
        guard pieces.count >= 2, (0...23).contains(pieces[0]), (0...59).contains(pieces[1]) else { return nil }
        if !zone.isEmpty, let saved = instant(task.string("scheduled_at")) {
            let a = sourceCalendar.dateComponents([.year, .month, .day], from: saved)
            let b = sourceCalendar.dateComponents([.year, .month, .day], from: day)
            let time = sourceCalendar.dateComponents([.hour, .minute], from: saved)
            if a == b && time.hour == pieces[0] && time.minute == pieces[1] { return saved }
        }
        return sourceCalendar.date(bySettingHour: pieces[0], minute: pieces[1], second: 0, of: day)
    }
    static func fields(_ fields: [String: JSON], existing: Record?, calendar: Calendar = .current) -> [String: JSON] {
        guard !keys.isDisjoint(with: fields.keys) else { return fields }
        var result = fields
        var task = existing ?? Record()
        for (key, value) in fields { task[key] = value }
        let changed = keys.contains { fields[$0] != nil && fields[$0] != existing?[$0] }
        // An explicit instant from import/restore preserves the chosen DST fold.
        if changed && fields["scheduled_at"] == nil { task["scheduled_at"] = .null }
        if task.string("time_zone").isEmpty || task.string("due_time").isEmpty || task.due == nil { result["scheduled_at"] = .null }
        else { result["scheduled_at"] = start(task, calendar: calendar).map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null }
        return result
    }
    static func nextOccurrence(_ task: Record, date: Date) -> Record {
        var copy = task
        copy["due_date"] = .string(Dates.day(date))
        copy["deadline_date"] = .null // A one-off hard deadline never follows a repeat.
        copy["scheduled_at"] = .null
        copy.fields = fields(copy.fields, existing: nil)
        return copy
    }
}


/// Versioned widget payload. The extension receives planning data, never sessions or mutations.
enum WidgetProjection {
    static func payload(tasks: [Record], projects: [Record], account: String, now: Date = Date()) -> [String: JSON] {
        guard !account.isEmpty else { return ["version": .number(2), "updated": .number(0), "account": .string(""), "tasks": .array([])] }
        let projects = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = tasks.filter { !$0.completed }.map { task -> JSON in
            let project = projects[task.string("project_id")]
            let instant = !task.string("time_zone").isEmpty ? TaskPlanning.start(task).map { ISO8601DateFormatter().string(from: $0) } : nil
            return .object(["id": .string(task.id), "title": .string(task.title), "due": .string(String(task.string("due_date").prefix(10))), "time": .string(String(task.string("due_time").prefix(5))),
                "priority": .number(Double(task.priority)), "project": .string(project?.name ?? ""), "projectID": .string(task.string("project_id")), "color": .string(project?.string("color") ?? ""),
                "deadline": task.deadline.map { _ in .string(String(task.string("deadline_date").prefix(10))) } ?? .null,
                "duration": task.durationMinutes.map { .number(Double($0)) } ?? .null,
                "scheduledAt": instant.map(JSON.string) ?? .null, "timeZone": task.string("time_zone").isEmpty ? .null : .string(task.string("time_zone"))])
        }
        return ["version": .number(2), "updated": .number(now.timeIntervalSinceReferenceDate), "account": .string(account), "tasks": .array(rows)]
    }
}
