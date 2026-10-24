import XCTest
import CryptoKit
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

    private func cancellationFixture(recorded:Bool=false,undo:Bool=false) throws -> (Mutation,[String:JSON],[String:JSON]) {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"team-completion-cancellation-v1",withExtension:"json",subdirectory:"Fixtures"))
        let root=try JSONDecoder().decode([String:JSON].self,from:Data(contentsOf:url)),body=root[undo ? "undo_body":recorded ? "recorded_body":"body"]!.object
        let source=Record(body["record"]!.object),id=try XCTUnwrap(UUID(uuidString:body["request_id"]!.text))
        let scope=TeamTaskEditScope(account:root["account"]!.text,origin:origin,team:body["team_id"]!.text,project:body["project_id"]!.text)
        let forecast=try TeamCompletion.complete(source,tasks:[source],scope:scope,at:TaskPlanning.instant(body["completed_at"]!.text)!,zone:body["input_zone"]!.text,id:undo ? UUID(uuidString:body["undoes"]!.text)!:id)
        var proposed=forecast.teamCompletion!.proposed;proposed?["task_generation"]=body["next_generation"]!
        let command=TeamCompletion(scope:scope,operation:undo ? .undo:.complete,source:source,completedAt:body["completed_at"]!.text,inputZone:body["input_zone"]!.text,seriesID:body["series_id"]!.text,seriesGeneration:body["series_generation"]!.text,seriesProject:body["series_project_id"]!.text,nextGeneration:body["next_generation"]!.text,proposed:proposed,related:undo ? UUID(uuidString:body["undoes"]!.text):nil)
        return(TeamCompletion.header(command,id:id),body,root[undo ? "undo_cancelled":recorded ? "recorded":"cancelled"]!.object)
    }
    private func projected(_ header:Mutation)->Snapshot {
        var local=snapshot(header);local.apply(header);local.pending=[header];return local
    }
    func testActualSQLCancellationRestoresSyncedRowsAndOnlyRemovesCertifiedCommand() throws {
        let(header,body,reply)=try cancellationFixture(),review=try TeamCompletion.Review(reply,for:header)
        XCTAssertEqual(try header.teamCompletion!.body(for:header),body)
        var local=projected(header)
        let unrelated=Mutation(table:"labels",recordID:UUID().uuidString.lowercased(),method:"POST",fields:["name":.string("Independent work")])
        local.apply(unrelated);local.pending.append(unrelated)
        let result=try XCTUnwrap(review.cancelling(local))
        XCTAssertTrue(review.isCancelled);XCTAssertFalse(review.isRecorded);XCTAssertNil(review.acknowledging(local))
        XCTAssertEqual(result.pending,[unrelated]);XCTAssertEqual(result.tables["tasks"],[review.task!]);XCTAssertEqual(result.tables["labels"],local.tables["labels"])
    }
    func testUnrecordedObservationDoesNotAuthorizeCancellationProjection() throws {
        let(header,_,original)=try cancellationFixture();var reply=original;reply["state"] = .string("unrecorded")
        let review=try TeamCompletion.Review(reply,for:header),local=projected(header)
        XCTAssertTrue(review.canRequestCancellation(local));XCTAssertNil(review.cancelling(local));XCTAssertEqual(local.pending,[header])
    }
    func testCancelledActionRejectsStaleQueueOrMalformedAuthority() throws {
        let(header,_,reply)=try cancellationFixture(),review=try TeamCompletion.Review(reply,for:header)
        var local=projected(header);local.pending=[];XCTAssertNil(review.cancelling(local))
        local.pending=[header];local.pending[0].id=UUID();XCTAssertNil(review.cancelling(local))
        for key in ["account","team_id","project_id","request_id","task_generation"] {
            var bad=reply;bad[key] = .string(UUID().uuidString.lowercased());XCTAssertThrowsError(try TeamCompletion.Review(bad,for:header))
        }
        var bad=reply;bad["receipt"] = .object([:]);XCTAssertThrowsError(try TeamCompletion.Review(bad,for:header))
    }
    func testCancellationKeepsAuthoredSourceAndProvisionalEditsForSeparateReview() throws {
        let(header,_,reply)=try cancellationFixture(),review=try TeamCompletion.Review(reply,for:header)
        for id in [header.recordID,header.teamCompletion!.proposed!.id] {
            var local=projected(header)
            let edit=Mutation(table:"tasks",recordID:id,method:"PATCH",fields:["title":.string("Authored draft")])
            local.apply(edit);local.pending.append(edit);let before=local
            XCTAssertFalse(review.canRequestCancellation(local));XCTAssertNil(review.cancelling(local));XCTAssertEqual(local,before)
            local.pending.removeLast() // Even an unexplained local delta cannot be discarded.
            XCTAssertNil(review.cancelling(local))
        }
    }
    func testCancellationFindsDependenciesInsideBatchesHistoryAndPinnedNotes() throws {
        let(header,_,reply)=try cancellationFixture(),review=try TeamCompletion.Review(reply,for:header),command=header.teamCompletion!
        let deletion=Mutation(table:"tasks",recordID:command.proposed!.id,method:"DELETE",fields:[:])
        let batch=TeamTaskBatch(account:command.scope.account,origin:origin,team:command.scope.team,operation:.delete,restores:nil,items:[deletion])
        let pin=Mutation(table:"view_orders",recordID:"notes",method:"PATCH",fields:["ids":.array([.string("task:"+command.proposed!.id)])])
        for dependent in [TeamTaskBatch.header(batch),try command.inverse(of:header),pin] {
            var local=projected(header);local.pending.append(dependent)
            XCTAssertNil(review.cancelling(local));XCTAssertEqual(local.pending.count,2)
        }
    }
    func testCancellationProtectsSeparateCommentDraftOutbox() throws {
        let(header,_,reply)=try cancellationFixture(),review=try TeamCompletion.Review(reply,for:header),command=header.teamCompletion!
        var local=projected(header)
        let intent=try SharedCommentChange(account:command.scope.account,taskID:command.proposed!.id,taskGeneration:command.nextGeneration,projectID:command.scope.project,body:"Keep this discussion draft")
        try ConversationOutbox.enqueue(intent.record,into:&local);let before=local
        XCTAssertNil(review.cancelling(local));XCTAssertEqual(local,before)
    }
    func testCancellationRetainsExistingServerOccurrenceAndNeverRewindsGeneration() throws {
        let(header,_,original)=try cancellationFixture();var reply=original
        var existing=header.teamCompletion!.proposed!;existing["task_generation"] = .string(UUID().uuidString.lowercased());existing["title"] = .string("Existing shared occurrence")
        reply["successor"] = .object(existing.fields)
        let review=try TeamCompletion.Review(reply,for:header)
        var local=projected(header);local.tables["tasks"]?.removeAll{$0.id == existing.id};local.tables["tasks"]?.append(existing)
        let result=try XCTUnwrap(review.cancelling(local));XCTAssertEqual(result.tables["tasks"]?.first{$0.id == existing.id},existing)
        local.tables["tasks"]?[0]["task_generation"] = .string(UUID().uuidString.lowercased())
        XCTAssertNil(review.cancelling(local))
    }
    func testRecordedWinnerCannotBeDiscardedAsCancellation() throws {
        let(header,_,reply)=try cancellationFixture(recorded:true),review=try TeamCompletion.Review(reply,for:header),local=projected(header)
        XCTAssertTrue(review.isRecorded);XCTAssertFalse(review.isCancelled)
        XCTAssertFalse(review.canRequestCancellation(local));XCTAssertNil(review.cancelling(local));XCTAssertNotNil(review.acknowledging(local))
    }
    func testRecoveryVaultPreservesEntireOriginalCompletionBeforeCancellation() throws {
        let(header,_,reply)=try cancellationFixture(),review=try TeamCompletion.Review(reply,for:header)
        var local=projected(header);local.tables["projects"]=[Record(["id":.string(header.teamCompletion!.scope.project),"name":.string("Synthetic review project"),"user_id":.string(header.teamCompletion!.scope.account)])]
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-cancel-vault-"+UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        let key=SymmetricKey(size:.bits256),vault=BackupVault(directory:directory,account:header.teamCompletion!.scope.account,key:{key})
        let entry=try vault.save(local,kind:"Before sync review"),loaded=try vault.load(entry)
        XCTAssertEqual(loaded.snapshot,local);XCTAssertEqual(loaded.snapshot.pending,[header]);XCTAssertNotNil(review.cancelling(local))
        XCTAssertFalse(String(decoding:try Data(contentsOf:vault.file(entry)),as:UTF8.self).contains(header.teamCompletion!.source.title))
    }
    @MainActor func testCancellationTransportRequiresDurableOutcomeAndRetriesSameBody() async throws {
        let(header,body,reply)=try cancellationFixture(),api=try backend(header.teamCompletion!.scope.account)
        var requests:[URLRequest]=[]
        CompletionHTTP.handler={request,peer in requests.append(request);peer.finish(try! JSONEncoder().encode(reply))};defer{CompletionHTTP.handler=nil}
        let first=try await api.cancelTeamCompletion(header,expectedAccount:header.teamCompletion!.scope.account)
        let again=try await api.cancelTeamCompletion(header,expectedAccount:header.teamCompletion!.scope.account)
        XCTAssertEqual(first,again);XCTAssertTrue(first.isCancelled);XCTAssertEqual(requests.count,2)
        for request in requests {
            XCTAssertEqual(request.url?.path,"/rest/v1/rpc/taskfold_cancel_team_completion");XCTAssertEqual(request.timeoutInterval,25);XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.value(forHTTPHeaderField:"Cache-Control"),"no-store")
            XCTAssertEqual(try JSONDecoder().decode([String:JSON].self,from:XCTUnwrap(request.httpBody))["_body"],.object(body))
        }
        var absent=reply;absent["state"] = .string("unrecorded")
        CompletionHTTP.handler={_,peer in peer.finish(try! JSONEncoder().encode(absent))}
        do{_=try await api.cancelTeamCompletion(header,expectedAccount:header.teamCompletion!.scope.account);XCTFail("Absence treated as cancellation")}catch{}
        CompletionHTTP.handler={_,peer in peer.finish(Data(repeating:32,count:1_000_001))}
        do{_=try await api.cancelTeamCompletion(header,expectedAccount:header.teamCompletion!.scope.account);XCTFail("Oversized certificate")}catch{XCTAssertTrue(error.localizedDescription.contains("too large"))}
        do{_=try await api.cancelTeamCompletion(header,expectedAccount:UUID().uuidString.lowercased());XCTFail("Wrong account cancellation")}catch{XCTAssertTrue(error is CancellationError)}
    }

    func testCancelledUndoRestoresCompletedRootAndExistingNextOccurrence() throws {
        let(header,_,reply)=try cancellationFixture(undo:true),review=try TeamCompletion.Review(reply,for:header),command=header.teamCompletion!
        var completed=command.source;completed["completed"] = .bool(true);completed["completed_at"] = .string(command.completedAt);completed["completion_version"] = .number(Double(command.source["completion_version"].integer+1))
        var local=Snapshot(tables:["projects":[Record(["id":.string(command.scope.project)])],"tasks":[completed,command.proposed!]],pending:[header])
        XCTAssertTrue(command.apply(to:&local,header:header));XCTAssertFalse(local.tables["tasks"]!.first!.completed)
        let result=try XCTUnwrap(review.cancelling(local));XCTAssertTrue(result.pending.isEmpty)
        XCTAssertTrue(result.tables["tasks"]!.first{$0.id == command.source.id}!.completed)
        XCTAssertEqual(result.tables["tasks"]!.first{$0.id == command.proposed!.id},review.successor)
    }

    func testReviewResolutionDoesNotReplayUnrelatedCompletionCycles() throws {
        for recorded in [false,true] {
            let(header,_,reply)=try cancellationFixture(recorded:recorded),review=try TeamCompletion.Review(reply,for:header)
            var local=projected(header),other=header.teamCompletion!.source
            other["id"] = .string(UUID().uuidString.lowercased());other["task_generation"] = .string(UUID().uuidString.lowercased())
            other["is_recurring"] = .bool(false);other["recurrence_pattern"] = .null
            local.tables["tasks"]?.append(other)
            let first=TaskCompletionRevision.capturing(Mutation(table:"tasks",recordID:other.id,method:"PATCH",fields:["completed":.bool(true),"completed_at":.string("2026-10-24T14:00:00Z")]),existing:other)
            local.apply(first);local.pending.append(first)
            let middle=local.tables["tasks"]!.first{$0.id == other.id}!
            let second=TaskCompletionRevision.capturing(Mutation(table:"tasks",recordID:other.id,method:"PATCH",fields:["completed":.bool(false),"completed_at":.null]),existing:middle)
            local.apply(second);local.pending.append(second)
            let expected=local.tables["tasks"]!.first{$0.id == other.id}!
            XCTAssertEqual(expected["completion_version"],.number(2))
            let resolved=try XCTUnwrap(recorded ? review.acknowledging(local):review.cancelling(local))
            XCTAssertEqual(resolved.tables["tasks"]!.first{$0.id == other.id},expected)
            XCTAssertEqual(resolved.pending,[first,second])
        }
    }

    func testRecordedOutcomeKeepsLaterAtomicDeletionCohortWaitingTogether() throws {
        let(header,_,reply)=try cancellationFixture(recorded:true),review=try TeamCompletion.Review(reply,for:header),command=header.teamCompletion!
        let item=Mutation(table:"tasks",recordID:command.proposed!.id,method:"DELETE",fields:[:],baseline:command.proposed!.fields,teamTaskScope:command.scope)
        let batch=TeamTaskBatch(account:command.scope.account,origin:origin,team:command.scope.team,operation:.delete,restores:nil,items:[item])
        let group=TeamTaskBatch.header(batch)
        var local=projected(header);XCTAssertTrue(batch.apply(to:&local,header:group));local.pending.append(group)
        let exact=local
        XCTAssertNil(review.acknowledging(local));XCTAssertEqual(local,exact)
        XCTAssertEqual(local.pending,[header,group])
    }

    private func rebaseFixture(_ mode:String="complete",state:String="cancelled") throws -> (Mutation,[String:JSON],[String:JSON],[String:JSON]) {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"team-completion-rebase-v1",withExtension:"json",subdirectory:"Fixtures"))
        let root=try JSONDecoder().decode([String:JSON].self,from:Data(contentsOf:url))
        let prefix=mode == "complete" ? "":mode+"_",body=root[prefix+"body"]!.object
        let key=mode == "parent" ? "parent_"+state : prefix+(state == "review" ? "review":state)
        let reply=root[key]!.object,source=Record(body["record"]!.object),id=try XCTUnwrap(UUID(uuidString:body["request_id"]!.text))
        let undo=mode == "undo",reference=undo ? UUID(uuidString:body["undoes"]!.text):nil
        let scope=TeamTaskEditScope(account:root["account"]!.text,origin:origin,team:body["team_id"]!.text,project:body["project_id"]!.text)
        var tasks=[source];if case .object(let parent)?=reply["series"] {tasks.append(Record(parent))}
        let forecast=try TeamCompletion.complete(source,tasks:tasks,scope:scope,at:TaskPlanning.instant(body["completed_at"]!.text)!,zone:body["input_zone"]!.text,id:reference ?? id)
        var proposed=forecast.teamCompletion!.proposed;proposed?["task_generation"]=body["next_generation"]!
        let command=TeamCompletion(scope:scope,operation:undo ? .undo:.complete,source:source,completedAt:body["completed_at"]!.text,inputZone:body["input_zone"]!.text,seriesID:body["series_id"]!.text,seriesGeneration:body["series_generation"]!.text,seriesProject:body["series_project_id"]!.text,nextGeneration:body["next_generation"]!.text,proposed:proposed,related:reference)
        return(TeamCompletion.header(command,id:id),body,reply,root)
    }
    private func rebaseProjection(_ header:Mutation)->Snapshot {
        guard header.teamCompletion!.operation == .undo else {return projected(header)}
        let command=header.teamCompletion!;var completed=command.source
        completed["completed"] = .bool(true);completed["completed_at"] = .string(command.completedAt);completed["completion_version"] = .number(Double(command.source["completion_version"].integer+1))
        var local=Snapshot(tables:["projects":[Record(["id":.string(command.scope.project)])],"tasks":[completed]+[command.proposed].compactMap{$0}],pending:[header])
        XCTAssertTrue(command.apply(to:&local,header:header));return local
    }
    func testRebasedCompletionMatchesActualSQLSourceAndRecurrenceContract() throws {
        let(header,_,reply,root)=try rebaseFixture(),review=try TeamCompletion.Review(reply,for:header),local=rebaseProjection(header)
        let sql=root["rebased_body"]!.object,id=try XCTUnwrap(UUID(uuidString:sql["request_id"]!.text))
        let plan=try XCTUnwrap(review.rebasing(local,id:id)),command=try XCTUnwrap(plan.action.teamCompletion)
        var body=try command.body(for:plan.action),expected=sql
        // Each caller owns its fresh UUID; the remainder must match the body
        // accepted by the real SQL fixture, including the changed repeat rule.
        expected["next_generation"]=body["next_generation"]
        XCTAssertEqual(body,expected);XCTAssertNotEqual(plan.action.id,header.id)
        XCTAssertNotEqual(command.nextGeneration,header.teamCompletion!.nextGeneration)
        XCTAssertNil(command.related);XCTAssertEqual(command.source,review.task)
        XCTAssertEqual(command.completedAt,header.teamCompletion!.completedAt)
        XCTAssertEqual(command.proposed?["due_date"],.string("2026-10-28"))
        XCTAssertEqual(command.proposed?["attachments"],review.task?["attachments"])
        XCTAssertEqual(command.proposed?["source_metadata"].object["future"],review.task?["source_metadata"].object["future"])
        XCTAssertEqual(plan.snapshot.pending,[plan.action]);XCTAssertTrue(plan.snapshot.tables["tasks"]!.first{$0.id == command.source.id}!.completed)
        XCTAssertFalse(plan.snapshot.tables["tasks"]!.contains{$0.id == header.teamCompletion!.proposed!.id})
        body["request_id"] = .string(header.id.uuidString.lowercased());XCTAssertNotEqual(body,try command.body(for:plan.action))
    }
    func testUnrecordedReviewPreviewsButCannotQueueRebaseUntilCancelled() throws {
        let(header,_,reply,_)=try rebaseFixture(state:"review"),review=try TeamCompletion.Review(reply,for:header),local=rebaseProjection(header)
        XCTAssertTrue(review.canRequestRebase(local));XCTAssertNotNil(review.previewRebase(local));XCTAssertNil(review.rebasing(local))
        XCTAssertEqual(local.pending,[header])
    }
    func testRebaseDoesNotOfferActionWithoutItsCachedProject() throws {
        for mode in ["complete","undo"] {
            for state in ["review","cancelled"] {
                let(header,_,reply,_)=try rebaseFixture(mode,state:state)
                let review=try TeamCompletion.Review(reply,for:header)
                let projectSets:[[Record]?]=[nil,[],[Record(["id":.string(UUID().uuidString.lowercased())])]]
                for projects in projectSets {
                    var local=rebaseProjection(header);local.tables["projects"]=projects
                    let before=local
                    XCTAssertFalse(review.hasRebaseProject(in:local))
                    XCTAssertNil(review.previewRebase(local));XCTAssertFalse(review.canRequestRebase(local))
                    XCTAssertNil(review.rebasing(local));XCTAssertEqual(local,before)
                    // Keeping the synced task remains available: it does not
                    // enqueue a new edit into the missing project.
                    XCTAssertTrue(review.canRequestCancellation(local))
                }
            }
        }
    }
    func testRestoredProjectEnablesRebaseWithoutRewritingOtherWork() throws {
        for mode in ["complete","undo"] {
            let(header,_,reply,_)=try rebaseFixture(mode),review=try TeamCompletion.Review(reply,for:header)
            var local=rebaseProjection(header);local.tables.removeValue(forKey:"projects")
            let independent=Mutation(table:"labels",recordID:UUID().uuidString.lowercased(),method:"POST",fields:["name":.string("Keep this draft")])
            local.apply(independent);local.pending.append(independent)
            XCTAssertNil(review.previewRebase(local))
            local.tables["projects"]=[Record(["id":.string(header.teamCompletion!.scope.project)])]
            XCTAssertNotNil(review.previewRebase(local))
            let before=local,plan=try XCTUnwrap(review.rebasing(local))
            XCTAssertEqual(plan.snapshot.pending,[plan.action,independent])
            XCTAssertEqual(plan.snapshot.tables["labels"],before.tables["labels"])
            XCTAssertEqual(local,before)
        }
    }
    func testProjectRemovedAfterPreviewCannotQueueRebasedAction() throws {
        for mode in ["complete","undo"] {
            let(header,_,reply,_)=try rebaseFixture(mode),review=try TeamCompletion.Review(reply,for:header)
            var local=rebaseProjection(header)
            XCTAssertNotNil(review.previewRebase(local))
            local.tables["projects"]=[];let before=local
            XCTAssertNil(review.rebasing(local));XCTAssertEqual(local,before)
            XCTAssertEqual(local.pending,[header])
        }
    }

    func testRebaseDefaultClosedOnOlderBackendAndMalformedCapabilities() throws {
        let(header,_,original,_)=try rebaseFixture();var reply=original
        reply.removeValue(forKey:"can_edit_current");reply.removeValue(forKey:"can_edit_series")
        let review=try TeamCompletion.Review(reply,for:header),local=rebaseProjection(header)
        XCTAssertFalse(review.canEditCurrent);XCTAssertFalse(review.canEditSeries);XCTAssertNil(review.previewRebase(local));XCTAssertTrue(review.canRequestCancellation(local))
        for key in ["can_edit_current","can_edit_series"] {
            var invalid=original;invalid[key] = .number(1);XCTAssertThrowsError(try TeamCompletion.Review(invalid,for:header))
            invalid[key] = .null;XCTAssertThrowsError(try TeamCompletion.Review(invalid,for:header))
        }
    }
    func testRebaseRequiresCurrentEditorCapabilityAndUntouchedProjection() throws {
        let(header,_,original,_)=try rebaseFixture(),local=rebaseProjection(header)
        for (key,value) in [("can_edit_current",JSON.bool(false)),("project_role",JSON.string("viewer"))] {
            var reply=original;reply[key]=value;let review=try TeamCompletion.Review(reply,for:header)
            XCTAssertNil(review.previewRebase(local));XCTAssertNil(review.rebasing(local))
        }
        let review=try TeamCompletion.Review(original,for:header)
        var draft=local;let change=Mutation(table:"tasks",recordID:header.teamCompletion!.proposed!.id,method:"PATCH",fields:["description":.string("My unsent instructions")])
        draft.apply(change);draft.pending.append(change);let saved=draft
        XCTAssertNil(review.rebasing(draft));XCTAssertEqual(draft,saved)
        XCTAssertNil(review.rebasing(local,id:header.id))
    }
    func testRebaseCannotApplyChangedServerObservationWithoutAnotherReview() throws {
        let(header,_,before,root)=try rebaseFixture("changed",state:"cancelled")
        let expected=try TeamCompletion.Review(before,for:header),changed=try TeamCompletion.Review(root["changed_again"]!.object,for:header)
        XCTAssertFalse(changed.matchesRebaseObservation(expected));XCTAssertTrue(expected.matchesRebaseObservation(expected))
        let plan=try XCTUnwrap(changed.rebasing(rebaseProjection(header)))
        XCTAssertEqual(plan.action.teamCompletion?.source.string("description"),"Changed again while reviewing")
    }
    func testRebaseIndependentlyChecksSeriesParentAccessAndGeneration() throws {
        let(header,_,reply,_)=try rebaseFixture("parent",state:"viewer"),local=rebaseProjection(header)
        let viewer=try TeamCompletion.Review(reply,for:header)
        XCTAssertTrue(viewer.canEditCurrent);XCTAssertFalse(viewer.canEditSeries);XCTAssertNil(viewer.previewRebase(local))
        var allowed=reply;allowed["can_edit_series"] = .bool(true);let editor=try TeamCompletion.Review(allowed,for:header)
        XCTAssertNotNil(editor.previewRebase(local))
        allowed["series"] = .null;let unavailable=try TeamCompletion.Review(allowed,for:header);XCTAssertNil(unavailable.previewRebase(local))
        var bad=reply;var parent=reply["series"]!.object;parent["task_generation"] = .string(UUID().uuidString.lowercased());bad["series"] = .object(parent)
        XCTAssertThrowsError(try TeamCompletion.Review(bad,for:header))
    }
    func testRebasedReopenMatchesSQLGuardedPatchAndPreservesExistingFuture() throws {
        let(header,_,reply,root)=try rebaseFixture("undo"),review=try TeamCompletion.Review(reply,for:header)
        let sql=root["reopen_body"]!.object,id=try XCTUnwrap(UUID(uuidString:sql["request_id"]!.text))
        let plan=try XCTUnwrap(review.rebasing(rebaseProjection(header),id:id)),scope=try XCTUnwrap(plan.action.teamTaskScope)
        XCTAssertEqual(try scope.body(for:plan.action),sql);XCTAssertNil(plan.action.teamCompletion)
        XCTAssertEqual(plan.action.fields,["completed":.bool(false),"completed_at":.null])
        XCTAssertEqual(plan.snapshot.tables["tasks"]!.first{$0.id == header.recordID}?["completion_version"],.number(Double(review.task!["completion_version"].integer+1)))
        XCTAssertEqual(plan.snapshot.tables["tasks"]!.first{$0.id == review.successor?.id},review.successor)
        XCTAssertNotEqual(plan.action.id,header.id)
    }
    func testRebasePreservesIndependentPendingRowsAndNewQueuePosition() throws {
        let(header,_,reply,_)=try rebaseFixture(),review=try TeamCompletion.Review(reply,for:header)
        var local=rebaseProjection(header)
        let unrelated=Mutation(table:"labels",recordID:UUID().uuidString.lowercased(),method:"POST",fields:["name":.string("Independent queue")])
        local.apply(unrelated);local.pending.append(unrelated)
        let plan=try XCTUnwrap(review.rebasing(local))
        XCTAssertEqual(plan.snapshot.pending,[plan.action,unrelated]);XCTAssertEqual(plan.snapshot.tables["labels"],local.tables["labels"])
        XCTAssertEqual(plan.base.pending,[unrelated]);XCTAssertEqual(local.pending,[header,unrelated])
    }
    func testRebasedCompletionCanPersistRetryAndBuildItsOwnUndo() throws {
        let(header,_,reply,_)=try rebaseFixture(),review=try TeamCompletion.Review(reply,for:header)
        let plan=try XCTUnwrap(review.rebasing(rebaseProjection(header)))
        let restored=try JSONDecoder().decode(Snapshot.self,from:JSONEncoder().encode(plan.snapshot))
        XCTAssertEqual(restored,plan.snapshot);XCTAssertEqual(try restored.pending[0].teamCompletion!.body(for:restored.pending[0]),try plan.action.teamCompletion!.body(for:plan.action))
        let history=EditHistory(changes:[plan.action],snapshot:plan.base),back=try XCTUnwrap(history.undo.first),undo=try XCTUnwrap(back.teamCompletion)
        XCTAssertEqual(undo.related,plan.action.id);XCTAssertNotEqual(undo.related,header.id);XCTAssertEqual(undo.source,review.task)
        var after=plan.snapshot;XCTAssertTrue(undo.apply(to:&after,header:back));XCTAssertFalse(after.tables["tasks"]!.first{$0.id == header.recordID}!.completed)
    }
    func testAlreadyCompletedOrAlreadyReopenedTaskDoesNotOfferAnotherAction() throws {
        for mode in ["complete","undo"] {
            let(header,_,original,_)=try rebaseFixture(mode);var reply=original,task=reply["task"]!.object
            task["completed"] = .bool(mode == "complete");reply["task"] = .object(task)
            let review=try TeamCompletion.Review(reply,for:header)
            XCTAssertNil(review.previewRebase(rebaseProjection(header)))
        }
    }

    private func retirementFixture() throws -> (Mutation,[String:JSON],[String:JSON]) {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"team-provisional-retirement-v1",withExtension:"json",subdirectory:"Fixtures"))
        let root=try JSONDecoder().decode([String:JSON].self,from:Data(contentsOf:url)),body=root["body"]!.object
        let source=Record(body["record"]!.object),id=try XCTUnwrap(UUID(uuidString:body["request_id"]!.text))
        let scope=TeamTaskEditScope(account:root["account"]!.text,origin:origin,team:body["team_id"]!.text,project:body["project_id"]!.text)
        let forecast=try TeamCompletion.complete(source,tasks:[source],scope:scope,at:TaskPlanning.instant(body["completed_at"]!.text)!,zone:body["input_zone"]!.text,id:id)
        var proposed=forecast.teamCompletion!.proposed;proposed?["task_generation"]=body["next_generation"]!
        let command=TeamCompletion(scope:scope,operation:.complete,source:source,completedAt:body["completed_at"]!.text,inputZone:body["input_zone"]!.text,seriesID:body["series_id"]!.text,seriesGeneration:body["series_generation"]!.text,seriesProject:body["series_project_id"]!.text,nextGeneration:body["next_generation"]!.text,proposed:proposed,related:nil)
        return(TeamCompletion.header(command,id:id),body,root["retirement"]!.object)
    }
    private func editedDraftSnapshot(_ header:Mutation) throws -> Snapshot {
        var local=projected(header);let command=header.teamCompletion!,next=command.proposed!
        let fields:[String:JSON] = ["title":.string("My unsent design notes"),"description":.string("Keep every edited instruction")]
        let scope=command.scope
        let change=try scope.capturing(Mutation(table:"tasks",recordID:next.id,method:"PATCH",fields:fields,baseline:TaskCompletionRevision.editBaseline(for:fields,from:next),teamTaskScope:scope),existing:next)
        local.apply(change);local.pending.append(change)
        let comment=try SharedCommentChange(account:scope.account,taskID:next.id,taskGeneration:next.string("task_generation"),projectID:scope.project,body:"Keep this comment draft")
        try ConversationOutbox.enqueue(comment.record,into:&local)
        return local
    }
    private func draftVault(_ draft:TeamCompletionDraft,directory:URL,key:SymmetricKey) -> TeamCompletionDraftVault {
        TeamCompletionDraftVault(directory:directory,account:draft.scope.account,origin:draft.scope.origin,key:{key})
    }
    func testRetirementProofParksOwnDraftWithoutChangingSharedOccurrence() throws {
        let(header,body,raw)=try retirementFixture(),proof=try TeamCompletionDraft.Retirement(raw,for:header)
        XCTAssertEqual(try header.teamCompletion!.body(for:header),body)
        var local=try editedDraftSnapshot(header)
        let unrelated=Mutation(table:"labels",recordID:UUID().uuidString.lowercased(),method:"POST",fields:["name":.string("Independent work")])
        local.apply(unrelated);local.pending.append(unrelated)
        let candidate=try XCTUnwrap(TeamCompletionDraft.Candidate(review:proof.review,snapshot:local)),before=local
        let next=try XCTUnwrap(candidate.parking(local,proof:proof))
        XCTAssertEqual(next.pending,[unrelated]);XCTAssertEqual(next.tables["labels"],local.tables["labels"])
        XCTAssertEqual(next.tables["tasks"]?.first{$0.id == proof.currentProposed?.id},proof.currentProposed)
        XCTAssertEqual(candidate.draft.record.title,"My unsent design notes");XCTAssertEqual(candidate.draft.edits,[local.pending[1]])
        XCTAssertEqual(candidate.draft.conversations,local.tables[ConversationOutbox.table]);XCTAssertTrue(next.tables[ConversationOutbox.table]?.isEmpty == true)
        XCTAssertEqual(local,before);XCTAssertEqual(candidate.draft.original,header)
        XCTAssertTrue(candidate.draft.text.contains("Keep this comment draft"))
    }
    func testRetirementProofRejectsWrongScopeOrLiveGeneration() throws {
        let(header,_,raw)=try retirementFixture()
        for key in ["account","team_id","project_id","request_id","task_id","task_generation"] {
            var invalid=raw;invalid[key] = .string(UUID().uuidString.lowercased());XCTAssertThrowsError(try TeamCompletionDraft.Retirement(invalid,for:header))
        }
        var invalid=raw;invalid["generation_unavailable"] = .bool(false);XCTAssertThrowsError(try TeamCompletionDraft.Retirement(invalid,for:header))
        invalid=raw;var row=raw["current_proposed"]!.object;row["task_generation"]=header.teamCompletion!.proposed!["task_generation"];invalid["current_proposed"] = .object(row)
        XCTAssertThrowsError(try TeamCompletionDraft.Retirement(invalid,for:header))
        invalid=raw;var review=raw["review"]!.object;review["state"] = .string("unrecorded");review["receipt"] = .null;invalid["review"] = .object(review)
        XCTAssertThrowsError(try TeamCompletionDraft.Retirement(invalid,for:header))
    }
    func testMixedBatchesRootEditsAndCompoundHistoryStayQueuedForReview() throws {
        let(header,_,raw)=try retirementFixture(),proof=try TeamCompletionDraft.Retirement(raw,for:header),command=header.teamCompletion!
        let deletion=Mutation(table:"tasks",recordID:command.proposed!.id,method:"DELETE",fields:[:])
        let batch=TeamTaskBatch.header(TeamTaskBatch(account:command.scope.account,origin:origin,team:command.scope.team,operation:.delete,restores:nil,items:[deletion]))
        let root=Mutation(table:"tasks",recordID:header.recordID,method:"PATCH",fields:["title":.string("Related root work")])
        for related in [batch,root,try command.inverse(of:header)] {
            var local=try editedDraftSnapshot(header);local.pending.append(related);let exact=local
            XCTAssertNil(TeamCompletionDraft.Candidate(review:proof.review,snapshot:local));XCTAssertEqual(local,exact)
        }
    }
    func testDeletedProvisionalDraftPreservesLastEditedRowAndDeletionIntent() throws {
        let(header,_,raw)=try retirementFixture(),proof=try TeamCompletionDraft.Retirement(raw,for:header),command=header.teamCompletion!
        var local=try editedDraftSnapshot(header);let row=try XCTUnwrap(local.tables["tasks"]?.first{$0.id == command.proposed!.id})
        let deletion=Mutation(table:"tasks",recordID:row.id,method:"DELETE",fields:[:],baseline:row.fields,teamTaskScope:command.scope)
        local.apply(deletion);local.pending.append(deletion)
        let candidate=try XCTUnwrap(TeamCompletionDraft.Candidate(review:proof.review,snapshot:local)),parked=try XCTUnwrap(candidate.parking(local,proof:proof))
        XCTAssertTrue(candidate.draft.markedForDeletion);XCTAssertEqual(candidate.draft.record,row);XCTAssertEqual(candidate.draft.edits.last,deletion)
        XCTAssertEqual(parked.tables["tasks"]?.first{$0.id == row.id},proof.currentProposed);XCTAssertTrue(parked.pending.isEmpty)
    }
    func testNewEditsDuringRetirementCannotBeDroppedFromSnapshot() throws {
        let(header,_,raw)=try retirementFixture(),proof=try TeamCompletionDraft.Retirement(raw,for:header)
        var local=try editedDraftSnapshot(header);let candidate=try XCTUnwrap(TeamCompletionDraft.Candidate(review:proof.review,snapshot:local))
        local.tables["tasks"]?[1]["description"] = .string("New work after draft was saved")
        let exact=local;XCTAssertNil(candidate.parking(local,proof:proof));XCTAssertEqual(local,exact)
        local=try editedDraftSnapshot(header);local.tables["tasks"]?[0]["description"] = .string("Unexplained root draft")
        XCTAssertNil(TeamCompletionDraft.Candidate(review:proof.review,snapshot:local))
    }
    func testUnknownOrForeignCommentIntentsCannotBeDiscarded() throws {
        let(header,_,raw)=try retirementFixture(),proof=try TeamCompletionDraft.Retirement(raw,for:header)
        var local=try editedDraftSnapshot(header)
        local.tables[ConversationOutbox.table]![0]["account"] = .string(UUID().uuidString.lowercased())
        XCTAssertNil(TeamCompletionDraft.Candidate(review:proof.review,snapshot:local))
        local=try editedDraftSnapshot(header);var intent=local.tables[ConversationOutbox.table]![0]["intent"].object;intent["kind"] = .string("future-comment-protocol")
        local.tables[ConversationOutbox.table]![0]["intent"] = .object(intent)
        XCTAssertNil(TeamCompletionDraft.Candidate(review:proof.review,snapshot:local))
    }
    func testDraftVaultIsEncryptedScopedAndDeduplicatesRetry() throws {
        let(header,_,raw)=try retirementFixture(),proof=try TeamCompletionDraft.Retirement(raw,for:header),local=try editedDraftSnapshot(header)
        let draft=try XCTUnwrap(TeamCompletionDraft.Candidate(review:proof.review,snapshot:local)).draft
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-draft-vault-"+UUID().uuidString,isDirectory:true);defer{try? FileManager.default.removeItem(at:directory)}
        let key=SymmetricKey(size:.bits256),vault=draftVault(draft,directory:directory,key:key)
        XCTAssertEqual(try vault.save(draft),draft);XCTAssertEqual(try vault.load(draft.id),draft)
        XCTAssertFalse(String(decoding:try Data(contentsOf:vault.file(draft.id)),as:UTF8.self).contains(draft.record.title))
        let same=TeamCompletionDraft(version:draft.version,id:UUID(),createdAt:Date().addingTimeInterval(30),original:draft.original,record:draft.record,markedForDeletion:draft.markedForDeletion,edits:draft.edits,conversations:draft.conversations)
        XCTAssertEqual(try vault.save(same).id,draft.id);XCTAssertEqual(try vault.entries().count,1)
        var wrong=vault;wrong=TeamCompletionDraftVault(directory:directory,account:draft.scope.account,origin:"https://other.example",key:{key});XCTAssertThrowsError(try wrong.load(draft.id))
        wrong=TeamCompletionDraftVault(directory:directory,account:UUID().uuidString.lowercased(),origin:origin,key:{key});XCTAssertThrowsError(try wrong.load(draft.id))
        let different=SymmetricKey(size:.bits256);wrong=TeamCompletionDraftVault(directory:directory,account:draft.scope.account,origin:origin,key:{different});XCTAssertThrowsError(try wrong.load(draft.id))
    }
    func testRecoveryRotationCannotEvictDraftButAccountVaultRemovalIncludesIt() throws {
        let(header,_,raw)=try retirementFixture(),proof=try TeamCompletionDraft.Retirement(raw,for:header),local=try editedDraftSnapshot(header)
        let draft=try XCTUnwrap(TeamCompletionDraft.Candidate(review:proof.review,snapshot:local)).draft
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-draft-removal-"+UUID().uuidString,isDirectory:true);defer{try? FileManager.default.removeItem(at:root)}
        let key=SymmetricKey(size:.bits256),own=root.appendingPathComponent("own"),other=root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true);try Data("Other account".utf8).write(to:other.appendingPathComponent("untouched"))
        let vault=draftVault(draft,directory:own.appendingPathComponent("Team drafts"),key:key)
        try vault.save(draft);var backup=BackupVault(directory:own,account:draft.scope.account,key:{key});backup.retention=1
        _=try backup.save(local,kind:"Before review");_=try backup.save(local,kind:"Manual")
        XCTAssertEqual(try vault.load(draft.id),draft);try backup.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath:vault.file(draft.id).path));XCTAssertEqual(try Data(contentsOf:other.appendingPathComponent("untouched")),Data("Other account".utf8))
    }
    func testDraftShelfNeverSilentlyExpiresOrEvictsOlderWork() throws {
        let(header,_,raw)=try retirementFixture(),proof=try TeamCompletionDraft.Retirement(raw,for:header)
        let draft=try XCTUnwrap(TeamCompletionDraft.Candidate(review:proof.review,snapshot:editedDraftSnapshot(header))).draft
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-draft-limit-"+UUID().uuidString,isDirectory:true);defer{try? FileManager.default.removeItem(at:directory)}
        let vault=draftVault(draft,directory:directory,key:SymmetricKey(size:.bits256))
        var first:TeamCompletionDraft?
        for n in 0..<20 {var record=draft.record;record["title"] = .string("Preserved draft "+String(n));let copy=TeamCompletionDraft(version:1,id:UUID(),createdAt:Date(timeIntervalSince1970:Double(n)),original:draft.original,record:record,markedForDeletion:false,edits:draft.edits,conversations:draft.conversations);try vault.save(copy);if n==0 {first=copy}}
        XCTAssertThrowsError(try vault.save(draft));XCTAssertEqual(try vault.entries().count,20);XCTAssertEqual(try vault.load(first!.id),first)
        try vault.remove(first!.id);XCTAssertEqual(try vault.entries().count,19);try vault.save(draft);XCTAssertEqual(try vault.entries().count,20)
    }
    func testDefaultSharedTextOmitsSupersededPrivateTextButHistoryIsRetained() throws {
        let(header,_,raw)=try retirementFixture(),proof=try TeamCompletionDraft.Retirement(raw,for:header),command=header.teamCompletion!
        var local=try editedDraftSnapshot(header)
        var first=local.pending[1];first.fields["description"] = .string("Earlier confidential scratch text");local.pending.insert(first,at:1);local.pending[1].id=UUID()
        let draft=try XCTUnwrap(TeamCompletionDraft.Candidate(review:proof.review,snapshot:local)).draft
        XCTAssertFalse(draft.text.contains("Earlier confidential scratch text"));XCTAssertTrue(draft.historyText.contains("Earlier confidential scratch text"))
        XCTAssertTrue(draft.text.contains("Keep every edited instruction"));XCTAssertEqual(draft.record["task_generation"],command.proposed?["task_generation"])
    }
    @MainActor func testRetirementTransportBindsOriginalBodyAndBoundsProof() async throws {
        let(header,body,reply)=try retirementFixture(),api=try backend(header.teamCompletion!.scope.account)
        var requests:[URLRequest]=[]
        CompletionHTTP.handler={request,peer in requests.append(request);peer.finish(try! JSONEncoder().encode(reply))};defer{CompletionHTTP.handler=nil}
        let proof=try await api.retireTeamProvisional(header,expectedAccount:header.teamCompletion!.scope.account)
        XCTAssertTrue(proof.review.isRecorded);XCTAssertEqual(requests.count,1)
        let request=try XCTUnwrap(requests.first);XCTAssertEqual(request.url?.path,"/rest/v1/rpc/taskfold_retire_team_provisional");XCTAssertEqual(request.timeoutInterval,25);XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.value(forHTTPHeaderField:"Cache-Control"),"no-store");XCTAssertEqual(try JSONDecoder().decode([String:JSON].self,from:XCTUnwrap(request.httpBody))["_body"],.object(body))
        do{_=try await api.retireTeamProvisional(header,expectedAccount:UUID().uuidString.lowercased());XCTFail("Wrong account retirement")}catch{XCTAssertTrue(error is CancellationError)}
        CompletionHTTP.handler={_,peer in peer.finish(Data(repeating:32,count:2_000_001))}
        do{_=try await api.retireTeamProvisional(header,expectedAccount:header.teamCompletion!.scope.account);XCTFail("Oversized retirement")}catch{XCTAssertTrue(error.localizedDescription.contains("too large"))}
    }

    func testDraftParkingDoesNotInventWorkForUntouchedOrLiveOwnOccurrences() throws {
        let(header,_,raw)=try retirementFixture(),proof=try TeamCompletionDraft.Retirement(raw,for:header)
        XCTAssertNil(TeamCompletionDraft.Candidate(review:proof.review,snapshot:projected(header)))
        let(own,_,reply)=try cancellationFixture(recorded:true),review=try TeamCompletion.Review(reply,for:own)
        let ownLocal=try editedDraftSnapshot(own);XCTAssertNil(TeamCompletionDraft.Candidate(review:review,snapshot:ownLocal))
    }
    func testDraftVaultRejectsOversizeAndTamperingWithoutEvictingSavedWork() throws {
        let(header,_,raw)=try retirementFixture(),proof=try TeamCompletionDraft.Retirement(raw,for:header)
        let draft=try XCTUnwrap(TeamCompletionDraft.Candidate(review:proof.review,snapshot:editedDraftSnapshot(header))).draft
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-draft-integrity-"+UUID().uuidString,isDirectory:true);defer{try? FileManager.default.removeItem(at:directory)}
        let vault=draftVault(draft,directory:directory,key:SymmetricKey(size:.bits256));try vault.save(draft)
        var large=draft.record;large["description"] = .string(String(repeating:"x",count:16_000_001))
        let oversized=TeamCompletionDraft(version:1,id:UUID(),createdAt:Date(),original:draft.original,record:large,markedForDeletion:false,edits:draft.edits,conversations:draft.conversations)
        XCTAssertThrowsError(try vault.save(oversized));XCTAssertEqual(try vault.entries(),[draft])
        var bytes=try Data(contentsOf:vault.file(draft.id));bytes[bytes.count-1] ^= 1;try bytes.write(to:vault.file(draft.id))
        XCTAssertThrowsError(try vault.load(draft.id));XCTAssertThrowsError(try vault.entries())
        XCTAssertTrue(FileManager.default.fileExists(atPath:vault.file(draft.id).path))
    }

}
