import Foundation

public struct PulseAttention: Codable, Equatable, Identifiable, Sendable {
    public var id: String, title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
    var valid: Bool { PulseProject.validID(id) && title.count <= 120 && title.utf8.count <= 800 }
}
public struct PulseDay: Codable, Equatable, Sendable {
    public var completions: Int, reopens: Int, additions: Int, movedIn: Int, movedOut: Int, attentionCount: Int
    public var attention: [PulseAttention]
    public init(completions: Int, reopens: Int, additions: Int, movedIn: Int, movedOut: Int, attentionCount: Int, attention: [PulseAttention]) {
        self.completions = completions; self.reopens = reopens; self.additions = additions; self.movedIn = movedIn; self.movedOut = movedOut; self.attentionCount = attentionCount; self.attention = attention
    }
    var valid: Bool {
        [completions, reopens, additions, movedIn, movedOut, attentionCount].allSatisfy { (0...1_000_000).contains($0) } && attention.count <= 3 && attention.count <= attentionCount && attention.allSatisfy(\.valid) && Set(attention.map(\.id)).count == attention.count
    }
}
public struct PulseProject: Codable, Equatable, Identifiable, Sendable {
    public var id: String, recordID: String, name: String
    public var total: Int, completed: Int
    public var days: [String: PulseDay]
    public init(account: String, recordID: String, name: String, total: Int, completed: Int, days: [String: PulseDay]) {
        self.id = Self.key(account: account, project: recordID); self.recordID = recordID; self.name = name; self.total = total; self.completed = completed; self.days = days
    }
    public static func key(account: String, project: String) -> String { (try? JSONEncoder().encode([account, project]).base64EncodedString()) ?? "" }
    public static func link(for id: String) -> ProjectPulseLink? {
        guard id.utf8.count <= 1024, let data = Data(base64Encoded: id), let parts = try? JSONDecoder().decode([String].self, from: data), parts.count == 2, validID(parts[0]), validID(parts[1]), key(account: parts[0], project: parts[1]) == id else { return nil }
        return ProjectPulseLink(account: parts[0], project: parts[1])
    }
    static func validID(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 256 }
    public func belongs(to account: String) -> Bool {
        Self.validID(account) && Self.validID(recordID) && id == Self.key(account: account, project: recordID) && name.count <= 160 && name.utf8.count <= 1000 && (0...1_000_000).contains(total) && (0...total).contains(completed) && days.count == 8 && days.allSatisfy { ProjectPulseSnapshot.validDay($0.key) && $0.value.valid && $0.value.attentionCount <= total - completed }
    }
}
public enum PulseWidgetStatus: Equatable, Sendable { case ready, choose, unavailable, refresh }
public struct ProjectPulseSnapshot: Codable, Equatable, Sendable {
    public var version = 1
    public var account: String, timeZone: String, history: String
    public var recordedFrom: TimeInterval?
    public var projects: [PulseProject]
    public var omitted: Int
    public init(account: String, timeZone: String, history: String, recordedFrom: TimeInterval?, projects: [PulseProject], omitted: Int = 0) {
        self.account = account; self.timeZone = timeZone; self.history = history; self.recordedFrom = recordedFrom; self.projects = projects; self.omitted = omitted
    }
    public func valid(for owner: String) -> Bool {
        version == 1 && account == owner && PulseProject.validID(owner) && TimeZone(identifier: timeZone) != nil && ["ready", "unavailable", "incomplete"].contains(history) && (0...1_000_000).contains(omitted) && projects.count <= 2048 && projects.allSatisfy { $0.belongs(to: owner) } && Set(projects.map(\.id)).count == projects.count && (recordedFrom.map { $0.isFinite && (0...4_133_980_800).contains($0) } ?? true) && (history != "ready" || recordedFrom != nil)
    }
    public func fresh(at date: Date, owner: String, updated: TimeInterval, calendar: Calendar = .current) -> Bool {
        valid(for: owner) && timeZone == calendar.timeZone.identifier && updated.isFinite && updated > 0 && date.timeIntervalSinceReferenceDate >= updated - 300 && date.timeIntervalSinceReferenceDate < updated + 86_400
    }
    public func project(_ id: String?) -> PulseProject? { guard let id else { return nil }; return projects.first { $0.id == id && $0.belongs(to: account) } }
    public func status(_ id: String?, at date: Date, owner: String, updated: TimeInterval, calendar: Calendar = .current) -> PulseWidgetStatus {
        guard fresh(at: date, owner: owner, updated: updated, calendar: calendar) else { return .refresh }
        guard id != nil else { return .choose }
        guard let project = project(id) else { return omitted > 0 ? .refresh : .unavailable }
        return project.days[Self.day(date, calendar: calendar)] == nil ? .refresh : .ready
    }
    public func timelineDates(from now: Date, updated: TimeInterval, calendar: Calendar = .current) -> [Date] {
        guard fresh(at: now, owner: account, updated: updated, calendar: calendar) else { return [now] }
        let expiry = Date(timeIntervalSinceReferenceDate: updated + 86_400)
        var dates = [now, expiry]
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)), tomorrow < expiry { dates.append(tomorrow) }
        return Array(Set(dates)).sorted()
    }
    public static func day(_ date: Date, calendar input: Calendar = .current) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = input.timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    static func validDay(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let c = value.split(separator: "-").compactMap { Int($0) }
        guard c.count == 3, c[0] > 0 else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: c[0], month: c[1], day: c[2])) else { return false }
        return day(date, calendar: calendar) == value
    }
}
public struct ProjectPulseLink: Equatable, Sendable {
    public var account: String, project: String?
    public init(account: String, project: String? = nil) { self.account = account; self.project = project }
    public var url: URL {
        var c = URLComponents(); c.scheme = "taskfold"; c.host = "pulse"
        c.queryItems = [URLQueryItem(name: "account", value: account)] + (project.map { [URLQueryItem(name: "project", value: $0)] } ?? [])
        return c.url!
    }
    public static func parse(_ url: URL) -> Self? {
        guard url.scheme == "taskfold", url.host == "pulse", url.fragment == nil,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.percentEncodedPath.isEmpty, c.user == nil, c.password == nil, c.port == nil,
              let q = c.queryItems, (1...2).contains(q.count), Set(q.map(\.name)).count == q.count, Set(q.map(\.name)).isSubset(of: ["account", "project"]),
              let account = q.first(where: { $0.name == "account" })?.value, PulseProject.validID(account) else { return nil }
        let project = q.first(where: { $0.name == "project" })?.value
        guard !q.contains(where: { $0.name == "project" }) || project.map(PulseProject.validID) == true else { return nil }
        return Self(account: account, project: project)
    }
}

