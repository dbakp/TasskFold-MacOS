import Foundation
import Observation

/// Administration stays separate from task mutations and never enters the
/// optimistic task queue. A retry is the same reviewed body, not a rebased edit.
struct TeamOrganizationCommand: Equatable, Sendable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Action: String, Codable, Sendable, CaseIterable {
        case create, rename, archive, unarchive
        case folderCreate = "folder_create", folderRename = "folder_rename", folderRemove = "folder_remove"
        var title: String {
            switch self {
            case .create: return "Create team"
            case .rename: return "Rename team"
            case .archive: return "Archive team"
            case .unarchive: return "Reopen team"
            case .folderCreate: return "New folder"
            case .folderRename: return "Rename folder"
            case .folderRemove: return "Remove folder"
            }
        }
        var needsName: Bool { [.create, .rename, .folderCreate, .folderRename].contains(self) }
        var needsFolder: Bool { self == .folderRename || self == .folderRemove }
        var success: String {
            switch self {
            case .create: return "Team created"
            case .rename: return "Team renamed"
            case .archive: return "Team archived"
            case .unarchive: return "Team reopened"
            case .folderCreate: return "Folder created"
            case .folderRename: return "Folder renamed"
            case .folderRemove: return "Folder removed"
            }
        }
    }
    let account: String
    let origin: String
    let action: Action
    let body: [String: JSON]
    var description: String { "Private team administration request" }
    var debugDescription: String { description }
    var team: String { body["team_id"]!.text }
    var id: String { body["request_id"]!.text }
    var name: String? { body["name"]?.text }
    var issued: Date { try! TeamOrganizationValue.date(body["issued_at"]) }
    var expires: Date { issued.addingTimeInterval(900) }
    var canRetry: Bool { retryable(at: Date()) }
    func retryable(at now: Date) -> Bool { issued <= now.addingTimeInterval(60) && expires >= now }
    static var invalid: AppFailure { AppFailure(message: "Review this team change again before sending it.") }

    init(account: String, origin: String, action: Action, team: String = UUID().uuidString.lowercased(), revision: Double? = nil,
         name: String? = nil, folder: String? = nil, id: UUID = UUID(), now: Date = Date()) throws {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var body: [String: JSON] = ["team_id": .string(team), "request_id": .string(id.uuidString.lowercased()), "issued_at": .string(parser.string(from: now))]
        if let revision { body["revision"] = .number(revision) }
        if let name { body["name"] = .string(name.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let folder { body["folder_id"] = .string(folder) }
        try self.init(account: account, origin: origin, action: action, body: body)
    }
    init(account: String, origin: String, action: Action, body: [String: JSON]) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        var fields: Set<String> = ["team_id", "request_id", "issued_at"]
        if action != .create { fields.insert("revision") }
        if action.needsName { fields.insert("name") }
        if action.needsFolder { fields.insert("folder_id") }
        guard Set(body.keys) == fields, try JSONEncoder().encode(body).count <= 16_384 else { throw Self.invalid }
        _ = try TeamOrganizationValue.id(body["team_id"]); _ = try TeamOrganizationValue.id(body["request_id"])
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
        if action.needsFolder { _ = try TeamOrganizationValue.id(body["folder_id"]) }
        self.account = account; self.origin = origin; self.action = action; self.body = body
    }
    private enum CodingKeys: String, CodingKey { case account, origin, action, body }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), action: c.decode(Action.self, forKey: .action), body: c.decode([String: JSON].self, forKey: .body))
    }
    func confirmed(_ raw: [String: JSON]) throws -> TeamOrganizationCommandReceipt {
        guard raw["id"] == body["team_id"], raw["state"] == .string(action == .archive ? "archived" : "active") else { throw Self.invalid }
        let revision = try TeamProjectValue.revision(raw["revision"])
        let expected = action == .create ? 1 : try TeamProjectValue.revision(body["revision"]) + 1
        guard revision == expected else { throw Self.invalid }
        var folder: String?
        if action == .folderCreate { folder = try TeamOrganizationValue.id(raw["folder_id"]) }
        return TeamOrganizationCommandReceipt(team: team, revision: revision, folder: folder)
    }
}
struct TeamOrganizationCommandReceipt: Equatable, Sendable { let team: String; let revision: Double; let folder: String? }

/// Stable, private, one-command-per-account/server recovery shared across app windows.
/// Keychain data never enters portable backups, widgets or the task cache.
actor TeamOrganizationCommandVault {
    private struct Envelope: Codable { var version = 1; let command: TeamOrganizationCommand }
    private let io: any CalendarSecureItemIO
    private let lock: AutomationEnrollmentProcessLock
    private let removalDirectory: URL?
    init(io: any CalendarSecureItemIO, coordinationDirectory: URL? = nil, removalDirectory: URL? = nil) {
        precondition(!(io is CalendarKeychainIO) || (coordinationDirectory != nil && removalDirectory != nil))
        self.io = io; lock = AutomationEnrollmentProcessLock(directory: coordinationDirectory); self.removalDirectory = removalDirectory
    }
    private func key(_ account: String, origin: String) throws -> String {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        return "team-command-v1." + account + "." + CalendarOAuthConfiguration.digest(origin)
    }
    private func guarded<T>(account: String, _ action: () throws -> T) throws -> T {
        if let removalDirectory { return try AccountRemovalDisk(directory: removalDirectory, account: account).writable(action) }
        return try action()
    }
    private func read(account: String, origin: String) throws -> TeamOrganizationCommand? {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard let data = try io.read(key: key(account, origin: origin)) else { return nil }
        guard data.count <= 20_000, let value = try? JSONDecoder().decode(Envelope.self, from: data), value.version == 1,
              value.command.account == account, value.command.origin == origin else { throw TeamOrganizationCommand.invalid }
        return value.command
    }
    func pending(account: String, origin: String) throws -> TeamOrganizationCommand? {
        try lock.withExclusive(account: account) { try guarded(account: account) { try read(account: account, origin: origin) } }
    }
    func begin(_ command: TeamOrganizationCommand, lease: CalendarReadLease) throws {
        try lock.withExclusive(account: command.account, check: { try lease.check() }) {
            try guarded(account: command.account) {
                if let old = try read(account: command.account, origin: command.origin) {
                    guard old == command else { throw AppFailure(message: "Finish or review your saved team request first.") }; return
                }
                let data = try JSONEncoder().encode(Envelope(command: command))
                guard data.count <= 20_000 else { throw TeamOrganizationCommand.invalid }
                try lease.check(); try io.write(data, key: key(command.account, origin: command.origin))
            }
        }
    }
    /// Clearing recovery is conditional: another window's newer request survives.
    /// This never cancels or undoes an operation already accepted by the server.
    func clear(_ command: TeamOrganizationCommand, lease: CalendarReadLease) throws {
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
    func close() { closed = true; lease.cancel(); pending = nil; message = nil; success = nil; receipt = nil }
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
        var verified: [String: JSON] = ["id": .string(result.team), "revision": .number(result.revision), "state": .string(command.action == .archive ? "archived" : "active")]
        if let folder = result.folder { verified["folder_id"] = .string(folder) }
        guard try command.confirmed(verified) == result else { throw TeamOrganizationCommand.invalid }
        try await vault.clear(command, lease: lease); try check()
        pending = nil; receipt = result; success = command.action.success
        try await recover()
    }
    private func perform(_ action: () async throws -> Void) async {
        guard current, !busy else { return }
        busy = true; message = nil; success = nil; receipt = nil
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
