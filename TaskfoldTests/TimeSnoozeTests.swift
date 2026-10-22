import XCTest
@testable import TaskfoldCore

private actor DurableSnoozeCenter: ReminderCenter {
    var requests: [ReminderRequest] = []
    var outside = 60
    var addCalls = 0
    var noRoom = false
    var fail = false
    func pending() async -> [ReminderRequest] { requests }
    func removeInvalid(_ state: ReminderState) async { requests.removeAll { !$0.valid(state: state) } }
    func remove(_ identifiers: [String]) async { requests.removeAll { identifiers.contains($0.identifier) } }
    func occupiedOutsideTimeAndFocus() async -> [String] { (0..<outside).map { "other-\($0)" } }
    func add(_ request: ReminderRequest) async throws {
        addCalls += 1
        if noRoom { throw ReminderSchedulingFailure.noRoom }
        if fail { throw AppFailure(message: "Synthetic native refusal") }
        requests.removeAll { $0.identifier == request.identifier }; requests.append(request)
    }
    func configure(outside: Int = 0, noRoom: Bool = false, fail: Bool = false) { self.outside = outside; self.noRoom = noRoom; self.fail = fail }
}
private actor DurableSnoozeLedger {
    var record: TimeSnoozeIntent
    var refuseReserve = false
    var refuseInstalled = false
    init(_ record: TimeSnoozeIntent) { self.record = record }
    func configure(reserve: Bool = false, installed: Bool = false) { refuseReserve = reserve; refuseInstalled = installed }
    func transition(_ input: LocationSnoozeTransition) -> LocationSnoozeAcknowledgement {
        switch input {
        case .reserve: if refuseReserve { return .retry }; guard record.phase == .queued else { return .obsolete }; record = record.changing(to: .reserved)
        case .installed: if refuseInstalled { return .retry }; record = record.changing(to: .installed)
        case .notSubmitted: record = record.changing(to: .queued)
        case .failed: record = record.changing(to: .closed)
        }
        return .saved
    }
}
final class TimeSnoozeTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_800_000)
    let epoch = "91000000-0000-4000-8000-000000000001"
    let account = "local"
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    func task() -> Record {
        var task = Record.task(user: account)
        task["title"] = .string("A private title must not be saved in recovery")
        task["due_date"] = .string("2026-10-24")
        task["due_time"] = .string("09:00")
        return task
    }
    func fixture() throws -> (Record, ReminderRequest, TimeSnoozeIntent) {
        let task = task(), event = try XCTUnwrap(DueReminder.events(tasks: [task], calendar: calendar, now: now).first)
        let request = ReminderRequest.make(account: account, event: event, fireAt: now.addingTimeInterval(900), snoozed: true)
        return (task, request, try XCTUnwrap(TimeSnoozeIntent(request: request, epoch: epoch)))
    }
    private func state(_ task: Record, request: ReminderRequest, ledger: DurableSnoozeLedger, revision: Int = 1) -> ReminderState {
        var state = ReminderState(revision: revision, account: account, events: [], now: now, validationTasks: [task], calendar: calendar)
        state.queuedTimeSnoozes = [request]
        state.timeSnoozeTransition = { _, change in await ledger.transition(change) }
        return state
    }
    func testQueueSurvivesActualCacheSerializationThenNewSchedulerRetriesExactInstant() async throws {
        let (task, request, intent) = try fixture()
        var cache = Snapshot(tables: ["tasks": [task]])
        cache.timeSnoozes = try TimeSnoozeOutbox.staging(previous: [:], proposed: [intent.id: intent], newIntent: intent, now: now)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("local.json")
        try JSONEncoder().encode(cache).write(to: file, options: .atomic)
        let firstLedger = DurableSnoozeLedger(intent), firstCenter = DurableSnoozeCenter()
        let report = await ReminderScheduler(center: firstCenter).update(state(task, request: request, ledger: firstLedger))
        XCTAssertEqual(report.deferredSnoozes, [request]); let untouched = await firstLedger.record; XCTAssertEqual(untouched.phase, .queued)
        let read = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
        let recovered = try XCTUnwrap(read.timeSnoozes?[intent.id])
        let exact = try XCTUnwrap(recovered.request(account: account, epoch: epoch, tasks: read.tables["tasks"]!, now: now, calendar: calendar))
        XCTAssertEqual(exact.fireAt, request.fireAt)
        let newCenter = DurableSnoozeCenter(); await newCenter.configure()
        let newLedger = DurableSnoozeLedger(recovered)
        let accepted = await ReminderScheduler(center: newCenter).update(state(task, request: exact, ledger: newLedger))
        XCTAssertEqual(accepted.acceptedSnoozes, [request]); let installed = await newLedger.record; XCTAssertEqual(installed.phase, .installed)
    }
    func testReserveWriteRefusalNeverCallsNativeAdd() async throws {
        let (task, request, intent) = try fixture(), center = DurableSnoozeCenter(), ledger = DurableSnoozeLedger(intent)
        await center.configure(); await ledger.configure(reserve: true)
        let report = await ReminderScheduler(center: center).update(state(task, request: request, ledger: ledger))
        XCTAssertEqual(report.failedSnoozes, [request]); let count = await center.addCalls; XCTAssertEqual(count, 0)
    }
    func testNativeNoRoomRestoresQueuedButOtherRefusalClosesIt() async throws {
        for noRoom in [true, false] {
            let (task, request, intent) = try fixture(), center = DurableSnoozeCenter(), ledger = DurableSnoozeLedger(intent)
            await center.configure(noRoom: noRoom, fail: !noRoom)
            let report = await ReminderScheduler(center: center).update(state(task, request: request, ledger: ledger))
            let saved = await ledger.record
            XCTAssertEqual(saved.phase, noRoom ? .queued : .closed)
            XCTAssertEqual(noRoom ? report.deferredSnoozes : report.failedSnoozes, [request])
        }
    }
    func testAmbiguousReservationRecoversOnlyFromExactNativeProof() throws {
        let (task, request, intent) = try fixture(), reserved = intent.changing(to: .reserved)
        for pending in [[], [request]] {
            let next = TimeSnoozeOutbox.reconciling([reserved.id: reserved], account: account, epoch: epoch, tasks: [task], enabled: true, pending: pending, now: now, calendar: calendar)
            XCTAssertEqual(next[reserved.id]?.phase, pending.isEmpty ? .closed : .installed)
        }
        var wrong = request; wrong.fireAt = wrong.fireAt.addingTimeInterval(60)
        let next = TimeSnoozeOutbox.reconciling([reserved.id: reserved], account: account, epoch: epoch, tasks: [task], enabled: true, pending: [wrong], now: now, calendar: calendar)
        XCTAssertEqual(next[reserved.id]?.phase, .closed)
    }
    func testInstalledAcknowledgementFailureCanAdoptWithoutResubmitting() async throws {
        let (task, request, intent) = try fixture(), center = DurableSnoozeCenter(), ledger = DurableSnoozeLedger(intent)
        await center.configure(); await ledger.configure(installed: true)
        _ = await ReminderScheduler(center: center).update(state(task, request: request, ledger: ledger))
        let saved = await ledger.record, native = await center.requests
        XCTAssertEqual(saved.phase, .reserved)
        let next = TimeSnoozeOutbox.reconciling([saved.id: saved], account: account, epoch: epoch, tasks: [task], enabled: true, pending: native, now: now, calendar: calendar)
        XCTAssertEqual(next[saved.id]?.phase, .installed)
        let calls = await center.addCalls; XCTAssertEqual(calls, 1)
    }
    func testTaskCompletionRemovalChangesAndEpochCannotReviveWithUndo() throws {
        let (task, _, intent) = try fixture()
        var done = task; done["completed"] = .bool(true)
        var changed = task; changed["task_generation"] = .string(UUID().uuidString.lowercased())
        for tasks in [[], [done], [changed]] {
            let ended = TimeSnoozeOutbox.reconciling([intent.id: intent], account: account, epoch: epoch, tasks: tasks, enabled: true, pending: [], now: now, calendar: calendar)
            XCTAssertEqual(ended[intent.id]?.phase, .closed)
            let undone = try TimeSnoozeOutbox.staging(previous: ended, proposed: [intent.id: intent], now: now)
            XCTAssertEqual(undone[intent.id]?.phase, .closed)
        }
        for (owner, epochValue, enabled) in [("other",epoch,true), (account,UUID().uuidString.lowercased(),true), (account,epoch,false)] {
            let ended = TimeSnoozeOutbox.reconciling([intent.id: intent], account: owner, epoch: epochValue, tasks: [task], enabled: enabled, pending: [], now: now, calendar: calendar)
            XCTAssertEqual(ended[intent.id]?.phase, .closed)
        }
    }
    func testNewQueuedIntentSupersedesEarlierNativeSnoozeWithoutMovingChosenTime() async throws {
        let (task, request, intent) = try fixture(), center = DurableSnoozeCenter(), ledger = DurableSnoozeLedger(intent)
        await center.configure()
        var old = request; old.fireAt = old.fireAt.addingTimeInterval(-60)
        try await center.add(old)
        let report = await ReminderScheduler(center: center).update(state(task, request: request, ledger: ledger))
        XCTAssertEqual(report.acceptedSnoozes, [request])
        let pending = await center.requests; XCTAssertEqual(pending, [request])
    }
    func testExpiredSnoozeDoesNotCatchUpAndRetentionIsBounded() throws {
        let (_, _, intent) = try fixture()
        XCTAssertTrue(try TimeSnoozeOutbox.staging(previous: [intent.id: intent], proposed: [intent.id: intent], now: Date(timeIntervalSince1970: intent.fireAt)).isEmpty)
        var entries: [String: TimeSnoozeIntent] = [:]
        for _ in 0..<TimeSnoozeOutbox.maximum {
            let (_, request, _) = try fixture(); let value = try XCTUnwrap(TimeSnoozeIntent(request: request, epoch: epoch)); entries[value.id] = value
        }
        XCTAssertTrue(TimeSnoozeOutbox.valid(entries))
        XCTAssertThrowsError(try TimeSnoozeOutbox.staging(previous: entries, proposed: entries.merging([intent.id:intent]) { _, b in b }, newIntent: intent, now: now))
        let (_, base, _) = try fixture()
        var future = base; future.fireAt = now.addingTimeInterval(3600)
        let replacement = try XCTUnwrap(TimeSnoozeIntent(request: future, epoch: epoch))
        let reclaimed = try TimeSnoozeOutbox.staging(previous: entries, proposed: entries.merging([replacement.id:replacement]) { _, b in b }, newIntent: replacement, now: now.addingTimeInterval(901))
        XCTAssertEqual(reclaimed, [replacement.id:replacement], "Expired records must free capacity before the new intent is admitted")

    }
    func testRestoreCannotIntroduceNewIntentOrRewindAnExistingOne() throws {
        let (_, _, intent) = try fixture()
        XCTAssertTrue(try TimeSnoozeOutbox.staging(previous: [:], proposed: [intent.id:intent], now: now).isEmpty)
        let installed = intent.changing(to: .reserved).changing(to: .installed)
        let next = try TimeSnoozeOutbox.staging(previous: [intent.id:installed], proposed: [intent.id:intent], now: now)
        XCTAssertEqual(next[intent.id], installed)
        var conflict = intent; conflict.phase = .closed
        XCTAssertThrowsError(try TimeSnoozeOutbox.staging(previous: [intent.id:intent], proposed: [intent.id:conflict], now: now))
    }
    func testOpaquePayloadRefusedAndPortableBackupContainsNoRecovery() throws {
        let (task, request, intent) = try fixture()
        let data = try JSONEncoder().encode(intent); let object = try JSONDecoder().decode(JSON.self, from: data).object
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(task.title))
        for field in ["version", "epoch", "signature", "fireAt"] {
            var changed = object
            changed[field] = field == "version" ? .number(2) : field == "fireAt" ? .number(-1) : .string("")
            let entry = try JSONDecoder().decode(TimeSnoozeIntent.self, from: JSONEncoder().encode(JSON.object(changed)))
            XCTAssertFalse(entry.valid)
            var cache = Snapshot(); cache.timeSnoozes = [entry.id:entry]
            XCTAssertThrowsError(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(cache)))
        }
        var cache = Snapshot(tables: ["tasks":[task]]); cache.timeSnoozes = [intent.id:intent]
        let backup = try WorkspaceBackup.make(cache, account: account).data()
        XCTAssertFalse(String(decoding: backup, as: UTF8.self).contains("timeSnoozes"))
        var invalid = request; invalid.event.signature = "r9:private"; invalid.event.kind = .focusFinish
        XCTAssertNil(TimeSnoozeIntent(request: invalid, epoch: epoch))
    }
}
