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
