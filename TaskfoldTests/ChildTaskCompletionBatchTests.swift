import XCTest
import CryptoKit
@testable import TaskfoldCore

private final class BatchIO: CalendarSecureItemIO, @unchecked Sendable {
    private let lock = NSLock()
    var rows: [String: Data] = [:]
    var failWrite = false
    func read(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return rows[key] }
    func write(_ data: Data, key: String) throws { lock.lock(); defer { lock.unlock() }; if failWrite { throw URLError(.cannotWriteToFile) }; rows[key] = data }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; rows.removeValue(forKey: key) }
}
private final class BatchHTTP: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, BatchHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func finish(_ status: Int, _ data: Data, headers: [String: String] = [:]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
final class ChildTaskCompletionBatchTests: XCTestCase {
    private let origin = "https://child-batch.test"
    private func fixture() throws -> [String: JSON] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "child-task-completion-batch", withExtension: "json", subdirectory: "Fixtures"))
        return try TaskfoldJSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
    }
    private func command(undo: Bool = false) throws -> ChildTaskCompletionBatchCommand {
        let f = try fixture(), b = f[undo ? "undo" : "command"]!.object
        let items = try b["items"]!.list.map { value -> ChildTaskCompletionCommand in
            let raw = value.object
            let original: ChildTaskCompletionCommand.Original?
            if undo {
                let id = raw["undo_of"]!.text
                original = .init(body: try XCTUnwrap(f["command"]!.object["items"]!.list.first { $0.object["request_id"] == .string(id) }).object,
                                 receipt: try XCTUnwrap(f["receipt"]!.object["receipts"]!.list.first { $0.object["request_id"] == .string(id) }).object)
            } else { original = nil }
            return try .init(account: b["account"]!.text, origin: origin, body: raw, original: original)
        }
        return try .init(account: b["account"]!.text, origin: origin, items: items, batchID: XCTUnwrap(UUID(uuidString: b["batch_id"]!.text)))
    }
    private func item(_ key: String, requestID: UUID = UUID(), root: String? = nil) throws -> ChildTaskCompletionCommand {
        let base = try command().items[0]; var raw = base.body
        raw["request_id"] = .string(requestID.uuidString.lowercased()); raw["node_key"] = .string(key)
        if let root { raw["task_id"] = .string(root) }
        return try .init(account: base.account, origin: base.origin, body: raw)
    }
    private func many(_ count: Int) throws -> ChildTaskCompletionBatchCommand {
        let base = try command()
        return try .init(account: base.account, origin: origin, items: try (0..<count).map { try item("child-\($0)-" + String(repeating: "x", count: 100)) })
    }
    private func reply(_ c: ChildTaskCompletionBatchCommand, closed: Bool = false) throws -> [String: JSON] {
        let receipts = try c.items.map { item -> JSON in
            let before = item.original?.receipt["after"]!.object ?? item.body["baseline"]!.object
            var after = item.original?.receipt["before"]!.object ?? before
            let token = try XCTUnwrap(TeamChecklist.token(before[TeamChecklist.key]))
            after[TeamChecklist.key] = .object(["epoch": .string(token.epoch), "version": .number(token.version + 1)])
            if !item.isUndo {
                let completed = item.body["action"] == .string("complete")
                after["completed"] = .bool(completed); after["completed_at"] = completed ? .string("2026-10-31T00:00:00Z") : .null
            }
            var proof = item.body.filter { !["baseline", "undo_of"].contains($0.key) }
            proof["revision"] = .number(Double(item.body["revision"]!.integer + 1)); proof["undo_of"] = item.body["undo_of"] ?? .null
            proof["before"] = .object(before); proof["after"] = .object(after); proof["replayed"] = .bool(false)
            _ = try item.confirmed(proof); return .object(proof)
        }
        return ["protocol": .number(1), "account": .string(c.account), "batch_id": .string(c.id), "outcome": .string(closed ? "closed" : "applied"), "receipts": .array(closed ? [] : receipts), "replayed": .bool(false)]
    }
    func testActualPostgresApplyAndUndoContractsAgree() throws {
        let f = try fixture(), c = try command(), u = try command(undo: true)
        XCTAssertEqual(c.body, f["command"]!.object); XCTAssertEqual(u.body, f["undo"]!.object)
        XCTAssertEqual(try c.resolution(f["receipt"]!.object).receipts.count, 2)
        XCTAssertEqual(try u.resolution(f["undoReceipt"]!.object).receipts.count, 2)
        XCTAssertTrue(try c.resolution(f["receipt"]!.object).applied)
    }
    func testPartialReorderedAndDuplicateReceiptsCannotCertifyAGroup() throws {
        let c = try command(), proof = try fixture()["receipt"]!.object
        for receipts in [Array(proof["receipts"]!.list.prefix(1)), Array(proof["receipts"]!.list.reversed()), Array(repeating: proof["receipts"]!.list[0], count: 2)] {
            var bad = proof; bad["receipts"] = .array(receipts); XCTAssertThrowsError(try c.resolution(bad))
        }
    }
    func testWrongEnvelopeAndUnknownOutcomesFailClosed() throws {
        let c = try command(), proof = try reply(c)
        for (key,value) in [("protocol",JSON.number(2)),("account",.string(UUID().uuidString.lowercased())),("batch_id",.string(UUID().uuidString.lowercased())),("replayed",.null),("outcome",.string("pending")),("extra",.bool(false))] {
            var bad = proof; bad[key] = value; XCTAssertThrowsError(try c.resolution(bad), key)
        }
    }
    func testClosedGroupCannotContainAppliedReceipts() throws {
        let c = try command(); let value = try c.resolution(reply(c, closed: true))
        XCTAssertTrue(value.closed); XCTAssertFalse(value.applied); XCTAssertTrue(value.receipts.isEmpty)
        var bad = try reply(c); bad["outcome"] = .string("closed"); XCTAssertThrowsError(try c.resolution(bad))
    }
    func testComponentProofCannotHideWrongIncarnationOrState() throws {
        let c = try command(); var proof = try reply(c), rows = proof["receipts"]!.list
        var first = rows[0].object; first["incarnation"] = .string(UUID().uuidString.lowercased()); rows[0] = .object(first); proof["receipts"] = .array(rows)
        XCTAssertThrowsError(try c.resolution(proof))
        proof = try reply(c); rows = proof["receipts"]!.list; first = rows[0].object
        var after = first["after"]!.object; after["completed"] = .bool(false); first["after"] = .object(after); rows[0] = .object(first); proof["receipts"] = .array(rows)
        XCTAssertThrowsError(try c.resolution(proof))
    }
    func testBoundsAndUniqueTargetsAreEnforcedBeforeSaving() throws {
        let c = try command(); XCTAssertThrowsError(try ChildTaskCompletionBatchCommand(account: c.account, origin: origin, items: []))
        XCTAssertEqual(try many(32).items.count, 32); XCTAssertThrowsError(try many(33))
        let first = c.items[0]
        XCTAssertThrowsError(try ChildTaskCompletionBatchCommand(account: c.account, origin: origin, items: [first, first]))
        XCTAssertThrowsError(try item(first.body["node_key"]!.text, root: first.body["task_id"]!.text.uppercased()))
        let duplicate = try item(first.body["node_key"]!.text, root: first.body["task_id"]!.text)
        XCTAssertThrowsError(try ChildTaskCompletionBatchCommand(account: c.account, origin: origin, items: [first, duplicate]))
        XCTAssertThrowsError(try ChildTaskCompletionBatchCommand(account: c.account, origin: origin, items: [first], batchID: XCTUnwrap(UUID(uuidString: first.id))))
    }
    func testRequestIdentitiesCannotBeReusedForAnotherSelectedTarget() throws {
        let c = try command(), first = c.items[0]
        let second = try item("different-child", requestID: XCTUnwrap(UUID(uuidString: first.id)))
        XCTAssertThrowsError(try ChildTaskCompletionBatchCommand(account: c.account, origin: origin, items: [first, second]))
    }
    func testMixedActionsAccountsAndOriginsRefuseTheWholeGroup() throws {
        let c = try command(), first = c.items[0]; var body = c.items[1].body
        body["action"] = .string("reopen"); var state = body["baseline"]!.object; state["completed"] = .bool(true); state["completed_at"] = .string("2026-10-31T00:00:00Z"); body["baseline"] = .object(state)
        let reopen = try ChildTaskCompletionCommand(account: c.account, origin: origin, body: body)
        let otherOrigin = try ChildTaskCompletionCommand(account: c.account, origin: "https://other-batch.test", body: c.items[1].body)
        var otherBody = c.items[1].body; let otherAccount = UUID().uuidString.lowercased(); otherBody["account"] = .string(otherAccount)
        let otherUser = try ChildTaskCompletionCommand(account: otherAccount, origin: origin, body: otherBody)
        for item in [reopen, otherOrigin, otherUser] { XCTAssertThrowsError(try ChildTaskCompletionBatchCommand(account: c.account, origin: origin, items: [first,item])) }
    }
    func testStoredCodecKeepsOriginalUndoProofAndWireOmitsPrivateProofs() throws {
        for undo in [false,true] {
            let c = try command(undo: undo), data = try TaskfoldJSONEncoder().encode(c)
            XCTAssertEqual(try TaskfoldJSONDecoder().decode(ChildTaskCompletionBatchCommand.self, from: data), c)
            XCTAssertTrue(c.body["items"]!.list.allSatisfy { $0.object["original"] == nil && $0.object["subtasks"] == nil && $0.object["title"] == nil })
            var raw = try TaskfoldJSONDecoder().decode([String: JSON].self, from: data); raw["extra"] = .bool(true)
            XCTAssertThrowsError(try TaskfoldJSONDecoder().decode(ChildTaskCompletionBatchCommand.self, from: TaskfoldJSONEncoder().encode(raw)))
        }
    }
    @MainActor func testSavedGroupSurvivesColdVaultAndCannotBeReplacedByAnotherGroup() async throws {
        let c = try command(), io = BatchIO(), lease = CalendarReadLease()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-batch-vault-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = ChildTaskCompletionBatchVault(io: io, coordinationDirectory: directory, removalDirectory: directory)
        try await vault.begin(c, lease: lease)
        let cold = ChildTaskCompletionBatchVault(io: io, coordinationDirectory: directory, removalDirectory: directory)
        let retained = try await cold.pending(account: c.account, origin: c.origin); XCTAssertEqual(retained, c)
        let different = try ChildTaskCompletionBatchCommand(account: c.account, origin: c.origin, items: c.items)
        do { try await cold.begin(different, lease: lease); XCTFail("Must preserve original group") } catch {}
        let unchanged = try await cold.pending(account: c.account, origin: c.origin); XCTAssertEqual(unchanged, c)
    }
    @MainActor private func backend(_ c: ChildTaskCompletionBatchCommand) throws -> Backend {
        let raw: [String:JSON] = ["access_token":.string("synthetic"),"refresh_token":.string("synthetic"),"expires_in":.number(3600),"user":.object(["id":.string(c.account)])]
        let session = try TaskfoldJSONDecoder().decode(Session.self, from: TaskfoldJSONEncoder().encode(raw))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BatchHTTP.self]
        return Backend(configuration: ["URL":origin,"Key":"synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
    }
    private func requestBody(_ request: URLRequest) -> Data {
        if let bytes = request.httpBody { return bytes }; var data=Data()
        if let stream=request.httpBodyStream {stream.open();defer{stream.close()};var buffer=[UInt8](repeating:0,count:4096);while stream.hasBytesAvailable {let n=stream.read(&buffer,maxLength:buffer.count);if n<=0{break};data.append(contentsOf:buffer.prefix(n))}}
        return data
    }
    @MainActor func testBackendExactWireBodyAndLargerBoundedGroupReceipt() async throws {
        let c = try many(32), backend = try backend(c), proof = try reply(c)
        let data = try TaskfoldJSONEncoder().encode(proof); XCTAssertGreaterThan(data.count, 16_384)
        defer { BatchHTTP.handler = nil }
        BatchHTTP.handler = { request, pipe in
            XCTAssertEqual(request.url?.path,"/rest/v1/rpc/taskfold_complete_child_tasks"); XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.cachePolicy,.reloadIgnoringLocalCacheData); XCTAssertEqual(request.value(forHTTPHeaderField:"Cache-Control"),"no-store")
            XCTAssertEqual(try! TaskfoldJSONDecoder().decode([String:JSON].self,from:self.requestBody(request)),["_body":.object(c.body)])
            pipe.finish(200,data)
        }
        let result = try await backend.childTaskCompletionBatch(c,session:backend.reminderSessionIncarnation)
        XCTAssertTrue(result.applied); XCTAssertEqual(result.receipts.count,32)
    }
    @MainActor func testBackendResolutionAcceptsClosedButApplyDoesNot() async throws {
        let c = try command(), backend = try backend(c), data = try TaskfoldJSONEncoder().encode(reply(c,closed:true))
        defer { BatchHTTP.handler = nil }; BatchHTTP.handler = { _,pipe in pipe.finish(200,data) }
        let closed = try await backend.childTaskCompletionBatch(c,session:backend.reminderSessionIncarnation,close:true); XCTAssertTrue(closed.closed)
        do {_ = try await backend.childTaskCompletionBatch(c,session:backend.reminderSessionIncarnation);XCTFail("Apply must not certify closure")}catch let failure as ChildTaskCompletionFailure{XCTAssertEqual(failure.reason,.unconfirmed)}
    }
    @MainActor func testBackendRefusesStaleSessionBeforeHTTP() async throws {
        let c = try command(), backend = try backend(c)
        defer{BatchHTTP.handler=nil};BatchHTTP.handler={_,_ in XCTFail("Stale sender must not access network")}
        do {_ = try await backend.childTaskCompletionBatch(c,session:UUID());XCTFail("Stale scope")}catch is CancellationError{}catch{XCTFail("Wrong error: \(error)")}
    }
    @MainActor func testBackendRejectsDuplicateAndOversizedResponses() async throws {
        let c = try command(), backend = try backend(c)
        defer{BatchHTTP.handler=nil}
        for data in [Data("{\"protocol\":1,\"protocol\":1}".utf8),Data(repeating:32,count:ChildTaskCompletionBatchCommand.maximumResponseBytes+1)] {
            BatchHTTP.handler={_,pipe in pipe.finish(200,data)}
            do {_ = try await backend.childTaskCompletionBatch(c,session:backend.reminderSessionIncarnation);XCTFail("Unsafe response")}catch let failure as ChildTaskCompletionFailure{XCTAssertEqual(failure.reason,.unconfirmed)}
        }
    }
    @MainActor func testBackendRetainsTerminalErrorMapping() async throws {
        let c = try command(), backend = try backend(c)
        defer{BatchHTTP.handler=nil};BatchHTTP.handler={_,pipe in pipe.finish(400,Data("{\"code\":\"PT410\",\"message\":\"closed\"}".utf8))}
        do {_ = try await backend.childTaskCompletionBatch(c,session:backend.reminderSessionIncarnation);XCTFail("Closed group")}catch let failure as ChildTaskCompletionFailure{XCTAssertEqual(failure.reason,.closed)}
    }
}

