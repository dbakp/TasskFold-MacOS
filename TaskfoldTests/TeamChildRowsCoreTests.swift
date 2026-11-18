import XCTest
@testable import TaskfoldCore

/// The contract of "subtasks are rows": no JSON `subtasks` column on new tasks, team edits and lifecycle requests that
/// carry `parent_id` / `child_order`, empty legacy columns stripped at every boundary, old backups converted into rows.
final class TeamChildRowsCoreTests: XCTestCase {
    private let account = "11111111-1111-4111-8111-111111111111"
    private let team = "22222222-2222-4222-8222-222222222222"
    private let project = "33333333-3333-4333-8333-333333333333"
    private let taskID = "44444444-4444-4444-8444-444444444444"
    private let parentID = "55555555-5555-4555-8555-555555555555"
    private let generation = "66666666-6666-4666-8666-666666666666"
    private var scope: TeamTaskEditScope { TeamTaskEditScope(account: account, origin: "https://synthetic.example", team: team, project: project) }

    private func teamRow(id: String? = nil) -> Record {
        var row = Record.task(user: account, project: project)
        row["id"] = .string(id ?? taskID); row["title"] = .string("Row"); row["task_generation"] = .string(generation)
        return row
    }

    // MARK: 1. Record.task

    func testNewTaskRecordsCarryNoSubtasksKey() {
        XCTAssertNil(Record.task(user: account).fields["subtasks"])
        XCTAssertNil(Record.task(user: account, project: project, date: Date()).fields["subtasks"])
        XCTAssertNil(Record.task(user: account, project: project, date: nil, createdAt: "2026-11-01T10:00:00Z").fields["subtasks"])
    }

    // MARK: 2. TeamTaskEditScope.body(for:)

    private func patch(_ fields: [String: JSON], base: [String: JSON]) -> Mutation {
        var baseline = base; baseline["project_id"] = .string(project); baseline["task_generation"] = .string(generation)
        return Mutation(table: "tasks", recordID: taskID, method: "PATCH", fields: fields, baseline: baseline, teamTaskScope: scope)
    }

    func testTeamPatchAcceptsParentAndChildOrderWithBaseValues() throws {
        let toParent = patch(["parent_id": .string(parentID), "child_order": .number(2.5)], base: ["parent_id": .null, "child_order": .null])
        let body = try scope.body(for: toParent)
        XCTAssertEqual(body["changes"], .object(["parent_id": .string(parentID), "child_order": .number(2.5)]))
        XCTAssertEqual(body["task_id"], .string(taskID)); XCTAssertEqual(body["task_generation"], .string(generation))
        // Detaching a child: both fields go back to null.
        let detach = patch(["parent_id": .null, "child_order": .null], base: ["parent_id": .string(parentID), "child_order": .number(1)])
        XCTAssertEqual(try scope.body(for: detach)["changes"], .object(["parent_id": .null, "child_order": .null]))
        XCTAssertNoThrow(try scope.body(for: patch(["child_order": .number(0)], base: ["child_order": .number(1)])))
    }

    func testTeamPatchRejectsBadParentOrderAndTheRemovedSubtasksColumn() {
        for parent: JSON in [.string("not-a-uuid"), .string(""), .number(1), .bool(true), .array([])] {
            XCTAssertThrowsError(try scope.body(for: patch(["parent_id": parent], base: ["parent_id": .null])), String(describing: parent))
        }
        for order: JSON in [.number(.infinity), .number(.nan), .string("1"), .bool(false)] {
            XCTAssertThrowsError(try scope.body(for: patch(["child_order": order], base: ["child_order": .null])), String(describing: order))
        }
        // A base value is required for every changed field.
        XCTAssertThrowsError(try scope.body(for: patch(["parent_id": .string(parentID)], base: [:])))
        // The JSON column is not a team field any more, whatever its value or baseline.
        XCTAssertFalse(TeamTaskEditScope.fields.contains("subtasks"))
        XCTAssertTrue(TeamTaskEditScope.fields.isSuperset(of: ["parent_id", "child_order"]))
        for value: JSON in [.array([]), .array([.object(["id": .string("a"), "title": .string("A")])]), .null] {
            XCTAssertThrowsError(try scope.body(for: patch(["subtasks": value], base: ["subtasks": .array([])])), String(describing: value))
        }
    }

    // MARK: 3. TeamTaskEditScope.lifecycleBody(for:)

    func testLifecycleCreateSendsParentAndChildOrder() throws {
        var row = teamRow(); row["parent_id"] = .string(parentID); row["child_order"] = .number(3)
        let create = Mutation(table: "tasks", recordID: row.id, method: "POST", fields: row.fields, insertOnly: true, teamTaskScope: scope)
        let body = try scope.lifecycleBody(for: create), record = try XCTUnwrap(body["record"]?.object)
        XCTAssertEqual(record["parent_id"], .string(parentID)); XCTAssertEqual(record["child_order"], .number(3))
        XCTAssertNil(record["subtasks"]); XCTAssertNil(record["waiting_on"])
        XCTAssertEqual(try scope.lifecycleAction(for: create), "create")
    }

