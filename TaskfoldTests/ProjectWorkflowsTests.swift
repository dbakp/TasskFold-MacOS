import XCTest
@testable import TaskfoldCore

final class ProjectWorkflowsTests: XCTestCase {
    let owner = "11111111-1111-4111-8111-111111111111"
    func project(_ id: String, parent: String = "", archived: Bool = false) -> Record {
        Record(["id": .string(id), "user_id": .string(owner), "name": .string(id), "parent_id": parent.isEmpty ? .null : .string(parent), "is_archived": .bool(archived)])
    }
    func testParentArchiveHidesDescendantsAndRestoreKeepsExplicitChildArchive() {
        var rows = [project("root"),project("child",parent:"root"),project("kept",parent:"root",archived:true)]
        rows[0]["is_archived"] = .bool(true)
        XCTAssertEqual(Set(ProjectOrganization.outline(rows, archived:true).map(\.id)),["root","child","kept"])
        rows[0]["is_archived"] = .bool(false)
        XCTAssertEqual(ProjectOrganization.outline(rows).map(\.id),["root","child"])
        XCTAssertTrue(ProjectOrganization.archived("kept",in:rows))
    }
    func testArchiveProjectionForUnsharedAncestorAndLocalDetach() {
        var row = project("child",parent:"not-shared");row["ancestor_archived"] = .bool(true)
        XCTAssertTrue(ProjectOrganization.archived(row.id,in:[row]))
        row["parent_id"] = .null
        XCTAssertFalse(ProjectOrganization.archived(row.id,in:[row]))
    }
    func testCyclesAndDescendantMoveAreRejectedWithoutHangingOutline() {
        var rows=[project("a"),project("b",parent:"a"),project("c",parent:"b")]
        var moved=rows[0];moved["parent_id"] = .string("c")
        XCTAssertThrowsError(try ProjectOrganization.validate(moved,previous:rows[0],account:owner,projects:rows))
        rows[0]=moved;XCTAssertEqual(ProjectOrganization.outline(rows,archived:true).count,3)
        XCTAssertTrue(ProjectOrganization.parentChoices(for:rows[0],account:owner,projects:rows).isEmpty)
    }
    func testMovingSubtreeAccountsForItsFullDepth() {
        var rows=(0..<19).map{project("p\($0)",parent:$0==0 ? "" : "p\($0-1)")}
        let root=project("sub"), child=project("leaf",parent:"sub");rows += [root,child]
        var moved=root;moved["parent_id"] = .string("p18")
        XCTAssertThrowsError(try ProjectOrganization.validate(moved,previous:root,account:owner,projects:rows))
        moved["parent_id"] = .string("p17")
        XCTAssertNoThrow(try ProjectOrganization.validate(moved,previous:root,account:owner,projects:rows))
    }
    func testForeignParentAndMemberOrganizationChangeAreRejected() {
        var foreign=project("foreign");foreign["user_id"] = .string("other")
        var row=project("mine",parent:"foreign")
        XCTAssertThrowsError(try ProjectOrganization.validate(row,previous:nil,account:owner,projects:[foreign]))
        row=foreign;row["is_archived"] = .bool(true)
        XCTAssertThrowsError(try ProjectOrganization.validate(row,previous:foreign,account:owner,projects:[foreign]))
        row=foreign;row["name"] = .string("Shared rename")
        XCTAssertNoThrow(try ProjectOrganization.validate(row,previous:foreign,account:owner,projects:[foreign]))
    }
    func testOutlinePreservesTreeAndStableSiblingOrdering() {
        var a=project("a"),b=project("b"),child=project("child",parent:"b")
        a["order_index"] = .number(2);b["order_index"] = .number(1);child["order_index"] = .number(0)
        let rows=ProjectOrganization.outline([child,a,b])
        XCTAssertEqual(rows.map(\.id),["b","child","a"]);XCTAssertEqual(rows.map(\.depth),[0,1,0])
    }
    func testBulkReviewStripsListMarkersButKeepsBlankLinesOutAndParsesDates() throws {
        let now=Dates.parse("2026-10-20")!
        let lines=try MultiLineCapture.preview("- Prepare brief p1\r\n\r\n2. Book room tomorrow\n• [x] Send notes",account:owner,now:now)
        XCTAssertEqual(lines.map{ $0.task.title },["Prepare brief","Book room","Send notes"])
        XCTAssertEqual(lines[0].task.priority,1);XCTAssertEqual(lines[1].task.string("due_date"),"2026-10-21")
        XCTAssertTrue(lines.allSatisfy{ !$0.task.completed });XCTAssertEqual(Set(lines.map{$0.task.id}).count,3)
    }
    func testBulkLiteralModeRetainsSchedulingWordsAndInputLimitFailsBeforeWriting() throws {
        let lines=try MultiLineCapture.preview("Plan tomorrow p1",account:owner,recognize:false)
        XCTAssertEqual(lines[0].task.title,"Plan tomorrow p1");XCTAssertNil(lines[0].task.due)
        XCTAssertThrowsError(try MultiLineCapture.preview(Array(repeating:"Task",count:201).joined(separator:"\n"),account:owner))
        XCTAssertTrue(try MultiLineCapture.preview("\n \n",account:owner).isEmpty)
    }
    func fixture() -> Snapshot {
        let p=project("root"),child=project("child",parent:"root")
        let section=Record(["id":.string("section"),"name":.string("Prepare"),"project_id":.string("root"),"order_index":.number(0)])
        let label=Record(["id":.string("label"),"name":.string("Studio"),"color":.string("#123456")])
        var task=Record.task(user:owner,project:"root");task["id"] = .string("source");task["title"] = .string("Design review");task["section_id"] = .string("section");task["due_date"] = .string("2026-10-20");task["deadline_date"] = .string("2026-10-23");task["labels"] = .array([.string("label")]);task["completed"] = .bool(true);task["comments"] = .array([.object(["text":.string("Private discussion")])]);task["attachments"] = .array([.object(["url":.string("https://example.invalid/private")])]);task["assigned_to"] = .string("member")
        var sub=Record.task(user:owner);sub["title"] = .string("Prepare outline");sub["completed"] = .bool(true);task["subtasks"] = .array([.object(sub.fields)])
        var second=Record.task(user:owner,project:"child");second["title"] = .string("Follow up");second["due_date"] = .string("2026-10-22")
        return Snapshot(tables:["projects":[p,child],"sections":[section],"tasks":[task,second],"labels":[label]])
    }
    func testProjectTemplatePreservesStructureAndOffsetsButNeverHistoryOrOwnership() throws {
        let source=fixture(),template=try WorkflowTemplate.capture(kind:.project,id:"root",snapshot:source)
        let run=UUID(),changes=try template.instantiate(account:"recipient",name:"October launch",start:Dates.parse("2026-11-01"),run:run)
        XCTAssertEqual(changes.filter{$0.table=="projects"}.count,2);XCTAssertEqual(changes.filter{$0.table=="sections"}.count,1)
        let tasks=changes.filter{$0.table=="tasks"}.map{Record($0.fields)}
        let first=try XCTUnwrap(tasks.first{$0.title=="Design review"})
        XCTAssertEqual(first.string("due_date"),"2026-11-01");XCTAssertEqual(first.string("deadline_date"),"2026-11-04")
        XCTAssertFalse(first.completed);XCTAssertTrue(first["comments"].list.isEmpty);XCTAssertTrue(first["attachments"].list.isEmpty);XCTAssertTrue(first.string("assigned_to").isEmpty)
        XCTAssertFalse(Record(first["subtasks"].list[0].object).completed)
        XCTAssertTrue(changes.allSatisfy{$0.fields["user_id"] == .string("recipient")})
        XCTAssertNotEqual(first.id,"source");XCTAssertFalse(first.string("task_generation").isEmpty)
        let retry=try template.instantiate(account:"recipient",name:"October launch",start:Dates.parse("2026-11-01"),run:run)
        XCTAssertEqual(changes.map(\.recordID),retry.map(\.recordID))
        let next=try template.instantiate(account:"recipient",name:"Next run")
        XCTAssertTrue(Set(changes.map(\.recordID)).isDisjoint(with:Set(next.map(\.recordID))))
        XCTAssertTrue(source.tables["tasks"]!.first!.completed, "Creating a reusable definition does not reset the original project")
    }
    func testTemplateUseWithoutDateClearsOldScheduleAndReusesExistingLabel() throws {
        let source=fixture(),template=try WorkflowTemplate.capture(kind:.task,id:"source",snapshot:source)
        let changes=try template.instantiate(account:owner,name:"",labels:source.tables["labels"]!)
        XCTAssertFalse(changes.contains{$0.table=="labels" || $0.table=="projects" || $0.table=="sections"})
        let task=try XCTUnwrap(changes.first{$0.table=="tasks"});XCTAssertEqual(task.fields["due_date"],.null);XCTAssertEqual(task.fields["deadline_date"],.null)
        XCTAssertEqual(task.fields["labels"],.array([.string("label")]))
    }
    func testSectionTemplateRequiresDestinationAndCreatesItsOwnSection() throws {
        let template=try WorkflowTemplate.capture(kind:.section,id:"section",snapshot:fixture())
        XCTAssertThrowsError(try template.instantiate(account:owner,name:""))
        let changes=try template.instantiate(account:owner,name:"",targetProject:"destination")
        XCTAssertEqual(changes.filter{$0.table=="sections"}.first?.fields["project_id"],.string("destination"))
        XCTAssertEqual(changes.filter{$0.table=="tasks"}.first?.fields["project_id"],.string("destination"))
    }
    func testUnknownTemplateVersionAndBrokenReferencesFailClosed() throws {
        let template=try WorkflowTemplate.capture(kind:.project,id:"root",snapshot:fixture())
        var fields=template.document.object;fields["version"] = .number(2)
        XCTAssertThrowsError(try WorkflowTemplate(document:.object(fields)))
        fields=template.document.object;fields["sections"] = .array([])
        XCTAssertThrowsError(try WorkflowTemplate(document:.object(fields)))
        fields=template.document.object;fields["projects"] = .array([])
        XCTAssertThrowsError(try WorkflowTemplate(document:.object(fields)))
    }
}