@MainActor private final class GroupPeer: ChildTaskCompletionBatchService {
    var calls: [(ChildTaskCompletionBatchCommand, Bool)] = []
    var proofs: [String: ChildTaskCompletionBatchResolution] = [:]
    var lose = false
    var onReply: (() -> Void)?
    let make: (ChildTaskCompletionBatchCommand, Bool) throws -> ChildTaskCompletionBatchResolution
    init(make: @escaping (ChildTaskCompletionBatchCommand, Bool) throws -> ChildTaskCompletionBatchResolution) { self.make = make }
    func childTaskCompletionBatch(_ command: ChildTaskCompletionBatchCommand, session: UUID, close: Bool) async throws -> ChildTaskCompletionBatchResolution {
        calls.append((command, close))
        let proof = try proofs[command.id] ?? make(command, close); proofs[command.id] = proof
        onReply?(); if lose { lose = false; throw URLError(.networkConnectionLost) }; return proof
    }
}
extension ChildTaskCompletionBatchTests {
    private func groupDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-group-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func groupJournal(_ c: ChildTaskCompletionBatchCommand, _ io: any CalendarSecureItemIO, _ directory: URL) throws -> ChildTaskCompletionBatchJournal {
        try .init(account: c.account, origin: c.origin, io: io, coordinationDirectory: directory.appendingPathComponent("locks"), removalDirectory: directory.appendingPathComponent("removal"))
    }
    private func scope(_ c: ChildTaskCompletionBatchCommand) -> ChildTaskFieldClientScope {
        .init(account: c.account, origin: c.origin, workspace: UUID(), session: UUID(), access: UUID())
    }
    @MainActor private func peer() -> GroupPeer { GroupPeer { c, close in try c.resolution(self.reply(c, closed: close)) } }
    func testGroupColdJournalKeepsAttemptAndWholeConfirmation() async throws {
        let c = try command(), io = BatchIO(), d = try groupDirectory(), j = try groupJournal(c, io, d), lease = CalendarReadLease()
        try await j.enqueue(c, lease: lease); _ = try await j.begin(c, lease: lease)
        let cold = try groupJournal(c, io, d), pending = try await cold.load(); XCTAssertEqual(pending.entries.first?.phase, .attempted)
        let proof = try c.resolution(reply(c)); try await cold.settle(c, decision: proof, lease: lease)
        let saved = try await j.load(); XCTAssertEqual(saved.entries.first?.proof, proof); XCTAssertEqual(saved.entries.first?.phase, .confirmed)
    }
    func testGroupCannotSettleBeforeAttemptOrForgetUncertainty() async throws {
        let c = try command(), io = BatchIO(), j = try groupJournal(c, io, groupDirectory()), lease = CalendarReadLease()
        try await j.enqueue(c, lease: lease)
        do { try await j.settle(c, decision: c.resolution(reply(c)), lease: lease); XCTFail("Not attempted") } catch {}
        _ = try await j.begin(c, lease: lease)
        do { try await j.discard(c, lease: lease); XCTFail("Must resolve uncertainty") } catch {}
        let saved = try await j.load(); XCTAssertEqual(saved.entries.first?.phase, .attempted)
    }
    func testGroupStopsEveryMemberAndClosureCannotBeReplacedByAppliedProof() async throws {
        let c = try command(), io = BatchIO(), j = try groupJournal(c, io, groupDirectory()), lease = CalendarReadLease()
        try await j.enqueue(c, lease: lease); _ = try await j.begin(c, resolving: true, lease: lease)
        let closed = try c.resolution(reply(c, closed: true)); try await j.settle(c, decision: closed, lease: lease)
        do { _ = try await j.begin(c, lease: lease); XCTFail("Closed") } catch {}
        do { try await j.enqueue(c, lease: lease); XCTFail("Cannot revive identity") } catch {}
        do { try await j.settle(c, decision: c.resolution(reply(c)), lease: lease); XCTFail("Contradictory decision") } catch {}
        let saved = try await j.load(); XCTAssertEqual(saved.entries.first?.proof, closed)
    }
    func testGroupCorruptionAndDuplicateKeysCannotBeOverwritten() async throws {
        for bytes in [Data("corrupt".utf8), Data("{\"version\":1,\"version\":1}".utf8)] {
            let c = try command(), io = BatchIO(), j = try groupJournal(c, io, groupDirectory())
            try await j.enqueue(c, lease: CalendarReadLease()); let key = try XCTUnwrap(io.rows.keys.first); io.rows[key] = bytes
            do { try await j.enqueue(c, lease: CalendarReadLease()); XCTFail("Cannot replace unreadable saved work") } catch {}
            XCTAssertEqual(io.rows[key], bytes)
        }
    }
    func testGroupScopeAndRemovalFencePreventNewStorageWrites() async throws {
        let c = try command(), io = BatchIO(), d = try groupDirectory(), j = try groupJournal(c, io, d), lease = CalendarReadLease(); lease.cancel()
        do { try await j.enqueue(c, lease: lease); XCTFail("Cancelled") } catch {}
        XCTAssertTrue(io.rows.isEmpty)
        try AccountRemovalDisk(directory: d.appendingPathComponent("removal"), account: c.account).removeCache()
        do { try await j.enqueue(c, lease: CalendarReadLease()); XCTFail("Removed account") } catch {}
        XCTAssertTrue(io.rows.isEmpty)
    }
    func testGroupEncryptedColdStorageWrongKeyAndRemoval() async throws {
        let c = try command(), d = try groupDirectory(), key = SymmetricKey(size: .bits256), wrong = SymmetricKey(size: .bits256)
        let io = ReviewedTeamCommandFileIO<ChildTaskCompletionBatchState>(directory: d.appendingPathComponent("protected"), account: c.account, origin: c.origin, encryptionKey: { key })
        let j = try groupJournal(c, io, d); try await j.enqueue(c, lease: CalendarReadLease())
        let bytes = try Data(contentsOf: io.file); XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(c.id))
        let bad = ReviewedTeamCommandFileIO<ChildTaskCompletionBatchState>(directory: d.appendingPathComponent("protected"), account: c.account, origin: c.origin, encryptionKey: { wrong })
        do { _ = try await groupJournal(c, bad, d).load(); XCTFail("Wrong key") } catch {}
        XCTAssertEqual(try Data(contentsOf: io.file), bytes)
        let cold = try await groupJournal(c, io, d).load(); XCTAssertEqual(cold.entries.first?.command, c)
        try await j.removeAccount(); XCTAssertFalse(FileManager.default.fileExists(atPath: io.file.path))
    }
    func testGroupUndoRequiresOneCompleteConfirmedParentAndKeepsIt() async throws {
        let c = try command(), u = try command(undo: true), io = BatchIO(), j = try groupJournal(c, io, groupDirectory()), lease = CalendarReadLease()
        do { try await j.enqueue(u, lease: lease); XCTFail("No parent") } catch {}
        try await j.enqueue(c, lease: lease); _ = try await j.begin(c, lease: lease)
        try await j.settle(c, decision: c.resolution(fixture()["receipt"]!.object), lease: lease)
        try await j.enqueue(u, lease: lease)
        do { try await j.discard(c, lease: lease); XCTFail("Undo still depends on original") } catch {}
        _ = try await j.begin(u, lease: lease); try await j.settle(u, decision: u.resolution(fixture()["undoReceipt"]!.object), lease: lease)
        let saved = try await j.load(); XCTAssertEqual(saved.entries.count, 2); XCTAssertEqual(saved.parent(of: u)?.command, c)
        let second = try ChildTaskCompletionBatchCommand(account: c.account, origin: c.origin, items: u.items)
        do { try await j.enqueue(second, lease: lease); XCTFail("Members cannot belong to two groups") } catch {}
    }
    func testGroupPendingOverlapOrdersWholeSelectionsButResolutionCanStopLaterOne() async throws {
        let c = try command(), fresh = try ChildTaskCompletionBatchCommand(account: c.account, origin: c.origin, items: [item(c.items[0].body["node_key"]!.text)]), io = BatchIO(), j = try groupJournal(c, io, groupDirectory()), lease = CalendarReadLease()
        try await j.enqueue(c, lease: lease); try await j.enqueue(fresh, lease: lease)
        do { _ = try await j.begin(fresh, lease: lease); XCTFail("Earlier selection overlaps") } catch {}
        _ = try await j.begin(fresh, resolving: true, lease: lease); try await j.settle(fresh, decision: fresh.resolution(reply(fresh, closed: true)), lease: lease)
        let saved = try await j.load(); XCTAssertEqual(saved.entries.map(\.phase), [.queued, .closed])
    }
    func testGroupFreshReplacementNeedsClosureAndFreshMemberIDs() async throws {
        let c = try command(), fresh = try ChildTaskCompletionBatchCommand(account: c.account, origin: c.origin, items: c.items.map { old in var b = old.body; b["request_id"] = .string(UUID().uuidString.lowercased()); return try .init(account: old.account, origin: old.origin, body: b) }), io = BatchIO(), j = try groupJournal(c, io, groupDirectory()), lease = CalendarReadLease()
        try await j.enqueue(c, lease: lease)
        do { try await j.replaceClosed(c, with: fresh, lease: lease); XCTFail("Not closed") } catch {}
        _ = try await j.begin(c, resolving: true, lease: lease); try await j.settle(c, decision: c.resolution(reply(c, closed: true)), lease: lease)
        try await j.replaceClosed(c, with: fresh, lease: lease)
        let saved = try await j.load(); XCTAssertEqual(saved.entries.map(\.phase), [.closed, .queued])
    }
    @MainActor func testGroupLostReplyRetriesExactSavedGroupAfterColdReturn() async throws {
        let c = try command(), io = BatchIO(), d = try groupDirectory(), j = try groupJournal(c, io, d), s = scope(c), p = peer()
        try await j.enqueue(c, lease: CalendarReadLease()); p.lose = true
        let sender = ChildTaskCompletionBatchSender(scope: s, journal: j, service: p, current: { s }, canSend: { _ in true })
        do { _ = try await sender.send(c); XCTFail("Lost reply") } catch {}
        let uncertain = try await j.load(); XCTAssertEqual(uncertain.entries.first?.phase, .attempted); sender.close()
        let cold = ChildTaskCompletionBatchSender(scope: s, journal: try groupJournal(c, io, d), service: p, current: { s }, canSend: { _ in true })
        let result = try await cold.send(c); XCTAssertTrue(result.applied); XCTAssertEqual(p.calls.map { $0.0 }, [c,c]); XCTAssertEqual(p.proofs.count, 1)
        _ = try await cold.send(c); XCTAssertEqual(p.calls.count, 2)
    }
    @MainActor func testGroupAttemptWriteFailurePreventsNetworkAndConfirmationFailureKeepsUncertainty() async throws {
        let c = try command(), io = BatchIO(), j = try groupJournal(c, io, groupDirectory()), s = scope(c), p = peer()
        try await j.enqueue(c, lease: CalendarReadLease()); io.failWrite = true
        let sender = ChildTaskCompletionBatchSender(scope: s, journal: j, service: p, current: { s }, canSend: { _ in true })
        do { _ = try await sender.send(c); XCTFail("Storage refused attempt") } catch {}
        XCTAssertTrue(p.calls.isEmpty); io.failWrite = false; p.onReply = { io.failWrite = true }
        do { _ = try await sender.send(c); XCTFail("Storage refused proof") } catch {}
        let uncertain = try await j.load(); XCTAssertEqual(uncertain.entries.first?.phase, .attempted)
        io.failWrite = false; p.onReply = nil; _ = try await sender.send(c); XCTAssertEqual(p.calls.count, 2)
    }
    @MainActor func testGroupLateScopeChangeKeepsUncertaintyAndSuppressesLateProof() async throws {
        let c = try command(), io = BatchIO(), j = try groupJournal(c, io, groupDirectory()), s = scope(c), p = peer(); var current: ChildTaskFieldClientScope? = s
        try await j.enqueue(c, lease: CalendarReadLease()); p.onReply = { current = nil }
        let sender = ChildTaskCompletionBatchSender(scope: s, journal: j, service: p, current: { current }, canSend: { _ in true })
        do { _ = try await sender.send(c); XCTFail("Scope changed") } catch is CancellationError {} catch { XCTFail("Wrong failure") }
        let saved = try await j.load(); XCTAssertEqual(saved.entries.first?.phase, .attempted)
    }
    @MainActor func testGroupResolutionWorksWithSendingOffAndClosedSenderNeverStartsNetwork() async throws {
        let c = try command(), io = BatchIO(), j = try groupJournal(c, io, groupDirectory()), s = scope(c), p = peer()
        try await j.enqueue(c, lease: CalendarReadLease())
        let sender = ChildTaskCompletionBatchSender(scope: s, journal: j, service: p, current: { s }, canSend: { _ in false })
        let result = try await sender.send(c, resolving: true); XCTAssertTrue(result.closed); XCTAssertTrue(p.calls[0].1)
        _ = try await sender.send(c, resolving: true); XCTAssertEqual(p.calls.count, 1); sender.close()
        do { _ = try await sender.send(c, resolving: true); XCTFail("Closed presentation") } catch {}
        XCTAssertEqual(p.calls.count, 1)
    }
}

