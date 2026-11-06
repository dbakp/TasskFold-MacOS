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

    private func draftCopyFixture() throws -> (TeamCompletionDraft,TeamCompletionDraft.CopyCommand,[String:JSON]) {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"team-draft-copy-v1",withExtension:"json",subdirectory:"Fixtures"))
        let root=try JSONDecoder().decode([String:JSON].self,from:Data(contentsOf:url)),body=root["body"]!.object,original=body["original"]!.object
        let source=Record(original["record"]!.object),id=try XCTUnwrap(UUID(uuidString:original["request_id"]!.text))
        let scope=TeamTaskEditScope(account:root["account"]!.text,origin:origin,team:original["team_id"]!.text,project:original["project_id"]!.text)
        let forecast=try TeamCompletion.complete(source,tasks:[source],scope:scope,at:TaskPlanning.instant(original["completed_at"]!.text)!,zone:original["input_zone"]!.text,id:id)
        var proposed=forecast.teamCompletion!.proposed;proposed?["task_generation"]=original["next_generation"]!
        let command=TeamCompletion(scope:scope,operation:.complete,source:source,completedAt:original["completed_at"]!.text,inputZone:original["input_zone"]!.text,seriesID:original["series_id"]!.text,seriesGeneration:original["series_generation"]!.text,seriesProject:original["series_project_id"]!.text,nextGeneration:original["next_generation"]!.text,proposed:proposed,related:nil)
        let draft=TeamCompletionDraft(version:1,id:UUID(),createdAt:Date(timeIntervalSince1970:1792830000),original:TeamCompletion.header(command,id:id),record:Record(body["record"]!.object),markedForDeletion:false,edits:[],conversations:[])
        let copy=TeamCompletionDraft.CopyCommand(assignments:body["copy_assignments"]!.flag,reminders:body["copy_reminders"]!.flag,requestID:UUID(uuidString:body["request_id"]!.text)!,taskID:UUID(uuidString:body["task_id"]!.text)!,generation:UUID(uuidString:body["task_generation"]!.text)!)
        return(draft,copy,root)
    }
    func testSavedDraftCopyMatchesActualSQLRequestAndFreshReceipt() throws {
        let(draft,command,fixture)=try draftCopyFixture()
        XCTAssertEqual(try command.body(for:draft),fixture["body"]!.object)
        let preview=try TeamCompletionDraft.CopyReview(fixture["preview"]!.object,draft:draft,command:command)
        XCTAssertFalse(preview.recorded);XCTAssertNil(preview.installing(in:Snapshot()))
        let created=try TeamCompletionDraft.CopyReview(fixture["created"]!.object,draft:draft,command:command)
        XCTAssertTrue(created.recorded);XCTAssertFalse(created.replayed)
        XCTAssertEqual(created.task?["attachments"],draft.record["attachments"])
        XCTAssertEqual(created.task?["source_metadata"].object["future"],draft.record["source_metadata"].object["future"])
        XCTAssertEqual(created.task?["subtasks"].list.first?.object["description"],draft.record["subtasks"].list.first?.object["description"])
        XCTAssertEqual(created.task?["recurrence_parent_id"],.null)
        let local=Snapshot(tables:["projects":[Record(["id":.string(draft.scope.project)])],"tasks":[draft.original.teamCompletion!.source]])
        let installed=try XCTUnwrap(created.installing(in:local))
        XCTAssertEqual(installed.tables["tasks"]?.count,2);XCTAssertEqual(installed.tables["tasks"]?.first,local.tables["tasks"]?.first)
        XCTAssertTrue(installed.pending.isEmpty);XCTAssertEqual(local.tables["tasks"]?.count,1)
    }
    func testSavedDraftCopyRejectsWrongScopeIdentityAndChoiceReceipts() throws {
        let(draft,command,fixture)=try draftCopyFixture(),reply=fixture["created"]!.object
        for key in ["account","team_id","project_id","original_request_id","request_id","task_id","task_generation"] {
            var bad=reply;bad[key] = .string(UUID().uuidString.lowercased())
            XCTAssertThrowsError(try TeamCompletionDraft.CopyReview(bad,draft:draft,command:command),key)
        }
        for key in ["copy_assignments","copy_reminders"] {
            var bad=reply;bad[key] = .bool(true)
            XCTAssertThrowsError(try TeamCompletionDraft.CopyReview(bad,draft:draft,command:command),key)
        }
        for key in ["recorded","replayed","unavailable","cancelled"] {
            var bad=reply;bad[key] = .string("true")
            XCTAssertThrowsError(try TeamCompletionDraft.CopyReview(bad,draft:draft,command:command),key)
        }
        var bad=fixture["preview"]!.object;bad["replayed"] = .bool(true)
        XCTAssertThrowsError(try TeamCompletionDraft.CopyReview(bad,draft:draft,command:command))
        bad=reply;bad["task"] = .null
        XCTAssertThrowsError(try TeamCompletionDraft.CopyReview(bad,draft:draft,command:command))
    }
    func testSavedDraftCopyCannotClaimOldRootOrChildCompletionHistoryAsFresh() throws {
        let(draft,command,fixture)=try draftCopyFixture(),reply=fixture["created"]!.object
        for (key,value) in [("completion_version",JSON.number(5)),("recurrence_parent_id",JSON.string(draft.record.id)),("comments",JSON.array([.string("old discussion")])),("notification_sent_at",JSON.string("2026-10-24T12:00:00Z"))] {
            var bad=reply,task=reply["task"]!.object;task[key]=value;bad["task"] = .object(task)
            XCTAssertThrowsError(try TeamCompletionDraft.CopyReview(bad,draft:draft,command:command),key)
        }
        var bad=reply,task=reply["task"]!.object,child=task["subtasks"]!.list[0].object
        child["taskfold_completion_v1"] = .object(["epoch":.string("wrong"),"version":.number(0)])
        task["subtasks"] = .array([.object(child)]);bad["task"] = .object(task)
        XCTAssertThrowsError(try TeamCompletionDraft.CopyReview(bad,draft:draft,command:command))
    }
    func testSavedDraftCopyRetryAcceptsCurrentEditedRowAndUnavailableDeletion() throws {
        let(draft,command,fixture)=try draftCopyFixture()
        let edited=try TeamCompletionDraft.CopyReview(fixture["editedReplay"]!.object,draft:draft,command:command)
        XCTAssertTrue(edited.replayed);XCTAssertEqual(edited.task?.string("description"),"Another edit after creation")
        let unavailable=try TeamCompletionDraft.CopyReview(fixture["unavailableReplay"]!.object,draft:draft,command:command)
        XCTAssertTrue(unavailable.recorded);XCTAssertNil(unavailable.task)
        let local=Snapshot(tables:["tasks":[draft.record]])
        XCTAssertEqual(unavailable.installing(in:local),local)
    }
    func testSavedDraftCopyInstallationNeverOverwritesNewLocalWorkOrGeneration() throws {
        let(draft,command,fixture)=try draftCopyFixture(),review=try TeamCompletionDraft.CopyReview(fixture["created"]!.object,draft:draft,command:command)
        var local=Snapshot(tables:["projects":[Record(["id":.string(draft.scope.project)])],"tasks":[review.task!]])
        local.tables["tasks"]![0]["description"] = .string("New local instructions")
        let before=local;XCTAssertNil(review.installing(in:local));XCTAssertEqual(local,before)
        local.tables["tasks"]![0]["task_generation"] = .string(UUID().uuidString.lowercased())
        XCTAssertNil(review.installing(in:local))
        local.tables["tasks"]=[]
        let deletion=Mutation(table:"tasks",recordID:command.taskID.uuidString.lowercased(),method:"DELETE",fields:[:])
        local.pending=[deletion];XCTAssertNil(review.installing(in:local));XCTAssertEqual(local.pending,[deletion])
        local.pending=[];local.tables.removeValue(forKey:"projects");XCTAssertNil(review.installing(in:local))
    }
    func testSavedDraftCopyPreservesIndependentQueueAndProtectsCommentOutbox() throws {
        let(draft,command,fixture)=try draftCopyFixture(),review=try TeamCompletionDraft.CopyReview(fixture["created"]!.object,draft:draft,command:command)
        let independent=Mutation(table:"labels",recordID:UUID().uuidString.lowercased(),method:"POST",fields:["name":.string("Independent work")])
        var local=Snapshot(tables:["projects":[Record(["id":.string(draft.scope.project)])]],pending:[independent]);local.apply(independent)
        let installed=try XCTUnwrap(review.installing(in:local))
        XCTAssertEqual(installed.pending,[independent]);XCTAssertEqual(installed.tables["labels"],local.tables["labels"])
        let comment=try SharedCommentChange(account:draft.scope.account,taskID:command.taskID.uuidString.lowercased(),taskGeneration:command.generation.uuidString.lowercased(),projectID:draft.scope.project,body:"Queued comment")
        try ConversationOutbox.enqueue(comment.record,into:&local)
        XCTAssertNil(review.installing(in:local));XCTAssertNotNil(local.tables[ConversationOutbox.table]?.first)
    }
    func testSavedDraftCopyCommandUsesFreshIdentitiesAndBoundedFullContent() throws {
        let(draft,command,_)=try draftCopyFixture()
        let invalid=[TeamCompletionDraft.CopyCommand(requestID:draft.original.id),TeamCompletionDraft.CopyCommand(taskID:UUID(uuidString:draft.record.id)!),TeamCompletionDraft.CopyCommand(generation:UUID(uuidString:draft.record.string("task_generation"))!),TeamCompletionDraft.CopyCommand(taskID:UUID(uuidString:"00000000-0000-0000-0000-000000000000")!)]
        for value in invalid {XCTAssertThrowsError(try value.body(for:draft))}
        var large=draft.record;large["description"] = .string(String(repeating:"x",count:900001))
        let huge=TeamCompletionDraft(version:1,id:UUID(),createdAt:Date(),original:draft.original,record:large,markedForDeletion:false,edits:[],conversations:[])
        XCTAssertThrowsError(try command.body(for:huge))
    }
    func testSavedDraftCopyAttemptSurvivesEncryptedRelaunchAndCannotChangeChoices() throws {
        let(draft,command,_)=try draftCopyFixture(),directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let vault=draftVault(draft,directory:directory,key:SymmetricKey(size:.bits256));try vault.save(draft)
        let prepared=try vault.prepareCopy(draft,command:command),reloaded=try vault.load(draft.id)
        XCTAssertEqual(prepared.copyAttempt,command);XCTAssertEqual(reloaded,prepared)
        XCTAssertEqual(try command.body(for:reloaded),try command.body(for:draft))
        XCTAssertEqual(try vault.prepareCopy(draft,command:command),prepared)
        let before=try Data(contentsOf:vault.file(draft.id))
        XCTAssertThrowsError(try vault.prepareCopy(draft,command:TeamCompletionDraft.CopyCommand(assignments:true)))
        XCTAssertEqual(try Data(contentsOf:vault.file(draft.id)),before)
        XCTAssertEqual(try vault.save(draft).copyAttempt,command)
        XCTAssertEqual(try vault.entries().count,1)
        XCTAssertFalse(before.range(of:Data(draft.record.title.utf8)) != nil)
        var older=try JSONDecoder().decode([String:JSON].self,from:JSONEncoder().encode(draft));older.removeValue(forKey:"copyAttempt")
        XCTAssertNil(try JSONDecoder().decode(TeamCompletionDraft.self,from:JSONEncoder().encode(older)).copyAttempt)
    }
    func testSavedDraftCopyAttemptRequiresExistingUnchangedArchive() throws {
        let(draft,command,_)=try draftCopyFixture(),directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let vault=draftVault(draft,directory:directory,key:SymmetricKey(size:.bits256))
        XCTAssertThrowsError(try vault.prepareCopy(draft,command:command))
        try vault.save(draft)
        var record=draft.record;record["title"] = .string("Unexpected archive change")
        let changed=TeamCompletionDraft(version:1,id:draft.id,createdAt:draft.createdAt,original:draft.original,record:record,markedForDeletion:false,edits:[],conversations:[])
        XCTAssertThrowsError(try vault.prepareCopy(changed,command:command));XCTAssertNil(try vault.load(draft.id).copyAttempt)
    }
    @MainActor func testSavedDraftCopyBackendBindsAccountChoicesAndReadOnlyPreview() async throws {
        let(draft,command,fixture)=try draftCopyFixture(),backend=try backend(draft.scope.account)
        var requests:[URLRequest]=[]
        CompletionHTTP.handler={request,peer in requests.append(request);peer.finish(try! JSONEncoder().encode(fixture["preview"]!))};defer{CompletionHTTP.handler=nil}
        let review=try await backend.copyTeamDraft(draft,command:command,commit:false,expectedAccount:draft.scope.account)
        XCTAssertFalse(review.recorded)
        let request=try XCTUnwrap(requests.first),body=try JSONDecoder().decode([String:JSON].self,from:XCTUnwrap(request.httpBody))
        XCTAssertEqual(request.url?.path,"/rest/v1/rpc/taskfold_copy_team_draft");XCTAssertEqual(body["_commit"],.bool(false));XCTAssertEqual(body["_body"]?.object,try command.body(for:draft))
        XCTAssertEqual(request.value(forHTTPHeaderField:"Cache-Control"),"no-store");XCTAssertFalse(request.httpShouldHandleCookies)
        do {_=try await backend.copyTeamDraft(draft,command:command,commit:false,expectedAccount:UUID().uuidString.lowercased());XCTFail("foreign account")}catch{}
        XCTAssertEqual(requests.count,1)
        do {_=try await backend.copyTeamDraft(draft,command:command,commit:true,expectedAccount:draft.scope.account);XCTFail("commit requires recorded receipt")}catch{}
    }
    @MainActor func testSavedDraftCopyBackendCapsResponsesAndDoesNotReflectServerText() async throws {
        let(draft,command,_)=try draftCopyFixture(),backend=try backend(draft.scope.account)
        CompletionHTTP.handler={_,peer in peer.finish(Data(repeating:32,count:2_000_001))};defer{CompletionHTTP.handler=nil}
        do {_=try await backend.copyTeamDraft(draft,command:command,commit:false,expectedAccount:draft.scope.account);XCTFail("oversize")}catch{}
        CompletionHTTP.handler={_,peer in peer.finish(Data("{\"code\":\"22023\",\"message\":\"do not reflect this secret\"}".utf8),status:400)}
        do {_=try await backend.copyTeamDraft(draft,command:command,commit:false,expectedAccount:draft.scope.account);XCTFail("server refusal")}catch {XCTAssertFalse(error.localizedDescription.contains("do not reflect"))}
    }

    func testSavedDraftCopyPreviewBindsEveryAuthoredFieldBeforeConfirmation() throws {
        let(draft,command,fixture)=try draftCopyFixture(),review=try TeamCompletionDraft.CopyReview(fixture["preview"]!.object,draft:draft,command:command)
        XCTAssertTrue(review.matches(draft))
        var changed=draft.record;changed["description"] = .string("Content changed after preview")
        let other=TeamCompletionDraft(version:1,id:draft.id,createdAt:draft.createdAt,original:draft.original,record:changed,markedForDeletion:false,edits:[],conversations:[])
        XCTAssertFalse(review.matches(other))
        var prepared=draft;prepared.copyAttempt=command
        XCTAssertTrue(review.matches(prepared))
    }

    func testFreshSavedDraftCopyProofHonorsChoicesAndCannotInventChecklistHistory() throws {
        let(draft,command,fixture)=try draftCopyFixture(),reply=fixture["created"]!.object
        for (key,value) in [("assigned_to",JSON.string(draft.scope.account)),("reminder_specs",JSON.array([.object(["kind":.string("location")])]))] {
            var bad=reply,task=reply["task"]!.object;task[key]=value;bad["task"] = .object(task)
            XCTAssertThrowsError(try TeamCompletionDraft.CopyReview(bad,draft:draft,command:command))
        }
        var bad=reply,task=reply["task"]!.object,child=task["subtasks"]!.list[0].object
        child["taskfold_completion_v1"] = .object(["epoch":.string(UUID().uuidString.lowercased()),"version":.number(0)])
        task["subtasks"] = .array([.object(child)]);bad["task"] = .object(task)
        XCTAssertThrowsError(try TeamCompletionDraft.CopyReview(bad,draft:draft,command:command))
    }

    func testAccountRemovalStopsDelayedSavedDraftCopyPreparation() throws {
        let(draft,command,_)=try draftCopyFixture(),directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let gate=AccountRemovalDisk(directory:directory,account:draft.scope.account)
        var vault=draftVault(draft,directory:directory.appendingPathComponent("drafts"),key:SymmetricKey(size:.bits256));vault.removalGate=gate
        try vault.save(draft);let before=try Data(contentsOf:vault.file(draft.id))
        try gate.removeCache()
        XCTAssertThrowsError(try vault.prepareCopy(draft,command:command))
        XCTAssertEqual(try Data(contentsOf:vault.file(draft.id)),before)
        XCTAssertNil(try vault.load(draft.id).copyAttempt)
    }

    private func cancelledDraftCopyFixture() throws -> (TeamCompletionDraft,TeamCompletionDraft.CopyCommand,[String:JSON]) {
        let(draft,_,root)=try draftCopyFixture(),body=root["cancelBody"]!.object
        let command=TeamCompletionDraft.CopyCommand(assignments:body["copy_assignments"]!.flag,reminders:body["copy_reminders"]!.flag,requestID:UUID(uuidString:body["request_id"]!.text)!,taskID:UUID(uuidString:body["task_id"]!.text)!,generation:UUID(uuidString:body["task_generation"]!.text)!)
        XCTAssertEqual(try command.body(for:draft),body)
        return(draft,command,root["cancelledCopy"]!.object)
    }
    func testSavedDraftCopyCancellationIsDistinctFromCreationOrUnavailableCopy() throws {
        let(draft,command,reply)=try cancelledDraftCopyFixture()
        let cancelled=try TeamCompletionDraft.CopyReview(reply,draft:draft,command:command)
        XCTAssertTrue(cancelled.cancelled);XCTAssertFalse(cancelled.recorded);XCTAssertNil(cancelled.task)
        XCTAssertNil(cancelled.installing(in:Snapshot()))
        var bad=reply;bad["recorded"] = .bool(true)
        XCTAssertThrowsError(try TeamCompletionDraft.CopyReview(bad,draft:draft,command:command))
        bad=reply;bad["unavailable"] = .bool(false)
        XCTAssertThrowsError(try TeamCompletionDraft.CopyReview(bad,draft:draft,command:command))
    }
    func testSavedDraftCopyCanChangeChoicesOnlyAfterBoundDurableCancellation() throws {
        let(draft,command,reply)=try cancelledDraftCopyFixture(),proof=try TeamCompletionDraft.CopyReview(reply,draft:draft,command:command)
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let vault=draftVault(draft,directory:directory,key:SymmetricKey(size:.bits256));try vault.save(draft)
        let saved=try vault.prepareCopy(draft,command:command)
        XCTAssertThrowsError(try vault.prepareCopy(draft,command:TeamCompletionDraft.CopyCommand()))
        try vault.clearCopyAttempt(saved,proof:proof)
        let cleared=try vault.load(draft.id);XCTAssertNil(cleared.copyAttempt);XCTAssertTrue(cleared.sameWork(as:draft))
        let new=TeamCompletionDraft.CopyCommand(assignments:false,reminders:false)
        XCTAssertEqual(try vault.prepareCopy(cleared,command:new).copyAttempt,new)
        XCTAssertThrowsError(try vault.clearCopyAttempt(saved,proof:proof))
        XCTAssertEqual(try vault.load(draft.id).copyAttempt,new)
    }
    func testRecordedCopyProofCannotReleaseItsRequestForDuplicateCreation() throws {
        let(draft,command,fixture)=try draftCopyFixture(),proof=try TeamCompletionDraft.CopyReview(fixture["created"]!.object,draft:draft,command:command)
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let vault=draftVault(draft,directory:directory,key:SymmetricKey(size:.bits256));try vault.save(draft)
        let saved=try vault.prepareCopy(draft,command:command)
        XCTAssertThrowsError(try vault.clearCopyAttempt(saved,proof:proof))
        XCTAssertEqual(try vault.load(draft.id).copyAttempt,command)
    }
    @MainActor func testSavedDraftCopyCancellationTransportRequiresDurableOutcome() async throws {
        let(draft,command,reply)=try cancelledDraftCopyFixture(),backend=try backend(draft.scope.account)
        var request:URLRequest?
        CompletionHTTP.handler={incoming,peer in request=incoming;peer.finish(try! JSONEncoder().encode(reply))};defer{CompletionHTTP.handler=nil}
        let proof=try await backend.copyTeamDraft(draft,command:command,commit:false,cancel:true,expectedAccount:draft.scope.account)
        XCTAssertTrue(proof.cancelled)
        let body=try JSONDecoder().decode([String:JSON].self,from:XCTUnwrap(request?.httpBody))
        XCTAssertEqual(body["_cancel"],.bool(true));XCTAssertEqual(body["_commit"],.bool(false));XCTAssertEqual(body["_body"]?.object,try command.body(for:draft))
        do {_=try await backend.copyTeamDraft(draft,command:command,commit:true,cancel:true,expectedAccount:draft.scope.account);XCTFail("contradictory action")}catch{}
    }

    func testCopiedTaskWithRemindersOffCannotFallBackToAutomaticPlannedAlert() throws {
        let(draft,command,fixture)=try draftCopyFixture(),review=try TeamCompletionDraft.CopyReview(fixture["created"]!.object,draft:draft,command:command)
        let task=try XCTUnwrap(review.task)
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"Europe/Copenhagen")!
        XCTAssertTrue(DueReminder.events(tasks:[task],calendar:calendar).isEmpty)
        var fallback=task;fallback["reminder_specs"] = .array([])
        XCTAssertFalse(DueReminder.events(tasks:[fallback],calendar:calendar).isEmpty)
    }

}

