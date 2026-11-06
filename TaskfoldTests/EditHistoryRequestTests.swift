import XCTest
@testable import TaskfoldCore

final class EditHistoryRequestTests: XCTestCase {
    private let workspace = WorkspaceBinding(account: "synthetic-actor", generation: UUID())
    private let session = UUID()
    private func history(id: UUID = UUID(), mutationID: UUID = UUID()) -> EditHistory {
        var task = Record.task(user: workspace.account); task["title"] = .string("Private original title")
        return EditHistory(changes: [Mutation(id: mutationID, table: "tasks", recordID: task.id, method: "PATCH", fields: ["title": .string("Private edited title")])], snapshot: Snapshot(tables: ["tasks": [task]]), id: id)
    }
    func testCapturesOnlyOneLogicalEntryAndDirection() throws {
        let entry = history(), request = try XCTUnwrap(EditHistoryRequest(direction: .undo, history: entry, workspace: workspace, session: session))
        XCTAssertEqual(request.entry, entry.id)
        XCTAssertTrue(request.matches(direction: .undo, history: entry, workspace: workspace, session: session))
        XCTAssertFalse(request.matches(direction: .redo, history: entry, workspace: workspace, session: session))
        XCTAssertFalse(String(reflecting: request).contains("Private"))
    }
    func testThirtyEntryCapCannotRetargetAStaleButton() throws {
        var entries = (0..<30).map { _ in history() }
        let request = try XCTUnwrap(EditHistoryRequest(direction: .undo, history: entries.last, workspace: workspace, session: session))
        entries.append(history()); entries.removeFirst()
        XCTAssertEqual(entries.count, 30)
        XCTAssertFalse(request.matches(direction: .undo, history: entries.last, workspace: workspace, session: session))
    }
    func testSameMutationAndDepthDoNotMakeTwoActionsTheSameEntry() throws {
        let nonce = UUID(), first = history(mutationID: nonce), second = history(mutationID: nonce)
        XCTAssertEqual(first.redo.map(\.id), second.redo.map(\.id))
        XCTAssertNotEqual(first.id, second.id)
        let request = try XCTUnwrap(EditHistoryRequest(direction: .undo, history: first, workspace: workspace, session: session))
        XCTAssertFalse(request.matches(direction: .undo, history: second, workspace: workspace, session: session))
    }
    func testReverseAndFreshTransportActionsKeepLogicalIdentity() throws {
        let original = history(), reversed = original.reversed
        XCTAssertEqual(reversed.id, original.id)
        let request = try XCTUnwrap(EditHistoryRequest(direction: .redo, history: reversed, workspace: workspace, session: session))
        XCTAssertTrue(request.matches(direction: .redo, history: reversed, workspace: workspace, session: session))
        let next = history(id: original.id)
        XCTAssertNotEqual(next.redo.map(\.id), original.redo.map(\.id))
        XCTAssertEqual(next.id, original.id)
    }
    func testAccountWorkspaceAndSessionChangesRefuseTheSameEntry() throws {
        let entry = history(), request = try XCTUnwrap(EditHistoryRequest(direction: .undo, history: entry, workspace: workspace, session: session))
        for next in [WorkspaceBinding(account: "other", generation: workspace.generation), WorkspaceBinding(account: workspace.account, generation: UUID())] {
            XCTAssertFalse(request.matches(direction: .undo, history: entry, workspace: next, session: session))
        }
        XCTAssertFalse(request.matches(direction: .undo, history: entry, workspace: workspace, session: UUID()))
    }
    func testEmptyHistoryOrInverseCannotProduceAnUndoControl() throws {
        XCTAssertNil(EditHistoryRequest(direction: .undo, history: nil, workspace: workspace, session: session))
        let empty = EditHistory(changes: [], snapshot: Snapshot())
        XCTAssertNil(EditHistoryRequest(direction: .undo, history: empty, workspace: workspace, session: session))
        XCTAssertNil(EditHistoryRequest(direction: .redo, history: empty, workspace: workspace, session: session))
        XCTAssertNil(EditHistoryRequest(direction: .undo, history: history(), workspace: .init(account: "", generation: UUID()), session: session))
        var entry = history(); let request = try XCTUnwrap(EditHistoryRequest(direction: .undo, history: entry, workspace: workspace, session: session)); entry.undo = []
        XCTAssertFalse(request.matches(direction: .undo, history: entry, workspace: workspace, session: session))
    }
    func testOlderRequestCanResumeOnlyWhenItsExactEntryReturnsToTheTop() throws {
        let first = history(), second = history(), request = try XCTUnwrap(EditHistoryRequest(direction: .undo, history: first, workspace: workspace, session: session))
        XCTAssertFalse(request.matches(direction: .undo, history: second, workspace: workspace, session: session))
        XCTAssertFalse(request.matches(direction: .undo, history: nil, workspace: workspace, session: session))
        XCTAssertTrue(request.matches(direction: .undo, history: first, workspace: workspace, session: session))
    }
}
