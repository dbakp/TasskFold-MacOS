import Foundation
import Security

/// Transport-only contract. Addresses/capabilities never enter tasks, widget snapshots or backups.
struct ReminderDeviceBinding: Codable, Equatable, Sendable {
    enum Platform: String, Codable, Sendable { case ios, macos }
    enum Environment: String, Codable, Sendable { case development, production }
    enum Permission: String, Codable, Sendable { case authorized, provisional, denied }
    var platform: Platform
    var bundle: String
    var environment: Environment
    var token: String
    var time_zone: String
    var permission: Permission
    var enabled: Bool
    var valid: Bool {
        bundle == (platform == .ios ? "com.dbakp.taskfold" : "com.dbakp.taskfold.mac") &&
        token.utf8.count >= 2 && token.utf8.count <= 1024 && token.utf8.count % 2 == 0 &&
        token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } &&
        TimeZone(identifier: time_zone) != nil && (!enabled || permission != .denied)
    }
    static func address(_ bytes: Data) -> String? {
        guard !bytes.isEmpty, bytes.count <= 512 else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

struct ReminderDeviceInstallation: Codable, Equatable, Sendable {
    static let maximumRevision: Int64 = 9_007_199_254_740_991
    var id: String
    var secret: String
    var revision: Int64 = 0
    /// Durable anonymous cleanup intent. Contains no token, owner, session or task content.
    var pendingRetirement = false
    /// Survives loss of the separate consent item. Never assume missing consent means local.
    var mayHaveRemoteAuthority = false
    init(id: String, secret: String, revision: Int64 = 0, pendingRetirement: Bool = false) {
        self.id = id; self.secret = secret; self.revision = revision; self.pendingRetirement = pendingRetirement
    }
    enum CodingKeys: String, CodingKey { case id, secret, revision, pendingRetirement, mayHaveRemoteAuthority }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); secret = try c.decode(String.self, forKey: .secret)
        revision = try c.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
        pendingRetirement = try c.decodeIfPresent(Bool.self, forKey: .pendingRetirement) ?? false
        mayHaveRemoteAuthority = try c.decodeIfPresent(Bool.self, forKey: .mayHaveRemoteAuthority) ?? false
    }
    var valid: Bool {
        UUID(uuidString: id)?.uuidString.lowercased() == id && secret.utf8.count == 64 &&
        secret.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } &&
        (0...Self.maximumRevision).contains(revision) && (!pendingRetirement || revision > 0) && (!mayHaveRemoteAuthority || revision > 0)
    }
    static func make() throws -> Self {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AppFailure(message: "This device's secure registration could not be prepared.")
        }
        return Self(id: UUID().uuidString.lowercased(), secret: bytes.map { String(format: "%02x", $0) }.joined())
    }
    mutating func reserve(account: String?, binding: ReminderDeviceBinding?) throws -> ReminderDeviceCommand {
        guard valid, revision < Self.maximumRevision,
              (binding == nil && account == nil) || (binding?.valid == true && UUID(uuidString: account ?? "") != nil),
              !(revision == 0 && binding?.enabled == true) else {
            throw AppFailure(message: "Register this device without delivery before enabling remote reminders.")
        }
        revision += 1; pendingRetirement = binding == nil
        if binding?.enabled == true { mayHaveRemoteAuthority = true }
        return ReminderDeviceCommand(device: id, secret: secret, revision: revision, account: account, binding: binding)
    }
    var retirement: ReminderDeviceCommand? {
        guard valid, pendingRetirement, revision > 0 else { return nil }
        return ReminderDeviceCommand(device: id, secret: secret, revision: revision, account: nil, binding: nil)
    }
}

struct ReminderDeviceCommand: Equatable, Sendable {
    var device: String
    var secret: String
    var revision: Int64
    var account: String?
    var binding: ReminderDeviceBinding?
    var authorityTransition: UUID? = nil
    var localCutoffMS: Int64? = nil
    var valid: Bool {
        guard (authorityTransition == nil && localCutoffMS == nil) ||
                (authorityTransition != nil && binding?.enabled == true && localCutoffMS.map {
                    (0...ReminderDeliveryAuthority.maximumTimestamp).contains($0)
                } == true) else { return false }
        return ReminderDeviceInstallation(id: device, secret: secret, revision: revision).valid && revision > 0 &&
        ((binding == nil && account == nil) || (binding?.valid == true && UUID(uuidString: account ?? "") != nil))
    }
    var path: String {
        if authorityTransition != nil { return "/rest/v1/rpc/taskfold_activate_reminder_device" }
        return "/rest/v1/rpc/taskfold_" + (binding == nil ? "retire" : "register") + "_reminder_device"
    }
    func body() throws -> [String: JSON] {
        guard valid else { throw AppFailure(message: "Invalid device registration command.") }
        var fields: [String: JSON] = ["_device": .string(device), "_secret": .string(secret), "_revision": .number(Double(revision))]
        if let binding { fields["_binding"] = try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(binding)) }
        if let authorityTransition, let localCutoffMS {
            fields["_authority_nonce"] = .string(authorityTransition.uuidString.lowercased())
            fields["_local_cutoff_ms"] = .number(Double(localCutoffMS))
        }
        return fields
    }
}

