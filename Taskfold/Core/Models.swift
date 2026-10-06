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
                "completion_version": .number(0), "priority": .number(4), "project_id": project.isEmpty ? .null : .string(project),
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
    static func next(_ task: Record, calendar input: Calendar = .current) -> Date? {
        let calendar = TaskCompletion.calendar(for: task, input: input)
        guard task["is_recurring"].flag, let current = parse(task.string("due_date"), calendar: calendar) else { return nil }
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
        if let end = parse(endString, calendar: calendar), TaskPlanner.dayKey(next, calendar: calendar) > TaskPlanner.dayKey(end, calendar: calendar) { return nil }
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
    /// Create-only operations never overwrite an already present server row on retry.
    var insertOnly: Bool? = nil
}

/// A local prediction follows the server counter; only the server owns confirmed revisions.
enum TaskCompletionRevision {
    static func touches(_ fields: [String: JSON]) -> Bool { fields["completed"] != nil || fields["completed_at"] != nil }
    static func editBaseline(for fields: [String: JSON], from original: Record) -> [String: JSON] {
        var baseline = Dictionary(uniqueKeysWithValues: fields.keys.map { ($0, original[$0]) })
        if touches(fields) { baseline["completion_version"] = original.fields["completion_version"] ?? .number(0) }
        return baseline
    }
    static func capturing(_ change: Mutation, existing: Record?) -> Mutation {
        var change = change
        if change.table == "tasks", change.method == "PATCH" { change.fields.removeValue(forKey: "completion_version") }
        if change.table == "tasks", change.method == "PATCH", touches(change.fields), let existing {
            if change.baseline == nil { change.baseline = editBaseline(for: change.fields, from: existing) }
            if change.baseline?["completion_version"] == nil { change.baseline?["completion_version"] = existing.fields["completion_version"] ?? .number(0) }
        }
        if change.table == "tasks", change.method == "POST" { change.fields["completion_version"] = .number(0) }
        return change
    }
    static func applying(_ fields: [String: JSON], to old: Record) -> Record {
        var row = old; row.fields.merge(fields) { _, new in new }
        if fields["completion_version"] == nil, touches(fields),
           old.completed != row.completed || instant(old["completed_at"]) != instant(row["completed_at"]) {
            row["completion_version"] = .number(Double(old["completion_version"].integer + 1))
        }
        return row
    }
    private static func instant(_ value: JSON) -> JSON {
        guard case .string(let text) = value else { return value }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text) else { return value }
        return .number(date.timeIntervalSince1970)
    }
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
        guard mutation.table == "tasks", ["PATCH", "DELETE"].contains(mutation.method),
              remote.id.lowercased() == mutation.recordID.lowercased(),
              let index = snapshot.pending.firstIndex(where: { $0 == mutation }) else { return nil }
        var result = snapshot
        if keepLocal, mutation.method == "DELETE" {
            result.pending[index].baseline = remote.fields
        } else if keepLocal {
            result.pending[index].fields = Dictionary(uniqueKeysWithValues: mutation.fields.map { key, value in
                (key, mutation.baseline?[key].map { TaskEdit.keepingLocal(base: $0, desired: value, remote: remote[key]) } ?? value)
            })
            result.pending[index].baseline = Dictionary(uniqueKeysWithValues: mutation.fields.keys.map { ($0, remote[$0]) })
            result.pending[index] = TaskCompletionRevision.capturing(result.pending[index], existing: remote)
            if TaskCompletionRevision.touches(mutation.fields) {
                let before = TaskCompletionRevision.applying(mutation.fields, to: Record(mutation.baseline ?? [:]))["completion_version"].integer
                let after = TaskCompletionRevision.applying(result.pending[index].fields, to: remote)["completion_version"].integer
                let delta = after - before
                for next in result.pending.indices where next > index && result.pending[next].table == "tasks" && result.pending[next].recordID.lowercased() == mutation.recordID.lowercased() && TaskCompletionRevision.touches(result.pending[next].fields) {
                    if case .number(let version)? = result.pending[next].baseline?["completion_version"], version >= Double(before) {
                        result.pending[next].baseline?["completion_version"] = .number(version + Double(delta))
                    }
                }
            }
        } else {
            result.pending.remove(at: index)
            if !remote.completed, mutation.fields["completed"] == .bool(true) {
                cancelUnacceptedSuccessors(in: &result)
            }
        }
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
    private func cancelUnacceptedSuccessors(in result: inout Snapshot) {
        let action = mutation.id.uuidString.lowercased()
        let creations = result.pending.filter {
            $0.table == "tasks" && $0.method == "POST" && $0.insertOnly == true &&
            $0.fields["source_metadata"]?.object["taskfold_recurrence_v1"]?.object["action_id"]?.text == action
        }
        for creation in creations {
            let later = result.pending.filter { $0.table == "tasks" && $0.recordID.lowercased() == creation.recordID.lowercased() && $0.id != creation.id }
            let current = result.tables["tasks"]?.first { $0.id.lowercased() == creation.recordID.lowercased() }
            if later.isEmpty && (current == nil || current == Record(creation.fields)) {
                result.pending.removeAll { $0.id == creation.id }
                result.tables["tasks"]?.removeAll { $0.id.lowercased() == creation.recordID.lowercased() }
            } else {
                // Later user work becomes its own series rather than an occurrence of
                // the completion that was declined. Keep every later queued mutation.
                func independent(_ fields: [String: JSON]) -> [String: JSON] {
                    var fields = fields
                    if fields["recurrence_parent_id"] == creation.fields["recurrence_parent_id"] { fields["recurrence_parent_id"] = .null }
                    var metadata = fields["source_metadata"]?.object ?? [:]
                    if metadata["taskfold_recurrence_v1"]?.object["action_id"]?.text == action { metadata.removeValue(forKey: "taskfold_recurrence_v1") }
                    fields["source_metadata"] = .object(metadata); return fields
                }
                if let index = result.pending.firstIndex(where: { $0.id == creation.id }) { result.pending[index].fields = independent(creation.fields) }
                for index in result.pending.indices where result.pending[index].table == "tasks" && result.pending[index].recordID.lowercased() == creation.recordID.lowercased() && result.pending[index].id != creation.id {
                    // Rebase only the structural fields changed by detaching. Preserve
                    // the user's actual fields, identity and completion baselines.
                    if var base = result.pending[index].baseline {
                        let detached = independent(base)
                        for key in ["recurrence_parent_id", "source_metadata"] where base[key] != nil { base[key] = detached[key] }
                        result.pending[index].baseline = base
                    }
                    let detached = independent(result.pending[index].fields)
                    for key in ["recurrence_parent_id", "source_metadata"] where result.pending[index].fields[key] != nil { result.pending[index].fields[key] = detached[key] }
                }
                if let index = result.tables["tasks"]?.firstIndex(where: { $0.id.lowercased() == creation.recordID.lowercased() }), let fields = current?.fields {
                    result.tables["tasks"]?[index].fields = independent(fields)
                }
            }
        }
    }
}