extension TeamCompletionTests {
    private func recoveryAccess(_ header: Mutation, local: Snapshot, role: String = "viewer", archived: Bool = false, paused: Bool = false, reads: Bool = true, active: Bool = true, missing: Set<String> = [], account: String? = nil, origin: String? = nil) throws -> TeamWorkspaceCache {
        let command = header.teamCompletion!, owner = account ?? command.scope.account
        let projects = Set((local.tables["projects"] ?? []).map(\.id)).subtracting(missing).sorted()
        let raw: [String: JSON] = ["workspace_boundary_protocol": .number(1), "account": .string(owner), "native_team_reads_enabled": .bool(reads), "setup_paused": .bool(paused), "token": .string(String(repeating: "d", count: 64)),
            "teams": .array(reads ? [.object(["id": .string(command.scope.team), "state": .string(active ? "active" : "archived"), "revision": .number(1), "access_revision": .number(3)])] : []),
            "projects": .array(reads ? projects.map { .object(["id": .string($0), "team_id": .string(command.scope.team), "role": .string(role), "archived": .bool(archived), "can_send_tasks": .bool(role != "viewer" && !archived && !paused && active)]) } : [])]
        return try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(raw, account: owner, origin: origin ?? command.scope.origin), previous: local.teamWorkspace, pending: local.pending, tasks: local.tables["tasks"] ?? [])
    }
    private func recoveryProjection(_ header: Mutation) -> Snapshot {
        var local = snapshot(header)
        if header.teamCompletion!.operation == .undo {
            local.tables["tasks"] = [TaskCompletionRevision.applying(["completed": .bool(true), "completed_at": .string(header.teamCompletion!.completedAt)], to: header.teamCompletion!.source)] + [header.teamCompletion!.proposed].compactMap { $0 }
        }
        local.apply(header); local.pending = [header]; return local
    }
    func testSingleColdDiscoveryRequiresBlockedExactReadableHead() throws {
        let (header, _, raw) = try reviewFixture(), review = try TeamCompletion.Review(raw, for: header), local = recoveryProjection(header)
        for mode in ["viewer", "archived", "paused"] {
            let access = try recoveryAccess(header, local: local, role: mode == "viewer" ? "viewer" : "editor", archived: mode == "archived", paused: mode == "paused")
            let request = try XCTUnwrap(TeamCompletionDiscovery(snapshot: local, access: access))
            XCTAssertEqual(request.mutation, header); XCTAssertEqual(request.terminal(review, current: local, readable: access), review)
            XCTAssertEqual(local.pending, [header]); XCTAssertEqual(request.snapshot, local)
        }
        XCTAssertNil(TeamCompletionDiscovery(snapshot: local, access: try recoveryAccess(header, local: local, role: "editor")))
        for access in [try recoveryAccess(header, local: local, reads: false), try recoveryAccess(header, local: local, active: false), try recoveryAccess(header, local: local, missing: [header.teamCompletion!.scope.project]), try recoveryAccess(header, local: local, account: UUID().uuidString.lowercased()), try recoveryAccess(header, local: local, origin: "https://foreign.example")] {
            XCTAssertNil(TeamCompletionDiscovery(snapshot: local, access: access)); XCTAssertNil(review.acknowledging(local, readable: access))
        }
    }
    func testSingleColdDiscoveryRejectsUnrecordedAndLateContext() throws {
        let (header, _, raw) = try reviewFixture(), review = try TeamCompletion.Review(raw, for: header), local = recoveryProjection(header), access = try recoveryAccess(header, local: local)
        let request = try XCTUnwrap(TeamCompletionDiscovery(snapshot: local, access: access))
        let (_, _, unrecorded) = try reviewFixture(recorded: false)
        for state in ["unrecorded", "cancelled"] {
            var value = unrecorded; value["state"] = .string(state)
            let observed = try TeamCompletion.Review(value, for: header)
            XCTAssertEqual(request.terminal(observed, current: local, readable: access), state == "cancelled" ? observed : nil)
        }
        var changed = local; changed.tables["tasks"]![0]["title"] = .string("Newer local work")
        XCTAssertNil(request.terminal(review, current: changed, readable: access))
        changed = local; changed.pending.append(Mutation(table: "preferences", recordID: header.recordID, method: "PATCH", fields: ["name": .string("newer")]))
        XCTAssertNil(request.terminal(review, current: changed, readable: access))
        XCTAssertNil(request.terminal(review, current: local, readable: try recoveryAccess(header, local: local, paused: true)))
        let (undo, _, undoRaw) = try reviewFixture(undo: true)
        XCTAssertNil(request.terminal(try TeamCompletion.Review(undoRaw, for: undo), current: local, readable: access))
    }
    func testSingleColdDiscoveryRefusesMalformedUnrelatedAndDuplicateHeads() throws {
        let (header, _, _) = try reviewFixture(), local = recoveryProjection(header), access = try recoveryAccess(header, local: local)
        var changed = local; changed.pending = []; XCTAssertNil(TeamCompletionDiscovery(snapshot: changed, access: access))
        changed = local; changed.pending = [Mutation(table: "tasks", recordID: header.recordID, method: "PATCH", fields: ["title": .string("draft")]), header]
        XCTAssertNil(TeamCompletionDiscovery(snapshot: changed, access: access))
        changed = local; changed.pending = [header, header]; XCTAssertNil(TeamCompletionDiscovery(snapshot: changed, access: access))
        var bad = header; bad.fields = ["title": .string("tampered")]; changed = local; changed.pending = [bad]
        XCTAssertNil(TeamCompletionDiscovery(snapshot: changed, access: access))
    }
    func testRecordedSingleReadRecoveryPersistsCurrentRestrictionsAndTypedLaterEdits() throws {
        let (header, _, raw) = try reviewFixture(), review = try TeamCompletion.Review(raw, for: header), command = header.teamCompletion!
        var local = recoveryProjection(header)
        let row = try XCTUnwrap(local.tables["tasks"]?.first { $0.id == header.recordID })
        let fields: [String: JSON] = ["title": .string("Keep the later title"), "description": .string("Keep authored instructions")]
        let edit = try command.scope.capturing(Mutation(table: "tasks", recordID: row.id, method: "PATCH", fields: fields, baseline: TaskCompletionRevision.editBaseline(for: fields, from: row), teamTaskScope: command.scope), existing: row)
        local.apply(edit); local.pending.append(edit)
        local.teamWorkspace = try recoveryAccess(header, local: local, role: "editor")
        let before = local
        for mode in ["viewer", "archived", "paused"] {
            let access = try recoveryAccess(header, local: local, role: mode == "viewer" ? "viewer" : "editor", archived: mode == "archived", paused: mode == "paused")
            let next = try XCTUnwrap(review.acknowledging(local, readable: access))
            XCTAssertEqual(next.tables["projects"], local.tables["projects"])
            XCTAssertEqual(next.tables["tasks"]?.count, local.tables["tasks"]?.count)
            for row in local.tables["tasks"] ?? [] {
                let kept = try XCTUnwrap(next.tables["tasks"]?.first { $0.id == row.id })
                XCTAssertTrue(TeamCompletion.sameLocal(kept, row), "Only SQL date/time representation may differ")
                if row.id == edit.recordID { for (key, value) in fields { XCTAssertEqual(kept[key], value) } }
            }
            XCTAssertEqual(next.pending, [edit]); XCTAssertEqual(next.teamWorkspace?.boundary, access.boundary)
            XCTAssertFalse(try XCTUnwrap(next.teamWorkspace).canSend(edit, in: next)); XCTAssertEqual(local, before)
            XCTAssertEqual(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(next)), next)
        }
    }
    func testRecordedSingleReadRecoveryRetainsUndoRedoEnvelopeAndIndependentWork() throws {
        for undo in [false, true] {
            let (header, _, raw) = try reviewFixture(undo: undo), review = try TeamCompletion.Review(raw, for: header)
            var local = recoveryProjection(header)
            let independent = Mutation(table: "preferences", recordID: UUID().uuidString.lowercased(), method: "PATCH", fields: ["appearance": .string("dark")])
            local.pending.append(independent)
            let access = try recoveryAccess(header, local: local), request = try XCTUnwrap(TeamCompletionDiscovery(snapshot: local, access: access))
            XCTAssertEqual(request.terminal(review, current: local, readable: access), review)
            let next = try XCTUnwrap(review.acknowledging(local, readable: access))
            XCTAssertEqual(next.pending, [independent]); XCTAssertEqual(next.teamWorkspace?.boundary, access.boundary)
        }
        let (header, _, raw) = try reviewFixture(), review = try TeamCompletion.Review(raw, for: header)
        var local = snapshot(header)
        let undo = try XCTUnwrap(EditHistory(changes: [header], snapshot: local).undo.first); local.apply(header); local.pending = [header]
        let sentUndo = TeamCompletion.historyAction(undo, snapshot: local)
        let redo = try XCTUnwrap(EditHistory(changes: [sentUndo], snapshot: local).undo.first); local.apply(sentUndo); local.pending.append(sentUndo)
        let sentRedo = TeamCompletion.historyAction(redo, snapshot: local); local.apply(sentRedo); local.pending.append(sentRedo)
        let next = try XCTUnwrap(review.acknowledging(local, readable: try recoveryAccess(header, local: local)))
        XCTAssertEqual(next.pending, [sentUndo, sentRedo]); XCTAssertEqual(next.tables, local.tables)
    }
    func testSingleReadRecoveryRefusesLostCustodyMalformedAndForeignLaterEdits() throws {
        let (header, _, raw) = try reviewFixture(), review = try TeamCompletion.Review(raw, for: header)
        var local = recoveryProjection(header)
        local.teamWorkspace = try recoveryAccess(header, local: local, role: "editor")
        var encoded = try JSONDecoder().decode([String: JSON].self, from: JSONEncoder().encode(try XCTUnwrap(local.teamWorkspace)))
        encoded["knownTasks"] = .array(encoded["knownTasks"]!.list + [.string(UUID().uuidString.lowercased())])
        local.teamWorkspace = try JSONDecoder().decode(TeamWorkspaceCache.self, from: JSONEncoder().encode(encoded))
        var withoutMemory = local; withoutMemory.teamWorkspace = nil
        XCTAssertNil(review.acknowledging(local, readable: try recoveryAccess(header, local: withoutMemory)))
        local = recoveryProjection(header)
        for scope in [nil, TeamTaskEditScope(account: UUID().uuidString.lowercased(), origin: origin, team: header.teamCompletion!.scope.team, project: header.teamCompletion!.scope.project)] {
            var changed = local
            changed.pending.append(Mutation(table: "tasks", recordID: header.recordID, method: "PATCH", fields: ["title": .string("Keep this")], teamTaskScope: scope))
            let before = changed; XCTAssertNil(review.acknowledging(changed, readable: try recoveryAccess(header, local: changed))); XCTAssertEqual(changed, before)
        }
        local.pending.append(header); XCTAssertNil(review.acknowledging(local, readable: try recoveryAccess(header, local: local)))
    }
    func testSingleReadRecoveryPreservesCommentDraftOnDisplacedOccurrence() throws {
        let (header, _, raw) = try reviewFixture(); var reply = raw, receipt = raw["receipt"]!.object, row = raw["successor"]!.object
        let other = UUID().uuidString.lowercased(); row["task_generation"] = .string(other)
        receipt["successor"] = .object(row); receipt["successor_generation"] = .string(other); receipt["created_successor"] = .bool(false)
        reply["successor"] = .object(row); reply["receipt"] = .object(receipt)
        let review = try TeamCompletion.Review(reply, for: header); var local = recoveryProjection(header)
        local.tables[ConversationOutbox.table] = [Record(["id": .string(UUID().uuidString.lowercased()), "task_id": .string(header.teamCompletion!.proposed!.id), "text": .string("Keep my draft")])]
        let before = local; XCTAssertNil(review.acknowledging(local, readable: try recoveryAccess(header, local: local))); XCTAssertEqual(local, before)
        local.tables[ConversationOutbox.table] = []
        XCTAssertNotNil(review.acknowledging(local, readable: try recoveryAccess(header, local: local)))
    }
}

