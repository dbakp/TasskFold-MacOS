import Foundation
import CryptoKit
import Security
import Observation
import Darwin

enum AutomationScope: String, CaseIterable, Codable, Sendable {
    case read = "tasks:read", create = "tasks:create", update = "tasks:update", complete = "tasks:complete", delete = "tasks:delete"
    var title: String {
        switch self {
        case .read: return "Read tasks"
        case .create: return "Create tasks"
        case .update: return "Edit task details and checklists"
        case .complete: return "Complete and reopen tasks"
        case .delete: return "Delete tasks"
        }
    }

    var detail: String {
        switch self {
        case .read: return "Read this account’s Inbox, accessible tasks, and project and section names."
        case .create: return "Add tasks to Inbox and active projects you can access."
        case .update: return "Change task details, planning, portable reminders, labels, assignments and checklist structure."
        case .complete: return "Change task and checklist progress, including recurring tasks."
        case .delete: return "Remove tasks and linked occurrences included in a current deletion review."
        }
    }

}

/// In-memory enrollment value: intentionally not Codable. Only the dedicated
/// private Keychain envelope below may persist it. Retries use the same ID/hash;
/// snapshots and portable backups never contain the secret.
struct AutomationKeyDraft: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let id: String
    let account: String
    let origin: String
    let name: String
    let scopes: [AutomationScope]
    let days: Int
    private let rawSecret: String
    var description: String { "Automation key draft (secret redacted)" }
    var debugDescription: String { description }
    var secretForOneTimeReview: String { rawSecret }
    var body: [String: JSON] {
        ["id": .string(id), "name": .string(name), "token_hash": .string(Self.hash(rawSecret)),
         "scopes": .array(scopes.map { .string($0.rawValue) }), "ttl_days": .number(Double(days))]
    }
    init(account: String, origin: String, name: String, scopes: Set<AutomationScope>, days: Int, id: UUID = UUID(),
         entropy: () throws -> Data = AutomationKeyDraft.secureEntropy) throws {
        guard AutomationKey.canonicalID(account), let url = URLComponents(string: origin), url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
            throw AppFailure(message: "Sign in to your account before creating an automation key.")
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.uuidString != "00000000-0000-0000-0000-000000000000", !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.unicodeScalars.count <= 80, name.utf8.count <= 320,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), !scopes.isEmpty,
              [7, 30, 90, 365].contains(days) else { throw AppFailure(message: "Choose a name, permissions and expiry for this key.") }
        let bytes = try entropy()
        guard bytes.count == 32 else { throw AppFailure(message: "A secure key could not be created. Try again.") }
        var components = url; components.path = ""
        self.id = id.uuidString.lowercased(); self.account = account; self.origin = components.string!
        self.name = name; self.scopes = scopes.sorted { $0.rawValue < $1.rawValue }; self.days = days
        rawSecret = "tfk_v1_" + self.id.replacingOccurrences(of: "-", with: "") + "_" + bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func secureEntropy() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AppFailure(message: "A secure key could not be created. Try again.") }
        return Data(bytes)
    }
    private static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
}

