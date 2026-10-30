import Foundation
import Observation

/// Administration stays separate from task mutations and never enters the
/// optimistic task queue. A retry is the same reviewed body, not a rebased edit.
struct TeamOrganizationCommand: Equatable, Sendable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Action: String, Codable, Sendable, CaseIterable {
        case create, rename, archive, unarchive, delete, invite, leave
        case folderCreate = "folder_create", folderRename = "folder_rename", folderRemove = "folder_remove"
        case revokeInvitation = "revoke_invitation", acceptInvitation = "accept_invitation", declineInvitation = "decline_invitation"
        case changeRole = "change_role", removeMember = "remove_member"
        case transferOffer = "transfer_offer", transferAccept = "transfer_accept", transferCancel = "transfer_cancel"
        var title: String {
            switch self {
            case .create: return "Create team"
            case .rename: return "Rename team"
            case .archive: return "Archive team"
            case .unarchive: return "Reopen team"
            case .delete: return "Delete team"
            case .invite: return "Invite to team"
            case .leave: return "Leave team"
            case .folderCreate: return "New folder"
            case .folderRename: return "Rename folder"
            case .folderRemove: return "Remove folder"
            case .revokeInvitation: return "Revoke invitation"
            case .acceptInvitation: return "Join team"
            case .declineInvitation: return "Decline invitation"
            case .changeRole: return "Change role"
            case .removeMember: return "Remove member"
            case .transferOffer: return "Offer ownership"
            case .transferAccept: return "Accept ownership"
            case .transferCancel: return "Cancel ownership offer"
            }
        }
        var needsName: Bool { [.create, .rename, .folderCreate, .folderRename].contains(self) }
        var needsFolder: Bool { self == .folderRename || self == .folderRemove }
        var needsUser: Bool { [.changeRole, .removeMember, .transferOffer].contains(self) }
        var needsInvitation: Bool { [.revokeInvitation, .acceptInvitation, .declineInvitation].contains(self) }
        var needsRole: Bool { self == .invite || self == .changeRole }
        var allowedWhilePaused: Bool { [.delete, .leave, .removeMember, .revokeInvitation, .declineInvitation, .transferOffer, .transferAccept, .transferCancel].contains(self) }
        var allowedWhileArchived: Bool { self == .unarchive || allowedWhilePaused }
        var success: String {
            switch self {
            case .create: return "Team created"
            case .rename: return "Team renamed"
            case .archive: return "Team archived"
            case .unarchive: return "Team reopened"
            case .delete: return "Team deleted"
            case .invite: return "Invitation created"
            case .leave: return "You left the team"
            case .folderCreate: return "Folder created"
            case .folderRename: return "Folder renamed"
            case .folderRemove: return "Folder removed"
            case .revokeInvitation: return "Invitation revoked"
            case .acceptInvitation: return "You joined the team"
            case .declineInvitation: return "Invitation declined"
            case .changeRole: return "Role updated"
            case .removeMember: return "Member removed"
            case .transferOffer: return "Ownership offered"
            case .transferAccept: return "Ownership accepted"
            case .transferCancel: return "Ownership offer cancelled"
            }
        }
    }
    let account: String
    let origin: String
    let action: Action
    let body: [String: JSON]
    /// Private review metadata, never an authority claim or an extra RPC field.
    let reviewedState: String
    var resultState: String { action == .delete ? "deleted" : action == .archive ? "archived" : [.create, .unarchive].contains(action) ? "active" : reviewedState }
    var description: String { "Private team administration request" }
    var debugDescription: String { description }
    var team: String { body["team_id"]!.text }
    var id: String { body["request_id"]!.text }
    var name: String? { body["name"]?.text }
    var email: String? { body["email"]?.text }
    var issued: Date { try! TeamOrganizationValue.date(body["issued_at"]) }
    var expires: Date { issued.addingTimeInterval(900) }
    var canRetry: Bool { retryable(at: Date()) }
    func retryable(at now: Date) -> Bool { issued <= now.addingTimeInterval(60) && expires >= now }
    static var invalid: AppFailure { AppFailure(message: "Review this team change again before sending it.") }
    static func validEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return (3...254).contains(value.unicodeScalars.count) && parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty &&
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) })
    }
    init(account: String, origin: String, action: Action, team: String = UUID().uuidString.lowercased(), revision: Double? = nil,
         name: String? = nil, folder: String? = nil, email: String? = nil, role: TeamOrganizationRole? = nil,
         user: String? = nil, invitation: String? = nil, transfer: String? = nil, state: String? = nil,
         id: UUID = UUID(), now: Date = Date()) throws {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var body: [String: JSON] = ["team_id": .string(team), "request_id": .string(id.uuidString.lowercased()), "issued_at": .string(parser.string(from: now))]
        if let revision { body["revision"] = .number(revision) }
        if let name { body["name"] = .string(name.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let folder { body["folder_id"] = .string(folder) }
        if let email { body["email"] = .string(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        if let role { body["role"] = .string(role.rawValue) }
        if let user { body["user_id"] = .string(user) }
        if let invitation { body["invitation_id"] = .string(invitation) }
        if let transfer { body["transfer_id"] = .string(transfer) }
        try self.init(account: account, origin: origin, action: action, body: body, state: state)
    }
    init(account: String, origin: String, action: Action, body: [String: JSON], state: String? = nil) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        let state = state ?? (action == .unarchive ? "archived" : "active")
        guard ["active", "archived"].contains(state), state != "archived" || action.allowedWhileArchived,
              action != .unarchive || state == "archived" else { throw Self.invalid }
        var fields: Set<String> = ["team_id", "request_id", "issued_at"]
        if action != .create { fields.insert("revision") }
        if action.needsName { fields.insert("name") }
        if action.needsFolder { fields.insert("folder_id") }
        if action.needsUser { fields.insert("user_id") }
        if action.needsInvitation { fields.insert("invitation_id") }
        if action.needsRole { fields.insert("role") }
        if action == .invite { fields.insert("email") }
        if action == .transferAccept { fields.insert("transfer_id") }
        guard Set(body.keys) == fields, try TaskfoldJSONEncoder().encode(body).count <= 16_384 else { throw Self.invalid }
        for key in ["team_id", "request_id"] + (action.needsFolder ? ["folder_id"] : []) + (action.needsUser ? ["user_id"] : []) + (action.needsInvitation ? ["invitation_id"] : []) + (action == .transferAccept ? ["transfer_id"] : []) { _ = try TeamOrganizationValue.id(body[key]) }
        guard let stamp = body["issued_at"]?.text, stamp.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$"#, options: .regularExpression) != nil else { throw Self.invalid }
        _ = try TeamOrganizationValue.date(body["issued_at"])
        if action != .create {
            let revision = try TeamProjectValue.revision(body["revision"])
            guard revision <= 9_007_199_254_740_990 else { throw Self.invalid }
        }
        if action.needsName {
            let name = try TeamOrganizationValue.name(body["name"])
            guard name == name.trimmingCharacters(in: .whitespacesAndNewlines) else { throw Self.invalid }
        }
        if action.needsRole { guard let role = body["role"]?.text, ["admin", "member", "guest"].contains(role) else { throw Self.invalid } }
        if action == .invite { guard let email = body["email"]?.text, Self.validEmail(email) else { throw Self.invalid } }
        self.account = account; self.origin = origin; self.action = action; self.body = body; reviewedState = state
    }
    private enum CodingKeys: String, CodingKey { case account, origin, action, body, reviewedState }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), action: c.decode(Action.self, forKey: .action), body: c.decode([String: JSON].self, forKey: .body), state: c.decodeIfPresent(String.self, forKey: .reviewedState))
    }
    func confirmed(_ raw: [String: JSON]) throws -> TeamOrganizationCommandReceipt {
        guard raw["id"] == body["team_id"], raw["state"] == .string(resultState) else { throw Self.invalid }
        let revision = try TeamProjectValue.revision(raw["revision"])
        let expected = action == .create ? 1 : try TeamProjectValue.revision(body["revision"]) + 1
        guard revision == expected else { throw Self.invalid }
        let folder = action == .folderCreate ? try TeamOrganizationValue.id(raw["folder_id"]) : nil
        let invitation = action == .invite ? try TeamOrganizationValue.id(raw["invitation_id"]) : nil
        let transfer = action == .transferOffer ? try TeamOrganizationValue.id(raw["transfer_id"]) : nil
        return TeamOrganizationCommandReceipt(team: team, revision: revision, folder: folder, invitation: invitation, transfer: transfer)
    }
}
struct TeamOrganizationCommandReceipt: Equatable, Sendable {
    let team: String; let revision: Double; let folder: String?; let invitation: String?; let transfer: String?
    init(team: String, revision: Double, folder: String? = nil, invitation: String? = nil, transfer: String? = nil) { self.team = team; self.revision = revision; self.folder = folder; self.invitation = invitation; self.transfer = transfer }
}

