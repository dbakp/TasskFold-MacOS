import XCTest
import UserNotifications
@testable import TaskfoldCore

private actor TestReminderCenter: ReminderCenter {
    var requests: [ReminderRequest] = []
    var delivered: [ReminderRequest] = []
    var additions = 0
    var failNext = false
    var pauseNext = false
    var paused = false
    private var gate: CheckedContinuation<Void, Never>?
    func pending() async -> [ReminderRequest] { requests }
    func removeInvalid(account: String, events: [DueReminder]) async {
        requests.removeAll { !$0.valid(account: account, events: events) }
        delivered.removeAll { !$0.valid(account: account, events: events) }
    }
    func remove(_ identifiers: [String]) async { requests.removeAll { identifiers.contains($0.identifier) } }
    func add(_ request: ReminderRequest) async throws {
        additions += 1
        if pauseNext { pauseNext = false; paused = true; await withCheckedContinuation { gate = $0 }; paused = false }
        if failNext { failNext = false; throw NSError(domain: "fixture", code: 1) }
        requests.removeAll { $0.identifier == request.identifier }; requests.append(request)
    }
    func fail() { failNext = true }
    func pause() { pauseNext = true }
    func release() { pauseNext = false; gate?.resume(); gate = nil }
    func deliver(_ request: ReminderRequest) { delivered.append(request) }
}

