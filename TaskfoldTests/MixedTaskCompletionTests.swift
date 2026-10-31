import XCTest
import CryptoKit
@testable import TaskfoldCore

private final class MixedHTTP: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, MixedHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func finish(_ data: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
@MainActor private final class MixedPeer: MixedTaskCompletionService {
    var calls = 0, lose = true
    let proof: MixedTaskCompletionResolution
    init(_ proof: MixedTaskCompletionResolution) { self.proof = proof }
    func mixedTaskCompletion(_ command: MixedTaskCompletionCommand, session: UUID, close: Bool) async throws -> MixedTaskCompletionResolution {
        calls += 1
        if lose { lose = false; throw URLError(.networkConnectionLost) }
        return proof
    }
}
final class MixedTaskCompletionTests: XCTestCase {
    private let origin = "https://mixed-completion.test"
    private func fixture() throws -> [String: JSON] {
        try TaskfoldJSONDecoder().decode([String: JSON].self, from: Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "mixed-task-completion", withExtension: "json", subdirectory: "Fixtures"))))
    }
    private func command(undo: Bool = false) throws -> MixedTaskCompletionCommand {
        let f = try fixture(), b = f[undo ? "undo" : "command"]!.object
        return try .init(account: b["account"]!.text, origin: origin, body: b, original: undo ? .init(body: f["command"]!.object, receipt: f["receipt"]!.object) : nil)
    }
    private func directory() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-mixed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }; return d
    }
    private func journal(_ c: MixedTaskCompletionCommand, _ d: URL, key: SymmetricKey) throws -> MixedTaskCompletionJournal {
        let io = ReviewedTeamCommandFileIO<MixedTaskCompletionState>(directory: d.appendingPathComponent("encrypted"), account: c.account, origin: c.origin, encryptionKey: { key })
        return try .init(account: c.account, origin: c.origin, io: io, coordinationDirectory: d.appendingPathComponent("locks"), removalDirectory: d.appendingPathComponent("removal"))
    }
    func testActualDatabaseCompletionAndWholeUndoConfirmations() throws {
        let f = try fixture(), c = try command(), u = try command(undo: true)
        XCTAssertEqual(try c.resolution(f["receipt"]!.object).receipts.count, c.items.count)
        XCTAssertEqual(try u.resolution(f["undoReceipt"]!.object).receipts.count, c.items.count)
        XCTAssertEqual(c.items.map(\.kind), ["child", "root"])
        XCTAssertEqual(u.body["undo_of"], .string(c.id))
        let encoded = try TaskfoldJSONEncoder().encode(u)
        XCTAssertEqual(try TaskfoldJSONDecoder().decode(MixedTaskCompletionCommand.self, from: encoded), u)
        let text = String(decoding: encoded, as: UTF8.self)
        for field in ["title", "description", "subtasks", "attachments"] { XCTAssertFalse(text.contains("\"" + field + "\"")) }
    }
    func testMalformedRequestsAreRejectedBeforeAnyComputedMemberAccess() throws {
        let c = try command()
        var bad: [[String: JSON]] = []
        for value in [JSON.array([]), .array([.null]), .array([.object(["kind": .string("child"), "command": .null])]), .array([.object(["kind": .string("root"), "task_id": .null, "request_id": .null])])] { var b = c.body; b["items"] = value; bad.append(b) }
        var b = c.body; b["unknown"] = .bool(true); bad.append(b)
        b = c.body; b["items"] = .array(Array(c.body["items"]!.list.reversed())); b["items"] = .array([b["items"]!.list[0],b["items"]!.list[0]]); bad.append(b)
        b = c.body; b["children"] = .array([]); bad.append(b)
        for b in bad { XCTAssertThrowsError(try MixedTaskCompletionCommand(account: c.account, origin: c.origin, body: b)) }
    }
    func testConfirmationCannotOmitReorderOrSubstituteMembers() throws {
        let c = try command(), good = try fixture()["receipt"]!.object
        for values in [Array(good["receipts"]!.list.dropLast()), Array(good["receipts"]!.list.reversed())] {
            var bad = good; bad["receipts"] = .array(values); XCTAssertThrowsError(try c.resolution(bad))
        }
        var bad = good, rows = good["receipts"]!.list, root = rows[1].object
        root["task_id"] = .string(UUID().uuidString.lowercased()); rows[1] = .object(root); bad["receipts"] = .array(rows)
        XCTAssertThrowsError(try c.resolution(bad))
    }
    func testChangedRootClockOrCompletionVersionCannotConfirm() throws {
        let c = try command(), good = try fixture()["receipt"]!.object
        for (field, value) in [("completed_at", JSON.string("2000-01-01T00:00:00Z")), ("completion_version", .number(99))] {
            var bad = good, rows = good["receipts"]!.list, root = rows[1].object, after = root["after"]!.object
            after[field] = value; root["after"] = .object(after); rows[1] = .object(root); bad["receipts"] = .array(rows)
            XCTAssertThrowsError(try c.resolution(bad))
        }
    }
    func testClosedConfirmationContainsNoMemberProofAndCannotPretendApplied() throws {
        let c = try command(); var raw = try fixture()["receipt"]!.object; raw["outcome"] = .string("closed")
        XCTAssertThrowsError(try c.resolution(raw)); raw["receipts"] = .array([]); XCTAssertTrue(try c.resolution(raw).closed)
        raw["outcome"] = .string("applied"); XCTAssertThrowsError(try c.resolution(raw))
    }
    func testWholeUndoRequiresItsCompleteConfirmedParentInSavedState() throws {
        let c = try command(), u = try command(undo: true), f = try fixture()
        XCTAssertThrowsError(try MixedTaskCompletionState(account: c.account, origin: c.origin, entries: [.init(command: u, phase: .queued)]))
        let parent = MixedTaskCompletionState.Entry(command: c, phase: .confirmed, decision: f["receipt"]!.object)
        let state = try MixedTaskCompletionState(account: c.account, origin: c.origin, entries: [parent, .init(command: u, phase: .confirmed, decision: f["undoReceipt"]!.object)])
        XCTAssertEqual(state.parent(of: u)?.command, c)
    }
    func testEncryptedColdReturnAndWrongKeyPreserveExactOriginalRequest() async throws {
        let c = try command(), d = try directory(), key = SymmetricKey(size: .bits256), j = try journal(c,d,key:key)
        try await j.enqueue(c, lease: CalendarReadLease()); _ = try await j.begin(c, lease: CalendarReadLease())
        let bytes = try Data(contentsOf: d.appendingPathComponent("encrypted/" + MixedTaskCompletionState.fileName))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(c.id))
        let cold = try await journal(c,d,key:key).load(); XCTAssertEqual(cold.entries.first?.command,c); XCTAssertEqual(cold.entries.first?.phase,.attempted)
        do { _ = try await journal(c,d,key:SymmetricKey(size:.bits256)).load(); XCTFail("Wrong key") } catch {}
        XCTAssertEqual(try Data(contentsOf:d.appendingPathComponent("encrypted/" + MixedTaskCompletionState.fileName)),bytes)
    }
    @MainActor func testLostReplySurvivesColdJournalAndRetriesOnlyOriginalGroup() async throws {
        let c = try command(), d = try directory(), key = SymmetricKey(size:.bits256)
        let s = ChildTaskFieldClientScope(account:c.account,origin:c.origin,workspace:UUID(),session:UUID(),access:UUID())
        let peer = MixedPeer(try c.resolution(fixture()["receipt"]!.object)), j = try journal(c,d,key:key)
        let model = MixedTaskCompletionRecoveryModel(scope:s,journal:j,service:peer,current:{s},canQueue:{_ in true},canSend:{_ in true},refresh:{})
        let first = await model.perform(c); XCTAssertFalse(first); XCTAssertEqual(model.entries.first?.phase,.attempted); model.close()
        let cold = MixedTaskCompletionRecoveryModel(scope:s,journal:try journal(c,d,key:key),service:peer,current:{s},canQueue:{_ in true},canSend:{_ in true},refresh:{})
        await cold.load(); await cold.send(c); XCTAssertEqual(cold.entries.first?.phase,.confirmed); XCTAssertEqual(cold.entries.first?.command,c); XCTAssertEqual(peer.calls,2);cold.close()
    }
    @MainActor func testBackendUsesPrivateExactRequestsForForwardUndoAndResolution() async throws {
        let f=try fixture();defer{MixedHTTP.handler=nil}
        for (undo,close,path) in [(false,false,"taskfold_complete_mixed_tasks"),(true,false,"taskfold_undo_mixed_completion"),(false,true,"taskfold_close_mixed_completion")] {
            let c=try command(undo:undo), session=try TaskfoldJSONDecoder().decode(Session.self,from:TaskfoldJSONEncoder().encode(["access_token":JSON.string("synthetic"),"refresh_token":.string("synthetic"),"expires_in":.number(3600),"user":.object(["id":.string(c.account)])]))
            let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[MixedHTTP.self]
            let backend=Backend(configuration:["URL":origin,"Key":"synthetic-public"],http:URLSession(configuration:config),session:session,persistSession:{_ in})
            MixedHTTP.handler={ request,pipe in
                XCTAssertEqual(request.url?.path,"/rest/v1/rpc/"+path);XCTAssertFalse(request.httpShouldHandleCookies);XCTAssertEqual(request.cachePolicy,.reloadIgnoringLocalCacheData)
                pipe.finish(try! TaskfoldJSONEncoder().encode(f[undo ? "undoReceipt":"receipt"]!))
            }
            let result=try await backend.mixedTaskCompletion(c,session:backend.reminderSessionIncarnation,close:close);XCTAssertTrue(result.applied)
        }
    }
}
