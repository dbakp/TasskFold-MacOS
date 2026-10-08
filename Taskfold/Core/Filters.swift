import Foundation
import CryptoKit

struct FilterFailure: LocalizedError, Equatable { var message: String; var errorDescription: String? { message } }
struct FilterReference: Hashable, Sendable { var id: String; var name: String; var projectID: String? = nil }
struct FilterContext {
    var projects: [Record] = [], sections: [Record] = [], labels: [Record] = []
    var userID = ""
    var people: [Record] = []
    var datePreferences: DatePhrasePreferences? = DatePhrasePreferences()
    /// Accepted names remain in app memory; project scope prevents stale directory matches.
    var personReferences: [FilterReference] {
        people.compactMap { person in
            let name = person.string("display_name")
            guard !person.id.isEmpty, person.id == userID || UUID(uuidString: person.id) != nil,
                  !person["display_name_is_fallback"].flag, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.unicodeScalars.count <= 400, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            let project = person.string("project_id")
            return FilterReference(id: person.id, name: name, projectID: project.isEmpty ? nil : project)
        }
    }
    func resolve(_ field: String, _ value: String) throws -> String {
        if field == "assignee" {
            if value.lowercased() == "me" { return "me" }
            if ["unassigned", "others"].contains(value.lowercased()) { return value.lowercased() }
            if UUID(uuidString: value) != nil { return value }
            let matches = people.filter { person in
                [person.string("display_name"), person.string("email"), person.string("invited_email")].contains { !$0.isEmpty && $0.caseInsensitiveCompare(value) == .orderedSame }
            }
            let ids = Set(matches.map(\.id))
            guard ids.count == 1, let id = ids.first, id == userID || UUID(uuidString: id) != nil else {
                throw FilterFailure(message: ids.isEmpty ? "This collaborator is unavailable. Use their exact display name, email or ID, or refresh the project members." : "More than one collaborator matches this name. Use an email or ID.")
            }
            return id == userID ? "me" : id
        }
        let rows = field == "project" ? projects : field == "section" ? sections : labels
        if let row = rows.first(where: { $0.id.lowercased() == value.lowercased() }) { return row.id }
        let named = rows.filter { $0.name.caseInsensitiveCompare(value) == .orderedSame }
        guard named.count == 1 else { throw FilterFailure(message: named.isEmpty ? "The \(field) “\(value)” is unavailable. Choose another target." : "More than one \(field) is named “\(value)”. Use its ID.") }
        return named[0].id
    }
    func name(_ field: String, _ id: String) -> String {
        let rows = field == "project" ? projects : field == "section" ? sections : labels
        guard let target = rows.first(where: { $0.id == id }) else { return id }
        return rows.filter { $0.name.caseInsensitiveCompare(target.name) == .orderedSame }.count == 1 ? target.name : id
    }
}