extension ChildTaskCompletionBatchTests {
    private func afterRead(_ item: ChildTaskCompletionCommand, _ receipt: ChildTaskCompletionReceipt, _ scope: ChildTaskFieldClientScope) throws -> ChildTaskRecordRead {
        let b = item.body, key = b["node_key"]!.text, revision = receipt.raw["revision"]!
        let fields = receipt.raw["after"]!.object.merging(["id": .string(key), "title": .string("Synthetic group task")]) { _, value in value }
        let root = Record(["id": b["task_id"]!, "task_generation": b["task_generation"]!, "project_id": b["project_id"]!, "subtasks": .array([.object(fields)])])
        let context = try ChildTaskRecordContext(account: scope.account, origin: scope.origin, workspace: scope.workspace, session: scope.session, access: scope.access, snapshot: UUID(), root: root)
        let raw: [String: JSON] = ["protocol": .number(1), "account": .string(item.account), "task_id": b["task_id"]!, "task_generation": b["task_generation"]!, "project_id": b["project_id"]!, "projection_revision": revision, "root_kind": .string("array"), "records": .array([.object(["node_key": .string(key), "incarnation": b["incarnation"]!, "revision": revision, "parent_key": .null, "sibling_order": .number(0), "identity_path": .array([.string(key)]), "fields": .object(fields), "children_kind": .string("absent")])])]
        return try .init(data: TaskfoldJSONEncoder().encode(raw), context: context)
    }
    func testGroupUndoFactoryRequiresAllFreshReadsFromOneLiveScope() throws {
        let c = try command(), proof = try c.resolution(fixture()["receipt"]!.object), s = scope(c)
        var reads = try Dictionary(uniqueKeysWithValues: zip(c.items, proof.receipts).map { ($0.0.body["task_id"]!.text, try afterRead($0.0, $0.1, s)) })
        let undo = try c.undo(reads: reads, decision: proof)
        XCTAssertTrue(undo.isUndo); XCTAssertEqual(undo.items.map { $0.body["undo_of"]!.text }, c.items.map(\.id))
        XCTAssertThrowsError(try c.undo(reads: [:], decision: proof))
        reads[c.items[0].body["task_id"]!.text] = try afterRead(c.items[0], proof.receipts[0], scope(c))
        XCTAssertThrowsError(try c.undo(reads: reads, decision: proof))
    }
    func testGroupUndoCannotUsePartialOrMixedParentGroups() throws {
        let c = try command(), u = try command(undo: true), proof = try fixture()["receipt"]!.object
        let partial = try ChildTaskCompletionBatchCommand(account: c.account, origin: c.origin, items: [u.items[0]])
        XCTAssertThrowsError(try ChildTaskCompletionBatchState(account: c.account, origin: c.origin, entries: [.init(command: c, phase: .confirmed, decision: proof), .init(command: partial, phase: .queued)]))
        let valid = try ChildTaskCompletionBatchState(account: c.account, origin: c.origin, entries: [.init(command: c, phase: .confirmed, decision: proof), .init(command: u, phase: .queued)])
        XCTAssertEqual(valid.parent(of: u)?.command, c, "The real database fixture reverses Undo member order")
    }
    func testGroupFullPendingHistoryCannotBePrunedToAdmitMoreWork() async throws {
        let c = try command(), io = BatchIO(), j = try groupJournal(c, io, groupDirectory()), lease = CalendarReadLease()
        try await j.enqueue(c, lease: lease); let key = try XCTUnwrap(io.rows.keys.first)
        let history = try (0..<32).map { index -> ChildTaskCompletionBatchState.Entry in
            let command = try ChildTaskCompletionBatchCommand(account: c.account, origin: c.origin, items: [item("pending-\(index)")]); return .init(command: command, phase: .attempted)
        }
        io.rows[key] = try TaskfoldJSONEncoder().encode(ChildTaskCompletionBatchState(account: c.account, origin: c.origin, entries: history)); let before = io.rows
        do { try await j.enqueue(c, lease: lease); XCTFail("All uncertainty must survive") } catch is ChildTaskCompletionCapacityFailure {} catch { XCTFail("Wrong failure") }
        XCTAssertEqual(io.rows, before)
    }
    func testGroupRetentionPrunesSettledUndoTogetherAndKeepsPendingUndoFamily() throws {
        let c = try command(), u = try command(undo: true), f = try fixture()
        let history = try (0..<30).map { index -> ChildTaskCompletionBatchState.Entry in
            let c = try ChildTaskCompletionBatchCommand(account: c.account, origin: c.origin, items: [item("settled-\(index)")]); return .init(command: c, phase: .confirmed, decision: try reply(c))
        }
        for phase in [ChildTaskCompletionBatchState.Phase.confirmed, .attempted] {
            var state = try ChildTaskCompletionBatchState(account: c.account, origin: c.origin, entries: [.init(command: c, phase: .confirmed, decision: f["receipt"]!.object), .init(command: u, phase: phase, decision: phase == .confirmed ? f["undoReceipt"]!.object : nil)] + history)
            let incoming = try ChildTaskCompletionBatchCommand(account: c.account, origin: c.origin, items: [item("incoming")]); state.entries.append(.init(command: incoming, phase: .queued))
            try state.makeRoom(preserving: incoming.id)
            XCTAssertEqual(state.entries.contains { $0.command == c }, phase != .confirmed)
            XCTAssertEqual(state.entries.contains { $0.command == u }, phase != .confirmed)
            _ = try ChildTaskCompletionBatchState(account: c.account, origin: c.origin, entries: state.entries)
        }
    }
    func testGroupConcurrentJournalsKeepBothSelections() async throws {
        let c = try command(), other = try ChildTaskCompletionBatchCommand(account: c.account, origin: c.origin, items: [item("other")]), io = BatchIO(), d = try groupDirectory(), j = try groupJournal(c, io, d), k = try groupJournal(c, io, d)
        async let one: Void = j.enqueue(c, lease: CalendarReadLease())
        async let two: Void = k.enqueue(other, lease: CalendarReadLease())
        _ = try await (one, two)
        let state = try await j.load(); XCTAssertEqual(Set(state.entries.map(\.command.id)), [c.id, other.id])
    }
}

