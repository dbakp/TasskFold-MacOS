import Foundation
import CryptoKit
import Darwin
import Observation

struct TeamTemplateCommand: ReviewedTeamCommand, CustomStringConvertible, CustomDebugStringConvertible {
    enum Action: String, Codable, CaseIterable, Sendable {
        case publish, replace, delete
        var success: String { switch self { case .publish: "Template published"; case .replace: "Template updated"; case .delete: "Template removed" } }
    }
    static let storagePrefix = "team-template-command-v1."
    static let maximumStoredBytes = 2_100_000
    static var invalid: AppFailure { AppFailure(message: "Review this template change again before sending it.") }
    let account: String, origin: String
    let action: Action
    let body: [String: JSON]
    var id: String { body["request_id"]!.text }
    var team: String { body["team_id"]!.text }
    var template: String { body["template_id"]!.text }
    var description: String { "Private team template request" }
    var debugDescription: String { description }
    init(account: String, origin: String, action: Action, team: String, template: String, revision: Double? = nil, name: String? = nil, document: JSON? = nil, requestID: UUID = UUID()) throws {
        var body: [String: JSON] = ["team_id": .string(team), "template_id": .string(template), "request_id": .string(requestID.uuidString.lowercased())]
        if let revision { body["revision"] = .number(revision) }
        if let name { body["name"] = .string(name.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let document { body["document"] = document }
        try self.init(account: account, origin: origin, action: action, body: body)
    }
    init(account: String, origin: String, action: Action, body: [String: JSON]) throws {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        var fields: Set<String> = ["team_id", "template_id", "request_id"]
        for key in fields { _ = try TeamOrganizationValue.id(body[key]) }
        if action != .publish {
            fields.insert("revision"); let revision = try TeamTemplateLibraryValue.revision(body["revision"])
            guard action == .delete || revision < 9_007_199_254_740_991 else { throw Self.invalid }
        }
        if action != .delete {
            fields.formUnion(["name", "document"])
            let name = try TeamTemplateLibraryValue.name(body["name"])
            guard name == name.trimmingCharacters(in: .whitespacesAndNewlines), let document = body["document"] else { throw Self.invalid }
            _ = try WorkflowTemplate(document: document)
        }
        guard Set(body.keys) == fields, try JSONEncoder().encode(body).count <= 2_050_000 else { throw Self.invalid }
        self.account = account; self.origin = origin; self.action = action; self.body = body
    }
    private enum CodingKeys: String, CodingKey { case account, origin, action, body }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(account: c.decode(String.self, forKey: .account), origin: c.decode(String.self, forKey: .origin), action: c.decode(Action.self, forKey: .action), body: c.decode([String: JSON].self, forKey: .body))
    }
    func confirmed(_ raw: [String: JSON]) throws -> TeamTemplateReceipt {
        let revision: Double
        switch action {
        case .publish: revision = 1
        case .replace: revision = try TeamTemplateLibraryValue.revision(body["revision"]) + 1
        case .delete: revision = try TeamTemplateLibraryValue.revision(body["revision"])
        }
        guard Set(raw.keys) == ["library_protocol", "account", "team_id", "request_id", "operation", "template_id", "revision", "deleted", "replayed"],
              raw["library_protocol"] == .number(1), raw["account"] == .string(account), raw["team_id"] == .string(team),
              raw["request_id"] == .string(id), raw["operation"] == .string(action.rawValue), raw["template_id"] == .string(template),
              raw["revision"] == .number(revision), raw["deleted"] == .bool(action == .delete), case .bool? = raw["replayed"] else { throw Self.invalid }
        return TeamTemplateReceipt(raw: raw)
    }
}
struct TeamTemplateReceipt: Equatable, Sendable { let raw: [String: JSON] }
typealias TeamTemplateCommandVault = ReviewedTeamCommandVault<TeamTemplateCommand>

/// One bounded ciphertext per account/origin, outside portable backup contents.
/// The process/removal locks are supplied by ReviewedTeamCommandVault. Only the
/// key is in Keychain; no document or plaintext file is written there or on disk.
protocol ReviewedTeamFileCommand: ReviewedTeamCommand {
    static var fileName: String { get }
    static var encryptionContext: String { get }
}
extension TeamTemplateCommand: ReviewedTeamFileCommand {
    static let fileName = "request.taskfoldteamtemplate"
    static let encryptionContext = "com.taskfold.team-template-request.v1"
}
typealias TeamTemplateCommandFileIO = ReviewedTeamCommandFileIO<TeamTemplateCommand>

struct ReviewedTeamCommandFileIO<Command: ReviewedTeamFileCommand>: CalendarSecureItemIO {
    let directory: URL
    let account: String, origin: String
    let encryptionKey: @Sendable () throws -> SymmetricKey
    private var expectedKey: String { Command.storagePrefix + account + "." + CalendarOAuthConfiguration.digest(origin) }
    private var context: Data { Data((Command.encryptionContext + "|" + expectedKey).utf8) }
    var file: URL { directory.appendingPathComponent(Command.fileName) }
    private func validate(_ key: String) throws { try TeamOrganizationValue.scope(account: account, origin: origin); guard key == expectedKey else { throw Command.invalid } }
    private func directoryExists(create: Bool = false) throws -> Bool {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw Command.invalid }
            if !create { return false }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard lstat(directory.path, &info) == 0 else { throw Command.invalid }
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw Command.invalid }
        return true
    }
    func read(key: String) throws -> Data? {
        try validate(key); guard try directoryExists() else { return nil }
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 { if errno == ENOENT { return nil }; throw Command.invalid }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat(); let limit = Command.maximumStoredBytes + 1_024
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= limit else { throw Command.invalid }
        var bytes = Data()
        while bytes.count <= limit {
            let chunk = try handle.read(upToCount: min(262_144, limit + 1 - bytes.count)) ?? Data()
            if chunk.isEmpty { break }; bytes.append(chunk)
        }
        guard bytes.count == info.st_size, bytes.count <= limit else { throw Command.invalid }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: encryptionKey(), authenticating: context)
        guard plain.count <= Command.maximumStoredBytes else { throw Command.invalid }; return plain
    }
    func write(_ data: Data, key: String) throws {
        try validate(key); guard data.count <= Command.maximumStoredBytes else { throw Command.invalid }
        _ = try directoryExists(create: true)
        var info = stat()
        if lstat(file.path, &info) == 0 { guard info.st_mode & S_IFMT == S_IFREG else { throw Command.invalid } }
        else { guard errno == ENOENT else { throw Command.invalid } }
        let sealed = try AES.GCM.seal(data, using: encryptionKey(), authenticating: context)
        guard let bytes = sealed.combined else { throw Command.invalid }
        try bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var privateDirectory = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try privateDirectory.setResourceValues(values)
    }
    /// Cleanup does not need a decryption key and can run after account removal.
    func remove(key: String) throws {
        try validate(key); guard try directoryExists() else { return }
        var info = stat()
        if lstat(file.path, &info) != 0 { guard errno == ENOENT else { throw Command.invalid }; return }
        guard [S_IFREG, S_IFLNK].contains(info.st_mode & S_IFMT), Darwin.unlink(file.path) == 0 else { throw Command.invalid }
    }
}

