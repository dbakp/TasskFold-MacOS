import XCTest
@testable import TaskfoldCore

final class ChildDuplicateHistoryTests: XCTestCase {
    func testHistoryChoiceIsExplicitAndPositionBound() throws {
        let change = try ChildTaskRepairChange(.separateDuplicate, path: [1], reference: "fresh", keepPath: [0])
        XCTAssertEqual(change.raw["keep_path"], .array([.number(0)]))
        XCTAssertThrowsError(try ChildTaskRepairChange(.separateDuplicate, path: [1], reference: "fresh"))
        XCTAssertThrowsError(try ChildTaskRepairChange(.separateDuplicate, path: [1], reference: "fresh", keepPath: [1]))
        XCTAssertThrowsError(try ChildTaskRepairChange(.separateDuplicate, path: [1], reference: "fresh", keepPath: []))
        XCTAssertThrowsError(try ChildTaskRepairChange(.separateDuplicate, path: [1], reference: "fresh", keepPath: [-1]))
        XCTAssertThrowsError(try ChildTaskRepairChange(.separateDuplicate, path: [1], reference: "fresh", keepPath: Array(repeating: 0, count: 65)))
        var unknown = change.raw; unknown["copy_history"] = .bool(true)
        XCTAssertThrowsError(try ChildTaskRepairChange(raw: unknown))
    }
    func testKeeperOptionsUseCanonicalReferenceAndNeverTaskNames() throws {
        let outline = try ChildTaskRepairOutline(data: Data(#"[{"id":"é","title":"Same name"},{"id":"e\u0301","title":"Other name"},{"id":"unrelated","title":"Same name"},{"title":"Other name"}]"#.utf8))
        XCTAssertEqual(outline.historyKeepers(for: outline.items[0]).map(\.path), [[1]])
        XCTAssertEqual(outline.historyKeepers(for: outline.items[1]).map(\.path), [[0]])
        XCTAssertTrue(outline.historyKeepers(for: outline.items[2]).isEmpty)
        XCTAssertTrue(outline.historyKeepers(for: outline.items[3]).isEmpty)
    }
    func fixture() throws -> [String: JSON] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "duplicate-history", withExtension: "json", subdirectory: "Fixtures"))
        return try TaskfoldJSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
    }
    func preview(_ f: [String: JSON], changing: ((inout [String: JSON]) -> Void)? = nil) throws -> ChildTaskRepairPreview {
        let account = f["command"]!.object["account"]!.text
        let context = try ChildTaskRecordContext(account: account, origin: "https://repair.test", workspace: UUID(), session: UUID(), access: UUID(), snapshot: UUID(), root: Record(f["root"]!.object))
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let review = try ChildTaskAdoptionReview(data: encoder.encode(f["review"]!), context: context, workspaceID: nil)
        var raw = f["preview"]!.object; changing?(&raw)
        return try ChildTaskRepairPreview(data: encoder.encode(raw), review: review, changes: f["changes"]!.list.map { try ChildTaskRepairChange(raw: $0.object) })
    }
    func testActualDatabaseProofReadsAndDurableRequestRetainsTheChoice() throws {
        let f = try fixture(), p = try preview(f)
        XCTAssertTrue(p.eligible); XCTAssertEqual(p.historyRetention.count, 1)
        let retained = try XCTUnwrap(p.historyRetention.first)
        XCTAssertEqual(retained.path, [0]); XCTAssertGreaterThan(retained.eventCount, 0); XCTAssertEqual(retained.completedCount, 1)
        let command = try ChildTaskRepairCommand(preview: p, requestID: XCTUnwrap(UUID(uuidString: f["command"]!.object["request_id"]!.text)))
        XCTAssertEqual(command.body["changes"], f["command"]!.object["changes"])
        XCTAssertEqual(command.body["repair_digest"], f["command"]!.object["repair_digest"])
        XCTAssertEqual(try ChildTaskRepairCommand(data: TaskfoldJSONEncoder().encode(command)), command)
        let invalid = try TaskfoldJSONEncoder().encode(command)
        let fractional = Data(String(decoding: invalid, as: UTF8.self).replacingOccurrences(of: "\"keep_path\":[0]", with: "\"keep_path\":[0.5]").utf8)
        XCTAssertNotEqual(invalid, fractional); XCTAssertThrowsError(try ChildTaskRepairCommand(data: fractional))
    }
    func testMissingOrChangedConsentProofCannotBecomeASaveablePreview() throws {
        let f = try fixture()
        XCTAssertThrowsError(try preview(f) { $0.removeValue(forKey: "history_retention") })
        XCTAssertThrowsError(try preview(f) { $0["history_retention"] = .array([]) })
        for (key,value) in [("ordinal", JSON.number(2)), ("keep_path", .array([.number(1)])), ("event_count", .number(-1)), ("completed_count", .number(1_000_001)), ("digest", .string("invalid"))] {
            XCTAssertThrowsError(try preview(f) { raw in
                var row = raw["history_retention"]!.list[0].object; row[key] = value; raw["history_retention"] = .array([.object(row)])
            })
        }
    }
    func testEveryPriorEventKeepsIdentityVersionAndEffectiveTime() throws {
        let f = try fixture(), parser = TaskNodeActivity.Parser()
        let prior = try f["prior"]!.list.map { try XCTUnwrap(parser.event(Record($0.object))) }
        let after = try f["after"]!.list.map { try XCTUnwrap(parser.event(Record($0.object))) }
        XCTAssertTrue(prior.contains { $0.kinds.contains(.completed) })
        for event in prior { XCTAssertEqual(after.first { $0.id == event.id }, event) }
        XCTAssertFalse(after.contains { $0.nodeKey == "fresh" && $0.kinds.contains(.completed) })
        // Existing coverage gaps remain explicit. Separating a duplicate cannot
        // turn incomplete older history into invented productive credit.
        let epoch = [Record(["id": .string("current"), "recorded_from": .string("2026-10-01T00:00:00Z")])]
        let now = Date.distantFuture
        let beforeReading = ChildWorkReading(.init(rows: f["prior"]!.list.map { Record($0.object) }, epoch: epoch), now: now)
        let afterReading = ChildWorkReading(.init(rows: f["after"]!.list.map { Record($0.object) }, epoch: epoch), now: now)
        XCTAssertTrue(beforeReading.incomplete); XCTAssertTrue(afterReading.incomplete)
        XCTAssertEqual(Set(beforeReading.credits().map(\.taskID)), Set(afterReading.credits().map(\.taskID)))
    }
}
