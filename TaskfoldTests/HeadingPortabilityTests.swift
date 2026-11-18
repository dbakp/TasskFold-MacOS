import XCTest
@testable import TaskfoldCore

final class HeadingPortabilityTests: XCTestCase {
    let owner = "f2810000-0000-4000-8000-000000000001"
    let other = "f2810000-0000-4000-8000-000000000002"
    func row(_ title: String, heading: Bool = false) -> Record {
        var value = Record.task(user: owner); value["title"] = .string(title); value["description"] = .string("Full notes for " + title)
        value["due_date"] = .string("2026-11-01"); if heading { value["is_heading"] = .bool(true) }; return value
    }
    func tree() -> Record {
        var root = row("Project reference", heading: true), child = row("Review notes", heading: true)
        var done = row("Finished work"); done["completed"] = .bool(true)
        child["subtasks"] = .array([.object(done.fields)])
        root["subtasks"] = .array([.object(child.fields), .object(row("Next action").fields)]); return root
    }
    func template(_ root: Record) throws -> WorkflowTemplate { try .capture(kind: .task, id: root.id, snapshot: Snapshot(tables: ["tasks": [root]])) }
    func testHeadingTemplateUsesExplicitCapabilityWhileOrdinaryFilesStayVersionOne() throws {
        let normal = try template(row("* Literal ordinary title")); XCTAssertEqual(normal.document.object["version"], .number(1)); XCTAssertFalse(normal.requiresHeadingSupport)
        let captured = try template(tree()); XCTAssertTrue(captured.requiresHeadingSupport)
        XCTAssertEqual(TemplateEditing.summary(captured.document), "0 projects · 0 sections · 2 tasks and subtasks · 2 headings")
        XCTAssertEqual(captured.document.object["capabilities"], .array([.string("task_headings")]))
        XCTAssertEqual(captured.tasks[0]["is_heading"], .bool(true)); XCTAssertEqual(captured.tasks[0]["subtasks"].list[0].object["is_heading"], .bool(true))
        let file = try WorkflowTemplateFile(name: "Reference workflow", document: captured.document)
        let bytes = try file.encoded(), decoded = try WorkflowTemplateFile(data: bytes)
        XCTAssertTrue(decoded.template.requiresHeadingSupport)
        let envelope = try JSONDecoder().decode(JSON.self, from: bytes).object; XCTAssertEqual(envelope["version"], .number(2))
        XCTAssertEqual(decoded.template.tasks[0].string("description"), captured.tasks[0].string("description"))
    }
    func testOldOrMismatchedTemplateEnvelopesCannotSmuggleHeadingSemantics() throws {
        let captured = try template(tree()), file = try WorkflowTemplateFile(name: "Headings", document: captured.document)
        var envelope = try JSONDecoder().decode(JSON.self, from: file.encoded()).object
        envelope["version"] = .number(1); XCTAssertThrowsError(try WorkflowTemplateFile(data: JSONEncoder().encode(JSON.object(envelope))))
        var document = captured.document.object; document["version"] = .number(1); document.removeValue(forKey: "capabilities")
        XCTAssertThrowsError(try WorkflowTemplate(document: .object(document)))
        document = captured.document.object; document["capabilities"] = .array([.string("future")]); XCTAssertThrowsError(try WorkflowTemplate(document: .object(document)))
        document = captured.document.object; var task = captured.tasks[0]; task["is_heading"] = .string("true"); document["tasks"] = .array([.object(task.fields)])
        XCTAssertThrowsError(try WorkflowTemplate(document: .object(document)))
    }
    func testCaptureRejectsUnsupportedKindsRatherThanDroppingTheirType() {
        var unknown = row("Unknown"); unknown["is_heading"] = .number(1); XCTAssertThrowsError(try template(unknown))
        var root = row("Container"); root["subtasks"] = .array([.object(unknown.fields)]); XCTAssertThrowsError(try template(root))
    }
    func testTemplateRunPreservesEveryHeadingWithFreshIdentitiesAndRelativeDates() throws {
        let source = tree(), captured = try template(source), start = try XCTUnwrap(Dates.parse("2026-12-01"))
        let changes = try captured.instantiate(account: other, name: "", start: start)
        let change = try XCTUnwrap(changes.first { $0.table == "tasks" }), created = Record(change.fields)
        XCTAssertNotEqual(created.id, source.id); XCTAssertEqual(created["is_heading"], .bool(true)); XCTAssertFalse(created.completed)
        XCTAssertEqual(created.string("due_date"), "2026-12-01"); XCTAssertEqual(created.string("description"), source.string("description"))
        let rows = changes.filter { $0.table == "tasks" }.map { Record($0.fields) }
        XCTAssertEqual(rows.count, 4, "The nested template tree becomes child rows")
        XCTAssertTrue(rows.allSatisfy { $0.fields["subtasks"] == nil })
        XCTAssertEqual(rows.filter { TaskKind($0) == .heading }.count, 2); XCTAssertTrue(rows.allSatisfy { !$0.completed })
        XCTAssertEqual(Set(rows.map(\.id)).count, 4); XCTAssertEqual(rows.filter { !$0.string("parent_id").isEmpty }.count, 3)
        XCTAssertTrue(TaskKind.permits(change, existing: nil)); XCTAssertTrue(TaskKind.requiresAuthoring(change, existing: nil))
    }
    func testTemplateMetadataEditsKeepHeadingCapabilityAndFlags() throws {
        let captured = try template(tree()), item = try XCTUnwrap(TemplateEditing.tasks(captured.document).first)
        let edited = try TemplateEditing.changing(captured.document, item: item, fields: ["description": .string("Updated instructions")])
        let decoded = try WorkflowTemplate(document: edited); XCTAssertTrue(decoded.requiresHeadingSupport)
        XCTAssertEqual(decoded.tasks[0]["is_heading"], .bool(true)); XCTAssertEqual(decoded.tasks[0].string("description"), "Updated instructions")
    }
    func testWorkspaceRoundTripPreservesRootAndNestedTypesAndRejectsDowngrade() throws {
        let source = tree(), file = WorkspaceBackup.make(Snapshot(tables: ["tasks": [source]]), account: owner)
        XCTAssertEqual(file.version, 2); XCTAssertEqual(file.capabilities, ["task_headings"])
        let read = try WorkspaceBackup.read(file.data()); XCTAssertEqual(read.tables["tasks"]?[0], source)
        var downgraded = file; downgraded.version = 1; downgraded.capabilities = nil
        XCTAssertThrowsError(try WorkspaceBackup.read(downgraded.data()))
        let plan = try read.plan(current: Snapshot(), account: other), restored = plan.changes.filter { $0.table == "tasks" }.map { Record($0.fields) }, copied = try XCTUnwrap(restored.first)
        XCTAssertEqual(copied["is_heading"], .bool(true)); XCTAssertNil(copied.fields["subtasks"]); XCTAssertNotEqual(copied.id, source.id)
        XCTAssertEqual(restored.count, 4, "The nested tree is restored as child rows"); XCTAssertEqual(restored.filter { TaskKind($0) == .heading }.count, 2)
    }
    func testNestedOnlyTypeAndExplicitOrdinaryTypeRequireWorkspaceCapabilityToo() throws {
        var source = row("Ordinary parent"); source["subtasks"] = .array([.object(row("Nested reference", heading: true).fields)])
        // A heading that exists only inside the legacy JSON column is no longer inspected by the backup header: restore turns it into a row.
        let file = WorkspaceBackup.make(Snapshot(tables: ["tasks": [source]]), account: owner); XCTAssertEqual(file.version, 1)
        XCTAssertNoThrow(try WorkspaceBackup.read(file.data()))
        source = row("Explicit ordinary"); source["is_heading"] = .bool(false)
        XCTAssertEqual(WorkspaceBackup.make(Snapshot(tables: ["tasks": [source]]), account: owner).version, 2)
        source["is_heading"] = .null; XCTAssertNoThrow(try WorkspaceBackup.read(WorkspaceBackup.make(Snapshot(tables: ["tasks": [source]]), account: owner).data()))
        XCTAssertEqual(WorkspaceBackup.make(Snapshot(tables: ["tasks": [row("Legacy")]]), account: owner).version, 1)
    }
    func testInvalidRootOrConvertedChildHeadingCannotBeRestoredCompleted() throws {
        var source = tree(); source["completed"] = .bool(true)
        XCTAssertThrowsError(try WorkspaceBackup.read(WorkspaceBackup.make(Snapshot(tables: ["tasks": [source]]), account: owner).data()))
        source = row("Root"); var bad = row("Invalid child", heading: true); bad["completed_at"] = .string("2026-11-01T12:00:00Z"); source["subtasks"] = .array([.object(bad.fields)])
        // The JSON child becomes a heading row on restore; a completed heading row is refused, as for any heading.
        XCTAssertThrowsError(try WorkspaceBackup.read(WorkspaceBackup.make(Snapshot(tables: ["tasks": [source]]), account: owner).data()).plan(current: Snapshot(), account: other))
    }
    func testDuplicationKeepsTypesButUsesFreshIdentity() throws {
        let source = row("Project reference", heading: true), workspace = WorkspaceBinding(account: owner, generation: UUID())
        let changes = try TaskSelectionPlan.duplicateChanges([source], accessibleRoots: [source], projects: [], workspace: workspace)
        let change = try XCTUnwrap(changes.first), copy = Record(change.fields)
        XCTAssertEqual(copy["is_heading"], .bool(true)); XCTAssertNotEqual(copy.id, source.id); XCTAssertNil(copy.fields["subtasks"])
        XCTAssertTrue(TaskKind.permits(change, existing: nil)); XCTAssertEqual(copy.string("description"), source.string("description"))
    }
    func testUnsupportedDuplicateRefusesWholeSelection() {
        let ordinary = row("Ordinary"); var future = row("Future"); future["is_heading"] = .string("future")
        XCTAssertThrowsError(try TaskSelectionPlan.duplicateChanges([ordinary, future], accessibleRoots: [ordinary, future], projects: [], workspace: .init(account: owner, generation: UUID())))
    }
    func testSavedEditorCopyKeepsHeadingTypeInsteadOfBecomingCompletable() throws {
        let original = tree(), recovery = try TaskEditorRecovery(account: owner, origin: nil, original: original, draft: original)
        let file = try recovery.copyBackup(current: Snapshot()), copied = try XCTUnwrap(file.tables["tasks"]?.first)
        XCTAssertEqual(file.version, 2); XCTAssertEqual(copied["is_heading"], .bool(true)); XCTAssertEqual(copied["subtasks"].list[0].object["is_heading"], .bool(true))
        XCTAssertFalse(copied.completed); XCTAssertNotEqual(copied.id, original.id); XCTAssertEqual(copied.string("description"), original.string("description"))
    }
    func testAuthoringGateAllowsExistingMetadataButRejectsIntroducedOrConvertedTypes() throws {
        let source = tree(); let metadata = Mutation(table: "tasks", recordID: source.id, method: "PATCH", fields: ["description": .string("Updated")])
        XCTAssertFalse(TaskKind.requiresAuthoring(metadata, existing: source))
        let change = try XCTUnwrap(TaskKind.change(source, heading: false)); XCTAssertTrue(TaskKind.requiresAuthoring(change, existing: source))
        let removed = Mutation(table: "tasks", recordID: source.id, method: "DELETE", fields: [:]); XCTAssertFalse(TaskKind.requiresAuthoring(removed, existing: source))
    }
    func testSharedTemplatePublicationDoesNotSendUnsupportedVersionTwoToOldService() throws {
        let captured = try template(tree())
        XCTAssertThrowsError(try TeamTemplateCommand(account: owner, origin: "https://synthetic.example", action: .publish, team: UUID().uuidString.lowercased(), template: UUID().uuidString.lowercased(), name: "Headings", document: captured.document))
    }
}

extension HeadingPortabilityTests {
    func testRealCoordinatedTemplateAndBackupFilesRoundTripTypedContent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-heading-file-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: folder) }
        let source = tree(), definition = try template(source)
        let templateURL = folder.appendingPathComponent("reference.taskfold-template.json")
        try WorkflowTemplateFile(name: "Reference", document: definition.document).encoded().write(to: templateURL)
        let imported = try WorkflowTemplateFile.read(templateURL)
        XCTAssertTrue(imported.template.requiresHeadingSupport); XCTAssertEqual(imported.template.tasks[0]["is_heading"], .bool(true))
        let backupURL = folder.appendingPathComponent("reference.taskfold-backup.json")
        try WorkspaceBackup.make(Snapshot(tables: ["tasks": [source]]), account: owner).data().write(to: backupURL)
        let restored = try WorkspaceBackup.readFile(backupURL); XCTAssertEqual(restored.tables["tasks"]?[0], source)
    }
    func testUnversionedTypedTablesCannotBypassTheBackupCapabilityHeader() throws {
        let source = tree(); let bytes = try JSONEncoder().encode(["tasks": [source]])
        XCTAssertThrowsError(try WorkspaceBackup.read(bytes))
    }
}
