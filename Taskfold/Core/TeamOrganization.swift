import Foundation
import Observation

/// Organization roles never imply permission to read or edit a project.
enum TeamOrganizationRole: String, Sendable, CaseIterable, Hashable {
    case owner, admin, member, guest
    var title: String { rawValue.capitalized }
    var directoryVisible: Bool { self == .owner || self == .admin }
}

enum TeamOrganizationValue {
    static var invalid: AppFailure { AppFailure(message: "Team details couldn’t be verified. Refresh to try again.") }
    static func id(_ value: JSON?) throws -> String {
        guard case .string(let id)? = value, TeamProjectValue.id(id) else { throw invalid }; return id
    }
    static func name(_ value: JSON?) throws -> String {
        guard case .string(let name)? = value, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.unicodeScalars.count <= 100, name.utf8.count <= 400,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw invalid }; return name
    }
    static func date(_ value: JSON?) throws -> Date {
        guard case .string(let text)? = value, text.utf8.count <= 40 else { throw invalid }
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: text) { return date }
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: text) else { throw invalid }; return date
    }
    static func rows(_ value: JSON?, limit: Int) throws -> [[String: JSON]] {
        guard case .array(let values)? = value, values.count <= limit else { throw invalid }
        return try values.map { guard case .object(let row) = $0 else { throw invalid }; return row }
    }
    static func unique<T>(_ values: [T], by key: (T) -> String) throws {
        guard Set(values.map(key)).count == values.count else { throw invalid }
    }
    static func scope(account: String, origin: String) throws {
        guard TeamProjectValue.id(account), let url = URLComponents(string: origin), url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty,
              url.string == origin else { throw invalid }
    }
}

struct TeamOrganization: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let role: TeamOrganizationRole
    let archived: Bool
    let revision: Double
    init(_ row: [String: JSON]) throws {
        id = try TeamOrganizationValue.id(row["id"]); name = try TeamOrganizationValue.name(row["name"])
        guard case .string(let raw)? = row["role"], let role = TeamOrganizationRole(rawValue: raw),
              [JSON.string("active"), .string("archived")].contains(row["state"]) else { throw TeamOrganizationValue.invalid }
        self.role = role; archived = row["state"] == .string("archived")
        revision = try TeamProjectValue.revision(row["revision"])
    }
}

struct TeamOrganizationInvitation: Equatable, Identifiable, Sendable {
    let id: String
    let team: String
    let name: String
    let role: TeamOrganizationRole
    let expires: Date
    let revision: Double
    init(_ row: [String: JSON]) throws {
        id = try TeamOrganizationValue.id(row["id"]); team = try TeamOrganizationValue.id(row["team_id"])
        name = try TeamOrganizationValue.name(row["team_name"])
        guard case .string(let raw)? = row["role"], let role = TeamOrganizationRole(rawValue: raw), role != .owner else { throw TeamOrganizationValue.invalid }
        self.role = role; expires = try TeamOrganizationValue.date(row["expires_at"])
        revision = try TeamProjectValue.revision(row["team_revision"])
    }
}

struct TeamOrganizationOverview: Equatable, Sendable {
    let account: String
    let origin: String
    let enabled: Bool
    let teams: [TeamOrganization]
    let invitations: [TeamOrganizationInvitation]
    func canAccept(_ invitation: TeamOrganizationInvitation, now: Date = Date()) -> Bool {
        enabled && invitations.contains(invitation) && invitation.expires > now && !teams.contains(where: { $0.id == invitation.team })
    }
    init(list: [String: JSON], invitations: [String: JSON], account: String, origin: String) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard case .bool(let enabled)? = list["enabled"], invitations["enabled"] == .bool(enabled) else { throw TeamOrganizationValue.invalid }
        teams = try TeamOrganizationValue.rows(list["teams"], limit: 100).map(TeamOrganization.init)
        self.invitations = try TeamOrganizationValue.rows(invitations["invitations"], limit: 100).map(TeamOrganizationInvitation.init)
        try TeamOrganizationValue.unique(teams, by: \.id); try TeamOrganizationValue.unique(self.invitations, by: \.id)
        try TeamOrganizationValue.unique(self.invitations, by: \.team)
        self.account = account; self.origin = origin; self.enabled = enabled
    }
}

