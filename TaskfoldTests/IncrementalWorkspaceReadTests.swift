import XCTest
@testable import TaskfoldCore

private final class IncrementalHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, IncrementalHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func finish(_ value: JSON, status: Int = 200) {
        let data = try! JSONEncoder().encode(value)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json", "Content-Length": String(data.count)])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock(); private var items: [String] = []
    func add(_ value: String) { lock.lock(); items.append(value); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// The cursor and merge logic of incremental workspace reads. Every network exchange is a local mock.
@MainActor
final class IncrementalWorkspaceReadTests: XCTestCase {
    private let origin = "https://backend.example"
    private let generation = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture() throws -> [String: JSON] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-workspace-boundary-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
    }
    private func boundary(_ state: String = "active") throws -> TeamWorkspaceBoundary {
        let f = try fixture(); return try TeamWorkspaceBoundary(f[state]!.object, account: f["account"]!.text, origin: origin)
    }
    private func base(_ boundary: TeamWorkspaceBoundary?, continuity: UUID, at: Date, tables: [String: [Record]] = [:], account: String? = nil) -> WorkspaceReadBase {
        WorkspaceReadBase(account: boundary?.account ?? account ?? "legacy-account", origin: origin, generation: generation, boundary: boundary, continuity: continuity, tables: tables, lastFull: at, lastDeep: at)
    }
    private func evidence(_ continuity: UUID, dirty: Set<String> = [], joined: Bool = true, fresh: Bool = true, unknown: Bool = false) -> RealtimeChangeLedger.Evidence {
        .init(continuity: continuity, joined: joined, fresh: fresh, dirty: dirty, unknown: unknown)
    }
    private func plan(_ base: WorkspaceReadBase?, _ evidence: RealtimeChangeLedger.Evidence, boundary: TeamWorkspaceBoundary? = nil, requested: Bool = false,
                      sent: SentChanges = .none, conflict: Bool = false, now: Date, account: String? = nil, generation: UUID? = nil, origin: String? = nil) throws -> WorkspaceReadPlan {
        let b = try boundary ?? self.boundary()
        return WorkspaceReadPlanner.plan(.init(base: base, account: account ?? b.account, origin: origin ?? self.origin, generation: generation ?? self.generation, boundary: b,
                                               evidence: evidence, requestedFull: requested, sent: sent, hadConflict: conflict, now: now))
    }

    // MARK: Realtime ledger

    func testLedgerCollectsTablesAndHandsThemOverOnce() {
        var clock = t0
        let ledger = RealtimeChangeLedger(now: { clock })
        ledger.noteJoined()
        clock += 5; ledger.noteEvent(table: "tasks"); ledger.noteEvent(table: "labels")
        let taken = ledger.consume()
        XCTAssertEqual(taken.dirty, ["tasks", "labels"]); XCTAssertTrue(taken.joined); XCTAssertTrue(taken.fresh); XCTAssertFalse(taken.unknown)
        XCTAssertEqual(ledger.evidence().dirty, [])
        ledger.restore(taken)
        XCTAssertEqual(ledger.evidence().dirty, ["tasks", "labels"])
    }
    func testEventWithoutATableCannotBeNarrowed() {
        let ledger = RealtimeChangeLedger(now: { self.t0 }); ledger.noteJoined(); ledger.noteEvent(table: nil)
        XCTAssertTrue(ledger.consume().unknown)
        XCTAssertFalse(ledger.evidence().unknown)
    }
    func testSilenceDisconnectAndClockMovesBreakContinuity() {
        var clock = t0
        let ledger = RealtimeChangeLedger(now: { clock }, freshness: 75)
        ledger.noteJoined(); let joined = ledger.continuity
        clock += 25; ledger.noteFrame()
        XCTAssertEqual(ledger.continuity, joined, "heartbeats keep the same continuity")
        clock += 76; XCTAssertFalse(ledger.evidence().fresh, "no frame for longer than the freshness window")
        ledger.noteFrame()
        XCTAssertNotEqual(ledger.continuity, joined, "a sleeping device may have missed events with no close frame")
        let afterGap = ledger.continuity
        clock -= 500; ledger.noteFrame()
        XCTAssertNotEqual(ledger.continuity, afterGap, "a clock that moved backwards proves nothing")
        let beforeDrop = ledger.continuity
        ledger.noteDisconnected()
        XCTAssertNotEqual(ledger.continuity, beforeDrop); XCTAssertFalse(ledger.evidence().joined)
        ledger.noteJoined(); XCTAssertTrue(ledger.evidence().joined)
    }
    func testAFailedReadPutsBackWhatItTookSoNothingIsLost() {
        var clock = t0
        let ledger = RealtimeChangeLedger(now: { clock })
        ledger.noteJoined(); clock += 1; ledger.noteEvent(table: "tasks")
        let first = ledger.consume(); clock += 1; ledger.noteEvent(table: "labels")   // arrives while the read runs
        ledger.restore(first)                                                          // the read failed
        XCTAssertEqual(ledger.consume().dirty, ["tasks", "labels"])
    }

    // MARK: Planner

    func testExplicitSyncAndMissingBaseReadEverything() throws {
        let b = try boundary(), c = UUID(), snapshot = base(b, continuity: c, at: t0)
        XCTAssertEqual(try plan(snapshot, evidence(c), requested: true, now: t0 + 10), .full(.requested))
        XCTAssertEqual(try plan(nil, evidence(c), now: t0 + 10), .full(.noBase))
        XCTAssertEqual(try plan(snapshot, evidence(c), conflict: true, now: t0 + 10), .full(.conflict))
    }
    func testAccountSwitchNeverReusesAnotherAccountsRead() throws {
        let b = try boundary(), c = UUID(), snapshot = base(b, continuity: c, at: t0)
        XCTAssertEqual(try plan(snapshot, evidence(c), now: t0 + 10, account: UUID().uuidString.lowercased()), .full(.accountChanged))
        XCTAssertEqual(try plan(snapshot, evidence(c), now: t0 + 10, generation: UUID()), .full(.accountChanged), "sign-out and back in starts a new generation")
        XCTAssertEqual(try plan(snapshot, evidence(c), now: t0 + 10, origin: "https://other.example"), .full(.accountChanged))
        XCTAssertTrue(try plan(snapshot, evidence(c), now: t0 + 10).isSkip, "control: the same account is trusted")
    }
    func testAnyAccessBoundaryChangeForcesAFullRead() throws {
        let c = UUID(), active = try boundary(), snapshot = base(active, continuity: c, at: t0)
        XCTAssertEqual(try plan(snapshot, evidence(c, dirty: ["labels"]), boundary: try boundary("viewer"), now: t0 + 10), .full(.boundaryChanged))
        XCTAssertEqual(try plan(snapshot, evidence(c), boundary: try boundary("left"), now: t0 + 10), .full(.boundaryChanged))
    }
    func testAnythingThatCouldHideAMissedEventForcesAFullRead() throws {
        let b = try boundary(), c = UUID(), snapshot = base(b, continuity: c, at: t0)
        XCTAssertEqual(try plan(snapshot, evidence(c, joined: false), now: t0 + 10), .full(.realtimeGap))
        XCTAssertEqual(try plan(snapshot, evidence(c, fresh: false), now: t0 + 10), .full(.realtimeGap))
        XCTAssertEqual(try plan(snapshot, evidence(UUID()), now: t0 + 10), .full(.realtimeGap), "the socket rejoined since the base was read")
        XCTAssertEqual(try plan(snapshot, evidence(c, unknown: true), now: t0 + 10), .full(.unknownChange))
        XCTAssertEqual(try plan(snapshot, evidence(c), now: t0 - 5), .full(.clockMoved))
        XCTAssertEqual(try plan(snapshot, evidence(c), now: t0 + SyncTiming.deepReadInterval + 1), .full(.deepDue))
    }
    func testQuietJoinedSocketReadsNothingUntilTheSafetyNetIsDue() throws {
        let b = try boundary(), c = UUID(), snapshot = base(b, continuity: c, at: t0)
        XCTAssertTrue(try plan(snapshot, evidence(c), now: t0 + 60).isSkip)
        XCTAssertTrue(try plan(snapshot, evidence(c, dirty: ["task_comments"]), now: t0 + 60).isSkip, "conversation tables are read by their own sync")
        let due = try plan(snapshot, evidence(c), now: t0 + SyncTiming.reconcileInterval)
        XCTAssertFalse(due.full); XCTAssertEqual(due.tables, WorkspaceReadPlanner.ordinaryTables); XCTAssertTrue(due.activity)
        XCTAssertLessThan(SyncTiming.reconcileInterval, SyncTiming.pollIntervalRealtimeJoined, "every safety-net poll reconciles")
    }
    func testDeletionIsSeenByReReadingTheChangedTableNotByAPartialMerge() throws {
        let b = try boundary(), c = UUID(), snapshot = base(b, continuity: c, at: t0)
        let task = try plan(snapshot, evidence(c, dirty: ["tasks"]), now: t0 + 30)
        XCTAssertEqual(task.tables, ["tasks"]); XCTAssertTrue(task.activity, "a task change appends history and can change provenance")
        let label = try plan(snapshot, evidence(c, dirty: ["labels"]), now: t0 + 30)
        XCTAssertEqual(label.tables, ["labels"]); XCTAssertFalse(label.activity)
        let project = try plan(snapshot, evidence(c, dirty: ["projects"]), now: t0 + 30)
        XCTAssertEqual(project.tables, ["projects", "sections", "project_collaborators"], "a project delete cascades to its children")
    }
    func testOrdinaryAndDerivedTablesCoverEveryWorkspaceTable() {
        XCTAssertEqual(WorkspaceReadPlanner.ordinaryTables.union([TaskActivity.table, TaskActivity.epochTable]), Set(Backend.workspaceTables).union(Backend.optionalWorkspaceTables),
                       "a table added to the full read must also be classified for incremental reads")
    }

    // MARK: Offline queue

    func testQueuedPlainTaskEditsReadOnlyTheirTablesAfterSending() throws {
        let b = try boundary(), c = UUID(), snapshot = base(b, continuity: c, at: t0)
        let queue = [Mutation(table: "tasks", recordID: "a", method: "POST", fields: [:]), Mutation(table: "tasks", recordID: "b", method: "PATCH", fields: [:]),
                     Mutation(table: "tasks", recordID: "c", method: "DELETE", fields: [:]), Mutation(table: "labels", recordID: "d", method: "POST", fields: [:])]
        let sent = queue.reduce(SentChanges.none) { $0.adding($1) }
        XCTAssertEqual(sent, .tables(["tasks", "labels"]))
        let result = try plan(snapshot, evidence(c), sent: sent, now: t0 + 20)
        XCTAssertEqual(result.tables, ["tasks", "labels"]); XCTAssertTrue(result.activity); XCTAssertFalse(result.full)
    }
    func testOneUnclassifiedMutationAnywhereInTheQueueForcesAFullRead() throws {
        let b = try boundary(), c = UUID(), snapshot = base(b, continuity: c, at: t0)
        let plain = Mutation(table: "tasks", recordID: "a", method: "PATCH", fields: [:])
        let others: [Mutation] = [
            Mutation(table: "projects", recordID: "p", method: "PATCH", fields: [:]),
            Mutation(table: "tasks", recordID: "m", method: "PATCH", fields: [:], personalTaskMove: true),
            Mutation(table: "tasks", recordID: "o", method: "ORDER", fields: [:]),
            Mutation(table: "sections", recordID: "s", method: "DELETE", fields: [:]),
            Mutation(table: "tasks", recordID: "w", method: "POST", fields: [:], workflowRun: UUID())]
        for other in others {
            XCTAssertEqual(SentChanges.effects(of: other), .unknown, other.table + " " + other.method)
            let sent = SentChanges.none.adding(plain).adding(other).adding(plain)
            XCTAssertEqual(sent, .unknown, "unknown is sticky")
            XCTAssertEqual(try plan(snapshot, evidence(c), sent: sent, now: t0 + 20), .full(.mutation))
        }
    }
    func testTeamCommandsAreNeverTreatedAsPlainTaskEdits() throws {
        let b = try boundary(), project = try XCTUnwrap(b.teamProjects.first)
        let scope = TeamTaskEditScope(account: b.account, origin: origin, team: project.value, project: project.key)
        let team = Mutation(table: "tasks", recordID: "t", method: "PATCH", fields: [:], teamTaskScope: scope)
        XCTAssertEqual(SentChanges.effects(of: team), .unknown)
    }

    // MARK: History overlap

    private func activity(_ sequence: Int, at: Date, id: String? = nil) -> Record {
        Record(["id": .string(id ?? "row-\(sequence)"), "sequence": .number(Double(sequence)), "recorded_at": .string(ISO8601DateFormatter().string(from: at))])
    }
    func testHistoryIsReadAgainFromBelowTheRowsRecordedNearTheNewest() {
        let newest = t0
        let held = [activity(10, at: newest - 7200), activity(20, at: newest - 3600), activity(30, at: newest - 120), activity(31, at: newest - 60), activity(40, at: newest)]
        XCTAssertEqual(ActivityIncrement.floor(held), 29, "rows 30...40 were recorded within the overlap, so row 29 is the last trusted one")
        XCTAssertEqual(ActivityIncrement.kept(held, through: 29).map(\.id), ["row-10", "row-20"])
        XCTAssertNil(ActivityIncrement.floor([]))
        XCTAssertEqual(ActivityIncrement.floor([Record(["id": .string("x"), "sequence": .number(5)])]), 0, "a row that cannot be placed in time reads the whole ledger")
    }
    func testClockSkewBetweenClientAndServerDoesNotMoveTheWindow() {
        // The window comes from server timestamps alone: a client clock a day off changes nothing.
        let skewed = Date(timeIntervalSince1970: 4_000_000_000)
        XCTAssertEqual(ActivityIncrement.floor([activity(1, at: skewed - 5000), activity(2, at: skewed)]), 1)
        XCTAssertEqual(ActivityIncrement.floor([activity(7, at: Date(timeIntervalSince1970: 9_000_000_000))]), 6)
    }

    // MARK: Backend reads against a mock service

    private func backend(_ account: String) throws -> Backend {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [IncrementalHTTP.self]
        let session = try JSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(account)\"}}".utf8))
        return Backend(configuration: ["URL": origin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
    }
    private func rows(_ values: [Record]) -> JSON { .array(values.map { .object($0.fields) }) }
    private func task(_ id: String, _ project: String, account: String) -> Record {
        Record(["id": .string(id), "user_id": .string(account), "project_id": .string(project), "title": .string("Task")])
    }
    private func path(_ request: URLRequest) -> String { request.url!.path + (request.url!.query.map { "?" + $0 } ?? "") }

    func testPartialReadFetchesOnlyTheChangedTableAndDropsADeletedRow() async throws {
        let f = try fixture(), b = try boundary(), api = try backend(b.account), project = f["personal"]!.text
        let kept = task("11111111-1111-4111-8111-111111111111", project, account: b.account), gone = task("22222222-2222-4222-8222-222222222222", project, account: b.account)
        let label = Record(["id": .string("33333333-3333-4333-8333-333333333333"), "user_id": .string(b.account), "name": .string("Errands")])
        let held: [String: [Record]] = ["tasks": [kept, gone], "labels": [label]]
        let seen = RequestLog()
        IncrementalHTTP.handler = { request, peer in
            seen.add(request.url!.path)
            if request.url!.path.hasSuffix("taskfold_workspace_boundary") { peer.finish(f["active"]!); return }
            if request.url!.path == "/rest/v1/tasks" { peer.finish(self.rows([kept])); return }   // the other device deleted `gone`
            peer.finish(.array([]))
        }; defer { IncrementalHTTP.handler = nil }
        let snapshot = base(b, continuity: UUID(), at: t0, tables: held)
        let read = try await api.workspaceRead(account: b.account, initial: b, allowLegacy: false, plan: WorkspaceReadPlan(full: false, tables: ["tasks"]), base: snapshot)
        XCTAssertEqual(read.raw?["tasks"]?.map(\.id), [kept.id]); XCTAssertEqual(read.tables["tasks"]?.map(\.id), [kept.id])
        XCTAssertEqual(read.raw?["labels"], [label], "an unchanged table is carried over, not read")
        XCTAssertEqual(seen.all.filter { $0.hasPrefix("/rest/v1/") && !$0.hasPrefix("/rest/v1/rpc/") }, ["/rest/v1/tasks"])
        XCTAssertEqual(seen.all.filter { $0.contains("workspace_boundary") }.count, 1, "only the closing access check; the opening one is supplied")
        XCTAssertFalse(read.plan.full)
    }
    func testQuietPlanReadsNoTables() async throws {
        let f = try fixture(), b = try boundary(), api = try backend(b.account)
        let seen = RequestLog()
        IncrementalHTTP.handler = { request, peer in seen.add(request.url!.path); peer.finish(.array([])) }; defer { IncrementalHTTP.handler = nil }
        let held: [String: [Record]] = ["tasks": [task("11111111-1111-4111-8111-111111111111", f["personal"]!.text, account: b.account)]]
        let read = try await api.workspaceRead(account: b.account, initial: b, allowLegacy: false, plan: WorkspaceReadPlan(full: false), base: base(b, continuity: UUID(), at: t0, tables: held))
        XCTAssertEqual(seen.all, []); XCTAssertEqual(read.tables["tasks"]?.count, 1); XCTAssertEqual(read.boundary, b)
    }
    func testAccessChangeDuringAPartialReadRestartsAsAFullRead() async throws {
        let f = try fixture(), b = try boundary(), api = try backend(b.account)
        let seen = RequestLog()
        IncrementalHTTP.handler = { request, peer in
            seen.add(request.url!.path)
            peer.finish(request.url!.path.hasSuffix("taskfold_workspace_boundary") ? f["left"]! : .array([]))
        }; defer { IncrementalHTTP.handler = nil }
        // The caller still believes the active boundary; the closing check disagrees.
        let read = try await api.workspaceRead(account: b.account, initial: b, allowLegacy: false, plan: WorkspaceReadPlan(full: false, tables: ["labels"]), base: base(b, continuity: UUID(), at: t0, tables: ["tasks": []]))
        XCTAssertTrue(read.plan.full); XCTAssertEqual(read.plan.reason, .boundaryChanged)
        XCTAssertTrue(Set(seen.all).isSuperset(of: ["/rest/v1/tasks", "/rest/v1/projects", "/rest/v1/sections", "/rest/v1/task_activity"]), "every table is read again under the new boundary")
        XCTAssertEqual(try boundary("left"), read.boundary)
    }
    func testHistoryAppendsAfterTheOverlapAndReplacesRowsInsideIt() async throws {
        let f = try fixture(), b = try boundary(), api = try backend(b.account)
        let old = activity(10, at: t0 - 7200), inside = activity(30, at: t0 - 120, id: "inside"), newest = activity(40, at: t0)
        let late = activity(35, at: t0 - 100, id: "late"), fresh = activity(41, at: t0 + 30)   // 35 committed after 40 was read
        let epoch = [Record(["id": .string("current"), "recorded_from": .string("2026-01-01T00:00:00Z")])]
        let seen = RequestLog()
        IncrementalHTTP.handler = { request, peer in
            let url = request.url!; seen.add(self.path(request))
            if url.path.hasSuffix("taskfold_workspace_boundary") { peer.finish(f["active"]!); return }
            if url.path == "/rest/v1/task_activity_epoch" { peer.finish(self.rows(epoch)); return }
            if url.path == "/rest/v1/task_activity" { peer.finish(self.rows([inside, late, newest, fresh])); return }
            peer.finish(.array([]))
        }; defer { IncrementalHTTP.handler = nil }
        let held: [String: [Record]] = [TaskActivity.epochTable: epoch, TaskActivity.table: [old, inside, newest]]
        let read = try await api.workspaceRead(account: b.account, initial: b, allowLegacy: false, plan: WorkspaceReadPlan(full: false, activity: true), base: base(b, continuity: UUID(), at: t0, tables: held))
        XCTAssertEqual(read.raw?[TaskActivity.table]?.map(\.id), ["row-10", "inside", "late", "row-40", "row-41"])
        XCTAssertTrue(seen.all.contains { $0.contains("task_activity?") && $0.contains("sequence=gt.29") }, "reads above the overlap floor, not from zero")
        XCTAssertFalse(seen.all.contains { $0.contains("task_activity?") && $0.contains("sequence=gt.0&") })
    }
    func testHistoryEpochChangeReadsTheWholeLedgerAgain() async throws {
        let f = try fixture(), b = try boundary(), api = try backend(b.account)
        let held = [activity(10, at: t0 - 7200), activity(40, at: t0)]
        let oldEpoch = [Record(["id": .string("current"), "recorded_from": .string("2026-01-01T00:00:00Z")])]
        let newEpoch = [Record(["id": .string("current"), "recorded_from": .string("2026-06-01T00:00:00Z")])]
        let seen = RequestLog()
        IncrementalHTTP.handler = { request, peer in
            let url = request.url!; seen.add(self.path(request))
            if url.path.hasSuffix("taskfold_workspace_boundary") { peer.finish(f["active"]!); return }
            if url.path == "/rest/v1/task_activity_epoch" { peer.finish(self.rows(newEpoch)); return }
            if url.path == "/rest/v1/task_activity" { peer.finish(self.rows([self.activity(1, at: self.t0 - 9000)])); return }
            peer.finish(.array([]))
        }; defer { IncrementalHTTP.handler = nil }
        let read = try await api.workspaceRead(account: b.account, initial: b, allowLegacy: false, plan: WorkspaceReadPlan(full: false, activity: true),
                                               base: base(b, continuity: UUID(), at: t0, tables: [TaskActivity.epochTable: oldEpoch, TaskActivity.table: held]))
        XCTAssertEqual(read.raw?[TaskActivity.table]?.map(\.id), ["row-1"], "history was rewritten server-side, so nothing held is trusted")
        XCTAssertTrue(seen.all.contains { $0.contains("task_activity?") && $0.contains("sequence=gt.0") })
    }
    func testFullPlanReadsEveryTableLikeBefore() async throws {
        let f = try fixture(), b = try boundary(), api = try backend(b.account)
        let seen = RequestLog()
        IncrementalHTTP.handler = { request, peer in
            seen.add(request.url!.path)
            peer.finish(request.url!.path.hasSuffix("taskfold_workspace_boundary") ? f["active"]! : .array([]))
        }; defer { IncrementalHTTP.handler = nil }
        let read = try await api.workspaceRead(account: b.account, initial: b, allowLegacy: false)
        for table in Backend.workspaceTables { XCTAssertTrue(seen.all.contains("/rest/v1/" + table), table) }
        XCTAssertTrue(seen.all.contains("/rest/v1/" + TaskAssignmentProvenance.table)); XCTAssertTrue(seen.all.contains("/rest/v1/" + TaskNodeActivity.epochTable))
        XCTAssertTrue(read.plan.full); XCTAssertNotNil(read.raw)
    }

    // MARK: Older service without the team boundary RPC (what the hosted project runs today)

    private func legacyInput(_ base: WorkspaceReadBase?, boundary: TeamWorkspaceBoundary?, c: UUID, dirty: Set<String> = [], now: Date) -> WorkspaceReadPlanner.Input {
        .init(base: base, account: "legacy-account", origin: origin, generation: generation, boundary: boundary,
              evidence: evidence(c, dirty: dirty), requestedFull: false, sent: .none, hadConflict: false, now: now)
    }
    func testServiceWithoutABoundaryStillReadsIncrementally() throws {
        let c = UUID(), snapshot = base(nil, continuity: c, at: t0)
        XCTAssertTrue(WorkspaceReadPlanner.plan(legacyInput(snapshot, boundary: nil, c: c, now: t0 + 30)).isSkip)
        let changed = WorkspaceReadPlanner.plan(legacyInput(snapshot, boundary: nil, c: c, dirty: ["tasks"], now: t0 + 30))
        XCTAssertEqual(changed.tables, ["tasks"]); XCTAssertFalse(changed.full)
    }
    func testBoundaryAppearingAfterADeploymentForcesAFullRead() throws {
        let c = UUID(), snapshot = base(nil, continuity: c, at: t0)
        XCTAssertEqual(WorkspaceReadPlanner.plan(legacyInput(snapshot, boundary: try boundary(), c: c, now: t0 + 30)), .full(.boundaryChanged))
        let team = base(try boundary(), continuity: c, at: t0)
        XCTAssertEqual(WorkspaceReadPlanner.plan(legacyInput(team, boundary: nil, c: c, now: t0 + 30)), .full(.accountChanged), "different account in this fixture")
    }
    func testLegacyPartialReadMakesNoBoundaryCallsAndFetchesOnlyChangedTables() async throws {
        let f = try fixture(), api = try backend(f["account"]!.text)
        let seen = RequestLog()
        IncrementalHTTP.handler = { request, peer in
            seen.add(request.url!.path)
            if request.url!.path == "/rest/v1/tasks" { peer.finish(.array([])); return }
            peer.finish(.array([]))
        }; defer { IncrementalHTTP.handler = nil }
        let held: [String: [Record]] = ["tasks": [Record(["id": .string("a")])], "labels": [Record(["id": .string("l")])]]
        let read = try await api.workspaceRead(account: f["account"]!.text, initial: nil, allowLegacy: true, plan: WorkspaceReadPlan(full: false, tables: ["tasks"]),
                                               base: base(nil, continuity: UUID(), at: t0, tables: held, account: f["account"]!.text))
        XCTAssertEqual(seen.all, ["/rest/v1/tasks"], "no boundary or team probe, no other table")
        XCTAssertNil(read.boundary); XCTAssertEqual(read.tables["tasks"]?.count, 0); XCTAssertEqual(read.tables["labels"]?.count, 1)
        XCTAssertFalse(read.plan.full); XCTAssertNotNil(read.raw)
    }
    func testLegacyServiceWithoutNodeHistoryDropsThatLedgerLikeAFullRead() async throws {
        let f = try fixture(), api = try backend(f["account"]!.text)
        IncrementalHTTP.handler = { request, peer in
            if request.url!.path.contains("task_node_activity") { peer.finish(.object(["code": .string("42P01")]), status: 404); return }
            peer.finish(.array([]))
        }; defer { IncrementalHTTP.handler = nil }
        let held: [String: [Record]] = [TaskNodeActivity.table: [Record(["id": .string("stale")])], TaskNodeActivity.epochTable: [Record(["id": .string("current")])]]
        let read = try await api.workspaceRead(account: f["account"]!.text, initial: nil, allowLegacy: true, plan: WorkspaceReadPlan(full: false, activity: true),
                                               base: base(nil, continuity: UUID(), at: t0, tables: held, account: f["account"]!.text))
        XCTAssertNil(read.raw?[TaskNodeActivity.table]); XCTAssertNil(read.raw?[TaskNodeActivity.epochTable])
    }
}
