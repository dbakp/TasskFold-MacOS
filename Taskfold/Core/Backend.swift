import Foundation
import Security
import CryptoKit
#if canImport(UIKit)
import AuthenticationServices
import UIKit
#endif

struct AppFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum SecureSession {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.taskfold.ios.session", kSecAttrAccount as String: "supabase"]
    static func read() -> Session? {
        var q = query; q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }
    static func save(_ session: Session?) throws {
        guard let session else { SecItemDelete(query as CFDictionary); return }
        let data = try JSONEncoder().encode(session)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppFailure(message: "Could not securely save your session (\(status)).") }
    }
}

@MainActor
final class Backend: NSObject {
    var session: Session?
    #if canImport(UIKit)
    private var authSession: ASWebAuthenticationSession?
    #endif
    private let http: URLSession
    private let saveSession: (Session?) throws -> Void
    private var sessionGeneration = UUID()
    private var refreshTask: Task<Session, Error>?
    private let config: [String: String]
    init(configuration: [String: String]? = nil, http: URLSession = .shared,
         session: Session? = SecureSession.read(),
         persistSession: @escaping (Session?) throws -> Void = SecureSession.save) {
        self.http = http
        self.session = session
        self.saveSession = persistSession
        if let configuration { config = configuration }
        else if let url = Bundle.main.url(forResource: "Backend", withExtension: "plist"),
                let data = try? Data(contentsOf: url),
                let value = try? PropertyListDecoder().decode([String: String].self, from: data) { config = value }
        else { config = [:] }
        super.init()
    }
    func clearSession() throws {
        sessionGeneration = UUID()
        refreshTask?.cancel(); refreshTask = nil
        try saveSession(nil); session = nil
    }
    private func accept(_ next: Session) throws {
        try saveSession(next)
        session = next
    }
    var baseURL: String { config["URL"] ?? "" }
    func request(_ path: String, method: String = "GET", body: [String: JSON]? = nil,
                 authenticated: Bool = true, extra: [String: String] = [:], retryAuthentication: Bool = true) async throws -> Data {
        if authenticated { try await refreshIfNeeded() }
        guard let url = URL(string: baseURL + path), url.scheme == "https" else {
            throw AppFailure(message: "The Supabase configuration is missing.")
        }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = path == "/functions/v1/import-todoist" ? 240 : 30
        request.setValue(config["Key"], forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            guard let session else { throw AppFailure(message: "Sign in to sync your tasks.") }
            request.setValue("Bearer \(session.access_token)", forHTTPHeaderField: "Authorization")
        }
        extra.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let (data, response) = try await http.data(for: request)
        if authenticated, (response as? HTTPURLResponse)?.statusCode == 401, retryAuthentication {
            try await refreshIfNeeded(force: true)
            return try await self.request(path, method: method, body: body, authenticated: true, extra: extra, retryAuthentication: false)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let error = (try? JSONDecoder().decode(Record.self, from: data)) ?? Record()
            let message = ["msg", "message", "error_description", "error"].map { error.string($0) }.first { !$0.isEmpty }
            throw AppFailure(message: message ?? "The server could not complete this request. Please try again.")
        }
        return data
    }
    func refreshIfNeeded(force: Bool = false) async throws {
        guard let current = session else { throw AppFailure(message: "Please sign in again.") }
        guard force || current.expires_at < Date().timeIntervalSince1970 + 90 else { return }
        if let refreshTask { session = try await refreshTask.value; return }
        let generation = sessionGeneration
        let task = Task { @MainActor in
            let data = try await self.request("/auth/v1/token?grant_type=refresh_token", method: "POST",
                body: ["refresh_token": .string(current.refresh_token)], authenticated: false)
            let next = try JSONDecoder().decode(Session.self, from: data)
            guard generation == self.sessionGeneration else { throw CancellationError() }
            try self.saveSession(next)
            return next
        }
        refreshTask = task
        defer { refreshTask = nil }
        session = try await task.value
    }
    /// Hydrates metadata discarded by older app versions without requiring another sign-in.
    func refreshUser() async throws {
        let generation = sessionGeneration
        let data = try await request("/auth/v1/user")
        let user = try JSONDecoder().decode(Session.User.self, from: data)
        guard generation == sessionGeneration, var current = session, current.user.id == user.id else { throw CancellationError() }
        current.user = user
        try accept(current)
    }

