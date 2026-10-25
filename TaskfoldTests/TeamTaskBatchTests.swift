import XCTest
@testable import TaskfoldCore

private let batchOrigin="https://backend.example"
private final class BatchHTTP:URLProtocol,@unchecked Sendable {
    static var handler:((URLRequest,BatchHTTP)->Void)?
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func stopLoading(){}
    override func startLoading(){Self.handler?(request,self)}
    func finish(_ data:Data,status:Int=200){client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json","Content-Length":String(data.count)])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)}
}
private final class BatchReplyGate:@unchecked Sendable {
    private let lock=NSLock();private var peer:BatchHTTP?
    func hold(_ value:BatchHTTP){lock.lock();peer=value;lock.unlock()}
    func release(_ value:Data){lock.lock();let saved=peer;peer=nil;lock.unlock();saved?.finish(value)}
}
final class TeamTaskBatchTests:XCTestCase {
    private func fixture(_ op:String) throws -> (Mutation,TeamTaskBatch,[String:JSON]) {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"team-task-batch-v1",withExtension:"json",subdirectory:"Fixtures")),f=try JSONDecoder().decode([String:JSON].self,from:Data(contentsOf:url))
        let body=f[op]!.object["body"]!.object
        let items=body["items"]!.list.map { value -> Mutation in
            let v=value.object,scope=TeamTaskEditScope(account:f["account"]!.text,origin:batchOrigin,team:body["team_id"]!.text,project:v["project_id"]!.text,restoreRequest:v["restore_from"].flatMap{UUID(uuidString:$0.text)})
            return Mutation(id:UUID(uuidString:v["request_id"]!.text)!,table:"tasks",recordID:v["task_id"]!.text,method:op=="delete" ? "DELETE":"POST",fields:op=="delete" ? [:]:v["record"]!.object,baseline:op=="delete" ? v["record"]!.object:nil,insertOnly:op=="restore" ? true:nil,teamTaskScope:scope)
        }.sorted{$0.recordID<$1.recordID}
        let batch=TeamTaskBatch(account:f["account"]!.text,origin:batchOrigin,team:body["team_id"]!.text,operation:TeamTaskBatch.Operation(rawValue:op)!,restores:body["restores"].flatMap{UUID(uuidString:$0.text)},items:items)
        return(TeamTaskBatch.header(batch,id:UUID(uuidString:body["request_id"]!.text)!),batch,f[op]!.object["reply"]!.object)
    }
    private func snapshot(_ batch:TeamTaskBatch) -> Snapshot {
        let projects=Set(batch.items.compactMap{$0.teamTaskScope?.project}).map{Record(["id":.string($0)])}
        return Snapshot(tables:["projects":projects,"tasks":batch.operation == .delete ? batch.items.map{Record($0.baseline!)}:[]])
    }
    func testActualSQLAcknowledgementsAndPersistence() throws {
        for op in ["delete","restore"] {let(header,batch,reply)=try fixture(op);XCTAssertNoThrow(try batch.confirm(reply,for:header));XCTAssertEqual(try JSONDecoder().decode(Mutation.self,from:JSONEncoder().encode(header)),header)}
    }
    func testPreparationCapturesAllBeforeRemovingParents() throws {
        let(_,batch,_)=try fixture("delete");var raw=batch.items;for i in raw.indices{raw[i].baseline=nil}
        let prepared=try TeamTaskBatch.preparing(raw,snapshot:snapshot(batch));let header=try XCTUnwrap(prepared.first)
        XCTAssertEqual(prepared.count,1);XCTAssertEqual(header.teamTaskBatch?.items.compactMap{ $0.baseline?["recurrence_parent_id"] },batch.items.compactMap{$0.baseline?["recurrence_parent_id"]})
        XCTAssertEqual(header.teamTaskBatch?.items.map(\.id),batch.items.map(\.id))
    }
    func testWholeSelectionLocalProjectionAndUndoRetainRelations() throws {
        let(header,batch,_)=try fixture("delete");var current=snapshot(batch)
        let before=current;let history=EditHistory(changes:[header],snapshot:before);current.apply(header)
        XCTAssertEqual(current.tables["tasks"],[])
        let inverse=TeamTaskBatch.historyAction(try XCTUnwrap(history.undo.first)),restore=try XCTUnwrap(inverse.teamTaskBatch)
        XCTAssertEqual(restore.restores,header.id);XCTAssertEqual(Set(restore.items.compactMap{$0.teamTaskScope?.restoreRequest}),Set(batch.items.map(\.id)))
        current.apply(inverse);XCTAssertEqual(Set(current.tables["tasks"]!.map(\.id)),Set(before.tables["tasks"]!.map(\.id)))
        for value in current.tables["tasks"]! {XCTAssertNotEqual(value["task_generation"],before.tables["tasks"]!.first{$0.id==value.id}?["task_generation"]);XCTAssertEqual(value["recurrence_parent_id"],before.tables["tasks"]!.first{$0.id==value.id}?["recurrence_parent_id"])}
        XCTAssertNoThrow(try restore.body(for:inverse))
    }
    func testRedoReferencesActualNewDeletionNonces() throws {
        let(header,batch,_)=try fixture("delete"),start=snapshot(batch)
        let old=EditHistory(changes:[header],snapshot:start);var current=start;current.apply(header)
        let undo=TeamTaskBatch.historyAction(try XCTUnwrap(old.undo.first)),applied=EditHistory(changes:[undo],snapshot:current);current.apply(undo)
        let redo=TeamTaskBatch.historyAction(try XCTUnwrap(applied.undo.first)),redoBatch=try XCTUnwrap(redo.teamTaskBatch)
        XCTAssertEqual(redoBatch.operation,.delete);XCTAssertNotEqual(redo.id,header.id)
        let redoHistory=EditHistory(changes:[redo],snapshot:current)
        XCTAssertEqual(Set(redoHistory.undo.first!.teamTaskBatch!.items.compactMap{$0.teamTaskScope?.restoreRequest}),Set(redoBatch.items.map(\.id)))
    }
    func testMalformedMixedAndNestedGroupsCannotSend() throws {
        let(header,batch,_)=try fixture("delete")
        var mixed=batch.items;mixed[0].teamTaskScope=nil;XCTAssertThrowsError(try TeamTaskBatch.preparing(mixed,snapshot:snapshot(batch)))
        var nested=batch;nested.items[0].teamTaskBatch=batch;XCTAssertThrowsError(try nested.body(for:TeamTaskBatch.header(nested)))
        var duplicate=batch;duplicate.items.append(duplicate.items[0]);XCTAssertThrowsError(try duplicate.body(for:TeamTaskBatch.header(duplicate)))
        var invalid=header;invalid.recordID=UUID().uuidString.lowercased();XCTAssertThrowsError(try batch.body(for:invalid))
        var foreign=batch;foreign.items[0].teamTaskScope=TeamTaskEditScope(account:UUID().uuidString.lowercased(),origin:batchOrigin,team:batch.team,project:foreign.items[0].teamTaskScope!.project)
        XCTAssertThrowsError(try foreign.body(for:TeamTaskBatch.header(foreign)))
    }
    func testOneRecreatedTaskPreventsPartialLocalProjection() throws {
        let(header,batch,_)=try fixture("delete");var value=snapshot(batch);value.tables["tasks"]![0]["task_generation"] = .string(UUID().uuidString.lowercased());let before=value
        value.apply(header);XCTAssertEqual(value,before)
        value=snapshot(batch);value.tables["projects"]=[];let unavailable=value;value.apply(header);XCTAssertEqual(value,unavailable)
    }
    func testAcknowledgementCannotDropOnlyPartOfSelection() throws {
        let(header,batch,reply)=try fixture("delete")
        for key in ["account","team_id","request_id","operation"] {var wrong=reply;wrong[key] = .string(UUID().uuidString.lowercased());XCTAssertThrowsError(try batch.confirm(wrong,for:header))}
        var partial=reply;partial["items"] = .array(Array(reply["items"]!.list.dropLast()));XCTAssertThrowsError(try batch.confirm(partial,for:header))
        var stale=reply;var rows=stale["items"]!.list;var row=rows[0].object;row["task_generation"] = .string(UUID().uuidString.lowercased());rows[0] = .object(row);stale["items"] = .array(rows);XCTAssertThrowsError(try batch.confirm(stale,for:header))
        var value=snapshot(batch);value.pending=[header];value.apply(header);value.acknowledge(header,saved:nil);XCTAssertTrue(value.pending.isEmpty)
    }
    func testOldQueueDecodeAndIncompleteHeaderCannotCreateFakeTask() throws {
        let(header,batch,_)=try fixture("delete")
        let ordinary=Mutation(table:"tasks",recordID:batch.items[0].recordID,method:"PATCH",fields:["title":.string("Ordinary edit")])
        XCTAssertNil(try JSONDecoder().decode(Mutation.self,from:JSONEncoder().encode(ordinary)).teamTaskBatch)
        var malformed=header;malformed.teamTaskBatch=nil
        var value=snapshot(batch);let before=value;value.apply(malformed);XCTAssertEqual(value,before)
    }
    @MainActor func testLateBatchReplyCannotReachAnotherSession() async throws {
        let(header,batch,reply)=try fixture("delete"),config=URLSessionConfiguration.ephemeral;config.protocolClasses=[BatchHTTP.self]
        let session=try JSONDecoder().decode(Session.self,from:Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(batch.account)\"}}".utf8))
        let api=Backend(configuration:["URL":batchOrigin,"Key":"synthetic-public"],http:URLSession(configuration:config),session:session,persistSession:{_ in})
        let gate=BatchReplyGate(),started=expectation(description:"Batch held")
        BatchHTTP.handler={_,peer in gate.hold(peer);started.fulfill()};defer{BatchHTTP.handler=nil}
        let pending=Task{@MainActor in try await api.send(header)}
        await fulfillment(of:[started],timeout:3)
        var other=session;other.user.id=UUID().uuidString.lowercased();try await api.accept(other)
        gate.release(try JSONEncoder().encode(reply))
        do{_=try await pending.value;XCTFail("Old batch acknowledged in another session")}catch{XCTAssertTrue(error is CancellationError)}
    }
    @MainActor func testSenderUsesOneBoundedRequestAndNoSingleTaskFallback() async throws {
        let(header,batch,reply)=try fixture("delete"),config=URLSessionConfiguration.ephemeral;config.protocolClasses=[BatchHTTP.self]
        let session=try JSONDecoder().decode(Session.self,from:Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(batch.account)\"}}".utf8))
        let api=Backend(configuration:["URL":batchOrigin,"Key":"synthetic-public"],http:URLSession(configuration:config),session:session,persistSession:{_ in});var count=0
        BatchHTTP.handler={request,peer in count += 1;XCTAssertEqual(request.url?.path,"/rest/v1/rpc/taskfold_team_task_batch");XCTAssertEqual(request.value(forHTTPHeaderField:"Cache-Control"),"no-store");XCTAssertFalse(request.httpShouldHandleCookies);XCTAssertEqual(request.timeoutInterval,25);peer.finish(try! JSONEncoder().encode(reply))};defer{BatchHTTP.handler=nil}
        let saved=try await api.send(header);XCTAssertNil(saved);XCTAssertEqual(count,1)
        BatchHTTP.handler={_,peer in count += 1;peer.finish(Data("{\"code\":\"PT409\",\"message\":\"private-details\"}".utf8),status:409)}
        do{_=try await api.send(header);XCTFail("Conflict acknowledged")}catch{XCTAssertFalse(error.localizedDescription.contains("private-details"));XCTAssertTrue(error.localizedDescription.contains("selection"))};XCTAssertEqual(count,2)
        do{_=try await api.send(header,expectedAccount:UUID().uuidString.lowercased());XCTFail("Foreign account sent")}catch{XCTAssertTrue(error is CancellationError)};XCTAssertEqual(count,2)
    }
}

