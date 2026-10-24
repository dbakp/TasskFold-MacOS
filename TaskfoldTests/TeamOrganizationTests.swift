import XCTest
@testable import TaskfoldCore

private let orgAccount = "ea300000-0000-4000-8000-000000000001"
private let orgTeam = "ea300000-0000-4000-8000-000000000002"
private let orgOther = "ea300000-0000-4000-8000-000000000003"
private let orgOrigin = "https://backend.example"
private final class OrganizationHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, OrganizationHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() { Self.handler?(request, self) }
    func finish(_ raw: [String: JSON], status: Int = 200) {
        let data = try! JSONEncoder().encode(raw)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
private final class OrganizationReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var peer: OrganizationHTTP?
    func hold(_ value: OrganizationHTTP) { lock.lock(); peer = value; lock.unlock() }
    func release(_ value: [String: JSON]) { lock.lock(); let valuePeer = peer; peer = nil; lock.unlock(); valuePeer?.finish(value) }
}
final class TeamOrganizationTests: XCTestCase {
    func row(_ role: String = "owner") -> [String: JSON] { ["id": .string(orgTeam), "name": .string("Design studio"), "state": .string("active"), "revision": .number(3), "role": .string(role)] }
    func list(_ rows: [[String: JSON]]? = nil) -> [String: JSON] { ["enabled": .bool(false), "teams": .array((rows ?? [row()]).map(JSON.object))] }
    var emptyInvites: [String: JSON] { ["enabled": .bool(false), "invitations": .array([])] }
    func detail(_ role: String = "owner") -> [String: JSON] {
        var raw = row(role)
        if role != "guest" { raw["folders"] = .array([]) }
        if ["owner", "admin"].contains(role) {
            var members: [JSON] = [.object(["user_id": .string(role == "owner" ? orgAccount : orgOther), "role": .string("owner")])]
            if role == "admin" { members.append(.object(["user_id": .string(orgAccount), "role": .string("admin")])) }
            raw["members"] = .array(members); raw["invitations"] = .array([])
        }
        return raw
    }
    func decode(_ raw: [String: JSON]) throws -> TeamOrganizationDetail { try .init(raw, team: orgTeam, account: orgAccount, origin: orgOrigin) }
    func overview(_ raw: [String: JSON]? = nil) throws -> TeamOrganizationOverview { try .init(list: raw ?? list(), invitations: emptyInvites, account: orgAccount, origin: orgOrigin) }
    func testAllRolesAndArchivedTeamsAreRepresentedWithoutTaskPermissions() throws {
        for role in TeamOrganizationRole.allCases {
            let parsed = try decode(detail(role.rawValue))
            XCTAssertEqual(parsed.team.role, role)
            XCTAssertEqual(parsed.members.isEmpty, !role.directoryVisible)
        }
        var archived = row(); archived["state"] = .string("archived")
        XCTAssertTrue(try overview(list([archived])).teams[0].archived)
        XCTAssertFalse(try overview().enabled)
    }
    func testUnknownRolesStatesAndInvalidRevisionFailClosed() {
        for changes in [["role": JSON.string("manager")], ["state": .string("deleted")], ["revision": .number(0)], ["revision": .number(1.5)], ["id": .string("00000000-0000-0000-0000-000000000000")], ["name": .string(" ")], ["name": .string("bad\nname")], ["name": .string(String(repeating: "a", count: 101))]] {
            XCTAssertThrowsError(try overview(list([row().merging(changes) { _, b in b }])))
        }
        XCTAssertThrowsError(try overview(list([row(), row()])))
        XCTAssertThrowsError(try overview(list(Array(repeating: row(), count: 101))))
    }
    func testServerPauseMismatchAndOriginCannotPublish() {
        var invites = emptyInvites; invites["enabled"] = .bool(true)
        XCTAssertThrowsError(try TeamOrganizationOverview(list: list(), invitations: invites, account: orgAccount, origin: orgOrigin))
        for origin in ["http://backend.example", "https://backend.example/", "https://backend.example/path", "https://a@backend.example", "https://backend.example?x=1"] {
            XCTAssertThrowsError(try TeamOrganizationOverview(list: list(), invitations: emptyInvites, account: orgAccount, origin: origin))
        }
        XCTAssertThrowsError(try TeamOrganizationOverview(list: list(), invitations: emptyInvites, account: "ui-testing", origin: orgOrigin))
    }
    func testDirectoriesCannotLeakThroughLowerRoleResponses() {
        for role in ["guest", "member"] {
            for key in ["members", "invitations"] {
                var raw = detail(role); raw[key] = .array([])
                XCTAssertThrowsError(try decode(raw))
            }
        }
        var guest = detail("guest"); guest["folders"] = .array([])
        XCTAssertThrowsError(try decode(guest))
    }
    func testDirectoryMustContainExactlyOneOwnerAndCurrentActorRole() {
        for members: [JSON] in [[], [.object(["user_id": .string(orgOther), "role": .string("owner")])], [.object(["user_id": .string(orgAccount), "role": .string("owner")]), .object(["user_id": .string(orgOther), "role": .string("owner")])]] {
            var raw = detail(); raw["members"] = .array(members); XCTAssertThrowsError(try decode(raw))
        }
        var raw = detail("admin"); raw["role"] = .string("owner"); XCTAssertThrowsError(try decode(raw))
    }
    func testFoldersPreserveServerOrderAndRejectDuplicatesOrOversizePosition() throws {
        let a: [String: JSON] = ["id": .string(orgAccount), "name": .string("Product"), "position": .number(0)]
        let b: [String: JSON] = ["id": .string(orgOther), "name": .string("Launch"), "position": .number(1)]
        var raw = detail(); raw["folders"] = .array([.object(a), .object(b)])
        XCTAssertEqual(try decode(raw).folders.map(\.name), ["Product", "Launch"])
        for folders in [[b, a], [a, a], [a.merging(["position": .number(1_000_001)]) { _, b in b }]] {
            raw["folders"] = .array(folders.map(JSON.object)); XCTAssertThrowsError(try decode(raw))
        }
    }
    func testInvitationsValidateIdentityRoleExpiryAndDuplicates() throws {
        let invitation: [String: JSON] = ["id": .string(orgOther), "team_id": .string(orgTeam), "team_name": .string("Studio"), "role": .string("member"), "expires_at": .string("2030-10-24T10:00:00.123456+00:00"), "team_revision": .number(3)]
        var offers = emptyInvites; offers["invitations"] = .array([.object(invitation)])
        XCTAssertEqual(try TeamOrganizationOverview(list: list(), invitations: offers, account: orgAccount, origin: orgOrigin).invitations[0].role, .member)
        for changes in [["role": JSON.string("owner")], ["expires_at": .string("tomorrow")], ["team_revision": .number(-1)]] {
            offers["invitations"] = .array([.object(invitation.merging(changes) { _, b in b })]); XCTAssertThrowsError(try TeamOrganizationOverview(list: list(), invitations: offers, account: orgAccount, origin: orgOrigin))
        }
        offers["invitations"] = .array([.object(invitation), .object(invitation)]); XCTAssertThrowsError(try TeamOrganizationOverview(list: list(), invitations: offers, account: orgAccount, origin: orgOrigin))
    }
    func testTransferOnlyVisibleToOwnerOrRecipientAndTeamMustMatch() {
        var raw = detail("member"); raw["transfer"] = .object(["id": .string(orgOther), "target_id": .string(orgOther), "expires_at": .string("2030-10-24T10:00:00Z")])
        XCTAssertThrowsError(try decode(raw))
        raw["transfer"] = .object(["id": .string(orgOther), "target_id": .string(orgAccount), "expires_at": .string("2030-10-24T10:00:00Z")]); XCTAssertNoThrow(try decode(raw))
        XCTAssertThrowsError(try TeamOrganizationDetail(detail(), team: orgOther, account: orgAccount, origin: orgOrigin))
    }
    @MainActor func testBrowserDiscardsDelayedAccountSwitchResponseAndClearsDirectory() async throws {
        let reply = try overview(); var current = true
        var continuation: CheckedContinuation<TeamOrganizationOverview, Never>?
        let browser = TeamOrganizationBrowser(account: orgAccount, origin: orgOrigin, current: { current }, overview: { await withCheckedContinuation { continuation = $0 } }, detail: { _ in try self.decode(self.detail()) })
        let job = Task { await browser.refresh() }
        while continuation == nil { await Task.yield() }
        current = false; browser.invalidate(); continuation?.resume(returning: reply); await job.value
        XCTAssertNil(browser.overview); XCTAssertNil(browser.detail); XCTAssertFalse(browser.loading)
    }
    @MainActor func testRefreshClearsOldSensitiveContentBeforeFetchingAndRefusesForeignResult() async throws {
        var foreign = false
        let browser = TeamOrganizationBrowser(account: orgAccount, origin: orgOrigin, current: { true }, overview: {
            try TeamOrganizationOverview(list: self.list(), invitations: self.emptyInvites, account: foreign ? orgOther : orgAccount, origin: orgOrigin)
        }, detail: { _ in try self.decode(self.detail()) })
        await browser.refresh(); XCTAssertNotNil(browser.overview)
        await browser.refresh(team: orgTeam); XCTAssertNotNil(browser.detail); XCTAssertNil(browser.overview)
        foreign = true; await browser.refresh(); XCTAssertNil(browser.overview); XCTAssertNil(browser.detail)
    }
    @MainActor func backend() throws -> Backend {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OrganizationHTTP.self]
        let session = try JSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(orgAccount)\"}}".utf8))
        return Backend(configuration: ["URL": orgOrigin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
    }
    @MainActor func testBackendUsesReadOnlyUncachedScopedOrganizationRPC() async throws {
        let api = try backend(); var actions: [String] = []
        OrganizationHTTP.handler = { request, peer in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_teams"); XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store"); XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.timeoutInterval, 25)
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
            }
            let raw = try! JSONDecoder().decode([String: JSON].self, from: data)
            let action = raw["_action"]!.text; actions.append(action)
            peer.finish(action == "list" ? self.list() : action == "get" ? self.detail() : self.emptyInvites)
        }; defer { OrganizationHTTP.handler = nil }
        let overview = try await api.teamOrganizationOverview(account: orgAccount, origin: orgOrigin)
        XCTAssertEqual(overview.teams.count, 1)
        let detail = try await api.teamOrganizationDetail(team: orgTeam, account: orgAccount, origin: orgOrigin); XCTAssertEqual(detail.team.role, .owner)
        for (account, origin) in [(orgOther, orgOrigin), (orgAccount, "https://other.example")] {
            do { _ = try await api.teamOrganizationOverview(account: account, origin: origin); XCTFail("Foreign scope sent") } catch { XCTAssertTrue(error is CancellationError) }
        }
        XCTAssertEqual(actions, ["list", "invitations", "get"])
    }
    @MainActor func testLateReadAfterReauthenticationCannotPublishOrStartSecondRead() async throws {
        let api = try backend(), replacement = try backend(), gate = OrganizationReadGate()
        let started = expectation(description: "Organization list read held")
        var count = 0
        OrganizationHTTP.handler = { _, peer in count += 1; gate.hold(peer); started.fulfill() }
        defer { OrganizationHTTP.handler = nil }
        let pending = Task { try await api.teamOrganizationOverview(account: orgAccount, origin: orgOrigin) }
        await fulfillment(of: [started], timeout: 3)
        try await api.accept(XCTUnwrap(replacement.session))
        gate.release(list())
        do { _ = try await pending.value; XCTFail("Read survived a new session") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(count, 1)
    }
    @MainActor func testMissingServiceAndInvalidSessionNeverPublishRawServerErrors() async throws {
        let api = try backend()
        defer { OrganizationHTTP.handler = nil }
        for (code, expectedAuth) in [("PGRST202", false), ("28000", true)] {
            OrganizationHTTP.handler = { _, peer in peer.finish(["code": .string(code), "message": .string("private server details")], status: 404) }
            do { _ = try await api.teamOrganizationOverview(account: orgAccount, origin: orgOrigin); XCTFail("Rejected read accepted") }
            catch { XCTAssertEqual(error is AccountSessionAuthorizationRequired, expectedAuth); XCTAssertFalse(error.localizedDescription.contains("private server details")) }
        }
    }
    func testActualPostgreSQLRoleContract() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-organization-overview-v1", withExtension: "json", subdirectory: "Fixtures"))
        let raw = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        for role in ["owner", "admin", "member", "guest"] {
            let actor = raw[role]!.object
            let overview = try TeamOrganizationOverview(list: actor["list"]!.object, invitations: actor["invitations"]!.object, account: actor["account"]!.text, origin: orgOrigin)
            XCTAssertEqual(overview.teams.count, 1)
            let detail = try TeamOrganizationDetail(actor["detail"]!.object, team: raw["team"]!.text, account: actor["account"]!.text, origin: orgOrigin)
            XCTAssertEqual(detail.team.role.rawValue, role)
            XCTAssertEqual(detail.folders.count, role == "guest" ? 0 : 1)
        }
    }
}
