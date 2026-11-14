import XCTest
@testable import TaskfoldCore

/// Actual time (Core/ActualTime.swift): recording Focus time per task in `view_orders`, idempotence, the 30-day
/// estimate-versus-actual reading, its five-task floor, the planning caption and the spoken wording.
final class ActualTimeTests: XCTestCase {
    let account = "11111111-1111-4111-8111-111111111111"
    let task = "22222222-2222-4222-8222-222222222222"
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func session(_ id: String = "33333333-3333-4333-8333-333333333333", minutes: Int = 25, at: Date? = nil) throws -> FocusSession {
        try FocusSession(taskID: task, minutes: minutes, now: at ?? t0, id: UUID(uuidString: id)!)
    }
    func apply(_ change: Mutation?, to rows: [Record]) -> [Record] {
        guard let change else { return rows }
        let row = Record(change.fields)
        return rows.filter { $0.id != row.id } + [row]
    }

    func testRecordsStoppedSessionSecondsAgainstItsTask() throws {
        let stopped = try session().stopped(at: t0.addingTimeInterval(20 * 60 + 10))
        let change = try XCTUnwrap(ActualTime.recording(stopped, at: t0.addingTimeInterval(21 * 60), rows: [], account: account))
        XCTAssertEqual(change.table, "view_orders"); XCTAssertEqual(change.method, "POST")
        XCTAssertEqual(change.recordID, "actual:" + task)
        let rows = apply(change, to: [])
        XCTAssertEqual(ActualTime.seconds(ActualTime.entries(rows[0], account: account)), 20 * 60 + 10)
        XCTAssertEqual(ActualTime.totals(rows: rows, account: account), [task: 1210])
    }
    func testRunningSessionIsNotRecordedUntilItsTimeRunsOut() throws {
        let running = try session(minutes: 25)
        XCTAssertNil(try ActualTime.recording(running, at: t0.addingTimeInterval(600), rows: [], account: account))
        let change = try XCTUnwrap(ActualTime.recording(running, at: t0.addingTimeInterval(26 * 60), rows: [], account: account))
        XCTAssertEqual(ActualTime.seconds(ActualTime.entries(Record(change.fields), account: account)), 25 * 60)
    }
    func testPausedThenResumedThenStoppedCountsTheSessionOnce() throws {
        var rows: [Record] = []
        let paused = try session().paused(at: t0.addingTimeInterval(600))
        rows = apply(try ActualTime.recording(paused, at: t0.addingTimeInterval(601), rows: rows, account: account), to: rows)
        XCTAssertEqual(ActualTime.totals(rows: rows, account: account)[task], 600)
        // Recording the same state again changes nothing.
        XCTAssertNil(try ActualTime.recording(paused, at: t0.addingTimeInterval(900), rows: rows, account: account))
        let stopped = try paused.resumed(at: t0.addingTimeInterval(1000)).stopped(at: t0.addingTimeInterval(1300))
        let change = try XCTUnwrap(ActualTime.recording(stopped, at: t0.addingTimeInterval(1301), rows: rows, account: account))
        XCTAssertEqual(change.method, "PATCH")
        rows = apply(change, to: rows)
        XCTAssertEqual(ActualTime.entries(rows[0], account: account).count, 1)
        XCTAssertEqual(ActualTime.totals(rows: rows, account: account)[task], 900)
    }
    func testSecondSessionAddsAndTinySessionsAreIgnored() throws {
        var rows: [Record] = []
        let a = try session().stopped(at: t0.addingTimeInterval(600))
        rows = apply(try ActualTime.recording(a, at: t0, rows: rows, account: account), to: rows)
        let b = try session("44444444-4444-4444-8444-444444444444", at: t0.addingTimeInterval(3600)).stopped(at: t0.addingTimeInterval(3600 + 300))
        rows = apply(try ActualTime.recording(b, at: t0, rows: rows, account: account), to: rows)
        XCTAssertEqual(ActualTime.totals(rows: rows, account: account)[task], 900)
        let accidental = try session("55555555-5555-4555-8555-555555555555", at: t0.addingTimeInterval(9000)).stopped(at: t0.addingTimeInterval(9000 + 10))
        XCTAssertNil(try ActualTime.recording(accidental, at: t0, rows: rows, account: account))
    }
    func testOtherAccountsRowsAreNeverReadOrWritten() throws {
        let foreign = Record(["id": .string("actual:" + task), "user_id": .string("someone-else"), "ids": .array([.string("s|1|600")])])
        XCTAssertEqual(ActualTime.totals(rows: [foreign], account: account), [:])
        let stopped = try session().stopped(at: t0.addingTimeInterval(600))
        XCTAssertThrowsError(try ActualTime.recording(stopped, at: t0, rows: [foreign], account: account))
        XCTAssertNil(try ActualTime.recording(stopped, at: t0, rows: [], account: ""))
    }
    func testMalformedEntriesAndDuplicatesAreIgnored() {
        let row = Record(["id": .string("actual:" + task), "user_id": .string(account),
                          "ids": .array([.string("a|100|60"), .string("a|200|90"), .string("bad"), .string("b|x|60"), .string("c|5|0"), .number(3), .string("d|7|120")])])
        XCTAssertEqual(ActualTime.entries(row, account: account).map(\.sessionID), ["a", "d"])
        XCTAssertEqual(ActualTime.totals(rows: [row], account: account)[task], 180)
    }
    func testOldEntriesFoldIntoOneEarlierEntryAndKeepTheTotal() {
        let list = (0..<(ActualTime.maxEntries + 10)).map { ActualTime.Entry(sessionID: "s\($0)", endedAt: Int64($0), seconds: 60) }
        let folded = ActualTime.folded(list)
        XCTAssertEqual(folded.count, ActualTime.maxEntries + 1)
        XCTAssertEqual(folded.first?.sessionID, ActualTime.rollupID)
        XCTAssertEqual(ActualTime.seconds(folded), ActualTime.seconds(list))
        XCTAssertEqual(ActualTime.folded(folded).count, folded.count)
        XCTAssertEqual(ActualTime.seconds(ActualTime.folded(folded)), ActualTime.seconds(list))
    }
    func testWording() {
        XCTAssertEqual(ActualTime.spentText(seconds: 4800), "Spent 1h 20m")
        XCTAssertEqual(ActualTime.spentSpoken(seconds: 4800), "Spent 1 hour 20 minutes")
        XCTAssertEqual(ActualTime.spentText(seconds: 45 * 60), "Spent 45m")
        XCTAssertNil(ActualTime.spentText(seconds: 29))
        XCTAssertEqual(ActualTime.spentSpoken(seconds: 3600), "Spent 1 hour")
    }

