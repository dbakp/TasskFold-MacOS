import XCTest
@testable import TaskfoldCore

private actor IntervalReminderCenter: ReminderCenter {
    var requests: [ReminderRequest] = []
    var failNext = false
    func pending() async -> [ReminderRequest] { requests }
    func removeInvalid(_ state: ReminderState) async { requests.removeAll { !$0.valid(state: state) } }
    func remove(_ identifiers: [String]) async { requests.removeAll { identifiers.contains($0.identifier) } }
    func add(_ request: ReminderRequest) async throws {
        if failNext { failNext = false; throw NSError(domain: "isolated-reminder", code: 1) }
        requests.removeAll { $0.identifier == request.identifier }; requests.append(request)
    }
    func failOnce() { failNext = true }
}

final class IntervalReminderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func spec(minutes: Int = 30, count: Int? = 5) throws -> ReminderSpec {
        .interval(try XCTUnwrap(ReminderIntervalSchedule(start: now.addingTimeInterval(60), everyMinutes: minutes, count: count)))
    }
    private func task(_ spec: ReminderSpec) -> Record {
        Record(["id": .string("10000000-0000-4000-8000-000000000001"), "title": .string("Interval proof"), "reminder_specs": .array([.object(spec.raw)]), "task_generation": .string("10000000-0000-4000-8000-000000000002"), "completion_version": .number(0)])
    }
    func testVersionedSpecRoundTripsWithOptionalLimitsAndExtensions() throws {
        var original = try spec(); original.raw["future"] = .bool(true)
        let json = try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(JSON.object(original.raw)))
        XCTAssertEqual(ReminderSpec(row: json), original)
        XCTAssertEqual(original.intervalSchedule?.dates(after: now).count, 5)
        XCTAssertEqual(original.label, "Every 30 minutes · 5 alerts total")
        let unlimited = try spec(count: nil)
        XCTAssertEqual(unlimited.intervalSchedule?.dates(after: now).count, 60)
    }
    func testRejectsMalformedKnownSettingsAndOtherDeliveryChannels() throws {
        let original = try spec()
        for (key, value) in [("version", JSON.number(2)), ("channels", .array([.string("push")])), ("channels", .array([.string("local"), .string("push")])), ("id", .string(ReminderSpec.plannedID)), ("enabled", .string("true")), ("interval_schedule", .array([]))] {
            var raw = original.raw; raw[key] = value; XCTAssertNil(ReminderSpec(row: .object(raw)), key)
        }
        for (key, value) in [("start_ms", JSON.string("1800000000000")), ("every_minutes", .number(4)), ("every_minutes", .number(5.5)), ("count", .number(0)), ("until_ms", .number(0))] {
            var raw = original.raw, payload = raw["interval_schedule"]!.object; payload[key] = value; raw["interval_schedule"] = .object(payload)
            XCTAssertNil(ReminderSpec(row: .object(raw)), key)
        }
    }
    func testOnlyIntervalsShareSemanticDuplicateIdentity() throws {
        let a = try spec(), b = ReminderSpec.interval(try XCTUnwrap(a.intervalSchedule))
        XCTAssertNotEqual(a.id, b.id); XCTAssertTrue(ReminderSpec.duplicates(b, in: [.object(a.raw)]))
        XCTAssertFalse(ReminderSpec.duplicates(try spec(minutes: 15), in: [.object(a.raw)]))
        XCTAssertFalse(ReminderSpec.duplicates(try spec(count: 4), in: [.object(a.raw)]))
        var extended = a; extended.raw["display_zone"] = .string("Asia/Tokyo")
        XCTAssertEqual(a.semanticKey, extended.semanticKey)
    }
    func testChangingLimitsClearsKnownFieldsAndPreservesUnknownExtensions() throws {
        var a = try spec(), payload = a.raw["interval_schedule"]!.object
        payload["future"] = .string("retain"); a.raw["interval_schedule"] = .object(payload); a.raw["outer"] = .number(9)
        let b = ReminderSpec.interval(try XCTUnwrap(ReminderIntervalSchedule(start: now, everyMinutes: 15)), id: a.id)
        let merged = a.mergingSettings(from: b)
        XCTAssertNotNil(ReminderSpec(row: .object(merged.raw)))
        XCTAssertNil(merged.intervalSchedule?.count); XCTAssertNil(merged.intervalSchedule?.until)
        XCTAssertEqual(merged.raw["interval_schedule"]?.object["future"], .string("retain"))
        XCTAssertEqual(merged.raw["outer"], .number(9))
    }
    func testProjectionIndependentOfPlanWithUniqueOccurrenceRequests() throws {
        let a = try spec(); var row = task(a)
        let events = DueReminder.events(tasks: [row], now: now)
        XCTAssertEqual(events.count, 5); XCTAssertEqual(Set(events.map(\.signature)).count, 5)
        XCTAssertTrue(events.allSatisfy { $0.calendarOccurrence && $0.signature.hasPrefix("r6:") && $0.legacySignature == nil })
        XCTAssertEqual(Set(events.map { ReminderRequest.make(account: "a", event: $0).identifier }).count, 5)
        row["due_date"] = .string("2030-01-01"); row["due_time"] = .string("09:00"); row["time_zone"] = .string("Asia/Tokyo")
        XCTAssertEqual(DueReminder.events(tasks: [row], now: now), events)
        row["completed"] = .bool(true); XCTAssertTrue(DueReminder.events(tasks: [row], now: now).isEmpty)
    }
    func testExactPastCallbackStillValidButEditedLimitAndReincarnationInvalidateIt() throws {
        let a = try spec(); var row = task(a)
        let event = try XCTUnwrap(DueReminder.events(tasks: [row], now: now).first)
        func valid(_ row: Record, at: Date? = nil) -> DueReminder? { DueReminder.validated(tasks: [row], taskID: row.id, specID: a.id, signature: event.signature, originalAt: at ?? event.date) }
        XCTAssertEqual(valid(row), event)
        XCTAssertNil(valid(row, at: event.date.addingTimeInterval(0.001)))
        row["completion_version"] = .number(2); XCTAssertNil(valid(row)); row["completion_version"] = .number(0)
        row["task_generation"] = .string(UUID().uuidString); XCTAssertNil(valid(row)); row = task(a)
        let changed = ReminderSpec.interval(try XCTUnwrap(ReminderIntervalSchedule(start: event.date, everyMinutes: 30, count: 4)), id: a.id)
        row["reminder_specs"] = .array([.object(changed.raw)]); XCTAssertNil(valid(row)); row = task(a)
        row["reminder_specs"] = .array([]); XCTAssertNil(valid(row))
    }
    func testDisabledAndUnknownVersionsDoNotBecomePlannedReminders() throws {
        var a = try spec(); a.raw["enabled"] = .bool(false)
        XCTAssertTrue(DueReminder.events(tasks: [task(a)], now: now).isEmpty)
        a.raw["enabled"] = .bool(true); a.raw["version"] = .number(99)
        XCTAssertTrue(DueReminder.events(tasks: [task(a)], now: now).isEmpty)
        var row = task(a); let original = row["reminder_specs"]
        XCTAssertTrue(ReminderSpec.setPlanned(false, task: &row))
        XCTAssertEqual(row["reminder_specs"].list.first, original.list.first)
    }
    func testRecurringTaskSuccessorKeepsOriginalAnchorAndCountWithoutRestart() throws {
        let a = try spec(); var row = task(a)
        row["is_recurring"] = .bool(true); row["due_date"] = .string("2027-01-01"); row["recurrence_pattern"] = .object(["type": .string("daily")])
        let next = TaskPlanning.nextOccurrence(row, date: now)
        XCTAssertEqual(ReminderSpec.rows(next), [.object(a.raw)])
        XCTAssertEqual(ReminderSpec.rows(next).first.flatMap(ReminderSpec.init(row:))?.intervalSchedule?.start, a.intervalSchedule?.start)
        XCTAssertEqual(ReminderSpec.rows(row), [.object(a.raw)])
        let event = try XCTUnwrap(DueReminder.events(tasks: [row], now: now).first)
        let changes = TaskCompletion.complete(row, tasks: [row], at: now)
        let inserted = try XCTUnwrap(changes.first { $0.method == "POST" })
        var snapshot = Snapshot(); snapshot.tables["tasks"] = [row]
        for change in changes { snapshot.apply(change) }
        let successor = try XCTUnwrap(snapshot.tables["tasks"]?.first { $0.id == inserted.recordID })
        XCTAssertNotEqual(successor.id, row.id); XCTAssertEqual(ReminderSpec.rows(successor), ReminderSpec.rows(row))
        XCTAssertNil(DueReminder.validated(tasks: snapshot.tables["tasks"]!, taskID: row.id, specID: a.id, signature: event.signature, originalAt: event.date))
        XCTAssertNil(DueReminder.validated(tasks: [successor], taskID: successor.id, specID: a.id, signature: event.signature, originalAt: event.date), "Original callback cannot retarget the successor")
    }
    func testSnapshotQueueAndPortableBackupPreserveExactSettings() throws {
        let fixture = BackupTests(); var snapshot = fixture.fixture(), row = snapshot.tables["tasks"]![0]
        row["reminder_specs"] = .array([.object(try spec().raw)]); snapshot.tables["tasks"] = [row]
        snapshot.pending = [Mutation(table: "tasks", recordID: row.id, method: "PATCH", fields: ["reminder_specs": row["reminder_specs"]])]
        let saved = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(saved.pending[0].fields["reminder_specs"], row["reminder_specs"])
        let backup = try WorkspaceBackup.read(WorkspaceBackup.make(saved, account: fixture.owner).data())
        let restored = try backup.plan(current: Snapshot(), account: fixture.other)
        XCTAssertEqual(restored.changes.first { $0.table == "tasks" }?.fields["reminder_specs"], row["reminder_specs"])
    }
    func testIntervalKeepsLocalDeliveryWhileOtherOriginalsFollowRemoteAuthority() throws {
        let row = task(try spec()), events = DueReminder.events(tasks: [row], now: now)
        var state = ReminderState(revision: 1, account: "a", events: events, now: now, validationTasks: [row])
        state.deliveryAuthorityUnreadable = true
        XCTAssertTrue(events.allSatisfy(state.permitsOriginal))
        let ordinary = DueReminder(id: "other", title: "Other", body: "", date: now, taskID: "other", specID: "other", signature: "r4:other")
        XCTAssertFalse(state.permitsOriginal(ordinary))
    }
    func testQueueBudgetRetrySnoozeAndTaskCompletion() async throws {
        let row = task(try spec(count: nil)), center = IntervalReminderCenter(), scheduler = ReminderScheduler(center: center)
        var state = ReminderState(revision: 1, account: "a", events: DueReminder.events(tasks: [row], now: now), now: now, validationTasks: [row])
        await center.failOnce(); _ = await scheduler.update(state)
        let failedCount = await center.pending().count; XCTAssertEqual(failedCount, 59)
        state.revision += 1; _ = await scheduler.update(state)
        let count = await center.pending().count; XCTAssertEqual(count, 60)
        let event = try XCTUnwrap(state.events.first)
        _ = await scheduler.snooze(account: "a", taskID: row.id, specID: event.specID, signature: event.signature, minutes: 5, now: now, originalAt: event.date)
        let snoozes = await center.pending().filter(\.snoozed); XCTAssertEqual(snoozes.count, 1)
        XCTAssertEqual(snoozes.first?.event.date, event.date); XCTAssertEqual(snoozes.first?.fireAt, now.addingTimeInterval(300))
        state.revision += 1; state.account = "b"; state.events = []; state.validationTasks = []; _ = await scheduler.update(state)
        let remaining = await center.pending(); XCTAssertTrue(remaining.isEmpty)
    }
}