extension ProjectWorkflowsTests {
    func testPortableBackupRestoresArchivedHierarchyAndTemplateInParentFirstOrder() throws {
        var source = fixture()
        source.tables["projects"]![0]["is_archived"] = .bool(true)
        // Child deliberately precedes parent in the file.
        source.tables["projects"]!.reverse()
        let definition = try WorkflowTemplate.capture(kind: .project, id: "root", snapshot: source)
        let template = Record(["id": .string("template"), "user_id": .string(owner), "name": .string("Launch"), "document": definition.document])
        source.tables[WorkflowTemplate.table] = [template]
        let backup = try WorkspaceBackup.read(WorkspaceBackup.make(source, account: owner).data())
        let recipient = "22222222-2222-4222-8222-222222222222"
        let plan = try backup.plan(current: Snapshot(), account: recipient)
        let projects = plan.changes.filter { $0.table == "projects" }.map { Record($0.fields) }
        XCTAssertEqual(projects.count, 2)
        XCTAssertTrue(projects[0].string("parent_id").isEmpty)
        XCTAssertEqual(projects[1].string("parent_id"), projects[0].id)
        XCTAssertTrue(ProjectOrganization.archived(projects[1].id, in: projects))
        let restored = try XCTUnwrap(plan.changes.first { $0.table == WorkflowTemplate.table })
        XCTAssertNotEqual(restored.recordID, template.id)
        XCTAssertEqual(restored.fields["document"], definition.document)
        XCTAssertEqual(restored.fields["user_id"], .string(recipient))
        var saved = Snapshot()
        for change in plan.changes { saved.apply(change) }
        XCTAssertEqual(try backup.plan(current: saved, account: recipient).changes.count, 0)
    }
    func testBackupPreservesFutureTemplateButRefusesToRunIt() throws {
        let doc: JSON = .object(["version": .number(2), "future": .array([.string("preserve this")])])
        let source = Snapshot(tables: [WorkflowTemplate.table: [Record(["id": .string("future"), "user_id": .string(owner), "name": .string("Future"), "document": doc])]])
        let backup = try WorkspaceBackup.read(WorkspaceBackup.make(source, account: owner).data())
        let plan = try backup.plan(current: Snapshot(), account: "recipient")
        XCTAssertEqual(plan.changes.first?.fields["document"], doc)
        XCTAssertThrowsError(try WorkflowTemplate(document: doc))
    }
    func testBackupRejectsHierarchyCycleAndMissingParentBeforeAnyWrite() throws {
        let cyclic = Snapshot(tables: ["projects": [project("a", parent: "b"), project("b", parent: "a")]])
        XCTAssertThrowsError(try WorkspaceBackup.make(cyclic, account: owner).plan(current: Snapshot(), account: "recipient"))
        let orphan = Snapshot(tables: ["projects": [project("a", parent: "missing")]])
        XCTAssertThrowsError(try WorkspaceBackup.make(orphan, account: owner).plan(current: Snapshot(), account: "recipient"))
    }
}

