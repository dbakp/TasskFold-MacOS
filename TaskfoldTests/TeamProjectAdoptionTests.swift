import XCTest
@testable import TaskfoldCore

private final class AdoptionIO: CalendarSecureItemIO, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: Data] = [:]
    var failWrite = false, failRemove = false
    func read(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return rows[key] }
    func write(_ data: Data, key: String) throws { lock.lock(); defer { lock.unlock() }; if failWrite { throw URLError(.cannotWriteToFile) }; rows[key] = data }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; if failRemove { throw URLError(.cannotRemoveFile) }; rows.removeValue(forKey: key) }
    var encoded: String { lock.lock(); defer { lock.unlock() }; return rows.values.map { String(decoding: $0, as: UTF8.self) }.joined() }
}
@MainActor private final class AdoptionPeer: TeamProjectAdoptionService {
    var calls: [TeamProjectAdoptionCommand] = []
    private var applied: Set<String> = []
    var lose = false, hold = false, foreign = false
    var continuation: CheckedContinuation<Void, Never>?
    var onReply: (() -> Void)?
    let raw: [String: JSON]
    init(_ raw: [String: JSON]) { self.raw = raw }
    func inspectProjectAdoption(_ scope: TeamProjectAdoptionScope) async throws -> TeamProjectAdoptionInspection { throw TeamProjectAdoptionValue.invalid }
    func reviewProjectAdoption(_ inspection: TeamProjectAdoptionInspection, decisions: [TeamProjectAdoptionDecision]) async throws -> TeamProjectAdoptionReview { throw TeamProjectAdoptionValue.invalid }
    func adoptProjects(_ command: TeamProjectAdoptionCommand) async throws -> TeamProjectAdoptionReceipt {
        calls.append(command)
        if hold { await withCheckedContinuation { continuation = $0 } }
        if lose { lose = false; applied.insert(command.id); throw URLError(.networkConnectionLost) }
        var reply = raw; reply["request_id"] = .string(command.id); reply["replayed"] = .bool(!applied.insert(command.id).inserted)
        if foreign { reply["account"] = .string(UUID().uuidString.lowercased()) }
        let result = try command.confirmed(reply); onReply?(); return result
    }
}
private final class AdoptionHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, AdoptionHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func finish(_ raw: [String: JSON]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(raw)); client?.urlProtocolDidFinishLoading(self)
    }
}

