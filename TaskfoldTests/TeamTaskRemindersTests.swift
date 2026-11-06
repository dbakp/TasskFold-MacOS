import XCTest
import CryptoKit
@testable import TaskfoldCore

final class TeamTaskRemindersTests: XCTestCase {
    private let localID = "ec260000-0000-4000-8000-000000000021"
    private var privateRow: JSON { .object(["id": .string("ec260000-0000-4000-8000-000000000023"), "version": .number(77), "kind": .string("location"), "place_label": .string("Private studio"), "latitude_e6": .number(1)]) }
    private var futureRow: JSON { .object(["id": .string("ec260000-0000-4000-8000-000000000022"), "version": .number(99), "future": .array([.string("keep")])]) }
    private func calendar() throws -> ReminderSpec {
        .recurring(try XCTUnwrap(ReminderCalendarSchedule(raw: ["start_day": .string("2030-01-01"), "time": .string("09:00"), "time_zone": .string("UTC"), "recurrence": .object(["type": .string("daily"), "interval": .number(1)])])), id: localID)
    }
    func testPrivateFutureAndOtherChannelRowsRemainExactAndLocked() throws {
        var remote = ReminderSpec.relative(-45).raw; remote["channels"] = .array([.string("email")])
        let source: JSON = .array([.object(ReminderSpec.relative(-5, id: localID).raw), futureRow, privateRow, .object(remote)])
        var draft = TeamTaskRemindersDraft(source); XCTAssertTrue(draft.supported)
        for index in 1...3 { XCTAssertNil(draft.editable(index)); XCTAssertThrowsError(try draft.remove(index)); XCTAssertThrowsError(try draft.save(.relative(-15), replacing: index, opening: draft.rows)) }
        let before = draft.rows
        try draft.save(try XCTUnwrap(ReminderSpec.relative(-5, id: localID).settingTimeSensitive(true)), replacing: 0, opening: before)
        XCTAssertEqual(Array(draft.rows.dropFirst()), Array(before.dropFirst()))
        XCTAssertTrue(try XCTUnwrap(draft.editable(0)).timeSensitive)
    }
    func testLegacyPlannedDefaultMaterializesAndLastRemovalCannotReactivateIt() throws {
        var empty = TeamTaskRemindersDraft(.array([])); XCTAssertTrue(empty.plannedEnabled)
        try empty.save(.relative(-10), replacing: nil, opening: [])
        XCTAssertEqual(empty.rows.count, 2); XCTAssertEqual(empty.editable(0)?.id, ReminderSpec.plannedID)
        try empty.setPlanned(false); XCTAssertFalse(empty.plannedEnabled)
        var one = TeamTaskRemindersDraft(.array([.object(ReminderSpec.relative(-5, id: localID).raw)]))
        try one.remove(0); XCTAssertEqual(one.rows.count, 1); XCTAssertEqual(one.editable(0)?.id, ReminderSpec.plannedID); XCTAssertFalse(one.plannedEnabled)
    }
    func testFutureShapesLimitsAndDuplicateIdentitiesNeverTruncateOrPartiallyChange() throws {
        for source in [JSON.bool(true), .object(["future": .bool(true)]), .array([.string("future")]), .array([.object(["id": .string("invalid")])]), .array([futureRow, futureRow]), .array((0..<21).map { _ in .object(ReminderSpec.relative(-5).raw) })] {
            var draft = TeamTaskRemindersDraft(source); XCTAssertFalse(draft.supported); XCTAssertEqual(draft.value, source)
            XCTAssertThrowsError(try draft.setPlanned(false)); XCTAssertThrowsError(try draft.save(.relative(-10), replacing: nil, opening: [])); XCTAssertEqual(draft.value, source)
        }
        var full = TeamTaskRemindersDraft(.array((0..<20).map { .object(ReminderSpec.relative(-$0-1).raw) }))
        let before = full.value; XCTAssertFalse(full.plannedEditable); XCTAssertThrowsError(try full.save(.relative(-99), replacing: nil, opening: full.rows)); XCTAssertEqual(full.value, before)
        var empty = TeamTaskRemindersDraft(.array([])); XCTAssertThrowsError(try empty.save(.relative(0), replacing: nil, opening: [])); XCTAssertEqual(empty.value, .array([]))
    }
    func testAllPortableSchedulesAndTimeSensitiveHolidayWrappersCanBeReviewed() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let recurring = try calendar()
        let policy = try XCTUnwrap(ReminderHolidayPolicy(raw: ["version": .number(1), "year": .number(2030), "dates": .array([.string("2030-01-01")]), "source": .string("Reviewed dates"), "region": .string("Denmark"), "digest": .string(String(repeating: "a", count: 64)), "mode": .string("skip"), "avoid_weekends": .bool(false)]))
        let holiday = try XCTUnwrap(recurring.settingHolidayPolicy(policy))
        let cases: [ReminderSpec] = [.relative(-30, id: localID), .absolute(now, id: localID, zone: "UTC"), recurring, .interval(try XCTUnwrap(ReminderIntervalSchedule(start: now, everyMinutes: 30, count: 3)), id: localID), holiday, try XCTUnwrap(holiday.settingTimeSensitive(true))]
        for spec in cases {
            var draft = TeamTaskRemindersDraft(.array([.object(ReminderSpec.relative(-5, id: localID).raw)]))
            try draft.save(spec, replacing: 0, opening: draft.rows)
            XCTAssertEqual(draft.editable(0)?.kind, spec.kind); XCTAssertEqual(draft.editable(0)?.timeSensitive, spec.timeSensitive)
        }
    }
    func testExtensionsSurviveRowAndNestedSchedulePolicyKindChanges() throws {
        var raw = try calendar().raw
        raw["future_row"] = .object(["keep": .bool(true)])
        var rule = raw["recurrence"]!.object; rule["future_rule"] = .string("keep"); raw["recurrence"] = .object(rule)
        raw["holiday_policy"] = .object(["future_policy": .string("keep"), "origin": .object(["future_origin": .string("keep")])])
        raw["interval_schedule"] = .object(["future_interval": .array([.number(1)])])
        let old = try XCTUnwrap(ReminderSpec(row: .object(raw)))
        let changed = try TeamTaskRemindersDraft.preservingExtensions(from: old, in: .relative(-15, id: localID))
        XCTAssertEqual(changed.raw["future_row"], raw["future_row"])
        XCTAssertEqual(changed.raw["recurrence"]?.object["future_rule"], .string("keep"))
        XCTAssertEqual(changed.raw["interval_schedule"]?.object["future_interval"], .array([.number(1)]))
        XCTAssertEqual(changed.raw["holiday_policy"]?.object["future_policy"], .string("keep"))
        XCTAssertEqual(changed.raw["holiday_policy"]?.object["origin"]?.object["future_origin"], .string("keep"))
        XCTAssertEqual(changed.offset, -15)
    }
    func testChangedOpeningRowsWrongIdentityAndFabricatedOrNonlocalSpecNeverApply() throws {
        let original: JSON = .array([.object(ReminderSpec.relative(-5, id: localID).raw)])
        var draft = TeamTaskRemindersDraft(original)
        XCTAssertThrowsError(try draft.save(.relative(-15, id: localID), replacing: 0, opening: []))
        XCTAssertThrowsError(try draft.save(.relative(-15), replacing: 0, opening: draft.rows))
        var invalid = ReminderSpec.relative(-15, id: localID); invalid.raw["version"] = .number(99)
        XCTAssertThrowsError(try draft.save(invalid, replacing: 0, opening: draft.rows))
        var email = ReminderSpec.relative(-15, id: localID); email.raw["channels"] = .array([.string("email")])
        XCTAssertThrowsError(try draft.save(email, replacing: 0, opening: draft.rows)); XCTAssertEqual(draft.value, original)
    }
    func testReservedPlannedIdentityCanBeLockedAndCannotBecomeAnAdvancedReminder() throws {
        let source: JSON = .array([.object(["id": .string(ReminderSpec.plannedID), "version": .number(99)])])
        var locked = TeamTaskRemindersDraft(source); XCTAssertFalse(locked.plannedEditable)
        XCTAssertThrowsError(try locked.setPlanned(true)); XCTAssertEqual(locked.value, source)
        var empty = TeamTaskRemindersDraft(.null); XCTAssertFalse(empty.changed)
        XCTAssertThrowsError(try empty.save(.relative(0, id: ReminderSpec.plannedID), replacing: nil, opening: [])); XCTAssertFalse(empty.changed)
    }
}

extension TeamTaskRemindersTests {
    @MainActor func testFailedFirstRecoveryCaptureCannotBeMistakenForNoUnsentEdit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TeamReminderCapture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = "ec260000-0000-4000-8000-000000000001", key = SymmetricKey(size: .bits256)
        let vault = BackupVault(directory: directory, account: account, key: { key })
        let original = Record.task(user: account)
        let session = TaskEditorSession(vault: vault, origin: "https://synthetic.example", original: original, labels: [])
        var draft = original; draft["title"] = .string("Unsent reminder settings")
        // A mismatched task identity fails capture before a recoverable revision exists.
        draft["id"] = .string(UUID().uuidString.lowercased())
        session.capture(draft, extras: ["unsubmitted_reminder_settings": .object(["kind": .string("interval")])])
        XCTAssertNil(session.latest); XCTAssertNotNil(session.failure)
        XCTAssertFalse(session.flush(), "An absent first revision must not let a sheet Close discard an unpreserved edit")
        XCTAssertFalse(session.closed)
    }
}