extension ProjectWorkflowsTests {
    func testArchivedProjectRejectsAnAlreadyPublishedWidgetCompletion() throws {
        var source = fixture()
        source.tables["tasks"]![0]["completed"] = .bool(false)
        WidgetCompletion.prepare(&source)
        let task = source.tables["tasks"]![0]
        let request = try WidgetCompletionRequest(account: owner, taskID: task.id, token: XCTUnwrap(WidgetCompletion.tokens(source)[task.id.lowercased()]))
        guard case .complete = WidgetCompletion.plan(request, snapshot: source, account: owner) else { return XCTFail("The fresh active task should be completable") }
        source.tables["projects"]![0]["is_archived"] = .bool(true)
        guard case .stale = WidgetCompletion.plan(request, snapshot: source, account: owner) else { return XCTFail("An old widget must not complete archived work") }
        XCTAssertFalse(source.tables["tasks"]![0].completed)
    }
    func testRecurringTemplateRebasesBoundsAndDoesNotReplayHistory() throws {
        var source = fixture()
        source.tables["tasks"]![0]["is_recurring"] = .bool(true)
        source.tables["tasks"]![0]["recurrence_pattern"] = .object(["type": .string("weekly"), "interval": .number(2), "daysOfWeek": .array([.number(2)]), "startDate": .string("2026-10-20"), "endDate": .string("2026-11-03"), "count": .number(5)])
        source.tables["tasks"]![0]["recurrence_parent_id"] = .string("old-completion")
        let definition = try WorkflowTemplate.capture(kind: .task, id: "source", snapshot: source)
        let task = try XCTUnwrap(definition.instantiate(account: owner, name: "", start: Dates.parse("2026-12-01")).first { $0.table == "tasks" }).fields
        XCTAssertEqual(task["recurrence_pattern"]?.object["startDate"], .string("2026-12-01"))
        XCTAssertEqual(task["recurrence_pattern"]?.object["endDate"], .string("2026-12-15"))
        XCTAssertEqual(task["recurrence_pattern"]?.object["count"], .number(5))
        XCTAssertTrue(task["recurrence_parent_id"] == nil || task["recurrence_parent_id"] == .null)
    }
}