extension TeamCompletionTests {
    func testCancelledColdDiscoveryUsesActualTerminalProofWithoutRetiringAnything() throws {
        for undo in [false, true] {
            let (header, _, raw) = try cancellationFixture(undo: undo), review = try TeamCompletion.Review(raw, for: header), local = undo ? rebaseProjection(header) : projected(header)
            for mode in ["viewer", "archive", "pause"] {
                let access = try recoveryAccess(header, local: local, role: mode == "viewer" ? "viewer" : "editor", archived: mode == "archive", paused: mode == "pause")
                let request = try XCTUnwrap(TeamCompletionDiscovery(snapshot: local, access: access))
                XCTAssertEqual(request.terminal(review, current: local, readable: access), review); XCTAssertEqual(local.pending, [header])
                XCTAssertNil(review.acknowledging(local, readable: access))
                var changed = local; changed.pending.append(Mutation(table: "preferences", recordID: UUID().uuidString.lowercased(), method: "PATCH", fields: [:]))
                XCTAssertNil(request.terminal(review, current: changed, readable: access))
            }
        }
    }
    func testCancelledSingleRecoveryRetainsFreshPermissionsAndRefusesAuthoredLoss() throws {
        let (header, _, raw) = try cancellationFixture(), review = try TeamCompletion.Review(raw, for: header)
        var local = projected(header)
        let independent = Mutation(table: "labels", recordID: UUID().uuidString.lowercased(), method: "POST", fields: ["name": .string("Keep independent work")])
        local.apply(independent); local.pending.append(independent); local.teamWorkspace = try recoveryAccess(header, local: local, role: "editor")
        for mode in ["viewer", "archive", "pause"] {
            let access = try recoveryAccess(header, local: local, role: mode == "viewer" ? "viewer" : "editor", archived: mode == "archive", paused: mode == "pause")
            let next = try XCTUnwrap(review.cancelling(local, readable: access))
            XCTAssertEqual(next.pending, [independent]); XCTAssertEqual(next.tables["labels"], local.tables["labels"])
            XCTAssertEqual(next.tables["tasks"], [review.task!]); XCTAssertEqual(next.teamWorkspace?.boundary, access.boundary)
            XCTAssertFalse(try XCTUnwrap(next.teamWorkspace).canSend(header, in: next))
            XCTAssertEqual(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(next)), next)
            var authored = local; let edit = Mutation(table: "tasks", recordID: header.recordID, method: "PATCH", fields: ["description": .string("Keep authored notes")])
            authored.apply(edit); authored.pending.append(edit); let before = authored
            XCTAssertNil(review.cancelling(authored, readable: access)); XCTAssertEqual(authored, before)
        }
        for access in [try recoveryAccess(header, local: local, reads: false), try recoveryAccess(header, local: local, account: UUID().uuidString.lowercased()), try recoveryAccess(header, local: local, origin: "https://foreign.example"), try recoveryAccess(header, local: local, missing: [header.teamCompletion!.scope.project])] {
            XCTAssertNil(review.cancelling(local, readable: access))
        }
        var duplicate = local; duplicate.pending.append(header); XCTAssertNil(review.cancelling(duplicate, readable: try recoveryAccess(header, local: duplicate)))
    }
    func testCancelledRebaseRequiresCurrentWriteAccessAndPersistsFreshBoundary() throws {
        let (header, _, raw, _) = try rebaseFixture(), review = try TeamCompletion.Review(raw, for: header), local = rebaseProjection(header)
        XCTAssertTrue(review.canEditCurrent)
        for mode in ["viewer", "archive", "pause"] {
            let access = try recoveryAccess(header, local: local, role: mode == "viewer" ? "viewer" : "editor", archived: mode == "archive", paused: mode == "pause")
            XCTAssertNil(review.rebasing(local, readable: access)); XCTAssertEqual(local.pending, [header])
        }
        let access = try recoveryAccess(header, local: local, role: "editor"), plan = try XCTUnwrap(review.rebasing(local, readable: access))
        XCTAssertEqual(plan.snapshot.teamWorkspace?.boundary, access.boundary); XCTAssertEqual(plan.base.teamWorkspace?.boundary, access.boundary)
        XCTAssertNotEqual(plan.action.id, header.id); XCTAssertEqual(plan.snapshot.pending.first, plan.action)
    }
}


