import XCTest
@testable import TaskfoldCore

final class WorkspaceRefreshPreparationTests: XCTestCase {
    private func scope() -> WorkspaceRefreshPreparation.Scope {
        .init(workspace: .init(account: "sample", generation: UUID()), session: UUID(), source: UUID(),
              presentation: UUID(), access: UUID(), reviewing: false)
    }
    private func seed() -> Snapshot {
        var value = Snapshot(tables: ["tasks": [Record(["id": .string("sample"), "title": .string("Café"), "future": .object(["zero": .number(-0.0)])])]])
        WidgetCompletion.prepare(&value)
        return value
    }
    private func fixture() throws -> [String: JSON] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-workspace-boundary-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try TaskfoldJSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
    }
    func testLegacyPreparationPreservesPendingEditsAndExactRemoteFields() throws {
        var value = seed()
        let edit = Mutation(table: "tasks", recordID: "sample", method: "PATCH", fields: ["title": .string("Local draft")])
        value.apply(edit); value.pending = [edit]
        var remote = value.tables; remote["tasks"]![0]["title"] = .string("Server title")
        remote["tasks"]![0]["future"] = .object(["text": .string("Cafe\u{301}"), "zero": .number(0)])
        let captured = scope()
        let result = try WorkspaceRefreshPreparation.prepare(snapshot: value, tables: remote, cache: nil, preserveDrafts: false, scope: captured)
        var reference = value; reference.mergeRemote(remote); WidgetCompletion.prepare(&reference)
        XCTAssertTrue(AuthoredValueComparison.exactJSON(.object(result.encoding.snapshot.tables["tasks"]![0].fields), .object(reference.tables["tasks"]![0].fields)))
        XCTAssertEqual(result.encoding.snapshot.pending, [edit])
        XCTAssertEqual(result.encoding.snapshot.tables["tasks"]![0].title, "Local draft")
        XCTAssertNotNil(result.admitted(in: captured))
        XCTAssertTrue(try result.encoding.hasPreparedWidgetCompletion(matching: result.encoding.snapshot))
        XCTAssertEqual(try TaskfoldJSONDecoder().decode(Snapshot.self, from: XCTUnwrap(result.encoding.matching(result.encoding.snapshot))), result.encoding.snapshot)
        XCTAssertEqual(value.tables["tasks"]![0].title, "Local draft")
    }
    func testEachContextChangeRefusesResultIncludingEditThenUndo() throws {
        let original = scope()
        let result = try WorkspaceRefreshPreparation.prepare(snapshot: seed(), tables: [:], cache: nil, preserveDrafts: false, scope: original)
        var changes: [WorkspaceRefreshPreparation.Scope] = []
        for field in 0..<7 {
            changes.append(.init(workspace: .init(account: field == 0 ? "other" : original.workspace.account,
                generation: field == 1 ? UUID() : original.workspace.generation),
                session: field == 2 ? UUID() : original.session, source: field == 3 ? UUID() : original.source,
                presentation: field == 4 ? UUID() : original.presentation, access: field == 5 ? UUID() : original.access,
                reviewing: field == 6))
        }
        for changed in changes { XCTAssertNil(result.admitted(in: changed)) }
    }
    func testTeamRefreshAndReviewKeepExistingAccessRules() throws {
        let f = try fixture(), account = f["account"]!.text
        let boundary = try TeamWorkspaceBoundary(f["active"]!.object, account: account, origin: "https://backend.example")
        let left = try TeamWorkspaceBoundary(f["left"]!.object, account: account, origin: "https://backend.example")
        var task = Record.task(user: account, project: f["project"]!.text); task["title"] = .string("Private team draft")
        let personal = Record.task(user: account, project: f["personal"]!.text)
        let projects = boundary.projects.keys.sorted().map { Record(["id": .string($0), "user_id": .string(account)]) }
        var value = Snapshot(tables: ["tasks": [task, personal], "projects": projects])
        value.teamWorkspace = try TeamWorkspaceCache(boundary: boundary, previous: nil, pending: [], tasks: [task, personal])
        WidgetCompletion.prepare(&value)
        var remote = value.tables; remote["tasks"]![1]["title"] = .string("Remote personal title")
        for (access, preserving) in [(boundary, false), (boundary, true), (left, false), (left, true)] {
            let cache = try TeamWorkspaceCache(boundary: access, previous: value.teamWorkspace, pending: [], tasks: [task, personal])
            var expected = value
            if preserving { expected.tables = cache.filtering(value.tables); expected.teamWorkspace = cache }
            else { expected = cache.merging(remote, into: value) }
            WidgetCompletion.prepare(&expected)
            let result = try WorkspaceRefreshPreparation.prepare(snapshot: value, tables: remote, cache: cache, preserveDrafts: preserving, scope: scope())
            XCTAssertEqual(result.encoding.snapshot, expected)
            if access == left { XCTAssertFalse(result.encoding.snapshot.tables["tasks"]!.contains { $0.id == task.id }) }
            if preserving { XCTAssertEqual(result.encoding.snapshot.tables["tasks"]!.first { $0.id == personal.id }?.title, personal.title) }
        }
    }
    func testCancellationAtEveryPreparationBoundaryProducesNoResult() throws {
        let value = seed()
        for stop in 1...5 {
            var calls = 0
            XCTAssertThrowsError(try WorkspaceRefreshPreparation.prepare(snapshot: value, tables: value.tables, cache: nil,
                preserveDrafts: false, scope: scope(), checkCancellation: {
                    calls += 1; if calls == stop { throw CancellationError() }
                })) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(calls, stop)
        }
    }
    func testImmutableSignatureSeedDoesNotShareMutableCache() throws {
        var value = seed()
        let original = scope(), context = WidgetCompletion.SignatureCache.Scope(workspace: original.workspace, session: original.session, access: original.presentation)
        let cache = WidgetCompletion.SignatureCache()
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        let proof = try XCTUnwrap(cache.seed(matching: context))
        XCTAssertNil(cache.seed(matching: nil))
        XCTAssertNil(cache.seed(matching: .init(workspace: context.workspace, session: UUID(), access: context.access)))
        cache.clear()
        let worker = WidgetCompletion.SignatureCache(seed: proof)
        WidgetCompletion.prepare(&value, signatures: worker, scope: context)
        XCTAssertEqual(worker.statistics.reused, 1); XCTAssertEqual(cache.statistics.retained, 0)
        WidgetCompletion.prepare(&value, signatures: worker, scope: .init(workspace: context.workspace, session: UUID(), access: context.access))
        XCTAssertEqual(worker.statistics.reused, 0); XCTAssertEqual(worker.statistics.computed, 1)
        let empty = WidgetCompletion.SignatureCache(maximumEntries: 0, seed: proof)
        WidgetCompletion.prepare(&value, signatures: empty, scope: context)
        XCTAssertEqual(empty.statistics.reused, 0); XCTAssertEqual(empty.statistics.retained, 0)
    }
    @MainActor func testHeldWorkerLeavesMainActorAvailableAndRejectsInterveningEdit() async throws {
        let entered = expectation(description: "Worker entered"), release = DispatchSemaphore(value: 0)
        let value = seed(), captured = scope()
        let worker = Task.detached {
            var first = true
            return try WorkspaceRefreshPreparation.prepare(snapshot: value, tables: value.tables, cache: nil,
                preserveDrafts: false, scope: captured, checkCancellation: {
                    if first { first = false; entered.fulfill(); guard release.wait(timeout: .now() + 5) == .success else { throw CancellationError() } }
                    try Task.checkCancellation()
                })
        }
        await fulfillment(of: [entered], timeout: 3)
        // This runs on the interface actor while the worker is held.
        let edited = WorkspaceRefreshPreparation.Scope(workspace: captured.workspace, session: captured.session,
            source: UUID(), presentation: captured.presentation, access: captured.access, reviewing: captured.reviewing)
        release.signal()
        let result = try await worker.value
        XCTAssertNil(result.admitted(in: edited)); XCTAssertNotNil(result.admitted(in: captured))
    }
}