struct AutomationKey: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let prefix: String
    let scopes: [AutomationScope]
    let created: Date
    let expires: Date
    let revoked: Date?
    let lastUsed: Date?
    func active(at date: Date) -> Bool { revoked == nil && expires > date }
    static func canonicalID(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
    init(_ row: [String: JSON]) throws {
        let id = row["id"]?.text ?? "", name = row["name"]?.text ?? "", prefix = row["prefix"]?.text ?? ""
        let raw = row["scopes"]?.list ?? []
        let scopes = raw.compactMap { AutomationScope(rawValue: $0.text) }
        guard Self.canonicalID(id), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.unicodeScalars.count <= 80, name.utf8.count <= 320,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              prefix == "tfk_v1_" + id.replacingOccurrences(of: "-", with: "").prefix(8),
              !scopes.isEmpty, scopes.count <= 5, scopes.count == raw.count, Set(scopes).count == scopes.count,
              let created = Self.date(row["created_at"]), let expires = Self.date(row["expires_at"]),
              row["revoked_at"] == .null || Self.date(row["revoked_at"]) != nil,
              row["last_used_at"] == .null || Self.date(row["last_used_at"]) != nil else { throw Self.invalid }
        self.id = id; self.name = name; self.prefix = prefix; self.scopes = scopes
        self.created = created; self.expires = expires; self.revoked = Self.date(row["revoked_at"]); self.lastUsed = Self.date(row["last_used_at"])
    }
    private static func date(_ value: JSON?) -> Date? {
        guard case .string(let text) = value, text.count <= 40, text.contains("T") else { return nil }
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static var invalid: AppFailure { AppFailure(message: "Automation access was not confirmed. Reload your keys and try again.") }
}

struct AutomationKeyPage: Sendable {
    let keys: [AutomationKey]
    let nextCursor: String?
    init(_ receipt: [String: JSON], account: String) throws {
        guard AutomationKey.canonicalID(account), receipt["account"] == .string(account), case .array(let rows) = receipt["keys"], rows.count <= 100 else { throw AutomationKey.invalid }
        let keys = try rows.map { value -> AutomationKey in guard case .object(let fields) = value else { throw AutomationKey.invalid }; return try AutomationKey(fields) }
        let cursor = receipt["next_cursor"]
        guard Set(keys.map(\.id)).count == keys.count,
              cursor == .null || cursor?.text == keys.last?.id && AutomationKey.canonicalID(cursor?.text ?? "") else { throw AutomationKey.invalid }
        self.keys = keys; self.nextCursor = cursor == .null ? nil : cursor?.text
    }
}

/// Only this private envelope is Codable. Drafts remain non-Codable everywhere
/// else; this envelope is written exclusively to the app-only device Keychain.
private struct AutomationEnrollmentEnvelope: Codable {
    let version: Int
    let id: String
    let account: String
    let origin: String
    let name: String
    let scopes: [AutomationScope]
    let days: Int
    let secret: String
    let cancellationRequested: Bool?
    init(_ draft: AutomationKeyDraft, cancelling: Bool = false) {
        version = cancelling ? 2 : 1; id = draft.id; account = draft.account; origin = draft.origin
        name = draft.name; scopes = draft.scopes; days = draft.days; secret = draft.secretForOneTimeReview
        cancellationRequested = cancelling
    }
    func draft() throws -> AutomationKeyDraft {
        guard (version == 1 && cancellationRequested != true || version == 2 && cancellationRequested == true), AutomationKey.canonicalID(id), Set(scopes).count == scopes.count,
              secret.utf8.count == 83, secret.hasPrefix("tfk_v1_" + id.replacingOccurrences(of: "-", with: "") + "_") else { throw AutomationKey.invalid }
        let encoded = String(secret.suffix(43)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        guard let bytes = Data(base64Encoded: encoded) else { throw AutomationKey.invalid }
        let value = try AutomationKeyDraft(account: account, origin: origin, name: name, scopes: Set(scopes), days: days,
                                           id: UUID(uuidString: id)!, entropy: { bytes })
        guard value.secretForOneTimeReview == secret, value.origin == origin, value.name == name else { throw AutomationKey.invalid }
        return value
    }
}

struct AutomationEnrollmentRecovery: Sendable {
    let draft: AutomationKeyDraft
    let cancelling: Bool
}
struct AutomationEnrollmentDiscardPending: LocalizedError {
    var errorDescription: String? { "This key setup is being discarded. Retry discard to finish." }
}

/// A stable, zero-content lock file coordinates independent app processes. Never
/// unlink it while the app is installed: replacing its inode defeats flock.
struct AutomationEnrollmentProcessLock: Sendable {
    let directory: URL?
    var timeout: TimeInterval = 2
    func withExclusive<T>(account: String, check: () throws -> Void = { try Task.checkCancellation() }, _ operation: () throws -> T) throws -> T {
        try check()
        guard AutomationKey.canonicalID(account) else { throw AutomationKey.invalid }
        guard let directory else { return try operation() }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw Self.unavailable }
        let fd = Darwin.open(directory.appendingPathComponent(account + ".lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw Self.unavailable }
        defer { Darwin.close(fd) }
        var state = stat()
        guard fstat(fd, &state) == 0, state.st_mode & S_IFMT == S_IFREG else { throw Self.unavailable }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(max(0.1, min(5, timeout)) * 1000)))
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else { throw Self.unavailable }
            try check()
            guard ContinuousClock.now < deadline else { throw Self.unavailable }
            usleep(20_000)
        }
        defer { flock(fd, LOCK_UN) }
        try check()
        return try operation()
    }
    private static var unavailable: AppFailure { AppFailure(message: "Another key setup is busy or unavailable. Try again shortly. Your unfinished setup has been kept.") }
}

