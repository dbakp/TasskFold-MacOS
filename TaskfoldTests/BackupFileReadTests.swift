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
            XCTAssertThrowsError(try WorkspaceBackup.readFile(url))
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
