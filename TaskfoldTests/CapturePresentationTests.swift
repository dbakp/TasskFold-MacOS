import XCTest
@testable import TaskfoldCore

final class CapturePresentationTests: XCTestCase {
    func testRequestWaitsForDestinationMountAndIsConsumedOnlyOnce() {
        let generation = UUID()
        var queue = CapturePresentationQueue()
        queue.request(destination: "inbox", workspace: WorkspaceBinding(account: "owner", generation: generation))
        XCTAssertFalse(queue.take(destination: "today", account: "owner", generation: generation))
        XCTAssertNotNil(queue.pending)
        XCTAssertTrue(queue.take(destination: "inbox", account: "owner", generation: generation))
        XCTAssertFalse(queue.take(destination: "inbox", account: "owner", generation: generation), "Remount must not reopen the capture")
    }
    func testAccountSwitchAndSameAccountReentryRetireOldRequest() {
        let generation = UUID()
        for (account, receivingGeneration) in [("other", generation), ("owner", UUID())] {
            var queue = CapturePresentationQueue()
            queue.request(destination: "inbox", workspace: WorkspaceBinding(account: "owner", generation: generation))
            XCTAssertFalse(queue.take(destination: "inbox", account: account, generation: receivingGeneration))
            XCTAssertNil(queue.pending)
            XCTAssertFalse(queue.take(destination: "inbox", account: "owner", generation: generation))
        }
    }
    func testLatestIntentWinsWithoutPresentingInPreviousDestination() {
        var queue = CapturePresentationQueue()
        let generation = UUID(), workspace = WorkspaceBinding(account: "owner", generation: UUID())
        queue.request(destination: "inbox", workspace: WorkspaceBinding(account: "owner", generation: generation))
        queue.request(destination: "calendar", workspace: workspace)
        XCTAssertFalse(queue.take(destination: "inbox", account: "owner", generation: workspace.generation))
        XCTAssertTrue(queue.take(destination: "calendar", account: "owner", generation: workspace.generation))
    }
    func testNavigationCancellationAndSignedOutRequestDoNotReopenCapture() {
        var queue = CapturePresentationQueue()
        let workspace = WorkspaceBinding(account: "owner", generation: UUID())
        queue.request(destination: "project:one", workspace: workspace)
        queue.cancel()
        XCTAssertFalse(queue.take(destination: "project:one", account: "owner", generation: workspace.generation))
        queue.request(destination: "inbox", workspace: WorkspaceBinding(account: "", generation: workspace.generation))
        XCTAssertNil(queue.pending)
    }
}
