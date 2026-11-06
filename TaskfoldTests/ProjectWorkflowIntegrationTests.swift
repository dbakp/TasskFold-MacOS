import XCTest
@testable import TaskfoldCore

/// Runs Mac create → iOS reuse → Mac receive against one disposable account.
/// Credentials stay in a private local file; checkpoints contain record IDs only.
final class ProjectWorkflowIntegrationTests: XCTestCase {
    @MainActor func testWorkflowCloudHandoff() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TASKFOLD_WORKFLOW_LIVE_FIXTURE"],
              let phase = environment["TASKFOLD_WORKFLOW_LIVE_PHASE"],
              ["create", "reuse", "receive", "nativeReceive"].contains(phase) else {
            throw XCTSkip("Disposable workflow fixture and handoff phase required")
        }
        let url = URL(fileURLWithPath: path)
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0o777) & 0o077, 0)
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        let owner = try XCTUnwrap(fixture["userID"]), email = try XCTUnwrap(fixture["email"])
        guard UUID(uuidString: owner) != nil, email == "taskfold-continuity-" + owner + "@example.invalid" else {
            throw AppFailure(message: "Disposable continuity account required")
        }
        let backend = Backend(configuration: ["URL": try XCTUnwrap(fixture["url"]), "Key": try XCTUnwrap(fixture["key"])],
                              http: URLSession(configuration: .ephemeral), session: nil, persistSession: { _ in })
        let signedIn = try await backend.signIn(email: email, password: try XCTUnwrap(fixture["password"]), signup: false)
        XCTAssertTrue(signedIn); XCTAssertEqual(backend.session?.user.id, owner)
        let tables = ["projects", "sections", "tasks", "labels", "view_orders", WorkflowTemplate.table]
        let checkpointURL = url.appendingPathExtension("checkpoint")
        var checkpoint = phase == "create" ? [:] : try JSONDecoder().decode([String: String].self, from: Data(contentsOf: checkpointURL))
        func fetch() async throws -> Snapshot {
            var snapshot = Snapshot()
            for table in tables { snapshot.tables[table] = try await backend.rows(table) }
            return snapshot
        }
        func upload(_ changes: [Mutation], snapshot: Snapshot) async throws -> Snapshot {
            var durable = snapshot
            for change in changes { durable.apply(change); durable.pending.append(change) }
            // Decode the queue as a restarted client would, then send in stored order.
            durable = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(durable))
            while let change = durable.pending.first {
                let saved = try await backend.send(change, expectedAccount: owner)
                durable.acknowledge(change, saved: saved)
            }
            XCTAssertTrue(durable.pending.isEmpty)
            return durable
        }
        func row(_ snapshot: Snapshot, _ table: String, _ key: String) throws -> Record {
            let id = try XCTUnwrap(checkpoint[key])
            return try XCTUnwrap(snapshot.tables[table]?.first { $0.id == id })
        }
        var snapshot = try await fetch()
        if phase == "create" {
            XCTAssertTrue(snapshot.tables.values.allSatisfy(\.isEmpty), "Use a fresh synthetic account")
            guard snapshot.tables.values.allSatisfy(\.isEmpty) else { return }
            func project(_ name: String, parent: String = "") -> Record {
                Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(owner), "name": .string(name),
                        "parent_id": parent.isEmpty ? .null : .string(parent), "is_archived": .bool(false), "order_index": .number(0)])
            }
            let root = project("Cloud workflow workshop"), child = project("Review studio", parent: root.id)
            let section = Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(owner),
                                  "project_id": .string(child.id), "name": .string("Review"), "order_index": .number(0)])
            var task = Record.task(user: owner, project: child.id)
            task["title"] = .string("Prepare the workflow brief"); task["description"] = .string("Preserve these synthetic instructions.")
            task["section_id"] = .string(section.id); task["due_date"] = .string("2026-11-04"); task["duration_minutes"] = .number(30)
            var changes = [("projects", root), ("projects", child), ("sections", section), ("tasks", task)].map {
                Mutation(table: $0.0, recordID: $0.1.id, method: "POST", fields: $0.1.fields)
            }
            snapshot = try await upload(changes, snapshot: snapshot)
            let template = try WorkflowTemplate.capture(kind: .project, id: root.id, snapshot: snapshot)
            let templateID = UUID().uuidString.lowercased()
            changes = [Mutation(table: WorkflowTemplate.table, recordID: templateID, method: "POST", fields: [
                "id": .string(templateID), "user_id": .string(owner), "name": .string("Cloud launch workflow"), "document": template.document]),
                Mutation(table: "projects", recordID: root.id, method: "PATCH", fields: ["is_archived": .bool(true)])]
            _ = try await upload(changes, snapshot: snapshot)
            checkpoint = ["root": root.id, "child": child.id, "task": task.id, "template": templateID]
        } else if phase == "reuse" {
            let root = try row(snapshot, "projects", "root"), child = try row(snapshot, "projects", "child")
            XCTAssertTrue(root["is_archived"].flag); XCTAssertTrue(child["ancestor_archived"].flag)
            XCTAssertEqual(child.string("parent_id"), root.id)
            XCTAssertTrue(ProjectOrganization.outline(snapshot.tables["projects"] ?? []).isEmpty)
            let savedTemplate = try row(snapshot, WorkflowTemplate.table, "template")
            let template = try WorkflowTemplate(document: savedTemplate["document"])
            let changes = try template.instantiate(account: owner, name: "Reused on iOS", start: Dates.parse("2026-12-01"))
            snapshot = try await upload(changes, snapshot: snapshot)
            let newRoot = try XCTUnwrap(changes.first { $0.table == "projects" && Record($0.fields).string("parent_id").isEmpty })
            let newChild = try XCTUnwrap(changes.first { $0.table == "projects" && Record($0.fields).string("parent_id") == newRoot.recordID })
            let newTask = try XCTUnwrap(changes.first { $0.table == "tasks" })
            XCTAssertNotEqual(newTask.recordID, checkpoint["task"])
            checkpoint["copyRoot"] = newRoot.recordID; checkpoint["copyChild"] = newChild.recordID; checkpoint["copyTask"] = newTask.recordID
            let lines = try MultiLineCapture.preview("- Review handoff\n- Publish workflow p1", account: owner, project: newChild.recordID)
            let bulk = lines.map { Mutation(table: "tasks", recordID: $0.task.id, method: "POST", fields: $0.task.fields) }
            snapshot = try await upload(bulk, snapshot: snapshot)
            checkpoint["bulk0"] = bulk[0].recordID; checkpoint["bulk1"] = bulk[1].recordID
            // Replay after a lost acknowledgement must retain one task per line.
            _ = try await backend.send(bulk[0], expectedAccount: owner)
            _ = try await upload([Mutation(table: "projects", recordID: root.id, method: "PATCH", fields: ["is_archived": .bool(false)])], snapshot: snapshot)
        } else if phase == "nativeReceive" {
            let root = try row(snapshot, "projects", "root"), child = try row(snapshot, "projects", "child")
            XCTAssertFalse(root["is_archived"].flag); XCTAssertFalse(child["ancestor_archived"].flag)
            let original = try row(snapshot, "tasks", "task")
            XCTAssertEqual(original.string("due_date"), "2026-11-04"); XCTAssertFalse(original.completed)
            let copyRoot = try XCTUnwrap(snapshot.tables["projects"]?.first { $0.name == "Native workflow copy" })
            let copyChild = try XCTUnwrap(snapshot.tables["projects"]?.first { $0.string("parent_id") == copyRoot.id })
            let copy = try XCTUnwrap(snapshot.tables["tasks"]?.first { $0.string("project_id") == copyChild.id })
            XCTAssertNotEqual(copy.id, original.id); XCTAssertFalse(copy.completed)
            XCTAssertTrue(copy.string("due_date").isEmpty, "Native template default must clear the source's old date")
            XCTAssertEqual(copy.string("description"), original.string("description"))
            XCTAssertEqual(copy["duration_minutes"], .number(30))
            let batch = snapshot.tables["tasks"]?.filter { $0.string("project_id").isEmpty } ?? []
            XCTAssertEqual(Set(batch.map(\.title)), ["Native handoff first", "Native handoff second"])
            XCTAssertEqual(batch.count, 2); XCTAssertEqual(snapshot.tables["tasks"]?.count, 4)
            XCTAssertEqual(snapshot.tables["projects"]?.count, 4); XCTAssertEqual(snapshot.tables["sections"]?.count, 2)
            XCTAssertEqual(snapshot.tables[WorkflowTemplate.table]?.count, 1)
        } else {
            let root = try row(snapshot, "projects", "root"), child = try row(snapshot, "projects", "child")
            XCTAssertFalse(root["is_archived"].flag); XCTAssertFalse(child["ancestor_archived"].flag)
            let original = try row(snapshot, "tasks", "task"), copy = try row(snapshot, "tasks", "copyTask")
            XCTAssertEqual(original.string("due_date"), "2026-11-04"); XCTAssertFalse(original.completed)
            XCTAssertEqual(copy.string("due_date"), "2026-12-01"); XCTAssertFalse(copy.completed)
            XCTAssertEqual(copy.string("description"), original.string("description")); XCTAssertEqual(copy["duration_minutes"], .number(30))
            XCTAssertEqual(copy.string("project_id"), checkpoint["copyChild"])
            XCTAssertEqual(try row(snapshot, "projects", "copyChild").string("parent_id"), checkpoint["copyRoot"])
            XCTAssertEqual(try row(snapshot, "projects", "copyRoot").name, "Reused on iOS")
            XCTAssertEqual(try row(snapshot, "tasks", "bulk0").title, "Review handoff")
            XCTAssertEqual(try row(snapshot, "tasks", "bulk1").title, "Publish workflow")
            XCTAssertEqual(snapshot.tables["tasks"]?.count, 4); XCTAssertEqual(snapshot.tables["projects"]?.count, 4)
            XCTAssertEqual(snapshot.tables["sections"]?.count, 2); XCTAssertEqual(snapshot.tables[WorkflowTemplate.table]?.count, 1)
            XCTAssertEqual(ProjectOrganization.outline(snapshot.tables["projects"] ?? []).count, 4)
            _ = try WorkflowTemplate(document: row(snapshot, WorkflowTemplate.table, "template")["document"])
        }
        try JSONEncoder().encode(checkpoint).write(to: checkpointURL, options: .atomic)
    }
}

