import Foundation
import CryptoKit
import Security
import Observation

/// Address capabilities stay in the device-only vault, never task snapshots.
enum EmailCaptureValue {
    static var invalid: AppFailure { AppFailure(message: "Email setup was not confirmed. Refresh its status before continuing.") }
    static func id(_ value: String) -> Bool { AutomationKey.canonicalID(value) && value != "00000000-0000-0000-0000-000000000000" }
    static func domain(_ value: String) -> Bool {
        guard value.utf8.count <= 189, value == value.lowercased() else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.last!.range(of: #"^[a-z]{2,63}$"#, options: .regularExpression) != nil && labels.allSatisfy { $0.range(of: #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"#, options: .regularExpression) != nil }
    }
    static func hash(address: String) -> String {
        // Exact cross-runtime contract; the canonical address is ASCII lowercase.
        let bytes = Data(("[\"taskfold-email-alias\",1,\"" + address + "\"]").utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func entropy() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw invalid }
        return Data(bytes)
    }
}
struct EmailAddressDraft: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let id: String, account: String, origin: String, domain: String, name: String
    let project: String?
    let requestedAt: String
    fileprivate let localPart: String
    var description: String { "Email address setup (private address redacted)" }
    var debugDescription: String { description }
    var address: String { localPart + "@" + domain }
    var hash: String { EmailCaptureValue.hash(address: address) }
    init(account: String, origin: String, domain: String, name: String, project: String?, id: UUID = UUID(), now: Date = Date(), entropy: () throws -> Data = EmailCaptureValue.entropy) throws {
        guard EmailCaptureValue.id(account), EmailCaptureValue.id(id.uuidString.lowercased()), WebhookValue.origin(origin), EmailCaptureValue.domain(domain), WebhookValue.name(name), project == nil || EmailCaptureValue.id(project!) else { throw EmailCaptureValue.invalid }
        let bytes = try entropy(); guard bytes.count == 32, now.timeIntervalSince1970.isFinite else { throw EmailCaptureValue.invalid }
        self.id = id.uuidString.lowercased(); self.account = account; self.origin = origin; self.domain = domain; self.name = name; self.project = project
        localPart = bytes.map { String(format: "%02x", $0) }.joined()
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; requestedAt = formatter.string(from: now)
    }
    fileprivate init(_ row: EmailAddressEnvelope) throws {
        guard row.localPart.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              let date = WebhookValue.date(.string(row.requestedAt)), let uuid = UUID(uuidString: row.id) else { throw EmailCaptureValue.invalid }
        var bytes = Data(); for start in stride(from: 0, to: 64, by: 2) { let a = row.localPart.index(row.localPart.startIndex, offsetBy: start), b = row.localPart.index(a, offsetBy: 2); guard let byte = UInt8(row.localPart[a..<b], radix: 16) else { throw EmailCaptureValue.invalid }; bytes.append(byte) }
        try self.init(account: row.account, origin: row.origin, domain: row.domain, name: row.name, project: row.project, id: uuid, now: date, entropy: { bytes })
        guard self.id == row.id, self.requestedAt == row.requestedAt else { throw EmailCaptureValue.invalid }
    }
    var body: [String: JSON] { ["id": .string(id), "name": .string(name), "domain": .string(domain), "project_id": project.map(JSON.string) ?? .null, "alias_hash": .string(hash), "requested_at": .string(requestedAt)] }
}
struct EmailRoute: Identifiable, Equatable, Sendable {
    let id: String, name: String, sender: String, state: String
    let project: String?, rotatedTo: String?, domain: String?
    let revision: Int
    init(_ row: [String: JSON]) throws {
        guard let id = row["id"]?.text, EmailCaptureValue.id(id), let name = row["name"]?.text, WebhookValue.name(name),
              let sender = row["sender_email"]?.text, sender.utf8.count <= 254, sender.range(of: #"^[^\s@]+@[^\s@]+$"#, options: .regularExpression) != nil,
              let state = row["state"]?.text, ["active", "paused", "revoked"].contains(state) else { throw EmailCaptureValue.invalid }
        for key in ["created_at", "updated_at", "accept_after"] { guard WebhookValue.date(row[key]) != nil else { throw EmailCaptureValue.invalid } }
        func optionalID(_ key: String) throws -> String? { if row[key] == .null { return nil }; guard let value = row[key]?.text, EmailCaptureValue.id(value) else { throw EmailCaptureValue.invalid }; return value }
        let revision = try WebhookValue.count(row, "revision"); guard revision > 0 else { throw EmailCaptureValue.invalid }
        if row["alias_domain"] == .null && state == "revoked" { domain = nil }
        else { guard let value = row["alias_domain"]?.text, EmailCaptureValue.domain(value) else { throw EmailCaptureValue.invalid }; domain = value }
        self.id = id; self.name = name; self.sender = sender; self.state = state; self.revision = revision; project = try optionalID("project_id"); rotatedTo = try optionalID("rotated_to")
    }
}
private struct EmailAddressEnvelope: Codable {
    let id: String, account: String, origin: String, domain: String, name: String, requestedAt: String, localPart: String
    let project: String?
    init(_ d: EmailAddressDraft) { id = d.id; account = d.account; origin = d.origin; domain = d.domain; name = d.name; requestedAt = d.requestedAt; localPart = d.localPart; project = d.project }
}
struct EmailAddressOperation: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let action: String, id: String, domain: String?
    let revision: Int
    let draft: EmailAddressDraft?
    var description: String { "Email address change (private configuration redacted)" }
    var debugDescription: String { description }
    init(action: String, id: String, revision: Int = 0, domain: String? = nil, draft: EmailAddressDraft? = nil) throws {
        guard ["create", "pause", "resume", "revoke", "rotate"].contains(action), EmailCaptureValue.id(id), revision >= 0, revision <= 2147483646,
              domain == nil || EmailCaptureValue.domain(domain!) else { throw EmailCaptureValue.invalid }
        if action == "create" { guard draft?.id == id, domain == draft?.domain, revision == 0 else { throw EmailCaptureValue.invalid } }
        else if action == "rotate" { guard let draft, draft.id != id, draft.domain == domain, revision > 0 else { throw EmailCaptureValue.invalid } }
        else { guard draft == nil, action == "revoke" || revision > 0, action != "resume" || domain != nil else { throw EmailCaptureValue.invalid } }
        self.action = action; self.id = id; self.revision = revision; self.domain = domain; self.draft = draft
    }
    var body: [String: JSON] {
        if action == "create" { return draft!.body }
        var body: [String: JSON] = ["id": .string(id), "revision": .number(Double(revision))]
        if action == "rotate" { body["replacement"] = .object(draft!.body) }; if action == "resume" { body["domain"] = .string(domain!) }; return body
    }
    fileprivate var signature: [String] { [action, id, String(revision), domain ?? "", draft?.hash ?? "", draft?.requestedAt ?? "", draft?.name ?? "", draft?.project ?? ""] }
}
private struct EmailOperationEnvelope: Codable {
    let action: String, id: String
    let revision: Int
    let domain: String?
    let draft: EmailAddressEnvelope?
    init(_ op: EmailAddressOperation) { action = op.action; id = op.id; revision = op.revision; domain = op.domain; draft = op.draft.map(EmailAddressEnvelope.init) }
    func operation() throws -> EmailAddressOperation { try EmailAddressOperation(action: action, id: id, revision: revision, domain: domain, draft: try draft.map(EmailAddressDraft.init)) }
}
private struct EmailVaultEnvelope: Codable {
    var version = 1
    let account: String, origin: String
    var addresses: [EmailAddressEnvelope] = []
    var pending: EmailOperationEnvelope?
}
struct EmailAddressRecovery: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "Private email address recovery" }; var debugDescription: String { description }
    let addresses: [EmailAddressDraft]
    let pending: EmailAddressOperation?
}
actor EmailAddressVault {
    private let io: any CalendarSecureItemIO
    private let lock: AutomationEnrollmentProcessLock
    init(io: any CalendarSecureItemIO, coordinationDirectory: URL? = nil) { precondition(coordinationDirectory != nil || !(io is CalendarKeychainIO)); self.io = io; lock = AutomationEnrollmentProcessLock(directory: coordinationDirectory) }
    private func key(_ account: String) throws -> String { guard EmailCaptureValue.id(account) else { throw EmailCaptureValue.invalid }; return "email-addresses-v1." + account }
    private func read(_ account: String, _ origin: String) throws -> EmailVaultEnvelope {
        guard EmailCaptureValue.id(account), WebhookValue.origin(origin) else { throw EmailCaptureValue.invalid }
        guard let bytes = try io.read(key: key(account)) else { return EmailVaultEnvelope(account: account, origin: origin) }
        guard bytes.count <= 65536, let value = try? TaskfoldJSONDecoder().decode(EmailVaultEnvelope.self, from: bytes), value.version == 1, value.account == account, value.origin == origin, value.addresses.count <= 32 else { throw EmailCaptureValue.invalid }
        let drafts = try value.addresses.map(EmailAddressDraft.init)
        guard Set(drafts.map(\.id)).count == drafts.count, drafts.allSatisfy({ $0.account == account && $0.origin == origin }) else { throw EmailCaptureValue.invalid }
        if let op = try value.pending?.operation() { guard op.draft == nil || (op.draft!.account == account && op.draft!.origin == origin) else { throw EmailCaptureValue.invalid } }
        return value
    }
    private func write(_ value: EmailVaultEnvelope, _ lease: CalendarReadLease) throws {
        let bytes = try TaskfoldJSONEncoder().encode(value); guard bytes.count <= 65536, value.addresses.count <= 32 else { throw EmailCaptureValue.invalid }; try lease.check(); try io.write(bytes, key: key(value.account))
    }
    func recovery(account: String, origin: String) throws -> EmailAddressRecovery {
        try lock.withExclusive(account: account) { let value = try read(account, origin); return EmailAddressRecovery(addresses: try value.addresses.map(EmailAddressDraft.init), pending: try value.pending?.operation()) }
    }
    func begin(_ op: EmailAddressOperation, account: String, origin: String, lease: CalendarReadLease) throws {
        try lock.withExclusive(account: account, check: { try lease.check() }) {
            var value = try read(account, origin)
            guard op.draft == nil || (op.draft!.account == account && op.draft!.origin == origin) else { throw EmailCaptureValue.invalid }
            if let existing = try value.pending?.operation() { guard existing.signature == op.signature else { throw EmailCaptureValue.invalid }; return }
            value.pending = EmailOperationEnvelope(op); try write(value, lease)
        }
    }
    func cancelSetup(account: String, origin: String, lease: CalendarReadLease) throws {
        try lock.withExclusive(account: account, check: { try lease.check() }) {
            var value = try read(account, origin); guard let op = try value.pending?.operation(), let draft = op.draft else { throw EmailCaptureValue.invalid }
            value.pending = EmailOperationEnvelope(try EmailAddressOperation(action: "revoke", id: draft.id)); try write(value, lease)
        }
    }
    func finish(_ op: EmailAddressOperation, account: String, origin: String, lease: CalendarReadLease, applied: Bool = true) throws {
        try lock.withExclusive(account: account, check: { try lease.check() }) {
            var value = try read(account, origin); guard try value.pending?.operation().signature == op.signature else { throw CancellationError() }
            if applied, let draft = op.draft { value.addresses.removeAll { $0.id == draft.id }; value.addresses.append(EmailAddressEnvelope(draft)) }
            if applied && (op.action == "revoke" || op.action == "rotate") { value.addresses.removeAll { $0.id == op.id } }
            value.pending = nil; try write(value, lease)
        }
    }
    func pruneRevoked(_ ids: Set<String>, account: String, origin: String, lease: CalendarReadLease) throws {
        try lock.withExclusive(account: account, check: { try lease.check() }) {
            var value = try read(account, origin); let count = value.addresses.count
            value.addresses.removeAll { ids.contains($0.id) }
            if count != value.addresses.count { try write(value, lease) }
        }
    }
    func removeAccount(_ account: String, origin: String) throws { try lock.withExclusive(account: account) { _ = try read(account, origin); try io.remove(key: key(account)) } }
}
@MainActor protocol EmailCaptureService: AnyObject {
    func emailRouteReceipt(action: String, body: [String: JSON], domain: String?, account: String, origin: String) async throws -> [String: JSON]
}
extension Backend: EmailCaptureService {}

