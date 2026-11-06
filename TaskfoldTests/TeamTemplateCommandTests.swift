import XCTest
import CryptoKit
import Darwin
@testable import TaskfoldCore

private let tcAccount = "ec260000-0000-4000-8000-000000000001", tcTeam = "ec260000-0000-4000-8000-000000000002", tcTemplate = "ec260000-0000-4000-8000-000000000003", tcOrigin = "https://templates.example"
private let tcKey = SymmetricKey(size: .bits256)
private var tcStorageKey: String { TeamTemplateCommand.storagePrefix + tcAccount + "." + CalendarOAuthConfiguration.digest(tcOrigin) }
private final class TemplateFaultIO: CalendarSecureItemIO, @unchecked Sendable {
    let base: TeamTemplateCommandFileIO
    private let lock = NSLock(); private var failing = false
    init(_ base: TeamTemplateCommandFileIO) { self.base = base }
    func failRemove(_ value: Bool) { lock.lock(); failing = value; lock.unlock() }
    func read(key: String) throws -> Data? { try base.read(key: key) }
    func write(_ data: Data, key: String) throws { try base.write(data, key: key) }
    func remove(key: String) throws { lock.lock(); let fail = failing; lock.unlock(); if fail { throw URLError(.cannotRemoveFile) }; try base.remove(key: key) }
}
@MainActor private final class TemplatePeer: TeamTemplateCommandService {
    var calls: [TeamTemplateCommand] = [], applied: [String: TeamTemplateReceipt] = [:]
    var lose = false, foreign = false, hold = false
    var continuation: CheckedContinuation<Void, Never>?
    func teamTemplateCommand(_ command: TeamTemplateCommand) async throws -> TeamTemplateReceipt {
        calls.append(command)
        let replay = applied[command.id] != nil
        var raw: [String: JSON] = ["library_protocol": .number(1), "account": .string(command.account), "team_id": .string(command.team), "request_id": .string(command.id), "operation": .string(command.action.rawValue), "template_id": .string(command.template), "revision": command.action == .publish ? .number(1) : .number(command.body["revision"]!.integer.double + (command.action == .replace ? 1 : 0)), "deleted": .bool(command.action == .delete), "replayed": .bool(replay)]
        if let old = applied[command.id] { raw = old.raw; raw["replayed"] = .bool(true) }
        else { applied[command.id] = TeamTemplateReceipt(raw: raw) }
        if hold { await withCheckedContinuation { continuation = $0 } }
        if lose { lose = false; throw URLError(.networkConnectionLost) }
        if foreign { raw["account"] = .string(tcTeam) }
        return TeamTemplateReceipt(raw: raw)
    }
}
private extension Int { var double: Double { Double(self) } }
private final class TemplateCommandHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, TemplateCommandHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func finish(_ raw: [String: JSON]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(raw)); client?.urlProtocolDidFinishLoading(self)
    }
}
final class TeamTemplateCommandTests: XCTestCase {
    func document(text: String = "Private template text") -> JSON { .object(["version": .number(1), "kind": .string("task"), "projects": .array([]), "sections": .array([]), "tasks": .array([.object(["id": .string("task"), "title": .string("Design review"), "description": .string(text), "labels": .array([]), "subtasks": .array([])])])]) }
    func command(_ action: TeamTemplateCommand.Action = .publish, revision: Double = 4, text: String = "Private template text") throws -> TeamTemplateCommand {
        try .init(account: tcAccount, origin: tcOrigin, action: action, team: tcTeam, template: tcTemplate, revision: action == .publish ? nil : revision, name: action == .delete ? nil : "Design review", document: action == .delete ? nil : document(text: text))
    }
    func receipt(_ command: TeamTemplateCommand, replay: Bool = false) -> [String: JSON] {
        let revision: Double = command.action == .publish ? 1 : (try! TeamTemplateLibraryValue.revision(command.body["revision"])) + (command.action == .replace ? 1 : 0)
        return ["library_protocol": .number(1), "account": .string(command.account), "team_id": .string(command.team), "request_id": .string(command.id), "operation": .string(command.action.rawValue), "template_id": .string(command.template), "revision": .number(revision), "deleted": .bool(command.action == .delete), "replayed": .bool(replay)]
    }
    func root() throws -> URL { let root = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-template-commands-" + UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root }
    func io(_ root: URL, account: String = tcAccount, origin: String = tcOrigin) -> TeamTemplateCommandFileIO { .init(directory: root.appendingPathComponent("requests"), account: account, origin: origin, encryptionKey: { tcKey }) }
    func vault(_ io: any CalendarSecureItemIO, root: URL) -> TeamTemplateCommandVault { .init(io: io, coordinationDirectory: root.appendingPathComponent("locks"), removalDirectory: root) }
    func testAllActionsRoundTripAndHaveExactReceiptSemantics() throws {
        for action in TeamTemplateCommand.Action.allCases {
            let c = try command(action), decoded = try JSONDecoder().decode(TeamTemplateCommand.self, from: JSONEncoder().encode(c)); XCTAssertEqual(c, decoded)
            XCTAssertEqual(try c.confirmed(receipt(c)).raw["deleted"], .bool(action == .delete))
            XCTAssertEqual(try c.confirmed(receipt(c, replay: true)).raw["replayed"], .bool(true))
            XCTAssertFalse(String(reflecting: c).contains("Design review"))
        }
        let max = try command(.delete, revision: 9_007_199_254_740_991); XCTAssertEqual(try max.confirmed(receipt(max)).raw["revision"], .number(9_007_199_254_740_991))
        XCTAssertThrowsError(try command(.replace, revision: 9_007_199_254_740_991))
    }
    func testExactActionFieldsRejectExtrasAndMissingReviewedInputs() throws {
        for action in TeamTemplateCommand.Action.allCases {
            let c = try command(action)
            for key in c.body.keys { var body = c.body; body.removeValue(forKey: key); XCTAssertThrowsError(try TeamTemplateCommand(account: tcAccount, origin: tcOrigin, action: action, body: body), key) }
            var body = c.body; body["extra"] = .bool(true); XCTAssertThrowsError(try TeamTemplateCommand(account: tcAccount, origin: tcOrigin, action: action, body: body))
        }
    }
    func testUnsupportedDefinitionCannotBePublishedOrReplaced() throws {
        for doc in [JSON.object(["version": .number(2), "future": .string("keep")]), .object(["version": .number(1), "kind": .string("task")])] {
            XCTAssertThrowsError(try TeamTemplateCommand(account: tcAccount, origin: tcOrigin, action: .publish, team: tcTeam, template: tcTemplate, name: "Review", document: doc))
        }
        XCTAssertThrowsError(try command(text: String(repeating: "a", count: 2_000_000)))
    }
    func testInvalidScopeNamesAndRevisionsCannotRecover() throws {
        let c = try command(.replace)
        for (key, value) in [("revision", JSON.number(0)), ("revision", .number(2.5)), ("name", .string(" padded ")), ("name", .string("bad\u{202e}name")), ("request_id", .string("../outside"))] {
            var b = c.body; b[key] = value; XCTAssertThrowsError(try TeamTemplateCommand(account: tcAccount, origin: tcOrigin, action: c.action, body: b))
        }
        var encoded = try JSONDecoder().decode([String: JSON].self, from: JSONEncoder().encode(c)); encoded["account"] = .string("bad"); XCTAssertThrowsError(try JSONDecoder().decode(TeamTemplateCommand.self, from: JSONEncoder().encode(encoded)))
    }
    func testReceiptCannotConfirmAnotherOperationIdentityOrRevision() throws {
        for action in TeamTemplateCommand.Action.allCases {
            let c = try command(action)
            for (key, value) in [("account", JSON.string(tcTeam)), ("team_id", .string(tcAccount)), ("request_id", .string(tcTemplate)), ("template_id", .string(tcTeam)), ("operation", .string("other")), ("revision", .number(99)), ("deleted", .bool(action != .delete)), ("replayed", .string("true")), ("library_protocol", .number(2))] {
                var raw = receipt(c); raw[key] = value; XCTAssertThrowsError(try c.confirmed(raw), key)
            }
            var raw = receipt(c); raw["document"] = document(); XCTAssertThrowsError(try c.confirmed(raw))
        }
    }
    func testEncryptedFileRelaunchRoundTripAndPrivatePermissions() async throws {
        let root = try root(), io = io(root), c = try command(), store = vault(io, root: root)
        try await store.begin(c, lease: CalendarReadLease())
        let encrypted = try Data(contentsOf: io.file); XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains("Private template text")); XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains(tcTeam))
        let next = vault(self.io(root), root: root), restored = try await next.pending(account: tcAccount, origin: tcOrigin); XCTAssertEqual(restored, c)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: io.file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: io.directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try io.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
    func testLargeDefinitionUsesFileBackedVaultBeyondKeychainCommandDefault() async throws {
        let root = try root(), io = io(root), c = try command(text: String(repeating: "x", count: 1_100_000)), store = vault(io, root: root)
        try await store.begin(c, lease: CalendarReadLease()); let restored = try await store.pending(account: tcAccount, origin: tcOrigin); XCTAssertEqual(restored, c)
        XCTAssertGreaterThan(try Data(contentsOf: io.file).count, 1_000_000)
    }
    func testCiphertextCannotBeReadUnderAnotherAccountOriginOrKey() throws {
        let root = try root(), io = io(root), data = Data("private request".utf8); try io.write(data, key: tcStorageKey)
        let account = self.io(root, account: tcTeam), origin = self.io(root, origin: "https://other.example")
        XCTAssertThrowsError(try account.read(key: TeamTemplateCommand.storagePrefix + tcTeam + "." + CalendarOAuthConfiguration.digest(tcOrigin)))
        XCTAssertThrowsError(try origin.read(key: TeamTemplateCommand.storagePrefix + tcAccount + "." + CalendarOAuthConfiguration.digest("https://other.example")))
        let wrong = TeamTemplateCommandFileIO(directory: io.directory, account: tcAccount, origin: tcOrigin, encryptionKey: { SymmetricKey(size: .bits256) }); XCTAssertThrowsError(try wrong.read(key: tcStorageKey))
        XCTAssertThrowsError(try io.write(data, key: "foreign")); XCTAssertEqual(try io.read(key: tcStorageKey), data)
    }
    func testCorruptionBlocksNewAuthoringWithoutOverwritingRecovery() async throws {
        let root = try root(), io = io(root); try io.write(Data("not an envelope".utf8), key: tcStorageKey)
        let before = try Data(contentsOf: io.file), store = vault(io, root: root)
        do { _ = try await store.pending(account: tcAccount, origin: tcOrigin); XCTFail("Corrupt journal") } catch {}
        do { try await store.begin(command(), lease: CalendarReadLease()); XCTFail("Overwritten") } catch {}
        XCTAssertEqual(try Data(contentsOf: io.file), before)
        var damaged = before; damaged[damaged.startIndex] ^= 1; try damaged.write(to: io.file); XCTAssertThrowsError(try io.read(key: tcStorageKey))
    }
    func testOversizedAndNonregularCiphertextAreRejectedBeforeDecryption() throws {
        let root = try root(), io = io(root); try io.write(Data("saved".utf8), key: tcStorageKey)
        let handle = try FileHandle(forWritingTo: io.file); try handle.truncate(atOffset: UInt64(TeamTemplateCommand.maximumStoredBytes + 1_025)); try handle.close(); XCTAssertThrowsError(try io.read(key: tcStorageKey))
        try FileManager.default.removeItem(at: io.file); XCTAssertEqual(mkfifo(io.file.path, 0o600), 0); XCTAssertThrowsError(try io.read(key: tcStorageKey))
        XCTAssertThrowsError(try io.write(Data(), key: tcStorageKey))
    }
    func testSymlinkFileAndDirectoryCannotRedirectReadsOrWrites() throws {
        let root = try root(), io = io(root), outside = root.appendingPathComponent("outside")
        try Data("preserve".utf8).write(to: outside); try FileManager.default.createDirectory(at: io.directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: io.file, withDestinationURL: outside)
        XCTAssertThrowsError(try io.read(key: tcStorageKey)); XCTAssertThrowsError(try io.write(Data("replace".utf8), key: tcStorageKey)); XCTAssertEqual(try Data(contentsOf: outside), Data("preserve".utf8))
        try io.remove(key: tcStorageKey); XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        try FileManager.default.removeItem(at: io.directory); try FileManager.default.createSymbolicLink(at: io.directory, withDestinationURL: root)
        XCTAssertThrowsError(try io.read(key: tcStorageKey)); XCTAssertThrowsError(try io.write(Data(), key: tcStorageKey)); XCTAssertThrowsError(try io.remove(key: tcStorageKey))
    }
    func testKeyFailurePreservesCiphertextAndCleanupDoesNotNeedTheKey() throws {
        let root = try root(), io = io(root); try io.write(Data("request".utf8), key: tcStorageKey); let before = try Data(contentsOf: io.file)
        let locked = TeamTemplateCommandFileIO(directory: io.directory, account: tcAccount, origin: tcOrigin, encryptionKey: { throw URLError(.userAuthenticationRequired) })
        XCTAssertThrowsError(try locked.read(key: tcStorageKey)); XCTAssertThrowsError(try locked.write(Data("replace".utf8), key: tcStorageKey)); XCTAssertEqual(try Data(contentsOf: io.file), before)
        try locked.remove(key: tcStorageKey); XCTAssertNil(try io.read(key: tcStorageKey))
    }
    func testTwoVaultsPreserveTheOriginalRequestAndConditionalClear() async throws {
        let root = try root(), io = io(root), first = vault(io, root: root), second = vault(io, root: root), c = try command(), other = try command()
        try await first.begin(c, lease: CalendarReadLease()); try await second.begin(c, lease: CalendarReadLease())
        do { try await second.begin(other, lease: CalendarReadLease()); XCTFail("Replaced") } catch {}
        do { try await second.clear(other, lease: CalendarReadLease()); XCTFail("Wrong clear") } catch {}
        let saved = try await first.pending(account: tcAccount, origin: tcOrigin); XCTAssertEqual(saved, c)
    }
    func testCancelledLeaseAndRemovedAccountCannotWriteOrRecreate() async throws {
        let root = try root(), io = io(root), store = vault(io, root: root), c = try command(), lease = CalendarReadLease(); lease.cancel()
        do { try await store.begin(c, lease: lease); XCTFail("Cancelled begin") } catch {}
        try await store.begin(c, lease: CalendarReadLease())
        do { try await store.clear(c, lease: lease); XCTFail("Cancelled clear") } catch {}
        try AccountRemovalDisk(directory: root, account: tcAccount).removeCache()
        do { _ = try await store.pending(account: tcAccount, origin: tcOrigin); XCTFail("Removed read") } catch {}
        do { try await store.begin(c, lease: CalendarReadLease()); XCTFail("Removed write") } catch {}
        try await store.removeAccount(tcAccount, origin: tcOrigin); XCTAssertNil(try io.read(key: tcStorageKey))
    }
    @MainActor func testLostReplyRelaunchRetriesExactOriginalCommandOnce() async throws {
        let root = try root(), io = io(root), peer = TemplatePeer(), c = try command(); peer.lose = true
        let model = TeamTemplateCommandModel(account: tcAccount, origin: tcOrigin, vault: vault(io, root: root), service: peer, current: { true })
        await model.send(c, canAuthor: { true }); XCTAssertEqual(model.pending, c); XCTAssertNil(model.receipt); model.close()
        let next = TeamTemplateCommandModel(account: tcAccount, origin: tcOrigin, vault: vault(self.io(root), root: root), service: peer, current: { true })
        await next.load(); XCTAssertEqual(next.pending, c); await next.retry(c)
        XCTAssertNil(next.pending); XCTAssertEqual(next.receipt?.raw["replayed"], .bool(true)); XCTAssertEqual(peer.calls, [c, c]); XCTAssertEqual(peer.applied.count, 1)
        XCTAssertEqual(next.success, "Original change confirmed. The library may have changed since then.")
    }
    @MainActor func testForeignReceiptAndFailedCleanupRetainExactRequest() async throws {
        for foreign in [false, true] {
            let root = try root(), fault = TemplateFaultIO(io(root)), peer = TemplatePeer(), c = try command(); peer.foreign = foreign; fault.failRemove(!foreign)
            let model = TeamTemplateCommandModel(account: tcAccount, origin: tcOrigin, vault: vault(fault, root: root), service: peer, current: { true })
            await model.send(c, canAuthor: { true }); XCTAssertEqual(model.pending, c); XCTAssertNil(model.receipt)
            let saved = try await vault(fault, root: root).pending(account: tcAccount, origin: tcOrigin); XCTAssertEqual(saved, c)
            peer.foreign = false; fault.failRemove(false); await model.retry(c); XCTAssertNotNil(model.receipt); XCTAssertNil(model.pending); XCTAssertEqual(peer.applied.count, 1)
        }
    }
    @MainActor func testClosingOrChangingAccountDuringReplyKeepsDiskButClearsPresentation() async throws {
        for close in [true, false] {
            let root = try root(), io = io(root), peer = TemplatePeer(), c = try command(); peer.hold = true; var current = true
            let model = TeamTemplateCommandModel(account: tcAccount, origin: tcOrigin, vault: vault(io, root: root), service: peer, current: { current })
            let work = Task { await model.send(c, canAuthor: { true }) }
            while peer.continuation == nil { await Task.yield() }
            if close { model.close() } else { current = false }
            peer.continuation?.resume(); await work.value; XCTAssertNil(model.pending); XCTAssertNil(model.receipt); XCTAssertFalse(model.recoveryLoaded)
            let saved = try await vault(io, root: root).pending(account: tcAccount, origin: tcOrigin); XCTAssertEqual(saved, c)
        }
    }
    @MainActor func testUnreadableRecoveryBlocksFreshRequests() async throws {
        let root = try root(), io = io(root), peer = TemplatePeer(); try io.write(Data("broken envelope".utf8), key: tcStorageKey)
        let model = TeamTemplateCommandModel(account: tcAccount, origin: tcOrigin, vault: vault(io, root: root), service: peer, current: { true })
        await model.load(); XCTAssertFalse(model.recoveryLoaded); await model.send(try command(), canAuthor: { true }); XCTAssertTrue(peer.calls.isEmpty)
    }
    @MainActor func testAccessReviewCheckedBeforeAndAfterDurableSave() async throws {
        for invalidateDuringSave in [false, true] {
            let root = try root(), io = io(root), peer = TemplatePeer(); var checks = 0
            let model = TeamTemplateCommandModel(account: tcAccount, origin: tcOrigin, vault: vault(io, root: root), service: peer, current: { true })
            await model.send(try command(), canAuthor: { checks += 1; return invalidateDuringSave && checks == 1 })
            XCTAssertTrue(peer.calls.isEmpty)
            let saved = try await vault(io, root: root).pending(account: tcAccount, origin: tcOrigin); XCTAssertEqual(saved != nil, invalidateDuringSave)
        }
    }
    @MainActor func testChangedRequestInAnotherWindowCannotBeRetriedOrDropped() async throws {
        let root = try root(), io = io(root), store = vault(io, root: root), peer = TemplatePeer(), c = try command(), other = try command(.replace)
        try await store.begin(c, lease: CalendarReadLease())
        let model = TeamTemplateCommandModel(account: tcAccount, origin: tcOrigin, vault: store, service: peer, current: { true }); await model.load()
        try await store.clear(c, lease: CalendarReadLease()); try await store.begin(other, lease: CalendarReadLease())
        await model.retry(c); XCTAssertTrue(peer.calls.isEmpty); XCTAssertEqual(model.pending, other)
        await model.stopRetrying(c); let saved = try await store.pending(account: tcAccount, origin: tcOrigin); XCTAssertEqual(saved, other)
    }
    @MainActor func testStopRetryingLeavesAlreadyAppliedServerWorkAlone() async throws {
        let root = try root(), io = io(root), peer = TemplatePeer(), c = try command(); peer.lose = true
        let model = TeamTemplateCommandModel(account: tcAccount, origin: tcOrigin, vault: vault(io, root: root), service: peer, current: { true })
        await model.send(c, canAuthor: { true }); await model.stopRetrying(c); XCTAssertNil(model.pending); XCTAssertEqual(peer.calls, [c]); XCTAssertEqual(peer.applied.count, 1)
    }
    @MainActor func testActualHTTPCommandContractAndReceiptVerification() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TemplateCommandHTTP.self]
        let session = try JSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(tcAccount)\"}}".utf8))
        let api = Backend(configuration: ["URL": tcOrigin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        defer { TemplateCommandHTTP.handler = nil }
        for action in TeamTemplateCommand.Action.allCases {
            let c = try command(action)
            TemplateCommandHTTP.handler = { request, peer in
                XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_team_templates"); XCTAssertEqual(request.httpMethod, "POST"); XCTAssertFalse(request.httpShouldHandleCookies)
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(contentsOf: bytes.prefix(n)) } }
                let body = try! JSONDecoder().decode([String: JSON].self, from: data); XCTAssertEqual(body, ["_operation": .string(action.rawValue), "_body": .object(c.body)]); peer.finish(self.receipt(c))
            }
            let result = try await api.teamTemplateCommand(c); XCTAssertEqual(result.raw, receipt(c))
        }
    }
}