@MainActor protocol TeamTemplateCommandService: AnyObject { func teamTemplateCommand(_ command: TeamTemplateCommand) async throws -> TeamTemplateReceipt }
extension Backend: TeamTemplateCommandService {}

/// A lost reply keeps the original request, including the original CAS revision.
/// No automatic rebase, replacement identity, overwrite or private copy is made.
@MainActor @Observable final class TeamTemplateCommandModel {
    private(set) var pending: TeamTemplateCommand?
    private(set) var recoveryLoaded = false
    private(set) var busy = false
    private(set) var message: String?
    private(set) var success: String?
    private(set) var receipt: TeamTemplateReceipt?
    let account: String, origin: String
    private var closed = false
    @ObservationIgnored private let vault: TeamTemplateCommandVault
    @ObservationIgnored private let service: any TeamTemplateCommandService
    @ObservationIgnored private let current: () -> Bool
    @ObservationIgnored private let lease = CalendarReadLease()
    init(account: String, origin: String, vault: TeamTemplateCommandVault, service: any TeamTemplateCommandService, current: @escaping () -> Bool) {
        self.account = account; self.origin = origin; self.vault = vault; self.service = service; self.current = current
    }
    func close() { closed = true; lease.cancel(); pending = nil; recoveryLoaded = false; message = nil; success = nil; receipt = nil }
    private func check() throws { try lease.check(); guard !closed, current() else { throw CancellationError() } }
    private func recover() async throws {
        recoveryLoaded = false; pending = nil
        let saved = try await vault.pending(account: account, origin: origin); try check(); pending = saved; recoveryLoaded = true
    }
    func load() async { await perform { try await self.recover() } }
    func send(_ command: TeamTemplateCommand, canAuthor: () -> Bool) async {
        await perform {
            try await self.recover(); guard self.pending == nil, command.account == self.account, command.origin == self.origin, canAuthor() else { throw TeamTemplateCommand.invalid }
            try await self.vault.begin(command, lease: self.lease); try self.check(); self.pending = command
            guard canAuthor() else { throw TeamTemplateCommand.invalid }
            try await self.finish()
        }
    }
    func retry(_ reviewed: TeamTemplateCommand) async {
        await perform {
            try await self.recover(); guard self.pending == reviewed else { throw TeamTemplateCommand.invalid }
            try await self.finish()
        }
    }
    /// Stopping retry does not cancel a change already accepted by the service.
    func stopRetrying(_ reviewed: TeamTemplateCommand) async {
        await perform {
            try await self.recover(); guard self.pending == reviewed else { throw TeamTemplateCommand.invalid }
            try await self.vault.clear(reviewed, lease: self.lease); try self.check(); try await self.recover()
        }
    }
    private func finish() async throws {
        guard let command = pending else { throw TeamTemplateCommand.invalid }
        try check(); let result = try await service.teamTemplateCommand(command); try check()
        guard try command.confirmed(result.raw) == result else { throw TeamTemplateCommand.invalid }
        try await vault.clear(command, lease: lease); try check()
        pending = nil; receipt = result
        success = result.raw["replayed"] == .bool(true) ? "Original change confirmed. The library may have changed since then." : command.action.success
        try await recover()
    }
    private func perform(_ action: () async throws -> Void) async {
        guard !busy, !closed else { return }
        guard current() else { close(); return }
        busy = true; message = nil; success = nil; receipt = nil; defer { busy = false }
        do { try check(); try await action(); try check() }
        catch {
            guard !closed, current() else { close(); return }
            if receipt != nil { message = "The change was confirmed. Refresh the library before making another change." }
            else if error is AccountSessionAuthorizationRequired { message = "Sign in again before retrying your saved template request." }
            else if pending != nil { message = "This change couldn’t be confirmed. Your original request is saved. Refresh the library before retrying; stopping retry won’t undo a change already made." }
            else { message = "Your saved template request couldn’t be opened or prepared. Nothing new was sent." }
        }
    }
}
