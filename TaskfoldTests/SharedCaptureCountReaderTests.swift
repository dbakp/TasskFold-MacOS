import XCTest
@testable import TaskfoldCore

@MainActor final class SharedCaptureCountReaderTests: XCTestCase {
    actor Gate {
        var started = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var continuation: CheckedContinuation<Int, Error>?
        func read() async throws -> Int {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation; started = true
                waiters.forEach { $0.resume() }; waiters = []
            }
        }
        func wait() async { if started { return }; await withCheckedContinuation { waiters.append($0) } }
        func finish(_ result: Result<Int, Error>) { continuation?.resume(with: result); continuation = nil }
    }
    actor Calls {
        var values: [Int] = []
        func read(_ value: Int) -> Int { values.append(value); return value }
        func all() -> [Int] { values }
    }
    private func settled(_ reader: SharedCaptureCountReader) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !reader.isIdle {
            guard ContinuousClock.now < deadline else { throw SharedCaptureFailure("Count did not settle") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func testHeldReadLeavesInterfaceFreeAndOnlyNewestPendingReadRuns() async throws {
        let reader = SharedCaptureCountReader(), gate = Gate(), calls = Calls()
        var values: [Int] = []
        reader.refresh(read: { try await gate.read() }) { if case .success(let value) = $0 { values.append(value) } }
        await gate.wait()
        var interfaceTaps = 0; interfaceTaps += 1; XCTAssertEqual(interfaceTaps, 1)
        for value in 1...60 {
            reader.refresh(read: { await calls.read(value) }) { if case .success(let value) = $0 { values.append(value) } }
        }
        await gate.finish(.success(2)); try await settled(reader)
        XCTAssertEqual(values, [60]); let actual = await calls.all(); XCTAssertEqual(actual, [60])
    }
    func testInvalidationDropsHeldAndPendingReadsWithoutClearingNewWorkspaceCount() async throws {
        let reader = SharedCaptureCountReader(), gate = Gate(), calls = Calls(); var count = 7
        reader.refresh(read: { try await gate.read() }) { count = (try? $0.get()) ?? 0 }
        await gate.wait()
        reader.refresh(read: { await calls.read(8) }) { count = (try? $0.get()) ?? 0 }
        reader.invalidate(); count = 0
        await gate.finish(.success(6)); try await settled(reader)
        XCTAssertEqual(count, 0); let actual = await calls.all(); XCTAssertEqual(actual, [])
    }
    func testOldFailureCannotClearNewResultAndCurrentFailureCanRetry() async throws {
        let reader = SharedCaptureCountReader(), gate = Gate(); var count = 4
        reader.refresh(read: { try await gate.read() }) { count = (try? $0.get()) ?? 0 }
        await gate.wait()
        reader.refresh(read: { 3 }) { count = (try? $0.get()) ?? 0 }
        await gate.finish(.failure(SharedCaptureFailure("Old read"))); try await settled(reader)
        XCTAssertEqual(count, 3)
        reader.refresh(read: { throw SharedCaptureFailure("Current read") }) { count = (try? $0.get()) ?? 0 }
        try await settled(reader); XCTAssertEqual(count, 0)
        reader.refresh(read: { 2 }) { count = (try? $0.get()) ?? 0 }
        try await settled(reader); XCTAssertEqual(count, 2)
    }
    func testForegroundReadsAreFreshEvenWithoutContextChange() async throws {
        let reader = SharedCaptureCountReader(), calls = Calls(); var values: [Int] = []
        for value in 1...3 {
            reader.refresh(read: { await calls.read(value) }) { if case .success(let value) = $0 { values.append(value) } }
            try await settled(reader)
        }
        XCTAssertEqual(values, [1, 2, 3]); let actual = await calls.all(); XCTAssertEqual(actual, values)
    }
    func testImpossibleCountsFailClosed() async throws {
        let reader = SharedCaptureCountReader(); var successes = 0, failures = 0
        for value in [-1, 65, Int.max] {
            reader.refresh(read: { value }) { if case .failure = $0 { failures += 1 } else { successes += 1 } }
            try await settled(reader)
        }
        XCTAssertEqual(successes, 0); XCTAssertEqual(failures, 3)
    }
    func testExactForegroundReviewCountSurvivesAnOlderBackgroundReply() async throws {
        let reader = SharedCaptureCountReader(), gate = Gate(); var count = 0
        reader.refresh(read: { try await gate.read() }) { count = (try? $0.get()) ?? 0 }
        await gate.wait()
        reader.invalidate(); count = 3 // A synchronous explicit review has a newer exact count.
        await gate.finish(.success(2)); try await settled(reader)
        XCTAssertEqual(count, 3)
        reader.refresh(read: { 4 }) { count = (try? $0.get()) ?? 0 }
        try await settled(reader); XCTAssertEqual(count, 4)
    }
    struct Mailbox: Codable { let version: Int; let workspace: SharedCaptureWorkspace?; let drafts: [SharedCaptureDraft] }
    private func mailbox(_ drafts: Int) throws -> (URL, SharedCaptureDisk, SharedCaptureWorkspace, [SharedCaptureDraft]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-count-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let workspace = SharedCaptureWorkspace(account: "A", generation: UUID(), label: "Count read")
        let rows = try (0..<drafts).map { n in try SharedCaptureDraft(workspace: workspace, content: SharedCaptureContent(title: "Thought \(n)", notes: String(repeating: "Café notes 🪴 ", count: 5000))) }
        let data = try TaskfoldJSONEncoder().encode(Mailbox(version: 1, workspace: workspace, drafts: rows))
        try data.write(to: folder.appendingPathComponent("shared-capture.json"))
        return (folder, SharedCaptureDisk(directory: folder), workspace, rows)
    }
    func testActualFullMailboxDecodesOffInterfaceAndPreservesEveryByte() async throws {
        let (folder, disk, owner, rows) = try mailbox(64), file = folder.appendingPathComponent("shared-capture.json")
        let before = try Data(contentsOf: file), reader = SharedCaptureCountReader()
        XCTAssertGreaterThan(before.count, 5_000_000); XCTAssertLessThan(before.count, SharedCaptureDisk.maximumFileBytes)
        var result: Result<Int, Error>?
        reader.refresh(read: {
            guard !Thread.isMainThread else { throw SharedCaptureFailure("Read ran on interface") }
            return try disk.unhandledDraftCount(account: owner.account, receipts: [rows[0].taskID: rows[0].taskID, rows[1].taskID: "wrong", "unrelated": "unrelated"])
        }) { result = $0 }
        try await settled(reader)
        XCTAssertEqual(try XCTUnwrap(result).get(), 63)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try disk.unhandledDraftCount(account: "B", receipts: [:]), 0)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testCorruptUnsupportedAndOverCapacityMailboxCannotProduceBadge() throws {
        let (folder, disk, owner, rows) = try mailbox(1), file = folder.appendingPathComponent("shared-capture.json")
        let cases = [Data("not JSON".utf8), try TaskfoldJSONEncoder().encode(Mailbox(version: 2, workspace: owner, drafts: rows)), try TaskfoldJSONEncoder().encode(Mailbox(version: 1, workspace: owner, drafts: rows + rows)), try TaskfoldJSONEncoder().encode(Mailbox(version: 1, workspace: owner, drafts: try (0..<65).map { n in try SharedCaptureDraft(workspace: owner, content: SharedCaptureContent(title: "Thought \(n)")) }))]
        for data in cases {
            try data.write(to: file); XCTAssertThrowsError(try disk.unhandledDraftCount(account: owner.account, receipts: [:])); XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }
}