/// One unfinished enrollment per account, serialized across windows and app
/// processes. A different server cannot read, replace or acknowledge its secret.
actor AutomationEnrollmentVault {
    private let io: any CalendarSecureItemIO
    private let processLock: AutomationEnrollmentProcessLock
    init(io: any CalendarSecureItemIO, coordinationDirectory: URL? = nil) {
        precondition(coordinationDirectory != nil || !(io is CalendarKeychainIO), "Keychain enrollment requires process coordination")
        self.io = io; self.processLock = AutomationEnrollmentProcessLock(directory: coordinationDirectory)
    }
    private func key(_ account: String) throws -> String {
        guard AutomationKey.canonicalID(account) else { throw AutomationKey.invalid }
        return "enrollment-v1." + account
    }
    private func readRecovery(account: String, origin: String) throws -> AutomationEnrollmentRecovery? {
        let stored: Data?
        do { stored = try io.read(key: key(account)) }
        catch { throw Self.unavailable }
        guard let stored else { return nil }
        guard stored.count <= 4096, let envelope = try? JSONDecoder().decode(AutomationEnrollmentEnvelope.self, from: stored),
              let draft = try? envelope.draft(), draft.account == account else { throw Self.unavailable }
        guard draft.origin == origin else { throw AppFailure(message: "Return to this account’s original server to finish setting up its key.") }
        return AutomationEnrollmentRecovery(draft: draft, cancelling: envelope.cancellationRequested == true)
    }
    func recovery(account: String, origin: String) throws -> AutomationEnrollmentRecovery? {
        try processLock.withExclusive(account: account) { try readRecovery(account: account, origin: origin) }
    }
    func pending(account: String, origin: String) throws -> AutomationKeyDraft? { try recovery(account: account, origin: origin)?.draft }
    func prepareCancellation(_ draft: AutomationKeyDraft, lease: CalendarReadLease) throws {
        try processLock.withExclusive(account: draft.account, check: { try lease.check() }) {
            guard let old = try readRecovery(account: draft.account, origin: draft.origin), old.draft.id == draft.id, old.draft.body == draft.body else { throw CancellationError() }
            if old.cancelling { return }
            let data = try JSONEncoder().encode(AutomationEnrollmentEnvelope(draft, cancelling: true))
            guard data.count <= 4096 else { throw Self.unavailable }
            try lease.check()
            do { try io.write(data, key: key(draft.account)) } catch { throw Self.unavailable }
        }
    }
    func begin(_ draft: AutomationKeyDraft, lease: CalendarReadLease) throws -> AutomationKeyDraft {
        try processLock.withExclusive(account: draft.account, check: { try lease.check() }) {
            if let old = try readRecovery(account: draft.account, origin: draft.origin) { return old.draft }
            let data = try JSONEncoder().encode(AutomationEnrollmentEnvelope(draft))
            guard data.count <= 4096 else { throw Self.unavailable }
            try lease.check()
            do { try io.write(data, key: key(draft.account)) }
            catch { throw Self.unavailable }
            return draft
        }
    }
    /// Explicit save acknowledgement or confirmed cancellation/revocation only.
    /// A stale process cannot erase a newer enrollment's recovery.
    func finish(_ draft: AutomationKeyDraft, lease: CalendarReadLease, cancelled: Bool = false) throws {
        try processLock.withExclusive(account: draft.account, check: { try lease.check() }) {
            guard let saved = try readRecovery(account: draft.account, origin: draft.origin) else { return }
            guard saved.draft.id == draft.id, saved.draft.body == draft.body else { throw CancellationError() }
            guard !saved.cancelling || cancelled else { throw AutomationEnrollmentDiscardPending() }
            try lease.check()
            do { try io.remove(key: key(draft.account)) }
            catch { throw Self.unavailable }
        }
    }
    /// Invoked only by confirmed account-removal cleanup, never ordinary sign-out.
    func removeAccount(_ account: String, origin: String) throws {
        try processLock.withExclusive(account: account) {
            let location = try key(account)
            guard let data = try io.read(key: location) else { return }
            guard data.count <= 4096, let envelope = try? JSONDecoder().decode(AutomationEnrollmentEnvelope.self, from: data),
                  let draft = try? envelope.draft(), draft.account == account else { throw Self.unavailable }
            guard draft.origin == origin else { return }
            try io.remove(key: location)
        }
    }
    private static var unavailable: AppFailure {
        AppFailure(message: "Key setup could not be read or saved securely. Unlock this device and try again. Any unfinished setup has been kept.")
    }
}

