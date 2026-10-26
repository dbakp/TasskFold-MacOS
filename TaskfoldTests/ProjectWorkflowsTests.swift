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

    func testEveryTemplateKindRetainsCreateOnlyIntentAcrossColdQueueAndHistory() throws {
        for kind in [WorkflowTemplate.Kind.project, .section, .task] {
            let source = fixture(), id = kind == .project ? "root" : kind == .section ? "section" : "source"
            let template = try WorkflowTemplate.capture(kind: kind, id: id, snapshot: source)
            let changes = try template.instantiate(account: owner, name: "Fresh workflow", targetProject: "destination")
            XCTAssertFalse(changes.isEmpty)
            XCTAssertTrue(changes.allSatisfy { $0.method == "POST" && $0.insertOnly == true })
            var snapshot = Snapshot()
            for change in changes { snapshot.apply(change); snapshot.pending.append(change) }
            let cold = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
            XCTAssertEqual(cold, snapshot)
            let history = EditHistory(changes: changes, snapshot: Snapshot())
            XCTAssertEqual(history.redo, changes, "Redo must retain create-only intent")
            for change in cold.pending {
                var newer = Record(change.fields)
                let field = change.table == "tasks" ? "title" : change.table == "view_orders" ? "ids" : "name"
                newer[field] = field == "ids" ? .array([]) : .string("Later edit")
                var current = Snapshot(tables: [change.table: [newer]])
                current.apply(change)
                XCTAssertEqual(current.tables[change.table], [newer], "Replaying \(change.table) cannot replace current work")
            }
        }
    }

    @MainActor func testWorkflowLostRepliesPreserveLaterEditsThroughBackendAndColdQueue() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthTransportTests.Stub.self]
        let session = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(JSON.object([
            "access_token": .string("synthetic"), "refresh_token": .string("synthetic-refresh"),
            "expires_in": .number(3600), "user": .object(["id": .string(owner)])])))
        let backend = Backend(configuration: ["URL": "https://native-auth.test", "Key": "public"],
            http: URLSession(configuration: config), session: session, persistSession: { _ in })
        defer { AuthTransportTests.Stub.handler = nil }
        let template = try WorkflowTemplate.capture(kind: .project, id: "root", snapshot: fixture())
        let changes = try template.instantiate(account: owner, name: "Retry workflow")
        XCTAssertEqual(Set(changes.map(\.table)), ["projects", "sections", "labels", "tasks", "view_orders"])
        var snapshot = Snapshot()
        for change in changes { snapshot.apply(change); snapshot.pending.append(change) }
        for original in changes {
            var remote: Record?, posts = 0, reads = 0
            var later = Record(original.fields)
            let field = original.table == "tasks" ? "title" : original.table == "view_orders" ? "ids" : "name"
            later[field] = field == "ids" ? .array([.string("later-order")]) : .string("Changed after creation")
            AuthTransportTests.Stub.handler = { request in
                XCTAssertEqual(request.url?.path, "/rest/v1/" + original.table)
                if request.httpMethod == "POST" {
                    posts += 1
                    let prefer = request.value(forHTTPHeaderField: "Prefer") ?? ""
                    XCTAssertEqual(prefer, "handling=strict,resolution=ignore-duplicates,missing=default,return=representation")
                    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                    XCTAssertEqual(query?.first { $0.name == "on_conflict" }?.value, original.table == "view_orders" ? "user_id,id" : "id")
                    if posts == 1 {
                        // The server saves, another client edits, then the response is lost.
                        remote = later; throw URLError(.networkConnectionLost)
                    }
                    // Emulate PostgREST conflict handling; merge would destroy the later edit.
                    if prefer.contains("resolution=merge-duplicates") { remote = Record(original.fields) }
                    return (200, Data("[]".utf8))
                }
                reads += 1
                XCTAssertEqual(request.httpMethod, "GET")
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first { $0.name == "id" }?.value, "eq." + original.recordID)
                XCTAssertEqual(query?.first { $0.name == "user_id" }?.value, "eq." + self.owner)
                return (200, try JSONEncoder().encode([try XCTUnwrap(remote)]))
            }
            let queued = try XCTUnwrap(snapshot.pending.first)
            XCTAssertEqual(queued, original)
            do { _ = try await backend.send(queued, expectedAccount: owner); XCTFail("Lost reply must remain unconfirmed") }
            catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
            snapshot = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
            XCTAssertEqual(snapshot.pending.first, original)
            let saved = try await backend.send(try XCTUnwrap(snapshot.pending.first), expectedAccount: owner)
            XCTAssertEqual(saved, later)
            XCTAssertTrue(snapshot.acknowledge(original, saved: saved))
            XCTAssertEqual(snapshot.tables[original.table]?.first { $0.id == original.recordID }, later)
            XCTAssertEqual(posts, 2); XCTAssertEqual(reads, 1)
        }
        XCTAssertTrue(snapshot.pending.isEmpty)
    }


    @MainActor func testWorkflowRetryCannotAcknowledgeMissingOrForeignRows() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthTransportTests.Stub.self]
        let session = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(JSON.object([
            "access_token": .string("synthetic"), "refresh_token": .string("synthetic-refresh"),
            "expires_in": .number(3600), "user": .object(["id": .string(owner)])])))
        let backend = Backend(configuration: ["URL": "https://native-auth.test", "Key": "public"],
            http: URLSession(configuration: config), session: session, persistSession: { _ in })
        defer { AuthTransportTests.Stub.handler = nil }
        let template = try WorkflowTemplate.capture(kind: .project, id: "root", snapshot: fixture())
        for change in try template.instantiate(account: owner, name: "Private workflow") {
            for foreign in [false, true] {
                AuthTransportTests.Stub.handler = { request in
                    if request.httpMethod == "POST" || !foreign { return (200, Data("[]".utf8)) }
                    var row = Record(change.fields); row["user_id"] = .string("other-owner")
                    return (200, try JSONEncoder().encode([row]))
                }
                do { _ = try await backend.send(change, expectedAccount: owner); XCTFail("Unconfirmed \(change.table) must stay queued") }
                catch { XCTAssertTrue(error.localizedDescription.contains("could not confirm")) }
            }
        }
    }


    func workflowUndoFixture() throws -> (changes: [Mutation], snapshot: Snapshot, command: Mutation) {
        let template = try WorkflowTemplate.capture(kind: .project, id: "root", snapshot: fixture())
        let changes = try template.instantiate(account: owner, name: "Undo workflow").map { TaskCompletionRevision.capturing($0, existing: nil) }
        var snapshot = Snapshot(); for change in changes { snapshot.apply(change) }
        let history = EditHistory(changes: changes, snapshot: Snapshot())
        XCTAssertEqual(history.undo.count, 1)
        return (changes, snapshot, try XCTUnwrap(history.undo.first))
    }
    func testWorkflowUndoIsOneColdDurableCommandAndRedoCreatesFreshTaskIncarnations() throws {
        let f = try workflowUndoFixture()
        try WorkflowUndo.validate(f.command, snapshot: f.snapshot, account: owner)
        var snapshot = f.snapshot; snapshot.apply(f.command); snapshot.pending = [f.command]
        let cold = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(cold, snapshot); XCTAssertTrue(f.changes.allSatisfy { cold.tables[$0.table]?.isEmpty == true })
        let history = EditHistory(changes: [f.command], snapshot: f.snapshot)
        XCTAssertEqual(history.undo.map(\.recordID), f.changes.map(\.recordID))
        XCTAssertTrue(history.undo.allSatisfy { $0.method == "POST" && $0.insertOnly == true && $0.workflowRun == f.command.workflowRun })
        let redo = history.undo.map { TaskGeneration.restoring($0, existing: nil) }
        for task in redo where task.table == "tasks" {
            XCTAssertNotEqual(task.fields["task_generation"], f.changes.first { $0.recordID == task.recordID }?.fields["task_generation"])
        }
        let secondUndo = EditHistory(changes: redo, snapshot: snapshot).undo
        XCTAssertEqual(secondUndo.count, 1); XCTAssertNotEqual(secondUndo.first?.id, f.command.id)
    }
    func testWorkflowUndoRefusesObservedChangesAndIncomingDependenciesBeforeLocalDeletion() throws {
        let f = try workflowUndoFixture(), project = try XCTUnwrap(f.changes.first { $0.table == "projects" })
        for table in ["projects", "sections", "labels", "tasks", "view_orders"] {
            var snapshot = f.snapshot
            let index = try XCTUnwrap(snapshot.tables[table]?.indices.first)
            snapshot.tables[table]![index][table == "tasks" ? "title" : table == "view_orders" ? "ids" : "name"] = table == "view_orders" ? .array([]) : .string("Later edit")
            XCTAssertThrowsError(try WorkflowUndo.validate(f.command, snapshot: snapshot, account: owner))
        }
        var snapshot = f.snapshot, incoming = Record.task(user: owner, project: project.recordID)
        incoming["title"] = .string("Later task"); snapshot.tables["tasks", default: []].append(incoming)
        XCTAssertThrowsError(try WorkflowUndo.validate(f.command, snapshot: snapshot, account: owner))
        XCTAssertThrowsError(try WorkflowUndo.validate(f.command, snapshot: f.snapshot, account: "another-account"))
        var invalid = f.command; invalid.fields["items"] = .array([])
        XCTAssertNil(WorkflowUndo.items(invalid))
    }
    func testRefusedWorkflowUndoRestoresCurrentRowsAndReplaysLaterQueuedEdits() throws {
        let f = try workflowUndoFixture(), task = try XCTUnwrap(f.changes.first { $0.table == "tasks" })
        var snapshot = f.snapshot; snapshot.apply(f.command)
        let later = Mutation(table: "tasks", recordID: task.recordID, method: "PATCH", fields: ["title": .string("My later title")])
        snapshot.pending = [f.command, later]
        var rows = f.changes.map { value in JSON.object(["table": .string(value.table), "row": .object(value.fields)]) }
        let projectIndex = try XCTUnwrap(f.changes.firstIndex { $0.table == "projects" })
        var project = f.changes[projectIndex].fields; project["name"] = .string("Another device renamed this")
        rows[projectIndex] = .object(["table": .string("projects"), "row": .object(project)])
        let saved = Record(["id": .string(f.command.id.uuidString.lowercased()), "applied": .bool(false), "rows": .array(rows)])
        XCTAssertTrue(snapshot.acknowledge(f.command, saved: saved)); XCTAssertEqual(snapshot.pending, [later])
        XCTAssertEqual(snapshot.tables["projects"]?.first { $0.id == project["id"]?.text }?.name, "Another device renamed this")
        XCTAssertEqual(snapshot.tables["tasks"]?.first { $0.id == task.recordID }?.title, "My later title")
        var bad = saved; bad["id"] = .string(UUID().uuidString.lowercased())
        XCTAssertNil(WorkflowUndo.reply(bad, change: f.command))
        bad = saved; var foreign = project; foreign["user_id"] = .string("foreign")
        bad["rows"] = .array([.object(["table": .string("projects"), "row": .object(foreign)])])
        XCTAssertNil(WorkflowUndo.reply(bad, change: f.command))
    }
    @MainActor func testWorkflowUndoUsesOnlyAtomicRPCAndNeverFallsBackToRowDeletion() async throws {
        let f = try workflowUndoFixture()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthTransportTests.Stub.self]
        let session = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(JSON.object([
            "access_token": .string("synthetic"), "refresh_token": .string("synthetic-refresh"),
            "expires_in": .number(3600), "user": .object(["id": .string(owner)])])))
        let backend = Backend(configuration: ["URL": "https://native-auth.test", "Key": "public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        defer { AuthTransportTests.Stub.handler = nil }
        var requests = 0
        AuthTransportTests.Stub.handler = { request in
            requests += 1; XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_undo_private_workflow")
            return (200, try JSONEncoder().encode(Record(["id": .string(f.command.id.uuidString.lowercased()), "applied": .bool(true), "rows": .array([])])))
        }
        let saved = try await backend.send(f.command, expectedAccount: owner)
        XCTAssertEqual(WorkflowUndo.reply(saved, change: f.command)?.applied, true); XCTAssertEqual(requests, 1)
        AuthTransportTests.Stub.handler = { _ in requests += 1; return (404, Data("{}".utf8)) }
        do { _ = try await backend.send(f.command, expectedAccount: owner); XCTFail("Missing service must preserve the queue") } catch {}
        XCTAssertEqual(requests, 2, "No generic DELETE fallback")
    }


    func testWorkflowUndoCompatibilityIsExactAccountBoundAndNeverUsesLegacyFallback() throws {
        let change = try workflowUndoFixture().command, account = "f6310000-0000-4000-8000-000000000001"
        for value: JSON? in [nil, .null, .number(0), .number(2), .string("1"), .bool(true), .number(1)] {
            var raw: [String: JSON] = ["workspace_boundary_protocol": .number(1), "account": .string(account), "native_team_reads_enabled": .bool(false), "setup_paused": .bool(true), "projects": .array([]), "teams": .array([]), "token": .string(String(repeating: "a", count: 64))]; raw["personal_workflow_undo_protocol"] = value
            let boundary = try TeamWorkspaceBoundary(raw, account: account, origin: "https://personal.example")
            XCTAssertEqual(WorkflowUndo.available(boundary: boundary, account: account, origin: boundary.origin), value == .number(1))
            XCTAssertEqual(WorkflowUndo.canSend(change, boundary: boundary), value == .number(1))
            XCTAssertFalse(WorkflowUndo.available(boundary: boundary, account: owner, origin: boundary.origin))
            XCTAssertFalse(WorkflowUndo.available(boundary: boundary, account: account, origin: "https://another.example"))
        }
        XCTAssertFalse(WorkflowUndo.canSend(change, boundary: nil))
        var bad = try workflowUndoFixture().changes; bad[0].table = "unexpected"
        XCTAssertTrue(EditHistory(changes: bad, snapshot: Snapshot()).undo.isEmpty, "Tagged workflow history must not degrade to individual DELETEs")
    }




    func testWorkflowUndoBudgetCountsPostgresSpacesAndExpandedNumbers() {
        func bytes(_ value: JSON) -> Int? { WorkflowUndo.bodyBytes(Mutation(table: "test", recordID: "test", method: "POST", fields: ["n": value])) }
        XCTAssertEqual(bytes(.number(1e100)), 108)
        XCTAssertEqual(bytes(.number(-1e-100)), 110)
        XCTAssertEqual(bytes(.array([.number(1e100), .number(-1e-100)])), 215)
        XCTAssertEqual(bytes(.string("https://x\nñ🙂")), 26)
        XCTAssertEqual(bytes(.string("comma, colon: quote\" slash\\")), 38)
        XCTAssertEqual(bytes(.number(-0.0)), 8)
        let exponentBody = Mutation(table: "test", recordID: "test", method: "POST", fields: ["n": .array(Array(repeating: .number(1e308), count: 60000))])
        XCTAssertEqual(WorkflowUndo.bodyBytes(exponentBody), 18_660_007)
        XCTAssertFalse(WorkflowUndo.fitsBody(exponentBody), "Compact JSON below 1 MB must not bypass the service's expanded-byte budget")
        XCTAssertNil(bytes(.number(.infinity)))
    }

    func testWorkflowBulkReplayProtectsRecreatedTaskAndUnrelatedRows() throws {
        let f = try workflowUndoFixture(), created = try XCTUnwrap(f.changes.first { $0.table == "tasks" })
        var snapshot = f.snapshot
        let index = try XCTUnwrap(snapshot.tables["tasks"]?.firstIndex { $0.id == created.recordID })
        snapshot.tables["tasks"]![index]["task_generation"] = .string(UUID().uuidString.lowercased())
        snapshot.tables["tasks"]![index]["title"] = .string("Restored on another device")
        let recreated = snapshot.tables["tasks"]![index]
        var unrelated = Record.task(user: owner); unrelated["title"] = .string("Unrelated work")
        snapshot.tables["tasks", default: []].append(unrelated)
        snapshot.apply(f.command)
        XCTAssertEqual(snapshot.tables["tasks"]?.first { $0.id == recreated.id }, recreated)
        XCTAssertEqual(snapshot.tables["tasks"]?.first { $0.id == unrelated.id }, unrelated)
        snapshot.pending = [f.command, Mutation(table: "tasks", recordID: recreated.id, method: "PATCH", fields: ["title": .string("Stale generation edit")], baseline: ["task_generation": created.fields["task_generation"]!])]
        let rows = f.changes.map { item in JSON.object(["table": .string(item.table), "row": .object(item.recordID == recreated.id ? recreated.fields : item.fields)]) }
        let saved = Record(["id": .string(f.command.id.uuidString.lowercased()), "applied": .bool(false), "rows": .array(rows)])
        XCTAssertTrue(snapshot.acknowledge(f.command, saved: saved))
        XCTAssertEqual(snapshot.tables["tasks"]?.first { $0.id == recreated.id }, recreated)
        XCTAssertEqual(snapshot.tables["tasks"]?.first { $0.id == unrelated.id }, unrelated)
        XCTAssertEqual(snapshot.pending.count, 1, "A refused Undo cannot acknowledge a later edit")
    }

    func testFullSizedSectionedWorkflowKeepsOneUndoCommand() throws {
        let count = 5000
        let document: JSON = .object(["version": .number(1), "kind": .string("project"),
            "projects": .array([.object(["id": .string("root"), "name": .string("Large project")])]),
            "sections": .array((0..<count).map { .object(["id": .string("s\($0)"), "name": .string("Section \($0)"), "project_id": .string("root"), "order_index": .number(Double($0))]) }),
            "tasks": .array((0..<count).map { .object(["id": .string("t\($0)"), "title": .string("Task \($0)"), "project_id": .string("root"), "section_id": .string("s\($0)"), "labels": .array([.object(["name": .string("Label \($0)")])]), "subtasks": .array([])]) })])
        let definition = try WorkflowTemplate(document: document)
        let changes = try definition.instantiate(account: owner, name: "Large workflow")
        XCTAssertEqual(changes.count, 20001)
        let history = EditHistory(changes: changes, snapshot: Snapshot())
        XCTAssertEqual(history.undo.count, 1, "A valid complete workflow must not silently lose Undo")
        let command = try XCTUnwrap(history.undo.first)
        XCTAssertEqual(WorkflowUndo.items(command)?.count, changes.count)
        var raw: [String: JSON] = ["workspace_boundary_protocol": .number(1), "account": .string(owner), "native_team_reads_enabled": .bool(false), "setup_paused": .bool(true), "projects": .array([]), "teams": .array([]), "token": .string(String(repeating: "a", count: 64)), "personal_workflow_undo_protocol": .number(1)]
        let legacy = try TeamWorkspaceBoundary(raw, account: owner, origin: "https://synthetic.example")
        XCTAssertFalse(WorkflowUndo.canSend(command, boundary: legacy), "An older count-limited service must pause this intact command")
        raw["personal_workflow_undo_bulk_protocol"] = .number(1)
        XCTAssertTrue(WorkflowUndo.canSend(command, boundary: try TeamWorkspaceBoundary(raw, account: owner, origin: legacy.origin)))
        var snapshot = Snapshot(tables: Dictionary(grouping: changes, by: \.table).mapValues { $0.map { Record($0.fields) } })
        let initial = snapshot
        try WorkflowUndo.validate(command, snapshot: snapshot, account: owner)
        snapshot.apply(command); XCTAssertTrue(snapshot.tables.values.allSatisfy(\.isEmpty)); snapshot.pending = [command]
        snapshot = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        let task = try XCTUnwrap(changes.first { $0.table == "tasks" })
        let later = Mutation(table: "tasks", recordID: task.recordID, method: "PATCH", fields: ["title": .string("My later work")])
        snapshot.pending.append(later)
        let refused = Record(["id": .string(command.id.uuidString.lowercased()), "applied": .bool(false), "rows": .array(changes.map { .object(["table": .string($0.table), "row": .object($0.fields)]) })])
        XCTAssertTrue(snapshot.acknowledge(command, saved: refused)); XCTAssertEqual(snapshot.pending, [later])
        XCTAssertEqual(snapshot.tables.values.reduce(0) { $0 + $1.count }, changes.count)
        XCTAssertEqual(snapshot.tables["tasks"]?.first { $0.id == task.recordID }?.title, "My later work")
        for table in ["projects", "sections", "labels", "view_orders"] { XCTAssertEqual(Set(snapshot.tables[table]!.map(\.id)), Set(initial.tables[table]!.map(\.id))) }
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

extension ProjectWorkflowsTests {
    func templateRow() throws -> Record {
        let definition=try WorkflowTemplate.capture(kind:.project,id:"root",snapshot:fixture())
        return Record(["id":.string("template"),"user_id":.string(owner),"name":.string("Weekly studio"),"document":definition.document])
    }
    func testDefinitionEditsKeepNestedIdentitiesMetadataAndExistingRuns() throws {
        let original=try templateRow(),before=try WorkflowTemplate(document:original["document"]).instantiate(account:owner,name:"Previous run")
        let item=try XCTUnwrap(TemplateEditing.tasks(original["document"]).first{$0.record.title=="Design review"})
        let edited=try TemplateEditing.changing(original["document"],item:item,fields:["description":.string("New reusable notes"),"duration_minutes":.number(45),"planned_offset":.null,"deadline_offset":.number(7)])
        let updated=TemplateEditing.tasks(edited).first{$0.record.id==item.record.id}!.record
        XCTAssertNil(updated.fields["planned_offset"]);XCTAssertEqual(updated["deadline_offset"],.number(7));XCTAssertEqual(updated["labels"],item.record["labels"]);XCTAssertEqual(updated["subtasks"],item.record["subtasks"])
        let saved=try TemplateEditing.edit(original:original,name:"  Better studio  ",document:edited,current:original)
        XCTAssertEqual(saved.name,"Better studio");XCTAssertEqual(saved.id,original.id);XCTAssertEqual(saved["user_id"],original["user_id"])
        let after=try WorkflowTemplate(document:saved["document"]).instantiate(account:owner,name:"Next run",start:Dates.parse("2026-11-01"))
        XCTAssertTrue(before.filter{$0.table=="tasks"}.allSatisfy{$0.fields["description"] != .string("New reusable notes")})
        XCTAssertTrue(after.contains{$0.table=="tasks" && $0.fields["description"] == .string("New reusable notes") && $0.fields["duration_minutes"] == .number(45) && $0.fields["due_date"] == .null})
        XCTAssertTrue(Set(before.filter{$0.table=="tasks"}.map(\.recordID)).isDisjoint(with:Set(after.filter{$0.table=="tasks"}.map(\.recordID))))
    }
    func testDefinitionChildAddDeleteAndOrganizationRenameAreDraftOnly() throws {
        let row=try templateRow(),original=row["document"],parent=TemplateEditing.tasks(original).first!
        let added=try TemplateEditing.adding(original,parent:parent)
        XCTAssertEqual(TemplateEditing.tasks(added).count,TemplateEditing.tasks(original).count+1)
        let new=TemplateEditing.tasks(added).first{$0.record.title=="New task"}!
        XCTAssertEqual(try TemplateEditing.changing(added,item:new,fields:[:],remove:true),original)
        let renamed=try TemplateEditing.renamed(original,table:"projects",id:"child",name:"  Review studio  ")
        XCTAssertEqual(try WorkflowTemplate(document:renamed).projects.first{$0.id=="child"}?.name,"Review studio")
        XCTAssertEqual(row["document"],original)
        XCTAssertThrowsError(try TemplateEditing.renamed(original,table:"sections",id:"section",name:" "))
    }
    func testTemplateSaveRejectsStaleDeletedInvalidAndUnsupportedDefinitions() throws {
        let row=try templateRow();var remote=row;remote["name"] = .string("Another device")
        XCTAssertThrowsError(try TemplateEditing.edit(original:row,name:"Local",document:row["document"],current:remote))
        XCTAssertThrowsError(try TemplateEditing.edit(original:row,name:"Local",document:row["document"],current:nil))
        XCTAssertThrowsError(try TemplateEditing.edit(original:row,name:String(repeating:"x",count:161),document:row["document"],current:row))
        var future=row["document"].object;future["version"] = .number(99)
        XCTAssertThrowsError(try TemplateEditing.edit(original:row,name:"Local",document:.object(future),current:row))
    }
    func testTemplateConflictKeepsExplicitDocumentChoiceAndIndependentRemoteName() throws {
        let original=try templateRow();var remote=original;remote["name"] = .string("Remote name")
        let item=TemplateEditing.tasks(original["document"]).first!
        let document=try TemplateEditing.changing(original["document"],item:item,fields:["title":.string("Local definition")])
        let change=Mutation(table:WorkflowTemplate.table,recordID:original.id,method:"PATCH",fields:["document":document],baseline:original.fields)
        var snapshot=Snapshot(tables:[WorkflowTemplate.table:[original],"tasks":fixture().tables["tasks"]!],pending:[change]);snapshot.apply(change)
        let reviewed=try XCTUnwrap(SyncConflict(mutation:change,remote:remote).resolving(snapshot,keepLocal:true))
        XCTAssertEqual(reviewed.tables[WorkflowTemplate.table]?.first?.name,"Remote name")
        XCTAssertEqual(reviewed.tables[WorkflowTemplate.table]?.first?["document"],document)
        XCTAssertEqual(reviewed.pending.first?.baseline,remote.fields)
        XCTAssertEqual(reviewed.tables["tasks"],snapshot.tables["tasks"])
        XCTAssertEqual(try JSONDecoder().decode(Snapshot.self,from:JSONEncoder().encode(reviewed)),reviewed)
    }
    func testUseSyncedTemplateKeepsLaterOfflineWorkGuardedByItsOriginalBaseline() throws {
        let row=try templateRow();var remote=row;remote["name"] = .string("Remote name")
        let first=Mutation(table:WorkflowTemplate.table,recordID:row.id,method:"PATCH",fields:["name":.string("First local")],baseline:row.fields)
        var secondBase=row;secondBase["name"] = .string("First local")
        let second=Mutation(table:WorkflowTemplate.table,recordID:row.id,method:"PATCH",fields:["name":.string("Later local")],baseline:secondBase.fields)
        let snapshot=Snapshot(tables:[WorkflowTemplate.table:[row]],pending:[first,second])
        let reviewed=try XCTUnwrap(SyncConflict(mutation:first,remote:remote).resolving(snapshot,keepLocal:false))
        XCTAssertEqual(reviewed.pending,[second]);XCTAssertEqual(reviewed.tables[WorkflowTemplate.table]?.first?.name,"Later local")
        XCTAssertEqual(reviewed.pending.first?.baseline?["name"],.string("First local"),"Later overlapping work must still require review against Remote name")
    }
    func testDeletedTemplateRecoveryCreatesNewIdentityAndNeverRecreatesOldID() throws {
        let row=try templateRow(),change=Mutation(table:WorkflowTemplate.table,recordID:row.id,method:"PATCH",fields:["name":.string("Recovered")],baseline:row.fields)
        let snapshot=Snapshot(tables:[WorkflowTemplate.table:[row]],pending:[change]),missing=Record(["id":.string(row.id),"name":.string("Deleted template")])
        let recovered=try XCTUnwrap(SyncConflict(mutation:change,remote:missing).resolving(snapshot,keepLocal:true))
        XCTAssertEqual(recovered.pending.count,1);XCTAssertEqual(recovered.pending[0].method,"POST");XCTAssertNotEqual(recovered.pending[0].recordID,row.id)
        XCTAssertEqual(recovered.tables[WorkflowTemplate.table]?.first?.name,"Recovered")
        XCTAssertFalse(recovered.tables[WorkflowTemplate.table]!.contains{$0.id==row.id})
        let discarded=try XCTUnwrap(SyncConflict(mutation:change,remote:missing).resolving(snapshot,keepLocal:false));XCTAssertTrue(discarded.pending.isEmpty);XCTAssertTrue(discarded.tables[WorkflowTemplate.table]!.isEmpty)
    }
}

extension ProjectWorkflowsTests {
    func testTemplateSiblingMovesRetainWholeBranchAndRoundTripExactly() throws {
        let row=try templateRow(),source=row["document"]
        let item=try XCTUnwrap(TemplateEditing.tasks(source).first{$0.record.title=="Design review"})
        let moved=try TemplateEditing.moving(source,item:item,delta:-1)
        XCTAssertEqual(moved.object["tasks"]?.list.first,.object(item.record.fields))
        let back=TemplateEditing.tasks(moved).first!
        XCTAssertEqual(try TemplateEditing.moving(moved,item:back,delta:1),source)
        XCTAssertThrowsError(try TemplateEditing.moving(moved,item:back,delta:-1))
    }
    func testRecoveredTemplateRemapsLaterFullRecordIdentity() throws {
        let row=try templateRow(),change=Mutation(table:WorkflowTemplate.table,recordID:row.id,method:"PATCH",fields:["name":.string("Recovered")],baseline:row.fields)
        let later=Mutation(table:WorkflowTemplate.table,recordID:row.id,method:"POST",fields:row.fields)
        let reviewed=try XCTUnwrap(SyncConflict(mutation:change,remote:Record(["id":.string(row.id)])).resolving(Snapshot(tables:[:],pending:[change,later]),keepLocal:true))
        let copyID=reviewed.pending[0].recordID
        XCTAssertNotEqual(copyID,row.id);XCTAssertEqual(reviewed.pending[1].recordID,copyID);XCTAssertEqual(reviewed.pending[1].fields["id"],.string(copyID))
        XCTAssertFalse(reviewed.tables[WorkflowTemplate.table]!.contains{$0.id==row.id})
    }
}

extension ProjectWorkflowsTests {
    func testNewerSyncedDefinitionCannotBeOverwrittenDuringConflictReview() throws {
        let row=try templateRow();var remote=row,document=row["document"].object;document["version"] = .number(99);remote["document"] = .object(document)
        let change=Mutation(table:WorkflowTemplate.table,recordID:row.id,method:"PATCH",fields:["document":row["document"]],baseline:row.fields)
        let snapshot=Snapshot(tables:[WorkflowTemplate.table:[row]],pending:[change]),conflict=SyncConflict(mutation:change,remote:remote)
        XCTAssertNil(conflict.resolving(snapshot,keepLocal:true))
        let accepted=try XCTUnwrap(conflict.resolving(snapshot,keepLocal:false));XCTAssertEqual(accepted.tables[WorkflowTemplate.table]?.first?["document"],remote["document"]);XCTAssertTrue(accepted.pending.isEmpty)
    }
}

extension ProjectWorkflowsTests {
    func testQueuedTemplateDraftSurvivesAuthenticatedRemoteAbsenceWithoutBecomingCreation() throws {
        let row=try templateRow(),change=Mutation(table:WorkflowTemplate.table,recordID:row.id,method:"PATCH",fields:["name":.string("Queued draft")],baseline:row.fields)
        var snapshot=Snapshot(tables:[WorkflowTemplate.table:[row]],pending:[change])
        snapshot.mergeRemote([WorkflowTemplate.table:[]])
        let draft=try XCTUnwrap(snapshot.tables[WorkflowTemplate.table]?.first)
        XCTAssertEqual(draft.id,row.id);XCTAssertEqual(draft.name,"Queued draft");XCTAssertEqual(draft["document"],row["document"])
        XCTAssertEqual(snapshot.pending,[change]);XCTAssertEqual(snapshot.pending[0].method,"PATCH")
        XCTAssertEqual(try JSONDecoder().decode(Snapshot.self,from:JSONEncoder().encode(snapshot)),snapshot)
    }
}

extension ProjectWorkflowsTests {
    func testReviewedTemplateCreationBecomesGuardedPatchWithoutOwnershipFields() throws {
        let row=try templateRow();var remote=row;remote["name"] = .string("Changed after restore")
        let creation=Mutation(table:WorkflowTemplate.table,recordID:row.id,method:"POST",fields:row.fields)
        let reviewed=try XCTUnwrap(SyncConflict(mutation:creation,remote:remote).resolving(Snapshot(tables:[:],pending:[creation]),keepLocal:true))
        let patch=reviewed.pending[0]
        XCTAssertEqual(patch.method,"PATCH");XCTAssertEqual(Set(patch.fields.keys),["name","document"]);XCTAssertEqual(patch.baseline,remote.fields)
        XCTAssertEqual(reviewed.tables[WorkflowTemplate.table]?.first?.name,row.name)
    }
}

extension ProjectWorkflowsTests {
    func testTemplateReviewIncludesChangedSchedulePriorityNotesAndDestinations() throws {
        let row=try templateRow(),item=try XCTUnwrap(TemplateEditing.tasks(row["document"]).first{$0.record.title=="Design review"})
        let document=try TemplateEditing.changing(row["document"],item:item,fields:["priority":.number(1),"description":.string("Review these new notes"),"duration_minutes":.number(45),"planned_offset":.number(2),"deadline_offset":.number(7)])
        let review=TemplateEditing.reviewText(document)
        for value in ["Design review","Review these new notes","Priority 1","45 min","Planned day 2","Deadline day 7","root · Prepare","Prepare outline"] { XCTAssertTrue(review.contains(value),value) }
        var unsupported=document.object;unsupported["version"] = .number(99)
        XCTAssertTrue(TemplateEditing.reviewText(.object(unsupported)).contains("newer Taskfold version"))
    }

    func testPortableTemplateRoundTripRemapsReferencesAndCreatesIndependentRuns() throws {
        let original = fixture()
        let definition = try WorkflowTemplate.capture(kind: .project, id: "root", snapshot: original)
        let file = try WorkflowTemplateFile(name: "  Launch checklist  ", document: definition.document)
        let data = try file.encoded()
        let decoded = try WorkflowTemplateFile(data: data)
        XCTAssertEqual(decoded.name, "Launch checklist")
        XCTAssertEqual(decoded.template.projects.map(\.id), ["project-0002", "project-0001"])
        XCTAssertEqual(decoded.template.tasks.map(\.id), ["task-1", "task-2"])
        XCTAssertEqual(decoded.template.tasks.first { $0.title == "Design review" }?.string("section_id"), "section-0001")
        XCTAssertEqual(decoded.template.sections.first?.string("project_id"), "project-0002")
        let changes = try decoded.template.instantiate(account: "new-owner", name: "Fresh launch", start: Dates.parse("2026-11-01"))
        let task = try XCTUnwrap(changes.first { $0.table == "tasks" && $0.fields["title"] == .string("Design review") })
        XCTAssertEqual(task.fields["due_date"], .string("2026-11-01"))
        XCTAssertTrue(changes.allSatisfy { $0.fields["user_id"] == .string("new-owner") })
        XCTAssertFalse(changes.contains { $0.recordID == "root" || $0.recordID == "source" })
        XCTAssertTrue(original.tables["tasks"]!.first!.completed, "Export does not reset the source")
        XCTAssertEqual(try decoded.encoded(), data, "Portable references are deterministic")
    }

    func testPortableTemplateExcludesAccountAndLabelIdentityMetadata() throws {
        let definition = try WorkflowTemplate.capture(kind: .project, id: "root", snapshot: fixture())
        var document = definition.document.object
        var tasks = document["tasks"]!.list
        var task = tasks[0].object
        task["labels"] = .array([.object(["name": .string("Design"), "color": .string("#e31e4b"), "user_id": .string("private-account"), "id": .string("private-label")])])
        tasks[0] = .object(task); document["tasks"] = .array(tasks)
        let data = try WorkflowTemplateFile(name: "Shareable", document: .object(document)).encoded()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(owner)); XCTAssertFalse(text.contains("private-account")); XCTAssertFalse(text.contains("private-label"))
        let decoded = try WorkflowTemplateFile(data: data)
        XCTAssertEqual(Set(decoded.template.tasks[0]["labels"].list[0].object.keys), ["name", "color"])
    }

    func testPortableTemplateRejectsWrongFormatFutureVersionAndMalformedDefinitions() throws {
        let definition = try WorkflowTemplate.capture(kind: .project, id: "root", snapshot: fixture())
        let file = try WorkflowTemplateFile(name: "Checklist", document: definition.document)
        var root = try JSONDecoder().decode(JSON.self, from: file.encoded()).object
        root["version"] = .number(2)
        XCTAssertThrowsError(try WorkflowTemplateFile(data: JSONEncoder().encode(JSON.object(root))))
        root["version"] = .number(1); root["account"] = .string(owner)
        XCTAssertThrowsError(try WorkflowTemplateFile(data: JSONEncoder().encode(JSON.object(root))))
        root.removeValue(forKey: "account"); root["document"] = .object([:])
        XCTAssertThrowsError(try WorkflowTemplateFile(data: JSONEncoder().encode(JSON.object(root))))
        XCTAssertThrowsError(try WorkflowTemplateFile(data: Data("not json".utf8)))
        XCTAssertThrowsError(try WorkflowTemplateFile(data: Data(repeating: 32, count: WorkflowTemplateFile.maximumBytes + 1)))
        XCTAssertThrowsError(try WorkflowTemplateFile(name: "  ", document: definition.document))
        XCTAssertThrowsError(try WorkflowTemplateFile(name: String(repeating: "x", count: 161), document: definition.document))
    }

    func testPortableSectionAndTaskFilesRemainReusableAndUnknownRepeatDetailsFailClosed() throws {
        for kind in [WorkflowTemplate.Kind.section, .task] {
            let definition = try WorkflowTemplate.capture(kind: kind, id: kind == .section ? "section" : "source", snapshot: fixture())
            let file = try WorkflowTemplateFile(name: "Reusable", document: definition.document)
            let decoded = try WorkflowTemplateFile(data: file.encoded())
            XCTAssertEqual(decoded.template.kind, kind)
            let changes = try decoded.template.instantiate(account: "recipient", name: "", targetProject: "destination")
            XCTAssertTrue(changes.filter { $0.table == "tasks" }.allSatisfy { $0.fields["project_id"] == .string("destination") })
            XCTAssertFalse(changes.contains { $0.table == "projects" })
            var document = definition.document.object
            var tasks = document["tasks"]!.list, task = tasks[0].object
            task["recurrence_pattern"] = .object(["futurePolicy": .string("unknown")])
            tasks[0] = .object(task); document["tasks"] = .array(tasks)
            XCTAssertThrowsError(try WorkflowTemplateFile(name: "Future", document: .object(document)))
        }
    }

    func testPortableTemplatePreservesLegacyOrganizationOrderAcrossDoubleDigitReferences() throws {
        let children: [JSON] = (0..<12).reversed().map { index in
            .object(["id": .string(String(format: "child-%02d", index)), "name": .string("Step \(index)"), "parent_id": .string("root")])
        }
        let sections: [JSON] = (0..<12).reversed().map { index in
            .object(["id": .string(String(format: "section-%02d", index)), "name": .string("Phase \(index)"), "project_id": .string("root")])
        }
        let document = JSON.object(["version": .number(1), "kind": .string("project"), "projects": .array([.object(["id": .string("root"), "name": .string("Launch")])] + children), "sections": .array(sections), "tasks": .array([])])
        let original = try WorkflowTemplateFile(name: "Launch", document: document)
        let decoded = try WorkflowTemplateFile(data: original.encoded())
        XCTAssertEqual(ProjectOrganization.outline(original.template.projects).map { $0.project.name }, ProjectOrganization.outline(decoded.template.projects).map { $0.project.name })
        XCTAssertEqual(OrganizationOrder.sorted(original.template.sections).map(\.name), OrganizationOrder.sorted(decoded.template.sections).map(\.name))
        XCTAssertEqual(try original.encoded(), try decoded.encoded())
    }

    func testCoordinatedTemplateFileReadAndOversizeRefusal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workflow.json")
        let definition = try WorkflowTemplate.capture(kind: .project, id: "root", snapshot: fixture())
        var document = definition.document.object
        var projects = document["projects"]!.list, project = projects[0].object
        project["description"] = .string(String(repeating: "Résumé 🙂 ", count: 20_000))
        projects[0] = .object(project); document["projects"] = .array(projects)
        let file = try WorkflowTemplateFile(name: "Portable launch", document: .object(document))
        try file.encoded().write(to: url)
        XCTAssertEqual(try WorkflowTemplateFile.read(url).encoded(), try file.encoded())
        try Data(repeating: 32, count: WorkflowTemplateFile.maximumBytes + 1).write(to: url)
        XCTAssertThrowsError(try WorkflowTemplateFile.read(url))
        try Data("invalid json".utf8).write(to: url)
        XCTAssertThrowsError(try WorkflowTemplateFile.read(url))
    }

    func testMinimalPortableDefinitionAcceptsAbsentOptionalPlanningFields() throws {
        let data = Data(#"{"format":"taskfold-template","version":1,"name":"Reviewed design checklist","document":{"version":1,"kind":"project","projects":[{"id":"p","name":"Design checklist"}],"sections":[],"tasks":[{"id":"t","title":"Check colour contrast","description":"Review light and dark appearances.","project_id":"p","labels":[],"subtasks":[],"planned_offset":0}]}}"#.utf8)
        let file = try WorkflowTemplateFile(data: data)
        XCTAssertEqual(file.name, "Reviewed design checklist")
        let changes = try file.template.instantiate(account: "recipient", name: "New checklist")
        XCTAssertEqual(changes.filter { $0.table == "tasks" }.count, 1)
        let task = try XCTUnwrap(changes.first { $0.table == "tasks" })
        XCTAssertEqual(task.fields["title"], .string("Check colour contrast"))
        XCTAssertEqual(task.fields["user_id"], .string("recipient"))
        XCTAssertEqual(task.fields["priority"], .number(4))
    }
}

extension ProjectWorkflowsTests {
    private func sharedCaptureContext() throws -> (Snapshot, TeamWorkspaceCache, WorkspaceBinding, UUID, String) {
        let team = "ef260000-0000-4000-8000-000000000001", projectID = "ef260000-0000-4000-8000-000000000002", origin = "https://backend.example"
        let project = Record(["id": .string(projectID), "user_id": .string("ef260000-0000-4000-8000-000000000099"), "name": .string("Shared workshop")])
        var task = Record.task(user: project.string("user_id"), project: projectID)
        task["title"] = .string("Prepare launch"); task["description"] = .string("Authored workflow notes"); task["labels"] = .array([.string("Launch shared")]); task["assigned_to"] = .string(owner)
        task["opaque_future"] = .object(["retain": .bool(true)])
        task["comments"] = .array([.object(["text": .string("Private discussion")])]); task["attachments"] = .array([.object(["url": .string("https://example.invalid/private")])])
        var child = Record.task(user: owner); child["title"] = .string("Prepare outline"); child["labels"] = .array([.string("Outline shared")]); task["subtasks"] = .array([.object(child.fields)])
        let label = Record(["id": .string("Launch shared"), "name": .string("Private catalog name"), "color": .string("#112233")])
        let snapshot = Snapshot(tables: ["projects": [project], "tasks": [task], "labels": [label]])
        let boundary = try TeamWorkspaceBoundary(["workspace_boundary_protocol": .number(1), "account": .string(owner), "native_team_reads_enabled": .bool(true), "setup_paused": .bool(false), "token": .string(String(repeating: "a", count: 64)), "teams": .array([.object(["id": .string(team), "state": .string("active"), "revision": .number(1), "access_revision": .number(1)])]), "projects": .array([.object(["id": .string(projectID), "team_id": .string(team), "role": .string("viewer"), "archived": .bool(false), "can_send_tasks": .bool(false)])])], account: owner, origin: origin)
        return (snapshot, try TeamWorkspaceCache(boundary: boundary, previous: nil, pending: [], tasks: [task]), WorkspaceBinding(account: owner, generation: UUID()), UUID(), origin)
    }
    func testSharedTemplateLabelsArePortableAndNeverResolvedThroughPersonalCatalog() throws {
        let (snapshot, cache, workspace, session, origin) = try sharedCaptureContext()
        let opening = try WorkflowTemplateCapture(kind: .project, sourceID: snapshot.tables["projects"]![0].id, snapshot: snapshot, workspace: workspace, session: session, origin: origin, teamCache: cache)
        XCTAssertTrue(opening.shared)
        let root = opening.template.tasks[0], child = Record(root["subtasks"].list[0].object)
        XCTAssertEqual(root["labels"], .array([.object(["name": .string("Launch shared"), "color": .string("#e31e4b")])]))
        XCTAssertEqual(child["labels"].list[0].object["name"], .string("Outline shared"))
        XCTAssertNil(root.fields["assigned_to"]); XCTAssertNil(root.fields["comments"]); XCTAssertNil(root.fields["attachments"]); XCTAssertNil(root.fields["user_id"])
        var unrelated = snapshot; unrelated.tables["labels"] = []
        XCTAssertNoThrow(try opening.reviewed(snapshot: unrelated, workspace: workspace, session: session, origin: origin, teamCache: cache))
    }
    func testSharedTemplateReviewRetainsFullSourceNotJustCleanDefinition() throws {
        let (snapshot, cache, workspace, session, origin) = try sharedCaptureContext(), id = snapshot.tables["projects"]![0].id
        let opening = try WorkflowTemplateCapture(kind: .project, sourceID: id, snapshot: snapshot, workspace: workspace, session: session, origin: origin, teamCache: cache)
        for field in ["description", "opaque_future", "comments", "assigned_to"] {
            var changed = snapshot; changed.tables["tasks"]![0][field] = .string("newer content")
            XCTAssertThrowsError(try opening.reviewed(snapshot: changed, workspace: workspace, session: session, origin: origin, teamCache: cache), field)
        }
        var unrelated = snapshot; unrelated.tables["tasks"]!.append(Record.task(user: owner))
        XCTAssertNoThrow(try opening.reviewed(snapshot: unrelated, workspace: workspace, session: session, origin: origin, teamCache: cache))
    }
    func testSharedTemplateReviewRefusesAddedDescendantsAndMissingSource() throws {
        let (snapshot, cache, workspace, session, origin) = try sharedCaptureContext(), id = snapshot.tables["projects"]![0].id
        let opening = try WorkflowTemplateCapture(kind: .project, sourceID: id, snapshot: snapshot, workspace: workspace, session: session, origin: origin, teamCache: cache)
        var added = snapshot; var child = project(UUID().uuidString.lowercased(), parent: id); child["name"] = .string("New branch"); added.tables["projects"]!.append(child)
        XCTAssertThrowsError(try opening.reviewed(snapshot: added, workspace: workspace, session: session, origin: origin, teamCache: cache))
        var missing = snapshot; missing.tables["tasks"] = []
        XCTAssertThrowsError(try opening.reviewed(snapshot: missing, workspace: workspace, session: session, origin: origin, teamCache: cache))
    }
    func testSharedTemplateReviewRefusesAccountSessionOriginAndAccessReplacement() throws {
        let (snapshot, cache, workspace, session, origin) = try sharedCaptureContext(), id = snapshot.tables["projects"]![0].id
        let opening = try WorkflowTemplateCapture(kind: .project, sourceID: id, snapshot: snapshot, workspace: workspace, session: session, origin: origin, teamCache: cache)
        XCTAssertThrowsError(try opening.reviewed(snapshot: snapshot, workspace: WorkspaceBinding(account: owner, generation: UUID()), session: session, origin: origin, teamCache: cache))
        XCTAssertThrowsError(try opening.reviewed(snapshot: snapshot, workspace: workspace, session: UUID(), origin: origin, teamCache: cache))
        XCTAssertThrowsError(try opening.reviewed(snapshot: snapshot, workspace: workspace, session: session, origin: "https://another.example", teamCache: cache))
        XCTAssertThrowsError(try opening.reviewed(snapshot: snapshot, workspace: workspace, session: session, origin: origin, teamCache: nil))
        var raw = cache.boundary.raw; raw["token"] = .string(String(repeating: "b", count: 64))
        let changed = try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(raw, account: owner, origin: origin), previous: cache, pending: [], tasks: snapshot.tables["tasks"]!)
        XCTAssertThrowsError(try opening.reviewed(snapshot: snapshot, workspace: workspace, session: session, origin: origin, teamCache: changed))
    }
    func testUnsupportedSharedLabelCannotSilentlyDisappearIntoTemplate() throws {
        let (snapshot, cache, workspace, session, origin) = try sharedCaptureContext(), id = snapshot.tables["projects"]![0].id
        for labels in [JSON.array([.string(UUID().uuidString.lowercased())]), .array([.string("Name\nHidden")]), .object(["future": .bool(true)])] {
            var source = snapshot; source.tables["tasks"]![0]["labels"] = labels
            XCTAssertThrowsError(try WorkflowTemplateCapture(kind: .project, sourceID: id, snapshot: source, workspace: workspace, session: session, origin: origin, teamCache: cache))
            XCTAssertEqual(source.tables["tasks"]![0]["labels"], labels)
        }
    }
    func testSharedTemplateReadDoesNotGrantTeamRunOrRetainHistoryAndOwnership() throws {
        let (snapshot, cache, workspace, session, origin) = try sharedCaptureContext(), id = snapshot.tables["projects"]![0].id
        let opening = try WorkflowTemplateCapture(kind: .project, sourceID: id, snapshot: snapshot, workspace: workspace, session: session, origin: origin, teamCache: cache)
        let first = try opening.template.instantiate(account: owner, name: "Private run"), second = try opening.template.instantiate(account: owner, name: "Another private run")
        XCTAssertTrue(Set(first.map(\.recordID)).isDisjoint(with: second.map(\.recordID)))
        XCTAssertTrue(first.filter { $0.table == "projects" }.allSatisfy { $0.fields["team_id"] == nil && $0.fields["user_id"] == .string(owner) })
        for task in first.filter({ $0.table == "tasks" }) { XCTAssertEqual(task.fields["user_id"], .string(owner)); XCTAssertEqual(task.fields["completed"], .bool(false)); XCTAssertTrue(task.fields["comments"]?.list.isEmpty == true); XCTAssertTrue(task.fields["attachments"]?.list.isEmpty == true) }
    }
}