/// UI affordances only. The service must recheck every request against its live
/// role, revision, invitation and ownership records, including receipt retries.
struct TeamOrganizationAdministration {
    let detail: TeamOrganizationDetail
    let enabled: Bool
    func allows(_ action: TeamOrganizationCommand.Action, member: TeamOrganizationDetail.Member? = nil, invitation: TeamOrganizationDetail.Invitation? = nil, now: Date = Date()) -> Bool {
        let team = detail.team, role = team.role
        guard enabled || action.allowedWhilePaused, !team.archived || action.allowedWhileArchived else { return false }
        switch action {
        case .create, .acceptInvitation, .declineInvitation: return false
        case .rename, .folderCreate, .folderRename, .folderRemove, .invite: return role.directoryVisible
        case .archive: return role == .owner && !team.archived
        case .unarchive: return role == .owner && team.archived
        case .delete, .transferCancel: return role == .owner && (action != .transferCancel || detail.transfer != nil)
        case .leave: return role != .owner
        case .revokeInvitation:
            guard let invitation, detail.invitations.contains(invitation), invitation.expires > now else { return false }
            return role == .owner || role == .admin && invitation.role != .admin
        case .changeRole, .removeMember:
            guard let member, detail.members.contains(member), member.id != detail.account, member.role != .owner else { return false }
            return role == .owner || role == .admin && member.role != .admin
        case .transferOffer:
            guard let member, detail.members.contains(member), member.id != detail.account, [.admin, .member].contains(member.role) else { return false }
            return role == .owner
        case .transferAccept:
            return [.admin, .member].contains(role) && detail.transfer?.target == detail.account && (detail.transfer?.expires ?? .distantPast) > now
        }
    }
    var assignableRoles: [TeamOrganizationRole] { detail.team.role == .owner ? [.admin, .member, .guest] : [.member, .guest] }
}

