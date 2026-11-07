import XCTest
import CryptoKit
@testable import TaskfoldCore

final class ChildRepairArchiveTests: XCTestCase {
    private let origin = "https://archive-fixture.example.invalid"
    private func fixture() throws -> [String: JSON] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "child-repair-archive-contract-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try TaskfoldJSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
    }
    private func scope(_ account: String) -> ChildTaskFieldClientScope {
        .init(account: account, origin: origin, workspace: UUID(), session: UUID(), access: UUID())
    }
    private func page(_ raw: [String: JSON], _ scope: ChildTaskFieldClientScope, after: String? = nil, limit: Int = 2) throws -> ChildTaskRepairArchivePage {
        try .init(data: TaskfoldJSONEncoder().encode(raw), scope: scope, after: after, limit: limit)
    }
    func testActualServiceDiscoveryAndExactOriginalNeedNoLocalCommand() throws {
        let f = try fixture(), raw = f["page"]!.object, s = scope(raw["account"]!.text)
        let p = try page(raw, s), entry = try XCTUnwrap(p.entries.first)
        let original = try ChildTaskRepairOriginal(data: Data(f["originalWire"]!.text.utf8), archive: entry)
        XCTAssertEqual(original.data.count, entry.bytes)
        XCTAssertEqual(SHA256.hash(data: original.data).map { String(format: "%02x", $0) }.joined(), entry.receipt["archive_digest"]?.text)
        XCTAssertEqual(entry.scope, s); XCTAssertNotNil(entry.title); XCTAssertFalse(entry.titleTruncated); XCTAssertEqual(p.entries.count, 2); XCTAssertEqual(p.next, p.entries.last?.requestID)
        XCTAssertFalse(String(describing: entry).contains(entry.id)); XCTAssertFalse(String(reflecting: entry).contains(entry.rootID))
    }
    func testArchiveMetadataRefusesUnknownForeignAndMalformedProofs() throws {
        let raw = try fixture()["page"]!.object, s = scope(raw["account"]!.text)
        for (key, value): (String, JSON) in [
            ("account", .string(UUID().uuidString.lowercased())), ("state", .string("closed")), ("replayed", .bool(true)),
            ("archive_id", .string("unknown")), ("node_count", .null), ("node_count", .number(1001)),
            ("archive_bytes", .number(0)), ("archive_bytes", .number(8_000_001)), ("review_digest", .string("bad")),
            ("changes", .array([]))
        ] {
            var bad = raw, rows = bad["entries"]!.list, first = rows[0].object, receipt = first["receipt"]!.object
            receipt[key] = value; first["receipt"] = .object(receipt); rows[0] = .object(first); bad["entries"] = .array(rows)
            XCTAssertThrowsError(try page(bad, s), key)
        }
        for (key, value): (String, JSON) in [("created_at", .string("not a date")), ("content_retained", .string("true")), ("notes", .string("Unrequested content")), ("current_title", .number(1)), ("current_title", .string(String(repeating: "a", count: 513))), ("title_truncated", .bool(true))] {
            var bad = raw, rows = bad["entries"]!.list, first = rows[0].object
            first[key] = value; rows[0] = .object(first); bad["entries"] = .array(rows)
            XCTAssertThrowsError(try page(bad, s), key)
        }
        var bad = raw; bad["account"] = .string(UUID().uuidString.lowercased()); XCTAssertThrowsError(try page(bad, s))
        bad = raw; bad["unknown"] = .null; XCTAssertThrowsError(try page(bad, s))
    }
    func testKeysetOrderUniquenessAndCursorAreStrict() throws {
        let raw = try fixture()["page"]!.object, s = scope(raw["account"]!.text), rows = raw["entries"]!.list
        var bad = raw; bad["entries"] = .array(rows.reversed()); XCTAssertThrowsError(try page(bad, s))
        bad = raw; bad["entries"] = .array([rows[0], rows[0]]); XCTAssertThrowsError(try page(bad, s))
        bad = raw; bad["next"] = rows[0].object["receipt"]?.object["request_id"]; XCTAssertThrowsError(try page(bad, s))
        bad = raw; bad["entries"] = .array([]); XCTAssertThrowsError(try page(bad, s))
        XCTAssertThrowsError(try page(raw, s, after: rows[0].object["receipt"]!.object["request_id"]!.text))
        XCTAssertThrowsError(try page(raw, s, after: "not-a-cursor")); XCTAssertThrowsError(try page(raw, s, limit: 0)); XCTAssertThrowsError(try page(raw, s, limit: 51))
        var second = rows[1].object, receipt = second["receipt"]!.object
        receipt["archive_id"] = rows[0].object["receipt"]?.object["archive_id"]; second["receipt"] = .object(receipt)
        bad = raw; bad["entries"] = .array([rows[0], .object(second)]); XCTAssertThrowsError(try page(bad, s))
        let p = try page(raw, s); var empty = raw; empty["entries"] = .array([]); empty["next"] = .null
        XCTAssertTrue(try page(empty, s, after: p.next).entries.isEmpty)
    }
    func testLexicalCountersDuplicateKeysAndOversizedPagesRefuse() throws {
        let raw = try fixture()["page"]!.object, s = scope(raw["account"]!.text)
        let writer = TaskfoldJSONEncoder(); writer.outputFormatting = [.sortedKeys]
        let text = String(decoding: try writer.encode(raw), as: UTF8.self)
        for counter in ["1.0", "1e0"] {
            let bad = text.replacingOccurrences(of: "\"protocol\":1", with: "\"protocol\":" + counter)
            XCTAssertThrowsError(try ChildTaskRepairArchivePage(data: Data(bad.utf8), scope: s, after: nil, limit: 2))
        }
        let duplicate = "{\"protocol\":1," + text.dropFirst()
        XCTAssertThrowsError(try ChildTaskRepairArchivePage(data: Data(duplicate.utf8), scope: s, after: nil, limit: 2))
        XCTAssertThrowsError(try ChildTaskRepairArchivePage(data: Data(repeating: 32, count: ChildTaskRepairArchivePage.maximumBytes + 1), scope: s, after: nil, limit: 2))
    }
    func testExportRefusesWrongIdentityDigestContextAndMissingContent() throws {
        let f = try fixture(), raw = f["page"]!.object, s = scope(raw["account"]!.text), wire = Data(f["originalWire"]!.text.utf8)
        let entries = try page(raw, s).entries
        XCTAssertThrowsError(try ChildTaskRepairOriginal(data: wire, archive: entries[1]))
        var damaged = wire; damaged.append(120); XCTAssertThrowsError(try ChildTaskRepairOriginal(data: damaged, archive: entries[0]))
        for (key, value): (String, JSON) in [("task_id", .string(UUID().uuidString.lowercased())), ("review_digest", .string(String(repeating: "a", count: 64))), ("archive_bytes", .number(Double(entries[0].bytes + 1)))] {
            var bad = raw, rows = raw["entries"]!.list, first = rows[0].object, receipt = first["receipt"]!.object
            receipt[key] = value; first["receipt"] = .object(receipt); rows[0] = .object(first); bad["entries"] = .array(rows)
            XCTAssertThrowsError(try ChildTaskRepairOriginal(data: wire, archive: page(bad, s).entries[0]), key)
        }
        var bad = raw, rows = raw["entries"]!.list, first = rows[0].object
        first["content_retained"] = .bool(false); rows[0] = .object(first); bad["entries"] = .array(rows)
        let missing = try page(bad, s).entries[0]; XCTAssertFalse(missing.contentRetained)
        XCTAssertThrowsError(try ChildTaskRepairOriginal(data: wire, archive: missing))
    }
    func testMappedOriginalExportsWithoutReconstructingMappingMutation() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "child-copy-mapping-contract-v1", withExtension: "json", subdirectory: "Fixtures"))
        let envelope = try ChildTaskRecordRead.separatingJSONField("value", data: Data(contentsOf: url), maximum: 1_000_000, integerPaths: [], nullableIntegerPaths: [])
        let parts = try ChildTaskRecordRead.separatingJSONFields(["root", "review", "copies", "preview", "choice", "receipt", "original"], data: envelope.value, maximum: 1_000_000, integerPaths: [], nullableIntegerPaths: []).values
        let receipt = try TaskfoldJSONDecoder().decode([String: JSON].self, from: XCTUnwrap(parts["receipt"]))
        let s = scope(receipt["account"]!.text), raw: [String: JSON] = ["protocol": .number(1), "account": receipt["account"]!, "entries": .array([.object(["receipt": .object(receipt), "created_at": .string("2026-11-07T05:00:00Z"), "content_retained": .bool(true), "current_title": .null, "title_truncated": .bool(false)])]), "next": .null]
        let entry = try page(raw, s, limit: 1).entries[0]
        let original = try ChildTaskRepairOriginal(data: XCTUnwrap(parts["original"]), archive: entry)
        XCTAssertEqual(original.data.count, entry.bytes)
    }
}