extension ChildTaskCompletionBatchTests {
    @MainActor func testGroupModelOfflineStageColdLoadAndExplicitSend() async throws {
        let c = try command(), io = BatchIO(), d = try groupDirectory(), j = try groupJournal(c, io, d), s = scope(c), p = peer()
        var online = false, refreshes = 0
        func model() -> ChildTaskCompletionBatchRecoveryModel {
            .init(scope: s, journal: j, service: p, current: { s }, canQueue: { _ in true }, canSend: { _ in online }, refresh: { refreshes += 1 })
        }
        let first = model(); let immediate = await first.perform(c); XCTAssertFalse(immediate); XCTAssertTrue(p.calls.isEmpty); first.close()
        let cold = model(); await cold.load(); XCTAssertEqual(cold.entries.first?.command, c); XCTAssertTrue(p.calls.isEmpty)
        online = true; await cold.send(c); XCTAssertEqual(cold.entries.first?.phase, .confirmed); XCTAssertEqual(refreshes, 1)
    }
    @MainActor func testGroupModelLostReplyNeverShowsConfirmationAndRetryRefreshesOnce() async throws {
        let c = try command(), io = BatchIO(), j = try groupJournal(c, io, groupDirectory()), s = scope(c), p = peer(); p.lose = true; var refreshes = 0
        let model = ChildTaskCompletionBatchRecoveryModel(scope: s, journal: j, service: p, current: { s }, canQueue: { _ in true }, canSend: { _ in true }, refresh: { refreshes += 1 })
        let result = await model.perform(c); XCTAssertFalse(result); XCTAssertEqual(model.entries.first?.phase, .attempted); XCTAssertEqual(refreshes, 0)
        XCTAssertEqual(model.message, ChildTaskCompletionFailure(reason: .unconfirmed).localizedDescription)
        await model.send(c); XCTAssertEqual(model.entries.first?.phase, .confirmed); XCTAssertEqual(refreshes, 1); XCTAssertEqual(p.calls.map { $0.0 }, [c,c])
    }
    @MainActor func testGroupModelWholeUndoUsesCurrentReadsAndCannotRepeatUndo() async throws {
        let c = try command(), io = BatchIO(), j = try groupJournal(c, io, groupDirectory()), s = scope(c), p = peer()
        let model = ChildTaskCompletionBatchRecoveryModel(scope: s, journal: j, service: p, current: { s }, canQueue: { _ in true }, canSend: { _ in true }, refresh: {})
        let result = await model.perform(c); XCTAssertTrue(result)
        let entry = try XCTUnwrap(model.entries.first), proof = try XCTUnwrap(entry.proof)
        let reads = try Dictionary(uniqueKeysWithValues: zip(c.items, proof.receipts).map { ($0.0.body["task_id"]!.text, try afterRead($0.0, $0.1, s)) })
        let produced = await model.undo(entry, reads: reads); let undo = try XCTUnwrap(produced); XCTAssertTrue(undo.isUndo); XCTAssertEqual(model.entries.count, 2)
        XCTAssertEqual(model.entries.last?.phase, .confirmed); XCTAssertEqual(p.calls.count, 2)
        let repeated = await model.undo(entry, reads: reads); XCTAssertNil(repeated); XCTAssertEqual(p.calls.count, 2)
    }
    @MainActor func testGroupModelCloseDuringReplySuppressesUIAndRefreshButKeepsSavedIntent() async throws {
        let c = try command(), io = BatchIO(), j = try groupJournal(c, io, groupDirectory()), s = scope(c), p = peer(); var refreshes = 0
        let model = ChildTaskCompletionBatchRecoveryModel(scope: s, journal: j, service: p, current: { s }, canQueue: { _ in true }, canSend: { _ in true }, refresh: { refreshes += 1 })
        p.onReply = { model.close() }
        let result = await model.perform(c); XCTAssertFalse(result); XCTAssertTrue(model.entries.isEmpty); XCTAssertNil(model.message); XCTAssertFalse(model.loaded); XCTAssertEqual(refreshes, 0)
        let saved = try await j.load(); XCTAssertEqual(saved.entries.first?.phase, .attempted)
    }
    @MainActor func testGroupSendingPermissionRecheckedAfterAttemptAndResolutionRecoversAppliedResult() async throws {
        let c = try command(), io = BatchIO(), j = try groupJournal(c, io, groupDirectory()), s = scope(c), p = peer(); var admissions = 0
        try await j.enqueue(c, lease: CalendarReadLease())
        let sender = ChildTaskCompletionBatchSender(scope: s, journal: j, service: p, current: { s }, canSend: { _ in admissions += 1; return admissions == 1 })
        do { _ = try await sender.send(c); XCTFail("Access changed after durable attempt") } catch {}
        XCTAssertTrue(p.calls.isEmpty)
        p.proofs[c.id] = try c.resolution(reply(c))
        let result = try await sender.send(c, resolving: true); XCTAssertTrue(result.applied)
        let saved = try await j.load(); XCTAssertEqual(saved.entries.first?.phase, .confirmed)
    }
}

