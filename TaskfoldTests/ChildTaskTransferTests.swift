import XCTest
import CryptoKit
@testable import TaskfoldCore

private final class TransferMemoryIO: CalendarSecureItemIO, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    var failWrite = false
    var failAfterWrite = false
    func read(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func write(_ value: Data, key: String) throws { lock.lock(); defer { lock.unlock() }; if failWrite { throw URLError(.cannotWriteToFile) }; data = value; if failAfterWrite { throw URLError(.cannotWriteToFile) } }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; data = nil }
}
@MainActor private final class TransferService: ChildTaskTransferService {
    var calls: [ChildTaskTransferOperation] = []
    var raw: [String: JSON]
    var loseReply = false
    var beforeReply: (() -> Void)?
    init(_ raw: [String: JSON]) { self.raw = raw }
    func childTaskTransfer(_ command: ChildTaskTransferCommand, operation: ChildTaskTransferOperation, session: UUID) async throws -> ChildTaskTransferResult {
        calls.append(operation); beforeReply?()
        if loseReply { throw URLError(.networkConnectionLost) }
        return try command.result(raw)
    }
}
private final class TransferHTTP: URLProtocol {
    static var handler: ((URLRequest, TransferHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func finish(_ status: Int, _ data: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}

final class ChildTaskTransferTests: XCTestCase {
    let origin = "https://cross-root.test"
    struct Tokens { let workspace = UUID(), session = UUID(), access = UUID(), snapshot = UUID() }
    func fixture() throws -> [String: JSON] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cross-root-transfer-client-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
    }
    func bytes(_ raw: [String: JSON]) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(raw) }
    func command(_ f: [String: JSON], name: String = "command") throws -> ChildTaskTransferCommand {
        let body = try XCTUnwrap(f[name]?.object); return try .init(account: body["account"]!.text, origin: origin, body: body)
    }
    func read(_ f: [String: JSON], side: String, after: Bool = false, tokens: Tokens, change: ((inout Record, inout [String: JSON]) -> Void)? = nil) throws -> ChildTaskStructureRead {
        let prefix = after ? "after" + side.prefix(1).uppercased() + side.dropFirst() : side
        var root = Record(f[prefix + "Root"]!.object), raw = f[prefix + "Read"]!.object; change?(&root, &raw)
        let context = try ChildTaskRecordContext(account: f["command"]!.object["account"]!.text, origin: origin, workspace: tokens.workspace, session: tokens.session, access: tokens.access, snapshot: tokens.snapshot, root: root)
        return try .init(data: bytes(raw), context: context)
    }
    func directory() throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-transfer-test-" + UUID().uuidString); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url }
    func journal(_ c: ChildTaskTransferCommand, io: any CalendarSecureItemIO, root: URL) throws -> ChildTaskTransferJournal { try .init(account: c.account, origin: c.origin, io: io, coordinationDirectory: root.appendingPathComponent("locks"), removalDirectory: root.appendingPathComponent("removal")) }
    func testActualSQLCommandIsRebuiltFromBothReadsWithoutAnySubtreePayload() throws {
        let f = try fixture(), c = try command(f), tokens = Tokens()
        let from = try read(f, side: "source", tokens: tokens), to = try read(f, side: "destination", tokens: tokens)
        let built = try ChildTaskTransferCommand(node: c.body["node_key"]!.text, parent: c.body["destination"]!.object["parent_key"]!.text, index: 0, source: from, destination: to, requestID: XCTUnwrap(UUID(uuidString: c.id)))
        XCTAssertEqual(built, c); XCTAssertNoThrow(try c.result(f["receipt"]!.object))
        XCTAssertFalse(String(data: try bytes(c.body), encoding: .utf8)!.contains("Private design"))
        XCTAssertEqual(try ChildTaskTransferCommand(data: JSONEncoder().encode(c)), c)
    }
    func testActualUndoUsesFreshTwoRootCertificatesAndExactOriginalPlacement() throws {
        let f = try fixture(), c = try command(f), tokens = Tokens(), receipt = try c.result(f["receipt"]!.object)
        let undo = try ChildTaskTransferCommand(undo: c, receipt: receipt, source: read(f, side: "destination", after: true, tokens: tokens), destination: read(f, side: "source", after: true, tokens: tokens), requestID: XCTUnwrap(UUID(uuidString: f["undoCommand"]!.object["request_id"]!.text)))
        XCTAssertEqual(undo, try command(f, name: "undoCommand")); XCTAssertNoThrow(try undo.result(f["undo"]!.object))
    }
    func testActualUnknownAndTerminalProofsCannotBeConfusedWithAppliedMoves() throws {
        let f = try fixture(), c = try command(f), closed = try command(f, name: "closedCommand")
        XCTAssertTrue(try c.result(f["unknown"]!.object).unknown)
        XCTAssertTrue(try closed.result(f["closed"]!.object).closed)
        XCTAssertThrowsError(try c.result(f["closed"]!.object))
    }
    func testBothReadsMustBelongToSameWorkspaceSessionAccessAndSnapshot() throws {
        let f = try fixture(), c = try command(f), a = try read(f, side: "source", tokens: Tokens()), b = try read(f, side: "destination", tokens: Tokens())
        XCTAssertThrowsError(try c.review(source: a, destination: b))
    }
    func testNewerBranchFieldVersionBlocksAnOldMoveWithoutDiscardingNotes() throws {
        let f = try fixture(), c = try command(f), tokens = Tokens()
        let a = try read(f, side: "source", tokens: tokens) { root, raw in
            root["subtasks"] = SubtaskTree.changing(root["subtasks"], id: "branch", fields: ["description": .string("Newer remote notes")])
            var records = raw["records"]!.list
            let i = records.firstIndex { $0.object["node_key"] == .string("branch") }!; var row = records[i].object
            var fields = row["fields"]!.object; fields["description"] = .string("Newer remote notes"); row["fields"] = .object(fields); row["revision"] = .number(2); records[i] = .object(row); raw["records"] = .array(records)
        }
        XCTAssertThrowsError(try c.review(source: a, destination: read(f, side: "destination", tokens: tokens)))
        XCTAssertEqual(a.records.nodes["branch"]?.fields["description"], .string("Newer remote notes"))
    }
    func testMalformedExtraFieldsSlotsAndCountersAreRefused() throws {
        let f = try fixture(), c = try command(f)
        var bodies: [[String: JSON]] = []
        var body = c.body; body["title"] = .string("Unexpected plaintext"); bodies.append(body)
        body = c.body; var to = body["destination"]!.object; to["index"] = .number(-1); body["destination"] = .object(to); bodies.append(body)
        body = c.body; to = body["destination"]!.object; to["index"] = .number(0.5); body["destination"] = .object(to); bodies.append(body)
        body = c.body; body["source"] = body["destination"]; bodies.append(body)
        body = c.body; body["subtree_versions"] = .object([:]); bodies.append(body)
        for body in bodies { XCTAssertThrowsError(try ChildTaskTransferCommand(account: c.account, origin: origin, body: body)) }
    }
    func testDecimalWireCountersAndUnknownReceiptContentAreRefused() throws {
        let f = try fixture(), c = try command(f), raw = f["receipt"]!.object
        let data = String(data: try bytes(raw), encoding: .utf8)!.replacingOccurrences(of: "\"protocol\":1", with: "\"protocol\":1.0")
        XCTAssertThrowsError(try ChildTaskTransferResult(command: c, data: Data(data.utf8)))
        var extra = raw; extra["task"] = .object(["title": .string("Unexpected historical content")]); XCTAssertThrowsError(try c.result(extra))
        var wrong = raw; wrong["moved_count"] = .number(1); XCTAssertThrowsError(try c.result(wrong))
    }
    func testJournalSurvivesRecreationAndProtectsBothRootsFromOverlappingMoves() async throws {
        let f = try fixture(), c = try command(f), io = TransferMemoryIO(), root = try directory(), first = try journal(c, io: io, root: root)
        try await first.enqueue(c, lease: CalendarReadLease())
        let reopened = try journal(c, io: io, root: root), saved = try await reopened.load(); XCTAssertEqual(saved.entries.map(\.command), [c])
        var body = c.body; body["request_id"] = .string(UUID().uuidString.lowercased()); let other = try ChildTaskTransferCommand(account: c.account, origin: origin, body: body)
        do { try await reopened.enqueue(other, lease: CalendarReadLease()); XCTFail("Overlapping destination root must remain serialized") } catch {}
        _ = try await reopened.attempt(c, lease: CalendarReadLease())
        do { try await reopened.discard(c, lease: CalendarReadLease()); XCTFail("An uncertain move must be stopped on the server") } catch {}
        let after = try await reopened.load(); XCTAssertEqual(after.entries.first?.phase, .attempted)
    }
    func testTerminalClosureCannotBeChangedIntoAnAppliedMove() async throws {
        let f = try fixture(), c = try command(f, name: "closedCommand"), io = TransferMemoryIO(), root = try directory(), j = try journal(c, io: io, root: root), lease = CalendarReadLease()
        try await j.enqueue(c, lease: lease); _ = try await j.attempt(c, lease: lease); let closed = try c.result(f["closed"]!.object); try await j.settle(c, result: closed, lease: lease)
        var forged = f["closed"]!.object; forged["state"] = .string("applied"); forged["moved_count"] = .number(Double(c.body["subtree_versions"]!.object.count)); forged["return_parent"] = .null; forged["return_index"] = .number(0)
        do { try await j.settle(c, result: c.result(forged), lease: lease); XCTFail("A permanent stop must remain stopped") } catch {}
        let state = try await j.load(); XCTAssertEqual(state.entries.first?.phase, .closed)
    }
    func testUnsentRemovalAndExplicitSettledFamilyRemovalDoNotMutateTasks() async throws {
        let f = try fixture(), c = try command(f), io = TransferMemoryIO(), root = try directory(), j = try journal(c, io: io, root: root), lease = CalendarReadLease()
        try await j.enqueue(c, lease: lease); try await j.discard(c, lease: lease); let empty = try await j.load(); XCTAssertTrue(empty.entries.isEmpty)
        try await j.enqueue(c, lease: lease); _ = try await j.attempt(c, lease: lease); try await j.settle(c, result: c.result(f["receipt"]!.object), lease: lease); try await j.discard(c, lease: lease)
        let again = try await j.load(); XCTAssertTrue(again.entries.isEmpty)
    }
    @MainActor func testLostReplyKeepsOriginalIdentityAndColdRetryConfirmsOnce() async throws {
        let f = try fixture(), c = try command(f), io = TransferMemoryIO(), root = try directory(), j = try journal(c, io: io, root: root), tokens = Tokens(), a = try read(f, side: "source", tokens: tokens), b = try read(f, side: "destination", tokens: tokens), scope = ChildTaskFieldClientScope(a.context), service = TransferService(f["receipt"]!.object)
        service.loseReply = true
        let first = ChildTaskTransferModel(scope: scope, journal: j, service: service, current: { scope }, canSend: { _ in true }, admit: { _, _, _ in })
        let queued = await first.queue(c, source: a, destination: b); XCTAssertTrue(queued)
        let sent = await first.run(c, operation: .send); XCTAssertFalse(sent); XCTAssertEqual(first.entries.first?.phase, .attempted); first.close()
        service.loseReply = false
        let cold = ChildTaskTransferModel(scope: scope, journal: try journal(c, io: io, root: root), service: service, current: { scope }, canSend: { _ in true }, admit: { _, _, _ in })
        await cold.load(); XCTAssertEqual(cold.entries.first?.command, c)
        let retried = await cold.run(c, operation: .send); XCTAssertTrue(retried); XCTAssertEqual(cold.entries.first?.phase, .applied); XCTAssertEqual(service.calls, [.send, .send])
    }
    @MainActor func testAccessLossStillAllowsMetadataStatusRecoveryButNotSend() async throws {
        let f = try fixture(), c = try command(f), root = try directory(), j = try journal(c, io: TransferMemoryIO(), root: root), tokens = Tokens(), a = try read(f, side: "source", tokens: tokens), b = try read(f, side: "destination", tokens: tokens), scope = ChildTaskFieldClientScope(a.context), service = TransferService(f["receipt"]!.object)
        let model = ChildTaskTransferModel(scope: scope, journal: j, service: service, current: { scope }, canSend: { _ in false }, admit: { _, _, _ in })
        let queued = await model.queue(c, source: a, destination: b); XCTAssertTrue(queued)
        let send = await model.run(c, operation: .send); XCTAssertFalse(send); XCTAssertTrue(service.calls.isEmpty)
        let check = await model.run(c, operation: .check); XCTAssertTrue(check); XCTAssertEqual(service.calls, [.check]); XCTAssertEqual(model.entries.first?.phase, .applied)
    }
    @MainActor func testUnknownStatusKeepsUncertainMoveAndPreventsLocalDiscard() async throws {
        let f = try fixture(), c = try command(f), root = try directory(), j = try journal(c, io: TransferMemoryIO(), root: root), tokens = Tokens(), a = try read(f, side: "source", tokens: tokens), b = try read(f, side: "destination", tokens: tokens), scope = ChildTaskFieldClientScope(a.context), service = TransferService(f["unknown"]!.object)
        let model = ChildTaskTransferModel(scope: scope, journal: j, service: service, current: { scope }, canSend: { _ in true }, admit: { _, _, _ in })
        _ = await model.queue(c, source: a, destination: b); _ = await model.run(c, operation: .check); await model.discard(c)
        XCTAssertEqual(model.entries.first?.phase, .attempted); XCTAssertTrue(model.message?.contains("saved") == true)
    }
    @MainActor func testAccountSwitchDuringReplyCannotConfirmIntoAnotherWorkspace() async throws {
        let f = try fixture(), c = try command(f), root = try directory(), j = try journal(c, io: TransferMemoryIO(), root: root), tokens = Tokens(), a = try read(f, side: "source", tokens: tokens), b = try read(f, side: "destination", tokens: tokens), scope = ChildTaskFieldClientScope(a.context), service = TransferService(f["receipt"]!.object)
        var current: ChildTaskFieldClientScope? = scope
        let model = ChildTaskTransferModel(scope: scope, journal: j, service: service, current: { current }, canSend: { _ in true }, admit: { _, _, _ in })
        _ = await model.queue(c, source: a, destination: b); service.beforeReply = { current = nil }
        let result = await model.run(c, operation: .send); XCTAssertFalse(result); XCTAssertTrue(model.entries.isEmpty)
        let saved = try await j.load(); XCTAssertEqual(saved.entries.first?.phase, .attempted)
    }
    @MainActor func testFailedAttemptWriteNeverStartsNetwork() async throws {
        let f = try fixture(), c = try command(f), io = TransferMemoryIO(), root = try directory(), j = try journal(c, io: io, root: root), tokens = Tokens(), a = try read(f, side: "source", tokens: tokens), b = try read(f, side: "destination", tokens: tokens), scope = ChildTaskFieldClientScope(a.context), service = TransferService(f["receipt"]!.object)
        let model = ChildTaskTransferModel(scope: scope, journal: j, service: service, current: { scope }, canSend: { _ in true }, admit: { _, _, _ in })
        _ = await model.queue(c, source: a, destination: b); io.failWrite = true
        let result = await model.run(c, operation: .send); XCTAssertFalse(result); XCTAssertTrue(service.calls.isEmpty); XCTAssertEqual(model.entries.first?.phase, .queued)
    }
    func testEncryptedJournalRejectsWrongDeviceKeyAndRemovesOwnedFile() async throws {
        let f = try fixture(), c = try command(f), root = try directory(), key = SymmetricKey(data: Data(repeating: 53, count: 32))
        let io = ReviewedTeamCommandFileIO<ChildTaskTransferState>(directory: root.appendingPathComponent("encrypted"), account: c.account, origin: c.origin, encryptionKey: { key }), j = try journal(c, io: io, root: root)
        try await j.enqueue(c, lease: CalendarReadLease())
        let ciphertext = try Data(contentsOf: io.file); XCTAssertFalse(String(data: ciphertext, encoding: .utf8)?.contains(c.id) == true)
        let wrong = ReviewedTeamCommandFileIO<ChildTaskTransferState>(directory: root.appendingPathComponent("encrypted"), account: c.account, origin: c.origin, encryptionKey: { SymmetricKey(data: Data(repeating: 54, count: 32)) })
        do { _ = try await journal(c, io: wrong, root: root).load(); XCTFail("Wrong key must not expose pending requests") } catch {}
        try await j.removeAccount(); XCTAssertFalse(FileManager.default.fileExists(atPath: io.file.path))
    }
    @MainActor func testConfirmationWriteThatFinishesBeforeIOErrorIsRecoveredWithoutResending() async throws {
        let f = try fixture(), c = try command(f), io = TransferMemoryIO(), root = try directory(), j = try journal(c, io: io, root: root), tokens = Tokens(), a = try read(f, side: "source", tokens: tokens), b = try read(f, side: "destination", tokens: tokens), scope = ChildTaskFieldClientScope(a.context), service = TransferService(f["receipt"]!.object)
        let model = ChildTaskTransferModel(scope: scope, journal: j, service: service, current: { scope }, canSend: { _ in true }, admit: { _, _, _ in })
        _ = await model.queue(c, source: a, destination: b)
        service.beforeReply = { io.failAfterWrite = true }
        let result = await model.run(c, operation: .send)
        XCTAssertTrue(result); XCTAssertEqual(model.entries.first?.phase, .applied); XCTAssertEqual(model.message, "Subtask moved."); XCTAssertEqual(service.calls, [.send])
    }
    func testCancelledLeaseAndAccountRemovalFencePreventNewJournalWrites() async throws {
        let f = try fixture(), c = try command(f), io = TransferMemoryIO(), root = try directory(), j = try journal(c, io: io, root: root)
        let cancelled = CalendarReadLease(); cancelled.cancel()
        do { try await j.enqueue(c, lease: cancelled); XCTFail("A cancelled workspace must not write") } catch {}
        XCTAssertNil(try io.read(key: "unused"))
        try AccountRemovalDisk(directory: root.appendingPathComponent("removal"), account: c.account).removeCache()
        do { try await j.enqueue(c, lease: CalendarReadLease()); XCTFail("Account removal must fence new moves") } catch {}
        XCTAssertNil(try io.read(key: "unused"))
    }
    @MainActor func testActualBackendUsesPrivateBoundedTransferRouteForAllOperations() async throws {
        let f = try fixture(), c = try command(f)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TransferHTTP.self]
        let session = try JSONDecoder().decode(Session.self, from: bytes(["access_token": .string("synthetic"), "refresh_token": .string("synthetic"), "expires_in": .number(3600), "user": .object(["id": .string(c.account)])]))
        let api = Backend(configuration: ["URL": origin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        var calls: [String] = []
        TransferHTTP.handler = { request, peer in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_transfer_child"); XCTAssertEqual(request.timeoutInterval, 25); XCTAssertFalse(request.httpShouldHandleCookies); XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) } }
            let body = try! JSONDecoder().decode([String: JSON].self, from: data); XCTAssertEqual(body["_body"], .object(c.body)); calls.append(body["_operation"]!.text)
            peer.finish(200, try! self.bytes(body["_operation"] == .string("check") ? f["unknown"]!.object : f["receipt"]!.object))
        }; defer { TransferHTTP.handler = nil }
        for operation in [ChildTaskTransferOperation.check, .send, .close] { _ = try await api.childTaskTransfer(c, operation: operation, session: api.reminderSessionIncarnation) }
        XCTAssertEqual(calls, ["check", "send", "close"])
        TransferHTTP.handler = { _, peer in peer.finish(409, try! self.bytes(["code": .string("PT409"), "message": .string("Private internal details")])) }
        do { _ = try await api.childTaskTransfer(c, operation: .send, session: api.reminderSessionIncarnation); XCTFail("Changed work must require review") } catch { XCTAssertTrue(error is ChildTaskTransferFailure); XCTAssertFalse(error.localizedDescription.contains("Private internal")) }
    }
}
