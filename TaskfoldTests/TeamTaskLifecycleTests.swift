import XCTest
@testable import TaskfoldCore

private let lifeOrigin = "https://backend.example"
private final class TeamLifeHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, TeamLifeHTTP) -> Void)?
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var value=request
        if value.httpBody == nil, let stream=value.httpBodyStream {
            stream.open();defer{stream.close()};var data=Data(),buffer=[UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable { let count=stream.read(&buffer,maxLength:buffer.count);guard count>0 else{break};data.append(contentsOf:buffer.prefix(count)) };value.httpBody=data
        }
        Self.handler?(value,self)
    }
    func finish(_ data:Data,status:Int=200) {
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json","Content-Length":String(data.count)])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
}
final class TeamTaskLifecycleTests: XCTestCase {
    private func fixture(_ action:String) throws -> (Mutation,TeamTaskEditScope,[String:JSON]) {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"team-task-lifecycle-v1",withExtension:"json",subdirectory:"Fixtures"))
        let all=try JSONDecoder().decode([String:JSON].self,from:Data(contentsOf:url)),part=try XCTUnwrap(all[action]?.object),body=try XCTUnwrap(part["body"]?.object)
        let scope=TeamTaskEditScope(account:all["account"]!.text,origin:lifeOrigin,team:body["team_id"]!.text,project:body["project_id"]!.text,restoreRequest:body["restore_from"].flatMap{UUID(uuidString:$0.text)},parentGeneration:body["parent_generation"]?.text)
        let change=Mutation(id:try XCTUnwrap(UUID(uuidString:body["request_id"]!.text)),table:"tasks",recordID:body["task_id"]!.text,method:action=="delete" ? "DELETE":"POST",fields:action=="delete" ? [:]:body["record"]!.object,baseline:action=="delete" ? body["record"]!.object:nil,insertOnly:action=="delete" ? nil:true,teamTaskScope:scope)
        XCTAssertEqual(try scope.lifecycleBody(for:change),body)
        return(change,scope,part["reply"]!.object)
    }
    @MainActor private func backend(_ account:String) throws -> Backend {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[TeamLifeHTTP.self]
        let session=try JSONDecoder().decode(Session.self,from:Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(account)\"}}".utf8))
        return Backend(configuration:["URL":lifeOrigin,"Key":"synthetic-public"],http:URLSession(configuration:config),session:session,persistSession:{_ in})
    }
    func testActualSQLCreateDeleteRestoreContracts() throws {
        for action in ["create","delete","restore"] {
            let(change,scope,reply)=try fixture(action)
            let saved=try scope.lifecycleSaved(reply,for:change)
            XCTAssertEqual(saved == nil,action=="delete")
            XCTAssertEqual(try scope.lifecycleAction(for:change),action)
            XCTAssertEqual(try JSONDecoder().decode(Mutation.self,from:JSONEncoder().encode(change)),change)
        }
    }
    func testCreatorContextGenerationAndCreateOnlyRemainExplicit() throws {
        let(original,scope,_)=try fixture("create")
        var change=original;change.insertOnly=false;XCTAssertThrowsError(try scope.lifecycleBody(for:change))
        change=original;change.fields["user_id"] = .string(UUID().uuidString.lowercased());XCTAssertThrowsError(try scope.lifecycleBody(for:change))
        for field in ["id","project_id","task_generation"] {change=original;change.fields[field] = .string(UUID().uuidString.lowercased());if field=="task_generation"{change.fields[field] = .null};XCTAssertThrowsError(try scope.lifecycleBody(for:change))}
        let(deletion,deleteScope,reply)=try fixture("delete");let saved=try deleteScope.lifecycleSaved(reply,for:deletion);XCTAssertNil(saved)
        XCTAssertNotEqual(deletion.baseline?["user_id"],.string(deleteScope.account))
    }
    func testReceiptCannotConfirmWrongNonceWorkspaceOrOperation() throws {
        for action in ["create","delete","restore"] {
            let(change,scope,reply)=try fixture(action)
            for field in ["account","team_id","project_id","task_id","request_id","task_generation","operation"] {var wrong=reply;wrong[field] = .string(UUID().uuidString.lowercased());XCTAssertThrowsError(try scope.lifecycleSaved(wrong,for:change))}
            var missing=reply;missing.removeValue(forKey:"unavailable");XCTAssertThrowsError(try scope.lifecycleSaved(missing,for:change))
        }
    }
    func testUnavailableCreateRetryAcknowledgesWithoutRecreatingTask() throws {
        let(change,scope,reply)=try fixture("create");var unavailable=reply;unavailable["task"] = .null;unavailable["unavailable"] = .bool(true)
        XCTAssertThrowsError(try scope.lifecycleSaved(unavailable,for:change))
        unavailable["replayed"] = .bool(true);XCTAssertNil(try scope.lifecycleSaved(unavailable,for:change))
        var snapshot=Snapshot();snapshot.pending=[change];snapshot.acknowledge(change,saved:try scope.lifecycleSaved(unavailable,for:change));XCTAssertTrue(snapshot.pending.isEmpty)
    }
    func testUndoCarriesExactAcknowledgedDeletionReceipt() throws {
        let(change,scope,_)=try fixture("delete"),old=Record(change.baseline!)
        var snapshot=Snapshot();snapshot.tables=["tasks":[old]]
        let deletion=TeamTaskEditScope.historyAction(change)
        let history=EditHistory(changes:[deletion],snapshot:snapshot)
        let inverse=try XCTUnwrap(history.undo.first)
        XCTAssertEqual(inverse.teamTaskScope?.restoreRequest,deletion.id);XCTAssertNotEqual(deletion.id,change.id)
        let restored=TaskGeneration.restoring(TeamTaskEditScope.historyAction(inverse),existing:nil)
        let restoreScope=try XCTUnwrap(restored.teamTaskScope),body=try restoreScope.lifecycleBody(for:restored)
        XCTAssertEqual(body["restore_from"],.string(deletion.id.uuidString.lowercased()))
        XCTAssertNotEqual(body["task_generation"],change.baseline?["task_generation"])
        XCTAssertEqual(restored.fields["user_id"],old["user_id"]);XCTAssertEqual(restoreScope.account,scope.account)
    }
    func testScopedDeleteRetainsOccurrencesAndBlocksObsoleteIncarnation() throws {
        let(change,scope,_)=try fixture("delete"),old=Record(change.baseline!)
        let child=Record(["id":.string(UUID().uuidString.lowercased()),"title":.string("Keep occurrence"),"project_id":.string(scope.project),"task_generation":.string(UUID().uuidString.lowercased()),"recurrence_parent_id":.string(change.recordID)])
        var snapshot=Snapshot();snapshot.tables=["tasks":[old,child]];snapshot.apply(change)
        XCTAssertEqual(snapshot.tables["tasks"]?.count,1);XCTAssertEqual(snapshot.tables["tasks"]?.first?["recurrence_parent_id"],.null)
        var recreated=old;recreated["task_generation"] = .string(UUID().uuidString.lowercased());snapshot.tables=["tasks":[recreated,child]];snapshot.apply(change)
        XCTAssertEqual(snapshot.tables["tasks"],[recreated,child])
    }
    func testCaptureAndParentIdentityNeverBindToLaterWorkspaceState() throws {
        let(create,scope,_)=try fixture("create");XCTAssertNoThrow(try scope.capturing(create,existing:nil))
        XCTAssertThrowsError(try scope.capturing(create,existing:Record(create.fields)))
        var repeatChild=create;repeatChild.fields["recurrence_parent_id"] = .string(UUID().uuidString.lowercased())
        XCTAssertThrowsError(try scope.lifecycleBody(for:repeatChild))
        var parentScope=scope;parentScope.parentGeneration=UUID().uuidString.lowercased()
        XCTAssertNoThrow(try parentScope.lifecycleBody(for:repeatChild))
        let(deletion,deleteScope,_)=try fixture("delete");var wrong=Record(deletion.baseline!);wrong["project_id"] = .string(UUID().uuidString.lowercased())
        XCTAssertThrowsError(try deleteScope.capturing(deletion,existing:wrong))
    }
    func testLinkedDeleteBatchIsPreparedAtomically() throws {
        let(change,scope,_) = try fixture("delete"); let parent = Record(change.baseline!)
        var child = parent; child["id"] = .string(UUID().uuidString.lowercased()); child["recurrence_parent_id"] = .string(parent.id)
        let childChange = Mutation(table:"tasks",recordID:child.id,method:"DELETE",fields:[:],baseline:child.fields,teamTaskScope:scope)
        let snapshot = Snapshot(tables:["tasks":[parent,child]])
        let grouped=try TeamTaskBatch.preparing([change,childChange],snapshot:snapshot)
        XCTAssertEqual(grouped.count,1);XCTAssertEqual(grouped.first?.teamTaskBatch?.items.count,2)
        XCTAssertEqual(try TeamTaskBatch.preparing([change],snapshot:snapshot),[change])
    }
    @MainActor func testLegacyTeamDenialRequiresReviewWithoutAcknowledging() async throws {
        let(original,scope,_) = try fixture("delete"), api = try backend(scope.account)
        var change = original; change.teamTaskScope = nil
        TeamLifeHTTP.handler = { request,peer in
            XCTAssertEqual(request.url?.path,"/rest/v1/rpc/taskfold_delete_task")
            peer.finish(Data("{\"code\":\"PT409\",\"message\":\"private-details\"}".utf8),status:409)
        };defer{TeamLifeHTTP.handler=nil}
        do { _ = try await api.send(change);XCTFail("Legacy deletion acknowledged") }
        catch { XCTAssertTrue(error is TeamTaskReviewRequired);XCTAssertFalse(error.localizedDescription.contains("private-details")) }
    }
    @MainActor func testSenderUsesLifecycleEndpointAndNeverLegacyFallback() async throws {
        defer{TeamLifeHTTP.handler=nil}
        for action in ["create","delete","restore"] {
            let(change,scope,reply)=try fixture(action),api=try backend(scope.account);var calls=0
            TeamLifeHTTP.handler={request,peer in calls += 1;XCTAssertEqual(request.url?.path,"/rest/v1/rpc/taskfold_team_task_lifecycle");XCTAssertEqual(request.httpMethod,"POST");XCTAssertEqual(request.value(forHTTPHeaderField:"Cache-Control"),"no-store");XCTAssertFalse(request.httpShouldHandleCookies);XCTAssertEqual(request.timeoutInterval,25)
                let sent=try! JSONDecoder().decode([String:JSON].self,from:request.httpBody!);XCTAssertEqual(sent["_action"],.string(action));XCTAssertEqual(sent["_body"],.object(try! scope.lifecycleBody(for:change)));peer.finish(try! JSONEncoder().encode(reply))}
            _=try await api.send(change);_=try await api.send(change);XCTAssertEqual(calls,2)
            TeamLifeHTTP.handler={_,peer in calls += 1;peer.finish(Data("{\"code\":\"42501\",\"message\":\"private-details\"}".utf8),status:403)}
            do{_=try await api.send(change);XCTFail("Denied action acknowledged")}catch{XCTAssertFalse(error.localizedDescription.contains("private-details"))};XCTAssertEqual(calls,3)
        }
    }
}


