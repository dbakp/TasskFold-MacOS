import XCTest
import CryptoKit
@testable import TaskfoldCore

private final class RestoreMemoryIO: CalendarSecureItemIO, @unchecked Sendable {
    private let lock = NSLock()
    var bytes: Data?
    var failWrite = false
    var failAfterWrite = false
    func read(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return bytes }
    func write(_ data: Data, key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrite { throw URLError(.cannotWriteToFile) }; bytes = data
        if failAfterWrite { throw URLError(.cannotWriteToFile) }
    }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; bytes = nil }
}
private final class RestoreHTTP: URLProtocol {
    static var handler: ((URLRequest, RestoreHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func finish(_ status: Int, _ data: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
@MainActor private final class RestoreServiceDouble: ChildTaskRestoreService {
    let reply: [String: JSON]
    var operations: [ChildTaskRepairOperation] = []
    var loseReply = false
    var callback: (() -> Void)?
    init(_ reply: [String: JSON]) { self.reply = reply }
    func childTaskRestore(_ command: ChildTaskRestoreCommand, operation: ChildTaskRepairOperation, session: UUID) async throws -> ChildTaskRestoreResult {
        operations.append(operation); callback?()
        if loseReply { throw URLError(.networkConnectionLost) }
        return try command.result(reply)
    }
}

final class ChildTaskRestoreTests: XCTestCase {
    private let origin = "https://restore-tests.example.invalid"
    private func fixture() throws -> [String: JSON] {
        try TaskfoldJSONDecoder().decode([String: JSON].self, from: Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "child-original-restore-contract-v1", withExtension: "json", subdirectory: "Fixtures"))))
    }
    private func command(_ body: [String: JSON]? = nil) throws -> ChildTaskRestoreCommand {
        let body = try body ?? fixture()["command"]!.object
        return try .init(account: body["account"]!.text, origin: origin, body: body)
    }
    private func scope(_ command: ChildTaskRestoreCommand) -> ChildTaskFieldClientScope { .init(account: command.account, origin: origin, workspace: UUID(), session: UUID(), access: UUID()) }
    private func wire(_ value: [String: JSON]) throws -> Data { let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    private func review(scope: ChildTaskFieldClientScope, edit: (inout [String: JSON]) -> Void = { _ in }) throws -> ChildTaskRestoreReview {
        var raw = try fixture()["review"]!.object; edit(&raw)
        return try .init(data: wire(raw), scope: scope, snapshot: UUID(), identity: command().identity, mode: .restore)
    }
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-restore-unit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }; return directory
    }
    private func journal(_ command: ChildTaskRestoreCommand, io: any CalendarSecureItemIO, directory: URL) throws -> ChildTaskRestoreJournal {
        try .init(account: command.account, origin: command.origin, io: io, coordinationDirectory: directory.appendingPathComponent("locks"), removalDirectory: directory.appendingPathComponent("removal"))
    }
    @MainActor private func model(_ scope: ChildTaskFieldClientScope, _ journal: ChildTaskRestoreJournal, _ service: RestoreServiceDouble, current: @escaping () -> ChildTaskFieldClientScope?, canSend: @escaping (ChildTaskRestoreCommand) -> Bool = { _ in true }, reviewCurrent: @escaping (ChildTaskRestoreReview) -> Bool = { _ in true }) -> ChildTaskRestoreModel {
        .init(scope: scope, journal: journal, service: service, current: current, canSend: canSend, admit: { _ in }, reviewCurrent: reviewCurrent)
    }
    func testActualServiceMetadataAndEveryReversalReceiptBindExactCommands() throws {
        let f = try fixture(), c = try command(), r = try c.result(f["reply"]!.object)
        XCTAssertTrue(r.applied); XCTAssertEqual(r.raw["restoration_id"], .string(c.id))
        let scope = scope(c), p = try review(scope: scope), reconstructed = try ChildTaskRestoreCommand(review: p, requestID: XCTUnwrap(UUID(uuidString: c.id)))
        XCTAssertEqual(c, reconstructed)
        for cycle in f["cycles"]!.list {
            let command = try command(cycle.object["command"]!.object)
            XCTAssertTrue(try command.result(cycle.object["reply"]!.object).applied)
        }
        XCTAssertFalse(String(describing: c).contains(c.rootID)); XCTAssertFalse(String(reflecting: c).contains(c.id))
    }
    func testOpaqueSourcesKeepUnsafeNumbersUnknownFieldsAndDistinctUnicode() throws {
        let c = try command(), scope = scope(c)
        var raw = try fixture()["review"]!.object; raw["current_source"] = .null; raw["target_source"] = .null
        let source = "[{\"id\":\"opaque\",\"title\":\"Proof\",\"future\":{\"exact\":9007199254740993,\"huge\":1e500,\"é\":1,\"é\":2}}]"
        var text = String(decoding: try wire(raw), as: UTF8.self)
        for key in ["current_source", "target_source"] { text = text.replacingOccurrences(of: "\"" + key + "\":null", with: "\"" + key + "\":" + source) }
        let value = try ChildTaskRestoreReview(data: Data(text.utf8), scope: scope, snapshot: UUID(), identity: c.identity, mode: .restore)
        XCTAssertEqual(value.target.source, Data(source.utf8)); XCTAssertEqual(value.current.source, Data(source.utf8))
        XCTAssertTrue(value.target.excerpt.contains("1e500")); XCTAssertEqual(value.target.outline?.items.first?.title, "Proof")
        let stored = try wire(TaskfoldJSONDecoder().decode([String: JSON].self, from: TaskfoldJSONEncoder().encode(ChildTaskRestoreCommand(review: value))))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("future"))
    }
    func testReviewRefusesWrongScopeModeIdentityFlagsAndNullClaims() throws {
        let c = try command(), scope = scope(c)
        for (key, value): (String, JSON) in [("account", .string(UUID().uuidString.lowercased())), ("task_id", .string(UUID().uuidString.lowercased())), ("mode", .string("undo")), ("revision", .number(1)), ("restore_id", .string(UUID().uuidString.lowercased())), ("enabled", .string("true")), ("availability", .string("paused")), ("current_sql_null", .bool(true)), ("target_sql_null", .bool(true)), ("file_count", .number(257)), ("review_digest", .string("bad")), ("unknown", .null)] {
            XCTAssertThrowsError(try review(scope: scope) { $0[key] = value }, key)
        }
        let paused = try review(scope: scope) { $0["enabled"] = .bool(false); $0["availability"] = .string("paused") }
        XCTAssertFalse(paused.enabled); XCTAssertThrowsError(try ChildTaskRestoreCommand(review: paused))
    }
    func testWireCountersDuplicateKeysAndOversizedBodiesRefuse() throws {
        let c = try command(), scope = scope(c), raw = try fixture()["review"]!.object
        let text = String(decoding: try wire(raw), as: UTF8.self)
        for value in ["1.0", "1e0"] {
            let bad = text.replacingOccurrences(of: "\"protocol\":1", with: "\"protocol\":" + value)
            XCTAssertThrowsError(try ChildTaskRestoreReview(data: Data(bad.utf8), scope: scope, snapshot: UUID(), identity: c.identity, mode: .restore))
        }
        XCTAssertThrowsError(try ChildTaskRestoreReview(data: Data(("{\"protocol\":1," + text.dropFirst()).utf8), scope: scope, snapshot: UUID(), identity: c.identity, mode: .restore))
        let encoded = String(decoding: try TaskfoldJSONEncoder().encode(c), as: UTF8.self)
        XCTAssertThrowsError(try ChildTaskRestoreCommand(data: Data(("{\"account\":\"" + c.account + "\"," + encoded.dropFirst()).utf8)))
        XCTAssertThrowsError(try ChildTaskRestoreCommand(data: Data(repeating: 32, count: ChildTaskRestoreCommand.maximumStoredBytes + 1)))
        for revision in [JSON.number(-1), .number(0.5), .number(9_007_199_254_740_991), .string("0")] {
            var body = c.body; body["revision"] = revision; XCTAssertThrowsError(try command(body))
        }
    }
    func testReceiptRejectsMismatchedVersionIdentityAndNonAppliedProofs() throws {
        let c = try command(), raw = try fixture()["reply"]!.object
        for (key, value): (String, JSON) in [("request_id", .string(UUID().uuidString.lowercased())), ("task_id", .string(UUID().uuidString.lowercased())), ("next_revision", .number(3)), ("phase", .string("undone")), ("restoration_id", .null), ("after_digest", .string("bad")), ("replayed", .string("false")), ("extra", .null), ("state", .string("unknown"))] {
            var bad = raw; bad[key] = value; XCTAssertThrowsError(try c.result(bad), key)
        }
        var replay = raw; replay["replayed"] = .bool(true)
        XCTAssertTrue(try c.result(raw).agrees(c.result(replay)))
        for state in ["unknown", "closed"] {
            var reply = c.body; reply["state"] = .string(state); reply["replayed"] = .bool(false)
            for key in ["restoration_id", "next_revision", "phase", "after_digest"] { reply[key] = .null }
            let result = try c.result(reply); XCTAssertEqual(result.closed, state == "closed"); XCTAssertEqual(result.unknown, state == "unknown")
        }
    }
    func testJournalColdLoadRetainsOriginalIdentityAndBlocksConflictingRoot() async throws {
        let c = try command(), io = RestoreMemoryIO(), directory = try directory(), j = try journal(c, io: io, directory: directory), lease = CalendarReadLease()
        try await j.enqueue(c, lease: lease)
        var changed = c.body; changed["request_id"] = .string(UUID().uuidString.lowercased()); let other = try command(changed)
        do { try await j.enqueue(other, lease: lease); XCTFail("Two pending requests share a root") } catch {}
        _ = try await j.attempt(c, lease: lease)
        let cold = try journal(c, io: io, directory: directory), loaded = try await cold.load()
        XCTAssertEqual(loaded.entries.first?.command, c); XCTAssertEqual(loaded.entries.first?.phase, .attempted)
        do { try await cold.discard(c, lease: lease); XCTFail("Attempt cannot be discarded") } catch {}
        let result = try c.result(fixture()["reply"]!.object); try await cold.settle(c, result: result, lease: lease)
        do { try await cold.discard(c, lease: lease); XCTFail("Reversal identity cannot be discarded") } catch {}
        let final = try await cold.load(); XCTAssertEqual(final.entries.first?.phase, .applied)
    }
    func testStateRejectsTamperedReceiptsAndForeignOrDuplicateCommands() throws {
        let c = try command(), result = try c.result(fixture()["reply"]!.object)
        XCTAssertThrowsError(try ChildTaskRestoreState(account: UUID().uuidString.lowercased(), origin: origin, entries: [.init(command: c)]))
        XCTAssertThrowsError(try ChildTaskRestoreState(account: c.account, origin: origin, entries: [.init(command: c), .init(command: c)]))
        XCTAssertThrowsError(try ChildTaskRestoreState(account: c.account, origin: origin, entries: [.init(command: c, phase: .applied)]))
        XCTAssertThrowsError(try ChildTaskRestoreState(account: c.account, origin: origin, entries: [.init(command: c, phase: .closed, result: result)]))
        let state = try ChildTaskRestoreState(account: c.account, origin: origin, entries: [.init(command: c, phase: .applied, result: result)])
        XCTAssertEqual(try ChildTaskRestoreState(data: TaskfoldJSONEncoder().encode(state)).entries, state.entries)
    }
    @MainActor func testLostReplyRecoversByCheckAfterColdModelWithoutResending() async throws {
        let c = try command(), scope = scope(c), io = RestoreMemoryIO(), directory = try directory(), j = try journal(c, io: io, directory: directory)
        let service = RestoreServiceDouble(try fixture()["reply"]!.object), p = try review(scope: scope), model = model(scope, j, service, current: { scope })
        do { let actual = await model.queue(c, review: p); XCTAssertTrue(actual) }; service.loseReply = true
        do { let actual = await model.run(c, operation: .send); XCTAssertFalse(actual) }; XCTAssertEqual(model.entries.first?.phase, .attempted)
        model.close(); service.loseReply = false
        let cold = self.model(scope, try journal(c, io: io, directory: directory), service, current: { scope }, canSend: { _ in false })
        await cold.load(); do { let actual = await cold.run(c, operation: .check); XCTAssertTrue(actual) }
        XCTAssertEqual(cold.entries.first?.phase, .applied); XCTAssertEqual(service.operations, [.send, .check])
    }
    @MainActor func testFailedSecureWriteCannotSendAndAmbiguousSaveKeepsRecoverableRequest() async throws {
        let c = try command(), scope = scope(c), io = RestoreMemoryIO(), j = try journal(c, io: io, directory: directory()), service = RestoreServiceDouble(try fixture()["reply"]!.object), p = try review(scope: scope)
        let m = model(scope, j, service, current: { scope }); io.failWrite = true
        do { let actual = await m.queue(c, review: p); XCTAssertFalse(actual) }; XCTAssertTrue(service.operations.isEmpty)
        io.failWrite = false; io.failAfterWrite = true
        do { let actual = await m.queue(c, review: p); XCTAssertFalse(actual) }; XCTAssertEqual(m.entries.first?.command, c); XCTAssertTrue(service.operations.isEmpty)
        io.failAfterWrite = false; do { let actual = await m.run(c, operation: .send); XCTAssertTrue(actual) }; XCTAssertEqual(service.operations, [.send])
    }
    @MainActor func testScopeChangeDuringReplyDoesNotSettleIntoAnotherAccount() async throws {
        let c = try command(), scope = scope(c), io = RestoreMemoryIO(), j = try journal(c, io: io, directory: directory()), service = RestoreServiceDouble(try fixture()["reply"]!.object), p = try review(scope: scope)
        var current: ChildTaskFieldClientScope? = scope
        let m = model(scope, j, service, current: { current }); do { let actual = await m.queue(c, review: p); XCTAssertTrue(actual) }
        service.callback = { current = nil }; do { let actual = await m.run(c, operation: .send); XCTAssertFalse(actual) }; XCTAssertTrue(m.entries.isEmpty)
        let saved = try await j.load(); XCTAssertEqual(saved.entries.first?.phase, .attempted)
    }
    @MainActor func testStaleReviewCannotQueueAndPausedSendingStillAllowsStop() async throws {
        let c = try command(), scope = scope(c), io = RestoreMemoryIO(), j = try journal(c, io: io, directory: directory()), p = try review(scope: scope)
        var reply = c.body; reply["state"] = .string("closed"); reply["replayed"] = .bool(false)
        for key in ["restoration_id", "next_revision", "phase", "after_digest"] { reply[key] = .null }
        let service = RestoreServiceDouble(reply), stale = model(scope, j, service, current: { scope }, reviewCurrent: { _ in false })
        do { let actual = await stale.queue(c, review: p); XCTAssertFalse(actual) }; XCTAssertTrue(service.operations.isEmpty)
        let m = model(scope, j, service, current: { scope }, canSend: { _ in false })
        do { let actual = await m.queue(c, review: p); XCTAssertTrue(actual) }; do { let actual = await m.run(c, operation: .send); XCTAssertFalse(actual) }; XCTAssertTrue(service.operations.isEmpty)
        do { let actual = await m.run(c, operation: .close); XCTAssertTrue(actual) }; XCTAssertEqual(m.entries.first?.phase, .closed)
    }
    func testEncryptedRestoreJournalFencesOtherChildActions() async throws {
        let c = try command(), directory = try directory(), key = SymmetricKey(size: .bits256)
        let folder = directory.appendingPathComponent("Child original restoration requests").appendingPathComponent(c.account).appendingPathComponent(CalendarOAuthConfiguration.digest(c.origin))
        let io = ReviewedTeamCommandFileIO<ChildTaskRestoreState>(directory: folder, account: c.account, origin: c.origin, encryptionKey: { key })
        let state = try ChildTaskRestoreState(account: c.account, origin: c.origin, entries: [.init(command: c)])
        try io.write(TaskfoldJSONEncoder().encode(state), key: ChildTaskRestoreState.storagePrefix + c.account + "." + CalendarOAuthConfiguration.digest(c.origin))
        let admission = ChildTaskActionAdmission(account: c.account, origin: c.origin, directory: directory, encryptionKey: { key })
        XCTAssertThrowsError(try admission.checkOther([c.rootID])); XCTAssertThrowsError(try admission.checkBatch([c.rootID]))
        XCTAssertNoThrow(try admission.checkOther([UUID().uuidString.lowercased()]))
        XCTAssertNoThrow(try admission.checkBatch([c.rootID], includeRestores: false))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.isEmpty)
        for file in files where file.hasDirectoryPath == false { XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(c.rootID)) }
    }
    @MainActor private func backend() throws -> Backend {
        let c = try command(), configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RestoreHTTP.self]
        let session = try TaskfoldJSONDecoder().decode(Session.self, from: wire(["access_token": .string("synthetic"), "refresh_token": .string("synthetic"), "expires_in": .number(3600), "user": .object(["id": .string(c.account)])]))
        return Backend(configuration: ["URL": origin, "Key": "synthetic-public"], http: URLSession(configuration: configuration), session: session, persistSession: { _ in })
    }
    private func body(_ request: URLRequest) -> Data {
        if let bytes = request.httpBody { return bytes }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }; var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) }
        return bytes
    }
    @MainActor func testTransportUsesExactReviewAndSavedDecisionRoutesWithoutSourceUpload() async throws {
        let c = try command(), api = try backend(), f = try fixture()
        let scope = ChildTaskFieldClientScope(account: c.account, origin: origin, workspace: UUID(), session: api.reminderSessionIncarnation, access: UUID())
        var calls: [String] = []
        RestoreHTTP.handler = { request, peer in
            calls.append(request.url!.path)
            let body = try! TaskfoldJSONDecoder().decode([String: JSON].self, from: self.body(request))
            if request.url!.path.hasSuffix("taskfold_review_child_restore") {
                XCTAssertEqual(Set(body.keys), ["_mode", "_repair", "_archive", "_restore"])
                XCTAssertEqual(body["_repair"], c.body["repair_request_id"])
                peer.finish(200, try! self.wire(f["review"]!.object))
            } else {
                XCTAssertEqual(body["_body"], .object(c.body)); XCTAssertEqual(Set(body.keys), ["_operation", "_body"])
                peer.finish(200, try! self.wire(f["reply"]!.object))
            }
        }
        defer { RestoreHTTP.handler = nil }
        let review = try await api.childTaskRestoreReview(identity: c.identity, mode: .restore, restorationID: nil, scope: scope, snapshot: UUID())
        XCTAssertTrue(review.enabled)
        for operation in [ChildTaskRepairOperation.send, .check, .close] { _ = try await api.childTaskRestore(c, operation: operation, session: scope.session) }
        XCTAssertEqual(calls, ["/rest/v1/rpc/taskfold_review_child_restore"] + Array(repeating: "/rest/v1/rpc/taskfold_restore_child_original", count: 3))
    }
    @MainActor func testTransportRefusesExpiredSessionPrivateErrorsAndUnknownSendProof() async throws {
        let c = try command(), api = try backend(); var calls = 0
        RestoreHTTP.handler = { _, _ in calls += 1 }; defer { RestoreHTTP.handler = nil }
        do { _ = try await api.childTaskRestore(c, operation: .check, session: UUID()); XCTFail("Stale session sent") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 0)
        for code in ["PT409", "PT413", "42501", "PT503"] {
            RestoreHTTP.handler = { _, peer in peer.finish(409, try! self.wire(["code": .string(code), "message": .string("Private archived source")])) }
            do { _ = try await api.childTaskRestore(c, operation: .send, session: api.reminderSessionIncarnation); XCTFail("Refused write accepted") }
            catch { XCTAssertTrue(error is ChildTaskRepairFailure); XCTAssertFalse(error.localizedDescription.contains("Private archived source")) }
        }
        var unknown = c.body; unknown["state"] = .string("unknown"); unknown["replayed"] = .bool(false)
        for key in ["restoration_id", "next_revision", "phase", "after_digest"] { unknown[key] = .null }
        RestoreHTTP.handler = { _, peer in peer.finish(200, try! self.wire(unknown)) }
        do { _ = try await api.childTaskRestore(c, operation: .send, session: api.reminderSessionIncarnation); XCTFail("Unknown cannot certify send") } catch { XCTAssertTrue(error is ChildTaskRepairFailure) }
        let checked = try await api.childTaskRestore(c, operation: .check, session: api.reminderSessionIncarnation); XCTAssertTrue(checked.unknown)
    }
}
