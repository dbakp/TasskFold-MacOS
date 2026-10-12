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

/// Explain transport interruptions without presenting internal networking codes.
/// This describes already-persisted sync work, not an unsaved editor draft.
enum SyncStatus {
    struct Presentation {
        let title: String
        let symbol: String
    }
    /// A prior successful sync never overrides a current interruption or unsent work.
    static func presentation(local: Bool, online: Bool, syncing: Bool, needsAttention: Bool, pending: Int, lastSync: Date?) -> Presentation {
        if local { return Presentation(title: "Saved on this device", symbol: "internaldrive") }
        if !online { return Presentation(title: "Offline · saved on this device", symbol: "wifi.slash") }
        if syncing { return Presentation(title: "Syncing…", symbol: "arrow.triangle.2.circlepath") }
        if needsAttention { return Presentation(title: "Sync needs attention", symbol: "exclamationmark.icloud") }
        if pending > 0 { return Presentation(title: "\(pending) \(pending == 1 ? "change" : "changes") waiting to sync", symbol: "icloud") }
        if let lastSync { return Presentation(title: "Synced \(lastSync.formatted(date: .omitted, time: .shortened))", symbol: "checkmark.icloud") }
        return Presentation(title: "Waiting to sync", symbol: "icloud")
    }
    static func failureMessage(_ error: Error) -> String {
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain {
            switch failure.code {
            case URLError.notConnectedToInternet.rawValue:
                return "You're offline. Changes saved on this device will sync when you reconnect."
            case URLError.networkConnectionLost.rawValue:
                return "The connection was interrupted. Your saved changes are still on this device. Try syncing again."
            case URLError.timedOut.rawValue:
                return "Sync took too long. Your saved changes are still on this device. Try again."
            default: break
            }
        }
        return "Sync paused: \(error.localizedDescription)"
    }
}

