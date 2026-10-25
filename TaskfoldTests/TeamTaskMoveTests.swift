import XCTest
@testable import TaskfoldCore

private final class MoveMemoryIO: CalendarSecureItemIO, @unchecked Sendable {
    private let lock = NSLock()
    var values: [String: Data] = [:]
    var failWrite = false, failRemove = false
    func read(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func write(_ data: Data, key: String) throws { lock.lock(); defer { lock.unlock() }; if failWrite { throw URLError(.cannotWriteToFile) }; values[key] = data }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; if failRemove { throw URLError(.cannotRemoveFile) }; values.removeValue(forKey: key) }
}
@MainActor private final class MovePeer: TeamTaskMoveService {
    let reply: [String: JSON]
    var calls: [TeamTaskMoveCommand] = []
    var loseReply = false, hold = false, foreign = false
    var continuation: CheckedContinuation<Void, Never>?
    init(_ reply: [String: JSON]) { self.reply = reply }
    func teamTaskMoveReview(_ scope: TeamTaskMoveScope) async throws -> TeamTaskMoveReview { throw TeamTaskMoveCommand.invalid }
    func teamTaskMove(_ command: TeamTaskMoveCommand) async throws -> TeamTaskMoveReceipt {
        calls.append(command)
        if hold { await withCheckedContinuation { continuation = $0 } }
        if loseReply { loseReply = false; throw URLError(.networkConnectionLost) }
        var raw = reply
        if foreign { raw["account"] = .string(UUID().uuidString.lowercased()) }
        return try command.confirmed(raw)
    }
}
final class TeamTaskMoveTests: XCTestCase {
    private func fixture(_ index: Int = 0) throws -> (TeamTaskMoveCommand, TeamTaskMoveReview, [String: JSON]) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-task-moves-v1", withExtension: "json", subdirectory: "Fixtures"))
        let root = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        let sample = root["samples"]!.list[index].object
        let command = try TeamTaskMoveCommand(account: root["account"]!.text, origin: root["origin"]!.text, body: sample["body"]!.object)
        return (command, try TeamTaskMoveReview(sample["review"]!.object, scope: command.scope), sample["reply"]!.object)
    }
    func testActualSQLMoveUndoRedoReviewsAndReceipts() throws {
        for index in 0..<3 {
            let (command, review, raw) = try fixture(index)
            let receipt = try command.confirmed(raw)
            XCTAssertEqual(receipt.task?.id, command.scope.task)
            XCTAssertEqual(receipt.task?.string("project_id"), command.scope.destination)
            XCTAssertEqual(review.task.string("project_id"), command.scope.source)
            XCTAssertEqual(review.discussionCount, 1)
            XCTAssertEqual(review.clearedAssignments, index == 1 ? 0 : 2)
            XCTAssertEqual(review.restoredAssignments, index == 1 ? 2 : 0)
            let inverse = try receipt.inverseScope()
            XCTAssertEqual(inverse.source, command.scope.destination); XCTAssertEqual(inverse.destination, command.scope.source)
            XCTAssertEqual(inverse.undoes, command.id); XCTAssertEqual(inverse.operation, "undo")
            XCTAssertEqual(try JSONDecoder().decode(TeamTaskMoveCommand.self, from: JSONEncoder().encode(command)), command)
        }
    }
    func testCommandsContainNoTaskOrDiscussionText() throws {
        let (command, review, _) = try fixture()
        let text = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
        XCTAssertFalse(text.contains("Move proof")); XCTAssertFalse(text.contains("Keep all authored notes"))
        XCTAssertFalse(String(reflecting: command).contains("Keep")); XCTAssertEqual(String(describing: review), "Private task move review")
        XCTAssertEqual(Set(command.body.keys), Set(["team_id", "task_id", "task_generation", "source_project_id", "destination_project_id", "request_id", "review_token", "expires_at"]))
    }
    func testNewCommandsRequireFreshReviewsAndUniqueNonce() throws {
        let (_, review, _) = try fixture()
        let now = review.expires.addingTimeInterval(-60)
        let a = try TeamTaskMoveCommand(review: review, now: now), b = try TeamTaskMoveCommand(review: review, now: now)
        XCTAssertNotEqual(a.id, b.id); XCTAssertEqual(a.scope, b.scope)
        XCTAssertThrowsError(try TeamTaskMoveCommand(review: review, now: review.expires))
        XCTAssertThrowsError(try TeamTaskMoveCommand(review: review, now: review.expires.addingTimeInterval(-32 * 60)))
    }
    func testMalformedBodiesCannotSurviveDecoding() throws {
        let (command, _, _) = try fixture()
        for (key, value) in ["review_token": JSON.string("bad"), "expires_at": .string("2026-10-25T10:00:00+02:00"), "task_id": .null, "source_project_id": .string(command.scope.destination), "undoes": .null, "force": .bool(true)] {
            var body = command.body; body[key] = value
            XCTAssertThrowsError(try TeamTaskMoveCommand(account: command.account, origin: command.origin, body: body), key)
            let envelope: [String: JSON] = ["account": .string(command.account), "origin": .string(command.origin), "body": .object(body)]
            XCTAssertThrowsError(try JSONDecoder().decode(TeamTaskMoveCommand.self, from: JSONEncoder().encode(envelope)), key)
        }
        for key in command.body.keys { var b = command.body; b.removeValue(forKey: key); XCTAssertThrowsError(try TeamTaskMoveCommand(account: command.account, origin: command.origin, body: b), key) }
        XCTAssertThrowsError(try TeamTaskMoveCommand(account: command.account, origin: "http://backend.example", body: command.body))
    }
    func testReviewsRejectForeignContentsAndInvalidCounts() throws {
        let (command, _, _) = try fixture()
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-task-moves-v1", withExtension: "json", subdirectory: "Fixtures"))
        let root = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        let raw = root["samples"]!.list[0].object["review"]!.object
        for (key, value) in ["account": JSON.string(UUID().uuidString.lowercased()), "move_review_protocol": .number(2), "destination_visibility": .string("public"), "discussion_count": .number(501), "cleared_assignments": .number(-1), "restored_assignments": .number(0.5), "task": .null, "review_token": .string(String(repeating: "A", count: 64)), "related_request": .string(command.id)] {
            var bad = raw; bad[key] = value; XCTAssertThrowsError(try TeamTaskMoveReview(bad, scope: command.scope), key)
        }
        var bad = raw; var task = raw["task"]!.object; task["project_id"] = .string(command.scope.destination); bad["task"] = .object(task)
        XCTAssertThrowsError(try TeamTaskMoveReview(bad, scope: command.scope))
    }
    func testReceiptRejectsForeignAccountIdentityProjectAndGeneration() throws {
        let (command, _, raw) = try fixture()
        for key in ["account", "team_id", "task_id", "task_generation", "source_project_id", "destination_project_id", "request_id", "related_request"] {
            var bad = raw; bad[key] = .string(UUID().uuidString.lowercased()); XCTAssertThrowsError(try command.confirmed(bad), key)
        }
        for key in ["id", "task_generation", "project_id", "user_id"] {
            var bad = raw; var task = raw["task"]!.object; task[key] = .null; bad["task"] = .object(task); XCTAssertThrowsError(try command.confirmed(bad), key)
        }
        var bad = raw; bad["operation"] = .string("undo"); XCTAssertThrowsError(try command.confirmed(bad))
    }
    func testOnlyReplayCanAcknowledgeTaskThatHasMovedAgain() throws {
        let (command, _, raw) = try fixture(); var absent = raw; absent["task"] = .null
        XCTAssertThrowsError(try command.confirmed(absent)); absent["replayed"] = .bool(true)
        XCTAssertNil(try command.confirmed(absent).task)
    }
    @MainActor func testLostReplySurvivesModelRestartAndUsesSameNonce() async throws {
        let (command, review, raw) = try fixture(), io = MoveMemoryIO(), vault = TeamTaskMoveVault(io: io), peer = MovePeer(raw)
        let model = TeamTaskMoveModel(account: command.account, origin: command.origin, vault: vault, service: peer, isCurrent: { true })
        peer.loseReply = true; await model.send(command, now: review.expires.addingTimeInterval(-60))
        XCTAssertEqual(model.pending, command); XCTAssertNil(model.receipt); model.close()
        let reopened = TeamTaskMoveModel(account: command.account, origin: command.origin, vault: vault, service: peer, isCurrent: { true })
        await reopened.load(); XCTAssertEqual(reopened.pending, command); await reopened.retry()
        XCTAssertEqual(peer.calls, [command, command]); XCTAssertNil(reopened.pending); XCTAssertNotNil(reopened.receipt)
        let saved = try await vault.pending(account: command.account, origin: command.origin); XCTAssertNil(saved)
    }
    @MainActor func testExpiredSavedRequestStillReachesServerForAcknowledgement() async throws {
        let (original, _, raw) = try fixture(); var body = original.body; body["expires_at"] = .string("2000-01-01T00:00:00Z")
        let command = try TeamTaskMoveCommand(account: original.account, origin: original.origin, body: body)
        let io = MoveMemoryIO(), vault = TeamTaskMoveVault(io: io), peer = MovePeer(raw)
        try await vault.begin(command, lease: CalendarReadLease())
        let model = TeamTaskMoveModel(account: command.account, origin: command.origin, vault: vault, service: peer, isCurrent: { true })
        await model.load(); await model.retry(); XCTAssertEqual(peer.calls, [command]); XCTAssertNotNil(model.receipt)
    }
    @MainActor func testPrivateWriteFailurePreventsNetworkAndClearFailureKeepsRecovery() async throws {
        let (command, review, raw) = try fixture(), io = MoveMemoryIO(), peer = MovePeer(raw), vault = TeamTaskMoveVault(io: io)
        let model = TeamTaskMoveModel(account: command.account, origin: command.origin, vault: vault, service: peer, isCurrent: { true })
        io.failWrite = true; await model.send(command, now: review.expires.addingTimeInterval(-60)); XCTAssertTrue(peer.calls.isEmpty)
        io.failWrite = false; io.failRemove = true; await model.send(command, now: review.expires.addingTimeInterval(-60))
        XCTAssertEqual(model.pending, command); XCTAssertNil(model.receipt)
        io.failRemove = false; await model.retry(); XCTAssertNil(model.pending); XCTAssertNotNil(model.receipt)
    }
    @MainActor func testForeignReplyKeepsIntentAndAccountSwitchSuppressesCallback() async throws {
        let (command, review, raw) = try fixture(), io = MoveMemoryIO(), peer = MovePeer(raw), vault = TeamTaskMoveVault(io: io)
        var current = true
        let model = TeamTaskMoveModel(account: command.account, origin: command.origin, vault: vault, service: peer, isCurrent: { current })
        peer.foreign = true; await model.send(command, now: review.expires.addingTimeInterval(-60)); XCTAssertEqual(model.pending, command); XCTAssertNil(model.receipt)
        peer.foreign = false; peer.hold = true
        let retry = Task { await model.retry() }
        while peer.continuation == nil { await Task.yield() }
        current = false; model.close(); peer.continuation?.resume(); await retry.value
        XCTAssertNil(model.receipt); XCTAssertNil(model.pending)
        let saved = try await vault.pending(account: command.account, origin: command.origin); XCTAssertEqual(saved, command)
    }
    func testVaultIsolatesAccountServerAndClearsOnlyReviewedIntent() async throws {
        let (command, _, _) = try fixture(), io = MoveMemoryIO(), vault = TeamTaskMoveVault(io: io), lease = CalendarReadLease()
        try await vault.begin(command, lease: lease)
        let other = try TeamTaskMoveCommand(account: command.account, origin: "https://other.example", body: command.body)
        try await vault.begin(other, lease: lease)
        var body = command.body; body["request_id"] = .string(UUID().uuidString.lowercased())
        let replacement = try TeamTaskMoveCommand(account: command.account, origin: command.origin, body: body)
        do { try await vault.begin(replacement, lease: lease); XCTFail("must not replace") } catch {}
        do { try await vault.clear(replacement, lease: lease); XCTFail("must not clear another request") } catch {}
        try await vault.removeAccount(command.account, origin: command.origin)
        let a = try await vault.pending(account: command.account, origin: command.origin), b = try await vault.pending(account: command.account, origin: other.origin)
        XCTAssertNil(a); XCTAssertEqual(b, other)
    }
}
private final class MoveHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, MoveHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() { Self.handler?(request, self) }
    func finish(_ raw: [String: JSON]) {
        let data = try! JSONEncoder().encode(raw)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
private final class MoveHTTPGate: @unchecked Sendable {
    private let lock = NSLock(); private var held: MoveHTTP?
    func hold(_ value: MoveHTTP) { lock.lock(); held = value; lock.unlock() }
    func release(_ raw: [String: JSON]) { lock.lock(); let peer = held; held = nil; lock.unlock(); peer?.finish(raw) }
}
extension TeamTaskMoveTests {
    @MainActor private func backend(_ account: String) throws -> (Backend, Session) {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MoveHTTP.self]
        let session = try JSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(account)\"}}".utf8))
        return (Backend(configuration: ["URL": "https://backend.example", "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in }), session)
    }
    @MainActor func testBackendSendsOneExactMoveRequestWithoutPersonalFallback() async throws {
        let (command, _, raw) = try fixture(); let (api, _) = try backend(command.account); var count = 0
        MoveHTTP.handler = { request, peer in
            count += 1
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_team_task_move"); XCTAssertEqual(request.httpMethod, "POST")
            let data = request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open(); defer { stream.close() }; var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }; return data
            } ?? Data()
            let sent = try! JSONDecoder().decode([String: JSON].self, from: data)
            XCTAssertEqual(sent, ["_operation": .string(command.operation), "_body": .object(command.body)])
            peer.finish(raw)
        }; defer { MoveHTTP.handler = nil }
        let result = try await api.teamTaskMove(command); XCTAssertEqual(result, try command.confirmed(raw)); XCTAssertEqual(count, 1)
    }
    @MainActor func testBackendRejectsWrongOriginOrAccountBeforeHTTP() async throws {
        let (command, _, _) = try fixture(); let (api, _) = try backend(command.account); var count = 0
        MoveHTTP.handler = { _, _ in count += 1 }; defer { MoveHTTP.handler = nil }
        let wrongServer = try TeamTaskMoveCommand(account: command.account, origin: "https://other.example", body: command.body)
        let wrongAccount = try TeamTaskMoveCommand(account: UUID().uuidString.lowercased(), origin: command.origin, body: command.body)
        for value in [wrongServer, wrongAccount] { do { _ = try await api.teamTaskMove(value); XCTFail("foreign command sent") } catch { XCTAssertTrue(error is CancellationError) } }
        XCTAssertEqual(count, 0)
    }
    @MainActor func testBackendDiscardsReplyAfterSessionSwitch() async throws {
        let (command, _, raw) = try fixture(); let (api, session) = try backend(command.account)
        let gate = MoveHTTPGate(), started = expectation(description: "Move held")
        MoveHTTP.handler = { _, peer in gate.hold(peer); started.fulfill() }; defer { MoveHTTP.handler = nil }
        let task = Task { try await api.teamTaskMove(command) }; await fulfillment(of: [started], timeout: 3)
        var other = session; other.user.id = UUID().uuidString.lowercased(); try await api.accept(other); gate.release(raw)
        do { _ = try await task.value; XCTFail("old move crossed accounts") } catch { XCTAssertTrue(error is CancellationError) }
    }
}