struct ReminderDeviceReceipt: Codable, Equatable, Sendable {
    var version: Int
    var device: String
    var revision: Int64
    var account: String?
    var state: String
    var enabled: Bool
    var expires_at_ms: Int64
    var authority_version: Int? = nil
    var server_time_ms: Int64? = nil
    var enabled_since_ms: Int64? = nil
    var authority_nonce: UUID? = nil
    func confirms(_ command: ReminderDeviceCommand, now: Date = Date()) -> Bool {
        if let nonce = command.authorityTransition, authority_nonce != nonce { return false }
        guard command.valid, version == 1, device == command.device, revision == command.revision,
              (0...4_133_980_800_000).contains(expires_at_ms) else { return false }
        if let binding = command.binding {
            return state == "registered" && account == command.account && enabled == binding.enabled &&
                Double(expires_at_ms) > now.timeIntervalSince1970 * 1000
        }
        return state == "retired" && account == nil && !enabled
    }
}

/// Durable device-local handoff. An uncertain remote command never becomes permission to
/// schedule the same original event locally. Explicit snoozes remain a separate user action.
struct ReminderDeliveryAuthority: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case local, stoppingLocal, remotePending, remote, stoppingRemote }
    var version = 1
    var account: String
    var installationID: String? = nil
    var phase: Phase = .local
    var transition = UUID()
    var pendingRevision: Int64?
    var mayBeRemote = false
    var drainedAtMS: Int64?
    var localResumeAfterMS: Int64 = 0
    var remoteEnabledSinceMS: Int64?
    var reenableAfterRetirement: Bool? = nil
    static let maximumTimestamp: Int64 = 4_133_980_800_000

    var valid: Bool {
        guard (reenableAfterRetirement != true || phase == .stoppingRemote), version == 1, UUID(uuidString: account)?.uuidString.lowercased() == account,
              installationID.map({ UUID(uuidString: $0)?.uuidString.lowercased() == $0 }) ?? true,
              (0...Self.maximumTimestamp).contains(localResumeAfterMS),
              drainedAtMS.map({ (0...Self.maximumTimestamp).contains($0) }) ?? true,
              remoteEnabledSinceMS.map({ (0...Self.maximumTimestamp).contains($0) }) ?? true,
              pendingRevision.map({ (1...ReminderDeviceInstallation.maximumRevision).contains($0) }) ?? true else { return false }
        switch phase {
        case .local: return !mayBeRemote && pendingRevision == nil && drainedAtMS == nil && remoteEnabledSinceMS == nil
        case .stoppingLocal: return pendingRevision == nil
        case .remotePending: return mayBeRemote && pendingRevision != nil && drainedAtMS != nil
        case .remote: return mayBeRemote && pendingRevision == nil && drainedAtMS != nil && remoteEnabledSinceMS.map { $0 > drainedAtMS! } == true
        case .stoppingRemote: return mayBeRemote
        }
    }
    var wantsRemote: Bool { [.stoppingLocal, .remotePending, .remote].contains(phase) || reenableAfterRetirement == true }

    func choosing(remote: Bool) throws -> Self {
        guard valid else { throw AppFailure(message: "This device's reminder delivery choice could not be read.") }
        if remote == wantsRemote { return self }
        var next = self; next.transition = UUID(); next.pendingRevision = nil; next.reenableAfterRetirement = nil
        if remote { next.phase = .stoppingLocal; next.drainedAtMS = nil }
        else if mayBeRemote { next.phase = .stoppingRemote }
        else { next.phase = .local; next.drainedAtMS = nil; next.remoteEnabledSinceMS = nil }
        return next
    }
    /// A restart or same-account context change unlinks the previous address first.
    /// Preserve explicit consent without exposing a transient local scheduling window.
    func retiring(preservingRemote: Bool) throws -> Self {
        guard valid else { throw AppFailure(message: "This device's reminder delivery choice could not be read.") }
        guard mayBeRemote else { return preservingRemote ? self : try choosing(remote: false) }
        var next = self; next.transition = UUID(); next.pendingRevision = nil
        next.phase = .stoppingRemote; next.reenableAfterRetirement = preservingRemote && wantsRemote ? true : nil
        return next
    }
    /// The caller must save the stopping-local choice before beginning the serialized drain.
    /// Its captured transition prevents a late drain from overriding a newer user choice.
    func quiesced(at milliseconds: Int64, transition expected: UUID) throws -> Self {
        guard valid, phase == .stoppingLocal, transition == expected,
              (0...Self.maximumTimestamp).contains(milliseconds) else { throw CancellationError() }
        var next = self; next.drainedAtMS = milliseconds; return next
    }
    /// Save this candidate before dispatch. If that save fails, no activation may be sent.
    func dispatching(revision: Int64) throws -> Self {
        guard valid, (1...ReminderDeviceInstallation.maximumRevision).contains(revision),
              phase == .stoppingRemote || (phase == .stoppingLocal && drainedAtMS != nil) || phase == .remote || phase == .remotePending else {
            throw AppFailure(message: "Finish switching this device's reminders before continuing.")
        }
        var next = self; next.pendingRevision = revision; next.mayBeRemote = true
        if phase != .stoppingRemote { next.phase = .remotePending }
        return next
    }
    /// A receipt only settles the captured transition and exact dispatched device revision.
    /// Returning a candidate lets the caller persist it before exposing the new authority.
    func accepting(_ receipt: ReminderDeviceReceipt, command: ReminderDeviceCommand,
                   transition expected: UUID, now: Date = Date()) -> Self? {
        guard valid, transition == expected, pendingRevision == command.revision,
              installationID == nil || installationID == command.device,
              command.account == nil || command.account == account,
              let cutoff = receipt.authorityCutoff(for: command, now: now) else { return nil }
        var next = self; next.installationID = command.device
        if phase == .remotePending {
            guard command.account == account, command.binding?.enabled == true,
                  command.authorityTransition == transition, command.localCutoffMS == drainedAtMS,
                  let since = receipt.enabled_since_ms, let drainedAtMS, since > drainedAtMS else { return nil }
            next.phase = .remote; next.remoteEnabledSinceMS = since
        } else if phase == .stoppingRemote {
            guard command.binding == nil || command.binding?.enabled == false else { return nil }
            next.phase = reenableAfterRetirement == true ? .stoppingLocal : .local; next.mayBeRemote = false
            next.reenableAfterRetirement = nil
            next.localResumeAfterMS = max(localResumeAfterMS, cutoff, Int64(now.timeIntervalSince1970 * 1000))
            next.drainedAtMS = nil; next.remoteEnabledSinceMS = nil
        } else { return nil }
        next.pendingRevision = nil
        return next.valid ? next : nil
    }
    func allowsLocalOriginal(account current: String, at date: Date) -> Bool {
        guard valid, date.timeIntervalSince1970.isFinite else { return false }
        if current != account { return true }
        return phase == .local && date.timeIntervalSince1970 * 1000 > Double(localResumeAfterMS)
    }
}

