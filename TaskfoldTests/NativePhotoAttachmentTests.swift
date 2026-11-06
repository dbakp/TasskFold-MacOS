import XCTest
import CryptoKit
@testable import TaskfoldCore

final class NativePhotoAttachmentTests: XCTestCase {
    func testMacReadsNativePhotoAttachmentAndRetainsItThroughPortableRestore() throws {
        guard let path = ProcessInfo.processInfo.environment["TASKFOLD_NATIVE_PHOTO_SNAPSHOT"] else {
            throw XCTSkip("Requires the isolated iOS native photo-selection snapshot")
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertTrue(snapshot.pending.isEmpty)
        let task = try XCTUnwrap(snapshot.tables["tasks"]?.first { $0.title == "Photo import check" })
        XCTAssertEqual(task.string("user_id"), "ui-testing")
        XCTAssertFalse(task.completed)
        XCTAssertEqual(task["attachments"].list.count, 1)
        let attachment = Record(try XCTUnwrap(task["attachments"].list.first).object)
        XCTAssertNotNil(UUID(uuidString: attachment.id))
        XCTAssertEqual(attachment.name, "Photo.png")
        XCTAssertEqual(attachment.string("type"), "image/png")
        let value = attachment.string("url")
        XCTAssertTrue(value.hasPrefix("data:image/png;base64,"))
        let payload = try XCTUnwrap(value.split(separator: ",", maxSplits: 1).last)
        let image = try XCTUnwrap(Data(base64Encoded: String(payload)))
        XCTAssertEqual(attachment["size"], .number(Double(image.count)))
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "Taskfold-P0-attachment-checker", withExtension: "png", subdirectory: "Fixtures"))
        let fixture = try Data(contentsOf: fixtureURL)
        XCTAssertEqual(image, fixture, "The native picker must save the selected synthetic image, without replacing or corrupting its bytes")
        print("NATIVE_PHOTO_SHA256 " + SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined())
        let portable = try WorkspaceBackup.read(WorkspaceBackup.make(snapshot, account: "ui-testing").data())
        let receiver = "11111111-1111-4111-8111-111111111111"
        let plan = try portable.plan(current: Snapshot(), account: receiver)
        var restored = Snapshot(); plan.changes.forEach { restored.apply($0) }
        let received = try XCTUnwrap(restored.tables["tasks"]?.first { $0.title == task.title })
        XCTAssertEqual(received.string("user_id"), receiver)
        XCTAssertNotEqual(received.id, task.id)
        XCTAssertEqual(received["attachments"], task["attachments"], "Portable restore must retain the complete image and attachment identity")
        XCTAssertFalse(received.completed)
        XCTAssertEqual(try portable.plan(current: restored, account: receiver).total, 0)
    }
}