    func signIn(email: String, password: String, signup: Bool) async throws -> Bool {
        let path = signup ? "/auth/v1/signup" : "/auth/v1/token?grant_type=password"
        let data = try await request(path, method: "POST", body: ["email": .string(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()), "password": .string(password)], authenticated: false)
        guard let next = try? JSONDecoder().decode(Session.self, from: data) else {
            if signup { return false }
            throw AppFailure(message: "The sign-in response was incomplete. Please try again.")
        }
        try accept(next)
        return true
    }
    /// Changes the signed-in user's email (Supabase sends a confirmation) or password.
    func updateAccount(email: String? = nil, password: String? = nil) async throws {
        var body: [String: JSON] = [:]
        if let email { body["email"] = .string(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        if let password { body["password"] = .string(password) }
        guard !body.isEmpty else { return }
        _ = try await request("/auth/v1/user", method: "PUT", body: body)
    }
    func sendPasswordReset(email: String) async throws {
        _ = try await request("/auth/v1/recover", method: "POST", body: ["email": .string(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())], authenticated: false)
    }
    /// Asks the backend to delete the account and its data. Requires the `delete-account` edge function.
    func deleteAccount() async throws {
        _ = try await request("/functions/v1/delete-account", method: "POST", body: [:])
    }
    #if canImport(UIKit)
    func google() async throws {
        guard authSession == nil else { return }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AppFailure(message: "Could not start secure sign-in.") }
        let verifier = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var components = URLComponents(string: baseURL + "/auth/v1/authorize")!
        components.queryItems = [URLQueryItem(name: "provider", value: "google"), URLQueryItem(name: "redirect_to", value: "taskfold://auth/callback"), URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "s256")]
        defer { authSession?.cancel(); authSession = nil }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            authSession = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: "taskfold") { url, error in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? AppFailure(message: "Sign-in was cancelled.")) }
            }
            authSession?.presentationContextProvider = self
            if authSession?.start() != true { continuation.resume(throwing: AppFailure(message: "Could not open sign-in.")) }
        }
        let code = try OAuthCallback.code(from: callback)
        let data = try await request("/auth/v1/token?grant_type=pkce", method: "POST", body: ["auth_code": .string(code), "code_verifier": .string(verifier)], authenticated: false)
        let next = try JSONDecoder().decode(Session.self, from: data)
        try accept(next)
    }
    #endif
    #if canImport(UIKit)
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? UIWindow()
    }
    #endif
    func rows(_ table: String) async throws -> [Record] {
        // PostgREST caps responses; paginate so large task libraries are not truncated.
        var result: [Record] = []; var offset = 0
        while true {
            let data = try await request("/rest/v1/\(table)?select=*&order=id&offset=\(offset)&limit=500")
            let page = try JSONDecoder().decode([Record].self, from: data)
            result += page
            if page.count < 500 { return result }; offset += page.count
        }
    }
    @discardableResult func send(_ change: Mutation) async throws -> Record? {
        // Both native clients protect edits with the same server-side baseline merge.
        if change.table == "tasks", change.method == "PATCH" {
            // Missing baselines cannot safely distinguish a clear from no change.
            // Keep old queued work for explicit review, without sending a blind PATCH.
            guard let baseline = change.baseline, change.fields.keys.allSatisfy({ baseline[$0] != nil }) else {
                throw AppFailure(message: "TASKFOLD_CONFLICT: This older queued edit needs review before replacing synced values.")
            }
            if TaskCompletionRevision.touches(change.fields) {
                guard case .number(let version)? = baseline["completion_version"], version.isFinite, version >= 0, version.rounded(.down) == version else {
                    throw AppFailure(message: "TASKFOLD_CONFLICT: Review this older completion before replacing synced state.")
                }
            }
            let data = try await request("/rest/v1/rpc/taskfold_patch_task", method: "POST", body: [
                "_id": .string(change.recordID), "_base": .object(baseline), "_changes": .object(change.fields)])
            let saved = try JSONDecoder().decode(Record.self, from: data)
            guard saved.id.lowercased() == change.recordID.lowercased() else {
                throw AppFailure(message: "The server did not confirm this edit. Your change is saved on this device.")
            }
            return saved
        }
        if change.table == "tasks", change.method == "DELETE" {
            guard let baseline = change.baseline, baseline["id"] != nil, baseline["user_id"] != nil, baseline["title"] != nil else {
                // An old queue can outlive the task. Only visible, existing rows need review.
                let escaped = change.recordID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? change.recordID
                let data = try await request("/rest/v1/tasks?id=eq.\(escaped)&select=id")
                if try JSONDecoder().decode([Record].self, from: data).isEmpty { return nil }
                throw AppFailure(message: "TASKFOLD_CONFLICT: Review this older queued deletion before removing a synced task.")
            }
            let data = try await request("/rest/v1/rpc/taskfold_delete_task", method: "POST", body: [
                "_id": .string(change.recordID), "_base": .object(baseline)])
            guard try JSONDecoder().decode(Bool.self, from: data) else {
                throw AppFailure(message: "The server did not confirm this deletion. Your change is saved on this device.")
            }
            return nil
        }
        let conflictKey = ["favorites", "view_preferences", "view_orders"].contains(change.table) ? "user_id,id" : "id"
        let escapedID = change.recordID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? change.recordID
        let query = change.method == "POST" ? "?on_conflict=\(conflictKey)" : "?id=eq.\(escapedID)"
        let data = try await request("/rest/v1/\(change.table)\(query)", method: change.method,
            body: change.method == "DELETE" ? nil : change.fields,
            extra: ["Prefer": change.method == "POST" ? (change.insertOnly == true ? "handling=strict,resolution=ignore-duplicates,missing=default,return=representation" : "resolution=merge-duplicates,return=representation") : "return=representation"])
        if change.method == "POST", change.insertOnly == true {
            let rows = try JSONDecoder().decode([Record].self, from: data)
            if let saved = rows.first(where: { $0.id.lowercased() == change.recordID.lowercased() && $0.string("user_id") == change.fields["user_id"]?.text }) { return saved }
            let owner = (change.fields["user_id"]?.text ?? "").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            guard !owner.isEmpty else { throw AppFailure(message: "This new item has no workspace owner.") }
            let existing = try await request("/rest/v1/\(change.table)?id=eq.\(escapedID)&user_id=eq.\(owner)&select=*")
            let found = try JSONDecoder().decode([Record].self, from: existing)
            guard found.contains(where: { $0.id == change.recordID && $0.string("user_id") == change.fields["user_id"]?.text }) else {
                throw AppFailure(message: "The server could not confirm this new item. It remains saved on this device.")
            }
            return found.first
        }
        if change.method != "DELETE" {
            let rows = try JSONDecoder().decode([Record].self, from: data)
            guard rows.contains(where: { $0.id == change.recordID }) else {
                throw AppFailure(message: "This record is no longer available or you do not have permission to edit it. Your change is saved on this device.")
            }
            return rows.first { $0.id == change.recordID }
        }
        return nil
    }
    func uploadAvatar(_ data: Data) async throws -> String {
        try await refreshIfNeeded()
        guard let session else { throw AppFailure(message: "Sign in to change your photo.") }
        let path = "\(session.user.id)/\(UUID().uuidString).jpg"
        guard let url = URL(string: baseURL + "/storage/v1/object/avatars/" + path) else { throw AppFailure(message: "Invalid storage URL.") }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = data
        request.setValue(config["Key"], forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.access_token)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await http.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw AppFailure(message: "Your photo could not be uploaded. Please try again.") }
        return baseURL + "/storage/v1/object/public/avatars/" + path
    }

}