@MainActor protocol AutomationKeyService: AnyObject {
    func automationKeyPage(account: String, origin: String, cursor: String?, includeInactive: Bool) async throws -> AutomationKeyPage
    func registerAutomationKey(_ draft: AutomationKeyDraft) async throws -> AutomationKey
    func revokeAutomationKey(id: String, account: String, origin: String) async throws -> AutomationKey
    func cancelAutomationKey(id: String, account: String, origin: String) async throws
}
extension Backend: AutomationKeyService {}

/// A view-owned lease fences list, enrollment and revoke replies independently
/// of Backend's account/session fence. Closing a window hides the secret while
/// retaining private recovery. No task snapshot or UserDefaults state is used.
@MainActor @Observable private final class AutomationEnrollmentReview {
    static let shared = AutomationEnrollmentReview()
    var finished = Set<String>()
}

@MainActor @Observable final class AutomationAccessModel {
    private(set) var keys: [AutomationKey] = []
    private(set) var nextCursor: String?
    private(set) var pending: AutomationKeyDraft?
    private(set) var confirmed: AutomationKey?
    private(set) var discarding = false
    private(set) var busy = false
    private(set) var loaded = false
    private(set) var message: String?
    private(set) var needsSignIn = false
    private(set) var includesInactive = false
    let account: String
    let origin: String
    @ObservationIgnored private let service: any AutomationKeyService
    @ObservationIgnored private let vault: AutomationEnrollmentVault
    @ObservationIgnored private let isCurrent: () -> Bool
    @ObservationIgnored private let lease = CalendarReadLease()
    @ObservationIgnored private var closed = false
    init(account: String, origin: String, service: any AutomationKeyService, vault: AutomationEnrollmentVault, isCurrent: @escaping () -> Bool) {
        self.account = account; self.origin = origin; self.service = service; self.vault = vault; self.isCurrent = isCurrent
    }
    var current: Bool { !closed && isCurrent() }
    private func reviewID(_ draft: AutomationKeyDraft) -> String { draft.origin + "|" + draft.account + "|" + draft.id }
    var secret: String? {
        guard let draft = pending, current, !discarding, confirmed?.id == draft.id, confirmed?.active(at: Date()) == true,
              !AutomationEnrollmentReview.shared.finished.contains(reviewID(draft)) else { return nil }
        return draft.secretForOneTimeReview
    }
    func close() { closed = true; lease.cancel(); pending = nil; confirmed = nil; keys = []; message = nil }
    private func check() throws { try lease.check(); guard current else { throw CancellationError() } }
    private func perform(_ operation: () async throws -> Void) async {
        guard current, !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do { try check(); try await operation() }
        catch is CancellationError { }
        catch { if current {
            confirmed = nil
            if error is AccountSessionAuthorizationRequired {
                needsSignIn = true
                message = pending == nil ? "Sign in again to continue. Your tasks stay saved." : "Sign in again. Your setup is saved."
            } else { message = error.localizedDescription }
        } }
    }
    func selectHistory(_ value: Bool) {
        guard current, !busy else { return }
        includesInactive = value
    }
    func load(includeInactive: Bool = false, more: Bool = false) async {
        await perform {
            let cursor = more ? self.nextCursor : nil
            guard !more || cursor != nil else { return }
            let saved = try await self.vault.recovery(account: self.account, origin: self.origin)
            try self.check(); self.pending = saved?.draft; self.discarding = saved?.cancelling ?? false; self.confirmed = nil
            let page = try await self.service.automationKeyPage(account: self.account, origin: self.origin, cursor: cursor, includeInactive: includeInactive)
            try self.check()
            if more {
                let old = Set(self.keys.map(\.id))
                guard page.keys.allSatisfy({ !old.contains($0.id) }) else { throw AutomationKey.invalid }
                self.keys += page.keys
            } else { self.keys = page.keys }
            self.needsSignIn = false
            self.nextCursor = page.nextCursor; self.includesInactive = includeInactive; self.loaded = true
        }
    }
    func create(name: String, scopes: Set<AutomationScope>, days: Int) async {
        await perform {
            guard self.pending == nil else { throw AppFailure(message: "Finish the existing key setup before creating another.") }
            let draft = try AutomationKeyDraft(account: self.account, origin: self.origin, name: name, scopes: scopes, days: days)
            let saved = try await self.vault.begin(draft, lease: self.lease)
            try self.check(); self.pending = saved
            guard saved.id == draft.id, saved.body == draft.body else {
                throw AppFailure(message: "Another key setup is already waiting. Review its name and permissions before continuing.")
            }
            let key = try await self.service.registerAutomationKey(saved)
            try await self.accept(key, draft: saved)
        }
    }
    func resume() async {
        await perform {
            guard let saved = try await self.vault.recovery(account: self.account, origin: self.origin) else { self.pending = nil; self.confirmed = nil; self.discarding = false; return }
            let draft = saved.draft
            try self.check(); self.discarding = saved.cancelling
            guard let presented = self.pending, presented.id == draft.id, presented.body == draft.body else {
                self.pending = draft; self.confirmed = nil
                throw AppFailure(message: "Key setup changed in another window. Review its name and permissions before continuing.")
            }
            if saved.cancelling { self.confirmed = nil; try await self.finishDiscard(draft); return }
            let key = try await self.service.registerAutomationKey(draft)
            try await self.accept(key, draft: draft)
        }
    }
    private func accept(_ key: AutomationKey, draft: AutomationKeyDraft) async throws {
        try check()
        let saved = try await vault.recovery(account: account, origin: origin)
        try check(); discarding = saved?.cancelling ?? false
        guard saved?.draft.id == draft.id, saved?.draft.body == draft.body, pending?.id == draft.id, !discarding else {
            pending = saved?.draft; confirmed = nil
            throw AppFailure(message: "Key setup changed in another window. Review it before continuing.")
        }
        needsSignIn = false; confirmed = key; upsert(key)
    }
    func refreshRecovery() async {
        await perform {
            let previous = self.confirmed, old = self.pending
            self.confirmed = nil
            let saved = try await self.vault.recovery(account: self.account, origin: self.origin)
            try self.check(); self.pending = saved?.draft; self.discarding = saved?.cancelling ?? false
            if saved?.draft.id == old?.id, saved?.draft.body == old?.body, !self.discarding { self.confirmed = previous }
        }
    }
    func acknowledgeSaved() async {
        await perform {
            guard let draft = self.pending, self.confirmed?.id == draft.id, self.secret != nil else { throw AutomationKey.invalid }
            do { try await self.vault.finish(draft, lease: self.lease) }
            catch is AutomationEnrollmentDiscardPending { self.confirmed = nil; self.discarding = true; throw AutomationEnrollmentDiscardPending() }
            AutomationEnrollmentReview.shared.finished.insert(self.reviewID(draft))
            try self.check(); self.pending = nil; self.confirmed = nil
        }
    }
    func revoke(_ key: AutomationKey) async { await revokeID(key.id) }
    func discardPending() async {
        await perform {
            guard let draft = self.pending else { return }
            self.confirmed = nil
            try await self.vault.prepareCancellation(draft, lease: self.lease)
            try self.check(); self.discarding = true
            try await self.finishDiscard(draft)
        }
    }
    private func finishDiscard(_ draft: AutomationKeyDraft) async throws {
        try await service.cancelAutomationKey(id: draft.id, account: account, origin: origin)
        try check(); needsSignIn = false
        AutomationEnrollmentReview.shared.finished.insert(reviewID(draft))
        confirmed = nil; keys.removeAll { $0.id == draft.id }
        try await vault.finish(draft, lease: lease, cancelled: true)
        try check(); pending = nil; discarding = false
    }
    private func revokeID(_ id: String) async {
        await perform {
            let key = try await self.service.revokeAutomationKey(id: id, account: self.account, origin: self.origin)
            try self.check(); self.needsSignIn = false; self.upsert(key)
            if let draft = self.pending, draft.id == key.id {
                AutomationEnrollmentReview.shared.finished.insert(self.reviewID(draft))
                self.confirmed = nil // Never reveal after confirmed revocation, even if secure cleanup fails.
                try await self.vault.finish(draft, lease: self.lease, cancelled: true)
                try self.check(); self.pending = nil; self.discarding = false
            }
        }
    }
    private func upsert(_ key: AutomationKey) {
        if let index = keys.firstIndex(where: { $0.id == key.id }) { keys[index] = key }
        else { keys.insert(key, at: 0) }
    }
}
