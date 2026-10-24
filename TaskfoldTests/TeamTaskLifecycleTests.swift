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
    func testLinkedDeleteBatchNeedsAtomicAdapterBeforeAdmission() throws {
        let(change,scope,_) = try fixture("delete"); let parent = Record(change.baseline!)
        var child = parent; child["id"] = .string(UUID().uuidString.lowercased()); child["recurrence_parent_id"] = .string(parent.id)
        let childChange = Mutation(table:"tasks",recordID:child.id,method:"DELETE",fields:[:],baseline:child.fields,teamTaskScope:scope)
        let snapshot = Snapshot(tables:["tasks":[parent,child]])
        XCTAssertTrue(TeamTaskEditScope.needsLinkedDeletionReview([change,childChange],snapshot:snapshot))
        XCTAssertFalse(TeamTaskEditScope.needsLinkedDeletionReview([change],snapshot:snapshot))
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
