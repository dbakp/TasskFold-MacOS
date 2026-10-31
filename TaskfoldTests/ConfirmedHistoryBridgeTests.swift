import XCTest
@testable import TaskfoldCore

@MainActor final class ConfirmedHistoryBridgeTests: XCTestCase {
    private func bridge() -> ConfirmedHistoryBridge {
        let manager = UndoManager(); manager.groupsByEvent = false
        return .init(manager: manager)
    }
    private func settle(_ bridge: ConfirmedHistoryBridge) async {
        for _ in 0..<1000 { if !bridge.busy { return }; await Task.yield() }
        XCTFail("History operation did not finish")
    }
    func testUndoRegistersRedoSynchronouslyButCannotRunUntilConfirmation() async {
        let b = bridge(); var resume: CheckedContinuation<Void, Never>?, value = 1
        func step(_ target: Int) -> ConfirmedHistoryBridge.Step {
            .init(name: "Complete Tasks", retained: { true }, perform: {
                if target == 0 { await withCheckedContinuation { resume = $0 } }
                value = target; return step(target == 0 ? 1 : 0)
            })
        }
        b.record(step(0)); b.undo()
        XCTAssertTrue(b.manager.canRedo); XCTAssertTrue(b.busy); XCTAssertFalse(b.canRedo)
        for _ in 0..<1000 { if resume != nil { break }; await Task.yield() }
        XCTAssertNotNil(resume); b.redo(); XCTAssertEqual(value, 1)
        resume?.resume(); await settle(b)
        XCTAssertEqual(value, 0); XCTAssertTrue(b.canRedo)
        b.redo(); await settle(b); XCTAssertEqual(value, 1); XCTAssertTrue(b.canUndo)
    }
    func testFailureRemovesOnlyItsOwnInverseAndKeepsEarlierHistory() async {
        let b = bridge(); var older = 1
        b.record(.init(name: "Older", retained: { true }, perform: { older = 0; return nil }))
        b.record(.init(name: "Unconfirmed", retained: { true }, perform: { nil }))
        b.undo(); await settle(b); XCTAssertFalse(b.canRedo); XCTAssertTrue(b.canUndo)
        b.undo(); await settle(b); XCTAssertEqual(older, 0)
    }
    func testScopeChangeDuringAwaitCannotInstallAnInverse() async {
        let b = bridge(); var current = true, resume: CheckedContinuation<Void, Never>?
        b.record(.init(name: "Private Tasks", retained: { current }, perform: {
            await withCheckedContinuation { resume = $0 }
            return .init(name: "Private Tasks", retained: { true }, perform: { nil })
        }))
        b.undo(); for _ in 0..<1000 { if resume != nil { break }; await Task.yield() }
        current = false; resume?.resume(); await settle(b)
        XCTAssertFalse(b.canRedo); XCTAssertFalse(b.manager.canRedo)
    }
    func testNewEditDuringPendingConfirmationKeepsNewHistoryAndRejectsLateInverse() async {
        let b = bridge(); var resume: CheckedContinuation<Void, Never>?, newValue = 1
        b.record(.init(name: "Pending", retained: { true }, perform: {
            await withCheckedContinuation { resume = $0 }
            return .init(name: "Late", retained: { true }, perform: { nil })
        }))
        b.undo(); for _ in 0..<1000 { if resume != nil { break }; await Task.yield() }
        b.record(.init(name: "New Edit", key: "new", retained: { true }, perform: { newValue = 0; return nil }))
        resume?.resume(); await Task.yield()
        XCTAssertTrue(b.canUndo(key: "new")); XCTAssertFalse(b.canRedo)
        b.undo(); await settle(b); XCTAssertEqual(newValue, 0)
    }
    func testNewActionAfterUndoDropsRedoAndKeepsOrderedEarlierActions() async {
        let b = bridge(); var events: [String] = []
        func step(_ name: String, undo: Bool = true) -> ConfirmedHistoryBridge.Step {
            .init(name: name, retained: { true }, perform: { events.append((undo ? "undo " : "redo ") + name); return step(name, undo: !undo) })
        }
        b.record(step("first")); b.record(step("second")); b.undo(); await settle(b)
        b.record(step("third")); XCTAssertFalse(b.canRedo)
        b.undo(); await settle(b); b.undo(); await settle(b)
        XCTAssertEqual(events, ["undo second", "undo third", "undo first"])
        b.redo(); await settle(b); XCTAssertEqual(events.last, "redo first")
    }
    func testImmediateLocalHistoryKeepsSynchronousControlsAndOrderedRemoteInverse() async {
        let b = bridge(); var value = 1, remote = 1
        func local(_ target: Int) -> ConfirmedHistoryBridge.Step {
            .init(name: "Local", key: "local", retained: { true }, immediate: { value = target; return local(target == 0 ? 1 : 0) })
        }
        b.record(.init(name: "Remote", retained: { true }, perform: { remote = 0; return nil }))
        b.record(local(0)); b.undo(); XCTAssertEqual(value, 0); XCTAssertFalse(b.busy); XCTAssertTrue(b.canRedo(key: "local"))
        b.redo(); XCTAssertEqual(value, 1); b.undo(); b.undo(); await settle(b); XCTAssertEqual(remote, 0)
    }

}
