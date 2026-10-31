import XCTest
@testable import TaskfoldCore

final class ChildTaskListCompletionTests: XCTestCase {
    private func fixture() throws -> (Record, Record, ChildTaskRecordRead, [Record]) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "child-task-completion-command", withExtension: "json", subdirectory: "Fixtures"))
        let f = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url)), body = f["body"]!.object
        var child = body["baseline"]!.object
        child["id"] = body["node_key"]!; child["title"] = .string("Selected child")
        let root = Record(["id": body["task_id"]!, "user_id": body["account"]!, "task_generation": body["task_generation"]!, "project_id": body["project_id"]!, "subtasks": .array([.object(child)])])
        let context = try ChildTaskRecordContext(account: body["account"]!.text, origin: "https://child-list.test", workspace: UUID(), session: UUID(), access: UUID(), snapshot: UUID(), root: root)
        let read = try makeRead(context, fields: child, incarnation: body["incarnation"]!.text)
        let projects = root["project_id"] == .null ? [] : [Record(["id": root["project_id"], "is_archived": .bool(false)])]
        let task = try XCTUnwrap(TaskHierarchyIndex(roots: [root], projects: projects, workspace: WorkspaceBinding(account: context.account, generation: context.workspace)).items.last?.record)
        return (root, task, read, projects)
    }
    private func makeRead(_ context: ChildTaskRecordContext, fields: [String: JSON], incarnation: String) throws -> ChildTaskRecordRead {
        let root = context.root, key = fields["id"]!.text
        let data: [String: JSON] = ["protocol": .number(1), "account": .string(context.account), "task_id": .string(root.id), "task_generation": root["task_generation"], "project_id": root["project_id"], "projection_revision": .number(1), "root_kind": .string("array"), "records": .array([.object(["node_key": .string(key), "incarnation": .string(incarnation), "revision": .number(1), "parent_key": .null, "sibling_order": .number(0), "identity_path": .array([.string(key)]), "fields": .object(fields), "children_kind": .string("absent")])])]
        return try ChildTaskRecordRead(data: TaskfoldJSONEncoder().encode(data), context: context)
    }
    private func altered(_ read: ChildTaskRecordRead, root: Record? = nil, session: UUID? = nil, access: UUID? = nil) throws -> ChildTaskRecordRead {
        let c = read.context
        let context = try ChildTaskRecordContext(account: c.account, origin: c.origin, workspace: c.workspace, session: session ?? c.session, access: access ?? c.access, snapshot: UUID(), root: root ?? c.root)
        let fields = (root ?? c.root)["subtasks"].list[0].object
        return try makeRead(context, fields: fields, incarnation: read.orderedNodes[0].incarnation)
    }
    func testListClickTargetsObservedChildAndExistingServerCompletionProtocol() throws {
        let (root, task, read, projects) = try fixture()
        let intent = try ChildTaskListCompletionIntent(task: task, root: root, projects: projects, scope: ChildTaskFieldClientScope(read.context))
        let key = try intent.key(in: read)
        let command = try ChildTaskCompletionCommand(ChildTaskCompletionDraft(read: read, key: key, action: intent.completed ? .reopen : .complete))
        XCTAssertEqual(command.body["node_key"], read.orderedNodes[0].fields["id"])
        XCTAssertEqual(command.body["action"], .string("complete"))
        XCTAssertFalse(command.body.keys.contains("subtasks")); XCTAssertEqual(intent.title, "Selected child")
    }
    func testDifferentSessionAndAccessCannotResumeAListClick() throws {
        let (root, task, read, projects) = try fixture()
        let intent = try ChildTaskListCompletionIntent(task: task, root: root, projects: projects, scope: ChildTaskFieldClientScope(read.context))
        XCTAssertThrowsError(try intent.key(in: altered(read, session: UUID())))
        XCTAssertThrowsError(try intent.key(in: altered(read, access: UUID())))
    }
    func testStaleObservedCompletionIsRejectedBeforeReadOrWrite() throws {
        let (root, task, read, projects) = try fixture()
        var stale = task; stale["completed"] = .bool(true); stale["completed_at"] = .string("2026-10-31T12:00:00Z")
        XCTAssertThrowsError(try ChildTaskListCompletionIntent(task: stale, root: root, projects: projects, scope: ChildTaskFieldClientScope(read.context)))
    }
    func testChangedCompletionCohortWhileReadingRequiresFreshUserIntent() throws {
        let (root, task, read, projects) = try fixture()
        let intent = try ChildTaskListCompletionIntent(task: task, root: root, projects: projects, scope: ChildTaskFieldClientScope(read.context))
        var changed = root, child = root["subtasks"].list[0].object
        child["completed"] = .bool(true); child["completed_at"] = .string("2026-10-31T12:00:00Z"); changed["subtasks"] = .array([.object(child)])
        XCTAssertThrowsError(try intent.key(in: altered(read, root: changed)))
    }
    func testLegacyChildRefusesChangedCapturedTree() throws {
        let (root, task, read, projects) = try fixture()
        var legacyRoot = root, fields = root["subtasks"].list[0].object
        fields.removeValue(forKey: TeamChecklist.key); legacyRoot["subtasks"] = .array([.object(fields)])
        var legacyTask = task; legacyTask.fields.removeValue(forKey: TeamChecklist.key)
        let legacy = try altered(read, root: legacyRoot)
        let intent = try ChildTaskListCompletionIntent(task: legacyTask, root: legacyRoot, projects: projects, scope: ChildTaskFieldClientScope(read.context))
        XCTAssertEqual(try intent.key(in: legacy), fields["id"]!.text)
        fields["title"] = .string("Changed while reading"); legacyRoot["subtasks"] = .array([.object(fields)])
        XCTAssertThrowsError(try intent.key(in: altered(read, root: legacyRoot)))
    }
    func testChangedParentIncarnationCannotReceiveOldClick() throws {
        let (root, task, read, projects) = try fixture()
        let intent = try ChildTaskListCompletionIntent(task: task, root: root, projects: projects, scope: ChildTaskFieldClientScope(read.context))
        var changed = root; changed["task_generation"] = .string(UUID().uuidString.lowercased())
        XCTAssertThrowsError(try intent.key(in: altered(read, root: changed)))
    }
    func testArchivedAndUnknownProjectCannotCaptureEditableChild() throws {
        let (root, task, read, _) = try fixture()
        var projectRoot = root; projectRoot["project_id"] = .string(UUID().uuidString.lowercased())
        XCTAssertThrowsError(try ChildTaskListCompletionIntent(task: task, root: projectRoot, projects: [], scope: ChildTaskFieldClientScope(read.context)))
        let archived = Record(["id": projectRoot["project_id"], "is_archived": .bool(true)])
        XCTAssertThrowsError(try ChildTaskListCompletionIntent(task: task, root: projectRoot, projects: [archived], scope: ChildTaskFieldClientScope(read.context)))
    }
    func testUnchangedCompletionTokenAllowsDisjointTitleEdit() throws {
        let (root, task, read, projects) = try fixture()
        let intent = try ChildTaskListCompletionIntent(task: task, root: root, projects: projects, scope: ChildTaskFieldClientScope(read.context))
        var changed = root, fields = root["subtasks"].list[0].object
        fields["title"] = .string("Another device edited the title"); changed["subtasks"] = .array([.object(fields)])
        XCTAssertEqual(try intent.key(in: altered(read, root: changed)), fields["id"]!.text)
    }
    func testCompletionCycleTokenCannotBecomeAnotherToggle() throws {
        let (root, task, read, projects) = try fixture()
        let intent = try ChildTaskListCompletionIntent(task: task, root: root, projects: projects, scope: ChildTaskFieldClientScope(read.context))
        var changed = root, fields = root["subtasks"].list[0].object
        var token = fields[TeamChecklist.key]!.object; token["version"] = .number(2)
        fields[TeamChecklist.key] = .object(token); changed["subtasks"] = .array([.object(fields)])
        XCTAssertThrowsError(try intent.key(in: altered(read, root: changed)))
    }

    func testStaleRowOwnershipAndProjectCannotCaptureNewParentIdentity() throws {
        let (root, task, read, projects) = try fixture()
        for field in ["user_id", "project_id", "task_generation"] {
            var stale = task; stale[field] = .string(UUID().uuidString.lowercased())
            XCTAssertThrowsError(try ChildTaskListCompletionIntent(task: stale, root: root, projects: projects, scope: ChildTaskFieldClientScope(read.context)), field)
        }
    }

    @MainActor func testSnapshotRefreshRetriesOnlyTheReadOnce() async throws {
        let (_, _, read, _) = try fixture(); let scope = ChildTaskFieldClientScope(read.context)
        var reads = 0
        let value = try await ChildTaskListRead.fresh(scope: scope, current: { scope }, operation: {
            reads += 1; if reads == 1 { throw CancellationError() }; return read
        })
        XCTAssertEqual(reads, 2); XCTAssertEqual(value.orderedNodes.map(\.key), read.orderedNodes.map(\.key))
        XCTAssertEqual(value.orderedNodes.first?.fields, read.orderedNodes.first?.fields)
    }
    @MainActor func testChangedScopeDoesNotRetryCancelledRead() async throws {
        let (_, _, read, _) = try fixture(); let scope = ChildTaskFieldClientScope(read.context)
        var current: ChildTaskFieldClientScope? = scope, reads = 0
        do {
            _ = try await ChildTaskListRead.fresh(scope: scope, current: { current }, operation: { reads += 1; current = nil; throw CancellationError() })
            XCTFail("Old workspace must not retry")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(reads, 1)
    }
    @MainActor func testRepeatedReadCancellationIsBounded() async throws {
        let (_, _, read, _) = try fixture(); let scope = ChildTaskFieldClientScope(read.context)
        var reads = 0
        do {
            _ = try await ChildTaskListRead.fresh(scope: scope, current: { scope }, operation: { reads += 1; throw CancellationError() })
            XCTFail("Must stop after one retry")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(reads, 2)
    }
    @MainActor func testNetworkErrorsNeverBecomeAutomaticReadRetries() async throws {
        let (_, _, read, _) = try fixture(); let scope = ChildTaskFieldClientScope(read.context)
        var reads = 0
        do {
            _ = try await ChildTaskListRead.fresh(scope: scope, current: { scope }, operation: { reads += 1; throw URLError(.notConnectedToInternet) })
            XCTFail("Network failure must remain explicit")
        } catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
        XCTAssertEqual(reads, 1)
    }
    @MainActor func testActualTaskCancellationNeverStartsARead() async throws {
        let (_, _, read, _) = try fixture(); let scope = ChildTaskFieldClientScope(read.context)
        var reads = 0
        let job = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ChildTaskListRead.fresh(scope: scope, current: { scope }, operation: { reads += 1; return read })
        }
        do { _ = try await job.value; XCTFail("Must honor cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(reads, 0)
    }

}

extension ChildTaskListCompletionTests {
    func testBulkIntentUsesObservedChildAndDoesNotIncludeWholeTree() throws {
        let (root, task, read, projects) = try fixture(), scope = ChildTaskFieldClientScope(read.context)
        let intent = try ChildTaskListBatchIntent(tasks: [task], roots: [root], projects: projects, scope: scope, completed: true)
        let command = try intent.command(reads: [root.id: read])
        XCTAssertEqual(command.items.count, 1); XCTAssertEqual(command.items[0].body["node_key"], read.orderedNodes[0].fields["id"])
        XCTAssertNil(command.body["subtasks"]); XCTAssertNil(command.items[0].body["subtasks"])
    }
    func testBulkIntentRefusesMixedRootSelectionDuplicatesAndMissingRoots() throws {
        let (root, task, read, projects) = try fixture(), scope = ChildTaskFieldClientScope(read.context)
        for tasks in [[root,task],[task,task],[]] { XCTAssertThrowsError(try ChildTaskListBatchIntent(tasks: tasks, roots: [root], projects: projects, scope: scope, completed: true)) }
        XCTAssertThrowsError(try ChildTaskListBatchIntent(tasks: [task], roots: [], projects: projects, scope: scope, completed: true))
        XCTAssertThrowsError(try ChildTaskListBatchIntent(tasks: [task], roots: [root], projects: projects, scope: scope, completed: false))
    }
    func testBulkIntentNeverChangesTargetsAfterCohortOrScopeChange() throws {
        let (root, task, read, projects) = try fixture()
        let intent = try ChildTaskListBatchIntent(tasks: [task], roots: [root], projects: projects, scope: ChildTaskFieldClientScope(read.context), completed: true)
        XCTAssertThrowsError(try intent.command(reads: [:])); XCTAssertThrowsError(try intent.command(reads: [root.id: altered(read, access: UUID())]))
        var changed = root, child = root["subtasks"].list[0].object; child["completed"] = .bool(true); child["completed_at"] = .string("2026-10-31T12:00:00Z"); changed["subtasks"] = .array([.object(child)])
        XCTAssertThrowsError(try intent.command(reads: [root.id: altered(read, root: changed)]))
    }
}

extension ChildTaskListCompletionTests {
    private func twoChildren() throws -> (Record,[Record],ChildTaskRecordRead,[Record]) {
        let (original,_,read,projects) = try fixture();var root = original, first = root["subtasks"].list[0].object, second = first
        first["title"] = .string("First child");second["id"] = .string("second");second["title"] = .string("Second child");root["subtasks"] = .array([.object(first),.object(second)])
        let c = read.context, context = try ChildTaskRecordContext(account:c.account,origin:c.origin,workspace:c.workspace,session:c.session,access:c.access,snapshot:c.snapshot,root:root)
        let rows = [first,second].enumerated().map { index, fields -> JSON in .object(["node_key":fields["id"]!,"incarnation":.string(index == 0 ? read.orderedNodes[0].incarnation : "77110000-0000-4000-8000-000000000001"),"revision":.number(1),"parent_key":.null,"sibling_order":.number(Double(index)),"identity_path":.array([fields["id"]!]),"fields":.object(fields),"children_kind":.string("absent")]) }
        let raw: [String:JSON] = ["protocol":.number(1),"account":.string(c.account),"task_id":.string(root.id),"task_generation":root["task_generation"],"project_id":root["project_id"],"projection_revision":.number(1),"root_kind":.string("array"),"records":.array(rows)]
        let fresh = try ChildTaskRecordRead(data:TaskfoldJSONEncoder().encode(raw),context:context)
        let tasks = try TaskHierarchyIndex(roots:[root],projects:projects,workspace:WorkspaceBinding(account:c.account,generation:c.workspace)).items.filter(\.isSubtask).map(\.record)
        return (root,tasks,fresh,projects)
    }
    func testBulkIntentBuildsBothMembersAndRejectsAChangedLaterCohortAsAWhole() throws {
        let (root,tasks,read,projects) = try twoChildren(), scope = ChildTaskFieldClientScope(read.context)
        let intent = try ChildTaskListBatchIntent(tasks:tasks,roots:[root],projects:projects,scope:scope,completed:true)
        let group = try intent.command(reads:[root.id:read]);XCTAssertEqual(group.items.count,2);XCTAssertEqual(group.items.map { $0.body["node_key"]!.text },read.orderedNodes.map(\.key))
        var changed = root, rows = root["subtasks"].list, last = rows[1].object;last["completed"] = .bool(true);last["completed_at"] = .string("2026-10-31T12:00:00Z");rows[1] = .object(last);changed["subtasks"] = .array(rows)
        let c = read.context, context = try ChildTaskRecordContext(account:c.account,origin:c.origin,workspace:c.workspace,session:c.session,access:c.access,snapshot:c.snapshot,root:changed)
        let raw: [String:JSON] = ["protocol":.number(1),"account":.string(c.account),"task_id":.string(root.id),"task_generation":root["task_generation"],"project_id":root["project_id"],"projection_revision":.number(1),"root_kind":.string("array"),"records":.array(read.orderedNodes.enumerated().map { index,node in .object(["node_key":.string(node.key),"incarnation":.string(node.incarnation),"revision":.number(1),"parent_key":.null,"sibling_order":.number(Double(index)),"identity_path":.array([.string(node.key)]),"fields":rows[index],"children_kind":.string("absent")]) })]
        let altered = try ChildTaskRecordRead(data:TaskfoldJSONEncoder().encode(raw),context:context)
        XCTAssertThrowsError(try intent.command(reads:[root.id:altered]))
    }
}