enum SessionPersistence {
    private static let writer = DispatchQueue(label: "com.taskfold.session-persistence", qos: .utility)
    /// Await durability without holding the UI thread. One queue orders save and sign-out.
    static func perform(_ operation: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.async {
                do { try operation(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

enum SecureSession {
    static func saveAsync(_ session: Session?) async throws {
        try await SessionPersistence.perform { try save(session) }
    }
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
        guard let session else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AppFailure(message: "Could not securely clear your session (\(status)).")
            }
            return
        }
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


#if DEBUG
/// A pending sign-in for isolated UI checks. No request is sent to a real service.
private final class AuthenticationWaitingHTTP: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
/// A controlled connection outage for the isolated native Mac recovery walk.
private final class ContinuityDisconnectedHTTP: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
#endif

#if DEBUG
/// Holds only a disposable account's completed upload for a native account-switch walk.
/// The real request has already used its original owner/path/JWT; no response is fabricated.
private enum ProfileUploadResponseTestHold {
    static func wait(account: String, email: String?, objectPath: String) async throws {
        let bundle = Bundle.main.bundleIdentifier
        guard bundle == "com.dbakp.taskfold.assigneepatterntests" || bundle == "com.dbakp.taskfold.mac.p0uitests",
              ProcessInfo.processInfo.arguments.contains("--profile-upload-response-hold"),
              email == "taskfold-continuity-" + account + "@example.invalid",
              let path = ProcessInfo.processInfo.environment["TASKFOLD_PROFILE_RESPONSE_HOLD"] else { return }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let prefix = "taskfold-profile-upload-"
        guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
              path == name || path == "/private/tmp/" + name else { return }
        // A basename uses the app's own sandbox; legacy absolute paths serve Simulator runners.
        let marker: URL
        if path == name {
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            let directory = support.appendingPathComponent("Taskfold", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            marker = directory.appendingPathComponent(name)
        } else { marker = URL(fileURLWithPath: path) }
        let ready = marker.appendingPathExtension("ready")
        let release = marker.appendingPathExtension("release")
        let finished = marker.appendingPathExtension("finished")
        try Data(objectPath.utf8).write(to: ready, options: .atomic)
        defer { try? Data().write(to: finished, options: .atomic) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while !FileManager.default.fileExists(atPath: release.path) {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
#endif

@MainActor
final class Backend: NSObject {
    var session: Session?
    #if DEBUG
    private var discardedTodoistResponse = false
    #endif
    #if canImport(UIKit)
    private var authSession: ASWebAuthenticationSession?
    #endif
    private let http: URLSession
    private let saveSession: (Session?) async throws -> Void
    private var sessionGeneration = UUID()
    private var sessionTransition = false
    private var authenticationAttempt: UUID?
    private var cancelAuthenticationBrowser: (() -> Void)?
    /// Changes on sign-in/sign-out, and stays stable across ordinary token refresh.
    var reminderSessionIncarnation: UUID { sessionGeneration }
    private var refreshTask: Task<Session, Error>?
    private var refreshID: UUID?
    private let config: [String: String]
    init(configuration: [String: String]? = nil, http: URLSession = .shared,
         session: Session? = SecureSession.read(),
         persistSession: @escaping (Session?) async throws -> Void = SecureSession.saveAsync) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--auth-response-wait-testing"),
           ProcessInfo.processInfo.arguments.contains("--live-auth-ui-test"),
           ["com.dbakp.taskfold.mac.backupcanceltests", "com.dbakp.taskfold.backupcanceltests"].contains(Bundle.main.bundleIdentifier ?? "") {
            let waiting = URLSessionConfiguration.ephemeral
            waiting.protocolClasses = [AuthenticationWaitingHTTP.self]
            self.http = URLSession(configuration: waiting)
        } else if ProcessInfo.processInfo.arguments.contains("--continuity-offline"),
           Bundle.main.bundleIdentifier == "com.dbakp.taskfold.mac.p0signeduitests",
           let user = session?.user,
           user.id == "9a8bfc3d-42ec-4c89-8f1d-c830b2215152",
           user.email == "taskfold-continuity-" + user.id + "@example.invalid" {
            let disconnected = URLSessionConfiguration.ephemeral
            disconnected.protocolClasses = [ContinuityDisconnectedHTTP.self]
            self.http = URLSession(configuration: disconnected)
        } else { self.http = http }
        #else
        self.http = http
        #endif
        self.session = session
        self.saveSession = persistSession
        if let configuration { config = configuration }
        else if let url = Bundle.main.url(forResource: "Backend", withExtension: "plist"),
                let data = try? Data(contentsOf: url),
                let value = try? PropertyListDecoder().decode([String: String].self, from: data) { config = value }
        else { config = [:] }
        super.init()
    }
    /// A response belongs to the sign-in that started it, not whichever workspace is current later.
    func beginAuthentication(cancelBrowser: (() -> Void)? = nil) -> UUID {
        cancelAuthentication()
        let attempt = UUID(); authenticationAttempt = attempt
        cancelAuthenticationBrowser = cancelBrowser
        return attempt
    }
    func requireAuthentication(_ attempt: UUID) throws {
        guard authenticationAttempt == attempt else { throw CancellationError() }
    }
    func endAuthentication(_ attempt: UUID) {
        guard authenticationAttempt == attempt else { return }
        cancelAuthentication()
    }
    private func cancelAuthentication() {
        authenticationAttempt = nil
        let cancel = cancelAuthenticationBrowser; cancelAuthenticationBrowser = nil
        cancel?()
    }
    func clearSession() async throws {
        cancelAuthentication()
        let generation = UUID(); sessionGeneration = generation; sessionTransition = true
        defer { if sessionGeneration == generation { sessionTransition = false } }
        refreshTask?.cancel(); refreshTask = nil; refreshID = nil
        try await saveSession(nil)
        guard sessionGeneration == generation else { throw CancellationError() }
        session = nil
    }
    func accept(_ next: Session) async throws {
        cancelAuthentication()
        let generation = UUID(); sessionGeneration = generation; sessionTransition = true
        defer { if sessionGeneration == generation { sessionTransition = false } }
        refreshTask?.cancel(); refreshTask = nil; refreshID = nil
        try await saveSession(next)
        guard sessionGeneration == generation else { throw CancellationError() }
        session = next
    }
    var baseURL: String { config["URL"] ?? "" }
    func request(_ path: String, method: String = "GET", body: [String: JSON]? = nil,
                 authenticated: Bool = true, extra: [String: String] = [:], retryAuthentication: Bool = true,
                 expectedAccount: String? = nil) async throws -> Data {
        guard !authenticated || !sessionTransition else { throw CancellationError() }
        let generation = sessionGeneration, owner = expectedAccount ?? session?.user.id
        if authenticated { try await refreshIfNeeded() }
        if authenticated, sessionTransition || generation != sessionGeneration || session?.user.id != owner { throw CancellationError() }
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
        if authenticated, generation != sessionGeneration || session?.user.id != owner { throw CancellationError() }
        if authenticated, (response as? HTTPURLResponse)?.statusCode == 401, retryAuthentication {
            try await refreshIfNeeded(force: true)
            return try await self.request(path, method: method, body: body, authenticated: true, extra: extra, retryAuthentication: false, expectedAccount: owner)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let error = (try? JSONDecoder().decode(Record.self, from: data)) ?? Record()
            let message = ["msg", "message", "error_description", "error"].map { error.string($0) }.first { !$0.isEmpty }
            throw AppFailure(message: message ?? "The server could not complete this request. Please try again.")
        }
        #if DEBUG
        // Lose one actual successful response in the authorized disposable provider walk.
        // Never available in Release, ordinary bundles, other accounts or previews.
        // Later saves on this Backend instance use the real response normally.
        let isolatedBundle = Bundle.main.bundleIdentifier
        let replayAccount = session?.user.id == "316d6706-449c-4ab8-8480-db12e7d92642"
            && session?.user.email?.hasPrefix("taskfold-todoist-readonly-") == true
            && (isolatedBundle == "com.dbakp.taskfold.providercontinuitytests" || isolatedBundle == "com.dbakp.taskfold.mac.p0localuitests" || isolatedBundle == "com.dbakp.taskfold.mac.p0signeduitests")
        let firstImportAccount = session?.user.id == "00befe6f-4ab3-4fe0-b346-3c262a298c24"
            && session?.user.email == "taskfold-todoist-first-53c1dae7-7745-49e7-b473-7e509756047d@example.invalid"
            && (isolatedBundle == "com.dbakp.taskfold.firstimporttests" || isolatedBundle == "com.dbakp.taskfold.mac.p0firstimporttests")
        if !discardedTodoistResponse, path == "/functions/v1/import-todoist", method == "POST",
           body?["preview"] == .bool(false),
           replayAccount || firstImportAccount,
           ProcessInfo.processInfo.arguments.contains("--todoist-discard-save-response"),
           let marker = ProcessInfo.processInfo.environment["TASKFOLD_IMPORT_RESPONSE_RECEIPT"],
           marker.hasPrefix("taskfold-import-response-"),
           UUID(uuidString: String(marker.dropFirst("taskfold-import-response-".count))) != nil {
            let receipt = try JSONDecoder().decode(Record.self, from: data)
            guard receipt["success"].flag else { return data }
            var proof: [String: JSON] = ["httpStatus": .number(Double(http.statusCode)),
                "realResponseDiscarded": .bool(true)]
            for key in TodoistImportFlow.resultKeys { proof[key] = receipt[key] }
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Taskfold", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(Record(proof)).write(to: directory.appendingPathComponent(marker + ".json"), options: .atomic)
            discardedTodoistResponse = true
            throw URLError(.networkConnectionLost)
        }
        #endif
        return data
    }
    func refreshIfNeeded(force: Bool = false) async throws {
        guard let current = session else { throw AppFailure(message: "Please sign in again.") }
        guard force || current.expires_at < Date().timeIntervalSince1970 + 90 else { return }
        let generation = sessionGeneration
        if let refreshTask {
            let next = try await refreshTask.value
            guard generation == sessionGeneration, session?.user.id == current.user.id, next.user.id == current.user.id else { throw CancellationError() }
            session = next; return
        }
        let id = UUID(); refreshID = id
        let task = Task { @MainActor in
            let data = try await self.request("/auth/v1/token?grant_type=refresh_token", method: "POST",
                body: ["refresh_token": .string(current.refresh_token)], authenticated: false)
            let next = try JSONDecoder().decode(Session.self, from: data)
            guard generation == self.sessionGeneration, self.session?.user.id == current.user.id, next.user.id == current.user.id else { throw CancellationError() }
            try await self.saveSession(next)
            guard generation == self.sessionGeneration, self.session?.user.id == current.user.id else { throw CancellationError() }
            return next
        }
        refreshTask = task
        defer { if refreshID == id { refreshTask = nil; refreshID = nil } }
        let next = try await task.value
        guard generation == sessionGeneration, session?.user.id == current.user.id else { throw CancellationError() }
        session = next
    }
    /// Hydrates metadata discarded by older app versions without requiring another sign-in.
    func refreshUser() async throws {
        let generation = sessionGeneration
        let data = try await request("/auth/v1/user")
        let user = try JSONDecoder().decode(Session.User.self, from: data)
        guard generation == sessionGeneration, var current = session, current.user.id == user.id else { throw CancellationError() }
        current.user = user
        try await accept(current)
    }

    func signIn(email: String, password: String, signup: Bool) async throws -> Bool {
        let attempt = beginAuthentication(); defer { endAuthentication(attempt) }
        let path = signup ? "/auth/v1/signup" : "/auth/v1/token?grant_type=password"
        let data = try await request(path, method: "POST", body: ["email": .string(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()), "password": .string(password)], authenticated: false)
        try requireAuthentication(attempt)
        guard let next = try? JSONDecoder().decode(Session.self, from: data) else {
            if signup { return false }
            throw AppFailure(message: "The sign-in response was incomplete. Please try again.")
        }
        try await accept(next)
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
        guard authSession == nil else { throw CancellationError() }
        let attempt = beginAuthentication { [weak self] in self?.authSession?.cancel(); self?.authSession = nil }
        defer { endAuthentication(attempt) }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AppFailure(message: "Could not start secure sign-in.") }
        let verifier = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var components = URLComponents(string: baseURL + "/auth/v1/authorize")!
        components.queryItems = [URLQueryItem(name: "provider", value: "google"), URLQueryItem(name: "redirect_to", value: "taskfold://auth/callback"), URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "s256")]
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            authSession = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: "taskfold") { url, error in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? AppFailure(message: "Sign-in was cancelled.")) }
            }
            authSession?.presentationContextProvider = self
            if authSession?.start() != true { continuation.resume(throwing: AppFailure(message: "Could not open sign-in.")) }
        }
        try requireAuthentication(attempt)
        let code = try OAuthCallback.code(from: callback)
        let data = try await request("/auth/v1/token?grant_type=pkce", method: "POST", body: ["auth_code": .string(code), "code_verifier": .string(verifier)], authenticated: false)
        try requireAuthentication(attempt)
        let next = try JSONDecoder().decode(Session.self, from: data)
        try await accept(next)
    }
    #endif
    #if canImport(UIKit)
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? UIWindow()
    }
    #endif
    func rows(_ table: String) async throws -> [Record] {
        if table == TaskActivity.table {
            let owner = session?.user.id, generation = sessionGeneration
            var result: [Record] = []; var cursor: Int64 = 0
            while true {
                guard generation == sessionGeneration, session?.user.id == owner else { throw CancellationError() }
                let data = try await request(TaskActivityPage.query(after: cursor), expectedAccount: owner)
                guard generation == sessionGeneration, session?.user.id == owner else { throw CancellationError() }
                let page = try JSONDecoder().decode([Record].self, from: data)
                cursor = try TaskActivityPage.cursor(page, after: cursor); result += page
                if page.count < 500 { return result }
            }
        }
        // PostgREST caps responses; paginate so large task libraries are not truncated.
        var result: [Record] = []; var offset = 0
        while true {
            let data = try await request("/rest/v1/\(table)?select=*&order=id&offset=\(offset)&limit=500")
            let page = try JSONDecoder().decode([Record].self, from: data)
            result += page
            if page.count < 500 { return result }; offset += page.count
        }
    }
    @discardableResult func send(_ change: Mutation, expectedAccount: String? = nil) async throws -> Record? {
        guard change.table != TaskActivity.table, change.table != TaskActivity.epochTable else { throw AppFailure(message: "Activity history is read-only.") }
        let expectedOwner = expectedAccount ?? session?.user.id
        guard expectedOwner == session?.user.id else { throw CancellationError() }
        if change.organizationOrder != nil || change.method == "ORDER" {
            guard OrganizationOrder.valid(change), let command = change.organizationOrder else {
                throw AppFailure(message: "This saved ordering command needs a supported app before syncing.")
            }
            let data = try await request("/rest/v1/rpc/taskfold_order_organization", method: "POST", body: [
                "_table": .string(change.table), "_ids": .array(command.ids.map(JSON.string)),
                "_project": command.projectID.map(JSON.string) ?? .null,
                "_action": .string(change.id.uuidString.lowercased())], expectedAccount: expectedOwner)
            let rows = try JSONDecoder().decode([Record].self, from: data)
            return Record(["organization_order_rows": .array(rows.map { .object($0.fields) })])
        }
        if change.table == FocusSessionChange.table {
            guard let account = session?.user.id, FocusSessionChange.valid(change, account: account), let baseline = change.baseline else {
                throw AppFailure(message: "TASKFOLD_FOCUS_CONFLICT: Review this Focus session before replacing synced state.")
            }
            let data = try await request("/rest/v1/rpc/taskfold_set_focus_session", method: "POST", body: [
                "_base": .object(baseline), "_action": change.fields["action_id"]!, "_state": change.fields["state"]!], expectedAccount: account)
            let saved = try JSONDecoder().decode(Record.self, from: data)
            guard FocusSessionChange.validRow(saved, account: account),
                  saved["revision"] == change.fields["revision"], saved["action_id"] == change.fields["action_id"],
                  saved["state"] == change.fields["state"] else {
                throw AppFailure(message: "The server did not confirm this Focus session. It remains saved on this device.")
            }
            return saved
        }
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
                "_id": .string(change.recordID), "_base": .object(baseline), "_changes": .object(change.fields)], expectedAccount: expectedOwner)
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
                let data = try await request("/rest/v1/tasks?id=eq.\(escaped)&select=id", expectedAccount: expectedOwner)
                if try JSONDecoder().decode([Record].self, from: data).isEmpty { return nil }
                throw AppFailure(message: "TASKFOLD_CONFLICT: Review this older queued deletion before removing a synced task.")
            }
            let data = try await request("/rest/v1/rpc/taskfold_delete_task", method: "POST", body: [
                "_id": .string(change.recordID), "_base": .object(baseline)], expectedAccount: expectedOwner)
            guard try JSONDecoder().decode(Bool.self, from: data) else {
                throw AppFailure(message: "The server did not confirm this deletion. Your change is saved on this device.")
            }
            return nil
        }
        if change.table == ReminderSnooze.table, change.method == "POST", change.insertOnly != true {
            let automatic = change.reminderPreferenceField == ReminderAutomatic.field
            let settings = change.fields["settings"] ?? .null
            let minutes = automatic ? ReminderAutomatic.minutes(settings) : ReminderSnooze.minutes(settings)
            guard let owner = expectedOwner, change.recordID == ReminderSnooze.recordID,
                  change.fields["user_id"]?.text.lowercased() == owner.lowercased(),
                  [nil, "snooze_minutes", ReminderAutomatic.field].contains(change.reminderPreferenceField),
                  ReminderSnooze.validDocument(settings), let minutes else {
                throw AppFailure(message: "This reminder preference needs a supported delay before syncing.")
            }
            let rpc = automatic ? "taskfold_set_automatic_reminder" : "taskfold_set_reminder_snooze"
            let data = try await request("/rest/v1/rpc/" + rpc, method: "POST", body: ["_minutes": .number(Double(minutes))], expectedAccount: expectedOwner)
            let saved = try JSONDecoder().decode(Record.self, from: data)
            guard ReminderSnooze.row([saved], account: owner) != nil, ReminderSnooze.validDocument(saved["settings"]),
                  (automatic ? ReminderAutomatic.minutes(saved["settings"]) : ReminderSnooze.minutes(saved["settings"])) == minutes else {
                throw AppFailure(message: "The server did not confirm this reminder preference. Your choice is saved on this device.")
            }
            return saved
        }
        let conflictKey = ["favorites", "view_preferences", "view_orders", ReminderSnooze.table].contains(change.table) ? "user_id,id" : "id"
        let escapedID = change.recordID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? change.recordID
        let query = change.method == "POST" ? "?on_conflict=\(conflictKey)" : "?id=eq.\(escapedID)"
        let data = try await request("/rest/v1/\(change.table)\(query)", method: change.method,
            body: change.method == "DELETE" ? nil : change.fields,
            extra: ["Prefer": change.method == "POST" ? (change.insertOnly == true ? "handling=strict,resolution=ignore-duplicates,missing=default,return=representation" : "resolution=merge-duplicates,return=representation") : "return=representation"], expectedAccount: expectedOwner)
        if change.method == "POST", change.insertOnly == true {
            let rows = try JSONDecoder().decode([Record].self, from: data)
            if let saved = rows.first(where: { $0.id.lowercased() == change.recordID.lowercased() && $0.string("user_id") == change.fields["user_id"]?.text }) { return saved }
            let owner = (change.fields["user_id"]?.text ?? "").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            guard !owner.isEmpty else { throw AppFailure(message: "This new item has no workspace owner.") }
            let existing = try await request("/rest/v1/\(change.table)?id=eq.\(escapedID)&user_id=eq.\(owner)&select=*", expectedAccount: expectedOwner)
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
    func uploadAvatar(_ data: Data, expectedAccount: String) async throws -> String {
        let generation = sessionGeneration
        guard !expectedAccount.isEmpty, session?.user.id == expectedAccount else { throw CancellationError() }
        try await refreshIfNeeded()
        guard generation == sessionGeneration, session?.user.id == expectedAccount else { throw CancellationError() }
        guard let session else { throw AppFailure(message: "Sign in to change your photo.") }
        let path = "\(session.user.id)/\(UUID().uuidString).jpg"
        guard let url = URL(string: baseURL + "/storage/v1/object/avatars/" + path) else { throw AppFailure(message: "Invalid storage URL.") }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = data
        request.setValue(config["Key"], forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.access_token)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await http.data(for: request)
        #if DEBUG
        try await ProfileUploadResponseTestHold.wait(account: session.user.id, email: session.user.email, objectPath: path)
        #endif
        guard generation == sessionGeneration, self.session?.user.id == expectedAccount else { throw CancellationError() }
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
        let subscriptions: [JSON] = ["tasks", "projects", "sections", "labels", "project_collaborators", "profiles", "saved_views", "favorites", "view_preferences", "view_orders", ReminderSnooze.table, "focus_sessions"].map { .object(["event": .string("*"), "schema": .string("public"), "table": .string($0)]) }
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
