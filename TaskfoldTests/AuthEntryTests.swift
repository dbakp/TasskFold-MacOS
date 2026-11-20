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
        XCTAssertEqual(AuthFeedback.classify(AppFailure(message: "email rate limit exceeded")), .emailRateLimited)
        XCTAssertEqual(AuthFeedback.classify(AppFailure(message: "Request rate limit reached")), .rateLimited)
        XCTAssertEqual(AuthFeedback.classify(AppFailure(message: "boom internal 500")), .generic)
        XCTAssertTrue(AuthFeedback.badCredentials.outlinesFields); XCTAssertFalse(AuthFeedback.network.outlinesFields)
        XCTAssertTrue(AuthFeedback.unconfirmed.offersResend)
        let cancelled = NSError(domain: "com.apple.AuthenticationServices.WebAuthenticationSession", code: 1)
        XCTAssertNil(AuthFeedback.classify(cancelled, google: true))
        XCTAssertEqual(AuthFeedback.classify(NSError(domain: "com.apple.AuthenticationServices.WebAuthenticationSession", code: 2), google: true)?.text, "Google sign-in didn't finish. Try again, or use email.")
    }
    private static let sessionJSON = #"{"access_token":"a","refresh_token":"r","expires_in":3600,"user":{"id":"u","email":"m@example.com"}}"#
    private func sentBody(_ request: URLRequest) throws -> [String: String]? {
        var raw = request.httpBody ?? Data()
        if let stream = request.httpBodyStream { stream.open(); var buffer = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; raw.append(buffer, count: n) }; stream.close() }
        return try JSONSerialization.jsonObject(with: raw) as? [String: String]
    }
    func testSignUpResponseParsing() {
        // Confirm email off: a session comes back.
        XCTAssertEqual(SignUpResponse.parse(Data(Self.sessionJSON.utf8)), .session)
        // Confirm email on: the user, no session (bare, and an already-registered address answers in the same shape).
        XCTAssertEqual(SignUpResponse.parse(Data(#"{"id":"u","email":"m@example.com","confirmation_sent_at":"2026-11-20T10:00:00Z","identities":[]}"#.utf8)), .confirmationRequired)
        XCTAssertEqual(SignUpResponse.parse(Data(#"{"user":{"id":"u","email":"m@example.com"},"session":null}"#.utf8)), .confirmationRequired)
        // Anything else is not a sign-up answer.
        XCTAssertEqual(SignUpResponse.parse(Data("{}".utf8)), .invalid)
        XCTAssertEqual(SignUpResponse.parse(Data(#"{"id":""}"#.utf8)), .invalid)
        XCTAssertEqual(SignUpResponse.parse(Data("nope".utf8)), .invalid)
        XCTAssertEqual(SignUpResponse.parse(Data("[]".utf8)), .invalid)
    }
    @MainActor func testSignUpReturnsSessionOrNeedsConfirmation() async throws {
        let api = backend()
        defer { AuthEntryHTTP.handler = nil }
        AuthEntryHTTP.handler = { _ in (200, Data(#"{"id":"u","email":"m@example.com","confirmation_sent_at":"2026-11-20T10:00:00Z"}"#.utf8)) }
        let confirmed = try await api.signIn(email: "m@example.com", password: "abcdefghijkl", signup: true)
        XCTAssertFalse(confirmed); XCTAssertNil(api.session)
        XCTAssertEqual(AuthEntryHTTP.requests.last?.url?.path, "/auth/v1/signup")
        AuthEntryHTTP.handler = { _ in (200, Data(Self.sessionJSON.utf8)) }
        let immediate = try await api.signIn(email: "m@example.com", password: "abcdefghijkl", signup: true)
        XCTAssertTrue(immediate); XCTAssertEqual(api.session?.user.id, "u")
    }
    @MainActor func testSignUpWithAnUnreadableAnswerFailsAndSignInWithoutSessionFails() async {
        let api = backend()
        defer { AuthEntryHTTP.handler = nil }
        AuthEntryHTTP.handler = { _ in (200, Data("{}".utf8)) }
        do { _ = try await api.signIn(email: "m@example.com", password: "abcdefghijkl", signup: true); XCTFail("no user, no session") } catch { XCTAssertEqual(AuthFeedback.classify(error), .generic) }
        // A password sign-in never "needs confirmation": the unconfirmed case arrives as an error.
        AuthEntryHTTP.handler = { _ in (200, Data(#"{"id":"u"}"#.utf8)) }
        do { _ = try await api.signIn(email: "m@example.com", password: "x", signup: false); XCTFail("sign-in without session") } catch { XCTAssertEqual(AuthFeedback.classify(error), .generic) }
        XCTAssertNil(api.session)
    }
    @MainActor func testVerifySignupSendsSignupTypeAndSignsIn() async throws {
        let api = backend()
        AuthEntryHTTP.handler = { _ in (200, Data(Self.sessionJSON.utf8)) }
        defer { AuthEntryHTTP.handler = nil }
        try await api.verifySignup(email: " M@Example.com ", code: "471-912")
        XCTAssertEqual(AuthEntryHTTP.requests[0].url?.path, "/auth/v1/verify")
        XCTAssertEqual(try sentBody(AuthEntryHTTP.requests[0]), ["type": "signup", "email": "m@example.com", "token": "471912"])
        XCTAssertEqual(api.session?.user.id, "u")
        AuthEntryHTTP.requests = []
        do { try await api.verifySignup(email: "m@example.com", code: "123"); XCTFail("short code") } catch { XCTAssertTrue(AuthEntryHTTP.requests.isEmpty); XCTAssertEqual(AuthFeedback.classify(error), .invalidCode) }
    }
    @MainActor func testWrongOrExpiredCodeAndNoSessionAreMappedToPlainWords() async {
        let api = backend()
        defer { AuthEntryHTTP.handler = nil }
        AuthEntryHTTP.handler = { _ in (403, Data(#"{"code":403,"error_code":"otp_expired","msg":"Token has expired or is invalid"}"#.utf8)) }
        do { try await api.verifySignup(email: "m@example.com", code: "471912"); XCTFail("expired") } catch {
            XCTAssertEqual(AuthFeedback.classify(error), .invalidCode)
            XCTAssertEqual(AuthFeedback.invalidCode.text, "That code didn't work. Check it or send a new one.")
        }
        AuthEntryHTTP.handler = { _ in (200, Data("{}".utf8)) }
        do { try await api.verifySignup(email: "m@example.com", code: "471912"); XCTFail("no session") } catch { XCTAssertEqual(AuthFeedback.classify(error), .invalidCode) }
        XCTAssertNil(api.session)
    }
    @MainActor func testResendConfirmationAndItsRateLimit() async {
        let api = backend()
        defer { AuthEntryHTTP.handler = nil }
        AuthEntryHTTP.handler = { _ in (200, Data("{}".utf8)) }
        try? await api.resendConfirmation(email: " M@Example.com ")
        XCTAssertEqual(AuthEntryHTTP.requests[0].url?.path, "/auth/v1/resend")
        XCTAssertEqual(try? sentBody(AuthEntryHTTP.requests[0]), ["type": "signup", "email": "m@example.com"])
        AuthEntryHTTP.handler = { _ in (429, Data(#"{"code":429,"error_code":"over_email_send_rate_limit","msg":"For security purposes, you can only request this after 52 seconds."}"#.utf8)) }
        do { try await api.resendConfirmation(email: "m@example.com"); XCTFail("limited") } catch { XCTAssertEqual(AuthFeedback.classify(error), .emailRateLimited) }
    }
    func testConfirmationFeedbackAndCooldown() {
        XCTAssertEqual(AuthFeedback.classify(AppFailure(message: "Email not confirmed")), .unconfirmed)
        XCTAssertEqual(AuthFeedback.classify(AppFailure(message: "For security purposes, you can only request this after 59 seconds.")), .emailRateLimited)
        XCTAssertEqual(AuthFeedback.classify(AppFailure(message: "Token has expired or is invalid")), .invalidCode)
        XCTAssertEqual(AuthFeedback.emailRateLimited.text, "Too many emails — try again in a minute.")
        XCTAssertTrue(AuthFeedback.unconfirmed.offersResend); XCTAssertFalse(AuthFeedback.emailRateLimited.outlinesFields)
        let now = Date(); XCTAssertEqual(EmailCodeCooldown.availableAt(from: now).timeIntervalSince(now), 60)
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
        // The starter project and its tasks are recognised by their fixed IDs, even when a starter task has moved to another project.
        let starterProject = Record(["id": .string(Onboarding.projectID(account: "local")), "user_id": .string("local"), "name": .string(Onboarding.projectName)])
        var starterTask = Record.task(user: "local", project: starterProject.id); starterTask["id"] = .string(Onboarding.taskID(account: "local", key: Onboarding.Key.allCases[0]))
        var movedStarter = starterTask; movedStarter["id"] = .string(Onboarding.taskID(account: "local", key: Onboarding.Key.allCases[1])); movedStarter["project_id"] = .string("p1")
        XCTAssertTrue(LocalWorkspaceTransfer.plan(local: Snapshot(tables: ["projects": [starterProject], "tasks": [starterTask]]), account: "a").isEmpty)
        let mixed = LocalWorkspaceTransfer.plan(local: Snapshot(tables: ["projects": [starterProject, project], "tasks": [starterTask, movedStarter, task]]), account: "a")
        XCTAssertEqual(mixed.projectCount, 1); XCTAssertEqual(mixed.taskCount, 1)
    }
}