@MainActor @Observable final class EmailCaptureModel {
    private(set) var routes: [EmailRoute] = []
    private(set) var pending: EmailAddressOperation?
    private(set) var available = false
    private(set) var domain: String?
    private(set) var busy = false
    private(set) var message: String?
    private(set) var needsSignIn = false
    private var addresses: [EmailAddressDraft] = []
    private var closed = false
    let account: String, origin: String
    @ObservationIgnored private let service: any EmailCaptureService
    @ObservationIgnored private let vault: EmailAddressVault
    @ObservationIgnored private let isCurrent: () -> Bool
    @ObservationIgnored private let lease = CalendarReadLease()
    init(account: String, origin: String, service: any EmailCaptureService, vault: EmailAddressVault, isCurrent: @escaping () -> Bool) { self.account = account; self.origin = origin; self.service = service; self.vault = vault; self.isCurrent = isCurrent }
    var current: Bool { !closed && isCurrent() }
    func close() { closed = true; lease.cancel(); addresses = []; pending = nil; routes = []; available = false; domain = nil; message = nil }
    private func check() throws { try lease.check(); guard current else { throw CancellationError() } }
    func address(for route: EmailRoute) -> String? {
        guard current, !needsSignIn, route.state != "revoked", pending == nil, available, let draft = addresses.first(where: { $0.id == route.id && $0.domain == domain && $0.domain == route.domain }) else { return nil }; return draft.address
    }
    private func perform(_ work: () async throws -> Void) async {
        guard current, !busy else { return }; busy = true; message = nil; defer { busy = false }
        do { try check(); try await work() } catch is CancellationError {} catch {
            if current { available = false; domain = nil; needsSignIn = error is AccountSessionAuthorizationRequired; message = needsSignIn ? "Sign in again to continue. Your saved setup stays on this device." : "Change not confirmed. Refresh or retry the saved action. Your tasks stay saved." }
        }
    }
    private func call(_ action: String, _ body: [String: JSON], domain: String? = nil) async throws -> [String: JSON] {
        try check(); let result = try await service.emailRouteReceipt(action: action, body: body, domain: domain, account: account, origin: origin); try check(); guard result["protocol"] == .number(2), result["account"] == .string(account) else { throw EmailCaptureValue.invalid }; needsSignIn = false; return result
    }
    private func recover() async throws { let value = try await vault.recovery(account: account, origin: origin); try check(); addresses = value.addresses; pending = value.pending }
    func load() async { await perform { try await self.recover(); try await self.reload() } }
    private func reload() async throws {
        let result = try await call("list", [:]); guard case .bool(let enabled) = result["available"], case .array(let rows) = result["routes"], rows.count <= 512 else { throw EmailCaptureValue.invalid }
        let list = try rows.map { value -> EmailRoute in guard case .object(let fields) = value else { throw EmailCaptureValue.invalid }; return try EmailRoute(fields) }
        guard Set(list.map(\.id)).count == list.count else { throw EmailCaptureValue.invalid }
        let domain: String?; if result["domain"] == .null { domain = nil } else { guard let value = result["domain"]?.text, EmailCaptureValue.domain(value) else { throw EmailCaptureValue.invalid }; domain = value }
        guard enabled == (domain != nil) else { throw EmailCaptureValue.invalid }
        if let op = pending, op.draft == nil, op.revision > 0,
           let row = list.first(where: { $0.id == op.id }), row.state == "revoked" || row.revision > op.revision {
            try await vault.finish(op, account: account, origin: origin, lease: lease, applied: op.action == "revoke" && row.state == "revoked")
            try check(); try await recover()
            message = "The address changed. Review its current status before trying another action."
        }
        try await vault.pruneRevoked(Set(list.filter { $0.state == "revoked" }.map(\.id)), account: account, origin: origin, lease: lease); try check()
        routes = list; available = enabled; self.domain = domain
    }
    func create(name: String, project: String?) async {
        await perform {
            try await self.recover(); guard self.pending == nil, self.available, let domain = self.domain else { throw EmailCaptureValue.invalid }
            let draft = try EmailAddressDraft(account: self.account, origin: self.origin, domain: domain, name: name, project: project)
            let op = try EmailAddressOperation(action: "create", id: draft.id, domain: domain, draft: draft)
            try await self.vault.begin(op, account: self.account, origin: self.origin, lease: self.lease); try self.check(); self.pending = op; try await self.finish()
        }
    }
    func control(_ action: String, route: EmailRoute) async {
        await perform {
            try await self.recover(); guard self.pending == nil, self.routes.contains(route) else { throw EmailCaptureValue.invalid }
            let op: EmailAddressOperation
            if action == "rotate" {
                guard self.available, let domain = self.domain else { throw EmailCaptureValue.invalid }
                let draft = try EmailAddressDraft(account: self.account, origin: self.origin, domain: domain, name: route.name, project: route.project)
                op = try EmailAddressOperation(action: action, id: route.id, revision: route.revision, domain: domain, draft: draft)
            } else {
                if action == "resume" { guard self.address(for: route) != nil else { throw EmailCaptureValue.invalid } }
                op = try EmailAddressOperation(action: action, id: route.id, revision: route.revision, domain: action == "resume" ? self.domain : nil)
            }
            try await self.vault.begin(op, account: self.account, origin: self.origin, lease: self.lease); try self.check(); self.pending = op; try await self.finish()
        }
    }
    func retry() async { await perform { try await self.recover(); if self.pending == nil { try await self.reload() } else { try await self.finish() } } }
    func discardSetup() async { await perform { try await self.vault.cancelSetup(account: self.account, origin: self.origin, lease: self.lease); try self.check(); try await self.recover(); try await self.finish() } }
    private func finish() async throws {
        guard let op = pending else { return }
        let result = try await call(op.action, op.body, domain: op.domain)
        if result["cancelled"] == .bool(true) {
            guard op.action == "revoke", op.revision == 0, result["id"] == .string(op.id) else { throw EmailCaptureValue.invalid }
        } else {
            guard case .object(let fields) = result["route"] else { throw EmailCaptureValue.invalid }; let row = try EmailRoute(fields)
            guard row.id == (op.draft?.id ?? op.id) else { throw EmailCaptureValue.invalid }
            if let draft = op.draft { guard row.name == draft.name, row.project == draft.project, row.domain == draft.domain else { throw EmailCaptureValue.invalid } }
            if op.action == "rotate" { guard case .object(let oldFields) = result["replaced"] else { throw EmailCaptureValue.invalid }; let old = try EmailRoute(oldFields); guard old.id == op.id, old.state == "revoked", old.rotatedTo == row.id else { throw EmailCaptureValue.invalid } }
            if op.action == "pause" { guard row.state == "paused" else { throw EmailCaptureValue.invalid } }
            if op.action == "resume" { guard row.state == "active" else { throw EmailCaptureValue.invalid } }
            if op.action == "revoke" { guard row.state == "revoked" else { throw EmailCaptureValue.invalid } }
        }
        try await vault.finish(op, account: account, origin: origin, lease: lease); try check(); try await recover(); try await reload()
    }
}
