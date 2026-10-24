import XCTest
@testable import TaskfoldCore

private let editOrigin = "https://backend.example"
private final class TeamEditHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, TeamEditHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }; data.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = data
        }
        Self.handler?(captured, self)
    }
    func finish(_ data: Data, status: Int = 200) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json", "Content-Length":String(data.count)])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
}
private final class TeamEditGate: @unchecked Sendable {
    private let lock=NSLock();private var peer:TeamEditHTTP?
    func hold(_ value:TeamEditHTTP){lock.lock();peer=value;lock.unlock()}
    func release(_ data:Data){lock.lock();let value=peer;peer=nil;lock.unlock();value?.finish(data)}
}
final class TeamTaskEditTests: XCTestCase {
    private func fixture() throws -> (Mutation, TeamTaskEditScope, [String:JSON]) {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"team-task-edit-v1",withExtension:"json",subdirectory:"Fixtures"))
        let raw=try JSONDecoder().decode([String:JSON].self,from:Data(contentsOf:url))
        let body=try XCTUnwrap(raw["body"]?.object),reply=try XCTUnwrap(raw["reply"]?.object)
        let scope=TeamTaskEditScope(account:try XCTUnwrap(raw["account"]?.text),origin:editOrigin,team:try XCTUnwrap(body["team_id"]?.text),project:try XCTUnwrap(body["project_id"]?.text))
        let change=Mutation(id:try XCTUnwrap(UUID(uuidString:body["request_id"]!.text)),table:"tasks",recordID:body["task_id"]!.text,method:"PATCH",fields:body["changes"]!.object,baseline:body["base"]!.object,teamTaskScope:scope)
        return(change,scope,reply)
    }
    @MainActor private func backend(_ account:String) throws -> Backend {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[TeamEditHTTP.self]
        let session=try JSONDecoder().decode(Session.self,from:Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(account)\"}}".utf8))
        return Backend(configuration:["URL":editOrigin,"Key":"synthetic-public"],http:URLSession(configuration:config),session:session,persistSession:{_ in})
    }
    func testActualSQLReplyConfirmsFrozenIntentAndRetainsCreator() throws {
        let(change,scope,reply)=try fixture(),saved=try scope.saved(reply,for:change)
        XCTAssertEqual(saved.string("title"),"Edited");XCTAssertNotEqual(saved.string("user_id"),scope.account)
        XCTAssertEqual(try scope.body(for:change)["request_id"],.string(change.id.uuidString.lowercased()))
        var later=reply;var row=reply["task"]!.object;row["title"] = .string("A newer edit");later["task"] = .object(row);later["replayed"] = .bool(true)
        XCTAssertEqual(try scope.saved(later,for:change).string("title"),"A newer edit")
    }
    func testQueuedScopeSurvivesPersistenceAndOldQueuesStayUnscoped() throws {
        let(change,scope,_)=try fixture();XCTAssertEqual(try JSONDecoder().decode(Mutation.self,from:JSONEncoder().encode(change)),change)
        var legacy=try JSONDecoder().decode([String:JSON].self,from:JSONEncoder().encode(change));legacy.removeValue(forKey:"teamTaskScope")
        let decoded=try JSONDecoder().decode(Mutation.self,from:JSONEncoder().encode(legacy));XCTAssertNil(decoded.teamTaskScope)
        XCTAssertEqual(change.teamTaskScope,scope)
    }
    func testWrongMutationShapeCannotReachTeamAdapter() throws {
        let(original,scope,_)=try fixture()
        for method in ["POST","DELETE","ORDER"] {var change=original;change.method=method;XCTAssertThrowsError(try scope.body(for:change))}
        for key in ["project_id","attachments","comments","source_metadata","task_generation"] {
            var change=original;change.fields=[key:.null];change.baseline?[key] = .null;XCTAssertThrowsError(try scope.body(for:change))
        }
        var change=original;change.baseline?.removeValue(forKey:"project_id");XCTAssertThrowsError(try scope.body(for:change))
        change=original;change.baseline?["task_generation"] = .null;XCTAssertThrowsError(try scope.body(for:change))
        change=original;change.fields=["completed":.bool(true)];change.baseline?["completed"] = .bool(false)
        for version in [JSON.null,.number(-1),.number(0.5),.number(.infinity)] {change.baseline?["completion_version"]=version;XCTAssertThrowsError(try scope.body(for:change))}
        change.baseline?["completion_version"] = .number(0);XCTAssertNoThrow(try scope.body(for:change))
        change=original;change.fields=["title":.string(String(repeating:"x",count:129000))];XCTAssertThrowsError(try scope.body(for:change))
    }
    func testReplyCannotAcknowledgeAnotherAccountProjectGenerationOrNonce() throws {
        let(change,scope,reply)=try fixture()
        for key in ["account","team_id","project_id","request_id","task_generation"] {var value=reply;value[key] = .string(UUID().uuidString.lowercased());XCTAssertThrowsError(try scope.saved(value,for:change))}
        for key in ["protocol","replayed","task"] {var value=reply;value.removeValue(forKey:key);XCTAssertThrowsError(try scope.saved(value,for:change))}
        for key in ["id","project_id","task_generation","user_id","completion_version","completed"] {var value=reply;var row=reply["task"]!.object;row[key] = .null;value["task"] = .object(row);XCTAssertThrowsError(try scope.saved(value,for:change))}
    }
    func testUnavailableProjectRecoveryCannotDropTeamDraft() throws {
        let(change,scope,reply)=try fixture();var snapshot=Snapshot();snapshot.tables=["tasks":[try scope.saved(reply,for:change)],"projects":[Record(["id":.string(scope.project)])]];snapshot.pending=[change]
        let original=snapshot
        XCTAssertEqual(snapshot.recoveryProjectIDs(for:change),[])
        XCTAssertNil(snapshot.recoveringUnavailableProject(for:change,remote:["projects":[],"tasks":[],"sections":[],"project_collaborators":[]]))
        XCTAssertEqual(snapshot,original)
        var legacy = change; legacy.teamTaskScope = nil; legacy.id = UUID()
        snapshot.pending.insert(legacy, at: 0)
        XCTAssertNil(snapshot.recoveringUnavailableProject(for:legacy,remote:["projects":[],"tasks":[],"sections":[],"project_collaborators":[]]))
        XCTAssertEqual(snapshot.pending.count,2)
    }
    func testUndoRetainsFrozenWorkspaceAndReviewedBaseline() throws {
        let(change,scope,reply)=try fixture();var before=try scope.saved(reply,for:change);before["title"] = .string("Original")
        var snapshot=Snapshot();snapshot.tables=["tasks":[before]]
        let history=EditHistory(changes:[change],snapshot:snapshot)
        let inverse=try XCTUnwrap(history.undo.first);XCTAssertEqual(inverse.teamTaskScope,scope);XCTAssertNotEqual(inverse.id,change.id)
        XCTAssertEqual(try scope.body(for:inverse)["project_id"],.string(scope.project));XCTAssertEqual(history.redo.first?.teamTaskScope,scope)
        XCTAssertNoThrow(try scope.body(for:XCTUnwrap(history.redo.first)))
    }
    func testHistoryRecapturesOnlyOriginalProjectAndTaskIncarnation() throws {
        let (change,scope,reply) = try fixture(); let current = try scope.saved(reply,for:change)
        var rebased = change; rebased.baseline = nil
        rebased = TaskCompletionRevision.capturing(rebased,existing:current)
        XCTAssertNoThrow(try scope.capturing(rebased,existing:current))
        var foreign = current; foreign["project_id"] = .string(UUID().uuidString.lowercased())
        XCTAssertThrowsError(try scope.capturing(rebased,existing:foreign))
        foreign = current; foreign["task_generation"] = .string(UUID().uuidString.lowercased())
        XCTAssertThrowsError(try scope.capturing(rebased,existing:foreign))
        var snapshot = Snapshot(); snapshot.tables = ["tasks":[current]]; snapshot.pending = [change]
        let conflict = SyncConflict(mutation:change,remote:current)
        let resolved = try XCTUnwrap(conflict.resolving(snapshot,keepLocal:true))
        XCTAssertNotEqual(resolved.pending.first?.id,change.id)
        XCTAssertNoThrow(try scope.body(for:XCTUnwrap(resolved.pending.first)))
        XCTAssertNil(SyncConflict(mutation:change,remote:foreign).resolving(snapshot,keepLocal:true))
    }
    @MainActor func testSyncUsesDedicatedBoundedEndpointAndSameNonceForRetry() async throws {
        let(change,scope,reply)=try fixture();let api=try backend(scope.account),data=try JSONEncoder().encode(reply);var requests:[URLRequest]=[]
        TeamEditHTTP.handler={request,peer in requests.append(request);peer.finish(data)};defer{TeamEditHTTP.handler=nil}
        _=try await api.send(change,expectedAccount:scope.account);_=try await api.send(change,expectedAccount:scope.account)
        XCTAssertEqual(requests.count,2)
        for request in requests {
            XCTAssertEqual(request.url?.path,"/rest/v1/rpc/taskfold_edit_team_task");XCTAssertEqual(request.httpMethod,"POST");XCTAssertEqual(request.timeoutInterval,25);XCTAssertFalse(request.httpShouldHandleCookies);XCTAssertEqual(request.value(forHTTPHeaderField:"Cache-Control"),"no-store")
            let value=try JSONDecoder().decode([String:JSON].self,from:try XCTUnwrap(request.httpBody));XCTAssertEqual(value["_body"],.object(try scope.body(for:change)))
        }
        var rejected=change;rejected.teamTaskScope=TeamTaskEditScope(account:scope.account,origin:"https://other.example",team:scope.team,project:scope.project)
        do{_=try await api.send(rejected);XCTFail("Foreign origin sent")}catch{XCTAssertTrue(error is CancellationError)}
        do{_=try await api.send(change,expectedAccount:UUID().uuidString.lowercased());XCTFail("Foreign account sent")}catch{XCTAssertTrue(error is CancellationError)}
        XCTAssertEqual(requests.count,2)
    }
    @MainActor func testTeamFailureNeverFallsBackToPersonalWriteOrLeaksServerDetails() async throws {
        let(change,scope,_)=try fixture();let api=try backend(scope.account);var calls=0
        defer{TeamEditHTTP.handler=nil}
        for code in ["28000","PT409","42501","PT404","PT503","22023"] {
            TeamEditHTTP.handler={request,peer in calls += 1;XCTAssertEqual(request.url?.path,"/rest/v1/rpc/taskfold_edit_team_task");peer.finish(Data("{\"code\":\"\(code)\",\"message\":\"private-database-details\"}".utf8),status:400)}
            do{_=try await api.send(change);XCTFail("Failure acknowledged")}catch{XCTAssertFalse(error.localizedDescription.contains("private-database-details"));if code=="28000"{XCTAssertTrue(error is AccountSessionAuthorizationRequired)}}
        }
        XCTAssertEqual(calls,6)
    }
    @MainActor func testLateReplyCannotAcknowledgeAfterSessionReplacement() async throws {
        let(change,scope,reply)=try fixture();let api=try backend(scope.account),gate=TeamEditGate(),started=expectation(description:"Edit held")
        TeamEditHTTP.handler={_,peer in gate.hold(peer);started.fulfill()};defer{TeamEditHTTP.handler=nil}
        let pending=Task{@MainActor in try await api.send(change)}
        await fulfillment(of:[started],timeout:3)
        // Even signing into the same account creates a new session incarnation.
        try await api.accept(XCTUnwrap(api.session));gate.release(try JSONEncoder().encode(reply))
        do{_=try await pending.value;XCTFail("Old session reply acknowledged")}catch{XCTAssertTrue(error is CancellationError)}
    }
    @MainActor func testOversizedReplyCannotAcknowledgeDraft() async throws {
        let(change,scope,_)=try fixture();let api=try backend(scope.account)
        TeamEditHTTP.handler={_,peer in peer.finish(Data(repeating:32,count:256001))};defer{TeamEditHTTP.handler=nil}
        do{_=try await api.send(change);XCTFail("Oversized response accepted")}catch{XCTAssertTrue(error.localizedDescription.contains("too large"))}
    }
    private func planningFixture() throws -> (Mutation, TeamTaskEditScope, [String:JSON], Record) {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"team-task-planning-v1",withExtension:"json",subdirectory:"Fixtures"))
        let raw=try JSONDecoder().decode([String:JSON].self,from:Data(contentsOf:url))["planning"]!.object
        let body=raw["body"]!.object,reply=raw["reply"]!.object
        let scope=TeamTaskEditScope(account:raw["account"]!.text,origin:editOrigin,team:body["team_id"]!.text,project:body["project_id"]!.text)
        return(Mutation(id:try XCTUnwrap(UUID(uuidString:body["request_id"]!.text)),table:"tasks",recordID:body["task_id"]!.text,method:"PATCH",fields:body["changes"]!.object,baseline:body["base"]!.object,teamTaskScope:scope),scope,reply,Record(raw["before"]!.object))
    }
    func testPlanningActualSQLReplyAndPersistedFourFieldIntent() throws {
        let(change,scope,reply,before)=try planningFixture()
        XCTAssertEqual(Set(change.fields.keys),Set(["assigned_to","section_id","labels","reminder_specs"]))
        let saved=try scope.saved(reply,for:change)
        for (key,value) in change.fields { XCTAssertEqual(saved[key],value); XCTAssertEqual(change.baseline?[key],before[key]) }
        XCTAssertEqual(try JSONDecoder().decode(Mutation.self,from:JSONEncoder().encode(change)),change)
        XCTAssertNoThrow(try scope.capturing(change,existing:before))
    }
    func testPlanningUndoAndRedoKeepEveryFrozenField() throws {
        let(change,scope,_,before)=try planningFixture();var snapshot=Snapshot();snapshot.tables=["tasks":[before]]
        let history=EditHistory(changes:[change],snapshot:snapshot)
        let inverse=try XCTUnwrap(history.undo.first)
        XCTAssertEqual(inverse.teamTaskScope,scope)
        for key in change.fields.keys { XCTAssertEqual(inverse.fields[key],before[key]) }
        XCTAssertNoThrow(try scope.body(for:inverse));XCTAssertNoThrow(try scope.body(for:XCTUnwrap(history.redo.first)))
        snapshot.apply(change);snapshot.apply(inverse)
        let restored=try XCTUnwrap(snapshot.tables["tasks"]?.first)
        for key in change.fields.keys { XCTAssertEqual(restored[key],before[key]) }
    }
    func testPlanningInvalidReferenceAndListShapesStayLocal() throws {
        let(original,scope,_,_)=try planningFixture()
        let invalid:[String:[JSON]]=["assigned_to":[.string("invalid"),.number(1),.string("00000000-0000-0000-0000-000000000000")],"section_id":[.bool(false),.array([])],"labels":[.null,.array([.number(3)]),.array([.string("")]),.array([.string(String(repeating:"x",count:1025))]),.array(Array(repeating:.string("tag"),count:257))],"reminder_specs":[.null,.array([.string("not a reminder")]),.array([.object([:])]),.array(Array(repeating:.object(["id":.string(UUID().uuidString)]),count:21))]]
        for (key,values) in invalid { for value in values { var change=original;change.fields=[key:value];XCTAssertThrowsError(try scope.body(for:change),key) } }
        var duplicate=original;let reminder=try XCTUnwrap(original.fields["reminder_specs"]?.list.first)
        duplicate.fields=["reminder_specs":.array([reminder,reminder])];XCTAssertThrowsError(try scope.body(for:duplicate))
    }
    func testPlanningMissingBaselineCannotBeSilentlyCaptured() throws {
        let(original,scope,_,_)=try planningFixture()
        for key in original.fields.keys {var change=original;change.baseline?.removeValue(forKey:key);XCTAssertThrowsError(try scope.body(for:change))}
    }
    @MainActor func testPlanningSendsFourFieldsThroughGuardedEndpoint() async throws {
        let(change,scope,reply,_)=try planningFixture();let api=try backend(scope.account);var captured:URLRequest?
        TeamEditHTTP.handler={request,peer in captured=request;peer.finish(try! JSONEncoder().encode(reply))};defer{TeamEditHTTP.handler=nil}
        _=try await api.send(change,expectedAccount:scope.account)
        let request=try XCTUnwrap(captured);XCTAssertEqual(request.url?.path,"/rest/v1/rpc/taskfold_edit_team_task")
        let root=try JSONDecoder().decode([String:JSON].self,from:XCTUnwrap(request.httpBody))
        XCTAssertEqual(root["_body"],.object(try scope.body(for:change)))
    }
}
