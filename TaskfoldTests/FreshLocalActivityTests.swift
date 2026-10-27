import XCTest
@testable import TaskfoldCore

final class FreshLocalActivityTests: XCTestCase {
    private let account = "local"
    private let now = Date(timeIntervalSince1970: 1793095200)
    private func action(_ index: Int, children: Int = 2, prefix: String = "a810") -> (Mutation, Record) {
        var row = Record.task(user: account)
        row["id"] = .string(String(format: "\(prefix)0000-0000-4000-8000-%012x", index + 1))
        row["task_generation"] = .string(String(format: "a8200000-0000-4000-8000-%012x", index + 1))
        row["created_at"] = .string("2026-10-27T10:00:00Z"); row["title"] = .string("Local workflow \(index)")
        row["is_heading"] = .bool(index % 2 == 0); row["completed"] = .bool(false)
        row["subtasks"] = .array((0..<children).map { child in .object(["id": .string(String(format: "a8300000-0000-4000-8000-%012x", child + 1)), "title": .string("Step \(child)"), "completed": .bool(false)]) })
        var change = Mutation(table: "tasks", recordID: row.id, method: "POST", fields: row.fields)
        change.id = UUID(uuidString: String(format: "a8400000-0000-4000-8000-%012x", index + 1))!
        return (change, row)
    }
    private func seed() -> Snapshot {
        var value = Snapshot()
        for index in 0..<20 {
            let (change, row) = action(index, prefix: "a850")
            TaskActivity.recordLocal(change, before: nil, after: row, snapshot: &value, account: account, now: now.addingTimeInterval(Double(index) - 86400))
            TaskNodeActivity.recordLocal(change, before: nil, after: row, snapshot: &value, account: account, now: now.addingTimeInterval(Double(index) - 86400))
            TaskAssignmentProvenance.recordLocal(change, before: nil, after: row, snapshot: &value, account: account, now: now.addingTimeInterval(Double(index) - 86400))
        }
        return value
    }
    private func legacy(_ actions: [(Mutation, Record)], seed: Snapshot) -> Snapshot {
        var value = seed
        for (index, action) in actions.enumerated() {
            let (change, row) = action, time = now.addingTimeInterval(Double(index))
            value.tables["tasks", default: []].append(row)
            TaskActivity.recordLocal(change, before: nil, after: row, snapshot: &value, account: account, now: time)
            TaskNodeActivity.recordLocal(change, before: nil, after: row, snapshot: &value, account: account, now: time)
            TaskAssignmentProvenance.recordLocal(change, before: nil, after: row, snapshot: &value, account: account, now: time)
        }
        return value
    }
    private func metadata(_ value: Snapshot) throws -> Data {
        let keys: Set<String> = [TaskActivity.table, TaskActivity.epochTable, TaskNodeActivity.table, TaskNodeActivity.epochTable, TaskAssignmentProvenance.table]
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value.tables.filter { keys.contains($0.key) })
    }
    func testLegacyLocalHistoryControlIsDeterministic() throws {
        let actions = (0..<100).map { action($0) }, original = seed(), start = ContinuousClock.now
        let value = legacy(actions, seed: original), elapsed = start.duration(to: .now)
        XCTAssertEqual(try metadata(value), try metadata(legacy(actions, seed: original)))
        XCTAssertEqual(value.tables[TaskActivity.table]?.count, 100, "The first 20 duplicate command IDs remain idempotent")
        XCTAssertEqual(value.tables[TaskNodeActivity.table]?.count, 240)
        print("LOCAL_HISTORY_CONTROL_SECONDS \(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)")
        let digest = DueReminder.digest(String(decoding: try metadata(value), as: UTF8.self))
        XCTAssertEqual(digest, "b7d5c92f934e1e2af8103699b1d895b9d92f7c94fdcb0f8885e065d92c40ab4e", "Frozen before indexing local creation history; preserve existing event bytes and sequence rules")
        print("LOCAL_HISTORY_CONTROL_SHA \(digest)")
    }
}
