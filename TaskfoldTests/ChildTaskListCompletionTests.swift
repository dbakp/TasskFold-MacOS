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


extension ChildTaskListCompletionTests {
    private func selection(_ tasks: [Record], roots: [Record], projects: [Record], read: ChildTaskRecordRead, completed: Bool = true) throws -> TaskListCompletionSelectionIntent {
        try .init(tasks: tasks, roots: roots, projects: projects, scope: ChildTaskFieldClientScope(read.context), completed: completed)
    }
    private func prepared(_ intent: TaskListCompletionSelectionIntent, roots: [Record], projects: [Record], read: ChildTaskRecordRead) throws -> TaskListCompletionSelectionIntent.Prepared {
        try intent.prepare(roots: roots, projects: projects, reads: [read.context.root.id: read], current: ChildTaskFieldClientScope(read.context))
    }
    func testMixedPreflightRetainsParentAndChildOrderWithoutLegacyMutations() throws {
        let (root, task, read, projects) = try fixture()
        for reversed in [false, true] {
            let intent = try selection(reversed ? [task, root] : [root, task], roots: [root], projects: projects, read: read)
            let result = try prepared(intent, roots: [root], projects: projects, read: read)
            XCTAssertEqual(intent.members.count, 2); XCTAssertEqual(intent.rootIDs, [root.id]); XCTAssertEqual(result.members.count, 2); XCTAssertEqual(result.observations.count, 2)
            if case .root(let value) = result.members[reversed ? 1 : 0] { XCTAssertEqual(value, root) } else { XCTFail("Root order changed") }
            if case .child(let command) = result.members[reversed ? 0 : 1] { XCTAssertEqual(command.body["node_key"], read.orderedNodes[0].fields["id"]); XCTAssertNil(command.body["subtasks"]) } else { XCTFail("Child order changed") }
        }
    }
    func testMixedPreflightSupportsIndependentRootAndSubtaskBranches() throws {
        let (root, task, read, projects) = try fixture(); var other = root
        other["id"] = .string("77110000-0000-4000-8000-000000000099"); other["subtasks"] = .array([])
        let intent = try selection([task, other], roots: [root, other], projects: projects, read: read)
        XCTAssertEqual(intent.rootIDs, [root.id, other.id])
        XCTAssertEqual(try prepared(intent, roots: [other, root], projects: projects, read: read).members.count, 2)
    }
    func testMixedPreflightRejectsChangedLaterRootWithoutReturningEarlierChild() throws {
        let (root, task, read, projects) = try fixture()
        let intent = try selection([task, root], roots: [root], projects: projects, read: read)
        var changed = root; changed["completed"] = .bool(true); changed["completed_at"] = .string("2026-10-31T12:00:00Z")
        XCTAssertThrowsError(try prepared(intent, roots: [changed], projects: projects, read: read))
    }
    func testMixedPreflightRejectsReplacedMovedOrReownedRoots() throws {
        let (root, task, read, projects) = try fixture()
        let intent = try selection([root, task], roots: [root], projects: projects, read: read)
        for key in ["id", "task_generation", "user_id", "project_id", "section_id"] {
            var changed = root; changed[key] = .string(UUID().uuidString.lowercased())
            XCTAssertThrowsError(try prepared(intent, roots: [changed], projects: projects, read: read), key)
        }
    }
    func testMixedPreflightRequiresCurrentScopeAndReadScope() throws {
        let (root, task, read, projects) = try fixture(); let c = read.context
        let intent = try selection([root, task], roots: [root], projects: projects, read: read)
        let scopes = [ChildTaskFieldClientScope(account: c.account, origin: c.origin, workspace: UUID(), session: c.session, access: c.access),
                      .init(account: c.account, origin: c.origin, workspace: c.workspace, session: UUID(), access: c.access),
                      .init(account: c.account, origin: c.origin, workspace: c.workspace, session: c.session, access: UUID()),
                      .init(account: UUID().uuidString.lowercased(), origin: c.origin, workspace: c.workspace, session: c.session, access: c.access),
                      .init(account: c.account, origin: "https://different.test", workspace: c.workspace, session: c.session, access: c.access)]
        for scope in scopes { XCTAssertThrowsError(try intent.prepare(roots: [root], projects: projects, reads: [root.id: read], current: scope)) }
        XCTAssertThrowsError(try prepared(intent, roots: [root], projects: projects, read: altered(read, session: UUID())))
    }
    func testMixedPreflightRejectsMissingDuplicateOrArchivedProject() throws {
        let (root, task, read, projects) = try fixture()
        let intent = try selection([root, task], roots: [root], projects: projects, read: read)
        if !projects.isEmpty {
            var archived = projects[0]; archived["is_archived"] = .bool(true)
            for values in [[], projects + projects, [archived]] {
                XCTAssertThrowsError(try prepared(intent, roots: [root], projects: values, read: read))
                XCTAssertThrowsError(try selection([root, task], roots: [root], projects: values, read: read))
            }
        } else { XCTFail("Project coverage requires the project fixture") }
    }
    func testMixedPreflightRejectsMissingOrDuplicateAccessibleRoot() throws {
        let (root, task, read, projects) = try fixture()
        for roots in [[], [root, root]] {
            XCTAssertThrowsError(try selection([root, task], roots: roots, projects: projects, read: read))
            let intent = try selection([root, task], roots: [root], projects: projects, read: read)
            XCTAssertThrowsError(try prepared(intent, roots: roots, projects: projects, read: read))
        }
    }
    func testMixedPreflightRejectsDuplicateMalformedAndOversizedSelection() throws {
        let (root, task, read, projects) = try fixture(); var malformed = task
        malformed["id"] = .string("subtask:broken")
        for tasks in [[], [root, root], [task, task], [root, malformed], Array(repeating: root, count: 33)] {
            XCTAssertThrowsError(try selection(tasks, roots: [root], projects: projects, read: read))
        }
        let roots = (0..<33).map { index -> Record in var row = root; row["id"] = .string(String(format: "77110000-0000-4000-8000-%012d", index)); return row }
        XCTAssertNoThrow(try selection(Array(roots.prefix(32)), roots: roots, projects: projects, read: read))
        XCTAssertThrowsError(try selection(roots, roots: roots, projects: projects, read: read))
    }
    func testMixedPreflightRejectsHeadingAndStaleSelectedRootCohort() throws {
        let (root, task, read, projects) = try fixture()
        var heading = root; heading["is_heading"] = .bool(true)
        XCTAssertThrowsError(try selection([heading, task], roots: [heading], projects: projects, read: read))
        var stale = root; stale["completion_version"] = .number(7)
        XCTAssertThrowsError(try selection([stale, task], roots: [root], projects: projects, read: read))
    }
    func testMixedPreflightAllowsUnrelatedOrdinaryRootEditsAndRetainsFreshContent() throws {
        let (root, task, read, projects) = try fixture()
        let intent = try selection([root, task], roots: [root], projects: projects, read: read)
        var changed = root; changed["title"] = .string("Another device edited this title"); changed["description"] = .string("Keep these notes"); changed["unknown_future_field"] = .string("Keep this too")
        let result = try prepared(intent, roots: [changed], projects: projects, read: altered(read, root: changed))
        guard case .root(let fresh) = result.members[0] else { return XCTFail("Missing root") }
        XCTAssertEqual(fresh, changed)
    }
    func testRecurringMixedPreflightDoesNotCopyAStaleSuccessorSource() throws {
        let (root, task, read, projects) = try fixture(); var recurring = root
        recurring["is_recurring"] = .bool(true); recurring["recurrence_pattern"] = .object(["type": .string("daily")]); recurring["due_date"] = .string("2026-10-31")
        let intent = try selection([recurring, task], roots: [recurring], projects: projects, read: read)
        for key in ["title", "description", "subtasks", "recurrence_pattern", "due_date", "unknown_future_field"] {
            var changed = recurring; changed[key] = .string("Changed successor source")
            XCTAssertThrowsError(try prepared(intent, roots: [changed], projects: projects, read: read), key)
        }
        XCTAssertEqual(try prepared(intent, roots: [recurring], projects: projects, read: altered(read, root: recurring)).members.count, 2)
    }
    func testMixedPreflightValidatesRootNoOpBeforeOmittingIt() throws {
        let (root, task, read, projects) = try fixture(); var done = root
        done["completed"] = .bool(true); done["completed_at"] = .string("2026-10-31T12:00:00Z")
        let intent = try selection([done, task], roots: [done], projects: projects, read: read)
        let result = try prepared(intent, roots: [done], projects: projects, read: altered(read, root: done))
        XCTAssertEqual(result.members.count, 1); XCTAssertEqual(result.observations.count, 2)
        guard case .root(let observed) = result.observations[0] else { return XCTFail("Missing selected no-op root") }
        XCTAssertEqual(observed, done)
        XCTAssertThrowsError(try prepared(intent, roots: [root], projects: projects, read: read))
    }
    func testMixedPreflightRefusesAllNoOpsWithoutCreatingAnAction() throws {
        let (root, task, read, projects) = try fixture()
        XCTAssertThrowsError(try selection([root, task], roots: [root], projects: projects, read: read, completed: false))
    }
    func testMixedPreflightRejectsInvalidCompletionTypesAndExhaustedRootVersions() throws {
        let (root, task, read, projects) = try fixture()
        for (key, value) in [("completed", JSON.string("false")), ("is_recurring", .number(1)), ("completion_version", .number(-1)), ("completion_version", .number(0.5)), ("completion_version", .number(9_007_199_254_740_991))] {
            var bad = root; bad[key] = value
            XCTAssertThrowsError(try selection([bad, task], roots: [bad], projects: projects, read: read), key)
        }
    }
    func testMixedPreflightRequiresOneConsistentRootForChildRead() throws {
        let (root, task, read, projects) = try fixture()
        let intent = try selection([root, task], roots: [root], projects: projects, read: read)
        var changed = root; changed["title"] = .string("Different root read")
        XCTAssertThrowsError(try prepared(intent, roots: [changed], projects: projects, read: read))
        XCTAssertThrowsError(try intent.prepare(roots: [root], projects: projects, reads: [:], current: intent.scope))
    }
    func testChildOnlyBatchStillReadsAndValidatesSelectedNoOps() throws {
        let (root, task, read, projects) = try fixture()
        var doneRoot = root, fields = root["subtasks"].list[0].object
        fields["completed"] = .bool(true); fields["completed_at"] = .string("2026-10-31T12:00:00Z"); doneRoot["subtasks"] = .array([.object(fields)])
        let c = read.context
        let second = try ChildTaskRecordContext(account: c.account, origin: c.origin, workspace: c.workspace, session: c.session, access: c.access, snapshot: c.snapshot, root: {
            var value = doneRoot; value["id"] = .string("77110000-0000-4000-8000-000000000099"); return value
        }())
        let doneRead = try makeRead(second, fields: fields, incarnation: read.orderedNodes[0].incarnation)
        let doneTask = try XCTUnwrap(TaskHierarchyIndex(roots: [second.root], projects: projects, workspace: .init(account: c.account, generation: c.workspace)).items.last?.record)
        let intent = try ChildTaskListBatchIntent(tasks: [task, doneTask], roots: [root, second.root], projects: projects, scope: .init(c), completed: true)
        XCTAssertEqual(intent.members.count, 2)
        let mixed = try selection([task, doneTask], roots: [root, second.root], projects: projects, read: read)
        let checked = try mixed.prepare(roots: [root, second.root], projects: projects, reads: [root.id: read, second.root.id: doneRead], current: mixed.scope)
        XCTAssertEqual(checked.members.count, 1); XCTAssertEqual(checked.observations.count, 2)
        guard case .child(let observed, let key) = checked.observations[1] else { return XCTFail("Missing selected no-op child") }
        XCTAssertEqual(observed.context.root, second.root); XCTAssertEqual(key, doneRead.orderedNodes[0].key)
        let command = try intent.command(reads: [root.id: read, second.root.id: doneRead])
        XCTAssertEqual(command.items.count, 1)
        XCTAssertThrowsError(try intent.command(reads: [root.id: read]))
        var reopened = second.root; reopened["subtasks"] = root["subtasks"]
        let reopenedRead = try altered(doneRead, root: reopened)
        XCTAssertThrowsError(try intent.command(reads: [root.id: read, second.root.id: reopenedRead]))
    }
}


