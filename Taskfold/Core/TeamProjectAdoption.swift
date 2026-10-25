import Foundation
import Observation

enum TeamProjectAdoptionValue {
    static var invalid: AppFailure { AppFailure(message: "Refresh and review this project transfer again.") }
    static func count(_ value: JSON?, limit: Int = 2_147_483_647) throws -> Int {
        guard case .number(let n)? = value, n.isFinite, n >= 0, n <= Double(limit), n.rounded(.down) == n else { throw invalid }; return Int(n)
    }
    static func ids(_ value: JSON?, limit: Int) throws -> [String] {
        guard case .array(let values)? = value, !values.isEmpty, values.count <= limit else { throw invalid }
        let ids = try values.map { try TeamOrganizationValue.id($0) }
        guard Set(ids).count == ids.count, ids == ids.sorted() else { throw invalid }; return ids
    }
    static func date(_ value: JSON?) throws -> Date {
        guard case .string(let s)? = value, s.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$"#, options: .regularExpression) != nil else { throw invalid }
        return try TeamOrganizationValue.date(value)
    }
}
struct TeamProjectAdoptionScope: Equatable, Sendable {
    let account: String, origin: String, team: String
    let roots: [String], visibility: TeamProjectVisibility, folder: String?, parent: String?
    init(account: String, origin: String, team: String, roots: [String], visibility: TeamProjectVisibility, folder: String? = nil, parent: String? = nil) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard TeamProjectValue.id(team), !roots.isEmpty, roots.count <= 100, Set(roots).count == roots.count, roots.allSatisfy(TeamProjectValue.id),
              folder == nil || TeamProjectValue.id(folder!), parent == nil || TeamProjectValue.id(parent!), !roots.contains(parent ?? "") else { throw TeamProjectAdoptionValue.invalid }
        self.account = account; self.origin = origin; self.team = team; self.roots = roots.sorted(); self.visibility = visibility; self.folder = folder; self.parent = parent
    }
    var body: [String: JSON] { ["team_id": .string(team), "roots": .array(roots.map(JSON.string)), "visibility": .string(visibility.rawValue), "folder_id": folder.map(JSON.string) ?? .null, "parent_id": parent.map(JSON.string) ?? .null] }
}
struct TeamProjectAdoptionDecision: Equatable, Sendable, Identifiable {
    enum Choice: String, CaseIterable, Sendable { case editor, viewer, retire
        var title: String { switch self { case .editor: "Keep as editor"; case .viewer: "Keep as viewer"; case .retire: "Retire personal access" } }
        var role: JSON { self == .retire ? .null : .string(rawValue) }
    }
    let project: String, user: String, choice: Choice
    var id: String { project + ":" + user }
    var body: JSON { .object(["project_id": .string(project), "user_id": .string(user), "role": choice.role]) }
    init(project: String, user: String, choice: Choice) throws {
        guard TeamProjectValue.id(project), TeamProjectValue.id(user) else { throw TeamProjectAdoptionValue.invalid }; self.project = project; self.user = user; self.choice = choice
    }
    init(_ raw: [String: JSON]) throws {
        guard Set(raw.keys) == ["project_id", "user_id", "role"] else { throw TeamProjectAdoptionValue.invalid }
        let choice: Choice
        if raw["role"] == .null { choice = .retire }
        else if let s = raw["role"]?.text, let c = Choice(rawValue: s), c != .retire { choice = c }
        else { throw TeamProjectAdoptionValue.invalid }
        try self.init(project: TeamOrganizationValue.id(raw["project_id"]), user: TeamOrganizationValue.id(raw["user_id"]), choice: choice)
    }
}
struct TeamProjectAdoptionInspection: Equatable, Sendable, CustomStringConvertible {
    struct Project: Equatable, Sendable, Identifiable {
        let id: String, root: String, parent: String?, depth: Int, name: String?, archived: Bool, inherited: Bool
    }
    struct Collaborator: Equatable, Sendable, Identifiable {
        let id: String, project: String, user: String?, email: String?, status: String, eligible: Bool
        var decisionID: String? { guard status == "accepted", let user else { return nil }; return project + ":" + user }
    }
    let scope: TeamProjectAdoptionScope, token: String, teamName: String
    let projects: [Project], collaborators: [Collaborator], contents: [String: JSON]
    let commitSupported: Bool, destinationArchived: Bool, teamMembers: Int
    var description: String { "Private project transfer inspection" }
    var people: [Collaborator] {
        var seen: Set<String> = []
        return collaborators.filter { guard let id = $0.decisionID else { return false }; return seen.insert(id).inserted }
    }
    init(_ raw: [String: JSON], scope: TeamProjectAdoptionScope) throws {
        guard raw["project_adoption_protocol"] == .number(1), raw["account"] == .string(scope.account), scope.body.allSatisfy({ raw[$0.key] == $0.value }),
              case .string(let token)? = raw["inspection_token"], TeamTaskMoveReview.validToken(token), raw["creates_memberships"] == .bool(false), raw["sends_invitations"] == .bool(false), raw["automatic_undo"] == .bool(false),
              case .bool(let enabled)? = raw["commit_supported"], case .bool(let archived)? = raw["destination_archived"], case .object(let contents)? = raw["contents"],
              case .object(let counts)? = contents["counts"], try JSONEncoder().encode(raw).count <= 3_000_000 else { throw TeamProjectAdoptionValue.invalid }
        self.scope = scope; self.token = token; teamName = try TeamOrganizationValue.name(raw["team_name"]); commitSupported = enabled; destinationArchived = archived
        teamMembers = try TeamProjectAdoptionValue.count(raw["team_member_count"], limit: 2000)
        projects = try TeamOrganizationValue.rows(raw["projects"], limit: 1000).map { row in
            guard case .bool(let own)? = row["is_archived"], case .bool(let inherited)? = row["source_ancestor_archived"] else { throw TeamProjectAdoptionValue.invalid }
            let name = row["name"] == .null ? nil : try TeamOrganizationValue.name(row["name"])
            return try Project(id: TeamOrganizationValue.id(row["id"]), root: TeamOrganizationValue.id(row["root_id"]), parent: TeamProjectValue.optionalID(row["parent_id"]), depth: TeamProjectAdoptionValue.count(row["depth"], limit: 20), name: name, archived: own, inherited: inherited)
        }
        guard !projects.isEmpty, Set(projects.map(\.id)).count == projects.count, Set(projects.filter { $0.depth == 1 }.map(\.id)) == Set(scope.roots) else { throw TeamProjectAdoptionValue.invalid }
        let map = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        for project in projects {
            guard project.depth > 0, scope.roots.contains(project.root) else { throw TeamProjectAdoptionValue.invalid }
            if project.depth == 1 { guard project.id == project.root, project.parent == scope.parent else { throw TeamProjectAdoptionValue.invalid } }
            else { guard let parent = project.parent.flatMap({ map[$0] }), parent.root == project.root, parent.depth + 1 == project.depth else { throw TeamProjectAdoptionValue.invalid } }
        }
        collaborators = try TeamOrganizationValue.rows(raw["collaborators"], limit: 1000).map { row in
            guard let status = row["status"]?.text, ["accepted", "pending", "declined"].contains(status), case .bool(let eligible)? = row["eligible"] else { throw TeamProjectAdoptionValue.invalid }
            let user = try TeamProjectValue.optionalID(row["user_id"]), project = try TeamOrganizationValue.id(row["project_id"])
            guard map[project] != nil, user != nil || !eligible else { throw TeamProjectAdoptionValue.invalid }
            let email: String?
            if row["email"] == .null { email = nil }
            else { guard case .string(let s)? = row["email"], s.utf8.count <= 320, !s.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw TeamProjectAdoptionValue.invalid }; email = s }
            return try Collaborator(id: TeamOrganizationValue.id(row["id"]), project: project, user: user, email: email, status: status, eligible: eligible)
        }
        guard Set(collaborators.map(\.id)).count == collaborators.count else { throw TeamProjectAdoptionValue.invalid }
        let kinds: Set<String> = ["projects", "tasks", "sections", "project_collaborators", "task_comments", "task_mentions", "task_assignment_provenance", "task_activity"]
        guard Set(counts.keys) == kinds, try kinds.reduce(0, { try $0 + TeamProjectAdoptionValue.count(counts[$1], limit: 100000) }) <= 100000,
              try TeamProjectAdoptionValue.count(counts["projects"], limit: 1000) == projects.count, try TeamProjectAdoptionValue.count(counts["tasks"], limit: 10000) >= 0,
              try TeamProjectAdoptionValue.count(counts["project_collaborators"], limit: 1000) == collaborators.count else { throw TeamProjectAdoptionValue.invalid }
        _ = try TeamProjectAdoptionValue.count(contents["content_bytes"], limit: 33_554_432)
        for key in ["attachments", "inline_files", "external_files", "provider_files", "email_routes", "webhooks"] { _ = try TeamProjectAdoptionValue.count(contents[key]) }
        var eligibility: [String: Bool] = [:]
        for person in collaborators { if let id = person.decisionID { guard eligibility[id] == nil || eligibility[id] == person.eligible else { throw TeamProjectAdoptionValue.invalid }; eligibility[id] = person.eligible } }
        self.contents = contents
    }
    func inheritsArchiveAfter(_ project: Project) -> Bool {
        if destinationArchived { return true }
        let map = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        var parent = project.parent
        while let id = parent, let ancestor = map[id] {
            if ancestor.archived { return true }; parent = ancestor.parent
        }
        return false
    }
    func reviewBody(_ decisions: [TeamProjectAdoptionDecision]) throws -> [String: JSON] {
        guard decisions.count == people.count, Set(decisions.map(\.id)) == Set(people.compactMap(\.decisionID)), decisions.allSatisfy({ d in d.choice == .retire || people.first(where: { $0.decisionID == d.id })?.eligible == true }) else { throw TeamProjectAdoptionValue.invalid }
        return scope.body.merging(["inspection_token": .string(token), "decisions": .array(decisions.sorted { $0.id < $1.id }.map(\.body))]) { _, b in b }
    }
}
struct TeamProjectAdoptionReview: Equatable, Sendable, CustomStringConvertible {
    let inspection: TeamProjectAdoptionInspection, decisions: [TeamProjectAdoptionDecision], effectiveRoles: [String: TeamProjectRole]
    let token: String, expiresText: String, expires: Date, assignmentsCleared: Int, invitationsClosed: Int
    let needsFileCustody: Bool, needsIntegrationPause: Bool
    var description: String { "Private project transfer review" }
    var canCommit: Bool { inspection.commitSupported && !needsFileCustody && !needsIntegrationPause }
    init(_ raw: [String: JSON], inspection: TeamProjectAdoptionInspection, decisions: [TeamProjectAdoptionDecision]) throws {
        _ = try inspection.reviewBody(decisions)
        guard try TeamProjectAdoptionInspection(raw, scope: inspection.scope) == inspection,
              case .string(let token)? = raw["review_token"], TeamTaskMoveReview.validToken(token), case .string(let expiresText)? = raw["expires_at"],
              case .bool(let files)? = raw["requires_provider_custody"], case .bool(let integrations)? = raw["requires_integration_pause"] else { throw TeamProjectAdoptionValue.invalid }
        let rows = try TeamOrganizationValue.rows(raw["decisions"], limit: 1000)
        var roles: [String: TeamProjectRole] = [:], parsed: [TeamProjectAdoptionDecision] = []
        for row in rows {
            guard Set(row.keys) == ["project_id", "user_id", "role", "effective_role"] else { throw TeamProjectAdoptionValue.invalid }
            let d = try TeamProjectAdoptionDecision(row.filter { $0.key != "effective_role" }); parsed.append(d)
            if row["effective_role"] != .null { guard let text = row["effective_role"]?.text, let role = TeamProjectRole(rawValue: text) else { throw TeamProjectAdoptionValue.invalid }; roles[d.id] = role }
        }
        guard parsed.count == decisions.count, Set(parsed.map(\.id)).count == parsed.count, parsed.sorted(by: { $0.id < $1.id }) == decisions.sorted(by: { $0.id < $1.id }),
              files == ((inspection.contents["provider_files"]?.integer ?? -1) > 0), integrations == ((inspection.contents["email_routes"]?.integer ?? -1) > 0 || (inspection.contents["webhooks"]?.integer ?? -1) > 0) else { throw TeamProjectAdoptionValue.invalid }
        self.inspection = inspection; self.decisions = parsed; effectiveRoles = roles; self.token = token; self.expiresText = expiresText; expires = try TeamProjectAdoptionValue.date(raw["expires_at"])
        assignmentsCleared = try TeamProjectAdoptionValue.count(raw["assignments_cleared"], limit: 1_000_010_000)
        invitationsClosed = try TeamProjectAdoptionValue.count(raw["invitations_closed"], limit: 1000)
        guard invitationsClosed == inspection.collaborators.count else { throw TeamProjectAdoptionValue.invalid }
        needsFileCustody = files; needsIntegrationPause = integrations
    }
}
struct TeamProjectAdoptionCommand: ReviewedTeamCommand, CustomStringConvertible, CustomDebugStringConvertible {
    static let storagePrefix = "team-project-adoption-v1."
    static let maximumStoredBytes = 300_000
    static var invalid: AppFailure { TeamProjectAdoptionValue.invalid }
    let account: String, origin: String, body: [String: JSON], projects: [String], assignmentsCleared: Int, invitationsClosed: Int
    let scope: TeamProjectAdoptionScope
    var id: String { body["request_id"]!.text }
    var description: String { "Private project transfer request" }; var debugDescription: String { description }
    init(review: TeamProjectAdoptionReview, requestID: UUID = UUID(), now: Date = Date()) throws {
        guard review.canCommit, review.expires > now, review.expires <= now.addingTimeInterval(16 * 60) else { throw Self.invalid }
        let i = review.inspection
        var b = try i.reviewBody(review.decisions); b["review_token"] = .string(review.token); b["expires_at"] = .string(review.expiresText); b["request_id"] = .string(requestID.uuidString.lowercased())
        try self.init(account: i.scope.account, origin: i.scope.origin, body: b, projects: i.projects.map(\.id).sorted(), assignmentsCleared: review.assignmentsCleared, invitationsClosed: review.invitationsClosed)
    }
    init(account: String, origin: String, body: [String: JSON], projects: [String], assignmentsCleared: Int, invitationsClosed: Int) throws {
        guard Set(body.keys) == ["team_id", "roots", "visibility", "folder_id", "parent_id", "inspection_token", "decisions", "review_token", "expires_at", "request_id"], let v = body["visibility"]?.text, let visibility = TeamProjectVisibility(rawValue: v), try JSONEncoder().encode(body).count <= 262144 else { throw Self.invalid }
        let roots = try TeamProjectAdoptionValue.ids(body["roots"], limit: 100)
        scope = try TeamProjectAdoptionScope(account: account, origin: origin, team: TeamOrganizationValue.id(body["team_id"]), roots: roots, visibility: visibility, folder: TeamProjectValue.optionalID(body["folder_id"]), parent: TeamProjectValue.optionalID(body["parent_id"]))
        guard try TeamProjectAdoptionValue.ids(.array(projects.map(JSON.string)), limit: 1000) == projects, Set(roots).isSubset(of: Set(projects)), !projects.contains(scope.parent ?? ""), assignmentsCleared >= 0, assignmentsCleared <= 1_000_010_000, (0...1000).contains(invitationsClosed) else { throw Self.invalid }
        _ = try TeamOrganizationValue.id(body["request_id"]); _ = try TeamProjectAdoptionValue.date(body["expires_at"])
        for k in ["inspection_token", "review_token"] { guard let t = body[k]?.text, TeamTaskMoveReview.validToken(t) else { throw Self.invalid } }
        let choices = try TeamOrganizationValue.rows(body["decisions"], limit: 1000).map(TeamProjectAdoptionDecision.init)
        guard choices.count <= invitationsClosed, Set(choices.map(\.id)).count == choices.count, choices.allSatisfy({ projects.contains($0.project) }), choices.map(\.id) == choices.map(\.id).sorted() else { throw Self.invalid }
        self.account = account; self.origin = origin; self.body = body; self.projects = projects; self.assignmentsCleared = assignmentsCleared; self.invitationsClosed = invitationsClosed
    }
    private enum CodingKeys: String, CodingKey { case account, origin, body, projects, assignmentsCleared, invitationsClosed }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), body: c.decode([String: JSON].self, forKey: .body), projects: c.decode([String].self, forKey: .projects), assignmentsCleared: c.decode(Int.self, forKey: .assignmentsCleared), invitationsClosed: c.decode(Int.self, forKey: .invitationsClosed))
    }
    func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(account, forKey: .account); try c.encode(origin, forKey: .origin); try c.encode(body, forKey: .body); try c.encode(projects, forKey: .projects); try c.encode(assignmentsCleared, forKey: .assignmentsCleared); try c.encode(invitationsClosed, forKey: .invitationsClosed) }
    func confirmed(_ raw: [String: JSON]) throws -> TeamProjectAdoptionReceipt {
        guard raw["project_adoption_protocol"] == .number(1), raw["account"] == .string(account), raw["request_id"] == body["request_id"], raw["applied"] == .bool(true), raw["automatic_undo"] == .bool(false), case .bool(let replayed)? = raw["replayed"], scope.body.allSatisfy({ raw[$0.key] == $0.value }), try TeamProjectAdoptionValue.ids(raw["project_ids"], limit: 1000) == projects, try TeamProjectAdoptionValue.count(raw["assignments_cleared"]) == assignmentsCleared, try TeamProjectAdoptionValue.count(raw["invitations_closed"]) == invitationsClosed else { throw Self.invalid }
        return TeamProjectAdoptionReceipt(command: self, replayed: replayed)
    }
}
struct TeamProjectAdoptionReceipt: Equatable, Sendable { let command: TeamProjectAdoptionCommand, replayed: Bool }
typealias TeamProjectAdoptionVault = ReviewedTeamCommandVault<TeamProjectAdoptionCommand>
@MainActor protocol TeamProjectAdoptionService: AnyObject {
    func inspectProjectAdoption(_ scope: TeamProjectAdoptionScope) async throws -> TeamProjectAdoptionInspection
    func reviewProjectAdoption(_ inspection: TeamProjectAdoptionInspection, decisions: [TeamProjectAdoptionDecision]) async throws -> TeamProjectAdoptionReview
    func adoptProjects(_ command: TeamProjectAdoptionCommand) async throws -> TeamProjectAdoptionReceipt
}
extension Backend: TeamProjectAdoptionService {}
@MainActor @Observable final class TeamProjectAdoptionModel {
    private(set) var pending: TeamProjectAdoptionCommand?
    private(set) var receipt: TeamProjectAdoptionReceipt?
    private(set) var message: String?
    private(set) var busy = false
    private(set) var recoveryLoaded = false
    let account: String, origin: String
    @ObservationIgnored private let vault: TeamProjectAdoptionVault
    @ObservationIgnored private let service: any TeamProjectAdoptionService
    @ObservationIgnored private let current: () -> Bool
    @ObservationIgnored private let lease = CalendarReadLease()
    private var closed = false
    init(account: String, origin: String, vault: TeamProjectAdoptionVault, service: any TeamProjectAdoptionService, current: @escaping () -> Bool) { self.account = account; self.origin = origin; self.vault = vault; self.service = service; self.current = current }
    func close() { closed = true; lease.cancel(); pending = nil; receipt = nil; message = nil; recoveryLoaded = false }
    private func check() throws { try lease.check(); guard !closed, current() else { throw CancellationError() } }
    private func recover() async throws { recoveryLoaded = false; let value = try await vault.pending(account: account, origin: origin); try check(); pending = value; recoveryLoaded = true }
    func load() async { await perform { try await self.recover() } }
    func send(_ command: TeamProjectAdoptionCommand, canAuthor: @escaping () -> Bool, now: Date = Date()) async {
        await perform {
            try await self.recover()
            let expiry = try TeamProjectAdoptionValue.date(command.body["expires_at"])
            guard self.pending == nil, command.account == self.account, command.origin == self.origin, canAuthor(), expiry > now, expiry <= now.addingTimeInterval(16 * 60) else { throw TeamProjectAdoptionValue.invalid }
            try await self.vault.begin(command, lease: self.lease); try self.check(); self.pending = command
            guard canAuthor() else { throw TeamProjectAdoptionValue.invalid }; try await self.finish(command)
        }
    }
    func retry() async {
        guard let old = pending else { return }
        await perform { try await self.recover(); guard self.pending == old else { throw CancellationError() }; try await self.finish(old) }
    }
    func clear(_ reviewed: TeamProjectAdoptionCommand) async {
        await perform { try await self.recover(); guard self.pending == reviewed else { throw CancellationError() }; try await self.vault.clear(reviewed, lease: self.lease); try self.check(); try await self.recover() }
    }
    private func finish(_ command: TeamProjectAdoptionCommand) async throws {
        try check(); let value = try await service.adoptProjects(command); try check()
        guard value.command == command else { throw TeamProjectAdoptionValue.invalid }
        try await vault.clear(command, lease: lease); try check(); receipt = value; try await recover()
    }
    private func perform(_ action: () async throws -> Void) async {
        guard !closed, current(), !busy else { return }; busy = true; message = nil; receipt = nil; defer { busy = false }
        do { try check(); try await action(); try check() }
        catch { guard !closed, current() else { return }; message = pending == nil ? "The transfer couldn’t be prepared. Refresh and review it again." : "The result couldn’t be confirmed. Your exact transfer is saved. Retry it or check the latest projects before clearing it. Clearing does not undo a transfer." }
    }
}