extension TeamTaskBatchTests {
    private func planningFixture() throws -> ([String: JSON], Mutation, TeamTaskBatch) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-planning-batch-v1", withExtension: "json", subdirectory: "Fixtures"))
        let f = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url)), body = f["body"]!.object
        let items = body["items"]!.list.map { value -> Mutation in
            let v = value.object, scope = TeamTaskEditScope(account: f["account"]!.text, origin: batchOrigin, team: body["team_id"]!.text, project: v["project_id"]!.text)
            return Mutation(id: UUID(uuidString: v["request_id"]!.text)!, table: "tasks", recordID: v["task_id"]!.text, method: "PATCH", fields: v["changes"]!.object, baseline: v["record"]!.object, teamTaskScope: scope)
        }
        let batch = TeamTaskBatch(account: f["account"]!.text, origin: batchOrigin, team: body["team_id"]!.text, operation: .edit, restores: nil, items: items)
        return (f, TeamTaskBatch.header(batch, id: UUID(uuidString: body["request_id"]!.text)!), batch)
    }
    private func planningSnapshot(_ batch: TeamTaskBatch) -> Snapshot {
        Snapshot(tables: ["projects": Set(batch.items.map { $0.teamTaskScope!.project }).sorted().map { Record(["id": .string($0)]) }, "tasks": batch.items.map { Record($0.baseline!) }])
    }
    private func planningCache(_ batch: TeamTaskBatch) throws -> TeamWorkspaceCache {
        let projects = Set(batch.items.map { $0.teamTaskScope!.project }).sorted().map { id in JSON.object(["id": .string(id), "team_id": .string(batch.team), "role": .string("editor"), "archived": .bool(false), "can_send_tasks": .bool(true)]) }
        let raw: [String: JSON] = ["workspace_boundary_protocol": .number(1), "account": .string(batch.account), "native_team_reads_enabled": .bool(true), "setup_paused": .bool(false), "token": .string(String(repeating: "a", count: 64)), "projects": .array(projects), "teams": .array([.object(["id": .string(batch.team), "state": .string("active"), "revision": .number(1), "access_revision": .number(1)])])]
        return try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(raw, account: batch.account, origin: batch.origin), previous: nil, pending: [])
    }
    func testPlanningDateChoiceKeepsAlreadyCorrectMembersAndExplicitRemoval() throws {
        let (_, _, batch) = try planningFixture(); var task = Record(batch.items[0].baseline!)
        task["due_date"] = .string("2026-11-12")
        XCTAssertEqual(TeamTaskBatch.dateFields(task: task, day: "2026-11-12"), ["due_date": .string("2026-11-12")])
        XCTAssertEqual(TeamTaskBatch.dateFields(task: task, day: nil), ["due_date": .null, "due_time": .null, "time_zone": .null, "scheduled_at": .null])
        XCTAssertEqual(TeamTaskBatch.dateFields(task: task, day: "invalid"), [:])
    }
    func testPlanningDateRemovalSupportsSavedRowsWithAbsentOptionalClockFields() throws {
        let (_, _, batch) = try planningFixture(), cache = try planningCache(batch), workspace = WorkspaceBinding(account: batch.account, generation: UUID()), session = UUID()
        let records = batch.items.map { item -> Record in
            var row = Record(item.baseline!)
            for key in ["due_time", "time_zone", "scheduled_at"] { row.fields.removeValue(forKey: key) }
            return row
        }
        let drafts = try records.map { try TeamTaskEditorDraft(source: $0, workspace: workspace, session: session, cache: cache, enabled: true) }
        let changes = Dictionary(uniqueKeysWithValues: records.map { ($0.id, TeamTaskBatch.dateFields(task: $0, day: nil)) })
        let selection = try TeamTaskPlanningSelection(drafts: drafts, changes: changes)
        let command = try selection.mutation(current: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }), workspace: workspace, session: session, cache: cache, enabled: true)
        let parsed = try command.teamTaskBatch!.body(for: command)
        for item in parsed["items"]!.list { XCTAssertNil(item.object["record"]!.object["due_time"]) }
        var projected = Snapshot(tables: ["tasks": records, "projects": cache.boundary.projects.keys.map { Record(["id": .string($0)]) }])
        let original = projected
        XCTAssertTrue(command.teamTaskBatch!.apply(to: &projected, header: command))
        let inverse = try command.teamTaskBatch!.inverse(of: command, snapshot: original)
        XCTAssertTrue(inverse.teamTaskBatch!.apply(to: &projected, header: inverse))
        for row in projected.tables["tasks"]! {
            let old = records.first { $0.id == row.id }!
            for key in Set(row.fields.keys).union(old.fields.keys) { XCTAssertEqual(row[key], old[key], key) }
        }
    }
    func testPlanningSQLCommandReceiptAndPrivatePersistence() throws {
        let (f, header, batch) = try planningFixture()
        XCTAssertEqual(try batch.body(for: header), f["body"]!.object)
        XCTAssertNoThrow(try batch.confirm(f["reply"]!.object, for: header))
        XCTAssertEqual(try JSONDecoder().decode(Mutation.self, from: JSONEncoder().encode(header)), header)
        var replay = f["reply"]!.object; replay["replayed"] = .bool(true)
        XCTAssertNoThrow(try batch.confirm(replay, for: header))
    }
    func testPlanningProjectionAndUndoKeepWholeRowsAndFreshRequestIdentities() throws {
        let (_, header, batch) = try planningFixture(); var current = planningSnapshot(batch)
        let original = current, undo = try batch.inverse(of: header, snapshot: original)
        XCTAssertTrue(batch.apply(to: &current, header: header))
        for row in current.tables["tasks"]! { XCTAssertEqual(row["priority"], .number(2)); XCTAssertEqual(row["deadline_date"], .string("2026-11-12")); XCTAssertEqual(row["description"], .string("Private original note")) }
        let inverse = try XCTUnwrap(undo.teamTaskBatch); XCTAssertEqual(inverse.operation, .edit); XCTAssertNil(inverse.restores)
        XCTAssertTrue(inverse.apply(to: &current, header: undo)); XCTAssertEqual(current.tables["tasks"], original.tables["tasks"])
        let redo = try inverse.inverse(of: undo, snapshot: current), repeated = try XCTUnwrap(redo.teamTaskBatch)
        XCTAssertTrue(Set(batch.items.map(\.id)).isDisjoint(with: repeated.items.map(\.id)))
        XCTAssertTrue(repeated.apply(to: &current, header: redo)); XCTAssertEqual(current.tables["tasks"]?.first?["priority"], .number(2))
    }
    func testPlanningProjectionRejectsMissingRecreatedAndChangedMembersWithoutPartialEffect() throws {
        let (_, header, batch) = try planningFixture()
        for variant in 0..<3 {
            var current = planningSnapshot(batch)
            if variant == 0 { current.tables["tasks"]!.removeLast() }
            else { current.tables["tasks"]![1][variant == 1 ? "task_generation" : "description"] = .string(variant == 1 ? UUID().uuidString.lowercased() : "Newer note") }
            let before = current; XCTAssertFalse(batch.apply(to: &current, header: header)); XCTAssertEqual(current, before)
        }
    }
    func testPlanningBodyRejectsUnsupportedFieldsSmallSelectionAndRestoreAuthority() throws {
        let (_, _, original) = try planningFixture()
        for variant in 0..<4 {
            var items = original.items
            if variant == 0 { items[0].fields = ["completed": .bool(true)] }
            if variant == 1 { items.removeAll() }
            if variant == 2 { items[0].baseline?.removeValue(forKey: "id") }
            let batch = TeamTaskBatch(account: original.account, origin: original.origin, team: original.team, operation: .edit, restores: variant == 3 ? UUID() : nil, items: items)
            XCTAssertThrowsError(try batch.body(for: TeamTaskBatch.header(batch)))
        }
        XCTAssertThrowsError(try TeamTaskBatch.preparing(original.items, snapshot: planningSnapshot(original)))
    }
    func testPlanningReceiptRequiresCompleteExactMemberAcknowledgement() throws {
        let (f, header, batch) = try planningFixture()
        for key in ["account", "team_id", "request_id", "operation"] {
            var reply = f["reply"]!.object; reply[key] = .string("wrong")
            XCTAssertThrowsError(try batch.confirm(reply, for: header))
        }
        var reply = f["reply"]!.object; reply["items"] = .array(Array(reply["items"]!.list.dropLast()))
        XCTAssertThrowsError(try batch.confirm(reply, for: header))
    }
    func testPlanningOpeningFreezesRowsWorkspaceSessionAndAccessBeforeReview() throws {
        let (_, _, batch) = try planningFixture(), cache = try planningCache(batch), workspace = WorkspaceBinding(account: batch.account, generation: UUID()), session = UUID()
        let records = batch.items.map { Record($0.baseline!) }, drafts = try records.map { try TeamTaskEditorDraft(source: $0, workspace: workspace, session: session, cache: cache, enabled: true) }
        let selection = try TeamTaskPlanningSelection(drafts: drafts, changes: Dictionary(uniqueKeysWithValues: batch.items.map { ($0.recordID, $0.fields) }))
        let current = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let command = try selection.mutation(current: current, workspace: workspace, session: session, cache: cache, enabled: true)
        XCTAssertEqual(command, try selection.mutation(current: current, workspace: workspace, session: session, cache: cache, enabled: true))
        XCTAssertThrowsError(try selection.mutation(current: current, workspace: workspace, session: UUID(), cache: cache, enabled: true))
        XCTAssertThrowsError(try selection.mutation(current: current, workspace: WorkspaceBinding(account: batch.account, generation: UUID()), session: session, cache: cache, enabled: true))
        XCTAssertThrowsError(try selection.mutation(current: current, workspace: workspace, session: session, cache: cache, enabled: false))
        var changed = current; changed[records[0].id]?["description"] = .string("Newer note")
        XCTAssertThrowsError(try selection.mutation(current: changed, workspace: workspace, session: session, cache: cache, enabled: true))
        XCTAssertThrowsError(try selection.mutation(current: [:], workspace: workspace, session: session, cache: cache, enabled: true))
        XCTAssertThrowsError(try TeamTaskPlanningSelection(drafts: [drafts[0], drafts[0]], changes: [records[0].id: ["priority": .number(1)]]))
    }
    @MainActor func testPlanningSenderUsesOneRPCAndPreservesWholeIntentOnConflict() async throws {
        let (f, header, batch) = try planningFixture(), config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BatchHTTP.self]
        let session = try JSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(batch.account)\"}}".utf8))
        let api = Backend(configuration: ["URL": batchOrigin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in }); var calls = 0
        BatchHTTP.handler = { request, peer in
            calls += 1; XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_team_task_batch"); XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertFalse(request.httpShouldHandleCookies); peer.finish(try! JSONEncoder().encode(f["reply"]!.object))
        }; defer { BatchHTTP.handler = nil }
        let saved = try await api.send(header); XCTAssertNil(saved); XCTAssertEqual(calls, 1)
        BatchHTTP.handler = { _, peer in calls += 1; peer.finish(Data("{\"code\":\"PT409\",\"message\":\"private-details\"}".utf8), status: 409) }
        do { _ = try await api.send(header); XCTFail("Conflict acknowledged") } catch { XCTAssertFalse(error.localizedDescription.contains("private-details")) }
        XCTAssertEqual(calls, 2); XCTAssertEqual(try batch.body(for: header), f["body"]!.object)
    }
}