final class TeamCompletionRecoveryMessageTests: XCTestCase {
    func testFullStorageExplainsRetryWithoutExposingFileDetails() {
        let failure = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteOutOfSpace.rawValue, userInfo: [NSFilePathErrorKey: "/private/workspace-sensitive.json", NSLocalizedDescriptionKey: "Cannot write /private/workspace-sensitive.json"])
        let message = TeamCompletionRecoveryFailure.message(failure)
        XCTAssertTrue(message.contains("Free some space")); XCTAssertTrue(message.contains("queued work is unchanged")); XCTAssertFalse(message.contains("workspace-sensitive"))
    }
    func testInaccessibleOrDamagedStorageKeepsReviewGuidancePrivate() {
        for code in [CocoaError.fileReadUnknown, .fileReadNoPermission, .fileReadCorruptFile, .fileWriteUnknown, .fileWriteNoPermission, .fileWriteFileExists, .fileWriteInvalidFileName, .fileLocking] {
            let failure = NSError(domain: NSCocoaErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: "Could not access private-account-directory"])
            let message = TeamCompletionRecoveryFailure.message(failure)
            XCTAssertTrue(message.contains("queued work is unchanged")); XCTAssertTrue(message.contains("Check storage access")); XCTAssertFalse(message.contains("private-account"))
        }
    }
    func testNetworkAndSignInFailuresRetainTheirSpecificNextSteps() {
        XCTAssertEqual(TeamCompletionRecoveryFailure.message(URLError(.notConnectedToInternet)), SyncStatus.failureMessage(URLError(.notConnectedToInternet)))
        XCTAssertEqual(TeamCompletionRecoveryFailure.message(AccountSessionAuthorizationRequired()), SyncStatus.failureMessage(AccountSessionAuthorizationRequired()))
    }
}