extension ChildRepairArchiveTests {
    private func cleanupFixture() throws -> ([String: JSON], ChildTaskRepairArchive) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "child-repair-original-cleanup-contract-v1", withExtension: "json", subdirectory: "Fixtures"))
        let f = try TaskfoldJSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url)), account = f["review"]!.object["account"]!
        let raw: [String: JSON] = ["protocol": .number(1), "account": account, "entries": .array([f["entry"]!]), "next": .null]
        return (f, try page(raw, scope(account.text), limit: 1).entries[0])
    }
    func testActualOriginalCleanupReviewAndRepeatedRemovalBindOneReceipt() throws {
        let (f, entry) = try cleanupFixture()
        let review = try ChildTaskRepairOriginalCleanup(data: TaskfoldJSONEncoder().encode(f["review"]!), archive: entry, operation: .review)
        XCTAssertTrue(review.allowsRemoval)
        let removed = try ChildTaskRepairOriginalCleanup(data: TaskfoldJSONEncoder().encode(f["removed"]!), archive: entry, operation: .remove)
        XCTAssertFalse(removed.retained); XCTAssertFalse(removed.enabled); XCTAssertFalse(removed.allowsRemoval)
        XCTAssertEqual(removed.archive.receipt, entry.receipt)
        let body = ChildTaskRepairOriginalCleanup.body(archive: entry, operation: .remove)
        XCTAssertEqual(Set(body.keys), ["_operation", "_request", "_archive", "_digest", "_bytes"])
        XCTAssertEqual(body["_operation"], .string("remove")); XCTAssertEqual(body["_archive"], .string(entry.id))
        XCTAssertEqual(body["_bytes"], entry.receipt["archive_bytes"])
        XCTAssertFalse(String(reflecting: review).contains(entry.id)); XCTAssertFalse(String(reflecting: removed).contains(entry.scope.account))
    }
    func testOriginalCleanupRefusesForeignIdentityAndContradictoryRemoval() throws {
        let (f, entry) = try cleanupFixture(), original = f["review"]!.object
        for (key,value): (String,JSON) in [("account",.string(UUID().uuidString.lowercased())),("request_id",.string(UUID().uuidString.lowercased())),("archive_id",.string(UUID().uuidString.lowercased())),("archive_digest",.string(String(repeating:"0",count:64))),("archive_bytes",.number(Double(entry.bytes+1))),("protocol",.number(2)),("state",.string("restored")),("cleanup_enabled",.string("true")),("unknown",.null)] {
            var bad = original; bad[key] = value
            XCTAssertThrowsError(try ChildTaskRepairOriginalCleanup(data: TaskfoldJSONEncoder().encode(bad), archive: entry, operation: .review),key)
        }
        XCTAssertThrowsError(try ChildTaskRepairOriginalCleanup(data: TaskfoldJSONEncoder().encode(original), archive: entry, operation: .remove))
    }
    func testOriginalCleanupRejectsAmbiguousNumericAndDuplicateJSON() throws {
        let (f, entry) = try cleanupFixture(), writer = TaskfoldJSONEncoder(); writer.outputFormatting = .sortedKeys
        let source = String(decoding: try writer.encode(f["review"]!), as: UTF8.self)
        for token in ["1.0","1e0"] {
            XCTAssertThrowsError(try ChildTaskRepairOriginalCleanup(data: Data(source.replacingOccurrences(of:"\"protocol\":1",with:"\"protocol\":"+token).utf8),archive:entry,operation:.review))
        }
        let bytes = "\"archive_bytes\":\(entry.bytes)"
        XCTAssertThrowsError(try ChildTaskRepairOriginalCleanup(data: Data(source.replacingOccurrences(of:bytes,with:bytes+".0").utf8),archive:entry,operation:.review))
        XCTAssertThrowsError(try ChildTaskRepairOriginalCleanup(data: Data(("{\"protocol\":1,"+source.dropFirst()).utf8),archive:entry,operation:.review))
        XCTAssertThrowsError(try ChildTaskRepairOriginalCleanup(data: Data(repeating:32,count:4097),archive:entry,operation:.review))
    }
    func testOriginalCleanupPauseAndUnavailableNeverEnableRemoval() throws {
        let (f, entry) = try cleanupFixture(); var raw=f["review"]!.object;raw["cleanup_enabled"] = .bool(false)
        XCTAssertFalse(try ChildTaskRepairOriginalCleanup(data:TaskfoldJSONEncoder().encode(raw),archive:entry,operation:.review).allowsRemoval)
        raw["cleanup_enabled"] = .bool(true);raw["state"] = .string("unavailable")
        XCTAssertFalse(try ChildTaskRepairOriginalCleanup(data:TaskfoldJSONEncoder().encode(raw),archive:entry,operation:.review).allowsRemoval)
        let gone=entry.withoutOriginal();XCTAssertFalse(gone.contentRetained);XCTAssertEqual(gone.receipt,entry.receipt);XCTAssertEqual(gone.title,entry.title);XCTAssertEqual(gone.createdAt,entry.createdAt);XCTAssertEqual(gone.scope,entry.scope)
    }
}