    // MARK: Estimate versus actual

    func done(_ id: Int, estimate: Int?, daysAgo: Double, completed: Bool = true) -> Record {
        var row = Record.task(user: account, createdAt: "2026-01-01T09:00:00Z")
        row["id"] = .string(String(format: "00000000-0000-4000-8000-%012d", id))
        if let estimate { row["duration_minutes"] = .number(Double(estimate)) }
        if completed {
            row["completed"] = .bool(true)
            row["completed_at"] = .string(ISO8601DateFormatter().string(from: t0.addingTimeInterval(-daysAgo * 86400)))
        }
        return row
    }
    func reading(_ tasks: [Record], _ minutes: [Int: Int]) -> EstimateAccuracy? {
        var totals: [String: Int] = [:]
        for (id, m) in minutes { totals[String(format: "00000000-0000-4000-8000-%012d", id)] = m * 60 }
        return EstimateAccuracy.reading(tasks: tasks, totals: totals, now: t0)
    }
    func testNothingIsShownBelowFiveTasks() throws {
        let tasks = (1...4).map { done($0, estimate: 30, daysAgo: 2) }
        let result = try XCTUnwrap(reading(tasks, [1: 40, 2: 40, 3: 40, 4: 40]))
        XCTAssertFalse(result.isReliable); XCTAssertNil(result.message); XCTAssertNil(result.detail)
        XCTAssertNil(result.dayHint(plannedMinutes: 420))
        XCTAssertNil(reading([], [:]))
    }
    func testSaysTheEstimatesRunShort() throws {
        let tasks = (1...5).map { done($0, estimate: 60, daysAgo: Double($0)) }
        let result = try XCTUnwrap(reading(tasks, [1: 78, 2: 78, 3: 78, 4: 78, 5: 78]))
        XCTAssertEqual(result.samples, 5); XCTAssertEqual(result.ratio, 1.3, accuracy: 0.001)
        XCTAssertEqual(result.message, "Your estimates run about 30% short")
        XCTAssertEqual(result.detail, "Based on 5 tasks you finished in the last 30 days with Focus time recorded.")
    }
    func testSaysTheEstimatesRunLongOrClose() throws {
        let tasks = (1...5).map { done($0, estimate: 60, daysAgo: 1) }
        XCTAssertEqual(reading(tasks, [1: 30, 2: 30, 3: 30, 4: 30, 5: 30])?.message, "Your estimates run about 50% long")
        XCTAssertEqual(reading(tasks, [1: 62, 2: 58, 3: 60, 4: 61, 5: 59])?.message, "Your estimates are close to the time tasks take")
    }
    func testMedianIgnoresOneRunawayTask() throws {
        let tasks = (1...5).map { done($0, estimate: 30, daysAgo: 1) }
        let result = try XCTUnwrap(reading(tasks, [1: 30, 2: 30, 3: 30, 4: 30, 5: 600]))
        XCTAssertEqual(result.message, "Your estimates are close to the time tasks take")
    }
    func testOnlyFinishedEstimatedTasksFromTheLastThirtyDaysCount() throws {
        var tasks = (1...5).map { done($0, estimate: 60, daysAgo: 3) }
        tasks += [done(6, estimate: 60, daysAgo: 45), done(7, estimate: nil, daysAgo: 2), done(8, estimate: 60, daysAgo: 0, completed: false)]
        let result = try XCTUnwrap(reading(tasks, [1: 90, 2: 90, 3: 90, 4: 90, 5: 90, 6: 90, 7: 90, 8: 90]))
        XCTAssertEqual(result.samples, 5)
        // A task with under a minute of recorded time is not a sample.
        let totals = Dictionary(uniqueKeysWithValues: tasks.prefix(5).map { ($0.id, 30) })
        XCTAssertNil(EstimateAccuracy.reading(tasks: tasks, totals: totals, now: t0))
    }
    func testDayHintIsACaptionOnlyWhenReliableAndMeaningful() {
        let reliable = EstimateAccuracy(samples: 6, ratio: 1.3)
        XCTAssertEqual(reliable.dayHint(plannedMinutes: 330), "Based on your history, today may take ~7h 10m")
        XCTAssertEqual(reliable.dayHintSpoken(plannedMinutes: 330), "Based on your history, today may take about 7 hours 10 minutes")
        XCTAssertNil(EstimateAccuracy(samples: 4, ratio: 1.3).dayHint(plannedMinutes: 330))
        XCTAssertNil(EstimateAccuracy(samples: 6, ratio: 1.05).dayHint(plannedMinutes: 330))
        XCTAssertNil(reliable.dayHint(plannedMinutes: 0))
        XCTAssertEqual(EstimateAccuracy(samples: 9, ratio: 9).dayHint(plannedMinutes: 60), "Based on your history, today may take ~3h")
    }
}
