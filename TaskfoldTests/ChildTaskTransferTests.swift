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
    struct Tokens { let workspace = UUID(), access = UUID(), snapshot = UUID(); let session: UUID; init(session: UUID = UUID()) { self.session = session } }
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

extension ChildTaskTransferTests {
    private func redoRead(_ f: [String: JSON], side: String, tokens: Tokens, change: ((inout Record, inout [String: JSON]) -> Void)? = nil) throws -> ChildTaskStructureRead {
        try read(f, side: side, tokens: tokens) { root, raw in
            raw["structure_revision"] = .number(3); raw["projection_revision"] = .number(3)
            raw["records"] = .array(raw["records"]!.list.map { value in var row = value.object; row["revision"] = .number(Double(row["revision"]!.integer + 2)); return .object(row) })
            change?(&root, &raw)
        }
    }
    private func redoCommand(_ f: [String: JSON], tokens: Tokens = Tokens()) throws -> ChildTaskTransferCommand {
        let c = try command(f), u = try command(f, name: "undoCommand")
        return try .init(redo: c, receipt: c.result(f["receipt"]!.object), undo: u, undoReceipt: u.result(f["undo"]!.object), source: redoRead(f, side: "source", tokens: tokens), destination: redoRead(f, side: "destination", tokens: tokens))
    }
    private func appliedProof(_ command: ChildTaskTransferCommand, template: [String: JSON]) throws -> ChildTaskTransferResult {
        var raw = template; raw["request_id"] = .string(command.id); raw["action"] = command.body["action"]; raw["undo_of"] = command.body["undo_of"] ?? .null
        for name in ["source", "destination"] {
            for (field, wire) in [("task_id", "id"), ("task_generation", "generation"), ("project_id", "project"), ("structure_revision", "revision")] { raw[name + "_" + wire] = command.body[name]!.object[field] }
        }
        return try command.result(raw)
    }
    private func seedRedoJournal(_ f: [String: JSON], io: any CalendarSecureItemIO, root: URL) async throws -> (ChildTaskTransferJournal, ChildTaskTransferState.Entry, ChildTaskTransferState.Entry) {
        let c = try command(f), u = try command(f, name: "undoCommand"), j = try journal(c, io: io, root: root), lease = CalendarReadLease()
        for (command, proof) in [(c, f["receipt"]!.object), (u, f["undo"]!.object)] {
            try await j.enqueue(command, lease: lease); _ = try await j.attempt(command, lease: lease); try await j.settle(command, result: command.result(proof), lease: lease)
        }
        let state = try await j.load(); return (j, state.entries[0], state.entries[1])
    }
    func testRedoUsesNewIdentityConfirmedUndoAndOriginalDestinationWithoutContentCopies() throws {
        let f = try fixture(), c = try command(f), u = try command(f, name: "undoCommand"), redo = try redoCommand(f)
        XCTAssertNotEqual(redo.id, c.id); XCTAssertNotEqual(redo.id, u.id); XCTAssertFalse(redo.undoing)
        XCTAssertEqual(redo.body["destination"]!.object["parent_key"], c.body["destination"]!.object["parent_key"])
        XCTAssertEqual(redo.body["source"]!.object["structure_revision"], .number(3))
        XCTAssertEqual(redo.body["subtree_versions"]!.object["branch"]!.object["revision"], .number(3))
        XCTAssertEqual(Set(redo.body.keys), Set(c.body.keys)); XCTAssertFalse(String(data: try bytes(redo.body), encoding: .utf8)!.contains("Private design"))
        let result = try appliedProof(redo, template: f["receipt"]!.object)
        let tokens = Tokens()
        func afterRedo(_ side: String) throws -> ChildTaskStructureRead {
            try read(f, side: side, after: true, tokens: tokens) { _, raw in
                raw["structure_revision"] = .number(4); raw["projection_revision"] = .number(4)
                raw["records"] = .array(raw["records"]!.list.map { value in var row = value.object; row["revision"] = .number(Double(row["revision"]!.integer + 2)); return .object(row) })
            }
        }
        let nextUndo = try ChildTaskTransferCommand(undo: redo, receipt: result, source: afterRedo("destination"), destination: afterRedo("source"))
        XCTAssertEqual(nextUndo.body["undo_of"], .string(redo.id)); XCTAssertNotEqual(nextUndo.id, u.id)
    }
    func testRedoRefusesChangedBranchesDestinationsSessionsAndReusedIdentities() throws {
        let f = try fixture(), c = try command(f), u = try command(f, name: "undoCommand"), tokens = Tokens(), receipt = try c.result(f["receipt"]!.object), reversed = try u.result(f["undo"]!.object)
        func build(_ a: ChildTaskStructureRead, _ b: ChildTaskStructureRead, id: UUID = UUID()) throws -> ChildTaskTransferCommand { try .init(redo: c, receipt: receipt, undo: u, undoReceipt: reversed, source: a, destination: b, requestID: id) }
        let a = try redoRead(f, side: "source", tokens: tokens), b = try redoRead(f, side: "destination", tokens: tokens)
        XCTAssertThrowsError(try build(a, b, id: XCTUnwrap(UUID(uuidString: c.id))))
        XCTAssertThrowsError(try build(a, b, id: XCTUnwrap(UUID(uuidString: u.id))))
        XCTAssertThrowsError(try build(a, redoRead(f, side: "destination", tokens: Tokens())))
        let changed = try redoRead(f, side: "source", tokens: tokens) { _, raw in
            var rows = raw["records"]!.list; var row = rows[1].object; row["revision"] = .number(4); rows[1] = .object(row); raw["records"] = .array(rows)
        }
        XCTAssertThrowsError(try build(changed, b))
        let reorganized = try redoRead(f, side: "destination", tokens: tokens) { _, raw in raw["structure_revision"] = .number(4); raw["projection_revision"] = .number(4) }
        XCTAssertThrowsError(try build(a, reorganized))
        let replacedParent = try redoRead(f, side: "destination", tokens: tokens) { _, raw in
            var rows = raw["records"]!.list; var row = rows[0].object; row["incarnation"] = .string(UUID().uuidString.lowercased()); rows[0] = .object(row); raw["records"] = .array(rows)
        }
        XCTAssertThrowsError(try build(a, replacedParent))
        var wrong = reversed.raw; wrong["request_id"] = .string(UUID().uuidString.lowercased())
        XCTAssertThrowsError(try ChildTaskTransferCommand(redo: c, receipt: receipt, undo: u, undoReceipt: TaskfoldJSONDecoder().decode(ChildTaskTransferResult.self, from: TaskfoldJSONEncoder().encode(["raw": wrong])), source: a, destination: b))
    }
    func testRedoJournalRecoversOneRequestWhenTwoWindowsQueueTheSameUndo() async throws {
        let f = try fixture(), c = try command(f), io = TransferMemoryIO(), root = try directory()
        let (j, original, undo) = try await seedRedoJournal(f, io: io, root: root)
        let second = try journal(c, io: io, root: root), r1 = try redoCommand(f), r2 = try redoCommand(f)
        async let first = j.enqueueRedo(r1, original: original, undo: undo, lease: CalendarReadLease())
        async let other = second.enqueueRedo(r2, original: original, undo: undo, lease: CalendarReadLease())
        let ids = try await [first.id, other.id]; XCTAssertEqual(Set(ids).count, 1)
        let state = try await j.load(); XCTAssertEqual(state.entries.count, 3)
        let saved = try XCTUnwrap(state.entries.last?.command)
        _ = try await j.attempt(saved, lease: CalendarReadLease())
        let retry = try await second.enqueueRedo(redoCommand(f), original: original, undo: undo, lease: CalendarReadLease()); XCTAssertEqual(retry, saved)
        try await j.settle(saved, result: appliedProof(saved, template: f["receipt"]!.object), lease: CalendarReadLease())
        let known = try await second.enqueueRedo(redoCommand(f), original: original, undo: undo, lease: CalendarReadLease()); XCTAssertEqual(known, saved)
    }
    func testRedoCannotBeQueuedAfterItsProofHistoryWasRemoved() async throws {
        let f = try fixture(), io = TransferMemoryIO(), root = try directory()
        let (j, original, undo) = try await seedRedoJournal(f, io: io, root: root)
        try await j.discard(original.command, lease: CalendarReadLease())
        do { _ = try await j.enqueueRedo(redoCommand(f), original: original, undo: undo, lease: CalendarReadLease()); XCTFail("Removed proof history must not authorize a Redo") } catch {}
        let state = try await j.load(); XCTAssertTrue(state.entries.isEmpty)
    }
    @MainActor func testRedoLostHTTPReplyColdRetryKeepsExactEncryptedRequest() async throws {
        let f = try fixture(), c = try command(f), root = try directory(), key = SymmetricKey(data: Data(repeating: 61, count: 32))
        let io = ReviewedTeamCommandFileIO<ChildTaskTransferState>(directory: root.appendingPathComponent("encrypted"), account: c.account, origin: c.origin, encryptionKey: { key })
        let (j, original, undo) = try await seedRedoJournal(f, io: io, root: root)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TransferHTTP.self]
        let session = try JSONDecoder().decode(Session.self, from: bytes(["access_token": .string("synthetic"), "refresh_token": .string("synthetic"), "expires_in": .number(3600), "user": .object(["id": .string(c.account)])]))
        let api = Backend(configuration: ["URL": origin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        let tokens = Tokens(session: api.reminderSessionIncarnation)
        let a = try redoRead(f, side: "source", tokens: tokens), b = try redoRead(f, side: "destination", tokens: tokens), scope = ChildTaskFieldClientScope(a.context)
        var requests: [[String: JSON]] = [], accepted: Set<String> = []
        TransferHTTP.handler = { request, peer in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_transfer_child")
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) } }
            let body = try! JSONDecoder().decode([String: JSON].self, from: data); requests.append(body["_body"]!.object)
            let id = body["_body"]!.object["request_id"]!.text; accepted.insert(id)
            if requests.count == 1 { peer.client?.urlProtocol(peer, didFailWithError: URLError(.networkConnectionLost)); return }
            let command = try! ChildTaskTransferCommand(account: c.account, origin: self.origin, body: body["_body"]!.object)
            var result = try! self.appliedProof(command, template: f["receipt"]!.object).raw; result["replayed"] = .bool(true)
            peer.finish(200, try! self.bytes(result))
        }; defer { TransferHTTP.handler = nil }
        var announced: [String] = []
        func model(_ journal: ChildTaskTransferJournal) -> ChildTaskTransferModel { .init(scope: scope, journal: journal, service: api, current: { scope }, canSend: { _ in true }, admit: { _, _, _ in }, didApply: { announced.append($0.command.id) }) }
        let first = model(j); await first.load(); XCTAssertTrue(first.canRedo(undo))
        let fresh = try first.historyCommand(undo, source: a, destination: b)
        let queued = await first.queueHistory(fresh, reversing: undo, source: a, destination: b); XCTAssertEqual(queued, fresh)
        let sent = await first.run(fresh, operation: .send); XCTAssertFalse(sent); first.close()
        let cold = model(try journal(c, io: io, root: root)); await cold.load()
        let saved = try XCTUnwrap(cold.entries.first { $0.command == fresh }); XCTAssertEqual(saved.phase, .attempted); XCTAssertFalse(cold.canRedo(undo))
        let retried = await cold.run(saved.command, operation: .send); XCTAssertTrue(retried)
        let checkedAgain = await cold.run(saved.command, operation: .check); XCTAssertTrue(checkedAgain)
        XCTAssertEqual(announced, [fresh.id], "Only newly confirmed actions enter native history")
        XCTAssertEqual(requests, [fresh.body, fresh.body]); XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(cold.entries.first { $0.command == fresh }?.phase, .applied)
        XCTAssertEqual(cold.entries.first { $0.command == original.command }?.phase, .applied)
    }
}