extension ChildTaskCompletionBatchTests {
    func testGroupMemberReuseIsRefusedBeforeSettledHistoryCanBePruned() async throws {
        let c = try command(), io = BatchIO(), j = try groupJournal(c, io, groupDirectory()), lease = CalendarReadLease()
        try await j.enqueue(c, lease: lease); let key = try XCTUnwrap(io.rows.keys.first)
        let history = try (0..<32).map { index -> ChildTaskCompletionBatchState.Entry in
            let command = try ChildTaskCompletionBatchCommand(account: c.account, origin: c.origin, items: [item("settled-reuse-\(index)")])
            return .init(command: command, phase: .confirmed, decision: try reply(command))
        }
        io.rows[key] = try TaskfoldJSONEncoder().encode(ChildTaskCompletionBatchState(account: c.account, origin: c.origin, entries: history))
        let before = io.rows, reused = try ChildTaskCompletionBatchCommand(account: c.account, origin: c.origin, items: history[0].command.items)
        do { try await j.enqueue(reused, lease: lease); XCTFail("Reuse must be refused before retention can prune its earlier owner") } catch {}
        XCTAssertEqual(io.rows, before)
    }
}

extension ChildTaskCompletionBatchTests {
    private func actionIO<T: ReviewedTeamFileCommand>(_ type: T.Type, _ command: ChildTaskCompletionBatchCommand, _ dir: URL, _ folder: String) -> ReviewedTeamCommandFileIO<T> {
        .init(directory: dir.appendingPathComponent("vault").appendingPathComponent(folder).appendingPathComponent(command.account).appendingPathComponent(CalendarOAuthConfiguration.digest(command.origin)), account: command.account, origin: command.origin, encryptionKey: { SymmetricKey(data: Data(repeating: 77, count: 32)) })
    }
    private func actionAdmission(_ c: ChildTaskCompletionBatchCommand, _ d: URL) -> ChildTaskActionAdmission {
        .init(account: c.account, origin: c.origin, directory: d.appendingPathComponent("vault"), encryptionKey: { SymmetricKey(data: Data(repeating: 77, count: 32)) })
    }
    private func admittedGroup(_ c: ChildTaskCompletionBatchCommand, _ d: URL) throws -> ChildTaskCompletionBatchJournal {
        let admission = actionAdmission(c,d)
        return try .init(account: c.account, origin: c.origin, io: actionIO(ChildTaskCompletionBatchState.self,c,d,"Child completion groups"), coordinationDirectory: d.appendingPathComponent("shared"), removalDirectory: d.appendingPathComponent("removal"), admit: { try admission.checkBatch($0) })
    }
    private func admittedSingle(_ c: ChildTaskCompletionBatchCommand, _ d: URL) throws -> ChildTaskCompletionJournal {
        let admission = actionAdmission(c,d)
        return try .init(account: c.account, origin: c.origin, io: actionIO(ChildTaskCompletionJournalState.self,c,d,"Child completion requests"), coordinationDirectory: d.appendingPathComponent("shared"), removalDirectory: d.appendingPathComponent("removal"), admit: { try admission.checkOther($0) })
    }
    func testPendingSingleAndBulkHaveAtomicCrossJournalAdmission() async throws {
        let c = try command(), d = try groupDirectory(), group = try admittedGroup(c,d), single = try admittedSingle(c,d), lease = CalendarReadLease()
        func enqueueGroup() async -> Bool { do { try await group.enqueue(c, lease: lease); return true } catch { return false } }
        func enqueueSingle() async -> Bool { do { try await single.enqueue(c.items[0], lease: lease); return true } catch { return false } }
        async let a = enqueueGroup(); async let b = enqueueSingle(); let outcomes = await [a,b]
        XCTAssertEqual(outcomes.filter { $0 }.count, 1)
        let groups = try await group.load(), singles = try await single.load(); XCTAssertEqual(groups.entries.count + singles.entries.count, 1)
    }
    func testGroupTerminalResolutionRemainsAvailableWhileAnOlderSingleExists() async throws {
        let c = try command(), d = try groupDirectory(), group = try admittedGroup(c,d), single = try admittedSingle(c,d), lease = CalendarReadLease()
        try await single.enqueue(c.items[0], lease: lease)
        do { try await group.enqueue(c, lease: lease); XCTFail("Pending single must block") } catch {}
        let bare = try ChildTaskCompletionBatchJournal(account: c.account, origin: c.origin, io: actionIO(ChildTaskCompletionBatchState.self,c,d,"Child completion groups"), coordinationDirectory: d.appendingPathComponent("shared"), removalDirectory: d.appendingPathComponent("removal"))
        try await bare.enqueue(c, lease: lease)
        do { _ = try await group.begin(c, lease: lease); XCTFail("Conflicting send must block") } catch {}
        _ = try await group.begin(c, resolving: true, lease: lease); try await group.settle(c, decision: c.resolution(reply(c,closed:true)), lease: lease)
        _ = try await single.beginResolution(c.items[0], lease: lease)
        let state = try await group.load(); XCTAssertEqual(state.entries.first?.phase,.closed)
    }
    func testPendingBulkBlocksSingleAndUnblocksAfterDurableClosure() async throws {
        let c = try command(), d = try groupDirectory(), group = try admittedGroup(c,d), single = try admittedSingle(c,d), lease = CalendarReadLease()
        try await group.enqueue(c, lease: lease)
        do { try await single.enqueue(c.items[0], lease: lease); XCTFail("Pending selection must block") } catch {}
        _ = try await group.begin(c,resolving:true,lease:lease); try await group.settle(c,decision:c.resolution(reply(c,closed:true)),lease:lease)
        try await single.enqueue(c.items[0],lease:lease); let state = try await single.load(); XCTAssertEqual(state.entries.count,1)
    }
    func testAdmissionRefusesCorruptPendingStorageWithoutReplacingIt() async throws {
        let c = try command(), d = try groupDirectory(), single = try admittedSingle(c,d), lease = CalendarReadLease()
        try await single.enqueue(c.items[0],lease:lease)
        let io = actionIO(ChildTaskCompletionJournalState.self,c,d,"Child completion requests"), broken = Data("corrupt".utf8)
        try broken.write(to:io.file)
        do { try await admittedGroup(c,d).enqueue(c,lease:lease); XCTFail("Corruption cannot look empty") } catch {}
        XCTAssertEqual(try Data(contentsOf:io.file),broken)
    }
    func testAdmissionAllowsASeparateRootAndSettledHistory() async throws {
        let c = try command(), d = try groupDirectory(), group = try admittedGroup(c,d), single = try admittedSingle(c,d), lease = CalendarReadLease()
        try await group.enqueue(c,lease:lease)
        let other = try item("elsewhere",root:UUID().uuidString.lowercased());try await single.enqueue(other,lease:lease)
        let state = try await single.load();XCTAssertEqual(state.entries.first?.command,other)
    }
}
extension ChildTaskCompletionBatchTests {
    @MainActor func testAdmissionFailureExplainsEarlierWorkAndNeverStartsBulkNetwork() async throws {
        let c = try command(), d = try groupDirectory(), group = try admittedGroup(c,d), single = try admittedSingle(c,d), s = scope(c), p = peer()
        try await single.enqueue(c.items[0],lease:CalendarReadLease())
        let model = ChildTaskCompletionBatchRecoveryModel(scope:s,journal:group,service:p,current:{s},canQueue:{_ in true},canSend:{_ in true},refresh:{})
        let result = await model.perform(c);XCTAssertFalse(result);XCTAssertTrue(p.calls.isEmpty);XCTAssertTrue(model.entries.isEmpty);XCTAssertEqual(model.message,ChildTaskActionAdmissionFailure().localizedDescription)
        let saved = try await single.load();XCTAssertEqual(saved.entries.first?.phase,.queued)
    }
}