extension TeamTaskBatchTests {
    func testBulkPlanningChoicesValidateBoundariesAndKeepTheirOwnFields() throws {
        for value in ["1", "25", "10080", " 30 "] {
            let fields = try BulkPlanningField.estimate.fields(day: "2026-11-12", minutes: value, clearing: false)
            XCTAssertEqual(Set(fields.keys), ["duration_minutes"])
        }
        for value in ["", "0", "-1", "10081", "1.5", "+25", "2e3", String(repeating: "9", count: 100), "２５"] {
            XCTAssertThrowsError(try BulkPlanningField.estimate.fields(day: nil, minutes: value, clearing: false))
        }
        XCTAssertEqual(try BulkPlanningField.estimate.fields(day: nil, minutes: "invalid", clearing: true), ["duration_minutes": .null])
        XCTAssertEqual(try BulkPlanningField.deadline.fields(day: "2026-11-12", minutes: "invalid", clearing: false), ["deadline_date": .string("2026-11-12")])
        XCTAssertEqual(try BulkPlanningField.deadline.fields(day: "invalid", minutes: "", clearing: true), ["deadline_date": .null])
        XCTAssertThrowsError(try BulkPlanningField.deadline.fields(day: "2026-02-30", minutes: "", clearing: false))
        XCTAssertThrowsError(try BulkPlanningField.deadline.fields(day: nil, minutes: "", clearing: false))
    }
    func testPlanningPickerKeepsOpeningRowsWhenChoicesAreMadeLater() throws {
        let (_, _, batch) = try planningFixture(), cache = try planningCache(batch), workspace = WorkspaceBinding(account: batch.account, generation: UUID()), session = UUID()
        let records = batch.items.map { Record($0.baseline!) }, current = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let drafts = try records.map { try TeamTaskEditorDraft(source: $0, workspace: workspace, session: session, cache: cache, enabled: true) }
        let admission = try TeamTaskPlanningAdmission(drafts: drafts)
        XCTAssertTrue(admission.permits(current: current, workspace: workspace, session: session, cache: cache, enabled: true))
        let choice = try admission.selecting(BulkPlanningField.estimate.fields(day: nil, minutes: "30", clearing: false))
        let command = try choice.mutation(current: current, workspace: workspace, session: session, cache: cache, enabled: true)
        XCTAssertEqual(command.teamTaskBatch?.items.count, records.count)
        for item in command.teamTaskBatch!.items { XCTAssertEqual(item.baseline, current[item.recordID]?.fields); XCTAssertEqual(item.fields, ["duration_minutes": .number(30)]) }
        var changed = current; changed[records[0].id]?["description"] = .string("A newer saved note")
        XCTAssertFalse(admission.permits(current: changed, workspace: workspace, session: session, cache: cache, enabled: true))
        XCTAssertThrowsError(try choice.mutation(current: changed, workspace: workspace, session: session, cache: cache, enabled: true))
        XCTAssertFalse(admission.permits(current: current, workspace: workspace, session: UUID(), cache: cache, enabled: true))
        XCTAssertThrowsError(try TeamTaskPlanningAdmission(drafts: [drafts[0], drafts[0]]))
    }
    func testPlanningPickerClearsOnlyChosenOptionalFieldAndRetainsOtherPlans() throws {
        let (_, _, original) = try planningFixture(), cache = try planningCache(original), workspace = WorkspaceBinding(account: original.account, generation: UUID()), session = UUID()
        let records = original.items.map { item -> Record in
            var row = Record(item.baseline!); row["due_date"] = .string("2026-11-05"); row["due_time"] = .string("09:30"); row["time_zone"] = .string("UTC"); row["scheduled_at"] = .string("2026-11-05T09:30:00.000Z"); return row
        }
        let current = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }), admission = try TeamTaskPlanningAdmission(drafts: records.map { try TeamTaskEditorDraft(source: $0, workspace: workspace, session: session, cache: cache, enabled: true) })
        for field in [BulkPlanningField.deadline, .estimate] {
            let selection = try admission.selecting(field.fields(day: nil, minutes: "", clearing: true))
            let command = try selection.mutation(current: current, workspace: workspace, session: session, cache: cache, enabled: true)
            var snapshot = Snapshot(tables: ["tasks": records, "projects": cache.boundary.projects.keys.map { Record(["id": .string($0)]) }])
            XCTAssertTrue(command.teamTaskBatch!.apply(to: &snapshot, header: command))
            for row in snapshot.tables["tasks"]! {
                let before = current[row.id]!
                for key in Set(row.fields.keys).union(before.fields.keys) where key != field.key { XCTAssertEqual(row[key], before[key], key) }
                XCTAssertEqual(row[field.key], .null)
            }
        }
    }
}

