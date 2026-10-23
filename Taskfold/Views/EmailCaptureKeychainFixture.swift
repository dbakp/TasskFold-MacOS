#if DEBUG
import Foundation
import Security

/// Exact isolated host only: real device-only vault and Backend; synthetic
/// intercepted HTTP metadata. No provider, hosted Auth or real task mutation.
enum EmailCaptureKeychainFixture {
    static let origin = "https://email-management.test"
    static let a = "f0e4cafe-0000-4000-8000-000000000001", b = "f0e4cafe-0000-4000-8000-000000000002"
    static var enabled: Bool { EmailCaptureFixture.enabled && ProcessInfo.processInfo.arguments.contains("--email-keychain-testing") }
    static var account: String { ProcessInfo.processInfo.arguments.contains("--email-keychain-other-account") ? b : a }
    static var service: String { (Bundle.main.bundleIdentifier ?? "invalid") + ".email-addresses" }
    static var root: URL { URL.applicationSupportDirectory.appendingPathComponent("EmailKeychainFixture", isDirectory: true) }
    static var orphanCleanupRequested: Bool { enabled && ProcessInfo.processInfo.arguments.contains("--email-hosted-orphan-cleanup") }
    private static func orphanAccounts() throws -> [String] {
        let values = ProcessInfo.processInfo.arguments.filter { $0.hasPrefix("--email-orphan-account=") }.map { String($0.dropFirst("--email-orphan-account=".count)) }
        guard !values.isEmpty, values.count <= 16, Set(values).count == values.count, values.allSatisfy(EmailCaptureValue.id) else { throw EmailCaptureValue.invalid }
        return values
    }
    @MainActor private static func orphanOrigin() throws -> String {
        #if targetEnvironment(simulator)
        guard Bundle.main.bundleIdentifier == "com.dbakp.taskfold.workflowtestswebhooks" else { throw EmailCaptureValue.invalid }
        let origin = try Store.shared.backend.accountRemovalOrigin
        guard origin.hasPrefix("https://"), origin.hasSuffix(".supabase.co"), !origin.contains("zqxflydiyfjeedqvyova") else { throw EmailCaptureValue.invalid }
        return origin
        #else
        throw EmailCaptureValue.invalid
        #endif
    }
    @MainActor static var hostedCleanupEnabled: Bool {
        #if targetEnvironment(simulator)
        return Bundle.main.bundleIdentifier == "com.dbakp.taskfold.workflowtestswebhooks" && ProcessInfo.processInfo.arguments.contains("--email-hosted-testing") && EmailCaptureAvailability.enabled
        #else
        return false
        #endif
    }
    @MainActor static func removeHostedPrivateSetup() async -> String {
        guard hostedCleanupEnabled else { return "Cleanup unavailable" }
        let store = Store.shared, account = Store.shared.userID
        guard store.signedIn, !store.localMode, let email = store.backend.session?.user.email,
              email.hasPrefix("taskfold-email-"), email.hasSuffix("@example.invalid"),
              let origin = try? store.backend.accountRemovalOrigin,
              origin.hasPrefix("https://"), origin.hasSuffix(".supabase.co"), !origin.contains("zqxflydiyfjeedqvyova") else { return "Cleanup unavailable" }
        do {
            let saved = try await store.emailAddressVault.recovery(account: account, origin: origin)
            guard saved.addresses.isEmpty, saved.pending == nil else { return "Revoke test addresses first" }
            try await store.emailAddressVault.removeAccount(account, origin: origin)
            let empty = try await store.emailAddressVault.recovery(account: account, origin: origin)
            guard empty.addresses.isEmpty, empty.pending == nil else { return "Cleanup failed" }
            return "Private test setup cleared"
        } catch { return "Cleanup failed" }
    }
    @MainActor static func makeModel() async throws -> EmailCaptureModel {
        precondition(enabled)
        let actual = Store.shared.emailAddressVault
        if orphanCleanupRequested {
            let origin = try orphanOrigin()
            for id in try orphanAccounts() { try await actual.removeAccount(id, origin: origin) }
        }
        if ProcessInfo.processInfo.arguments.contains("--email-keychain-reset") {
            try await actual.removeAccount(a, origin: origin); try await actual.removeAccount(b, origin: origin)
            let aa = try await actual.recovery(account: a, origin: origin), bb = try await actual.recovery(account: b, origin: origin)
            guard aa.pending == nil, bb.pending == nil, aa.addresses.isEmpty, bb.addresses.isEmpty else { throw EmailCaptureValue.invalid }
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
        let vault: EmailAddressVault
        if ProcessInfo.processInfo.arguments.contains("--email-keychain-fail-confirm-write") {
            vault = EmailAddressVault(io: EmailKeychainWriteFault(actual: CalendarKeychainIO(service: service)), coordinationDirectory: URL.applicationSupportDirectory.appendingPathComponent("EmailAddressLocks", isDirectory: true))
        } else { vault = actual }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [EmailKeychainHTTP.self]
        let session = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: ["access_token": "synthetic-email-" + account, "refresh_token": "synthetic-refresh", "expires_at": Date().addingTimeInterval(3600).timeIntervalSince1970, "user": ["id": account, "email": "workshop@example.invalid"]]))
        let backend = Backend(configuration: ["URL": origin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        return EmailCaptureModel(account: account, origin: origin, service: backend, vault: vault, isCurrent: { true })
    }
    @MainActor static func audit() async throws -> String {
        precondition(enabled)
        if orphanCleanupRequested {
            let ids = try orphanAccounts(), origin = try orphanOrigin()
            for id in ids {
                let value = try await Store.shared.emailAddressVault.recovery(account: id, origin: origin)
                guard value.addresses.isEmpty, value.pending == nil else { throw EmailCaptureValue.invalid }
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "email-addresses-v1." + id, kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: true]
                guard SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound else { throw EmailCaptureValue.invalid }
            }
            return "orphan=cleared accounts=\(ids.count) policy=absent"
        }
        let saved = try await Store.shared.emailAddressVault.recovery(account: account, origin: origin)
        let server = try EmailKeychainHTTP.snapshot()
        let rows = server["rows"]?.object ?? [:], requests = server["requests"]?.object ?? [:]
        let drafts = saved.addresses + (saved.pending?.draft.map { [$0] } ?? [])
        for draft in drafts {
            guard draft.account == account, draft.origin == origin else { throw EmailCaptureValue.invalid }
            guard requests[draft.id] == .object(draft.body), rows[draft.id]?.object["fixture_account"] == .string(account) else { throw EmailCaptureValue.invalid }
        }
        let secrets = drafts.map { Data(String($0.address.prefix(64)).utf8) }
        let manager = FileManager.default
        if manager.fileExists(atPath: root.path) {
            let urls = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey])
            for url in urls {
                let bytes = try Data(contentsOf: url)
                guard bytes.count <= 65536, secrets.allSatisfy({ bytes.range(of: $0) == nil }) else { throw EmailCaptureValue.invalid }
            }
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "email-addresses-v1." + account, kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: true, kSecReturnAttributes as String: true]
        var item: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &item)
        let policy: String
        if status == errSecItemNotFound { guard saved.addresses.isEmpty, saved.pending == nil else { throw EmailCaptureValue.invalid }; policy = "absent" }
        else {
            guard status == errSecSuccess, let attributes = item as? [String: Any], attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
                  (attributes[kSecAttrSynchronizable as String] as? Bool ?? false) == false else { throw EmailCaptureValue.invalid }; policy = "device-only"
        }
        let counters = server["counters"]?.object ?? [:]
        let ownRows = rows.values.filter { $0.object["fixture_account"] == .string(account) }.count
        return "account=\(account == a ? "A" : "B") saved=\(saved.addresses.count) pending=\(saved.pending?.action ?? "none") requests=\(counters[account]?.integer ?? 0) created=\(ownRows) total=\(rows.count) identity=match files=clean policy=\(policy)"
    }
}
private final class EmailKeychainWriteFault: CalendarSecureItemIO, @unchecked Sendable {
    let actual: CalendarKeychainIO
    private let lock = NSLock(); private var writes = 0
    init(actual: CalendarKeychainIO) { self.actual = actual }
    func read(key: String) throws -> Data? { try actual.read(key: key) }
    func remove(key: String) throws { try actual.remove(key: key) }
    func write(_ data: Data, key: String) throws {
        lock.lock(); writes += 1; let fail = writes == 2; lock.unlock()
        if fail { throw CalendarReadFailure.unavailable }; try actual.write(data, key: key)
    }
}
private final class EmailKeychainHTTP: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    private static var file: URL { EmailCaptureKeychainFixture.root.appendingPathComponent("server.json") }
    static func snapshot() throws -> [String: JSON] {
        lock.lock(); defer { lock.unlock() }; return try read()
    }
    private static func read() throws -> [String: JSON] {
        guard FileManager.default.fileExists(atPath: file.path) else { return ["rows": .object([:]), "requests": .object([:]), "counters": .object([:]), "lost": .bool(false)] }
        let bytes = try Data(contentsOf: file); guard bytes.count <= 65536 else { throw EmailCaptureValue.invalid }; return try JSONDecoder().decode([String: JSON].self, from: bytes)
    }
    private static func write(_ state: [String: JSON]) throws {
        let bytes = try JSONEncoder().encode(state); guard bytes.count <= 65536 else { throw EmailCaptureValue.invalid }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try bytes.write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    override func startLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        do {
            guard EmailCaptureKeychainFixture.enabled, request.url?.absoluteString == EmailCaptureKeychainFixture.origin + "/functions/v1/email-routes", request.httpMethod == "POST", request.value(forHTTPHeaderField: "X-Taskfold-Email") == "2", !request.httpShouldHandleCookies else { throw URLError(.unsupportedURL) }
            let owner = String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst("Bearer synthetic-email-".count))
            guard [EmailCaptureKeychainFixture.a, EmailCaptureKeychainFixture.b].contains(owner), request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-email-" + owner else { throw EmailCaptureValue.invalid }
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); guard count >= 0, data.count + count <= 8192 else { throw EmailCaptureValue.invalid }; if count == 0 { break }; data.append(buffer, count: count) } }
            guard data.count <= 8192, let input = try? JSONDecoder().decode([String: JSON].self, from: data), case .object(let body) = input["body"] else { throw EmailCaptureValue.invalid }
            let action = input["action"]?.text ?? ""; var state = try Self.read(), rows = state["rows"]?.object ?? [:], requests = state["requests"]?.object ?? [:], counters = state["counters"]?.object ?? [:]
            var reply: [String: JSON] = ["protocol": .number(2), "account": .string(owner)]
            if action == "list" { reply["available"] = .bool(true); reply["domain"] = .string("mail.example.invalid"); reply["routes"] = .array(rows.values.filter { $0.object["fixture_account"] == .string(owner) }.map { .object($0.object.filter { $0.key != "fixture_account" }) }) }
            else if action == "create" {
                let id = body["id"]?.text ?? ""
                guard EmailCaptureValue.id(id), body["domain"] == .string("mail.example.invalid"), request.value(forHTTPHeaderField: "X-Taskfold-Email-Domain") == "mail.example.invalid", body["alias_hash"]?.text.count == 64 else { throw EmailCaptureValue.invalid }
                if let old = requests[id] { guard old == .object(body), rows[id]?.object["fixture_account"] == .string(owner) else { throw EmailCaptureValue.invalid } }
                else {
                    requests[id] = .object(body)
                    rows[id] = .object(["id": .string(id), "alias_domain": body["domain"]!, "name": body["name"]!, "project_id": body["project_id"]!, "sender_email": .string("workshop@example.invalid"), "state": .string("active"), "revision": .number(1), "created_at": .string("2026-10-23T16:00:00Z"), "updated_at": .string("2026-10-23T16:00:00Z"), "accept_after": .string("2026-10-23T16:00:00Z"), "rotated_to": .null, "fixture_account": .string(owner)])
                }
                counters[owner] = .number(Double((counters[owner]?.integer ?? 0) + 1)); state["rows"] = .object(rows); state["requests"] = .object(requests); state["counters"] = .object(counters)
                let lose = ProcessInfo.processInfo.arguments.contains("--email-keychain-lose-create-once") && state["lost"] != .bool(true)
                if lose { state["lost"] = .bool(true) }; try Self.write(state)
                if lose { throw URLError(.networkConnectionLost) }
                reply["route"] = .object(rows[id]!.object.filter { $0.key != "fixture_account" })
            } else { throw EmailCaptureValue.invalid }
            let bytes = try JSONEncoder().encode(reply)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}
#endif