final class ReminderTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!; return c }
    var now: Date { TaskPlanning.instant("2026-10-24T00:00:00Z")! }
    func task(_ id: String = "task", specs: [ReminderSpec] = []) -> Record {
        Record(["id": .string(id), "title": .string("Prepare"), "due_date": .string("2026-10-25"), "due_time": .string("09:00"), "reminder_specs": .array(specs.map { .object($0.raw) })])
    }
    func state(_ revision: Int, tasks: [Record], account: String = "account") -> ReminderState {
        ReminderState(revision: revision, account: account, events: DueReminder.events(tasks: tasks, calendar: calendar), now: now)
    }
    func testCompletionCycleInvalidatesOldNotificationAndSnoozeWithoutChangingItsPlannedTime() throws {
        var row = task(); let first = try XCTUnwrap(DueReminder.events(tasks: [row], calendar: calendar).first)
        let request = ReminderRequest.make(account: "account", event: first, fireAt: first.date.addingTimeInterval(3600), snoozed: true)
        row["completion_version"] = .number(0)
        XCTAssertEqual(DueReminder.events(tasks: [row], calendar: calendar).first?.signature, first.signature)
        row["title"] = .string("Unrelated edit")
        XCTAssertTrue(request.valid(account: "account", events: DueReminder.events(tasks: [row], calendar: calendar)))
        row["completion_version"] = .number(2)
        let next = try XCTUnwrap(DueReminder.events(tasks: [row], calendar: calendar).first)
        XCTAssertEqual(first.date, next.date); XCTAssertNotEqual(first.signature, next.signature)
        XCTAssertFalse(request.valid(account: "account", events: [next]))
        XCTAssertEqual(ReminderRequest.make(account: "account", event: next).identifier, ReminderRequest.make(account: "account", event: first).identifier)
    }
    func testLegacyPreferenceIsScopedAndDisablingDoesNotAffectAnotherAccount() {
        let name = "taskfold-reminder-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "remindersEnabled")
        XCTAssertFalse(ReminderPreferences.enabled(account: "", defaults: defaults))
        XCTAssertTrue(ReminderPreferences.enabled(account: "FIRST", defaults: defaults))
        XCTAssertTrue(ReminderPreferences.enabled(account: "first", defaults: defaults))
        XCTAssertFalse(ReminderPreferences.enabled(account: "second", defaults: defaults))
        defaults.set(true, forKey: ReminderPreferences.key("second"))
        defaults.set(false, forKey: ReminderPreferences.key("first"))
        XCTAssertFalse(ReminderPreferences.enabled(account: "first", defaults: defaults))
        XCTAssertTrue(ReminderPreferences.enabled(account: "second", defaults: defaults))
    }
    func testSystemCalendarTriggerUsesUTCAndPreservesSecondDSTFold() throws {
        let instant = try XCTUnwrap(TaskPlanning.instant("2026-10-25T01:30:00Z"))
        let trigger = SystemReminderCenter.trigger(at: instant)
        XCTAssertEqual(trigger.dateComponents.timeZone?.secondsFromGMT(for: instant), 0)
        XCTAssertEqual(trigger.dateComponents.calendar?.date(from: trigger.dateComponents), instant)
        XCTAssertFalse(trigger.repeats)
        // The native trigger calculates the same instant, independent of the Mac's local zone.
        XCTAssertEqual(trigger.nextTriggerDate(), instant > Date() ? instant : nil)
        var reserved = ReminderSpec.relative(0, id: ReminderSpec.plannedID).raw
        reserved["offset_minutes"] = .number(5)
        XCTAssertNil(ReminderSpec(row: .object(reserved)))
    }
    func testAddingDuplicateReminderDoesNotMutateTheTask() {
        var row = task(); let original = row
        XCTAssertFalse(ReminderSpec.append(.relative(0), task: &row)); XCTAssertEqual(row, original)
        let reminder = ReminderSpec.relative(-10)
        XCTAssertTrue(ReminderSpec.append(reminder, task: &row)); let saved = row
        XCTAssertFalse(ReminderSpec.append(.relative(-10), task: &row)); XCTAssertEqual(row, saved)
        var disabled = ReminderSpec.relative(-10); disabled.raw["enabled"] = .bool(false)
        XCTAssertTrue(ReminderSpec.append(disabled, task: &row))
    }
    func testPlannedToggleCannotEnableDuplicateZeroOffsetAndOverLimitRowsAreBounded() {
        var row = task(); ReminderSpec.setPlanned(false, task: &row)
        XCTAssertTrue(ReminderSpec.append(.relative(0), task: &row))
        let saved = row; XCTAssertFalse(ReminderSpec.setPlanned(true, task: &row)); XCTAssertEqual(row, saved)
        row["reminder_specs"] = .array((0..<25).map { .object(ReminderSpec.relative($0).raw) })
        XCTAssertEqual(DueReminder.events(tasks: [row], calendar: calendar).count, 20)
    }
    func testMultipleAbsoluteAndRelativeRemindersFollowDifferentAnchors() throws {
        let absolute = ReminderSpec.absolute(now.addingTimeInterval(7200))
        var row = task(specs: [.relative(-30), .relative(15), absolute])
        let initial = DueReminder.events(tasks: [row], calendar: calendar)
        XCTAssertEqual(initial.count, 3)
        let anchor = try XCTUnwrap(TaskPlanning.start(row, calendar: calendar))
        XCTAssertEqual(initial.first(where: { $0.specID == row["reminder_specs"].list[0].object["id"]?.text })?.date, anchor.addingTimeInterval(-1800))
        row["due_date"] = .string("2026-10-26")
        let moved = DueReminder.events(tasks: [row], calendar: calendar)
        XCTAssertEqual(moved.first(where: { $0.specID == absolute.id })?.date, absolute.absolute)
        XCTAssertNotEqual(moved.last?.date, initial.last?.date)
        XCTAssertEqual(Set(moved.map(\.id)).count, 3)
    }
    func testUndatedTaskRetainsRelativeButSchedulesAbsoluteAndCompletionCancelsAll() {
        var row = task(specs: [.relative(-10), .absolute(now.addingTimeInterval(3600))])
        row["due_date"] = .null; row["due_time"] = .null
        XCTAssertEqual(DueReminder.plan(tasks: [row], now: now, calendar: calendar).count, 1)
        XCTAssertEqual(ReminderSpec.rows(row).count, 2)
        row["completed"] = .bool(true)
        XCTAssertTrue(DueReminder.events(tasks: [row], calendar: calendar).isEmpty)
    }
    func testDateOnlyEightAMOffsetsAndPassedEventsRemainEligibleForSnooze() {
        var row = task(specs: [.relative(-60), .relative(30)]); row["due_time"] = .null
        let events = DueReminder.events(tasks: [row], calendar: calendar)
        XCTAssertEqual(events.map { calendar.component(.hour, from: $0.date) }, [7, 8])
        XCTAssertEqual(calendar.component(.minute, from: events[1].date), 30)
        XCTAssertTrue(DueReminder.plan(tasks: [row], now: events[1].date, calendar: calendar).isEmpty)
        XCTAssertEqual(DueReminder.events(tasks: [row], calendar: calendar).count, 2)
    }
    func testFixedSecondDSTFoldAndElapsedOffsetArePreservedAcrossTravel() throws {
        var row = task(specs: [.relative(-30)])
        row["due_time"] = .string("02:30"); row["time_zone"] = .string("Europe/Copenhagen"); row["scheduled_at"] = .string("2026-10-25T01:30:00Z")
        var travel = calendar; travel.timeZone = TimeZone(identifier: "America/New_York")!
        let events = DueReminder.events(tasks: [row], calendar: travel)
        XCTAssertEqual(events.first?.date, TaskPlanning.instant("2026-10-25T01:00:00Z"))
        let absolute = ReminderSpec.absolute(TaskPlanning.instant("2026-10-25T01:30:00Z")!)
        XCTAssertEqual(absolute.date(task: row, calendar: travel), absolute.date(task: row, calendar: calendar))
        row["time_zone"] = .null; row["scheduled_at"] = .null
        XCTAssertNotEqual(DueReminder.events(tasks: [row], calendar: travel).first?.date, DueReminder.events(tasks: [row], calendar: calendar).first?.date)
    }
    func testExplicitOptOutDefaultMaterializationAndRecurrence() {
        var row = task()
        XCTAssertTrue(ReminderSpec.plannedEnabled(row))
        XCTAssertTrue(ReminderSpec.append(.absolute(now.addingTimeInterval(3600)), task: &row))
        XCTAssertEqual(ReminderSpec.rows(row).count, 2)
        ReminderSpec.setPlanned(false, task: &row)
        XCTAssertEqual(DueReminder.events(tasks: [row], calendar: calendar).count, 1)
        let next = TaskPlanning.nextOccurrence(row, date: now.addingTimeInterval(3 * 86400))
        XCTAssertEqual(ReminderSpec.rows(next).count, 1)
        XCTAssertTrue(DueReminder.events(tasks: [next], calendar: calendar).isEmpty)
        let onlyAbsolute = task(specs: [.absolute(now.addingTimeInterval(3600))])
        XCTAssertFalse(ReminderSpec.successorRows(ReminderSpec.rows(onlyAbsolute)).isEmpty)
        XCTAssertFalse(ReminderSpec.plannedEnabled(TaskPlanning.nextOccurrence(onlyAbsolute, date: now)))
    }
    func testFutureMetadataMalformedRowsAndChannelChoicesAreNotRewritten() throws {
        var spec = ReminderSpec.relative(-10); spec.raw["future"] = .object(["color": .string("rose")])
        let encoded = try JSONEncoder().encode(JSON.object(spec.raw))
        XCTAssertEqual(ReminderSpec(row: try JSONDecoder().decode(JSON.self, from: encoded))?.raw, spec.raw)
        var future = spec.raw; future["version"] = .number(2)
        var invalid = spec.raw; invalid["offset_minutes"] = .number(10081)
        var fractional = spec.raw; fractional["offset_minutes"] = .number(1.5)
        var push = spec.raw; push["channels"] = .array([.string("push")])
        XCTAssertNil(ReminderSpec(row: .object(invalid))); XCTAssertNil(ReminderSpec(row: .object(fractional)))
        var row = task(); row["reminder_specs"] = .array([.object(future), .object(invalid), .object(push)])
        XCTAssertTrue(DueReminder.events(tasks: [row], calendar: calendar).isEmpty)
        let values = ReminderSpec.rows(row)
        ReminderSpec.setPlanned(false, task: &row)
        XCTAssertEqual(Array(ReminderSpec.rows(row).prefix(3)), values)
        XCTAssertEqual(ReminderSpec.successorRows(values), values)
        XCTAssertFalse(ReminderSpec(row: .object(push))!.locallyEditable)
    }
    func testStableIdentityBoundsDuplicatesAndEarliestLimit() {
        let first = ReminderSpec.relative(-10)
        var duplicate = first; duplicate.raw["id"] = .string(first.id.uppercased())
        var row = task(specs: [first, duplicate])
        XCTAssertEqual(DueReminder.events(tasks: [row], calendar: calendar).count, 1)
        row["reminder_specs"] = .array((0..<20).map { .object(ReminderSpec.relative($0).raw) })
        XCTAssertFalse(ReminderSpec.append(.relative(90), task: &row))
        XCTAssertEqual(ReminderSpec.rows(row).count, 20)
        let events = DueReminder.plan(tasks: [row], now: now, calendar: calendar, limit: 2)
        XCTAssertEqual(events.count, 2); XCTAssertLessThan(events[0].date, events[1].date)
        XCTAssertEqual(DueReminder.events(tasks: [row], calendar: calendar), DueReminder.events(tasks: [row], calendar: calendar))
        let a = ReminderRequest.make(account: "one", event: events[0]), b = ReminderRequest.make(account: "two", event: events[0])
        XCTAssertNotEqual(a.identifier, b.identifier)
    }
    func testSchedulerDiffFailureRetryAndCapacityReport() async {
        let center = TestReminderCenter()
        let runner = ReminderScheduler(center: center)
        await center.fail()
        let failed = await runner.update(state(1, tasks: [task()]))
        XCTAssertEqual(failed.failures, 1); XCTAssertEqual(failed.scheduled, 0)
        let retried = await runner.update(state(2, tasks: [task()])); XCTAssertEqual(retried.scheduled, 1)
        let additions = await center.additions
        _ = await runner.update(state(3, tasks: [task()])); let after = await center.additions
        XCTAssertEqual(after, additions)
        let report = await runner.update(state(4, tasks: (0..<65).map { task("task\($0)") }))
        XCTAssertEqual(report.scheduled, 60); XCTAssertEqual(report.deferred, 5)
        let pending = await center.requests; XCTAssertEqual(pending.count, 60)
    }
    func testSnoozeSurvivesRefreshButCancelsAfterMoveCompletionDeleteAndAccountSwitch() async throws {
        for mode in ["move", "complete", "delete", "account"] {
            let center = TestReminderCenter()
            let scheduler = ReminderScheduler(center: center)
            var row = task(specs: [.relative(-10)])
            _ = await scheduler.update(state(1, tasks: [row]))
            let event = try XCTUnwrap(DueReminder.events(tasks: [row], calendar: calendar).first)
            _ = await scheduler.snooze(account: "account", taskID: event.taskID, specID: event.specID, signature: event.signature, now: now)
            _ = await scheduler.update(state(2, tasks: [row]))
            let pending = await center.requests; XCTAssertEqual(pending.filter(\.snoozed).count, 1)
            await center.deliver(pending.first!)
            if mode == "move" { row["due_date"] = .string("2026-10-26") }
            if mode == "complete" { row["completed"] = .bool(true) }
            let next = state(3, tasks: mode == "delete" ? [] : [row], account: mode == "account" ? "different" : "account")
            _ = await scheduler.update(next)
            let after = await center.requests, delivered = await center.delivered
            XCTAssertTrue(after.filter(\.snoozed).isEmpty, mode); XCTAssertTrue(delivered.isEmpty, mode)
            let stale = await scheduler.snooze(account: "account", taskID: event.taskID, specID: event.specID, signature: event.signature, now: now)
            XCTAssertNil(stale, mode)
        }
    }
    func testInFlightAddCannotRestorePreviousAccountOrOlderPlan() async throws {
        let center = TestReminderCenter()
        let runner = ReminderScheduler(center: center)
        await center.pause()
        let old = Task { await runner.update(state(1, tasks: [task()], account: "old")) }
        for _ in 0..<200 { if await center.paused { break }; try await Task.sleep(for: .milliseconds(5)) }
        let paused = await center.paused; XCTAssertTrue(paused)
        let next = state(2, tasks: [], account: "")
        let new = Task { await runner.update(next) }
        for _ in 0..<200 { if await runner.currentRevision == 2 { break }; try await Task.sleep(for: .milliseconds(5)) }
        await center.release()
        let final = await new.value, oldReport = await old.value
        XCTAssertEqual(final.revision, 2); XCTAssertEqual(oldReport.revision, 2)
        let pending = await center.requests; XCTAssertTrue(pending.isEmpty)
        _ = await runner.update(state(1, tasks: [task()], account: "old"))
        let stillEmpty = await center.requests; XCTAssertTrue(stillEmpty.isEmpty)
    }
    func testFailedSnoozeIsReportedAndRetried() async throws {
        let center = TestReminderCenter()
        let scheduler = ReminderScheduler(center: center)
        let row = task(); _ = await scheduler.update(state(1, tasks: [row]))
        let event = try XCTUnwrap(DueReminder.events(tasks: [row], calendar: calendar).first)
        await center.fail()
        let report = await scheduler.snooze(account: "account", taskID: event.taskID, specID: event.specID, signature: event.signature, now: now)
        XCTAssertEqual(report?.failures, 1)
        _ = await scheduler.update(state(2, tasks: [row]))
        let pending = await center.requests; XCTAssertEqual(pending.filter(\.snoozed).count, 1)
    }
}