extension TeamTaskBatchTests {
    func testAssignmentBatchPreservesAllMembersAndUndoRestoresDistinctOriginalRecipients() throws {
        let (_, _, original) = try planningFixture(), cache = try planningCache(original), workspace = WorkspaceBinding(account: original.account, generation: UUID()), session = UUID()
        let target = UUID().uuidString.lowercased()
        let records = original.items.enumerated().map { offset, item -> Record in
            var row = Record(item.baseline!); if offset == 0 { row.fields.removeValue(forKey: "assigned_to") } else { row["assigned_to"] = .string(target) }; return row
        }
        let before = Snapshot(tables: ["tasks": records, "projects": cache.boundary.projects.keys.map { Record(["id": .string($0)]) }])
        let admission = try TeamTaskPlanningAdmission(drafts: records.map { try TeamTaskEditorDraft(source: $0, workspace: workspace, session: session, cache: cache, enabled: true) })
        let selection = try admission.selecting(["assigned_to": .string(target)])
        let header = try selection.mutation(current: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }), workspace: workspace, session: session, cache: cache, enabled: true)
        let batch = try XCTUnwrap(header.teamTaskBatch); XCTAssertEqual(batch.items.count, records.count)
        for item in batch.items { XCTAssertEqual(item.baseline, records.first { $0.id == item.recordID }?.fields) }
        XCTAssertEqual(try JSONDecoder().decode(Mutation.self, from: JSONEncoder().encode(header)), header)
        var current = before; XCTAssertTrue(batch.apply(to: &current, header: header))
        for row in current.tables["tasks"]! { var expected = records.first { $0.id == row.id }!; expected["assigned_to"] = .string(target); XCTAssertEqual(row, expected) }
        let undo = try batch.inverse(of: header, snapshot: before), inverse = try XCTUnwrap(undo.teamTaskBatch)
        XCTAssertTrue(inverse.apply(to: &current, header: undo)); XCTAssertEqual(current.tables["tasks"], records.map { source in var row = source; if row.fields["assigned_to"] == nil { row["assigned_to"] = .null }; return row })
        XCTAssertTrue(Set(batch.items.map(\.id)).isDisjoint(with: inverse.items.map(\.id)))
    }
}

