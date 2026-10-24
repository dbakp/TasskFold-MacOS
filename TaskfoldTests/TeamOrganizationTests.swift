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
    func testDirectoryIdentitySupportsOldAndNewServiceWithoutGuessingNames() throws {
        let legacy = try decode(detail()).members[0]
        XCTAssertNil(legacy.displayName); XCTAssertNil(legacy.verifiedEmail)
        XCTAssertEqual(legacy.subtitle(account: orgOther), "Profile not shared")
        XCTAssertEqual(legacy.title(account: orgAccount), "You")
        XCTAssertEqual(legacy.title(account: orgOther), "Member \(orgAccount.suffix(8))")
        var raw = detail()
        raw["members"] = .array([.object(["user_id": .string(orgAccount), "role": .string("owner"), "display_name": .string("Sam Chen"), "verified_email": .string("sam@example.invalid")])])
        let member = try decode(raw).members[0]
        XCTAssertEqual(member.title(account: orgOther), "Sam Chen")
        XCTAssertEqual(member.reference, "sam@example.invalid")
        XCTAssertEqual(member.subtitle(account: orgOther), "sam@example.invalid")
        let emailOnly = TeamOrganizationDetail.Member(id: orgOther, role: .member, verifiedEmail: "sam@example.invalid")
        XCTAssertEqual(emailOnly.title(account: orgAccount), "sam@example.invalid")
        XCTAssertEqual(emailOnly.subtitle(account: orgAccount), "Confirmed email")
        XCTAssertEqual(member.title(account: orgAccount), "You")
    }
    func testDirectoryIdentityHidesMisleadingOrMalformedPresentationWithoutLosingRoster() throws {
        for key in ["display_name", "verified_email"] {
            for value: JSON in [.number(1), .bool(true), .string(""), .string(" padded "), .string("bad\nname"), .string("bad\u{202E}name"), .string("bad\u{2066}name"), .string(String(repeating: "a", count: 1020))] {
                var raw = detail()
                raw["members"] = .array([.object(["user_id": .string(orgAccount), "role": .string("owner"), key: value])])
                let member = try decode(raw).members[0]
                XCTAssertNil(key == "display_name" ? member.displayName : member.verifiedEmail)
                XCTAssertEqual(member.id, orgAccount)
            }
        }
        for value in ["not-email", "a@@b", "a@b c", "a@b\u{00A0}c"] {
            XCTAssertNil(TeamOrganizationDetail.Member.identity(.string(value), email: true))
        }
        XCTAssertEqual(TeamOrganizationDetail.Member.identity(.string("Zoë 陳 👩🏽‍💻")), "Zoë 陳 👩🏽‍💻")
        XCTAssertNil(TeamOrganizationDetail.Member.identity(.null))
    }
    func testDirectoryDuplicateNamesKeepFullDistinctReferencesAndCommands() throws {
        var raw = detail()
        raw["members"] = .array([
            .object(["user_id": .string(orgAccount), "role": .string("owner"), "display_name": .string("Sam Chen"), "verified_email": .string("owner@example.invalid")]),
            .object(["user_id": .string(orgOther), "role": .string("member"), "display_name": .string("Sam Chen"), "verified_email": .string("other@example.invalid")])])
        let members = try decode(raw).members
        XCTAssertEqual(members.map { $0.title(account: orgTeam) }, ["Sam Chen", "Sam Chen"])
        XCTAssertNotEqual(members[0].reference, members[1].reference)
        let command = try TeamOrganizationCommand(account: orgAccount, origin: orgOrigin, action: .removeMember, team: orgTeam, revision: 3, user: members[1].id)
        XCTAssertEqual(command.body["user_id"], .string(orgOther))
        XCTAssertNil(command.body["display_name"]); XCTAssertNil(command.body["verified_email"])
    }
    func testActualPostgreSQLDirectoryIdentityContract() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-directory-v1", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        for role in ["owner", "admin", "member", "guest"] {
            let actor = fixture[role]!.object
            let value = try TeamOrganizationDetail(actor["detail"]!.object, team: fixture["team"]!.text, account: actor["account"]!.text, origin: orgOrigin)
            XCTAssertEqual(value.team.role.rawValue, role)
            if value.team.role.directoryVisible {
                XCTAssertEqual(value.members.count, 4)
                XCTAssertEqual(value.members.filter { $0.displayName == "Sam Chen" }.count, 2)
                XCTAssertEqual(Set(value.members.compactMap(\.verifiedEmail)).count, 4)
            } else { XCTAssertTrue(value.members.isEmpty) }
        }
    }
    @MainActor func testDirectoryNamesDisappearWhileRefreshAndAfterRoleLoss() async throws {
        var lower = false
        var suspended: CheckedContinuation<TeamOrganizationOverview, Never>?
        let browser = TeamOrganizationBrowser(account: orgAccount, origin: orgOrigin, current: { true }, overview: {
            if lower { return await withCheckedContinuation { suspended = $0 } }
            return try self.overview()
        }, detail: { _ in
            var raw = self.detail(lower ? "member" : "owner")
            if !lower { raw["members"] = .array([.object(["user_id": .string(orgAccount), "role": .string("owner"), "display_name": .string("Private profile"), "verified_email": .string("private@example.invalid")])]) }
            return try self.decode(raw)
        })
        await browser.refresh(team: orgTeam)
        XCTAssertEqual(browser.detail?.members[0].displayName, "Private profile")
        lower = true
        let job = Task { await browser.refresh(team: orgTeam) }
        while suspended == nil { await Task.yield() }
        XCTAssertNil(browser.detail)
        suspended?.resume(returning: try overview()); await job.value
        XCTAssertEqual(browser.detail?.team.role, .member)
        XCTAssertTrue(browser.detail?.members.isEmpty == true)
    }

    @MainActor func testLateDirectoryIdentityAfterAccountChangeCannotReappear() async throws {
        var raw = detail()
        raw["members"] = .array([.object(["user_id": .string(orgAccount), "role": .string("owner"), "display_name": .string("Private profile"), "verified_email": .string("private@example.invalid")])])
        let oldReply = try decode(raw)
        var current = true
        var suspended: CheckedContinuation<TeamOrganizationDetail, Never>?
        let browser = TeamOrganizationBrowser(account: orgAccount, origin: orgOrigin, current: { current }, overview: { try self.overview() }, detail: { _ in await withCheckedContinuation { suspended = $0 } })
        let job = Task { await browser.refresh(team: orgTeam) }
        while suspended == nil { await Task.yield() }
        current = false; browser.invalidate()
        suspended?.resume(returning: oldReply); await job.value
        XCTAssertNil(browser.detail); XCTAssertNil(browser.overview); XCTAssertFalse(browser.loading)
    }

}