final class TeamTaskTypeLifecycleTests: XCTestCase {
    let account = UUID().uuidString.lowercased(), project = UUID().uuidString.lowercased(), team = UUID().uuidString.lowercased()
    func scope(authoring: Bool = true, transport: Bool = true, restore: UUID? = nil) -> TeamTaskEditScope {
        TeamTaskEditScope(account: account, origin: "https://synthetic.example", team: team, project: project, restoreRequest: restore, taskTypesProtocol: authoring ? 1 : nil, taskTypeLifecycleProtocol: transport ? 1 : nil)
    }
    func row() -> Record {
        var task = Record.task(user: account, project: project); task["title"] = .string("Design workshop")
        task["task_generation"] = .string(UUID().uuidString.lowercased()); task["completion_version"] = .number(0); return task
    }
    func change(_ row: Record, deleting: Bool = false, scope: TeamTaskEditScope) -> Mutation {
        Mutation(table: "tasks", recordID: row.id, method: deleting ? "DELETE" : "POST", fields: deleting ? [:] : row.fields, baseline: deleting ? row.fields : nil, insertOnly: deleting ? nil : true, teamTaskScope: scope)
    }
    func testHeadingCreationNeedsBothCapabilitiesAndRetainsLiteralData() throws {
        var task = try TaskKind.setting(row(), heading: true); task["description"] = .string("Full notes"); task["opaque"] = .object(["kept": .bool(true)])
        let active = scope(), command = change(task, scope: active), body = try active.lifecycleBody(for: command)
        XCTAssertEqual(body["task_type_lifecycle_protocol"], .number(1)); XCTAssertEqual(body["record"], .object(task.fields))
        XCTAssertThrowsError(try scope(authoring: false).lifecycleBody(for: command))
        XCTAssertThrowsError(try scope(transport: false).lifecycleBody(for: command))
    }
    func testKnownHeadingDeletionAndRestoreDoNotNeedNewAuthoring() throws {
        let task = try TaskKind.setting(row(), heading: true), paused = scope(authoring: false)
        let deletion = change(task, deleting: true, scope: paused)
        XCTAssertEqual(try paused.lifecycleBody(for: deletion)["record"], .object(task.fields))
        let recovering = scope(authoring: false, restore: deletion.id); var restored = task; restored["task_generation"] = .string(UUID().uuidString.lowercased())
        let body = try recovering.lifecycleBody(for: change(restored, scope: recovering))
        XCTAssertEqual(body["restore_from"], .string(deletion.id.uuidString.lowercased())); XCTAssertEqual(body["record"]?.object["is_heading"], .bool(true))
        XCTAssertThrowsError(try scope(authoring: false, transport: false).lifecycleBody(for: deletion))
    }
    func testNestedHeadingCreationNeedsAuthoringAndPreservesOrdinaryDescendants() throws {
        var task = row(); task["subtasks"] = .array([.object(["id": .string("heading"), "title": .string("Plan"), "is_heading": .bool(true), "completed": .bool(false), "subtasks": .array([.object(["id": .string("work"), "title": .string("Prepare"), "completed": .bool(false)])])])])
        let active = scope(), command = try active.capturing(change(task, scope: active), existing: nil)
        XCTAssertEqual(try active.lifecycleBody(for: command)["record"]?.object["subtasks"], command.fields["subtasks"])
        XCTAssertThrowsError(try scope(authoring: false).lifecycleBody(for: command))
        XCTAssertEqual(command.fields["subtasks"]?.list[0].object["taskfold_completion_v1"]?.object["version"], .number(0))
    }
    func testOrdinaryNullTypeUsesTransportWithoutAuthoringAndLegacyBodyStaysCompatible() throws {
        let plain = row(), legacy = scope(authoring: false, transport: false)
        XCTAssertNil(try legacy.lifecycleBody(for: change(plain, scope: legacy))["task_type_lifecycle_protocol"])
        var typed = plain; typed["is_heading"] = .null
        let supported = scope(authoring: false)
        XCTAssertEqual(try supported.lifecycleBody(for: change(typed, scope: supported))["task_type_lifecycle_protocol"], .number(1))
        XCTAssertThrowsError(try legacy.lifecycleBody(for: change(typed, scope: legacy)))
    }
    func testCompletedUnknownAndInvalidNestedTypesCannotBeCreated() throws {
        let active = scope(); var task = row(); task["is_heading"] = .bool(true); task["completed"] = .bool(true)
        XCTAssertThrowsError(try active.lifecycleBody(for: change(task, scope: active)))
        task["completed"] = .bool(false); task["is_heading"] = .string("future")
        XCTAssertThrowsError(try active.lifecycleBody(for: change(task, scope: active)))
        task["is_heading"] = .bool(false); task["subtasks"] = .array([.object(["id": .string("child"), "is_heading": .bool(true), "completed": .bool(true)])])
        XCTAssertThrowsError(try active.lifecycleBody(for: change(task, scope: active)))
    }
    func testTypedReceiptAndDurableCommandRetainProtocol() throws {
        var task = try TaskKind.setting(row(), heading: true); let active = scope(), command = change(task, scope: active)
        var reply: [String: JSON] = ["protocol": .number(1), "task_type_lifecycle_protocol": .number(1), "operation": .string("create"), "account": .string(account), "team_id": .string(team), "project_id": .string(project), "task_id": .string(task.id), "request_id": .string(command.id.uuidString.lowercased()), "task_generation": task["task_generation"], "unavailable": .bool(false), "replayed": .bool(false), "task": .object(task.fields)]
        XCTAssertEqual(try active.lifecycleSaved(reply, for: command), task)
        reply.removeValue(forKey: "task_type_lifecycle_protocol"); XCTAssertThrowsError(try active.lifecycleSaved(reply, for: command))
        reply["task_type_lifecycle_protocol"] = .number(1); task.fields.removeValue(forKey: "is_heading"); reply["task"] = .object(task.fields)
        XCTAssertThrowsError(try active.lifecycleSaved(reply, for: command))
        let decoded = try JSONDecoder().decode(Mutation.self, from: JSONEncoder().encode(command))
        XCTAssertEqual(decoded.teamTaskScope?.taskTypeLifecycleProtocol, 1); XCTAssertEqual(try active.lifecycleBody(for: decoded), try active.lifecycleBody(for: command))
    }
}


