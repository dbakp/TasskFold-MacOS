import XCTest
@testable import TaskfoldCore

private let ea = "f0e1cafe-0000-4000-8000-000000000001", eb = "f0e1cafe-0000-4000-8000-000000000002", eo = "https://backend.example"
private final class EmailMemory: CalendarSecureItemIO, @unchecked Sendable {
    var data: [String: Data] = [:]; var failWrite = false
    func read(key: String) throws -> Data? { data[key] }
    func write(_ value: Data, key: String) throws { if failWrite { throw EmailCaptureValue.invalid }; data[key] = value }
    func remove(key: String) throws { data.removeValue(forKey: key) }
}
private func edraft(_ byte: UInt8 = 0) throws -> EmailAddressDraft { try EmailAddressDraft(account: ea, origin: eo, domain: "mail.example.invalid", name: "Workflow inbox", project: nil, entropy: { Data(repeating: byte, count: 32) }) }
@MainActor private final class EmailPeer: EmailCaptureService {
    var rows: [String: [String: JSON]] = [:], calls: [(String, [String: JSON], String?)] = []
    var enabled = true, loseCreate = false, authFailure = false, malformed = false
    var suspended: CheckedContinuation<Void, Never>?
    var suspendCreate = false
    var afterCreate: (() -> Void)?
    var protocolVersion = 2
    func row(_ body: [String: JSON], state: String = "active", revision: Int = 1) -> [String: JSON] {
        ["id": body["id"]!, "alias_domain": body["domain"]!, "name": body["name"]!, "project_id": body["project_id"]!, "sender_email": .string("owner@example.invalid"), "state": .string(state), "revision": .number(Double(revision)), "created_at": .string("2026-10-23T16:00:00.000Z"), "updated_at": .string("2026-10-23T16:00:00.000Z"), "accept_after": .string("2026-10-23T16:00:00.000Z"), "rotated_to": .null]
    }
    func emailRouteReceipt(action: String, body: [String: JSON], domain: String?, account: String, origin: String) async throws -> [String: JSON] {
        calls.append((action, body, domain)); if authFailure { throw AccountSessionAuthorizationRequired() }
        if action == "list" { return ["protocol": .number(Double(protocolVersion)), "account": .string(account), "available": .bool(enabled), "domain": enabled ? .string("mail.example.invalid") : .null, "routes": .array(rows.values.map(JSON.object))] }
        if suspendCreate { await withCheckedContinuation { suspended = $0 }; suspendCreate = false }
        let id = body["id"]!.text
        if action == "create" { if rows[id] == nil { rows[id] = row(body) }; if loseCreate { loseCreate = false; throw URLError(.networkConnectionLost) } }
        if action == "revoke", rows[id] == nil { return ["protocol": .number(Double(protocolVersion)), "account": .string(account), "id": .string(id), "cancelled": .bool(true)] }
        if action == "rotate" {
            let replacement = body["replacement"]!.object; let newID = replacement["id"]!.text
            rows[id]?["state"] = .string("revoked"); rows[id]?["rotated_to"] = .string(newID); rows[newID] = row(replacement)
            return ["protocol": .number(Double(protocolVersion)), "account": .string(account), "route": .object(rows[newID]!), "replaced": .object(rows[id]!)]
        }
        if ["pause", "resume", "revoke"].contains(action) { rows[id]?["state"] = .string(action == "pause" ? "paused" : action == "resume" ? "active" : "revoked"); rows[id]?["revision"] = .number(Double(body["revision"]!.integer + 1)) }
        if action == "create" { afterCreate?() }; var value = rows[id]!; if malformed { value["id"] = .string(eb) }
        return ["protocol": .number(Double(protocolVersion)), "account": .string(account), "route": .object(value)]
    }
}
final class EmailCaptureTests: XCTestCase {
    func testAliasContractAndRedaction() throws {
        let d = try edraft(); XCTAssertEqual(d.address, String(repeating: "00", count: 32) + "@mail.example.invalid")
        XCTAssertEqual(d.hash, "0736b143acb81a8e6e472803f1d5e30bbff26de6a6de5cf3ac7cff5f929a57b7")
        XCTAssertFalse(String(describing: d).contains(d.address)); XCTAssertFalse(String(reflecting: d).contains(d.localPartForTest))
        XCTAssertFalse(String(describing: d.body).contains(d.address)); XCTAssertEqual(d.body["alias_hash"], .string(d.hash))
        XCTAssertNotEqual(try edraft(1).hash, d.hash)
    }
    func testDraftValidationAndMailboxBounds() throws {
        for domain in ["MAIL.example.invalid", "mail..invalid", "https://mail.example.invalid", "localhost", String(repeating:"a",count:63)+"."+String(repeating:"b",count:63)+"."+String(repeating:"c",count:62)] {
            XCTAssertThrowsError(try EmailAddressDraft(account: ea, origin: eo, domain: domain, name: "Inbox", project: nil))
        }
        XCTAssertThrowsError(try EmailAddressDraft(account: ea, origin: eo, domain: "mail.example.invalid", name: "Inbox\n", project: nil))
        XCTAssertThrowsError(try EmailAddressDraft(account: ea, origin: eo, domain: "mail.example.invalid", name: "Inbox", project: nil, entropy: { Data() }))
        XCTAssertThrowsError(try EmailAddressDraft(account: ea, origin: "http://backend.example", domain: "mail.example.invalid", name: "Inbox", project: nil))
    }
    func testOperationValidationAndPrivateDescription() throws {
        let d = try edraft(); let op = try EmailAddressOperation(action: "create", id: d.id, domain: d.domain, draft: d)
        XCTAssertEqual(op.body, d.body); XCTAssertFalse(String(reflecting: op).contains(d.address))
        XCTAssertThrowsError(try EmailAddressOperation(action: "resume", id: d.id, revision: 1))
        XCTAssertThrowsError(try EmailAddressOperation(action: "pause", id: d.id, revision: 0))
        XCTAssertThrowsError(try EmailAddressOperation(action: "rotate", id: d.id, revision: 1, domain: d.domain, draft: d))
    }
    func testVaultRetainsExactSetupBeforeNetworkAndAcrossActors() async throws {
        let io = EmailMemory(), vault = EmailAddressVault(io: io), lease = CalendarReadLease(), d = try edraft()
        let op = try EmailAddressOperation(action: "create", id: d.id, domain: d.domain, draft: d)
        try await vault.begin(op, account: ea, origin: eo, lease: lease)
        let reopened = EmailAddressVault(io: io), saved = try await reopened.recovery(account: ea, origin: eo)
        XCTAssertEqual(saved.pending?.body, d.body); XCTAssertTrue(saved.addresses.isEmpty)
        XCTAssertFalse(String(reflecting: saved).contains(d.address))
        try await reopened.finish(op, account: ea, origin: eo, lease: lease)
        let finished = try await vault.recovery(account: ea, origin: eo)
        XCTAssertNil(finished.pending); XCTAssertEqual(finished.addresses.first?.address, d.address)
    }
    func testVaultFencesAccountOriginCancellationAndCompetingSetup() async throws {
        let io = EmailMemory(), vault = EmailAddressVault(io: io), lease = CalendarReadLease(), d = try edraft()
        let op = try EmailAddressOperation(action: "create", id: d.id, domain: d.domain, draft: d)
        try await vault.begin(op, account: ea, origin: eo, lease: lease)
        do { _ = try await vault.recovery(account: ea, origin: "https://other.example"); XCTFail() } catch {}
        let other = try await vault.recovery(account: eb, origin: eo); XCTAssertNil(other.pending)
        let changed = try EmailAddressOperation(action: "revoke", id: d.id)
        do { try await vault.begin(changed, account: ea, origin: eo, lease: lease); XCTFail() } catch {}
        lease.cancel(); do { try await vault.finish(op, account: ea, origin: eo, lease: lease); XCTFail() } catch {}
        let retained = try await vault.recovery(account: ea, origin: eo); XCTAssertNotNil(retained.pending)
    }
    func testCancelSetupPersistsTerminalIntentBeforeRetry() async throws {
        let vault = EmailAddressVault(io: EmailMemory()), lease = CalendarReadLease(), d = try edraft()
        try await vault.begin(EmailAddressOperation(action: "create", id: d.id, domain: d.domain, draft: d), account: ea, origin: eo, lease: lease)
        try await vault.cancelSetup(account: ea, origin: eo, lease: lease)
        let saved = try await vault.recovery(account: ea, origin: eo)
        XCTAssertEqual(saved.pending?.action, "revoke"); XCTAssertEqual(saved.pending?.body, ["id": .string(d.id), "revision": .number(0)]); XCTAssertNil(saved.pending?.draft)
    }
    @MainActor func testCreatePersistsThenRevealsOnlyConfirmedAddress() async throws {
        let peer = EmailPeer(), io = EmailMemory(), model = EmailCaptureModel(account: ea, origin: eo, service: peer, vault: EmailAddressVault(io: io), isCurrent: { true })
        await model.load(); await model.create(name: "Workflow inbox", project: nil)
        XCTAssertNil(model.pending); XCTAssertEqual(model.routes.count, 1); XCTAssertNotNil(model.address(for: model.routes[0])); XCTAssertNil(model.message)
        let body = peer.calls.first { $0.0 == "create" }!.1
        XCTAssertFalse(String(describing: body).contains("@mail.example.invalid")); XCTAssertEqual(peer.calls.first { $0.0 == "create" }!.2, "mail.example.invalid")
    }
    @MainActor func testLostResponseRelaunchRetriesSameIdentity() async throws {
        let io = EmailMemory(), peer = EmailPeer(); peer.loseCreate = true
        let first = EmailCaptureModel(account: ea, origin: eo, service: peer, vault: EmailAddressVault(io: io), isCurrent: { true })
        await first.load(); await first.create(name: "Workflow inbox", project: nil); XCTAssertNotNil(first.pending); XCTAssertNotNil(first.message); first.close()
        let second = EmailCaptureModel(account: ea, origin: eo, service: peer, vault: EmailAddressVault(io: io), isCurrent: { true })
        await second.load(); XCTAssertNotNil(second.pending); await second.retry()
        let calls = peer.calls.filter { $0.0 == "create" }; XCTAssertEqual(calls.count, 2); XCTAssertEqual(calls[0].1, calls[1].1); XCTAssertEqual(peer.rows.count, 1); XCTAssertNil(second.pending); XCTAssertNotNil(second.address(for: second.routes[0]))
    }
    @MainActor func testFailedPrivateSaveNeverSendsCreation() async throws {
        let io = EmailMemory(), peer = EmailPeer(), model = EmailCaptureModel(account: ea, origin: eo, service: peer, vault: EmailAddressVault(io: io), isCurrent: { true })
        await model.load(); io.failWrite = true; await model.create(name: "Workflow inbox", project: nil)
        XCTAssertFalse(peer.calls.contains { $0.0 == "create" }); XCTAssertNotNil(model.message)
    }
    @MainActor func testWrongReceiptNeverConfirmsSecretOrClearsRecovery() async throws {
        let peer = EmailPeer(); peer.malformed = true
        let model = EmailCaptureModel(account: ea, origin: eo, service: peer, vault: EmailAddressVault(io: EmailMemory()), isCurrent: { true })
        await model.load(); await model.create(name: "Workflow inbox", project: nil); XCTAssertNotNil(model.pending); XCTAssertFalse(model.available); XCTAssertNotNil(model.message)
    }
    @MainActor func testPauseResumeRotateAndRevokeKeepPrivateVaultAligned() async throws {
        let peer = EmailPeer(), model = EmailCaptureModel(account: ea, origin: eo, service: peer, vault: EmailAddressVault(io: EmailMemory()), isCurrent: { true })
        await model.load(); await model.create(name: "Workflow inbox", project: nil); let original = model.routes[0]
        await model.control("pause", route: original); XCTAssertEqual(model.routes[0].state, "paused")
        await model.control("resume", route: model.routes[0]); XCTAssertEqual(model.routes[0].state, "active")
        let oldAddress = model.address(for: model.routes[0]); await model.control("rotate", route: model.routes[0]); let replacement = try XCTUnwrap(model.routes.first { $0.state == "active" })
        XCTAssertNotEqual(model.address(for: replacement), oldAddress); XCTAssertNil(model.address(for: original))
        await model.control("revoke", route: replacement); XCTAssertTrue(model.routes.allSatisfy { $0.state == "revoked" }); XCTAssertNil(model.address(for: replacement))
    }
    @MainActor func testWorkspaceChangeDiscardsLateResponseButKeepsPrivateRecovery() async throws {
        let io = EmailMemory(), peer = EmailPeer(); var current = true
        let model = EmailCaptureModel(account: ea, origin: eo, service: peer, vault: EmailAddressVault(io: io), isCurrent: { current })
        await model.load(); peer.suspendCreate = true
        let work = Task { await model.create(name: "Workflow inbox", project: nil) }
        while peer.suspended == nil { await Task.yield() }
        current = false; model.close(); peer.suspended?.resume(); await work.value
        XCTAssertTrue(model.routes.isEmpty); XCTAssertNil(model.pending)
        let retained = try await EmailAddressVault(io: io).recovery(account: ea, origin: eo); XCTAssertNotNil(retained.pending)
    }
    @MainActor func testDisabledConfigurationAndExpiredSessionConcealAddresses() async throws {
        let peer = EmailPeer(), model = EmailCaptureModel(account: ea, origin: eo, service: peer, vault: EmailAddressVault(io: EmailMemory()), isCurrent: { true })
        await model.load(); await model.create(name: "Workflow inbox", project: nil); let route = model.routes[0]
        peer.enabled = false; await model.load(); XCTAssertNil(model.address(for: route)); await model.create(name: "Other", project: nil); XCTAssertEqual(peer.rows.count, 1)
        peer.authFailure = true; await model.load(); XCTAssertTrue(model.needsSignIn); XCTAssertNil(model.address(for: route))
    }
    @MainActor func testOtherDeviceCanManageButCannotRevealOrResumeUnknownAddress() async throws {
        let peer = EmailPeer(); let draft = try edraft(); peer.rows[draft.id] = peer.row(draft.body, state: "paused")
        let model = EmailCaptureModel(account: ea, origin: eo, service: peer, vault: EmailAddressVault(io: EmailMemory()), isCurrent: { true }); await model.load()
        XCTAssertNil(model.address(for: model.routes[0])); await model.control("resume", route: model.routes[0]); XCTAssertFalse(peer.calls.contains { $0.0 == "resume" })
        await model.load(); await model.control("revoke", route: model.routes[0]); XCTAssertEqual(model.routes[0].state, "revoked")
    }
}
private extension EmailAddressDraft { var localPartForTest: String { String(address.prefix(64)) } }
extension EmailCaptureTests {
    @MainActor func testPrivateSaveFailureAfterServerCommitRetainsRetry() async throws {
        let io = EmailMemory(), peer = EmailPeer(), vault = EmailAddressVault(io: io)
        let model = EmailCaptureModel(account: ea, origin: eo, service: peer, vault: vault, isCurrent: { true })
        await model.load(); peer.afterCreate = { io.failWrite = true }
        await model.create(name: "Workflow inbox", project: nil)
        XCTAssertEqual(peer.rows.count, 1); XCTAssertNotNil(model.pending); XCTAssertFalse(model.available)
        io.failWrite = false; peer.afterCreate = nil; await model.retry()
        XCTAssertNil(model.pending); XCTAssertEqual(peer.rows.count, 1); XCTAssertNotNil(model.address(for: model.routes[0]))
    }
    @MainActor func testDiscardLostCreationRevokesItAndDoesNotExposeAddress() async throws {
        let peer = EmailPeer(); peer.loseCreate = true
        let model = EmailCaptureModel(account: ea, origin: eo, service: peer, vault: EmailAddressVault(io: EmailMemory()), isCurrent: { true })
        await model.load(); await model.create(name: "Workflow inbox", project: nil); XCTAssertNotNil(model.pending)
        await model.discardSetup(); XCTAssertNil(model.pending); XCTAssertEqual(model.routes.first?.state, "revoked"); XCTAssertNil(model.address(for: model.routes[0]))
    }
    func testSeparateVaultActorsSerializeCompetingSetupsUsingProcessLock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Taskfold-email-lock-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = EmailMemory(), one = EmailAddressVault(io: io, coordinationDirectory: directory), two = EmailAddressVault(io: io, coordinationDirectory: directory)
        let d1 = try edraft(), d2 = try edraft(1)
        let op1 = try EmailAddressOperation(action: "create", id: d1.id, domain: d1.domain, draft: d1), op2 = try EmailAddressOperation(action: "create", id: d2.id, domain: d2.domain, draft: d2)
        func attempt(_ vault: EmailAddressVault, _ op: EmailAddressOperation) async -> Bool { do { try await vault.begin(op, account: ea, origin: eo, lease: CalendarReadLease()); return true } catch { return false } }
        async let first = attempt(one, op1); async let second = attempt(two, op2)
        let (a, b) = await (first, second); XCTAssertNotEqual(a, b)
        let saved = try await one.recovery(account: ea, origin: eo); XCTAssertEqual(saved.pending?.body, a ? op1.body : op2.body)
    }
    @MainActor func testRefreshResolvesSupersededControlWithoutErasingLiveAddress() async throws {
        let io = EmailMemory(), peer = EmailPeer(), vault = EmailAddressVault(io: io)
        let model = EmailCaptureModel(account: ea, origin: eo, service: peer, vault: vault, isCurrent: { true })
        await model.load(); await model.create(name: "Workflow inbox", project: nil); let original = model.routes[0]
        try await vault.begin(EmailAddressOperation(action: "revoke", id: original.id, revision: original.revision), account: ea, origin: eo, lease: CalendarReadLease())
        peer.rows[original.id]?["revision"] = .number(2)
        await model.load(); XCTAssertNil(model.pending); XCTAssertEqual(model.routes[0].state, "active"); XCTAssertNotNil(model.address(for: model.routes[0])); XCTAssertNotNil(model.message)
    }
    func testAccountErasureAndRevokedPruningPreserveOtherAccounts() async throws {
        let io = EmailMemory(), vault = EmailAddressVault(io: io), lease = CalendarReadLease(), d = try edraft()
        let op = try EmailAddressOperation(action: "create", id: d.id, domain: d.domain, draft: d)
        try await vault.begin(op, account: ea, origin: eo, lease: lease); try await vault.finish(op, account: ea, origin: eo, lease: lease)
        let other = try EmailAddressDraft(account: eb, origin: eo, domain: d.domain, name: "Other inbox", project: nil), op2 = try EmailAddressOperation(action: "create", id: other.id, domain: other.domain, draft: other)
        try await vault.begin(op2, account: eb, origin: eo, lease: lease); try await vault.finish(op2, account: eb, origin: eo, lease: lease)
        try await vault.pruneRevoked([d.id], account: ea, origin: eo, lease: lease)
        let pruned = try await vault.recovery(account: ea, origin: eo); XCTAssertTrue(pruned.addresses.isEmpty)
        try await vault.removeAccount(ea, origin: eo); let retained = try await vault.recovery(account: eb, origin: eo); XCTAssertEqual(retained.addresses.first?.address, other.address)
    }
}
private final class EmailHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, EmailHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() { Self.handler?(request, self) }
    func finish(_ data: Data) { client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self) }
}
extension EmailCaptureTests {
    @MainActor private func emailBackend() throws -> Backend {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [EmailHTTP.self]
        let session = try JSONDecoder().decode(Session.self, from: Data(("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"" + ea + "\"}}").utf8))
        return Backend(configuration: ["URL": eo, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
    }
    @MainActor func testHTTPUsesBoundedPrivateFixedRouteAndReviewedDomain() async throws {
        let backend = try emailBackend(), draft = try edraft(); var calls = 0
        defer { EmailHTTP.handler = nil }
        EmailHTTP.handler = { request, peer in
            calls += 1; XCTAssertEqual(request.url?.absoluteString, eo + "/functions/v1/email-routes"); XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.value(forHTTPHeaderField: "X-Taskfold-Email-Domain"), draft.domain); XCTAssertEqual(request.value(forHTTPHeaderField: "X-Taskfold-Email"), "2"); XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store"); XCTAssertFalse(request.httpShouldHandleCookies); XCTAssertEqual(request.timeoutInterval, 25)
            peer.finish(try! JSONEncoder().encode(["protocol": JSON.number(2), "account": JSON.string(ea)]))
        }
        _ = try await backend.emailRouteReceipt(action: "create", body: draft.body, domain: draft.domain, account: ea, origin: eo); XCTAssertEqual(calls, 1)
        do { _ = try await backend.emailRouteReceipt(action: "list", body: [:], domain: nil, account: eb, origin: eo); XCTFail() } catch {}
        do { _ = try await backend.emailRouteReceipt(action: "list", body: [:], domain: nil, account: ea, origin: "https://other.example"); XCTFail() } catch {}
        XCTAssertEqual(calls, 1)
    }
    @MainActor func testHTTPRefusesForeignOwnerAndOversizeStreamWithoutConfirming() async throws {
        let backend = try emailBackend(); defer { EmailHTTP.handler = nil }
        EmailHTTP.handler = { _, peer in peer.finish(try! JSONEncoder().encode(["protocol": JSON.number(2), "account": JSON.string(eb)])) }
        do { _ = try await backend.emailRouteReceipt(action: "list", body: [:], domain: nil, account: ea, origin: eo); XCTFail() } catch {}
        EmailHTTP.handler = { _, peer in peer.finish(Data(repeating: 32, count: 512001)) }
        do { _ = try await backend.emailRouteReceipt(action: "list", body: [:], domain: nil, account: ea, origin: eo); XCTFail() } catch {}
    }
}
extension EmailCaptureTests {
    @MainActor func testRetryRefreshesWhenAnotherWindowAlreadyFinished() async throws {
        let io = EmailMemory(), peer = EmailPeer(); peer.loseCreate = true
        let first = EmailCaptureModel(account: ea, origin: eo, service: peer, vault: EmailAddressVault(io: io), isCurrent: { true })
        await first.load(); await first.create(name: "Workflow inbox", project: nil)
        let second = EmailCaptureModel(account: ea, origin: eo, service: peer, vault: EmailAddressVault(io: io), isCurrent: { true })
        await second.load(); XCTAssertNotNil(second.pending)
        await first.retry(); XCTAssertNil(first.pending)
        await second.retry(); XCTAssertNil(second.pending); XCTAssertEqual(second.routes.count, 1); XCTAssertNotNil(second.address(for: second.routes[0]))
        XCTAssertEqual(peer.calls.filter { $0.0 == "create" }.count, 2)
    }
}
extension EmailCaptureTests {
    func testReviewedDomainIsExplicitInSetupAndResume() throws {
        let draft = try edraft(); XCTAssertEqual(draft.body["domain"], .string(draft.domain))
        let op = try EmailAddressOperation(action:"resume",id:draft.id,revision:1,domain:draft.domain)
        XCTAssertEqual(op.body["domain"],.string(draft.domain))
    }
    @MainActor func testActiveReceiptRequiresDomainWhileRevokedLegacyMayBeUnknown() throws {
        let peer = EmailPeer(), draft = try edraft(); var row = peer.row(draft.body); row.removeValue(forKey:"alias_domain")
        XCTAssertThrowsError(try EmailRoute(row));row["alias_domain"] = .null;XCTAssertThrowsError(try EmailRoute(row))
        row["state"] = .string("revoked");XCTAssertNil(try EmailRoute(row).domain)
        row["state"] = .string("active");row["alias_domain"] = .string(draft.domain);XCTAssertEqual(try EmailRoute(row).domain,draft.domain)
    }
    @MainActor func testPrivateAddressCannotBeRevealedAgainstDifferentReceiptDomain() async throws {
        let peer = EmailPeer(), model = EmailCaptureModel(account:ea,origin:eo,service:peer,vault:EmailAddressVault(io:EmailMemory()),isCurrent:{true})
        await model.load();await model.create(name:"Workflow inbox",project:nil);let id=model.routes[0].id
        peer.rows[id]?["alias_domain"] = .string("other.example.invalid");await model.load();XCTAssertNil(model.address(for:model.routes[0]))
    }
    @MainActor func testLegacyProtocolCannotPopulateNativeModel() async throws {
        let peer = EmailPeer();peer.protocolVersion=1
        let model = EmailCaptureModel(account:ea,origin:eo,service:peer,vault:EmailAddressVault(io:EmailMemory()),isCurrent:{true})
        await model.load();XCTAssertTrue(model.routes.isEmpty);XCTAssertFalse(model.available);XCTAssertNotNil(model.message)
    }
    @MainActor func testBackendRequiresVersionTwoReceipt() async throws {
        let backend=try emailBackend();defer{EmailHTTP.handler=nil}
        EmailHTTP.handler={_,peer in peer.finish(try! JSONEncoder().encode(["account":JSON.string(ea),"protocol":JSON.number(1)]))}
        do{_ = try await backend.emailRouteReceipt(action:"list",body:[:],domain:nil,account:ea,origin:eo);XCTFail()}catch{}
    }
}
extension EmailCaptureTests {
    @MainActor func testRetiredLegacyPendingSetupCanBeDiscardedWithoutGuessingDomain() async throws {
        let peer=EmailPeer();peer.loseCreate=true
        let model=EmailCaptureModel(account:ea,origin:eo,service:peer,vault:EmailAddressVault(io:EmailMemory()),isCurrent:{true})
        await model.load();await model.create(name:"Workflow inbox",project:nil);let id=try XCTUnwrap(model.pending?.id)
        peer.rows[id]?["state"] = .string("revoked");peer.rows[id]?["alias_domain"] = .null;peer.rows[id]?["revision"] = .number(2)
        await model.load();await model.retry();XCTAssertNotNil(model.pending);XCTAssertFalse(model.available)
        await model.discardSetup();XCTAssertNil(model.pending);XCTAssertEqual(model.routes.first?.state,"revoked");XCTAssertEqual(peer.rows.count,1)
    }
}
