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
    func removeInvalid(_ state: ReminderState) async {
        requests.removeAll { !$0.valid(state: state) }
        delivered.removeAll { !$0.valid(state: state) }
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


extension ReminderTests {
    func calendarSpec(_ text: String = "every saturday", start: String = "2026-10-24", time: String = "09:00", zone: String = "Europe/Copenhagen") throws -> ReminderSpec {
        .recurring(try XCTUnwrap(ReminderCalendarSchedule.make(text, time: time, start: start, zone: zone)))
    }
    func testIndependentScheduleDoesNotReadPlanAndQueuesDistinctOccurrences() throws {
        let spec = try calendarSpec()
        var row = task(specs: [spec]); row["due_date"] = .null; row["due_time"] = .null
        let events = DueReminder.events(tasks: [row], calendar: calendar, now: now)
        XCTAssertEqual(events.count, 60); XCTAssertEqual(events.first?.date, TaskPlanning.instant("2026-10-24T07:00:00Z"))
        XCTAssertEqual(events[1].date, TaskPlanning.instant("2026-10-31T08:00:00Z"))
        XCTAssertEqual(Set(events.map(\.signature)).count, 60)
        XCTAssertEqual(Set(events.map { ReminderRequest.make(account: "account", event: $0).identifier }).count, 60)
        row["due_date"] = .string("2027-02-01"); row["due_time"] = .string("15:00")
        XCTAssertEqual(DueReminder.events(tasks: [row], calendar: calendar, now: now), events)
        row["completed"] = .bool(true); XCTAssertTrue(DueReminder.events(tasks: [row], now: now).isEmpty)
    }
    func testCalendarSchedulesKeepSourceClockAcrossTravelDSTGapsAndFolds() throws {
        let spring = try calendarSpec("every day for 3 occurrences", start: "2026-03-28", time: "02:30")
        let dates = try XCTUnwrap(spring.schedule).dates(after: TaskPlanning.instant("2026-03-27T00:00:00Z")!)
        XCTAssertEqual(dates.count, 3)
        XCTAssertEqual(dates.map { calendar.component(.minute, from: $0) }, [30, 0, 30], "A missing clock uses the next valid minute, matching task planning")
        XCTAssertEqual(dates.map { calendar.component(.hour, from: $0) }, [2, 3, 2])
        let autumn = try calendarSpec("every day for 3 occurrences", time: "02:30")
        let fall = try XCTUnwrap(autumn.schedule).dates(after: now)
        XCTAssertEqual(fall[1], TaskPlanning.instant("2026-10-25T00:30:00Z"))
        XCTAssertFalse(try XCTUnwrap(autumn.schedule).contains(TaskPlanning.instant("2026-10-25T01:30:00Z")!))
        var travel = calendar; travel.timeZone = TimeZone(identifier: "Pacific/Honolulu")!
        XCTAssertEqual(DueReminder.events(tasks: [task(specs: [autumn])], calendar: calendar, now: now), DueReminder.events(tasks: [task(specs: [autumn])], calendar: travel, now: now))
    }
    func testCalendarRuleIntervalsCountsEndLimitsAndSkippedFifthWeekdays() throws {
        let weekly = try calendarSpec("every 2 weeks on monday and friday for 5 occurrences", start: "2026-10-19")
        XCTAssertEqual(weekly.schedule?.dates(after: TaskPlanning.instant("2026-10-18T00:00:00Z")!).map { TaskPlanner.dayKey($0, calendar: calendar) }, ["2026-10-19", "2026-10-23", "2026-11-02", "2026-11-06", "2026-11-16"])
        let monthly = try calendarSpec("every month on 31 for 4 occurrences", start: "2027-01-31")
        XCTAssertEqual(monthly.schedule?.dates(after: now).map { TaskPlanner.dayKey($0, calendar: calendar) }, ["2027-01-31", "2027-02-28", "2027-03-31", "2027-04-30"])
        let fifth = try calendarSpec("every month on fifth monday for 3 occurrences", start: "2026-01-01")
        XCTAssertEqual(fifth.schedule?.dates(after: TaskPlanning.instant("2025-12-31T00:00:00Z")!).map { TaskPlanner.dayKey($0, calendar: calendar) }, ["2026-03-30", "2026-06-29", "2026-08-31"])
        let end = try calendarSpec("every day until 2026-10-26")
        XCTAssertEqual(end.schedule?.dates(after: now).count, 3)
        XCTAssertTrue(try XCTUnwrap(end.schedule).dates(after: TaskPlanning.instant("2026-10-26T08:00:00Z")!).isEmpty)
        let leap = try calendarSpec("every year on february 29 for 3 occurrences", start: "2028-02-29")
        XCTAssertEqual(leap.schedule?.dates(after: now).map { TaskPlanner.dayKey($0, calendar: calendar) }, ["2028-02-29", "2029-02-28", "2030-02-28"])
    }
    func testUnlimitedScheduleJumpsFromHistoricalAnchorAndCountDoesNotReset() throws {
        let old = try calendarSpec("every day", start: "0001-01-01", zone: "Etc/UTC")
        let current = try XCTUnwrap(old.schedule).dates(after: now, limit: 3)
        XCTAssertEqual(current.first, TaskPlanning.instant("2026-10-24T09:00:00Z")); XCTAssertEqual(current.count, 3)
        let finite = try calendarSpec("every day for 5 occurrences")
        XCTAssertEqual(finite.schedule?.dates(after: TaskPlanning.instant("2026-10-26T08:00:00Z")!).count, 2)
        XCTAssertEqual(finite.schedule?.summary, "Every day · 5 occurrences total")
        XCTAssertEqual(finite.label, "Every day · 5 occurrences total · 09:00")
        XCTAssertTrue(try XCTUnwrap(finite.schedule).dates(after: TaskPlanning.instant("2026-10-29T00:00:00Z")!).isEmpty)
    }
    func testMalformedCalendarRowsFailClosedAndKnownExtensionFieldsAreSemanticNeutral() throws {
        let spec = try calendarSpec(); let event = try XCTUnwrap(DueReminder.events(tasks: [task(specs: [spec])], now: now).first)
        for (key, value) in [("version", JSON.number(1)), ("time", .string("25:60")), ("time", .string("9:00")), ("time_zone", .string("missing")), ("time_zone", .string("GMT+0200")), ("start_day", .string("2026-02-30")), ("channels", .array([.string("push")])), ("channels", .array([.string("local"), .string("push")]))] {
            var raw = spec.raw; raw[key] = value; XCTAssertNil(ReminderSpec(row: .object(raw)), key)
        }
        for (key, value) in [("count", JSON.number(1000)), ("fromCompletion", .bool(true)), ("interval", .number(0))] {
            var raw = spec.raw, pattern = raw["recurrence"]!.object; pattern[key] = value; raw["recurrence"] = .object(pattern)
            XCTAssertNil(ReminderSpec(row: .object(raw)), key)
        }
        var extended = spec; extended.raw["future"] = .string("preserve")
        var pattern = extended.raw["recurrence"]!.object; pattern["future"] = .string("preserve rule"); extended.raw["recurrence"] = .object(pattern)
        XCTAssertEqual(ReminderSignature.make(task: task(specs: [spec]), spec: extended, date: event.date), event.signature)
        var row = task(specs: [spec]); XCTAssertFalse(ReminderSpec.append(extended, task: &row))
        var disabled = extended; disabled.raw["id"] = .string(UUID().uuidString); disabled.raw["enabled"] = .bool(false)
        XCTAssertTrue(ReminderSpec.append(disabled, task: &row))
    }
    func testEditingCalendarRulePreservesExtensionsWithoutRetainingPreviousKnownLimits() throws {
        var previous = try calendarSpec("every week until 2027-01-01 for 5 occurrences")
        previous.raw["future"] = .string("row extension")
        var pattern = previous.raw["recurrence"]!.object; pattern["future"] = .string("rule extension"); previous.raw["recurrence"] = .object(pattern)
        let replacement = ReminderSpec.recurring(try XCTUnwrap(ReminderCalendarSchedule.make("every month on last friday", time: "02:30", start: "2026-10-24", zone: "Europe/Copenhagen")), id: previous.id)
        let edited = previous.mergingSettings(from: replacement)
        XCTAssertNotNil(ReminderSpec(row: .object(edited.raw)))
        XCTAssertEqual(edited.raw["future"], .string("row extension")); XCTAssertEqual(edited.raw["recurrence"]?.object["future"], .string("rule extension"))
        XCTAssertNil(edited.raw["recurrence"]?.object["count"]); XCTAssertNil(edited.raw["recurrence"]?.object["endDate"]); XCTAssertNil(edited.raw["recurrence"]?.object["daysOfWeek"])
        XCTAssertEqual(edited.schedule?.time, "02:30")
        var invalid = replacement.raw, rule = invalid["recurrence"]!.object; rule["type"] = .string("daily"); invalid["recurrence"] = .object(rule)
        XCTAssertNil(ReminderSpec(row: .object(invalid)), "A daily rule cannot silently ignore a monthly ordinal")
        invalid = previous.raw; rule = invalid["recurrence"]!.object; rule["daysOfWeek"] = .array([.number(6)]); rule["type"] = .string("daily"); invalid["recurrence"] = .object(rule)
        XCTAssertNil(ReminderSpec(row: .object(invalid)), "A daily rule cannot silently ignore selected weekly days")
    }
    func testCalendarReceiptReconstructsHistoricalOccurrenceAndRejectsChanges() throws {
        let spec = try calendarSpec(); var row = task(specs: [spec])
        let event = try XCTUnwrap(DueReminder.events(tasks: [row], now: now).first)
        func validate(_ row: Record, date: Date? = nil, signature: String? = nil) -> DueReminder? {
            DueReminder.validated(tasks: [row], taskID: row.id, specID: spec.id, signature: signature ?? event.signature, originalAt: date ?? event.date, calendar: calendar)
        }
        XCTAssertNotNil(validate(row))
        XCTAssertNil(DueReminder.validated(tasks: [row], taskID: row.id, specID: spec.id, signature: event.signature, originalAt: nil))
        XCTAssertNil(validate(row, date: event.date.addingTimeInterval(1)))
        XCTAssertNil(validate(row, date: Date(timeIntervalSince1970: .nan)))
        row["title"] = .string("Renamed"); row["due_date"] = .string("2028-01-01"); XCTAssertEqual(validate(row)?.title, "Renamed")
        row["completion_version"] = .number(2); XCTAssertNil(validate(row))
        row["completion_version"] = .number(0); row["task_generation"] = .string(UUID().uuidString); XCTAssertNil(validate(row))
        row["task_generation"] = .null; row["reminder_specs"] = .array([]); XCTAssertNil(validate(row))
        var edited = spec; edited.raw["time"] = .string("10:00"); row["reminder_specs"] = .array([.object(edited.raw)]); XCTAssertNil(validate(row))
    }
    func testCalendarNotificationRoundTripRetainsOccurrenceIdentityAndSourceFields() throws {
        let spec = try calendarSpec(); let events = DueReminder.events(tasks: [task(specs: [spec])], now: now)
        let request = ReminderRequest.make(account: "account", event: events[1], fireAt: events[1].date.addingTimeInterval(3600), snoozed: true)
        let native = UNNotificationRequest(identifier: request.identifier, content: SystemReminderCenter.content(for: request), trigger: SystemReminderCenter.trigger(at: request.fireAt))
        XCTAssertEqual(SystemReminderCenter.decode(native), request)
        XCTAssertNotEqual(request.identifier, ReminderRequest.make(account: "other", event: events[1], snoozed: true).identifier)
        XCTAssertTrue(request.event.signature.hasPrefix("r5:"))
    }
    func testHistoricalCalendarSnoozeSurvivesRefreshButCompletionAndAccountChangeCancel() async throws {
        let spec = try calendarSpec(); var row = task(specs: [spec]); let event = try XCTUnwrap(DueReminder.events(tasks: [row], now: now).first)
        let later = TaskPlanning.instant("2026-11-15T00:00:00Z")!
        let center = TestReminderCenter(), scheduler = ReminderScheduler(center: center)
        await center.deliver(ReminderRequest.make(account: "account", event: event))
        func current(_ revision: Int, account: String = "account") -> ReminderState {
            ReminderState(revision: revision, account: account, events: DueReminder.events(tasks: [row], now: later), now: later, validationTasks: [row], calendar: calendar)
        }
        _ = await scheduler.update(current(1))
        let delivered = await center.delivered; XCTAssertEqual(delivered.count, 1)
        let report = await scheduler.snooze(account: "account", taskID: event.taskID, specID: event.specID, signature: event.signature, now: later, originalAt: event.date)
        XCTAssertNotNil(report)
        _ = await scheduler.update(current(2)); let pending = await center.requests
        XCTAssertEqual(pending.filter(\.snoozed).count, 1); XCTAssertEqual(pending.first(where: \.snoozed)?.event.date, event.date)
        row["completed"] = .bool(true); _ = await scheduler.update(current(3)); let cleared = await center.requests, clearedDelivered = await center.delivered
        XCTAssertTrue(cleared.isEmpty); XCTAssertTrue(clearedDelivered.isEmpty)
        row["completed"] = .bool(false); _ = await scheduler.update(current(4)); _ = await scheduler.update(current(5, account: "other"))
        let switched = await center.requests; XCTAssertTrue(switched.allSatisfy { $0.account == "other" && !$0.snoozed })
    }
    func testIndependentScheduleQuickEntryDeclineProtectionAndAutocomplete() throws {
        let parsed = QuickEntry("Review !every sat 9am p2 ~25m", now: now, calendar: calendar)
        XCTAssertEqual(parsed.title, "Review"); XCTAssertNil(parsed.updates["due_date"]); XCTAssertNil(parsed.updates["due_time"]); XCTAssertNil(parsed.updates["is_recurring"])
        XCTAssertEqual(parsed.updates["priority"], .number(2)); XCTAssertEqual(parsed.updates["duration_minutes"], .number(25))
        let raw = try XCTUnwrap(parsed.updates["reminder_specs"]?.list.last), spec = try XCTUnwrap(ReminderSpec(row: raw))
        XCTAssertEqual(spec.schedule?.startDay, "2026-10-24"); XCTAssertEqual(spec.schedule?.time, "09:00")
        let token = try XCTUnwrap(parsed.tokens.first { $0.group.hasPrefix("reminder_specs:") })
        let declined = QuickEntry("Review !every sat 9am p2 ~25m", now: now, calendar: calendar, disabled: [token.group])
        XCTAssertEqual(declined.title, "Review !every sat 9am"); XCTAssertNil(declined.updates["reminder_specs"]); XCTAssertNil(declined.updates["due_date"])
        let completion = QuickPlanningCompletion("Review !every sat", now: now, calendar: calendar)
        let option = try XCTUnwrap(completion.options.first { $0.reference == "!every saturday 9am" })
        let chosen = try XCTUnwrap(completion.choosing(option, in: "Review !every sat"))
        XCTAssertEqual(QuickEntry(chosen.text, now: now, calendar: calendar).title, "Review")
        let finite = QuickEntry("Review !every day at 9am until 2026-10-27 for 3 occurrences", now: now, calendar: calendar)
        XCTAssertEqual(finite.title, "Review"); XCTAssertEqual(ReminderSpec(row: try XCTUnwrap(finite.updates["reminder_specs"]?.list.last))?.schedule?.dates(after: now).count, 3)
        for text in ["!every sat", "!every! sat 9am", "!every 2 hours", "!every day 25:60", "!every day 9am 10am"] {
            let value = QuickEntry("Review " + text, now: now, calendar: calendar); XCTAssertEqual(value.title, "Review " + text); XCTAssertNil(value.updates["due_date"]); XCTAssertNil(value.updates["reminder_specs"])
        }
    }
    func testIndependentScheduleSurvivesOwnBackupRestoreQueueAndTaskRecurrence() throws {
        let spec = try calendarSpec("every week until 2027-01-01 for 5 occurrences")
        let fixture = BackupTests(); var snapshot = fixture.fixture(), row = snapshot.tables["tasks"]![0]
        row["reminder_specs"] = .array([.object(spec.raw)]); snapshot.tables["tasks"] = [row]
        snapshot.pending = [Mutation(table: "tasks", recordID: row.id, method: "PATCH", fields: ["reminder_specs": row["reminder_specs"]])]
        let roundTrip = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot)); XCTAssertEqual(roundTrip.pending.first?.fields["reminder_specs"], row["reminder_specs"])
        let backup = try WorkspaceBackup.read(WorkspaceBackup.make(snapshot, account: fixture.owner).data())
        let plan = try backup.plan(current: Snapshot(), account: fixture.other)
        let restored = try XCTUnwrap(plan.changes.first { $0.table == "tasks" })
        XCTAssertEqual(restored.fields["reminder_specs"], row["reminder_specs"])
        row["is_recurring"] = .bool(true); row["recurrence_pattern"] = .object(["type": .string("daily")])
        XCTAssertEqual(ReminderSpec.rows(TaskPlanning.nextOccurrence(row, date: now)), ReminderSpec.rows(row))
    }
}


