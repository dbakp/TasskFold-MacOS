import Foundation

struct FilterFailure: LocalizedError, Equatable { var message: String; var errorDescription: String? { message } }
struct FilterReference: Hashable, Sendable { var id: String; var name: String }
struct FilterContext {
    var projects: [Record] = [], sections: [Record] = [], labels: [Record] = []
    var userID = ""
    func resolve(_ field: String, _ value: String) throws -> String {
        if field == "assignee" {
            if value.lowercased() == "me" { return "me" }
            if value.lowercased() == "unassigned" { return "unassigned" }
            guard UUID(uuidString: value) != nil else { throw FilterFailure(message: "Use assignee:me, assignee:unassigned, or a collaborator ID.") }
            return value
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

/// Versioned query AST shared by app lists, exported backups and widget projections.
indirect enum FilterRule: Hashable, Sendable {
    case predicate(String, String), and([FilterRule]), or([FilterRule]), not(FilterRule)
    static let fields = ["all", "inbox", "today", "overdue", "next", "no_date", "priority", "project", "section", "label", "completed", "assignee", "due", "before", "deadline_today", "deadline_overdue", "deadline_next", "no_deadline", "deadline", "deadline_before", "duration_max", "no_estimate"]
    var json: JSON {
        switch self {
        case .predicate(let field, let value): return .object(["op": .string("predicate"), "field": .string(field), "value": .string(value)])
        case .and(let rules): return .object(["op": .string("and"), "children": .array(rules.map(\.json))])
        case .or(let rules): return .object(["op": .string("or"), "children": .array(rules.map(\.json))])
        case .not(let rule): return .object(["op": .string("not"), "child": rule.json])
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
            if field == "assignee", !["me", "unassigned"].contains(value), UUID(uuidString: value) == nil { throw FilterFailure(message: "Choose an available collaborator.") }
            if field == "completed", !["true", "false"].contains(value) { throw FilterFailure(message: "Choose a valid completion state.") }
            if ["project", "section", "label", "assignee"].contains(field), value.isEmpty { throw FilterFailure(message: "Choose a \(field) target.") }
            self = .predicate(field, value)
        case "and", "or":
            guard case .array(let nodes) = row["children"], !nodes.isEmpty, nodes.count <= 20 else { throw FilterFailure(message: "A filter group needs 1–20 conditions.") }
            let rules = try nodes.map { try Self(json: $0, depth: depth + 1) }
            self = row.string("op") == "and" ? .and(rules) : .or(rules)
        case "not": self = .not(try Self(json: row["child"], depth: depth + 1))
        default: throw FilterFailure(message: "This filter has an invalid operator.")
        }
    }
    func validate(in context: FilterContext) throws {
        switch self {
        case .predicate(let field, let value):
            if ["project", "section", "label"].contains(field) { let rows = field == "project" ? context.projects : field == "section" ? context.sections : context.labels; guard rows.contains(where: { $0.id == value }) else { throw FilterFailure(message: "A referenced " + field + " was deleted or is no longer accessible. Edit the filter to choose another target.") } }
        case .and(let rules), .or(let rules): for rule in rules { try rule.validate(in: context) }
        case .not(let rule): try rule.validate(in: context)
        }
    }
    var includesCompletion: Bool {
        switch self { case .predicate(let field, _): return field == "completed"; case .and(let r), .or(let r): return r.contains { $0.includesCompletion }; case .not(let r): return r.includesCompletion }
    }
    func matches(_ task: Record, today: String, userID: String, labels: [FilterReference], timeZone: String) -> Bool {
        switch self {
        case .and(let rules): return rules.allSatisfy { $0.matches(task, today: today, userID: userID, labels: labels, timeZone: timeZone) }
        case .or(let rules): return rules.contains { $0.matches(task, today: today, userID: userID, labels: labels, timeZone: timeZone) }
        case .not(let rule): return !rule.matches(task, today: today, userID: userID, labels: labels, timeZone: timeZone)
        case .predicate(let field, let value):
            let day = Self.plannedDay(task, timeZone: timeZone), deadline = task.string("deadline_date")
            func next(_ date: String) -> Bool {
                guard !date.isEmpty, let start = Dates.parse(today), let end = Calendar(identifier: .gregorian).date(byAdding: .day, value: Int(value) ?? 1, to: start) else { return false }
                return date >= today && date < Dates.day(end)
            }
            switch field {
            case "all": return true
            case "inbox": return task.string("project_id").isEmpty
            case "today": return day == today
            case "overdue": return !day.isEmpty && day < today
            case "next": return next(day)
            case "no_date": return day.isEmpty
            case "priority": return task.priority == Int(value)
            case "project": return task.string("project_id") == value
            case "section": return task.string("section_id") == value
            case "label": return task["labels"].list.contains(.string(value)) || labels.first(where: { $0.id == value }).map { task["labels"].list.contains(.string($0.name)) } == true
            case "completed": return task.completed == (value == "true")
            case "assignee": return task.string("assigned_to") == (value == "me" ? userID : value == "unassigned" ? "" : value)
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
    func captureDefaults(in context: FilterContext, today: String) -> [String: JSON] {
        switch self {
        case .not: return [:]
        case .and(let rules):
            var result: [String: JSON] = [:], conflicts = Set<String>()
            for rule in rules {
                for (field, value) in rule.captureDefaults(in: context, today: today) {
                    if field == "labels", let old = result[field] { result[field] = .array(Array(Set((old.list + value.list).map(\.text))).sorted().map(JSON.string)) }
                    else if let old = result[field], old != value { conflicts.insert(field) }
                    else { result[field] = value }
                }
            }
            for field in conflicts { result.removeValue(forKey: field) }
            return result
        case .or(let rules):
            guard let first = rules.first else { return [:] }
            return rules.dropFirst().reduce(first.captureDefaults(in: context, today: today)) { defaults, rule in
                let branch = rule.captureDefaults(in: context, today: today)
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
            case "today": return ["due_date": .string(today)]
            case "due": return ["due_date": .string(value)]
            case "no_date": return ["due_date": .null]
            case "deadline_today": return ["deadline_date": .string(today)]
            case "deadline": return ["deadline_date": .string(value)]
            default: return [:]
            }
        }
    }
    func expression(in context: FilterContext) -> String {
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        switch self {
        case .and(let rules): return rules.map { "(" + $0.expression(in: context) + ")" }.joined(separator: " AND ")
        case .or(let rules): return rules.map { "(" + $0.expression(in: context) + ")" }.joined(separator: " OR ")
        case .not(let rule): return "NOT (" + rule.expression(in: context) + ")"
        case .predicate(let field, let value):
            switch field {
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
    let context: FilterContext
    init(_ expression: String, context: FilterContext) throws {
        self.context = context
        guard expression.count <= 4000 else { throw FilterFailure(message: "Keep the filter expression under 4,000 characters.") }
        var token = "", quoted = false, escaped = false
        for character in expression {
            if escaped { token.append(character); escaped = false; continue }
            if quoted && character == "\\" { escaped = true; continue }
            if character == "\"" { quoted.toggle(); continue }
            if quoted { token.append(character); continue }
            if character.isWhitespace { if !token.isEmpty { tokens.append(token); token = "" }; continue }
            if "()&|!".contains(character) { if !token.isEmpty { tokens.append(token); token = "" }; tokens.append(String(character)); continue }
            token.append(character)
        }
        guard !quoted && !escaped else { throw FilterFailure(message: "Close the quoted target name.") }
        if !token.isEmpty { tokens.append(token) }
        guard !tokens.isEmpty, tokens.count <= 300 else { throw FilterFailure(message: "Add a filter condition.") }
    }
    mutating func parse() throws -> FilterRule {
        let rule = try parseOr(depth: 0)
        guard cursor == tokens.count else { throw FilterFailure(message: "Unexpected “\(tokens[cursor])”. Join conditions with AND or OR.") }
        let checked = try FilterRule(json: rule.json)
        try checked.validate(in: context); return checked
    }
    private mutating func consume(_ choices: [String]) -> Bool {
        guard cursor < tokens.count, choices.contains(tokens[cursor].lowercased()) else { return false }; cursor += 1; return true
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
        let token = tokens[cursor]; cursor += 1; let lower = token.lowercased()
        if ["all", "inbox", "today", "overdue"].contains(lower) { return .predicate(lower, "") }
        if lower == "no", cursor < tokens.count, ["date", "deadline", "estimate"].contains(tokens[cursor].lowercased()) { let kind = tokens[cursor].lowercased(); cursor += 1; return .predicate("no_" + kind, "") }
        if lower == "next", cursor + 1 < tokens.count, Int(tokens[cursor]) != nil, consumeNumberDays() { return .predicate("next", tokens[cursor - 2]) }
        if lower == "completed" || lower == "open" { return .predicate("completed", lower == "completed" ? "true" : "false") }
        if lower.count == 2, lower.first == "p", let number = Int(lower.dropFirst()), (1...4).contains(number) { return .predicate("priority", String(number)) }
        if lower.hasPrefix("duration<=") { return .predicate("duration_max", String(lower.dropFirst(10))) }
        if let colon = token.firstIndex(of: ":") {
            let field = token[..<colon].lowercased(), value = String(token[token.index(after: colon)...])
            if ["project", "section", "label", "assignee"].contains(field) { return .predicate(field, try context.resolve(field, value)) }
            if ["due", "before", "deadline", "deadline-before"].contains(field) {
                if field == "deadline", ["today", "overdue"].contains(value.lowercased()) { return .predicate("deadline_" + value.lowercased(), "") }
                if field == "deadline", value.lowercased().hasPrefix("next") { return .predicate("deadline_next", String(value.dropFirst(4))) }
                return .predicate(field == "deadline-before" ? "deadline_before" : field, value)
            }
        }
        throw FilterFailure(message: "Unknown condition “\(token)”. Use the builder or the syntax examples.")
    }
    private mutating func consumeNumberDays() -> Bool {
        guard cursor + 1 < tokens.count, ["days", "day"].contains(tokens[cursor + 1].lowercased()) else { return false }; cursor += 2; return true
    }
}

struct TaskGrouping {
    struct Group: Identifiable { var id: String; var name: String; var tasks: [Record] }
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
