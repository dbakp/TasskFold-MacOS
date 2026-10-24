import XCTest
@testable import TaskfoldCore

private let cmAccount = "ea310000-0000-4000-8000-000000000001", cmOther = "ea310000-0000-4000-8000-000000000002", cmTeam = "ea310000-0000-4000-8000-000000000003", cmFolder = "ea310000-0000-4000-8000-000000000004"
private let cmOrigin = "https://backend.example"
private final class CommandMemory: CalendarSecureItemIO, @unchecked Sendable {
    private let lock = NSLock()
    var values: [String: Data] = [:]
    var failWrite = false, failRemove = false
    func read(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func write(_ data: Data, key: String) throws { lock.lock(); defer { lock.unlock() }; if failWrite { throw URLError(.cannotWriteToFile) }; values[key] = data }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; if failRemove { throw URLError(.cannotRemoveFile) }; values.removeValue(forKey: key) }
}
@MainActor private final class CommandPeer: TeamOrganizationCommandService {
    var calls: [TeamOrganizationCommand] = []
    var applied: [String: TeamOrganizationCommandReceipt] = [:]
    var loseReply = false, failAuth = false, foreignResult = false
    var wait = false
    var continuation: CheckedContinuation<Void, Never>?
    func teamOrganizationCommand(_ command: TeamOrganizationCommand) async throws -> TeamOrganizationCommandReceipt {
        calls.append(command)
        if failAuth { throw AccountSessionAuthorizationRequired() }
        if wait { await withCheckedContinuation { continuation = $0 } }
        let value = TeamOrganizationCommandReceipt(team: foreignResult ? cmOther : command.team, revision: command.action == .create ? 1 : Double(command.body["revision"]!.integer + 1), folder: command.action == .folderCreate ? cmFolder : nil)
        let result = applied[command.id] ?? value; applied[command.id] = result
        if loseReply { loseReply = false; throw URLError(.networkConnectionLost) }
        return result
    }
}
private final class CommandHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, CommandHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func finish(_ raw: [String: JSON], status: Int = 200) {
        let data = try! JSONEncoder().encode(raw)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
final class TeamOrganizationCommandTests: XCTestCase {
    func command(_ action: TeamOrganizationCommand.Action = .create, now: Date = Date()) throws -> TeamOrganizationCommand {
        try .init(account: cmAccount, origin: cmOrigin, action: action, team: cmTeam, revision: action == .create ? nil : 3, name: action.needsName ? "  Design studio  " : nil, folder: action.needsFolder ? cmFolder : nil, now: now)
    }
    func reply(_ command: TeamOrganizationCommand) -> [String: JSON] {
        var raw: [String: JSON] = ["id": .string(command.team), "revision": .number(command.action == .create ? 1 : 4), "state": .string(command.action == .archive ? "archived" : "active")]
        if command.action == .folderCreate { raw["folder_id"] = .string(cmFolder) }; return raw
    }
    func testAllActionsHaveExactBodiesAndRoundTripWithoutChangingRequestIdentity() throws {
        for action in TeamOrganizationCommand.Action.allCases {
            let command = try command(action)
            let roundTrip = try JSONDecoder().decode(TeamOrganizationCommand.self, from: JSONEncoder().encode(command))
            XCTAssertEqual(roundTrip, command); XCTAssertEqual(roundTrip.body, command.body)
            XCTAssertEqual(command.name, action.needsName ? "Design studio" : nil)
            XCTAssertEqual(try command.confirmed(reply(command)).team, cmTeam)
            XCTAssertFalse(String(reflecting: command).contains("Design studio"))
        }
    }
    func testInvalidFieldsNamesAndRevisionsCannotBecomeCommands() throws {
        let command = try command()
        for change in [["revision": JSON.number(1)], ["name": .string("")], ["name": .string(" padded ")], ["name": .string("bad\nname")], ["name": .string(String(repeating: "a", count: 101))], ["request_id": .string("00000000-0000-0000-0000-000000000000")], ["issued_at": .string("2030-01-01T00:00:00+00:00")], ["role": .string("owner")]] {
            XCTAssertThrowsError(try TeamOrganizationCommand(account: cmAccount, origin: cmOrigin, action: .create, body: command.body.merging(change) { _, b in b }))
        }
        for revision in [0, -1, 1.5, 9_007_199_254_740_991, Double.infinity] {
            XCTAssertThrowsError(try TeamOrganizationCommand(account: cmAccount, origin: cmOrigin, action: .rename, team: cmTeam, revision: revision, name: "Name"))
        }
        XCTAssertThrowsError(try TeamOrganizationCommand(account: cmAccount, origin: cmOrigin, action: .folderRename, team: cmTeam, revision: 1, name: "Folder"))
        XCTAssertThrowsError(try TeamOrganizationCommand(account: cmAccount, origin: cmOrigin, action: .archive, team: cmTeam, revision: 1, name: "Extra"))
    }
    func testReceiptsRejectForeignTeamStateRevisionAndMissingFolder() throws {
        for action in TeamOrganizationCommand.Action.allCases {
            let command = try command(action), expected = reply(command)
            for change in [["id": JSON.string(cmOther)], ["revision": .number(2)], ["state": .string("deleted")]] { XCTAssertThrowsError(try command.confirmed(expected.merging(change) { _, b in b })) }
            if action == .folderCreate { var missing = expected; missing.removeValue(forKey: "folder_id"); XCTAssertThrowsError(try command.confirmed(missing)) }
        }
    }
    func testExpiredCommandCannotBeRenewedByDecodeOrRetry() throws {
        let time = Date(), command = try command(now: time)
        XCTAssertTrue(command.retryable(at: time.addingTimeInterval(899)))
        XCTAssertFalse(command.retryable(at: time.addingTimeInterval(901)))
        XCTAssertFalse(command.retryable(at: time.addingTimeInterval(-61)))
        let decoded = try JSONDecoder().decode(TeamOrganizationCommand.self, from: JSONEncoder().encode(command))
        XCTAssertEqual(decoded.body["issued_at"], command.body["issued_at"])
    }
    func testVaultRefusesReplacementWrongOriginAndStaleAcknowledgement() async throws {
        let io = CommandMemory(), vault = TeamOrganizationCommandVault(io: io), first = try command(), second = try command(.rename)
        try await vault.begin(first, lease: CalendarReadLease())
        do { try await vault.begin(second, lease: CalendarReadLease()); XCTFail("Replaced pending request") } catch {}
        let foreignOrigin = try await vault.pending(account: cmAccount, origin: "https://other.example"); XCTAssertNil(foreignOrigin)
        let other = try await vault.pending(account: cmOther, origin: cmOrigin); XCTAssertNil(other)
        try await vault.clear(first, lease: CalendarReadLease()); try await vault.begin(second, lease: CalendarReadLease())
        do { try await vault.clear(first, lease: CalendarReadLease()); XCTFail("Stale ack cleared newer request") } catch {}
        let saved = try await vault.pending(account: cmAccount, origin: cmOrigin); XCTAssertEqual(saved, second)
    }
    func testTwoWindowsCannotReplaceEachOthersPendingCommand() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let io = CommandMemory(), first = try command(), second = try command(.rename)
        let one = TeamOrganizationCommandVault(io: io, coordinationDirectory: root), two = TeamOrganizationCommandVault(io: io, coordinationDirectory: root)
        let left = Task.detached { do { try await one.begin(first, lease: CalendarReadLease()); return true } catch { return false } }
        let right = Task.detached { do { try await two.begin(second, lease: CalendarReadLease()); return true } catch { return false } }
        let results = await [left.value, right.value]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let saved = try await one.pending(account: cmAccount, origin: cmOrigin); XCTAssertTrue(saved == first || saved == second)
    }
    func testDifferentServerCleanupCannotEraseOriginalRequest() async throws {
        let io = CommandMemory(), vault = TeamOrganizationCommandVault(io: io), command = try command()
        try await vault.begin(command, lease: CalendarReadLease())
        try await vault.removeAccount(cmAccount, origin: "https://other.example")
        let saved = try await vault.pending(account: cmAccount, origin: cmOrigin); XCTAssertEqual(saved, command)
    }
    func testCorruptRecoveryIsKeptAndAccountRemovalStillErasesIt() async throws {
        let io = CommandMemory(); io.values["team-command-v1." + cmAccount + "." + CalendarOAuthConfiguration.digest(cmOrigin)] = Data("broken".utf8)
        let vault = TeamOrganizationCommandVault(io: io)
        do { _ = try await vault.pending(account: cmAccount, origin: cmOrigin); XCTFail("Corrupt recovery ignored") } catch {}
        do { try await vault.begin(command(), lease: CalendarReadLease()); XCTFail("Overwrote corrupt recovery") } catch {}
        XCTAssertEqual(io.values["team-command-v1." + cmAccount + "." + CalendarOAuthConfiguration.digest(cmOrigin)], Data("broken".utf8))
        try await vault.removeAccount(cmAccount, origin: cmOrigin); XCTAssertTrue(io.values.isEmpty)
    }
    func testRemovalFencePreventsLateRecoveryRecreationAndReads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let io = CommandMemory(), vault = TeamOrganizationCommandVault(io: io, removalDirectory: root)
        try AccountRemovalDisk(directory: root, account: cmAccount).removeCache()
        do { try await vault.begin(command(), lease: CalendarReadLease()); XCTFail("Recreated removed account") } catch {}
        do { _ = try await vault.pending(account: cmAccount, origin: cmOrigin); XCTFail("Read removed account") } catch {}
        XCTAssertTrue(io.values.isEmpty)
    }
    func testCancelledLeaseCannotPersistOrClear() async throws {
        let io = CommandMemory(), vault = TeamOrganizationCommandVault(io: io), command = try command(), lease = CalendarReadLease()
        lease.cancel()
        do { try await vault.begin(command, lease: lease); XCTFail("Cancelled save") } catch {}
        XCTAssertTrue(io.values.isEmpty)
        try await vault.begin(command, lease: CalendarReadLease())
        do { try await vault.clear(command, lease: lease); XCTFail("Cancelled clear") } catch {}
        XCTAssertFalse(io.values.isEmpty)
    }
    @MainActor func testLostReplyRelaunchAndRetryUseExactlyOneServerRequestIdentity() async throws {
        let io = CommandMemory(), vault = TeamOrganizationCommandVault(io: io), peer = CommandPeer(); peer.loseReply = true
        let command = try command(.folderCreate)
        let model = TeamOrganizationCommandModel(account: cmAccount, origin: cmOrigin, vault: vault, service: peer, isCurrent: { true })
        await model.send(command); XCTAssertEqual(model.pending, command); XCTAssertNil(model.receipt)
        model.close()
        let reopened = TeamOrganizationCommandModel(account: cmAccount, origin: cmOrigin, vault: TeamOrganizationCommandVault(io: io), service: peer, isCurrent: { true })
        await reopened.load(); XCTAssertEqual(peer.calls.count, 1); XCTAssertEqual(reopened.pending, command)
        await reopened.retry(); XCTAssertNil(reopened.pending); XCTAssertNotNil(reopened.receipt)
        XCTAssertEqual(peer.calls, [command, command]); XCTAssertEqual(peer.applied.count, 1)
    }
    @MainActor func testStaleRetryCannotSendAnotherWindowsReplacementRequest() async throws {
        let io = CommandMemory(), vault = TeamOrganizationCommandVault(io: io), peer = CommandPeer()
        let first = try command(), replacement = try command(.rename)
        try await vault.begin(first, lease: CalendarReadLease())
        let model = TeamOrganizationCommandModel(account: cmAccount, origin: cmOrigin, vault: vault, service: peer, isCurrent: { true })
        await model.load(); XCTAssertEqual(model.pending, first)
        try await vault.clear(first, lease: CalendarReadLease())
        try await vault.begin(replacement, lease: CalendarReadLease())
        await model.retry()
        XCTAssertTrue(peer.calls.isEmpty); XCTAssertEqual(model.pending, replacement)
        XCTAssertTrue(model.message?.contains("another window") == true)
        await model.retry(); XCTAssertEqual(peer.calls, [replacement])
    }
    @MainActor func testStorageFailurePreventsSendAndFailedClearRetainsRetry() async throws {
        let io = CommandMemory(), vault = TeamOrganizationCommandVault(io: io), peer = CommandPeer()
        let model = TeamOrganizationCommandModel(account: cmAccount, origin: cmOrigin, vault: vault, service: peer, isCurrent: { true })
        io.failWrite = true; let command = try command(); await model.send(command); XCTAssertTrue(peer.calls.isEmpty)
        io.failWrite = false; io.failRemove = true
        await model.send(command); XCTAssertEqual(model.pending, command); XCTAssertNil(model.receipt)
        io.failRemove = false; await model.retry(); XCTAssertEqual(peer.applied.count, 1); XCTAssertNotNil(model.receipt)
    }
    @MainActor func testExpiryNeverGeneratesReplacementOrSendsAgain() async throws {
        let io = CommandMemory(), vault = TeamOrganizationCommandVault(io: io), peer = CommandPeer(), time = Date()
        let command = try command(now: time.addingTimeInterval(-901))
        try await vault.begin(command, lease: CalendarReadLease())
        let model = TeamOrganizationCommandModel(account: cmAccount, origin: cmOrigin, vault: vault, service: peer, isCurrent: { true })
        await model.load(); await model.retry(now: time)
        XCTAssertTrue(peer.calls.isEmpty); XCTAssertEqual(model.pending, command)
        await model.clearReviewedRequest(command); XCTAssertNil(model.pending); XCTAssertTrue(peer.calls.isEmpty)
    }
    @MainActor func testClosingDuringSendKeepsOriginalAccountRecovery() async throws {
        let io = CommandMemory(), vault = TeamOrganizationCommandVault(io: io), peer = CommandPeer(); peer.wait = true
        var current = true
        let command = try command(), model = TeamOrganizationCommandModel(account: cmAccount, origin: cmOrigin, vault: vault, service: peer, isCurrent: { current })
        let sending = Task { await model.send(command) }
        while peer.continuation == nil { await Task.yield() }
        current = false; model.close(); peer.continuation?.resume(); await sending.value
        XCTAssertNil(model.pending); XCTAssertNil(model.receipt)
        let saved = try await vault.pending(account: cmAccount, origin: cmOrigin); XCTAssertEqual(saved, command)
        let other = try await vault.pending(account: cmOther, origin: cmOrigin); XCTAssertNil(other)
    }
    @MainActor func testForeignResultAndAuthenticationFailureKeepPending() async throws {
        for auth in [false, true] {
            let io = CommandMemory(), vault = TeamOrganizationCommandVault(io: io), peer = CommandPeer(); peer.failAuth = auth; peer.foreignResult = !auth
            let model = TeamOrganizationCommandModel(account: cmAccount, origin: cmOrigin, vault: vault, service: peer, isCurrent: { true }), command = try command()
            await model.send(command); XCTAssertEqual(model.pending, command); XCTAssertNil(model.receipt)
        }
    }
    func testActualPostgreSQLCommandReceiptsDecodeForEveryImplementedAction() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-organization-commands-v1", withExtension: "json", subdirectory: "Fixtures"))
        let rows = try JSONDecoder().decode([[String: JSON]].self, from: Data(contentsOf: url))
        var actions: Set<String> = []
        for raw in rows {
            let action = try XCTUnwrap(TeamOrganizationCommand.Action(rawValue: raw["action"]!.text)); actions.insert(action.rawValue)
            let command = try TeamOrganizationCommand(account: raw["account"]!.text, origin: cmOrigin, action: action, body: raw["body"]!.object)
            XCTAssertNoThrow(try command.confirmed(raw["result"]!.object))
        }
        XCTAssertEqual(actions, Set(TeamOrganizationCommand.Action.allCases.map(\.rawValue)))
    }
    @MainActor func testBackendIsScopedAndPreservesExactCommandBody() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CommandHTTP.self]
        let session = try JSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(cmAccount)\"}}".utf8))
        let api = Backend(configuration: ["URL": cmOrigin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        let command = try command(); var calls = 0
        CommandHTTP.handler = { request, peer in
            calls += 1; XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_teams"); XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store"); XCTAssertFalse(request.httpShouldHandleCookies)
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(contentsOf: bytes.prefix(n)) } }
            XCTAssertEqual(try? JSONDecoder().decode([String: JSON].self, from: data), ["_action": .string(command.action.rawValue), "_body": .object(command.body)])
            peer.finish(self.reply(command))
        }; defer { CommandHTTP.handler = nil }
        _ = try await api.teamOrganizationCommand(command)
        let other = try TeamOrganizationCommand(account: cmOther, origin: cmOrigin, action: .create, name: "Other")
        do { _ = try await api.teamOrganizationCommand(other); XCTFail("Foreign account sent") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 1)
    }
}
