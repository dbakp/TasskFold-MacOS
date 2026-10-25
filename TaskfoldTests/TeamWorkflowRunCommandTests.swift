import XCTest
import CryptoKit
@testable import TaskfoldCore

private let runKey = SymmetricKey(size: .bits256)
private func workflowReceipt(_ c: TeamWorkflowRunCommand, replay: Bool = false) -> [String: JSON] {
    ["run_protocol": .number(1), "account": .string(c.account), "team_id": .string(c.team), "request_id": .string(c.id),
     "projects": .array(c.body["projects"]!.list.map { $0.object["id"]! }), "sections": .array(c.body["sections"]!.list.map { $0.object["id"]! }),
     "tasks": .array(c.body["tasks"]!.list.map { .object(["id": $0.object["id"]!, "generation": $0.object["task_generation"]!, "project_id": $0.object["project_id"]!]) }), "replayed": .bool(replay)]
}
@MainActor private final class WorkflowPeer: TeamWorkflowRunService {
    var calls: [TeamWorkflowRunCommand] = [], applied: [String: TeamWorkflowRunReceipt] = [:]
    var lose = false, foreign = false, hold = false
    var continuation: CheckedContinuation<Void, Never>?
    func workflowRun(_ c: TeamWorkflowRunCommand) async throws -> TeamWorkflowRunReceipt {
        calls.append(c); let replay = applied[c.id] != nil
        let result = TeamWorkflowRunReceipt(raw: workflowReceipt(c, replay: replay)); applied[c.id] = result
        if hold { await withCheckedContinuation { continuation = $0 } }
        if lose { lose = false; throw URLError(.networkConnectionLost) }
        var raw = result.raw
        if foreign { raw["tasks"] = .array([]) }
        return .init(raw: raw)
    }
}
private final class WorkflowFaultIO: CalendarSecureItemIO, @unchecked Sendable {
    let base: TeamWorkflowRunFileIO
    private let lock = NSLock(); private var failing = false
    init(_ base: TeamWorkflowRunFileIO) { self.base = base }
    func failRemove(_ value: Bool) { lock.lock(); failing = value; lock.unlock() }
    func read(key: String) throws -> Data? { try base.read(key: key) }
    func write(_ data: Data, key: String) throws { try base.write(data, key: key) }
    func remove(key: String) throws { lock.lock(); let fail = failing; lock.unlock(); if fail { throw URLError(.cannotRemoveFile) }; try base.remove(key: key) }
}
private final class WorkflowHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, WorkflowHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func finish(_ raw: [String: JSON], length: Int? = nil, status: Int = 200) {
        var headers = ["Content-Type": "application/json"]; if let length { headers["Content-Length"] = String(length) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(raw)); client?.urlProtocolDidFinishLoading(self)
    }
}
final class TeamWorkflowRunCommandTests: XCTestCase {
    func command() throws -> TeamWorkflowRunCommand {
        let plan = try TeamWorkflowRunTests().plan()
        return try .init(plan: plan, baseOrders: Dictionary(uniqueKeysWithValues: plan.orders.map { ("group:" + $0.project + ":" + ($0.section ?? "none"), []) }))
    }
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-workflow-client-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func io(_ root: URL, command: TeamWorkflowRunCommand) -> TeamWorkflowRunFileIO { .init(directory: root.appendingPathComponent("requests"), account: command.account, origin: command.origin, encryptionKey: { runKey }) }
    func vault(_ io: any CalendarSecureItemIO, root: URL) -> TeamWorkflowRunVault { .init(io: io, coordinationDirectory: root.appendingPathComponent("locks"), removalDirectory: root) }
    func key(_ c: TeamWorkflowRunCommand) -> String { TeamWorkflowRunCommand.storagePrefix + c.account + "." + CalendarOAuthConfiguration.digest(c.origin) }
    func testCompleteFrozenCommandRoundTripAndReceiptScope() throws {
        let c = try command(); XCTAssertEqual(try JSONDecoder().decode(TeamWorkflowRunCommand.self, from: JSONEncoder().encode(c)), c)
        XCTAssertEqual(try c.confirmed(workflowReceipt(c)).raw["replayed"], .bool(false)); XCTAssertEqual(try c.confirmed(workflowReceipt(c, replay: true)).raw["replayed"], .bool(true))
        for (field, value) in [("account", JSON.string(c.team)), ("team_id", .string(c.account)), ("request_id", .string(UUID().uuidString.lowercased())), ("projects", .array([])), ("sections", .array([])), ("tasks", .array([])), ("run_protocol", .number(2)), ("replayed", .string("yes"))] {
            var raw = workflowReceipt(c); raw[field] = value; XCTAssertThrowsError(try c.confirmed(raw), field)
        }
        var raw = workflowReceipt(c); var tasks = raw["tasks"]!.list; var task = tasks[0].object; task["generation"] = .string(UUID().uuidString.lowercased()); tasks[0] = .object(task); raw["tasks"] = .array(tasks); XCTAssertThrowsError(try c.confirmed(raw))
        XCTAssertFalse(String(reflecting: c).contains("Design review"))
    }
    func testMalformedRecoveryCannotPreparePartialOrForeignWork() throws {
        let c = try command()
        var variants: [[String: JSON]] = []
        var b = c.body; b["tasks"] = .array([]); variants.append(b)
        b = c.body; b["orders"] = .array([]); variants.append(b)
        b = c.body; b["extra"] = .bool(true); variants.append(b)
        b = c.body; var rows = b["projects"]!.list; var row = rows[0].object; row.removeValue(forKey: "parent_id"); rows[0] = .object(row); b["projects"] = .array(rows); variants.append(b)
        b = c.body; var tasks = b["tasks"]!.list; var task = tasks[0].object; task["user_id"] = .string(c.team); tasks[0] = .object(task); b["tasks"] = .array(tasks); variants.append(b)
        b = c.body; task["user_id"] = .string(c.account); task["title"] = .string(""); tasks[0] = .object(task); b["tasks"] = .array(tasks); variants.append(b)
        for body in variants { XCTAssertThrowsError(try TeamWorkflowRunCommand(account: c.account, origin: c.origin, body: body)) }
    }
    func testEncryptedRelaunchAndNamespaceAuthentication() async throws {
        let c = try command(), root = try root(), io = io(root, command: c), store = vault(io, root: root)
        try await store.begin(c, lease: CalendarReadLease()); let bytes = try Data(contentsOf: io.file)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("Design review"))
        let recovered = try await vault(io, root: root).pending(account: c.account, origin: c.origin); XCTAssertEqual(recovered, c)
        let legacy = TeamTemplateCommandFileIO(directory: io.directory, account: c.account, origin: c.origin, encryptionKey: { runKey })
        try bytes.write(to: legacy.file)
        let legacyKey = TeamTemplateCommand.storagePrefix + c.account + "." + CalendarOAuthConfiguration.digest(c.origin)
        XCTAssertThrowsError(try legacy.read(key: legacyKey))
        let other = TeamWorkflowRunFileIO(directory: io.directory, account: c.account, origin: "https://other.example", encryptionKey: { runKey })
        XCTAssertThrowsError(try other.read(key: TeamWorkflowRunCommand.storagePrefix + c.account + "." + CalendarOAuthConfiguration.digest("https://other.example")))
        let mode = try FileManager.default.attributesOfItem(atPath: io.file.path)[.posixPermissions] as? NSNumber; XCTAssertEqual(mode?.intValue, 0o600)
    }
    func testExistingTemplateCiphertextKeepsOriginalAADAndFileName() throws {
        let c = try command(), root = try root(), legacy = TeamTemplateCommandFileIO(directory: root, account: c.account, origin: c.origin, encryptionKey: { runKey })
        let k = TeamTemplateCommand.storagePrefix + c.account + "." + CalendarOAuthConfiguration.digest(c.origin), plain = Data("Existing template request".utf8)
        let box = try AES.GCM.seal(plain, using: runKey, authenticating: Data(("com.taskfold.team-template-request.v1|" + k).utf8))
        XCTAssertEqual(legacy.file.lastPathComponent, "request.taskfoldteamtemplate"); try XCTUnwrap(box.combined).write(to: legacy.file)
        XCTAssertEqual(try legacy.read(key: k), plain)
    }
    @MainActor func testLostReplyAndRelaunchRetainExactOriginalRun() async throws {
        let c = try command(), root = try root(), io = io(root, command: c), peer = WorkflowPeer(); peer.lose = true
        let first = TeamWorkflowRunModel(account: c.account, origin: c.origin, vault: vault(io, root: root), service: peer, current: { true })
        await first.send(c, canAuthor: { true }); XCTAssertEqual(first.pending, c); XCTAssertNil(first.receipt); first.close()
        let next = TeamWorkflowRunModel(account: c.account, origin: c.origin, vault: vault(io, root: root), service: peer, current: { true })
        await next.load(); XCTAssertEqual(next.pending, c); await next.retry(c)
        XCTAssertEqual(peer.calls, [c, c]); XCTAssertEqual(peer.applied.count, 1); XCTAssertNil(next.pending); XCTAssertNotNil(next.receipt)
        XCTAssertEqual(next.success, "Original workflow confirmed. Its tasks may have changed since then.")
    }
    @MainActor func testWrongReceiptAndFailedDiskClearKeepRecovery() async throws {
        for foreign in [false, true] {
            let c = try command(), root = try root(), io = WorkflowFaultIO(io(root, command: c)), peer = WorkflowPeer(); io.failRemove(!foreign); peer.foreign = foreign
            let model = TeamWorkflowRunModel(account: c.account, origin: c.origin, vault: vault(io, root: root), service: peer, current: { true })
            await model.send(c, canAuthor: { true }); XCTAssertEqual(model.pending, c); XCTAssertNil(model.receipt)
            peer.foreign = false; io.failRemove(false); await model.retry(c); XCTAssertNil(model.pending); XCTAssertNotNil(model.receipt); XCTAssertEqual(peer.applied.count, 1)
        }
    }
    @MainActor func testLateReplyAfterAccountOrWindowChangeCannotClearSavedRequest() async throws {
        for closing in [false, true] {
            let c = try command(), root = try root(), io = io(root, command: c), peer = WorkflowPeer(); peer.hold = true; var current = true
            let model = TeamWorkflowRunModel(account: c.account, origin: c.origin, vault: vault(io, root: root), service: peer, current: { current })
            let work = Task { await model.send(c, canAuthor: { true }) }; while peer.continuation == nil { await Task.yield() }
            if closing { model.close() } else { current = false }; peer.continuation?.resume(); await work.value
            XCTAssertNil(model.pending); XCTAssertNil(model.receipt); let saved = try await vault(io, root: root).pending(account: c.account, origin: c.origin); XCTAssertEqual(saved, c)
        }
    }
    @MainActor func testOtherWindowAndStoppedRetryCannotChangeAppliedWork() async throws {
        let c = try command(), other = try command(), root = try root(), io = io(root, command: c), peer = WorkflowPeer(), store = vault(io, root: root)
        try await store.begin(c, lease: CalendarReadLease())
        let model = TeamWorkflowRunModel(account: c.account, origin: c.origin, vault: store, service: peer, current: { true }); await model.load()
        try await store.clear(c, lease: CalendarReadLease()); try await store.begin(other, lease: CalendarReadLease())
        await model.retry(c); await model.stopRetrying(c); XCTAssertTrue(peer.calls.isEmpty)
        let saved = try await store.pending(account: c.account, origin: c.origin); XCTAssertEqual(saved, other)
        peer.lose = true; await model.retry(other); await model.stopRetrying(other); XCTAssertEqual(peer.applied.count, 1); XCTAssertNil(model.pending)
    }
    func testRemovalFenceBlocksNewWritesAndCleanupNeedsNoKey() async throws {
        let c = try command(), root = try root(), io = io(root, command: c), store = vault(io, root: root)
        try await store.begin(c, lease: CalendarReadLease()); try AccountRemovalDisk(directory: root, account: c.account).removeCache()
        do { try await store.begin(c, lease: CalendarReadLease()); XCTFail("Removed account write") } catch {}
        let locked = TeamWorkflowRunFileIO(directory: io.directory, account: c.account, origin: c.origin, encryptionKey: { throw URLError(.userAuthenticationRequired) })
        try await vault(locked, root: root).removeAccount(c.account, origin: c.origin); XCTAssertFalse(FileManager.default.fileExists(atPath: io.file.path))
    }
    @MainActor func testActualHTTPIsPrivateBoundedAndUsesFrozenEnvelope() async throws {
        let c = try command(), config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WorkflowHTTP.self]
        let session = try JSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(c.account)\"}}".utf8))
        let api = Backend(configuration: ["URL": c.origin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        defer { WorkflowHTTP.handler = nil }
        WorkflowHTTP.handler = { request, peer in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_team_workflow_run"); XCTAssertEqual(request.httpMethod, "POST"); XCTAssertFalse(request.httpShouldHandleCookies); XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(contentsOf: bytes.prefix(n)) } }
            XCTAssertEqual(try! JSONDecoder().decode([String: JSON].self, from: data), ["_body": .object(c.body)])
            peer.finish(workflowReceipt(c))
        }
        let result = try await api.workflowRun(c)
        XCTAssertEqual(result.raw, workflowReceipt(c))
        WorkflowHTTP.handler = { _, peer in peer.finish(workflowReceipt(c), length: 1_000_001) }
        do { _ = try await api.workflowRun(c); XCTFail("Oversized response") } catch {}
        WorkflowHTTP.handler = { _, peer in peer.finish(["code": .string("28000"), "message": .string("Private session detail")], status: 403) }
        do { _ = try await api.workflowRun(c); XCTFail("Authorization required") } catch { XCTAssertTrue(error is AccountSessionAuthorizationRequired) }
        WorkflowHTTP.handler = { _, peer in peer.finish(["code": .string("PT409"), "message": .string("Private workflow detail")], status: 409) }
        do { _ = try await api.workflowRun(c); XCTFail("Conflict") } catch { XCTAssertEqual((error as? AppFailure)?.message, TeamWorkflowRunCommand.invalid.message) }
    }
    @MainActor func testAccessReviewRunsBeforeAndAfterDurableSave() async throws {
        for firstAllowed in [false, true] {
            let c = try command(), root = try root(), io = io(root, command: c), peer = WorkflowPeer(); var checks = 0
            let model = TeamWorkflowRunModel(account: c.account, origin: c.origin, vault: vault(io, root: root), service: peer, current: { true })
            await model.send(c, canAuthor: { checks += 1; return firstAllowed && checks == 1 })
            XCTAssertTrue(peer.calls.isEmpty)
            let saved = try await vault(io, root: root).pending(account: c.account, origin: c.origin); XCTAssertEqual(saved != nil, firstAllowed)
        }
    }
    @MainActor func testUnreadableRecoveryBlocksFreshSendWithoutOverwriting() async throws {
        let c = try command(), root = try root(), io = io(root, command: c), peer = WorkflowPeer()
        try io.write(Data("Broken saved envelope".utf8), key: key(c)); let before = try Data(contentsOf: io.file)
        let model = TeamWorkflowRunModel(account: c.account, origin: c.origin, vault: vault(io, root: root), service: peer, current: { true })
        await model.load(); await model.send(c, canAuthor: { true }); XCTAssertFalse(model.recoveryLoaded); XCTAssertTrue(peer.calls.isEmpty)
        XCTAssertEqual(try Data(contentsOf: io.file), before)
    }
    @MainActor func testActualHTTPReplyAfterSignOutIsRejected() async throws {
        let c = try command(), config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WorkflowHTTP.self]
        let session = try JSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(c.account)\"}}".utf8))
        let api = Backend(configuration: ["URL": c.origin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        var held: WorkflowHTTP?; WorkflowHTTP.handler = { _, peer in held = peer }; defer { WorkflowHTTP.handler = nil }
        let work = Task { try await api.workflowRun(c) }; while held == nil { await Task.yield() }
        try await api.clearSession(); held?.finish(workflowReceipt(c))
        do { _ = try await work.value; XCTFail("Late receipt") } catch { XCTAssertTrue(error is CancellationError) }
    }
}
