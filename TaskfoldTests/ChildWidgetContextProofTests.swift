import XCTest
@testable import TaskfoldCore

final class ChildWidgetContextProofTests: XCTestCase {
    private func root(_ id: String = "root") -> Record {
        var row = Record.task(user: "local", project: "p", createdAt: "2026-11-01T10:00:00Z")
        row["id"] = .string(id)
        row["subtasks"] = .array([.object(["id": .string("child"), "title": .string("Review"), "completed": .bool(false), "description": .string("Keep the exact notes")])])
        return row
    }
    private func snapshot(_ roots: [Record]) -> Snapshot {
        Snapshot(tables: ["tasks": roots, "projects": [Record(["id": .string("p"), "name": .string("Studio")]), Record(["id": .string("q"), "name": .string("Other")])], "saved_views": [Record(["id": .string("children"), "query_ast": FilterRule.predicate("subtask", "").document])]])
    }
    private func scope() -> WidgetCompletion.SignatureCache.Scope { .init(workspace: .init(account: "local", generation: UUID()), session: UUID(), access: UUID()) }
    func testUnrelatedSubscriptWritesKeepOnlyTheChildProof() {
        let original = root()
        for field in ["title", "description", "due_date", "due_time", "time_zone", "priority", "labels", "completed", "completed_at", "completion_version", "user_id", "opaque_root"] {
            var row = original; row[field] = .string("changed")
            XCTAssertNotEqual(row.authoredSourceToken, original.authoredSourceToken, field)
            XCTAssertEqual(row.widgetChildSignatureSourceToken, original.widgetChildSignatureSourceToken, field)
        }
    }
    func testEveryChildOrRoutingWriteInvalidatesEvenWhenTheValueIsEqual() {
        let original = root()
        for field in ["id", "subtasks", "task_generation", "created_at", "project_id", "section_id"] {
            var row = original; row[field] = original[field]
            XCTAssertNotEqual(row.widgetChildSignatureSourceToken, original.widgetChildSignatureSourceToken, field)
            row = original; row.mergeFields([field: original[field]])
            XCTAssertNotEqual(row.widgetChildSignatureSourceToken, original.widgetChildSignatureSourceToken, field)
        }
    }
    func testDirectDictionaryMutationAlwaysTakesTheConservativePath() {
        let original = root()
        var row = original; row.fields["title"] = .string("Direct")
        XCTAssertNotEqual(row.widgetChildSignatureSourceToken, original.widgetChildSignatureSourceToken)
        row = original; row.fields.merge(["due_date": .string("2026-11-10")]) { _, value in value }
        XCTAssertNotEqual(row.widgetChildSignatureSourceToken, original.widgetChildSignatureSourceToken)
        row = original; row.fields.removeValue(forKey: "title")
        XCTAssertNotEqual(row.widgetChildSignatureSourceToken, original.widgetChildSignatureSourceToken)
        row = original; row.fields = original.fields
        XCTAssertNotEqual(row.widgetChildSignatureSourceToken, original.widgetChildSignatureSourceToken)
    }
    func testControlledMergeKeepsValuesAndInvalidatesMixedCriticalInputs() {
        let original = root(); var row = original
        let changes: [String: JSON] = ["due_date": .string("2026-11-10"), "opaque_root": .object(["future": .bool(true)])]
        row.mergeFields(changes)
        XCTAssertEqual(row.fields, original.fields.merging(changes) { _, value in value })
        XCTAssertEqual(row.widgetChildSignatureSourceToken, original.widgetChildSignatureSourceToken)
        row.mergeFields(["description": .string("Later"), "section_id": .string("new")])
        XCTAssertNotEqual(row.widgetChildSignatureSourceToken, original.widgetChildSignatureSourceToken)
    }
    func testOrdinaryCompletionRevisionMergePreservesChildContextForDateEdits() {
        let original = root(), edited = TaskCompletionRevision.applying(["due_date": .string("2026-11-10")], to: root())
        let actual = TaskCompletionRevision.applying(["due_date": .string("2026-11-10")], to: original)
        XCTAssertEqual(actual.widgetChildSignatureSourceToken, original.widgetChildSignatureSourceToken)
        XCTAssertEqual(actual["subtasks"], original["subtasks"]); XCTAssertEqual(actual.string("due_date"), "2026-11-10")
        XCTAssertNotEqual(edited.widgetChildSignatureSourceToken, original.widgetChildSignatureSourceToken)
        XCTAssertNotEqual(TaskCompletionRevision.applying(["project_id": .string("q")], to: original).widgetChildSignatureSourceToken, original.widgetChildSignatureSourceToken)
    }
    func testDecodingCreatesFreshProofWithoutEncodingPrivateMetadata() throws {
        var original = root(); original["title"] = .string("Changed")
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(original), decoded = try TaskfoldJSONDecoder().decode(Record.self, from: bytes)
        XCTAssertNotEqual(decoded.widgetChildSignatureSourceToken, original.widgetChildSignatureSourceToken)
        XCTAssertEqual(try encoder.encode(decoded), bytes)
        XCTAssertEqual(Set(try TaskfoldJSONDecoder().decode(JSON.self, from: bytes).object.keys), Set(original.fields.keys))
    }
    func testCachedDateChangeMatchesReferenceAndKeepsOldWidgetTokens() throws {
        var value = snapshot([root()]); let cache = WidgetCompletion.SignatureCache(), context = scope()
        WidgetCompletion.prepare(&value, signatures: cache, scope: context); let before = value.widgetCompletion
        let old = try XCTUnwrap(value.tables["tasks"]?.first)
        let delta = TaskCompletionRevision.capturing(Mutation(table: "tasks", recordID: old.id, method: "PATCH", fields: ["due_date": .string("2026-11-10")]), existing: old)
        value.apply(delta); XCTAssertEqual(value.tables["tasks"]?.first?.string("due_date"), "2026-11-10")
        var reference = value; WidgetCompletion.prepare(&reference)
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        XCTAssertEqual(cache.statistics.computed, 1); XCTAssertEqual(cache.statistics.reused, 1)
        XCTAssertEqual(value.widgetCompletion, reference.widgetCompletion); XCTAssertEqual(value.widgetCompletion, before)
    }
    func testLegacySignatureFormatAndTokensAreUnchanged() throws {
        var value = snapshot([root()]); let item = try XCTUnwrap(WidgetCompletion.childItems(value, account: "local").first)
        var own = item.source.fields; own.removeValue(forKey: "subtasks")
        let values: [JSON] = [.string(item.id), .object(own), item.root["task_generation"], item.root["created_at"], item.root["project_id"], item.root["section_id"]]
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = .sortedKeys
        let legacy = DueReminder.digest(String(decoding: try encoder.encode(values), as: UTF8.self)), token = UUID().uuidString.lowercased()
        value.widgetCompletion.states[item.id] = .init(token: token, signature: legacy)
        WidgetCompletion.prepare(&value, signatures: WidgetCompletion.SignatureCache(), scope: scope())
        XCTAssertEqual(value.widgetCompletion.states[item.id]?.signature, legacy); XCTAssertEqual(value.widgetCompletion.states[item.id]?.token, token)
    }
    func testCurrentActionStillRevalidatesChildContentsAndScope() throws {
        var value = snapshot([root()]); let cache = WidgetCompletion.SignatureCache(), context = scope()
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        let child = try XCTUnwrap(WidgetCompletion.childItems(value, account: "local").first)
        let request = try WidgetCompletionRequest(account: "local", taskID: child.id, token: XCTUnwrap(value.widgetCompletion.states[child.id]?.token), at: Date(timeIntervalSince1970: 1_790_000_000))
        value.tables["tasks"]![0]["due_date"] = .string("2026-11-10")
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        guard case .complete = WidgetCompletion.plan(request, snapshot: value, account: "local") else { return XCTFail("A date edit changed an otherwise current child action") }
        guard case .stale = WidgetCompletion.plan(request, snapshot: value, account: "other") else { return XCTFail("Wrong-account child action accepted") }
        value.tables["tasks"]![0]["subtasks"] = SubtaskTree.changing(value.tables["tasks"]![0]["subtasks"], id: "child", fields: ["description": .string("Changed")])
        guard case .stale = WidgetCompletion.plan(request, snapshot: value, account: "local") else { return XCTFail("A stale child action bypassed current-data validation") }
    }
    func testEveryRoutingChangeStillMatchesUncachedSignatures() throws {
        for (field, next) in [("id", "new-root"), ("task_generation", UUID().uuidString.lowercased()), ("created_at", "2026-11-02T10:00:00Z"), ("project_id", "q"), ("section_id", "new-section")] {
            var value = snapshot([root()]); let cache = WidgetCompletion.SignatureCache(), context = scope()
            WidgetCompletion.prepare(&value, signatures: cache, scope: context)
            let oldChild = try XCTUnwrap(WidgetCompletion.childItems(value, account: "local").first)
            let token = try XCTUnwrap(value.widgetCompletion.states[oldChild.id]?.token)
            value.tables["tasks"]![0][field] = .string(next)
            var reference = value; WidgetCompletion.prepare(&reference)
            WidgetCompletion.prepare(&value, signatures: cache, scope: context)
            XCTAssertEqual(value.widgetCompletion.states.mapValues(\.signature), reference.widgetCompletion.states.mapValues(\.signature), field)
            let newChild = try XCTUnwrap(WidgetCompletion.childItems(value, account: "local").first)
            XCTAssertNotEqual(value.widgetCompletion.states[newChild.id]?.token, token, field)
        }
    }
    func testCurrentVisibilityIsRebuiltAfterAProofPreservingDateEdit() throws {
        var value = snapshot([root()]); let cache = WidgetCompletion.SignatureCache(), context = scope()
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        let id = try XCTUnwrap(WidgetCompletion.childItems(value, account: "local").first?.id)
        value.tables["tasks"]![0]["due_date"] = .string("2026-11-10")
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        XCTAssertEqual(cache.statistics.reused, 1)
        value.tables["projects"]![0]["is_archived"] = .bool(true)
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        XCTAssertNil(value.widgetCompletion.states[id]); XCTAssertEqual(cache.statistics.retained, 1)
        value.tables["projects"]![0]["is_archived"] = .bool(false)
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        XCTAssertNotNil(value.widgetCompletion.states[id]); XCTAssertEqual(cache.statistics.computed, 1)
    }
    func testCounterbalancedBatchPreparationWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["TASKFOLD_CHILD_CONTEXT_REPORT"] else { throw XCTSkip("Explicit batch preparation diagnostic") }
        let roots = (0..<100).map { index -> Record in
            var row = root("root-\(index)")
            row["subtasks"] = .array((0..<20).map { child in .object(["id": .string("child-\(child)"), "title": .string("Review"), "completed": .bool(false), "description": .string(String(repeating: "Review the current layout. ", count: 20))]) })
            return row
        }
        let source = snapshot(roots), context = scope(); var samples: [[String: Any]] = []
        for pass in 0..<5 {
            for retain in (pass.isMultiple(of: 2) ? [true, false] : [false, true]) {
                var value = source; let cache = WidgetCompletion.SignatureCache()
                WidgetCompletion.prepare(&value, signatures: cache, scope: context); let original = value.widgetCompletion
                for row in roots {
                    value.apply(TaskCompletionRevision.capturing(Mutation(table: "tasks", recordID: row.id, method: "PATCH", fields: ["due_date": .string("2026-11-10")]), existing: row))
                }
                XCTAssertTrue(value.tables["tasks"]!.allSatisfy { $0.string("due_date") == "2026-11-10" })
                // Rewrapping outside timing discards the narrower proof. Every
                // root changed, so this computes the prior full-root policy.
                if !retain { value.tables["tasks"] = value.tables["tasks"]!.map { Record($0.fields) } }
                let start = ProcessInfo.processInfo.systemUptime
                WidgetCompletion.prepare(&value, signatures: cache, scope: context)
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                var reference = value; WidgetCompletion.prepare(&reference)
                XCTAssertEqual(value.widgetCompletion, reference.widgetCompletion); XCTAssertEqual(value.widgetCompletion, original)
                XCTAssertEqual(cache.statistics.computed, retain ? 100 : 2100); XCTAssertEqual(cache.statistics.reused, retain ? 2000 : 0)
                samples.append(["pass":pass,"retainedChildProof":retain,"seconds":elapsed,"computed":cache.statistics.computed,"reused":cache.statistics.reused])
            }
        }
        let report: [String: Any] = ["scope":"Same Debug executable, counterbalanced child-context proof versus discarded-proof full-root invalidation; widget preparation only, not old/new app Save or UI/FPS", "roots":100,"children":2000,"samples":samples,"exactReferenceStatesAndTokens":true]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys,.prettyPrinted]).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
