import XCTest
import UserNotifications
@testable import TaskfoldCore

private actor FinishCenter: ReminderCenter {
    var requests: [ReminderRequest] = []
    var fail = false
    var paused = false
    var gate: CheckedContinuation<Void, Never>?
    func pending() -> [ReminderRequest] { requests }
    func removeInvalid(_ state: ReminderState) { requests.removeAll { !$0.valid(state: state) } }
    func remove(_ ids: [String]) { requests.removeAll { ids.contains($0.identifier) } }
    func add(_ request: ReminderRequest) async throws {
        if paused { await withCheckedContinuation { gate = $0 }; paused = false }
        if fail { fail = false; throw NSError(domain: "fixture", code: 1) }
        requests.removeAll { $0.identifier == request.identifier }; requests.append(request)
    }
    func failNext() { fail = true }
    func pauseNext() { paused = true }
    func release() { gate?.resume(); gate = nil; paused = false }
}
final class FocusFinishTests: XCTestCase {
    let account = "11111111-1111-4111-8111-111111111111"
    let taskID = "33333333-3333-4333-8333-333333333333"
    let now = Date(timeIntervalSince1970: 1_791_281_600.125)
    func task() -> Record { Record(["id": .string(taskID), "title": .string("A useful step"), "completed": .bool(false), "completion_version": .number(0), "description": .string("Private notes")]) }
    func row(_ session: FocusSession, current: Record? = nil) throws -> Record { Record(try FocusSessionChange.make(session, current: current, account: account).fields) }
    func event(_ row: Record, tasks: [Record]? = nil) throws -> DueReminder { try XCTUnwrap(FocusFinish.event(row: row, tasks: tasks ?? [task()], account: account)) }
    func receipt(_ event: DueReminder, account: String? = nil) throws -> FocusFinishReceipt { try XCTUnwrap(FocusFinishReceipt(info: ["accountID": account ?? self.account, "taskID": event.taskID, "specID": event.specID, "signature": event.signature])) }
    func testTimestampFinishRoundsUpToSecondWithoutResettingAfterProcessEncoding() throws {
        let start = try FocusSession(taskID: taskID, minutes: 25, now: now), state = try row(start), first = try event(state)
        XCTAssertEqual(first.date.timeIntervalSince1970, ceil(start.endDate!.timeIntervalSince1970))
        XCTAssertLessThan(first.date.timeIntervalSince(start.endDate!), 1); XCTAssertGreaterThanOrEqual(first.date, start.endDate!)
        let copied = try JSONDecoder().decode(Record.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(try event(copied), first)
        let paused = try start.paused(at: now.addingTimeInterval(10.625)), pauseRow = try row(paused, current: state)
        XCTAssertNil(FocusFinish.event(row: pauseRow, tasks: [task()], account: account))
        let resumed = try paused.resumed(at: now.addingTimeInterval(70)), next = try event(row(resumed, current: pauseRow))
        XCTAssertEqual(next.date.timeIntervalSince1970, ceil(resumed.endDate!.timeIntervalSince1970)); XCTAssertNotEqual(first.signature, next.signature)
    }
    func testPauseStopClearConflictMissingCompletedUnreadableOrForeignStateCannotProduceFinishAlert() throws {
        let start = try FocusSession(taskID: taskID, minutes: 1, now: now), state = try row(start)
        for session in [try start.paused(at: now), try start.stopped(at: now)] { XCTAssertNil(FocusFinish.event(row: try row(session, current: state), tasks: [task()], account: account)) }
        XCTAssertNil(FocusFinish.event(row: nil, tasks: [task()], account: account))
        XCTAssertNil(FocusFinish.event(row: state, tasks: [], account: account))
        var done = task(); done["completed"] = .bool(true)
        XCTAssertNil(FocusFinish.event(row: state, tasks: [done], account: account))
        XCTAssertNil(FocusFinish.event(row: state, tasks: [task()], account: account, conflict: true))
        XCTAssertNil(FocusFinish.event(row: state, tasks: [task()], account: account, available: false))
        XCTAssertNil(FocusFinish.event(row: state, tasks: [task()], account: "other"))
        var bad = state; bad["revision"] = .number(1.5); XCTAssertNil(FocusFinish.event(row: bad, tasks: [task()], account: account))
    }
    func testCompletionCycleAndSessionRevisionInvalidateReceiptWhileTitleEditDoesNot() throws {
        let start = try FocusSession(taskID: taskID, minutes: 1, now: now), state = try row(start), first = try event(state), old = try receipt(first)
        XCTAssertFalse(old.valid(account: account, event: first, now: first.date.addingTimeInterval(-0.001)))
        XCTAssertTrue(old.valid(account: account, event: first, now: first.date))
        XCTAssertFalse(old.valid(account: "other", event: first, now: first.date))
        var renamed = task(); renamed["title"] = .string("Renamed")
        XCTAssertTrue(old.valid(account: account, event: try event(state, tasks: [renamed]), now: first.date))
        renamed["completion_version"] = .number(2)
        XCTAssertFalse(old.valid(account: account, event: try event(state, tasks: [renamed]), now: first.date))
        XCTAssertFalse(old.valid(account: account, event: try event(row(start, current: state)), now: first.date))
        let replacement = try FocusSession(taskID: taskID, minutes: 1, now: now)
        XCTAssertFalse(old.valid(account: account, event: try event(row(replacement, current: state)), now: first.date))
    }
    func testBoundedReceiptTitleAndSeparateTaskReminderNamespace() throws {
        let state = try row(FocusSession(taskID: taskID, minutes: 1, now: now))
        var huge = task(); huge["title"] = .string(String(repeating: "👩🏽‍💻 café", count: 1000))
        let finish = try event(state, tasks: [huge]); XCTAssertLessThan(finish.body.utf8.count, 1100); XCTAssertFalse(finish.body.contains("Private notes"))
        let request = ReminderRequest.make(account: account, event: finish)
        var normal = finish; normal.kind = .task
        XCTAssertNotEqual(request.identifier, ReminderRequest.make(account: account, event: normal).identifier)
        XCTAssertTrue(request.identifier.hasPrefix(FocusFinish.prefix))
        XCTAssertNotEqual(request.identifier, ReminderRequest.make(account: "another", event: finish).identifier)
        XCTAssertFalse(request.valid(account: account, events: [normal]))
        XCTAssertNil(FocusFinishReceipt(info: ["accountID": String(repeating: "x", count: 257), "taskID": taskID, "specID": finish.specID, "signature": finish.signature]))
        XCTAssertNil(FocusFinishReceipt(info: ["accountID": account, "taskID": taskID, "specID": finish.specID, "signature": "invalid"]))
    }
    func testActualSystemContentRoundTripsAndRejectsForgedFocusKindCategoryIdentityAndSnooze() throws {
        let finish = try event(row(FocusSession(taskID: taskID, minutes: 1, now: now)))
        let projected = ReminderRequest.make(account: account, event: finish)
        let content = SystemReminderCenter.content(for: projected)
        let notification = UNNotificationRequest(identifier: projected.identifier, content: content, trigger: SystemReminderCenter.trigger(at: projected.fireAt))
        XCTAssertEqual(SystemReminderCenter.decode(notification), projected)
        XCTAssertEqual(content.categoryIdentifier, FocusFinish.category)
        // The last permitted start still has a valid finish up to three hours later.
        let boundaryStart = Date(timeIntervalSince1970: Double(FocusSession.maximumTimestamp) / 1000)
        let boundaryEvent = try event(row(FocusSession(taskID: taskID, minutes: 180, now: boundaryStart)))
        let boundaryRequest = ReminderRequest.make(account: account, event: boundaryEvent)
        XCTAssertEqual(SystemReminderCenter.decode(UNNotificationRequest(identifier: boundaryRequest.identifier, content: SystemReminderCenter.content(for: boundaryRequest), trigger: nil)), boundaryRequest)
        XCTAssertNil(SystemReminderCenter.decode(UNNotificationRequest(identifier: projected.identifier + ".forged", content: content, trigger: nil)))
        for mode in ["category", "kind", "snooze", "future", "signature"] {
            let altered = content.mutableCopy() as! UNMutableNotificationContent
            switch mode {
            case "category": altered.categoryIdentifier = "taskfold.reminder"
            case "kind": altered.userInfo["eventKind"] = "future"
            case "snooze": altered.userInfo["snoozed"] = true
            case "future": altered.userInfo["fireAt"] = projected.fireAt.timeIntervalSince1970 + 3600
            default: altered.userInfo["signature"] = "invalid"
            }
            XCTAssertNil(SystemReminderCenter.decode(UNNotificationRequest(identifier: projected.identifier, content: altered, trigger: nil)), mode)
        }
    }
    func testUnifiedBudgetReservesFinishAndReportsTaskCountsSeparately() async throws {
        let finish = try event(row(FocusSession(taskID: taskID, minutes: 180, now: now)))
        let taskEvents = (0..<65).map { index in DueReminder(id: "task\(index)", title: "Task", body: "", date: now.addingTimeInterval(Double(index + 1)), taskID: "task\(index)", specID: "spec", signature: "signature") }
        let center = FinishCenter(), scheduler = ReminderScheduler(center: center)
        let report = await scheduler.update(ReminderState(revision: 1, account: account, events: taskEvents + [finish], now: now))
        XCTAssertEqual(report.scheduled, 59); XCTAssertEqual(report.deferred, 6); XCTAssertTrue(report.focusScheduled)
        let pending = await center.requests; XCTAssertEqual(pending.count, 60); XCTAssertEqual(pending.filter { $0.event.kind == .focusFinish }.count, 1)
        let forbidden = await scheduler.snooze(account: account, taskID: finish.taskID, specID: finish.specID, signature: finish.signature, now: now)
        XCTAssertNil(forbidden)
        let withoutFocus = await scheduler.update(ReminderState(revision: 2, account: account, events: taskEvents, now: now))
        XCTAssertEqual(withoutFocus.scheduled, 60); XCTAssertFalse(withoutFocus.focusScheduled)
    }
    func testFailureRetryAndAccountSwitchCancelFinishWithSeparateFailureReport() async throws {
        let finish = try event(row(FocusSession(taskID: taskID, minutes: 1, now: now)))
        let center = FinishCenter(), scheduler = ReminderScheduler(center: center)
        await center.failNext()
        let failed = await scheduler.update(ReminderState(revision: 1, account: account, events: [finish], now: now))
        XCTAssertTrue(failed.focusFailure); XCTAssertEqual(failed.failures, 0)
        let retried = await scheduler.update(ReminderState(revision: 2, account: account, events: [finish], now: now)); XCTAssertTrue(retried.focusScheduled)
        _ = await scheduler.update(ReminderState(revision: 3, account: "other", events: [], now: now)); let pending = await center.requests; XCTAssertTrue(pending.isEmpty)
    }
    func testStaleInFlightFinishAddDrainsAwayAfterPauseOrSignOut() async throws {
        let finish = try event(row(FocusSession(taskID: taskID, minutes: 1, now: now)))
        let center = FinishCenter(), scheduler = ReminderScheduler(center: center)
        await center.pauseNext()
        let old = Task { await scheduler.update(ReminderState(revision: 1, account: account, events: [finish], now: now)) }
        for _ in 0..<200 { if await center.gate != nil { break }; try await Task.sleep(for: .milliseconds(5)) }
        let new = Task { await scheduler.update(ReminderState(revision: 2, account: "", events: [], now: now)) }
        for _ in 0..<200 { if await scheduler.currentRevision == 2 { break }; try await Task.sleep(for: .milliseconds(5)) }
        await center.release(); let report = await new.value; _ = await old.value
        XCTAssertEqual(report.revision, 2); let pending = await center.requests; XCTAssertTrue(pending.isEmpty)
    }
}
