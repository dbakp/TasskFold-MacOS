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

@MainActor final class StartupPublicationTests: XCTestCase {
    private func disk() -> (URL, WidgetActionDisk, SharedCaptureDisk) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-startup-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return (folder, WidgetActionDisk(directory: folder.appendingPathComponent("Widgets")), SharedCaptureDisk(directory: folder.appendingPathComponent("Mailbox")))
    }
    private func settle<T>(_ queue: StartupPublicationQueue<T>) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !queue.isIdle { guard ContinuousClock.now < deadline else { throw CancellationError() }; try await Task.sleep(for: .milliseconds(5)) }
    }
    func testHeldWriteDoesNotOccupyInterfaceAndKeepsOnlyNewestPendingRequest() async throws {
        let queue = StartupPublicationQueue<Int>(), gate = PublicationGate(), concurrency = PublicationConcurrency()
        var completed: [Int] = []
        queue.enqueue(write: { _ in await concurrency.begin(0); await gate.hold(); await concurrency.end(); return 0 }) { _ in completed.append(0) }
        await gate.waitUntilStarted()
        for n in 1...40 {
            queue.enqueue(write: { _ in await concurrency.begin(n); await concurrency.end(); return n }) { result in completed.append((try? result.get()) ?? -1) }
        }
        // This actor turn is available while the uncooperative file producer waits.
        XCTAssertFalse(queue.isIdle); XCTAssertTrue(completed.isEmpty)
        await gate.resume(); try await settle(queue)
        let starts = await concurrency.starts, maximum = await concurrency.maximum
        XCTAssertEqual(starts, [0, 40]); XCTAssertEqual(maximum, 1); XCTAssertEqual(completed, [40])
    }
    func testLatePublicationCannotRestorePrivateContentAfterImmediateRedaction() async throws {
        let (folder, widget, mailbox) = disk(), queue = StartupPublicationQueue<Int>(), gate = PublicationGate()
        let workspace = SharedCaptureWorkspace(account: "old", generation: UUID(), label: "Private")
        let draft = try SharedCaptureDraft(workspace: workspace, content: SharedCaptureContent(title: "Keep the draft"))
        try mailbox.publish(workspace); try mailbox.save(draft)
        let old = try WidgetPublicationInput(tasks: [Record(["id": .string("private"), "title": .string("Old task")])], projects: [], account: "old").encoded()
        try widget.publish(old)
        var callbacks = 0
        queue.enqueue(write: { ticket in
            await gate.hold()
            try mailbox.publish(workspace, admitting: { ticket.isCurrent })
            try widget.publish(old, admitting: { ticket.isCurrent })
            return 1
        }) { _ in callbacks += 1 }
        await gate.waitUntilStarted(); queue.invalidate()
        // The existing synchronous privacy path completes before the old producer resumes.
        try mailbox.publish(nil)
        let redacted = try WidgetPublicationInput(tasks: [], projects: [], account: "").encoded()
        try widget.publish(redacted)
        let mailboxBytes = try Data(contentsOf: folder.appendingPathComponent("Mailbox/shared-capture.json"))
        await gate.resume(); try await settle(queue)
        XCTAssertEqual(try widget.read().data, redacted)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Mailbox/shared-capture.json")), mailboxBytes)
        XCTAssertNil(try mailbox.workspace()); XCTAssertEqual(callbacks, 0)
        // Redaction keeps captured thoughts for a later explicit return.
        try mailbox.publish(workspace); XCTAssertEqual(try mailbox.drafts(account: "old"), [draft])
    }
    func testLateFailureCannotClearAReplacementProjection() async throws {
        let (_, widget, _) = disk(), queue = StartupPublicationQueue<Int>(), gate = PublicationGate()
        var callbacks = 0
        queue.enqueue(write: { ticket in
            await gate.hold()
            try widget.clearProjection(admitting: { ticket.isCurrent })
            throw CocoaError(.fileWriteOutOfSpace)
        }) { _ in callbacks += 1 }
        await gate.waitUntilStarted(); queue.invalidate()
        let newer = try WidgetPublicationInput(tasks: [], projects: [], account: "new").encoded(); try widget.publish(newer)
        await gate.resume(); try await settle(queue)
        XCTAssertEqual(try widget.read().data, newer); XCTAssertEqual(callbacks, 0)
    }
    func testCurrentFailureIsReportedAndCanRetryWithoutAWorkerBacklog() async throws {
        let queue = StartupPublicationQueue<Int>(); var outcomes: [Bool] = []
        queue.enqueue(write: { _ in throw CocoaError(.fileWriteNoPermission) }) { result in outcomes.append((try? result.get()) != nil) }
        try await settle(queue)
        queue.enqueue(write: { _ in 7 }) { result in outcomes.append((try? result.get()) == 7) }
        try await settle(queue); XCTAssertEqual(outcomes, [false, true])
    }
    func testInvalidTicketLeavesBothFilesByteExactEvenWithUnreadableMailbox() throws {
        let (folder, widget, mailbox) = disk(), ticket = SharedPublicationTicket()
        let projection = try WidgetPublicationInput(tasks: [], projects: [], account: "current").encoded(); try widget.publish(projection)
        try mailbox.publish(nil)
        let file = folder.appendingPathComponent("Mailbox/shared-capture.json"), bytes = Data("keep unreadable source".utf8); try bytes.write(to: file)
        ticket.invalidate()
        XCTAssertThrowsError(try mailbox.publish(nil, admitting: { ticket.isCurrent }))
        XCTAssertThrowsError(try widget.publish(Data(), admitting: { ticket.isCurrent }))
        XCTAssertThrowsError(try widget.clearProjection(admitting: { ticket.isCurrent }))
        XCTAssertEqual(try Data(contentsOf: file), bytes); XCTAssertEqual(try widget.read().data, projection)
    }
    func testBackgroundWritesUseTheActualDisksWithoutChangingSavedDrafts() async throws {
        let (_, widget, mailbox) = disk(), queue = StartupPublicationQueue<Bool>()
        let workspace = SharedCaptureWorkspace(account: "owner", generation: UUID(), label: "Current")
        let draft = try SharedCaptureDraft(workspace: workspace, content: SharedCaptureContent(title: "Full notes", notes: "Café 🪴\nSecond line"))
        try mailbox.publish(workspace); try mailbox.save(draft)
        let data = try WidgetPublicationInput(tasks: [], projects: [], account: "owner").encoded()
        var background: Bool?
        queue.enqueue(write: { ticket in
            return try Result {
                try mailbox.publish(workspace, admitting: { ticket.isCurrent })
                try widget.publish(data, admitting: { ticket.isCurrent })
                return !Thread.isMainThread
            }.get()
        }) { result in background = try? result.get() }
        try await settle(queue)
        XCTAssertEqual(background, true); XCTAssertEqual(try mailbox.drafts(account: "owner"), [draft]); XCTAssertEqual(try widget.read().data, data)
    }
}

extension StartupPublicationTests {
    func testRedactionWaitsForTheActualFileLockAndWinsOverAnAdmittedOldWriter() async throws {
        let (_, widget, _) = disk(), ticket = SharedPublicationTicket()
        let entered = expectation(description: "inside file lock"), release = DispatchSemaphore(value: 0)
        let old = try WidgetPublicationInput(tasks: [], projects: [], account: "old").encoded()
        let redacted = try WidgetPublicationInput(tasks: [], projects: [], account: "").encoded()
        let producer = Task.detached {
            try widget.publish(old, admitting: {
                entered.fulfill(); _ = release.wait(timeout: .now() + 5)
                return ticket.isCurrent
            })
        }
        await fulfillment(of: [entered], timeout: 3)
        ticket.invalidate()
        let barrier = Task.detached { try widget.publish(redacted) }
        release.signal()
        do { try await producer.value; XCTFail("Old admitted work must observe invalidation inside the file lock") } catch { XCTAssertTrue(error is CancellationError) }
        try await barrier.value
        XCTAssertEqual(try widget.read().data, redacted)
    }
}
