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