extension ReminderDeviceReceipt {
    /// Legacy registration receipts cannot resolve a handoff. The private server supplies
    /// the cutoff while holding the same device lock used by provider preparation.
    func authorityCutoff(for command: ReminderDeviceCommand, now: Date = Date()) -> Int64? {
        guard now.timeIntervalSince1970.isFinite, (0...Double(ReminderDeliveryAuthority.maximumTimestamp)).contains(now.timeIntervalSince1970 * 1000), authority_version == 1, confirms(command, now: now), let cutoff = server_time_ms,
              (0...ReminderDeliveryAuthority.maximumTimestamp).contains(cutoff) else { return nil }
        if command.binding != nil && cutoff >= expires_at_ms { return nil }
        if command.binding?.enabled == true {
            guard let since = enabled_since_ms, (0...ReminderDeliveryAuthority.maximumTimestamp).contains(since),
                  since < expires_at_ms, since <= cutoff + 300_000 else { return nil }
        } else if enabled_since_ms != nil { return nil }
        return cutoff
    }
}

/// A separate ThisDeviceOnly keychain item, never a workspace or cloud backup. It stores the random
/// binding capability and monotonic fence, not the APNs address (which Apple says to obtain each launch).
enum ReminderDeviceVault {
    static func query(bundle: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: bundle + ".reminder-device", kSecAttrAccount as String: "installation"]
    }
    static func read(bundle: String) throws -> ReminderDeviceInstallation? {
        var q = query(bundle: bundle); q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = try? JSONDecoder().decode(ReminderDeviceInstallation.self, from: data), value.valid else {
            throw AppFailure(message: "This device's secure registration could not be read. It has not been replaced.")
        }
        return value
    }
    static func save(_ value: ReminderDeviceInstallation, bundle: String) throws {
        guard value.valid else { throw AppFailure(message: "Invalid secure device registration.") }
        let data = try JSONEncoder().encode(value), q = query(bundle: bundle)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var created = q; created[kSecValueData as String] = data
            created[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(created as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppFailure(message: "This device's registration revision could not be securely saved.") }
    }
}