extension ProjectWorkflowsTests {
    func testSharedTemplatePreservesReadableLegacyLabelLengthWithoutApplyingAdderLimit() throws {
        let (original, cache, workspace, session, origin) = try sharedCaptureContext()
        var source = original; let name = String(repeating: "Long label ", count: 30)
        source.tables["tasks"]![0]["labels"] = .array([.string(name)])
        let capture = try WorkflowTemplateCapture(kind: .project, sourceID: source.tables["projects"]![0].id, snapshot: source, workspace: workspace, session: session, origin: origin, teamCache: cache)
        XCTAssertEqual(capture.template.tasks[0]["labels"].list[0].object["name"], .string(name))
    }
}


extension ProjectWorkflowsTests {
    func editableDefinition() throws -> JSON {
        try WorkflowTemplate(document: .object(["version": .number(1), "kind": .string("task"), "projects": .array([]), "sections": .array([]), "tasks": .array([.object(["id": .string("root"), "title": .string("* Literal context"), "description": .string("Keep full notes"), "priority": .number(2), "duration_minutes": .number(25), "planned_offset": .number(3), "labels": .array([.object(["name": .string("Design")])]), "subtasks": .array([.object(["id": .string("child"), "title": .string("Productive child"), "labels": .array([]), "subtasks": .array([])])])])])])).document
    }
    func testTemplateTypeEditPromotesKnownFormatAndPreservesWork() throws {
        let original = try editableDefinition(), item = try XCTUnwrap(TemplateEditing.tasks(original).first)
        let changed = try TemplateEditing.editingTask(original, item: item, fields: ["is_heading": .bool(true)], headingsEnabled: true)
        XCTAssertEqual(changed.object["version"], .number(2)); XCTAssertEqual(changed.object["capabilities"], .array([.string("task_headings")]))
        let edited = try XCTUnwrap(TemplateEditing.tasks(changed).first)
        XCTAssertEqual(TaskKind(edited.record), .heading)
        for key in item.record.fields.keys { XCTAssertEqual(item.record[key], edited.record[key], key) }
        let runs = try WorkflowTemplate(document: changed).instantiate(account: owner, name: "Run")
        XCTAssertTrue(runs.contains { $0.table == "tasks" && $0.fields["is_heading"] == .bool(true) })
        XCTAssertEqual(original, try editableDefinition())
    }
    func testNestedTemplateHeadingEditAndReturnToTaskKeepV2() throws {
        let original = try editableDefinition(), child = TemplateEditing.tasks(original)[1]
        let changed = try TemplateEditing.editingTask(original, item: child, fields: ["is_heading": .bool(true), "description": .string("Child notes")], headingsEnabled: true)
        let nodes = TemplateEditing.tasks(changed); XCTAssertEqual(TaskKind(nodes[0].record), .task); XCTAssertEqual(TaskKind(nodes[1].record), .heading)
        let back = try TemplateEditing.editingTask(changed, item: nodes[1], fields: ["is_heading": .bool(false)], headingsEnabled: true)
        XCTAssertEqual(back.object["version"], .number(2)); XCTAssertEqual(back.object["capabilities"], .array([.string("task_headings")]))
        XCTAssertEqual(TemplateEditing.tasks(back)[1].record["is_heading"], .bool(false)); XCTAssertEqual(TemplateEditing.tasks(back)[1].record.string("description"), "Child notes")
    }
    func testTemplateTypeOptInDoesNotBlockReadPreservingEdits() throws {
        let original = try editableDefinition(), item = TemplateEditing.tasks(original)[0]
        XCTAssertThrowsError(try TemplateEditing.editingTask(original, item: item, fields: ["is_heading": .bool(true)], headingsEnabled: false))
        let ordinary = try TemplateEditing.editingTask(original, item: item, fields: ["is_heading": .bool(false), "description": .string("Edited")], headingsEnabled: false)
        XCTAssertEqual(ordinary.object["version"], .number(1)); XCTAssertNil(TemplateEditing.tasks(ordinary)[0].record.fields["is_heading"])
        let headed = try TemplateEditing.editingTask(original, item: item, fields: ["is_heading": .bool(true)], headingsEnabled: true)
        let heading = TemplateEditing.tasks(headed)[0]
        XCTAssertThrowsError(try TemplateEditing.editingTask(headed, item: heading, fields: ["is_heading": .bool(false)], headingsEnabled: false))
        let notes = try TemplateEditing.editingTask(headed, item: heading, fields: ["description": .string("Preserved heading")], headingsEnabled: false)
        XCTAssertEqual(TaskKind(TemplateEditing.tasks(notes)[0].record), .heading)
    }
    func testTemplateTypeEditRefusesStaleItemMalformedTypeAndFutureDefinition() throws {
        let original = try editableDefinition(), item = TemplateEditing.tasks(original)[0]
        let newer = try TemplateEditing.changing(original, item: item, fields: ["title": .string("Newer title")])
        XCTAssertThrowsError(try TemplateEditing.editingTask(newer, item: item, fields: ["is_heading": .bool(true)], headingsEnabled: true))
        for value in [JSON.null, .string("true"), .number(1)] { XCTAssertThrowsError(try TemplateEditing.editingTask(original, item: item, fields: ["is_heading": value], headingsEnabled: true)) }
        var future = original.object; future["version"] = .number(9)
        XCTAssertThrowsError(try TemplateEditing.editingTask(.object(future), item: item, fields: ["is_heading": .bool(true)], headingsEnabled: true))
    }
}
