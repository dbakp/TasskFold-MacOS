import XCTest
@testable import TaskfoldCore

final class BackupV3Tests: XCTestCase {
    let owner = "11111111-1111-4111-8111-111111111111"
    let other = "22222222-2222-4222-8222-222222222222"
    let project = "33333333-3333-4333-8333-333333333333"
    let rootID = "aaaaaaaa-0000-4000-8000-000000000001"
    let childID = "aaaaaaaa-0000-4000-8000-000000000002"
    let grandID = "aaaaaaaa-0000-4000-8000-000000000003"

    func task(_ id: String, title: String, parent: String? = nil, order: Double? = nil, project: String? = nil, extra: [String: JSON] = [:]) -> Record {
        var fields: [String: JSON] = ["id": .string(id), "user_id": .string(owner), "title": .string(title), "completed": .bool(false), "priority": .number(4)]
        fields["project_id"] = (project ?? self.project).isEmpty ? .null : .string(project ?? self.project)
        if let parent { fields["parent_id"] = .string(parent) }
        if let order { fields["child_order"] = .number(order) }
        for (key, value) in extra { fields[key] = value }
        return Record(fields)
    }
    func snapshot(_ tasks: [Record]) -> Snapshot {
        var value = Snapshot()
        value.tables = ["projects": [Record(["id": .string(project), "user_id": .string(owner), "name": .string("P"), "color": .string("#e31e4b")])], "tasks": tasks]
        return value
    }
    var family: [Record] { [task(rootID, title: "Root"), task(childID, title: "Child", parent: rootID, order: 1), task(grandID, title: "Grand", parent: childID, order: 2.5)] }