extension ChildTaskListCompletionTests {
    func testMixedPreflightCanReopenCompletedRootAndChildTogether() throws {
        let (root, _, read, projects) = try fixture(); var done = root, fields = root["subtasks"].list[0].object
        fields["completed"] = .bool(true); fields["completed_at"] = .string("2026-10-31T12:00:00Z")
        done["subtasks"] = .array([.object(fields)]); done["completed"] = .bool(true); done["completed_at"] = fields["completed_at"]!
        let fresh = try altered(read, root: done)
        let task = try XCTUnwrap(TaskHierarchyIndex(roots: [done], projects: projects, workspace: .init(account: read.context.account, generation: read.context.workspace)).items.last?.record)
        let intent = try selection([done, task], roots: [done], projects: projects, read: fresh, completed: false)
        let result = try prepared(intent, roots: [done], projects: projects, read: fresh)
        XCTAssertFalse(result.completed); XCTAssertEqual(result.members.count, 2)
        guard case .child(let command) = result.members[1] else { return XCTFail("Missing child reopen") }
        XCTAssertEqual(command.body["action"], .string("reopen"))
    }
    func testRootOnlyPreflightDoesNotRequireAnIndependentChildRead() throws {
        let (root, _, read, projects) = try fixture()
        let intent = try selection([root], roots: [root], projects: projects, read: read)
        let result = try intent.prepare(roots: [root], projects: projects, reads: [:], current: intent.scope)
        XCTAssertEqual(result.members.count, 1); XCTAssertTrue(intent.childMembers.isEmpty)
    }
    func testMixedPreflightRejectsInconsistentRootCompletionTimestamp() throws {
        let (root, task, read, projects) = try fixture()
        for (completed, timestamp) in [(true, JSON.null), (true, .string("not a date")), (false, .string("2026-10-31T12:00:00Z"))] {
            var value = root; value["completed"] = .bool(completed); value["completed_at"] = timestamp
            XCTAssertThrowsError(try selection([value, task], roots: [value], projects: projects, read: read))
        }
    }
    func testMixedPreflightRejectsACompletionCycleEvenWhenStatusReturnsToBaseline() throws {
        let (root, task, read, projects) = try fixture()
        let intent = try selection([root, task], roots: [root], projects: projects, read: read)
        var cycled = root; cycled["completion_version"] = .number(Double(root["completion_version"].integer + 2))
        XCTAssertThrowsError(try prepared(intent, roots: [cycled], projects: projects, read: altered(read, root: cycled)))
    }
}