extension ReminderTests {
    func testIndependentCalendarUsesProlepticCivilDaysAndSkipsAbsentDaysWithoutLosingCount() throws {
        let julianOnly = ReminderCalendarSchedule.make("every day", time: "09:00", start: "1500-02-29", zone: "Etc/UTC")
        XCTAssertNil(julianOnly, "Persisted Gregorian dates must not adopt Foundation’s historical Julian cutover")
        let cutover = try calendarSpec("every day for 3 occurrences", start: "1582-10-04", zone: "Etc/UTC")
        XCTAssertEqual(cutover.schedule?.dates(after: Date(timeIntervalSince1970: -12220329600)).map(\.timeIntervalSince1970), [-12220210800, -12220124400, -12220038000])
        let skipped = try calendarSpec("every day for 3 occurrences", start: "2011-12-29", zone: "Pacific/Apia")
        let schedule = try XCTUnwrap(skipped.schedule)
        XCTAssertEqual(schedule.dates(after: TaskPlanning.instant("2011-12-28T00:00:00Z")!).map { TaskPlanner.dayKey($0, calendar: schedule.calendar) }, ["2011-12-29", "2011-12-31", "2012-01-01"])
        let weekly = try calendarSpec("every saturday for 3 occurrences", start: "2011-12-24", zone: "Pacific/Apia")
        let w = try XCTUnwrap(weekly.schedule)
        XCTAssertEqual(w.dates(after: TaskPlanning.instant("2011-12-23T00:00:00Z")!).map { TaskPlanner.dayKey($0, calendar: w.calendar) }, ["2011-12-24", "2011-12-31", "2012-01-07"])
        let interval = try calendarSpec("every 2 days for 3 occurrences", start: "2011-12-29", zone: "Pacific/Apia")
        XCTAssertEqual(interval.schedule?.dates(after: TaskPlanning.instant("2011-12-28T00:00:00Z")!).map { TaskPlanner.dayKey($0, calendar: schedule.calendar) }, ["2011-12-29", "2011-12-31", "2012-01-02"])
    }
}

