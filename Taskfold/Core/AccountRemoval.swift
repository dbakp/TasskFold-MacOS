import Foundation
import Darwin

/// Device-private recovery only. Never put this authorization in Snapshot,
/// portable backups, an App Group, diagnostics or task metadata.
struct AccountRemovalCommand: Codable, Equatable, Sendable {
    var version = 2
    let id: UUID
    let account: String
    let origin: String
    let authorization: String
    var statusProof: String?
    var confirmed = false
    init(account: String, origin: String, authorization: String) throws {
        self.id = UUID(); self.account = account; self.origin = origin; self.authorization = authorization
        guard valid else { throw AppFailure(message: "Account removal needs a valid signed-in workspace.") }
    }
    var valid: Bool {
        guard (version == 1 || version == 2), let accountID = UUID(uuidString: account), accountID.uuidString.lowercased() == account,
              let url = URL(string: origin), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", !authorization.isEmpty, authorization.utf8.count <= 8192,
              authorization.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { return false }
        if let statusProof, !Self.validProof(statusProof) { return false }
        return version == 1 || !confirmed || statusProof != nil
    }
    static func validProof(_ value: String) -> Bool {
        value.utf8.count <= 2048 && value.range(of: #"^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{43}\z"#, options: .regularExpression) != nil
    }
    func prepared(with proof: String) throws -> Self {
        guard valid, !confirmed, Self.validProof(proof) else { throw CancellationError() }
        var result = self; result.version = 2; result.statusProof = proof; return result
    }
}

struct AccountRemovalAuthorizationRequired: LocalizedError {
    var errorDescription: String? { "Sign in to this account again to finish removal. Your remaining device copies have been kept." }
}

/// One serialized Keychain item, separately bound to each account and original
/// server. A lost reply or ordinary sign-out cannot discard an unfinished command.
actor AccountRemovalVault {
    private let io: any CalendarSecureItemIO
    private let processLock: AutomationEnrollmentProcessLock
    private let key = "unfinished-removals-v1"
    // All accounts share one Keychain envelope, so they must share one lock.
    // The service-specific parent directory separates independently owned apps.
    static let coordinationResource = "00000000-0000-4000-8000-000000000000"
    static func coordinationDirectory(service: String, root: URL = .applicationSupportDirectory) -> URL {
        root.appendingPathComponent("AccountRemovalLocks", isDirectory: true)
            .appendingPathComponent(WorkspaceBackup.stableID("service", service), isDirectory: true)
    }
    init(io: any CalendarSecureItemIO, coordinationDirectory: URL? = nil, lockTimeout: TimeInterval = 2) {
        precondition(coordinationDirectory != nil || !(io is CalendarKeychainIO), "Keychain removal recovery requires process coordination")
        self.io = io
        self.processLock = AutomationEnrollmentProcessLock(directory: coordinationDirectory, timeout: lockTimeout)
    }
    private func coordinated<T>(_ operation: () throws -> T) throws -> T {
        var entered = false
        do {
            return try processLock.withExclusive(account: Self.coordinationResource) {
                entered = true
                return try operation()
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            guard entered else { throw AppFailure(message: "Account removal recovery is busy or unavailable. Try again shortly. Your saved data has been kept.") }
            throw error
        }
    }
    func pending() throws -> [AccountRemovalCommand] { try coordinated { try read() } }
    private func read() throws -> [AccountRemovalCommand] {
        let stored: Data?
        do { stored = try io.read(key: key) }
        catch { throw AppFailure(message: "Account removal recovery could not be read securely. Unlock this device and try again.") }
        guard let data = stored else { return [] }
        guard data.count <= 100_000, let commands = try? TaskfoldJSONDecoder().decode([AccountRemovalCommand].self, from: data),
              commands.count <= 8, commands.allSatisfy(\.valid), Set(commands.map(\.account)).count == commands.count,
              Set(commands.map(\.id)).count == commands.count else {
            throw AppFailure(message: "Account removal recovery could not be read securely. Your device data has been kept.")
        }
        return commands
    }
    private func save(_ commands: [AccountRemovalCommand]) throws {
        do {
            if commands.isEmpty { try io.remove(key: key) }
            else { try io.write(TaskfoldJSONEncoder().encode(commands), key: key) }
        } catch { throw AppFailure(message: "Account removal recovery could not be saved securely. Unlock this device and try again.") }
    }
    func command(account: String, origin: String) throws -> AccountRemovalCommand? {
        try coordinated {
            guard let command = try read().first(where: { $0.account == account }) else { return nil }
            guard command.origin == origin else { throw AppFailure(message: "Return to this account's original server to finish removal.") }
            return command
        }
    }
    func begin(_ command: AccountRemovalCommand) throws -> AccountRemovalCommand {
        try coordinated {
            guard command.valid, !command.confirmed else { throw CancellationError() }
            var commands = try read()
            if let old = commands.first(where: { $0.account == command.account }) {
                guard old.origin == command.origin else { throw CancellationError() }; return old
            }
            guard commands.count < 8 else { throw AppFailure(message: "Finish an existing account removal before starting another.") }
            commands.append(command); try save(commands); return command
        }
    }
    /// Called only after the original endpoint explicitly refuses authorization.
    /// Never replace a confirmed command or reuse a different account's login.
    func renew(_ original: AccountRemovalCommand, with replacement: AccountRemovalCommand) throws -> AccountRemovalCommand {
        try coordinated {
            guard !original.confirmed, replacement.valid, !replacement.confirmed,
                  original.account == replacement.account, original.origin == replacement.origin,
                  original.authorization != replacement.authorization else { throw CancellationError() }
            var commands = try read()
            guard let index = commands.firstIndex(of: original) else { throw CancellationError() }
            commands[index] = replacement; try save(commands); return replacement
        }
    }
    /// The status proof must reach protected storage before execution can start.
    func prepare(_ original: AccountRemovalCommand, proof: String) throws -> AccountRemovalCommand {
        try coordinated {
            let prepared = try original.prepared(with: proof)
            var commands = try read()
            guard let index = commands.firstIndex(of: original) else { throw CancellationError() }
            commands[index] = prepared; try save(commands); return prepared
        }
    }
    func confirm(_ command: AccountRemovalCommand) throws -> AccountRemovalCommand {
        try coordinated {
            var commands = try read()
            guard command.valid, command.statusProof != nil || command.version == 1 && command.confirmed else { throw CancellationError() }
            var confirmed = command; confirmed.confirmed = true
            guard let index = commands.firstIndex(where: { $0 == command || $0 == confirmed }) else { throw CancellationError() }
            // Another process may already have saved this exact confirmation.
            if commands[index] == confirmed { return confirmed }
            commands[index] = confirmed; try save(commands); return confirmed
        }
    }
    func finish(_ command: AccountRemovalCommand) throws {
        try coordinated {
            guard command.valid, command.confirmed else { throw CancellationError() }
            var commands = try read()
            // Repeating an acknowledged cleanup must not overwrite an account
            // added by another process, or acknowledge a newer command for A.
            guard let index = commands.firstIndex(where: { $0.account == command.account }) else { return }
            guard commands[index] == command else { throw CancellationError() }
            commands.remove(at: index); try save(commands)
        }
    }
}

/// A durable account-only tombstone fences cache writers from other current
/// processes as well as the UI task that started removal. It contains no token.
struct AccountRemovalDisk: Sendable {
    let directory: URL
    let account: String
    var cache: URL { directory.appendingPathComponent(account + ".json") }
    var teamAccessFence:URL {directory.appendingPathComponent(account+".team-access-fence")}
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
            for file in [cache,teamAccessFence] where FileManager.default.fileExists(atPath:file.path) {try FileManager.default.removeItem(at:file)}
        }
    }
}
