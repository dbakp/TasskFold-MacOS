import XCTest
import Darwin
@testable import TaskfoldCore

final class AudioCommentTaskAdmissionTests: XCTestCase {
    let account = "local"
    let generation = "ac290000-0000-4000-8000-000000000005"
    func task(project: String = "") -> Record {
        var row = Record.task(user: account, project: project)
        row["title"] = .string("Keep the original notes"); row["task_generation"] = .string(generation)
        return row
    }
    func project(id: String = UUID().uuidString.lowercased()) -> Record {
        Record(["id": .string(id), "user_id": .string(account), "is_archived": .bool(false)])
    }
    func testInboxAndOwnedProjectTargetsPreserveTheirCompleteSource() throws {
        let inbox = task(), project = project(), inProject = task(project: project.id)
        let first = try AudioCommentTaskAdmission.target(account: account, task: inbox, projects: [])
        XCTAssertEqual(first.task, UUID(uuidString: inbox.id)); XCTAssertEqual(first.generation, UUID(uuidString: generation)); XCTAssertNil(first.project)
        let second = try AudioCommentTaskAdmission.target(account: account, task: inProject, projects: [project])
        XCTAssertEqual(second.project, UUID(uuidString: project.id)); XCTAssertNotEqual(first, second)
        var renamed = inProject; renamed["title"] = .string("Changed title only"); renamed["description"] = .string("Other notes")
        XCTAssertEqual(try AudioCommentTaskAdmission.target(account: account, task: renamed, projects: [project]), second)
        var heading = inProject; heading["is_heading"] = .bool(true)
        XCTAssertEqual(try AudioCommentTaskAdmission.target(account: account, task: heading, projects: [project]), second)
        XCTAssertEqual(inbox.string("title"), "Keep the original notes"); XCTAssertEqual(inProject.string("task_generation"), generation)
    }
    func testMalformedLegacyForeignAndFutureTaskIdentitiesRefuse() throws {
        let original = task()
        for (field, value) in [("task_generation", JSON.null), ("task_generation", .string("not-a-generation")), ("task_generation", .string(AudioCommentTarget.zero.uuidString)), ("id", .string(AudioCommentTarget.zero.uuidString)), ("user_id", .string("another-account")), ("project_id", .number(1)), ("is_heading", .string("future"))] {
            var row = original; row[field] = value
            XCTAssertThrowsError(try AudioCommentTaskAdmission.target(account: account, task: row, projects: []), field)
        }
        var row = original; row["user_id"] = .string("café")
        XCTAssertThrowsError(try AudioCommentTaskAdmission.target(account: "cafe\u{301}", task: row, projects: []))
        XCTAssertThrowsError(try AudioCommentTaskAdmission.target(account: "", task: original, projects: []))
    }
    func testMissingSharedForeignArchivedAndAmbiguousProjectsRefuse() throws {
        let original = project(), row = task(project: original.id)
        XCTAssertThrowsError(try AudioCommentTaskAdmission.target(account: account, task: row, projects: []))
        XCTAssertThrowsError(try AudioCommentTaskAdmission.target(account: account, task: row, projects: [original, original]))
        for (field, value) in [("user_id", JSON.string("other")), ("team_id", .string(UUID().uuidString)), ("is_archived", .bool(true)), ("is_archived", .string("future"))] {
            var changed = original; changed[field] = value
            XCTAssertThrowsError(try AudioCommentTaskAdmission.target(account: account, task: row, projects: [changed]))
        }
        var parent = project(), child = original; parent["is_archived"] = .bool(true); child["parent_id"] = .string(parent.id)
        XCTAssertThrowsError(try AudioCommentTaskAdmission.target(account: account, task: row, projects: [parent, child]))
    }
    func testGenerationAndProjectMovesSelectADifferentRecordingTarget() throws {
        let first = task(), project = project(); var restored = first; restored["task_generation"] = .string(UUID().uuidString.lowercased())
        let baseline = try AudioCommentTaskAdmission.target(account: account, task: first, projects: [])
        XCTAssertNotEqual(try AudioCommentTaskAdmission.target(account: account, task: restored, projects: []), baseline)
        var moved = first; moved["project_id"] = .string(project.id)
        XCTAssertNotEqual(try AudioCommentTaskAdmission.target(account: account, task: moved, projects: [project]), baseline)
    }
    func testAppIdentitiesCannotShareAPrivateAudioDirectory() throws {
        let production = try AudioCommentTaskAdmission.applicationDirectory(bundleIdentifier: "com.example.taskfold")
        let test = try AudioCommentTaskAdmission.applicationDirectory(bundleIdentifier: "com.example.taskfold.test")
        XCTAssertNotEqual(production, test); XCTAssertFalse(production.contains("com.example")); XCTAssertFalse(production.contains("/"))
        XCTAssertEqual(production, try AudioCommentTaskAdmission.applicationDirectory(bundleIdentifier: "com.example.taskfold"))
        XCTAssertThrowsError(try AudioCommentTaskAdmission.applicationDirectory(bundleIdentifier: ""))
        XCTAssertThrowsError(try AudioCommentTaskAdmission.applicationDirectory(bundleIdentifier: "invalid\0app"))
    }
    func testLocalAndDistinctServersHaveIndependentNonPathNamespaces() throws {
        let local = try AudioCommentTaskAdmission.storageDirectory(origin: nil)
        let first = try AudioCommentTaskAdmission.storageDirectory(origin: "https://first.example.invalid")
        let second = try AudioCommentTaskAdmission.storageDirectory(origin: "https://second.example.invalid")
        XCTAssertEqual(Set([local, first, second]).count, 3); XCTAssertFalse(first.contains("first.example")); XCTAssertFalse(first.contains("/"))
        XCTAssertEqual(first, try AudioCommentTaskAdmission.storageDirectory(origin: "https://first.example.invalid"))
        for origin in ["http://first.example.invalid", "https://user:secret@example.invalid", "https://example.invalid/path", "https://example.invalid?token=x", "https://example.invalid#fragment", "invalid"] {
            XCTAssertThrowsError(try AudioCommentTaskAdmission.storageDirectory(origin: origin))
        }
    }
}

extension AudioCommentVaultTests {
    func testPreparedAppNamespacesArePrivateBackupExcludedAndServerIsolated() async throws {
        let first = root.appendingPathComponent("AppAudio").appendingPathComponent(try AudioCommentTaskAdmission.storageDirectory(origin: "https://first.example.invalid"))
        let second = root.appendingPathComponent("AppAudio").appendingPathComponent(try AudioCommentTaskAdmission.storageDirectory(origin: "https://second.example.invalid"))
        let owner = try AudioCommentOwner(account), draft = try self.draft(owner)
        let a = try await AudioCommentDraftStorage.open(applicationSupport: first, owner: owner)
        try await a.save(draft)
        let b = try await AudioCommentDraftStorage.open(applicationSupport: second, owner: owner)
        let other = try await b.drafts(); XCTAssertTrue(other.isEmpty)
        let reopened = try await AudioCommentDraftStorage.open(applicationSupport: first, owner: owner)
        let restored = try await reopened.drafts(); XCTAssertEqual(restored, [draft])
        let attrs = try FileManager.default.attributesOfItem(atPath: first.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try first.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
    func testAppNamespaceRefusesASymlinkWithoutReadingOrChangingItsTarget() async throws {
        let outside = root.appendingPathComponent("outside", isDirectory: true), link = root.appendingPathComponent("app-link", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        do { _ = try await AudioCommentDraftStorage.open(applicationSupport: link, owner: .init(account)); XCTFail("Expected link refusal") } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}
