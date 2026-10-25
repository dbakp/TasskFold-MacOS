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