extension TeamTaskTypeLifecycleTests {
    func testActualSQLTypedCreateDeleteRestoreReceipts() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-type-lifecycle-v1", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        for action in ["create", "delete", "restore"] {
            let part = try XCTUnwrap(fixture[action]?.object), body = try XCTUnwrap(part["body"]?.object)
            let scope = TeamTaskEditScope(account: fixture["account"]!.text, origin: "https://synthetic.example", team: body["team_id"]!.text, project: body["project_id"]!.text, restoreRequest: body["restore_from"].flatMap { UUID(uuidString: $0.text) }, taskTypesProtocol: 1, taskTypeLifecycleProtocol: 1)
            let command = Mutation(id: try XCTUnwrap(UUID(uuidString: body["request_id"]!.text)), table: "tasks", recordID: body["task_id"]!.text, method: action == "delete" ? "DELETE" : "POST", fields: action == "delete" ? [:] : body["record"]!.object, baseline: action == "delete" ? body["record"]!.object : nil, insertOnly: action == "delete" ? nil : true, teamTaskScope: scope)
            XCTAssertEqual(try scope.lifecycleBody(for: command), body)
            let result = try scope.lifecycleSaved(part["reply"]!.object, for: command)
            if action == "delete" { XCTAssertNil(result) }
            else { XCTAssertEqual(result?["is_heading"], .bool(true)); XCTAssertEqual(result?["subtasks"].list[0].object["is_heading"], .bool(true)) }
        }
    }
    func testTypedSelectionUndoRetainsCapabilityAndRequiresTypedAcknowledgement() throws {
        let first = try TaskKind.setting(row(), heading: true); var second = row(); second["is_heading"] = .null
        let active = scope(authoring: false), rows = [first, second]
        let prepared = try TeamTaskBatch.preparing(rows.map { change($0, deleting: true, scope: active) }, snapshot: Snapshot(tables: ["tasks": rows]))
        let header = try XCTUnwrap(prepared.first), batch = try XCTUnwrap(header.teamTaskBatch), body = try batch.body(for: header)
        XCTAssertTrue(body["items"]!.list.allSatisfy { $0.object["task_type_lifecycle_protocol"] == .number(1) })
        var reply: [String: JSON] = ["protocol": .number(1), "account": .string(account), "team_id": .string(team), "request_id": body["request_id"]!, "operation": .string("delete"), "restores": .null, "replayed": .bool(false), "items": .array(body["items"]!.list.map { .object($0.object.filter { ["task_id", "project_id", "task_generation", "request_id"].contains($0.key) }) })]
        XCTAssertThrowsError(try batch.confirm(reply, for: header))
        reply["task_type_lifecycle_protocol"] = .number(1); XCTAssertNoThrow(try batch.confirm(reply, for: header))
        let undo = try batch.inverse(of: header, snapshot: Snapshot(tables: ["tasks": rows])), restored = try XCTUnwrap(undo.teamTaskBatch)
        XCTAssertTrue(try restored.body(for: undo)["items"]!.list.allSatisfy { $0.object["task_type_lifecycle_protocol"] == .number(1) })
    }
}