struct Snapshot: Codable, Equatable, Sendable {
    var tables: [String: [Record]] = [:]
    var pending: [Mutation] = []
    var widgetCompletion = WidgetCompletionCache()
    mutating func apply(_ change: Mutation) {
        var rows = tables[change.table] ?? []
        if change.method == "DELETE" { rows.removeAll { $0.id == change.recordID } }
        else if let i = rows.firstIndex(where: { $0.id == change.recordID }) {
            if change.method == "POST", change.insertOnly == true { return }
            rows[i] = change.table == "tasks" ? TaskCompletionRevision.applying(change.fields, to: rows[i]) : Record(rows[i].fields.merging(change.fields) { _, new in new })
        } else {
            var fields = change.fields
            if change.table == "tasks", change.method == "POST" { fields["completion_version"] = .number(0) }
            rows.append(Record(fields))
        }
        tables[change.table] = rows
    }
    /// Confirm the server revision before replaying work queued during the request.
    mutating func acknowledge(_ change: Mutation, saved: Record?) {
        pending.removeAll { $0.id == change.id }
        guard let saved else { return }
        var rows = tables[change.table] ?? []
        if let index = rows.firstIndex(where: { $0.id.lowercased() == change.recordID.lowercased() }) {
            var confirmed = saved; confirmed["id"] = .string(rows[index].id); rows[index] = confirmed
        } else { rows.append(saved) }
        tables[change.table] = rows
        for queued in pending where queued.table == change.table && queued.recordID.lowercased() == change.recordID.lowercased() {
            var queued = queued
            if let id = rows.first(where: { $0.id.lowercased() == change.recordID.lowercased() })?.id { queued.recordID = id }
            apply(queued)
        }
    }
    mutating func mergeRemote(_ remote: [String: [Record]]) {
        tables.merge(remote) { _, new in new }
        for change in pending { apply(change) }
    }
}

