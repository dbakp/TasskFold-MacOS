import XCTest
import CryptoKit
@testable import TaskfoldCore

private final class CompletionIO: CalendarSecureItemIO, @unchecked Sendable {
    private let lock = NSLock()
    var failWrite = false
    var rows: [String: Data] = [:]
    func read(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return rows[key] }
    func write(_ data: Data, key: String) throws { lock.lock(); defer { lock.unlock() }; if failWrite { throw URLError(.cannotWriteToFile) }; rows[key] = data }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; rows.removeValue(forKey: key) }
}
private func completionReply(_ c: ChildTaskCompletionCommand, replayed: Bool = false) throws -> ChildTaskCompletionReceipt {
    let before = c.original?.receipt["after"]!.object ?? c.body["baseline"]!.object
    var after = c.original?.receipt["before"]!.object ?? before
    let old = TeamChecklist.token(before[TeamChecklist.key])
    after[TeamChecklist.key] = .object(["epoch": .string(old?.epoch ?? "2927994b-2e36-4460-8683-fef792648841"), "version": .number((old?.version ?? 0) + 1)])
    if !c.isUndo { after["completed"] = .bool(c.body["action"] == .string("complete")); after["completed_at"] = c.body["action"] == .string("complete") ? .string("2026-10-29T12:00:00Z") : .null }
    var raw = c.body.filter { !["baseline", "undo_of"].contains($0.key) }
    raw["revision"] = .number(Double(c.body["revision"]!.integer) + 1); raw["undo_of"] = c.body["undo_of"] ?? .null
    raw["before"] = .object(before); raw["after"] = .object(after); raw["replayed"] = .bool(replayed)
    return try c.confirmed(raw)
}
private func completionDecision(_ c: ChildTaskCompletionCommand, receipt: ChildTaskCompletionReceipt? = nil) throws -> ChildTaskCompletionResolution {
    var raw = c.body.filter { !["baseline", "revision"].contains($0.key) }
    raw["undo_of"] = c.body["undo_of"] ?? .null
    raw["outcome"] = .string(receipt == nil ? "closed" : "applied"); raw["receipt"] = receipt.map { .object($0.raw) } ?? .null
    return try .init(command: c, raw: raw)
}
@MainActor private final class CompletionPeer: ChildTaskCompletionCommandService {
    var calls: [ChildTaskCompletionCommand] = [], applied: [String: ChildTaskCompletionReceipt] = [:]
    var lose = false, onReply: (() -> Void)?
    var closeCalls: [ChildTaskCompletionCommand] = [], closed: [String: ChildTaskCompletionCommand] = [:]
    var loseClose = false, onClose: (() -> Void)?
    func childTaskCompletionCommand(_ command: ChildTaskCompletionCommand, session: UUID) async throws -> ChildTaskCompletionReceipt {
        guard closed[command.id] == nil else { throw ChildTaskCompletionFailure(reason: .closed) }
        calls.append(command)
        let replay = applied[command.id] != nil
        let proof = try applied[command.id] ?? completionReply(command)
        applied[command.id] = proof
        var raw = proof.raw; raw["replayed"] = .bool(replay)
        onReply?()
        if lose { lose = false; throw URLError(.networkConnectionLost) }
        return try command.confirmed(raw)
    }
    func closeChildTaskCompletionCommand(_ command: ChildTaskCompletionCommand, session: UUID) async throws -> ChildTaskCompletionResolution {
        closeCalls.append(command)
        let result: ChildTaskCompletionResolution
        if let proof = applied[command.id] {
            var raw = proof.raw; raw["replayed"] = .bool(true)
            result = try completionDecision(command, receipt: command.confirmed(raw))
        } else {
            if let old = closed[command.id], old.body != command.body { throw ChildTaskCompletionFailure(reason: .review) }
            closed[command.id] = command; result = try completionDecision(command)
        }
        onClose?(); if loseClose { loseClose = false; throw URLError(.networkConnectionLost) }; return result
    }

}
private final class CompletionHTTP: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: ((URLRequest, CompletionHTTP) -> Void)?
    static var handler: ((URLRequest, CompletionHTTP) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func finish(_ status: Int, _ data: Data, headers: [String: String] = [:]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
final class ChildTaskCompletionCommandTests: XCTestCase {
    func fixture() throws -> [String: JSON] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "child-task-completion-command", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
    }
    func command() throws -> ChildTaskCompletionCommand {
        let f = try fixture()
        return try .init(account: f["body"]!.object["account"]!.text, origin: "https://child-record.test", body: f["body"]!.object)
    }
    func read(_ command: ChildTaskCompletionCommand, fields: [String: JSON], revision: Double? = nil, session: UUID = UUID()) throws -> ChildTaskRecordRead {
        let b = command.body, key = b["node_key"]!.text
        let own = fields.merging(["id": .string(key), "title": .string("Synthetic private task")]) { _, value in value }
        let root = Record(["id": b["task_id"]!, "task_generation": b["task_generation"]!, "project_id": b["project_id"]!, "subtasks": .array([.object(own)])])
        let context = try ChildTaskRecordContext(account: command.account, origin: command.origin, workspace: UUID(), session: session, access: UUID(), snapshot: UUID(), root: root)
        let rev = revision ?? Double(b["revision"]!.integer)
        let response: [String: JSON] = ["protocol": .number(1), "account": .string(command.account), "task_id": b["task_id"]!, "task_generation": b["task_generation"]!, "project_id": b["project_id"]!, "projection_revision": .number(rev), "root_kind": .string("array"), "records": .array([.object(["node_key": .string(key), "incarnation": b["incarnation"]!, "revision": .number(rev), "parent_key": .null, "sibling_order": .number(0), "identity_path": .array([.string(key)]), "fields": .object(own), "children_kind": .string("absent")])])]
        return try ChildTaskRecordRead(data: JSONEncoder().encode(response), context: context)
    }
    func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-completion-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func journal(_ c: ChildTaskCompletionCommand, _ io: any CalendarSecureItemIO, _ directory: URL) throws -> ChildTaskCompletionJournal {
        try .init(account: c.account, origin: c.origin, io: io, coordinationDirectory: directory.appendingPathComponent("locks"), removalDirectory: directory.appendingPathComponent("removal"))
    }
    func undo(_ c: ChildTaskCompletionCommand, proof: ChildTaskCompletionReceipt? = nil) throws -> ChildTaskCompletionCommand {
        let proof = try proof ?? completionReply(c)
        return try .init(undo: c, receipt: proof, read: read(c, fields: proof.raw["after"]!.object, revision: Double(proof.raw["revision"]!.integer)))
    }
    func testActualPostgresCommandAndReceiptAgree() throws {
        let c = try command(), proof = try c.confirmed(fixture()["receipt"]!.object)
        XCTAssertEqual(proof.raw["after"]!.object["completed"], .bool(true)); XCTAssertEqual(proof.raw["revision"], .number(2))
        XCTAssertEqual(try JSONDecoder().decode(ChildTaskCompletionCommand.self, from: JSONEncoder().encode(c)), c)
        XCTAssertEqual(c.description, "Private child completion request")
        XCTAssertEqual(String(reflecting: proof), "Private child completion confirmation")
    }
    func testEveryReceiptIdentityAndKeyRequired() throws {
        let c = try command(), raw = try completionReply(c).raw
        for key in raw.keys {
            var changed = raw; changed.removeValue(forKey: key); XCTAssertThrowsError(try c.confirmed(changed), key)
            changed = raw; changed[key] = .string("foreign"); XCTAssertThrowsError(try c.confirmed(changed), key)
        }
        var changed = raw; changed["task"] = .object([:]); XCTAssertThrowsError(try c.confirmed(changed))
    }
    func testReceiptRejectsUnchangedAndMalformedCounters() throws {
        let c = try command(), raw = try completionReply(c).raw
        for value: JSON in [.number(0), c.body["revision"]!, .number(1.5), .number(9_007_199_254_740_992), .null, .string("2")] {
            var changed = raw; changed["revision"] = value; XCTAssertThrowsError(try c.confirmed(changed))
        }
    }
    func testCompletionProofPreservesCohortAndToken() throws {
        let c = try command(), raw = try completionReply(c).raw
        for patch: [String: JSON] in [["completed": .bool(false)], ["completed_at": .null], ["is_heading": .bool(false)], ["title": .string("smuggled")], [TeamChecklist.key: .object(["epoch": .string(UUID().uuidString.lowercased()), "version": .number(1)])]] {
            var changed = raw; changed["after"] = .object(raw["after"]!.object.merging(patch) { _, v in v }); XCTAssertThrowsError(try c.confirmed(changed))
        }
        var changed = raw; changed["before"] = .object([:]); XCTAssertThrowsError(try c.confirmed(changed))
    }
    func testReceiptAllowsLastSafeTokenButNoNextCommand() throws {
        let base = try command(); var b = base.body, state = b["baseline"]!.object
        state[TeamChecklist.key] = .object(["epoch": state[TeamChecklist.key]!.object["epoch"]!, "version": .number(TeamChecklist.maximumVersion - 1)])
        b["baseline"] = .object(state)
        let c = try ChildTaskCompletionCommand(account: base.account, origin: base.origin, body: b), proof = try completionReply(c)
        XCTAssertEqual(proof.raw["after"]!.object[TeamChecklist.key]!.object["version"], .number(TeamChecklist.maximumVersion))
        XCTAssertThrowsError(try undo(c, proof: proof))
    }
    func testUndoRequiresConfirmedExactNodeAndRestoresHistoricTime() throws {
        let base = try command(); var b = base.body, state = b["baseline"]!.object
        b["action"] = .string("reopen"); state["completed"] = .bool(true); state["completed_at"] = .string("2026-10-01T09:30:00Z"); b["baseline"] = .object(state)
        let c = try ChildTaskCompletionCommand(account: base.account, origin: base.origin, body: b), proof = try completionReply(c), u = try undo(c, proof: proof), inverse = try completionReply(u)
        XCTAssertEqual(inverse.raw["after"]!.object["completed_at"], .string("2026-10-01T09:30:00Z"))
        XCTAssertEqual(u.body["undo_of"], .string(c.id)); XCTAssertNil(u.body["baseline"])
        XCTAssertEqual(try JSONDecoder().decode(ChildTaskCompletionCommand.self, from: JSONEncoder().encode(u)), u)
        XCTAssertThrowsError(try undo(u, proof: inverse))
    }
    func testSparseUndoRestoresAbsentFlagsWithMonotoneToken() throws {
        let base = try command(); var b = base.body; b["baseline"] = .object([:])
        let c = try ChildTaskCompletionCommand(account: base.account, origin: base.origin, body: b), u = try undo(c), proof = try completionReply(u)
        let after = proof.raw["after"]!.object
        XCTAssertEqual(Set(after.keys), [TeamChecklist.key]); XCTAssertEqual(after[TeamChecklist.key]!.object["version"], .number(2))
        var forged = proof.raw; forged["after"] = .object(["completed": .bool(false), TeamChecklist.key: after[TeamChecklist.key]!])
        XCTAssertThrowsError(try u.confirmed(forged))
    }
    func testUndoProofCannotChangeOriginalTimeOrNonce() throws {
        let c = try command(), u = try undo(c), proof = try completionReply(u)
        for key in ["undo_of", "request_id", "incarnation"] { var raw = proof.raw; raw[key] = .string(UUID().uuidString.lowercased()); XCTAssertThrowsError(try u.confirmed(raw)) }
        var raw = proof.raw, state = raw["after"]!.object; state["completed_at"] = .string("2026-10-29T10:00:00Z"); raw["after"] = .object(state)
        XCTAssertThrowsError(try u.confirmed(raw))
    }
    func testFreshUndoReviewAllowsNotesButRefusesCycleAndOldIncarnation() throws {
        let c = try command(), proof = try completionReply(c), u = try undo(c)
        var current = proof.raw["after"]!.object; current["description"] = .string("Keep new notes")
        try u.review(read(c, fields: current, revision: 5))
        current[TeamChecklist.key] = .object(["epoch": current[TeamChecklist.key]!.object["epoch"]!, "version": .number(3)])
        XCTAssertThrowsError(try u.review(read(c, fields: current, revision: 5)))
        var body = u.body; body["incarnation"] = .string(UUID().uuidString.lowercased())
        XCTAssertThrowsError(try ChildTaskCompletionCommand(account: u.account, origin: u.origin, body: body, original: u.original))
    }
    func testDecodedCommandsRejectUnknownKeysAndInvalidBodies() throws {
        let c = try command(); var stored = try JSONDecoder().decode([String: JSON].self, from: JSONEncoder().encode(c))
        stored["extra"] = .bool(true); XCTAssertThrowsError(try JSONDecoder().decode(ChildTaskCompletionCommand.self, from: JSONEncoder().encode(stored)))
        for patch: [String: JSON] in [["revision": .number(0)], ["action": .string("undo")], ["subtasks": .array([])], ["baseline": .object(["title": .string("Private title")])]] {
            XCTAssertThrowsError(try ChildTaskCompletionCommand(account: c.account, origin: c.origin, body: c.body.merging(patch) { _, v in v }))
        }
    }
    func testJournalRejectsOrphanOrDuplicateUndoAndUnconfirmedProofs() throws {
        let c = try command(), proof = try completionReply(c), u = try undo(c)
        let parent = ChildTaskCompletionJournalState.Entry(command: c, phase: .confirmed, receipt: proof)
        let child = ChildTaskCompletionJournalState.Entry(command: u, phase: .queued, receipt: nil)
        XCTAssertThrowsError(try ChildTaskCompletionJournalState(account: c.account, origin: c.origin, entries: [child]))
        XCTAssertThrowsError(try ChildTaskCompletionJournalState(account: c.account, origin: c.origin, entries: [.init(command: c, phase: .queued, receipt: proof)]))
        let other = try undo(c)
        XCTAssertThrowsError(try ChildTaskCompletionJournalState(account: c.account, origin: c.origin, entries: [parent, child, .init(command: other, phase: .queued, receipt: nil)]))
    }
    func testJournalNeverCoalescesAndSerializesSameTarget() async throws {
        let c = try command(), io = CompletionIO(), j = try journal(c, io, root()); var b = c.body; b["request_id"] = .string(UUID().uuidString.lowercased())
        let next = try ChildTaskCompletionCommand(account: c.account, origin: c.origin, body: b)
        try await j.enqueue(c, lease: CalendarReadLease()); try await j.enqueue(next, lease: CalendarReadLease())
        let state = try await j.load(); XCTAssertEqual(state.entries.map(\.command), [c, next])
        do { _ = try await j.attempt(next, lease: CalendarReadLease()); XCTFail("Must resolve earlier intent") } catch {}
        _ = try await j.attempt(c, lease: CalendarReadLease())
        do { try await j.discard(c, lease: CalendarReadLease()); XCTFail("Cannot forget attempted request") } catch {}
        try await j.confirm(c, receipt: completionReply(c), lease: CalendarReadLease())
        _ = try await j.attempt(next, lease: CalendarReadLease())
    }
    func testUndoNeedsDurableParentAndCannotOrphanIt() async throws {
        let c = try command(), proof = try completionReply(c), u = try undo(c), io = CompletionIO(), j = try journal(c, io, root())
        do { try await j.enqueue(u, lease: CalendarReadLease()); XCTFail("Unrecorded original") } catch {}
        try await j.enqueue(c, lease: CalendarReadLease()); _ = try await j.attempt(c, lease: CalendarReadLease()); try await j.confirm(c, receipt: proof, lease: CalendarReadLease())
        try await j.enqueue(u, lease: CalendarReadLease())
        do { try await j.discard(c, lease: CalendarReadLease()); XCTFail("Dependent Undo needs proof") } catch {}
        try await j.discard(u, lease: CalendarReadLease()); try await j.discard(c, lease: CalendarReadLease())
        let state = try await j.load(); XCTAssertTrue(state.entries.isEmpty)
    }
    func testQueuedCannotConfirmAndChangedIdentityCannotReplace() async throws {
        let c = try command(), io = CompletionIO(), j = try journal(c, io, root()); try await j.enqueue(c, lease: CalendarReadLease())
        do { try await j.confirm(c, receipt: completionReply(c), lease: CalendarReadLease()); XCTFail("Never attempted") } catch {}
        var b = c.body; b["revision"] = .number(Double(c.body["revision"]!.integer) + 1)
        let changed = try ChildTaskCompletionCommand(account: c.account, origin: c.origin, body: b)
        do { try await j.enqueue(changed, lease: CalendarReadLease()); XCTFail("UUID is frozen") } catch {}
    }
    func testConcurrentJournalsRetainIndependentCommands() async throws {
        let c = try command(), io = CompletionIO(), d = try root(), j = try journal(c, io, d), k = try journal(c, io, d)
        var b = c.body; b["request_id"] = .string(UUID().uuidString.lowercased()); b["node_key"] = .string("sibling")
        let other = try ChildTaskCompletionCommand(account: c.account, origin: c.origin, body: b)
        async let a: Void = j.enqueue(c, lease: CalendarReadLease()); async let z: Void = k.enqueue(other, lease: CalendarReadLease()); _ = try await (a, z)
        let state = try await j.load(); XCTAssertEqual(Set(state.entries.map { $0.command.id }), [c.id, other.id])
    }
    func testCancelledLeaseAndRemovalFenceRefuseEnqueue() async throws {
        let c = try command(), io = CompletionIO(), d = try root(), j = try journal(c, io, d), lease = CalendarReadLease(); lease.cancel()
        do { try await j.enqueue(c, lease: lease); XCTFail("Cancelled") } catch {}
        try AccountRemovalDisk(directory: d.appendingPathComponent("removal"), account: c.account).removeCache()
        do { try await j.enqueue(c, lease: CalendarReadLease()); XCTFail("Account removal") } catch {}
    }
    func testCorruptRecoveryNeverOverwritten() async throws {
        let c = try command(), io = CompletionIO(), j = try journal(c, io, root()); try await j.enqueue(c, lease: CalendarReadLease())
        let key = try XCTUnwrap(io.rows.keys.first); io.rows[key] = Data("corrupt".utf8)
        do { try await j.enqueue(c, lease: CalendarReadLease()); XCTFail("Corrupt archive") } catch {}
        XCTAssertEqual(io.rows[key], Data("corrupt".utf8))
    }
    func testEncryptedFilePrivacyScopeAndWrongKeyPreserveData() async throws {
        let c = try command(), d = try root(), key = SymmetricKey(size: .bits256), other = SymmetricKey(size: .bits256)
        let io = try ChildTaskCompletionJournalFileIO(directory: d, account: c.account, origin: c.origin, encryptionKey: { key }), j = try journal(c, io, d)
        try await j.enqueue(c, lease: CalendarReadLease()); let bytes = try Data(contentsOf: io.file)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(c.id))
        let wrong = try ChildTaskCompletionJournalFileIO(directory: d, account: c.account, origin: c.origin, encryptionKey: { other })
        do { _ = try await journal(c, wrong, d).load(); XCTFail("Wrong key") } catch {}
        XCTAssertEqual(try Data(contentsOf: io.file), bytes)
        let foreign = try ChildTaskCompletionJournalFileIO(directory: d, account: c.account, origin: "https://other.test", encryptionKey: { key })
        XCTAssertNotEqual(foreign.file, io.file)
        try foreign.remove(key: ChildTaskCompletionJournalState.storagePrefix + c.account + "." + CalendarOAuthConfiguration.digest("https://other.test"))
        XCTAssertEqual(try Data(contentsOf: io.file), bytes)
    }
    @MainActor func testLostReplyRetriesSameRequestAfterColdJournalAndFreshSession() async throws {
        let c = try command(), r = try read(c, fields: c.body["baseline"]!.object), scope = ChildTaskFieldClientScope(r.context), io = CompletionIO(), d = try root(), j = try journal(c, io, d), peer = CompletionPeer()
        try await j.enqueue(c, lease: CalendarReadLease()); peer.lose = true
        let sender = ChildTaskCompletionSender(scope: scope, journal: j, service: peer, current: { scope }, canSend: { _ in true })
        do { _ = try await sender.send(c); XCTFail("Lost reply") } catch {}
        let first = try await j.load(); XCTAssertEqual(first.entries[0].phase, .attempted)
        let fresh = ChildTaskFieldClientScope(account: scope.account, origin: scope.origin, workspace: UUID(), session: UUID(), access: UUID())
        let cold = try journal(c, io, d), retry = ChildTaskCompletionSender(scope: fresh, journal: cold, service: peer, current: { fresh }, canSend: { _ in true })
        let proof = try await retry.send(c); XCTAssertEqual(proof.raw["replayed"], .bool(true)); XCTAssertEqual(peer.calls, [c, c]); XCTAssertEqual(peer.applied.count, 1)
        _ = try await retry.send(c); XCTAssertEqual(peer.calls.count, 2)
    }
    @MainActor func testAttemptWriteFailurePreventsNetworkAndProofWriteFailureRecovers() async throws {
        let c = try command(), r = try read(c, fields: c.body["baseline"]!.object), scope = ChildTaskFieldClientScope(r.context), io = CompletionIO(), j = try journal(c, io, root()), peer = CompletionPeer()
        try await j.enqueue(c, lease: CalendarReadLease()); io.failWrite = true
        let sender = ChildTaskCompletionSender(scope: scope, journal: j, service: peer, current: { scope }, canSend: { _ in true })
        do { _ = try await sender.send(c); XCTFail("Attempt not saved") } catch {}
        XCTAssertTrue(peer.calls.isEmpty)
        io.failWrite = false; peer.onReply = { io.failWrite = true }
        do { _ = try await sender.send(c); XCTFail("Proof not saved") } catch {}
        let state = try await j.load(); XCTAssertEqual(state.entries[0].phase, .attempted)
        io.failWrite = false; peer.onReply = nil; _ = try await sender.send(c); XCTAssertEqual(peer.applied.count, 1)
    }
    @MainActor func testLateSuccessAndFailureAreSuppressedAfterDeparture() async throws {
        for lose in [false, true] {
            let c = try command(), r = try read(c, fields: c.body["baseline"]!.object), scope = ChildTaskFieldClientScope(r.context), io = CompletionIO(), j = try journal(c, io, root()), peer = CompletionPeer()
            var current: ChildTaskFieldClientScope? = scope
            try await j.enqueue(c, lease: CalendarReadLease()); peer.lose = lose; peer.onReply = { current = nil }
            let sender = ChildTaskCompletionSender(scope: scope, journal: j, service: peer, current: { current }, canSend: { _ in true })
            do { _ = try await sender.send(c); XCTFail("Late result") } catch is CancellationError {} catch { XCTFail("Wrong stale error") }
            let state = try await j.load(); XCTAssertEqual(state.entries[0].phase, .attempted)
        }
    }
    @MainActor func testLostAdmissionAndClosedSenderKeepQueuedState() async throws {
        let c = try command(), r = try read(c, fields: c.body["baseline"]!.object), scope = ChildTaskFieldClientScope(r.context), io = CompletionIO(), j = try journal(c, io, root()), peer = CompletionPeer()
        try await j.enqueue(c, lease: CalendarReadLease())
        let sender = ChildTaskCompletionSender(scope: scope, journal: j, service: peer, current: { scope }, canSend: { _ in false })
        do { _ = try await sender.send(c); XCTFail("Access lost") } catch {}
        sender.close(); do { _ = try await sender.send(c); XCTFail("Closed sender") } catch is CancellationError {} catch { XCTFail("Wrong cancellation") }
        XCTAssertTrue(peer.calls.isEmpty); let state = try await j.load(); XCTAssertEqual(state.entries[0].phase, .queued)
    }
    @MainActor private func backend(_ account: String) throws -> Backend {
        let session = try JSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic\",\"refresh_token\":\"synthetic\",\"expires_in\":3600,\"user\":{\"id\":\"\(account)\"}}".utf8))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CompletionHTTP.self]
        return Backend(configuration: ["URL": "https://child-record.test", "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
    }
    @MainActor func testBackendExactBodyNoCacheCookiesAndValidProof() async throws {
        let c = try command(), backend = try backend(c.account), proof = try completionReply(c)
        defer { CompletionHTTP.handler = nil }
        CompletionHTTP.handler = { request, pipe in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_complete_child_task"); XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData); XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            var bytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf: buffer.prefix(n)) } }
            XCTAssertEqual(try! JSONDecoder().decode([String: JSON].self, from: bytes), ["_body": .object(c.body)])
            pipe.finish(200, try! JSONEncoder().encode(proof.raw))
        }
        let result = try await backend.childTaskCompletionCommand(c, session: backend.reminderSessionIncarnation); XCTAssertEqual(result, proof)
    }
    @MainActor func testBackendBoundsAndSanitizesReplies() async throws {
        let c = try command(), backend = try backend(c.account)
        defer { CompletionHTTP.handler = nil }
        for code in ["PT409", "42501", "PT503", "54000", "PT429", "55P03", "unknown"] {
            CompletionHTTP.handler = { _, pipe in pipe.finish(409, Data("{\"code\":\"\(code)\",\"message\":\"PRIVATE SERVER DETAILS\"}".utf8)) }
            do { _ = try await backend.childTaskCompletionCommand(c, session: backend.reminderSessionIncarnation); XCTFail("Refusal") }
            catch let error as ChildTaskCompletionFailure { XCTAssertFalse(error.localizedDescription.contains("PRIVATE SERVER")) }
            catch { XCTFail("Unsanitized error: \(error)") }
        }
        for declared in [false, true] {
            CompletionHTTP.handler = { _, pipe in pipe.finish(200, Data(repeating: 32, count: declared ? 1 : 16385), headers: declared ? ["Content-Length": "16385"] : [:]) }
            do { _ = try await backend.childTaskCompletionCommand(c, session: backend.reminderSessionIncarnation); XCTFail("Too large") } catch {}
        }
    }
    @MainActor func testBackendRejectsDuplicateNestedKeysAndForeignProof() async throws {
        let c = try command(), backend = try backend(c.account), raw = try completionReply(c).raw
        defer { CompletionHTTP.handler = nil }
        let normal = String(decoding: try JSONEncoder().encode(raw), as: UTF8.self)
        let duplicate = normal.replacingOccurrences(of: "\"replayed\":false", with: "\"replayed\":false,\"replayed\":false")
        XCTAssertNotEqual(duplicate, normal)
        for bytes in [Data(duplicate.utf8), Data(normal.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1").utf8)] {
            CompletionHTTP.handler = { _, pipe in pipe.finish(200, bytes) }
            do { _ = try await backend.childTaskCompletionCommand(c, session: backend.reminderSessionIncarnation); XCTFail("Duplicate key") }
            catch let error as ChildTaskCompletionFailure { XCTAssertEqual(error.reason, .unconfirmed) }
        }
        var wrong = raw; wrong["account"] = .string(UUID().uuidString.lowercased())
        let bytes = try JSONEncoder().encode(wrong); CompletionHTTP.handler = { _, pipe in pipe.finish(200, bytes) }
        do { _ = try await backend.childTaskCompletionCommand(c, session: backend.reminderSessionIncarnation); XCTFail("Foreign proof") } catch {}
    }
    @MainActor func testBackendStaleSessionRefusedBeforeNetwork() async throws {
        let c = try command(), backend = try backend(c.account)
        defer { CompletionHTTP.handler = nil }; CompletionHTTP.handler = { _, _ in XCTFail("No network") }
        do { _ = try await backend.childTaskCompletionCommand(c, session: UUID()); XCTFail("Stale session") } catch is CancellationError {} catch { XCTFail("Wrong stale error") }
    }
    func testQueueBoundAndOtherScopeRefusalKeepArchive() async throws {
        let c = try command(), io = CompletionIO(), j = try journal(c, io, root())
        for index in 0..<64 {
            var body = c.body; body["request_id"] = .string(UUID().uuidString.lowercased()); body["node_key"] = .string("node-\(index)")
            try await j.enqueue(ChildTaskCompletionCommand(account: c.account, origin: c.origin, body: body), lease: CalendarReadLease())
        }
        let before = io.rows
        do { try await j.enqueue(c, lease: CalendarReadLease()); XCTFail("Full queue") } catch {}
        let foreign = try ChildTaskCompletionCommand(account: c.account, origin: "https://other.test", body: c.body)
        do { try await j.enqueue(foreign, lease: CalendarReadLease()); XCTFail("Foreign origin") } catch {}
        XCTAssertEqual(io.rows, before)
    }
    func testDuplicateJournalKeysRefuseWithoutOverwriting() async throws {
        let c = try command(), io = CompletionIO(), j = try journal(c, io, root()); try await j.enqueue(c, lease: CalendarReadLease())
        let key = try XCTUnwrap(io.rows.keys.first), before = String(decoding: io.rows[key]!, as: UTF8.self)
        let duplicate = before.replacingOccurrences(of: "\"action\":\"complete\"", with: "\"action\":\"complete\",\"action\":\"complete\"")
        XCTAssertNotEqual(before, duplicate); io.rows[key] = Data(duplicate.utf8)
        do { _ = try await j.load(); XCTFail("Duplicate archive key") } catch {}
        do { try await j.enqueue(c, lease: CalendarReadLease()); XCTFail("Cannot overwrite archive") } catch {}
        XCTAssertEqual(io.rows[key], Data(duplicate.utf8))
    }
    func testEncryptedColdReadAndSymlinkRefusal() async throws {
        let c = try command(), d = try root(), key = SymmetricKey(size: .bits256)
        let io = try ChildTaskCompletionJournalFileIO(directory: d, account: c.account, origin: c.origin, encryptionKey: { key }), j = try journal(c, io, d)
        try await j.enqueue(c, lease: CalendarReadLease())
        let cold = try journal(c, io, d), state = try await cold.load(); XCTAssertEqual(state.entries[0].command, c)
        let unrelated = d.appendingPathComponent("kept"); try Data("untouched".utf8).write(to: unrelated)
        try FileManager.default.removeItem(at: io.file); try FileManager.default.createSymbolicLink(at: io.file, withDestinationURL: unrelated)
        do { _ = try await cold.load(); XCTFail("Symlink") } catch {}
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("untouched".utf8))
    }
    @MainActor func testDurableUndoLostReplyColdRecovery() async throws {
        let c = try command(), io = CompletionIO(), d = try root(), j = try journal(c, io, d), peer = CompletionPeer()
        let r = try read(c, fields: c.body["baseline"]!.object), scope = ChildTaskFieldClientScope(r.context)
        let sender = ChildTaskCompletionSender(scope: scope, journal: j, service: peer, current: { scope }, canSend: { _ in true })
        try await j.enqueue(c, lease: CalendarReadLease()); let first = try await sender.send(c), u = try undo(c, proof: first)
        try await j.enqueue(u, lease: CalendarReadLease()); peer.lose = true
        do { _ = try await sender.send(u); XCTFail("Lost Undo reply") } catch {}
        let cold = try journal(c, io, d), state = try await cold.load()
        XCTAssertEqual(state.entries[0].phase, .confirmed); XCTAssertEqual(state.entries[1].phase, .attempted)
        let retry = ChildTaskCompletionSender(scope: scope, journal: cold, service: peer, current: { scope }, canSend: { _ in true })
        let result = try await retry.send(state.entries[1].command)
        XCTAssertEqual(result.raw["action"], .string("undo")); XCTAssertEqual(result.raw["replayed"], .bool(true))
        XCTAssertEqual(peer.applied.count, 2); XCTAssertEqual(peer.calls, [c, u, u])
    }
    @MainActor func testEveryLiveScopeFenceSuppressesLateProof() async throws {
        let c = try command(), r = try read(c, fields: c.body["baseline"]!.object), scope = ChildTaskFieldClientScope(r.context)
        let replacements = [
            ChildTaskFieldClientScope(account: UUID().uuidString.lowercased(), origin: scope.origin, workspace: scope.workspace, session: scope.session, access: scope.access),
            ChildTaskFieldClientScope(account: scope.account, origin: "https://other.test", workspace: scope.workspace, session: scope.session, access: scope.access),
            ChildTaskFieldClientScope(account: scope.account, origin: scope.origin, workspace: UUID(), session: scope.session, access: scope.access),
            ChildTaskFieldClientScope(account: scope.account, origin: scope.origin, workspace: scope.workspace, session: UUID(), access: scope.access),
            ChildTaskFieldClientScope(account: scope.account, origin: scope.origin, workspace: scope.workspace, session: scope.session, access: UUID())]
        for replacement in replacements {
            let io = CompletionIO(), j = try journal(c, io, root()), peer = CompletionPeer()
            var current = scope; try await j.enqueue(c, lease: CalendarReadLease()); peer.onReply = { current = replacement }
            let sender = ChildTaskCompletionSender(scope: scope, journal: j, service: peer, current: { current }, canSend: { _ in true })
            do { _ = try await sender.send(c); XCTFail("Scope changed") } catch is CancellationError {} catch { XCTFail("Wrong departure error") }
            let state = try await j.load(); XCTAssertEqual(state.entries[0].phase, .attempted)
        }
    }
    @MainActor func testBackendUndoOnlySendsReviewedServerBody() async throws {
        let c = try command(), u = try undo(c), backend = try backend(c.account), proof = try completionReply(u)
        defer { CompletionHTTP.handler = nil }
        CompletionHTTP.handler = { request, pipe in
            var bytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf: buffer.prefix(n)) } }
            let sent = try! JSONDecoder().decode([String: JSON].self, from: bytes)
            XCTAssertEqual(sent, ["_body": .object(u.body)]); XCTAssertNil(sent["original"]); XCTAssertNil(sent["baseline"])
            pipe.finish(200, try! JSONEncoder().encode(proof.raw))
        }
        let result = try await backend.childTaskCompletionCommand(u, session: backend.reminderSessionIncarnation); XCTAssertEqual(result, proof)
    }

    func testReceiptIdentityUsesLiteralNodeKey() throws {
        let base = try command(); var body = base.body; body["node_key"] = .string("Café")
        let c = try ChildTaskCompletionCommand(account: base.account, origin: base.origin, body: body)
        var raw = try completionReply(c).raw; raw["node_key"] = .string("Cafe\u{301}")
        XCTAssertThrowsError(try c.confirmed(raw))
    }
    func testCompletionInstantsRejectSuffixesAndOversizedFractions() throws {
        let c = try command(), proof = try completionReply(c)
        for value in ["2026-10-29T12:00:00Z\n", "2026-10-29T12:00:00Z suffix", "2026-10-29", "2026-10-29T12:00:00." + String(repeating: "0", count: 65) + "Z"] {
            var raw = proof.raw, after = raw["after"]!.object; after["completed_at"] = .string(value); raw["after"] = .object(after)
            XCTAssertThrowsError(try c.confirmed(raw))
        }
    }

    func testActualPostgresUndoFactoryAndReceiptAgree() throws {
        let fixture = try fixture(), c = try command(), proof = try c.confirmed(fixture["receipt"]!.object), body = fixture["undo_body"]!.object
        let read = try read(c, fields: proof.raw["after"]!.object, revision: Double(body["revision"]!.integer))
        let u = try ChildTaskCompletionCommand(undo: c, receipt: proof, read: read, requestID: XCTUnwrap(UUID(uuidString: body["request_id"]!.text)))
        XCTAssertEqual(u.body, body)
        let result = try u.confirmed(fixture["undo_receipt"]!.object)
        XCTAssertEqual(result.raw["after"]!.object["completed"], .bool(false))
        XCTAssertEqual(result.raw["after"]!.object[TeamChecklist.key]!.object["version"], .number(2))
    }

    func testActualDatabaseTerminalDecisionsAgree() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "child-task-completion-resolution", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        for prefix in ["closed", "applied"] {
            let body = fixture[prefix + "_body"]!.object
            let c = try ChildTaskCompletionCommand(account: body["account"]!.text, origin: "https://child-record.test", body: body)
            let result = try ChildTaskCompletionResolution(command: c, raw: fixture[prefix + "_decision"]!.object)
            XCTAssertEqual(result.closed, prefix == "closed"); XCTAssertEqual(result.receipt != nil, prefix == "applied")
            XCTAssertEqual(String(reflecting: result), "Private child completion decision")
        }
    }
    func testTerminalDecisionRequiresEveryLiteralIdentityAndValidReceipt() throws {
        let c = try command(), good = try completionDecision(c)
        for key in good.raw.keys {
            var raw = good.raw; raw.removeValue(forKey: key); XCTAssertThrowsError(try ChildTaskCompletionResolution(command: c, raw: raw), key)
            raw = good.raw; raw[key] = .string("foreign"); XCTAssertThrowsError(try ChildTaskCompletionResolution(command: c, raw: raw), key)
        }
        var raw = good.raw; raw["receipt"] = .object(try completionReply(c).raw)
        XCTAssertThrowsError(try ChildTaskCompletionResolution(command: c, raw: raw))
        raw["outcome"] = .string("applied"); _ = try ChildTaskCompletionResolution(command: c, raw: raw)
        raw["extra"] = .bool(true); XCTAssertThrowsError(try ChildTaskCompletionResolution(command: c, raw: raw))
    }
    func testPreviousJournalFormatStillLoadsAndClosedRequiresProof() throws {
        let c = try command(), entry = ChildTaskCompletionJournalState.Entry(command: c, phase: .queued, receipt: nil)
        let state = try ChildTaskCompletionJournalState(account: c.account, origin: c.origin, entries: [entry])
        var raw = try JSONDecoder().decode([String: JSON].self, from: JSONEncoder().encode(state))
        var saved = raw["entries"]!.list[0].object; saved.removeValue(forKey: "resolution"); raw["entries"] = .array([.object(saved)])
        XCTAssertEqual(try JSONDecoder().decode(ChildTaskCompletionJournalState.self, from: JSONEncoder().encode(raw)), state)
        XCTAssertThrowsError(try ChildTaskCompletionJournalState(account: c.account, origin: c.origin, entries: [.init(command: c, phase: .closed, receipt: nil)]))
        XCTAssertThrowsError(try ChildTaskCompletionJournalState(account: c.account, origin: c.origin, entries: [.init(command: c, phase: .closed, receipt: completionReply(c), resolution: completionDecision(c))]))
    }
    @MainActor func testLostCloseReplyColdRetryPersistsClosureWithoutEditAdmission() async throws {
        let c = try command(), r = try read(c, fields: c.body["baseline"]!.object), scope = ChildTaskFieldClientScope(r.context), io = CompletionIO(), d = try root(), j = try journal(c, io, d), peer = CompletionPeer()
        try await j.enqueue(c, lease: CalendarReadLease()); peer.loseClose = true
        let sender = ChildTaskCompletionSender(scope: scope, journal: j, service: peer, current: { scope }, canSend: { _ in false })
        do { _ = try await sender.resolve(c); XCTFail("Lost close reply") } catch {}
        let initial = try await j.load(); XCTAssertEqual(initial.entries[0].phase, .attempted)
        sender.close()
        let fresh = ChildTaskFieldClientScope(account: scope.account, origin: scope.origin, workspace: UUID(), session: UUID(), access: UUID())
        let cold = try journal(c, io, d), retry = ChildTaskCompletionSender(scope: fresh, journal: cold, service: peer, current: { fresh }, canSend: { _ in false })
        let result = try await retry.resolve(c); XCTAssertTrue(result.closed)
        let terminal = try await cold.load(); XCTAssertEqual(terminal.entries[0].phase, .closed); XCTAssertEqual(terminal.entries[0].resolution, result)
        _ = try await retry.resolve(c); XCTAssertEqual(peer.closeCalls, [c, c]); XCTAssertTrue(peer.calls.isEmpty)
        do { _ = try await retry.send(c); XCTFail("Closed request") } catch let error as ChildTaskCompletionFailure { XCTAssertEqual(error.reason, .closed) }
        do { try await cold.enqueue(c, lease: CalendarReadLease()); XCTFail("Cannot revive closed request") } catch {}
    }
    @MainActor func testClosureWriteFailurePreventsReplacementUntilProofRecovered() async throws {
        let c = try command(), r = try read(c, fields: c.body["baseline"]!.object), scope = ChildTaskFieldClientScope(r.context), io = CompletionIO(), j = try journal(c, io, root()), peer = CompletionPeer()
        try await j.enqueue(c, lease: CalendarReadLease()); peer.onClose = { io.failWrite = true }
        let sender = ChildTaskCompletionSender(scope: scope, journal: j, service: peer, current: { scope }, canSend: { _ in true })
        do { _ = try await sender.resolve(c); XCTFail("Closure not durable") } catch {}
        io.failWrite = false; peer.onClose = nil
        var body = c.body; body["request_id"] = .string(UUID().uuidString.lowercased())
        let next = try ChildTaskCompletionCommand(account: c.account, origin: c.origin, body: body)
        do { try await j.replaceClosed(c, with: next, lease: CalendarReadLease()); XCTFail("Missing durable proof") } catch {}
        let attempted = try await j.load(); XCTAssertEqual(attempted.entries[0].phase, .attempted)
        _ = try await sender.resolve(c); try await j.replaceClosed(c, with: next, lease: CalendarReadLease())
        let saved = try await j.load(); XCTAssertEqual(saved.entries.map(\.phase), [.closed, .queued]); XCTAssertEqual(saved.entries[0].command, c); XCTAssertEqual(saved.entries[1].command, next)
        _ = try await sender.send(next); XCTAssertEqual(peer.calls, [next])
    }
    @MainActor func testResolutionRecoversAppliedWriteWithoutMakingReplacement() async throws {
        let c = try command(), r = try read(c, fields: c.body["baseline"]!.object), scope = ChildTaskFieldClientScope(r.context), io = CompletionIO(), j = try journal(c, io, root()), peer = CompletionPeer()
        try await j.enqueue(c, lease: CalendarReadLease()); peer.lose = true
        let sender = ChildTaskCompletionSender(scope: scope, journal: j, service: peer, current: { scope }, canSend: { _ in true })
        do { _ = try await sender.send(c); XCTFail("Lost write reply") } catch {}
        let recovery = ChildTaskCompletionSender(scope: scope, journal: j, service: peer, current: { scope }, canSend: { _ in false })
        let result = try await recovery.resolve(c); XCTAssertFalse(result.closed); XCTAssertEqual(result.receipt?.raw["replayed"], .bool(true))
        let saved = try await j.load(); XCTAssertEqual(saved.entries[0].phase, .confirmed)
        var body = c.body; body["request_id"] = .string(UUID().uuidString.lowercased())
        do { try await j.replaceClosed(c, with: ChildTaskCompletionCommand(account: c.account, origin: c.origin, body: body), lease: CalendarReadLease()); XCTFail("Applied original") } catch {}
        _ = try await recovery.resolve(c); XCTAssertEqual(peer.closeCalls, [c]); XCTAssertEqual(peer.calls, [c])
    }
    @MainActor func testLateCloseSuccessAndErrorDoNotCrossScope() async throws {
        for lose in [false, true] {
            let c = try command(), r = try read(c, fields: c.body["baseline"]!.object), scope = ChildTaskFieldClientScope(r.context), io = CompletionIO(), j = try journal(c, io, root()), peer = CompletionPeer()
            var current: ChildTaskFieldClientScope? = scope
            try await j.enqueue(c, lease: CalendarReadLease()); peer.loseClose = lose; peer.onClose = { current = nil }
            let sender = ChildTaskCompletionSender(scope: scope, journal: j, service: peer, current: { current }, canSend: { _ in false })
            do { _ = try await sender.resolve(c); XCTFail("Late close decision") } catch is CancellationError {} catch { XCTFail("Wrong stale error") }
            let state = try await j.load(); XCTAssertEqual(state.entries[0].phase, .attempted)
        }
    }
    @MainActor func testClosedSenderNeverStartsResolution() async throws {
        let c = try command(), r = try read(c, fields: c.body["baseline"]!.object), scope = ChildTaskFieldClientScope(r.context), io = CompletionIO(), j = try journal(c, io, root()), peer = CompletionPeer()
        try await j.enqueue(c, lease: CalendarReadLease())
        let sender = ChildTaskCompletionSender(scope: scope, journal: j, service: peer, current: { scope }, canSend: { _ in false }); sender.close()
        do { _ = try await sender.resolve(c); XCTFail("Closed owner") } catch is CancellationError {} catch { XCTFail("Wrong cancellation") }
        let state = try await j.load(); XCTAssertEqual(state.entries[0].phase, .queued); XCTAssertTrue(peer.closeCalls.isEmpty)
    }
    @MainActor func testLaterRequestCanResolveButCannotReplaceAcrossOtherPendingIntent() async throws {
        let c = try command(), r = try read(c, fields: c.body["baseline"]!.object), scope = ChildTaskFieldClientScope(r.context), io = CompletionIO(), j = try journal(c, io, root()), peer = CompletionPeer()
        var body = c.body; body["request_id"] = .string(UUID().uuidString.lowercased())
        let later = try ChildTaskCompletionCommand(account: c.account, origin: c.origin, body: body)
        try await j.enqueue(c, lease: CalendarReadLease()); try await j.enqueue(later, lease: CalendarReadLease())
        let sender = ChildTaskCompletionSender(scope: scope, journal: j, service: peer, current: { scope }, canSend: { _ in false })
        _ = try await sender.resolve(later)
        let state = try await j.load(); XCTAssertEqual(state.entries.map(\.phase), [.queued, .closed])
        body["request_id"] = .string(UUID().uuidString.lowercased())
        do { try await j.replaceClosed(later, with: ChildTaskCompletionCommand(account: c.account, origin: c.origin, body: body), lease: CalendarReadLease()); XCTFail("Another saved intent") } catch {}
    }
    @MainActor func testClosedUndoCanBeReplacedWithFreshUndoKeepingParentProof() async throws {
        let c = try command(), r = try read(c, fields: c.body["baseline"]!.object), scope = ChildTaskFieldClientScope(r.context), io = CompletionIO(), j = try journal(c, io, root()), peer = CompletionPeer()
        try await j.enqueue(c, lease: CalendarReadLease())
        let sender = ChildTaskCompletionSender(scope: scope, journal: j, service: peer, current: { scope }, canSend: { _ in true })
        let proof = try await sender.send(c), old = try undo(c, proof: proof)
        try await j.enqueue(old, lease: CalendarReadLease()); _ = try await sender.resolve(old)
        let next = try undo(c, proof: proof); try await j.replaceClosed(old, with: next, lease: CalendarReadLease())
        let result = try await sender.send(next); XCTAssertEqual(result.raw["action"], .string("undo"))
        let state = try await j.load(); XCTAssertEqual(state.entries.map(\.phase), [.confirmed, .closed, .confirmed]); XCTAssertEqual(peer.calls, [c, next])
    }
    func testClosedProofCannotOverwriteConfirmedProof() async throws {
        let c = try command(), io = CompletionIO(), j = try journal(c, io, root()), proof = try completionReply(c)
        try await j.enqueue(c, lease: CalendarReadLease()); _ = try await j.attempt(c, lease: CalendarReadLease()); try await j.confirm(c, receipt: proof, lease: CalendarReadLease())
        do { try await j.resolve(c, decision: completionDecision(c), lease: CalendarReadLease()); XCTFail("Cannot close applied result") } catch {}
        let state = try await j.load(); XCTAssertEqual(state.entries[0].receipt, proof)
    }
    func testCorruptStoredTerminalProofCannotBeUsedOrOverwritten() async throws {
        let c = try command(), io = CompletionIO(), j = try journal(c, io, root()); try await j.enqueue(c, lease: CalendarReadLease())
        let key = try XCTUnwrap(io.rows.keys.first)
        var raw = try JSONDecoder().decode([String: JSON].self, from: XCTUnwrap(io.rows[key])), entry = raw["entries"]!.list[0].object
        var decision = try completionDecision(c).raw; decision["request_id"] = .string(UUID().uuidString.lowercased())
        entry["phase"] = .string("closed"); entry["resolution"] = .object(["raw": .object(decision)]); raw["entries"] = .array([.object(entry)])
        let corrupt = try JSONEncoder().encode(raw); io.rows[key] = corrupt
        do { _ = try await j.load(); XCTFail("Foreign terminal proof") } catch {}
        do { try await j.enqueue(c, lease: CalendarReadLease()); XCTFail("No overwrite") } catch {}
        XCTAssertEqual(io.rows[key], corrupt)
    }
    @MainActor func testBackendResolutionUsesExactBodyAndBoundedPrivateTransport() async throws {
        let c = try command(), backend = try backend(c.account), proof = try completionDecision(c)
        defer { CompletionHTTP.handler = nil }
        CompletionHTTP.handler = { request, pipe in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_close_child_completion"); XCTAssertFalse(request.httpShouldHandleCookies); XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            var bytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf: buffer.prefix(n)) } }
            XCTAssertEqual(try! JSONDecoder().decode([String: JSON].self, from: bytes), ["_body": .object(c.body)])
            pipe.finish(200, try! JSONEncoder().encode(proof.raw))
        }
        let result = try await backend.closeChildTaskCompletionCommand(c, session: backend.reminderSessionIncarnation); XCTAssertEqual(result, proof)
    }
    @MainActor func testBackendRejectsMalformedOrOversizedCloseAndSanitizesErrors() async throws {
        let c = try command(), backend = try backend(c.account), proof = try completionDecision(c)
        defer { CompletionHTTP.handler = nil }
        let normal = String(decoding: try JSONEncoder().encode(proof.raw), as: UTF8.self)
        let duplicate = normal.replacingOccurrences(of: "\"outcome\":\"closed\"", with: "\"outcome\":\"closed\",\"outcome\":\"closed\"")
        XCTAssertNotEqual(normal, duplicate)
        var bad = proof.raw; bad["outcome"] = .string("applied")
        for bytes in [Data(duplicate.utf8), try JSONEncoder().encode(bad), Data(repeating: 32, count: 16385)] {
            CompletionHTTP.handler = { _, pipe in pipe.finish(200, bytes) }
            do { _ = try await backend.closeChildTaskCompletionCommand(c, session: backend.reminderSessionIncarnation); XCTFail("Unconfirmed close") }
            catch let error as ChildTaskCompletionFailure { XCTAssertEqual(error.reason, .unconfirmed) }
        }
        CompletionHTTP.handler = { _, pipe in pipe.finish(409, Data("{\"code\":\"PT409\",\"message\":\"PRIVATE DETAILS\"}".utf8)) }
        do { _ = try await backend.closeChildTaskCompletionCommand(c, session: backend.reminderSessionIncarnation); XCTFail("Refusal") }
        catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE DETAILS")) }
    }
    @MainActor func testBackendResolutionRejectsWrongSessionBeforeNetwork() async throws {
        let c = try command(), backend = try backend(c.account)
        defer { CompletionHTTP.handler = nil }; CompletionHTTP.handler = { _, _ in XCTFail("Must not send") }
        do { _ = try await backend.closeChildTaskCompletionCommand(c, session: UUID()); XCTFail("Stale session") } catch is CancellationError {} catch { XCTFail("Wrong cancellation") }
    }

}

