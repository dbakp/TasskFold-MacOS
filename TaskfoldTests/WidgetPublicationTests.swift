import XCTest
@testable import TaskfoldCore

private actor PublicationGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    private var started = false
    func hold() async {
        await withCheckedContinuation { continuation in
            release = continuation; started = true
            waiters.forEach { $0.resume() }; waiters = []
        }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func resume() { release?.resume(); release = nil }
}

private actor PublicationConcurrency {
    private var active = 0
    private(set) var maximum = 0
    private(set) var starts: [Int] = []
    func begin(_ value: Int) { active += 1; maximum = max(maximum, active); starts.append(value) }
    func end() { active -= 1 }
}

final class WidgetPublicationTests: XCTestCase {
    @MainActor func testNewestPendingReplacesIntermediateWithoutConcurrentRendering() async {
        let queue = WidgetPublicationQueue(), gate = PublicationGate(), concurrency = PublicationConcurrency()
        var completions: [Int] = [], secondStarted = false
        let finished = expectation(description: "latest projection")
        queue.enqueue(render: { await concurrency.begin(1); await gate.hold(); await concurrency.end(); return Data([1]) }) { _ in completions.append(1) }
        await gate.waitUntilStarted()
        queue.enqueue(render: { await concurrency.begin(2); await concurrency.end(); return Data([2]) }) { _ in completions.append(2) }
        queue.enqueue(render: { await concurrency.begin(3); await concurrency.end(); return Data([3]) }) { result in
            secondStarted = true; XCTAssertEqual(try? result.get(), Data([3])); completions.append(3); finished.fulfill()
        }
        // The first renderer deliberately ignores cancellation until released.
        await Task.yield()
        XCTAssertFalse(secondStarted); XCTAssertFalse(queue.isIdle); XCTAssertTrue(completions.isEmpty)
        await gate.resume()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(completions, [3]); XCTAssertTrue(queue.isIdle)
        let maximum = await concurrency.maximum, starts = await concurrency.starts
        XCTAssertEqual(maximum, 1); XCTAssertEqual(starts, [1, 3])
    }

    @MainActor func testInvalidatedSuccessCannotResurrectProjectionAfterSignOut() async throws {
        let queue = WidgetPublicationQueue(), gate = PublicationGate()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = WidgetActionDisk(directory: directory)
        let old = try WidgetPublicationInput(tasks: [Record(["title": .string("Private task")])], projects: [], account: "old").encoded()
        try disk.publish(old)
        queue.enqueue(render: { await gate.hold(); return old }) { result in try? disk.publish(result.get()) }
        await gate.waitUntilStarted()
        queue.invalidate()
        let redacted = try WidgetPublicationInput(tasks: [], projects: [], account: "").encoded()
        try disk.publish(redacted)
        let finished = expectation(description: "new workspace")
        queue.enqueue(render: { Data([4]) }) { result in XCTAssertEqual(try? result.get(), Data([4])); finished.fulfill() }
        await gate.resume()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(try JSONDecoder().decode([String: JSON].self, from: XCTUnwrap(disk.read().data)), try JSONDecoder().decode([String: JSON].self, from: redacted))
    }

    @MainActor func testStaleFailureCannotClearNewerPublication() async throws {
        let queue = WidgetPublicationQueue(), gate = PublicationGate()
        var oldCallbacks = 0
        queue.enqueue(render: { await gate.hold(); throw CocoaError(.fileReadCorruptFile) }) { _ in oldCallbacks += 1 }
        await gate.waitUntilStarted()
        queue.invalidate()
        let finished = expectation(description: "recovered projection")
        queue.enqueue(render: { Data([5]) }) { result in XCTAssertEqual(try? result.get(), Data([5])); finished.fulfill() }
        await gate.resume()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(oldCallbacks, 0)
    }

    @MainActor func testLatestFailureIsDeliveredAndNextRequestCanRecover() async {
        let queue = WidgetPublicationQueue()
        let failed = expectation(description: "current error")
        queue.enqueue(render: { throw CocoaError(.fileWriteOutOfSpace) }) { result in
            if case .success = result { XCTFail("Current rendering failure must reach publication cleanup") }
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 5)
        let recovered = expectation(description: "next render")
        queue.enqueue(render: { Data([6]) }) { result in XCTAssertEqual(try? result.get(), Data([6])); recovered.fulfill() }
        await fulfillment(of: [recovered], timeout: 5)
        XCTAssertTrue(queue.isIdle)
    }

    func testCapturedInputPreservesProjectionAndFeedback() throws {
        let now = Date(timeIntervalSince1970: 1793000000)
        let task = Record(["id": .string("t"), "user_id": .string("a"), "title": .string("Review"), "completed": .bool(false)])
        var input = WidgetPublicationInput(tasks: [task], projects: [], account: "a")
        input.now = now; input.pendingSync = 2
        let expected = WidgetProjection.payload(tasks: [task], projects: [], account: "a", now: now, pendingSync: 2)
        XCTAssertEqual(try JSONDecoder().decode([String: JSON].self, from: input.encoded()), expected)
        input.feedback = WidgetCompletionFeedback(account: "a", taskID: "t", title: "Review", listIDs: ["inbox"], savedAt: now)
        XCTAssertNotNil(try JSONDecoder().decode([String: JSON].self, from: input.encoded())["completionFeedback"])
        input.account = "b"
        XCTAssertNil(try JSONDecoder().decode([String: JSON].self, from: input.encoded())["completionFeedback"])
        input.account = "a"; input.now = now.addingTimeInterval(9)
        XCTAssertNil(try JSONDecoder().decode([String: JSON].self, from: input.encoded())["completionFeedback"])
        input.account = ""; input.now = now
        let redacted = try JSONDecoder().decode([String: JSON].self, from: input.encoded())
        XCTAssertEqual(redacted, ["version": .number(2), "updated": .number(0), "account": .string(""), "tasks": .array([])])
    }
}
