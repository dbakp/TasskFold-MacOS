import XCTest
@testable import TaskfoldCore

private let tpAccount = "f07dcafe-0000-4000-8000-000000000001", tpOther = "f07dcafe-0000-4000-8000-000000000002"
private let tpTeam = "f07dcafe-0000-4000-8000-000000000011", tpProject = "f07dcafe-0000-4000-8000-000000000021"
private let tpOrigin = "https://backend.example"
private final class TeamProjectHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, TeamProjectHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() { Self.handler?(request, self) }
    func finish(_ data: Data, status: Int = 200) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json", "Content-Length":String(data.count)])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
private final class TeamProjectGate: @unchecked Sendable {
    private let lock = NSLock(); private var peer: TeamProjectHTTP?
    func hold(_ value: TeamProjectHTTP) { lock.lock(); peer = value; lock.unlock() }
    func release(_ data: Data) { lock.lock(); let value = peer; peer = nil; lock.unlock(); value?.finish(data) }
}
final class TeamProjectAccessTests: XCTestCase {
    private func row(_ role: String = "viewer") -> [String: JSON] {
        ["id":.string(tpProject),"team_id":.string(tpTeam),"revision":.number(2),"visibility":.string("private"),"folder_id":.null,"role":.string(role),"can_edit_tasks":.bool(false),"can_manage_access":.bool(role == "manager")]
    }
    private func page(_ rows: [[String:JSON]]? = nil) -> [String:JSON] {
        ["protocol":.number(1),"account":.string(tpAccount),"team_id":.string(tpTeam),"team_revision":.number(3),"team_state":.string("active"),"setup_paused":.bool(false),"task_writes_enabled":.bool(false),"projects":.array((rows ?? [row()]).map(JSON.object)),"next_cursor":.null]
    }
    private func detail() -> [String:JSON] { page().filter { !["task_writes_enabled","projects","next_cursor"].contains($0.key) }.merging(row()) { _,new in new } }
    func testRoleAndContextAreExplicitAndDoNotInferTaskEditing() throws {
        for role in ["manager","editor","viewer"] {
            let value = try TeamProjectPage(page([row(role)]), account: tpAccount, origin: tpOrigin, team: tpTeam, after: nil)
            XCTAssertEqual(value.projects[0].role.rawValue, role)
            XCTAssertFalse(value.projects[0].canEditTasks)
            XCTAssertEqual(value.projects[0].canManageAccess, role == "manager")
            XCTAssertTrue(value.projects[0].belongs(to:tpAccount,origin:tpOrigin,team:tpTeam))
            XCTAssertFalse(value.projects[0].belongs(to:tpOther,origin:tpOrigin,team:tpTeam))
            XCTAssertFalse(value.projects[0].belongs(to:tpAccount,origin:"https://other.example",team:tpTeam))
        }
    }
    func testUnknownRolesContradictoryCapabilitiesAndMalformedRevisionsFailClosed() {
        for change in [["role":JSON.string("owner")],["can_edit_tasks":.bool(true)],["can_manage_access":.bool(true)],["revision":.number(1.5)],["revision":.number(0)],["revision":.number(.infinity)],["folder_id":.string("")],["visibility":.string("public")],["team_id":.string(tpOther)]] {
            XCTAssertThrowsError(try TeamProjectPage(page([row().merging(change){_,new in new}]),account:tpAccount,origin:tpOrigin,team:tpTeam,after:nil))
        }
        for key in ["role","can_edit_tasks","can_manage_access","folder_id","revision"] {
            var missing = row(); missing.removeValue(forKey:key)
            XCTAssertThrowsError(try TeamProjectPage(page([missing]),account:tpAccount,origin:tpOrigin,team:tpTeam,after:nil))
        }
    }
    func testScopeProtocolAndPaginationCannotMisclassifyAWorkspace() throws {
        for change in [["protocol":JSON.number(2)],["account":.string(tpOther)],["team_id":.string(tpOther)],["team_state":.string("deleted")],["setup_paused":.null],["task_writes_enabled":.bool(true)],["next_cursor":.string(tpOther)]] {
            XCTAssertThrowsError(try TeamProjectPage(page().merging(change){_,new in new},account:tpAccount,origin:tpOrigin,team:tpTeam,after:nil))
        }
        XCTAssertThrowsError(try TeamProjectPage(page([row(),row()]),account:tpAccount,origin:tpOrigin,team:tpTeam,after:nil))
        XCTAssertThrowsError(try TeamProjectPage(page(),account:tpAccount,origin:tpOrigin,team:tpTeam,after:tpProject))
        var first = page(); first["next_cursor"] = .string(tpProject)
        XCTAssertNoThrow(try TeamProjectPage(first,account:tpAccount,origin:tpOrigin,team:tpTeam,after:nil,limit:1))
        XCTAssertThrowsError(try TeamProjectAccess(detail:detail(),account:tpAccount,origin:tpOrigin,team:tpTeam,project:tpOther))
    }
    func testDecodeActualOwnedPostgreSQLResponseContract() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource:"team-project-access-v1",withExtension:"json",subdirectory:"Fixtures"))
        let raw = try JSONDecoder().decode([String:JSON].self,from:Data(contentsOf:url))
        let account = try XCTUnwrap(raw["account"]?.text), team = try XCTUnwrap(raw["team"]?.text), project = try XCTUnwrap(raw["project"]?.text)
        guard case .object(let page)? = raw["page"],case .object(let detail)? = raw["detail"] else { return XCTFail("Missing real SQL envelopes") }
        let decoded = try TeamProjectPage(page,account:account,origin:tpOrigin,team:team,after:nil)
        let selected = try TeamProjectAccess(detail:detail,account:account,origin:tpOrigin,team:team,project:project)
        XCTAssertEqual(decoded.projects.map(\.id),[project]); XCTAssertEqual(selected.role,.editor); XCTAssertFalse(selected.canEditTasks)
    }
    @MainActor private func backend(_ account: String = tpAccount) throws -> Backend {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [TeamProjectHTTP.self]
        let session = try JSONDecoder().decode(Session.self,from:Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(account)\"}}".utf8))
        return Backend(configuration:["URL":tpOrigin,"Key":"synthetic-public"],http:URLSession(configuration:configuration),session:session,persistSession:{_ in})
    }
    @MainActor func testNativeReadUsesBoundedUncachedAccountScopedEndpoint() async throws {
        let api = try backend(), reply = try JSONEncoder().encode(page()); var calls = 0
        TeamProjectHTTP.handler = { request,peer in
            calls += 1; XCTAssertEqual(request.url?.path,"/rest/v1/rpc/taskfold_team_projects"); XCTAssertEqual(request.httpMethod,"POST")
            XCTAssertEqual(request.value(forHTTPHeaderField:"Cache-Control"),"no-store"); XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.timeoutInterval,25); peer.finish(reply)
        }; defer { TeamProjectHTTP.handler = nil }
        let page = try await api.teamProjectPage(team:tpTeam,account:tpAccount,origin:tpOrigin)
        XCTAssertEqual(page.projects[0].id,tpProject); XCTAssertEqual(calls,1)
        do { _ = try await api.teamProjectPage(team:tpTeam,account:tpOther,origin:tpOrigin); XCTFail("Foreign account sent") } catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await api.teamProjectPage(team:tpTeam,account:tpAccount,origin:"https://other.example"); XCTFail("Foreign origin sent") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls,1)
    }
    @MainActor func testLateReplyCannotReachAnotherAccount() async throws {
        let api = try backend(), next = try backend(tpOther), gate = TeamProjectGate(), started = expectation(description:"Original read held")
        let reply = try JSONEncoder().encode(page())
        TeamProjectHTTP.handler = { _,peer in gate.hold(peer); started.fulfill() }; defer { TeamProjectHTTP.handler = nil }
        let pending = Task { @MainActor in try await api.teamProjectPage(team:tpTeam,account:tpAccount,origin:tpOrigin) }
        await fulfillment(of:[started],timeout:3); try await api.accept(XCTUnwrap(next.session)); gate.release(reply)
        do { _ = try await pending.value; XCTFail("Late project access escaped its account") } catch { XCTAssertTrue(error is CancellationError) }
    }
    @MainActor func testConfirmedAccessLossIsDistinctFromUnavailableServerContract() async throws {
        let api = try backend(); defer { TeamProjectHTTP.handler = nil }
        TeamProjectHTTP.handler = { _,peer in peer.finish(Data("{\"code\":\"PT404\"}".utf8),status:404) }
        do { _ = try await api.teamProjectPage(team:tpTeam,account:tpAccount,origin:tpOrigin); XCTFail("Revoked scope accepted") } catch { XCTAssertTrue(error is TeamProjectAccessUnavailable) }
        TeamProjectHTTP.handler = { _,peer in peer.finish(Data("{\"code\":\"PGRST202\",\"message\":\"private server details\"}".utf8),status:404) }
        do { _ = try await api.teamProjectPage(team:tpTeam,account:tpAccount,origin:tpOrigin); XCTFail("Missing contract accepted") } catch { XCTAssertFalse(error is TeamProjectAccessUnavailable); XCTAssertFalse(error.localizedDescription.contains("private server details")) }
    }
    @MainActor func testOversizedAndUnauthorizedRepliesRemainUnconfirmed() async throws {
        let api = try backend(); defer { TeamProjectHTTP.handler = nil }
        TeamProjectHTTP.handler = { _,peer in peer.finish(Data(repeating:32,count:256001)) }
        do { _ = try await api.teamProjectPage(team:tpTeam,account:tpAccount,origin:tpOrigin); XCTFail("Oversized response accepted") } catch { XCTAssertFalse(error is CancellationError) }
        TeamProjectHTTP.handler = { _,peer in peer.finish(Data("{\"code\":\"28000\",\"message\":\"private server details\"}".utf8),status:403) }
        do { _ = try await api.teamProjectPage(team:tpTeam,account:tpAccount,origin:tpOrigin); XCTFail("Expired session accepted") } catch { XCTAssertTrue(error is AccountSessionAuthorizationRequired) }
    }
    private func hierarchyReply(parent: String? = tpOther) -> [String: JSON] {
        ["protocol": .number(1), "project_hierarchy_protocol": .number(1), "account": .string(tpAccount), "team_id": .string(tpTeam), "id": .string(tpProject), "operation": .string("move"), "team_revision": .number(3), "revision": .number(2), "parent_id": parent.map(JSON.string) ?? .null, "parent_revision": parent == nil ? .null : .number(1), "tree_token": .string(String(repeating: "a", count: 64)), "affected_count": .number(2), "destination_archived": .bool(false), "is_archived": .bool(false)]
    }
    @MainActor func testHierarchyHTTPReviewChecksRequestedDestinationBeforeReturning() async throws {
        let api = try backend(); var calls = 0
        TeamProjectHTTP.handler = { request, peer in
            calls += 1
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_team_projects")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertEqual(request.timeoutInterval, 25)
            peer.finish(try! JSONEncoder().encode(self.hierarchyReply()))
        }; defer { TeamProjectHTTP.handler = nil }
        let reviewed = try await api.teamProjectHierarchyReview(team: tpTeam, project: tpProject, parent: tpOther, action: .move, account: tpAccount, origin: tpOrigin)
        XCTAssertEqual(reviewed.parent, tpOther)
        do { _ = try await api.teamProjectHierarchyReview(team: tpTeam, project: tpProject, parent: nil, action: .move, account: tpAccount, origin: tpOrigin); XCTFail("Wrong destination accepted") } catch {}
        do { _ = try await api.teamProjectHierarchyReview(team: tpTeam, project: tpProject, parent: tpOther, action: .move, account: tpOther, origin: tpOrigin); XCTFail("Wrong account sent") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 2)
    }
    @MainActor func testHierarchyReviewCannotReturnAfterAccountChanges() async throws {
        let api = try backend(), next = try backend(tpOther), gate = TeamProjectGate(), started = expectation(description: "Hierarchy review held")
        let reply = try JSONEncoder().encode(hierarchyReply())
        TeamProjectHTTP.handler = { _, peer in gate.hold(peer); started.fulfill() }; defer { TeamProjectHTTP.handler = nil }
        let pending = Task { @MainActor in try await api.teamProjectHierarchyReview(team: tpTeam, project: tpProject, parent: tpOther, action: .move, account: tpAccount, origin: tpOrigin) }
        await fulfillment(of: [started], timeout: 3); try await api.accept(XCTUnwrap(next.session)); gate.release(reply)
        do { _ = try await pending.value; XCTFail("Late hierarchy review escaped") } catch { XCTAssertTrue(error is CancellationError) }
    }

}
