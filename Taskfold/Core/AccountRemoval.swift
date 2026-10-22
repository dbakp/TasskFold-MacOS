import Foundation
import Darwin

/// Device-private recovery only. Never put this authorization in Snapshot,
/// portable backups, an App Group, diagnostics or task metadata.
struct AccountRemovalCommand: Codable, Equatable, Sendable {
    var version = 1
    let id: UUID
    let account: String
    let origin: String
    let authorization: String
    var confirmed = false
    init(account: String, origin: String, authorization: String) throws {
        self.id = UUID(); self.account = account; self.origin = origin; self.authorization = authorization
        guard valid else { throw AppFailure(message: "Account removal needs a valid signed-in workspace.") }
    }
    var valid: Bool {
        guard version == 1, let accountID = UUID(uuidString: account), accountID.uuidString.lowercased() == account,
              let url = URL(string: origin), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", !authorization.isEmpty, authorization.utf8.count <= 8192,
              authorization.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { return false }
        return true
    }
}

struct AccountRemovalAuthorizationRequired: LocalizedError {
    var errorDescription: String? { "Sign in to this account again to finish removal. Your remaining device copies have been kept." }
}

/// One serialized Keychain item, separately bound to each account and original
/// server. A lost reply or ordinary sign-out cannot discard an unfinished command.
actor AccountRemovalVault {
    private let io: any CalendarSecureItemIO
    private let key = "unfinished-removals-v1"
    init(io: any CalendarSecureItemIO) { self.io = io }
    func pending() throws -> [AccountRemovalCommand] {
        let stored: Data?
        do { stored = try io.read(key: key) }
        catch { throw AppFailure(message: "Account removal recovery could not be read securely. Unlock this device and try again.") }
        guard let data = stored else { return [] }
        guard data.count <= 100_000, let commands = try? JSONDecoder().decode([AccountRemovalCommand].self, from: data),
              commands.count <= 8, commands.allSatisfy(\.valid), Set(commands.map(\.account)).count == commands.count,
              Set(commands.map(\.id)).count == commands.count else {
            throw AppFailure(message: "Account removal recovery could not be read securely. Your device data has been kept.")
        }
        return commands
    }
    private func save(_ commands: [AccountRemovalCommand]) throws {
        do {
            if commands.isEmpty { try io.remove(key: key) }
            else { try io.write(JSONEncoder().encode(commands), key: key) }
        } catch { throw AppFailure(message: "Account removal recovery could not be saved securely. Unlock this device and try again.") }
    }
    func command(account: String, origin: String) throws -> AccountRemovalCommand? {
        guard let command = try pending().first(where: { $0.account == account }) else { return nil }
        guard command.origin == origin else { throw AppFailure(message: "Return to this account's original server to finish removal.") }
        return command
    }
    func begin(_ command: AccountRemovalCommand) throws -> AccountRemovalCommand {
        guard command.valid, !command.confirmed else { throw CancellationError() }
        var commands = try pending()
        if let old = commands.first(where: { $0.account == command.account }) {
            guard old.origin == command.origin else { throw CancellationError() }; return old
        }
        guard commands.count < 8 else { throw AppFailure(message: "Finish an existing account removal before starting another.") }
        commands.append(command); try save(commands); return command
    }
    /// Called only after the original endpoint explicitly refuses authorization.
    /// Never replace a confirmed command or reuse a different account's login.
    func renew(_ original: AccountRemovalCommand, with replacement: AccountRemovalCommand) throws -> AccountRemovalCommand {
        guard !original.confirmed, replacement.valid, !replacement.confirmed,
              original.account == replacement.account, original.origin == replacement.origin,
              original.authorization != replacement.authorization else { throw CancellationError() }
        var commands = try pending()
        guard let index = commands.firstIndex(of: original) else { throw CancellationError() }
        commands[index] = replacement; try save(commands); return replacement
    }
    func confirm(_ command: AccountRemovalCommand) throws -> AccountRemovalCommand {
        var commands = try pending()
        guard let index = commands.firstIndex(where: { $0.id == command.id && $0.account == command.account }),
              commands[index].origin == command.origin, commands[index].authorization == command.authorization else { throw CancellationError() }
        commands[index].confirmed = true; try save(commands); return commands[index]
    }
    func finish(_ command: AccountRemovalCommand) throws {
        var commands = try pending()
        guard command.confirmed, commands.contains(command) else { throw CancellationError() }
        commands.removeAll { $0 == command }; try save(commands)
    }
}

/// A durable account-only tombstone fences cache writers from other current
/// processes as well as the UI task that started removal. It contains no token.
struct AccountRemovalDisk: Sendable {
    let directory: URL
    let account: String
    var cache: URL { directory.appendingPathComponent(account + ".json") }
    private var marker: URL { directory.appendingPathComponent(account + ".removed") }
    private func locked<T>(_ operation: () throws -> T) throws -> T {
        guard let id = UUID(uuidString: account), id.uuidString.lowercased() == account else { throw CancellationError() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = Darwin.open(directory.appendingPathComponent(account + ".removal.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw AppFailure(message: "Account cleanup could not lock this device's saved work. Try again.") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw AppFailure(message: "Account cleanup is busy. Try again.") }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }
    var removed: Bool { FileManager.default.fileExists(atPath: marker.path) }
    func writable<T>(_ operation: () throws -> T) throws -> T {
        try locked {
            guard !removed else { throw AppFailure(message: "This account was removed. Its saved work cannot be changed or recreated.") }
            return try operation()
        }
    }
    /// Only call after a server success has reached the secure recovery vault.
    func removeCache() throws {
        try locked {
            try Data("Account removed\n".utf8).write(to: marker, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
        }
    }
}