    func testLifecycleRecordDropsWaitingOnSubtasksAndNullHeading() throws {
        var row = teamRow(); row["waiting_on"] = .null; row["subtasks"] = .array([]); row["is_heading"] = .null; row["description"] = .string("kept")
        let delete = Mutation(table: "tasks", recordID: row.id, method: "DELETE", fields: [:], baseline: row.fields, teamTaskScope: scope)
        let record = try XCTUnwrap(try scope.lifecycleBody(for: delete)["record"]?.object)
        XCTAssertNil(record["waiting_on"]); XCTAssertNil(record["subtasks"]); XCTAssertNil(record["is_heading"])
        XCTAssertEqual(record["description"], .string("kept")); XCTAssertEqual(record["id"], .string(taskID))
        // A NULL heading flag is not type metadata, so the plain scope needs no typed protocol for it.
        XCTAssertNil(try scope.lifecycleBody(for: delete)["task_type_lifecycle_protocol"])
        // The same helper is what the body uses, and it keeps an explicit type.
        var typed = row; typed["is_heading"] = .bool(false)
        XCTAssertEqual(TeamTaskEditScope.lifecycleRecord(typed.fields)["is_heading"], .bool(false))
        XCTAssertNil(TeamTaskEditScope.lifecycleRecord(typed.fields)["subtasks"])
    }

    // MARK: 4. LegacySubtaskColumn.outbound

    func testOutboundDropsEmptySubtasksFromFieldsAndBaselineOfAPlainPatch() {
        for empty: JSON in [.array([]), .null] {
            let change = Mutation(table: "tasks", recordID: taskID, method: "PATCH", fields: ["title": .string("New"), "subtasks": empty], baseline: ["title": .string("Old"), "subtasks": empty])
            let sent = LegacySubtaskColumn.outbound(change)
            XCTAssertNil(sent.fields["subtasks"]); XCTAssertNil(sent.baseline?["subtasks"])
            XCTAssertEqual(sent.fields["title"], .string("New")); XCTAssertEqual(sent.baseline?["title"], .string("Old")); XCTAssertEqual(sent.id, change.id)
        }
        // Only one side empty is enough to strip that side.
        let mixed = Mutation(table: "tasks", recordID: taskID, method: "PATCH", fields: ["subtasks": .array([])], baseline: ["subtasks": .array([.object(["id": .string("a")])])])
        XCTAssertNil(LegacySubtaskColumn.outbound(mixed).fields["subtasks"])
    }

    func testOutboundLeavesANonEmptyTreeAndOtherTablesAlone() {
        let tree: JSON = .array([.object(["id": .string("a"), "title": .string("A")])])
        let kept = Mutation(table: "tasks", recordID: taskID, method: "PATCH", fields: ["subtasks": tree], baseline: ["subtasks": tree])
        XCTAssertEqual(LegacySubtaskColumn.outbound(kept), kept)
        let project = Mutation(table: "projects", recordID: taskID, method: "PATCH", fields: ["subtasks": .array([])], baseline: ["subtasks": .array([])])
        XCTAssertEqual(LegacySubtaskColumn.outbound(project), project)
        XCTAssertTrue(LegacySubtaskColumn.isEmpty(.array([]))); XCTAssertTrue(LegacySubtaskColumn.isEmpty(.null))
        XCTAssertFalse(LegacySubtaskColumn.isEmpty(tree)); XCTAssertFalse(LegacySubtaskColumn.isEmpty(nil))
    }

    // MARK: 5. Snapshot decode and merge

    func testDecodingASnapshotStripsEmptySubtasksButKeepsATree() throws {
        let tree: JSON = .array([.object(["id": .string("a"), "title": .string("A")])])
        var plain = teamRow(id: "a1111111-1111-4111-8111-111111111111"); plain["subtasks"] = .array([])
        var null = teamRow(id: "a2222222-2222-4222-8222-222222222222"); null["subtasks"] = .null
        var legacy = teamRow(id: "a3333333-3333-4333-8333-333333333333"); legacy["subtasks"] = tree
        let snapshot = Snapshot(tables: ["tasks": [plain, null, legacy]])
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        let rows = try XCTUnwrap(decoded.tables["tasks"])
        XCTAssertEqual(rows.count, 3)
        XCTAssertNil(rows[0].fields["subtasks"]); XCTAssertNil(rows[1].fields["subtasks"])
        XCTAssertEqual(rows[2]["subtasks"], tree, "Only pre-update local data holds a tree; it is converted later, not dropped")
    }

