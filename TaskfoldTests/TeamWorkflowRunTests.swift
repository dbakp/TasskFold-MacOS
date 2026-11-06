import XCTest
@testable import TaskfoldCore

final class TeamWorkflowRunTests: XCTestCase {
    let account = "ec260000-0000-4000-8000-000000000001"
    let teamID = "ec260000-0000-4000-8000-000000000002"
    let projectID = "ec260000-0000-4000-8000-000000000003"
    let templateID = "ec260000-0000-4000-8000-000000000004"
    let origin = "https://workflow.example"
    let generation = UUID()
    let session = UUID()
    let stamp = Date(timeIntervalSince1970: 1792920000)
    var workspace: WorkspaceBinding { .init(account: account, generation: generation) }
    func team(role: String = "member", archived: Bool = false, revision: Double = 1) throws -> TeamOrganization {
        try .init(["id": .string(teamID), "name": .string("Studio"), "role": .string(role), "state": .string(archived ? "archived" : "active"), "revision": .number(revision)])
    }
    func access(role: String = "editor", archived: Bool = false, inherited: Bool = false, paused: Bool = false, revision: Double = 1, teamRevision: Double = 1, legacy: Bool = false) throws -> TeamProjectAccess {
        var row: [String: JSON] = ["protocol": .number(1), "account": .string(account), "team_id": .string(teamID), "team_state": .string("active"), "setup_paused": .bool(paused), "team_revision": .number(teamRevision), "id": .string(projectID), "name": .string("Review"), "revision": .number(revision), "role": .string(role), "visibility": .string("private"), "folder_id": .null, "can_edit_tasks": .bool(false), "can_manage_access": .bool(role == "manager")]
        if !legacy {
            row.merge(["project_state_protocol": .number(1), "is_archived": .bool(archived), "ancestor_archived": .bool(inherited), "project_hierarchy_protocol": .number(1), "parent_id": .null, "parent_unavailable": .bool(false)]) { _, b in b }
        }
        return try .init(detail: row, account: account, origin: origin, team: teamID, project: projectID)
    }
    func source(kind: WorkflowTemplate.Kind = .project) throws -> TeamWorkflowRunPlan.Source {
        let definition = try WorkflowTemplate.capture(kind: kind, id: kind == .project ? "root" : kind == .section ? "section" : "source", snapshot: ProjectWorkflowsTests().fixture())
        return .personal(Record(["id": .string(templateID), "user_id": .string(account), "name": .string("Design"), "document": definition.document]))
    }
    func plan(source: TeamWorkflowRunPlan.Source? = nil, destination: TeamWorkflowRunPlan.Destination = .newProject(.team), team: TeamOrganization? = nil, run: UUID = UUID(), start: Date? = nil) throws -> TeamWorkflowRunPlan {
        try .init(source: source ?? self.source(), account: account, origin: origin, team: team ?? self.team(), destination: destination, name: "Launch", start: start, workspace: workspace, session: session, run: run, createdAt: stamp)
    }
    func testProjectHierarchySectionsOrderAndCleanHistory() throws {
        let p = try plan(start: Dates.parse("2026-11-01"))
        XCTAssertEqual(p.projects.count, 2); XCTAssertEqual(p.sections.count, 1); XCTAssertEqual(p.tasks.count, 2)
        let root = try XCTUnwrap(p.projects.first); XCTAssertEqual(root.name, "Launch")
        XCTAssertEqual(p.projects[1]["parent_id"], .string(root.id))
        XCTAssertTrue(p.projects.allSatisfy { $0["team_id"] == .string(teamID) && $0["visibility"] == .string("team") })
        let task = try XCTUnwrap(p.tasks.first { $0.title == "Design review" })
        XCTAssertEqual(task["section_id"], .string(p.sections[0].id)); XCTAssertEqual(p.sections[0]["project_id"], .string(root.id))
        XCTAssertEqual(task.string("due_date"), "2026-11-01"); XCTAssertEqual(task.string("deadline_date"), "2026-11-04")
        XCTAssertFalse(task.completed); XCTAssertTrue(task["comments"].list.isEmpty); XCTAssertTrue(task["attachments"].list.isEmpty); XCTAssertTrue(task.string("assigned_to").isEmpty)
        XCTAssertEqual(task["labels"], .array([.string("Studio")]))
        XCTAssertEqual(Set(p.orders.flatMap(\.tasks)), Set(p.tasks.map(\.id)))
        XCTAssertFalse(String(reflecting: p).contains("Design review"))
    }
    func testStableIdentityAndContentOnRetryFreshIdentityForNextRun() throws {
        let source = try source(), run = UUID()
        let first = try plan(source: source, run: run), retry = try plan(source: source, run: run), next = try plan(source: source)
        XCTAssertEqual(first.projects, retry.projects); XCTAssertEqual(first.sections, retry.sections); XCTAssertEqual(first.tasks, retry.tasks); XCTAssertEqual(first.orders, retry.orders)
        XCTAssertTrue(Set(first.tasks.map(\.id)).isDisjoint(with: Set(next.tasks.map(\.id))))
        XCTAssertTrue(Set(first.tasks.map { $0.string("task_generation") }).isDisjoint(with: Set(next.tasks.map { $0.string("task_generation") })))
    }
    func testTaskAndSectionUseExistingProjectWithoutCopyingSourceProject() throws {
        for kind in [WorkflowTemplate.Kind.section, .task] {
            let p = try plan(source: source(kind: kind), destination: .project(access()))
            XCTAssertTrue(p.projects.isEmpty); XCTAssertTrue(p.tasks.allSatisfy { $0["project_id"] == .string(projectID) })
            XCTAssertEqual(p.sections.count, kind == .section ? 1 : 0)
            XCTAssertEqual(Set(p.orders.flatMap(\.tasks)), Set(p.tasks.map(\.id)))
            XCTAssertTrue(p.tasks.allSatisfy { $0["due_date"] == .null && $0["deadline_date"] == .null })
        }
    }
    func testDestinationRefusesWrongKindViewerArchivePausedAndOldService() throws {
        XCTAssertThrowsError(try plan(destination: .project(access())))
        for kind in [WorkflowTemplate.Kind.task, .section] {
            let s = try source(kind: kind)
            XCTAssertThrowsError(try plan(source: s))
            for a in [try access(role: "viewer"), try access(archived: true), try access(inherited: true), try access(paused: true), try access(teamRevision: 2), try access(legacy: true)] {
                XCTAssertThrowsError(try plan(source: s, destination: .project(a)))
            }
        }
        XCTAssertThrowsError(try plan(team: team(archived: true)))
        XCTAssertThrowsError(try plan(team: team(role: "guest")))
    }
    func testReviewRejectsChangedSourceDestinationScopeOrSession() throws {
        let p = try plan(source: source(kind: .task), destination: .project(access()))
        XCTAssertNoThrow(try p.verify(source: p.source, team: p.team, destination: p.destination, workspace: workspace, session: session))
        XCTAssertThrowsError(try p.verify(source: source(kind: .section), team: p.team, destination: p.destination, workspace: workspace, session: session))
        XCTAssertThrowsError(try p.verify(source: p.source, team: team(revision: 2), destination: p.destination, workspace: workspace, session: session))
        XCTAssertThrowsError(try p.verify(source: p.source, team: p.team, destination: .project(access(revision: 2)), workspace: workspace, session: session))
        XCTAssertThrowsError(try p.verify(source: p.source, team: p.team, destination: p.destination, workspace: .init(account: account, generation: UUID()), session: session))
        XCTAssertThrowsError(try p.verify(source: p.source, team: p.team, destination: p.destination, workspace: workspace, session: UUID()))
    }
    func testForeignPersonalOwnerAndUnsupportedDocumentCannotPrepare() throws {
        guard case .personal(var row) = try source() else { return XCTFail() }
        row["user_id"] = .string(teamID); XCTAssertThrowsError(try plan(source: .personal(row)))
        row["user_id"] = .string(account); row["team_id"] = .string(teamID); XCTAssertThrowsError(try plan(source: .personal(row)))
        row.fields.removeValue(forKey: "team_id"); row["document"] = .object(["version": .number(2)])
        XCTAssertThrowsError(try plan(source: .personal(row)))
    }
    func testInlineLabelsKeepCaseAndChildContextWithStableChecklistTokens() throws {
        guard case .personal(var row) = try source(kind: .task) else { return XCTFail() }
        var doc = row["document"].object, tasks = doc["tasks"]!.list
        var task = tasks[0].object, children = task["subtasks"]!.list
        task["labels"] = .array([.object(["name": .string("Studio")]), .object(["name": .string("studio")])])
        var child = children[0].object; child["labels"] = .array([.object(["name": .string("Child only")])]); children[0] = .object(child)
        task["subtasks"] = .array(children); tasks[0] = .object(task); doc["tasks"] = .array(tasks); row["document"] = .object(doc)
        let run = UUID(), a = try plan(source: .personal(row), destination: .project(access()), run: run)
        let b = try plan(source: .personal(row), destination: .project(access()), run: run)
        XCTAssertEqual(a.tasks, b.tasks)
        XCTAssertEqual(a.tasks[0]["labels"], .array([.string("Studio"), .string("studio")]))
        let savedChild = Record(a.tasks[0]["subtasks"].list[0].object)
        XCTAssertEqual(savedChild["labels"], .array([.string("Child only")]))
        XCTAssertFalse(savedChild.completed)
        XCTAssertEqual(TeamChecklist.token(savedChild[TeamChecklist.key])?.version, 0)
        XCTAssertNotEqual(savedChild.id, child["id"]?.text)
        XCTAssertNoThrow(try TeamChecklist.validate(a.tasks[0]["subtasks"]))
        XCTAssertNotNil(a.tasks[0].fields["created_at"])
        for field in ["user_id", "project_id", "task_generation", "created_at", "is_recurring"] { XCTAssertNil(savedChild.fields[field], field) }
        task["labels"] = .array([.object(["name": .string(String(repeating: "x", count: 1025))])])
        doc["tasks"] = .array([.object(task)]); row["document"] = .object(doc)
        XCTAssertThrowsError(try plan(source: .personal(row), destination: .project(access())))
    }
    func testSharedSourceChecksAccountOriginAndSupportedDefinition() throws {
        let library = TeamTemplateLibraryTests()
        var raw = library.detailRaw(document: try source().document)
        raw["account"] = .string(account)
        let sourceTeam = raw["team_id"]!.text
        let detail = try TeamTemplateDetail(raw, account: account, origin: origin, team: sourceTeam, template: raw["item"]!.object["id"]!.text)
        let p = try plan(source: .shared(detail))
        XCTAssertEqual(p.tasks.count, 2)
        XCTAssertNotEqual(detail.scope.team, p.team.id)
        XCTAssertThrowsError(try TeamWorkflowRunPlan(source: .shared(library.detail()), account: account, origin: origin, team: team(), destination: .newProject(.team), name: "Launch", workspace: workspace, session: session))
        var item = raw["item"]!.object
        item["document"] = .object(["version": .number(2), "future": .string("keep")]); raw["item"] = .object(item)
        let future = try TeamTemplateDetail(raw, account: account, origin: origin, team: sourceTeam, template: item["id"]!.text)
        XCTAssertThrowsError(try plan(source: .shared(future)))
    }
    func testSameSectionTaskOrderAndPrivateProjectAudienceArePreserved() throws {
        guard case .personal(var row) = try source() else { return XCTFail() }
        var document = row["document"].object, tasks = document["tasks"]!.list
        let index = try XCTUnwrap(tasks.firstIndex { $0.object["title"] == .string("Design review") })
        var extra = tasks[index].object
        extra["id"] = .string("extra"); extra["title"] = .string("Second in review"); extra["subtasks"] = .array([])
        tasks.insert(.object(extra), at: index + 1); document["tasks"] = .array(tasks); row["document"] = .object(document)
        let original = row
        let p = try plan(source: .personal(row), destination: .newProject(.private))
        XCTAssertTrue(p.projects.allSatisfy { $0["visibility"] == .string("private") })
        let section = try XCTUnwrap(p.sections.first)
        let order = try XCTUnwrap(p.orders.first { $0.section == section.id })
        let titles = order.tasks.compactMap { id in p.tasks.first { $0.id == id }?.title }
        XCTAssertEqual(titles, ["Design review", "Second in review"])
        XCTAssertEqual(row, original)
    }
    func testSharedBoundsRejectOversizedTaskChecklistAndNonfiniteDates() throws {
        guard case .personal(var row) = try source(kind: .task) else { return XCTFail() }
        var doc = row["document"].object, task = doc["tasks"]!.list[0].object
        task["description"] = .string(String(repeating: "x", count: 128000))
        doc["tasks"] = .array([.object(task)]); row["document"] = .object(doc)
        XCTAssertThrowsError(try plan(source: .personal(row), destination: .project(access())))
        task["description"] = .string("")
        task["subtasks"] = .array((0...1000).map { .object(["id": .string("child-\($0)"), "title": .string("Step"), "labels": .array([]), "subtasks": .array([])]) })
        doc["tasks"] = .array([.object(task)]); row["document"] = .object(doc)
        XCTAssertThrowsError(try plan(source: .personal(row), destination: .project(access())))
        XCTAssertThrowsError(try plan(start: Date(timeIntervalSince1970: .infinity)))
        XCTAssertThrowsError(try plan(run: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!))
    }
    func testFrozenOrderEnvelopeAndParentReview() throws {
        let p = try plan(destination: .newProject(.private, parent: access(role: "manager")))
        let bases = Dictionary(uniqueKeysWithValues: p.orders.map { ("group:" + $0.project + ":" + ($0.section ?? "none"), [String]()) })
        let body = try p.requestBody(baseOrders: bases)
        XCTAssertEqual(body["destination"]?.object["parent_id"], .string(projectID))
        XCTAssertEqual(body["destination"]?.object["parent_revision"], .number(1))
        XCTAssertEqual(body["request_id"], .string(p.run.uuidString.lowercased()))
        XCTAssertEqual(body["tasks"]?.list, p.tasks.map { .object($0.fields) })
        XCTAssertEqual(try p.requestBody(baseOrders: bases), body)
        XCTAssertThrowsError(try p.requestBody(baseOrders: [:]))
        XCTAssertThrowsError(try plan(destination: .newProject(.team, parent: access(role: "editor"))))
        XCTAssertThrowsError(try plan(destination: .newProject(.team, parent: access(archived: true))))
        XCTAssertThrowsError(try plan(destination: .newProject(.team, folder: "not-a-folder")))
    }
    func testExportGeneratedSQLFixture() throws {
        guard let output = ProcessInfo.processInfo.environment["TASKFOLD_RUN_SQL_FIXTURE"] else { return }
        guard output.hasPrefix("/tmp/taskfold-workflow-run-") && output.hasSuffix(".json") else { return XCTFail("Use an owned temporary fixture path") }
        let p = try plan(start: Dates.parse("2026-11-01"))
        let bases = Dictionary(uniqueKeysWithValues: p.orders.map { ("group:" + $0.project + ":" + ($0.section ?? "none"), [String]()) })
        let body = try p.requestBody(baseOrders: bases)
        try JSONEncoder().encode(JSON.object(body)).write(to: URL(fileURLWithPath: output), options: .atomic)
    }
    func testRepeatingChecklistIsRefusedWithoutChangingTemplate() throws {
        guard case .personal(var row) = try source(kind: .task) else { return XCTFail() }
        var doc = row["document"].object, task = doc["tasks"]!.list[0].object
        var child = task["subtasks"]!.list[0].object
        child["is_recurring"] = .bool(true); child["recurrence_pattern"] = .object(["type": .string("daily"), "interval": .number(1)])
        task["subtasks"] = .array([.object(child)]); doc["tasks"] = .array([.object(task)]); row["document"] = .object(doc)
        XCTAssertNoThrow(try WorkflowTemplate(document: row["document"]))
        XCTAssertThrowsError(try plan(source: .personal(row), destination: .project(access())))
        XCTAssertEqual(row["document"], .object(doc))
    }
}

