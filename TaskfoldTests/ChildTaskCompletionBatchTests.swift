import XCTest
@testable import TaskfoldCore

private final class BatchIO: CalendarSecureItemIO, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: Data] = [:]
    func read(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return rows[key] }
    func write(_ data: Data, key: String) throws { lock.lock(); defer { lock.unlock() }; rows[key] = data }
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
