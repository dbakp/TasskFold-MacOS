import Foundation
import Observation

struct TeamProjectCommand: ReviewedTeamCommand, CustomStringConvertible, CustomDebugStringConvertible {
    enum Action: String, Codable, CaseIterable, Sendable {
        case create, settings, rename, archive, unarchive, setAccess = "set_access", resetAccess = "reset_access"
        var title: String { switch self { case .rename: "Rename project"; case .archive: "Archive project"; case .unarchive: "Reopen project"; case .create: "New project"; case .settings: "Project settings"; case .setAccess: "Project access"; case .resetAccess: "Reset to team permissions" } }
        var success: String { switch self { case .create: "Project created"; case .settings: "Project settings saved"; case .rename: "Project renamed"; case .archive: "Project archived"; case .unarchive: "Project reopened"; case .setAccess, .resetAccess: "Project access updated" } }
        var structural: Bool { self == .archive || self == .unarchive }
    }
    static let storagePrefix = "team-project-command-v1."
    static var invalid: AppFailure { AppFailure(message: "Review this project change again before sending it.") }
    let account: String
    let origin: String
    let action: Action
    let body: [String: JSON]
    var description: String { "Private project administration request" }
    var debugDescription: String { description }
    var id: String { body["request_id"]!.text }
    var team: String { body["team_id"]!.text }
    var project: String { body["project_id"]!.text }
    var issued: Date { try! TeamOrganizationValue.date(body["issued_at"]) }
    var expires: Date { issued.addingTimeInterval(900) }
    var canRetry: Bool { retryable(at: Date()) }
    func retryable(at now: Date) -> Bool { issued <= now.addingTimeInterval(60) && expires >= now }
    init(account: String, origin: String, action: Action, team: String, project: String, teamRevision: Double, revision: Double? = nil, name: String? = nil, visibility: TeamProjectVisibility? = nil, folder: String? = nil, user: String? = nil, role: TeamProjectRole? = nil, review: TeamProjectStructureReview? = nil, requestID: UUID = UUID(), issuedAt: Date = Date()) throws {
        guard folder == nil || visibility != nil else { throw Self.invalid }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var body: [String: JSON] = ["team_id": .string(team), "project_id": .string(project), "team_revision": .number(teamRevision), "request_id": .string(requestID.uuidString.lowercased()), "issued_at": .string(formatter.string(from: issuedAt))]
        if let revision { body["revision"] = .number(revision) }
        if let name { body["name"] = .string(name.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let visibility { body["visibility"] = .string(visibility.rawValue); body["folder_id"] = folder.map(JSON.string) ?? .null }
        if let user { body["user_id"] = .string(user) }
        if let role { body["role"] = .string(role.rawValue) }
        if let review {
            guard action.structural, review.account == account, review.origin == origin, review.team == team, review.project == project, review.action == action, review.teamRevision == teamRevision, review.revision == revision else { throw Self.invalid }
            body["tree_token"] = .string(review.token); body["affected_count"] = .number(Double(review.count))
        }
        try self.init(account: account, origin: origin, action: action, body: body)
    }
    init(account: String, origin: String, action: Action, body: [String: JSON]) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        var keys: Set<String> = ["team_id", "project_id", "team_revision", "request_id", "issued_at"]
        if action != .create { keys.insert("revision"); let r = try TeamProjectValue.revision(body["revision"]); guard r < 9_007_199_254_740_991 else { throw Self.invalid } }
        if action == .create || action == .rename { keys.insert("name"); _ = try TeamOrganizationValue.name(body["name"]) }
        if action == .create || action == .settings {
            keys.formUnion(["visibility", "folder_id"])
            guard let value = body["visibility"]?.text, TeamProjectVisibility(rawValue: value) != nil else { throw Self.invalid }
            _ = try TeamProjectValue.optionalID(body["folder_id"])
        } else if action == .setAccess || action == .resetAccess { keys.insert("user_id"); _ = try TeamOrganizationValue.id(body["user_id"]) }
        if action.structural {
            keys.formUnion(["tree_token", "affected_count"])
            guard case .string(let token)? = body["tree_token"], TeamProjectStructureReview.validToken(token), case .number(let count)? = body["affected_count"], count >= 1, count <= 1000, count.rounded(.down) == count else { throw Self.invalid }
        }
        if action == .setAccess { keys.insert("role"); guard let value = body["role"]?.text, TeamProjectRole(rawValue: value) != nil else { throw Self.invalid } }
        guard Set(body.keys) == keys, try JSONEncoder().encode(body).count <= 16_384,
              let text = body["issued_at"]?.text, text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$"#, options: .regularExpression) != nil else { throw Self.invalid }
        _ = try TeamOrganizationValue.date(body["issued_at"])
        _ = try TeamProjectValue.revision(body["team_revision"])
        for key in ["team_id", "project_id", "request_id"] { _ = try TeamOrganizationValue.id(body[key]) }
        self.account = account; self.origin = origin; self.action = action; self.body = body
    }
    private enum CodingKeys: String, CodingKey { case account, origin, action, body }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), action: c.decode(Action.self, forKey: .action), body: c.decode([String: JSON].self, forKey: .body))
    }
    func confirmed(_ raw: [String: JSON]) throws -> TeamProjectCommandReceipt {
        guard raw["protocol"] == .number(1), raw["account"] == .string(account), raw["team_id"] == body["team_id"], raw["id"] == body["project_id"], raw["request_id"] == body["request_id"], raw["team_revision"] == body["team_revision"] else { throw Self.invalid }
        let expected = action == .create ? 1 : try TeamProjectValue.revision(body["revision"]) + 1
        guard try TeamProjectValue.revision(raw["revision"]) == expected else { throw Self.invalid }
        if action.structural {
            guard let state = try TeamProjectArchiveState.read(raw), state.own == (action == .archive), !state.inherited || action == .archive, raw["affected_count"] == body["affected_count"] else { throw Self.invalid }
        }
        return TeamProjectCommandReceipt(raw: raw)
    }
}
/// Server-reviewed branch identity; no private child names or task data.
struct TeamProjectStructureReview: Equatable, Sendable {
    let account: String, origin: String, team: String, project: String
    let action: TeamProjectCommand.Action
    let revision: Double, teamRevision: Double
    let token: String
    let count: Int
    let archive: TeamProjectArchiveState
    static func validToken(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    init(_ raw: [String: JSON], account: String, origin: String, team: String, project: String, action: TeamProjectCommand.Action) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard action.structural, TeamProjectValue.id(team), TeamProjectValue.id(project), raw["protocol"] == .number(1), raw["account"] == .string(account), raw["team_id"] == .string(team), raw["id"] == .string(project), raw["operation"] == .string(action.rawValue),
              case .string(let token)? = raw["tree_token"], Self.validToken(token), case .number(let count)? = raw["affected_count"], count >= 1, count <= 1000, count.rounded(.down) == count,
              let archive = try TeamProjectArchiveState.read(raw), archive.own != (action == .archive), action != .unarchive || !archive.inherited else { throw TeamProjectCommand.invalid }
        self.account = account; self.origin = origin; self.team = team; self.project = project; self.action = action
        self.token = token; self.count = Int(count); self.archive = archive
        revision = try TeamProjectValue.revision(raw["revision"]); teamRevision = try TeamProjectValue.revision(raw["team_revision"])
    }
}
struct TeamProjectCommandReceipt: Equatable, Sendable { let raw: [String: JSON]; var project: String { raw["id"]!.text } }
typealias TeamProjectCommandVault = ReviewedTeamCommandVault<TeamProjectCommand>

