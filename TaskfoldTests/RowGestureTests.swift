import XCTest
@testable import TaskfoldCore

final class RowGestureTests: XCTestCase {
    func testMacDefaultsRevealAndRequireClick() {
        var m = RowGestureMotion(); m.begin(width: 600)
        XCTAssertTrue(m.move(dx: 1000, dy: 0)); XCTAssertFalse(m.armed)
        XCTAssertLessThanOrEqual(m.offset, RowGestureMotion.leadingWidth + 24)
        XCTAssertNil(m.finish()); XCTAssertEqual(m.stage, .open); XCTAssertEqual(m.offset, RowGestureMotion.leadingWidth)
    }
    func testVerticalAndDiagonalSequencesAreNeverClaimed() {
        for (x, y) in [(0.0, 8.0), (8, 8), (20, 40), (-10, -30)] {
            var m = RowGestureMotion(); m.begin(width: 600)
            XCTAssertFalse(m.move(dx: x, dy: y)); XCTAssertFalse(m.move(dx: 1000, dy: 0))
            XCTAssertNil(m.finish()); XCTAssertEqual(m.offset, 0)
        }
    }
    func testSmallPendingMovementCanBecomeHorizontal() {
        var m = RowGestureMotion(); m.begin(width: 600)
        XCTAssertFalse(m.move(dx: 2, dy: 1)); XCTAssertFalse(m.move(dx: 3, dy: 1))
        XCTAssertTrue(m.move(dx: 20, dy: 0)); XCTAssertEqual(m.stage, .tracking)
    }
    func testNoneAndFuturePreferenceCannotBecomeAnAction() {
        XCTAssertNil(RowGestureAction(rawValue: "future")); XCTAssertNil(RowGestureCommand(.none))
        var m = RowGestureMotion(); m.leading = .none; m.begin(width: 600)
        XCTAssertFalse(m.move(dx: 1000, dy: 0)); XCTAssertNil(m.finish())
        m.trailing = .none; m.begin(width: 600); XCTAssertFalse(m.move(dx: -1000, dy: 0)); XCTAssertNil(m.finish())
    }
    func testEnabledFullSwipeDeliversOnlyEligibleActionOnce() {
        for (delta, action) in [(1000.0, RowGestureAction.complete), (-1000, .tomorrow)] {
            var m = RowGestureMotion(); m.fullSwipe = true; m.begin(width: 600)
            XCTAssertTrue(m.move(dx: delta, dy: 0)); XCTAssertTrue(m.armed)
            XCTAssertEqual(m.finish(), action); XCTAssertNil(m.finish()); XCTAssertEqual(m.stage, .idle)
        }
        XCTAssertNil(RowGestureAction(rawValue: "delete"))
    }
    func testEditAlwaysRequiresAButton() {
        var m = RowGestureMotion(); m.fullSwipe = true; m.leading = .edit; m.trailing = .edit
        for dx in [-1000.0, 1000] {
            m.begin(width: 600); XCTAssertTrue(m.move(dx: dx, dy: 0)); XCTAssertFalse(m.armed)
            XCTAssertNil(m.finish()); XCTAssertEqual(m.stage, .open)
        }
    }
    func testCompletedTaskCannotRevealOrFullSwipeTomorrow() {
        var m = RowGestureMotion(); m.fullSwipe = true; m.canReschedule = false; m.begin(width: 600)
        XCTAssertFalse(m.move(dx: -1000, dy: 0)); XCTAssertNil(m.finish())
        m.begin(width: 600); XCTAssertTrue(m.move(dx: 1000, dy: 0)); XCTAssertEqual(m.finish(), .complete)
    }
    func testCancellationNeverFinishesAnArmedAction() {
        var m = RowGestureMotion(); m.fullSwipe = true; m.begin(width: 600); _ = m.move(dx: 1000, dy: 0)
        XCTAssertTrue(m.armed); m.cancel(); XCTAssertNil(m.finish()); XCTAssertEqual(m.offset, 0)
    }
    func testRTLChangesPhysicalDirectionWithoutChangingMeaning() {
        var m = RowGestureMotion(); m.rightToLeft = true; m.fullSwipe = true
        m.begin(width: 600); _ = m.move(dx: -1000, dy: 0); XCTAssertEqual(m.finish(), .complete)
        m.begin(width: 600); _ = m.move(dx: 1000, dy: 0); XCTAssertEqual(m.finish(), .tomorrow)
    }
    func testRevealedRowCanBeClosedByDraggingBack() {
        var m = RowGestureMotion(); m.begin(width: 600); _ = m.move(dx: 100, dy: 0); _ = m.finish()
        let initial = m.offset; m.begin(width: 600, initialOffset: initial); _ = m.move(dx: -initial, dy: 0)
        XCTAssertNil(m.finish()); XCTAssertEqual(m.stage, .idle)
    }
    func testAnAlreadyRevealedRowNeedsNewDeliberateMovementToArm() {
        var m = RowGestureMotion(); m.fullSwipe = true; m.begin(width: 320)
        _ = m.move(dx: -100, dy: 0); XCTAssertNil(m.finish()); XCTAssertEqual(m.stage, .open)
        let previous = m.offset
        m.begin(width: 320, initialOffset: previous); _ = m.move(dx: -20, dy: 0)
        XCTAssertFalse(m.armed); XCTAssertNil(m.finish())
    }
    func testInvalidDeltasAndWidthsCannotArmAnAction() {
        var m = RowGestureMotion(); m.fullSwipe = true; m.begin(width: .nan)
        XCTAssertFalse(m.move(dx: .infinity, dy: 0)); XCTAssertNil(m.finish())
        m.begin(width: 1); _ = m.move(dx: 1000, dy: 0); XCTAssertFalse(m.armed)
        XCTAssertNil(m.finish()); XCTAssertTrue(m.offset.isFinite)
    }
    func testTaskIntentFencesRootAndWorkspaceChanges() {
        let generation = UUID(), task = Record(["id": .string("root/child"), "title": .string("Review"), "completed": .bool(false)])
        let root = Record(["id": .string("root"), "task_generation": .string("incarnation"), "subtasks": .array([.object(task.fields)])])
        let intent = RowGestureIntent(task: task, root: root, workspace: WorkspaceBinding(account: "a", generation: generation))
        XCTAssertTrue(intent.matches(task, root: root, account: "a", generation: generation))
        XCTAssertFalse(intent.matches(task, root: root, account: "b", generation: generation))
        XCTAssertFalse(intent.matches(task, root: root, account: "a", generation: UUID()))
        XCTAssertFalse(intent.matches(task, root: nil, account: "a", generation: generation))
        for field in ["task_generation", "project_id", "section_id", "created_at", "subtasks"] {
            var changed = root; changed[field] = .string("changed")
            XCTAssertFalse(intent.matches(task, root: changed, account: "a", generation: generation), field)
        }
        var completed = task; completed["completed"] = .bool(true)
        XCTAssertFalse(intent.matches(completed, root: root, account: "a", generation: generation))
    }
}
