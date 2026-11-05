import XCTest
@testable import TaskfoldCore

@MainActor final class ProjectMemberReadsTests: XCTestCase {
    @MainActor private final class Gate {
        private var waits: [CheckedContinuation<Void, Never>] = []
        var count: Int { waits.count }
        func wait() async { await withCheckedContinuation { waits.append($0) } }
        func open() { let pending = waits; waits = []; for value in pending { value.resume() } }
    }
    private func scope() -> ProjectMemberReads.Scope {
        .init(account: "owner", generation: UUID(), access: UUID(), session: UUID(), origin: "https://example.invalid", project: "project")
    }
    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 { if predicate() { return }; await Task.yield() }
        XCTFail("Expected asynchronous state was not reached", file: file, line: line)
    }
    private func cancelled(_ task: Task<[Record], Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await task.value; XCTFail("Cancelled read returned rows", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, file: file, line: line) }
    }
    func testConcurrentCallersShareOneOperationAndLaterRefreshIsFresh() async throws {
        let pool = ProjectMemberReads(), key = scope(), gate = Gate()
        var calls = 0
        let first = Task { try await pool.load(key) { calls += 1; await gate.wait(); return [Record(["id": .string("first")])] } }
        await eventually { gate.count == 1 }
        let second = Task { try await pool.load(key) { calls += 1; return [] } }
        await eventually { pool.waiterCount == 2 }
        XCTAssertEqual(calls, 1); gate.open()
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a.map(\.id), ["first"]); XCTAssertEqual(b.map(\.id), ["first"])
        XCTAssertEqual(pool.pendingCount, 0)
        let next = try await pool.load(key) { calls += 1; return [Record(["id": .string("fresh")])] }
        XCTAssertEqual(next.map(\.id), ["fresh"]); XCTAssertEqual(calls, 2)
    }
    func testCancellingOneWaiterDoesNotCancelTheRemainingRead() async throws {
        let pool = ProjectMemberReads(), key = scope(), gate = Gate()
        var workerCancelled = false
        let first = Task { try await pool.load(key) { await gate.wait(); workerCancelled = Task.isCancelled; return [Record(["id": .string("member")])] } }
        await eventually { gate.count == 1 }
        let second = Task { try await pool.load(key) { XCTFail("Duplicate operation"); return [] } }
        await eventually { pool.waiterCount == 2 }
        first.cancel(); await eventually { pool.waiterCount == 1 }
        gate.open(); await cancelled(first)
        let rows = try await second.value
        XCTAssertEqual(rows.map(\.id), ["member"]); XCTAssertFalse(workerCancelled)
        XCTAssertEqual(pool.pendingCount, 0)
    }
    func testLastCancellationCannotRemoveOrFeedAReplacementRead() async throws {
        let pool = ProjectMemberReads(), key = scope(), oldGate = Gate(), newGate = Gate()
        let old = Task { try await pool.load(key) { await oldGate.wait(); return [Record(["id": .string("old")])] } }
        await eventually { oldGate.count == 1 }; old.cancel()
        await eventually { pool.pendingCount == 0 }
        let current = Task { try await pool.load(key) { await newGate.wait(); return [Record(["id": .string("new")])] } }
        await eventually { newGate.count == 1 }
        oldGate.open(); await cancelled(old)
        XCTAssertEqual(pool.pendingCount, 1)
        newGate.open(); let value = try await current.value
        XCTAssertEqual(value.map(\.id), ["new"]); XCTAssertEqual(pool.pendingCount, 0)
    }
    func testScopeChangesNeverShareReadsAndInvalidationDiscardsLateResults() async {
        let pool = ProjectMemberReads(), s = scope(), gate = Gate()
        let scopes = [s,
            .init(account: "other", generation: s.generation, access: s.access, session: s.session, origin: s.origin, project: s.project),
            .init(account: s.account, generation: UUID(), access: s.access, session: s.session, origin: s.origin, project: s.project),
            .init(account: s.account, generation: s.generation, access: UUID(), session: s.session, origin: s.origin, project: s.project),
            .init(account: s.account, generation: s.generation, access: s.access, session: UUID(), origin: s.origin, project: s.project),
            .init(account: s.account, generation: s.generation, access: s.access, session: s.session, origin: "https://other.invalid", project: s.project),
            .init(account: s.account, generation: s.generation, access: s.access, session: s.session, origin: s.origin, project: "other-project")]
        let tasks = scopes.map { scope in Task { try await pool.load(scope) { await gate.wait(); return [Record(["id": .string("late")])] } } }
        await eventually { gate.count == scopes.count }
        XCTAssertEqual(pool.pendingCount, scopes.count)
        pool.cancelAll(); XCTAssertEqual(pool.pendingCount, 0)
        gate.open()
        for task in tasks { await cancelled(task) }
        XCTAssertEqual(pool.waiterCount, 0)
    }
    func testSharedFailureIsNotCachedAndAlreadyCancelledCallerStartsNoWork() async throws {
        enum Failure: Error { case synthetic }
        let pool = ProjectMemberReads(), key = scope(), gate = Gate()
        var calls = 0
        let a = Task { try await pool.load(key) { calls += 1; await gate.wait(); throw Failure.synthetic } }
        await eventually { gate.count == 1 }
        let b = Task { try await pool.load(key) { calls += 1; return [] } }
        await eventually { pool.waiterCount == 2 }; gate.open()
        for task in [a, b] { do { _ = try await task.value; XCTFail("Failure became success") } catch { XCTAssertTrue(error is Failure) } }
        XCTAssertEqual(calls, 1); XCTAssertEqual(pool.pendingCount, 0)
        _ = try await pool.load(key) { calls += 1; return [] }; XCTAssertEqual(calls, 2)
        let cancelledRead = Task { () throws -> [Record] in
            while !Task.isCancelled { await Task.yield() }
            return try await pool.load(key) { calls += 1; return [] }
        }
        cancelledRead.cancel(); await cancelled(cancelledRead)
        XCTAssertEqual(calls, 2); XCTAssertEqual(pool.pendingCount, 0)
    }
    func testDirectoryDemandUsesParsedMeaningAndExplicitNameIntent() throws {
        let id = "11111111-1111-4111-8111-111111111111"
        let c = FilterContext(userID: id, people: [Record(["id": .string(id), "display_name": .string("Alex")])])
        for expression in ["today AND p1", "inbox OR overdue", "assigned", "assignee:me", "assignee:others", "assignee:unassigned", "assignee:" + id, #"search:"assignee:Alex""#, "assignee:\"unclosed"] {
            XCTAssertFalse(ProjectMemberDemand.needsDirectory(expression: expression, fields: [], context: c), expression)
        }
        for expression in ["assignee:Alex", "assignee:Unknown", "NOT assignee:A*", "assignee matching:A*", "assigned-by:Alex", "today, assignee:Alex"] {
            XCTAssertTrue(ProjectMemberDemand.needsDirectory(expression: expression, fields: [], context: c), expression)
        }
        XCTAssertFalse(ProjectMemberDemand.needsDirectory(expression: nil, fields: ["today", "priority"], context: c))
        for field in ["assignee", "assigned_by", "assignee_name"] { XCTAssertTrue(ProjectMemberDemand.needsDirectory(expression: nil, fields: [field], context: c)) }
        var parser = try FilterParser("assignee:Alex", context: c)
        XCTAssertEqual(try parser.parse(), .predicate("assignee", "me"))
        XCTAssertTrue(parser.needsPeopleDirectory, "Named self still requires the full directory to detect duplicate names")
    }
}
