import XCTest
@testable import TaskfoldCore

final class SharedCaptureTests: XCTestCase {
    private func workspace(_ account: String = "owner", generation: UUID = UUID()) -> SharedCaptureWorkspace {
        SharedCaptureWorkspace(account: account, generation: generation, label: "Test workspace")
    }
    private func disk() throws -> (URL, SharedCaptureDisk) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-share-test-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (directory, SharedCaptureDisk(directory: directory))
    }
    func testSharedSelectionIsPreservedWithoutParsingCommands() throws {
        let text = "Plan tomorrow p1 #Personal\nKeep the exact selection and URL as text."
        let value = try SharedCaptureContent.suggested(text: text, source: "https://example.com/notes?a=1#part")
        XCTAssertEqual(value.title, "Plan tomorrow p1 #Personal")
        XCTAssertEqual(value.notes, text)
        XCTAssertEqual(value.taskDescription, text + "\n\nhttps://example.com/notes?a=1#part")
    }
    func testLinkAndSingleLineSuggestionsDoNotNeedDuplicateNotes() throws {
        XCTAssertEqual(try SharedCaptureContent.suggested(text: "A thought").notes, "")
        let link = try SharedCaptureContent.suggested(text: "", source: "https://example.com/story")
        XCTAssertEqual(link.title, "example.com"); XCTAssertEqual(link.taskDescription, "https://example.com/story")
        let page = try SharedCaptureContent.suggested(text: "Selected words", pageTitle: "Page heading", source: "https://example.com")
        XCTAssertEqual(page.title, "Page heading"); XCTAssertEqual(page.notes, "Selected words")
    }
    func testLongSuggestedHeadingDoesNotLoseOriginalText() throws {
        let text = String(repeating: "Résumé 🙂 ", count: 1000)
        let value = try SharedCaptureContent.suggested(text: text)
        XCTAssertEqual(value.title.count, 200)
        XCTAssertEqual(value.notes, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    func testUnsupportedAndCredentialedLinksFailBeforeSaving() throws {
        for link in ["file:///private/test", "javascript:alert(1)", "taskfold://new", "https://name:secret@example.com", "https://name@example.com", "https:///", "https://example.com/\nprivate"] {
            XCTAssertThrowsError(try SharedCaptureContent(title: "A task", source: link), link)
        }
        XCTAssertNoThrow(try SharedCaptureContent(title: "A task", source: "https://example.com/%20?q=hello"))
    }
    func testEmptyOversizedAndUnicodeContentIsBoundedInBytes() throws {
        XCTAssertThrowsError(try SharedCaptureContent(title: " \n "))
        XCTAssertThrowsError(try SharedCaptureContent(title: String(repeating: "x", count: 10_001)))
        XCTAssertThrowsError(try SharedCaptureContent(title: "Title", notes: String(repeating: "🙂", count: 25_000)))
        XCTAssertThrowsError(try SharedCaptureContent.suggested(text: String(repeating: "a", count: 100_001)))
        XCTAssertThrowsError(try SharedCaptureContent(title: "A task", source: "https://example.com/" + String(repeating: "a", count: 8192)))
    }
    func testSaveRelaunchAndExactRetryRemainOneDraft() throws {
        let (directory, disk) = try disk(), owner = workspace()
        try disk.publish(owner)
        let draft = try SharedCaptureDraft(workspace: owner, content: SharedCaptureContent(title: "Read the article", source: "https://example.com"))
        try disk.save(draft); try SharedCaptureDisk(directory: directory).save(draft)
        XCTAssertEqual(try SharedCaptureDisk(directory: directory).drafts(account: owner.account), [draft])
        XCTAssertEqual(draft.taskID, draft.id.uuidString.lowercased())
        let bytes = try Data(contentsOf: directory.appendingPathComponent("shared-capture.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "workspace", "drafts"])
    }
    func testWorkspaceChangeDuringShareCannotRetargetDraft() throws {
        let (_, disk) = try disk(), owner = workspace(), next = workspace("other")
        try disk.publish(owner)
        let draft = try SharedCaptureDraft(workspace: owner, content: SharedCaptureContent(title: "Original account"))
        try disk.publish(next)
        XCTAssertThrowsError(try disk.save(draft))
        XCTAssertTrue(try disk.drafts(account: next.account).isEmpty)
        try disk.publish(owner); XCTAssertTrue(try disk.drafts(account: owner.account).isEmpty)
    }
    func testSignOutAndSameAccountNewSessionInvalidateOpenShare() throws {
        let (_, disk) = try disk(), owner = workspace()
        try disk.publish(owner)
        let draft = try SharedCaptureDraft(workspace: owner, content: SharedCaptureContent(title: "A thought"))
        try disk.publish(nil); XCTAssertNil(try disk.workspace()); XCTAssertThrowsError(try disk.save(draft))
        try disk.publish(workspace(owner.account)); XCTAssertThrowsError(try disk.save(draft))
    }
    func testExistingDraftsReturnOnlyInOriginalAccountAfterNormalRelaunch() throws {
        let (_, disk) = try disk(), owner = workspace(), other = workspace("other")
        let draft = try SharedCaptureDraft(workspace: owner, content: SharedCaptureContent(title: "Private draft"))
        try disk.publish(owner); try disk.save(draft); try disk.publish(other)
        XCTAssertTrue(try disk.drafts(account: other.account).isEmpty)
        XCTAssertTrue(try disk.drafts(account: owner.account).isEmpty)
        XCTAssertThrowsError(try disk.acknowledge(draft, account: other.account))
        try disk.publish(workspace(owner.account))
        XCTAssertEqual(try disk.drafts(account: owner.account), [draft])
    }
    func testAcknowledgementIsExactIdempotentAndKeepsOtherDrafts() throws {
        let (_, disk) = try disk(), owner = workspace()
        try disk.publish(owner)
        let first = try SharedCaptureDraft(workspace: owner, content: SharedCaptureContent(title: "First"))
        let second = try SharedCaptureDraft(workspace: owner, content: SharedCaptureContent(title: "Second"))
        try disk.save(first); try disk.save(second)
        var altered = first; altered.content.title = "Changed"
        try disk.acknowledge(altered, account: owner.account)
        XCTAssertEqual(try disk.drafts(account: owner.account), [first, second])
        try disk.acknowledge(first, account: owner.account); try disk.acknowledge(first, account: owner.account)
        XCTAssertEqual(try disk.drafts(account: owner.account), [second])
    }
    func testSameIdentityWithDifferentContentNeverOverwritesSavedDraft() throws {
        let (_, disk) = try disk(), owner = workspace()
        try disk.publish(owner)
        let draft = try SharedCaptureDraft(workspace: owner, content: SharedCaptureContent(title: "Original"))
        try disk.save(draft)
        var changed = draft; changed.content.title = "Replacement"
        XCTAssertThrowsError(try disk.save(changed)); XCTAssertEqual(try disk.drafts(account: owner.account), [draft])
    }
    func testCapacityRejectsWithoutDroppingOldDrafts() throws {
        let (_, disk) = try disk(), owner = workspace()
        try disk.publish(owner)
        for n in 0..<SharedCaptureDisk.capacity { try disk.save(SharedCaptureDraft(workspace: owner, content: SharedCaptureContent(title: "Draft \(n)"))) }
        XCTAssertThrowsError(try disk.save(SharedCaptureDraft(workspace: owner, content: SharedCaptureContent(title: "Overflow"))))
        XCTAssertEqual(try disk.drafts(account: owner.account).count, SharedCaptureDisk.capacity)
    }
    func testCorruptFutureAndOversizedFilesArePreservedRatherThanReset() throws {
        let (directory, disk) = try disk()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("shared-capture.json")
        for data in [Data("invalid".utf8), Data(#"{"version":99,"drafts":[]}"#.utf8), Data(repeating: 32, count: SharedCaptureDisk.maximumFileBytes + 1)] {
            try data.write(to: file)
            XCTAssertThrowsError(try disk.publish(workspace()))
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }
    func testConcurrentInstancesDoNotLoseDrafts() throws {
        let (directory, disk) = try disk(), owner = workspace()
        try disk.publish(owner)
        let drafts = try (0..<24).map { try SharedCaptureDraft(workspace: owner, content: SharedCaptureContent(title: "Draft \($0)")) }
        let errors = ShareTestErrors()
        DispatchQueue.concurrentPerform(iterations: drafts.count) { index in
            do { try SharedCaptureDisk(directory: directory).save(drafts[index]) } catch { errors.append(error) }
        }
        XCTAssertTrue(errors.values.isEmpty)
        XCTAssertEqual(Set(try disk.drafts(account: owner.account).map(\.id)), Set(drafts.map(\.id)))
    }
}
private final class ShareTestErrors: @unchecked Sendable {
    let lock = NSLock(); private var stored: [String] = []
    func append(_ error: Error) { lock.lock(); defer { lock.unlock() }; stored.append(error.localizedDescription) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

final class SharedCapturePlanTests: XCTestCase {
    private func draft() throws -> SharedCaptureDraft {
        try SharedCaptureDraft(workspace: SharedCaptureWorkspace(account: "owner", generation: UUID(), label: "Test"), content: SharedCaptureContent(title: "Read tomorrow p1 #Studio", notes: "The whole selection.", source: "https://example.com/read"))
    }
    func testReviewCreatesOnlyOneCreateOnlyTaskWithoutInferringPlanning() throws {
        let draft = try draft()
        guard case .create(let change) = try SharedCapturePlan.prepare(draft, content: draft.content, account: "owner", project: "", snapshot: Snapshot()) else { return XCTFail("Expected a task") }
        XCTAssertEqual(change.table, "tasks"); XCTAssertEqual(change.method, "POST"); XCTAssertEqual(change.insertOnly, true)
        XCTAssertEqual(change.recordID, draft.taskID)
        XCTAssertEqual(change.fields["user_id"], .string("owner"))
        XCTAssertEqual(change.fields["title"], .string("Read tomorrow p1 #Studio"))
        XCTAssertEqual(change.fields["description"], .string("The whole selection.\n\nhttps://example.com/read"))
        XCTAssertEqual(change.fields["priority"], .number(4)); XCTAssertEqual(change.fields["due_date"], .null)
        XCTAssertEqual(change.fields["labels"], .array([]))
        guard case .create(let retry) = try SharedCapturePlan.prepare(draft, content: draft.content, account: "owner", project: "", snapshot: Snapshot()) else { return XCTFail("Expected same identity") }
        XCTAssertEqual(retry.recordID, change.recordID)
        XCTAssertEqual(retry.fields["task_generation"], change.fields["task_generation"])
    }
    func testReceiptPreventsRecreationAfterTaskDeletionOrUndo() throws {
        let draft = try draft()
        var snapshot = Snapshot(); snapshot.sharedCaptureReceipts = [draft.taskID: draft.taskID]
        guard case .saved = try SharedCapturePlan.prepare(draft, content: draft.content, account: "owner", project: "", snapshot: snapshot) else { return XCTFail("Must not recreate an already handled draft") }
        let roundtrip = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(roundtrip.sharedCaptureReceipts, snapshot.sharedCaptureReceipts)
        guard case .saved = try SharedCapturePlan.prepare(draft, content: draft.content, account: "owner", project: "", snapshot: roundtrip) else { return XCTFail("Receipt must survive relaunch") }
    }
    func testReceiptDoesNotAuthorizeAnotherAccount() throws {
        let draft = try draft()
        var snapshot = Snapshot(); snapshot.sharedCaptureReceipts = [draft.taskID: draft.taskID]
        XCTAssertThrowsError(try SharedCapturePlan.prepare(draft, content: draft.content, account: "other", project: "", snapshot: snapshot))
    }
    func testExistingTaskCollisionCannotBecomeAnUpdate() throws {
        let draft = try draft()
        let task = Record(["id": .string(draft.taskID), "title": .string("Existing work")])
        XCTAssertThrowsError(try SharedCapturePlan.prepare(draft, content: draft.content, account: "owner", project: "", snapshot: Snapshot(tables: ["tasks": [task]])))
    }
    func testArchivedAndUnavailableProjectsAreRejected() throws {
        let draft = try draft()
        let project = Record(["id": .string("studio"), "name": .string("Studio"), "user_id": .string("owner"), "is_archived": .bool(true)])
        for snapshot in [Snapshot(), Snapshot(tables: ["projects": [project]])] {
            XCTAssertThrowsError(try SharedCapturePlan.prepare(draft, content: draft.content, account: "owner", project: "studio", snapshot: snapshot))
        }
        var active = project; active["is_archived"] = .bool(false)
        guard case .create(let change) = try SharedCapturePlan.prepare(draft, content: draft.content, account: "owner", project: "studio", snapshot: Snapshot(tables: ["projects": [active]])) else { return XCTFail("Expected chosen project") }
        XCTAssertEqual(change.fields["project_id"], .string("studio"))
    }
    func testOlderCachesDecodeAndPortableBackupsExcludeLocalReceipts() throws {
        let old = Data(#"{"tables":{},"pending":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Snapshot.self, from: old).sharedCaptureReceipts)
        var snapshot = Snapshot(); snapshot.sharedCaptureReceipts = [UUID().uuidString: "local-only"]
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: WorkspaceBackup.make(snapshot, account: "owner").data()) as? [String: Any])
        XCTAssertNil(root["sharedCaptureReceipts"])
        XCTAssertTrue((root["tables"] as? [String: Any] ?? [:]).isEmpty)
    }
}

final class SharedCaptureItemTests: XCTestCase {
    func testProviderFoundationRepresentationsRemainPlainText() throws {
        XCTAssertEqual(try SharedCaptureItem.text("A thought" as NSString), "A thought")
        XCTAssertEqual(try SharedCaptureItem.text(NSAttributedString(string: "Readable words")), "Readable words")
        XCTAssertEqual(try SharedCaptureItem.text(Data("Résumé 🙂".utf8) as NSData), "Résumé 🙂")
        XCTAssertThrowsError(try SharedCaptureItem.text(Data([0xff, 0xfe, 0x80]) as NSData))
        XCTAssertThrowsError(try SharedCaptureItem.text(Data(repeating: 32, count: 100_001) as NSData))
        XCTAssertThrowsError(try SharedCaptureItem.text(NSNumber(value: 12)))
    }
    func testURLRepresentationsRejectLocalFilesAndEmbeddedCredentials() throws {
        XCTAssertEqual(try SharedCaptureItem.webLink(URL(string: "https://example.com/read")! as NSURL), "https://example.com/read")
        XCTAssertEqual(try SharedCaptureItem.webLink("https://example.com/read" as NSString), "https://example.com/read")
        XCTAssertThrowsError(try SharedCaptureItem.webLink(URL(fileURLWithPath: "/private/secret") as NSURL))
        XCTAssertThrowsError(try SharedCaptureItem.webLink("https://user:secret@example.com" as NSString))
        XCTAssertThrowsError(try SharedCaptureItem.webLink(" " as NSString))
        let value = try SharedCaptureContent.suggested(text: "https://example.com/read", source: "https://example.com/read")
        XCTAssertEqual(value.title, "example.com"); XCTAssertEqual(value.taskDescription, "https://example.com/read")
    }
}

final class SharedCaptureCombinationTests: XCTestCase {
    func testProviderPiecesAreBoundedBeforeJoiningAndKeepSeparators() throws {
        XCTAssertEqual(try SharedCaptureContent.combine(["First", "Résumé 🙂"]), "First\n\nRésumé 🙂")
        XCTAssertEqual(try SharedCaptureContent.combine([]), "")
        XCTAssertThrowsError(try SharedCaptureContent.combine([String(repeating: "a", count: 50_000), String(repeating: "b", count: 50_000)]))
        XCTAssertEqual(try SharedCaptureContent.combine([String(repeating: "a", count: 49_999), String(repeating: "b", count: 49_999)]).utf8.count, 100_000)
        XCTAssertThrowsError(try SharedCaptureContent.combine([String(repeating: "🙂", count: 25_001)]))
    }
}