extension ChildTaskCompletionCommandTests {
    @MainActor func testPresentationQueuesOfflineAndColdRetryRefreshesOnce() async throws {
        let c = try command(), r = try read(c, fields: c.body["baseline"]!.object), scope = ChildTaskFieldClientScope(r.context)
        let io = CompletionIO(), directory = try root(), j = try journal(c, io, directory), peer = CompletionPeer()
        var online = false, refreshes = 0
        let model = ChildTaskCompletionRecoveryModel(scope: scope, journal: j, service: peer, current: { scope }, canQueue: { _ in true }, canSend: { _ in online }, refresh: { refreshes += 1 })
        let pending = await model.perform(read: r, key: c.body["node_key"]!.text, action: .complete)
        let saved = try XCTUnwrap(pending)
        XCTAssertEqual(model.entries.first?.phase, .queued); XCTAssertEqual(peer.calls.count, 0); XCTAssertEqual(refreshes, 0)
        model.close(); XCTAssertTrue(model.entries.isEmpty)
        online = true
        let cold = ChildTaskCompletionRecoveryModel(scope: scope, journal: try journal(c, io, directory), service: peer, current: { scope }, canQueue: { _ in true }, canSend: { _ in online }, refresh: { refreshes += 1 })
        await cold.load(); await cold.send(saved)
        XCTAssertEqual(cold.entries.first?.phase, .confirmed); XCTAssertEqual(peer.calls.count, 1); XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(cold.message, "Completion confirmed.")
    }
    @MainActor func testPresentationLostReplyRemainsAttemptedThenChecksApplied() async throws {
        let c = try command(), r = try read(c, fields: c.body["baseline"]!.object), scope = ChildTaskFieldClientScope(r.context)
        let j = try journal(c, CompletionIO(), root()), peer = CompletionPeer(); peer.lose = true
        var refreshes = 0
        let model = ChildTaskCompletionRecoveryModel(scope: scope, journal: j, service: peer, current: { scope }, canQueue: { _ in true }, canSend: { _ in true }, refresh: { refreshes += 1 })
        _ = await model.perform(read: r, key: c.body["node_key"]!.text, action: .complete)
        let saved = try XCTUnwrap(model.entries.first)
        XCTAssertEqual(saved.phase, .attempted); XCTAssertEqual(refreshes, 0)
        await model.resolve(saved.command)
        XCTAssertEqual(model.entries.first?.phase, .confirmed); XCTAssertEqual(peer.calls.count, 1); XCTAssertEqual(peer.closeCalls.count, 1); XCTAssertEqual(refreshes, 1)
    }
    @MainActor func testPresentationStopAndReplacementOnlySavesFreshAction() async throws {
        let c = try command(), r = try read(c, fields: c.body["baseline"]!.object), scope = ChildTaskFieldClientScope(r.context)
        let j = try journal(c, CompletionIO(), root()), peer = CompletionPeer()
        var online = false
        let model = ChildTaskCompletionRecoveryModel(scope: scope, journal: j, service: peer, current: { scope }, canQueue: { _ in true }, canSend: { _ in online }, refresh: {})
        let pending = await model.perform(read: r, key: c.body["node_key"]!.text, action: .complete)
        let saved = try XCTUnwrap(pending); await model.resolve(saved)
        let stopped = try XCTUnwrap(model.entries.first); XCTAssertEqual(stopped.phase, .closed)
        online = true
        let replacement = await model.replace(stopped, read: r)
        XCTAssertNotNil(replacement); XCTAssertNotEqual(replacement?.id, saved.id)
        XCTAssertEqual(model.entries.last?.phase, .queued); XCTAssertTrue(peer.calls.isEmpty)
    }
    @MainActor func testPresentationDepartureHidesLateReplyAndKeepsAttemptPrivate() async throws {
        let c = try command(), r = try read(c, fields: c.body["baseline"]!.object), scope = ChildTaskFieldClientScope(r.context)
        let j = try journal(c, CompletionIO(), root()), peer = CompletionPeer()
        var current: ChildTaskFieldClientScope? = scope, refreshes = 0
        peer.onReply = { current = nil }
        let model = ChildTaskCompletionRecoveryModel(scope: scope, journal: j, service: peer, current: { current }, canQueue: { _ in true }, canSend: { _ in true }, refresh: { refreshes += 1 })
        _ = await model.perform(read: r, key: c.body["node_key"]!.text, action: .complete)
        XCTAssertTrue(model.entries.isEmpty); XCTAssertNil(model.message); XCTAssertEqual(refreshes, 0)
        let state = try await j.load(); XCTAssertEqual(state.entries.first?.phase, .attempted)
    }
    @MainActor func testPresentationRefusesQueueAfterEditingAccessLoss() async throws {
        let c = try command(), r = try read(c, fields: c.body["baseline"]!.object), scope = ChildTaskFieldClientScope(r.context)
        let j = try journal(c, CompletionIO(), root()), peer = CompletionPeer()
        let model = ChildTaskCompletionRecoveryModel(scope: scope, journal: j, service: peer, current: { scope }, canQueue: { _ in false }, canSend: { _ in true }, refresh: {})
        let saved = await model.perform(read: r, key: c.body["node_key"]!.text, action: .complete)
        XCTAssertNil(saved); let state = try await j.load(); XCTAssertTrue(state.entries.isEmpty); XCTAssertTrue(peer.calls.isEmpty)
    }
}