/// Device-owned delivery consent is separate from the installation capability and
/// every synchronized workspace. Unknown/corrupt records keep originals suppressed.
enum ReminderAuthorityVault {
    static func query(bundle: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: bundle + ".reminder-authority", kSecAttrAccount as String: "installation"]
    }
    static func read(bundle: String) throws -> ReminderDeliveryAuthority? {
        var q = query(bundle: bundle); q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 4096,
              let value = try? JSONDecoder().decode(ReminderDeliveryAuthority.self, from: data), value.valid else {
            throw AppFailure(message: "This device's reminder delivery choice could not be read. Check remote setup before scheduling task reminders.")
        }
        return value
    }
    static func save(_ value: ReminderDeliveryAuthority, bundle: String) throws {
        guard value.valid else { throw AppFailure(message: "Invalid reminder delivery choice.") }
        let data = try JSONEncoder().encode(value), q = query(bundle: bundle)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var created = q; created[kSecValueData as String] = data
            created[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(created as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppFailure(message: "This device's reminder delivery choice could not be securely saved.") }
    }
}

/// Reserve/save before HTTP dispatch. Lost acknowledgements retry the exact command; new choices
/// always use a higher fence. Storage failure leaves the in-memory revision unchanged.
actor ReminderDeviceCommands {
    private var installation: ReminderDeviceInstallation
    private let save: @Sendable (ReminderDeviceInstallation) throws -> Void
    init(installation: ReminderDeviceInstallation, save: @escaping @Sendable (ReminderDeviceInstallation) throws -> Void) throws {
        guard installation.valid else { throw AppFailure(message: "Invalid secure device registration.") }
        self.installation = installation; self.save = save
    }
    func reserve(account: String?, binding: ReminderDeviceBinding?) throws -> ReminderDeviceCommand {
        var next = installation
        let command = try next.reserve(account: account, binding: binding)
        try save(next); installation = next
        return command
    }
}

extension Backend {
    func reminderDeliveryAvailable(account: String, expectedIncarnation: UUID) async throws -> Bool {
        guard expectedIncarnation == reminderSessionIncarnation, account == session?.user.id else { throw CancellationError() }
        let data = try await request("/rest/v1/rpc/taskfold_reminder_delivery_available", method: "POST", body: [:], authenticated: true, expectedAccount: account)
        guard expectedIncarnation == reminderSessionIncarnation else { throw CancellationError() }
        let value = try JSONDecoder().decode(JSON.self, from: data).object
        guard value["version"] == .number(1), value["account"] == .string(account),
              case .bool(let available)? = value["available"] else { throw AppFailure(message: "Remote reminder availability could not be confirmed.") }
        return available
    }
    /// Existing request generation guards reject old-account and same-account reentry responses.
    func sendReminderDevice(_ command: ReminderDeviceCommand, expectedIncarnation: UUID? = nil) async throws -> ReminderDeviceReceipt {
        guard command.valid else { throw AppFailure(message: "Invalid device registration command.") }
        if let expectedIncarnation, expectedIncarnation != reminderSessionIncarnation { throw CancellationError() }
        if command.binding != nil, command.account != session?.user.id { throw CancellationError() }
        let data = try await request(command.path, method: "POST", body: command.body(),
                                     authenticated: command.binding != nil, expectedAccount: command.account)
        if let expectedIncarnation, expectedIncarnation != reminderSessionIncarnation { throw CancellationError() }
        let receipt = try JSONDecoder().decode(ReminderDeviceReceipt.self, from: data)
        guard receipt.confirms(command) else {
            throw AppFailure(message: "The server did not confirm this device registration. Delivery has not been enabled.")
        }
        return receipt
    }
}

