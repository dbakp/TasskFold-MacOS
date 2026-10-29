import XCTest
import CryptoKit
@testable import TaskfoldCore

private final class ChildFieldIO: CalendarSecureItemIO, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: Data] = [:]
    var failWrite = false
    func read(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return rows[key] }
    func write(_ data: Data, key: String) throws { lock.lock(); defer { lock.unlock() }; if failWrite { throw URLError(.cannotWriteToFile) }; rows[key] = data }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; rows.removeValue(forKey: key) }
}
@MainActor private final class ChildFieldPeer: ChildTaskFieldCommandService {
    var calls: [ChildTaskFieldCommand] = [], applied: [String: ChildTaskFieldReceipt] = [:]
    var lose = false, onReply: (() -> Void)?
    func childTaskFieldCommand(_ command: ChildTaskFieldCommand, session: UUID) async throws -> ChildTaskFieldReceipt {
        calls.append(command)
        var raw = command.body.filter { $0.key != "changes" }
        raw["revision"] = .number(Double(command.body["revision"]!.integer) + 1)
        raw["replayed"] = .bool(applied[command.id] != nil)
        let receipt = try command.confirmed(raw)
        if applied[command.id] == nil { applied[command.id] = receipt }
        onReply?()
        if lose { lose = false; throw URLError(.networkConnectionLost) }
        return receipt
    }
}
private final class ChildFieldHTTP: URLProtocol {
    private static let handlerLock = NSLock()
    private static var storedHandler: ((URLRequest, ChildFieldHTTP) -> Void)?
    static var handler: ((URLRequest, ChildFieldHTTP) -> Void)? {
        get { handlerLock.lock(); defer { handlerLock.unlock() }; return storedHandler }
        set { handlerLock.lock(); storedHandler = newValue; handlerLock.unlock() }
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
final class ChildTaskFieldCommandTests: XCTestCase {
    func read() throws -> ChildTaskRecordRead {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "child-task-record-read", withExtension: "json", subdirectory: "Fixtures"))
        let raw = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        let context = try ChildTaskRecordContext(account: raw["account"]!.text, origin: "https://child-record.test", workspace: UUID(), session: UUID(), access: UUID(), snapshot: UUID(), root: Record(raw["root"]!.object))
        return try ChildTaskRecordRead(data: JSONEncoder().encode(raw["response"]!.object), context: context)
    }
    func command(_ changes: [String: JSON] = ["title": .string("Private child edit")], key: String = "child") throws -> ChildTaskFieldCommand { try .init(read: read(), key: key, changes: changes) }
    func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-child-journal-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func journal(_ command: ChildTaskFieldCommand, io: any CalendarSecureItemIO, root: URL) throws -> ChildTaskFieldJournal {
        try .init(account: command.account, origin: command.origin, io: io, coordinationDirectory: root.appendingPathComponent("locks"), removalDirectory: root.appendingPathComponent("removal"))
    }
    func receipt(_ c: ChildTaskFieldCommand, revision: Double? = nil) throws -> ChildTaskFieldReceipt {
        var raw = c.body.filter { $0.key != "changes" }; raw["revision"] = .number(revision ?? Double(c.body["revision"]!.integer) + 1); raw["replayed"] = .bool(false)
        return try c.confirmed(raw)
    }
    func testActualPostgresCommandAndOriginalReplayReceiptsAgree() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "child-task-field-command", withExtension: "json", subdirectory: "Fixtures"))
        let raw = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        let c = try ChildTaskFieldCommand(account: raw["account"]!.text, origin: raw["origin"]!.text, body: raw["body"]!.object)
        let original = try c.confirmed(raw["receipt"]!.object), replay = try c.confirmed(raw["replay"]!.object)
        XCTAssertEqual(original.raw["revision"], .number(3)); XCTAssertEqual(replay.raw["revision"], original.raw["revision"])
        XCTAssertEqual(original.raw["replayed"], .bool(false)); XCTAssertEqual(replay.raw["replayed"], .bool(true))
    }
    func testCommandsCaptureActualReadAndRetainLiteralAuthoredText() throws {
        let r = try read(), c = try ChildTaskFieldCommand(read: r, key: "child", changes: ["title": .string("Cafe\u{301}")])
        XCTAssertEqual(c.body["task_id"], .string(r.context.root.id)); XCTAssertEqual(c.body["incarnation"], .string(r.nodes["child"]!.incarnation))
        XCTAssertEqual(try JSONDecoder().decode(ChildTaskFieldCommand.self, from: JSONEncoder().encode(c)), c)
        var body = c.body; body["changes"] = .object(["title": .string("Café")])
        XCTAssertNotEqual(try ChildTaskFieldCommand(account: c.account, origin: c.origin, body: body), c)
        XCTAssertFalse(String(reflecting: c).contains("Cafe")); XCTAssertFalse(c.description.contains(c.account))
    }
    func testUnknownCompletionStructureAndMalformedFieldsRefuse() throws {
        for change: [String: JSON] in [["completed": .bool(true)], ["subtasks": .array([])], ["title": .string(" \n")], ["duration_minutes": .number(0)], ["priority": .number(5)], ["due_time": .string("24:00")], ["assigned_to": .string("bad")], ["due_date": .string("2026-02-30")], ["time_zone": .string("Not/AZone")], [:]] {
            XCTAssertThrowsError(try command(change), "\(change.keys)")
        }
        let c = try command(); for key in c.body.keys { var b = c.body; b.removeValue(forKey: key); XCTAssertThrowsError(try ChildTaskFieldCommand(account: c.account, origin: c.origin, body: b), key) }
        XCTAssertThrowsError(try command(["description": .string(String(repeating: "x", count: 100001))]))
    }
    func testReceiptBindsEveryIdentityAndAllowsNoOpOrLaterRevision() throws {
        let c = try command(), good = try receipt(c)
        for key in ["account", "request_id", "task_id", "task_generation", "project_id", "node_key", "incarnation"] {
            var raw = good.raw; raw[key] = .string(UUID().uuidString.lowercased()); XCTAssertThrowsError(try c.confirmed(raw), key)
        }
        var raw = good.raw; raw["changes"] = c.body["changes"]; XCTAssertThrowsError(try c.confirmed(raw))
        raw = good.raw; raw["replayed"] = .string("true"); XCTAssertThrowsError(try c.confirmed(raw))
        XCTAssertNoThrow(try receipt(c, revision: Double(c.body["revision"]!.integer)))
        XCTAssertNoThrow(try receipt(c, revision: Double(c.body["revision"]!.integer) + 20))
        XCTAssertThrowsError(try receipt(c, revision: 0))
    }
    func testEncryptedRoundTripAndOriginScopedCleanup() async throws {
        let c = try command(), directory = try root(), key = SymmetricKey(size: .bits256)
        let io = try ChildTaskFieldJournalFileIO(directory: directory, account: c.account, origin: c.origin, encryptionKey: { key })
        let j = try journal(c, io: io, root: directory)
        _ = try await j.enqueue(c, lease: CalendarReadLease())
        let ciphertext = try Data(contentsOf: io.file)
        XCTAssertFalse(String(decoding: ciphertext, as: UTF8.self).contains("Private child edit"))
        let attrs = try FileManager.default.attributesOfItem(atPath: io.file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try io.file.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let recovered = try await journal(c, io: io, root: directory).load(); XCTAssertEqual(recovered.entries.first?.command, c)
        let other = try ChildTaskFieldJournalFileIO(directory: directory, account: c.account, origin: "https://other.test", encryptionKey: { throw URLError(.userAuthenticationRequired) })
        let otherCommand = try ChildTaskFieldCommand(account: c.account, origin: "https://other.test", body: c.body)
        try await journal(otherCommand, io: other, root: directory).removeAccount()
        XCTAssertTrue(FileManager.default.fileExists(atPath: io.file.path))
        try await j.removeAccount(); XCTAssertFalse(FileManager.default.fileExists(atPath: io.file.path))
    }
    func testCorruptionNeverBecomesEmptyQueue() async throws {
        let c = try command(), directory = try root(), key = SymmetricKey(size: .bits256)
        let io = try ChildTaskFieldJournalFileIO(directory: directory, account: c.account, origin: c.origin, encryptionKey: { key })
        let j = try journal(c, io: io, root: directory); _ = try await j.enqueue(c, lease: CalendarReadLease())
        try Data("corrupt ciphertext".utf8).write(to: io.file)
        do { _ = try await j.load(); XCTFail("Corruption must remain visible") } catch {}
        do { _ = try await j.enqueue(c, lease: CalendarReadLease()); XCTFail("Cannot overwrite corrupt recovery") } catch {}
        XCTAssertEqual(try Data(contentsOf: io.file), Data("corrupt ciphertext".utf8))
    }
    func testUnsentCoalescingKeepsIdentityAndStaleReviewCannotSendOrDiscard() async throws {
        let c = try command(), io = ChildFieldIO(), directory = try root(), j = try journal(c, io: io, root: directory)
        _ = try await j.enqueue(c, lease: CalendarReadLease())
        let later = try command(["description": .string("Added offline")])
        let merged = try await j.enqueue(later, lease: CalendarReadLease())
        XCTAssertEqual(merged.id, c.id); XCTAssertEqual(merged.body["changes"]!.object.count, 2)
        do { _ = try await j.attempt(c, lease: CalendarReadLease()); XCTFail("Old review cannot send merged text") } catch {}
        do { try await j.discard(c, lease: CalendarReadLease()); XCTFail("Old review cannot delete merged text") } catch {}
        let state = try await j.load(); XCTAssertEqual(state.entries.count, 1); XCTAssertEqual(state.entries[0].command, merged)
    }
    func testAttemptFreezesBodyAndSerializesSameTargetWhileOtherChildrenProceed() async throws {
        let c = try command(), io = ChildFieldIO(), directory = try root(), j = try journal(c, io: io, root: directory)
        _ = try await j.enqueue(c, lease: CalendarReadLease()); _ = try await j.attempt(c, lease: CalendarReadLease())
        let later = try command(["title": .string("Later edit")]), sibling = try command(key: "parent")
        _ = try await j.enqueue(later, lease: CalendarReadLease()); _ = try await j.enqueue(sibling, lease: CalendarReadLease())
        do { _ = try await j.attempt(later, lease: CalendarReadLease()); XCTFail("Same target waits for original proof") } catch {}
        _ = try await j.attempt(sibling, lease: CalendarReadLease())
        do { try await j.discard(c, lease: CalendarReadLease()); XCTFail("Uncertain deletion needs explicit review") } catch {}
        try await j.confirm(c, receipt: receipt(c), lease: CalendarReadLease())
        _ = try await j.attempt(later, lease: CalendarReadLease())
        let state = try await j.load(); XCTAssertEqual(state.entries[0].command, c); XCTAssertEqual(state.entries.count, 3)
    }
    func testQueueBoundDoesNotEvictOldRecovery() async throws {
        let c = try command(), io = ChildFieldIO(), directory = try root(), j = try journal(c, io: io, root: directory)
        for i in 0..<64 { var b = c.body; b["request_id"] = .string(UUID().uuidString.lowercased()); b["node_key"] = .string("node-\(i)"); _ = try await j.enqueue(ChildTaskFieldCommand(account: c.account, origin: c.origin, body: b), lease: CalendarReadLease()) }
        do { _ = try await j.enqueue(c, lease: CalendarReadLease()); XCTFail("Full queue needs explicit handling") } catch {}
        let state = try await j.load(); XCTAssertEqual(state.entries.count, 64)
    }
    func testTwoJournalActorsCannotLoseDifferentChildEdits() async throws {
        let c = try command(), other = try command(key: "parent"), io = ChildFieldIO(), directory = try root()
        let one = try journal(c, io: io, root: directory), two = try journal(c, io: io, root: directory)
        async let a = one.enqueue(c, lease: CalendarReadLease()); async let b = two.enqueue(other, lease: CalendarReadLease())
        _ = try await (a, b); let state = try await one.load(); XCTAssertEqual(Set(state.entries.map { $0.command.id }), [c.id, other.id])
    }
    func testRemovalFenceAndCancelledLeasePreventEnqueue() async throws {
        let c = try command(), io = ChildFieldIO(), directory = try root(), j = try journal(c, io: io, root: directory)
        let lease = CalendarReadLease(); lease.cancel()
        do { _ = try await j.enqueue(c, lease: lease); XCTFail("Cancelled lease") } catch {}
        try AccountRemovalDisk(directory: directory.appendingPathComponent("removal"), account: c.account).removeCache()
        do { _ = try await j.enqueue(c, lease: CalendarReadLease()); XCTFail("Removed account") } catch {}
    }
    func testSameRequestCannotChangeIntentAndDifferentRevisionsDoNotCoalesce() async throws {
        let c = try command(), io = ChildFieldIO(), directory = try root(), j = try journal(c, io: io, root: directory)
        _ = try await j.enqueue(c, lease: CalendarReadLease())
        var body = c.body; body["changes"] = .object(["title": .string("Different")])
        let changed = try ChildTaskFieldCommand(account: c.account, origin: c.origin, body: body)
        do { _ = try await j.enqueue(changed, lease: CalendarReadLease()); XCTFail("Same UUID cannot identify new intent") } catch {}
        body["request_id"] = .string(UUID().uuidString.lowercased()); body["revision"] = .number(Double(c.body["revision"]!.integer + 1))
        _ = try await j.enqueue(ChildTaskFieldCommand(account: c.account, origin: c.origin, body: body), lease: CalendarReadLease())
        let state = try await j.load(); XCTAssertEqual(state.entries.count, 2); XCTAssertEqual(state.entries[0].command, c)
    }
    func testReceiptCannotConfirmQueuedOrReplaceAnExistingProof() async throws {
        let c = try command(), io = ChildFieldIO(), directory = try root(), j = try journal(c, io: io, root: directory), proof = try receipt(c)
        _ = try await j.enqueue(c, lease: CalendarReadLease())
        do { try await j.confirm(c, receipt: proof, lease: CalendarReadLease()); XCTFail("Queued intent was never sent") } catch {}
        _ = try await j.attempt(c, lease: CalendarReadLease()); try await j.confirm(c, receipt: proof, lease: CalendarReadLease())
        var replay = proof.raw; replay["replayed"] = .bool(true)
        try await j.confirm(c, receipt: c.confirmed(replay), lease: CalendarReadLease())
        do { try await j.confirm(c, receipt: receipt(c, revision: Double(c.body["revision"]!.integer + 20)), lease: CalendarReadLease()); XCTFail("Conflicting proof") } catch {}
        let state = try await j.load(); XCTAssertEqual(state.entries[0].receipt, proof)
    }
    func testWrongKeyAndSymlinkCannotOverwriteRecovery() async throws {
        let c = try command(), directory = try root(), key = SymmetricKey(size: .bits256), wrong = SymmetricKey(size: .bits256)
        let io = try ChildTaskFieldJournalFileIO(directory: directory, account: c.account, origin: c.origin, encryptionKey: { key })
        let j = try journal(c, io: io, root: directory); _ = try await j.enqueue(c, lease: CalendarReadLease())
        let ciphertext = try Data(contentsOf: io.file)
        let bad = try ChildTaskFieldJournalFileIO(directory: directory, account: c.account, origin: c.origin, encryptionKey: { wrong })
        do { _ = try await journal(c, io: bad, root: directory).enqueue(c, lease: CalendarReadLease()); XCTFail("Wrong key") } catch {}
        XCTAssertEqual(try Data(contentsOf: io.file), ciphertext)
        let target = directory.appendingPathComponent("unrelated"); try Data("kept".utf8).write(to: target)
        try FileManager.default.removeItem(at: io.file); try FileManager.default.createSymbolicLink(at: io.file, withDestinationURL: target)
        do { _ = try await j.enqueue(c, lease: CalendarReadLease()); XCTFail("Symlink") } catch {}
        XCTAssertEqual(try Data(contentsOf: target), Data("kept".utf8))
    }
    @MainActor func testAccessRefusalAndClosedSenderKeepUnsentDraft() async throws {
        let r = try read(), c = try ChildTaskFieldCommand(read: r, key: "child", changes: ["title": .string("Proof")]), io = ChildFieldIO(), directory = try root(), j = try journal(c, io: io, root: directory), peer = ChildFieldPeer(), scope = ChildTaskFieldClientScope(r.context)
        _ = try await j.enqueue(c, lease: CalendarReadLease())
        let sender = ChildTaskFieldSender(scope: scope, journal: j, service: peer, current: { scope }, canSend: { _ in false })
        do { _ = try await sender.send(c); XCTFail("Lost admission") } catch {}
        sender.close()
        do { _ = try await sender.send(c); XCTFail("Closed sender") } catch is CancellationError {} catch { XCTFail("Wrong closed result") }
        let state = try await j.load(); XCTAssertEqual(state.entries[0].phase, .queued); XCTAssertTrue(peer.calls.isEmpty)
    }
    @MainActor func testLostReplyRetriesExactFrozenCommandAfterRelaunch() async throws {
        let r = try read(), c = try ChildTaskFieldCommand(read: r, key: "child", changes: ["title": .string("Proof")]), io = ChildFieldIO(), directory = try root(), j = try journal(c, io: io, root: directory), peer = ChildFieldPeer(), scope = ChildTaskFieldClientScope(r.context)
        _ = try await j.enqueue(c, lease: CalendarReadLease()); peer.lose = true
        let sender = ChildTaskFieldSender(scope: scope, journal: j, service: peer, current: { scope }, canSend: { _ in true })
        do { _ = try await sender.send(c); XCTFail("Reply was lost") } catch {}
        let state = try await j.load(); XCTAssertEqual(state.entries[0].phase, .attempted)
        let cold = try journal(c, io: io, root: directory), retry = ChildTaskFieldSender(scope: scope, journal: cold, service: peer, current: { scope }, canSend: { _ in true })
        let result = try await retry.send(c); XCTAssertEqual(result.raw["replayed"], .bool(true)); XCTAssertEqual(peer.calls, [c, c]); XCTAssertEqual(peer.applied.count, 1)
        let proof = try await cold.load(); XCTAssertEqual(proof.entries[0].phase, .confirmed)
        _ = try await retry.send(c); XCTAssertEqual(peer.calls.count, 2)
    }
    @MainActor func testDiskFailureBeforeAttemptPreventsNetwork() async throws {
        let r = try read(), c = try ChildTaskFieldCommand(read: r, key: "child", changes: ["title": .string("Proof")]), io = ChildFieldIO(), directory = try root(), j = try journal(c, io: io, root: directory), peer = ChildFieldPeer(), scope = ChildTaskFieldClientScope(r.context)
        _ = try await j.enqueue(c, lease: CalendarReadLease()); io.failWrite = true
        let sender = ChildTaskFieldSender(scope: scope, journal: j, service: peer, current: { scope }, canSend: { _ in true })
        do { _ = try await sender.send(c); XCTFail("No durable attempted state") } catch {}
        XCTAssertTrue(peer.calls.isEmpty)
    }
    @MainActor func testFailedReceiptSaveKeepsAttemptAndCanRecoverOriginalProof() async throws {
        let r = try read(), c = try ChildTaskFieldCommand(read: r, key: "child", changes: ["title": .string("Proof")]), io = ChildFieldIO(), directory = try root(), j = try journal(c, io: io, root: directory), peer = ChildFieldPeer(), scope = ChildTaskFieldClientScope(r.context)
        _ = try await j.enqueue(c, lease: CalendarReadLease()); peer.onReply = { io.failWrite = true }
        let sender = ChildTaskFieldSender(scope: scope, journal: j, service: peer, current: { scope }, canSend: { _ in true })
        do { _ = try await sender.send(c); XCTFail("Success requires durable proof") } catch {}
        let state = try await j.load(); XCTAssertEqual(state.entries[0].phase, .attempted)
        io.failWrite = false; peer.onReply = nil; _ = try await sender.send(c); XCTAssertEqual(peer.applied.count, 1)
    }
    @MainActor func testChangedWorkspaceSuppressesBothSuccessAndError() async throws {
        for lost in [false, true] {
            let r = try read(), c = try ChildTaskFieldCommand(read: r, key: "child", changes: ["title": .string("Proof")]), io = ChildFieldIO(), directory = try root(), j = try journal(c, io: io, root: directory), peer = ChildFieldPeer(), scope = ChildTaskFieldClientScope(r.context)
            var current: ChildTaskFieldClientScope? = scope
            _ = try await j.enqueue(c, lease: CalendarReadLease()); peer.lose = lost; peer.onReply = { current = nil }
            let sender = ChildTaskFieldSender(scope: scope, journal: j, service: peer, current: { current }, canSend: { _ in true })
            do { _ = try await sender.send(c); XCTFail("Stale reply") } catch is CancellationError {} catch { XCTFail("Stale error must also be cancelled: \(error)") }
            let state = try await j.load(); XCTAssertEqual(state.entries[0].phase, .attempted)
        }
    }
    @MainActor func testBackendPostsExactScopedBodyWithoutCookiesOrCache() async throws {
        let c = try command(), response = try receipt(c), backend = try backend(c.account)
        defer { ChildFieldHTTP.handler = nil }
        ChildFieldHTTP.handler = { request, pipe in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_edit_child_task"); XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertFalse(request.httpShouldHandleCookies); XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) } }
            let body = try! JSONDecoder().decode([String: JSON].self, from: data)
            XCTAssertEqual(body, ["_body": .object(c.body)])
            pipe.finish(200, try! JSONEncoder().encode(response.raw))
        }
        let proof = try await backend.childTaskFieldCommand(c, session: backend.reminderSessionIncarnation); XCTAssertEqual(proof, response)
    }
    @MainActor func testBackendSanitizesServiceRefusalsAndBoundsReplies() async throws {
        let c = try command(), backend = try backend(c.account)
        defer { ChildFieldHTTP.handler = nil }
        for code in ["PT409", "42501", "PT503", "54000", "55P03", "unknown"] {
            ChildFieldHTTP.handler = { _, pipe in pipe.finish(409, Data("{\"code\":\"\(code)\",\"message\":\"PRIVATE SERVER DETAILS\"}".utf8)) }
            do { _ = try await backend.childTaskFieldCommand(c, session: backend.reminderSessionIncarnation); XCTFail("Refusal") } catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE SERVER")) }
        }
        for declared in [false, true] {
            ChildFieldHTTP.handler = { _, pipe in pipe.finish(200, Data(repeating: 32, count: declared ? 1 : 16385), headers: declared ? ["Content-Length": "16385"] : [:]) }
            do { _ = try await backend.childTaskFieldCommand(c, session: backend.reminderSessionIncarnation); XCTFail("Oversized reply") } catch { XCTAssertFalse(error.localizedDescription.contains("place draft")) }
        }
    }
    @MainActor func testMalformedSuccessRemainsUnconfirmed() async throws {
        let c = try command(), backend = try backend(c.account)
        defer { ChildFieldHTTP.handler = nil }
        var raw = try receipt(c).raw; raw["request_id"] = .string(UUID().uuidString.lowercased())
        let data = try JSONEncoder().encode(raw)
        ChildFieldHTTP.handler = { _, pipe in pipe.finish(200, data) }
        do { _ = try await backend.childTaskFieldCommand(c, session: backend.reminderSessionIncarnation); XCTFail("Foreign proof") }
        catch let error as ChildTaskFieldWriteFailure { XCTAssertEqual(error.reason, .unconfirmed) }
        catch { XCTFail("A malformed success must not imply that no write happened") }
    }
    @MainActor func testBackendRefusesOtherSessionBeforeNetwork() async throws {
        let c = try command(), backend = try backend(c.account)
        defer { ChildFieldHTTP.handler = nil }
        ChildFieldHTTP.handler = { _, _ in XCTFail("Stale session must never send") }
        do { _ = try await backend.childTaskFieldCommand(c, session: UUID()); XCTFail("Old session") } catch is CancellationError {} catch { XCTFail("\(error)") }
    }
    @MainActor func testRecoveryModelSavesBeforeSendingAndRetainsConfirmedProof() async throws {
        let r = try read(), c = try ChildTaskFieldCommand(read: r, key: "child", changes: ["title": .string("Recovered")]), io = ChildFieldIO(), directory = try root(), j = try journal(c, io: io, root: directory), peer = ChildFieldPeer(), scope = ChildTaskFieldClientScope(r.context)
        var refreshes = 0
        let model = ChildTaskFieldRecoveryModel(scope: scope, journal: j, service: peer, current: { scope }, canQueue: { _ in true }, canSend: { _ in true }, refresh: { refreshes += 1 })
        await model.load(); XCTAssertTrue(model.loaded); XCTAssertTrue(model.entries.isEmpty)
        let saved = await model.save(c); XCTAssertEqual(saved, c); XCTAssertTrue(peer.calls.isEmpty); XCTAssertEqual(model.entries.first?.phase, .queued)
        await model.send(c); XCTAssertEqual(refreshes, 1); XCTAssertEqual(model.entries.first?.phase, .confirmed)
        XCTAssertTrue(model.message?.contains("confirmed") == true)
        model.close(); XCTAssertTrue(model.entries.isEmpty); XCTAssertNil(model.message); XCTAssertFalse(model.loaded)
        let state = try await j.load(); XCTAssertEqual(state.entries.first?.phase, .confirmed)
    }
    @MainActor func testRecoveryModelShowsAttemptedAfterLostReplyAndRequiresExplicitDiscard() async throws {
        let r = try read(), c = try ChildTaskFieldCommand(read: r, key: "child", changes: ["title": .string("Recovered")]), io = ChildFieldIO(), directory = try root(), j = try journal(c, io: io, root: directory), peer = ChildFieldPeer(), scope = ChildTaskFieldClientScope(r.context)
        let model = ChildTaskFieldRecoveryModel(scope: scope, journal: j, service: peer, current: { scope }, canQueue: { _ in true }, canSend: { _ in true }, refresh: { XCTFail("Lost reply cannot refresh as success") })
        _ = await model.save(c); peer.lose = true; await model.send(c)
        XCTAssertEqual(model.entries.first?.phase, .attempted); XCTAssertEqual(model.message, ChildTaskFieldWriteFailure(reason: .unconfirmed).localizedDescription)
        await model.discard(c); XCTAssertEqual(model.entries.count, 1)
        await model.discard(c, uncertainConfirmed: true); XCTAssertTrue(model.entries.isEmpty); XCTAssertEqual(peer.applied.count, 1)
    }
    @MainActor func testDiscardRereadsAttemptMadeByAnotherWindowBeforeOfferingActions() async throws {
        let r = try read(), c = try command(), io = ChildFieldIO(), directory = try root(), j = try journal(c, io: io, root: directory), peer = ChildFieldPeer(), scope = ChildTaskFieldClientScope(r.context)
        let model = ChildTaskFieldRecoveryModel(scope: scope, journal: j, service: peer, current: { scope }, canQueue: { _ in true }, canSend: { _ in true }, refresh: {})
        _ = await model.save(c)
        _ = try await j.attempt(c, lease: CalendarReadLease())
        await model.discard(c)
        XCTAssertEqual(model.entries.first?.phase, .attempted)
        XCTAssertTrue(model.loaded); XCTAssertNotNil(model.message); XCTAssertTrue(peer.calls.isEmpty)
        let retained = try await j.load(); XCTAssertEqual(retained.entries.first?.phase, .attempted)
        await model.discard(c, uncertainConfirmed: true)
        XCTAssertTrue(model.entries.isEmpty)
    }
    @MainActor func testDiscardRereadsNewerCoalescedRequestWithoutRemovingIt() async throws {
        let r = try read(), c = try command(), newer = try command(["title": .string("Newer work in the other window")]), io = ChildFieldIO(), directory = try root(), j = try journal(c, io: io, root: directory), peer = ChildFieldPeer(), scope = ChildTaskFieldClientScope(r.context)
        let model = ChildTaskFieldRecoveryModel(scope: scope, journal: j, service: peer, current: { scope }, canQueue: { _ in true }, canSend: { _ in true }, refresh: {})
        _ = await model.save(c)
        let current = try await j.enqueue(newer, lease: CalendarReadLease())
        await model.discard(c)
        XCTAssertEqual(model.entries.first?.command, current)
        XCTAssertNotEqual(current, c); XCTAssertEqual(current.id, c.id)
        let retained = try await j.load(); XCTAssertEqual(retained.entries.first?.command, current)
        XCTAssertTrue(peer.calls.isEmpty)
    }
    @MainActor func testRecoveryModelSuppressesStaleAccountSessionSuccessAndError() async throws {
        for lost in [false, true] {
            let r = try read(), c = try ChildTaskFieldCommand(read: r, key: "child", changes: ["title": .string("Recovered")]), io = ChildFieldIO(), directory = try root(), j = try journal(c, io: io, root: directory), peer = ChildFieldPeer(), scope = ChildTaskFieldClientScope(r.context)
            var current = scope
            let model = ChildTaskFieldRecoveryModel(scope: scope, journal: j, service: peer, current: { current }, canQueue: { _ in true }, canSend: { _ in true }, refresh: { XCTFail("Stale result must not refresh another workspace") })
            _ = await model.save(c); peer.lose = lost
            peer.onReply = { current = .init(account: scope.account, origin: scope.origin, workspace: scope.workspace, session: UUID(), access: scope.access) }
            await model.send(c); XCTAssertTrue(model.entries.isEmpty); XCTAssertNil(model.message); XCTAssertFalse(model.loaded)
            let state = try await j.load(); XCTAssertEqual(state.entries.first?.phase, .attempted)
        }
    }
    @MainActor func testRecoveryModelRejectsStaleCoalescedReviewWithoutNetwork() async throws {
        let r = try read(), c = try ChildTaskFieldCommand(read: r, key: "child", changes: ["title": .string("Recovered")]), later = try ChildTaskFieldCommand(read: r, key: "child", changes: ["description": .string("Later notes")]), io = ChildFieldIO(), directory = try root(), j = try journal(c, io: io, root: directory), peer = ChildFieldPeer(), scope = ChildTaskFieldClientScope(r.context)
        let model = ChildTaskFieldRecoveryModel(scope: scope, journal: j, service: peer, current: { scope }, canQueue: { _ in true }, canSend: { _ in true }, refresh: {})
        _ = await model.save(c); let merged = await model.save(later); XCTAssertEqual(merged?.id, c.id)
        await model.send(c); XCTAssertTrue(peer.calls.isEmpty); XCTAssertEqual(model.entries.first?.command, merged)
        await model.discard(c); XCTAssertEqual(model.entries.count, 1)
    }
    @MainActor func testRecoveryModelDoesNotClaimSuccessWhenConfirmationCannotSave() async throws {
        let r = try read(), c = try ChildTaskFieldCommand(read: r, key: "child", changes: ["title": .string("Recovered")]), io = ChildFieldIO(), directory = try root(), j = try journal(c, io: io, root: directory), peer = ChildFieldPeer(), scope = ChildTaskFieldClientScope(r.context)
        var refreshes = 0
        let model = ChildTaskFieldRecoveryModel(scope: scope, journal: j, service: peer, current: { scope }, canQueue: { _ in true }, canSend: { _ in true }, refresh: { refreshes += 1 })
        _ = await model.save(c); peer.onReply = { io.failWrite = true }; await model.send(c)
        XCTAssertEqual(model.entries.first?.phase, .attempted); XCTAssertEqual(refreshes, 0)
        io.failWrite = false; peer.onReply = nil; await model.send(c)
        XCTAssertEqual(model.entries.first?.phase, .confirmed); XCTAssertEqual(peer.applied.count, 1); XCTAssertEqual(refreshes, 1)
    }
    @MainActor func testRecoveryModelRefusesUnavailableQueueAndClosedPresentation() async throws {
        let r = try read(), c = try ChildTaskFieldCommand(read: r, key: "child", changes: ["title": .string("Recovered")]), io = ChildFieldIO(), directory = try root(), j = try journal(c, io: io, root: directory), peer = ChildFieldPeer(), scope = ChildTaskFieldClientScope(r.context)
        let model = ChildTaskFieldRecoveryModel(scope: scope, journal: j, service: peer, current: { scope }, canQueue: { _ in false }, canSend: { _ in true }, refresh: {})
        let saved = await model.save(c); XCTAssertNil(saved); let state = try await j.load(); XCTAssertTrue(state.entries.isEmpty)
        model.close(); await model.load(); XCTAssertFalse(model.loaded); XCTAssertTrue(peer.calls.isEmpty)
    }
    @MainActor func testRecoveryModelClearsPresentationWhenRefreshChangesAccess() async throws {
        let r = try read(), c = try ChildTaskFieldCommand(read: r, key: "child", changes: ["title": .string("Recovered")]), io = ChildFieldIO(), directory = try root(), j = try journal(c, io: io, root: directory), peer = ChildFieldPeer(), scope = ChildTaskFieldClientScope(r.context)
        var current: ChildTaskFieldClientScope? = scope
        let model = ChildTaskFieldRecoveryModel(scope: scope, journal: j, service: peer, current: { current }, canQueue: { _ in true }, canSend: { _ in true }, refresh: { current = nil })
        _ = await model.save(c); await model.send(c)
        XCTAssertTrue(model.entries.isEmpty); XCTAssertNil(model.message)
        let state = try await j.load(); XCTAssertEqual(state.entries.first?.phase, .confirmed)
    }
    @MainActor func testAsyncCheckpointCannotRetireNewerUnsentTyping() throws {
        let r = try read(), original = Record(r.nodes["child"]!.fields), directory = try root(), key = SymmetricKey(size: .bits256)
        let vault = BackupVault(directory: directory, account: r.context.account, key: { key })
        let session = TaskEditorSession(vault: vault, origin: r.context.origin, original: original, labels: [])
        var draft = original; draft["title"] = .string("First typed title"); session.capture(draft, extras: [:]); XCTAssertTrue(session.flush())
        let submittedRevision = session.latest!.revision
        draft["description"] = .string("Typed while request checkpoint was saving"); session.capture(draft, extras: [:]); XCTAssertTrue(session.flush())
        XCTAssertFalse(session.finish(ifRevision: submittedRevision)); XCTAssertFalse(session.closed)
        XCTAssertEqual(session.latest?.draft["description"], draft["description"])
        XCTAssertTrue(session.finish(ifRevision: session.latest!.revision)); XCTAssertTrue(session.closed)
    }
    @MainActor func testEmptyAndClosedDraftConditionalFinishRemainSafe() throws {
        let r = try read(), original = Record(r.nodes["child"]!.fields), directory = try root(), key = SymmetricKey(size: .bits256)
        let vault = BackupVault(directory: directory, account: r.context.account, key: { key })
        let session = TaskEditorSession(vault: vault, origin: r.context.origin, original: original, labels: [])
        XCTAssertTrue(session.finish(ifRevision: nil)); XCTAssertTrue(session.closed)
        XCTAssertTrue(session.finish(ifRevision: 99))
        session.capture(original, extras: [:]); XCTAssertNil(session.latest)
    }
    @MainActor func testPrivateDraftLiteralUnicodeChangePreventsEarlierFinish() throws {
        let r = try read(), original = Record(r.nodes["child"]!.fields), directory = try root(), key = SymmetricKey(size: .bits256)
        let vault = BackupVault(directory: directory, account: r.context.account, key: { key })
        let session = TaskEditorSession(vault: vault, origin: r.context.origin, original: original, labels: [])
        var first = original; first["title"] = .string("Cafe\u{301}"); session.capture(first, extras: [:]); XCTAssertTrue(session.flush())
        let submitted = session.latest!.revision
        var later = first; later["title"] = .string("Café"); XCTAssertEqual(first, later, "Ordinary String equality hides the authored-byte change")
        session.capture(later, extras: [:]); XCTAssertTrue(session.flush())
        XCTAssertGreaterThan(session.latest!.revision, submitted)
        XCTAssertTrue(session.latest!.draft.title.utf8.elementsEqual("Café".utf8))
        XCTAssertFalse(session.finish(ifRevision: submitted))
        if !session.closed { let saved = try vault.editorDraft(session.id, origin: r.context.origin); XCTAssertTrue(saved.draft.title.utf8.elementsEqual("Café".utf8)); _ = session.finish() }
    }
    @MainActor func testPrivateRecoveryMetadataKeepsLiteralUnicodeRevision() throws {
        let r = try read(), original = Record(r.nodes["child"]!.fields), directory = try root(), key = SymmetricKey(size: .bits256)
        let vault = BackupVault(directory: directory, account: r.context.account, key: { key })
        let session = TaskEditorSession(vault: vault, origin: r.context.origin, original: original, labels: [])
        session.capture(original, extras: ["raw_path": .string("Cafe\u{301}")]); XCTAssertTrue(session.flush()); let before = session.latest!.revision
        session.capture(original, extras: ["raw_path": .string("Café")]); XCTAssertTrue(session.flush())
        XCTAssertGreaterThan(session.latest!.revision, before)
        XCTAssertTrue(session.latest!.extras["raw_path"]!.text.utf8.elementsEqual("Café".utf8)); _ = session.finish()
    }
    @MainActor private func backend(_ account: String) throws -> Backend {
        let session = try JSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic\",\"refresh_token\":\"synthetic\",\"expires_in\":3600,\"user\":{\"id\":\"\(account)\"}}".utf8))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChildFieldHTTP.self]
        return Backend(configuration: ["URL": "https://child-record.test", "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
    }
    private func planningSource() -> Record {
        Record(["id": .string("child"), "title": .string("A planned child"), "due_date": .string("2026-01-08"), "due_time": .string("10:30"), "time_zone": .string("America/New_York"), "scheduled_at": .string("2026-01-08T15:30:00.000Z"), "deadline_date": .string("2026-01-15"), "duration_minutes": .number(45), "future": .object(["literal": .string("Cafe\u{301}")]), "reminder_specs": .array([.object(["future": .bool(true)])])])
    }
    func testPlanningDraftUntouchedAndNoOpKeepExactSourceAndInstant() throws {
        let source = planningSource(); var draft = ChildTaskPlanningDraft(original: source)
        XCTAssertTrue(draft.changes.isEmpty)
        try draft.plannedDay("2026-01-08"); try draft.clock("10:30"); try draft.zone("America/New_York")
        try draft.deadline("2026-01-15"); try draft.estimate(45)
        XCTAssertTrue(draft.changes.isEmpty)
        XCTAssertTrue(AuthoredValueComparison.exactJSON(.object(draft.value.fields), .object(source.fields)))
    }
    func testPlanningDateAndClockChangesRecomputeFixedInstantWithoutMovingDeadline() throws {
        var draft = ChildTaskPlanningDraft(original: planningSource())
        try draft.plannedDay("2026-01-09"); try draft.clock("11:45")
        XCTAssertEqual(draft.value["scheduled_at"], .string("2026-01-09T16:45:00Z"))
        XCTAssertEqual(draft.value["deadline_date"], .string("2026-01-15"))
        XCTAssertEqual(Set(draft.changes.keys), ["due_date", "due_time", "scheduled_at"])
    }
    func testPlanningLocalZoneAndAllDayClearOnlyTheirScheduleFields() throws {
        let source = planningSource(); var draft = ChildTaskPlanningDraft(original: source)
        try draft.zone(nil)
        XCTAssertEqual(draft.value["time_zone"], .null); XCTAssertEqual(draft.value["scheduled_at"], .null)
        XCTAssertEqual(draft.value["due_time"], source["due_time"])
        try draft.clock(nil)
        XCTAssertEqual(draft.value["due_time"], .null); XCTAssertEqual(draft.value["due_date"], source["due_date"])
        XCTAssertEqual(draft.value["deadline_date"], source["deadline_date"]); XCTAssertEqual(draft.value["duration_minutes"], source["duration_minutes"])
    }
    func testPlanningClearDateKeepsDeadlineEstimateRemindersAndOpaqueMetadata() throws {
        let source = planningSource(); var draft = ChildTaskPlanningDraft(original: source)
        try draft.plannedDay(nil)
        for key in ["due_date", "due_time", "time_zone", "scheduled_at"] { XCTAssertEqual(draft.value[key], .null) }
        for key in ["deadline_date", "duration_minutes", "reminder_specs", "future"] { XCTAssertTrue(AuthoredValueComparison.exactJSON(draft.value[key], source[key])) }
    }
    func testPlanningDeadlineAndEstimateDoNotNormalizeLegacySchedule() throws {
        var source = planningSource(); source["due_date"] = .string("future date encoding"); source["scheduled_at"] = .object(["future": .bool(true)])
        var draft = ChildTaskPlanningDraft(original: source)
        try draft.deadline("2026-02-20"); try draft.estimate(90)
        XCTAssertEqual(Set(draft.changes.keys), ["deadline_date", "duration_minutes"])
        XCTAssertTrue(AuthoredValueComparison.exactJSON(draft.value["scheduled_at"], source["scheduled_at"]))
        XCTAssertEqual(draft.value["due_date"], source["due_date"])
    }
    func testPlanningInvalidValuesRefuseAtomicallyAndBoundEstimate() throws {
        let source = planningSource(); var draft = ChildTaskPlanningDraft(original: source)
        XCTAssertThrowsError(try draft.plannedDay("2026-02-30")); XCTAssertThrowsError(try draft.clock("24:00"))
        XCTAssertThrowsError(try draft.zone("Not/AZone")); XCTAssertThrowsError(try draft.deadline("2026-02-30"))
        XCTAssertThrowsError(try draft.estimate(0)); XCTAssertThrowsError(try draft.estimate(10081))
        XCTAssertTrue(draft.changes.isEmpty)
        XCTAssertTrue(AuthoredValueComparison.exactJSON(.object(draft.value.fields), .object(source.fields)))
        try draft.estimate(1); XCTAssertEqual(draft.value.durationMinutes, 1)
        try draft.estimate(10080); XCTAssertEqual(draft.value.durationMinutes, 10080)
    }
    func testPlanningRequiresDateBeforeClockAndZone() throws {
        var draft = ChildTaskPlanningDraft(original: Record(["title": .string("Undated")]))
        XCTAssertThrowsError(try draft.clock("09:00")); XCTAssertThrowsError(try draft.zone("UTC"))
        XCTAssertTrue(draft.changes.isEmpty)
        try draft.plannedDay("2026-01-08"); try draft.clock("09:00"); try draft.zone("UTC")
        XCTAssertEqual(draft.value["scheduled_at"], .string("2026-01-08T09:00:00Z"))
    }
    func testPlanningKeepsChosenDSTFoldForUnrelatedEditsAndSameClock() throws {
        var source = planningSource(); source["due_date"] = .string("2026-11-01"); source["due_time"] = .string("01:30"); source["scheduled_at"] = .string("2026-11-01T06:30:00.000Z")
        var draft = ChildTaskPlanningDraft(original: source)
        try draft.clock("01:30"); try draft.estimate(60)
        XCTAssertEqual(draft.value["scheduled_at"], source["scheduled_at"])
        XCTAssertEqual(Set(draft.changes.keys), ["duration_minutes"])
    }
    @MainActor func testPlanningPrivateCheckpointAndRestoredIntentKeepOtherFields() throws {
        let source = planningSource(); var draft = ChildTaskPlanningDraft(original: source)
        try draft.estimate(120); try draft.deadline(nil)
        var titleDraft = source; titleDraft["title"] = .string("Private revised title")
        let value = draft.applying(to: titleDraft)
        let r = try read(), directory = try root()
        let vault = BackupVault(directory: directory, account: r.context.account, key: { SymmetricKey(data: Data(repeating: 17, count: 32)) })
        let session = TaskEditorSession(vault: vault, origin: r.context.origin, original: source, labels: [])
        session.capture(value, extras: [:]); XCTAssertTrue(session.flush())
        let restored = try vault.editorDraft(session.id, origin: r.context.origin)
        let reopened = ChildTaskPlanningDraft(original: source, restored: restored.draft)
        XCTAssertEqual(reopened.changes, draft.changes)
        XCTAssertEqual(restored.draft.title, "Private revised title")
        XCTAssertTrue(AuthoredValueComparison.exactJSON(restored.draft["future"], source["future"]))
        _ = session.finish()
    }
    func testPlanningIntentFormsIndependentCommandWithoutUneditedFields() throws {
        let r = try read(), source = Record(r.nodes["child"]!.fields)
        var draft = ChildTaskPlanningDraft(original: source)
        try draft.estimate(30); try draft.deadline("2026-12-12")
        let command = try ChildTaskFieldCommand(read: r, key: "child", changes: draft.changes)
        XCTAssertEqual(Set(command.body["changes"]!.object.keys), ["duration_minutes", "deadline_date"])
        XCTAssertEqual(command.body["node_key"], .string("child")); XCTAssertEqual(command.body["revision"], .number(r.nodes["child"]!.revision))
    }

    func testPlanningGapShowsResolvedWallMinuteAndPreservesDeadline() throws {
        var draft = ChildTaskPlanningDraft(original: planningSource())
        try draft.plannedDay("2026-03-08"); try draft.clock("02:30")
        XCTAssertEqual(draft.value["due_time"], .string("03:00"))
        XCTAssertEqual(draft.value["scheduled_at"], .string("2026-03-08T07:00:00Z"))
        XCTAssertEqual(draft.value["deadline_date"], .string("2026-01-15"))
    }

}

