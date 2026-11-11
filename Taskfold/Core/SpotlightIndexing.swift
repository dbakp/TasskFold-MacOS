import Foundation

/// Pure Spotlight logic shared by both apps: which records are searchable, what their
/// searchable fields are, what changed since the last index, how changes are batched and
/// debounced, and how a selected result routes back into the app. The app layer
/// (`SpotlightIndexer`) turns these values into Core Spotlight items; nothing here touches
/// the system index, the Store or the network.
enum SpotlightKind: String, Sendable, CaseIterable {
    case task, project
    var domain: String { "com.dbakp.taskfold.spotlight." + rawValue }
}

/// Identifiers are `task:<id>` / `project:<id>`, so Spotlight, Siri and the app agree on one key.
enum SpotlightIdentifier {
    static func make(_ kind: SpotlightKind, _ id: String) -> String { kind.rawValue + ":" + id }
    static func parse(_ identifier: String) -> (kind: SpotlightKind, id: String)? {
        guard let split = identifier.firstIndex(of: ":"),
              let kind = SpotlightKind(rawValue: String(identifier[..<split])) else { return nil }
        let id = String(identifier[identifier.index(after: split)...])
        return id.isEmpty ? nil : (kind, id)
    }
}

struct SpotlightDocument: Equatable, Sendable {
    var kind: SpotlightKind
    var recordID: String
    var title: String
    /// First 200 characters of the task description (never the whole note).
    var textContent: String
    /// "Project name · Due Thu, Nov 12".
    var contentDescription: String
    /// Label names; Spotlight matches them like tags.
    var keywords: [String]
    var dueDate: Date?
    var projectName: String?
    var identifier: String { SpotlightIdentifier.make(kind, recordID) }
    var domain: String { kind.domain }
    /// A stable digest of everything the index stores. Not `hashValue`, which changes per launch.
    var fingerprint: String {
        let parts = [kind.rawValue, recordID, title, textContent, contentDescription, keywords.joined(separator: "\u{1F}"),
                     dueDate.map { String(Int64($0.timeIntervalSince1970)) } ?? ""]
        return SpotlightDigest.hex(parts.joined(separator: "\u{1E}"))
    }
}

enum SpotlightDigest {
    /// FNV-1a, 64 bit. Deterministic across launches and platforms.
    static func hex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
        return String(hash, radix: 16)
    }
}

enum SpotlightMapper {
    static let descriptionLimit = 200