extension ReminderTests {
    func testSharedCalendarWorkerVectorsMatchNativeOccurrencesAndSignatures() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "reminder-calendar-events", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: url))
        for item in fixture.object["cases"]?.list ?? [] {
            let c = item.object, name = c["name"]?.text ?? ""
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: c["zone"]?.text ?? ""))
            let from = Double(try XCTUnwrap(c["from"]).integer), until = Double(try XCTUnwrap(c["until"]).integer)
            let task = Record(c["task"]?.object ?? [:]), expected = c["events"]?.list ?? []
            let actual = DueReminder.events(tasks: [task], calendar: calendar, channels: ["local", "push"], now: Date(timeIntervalSince1970: from - 0.001)).filter { $0.date.timeIntervalSince1970 >= from && $0.date.timeIntervalSince1970 <= until }
            XCTAssertEqual(actual.count, expected.count, name)
            for (event, row) in zip(actual, expected) {
                XCTAssertEqual(event.specID, row.object["spec"]?.text, name)
                XCTAssertEqual(event.date.timeIntervalSince1970, Double(try XCTUnwrap(row.object["epoch"]).integer), accuracy: 0.0001, name)
                XCTAssertEqual(event.signature, row.object["signature"]?.text, name)
            }
        }
    }
}


extension ReminderTests {
    func testSnoozeDelayFramesActionsAndFuturePreservation() throws {
        for value in [1, 5, 15, 30, 60, 120, 240, 1440] {
            let document = try XCTUnwrap(ReminderSnooze.changing(.null, minutes: value))
            XCTAssertEqual(ReminderSnooze.minutes(document), value)
            XCTAssertEqual(ReminderSnooze.minutes(action: try XCTUnwrap(ReminderSnooze.action(minutes: value))), value)
        }
        XCTAssertEqual(ReminderSnooze.minutes(action: "taskfold.snooze.hour"), 60)
        for action in ["taskfold.snooze.minutes.0", "taskfold.snooze.minutes.1441", "taskfold.snooze.minutes.015", "taskfold.snooze.minutes.+15", "taskfold.snooze.minutes.15.0", "taskfold.snooze.minutes.15 ", "taskfold.snooze.hour.extra", "taskfold.complete"] { XCTAssertNil(ReminderSnooze.minutes(action: action), action) }
        for value in [-1, 0, 1441, Int.max] { XCTAssertNil(ReminderSnooze.changing(.null, minutes: value)) }
        for field in [JSON.bool(true), .string("15"), .number(15.5), .number(.nan), .null] {
            XCTAssertFalse(ReminderSnooze.validDocument(.object(["version": .number(1), "snooze_minutes": field])))
        }
        let supported: JSON = .object(["version": .number(1), "snooze_minutes": .number(15), "extension": .object(["marker": .string("retained")])])
        let changed = try XCTUnwrap(ReminderSnooze.changing(supported, minutes: 30))
        XCTAssertEqual(changed.object["extension"], supported.object["extension"])
        let future: JSON = .object(["version": .number(2), "future": .object(["delay": .string("opaque")])])
        XCTAssertTrue(ReminderSnooze.validDocument(future)); XCTAssertNil(ReminderSnooze.minutes(future)); XCTAssertNil(ReminderSnooze.changing(future, minutes: 30))
    }
    func testServerSizedSnoozeMetadataRemainsBackupReadable() throws {
        let frame = JSON.object(["version": .number(2), "extension": .string(String(repeating: "/", count: 5000))])
        XCTAssertTrue(ReminderSnooze.validDocument(frame))
        XCTAssertNil(ReminderSnooze.minutes(frame))
        XCTAssertNil(ReminderSnooze.changing(frame, minutes: 15))
        XCTAssertFalse(ReminderSnooze.validDocument(.object(["version": .number(2), "extension": .string(String(repeating: "a", count: 8192))])))
    }
    func testSnoozeAccountRowDoesNotReadAnotherOwner() {
        let row = Record(["id": .string("current"), "user_id": .string("owner"), "settings": .object(["version": .number(1), "snooze_minutes": .number(15)])])
        XCTAssertEqual(ReminderSnooze.row([row], account: "OWNER"), row)
        XCTAssertNil(ReminderSnooze.row([row], account: "other")); XCTAssertNil(ReminderSnooze.row([row], account: ""))
        var foreignID = row; foreignID["id"] = .string("other")
        XCTAssertNil(ReminderSnooze.row([foreignID], account: "owner"))
    }
    func testCustomSnoozeExactElapsedDelayAndRestartKeepsChosenInstant() async throws {
        for minutes in [5, 15, 30, 120, 1440] {
            let center = TestReminderCenter(), scheduler = ReminderScheduler(center: center)
            let row = task(); _ = await scheduler.update(state(1, tasks: [row]))
            let event = try XCTUnwrap(DueReminder.events(tasks: [row], calendar: calendar).first)
            let report = await scheduler.snooze(account: "account", taskID: event.taskID, specID: event.specID, signature: event.signature, minutes: minutes, now: now)
            XCTAssertEqual(report?.failures, 0)
            let pending = await center.requests
            let chosen = try XCTUnwrap(pending.first { $0.snoozed })
            XCTAssertEqual(chosen.fireAt, now.addingTimeInterval(Double(minutes) * 60))
            // A new actor reads the persisted OS request; a preference change does not retime it.
            let relaunched = ReminderScheduler(center: center)
            _ = await relaunched.update(state(2, tasks: [row]))
            let retained = await center.requests
            XCTAssertEqual(retained.first { $0.snoozed }?.fireAt, chosen.fireAt)
            XCTAssertEqual(retained.filter(\.snoozed).count, 1)
        }
    }
    func testInvalidSnoozeDelayDoesNotTouchValidPendingRequests() async throws {
        let center = TestReminderCenter(), scheduler = ReminderScheduler(center: center)
        let row = task(); _ = await scheduler.update(state(1, tasks: [row]))
        let event = try XCTUnwrap(DueReminder.events(tasks: [row], calendar: calendar).first)
        let before = await center.requests
        for minutes in [0, -1, 1441, Int.max] {
            let rejected = await scheduler.snooze(account: "account", taskID: event.taskID, specID: event.specID, signature: event.signature, minutes: minutes, now: now)
            XCTAssertNil(rejected)
        }
        let invalidClock = await scheduler.snooze(account: "account", taskID: event.taskID, specID: event.specID, signature: event.signature, minutes: 15, now: Date(timeIntervalSince1970: .nan))
        XCTAssertNil(invalidClock)
        let after = await center.requests; XCTAssertEqual(after, before)
    }
}