extension Snapshot {
    private enum CodingKeys: String, CodingKey { case tables, pending, widgetCompletion }
    init(from decoder: Decoder) throws {
        let row = try decoder.container(keyedBy: CodingKeys.self)
        tables = try row.decode([String: [Record]].self, forKey: .tables)
        pending = try row.decode([Mutation].self, forKey: .pending)
        widgetCompletion = try row.decodeIfPresent(WidgetCompletionCache.self, forKey: .widgetCompletion) ?? WidgetCompletionCache()
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
    static let groups = ["priority", "labels", "due_time", "recurrence", "due_date", "deadline_date", "duration_minutes", "project_id", "section_id", "assigned_to", "reminder_specs"]
    var title: String
    var updates: [String: JSON] = [:]
    var tokens: [Token] = []
    var warnings: [String] = []
    private var knownLabels: [Record] = []
    private var acceptedReminders: [(ReminderSpec, String)] = []
    var hasSuggestions: Bool { !updates.isEmpty }
    /// Parses `input`. Groups in `disabled` are left untouched in the title and produce no updates,
    /// so a user can decline a single suggestion (for example keep "tomorrow" as part of the name).
    init(_ input: String, now: Date = Date(), calendar: Calendar = .current, disabled: Set<String> = [], context: QuickEntryContext = QuickEntryContext(), task: Record = Record()) {
        let references = QuickEntryReferences(input, context: context, disabled: disabled)
        title = references.title; updates = references.updates; tokens = references.tokens; warnings = references.warnings; knownLabels = context.labels
        var literals = references.literals
        func protect(_ pattern: String, removeEscape: Bool = false) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return }
            while let found = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)), let range = Range(found.range, in: title) {
                let original = String(title[range])
                let marker = "\u{E000}" + UUID().uuidString + "\u{E001}"
                literals.append((marker, removeEscape ? String(original.dropFirst()) : original))
                title.replaceSubrange(range, with: marker)
            }
        }
        protect(QuickReminderText.pattern.replacingOccurrences(of: #"(?<!\S)!"#, with: #"(?<!\S)\\!"#), removeEscape: true)
        protect(#"\\(?:[#/@%+](?:"[^"\n]*"|[^\s]+)|\{[^}]+\}|[^\s]+)"#, removeEscape: true)
        protect(#""[^"\n]*""#)
        protect(#"(?<!\S)(?:https?://|www\.)\S+"#)
        protect(#"(?<!\S)[^\s!]+![^\s!]+"#)
        var reminderRows = ReminderSpec.rows(task)
        let reminderSeed = reminderRows.map { $0.object["id"]?.text ?? "" }.joined(separator: "|")
        if let regex = try? NSRegularExpression(pattern: QuickReminderText.pattern, options: .caseInsensitive) {
            let input = title
            let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
            var seen = Set<String>()
            var occurrences: [String: Int] = [:]
            var replacements: [(NSRange, String)] = []
            for match in matches {
                guard let range = Range(match.range, in: input) else { continue }
                let raw = String(input[range]).trimmingCharacters(in: .whitespaces), key = raw.lowercased()
                let ordinal = occurrences[key, default: 0]; occurrences[key] = ordinal + 1
                let group = "reminder_specs:" + String(DueReminder.digest(key).prefix(12)) + ":\(ordinal)"
                let marker = "\u{E004}" + UUID().uuidString + "\u{E005}"
                var accepted = false
                if !disabled.contains("reminder_specs") && !disabled.contains(group) {
                    let id = QuickReminderText.stableID(reminderSeed + "|" + key + "|\(ordinal)")
                    if let spec = QuickReminderText.spec(raw, id: id, now: now, calendar: calendar) {
                        let semantic = spec.kind + "|" + (spec.kind == "relative" ? String(spec.offset ?? 0) : spec.raw["at"]?.text ?? "")
                        if seen.insert(semantic).inserted && QuickReminderText.merge(spec, into: &reminderRows) {
                            acceptedReminders.append((spec, raw))
                            tokens.append(Token(group: group, text: raw, label: spec.kind == "relative" ? spec.label : "Remind " + spec.label))
                            accepted = true
                        } else { warnings.append("“\(raw)” duplicates a reminder or exceeds the 20-setting limit. Its text stays in the title.") }
                    } else {
                        warnings.append(raw.lowercased().hasPrefix("!every") ? "Independently recurring reminders are not available yet. “\(raw)” stays in the title." : "“\(raw)” is not a future reminder. Try !30m, !30mb or !tomorrow 9am. Its text stays in the title.")
                    }
                }
                replacements.append((match.range, accepted ? "" : marker))
                if !accepted { literals.append((marker, raw)) }
            }
            for (range, replacement) in replacements.reversed() {
                if let range = Range(range, in: title) { title.replaceSubrange(range, with: replacement) }
            }
            if !acceptedReminders.isEmpty { updates["reminder_specs"] = .array(reminderRows) }
        }
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
        if acceptedReminders.contains(where: { $0.0.kind == "relative" }) && (updates["due_date"]?.text ?? task.string("due_date")).isEmpty {
            warnings.append("Relative reminders wait for a planned date. Date-only tasks use 8 AM.")
        }
        for (marker, original) in literals.reversed() { title = title.replacingOccurrences(of: marker, with: original) }
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
        for (key, value) in updates where key != "labels" && key != "reminder_specs" { result[key] = value }
        if !acceptedReminders.isEmpty {
            var rows = ReminderSpec.rows(task)
            for (spec, raw) in acceptedReminders where !QuickReminderText.merge(spec, into: &rows) {
                result["title"] = .string(result.title + " " + raw)
            }
            result["reminder_specs"] = .array(rows)
        }
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
                inverse.append(Mutation(table: change.table, recordID: change.recordID, method: change.method == "DELETE" ? "POST" : "PATCH", fields: fields, baseline: change.method == "DELETE" ? nil : change.fields, insertOnly: change.method == "DELETE" && change.table == "tasks" ? true : nil))
                var forward = change
                if change.method == "PATCH" { forward.baseline = Dictionary(uniqueKeysWithValues: change.fields.keys.map { ($0, old[$0]) }) }
                redo.append(forward)
            } else {
                redo.append(change)
                inverse.append(Mutation(table: change.table, recordID: change.recordID, method: "DELETE", fields: [:], baseline: change.table == "tasks" ? change.fields : nil))
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
    static func nextOccurrence(_ task: Record, date: Date, calendar: Calendar = .current) -> Record {
        var copy = task
        copy["due_date"] = .string(TaskPlanner.dayKey(date, calendar: calendar))
        copy["deadline_date"] = .null // A one-off hard deadline never follows a repeat.
        copy["scheduled_at"] = .null
        copy["reminder_specs"] = .array(ReminderSpec.successorRows(ReminderSpec.rows(task)))
        copy.fields = fields(copy.fields, existing: nil, calendar: calendar)
        return copy
    }
}


/// One completion contract for native actions and widgets. An occurrence has one stable successor ID.
enum TaskCompletion {
    static func calendar(for task: Record, input: Calendar = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = input.timeZone
        if !task.string("due_time").isEmpty, let zone = TimeZone(identifier: task.string("time_zone")) { calendar.timeZone = zone }
        return calendar
    }
    static func successorID(parent: String, day: String) -> String {
        let hex = Array(DueReminder.digest("com.taskfold.recurrence.v1|" + parent.lowercased() + "|" + day).prefix(32))
        return String(hex[0..<8]) + "-" + String(hex[8..<12]) + "-5" + String(hex[13..<16]) + "-a" + String(hex[17..<20]) + "-" + String(hex[20..<32])
    }
    static func complete(_ task: Record, tasks: [Record], at now: Date = Date(), calendar input: Calendar = .current) -> [Mutation] {
        guard !task.completed, !task.id.isEmpty else { return [] }
        return toggle(task, tasks: tasks, at: now, calendar: input)
    }
    static func toggle(_ task: Record, tasks: [Record], at now: Date = Date(), calendar input: Calendar = .current) -> [Mutation] {
        guard !task.id.isEmpty else { return [] }
        let stamp = ISO8601DateFormatter().string(from: now)
        let fields: [String: JSON] = ["completed": .bool(!task.completed), "completed_at": task.completed ? .null : .string(stamp)]
        var changes = [Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: fields,
            baseline: ["completed": task["completed"], "completed_at": task["completed_at"], "completion_version": task.fields["completion_version"] ?? .number(0)])]
        let calendar = calendar(for: task, input: input)
        let parent = task.string("recurrence_parent_id").isEmpty ? task.id : task.string("recurrence_parent_id")
        guard !task.completed, let next = Dates.next(task, calendar: calendar) else { return changes }
        let day = TaskPlanner.dayKey(next, calendar: calendar), nextID = successorID(parent: parent, day: TaskPlanner.dayKey(next, calendar: calendar))
        guard !tasks.contains(where: { $0.id.lowercased() == nextID || ($0.string("recurrence_parent_id").lowercased() == parent.lowercased() && String($0.string("due_date").prefix(10)) == day) }) else { return changes }
        var copy = TaskPlanning.nextOccurrence(task, date: next, calendar: calendar)
        copy["id"] = .string(nextID); copy["completed"] = .bool(false); copy["completed_at"] = .null; copy["completion_version"] = .number(0)
        copy["notification_sent_at"] = .null; copy["created_at"] = .string(stamp); copy.fields.removeValue(forKey: "updated_at")
        copy["comments"] = .array([]); copy["recurrence_parent_id"] = .string(parent)
        // One occurrence identity, but separate actions: undo must not delete another device's copy.
        var metadata = copy["source_metadata"].object
        if case .object = copy["source_metadata"] {} else if copy["source_metadata"] != .null {
            metadata["taskfold_previous_source_metadata"] = copy["source_metadata"]
        }
        metadata["taskfold_recurrence_v1"] = .object(["action_id": .string(changes[0].id.uuidString.lowercased())])
        copy["source_metadata"] = .object(metadata)
        var pattern = copy["recurrence_pattern"].object
        if let count = pattern["count"]?.integer, count > 1 { pattern["count"] = .number(Double(count - 1)) }
        copy["recurrence_pattern"] = .object(pattern)
        let old = Dates.parse(task.string("due_date"), calendar: calendar)
        let delta = old.flatMap { calendar.dateComponents([.day], from: $0, to: next).day } ?? 0
        copy["subtasks"] = .array(successorChildren(task["subtasks"].list, root: nextID, path: "", delta: delta, calendar: calendar))
        changes.append(Mutation(table: "tasks", recordID: nextID, method: "POST", fields: copy.fields, insertOnly: true))
        return changes
    }
    private static func successorChildren(_ values: [JSON], root: String, path: String, delta: Int, calendar input: Calendar, depth: Int = 0) -> [JSON] {
        guard depth < 24 else { return values }
        return values.enumerated().map { index, value in
            guard case .object(let fields) = value else { return value }
            var child = Record(fields)
            let path = path + "/" + String(index) + ":" + child.id
            child["id"] = .string(successorID(parent: root + path, day: "child"))
            child["completed"] = .bool(false); child["completed_at"] = .null; child["comments"] = .array([])
            child["deadline_date"] = .null; child["notification_sent_at"] = .null
            child["reminder_specs"] = .array(ReminderSpec.successorRows(ReminderSpec.rows(child)))
            let calendar = calendar(for: child, input: input)
            if let old = Dates.parse(child.string("due_date"), calendar: calendar), let next = calendar.date(byAdding: .day, value: delta, to: old) {
                child["due_date"] = .string(TaskPlanner.dayKey(next, calendar: calendar)); child["scheduled_at"] = .null
                child.fields = TaskPlanning.fields(child.fields, existing: nil, calendar: calendar)
            }
            if case .array(let nested) = child["subtasks"] { child["subtasks"] = .array(successorChildren(nested, root: root, path: path, delta: delta, calendar: calendar, depth: depth + 1)) }
            return .object(child.fields)
        }
    }
}

/// Versioned widget payload. The extension receives planning data, never sessions or mutations.
enum WidgetProjection {
    static func payload(tasks: [Record], projects: [Record], account: String, now: Date = Date(), labels: [Record] = [], sections: [Record] = [], savedViews: [Record] = [], calendar: Calendar = .current, completionTokens: [String: String] = [:], pendingSync: Int = 0, workingHours: WorkingHours = WorkingHours(), calendarWindow: CalendarCapacityWindow? = nil, calendarFallback: String = "off", notePins: [Record] = []) -> [String: JSON] {
        guard !account.isEmpty else { return ["version": .number(2), "updated": .number(0), "account": .string(""), "tasks": .array([])] }
        let lists = listPayload(tasks: tasks, projects: projects, labels: labels, sections: sections, savedViews: savedViews, account: account, now: now, calendar: calendar)
        let projects = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = tasks.filter { !$0.completed }.map { task -> JSON in
            let project = projects[task.string("project_id")]
            let instant = !task.string("time_zone").isEmpty ? TaskPlanning.start(task).map { ISO8601DateFormatter().string(from: $0) } : nil
            return .object(["id": .string(task.id), "title": .string(task.title), "due": .string(String(task.string("due_date").prefix(10))), "time": .string(String(task.string("due_time").prefix(5))),
                "completionToken": completionTokens[task.id.lowercased()].map(JSON.string) ?? .null,
                "priority": .number(Double(task.priority)), "project": .string(project?.name ?? ""), "projectID": .string(task.string("project_id")), "color": .string(project?.string("color") ?? ""),
                "deadline": task.deadline.map { _ in .string(String(task.string("deadline_date").prefix(10))) } ?? .null,
                "duration": task.durationMinutes.map { .number(Double($0)) } ?? .null,
                "scheduledAt": instant.map(JSON.string) ?? .null, "timeZone": task.string("time_zone").isEmpty ? .null : .string(task.string("time_zone"))])
        }
        return ["version": .number(2), "updated": .number(now.timeIntervalSinceReferenceDate), "account": .string(account), "tasks": .array(rows), "notes": .array(PinnedNotes.payload(tasks: tasks, pins: notePins, account: account)), "lists": .array(lists), "pendingSync": .number(Double(max(0, pendingSync))), "capacity": capacityPayload(tasks: tasks, account: account, hours: workingHours, window: calendarWindow, fallback: calendarFallback, now: now, calendar: calendar)]
    }

    /// Materialize the planner's exact day semantics in a bounded, title-free projection.
    static func capacityPayload(tasks: [Record], account: String, hours: WorkingHours, window: CalendarCapacityWindow?, fallback: String, now: Date, calendar input: Calendar) -> JSON {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = input.timeZone
        let usable = window.flatMap { value -> CalendarCapacityWindow? in
            value.account == account && value.timeZone == calendar.timeZone.identifier && now >= value.updated.addingTimeInterval(-300) && now < value.updated.addingTimeInterval(3600) ? value : nil
        }
        let state = usable?.state ?? fallback
        var days: [String: JSON] = [:]
        for offset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }
            let capacity = TaskPlanner.capacity(tasks, events: usable?.events ?? [], on: day, hours: hours, calendar: calendar)
            let key = TaskPlanner.dayKey(day, calendar: calendar)
            let plannedIDs = Set(TaskPlanner.blocks(tasks, on: day, calendar: calendar).map(\.id) + TaskPlanner.allDay(tasks, on: day, calendar: calendar).map(\.id))
            let overdue = tasks.filter { !plannedIDs.contains($0.id) && !$0.completed && !$0.string("due_date").isEmpty && Dates.parse(TaskPlanner.plannedDay($0, calendar: calendar)) != nil && TaskPlanner.plannedDay($0, calendar: calendar) < key }.count
            days[key] = .object(["working": .number(Double(capacity.workingMinutes)), "busy": .number(Double(capacity.busyMinutes)), "estimated": .number(Double(capacity.estimatedMinutes)), "unknown": .number(Double(capacity.unknownTasks)), "overdue": .number(Double(overdue))])
        }
        return .object(["version": .number(1), "timeZone": .string(calendar.timeZone.identifier), "calendarState": .string(state),
            "calendarUpdated": usable.map { .number($0.updated.timeIntervalSinceReferenceDate) } ?? .null,
            "hours": .string(String(format: "%02d:%02d–%02d:%02d", hours.start / 60, hours.start % 60, hours.end / 60, hours.end % 60)), "days": .object(days)])
    }

    /// Only open task IDs and display names leave the app; filter expressions and credentials do not.
    static func listPayload(tasks: [Record], projects: [Record], labels: [Record], sections: [Record], savedViews: [Record], account: String, now: Date, calendar input: Calendar) -> [JSON] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = input.timeZone
        let context = FilterContext(projects: projects, sections: sections, labels: labels, userID: account)
        let cache = TaskCache(); cache.update(tasks)
        func row(_ record: Record, kind: String, days: [String: [String]], error: Bool = false) -> JSON {
            let key = (try? JSONEncoder().encode([account, kind, record.id]).base64EncodedString()) ?? ""
            return .object(["id": .string(key), "recordID": .string(record.id), "kind": .string(kind), "name": .string(record.name),
                "days": .object(days.mapValues { .array($0.map(JSON.string)) }), "timeZone": .string(calendar.timeZone.identifier), "invalid": .bool(error)])
        }
        var result = projects.filter { !$0.id.isEmpty }.map { project in
            row(project, kind: "project", days: ["*": cache.matching(TaskQuery(scope: .project(project.id))).map(\.id)])
        }
        result += labels.filter { !$0.id.isEmpty }.map { label in
            row(label, kind: "label", days: ["*": cache.matching(TaskQuery(scope: .label(label.id), labelName: label.name)).map(\.id)])
        }
        for view in savedViews where !view.id.isEmpty {
            guard let rule = try? FilterRule(document: view["query_ast"]), (try? rule.validate(in: context)) != nil else {
                result.append(row(view, kind: "filter", days: [:], error: true)); continue
            }
            var days: [String: [String]] = [:]
            for offset in 0..<8 {
                guard let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }
                let day = TaskPlanner.dayKey(date, calendar: calendar)
                let query = TaskQuery(scope: .all, sort: view.string("sort_by"), today: day, filter: rule,
                    filterLabels: labels.map { FilterReference(id: $0.id, name: $0.name) }, userID: account, timeZone: calendar.timeZone.identifier)
                days[day] = cache.matching(query).map(\.id)
            }
            result.append(row(view, kind: "filter", days: days))
        }
        return result
    }

}

