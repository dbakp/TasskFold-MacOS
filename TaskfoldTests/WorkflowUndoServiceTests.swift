import XCTest
@testable import TaskfoldCore

final class WorkflowUndoServiceTests: XCTestCase {
    let account = "f6310000-0000-4000-8000-000000000001"
    let origin = "https://native-auth.test"
    func raw(undo: Int = 1, bulk: Int = 1) -> [String: JSON] { ["protocol": .number(1), "account": .string(account), "undo_protocol": .number(Double(undo)), "bulk_protocol": .number(Double(bulk))] }
    func service(undo: Int = 1, bulk: Int = 1) throws -> WorkflowUndoService { try WorkflowUndoService(raw(undo: undo, bulk: bulk), account: account, origin: origin) }
    func command(count: Int = 1) -> Mutation {
        let run = UUID()
        return Mutation(table: WorkflowUndo.table, recordID: run.uuidString.lowercased(), method: "WORKFLOW_UNDO", fields: ["user_id": .string(account), "items": .array(Array(repeating: .object([:]), count: count))], workflowRun: run)
    }
    func boundary() throws -> TeamWorkspaceBoundary {
        try TeamWorkspaceBoundary(["workspace_boundary_protocol": .number(1), "account": .string(account), "native_team_reads_enabled": .bool(false), "setup_paused": .bool(true), "projects": .array([]), "teams": .array([]), "token": .string(String(repeating: "a", count: 64)), "personal_workflow_undo_protocol": .number(1)], account: account, origin: origin)
    }
    func testPersonalSupportDoesNotRequireTeamBoundary() throws {
        let value = try service()
        XCTAssertTrue(WorkflowUndo.available(boundary: nil, account: account, origin: origin, service: value))
        XCTAssertTrue(WorkflowUndo.canSend(command(), boundary: nil, service: value, origin: origin))
    }
    func testWrongAccountAndOriginCannotReuseCachedSupport() throws {
        let value = try service()
        XCTAssertFalse(WorkflowUndo.available(boundary: nil, account: UUID().uuidString.lowercased(), origin: origin, service: value))
        XCTAssertFalse(WorkflowUndo.available(boundary: nil, account: account, origin: "https://other.example", service: value))
        XCTAssertFalse(WorkflowUndo.canSend(command(), boundary: nil, service: value, origin: "https://other.example"))
        var other = command(); other.fields["user_id"] = .string(UUID().uuidString.lowercased())
        XCTAssertFalse(WorkflowUndo.canSend(other, boundary: nil, service: value, origin: origin))
    }
    func testFreshUnsupportedServiceOverridesAnOlderBoundary() throws {
        let value = try service(undo: 0, bulk: 0)
        XCTAssertFalse(WorkflowUndo.available(boundary: try boundary(), account: account, origin: origin, service: value))
        XCTAssertFalse(WorkflowUndo.canSend(command(), boundary: try boundary(), service: value, origin: origin))
    }
    func testLegacyBoundaryRemainsSupportedWhenIndependentDiscoveryIsAbsent() throws {
        XCTAssertTrue(WorkflowUndo.available(boundary: try boundary(), account: account, origin: origin))
        XCTAssertTrue(WorkflowUndo.canSend(command(), boundary: try boundary()))
        XCTAssertFalse(WorkflowUndo.canSend(command(), boundary: nil))
    }
    func testLargerRequestsNeedExplicitBulkSupport() throws {
        XCTAssertTrue(WorkflowUndo.canSend(command(count: 12000), boundary: nil, service: try service(bulk: 0), origin: origin))
        XCTAssertFalse(WorkflowUndo.canSend(command(count: 12001), boundary: nil, service: try service(bulk: 0), origin: origin))
        XCTAssertTrue(WorkflowUndo.canSend(command(count: 12001), boundary: nil, service: try service(), origin: origin))
    }
    func testUnrelatedChangesNeverRequireThisOptionalService() {
        XCTAssertTrue(WorkflowUndo.canSend(Mutation(table: "tasks", recordID: UUID().uuidString.lowercased(), method: "POST", fields: [:]), boundary: nil))
    }
    func testUnsupportedVersionsAndContradictoryCapabilitiesAreRejected() {
        let variations: [[String: JSON]] = [["protocol": .number(2)], ["undo_protocol": .bool(true)], ["undo_protocol": .number(0), "bulk_protocol": .number(1)], ["account": .string("foreign")]]
        for fields in variations {
            var value = raw(); value.merge(fields) { _, new in new }
            XCTAssertThrowsError(try WorkflowUndoService(value, account: account, origin: origin))
        }
    }
    func testUnsafeBackendIdentitiesCannotBeCached() {
        for value in ["http://workflow.example", "https://person:password@workflow.example", "https://workflow.example/path", "https://workflow.example/", "https://workflow.example?x=1"] {
            XCTAssertThrowsError(try WorkflowUndoService(raw(), account: account, origin: value))
        }
    }
    func testSnapshotColdRoundTripPreservesBoundSupportAndUnsentWork() throws {
        let task = Record.task(user: account)
        var snapshot = Snapshot(tables: ["tasks": [task]], pending: [command()]); snapshot.workflowUndoService = try service()
        let saved = try TaskfoldJSONEncoder().encode(snapshot)
        XCTAssertEqual(try TaskfoldJSONDecoder().decode(Snapshot.self, from: saved), snapshot)
        XCTAssertNil(try TaskfoldJSONDecoder().decode(Snapshot.self, from: TaskfoldJSONEncoder().encode(Snapshot())).workflowUndoService)
    }
    func testCorruptOptionalSupportCannotHideSavedTasksOrDiscardTheQueue() throws {
        let task = Record.task(user: account)
        let original = Snapshot(tables: ["tasks": [task]], pending: [command()])
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: TaskfoldJSONEncoder().encode(original)) as? [String: Any])
        document["workflowUndoService"] = ["raw": ["protocol": 99], "origin": origin]
        let restored = try TaskfoldJSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: document))
        XCTAssertEqual(restored.tables, original.tables); XCTAssertEqual(restored.pending, original.pending)
        XCTAssertNil(restored.workflowUndoService)
        XCTAssertFalse(WorkflowUndo.canSend(restored.pending[0], boundary: nil, service: restored.workflowUndoService, origin: origin))
    }
    func testPreparedSaveCannotReuseChangedCapabilityMetadata() throws {
        var snapshot = Snapshot(); snapshot.workflowUndoService = try service()
        let prepared = try PreparedSnapshotEncoding(snapshot)
        XCTAssertNotNil(try prepared.matching(snapshot))
        snapshot.workflowUndoService = try service(undo: 0, bulk: 0)
        XCTAssertNil(try prepared.matching(snapshot))
    }
    func testPortableBackupDoesNotCarryServiceSupport() throws {
        var snapshot = Snapshot(); snapshot.workflowUndoService = try service()
        let backup = try WorkspaceBackup.make(snapshot, account: account).data()
        XCTAssertFalse(String(decoding: backup, as: UTF8.self).contains("workflowUndoService"))
        XCTAssertFalse(String(decoding: backup, as: UTF8.self).contains(origin))
    }
    @MainActor func backend() throws -> Backend {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthTransportTests.Stub.self]
        let session = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(JSON.object(["access_token": .string("synthetic"), "refresh_token": .string("synthetic-refresh"), "expires_in": .number(3600), "user": .object(["id": .string(account)])])))
        return Backend(configuration: ["URL": origin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
    }
    @MainActor func testDiscoveryUsesOnlyTheIndependentEndpoint() async throws {
        let backend = try backend(); var paths: [String] = []
        AuthTransportTests.Stub.handler = { request in paths.append(request.url!.path); XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store"); XCTAssertFalse(request.httpShouldHandleCookies); return (200, try JSONEncoder().encode(JSON.object(self.raw()))) }
        defer { AuthTransportTests.Stub.handler = nil }
        let value = try await backend.workflowUndoService(account: account)
        XCTAssertEqual(value, try service()); XCTAssertEqual(paths, ["/rest/v1/rpc/taskfold_workflow_undo_capabilities"])
    }
    @MainActor func testRevokedSessionDoesNotBecomeMissingSupport() async throws {
        let backend = try backend()
        AuthTransportTests.Stub.handler = { _ in (403, Data("{\"code\":\"28000\",\"message\":\"Sign in again\"}".utf8)) }
        defer { AuthTransportTests.Stub.handler = nil }
        do { _ = try await backend.workflowUndoService(account: account); XCTFail("Revocation must require sign-in") }
        catch is AccountSessionAuthorizationRequired { }
        catch { XCTFail("Unexpected error: \(error)") }
    }
    @MainActor func testMissingDiscoveryDisablesOnlyThisCapability() async throws {
        let backend = try backend()
        AuthTransportTests.Stub.handler = { _ in (404, Data("{\"code\":\"PGRST202\"}".utf8)) }
        defer { AuthTransportTests.Stub.handler = nil }
        let value = try await backend.workflowUndoService(account: account)
        XCTAssertNil(value)
    }
}