struct ReminderAppIdentity: Equatable, Sendable {
    var platform: ReminderDeviceBinding.Platform
    var bundle: String
    var environment: ReminderDeviceBinding.Environment
    var valid: Bool { bundle == (platform == .ios ? "com.dbakp.taskfold" : "com.dbakp.taskfold.mac") }
    static func signed() -> Self? {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.aps-environment" as CFString, nil) as? String,
              let environment = ReminderDeviceBinding.Environment(rawValue: value), let bundle = Bundle.main.bundleIdentifier else { return nil }
        let identity = Self(platform: .macos, bundle: bundle, environment: environment)
        #elseif os(iOS)
        // SecTask's entitlement reader is not a public iOS API. Read the OS-verified executable's
        // signed XML entitlement blob instead of guessing from DEBUG, receipts or a build setting.
        guard let url = Bundle.main.executableURL, let bundle = Bundle.main.bundleIdentifier,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let environment = ReminderExecutableEntitlements.environment(data, bundle: bundle) else { return nil }
        let identity = Self(platform: .ios, bundle: bundle, environment: environment)
        #else
        return nil
        #endif
        return identity.valid ? identity : nil
    }
}

/// Strict bounded Mach-O/code-signature reader for the current iOS executable. The OS verifies
/// this executable's signature; this reader extracts metadata and is not a signature verifier.
/// Missing/XML-less signatures fail closed. Distribution acceptance must exercise the final binary.
enum ReminderExecutableEntitlements {
    static func environment(_ data: Data, bundle: String) -> ReminderDeviceBinding.Environment? {
        guard bundle == "com.dbakp.taskfold" else { return nil }
        func uint(_ offset: Int, little: Bool = false) -> UInt32? {
            guard offset >= 0, offset <= data.count - 4 else { return nil }
            let bytes = (0..<4).map { UInt32(data[data.startIndex + offset + $0]) }
            return little ? bytes[0] | bytes[1] << 8 | bytes[2] << 16 | bytes[3] << 24 : bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]
        }
        func thin(_ start: Int, _ size: Int) -> String? {
            guard start >= 0, size >= 32, start <= data.count - size,
                  uint(start) == 0xcffaedfe, uint(start + 4, little: true) == 0x0100000c,
                  let count = uint(start + 16, little: true), let commands = uint(start + 20, little: true),
                  count <= 4096, commands <= 1_048_576, Int(commands) <= size - 32 else { return nil }
            var cursor = start + 32; let end = cursor + Int(commands)
            for _ in 0..<count {
                guard cursor <= end - 8, let command = uint(cursor, little: true), let length = uint(cursor + 4, little: true),
                      length >= 8, Int(length) <= end - cursor else { return nil }
                if command == 0x1d { // LC_CODE_SIGNATURE offsets are relative to this architecture slice.
                    guard length == 16, let offset = uint(cursor + 8, little: true), let length = uint(cursor + 12, little: true),
                          length >= 12, length <= 4_194_304, Int(offset) >= 32 + Int(commands), Int(offset) <= size - Int(length) else { return nil }
                    let base = start + Int(offset), limit = base + Int(length)
                    guard uint(base) == 0xfade0cc0, let total = uint(base + 4), let entries = uint(base + 8),
                          total >= 12, total <= length, entries <= 4096, Int(entries) <= (Int(total) - 12) / 8 else { return nil }
                    var result: String?
                    for i in 0..<Int(entries) {
                        guard let type = uint(base + 12 + i * 8), let relative = uint(base + 16 + i * 8),
                              relative >= 12 + entries * 8, relative <= total - 8 else { return nil }
                        if type != 5 { continue } // CSSLOT_ENTITLEMENTS, public XML form.
                        let blob = base + Int(relative)
                        guard result == nil, uint(blob) == 0xfade7171, let bytes = uint(blob + 4), bytes > 8, bytes <= 65_536,
                              Int(bytes) <= min(limit - blob, Int(total - relative)),
                              let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: blob + 8..<blob + Int(bytes)), format: nil) as? [String: Any],
                              let value = plist["aps-environment"] as? String,
                              let app = plist["application-identifier"] as? String,
                              app.hasSuffix("." + bundle), app.count == bundle.count + 11,
                              app.prefix(10).utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else { return nil }
                        result = value
                    }
                    return result
                }
                cursor += Int(length)
            }
            return nil
        }
        guard let magic = uint(0) else { return nil }
        var values: [String] = []
        if magic == 0xcffaedfe { if let value = thin(0, data.count) { values.append(value) } }
        else if magic == 0xcafebabe {
            guard let count = uint(4), count > 0, count <= 32, Int(count) <= (data.count - 8) / 20 else { return nil }
            for i in 0..<Int(count) {
                let arch = 8 + i * 20
                guard let cpu = uint(arch), let offset = uint(arch + 8), let size = uint(arch + 12),
                      Int(offset) >= 8 + Int(count) * 20, Int(offset) <= data.count - Int(size) else { return nil }
                if cpu == 0x0100000c { guard let value = thin(Int(offset), Int(size)) else { return nil }; values.append(value) }
            }
        } else { return nil }
        guard let value = values.first, values.allSatisfy({ $0 == value }) else { return nil }
        return ReminderDeviceBinding.Environment(rawValue: value)
    }
}

