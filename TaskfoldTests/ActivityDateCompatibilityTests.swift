import XCTest
@testable import TaskfoldCore

final class ActivityDateCompatibilityTests: XCTestCase {
    private let account = "local"
    private let dates = ["", "2026-10-27T12:34:56Z", "2026-10-27T12:34:56.123Z", "2026-10-27T13:34:56.123+01:00", "2026-10-27T12:34:56.123456789Z", "2026-03-29T01:30:00+01:00", "2026-10-25T01:30:00Z", "1969-12-31T23:59:59.999Z", "2000-02-29T00:00:00Z", "invalid", "invalid-é", "invalid-e\u{301}", "2026-02-30", "2026-10-27", " 2026-10-27T12:34:56Z"]
    private func root(_ index: Int, instant: String, day: String, heading: Bool = false) -> Record {
        Record(["id": .string(String(format: "b8100000-0000-4000-8000-%012x", index + 1)), "user_id": .string(account), "task_generation": .string("b8200000-0000-4000-8000-000000000001"), "title": .string("Date corpus"), "completed": .bool(false), "completion_version": .number(0), "is_heading": .bool(heading), "due_date": .string(day), "deadline_date": .string(day), "due_time": .string(index % 2 == 0 ? "12:34" : "12:34:56"), "scheduled_at": .string(instant), "subtasks": .array([.object(["id": .string("b8300000-0000-4000-8000-000000000001"), "title": .string("Date child"), "completed": .bool(false), "due_date": .string(day), "scheduled_at": .string(instant), "due_time": .string("12:34")])])])
    }
    private func command(_ index: Int, before: Record?, after: Record?) -> Mutation {
        Mutation(id: UUID(uuidString: String(format: "b8400000-0000-4000-8000-%012x", index + 1))!, table: "tasks", recordID: (after ?? before)!.id, method: before == nil ? "POST" : after == nil ? "DELETE" : "PATCH", fields: after?.fields ?? [:])
    }
    private func corpus() throws -> [Record] {
        var result = [Record](), index = 0
        for instant in dates {
            for day in ["2026-10-27", "2000-02-29", "2026-02-30", "2026-10-27T00:00:00Z", ""] {
                let base = root(index, instant: instant, day: day, heading: index % 2 == 0)
                var completed = base; completed["completed"] = .bool(true); completed["completed_at"] = .string(instant)
                var children = base["subtasks"].list, child = children[0].object
                child["completed"] = .bool(true); child["completed_at"] = .string(instant); children[0] = .object(child); completed["subtasks"] = .array(children)
                var rescheduled = base; rescheduled["scheduled_at"] = .string("2026-10-28T09:00:00.987Z"); rescheduled["due_date"] = .string("2026-10-28")
                let states: [(Record?, Record?)] = [(nil, base), (base, completed), (completed, base), (base, rescheduled), (base, nil)]
                for (before, after) in states {
                    let change = command(index, before: before, after: after)
                    let now = Date(timeIntervalSince1970: Double([-1, 0, 951782400, 1793095200, 4102444800][index % 5]) + Double(index % 1000) / 1000)
                    var snapshot = Snapshot()
                    TaskActivity.recordLocal(change, before: before, after: after, snapshot: &snapshot, account: account, now: now)
                    TaskNodeActivity.recordLocal(change, before: before, after: after, snapshot: &snapshot, account: account, now: now)
                    // Keep refusal results too: no missing-case ambiguity in the digest.
                    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                    let bytes = try encoder.encode(snapshot.tables)
                    result.append(Record(["id": .string(String(index)), "metadata": .string(String(decoding: bytes, as: UTF8.self))]))
                    index += 1
                }
            }
        }
        return result
    }
    func testHistoryDateCorpusRetainsFrozenLegacyBytesAndRefusals() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let rows = try corpus(), bytes = try encoder.encode(rows)
        XCTAssertEqual(rows.count, 375)
        let digest = DueReminder.digest(String(decoding: bytes, as: UTF8.self))
        print("HISTORY_DATE_CORPUS_SHA \(digest)")
        // Frozen before the formatter reuse change.
        XCTAssertEqual(digest, "901745ac563fae6de8dab06750891d3a603061398928f060dde2db55861db977")
    }
    func testCreationBatchDatesMatchOrdinaryRecordsAcrossAllSpellings() throws {
        var snapshot = Snapshot(), entries = [LocalActivityCreation.Entry](), ordinary = Snapshot()
        for (index, instant) in dates.enumerated() {
            var row = root(index, instant: instant, day: "2026-10-27")
            row["completed_at"] = .string(instant)
            let change = command(index, before: nil, after: row), time = Date(timeIntervalSince1970: 1793095200 + Double(index) / 1000)
            snapshot.tables["tasks", default: []].append(row); ordinary.tables["tasks", default: []].append(row)
            entries.append(.init(change: change, after: row, recordedAt: time))
            TaskActivity.recordLocal(change, before: nil, after: row, snapshot: &ordinary, account: account, now: time)
            TaskNodeActivity.recordLocal(change, before: nil, after: row, snapshot: &ordinary, account: account, now: time)
            TaskAssignmentProvenance.recordLocal(change, before: nil, after: row, snapshot: &ordinary, account: account, now: time)
        }
        XCTAssertTrue(LocalActivityCreation.record(entries, snapshot: &snapshot, account: account))
        XCTAssertEqual(snapshot, ordinary)
    }
}
