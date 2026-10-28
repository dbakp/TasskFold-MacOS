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
    private func workflowChanges() -> [Mutation] {
        let run = UUID()
        return (100..<104).map { index in
            var (change, _) = action(index)
            change.workflowRun = run; change.insertOnly = true
            change.fields["description"] = .string("é")
            return change
        }
    }
    private func finalEntries(_ changes: [Mutation], seed: Snapshot) -> (Snapshot, [LocalActivityCreation.Entry]) {
        var value = seed, entries: [LocalActivityCreation.Entry] = []
        for original in changes {
            var change = original
            change.fields = TaskPlanning.fields(change.fields, existing: nil)
            change = TaskCompletionRevision.capturing(change, existing: nil)
            value.apply(change)
            entries.append(.init(change: change, after: value.tables["tasks"]!.first { $0.id == change.recordID }!, recordedAt: now))
        }
        return (value, entries)
    }
    func testDetachedHistoryMatchesOrdinaryMetadataWithoutChangingInput() async throws {
        let original = seed(), changes = workflowChanges(), source = UUID(), account = account, time = now
        let prepared = try await Task.detached {
            try LocalActivityCreation.Preparation(changes: changes, snapshot: original, source: source, account: account, labels: [], cache: nil, at: time)
        }.value
        let plan = try XCTUnwrap(prepared)
        var (actual, entries) = finalEntries(changes, seed: original)
        var expected = actual
        XCTAssertTrue(LocalActivityCreation.record(entries, snapshot: &expected, account: account))
        XCTAssertTrue(plan.apply(entries, to: &actual, source: source, account: account))
        XCTAssertEqual(withoutProvenanceNonces(actual), withoutProvenanceNonces(expected))
        XCTAssertEqual(try metadata(original), try metadata(seed()))
    }
    func testPreparedHistoryRejectsRevisionOwnerAndRawUnicodeChangesAtomically() throws {
        let original = seed(), changes = workflowChanges(), source = UUID()
        let plan = try XCTUnwrap(try LocalActivityCreation.Preparation(changes: changes, snapshot: original, source: source, account: account, labels: [], cache: nil, at: now))
        let (projected, entries) = finalEntries(changes, seed: original)
        for wrongOwner in [false, true] {
            var actual = projected
            XCTAssertFalse(plan.apply(entries, to: &actual, source: wrongOwner ? source : UUID(), account: wrongOwner ? "other" : account))
            XCTAssertEqual(actual, projected)
        }
        var changed = entries, after = changed[0].after, mutation = changed[0].change
        after["description"] = .string("e\u{301}"); mutation.fields["description"] = after["description"]
        changed[0] = .init(change: mutation, after: after, recordedAt: now)
        XCTAssertEqual(entries[0].after, changed[0].after, "Semantic String equality alone cannot bind prepared records")
        var actual = projected
        XCTAssertFalse(plan.apply(changed, to: &actual, source: source, account: account)); XCTAssertEqual(actual, projected)
    }
    func testHistoryAdmissionRequiresSameImmutableInputAndContext() throws {
        let original = seed(), changes = workflowChanges(), source = UUID()
        let plan = try XCTUnwrap(try LocalActivityCreation.Preparation(changes: changes, snapshot: original, source: source, account: account, labels: [], cache: nil, at: now))
        let admitted = try XCTUnwrap(plan.admit(changes, source: source, account: account, cache: nil))
        var (actual, entries) = finalEntries(changes, seed: original)
        var expected = actual
        XCTAssertTrue(LocalActivityCreation.record(entries, snapshot: &expected, account: account))
        XCTAssertTrue(admitted.apply(to: &actual, source: source, account: account))
        XCTAssertEqual(withoutProvenanceNonces(actual), withoutProvenanceNonces(expected))
        var changed = changes
        changed[0].fields["description"] = .string("e\u{301}")
        XCTAssertEqual(changes, changed)
        XCTAssertNil(plan.admit(changed, source: source, account: account, cache: nil), "Copy-on-write rejects a raw Unicode change even when semantic equality says equal")
        XCTAssertNil(plan.admit(changes, source: UUID(), account: account, cache: nil))
        XCTAssertNil(plan.admit(changes, source: source, account: "other", cache: nil))
        var calendar = Calendar.current; calendar.timeZone = TimeZone(secondsFromGMT: calendar.timeZone.secondsFromGMT() == 10800 ? 0 : 10800)!
        XCTAssertNil(plan.admit(changes, source: source, account: account, cache: nil, calendar: calendar))
        var untagged = changes; untagged[0].insertOnly = nil
        XCTAssertNil(try LocalActivityCreation.Preparation(changes: untagged, snapshot: original, source: source, account: account, labels: [], cache: nil))
    }

    func testPreparedHistoryCancellationAndExistingIdentityDoNotWrite() throws {
        let original = seed(), changes = workflowChanges(), source = UUID()
        var checks = 0
        XCTAssertThrowsError(try LocalActivityCreation.Preparation(changes: changes, snapshot: original, source: source, account: account, labels: [], cache: nil, checkCancellation: {
            checks += 1; if checks == 3 { throw CancellationError() }
        }))
        var collision = original; collision.tables["tasks"] = [Record(changes[0].fields)]
        XCTAssertNil(try LocalActivityCreation.Preparation(changes: changes, snapshot: collision, source: source, account: account, labels: [], cache: nil))
        XCTAssertEqual(try metadata(original), try metadata(seed()))
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

extension FreshLocalActivityTests {
    func testPreparedUndoMatchesOrdinaryCompleteDefinitionAndRetainsOneIdentity() throws {
        let original = seed(), source = UUID(), run = UUID()
        let project = Mutation(table: "projects", recordID: "project", method: "POST", fields: ["id": .string("project"), "user_id": .string(account), "name": .string("Résumé project")], insertOnly: true, workflowRun: run)
        let section = Mutation(table: "sections", recordID: "section", method: "POST", fields: ["id": .string("section"), "user_id": .string(account), "project_id": .string("project"), "name": .string("Review")], insertOnly: true, workflowRun: run)
        let label = Mutation(table: "labels", recordID: "label", method: "POST", fields: ["id": .string("label"), "user_id": .string(account), "name": .string("Résumé")], insertOnly: true, workflowRun: run)
        var changes = workflowChanges().map { change -> Mutation in
            var change = change; change.workflowRun = run
            change.fields["project_id"] = .string("project"); change.fields["section_id"] = .string("section")
            return change
        }
        changes.insert(contentsOf: [project, section, label], at: 0)
        changes.append(Mutation(table: "view_orders", recordID: "group:project:section", method: "POST", fields: ["id": .string("group:project:section"), "user_id": .string(account), "ids": .array(changes.filter { $0.table == "tasks" }.map { .string($0.recordID) })], insertOnly: true, workflowRun: run))
        let plan = try XCTUnwrap(try LocalActivityCreation.Preparation(changes: changes, snapshot: original, source: source, account: account, labels: [], cache: nil, at: now))
        let admission = try XCTUnwrap(plan.admit(changes, source: source, account: account, cache: nil))
        let prepared = try XCTUnwrap(admission.editHistory(matching: admission.changes, source: source, account: account))
        var ordinary = EditHistory(changes: admission.changes, snapshot: original, id: prepared.id)
        XCTAssertEqual(prepared.undo.count, 1)
        // The ordinary constructor chooses a fresh transport nonce; compare all
        // other command content against the existing synchronous constructor.
        ordinary.undo[0].id = prepared.undo[0].id
        XCTAssertEqual(prepared.undo, ordinary.undo)
        XCTAssertEqual(prepared.redo, ordinary.redo)
        let again = try XCTUnwrap(admission.editHistory(matching: admission.changes, source: source, account: account))
        XCTAssertEqual(prepared.id, again.id); XCTAssertEqual(prepared.undo.map(\.id), again.undo.map(\.id))
        XCTAssertEqual(try metadata(original), try metadata(seed()))
    }
    func testPreparedUndoRejectsRawUnicodeNumbersAndCommandMetadata() throws {
        let original = seed(), source = UUID(), changes = workflowChanges()
        let plan = try XCTUnwrap(try LocalActivityCreation.Preparation(changes: changes, snapshot: original, source: source, account: account, labels: [], cache: nil, at: now))
        let admission = try XCTUnwrap(plan.admit(changes, source: source, account: account, cache: nil))
        var variants: [[Mutation]] = []
        variants.append(admission.changes.map { $0 })
        var edited = admission.changes; edited[0].fields["description"] = .string("e\u{301}"); variants.append(edited)
        XCTAssertEqual(edited, admission.changes, "Semantic String equality must not admit raw-edited fields")
        edited = admission.changes; edited[0].baseline = [:]; variants.append(edited)
        edited = admission.changes; edited[0].id = UUID(); variants.append(edited)
        edited = admission.changes; edited[0].workflowRun = UUID(); variants.append(edited)
        edited = admission.changes; edited[0].reminderPreferenceField = "enabled"; variants.append(edited)
        edited = admission.changes; edited[0].fields["future_metadata"] = .object(["raw": .string("é")]); variants.append(edited)
        edited = Array(admission.changes.reversed()); variants.append(edited)
        for variant in variants { XCTAssertNil(admission.editHistory(matching: variant, source: source, account: account)) }
        XCTAssertNil(admission.editHistory(matching: admission.changes, source: UUID(), account: account))
        XCTAssertNil(admission.editHistory(matching: admission.changes, source: source, account: "other"))
        XCTAssertNotNil(admission.editHistory(matching: admission.changes, source: source, account: account))
    }
    func testPreparedUndoRefusesRawSignedZeroChange() throws {
        let original = seed(), source = UUID()
        var changes = workflowChanges(); changes[0].fields["future_number"] = .number(0)
        let plan = try XCTUnwrap(try LocalActivityCreation.Preparation(changes: changes, snapshot: original, source: source, account: account, labels: [], cache: nil, at: now))
        let admission = try XCTUnwrap(plan.admit(changes, source: source, account: account, cache: nil))
        var edited = admission.changes; edited[0].fields["future_number"] = .number(-0.0)
        XCTAssertEqual(edited, admission.changes)
        XCTAssertNil(admission.editHistory(matching: edited, source: source, account: account))
    }
}

extension FreshLocalActivityTests {
    func testPreparedUndoScaleMatchesOrdinaryConstructor() throws {
        let count = 5000, source = UUID(), original = Snapshot()
        let document: JSON = .object(["version": .number(1), "kind": .string("project"),
            "projects": .array([.object(["id": .string("root"), "name": .string("Scale workflow")])]),
            "sections": .array((0..<count).map { .object(["id": .string("s\($0)"), "name": .string("Section \($0)"), "project_id": .string("root"), "order_index": .number(Double($0))]) }),
            "tasks": .array((0..<count).map { .object(["id": .string("t\($0)"), "title": .string("Task \($0)"), "project_id": .string("root"), "section_id": .string("s\($0)"), "labels": .array([.object(["name": .string("Label \($0)")])]), "subtasks": .array([])]) })])
        let changes = try WorkflowTemplate(document: document).instantiate(account: account, name: "Scale workflow")
        let plan = try XCTUnwrap(try LocalActivityCreation.Preparation(changes: changes, snapshot: original, source: source, account: account, labels: [], cache: nil, at: now))
        let admission = try XCTUnwrap(plan.admit(changes, source: source, account: account, cache: nil))
        let final = admission.changes
        let clock = ContinuousClock()
        func seconds(_ elapsed: Duration) -> Double { Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18 }
        var matching: [Double] = [], constructing: [Double] = []
        for _ in 0..<3 {
            let start = clock.now
            let prepared = try XCTUnwrap(admission.editHistory(matching: final, source: source, account: account))
            matching.append(seconds(start.duration(to: clock.now)))
            let ordinaryStart = clock.now
            var ordinary = EditHistory(changes: final, snapshot: original, id: prepared.id)
            constructing.append(seconds(ordinaryStart.duration(to: clock.now)))
            XCTAssertEqual(prepared.undo.count, 1); XCTAssertEqual(ordinary.undo.count, 1)
            ordinary.undo[0].id = prepared.undo[0].id
            XCTAssertEqual(prepared.undo, ordinary.undo); XCTAssertEqual(prepared.redo, ordinary.redo)
        }
        print("WORKFLOW_UNDO_MATCH_5000_SECONDS \(matching)")
        print("WORKFLOW_UNDO_CONSTRUCT_5000_SECONDS \(constructing)")
        // Timing observations are not a flaky performance assertion or release guarantee.
    }
}

extension FreshLocalActivityTests {
    func testPreparedUndoKeepsNonstandardCaptureMetadataOnOrdinaryPath() throws {
        let original = seed(), source = UUID()
        var changes = workflowChanges(); changes[0].baseline = [:]
        let plan = try XCTUnwrap(try LocalActivityCreation.Preparation(changes: changes, snapshot: original, source: source, account: account, labels: [], cache: nil, at: now))
        let admission = try XCTUnwrap(plan.admit(changes, source: source, account: account, cache: nil))
        XCTAssertFalse(admission.canRetainCapturedChanges)
        XCTAssertNil(admission.editHistory(matching: admission.changes, source: source, account: account))
        XCTAssertEqual(EditHistory(changes: admission.changes, snapshot: original).undo.count, 1)
    }
}


extension FreshLocalActivityTests {
    func testRetainedWorkflowTablesAdmitPreparedEncodingAfterFinalProjection() throws {
        let original = seed(), changes = workflowChanges(), source = UUID()
        let plan = try XCTUnwrap(try LocalActivityCreation.Preparation(changes: changes, snapshot: original, source: source, account: account, labels: [], cache: nil, at: now))
        let admission = try XCTUnwrap(plan.admit(changes, source: source, account: account, cache: nil))
        let encoded = try XCTUnwrap(admission.encodedCache)
        var (actual, entries) = finalEntries(admission.changes, seed: original)
        var expected = actual
        XCTAssertTrue(LocalActivityCreation.record(entries, snapshot: &expected, account: account))
        WidgetCompletion.prepare(&expected)
        XCTAssertTrue(admission.apply(to: &actual, source: source, account: account, retainingValidatedCommands: true))
        XCTAssertEqual(actual.widgetCompletion.states.mapValues(\.signature), expected.widgetCompletion.states.mapValues(\.signature))
        // New widget tokens and assignment transport nonces are random; all
        // projected rows, private metadata and signatures must otherwise match
        // the independent ordinary projection/recording path byte for byte.
        expected.widgetCompletion.states = actual.widgetCompletion.states
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(withoutProvenanceNonces(actual)), try encoder.encode(withoutProvenanceNonces(expected)))
        let widgetStates = actual.widgetCompletion
        WidgetCompletion.prepare(&actual)
        XCTAssertEqual(actual.widgetCompletion, widgetStates, "Final preparation must preserve the worker's exact completion tokens")
        let bytes = try XCTUnwrap(encoded.matching(actual))
        let saved = try JSONDecoder().decode(Snapshot.self, from: bytes)
        XCTAssertEqual(saved, actual)
        XCTAssertEqual(saved.tables["tasks"], actual.tables["tasks"])
        XCTAssertEqual(actual.tables["tasks"]?.count, original.tables["tasks", default: []].count + changes.count)
        actual.sharedCaptureReceipts = ["new": "receipt"]
        XCTAssertNil(try encoded.matching(actual), "Late receipt staging must force ordinary encoding")
        var unchanged = original
        XCTAssertFalse(admission.apply(to: &unchanged, source: UUID(), account: account, retainingValidatedCommands: true))
        XCTAssertEqual(unchanged, original)
    }
}


