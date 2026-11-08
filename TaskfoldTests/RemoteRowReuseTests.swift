import XCTest
import CryptoKit
@testable import TaskfoldCore

final class RemoteRowReuseTests: XCTestCase {
    private func fresh(_ rows: [Record]) throws -> [Record] {
        try TaskfoldJSONDecoder().decode([Record].self, from: TaskfoldJSONEncoder().encode(rows))
    }
    private func row(_ id: String, title: String = "Workshop") -> Record { Record(["id": .string(id), "title": .string(title)]) }
    func testExactRefreshKeepsEncodedRowsWithoutReplacingSourceValues() throws {
        let cache = DurableSnapshotReadCache(minimumFieldEncodingBytes: 0)
        var current = try cache.decode(TaskfoldJSONEncoder().encode(Snapshot(tables: ["tasks": [row("a"), row("b")]])))
        let prior = current.tables["tasks"]!
        XCTAssertTrue(cache.adoptRows(try DurableSnapshotReadCache.prepareRows(try XCTUnwrap(cache.rowPreparationRequest()))))
        let remote = try fresh(prior)
        XCTAssertFalse(remote[0].sharesAuthoredSource(with: prior[0]))
        current.mergeRemote(["tasks": remote])
        XCTAssertTrue(AuthoredValueComparison.sameRecordSources(current.tables["tasks"]!, prior))
        let saved = try cache.encode(current)
        XCTAssertEqual(cache.rowEncodingStatistics.reused, 2)
        XCTAssertEqual(cache.rowEncodingStatistics.encoded, 0)
        XCTAssertEqual(try TaskfoldJSONDecoder().decode(Snapshot.self, from: saved), current)
    }
    func testIncomingOrderInsertionsRemovalAndChangedFieldsStayCurrent() throws {
        let prior = [row("a"), row("b"), row("c")]
        var incoming = try fresh([prior[2], prior[0], row("d")])
        incoming[1]["title"] = .string("Changed")
        let result = AuthoredValueComparison.reusingExactRows(incoming, from: prior)
        XCTAssertEqual(result, incoming)
        XCTAssertEqual(result.map(\.id), ["c", "a", "d"])
        XCTAssertTrue(result[0].sharesAuthoredSource(with: prior[2]))
        XCTAssertFalse(result[1].sharesAuthoredSource(with: prior[0]))
        XCTAssertTrue(result[2].sharesAuthoredSource(with: incoming[2]))
    }
    func testSemanticEqualityCannotHideUnicodeOrSignedZeroChanges() throws {
        let old = Record(["id": .string("a"), "title": .string("Café"), "zero": .number(-0.0)])
        for key in ["title", "zero"] {
            var changed = try fresh([old])[0]
            changed[key] = key == "title" ? .string("Cafe\u{301}") : .number(0)
            XCTAssertEqual(changed, old, "Domain equality is deliberately weaker")
            let result = AuthoredValueComparison.reusingExactRows([changed], from: [old])[0]
            XCTAssertFalse(result.sharesAuthoredSource(with: old))
            XCTAssertTrue(AuthoredValueComparison.exactJSON(.object(result.fields), .object(changed.fields)))
        }
    }
    func testCanonicallyEqualIDsNeverAliasCandidateRecords() throws {
        let prior = [row("Café"), row("Cafe\u{301}")]
        let result = AuthoredValueComparison.reusingExactRows(try fresh(prior.reversed()), from: prior)
        XCTAssertTrue(result[0].sharesAuthoredSource(with: prior[1]))
        XCTAssertTrue(result[1].sharesAuthoredSource(with: prior[0]))
    }
    func testAmbiguousOrMissingIdentitiesStayFresh() throws {
        let prior = [row("a"), row("a"), row("b"), Record(["title": .string("No ID")])]
        let incoming = try fresh([prior[0], prior[2], prior[3]])
        let result = AuthoredValueComparison.reusingExactRows(incoming, from: prior)
        XCTAssertFalse(result[0].sharesAuthoredSource(with: prior[0]))
        XCTAssertTrue(result[1].sharesAuthoredSource(with: prior[2]))
        XCTAssertFalse(result[2].sharesAuthoredSource(with: prior[3]))
        let duplicate = try fresh([prior[2], prior[2]])
        let repeated = AuthoredValueComparison.reusingExactRows(duplicate, from: [prior[2]])
        XCTAssertEqual(repeated.count, 2)
        XCTAssertTrue(zip(repeated, duplicate).allSatisfy { $0.sharesAuthoredSource(with: $1) })
    }
    func testPendingWorkStillOverlaysFreshFieldsAndMissingProvenanceIsDropped() throws {
        let original = [row("a"), row("b")]
        var current = Snapshot(tables: ["tasks": original, TaskAssignmentProvenance.table: [Record(["id": .string("old-proof")])]])
        let pending = Mutation(table: "tasks", recordID: "a", method: "PATCH", fields: ["title": .string("Local draft")])
        current.apply(pending); current.pending = [pending]
        var remote = try fresh(original); remote[0]["priority"] = .number(1)
        current.mergeRemote(["tasks": remote])
        XCTAssertEqual(current.pending, [pending])
        XCTAssertEqual(current.tables["tasks"]?[0].title, "Local draft")
        XCTAssertEqual(current.tables["tasks"]?[0].priority, 1)
        XCTAssertTrue(current.tables["tasks"]![1].sharesAuthoredSource(with: original[1]))
        XCTAssertNil(current.tables[TaskAssignmentProvenance.table])
    }
    func testProfilesUseTheirRealPrimaryKeyAndKeepCurrentNames() throws {
        let prior = [Record(["user_id": .string("a"), "display_name": .string("First")]), Record(["user_id": .string("b"), "display_name": .string("Second")])]
        var remote = try fresh(prior); remote[1]["display_name"] = .string("Updated")
        var value = Snapshot(tables: ["profiles": prior]); value.mergeRemote(["profiles": remote])
        XCTAssertTrue(value.tables["profiles"]![0].sharesAuthoredSource(with: prior[0]))
        XCTAssertFalse(value.tables["profiles"]![1].sharesAuthoredSource(with: prior[1]))
        XCTAssertEqual(value.tables["profiles"]?[1].string("display_name"), "Updated")
    }
    func testUnknownOpaqueValuesRemainExactAndNeverGainPlainRowEncoding() throws {
        let data = Data(#"[{"id":"a","future":{"exact":9007199254740993,"huge":1e500,"é":1,"é":2}}]"#.utf8)
        let prior = try TaskfoldJSONDecoder().decode([Record].self, from: data)
        let incoming = try TaskfoldJSONDecoder().decode([Record].self, from: data)
        let result = AuthoredValueComparison.reusingExactRows(incoming, from: prior)
        XCTAssertTrue(result[0].sharesAuthoredSource(with: prior[0]))
        let cache = DurableSnapshotReadCache(minimumFieldEncodingBytes: 0)
        let saved = try cache.encode(Snapshot(tables: ["tasks": result]))
        let decoded = try TaskfoldJSONDecoder().decode(Snapshot.self, from: saved)
        XCTAssertTrue(AuthoredValueComparison.sameRows(decoded.tables["tasks"]!, incoming))
        XCTAssertEqual(cache.rowEncodingStatistics.retained, 0)
    }
    func testRefreshSaveDiagnosticWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["TASKFOLD_REFRESH_ROW_REPORT"] else { throw XCTSkip("Explicit save diagnostic") }
        var source = Snapshot(tables: ["tasks": (0..<2004).map { i in
            var row = Record.task(user: "local", createdAt: "2026-11-01T10:00:00Z")
            row["id"] = .string("task-\(i)")
            row["task_generation"] = .string(String(format: "00000000-0000-0000-0000-%012d", i + 1))
            row["title"] = .string("Task \(i)")
            row["description"] = .string(String(repeating: "Keep these workshop notes. ", count: 8))
            if i == 4 { row["future"] = .string(String(repeating: "Exact synthetic reference. ", count: 80000)) }
            return row
        }])
        WidgetCompletion.prepare(&source)
        for key in source.widgetCompletion.states.keys {
            source.widgetCompletion.states[key]!.token = String(format: "10000000-0000-0000-0000-%012d", Int(key.dropFirst(5))! + 1)
        }
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = .sortedKeys
        let wire = try encoder.encode(source)
        var reports: [[String: Any]] = []
        for pass in 0..<3 {
            let cache = DurableSnapshotReadCache(minimumFieldEncodingBytes: 0)
            var current = try cache.decode(wire)
            XCTAssertTrue(cache.adoptRows(try DurableSnapshotReadCache.prepareRows(try XCTUnwrap(cache.rowPreparationRequest()))))
            _ = try cache.encode(current)
            var remote = try TaskfoldJSONDecoder().decode(Snapshot.self, from: wire).tables
            remote["tasks"]![0]["due_date"] = .string("2026-11-\(pass + 10)")
            let start = ProcessInfo.processInfo.systemUptime
            current.mergeRemote(remote)
            WidgetCompletion.prepare(&current)
            let saved = try cache.encode(current)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let decoded = try TaskfoldJSONDecoder().decode(Snapshot.self, from: saved)
            XCTAssertEqual(try encoder.encode(decoded), try encoder.encode(current))
            XCTAssertEqual(decoded.tables["tasks"]?.count, 2004)
            XCTAssertEqual(decoded.tables["tasks"]?.first?.string("due_date"), "2026-11-\(pass + 10)")
            reports.append(["seconds": elapsed, "rowsReused": cache.rowEncodingStatistics.reused,
                            "rowsEncoded": cache.rowEncodingStatistics.encoded, "exactSavedValues": true])
        }
        let report: [String: Any] = ["rows": 2004, "passes": reports, "fixtureBytes": wire.count,
            "fixtureSHA256": SHA256.hash(data: wire).map { String(format: "%02x", $0) }.joined(),
            "scope": "Merge refreshed tables, prepare widget metadata and encode; transport/decode/disk/UI excluded", "physicalFPSClaim": false]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