extension ReminderTests {
    func testPendingOpenRouteRevalidatesWorkspaceIncarnationAndReminderCycle() throws {
        var task=Record.task(user:"owner",date:Date().addingTimeInterval(86400)); task["due_time"] = .string("09:00")
        let event=try XCTUnwrap(DueReminder.events(tasks:[task]).first), generation=UUID()
        let route=ReminderTaskRoute(workspace:WorkspaceBinding(account:"owner",generation:generation),taskID:event.taskID,specID:event.specID,signature:event.signature)
        XCTAssertTrue(route.matches(account:"owner",generation:generation,events:[event]))
        XCTAssertFalse(route.matches(account:"other",generation:generation,events:[event]))
        XCTAssertFalse(route.matches(account:"owner",generation:UUID(),events:[event]))
        task["completion_version"] = .number(2)
        XCTAssertFalse(route.matches(account:"owner",generation:generation,events:DueReminder.events(tasks:[task])))
        task["completed"] = .bool(true)
        XCTAssertFalse(route.matches(account:"owner",generation:generation,events:DueReminder.events(tasks:[task])))
        XCTAssertFalse(route.matches(account:"owner",generation:generation,events:[]))
    }
}


extension ReminderTests {
    func testSharedWorkerProjectionVectorsMatchNativeCalendarAndCanonicalSignatures() throws {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"reminder-events",withExtension:"json",subdirectory:"Fixtures"))
        let fixture=try JSONDecoder().decode(JSON.self,from:Data(contentsOf:url))
        for item in fixture.object["cases"]?.list ?? [] {
            let c=item.object; let name=c["name"]?.text ?? ""; var calendar=Calendar(identifier:.gregorian)
            calendar.timeZone=try XCTUnwrap(TimeZone(identifier:c["zone"]?.text ?? ""))
            let task=Record(c["task"]?.object ?? [:]), expected=c["events"]?.list ?? []
            let actual=DueReminder.events(tasks:[task],calendar:calendar,channels:["local","push"])
            XCTAssertEqual(actual.count,expected.count,name)
            for (event,row) in zip(actual,expected) {
                XCTAssertEqual(event.specID,row.object["spec"]?.text,name)
                XCTAssertEqual(event.date.timeIntervalSince1970,try XCTUnwrap(TaskPlanning.instant(row.object["instant"]?.text ?? "")).timeIntervalSince1970,accuracy:0.0001,name)
                XCTAssertEqual(event.signature,row.object["signature"]?.text,name)
            }
            if name == "push only remote projection" { XCTAssertTrue(DueReminder.events(tasks:[task],calendar:calendar).isEmpty) }
        }
    }
    func testSemanticSignatureIgnoresJSONSpellingButRetainsScheduleChannelsAndCycle() {
        let at=TaskPlanning.instant("2026-10-25T00:30:00Z")!
        var spec=ReminderSpec.relative(0), row=task(); let base=ReminderSignature.make(task:row,spec:spec,date:at)
        spec.raw["extra"] = .object(["future":.string("Keep intact")]); spec.raw["at"] = .string("2027-01-01T00:00:00Z")
        XCTAssertEqual(ReminderSignature.make(task:row,spec:spec,date:at),base)
        spec.raw["channels"] = .array([.string("local"),.string("push")]); XCTAssertNotEqual(ReminderSignature.make(task:row,spec:spec,date:at),base)
        let channelSignature=ReminderSignature.make(task:row,spec:spec,date:at)
        spec.raw["channels"] = .array([.string("push"),.string("local")]); XCTAssertEqual(ReminderSignature.make(task:row,spec:spec,date:at),channelSignature)
        row["completion_version"] = .number(2); XCTAssertNotEqual(ReminderSignature.make(task:row,spec:spec,date:at),channelSignature)
        let changed=ReminderSignature.make(task:row,spec:spec,date:at)
        XCTAssertNotEqual(ReminderSignature.make(task:row,spec:spec,date:at.addingTimeInterval(1)),changed)
    }
}


