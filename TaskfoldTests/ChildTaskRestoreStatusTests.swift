import XCTest
@testable import TaskfoldCore

final class ChildTaskRestoreStatusTests: XCTestCase {
    private let origin = "https://live-status.example.invalid"
    private func fixture() throws -> [String: JSON] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "child-live-restoration-status-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try TaskfoldJSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
    }
    private func entry(_ f: [String: JSON], cycle: Bool = false) throws -> ChildTaskRestoreState.Entry {
        let raw = f[cycle ? "lifecycleCommand" : "command"]!.object
        let command = try ChildTaskRestoreCommand(account: raw["account"]!.text, origin: origin, body: raw)
        return .init(command: command, phase: .applied, result: try command.result(f[cycle ? "lifecycleReceipt" : "receipt"]!.object))
    }
    private func scope(_ entry: ChildTaskRestoreState.Entry) -> ChildTaskFieldClientScope { .init(account: entry.command.account, origin: origin, workspace: UUID(), session: UUID(), access: UUID()) }
    private func wire(_ value: JSON) throws -> Data { let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    func testGenuineLiveAdoptionDoesNotRewriteAnEarlierRestoreEvent() throws {
        let f = try fixture(), e = try entry(f), scope = scope(e), snapshot = UUID()
        let before = try ChildTaskRestoreStatus(data: wire(f["active"]!), entry: e, scope: scope, snapshot: snapshot)
        let after = try ChildTaskRestoreStatus(data: wire(f["adopted"]!), entry: e, scope: scope, snapshot: snapshot)
        XCTAssertEqual(before.phase, .restored); XCTAssertEqual(before.reversalMode, .undo); XCTAssertTrue(before.canReviewAdoption)
        XCTAssertEqual(after.phase, .adopted); XCTAssertEqual(after.revision, 2); XCTAssertTrue(after.newerRetained)
        XCTAssertNil(after.reversalMode); XCTAssertFalse(after.canReviewAdoption); XCTAssertFalse(after.canReviewFinish)
        XCTAssertEqual(e.result?.raw["phase"], .string("restored")); XCTAssertEqual(e.result?.raw["next_revision"], .number(1))
        XCTAssertTrue(after.message.contains("cycle has ended")); XCTAssertFalse(String(describing: after).contains(e.command.account))
    }
    func testGenuineUndoRedoNewWorkAndFinishHaveDistinctCurrentControls() throws {
        let f = try fixture(), e = try entry(f, cycle: true), scope = scope(e)
        let states = try f["lifecycle"]!.list.map { try ChildTaskRestoreStatus(data: wire($0), entry: e, scope: scope, snapshot: UUID()) }
        XCTAssertEqual(states.map(\.phase), [.undone, .restored, .undone, .undone, .finished])
        XCTAssertEqual(states[0].reversalMode, .redo); XCTAssertEqual(states[1].reversalMode, .undo)
        XCTAssertNil(states[3].reversalMode); XCTAssertTrue(states[3].canReviewFinish)
        XCTAssertNil(states[4].reversalMode); XCTAssertFalse(states[4].canReviewFinish); XCTAssertFalse(states[4].newerRetained)
    }
    func testLiveStatusExpiresWithWorkspaceSessionAccessAndSnapshot() throws {
        let f = try fixture(), e = try entry(f), scope = scope(e), snapshot = UUID()
        let status = try ChildTaskRestoreStatus(data: wire(f["active"]!), entry: e, scope: scope, snapshot: snapshot)
        XCTAssertTrue(status.isCurrent(scope: scope, snapshot: snapshot)); XCTAssertFalse(status.isCurrent(scope: scope, snapshot: UUID()))
        for other in [ChildTaskFieldClientScope(account: scope.account, origin: origin, workspace: UUID(), session: scope.session, access: scope.access), .init(account: scope.account, origin: origin, workspace: scope.workspace, session: UUID(), access: scope.access), .init(account: scope.account, origin: origin, workspace: scope.workspace, session: scope.session, access: UUID())] {
            XCTAssertFalse(status.isCurrent(scope: other, snapshot: snapshot))
        }
        XCTAssertFalse(status.isCurrent(scope: nil, snapshot: snapshot))
    }
    func testForeignOrContradictoryHeadersNeverOfferRecoveryActions() throws {
        let f = try fixture(), e = try entry(f), scope = scope(e), original = f["active"]!.object
        let changes: [(String, JSON)] = [("task_id", .string(UUID().uuidString.lowercased())), ("actor_id", .string(UUID().uuidString.lowercased())), ("restore_id", .string(UUID().uuidString.lowercased())), ("archive_digest", .string(String(repeating: "a", count: 64))), ("phase", .string("unknown-future-phase")), ("revision", .number(0)), ("newer_retained", .bool(true)), ("structure_current", .number(1)), ("unexpected", .null)]
        for (key, value) in changes {
            var raw = original; raw[key] = value
            XCTAssertThrowsError(try ChildTaskRestoreStatus(data: wire(.object(raw)), entry: e, scope: scope, snapshot: UUID()), key)
        }
        var adopted = f["adopted"]!.object; adopted["structure_current"] = .bool(true)
        XCTAssertThrowsError(try ChildTaskRestoreStatus(data: wire(.object(adopted)), entry: e, scope: scope, snapshot: UUID()))
    }
    func testRevisionSyntaxAndSizeAreBoundedBeforeDecode() throws {
        let f = try fixture(), e = try entry(f), scope = scope(e), raw = try wire(f["active"]!)
        let text = String(decoding: raw, as: UTF8.self)
        for revision in ["1.0", "1e0", "9007199254740993", "1,\"revision\":1"] {
            let malformed = Data(text.replacingOccurrences(of: "\"revision\":1", with: "\"revision\":" + revision).utf8)
            XCTAssertNotEqual(raw, malformed); XCTAssertThrowsError(try ChildTaskRestoreStatus(data: malformed, entry: e, scope: scope, snapshot: UUID()))
        }
        XCTAssertThrowsError(try ChildTaskRestoreStatus(data: raw + Data(repeating: 32, count: 4096), entry: e, scope: scope, snapshot: UUID()))
    }
    func testOnlyConfirmedMatchingDecisionsCanCreateAContentlessRead() throws {
        let f = try fixture(), e = try entry(f), scope = scope(e)
        let body = try ChildTaskRestoreStatus.body(e, scope: scope)
        XCTAssertEqual(Set(body.keys), ["_body", "_actor", "_restore"]); XCTAssertEqual(body["_body"], .object(e.command.identity))
        XCTAssertLessThan(try wire(.object(body)).count, 1024)
        for phase in [ChildTaskRestoreState.Phase.queued, .attempted, .closed] { XCTAssertThrowsError(try ChildTaskRestoreStatus.body(.init(command: e.command, phase: phase), scope: scope)) }
        let other = ChildTaskFieldClientScope(account: UUID().uuidString.lowercased(), origin: origin, workspace: scope.workspace, session: scope.session, access: scope.access)
        XCTAssertThrowsError(try ChildTaskRestoreStatus.body(e, scope: other))
        var retained = f["adopted"]!.object; retained["newer_retained"] = .bool(false)
        let status = try ChildTaskRestoreStatus(data: wire(.object(retained)), entry: e, scope: scope, snapshot: UUID())
        XCTAssertFalse(status.message.contains("retained in Saved originals")); XCTAssertNil(status.reversalMode)
    }
}