// Heading-aware shared reuse must preserve the reviewed format through recovery.
extension TeamWorkflowRunTests {
    func headingWorkflowSource() -> TeamWorkflowRunPlan.Source {
        let child: JSON = .object(["id": .string("phase"), "title": .string("Research"), "is_heading": .bool(true), "labels": .array([]), "subtasks": .array([.object(["id": .string("work"), "title": .string("* Literal task"), "labels": .array([]), "subtasks": .array([])])])])
        let document: JSON = .object(["version": .number(2), "capabilities": .array([.string("task_headings")]), "kind": .string("task"), "projects": .array([]), "sections": .array([]), "tasks": .array([.object(["id": .string("root"), "title": .string("Design phase"), "is_heading": .bool(true), "labels": .array([]), "subtasks": .array([child])])])])
        return .personal(Record(["id": .string(templateID), "user_id": .string(account), "name": .string("Design"), "document": document]))
    }
    func headingRun() throws -> TeamWorkflowRunPlan {
        try .init(source: headingWorkflowSource(), account: account, origin: origin, team: team(), destination: .project(access()), name: "Design", workspace: workspace, session: session, createdAt: stamp, supportsHeadings: true)
    }
    func testSharedHeadingRunRequiresOptInAndPreservesNestedTypes() throws {
        XCTAssertThrowsError(try plan(source: headingWorkflowSource(), destination: .project(access())))
        let p = try headingRun(), row = try XCTUnwrap(p.tasks.first)
        XCTAssertEqual(p.contentsSummary, "1 checklist item · 2 headings")
        XCTAssertEqual(TaskKind(row), .heading)
        let nested = Record(try XCTUnwrap(row["subtasks"].list.first).object)
        XCTAssertEqual(TaskKind(nested), .heading)
        let work = Record(try XCTUnwrap(nested["subtasks"].list.first).object)
        XCTAssertEqual(TaskKind(work), .task); XCTAssertEqual(work.title, "* Literal task")
        XCTAssertFalse(row.completed); XCTAssertFalse(nested.completed); XCTAssertFalse(work.completed)
        XCTAssertEqual(TeamChecklist.token(nested[TeamChecklist.key])?.version, 0)
        let bases = Dictionary(uniqueKeysWithValues: p.orders.map { ("group:" + $0.project + ":" + ($0.section ?? "none"), [String]()) })
        let c = try TeamWorkflowRunCommand(plan: p, baseOrders: bases)
        XCTAssertEqual(c.body["workflow_types_protocol"], .number(1))
        XCTAssertEqual(try JSONDecoder().decode(TeamWorkflowRunCommand.self, from: JSONEncoder().encode(c)), c)
        for marker in [JSON.null, .number(2), .bool(true)] {
            var body = c.body; body["workflow_types_protocol"] = marker
            XCTAssertThrowsError(try TeamWorkflowRunCommand(account: account, origin: origin, body: body))
        }
        var body = c.body; body.removeValue(forKey: "workflow_types_protocol")
        XCTAssertThrowsError(try TeamWorkflowRunCommand(account: account, origin: origin, body: body))
        for level in [0, 1] {
            var root = row.fields
            if level == 0 { root.removeValue(forKey: "is_heading") }
            else { var nodes = root["subtasks"]!.list; var node = nodes[0].object; node["is_heading"] = .bool(false); nodes[0] = .object(node); root["subtasks"] = .array(nodes) }
            body = c.body; body["tasks"] = .array([.object(root)])
            XCTAssertThrowsError(try TeamWorkflowRunCommand(account: account, origin: origin, body: body))
        }
        var receipt: [String:JSON] = ["run_protocol": .number(1), "workflow_types_protocol": .number(1), "account": .string(account), "team_id": .string(teamID), "request_id": .string(c.id), "projects": .array([]), "sections": .array([]), "tasks": .array([.object(["id": row["id"], "generation": row["task_generation"], "project_id": row["project_id"]])]), "replayed": .bool(false)]
        XCTAssertNoThrow(try c.confirmed(receipt)); receipt.removeValue(forKey: "workflow_types_protocol")
        XCTAssertThrowsError(try c.confirmed(receipt))
    }
    func testSharedHeadingPublicationRequiresTypedAckAndRetainsDocument() throws {
        let doc = headingWorkflowSource().document
        XCTAssertThrowsError(try TeamTemplateCommand(account: account, origin: origin, action: .publish, team: teamID, template: templateID, name: "Design", document: doc))
        for action in [TeamTemplateCommand.Action.publish, .replace] {
            let c = try TeamTemplateCommand(account: account, origin: origin, action: action, team: teamID, template: templateID, revision: action == .replace ? 1 : nil, name: "Design", document: doc, supportsHeadings: true)
            XCTAssertEqual(c.body["document"], doc); XCTAssertEqual(c.body["workflow_types_protocol"], .number(1))
            XCTAssertEqual(try JSONDecoder().decode(TeamTemplateCommand.self, from: JSONEncoder().encode(c)), c)
            var raw: [String:JSON] = ["library_protocol": .number(1), "workflow_types_protocol": .number(1), "account": .string(account), "team_id": .string(teamID), "request_id": .string(c.id), "operation": .string(action.rawValue), "template_id": .string(templateID), "revision": .number(action == .publish ? 1 : 2), "deleted": .bool(false), "replayed": .bool(true)]
            XCTAssertNoThrow(try c.confirmed(raw)); raw["workflow_types_protocol"] = .number(2)
            XCTAssertThrowsError(try c.confirmed(raw)); raw.removeValue(forKey: "workflow_types_protocol")
            XCTAssertThrowsError(try c.confirmed(raw))
            var body = c.body; body.removeValue(forKey: "workflow_types_protocol")
            XCTAssertThrowsError(try TeamTemplateCommand(account: account, origin: origin, action: action, body: body))
        }
    }
    func testSharedOrganizerReopenMustBeSavedBeforeTypeChange() throws {
        let row = Record(["id": .string("item"), "completed": .bool(false)])
        XCTAssertFalse(TeamTaskTypes.needsSavedReopen(row, originalTree: nil))
        XCTAssertFalse(TeamTaskTypes.needsSavedReopen(row, originalTree: .array([])))
        XCTAssertFalse(TeamTaskTypes.needsSavedReopen(row, originalTree: .array([.object(row.fields)])))
        var completed = row; completed["completed"] = .bool(true)
        XCTAssertTrue(TeamTaskTypes.needsSavedReopen(row, originalTree: .array([.object(completed.fields)])))
        completed["completed"] = .bool(false); completed["completed_at"] = .string("2026-10-26T10:00:00Z")
        XCTAssertTrue(TeamTaskTypes.needsSavedReopen(row, originalTree: .array([.object(completed.fields)])))
        XCTAssertTrue(TeamTaskTypes.needsSavedReopen(row, originalTree: .string("unknown")))
    }
}