extension TeamTaskBatchTests {
    private func labelFixture(_ labels: [[JSON]]) throws -> (TeamTaskPlanningAdmission, TeamWorkspaceCache, WorkspaceBinding, UUID, [Record]) {
        let (_, _, batch) = try planningFixture(), cache = try planningCache(batch)
        let workspace = WorkspaceBinding(account: batch.account, generation: UUID()), session = UUID()
        let records = batch.items.enumerated().map { index, item in var row = Record(item.baseline!); row["labels"] = .array(labels[index]); return row }
        return (try TeamTaskPlanningAdmission(drafts: records.map { try TeamTaskEditorDraft(source: $0, workspace: workspace, session: session, cache: cache, enabled: true) }), cache, workspace, session, records)
    }
    func testBulkLabelsAddPreservesEachSetAndAlreadyCorrectMembers() throws {
        let opaque = UUID().uuidString.lowercased()
        let (admission, cache, workspace, session, rows) = try labelFixture([[.string("Design"),.string(opaque)], [.string("design"),.string("Ship")]])
        let changes = try TeamTaskBulkLabels.changes(records: rows, action: .add, input: " Ship ")
        XCTAssertEqual(changes[rows[0].id], ["labels": .array([.string("Design"),.string(opaque),.string("Ship")])])
        XCTAssertEqual(changes[rows[1].id], ["labels": rows[1]["labels"]])
        let choice = try TeamTaskPlanningSelection(drafts: admission.drafts, changes: changes), current = Dictionary(uniqueKeysWithValues: rows.map { ($0.id,$0) })
        let command = try choice.mutation(current: current, workspace: workspace, session: session, cache: cache, enabled: true)
        XCTAssertEqual(command.teamTaskBatch?.items.count, 2)
        XCTAssertEqual(command, try choice.mutation(current: current, workspace: workspace, session: session, cache: cache, enabled: true))
        XCTAssertEqual(try JSONDecoder().decode(Mutation.self,from:JSONEncoder().encode(command)),command)
    }
    func testBulkLabelsRemoveIsExactAndClearIsExplicit() throws {
        let (_, _, _, _, rows) = try labelFixture([[.string("Design"),.string("design"),.string("Design")],[.string(" Design "),.string("Keep")]])
        let removed = try TeamTaskBulkLabels.changes(records: rows, action: .remove, input: "Design")
        XCTAssertEqual(removed[rows[0].id]?["labels"],.array([.string("design")]))
        XCTAssertEqual(removed[rows[1].id]?["labels"],rows[1]["labels"])
        let spaced = try TeamTaskBulkLabels.changes(records: rows, action: .remove, input: " Design ")
        XCTAssertEqual(spaced[rows[0].id]?["labels"], rows[0]["labels"])
        XCTAssertEqual(spaced[rows[1].id]?["labels"], .array([.string("Keep")]))
        let legacyName = String(repeating: "x", count: 101)
        var legacy = rows; legacy[0]["labels"] = .array([.string(legacyName)])
        XCTAssertEqual(try TeamTaskBulkLabels.changes(records: legacy, action: .remove, input: legacyName)[rows[0].id]?["labels"], .array([]))
        XCTAssertTrue(TeamTaskBulkLabels.suggestions(records: legacy, action: .remove).contains(legacyName))
        XCTAssertFalse(TeamTaskBulkLabels.suggestions(records: legacy).contains(legacyName))
        let cleared = try TeamTaskBulkLabels.changes(records: rows, action: .clear, input: "ignored invalid\ninput")
        XCTAssertTrue(cleared.values.allSatisfy { $0 == ["labels": .array([])] })
    }
    func testBulkLabelsUndoRestoresEachOriginalSetAndProtectsLaterChanges() throws {
        let (admission, cache, workspace, session, rows) = try labelFixture([[.string("One")],[]])
        let selection = try TeamTaskPlanningSelection(drafts: admission.drafts, changes: TeamTaskBulkLabels.changes(records: rows, action: .add, input: "Ship"))
        let current = Dictionary(uniqueKeysWithValues: rows.map { ($0.id,$0) }), command = try selection.mutation(current: current,workspace: workspace,session: session,cache: cache,enabled: true), batch = try XCTUnwrap(command.teamTaskBatch)
        let before = Snapshot(tables:["tasks":rows,"projects":cache.boundary.projects.keys.map { Record(["id":.string($0)]) }]); var saved = before
        XCTAssertTrue(batch.apply(to:&saved,header:command))
        for row in saved.tables["tasks"]! { var expected = current[row.id]!; expected["labels"] = selection.changes[row.id]!["labels"]!; XCTAssertEqual(row,expected) }
        let undo = try batch.inverse(of:command,snapshot:before), inverse = try XCTUnwrap(undo.teamTaskBatch)
        var newer = saved; newer.tables["tasks"]![1]["description"] = .string("Later note")
        let preserved = newer; XCTAssertFalse(inverse.apply(to:&newer,header:undo)); XCTAssertEqual(newer.tables,preserved.tables)
        XCTAssertTrue(inverse.apply(to:&saved,header:undo)); XCTAssertEqual(saved.tables["tasks"],rows)
        let redo = TeamTaskBatch.historyAction(command); XCTAssertNotEqual(redo.id,command.id)
        XCTAssertTrue(Set(redo.teamTaskBatch!.items.map(\.id)).isDisjoint(with: batch.items.map(\.id)))
        XCTAssertTrue(redo.teamTaskBatch!.apply(to:&saved,header:redo))
    }
    func testBulkLabelsRejectUnsupportedRowsAndInvalidNameBeforeReview() throws {
        let (_, _, _, _, rows) = try labelFixture([[],[]])
        for name in ["", "\n", "Name\nHidden", String(repeating:"x",count:101), UUID().uuidString, "Hidden\u{202E}name"] {
            XCTAssertThrowsError(try TeamTaskBulkLabels.changes(records:rows,action:.add,input:name))
        }
        for value: JSON in [.null,.array([.object(["id":.string("future")])]),.array([.string("")]),.array([.string(String(repeating:"é",count:513))]) ] {
            var bad=rows; bad[1]["labels"]=value
            for action in TeamTaskLabelAction.allCases { XCTAssertThrowsError(try TeamTaskBulkLabels.changes(records:bad,action:action,input:"Ship")) }
        }
        XCTAssertThrowsError(try TeamTaskBulkLabels.changes(records:[rows[0],rows[0]],action:.add,input:"Ship"))
    }
    func testBulkLabelsCapacityDoesNotRejectAnAlreadyCorrectFullTask() throws {
        let full=(0..<256).map { JSON.string("Label \($0)") }
        let (_, _, _, _, rows)=try labelFixture([full,[]])
        XCTAssertNoThrow(try TeamTaskBulkLabels.changes(records:rows,action:.add,input:"Label 0"))
        XCTAssertThrowsError(try TeamTaskBulkLabels.changes(records:rows,action:.add,input:"New"))
        XCTAssertNoThrow(try TeamTaskBulkLabels.changes(records:rows,action:.remove,input:"Label 0"))
    }
    func testBulkLabelsSuggestionsUseOnlyReadableSelectedValues() throws {
        let opaque=UUID().uuidString.lowercased(),(_,_,_,_,rows)=try labelFixture([[.string("Design"),.string(opaque),.string("Name\nHidden")],[.string("design"),.string("Design")]])
        XCTAssertEqual(Set(TeamTaskBulkLabels.suggestions(records:rows)),["Design","design"])
    }
}