struct TeamOrganizationDetail: Equatable, Sendable {
    struct Folder: Equatable, Identifiable, Sendable { let id: String; let name: String; let position: Int }
    struct Member: Equatable, Identifiable, Sendable { let id: String; let role: TeamOrganizationRole }
    struct Invitation: Equatable, Identifiable, Sendable { let id: String; let email: String; let role: TeamOrganizationRole; let expires: Date }
    struct Transfer: Equatable, Sendable { let id: String; let target: String; let expires: Date }
    let account: String
    let origin: String
    let team: TeamOrganization
    let folders: [Folder]
    let members: [Member]
    let invitations: [Invitation]
    let transfer: Transfer?
    init(_ raw: [String: JSON], team expected: String, account: String, origin: String) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        team = try TeamOrganization(raw); guard team.id == expected else { throw TeamOrganizationValue.invalid }
        if team.role == .guest {
            guard raw["folders"] == nil else { throw TeamOrganizationValue.invalid }; folders = []
        } else {
            folders = try TeamOrganizationValue.rows(raw["folders"], limit: 200).map { row in
                guard case .number(let position)? = row["position"], position.isFinite, (0...1_000_000).contains(position), position.rounded(.down) == position else { throw TeamOrganizationValue.invalid }
                return try Folder(id: TeamOrganizationValue.id(row["id"]), name: TeamOrganizationValue.name(row["name"]), position: Int(position))
            }
            try TeamOrganizationValue.unique(folders, by: \.id)
            guard folders == folders.sorted(by: { ($0.position, $0.id) < ($1.position, $1.id) }) else { throw TeamOrganizationValue.invalid }
        }
        if team.role.directoryVisible {
            members = try TeamOrganizationValue.rows(raw["members"], limit: 500).map { row in
                guard case .string(let raw)? = row["role"], let role = TeamOrganizationRole(rawValue: raw) else { throw TeamOrganizationValue.invalid }
                return try Member(id: TeamOrganizationValue.id(row["user_id"]), role: role)
            }
            try TeamOrganizationValue.unique(members, by: \.id)
            guard members.filter({ $0.role == .owner }).count == 1, members.first(where: { $0.id == account })?.role == team.role else { throw TeamOrganizationValue.invalid }
            invitations = try TeamOrganizationValue.rows(raw["invitations"], limit: 100).map { row in
                guard case .string(let email)? = row["email"], (3...254).contains(email.unicodeScalars.count), email.contains("@"),
                      !email.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      case .string(let text)? = row["role"], let role = TeamOrganizationRole(rawValue: text), role != .owner else { throw TeamOrganizationValue.invalid }
                return try Invitation(id: TeamOrganizationValue.id(row["id"]), email: email, role: role, expires: TeamOrganizationValue.date(row["expires_at"]))
            }
            try TeamOrganizationValue.unique(invitations, by: \.id)
            try TeamOrganizationValue.unique(invitations, by: \.email)
        } else {
            guard raw["members"] == nil, raw["invitations"] == nil else { throw TeamOrganizationValue.invalid }; members = []; invitations = []
        }
        if let value = raw["transfer"], value != .null {
            guard case .object(let row) = value else { throw TeamOrganizationValue.invalid }
            let target = try TeamOrganizationValue.id(row["target_id"])
            guard team.role == .owner || target == account else { throw TeamOrganizationValue.invalid }
            transfer = try Transfer(id: TeamOrganizationValue.id(row["id"]), target: target, expires: TeamOrganizationValue.date(row["expires_at"]))
        } else { transfer = nil }
        self.account = account; self.origin = origin
    }
}

/// Ephemeral presentation only. Account/session/access changes destroy it; no
/// directory names or invitation email addresses are written to the task cache.
@MainActor @Observable final class TeamOrganizationBrowser {
    private(set) var overview: TeamOrganizationOverview?
    private(set) var detail: TeamOrganizationDetail?
    private(set) var setupEnabled = false
    private(set) var loading = false
    private(set) var message: String?
    private var request = UUID()
    private let account: String
    private let origin: String
    @ObservationIgnored private let current: () -> Bool
    @ObservationIgnored private let readOverview: () async throws -> TeamOrganizationOverview
    @ObservationIgnored private let readDetail: (String) async throws -> TeamOrganizationDetail
    init(account: String, origin: String, current: @escaping () -> Bool,
         overview: @escaping () async throws -> TeamOrganizationOverview,
         detail: @escaping (String) async throws -> TeamOrganizationDetail) {
        self.account = account; self.origin = origin; self.current = current; readOverview = overview; readDetail = detail
    }
    func invalidate() { request = UUID(); overview = nil; detail = nil; setupEnabled = false; message = nil; loading = false }
    func refresh(team: String? = nil) async {
        invalidate(); guard current() else { return }
        let attempt = request; loading = true
        do {
            if let team {
                let enrollment = try await readOverview()
                guard attempt == request, current(), enrollment.account == account, enrollment.origin == origin else { return finishStale(attempt) }
                let value = try await readDetail(team)
                guard attempt == request, current(), value.account == account, value.origin == origin, value.team.id == team else { return finishStale(attempt) }
                detail = value; setupEnabled = enrollment.enabled
            } else {
                let value = try await readOverview()
                guard attempt == request, current(), value.account == account, value.origin == origin else { return finishStale(attempt) }
                overview = value; setupEnabled = value.enabled
            }
        } catch {
            guard attempt == request, current() else { return finishStale(attempt) }
            message = error is TeamWorkspaceUnavailable ? "Teams aren’t available for this account yet." : error is AccountSessionAuthorizationRequired ? "Sign in again to view your teams." : "Team details couldn’t be refreshed. Try again when you’re connected."
        }
        if attempt == request { loading = false }
    }
    private func finishStale(_ attempt: UUID) { if attempt == request { invalidate() } }
}
