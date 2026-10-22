import Foundation
import CryptoKit
import Security

enum AutomationScope: String, CaseIterable, Codable, Sendable {
    case read = "tasks:read", create = "tasks:create", update = "tasks:update", complete = "tasks:complete", delete = "tasks:delete"
    var title: String {
        switch self {
        case .read: return "Read tasks"
        case .create: return "Create tasks"
        case .update: return "Edit task details"
        case .complete: return "Complete tasks"
        case .delete: return "Delete tasks"
        }
    }
}

/// Transient enrollment state only: intentionally not Codable. A retry uses the
/// same ID/hash; neither snapshots nor portable backups may contain the secret.
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