    func testMergeRemoteStripsEmptySubtasksFromIncomingRows() {
        var snapshot = Snapshot(tables: ["tasks": [teamRow(id: "b1111111-1111-4111-8111-111111111111")]])
        var incoming = teamRow(id: "b2222222-2222-4222-8222-222222222222"); incoming["subtasks"] = .array([])
        var replaced = teamRow(id: "b1111111-1111-4111-8111-111111111111"); replaced["subtasks"] = .array([]); replaced["title"] = .string("Server title")
        snapshot.mergeRemote(["tasks": [replaced, incoming]])
        let rows = snapshot.tables["tasks"] ?? []
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.fields["subtasks"] == nil })
        XCTAssertEqual(rows.first { $0.id == replaced.id }?.title, "Server title")
    }

    // MARK: 6. Backup restore

    func testRestoringAnOlderBackupTurnsTheJSONTreeIntoRowsAndNeverSendsTheColumn() throws {
        let rootID = "c0000000-0000-4000-8000-000000000001", other = "d0000000-0000-4000-8000-000000000002"
        var root = Record.task(user: account); root["id"] = .string(rootID); root["title"] = .string("Root"); root["task_generation"] = .string(generation)
        root["subtasks"] = .array([
            .object(["id": .string("a"), "title": .string("A"), "completed": .bool(true), "subtasks": .array([.object(["id": .string("b"), "title": .string("B")])])]),
            .object(["title": .string("Plain")])])
        let file = try WorkspaceBackup.read(WorkspaceBackup.make(Snapshot(tables: ["tasks": [root]]), account: account, childRows: false).data())
        XCTAssertLessThan(file.version, 3, "An older file keeps its subtasks as JSON")
        for rows in [true, false] {
            let plan = try file.plan(current: Snapshot(), account: account, childRows: rows)
            let posts = plan.changes.filter { $0.table == "tasks" && $0.method == "POST" }
            let a = LegacySubtaskConversion.legacyChildID(root: rootID, path: ["a"]), b = LegacySubtaskConversion.legacyChildID(root: rootID, path: ["a", "b"])
            let plain = LegacySubtaskConversion.legacyChildID(root: rootID, path: ["@1"])
            XCTAssertEqual(Set(posts.map(\.recordID)), [rootID, a, b, plain], "childRows: \(rows)")
            XCTAssertEqual(posts.first?.recordID, rootID)
            XCTAssertEqual(posts.first { $0.recordID == a }?.fields["parent_id"], .string(rootID))
            XCTAssertEqual(posts.first { $0.recordID == b }?.fields["parent_id"], .string(a))
            XCTAssertEqual(posts.first { $0.recordID == a }?.fields["completed"], .bool(true))
            XCTAssertTrue(plan.changes.allSatisfy { $0.fields["subtasks"] == nil && $0.baseline?["subtasks"] == nil }, "No mutation carries a subtasks key")
        }
        // Restoring into another account maps the converted rows too.
        let moved = try file.plan(current: Snapshot(), account: other)
        let map = try XCTUnwrap(moved.mappedIDs["tasks"])
        let childA = LegacySubtaskConversion.legacyChildID(root: rootID, path: ["a"])
        XCTAssertEqual(moved.changes.first { $0.recordID == map[childA] }?.fields["parent_id"], .string(map[rootID]!))
        XCTAssertTrue(moved.changes.allSatisfy { $0.fields["subtasks"] == nil })
    }

    // MARK: 7. TaskSelectionPlan

    func testSelectionPlanCompletesAndDeletesPlainRows() throws {
        let workspace = WorkspaceBinding(account: account, generation: UUID())
        let first = teamRow(id: "e1111111-1111-4111-8111-111111111111"), second = teamRow(id: "e2222222-2222-4222-8222-222222222222")
        var child = teamRow(id: "e3333333-3333-4333-8333-333333333333"); child["parent_id"] = first["id"]; child["child_order"] = .number(1)
        let rows = [first, second, child], projects = [Record(["id": .string(project), "user_id": .string(account), "name": .string("P")])]
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let completion = try TaskSelectionPlan.changes([.init(task: child, action: .completion(true, at), workspace: workspace)], accessibleRoots: rows, projects: projects, workspace: workspace)
        XCTAssertEqual(completion.map(\.recordID), [child.id]); XCTAssertEqual(completion.first?.method, "PATCH")
        XCTAssertEqual(completion.first?.fields["completed"], .bool(true))
        let deletion = try TaskSelectionPlan.changes([.init(task: first, action: .delete, workspace: workspace), .init(task: second, action: .delete, workspace: workspace)], accessibleRoots: rows, projects: projects, workspace: workspace)
        XCTAssertEqual(Set(deletion.map(\.recordID)), [first.id, second.id]); XCTAssertTrue(deletion.allSatisfy { $0.method == "DELETE" })
        XCTAssertEqual(TaskSelectionPlan.maximumRequests, 1_000)
    }

    func testSelectionPlanRefusesALegacySubtaskReference() {
        let workspace = WorkspaceBinding(account: account, generation: UUID())
        let root = teamRow(id: "f1111111-1111-4111-8111-111111111111")
        var virtual = root; virtual["id"] = .string(LegacySubtaskReference.reference([root.id, "child"]))
        for action in [TaskSelectionPlan.Action.completion(true, Date()), .delete, .patch(["title": .string("Renamed")])] {
            XCTAssertThrowsError(try TaskSelectionPlan.changes([.init(task: virtual, action: action, workspace: workspace)], accessibleRoots: [root, virtual], projects: [], workspace: workspace)) {
                XCTAssertTrue($0 is TaskSelectionPlan.Failure)
            }
        }
    }
}
