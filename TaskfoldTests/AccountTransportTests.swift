import XCTest
@testable import TaskfoldCore

/// A held HTTP response makes account-switch races deterministic without a real service.
private final class ScopedHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, ScopedHTTP) -> Void)?
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
    func finish(_ status: Int, _ data: Data) {
        lock.lock(); let active = !stopped; lock.unlock()
        guard active else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
private final class HTTPGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held: ScopedHTTP?
    private var calls = 0
    func hold(_ request: ScopedHTTP) { lock.lock(); held = request; calls += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func release(_ status: Int, _ data: Data) { lock.lock(); let request = held; held = nil; lock.unlock(); request?.finish(status, data) }
}

final class AccountTransportTests: XCTestCase {
    let owner = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", other = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    func signed(_ account: String, token: String = "old") throws -> Session {
        try JSONDecoder().decode(Session.self, from: Data(("{\"access_token\":\"" + token + "\",\"refresh_token\":\"refresh\",\"expires_in\":3600,\"user\":{\"id\":\"" + account + "\"}}").utf8))
    }
    @MainActor func backend(_ session: Session, save: @escaping (Session?) throws -> Void = { _ in }) -> Backend {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ScopedHTTP.self]
        return Backend(configuration: ["URL":"https://native-scope.test","Key":"public"], http: URLSession(configuration: config), session: session, persistSession: save)
    }
    @MainActor func testOldFocus401CannotRetryWithAnotherAccountsCredentials() async throws {
        let gate = HTTPGate(), started = expectation(description: "Original account's Focus request started")
        let next = try signed(other, token: "new"), data = try JSONEncoder().encode(next)
        var saved: Session?
        let api = backend(try signed(owner), save: { saved = $0 })
        ScopedHTTP.handler = { request, transport in
            if request.url?.path == "/auth/v1/token" { transport.finish(200, data) }
            else {
                XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_set_focus_session")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old")
                gate.hold(transport); started.fulfill()
            }
        }
        defer { ScopedHTTP.handler = nil }
        let session = try FocusSession(taskID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", minutes: 25)
        let change = try FocusSessionChange.make(session, current: nil, account: owner)
        let request = Task { @MainActor in try await api.send(change, expectedAccount: self.owner) }
        await fulfillment(of: [started], timeout: 3)
        _ = try await api.signIn(email: "fixture@example.invalid", password: "fixture", signup: false)
        gate.release(401, Data(#"{"message":"Expired token"}"#.utf8))
        do { _ = try await request.value; XCTFail("An old request must not retry under the new account") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(gate.count, 1); XCTAssertEqual(api.session?.user.id, other); XCTAssertEqual(saved?.user.id, other)
    }
    @MainActor func testStaleQueueScopeIsRejectedBeforeAnyTransportIncludingSharedTaskEdits() async throws {
        let api = backend(try signed(other)); let calls = HTTPGate()
        ScopedHTTP.handler = { _, transport in calls.hold(transport); transport.finish(200, Data("[]".utf8)) }
        defer { ScopedHTTP.handler = nil }
        let mutation = Mutation(table: "tasks", recordID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", method: "PATCH", fields: ["title": .string("Old workspace edit")], baseline: ["title": .string("Original")])
        do { _ = try await api.send(mutation, expectedAccount: owner); XCTFail("A stale queue used the current account") } catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await api.request("/rest/v1/focus_sessions", expectedAccount: owner); XCTFail("A stale timer request used the current account") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls.count, 0)
    }
    @MainActor func testJoinedRefreshCannotRestorePreviousAccountAfterNewSignIn() async throws {
        var expired = try signed(owner); expired.expires_at = 0
        let gate = HTTPGate(), started = expectation(description: "Shared refresh started")
        let next = try signed(other, token: "new"), data = try JSONEncoder().encode(next), oldData = try JSONEncoder().encode(signed(owner, token: "refreshed-old"))
        var saved: Session?
        let api = backend(expired, save: { saved = $0 })
        ScopedHTTP.handler = { request, transport in
            if request.url?.query?.contains("refresh_token") == true { gate.hold(transport); started.fulfill() }
            else { transport.finish(200, data) }
        }
        defer { ScopedHTTP.handler = nil }
        let first = Task { @MainActor in try await api.refreshIfNeeded() }
        await fulfillment(of: [started], timeout: 3)
        let joinedStarted = expectation(description: "Second caller joined the held refresh")
        let joined = Task { @MainActor in joinedStarted.fulfill(); try await api.refreshIfNeeded() }
        await fulfillment(of: [joinedStarted], timeout: 3)
        _ = try await api.signIn(email: "fixture@example.invalid", password: "fixture", signup: false)
        gate.release(200, oldData)
        for request in [first, joined] {
            do { try await request.value; XCTFail("A stale refresh replaced the accepted account") } catch { /* Cancellation/network cancellation both leave the new account intact. */ }
        }
        XCTAssertEqual(gate.count, 1); XCTAssertEqual(api.session?.user.id, other); XCTAssertEqual(saved?.user.id, other)
    }
}
