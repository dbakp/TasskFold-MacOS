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
    func testSharedRecurringWidgetCompletionCreatesForItsBoundAccount() throws {
        var value = snapshot(), source = task()
        source["user_id"] = .string("b"); source["project_id"] = .string("p")
        source["is_recurring"] = .bool(true); source["recurrence_pattern"] = .object(["type": .string("daily")])
        value.tables["tasks"] = [source]
        value.tables["projects"] = [Record(["id": .string("p"), "name": .string("Shared"), "user_id": .string("b")])]
        WidgetCompletion.prepare(&value)
        guard case .complete(let changes) = WidgetCompletion.plan(try request(value), snapshot: value, account: "a") else {
            return XCTFail("The current shared-task request should complete")
        }
        let successor = try XCTUnwrap(changes.first { $0.method == "POST" })
        XCTAssertEqual(successor.fields["user_id"], .string("a"))
        XCTAssertEqual(successor.fields["project_id"], .string("p"))
        XCTAssertEqual(value.tables["tasks"]?.first?["user_id"], .string("b"))
    }

    func testCompletionFeedbackIsScopedBoundedAndCompatibleWithOldCaches() throws {
        var value = snapshot()
        value.tables["tasks"]?[0]["project_id"] = .string("p")
        let project = Record(["id": .string("p"), "name": .string("Proof"), "user_id": .string("a")])
        let action = try request(value), now = action.createdAt
        let payload = WidgetProjection.payload(tasks: value.tables["tasks"]!, projects: [project], account: "a", now: now, completionTokens: WidgetCompletion.tokens(value))
        let data = try JSONEncoder().encode(payload)
        let feedback = try XCTUnwrap(WidgetCompletionFeedback.capture(action, projection: data, at: now))
        let listID = try XCTUnwrap(feedback.listIDs.first)
        XCTAssertTrue(feedback.visible(account: "a", listID: listID, at: now))
        XCTAssertTrue(feedback.visible(account: "a", listID: listID, at: now.addingTimeInterval(7)))
        XCTAssertFalse(feedback.visible(account: "b", listID: listID, at: now))
        XCTAssertFalse(feedback.visible(account: "a", listID: "other", at: now))
        XCTAssertFalse(feedback.visible(account: "a", listID: listID, at: now.addingTimeInterval(-1)))
        XCTAssertFalse(feedback.visible(account: "a", listID: listID, at: now.addingTimeInterval(8)))
        var foreign = action; foreign.account = "b"
        XCTAssertNil(WidgetCompletionFeedback.capture(foreign, projection: data, at: now))
        foreign = action; foreign.token = UUID().uuidString
        XCTAssertNil(WidgetCompletionFeedback.capture(foreign, projection: data, at: now))
        let old = try JSONDecoder().decode(WidgetCompletionCache.self, from: Data(#"{"states":{},"receipts":{},"receiptOrder":[]}"#.utf8))
        XCTAssertNil(old.feedback)
        value.widgetCompletion.feedback = feedback
        let restored = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored.widgetCompletion.feedback, feedback)
        var published = payload
        published["completionFeedback"] = try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(feedback))
        let widget = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(published))
        XCTAssertEqual(widget.completionFeedback, feedback)
    }
    func testDismissalIsExactDurableAndNeverMutatesTasksOrHidesNewFeedback() throws {
        let (disk, directory) = try disk(); defer { try? FileManager.default.removeItem(at: directory) }
        let value = snapshot()
        var payload = WidgetProjection.payload(tasks: [task()], projects: [], account: "a", completionTokens: WidgetCompletion.tokens(value))
        let feedback: JSON = .object(["account": .string("a"), "taskID": .string(task().id), "savedAt": .number(123), "title": .string("Review"), "listIDs": .array([])])
        payload["completionFeedback"] = feedback
        let original = try JSONEncoder().encode(payload); try disk.publish(original)
        try disk.dismissFeedback(account: "b", taskID: task().id, savedAt: 123)
        XCTAssertEqual(try disk.read().data, original)
        try disk.dismissFeedback(account: "a", taskID: task().id, savedAt: 122)
        XCTAssertEqual(try disk.read().data, original)
        try disk.dismissFeedback(account: "a", taskID: task().id, savedAt: 123)
        let read = try XCTUnwrap(WidgetActionDisk(directory: directory).read().data)
        let decoded = try JSONDecoder().decode([String: JSON].self, from: read)
        XCTAssertNil(decoded["completionFeedback"])
        XCTAssertEqual(decoded["tasks"], payload["tasks"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("widget.json")), original)
        payload["completionFeedback"] = .object(["account": .string("a"), "taskID": .string(task().id), "savedAt": .number(124)])
        let next = try JSONEncoder().encode(payload); try disk.publish(next)
        XCTAssertEqual(try disk.read().data, next)
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

final class HierarchyWidgetTests: XCTestCase {
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }
    private var now: Date { Dates.parse("2026-10-21", calendar: calendar)!.addingTimeInterval(12 * 3600) }
    private var workspace: WorkspaceBinding { WorkspaceBinding(account: "owner", generation: UUID()) }
    private func fixture() -> Snapshot {
        let leaf: JSON = .object(["id": .string("CaseSensitiveLeaf"), "title": .string("Review contrast"), "completed": .bool(false), "priority": .number(1), "due_date": .string("2026-10-21")])
        let branch: JSON = .object(["id": .string("branch"), "title": .string("Design review"), "completed": .bool(false), "subtasks": .array([leaf])])
        let sibling: JSON = .object(["id": .string("sibling"), "title": .string("Publish"), "completed": .bool(false)])
        let root = Record(["id": .string("root"), "title": .string("Release plan"), "completed": .bool(false), "project_id": .string("p"), "task_generation": .string("root-generation"), "created_at": .string("2026-10-20T10:00:00Z"), "due_date": .string("2026-10-21"), "subtasks": .array([branch, sibling])])
        let view = Record(["id": .string("children"), "name": .string("Subtasks"), "query_ast": FilterRule.predicate("subtask", "").document])
        var result = Snapshot(tables: ["tasks": [root], "projects": [Record(["id": .string("p"), "name": .string("Studio")])], "saved_views": [view]])
        WidgetCompletion.prepare(&result); return result
    }
    private func index(_ value: Snapshot) throws -> TaskHierarchyIndex { try TaskHierarchyIndex(roots: value.tables["tasks"]!, projects: value.tables["projects"]!, workspace: workspace) }
    private func leaf(_ value: Snapshot) throws -> TaskHierarchyIndex.Item { try XCTUnwrap(try index(value).items.first { $0.source.id == "CaseSensitiveLeaf" }) }
    private func payload(_ value: Snapshot, account: String = "owner") -> [String: JSON] { WidgetProjection.payload(tasks: value.tables["tasks"]!, projects: value.tables["projects"]!, account: account, now: now, savedViews: value.tables["saved_views"]!, calendar: calendar, completionTokens: WidgetCompletion.tokens(value)) }
    private func action(_ value: Snapshot) throws -> WidgetCompletionRequest { let item = try leaf(value); return try WidgetCompletionRequest(account: "owner", taskID: item.id, token: XCTUnwrap(WidgetCompletion.tokens(value)[item.id]), at: now) }
    func testChildMembershipUsesSeparateCatalogAndNeverChangesDefaultCounts() throws {
        let value = fixture(), before = value, data = try JSONEncoder().encode(payload(value))
        let widget = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        XCTAssertEqual(widget.tasks.map(\.title), ["Release plan"]); XCTAssertEqual(widget.nestedTasks?.count, 3)
        let list = try XCTUnwrap(widget.availableLists.first { $0.recordID == "children" })
        XCTAssertEqual(widget.listStatus(list.id, at: now, calendar: calendar), .ready)
        XCTAssertEqual(Set(widget.listTasks(list.id, at: now, calendar: calendar).map(\.title)), ["Design review", "Review contrast", "Publish"])
        let child = try XCTUnwrap(widget.listTasks(list.id, at: now, calendar: calendar).first { $0.title == "Review contrast" })
        XCTAssertEqual(child.parent, "Release plan › Design review"); XCTAssertNotNil(child.completionToken)
        XCTAssertEqual(widget.inboxReading().count, 0)
        let project = try XCTUnwrap(widget.availableLists.first { $0.recordID == "p" })
        XCTAssertEqual(widget.listTasks(project.id, at: now, calendar: calendar).count, 1)
        XCTAssertEqual(value, before)
    }
    func testDiskHandoffCompletesOnlyRealRootSubtreeAndRetainsReceiptThroughUndo() throws {
        var value = fixture(); let before = value, request = try action(value)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-child-widget-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: directory) }
        let disk = WidgetActionDisk(directory: directory), data = try JSONEncoder().encode(payload(value))
        try disk.publish(data); XCTAssertEqual(try disk.enqueue(request), request); XCTAssertEqual(try disk.enqueue(request), request)
        XCTAssertEqual(try disk.pending(account: "owner").count, 1)
        let feedback = try XCTUnwrap(WidgetCompletionFeedback.capture(request, projection: data, at: now))
        XCTAssertEqual(feedback.title, "Review contrast"); XCTAssertEqual(feedback.routeContext, WidgetCompletion.routeContext(try leaf(value)))
        guard case .complete(let changes) = WidgetCompletion.plan(request, snapshot: value, account: "owner") else { return XCTFail("Missing child completion") }
        XCTAssertEqual(changes.count, 1); XCTAssertEqual(changes[0].recordID, "root"); XCTAssertEqual(Set(changes[0].fields.keys), ["subtasks"])
        let history = EditHistory(changes: changes, snapshot: value)
        changes.forEach { value.apply($0); value.pending.append($0) }; value.widgetCompletion.record(request); value.widgetCompletion.feedback = feedback; WidgetCompletion.prepare(&value)
        XCTAssertFalse(value.tables["tasks"]![0].completed); XCTAssertTrue(try leaf(value).record.completed); XCTAssertEqual(value.tables["tasks"]?.count, 1)
        var restored = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(value))
        XCTAssertTrue(restored.widgetCompletion.saved(request)); XCTAssertEqual(restored.pending, changes)
        let widget = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(payload(restored)))
        XCTAssertFalse(widget.nestedTasks!.contains { $0.id == request.taskID })
        history.undo.forEach { restored.apply($0) }; WidgetCompletion.prepare(&restored)
        XCTAssertEqual(restored.tables["tasks"], before.tables["tasks"])
        guard case .saved = WidgetCompletion.plan(request, snapshot: restored, account: "owner") else { return XCTFail("Receipt retry cannot repeat completion after Undo") }
        try disk.acknowledge(request); XCTAssertTrue(try disk.pending(account: "owner").isEmpty)
    }
    func testIndependentDescendantCompletionKeepsParentCheckboxUsable() throws {
        var value = fixture(); let request = try action(value)
        let parent = try XCTUnwrap(try index(value).items.first { $0.source.id == "branch" })
        let parentRequest = try WidgetCompletionRequest(account: "owner", taskID: parent.id, token: XCTUnwrap(WidgetCompletion.tokens(value)[parent.id]), at: now)
        guard case .complete(let changes) = WidgetCompletion.plan(request, snapshot: value, account: "owner") else { return XCTFail("Missing leaf completion") }
        changes.forEach { value.apply($0) }; WidgetCompletion.prepare(&value)
        XCTAssertEqual(WidgetCompletion.tokens(value)[parent.id], parentRequest.token)
        guard case .complete(let next) = WidgetCompletion.plan(parentRequest, snapshot: value, account: "owner") else { return XCTFail("Independent parent checkbox became stale") }
        next.forEach { value.apply($0) }
        XCTAssertTrue(try leaf(value).record.completed)
        XCTAssertTrue(try index(value).item(parent.id)!.record.completed)
        XCTAssertFalse(value.tables["tasks"]![0].completed)
    }
    func testStaleChangedMovedReplacedRevokedAndMalformedChildActionsRefuseAtomically() throws {
        let value = fixture(), request = try action(value)
        var samples: [Snapshot] = []
        var changed = value; changed.tables["tasks"]?[0]["subtasks"] = SubtaskTree.changing(value.tables["tasks"]![0]["subtasks"], id: "CaseSensitiveLeaf", fields: ["title": .string("Replacement")]); samples.append(changed)
        changed = value; changed.tables["tasks"]?[0]["task_generation"] = .string("new-generation"); samples.append(changed)
        changed = value; changed.tables["tasks"]?[0]["section_id"] = .string("moved"); samples.append(changed)
        changed = value; changed.tables["projects"]?[0]["is_archived"] = .bool(true); samples.append(changed)
        changed = value; changed.tables["projects"] = []; samples.append(changed)
        changed = value; changed.tables["tasks"]?[0]["subtasks"] = .object(["unknown": .bool(true)]); samples.append(changed)
        changed = value; changed.tables["tasks"]?[0]["subtasks"] = .array([]); samples.append(changed)
        for var sample in samples {
            for prepared in [false, true] {
                if prepared { WidgetCompletion.prepare(&sample) }
                let before = sample
                guard case .stale = WidgetCompletion.plan(request, snapshot: sample, account: "owner") else { return XCTFail("Stale child action accepted") }
                XCTAssertEqual(sample, before)
            }
        }
        guard case .stale = WidgetCompletion.plan(request, snapshot: value, account: "other") else { return XCTFail("Wrong account") }
    }
    func testEncodedPathsStayCaseSensitiveAcrossRequestsReceiptsAndDisk() throws {
        let value = fixture(), request = try action(value)
        var corrupt = request; corrupt.taskID = request.taskID.lowercased(); XCTAssertNotEqual(request.taskID, corrupt.taskID)
        XCTAssertFalse(request.matches(corrupt)); var copy = value; copy.widgetCompletion.record(request); XCTAssertFalse(copy.widgetCompletion.saved(corrupt))
        guard case .stale = WidgetCompletion.plan(corrupt, snapshot: value, account: "owner") else { return XCTFail("Case-folded path accepted") }
        XCTAssertEqual(WidgetTaskIdentity.key("ABC-DEF"), "abc-def")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-child-case-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: directory) }
        let disk = WidgetActionDisk(directory: directory); try disk.publish(JSONEncoder().encode(payload(value)))
        XCTAssertThrowsError(try disk.enqueue(corrupt)); XCTAssertEqual(try disk.enqueue(request), request)
    }
    func testScopedLinksResolveExactChildAndRejectOldIncarnationsOrMissingContext() throws {
        let value = fixture(), item = try leaf(value)
        let url = WidgetLinks.task(item.id, account: "owner", context: WidgetCompletion.routeContext(item))
        XCTAssertTrue(WidgetRecordLink.allows(url, account: "owner", available: true))
        XCTAssertEqual(try WidgetRecordLink.task(url, roots: value.tables["tasks"]!, projects: value.tables["projects"]!, workspace: workspace), item.record)
        for link in [WidgetLinks.task(item.id), WidgetLinks.task(item.id, account: "owner"), WidgetLinks.task(item.id, account: "other", context: WidgetCompletion.routeContext(item)), URL(string: url.absoluteString + "&context=duplicate")!] {
            XCTAssertFalse(WidgetRecordLink.allows(link, account: "owner", available: true))
        }
        var roots = value.tables["tasks"]!; roots[0]["task_generation"] = .string("replaced")
        XCTAssertThrowsError(try WidgetRecordLink.task(url, roots: roots, projects: value.tables["projects"]!, workspace: workspace))
        XCTAssertFalse(WidgetRecordLink.allows(url, account: "owner", available: false))
        roots = value.tables["tasks"]!; roots[0]["subtasks"] = SubtaskTree.changing(roots[0]["subtasks"], id: "CaseSensitiveLeaf", fields: ["completed": .bool(true)])
        let completed = try WidgetRecordLink.task(url, roots: roots, projects: value.tables["projects"]!, workspace: workspace)
        XCTAssertTrue(completed.completed, "Completion feedback can open the same saved child")
        XCTAssertEqual(WidgetRecordLink.containingTask(completed, roots: roots)?.completed, false, "A completed child must not route to an empty root Completed list")
        roots[0]["completed"] = .bool(true)
        XCTAssertEqual(WidgetRecordLink.containingTask(completed, roots: roots)?.completed, true)
        XCTAssertNil(WidgetRecordLink.containingTask(completed, roots: []))
    }
    func testMissingNestedCatalogCannotRenderFalseAllClearAndSignOutClearsContent() throws {
        let value = fixture(); var published = payload(value)
        published.removeValue(forKey: "nestedTasks")
        var widget = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(published))
        let list = try XCTUnwrap(widget.availableLists.first { $0.recordID == "children" })
        XCTAssertEqual(widget.listStatus(list.id, at: now, calendar: calendar), .refresh)
        published["nestedTasks"] = .array([]); widget = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(published))
        XCTAssertEqual(widget.listStatus(list.id, at: now, calendar: calendar), .unavailable)
        let empty = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(payload(value, account: "")))
        XCTAssertTrue(empty.tasks.isEmpty); XCTAssertTrue(empty.availableLists.isEmpty); XCTAssertTrue(empty.nestedTasks?.isEmpty ?? true)
    }
}
