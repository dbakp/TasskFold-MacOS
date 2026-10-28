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

/// A rejected session requires explicit sign-in; never surface server details.
struct AccountSessionAuthorizationRequired: LocalizedError {
    var errorDescription: String? { "Sign in again to continue." }
}

/// An explicit sign-in can renew only this account, server and session incarnation.
struct AccountReauthentication: Identifiable, Sendable {
    let id = UUID()
    let account: String
    let origin: String
    let incarnation: UUID
}
struct AccountReauthenticationMismatch: LocalizedError {
    var errorDescription: String? { "Use the same Taskfold account to continue." }
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
        if error is AccountSessionAuthorizationRequired {
            return "Sign in again to sync. Your changes are saved on this device."
        }
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

/// Private geometry RPCs never follow a redirect, including a same-host redirect.
/// This delegate is immutable and holds no credentials or request state.
private final class LocationHandoffRedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = LocationHandoffRedirectRefusal()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class Backend: NSObject {
    var session: Session?
    #if DEBUG
    private var discardedTodoistResponse = false
    private var discardedWebhookCreateResponse = false
    #endif
    #if canImport(UIKit)
    private var authSession: ASWebAuthenticationSession?
    #endif
    private let http: URLSession
    private let saveSession: (Session?) async throws -> Void
    private var sessionGeneration = UUID()
    private var sessionTransition = false
    private var authenticationAttempt: UUID?
    private var reauthenticationAttempt: (context: UUID, attempt: UUID)?
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
        } else if ProcessInfo.processInfo.arguments.contains("--shared-capture-offline"),
           Bundle.main.bundleIdentifier == "com.dbakp.taskfold.mac.workflowtestssharecloud",
           let user = session?.user, UUID(uuidString: user.id) != nil,
           let email = user.email, email.hasPrefix("taskfold-share-capture-"), email.hasSuffix("@example.invalid"),
           UUID(uuidString: String(email.dropFirst("taskfold-share-capture-".count).dropLast("@example.invalid".count))) != nil {
            // Only an authenticated disposable account in the exact isolated Debug app.
            // Real Auth/HTTP is used before and after this controlled transport outage.
            let disconnected = URLSessionConfiguration.ephemeral
            disconnected.protocolClasses = [ContinuityDisconnectedHTTP.self]
            self.http = URLSession(configuration: disconnected)
        } else if ProcessInfo.processInfo.arguments.contains("--continuity-offline"),
           ["com.dbakp.taskfold.mac.p0signeduitests", "com.dbakp.taskfold.mac.backupcanceltests"].contains(Bundle.main.bundleIdentifier ?? ""),
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
        reauthenticationAttempt = nil
        let cancel = cancelAuthenticationBrowser; cancelAuthenticationBrowser = nil
        cancel?()
    }
    func reauthenticationContext(account: String) throws -> AccountReauthentication {
        guard !sessionTransition, session?.user.id == account, AutomationKey.canonicalID(account) else { throw CancellationError() }
        return AccountReauthentication(account:account,origin:try accountRemovalOrigin,incarnation:sessionGeneration)
    }
    func requireReauthentication(_ context: AccountReauthentication?) throws {
        guard let context else { return }
        guard !sessionTransition, session?.user.id == context.account, sessionGeneration == context.incarnation,
              context.origin == (try accountRemovalOrigin) else { throw CancellationError() }
    }
    func startAuthentication(reauthenticating context: AccountReauthentication?, cancelBrowser: (() -> Void)? = nil) throws -> UUID {
        try requireReauthentication(context)
        let attempt = beginAuthentication(cancelBrowser:cancelBrowser)
        if let context { reauthenticationAttempt = (context.id,attempt) }
        return attempt
    }
    func cancelReauthentication(_ context: AccountReauthentication) {
        guard let current = reauthenticationAttempt, current.context == context.id, current.attempt == authenticationAttempt else { return }
        cancelAuthentication()
    }
    func acceptAuthentication(_ next: Session, attempt: UUID, reauthenticating context: AccountReauthentication?, willCommit: (() -> Void)? = nil) async throws {
        try requireAuthentication(attempt)
        try requireReauthentication(context)
        if let context, next.user.id != context.account { throw AccountReauthenticationMismatch() }
        try Task.checkCancellation()
        // From this point the existing serialized credential write must finish.
        // The sheet disables cancellation for that short commit phase.
        willCommit?()
        try await accept(next)
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
                 expectedAccount: String? = nil, workflowReadLimit: Int? = nil) async throws -> Data {
        guard !authenticated || !sessionTransition else { throw CancellationError() }
        let generation = sessionGeneration, owner = expectedAccount ?? session?.user.id
        if authenticated { try await refreshIfNeeded() }
        if authenticated, sessionTransition || generation != sessionGeneration || session?.user.id != owner { throw CancellationError() }
        guard let url = URL(string: baseURL + path), url.scheme == "https" else {
            throw AppFailure(message: "The Supabase configuration is missing.")
        }
        if let workflowReadLimit { guard (1...4_200_000).contains(workflowReadLimit) else { throw TeamWorkflowRunCommand.invalid } }
        let workflowRead = workflowReadLimit != nil
        let workflowRun = path == "/rest/v1/rpc/taskfold_team_workflow_run"
        let templateLibrary = path == "/rest/v1/rpc/taskfold_team_templates"
        let projectAdoption = path == "/rest/v1/rpc/taskfold_team_project_adoption"
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = path == "/functions/v1/import-todoist" ? 240 : 30
        request.setValue(config["Key"], forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            guard let session else { throw AppFailure(message: "Sign in to sync your tasks.") }
            request.setValue("Bearer \(session.access_token)", forHTTPHeaderField: "Authorization")
        }
        extra.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if workflowRead || workflowRun || projectAdoption || templateLibrary || path.hasPrefix("/rest/v1/rpc/taskfold_location_handoff_") || ["/functions/v1/automation-keys", "/functions/v1/automation-webhooks", "/functions/v1/email-routes", "/rest/v1/rpc/taskfold_team_task_recipients", "/rest/v1/rpc/taskfold_team_projects", "/rest/v1/rpc/taskfold_edit_team_task", "/rest/v1/rpc/taskfold_team_task_lifecycle", "/rest/v1/rpc/taskfold_team_task_batch", "/rest/v1/rpc/taskfold_complete_team_task", "/rest/v1/rpc/taskfold_complete_team_tasks", "/rest/v1/rpc/taskfold_review_team_completion_batch", "/rest/v1/rpc/taskfold_cancel_team_completion_batch", "/rest/v1/rpc/taskfold_review_team_completion", "/rest/v1/rpc/taskfold_cancel_team_completion", "/rest/v1/rpc/taskfold_retire_team_provisional", "/rest/v1/rpc/taskfold_copy_team_draft", "/rest/v1/rpc/taskfold_workspace_boundary", "/rest/v1/rpc/taskfold_teams"].contains(path) {
            request.timeoutInterval = 25
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.httpShouldHandleCookies = false
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let data: Data, response: URLResponse
        if workflowRead || workflowRun || projectAdoption || templateLibrary || path.hasPrefix("/rest/v1/rpc/taskfold_location_handoff_") || ["/functions/v1/automation-keys", "/functions/v1/automation-webhooks", "/functions/v1/email-routes", "/rest/v1/rpc/taskfold_team_task_recipients", "/rest/v1/rpc/taskfold_team_projects", "/rest/v1/rpc/taskfold_edit_team_task", "/rest/v1/rpc/taskfold_team_task_lifecycle", "/rest/v1/rpc/taskfold_team_task_batch", "/rest/v1/rpc/taskfold_complete_team_task", "/rest/v1/rpc/taskfold_complete_team_tasks", "/rest/v1/rpc/taskfold_review_team_completion_batch", "/rest/v1/rpc/taskfold_cancel_team_completion_batch", "/rest/v1/rpc/taskfold_review_team_completion", "/rest/v1/rpc/taskfold_cancel_team_completion", "/rest/v1/rpc/taskfold_retire_team_provisional", "/rest/v1/rpc/taskfold_copy_team_draft", "/rest/v1/rpc/taskfold_workspace_boundary", "/rest/v1/rpc/taskfold_teams"].contains(path) {
            let (bytes, incoming) = try await http.bytes(for: request, delegate: LocationHandoffRedirectRefusal.shared)
            let limit = ["/rest/v1/rpc/taskfold_review_team_completion_batch", "/rest/v1/rpc/taskfold_cancel_team_completion_batch"].contains(path) ? 8_500_000 : path == "/rest/v1/rpc/taskfold_complete_team_tasks" ? 4_300_000 : workflowReadLimit ?? (workflowRun ? 1_000_000 : projectAdoption || templateLibrary ? 3_000_000 : path == "/rest/v1/rpc/taskfold_team_task_recipients" ? 350_000 : path == "/rest/v1/rpc/taskfold_team_projects" ? 1_000_000 : ["/rest/v1/rpc/taskfold_workspace_boundary", "/rest/v1/rpc/taskfold_teams"].contains(path) ? 4_000_000 : ["/rest/v1/rpc/taskfold_retire_team_provisional", "/rest/v1/rpc/taskfold_copy_team_draft"].contains(path) ? 2_000_000 : ["/rest/v1/rpc/taskfold_review_team_completion_batch", "/rest/v1/rpc/taskfold_cancel_team_completion_batch", "/rest/v1/rpc/taskfold_review_team_completion", "/rest/v1/rpc/taskfold_cancel_team_completion", "/rest/v1/rpc/taskfold_retire_team_provisional", "/rest/v1/rpc/taskfold_copy_team_draft", "/rest/v1/rpc/taskfold_workspace_boundary", "/rest/v1/rpc/taskfold_teams"].contains(path) ? 1_000_000 : ["/functions/v1/email-routes", "/rest/v1/rpc/taskfold_complete_team_task", "/rest/v1/rpc/taskfold_review_team_completion_batch", "/rest/v1/rpc/taskfold_cancel_team_completion_batch", "/rest/v1/rpc/taskfold_review_team_completion", "/rest/v1/rpc/taskfold_cancel_team_completion", "/rest/v1/rpc/taskfold_retire_team_provisional", "/rest/v1/rpc/taskfold_copy_team_draft", "/rest/v1/rpc/taskfold_workspace_boundary", "/rest/v1/rpc/taskfold_teams"].contains(path) ? 512000 : (["/functions/v1/automation-keys", "/functions/v1/automation-webhooks", "/rest/v1/rpc/taskfold_team_task_recipients", "/rest/v1/rpc/taskfold_team_projects", "/rest/v1/rpc/taskfold_edit_team_task", "/rest/v1/rpc/taskfold_team_task_lifecycle", "/rest/v1/rpc/taskfold_team_task_batch", "/rest/v1/rpc/taskfold_complete_team_task", "/rest/v1/rpc/taskfold_complete_team_tasks", "/rest/v1/rpc/taskfold_review_team_completion_batch", "/rest/v1/rpc/taskfold_cancel_team_completion_batch", "/rest/v1/rpc/taskfold_review_team_completion", "/rest/v1/rpc/taskfold_cancel_team_completion", "/rest/v1/rpc/taskfold_retire_team_provisional", "/rest/v1/rpc/taskfold_copy_team_draft", "/rest/v1/rpc/taskfold_workspace_boundary", "/rest/v1/rpc/taskfold_teams"].contains(path) ? 256000 : LocationHandoffResponse.maximumBytes))
            var body = Data()
            do {
                guard incoming.expectedContentLength <= Int64(limit) else { throw AppFailure(message: templateLibrary ? "The team template response is too large. Refresh to try again." : projectAdoption ? "The project review is too large. Your saved request is unchanged." : ["/functions/v1/automation-keys", "/functions/v1/automation-webhooks", "/functions/v1/email-routes", "/rest/v1/rpc/taskfold_team_task_recipients", "/rest/v1/rpc/taskfold_team_projects", "/rest/v1/rpc/taskfold_edit_team_task", "/rest/v1/rpc/taskfold_team_task_lifecycle", "/rest/v1/rpc/taskfold_team_task_batch", "/rest/v1/rpc/taskfold_complete_team_task", "/rest/v1/rpc/taskfold_complete_team_tasks", "/rest/v1/rpc/taskfold_review_team_completion_batch", "/rest/v1/rpc/taskfold_cancel_team_completion_batch", "/rest/v1/rpc/taskfold_review_team_completion", "/rest/v1/rpc/taskfold_cancel_team_completion", "/rest/v1/rpc/taskfold_retire_team_provisional", "/rest/v1/rpc/taskfold_copy_team_draft", "/rest/v1/rpc/taskfold_workspace_boundary", "/rest/v1/rpc/taskfold_teams"].contains(path) ? "The connection response is too large. Reload and try again." : "The private place draft response is too large. Your tasks are unchanged.") }
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard body.count < limit else { throw AppFailure(message: templateLibrary ? "The team template response is too large. Refresh to try again." : projectAdoption ? "The project review is too large. Your saved request is unchanged." : ["/functions/v1/automation-keys", "/functions/v1/automation-webhooks", "/functions/v1/email-routes", "/rest/v1/rpc/taskfold_team_task_recipients", "/rest/v1/rpc/taskfold_team_projects", "/rest/v1/rpc/taskfold_edit_team_task", "/rest/v1/rpc/taskfold_team_task_lifecycle", "/rest/v1/rpc/taskfold_team_task_batch", "/rest/v1/rpc/taskfold_complete_team_task", "/rest/v1/rpc/taskfold_complete_team_tasks", "/rest/v1/rpc/taskfold_review_team_completion_batch", "/rest/v1/rpc/taskfold_cancel_team_completion_batch", "/rest/v1/rpc/taskfold_review_team_completion", "/rest/v1/rpc/taskfold_cancel_team_completion", "/rest/v1/rpc/taskfold_retire_team_provisional", "/rest/v1/rpc/taskfold_copy_team_draft", "/rest/v1/rpc/taskfold_workspace_boundary", "/rest/v1/rpc/taskfold_teams"].contains(path) ? "The connection response is too large. Reload and try again." : "The private place draft response is too large. Your tasks are unchanged.") }
                    body.append(byte)
                }
            } catch { bytes.task.cancel(); throw error }
            data = body; response = incoming
        } else { (data, response) = try await http.data(for: request) }
        if authenticated, generation != sessionGeneration || session?.user.id != owner { throw CancellationError() }
        if authenticated, (response as? HTTPURLResponse)?.statusCode == 401, retryAuthentication {
            try await refreshIfNeeded(force: true)
            return try await self.request(path, method: method, body: body, authenticated: true, extra: extra, retryAuthentication: false, expectedAccount: owner, workflowReadLimit: workflowReadLimit)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let error = (try? JSONDecoder().decode(Record.self, from: data)) ?? Record()
            let status = (response as? HTTPURLResponse)?.statusCode
            if ["/rest/v1/rpc/taskfold_review_team_completion_batch", "/rest/v1/rpc/taskfold_cancel_team_completion_batch"].contains(path) {
                if status == 401 || error.string("code") == "28000" { throw AccountSessionAuthorizationRequired() }
                throw TeamTaskBatch.Review.invalid
            }
            if workflowRun || workflowRead {
                if status == 401 || error.string("code") == "28000" { throw AccountSessionAuthorizationRequired() }
                throw TeamWorkflowRunCommand.invalid
            }
            if templateLibrary {
                if status == 401 || error.string("code") == "28000" { throw AccountSessionAuthorizationRequired() }
                throw TeamTemplateLibraryValue.invalid
            }
            if projectAdoption {
                if status == 401 || error.string("code") == "28000" { throw AccountSessionAuthorizationRequired() }
                throw TeamProjectAdoptionValue.invalid
            }
            if authenticated, status == 401,
               ["/functions/v1/automation-keys", "/functions/v1/automation-webhooks", "/functions/v1/email-routes", "/rest/v1/rpc/taskfold_team_task_recipients", "/rest/v1/rpc/taskfold_team_projects", "/rest/v1/rpc/taskfold_edit_team_task", "/rest/v1/rpc/taskfold_team_task_lifecycle", "/rest/v1/rpc/taskfold_team_task_batch", "/rest/v1/rpc/taskfold_complete_team_task", "/rest/v1/rpc/taskfold_complete_team_tasks", "/rest/v1/rpc/taskfold_review_team_completion_batch", "/rest/v1/rpc/taskfold_cancel_team_completion_batch", "/rest/v1/rpc/taskfold_review_team_completion", "/rest/v1/rpc/taskfold_cancel_team_completion", "/rest/v1/rpc/taskfold_retire_team_provisional", "/rest/v1/rpc/taskfold_copy_team_draft", "/rest/v1/rpc/taskfold_workspace_boundary", "/rest/v1/rpc/taskfold_teams"].contains(path) {
                throw AccountSessionAuthorizationRequired()
            }
            if path == "/rest/v1/rpc/taskfold_teams", body?["_action"] != .string("list"), body?["_action"] != .string("get"), body?["_action"] != .string("invitations") {
                if error.string("code") == "28000" { throw AccountSessionAuthorizationRequired() }
                throw TeamOrganizationCommandFailure(code: error.string("code"))
            }
            if ["/rest/v1/rpc/taskfold_workspace_boundary", "/rest/v1/rpc/taskfold_teams"].contains(path) {
                if error.string("code")=="PGRST202" {throw TeamWorkspaceUnavailable()}
                if error.string("code")=="28000" {throw AccountSessionAuthorizationRequired()}
                throw TeamProjectValue.invalid
            }
            if path == "/rest/v1/rpc/taskfold_copy_team_draft" {
                if error.string("code") == "28000" {throw AccountSessionAuthorizationRequired()}
                if ["42501","PT404","PT503"].contains(error.string("code")) {throw AppFailure(message:"Copying is not available in this project right now. Your saved draft and copy request are kept.")}
                throw AppFailure(message:"The copy could not be confirmed. Check project access, assignments and reminders. Your draft and any saved copy request are kept.")
            }
            if path == "/rest/v1/rpc/taskfold_retire_team_provisional" {
                if error.string("code") == "28000" {throw AccountSessionAuthorizationRequired()}
                throw TeamCompletionDraft.invalid
            }
            if path == "/rest/v1/rpc/taskfold_complete_team_task" { throw TeamCompletion.conflict }
            if ["/rest/v1/rpc/taskfold_edit_team_task", "/rest/v1/rpc/taskfold_team_task_lifecycle", "/rest/v1/rpc/taskfold_team_task_batch", "/rest/v1/rpc/taskfold_complete_team_task", "/rest/v1/rpc/taskfold_complete_team_tasks", "/rest/v1/rpc/taskfold_review_team_completion_batch", "/rest/v1/rpc/taskfold_cancel_team_completion_batch", "/rest/v1/rpc/taskfold_review_team_completion", "/rest/v1/rpc/taskfold_cancel_team_completion", "/rest/v1/rpc/taskfold_retire_team_provisional", "/rest/v1/rpc/taskfold_copy_team_draft", "/rest/v1/rpc/taskfold_workspace_boundary", "/rest/v1/rpc/taskfold_teams"].contains(path) {
                if error.string("code") == "28000" { throw AccountSessionAuthorizationRequired() }
                if error.string("code") == "PT410" { throw TeamConversationRecoveryExpired() }
                if ["/rest/v1/rpc/taskfold_team_task_batch", "/rest/v1/rpc/taskfold_complete_team_tasks"].contains(path), ["40P01","55P03","57014"].contains(error.string("code")) {
                    throw AppFailure(message:"This selection is busy syncing. Your saved changes remain on this device. Try again shortly.")
                }
                if ["PT409", "P0001"].contains(error.string("code")) {
                    if ["/rest/v1/rpc/taskfold_team_task_batch", "/rest/v1/rpc/taskfold_complete_team_tasks"].contains(path) { throw TeamTaskBatch.conflict }
                    throw TeamTaskEditScope.conflict
                }
                if ["PT404", "42501"].contains(error.string("code")) {
                    throw AppFailure(message: "Team editing access is no longer available. Your saved edit remains on this device.")
                }
                throw TeamTaskEditScope.invalid
            }
            if path == "/rest/v1/rpc/taskfold_team_task_recipients" {
                if error.string("code") == "28000" { throw AccountSessionAuthorizationRequired() }
                throw TeamTaskRecipientCatalog.invalid
            }
            if path == "/rest/v1/rpc/taskfold_team_projects" {
                if error.string("code") == "28000" { throw AccountSessionAuthorizationRequired() }
                if error.string("code") == "PT404" { throw TeamProjectAccessUnavailable() }
                throw TeamProjectValue.invalid
            }
            if ["/rest/v1/rpc/taskfold_patch_task", "/rest/v1/rpc/taskfold_delete_task"].contains(path), error.string("code") == "PT409" {
                throw TeamTaskReviewRequired()
            }
            // Raw Auth responses use error_code (code may be numeric HTTP status).
            // Retain support for normalized string-code responses, without using msg.
            let authCode = error.string("error_code").isEmpty ? error.string("code") : error.string("error_code")
            if !authenticated, path == "/auth/v1/token?grant_type=refresh_token",
               [400, 401, 422].contains(status ?? 0),
               ["refresh_token_not_found", "refresh_token_already_used", "session_expired", "session_not_found"].contains(authCode) {
                throw AccountSessionAuthorizationRequired()
            }
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
    private func refreshResult(_ task: Task<Session, Error>, generation: UUID, account: String) async throws -> Session {
        do { return try await task.value }
        catch {
            guard generation == sessionGeneration, session?.user.id == account else { throw CancellationError() }
            throw error
        }
    }
    func refreshIfNeeded(force: Bool = false) async throws {
        guard let current = session else { throw AppFailure(message: "Please sign in again.") }
        guard force || current.expires_at < Date().timeIntervalSince1970 + 90 else { return }
        let generation = sessionGeneration
        if let refreshTask {
            let next = try await refreshResult(refreshTask, generation:generation, account:current.user.id)
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
        let next = try await refreshResult(task, generation:generation, account:current.user.id)
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
        // Profile hydration is not a new sign-in. Keep current account leases,
        // pending browser authentication and connection recovery contexts alive.
        // The existing credential writer orders this save with token refreshes.
        try await saveSession(current)
        guard generation == sessionGeneration, var live = session, live.user.id == user.id else { throw CancellationError() }
        // A token renewal may finish while profile persistence is awaiting I/O.
        // Update only metadata on the latest live credentials.
        live.user = user
        session = live
    }

    func signIn(email: String, password: String, signup: Bool, reauthenticating context: AccountReauthentication? = nil, willCommit: (() -> Void)? = nil) async throws -> Bool {
        guard context == nil || !signup else { throw CancellationError() }
        let attempt = try startAuthentication(reauthenticating:context); defer { endAuthentication(attempt) }
        let path = signup ? "/auth/v1/signup" : "/auth/v1/token?grant_type=password"
        let data = try await request(path, method: "POST", body: ["email": .string(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()), "password": .string(password)], authenticated: false)
        try requireAuthentication(attempt)
        guard let next = try? JSONDecoder().decode(Session.self, from: data) else {
            if signup { return false }
            throw AppFailure(message: "The sign-in response was incomplete. Please try again.")
        }
        try await acceptAuthentication(next,attempt:attempt,reauthenticating:context,willCommit:willCommit)
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
    /// The organization RPC does not echo an account. Bind both ends of every
    /// read to this exact authenticated backend, then decode its bounded value.
    func teamOrganizationCommand(_ command: TeamOrganizationCommand) async throws -> TeamOrganizationCommandReceipt {
        guard command.canRetry else { throw TeamOrganizationCommand.invalid }
        try TeamOrganizationValue.scope(account: command.account, origin: command.origin)
        guard !sessionTransition, session?.user.id == command.account, command.origin == (try accountRemovalOrigin) else { throw CancellationError() }
        let generation = sessionGeneration
        let data = try await request("/rest/v1/rpc/taskfold_teams", method: "POST", body: ["_action": .string(command.action.rawValue), "_body": .object(command.body)], expectedAccount: command.account)
        guard !sessionTransition, generation == sessionGeneration, session?.user.id == command.account, command.origin == (try accountRemovalOrigin) else { throw CancellationError() }
        guard let raw = try? JSONDecoder().decode([String: JSON].self, from: data) else { throw TeamOrganizationCommand.invalid }
        return try command.confirmed(raw)
    }
    private func teamOrganizationRead(_ action: String, body: [String: JSON] = [:], account: String, origin: String) async throws -> [String: JSON] {
        try TeamOrganizationValue.scope(account: account, origin: origin)
        guard !sessionTransition, session?.user.id == account, origin == (try accountRemovalOrigin) else { throw CancellationError() }
        let generation = sessionGeneration
        let data = try await request("/rest/v1/rpc/taskfold_teams", method: "POST", body: ["_action": .string(action), "_body": .object(body)], expectedAccount: account)
        guard !sessionTransition, generation == sessionGeneration, session?.user.id == account, origin == (try accountRemovalOrigin) else { throw CancellationError() }
        guard let raw = try? JSONDecoder().decode([String: JSON].self, from: data) else { throw TeamOrganizationValue.invalid }
        return raw
    }
    func teamOrganizationOverview(account: String, origin: String) async throws -> TeamOrganizationOverview {
        let generation = sessionGeneration
        let list = try await teamOrganizationRead("list", account: account, origin: origin)
        let invitations = try await teamOrganizationRead("invitations", account: account, origin: origin)
        guard generation == sessionGeneration else { throw CancellationError() }
        return try TeamOrganizationOverview(list: list, invitations: invitations, account: account, origin: origin)
    }
    func teamOrganizationDetail(team: String, account: String, origin: String) async throws -> TeamOrganizationDetail {
        guard TeamProjectValue.id(team) else { throw TeamOrganizationValue.invalid }
        return try TeamOrganizationDetail(await teamOrganizationRead("get", body: ["team_id": .string(team)], account: account, origin: origin), team: team, account: account, origin: origin)
    }

    private func teamProjectReceipt(action: String, body: [String: JSON], account: String, origin: String) async throws -> [String: JSON] {
        guard !sessionTransition, session?.user.id == account, TeamProjectValue.id(account), origin == (try accountRemovalOrigin) else { throw CancellationError() }
        let data = try await request("/rest/v1/rpc/taskfold_team_projects", method: "POST", body: ["_action": .string(action), "_body": .object(body)], expectedAccount: account)
        guard let receipt = try? JSONDecoder().decode([String: JSON].self, from: data) else { throw TeamProjectValue.invalid }
        return receipt
    }
    func teamProjectPage(team: String, account: String, origin: String, after: String? = nil) async throws -> TeamProjectPage {
        guard TeamProjectValue.id(team), after == nil || TeamProjectValue.id(after!) else { throw TeamProjectValue.invalid }
        var body: [String: JSON] = ["team_id": .string(team), "limit": .number(50)]
        if let after { body["after"] = .string(after) }
        return try TeamProjectPage(await teamProjectReceipt(action: "list", body: body, account: account, origin: origin), account: account, origin: origin, team: team, after: after)
    }
    func teamProjectAccess(team: String, project: String, account: String, origin: String) async throws -> TeamProjectAccess {
        guard TeamProjectValue.id(team), TeamProjectValue.id(project) else { throw TeamProjectValue.invalid }
        return try TeamProjectAccess(detail: await teamProjectReceipt(action: "get", body: ["team_id": .string(team), "project_id": .string(project)], account: account, origin: origin), account: account, origin: origin, team: team, project: project)
    }

    func teamProjectManagementDetail(team: String, project: String, account: String, origin: String) async throws -> TeamProjectManagementDetail {
        guard TeamProjectValue.id(team), TeamProjectValue.id(project) else { throw TeamProjectValue.invalid }
        return try TeamProjectManagementDetail(await teamProjectReceipt(action: "get", body: ["team_id": .string(team), "project_id": .string(project)], account: account, origin: origin), account: account, origin: origin, team: team, project: project)
    }
    func teamProjectStructureReview(team: String, project: String, action: TeamProjectCommand.Action, account: String, origin: String) async throws -> TeamProjectStructureReview {
        guard action.structural, TeamProjectValue.id(team), TeamProjectValue.id(project) else { throw TeamProjectCommand.invalid }
        let raw = try await teamProjectReceipt(action: "review_structure", body: ["team_id": .string(team), "project_id": .string(project), "operation": .string(action.rawValue)], account: account, origin: origin)
        return try TeamProjectStructureReview(raw, account: account, origin: origin, team: team, project: project, action: action)
    }
    func teamProjectHierarchyReview(team: String, project: String, parent: String?, action: TeamProjectCommand.Action, account: String, origin: String) async throws -> TeamProjectHierarchyReview {
        guard action.hierarchical, TeamProjectValue.id(team), TeamProjectValue.id(project), parent == nil || TeamProjectValue.id(parent!) else { throw TeamProjectCommand.invalid }
        let body: [String: JSON] = ["team_id": .string(team), "project_id": .string(project), "parent_id": parent.map(JSON.string) ?? .null, "operation": .string(action.rawValue)]
        let reviewed = try TeamProjectHierarchyReview(await teamProjectReceipt(action: "review_hierarchy", body: body, account: account, origin: origin), account: account, origin: origin, team: team, project: project, action: action)
        guard reviewed.parent == parent else { throw TeamProjectCommand.invalid }
        return reviewed
    }
    func teamProjectCommand(_ command: TeamProjectCommand) async throws -> TeamProjectCommandReceipt {
        try command.confirmed(await teamProjectReceipt(action: command.action.rawValue, body: command.body, account: command.account, origin: command.origin))
    }

    private func projectAdoptionReply(_ operation: String, body: [String: JSON], account: String, origin: String) async throws -> [String: JSON] {
        guard !sessionTransition, session?.user.id == account, TeamProjectValue.id(account), origin == (try accountRemovalOrigin) else { throw CancellationError() }
        let data = try await request("/rest/v1/rpc/taskfold_team_project_adoption", method: "POST", body: ["operation": .string(operation), "body": .object(body)], expectedAccount: account)
        guard data.count <= 3_000_000, let raw = try? JSONDecoder().decode([String: JSON].self, from: data) else { throw TeamProjectAdoptionValue.invalid }; return raw
    }
    func inspectProjectAdoption(_ scope: TeamProjectAdoptionScope) async throws -> TeamProjectAdoptionInspection {
        try TeamProjectAdoptionInspection(await projectAdoptionReply("inspect", body: scope.body, account: scope.account, origin: scope.origin), scope: scope)
    }
    func reviewProjectAdoption(_ inspection: TeamProjectAdoptionInspection, decisions: [TeamProjectAdoptionDecision]) async throws -> TeamProjectAdoptionReview {
        try await reviewProjectAdoption(inspection, decisions: decisions, connectionPolicy: nil)
    }
    func reviewProjectAdoption(_ inspection: TeamProjectAdoptionInspection, decisions: [TeamProjectAdoptionDecision], connectionPolicy: TeamProjectConnectionPolicy?) async throws -> TeamProjectAdoptionReview {
        let body = try inspection.reviewBody(decisions, connectionPolicy: connectionPolicy)
        return try TeamProjectAdoptionReview(await projectAdoptionReply("review", body: body, account: inspection.scope.account, origin: inspection.scope.origin), inspection: inspection, decisions: decisions, connectionPolicy: connectionPolicy)
    }
    func adoptProjects(_ command: TeamProjectAdoptionCommand) async throws -> TeamProjectAdoptionReceipt {
        try command.confirmed(await projectAdoptionReply("adopt", body: command.body, account: command.account, origin: command.origin))
    }

    private func taskMoveReceipt(operation: String, body: [String: JSON], account: String, origin: String) async throws -> [String: JSON] {
        guard !sessionTransition, session?.user.id == account, TeamProjectValue.id(account), origin == (try accountRemovalOrigin) else { throw CancellationError() }
        let data = try await request("/rest/v1/rpc/taskfold_team_task_move", method: "POST", body: ["_operation": .string(operation), "_body": .object(body)], expectedAccount: account)
        guard let raw = try? JSONDecoder().decode([String: JSON].self, from: data) else { throw TeamTaskMoveCommand.invalid }; return raw
    }
    func teamTaskMoveReview(_ scope: TeamTaskMoveScope) async throws -> TeamTaskMoveReview {
        try TeamTaskMoveReview(await taskMoveReceipt(operation: scope.reviewOperation, body: scope.body, account: scope.account, origin: scope.origin), scope: scope)
    }
    func teamTaskMove(_ command: TeamTaskMoveCommand) async throws -> TeamTaskMoveReceipt {
        try command.confirmed(await taskMoveReceipt(operation: command.operation, body: command.body, account: command.account, origin: command.origin))
    }

    private func automationReceipt(action: String, body: [String: JSON], account: String, origin: String) async throws -> [String: JSON] {
        guard !sessionTransition, session?.user.id == account, AutomationKey.canonicalID(account), origin == (try accountRemovalOrigin) else { throw CancellationError() }
        let data = try await request("/functions/v1/automation-keys", method: "POST", body: ["action": .string(action), "body": .object(body)],
                                     extra: ["X-Taskfold-Automation": "1"], expectedAccount: account)
        guard let receipt = try? JSONDecoder().decode([String: JSON].self, from: data), receipt["account"] == .string(account) else { throw AutomationKey.invalid }
        return receipt
    }
    #if DEBUG
    /// Controlled faults only in the isolated native host, on a disposable Auth
    /// account and a non-main Supabase origin. Never available in Release.
    private func webhookRecoveryTesting(account: String, origin: String) -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard ["com.dbakp.taskfold.workflowtestswebhooks", "com.dbakp.taskfold.mac.workflowtestsp1"].contains(Bundle.main.bundleIdentifier ?? ""),
              args.contains("--webhook-management-testing"), !args.contains("--uitesting"),
              session?.user.id == account, let email = session?.user.email,
              email.hasPrefix("taskfold-webhook-"), email.hasSuffix("@example.invalid"),
              UUID(uuidString:String(email.dropFirst("taskfold-webhook-".count).dropLast("@example.invalid".count))) != nil,
              let host = URL(string:origin)?.host, host != "zqxflydiyfjeedqvyova.supabase.co",
              host.range(of:#"^[a-z]{20}\.supabase\.co$"#,options:.regularExpression) != nil else { return false }
        return true
    }
    #endif
    func emailRouteReceipt(action: String, body: [String: JSON], domain: String?, account: String, origin: String) async throws -> [String: JSON] {
        guard !sessionTransition, session?.user.id == account, EmailCaptureValue.id(account), origin == (try accountRemovalOrigin) else { throw CancellationError() }
        var headers = ["X-Taskfold-Email": "2"]
        if let domain { guard EmailCaptureValue.domain(domain) else { throw EmailCaptureValue.invalid }; headers["X-Taskfold-Email-Domain"] = domain }
        let data = try await request("/functions/v1/email-routes", method: "POST", body: ["action": .string(action), "body": .object(body)], extra: headers, expectedAccount: account)
        guard let result = try? JSONDecoder().decode([String: JSON].self, from: data), result["protocol"] == .number(2), result["account"] == .string(account) else { throw EmailCaptureValue.invalid }; return result
    }
    func webhookReceipt(action: String, body: [String: JSON], account: String, origin: String) async throws -> [String: JSON] {
        guard !sessionTransition, session?.user.id == account, AutomationKey.canonicalID(account), origin == (try accountRemovalOrigin) else { throw CancellationError() }
        #if DEBUG
        if webhookRecoveryTesting(account:account,origin:origin), ProcessInfo.processInfo.arguments.contains("--webhook-recovery-offline") {
            throw URLError(.notConnectedToInternet)
        }
        #endif
        let data = try await request("/functions/v1/automation-webhooks", method: "POST", body: ["action": .string(action), "body": .object(body)], extra: ["X-Taskfold-Automation": "1"], expectedAccount: account)
        guard let receipt = try? JSONDecoder().decode([String: JSON].self, from: data), receipt["account"] == .string(account) else { throw WebhookValue.invalid }
        #if DEBUG
        if !discardedWebhookCreateResponse, action == "create", webhookRecoveryTesting(account:account,origin:origin),
           ProcessInfo.processInfo.arguments.contains("--webhook-discard-create-response"),
           body["name"]?.text.hasPrefix("Native recovery receiver ") == true,
           let id = body["id"]?.text, AutomationKey.canonicalID(id),
           case .object(let row) = receipt["subscription"], row["id"] == .string(id), row["state"] == .string("pending") {
            // Real HTTPS and server commit have completed. Discard that actual
            // receipt before the enrollment model receives it; no fake API peer.
            let proof:[String:JSON] = ["account":.string(account), "id":.string(id), "realSuccessDiscarded":.bool(true)]
            let folder = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Taskfold",isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try JSONEncoder().encode(proof).write(to:folder.appendingPathComponent("webhook-recovery-proof.json"),options:.atomic)
            discardedWebhookCreateResponse = true
            throw URLError(.networkConnectionLost)
        }
        #endif
        return receipt
    }
    func automationKeyPage(account: String, origin: String, cursor: String? = nil, includeInactive: Bool = false) async throws -> AutomationKeyPage {
        var body: [String: JSON] = ["limit": .number(50), "include_inactive": .bool(includeInactive)]
        if let cursor { guard AutomationKey.canonicalID(cursor) else { throw AutomationKey.invalid }; body["cursor"] = .string(cursor) }
        return try AutomationKeyPage(await automationReceipt(action: "list", body: body, account: account, origin: origin), account: account)
    }
    func registerAutomationKey(_ draft: AutomationKeyDraft) async throws -> AutomationKey {
        let receipt = try await automationReceipt(action: "create", body: draft.body, account: draft.account, origin: draft.origin)
        guard case .object(let row) = receipt["key"] else { throw AutomationKey.invalid }
        let key = try AutomationKey(row)
        guard key.id == draft.id, key.name == draft.name, Set(key.scopes) == Set(draft.scopes),
              abs(key.expires.timeIntervalSince(key.created) - Double(draft.days) * 86400) < 0.01 else { throw AutomationKey.invalid }
        guard key.active(at: Date()) else { throw AppFailure(message: "This key is no longer active. Reload your keys and create a new one.") }
        return key
    }
    func revokeAutomationKey(id: String, account: String, origin: String) async throws -> AutomationKey {
        guard AutomationKey.canonicalID(id) else { throw AutomationKey.invalid }
        let receipt = try await automationReceipt(action: "revoke", body: ["id": .string(id)], account: account, origin: origin)
        guard case .object(let row) = receipt["key"] else { throw AutomationKey.invalid }
        let key = try AutomationKey(row)
        guard key.id == id, key.revoked != nil else { throw AutomationKey.invalid }
        return key
    }
    func cancelAutomationKey(id: String, account: String, origin: String) async throws {
        guard AutomationKey.canonicalID(id) else { throw AutomationKey.invalid }
        let receipt = try await automationReceipt(action: "cancel", body: ["id": .string(id)], account: account, origin: origin)
        guard receipt["id"] == .string(id), receipt["cancelled"] == .bool(true) else { throw AutomationKey.invalid }
    }
    var accountRemovalOrigin: String {
        get throws {
            guard var url = URLComponents(string: baseURL), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/" else { throw AppFailure(message: "The account server configuration is unavailable.") }
            url.path = ""; return url.string!
        }
    }
    /// Refresh only before saving a new removal command. Uncertain-result retries
    /// must keep the original token even after expiry or Auth user removal.
    func accountRemovalCommand(forceRefresh: Bool = false) async throws -> AccountRemovalCommand {
        guard !sessionTransition, let account = session?.user.id else { throw AppFailure(message: "Sign in to remove your account.") }
        let incarnation = sessionGeneration
        try await refreshIfNeeded(force: forceRefresh)
        guard !sessionTransition, sessionGeneration == incarnation, let current = session, current.user.id == account else { throw CancellationError() }
        return try AccountRemovalCommand(account: account, origin: accountRemovalOrigin, authorization: current.access_token)
    }
    /// Preparation never deletes data. Store saves the returned status proof in
    /// its private vault before sending the separate execution request.
    func prepareAccountRemoval(_ command: AccountRemovalCommand) async throws -> String {
        let receipt = try await accountRemovalRequest(command, preparing: true)
        guard receipt["prepared"] == .bool(true), receipt["account"]?.text == command.account,
              let proof = receipt["proof"]?.text, AccountRemovalCommand.validProof(proof) else {
            throw AppFailure(message: "The server did not confirm account removal preparation. Your local work has been kept.")
        }
        return proof
    }
    /// Resumes only an app-private, durably authorized command. It deliberately
    /// does not refresh credentials, retarget to the current account or clear it.
    func performAccountRemoval(_ command: AccountRemovalCommand) async throws {
        guard command.valid, command.origin == (try accountRemovalOrigin) else { throw AppFailure(message: "Return to this account's original server to finish removal.") }
        if command.confirmed { return }
        guard command.statusProof != nil else { throw AppFailure(message: "Prepare account removal securely before continuing.") }
        let receipt = try await accountRemovalRequest(command, preparing: false)
        guard receipt["deleted"] == .bool(true) else {
            throw AppFailure(message: "The server did not confirm account removal. Your local work is still on this device. Try again.")
        }
        #if DEBUG && !SWIFT_PACKAGE
        try AccountRemovalLiveReplyFault.afterConfirmed(command, currentAccount: session?.user.id, email: session?.user.email)
        #endif
    }
    private func accountRemovalRequest(_ command: AccountRemovalCommand, preparing: Bool) async throws -> [String: JSON] {
        guard command.valid, command.origin == (try accountRemovalOrigin), !command.confirmed else { throw CancellationError() }
        var outgoing = URLRequest(url: URL(string: command.origin + "/functions/v1/delete-account")!)
        outgoing.httpMethod = "POST"; outgoing.httpBody = Data((preparing ? #"{"action":"prepare"}"# : "{}").utf8); outgoing.timeoutInterval = 25
        outgoing.cachePolicy = .reloadIgnoringLocalCacheData; outgoing.httpShouldHandleCookies = false
        outgoing.setValue(config["Key"], forHTTPHeaderField: "apikey")
        outgoing.setValue("Bearer " + command.authorization, forHTTPHeaderField: "Authorization")
        outgoing.setValue("2", forHTTPHeaderField: "X-Taskfold-Account-Removal")
        if !preparing { outgoing.setValue(command.statusProof, forHTTPHeaderField: "X-Taskfold-Account-Removal-Proof") }
        outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
        outgoing.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (bytes, response) = try await http.bytes(for: outgoing, delegate: LocationHandoffRedirectRefusal.shared)
        var data = Data()
        do {
            guard response.expectedContentLength <= 4096 else { throw AppFailure(message: "The server did not confirm account removal. Try again.") }
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 4096 else { throw AppFailure(message: "The server did not confirm account removal. Try again.") }
                data.append(byte)
            }
        } catch { bytes.task.cancel(); throw error }
        let receipt = try? JSONDecoder().decode([String: JSON].self, from: data)
        if (response as? HTTPURLResponse)?.statusCode == 401 { throw AccountRemovalAuthorizationRequired() }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw AppFailure(message: (receipt?["error"]?.text).flatMap { $0.isEmpty ? nil : String($0.prefix(500)) } ?? "Account removal could not be confirmed. Some server data may already be removed. Try again.")
        }
        return receipt ?? [:]
    }
    #if SWIFT_PACKAGE
    /// Transport-test convenience only. Production always uses Store's vault.
    func deleteAccount() async throws {
        let incarnation = sessionGeneration, account = session?.user.id
        let command = try await accountRemovalCommand()
        let prepared = try command.prepared(with: await prepareAccountRemoval(command))
        guard sessionGeneration == incarnation, session?.user.id == account else { throw CancellationError() }
        try await performAccountRemoval(prepared)
        guard sessionGeneration == incarnation, session?.user.id == account else { throw CancellationError() }
    }
    #endif
    #if canImport(UIKit)
    func google(reauthenticating context: AccountReauthentication? = nil, willCommit: (() -> Void)? = nil) async throws {
        guard authSession == nil else { throw CancellationError() }
        let attempt = try startAuthentication(reauthenticating:context,cancelBrowser: { [weak self] in self?.authSession?.cancel(); self?.authSession = nil })
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
        try await acceptAuthentication(next,attempt:attempt,reauthenticating:context,willCommit:willCommit)
    }
    #endif
    #if canImport(UIKit)
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? UIWindow()
    }
    #endif
    func rows(_ table: String, expectedAccount:String?=nil, maximumRows:Int?=nil) async throws -> [Record] {
        let expected=expectedAccount ?? session?.user.id,epoch=sessionGeneration
        guard expected==session?.user.id else {throw CancellationError()}
        if table == TaskActivity.table || table == TaskNodeActivity.table {
            let owner = expected, generation = sessionGeneration
            var result: [Record] = []; var cursor: Int64 = 0; var seen = Set<String>(); let nodeParser = TaskNodeActivity.Parser()
            while true {
                guard generation == sessionGeneration, session?.user.id == owner else { throw CancellationError() }
                let data = try await request(table == TaskNodeActivity.table ? TaskNodeActivity.query(after: cursor) : TaskActivityPage.query(after: cursor), expectedAccount: owner)
                guard generation == sessionGeneration, session?.user.id == owner else { throw CancellationError() }
                let page = try JSONDecoder().decode([Record].self, from: data)
                if table == TaskNodeActivity.table {
                    guard page.count <= 500, result.count + page.count <= (maximumRows ?? 100_000),
                          page.allSatisfy({ nodeParser.event($0) != nil && seen.insert($0.id.lowercased()).inserted }) else { throw TeamProjectValue.invalid }
                }
                cursor = try TaskActivityPage.cursor(page, after: cursor); result += page
                if let maximumRows,result.count>maximumRows {throw TeamProjectValue.invalid}
                if page.count < 500 { return result }
            }
        }
        // PostgREST caps responses; paginate so large task libraries are not truncated.
        var result: [Record] = []; var offset = 0; var seen=Set<String>()
        let order=table=="profiles" ? "user_id":"id"
        while true {
            guard epoch==sessionGeneration,expected==session?.user.id else {throw CancellationError()}
            let data = try await request("/rest/v1/\(table)?select=*&order=\(order)&offset=\(offset)&limit=500",expectedAccount:expected)
            let page = try JSONDecoder().decode([Record].self, from: data)
            guard epoch==sessionGeneration,expected==session?.user.id else {throw CancellationError()}
            result += page
            if let maximumRows {guard result.count<=maximumRows,page.count<=500,page.allSatisfy({row in let id=table=="profiles" ? row.string("user_id"):row.id;return !id.isEmpty && seen.insert(id).inserted}) else {throw TeamProjectValue.invalid}}
            if page.count < 500 { return result }; offset += page.count
        }
    }
    /// Optional feature reads cannot stop core task sync or reuse a previous
    /// account's evidence. A missing table, denial or transport failure is unknown.
    func assignmentProvenanceRows() async -> [Record]? {
        let generation = sessionGeneration, account = session?.user.id
        guard account != nil else { return nil }
        guard let result = try? await rows(TaskAssignmentProvenance.table), generation == sessionGeneration, session?.user.id == account else { return nil }
        return result
    }
    /// Missing/denied/partial/future history is unavailable, never an empty
    /// certified feed. A start/end epoch and session fence cover the full read.
    func nodeActivityHistory(expectedAccount: String? = nil) async -> TaskNodeActivity.Feed? {
        let generation = sessionGeneration, account = expectedAccount ?? session?.user.id
        guard let account, session?.user.id == account else { return nil }
        do {
            let before = try await rows(TaskNodeActivity.epochTable, expectedAccount: account, maximumRows: 1)
            guard TaskNodeActivity.validEpoch(before) else { return nil }
            let events = try await rows(TaskNodeActivity.table, expectedAccount: account, maximumRows: 100_000)
            let after = try await rows(TaskNodeActivity.epochTable, expectedAccount: account, maximumRows: 1)
            guard before == after, generation == sessionGeneration, session?.user.id == account else { return nil }
            return TaskNodeActivity.Feed(rows: events, epoch: after)
        } catch { return nil }
    }
    func copyTeamDraft(_ draft:TeamCompletionDraft,command:TeamCompletionDraft.CopyCommand,commit:Bool,cancel:Bool=false,expectedAccount:String) async throws -> TeamCompletionDraft.CopyReview {
        try draft.validate()
        guard !commit || !cancel else {throw TeamCompletionDraft.invalid}
        guard !sessionTransition,expectedAccount == session?.user.id,draft.scope.account == expectedAccount,
              draft.scope.origin == (try accountRemovalOrigin) else {throw CancellationError()}
        let data=try await request("/rest/v1/rpc/taskfold_copy_team_draft",method:"POST",body:["_body":.object(try command.body(for:draft)),"_commit":.bool(commit),"_cancel":.bool(cancel)],expectedAccount:expectedAccount)
        let value=try JSONDecoder().decode([String:JSON].self,from:data)
        let result=try TeamCompletionDraft.CopyReview(value,draft:draft,command:command)
        guard !commit || result.recorded || result.cancelled else {throw TeamCompletionDraft.invalid}
        guard !cancel || result.recorded || result.cancelled else {throw TeamCompletionDraft.invalid}
        return result
    }

    func retireTeamProvisional(_ mutation:Mutation,expectedAccount:String) async throws -> TeamCompletionDraft.Retirement {
        guard let command=mutation.teamCompletion,command.operation == .complete else {throw TeamCompletionDraft.invalid}
        guard !sessionTransition,expectedAccount == session?.user.id,command.scope.account == expectedAccount,command.scope.origin == (try accountRemovalOrigin) else {throw CancellationError()}
        let data=try await request("/rest/v1/rpc/taskfold_retire_team_provisional",method:"POST",body:["_body":.object(try command.body(for:mutation))],expectedAccount:expectedAccount)
        let value=try JSONDecoder().decode([String:JSON].self,from:data)
        return try TeamCompletionDraft.Retirement(value,for:mutation)
    }

    func cancelTeamCompletion(_ mutation:Mutation,expectedAccount:String) async throws -> TeamCompletion.Review {
        guard let command=mutation.teamCompletion else {throw TeamCompletion.invalid}
        guard !sessionTransition,expectedAccount == session?.user.id,command.scope.account == expectedAccount,
              command.scope.origin == (try accountRemovalOrigin) else {throw CancellationError()}
        let body=try command.body(for:mutation)
        let data=try await request("/rest/v1/rpc/taskfold_cancel_team_completion",method:"POST",body:["_action":.string(command.operation.rawValue),"_body":.object(body)],expectedAccount:expectedAccount)
        let value=try JSONDecoder().decode([String:JSON].self,from:data)
        let result=try TeamCompletion.Review(value,for:mutation)
        guard result.isCancelled || result.isRecorded else {throw TeamCompletion.invalid}
        return result
    }

    func reviewTeamCompletion(_ mutation:Mutation,expectedAccount:String) async throws -> TeamCompletion.Review {
        guard let command=mutation.teamCompletion else {throw TeamCompletion.invalid}
        guard !sessionTransition,expectedAccount == session?.user.id,command.scope.account == expectedAccount,
              command.scope.origin == (try accountRemovalOrigin) else {throw CancellationError()}
        let body=try command.body(for:mutation)
        let data=try await request("/rest/v1/rpc/taskfold_review_team_completion",method:"POST",body:["_action":.string(command.operation.rawValue),"_body":.object(body)],expectedAccount:expectedAccount)
        let value=try JSONDecoder().decode([String:JSON].self,from:data)
        return try TeamCompletion.Review(value,for:mutation)
    }

    func reviewTeamCompletionBatch(_ mutation: Mutation, expectedAccount: String, cancel: Bool = false) async throws -> TeamTaskBatch.Review {
        guard let batch = mutation.teamTaskBatch, let action = batch.completionOperation else { throw TeamTaskBatch.Review.invalid }
        guard !sessionTransition, expectedAccount == session?.user.id, batch.account == expectedAccount,
              batch.origin == (try accountRemovalOrigin) else { throw CancellationError() }
        let path = cancel ? "/rest/v1/rpc/taskfold_cancel_team_completion_batch" : "/rest/v1/rpc/taskfold_review_team_completion_batch"
        let data = try await request(path, method: "POST", body: ["_action": .string(action.rawValue), "_body": .object(try batch.body(for: mutation))], expectedAccount: expectedAccount)
        let review = try TeamTaskBatch.Review(try JSONDecoder().decode([String: JSON].self, from: data), for: mutation)
        guard !cancel || review.isRecorded || review.isCancelled else { throw TeamTaskBatch.Review.invalid }
        return review
    }

    @discardableResult func send(_ change: Mutation, expectedAccount: String? = nil) async throws -> Record? {
        guard change.table != TaskNodeActivity.table, change.table != TaskNodeActivity.epochTable, change.table != TaskActivity.table, change.table != TaskActivity.epochTable, change.table != TaskAssignmentProvenance.table else { throw AppFailure(message: "Activity history is read-only.") }
        let expectedOwner = expectedAccount ?? session?.user.id
        guard expectedOwner == session?.user.id else { throw CancellationError() }
        if WorkflowUndo.matches(change) {
            guard WorkflowUndo.items(change) != nil, WorkflowUndo.fitsBody(change), change.fields["user_id"]?.text == expectedOwner else { throw AppFailure(message: "Reopen this workflow's current Undo action.") }
            let data = try await request("/rest/v1/rpc/taskfold_undo_private_workflow", method: "POST", body: [
                "_request": .string(change.id.uuidString.lowercased()), "_body": .object(change.fields)], expectedAccount: expectedOwner)
            let saved = try JSONDecoder().decode(Record.self, from: data)
            guard WorkflowUndo.reply(saved, change: change) != nil else { throw AppFailure(message: "The server did not confirm this workflow Undo. It remains saved on this device.") }
            return saved
        }
        if change.method == "TEAM_COMPLETE" || change.teamCompletion != nil {
            guard let command=change.teamCompletion else { throw TeamCompletion.invalid }
            guard !sessionTransition,command.scope.account == expectedOwner,command.scope.account == session?.user.id,command.scope.origin == (try accountRemovalOrigin) else { throw CancellationError() }
            let body=try command.body(for:change)
            let data=try await request("/rest/v1/rpc/taskfold_complete_team_task",method:"POST",body:["_action":.string(command.operation.rawValue),"_body":.object(body)],expectedAccount:command.scope.account)
            guard let reply=try? JSONDecoder().decode([String:JSON].self,from:data) else { throw TeamCompletion.invalid }
            _=try command.receipt(reply,for:change)
            return Record(["id":.string(change.recordID),"team_completion_reply":.object(reply)])
        }
        if change.method == "TEAM_BATCH" || change.teamTaskBatch != nil {
            guard let batch=change.teamTaskBatch else { throw TeamTaskBatch.invalid }
            guard !sessionTransition,batch.account == expectedOwner,batch.account == session?.user.id,batch.origin == (try accountRemovalOrigin) else { throw CancellationError() }
            let body=try batch.body(for:change)
            let path = batch.isCompletion ? "/rest/v1/rpc/taskfold_complete_team_tasks" : "/rest/v1/rpc/taskfold_team_task_batch"
            let operation = batch.completionOperation?.rawValue ?? batch.operation.rawValue
            let data=try await request(path,method:"POST",body:[batch.isCompletion ? "_action" : "_operation":.string(operation),"_body":.object(body)],expectedAccount:batch.account)
            guard let reply=try? JSONDecoder().decode([String:JSON].self,from:data) else { throw TeamTaskBatch.invalid }
            try batch.confirm(reply,for:change)
            if batch.isCompletion { return Record(["id": .string(change.recordID), "team_completion_batch_reply": .object(reply)]) }
            return nil
        }
        if let scope = change.teamTaskScope {
            guard !sessionTransition, scope.account == expectedOwner, scope.account == session?.user.id,
                  scope.origin == (try accountRemovalOrigin) else { throw CancellationError() }
            if change.method != "PATCH" {
                let action = try scope.lifecycleAction(for: change), body = try scope.lifecycleBody(for: change)
                let data = try await request("/rest/v1/rpc/taskfold_team_task_lifecycle", method: "POST", body: ["_action":.string(action),"_body":.object(body)], expectedAccount:scope.account)
                guard let reply = try? JSONDecoder().decode([String:JSON].self,from:data) else { throw TeamTaskEditScope.invalid }
                return try scope.lifecycleSaved(reply,for:change)
            }
            let body = try scope.body(for: change)
            let data = try await request("/rest/v1/rpc/taskfold_edit_team_task", method: "POST", body: ["_body": .object(body)], expectedAccount: scope.account)
            guard let reply = try? JSONDecoder().decode([String: JSON].self, from: data) else { throw TeamTaskEditScope.invalid }
            return try scope.saved(reply, for: change)
        }
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
        if ProductivityGoalEdit.matches(change) {
            guard let owner=expectedOwner,ProductivityGoalEdit.scoped(change,account:owner),let base=change.baseline?[ProductivityGoals.field],let desired=change.fields[ProductivityGoals.field] else { throw AppFailure(message:"These saved goals need a valid workspace before syncing.") }
            guard ProductivityGoalEdit.valid(change,account:owner) else { throw AppFailure(message:"TASKFOLD_CONFLICT: These saved goals need a supported choice and review before syncing.") }
            let data=try await request("/rest/v1/rpc/taskfold_set_productivity_goals",method:"POST",body:["_base":base,"_goals":desired],expectedAccount:owner)
            let saved=try JSONDecoder().decode(Record.self,from:data)
            guard saved.id==ProductivityGoals.recordID,saved.string("user_id").lowercased()==owner.lowercased(),saved[ProductivityGoals.field]==desired else { throw AppFailure(message:"The server did not confirm your goals. They remain saved on this device.") }
            return saved
        }
        if change.table == WorkflowTemplate.table, ["PATCH","DELETE"].contains(change.method) {
            guard let base=change.baseline,base["name"] != nil,base["document"] != nil else { throw AppFailure(message:"TASKFOLD_CONFLICT: Review this older template edit before replacing synced work.") }
            let data=try await request("/rest/v1/rpc/taskfold_edit_template",method:"POST",body:["_id":.string(change.recordID),"_base":.object(base),"_changes":.object(change.fields),"_delete":.bool(change.method=="DELETE")],expectedAccount:expectedOwner)
            if change.method=="DELETE" { return nil }
            let saved=try JSONDecoder().decode(Record.self,from:data)
            guard saved.id.lowercased()==change.recordID.lowercased(),change.fields.allSatisfy({saved[$0.key]==$0.value}) else { throw AppFailure(message:"The server did not confirm this template edit. It remains saved on this device.") }
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
        let guardedTemplateCreation = change.table == WorkflowTemplate.table && change.method == "POST"
        let conflictKey = ["favorites", "view_preferences", "view_orders", ReminderSnooze.table].contains(change.table) ? "user_id,id" : "id"
        let escapedID = change.recordID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? change.recordID
        let query = change.method == "POST" ? "?on_conflict=\(conflictKey)" : "?id=eq.\(escapedID)"
        let data = try await request("/rest/v1/\(change.table)\(query)", method: change.method,
            body: change.method == "DELETE" ? nil : change.fields,
            extra: ["Prefer": change.method == "POST" ? (change.insertOnly == true || guardedTemplateCreation ? "handling=strict,resolution=ignore-duplicates,missing=default,return=representation" : "resolution=merge-duplicates,return=representation") : "return=representation"], expectedAccount: expectedOwner)
        if change.method == "POST", change.insertOnly == true || guardedTemplateCreation {
            let rows = try JSONDecoder().decode([Record].self, from: data)
            if let saved = rows.first(where: { $0.id.lowercased() == change.recordID.lowercased() && $0.string("user_id") == change.fields["user_id"]?.text }) { return saved }
            let owner = (change.fields["user_id"]?.text ?? "").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            guard !owner.isEmpty else { throw AppFailure(message: "This new item has no workspace owner.") }
            let existing = try await request("/rest/v1/\(change.table)?id=eq.\(escapedID)&user_id=eq.\(owner)&select=*", expectedAccount: expectedOwner)
            let found = try JSONDecoder().decode([Record].self, from: existing)
            guard found.contains(where: { $0.id == change.recordID && $0.string("user_id") == change.fields["user_id"]?.text }) else {
                throw AppFailure(message: "The server could not confirm this new item. It remains saved on this device.")
            }
            if guardedTemplateCreation, let existing=found.first,
               existing["name"] != change.fields["name"] || existing["document"] != change.fields["document"] {
                throw AppFailure(message:"TASKFOLD_CONFLICT: This template already exists with different saved contents. Review before restoring it.")
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
        let subscriptions: [JSON] = ["tasks", "projects", "sections", "labels", "project_collaborators", "profiles", "saved_views", "favorites", "view_preferences", "view_orders", WorkflowTemplate.table, ReminderSnooze.table, "focus_sessions", SharedComment.table, SharedMention.table].map { .object(["event": .string("*"), "schema": .string("public"), "table": .string($0)]) }
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


extension Backend: AudioCommentPublishingTransport {
    func publishAudio(_ pending: AudioCommentPending, origin: String, incarnation: UUID) async throws -> AudioCommentPublishedReceipt {
        let owner = pending.publication.account.uuidString.lowercased()
        func check() throws {
            guard !sessionTransition, sessionGeneration == incarnation, session?.user.id == owner,
                  try AudioCommentPublicationJournal.canonicalOrigin(baseURL) == origin else { throw CancellationError() }
            try Task.checkCancellation()
        }
        try check(); try await refreshIfNeeded(); try check()
        // Full native decode before sending, without recording or playing sound.
        let decoded = try await AudioCommentDecoding.validate(pending.clip.data)
        guard decoded.descriptor.sha256 == pending.publication.descriptor.sha256, decoded.descriptor.byteCount == pending.publication.descriptor.byteCount, abs(decoded.descriptor.milliseconds - pending.publication.descriptor.milliseconds) <= 1000 else { throw AudioCommentFailure.invalid }; try check()
        let encoding = Task.detached(priority: .utility) { () throws -> Data in
            try Task.checkCancellation()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(Record(["intent": .object(pending.publication.record.fields), "audio_base64": .string(pending.clip.data.base64EncodedString())]))
            try Task.checkCancellation(); return data
        }
        let body = try await withTaskCancellationHandler(operation: { try await encoding.value }, onCancel: { encoding.cancel() }); try check()
        guard let url = URL(string: origin + "/functions/v1/audio-comments?action=publish"), let session else { throw AudioCommentFailure.changed }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData; request.httpShouldHandleCookies = false
        request.setValue(config["Key"], forHTTPHeaderField: "apikey"); request.setValue("Bearer " + session.access_token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = body
        let (bytes, incoming) = try await http.bytes(for: request, delegate: LocationHandoffRedirectRefusal.shared)
        var data = Data()
        do {
            for try await byte in bytes { try Task.checkCancellation(); guard data.count < 64000 else { throw AudioCommentFailure(message: "Publication couldn’t be confirmed. Check again to retry the same recording safely.") }; if data.count % 4096 == 0 { try check() }; data.append(byte) }
            try check()
        } catch { bytes.task.cancel(); throw error }
        guard let response = incoming as? HTTPURLResponse, response.url == url else { throw AudioCommentFailure.invalid }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw AccountSessionAuthorizationRequired() }
            if response.statusCode == 429 { throw AudioCommentFailure(message: "Wait briefly, then check this recording again. Your local copy is safe.") }
            throw AudioCommentFailure(message: "Publication couldn’t be confirmed. Check again to retry the same recording safely.")
        }
        do {
            let envelope = try JSONDecoder().decode(Record.self, from: data)
            if Set(envelope.fields.keys) == ["closed"],case .object(let proof)=envelope["closed"] {
                throw try AudioCommentPublicationClosed(record:Record(proof),publication:pending.publication)
            }
            guard Set(envelope.fields.keys) == ["receipt"], case .object(let receipt) = envelope["receipt"] else { throw AudioCommentFailure.invalid }
            return try AudioCommentPublishedReceipt(record: Record(receipt), publication: pending.publication)
        } catch let closed as AudioCommentPublicationClosed {throw closed}
        catch { throw AudioCommentFailure(message: "Publication couldn’t be confirmed. Check again to retry the same recording safely.") }
    }
}

extension Backend {
    /// Local presentation may survive expired tokens, but never an in-progress
    /// account transition or a different cached account. Server calls still do
    /// their independent live Auth/session checks.
    func audioPublicationSessionMatches(_ account: String) -> Bool {
        guard !sessionTransition, let id = UUID(uuidString: account), id != AudioCommentTarget.zero,
              id.uuidString.lowercased() == account else { return false }
        return session?.user.id == account
    }
}

extension Backend: AudioCommentReadingTransport {
    private func checkAudioRead(account: UUID, origin: String, incarnation: UUID) throws {
        guard account != AudioCommentTarget.zero, audioPublicationSessionMatches(account.uuidString.lowercased()), sessionGeneration == incarnation,
              try AudioCommentPublicationJournal.canonicalOrigin(baseURL) == origin else { throw CancellationError() }
        try Task.checkCancellation()
    }
    /// Fixed authenticated gateway only: no stored URLs, signed links, cookies or
    /// redirect-following. Bound failed replies before interpreting any payload.
    private func audioReadRequest(action: String, body: Record, account: UUID, origin: String, incarnation: UUID, maximum: Int) async throws -> (Data, HTTPURLResponse) {
        try checkAudioRead(account: account, origin: origin, incarnation: incarnation)
        try await refreshIfNeeded(); try checkAudioRead(account: account, origin: origin, incarnation: incarnation)
        guard ["list", "page", "download", "remove"].contains(action), let session, let url = URL(string: origin + "/functions/v1/audio-comments?action=" + action) else { throw AudioCommentFailure.changed }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData; request.httpShouldHandleCookies = false
        request.setValue(config["Key"], forHTTPHeaderField: "apikey"); request.setValue("Bearer " + session.access_token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("no-store", forHTTPHeaderField: "Cache-Control"); request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.httpBody = try JSONEncoder().encode(body)
        let (bytes, incoming) = try await http.bytes(for: request, delegate: LocationHandoffRedirectRefusal.shared)
        do {
            guard let response = incoming as? HTTPURLResponse, response.url == url else { throw AudioCommentFailure.invalid }
            // Do not collect provider diagnostics or redirects, and do not trust
            // them as a successful deletion or current membership evidence.
            guard response.statusCode == 200 else {
                if response.statusCode == 401 { throw AccountSessionAuthorizationRequired() }
                if response.statusCode == 403 || response.statusCode == 404 { throw AudioCommentReadAccessUnavailable() }
                throw AudioCommentFailure(message: action == "remove" ? "Removal couldn’t be confirmed. Refresh the conversation before trying again." : "Recordings couldn’t be loaded. Refresh to try again.")
            }
            guard response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == (action == "download" ? "audio/mp4" : "application/json") else { throw AudioCommentFailure.invalid }
            let length = response.expectedContentLength
            guard length <= maximum else { throw AudioCommentFailure.invalid }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation(); guard data.count < maximum else { throw AudioCommentFailure.invalid }
                if data.count % 4096 == 0 { try checkAudioRead(account: account, origin: origin, incarnation: incarnation) }; data.append(byte)
            }
            try checkAudioRead(account: account, origin: origin, incarnation: incarnation)
            return (data, response)
        } catch { bytes.task.cancel(); throw error }
    }
    func pageAudio(account: UUID, target: AudioCommentTarget, after: AudioCommentPageCursor?, origin: String, incarnation: UUID) async throws -> AudioCommentPage {
        guard after == nil || after?.account == account && after?.target == target else { throw AudioCommentFailure.changed }
        let body=Record(["target":.object(target.record.fields),"after":after.map { .object($0.position.fields) } ?? .null])
        let (data,_)=try await audioReadRequest(action:"page",body:body,account:account,origin:origin,incarnation:incarnation,maximum:640_000)
        return try AudioCommentPage(data:data,account:account,target:target,after:after)
    }
    func listAudio(account: UUID, target: AudioCommentTarget, origin: String, incarnation: UUID) async throws -> [AudioCommentRemote] {
        let (data, _) = try await audioReadRequest(action: "list", body: target.record, account: account, origin: origin, incarnation: incarnation, maximum: 640_000)
        return try AudioCommentRemote.list(data, account: account, target: target)
    }
    func downloadAudio(_ comment: AudioCommentRemote, origin: String, incarnation: UUID) async throws -> AudioCommentClip {
        let (data, response) = try await audioReadRequest(action: "download", body: Record(["comment_id": .string(comment.id.uuidString.lowercased())]), account: comment.publication.account, origin: origin, incarnation: incarnation, maximum: AudioCommentDescriptor.maximumBytes)
        let expected = comment.publication.descriptor
        guard response.value(forHTTPHeaderField: "X-Audio-SHA256") == expected.sha256 else { throw AudioCommentFailure.invalid }
        let clip = try AudioCommentClip(restoring: data, descriptor: expected)
        let decoded = try await AudioCommentDecoding.validate(clip.data)
        try checkAudioRead(account: comment.publication.account, origin: origin, incarnation: incarnation)
        guard decoded.descriptor.sha256 == expected.sha256, decoded.descriptor.byteCount == expected.byteCount, abs(decoded.descriptor.milliseconds - expected.milliseconds) <= 1000 else { throw AudioCommentFailure.invalid }
        return clip
    }
    func removeAudio(_ comment: AudioCommentRemote, origin: String, incarnation: UUID) async throws -> AudioCommentRemoteRemoval {
        let (data, _) = try await audioReadRequest(action: "remove", body: Record(["comment_id": .string(comment.id.uuidString.lowercased())]), account: comment.publication.account, origin: origin, incarnation: incarnation, maximum: 64_000)
        return try AudioCommentRemoteRemoval(data: data, expected: comment)
    }
}
