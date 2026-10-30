import XCTest
@testable import TaskfoldCore

final class ChildTaskOpaqueReadTests: XCTestCase {
    private let original = #"{"é":1,"e\u0301":2,"large":1e1000,"exact":9007199254740993,"note":"Café 🪴","items":[false,null,{"keep":true}]}"#
    private let reformatted = #"{ "items": [false, null, {"keep": true}], "note": "Caf\u00e9 🪴", "exact": 900719925474099300e-2, "large": 10e999, "é": 2.00, "\u00e9": 1e0 }"#

    private func value(_ text: String) throws -> JSON {
        try TaskfoldJSONDecoder().decode(JSON.self, from: Data(text.utf8))
    }
    private func bytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private struct Fixture {
        let root: Record, context: ChildTaskRecordContext, key: String
        var response: [String: JSON]
    }
    private func fixture(_ version: Int, wireValue: String? = nil) throws -> Fixture {
        let name = version == 1 ? "child-task-record-read" : "child-task-structure-read"
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        let file = try TaskfoldJSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        var root = Record(file["root"]!.object), response = file["response"]!.object
        var children = root["subtasks"].list, first = children[0].object
        let key = first["id"]!.text
        first["future_exact"] = try value(original); children[0] = .object(first); root["subtasks"] = .array(children)
        var rows = response["records"]!.list
        let index = try XCTUnwrap(rows.firstIndex { $0.object["node_key"] == .string(key) })
        var row = rows[index].object, fields = row["fields"]!.object
        fields["future_exact"] = try value(wireValue ?? original); row["fields"] = .object(fields)
        rows[index] = .object(row); response["records"] = .array(rows)
        let context = try ChildTaskRecordContext(account: file["account"]!.text, origin: "https://child-record.test", workspace: UUID(), session: UUID(), access: UUID(), snapshot: UUID(), root: root)
        return Fixture(root: root, context: context, key: key, response: response)
    }
    private func read(_ fixture: Fixture, version: Int) throws -> ChildTaskRecordRead {
        if version == 1 { return try ChildTaskRecordRead(data: bytes(fixture.response), context: fixture.context) }
        return try ChildTaskStructureRead(data: bytes(fixture.response), context: fixture.context).records
    }

