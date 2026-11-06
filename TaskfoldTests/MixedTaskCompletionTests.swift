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
@MainActor private final class MixedLostPeer: MixedTaskCompletionService {
    var commands: [MixedTaskCompletionCommand] = []
    func mixedTaskCompletion(_ command: MixedTaskCompletionCommand, session: UUID, close: Bool) async throws -> MixedTaskCompletionResolution {
        commands.append(command); throw URLError(.networkConnectionLost)
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
    private func redoReads(rootChanges: [String: JSON] = [:], childChanges: [String: JSON] = [:], incarnation: String? = nil, revision: Double = 3) throws -> (CompletionSelectionRootRead, [String: ChildTaskRecordRead]) {
        let f = try fixture(), u = try command(undo: true), rows = f["undoReceipt"]!.object["receipts"]!.list
        var root = rows[1].object["after"]!.object, fields = rows[0].object["receipt"]!.object["after"]!.object
        root.merge(rootChanges) { _, new in new }; fields.merge(childChanges) { _, new in new }
        fields["id"] = .string("child"); fields["title"] = .string("Keep newer child title")
        root["title"] = .string("Keep newer root title"); root["subtasks"] = .array([.object(fields)])
        let scope = ChildTaskFieldClientScope(account: u.account, origin: u.origin, workspace: UUID(), session: UUID(), access: UUID())
        let baseline = root.filter { CompletionSelectionRootRead.baselineKeys.contains($0.key) }
        let parent: [String: JSON] = ["protocol": .number(1), "account": .string(u.account), "roots": .array([.object(["task": .object(root), "baseline": .object(baseline), "source_hash": .string(String(repeating: "a", count: 64))])])]
        let roots = try CompletionSelectionRootRead(data: TaskfoldJSONEncoder().encode(parent), taskIDs: [root["id"]!.text], scope: scope)
        let context = try ChildTaskRecordContext(account: u.account, origin: u.origin, workspace: scope.workspace, session: scope.session, access: scope.access, snapshot: UUID(), root: Record(root))
        let response: [String: JSON] = ["protocol": .number(1), "account": .string(u.account), "task_id": root["id"]!, "task_generation": root["task_generation"]!, "project_id": root["project_id"]!, "root_kind": .string("array"), "projection_revision": .number(revision), "records": .array([.object(["node_key": .string("child"), "incarnation": .string(incarnation ?? u.items[0].body["incarnation"]!.text), "revision": .number(revision), "parent_key": .null, "children_kind": .string("absent"), "identity_path": .array([.string("child")]), "sibling_order": .number(0), "fields": .object(fields)])])]
        return (roots, [root["id"]!.text: try ChildTaskRecordRead(data: TaskfoldJSONEncoder().encode(response), context: context)])
    }
    func testRedoUsesConfirmedUndoCohortsFreshNoncesAndOriginalClock() throws {
        let u = try command(undo: true), (roots, reads) = try redoReads(revision: 8)
        let redo = try u.redo(roots: roots, reads: reads, decision: u.resolution(fixture()["undoReceipt"]!.object))
        XCTAssertFalse(redo.isUndo); XCTAssertNotEqual(redo.id, u.id); XCTAssertNotEqual(redo.id, try command().id)
        XCTAssertEqual(redo.items.map(\.kind), ["child", "root"])
        XCTAssertEqual(redo.body["completed_at"], u.original!.body["completed_at"])
        XCTAssertEqual(redo.body["input_zone"], u.original!.body["input_zone"])
        XCTAssertEqual(redo.items[0].body["revision"], .number(8))
        XCTAssertEqual(redo.items[0].body["baseline"], try fixture()["undoReceipt"]!.object["receipts"]!.list[0].object["receipt"]!.object["after"])
        XCTAssertTrue(Set(redo.items.map(\.id)).isDisjoint(with: Set(u.items.map(\.id) + (try command()).items.map(\.id))))
        let wire = String(decoding: try TaskfoldJSONEncoder().encode(redo), as: UTF8.self)
        XCTAssertFalse(wire.contains("Keep newer")); XCTAssertEqual(try TaskfoldJSONDecoder().decode(MixedTaskCompletionCommand.self, from: TaskfoldJSONEncoder().encode(redo)), redo)
    }
    func testRedoRefusesCompletionCyclesReplacementAndOlderReads() throws {
        let u = try command(undo: true), proof = try u.resolution(fixture()["undoReceipt"]!.object)
        let token = try fixture()["undoReceipt"]!.object["receipts"]!.list[0].object["receipt"]!.object["after"]!.object[TeamChecklist.key]!.object
        for pair in [try redoReads(rootChanges: ["completion_version": .number(4)]),
                     try redoReads(childChanges: [TeamChecklist.key: .object(token.merging(["version": .number(4)]) { _, n in n })]),
                     try redoReads(incarnation: UUID().uuidString.lowercased()), try redoReads(revision: 2)] {
            XCTAssertThrowsError(try u.redo(roots: pair.0, reads: pair.1, decision: proof))
        }
        let pair = try redoReads()
        XCTAssertThrowsError(try command().redo(roots: pair.0, reads: pair.1, decision: proof))
    }
    @MainActor func testRedoWithLostResponseIsSavedAsOneFreshRequestAcrossColdReturn() async throws {
        let u = try command(undo: true), pair = try redoReads()
        let redo = try u.redo(roots: pair.0, reads: pair.1, decision: u.resolution(fixture()["undoReceipt"]!.object))
        let d = try directory(), key = SymmetricKey(size: .bits256), peer = MixedLostPeer(), scope = pair.0.scope
        let model = MixedTaskCompletionRecoveryModel(scope: scope, journal: try journal(redo, d, key: key), service: peer, current: { scope }, canQueue: { _ in true }, canSend: { _ in true }, refresh: { XCTFail("Unconfirmed Redo cannot refresh as applied") })
        let applied = await model.perform(redo); XCTAssertFalse(applied); model.close()
        let cold = MixedTaskCompletionRecoveryModel(scope: scope, journal: try journal(redo, d, key: key), service: peer, current: { scope }, canQueue: { _ in true }, canSend: { _ in true }, refresh: { XCTFail("Unconfirmed retry cannot refresh as applied") })
        await cold.load(); await cold.send(redo)
        XCTAssertEqual(cold.entries.count, 1); XCTAssertEqual(cold.entries[0].command, redo); XCTAssertEqual(cold.entries[0].phase, .attempted)
        XCTAssertEqual(peer.commands, [redo, redo]); cold.close()
    }

}