extension ChildTaskFieldCommandTests {
    func testChildLabelsOpeningDoesNotMaterializeAbsentOrNormalizeAuthoredValues() throws {
        for raw: JSON? in [nil, .null, .array([]), .array([.string("cafe\u{301}"), .string("future-label")])] {
            var source = Record(["future": .object(["keep": .bool(true)])]); source.fields["labels"] = raw
            let draft = ChildTaskLabelsDraft(original: source, kind: .personal)
            XCTAssertTrue(draft.changes.isEmpty)
            XCTAssertTrue(AuthoredValueComparison.exactJSON(.object(draft.applying(to: source).fields), .object(source.fields)))
        }
    }
    func testChildPersonalLabelsResolveOnlyAnExplicitUnambiguousName() throws {
        let id = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        let catalog = [Record(["id": .string(id), "name": .string("Work")])]
        var draft = ChildTaskLabelsDraft(original: Record(["labels": .array([.string("legacy")])]), kind: .personal)
        try draft.addName(" Work ", catalog: catalog)
        XCTAssertEqual(draft.value, .array([.string("legacy"), .string(id)]))
        XCTAssertEqual(draft.name(draft.entries[1], catalog: catalog), "Work")
        XCTAssertThrowsError(try draft.addName("Work", catalog: catalog))
        let before = draft.value
        XCTAssertThrowsError(try draft.addName("Work", catalog: catalog + [Record(["id": .string(other), "name": .string("Work")])]))
        XCTAssertTrue(AuthoredValueComparison.exactJSON(before, draft.value))
    }
    func testChildPersonalCatalogChoiceDoesNotRenormalizeOtherEntries() throws {
        let id = UUID().uuidString.lowercased()
        let source = Record(["labels": .array([.string("Legacy name"), .string("cafe\u{301}"), .string("future")])])
        let catalog = [Record(["id": .string(id), "name": .string("Work")])]
        var draft = ChildTaskLabelsDraft(original: source, kind: .personal)
        try draft.addCatalog(id, catalog: catalog)
        XCTAssertTrue(AuthoredValueComparison.exactJSON(draft.value, .array(source["labels"].list + [.string(id)])))
        XCTAssertThrowsError(try draft.addCatalog(UUID().uuidString, catalog: catalog))
        draft.remove(draft.entries.last!.id)
        XCTAssertTrue(draft.changes.isEmpty)
        var named = ChildTaskLabelsDraft(original: Record(["labels": .array([.string("Work")])]), kind: .personal)
        XCTAssertThrowsError(try named.addCatalog(id, catalog: catalog))
        XCTAssertTrue(named.changes.isEmpty)
    }
    func testChildSharedLabelsNeverResolveAgainstPersonalCatalog() throws {
        let id = UUID().uuidString.lowercased(), catalog = [Record(["id": .string(UUID().uuidString), "name": .string("Work")])]
        var draft = ChildTaskLabelsDraft(original: Record(), kind: .shared)
        try draft.addName("Work", catalog: catalog)
        XCTAssertEqual(draft.value, .array([.string("Work")]))
        XCTAssertThrowsError(try draft.addCatalog(id, catalog: [Record(["id": .string(id), "name": .string("Private")])]))
        XCTAssertThrowsError(try draft.addName(id, catalog: []))
    }
    func testChildLabelsUnsupportedAndCapacityFailuresKeepOriginal() throws {
        var future = ChildTaskLabelsDraft(original: Record(["labels": .object(["v": .number(2)])]), kind: .personal)
        XCTAssertFalse(future.supported); XCTAssertTrue(future.changes.isEmpty)
        XCTAssertThrowsError(try future.addName("New", catalog: [])); future.remove(0)
        XCTAssertEqual(future.value, .object(["v": .number(2)]))
        let rows = (0..<256).map { JSON.string("Saved \($0)") }
        var full = ChildTaskLabelsDraft(original: Record(["labels": .array(rows)]), kind: .personal)
        XCTAssertThrowsError(try full.addName("New", catalog: []))
        XCTAssertThrowsError(try full.addCatalog("catalog-id", catalog: [Record(["id": .string("catalog-id"), "name": .string("New")])]))
        XCTAssertEqual(full.value, .array(rows))
    }
    func testChildLabelChangesJoinPlanningWithoutLosingFieldsAndRestore() throws {
        let read = try read(), node = try XCTUnwrap(read.nodes["child"]), source = Record(node.fields)
        var labels = ChildTaskLabelsDraft(original: source, kind: .shared)
        try labels.addName("Review", catalog: [])
        var planning = ChildTaskPlanningDraft(original: source); try planning.estimate(45)
        let draft = labels.applying(to: planning.applying(to: source))
        let restored = ChildTaskLabelsDraft(original: source, restored: draft, kind: .shared)
        XCTAssertEqual(restored.changes, labels.changes)
        let command = try ChildTaskFieldCommand(read: read, key: "child", changes: labels.changes.merging(planning.changes) { _, b in b })
        XCTAssertEqual(Set(command.body["changes"]!.object.keys), ["labels", "duration_minutes"])
        XCTAssertEqual(draft["duration_minutes"], .number(45)); XCTAssertEqual(draft["title"], source["title"])
    }
}

