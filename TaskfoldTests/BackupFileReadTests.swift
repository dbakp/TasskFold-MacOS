import Foundation
import XCTest
@testable import TaskfoldCore

final class BackupFileReadTests: XCTestCase {
    private func temporaryFile(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder.appendingPathComponent("backup.json"))
    }

    func testReadCoordinatesPendingPresenterSaveBeforeParsing() throws {
        try temporaryFile { url in
            let stale = WorkspaceBackup.make(Snapshot(), account: "stale")
            let latest = WorkspaceBackup.make(Snapshot(), account: "latest")
            try stale.data().write(to: url)
            let presenter = SavingBackupPresenter(url: url, contents: try latest.data())
            NSFileCoordinator.addFilePresenter(presenter)
            defer { NSFileCoordinator.removeFilePresenter(presenter) }
            // The previous direct read returns stale content while a presenter has pending edits.
            XCTAssertEqual(try WorkspaceBackup.read(Data(contentsOf: url)).id, stale.id)
            let read = try WorkspaceBackup.readFile(url)
            XCTAssertEqual(read.id, latest.id)
            XCTAssertEqual(read.sourceAccount, "latest")
        }
    }

    func testPresenterFailureDoesNotSilentlyReadStaleBackup() throws {
        try temporaryFile { url in
            let data = try WorkspaceBackup.make(Snapshot(), account: "stale").data()
            try data.write(to: url)
            let presenter = SavingBackupPresenter(url: url, contents: data, failure: CocoaError(.fileReadNoPermission))
            NSFileCoordinator.addFilePresenter(presenter)
            defer { NSFileCoordinator.removeFilePresenter(presenter) }
            XCTAssertThrowsError(try WorkspaceBackup.readFile(url)) { error in
                XCTAssertTrue(error.localizedDescription.contains("choose it again"))
                XCTAssertTrue(error.localizedDescription.contains("Your current work is unchanged."))
            }
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testMissingFileThrowsAndSubsequentReadCanRetry() throws {
        try temporaryFile { url in
            XCTAssertThrowsError(try WorkspaceBackup.readFile(url))
            let backup = WorkspaceBackup.make(Snapshot(), account: "retry")
            try backup.data().write(to: url)
            XCTAssertEqual(try WorkspaceBackup.readFile(url).id, backup.id)
        }
    }

    func testCancelledReadNeverReturnsBackupAndNewOperationCanRetry() throws {
        try temporaryFile { url in
            let backup = WorkspaceBackup.make(Snapshot(), account: "cancel-retry")
            let bytes = try backup.data()
            try bytes.write(to: url)
            let operation = BackupFileReadOperation()
            operation.cancel()
            XCTAssertThrowsError(try operation.read(url)) { error in
                XCTAssertEqual((error as NSError).code, NSUserCancelledError)
            }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertEqual(try BackupFileReadOperation().read(url).id, backup.id)
        }
    }

    func testCancelInterruptsWaitingPresenterAndPreservesFileForRetry() throws {
        try temporaryFile { url in
            let backup = WorkspaceBackup.make(Snapshot(), account: "waiting-provider")
            let bytes = try backup.data()
            try bytes.write(to: url)
            let entered = expectation(description: "Presenter received save request")
            let ended = expectation(description: "Cancelled coordination returned")
            let presenter = HoldingBackupPresenter(url: url) { entered.fulfill() }
            NSFileCoordinator.addFilePresenter(presenter)
            defer { presenter.release(); NSFileCoordinator.removeFilePresenter(presenter) }
            let operation = BackupFileReadOperation()
            DispatchQueue.global().async {
                do { _ = try operation.read(url); XCTFail("Cancelled read returned a backup") }
                catch { XCTAssertEqual((error as NSError).code, NSUserCancelledError) }
                ended.fulfill()
            }
            wait(for: [entered], timeout: 5)
            operation.cancel()
            // Cancellation must end the reader even while the provider is held.
            wait(for: [ended], timeout: 5)
            presenter.release()
            NSFileCoordinator.removeFilePresenter(presenter)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertEqual(try BackupFileReadOperation().read(url).id, backup.id)
        }
    }

    func testCoordinatedReadRejectsOversizedFileBeforeDecoding() throws {
        try temporaryFile { url in
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(WorkspaceBackup.maximumBytes + 1))
            try handle.close()
            XCTAssertThrowsError(try WorkspaceBackup.readFile(url)) { error in
                XCTAssertEqual(error as? BackupFailure, BackupFailure(message: "Choose a backup no larger than 256 MB."))
            }
        }
    }
}

private final class SavingBackupPresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let contents: Data
    private let failure: Error?
    init(url: URL, contents: Data, failure: Error? = nil) {
        presentedItemURL = url
        self.contents = contents
        self.failure = failure
    }
    func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
        if let failure { completionHandler(failure); return }
        do {
            try contents.write(to: presentedItemURL!)
            completionHandler(nil)
        } catch { completionHandler(error) }
    }
}

private final class HoldingBackupPresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    private let lock = NSLock()
    private var completion: ((Error?) -> Void)?
    private var released = false
    private let entered: () -> Void
    init(url: URL, entered: @escaping () -> Void) {
        presentedItemURL = url
        self.entered = entered
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
    }
    func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
        lock.lock()
        let finishNow = released
        if !finishNow { completion = completionHandler }
        lock.unlock()
        entered()
        if finishNow { completionHandler(nil) }
    }
    func release() {
        lock.lock()
        released = true
        let callback = completion; completion = nil
        lock.unlock()
        callback?(nil)
    }
}
