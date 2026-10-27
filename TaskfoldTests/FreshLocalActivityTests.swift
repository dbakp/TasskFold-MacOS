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
    private func batch(_ actions: [(Mutation, Record)], seed: Snapshot) -> Snapshot {
        var value = seed
        value.tables["tasks", default: []] += actions.map { $0.1 }
        XCTAssertTrue(LocalActivityCreation.record(actions.enumerated().map { .init(change: $0.element.0, after: $0.element.1, recordedAt: now.addingTimeInterval(Double($0.offset))) }, snapshot: &value, account: account))
        return value
    }
    func testCreationBatchPreservesFrozenMetadataAndSequenceOrder() throws {
        let actions = (0..<100).map { action($0) }, original = seed(), start = ContinuousClock.now
        let value = batch(actions, seed: original), elapsed = start.duration(to: .now)
        XCTAssertEqual(try metadata(value), try metadata(legacy(actions, seed: original)))
        XCTAssertEqual(DueReminder.digest(String(decoding: try metadata(value), as: UTF8.self)), "b7d5c92f934e1e2af8103699b1d895b9d92f7c94fdcb0f8885e065d92c40ab4e")
        print("LOCAL_HISTORY_BATCH_100_SECONDS \(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)")
    }
    func testMalformedLedgersAndDuplicateSequencesKeepLegacyRefusal() throws {
        let actions = (20..<25).map { action($0) }, original = seed()
        var variants = [Snapshot]()
        var malformed = original; malformed.tables[TaskNodeActivity.table]?[0]["future_field"] = .bool(true); variants.append(malformed)
        malformed = original; malformed.tables[TaskNodeActivity.table]?[1]["sequence"] = .number(1); variants.append(malformed)
        malformed = original; malformed.tables[TaskNodeActivity.table]?[0]["recorded_at"] = .string("invalid"); variants.append(malformed)
        malformed = original; malformed.tables[TaskActivity.table, default: []].append(Record(["id": .string("unknown"), "sequence": .number(1042)])); variants.append(malformed)
        // Duplicate child IDs with distinct valid sequences are historically allowed.
        malformed = original
        var duplicate = try XCTUnwrap(malformed.tables[TaskNodeActivity.table]?.first); duplicate["sequence"] = .number(41)
        malformed.tables[TaskNodeActivity.table, default: []].append(duplicate); variants.append(malformed)
        for (index, value) in variants.enumerated() {
            XCTAssertEqual(try metadata(batch(actions, seed: value)), try metadata(legacy(actions, seed: value)), "variant \(index)")
        }
    }
    func testSequenceLimitsAndFilteredDuplicateRowsKeepLegacyGaps() throws {
        let actions = (20..<24).map { action($0) }
        for table in [TaskActivity.table, TaskNodeActivity.table] {
            for remaining in [0, 1, 2, 3] {
                var value = seed()
                let index = try XCTUnwrap(value.tables[table]?.indices.last)
                value.tables[table]?[index]["sequence"] = .number(9_007_199_254_740_991 - Double(remaining))
                XCTAssertEqual(try metadata(batch(actions, seed: value)), try metadata(legacy(actions, seed: value)), "\(table) remaining \(remaining)")
            }
        }
        // Replayed child IDs are filtered after generation; subsequent new roots
        // start from the maximum sequence actually appended, not rejected rows.
        let repeated = [action(21), action(22)]
        var value = legacy([action(21)], seed: Snapshot()); value.tables["tasks"] = []
        XCTAssertEqual(try metadata(batch(repeated, seed: value)), try metadata(legacy(repeated, seed: value)))
        value.tables[TaskNodeActivity.table]?.removeLast()
        let partial = batch(repeated, seed: value)
        XCTAssertEqual(try metadata(partial), try metadata(legacy(repeated, seed: value)))
        XCTAssertEqual(partial.tables[TaskNodeActivity.table]?.map { $0["sequence"] }, [.number(1), .number(3), .number(4), .number(5)], "Filtering a previously recorded child keeps the legacy sequence gap")
    }
    func testEpochAbsenceEmptyAndUnknownRowsRetainLegacyRules() throws {
        for mode in 0..<3 {
            var value = seed()
            for table in [TaskActivity.epochTable, TaskNodeActivity.epochTable] {
                if mode == 0 { value.tables.removeValue(forKey: table) }
                else { value.tables[table] = mode == 1 ? [] : [Record(["id": .string("future"), "recorded_from": .string("unknown")])] }
            }
            let actions = [action(21), action(22)]
            XCTAssertEqual(try metadata(batch(actions, seed: value)), try metadata(legacy(actions, seed: value)))
        }
    }
    func testInvalidCreationScopeRefusesBeforeAnyMetadataWrite() throws {
        let (change, row) = action(21)
        let good = LocalActivityCreation.Entry(change: change, after: row, recordedAt: now)
        var original = seed(); original.tables["tasks"] = [row]
        var wrongOwner = row; wrongOwner["user_id"] = .string("other")
        var stale = row; stale["title"] = .string("stale")
        var patch = change; patch.method = "PATCH"
        var wrongID = change; wrongID.recordID = "other"
        var otherTable = change; otherTable.table = "projects"
        let invalid: [[LocalActivityCreation.Entry]] = [
            [good, good], [.init(change: change, after: wrongOwner)], [.init(change: change, after: stale)],
            [.init(change: patch, after: row)], [.init(change: wrongID, after: row)], [.init(change: otherTable, after: row)]
        ]
        for entries in invalid {
            var value = original
            XCTAssertFalse(LocalActivityCreation.record(entries, snapshot: &value, account: account))
            XCTAssertEqual(value, original)
        }
        var duplicated = original; duplicated.tables["tasks"]?.append(row)
        let before = duplicated
        XCTAssertFalse(LocalActivityCreation.record([good], snapshot: &duplicated, account: account)); XCTAssertEqual(duplicated, before)
        var value = original
        XCTAssertTrue(LocalActivityCreation.record([], snapshot: &value, account: "")); XCTAssertEqual(value, original)
    }
    private func withoutProvenanceNonces(_ value: Snapshot) -> Snapshot {
        var result = value
        result.tables[TaskAssignmentProvenance.table] = result.tables[TaskAssignmentProvenance.table]?.map { row in
            var row = row; row.fields.removeValue(forKey: "id"); row.fields.removeValue(forKey: "event_id"); return row
        }.sorted { ($0.string("task_id"), $0.string("node_key")) < ($1.string("task_id"), $1.string("node_key")) }
        return result
    }
    func testFreshProjectionAndOrphanAssignmentRepairMatchOrdinaryCreation() throws {
        let run = UUID(), assignee = "a8600000-0000-4000-8000-000000000001"
        let actions = (21..<25).map { index -> (Mutation, Record) in
            var (change, row) = action(index)
            row["assigned_to"] = .string(assignee)
            var children = row["subtasks"].list
            var fields = children[0].object; fields["assigned_to"] = .string(assignee); children[0] = .object(fields); row["subtasks"] = .array(children)
            if index == 24 { row["recurrence_parent_id"] = .string("a8700000-0000-4000-8000-000000000001") }
            change.fields = row.fields; change.workflowRun = run; change.insertOnly = true
            return (change, row)
        }
        var original = seed()
        // Existing orphan provenance for a fresh root must retain its row ID and
        // use the same invalidation/repair behavior as ordinary Snapshot.apply.
        var provenance = Snapshot()
        TaskAssignmentProvenance.recordLocal(actions[0].0, before: nil, after: actions[0].1, snapshot: &provenance, account: account, now: now)
        original.tables[TaskAssignmentProvenance.table] = provenance.tables[TaskAssignmentProvenance.table]
        var ordinary = original, fresh = original
        var plan = try XCTUnwrap(FreshWorkflowCreation(actions.map { $0.0 }, snapshot: original, account: account))
        var entries = [LocalActivityCreation.Entry]()
        for (index, action) in actions.enumerated() {
            let (change, _) = action, time = now.addingTimeInterval(Double(index))
            ordinary.apply(change)
            let after = try XCTUnwrap(ordinary.tables["tasks"]?.first { $0.id == change.recordID })
            TaskActivity.recordLocal(change, before: nil, after: after, snapshot: &ordinary, account: account, now: time)
            TaskNodeActivity.recordLocal(change, before: nil, after: after, snapshot: &ordinary, account: account, now: time)
            TaskAssignmentProvenance.recordLocal(change, before: nil, after: after, snapshot: &ordinary, account: account, now: time)
            let appended = try XCTUnwrap(plan.append(change, to: &fresh))
            entries.append(.init(change: change, after: appended, recordedAt: time))
        }
        XCTAssertTrue(LocalActivityCreation.record(entries, snapshot: &fresh, account: account))
        XCTAssertEqual(withoutProvenanceNonces(fresh), withoutProvenanceNonces(ordinary))
        for row in provenance.tables[TaskAssignmentProvenance.table] ?? [] {
            XCTAssertEqual(fresh.tables[TaskAssignmentProvenance.table]?.first { $0.id == row.id }?.id, row.id)
        }
    }
    func testFiveThousandRootsAndChildrenRetainCompleteHistoryAcrossEncoding() throws {
        let actions = (20..<5020).map { action($0, children: 1) }, original = seed(), start = ContinuousClock.now
        let value = batch(actions, seed: original), elapsed = start.duration(to: .now)
        XCTAssertEqual(value.tables[TaskActivity.table]?.count, 5020)
        XCTAssertEqual(value.tables[TaskNodeActivity.table]?.count, 5040)
        XCTAssertEqual(value.tables[TaskActivity.table]?.last?["sequence"], .number(5020))
        XCTAssertEqual(value.tables[TaskNodeActivity.table]?.last?["sequence"], .number(5040))
        XCTAssertEqual(Array((value.tables[TaskNodeActivity.table] ?? []).prefix(40)), original.tables[TaskNodeActivity.table])
        let encoder = JSONEncoder(), decoded = try JSONDecoder().decode(Snapshot.self, from: encoder.encode(value))
        XCTAssertEqual(decoded, value)
        print("LOCAL_HISTORY_BATCH_5000_SECONDS \(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)")
    }
    func testRecordingHierarchyEdgeCorpusRetainsLegacyMetadata() throws {
        let child: JSON = .object(["id": .string("a9300000-0000-4000-8000-000000000001"), "title": .string("Child"), "completed": .bool(false)])
        let shapes: [JSON] = [.null, .array([]), .array([child]), .array([.string("Legacy child")]), .string("future"), .object(["future": .bool(true)]), .array([child, child]),
            .array([.object(["id": child.object["id"]!, "title": .string(" ")])]),
            .array([.object(["id": child.object["id"]!, "title": .string("Child"), "completed": .string("future")])]),
            .array([.object(["id": child.object["id"]!, "title": .string("Heading"), "is_heading": .bool(true), "completed": .bool(true)])]),
            .array([.object(["id": child.object["id"]!, "title": .string("Heading"), "is_heading": .bool(true), "subtasks": .array([child])])]),
            .array([.object(["id": .string("é"), "title": .string("First")]), .object(["id": .string("e\u{301}"), "title": .string("Equivalent identity")])])]
        let types: [JSON] = [.null, .bool(false), .bool(true), .string("future")]
        let generations: [JSON] = [.null, .string("a9200000-0000-4000-8000-000000000001"), .string("invalid")]
        let completions: [JSON] = [.null, .bool(false), .bool(true), .string("future")]
        let recipients: [JSON] = [.null, .string(""), .string("a9400000-0000-4000-8000-000000000001"), .string("unknown")]
        var cases: [(JSON, JSON, JSON, JSON, JSON)] = []
        for (i, shape) in shapes.enumerated() {
            for (j, kind) in types.enumerated() {
                for (k, generation) in generations.enumerated() {
                    cases.append((shape, kind, generation, completions[(i+j+k)%4], recipients[(i*7+j*3+k)%4]))
                }
            }
        }
        for shape: JSON in [.null, .array([])] {
            for completion in completions { for recipient in recipients { cases.append((shape, .bool(false), generations[1], completion, recipient)) } }
        }
        var digests: [String] = []
        for (index, values) in cases.enumerated() {
            var (change, row) = action(1000+index, children: 0)
            row["subtasks"] = values.0; row["is_heading"] = values.1; row["task_generation"] = values.2; row["completed"] = values.3; row["assigned_to"] = values.4
            change.fields = row.fields
            let original = Snapshot(), ordinary = withoutProvenanceNonces(legacy([(change, row)], seed: original))
            let fresh = withoutProvenanceNonces(batch([(change, row)], seed: original))
            XCTAssertEqual(fresh, ordinary, "Hierarchy corpus case \(index)")
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            digests.append(DueReminder.digest(String(decoding: try encoder.encode(ordinary), as: UTF8.self)))
        }
        let digest = DueReminder.digest(digests.joined(separator: "\n"))
        print("RECORDING_HIERARCHY_CORPUS \(cases.count) \(digest)")
        XCTAssertEqual(cases.count, 176)
        XCTAssertEqual(digest, "38a18fe66c316e6be6e90f3b4663831e8d9753a79f37bc939a77eec68449d68a", "Frozen before sharing structural reads; keep independently validated histories and refusal metadata")
    }

    func testCaseAliasedRootsUseOrdinaryProjectionInsteadOfReorderingProvenance() throws {
        let action = action(30)
        var change = action.0; let row = action.1
        change.workflowRun = UUID(); change.insertOnly = true
        var alias = row; alias["id"] = .string(row.id.uppercased())
        var other = change; other.id = UUID(); other.recordID = alias.id; other.fields = alias.fields
        XCTAssertNotEqual(row.id, alias.id)
        XCTAssertNil(FreshWorkflowCreation([change, other], snapshot: Snapshot(), account: account))
        var value = Snapshot(); value.tables["tasks"] = [row, alias]
        let original = value
        XCTAssertFalse(LocalActivityCreation.record([.init(change: change, after: row), .init(change: other, after: alias)], snapshot: &value, account: account))
        XCTAssertEqual(value, original)
    }

}