/// Clock predicates use the viewer's wall minute. Dated time predicates compare instants.
enum FilterTimeReference {
    static let expressions = ["planned_time_on": "time", "planned_time_before": "time before", "planned_time_after": "time after"]
    static func canonical(_ raw: String) throws -> String {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = text.replacingOccurrences(of: " ", with: "")
        guard !text.contains(" ") || text.hasSuffix(" am") || text.hasSuffix(" pm"), !text.dropLast(3).contains(" ") else { throw FilterFailure(message: "Use a time such as 14:00 or 2pm.") }
        let normalized = compact
        let suffix = normalized.hasSuffix("am") ? "am" : normalized.hasSuffix("pm") ? "pm" : ""
        let clock = suffix.isEmpty ? normalized : String(normalized.dropLast(2))
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard (suffix.isEmpty ? parts.count == 2 : (1...2).contains(parts.count)),
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              parts[0].count <= 2, let hour = Int(parts[0]),
              (suffix.isEmpty ? 0...23 : 1...12).contains(hour),
              parts.count == 1 || parts[1].count == 2,
              let minute = parts.count == 1 ? 0 : Int(parts[1]), (0...59).contains(minute) else {
            throw FilterFailure(message: "Use a time such as 14:00 or 2pm.")
        }
        return String(format: "%02d:%02d", suffix.isEmpty ? hour : hour % 12 + (suffix == "pm" ? 12 : 0), minute)
    }
    static func split(_ reference: String) -> (day: String, clock: String)? {
        let parts = reference.components(separatedBy: " at ")
        guard parts.count == 2, !parts[0].isEmpty, let clock = try? canonical(parts[1]) else { return nil }
        return (parts[0], clock)
    }
    static func boundary(_ reference: String, today: String, timeZone: String, datePreferences: DatePhrasePreferences? = DatePhrasePreferences()) -> Date? {
        guard let parts = split(reference), let zone = TimeZone(identifier: timeZone),
              let day = FilterDateReference.day(parts.day, today: today, timeZone: timeZone, datePreferences: datePreferences) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        guard let date = Dates.parse(day, calendar: calendar) else { return nil }
        let clock = parts.clock.split(separator: ":").compactMap { Int($0) }
        return TaskPlanning.wallTime(day: date, hour: clock[0], minute: clock[1], calendar: calendar)
    }
    static func start(_ task: Record, timeZone: String) -> Date? {
        // A malformed or date-only task cannot become a timed result through midnight fallback.
        let raw = task.string("due_time"), pieces = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(pieces.count), pieces.allSatisfy({ $0.count == 2 && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              pieces.count == 2 || (Int(pieces[2]).map { (0...59).contains($0) } ?? false),
              (try? canonical(String(raw.prefix(5)))) == String(raw.prefix(5)),
              let zone = TimeZone(identifier: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return TaskPlanning.start(task, calendar: calendar)
    }
    static func minute(_ task: Record, timeZone: String) -> String? {
        guard let date = start(task, timeZone: timeZone), let zone = TimeZone(identifier: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

/// Elapsed windows are minute-resolution instants, independent of calendar/DST day lengths.
enum FilterClockWindow {
    static let fields: Set<String> = ["planned_before", "planned_after", "effective_due_before", "effective_due_after"]
    static func offset(_ raw: String) -> Int? {
        let text = raw.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if text == "now" { return 0 }
        let words = text.split(separator: " ")
        let count: Substring, unit: Substring, sign: Int
        if words.count == 3, words[0] == "in" { count = words[1]; unit = words[2]; sign = 1 }
        else if words.count == 2, let first = words[0].first, first == "+" || first == "-" { count = words[0].dropFirst(); unit = words[1]; sign = first == "-" ? -1 : 1 }
        else { return nil }
        guard ["minute", "minutes", "hour", "hours"].contains(unit),
              count == "one" || (!count.isEmpty && count.utf8.allSatisfy { (48...57).contains($0) }),
              let number = count == "one" ? 1 : Int(count), (1...10080).contains(number) else { return nil }
        let multiplier = unit.hasPrefix("hour") ? 60 : 1
        guard number <= 10080 / multiplier else { return nil }
        return number * multiplier * sign
    }
    static func canonical(_ raw: String) -> String? {
        guard let value = offset(raw) else { return nil }
        if value == 0 { return "now" }
        let hours = abs(value) % 60 == 0, count = hours ? abs(value) / 60 : abs(value)
        return (value > 0 ? "+" : "-") + String(count) + " " + (hours ? (count == 1 ? "hour" : "hours") : (count == 1 ? "minute" : "minutes"))
    }
    static func minute(_ now: Date) -> Date { Date(timeIntervalSinceReferenceDate: floor(now.timeIntervalSinceReferenceDate / 60) * 60) }
    static func boundary(_ reference: String, now: Date?) -> Date? {
        guard let delta = offset(reference), let now, now.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return minute(now).addingTimeInterval(Double(delta) * 60)
    }
}

/// Civil-day references stay relative in persisted queries; no clock or task mutation is needed.
enum FilterDateReference {
    static let expressions = [
        "planned_on": "date", "planned_before": "date before", "planned_after": "date after",
        "effective_due_on": "effective-due", "effective_due_before": "effective-due before", "effective_due_after": "effective-due after",
        "deadline_on": "deadline on", "deadline_before_day": "deadline before", "deadline_after": "deadline after"
    ]
    private static func offset(_ text: String) -> Int? {
        let words = text.split(separator: " ")
        if words.count == 3, words[0] == "in", ["day", "days"].contains(words[2]), let n = Int(words[1]), (0...3650).contains(n) { return n }
        if words.count == 3, ["day", "days"].contains(words[1]), words[2] == "ago", let n = Int(words[0]), (0...3650).contains(n) { return -n }
        return nil
    }
    static func canonical(_ raw: String, allowTime: Bool = true, allowElapsed: Bool = false) throws -> String {
        let text = raw.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty, text.unicodeScalars.count <= 80 else { throw FilterFailure(message: "Enter a date or a short date phrase.") }
        if allowElapsed, let window = FilterClockWindow.canonical(text) { return window }
        if text.contains(" at ") {
            guard allowTime, let parts = FilterTimeReference.split(text) else { throw FilterFailure(message: "Use a date and time such as today at 14:00. Deadlines take a date only.") }
            return try canonical(parts.day, allowTime: false) + " at " + parts.clock
        }
        if let delta = offset(text) { return delta == 0 ? "today" : delta > 0 ? "in \(delta) days" : "\(-delta) days ago" }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let anchor = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: 12))!
        guard QuickNaturalDateText.resolve(text, relativeTo: anchor, calendar: calendar, inclusiveWeekday: true) != nil else {
            throw FilterFailure(message: "Enter a valid date phrase. Use at 14:00 to add a time.")
        }
        return text
    }
    static func day(_ reference: String, today: String, timeZone: String, datePreferences: DatePhrasePreferences? = DatePhrasePreferences()) -> String? {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        guard let anchor = Dates.parse(today, calendar: calendar) else { return nil }
        let date: Date?
        if let delta = offset(reference) { date = calendar.date(byAdding: .day, value: delta, to: anchor) }
        else { date = QuickNaturalDateText.resolve(reference, relativeTo: anchor, calendar: calendar, inclusiveWeekday: true, datePreferences: datePreferences) }
        return date.map { TaskPlanner.dayKey($0, calendar: calendar) }
    }
}

/// Creation dates are recorded metadata, independent of plans and deadlines.
enum FilterCreationReference {
    static let expressions = ["created_on": "created", "created_before": "created before", "created_after": "created after"]
    static func canonical(_ raw: String) throws -> String {
        let text = raw.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let parts = text.split(separator: " ")
        if parts.count == 2, parts[0].hasPrefix("-"), ["day", "days"].contains(parts[1]) {
            let digits = parts[0].dropFirst()
            guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }), let offset = Int(digits), (0...3650).contains(offset) else {
                throw FilterFailure(message: "Use a day offset from -0 to -3650 days.")
            }
            return try FilterDateReference.canonical("\(offset) days ago", allowTime: false)
        }
        do { return try FilterDateReference.canonical(text, allowTime: false) }
        catch let error as FilterFailure {
            if DatePhrasePreferences.phrases.contains(text) { throw error }
            throw FilterFailure(message: "Enter a creation date without a time. Try today, yesterday or -30 days.")
        }
    }
    static func day(_ task: Record, timeZone: String) -> String? {
        let value = task.string("created_at")
        // Preserve date-only legacy records as civil dates. Do not invent a date
        // for absent or malformed metadata from the plan, deadline or current clock.
        if value.count == 10, Dates.parse(value) != nil { return value }
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil,
              Dates.parse(String(value.prefix(10))) != nil,
              let instant = TaskPlanning.instant(value), let zone = TimeZone(identifier: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return TaskPlanner.dayKey(instant, calendar: calendar)
    }
}

/// Name patterns are explicit dynamic selectors; exact targets retain their stored IDs.
enum FilterNamePattern {
    static let expressions = ["project_name": "project matching", "section_name": "section matching", "label_name": "label matching", "assignee_name": "assignee matching"]
    static func canonical(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.unicodeScalars.count <= 120,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw FilterFailure(message: "Enter a name pattern of 1–120 characters. Use * for any characters.")
        }
        var escaped = false
        for scalar in value.unicodeScalars {
            if escaped {
                guard scalar == "*" || scalar == "\\" else { throw FilterFailure(message: "Only * and backslash can be escaped in a name pattern.") }
                escaped = false
            } else if scalar == "\\" { escaped = true }
        }
        guard !escaped else { throw FilterFailure(message: "Finish the escaped character in the name pattern.") }
        return value
    }
    static func matches(_ name: String, pattern: String) -> Bool {
        guard let pattern = try? canonical(pattern), name.unicodeScalars.count <= 400 else { return false }
        let locale = Locale(identifier: "en_US_POSIX")
        func folded(_ value: String) -> [Unicode.Scalar] {
            Array(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale).unicodeScalars)
        }
        // Bounded dynamic programming; wildcard matching cannot backtrack exponentially.
        var tokens: [Unicode.Scalar?] = [], escaped = false
        for scalar in folded(pattern) {
            if escaped { tokens.append(scalar); escaped = false }
            else if scalar == "\\" { escaped = true }
            else { tokens.append(scalar == "*" ? nil : scalar) }
        }
        let characters = folded(name)
        var previous = [Bool](repeating: false, count: characters.count + 1); previous[0] = true
        for token in tokens {
            var next = [Bool](repeating: false, count: previous.count)
            if token == nil { next[0] = previous[0] }
            for i in characters.indices {
                next[i + 1] = token.map { previous[i] && $0 == characters[i] } ?? (previous[i + 1] || next[i])
            }
            previous = next
        }
        return previous[characters.count]
    }
}

/// Resolve each name pattern once per catalog/query, rather than for every task.
struct FilterNameBinding {
    var field: String, value: String
    var ids: Set<String>, names: Set<String>
    var people: Set<FilterReference> = []
}

/// Versioned query AST shared by app lists, exported backups and widget projections.
indirect enum FilterRule: Hashable, Sendable {
    case predicate(String, String), and([FilterRule]), or([FilterRule]), not(FilterRule), sections([FilterRule])
    static let fields = ["all", "inbox", "today", "overdue", "next", "no_date", "priority", "project", "section", "label", "completed", "assignee", "due", "before", "deadline_today", "deadline_overdue", "deadline_next", "no_deadline", "deadline", "deadline_before", "duration_max", "no_estimate", "search", "recurring", "no_time", "no_labels", "assigned"] + FilterDateReference.expressions.keys.sorted() + FilterTimeReference.expressions.keys.sorted() + FilterCreationReference.expressions.keys.sorted() + FilterNamePattern.expressions.keys.sorted()
    var json: JSON {
        switch self {
        case .predicate(let field, let value): return .object(["op": .string("predicate"), "field": .string(field), "value": .string(value)])
        case .and(let rules): return .object(["op": .string("and"), "children": .array(rules.map(\.json))])
        case .or(let rules): return .object(["op": .string("or"), "children": .array(rules.map(\.json))])
        case .not(let rule): return .object(["op": .string("not"), "child": rule.json])
        case .sections(let rules): return .object(["op": .string("sections"), "children": .array(rules.map(\.json))])
        }
    }
    var document: JSON { .object(["version": .number(1), "root": json]) }
    init(document: JSON) throws {
        guard document.object["version"] == .number(1), let root = document.object["root"] else { throw FilterFailure(message: "This filter version is unsupported. Update Taskfold before editing it.") }
        try self.init(json: root, depth: 0)
    }
    init(json: JSON, depth: Int = 0) throws {
        guard depth < 24 else { throw FilterFailure(message: "This filter is nested too deeply.") }
        let row = Record(json.object)
        switch row.string("op") {
        case "predicate":
            let field = row.string("field"), value = row.string("value")
            guard Self.fields.contains(field) else { throw FilterFailure(message: "Unsupported filter field: \(field).") }
            if ["priority", "next", "deadline_next", "duration_max"].contains(field) {
                guard let number = Int(value), (1...(field == "priority" ? 4 : field == "duration_max" ? 10080 : 3650)).contains(number) else { throw FilterFailure(message: "Enter a valid number for \(field).") }
            }
            if ["due", "before", "deadline", "deadline_before"].contains(field), Dates.parse(value) == nil { throw FilterFailure(message: "Enter a valid YYYY-MM-DD date.") }
            if field == "assignee", !["me", "unassigned", "others"].contains(value), UUID(uuidString: value) == nil { throw FilterFailure(message: "Choose an available collaborator.") }
            if field == "completed", !["true", "false"].contains(value) { throw FilterFailure(message: "Choose a valid completion state.") }
            if ["project", "section", "label", "assignee"].contains(field), value.isEmpty { throw FilterFailure(message: "Choose a \(field) target.") }
            if field == "search" {
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.unicodeScalars.count <= 400 else { throw FilterFailure(message: "Enter 1–400 characters to search for.") }
            }
            if ["recurring", "no_time", "no_labels", "assigned"].contains(field) {
                guard row["value"] == .string("") else { throw FilterFailure(message: "This condition does not take a value.") }
            }
            if FilterNamePattern.expressions[field] != nil {
                guard case .string = row["value"] else { throw FilterFailure(message: "Enter a name pattern.") }
                self = .predicate(field, try FilterNamePattern.canonical(value))
            } else if FilterCreationReference.expressions[field] != nil {
                guard case .string = row["value"] else { throw FilterFailure(message: "Enter a creation date or a short date phrase.") }
                self = .predicate(field, try FilterCreationReference.canonical(value))
            } else if FilterDateReference.expressions[field] != nil {
                guard case .string = row["value"] else { throw FilterFailure(message: "Enter a date or a short date phrase.") }
                self = .predicate(field, try FilterDateReference.canonical(value, allowTime: !field.hasPrefix("deadline"), allowElapsed: FilterClockWindow.fields.contains(field)))
            } else if FilterTimeReference.expressions[field] != nil {
                guard case .string = row["value"] else { throw FilterFailure(message: "Enter a time such as 14:00.") }
                self = .predicate(field, try FilterTimeReference.canonical(value))
            } else { self = .predicate(field, value) }
        case "sections":
            guard depth == 0, case .array(let nodes) = row["children"], (2...20).contains(nodes.count) else { throw FilterFailure(message: "Separate query lists need 2–20 queries at the top level.") }
            self = .sections(try nodes.map { try Self(json: $0, depth: depth + 1) })
        case "and", "or":
            guard case .array(let nodes) = row["children"], !nodes.isEmpty, nodes.count <= 20 else { throw FilterFailure(message: "A filter group needs 1–20 conditions.") }
            let rules = try nodes.map { try Self(json: $0, depth: depth + 1) }
            self = row.string("op") == "and" ? .and(rules) : .or(rules)
        case "not": self = .not(try Self(json: row["child"], depth: depth + 1))
        default: throw FilterFailure(message: "This filter has an invalid operator.")
        }
    }
    func validate(in context: FilterContext) throws {
        if usesDatePreferences, context.datePreferences == nil { throw FilterFailure(message: "These date preferences are unsupported. Update Taskfold before editing this filter.") }
        switch self {
        case .predicate(let field, let value):
            if ["project", "section", "label"].contains(field) { let rows = field == "project" ? context.projects : field == "section" ? context.sections : context.labels; guard rows.contains(where: { $0.id == value }) else { throw FilterFailure(message: "A referenced " + field + " was deleted or is no longer accessible. Edit the filter to choose another target.") } }
        case .and(let rules), .or(let rules), .sections(let rules): for rule in rules { try rule.validate(in: context) }
        case .not(let rule): try rule.validate(in: context)
        }
    }
    var hasQuerySections: Bool { if case .sections = self { return true }; return false }
    var querySectionKeys: [String] {
        guard case .sections(let queries) = self else { return [] }
        var occurrences: [String: Int] = [:]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return queries.map { query in
            let digest = SHA256.hash(data: (try? encoder.encode(query.json)) ?? Data()).map { String(format: "%02x", $0) }.joined()
            let ordinal = occurrences[digest, default: 0]; occurrences[digest] = ordinal + 1
            return "query:" + digest + ":" + String(ordinal)
        }
    }
    /// Completion visibility belongs to each independent query, not the union.
    func resultMatches(_ task: Record, context: FilterContext, today: String, timeZone: String, includeCompleted: Bool = false, now: Date? = nil) -> Bool {
        if case .sections(let rules) = self { return rules.contains { $0.resultMatches(task, context: context, today: today, timeZone: timeZone, includeCompleted: includeCompleted, now: now) } }
        return (includeCompleted || includesCompletion || !task.completed) && matches(task, today: today, userID: context.userID, labels: context.labels.map { FilterReference(id: $0.id, name: $0.name) }, timeZone: timeZone, projects: context.projects.map { FilterReference(id: $0.id, name: $0.name) }, sections: context.sections.map { FilterReference(id: $0.id, name: $0.name, projectID: $0.string("project_id").isEmpty ? nil : $0.string("project_id")) }, now: now, datePreferences: context.datePreferences, people: context.personReferences)
    }
    var usesDatePreferences: Bool {
        switch self {
        case .predicate(let field, let value):
            return (FilterDateReference.expressions[field] != nil || FilterCreationReference.expressions[field] != nil) && DatePhrasePreferences.phrases.contains(FilterTimeReference.split(value)?.day ?? value)
        case .and(let rules), .or(let rules), .sections(let rules): return rules.contains { $0.usesDatePreferences }
        case .not(let rule): return rule.usesDatePreferences
        }
    }
    var usesClockWindow: Bool {
        switch self {
        case .predicate(let field, let value): return FilterClockWindow.fields.contains(field) && FilterClockWindow.offset(value) != nil
        case .and(let rules), .or(let rules), .sections(let rules): return rules.contains { $0.usesClockWindow }
        case .not(let rule): return rule.usesClockWindow
        }
    }
    var includesCompletion: Bool {
        switch self { case .predicate(let field, _): return field == "completed"; case .and(let r), .or(let r), .sections(let r): return r.contains { $0.includesCompletion }; case .not(let r): return r.includesCompletion }
    }
    func nameBindings(projects: [FilterReference], sections: [FilterReference], labels: [FilterReference], people: [FilterReference] = []) -> [FilterNameBinding] {
        switch self {
        case .and(let rules), .or(let rules), .sections(let rules): return rules.flatMap { $0.nameBindings(projects: projects, sections: sections, labels: labels, people: people) }
        case .not(let rule): return rule.nameBindings(projects: projects, sections: sections, labels: labels, people: people)
        case .predicate(let field, let value):
            guard FilterNamePattern.expressions[field] != nil else { return [] }
            let rows = field == "project_name" ? projects : field == "section_name" ? sections : field == "assignee_name" ? people : labels
            let matching = rows.filter { FilterNamePattern.matches($0.name, pattern: value) }
            return [FilterNameBinding(field: field, value: value, ids: Set(matching.map(\.id)), names: Set(matching.map(\.name)), people: field == "assignee_name" ? Set(matching) : [])]
        }
    }
    /// Missing catalog references remain excluded even under NOT or OR.
    private func nameReferencesAvailable(_ task: Record, projects: [FilterReference], sections: [FilterReference], labels: [FilterReference], userID: String, people: [FilterReference]) -> Bool {
        let userIdentityMissing = userID.isEmpty
        switch self {
        case .sections: return true // Each independent query checks its own references.
        case .and(let rules), .or(let rules): return rules.allSatisfy { $0.nameReferencesAvailable(task, projects: projects, sections: sections, labels: labels, userID: userID, people: people) }
        case .not(let rule): return rule.nameReferencesAvailable(task, projects: projects, sections: sections, labels: labels, userID: userID, people: people)
        case .predicate(let field, let value):
            if field == "assignee", ["me", "others"].contains(value), userIdentityMissing { return false }
            if field == "assignee_name" {
                guard !userIdentityMissing else { return false }
                let assignee = task.string("assigned_to"), project = task.string("project_id")
                guard project.isEmpty || projects.contains(where: { $0.id == project }) else { return false }
                if assignee.isEmpty { return true }
                guard !project.isEmpty else { return false }
                return people.contains { $0.id == assignee && ($0.projectID == nil || $0.projectID == project) }
            }
            if FilterNamePattern.expressions[field] != nil, !task.string("project_id").isEmpty, !projects.contains(where: { $0.id == task.string("project_id") }) { return false }
            if field == "project_name" { let id = task.string("project_id"); return id.isEmpty || projects.contains { $0.id == id } }
            if field == "section_name" { let id = task.string("section_id"); return id.isEmpty || sections.contains { $0.id == id && ($0.projectID == nil || $0.projectID == task.string("project_id")) } }
            if field == "label_name" {
                return task["labels"].list.allSatisfy { stored in
                    guard case .string(let value) = stored else { return false }
                    return labels.contains { $0.id == value || $0.name == value }
                }
            }
            return true
        }
    }
    func matches(_ task: Record, today: String, userID: String, labels: [FilterReference], timeZone: String,
                 projects: [FilterReference] = [], sections: [FilterReference] = [], nameBindings supplied: [FilterNameBinding]? = nil, now: Date? = nil, datePreferences: DatePhrasePreferences? = DatePhrasePreferences(), people: [FilterReference] = []) -> Bool {
        if !hasQuerySections, usesDatePreferences, datePreferences == nil { return false }
        // Independent query sections may still show safe results when the reader has no clock.
        if !hasQuerySections, usesClockWindow, now.map({ $0.timeIntervalSinceReferenceDate.isFinite }) != true { return false }
        let bindings = supplied ?? nameBindings(projects: projects, sections: sections, labels: labels, people: people)
        guard nameReferencesAvailable(task, projects: projects, sections: sections, labels: labels, userID: userID, people: people) else { return false }
        switch self {
        case .sections(let rules): return rules.contains { $0.matches(task, today: today, userID: userID, labels: labels, timeZone: timeZone, projects: projects, sections: sections, nameBindings: bindings, now: now, datePreferences: datePreferences, people: people) }
        case .and(let rules): return rules.allSatisfy { $0.matches(task, today: today, userID: userID, labels: labels, timeZone: timeZone, projects: projects, sections: sections, nameBindings: bindings, now: now, datePreferences: datePreferences, people: people) }
        case .or(let rules): return rules.contains { $0.matches(task, today: today, userID: userID, labels: labels, timeZone: timeZone, projects: projects, sections: sections, nameBindings: bindings, now: now, datePreferences: datePreferences, people: people) }
        case .not(let rule): return !rule.matches(task, today: today, userID: userID, labels: labels, timeZone: timeZone, projects: projects, sections: sections, nameBindings: bindings, now: now, datePreferences: datePreferences, people: people)
        case .predicate(let field, let value):
            let day = Self.plannedDay(task, timeZone: timeZone), deadline = task.string("deadline_date")
            func next(_ date: String) -> Bool {
                guard !date.isEmpty, let start = Dates.parse(today), let end = Calendar(identifier: .gregorian).date(byAdding: .day, value: Int(value) ?? 1, to: start) else { return false }
                return date >= today && date < Dates.day(end)
            }
            if FilterTimeReference.expressions[field] != nil {
                guard let candidate = FilterTimeReference.minute(task, timeZone: timeZone) else { return false }
                if field.hasSuffix("_before") { return candidate < value }
                if field.hasSuffix("_after") { return candidate > value }
                return candidate == value
            }
            if FilterCreationReference.expressions[field] != nil {
                guard let candidate = FilterCreationReference.day(task, timeZone: timeZone),
                      let boundary = FilterDateReference.day(value, today: today, timeZone: timeZone, datePreferences: datePreferences) else { return false }
                if field == "created_before" { return candidate < boundary }
                if field == "created_after" { return candidate > boundary }
                return candidate == boundary
            }
            if FilterDateReference.expressions[field] != nil {
                if FilterClockWindow.fields.contains(field), FilterClockWindow.offset(value) != nil {
                    guard let boundary = FilterClockWindow.boundary(value, now: now),
                          let candidate = FilterTimeReference.start(task, timeZone: timeZone) else { return false }
                    return field.hasSuffix("_after") ? candidate >= boundary.addingTimeInterval(60) : candidate < boundary
                }
                if FilterTimeReference.split(value) != nil {
                    guard let boundary = FilterTimeReference.boundary(value, today: today, timeZone: timeZone, datePreferences: datePreferences),
                          let candidate = FilterTimeReference.start(task, timeZone: timeZone) else { return false }
                    if field.contains("_before") { return candidate < boundary }
                    if field.hasSuffix("_after") { return candidate >= boundary.addingTimeInterval(60) }
                    return candidate >= boundary && candidate < boundary.addingTimeInterval(60)
                }
                guard let boundary = FilterDateReference.day(value, today: today, timeZone: timeZone, datePreferences: datePreferences) else { return false }
                let candidate = field.hasPrefix("planned_") ? day : field.hasPrefix("effective_due_") ? (day.isEmpty ? deadline : day) : deadline
                guard !candidate.isEmpty else { return false }
                if field.contains("_before") { return candidate < boundary }
                if field.hasSuffix("_after") { return candidate > boundary }
                return candidate == boundary
            }
            switch field {
            case "all": return true
            case "inbox": return task.string("project_id").isEmpty
            case "today": return day == today
            case "overdue": return !day.isEmpty && day < today
            case "next": return next(day)
            case "no_date": return day.isEmpty
            case "priority": return task.priority == Int(value)
            case "project_name", "section_name", "label_name", "assignee_name":
                guard let binding = bindings.first(where: { $0.field == field && $0.value == value }) else { return false }
                if field == "assignee_name" { return binding.people.contains { $0.id == task.string("assigned_to") && ($0.projectID == nil || $0.projectID == task.string("project_id")) } }
                if field != "label_name" { return binding.ids.contains(task.string(field == "project_name" ? "project_id" : "section_id")) }
                return task["labels"].list.contains { stored in
                    guard case .string(let item) = stored else { return false }; return binding.ids.contains(item) || binding.names.contains(item)
                }
            case "project": return task.string("project_id") == value
            case "section": return task.string("section_id") == value
            case "label": return task["labels"].list.contains(.string(value)) || labels.first(where: { $0.id == value }).map { task["labels"].list.contains(.string($0.name)) } == true
            case "completed": return task.completed == (value == "true")
            case "assigned": return !task.string("assigned_to").isEmpty
            case "assignee":
                let assignee = task.string("assigned_to")
                if value == "others" { return !assignee.isEmpty && assignee != userID }
                return assignee == (value == "me" ? userID : value == "unassigned" ? "" : value)
            case "due": return day == value
            case "before": return !day.isEmpty && day < value
            case "deadline_today": return deadline == today
            case "deadline_overdue": return !deadline.isEmpty && deadline < today
            case "deadline_next": return next(deadline)
            case "no_deadline": return deadline.isEmpty
            case "deadline": return deadline == value
            case "deadline_before": return !deadline.isEmpty && deadline < value
            case "duration_max": return task.durationMinutes.map { $0 <= (Int(value) ?? 0) } ?? false
            case "no_estimate": return task.durationMinutes == nil
            case "search":
                let locale = Locale(identifier: "en_US_POSIX")
                let content = (task.title + " " + task.string("description")).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
                let words = value.unicodeScalars.split(whereSeparator: { $0.properties.isWhitespace }).map { String(String.UnicodeScalarView($0)).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale) }
                return !words.isEmpty && words.allSatisfy { !$0.isEmpty && content.contains($0) }
            case "recurring": return task["is_recurring"].flag
            case "no_time": return task.string("due_time").isEmpty
            case "no_labels": return task["labels"].list.isEmpty
            default: return false
            }
        }
    }
    static func plannedDay(_ task: Record, timeZone: String) -> String {
        guard !task.string("time_zone").isEmpty, let instant = TaskPlanning.start(task) else { return String(task.string("due_date").prefix(10)) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    /// Only explicit creation fields common to every OR branch become capture defaults.
    /// Relative windows, negation and estimates never invent a date or duration.
    func captureDefaults(in context: FilterContext, today: String, timeZone: String = TimeZone.current.identifier) -> [String: JSON] {
        switch self {
        case .not: return [:]
        case .and(let rules):
            var result: [String: JSON] = [:], conflicts = Set<String>()
            for rule in rules {
                for (field, value) in rule.captureDefaults(in: context, today: today, timeZone: timeZone) {
                    if field == "labels", let old = result[field] { result[field] = .array(Array(Set((old.list + value.list).map(\.text))).sorted().map(JSON.string)) }
                    else if let old = result[field], old != value { conflicts.insert(field) }
                    else { result[field] = value }
                }
            }
            for field in conflicts { result.removeValue(forKey: field) }
            return result
        case .or(let rules), .sections(let rules):
            guard let first = rules.first else { return [:] }
            return rules.dropFirst().reduce(first.captureDefaults(in: context, today: today, timeZone: timeZone)) { defaults, rule in
                let branch = rule.captureDefaults(in: context, today: today, timeZone: timeZone)
                return defaults.filter { branch[$0.key] == $0.value }
            }
        case .predicate(let field, let value):
            switch field {
            case "project": return ["project_id": .string(value)]
            case "section":
                guard let section = context.sections.first(where: { $0.id == value }) else { return [:] }
                return ["section_id": .string(value), "project_id": section["project_id"]]
            case "inbox": return ["project_id": .null]
            case "priority": return ["priority": .number(Double(Int(value) ?? 4))]
            case "label": return ["labels": .array([.string(context.labels.first(where: { $0.id == value })?.name ?? value)])]
            case "planned_on", "deadline_on":
                if FilterTimeReference.split(value) != nil { return [:] }
                guard let day = FilterDateReference.day(value, today: today, timeZone: timeZone, datePreferences: context.datePreferences) else { return [:] }
                return [field == "planned_on" ? "due_date" : "deadline_date": .string(day)]
            case "today": return ["due_date": .string(today)]
            case "due": return ["due_date": .string(value)]
            case "no_date": return ["due_date": .null]
            case "deadline_today": return ["deadline_date": .string(today)]
            case "deadline": return ["deadline_date": .string(value)]
            default: return [:]
            }
        }
    }
    /// Native headings describe the query without exposing stored collaborator IDs.
    /// This presentation never changes the persisted predicate or its canonical expression.
    func sectionTitle(in context: FilterContext) -> String {
        switch self {
        case .predicate("assignee_name", let value): return "Assigned name matches “" + value + "”"
        case .predicate("assigned", _): return "Assigned tasks"
        case .predicate("assignee", let value):
            if value == "me" { return "Assigned to me" }
            if value == "others" { return "Assigned to others" }
            if value == "unassigned" { return "Unassigned tasks" }
            guard let person = context.people.first(where: { $0.id.caseInsensitiveCompare(value) == .orderedSame }) else { return "Assigned to unavailable collaborator" }
            let name = person.string("display_name").isEmpty ? person.string("email") : person.string("display_name")
            return name.isEmpty ? "Assigned to unavailable collaborator" : "Assigned to " + name
        case .and(let rules): return rules.map { "(" + $0.sectionTitle(in: context) + ")" }.joined(separator: " AND ")
        case .or(let rules): return rules.map { "(" + $0.sectionTitle(in: context) + ")" }.joined(separator: " OR ")
        case .not(let rule): return "NOT (" + rule.sectionTitle(in: context) + ")"
        default: return expression(in: context)
        }
    }
    func expression(in context: FilterContext) -> String {
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        switch self {
        case .sections(let rules): return rules.map { $0.expression(in: context) }.joined(separator: ", ")
        case .and(let rules): return rules.map { "(" + $0.expression(in: context) + ")" }.joined(separator: " AND ")
        case .or(let rules): return rules.map { "(" + $0.expression(in: context) + ")" }.joined(separator: " OR ")
        case .not(let rule): return "NOT (" + rule.expression(in: context) + ")"
        case .predicate(let field, let value):
            if let name = FilterDateReference.expressions[field] ?? FilterTimeReference.expressions[field] ?? FilterCreationReference.expressions[field] ?? FilterNamePattern.expressions[field] { return name + ":" + quote(value) }
            switch field {
            case "assigned": return "assigned"
            case "all": return "all"
            case "inbox": return "inbox"
            case "no_date": return "no date"
            case "priority": return "p" + value
            case "next": return "next \(value) days"
            case "project", "section", "label": return field + ":" + quote(context.name(field, value))
            case "completed": return value == "true" ? "completed" : "open"
            case "assignee": return "assignee:" + value
            case "deadline_today": return "deadline:today"
            case "deadline_overdue": return "deadline:overdue"
            case "deadline_next": return "deadline:next" + value
            case "no_deadline": return "no deadline"
            case "duration_max": return "duration<=" + value
            case "no_estimate": return "no estimate"
            case "search": return "search:" + quote(value)
            case "no_time": return "no time"
            case "no_labels": return "no labels"
            case "deadline_before": return "deadline-before:" + value
            case "due", "before", "deadline": return field + ":" + value
            default: return field
            }
        }
    }
}

struct FilterParser {
    private var tokens: [String] = []
    private var cursor = 0
    private var quotedTokens = Set<Int>()
    let context: FilterContext
    init(_ expression: String, context: FilterContext) throws {
        self.context = context
        guard expression.count <= 4000 else { throw FilterFailure(message: "Keep the filter expression under 4,000 characters.") }
        var token = "", quoted = false, escaped = false, hadQuote = false
        func appendToken() {
            if !token.isEmpty {
                if hadQuote { quotedTokens.insert(tokens.count) }
                tokens.append(token)
            }
            token = ""; hadQuote = false
        }
        // Tokenize scalars so an accent attached to a space or quote cannot swallow the delimiter.
        for scalar in expression.unicodeScalars {
            let character = Character(String(scalar))
            if escaped { token.append(character); escaped = false; continue }
            if quoted && character == "\\" { escaped = true; continue }
            if character == "\"" { quoted.toggle(); hadQuote = true; continue }
            if quoted { token.append(character); continue }
            if character.isWhitespace { appendToken(); continue }
            if "()&|!,".contains(character) { appendToken(); tokens.append(String(character)); continue }
            token.append(character)
        }
        guard !quoted && !escaped else { throw FilterFailure(message: "Close the quoted target name.") }
        appendToken()
        guard !tokens.isEmpty, tokens.count <= 300 else { throw FilterFailure(message: "Add a filter condition.") }
    }
    mutating func parse() throws -> FilterRule {
        var queries = [try parseOr(depth: 0)]
        while consume([","]) {
            guard queries.count < 20 else { throw FilterFailure(message: "Keep separate query lists within 20 queries.") }
            queries.append(try parseOr(depth: 0))
        }
        let rule: FilterRule = queries.count == 1 ? queries[0] : .sections(queries)
        guard cursor == tokens.count else { throw FilterFailure(message: "Unexpected “\(tokens[cursor])”. Join conditions with AND or OR.") }
        let checked = try FilterRule(json: rule.json)
        try checked.validate(in: context); return checked
    }
    private mutating func consume(_ choices: [String]) -> Bool {
        guard cursor < tokens.count, !quotedTokens.contains(cursor), choices.contains(tokens[cursor].lowercased()) else { return false }; cursor += 1; return true
    }
    private mutating func parseOr(depth: Int) throws -> FilterRule {
        var rules = [try parseAnd(depth: depth)]
        while consume(["or", "|"]) { rules.append(try parseAnd(depth: depth)) }
        return rules.count == 1 ? rules[0] : .or(rules)
    }
    private mutating func parseAnd(depth: Int) throws -> FilterRule {
        var rules = [try atom(depth: depth)]
        while consume(["and", "&"]) { rules.append(try atom(depth: depth)) }
        return rules.count == 1 ? rules[0] : .and(rules)
    }
    private mutating func atom(depth: Int) throws -> FilterRule {
        guard depth < 24, cursor < tokens.count else { throw FilterFailure(message: "Add a condition after the operator.") }
        if consume(["not", "!"]) { return .not(try atom(depth: depth + 1)) }
        if consume(["("]) { let rule = try parseOr(depth: depth + 1); guard consume([")"]) else { throw FilterFailure(message: "Close the filter parenthesis.") }; return rule }
        var token = tokens[cursor]; cursor += 1
        if ["date", "effective-due", "deadline", "time", "created", "project", "section", "label", "assigned", "assignee"].contains(token.lowercased()), !quotedTokens.contains(cursor - 1), cursor < tokens.count {
            let next = tokens[cursor].lowercased()
            if next.hasPrefix("to:") || next.hasPrefix("matching:") || ["before:", "after:", "on:"].contains(next) || next.hasPrefix("before:") || next.hasPrefix("after:") || next.hasPrefix("on:") { token += " " + tokens[cursor]; cursor += 1 }
        }
        let lower = token.lowercased(), scalars = token.unicodeScalars
        if scalars.first == "#" {
            let target = String(String.UnicodeScalarView(scalars.dropFirst()))
            if !quotedTokens.contains(cursor - 1), target.contains("*") { return .predicate("project_name", try FilterNamePattern.canonical(target)) }
            if target.caseInsensitiveCompare("Inbox") == .orderedSame { return .predicate("inbox", "") }
            return .predicate("project", try context.resolve("project", target))
        }
        if scalars.first == "%" || scalars.first == "@" {
            let target = String(String.UnicodeScalarView(scalars.dropFirst()))
            if !quotedTokens.contains(cursor - 1), target.contains("*") { return .predicate("label_name", try FilterNamePattern.canonical(target)) }
            return .predicate("label", try context.resolve("label", target))
        }
        if scalars.first == "/" { return .predicate("section_name", try FilterNamePattern.canonical(String(String.UnicodeScalarView(scalars.dropFirst())))) }
        if !quotedTokens.contains(cursor - 1), ["all", "inbox", "today", "overdue", "recurring", "assigned"].contains(lower) { return .predicate(lower, "") }
        if lower == "no", !quotedTokens.contains(cursor - 1), cursor < tokens.count, !quotedTokens.contains(cursor), ["date", "deadline", "estimate", "time", "labels", "priority"].contains(tokens[cursor].lowercased()) {
            let kind = tokens[cursor].lowercased(); cursor += 1
            return kind == "priority" ? .predicate("priority", "4") : .predicate("no_" + kind, "")
        }
        if lower == "next", cursor + 1 < tokens.count, Int(tokens[cursor]) != nil, consumeNumberDays() { return .predicate("next", tokens[cursor - 2]) }
        if lower == "completed" || lower == "open" { return .predicate("completed", lower == "completed" ? "true" : "false") }
        if lower.count == 2, lower.first == "p", let number = Int(lower.dropFirst()), (1...4).contains(number) { return .predicate("priority", String(number)) }
        if lower.hasPrefix("duration<=") { return .predicate("duration_max", String(lower.dropFirst(10))) }
        if let colon = scalars.firstIndex(of: ":") {
            let field = String(String.UnicodeScalarView(scalars[..<colon])).lowercased()
            let value = String(String.UnicodeScalarView(scalars[scalars.index(after: colon)...]))
            if let nameField = FilterNamePattern.expressions.first(where: { $0.value == field })?.key {
                return .predicate(nameField, try FilterNamePattern.canonical(readValue(starting: value)))
            }
            if let creationField = FilterCreationReference.expressions.first(where: { $0.value == field || ($0.key == "created_on" && field == "created on") })?.key {
                return .predicate(creationField, try FilterCreationReference.canonical(readValue(starting: value)))
            }
            if let dateField = FilterDateReference.expressions.first(where: { $0.value == field })?.key {
                return .predicate(dateField, try FilterDateReference.canonical(readValue(starting: value), allowTime: !dateField.hasPrefix("deadline"), allowElapsed: FilterClockWindow.fields.contains(dateField)))
            }
            if let timeField = FilterTimeReference.expressions.first(where: { $0.value == field })?.key {
                return .predicate(timeField, try FilterTimeReference.canonical(readValue(starting: value)))
            }
            // Existing deadline shorthands retain their exact stored meaning.
            if field == "deadline", !["today", "overdue"].contains(value.lowercased()), !(value.lowercased().hasPrefix("next") && Int(value.dropFirst(4)) != nil), !(value.count == 10 && Dates.parse(value) != nil) {
                return .predicate("deadline_on", try FilterDateReference.canonical(readValue(starting: value), allowTime: false))
            }
            if field == "search" {
                var words = value.isEmpty ? [] : [value]
                if value.isEmpty && quotedTokens.contains(cursor - 1) { throw FilterFailure(message: "Enter 1–400 characters to search for.") }
                while cursor < tokens.count {
                    if !quotedTokens.contains(cursor), ["and", "or", "&", "|", "!", "not", "(", ")", ","].contains(tokens[cursor].lowercased()) { break }
                    words.append(tokens[cursor]); cursor += 1
                }
                return .predicate("search", words.joined(separator: " "))
            }
            if ["project", "section", "label", "assignee", "assigned to"].contains(field) {
                let target = field == "assigned to" ? "assignee" : field
                let first = cursor - 1, name = readValue(starting: value)
                if target == "assignee", name.contains("*"), !(first..<cursor).contains(where: { quotedTokens.contains($0) }) {
                    return .predicate("assignee_name", try FilterNamePattern.canonical(name))
                }
                return .predicate(target, try context.resolve(target, name))
            }
            if ["due", "before", "deadline", "deadline-before"].contains(field) {
                if field == "deadline", ["today", "overdue"].contains(value.lowercased()) { return .predicate("deadline_" + value.lowercased(), "") }
                if field == "deadline", value.lowercased().hasPrefix("next") { return .predicate("deadline_next", String(value.dropFirst(4))) }
                return .predicate(field == "deadline-before" ? "deadline_before" : field, value)
            }
        }
        throw FilterFailure(message: "Unknown condition “\(token)”. Use the builder or the syntax examples.")
    }
    private mutating func readValue(starting value: String) -> String {
        var words = value.isEmpty ? [] : [value]
        while cursor < tokens.count {
            if !quotedTokens.contains(cursor), ["and", "or", "&", "|", "!", "not", "(", ")", ","].contains(tokens[cursor].lowercased()) { break }
            words.append(tokens[cursor]); cursor += 1
        }
        return words.joined(separator: " ")
    }
    private mutating func consumeNumberDays() -> Bool {
        guard cursor + 1 < tokens.count, ["days", "day"].contains(tokens[cursor + 1].lowercased()) else { return false }; cursor += 2; return true
    }
}

struct TaskGrouping {
    struct Group: Identifiable { var id: String; var name: String; var tasks: [Record] }
    /// Sections keep query order and overlap; union results stay unique for bulk actions/widgets.
    /// Content identity keeps manual ordering attached to the query through reordering/renames.
    static func queryGroups(_ tasks: [Record], rule: FilterRule?, by field: String, context: FilterContext, today: String, timeZone: String, includeCompleted: Bool = false, now: Date? = nil) -> [Group] {
        guard case .sections(let queries) = rule else { return groups(tasks, by: field, projects: context.projects, timeZone: timeZone) }
        let keys = rule?.querySectionKeys ?? []
        let projects = context.projects.map { FilterReference(id: $0.id, name: $0.name) }
        let sections = context.sections.map { FilterReference(id: $0.id, name: $0.name, projectID: $0.string("project_id").isEmpty ? nil : $0.string("project_id")) }
        let labels = context.labels.map { FilterReference(id: $0.id, name: $0.name) }
        let people = context.personReferences
        return queries.enumerated().flatMap { index, query -> [Group] in
            let key = keys[index]
            let bindings = query.nameBindings(projects: projects, sections: sections, labels: labels, people: people)
            let name = "\(index + 1) · " + query.sectionTitle(in: context)
            let matches = tasks.filter { (includeCompleted || query.includesCompletion || !$0.completed) && query.matches($0, today: today, userID: context.userID, labels: labels, timeZone: timeZone, projects: projects, sections: sections, nameBindings: bindings, now: now, datePreferences: context.datePreferences, people: people) }
            let nested = groups(matches, by: field, projects: context.projects, timeZone: timeZone)
            if nested.isEmpty { return [Group(id: key + ":all", name: name, tasks: [])] }
            return nested.map { Group(id: key + ":" + $0.id, name: field == "none" ? name : name + " / " + $0.name, tasks: $0.tasks) }
        }
    }
    static func groups(_ tasks: [Record], by field: String, projects: [Record], timeZone: String = TimeZone.current.identifier) -> [Group] {
        guard field != "none" else { return [Group(id: "all", name: "Tasks", tasks: tasks)] }
        let keyed = Dictionary(grouping: tasks) { task -> String in
            switch field { case "project": return task.string("project_id"); case "priority": return String(task.priority); case "deadline": return task.string("deadline_date"); default: return FilterRule.plannedDay(task, timeZone: timeZone) }
        }
        return keyed.keys.sorted { ($0.isEmpty ? "zzzz" : $0) < ($1.isEmpty ? "zzzz" : $1) }.map { key in
            let name: String
            switch field { case "project": name = projects.first { $0.id == key }?.name ?? (key.isEmpty ? "Inbox" : "Unavailable project"); case "priority": name = key == "4" ? "No priority" : "Priority " + key; case "deadline": name = key.isEmpty ? "No deadline" : "Deadline " + key; default: name = key.isEmpty ? "Unscheduled" : key }
            return Group(id: field + ":" + (key.isEmpty ? "none" : key), name: name, tasks: keyed[key] ?? [])
        }
    }
}
