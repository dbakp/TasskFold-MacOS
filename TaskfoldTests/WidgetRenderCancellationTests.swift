import XCTest
@testable import TaskfoldCore

private final class RenderCheckpointBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [WidgetRenderCheckpoint] = []
    private let started = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
    func check(_ stage: WidgetRenderCheckpoint) throws {
        lock.lock(); values.append(stage); let first = stage == .pulseDay && values.filter { $0 == .pulseDay }.count == 1; lock.unlock()
        if first {
            started.signal()
            guard released.wait(timeout: .now() + 10) == .success else { throw CocoaError(.userCancelled) }
        }
        try Task.checkCancellation()
    }
    func waitForStart() async -> Bool { await Task.detached { self.started.wait(timeout: .now() + 10) == .success }.value }
    func resume() { released.signal() }
    func visited() -> [WidgetRenderCheckpoint] { lock.lock(); defer { lock.unlock() }; return values }
}

final class WidgetRenderCancellationTests: XCTestCase {
    private func fixture() -> WidgetPublicationInput {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
        let tasks = (0..<12).map { i in
            Record(["id": .string("t\(i)"), "user_id": .string("owner"), "title": .string("Review \(i)"), "project_id": .string(i < 6 ? "p1" : "p2"), "completed": .bool(false), "due_date": .string("2026-10-25"), "duration_minutes": .number(25), "subtasks": .array([])])
        }
        let projects = ["p1", "p2"].map { Record(["id": .string($0), "name": .string($0), "user_id": .string("owner")]) }
        let views = [Record(["id": .string("v"), "name": .string("Today"), "query_ast": FilterRule.predicate("today", "").document])]
        var input = WidgetPublicationInput(tasks: tasks, projects: projects, account: "owner")
        input.calendar = calendar; input.now = TaskPlanning.instant("2026-10-25T10:00:00Z")!
        input.savedViews = views; input.labels = [Record(["id": .string("l"), "name": .string("Useful")])]
        input.context = WidgetPublicationContext(snapshot: Snapshot(tables: ["tasks": tasks, "projects": projects, "saved_views": views]), account: "owner", localAccount: "owner", tokenMask: nil)
        input.feedback = WidgetCompletionFeedback(account: "owner", taskID: "t0", title: "Review", listIDs: ["inbox"], savedAt: input.now)
        return input
    }
    func testUncancelledWorkerKeepsExactFullProjectionAndFeedback() async throws {
        let input = fixture(), source = input.tasks
        let expected = try input.encoded()
        var visited: [WidgetRenderCheckpoint] = []
        let observed = try input.encoded(checking: { visited.append($0) })
        XCTAssertEqual(try TaskfoldJSONDecoder().decode(JSON.self, from: observed), try TaskfoldJSONDecoder().decode(JSON.self, from: expected))
        let current = try await Task.detached { try input.encodedForWorker() }.value
        XCTAssertEqual(try TaskfoldJSONDecoder().decode(JSON.self, from: current), try TaskfoldJSONDecoder().decode(JSON.self, from: expected))
        XCTAssertEqual(Set(visited.map(\.rawValue)), Set(["context", "lists", "list", "filterDay", "pulse", "pulseDay", "tasks", "task", "capacity", "capacityDay", "feedback", "encoding"]))
        XCTAssertTrue(AuthoredValueComparison.sameRows(input.tasks, source))
        XCTAssertNotNil(try TaskfoldJSONDecoder().decode([String: JSON].self, from: current)["completionFeedback"])
    }
    func testEveryCheckpointPropagatesCancellationWithoutReturningPartialData() throws {
        let input = fixture(), source = input.tasks
        var complete: [WidgetRenderCheckpoint] = []
        _ = try input.encoded(checking: { complete.append($0) })
        for stop in Set(complete.map(\.rawValue)) {
            var visited: [WidgetRenderCheckpoint] = [], returned = false
            do {
                _ = try input.encoded(checking: { stage in visited.append(stage); if stage.rawValue == stop { throw CancellationError() } })
                returned = true
            } catch is CancellationError { }
            catch { XCTFail("Unexpected failure: \(error)") }
            XCTAssertFalse(returned, stop); XCTAssertEqual(visited.last?.rawValue, stop)
            XCTAssertEqual(visited.count, try XCTUnwrap(complete.firstIndex { $0.rawValue == stop }) + 1)
        }
        XCTAssertTrue(AuthoredValueComparison.sameRows(input.tasks, source))
    }
    func testLongTimelineAndTaskLoopsStopBetweenItems() throws {
        let input = fixture()
        for (stop, limit) in [(WidgetRenderCheckpoint.pulseDay, 2), (.filterDay, 3), (.task, 4), (.capacityDay, 3), (.context, 3), (.list, 2)] {
            var checks = 0
            XCTAssertThrowsError(try input.encoded(checking: { stage in
                if stage == stop { checks += 1; if checks == limit { throw CancellationError() } }
            })) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(checks, limit)
        }
    }
    func testCancelledTaskStopsWorkerButKeepsImmediatePrivacyAndReceiptEncoding() async throws {
        let input = fixture(), expected = try input.encoded()
        let verified = try await Task.detached { () throws -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            var stopped = false
            do { _ = try input.encodedForWorker() } catch is CancellationError { stopped = true }
            // Synchronous action acknowledgement and privacy paths deliberately
            // finish even when their caller's task has already been cancelled.
            let acknowledgement = try input.encoded()
            var redacted = input; redacted.account = ""; redacted.context = nil
            let privacy = try TaskfoldJSONDecoder().decode([String: JSON].self, from: redacted.encoded())
            let unchanged = try TaskfoldJSONDecoder().decode(JSON.self, from: acknowledgement) == TaskfoldJSONDecoder().decode(JSON.self, from: expected)
            return stopped && unchanged && privacy["account"] == .string("") && privacy["tasks"] == .array([])
        }.value
        XCTAssertTrue(verified)
    }
    @MainActor func testSupersededRealRenderStopsBeforeLaterStagesAndPublishesNewestOnly() async throws {
        let input = fixture(), barrier = RenderCheckpointBarrier(), queue = WidgetPublicationQueue()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-render-stop-" + UUID().uuidString)
        defer { barrier.resume(); try? FileManager.default.removeItem(at: folder) }
        let disk = WidgetActionDisk(directory: folder), original = try input.encoded()
        try disk.publish(original)
        var obsoleteCallbacks = 0
        queue.enqueue(render: { try input.encoded(checking: barrier.check) }) { _ in obsoleteCallbacks += 1 }
        let started = await barrier.waitForStart(); XCTAssertTrue(started)
        guard started else { return }
        var newest = input; newest.pendingSync = 7; newest.context = nil
        let latest = newest, expected = try latest.encoded(), finished = expectation(description: "current render completes")
        queue.enqueue(render: { try latest.encodedForWorker() }) { result in
            do { try disk.publish(result.get()) } catch { XCTFail("Current publication failed: \(error)") }
            finished.fulfill()
        }
        barrier.resume()
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertEqual(try TaskfoldJSONDecoder().decode(JSON.self, from: XCTUnwrap(disk.read().data)), try TaskfoldJSONDecoder().decode(JSON.self, from: expected)); XCTAssertEqual(obsoleteCallbacks, 0); XCTAssertTrue(queue.isIdle)
        XCTAssertEqual(barrier.visited().last, .pulseDay)
        XCTAssertFalse(barrier.visited().contains(.tasks)); XCTAssertFalse(barrier.visited().contains(.encoding))
        XCTAssertTrue(AuthoredValueComparison.sameRows(input.tasks, latest.tasks))
    }
    func testCancellationDoesNotBecomeInvalidFilterOrSilentNullPulse() throws {
        let input = fixture()
        XCTAssertThrowsError(try WidgetProjection.listPayload(tasks: input.tasks, projects: input.projects, labels: input.labels, sections: [], savedViews: input.savedViews, account: input.account, now: input.now, calendar: input.calendar, checking: { if $0 == .filterDay { throw CancellationError() } })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try WidgetProjection.pulsePayload(tasks: input.tasks, projects: input.projects, activity: [], epoch: [], account: input.account, readable: true, now: input.now, calendar: input.calendar, checking: { if $0 == .pulseDay { throw CancellationError() } })) { XCTAssertTrue($0 is CancellationError) }
    }
}