struct TeamProjectManagementDetail: Sendable {
    let access: TeamProjectAccess
    let members: [TeamOrganizationDetail.Member]
    let grants: [String: TeamProjectRole]
    init(_ raw: [String: JSON], account: String, origin: String, team: String, project: String) throws {
        access = try TeamProjectAccess(detail: raw, account: account, origin: origin, team: team, project: project)
        if access.canManageAccess {
            members = try TeamOrganizationValue.rows(raw["eligible_members"], limit: 500).map { row in
                guard let value = row["role"]?.text, let role = TeamOrganizationRole(rawValue: value), row["verified_email"] == nil else { throw TeamProjectValue.invalid }
                return try TeamOrganizationDetail.Member(id: TeamOrganizationValue.id(row["user_id"]), role: role, displayName: TeamOrganizationDetail.Member.identity(row["display_name"]))
            }
            try TeamOrganizationValue.unique(members, by: \.id)
            guard members.contains(where: { $0.id == account }) else { throw TeamProjectValue.invalid }
            var values: [String: TeamProjectRole] = [:]
            for row in try TeamOrganizationValue.rows(raw["grants"], limit: 500) {
                let id = try TeamOrganizationValue.id(row["user_id"])
                guard values[id] == nil, let role = TeamProjectRole(rawValue: row["role"]?.text ?? "") else { throw TeamProjectValue.invalid }
                values[id] = role
            }
            grants = values
        } else {
            guard raw["eligible_members"] == nil, raw["grants"] == nil else { throw TeamProjectValue.invalid }
            members = []; grants = [:]
        }
    }
    func effective(_ member: TeamOrganizationDetail.Member) -> TeamProjectRole? {
        if member.role.directoryVisible { return .manager }
        return grants[member.id] ?? (member.role == .member && access.visibility == .team ? .editor : nil)
    }
    var editable: Bool { access.canManageAccess && access.state == .active && !access.setupPaused }
    func canReset(_ member: TeamOrganizationDetail.Member) -> Bool {
        guard access.canManageAccess, members.contains(member), !member.role.directoryVisible, let role = grants[member.id] else { return false }
        return editable || access.visibility == .private || member.role == .guest || role == .manager
    }
    func roles(for member: TeamOrganizationDetail.Member) -> [TeamProjectRole] {
        guard editable, members.contains(member), !member.role.directoryVisible else { return [] }
        return member.role == .guest ? [.editor, .viewer] : [.manager, .editor, .viewer]
    }
    func resetDescription(_ member: TeamOrganizationDetail.Member) -> String {
        member.role == .member && access.visibility == .team ? "Their team membership will give them Editor access." : "They will lose access to this project."
    }
}