extension ProjectWorkflowsTests {
    func testTemplatePreservesSiblingAndManualTaskOrderWithRemappedReferences() throws {
        var source = fixture()
        source.tables["projects"]![0]["order_index"] = .number(3)
        source.tables["projects"]![1]["order_index"] = .number(7)
        var task = source.tables["tasks"]![0]; task["id"] = .string("second"); task["title"] = .string("Before the review")
        source.tables["tasks"]!.append(task)
        source.tables["view_orders"] = [Record(["id": .string("group:root:section"), "user_id": .string(owner), "ids": .array([.string("second"), .string("source")])])]
        let definition = try WorkflowTemplate.capture(kind: .project, id: "root", snapshot: source)
        XCTAssertEqual(definition.tasks.filter { $0.string("project_id") == "root" }.map(\.title), ["Before the review", "Design review"])
        let changes = try definition.instantiate(account: owner, name: "Ordered workflow")
        XCTAssertEqual(changes.filter { $0.table == "projects" }.map { $0.fields["order_index"] }, [.number(3), .number(7)])
        let tasks = changes.filter { $0.table == "tasks" && $0.fields["title"] == .string("Before the review") || $0.table == "tasks" && $0.fields["title"] == .string("Design review") }
        let order = try XCTUnwrap(changes.first { $0.table == "view_orders" && $0.fields["ids"]?.list.count == 2 })
        XCTAssertEqual(order.fields["ids"], .array(tasks.map { .string($0.recordID) }))
        XCTAssertFalse(order.recordID.contains("root")); XCTAssertFalse(order.recordID.contains("section"))
    }
}