extension ChildTaskCompletionCommandTests {
    @MainActor func testPresentationUndoUsesFreshReadAndPreservesOriginalProof() async throws {
        let c = try command(), r = try read(c, fields: c.body["baseline"]!.object), scope = ChildTaskFieldClientScope(r.context)
        let j = try journal(c, CompletionIO(), root()), peer = CompletionPeer()
        let model = ChildTaskCompletionRecoveryModel(scope: scope, journal: j, service: peer, current: { scope }, canQueue: { _ in true }, canSend: { _ in true }, refresh: {})
        _ = await model.perform(read: r, key: c.body["node_key"]!.text, action: .complete)
        let entry = try XCTUnwrap(model.entries.first), receipt = try XCTUnwrap(entry.receipt)
        let current = try read(entry.command, fields: receipt.raw["after"]!.object, revision: Double(receipt.raw["revision"]!.integer), session: scope.session)
        let context = try ChildTaskRecordContext(account: scope.account, origin: scope.origin, workspace: scope.workspace, session: scope.session, access: scope.access, snapshot: UUID(), root: current.context.root)
        let node = try XCTUnwrap(current.orderedNodes.first)
        let data: [String: JSON] = ["protocol": .number(1), "account": .string(scope.account), "task_id": c.body["task_id"]!, "task_generation": c.body["task_generation"]!, "project_id": c.body["project_id"]!, "projection_revision": .number(node.revision), "root_kind": .string("array"), "records": .array([.object(["node_key": .string(node.key), "incarnation": .string(node.incarnation), "revision": .number(node.revision), "parent_key": .null, "sibling_order": .number(0), "identity_path": .array([.string(node.key)]), "fields": .object(node.fields), "children_kind": .string("absent")])])]
        let fresh = try ChildTaskRecordRead(data: JSONEncoder().encode(data), context: context)
        await model.undo(entry, read: fresh)
        XCTAssertEqual(model.entries.count, 2); XCTAssertEqual(model.entries.last?.phase, .confirmed)
        XCTAssertEqual(model.entries.last?.command.original?.body, entry.command.body)
        XCTAssertEqual(model.entries.last?.receipt?.raw["after"]?.object["completed_at"], entry.receipt?.raw["before"]?.object["completed_at"])
        XCTAssertEqual(peer.calls.count, 2); XCTAssertEqual(model.message, "Undo confirmed.")
    }
    @MainActor func testPresentationDoesNotSendWhenDurableSaveFails() async throws {
        let c = try command(), r = try read(c, fields: c.body["baseline"]!.object), scope = ChildTaskFieldClientScope(r.context)
        let io = CompletionIO(); io.failWrite = true
        let j = try journal(c, io, root()), peer = CompletionPeer()
        let model = ChildTaskCompletionRecoveryModel(scope: scope, journal: j, service: peer, current: { scope }, canQueue: { _ in true }, canSend: { _ in true }, refresh: {})
        let pending = await model.perform(read: r, key: c.body["node_key"]!.text, action: .complete)
        XCTAssertNil(pending); XCTAssertTrue(peer.calls.isEmpty); XCTAssertTrue(model.entries.isEmpty); XCTAssertNotNil(model.message)
    }
}
