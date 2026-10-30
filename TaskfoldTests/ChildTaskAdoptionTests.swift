import XCTest
import CryptoKit
@testable import TaskfoldCore

private final class AdoptionMemoryIO: CalendarSecureItemIO, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    var failWrite = false, failAfterWrite = false
    func read(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func write(_ bytes: Data, key: String) throws { lock.lock(); defer { lock.unlock() }; if failWrite { throw URLError(.cannotWriteToFile) }; data = bytes; if failAfterWrite { throw URLError(.cannotWriteToFile) } }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; data = nil }
}
@MainActor private final class AdoptionService: ChildTaskAdoptionService {
    var raw: [String: JSON], calls: [ChildTaskAdoptionOperation] = []
    var loseReply = false
    var beforeReply: (() -> Void)?
    init(_ raw: [String: JSON]) { self.raw = raw }
    func childTaskAdoption(_ command: ChildTaskAdoptionCommand, operation: ChildTaskAdoptionOperation, session: UUID) async throws -> ChildTaskAdoptionResult {
        calls.append(operation); beforeReply?()
        if loseReply { throw URLError(.networkConnectionLost) }
        return try command.result(raw)
    }
}
private final class AdoptionHTTP: URLProtocol {
    static var handler: ((URLRequest, AdoptionHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func finish(_ status: Int, _ data: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
final class ChildTaskAdoptionTests: XCTestCase {
    private func verifyTrue(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(value, message, file: file, line: line) }
    private func verifyFalse(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(value, message, file: file, line: line) }
    private func verifyEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(a, b, message, file: file, line: line) }
    let origin = "https://adoption.test"
    func fixture() throws -> [String: JSON] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "child-adoption-contract-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
    }
    func bytes(_ raw: [String: JSON]) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(raw) }
    func context(_ raw: [String: JSON], session: UUID = UUID()) throws -> ChildTaskRecordContext {
        try .init(account: raw["account"]!.text, origin: origin, workspace: UUID(), session: session, access: UUID(), snapshot: UUID(), root: Record(["id": raw["task_id"]!, "task_generation": raw["task_generation"]!, "project_id": raw["project_id"]!, "title": .string("Current root")]))
    }
    func read(_ raw: [String: JSON]) throws -> ChildTaskAdoptionReview { try .init(data: bytes(raw), context: context(raw), workspaceID: try TeamProjectValue.optionalID(raw["workspace_id"])) }
    func command(_ f: [String: JSON], name: String = "command") throws -> ChildTaskAdoptionCommand { try .init(account: f[name]!.object["account"]!.text, origin: origin, body: f[name]!.object, nodeCount: f["review"]!.object["node_count"]!.integer) }
    func directory() throws -> URL { let d = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-adoption-unit-" + UUID().uuidString); try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); addTeardownBlock { try? FileManager.default.removeItem(at: d) }; return d }
    func journal(_ c: ChildTaskAdoptionCommand, _ io: any CalendarSecureItemIO, _ d: URL) throws -> ChildTaskAdoptionJournal { try .init(account: c.account, origin: c.origin, io: io, coordinationDirectory: d.appendingPathComponent("locks"), removalDirectory: d.appendingPathComponent("removal")) }
    @MainActor private func model(_ scope: ChildTaskFieldClientScope, _ journal: ChildTaskAdoptionJournal, _ service: AdoptionService, current: @escaping () -> ChildTaskFieldClientScope?, canSend: @escaping (ChildTaskAdoptionCommand) -> Bool = { _ in true }, admit: @escaping (ChildTaskAdoptionCommand) async throws -> Void = { _ in }, reviewCurrent: @escaping (ChildTaskAdoptionReview) -> Bool = { _ in true }) -> ChildTaskAdoptionModel {
        .init(scope: scope, journal: journal, service: service, current: current, canSend: canSend, admit: admit, reviewCurrent: reviewCurrent)
    }
    func testActualOwnedSQLReviewBuildsMetadataOnlyCommandAndStrictResults() throws {
        let f = try fixture(), review = try read(f["review"]!.object), c = try command(f)
        let rebuilt = try ChildTaskAdoptionCommand(review: review, requestID: UUID(uuidString: c.id)!)
        verifyEqual(c, rebuilt); verifyEqual(review.preview.map(\.depth), [1,2,1]); verifyEqual(review.preview[0].id.utf8.map { $0 }, Array("e\u{301}".utf8))
        verifyTrue(try c.result(f["receipt"]!.object).applied); verifyTrue(try c.result(f["unknown"]!.object).unknown)
        verifyTrue(try command(f, name: "closedCommand").result(f["closed"]!.object).closed)
        let stored = try JSONEncoder().encode(c); verifyEqual(try ChildTaskAdoptionCommand(data: stored), c)
        XCTAssertLessThan(try bytes(c.body).count, 2000); verifyFalse(String(decoding: stored, as: UTF8.self).contains("Original older notes"))
        verifyFalse(review.description.contains("Keep my")); verifyFalse(review.debugDescription.contains("Keep my"))
    }
    func testActualMalformedReviewsRetainOriginalAndCannotConstructAdoption() throws {
        for raw in try fixture()["malformed"]!.list.map(\.object) {
            let review = try read(raw); verifyFalse(review.eligible); XCTAssertNotNil(review.originalSource)
            let source = try JSONDecoder().decode(JSON.self, from: XCTUnwrap(review.originalSource)); verifyEqual(source, raw["source_tree"])
            XCTAssertThrowsError(try ChildTaskAdoptionCommand(review: review))
        }
    }
    func testReviewRejectsWrongContextWorkspaceCountsAndUnknownFields() throws {
        let original = try fixture()["review"]!.object, captured = try context(original)
        for (key, value) in [("account", JSON.string(UUID().uuidString.lowercased())), ("task_generation", .null), ("workspace_id", .string(UUID().uuidString.lowercased())), ("node_count", .number(99)), ("max_depth", .number(23)), ("extra", .bool(true))] {
            var raw = original; raw[key] = value
            XCTAssertThrowsError(try ChildTaskAdoptionReview(data: bytes(raw), context: captured, workspaceID: nil), key)
        }
        var adopted = original; adopted["state"] = .string("records"); XCTAssertThrowsError(try read(adopted))
        adopted["can_adopt"] = .bool(false); verifyFalse(try read(adopted).eligible)
    }
    func testOriginalOpaqueJSONKeepsPreciseNumbersAndDistinctUnicodeKeys() throws {
        var raw = try fixture()["review"]!.object
        let source = "[{\"id\":\"one\",\"title\":\"Exact original\",\"future\":{\"large\":1e1000,\"precise\":9007199254740993,\"é\":1,\"e\u{301}\":2}}]"
        raw["node_count"] = .number(1); raw["max_depth"] = .number(1); raw["source_bytes"] = .number(Double(source.utf8.count)); raw["source_tree"] = .null
        let envelope = String(decoding: try bytes(raw), as: UTF8.self).replacingOccurrences(of: "\"source_tree\":null", with: "\"source_tree\":" + source)
        let review = try ChildTaskAdoptionReview(data: Data(envelope.utf8), context: context(raw), workspaceID: nil)
        verifyEqual(review.originalSource, Data(source.utf8)); verifyEqual(review.preview.map(\.title), ["Exact original"])
        let padded = Data(("xx" + envelope + "zz").utf8)
        let sliced = padded.dropFirst(2).dropLast(2)
        verifyEqual(try ChildTaskAdoptionReview(data: sliced, context: context(raw), workspaceID: nil).originalSource, Data(source.utf8))
        let c = try ChildTaskAdoptionCommand(review: review); verifyEqual(c.nodeCount, 1); verifyFalse(String(decoding: try bytes(c.body), as: UTF8.self).contains("precise"))
    }
    func testRawSourceValidationRejectsDuplicateKeysAndInvalidPrimitiveTokens() throws {
        var raw = try fixture()["review"]!.object; raw["source_tree"] = .null; raw["node_count"] = .number(1); raw["max_depth"] = .number(1)
        let prefix = String(decoding: try bytes(raw), as: UTF8.self)
        let sources = ["[{\"id\":\"a\",\"future\":{\"same\":1,\"same\":2}}]"] + ["NaN", "Infinity", "01", "1.", "1e+", "nullx", "-"].map { "[{\"id\":\"a\",\"future\":" + $0 + "}]" }
        for source in sources { let data = Data(prefix.replacingOccurrences(of: "\"source_tree\":null", with: "\"source_tree\":" + source).utf8); XCTAssertThrowsError(try ChildTaskAdoptionReview(data: data, context: context(raw), workspaceID: nil), source) }
    }
    func testOmittedOversizedSourceCannotBeMistakenForAnOriginalNullTree() throws {
        var raw = try fixture()["review"]!.object
        for (k,v) in ["source_tree":JSON.null,"source_included":.bool(false),"source_bytes":.number(2_000_001),"state":.string("review"),"issue":.string("source_size"),"node_count":.null,"max_depth":.null,"can_adopt":.bool(false)] { raw[k] = v }
        let review = try read(raw); XCTAssertNil(review.originalSource); verifyFalse(review.eligible); XCTAssertThrowsError(try ChildTaskAdoptionCommand(review: review))
        XCTAssertThrowsError(try ChildTaskAdoptionReview(data: Data(repeating: 32, count: ChildTaskAdoptionReview.maximumBytes + 1), context: context(raw), workspaceID: nil))
    }
    func testNullAndEmptySourcesStayDistinctInAnExplicitWorkspace() throws {
        let workspace = UUID().uuidString.lowercased()
        for source in [JSON.null, JSON.array([])] {
            var raw = try fixture()["review"]!.object
            raw["workspace_id"] = .string(workspace); raw["source_tree"] = source
            raw["node_count"] = .number(0); raw["max_depth"] = .number(0)
            raw["root_kind"] = .string(source == .null ? "null" : "array"); raw["source_bytes"] = .number(source == .null ? 4 : 2)
            let review = try ChildTaskAdoptionReview(data: bytes(raw), context: context(raw), workspaceID: workspace)
            verifyEqual(review.originalSource, Data((source == .null ? "null" : "[]").utf8))
            verifyEqual(try ChildTaskAdoptionCommand(review: review).nodeCount, 0)
        }
    }
    func testCounterLexemesAndReceiptBindingsAreStrict() throws {
        let f = try fixture(), c = try command(f), original = try bytes(f["receipt"]!.object)
        let decimal = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"node_count\":3", with: "\"node_count\":3.0")
        XCTAssertNotEqual(Data(decimal.utf8), original); XCTAssertThrowsError(try ChildTaskAdoptionResult(command: c, data: Data(decimal.utf8)))
        for (key,value) in [("workspace_id",JSON.string(UUID().uuidString.lowercased())),("review_digest",.string(String(repeating:"0",count:64))),("node_count",.number(2)),("extra",.bool(false))] {
            var raw = f["receipt"]!.object; raw[key] = value; XCTAssertThrowsError(try c.result(raw), key)
        }
    }
    func testColdJournalPreservesAttemptedRequestAndRefusesUncertainDiscard() async throws {
        let f = try fixture(), c = try command(f), io = AdoptionMemoryIO(), d = try directory(), j = try journal(c, io, d), lease = CalendarReadLease()
        try await j.enqueue(c, lease: lease); _ = try await j.attempt(c, lease: lease)
        do { try await j.discard(c, lease: lease); XCTFail("Uncertain request must remain") } catch {}
        let cold = try journal(c, io, d), state = try await cold.load(); verifyEqual(state.entries.first?.command, c); verifyEqual(state.entries.first?.phase, .attempted)
        try await cold.settle(c, result: c.result(f["receipt"]!.object), lease: lease); let settled = try await j.load(); verifyEqual(settled.entries.first?.phase, .applied)
    }
    func testPendingRootsCannotOverlapAndTerminalProofCannotChange() async throws {
        let f = try fixture(), c = try command(f), io = AdoptionMemoryIO(), j = try journal(c, io, directory()), lease = CalendarReadLease()
        try await j.enqueue(c, lease: lease)
        var body = c.body; body["request_id"] = .string(UUID().uuidString.lowercased()); let other = try ChildTaskAdoptionCommand(account: c.account, origin: c.origin, body: body, nodeCount: c.nodeCount)
        do { try await j.enqueue(other, lease: lease); XCTFail("One pending adoption per root") } catch {}
        _ = try await j.attempt(c, lease: lease); var closed = f["receipt"]!.object; closed["state"] = .string("closed"); closed["node_count"] = .null
        try await j.settle(c, result: c.result(closed), lease: lease)
        do { try await j.settle(c, result: c.result(f["receipt"]!.object), lease: lease); XCTFail("Closed cannot become applied") } catch {}
        verifyEqual(try await j.load().entries.first?.phase, .closed)
    }
    @MainActor func testLostReplyColdRetryUsesOriginalIdentity() async throws {
        let f = try fixture(), review = try read(f["review"]!.object), c = try command(f), scope = ChildTaskFieldClientScope(review.context), io = AdoptionMemoryIO(), d = try directory(), j = try journal(c, io, d), service = AdoptionService(f["receipt"]!.object)
        let first = model(scope,j,service,current:{scope}); verifyTrue(await first.queue(c,review:review)); service.loseReply = true
        verifyFalse(await first.run(c,operation:.send)); verifyEqual(first.entries.first?.phase,.attempted)
        first.close(); service.loseReply = false
        let cold = model(scope,try journal(c,io,d),service,current:{scope}); await cold.load(); verifyTrue(await cold.run(c,operation:.send))
        verifyEqual(cold.entries.first?.phase,.applied); verifyEqual(cold.entries.first?.command.id,c.id); verifyEqual(service.calls,[.send,.send])
    }
    @MainActor func testCheckAndCloseWorkWithSendingDeniedAndUnknownRemainsPending() async throws {
        let f = try fixture(), review = try read(f["review"]!.object), c = try command(f), scope = ChildTaskFieldClientScope(review.context), io = AdoptionMemoryIO(), j = try journal(c,io,directory()), service = AdoptionService(f["unknown"]!.object)
        let m = model(scope,j,service,current:{scope},canSend:{_ in false}); verifyTrue(await m.queue(c,review:review)); verifyFalse(await m.run(c,operation:.send)); verifyEqual(service.calls,[])
        verifyTrue(await m.run(c,operation:.check)); verifyEqual(m.entries.first?.phase,.attempted)
        var closed = f["receipt"]!.object; closed["state"] = .string("closed"); closed["node_count"] = .null; service.raw = closed
        verifyTrue(await m.run(c,operation:.close)); verifyEqual(m.entries.first?.phase,.closed); verifyEqual(service.calls,[.check,.close])
    }
    @MainActor func testLateScopeChangeNeverPublishesOldResult() async throws {
        let f = try fixture(), review = try read(f["review"]!.object), c = try command(f), scope = ChildTaskFieldClientScope(review.context), io = AdoptionMemoryIO(), j = try journal(c,io,directory()), service = AdoptionService(f["receipt"]!.object)
        var current: ChildTaskFieldClientScope? = scope; let m = model(scope,j,service,current:{current}); verifyTrue(await m.queue(c,review:review)); service.beforeReply = {current=nil}
        verifyFalse(await m.run(c,operation:.send)); verifyTrue(m.entries.isEmpty); XCTAssertNil(m.message); verifyEqual(try await j.load().entries.first?.phase,.attempted)
    }
    @MainActor func testFailedAttemptWritePreventsNetworkAndWriteAfterErrorRecoversProof() async throws {
        let f = try fixture(), review = try read(f["review"]!.object), c = try command(f), scope = ChildTaskFieldClientScope(review.context), io = AdoptionMemoryIO(), j = try journal(c,io,directory()), service = AdoptionService(f["receipt"]!.object), m = model(scope,j,service,current:{scope})
        verifyTrue(await m.queue(c,review:review)); io.failWrite=true; verifyFalse(await m.run(c,operation:.send)); verifyEqual(service.calls,[])
        io.failWrite=false; service.beforeReply = {io.failAfterWrite=true}; verifyTrue(await m.run(c,operation:.send)); verifyEqual(m.entries.first?.phase,.applied); verifyEqual(service.calls,[.send])
    }
    @MainActor func testAdmissionAndSnapshotChangesKeepUnsentRequestsOffDisk() async throws {
        let f = try fixture(), review = try read(f["review"]!.object), c = try command(f), scope = ChildTaskFieldClientScope(review.context), io = AdoptionMemoryIO(), j = try journal(c,io,directory()), service = AdoptionService(f["receipt"]!.object)
        var fresh = true; let m = model(scope,j,service,current:{scope},admit:{_ in fresh=false},reviewCurrent:{_ in fresh})
        verifyFalse(await m.queue(c,review:review)); verifyTrue(try await j.load().entries.isEmpty); XCTAssertNil(try io.read(key:"unused")); verifyEqual(service.calls,[])
    }
    func testEncryptedColdRecoveryWrongKeyAndAccountRemovalFence() async throws {
        let f = try fixture(), c = try command(f), d = try directory(), key = SymmetricKey(size:.bits256)
        let io = ReviewedTeamCommandFileIO<ChildTaskAdoptionState>(directory:d.appendingPathComponent("vault"),account:c.account,origin:c.origin,encryptionKey:{key}), j = try journal(c,io,d), lease=CalendarReadLease()
        try await j.enqueue(c,lease:lease); let sealed=try Data(contentsOf:io.file); verifyFalse(String(decoding:sealed,as:UTF8.self).contains(c.id))
        let wrong = ReviewedTeamCommandFileIO<ChildTaskAdoptionState>(directory:d.appendingPathComponent("vault"),account:c.account,origin:c.origin,encryptionKey:{SymmetricKey(size:.bits256)})
        do {_ = try await journal(c,wrong,d).load();XCTFail("Wrong encryption key must fail")}catch{}
        verifyEqual(try Data(contentsOf:io.file),sealed); try await j.removeAccount(); verifyFalse(FileManager.default.fileExists(atPath:io.file.path))
        try AccountRemovalDisk(directory:d.appendingPathComponent("removal"),account:c.account).removeCache()
        do {try await j.enqueue(c,lease:lease);XCTFail("Removal blocks resurrection")}catch{}
        verifyFalse(FileManager.default.fileExists(atPath:io.file.path))
    }
    func testCorruptJournalCannotPresentUnknownOrCrossBoundProofAsApplied() throws {
        let f = try fixture(), c = try command(f), result = try c.result(f["receipt"]!.object)
        let state=try ChildTaskAdoptionState(account:c.account,origin:c.origin,entries:[.init(command:c,phase:.applied,result:result)])
        verifyEqual(try ChildTaskAdoptionState(data:JSONEncoder().encode(state)).entries.first?.phase,.applied)
        XCTAssertThrowsError(try ChildTaskAdoptionState(account:c.account,origin:c.origin,entries:[.init(command:c,phase:.applied,result:c.result(f["unknown"]!.object))]))
        XCTAssertThrowsError(try ChildTaskAdoptionState(account:c.account,origin:c.origin,entries:[.init(command:c),.init(command:c)]))
        var raw = try JSONDecoder().decode([String: JSON].self, from: JSONEncoder().encode(state))
        var entry = raw["entries"]!.list[0].object; var wrapped = entry["result"]!.object; wrapped["unsupported"] = .bool(true)
        entry["result"] = .object(wrapped); raw["entries"] = .array([.object(entry)])
        XCTAssertThrowsError(try ChildTaskAdoptionState(data: bytes(raw)))
    }
    @MainActor func testActualBackendReviewAndAllDecisionRoutesArePrivateAndBounded() async throws {
        let f = try fixture(), c = try command(f), config=URLSessionConfiguration.ephemeral; config.protocolClasses=[AdoptionHTTP.self]
        let session=try JSONDecoder().decode(Session.self,from:bytes(["access_token":.string("synthetic"),"refresh_token":.string("synthetic"),"expires_in":.number(3600),"user":.object(["id":.string(c.account)])]))
        let api=Backend(configuration:["URL":origin,"Key":"synthetic-public"],http:URLSession(configuration:config),session:session,persistSession:{_ in})
        var paths:[String]=[]
        AdoptionHTTP.handler={request,peer in
            paths.append(request.url!.path);self.verifyEqual(request.timeoutInterval,25);self.verifyFalse(request.httpShouldHandleCookies);self.verifyEqual(request.value(forHTTPHeaderField:"Cache-Control"),"no-store")
            peer.finish(200,try! self.bytes(request.url!.path.hasSuffix("taskfold_review_child_adoption") ? f["review"]!.object : f["receipt"]!.object))
        };defer{AdoptionHTTP.handler=nil}
        let context=try context(f["review"]!.object,session:api.reminderSessionIncarnation)
        verifyTrue(try await api.childTaskAdoptionReview(context,workspaceID:nil).eligible)
        for operation in [ChildTaskAdoptionOperation.send,.check,.close] {_ = try await api.childTaskAdoption(c,operation:operation,session:api.reminderSessionIncarnation)}
        verifyEqual(paths,["/rest/v1/rpc/taskfold_review_child_adoption"]+Array(repeating:"/rest/v1/rpc/taskfold_adopt_child_records",count:3))
        AdoptionHTTP.handler={_,peer in peer.finish(409,try! self.bytes(["code":.string("PT409"),"message":.string("Private internal notes")]))}
        do{_ = try await api.childTaskAdoption(c,operation:.send,session:api.reminderSessionIncarnation);XCTFail("Refuse stale request")}catch{verifyTrue(error is ChildTaskAdoptionFailure);verifyFalse(error.localizedDescription.contains("Private internal"))}
        AdoptionHTTP.handler={_,peer in peer.finish(200,try! self.bytes(f["unknown"]!.object))}
        do{_ = try await api.childTaskAdoption(c,operation:.send,session:api.reminderSessionIncarnation);XCTFail("Unknown cannot certify Send")}catch{verifyTrue(error is ChildTaskAdoptionFailure)}
        AdoptionHTTP.handler={_,peer in peer.finish(200,Data(repeating:32,count:ChildTaskAdoptionReview.maximumBytes+1))}
        do{_ = try await api.childTaskAdoptionReview(context,workspaceID:nil);XCTFail("Bounded read must refuse oversized response")}catch{guard let e=error as? ChildTaskAdoptionFailure else{return XCTFail("Expected sanitized failure")};if case .limit=e.reason {}else{XCTFail("Expected size limit")}}
    }
}
