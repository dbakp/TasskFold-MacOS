import XCTest
@testable import TaskfoldCore

private final class WorkspaceHTTP:URLProtocol,@unchecked Sendable {
    static var handler:((URLRequest,WorkspaceHTTP)->Void)?
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading(){Self.handler?(request,self)}
    override func stopLoading(){}
    func finish(_ value:JSON,status:Int=200) {finishData(try! JSONEncoder().encode(value),status:status)}
    func finishData(_ data:Data,status:Int=200) {
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json","Content-Length":String(data.count)])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
}
final class TeamWorkspaceTests:XCTestCase {
    private let origin="https://backend.example"
    private func fixture() throws -> [String:JSON] {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"team-workspace-boundary-v1",withExtension:"json",subdirectory:"Fixtures"))
        return try JSONDecoder().decode([String:JSON].self,from:Data(contentsOf:url))
    }
    private func boundary(_ state:String="active") throws -> TeamWorkspaceBoundary {
        let f=try fixture();return try TeamWorkspaceBoundary(f[state]!.object,account:f["account"]!.text,origin:origin)
    }
    private func snapshot() throws -> Snapshot {
        let b=try boundary(),f=try fixture()
        var team=Record.task(user:b.account,project:f["project"]!.text);team["title"] = .string("Team secret review");team["description"] = .string("Private workshop instructions")
        var personal=Record.task(user:b.account,project:f["personal"]!.text);personal["title"] = .string("Personal draft")
        let projects=b.projects.keys.sorted().map{Record(["id":.string($0),"user_id":.string(b.account),"name":.string($0==f["project"]!.text ? "Secret workshop":"Personal studio")])}
        return Snapshot(tables:["projects":projects,"tasks":[team,personal],"profiles":[Record(["user_id":.string(b.account),"display_name":.string("Current person")])]])
    }
    private func edit(_ task:Record,boundary b:TeamWorkspaceBoundary,title:String="Unsent team notes") throws -> Mutation {
        let p=try XCTUnwrap(b.projects[task.string("project_id")]),scope=TeamTaskEditScope(account:b.account,origin:b.origin,team:try XCTUnwrap(p.team),project:p.id)
        let fields:[String:JSON]=["title":.string(title)]
        return try scope.capturing(Mutation(table:"tasks",recordID:task.id,method:"PATCH",fields:fields,baseline:TaskCompletionRevision.editBaseline(for:fields,from:task),teamTaskScope:scope),existing:task)
    }
    @MainActor private func backend(_ account:String) throws -> Backend {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[WorkspaceHTTP.self]
        let session=try JSONDecoder().decode(Session.self,from:Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(account)\"}}".utf8))
        return Backend(configuration:["URL":origin,"Key":"synthetic-public"],http:URLSession(configuration:config),session:session,persistSession:{_ in})
    }
    func testActualSQLBoundariesKeepPersonalSharingSeparateFromTeamRoles() throws {
        let f=try fixture(),active=try boundary(),viewer=try boundary("viewer"),left=try boundary("left")
        XCTAssertEqual(active.projects[f["project"]!.text]?.role,"editor")
        XCTAssertEqual(viewer.projects[f["project"]!.text]?.role,"viewer");XCTAssertFalse(viewer.projects[f["project"]!.text]!.canSend)
        XCTAssertNil(left.projects[f["project"]!.text]);XCTAssertNotNil(left.projects[f["personal"]!.text])
        XCTAssertNotEqual(active,viewer)
    }
    func testBoundaryRejectsWrongAccountMalformedTokensAndForgedRoleCapabilities() throws {
        let f=try fixture(),raw=f["active"]!.object
        XCTAssertThrowsError(try TeamWorkspaceBoundary(raw,account:UUID().uuidString.lowercased(),origin:origin))
        for token in ["",String(repeating:"z",count:64),String(repeating:"a",count:65)] {var bad=raw;bad["token"] = .string(token);XCTAssertThrowsError(try TeamWorkspaceBoundary(bad,account:f["account"]!.text,origin:origin))}
        var bad=f["viewer"]!.object,rows=bad["projects"]!.list
        let i=rows.firstIndex{$0.object["team_id"] != .null}!
        var p=rows[i].object;p["can_send_tasks"] = .bool(true);rows[i] = .object(p);bad["projects"] = .array(rows)
        XCTAssertThrowsError(try TeamWorkspaceBoundary(bad,account:f["account"]!.text,origin:origin))
        bad=raw;bad["projects"] = .array(raw["projects"]!.list+raw["projects"]!.list)
        XCTAssertThrowsError(try TeamWorkspaceBoundary(bad,account:f["account"]!.text,origin:origin))
        bad=raw;bad["teams"] = .array([])
        XCTAssertThrowsError(try TeamWorkspaceBoundary(bad,account:f["account"]!.text,origin:origin))
    }
    func testBoundaryAndHistoricalCustodyPersistPrivatelyButDoNotExportAuthority() throws {
        var local=try snapshot();let b=try boundary()
        local.teamWorkspace=try TeamWorkspaceCache(boundary:b,previous:nil,pending:[],tasks:local.tables["tasks"]!)
        let decoded=try JSONDecoder().decode(Snapshot.self,from:JSONEncoder().encode(local))
        XCTAssertEqual(decoded,local)
        let portable=try JSONSerialization.jsonObject(with:WorkspaceBackup.make(local,account:b.account).data()) as! [String:Any]
        XCTAssertNil(portable["teamWorkspace"])
        var old=try JSONDecoder().decode([String:JSON].self,from:JSONEncoder().encode(local));old.removeValue(forKey:"teamWorkspace")
        XCTAssertNil(try JSONDecoder().decode(Snapshot.self,from:JSONEncoder().encode(old)).teamWorkspace)
    }
    func testLossOfReadAccessRemovesSharedCacheWithoutRemovingQueuedWork() throws {
        let b=try boundary(),left=try boundary("left");var local=try snapshot()
        let task=local.tables["tasks"]![0],change=try edit(task,boundary:b)
        local.apply(change);local.pending=[change]
        let old=try TeamWorkspaceCache(boundary:b,previous:nil,pending:local.pending,tasks:local.tables["tasks"]!)
        let current=try TeamWorkspaceCache(boundary:left,previous:old,pending:local.pending,tasks:local.tables["tasks"]!)
        XCTAssertTrue(current.requiresRecovery(local))
        let result=current.merging(local.tables,into:local)
        XCTAssertEqual(result.pending,[change]);XCTAssertFalse(result.tables["tasks"]!.contains{$0.id==task.id})
        XCTAssertEqual(result.tables["tasks"]?.count,1);XCTAssertNotNil(result.tables["profiles"]?.first)
        XCTAssertTrue(result.teamWorkspace!.knownTasks.contains(task.id))
        XCTAssertFalse(result.teamWorkspace!.requiresRecovery(result))
        XCTAssertFalse(current.canSend(change,in:result))
    }
    func testViewerSeesServerVersionWhileTheirUnsentEditsStayQueued() throws {
        let b=try boundary();var local=try snapshot();let task=local.tables["tasks"]![0],change=try edit(task,boundary:b)
        let remote=local.tables;local.apply(change);local.pending=[change]
        let cache=try TeamWorkspaceCache(boundary:boundary("viewer"),previous:nil,pending:local.pending,tasks:local.tables["tasks"]!)
        let result=cache.merging(remote,into:local)
        XCTAssertEqual(result.tables["tasks"]?.first?.title,task.title)
        XCTAssertEqual(result.pending,[change]);XCTAssertEqual(local.tables["tasks"]?.first?.title,"Unsent team notes")
        XCTAssertTrue(cache.requiresRecovery(local))
    }
    func testBlockedCohortDoesNotReplayDependentEditsOrHideIndependentPersonalNotes() throws {
        let b=try boundary();var local=try snapshot();let task=local.tables["tasks"]![0],first=try edit(task,boundary:b)
        let childID=UUID().uuidString.lowercased()
        let dependent=Mutation(table:"tasks",recordID:childID,method:"POST",fields:["id":.string(childID),"recurrence_parent_id":.string(task.id),"user_id":.string(b.account),"title":.string("Dependent draft")])
        let personal=local.tables["tasks"]![1],separate=Mutation(table:"tasks",recordID:personal.id,method:"PATCH",fields:["description":.string("A reference in my own notes: "+task.id)])
        local.pending=[first,dependent,separate]
        let cache=try TeamWorkspaceCache(boundary:boundary("viewer"),previous:nil,pending:local.pending,tasks:local.tables["tasks"]!)
        XCTAssertEqual(cache.blocked(local),Set([first.id,dependent.id]))
        let result=cache.merging(local.tables,into:local)
        XCTAssertEqual(result.pending,local.pending)
        XCTAssertFalse(result.tables["tasks"]!.contains{$0.id==childID})
        XCTAssertEqual(result.tables["tasks"]!.first{$0.id==personal.id}?.string("description"),separate.fields["description"]?.text)
    }
    func testHistoricalTaskCustodyStopsOldLegacyCallbacksAfterRowsArePruned() throws {
        let b=try boundary(),local=try snapshot(),task=local.tables["tasks"]![0]
        let old=try TeamWorkspaceCache(boundary:b,previous:nil,pending:[],tasks:local.tables["tasks"]!)
        let next=try TeamWorkspaceCache(boundary:boundary("left"),previous:old,pending:[])
        let gone=next.merging(local.tables,into:local)
        let late=Mutation(table:"tasks",recordID:task.id,method:"PATCH",fields:["title":.string("Late old callback")])
        XCTAssertFalse(next.canSend(late,in:gone))
        var disguised=task;disguised["project_id"] = .null
        XCTAssertTrue(next.filtering(["tasks":[disguised]])["tasks"]!.isEmpty)
    }
    func testLocalPersonalCaptureSurvivesBoundaryRefreshWithoutServerProjectYet() throws {
        let b=try boundary(),projectID=UUID().uuidString.lowercased(),taskID=UUID().uuidString.lowercased()
        let project=Mutation(table:"projects",recordID:projectID,method:"POST",fields:["id":.string(projectID),"user_id":.string(b.account),"name":.string("Offline project")])
        let task=Mutation(table:"tasks",recordID:taskID,method:"POST",fields:["id":.string(taskID),"user_id":.string(b.account),"project_id":.string(projectID),"title":.string("Offline capture")])
        let local=Snapshot(pending:[project,task]),cache=try TeamWorkspaceCache(boundary:b,previous:nil,pending:local.pending)
        let result=cache.merging(["projects":[],"tasks":[]],into:local)
        XCTAssertEqual(result.tables["projects"]?.first?.name,"Offline project");XCTAssertEqual(result.tables["tasks"]?.first?.title,"Offline capture");XCTAssertEqual(result.pending,local.pending)
    }
    func testTeamWidgetActionsAreWithheldWithoutDisablingPersonalChildActions() throws {
        let b=try boundary();var local=try snapshot();let team=local.tables["tasks"]![0],personal=local.tables["tasks"]![1]
        let child=SubtaskTree.reference(parent:personal.id,key:"child"),teamChild=SubtaskTree.reference(parent:team.id,key:"child")
        for id in [team.id,personal.id,child,teamChild] {local.widgetCompletion.states[id] = .init(token:UUID().uuidString.lowercased(),signature:"fixture")}
        let cache=try TeamWorkspaceCache(boundary:b,previous:nil,pending:[],tasks:local.tables["tasks"]!)
        XCTAssertEqual(Set(cache.widgetTokens(local).keys),Set([personal.id,child]))
    }
    func testRevokedTaskCannotAppearInWidgetOrPinnedNotePayload() throws {
        let local=try snapshot(),b=try boundary("left"),task=local.tables["tasks"]![0]
        let old=try TeamWorkspaceCache(boundary:boundary(),previous:nil,pending:[],tasks:local.tables["tasks"]!)
        let cache=try TeamWorkspaceCache(boundary:b,previous:old,pending:[]),clean=cache.merging(local.tables,into:local)
        let pin=Record(["id":.string(PinnedNotes.key(task.id)),"user_id":.string(b.account),"ids":.array([.string(task.id)])])
        let payload=WidgetProjection.payload(tasks:clean.tables["tasks"]!,projects:clean.tables["projects"]!,account:b.account,notePins:[pin])
        let data=String(decoding:try JSONEncoder().encode(payload),as:UTF8.self)
        XCTAssertFalse(data.contains("Team secret"));XCTAssertFalse(data.contains("Private workshop"));XCTAssertFalse(data.contains("Secret workshop"))
    }
    @MainActor func testWorkspaceReaderRestartsEntireFetchAfterAccessChanges() async throws {
        let f=try fixture(),b=try boundary(),api=try backend(b.account),local=try snapshot()
        var boundaries=0,taskReads=0
        WorkspaceHTTP.handler={request,peer in
            if request.url!.path.hasSuffix("taskfold_workspace_boundary") {boundaries+=1;peer.finish(f[boundaries==1 ? "active":"left"]!);return}
            if request.url!.path=="/rest/v1/tasks" {taskReads+=1;peer.finish(.array(local.tables["tasks"]!.map{.object($0.fields)}));return}
            if request.url!.path=="/rest/v1/projects" {peer.finish(.array(local.tables["projects"]!.map{.object($0.fields)}));return}
            peer.finish(.array([]))
        };defer{WorkspaceHTTP.handler=nil}
        let read=try await api.workspaceRead(account:b.account,initial:nil,allowLegacy:false)
        XCTAssertEqual(boundaries,3);XCTAssertEqual(taskReads,2)
        XCTAssertEqual(read.boundary,try boundary("left"));XCTAssertEqual(read.tables["tasks"]?.count,1)
    }
    @MainActor func testWorkspaceReaderRejectsContinuousAccessChurnAndNeverReturnsPartialRows() async throws {
        let f=try fixture(),api=try backend(f["account"]!.text);var reads=0
        WorkspaceHTTP.handler={request,peer in if request.url!.path.hasSuffix("taskfold_workspace_boundary") {reads+=1;peer.finish(f[reads%2==1 ? "active":"viewer"]!)}else {peer.finish(.array([]))}};defer{WorkspaceHTTP.handler=nil}
        do {_=try await api.workspaceRead(account:f["account"]!.text,initial:nil,allowLegacy:false);XCTFail("partial read")}catch {XCTAssertTrue(error is TeamWorkspaceChanged)}
        XCTAssertEqual(reads,4)
    }
    @MainActor func testLegacyFallbackRequiresExplicitMissingRPCAndNoKnownTeamState() async throws {
        let b=try boundary(),api=try backend(b.account);var tables=0
        WorkspaceHTTP.handler={request,peer in if request.url!.path.hasSuffix("taskfold_workspace_boundary") || request.url!.path.hasSuffix("taskfold_teams") {peer.finish(.object(["code":.string("PGRST202")]),status:404)}else {tables+=1;peer.finish(.array([]))}};defer{WorkspaceHTTP.handler=nil}
        let read=try await api.workspaceRead(account:b.account,initial:nil,allowLegacy:true);XCTAssertNil(read.boundary)
        tables=0
        do {_=try await api.workspaceRead(account:b.account,initial:nil,allowLegacy:false);XCTFail("known team fallback")}catch {XCTAssertTrue(error is TeamWorkspaceUnavailable)}
        XCTAssertEqual(tables,0)
        WorkspaceHTTP.handler={_,peer in peer.finish(.object(["code":.string("42501")]),status:403)}
        do {_=try await api.workspaceRead(account:b.account,initial:nil,allowLegacy:true);XCTFail("permission denial is not unsupported RPC")}catch {XCTAssertFalse(error is TeamWorkspaceUnavailable)}
    }
    @MainActor func testBoundaryTransportIsBoundedPrivateAndAccountScoped() async throws {
        let b=try boundary(),api=try backend(b.account);var requests:[URLRequest]=[]
        WorkspaceHTTP.handler={request,peer in requests.append(request);peer.finish(.object(b.raw))};defer{WorkspaceHTTP.handler=nil}
        let observed=try await api.workspaceBoundary(account:b.account);XCTAssertEqual(observed,b)
        let r=try XCTUnwrap(requests.first);XCTAssertEqual(r.value(forHTTPHeaderField:"Cache-Control"),"no-store");XCTAssertFalse(r.httpShouldHandleCookies);XCTAssertEqual(r.timeoutInterval,25)
        do {_=try await api.workspaceBoundary(account:UUID().uuidString.lowercased());XCTFail("foreign account")}catch{}
        XCTAssertEqual(requests.count,1)
        WorkspaceHTTP.handler={_,peer in peer.finishData(Data(repeating:32,count:4_000_001))}
        do {_=try await api.workspaceBoundary(account:b.account);XCTFail("oversize")}catch{}
    }
    @MainActor func testBoundedTablePaginationRejectsRepeatedPagesAndUsesProfilePrimaryKey() async throws {
        let b=try boundary(),api=try backend(b.account);var requests=0
        let page=(0..<500).map{JSON.object(["id":.string("row-"+String($0))])}
        WorkspaceHTTP.handler={_,peer in requests+=1;peer.finish(.array(page))};defer{WorkspaceHTTP.handler=nil}
        do {_=try await api.rows("labels",expectedAccount:b.account,maximumRows:100000);XCTFail("repeated page")}catch{}
        XCTAssertEqual(requests,2)
        WorkspaceHTTP.handler={request,peer in XCTAssertTrue(request.url!.query!.contains("order=user_id"));peer.finish(.array([.object(["user_id":.string(b.account),"display_name":.string("Current person")])]))}
        let people=try await api.rows("profiles",expectedAccount:b.account,maximumRows:100000);XCTAssertEqual(people.count,1)
    }
    func testNewDependentWorkNeedsAnotherRecoveryButUnchangedQuarantineDoesNot() throws {
        let b=try boundary();var local=try snapshot();let task=local.tables["tasks"]![0],first=try edit(task,boundary:b)
        local.apply(first);local.pending=[first]
        let cache=try TeamWorkspaceCache(boundary:boundary("left"),previous:nil,pending:local.pending,tasks:local.tables["tasks"]!)
        var protected=cache.merging(local.tables,into:local)
        XCTAssertFalse(protected.teamWorkspace!.requiresRecovery(protected))
        let dependent=Mutation(table:"tasks",recordID:UUID().uuidString.lowercased(),method:"POST",fields:["recurrence_parent_id":.string(task.id),"title":.string("Later dependent work")])
        protected.pending.append(dependent)
        XCTAssertTrue(protected.teamWorkspace!.requiresRecovery(protected))
        XCTAssertEqual(protected.pending,[first,dependent])
    }
    func testRestoredRoleReplaysFrozenIntentWithoutRetargetingARecreatedTask() throws {
        let b=try boundary();var local=try snapshot();let task=local.tables["tasks"]![0],change=try edit(task,boundary:b)
        local.pending=[change]
        let viewer=try TeamWorkspaceCache(boundary:boundary("viewer"),previous:nil,pending:local.pending,tasks:local.tables["tasks"]!)
        let protected=viewer.merging(local.tables,into:local)
        let restored=try TeamWorkspaceCache(boundary:b,previous:protected.teamWorkspace,pending:protected.pending,tasks:protected.tables["tasks"]!)
        XCTAssertTrue(restored.canSend(change,in:protected))
        var remote=local.tables;remote["tasks"]![0]["task_generation"] = .string(UUID().uuidString.lowercased());remote["tasks"]![0]["title"] = .string("Replacement task")
        let refreshed=restored.merging(remote,into:protected)
        XCTAssertEqual(refreshed.tables["tasks"]?.first?.title,"Replacement task");XCTAssertEqual(refreshed.pending,[change])
    }
    func testRevokedDiscussionCacheIsPrunedWhileAuthoredCommentOutboxIsRetained() throws {
        let b=try boundary();var local=try snapshot();let task=local.tables["tasks"]![0],id=UUID().uuidString.lowercased()
        local.tables[SharedComment.table]=[Record(["id":.string(id),"task_id":.string(task.id),"task_generation":task["task_generation"],"project_id":task["project_id"],"author_id":.string(b.account),"body":.string("Shared private discussion"),"mention_ids":.array([]),"revision":.number(1),"created_at":.string("2026-10-24T10:00:00Z"),"updated_at":.string("2026-10-24T10:00:00Z"),"deleted_at":.null])]
        let draft=try SharedCommentChange(account:b.account,taskID:task.id,taskGeneration:task.string("task_generation"),projectID:task.string("project_id"),body:"My unsent comment")
        try ConversationOutbox.enqueue(draft.record,into:&local)
        let cache=try TeamWorkspaceCache(boundary:boundary("left"),previous:nil,pending:local.pending,tasks:local.tables["tasks"]!)
        let mention=Record(["id":.string(UUID().uuidString.lowercased()),"comment_id":.string(id),"recipient_id":.string(b.account),"revision":.number(1),"created_at":.string("2026-10-24T10:00:00Z"),"read_at":.null])
        local.tables[SharedMention.table]=[mention]
        local.tables[ConversationOutbox.viewsTable]=[Record(["id":.string("summary"),"account":.string(b.account),"version":.number(1),"total":.number(1),"unread":.number(1)])]
        let before=local
        let masked=cache.presentation(local)
        XCTAssertTrue(masked[SharedComment.table]?.isEmpty != false)
        XCTAssertTrue(masked[SharedMention.table]?.isEmpty != false)
        XCTAssertTrue(masked[ConversationOutbox.viewsTable]?.isEmpty != false)
        XCTAssertEqual(local,before)
        XCTAssertEqual(masked[ConversationOutbox.table],local.tables[ConversationOutbox.table])
        let hidden=cache.merging(local.tables,into:local)
        XCTAssertTrue(hidden.tables[SharedComment.table]?.isEmpty != false)
        XCTAssertEqual(hidden.tables[ConversationOutbox.table],local.tables[ConversationOutbox.table])
    }
    func testPausedSetupKeepsReadOnlyContentAndProtectsQueuedChanges() throws {
        let b=try boundary();var local=try snapshot();let task=local.tables["tasks"]![0],change=try edit(task,boundary:b)
        local.pending=[change]
        let paused=try TeamWorkspaceCache(boundary:boundary("paused"),previous:nil,pending:local.pending,tasks:local.tables["tasks"]!)
        XCTAssertFalse(paused.canSend(change,in:local));XCTAssertTrue(paused.requiresRecovery(local))
        XCTAssertNotNil(paused.merging(local.tables,into:local).tables["tasks"]?.first{$0.id==task.id})
    }
    @MainActor func testForeignInitialBoundaryCannotStartAWorkspaceRead() async throws {
        let b=try boundary(),api=try backend(b.account);var foreign=b.raw;foreign["account"] = .string(UUID().uuidString.lowercased())
        let other=try TeamWorkspaceBoundary(foreign,account:foreign["account"]!.text,origin:origin)
        var requests=0;WorkspaceHTTP.handler={_,peer in requests+=1;peer.finish(.array([]))};defer{WorkspaceHTTP.handler=nil}
        do {_=try await api.workspaceRead(account:b.account,initial:other,allowLegacy:false);XCTFail("foreign boundary")}catch{}
        XCTAssertEqual(requests,0)
    }

    @MainActor func testPartialTeamServiceCannotSilentlyFallBackToLegacySync() async throws {
        let b=try boundary(),api=try backend(b.account);var tables=0
        WorkspaceHTTP.handler={request,peer in
            if request.url!.path.hasSuffix("taskfold_workspace_boundary") {peer.finish(.object(["code":.string("PGRST202")]),status:404)}
            else if request.url!.path.hasSuffix("taskfold_teams") {peer.finish(.object(["enabled":.bool(true),"teams":.array([])]))}
            else {tables+=1;peer.finish(.array([]))}
        };defer{WorkspaceHTTP.handler=nil}
        do {_=try await api.workspaceRead(account:b.account,initial:nil,allowLegacy:true);XCTFail("partial team deployment")}catch {XCTAssertTrue(error is TeamWorkspaceServiceIncomplete)}
        XCTAssertEqual(tables,0)
    }
    func testPresentationMaskHidesRevokedContentBeforeMutatingOrBackingUpQueue() throws {
        let b=try boundary();var original=try snapshot();let task=original.tables["tasks"]![0],edit=try edit(task,boundary:b)
        original.apply(edit);original.pending=[edit]
        let before=try JSONEncoder().encode(original),cache=try TeamWorkspaceCache(boundary:boundary("left"),previous:nil,pending:original.pending,tasks:original.tables["tasks"]!)
        var visible=original;visible.tables=cache.presentation(original)
        XCTAssertFalse(visible.tables["tasks"]!.contains{$0.id==task.id});XCTAssertEqual(visible.pending,original.pending)
        XCTAssertEqual(try JSONDecoder().decode(Snapshot.self,from:before),original)
        let portable=String(decoding:try WorkspaceBackup.make(visible,account:b.account).data(),as:UTF8.self)
        XCTAssertFalse(portable.contains("Unsent team notes"));XCTAssertFalse(portable.contains("Private workshop instructions"))
        XCTAssertTrue(original.tables["tasks"]!.contains{$0.id==task.id})
    }

    func testDurableAccessFenceSurvivesRelaunchWithoutTaskTextAndCleanupStopsLateWrites() throws {
        let b=try boundary("left"),directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let disk=AccountRemovalDisk(directory:directory,account:b.account),fence=TeamAccessFenceDisk(disk:disk,origin:b.origin)
        try fence.save(b);XCTAssertEqual(try fence.load(),b)
        let bytes=try Data(contentsOf:disk.teamAccessFence)
        XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains("Private workshop instructions"))
        let restarted=TeamAccessFenceDisk(disk:disk,origin:b.origin);XCTAssertEqual(try restarted.load(),b)
        XCTAssertThrowsError(try TeamAccessFenceDisk(disk:disk,origin:"https://another.example").load())
        try disk.removeCache()
        XCTAssertFalse(FileManager.default.fileExists(atPath:disk.teamAccessFence.path))
        XCTAssertThrowsError(try fence.save(b));XCTAssertThrowsError(try fence.load())
    }
    func testAccessFenceRejectsDamagedDataAndOnlyClearsItsOwnScope() throws {
        let b=try boundary(),directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let disk=AccountRemovalDisk(directory:directory,account:b.account),fence=TeamAccessFenceDisk(disk:disk,origin:b.origin)
        try fence.save(b)
        XCTAssertThrowsError(try TeamAccessFenceDisk(disk:disk,origin:"https://another.example").clear())
        XCTAssertEqual(try fence.load(),b)
        try fence.clear();XCTAssertNil(try fence.load())
        try Data("damaged".utf8).write(to:disk.teamAccessFence)
        XCTAssertThrowsError(try fence.load());XCTAssertTrue(FileManager.default.fileExists(atPath:disk.teamAccessFence.path))
    }

    func testVerifiedRefreshCanRepairDamagedFenceWithoutClearingAnotherBackend() throws {
        let b=try boundary(),directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let disk=AccountRemovalDisk(directory:directory,account:b.account),fence=TeamAccessFenceDisk(disk:disk,origin:b.origin)
        try fence.save(b);try Data("damaged metadata".utf8).write(to:disk.teamAccessFence)
        try fence.clear(after:b);XCTAssertNil(try fence.load())
        try fence.save(b)
        XCTAssertThrowsError(try TeamAccessFenceDisk(disk:disk,origin:"https://another.example").clear(after:b))
        XCTAssertEqual(try fence.load(),b)
    }

    func testMissingLegacyProjectAlsoNeedsProtectionButNewOfflineProjectDoesNot() throws {
        let b=try boundary(),id=UUID().uuidString.lowercased()
        let cache=try TeamWorkspaceCache(boundary:b,previous:nil,pending:[])
        let lost=Snapshot(tables:["projects":[Record(["id":.string(id),"name":.string("Former legacy project")])]])
        XCTAssertTrue(cache.requiresRecovery(lost));XCTAssertTrue(cache.presentation(lost)["projects"]!.isEmpty)
        let create=Mutation(table:"projects",recordID:id,method:"POST",fields:["id":.string(id),"user_id":.string(b.account),"name":.string("New offline project")])
        var local=Snapshot(pending:[create]);local.apply(create)
        XCTAssertFalse(cache.requiresRecovery(local));XCTAssertEqual(cache.presentation(local)["projects"]?.count,1)
    }

    func testLocalProjectIntentCannotExposeOldCachedSharedChildrenAtSameID() throws {
        let b=try boundary(),project=UUID().uuidString.lowercased(),task=UUID().uuidString.lowercased()
        let create=Mutation(table:"projects",recordID:project,method:"POST",fields:["id":.string(project),"user_id":.string(b.account),"name":.string("My local project")])
        let old=Snapshot(tables:["projects":[Record(["id":.string(project),"user_id":.string(b.account),"name":.string("Former shared name")])],"tasks":[Record(["id":.string(task),"user_id":.string(UUID().uuidString.lowercased()),"project_id":.string(project),"title":.string("Other person's cached private task")])]],pending:[create])
        let cache=try TeamWorkspaceCache(boundary:b,previous:nil,pending:old.pending),visible=cache.presentation(old)
        XCTAssertTrue(cache.requiresRecovery(old));XCTAssertEqual(visible["projects"]?.first?.name,"My local project")
        XCTAssertTrue(visible["tasks"]?.isEmpty != false);XCTAssertEqual(old.pending,[create])
    }

}


