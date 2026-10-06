import XCTest
@testable import TaskfoldCore
@testable import WidgetModel

final class FocusWidgetTests: XCTestCase {
    private let owner = "11111111-1111-4111-8111-111111111111", other = "22222222-2222-4222-8222-222222222222"
    private let taskID = "33333333-3333-4333-8333-333333333333"
    private let now = Date(timeIntervalSince1970: 1_791_281_600.125)
    private func task(done: Bool = false) -> Record {
        var row = Record.task(user: owner); row["id"] = .string(taskID); row["title"] = .string("One useful step")
        row["completed"] = .bool(done); row["description"] = .string("Private full notes never belong in a Focus clock")
        return row
    }
    private func row(_ session: FocusSession) throws -> Record { Record(try FocusSessionChange.make(session, current: nil, account: owner).fields) }
    private func widget(_ session: FocusSession?, tasks: [Record]? = nil, conflict: Bool = false, account: String? = nil) throws -> WidgetSnapshot {
        let projection = WidgetProjection.payload(tasks: tasks ?? [task()], projects: [], account: account ?? owner, now: now, focusRecord: try session.map(row), focusConflict: conflict)
        return try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(projection))
    }
    func testActualProjectionMatchesNativeClockAcrossPauseResumeAndFinish() throws {
        let started = try FocusSession(taskID: taskID, minutes: 25, now: now.addingTimeInterval(-300.625))
        let paused = try started.paused(at: now), resumed = try paused.resumed(at: now.addingTimeInterval(60.375))
        for session in [started, paused, resumed] {
            let clock = try XCTUnwrap(widget(session).focusSession?.clock)
            for offset in [0.0, 0.125, 60.875, 1500.0] {
                let time = now.addingTimeInterval(offset)
                XCTAssertEqual(clock.elapsed(at: time), session.elapsed(at: time))
                XCTAssertEqual(clock.remaining(at: time), session.remaining(at: time))
            }
            XCTAssertEqual(clock.endDate, session.endDate)
        }
        XCTAssertEqual(try widget(paused).focusSessionStatus(at: now.addingTimeInterval(600)), .paused)
        XCTAssertEqual(try widget(started).focusSessionStatus(at: now.addingTimeInterval(1500)), .finished)
    }
    func testTimerIntervalCarriesAccumulatedProgressAndCannotCountUpPastFinish() throws {
        let start = try FocusSession(taskID: taskID, minutes: 25, now: now.addingTimeInterval(-300))
        let resumed = try start.paused(at: now).resumed(at: now.addingTimeInterval(600))
        let clock = try XCTUnwrap(widget(resumed).focusSession?.clock), interval = try XCTUnwrap(clock.timerInterval)
        XCTAssertEqual(interval.upperBound, now.addingTimeInterval(1800))
        XCTAssertEqual(interval.lowerBound, now.addingTimeInterval(300))
        XCTAssertEqual(clock.clock(at: interval.upperBound), "00:00")
        XCTAssertEqual(clock.clock(at: interval.upperBound.addingTimeInterval(60)), "00:00")
        XCTAssertEqual(clock.elapsed(at: now.addingTimeInterval(600)), 300_000)
        XCTAssertEqual(clock.elapsed(at: Date(timeIntervalSince1970: .nan)), 300_000)
    }
    func testEndedTimeIsSpentAndPausesNeverAcquireNewElapsedTime() throws {
        let start = try FocusSession(taskID: taskID, minutes: 25, now: now.addingTimeInterval(-120))
        let paused = try start.paused(at: now), ended = try paused.stopped(at: now.addingTimeInterval(600))
        let stopped = try widget(ended), clock = try XCTUnwrap(stopped.focusSession?.clock)
        XCTAssertEqual(stopped.focusSessionStatus(at: now.addingTimeInterval(900)), .ended)
        XCTAssertEqual(clock.clock(at: now.addingTimeInterval(900), spent: true), "02:00")
        XCTAssertEqual(clock.clock(at: now.addingTimeInterval(900)), "23:00")
        XCTAssertNil(clock.timerInterval)
    }
    func testMissingCompletedAndConflictStateRemainExplicitWithoutAnotherTaskFallback() throws {
        let session = try FocusSession(taskID: taskID, minutes: 25, now: now)
        let missing = try widget(session, tasks: [])
        XCTAssertEqual(missing.focusSessionStatus(at: now), .unavailable)
        XCTAssertNil(missing.focusSession?.clock?.title)
        XCTAssertEqual(try widget(session, tasks: [task(done: true)]).focusSessionStatus(at: now), .unavailable)
        XCTAssertEqual(try widget(session, conflict: true).focusSessionStatus(at: now), .conflict)
        XCTAssertEqual(try widget(nil).focusSessionStatus(at: now), .idle)
    }
    func testOwnerIsolationSignedOutLegacyMalformedRowsAndUnknownProjectionVersion() throws {
        let session = try FocusSession(taskID: taskID, minutes: 25, now: now)
        XCTAssertEqual(try widget(session, account: other).focusSessionStatus(at: now), .refresh)
        let signedOut = try widget(session, account: "")
        XCTAssertNil(signedOut.focusSession); XCTAssertTrue(signedOut.tasks.isEmpty)
        XCTAssertEqual(signedOut.focusSessionURL.host, "today")
        let unreadable = WidgetProjection.payload(tasks: [task()], projects: [], account: owner, now: now, focusReadable: false)
        XCTAssertEqual(unreadable["focusSession"], .null)
        var value = try widget(session); value.focusSession?.account = other
        XCTAssertEqual(value.focusSessionStatus(at: now), .refresh)
        value = try widget(session); value.focusSession?.version = 99
        XCTAssertEqual(value.focusSessionStatus(at: now), .refresh)
        let legacy = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(#"{"updated":123,"tasks":[]}"#.utf8))
        XCTAssertEqual(legacy.focusSessionStatus(at: now), .refresh)
        var malformed = try row(session); malformed["revision"] = .number(1.5)
        XCTAssertEqual(WidgetProjection.focusPayload(malformed, tasks: [task()], account: owner, conflict: false), .null)
    }
    func testStrictClockBoundsAndDecoderRejectMalformedTypesWithoutCrashes() throws {
        let session = try FocusSession(taskID: taskID, minutes: 25, now: now)
        let original = try XCTUnwrap(widget(session).focusSession?.clock)
        var bad = original; bad.startedAt = Int64.max; XCTAssertFalse(bad.valid)
        bad = original; bad.changedAt = -1; XCTAssertFalse(bad.valid)
        bad = original; bad.durationSeconds = Int.max; XCTAssertFalse(bad.valid)
        bad = original; bad.elapsedMilliseconds = Int64.max; XCTAssertFalse(bad.valid)
        bad = original; bad.runningSince = nil; XCTAssertFalse(bad.valid)
        bad = original; bad.status = "paused"; XCTAssertFalse(bad.valid)
        bad = original; bad.taskState = "unavailable"; XCTAssertFalse(bad.valid)
        bad = original; bad.title = String(repeating: "x", count: 161); XCTAssertFalse(bad.valid)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        for value in [1.5, 1e200, -1] {
            var document = encoded; document["elapsedMilliseconds"] = value
            let data = try JSONSerialization.data(withJSONObject: document)
            let decoded = try? JSONDecoder().decode(FocusWidgetClock.self, from: data)
            XCTAssertFalse(decoded?.valid ?? false)
        }
    }
    func testProjectionBoundsUnicodeTitlesAndNeverCopiesDescriptionOrCredential() throws {
        var title = task(); title["title"] = .string(String(repeating: "👩🏽‍💻 café", count: 1000))
        let session = try FocusSession(taskID: taskID, minutes: 25, now: now)
        let snapshot = try widget(session, tasks: [title]), clock = try XCTUnwrap(snapshot.focusSession?.clock)
        XCTAssertLessThanOrEqual(clock.title!.count, 160); XCTAssertLessThanOrEqual(clock.title!.utf8.count, 1000)
        let encoded = String(data: try JSONEncoder().encode(snapshot.focusSession), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("Private full notes")); XCTAssertFalse(encoded.contains("access_token"))
        XCTAssertEqual(title.string("title"), String(repeating: "👩🏽‍💻 café", count: 1000))
    }
    func testTimelineIncludesExactFinishExpiryAndRejectsFutureOrStalePublication() throws {
        let session = try FocusSession(taskID: taskID, minutes: 25, now: now)
        let snapshot = try widget(session), dates = snapshot.focusSessionTimelineDates(from: now), expiry = now.addingTimeInterval(86_400)
        XCTAssertEqual(dates, [now, now.addingTimeInterval(1500), expiry])
        XCTAssertEqual(snapshot.focusSessionStatus(at: expiry.addingTimeInterval(-0.001)), .finished)
        XCTAssertEqual(snapshot.focusSessionStatus(at: expiry), .refresh)
        XCTAssertEqual(snapshot.focusSessionTimelineDates(from: expiry), [expiry])
        var future = snapshot; future.updated = now.addingTimeInterval(301).timeIntervalSinceReferenceDate
        XCTAssertEqual(future.focusSessionStatus(at: now), .refresh)
        var stale = snapshot; stale.updated = .infinity
        XCTAssertEqual(stale.focusSessionStatus(at: now), .refresh)
    }
    func testAccountBoundRouteRoundTripsAndRejectsDuplicateExtraForgedComponents() {
        let link = FocusSessionLink(account: "workspace + café/😀&x=%")
        XCTAssertEqual(FocusSessionLink.parse(link.url), link)
        for value in ["https://focus?account=a", "taskfold://focus?account=", "taskfold://focus?account=a&account=b", "taskfold://focus?account=a&task=b", "taskfold://focus/path?account=a", "taskfold://focus/?account=a", "taskfold://u@focus?account=a", "taskfold://focus:80?account=a", "taskfold://focus?account=a#fragment"] {
            XCTAssertNil(FocusSessionLink.parse(URL(string: value)!), value)
        }
        XCTAssertNil(FocusSessionLink.parse(FocusSessionLink(account: String(repeating: "x", count: 257)).url))
    }
}