@MainActor protocol TeamProjectCommandService: AnyObject {
    func teamProjectCommand(_ command: TeamProjectCommand) async throws -> TeamProjectCommandReceipt
}
extension Backend: TeamProjectCommandService {}

/// No partial page/directory publication, no cached recipient names, and no
/// account or access transition accepted while paginated reads are in flight.
@MainActor @Observable final class TeamProjectBrowser {
    private(set) var team: TeamOrganizationDetail?
    private(set) var projects: [TeamProjectAccess] = []
    private(set) var detail: TeamProjectManagementDetail?
    private(set) var loading = false
    private(set) var setupPaused = true
    private(set) var message: String?
    private var attempt = UUID()
    private let account: String, origin: String, teamID: String
    @ObservationIgnored private let current: () -> Bool
    @ObservationIgnored private let fence: () async throws -> String
    @ObservationIgnored private let readTeam: () async throws -> TeamOrganizationDetail
    @ObservationIgnored private let page: (String?) async throws -> TeamProjectPage
    @ObservationIgnored private let readDetail: (String) async throws -> TeamProjectManagementDetail
    init(account: String, origin: String, team: String, current: @escaping () -> Bool, fence: @escaping () async throws -> String, readTeam: @escaping () async throws -> TeamOrganizationDetail, page: @escaping (String?) async throws -> TeamProjectPage, detail: @escaping (String) async throws -> TeamProjectManagementDetail) {
        self.account = account; self.origin = origin; teamID = team; self.current = current; self.fence = fence; self.readTeam = readTeam; self.page = page; readDetail = detail
    }
    func invalidate() { attempt = UUID(); team = nil; projects = []; detail = nil; loading = false; setupPaused = true; message = nil }
    func refresh(project: String? = nil) async {
        invalidate(); guard current() else { return }; let id = attempt; loading = true
        func check() throws { guard id == attempt, current() else { throw CancellationError() } }
        do {
            let before = try await fence(); try check()
            guard before.count == 64, before.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw TeamProjectValue.invalid }
            let team = try await readTeam(); try check()
            guard team.account == account, team.origin == origin, team.team.id == teamID else { throw TeamProjectValue.invalid }
            var rows: [TeamProjectAccess] = [], selected: TeamProjectManagementDetail?
            var paused: Bool?
            if let project {
                selected = try await readDetail(project); try check()
                guard let selected, selected.access.belongs(to: account, origin: origin, team: teamID), selected.access.id == project, selected.access.teamRevision == team.team.revision, selected.access.state.rawValue == (team.team.archived ? "archived" : "active") else { throw TeamProjectValue.invalid }
            } else {
                var cursor: String? = nil
                repeat {
                    let result = try await page(cursor); try check()
                    guard result.account == account, result.origin == origin, result.team == teamID, result.teamRevision == team.team.revision, result.state.rawValue == (team.team.archived ? "archived" : "active"), rows.count + result.projects.count <= 1000 else { throw TeamProjectValue.invalid }
                    guard paused == nil || paused == result.setupPaused else { throw TeamProjectValue.invalid }; paused = result.setupPaused
                    rows += result.projects; cursor = result.next
                    guard rows.count < 1000 || cursor == nil else { throw TeamProjectValue.invalid }
                } while cursor != nil
                try TeamOrganizationValue.unique(rows, by: \.id)
                guard rows.map(\.id) == rows.map(\.id).sorted() else { throw TeamProjectValue.invalid }
            }
            let after = try await fence(); try check(); guard before == after else { throw TeamWorkspaceChanged() }
            self.team = team; projects = rows; detail = selected; setupPaused = selected?.access.setupPaused ?? paused ?? true
        } catch {
            guard id == attempt, current() else { return }
            message = error is AccountSessionAuthorizationRequired ? "Sign in again to view this team’s projects." : error is TeamProjectAccessUnavailable ? "This project is no longer available to your account." : "Project details couldn’t be refreshed. Try again when you’re connected."
        }
        if id == attempt { loading = false }
    }
}