extension TeamWorkspaceTests {
    func testConversationMetadataMatchesCurrentBoundaryAndSurvivesCodec() throws {
        let b=try boundary();var local=try snapshot()
        let cache=try TeamWorkspaceCache(boundary:b,previous:nil,pending:[],tasks:local.tables["tasks"]!)
        local.tables[ConversationOutbox.viewsTable]=[
            Record(["id":.string("summary"),"access_token":b.raw["token"]!]),
            Record(["id":.string("inbox"),"access_token":.string("old")]),
            Record(["id":.string("thread:old")])]
        let visible=cache.presentation(local)
        XCTAssertEqual(visible[ConversationOutbox.viewsTable]?.map(\.id),["summary"])
        let restored=try JSONDecoder().decode(TeamWorkspaceCache.self,from:JSONEncoder().encode(cache))
        XCTAssertEqual(restored.presentation(local)[ConversationOutbox.viewsTable],visible[ConversationOutbox.viewsTable])
        let changed=try TeamWorkspaceCache(boundary:boundary("viewer"),previous:cache,pending:[],tasks:local.tables["tasks"]!)
        XCTAssertTrue(changed.presentation(local)[ConversationOutbox.viewsTable]?.isEmpty != false)
    }
    func testNativeDiscussionWriteGateDoesNotInferTeamRightsFromTaskCreator() throws {
        let f=try fixture(),b=try boundary()
        let cache=try TeamWorkspaceCache(boundary:b,previous:nil,pending:[])
        XCTAssertFalse(cache.nativeConversationWritable(project:f["project"]!.text))
        XCTAssertTrue(cache.nativeConversationWritable(project:f["personal"]!.text))
        XCTAssertTrue(cache.nativeConversationWritable(project:f["legacy"]!.text))
        let revoked=try TeamWorkspaceCache(boundary:boundary("left"),previous:cache,pending:[])
        XCTAssertFalse(revoked.nativeConversationWritable(project:f["project"]!.text))
    }
    private func editorContext() throws -> (TeamTaskEditorDraft, TeamWorkspaceCache, Record, WorkspaceBinding, UUID) {
        let b = try boundary(); var row = try snapshot().tables["tasks"]![0]
        row["user_id"] = .string("ea350000-0000-4000-8000-000000000099") // Retained/departed creator, not current actor.
        row["opaque_future"] = .object(["kept": .bool(true)])
        let cache = try TeamWorkspaceCache(boundary: b, previous: nil, pending: [], tasks: [row]), workspace = WorkspaceBinding(account: b.account, generation: UUID()), session = UUID()
        return (try TeamTaskEditorDraft(source: row, workspace: workspace, session: session, cache: cache, enabled: true), cache, row, workspace, session)
    }