extension ChildTaskFieldCommandTests {
    func testChildLabelsCanonicalReplacementIsAnExactAuthoredChange() throws {
        let source = Record(["labels": .array([.string("cafe\u{301}")])])
        var draft = ChildTaskLabelsDraft(original: source, kind: .shared)
        draft.remove(0); try draft.addName("café", catalog: [])
        XCTAssertFalse(draft.changes.isEmpty)
        XCTAssertTrue(AuthoredValueComparison.exactJSON(draft.value, .array([.string("café")])))
        XCTAssertFalse(AuthoredValueComparison.exactJSON(draft.value, source["labels"]))
    }
}

extension ChildTaskFieldCommandTests {
    func testChildAssignmentKeepsMissingNullAndLegacyWithoutAnEdit() throws {
        for raw: JSON? in [nil, .null, .string("legacy-person"), .object(["future": .bool(true)])] {
            var row = Record(["title": .string("Keep")]); row.fields["assigned_to"] = raw
            let draft = ChildTaskAssignmentDraft(original: row)
            XCTAssertTrue(draft.changes.isEmpty)
            XCTAssertTrue(AuthoredValueComparison.exactJSON(.object(draft.applying(to: row).fields), .object(row.fields)))
        }
    }
    func testChildAssignmentOnlyChangesChosenIdentityAndRestoresPrivateDraft() throws {
        let source = Record(["title": .string("Keep"), "future": .array([.string("opaque")])]), actor = UUID().uuidString.lowercased()
        var draft = ChildTaskAssignmentDraft(original: source); try draft.choose(actor)
        XCTAssertEqual(draft.changes, ["assigned_to": .string(actor)])
        let restored = ChildTaskAssignmentDraft(original: source, restored: draft.applying(to: source))
        XCTAssertEqual(restored.changes, draft.changes); XCTAssertEqual(restored.value["future"], source["future"])
        XCTAssertThrowsError(try draft.choose("not-an-id")); XCTAssertEqual(draft.selected, actor)
        try draft.choose(nil); XCTAssertTrue(draft.changes.isEmpty)
    }
    func testChildAssignmentClearIsAnExplicitCommandAndKeepsOtherFields() throws {
        let read = try read(); var source = Record(read.nodes["child"]!.fields); source["assigned_to"] = .string(UUID().uuidString.lowercased())
        var draft = ChildTaskAssignmentDraft(original: source); try draft.choose(nil)
        XCTAssertEqual(draft.changes, ["assigned_to": .null]); XCTAssertEqual(draft.applying(to: source)["title"], source["title"])
        let command = try ChildTaskFieldCommand(read: read, key: "child", changes: draft.changes)
        XCTAssertEqual(command.body["changes"], .object(["assigned_to": .null]))
    }
    @MainActor func testPersonalChildRecipientSelfAndClearNeverReadDirectory() async throws {
        let actor = UUID().uuidString.lowercased(); var calls = 0, selected: [String?] = []
        let picker = ChildTaskPersonalRecipientPicker(account: actor, current: { true }, read: { calls += 1; throw URLError(.notConnectedToInternet) }, apply: { selected.append($0); return nil })
        let selfChosen = await picker.choose(actor), cleared = await picker.choose(nil)
        XCTAssertTrue(selfChosen); XCTAssertTrue(cleared); XCTAssertEqual(calls, 0); XCTAssertEqual(selected.count, 2); XCTAssertEqual(selected[0], actor); XCTAssertNil(selected[1])
    }
    @MainActor func testPersonalChildRecipientRechecksAndRejectsRemovedPerson() async throws {
        let actor = UUID().uuidString.lowercased(), person = UUID().uuidString.lowercased(); var calls = 0, applied = false
        let picker = ChildTaskPersonalRecipientPicker(account: actor, current: { true }, read: {
            calls += 1; return calls == 1 ? [Record(["id": .string(person), "display_name": .string("Editor")])] : []
        }, apply: { _ in applied = true; return nil })
        await picker.refresh(); let chosen = await picker.choose(person)
        XCTAssertFalse(chosen); XCTAssertFalse(applied); XCTAssertEqual(calls, 2); XCTAssertTrue(picker.people.isEmpty); XCTAssertNotNil(picker.message)
    }
    @MainActor func testPersonalChildRecipientLateDirectoryCannotApplyOrExposeNames() async throws {
        let actor = UUID().uuidString.lowercased(), person = UUID().uuidString.lowercased(); var current = true, applied = false
        let picker = ChildTaskPersonalRecipientPicker(account: actor, current: { current }, read: { current = false; return [Record(["id": .string(person), "display_name": .string("Private name")])] }, apply: { _ in applied = true; return nil })
        await picker.refresh(); let chosen = await picker.choose(person)
        XCTAssertTrue(picker.people.isEmpty); XCTAssertFalse(chosen); XCTAssertFalse(applied)
    }
    @MainActor func testPersonalChildRecipientOfflineRetainsOnlyReviewedChoice() async throws {
        let actor = UUID().uuidString.lowercased(), person = UUID().uuidString.lowercased(); var calls = 0, selected: String?
        let picker = ChildTaskPersonalRecipientPicker(account: actor, current: { true }, read: {
            calls += 1; if calls > 1 { throw URLError(.networkConnectionLost) }; return [Record(["id": .string(person), "display_name": .string("Reviewed")])]
        }, apply: { selected = $0; return nil })
        await picker.refresh(); let chosen = await picker.choose(person)
        XCTAssertTrue(chosen); XCTAssertEqual(selected, person)
        let invented = await picker.choose(UUID().uuidString.lowercased()); XCTAssertFalse(invented); XCTAssertEqual(calls, 2)
    }
    @MainActor func testPersonalChildRecipientInvalidOrFailedDirectoryClearsNames() async throws {
        let actor = UUID().uuidString.lowercased(), person = UUID().uuidString.lowercased(); var bad = false
        let picker = ChildTaskPersonalRecipientPicker(account: actor, current: { true }, read: {
            let row = Record(["id": .string(person), "display_name": .string("Name")]); return bad ? [row, row] : [row]
        }, apply: { _ in XCTFail("Invalid directory must not apply"); return nil })
        await picker.refresh(); XCTAssertEqual(picker.people.count, 1); bad = true; await picker.refresh()
        XCTAssertTrue(picker.people.isEmpty); XCTAssertNotNil(picker.message)
    }
}

