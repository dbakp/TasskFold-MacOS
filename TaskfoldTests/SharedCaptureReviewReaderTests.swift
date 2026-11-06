import XCTest
@testable import TaskfoldCore

@MainActor final class SharedCaptureReviewReaderTests: XCTestCase {
    actor Gate {
        var started = false
        var waiting: [CheckedContinuation<Void, Never>] = []
        var continuation: CheckedContinuation<[SharedCaptureDraft], Error>?
        func read() async throws -> [SharedCaptureDraft] {
            try await withCheckedThrowingContinuation { c in continuation = c; started = true; waiting.forEach { $0.resume() }; waiting = [] }
        }
        func wait() async { if started { return }; await withCheckedContinuation { waiting.append($0) } }
        func finish(_ result: Result<[SharedCaptureDraft], Error>) { continuation?.resume(with: result); continuation = nil }
    }
    actor Calls {
        var values: [Int] = []
        func read(_ n: Int) -> [SharedCaptureDraft] { values.append(n); return [] }
    }
    func settle(_ reader: SharedCaptureReviewReader) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        while !reader.isIdle { guard ContinuousClock.now < limit else { throw CancellationError() }; try await Task.sleep(for: .milliseconds(5)) }
    }
    func testHeldReadKeepsInterfaceAvailableAndCoalescesRefreshes() async throws {
        let reader = SharedCaptureReviewReader(), gate = Gate(), calls = Calls()
        var completions = 0
        reader.refresh(read: { try await gate.read() }) { _ in completions += 1 }
        await gate.wait()
        for n in 1...30 { reader.refresh(read: { await calls.read(n) }) { _ in completions += 1 } }
        await gate.finish(.success([])); try await settle(reader)
        let executed = await calls.values
        XCTAssertEqual(executed, [30]); XCTAssertEqual(completions, 1)
    }
    func testLeavingReviewDiscardsHeldAndPendingReplies() async throws {
        let reader = SharedCaptureReviewReader(), gate = Gate(); var completions = 0
        reader.refresh(read: { try await gate.read() }) { _ in completions += 1 }; await gate.wait()
        reader.refresh(read: { [] }) { _ in completions += 1 }; reader.invalidate()
        await gate.finish(.failure(SharedCaptureFailure("Old read"))); try await settle(reader)
        XCTAssertEqual(completions, 0)
        reader.refresh(read: { [] }) { _ in completions += 1 }; try await settle(reader)
        XCTAssertEqual(completions, 1)
    }
    func testReadErrorCanRetryWithoutReusingFailedResult() async throws {
        let reader = SharedCaptureReviewReader(); var results: [Bool] = []
        reader.refresh(read: { throw SharedCaptureFailure("Unavailable") }) { results.append((try? $0.get()) != nil) }; try await settle(reader)
        reader.refresh(read: { [] }) { results.append((try? $0.get()) != nil) }; try await settle(reader)
        XCTAssertEqual(results, [false, true])
    }
    func testFullMailboxReviewRunsOffMainAndKeepsAllUnimportedTextAndBytes() async throws {
        let (folder, disk, workspace) = try mailbox()
        let drafts = try (0..<64).map { n in try SharedCaptureDraft(workspace: workspace, content: SharedCaptureContent(title: "Thought \(n)", notes: String(repeating: "Café notes 🪴\n", count: 5000))) }
        try encode(drafts, workspace, folder)
        let file = folder.appendingPathComponent("shared-capture.json"), bytes = try Data(contentsOf: file)
        XCTAssertGreaterThan(bytes.count, 5_000_000)
        let actual = try await Task.detached { XCTAssertFalse(Thread.isMainThread); return try disk.reviewDrafts(account: "A", receipts: [:]) }.value
        XCTAssertEqual(actual, drafts); XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testReceiptCleanupPreservesOtherAccountsAndWrongReceiptValues() throws {
        let (folder, disk, workspace) = try mailbox()
        let first = try SharedCaptureDraft(workspace: workspace, content: SharedCaptureContent(title: "Imported"))
        let second = try SharedCaptureDraft(workspace: workspace, content: SharedCaptureContent(title: "Still open", notes: "Exact notes"))
        let other = try SharedCaptureDraft(workspace: .init(account: "B", generation: UUID(), label: "Other"), content: SharedCaptureContent(title: "Other private thought"))
        try encode([first, second, other], workspace, folder)
        XCTAssertEqual(try disk.reviewDrafts(account: "A", receipts: [first.taskID:first.taskID,second.taskID:"wrong"]), [second])
        let bytes = try Data(contentsOf: folder.appendingPathComponent("shared-capture.json"))
        let saved = try TaskfoldJSONDecoder().decode(Mailbox.self, from: bytes)
        XCTAssertEqual(saved.drafts, [second, other])
        XCTAssertEqual(try disk.reviewDrafts(account: "B", receipts: [other.taskID:other.taskID]), [])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("shared-capture.json")), bytes)
    }
    func testInvalidMailboxNeverRewritesInput() throws {
        let (folder, disk, _) = try mailbox(), file = folder.appendingPathComponent("shared-capture.json")
        let bytes = Data("not a mailbox".utf8); try bytes.write(to: file)
        XCTAssertThrowsError(try disk.reviewDrafts(account: "A", receipts: [:])); XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testCancelledReviewCannotRetireImportedDrafts() async throws {
        let (folder, disk, workspace) = try mailbox()
        let draft = try SharedCaptureDraft(workspace: workspace, content: SharedCaptureContent(title: "Keep until review"))
        try encode([draft], workspace, folder)
        let file = folder.appendingPathComponent("shared-capture.json"), original = try Data(contentsOf: file)
        let gate = Gate()
        let worker = Task.detached {
            _ = try await gate.read()
            return try disk.reviewDrafts(account: "A", receipts: [draft.taskID:draft.taskID])
        }
        await gate.wait(); worker.cancel(); await gate.finish(.success([]))
        do { _ = try await worker.value; XCTFail("Cancelled review was accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    struct Mailbox: Codable { var version = 1; let workspace: SharedCaptureWorkspace; let drafts: [SharedCaptureDraft] }
    func mailbox() throws -> (URL, SharedCaptureDisk, SharedCaptureWorkspace) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-review-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return (folder, SharedCaptureDisk(directory: folder), .init(account: "A", generation: UUID(), label: "Review"))
    }
    func encode(_ drafts: [SharedCaptureDraft], _ workspace: SharedCaptureWorkspace, _ folder: URL) throws {
        try TaskfoldJSONEncoder().encode(Mailbox(workspace: workspace, drafts: drafts)).write(to: folder.appendingPathComponent("shared-capture.json"))
    }
}

@MainActor final class SharedCaptureActionWorkerTests: XCTestCase {
    private func mailbox() throws -> (URL, SharedCaptureDisk, SharedCaptureWorkspace) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-share-action-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let disk = SharedCaptureDisk(directory: folder)
        let workspace = SharedCaptureWorkspace(account: "owner", generation: UUID(), label: "Original")
        try disk.publish(workspace)
        return (folder, disk, workspace)
    }
    func testBlockedActionLeavesMainActorAvailableAndRefusesConcurrentBacklog() async throws {
        let worker = SharedCaptureActionWorker(), started = expectation(description: "background action")
        let release = DispatchSemaphore(value: 0)
        let task = Task { try await worker.perform { started.fulfill(); _ = release.wait(timeout: .now() + 5); return Thread.isMainThread } }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(worker.busy)
        do { _ = try await worker.perform { 2 }; XCTFail("Do not enqueue a second mailbox action") }
        catch { XCTAssertTrue(error is SharedCaptureFailure) }
        var interfaceResponded = false
        Task { @MainActor in interfaceResponded = true }
        await Task.yield()
        XCTAssertTrue(interfaceResponded)
        release.signal()
        let ranOnMain = try await task.value
        XCTAssertFalse(ranOnMain); XCTAssertFalse(worker.busy)
        let next = try await worker.perform { 3 }; XCTAssertEqual(next, 3)
    }
    func testCancelledAcknowledgementKeepsEveryMailboxByteAndCanRetry() async throws {
        let (folder, disk, workspace) = try mailbox()
        let draft = try SharedCaptureDraft(workspace: workspace, content: SharedCaptureContent(title: "Keep this thought"))
        try disk.save(draft)
        let file = folder.appendingPathComponent("shared-capture.json"), before = try Data(contentsOf: file)
        let worker = SharedCaptureActionWorker(), started = expectation(description: "held acknowledgement"), release = DispatchSemaphore(value: 0)
        let task = Task { try await worker.perform { started.fulfill(); _ = release.wait(timeout: .now() + 5); try disk.acknowledge(draft, account: "owner", generation: workspace.generation) } }
        await fulfillment(of: [started], timeout: 3)
        task.cancel(); release.signal()
        do { try await task.value; XCTFail("Cancelled action must not report success") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: file), before); XCTAssertFalse(worker.busy)
        try await worker.perform { try disk.acknowledge(draft, account: "owner", generation: workspace.generation) }
        XCTAssertTrue(try disk.drafts(account: "owner").isEmpty)
    }
    func testSameAccountNewSessionRefusesLateAcknowledgementWithoutChangingBytes() async throws {
        let (folder, disk, workspace) = try mailbox()
        let draft = try SharedCaptureDraft(workspace: workspace, content: SharedCaptureContent(title: "Original session"))
        try disk.save(draft)
        try disk.publish(.init(account: "owner", generation: UUID(), label: "New session"))
        let file = folder.appendingPathComponent("shared-capture.json"), before = try Data(contentsOf: file)
        do { try await SharedCaptureActionWorker().perform { try disk.acknowledge(draft, account: "owner", generation: workspace.generation) }; XCTFail("A late callback cannot clear a new session") }
        catch { XCTAssertTrue(error is SharedCaptureFailure) }
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testActionFailureReleasesWorkerAndPreservesCorruptMailbox() async throws {
        let (folder, disk, _) = try mailbox(), worker = SharedCaptureActionWorker()
        let file = folder.appendingPathComponent("shared-capture.json"), bytes = Data("unreadable original".utf8)
        try bytes.write(to: file)
        do { _ = try await worker.perform { try disk.drafts(account: "owner") }; XCTFail("Do not replace unreadable drafts") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), bytes); XCTAssertFalse(worker.busy)
        let next = try await worker.perform { true }; XCTAssertTrue(next)
    }
    func testLargeAcknowledgementKeepsExactOtherDraftsAndRunsOffMain() async throws {
        let (folder, disk, workspace) = try mailbox()
        let drafts = try (0..<64).map { n in try SharedCaptureDraft(workspace: workspace, content: SharedCaptureContent(title: "Thought \(n)", notes: String(repeating: "Exact café notes 🪴\n", count: 4000))) }
        let state: [String: JSON] = ["version": .number(1), "workspace": try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(workspace)), "drafts": try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(drafts))]
        let file = folder.appendingPathComponent("shared-capture.json")
        try JSONEncoder().encode(state).write(to: file)
        XCTAssertGreaterThan(try Data(contentsOf: file).count, 5_000_000)
        let ranOnMain = try await SharedCaptureActionWorker().perform {
            try disk.acknowledge(drafts[0], account: "owner", generation: workspace.generation)
            return Thread.isMainThread
        }
        XCTAssertFalse(ranOnMain); XCTAssertEqual(try disk.drafts(account: "owner"), Array(drafts.dropFirst()))
    }
}
