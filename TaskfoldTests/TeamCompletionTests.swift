import XCTest
@testable import TaskfoldCore

private final class CompletionHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest,CompletionHTTP)->Void)?
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func stopLoading() {}
    override func startLoading() {
        var request=request
        if request.httpBody == nil,let stream=request.httpBodyStream {
            stream.open();defer{stream.close()};var data=Data(),buffer=[UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable {let n=stream.read(&buffer,maxLength:buffer.count);if n<=0{break};data.append(contentsOf:buffer.prefix(n))};request.httpBody=data
        }
        Self.handler?(request,self)
    }
    func finish(_ data:Data,status:Int=200) {
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json","Content-Length":String(data.count)])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
}
final class TeamCompletionTests: XCTestCase {
    private let origin="https://backend.example"
    private func fixture(_ mode:String="complete") throws -> (Mutation,[String:JSON],[String:JSON]) {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"team-completion-v1",withExtension:"json",subdirectory:"Fixtures"))
        let root=try JSONDecoder().decode([String:JSON].self,from:Data(contentsOf:url)),prefix=mode == "complete" ? "":mode+"_"
        let body=root[prefix+"body"]!.object,reply=root[prefix+"reply"]!.object
        let scope=TeamTaskEditScope(account:root["account"]!.text,origin:origin,team:body["team_id"]!.text,project:body["project_id"]!.text)
        let operation:TeamCompletion.Operation=(mode == "undo" || mode == "kept") ? .undo:.complete
        let ref=body[operation == .undo ? "undoes":"redo_of"].flatMap{UUID(uuidString:$0.text)}
        let source=Record(body["record"]!.object),id=try XCTUnwrap(UUID(uuidString:body["request_id"]!.text)),clock=try XCTUnwrap(TaskPlanning.instant(body["completed_at"]!.text))
        let forecast=try TeamCompletion.complete(source,tasks:[source],scope:scope,at:clock,zone:body["input_zone"]!.text,id:operation == .undo ? ref!:id)
        var proposed=forecast.teamCompletion!.proposed;proposed?["task_generation"]=body["next_generation"]!
        let command=TeamCompletion(scope:scope,operation:operation,source:source,completedAt:body["completed_at"]!.text,inputZone:body["input_zone"]!.text,seriesID:body["series_id"]!.text,seriesGeneration:body["series_generation"]!.text,seriesProject:body["series_project_id"]!.text,nextGeneration:body["next_generation"]!.text,proposed:proposed,related:ref)
        return(TeamCompletion.header(command,id:id),body,reply)
    }
    private func snapshot(_ header:Mutation)->Snapshot {
        let command=header.teamCompletion!
        return Snapshot(tables:["tasks":[command.source],"projects":[Record(["id":.string(command.scope.project)])]],pending:[])
    }
    private func saved(_ reply:[String:JSON],id:String)->Record {Record(["id":.string(id),"team_completion_reply":.object(reply)])}
    @MainActor private func backend(_ account:String) throws -> Backend {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[CompletionHTTP.self]
        let session=try JSONDecoder().decode(Session.self,from:Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(account)\"}}".utf8))
        return Backend(configuration:["URL":origin,"Key":"synthetic-public"],http:URLSession(configuration:config),session:session,persistSession:{_ in})
    }
    func testNativeForecastAndEnvelopeMatchActualSQLCompletion() throws {
        let(header,body,reply)=try fixture(),command=header.teamCompletion!
        XCTAssertEqual(try command.body(for:header),body)
        let receipt=try command.receipt(reply,for:header)
        XCTAssertTrue(receipt.created);XCTAssertTrue(receipt.task!.completed)
        XCTAssertTrue(TeamCompletion.sameLocal(try XCTUnwrap(receipt.successor),try XCTUnwrap(command.proposed)))
        XCTAssertEqual(receipt.successor?["attachments"],command.source["attachments"])
    }
    func testPersistedCommandKeepsClockGenerationAndNonce() throws {
        let(header,_,_)=try fixture()
        XCTAssertEqual(try JSONDecoder().decode(Mutation.self,from:JSONEncoder().encode(header)),header)
        var old=try JSONDecoder().decode([String:JSON].self,from:JSONEncoder().encode(header));old.removeValue(forKey:"teamCompletion")
        XCTAssertNil(try JSONDecoder().decode(Mutation.self,from:JSONEncoder().encode(old)).teamCompletion)
    }
    func testLocalCompletionAppliesSourceAndSuccessorTogether() throws {
        let(header,_,_)=try fixture();var local=snapshot(header)
        XCTAssertTrue(header.teamCompletion!.apply(to:&local,header:header))
        XCTAssertEqual(local.tables["tasks"]?.count,2)
        XCTAssertTrue(local.tables["tasks"]!.first{$0.id == header.recordID}!.completed)
        var stale=snapshot(header);stale.tables["tasks"]![0]["task_generation"] = .string(UUID().uuidString.lowercased());let before=stale
        XCTAssertFalse(header.teamCompletion!.apply(to:&stale,header:header));XCTAssertEqual(stale,before)
    }
    func testExistingOccurrenceIsNotLocallyDuplicated() throws {
        let(header,_,_)=try fixture(),command=header.teamCompletion!;var local=snapshot(header)
        var existing=command.proposed!;existing["task_generation"] = .string(UUID().uuidString.lowercased());existing["id"] = .string(UUID().uuidString.lowercased());local.tables["tasks"]!.append(existing)
        XCTAssertTrue(command.apply(to:&local,header:header));XCTAssertEqual(local.tables["tasks"]?.count,2)
        XCTAssertEqual(local.tables["tasks"]?.last,existing)
    }
    func testUndoEnvelopeAndReceiptMatchActualSQL() throws {
        let(header,body,reply)=try fixture("undo"),command=header.teamCompletion!
        XCTAssertEqual(try command.body(for:header),body)
        let receipt=try command.receipt(reply,for:header);XCTAssertTrue(receipt.removed);XCTAssertFalse(receipt.task!.completed);XCTAssertNil(receipt.successor)
    }
    func testHistoryReferencesSentActionAndRedoUsesFreshGeneration() throws {
        let(header,_,_)=try fixture();var local=snapshot(header)
        let history=EditHistory(changes:[header],snapshot:local),undo=try XCTUnwrap(history.undo.first)
        XCTAssertEqual(undo.teamCompletion?.related,header.id)
        local.apply(header);let actualUndo=TeamCompletion.historyAction(undo,snapshot:local)
        let redoHistory=EditHistory(changes:[actualUndo],snapshot:local);local.apply(actualUndo)
        let redo=TeamCompletion.historyAction(try XCTUnwrap(redoHistory.undo.first),snapshot:local)
        XCTAssertEqual(redo.teamCompletion?.related,actualUndo.id);XCTAssertNotEqual(redo.id,header.id)
        XCTAssertNotEqual(redo.teamCompletion?.nextGeneration,header.teamCompletion?.nextGeneration)
        XCTAssertEqual(redo.teamCompletion?.source["completion_version"],.number(2))
        XCTAssertNoThrow(try redo.teamCompletion!.body(for:redo))
    }
    func testReceiptInstallsTwoCurrentRowsWithoutFakeHeaderTask() throws {
        let(header,_,reply)=try fixture();var local=snapshot(header);local.apply(header);local.pending=[header]
        XCTAssertTrue(local.acknowledge(header,saved:saved(reply,id:header.recordID)))
        XCTAssertTrue(local.pending.isEmpty);XCTAssertEqual(local.tables["tasks"]?.count,2)
        XCTAssertFalse(local.tables["tasks"]!.contains{$0.fields["team_completion_reply"] != nil})
    }
    func testAcknowledgementPreservesLaterOfflineUndoRedo() throws {
        let(header,_,reply)=try fixture();var local=snapshot(header)
        let undo=try XCTUnwrap(EditHistory(changes:[header],snapshot:local).undo.first);local.apply(header);local.pending=[header]
        let sentUndo=TeamCompletion.historyAction(undo,snapshot:local)
        let redoPlaceholder=try XCTUnwrap(EditHistory(changes:[sentUndo],snapshot:local).undo.first);local.apply(sentUndo);local.pending.append(sentUndo)
        let sentRedo=TeamCompletion.historyAction(redoPlaceholder,snapshot:local);local.apply(sentRedo);local.pending.append(sentRedo)
        let before=local.tables
        XCTAssertTrue(local.acknowledge(header,saved:saved(reply,id:header.recordID)))
        XCTAssertEqual(local.tables,before);XCTAssertEqual(local.pending.map(\.id),[sentUndo.id,sentRedo.id])
    }
    func testLosingProvisionalGenerationCannotEraseAuthoredDraft() throws {
        let(header,_,originalReply)=try fixture();var local=snapshot(header);local.apply(header);local.pending=[header]
        let proposed=header.teamCompletion!.proposed!
        let edit=Mutation(table:"tasks",recordID:proposed.id,method:"PATCH",fields:["title":.string("Keep this draft")],baseline:TaskCompletionRevision.editBaseline(for:["title":.string("Keep this draft")],from:proposed),teamTaskScope:header.teamCompletion!.scope)
        local.apply(edit);local.pending.append(edit);let before=local
        var reply=originalReply;var row=reply["successor"]!.object;let other=UUID().uuidString.lowercased();row["task_generation"] = .string(other);reply["successor"] = .object(row);reply["successor_generation"] = .string(other);reply["created_successor"] = .bool(false)
        XCTAssertFalse(local.acknowledge(header,saved:saved(reply,id:header.recordID)));XCTAssertEqual(local,before)
    }
    func testDifferentServerGenerationCanReplaceOnlyUntouchedProvisional() throws {
        let(header,_,originalReply)=try fixture();var local=snapshot(header);local.apply(header);local.pending=[header]
        var reply=originalReply;var row=reply["successor"]!.object;let other=UUID().uuidString.lowercased();row["task_generation"] = .string(other);reply["successor"] = .object(row);reply["successor_generation"] = .string(other);reply["created_successor"] = .bool(false)
        XCTAssertTrue(local.acknowledge(header,saved:saved(reply,id:header.recordID)))
        XCTAssertEqual(local.tables["tasks"]?.first{$0.id == row["id"]?.text}?["task_generation"],.string(other))
    }
    func testReceiptCannotRewindAlreadyFetchedGeneration() throws {
        let(header,_,reply)=try fixture();var local=snapshot(header);local.apply(header);local.pending=[header]
        local.tables["tasks"]![0]["task_generation"] = .string(UUID().uuidString.lowercased());let before=local
        XCTAssertFalse(local.acknowledge(header,saved:saved(reply,id:header.recordID)));XCTAssertEqual(local,before)
    }
    func testWrongAuthorityIdentityAndMalformedRepliesCannotAcknowledge() throws {
        let(header,_,reply)=try fixture(),command=header.teamCompletion!
        for key in ["account","team_id","project_id","task_id","task_generation","request_id","series_id","series_generation","series_project_id"] {var value=reply;value[key] = .string(UUID().uuidString.lowercased());XCTAssertThrowsError(try command.receipt(value,for:header))}
        for key in ["protocol","replayed","created_successor","removed_successor","source_revision","task"] {var value=reply;value.removeValue(forKey:key);XCTAssertThrowsError(try command.receipt(value,for:header))}
        var absent=reply;absent["task"] = .null;XCTAssertThrowsError(try command.receipt(absent,for:header))
    }
    func testGenericConflictAndProjectCleanupCannotDiscardCompletion() throws {
        let(header,_,reply)=try fixture();var local=snapshot(header);local.apply(header);local.pending=[header]
        XCTAssertNil(SyncConflict(mutation:header,remote:Record(reply["task"]!.object)).resolving(local,keepLocal:true))
        XCTAssertNil(local.recoveringUnavailableProject(for:header,remote:["projects":[],"tasks":[],"sections":[],"project_collaborators":[]]))
        var legacy=Mutation(table:"tasks",recordID:header.recordID,method:"PATCH",fields:["title":.string("Older edit")]);legacy.baseline=header.baseline
        local.pending.insert(legacy,at:0)
        XCTAssertNil(local.recoveringUnavailableProject(for:legacy,remote:["projects":[],"tasks":[],"sections":[],"project_collaborators":[]]))
    }
    @MainActor func testDedicatedTransportKeepsNonceAndReturnsStructuredReceipt() async throws {
        let(header,body,reply)=try fixture(),api=try backend(header.teamCompletion!.scope.account);var requests:[URLRequest]=[]
        CompletionHTTP.handler={request,peer in requests.append(request);peer.finish(try! JSONEncoder().encode(reply))};defer{CompletionHTTP.handler=nil}
        for _ in 0..<2 {let response=try await api.send(header,expectedAccount:header.teamCompletion!.scope.account);let result=try XCTUnwrap(response);XCTAssertEqual(result["team_completion_reply"],.object(reply))}
        XCTAssertEqual(requests.count,2)
        for request in requests {XCTAssertEqual(request.url?.path,"/rest/v1/rpc/taskfold_complete_team_task");XCTAssertEqual(request.timeoutInterval,25);XCTAssertFalse(request.httpShouldHandleCookies);XCTAssertEqual(request.value(forHTTPHeaderField:"Cache-Control"),"no-store");XCTAssertEqual(try JSONDecoder().decode([String:JSON].self,from:XCTUnwrap(request.httpBody))["_body"],.object(body))}
    }
    @MainActor func testOversizedAndWrongAccountResponsesKeepCommand() async throws {
        let(header,_,_)=try fixture(),api=try backend(header.teamCompletion!.scope.account)
        CompletionHTTP.handler={_,peer in peer.finish(Data(repeating:32,count:512001))};defer{CompletionHTTP.handler=nil}
        do{_=try await api.send(header);XCTFail("Oversized response accepted")}catch{XCTAssertTrue(error.localizedDescription.contains("too large"))}
        do{_=try await api.send(header,expectedAccount:UUID().uuidString.lowercased());XCTFail("Wrong account accepted")}catch{XCTAssertTrue(error is CancellationError)}
    }
    func testNonrecurringCompletionNeedsNoSuccessorOrParentLookup() throws {
        let(header,_,_)=try fixture();var source=header.teamCompletion!.source;source["is_recurring"] = .bool(false);source["recurrence_pattern"] = .null
        let command=try TeamCompletion.complete(source,tasks:[source],scope:header.teamCompletion!.scope,at:TaskPlanning.instant("2026-10-24T12:00:00Z")!,zone:"Europe/Copenhagen")
        XCTAssertNil(command.teamCompletion?.proposed)
        XCTAssertEqual(try command.teamCompletion!.body(for:command)["planned_next_id"],.null)
        var local=Snapshot(tables:["tasks":[source],"projects":[Record(["id":.string(source.string("project_id"))])]])
        XCTAssertTrue(command.teamCompletion!.apply(to:&local,header:command));XCTAssertEqual(local.tables["tasks"]?.count,1)
    }
    func testMalformedEnvelopeCannotBecomeOrdinaryTaskPatch() throws {
        let(original,_,_)=try fixture();let command=original.teamCompletion!
        var header=original;header.method="PATCH";XCTAssertThrowsError(try command.body(for:header))
        header=original;header.fields=["title":.string("Injected")];XCTAssertThrowsError(try command.body(for:header))
        header=original;header.baseline?["task_generation"] = .string(UUID().uuidString.lowercased());XCTAssertThrowsError(try command.body(for:header))
        XCTAssertThrowsError(try TeamCompletion.complete(command.source,tasks:[command.source],scope:command.scope,at:Date(),zone:"Not/AZone"))
    }

    private func reviewFixture(recorded:Bool=true,undo:Bool=false) throws -> (Mutation,[String:JSON],[String:JSON]) {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"team-completion-review-v1",withExtension:"json",subdirectory:"Fixtures"))
        let root=try JSONDecoder().decode([String:JSON].self,from:Data(contentsOf:url)),body=root[undo ? "undo_body":"body"]!.object
        let source=Record(body["record"]!.object),id=try XCTUnwrap(UUID(uuidString:body["request_id"]!.text))
        let scope=TeamTaskEditScope(account:root["account"]!.text,origin:origin,team:body["team_id"]!.text,project:body["project_id"]!.text)
        let forecast=try TeamCompletion.complete(source,tasks:[source],scope:scope,at:TaskPlanning.instant(body["completed_at"]!.text)!,zone:body["input_zone"]!.text,id:undo ? UUID(uuidString:body["undoes"]!.text)!:id)
        var proposed=forecast.teamCompletion!.proposed;proposed?["task_generation"]=body["next_generation"]!
        let command=TeamCompletion(scope:scope,operation:undo ? .undo:.complete,source:source,completedAt:body["completed_at"]!.text,inputZone:body["input_zone"]!.text,seriesID:body["series_id"]!.text,seriesGeneration:body["series_generation"]!.text,seriesProject:body["series_project_id"]!.text,nextGeneration:body["next_generation"]!.text,proposed:proposed,related:undo ? UUID(uuidString:body["undoes"]!.text):nil)
        return(TeamCompletion.header(command,id:id),body,root[undo ? "undo_review":recorded ? "recorded":"unrecorded"]!.object)
    }
    func testActualSQLReviewAndNativeEnvelopeAgree() throws {
        let(header,body,reply)=try reviewFixture(),review=try TeamCompletion.Review(reply,for:header)
        XCTAssertEqual(try header.teamCompletion!.body(for:header),body)
        XCTAssertTrue(review.isRecorded);XCTAssertTrue(review.task!.completed);XCTAssertEqual(review.role,.editor)
        XCTAssertEqual(review.successor?.id,header.teamCompletion!.proposed?.id)
    }
    func testRecordedReviewAcknowledgesSavedOutcomeWithoutNewCommand() throws {
        let(header,_,reply)=try reviewFixture(),review=try TeamCompletion.Review(reply,for:header)
        var local=snapshot(header);local.apply(header);local.pending=[header]
        let next=try XCTUnwrap(review.acknowledging(local))
        XCTAssertTrue(next.pending.isEmpty);XCTAssertEqual(next.tables["tasks"]?.first{$0.id == header.recordID},review.task)
        XCTAssertEqual(next.tables["tasks"]?.first{$0.id == review.successor?.id},review.successor)
    }
    func testUnrecordedReadCannotDiscardOrAcknowledgeInFlightCommand() throws {
        let(header,_,reply)=try reviewFixture(recorded:false),review=try TeamCompletion.Review(reply,for:header)
        var local=snapshot(header);local.apply(header);local.pending=[header];let original=local
        XCTAssertFalse(review.isRecorded);XCTAssertNil(review.acknowledging(local));XCTAssertEqual(local,original)
    }
    func testReviewMustMatchExactFrozenAuthorityAndRequest() throws {
        let(header,_,reply)=try reviewFixture()
        for key in ["account","team_id","project_id","task_id","task_generation","request_id","series_id","series_generation","series_project_id","planned_next_id"] {
            var wrong=reply;wrong[key] = .string(UUID().uuidString.lowercased());XCTAssertThrowsError(try TeamCompletion.Review(wrong,for:header),key)
        }
        var wrong=reply;wrong["operation"] = .string("undo");XCTAssertThrowsError(try TeamCompletion.Review(wrong,for:header))
        wrong=reply;wrong["project_role"] = .string("owner");XCTAssertThrowsError(try TeamCompletion.Review(wrong,for:header))
        wrong=reply;wrong["receipt"] = .null;XCTAssertThrowsError(try TeamCompletion.Review(wrong,for:header))
        wrong=reply;wrong["state"] = .string("unrecorded");XCTAssertThrowsError(try TeamCompletion.Review(wrong,for:header))
    }
    func testReviewRejectsInconsistentRowsAndReplacementSource() throws {
        let(header,_,reply)=try reviewFixture();var wrong=reply
        var task=reply["task"]!.object;task["task_generation"] = .string(UUID().uuidString.lowercased());wrong["task"] = .object(task)
        XCTAssertThrowsError(try TeamCompletion.Review(wrong,for:header))
        wrong=reply;var receipt=reply["receipt"]!.object;receipt["task"] = .null;wrong["receipt"] = .object(receipt)
        XCTAssertThrowsError(try TeamCompletion.Review(wrong,for:header))
        wrong=reply;wrong.removeValue(forKey:"series");XCTAssertThrowsError(try TeamCompletion.Review(wrong,for:header))
    }
    func testReviewRetainsEditedProvisionalDraftWhenServerAdoptedAnotherGeneration() throws {
        let(header,_,original)=try reviewFixture();var reply=original,receipt=reply["receipt"]!.object,next=reply["successor"]!.object
        let generation=UUID().uuidString.lowercased();next["task_generation"] = .string(generation)
        receipt["successor"] = .object(next);receipt["successor_generation"] = .string(generation);receipt["created_successor"] = .bool(false)
        reply["receipt"] = .object(receipt);reply["successor"] = .object(next)
        let review=try TeamCompletion.Review(reply,for:header)
        var local=snapshot(header);local.apply(header);local.pending=[header]
        let edit=Mutation(table:"tasks",recordID:next["id"]!.text,method:"PATCH",fields:["title":.string("Local design notes")])
        local.apply(edit);local.pending.append(edit);let exact=local
        XCTAssertNil(review.acknowledging(local));XCTAssertEqual(local,exact)
        local.pending.removeLast();local.tables["tasks"]?.removeAll{$0.id == edit.recordID};local.tables["tasks"]?.append(header.teamCompletion!.proposed!)
        XCTAssertNotNil(review.acknowledging(local))
    }
    func testRecordedReviewCannotAcknowledgeStaleOrNonHeadQueue() throws {
        let(header,_,reply)=try reviewFixture(),review=try TeamCompletion.Review(reply,for:header)
        var local=snapshot(header);local.apply(header)
        XCTAssertNil(review.acknowledging(local))
        local.pending=[Mutation(table:"labels",recordID:UUID().uuidString,method:"POST",fields:[:]),header]
        XCTAssertNil(review.acknowledging(local))
    }
    @MainActor func testReviewTransportIsReadOnlyBoundedAndAccountBound() async throws {
        let(header,body,reply)=try reviewFixture(),api=try backend(header.teamCompletion!.scope.account)
        var requests:[URLRequest]=[]
        CompletionHTTP.handler={request,peer in requests.append(request);peer.finish(try! JSONEncoder().encode(reply))};defer{CompletionHTTP.handler=nil}
        let result=try await api.reviewTeamCompletion(header,expectedAccount:header.teamCompletion!.scope.account)
        XCTAssertTrue(result.isRecorded);XCTAssertEqual(requests.count,1)
        let request=try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path,"/rest/v1/rpc/taskfold_review_team_completion");XCTAssertEqual(request.timeoutInterval,25);XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.value(forHTTPHeaderField:"Cache-Control"),"no-store")
        XCTAssertEqual(try JSONDecoder().decode([String:JSON].self,from:XCTUnwrap(request.httpBody))["_body"],.object(body))
        do{_=try await api.reviewTeamCompletion(header,expectedAccount:UUID().uuidString.lowercased());XCTFail("wrong account read")}catch{XCTAssertTrue(error is CancellationError)}
        XCTAssertEqual(requests.count,1)
        CompletionHTTP.handler={_,peer in peer.finish(Data(repeating:32,count:1_000_001))}
        do{_=try await api.reviewTeamCompletion(header,expectedAccount:header.teamCompletion!.scope.account);XCTFail("oversized review")}catch{XCTAssertTrue(error.localizedDescription.contains("too large"))}
    }

    func testActualSQLUndoReviewAcknowledgesWithoutReopeningAgain() throws {
        let(header,body,reply)=try reviewFixture(undo:true),review=try TeamCompletion.Review(reply,for:header)
        XCTAssertEqual(try header.teamCompletion!.body(for:header),body)
        XCTAssertEqual(header.teamCompletion?.operation,.undo);XCTAssertFalse(review.task!.completed);XCTAssertNil(review.successor)
        let local=Snapshot(tables:["tasks":[review.task!],"projects":[Record(["id":.string(header.teamCompletion!.scope.project)])]],pending:[header])
        let next=try XCTUnwrap(review.acknowledging(local));XCTAssertTrue(next.pending.isEmpty)
        XCTAssertEqual(next.tables["tasks"],local.tables["tasks"])
    }

}
