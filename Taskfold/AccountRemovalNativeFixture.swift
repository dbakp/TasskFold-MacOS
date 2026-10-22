#if DEBUG
import Foundation
import SwiftUI
import Darwin
import Security

/// Reserved synthetic native Store proof. Never enabled by a normal/release bundle.
enum AccountRemovalNativeFixture {
    static let owner = "f084cafe-1111-4111-8111-000000000001"
    static let other = "f084cafe-1111-4111-8111-000000000002"
    static var enabled: Bool {
        ["com.dbakp.taskfold.workflowtestsremoval", "com.dbakp.taskfold.mac.workflowtestsremoval"].contains(Bundle.main.bundleIdentifier ?? "") &&
            ProcessInfo.processInfo.arguments.contains("--account-removal-proof")
    }
    static var expiring: Bool { ProcessInfo.processInfo.arguments.contains("--account-removal-expired") }
    static var switching: Bool { ProcessInfo.processInfo.arguments.contains("--account-removal-switch") }
    static var root: URL { URL.applicationSupportDirectory.appendingPathComponent("RemovalNativeProof-" + (Bundle.main.bundleIdentifier ?? "isolated"), isDirectory: true) }
    static var dataRoot: URL { root.appendingPathComponent("Taskfold", isDirectory: true) }
    static var sharedRoot: URL { root.appendingPathComponent("Shared", isDirectory: true) }
    static var result: URL { root.appendingPathComponent("result.json") }
    static func backupKeyStatus(_ account: String) -> OSStatus {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.taskfold.recovery.v1", kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true]
        var result: CFTypeRef?; return SecItemCopyMatching(query as CFDictionary, &result)
    }
    static func session(_ account: String) throws -> Session {
        try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: ["access_token": account == owner ? "synthetic-A" : "synthetic-B", "refresh_token": "synthetic-refresh", "expires_at": Date().addingTimeInterval(3600).timeIntervalSince1970, "user": ["id": account, "email": "taskfold-removal-proof@example.invalid"]]))
    }
    @MainActor static func backend() -> Backend {
        precondition(enabled)
        if ProcessInfo.processInfo.arguments.contains("--account-removal-proof-reset") { try? FileManager.default.removeItem(at: root) }
        UserDefaults.standard.set(false, forKey: "localMode")
        for account in [owner, other] {
            UserDefaults.standard.set(false, forKey: "dailyBackups." + account)
            UserDefaults.standard.removeObject(forKey: "accountRemoval.pending." + account)
        }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AccountRemovalProofHTTP.self]
        return Backend(configuration: ["URL": "https://removal-native.test", "Key": "synthetic-public"], http: URLSession(configuration: configuration), session: try! session(owner))
    }
}
final class AccountRemovalProofHTTP: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requests = 0
    private static var refreshes = 0
    static var refreshCount: Int { lock.lock(); defer { lock.unlock() }; return refreshes }
    private static var held: AccountRemovalProofHTTP?
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    static func release() { lock.lock(); let pending = held; held = nil; lock.unlock(); pending?.reply(200) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        if AccountRemovalNativeFixture.enabled, AccountRemovalNativeFixture.expiring, request.url?.host == "removal-native.test",
           request.url?.path == "/auth/v1/token", request.url?.query == "grant_type=refresh_token" {
            Self.lock.lock(); Self.refreshes += 1; Self.lock.unlock()
            var next = try! AccountRemovalNativeFixture.session(AccountRemovalNativeFixture.owner); next.access_token = "synthetic-A-renewed"
            reply(200, body: try! JSONEncoder().encode(next)); return
        }
        let permitted = request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-A" ||
            AccountRemovalNativeFixture.expiring && request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-A-renewed"
        guard AccountRemovalNativeFixture.enabled, request.url?.host == "removal-native.test",
              request.url?.path == "/functions/v1/delete-account", request.httpMethod == "POST", permitted else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        Self.lock.lock(); Self.requests += 1; let index = Self.requests
        if AccountRemovalNativeFixture.switching && index == 1 { Self.held = self; Self.lock.unlock(); return }
        Self.lock.unlock()
        reply(index == 1 && AccountRemovalNativeFixture.expiring ? 401 : !AccountRemovalNativeFixture.switching && index == 1 ? 503 : 200)
    }
    private func reply(_ status: Int, body: Data? = nil) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data((status == 200 ? "{\"deleted\":true}" : "{\"error\":\"Synthetic interrupted reply\"}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
struct AccountRemovalProofView: View {
    @Environment(Store.self) private var store
    var body: some View {
        Text("Verifying isolated account cleanup…").padding().task {
            await store.runAccountRemovalNativeProof()
            Darwin.exit(0)
        }
    }
}
#endif