final class TeamCompletionPresentationTests: XCTestCase {
    private func context() -> TeamCompletionReviewPresentation {
        TeamCompletionReviewPresentation(workspace: WorkspaceBinding(account: "ec240000-0000-4000-8000-000000000001", generation: UUID()), session: UUID(), snapshot: Snapshot(), access: nil, revision: UUID(), errorRevision: UUID(), single: nil, group: nil)
    }
    private func owns(_ value: TeamCompletionReviewPresentation, workspace: WorkspaceBinding? = nil, session: UUID? = nil, snapshot: Snapshot? = nil, access: TeamWorkspaceCache? = nil, revision: UUID? = nil) -> Bool {
        value.ownsFailure(workspace: workspace ?? value.workspace, session: session ?? value.session, snapshot: snapshot ?? value.snapshot, access: access ?? value.access, revision: revision ?? value.revision, single: value.single, group: value.group)
    }
    func testUnchangedPresentationOwnsItsFailure() { let value = context(); XCTAssertTrue(owns(value)) }
    func testOtherAccountAndReturnCannotReusePresentation() {
        let value = context()
        XCTAssertFalse(owns(value, workspace: WorkspaceBinding(account: UUID().uuidString.lowercased(), generation: value.workspace.generation)))
        XCTAssertFalse(owns(value, workspace: WorkspaceBinding(account: value.workspace.account, generation: UUID())))
    }
    func testNewCredentialIncarnationCannotReuseSameWorkspacePresentation() {
        let value = context(); XCTAssertFalse(owns(value, session: UUID()))
    }
    func testNewAuthoredWorkAndReadRevisionInvalidateFailureOwnership() {
        let value = context(); var changed = value.snapshot; changed.tables["tasks"] = [Record.task(user: value.workspace.account)]
        XCTAssertFalse(owns(value, snapshot: changed)); XCTAssertFalse(owns(value, revision: UUID()))
    }
    func testChangedAccessCacheInvalidatesFailureOwnership() throws {
        let value = context()
        let raw: [String: JSON] = ["workspace_boundary_protocol": .number(1), "account": .string(value.workspace.account), "native_team_reads_enabled": .bool(true), "setup_paused": .bool(false), "token": .string(String(repeating: "a", count: 64)), "teams": .array([]), "projects": .array([])]
        let access = try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(raw, account: value.workspace.account, origin: "https://synthetic.example"), previous: nil, pending: [], tasks: [])
        XCTAssertFalse(owns(value, access: access))
    }
}

extension TeamCompletionPresentationTests {
    func testOwnedRollbackFailureCanUseItsNewReadRevision() {
        let origin = context()
        let rollback = TeamCompletionReviewPresentation(workspace: origin.workspace, session: origin.session, snapshot: origin.snapshot, access: origin.access, revision: UUID(), errorRevision: UUID(), single: origin.single, group: origin.group)
        let failure = TeamCompletionReviewFailure(origin: origin, current: rollback, message: "Storage unavailable")
        XCTAssertTrue(failure.mayConsume(origin: origin, current: rollback, error: "Storage unavailable"))
        XCTAssertFalse(failure.mayConsume(origin: rollback, current: rollback, error: "Storage unavailable"))
        XCTAssertFalse(failure.mayConsume(origin: origin, current: origin, error: "Storage unavailable"))
    }
    func testNewMessageInvalidatesOwnershipEvenWithIdenticalText() {
        let origin = context()
        let later = TeamCompletionReviewPresentation(workspace: origin.workspace, session: origin.session, snapshot: origin.snapshot, access: origin.access, revision: origin.revision, errorRevision: UUID(), single: origin.single, group: origin.group)
        let failure = TeamCompletionReviewFailure(origin: origin, current: origin, message: "Try again")
        XCTAssertFalse(failure.mayConsume(origin: origin, current: later, error: "Try again"))
        XCTAssertFalse(failure.mayConsume(origin: origin, current: origin, error: "Different message"))
    }
}

