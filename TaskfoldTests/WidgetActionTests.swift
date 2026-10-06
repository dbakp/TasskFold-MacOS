import XCTest
@testable import TaskfoldCore
@testable import WidgetModel

final class WidgetActionTests: XCTestCase {
    private func task() -> Record { Record(["id": .string("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), "user_id": .string("a"), "title": .string("Review"), "completed": .bool(false), "completed_at": .null, "created_at": .string("2026-10-06T12:00:00Z"), "due_date": .string("2026-10-06")]) }
    private func snapshot() -> Snapshot { var value = Snapshot(tables: ["tasks": [task()]]); WidgetCompletion.prepare(&value); return value }
    private func request(_ snapshot: Snapshot, account: String = "a") throws -> WidgetCompletionRequest {
        try WidgetCompletionRequest(account: account, taskID: task().id, token: XCTUnwrap(WidgetCompletion.tokens(snapshot)[task().id]), at: ISO8601DateFormatter().date(from: "2026-10-06T12:30:00Z")!)
    }
    private func disk() throws -> (WidgetActionDisk, URL) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-widget-actions-" + UUID().uuidString)
        return (WidgetActionDisk(directory: path), path)
    }
    private func publish(_ disk: WidgetActionDisk, _ snapshot: Snapshot, account: String = "a") throws {
        try disk.publish(JSONEncoder().encode(WidgetProjection.payload(tasks: snapshot.tables["tasks"] ?? [], projects: [], account: account, completionTokens: WidgetCompletion.tokens(snapshot))))
    }
    func testTokenPersistsAcrossRelaunchUnrelatedEditsAndEquivalentServerTimestampSpellings() throws {
        let before = snapshot(), token = WidgetCompletion.tokens(before)[task().id]
        var after = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(before))
        after.tables["tasks"]?[0]["title"] = .string("Current edited title")
        after.tables["tasks"]?[0]["created_at"] = .string("2026-10-06T14:00:00+02:00")
        WidgetCompletion.prepare(&after); XCTAssertEqual(WidgetCompletion.tokens(after)[task().id], token)
        let action = try request(before)
        guard case .complete(let changes) = WidgetCompletion.plan(action, snapshot: after, account: "a") else { return XCTFail("An unrelated edit must not discard a tap") }
        XCTAssertEqual(changes.first?.fields["completed"], .bool(true)); XCTAssertEqual(changes.first?.baseline?["completed"], .bool(false))
        XCTAssertEqual(changes.first?.fields["completed_at"], .string("2026-10-06T12:30:00Z"))
    }
    func testCompleteReopenAndDeletionInvalidateOldWidgetTaps() throws {
        var value = snapshot(); let original = try request(value)
        value.tables["tasks"]?[0]["completed"] = .bool(true); value.tables["tasks"]?[0]["completed_at"] = .string("2026-10-06T12:30:00Z")
        WidgetCompletion.prepare(&value)
        if case .saved = WidgetCompletion.plan(original, snapshot: value, account: "a") {} else { XCTFail("An already completed task cannot reopen") }
        value.tables["tasks"]?[0]["completed"] = .bool(false); value.tables["tasks"]?[0]["completed_at"] = .null
        WidgetCompletion.prepare(&value)
        if case .stale = WidgetCompletion.plan(original, snapshot: value, account: "a") {} else { XCTFail("A pre-undo tap must not complete the reopened task") }
        let fresh = try request(value); XCTAssertNotEqual(original.token, fresh.token)
        value.tables["tasks"] = []; WidgetCompletion.prepare(&value); XCTAssertTrue(value.widgetCompletion.states.isEmpty)
        if case .stale = WidgetCompletion.plan(fresh, snapshot: value, account: "a") {} else { XCTFail("Deleted task cannot be recreated") }
    }
    func testWorkspaceMismatchAndMalformedTokensCannotApply() throws {
        let value = snapshot(), action = try request(value)
        if case .stale = WidgetCompletion.plan(action, snapshot: value, account: "b") {} else { XCTFail("Wrong workspace") }
        XCTAssertThrowsError(try WidgetCompletionRequest(account: "a", taskID: "t", token: "bad"))
        XCTAssertThrowsError(try WidgetCompletionRequest(account: "", taskID: "t", token: UUID().uuidString))
        var forged = action; forged.id = UUID()
        if case .stale = WidgetCompletion.plan(forged, snapshot: value, account: "a") {} else { XCTFail("Mismatched request identity") }
    }
    func testReceiptAndTaskQueueSurviveCrashBeforeAcknowledgementAndLaterUndo() throws {
        var value = snapshot(); let action = try request(value)
        guard case .complete(let changes) = WidgetCompletion.plan(action, snapshot: value, account: "a") else { return XCTFail("Missing plan") }
        let history = EditHistory(changes: changes, snapshot: value)
        changes.forEach { value.apply($0); value.pending.append($0) }
        value.widgetCompletion.record(action); WidgetCompletion.prepare(&value)
        var restored = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored.pending, changes)
        history.undo.forEach { restored.apply($0) }; WidgetCompletion.prepare(&restored)
        guard case .saved = WidgetCompletion.plan(action, snapshot: restored, account: "a") else { return XCTFail("A retried receipt must not repeat completion after undo") }
        XCTAssertEqual(restored.tables["tasks"]?.first?.completed, false)
    }
    func testRecurringWidgetPlanUsesCurrentRecordAndOneCreateOnlySuccessor() throws {
        var value = snapshot(); value.tables["tasks"]?[0]["is_recurring"] = .bool(true)
        value.tables["tasks"]?[0]["recurrence_pattern"] = .object(["type": .string("daily")])
        value.tables["tasks"]?[0]["description"] = .string("Latest notes")
        let action = try request(value)
        guard case .complete(let changes) = WidgetCompletion.plan(action, snapshot: value, account: "a") else { return XCTFail("Missing recurring plan") }
        XCTAssertEqual(changes.count, 2); XCTAssertEqual(changes[1].insertOnly, true); XCTAssertEqual(changes[1].fields["description"], .string("Latest notes"))
        changes.forEach { value.apply($0) }; WidgetCompletion.prepare(&value)
        guard case .saved = WidgetCompletion.plan(action, snapshot: value, account: "a") else { return XCTFail("Double tap created another occurrence") }
        XCTAssertEqual(value.tables["tasks"]?.count, 2)
    }
    func testLegacyCacheDecodesAndExportNeverContainsLocalTokensOrReceipts() throws {
        let value = snapshot(), action = try request(value)
        var saved = value; saved.widgetCompletion.record(action)
        let backup = WorkspaceBackup.make(saved, account: "a")
        let text = String(decoding: try JSONEncoder().encode(backup), as: UTF8.self)
        XCTAssertFalse(text.contains(action.token)); XCTAssertFalse(text.contains("widgetCompletion"))
        let legacy = try JSONDecoder().decode(Snapshot.self, from: Data(#"{"tables":{},"pending":[]}"#.utf8))
        XCTAssertTrue(legacy.widgetCompletion.states.isEmpty); XCTAssertTrue(legacy.widgetCompletion.receipts.isEmpty)
        XCTAssertThrowsError(try JSONDecoder().decode(Snapshot.self, from: Data("{}".utf8)))
    }
    func testProducerAndDecoderExposeOpaqueTokensPendingSyncAndReadOnlyLegacyCompatibility() throws {
        let value = snapshot(), action = try request(value)
        let payload = WidgetProjection.payload(tasks: [task()], projects: [], account: "a", completionTokens: WidgetCompletion.tokens(value), pendingSync: 2)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(payload))
        XCTAssertEqual(decoded.tasks.first?.completionToken, action.token); XCTAssertEqual(decoded.pendingSync, 2)
        let text = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        XCTAssertFalse(text.contains("receipts")); XCTAssertFalse(text.contains("signature")); XCTAssertFalse(text.contains("access_token"))
        let legacy = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(#"{"updated":0,"tasks":[{"id":"t","title":"Task","due":"","time":"","priority":4,"project":"","color":""}]}"#.utf8))
        XCTAssertNil(legacy.tasks.first?.completionToken); XCTAssertEqual(legacy.pendingSync, 0)
    }
    func testDiskEnqueueIsDurableDeduplicatedAndShowsPendingWithoutCompletingProjection() throws {
        let (disk, directory) = try disk(); defer { try? FileManager.default.removeItem(at: directory) }
        let value = snapshot(), action = try request(value); try publish(disk, value)
        let queued = try disk.enqueue(action)
        var later = action; later.createdAt = later.createdAt.addingTimeInterval(10)
        XCTAssertEqual(try disk.enqueue(later), queued)
        let otherProcess = WidgetActionDisk(directory: directory)
        XCTAssertEqual(try otherProcess.pending(account: "a"), [queued])
        let read = try otherProcess.read(); XCTAssertEqual(read.pendingTaskIDs, [action.taskID])
        let visible = try JSONDecoder().decode(WidgetSnapshot.self, from: XCTUnwrap(read.data))
        XCTAssertEqual(visible.tasks.count, 1, "Pending is not a completed task or an inflated success count")
        try otherProcess.acknowledge(queued); try otherProcess.acknowledge(queued)
        XCTAssertTrue(try disk.pending(account: "a").isEmpty)
    }
    func testDiskAccountChangesAndSignOutRejectStaleTapsButRetainAcceptedOtherWorkspaceRequests() throws {
        let (disk, directory) = try disk(); defer { try? FileManager.default.removeItem(at: directory) }
        let value = snapshot(), action = try request(value); try publish(disk, value); _ = try disk.enqueue(action)
        try publish(disk, value, account: "b"); XCTAssertThrowsError(try disk.enqueue(action))
        XCTAssertTrue(try disk.read().pendingTaskIDs.isEmpty); XCTAssertEqual(try disk.pending(account: "a"), [action])
        try publish(disk, value, account: ""); XCTAssertThrowsError(try disk.enqueue(action))
        XCTAssertTrue(try disk.read().pendingTaskIDs.isEmpty); XCTAssertEqual(try disk.pending(account: "a").count, 1)
        try publish(disk, value); XCTAssertEqual(try disk.read().pendingTaskIDs, [action.taskID])
    }
    func testCorruptQueueAndFutureVersionAreNeverSilentlyOverwritten() throws {
        let (disk, directory) = try disk(); defer { try? FileManager.default.removeItem(at: directory) }
        let value = snapshot(); try publish(disk, value)
        let url = directory.appendingPathComponent("widget-actions.json")
        for bytes in [Data("broken".utf8), Data(#"{"version":99,"requests":[]}"#.utf8)] {
            try bytes.write(to: url)
            XCTAssertThrowsError(try disk.enqueue(request(value))); XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertThrowsError(try disk.read())
        }
    }
}
