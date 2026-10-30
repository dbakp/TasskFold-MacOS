import XCTest
@testable import TaskfoldCore

final class ChildTaskFieldOpeningTests: XCTestCase {
    private func fixture() throws -> (Record, [String: JSON], WorkspaceBinding) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "child-task-record-read", withExtension: "json", subdirectory: "Fixtures"))
        let file = try TaskfoldJSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        return (Record(file["root"]!.object), file["response"]!.object, WorkspaceBinding(account: file["account"]!.text, generation: UUID()))
    }
    private func read(_ root: Record, _ response: [String: JSON], _ binding: WorkspaceBinding) throws -> ChildTaskRecordRead {
        let context = try ChildTaskRecordContext(account: binding.account, origin: "https://child-record.test", workspace: binding.generation, session: UUID(), access: UUID(), snapshot: UUID(), root: root)
        return try ChildTaskRecordRead(data: TaskfoldJSONEncoder().encode(response), context: context)
    }
    private func projects(_ root: Record) -> [Record] {
        root.string("project_id").isEmpty ? [] : [Record(["id": root["project_id"], "name": .string("Fixture project")])]
    }
    private func reference(_ root: Record, _ keys: [String]) -> String {
        keys.reduce(root.id) { SubtaskTree.reference(parent: $0, key: $1) }
    }
    func testOpeningSelectsExactNestedChildRatherThanFirstRow() throws {
        let (root, response, binding) = try fixture(), current = try read(root, response, binding)
        let opening = try ChildTaskFieldOpening(reference: reference(root, ["parent", "child"]), root: root, workspace: binding)
        XCTAssertEqual(try opening.key(in: current), "child")
        XCTAssertNotEqual(try opening.key(in: current), current.orderedNodes.first?.key)
        let command = try ChildTaskFieldCommand(read: current, key: opening.key(in: current), changes: ["title": .string("Selected child only")])
        XCTAssertEqual(command.body["node_key"], .string("child"))
    }
    func testMissingAndMovedPathsNeverFallBackToAnotherTask() throws {
        let (root, response, binding) = try fixture(), current = try read(root, response, binding)
        for keys in [["missing"], ["child"], ["parent", "missing"], ["parent", "child", "missing"]] {
            let opening = try ChildTaskFieldOpening(reference: reference(root, keys), root: root, workspace: binding)
            XCTAssertThrowsError(try opening.key(in: current))
        }
    }
    func testWorkspaceAccountAndReturnIncarnationsCannotReuseOpening() throws {
        let (root, response, binding) = try fixture()
        let opening = try ChildTaskFieldOpening(reference: reference(root, ["parent"]), root: root, workspace: binding)
        XCTAssertTrue(opening.permits(account: binding.account, generation: binding.generation, root: root))
        XCTAssertFalse(opening.permits(account: UUID().uuidString.lowercased(), generation: binding.generation, root: root))
        XCTAssertFalse(opening.permits(account: binding.account, generation: UUID(), root: root))
        XCTAssertThrowsError(try opening.key(in: read(root, response, WorkspaceBinding(account: binding.account, generation: UUID()))))
        XCTAssertFalse(opening.permits(account: binding.account, generation: binding.generation, root: nil))
    }
    func testParentOwnershipProjectAndGenerationChangesStopOpening() throws {
        let (root, _, binding) = try fixture()
        let opening = try ChildTaskFieldOpening(reference: reference(root, ["parent"]), root: root, workspace: binding)
        for key in ["id", "user_id", "project_id", "task_generation"] {
            var changed = root; changed[key] = .string(UUID().uuidString.lowercased())
            XCTAssertFalse(opening.permits(account: binding.account, generation: binding.generation, root: changed), key)
        }
        var updated = root; updated["title"] = .string("A supported edit refreshed the parent")
        XCTAssertTrue(opening.permits(account: binding.account, generation: binding.generation, root: updated))
    }
    func testWrongRootMalformedReferenceAndUnaddressableDepthAreRejected() throws {
        let (root, _, binding) = try fixture()
        for ref in [root.id, "subtask:broken", SubtaskTree.reference(parent: UUID().uuidString.lowercased(), key: "parent"), reference(root, Array(repeating: "nested", count: 25))] {
            XCTAssertThrowsError(try ChildTaskFieldOpening(reference: ref, root: root, workspace: binding))
        }
    }
    func testAddressableEscapedKeysFitWithoutAcceptingOversizedReferences() throws {
        let (root, _, binding) = try fixture()
        let keys = Array(repeating: String(repeating: "\u{0010}", count: 128), count: 24)
        XCTAssertEqual(try ChildTaskFieldOpening(reference: reference(root, keys), root: root, workspace: binding).path.count, 24)
        XCTAssertThrowsError(try ChildTaskFieldOpening(reference: reference(root, [String(repeating: "a", count: 129)]), root: root, workspace: binding))
        XCTAssertThrowsError(try ChildTaskFieldOpening(reference: "subtask:" + String(repeating: "A", count: 32_768), root: root, workspace: binding))
    }
    func testOutlineExpandsOnlyVisibleAncestorsInAuthoredOrder() throws {
        let (root, _, binding) = try fixture()
        let parent = reference(root, ["parent"]), child = reference(root, ["parent", "child"])
        func rows(_ expanded: Set<String>) throws -> [String] {
            try ChildTaskListOutline.rows([root], expanded: expanded, projects: projects(root), workspace: binding, includeCompleted: false).map(\.id)
        }
        XCTAssertEqual(try rows([]), [root.id])
        XCTAssertEqual(try rows([root.id]), [root.id, parent])
        XCTAssertEqual(try rows([root.id, parent]), [root.id, parent, child])
        XCTAssertEqual(try rows([parent]), [root.id])
    }
    func testOutlineCompletionVisibilityDoesNotOrphanNestedChildren() throws {
        let (original, _, binding) = try fixture(); var root = original, children = root["subtasks"].list, parent = children[0].object
        parent["completed"] = .bool(true); children[0] = .object(parent); root["subtasks"] = .array(children)
        let expanded: Set<String> = [root.id, reference(root, ["parent"])]
        XCTAssertEqual(try ChildTaskListOutline.rows([root], expanded: expanded, projects: projects(root), workspace: binding, includeCompleted: false).map(\.id), [root.id])
        XCTAssertEqual(try ChildTaskListOutline.rows([root], expanded: expanded, projects: projects(root), workspace: binding, includeCompleted: true).count, 3)
    }
    func testExistingFlatFilterRowsAreNotExpandedAgain() throws {
        let (root, _, binding) = try fixture()
        let index = try TaskHierarchyIndex(roots: [root], projects: projects(root), workspace: binding)
        let rows = index.records(in: .subtasks)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(try ChildTaskListOutline.rows(rows, expanded: Set(rows.map(\.id)), projects: projects(root), workspace: binding, includeCompleted: false), rows)
    }
    func testMalformedOutlineCannotReturnPartiallyExpandedWork() throws {
        let (original, _, binding) = try fixture(); var root = original
        root["subtasks"] = .array([.object(["id": .string("same"), "title": .string("A")]), .object(["id": .string("same"), "title": .string("B")])])
        XCTAssertThrowsError(try ChildTaskListOutline.rows([root], expanded: [root.id], projects: projects(root), workspace: binding, includeCompleted: false))
    }
    func testRawUnicodePathCannotSelectACanonicalEquivalentNode() throws {
        let (original, originalResponse, binding) = try fixture()
        var root = original, response = originalResponse
        var children = root["subtasks"].list, parent = children[0].object
        parent["id"] = .string("Café"); children[0] = .object(parent); root["subtasks"] = .array(children)
        var rows = response["records"]!.list
        for index in rows.indices {
            var row = rows[index].object
            if row["node_key"] == .string("parent") {
                row["node_key"] = .string("Café"); var fields = row["fields"]!.object; fields["id"] = .string("Café"); row["fields"] = .object(fields)
            } else { row["parent_key"] = .string("Café") }
            var path = row["identity_path"]!.list; path[0] = .string("Café"); row["identity_path"] = .array(path); rows[index] = .object(row)
        }
        response["records"] = .array(rows)
        let current = try read(root, response, binding)
        let exact = try ChildTaskFieldOpening(reference: reference(root, ["Café"]), root: root, workspace: binding)
        XCTAssertEqual(try exact.key(in: current), "Café")
        let other = try ChildTaskFieldOpening(reference: reference(root, ["Cafe\u{301}"]), root: root, workspace: binding)
        XCTAssertThrowsError(try other.key(in: current))
    }
}