    /// Open, ordinary tasks and the projects containing them. Completed work, headings and
    /// untitled rows are never indexed. Callers pass the already archive-filtered workspace.
    static func documents(tasks: [Record], projects: [Record], labels: [Record],
                          calendar: Calendar = .current, locale: Locale = .current) -> [SpotlightDocument] {
        let projectNames = Dictionary(projects.filter { !$0.id.isEmpty }.map { ($0.id, $0.name.trimmingCharacters(in: .whitespacesAndNewlines)) },
                                      uniquingKeysWith: { first, _ in first })
        let labelNames = Dictionary(labels.filter { !$0.id.isEmpty }.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>(), result: [SpotlightDocument] = []
        var openCounts: [String: Int] = [:]
        for task in tasks {
            guard let document = taskDocument(task, projectNames: projectNames, labelNames: labelNames, calendar: calendar, locale: locale),
                  seen.insert(document.identifier).inserted else { continue }
            let projectID = task.string("project_id")
            if !projectID.isEmpty { openCounts[projectID, default: 0] += 1 }
            result.append(document)
        }
        for project in projects {
            let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !project.id.isEmpty, !name.isEmpty, !project["is_archived"].flag,
                  seen.insert(SpotlightIdentifier.make(.project, project.id)).inserted else { continue }
            let open = openCounts[project.id, default: 0]
            result.append(SpotlightDocument(kind: .project, recordID: project.id, title: name, textContent: "",
                                            contentDescription: "Project · " + (open == 1 ? "1 open task" : "\(open) open tasks"),
                                            keywords: [], dueDate: nil, projectName: nil))
        }
        return result.sorted { $0.identifier < $1.identifier }
    }

    /// One open, ordinary, titled task; otherwise nil. Shared by the index and by `TaskEntity`.
    static func taskDocument(_ task: Record, projectNames: [String: String], labelNames: [String: String],
                             calendar: Calendar = .current, locale: Locale = .current) -> SpotlightDocument? {
        guard TaskKind.mayComplete(task), !task.completed, !task.id.isEmpty else { return nil }
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let projectID = task.string("project_id")
        let projectName = projectID.isEmpty ? nil : projectNames[projectID].flatMap { $0.isEmpty ? nil : $0 }
        var details: [String] = [projectName ?? "Inbox"]
        // Parsed in the formatting calendar, so the day printed is the day stored.
        let due = Dates.parse(task.string("due_date"), calendar: calendar)
        if let due { details.append("Due " + dueText(due, calendar: calendar, locale: locale)) }
        var keywords: [String] = []
        for value in task["labels"].list {
            let raw = value.text
            let name = (labelNames[raw] ?? raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, !keywords.contains(name) { keywords.append(name) }
        }
        return SpotlightDocument(kind: .task, recordID: task.id, title: title, textContent: excerpt(task.string("description")),
                                 contentDescription: details.joined(separator: " · "), keywords: keywords, dueDate: due, projectName: projectName)
    }

    static func excerpt(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= descriptionLimit ? trimmed : String(trimmed.prefix(descriptionLimit))
    }

    static func dueText(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.locale = locale; formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter.string(from: date)
    }
}

/// The difference between what the index holds (identifier to fingerprint) and what it should hold.
struct SpotlightIndexPlan: Equatable, Sendable {
    var upserts: [SpotlightDocument]
    var removals: [String]
    var isEmpty: Bool { upserts.isEmpty && removals.isEmpty }

    static func diff(indexed: [String: String], current: [SpotlightDocument]) -> SpotlightIndexPlan {
        let wanted = Dictionary(current.map { ($0.identifier, $0) }, uniquingKeysWith: { _, last in last })
        let upserts = wanted.values.filter { indexed[$0.identifier] != $0.fingerprint }.sorted { $0.identifier < $1.identifier }
        let removals = indexed.keys.filter { wanted[$0] == nil }.sorted()
        return SpotlightIndexPlan(upserts: upserts, removals: removals)
    }

    struct Batch: Equatable, Sendable {
        var upserts: [SpotlightDocument]
        var removals: [String]
    }
    /// Chunks the plan so one system call never carries more than `size` operations.
    /// Removals go first, so a stale hit disappears before new ones arrive.
    func batches(size: Int = 100) -> [Batch] {
        let limit = max(1, size)
        var result: [Batch] = []
        var index = 0
        while index < removals.count {
            result.append(Batch(upserts: [], removals: Array(removals[index..<min(removals.count, index + limit)]))); index += limit
        }
        index = 0
        while index < upserts.count {
            result.append(Batch(upserts: Array(upserts[index..<min(upserts.count, index + limit)]), removals: [])); index += limit
        }
        return result
    }
    /// The index as it will be once every batch has been applied.
    func applying(to indexed: [String: String]) -> [String: String] {
        var next = indexed
        for id in removals { next[id] = nil }
        for document in upserts { next[document.identifier] = document.fingerprint }
        return next
    }
}

/// What the app remembers about its own index: no titles, only fingerprints.
struct SpotlightIndexState: Codable, Equatable, Sendable {
    /// Bump when the mapped fields change so every install reindexes once.
    static let schemaVersion = 1
    var schema = SpotlightIndexState.schemaVersion
    var build = ""
    var account = ""
    var fingerprints: [String: String] = [:]

    func requiresFullReindex(schema currentSchema: Int = SpotlightIndexState.schemaVersion, build currentBuild: String, account currentAccount: String) -> Bool {
        schema != currentSchema || build != currentBuild || account != currentAccount || currentAccount.isEmpty
    }
    static func empty(build: String, account: String) -> SpotlightIndexState { SpotlightIndexState(build: build, account: account) }
}

/// Decides what this process may do with the system index.
enum SpotlightIndexPolicy {
    static let fixtureFlag = "--spotlight-index-fixture"
    static let fixtureAccounts: Set<String> = ["preview", "ui-testing"]
    enum Decision: Equatable, Sendable { case index, clear, leaveAlone }

    /// Only a signed-in person's own workspace is indexed. Signing out clears the index.
    /// Preview and UI-test fixture runs neither index nor clear (they must not touch the
    /// real index) unless a DEBUG build is asked to with `--spotlight-index-fixture`.
    static func decide(account: String, arguments: [String], signedIn: Bool, debugBuild: Bool) -> Decision {
        let fixtureRun = fixtureAccounts.contains(account) || arguments.contains("--uitesting") || arguments.contains("--preview")
        if fixtureRun { return debugBuild && arguments.contains(fixtureFlag) && signedIn && !account.isEmpty ? .index : .leaveAlone }
        return signedIn && !account.isEmpty ? .index : .clear
    }
}

/// Trailing-edge debounce with a ceiling, so a long burst of edits still reaches the index.
struct SpotlightDebouncer: Equatable, Sendable {
    var interval: TimeInterval
    var maximumDelay: TimeInterval
    private(set) var firstRequest: Date?
    private(set) var lastRequest: Date?
    init(interval: TimeInterval = 2, maximumDelay: TimeInterval = 10) { self.interval = interval; self.maximumDelay = maximumDelay }
    var isPending: Bool { firstRequest != nil }
    mutating func request(at now: Date) {
        if firstRequest == nil { firstRequest = now }
        lastRequest = now
    }
    var fireDate: Date? {
        guard let firstRequest, let lastRequest else { return nil }
        return min(lastRequest.addingTimeInterval(interval), firstRequest.addingTimeInterval(maximumDelay))
    }
    func isDue(at now: Date) -> Bool { fireDate.map { now >= $0 } ?? false }
    mutating func fired() { firstRequest = nil; lastRequest = nil }
    mutating func cancel() { fired() }
}

/// A selected search result, or the continuation activity, becomes one existing app route.
enum SpotlightRoute: Equatable, Sendable {
    case task(String), project(String)
    init?(identifier: String) {
        guard let parsed = SpotlightIdentifier.parse(identifier) else { return nil }
        self = parsed.kind == .task ? .task(parsed.id) : .project(parsed.id)
    }
    /// Reuses the widget deep links, which the app already scopes to the current account.
    func url(account: String) -> URL? {
        guard !account.isEmpty else { return nil }
        var parts = URLComponents()
        parts.scheme = "taskfold"
        switch self {
        case .task(let id): parts.host = "task"; parts.percentEncodedPath = "/" + Self.encode(id)
        case .project(let id): parts.host = "project"; parts.percentEncodedPath = "/" + Self.encode(id)
        }
        parts.queryItems = [URLQueryItem(name: "account", value: account)]
        return parts.url
    }
    private static func encode(_ id: String) -> String {
        var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "/?#%")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }
}