final class TeamProjectAdoptionTests: XCTestCase {
    private func fixture(connections: Bool = false) throws -> ([String: JSON], TeamProjectAdoptionInspection, TeamProjectAdoptionReview, TeamProjectAdoptionCommand) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: connections ? "team-project-adoption-connections-v1" : "team-project-adoption-v1", withExtension: "json", subdirectory: "Fixtures"))
        let raw = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url)), b = raw["body"]!.object
        XCTAssertEqual(raw["syntheticOnly"], .bool(true)); XCTAssertEqual(raw["containerRemoved"], .bool(true))
        let scope = try TeamProjectAdoptionScope(account: raw["account"]!.text, origin: raw["origin"]!.text, team: b["team_id"]!.text, roots: b["roots"]!.list.map(\.text), visibility: .private)
        let i = try TeamProjectAdoptionInspection(raw["inspect"]!.object, scope: scope)
        let decisions = try raw["decisions"]!.list.map { try TeamProjectAdoptionDecision($0.object) }
        let r = try TeamProjectAdoptionReview(raw["review"]!.object, inspection: i, decisions: decisions, connectionPolicy: connections ? .pause : nil)
        let c = try TeamProjectAdoptionCommand(review: r, requestID: UUID(uuidString: raw["command"]!.object["request_id"]!.text)!, now: r.expires.addingTimeInterval(-60))
        return (raw, i, r, c)
    }
    func testActualSQLInspectionReviewAndReceipt() throws {
        let (raw, i, r, c) = try fixture()
        XCTAssertEqual(i.projects.count, 2); XCTAssertTrue(i.projects.contains { $0.archived }); XCTAssertEqual(i.people.count, 2)
        XCTAssertEqual(r.assignmentsCleared, 1); XCTAssertEqual(r.invitationsClosed, 2); XCTAssertTrue(r.canCommit)
        XCTAssertEqual(c.body, raw["command"]!.object); XCTAssertFalse(try c.confirmed(raw["receipt"]!.object).replayed)
        XCTAssertEqual(try JSONDecoder().decode(TeamProjectAdoptionCommand.self, from: JSONEncoder().encode(c)), c)
    }
    func testEveryAcceptedCollaboratorNeedsAnExplicitDecision() throws {
        let (_, i, r, _) = try fixture()
        XCTAssertThrowsError(try i.reviewBody([])); XCTAssertThrowsError(try i.reviewBody(r.decisions + [r.decisions[0]]))
        let outsider = try XCTUnwrap(i.people.first { !$0.eligible })
        let bad = try r.decisions.map { d in try TeamProjectAdoptionDecision(project: d.project, user: d.user, choice: d.user == outsider.user ? .editor : d.choice) }
        XCTAssertThrowsError(try i.reviewBody(bad))
    }
    func testSourceForestCannotBeRetargetedOrFabricated() throws {
        let (raw, i, _, _) = try fixture()
        for (k, value) in ["account": JSON.string(UUID().uuidString.lowercased()), "team_id": .string(UUID().uuidString.lowercased()), "creates_memberships": .bool(true), "automatic_undo": .bool(true), "inspection_token": .string("bad"), "destination_archived": .null] {
            var x = raw["inspect"]!.object; x[k] = value; XCTAssertThrowsError(try TeamProjectAdoptionInspection(x, scope: i.scope), k)
        }
        var x = raw["inspect"]!.object, projects = x["projects"]!.list
        var child = projects[1].object; child["parent_id"] = .string(UUID().uuidString.lowercased()); projects[1] = .object(child); x["projects"] = .array(projects)
        XCTAssertThrowsError(try TeamProjectAdoptionInspection(x, scope: i.scope))
        x = raw["inspect"]!.object; x["projects"] = .array([projects[0], projects[0]]); XCTAssertThrowsError(try TeamProjectAdoptionInspection(x, scope: i.scope))
        XCTAssertThrowsError(try TeamProjectAdoptionScope(account: i.scope.account, origin: "http://synthetic.example", team: i.scope.team, roots: i.scope.roots, visibility: .private))
    }
    func testReviewCannotChangeAChoiceOrHideAnInvitation() throws {
        let (raw, i, r, _) = try fixture()
        for (k, value) in ["assignments_cleared": JSON.number(-1), "invitations_closed": .number(0), "expires_at": .string("2026-10-25T10:00:00+01:00"), "review_token": .string("bad"), "requires_provider_custody": .bool(true)] {
            var x = raw["review"]!.object; x[k] = value; XCTAssertThrowsError(try TeamProjectAdoptionReview(x, inspection: i, decisions: r.decisions), k)
        }
        var x = raw["review"]!.object, decisions = x["decisions"]!.list; var d = decisions[0].object; d["role"] = .string("viewer"); decisions[0] = .object(d); x["decisions"] = .array(decisions)
        XCTAssertThrowsError(try TeamProjectAdoptionReview(x, inspection: i, decisions: r.decisions))
    }
    func testFreshAuthoringAndExpiredRetryAreDifferent() throws {
        let (_, _, r, c) = try fixture()
        XCTAssertThrowsError(try TeamProjectAdoptionCommand(review: r, now: r.expires)); XCTAssertThrowsError(try TeamProjectAdoptionCommand(review: r, now: r.expires.addingTimeInterval(-17 * 60)))
        XCTAssertNotEqual(try TeamProjectAdoptionCommand(review: r, now: r.expires.addingTimeInterval(-60)).id, c.id)
        // Decoding preserves a saved request even after its review expires.
        XCTAssertEqual(try JSONDecoder().decode(TeamProjectAdoptionCommand.self, from: JSONEncoder().encode(c)), c)
    }
    func testOnlyIdentityAndProofFieldsEnterThePrivateRetry() throws {
        let (_, _, _, c) = try fixture(); let data = try JSONEncoder().encode(c), text = String(decoding: data, as: UTF8.self)
        for privateText in ["Studio plan", "Never put task text", "example.invalid", "data:text/plain", "Design Studio"] { XCTAssertFalse(text.contains(privateText)) }
        XCTAssertEqual(String(reflecting: c), "Private project transfer request")
        for (key, value) in ["task": JSON.string("Private text"), "review_token": .string("bad"), "request_id": .null, "expires_at": .string("bad")] {
            var b = c.body; b[key] = value; XCTAssertThrowsError(try TeamProjectAdoptionCommand(account: c.account, origin: c.origin, body: b, projects: c.projects, assignmentsCleared: c.assignmentsCleared, invitationsClosed: c.invitationsClosed))
        }
    }
    func testReceiptRequiresTheWholeReviewedForestAndExactCounts() throws {
        let (raw, _, _, c) = try fixture()
        for (key, value) in ["account": JSON.string(UUID().uuidString.lowercased()), "request_id": .string(UUID().uuidString.lowercased()), "project_ids": .array([.string(c.projects[0])]), "assignments_cleared": .number(0), "invitations_closed": .number(0), "applied": .bool(false), "automatic_undo": .bool(true)] {
            var x = raw["receipt"]!.object; x[key] = value; XCTAssertThrowsError(try c.confirmed(x), key)
        }
    }
    @MainActor func testLostReplyRelaunchRetriesTheExactNonce() async throws {
        let (raw, _, r, c) = try fixture(), io = AdoptionIO(), vault = TeamProjectAdoptionVault(io: io), peer = AdoptionPeer(raw["receipt"]!.object)
        peer.lose = true
        let first = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: vault, service: peer, current: { true })
        await first.send(c, canAuthor: { true }, now: r.expires.addingTimeInterval(-60)); XCTAssertEqual(first.pending, c); XCTAssertNil(first.receipt); first.close()
        let second = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: vault, service: peer, current: { true })
        await second.load(); XCTAssertEqual(second.pending, c); await second.retry()
        XCTAssertEqual(peer.calls, [c,c]); XCTAssertEqual(second.receipt?.command, c); XCTAssertEqual(second.receipt?.replayed, true); XCTAssertNil(second.pending)
    }
    @MainActor func testNoNetworkWriteBeforeDurablePrivateSave() async throws {
        let (raw, _, r, c) = try fixture(), io = AdoptionIO(); io.failWrite = true
        let peer = AdoptionPeer(raw["receipt"]!.object), model = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: TeamProjectAdoptionVault(io: io), service: peer, current: { true })
        await model.send(c, canAuthor: { true }, now: r.expires.addingTimeInterval(-60)); XCTAssertTrue(peer.calls.isEmpty); XCTAssertNil(model.receipt)
    }
    @MainActor func testOtherWindowsCannotReplaceThePendingTransfer() async throws {
        let (raw, _, r, c) = try fixture(), io = AdoptionIO(), vault = TeamProjectAdoptionVault(io: io), peer = AdoptionPeer(raw["receipt"]!.object)
        peer.lose = true
        let first = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: vault, service: peer, current: { true })
        await first.send(c, canAuthor: { true }, now: r.expires.addingTimeInterval(-60))
        let second = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: vault, service: peer, current: { true }), other = try TeamProjectAdoptionCommand(review: r, now: r.expires.addingTimeInterval(-60))
        await second.send(other, canAuthor: { true }, now: r.expires.addingTimeInterval(-60)); XCTAssertEqual(peer.calls, [c]); XCTAssertEqual(second.pending, c)
        await second.clear(other); XCTAssertEqual(second.pending, c)
    }
    @MainActor func testAccountSwitchDuringReplyCannotClearPrivateRecovery() async throws {
        let (raw, _, r, c) = try fixture(), io = AdoptionIO(), vault = TeamProjectAdoptionVault(io: io), peer = AdoptionPeer(raw["receipt"]!.object)
        var current = true; peer.onReply = { current = false }
        let model = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: vault, service: peer, current: { current })
        await model.send(c, canAuthor: { true }, now: r.expires.addingTimeInterval(-60)); XCTAssertNil(model.receipt)
        let saved = try await vault.pending(account: c.account, origin: c.origin); XCTAssertEqual(saved, c)
    }
    @MainActor func testForeignReplyAndCleanupFailureKeepTheRequest() async throws {
        let (raw, _, r, c) = try fixture(), io = AdoptionIO(), vault = TeamProjectAdoptionVault(io: io), peer = AdoptionPeer(raw["receipt"]!.object)
        peer.foreign = true
        let model = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: vault, service: peer, current: { true })
        await model.send(c, canAuthor: { true }, now: r.expires.addingTimeInterval(-60)); XCTAssertEqual(model.pending, c)
        peer.foreign = false; io.failRemove = true; await model.retry(); XCTAssertEqual(model.pending, c); XCTAssertNil(model.receipt)
        io.failRemove = false; await model.retry(); XCTAssertNotNil(model.receipt)
    }
    @MainActor func testNewAuthoringCannotBypassTheCleanWorkspaceGate() async throws {
        let (raw, _, r, c) = try fixture(), peer = AdoptionPeer(raw["receipt"]!.object), model = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: TeamProjectAdoptionVault(io: AdoptionIO()), service: peer, current: { true })
        await model.send(c, canAuthor: { false }, now: r.expires.addingTimeInterval(-60)); XCTAssertTrue(peer.calls.isEmpty); XCTAssertNil(model.pending)
    }
    @MainActor func testReviewedClearIsLocalAndDoesNotSendOrUndo() async throws {
        let (raw, _, r, c) = try fixture(), peer = AdoptionPeer(raw["receipt"]!.object), io = AdoptionIO(), vault = TeamProjectAdoptionVault(io: io)
        peer.lose = true; let model = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: vault, service: peer, current: { true })
        await model.send(c, canAuthor: { true }, now: r.expires.addingTimeInterval(-60)); await model.clear(c); XCTAssertNil(model.pending); XCTAssertEqual(peer.calls, [c]); XCTAssertTrue(io.encoded.isEmpty)
    }
    func testVaultCapacitySupports1000IdentityOnlyDecisions() async throws {
        let (_, _, _, c) = try fixture()
        let choices: [JSON] = (1...1000).map { n in .object(["project_id": .string(c.scope.roots[0]), "user_id": .string(String(format:"a0000000-0000-4000-8000-%012d",n)), "role": .null]) }
        var body = c.body; body["decisions"] = .array(choices)
        let big = try TeamProjectAdoptionCommand(account: c.account, origin: c.origin, body: body, projects: c.projects, assignmentsCleared: 0, invitationsClosed: 1000)
        XCTAssertGreaterThan(try JSONEncoder().encode(big).count, 20_000)
        let vault = TeamProjectAdoptionVault(io: AdoptionIO()); try await vault.begin(big, lease: CalendarReadLease())
        let saved = try await vault.pending(account: big.account, origin: big.origin); XCTAssertEqual(saved, big)
    }
    func testRemovalAndLeaseFencesProtectAdoptionRecovery() async throws {
        let (_, _, _, c) = try fixture(), io = AdoptionIO(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = TeamProjectAdoptionVault(io: io, removalDirectory: root)
        let lease = CalendarReadLease(); lease.cancel()
        do { try await vault.begin(c, lease: lease); XCTFail("Cancelled writer persisted") } catch {}
        try await vault.begin(c, lease: CalendarReadLease())
        do { try await vault.clear(c, lease: lease); XCTFail("Cancelled clear removed recovery") } catch {}
        let saved = try await vault.pending(account: c.account, origin: c.origin); XCTAssertEqual(saved, c)
        try AccountRemovalDisk(directory: root, account: c.account).removeCache()
        do { _ = try await vault.pending(account: c.account, origin: c.origin); XCTFail("Removed account read recovery") } catch {}
        do { try await vault.begin(c, lease: CalendarReadLease()); XCTFail("Removed account recreated recovery") } catch {}
        try await vault.removeAccount(c.account, origin: c.origin); XCTAssertTrue(io.encoded.isEmpty)
    }
    func testDifferentOriginAndAccountNeverShareRecovery() async throws {
        let (_, _, _, c) = try fixture(), io = AdoptionIO(), vault = TeamProjectAdoptionVault(io: io)
        try await vault.begin(c, lease: CalendarReadLease())
        let otherAccount = try await vault.pending(account: UUID().uuidString.lowercased(), origin: c.origin), otherOrigin = try await vault.pending(account: c.account, origin: "https://other.example")
        XCTAssertNil(otherAccount); XCTAssertNil(otherOrigin)
        try await vault.removeAccount(c.account, origin: "https://other.example")
        let saved = try await vault.pending(account: c.account, origin: c.origin); XCTAssertEqual(saved, c)
    }
    @MainActor func testClosingAnInFlightTransferKeepsOriginalRecovery() async throws {
        let (raw, _, r, c) = try fixture(), vault = TeamProjectAdoptionVault(io: AdoptionIO()), peer = AdoptionPeer(raw["receipt"]!.object)
        peer.hold = true; let model = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: vault, service: peer, current: { true })
        let work = Task { await model.send(c, canAuthor: { true }, now: r.expires.addingTimeInterval(-60)) }
        while peer.continuation == nil { await Task.yield() }
        model.close(); peer.continuation?.resume(); await work.value
        XCTAssertNil(model.receipt); let saved = try await vault.pending(account: c.account, origin: c.origin); XCTAssertEqual(saved, c)
    }
    @MainActor func testBackendUsesTheActualAdoptionProtocolAndSessionFence() async throws {
        let (raw, i, r, c) = try fixture()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AdoptionHTTP.self]
        let session = try JSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(c.account)\"}}".utf8))
        let api = Backend(configuration: ["URL": c.origin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        var operations: [String] = []
        AdoptionHTTP.handler = { request, peer in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_team_project_adoption"); XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store"); XCTAssertFalse(request.httpShouldHandleCookies)
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(contentsOf: bytes.prefix(n)) } }
            let body = try! JSONDecoder().decode([String: JSON].self, from: data), op = body["operation"]!.text; operations.append(op)
            XCTAssertEqual(Set(body.keys), ["operation", "body"])
            if op == "inspect" { XCTAssertEqual(body["body"], .object(i.scope.body)); peer.finish(raw["inspect"]!.object) }
            else if op == "review" { XCTAssertEqual(body["body"], .object(try! i.reviewBody(r.decisions))); peer.finish(raw["review"]!.object) }
            else { XCTAssertEqual(body["body"], .object(c.body)); peer.finish(raw["receipt"]!.object) }
        }; defer { AdoptionHTTP.handler = nil }
        let inspected = try await api.inspectProjectAdoption(i.scope); XCTAssertEqual(inspected, i)
        let reviewed = try await api.reviewProjectAdoption(i, decisions: r.decisions); XCTAssertEqual(reviewed, r)
        let receipt = try await api.adoptProjects(c); XCTAssertEqual(receipt.command, c)
        let foreign = try TeamProjectAdoptionCommand(account: UUID().uuidString.lowercased(), origin: c.origin, body: c.body, projects: c.projects, assignmentsCleared: c.assignmentsCleared, invitationsClosed: c.invitationsClosed)
        do { _ = try await api.adoptProjects(foreign); XCTFail("Foreign account sent") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(operations, ["inspect", "review", "adopt"])
    }

    @MainActor func testUnreadableRecoveryCannotStartAFreshTransfer() async throws {
        let (raw, _, r, c) = try fixture(), io = AdoptionIO(), vault = TeamProjectAdoptionVault(io: io), peer = AdoptionPeer(raw["receipt"]!.object)
        let key = TeamProjectAdoptionCommand.storagePrefix + c.account + "." + CalendarOAuthConfiguration.digest(c.origin)
        try io.write(Data("broken private recovery".utf8), key: key)
        let model = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: vault, service: peer, current: { true })
        await model.load(); XCTAssertFalse(model.recoveryLoaded)
        await model.send(c, canAuthor: { true }, now: r.expires.addingTimeInterval(-60))
        XCTAssertTrue(peer.calls.isEmpty); XCTAssertFalse(model.recoveryLoaded); XCTAssertTrue(io.encoded.contains("broken private recovery"))
    }

    func testArchivePreviewSeparatesOwnStateFromDestinationInheritance() throws {
        let (raw, i, _, _) = try fixture(); var response = raw["inspect"]!.object
        var rows = response["projects"]!.list, root = rows[0].object, child = rows[1].object
        root["source_ancestor_archived"] = .bool(true); root["is_archived"] = .bool(false)
        rows[0] = .object(root); response["projects"] = .array(rows)
        let detached = try TeamProjectAdoptionInspection(response, scope: i.scope)
        XCTAssertTrue(detached.projects[0].inherited); XCTAssertFalse(detached.inheritsArchiveAfter(detached.projects[0])); XCTAssertTrue(detached.projects[1].archived)
        root["is_archived"] = .bool(true); child["is_archived"] = .bool(false); child["source_ancestor_archived"] = .bool(true)
        response["projects"] = .array([.object(root),.object(child)])
        let withParent = try TeamProjectAdoptionInspection(response, scope: i.scope)
        XCTAssertTrue(withParent.inheritsArchiveAfter(withParent.projects[1]))
        root["is_archived"] = .bool(false); response["projects"] = .array([.object(root),.object(child)]); response["destination_archived"] = .bool(true)
        let archivedDestination = try TeamProjectAdoptionInspection(response, scope: i.scope)
        XCTAssertTrue(archivedDestination.inheritsArchiveAfter(archivedDestination.projects[0])); XCTAssertTrue(archivedDestination.inheritsArchiveAfter(archivedDestination.projects[1]))
    }

    func testActualSQLPausePolicyAndReceiptCounts() throws {
        let (raw,i,r,c)=try fixture(connections:true)
        XCTAssertTrue(i.hasConnections);XCTAssertTrue(i.supportsConnectionPause);XCTAssertTrue(i.connectionPauseSupported);XCTAssertFalse(i.commitSupported)
        XCTAssertTrue(r.canCommit);XCTAssertEqual(r.connectionPolicy,.pause);XCTAssertEqual(r.connectionEffects?.values,["email_routes_paused":1,"project_webhooks_paused":1,"pending_webhooks_cancelled":1,"global_webhooks_excluded":1,"queued_updates_discarded":2])
        XCTAssertEqual(c.body,raw["command"]!.object);XCTAssertEqual(try c.confirmed(raw["receipt"]!.object).command,c)
        XCTAssertEqual(try JSONDecoder().decode(TeamProjectAdoptionCommand.self,from:JSONEncoder().encode(c)),c)
    }
    func testPauseRequiresExplicitConsentAndMatchingSummary() throws {
        let (raw,i,r,_)=try fixture(connections:true)
        XCTAssertThrowsError(try TeamProjectAdoptionReview(raw["review"]!.object,inspection:i,decisions:r.decisions))
        var unchosen=raw["review"]!.object;unchosen["connection_policy"] = .null;unchosen["connection_effects"] = .null;unchosen["requires_integration_pause"] = .bool(true)
        let blocked=try TeamProjectAdoptionReview(unchosen,inspection:i,decisions:r.decisions)
        XCTAssertFalse(blocked.canCommit);XCTAssertThrowsError(try TeamProjectAdoptionCommand(review:blocked,now:blocked.expires.addingTimeInterval(-60)))
        for key in TeamProjectConnectionEffects.keys {
            var forged=raw["review"]!.object,values=forged["connection_effects"]!.object;values[key] = .number(Double(values[key]!.integer+1));forged["connection_effects"] = .object(values)
            XCTAssertThrowsError(try TeamProjectAdoptionReview(forged,inspection:i,decisions:r.decisions,connectionPolicy:.pause))
        }
    }
    func testPauseReceiptCannotHideActionsOrChangeCounts() throws {
        let (raw,_,_,c)=try fixture(connections:true)
        var absent=raw["receipt"]!.object;absent.removeValue(forKey:"connection_policy");XCTAssertThrowsError(try c.confirmed(absent))
        absent=raw["receipt"]!.object;absent.removeValue(forKey:"connection_effects");XCTAssertThrowsError(try c.confirmed(absent))
        for key in TeamProjectConnectionEffects.keys {
            var forged=raw["receipt"]!.object,values=forged["connection_effects"]!.object;values[key] = .number(999);forged["connection_effects"] = .object(values);XCTAssertThrowsError(try c.confirmed(forged))
        }
        let (old,_,_,legacy)=try fixture();var unexpected=old["receipt"]!.object;unexpected["connection_policy"] = .string("pause");unexpected["connection_effects"] = c.connectionEffects!.body
        XCTAssertThrowsError(try legacy.confirmed(unexpected))
    }
    func testPausePrivateCommandKeepsOnlyActionAndBoundedCounts() throws {
        let (_,_,_,c)=try fixture(connections:true),data=try JSONEncoder().encode(c),text=String(decoding:data,as:UTF8.self)
        XCTAssertTrue(text.contains("connection_policy"));XCTAssertTrue(text.contains("queued_updates_discarded"))
        for secret in ["Never put task text", "Workshop address", "receiver.example", "capture.example", "@example.invalid", "secret_envelope"] {XCTAssertFalse(text.contains(secret))}
        XCTAssertThrowsError(try TeamProjectAdoptionCommand(account:c.account,origin:c.origin,body:c.body,projects:c.projects,assignmentsCleared:c.assignmentsCleared,invitationsClosed:c.invitationsClosed))
        var unknown=c.body;unknown["connection_policy"] = .string("retarget")
        XCTAssertThrowsError(try TeamProjectAdoptionCommand(account:c.account,origin:c.origin,body:unknown,projects:c.projects,assignmentsCleared:c.assignmentsCleared,invitationsClosed:c.invitationsClosed,connectionEffects:c.connectionEffects))
        var malformed=c.connectionEffects!.body.object;malformed["queued_updates_discarded"] = .number(-1);XCTAssertThrowsError(try TeamProjectConnectionEffects(malformed))
        malformed=c.connectionEffects!.body.object;malformed["sender_email"] = .string("hidden@example.invalid");XCTAssertThrowsError(try TeamProjectConnectionEffects(malformed))
        var stored=try JSONDecoder().decode([String:JSON].self,from:data);stored["connectionEffects"] = .object(malformed)
        XCTAssertThrowsError(try JSONDecoder().decode(TeamProjectAdoptionCommand.self,from:JSONEncoder().encode(stored)))
    }
    @MainActor func testAppliedPauseReplyLossPreservesExactPolicyAcrossRelaunch() async throws {
        let (raw,_,r,c)=try fixture(connections:true),io=AdoptionIO(),vault=TeamProjectAdoptionVault(io:io),peer=AdoptionPeer(raw["receipt"]!.object);peer.lose=true
        let first=TeamProjectAdoptionModel(account:c.account,origin:c.origin,vault:vault,service:peer,current:{true})
        await first.send(c,canAuthor:{true},now:r.expires.addingTimeInterval(-60));XCTAssertEqual(first.pending?.connectionEffects,c.connectionEffects);first.close()
        let next=TeamProjectAdoptionModel(account:c.account,origin:c.origin,vault:TeamProjectAdoptionVault(io:io),service:peer,current:{true});await next.load();XCTAssertEqual(next.pending,c);await next.retry()
        XCTAssertEqual(peer.calls,[c,c]);XCTAssertEqual(next.receipt?.command.connectionEffects,c.connectionEffects);XCTAssertTrue(next.receipt?.replayed == true);XCTAssertNil(next.pending)
    }

    func testActualPausedConnectionStillLoadsInExistingSettingsDecoder() throws {
        let (raw,_,_,_)=try fixture(connections:true)
        let connection=try WebhookConnection(raw["connection_receipt"]!.object)
        XCTAssertEqual(connection.state,"paused");XCTAssertEqual(connection.delivery.error,"resource_unavailable");XCTAssertEqual(connection.delivery.pending,0)
        XCTAssertNil(connection.delivery.blocked)
    }

}