extension ChildTaskFieldCommandTests {
    @MainActor func testPersonalChildSelfChoiceInvalidatesAnInFlightDirectory() async throws {
        let actor = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        var reply: CheckedContinuation<[Record], Error>?, applied: [String?] = []
        let picker = ChildTaskPersonalRecipientPicker(account: actor, current: { true }, read: {
            try await withCheckedThrowingContinuation { reply = $0 }
        }, apply: { applied.append($0); return nil })
        let refresh = Task { await picker.refresh() }
        for _ in 0..<100 where reply == nil { await Task.yield() }
        let pending = try XCTUnwrap(reply)
        XCTAssertTrue(picker.busy)
        let chosen = await picker.choose(actor); XCTAssertTrue(chosen)
        pending.resume(returning: [Record(["id": .string(other), "display_name": .string("Old directory")])])
        await refresh.value
        XCTAssertEqual(applied.count, 1); XCTAssertEqual(applied[0], actor)
        XCTAssertTrue(picker.people.isEmpty); XCTAssertFalse(picker.busy)
    }
    @MainActor func testPersonalChildLateSelectionCannotApplyToNewEditorScope() async throws {
        let actor = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        var calls = 0, current = true, applied = false
        let picker = ChildTaskPersonalRecipientPicker(account: actor, current: { current }, read: {
            calls += 1; if calls == 2 { current = false }
            return [Record(["id": .string(other), "display_name": .string("Old scope")])]
        }, apply: { _ in applied = true; return nil })
        await picker.refresh(); let chosen = await picker.choose(other)
        XCTAssertFalse(chosen); XCTAssertFalse(applied); XCTAssertTrue(picker.people.isEmpty); XCTAssertNil(picker.message)
    }
}
