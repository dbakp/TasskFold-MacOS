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
    var onReply: (() -> Void)?
    init(_ reply: [String: JSON]) { self.reply = reply }
    func teamTaskMoveReview(_ scope: TeamTaskMoveScope) async throws -> TeamTaskMoveReview { throw TeamTaskMoveCommand.invalid }
    func teamTaskMove(_ command: TeamTaskMoveCommand) async throws -> TeamTaskMoveReceipt {
        calls.append(command)
        if hold { await withCheckedContinuation { continuation = $0 } }
        if loseReply { loseReply = false; throw URLError(.networkConnectionLost) }
        var raw = reply
        if foreign { raw["account"] = .string(UUID().uuidString.lowercased()) }
        onReply?(); return try command.confirmed(raw)
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
    private func privateUndoReview(_ policy: JSON?, _ count: JSON?) throws -> TeamTaskMoveReview {
        let (command, _, _) = try fixture()
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-task-moves-v1", withExtension: "json", subdirectory: "Fixtures"))
        let root = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        var raw = root["samples"]!.list[0].object["review"]!.object
        raw["subtask_undo_policy"] = policy; raw["subtask_undo_count"] = count
        return try TeamTaskMoveReview(raw, scope: command.scope)
    }
    func testActualSQLRecordTransferMoveAndUndoPrivateReviewContract() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-child-record-transfer-review-v1", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        for (index, value) in fixture["reviews"]!.list.enumerated() {
            let raw = value.object
            let reply = fixture["replies"]!.list[index].object
            let related: String? = if case .string(let id)? = raw["related_request"] { id } else { nil }
            let scope = try TeamTaskMoveScope(account: raw["account"]!.text, origin: fixture["origin"]!.text,
                team: raw["team_id"]!.text, task: raw["task_id"]!.text, generation: raw["task_generation"]!.text,
                source: raw["source_project_id"]!.text, destination: raw["destination_project_id"]!.text, undoes: related)
            let review = try TeamTaskMoveReview(raw, scope: scope)
            XCTAssertTrue(review.keepsSubtaskUndoPrivate); XCTAssertEqual(review.privateSubtaskUndoCount, 1)
            let command = try TeamTaskMoveCommand(review: review, requestID: XCTUnwrap(UUID(uuidString: reply["request_id"]!.text)), now: review.expires.addingTimeInterval(-1))
            let receipt = try command.confirmed(reply)
            XCTAssertEqual(receipt.task?["subtasks"], reply["task"]!.object["subtasks"])
            XCTAssertNil(command.body["task"]); XCTAssertNil(command.body["subtask_undo_count"])
            XCTAssertFalse(String(describing: review).contains("Private removed instructions"))
        }
    }
    func testMoveTreeAcceptsNullSparseAndEmptyContainersWithoutRelaxingChecklistWrites() throws {
        for tree in [JSON.null, .array([]), .array([.object(["id": .string("sparse")]), .object(["id": .string("null"), "subtasks": .null]), .object(["id": .string("empty"), "subtasks": .array([])])])] {
            XCTAssertNoThrow(try TeamTaskMoveTree.validate(tree))
        }
        XCTAssertThrowsError(try TeamChecklist.validate(.null))
        XCTAssertThrowsError(try TeamChecklist.validate(.array([.object(["id": .string("null"), "subtasks": .null])])))
    }
    func testMoveTreeRejectsAmbiguousIdentityAndMalformedContainers() throws {
        let trees: [JSON] = [.object([:]), .string("text"), .array([.object([:])]), .array([.object(["id": .string("")])]),
            .array([.object(["id": .string("cafe\u{0301}")]), .object(["id": .string("café")])]),
            .array([.object(["id": .string("child"), "subtasks": .object([:])])]),
            .array([.object(["id": .string("child"), TeamChecklist.key: .object(["epoch": .string("invalid"), "version": .number(0)])])])]
        for tree in trees { XCTAssertThrowsError(try TeamTaskMoveTree.validate(tree)) }
    }
    func testMoveTreeEnforcesDepthNodeAndIdentityBounds() throws {
        var tree: JSON = .array([])
        for depth in (1...24).reversed() { tree = .array([.object(["id": .string("depth-\(depth)"), "subtasks": tree])]) }
        XCTAssertNoThrow(try TeamTaskMoveTree.validate(tree))
        XCTAssertThrowsError(try TeamTaskMoveTree.validate(.array([.object(["id": .string("overflow"), "subtasks": tree])])))
        let rows = (0..<1000).map { JSON.object(["id": .string("node-\($0)")]) }
        XCTAssertNoThrow(try TeamTaskMoveTree.validate(.array(rows)))
        XCTAssertThrowsError(try TeamTaskMoveTree.validate(.array(rows + [.object(["id": .string("too-many")])])) )
        XCTAssertThrowsError(try TeamTaskMoveTree.validate(.array([.object(["id": .string(String(repeating: "x", count: 129))])])) )
    }
    func testOlderMoveReviewDoesNotClaimPrivateUndoRetention() throws {
        let review = try privateUndoReview(nil, nil)
        XCTAssertFalse(review.keepsSubtaskUndoPrivate); XCTAssertEqual(review.privateSubtaskUndoCount, 0)
    }
    func testPrivateUndoReviewAcceptsBoundedCountsWithoutChangingCommand() throws {
        for count in [0, 1, 64] {
            let review = try privateUndoReview(.string("kept_private"), .number(Double(count)))
            XCTAssertTrue(review.keepsSubtaskUndoPrivate); XCTAssertEqual(review.privateSubtaskUndoCount, count)
            let command = try TeamTaskMoveCommand(review: review, now: review.expires.addingTimeInterval(-1))
            XCTAssertNil(command.body["subtask_undo_policy"]); XCTAssertNil(command.body["subtask_undo_count"])
            XCTAssertFalse(String(describing: review).contains(review.task.title))
        }
    }
    func testPrivateUndoReviewRefusesUnknownOrUnpairedPolicy() throws {
        let pairs: [(JSON?, JSON?)] = [(nil, .number(1)), (.string("kept_private"), nil), (.string("share"), .number(1)), (.null, .number(0))]
        for pair in pairs {
            XCTAssertThrowsError(try privateUndoReview(pair.0, pair.1))
        }
    }
    func testPrivateUndoReviewRefusesUnboundedOrNonNumericCounts() throws {
        for count in [JSON.number(-1), .number(65), .number(1.5), .string("1"), .null] {
            XCTAssertThrowsError(try privateUndoReview(.string("kept_private"), count))
        }
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
        io.failWrite = false; peer.onReply = { io.failWrite = true }; await model.send(command, now: review.expires.addingTimeInterval(-60))
        XCTAssertEqual(model.pending, command); XCTAssertNil(model.receipt)
        io.failWrite = false; peer.onReply = nil; await model.retry(); XCTAssertNil(model.pending); XCTAssertNotNil(model.receipt)
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
extension TeamTaskMoveTests {
    func testConfirmedMoveUndoRedoRemainOneHistoryChainAcrossVaults() async throws {
        let io = MoveMemoryIO(), vault = TeamTaskMoveVault(io: io), lease = CalendarReadLease()
        let (move, _, _) = try fixture()
        for index in 0..<3 {
            let (command, _, _) = try fixture(index); try await vault.begin(command, lease: lease); try await vault.confirm(command, lease: lease)
            let state = try await TeamTaskMoveVault(io: io).state(account: command.account, origin: command.origin)
            XCTAssertNil(state.pending); XCTAssertEqual(state.history.count, 1); XCTAssertEqual(state.history[0].id, move.id)
            XCTAssertEqual(state.history[0].latest, command); XCTAssertEqual(state.history[0].isUndone, index == 1)
            XCTAssertEqual(state.history[0].acknowledged.count, index + 1)
            XCTAssertEqual(try state.history[0].inverseScope().undoes, command.id)
        }
        // A delayed first-window acknowledgement cannot rewind a later Redo.
        try await vault.confirm(move, lease: lease)
        let state = try await vault.state(account: move.account, origin: move.origin)
        XCTAssertEqual(state.history[0].latest.id, try fixture(2).0.id)
        XCTAssertFalse(String(decoding: try XCTUnwrap(io.values.values.first), as: UTF8.self).contains("Keep all authored notes"))
    }
    func testJournalMigratesOldPendingCommandWithoutLosingIdentity() async throws {
        let (command, _, _) = try fixture(), io = MoveMemoryIO()
        let envelope: [String: JSON] = ["version": .number(1), "command": try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(command))]
        let key = TeamTaskMoveCommand.storagePrefix + command.account + "." + CalendarOAuthConfiguration.digest(command.origin)
        try io.write(JSONEncoder().encode(envelope), key: key)
        let vault = TeamTaskMoveVault(io: io), initial = try await vault.state(account: command.account, origin: command.origin)
        XCTAssertEqual(initial.pending, command); XCTAssertTrue(initial.history.isEmpty)
        try await vault.confirm(command, lease: CalendarReadLease())
        let state = try await vault.state(account: command.account, origin: command.origin)
        XCTAssertNil(state.pending); XCTAssertEqual(state.history.first?.latest.id, command.id)
    }
    func testJournalFailureIsAtomicAndAccountRemovalErasesUndoHistory() async throws {
        let (command, _, _) = try fixture(), io = MoveMemoryIO(), vault = TeamTaskMoveVault(io: io), lease = CalendarReadLease()
        try await vault.begin(command, lease: lease); let bytes = io.values
        io.failWrite = true
        do { try await vault.confirm(command, lease: lease); XCTFail("confirmation must be durable") } catch {}
        XCTAssertEqual(io.values, bytes)
        io.failWrite = false; try await vault.confirm(command, lease: lease)
        try await vault.removeAccount(command.account, origin: command.origin)
        let state = try await vault.state(account: command.account, origin: command.origin)
        XCTAssertNil(state.pending); XCTAssertTrue(state.history.isEmpty)
    }
    func testJournalClearDoesNotEraseEarlierAcceptedMove() async throws {
        let (move, _, _) = try fixture(), (undo, _, _) = try fixture(1), io = MoveMemoryIO(), vault = TeamTaskMoveVault(io: io), lease = CalendarReadLease()
        try await vault.begin(move, lease: lease); try await vault.confirm(move, lease: lease)
        try await vault.begin(undo, lease: lease); try await vault.clear(undo, lease: lease)
        let state = try await vault.state(account: move.account, origin: move.origin)
        XCTAssertNil(state.pending); XCTAssertEqual(state.history.first?.latest, move)
    }
    func testJournalRefusesCorruptAndForeignHistoryWithoutReplacingBytes() async throws {
        let (command, _, _) = try fixture(), io = MoveMemoryIO(), vault = TeamTaskMoveVault(io: io)
        try await vault.begin(command, lease: CalendarReadLease()); try await vault.confirm(command, lease: CalendarReadLease())
        let key = try XCTUnwrap(io.values.keys.first), data = try XCTUnwrap(io.values[key])
        var raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var history = raw["history"] as! [[String: Any]], row = history[0], latest = row["latest"] as! [String: Any]
        latest["account"] = UUID().uuidString.lowercased(); row["latest"] = latest; history[0] = row; raw["history"] = history
        let corrupt = try JSONSerialization.data(withJSONObject: raw); try io.write(corrupt, key: key)
        do { _ = try await vault.state(account: command.account, origin: command.origin); XCTFail("foreign history must not open") } catch {}
        XCTAssertEqual(io.values[key], corrupt)
    }
    private func moveAdmissionFixture() throws -> (TeamTaskMoveAdmission, TeamWorkspaceCache, UUID) {
        let (command, review, _) = try fixture(), s = command.scope, session = UUID()
        let viewer = "ec440000-0000-4000-8000-000000000001", archived = "ec440000-0000-4000-8000-000000000002", personal = "ec440000-0000-4000-8000-000000000003"
        let rows: [JSON] = [(s.source,"editor",false,true,JSON.string(s.team)),(s.destination,"editor",false,true,.string(s.team)),(viewer,"viewer",false,false,.string(s.team)),(archived,"editor",true,false,.string(s.team)),(personal,"owner",false,true,.null)].sorted { $0.0 < $1.0 }.map { id, role, archived, send, team in .object(["id": .string(id), "role": .string(role), "archived": .bool(archived), "can_send_tasks": .bool(send), "team_id": team]) }
        let raw: [String: JSON] = ["workspace_boundary_protocol": .number(1), "account": .string(s.account), "native_team_reads_enabled": .bool(true), "setup_paused": .bool(false), "token": .string(String(repeating: "a", count: 64)), "teams": .array([.object(["id": .string(s.team), "state": .string("active"), "revision": .number(1), "access_revision": .number(1)])]), "projects": .array(rows)]
        let cache = try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(raw, account: s.account, origin: s.origin), previous: nil, pending: [], tasks: [review.task])
        let draft = try TeamTaskEditorDraft(source: review.task, workspace: WorkspaceBinding(account: s.account, generation: UUID()), session: session, cache: cache, enabled: true)
        return (try TeamTaskMoveAdmission(draft), cache, session)
    }
    func testAdmissionFiltersDestinationsAndFreezesWholeSourceAndAccess() throws {
        let (admission, cache, session) = try moveAdmissionFixture(), draft = admission.draft
        XCTAssertEqual(try admission.destinations(current: draft.source, workspace: draft.workspace, session: session, cache: cache, pending: [], enabled: true), [try fixture().0.scope.destination])
        let destination = try fixture().0.scope.destination
        XCTAssertEqual(try admission.scope(destination: destination, current: draft.source, workspace: draft.workspace, session: session, cache: cache, pending: [], enabled: true), try fixture().0.scope)
        var changed = draft.source; changed["description"] = .string("New shared notes")
        XCTAssertThrowsError(try admission.destinations(current: changed, workspace: draft.workspace, session: session, cache: cache, pending: [], enabled: true))
        let pending = Mutation(table: "tasks", recordID: UUID().uuidString.lowercased(), method: "PATCH", fields: ["title": .string("Unsent work")])
        XCTAssertThrowsError(try admission.destinations(current: draft.source, workspace: draft.workspace, session: session, cache: cache, pending: [pending], enabled: true))
        XCTAssertThrowsError(try admission.destinations(current: draft.source, workspace: draft.workspace, session: UUID(), cache: cache, pending: [], enabled: true))
        XCTAssertThrowsError(try admission.destinations(current: draft.source, workspace: draft.workspace, session: session, cache: cache, pending: [], enabled: false))
        var boundary = cache.boundary.raw; boundary["token"] = .string(String(repeating: "b", count: 64))
        let updated = try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(boundary, account: draft.scope.account, origin: draft.scope.origin), previous: cache, pending: [], tasks: [draft.source])
        XCTAssertThrowsError(try admission.destinations(current: draft.source, workspace: draft.workspace, session: session, cache: updated, pending: [], enabled: true))
    }
}
