import XCTest
import CryptoKit
@testable import TaskfoldCore

final class ChildRestoredAdoptionTests: XCTestCase {
    struct Fixture {
        let review: ChildTaskAdoptionReview, held: ChildTaskRestoredCopyReview
        let preview: ChildTaskRepairPreview, command: ChildTaskRepairCommand, result: ChildTaskRepairResult
        let values: [String: Data]
    }
    func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "child-restored-adoption-contract-v1", withExtension: "json", subdirectory: "Fixtures"))
        let values = try ChildTaskRecordRead.separatingJSONFields(["root", "review", "held", "preview", "command", "receipt", "original"], data: Data(contentsOf: url), maximum: 1_000_000, integerPaths: [], nullableIntegerPaths: []).values
        let body = try TaskfoldJSONDecoder().decode([String: JSON].self, from: XCTUnwrap(values["command"]))
        let root = try TaskfoldJSONDecoder().decode(Record.self, from: XCTUnwrap(values["root"]))
        let context = try ChildTaskRecordContext(account: body["account"]!.text, origin: "https://repair.test", workspace: UUID(), session: UUID(), access: UUID(), snapshot: UUID(), root: root)
        let read = try ChildTaskAdoptionReview(data: XCTUnwrap(values["review"]), context: context, workspaceID: nil)
        let choice = body["changes"]!.list[0].object, binding = try ChildTaskRestorationBinding(raw: choice["restoration"]!.object)
        let held = try ChildTaskRestoredCopyReview(data: XCTUnwrap(values["held"]), review: read, actorID: binding.actorID, restorationID: binding.restorationID)
        let changes = try body["changes"]!.list.map { try ChildTaskRepairChange(raw: $0.object) }
        let preview = try ChildTaskRepairPreview(data: XCTUnwrap(values["preview"]), review: read, changes: changes)
        let command = try ChildTaskRepairCommand(preview: preview, requestID: XCTUnwrap(UUID(uuidString: body["request_id"]!.text)))
        return try .init(review: read, held: held, preview: preview, command: command, result: ChildTaskRepairResult(command: command, data: XCTUnwrap(values["receipt"])), values: values)
    }
    func testActualSavedAdoptionRetainsExactInverseWithoutGrantingEditingFromRead() throws {
        let f = try fixture()
        XCTAssertTrue(f.preview.eligible); XCTAssertTrue(f.result.applied)
        XCTAssertEqual(f.command.body["changes"]!.list[0].object["restoration"], .object(f.held.restoration.raw))
        let original = try ChildTaskRepairOriginal(data: XCTUnwrap(f.values["original"]), command: f.command, result: f.result)
        let text = String(decoding: original.data, as: UTF8.self)
        XCTAssertTrue(text.contains("9007199254740993"))
        XCTAssertTrue(text.contains("Newer formatted instruction"))
        XCTAssertTrue(text.contains("retained_restoration"))
        XCTAssertFalse(String(describing: original).contains("instruction"))
    }
    func testBoundPartialHistoryAndDurableCommandSurviveColdRoundTrip() throws {
        let f = try fixture(), choice = f.command.body["changes"]!.list[0].object
        let format = try choice["format_changes"]!.list.map { try ChildTaskRepairChange(raw: $0.object) }
        let partial = try ChildCopyMappingDraft(source: "task", digest: f.held.copies.digest, mapping: choice["mapping"]!.object, formatChanges: format, restoration: f.held.restoration)
        let edited = try partial.replacingMapping(partial.mapping.raw)
        XCTAssertEqual(edited.restoration, f.held.restoration); XCTAssertEqual(edited.formatChanges, format)
        let data = try TaskfoldJSONEncoder().encode(edited)
        XCTAssertEqual(try TaskfoldJSONDecoder().decode(ChildCopyMappingDraft.self, from: data), partial)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("9007199254740993"))
        let rebuilt = try ChildTaskRepairChange.choosing("task", digest: f.held.copies.digest, mapping: partial.mapping, formatChanges: format, restoration: partial.restoration)
        XCTAssertEqual(rebuilt, f.preview.changes[0])
        let stored = try TaskfoldJSONEncoder().encode(f.command), recovered = try ChildTaskRepairCommand(data: stored)
        XCTAssertEqual(recovered, f.command)
        XCTAssertTrue(try recovered.result(f.result.raw).agrees(f.result))
    }
    func testRestorationBindingCannotBeAttachedToOtherSourcesOrUnmappedChoices() throws {
        let f = try fixture(), choice = f.preview.changes[0].raw
        for key in ["mapping", "restoration"] {
            var changed = choice; changed.removeValue(forKey: key)
            if key == "mapping" { XCTAssertThrowsError(try ChildTaskRepairChange(raw: changed)) }
            else { XCTAssertNoThrow(try ChildTaskRepairChange(raw: changed)) }
        }
        for source in ["projection", "records"] {
            var changed = choice; changed["source"] = .string(source)
            XCTAssertThrowsError(try ChildTaskRepairChange(raw: changed))
            XCTAssertThrowsError(try ChildCopyMappingDraft(source: source, digest: f.held.copies.digest, mapping: choice["mapping"]!.object, restoration: f.held.restoration))
        }
    }
    func testUnsafeStoredBindingCounterCannotBeRoundedIntoAnotherRequest() throws {
        let f = try fixture(), encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(f.command), text = String(decoding: data, as: UTF8.self)
        for revision in ["1.0", "1e0", "-1", "9007199254740993", "1,\"revision\":1"] {
            let malformed = Data(text.replacingOccurrences(of: "\"revision\":1", with: "\"revision\":" + revision).utf8)
            XCTAssertNotEqual(data, malformed)
            XCTAssertThrowsError(try ChildTaskRepairCommand(data: malformed), revision)
        }
    }
    func testAdoptionArchiveRequiresItsMatchingRetainedBindingAndNullPreimageAuthority() throws {
        let f = try fixture(), envelope = try ChildTaskRecordRead.separatingJSONField("original", data: XCTUnwrap(f.values["original"]), maximum: 1_000_000, integerPaths: [], nullableIntegerPaths: [])
        let names: Set<String> = ["root", "projection", "records", "authority", "root_history", "child_history", "retained_restoration"]
        let parts = try ChildTaskRecordRead.separatingJSONFields(names, data: envelope.value, maximum: 1_000_000, integerPaths: [], nullableIntegerPaths: [])
        let metadata = try TaskfoldJSONDecoder().decode([String: JSON].self, from: parts.metadata)
        for mode in ["missing retained", "nonnull authority", "wrong retained binding"] {
            var values = parts.values
            if mode == "missing retained" { values.removeValue(forKey: "retained_restoration") }
            if mode == "nonnull authority" { values["authority"] = Data("{}".utf8) }
            if mode == "wrong retained binding" {
                let retained = String(decoding: try XCTUnwrap(values["retained_restoration"]), as: UTF8.self)
                values["retained_restoration"] = Data(retained.replacingOccurrences(of: f.held.restoration.digest, with: String(repeating: "a", count: 64)).utf8)
            }
            let keys = Set(metadata.keys).subtracting(names).union(values.keys)
            let fields = try keys.sorted().map { key -> String in
                let data = try values[key] ?? TaskfoldJSONEncoder().encode(metadata[key]!)
                return "\"" + key + "\":" + String(decoding: data, as: UTF8.self)
            }
            let changed = Data(("{" + fields.joined(separator: ",") + "}").utf8)
            let digest = SHA256.hash(data: changed).map { String(format: "%02x", $0) }.joined()
            var raw = f.result.raw; raw["archive_digest"] = .string(digest); raw["archive_bytes"] = .number(Double(changed.count))
            let result = try ChildTaskRepairResult(command: f.command, raw: raw)
            var wrapper = try TaskfoldJSONDecoder().decode([String: JSON].self, from: envelope.metadata)
            wrapper.removeValue(forKey: "original"); wrapper["archive_digest"] = .string(digest)
            let header = String(decoding: try TaskfoldJSONEncoder().encode(wrapper), as: UTF8.self)
            let response = Data((String(header.dropLast()) + ",\"original\":" + String(decoding: changed, as: UTF8.self) + "}").utf8)
            XCTAssertThrowsError(try ChildTaskRepairOriginal(data: response, command: f.command, result: result), mode)
        }
    }

    func testFormatStageKeepsBoundRestorationAcrossColdStateAndHistoryReview() throws {
        let f = try fixture(), raw = f.preview.changes[0].raw
        let format = try raw["format_changes"]!.list.map { try ChildTaskRepairChange(raw: $0.object) }
        let draft = try ChildTaskRepairDraft(review: f.review, changes: format, labels: format.map(\.formatSummary), restoration: f.held.restoration)
        let state = try ChildTaskRepairState(account: draft.account, origin: draft.origin, drafts: [draft])
        let data = try TaskfoldJSONEncoder().encode(state), cold = try ChildTaskRepairState(data: data)
        XCTAssertEqual(cold.drafts, [draft]); XCTAssertTrue(cold.drafts[0].matches(f.review))
        XCTAssertEqual(cold.drafts[0].restoration, f.held.restoration)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Newer formatted instruction"))
        let partial = try ChildCopyMappingDraft(source: "task", digest: f.held.copies.digest, mapping: raw["mapping"]!.object, formatChanges: format, restoration: draft.restoration)
        let mappingDraft = try ChildTaskRepairDraft(review: f.review, changes: [], labels: [], mappingReview: partial, restoration: draft.restoration)
        let returned = try ChildTaskRepairDraft(review: f.review, changes: partial.formatChanges, labels: format.map(\.formatSummary), restoration: mappingDraft.restoration)
        XCTAssertEqual(returned.restoration, draft.restoration); XCTAssertEqual(returned.changes, draft.changes)
    }
    func testBoundReviewNeverFallsBackToAnUnboundOrDifferentMapping() throws {
        let f = try fixture(), raw = f.preview.changes[0].raw
        var otherRaw = f.held.restoration.raw; otherRaw["digest"] = .string(String(repeating: "a", count: 64))
        let other = try ChildTaskRestorationBinding(raw: otherRaw)
        let partial = try ChildCopyMappingDraft(source: "task", digest: f.held.copies.digest, mapping: raw["mapping"]!.object, restoration: f.held.restoration)
        XCTAssertThrowsError(try ChildTaskRepairDraft(review: f.review, changes: [], labels: [], mappingReview: partial, restoration: other))
        let unbound = try ChildCopyMappingDraft(source: "task", digest: f.held.copies.digest, mapping: raw["mapping"]!.object)
        XCTAssertThrowsError(try ChildTaskRepairDraft(review: f.review, changes: [], labels: [], mappingReview: unbound, restoration: f.held.restoration))
        XCTAssertThrowsError(try ChildTaskRepairDraft(review: f.review, changes: f.preview.changes, labels: ["Keep older"], restoration: other))
        let ordinary = try ChildTaskRepairChange.choosing("task", digest: f.held.copies.digest)
        XCTAssertThrowsError(try ChildTaskRepairDraft(review: f.review, changes: [ordinary], labels: ["Use copy"], restoration: f.held.restoration))
    }
    func testPriorBoundMappedDraftInfersContextWithoutChangingTheCommand() throws {
        let f = try fixture()
        let draft = try ChildTaskRepairDraft(review: f.review, changes: f.preview.changes, labels: ["Keep older"])
        XCTAssertEqual(draft.restoration, f.held.restoration)
        let data = try TaskfoldJSONEncoder().encode(draft)
        var raw = try TaskfoldJSONDecoder().decode([String: JSON].self, from: data); raw.removeValue(forKey: "restoration")
        let recovered = try TaskfoldJSONDecoder().decode(ChildTaskRepairDraft.self, from: TaskfoldJSONEncoder().encode(raw))
        XCTAssertEqual(recovered, draft); XCTAssertEqual(recovered.changes, f.command.body["changes"]!.list.map { try! ChildTaskRepairChange(raw: $0.object) })
    }
    func testUndoingLastFormatChoiceKeepsOnlyTheVersionIdentity() throws {
        let f = try fixture()
        XCTAssertThrowsError(try ChildTaskRepairDraft(review: f.review, changes: [], labels: []))
        let identityOnly = try ChildTaskRepairDraft(review: f.review, changes: [], labels: [], restoration: f.held.restoration)
        let state = try ChildTaskRepairState(account: identityOnly.account, origin: identityOnly.origin, drafts: [identityOnly])
        let data = try TaskfoldJSONEncoder().encode(state), recovered = try ChildTaskRepairState(data: data)
        XCTAssertEqual(recovered.drafts, [identityOnly]); XCTAssertNil(recovered.drafts[0].mappingReview)
        XCTAssertTrue(recovered.drafts[0].changes.isEmpty)
        XCTAssertLessThan(data.count, 2000)
    }
    func testFormatStageBindingRevisionIsStrictBeforeDecoding() throws {
        let f = try fixture(), draft = try ChildTaskRepairDraft(review: f.review, changes: [], labels: [], restoration: f.held.restoration)
        let state = try ChildTaskRepairState(account: draft.account, origin: draft.origin, drafts: [draft])
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(state), as: UTF8.self)
        for revision in ["1e0", "1.0", "9007199254740993", "1,\"revision\":1"] {
            let invalid = Data(text.replacingOccurrences(of: "\"revision\":1", with: "\"revision\":" + revision).utf8)
            XCTAssertNotEqual(invalid, Data(text.utf8)); XCTAssertThrowsError(try ChildTaskRepairState(data: invalid), revision)
        }
    }
}