extension FreshLocalActivityTests {
    func testWorkerProjectionAdoptsCompleteRowsWithoutASecondAppendPass() throws {
        let original = seed(), changes = workflowChanges(), source = UUID()
        let plan = try XCTUnwrap(try LocalActivityCreation.Preparation(changes: changes, snapshot: original, source: source, account: account, labels: [], cache: nil, at: now))
        let admission = try XCTUnwrap(plan.admit(changes, source: source, account: account, cache: nil))
        XCTAssertTrue(admission.canAdoptProjectedCreation)
        var actual = original
        XCTAssertTrue(admission.apply(to: &actual, source: source, account: account, retainingValidatedCommands: true))
        var (expected, entries) = finalEntries(admission.changes, seed: original)
        XCTAssertTrue(LocalActivityCreation.record(entries, snapshot: &expected, account: account))
        WidgetCompletion.prepare(&expected)
        XCTAssertEqual(actual.widgetCompletion.states.mapValues(\.signature), expected.widgetCompletion.states.mapValues(\.signature))
        expected.widgetCompletion = actual.widgetCompletion
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(withoutProvenanceNonces(actual)), try encoder.encode(withoutProvenanceNonces(expected)))
        XCTAssertEqual(actual.tables["tasks"]?.count, changes.count)
        XCTAssertEqual(try metadata(original), try metadata(seed()), "Capturing/adopting must leave the prior snapshot immutable")
        XCTAssertNotNil(try admission.encodedCache?.matching(actual))
    }
    func testEncodingFailureCannotAuthorizeSkippingOrdinaryProjection() throws {
        var original = seed()
        original.tables["future"] = [Record(["id": .string("unknown"), "invalid": .number(.nan)])]
        let changes = workflowChanges(), source = UUID()
        let plan = try XCTUnwrap(try LocalActivityCreation.Preparation(changes: changes, snapshot: original, source: source, account: account, labels: [], cache: nil, at: now))
        let admission = try XCTUnwrap(plan.admit(changes, source: source, account: account, cache: nil))
        XCTAssertTrue(admission.canRetainCapturedChanges)
        XCTAssertFalse(admission.canAdoptProjectedCreation)
        XCTAssertNil(admission.encodedCache)
        var ordinary = original, fresh = try XCTUnwrap(FreshWorkflowCreation(admission.changes, snapshot: original, account: account))
        for change in admission.changes { XCTAssertNotNil(fresh.append(change, to: &ordinary)) }
        XCTAssertEqual(ordinary.tables["tasks"]?.count, changes.count)
        XCTAssertThrowsError(try JSONEncoder().encode(ordinary), "The normal durable-save error remains visible; no rows may be presented as saved")
    }
    func testRejectedProjectionLeavesEveryTableUntouchedForOrdinaryReplay() throws {
        let original = seed(), changes = workflowChanges(), source = UUID()
        let plan = try XCTUnwrap(try LocalActivityCreation.Preparation(changes: changes, snapshot: original, source: source, account: account, labels: [], cache: nil, at: now))
        let admission = try XCTUnwrap(plan.admit(changes, source: source, account: account, cache: nil))
        for wrongOwner in [false, true] {
            var unchanged = original
            XCTAssertFalse(admission.apply(to: &unchanged, source: wrongOwner ? source : UUID(), account: wrongOwner ? "other" : account, retainingValidatedCommands: true))
            XCTAssertEqual(unchanged, original)
        }
        var replayed = original, fresh = try XCTUnwrap(FreshWorkflowCreation(admission.changes, snapshot: original, account: account))
        for change in admission.changes { XCTAssertNotNil(fresh.append(change, to: &replayed)) }
        XCTAssertEqual(replayed.tables["tasks"]?.count, changes.count)
        var edited = changes; edited[0].fields["description"] = .string("e\u{301}")
        XCTAssertNil(plan.admit(edited, source: source, account: account, cache: nil), "Raw edited commands cannot inherit the projection capability")
    }
    func testProjectOnlyWorkerProjectionIsCompleteWithoutTaskHistoryEntries() throws {
        let original = seed(), source = UUID(), run = UUID(), project = UUID().uuidString.lowercased()
        let change = Mutation(table: "projects", recordID: project, method: "POST", fields: ["id": .string(project), "user_id": .string(account), "name": .string("Project-only workflow")], insertOnly: true, workflowRun: run)
        let changes = [change]
        let plan = try XCTUnwrap(try LocalActivityCreation.Preparation(changes: changes, snapshot: original, source: source, account: account, labels: [], cache: nil, at: now))
        let admission = try XCTUnwrap(plan.admit(changes, source: source, account: account, cache: nil))
        XCTAssertTrue(admission.canAdoptProjectedCreation)
        var adopted = original
        XCTAssertTrue(admission.apply(to: &adopted, source: source, account: account, retainingValidatedCommands: true))
        XCTAssertEqual(adopted.tables["projects"]?.map(\.id), [project])
        XCTAssertEqual(try metadata(adopted), try metadata(original))
        var fallback = original
        XCTAssertFalse(admission.apply(to: &fallback, source: UUID(), account: account, retainingValidatedCommands: true))
        var fresh = try XCTUnwrap(FreshWorkflowCreation(admission.changes, snapshot: fallback, account: account))
        for command in admission.changes { XCTAssertNotNil(fresh.append(command, to: &fallback)) }
        XCTAssertTrue(LocalActivityCreation.record([], snapshot: &fallback, account: account))
        XCTAssertEqual(fallback.tables["projects"]?.map(\.id), [project], "An empty task-history list is not proof that the project's row was created")
        XCTAssertEqual(EditHistory(changes: admission.changes, snapshot: original).undo.count, 1)
    }
}