extension ChildTaskCompletionBatchTests {
    private func contract(_ name: String) throws -> [String:JSON] {
        let url = try XCTUnwrap(Bundle.module.url(forResource:name,withExtension:"json",subdirectory:"Fixtures"))
        return try TaskfoldJSONDecoder().decode([String:JSON].self,from:Data(contentsOf:url))
    }
    private func registryRefuses<T: ReviewedTeamFileCommand>(_ state: T, folder: String, roots: Set<String>) throws {
        let original = try command(), d = try groupDirectory()
        var body = original.items[0].body;body["account"] = .string(state.account);body["task_id"] = .string(roots.sorted()[0])
        let item = try ChildTaskCompletionCommand(account:state.account,origin:state.origin,body:body), c = try ChildTaskCompletionBatchCommand(account:state.account,origin:state.origin,items:[item])
        let io = actionIO(T.self,c,d,folder), key = T.storagePrefix + c.account + "." + CalendarOAuthConfiguration.digest(c.origin)
        try io.write(TaskfoldJSONEncoder().encode(state),key:key)
        XCTAssertThrowsError(try actionAdmission(c,d).checkBatch(roots)) { XCTAssertTrue($0 is ChildTaskActionAdmissionFailure) }
        XCTAssertNoThrow(try actionAdmission(c,d).checkBatch([UUID().uuidString.lowercased()]))
    }
    func testRegistryReadsEveryOtherPendingChildJournalAndPrivateHierarchyDraft() throws {
        let f = try contract("child-task-structure-proofs"), b = f["fixtureCommand"]!.object, account = b["account"]!.text
        let structure = try ChildTaskStructureCommand(account:account,origin:origin,body:b)
        try registryRefuses(ChildTaskStructureJournalState(account:account,origin:origin,entries:[.init(command:structure)]),folder:"Child hierarchy requests",roots:[b["task_id"]!.text])
        let draftBody: [String:JSON] = ["account":.string(account),"request_id":.string(UUID().uuidString.lowercased()),"task_id":b["task_id"]!,"task_generation":b["task_generation"]!,"project_id":b["project_id"]!,"action":.string("insert"),"node_key":.null,"incarnation":.null,"structure_revision":.number(1),"parent_key":.null,"parent_incarnation":.null,"index":.number(0),"title":.string("Private draft")]
        let draft = try ChildTaskStructureDraft(account:account,origin:origin,body:draftBody)
        try registryRefuses(ChildTaskStructureDraftState(account:account,origin:origin,entries:[draft]),folder:"Child hierarchy drafts",roots:[b["task_id"]!.text])
        let tf = try contract("cross-root-transfer-client-v1"), tb = tf["command"]!.object, ta = tb["account"]!.text
        let transfer = try ChildTaskTransferCommand(account:ta,origin:origin,body:tb)
        try registryRefuses(ChildTaskTransferState(account:ta,origin:origin,entries:[.init(command:transfer)]),folder:"Child transfer requests",roots:transfer.roots)
        let af = try contract("child-adoption-contract-v1"), ab = af["command"]!.object, aa = ab["account"]!.text
        let adoption = try ChildTaskAdoptionCommand(account:aa,origin:origin,body:ab,nodeCount:af["review"]!.object["node_count"]!.integer)
        try registryRefuses(ChildTaskAdoptionState(account:aa,origin:origin,entries:[.init(command:adoption)]),folder:"Child adoption requests",roots:[ab["task_id"]!.text])
        let rf = try contract("child-repair-contract-v1"), rb = rf["command"]!.object, ra = rb["account"]!.text
        let repair = try ChildTaskRepairCommand(account:ra,origin:origin,body:rb,nodeCount:rf["nodeCount"]!.integer)
        try registryRefuses(ChildTaskRepairState(account:ra,origin:origin,entries:[.init(command:repair)]),folder:"Child repair requests",roots:[rb["task_id"]!.text])
        let ff = try contract("child-task-field-command"), fb = ff["body"]!.object, fa = fb["account"]!.text
        let field = try ChildTaskFieldCommand(account:fa,origin:origin,body:fb)
        try registryRefuses(ChildTaskFieldJournalState(account:fa,origin:origin,entries:[.init(command:field,phase:.queued,receipt:nil)]),folder:"Child field requests",roots:[fb["task_id"]!.text])
    }
    func testRepairAdoptionAndTransferMetadataAttemptsBypassWriteAdmission() async throws {
        let d = try groupDirectory(), io = BatchIO(), lease = CalendarReadLease()
        let tf = try contract("cross-root-transfer-client-v1"), tb = tf["command"]!.object, transfer = try ChildTaskTransferCommand(account:tb["account"]!.text,origin:origin,body:tb)
        let tj = try ChildTaskTransferJournal(account:transfer.account,origin:origin,io:io,coordinationDirectory:d.appendingPathComponent("moves"),removalDirectory:d,admit:{_ in throw ChildTaskActionAdmissionFailure()})
        let seedT = try ChildTaskTransferJournal(account:transfer.account,origin:origin,io:io,coordinationDirectory:d.appendingPathComponent("moves"),removalDirectory:d)
        try await seedT.enqueue(transfer,lease:lease)
        do { _ = try await tj.attempt(transfer,lease:lease);XCTFail("Write must be admitted") } catch is ChildTaskActionAdmissionFailure {} catch { XCTFail("Wrong error") }
        _ = try await tj.attempt(transfer,lease:lease,resolving:true)
        let af = try contract("child-adoption-contract-v1"), ab = af["command"]!.object, adoption = try ChildTaskAdoptionCommand(account:ab["account"]!.text,origin:origin,body:ab,nodeCount:af["review"]!.object["node_count"]!.integer)
        let aj = try ChildTaskAdoptionJournal(account:adoption.account,origin:origin,io:io,coordinationDirectory:d.appendingPathComponent("adoption"),removalDirectory:d,admit:{_ in throw ChildTaskActionAdmissionFailure()})
        let seedA = try ChildTaskAdoptionJournal(account:adoption.account,origin:origin,io:io,coordinationDirectory:d.appendingPathComponent("adoption"),removalDirectory:d)
        try await seedA.enqueue(adoption,lease:lease);_ = try await aj.attempt(adoption,lease:lease,resolving:true)
        let rf = try contract("child-repair-contract-v1"), rb = rf["command"]!.object, repair = try ChildTaskRepairCommand(account:rb["account"]!.text,origin:origin,body:rb,nodeCount:rf["nodeCount"]!.integer)
        let rj = try ChildTaskRepairJournal(account:repair.account,origin:origin,io:io,coordinationDirectory:d.appendingPathComponent("repair"),removalDirectory:d,admit:{_ in throw ChildTaskActionAdmissionFailure()})
        let seedR = try ChildTaskRepairJournal(account:repair.account,origin:origin,io:io,coordinationDirectory:d.appendingPathComponent("repair"),removalDirectory:d)
        try await seedR.enqueue(repair,lease:lease);_ = try await rj.attempt(repair,lease:lease,resolving:true)
    }
}
