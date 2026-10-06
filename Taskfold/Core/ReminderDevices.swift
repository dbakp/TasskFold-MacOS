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
    var valid: Bool {
        UUID(uuidString: id)?.uuidString.lowercased() == id && secret.utf8.count == 64 &&
        secret.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } &&
        (0...Self.maximumRevision).contains(revision)
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
        revision += 1
        return ReminderDeviceCommand(device: id, secret: secret, revision: revision, account: account, binding: binding)
    }
}

struct ReminderDeviceCommand: Equatable, Sendable {
    var device: String
    var secret: String
    var revision: Int64
    var account: String?
    var binding: ReminderDeviceBinding?
    var valid: Bool {
        ReminderDeviceInstallation(id: device, secret: secret, revision: revision).valid && revision > 0 &&
        ((binding == nil && account == nil) || (binding?.valid == true && UUID(uuidString: account ?? "") != nil))
    }
    var path: String { "/rest/v1/rpc/taskfold_" + (binding == nil ? "retire" : "register") + "_reminder_device" }
    func body() throws -> [String: JSON] {
        guard valid else { throw AppFailure(message: "Invalid device registration command.") }
        var fields: [String: JSON] = ["_device": .string(device), "_secret": .string(secret), "_revision": .number(Double(revision))]
        if let binding { fields["_binding"] = try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(binding)) }
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
    func confirms(_ command: ReminderDeviceCommand, now: Date = Date()) -> Bool {
        guard command.valid, version == 1, device == command.device, revision == command.revision,
              (0...4_133_980_800_000).contains(expires_at_ms) else { return false }
        if let binding = command.binding {
            return state == "registered" && account == command.account && enabled == binding.enabled &&
                Double(expires_at_ms) > now.timeIntervalSince1970 * 1000
        }
        return state == "retired" && account == nil && !enabled
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
    /// Existing request generation guards reject old-account and same-account reentry responses.
    func sendReminderDevice(_ command: ReminderDeviceCommand) async throws -> ReminderDeviceReceipt {
        guard command.valid else { throw AppFailure(message: "Invalid device registration command.") }
        if command.binding != nil, command.account != session?.user.id { throw CancellationError() }
        let data = try await request(command.path, method: "POST", body: command.body(),
                                     authenticated: command.binding != nil, expectedAccount: command.account)
        let receipt = try JSONDecoder().decode(ReminderDeviceReceipt.self, from: data)
        guard receipt.confirms(command) else {
            throw AppFailure(message: "The server did not confirm this device registration. Delivery has not been enabled.")
        }
        return receipt
    }
}
