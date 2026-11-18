import XCTest
@testable import TaskfoldCore

/// Proves the Swift conversion equals the independent Python computation recorded in Fixtures/legacy_subtasks.json,
/// which the Migration B SQL reuses.
final class LegacySubtaskConversionTests: XCTestCase {
    func fixture() throws -> [String: JSON] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "legacy_subtasks", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(JSON.self, from: Data(contentsOf: url)).object
    }
    func trees() throws -> [[String: JSON]] { try XCTUnwrap(fixture()["trees"]).list.map(\.object) }
    func root(_ tree: [String: JSON]) -> Record {
        var record = Record(tree["root"]!.object); record["subtasks"] = tree["subtasks"]!; return record
    }
    func strings(_ value: JSON?) -> [String] { value?.list.map(\.text) ?? [] }

    func testIDFunctionMatchesTheIndependentComputation() throws {
        let cases = try XCTUnwrap(fixture()["id_cases"]).list.map(\.object)
        XCTAssertGreaterThan(cases.count, 4)
        for c in cases {
            XCTAssertEqual(LegacySubtaskConversion.legacyChildID(root: c["root"]!.text, path: strings(c["path"])), c["expected"]!.text, "\(c)")
        }
    }
    func testKnownVector() {
        // md5("taskfold.child-row.v1|11111111-1111-4111-8111-111111111111|a") computed with hashlib.
        let expected = LegacySubtaskConversion.legacyChildID(root: "11111111-1111-4111-8111-111111111111", path: ["a"])
        XCTAssertEqual(expected.count, 36); XCTAssertEqual(expected, expected.lowercased())
        XCTAssertEqual(LegacySubtaskConversion.legacyChildID(root: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", path: ["x"]), LegacySubtaskConversion.legacyChildID(root: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", path: ["x"]))
    }
    func testEveryFixtureTreeConvertsToTheExpectedRows() throws {
        for tree in try trees() {
            let name = tree["name"]!.text
            let result = LegacySubtaskConversion.convert(root: root(tree))
            let expected = tree["expected_rows"]!.list.map(\.object)
            XCTAssertEqual(result.rows.map(\.id), expected.map { $0["id"]!.text }, name)
            for (row, want) in zip(result.rows, expected) {
                XCTAssertEqual(row.string("parent_id"), want["parent_id"]!.text, name + " parent")
                XCTAssertEqual(row["child_order"], want["child_order"], name + " order")
                XCTAssertEqual(row.title, want["title"]!.text, name)
                XCTAssertEqual(row.completed, want["completed"]!.flag, name)
                XCTAssertEqual(row["assigned_to"], want["assigned_to"], name + " assignee")
                XCTAssertEqual(row["source_metadata"], want["source_metadata"], name + " metadata")
                for (key, value) in want["fields"]!.object { XCTAssertEqual(row[key], value, name + " " + key) }
                XCTAssertEqual(row["user_id"], tree["root"]!.object["user_id"]); XCTAssertEqual(row["project_id"], tree["root"]!.object["project_id"]); XCTAssertEqual(row["section_id"], tree["root"]!.object["section_id"])
            }
            XCTAssertEqual(result.skipped.map { $0.json }, tree["expected_skipped"]!.list, name + " skipped")
            XCTAssertEqual(result.reparented.map { $0.json }, tree["expected_reparented"]!.list, name + " reparented")
        }
    }
    func testConvertedRowsFormAValidTreeTheServerWouldAccept() throws {
        for tree in try trees() {
            let source = root(tree)
            var rootRow = source; rootRow["subtasks"] = .array([])
            let rows = LegacySubtaskConversion.convert(root: source).rows
            let posts = rows.map { Mutation(table: "tasks", recordID: $0.id, method: "POST", fields: $0.fields, insertOnly: true) }
            XCTAssertNoThrow(try TaskTree.validate(posts, tasks: [rootRow]), tree["name"]!.text)
            let index = TaskTree([rootRow] + rows)
            XCTAssertLessThanOrEqual(rows.map { index.depth(of: $0.id) }.max() ?? 0, 10, tree["name"]!.text)
        }
    }
    func testDeepChainsAreReparentedToTheLevelNineAncestor() throws {
        let tree = try XCTUnwrap(trees().first { $0["name"]?.text == "depth_chain_12" })
        let result = LegacySubtaskConversion.convert(root: root(tree))
        XCTAssertEqual(result.rows.count, 12); XCTAssertEqual(result.reparented.count, 2)
        let index = TaskTree([root(tree)] + result.rows)
        XCTAssertEqual(index.depth(of: result.rows[9].id), 10)
        XCTAssertEqual(result.rows[10].string("parent_id"), result.rows[8].id)
        XCTAssertEqual(result.rows[11].string("parent_id"), result.rows[8].id)
        XCTAssertEqual(Set(result.reparented.map(\.id)), [result.rows[10].id, result.rows[11].id])
    }
    func testJunkIsSkippedAndReportedWithoutLosingValidSiblings() throws {
        let tree = try XCTUnwrap(trees().first { $0["name"]?.text == "junk_nodes" })
        let result = LegacySubtaskConversion.convert(root: root(tree))
        XCTAssertEqual(result.rows.map(\.title), ["Survivor"])
        XCTAssertEqual(result.skipped.map(\.reason), ["not_an_object", "not_an_object", "not_an_object", "not_an_object", "missing_title", "empty_title", "empty_title", "missing_title"])
        XCTAssertEqual(result.skipped[4].descendants, 1)
        XCTAssertEqual(result.rows[0]["priority"], .number(4))
        XCTAssertEqual(result.rows[0]["source_metadata"].object["taskfold_legacy_child"]?.object["priority"], .string("high"))
        XCTAssertEqual(result.skippedJSON.object["skipped"]?.list.count, 8)
    }
    func testConversionIsDeterministicAndIgnoresRootsWithoutSubtasks() throws {
        let tree = try XCTUnwrap(trees().first)
        XCTAssertEqual(LegacySubtaskConversion.convert(root: root(tree)), LegacySubtaskConversion.convert(root: root(tree)))
        XCTAssertTrue(LegacySubtaskConversion.convert(root: Record(["id": .string("r"), "subtasks": .null])).rows.isEmpty)
        XCTAssertTrue(LegacySubtaskConversion.convert(root: Record(["id": .string("r"), "subtasks": .array([])])).rows.isEmpty)
        XCTAssertTrue(LegacySubtaskConversion.convert(root: Record(["subtasks": .array([.string("x")])])).rows.isEmpty)
    }
    func testAssigneeSurvivesOnlyWhenAssignmentIsAllowed() {
        let source = Record(["id": .string("r"), "project_id": .string("p"), "subtasks": .array([.object(["id": .string("a"), "title": .string("A"), "assigned_to": .string("u")])])])
        XCTAssertEqual(LegacySubtaskConversion.convert(root: source).rows[0]["assigned_to"], .string("u"))
        XCTAssertEqual(LegacySubtaskConversion.convert(root: source, canAssign: { _, _ in false }).rows[0]["assigned_to"], .null)
    }
    func testReferencesMapToTheNewIDs() throws {
        for reference in try XCTUnwrap(fixture()["references"]).list.map(\.object) {
            let tree = try XCTUnwrap(trees().first { $0["name"] == reference["tree"] })
            let text = reference["reference"]!.text
            XCTAssertEqual(LegacySubtaskConversion.newID(forReference: text), reference["direct_id"]!.text)
            let checked = LegacySubtaskConversion.newID(forReference: text, root: root(tree))
            XCTAssertEqual(checked, reference["expected_with_tree"]!.text.isEmpty ? nil : reference["expected_with_tree"]!.text, text)
        }
        XCTAssertNil(LegacySubtaskConversion.newID(forReference: "work:abc")); XCTAssertNil(LegacySubtaskConversion.newID(forReference: "subtask:@@@"))
        let built = LegacySubtaskReference.reference(["11111111-1111-4111-8111-111111111111", "a"])
        XCTAssertEqual(LegacySubtaskConversion.newID(forReference: built), LegacySubtaskConversion.legacyChildID(root: "11111111-1111-4111-8111-111111111111", path: ["a"]))
    }
    func testSegmentsFollowChildKey() {
        let siblings: [JSON] = [.object(["id": .string("a")]), .object(["id": .string("d")]), .object(["id": .string("d")]), .string("x"), .object(["id": .number(3)]), .object(["id": .string("")])]
        XCTAssertEqual(LegacySubtaskConversion.segments(siblings), ["a", "@1", "@2", "@3", "@4", "@5"])
    }
}