    // MARK: writing
    func testOffAndWithoutParentsKeepsTheCurrentFormat() throws {
        let file = WorkspaceBackup.make(snapshot([task(rootID, title: "Root")]), account: owner, childRows: false)
        XCTAssertEqual(file.version, 1); XCTAssertNil(file.capabilities)
        let headed = WorkspaceBackup.make(snapshot([task(rootID, title: "Root", extra: ["is_heading": .bool(true)])]), account: owner, childRows: false)
        XCTAssertEqual(headed.version, 2); XCTAssertEqual(headed.capabilities, ["task_headings"])
    }
    /// Since migration A every task from the server carries empty `parent_id` and `child_order`.
    /// An older-format backup leaves them out, and still restores one that kept them empty.
    func testEmptyChildColumnsStayRestorableInOlderFormats() throws {
        let fromServer = task(rootID, title: "Root", extra: ["parent_id": .null, "child_order": .null])
        let file = WorkspaceBackup.make(snapshot([fromServer]), account: owner, childRows: false)
        XCTAssertEqual(file.version, 1)
        XCTAssertNil(file.tables["tasks"]?.first?.fields["parent_id"]); XCTAssertNil(file.tables["tasks"]?.first?.fields["child_order"])
        XCTAssertEqual(try WorkspaceBackup.read(file.data()).tables["tasks"]?.count, 1)
        // A file written before this fix kept the empty columns.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: file.data()) as? [String: Any])
        var tables = try XCTUnwrap(object["tables"] as? [String: Any])
        var rows = try XCTUnwrap(tables["tasks"] as? [[String: Any]])
        rows[0]["parent_id"] = NSNull(); rows[0]["child_order"] = NSNull()
        tables["tasks"] = rows; object["tables"] = tables
        let old = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try WorkspaceBackup.read(old).tables["tasks"]?.count, 1)
        // A real parent in an older-format file is still refused.
        rows[0]["parent_id"] = childID; tables["tasks"] = rows; object["tables"] = tables
        XCTAssertThrowsError(try WorkspaceBackup.read(JSONSerialization.data(withJSONObject: object)))
    }
    func testVersionThreeIsWrittenForParentsOrWhenChildRowsAreOn() throws {
        XCTAssertEqual(WorkspaceBackup.make(snapshot(family), account: owner, childRows: false).version, 3)
        XCTAssertEqual(WorkspaceBackup.make(snapshot([task(rootID, title: "Root")]), account: owner, childRows: true).version, 3)
        let headed = WorkspaceBackup.make(snapshot(family + [task("aaaaaaaa-0000-4000-8000-000000000009", title: "H", extra: ["is_heading": .bool(true)])]), account: owner)
        XCTAssertEqual(headed.version, 3); XCTAssertEqual(headed.capabilities, ["task_headings"])
        let data = try headed.data()
        XCTAssertEqual(try WorkspaceBackup.read(data).tables["tasks"]?.count, 4)
    }
    func testVersionThreeRoundTrips() throws {
        let file = WorkspaceBackup.make(snapshot(family), account: owner)
        let read = try WorkspaceBackup.read(file.data())
        XCTAssertEqual(read.version, 3); XCTAssertEqual(read.tables["tasks"], family)
        XCTAssertEqual(try JSONDecoder().decode(JSON.self, from: file.data()).object["version"], .number(3))
    }

    // MARK: validation
    func testOlderVersionsStillRejectChildColumns() throws {
        var file = WorkspaceBackup.make(snapshot(family), account: owner); file.version = 1
        XCTAssertThrowsError(try file.validate())
        file.version = 2; file.capabilities = ["task_headings"]
        XCTAssertThrowsError(try file.validate())
    }
    func testVersionThreeRejectsBrokenStructure() throws {
        func invalid(_ tasks: [Record], _ fragment: String, line: UInt = #line) {
            var file = WorkspaceBackup.make(snapshot(tasks), account: owner); file.version = 3
            XCTAssertThrowsError(try file.validate(), line: line) { XCTAssertTrue(($0 as? BackupFailure)?.message.contains(fragment) == true, "\($0)", line: line) }
        }
        invalid([task(childID, title: "Orphan", parent: rootID, order: 1)], "no longer exists")
        invalid([task(rootID, title: "A", parent: childID, order: 1), task(childID, title: "B", parent: rootID, order: 1)], "own subtasks")
        invalid([task(rootID, title: "A"), task(childID, title: "B", parent: rootID, order: 1, project: "44444444-4444-4444-8444-444444444444")], "parent")
        var chain: [Record] = [task("00000000-0000-4000-8000-000000000000", title: "0")]
        for i in 1...11 { chain.append(task(String(format: "00000000-0000-4000-8000-%012d", i), title: "\(i)", parent: String(format: "00000000-0000-4000-8000-%012d", i - 1), order: 1)) }
        invalid(chain, "10 levels")
    }
    func testVersionOneFilesStillValidateAsBefore() throws {
        let file = WorkspaceBackup.make(snapshot([task(rootID, title: "Root", extra: ["subtasks": .array([.object(["id": .string("a"), "title": .string("A")])])])]), account: owner, childRows: false)
        XCTAssertEqual(file.version, 1); XCTAssertNoThrow(try file.validate())
    }

    // MARK: restoring
    func testRestoreCreatesParentsBeforeChildrenWhateverTheFileOrder() throws {
        var file = WorkspaceBackup.make(snapshot(family), account: owner)
        file.tables["tasks"] = file.tables["tasks"]!.reversed()
        let plan = try file.plan(current: Snapshot(), account: owner, childRows: true)
        let order = plan.changes.filter { $0.table == "tasks" }.map(\.recordID)
        XCTAssertEqual(order, [rootID, childID, grandID])
        XCTAssertEqual(plan.changes.first { $0.recordID == grandID }?.fields["parent_id"], .string(childID))
        XCTAssertEqual(plan.changes.first { $0.recordID == grandID }?.fields["child_order"], .number(2.5))
        XCTAssertNil(plan.changes.first { $0.recordID == rootID }?.fields["parent_id"]); XCTAssertNil(plan.changes.first { $0.recordID == rootID }?.fields["child_order"])
        XCTAssertNoThrow(try TaskTree.validate(plan.changes, tasks: []))
    }
    func testRestoringIntoAnotherAccountRemapsParentIDs() throws {
        let file = try WorkspaceBackup.read(WorkspaceBackup.make(snapshot(family), account: owner).data())
        let plan = try file.plan(current: Snapshot(), account: other, childRows: true)
        let map = try XCTUnwrap(plan.mappedIDs["tasks"])
        XCTAssertNotEqual(map[rootID], rootID)
        let child = try XCTUnwrap(plan.changes.first { $0.recordID == map[childID] })
        XCTAssertEqual(child.fields["parent_id"], .string(map[rootID]!)); XCTAssertEqual(child.fields["user_id"], .string(other))
        XCTAssertEqual(plan.changes.first { $0.recordID == map[grandID] }?.fields["parent_id"], .string(map[childID]!))
        XCTAssertEqual(plan.added, plan.changes.filter { $0.method == "POST" }.count)
    }
    func testRestoreIsIdempotentAgainstExistingRows() throws {
        let file = WorkspaceBackup.make(snapshot(family), account: owner)
        let current = snapshot(family)
        let keep = try file.plan(current: current, account: owner, policy: .keepCurrent, childRows: true)
        XCTAssertTrue(keep.changes.filter { $0.table == "tasks" }.isEmpty)
        var moved = family; moved[2] = task(grandID, title: "Grand", parent: rootID, order: 9)
        let plan = try file.plan(current: snapshot(moved), account: owner, policy: .backupValues, childRows: true)
        let patch = try XCTUnwrap(plan.changes.first { $0.recordID == grandID })
        XCTAssertEqual(patch.method, "PATCH"); XCTAssertEqual(patch.fields["parent_id"], .string(childID)); XCTAssertEqual(patch.fields["child_order"], .number(2.5))
    }
    func testRestoringARootOverAChildDetachesIt() throws {
        var flat = family; flat[1] = task(childID, title: "Child")
        let file = WorkspaceBackup.make(snapshot(flat), account: owner, childRows: true)
        let plan = try file.plan(current: snapshot(family), account: owner, policy: .backupValues, childRows: true)
        let patch = try XCTUnwrap(plan.changes.first { $0.recordID == childID })
        XCTAssertEqual(patch.fields["parent_id"], .null); XCTAssertEqual(patch.fields["child_order"], .null)
    }
    func testAFileWithChildRowsIsRefusedWhileTheFlagIsOff() throws {
        let file = WorkspaceBackup.make(snapshot(family), account: owner)
        XCTAssertThrowsError(try file.plan(current: Snapshot(), account: owner, childRows: false)) {
            XCTAssertTrue(($0 as? BackupFailure)?.message.contains("separate tasks") == true)
        }
    }

    // MARK: older formats
    func legacyFile(version: Int = 1) throws -> WorkspaceBackup {
        let subtasks: JSON = .array([.object(["id": .string("a"), "title": .string("A"), "completed": .bool(true), "subtasks": .array([.object(["id": .string("b"), "title": .string("B")])])]), .object(["title": .string("Plain")])])
        let file = WorkspaceBackup.make(snapshot([task(rootID, title: "Root", extra: ["subtasks": subtasks])]), account: owner, childRows: false)
        XCTAssertEqual(file.version, 1)
        return try WorkspaceBackup.read(file.data())
    }
    func testJSONSubtasksBecomeRowsOnRestoreWhenChildRowsAreOn() throws {
        let plan = try legacyFile().plan(current: Snapshot(), account: owner, childRows: true)
        let posts = plan.changes.filter { $0.table == "tasks" }
        XCTAssertEqual(posts.count, 4)
        XCTAssertEqual(posts[0].recordID, rootID); XCTAssertNil(posts[0].fields["subtasks"])
        let a = LegacySubtaskConversion.legacyChildID(root: rootID, path: ["a"]), b = LegacySubtaskConversion.legacyChildID(root: rootID, path: ["a", "b"])
        let plain = LegacySubtaskConversion.legacyChildID(root: rootID, path: ["@1"])
        XCTAssertEqual(Set(posts.map(\.recordID)), [rootID, a, b, plain])
        XCTAssertEqual(posts[0].recordID, rootID)
        XCTAssertLessThan(posts.firstIndex { $0.recordID == a }!, posts.firstIndex { $0.recordID == b }!, "a parent is created before its child")
        XCTAssertEqual(posts.first { $0.recordID == b }?.fields["parent_id"], .string(a)); XCTAssertEqual(posts.first { $0.recordID == a }?.fields["parent_id"], .string(rootID))
        XCTAssertEqual(posts.first { $0.recordID == a }?.fields["completed"], .bool(true))
        XCTAssertTrue(plan.warnings.filter { $0.contains("left out") }.isEmpty)
        XCTAssertNoThrow(try TaskTree.validate(plan.changes, tasks: []))
        XCTAssertEqual(try legacyFile().plan(current: Snapshot(), account: owner, childRows: true).changes.map(\.recordID), plan.changes.map(\.recordID))
    }
    func testJSONSubtasksConvertIntoAnotherAccountToo() throws {
        let plan = try legacyFile().plan(current: Snapshot(), account: other, childRows: true)
        let map = try XCTUnwrap(plan.mappedIDs["tasks"])
        let a = LegacySubtaskConversion.legacyChildID(root: rootID, path: ["a"])
        XCTAssertEqual(plan.changes.first { $0.recordID == map[a] }?.fields["parent_id"], .string(map[rootID]!))
    }
    func testJSONSubtasksConvertToRowsEvenWhileTheFlagIsOff() throws {
        let subtasks: JSON = .array([.object(["id": .string("a"), "title": .string("A"), "subtasks": .array([.object(["id": .string("b"), "title": .string("B")])])])])
        let file = WorkspaceBackup.make(snapshot([task(rootID, title: "Root", extra: ["subtasks": subtasks])]), account: owner, childRows: false)
        let plan = try file.plan(current: Snapshot(), account: owner, childRows: false)
        let posts = plan.changes.filter { $0.table == "tasks" }
        XCTAssertEqual(posts.count, 3)
        XCTAssertNil(posts[0].fields["subtasks"]); XCTAssertNil(posts[0].fields["parent_id"])
        let a = LegacySubtaskConversion.legacyChildID(root: rootID, path: ["a"]), b = LegacySubtaskConversion.legacyChildID(root: rootID, path: ["a", "b"])
        XCTAssertEqual(Set(posts.map(\.recordID)), [rootID, a, b])
        XCTAssertEqual(posts.first { $0.recordID == b }?.fields["parent_id"], .string(a))
        XCTAssertTrue(posts.allSatisfy { $0.fields["subtasks"] == nil })
    }
}