/// Reminder syntax is protected before task dates/times are parsed, including declined or invalid
/// expressions. An exclamation in a URL, quoted prose, or an escaped token remains ordinary text.
private enum QuickReminderText {
    static let clock = #"(?:\d{1,2}(?:[:.]\d{2})?\s*(?:am|pm)|\d{1,2}[:.]\d{2})"#
    static let day = #"(?:today|tomorrow|tmr|sun(?:day)?|mon(?:day)?|tue(?:sday)?|wed(?:nesday)?|thu(?:rsday)?|fri(?:day)?|sat(?:urday)?|\d{4}-\d{2}-\d{2})"#
    static let duration = #"(?:\d+\s*(?:minutes?|mins?|m|hours?|hrs?|h|days?|d)\s*)+"#
    static var pattern: String {
        #"(?<!\S)!(?:every!?[^\n!#/@%+{~]*|"# + day + #"(?:\s+(?:at\s+)?"# + clock + #")?|"# + duration + #"(?:before|after|b|a)?|"# + clock + #"|later|[^\s]+)(?!\S)"#
    }
    static func stableID(_ seed: String) -> String {
        let hex = Array(DueReminder.digest(seed).prefix(32))
        let value = String(hex[0..<8]) + "-" + String(hex[8..<12]) + "-5" + String(hex[13..<16]) + "-a" + String(hex[17..<20]) + "-" + String(hex[20..<32])
        return value
    }
    static func spec(_ raw: String, id: String, now: Date, calendar input: Calendar) -> ReminderSpec? {
        let text = raw.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = input.timeZone
        if text == "later" { return .absolute(now.addingTimeInterval(4 * 3600), id: id, zone: calendar.timeZone.identifier) }
        let relative = text.hasSuffix("before") || text.hasSuffix("after") || text.hasSuffix("b") || text.hasSuffix("a")
        let suffix = text.hasSuffix("before") ? 6 : text.hasSuffix("after") ? 5 : relative ? 1 : 0
        let amount = String(text.dropLast(suffix)).trimmingCharacters(in: .whitespaces)
        let unitPattern = #"(\d+)\s*(minutes?|mins?|m|hours?|hrs?|h|days?|d)"#
        if let units = try? NSRegularExpression(pattern: unitPattern) {
            let matches = units.matches(in: amount, range: NSRange(amount.startIndex..., in: amount))
            let covered = matches.compactMap { Range($0.range, in: amount).map { String(amount[$0]).filter { !$0.isWhitespace } } }.joined()
            if !matches.isEmpty && covered == amount.filter({ !$0.isWhitespace }) {
                var minutes = 0
                for match in matches {
                    guard let nr = Range(match.range(at: 1), in: amount), let ur = Range(match.range(at: 2), in: amount),
                          let number = Int(amount[nr]), number <= 10080 else { return nil }
                    let unit = amount[ur]; let multiplier = unit.hasPrefix("d") ? 1440 : unit.hasPrefix("h") ? 60 : 1
                    let value = number * multiplier
                    guard value <= 10080, minutes <= 10080 - value else { return nil }
                    minutes += value
                }
                if relative {
                    let before = text.hasSuffix("b") || text.hasSuffix("before")
                    let offset = before ? -minutes : minutes
                    return .relative(offset, id: offset == 0 ? ReminderSpec.plannedID : id)
                }
                guard minutes > 0 else { return nil }
                return .absolute(now.addingTimeInterval(Double(minutes) * 60), id: id, zone: calendar.timeZone.identifier)
            }
        }
        guard let regex = try? NSRegularExpression(pattern: "^(?:((?:" + day + "))(?:\\s+(?:at\\s+)?)?)?(" + clock + ")?$"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func part(_ index: Int) -> String { Range(match.range(at: index), in: text).map { String(text[$0]) } ?? "" }
        let dayText = part(1), time = part(2)
        guard !dayText.isEmpty || !time.isEmpty else { return nil }
        var hour = 9, minute = 0
        if !time.isEmpty {
            let pieces = time.replacingOccurrences(of: #"\s"#, with: "", options: .regularExpression)
            let am = pieces.hasSuffix("am"), pm = pieces.hasSuffix("pm")
            let numbers = (am || pm ? String(pieces.dropLast(2)) : pieces).split(whereSeparator: { $0 == ":" || $0 == "." })
            guard let h = Int(numbers[0]), let m = Int(numbers.count > 1 ? String(numbers[1]) : "0"), (0...59).contains(m),
                  (am || pm ? (1...12).contains(h) : (0...23).contains(h)) else { return nil }
            hour = am || pm ? h % 12 + (pm ? 12 : 0) : h; minute = m
        }
        var date: Date?
        let components = DateComponents(hour: hour, minute: minute, second: 0)
        if dayText.isEmpty {
            date = calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime, repeatedTimePolicy: .first)
        } else if dayText == "today" || dayText == "tomorrow" || dayText == "tmr" {
            let day = calendar.date(byAdding: .day, value: dayText == "today" ? 0 : 1, to: now)!
            date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
        } else if let weekday = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7][String(dayText.prefix(3))] {
            var parts = components; parts.weekday = weekday
            date = calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime, repeatedTimePolicy: .first)
        } else if let day = Dates.parse(dayText, calendar: calendar) {
            date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
        }
        guard let date, date > now else { return nil }
        return .absolute(date, id: id, zone: calendar.timeZone.identifier)
    }
    /// Merge into current rows, retaining unknown fields/versions and explicit planned opt-out.
    static func merge(_ spec: ReminderSpec, into rows: inout [JSON]) -> Bool {
        if spec.id == ReminderSpec.plannedID {
            if let index = rows.firstIndex(where: { $0.object["id"]?.text.lowercased() == spec.id }) {
                guard var old = ReminderSpec(row: rows[index]), old.locallyEditable,
                      !ReminderSpec.duplicates(spec, in: rows, excluding: spec.id) else { return false }
                old.raw["enabled"] = .bool(true); rows[index] = .object(old.raw); return true
            }
            guard rows.count < ReminderSpec.maximum, !ReminderSpec.duplicates(spec, in: rows) else { return false }
            rows.append(.object(spec.raw)); return true
        }
        if rows.isEmpty { rows.append(.object(ReminderSpec.relative(0, id: ReminderSpec.plannedID).raw)) }
        guard rows.count < ReminderSpec.maximum, !rows.contains(where: { $0.object["id"]?.text.lowercased() == spec.id }),
              !ReminderSpec.duplicates(spec, in: rows) else { return false }
        rows.append(.object(spec.raw)); return true
    }
}