extension TeamCompletionTests {
    func testProvisionalDraftSaveRequiresEncryptedReadbackAndRetriesSameArchive() throws {
        let (draft, _, _) = try draftCopyFixture(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ProvisionalVaultKeySource(), vault = TeamCompletionDraftVault(directory: directory, account: draft.scope.account, origin: draft.scope.origin, key: { try source.read() })
        source.fail(on: 2)
        XCTAssertThrowsError(try vault.save(draft), "A successful write with an unreadable result must not authorize retirement")
        source.fail(on: nil)
        let saved = try vault.load(draft.id), bytes = try Data(contentsOf: vault.file(draft.id))
        XCTAssertEqual(saved, draft)
        XCTAssertEqual(try vault.save(draft), saved)
        XCTAssertEqual(try Data(contentsOf: vault.file(draft.id)), bytes, "Retry reuses the already verified authored archive")
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(draft.record.title))
    }
    func testProvisionalCopyPreparationReadbackFailureKeepsExactFrozenRequestForRetry() throws {
        let (draft, command, _) = try draftCopyFixture(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ProvisionalVaultKeySource(), vault = TeamCompletionDraftVault(directory: directory, account: draft.scope.account, origin: draft.scope.origin, key: { try source.read() })
        try vault.save(draft); source.fail(on: 4)
        XCTAssertThrowsError(try vault.prepareCopy(draft, command: command))
        source.fail(on: nil)
        let reopened = try vault.load(draft.id), bytes = try Data(contentsOf: vault.file(draft.id))
        XCTAssertEqual(reopened.copyAttempt, command); XCTAssertTrue(reopened.sameWork(as: draft))
        XCTAssertEqual(try vault.prepareCopy(draft, command: command), reopened)
        XCTAssertEqual(try Data(contentsOf: vault.file(draft.id)), bytes)
        XCTAssertThrowsError(try vault.prepareCopy(draft, command: TeamCompletionDraft.CopyCommand(assignments: !command.assignments)))
        XCTAssertEqual(try vault.load(draft.id), reopened)
    }
    func testProvisionalCopyCancellationReadbackFailurePreservesAuthoredWorkOnReopen() throws {
        let (draft, command, reply) = try cancelledDraftCopyFixture(), proof = try TeamCompletionDraft.CopyReview(reply, draft: draft, command: command)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ProvisionalVaultKeySource(), vault = TeamCompletionDraftVault(directory: directory, account: draft.scope.account, origin: draft.scope.origin, key: { try source.read() })
        try vault.save(draft); let prepared = try vault.prepareCopy(draft, command: command)
        source.fail(on: 4)
        XCTAssertThrowsError(try vault.clearCopyAttempt(prepared, proof: proof))
        source.fail(on: nil)
        let reopened = try vault.load(draft.id)
        XCTAssertNil(reopened.copyAttempt); XCTAssertTrue(reopened.sameWork(as: draft))
        // A late old cancellation cannot release a newer request after relaunch.
        let next = TeamCompletionDraft.CopyCommand()
        let frozen = try vault.prepareCopy(reopened, command: next)
        XCTAssertThrowsError(try vault.clearCopyAttempt(prepared, proof: proof))
        XCTAssertEqual(try vault.load(draft.id), frozen)
    }
    func testProvisionalVaultRefusesOversizeFilesBeforeReadingOrFetchingKey() throws {
        let (draft, _, _) = try draftCopyFixture(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = ProvisionalVaultKeySource(), vault = TeamCompletionDraftVault(directory: directory, account: draft.scope.account, origin: draft.scope.origin, key: { try source.read() })
        XCTAssertTrue(FileManager.default.createFile(atPath: vault.file(draft.id).path, contents: nil))
        let handle = try FileHandle(forWritingTo: vault.file(draft.id)); try handle.truncate(atOffset: 16_001_025); try handle.close()
        XCTAssertThrowsError(try vault.load(draft.id)); XCTAssertThrowsError(try vault.entries()); XCTAssertThrowsError(try vault.save(draft))
        XCTAssertEqual(source.calls, 0)
        XCTAssertEqual(try vault.file(draft.id).resourceValues(forKeys: [.fileSizeKey]).fileSize, 16_001_025)
    }
    func testProvisionalVaultChecksAggregateAndCountBoundsBeforeDecrypting() throws {
        let (draft, _, _) = try draftCopyFixture(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = ProvisionalVaultKeySource(), vault = TeamCompletionDraftVault(directory: directory, account: draft.scope.account, origin: draft.scope.origin, key: { try source.read() })
        for _ in 0..<5 {
            let url = vault.file(UUID()); XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url); try handle.truncate(atOffset: 13_000_000); try handle.close()
        }
        XCTAssertThrowsError(try vault.entries()); XCTAssertEqual(source.calls, 0)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) { try FileManager.default.removeItem(at: file) }
        for _ in 0..<21 { XCTAssertTrue(FileManager.default.createFile(atPath: vault.file(UUID()).path, contents: nil)) }
        XCTAssertThrowsError(try vault.entries()); XCTAssertEqual(source.calls, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count, 21)
    }
    func testProvisionalVaultRejectsLinkedDirectoryAndLinkedFileWithoutChangingTarget() throws {
        let (draft, command, _) = try draftCopyFixture(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), target = draftVault(draft, directory: root.appendingPathComponent("target"), key: key)
        try target.save(draft); let bytes = try Data(contentsOf: target.file(draft.id))
        let linked = draftVault(draft, directory: root.appendingPathComponent("linked"), key: key)
        try FileManager.default.createSymbolicLink(at: linked.directory, withDestinationURL: target.directory)
        XCTAssertThrowsError(try linked.entries()); XCTAssertThrowsError(try linked.load(draft.id)); XCTAssertThrowsError(try linked.save(draft)); XCTAssertThrowsError(try linked.prepareCopy(draft, command: command)); XCTAssertThrowsError(try linked.remove(draft.id))
        let other = draftVault(draft, directory: root.appendingPathComponent("other"), key: key)
        try FileManager.default.createDirectory(at: other.directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: other.file(draft.id), withDestinationURL: target.file(draft.id))
        XCTAssertThrowsError(try other.load(draft.id)); XCTAssertThrowsError(try other.entries()); XCTAssertThrowsError(try other.prepareCopy(draft, command: command)); XCTAssertThrowsError(try other.remove(draft.id))
        XCTAssertEqual(try Data(contentsOf: target.file(draft.id)), bytes)
    }
    func testProvisionalVaultBlockedDestinationRepairKeepsAuthoredArchiveAndCopyChoices() throws {
        let (draft, command, _) = try draftCopyFixture(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let vault = draftVault(draft, directory: root.appendingPathComponent("vault"), key: SymmetricKey(size: .bits256))
        try Data("Reserved test barrier".utf8).write(to: vault.directory)
        XCTAssertThrowsError(try vault.save(draft)); XCTAssertEqual(try String(contentsOf: vault.directory), "Reserved test barrier")
        try FileManager.default.removeItem(at: vault.directory); try vault.save(draft)
        let held = vault.file(draft.id).appendingPathExtension("held")
        try FileManager.default.moveItem(at: vault.file(draft.id), to: held)
        try FileManager.default.createDirectory(at: vault.file(draft.id), withIntermediateDirectories: false)
        XCTAssertThrowsError(try vault.prepareCopy(draft, command: command)); XCTAssertThrowsError(try vault.load(draft.id))
        try FileManager.default.removeItem(at: vault.file(draft.id)); try FileManager.default.moveItem(at: held, to: vault.file(draft.id))
        XCTAssertEqual(try vault.load(draft.id), draft)
        XCTAssertEqual(try vault.prepareCopy(draft, command: command).copyAttempt, command)
    }
    func testAccountRemovalFenceProtectsProvisionalDraftDeletionAsWellAsWrites() throws {
        let (draft, _, _) = try draftCopyFixture(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = AccountRemovalDisk(directory: directory, account: draft.scope.account)
        var vault = draftVault(draft, directory: directory.appendingPathComponent("drafts"), key: SymmetricKey(size: .bits256)); vault.removalGate = gate
        try vault.save(draft); let bytes = try Data(contentsOf: vault.file(draft.id))
        try gate.removeCache(); XCTAssertThrowsError(try vault.remove(draft.id))
        XCTAssertEqual(try Data(contentsOf: vault.file(draft.id)), bytes)
        XCTAssertEqual(try vault.load(draft.id), draft, "Existing encrypted material remains reviewable; the fence prevents mutation")
    }

}

private final class ProvisionalVaultKeySource: @unchecked Sendable {
    private let lock = NSLock()
    private let key = SymmetricKey(size: .bits256)
    private var failure: Int?, count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func fail(on call: Int?) { lock.lock(); defer { lock.unlock() }; count = 0; failure = call }
    func read() throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }; count += 1
        if count == failure { throw AppFailure(message: "Synthetic key temporarily unavailable") }
        return key
    }
}

extension TeamCompletionTests {
    private func connectedProvisionalFixture(deleted: Bool = false, missingContext: Bool = true) throws -> (TeamConnectedProvisionalDraft, TeamCompletionDraft.Retirement, TeamWorkspaceCache) {
        let (header, _, raw) = try retirementFixture(), proof = try TeamCompletionDraft.Retirement(raw, for: header)
        var local = try editedDraftSnapshot(header)
        let scope = header.teamCompletion!.scope, proposed = header.teamCompletion!.proposed!
        let boundary: [String: JSON] = ["workspace_boundary_protocol": .number(1), "account": .string(scope.account), "native_team_reads_enabled": .bool(true), "setup_paused": .bool(false), "token": .string(String(repeating: "a", count: 64)), "teams": .array([.object(["id": .string(scope.team), "state": .string("active"), "revision": .number(1), "access_revision": .number(1)])]), "projects": .array([.object(["id": .string(scope.project), "team_id": .string(scope.team), "role": .string("viewer"), "archived": .bool(false), "can_send_tasks": .bool(false)])])]
        let access = try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(boundary, account: scope.account, origin: scope.origin), previous: nil, pending: local.pending, tasks: local.tables["tasks"]!)
        local.teamWorkspace = access
        let commentID = UUID().uuidString.lowercased(), mentionID = UUID().uuidString.lowercased(), stamp = "2026-10-26T12:00:00Z"
        let comment = Record(["id": .string(commentID), "task_id": .string(proposed.id), "task_generation": proposed["task_generation"], "project_id": .string(scope.project), "author_id": .string(scope.account), "body": .string("Connected retirement discussion"), "mention_ids": .array([.string(scope.account)]), "revision": .number(2), "created_at": .string(stamp), "updated_at": .string(stamp), "deleted_at": .null])
        let mention = Record(["id": .string(mentionID), "comment_id": .string(commentID), "recipient_id": .string(scope.account), "revision": .number(3), "created_at": .string(stamp), "read_at": .null])
        local.tables[SharedComment.table] = [comment]; local.tables[SharedMention.table] = [mention]
        try ConversationOutbox.enqueue(SharedMentionChange(mention: XCTUnwrap(SharedMention(mention)), account: scope.account, read: false).record, into: &local, origin: scope.origin)
        XCTAssertNotNil(local.tables[ConversationOutbox.table]!.last!.fields[MentionRecoveryContext.field])
        if missingContext { local.tables[SharedComment.table] = []; local.tables[SharedMention.table] = [] }
        let pin = try TaskOrderRecovery.capturing(Mutation(table: "view_orders", recordID: PinnedNotes.key(proposed.id), method: "POST", fields: ["id": .string(PinnedNotes.key(proposed.id)), "user_id": .string(scope.account), "ids": .array([.string(proposed.id)])]), snapshot: local, account: scope.account, origin: scope.origin)
        local.apply(pin); local.pending.append(pin)
        if deleted {
            let row = try XCTUnwrap(local.tables["tasks"]?.first { $0.id == proposed.id })
            let deletion = try scope.capturing(Mutation(table: "tasks", recordID: row.id, method: "DELETE", fields: [:], baseline: row.fields, teamTaskScope: scope), existing: row)
            local.apply(deletion); local.pending.append(deletion)
        }
        XCTAssertNil(TeamCompletionDraft.Candidate(review: proof.review, snapshot: local))
        return (try XCTUnwrap(TeamConnectedProvisionalDraft(review: proof.review, snapshot: local)), proof, access)
    }
    func testConnectedProvisionalPreservesPinDiscussionAndReadChoiceUnderViewerScope() throws {
        let (candidate, proof, access) = try connectedProvisionalFixture(), before = candidate.recovery.snapshot
        let label = Mutation(table: "labels", recordID: UUID().uuidString.lowercased(), method: "POST", fields: ["name": .string("Independent label")])
        var local = before; local.apply(label); local.pending.append(label)
        let connected = try XCTUnwrap(TeamConnectedProvisionalDraft(review: proof.review, snapshot: local)), next = try XCTUnwrap(connected.parking(proof: proof, readable: access))
        XCTAssertEqual(next.pending, [label]); XCTAssertEqual(next.tables["labels"], local.tables["labels"])
        XCTAssertEqual(connected.recovery.parkedChanges, Array(local.pending.dropLast()))
        XCTAssertEqual(connected.recovery.parkedConversations, local.tables[ConversationOutbox.table]); XCTAssertTrue(next.tables[ConversationOutbox.table]!.isEmpty)
        XCTAssertFalse((next.tables["view_orders"] ?? []).contains { $0.id == PinnedNotes.key(connected.copy.record.id) })
        XCTAssertFalse(next.tables["tasks"]!.contains { $0.id == connected.copy.record.id && $0["task_generation"] == connected.copy.record["task_generation"] })
        XCTAssertEqual(connected.copy.record.title, "My unsent design notes"); XCTAssertTrue(connected.recovery.text.contains("Connected retirement discussion"))
        XCTAssertFalse(next.teamWorkspace!.canSend(candidate.copy.original, in: next)); XCTAssertEqual(candidate.recovery.snapshot, before)
    }
    func testConnectedProvisionalDeletionKeepsLastAuthoredRecordAndWholeHistory() throws {
        let (candidate, proof, access) = try connectedProvisionalFixture(deleted: true)
        XCTAssertTrue(candidate.copy.markedForDeletion); XCTAssertEqual(candidate.copy.record.string("description"), "Keep every edited instruction")
        XCTAssertTrue(candidate.recovery.parkedChanges.contains { $0.method == "DELETE" })
        let next = try XCTUnwrap(candidate.parking(proof: proof, readable: access)); XCTAssertTrue(next.pending.isEmpty)
        XCTAssertFalse(next.tables["tasks"]!.contains { $0.id == candidate.copy.record.id && $0["task_generation"] == candidate.copy.record["task_generation"] })
        XCTAssertEqual(next.tables["tasks"]?.first { $0.id == candidate.copy.record.id }, proof.currentProposed)
    }
    func testConnectedProvisionalRetainsActualReplacementWithoutOldDiscussionCache() throws {
        let (candidate, proof, access) = try connectedProvisionalFixture(missingContext: false)
        var reply = proof.response, row = try XCTUnwrap(proof.currentProposed)
        row["title"] = .string("Actual replacement")
        reply["current_proposed"] = .object(row.fields)
        let current = try TeamCompletionDraft.Retirement(reply, for: candidate.copy.original), next = try XCTUnwrap(candidate.parking(proof: current, readable: access))
        XCTAssertEqual(next.tables["tasks"]?.first { $0.id == row.id }, row)
        XCTAssertTrue(next.tables[SharedComment.table]!.isEmpty); XCTAssertTrue(next.tables[SharedMention.table]!.isEmpty)
    }
    func testConnectedProvisionalPairAndActualRetirementSurviveEncryptedReadback() throws {
        let (candidate, proof, _) = try connectedProvisionalFixture(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256), archiveVault = TeamCompletionRecoveryDraftVault(directory: directory.appendingPathComponent("archives"), account: candidate.recovery.account, origin: candidate.recovery.origin, key: { key }), copyVault = draftVault(candidate.copy, directory: directory.appendingPathComponent("copies"), key: key)
        let archive = try archiveVault.save(candidate.recovery), copy = try copyVault.saveConnected(candidate.copy, recovery: archive)
        let verified = try archiveVault.recordProvisionalRetirement(archive, proof: proof)
        XCTAssertEqual(try archiveVault.load(archive.id), verified); XCTAssertEqual(try copyVault.load(copy.id), copy)
        XCTAssertEqual(copy.connectedRecoveryIDs, [archive.id]); XCTAssertEqual(verified.provisionalRetirements, [proof.response]); XCTAssertEqual(verified.snapshot, candidate.recovery.snapshot)
        let export = try JSONDecoder().decode([String: JSON].self, from: verified.data())
        XCTAssertNil(export["provisionalRetirements"]); XCTAssertNil(export["review"]); XCTAssertNil(export["snapshot"])
        XCTAssertEqual(export["conversations"]!.list, candidate.recovery.parkedConversations.map { .object($0.fields) })
        XCTAssertTrue(verified.text.contains("Provisional task retired"))
        XCTAssertFalse(String(decoding: try Data(contentsOf: copyVault.file(copy.id)), as: UTF8.self).contains(copy.record.title))
    }
    func testConnectedProvisionalReusesFrozenLegacyCopyAcrossNewArchiveLinks() throws {
        let (candidate, _, _) = try connectedProvisionalFixture(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copyVault = draftVault(candidate.copy, directory: directory, key: SymmetricKey(size: .bits256))
        let old = try copyVault.save(candidate.copy), command = TeamCompletionDraft.CopyCommand(assignments: true, reminders: false)
        let frozen = try copyVault.prepareCopy(old, command: command), body = try command.body(for: frozen)
        let linked = try copyVault.saveConnected(candidate.copy, recovery: candidate.recovery)
        XCTAssertEqual(linked.id, frozen.id); XCTAssertEqual(linked.copyAttempt, command); XCTAssertEqual(try command.body(for: linked), body)
        var raw = try JSONDecoder().decode([String: JSON].self, from: JSONEncoder().encode(candidate.recovery)); raw["id"] = .string(UUID().uuidString.lowercased())
        let another = try JSONDecoder().decode(TeamCompletionRecoveryDraft.self, from: JSONEncoder().encode(raw))
        let twice = try copyVault.saveConnected(candidate.copy, recovery: another)
        XCTAssertEqual(twice.id, frozen.id); XCTAssertEqual(twice.copyAttempt, command); XCTAssertEqual(twice.connectedRecoveryIDs, [candidate.recovery.id, another.id]); XCTAssertEqual(try command.body(for: twice), body)
        XCTAssertEqual(try copyVault.entries().count, 1)
    }
    func testConnectedProvisionalLinkReadbackFailureReopensSameCopyAndLink() throws {
        let (candidate, _, _) = try connectedProvisionalFixture(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ProvisionalVaultKeySource(), vault = TeamCompletionDraftVault(directory: directory, account: candidate.copy.scope.account, origin: candidate.copy.scope.origin, key: { try source.read() })
        let old = try vault.save(candidate.copy), command = TeamCompletionDraft.CopyCommand(), frozen = try vault.prepareCopy(old, command: command)
        source.fail(on: 4); XCTAssertThrowsError(try vault.saveConnected(candidate.copy, recovery: candidate.recovery))
        source.fail(on: nil); let reopened = try vault.load(frozen.id), bytes = try Data(contentsOf: vault.file(frozen.id))
        XCTAssertEqual(reopened.copyAttempt, command); XCTAssertEqual(reopened.connectedRecoveryIDs, [candidate.recovery.id])
        XCTAssertEqual(try vault.saveConnected(candidate.copy, recovery: candidate.recovery), reopened)
        XCTAssertEqual(try Data(contentsOf: vault.file(frozen.id)), bytes)
    }
    func testConnectedProvisionalLinkBoundNeverEvictsOrResetsCopyRequest() throws {
        let (candidate, _, _) = try connectedProvisionalFixture(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = draftVault(candidate.copy, directory: directory, key: SymmetricKey(size: .bits256)), command = TeamCompletionDraft.CopyCommand()
        let frozen = try vault.prepareCopy(vault.save(candidate.copy), command: command)
        var raw = try JSONDecoder().decode([String: JSON].self, from: JSONEncoder().encode(candidate.recovery))
        for _ in 0..<20 { raw["id"] = .string(UUID().uuidString.lowercased()); let archive = try JSONDecoder().decode(TeamCompletionRecoveryDraft.self, from: JSONEncoder().encode(raw)); _ = try vault.saveConnected(candidate.copy, recovery: archive) }
        let bytes = try Data(contentsOf: vault.file(frozen.id)); raw["id"] = .string(UUID().uuidString.lowercased())
        let overflow = try JSONDecoder().decode(TeamCompletionRecoveryDraft.self, from: JSONEncoder().encode(raw)); XCTAssertThrowsError(try vault.saveConnected(candidate.copy, recovery: overflow))
        XCTAssertEqual(try Data(contentsOf: vault.file(frozen.id)), bytes); XCTAssertEqual(try vault.load(frozen.id).connectedRecoveryIDs?.count, 20); XCTAssertEqual(try vault.load(frozen.id).copyAttempt, command)
    }
    func testConnectedProvisionalActualProofHistoryBoundAndWrongPhaseRefusal() throws {
        let (candidate, proof, _) = try connectedProvisionalFixture(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256), vault = TeamCompletionRecoveryDraftVault(directory: directory, account: candidate.recovery.account, origin: candidate.recovery.origin, key: { key })
        let saved = try vault.save(candidate.recovery)
        for i in 0..<20 { var raw = proof.response; raw["test_observation"] = .number(Double(i)); _ = try vault.recordProvisionalRetirement(saved, proof: TeamCompletionDraft.Retirement(raw, for: candidate.copy.original)) }
        let bytes = try Data(contentsOf: vault.file(saved.id)); var raw = proof.response; raw["test_observation"] = .number(20)
        XCTAssertThrowsError(try vault.recordProvisionalRetirement(saved, proof: TeamCompletionDraft.Retirement(raw, for: candidate.copy.original)))
        XCTAssertEqual(try Data(contentsOf: vault.file(saved.id)), bytes); XCTAssertEqual(try vault.load(saved.id).provisionalRetirements?.count, 20)
        let cancellationVault = TeamCompletionRecoveryDraftVault(directory: directory, account: candidate.recovery.account, origin: candidate.recovery.origin, key: { key }, cancelled: true)
        XCTAssertThrowsError(try cancellationVault.recordProvisionalRetirement(saved, proof: proof))
    }
    func testConnectedProvisionalRefusesChangedCopyDefinitionAndLostCurrentReadScope() throws {
        let (candidate, proof, access) = try connectedProvisionalFixture(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = draftVault(candidate.copy, directory: directory, key: SymmetricKey(size: .bits256)); _ = try vault.save(candidate.copy)
        let bytes = try Data(contentsOf: vault.file(candidate.copy.id)); var changed = candidate.copy.record; changed["title"] = .string("Unexpected different copy")
        let other = TeamCompletionDraft(version: 1, id: UUID(), createdAt: Date(), original: candidate.copy.original, record: changed, markedForDeletion: false, edits: [], conversations: [])
        XCTAssertThrowsError(try vault.saveConnected(other, recovery: candidate.recovery)); XCTAssertEqual(try Data(contentsOf: vault.file(candidate.copy.id)), bytes)
        var boundary = access.boundary.raw; boundary["projects"] = .array([]); boundary["teams"] = .array([])
        let lost = try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(boundary, account: access.boundary.account, origin: access.boundary.origin), previous: nil, pending: [], tasks: [])
        XCTAssertNil(candidate.parking(proof: proof, readable: lost))
    }
    func testConnectedProvisionalLongOwnHistoryStaysInFullArchiveWithoutTruncation() throws {
        let (base, proof, access) = try connectedProvisionalFixture(); var local = base.recovery.snapshot
        for i in 0..<105 {
            let row = try XCTUnwrap(local.tables["tasks"]?.first { $0.id == base.copy.record.id }), fields: [String: JSON] = ["description": .string("Long connected history \(i)")]
            let edit = try base.copy.scope.capturing(Mutation(table: "tasks", recordID: row.id, method: "PATCH", fields: fields, baseline: TaskCompletionRevision.editBaseline(for: fields, from: row), teamTaskScope: base.copy.scope), existing: row)
            local.apply(edit); local.pending.append(edit)
        }
        let candidate = try XCTUnwrap(TeamConnectedProvisionalDraft(review: proof.review, snapshot: local))
        XCTAssertTrue(candidate.copy.edits.isEmpty); XCTAssertEqual(candidate.recovery.parkedChanges.count, local.pending.count)
        let text = candidate.recovery.text
        for i in 0..<105 { XCTAssertTrue(text.contains("Long connected history \(i)")) }
        XCTAssertTrue(try XCTUnwrap(candidate.parking(proof: proof, readable: access)).pending.isEmpty)
    }
    func testConnectedProvisionalOptionalLinksKeepLegacyWireBodyAndDecoderCompatibility() throws {
        let (draft, command, fixture) = try draftCopyFixture(); var linked = draft; linked.connectedRecoveryIDs = [UUID()]
        XCTAssertEqual(try command.body(for: linked), fixture["body"]!.object)
        let data = try JSONEncoder().encode(linked); XCTAssertEqual(try JSONDecoder().decode(TeamCompletionDraft.self, from: data), linked)
        var raw = try JSONDecoder().decode([String: JSON].self, from: data); raw.removeValue(forKey: "connectedRecoveryIDs")
        XCTAssertNil(try JSONDecoder().decode(TeamCompletionDraft.self, from: JSONEncoder().encode(raw)).connectedRecoveryIDs)
        linked.connectedRecoveryIDs = [UUID(uuidString: "00000000-0000-0000-0000-000000000000")!]; XCTAssertThrowsError(try linked.validate())
    }
    @MainActor func testConnectedProvisionalRetirementTransportRetainsActualReplyAndOriginalBody() async throws {
        let (candidate, proof, _) = try connectedProvisionalFixture(), api = try backend(candidate.copy.scope.account)
        var requests: [URLRequest] = []
        CompletionHTTP.handler = { request, peer in requests.append(request); peer.finish(try! JSONEncoder().encode(proof.response)) }; defer { CompletionHTTP.handler = nil }
        let actual = try await api.retireTeamProvisional(candidate.copy.original, expectedAccount: candidate.copy.scope.account)
        XCTAssertEqual(actual.response, proof.response); XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.path, "/rest/v1/rpc/taskfold_retire_team_provisional")
        let body = try JSONDecoder().decode([String: JSON].self, from: XCTUnwrap(requests[0].httpBody))
        XCTAssertEqual(body, ["_body": .object(try candidate.copy.original.teamCompletion!.body(for: candidate.copy.original))])
        XCTAssertNil(body["connectedRecoveryIDs"]); XCTAssertNil(body["provisionalRetirements"])
    }
}

extension TeamCompletionTests {
    func testConnectedProvisionalAccountRemovalFencesBothArchiveUpdates() throws {
        let (candidate, proof, _) = try connectedProvisionalFixture(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = AccountRemovalDisk(directory: root, account: candidate.copy.scope.account), key = SymmetricKey(size: .bits256)
        var copies = draftVault(candidate.copy, directory: root.appendingPathComponent("copies"), key: key)
        copies.removalGate = gate
        let archive = TeamCompletionRecoveryDraftVault(directory: root.appendingPathComponent("archives"), account: candidate.recovery.account, origin: candidate.recovery.origin, key: { key }, removalGate: gate)
        let saved = try archive.save(candidate.recovery), copy = try copies.saveConnected(candidate.copy, recovery: saved)
        let copyBytes = try Data(contentsOf: copies.file(copy.id)), archiveBytes = try Data(contentsOf: archive.file(saved.id))
        try gate.removeCache()
        XCTAssertThrowsError(try copies.saveConnected(candidate.copy, recovery: saved))
        XCTAssertThrowsError(try archive.recordProvisionalRetirement(saved, proof: proof))
        XCTAssertEqual(try Data(contentsOf: copies.file(copy.id)), copyBytes); XCTAssertEqual(try Data(contentsOf: archive.file(saved.id)), archiveBytes)
    }
}