/// Stable, private, one-command-per-account/server recovery shared across app windows.
/// Keychain data never enters portable backups, widgets or the task cache.
protocol ReviewedTeamCommand: Codable, Equatable, Sendable {
    var account: String { get }; var origin: String { get }
    static var storagePrefix: String { get }; static var invalid: AppFailure { get }; static var maximumStoredBytes: Int { get }
}
extension ReviewedTeamCommand { static var maximumStoredBytes: Int { 20_000 } }
extension TeamOrganizationCommand: ReviewedTeamCommand { static let storagePrefix = "team-command-v1." }
typealias TeamOrganizationCommandVault = ReviewedTeamCommandVault<TeamOrganizationCommand>
actor ReviewedTeamCommandVault<Command: ReviewedTeamCommand> {
    private struct Envelope: Codable { var version = 1; let command: Command }
    private let io: any CalendarSecureItemIO
    private let lock: AutomationEnrollmentProcessLock
    private let removalDirectory: URL?
    init(io: any CalendarSecureItemIO, coordinationDirectory: URL? = nil, removalDirectory: URL? = nil) {
        precondition(!(io is CalendarKeychainIO) || (coordinationDirectory != nil && removalDirectory != nil))
        self.io = io; lock = AutomationEnrollmentProcessLock(directory: coordinationDirectory); self.removalDirectory = removalDirectory
    }
    private func key(_ account: String, origin: String) throws -> String {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        return Command.storagePrefix + account + "." + CalendarOAuthConfiguration.digest(origin)
    }
    private func guarded<T>(account: String, _ action: () throws -> T) throws -> T {
        if let removalDirectory { return try AccountRemovalDisk(directory: removalDirectory, account: account).writable(action) }
        return try action()
    }
    private func read(account: String, origin: String) throws -> Command? {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard let data = try io.read(key: key(account, origin: origin)) else { return nil }
        guard data.count <= Command.maximumStoredBytes, let value = try? TaskfoldJSONDecoder().decode(Envelope.self, from: data), value.version == 1,
              value.command.account == account, value.command.origin == origin else { throw Command.invalid }
        return value.command
    }
    func pending(account: String, origin: String) throws -> Command? {
        try lock.withExclusive(account: account) { try guarded(account: account) { try read(account: account, origin: origin) } }
    }
    func begin(_ command: Command, lease: CalendarReadLease) throws {
        try lock.withExclusive(account: command.account, check: { try lease.check() }) {
            try guarded(account: command.account) {
                if let old = try read(account: command.account, origin: command.origin) {
                    guard old == command else { throw AppFailure(message: "Finish or review your saved team request first.") }; return
                }
                let data = try TaskfoldJSONEncoder().encode(Envelope(command: command))
                guard data.count <= Command.maximumStoredBytes else { throw Command.invalid }
                try lease.check(); try io.write(data, key: key(command.account, origin: command.origin))
            }
        }
    }
    /// Clearing recovery is conditional: another window's newer request survives.
    /// This never cancels or undoes an operation already accepted by the server.
    func clear(_ command: Command, lease: CalendarReadLease) throws {
        try lock.withExclusive(account: command.account, check: { try lease.check() }) {
            try guarded(account: command.account) {
                guard let old = try read(account: command.account, origin: command.origin) else { return }
                guard old == command else { throw CancellationError() }
                try lease.check(); try io.remove(key: key(command.account, origin: command.origin))
            }
        }
    }
    func removeAccount(_ account: String, origin: String) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        try lock.withExclusive(account: account) { try io.remove(key: key(account, origin: origin)) }
    }
}