@MainActor @Observable final class TeamProjectCommandModel {
    private(set) var pending: TeamProjectCommand?
    private(set) var busy = false
    private(set) var message: String?
    private(set) var success: String?
    private(set) var receipt: TeamProjectCommandReceipt?
    private(set) var appliedAction: TeamProjectCommand.Action?
    private var closed = false
    let account: String
    let origin: String
    @ObservationIgnored private let vault: TeamProjectCommandVault
    @ObservationIgnored private let service: any TeamProjectCommandService
    @ObservationIgnored private let isCurrent: () -> Bool
    @ObservationIgnored private let lease = CalendarReadLease()
    init(account: String, origin: String, vault: TeamProjectCommandVault, service: any TeamProjectCommandService, isCurrent: @escaping () -> Bool) {
        self.account = account; self.origin = origin; self.vault = vault; self.service = service; self.isCurrent = isCurrent
    }
    var current: Bool { !closed && isCurrent() }
    func close() { closed = true; lease.cancel(); pending = nil; message = nil; success = nil; receipt = nil; appliedAction = nil }
    private func check() throws { try lease.check(); guard current else { throw CancellationError() } }
    private func recover() async throws { let saved = try await vault.pending(account: account, origin: origin); try check(); pending = saved }
    func load() async { await perform { try await self.recover() } }
    func send(_ command: TeamProjectCommand, now: Date = Date()) async {
        await perform {
            try await self.recover()
            guard command.account == self.account, command.origin == self.origin, command.retryable(at: now), self.pending == nil else { throw TeamProjectCommand.invalid }
            try await self.vault.begin(command, lease: self.lease); try self.check(); self.pending = command
            try await self.finish(now: now)
        }
    }
    func retry(now: Date = Date()) async {
        guard let reviewed = pending else { return }
        await perform {
            try await self.recover()
            guard self.pending == reviewed else { throw TeamOrganizationCommandFailure(code: "review_changed") }
            try await self.finish(now: now)
        }
    }
    func clearReviewedRequest(_ reviewed: TeamProjectCommand) async {
        await perform {
            try await self.recover(); guard self.pending == reviewed else { throw TeamProjectCommand.invalid }
            try await self.vault.clear(reviewed, lease: self.lease); try self.check(); try await self.recover()
        }
    }
    private func finish(now: Date) async throws {
        guard let command = pending else { throw TeamProjectCommand.invalid }
        guard command.retryable(at: now) else { throw TeamOrganizationCommandFailure(code: "expired") }
        try check(); let result = try await service.teamProjectCommand(command); try check()
        guard try command.confirmed(result.raw) == result else { throw TeamProjectCommand.invalid }
        try await vault.clear(command, lease: lease); try check()
        pending = nil; appliedAction = command.action; receipt = result; success = command.action.success
        try await recover()
    }
    private func perform(_ action: () async throws -> Void) async {
        guard current, !busy else { return }
        busy = true; message = nil; success = nil; receipt = nil; appliedAction = nil
        defer { busy = false }
        do { try check(); try await action(); try check() }
        catch {
            guard current else { return }
            if receipt != nil { message = "The change was confirmed. Refresh project details before making another change." }
            else if let error = error as? TeamOrganizationCommandFailure { message = error.localizedDescription }
            else if error is AccountSessionAuthorizationRequired { message = "Sign in again before retrying your saved project request." }
            else if pending != nil { message = "This request couldn’t be confirmed. Check the latest project details before trying again; the request won’t be replaced automatically." }
            else { message = "The project request couldn’t be opened or prepared. Try again." }
        }
    }
}