extension ProjectWorkflowIntegrationTests {
    @MainActor func testTwoClientTemplateEditReviewRetryAndDeletedCopyRecovery() async throws {
        guard let path=ProcessInfo.processInfo.environment["TASKFOLD_TEMPLATE_LIVE_FIXTURE"] else { throw XCTSkip("Disposable template account required") }
        let f=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let owner=try XCTUnwrap(f["userID"]),identity=try XCTUnwrap(f["emailIdentity"]),email=try XCTUnwrap(f["email"])
        guard UUID(uuidString:owner) != nil,UUID(uuidString:identity) != nil,email=="taskfold-continuity-"+identity+"@example.invalid" else { throw AppFailure(message:"Synthetic account only") }
        let config=["URL":try XCTUnwrap(f["url"]),"Key":try XCTUnwrap(f["key"])]
        func client()->Backend { Backend(configuration:config,http:URLSession(configuration:.ephemeral),session:nil,persistSession:{_ in}) }
        let a=client(),b=client()
        for api in [a,b] { let signed=try await api.signIn(email:email,password:try XCTUnwrap(f["password"]),signup:false);XCTAssertTrue(signed);XCTAssertEqual(api.session?.user.id,owner) }
        func send(_ api:Backend,_ change:Mutation) async throws ->Record { let value=try await api.send(change);return try XCTUnwrap(value) }
        let id=UUID().uuidString.lowercased()
        let document:JSON = .object(["version":.number(1),"kind":.string("task"),"projects":.array([]),"sections":.array([]),"tasks":.array([.object(["id":.string("source"),"title":.string("Original reusable task"),"description":.string("Original reusable notes"),"labels":.array([]),"subtasks":.array([])])])])
        let original=try await send(a,Mutation(table:WorkflowTemplate.table,recordID:id,method:"POST",fields:["id":.string(id),"user_id":.string(owner),"name":.string("Synthetic template"),"document":document],insertOnly:true))
        var run=try WorkflowTemplate(document:document).instantiate(account:owner,name:"",run:UUID())
        run[0].insertOnly=true
        let createdTask=try await send(a,run[0])
        var templateIDs=[id]
        func current(_ api:Backend,_ target:String) async throws ->Record? { try await api.rows(WorkflowTemplate.table).first{$0.id==target} }
        func patch(_ row:Record,_ fields:[String:JSON])->Mutation { Mutation(table:WorkflowTemplate.table,recordID:row.id,method:"PATCH",fields:fields,baseline:row.fields) }
        func cleanup() async throws {
            for target in templateIDs { if let row=try await current(a,target) { _ = try await a.send(Mutation(table:WorkflowTemplate.table,recordID:target,method:"DELETE",fields:[:],baseline:row.fields)) } }
            if let row=try await a.rows("tasks").first(where:{$0.id==createdTask.id}) { _ = try await a.send(Mutation(table:"tasks",recordID:row.id,method:"DELETE",fields:[:],baseline:row.fields)) }
        }
        do {
            _ = try await b.send(patch(original,["name":.string("Second device name")]))
            let item=TemplateEditing.tasks(document)[0]
            let local=try TemplateEditing.changing(document,item:item,fields:["description":.string("First device notes")])
            let independent=try await send(a,patch(original,["document":local]))
            XCTAssertEqual(independent.name,"Second device name")
            let remoteDocument=try TemplateEditing.changing(local,item:item,fields:["description":.string("Second device notes")])
            let remote=try await send(b,patch(independent,["document":remoteDocument]))
            let desired=try TemplateEditing.changing(local,item:item,fields:["description":.string("Reviewed local notes")])
            let edit=patch(independent,["document":desired])
            do { _ = try await a.send(edit);XCTFail("Overlapping definitions silently merged") } catch { XCTAssertTrue(error.localizedDescription.contains("TASKFOLD_CONFLICT:"),error.localizedDescription) }
            let queue=Snapshot(tables:[WorkflowTemplate.table:[independent]],pending:[edit])
            let reviewed=try XCTUnwrap(SyncConflict(mutation:edit,remote:remote).resolving(queue,keepLocal:true))
            let durable=try JSONDecoder().decode(Snapshot.self,from:JSONEncoder().encode(reviewed))
            let saved=try await send(a,durable.pending[0]);_ = try await a.send(durable.pending[0])
            XCTAssertEqual(saved["document"],desired)
            let received=try await current(b,id);XCTAssertEqual(received?["document"],desired)
            let oldRun=try await b.rows("tasks").first{$0.id==createdTask.id};XCTAssertEqual(oldRun?.string("description"),"Original reusable notes")
            // Undo/Redo restoration is an insert-only creation until explicitly reviewed.
            let restoreID=UUID().uuidString.lowercased();templateIDs.append(restoreID)
            let restore=Mutation(table:WorkflowTemplate.table,recordID:restoreID,method:"POST",fields:["id":.string(restoreID),"user_id":.string(owner),"name":.string("Restore fixture"),"document":document])
            let restoreBase=try await send(a,restore);_ = try await a.send(restore)
            let changedRestore=try await send(b,patch(restoreBase,["name":.string("Changed by second client"),"document":desired]))
            do { _ = try await a.send(restore);XCTFail("A stale restore overwrote another device") } catch { XCTAssertTrue(error.localizedDescription.contains("TASKFOLD_CONFLICT:"),error.localizedDescription) }
            let restoreQueue=Snapshot(tables:[WorkflowTemplate.table:[changedRestore]],pending:[restore])
            let restoreReview=try XCTUnwrap(SyncConflict(mutation:restore,remote:changedRestore).resolving(restoreQueue,keepLocal:true))
            let restored=try await send(a,restoreReview.pending[0]);_ = try await a.send(restoreReview.pending[0])
            XCTAssertEqual(restored.name,"Restore fixture");XCTAssertEqual(restored["document"],document)

            let deletion=Mutation(table:WorkflowTemplate.table,recordID:id,method:"DELETE",fields:[:],baseline:independent.fields)
            do { _ = try await b.send(deletion);XCTFail("Stale deletion accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("TASKFOLD_CONFLICT:"),error.localizedDescription) }
            _ = try await b.send(Mutation(table:WorkflowTemplate.table,recordID:id,method:"DELETE",fields:[:],baseline:saved.fields))
            let late=patch(saved,["name":.string("Recovered template")])
            do { _ = try await a.send(late);XCTFail("Removed template resurrected") } catch { XCTAssertTrue(error.localizedDescription.contains("TASKFOLD_CONFLICT:"),error.localizedDescription) }
            let recovered=try XCTUnwrap(SyncConflict(mutation:late,remote:Record(["id":.string(id)])).resolving(Snapshot(tables:[:],pending:[late]),keepLocal:true))
            let copyID=recovered.pending[0].recordID;templateIDs.append(copyID);XCTAssertNotEqual(copyID,id)
            _ = try await a.send(recovered.pending[0]);let copy=try await current(b,copyID);XCTAssertEqual(copy?.name,"Recovered template");XCTAssertEqual(copy?["document"],desired)
            let removed=try await current(b,id);XCTAssertNil(removed)
            try await cleanup()
        } catch { try? await cleanup();throw error }
    }
}

extension ProjectWorkflowIntegrationTests {
    @MainActor func testTwoClientGoalsReviewAndRecordedCompletionCorrection() async throws {
        guard let path=ProcessInfo.processInfo.environment["TASKFOLD_GOALS_LIVE_FIXTURE"] else { throw XCTSkip("Disposable goal account required") }
        let permissions=try FileManager.default.attributesOfItem(atPath:path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0o777)&0o077,0)
        let f=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let owner=try XCTUnwrap(f["userID"]),identity=try XCTUnwrap(f["emailIdentity"]),email=try XCTUnwrap(f["email"])
        guard UUID(uuidString:owner) != nil,UUID(uuidString:identity) != nil,email=="taskfold-continuity-"+identity+"@example.invalid" else { throw AppFailure(message:"Synthetic account only") }
        let config=["URL":try XCTUnwrap(f["url"]),"Key":try XCTUnwrap(f["key"])]
        func client()->Backend { Backend(configuration:config,http:URLSession(configuration:.ephemeral),session:nil,persistSession:{_ in}) }
        let a=client(),b=client()
        for api in [a,b] { let signed=try await api.signIn(email:email,password:try XCTUnwrap(f["password"]),signup:false);XCTAssertTrue(signed);XCTAssertEqual(api.session?.user.id,owner) }
        func current(_ api:Backend) async throws ->Record? { try await api.rows("view_preferences").first{$0.id==ProductivityGoals.recordID} }
        func send(_ api:Backend,_ change:Mutation) async throws ->Record { let row=try await api.send(change,expectedAccount:owner);return try XCTUnwrap(row) }
        let before=try await current(a),initialTasks=try await a.rows("tasks")
        guard before==nil,initialTasks.isEmpty else { throw AppFailure(message:"Fresh synthetic goals and tasks required") }
        let taskID=UUID().uuidString.lowercased()
        func cleanup() async throws {
            if let task=try await a.rows("tasks").first(where:{$0.id==taskID}) { _ = try await a.send(Mutation(table:"tasks",recordID:task.id,method:"DELETE",fields:[:],baseline:task.fields)) }
            if let row=try await current(a) { _ = try await a.send(Mutation(table:"view_preferences",recordID:row.id,method:"DELETE",fields:[:],baseline:row.fields)) }
        }
        func source(_ api:Backend) async throws ->Snapshot {
            var result=Snapshot();for table in ["view_preferences",TaskActivity.table,TaskActivity.epochTable] {result.tables[table]=try await api.rows(table)};return result
        }
        do {
            var goals=try ProductivityGoals();goals.dailyTarget=5;goals.weeklyTarget=20;goals.timeZone="UTC"
            let creation=try ProductivityGoalEdit.command(goals.document,previous:nil,account:owner)
            let original=try await send(a,creation);_ = try await send(a,creation)
            var remoteGoals=goals;remoteGoals.dailyTarget=6
            var remoteDocument=remoteGoals.document.object;remoteDocument["metadata"] = .string("Keep independent synced metadata")
            _ = try await send(b,ProductivityGoalEdit.command(.object(remoteDocument),previous:original,account:owner))
            _ = try await b.send(Mutation(table:"view_preferences",recordID:ProductivityGoals.recordID,method:"PATCH",fields:["sort_by":.string("title")]))
            goals.weeklyTarget=25
            let stale=try ProductivityGoalEdit.command(goals.document,previous:original,account:owner)
            do{_ = try await a.send(stale);XCTFail("Overlapping goal was replaced without review")}catch{XCTAssertTrue(error.localizedDescription.contains("TASKFOLD_CONFLICT:"))}
            let fetched=try await current(a);let remote=try XCTUnwrap(fetched);var queued=Snapshot(tables:["view_preferences":[original]],pending:[stale]);queued.apply(stale)
            queued=try JSONDecoder().decode(Snapshot.self,from:JSONEncoder().encode(queued))
            let reviewed=try XCTUnwrap(SyncConflict(mutation:stale,remote:remote).resolving(queued,keepLocal:true))
            let retry=try XCTUnwrap(reviewed.pending.first),saved=try await send(a,retry)
            XCTAssertEqual(saved[ProductivityGoals.field].object["metadata"],.string("Keep independent synced metadata"));XCTAssertEqual(saved.string("sort_by"),"title")
            _ = try await send(a,retry)
            var final=try ProductivityGoals(document:saved[ProductivityGoals.field]);final.timeZone="Europe/Copenhagen";final.weekStart=1;final.weeklyTarget=30
            let latest=try await send(b,ProductivityGoalEdit.command(final.document,previous:saved,account:owner))
            do{_ = try await a.send(retry);XCTFail("Old retry overwrote a newer goal choice")}catch{XCTAssertTrue(error.localizedDescription.contains("TASKFOLD_CONFLICT:"))}
            let synced=try XCTUnwrap(SyncConflict(mutation:retry,remote:latest).resolving(Snapshot(pending:[retry]),keepLocal:false))
            XCTAssertTrue(synced.pending.isEmpty);XCTAssertEqual(ProductivityGoals.row(synced,account:owner)?[ProductivityGoals.field],latest[ProductivityGoals.field])
            var task=Record.task(user:owner);task["id"] = .string(taskID);task["title"] = .string("Synthetic Insights completion proof")
            let created=try await send(a,Mutation(table:"tasks",recordID:taskID,method:"POST",fields:task.fields,insertOnly:true))
            let completed=try await send(a,Mutation(table:"tasks",recordID:taskID,method:"PATCH",fields:["completed":.bool(true),"completed_at":.string(TaskActivity.stamp(Date()))],baseline:created.fields))
            let first=try await source(a),second=try await source(b),instant=Date().addingTimeInterval(2)
            let one=try ProductivityGoals(document:try XCTUnwrap(ProductivityGoals.row(first,account:owner))[ProductivityGoals.field]),two=try ProductivityGoals(document:try XCTUnwrap(ProductivityGoals.row(second,account:owner))[ProductivityGoals.field])
            XCTAssertEqual(one.document,two.document)
            let r1=InsightsReading(account:owner,activity:first.tables[TaskActivity.table]!,epoch:first.tables[TaskActivity.epochTable]!,goals:one,now:instant)
            let r2=InsightsReading(account:owner,activity:second.tables[TaskActivity.table]!,epoch:second.tables[TaskActivity.epochTable]!,goals:two,now:instant)
            XCTAssertTrue(r1.reliable);XCTAssertTrue(r2.reliable);XCTAssertEqual(r1.today,1);XCTAssertEqual(r1.week,1);XCTAssertEqual(r1.days,r2.days)
            _ = try await send(b,Mutation(table:"tasks",recordID:taskID,method:"PATCH",fields:["completed":.bool(false),"completed_at":.null],baseline:completed.fields))
            for api in [a,b] { let snapshot=try await source(api);let reading=InsightsReading(account:owner,activity:snapshot.tables[TaskActivity.table]!,epoch:snapshot.tables[TaskActivity.epochTable]!,goals:one,now:Date().addingTimeInterval(2));XCTAssertTrue(reading.reliable);XCTAssertEqual(reading.today,0);XCTAssertEqual(reading.week,0) }
            try await cleanup()
        } catch { try? await cleanup();throw error }
    }
}

extension ProjectWorkflowIntegrationTests {
    @MainActor func testTwoClientMonthlyDatesPersistCompleteAndReopen() async throws {
        guard let path=ProcessInfo.processInfo.environment["TASKFOLD_MONTHLY_LIVE_FIXTURE"] else {throw XCTSkip("Disposable monthly-date account required")}
        let permissions=try FileManager.default.attributesOfItem(atPath:path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0o777)&0o077,0)
        let f=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let owner=try XCTUnwrap(f["userID"]),identity=try XCTUnwrap(f["emailIdentity"]),email=try XCTUnwrap(f["email"])
        guard UUID(uuidString:owner) != nil,UUID(uuidString:identity) != nil,email=="taskfold-continuity-"+identity+"@example.invalid" else {throw AppFailure(message:"Synthetic account only")}
        let configuration=["URL":try XCTUnwrap(f["url"]),"Key":try XCTUnwrap(f["key"])]
        func client()->Backend {Backend(configuration:configuration,http:URLSession(configuration:.ephemeral),session:nil,persistSession:{_ in})}
        let a=client(),b=client()
        for api in [a,b] {let signed=try await api.signIn(email:email,password:try XCTUnwrap(f["password"]),signup:false);XCTAssertTrue(signed);XCTAssertEqual(api.session?.user.id,owner)}
        let initial=try await a.rows("tasks");guard initial.isEmpty else {throw AppFailure(message:"Fresh synthetic workspace required")}
        let root=UUID().uuidString.lowercased(),next=TaskCompletion.successorID(parent:root,day:"2027-01-15")
        func cleanup() async throws {for id in [next,root] {if let row=try await a.rows("tasks").first(where:{$0.id==id}) {_ = try await a.send(Mutation(table:"tasks",recordID:id,method:"DELETE",fields:[:],baseline:row.fields))}}}
        do {
            var task=Record.task(user:owner);task["id"] = .string(root);task["title"] = .string("Synthetic month-date continuity proof")
            task["due_date"] = .string("2027-01-01");task["due_time"] = .string("09:00");task["time_zone"] = .string("Europe/Copenhagen");task["scheduled_at"] = .string("2027-01-01T08:00:00Z")
            task["is_recurring"] = .bool(true);task["recurrence_pattern"] = .object(["type":.string("monthly"),"interval":.number(1),"daysOfMonth":.array([.number(1),.number(15),.number(31)]),"count":.number(3),"opaque_metadata":.object(["keep":.bool(true)])])
            _ = try await a.send(Mutation(table:"tasks",recordID:root,method:"POST",fields:task.fields,insertOnly:true),expectedAccount:owner)
            let fetched=try await b.rows("tasks"),remote=try XCTUnwrap(fetched.first{$0.id==root});XCTAssertEqual(remote["recurrence_pattern"],task["recurrence_pattern"])
            let restored=try JSONDecoder().decode(Snapshot.self,from:JSONEncoder().encode(Snapshot(tables:["tasks":[remote]])))
            let instant=try XCTUnwrap(TaskPlanning.instant("2027-01-01T12:00:00Z")),reloaded=try XCTUnwrap(restored.tables["tasks"]?.first)
            XCTAssertEqual(Recurrence.preview(reloaded,completion:instant),Recurrence.preview(remote,completion:instant))
            let changes=TaskCompletion.complete(reloaded,tasks:fetched,at:instant);XCTAssertEqual(changes.count,2)
            for change in changes {_ = try await b.send(change,expectedAccount:owner)}
            let first=try await a.rows("tasks"),second=try await b.rows("tasks");XCTAssertEqual(first.count,2);XCTAssertEqual(Set(first.map(\.id)),Set(second.map(\.id)))
            let completed=try XCTUnwrap(first.first{$0.id==root}),successor=try XCTUnwrap(first.first{$0.id==next});XCTAssertTrue(completed.completed);XCTAssertFalse(successor.completed)
            XCTAssertEqual(successor.string("due_date"),"2027-01-15");XCTAssertEqual(TaskPlanning.instant(successor.string("scheduled_at")),TaskPlanning.instant("2027-01-15T08:00:00Z"))
            var expected=task["recurrence_pattern"].object;expected["count"] = .number(2);XCTAssertEqual(successor["recurrence_pattern"],.object(expected))
            _ = try await a.send(try XCTUnwrap(TaskCompletion.toggle(completed,tasks:first,at:instant).first),expectedAccount:owner)
            for api in [a,b] {let rows=try await api.rows("tasks");XCTAssertEqual(rows.count,2);XCTAssertEqual(rows.filter{$0.id==root && !$0.completed}.count,1);XCTAssertEqual(rows.filter{$0.id==next}.count,1);XCTAssertEqual(rows.first{$0.id==root}?["recurrence_pattern"],task["recurrence_pattern"])}
            try await cleanup()
        } catch {try? await cleanup();throw error}
    }
}