@MainActor protocol TeamOrganizationCommandService: AnyObject {
    func teamOrganizationCommand(_ command: TeamOrganizationCommand) async throws -> TeamOrganizationCommandReceipt
}
extension Backend: TeamOrganizationCommandService {}

struct TeamOrganizationCommandFailure: LocalizedError {
    let code: String
    var errorDescription: String? {
        switch code {
        case "review_changed": return "Your saved request changed in another window. Review it before retrying."
        case "expired": return "This saved request has expired. Refresh and review the team before clearing it. Clearing does not undo a change that may already have been made."
        case "PT409": return "The team or this review changed. Refresh the team before reviewing another change. Your saved request is kept."
        case "PT404", "42501": return "This team or action is no longer available to your account. Your saved request is kept."
        case "PT503", "PGRST202": return "Team setup is paused or unavailable. Your saved request is kept."
        case "PT429", "54000": return "The team has reached an administration limit. Your saved request is kept."
        case "22023": return "This team request needs a new review. Your saved request is kept."
        default: return "The result couldn’t be confirmed. Retry the saved request or review the latest team details."
        }
    }
}

@MainActor @Observable final class TeamOrganizationCommandModel {
    private(set) var pending: TeamOrganizationCommand?
    private(set) var busy = false
    private(set) var message: String?
    private(set) var success: String?
    private(set) var receipt: TeamOrganizationCommandReceipt?
    private(set) var appliedAction: TeamOrganizationCommand.Action?
    private var closed = false
    let account: String
    let origin: String
    @ObservationIgnored private let vault: TeamOrganizationCommandVault
    @ObservationIgnored private let service: any TeamOrganizationCommandService
    @ObservationIgnored private let isCurrent: () -> Bool
    @ObservationIgnored private let lease = CalendarReadLease()
    init(account: String, origin: String, vault: TeamOrganizationCommandVault, service: any TeamOrganizationCommandService, isCurrent: @escaping () -> Bool) {
        self.account = account; self.origin = origin; self.vault = vault; self.service = service; self.isCurrent = isCurrent
    }
    var current: Bool { !closed && isCurrent() }
    func close() { closed = true; lease.cancel(); pending = nil; message = nil; success = nil; receipt = nil; appliedAction = nil }
    private func check() throws { try lease.check(); guard current else { throw CancellationError() } }
    private func recover() async throws { let saved = try await vault.pending(account: account, origin: origin); try check(); pending = saved }
    func load() async { await perform { try await self.recover() } }
    func send(_ command: TeamOrganizationCommand, now: Date = Date()) async {
        await perform {
            try await self.recover()
            guard command.account == self.account, command.origin == self.origin, command.retryable(at: now), self.pending == nil else { throw TeamOrganizationCommand.invalid }
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
    func clearReviewedRequest(_ reviewed: TeamOrganizationCommand) async {
        await perform {
            try await self.recover(); guard self.pending == reviewed else { throw TeamOrganizationCommand.invalid }
            try await self.vault.clear(reviewed, lease: self.lease); try self.check(); try await self.recover()
        }
    }
    private func finish(now: Date) async throws {
        guard let command = pending else { throw TeamOrganizationCommand.invalid }
        guard command.retryable(at: now) else { throw TeamOrganizationCommandFailure(code: "expired") }
        try check(); let result = try await service.teamOrganizationCommand(command); try check()
        var verified: [String: JSON] = ["id": .string(result.team), "revision": .number(result.revision), "state": .string(command.resultState)]
        if let folder = result.folder { verified["folder_id"] = .string(folder) }
        if let invitation = result.invitation { verified["invitation_id"] = .string(invitation) }
        if let transfer = result.transfer { verified["transfer_id"] = .string(transfer) }
        guard try command.confirmed(verified) == result else { throw TeamOrganizationCommand.invalid }
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
            if receipt != nil { message = "The change was confirmed. Refresh team details before making another change." }
            else if let error = error as? TeamOrganizationCommandFailure { message = error.localizedDescription }
            else if error is AccountSessionAuthorizationRequired { message = "Sign in again before retrying your saved team request." }
            else if pending != nil { message = "This request couldn’t be confirmed. Check the latest team details before trying again; the request won’t be replaced automatically." }
            else { message = "The team request couldn’t be opened or prepared. Try again." }
        }
    }
}
