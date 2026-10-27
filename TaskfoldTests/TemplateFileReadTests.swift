import XCTest
@testable import TaskfoldCore

final class TemplateFileReadTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("template-read-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testCancellationBeforeReadingDoesNotOpenAFile() {
        let operation = WorkflowTemplateReadOperation()
        operation.cancel(); operation.cancel()
        XCTAssertThrowsError(try operation.readData(URL(fileURLWithPath: "/missing-synthetic-template.json"))) { error in
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, NSUserCancelledError)
        }
    }
    func testMissingProviderFileHasActionableRecoveryAndCanRetry() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("workflow.json")
        XCTAssertThrowsError(try WorkflowTemplateReadOperation().readData(url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("downloaded and available"))
            XCTAssertTrue(error.localizedDescription.contains("saved templates are unchanged"))
        }
        let bytes = Data("Synthetic template bytes 🙂".utf8)
        try bytes.write(to: url)
        XCTAssertEqual(try WorkflowTemplateReadOperation().readData(url), bytes)
    }
    func testProviderFailurePreservesFileAndOffersFreshRetry() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("workflow.json"), bytes = Data("Synthetic offline provider".utf8)
        try bytes.write(to: url)
        let asked = expectation(description: "Unavailable provider was consulted")
        let presenter = HeldTemplatePresenter(url: url, asked: asked, failure: URLError(.notConnectedToInternet))
        NSFileCoordinator.addFilePresenter(presenter)
        defer { presenter.release(); NSFileCoordinator.removeFilePresenter(presenter) }
        XCTAssertThrowsError(try WorkflowTemplateReadOperation().readData(url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("downloaded and available"))
        }
        wait(for: [asked], timeout: 5)
        NSFileCoordinator.removeFilePresenter(presenter)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try WorkflowTemplateReadOperation().readData(url), bytes)
    }
    func testCoordinatedReadPreservesLargeUnicodeBytesAndRejectsOversize() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("workflow.json")
        let bytes = Data(String(repeating: "Résumé 🧑🏽‍💻\r\n", count: 20_000).utf8)
        try bytes.write(to: url)
        XCTAssertEqual(try WorkflowTemplateReadOperation().readData(url), bytes)
        try Data(repeating: 32, count: WorkflowTemplateFile.maximumBytes + 1).write(to: url)
        XCTAssertThrowsError(try WorkflowTemplateReadOperation().readData(url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("2.1 MB"))
        }
    }
    func testCancellationInterruptsHeldProviderAndFreshReadSucceeds() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("workflow.json"), bytes = Data("Synthetic provider data".utf8)
        try bytes.write(to: url)
        let asked = expectation(description: "Provider was asked to make file available")
        let presenter = HeldTemplatePresenter(url: url, asked: asked)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { presenter.release(); NSFileCoordinator.removeFilePresenter(presenter) }
        let operation = WorkflowTemplateReadOperation()
        let finished = expectation(description: "Cancellation returned before provider release")
        finished.assertForOverFulfill = true
        DispatchQueue.global().async {
            do { _ = try operation.readData(url); XCTFail("Cancelled provider read returned bytes") }
            catch {
                XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
                XCTAssertEqual((error as NSError).code, NSUserCancelledError)
            }
            finished.fulfill()
        }
        wait(for: [asked], timeout: 5)
        operation.cancel()
        wait(for: [finished], timeout: 5)
        // Release the real presenter only after cancellation has returned.
        presenter.release(); NSFileCoordinator.removeFilePresenter(presenter)
        XCTAssertEqual(try WorkflowTemplateReadOperation().readData(url), bytes)
    }
}

private final class HeldTemplatePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    private let lock = NSLock()
    private var completions: [(Error?) -> Void] = []
    private var released = false
    private let asked: XCTestExpectation
    private let failure: Error?
    init(url: URL, asked: XCTestExpectation, failure: Error? = nil) {
        presentedItemURL = url; self.asked = asked; self.failure = failure
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
    }
    func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
        if let failure { asked.fulfill(); completionHandler(failure); return }
        lock.lock()
        let finish = released
        if !finish { completions.append(completionHandler) }
        lock.unlock()
        if finish { completionHandler(nil) } else { asked.fulfill() }
    }
    func release() {
        lock.lock(); released = true
        let callbacks = completions; completions = []
        lock.unlock()
        callbacks.forEach { $0(nil) }
    }
}