extension ReminderTests {
    func testHalfHourDSTReminderShortcutsKeepTheRequestedDay() throws {
        var calendar=Calendar(identifier:.gregorian); calendar.timeZone=TimeZone(identifier:"Australia/Lord_Howe")!
        let now=try XCTUnwrap(TaskPlanning.instant("2026-10-03T14:00:00Z")), expected=try XCTUnwrap(TaskPlanning.instant("2026-10-03T15:30:00Z"))
        for text in ["today 2:15am","2026-10-04 2:15am","sun 2:15am","2:15am"] {
            let entry=QuickEntry("Check !"+text,now:now,calendar:calendar)
            let spec=try XCTUnwrap(entry.updates["reminder_specs"]?.list.compactMap(ReminderSpec.init(row:)).first { $0.kind == "absolute" },text)
            XCTAssertEqual(spec.absolute,expected,text)
        }
    }
}


extension ReminderTests {
    func testLegacySignaturesAcceptOnlyUnchangedCurrentScheduleAndCompletionCycle() throws {
        var row=task(); let event=try XCTUnwrap(DueReminder.events(tasks:[row],calendar:calendar).first)
        let old=try XCTUnwrap(event.legacySignature); XCTAssertTrue(event.hasSignature(old)); XCTAssertFalse(event.hasSignature("arbitrary"))
        var decoded=event; decoded.signature=old; decoded.legacySignature=nil
        let request=ReminderRequest.make(account:"owner",event:decoded)
        XCTAssertTrue(request.valid(account:"owner",events:[event])); XCTAssertFalse(request.valid(account:"other",events:[event]))
        row["completion_version"] = .number(2)
        XCTAssertFalse(request.valid(account:"owner",events:DueReminder.events(tasks:[row],calendar:calendar)))
        row["completion_version"] = .number(0); row["due_time"] = .string("10:00")
        XCTAssertFalse(request.valid(account:"owner",events:DueReminder.events(tasks:[row],calendar:calendar)))
        var same=event; same.legacySignature=nil; XCTAssertEqual(same,event)
    }
    func testLegacySnoozeUpgradesItsReceiptWithoutLosingTheChosenFireTime() async throws {
        var row=task(); let current=try XCTUnwrap(DueReminder.events(tasks:[row],calendar:calendar).first)
        var old=current; old.signature=try XCTUnwrap(current.legacySignature); old.legacySignature=nil
        let fire=current.date.addingTimeInterval(3600), center=TestReminderCenter(), scheduler=ReminderScheduler(center:center)
        try await center.add(ReminderRequest.make(account:"account",event:old,fireAt:fire,snoozed:true))
        row["title"] = .string("Current title")
        _=await scheduler.update(state(1,tasks:[row]))
        let pending=await center.requests, snooze=try XCTUnwrap(pending.first { $0.snoozed })
        XCTAssertEqual(snooze.fireAt,fire); XCTAssertEqual(snooze.event.signature,current.signature); XCTAssertEqual(snooze.event.title,"Current title")
        let adds=await center.additions
        _=await scheduler.update(state(2,tasks:[row]))
        let laterAdds=await center.additions; XCTAssertEqual(adds,laterAdds)
    }
    func testWorkingHoursUseNextValidGapAndLastFoldForTheEnd() throws {
        var c=Calendar(identifier:.gregorian); c.timeZone=TimeZone(identifier:"Australia/Lord_Howe")!
        let day=try XCTUnwrap(Dates.parse("2026-10-04",calendar:c)), interval=try XCTUnwrap(WorkingHours(start:135,end:180,weekdays:[1]).interval(on:day,calendar:c))
        XCTAssertEqual(interval.start,TaskPlanning.instant("2026-10-03T15:30:00Z")); XCTAssertEqual(interval.duration,30*60)
        c.timeZone=TimeZone(identifier:"Europe/Copenhagen")!
        let folded=try XCTUnwrap(Dates.parse("2026-10-25",calendar:c)), long=try XCTUnwrap(WorkingHours(start:135,end:165,weekdays:[1]).interval(on:folded,calendar:c))
        XCTAssertEqual(long.duration,90*60)
    }
}
