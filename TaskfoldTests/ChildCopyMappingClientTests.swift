import XCTest
import CryptoKit
@testable import TaskfoldCore

final class ChildCopyMappingClientTests: XCTestCase {
    struct Contract {
        let review: ChildTaskAdoptionReview, copies: ChildTaskCopyReview, preview: ChildTaskRepairPreview
        let command: ChildTaskRepairCommand, receipt: ChildTaskRepairResult, original: Data, previewData: Data
    }
    func contract(origin: String = "https://repair.test") throws -> Contract {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "child-copy-mapping-contract-v1", withExtension: "json", subdirectory: "Fixtures"))
        let envelope = try ChildTaskRecordRead.separatingJSONField("value", data: Data(contentsOf: url), maximum: 1_000_000, integerPaths: [], nullableIntegerPaths: [])
        let values = try ChildTaskRecordRead.separatingJSONFields(["root", "review", "copies", "preview", "choice", "receipt", "original"], data: envelope.value, maximum: 1_000_000, integerPaths: [], nullableIntegerPaths: []).values
        let choice = try TaskfoldJSONDecoder().decode([String: JSON].self, from: XCTUnwrap(values["choice"]))
        let root = try TaskfoldJSONDecoder().decode(Record.self, from: XCTUnwrap(values["root"]))
        let context = try ChildTaskRecordContext(account: choice["account"]!.text, origin: origin, workspace: UUID(), session: UUID(), access: UUID(), snapshot: UUID(), root: root)
        let review = try ChildTaskAdoptionReview(data: XCTUnwrap(values["review"]), context: context, workspaceID: nil)
        let changes = try choice["changes"]!.list.map { try ChildTaskRepairChange(raw: $0.object) }
        let previewData = try XCTUnwrap(values["preview"])
        let preview = try ChildTaskRepairPreview(data: previewData, review: review, changes: changes)
        let command = try ChildTaskRepairCommand(preview: preview, requestID: XCTUnwrap(UUID(uuidString: choice["request_id"]!.text)))
        return try Contract(review: review, copies: ChildTaskCopyReview(data: XCTUnwrap(values["copies"]), review: review), preview: preview, command: command, receipt: ChildTaskRepairResult(command: command, data: XCTUnwrap(values["receipt"])), original: XCTUnwrap(values["original"]), previewData: previewData)
    }
    func partial(_ f: Contract, nodes: [[String: JSON]] = [], retired: [[String: JSON]] = []) throws -> ChildCopyMappingDraft {
        try .init(source: "projection", digest: f.preview.changes[0].raw["copy_digest"]!.text, mapping: ["version": .number(1), "nodes": .array(nodes.map(JSON.object)), "retire": .array(retired.map(JSON.object))])
    }
    func previewBytes(_ metadata: [String: JSON], _ f: Contract) throws -> Data {
        var value = metadata; value["original_tree"] = .null; value["proposed_tree"] = .null
        var data = try TaskfoldJSONEncoder().encode(value)
        for (key, raw) in [("original_tree", f.preview.original), ("proposed_tree", f.preview.proposed)] {
            let range = try XCTUnwrap(data.range(of: Data(("\"" + key + "\":null").utf8)))
            data.replaceSubrange(range, with: Data(("\"" + key + "\":").utf8) + raw)
        }
        return data
    }
    func testActualSQLMappedPreviewReceiptAndCompleteOriginalRoundTrip() throws {
        let f = try contract(), mapping = try ChildCopyMapping(raw: f.preview.changes[0].raw["mapping"]!.object)
        let catalog = try ChildCopyMappingCatalog(copies: f.copies, source: "projection")
        try catalog.validate(try partial(f, nodes: mapping.nodes, retired: mapping.retired), complete: true)
        XCTAssertEqual(f.preview.mappingSummary?.newCount, 1)
        XCTAssertEqual(f.preview.mappingSummary?.resetCount, 2)
        XCTAssertEqual(f.preview.items.count, 3)
        let original = try ChildTaskRepairOriginal(data: f.original, command: f.command, result: f.receipt)
        XCTAssertTrue(String(decoding: original.data, as: UTF8.self).contains("mapping_context"))
        XCTAssertEqual(try ChildTaskRepairCommand(data: TaskfoldJSONEncoder().encode(f.command)), f.command)
        XCTAssertLessThan(try TaskfoldJSONEncoder().encode(f.command).count, 3000)
    }
    func testPartialChoicesSurviveColdStateWithoutDefaultMatchingOrSourceContent() throws {
        let f = try contract(), partial = try partial(f)
        let draft = try ChildTaskRepairDraft(review: f.review, changes: [], labels: [], mappingReview: partial)
        let state = try ChildTaskRepairState(account: draft.account, origin: draft.origin, drafts: [draft])
        let data = try TaskfoldJSONEncoder().encode(state), cold = try ChildTaskRepairState(data: data)
        XCTAssertEqual(cold.drafts, [draft]); XCTAssertTrue(cold.drafts[0].mappingReview!.mapping.nodes.isEmpty)
        XCTAssertTrue(cold.drafts[0].matches(f.review)); XCTAssertLessThan(data.count, 2000)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Chosen older instructions"))
        XCTAssertThrowsError(try ChildCopyMappingCatalog(copies: f.copies, source: "projection").validate(partial, complete: true))
    }
    func testRecordedIdentityStillRequiresExplicitLifecycleConsent() throws {
        let f = try contract(), catalog = try ChildCopyMappingCatalog(copies: f.copies, source: "projection")
        var node = f.preview.changes[0].raw["mapping"]!.object["nodes"]!.list[0].object; node["lifecycle"] = .null
        let partial = try partial(f, nodes: [node]); try catalog.validate(partial, complete: false)
        XCTAssertThrowsError(try ChildCopyMapping(raw: partial.mapping.raw))
        XCTAssertThrowsError(try catalog.validate(partial, complete: true))
        let draft = try ChildTaskRepairDraft(review: f.review, changes: [], labels: [], mappingReview: partial)
        XCTAssertEqual(try TaskfoldJSONDecoder().decode(ChildTaskRepairDraft.self, from: TaskfoldJSONEncoder().encode(draft)), draft)
    }
    func testUncarriedHistoryRequiresExplicitCurrentIncarnationRetirement() throws {
        let f = try contract(), catalog = try ChildCopyMappingCatalog(copies: f.copies, source: "projection")
        var nodes = f.preview.changes[0].raw["mapping"]!.object["nodes"]!.list.map(\.object)
        let old = try XCTUnwrap(catalog.stored.first { $0.id == "second" })
        nodes[1] = ["source_key": .string("second"), "history_key": .null, "incarnation": .null, "lifecycle": .string("selected"), "new_reference": .string("new-second")]
        XCTAssertThrowsError(try catalog.validate(partial(f, nodes: nodes), complete: true))
        let retired: [[String: JSON]] = [["node_key": .string(old.id), "incarnation": .string(old.incarnation)]]
        try catalog.validate(partial(f, nodes: nodes, retired: retired), complete: true)
        XCTAssertThrowsError(try catalog.validate(partial(f, nodes: nodes, retired: [["node_key": .string(old.id), "incarnation": .string(UUID().uuidString.lowercased())]]), complete: true))
    }
    func testMappingRejectsStaleCopiesForeignIncarnationsDuplicateTargetsAndInjectedTrees() throws {
        let f = try contract(), catalog = try ChildCopyMappingCatalog(copies: f.copies, source: "projection")
        let mapping = f.preview.changes[0].raw["mapping"]!.object, nodes = mapping["nodes"]!.list.map(\.object)
        let stale = try ChildCopyMappingDraft(source: "projection", digest: String(repeating: "0", count: 64), mapping: mapping)
        XCTAssertThrowsError(try catalog.validate(stale, complete: false))
        var foreign = nodes; foreign[0]["incarnation"] = .string(UUID().uuidString.lowercased())
        XCTAssertThrowsError(try catalog.validate(partial(f, nodes: foreign), complete: false))
        var duplicate = nodes; duplicate[1]["history_key"] = duplicate[0]["history_key"]; duplicate[1]["incarnation"] = duplicate[0]["incarnation"]
        XCTAssertThrowsError(try partial(f, nodes: duplicate))
        var injected = mapping; injected["tree"] = .array([]); XCTAssertThrowsError(try ChildCopyMapping(raw: injected))
        var wrong = mapping; wrong["version"] = .number(2); XCTAssertThrowsError(try ChildCopyMapping(raw: wrong))
        XCTAssertThrowsError(try ChildTaskRepairDraft(review: f.review, changes: f.preview.changes, labels: ["Mixed"], mappingReview: partial(f)))
    }
    func testMappedSummaryMustMatchEveryExplicitChoiceAndResetBoundary() throws {
        let f = try contract(), base = try TaskfoldJSONDecoder().decode([String: JSON].self, from: f.previewData)
        for key in ["new_identity_count", "reset_completion_count", "subjects", "protocol"] {
            var changed = base, summary = changed["mapping_plan"]!.object
            summary[key] = key == "subjects" ? .array([]) : .number(999); changed["mapping_plan"] = .object(summary)
            XCTAssertThrowsError(try ChildTaskRepairPreview(data: previewBytes(changed, f), review: f.review, changes: f.preview.changes), key)
        }
        var missing = base; missing.removeValue(forKey: "mapping_plan")
        XCTAssertThrowsError(try ChildTaskRepairPreview(data: previewBytes(missing, f), review: f.review, changes: f.preview.changes))
    }
    func testRetirementCountReflectsExplicitChoicesNotOlderDeletedHistoryReferences() throws {
        let f = try contract(); var base = try TaskfoldJSONDecoder().decode([String: JSON].self, from: f.previewData)
        var summary = base["mapping_plan"]!.object
        summary["subjects"] = .array(summary["subjects"]!.list + [.object(["node_key": .string("earlier-deleted"), "reset_completion": .bool(true), "retired": .bool(true)])])
        base["mapping_plan"] = .object(summary)
        let preview = try ChildTaskRepairPreview(data: previewBytes(base, f), review: f.review, changes: f.preview.changes)
        XCTAssertEqual(preview.mappingSummary?.retiredCount, 0)
        XCTAssertEqual(preview.mappingSummary?.newCount, 1)
    }
    func testMappedOriginalRejectsWrongContextEvenWithMatchingRecomputedHash() throws {
        let f = try contract(), parts = try ChildTaskRecordRead.separatingJSONField("original", data: f.original, maximum: 1_000_000, integerPaths: [], nullableIntegerPaths: [])
        let archive = try TaskfoldJSONDecoder().decode([String: JSON].self, from: parts.value)
        for key in ["request_id", "archive_id"] {
            var value = archive, context = value["mapping_context"]!.object; context[key] = .string(UUID().uuidString.lowercased()); value["mapping_context"] = .object(context)
            let bytes = try TaskfoldJSONEncoder().encode(value), digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            var receipt = f.receipt.raw; receipt["archive_bytes"] = .number(Double(bytes.count)); receipt["archive_digest"] = .string(digest)
            // Embed the very same archive bytes that the recomputed receipt certifies.
            let wrapper = Data("{\"protocol\":1,\"account\":\"\(f.command.account)\",\"request_id\":\"\(f.command.id)\",\"archive_id\":\"\(receipt["archive_id"]!.text)\",\"archive_digest\":\"\(digest)\",\"original\":".utf8) + bytes + Data("}".utf8)
            XCTAssertThrowsError(try ChildTaskRepairOriginal(data: wrapper, command: f.command, result: f.command.result(receipt)), key)
        }
    }
    func testLargerMappedRequestsRoundTripWhileOrdinaryLimitsRemain() throws {
        let f = try contract(); var mapping = f.preview.changes[0].raw["mapping"]!.object
        mapping["nodes"] = .array((0..<400).map { .object(["source_key": .string("source-\($0)-" + String(repeating: "x", count: 50)), "history_key": .null, "incarnation": .null, "lifecycle": .string("selected"), "new_reference": .string("target-\($0)-" + String(repeating: "y", count: 50))]) })
        let change = try ChildTaskRepairChange.choosing("projection", digest: f.copies.digest, mapping: ChildCopyMapping(raw: mapping))
        var body = f.command.body; body["changes"] = .array([.object(change.raw)])
        XCTAssertGreaterThan(try TaskfoldJSONEncoder().encode(body).count, 70_000)
        let command = try ChildTaskRepairCommand(account: f.command.account, origin: f.command.origin, body: body, nodeCount: 400)
        XCTAssertEqual(try ChildTaskRepairCommand(data: TaskfoldJSONEncoder().encode(command)), command)
        let ordinary = try (0..<64).map { try ChildTaskRepairChange(.wrapItem, path: [$0], reference: UUID().uuidString.lowercased(), title: String(repeating: "é", count: 500)) }
        XCTAssertThrowsError(try ChildTaskRepairChange.validate(ordinary), "Ordinary metadata allowance stays unchanged")
    }
}