extension ReminderTests {
    func testAutomaticFramesPreserveSnoozeMetadataAndFutureDocuments() throws {
        let old: JSON = .object(["version": .number(1), "snooze_minutes": .number(5), "extension": .object(["keep": .bool(true)])])
        XCTAssertEqual(ReminderAutomatic.minutes(old), 0)
        for value in [-1, 0, 1, 15, 1440, 10080] {
            let changed = try XCTUnwrap(ReminderAutomatic.changing(old, minutes: value))
            XCTAssertEqual(ReminderAutomatic.minutes(changed), value)
            XCTAssertEqual(ReminderSnooze.minutes(changed), 5)
            XCTAssertEqual(changed.object["extension"], old.object["extension"])
            XCTAssertEqual(ReminderAutomatic.minutes(try XCTUnwrap(ReminderSnooze.changing(changed, minutes: 30))), value)
        }
        for value in [-2, 10081, Int.max] { XCTAssertNil(ReminderAutomatic.changing(old, minutes: value)) }
        for value in [JSON.null, .bool(true), .string("15"), .number(15.5), .number(-2), .number(10081)] {
            var raw = old.object; raw[ReminderAutomatic.field] = value
            XCTAssertFalse(ReminderSnooze.validDocument(.object(raw)))
            XCTAssertNil(ReminderAutomatic.changing(.object(raw), minutes: 0))
        }
        let future: JSON = .object(["version": .number(2), ReminderAutomatic.field: .string("opaque")])
        XCTAssertTrue(ReminderSnooze.validDocument(future)); XCTAssertNil(ReminderAutomatic.minutes(future))
        XCTAssertNil(ReminderAutomatic.changing(future, minutes: 0))
    }
    func testAutomaticFirstTimedPlanStoresOrdinaryOffsetAndKeepsItAfterMove() throws {
        var previous = task(); previous["due_time"] = .null
        let captured = ReminderAutomatic.applying(to: task(), previous: previous, minutes: 15, calendar: calendar)
        let spec = try XCTUnwrap(ReminderSpec.rows(captured).first.flatMap(ReminderSpec.init(row:)))
        XCTAssertEqual(spec.id, ReminderAutomatic.specID); XCTAssertEqual(spec.offset, -15)
        XCTAssertEqual(spec.raw["version"], .number(1))
        let event = try XCTUnwrap(DueReminder.events(tasks: [captured], calendar: calendar).first)
        XCTAssertEqual(event.date.timeIntervalSince(try XCTUnwrap(TaskPlanning.start(captured, calendar: calendar))), -900)
        var moved = captured; moved["due_time"] = .string("10:00")
        let retained = ReminderAutomatic.applying(to: moved, previous: captured, minutes: 30, calendar: calendar)
        XCTAssertEqual(retained["reminder_specs"], captured["reminder_specs"])
        XCTAssertEqual(DueReminder.events(tasks: [retained], calendar: calendar).first!.date.timeIntervalSince(event.date), 3600)
        XCTAssertEqual(ReminderAutomatic.applying(to: task(), previous: task(), minutes: 15, calendar: calendar), task())
        XCTAssertEqual(ReminderAutomatic.applying(to: previous, previous: nil, minutes: 15, calendar: calendar), previous)
        XCTAssertEqual(DueReminder.events(tasks: [previous], calendar: calendar).first!.date, TaskPlanning.wallTime(day: previous.due!, hour: 8, minute: 0, calendar: calendar))
    }
    func testAutomaticOffAtTimeAndCustomPlannedChoiceRemainExplicit() throws {
        let off = ReminderAutomatic.applying(to: task(), previous: nil, minutes: -1, calendar: calendar)
        XCTAssertFalse(ReminderSpec.plannedEnabled(off)); XCTAssertTrue(DueReminder.events(tasks: [off], calendar: calendar).isEmpty)
        XCTAssertEqual(ReminderAutomatic.applying(to: off, previous: nil, minutes: 15, calendar: calendar), off)
        let on = ReminderAutomatic.applying(to: task(), previous: nil, minutes: 0, calendar: calendar)
        XCTAssertTrue(ReminderSpec.plannedEnabled(on)); XCTAssertEqual(DueReminder.events(tasks: [on], calendar: calendar).count, 1)
        for enabled in [true, false] {
            var chosen = task(); XCTAssertTrue(ReminderSpec.setPlanned(enabled, task: &chosen))
            XCTAssertEqual(ReminderAutomatic.applying(to: chosen, previous: nil, minutes: 15, calendar: calendar), chosen)
        }
    }
    func testAutomaticReplacesOnlyRecognizedPlaceholderAndDoesNotDuplicateCustom() throws {
        var manual = task(); XCTAssertTrue(ReminderSpec.append(.relative(-30), task: &manual))
        manual.fields["reminder_specs"] = .array(ReminderSpec.rows(manual).enumerated().map { index, row in
            var fields = row.object; if index == 0 { fields["extra"] = .string("keep") }; return .object(fields)
        })
        let captured = ReminderAutomatic.applying(to: manual, previous: nil, minutes: 15, calendar: calendar)
        let specs = ReminderSpec.rows(captured).compactMap(ReminderSpec.init(row:))
        XCTAssertEqual(Set(specs.compactMap(\.offset)), [-15, -30]); XCTAssertEqual(specs.count, 2)
        XCTAssertEqual(specs.first { $0.id == ReminderAutomatic.specID }?.raw["extra"], .string("keep"))
        XCTAssertFalse(ReminderSpec.rows(captured).contains { $0.object[ReminderAutomatic.placeholder] != nil })
        let duplicate = ReminderAutomatic.applying(to: manual, previous: nil, minutes: 30, calendar: calendar)
        XCTAssertEqual(ReminderSpec.rows(duplicate).count, 1); XCTAssertEqual(ReminderSpec.rows(duplicate).first, ReminderSpec.rows(manual).last)
        var explicit = manual; XCTAssertTrue(ReminderSpec.setPlanned(true, task: &explicit))
        XCTAssertEqual(ReminderAutomatic.applying(to: explicit, previous: nil, minutes: 15, calendar: calendar), explicit)
        var future = task(); future["reminder_specs"] = .array([.object(["version": .number(99), "extra": .string("opaque")])])
        XCTAssertEqual(ReminderAutomatic.applying(to: future, previous: nil, minutes: 15, calendar: calendar), future)
    }
    func testAutomaticQuickTokensAndCapacityPreserveManualRows() throws {
        let parsed = QuickEntry("Prepare tomorrow at 9am !30mb", now: now, calendar: calendar, task: task())
        let captured = ReminderAutomatic.applying(to: parsed.applying(to: task()), previous: nil, minutes: 15, calendar: calendar)
        XCTAssertEqual(Set(ReminderSpec.rows(captured).compactMap(ReminderSpec.init(row:)).compactMap(\.offset)), [-15, -30])
        var full = task(); full["reminder_specs"] = .array([ReminderAutomatic.legacyPlaceholder] + (1..<20).map { .object(ReminderSpec.relative(-$0).raw) })
        let replaced = ReminderAutomatic.applying(to: full, previous: nil, minutes: 60, calendar: calendar)
        XCTAssertEqual(ReminderSpec.rows(replaced).count, 20)
        XCTAssertEqual(Array(ReminderSpec.rows(replaced).prefix(19)), Array(ReminderSpec.rows(full).dropFirst()))
        XCTAssertEqual(ReminderSpec.successorRows(ReminderSpec.rows(replaced)), ReminderSpec.rows(replaced))
    }
    func testAutomaticSemanticQueueReplaysOnlyItsFieldAgainstLatestMetadata() throws {
        let owner = "owner"
        let initial = Record(["id": .string("current"), "user_id": .string(owner), "settings": .object(["version": .number(1), "snooze_minutes": .number(5), ReminderAutomatic.field: .number(15), "extension": .string("old")])])
        let auto = Mutation(table: ReminderSnooze.table, recordID: "current", method: "POST", fields: initial.fields, reminderPreferenceField: ReminderAutomatic.field)
        var snooze = auto; snooze.id = UUID(); snooze.reminderPreferenceField = nil
        snooze.fields["settings"] = ReminderSnooze.changing(initial["settings"], minutes: 30)
        var latest = initial; latest["settings"] = .object(["version": .number(1), "snooze_minutes": .number(60), ReminderAutomatic.field: .number(120), "extension": .string("new")])
        var snapshot = Snapshot(); snapshot.tables[ReminderSnooze.table] = [initial]; snapshot.pending = [auto, snooze]
        snapshot.mergeRemote([ReminderSnooze.table: [latest]])
        let settings = try XCTUnwrap(snapshot.tables[ReminderSnooze.table]?.first?["settings"])
        XCTAssertEqual(ReminderAutomatic.minutes(settings), 15); XCTAssertEqual(ReminderSnooze.minutes(settings), 30)
        XCTAssertEqual(settings.object["extension"], .string("new"))
        snapshot.acknowledge(auto, saved: latest)
        XCTAssertEqual(ReminderAutomatic.minutes(snapshot.tables[ReminderSnooze.table]!.first!["settings"]), 120)
        XCTAssertEqual(ReminderSnooze.minutes(snapshot.tables[ReminderSnooze.table]!.first!["settings"]), 30)
        let reopened = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(reopened, snapshot)
        latest["settings"] = .object(["version": .number(2), "future": .string("keep")])
        snapshot.mergeRemote([ReminderSnooze.table: [latest]])
        XCTAssertEqual(snapshot.tables[ReminderSnooze.table], [latest]); XCTAssertEqual(snapshot.pending.count, 1)
        var restore = auto; restore.insertOnly = true
        snapshot.apply(restore); XCTAssertEqual(snapshot.tables[ReminderSnooze.table], [latest])
    }
}

extension ReminderTests {
    func testLegacyClockRemovalKeepsItsExistingChoiceAcrossNewDefault() throws {
        let original = task()
        var undated = original; undated["due_time"] = .null
        let frozen = ReminderAutomatic.applying(to: undated, previous: original, minutes: 15, calendar: calendar)
        XCTAssertEqual(ReminderSpec.rows(frozen).compactMap(ReminderSpec.init(row:)).map(\.offset), [0])
        var timedAgain = frozen; timedAgain["due_time"] = .string("10:00")
        XCTAssertEqual(ReminderAutomatic.applying(to: timedAgain, previous: frozen, minutes: 30, calendar: calendar), timedAgain)
        var manual = original; XCTAssertTrue(ReminderSpec.append(.relative(-30), task: &manual))
        let saved = ReminderAutomatic.applying(to: manual, previous: original, minutes: 15, calendar: calendar)
        XCTAssertEqual(Set(ReminderSpec.rows(saved).compactMap(ReminderSpec.init(row:)).compactMap(\.offset)), [0, -30])
        XCTAssertFalse(ReminderSpec.rows(saved).contains { $0.object[ReminderAutomatic.placeholder] != nil })
    }
}