    func testFreshReadsRetainExactUnknownObjectsAndFieldRequestsNeverResubmitThem() throws {
        for version in [1, 2] {
            let f = try fixture(version), before = try bytes(f.root), result = try read(f, version: version)
            let retained = try XCTUnwrap(result.nodes[f.key]?.fields["future_exact"])
            XCTAssertEqual(try bytes(retained), Data(original.utf8))
            let command = try ChildTaskFieldCommand(read: result, key: f.key, changes: ["title": .string("Edit supported fields")])
            XCTAssertEqual(command.body["changes"], .object(["title": .string("Edit supported fields")]))
            let encoded = try bytes(command)
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("future_exact"))
            XCTAssertEqual(try TaskfoldJSONDecoder().decode(ChildTaskFieldCommand.self, from: encoded), command)
            XCTAssertEqual(try bytes(f.root), before)
        }
    }
    func testServerFormattingAndExactNumericNotationDoNotInventAConflict() throws {
        for version in [1, 2] {
            let f = try fixture(version, wireValue: reformatted), result = try read(f, version: version)
            XCTAssertTrue(AuthoredValueComparison.exactJSON(result.tree, f.root["subtasks"]))
            XCTAssertEqual(try bytes(result.nodes[f.key]!.fields["future_exact"]!), Data(reformatted.utf8))
            XCTAssertEqual(try bytes(f.root["subtasks"].list[0].object["future_exact"]!), Data(original.utf8))
        }
    }
    func testContentChangesStillRefuseFreshReadWithoutChangingTheRoot() throws {
        for changed in [reformatted.replacingOccurrences(of: "900719925474099300e-2", with: "900719925474099400e-2"), reformatted.replacingOccurrences(of: "2.00", with: "3.00"), reformatted.replacingOccurrences(of: "Caf\\u00e9", with: "Cafe\\u0301"), reformatted.replacingOccurrences(of: "[false, null", with: "[null, false")] {
            XCTAssertNotEqual(changed, reformatted)
            for version in [1, 2] {
                let f = try fixture(version, wireValue: changed), before = try bytes(f.root)
                XCTAssertThrowsError(try read(f, version: version))
                XCTAssertEqual(try bytes(f.root), before)
            }
        }
    }
    func testDuplicateKeysAndAmbiguousStructuralMembersRemainRefused() throws {
        for version in [1, 2] {
            let f = try fixture(version), wire = String(decoding: try bytes(f.response), as: UTF8.self)
            for changed in [wire.replacingOccurrences(of: #""é":1,"e\u0301":2"#, with: #""é":1,"\u00e9":2"#), "{" + #""é":1,"e\u0301":2,"# + wire.dropFirst(), wire.replacingOccurrences(of: #""future_exact":{"#, with: #""é":1,"e\u0301":2,"future_exact":{"#)] {
                XCTAssertNotEqual(changed, wire)
                if version == 1 { XCTAssertThrowsError(try ChildTaskRecordRead(data: Data(changed.utf8), context: f.context)) }
                else { XCTAssertThrowsError(try ChildTaskStructureRead(data: Data(changed.utf8), context: f.context)) }
            }
        }
    }
    func testPreservedMetadataDoesNotRelaxCounterGrammarOrReadDepth() throws {
        let f = try fixture(2), wire = String(decoding: try bytes(f.response), as: UTF8.self)
        for counter in ["1e0", "1.0", "9007199254740993"] {
            let changed = wire.replacingOccurrences(of: #""structure_revision":2"#, with: #""structure_revision":"# + counter)
            XCTAssertNotEqual(changed, wire)
            XCTAssertThrowsError(try ChildTaskStructureRead(data: Data(changed.utf8), context: f.context))
        }
        let nested = String(repeating: "[", count: 128) + original + String(repeating: "]", count: 128)
        XCTAssertThrowsError(try read(fixture(2, wireValue: nested), version: 2))
    }
    func testExistingOpaqueFieldsDoNotBecomeNewAuthoredStructurePayloads() throws {
        let f = try fixture(2), result = try ChildTaskStructureRead(data: bytes(f.response), context: f.context)
        let move = try ChildTaskStructureCommand(move: f.key, parent: nil, index: 1, read: result)
        XCTAssertFalse(String(decoding: try bytes(move), as: UTF8.self).contains("future_exact"))
        XCTAssertEqual(try ChildTaskStructureCommand(data: bytes(move)), move)
        var copied: [String: JSON] = ["id": .string("new-opaque-node"), "title": .string("New task")]
        XCTAssertNoThrow(try ChildTaskStructureCommand(insert: .object(copied), parent: nil, index: 0, read: result))
        copied["future_exact"] = result.records.nodes[f.key]!.fields["future_exact"]
        XCTAssertThrowsError(try ChildTaskStructureCommand(insert: .object(copied), parent: nil, index: 0, read: result))
    }
    func testExactComparisonDoesNotAlterRawExportsOrCollapseKeysStringsAndArrays() throws {
        let a = try value(original), b = try value(reformatted)
        XCTAssertNotEqual(a, b) // Raw storage identity remains distinct.
        XCTAssertTrue(AuthoredValueComparison.exactJSON(a, b))
        XCTAssertEqual(try bytes(a), Data(original.utf8)); XCTAssertEqual(try bytes(b), Data(reformatted.utf8))
        for changed in [original.replacingOccurrences(of: "1e1000", with: "1e999"), original.replacingOccurrences(of: #""e\u0301":2"#, with: #""other":2"#), original.replacingOccurrences(of: "false,null", with: "null,false"), original.replacingOccurrences(of: "Café", with: "Cafe\u{301}")] {
            XCTAssertNotEqual(Data(changed.utf8), Data(original.utf8))
            XCTAssertFalse(AuthoredValueComparison.exactJSON(a, try value(changed)))
        }
    }
}