extension Backend {
    /// Supabase Realtime signals a refresh; the REST snapshot remains the source of truth.
    func watchChanges(onChange: @escaping @MainActor () async -> Void) async throws {
        try await refreshIfNeeded()
        guard let session else { return }
        var components = URLComponents(string: baseURL.replacingOccurrences(of: "https://", with: "wss://") + "/realtime/v1/websocket")!
        components.queryItems = [URLQueryItem(name: "apikey", value: config["Key"]), URLQueryItem(name: "vsn", value: "1.0.0")]
        let socket = URLSession.shared.webSocketTask(with: components.url!)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        let subscriptions: [JSON] = ["tasks", "projects", "sections", "labels", "project_collaborators", "profiles", "saved_views", "favorites", "view_preferences", "view_orders"].map { .object(["event": .string("*"), "schema": .string("public"), "table": .string($0)]) }
        let join: [String: JSON] = ["topic": .string("realtime:taskfold-ios"), "event": .string("phx_join"), "ref": .string("1"), "join_ref": .string("1"), "payload": .object(["access_token": .string(session.access_token), "config": .object(["postgres_changes": .array(subscriptions)])])]
        try await socket.send(.string(String(decoding: JSONEncoder().encode(join), as: UTF8.self)))
        let heartbeat = Task { @MainActor in
            var reference = 2
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(25))
                // Reconnect before token expiry instead of leaving a stale authorized channel open.
                if (self.session?.expires_at ?? 0) < Date().timeIntervalSince1970 + 90 {
                    socket.cancel(with: .goingAway, reason: nil); return
                }
                let body: [String: JSON] = ["topic": .string("phoenix"), "event": .string("heartbeat"), "payload": .object([:]), "ref": .string("\(reference)")]
                try await socket.send(.string(String(decoding: JSONEncoder().encode(body), as: UTF8.self))); reference += 1
            }
        }
        defer { heartbeat.cancel() }
        try await withTaskCancellationHandler {
            while !Task.isCancelled {
                let message = try await socket.receive()
                let data: Data
                switch message { case .data(let bytes): data = bytes; case .string(let text): data = Data(text.utf8); @unknown default: continue }
                let event = try JSONDecoder().decode(Record.self, from: data)
                if event.string("event") == "postgres_changes" { await onChange() }
                if event.string("event") == "phx_error" { throw AppFailure(message: "Realtime connection interrupted.") }
            }
        } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }
}

#if canImport(UIKit)
extension Backend: ASWebAuthenticationPresentationContextProviding {}
#endif
