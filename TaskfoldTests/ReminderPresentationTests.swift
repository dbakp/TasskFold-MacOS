import XCTest
import UserNotifications
@testable import TaskfoldCore

private actor PresentationCenter: ReminderCenter {
    var requests: [ReminderRequest] = []
    var additions = 0
    func pending() async -> [ReminderRequest] { requests }
    func removeInvalid(_ state: ReminderState) async { requests.removeAll { !$0.valid(state: state) } }
    func remove(_ ids: [String]) async { requests.removeAll { ids.contains($0.identifier) } }
    func add(_ request: ReminderRequest) async throws { additions += 1; requests.removeAll { $0.identifier == request.identifier }; requests.append(request) }
}
final class ReminderPresentationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func bases() throws -> [ReminderSpec] {
        [.relative(-10), .absolute(now.addingTimeInterval(3600)),
         .recurring(try XCTUnwrap(ReminderCalendarSchedule.make("every day for 3 occurrences", time: "09:00", start: "2027-01-16", zone: "Europe/Copenhagen"))),
         .interval(try XCTUnwrap(ReminderIntervalSchedule(start: now.addingTimeInterval(60), everyMinutes: 30, count: 3)))]
    }
    func task(_ spec: ReminderSpec) -> Record {
        Record(["id": .string("70000000-0000-4000-8000-000000000001"), "task_generation": .string("70000000-0000-4000-8000-000000000002"), "title": .string("Presentation proof"), "due_date": .string("2027-01-16"), "due_time": .string("09:00"), "time_zone": .string("Europe/Copenhagen"), "reminder_specs": .array([.object(spec.raw)])])
    }
    func testAllSchedulesRoundTripAndTurningOffRestoresExactNormalSettings() throws {
        for var base in try bases() {
            base.raw["future"] = .object(["keep": .bool(true)])
            let changed = try XCTUnwrap(base.settingTimeSensitive(true))
            XCTAssertTrue(changed.timeSensitive); XCTAssertEqual(changed.raw["version"], .number(4))
            XCTAssertEqual(changed.raw["schedule_version"], base.raw["version"])
            XCTAssertEqual(ReminderSpec(row: .object(changed.raw)), changed)
            XCTAssertEqual(changed.settingTimeSensitive(false), base)
            XCTAssertEqual(changed.semanticKey, base.semanticKey)
            XCTAssertEqual(changed.date(task: task(base), calendar: .current, now: now), base.date(task: task(base), calendar: .current, now: now))
            let record = task(changed)
            XCTAssertEqual(try JSONDecoder().decode(Record.self, from: JSONEncoder().encode(record)), record)
        }
    }
    func testInvalidWrappersNeverScheduleOrFallback() throws {
        let valid = try XCTUnwrap(bases()[0].settingTimeSensitive(true))
        let edits: [(String, JSON)] = [("presentation", .string("critical")), ("presentation", .null), ("schedule_version", .number(4)), ("schedule_version", .number(2)), ("schedule_version", .string("1")), ("channels", .array([.string("push")])), ("channels", .array([.string("local"), .string("email")])), ("id", .string(ReminderSpec.plannedID)), ("kind", .string("unknown"))]
        for (key, value) in edits {
            var raw = valid.raw; raw[key] = value
            XCTAssertNil(ReminderSpec(row: .object(raw)), key)
            var row = task(valid); row["reminder_specs"] = .array([.object(raw)])
            XCTAssertTrue(DueReminder.events(tasks: [row], now: now).isEmpty, key)
        }
        XCTAssertNil(ReminderSpec.relative(0, id: ReminderSpec.plannedID).settingTimeSensitive(true))
        var nonlocal = ReminderSpec.relative(-10); nonlocal.raw["channels"] = .array([.string("push")])
        XCTAssertNil(nonlocal.settingTimeSensitive(true))
    }
    func testUnknownPresentationOnLegacyVersionDoesNotElevate() throws {
        var base = try bases()[0]; base.raw["presentation"] = .string("time-sensitive")
        XCTAssertFalse(try XCTUnwrap(ReminderSpec(row: .object(base.raw))).timeSensitive)
        XCTAssertTrue(DueReminder.events(tasks: [task(base)], now: now).allSatisfy { !$0.timeSensitive })
    }
    func testSameTimeDuplicateIsRefusedRegardlessOfPresentation() throws {
        let base = try bases()[0], changed = try XCTUnwrap(base.settingTimeSensitive(true))
        let other = try XCTUnwrap(ReminderSpec.relative(-10).settingTimeSensitive(true))
        XCTAssertTrue(ReminderSpec.duplicates(other, in: [.object(base.raw)]))
        XCTAssertTrue(ReminderSpec.duplicates(ReminderSpec.relative(-10), in: [.object(changed.raw)]))
    }
    func testEditedPresentationInvalidatesBothDirectionsAndCannotUseLegacySignature() throws {
        for base in try bases() {
            let changed = try XCTUnwrap(base.settingTimeSensitive(true)), normal = task(base), sensitive = task(changed)
            let event = try XCTUnwrap(DueReminder.events(tasks: [sensitive], now: now).first)
            let old = try XCTUnwrap(DueReminder.events(tasks: [normal], now: now).first)
            XCTAssertTrue(event.signature.hasPrefix("r7:")); XCTAssertNil(event.legacySignature)
            XCTAssertTrue(event.timeSensitive); XCTAssertEqual(event.date, old.date)
            XCTAssertNil(DueReminder.validated(tasks: [normal], taskID: event.taskID, specID: event.specID, signature: event.signature, originalAt: event.date))
            XCTAssertNil(DueReminder.validated(tasks: [sensitive], taskID: old.taskID, specID: old.specID, signature: old.signature, originalAt: old.date))
            XCTAssertEqual(DueReminder.validated(tasks: [sensitive], taskID: event.taskID, specID: event.specID, signature: event.signature, originalAt: event.date), event)
            var legacy = sensitive; legacy.fields.removeValue(forKey: "task_generation")
            XCTAssertNil(try XCTUnwrap(DueReminder.events(tasks: [legacy], now: now).first).legacySignature)
        }
    }
    func testMergeAcrossKindsAndSuccessorPreserveChoiceAndExtensions() throws {
        for base in try bases() {
            var changed = try XCTUnwrap(base.settingTimeSensitive(true)); changed.raw["future"] = .string("keep")
            let replacement = ReminderSpec.relative(-30, id: changed.id)
            let result = try XCTUnwrap(changed.mergingSettings(from: replacement).settingTimeSensitive(true))
            XCTAssertEqual(result.raw["schedule_version"], .number(1)); XCTAssertEqual(result.offset, -30)
            XCTAssertEqual(result.raw["future"], .string("keep")); XCTAssertTrue(result.timeSensitive)
            let successors = ReminderSpec.successorRows([.object(changed.raw)])
            XCTAssertEqual(successors, base.kind == "absolute" ? [.object(ReminderSpec.relative(0, id: ReminderSpec.plannedID, enabled: false).raw)] : [.object(changed.raw)])
        }
    }
    func testDevicePreferencesAreDefaultOffAndAccountIsolated() {
        let name = "presentation-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "remindersEnabled")
        XCTAssertFalse(ReminderPreferences.timeSensitiveEnabled(account: "A", defaults: defaults))
        defaults.set(true, forKey: ReminderPreferences.timeSensitiveKey("A"))
        XCTAssertTrue(ReminderPreferences.timeSensitiveEnabled(account: "a", defaults: defaults))
        XCTAssertFalse(ReminderPreferences.timeSensitiveEnabled(account: "B", defaults: defaults))
        XCTAssertFalse(ReminderPreferences.timeSensitiveEnabled(account: "", defaults: defaults))
    }
    func testNativeContentAndDecodePreserveActualPresentationWithoutCriticalSound() throws {
        let spec = try XCTUnwrap(bases()[1].settingTimeSensitive(true))
        let event = try XCTUnwrap(DueReminder.events(tasks: [task(spec)], now: now).first)
        let request = ReminderRequest.make(account: "a", event: event)
        let content = SystemReminderCenter.content(for: request)
        XCTAssertEqual(content.interruptionLevel, .timeSensitive); XCTAssertNotNil(content.sound)
        XCTAssertEqual(SystemReminderCenter.decode(UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil)), request)
        var normal = request; normal.event.timeSensitive = false
        XCTAssertEqual(SystemReminderCenter.content(for: normal).interruptionLevel, .active)
        XCTAssertEqual(SystemReminderCenter.decode(UNNotificationRequest(identifier: normal.identifier, content: SystemReminderCenter.content(for: normal), trigger: nil)), normal)
        var focus = request; focus.event.kind = .focusFinish
        XCTAssertEqual(SystemReminderCenter.content(for: focus).interruptionLevel, .active)
    }
    func testSchedulerDeviceOptInChangesExistingRequestAndSnoozeWithoutRetargeting() async throws {
        let spec = try XCTUnwrap(bases()[3].settingTimeSensitive(true)), row = task(spec)
        let events = DueReminder.events(tasks: [row], now: now)
        let center = PresentationCenter(), scheduler = ReminderScheduler(center: center)
        var state = ReminderState(revision: 1, account: "a", events: events, now: now, validationTasks: [row])
        _ = await scheduler.update(state)
        let first = await center.pending(); XCTAssertEqual(first.count, 3); XCTAssertTrue(first.allSatisfy { !$0.event.timeSensitive })
        state.revision += 1; state.timeSensitiveAllowed = true; _ = await scheduler.update(state)
        let second = await center.pending(); XCTAssertTrue(second.allSatisfy { $0.event.timeSensitive }); XCTAssertEqual(second.map(\.identifier), first.map(\.identifier))
        let event = try XCTUnwrap(events.first)
        _ = await scheduler.snooze(account: "a", taskID: event.taskID, specID: event.specID, signature: event.signature, minutes: 5, now: now, originalAt: event.date)
        state.revision += 1; state.timeSensitiveAllowed = false; _ = await scheduler.update(state)
        let final = await center.pending(); XCTAssertTrue(final.contains { $0.snoozed }); XCTAssertTrue(final.allSatisfy { !$0.event.timeSensitive })
        XCTAssertTrue(final.allSatisfy { $0.event.signature.hasPrefix("r7:") })
        state.revision += 1; state.account = "b"; state.events = []; state.validationTasks = []; _ = await scheduler.update(state)
        let empty = await center.pending(); XCTAssertTrue(empty.isEmpty)
    }
    func testQueuedChangesAndPortableBackupRetainPresentationWithoutDeviceConsent() throws {
        let fixture = BackupTests(); var snapshot = fixture.fixture(), row = snapshot.tables["tasks"]![0]
        for base in try bases() {
            let spec = try XCTUnwrap(base.settingTimeSensitive(true)); row["reminder_specs"] = .array([.object(spec.raw)]); snapshot.tables["tasks"] = [row]
            snapshot.pending = [Mutation(table: "tasks", recordID: row.id, method: "PATCH", fields: ["reminder_specs": row["reminder_specs"]])]
            let saved = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
            XCTAssertEqual(saved.pending[0].fields["reminder_specs"], row["reminder_specs"])
            let backup = try WorkspaceBackup.read(WorkspaceBackup.make(saved, account: fixture.owner).data())
            let plan = try backup.plan(current: Snapshot(), account: fixture.other)
            XCTAssertEqual(plan.changes.first { $0.table == "tasks" }?.fields["reminder_specs"], row["reminder_specs"])
        }
    }
    func testRecurringTaskCompletionKeepsChoiceWithoutRetargetingOldAlert() throws {
        let spec = try XCTUnwrap(bases()[3].settingTimeSensitive(true)); var row = task(spec)
        row["is_recurring"] = .bool(true); row["recurrence_pattern"] = .object(["type": .string("daily")])
        let event = try XCTUnwrap(DueReminder.events(tasks: [row], now: now).first)
        let changes = TaskCompletion.complete(row, tasks: [row], at: now)
        let inserted = try XCTUnwrap(changes.first { $0.method == "POST" })
        var snapshot = Snapshot(); snapshot.tables["tasks"] = [row]
        for change in changes { snapshot.apply(change) }
        let successor = try XCTUnwrap(snapshot.tables["tasks"]?.first { $0.id == inserted.recordID })
        XCTAssertEqual(ReminderSpec.rows(successor), [.object(spec.raw)])
        XCTAssertNil(DueReminder.validated(tasks: snapshot.tables["tasks"]!, taskID: row.id, specID: spec.id, signature: event.signature, originalAt: event.date))
        XCTAssertNil(DueReminder.validated(tasks: [successor], taskID: successor.id, specID: spec.id, signature: event.signature, originalAt: event.date))
    }
    func testLocalOnlyAuthorityAndCompletionEligibility() throws {
        let spec = try XCTUnwrap(bases()[3].settingTimeSensitive(true)); var row = task(spec)
        let events = DueReminder.events(tasks: [row], now: now)
        let state = ReminderState(revision: 1, account: "a", events: events, now: now, deliveryAuthorityUnreadable: true)
        XCTAssertTrue(events.allSatisfy(state.permitsOriginal))
        row["completed"] = .bool(true); XCTAssertTrue(DueReminder.events(tasks: [row], now: now).isEmpty)
    }
}