extension ProjectWorkflowsTests {
    func testSharedChildBackupPromotesUnavailableParentAndRetainsInheritedArchive() throws {
        var child = project("shared-child", parent: "not-shared")
        child["user_id"] = .string("22222222-2222-4222-8222-222222222222")
        child["ancestor_archived"] = .bool(true)
        var task = Record.task(user: child.string("user_id"), project: child.id); task["title"] = .string("Shared work stays recoverable")
        let source = Snapshot(tables: ["projects": [child], "tasks": [task]])
        let plan = try WorkspaceBackup.make(source, account: owner).plan(current: Snapshot(), account: "recipient")
        let project = try XCTUnwrap(plan.changes.first { $0.table == "projects" })
        XCTAssertEqual(project.fields["parent_id"], .null)
        XCTAssertEqual(project.fields["is_archived"], .bool(true))
        XCTAssertEqual(project.fields["user_id"], .string("recipient"))
        XCTAssertEqual(plan.changes.first { $0.table == "tasks" }?.fields["project_id"], .string(project.recordID))
        XCTAssertTrue(plan.warnings.contains { $0.contains("unavailable parent") })
        XCTAssertEqual(source.tables["projects"]?.first?["ancestor_archived"], .bool(true))
    }
}

extension ProjectWorkflowsTests {
    func testWindowsLineEndingsKeepTheActualSourceLineNumbers() throws {
        let lines = try MultiLineCapture.preview("First task\r\nSecond task\r\n\r\nFourth line", account: owner)
        XCTAssertEqual(lines.map(\.number), [1, 2, 4])
    }
    func testLegacyTemplateReferencesCannotAliasARootWithASubtask() throws {
        var source = fixture()
        source.tables["tasks"]![0]["id"] = .string("legacy")
        var another = source.tables["tasks"]![0]
        another["id"] = .string("legacy:0"); another["subtasks"] = .array([])
        source.tables["tasks"]!.append(another)
        let definition = try WorkflowTemplate.capture(kind: .project, id: "root", snapshot: source)
        let tasks = try definition.instantiate(account: owner, name: "Legacy workflow").filter { $0.table == "tasks" }.map { Record($0.fields) }
        let nested = tasks.flatMap { $0["subtasks"].list.map { Record($0.object).id } }
        XCTAssertFalse(nested.isEmpty)
        XCTAssertTrue(Set(tasks.map(\.id)).isDisjoint(with: Set(nested)))
    }
}
