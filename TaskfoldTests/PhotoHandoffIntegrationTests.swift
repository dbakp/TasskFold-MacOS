import XCTest
import CryptoKit
@testable import TaskfoldCore

/// Authenticated Mac transport plus actual phone/tablet caches; no Mac GUI launch.
final class PhotoHandoffIntegrationTests: XCTestCase {
    @MainActor func testMacReadsCloudPhotoAndOfflineDeviceSnapshotsWithoutIdentityOrByteLoss() async throws {
        guard let path = ProcessInfo.processInfo.environment["TASKFOLD_PHOTO_HANDOFF_FIXTURE"],
              let directory = ProcessInfo.processInfo.environment["TASKFOLD_PHOTO_HANDOFF_RESULTS"] else {
            throw XCTSkip("Requires disposable native photo handoff fixture and snapshots")
        }
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let owner = try XCTUnwrap(fixture["userID"])
        guard UUID(uuidString: owner) != nil, fixture["email"] == "taskfold-continuity-" + owner + "@example.invalid" else {
            throw XCTSkip("Requires disposable continuity namespace")
        }
        let backend = Backend(configuration: ["URL": try XCTUnwrap(fixture["url"]), "Key": try XCTUnwrap(fixture["key"])], session: nil, persistSession: { _ in })
        let signedIn = try await backend.signIn(email: try XCTUnwrap(fixture["email"]), password: try XCTUnwrap(fixture["password"]), signup: false)
        XCTAssertTrue(signedIn); XCTAssertEqual(backend.session?.user.id, owner)
        let rows = try await backend.rows("tasks"); XCTAssertEqual(rows.count, 1)
        let remote = try XCTUnwrap(rows.first)
        XCTAssertEqual(remote.id, fixture["taskID"]); XCTAssertEqual(remote.string("user_id"), owner)
        XCTAssertEqual(remote.title, "Photo handoff check"); XCTAssertFalse(remote.completed)
        XCTAssertEqual(remote.string("description"), "Reviewed offline on tablet")
        XCTAssertEqual(remote["attachments"].list.count, 1)
        let attachment = Record(try XCTUnwrap(remote["attachments"].list.first).object)
        XCTAssertEqual(attachment.id, fixture["attachmentID"]); XCTAssertEqual(attachment.name, "Photo.png")
        XCTAssertEqual(attachment.string("type"), "image/png")
        let value = attachment.string("url"); XCTAssertTrue(value.hasPrefix("data:image/png;base64,"))
        let bytes = try XCTUnwrap(Data(base64Encoded: String(try XCTUnwrap(value.split(separator: ",", maxSplits: 1).last))))
        let imageURL = try XCTUnwrap(Bundle.module.url(forResource: "Taskfold-P0-attachment-checker", withExtension: "png", subdirectory: "Fixtures"))
        XCTAssertEqual(bytes, try Data(contentsOf: imageURL)); XCTAssertEqual(attachment["size"], .number(Double(bytes.count)))
        for phase in ["phone-create", "tablet-offline", "tablet-reconnect", "phone-final"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(phase + "-snapshot.json")
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
            let task = try XCTUnwrap(snapshot.tables["tasks"]?.first { $0.id == remote.id })
            XCTAssertEqual(task.string("user_id"), owner); XCTAssertFalse(task.completed)
            XCTAssertEqual(task["attachments"], remote["attachments"], "Every native stage must preserve the entire original attachment object")
            XCTAssertEqual(task.string("description"), phase == "phone-create" ? "" : "Reviewed offline on tablet")
            XCTAssertEqual(snapshot.pending.count, phase == "tablet-offline" ? 1 : 0)
            if phase == "tablet-offline" {
                let pending = try XCTUnwrap(snapshot.pending.first)
                XCTAssertEqual(pending.table, "tasks"); XCTAssertEqual(pending.recordID, remote.id)
                XCTAssertEqual(pending.fields["description"], .string("Reviewed offline on tablet"))
            }
        }
        print("CLOUD_PHOTO_SHA256 " + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
}
