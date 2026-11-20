import XCTest
@testable import TaskfoldCore

private final class AuthEntryHTTP: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.requests.append(request)
        if let (status, data) = Self.handler?(request) {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    }
}

final class AuthEntryTests: XCTestCase {
    private func defaults() -> UserDefaults { let name = "auth-entry-" + UUID().uuidString; let d = UserDefaults(suiteName: name)!; d.removePersistentDomain(forName: name); return d }
    @MainActor private func backend() -> Backend {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthEntryHTTP.self]
        AuthEntryHTTP.requests = []
        return Backend(configuration: ["URL": "https://auth-entry.test", "Key": "public"], http: URLSession(configuration: config), session: nil, persistSession: { _ in })
    }

    func testProviderSettingsParsing() {
        XCTAssertEqual(AuthProviderAvailability(settings: Data(#"{"external":{"google":false,"email":true}}"#.utf8))?.google, .unavailable)
        XCTAssertEqual(AuthProviderAvailability(settings: Data(#"{"external":{"google":true}}"#.utf8))?.google, .available)
        XCTAssertNil(AuthProviderAvailability(settings: Data("{}".utf8)))
        XCTAssertNil(AuthProviderAvailability(settings: Data("nope".utf8)))
        XCTAssertFalse(AuthProviderAvailability(google: .unavailable).googleEnabled)
        XCTAssertTrue(AuthProviderAvailability.unknown.googleEnabled)
    }
    func testCacheFreshnessIsTwentyFourHours() {
        let now = Date()
        XCTAssertTrue(AuthProviderCache.isFresh(fetchedAt: now.addingTimeInterval(-86_399), now: now))
        XCTAssertFalse(AuthProviderCache.isFresh(fetchedAt: now.addingTimeInterval(-86_401), now: now))
    }
    @MainActor func testProvidersAreFetchedOnceThenCached() async {
        let api = backend(), store = defaults()
        AuthEntryHTTP.handler = { _ in (200, Data(#"{"external":{"google":false}}"#.utf8)) }
        defer { AuthEntryHTTP.handler = nil }
        let first = await api.authProviders(defaults: store)
        let second = await api.authProviders(defaults: store)
        XCTAssertEqual(first.google, .unavailable); XCTAssertEqual(second.google, .unavailable)
        XCTAssertEqual(AuthEntryHTTP.requests.count, 1)
        XCTAssertEqual(AuthEntryHTTP.requests[0].url?.path, "/auth/v1/settings")
        XCTAssertNil(AuthEntryHTTP.requests[0].value(forHTTPHeaderField: "Authorization"))
        // A day later it asks again.
        let later = await api.authProviders(now: Date().addingTimeInterval(90_000), defaults: store)
        XCTAssertEqual(later.google, .unavailable); XCTAssertEqual(AuthEntryHTTP.requests.count, 2)
    }
    @MainActor func testOfflineLeavesGoogleEnabledAndKeepsLastAnswer() async {
        let api = backend(), store = defaults()
        AuthEntryHTTP.handler = nil
        let unknown = await api.authProviders(defaults: store)
        XCTAssertEqual(unknown, .unknown); XCTAssertTrue(unknown.googleEnabled)
        AuthEntryHTTP.handler = { _ in (200, Data(#"{"external":{"google":true}}"#.utf8)) }
        _ = await api.authProviders(defaults: store)
        AuthEntryHTTP.handler = nil
        let stale = await api.authProviders(now: Date().addingTimeInterval(200_000), defaults: store)
        XCTAssertEqual(stale.google, .available)
    }
    @MainActor func testVerifyRecoverySendsTypeAndNormalizedCode() async throws {
        let api = backend()
        let session = #"{"access_token":"a","refresh_token":"r","expires_in":3600,"user":{"id":"u","email":"m@example.com"}}"#
        AuthEntryHTTP.handler = { _ in (200, Data(session.utf8)) }
        defer { AuthEntryHTTP.handler = nil }
        try await api.verifyRecovery(email: " M@Example.com ", code: "471 912")
        let request = AuthEntryHTTP.requests[0]
        XCTAssertEqual(request.url?.path, "/auth/v1/verify")
        var raw = request.httpBody ?? Data()
        if let stream = request.httpBodyStream { stream.open(); var buffer = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; raw.append(buffer, count: n) }; stream.close() }
        let body = try JSONSerialization.jsonObject(with: raw) as? [String: String]
        XCTAssertEqual(body, ["type": "recovery", "email": "m@example.com", "token": "471912"])
        XCTAssertEqual(api.session?.user.id, "u")
        AuthEntryHTTP.requests = []
        do { try await api.verifyRecovery(email: "m@example.com", code: "12"); XCTFail("short code") } catch { XCTAssertTrue(AuthEntryHTTP.requests.isEmpty) }
    }
    func testRecoveryCodeHelpers() {
        XCTAssertEqual(RecoveryCode.normalized("4a7-1 9x12345"), "471912")
        XCTAssertTrue(RecoveryCode.isComplete("471912")); XCTAssertFalse(RecoveryCode.isComplete("47191"))
        XCTAssertEqual(RecoveryCode.masked(email: "maya.lind@example.com"), "m…@example.com")
    }
    func testFeedbackIsPlainWordsAndNeverRaw() {
        XCTAssertNil(AuthFeedback.classify(CancellationError()))
        XCTAssertEqual(AuthFeedback.classify(URLError(.notConnectedToInternet)), .network)
        XCTAssertEqual(AuthFeedback.classify(AppFailure(message: "Invalid login credentials")), .badCredentials)
        XCTAssertEqual(AuthFeedback.classify(AppFailure(message: "Email not confirmed")), .unconfirmed)
        XCTAssertEqual(AuthFeedback.classify(AppFailure(message: "The Supabase configuration is missing.")), .config)
        XCTAssertEqual(AuthFeedback.classify(AppFailure(message: "User already registered")), .accountExists)
        XCTAssertEqual(AuthFeedback.classify(AppFailure(message: "email rate limit exceeded")), .rateLimited)
        XCTAssertEqual(AuthFeedback.classify(AppFailure(message: "boom internal 500")), .generic)
        XCTAssertTrue(AuthFeedback.badCredentials.outlinesFields); XCTAssertFalse(AuthFeedback.network.outlinesFields)
        XCTAssertTrue(AuthFeedback.unconfirmed.offersResend)
        let cancelled = NSError(domain: "com.apple.AuthenticationServices.WebAuthenticationSession", code: 1)
        XCTAssertNil(AuthFeedback.classify(cancelled, google: true))
        XCTAssertEqual(AuthFeedback.classify(NSError(domain: "com.apple.AuthenticationServices.WebAuthenticationSession", code: 2), google: true)?.text, "Google sign-in didn't finish. Try again, or use email.")
    }
    func testPasswordRuleCaption() {
        XCTAssertEqual(PasswordRuleStatus("").remaining, nil)
        XCTAssertFalse(PasswordRuleStatus("1234567").met); XCTAssertEqual(PasswordRuleStatus("1234567").remaining, "3 more to go")
        XCTAssertTrue(PasswordRuleStatus("1234567890").met); XCTAssertNil(PasswordRuleStatus("1234567890").remaining)
        XCTAssertEqual(PasswordRuleStatus("").text, "Use at least 10 characters.")
    }
    func testEmailFallbackNamesTheDevice() {
        XCTAssertEqual(AccountCopy.email(session: "a@b.co", device: "this Mac"), "a@b.co")
        XCTAssertEqual(AccountCopy.email(session: nil, device: "this Mac"), "On this Mac")
        XCTAssertEqual(AccountCopy.email(session: "", device: "this iPhone"), "On this iPhone")
        #if os(macOS)
        XCTAssertEqual(AccountCopy.email(session: nil), "On this Mac")
        #endif
    }
    func testSyncBadgeIsCalm() {
        func issue(online: Bool = true, long: Bool = false, pending: Int = 0, signIn: Bool = false, failed: Bool = false, local: Bool = false, signedIn: Bool = true) -> SyncIssue? {
            SyncIssue.current(local: local, signedIn: signedIn, online: online, offlineLongEnough: long, pending: pending, needsSignIn: signIn, failed: failed)
        }
        XCTAssertNil(issue())
        XCTAssertNil(issue(online: false))                       // just dropped, nothing unsent
        XCTAssertEqual(issue(online: false, pending: 2), .offline)
        XCTAssertEqual(issue(online: false, long: true), .offline)
        XCTAssertEqual(issue(failed: true), .cantSync)
        XCTAssertEqual(issue(signIn: true), .signInAgain)
        XCTAssertNil(issue(online: false, long: true, pending: 5, local: true))
        XCTAssertNil(issue(failed: true, signedIn: false))
        XCTAssertEqual(SyncIssue.cantSync.detail, "Can't sync — will retry")
        XCTAssertEqual(SyncIssue.offline.detail, "Offline — changes saved on this device")
    }
    func testTransferLeavesStarterRowsOutAndRemapsIDs() {
        var n = 0
        let project = Record(["id": .string("p1"), "user_id": .string("local"), "name": .string("Home")])
        let seed = Record(["id": .string("p0"), "user_id": .string("local"), "name": .string(LocalModeDefaults.gettingStartedProject), "description": .string(LocalModeDefaults.gettingStartedDescription)])
        var task = Record.task(user: "local", project: "p1"); task["title"] = .string("Water the plants")
        var starter = Record.task(user: "local", project: "p0"); starter["title"] = .string("Press Space to complete this task")
        var child = Record.task(user: "local", project: "p1"); child["title"] = .string("Child"); child["parent_id"] = .string(task.id)
        let snap = Snapshot(tables: ["projects": [seed, project], "tasks": [task, starter, child]])
        let plan = LocalWorkspaceTransfer.plan(local: snap, account: "acct", makeID: { n += 1; return "new-\(n)" })
        XCTAssertEqual(plan.taskCount, 2); XCTAssertEqual(plan.projectCount, 1)
        XCTAssertEqual(plan.summary, "2 tasks and 1 project")
        XCTAssertTrue(plan.mutations.allSatisfy { $0.fields["user_id"] == .string("acct") && $0.method == "POST" })
        let tasks = plan.mutations.filter { $0.table == "tasks" }
        XCTAssertEqual(tasks.count, 2)
        let parent = tasks.first { $0.fields["title"] == .string("Water the plants") }!, kid = tasks.first { $0.fields["title"] == .string("Child") }!
        XCTAssertEqual(kid.fields["parent_id"], .string(parent.recordID))
        XCTAssertEqual(parent.fields["project_id"], plan.mutations.first { $0.table == "projects" }.map { .string($0.recordID) })
        XCTAssertNotEqual(parent.recordID, task.id)
        XCTAssertTrue(LocalWorkspaceTransfer.plan(local: Snapshot(tables: ["projects": [seed], "tasks": [starter]]), account: "a").isEmpty)
    }
}