#if !TASKFOLD_WIDGET_EXTENSION
extension WidgetProjection {
    /// Bound titles and summaries, never the full task ledger, leave the app.
    static func pulsePayload(tasks: [Record], projects: [Record], activity: [Record], epoch: [Record], account: String, readable: Bool, now: Date, calendar input: Calendar) -> JSON {
        guard readable, PulseProject.validID(account) else { return .null }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = input.timeZone
        var seen = Set<String>()
        let uniqueTasks = tasks.filter { seen.insert($0.id.lowercased()).inserted }
        let groups = Dictionary(grouping: uniqueTasks, by: { $0.string("project_id").lowercased() })
        var events: [String: [Record]] = [:], malformed = false; seen = []
        for row in activity {
            guard let event = TaskActivity(row: row) else { malformed = true; continue }
            guard seen.insert(event.id).inserted, event.recordedAt <= now else { continue }
            let ids = Set([event.before["project_id"]?.text.lowercased() ?? "", event.after["project_id"]?.text.lowercased() ?? ""]).subtracting([""])
            for id in ids { events[id, default: []].append(row) }
        }
        seen = []
        let all = projects.filter { PulseProject.validID($0.id) && seen.insert($0.id.lowercased()).inserted }.sorted { $0.id < $1.id }
        let recorded = epoch.first { $0.id == "current" }.flatMap { TaskPlanning.instant($0.string("recorded_from")) }?.timeIntervalSince1970
        let cards = all.prefix(2048).map { project -> PulseProject in
            let id = project.id.lowercased(), rows = groups[id] ?? []
            var days: [String: PulseDay] = [:]
            for offset in 0..<8 {
                let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
                let key = ProjectPulseSnapshot.day(date, calendar: calendar), soon = ProjectPulseSnapshot.day(calendar.date(byAdding: .day, value: 6, to: date)!, calendar: calendar)
                let reading = ProjectPulseReading(project: id, tasks: rows, activity: events[id] ?? [], now: offset == 0 ? now : date, calendar: calendar)
                let attention = rows.filter {
                    guard !$0.completed else { return false }
                    let deadline = $0.string("deadline_date"), planned = TaskPlanner.plannedDay($0, calendar: calendar)
                    return (!deadline.isEmpty && Dates.parse(deadline) != nil && deadline <= soon) || (!planned.isEmpty && Dates.parse(planned) != nil && planned < key)
                }.sorted {
                    let a = $0.string("deadline_date"), b = $1.string("deadline_date")
                    if a != b { return (a.isEmpty ? "9999" : a) < (b.isEmpty ? "9999" : b) }
                    return $0.priority == $1.priority ? $0.id < $1.id : $0.priority < $1.priority
                }
                days[key] = PulseDay(completions: reading.completions, reopens: reading.reopens, additions: reading.additions, movedIn: reading.movedIn, movedOut: reading.movedOut, attentionCount: attention.count, attention: attention.prefix(3).map { PulseAttention(id: $0.id, title: PinnedNotes.excerpt($0.title, characters: 120, bytes: 800).0) })
            }
            return PulseProject(account: account, recordID: id, name: PinnedNotes.excerpt(project.name, characters: 160, bytes: 1000).0, total: rows.count, completed: rows.filter(\.completed).count, days: days)
        }
        let snapshot = ProjectPulseSnapshot(account: account, timeZone: calendar.timeZone.identifier, history: malformed ? "incomplete" : recorded == nil ? "unavailable" : "ready", recordedFrom: recorded, projects: cards, omitted: max(0, all.count - cards.count))
        guard snapshot.valid(for: account) else { return .null }
        return (try? JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(snapshot))) ?? .null
    }
}
#endif