struct ReminderDeviceContext: Equatable, Sendable {
    var account: String
    var workspace: UUID
    var session: UUID
    var identity: ReminderAppIdentity
    var timeZone: String
    var permission: ReminderDeviceBinding.Permission
    var valid: Bool { UUID(uuidString: account)?.uuidString.lowercased() == account && identity.valid && TimeZone(identifier: timeZone) != nil && permission != .denied }
}

/// A single main-actor owner reserves installation revisions for enrollment,
/// retirement and delivery handoff. Durable authority precedes queue/network changes.
@MainActor final class ReminderDeviceLifecycle {
    private var installation: ReminderDeviceInstallation
    private let save: (ReminderDeviceInstallation) throws -> Void
    private let send: (ReminderDeviceCommand, UUID?) async throws -> ReminderDeviceReceipt
    private let changed: (String, Bool) -> Void
    private let now: () -> Date
    private let saveAuthority: (ReminderDeliveryAuthority) throws -> Void
    private let authorityChanged: (ReminderDeliveryAuthority) -> Void
    private let quiesceLocal: (ReminderDeliveryAuthority) async throws -> Int64
    private(set) var authority: ReminderDeliveryAuthority?
    private(set) var available = false
    private var context: ReminderDeviceContext?
    private var token: String?
    private var pending: ReminderDeviceCommand?
    private var retirementRequired: Bool
    private var acknowledged: (ReminderDeviceContext, ReminderDeviceBinding, ReminderDeviceReceipt)?
    private var sending: Task<Void, Never>?
    private var quiescing: Task<Void, Never>?
    private var operation = UUID()
    private var online = true
    private var retryAt = Date.distantPast
    private var requestedAt: Date?
    private var tokenFailure = false
    private(set) var status = "Remote delivery is not available yet."
    private(set) var busy = false
    var retirementPending: Bool { retirementRequired || installation.pendingRetirement }
    var needsToken: Bool { context != nil && token == nil && (requestedAt == nil || now().timeIntervalSince(requestedAt!) >= 60) }
    init(installation: ReminderDeviceInstallation, save: @escaping (ReminderDeviceInstallation) throws -> Void,
         send: @escaping (ReminderDeviceCommand, UUID?) async throws -> ReminderDeviceReceipt,
         now: @escaping () -> Date = Date.init, changed: @escaping (String, Bool) -> Void = { _, _ in },
         authority: ReminderDeliveryAuthority? = nil,
         saveAuthority: @escaping (ReminderDeliveryAuthority) throws -> Void = { _ in },
         authorityChanged: @escaping (ReminderDeliveryAuthority) -> Void = { _ in },
         quiesceLocal: @escaping (ReminderDeliveryAuthority) async throws -> Int64 = { _ in throw CancellationError() }) throws {
        guard installation.valid, authority?.valid != false,
              !installation.mayHaveRemoteAuthority || authority != nil,
              authority?.mayBeRemote != true || authority?.installationID == installation.id else { throw AppFailure(message: "This device's secure registration is invalid. It has not been replaced.") }
        self.installation = installation; self.save = save; self.send = send; self.now = now; self.changed = changed
        self.authority = authority; self.saveAuthority = saveAuthority; self.authorityChanged = authorityChanged; self.quiesceLocal = quiesceLocal
        pending = installation.retirement; retirementRequired = installation.revision > 0
    }
    private func report(_ message: String, busy: Bool = false) { status = message; self.busy = busy; changed(message, busy) }
    private var localMessage: String {
        authority?.phase != nil && authority?.phase != .local ? "Task reminders are waiting for the delivery handoff. Focus alerts and existing snoozes stay on this device." : "Reminders continue on this device."
    }
    private func persistAuthority(_ next: ReminderDeliveryAuthority) throws {
        try saveAuthority(next); authority = next; authorityChanged(next)
    }
    private func invalidate() { operation = UUID(); sending?.cancel(); sending = nil; quiescing?.cancel(); quiescing = nil }
    private func reserve(account: String?, binding: ReminderDeviceBinding?) throws -> ReminderDeviceCommand {
        var next = installation; let command = try next.reserve(account: account, binding: binding)
        try save(next); installation = next; return command
    }
    /// Persist retirement intent before the caller clears its session.
    func retire() throws { try retire(preservingRemote: false) }
    private func retire(preservingRemote: Bool) throws {
        invalidate(); context = nil; acknowledged = nil; requestedAt = nil; available = false
        retirementRequired = installation.revision > 0; pending = installation.retirement
        if let authority { try persistAuthority(authority.retiring(preservingRemote: preservingRemote)) }
        if retirementRequired, pending == nil {
            do { pending = try reserve(account: nil, binding: nil) }
            catch { report("Device unlinking could not be saved securely. Retry remote setup."); throw error }
        }
        if let authority, authority.phase == .stoppingRemote, let pending {
            try persistAuthority(authority.dispatching(revision: pending.revision))
        }
        retryAt = .distantPast; pump()
    }
    func update(_ next: ReminderDeviceContext?, online: Bool) throws {
        guard next?.valid != false else { throw AppFailure(message: "This device's registration context is invalid.") }
        self.online = online
        if next != context {
            let preserve = next?.account == authority?.account && next != nil
            try retire(preservingRemote: preserve)
            context = next
        }
        pump()
    }
    func setAvailability(_ value: Bool, account: String, session: UUID) {
        guard context?.account == account, context?.session == session else { return }
        available = value; pump()
    }
    func chooseRemote(_ enabled: Bool) throws {
        if !enabled, context == nil { try retire(); return }
        guard let context, !enabled || available else { throw AppFailure(message: "Remote reminders are not available for this account yet.") }
        if let authority, authority.account != context.account, authority.mayBeRemote { throw AppFailure(message: "Finish unlinking the previous account before changing delivery.") }
        var initial = authority?.account == context.account ? authority! : ReminderDeliveryAuthority(account: context.account)
        if !initial.mayBeRemote { initial.installationID = installation.id }
        let next = try initial.choosing(remote: enabled)
        guard next != authority else { return }
        try persistAuthority(next); invalidate()
        if pending?.binding != nil { pending = nil }
        retryAt = .distantPast; pump()
    }
    func requestedToken() { requestedAt = now(); tokenFailure = false; report("Checking this device's remote registration…", busy: true) }
    func receivedToken(_ bytes: Data) throws {
        guard let address = ReminderDeviceBinding.address(bytes) else { failedToken(); return }
        requestedAt = nil; tokenFailure = false
        if address != token {
            invalidate(); token = address; acknowledged = nil
            if pending?.binding != nil { pending = nil }
        }
        do { try prepare(); pump() }
        catch { report("Device registration could not be saved securely. " + localMessage); throw error }
    }
    func failedToken() {
        invalidate(); token = nil; requestedAt = nil; acknowledged = nil; tokenFailure = true
        if pending?.binding != nil { pending = nil }
        report("Remote registration could not be checked. " + localMessage)
        pump()
    }
    func retry(force: Bool = false) throws {
        if force { retryAt = .distantPast; requestedAt = nil }
        try prepare(); pump()
    }
    private func captureAuthority(for command: inout ReminderDeviceCommand) throws {
        guard let authority else { return }
        if command.binding?.enabled == true {
            let next = try authority.dispatching(revision: command.revision)
            command.authorityTransition = next.transition; command.localCutoffMS = next.drainedAtMS
            try persistAuthority(next)
        } else if authority.phase == .stoppingRemote {
            try persistAuthority(authority.dispatching(revision: command.revision))
        }
    }
    private func prepare() throws {
        if retirementRequired, let authority, authority.mayBeRemote, authority.phase != .stoppingRemote {
            try persistAuthority(authority.retiring(preservingRemote: authority.wantsRemote))
        }
        if pending == nil, retirementRequired {
            var command = try installation.retirement ?? reserve(account: nil, binding: nil)
            try captureAuthority(for: &command); pending = command; return
        }
        guard pending == nil, let context, let token else { return }
        let wantsRemote = authority?.account == context.account && authority?.wantsRemote == true
        let established = acknowledged?.0 == context && acknowledged?.1.token == token
        if wantsRemote && established {
            guard available, let authority, authority.drainedAtMS != nil else { return }
        }
        let enable = wantsRemote && established
        let binding = ReminderDeviceBinding(platform: context.identity.platform, bundle: context.identity.bundle, environment: context.identity.environment,
                                            token: token, time_zone: context.timeZone, permission: context.permission, enabled: enable)
        if authority?.phase != .stoppingRemote, let ack = acknowledged, ack.0 == context, ack.1 == binding, Double(ack.2.expires_at_ms) > now().addingTimeInterval(7 * 86400).timeIntervalSince1970 * 1000 { return }
        var command = try reserve(account: context.account, binding: binding)
        try captureAuthority(for: &command); pending = command
    }
    private func pump() {
        guard sending == nil, quiescing == nil else { return }
        do {
            if let existing = pending, existing.binding == nil, let authority,
               authority.phase == .stoppingRemote, authority.pendingRevision != existing.revision {
                var command = existing; try captureAuthority(for: &command); pending = command
            }
            try prepare()
        } catch { report("Device registration could not be saved securely. " + localMessage); return }
        if pending == nil, let authority, authority.phase == .stoppingLocal, authority.drainedAtMS == nil,
           authority.account == context?.account, available, acknowledged != nil {
            let fence = operation, transition = authority.transition
            report("Switching this device's task reminders…", busy: true)
            quiescing = Task { [weak self] in
                guard let self else { return }
                do {
                    let cutoff = try await self.quiesceLocal(authority)
                    guard self.operation == fence, let current = self.authority, current.transition == transition else { return }
                    try self.persistAuthority(current.quiesced(at: cutoff, transition: transition))
                    self.quiescing = nil; self.pump()
                } catch {
                    guard self.operation == fence else { return }
                    self.quiescing = nil; self.report("The delivery handoff could not finish. Check remote setup to retry. " + self.localMessage)
                }
            }
            return
        }
        guard let command = pending else {
            if authority?.phase == .remote { report("Remote task reminders are enabled on this device. Focus alerts and existing snoozes stay local.") }
            else if authority?.phase != nil && authority?.phase != .local { report(localMessage) }
            else if context == nil { report("Remote delivery is not available yet.") }
            else if token == nil { if requestedAt == nil && !tokenFailure { report("Waiting to check this device's remote registration.") } }
            else if acknowledged != nil { report("Device registration is confirmed. Reminders continue on this device.") }
            return
        }
        guard online else { report(command.binding == nil ? "Device unlinking will retry when online. " + localMessage : "Device registration will retry when online. " + localMessage); return }
        guard now() >= retryAt else { return }
        let fence = operation, captured = context, transition = authority?.transition
        report(command.binding == nil ? "Unlinking the previous remote registration…" : "Confirming this device's remote registration…", busy: true)
        sending = Task { [weak self] in
            guard let self, self.operation == fence, self.pending == command else { return }
            do {
                let receipt = try await self.send(command, command.binding == nil ? nil : captured?.session)
                guard self.operation == fence, self.pending == command else { return }
                guard receipt.confirms(command, now: self.now()) else { throw AppFailure(message: "Unconfirmed device receipt") }
                if let authority = self.authority, authority.pendingRevision == command.revision, let transition {
                    guard let next = authority.accepting(receipt, command: command, transition: transition, now: self.now()) else {
                        throw AppFailure(message: "Unconfirmed reminder delivery handoff")
                    }
                    try self.persistAuthority(next)
                }
                if self.installation.mayHaveRemoteAuthority, command.binding?.enabled != true {
                    guard receipt.authorityCutoff(for: command, now: self.now()) != nil else { throw AppFailure(message: "Unconfirmed reminder retirement") }
                    var next = self.installation; next.mayHaveRemoteAuthority = false
                    try self.save(next); self.installation = next
                }
                if command.binding == nil {
                    var next = self.installation; next.pendingRetirement = false
                    try self.save(next); self.installation = next; self.retirementRequired = false
                } else if let captured, let binding = command.binding, captured == self.context {
                    self.acknowledged = (captured, binding, receipt)
                }
                self.pending = nil; self.sending = nil; self.retryAt = .distantPast; self.pump()
            } catch {
                guard self.operation == fence, self.pending == command else { return }
                self.sending = nil; self.retryAt = self.now().addingTimeInterval(30)
                if self.authority?.phase == .remotePending {
                    self.report("Remote delivery is waiting for confirmation. Focus alerts and existing snoozes stay local.")
                } else if self.authority?.phase == .stoppingRemote {
                    self.report("Local delivery is waiting for confirmation. Focus alerts and existing snoozes stay local.")
                } else {
                    self.report(command.binding == nil ? "Device unlinking is waiting for confirmation. It will retry when opened or online. " + self.localMessage : "Device registration is waiting for confirmation. " + self.localMessage)
                }
            }
        }
    }
}
