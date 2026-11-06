import XCTest
@testable import TaskfoldCore

private func destinationID(_ n: Int) -> String { String(format: "ec270000-0000-4000-8000-%012d", n) }
private final class WorkflowReadHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, WorkflowReadHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func finish(_ value: JSON, length: Int? = nil) {
        var headers = ["Content-Type": "application/json"]; if let length { headers["Content-Length"] = String(length) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(value)); client?.urlProtocolDidFinishLoading(self)
    }
}
final class TeamWorkflowDestinationsTests: XCTestCase {
    let f = TeamWorkflowRunTests()
    func teamRaw(name: String = "Studio") -> [String: JSON] { ["id": .string(f.teamID), "name": .string(name), "role": .string("member"), "state": .string("active"), "revision": .number(1)] }
    func overview() throws -> TeamOrganizationOverview { try .init(list: ["enabled": .bool(true), "teams": .array([.object(teamRaw())])], invitations: ["enabled": .bool(true), "invitations": .array([])], account: f.account, origin: f.origin) }
    func detail() throws -> TeamOrganizationDetail { var raw = teamRaw(); raw["folders"] = .array([]); return try .init(raw, team: f.teamID, account: f.account, origin: f.origin) }
    func page(_ ids: [Int], after: String? = nil, next: Bool = false, revision: Double = 1) throws -> TeamProjectPage {
        let rows: [JSON] = ids.map { .object(["id": .string(destinationID($0)), "team_id": .string(f.teamID), "revision": .number(1), "role": .string("editor"), "visibility": .string("team"), "folder_id": .null, "can_edit_tasks": .bool(false), "can_manage_access": .bool(false), "project_state_protocol": .number(1), "is_archived": .bool(false), "ancestor_archived": .bool(false), "project_hierarchy_protocol": .number(1), "parent_id": .null, "parent_unavailable": .bool(false)]) }
        return try .init(["protocol": .number(1), "account": .string(f.account), "team_id": .string(f.teamID), "team_revision": .number(revision), "team_state": .string("active"), "setup_paused": .bool(false), "task_writes_enabled": .bool(false), "projects": .array(rows), "next_cursor": next ? .string(destinationID(ids.last!)) : .null], account: f.account, origin: f.origin, team: f.teamID, after: after)
    }
    @MainActor func browser(current: @escaping () -> Bool = { true }, fence: @escaping () async throws -> String = { String(repeating: "a", count: 64) }, page: @escaping (String, String?) async throws -> TeamProjectPage) -> TeamWorkflowDestinations {
        .init(account: f.account, origin: f.origin, current: current, fence: fence, overview: { try self.overview() }, team: { _ in try self.detail() }, page: page)
    }
    @MainActor func testCompletePaginationPublishesOneCoherentCatalog() async throws {
        let b = browser { _, after in try self.page(after == nil ? Array(1...50) : [51], after: after, next: after == nil) }
        await b.load(team: f.teamID); XCTAssertEqual(b.projects.count, 51); XCTAssertNotNil(b.organization); XCTAssertNotNil(b.overview); XCTAssertNil(b.message)
    }
    @MainActor func testLaterPageFailurePublishesNoPartialNames() async throws {
        let b = browser { _, after in if after != nil { throw URLError(.notConnectedToInternet) }; return try self.page(Array(1...50), next: true) }
        await b.load(team: f.teamID); XCTAssertTrue(b.projects.isEmpty); XCTAssertNil(b.organization); XCTAssertNil(b.overview); XCTAssertNotNil(b.message)
    }
    @MainActor func testChangedFenceAndPageRevisionCannotPublishDestinations() async throws {
        var reads = 0
        let changed = browser(fence: { reads += 1; return String(repeating: reads == 1 ? "a" : "b", count: 64) }) { _, _ in try self.page([1]) }
        await changed.load(team: f.teamID); XCTAssertNil(changed.overview); XCTAssertTrue(changed.projects.isEmpty)
        let stale = browser { _, _ in try self.page([1], revision: 2) }
        await stale.load(team: f.teamID); XCTAssertNil(stale.overview); XCTAssertTrue(stale.projects.isEmpty)
    }
    @MainActor func testSupersededReadCannotReplaceNewerCatalog() async throws {
        var held: CheckedContinuation<Void, Never>?, calls = 0
        let b = browser { _, _ in calls += 1; let id = calls; if id == 1 { await withCheckedContinuation { held = $0 } }; return try self.page([id]) }
        let old = Task { await b.load(team: f.teamID) }; while held == nil { await Task.yield() }
        await b.load(team: f.teamID); held?.resume(); await old.value
        XCTAssertEqual(b.projects.map(\.id), [destinationID(2)]); XCTAssertFalse(b.loading)
    }
    @MainActor func testAccountInvalidationDuringReadPublishesNothing() async throws {
        var current = true
        let b = browser(current: { current }) { _, _ in current = false; return try self.page([1]) }
        await b.load(team: f.teamID); XCTAssertNil(b.overview); XCTAssertTrue(b.projects.isEmpty)
    }
    @MainActor func testOnlyKnownActiveEditableProjectsAreEligible() throws {
        XCTAssertTrue(TeamWorkflowDestinations.editable(try f.access()))
        XCTAssertFalse(TeamWorkflowDestinations.editable(try page([1]).projects[0]))
        for access in [try f.access(role: "viewer"), try f.access(archived: true), try f.access(inherited: true), try f.access(paused: true), try f.access(legacy: true)] { XCTAssertFalse(TeamWorkflowDestinations.editable(access)) }
    }
    @MainActor func backend() throws -> Backend {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WorkflowReadHTTP.self]
        let session = try JSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(f.account)\"}}".utf8))
        return Backend(configuration: ["URL": f.origin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
    }
    @MainActor func testPrivateSourceReadIsFilteredBoundedAndScoped() async throws {
        let api = try backend(), source = try f.source()
        guard case .personal(let row) = source else { return XCTFail() }
        WorkflowReadHTTP.handler = { request, peer in
            XCTAssertEqual(request.url?.path, "/rest/v1/project_templates"); XCTAssertFalse(request.httpShouldHandleCookies); XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            let values = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            XCTAssertEqual(values["id"], "eq." + self.f.templateID); XCTAssertEqual(values["user_id"], "eq." + self.f.account); XCTAssertEqual(values["limit"], "1")
            peer.finish(.array([.object(row.fields)]))
        }
        defer { WorkflowReadHTTP.handler = nil }
        let result = try await api.workflowPersonalSource(id: f.templateID, account: f.account, origin: f.origin); XCTAssertEqual(result, source)
        WorkflowReadHTTP.handler = { _, peer in peer.finish(.array([.object(row.fields)]), length: 3_000_001) }
        do { _ = try await api.workflowPersonalSource(id: f.templateID, account: f.account, origin: f.origin); XCTFail("Oversized") } catch {}
    }
    @MainActor func plan(_ api: Backend) throws -> TeamWorkflowRunPlan { try .init(source: f.source(), account: f.account, origin: f.origin, team: f.team(), destination: .newProject(.team), name: "Launch", workspace: f.workspace, session: api.reminderSessionIncarnation) }
    @MainActor func testFreshOrderReadKeepsMissingGroupsEmptyAndRefusesForeignRows() async throws {
        let api = try backend(), plan = try plan(api), keys = plan.orders.map { "group:" + $0.project + ":" + ($0.section ?? "none") }
        let id = destinationID(99), row: JSON = .object(["id": .string(keys[0]), "user_id": .string(f.account), "ids": .array([.string(id)])])
        WorkflowReadHTTP.handler = { request, peer in
            XCTAssertEqual(request.url?.path, "/rest/v1/view_orders"); XCTAssertFalse(request.httpShouldHandleCookies)
            let values = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            XCTAssertEqual(values["user_id"], "eq." + self.f.account); XCTAssertTrue(values["id"]!.contains(keys[0])); peer.finish(.array([row]))
        }
        defer { WorkflowReadHTTP.handler = nil }
        let result = try await api.workflowBaseOrders(plan); XCTAssertEqual(result[keys[0]], [id]); XCTAssertEqual(result[keys[1]], [])
        var foreign = row.object; foreign["user_id"] = .string(f.teamID)
        WorkflowReadHTTP.handler = { _, peer in peer.finish(.array([.object(foreign)])) }
        do { _ = try await api.workflowBaseOrders(plan); XCTFail("Foreign order") } catch {}
        WorkflowReadHTTP.handler = { _, peer in peer.finish(.array([row, row])) }
        do { _ = try await api.workflowBaseOrders(plan); XCTFail("Duplicate order") } catch {}
    }
    @MainActor func testLateSourceReadAfterSignOutIsRejected() async throws {
        let api = try backend(); var held: WorkflowReadHTTP?; WorkflowReadHTTP.handler = { _, peer in held = peer }; defer { WorkflowReadHTTP.handler = nil }
        let work = Task { try await api.workflowPersonalSource(id: f.templateID, account: f.account, origin: f.origin) }; while held == nil { await Task.yield() }
        try await api.clearSession(); guard case .personal(let row) = try f.source() else { return XCTFail() }; held?.finish(.array([.object(row.fields)]))
        do { _ = try await work.value; XCTFail("Late source") } catch { XCTAssertTrue(error is CancellationError) }
    }
}
