import XCTest
@testable import TaskfoldCore

final class WidgetSignatureCacheTests: XCTestCase {
    private func scope(account: String = "local", generation: UUID = UUID(), session: UUID = UUID(), access: UUID = UUID()) -> WidgetCompletion.SignatureCache.Scope {
        .init(workspace: .init(account: account, generation: generation), session: session, access: access)
    }
    private func seed() -> Snapshot {
        var rows = (0..<3).map { _ in Record.task(user: "local", createdAt: "2026-11-01T10:00:00Z") }
        for i in rows.indices { rows[i]["title"] = .string("Task \(i)") }
        return Snapshot(tables: ["tasks": rows])
    }
    private func signatures(_ snapshot: Snapshot) -> [String: String] { snapshot.widgetCompletion.states.mapValues(\.signature) }
    private func equalToReference(_ current: Snapshot, cache: WidgetCompletion.SignatureCache, scope: WidgetCompletion.SignatureCache.Scope) {
        var actual = current, reference = current
        WidgetCompletion.prepare(&reference)
        WidgetCompletion.prepare(&actual, signatures: cache, scope: scope)
        XCTAssertEqual(signatures(actual), signatures(reference))
    }
    func testRepeatedUnchangedPreparationPreservesTokensAndReusesHashes() {
        var value = seed(); let cache = WidgetCompletion.SignatureCache(), context = scope()
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        XCTAssertEqual(cache.statistics.computed, 3)
        let before = value
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        XCTAssertEqual(cache.statistics.reused, 3); XCTAssertEqual(cache.statistics.computed, 0)
        XCTAssertEqual(value, before)
    }
    func testEveryRelevantFieldChangeMatchesUncachedPreparation() {
        let changes: [String: JSON] = ["completed": .bool(true), "created_at": .string("2026-11-02T10:00:00Z"), "completed_at": .string("2026-11-03T10:00:00Z"), "completion_version": .number(1), "task_generation": .string("another-generation"), "is_heading": .bool(true)]
        for (field, next) in changes {
            var value = seed(); let cache = WidgetCompletion.SignatureCache(), context = scope()
            WidgetCompletion.prepare(&value, signatures: cache, scope: context)
            value.tables["tasks"]![0][field] = next
            equalToReference(value, cache: cache, scope: context)
            XCTAssertEqual(cache.statistics.computed, 1, field); XCTAssertEqual(cache.statistics.reused, 2, field)
        }
    }
    func testUnrelatedFieldEditStillRetainsExistingCompletionToken() {
        var value = seed(); let cache = WidgetCompletion.SignatureCache(), context = scope()
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        let before = value.widgetCompletion
        value.tables["tasks"]![0]["title"] = .string("Edited title")
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        XCTAssertEqual(cache.statistics.computed, 1)
        XCTAssertEqual(value.widgetCompletion, before)
    }
    func testFreshDecodedRecordsRequireNewProofEvenWithSameFields() throws {
        var value = seed(); let cache = WidgetCompletion.SignatureCache(), context = scope()
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        let prior = value.widgetCompletion
        value = try TaskfoldJSONDecoder().decode(Snapshot.self, from: TaskfoldJSONEncoder().encode(value))
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        XCTAssertEqual(cache.statistics.computed, 3); XCTAssertEqual(cache.statistics.reused, 0)
        XCTAssertEqual(value.widgetCompletion, prior)
    }
    func testWorkspaceSessionAndAccessChangesInvalidateAllMemoEntries() {
        let original = scope()
        for changed in [scope(account: "other", generation: original.workspace.generation, session: original.session, access: original.access), scope(generation: UUID(), session: original.session, access: original.access), scope(generation: original.workspace.generation, session: UUID(), access: original.access), scope(generation: original.workspace.generation, session: original.session, access: UUID())] {
            var value = seed(); let cache = WidgetCompletion.SignatureCache()
            WidgetCompletion.prepare(&value, signatures: cache, scope: original)
            WidgetCompletion.prepare(&value, signatures: cache, scope: changed)
            XCTAssertEqual(cache.statistics.reused, 0); XCTAssertEqual(cache.statistics.computed, 3)
        }
    }
    func testMissingScopeCannotReuseOrRetainEntries() {
        var value = seed(); let cache = WidgetCompletion.SignatureCache()
        WidgetCompletion.prepare(&value, signatures: cache, scope: scope())
        WidgetCompletion.prepare(&value, signatures: cache)
        XCTAssertEqual(cache.statistics.reused, 0); XCTAssertEqual(cache.statistics.computed, 3); XCTAssertEqual(cache.statistics.retained, 0)
    }
    func testEntryLimitAndDeletedRootsDoNotRetainOldMemoEntries() {
        var value = seed(); let cache = WidgetCompletion.SignatureCache(maximumEntries: 1), context = scope()
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        XCTAssertEqual(cache.statistics.retained, 1)
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        XCTAssertEqual(cache.statistics.reused, 1); XCTAssertEqual(cache.statistics.computed, 2)
        value.tables["tasks"] = []
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        XCTAssertEqual(cache.statistics.retained, 0); XCTAssertTrue(value.widgetCompletion.states.isEmpty)
    }
    func testTamperedWidgetStateCannotCertifyItselfOnMemoHit() {
        var value = seed(); let cache = WidgetCompletion.SignatureCache(), context = scope()
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        let id = value.tables["tasks"]![0].id.lowercased(), expected = value.widgetCompletion.states[id]!.signature
        value.widgetCompletion.states[id] = .init(token: "tampered", signature: "incorrect")
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        XCTAssertEqual(cache.statistics.reused, 3)
        XCTAssertEqual(value.widgetCompletion.states[id]?.signature, expected)
        XCTAssertNotEqual(value.widgetCompletion.states[id]?.token, "tampered")
    }
    func testRollbackAfterUncommittedPreparationKeepsOriginalState() {
        var original = seed(); let cache = WidgetCompletion.SignatureCache(), context = scope()
        WidgetCompletion.prepare(&original, signatures: cache, scope: context)
        var proposed = original; proposed.tables["tasks"]![0]["completed"] = .bool(true)
        WidgetCompletion.prepare(&proposed, signatures: cache, scope: context)
        var rolledBack = original
        WidgetCompletion.prepare(&rolledBack, signatures: cache, scope: context)
        XCTAssertEqual(rolledBack, original)
    }
    func testDuplicateIDsStillFollowUncachedFinalSignature() {
        var value = seed(); value.tables["tasks"]![1]["id"] = value.tables["tasks"]![0]["id"]
        value.tables["tasks"]![1]["completed"] = .bool(true)
        let cache = WidgetCompletion.SignatureCache(), context = scope()
        equalToReference(value, cache: cache, scope: context)
        equalToReference(value, cache: cache, scope: context)
    }
    func testRefreshedRowsRetainOnlyProvenMemoHits() throws {
        var value = seed(); let cache = WidgetCompletion.SignatureCache(), context = scope()
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        var remote = try TaskfoldJSONDecoder().decode(Snapshot.self, from: TaskfoldJSONEncoder().encode(value)).tables
        remote["tasks"]![0]["due_date"] = .string("2026-11-10")
        value.mergeRemote(remote)
        equalToReference(value, cache: cache, scope: context)
        XCTAssertEqual(cache.statistics.reused, 2); XCTAssertEqual(cache.statistics.computed, 1)
    }
    func testExplicitPrivacyClearDropsEveryMemoEntry() {
        var value = seed(); let cache = WidgetCompletion.SignatureCache(), context = scope()
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        cache.clear()
        XCTAssertEqual(cache.statistics.retained, 0)
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        XCTAssertEqual(cache.statistics.reused, 0); XCTAssertEqual(cache.statistics.computed, 3)
    }
    func testOversizedIDsUseReferencePathWithoutRetainingThem() {
        var value = seed(); value.tables["tasks"]![0]["id"] = .string(String(repeating: "x", count: 1024))
        let cache = WidgetCompletion.SignatureCache(), context = scope()
        equalToReference(value, cache: cache, scope: context)
        XCTAssertEqual(cache.statistics.retained, 2)
        equalToReference(value, cache: cache, scope: context)
        XCTAssertEqual(cache.statistics.computed, 1); XCTAssertEqual(cache.statistics.reused, 2)
    }
    func testChildEditsAndFilterRemovalStillRevalidateWithRootMemo() throws {
        var root = Record.task(user: "local", project: "p", createdAt: "2026-11-01T10:00:00Z")
        root["id"] = .string("root")
        root["subtasks"] = .array([.object(["id": .string("child"), "title": .string("Review"), "completed": .bool(false)])])
        var value = Snapshot(tables: ["tasks": [root], "projects": [Record(["id": .string("p"), "name": .string("Studio")])],
            "saved_views": [Record(["id": .string("children"), "query_ast": FilterRule.predicate("subtask", "").document])]])
        let cache = WidgetCompletion.SignatureCache(), context = scope()
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        let child = try XCTUnwrap(value.widgetCompletion.states.keys.first { $0.hasPrefix("subtask:") })
        let old = value.widgetCompletion.states[child]!
        value.tables["tasks"]![0]["subtasks"] = .array([.object(["id": .string("child"), "title": .string("Revised review"), "completed": .bool(false)])])
        var reference = value; WidgetCompletion.prepare(&reference)
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        XCTAssertEqual(signatures(value), signatures(reference))
        XCTAssertNotEqual(value.widgetCompletion.states[child]?.token, old.token)
        value.tables["saved_views"] = []
        WidgetCompletion.prepare(&value, signatures: cache, scope: context)
        XCTAssertEqual(cache.statistics.reused, 1)
        XCTAssertNil(value.widgetCompletion.states[child])
    }
    func testPreparationDiagnosticWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["TASKFOLD_WIDGET_SIGNATURE_REPORT"] else { throw XCTSkip("Explicit signature diagnostic") }
        let source = RemoteRowReuseTests.refreshFixture(), encoder = TaskfoldJSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let wire = try encoder.encode(source), context = scope()
        var report: [[String: Any]] = []
        for pass in 0..<3 {
            var outputs: [String: Data] = [:], timings: [String: Double] = [:]
            var lastStatistics: WidgetCompletion.SignatureCache.Statistics?
            for useMemo in (pass % 2 == 0 ? [false, true] : [true, false]) {
                let disk = DurableSnapshotReadCache(minimumFieldEncodingBytes: 0), cache = WidgetCompletion.SignatureCache()
                var current = try disk.decode(wire)
                XCTAssertTrue(disk.adoptRows(try DurableSnapshotReadCache.prepareRows(try XCTUnwrap(disk.rowPreparationRequest()))))
                WidgetCompletion.prepare(&current, signatures: useMemo ? cache : nil, scope: context)
                _ = try disk.encode(current)
                var remote = try TaskfoldJSONDecoder().decode(Snapshot.self, from: wire).tables
                remote["tasks"]![0]["due_date"] = .string("2026-11-\(pass + 10)")
                let started = ProcessInfo.processInfo.systemUptime
                current.mergeRemote(remote)
                WidgetCompletion.prepare(&current, signatures: useMemo ? cache : nil, scope: context)
                let saved = try disk.encode(current)
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                let name = useMemo ? "memo" : "reference"
                timings[name] = elapsed
                outputs[name] = try encoder.encode(TaskfoldJSONDecoder().decode(Snapshot.self, from: saved))
                if useMemo { lastStatistics = cache.statistics }
            }
            XCTAssertEqual(outputs["memo"], outputs["reference"])
            XCTAssertEqual(lastStatistics?.reused, 2003); XCTAssertEqual(lastStatistics?.computed, 1)
            report.append(["referenceSeconds": timings["reference"]!, "memoSeconds": timings["memo"]!, "computed": lastStatistics!.computed, "reused": lastStatistics!.reused, "exactOutput": true])
        }
        try JSONSerialization.data(withJSONObject: ["rows": 2004, "passes": report, "scope": "Primed refresh merge/widget metadata/encoding; transport/decode/disk/UI excluded", "configuration": "SwiftPM Debug", "physicalFPSClaim": false], options: [.sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