    func testTeamEditorAdmissionKeepsCapturedContextThroughSecondarySheets() throws {
        let (draft, _, row, workspace, _) = try editorContext()
        let opening = TaskEditorAdmission(workspace: workspace, record: row, root: row, kind: .existing, teamDraft: draft)
        XCTAssertTrue(opening.matches(account: workspace.account, generation: workspace.generation, currentRoot: row))
        var edited = row; edited["description"] = .string("Unsaved formatted notes")
        let nested = TaskEditorAdmission(workspace: workspace, record: edited, root: row, kind: .nested, teamDraft: opening.teamDraft)
        XCTAssertEqual(nested.teamDraft, draft)
        XCTAssertEqual(nested.teamDraft?.source, row, "Opening a sheet cannot promote unsaved fields to the captured baseline")
        XCTAssertTrue(nested.matches(account: workspace.account, generation: workspace.generation, currentRoot: row))
        XCTAssertFalse(nested.matches(account: workspace.account, generation: UUID(), currentRoot: row))
    }
    func testTeamEditorAdmissionRejectsMismatchedRootAndWorkspaceContext() throws {
        let (draft, _, row, workspace, _) = try editorContext()
        for key in ["id", "user_id", "project_id", "task_generation"] {
            var replaced = row; replaced[key] = .string(UUID().uuidString.lowercased())
            let opening = TaskEditorAdmission(workspace: workspace, record: replaced, root: replaced, kind: .existing, teamDraft: draft)
            XCTAssertFalse(opening.matches(account: workspace.account, generation: workspace.generation, currentRoot: replaced), key)
        }
        let other = WorkspaceBinding(account: workspace.account, generation: UUID())
        let opening = TaskEditorAdmission(workspace: other, record: row, root: row, kind: .nested, teamDraft: draft)
        XCTAssertFalse(opening.matches(account: other.account, generation: other.generation, currentRoot: row))
        let new = TaskEditorAdmission(workspace: workspace, record: Record.task(user: workspace.account), root: nil, kind: .new, teamDraft: draft)
        XCTAssertFalse(new.matches(account: workspace.account, generation: workspace.generation, currentRoot: nil))
    }
    func testNativeEditorCapturesRoleAuthorityRatherThanCreatorAndKeepsOrdinaryWritesClosed() throws {
        let (draft, cache, row, workspace, session) = try editorContext()
        XCTAssertNotEqual(row.string("user_id"), draft.scope.account)
        XCTAssertThrowsError(try TeamTaskEditorDraft(source: row, workspace: workspace, session: session, cache: cache, enabled: false))
        let viewer = try TeamWorkspaceCache(boundary: boundary("viewer"), previous: cache, pending: [], tasks: [row])
        XCTAssertThrowsError(try TeamTaskEditorDraft(source: row, workspace: workspace, session: session, cache: viewer, enabled: true))
        var proposed = row; proposed["title"] = .string("Reviewed title")
        let change = try XCTUnwrap(draft.mutation(desired: proposed, current: row, workspace: workspace, session: session, cache: cache, enabled: true))
        XCTAssertEqual(change.teamTaskScope, draft.scope); XCTAssertTrue(cache.canSend(change, in: Snapshot(tables: ["tasks": [row]])))
        let personal = Mutation(table: "tasks", recordID: row.id, method: "PATCH", fields: change.fields)
        XCTAssertFalse(cache.canSend(personal, in: Snapshot(tables: ["tasks": [row]])))
    }
    func testNativeEditorRejectsAccessABAAccountWorkspaceSessionAndBackendChanges() throws {
        let (draft, cache, row, workspace, session) = try editorContext()
        var changed = cache.boundary.raw; changed["token"] = .string(String(repeating: "b", count: 64))
        let next = try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(changed, account: cache.boundary.account, origin: origin), previous: cache, pending: [], tasks: [row])
        XCTAssertFalse(draft.permits(current: row, workspace: workspace, session: session, cache: next, enabled: true))
        XCTAssertFalse(draft.permits(current: row, workspace: WorkspaceBinding(account: workspace.account, generation: UUID()), session: session, cache: cache, enabled: true))
        XCTAssertFalse(draft.permits(current: row, workspace: WorkspaceBinding(account: UUID().uuidString.lowercased(), generation: workspace.generation), session: session, cache: cache, enabled: true))
        XCTAssertFalse(draft.permits(current: row, workspace: workspace, session: UUID(), cache: cache, enabled: true))
        let other = try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(cache.boundary.raw, account: cache.boundary.account, origin: "https://other.example"), previous: nil, pending: [], tasks: [row])
        XCTAssertFalse(draft.permits(current: row, workspace: workspace, session: session, cache: other, enabled: true))
        XCTAssertFalse(draft.permits(current: row, workspace: workspace, session: session, cache: cache, enabled: false))
    }
    func testNativeEditorRejectsRemovedRecreatedOrReboundTaskEvenWithSameVisibleTitle() throws {
        let (draft, cache, row, workspace, session) = try editorContext()
        XCTAssertFalse(draft.permits(current: nil, workspace: workspace, session: session, cache: cache, enabled: true))
        for key in ["id", "user_id", "project_id", "task_generation"] {
            var current = row; current[key] = .string(UUID().uuidString.lowercased())
            XCTAssertFalse(draft.permits(current: current, workspace: workspace, session: session, cache: cache, enabled: true), key)
        }
    }
    func testNativeEditorPreservesAuthoredBaselineAndConcurrentUntouchedFields() throws {
        let (draft, cache, row, workspace, session) = try editorContext()
        var desired = row; desired["title"] = .string("My new name"); desired["description"] = .string("My notes")
        var current = row; current["priority"] = .number(1); current["opaque_future"] = .object(["newer": .bool(true)]); current["title"] = .string("Teammate's new name")
        let before = current
        let change = try XCTUnwrap(draft.mutation(desired: desired, current: current, workspace: workspace, session: session, cache: cache, enabled: true))
        XCTAssertEqual(current, before); XCTAssertEqual(Set(change.fields.keys), ["title", "description"])
        XCTAssertEqual(change.baseline?["title"], row["title"]); XCTAssertEqual(change.fields["title"], desired["title"])
        XCTAssertEqual(try draft.scope.body(for: change)["base"]?.object["title"], row["title"])
        var state = Snapshot(tables: ["tasks": [current]]); state.apply(change)
        XCTAssertEqual(state.tables["tasks"]![0]["priority"], .number(1)); XCTAssertEqual(state.tables["tasks"]![0]["opaque_future"], current["opaque_future"])
        XCTAssertEqual(try JSONDecoder().decode(Mutation.self, from: JSONEncoder().encode(change)), change)
    }
    func testNativeEditorRejectsUnsupportedChangesAsAWholeWithoutDiscardingDraftFields() throws {
        let (draft, cache, row, workspace, session) = try editorContext()
        for key in ["id", "user_id", "project_id", "task_generation", "completion_version", "completed", "completed_at", "attachments", "comments", "is_recurring", "recurrence_pattern", "source_metadata", "opaque_future"] {
            var desired = row; desired["title"] = .string("Keep this draft"); desired[key] = .null
            XCTAssertThrowsError(try draft.mutation(desired: desired, current: row, workspace: workspace, session: session, cache: cache, enabled: true), key)
            XCTAssertEqual(desired["title"], .string("Keep this draft"))
        }
        var desired = row; desired.fields.removeValue(forKey: "opaque_future")
        XCTAssertThrowsError(try draft.mutation(desired: desired, current: row, workspace: workspace, session: session, cache: cache, enabled: true))
    }
    func testNativeEditorNoopDoesNotCreateARequestOrReplaceObservedWork() throws {
        let (draft, cache, row, workspace, session) = try editorContext()
        var current = row; current["description"] = .string("New remote notes")
        XCTAssertNil(try draft.mutation(desired: row, current: current, workspace: workspace, session: session, cache: cache, enabled: true))
        var desired = row; desired["description"] = current["description"]
        XCTAssertNil(try draft.mutation(desired: desired, current: current, workspace: workspace, session: session, cache: cache, enabled: true))
        desired = row; desired["title"] = .string("  ")
        XCTAssertThrowsError(try draft.mutation(desired: desired, current: row, workspace: workspace, session: session, cache: cache, enabled: true))
    }
    @MainActor func testNativeEditorMatchesActualSQLCommandAndUsesDedicatedTransport() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-task-planning-v1", withExtension: "json", subdirectory: "Fixtures"))
        let f = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))["planning"]!.object, body = f["body"]!.object, reply = f["reply"]!.object
        let account = reply["account"]!.text, team = body["team_id"]!.text, project = body["project_id"]!.text
        let source = Record(f["before"]!.object)
        var desired = source; desired.fields.merge(body["changes"]!.object) { _, b in b }
        let raw: [String: JSON] = ["workspace_boundary_protocol": .number(1), "account": .string(account), "native_team_reads_enabled": .bool(true), "setup_paused": .bool(false), "token": .string(String(repeating: "a", count: 64)), "teams": .array([.object(["id": .string(team), "revision": .number(1), "access_revision": .number(1), "state": .string("active")])]), "projects": .array([.object(["id": .string(project), "team_id": .string(team), "role": .string("editor"), "archived": .bool(false), "can_send_tasks": .bool(true)])])]
        let b = try TeamWorkspaceBoundary(raw, account: account, origin: origin), cache = try TeamWorkspaceCache(boundary: b, previous: nil, pending: [], tasks: [source]), workspace = WorkspaceBinding(account: account, generation: UUID()), session = UUID()
        let draft = try TeamTaskEditorDraft(source: source, workspace: workspace, session: session, cache: cache, enabled: true)
        let change = try XCTUnwrap(draft.mutation(desired: desired, current: source, workspace: workspace, session: session, cache: cache, enabled: true, requestID: try XCTUnwrap(UUID(uuidString: body["request_id"]!.text))))
        XCTAssertEqual(try draft.scope.body(for: change), body)
        let api = try backend(account); var calls = 0
        WorkspaceHTTP.handler = { request, peer in calls += 1; XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_edit_team_task"); peer.finish(.object(reply)) }; defer { WorkspaceHTTP.handler = nil }
        _ = try await api.send(change, expectedAccount: account); XCTAssertEqual(calls, 1)
    }

    func testNativeEditorRefusesArchivedTeamEvenIfCapabilityReplyContradictsItsState() throws {
        let (_, cache, row, workspace, session) = try editorContext()
        var raw = cache.boundary.raw
        raw["teams"] = .array(raw["teams"]!.list.map { value in var team = value.object; team["state"] = .string("archived"); return .object(team) })
        let archived = try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(raw, account: workspace.account, origin: origin), previous: cache, pending: [], tasks: [row])
        XCTAssertThrowsError(try TeamTaskEditorDraft(source: row, workspace: workspace, session: session, cache: archived, enabled: true))
    }
    func testNativeEditorChecklistIntentRetainsConcurrentOtherChildWithoutRewritingItsBaseline() throws {
        let (_, cache, original, workspace, session) = try editorContext()
        var source = original
        let a: JSON = .object(["id": .string("alpha"), "title": .string("First"), "completed": .bool(false)])
        let b: JSON = .object(["id": .string("beta"), "title": .string("Second"), "completed": .bool(false)])
        source["subtasks"] = .array([a,b])
        let draft = try TeamTaskEditorDraft(source: source, workspace: workspace, session: session, cache: cache, enabled: true)
        var desired = source, current = source, local = a.object, remote = b.object
        local["title"] = .string("My first child edit"); remote["title"] = .string("Their second child edit")
        desired["subtasks"] = .array([.object(local),b]); current["subtasks"] = .array([a,.object(remote)])
        let change = try XCTUnwrap(draft.mutation(desired: desired, current: current, workspace: workspace, session: session, cache: cache, enabled: true))
        XCTAssertEqual(change.baseline?["subtasks"], source["subtasks"])
        var state = Snapshot(tables: ["tasks": [current]]); state.apply(change)
        let children = state.tables["tasks"]![0]["subtasks"].list.map(\.object)
        XCTAssertEqual(children[0]["title"], .string("My first child edit")); XCTAssertEqual(children[1]["title"], .string("Their second child edit"))
        XCTAssertEqual(change.teamTaskScope, draft.scope)
    }

    func testNativeEditorUndoRestoresObservedStateWithFreshScopedRequest() throws {
        let (draft, cache, source, workspace, session) = try editorContext()
        var current = source; current["description"] = .string("Their observed notes")
        var desired = source; desired["description"] = .string("My authored notes")
        let change = try XCTUnwrap(draft.mutation(desired: desired, current: current, workspace: workspace, session: session, cache: cache, enabled: true))
        var state = Snapshot(tables: ["tasks": [current]])
        let history = EditHistory(changes: [change], snapshot: state)
        let inverse = try XCTUnwrap(history.undo.first)
        XCTAssertNotEqual(change.id, inverse.id); XCTAssertEqual(inverse.teamTaskScope, draft.scope)
        XCTAssertEqual(change.baseline?["description"], source["description"])
        XCTAssertEqual(inverse.fields["description"], current["description"])
        XCTAssertNoThrow(try draft.scope.body(for: inverse))
        state.apply(change); state.apply(inverse)
        XCTAssertEqual(state.tables["tasks"]![0], current)
    }

}
