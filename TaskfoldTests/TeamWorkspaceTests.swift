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

    private func deletionSelectionContext(count: Int = 3, notes: Int = 0) throws -> (TeamTaskDeletionSelection, TeamWorkspaceCache, [Record], WorkspaceBinding, UUID) {
        let (_, cache, source, workspace, session) = try editorContext()
        var rows: [Record] = []
        for index in 0..<count {
            var row = source; row["id"] = .string(String(format: "ea350000-0000-4000-8000-%012d", index + 100))
            row["title"] = .string("Shared selection \(index + 1)")
            if notes > 0 { row["description"] = .string(String(repeating: "n", count: notes)) }
            if index > 0 { row["recurrence_parent_id"] = rows[0]["id"] }
            rows.append(row)
        }
        let drafts = try rows.prefix(2).map { try TeamTaskEditorDraft(source: $0, workspace: workspace, session: session, cache: cache, enabled: true) }
        return (try TeamTaskDeletionSelection(drafts: drafts), cache, rows, workspace, session)
    }
    func testDeletionSelectionFreezesWholeRowsAndAllRequestIdentitiesAcrossRetry() throws {
        let (selection, cache, rows, workspace, session) = try deletionSelectionContext()
        let current = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let first = try selection.mutation(current: current, workspace: workspace, session: session, cache: cache, enabled: true)
        XCTAssertEqual(first, try selection.mutation(current: current, workspace: workspace, session: session, cache: cache, enabled: true))
        let batch = try XCTUnwrap(first.teamTaskBatch)
        XCTAssertEqual(first.id, selection.requestID); XCTAssertEqual(first.method, "TEAM_BATCH")
        XCTAssertEqual(batch.items.count, 2); XCTAssertEqual(batch.items.map(\.recordID), Array(rows.prefix(2)).map(\.id).sorted())
        XCTAssertEqual(Set(batch.items.map(\.id)).count, 2); XCTAssertFalse(batch.items.map(\.id).contains(first.id))
        for item in batch.items { XCTAssertEqual(item.baseline, current[item.recordID]?.fields); XCTAssertEqual(item.teamTaskScope?.account, workspace.account) }
        XCTAssertFalse(batch.items.contains { $0.recordID == rows[2].id }, "Review never expands to an unselected occurrence")
        XCTAssertEqual(try JSONDecoder().decode(Mutation.self, from: JSONEncoder().encode(first)), first)
    }
    func testDeletionSelectionAppliesTogetherAndUndoKeepsSelectedLinksAndUnselectedWork() throws {
        let (selection, cache, rows, workspace, session) = try deletionSelectionContext()
        let change = try selection.mutation(current: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) }), workspace: workspace, session: session, cache: cache, enabled: true)
        var snapshot = Snapshot(tables: ["tasks": rows, "projects": [Record(["id": rows[0]["project_id"]])]])
        let history = EditHistory(changes: [change], snapshot: snapshot)
        snapshot.apply(change)
        XCTAssertEqual(snapshot.tables["tasks"]?.map(\.id), [rows[2].id]); XCTAssertEqual(snapshot.tables["tasks"]?.first?["recurrence_parent_id"], .null)
        XCTAssertEqual(snapshot.tables["tasks"]?.first?["task_generation"], rows[2]["task_generation"])
        let undo = try XCTUnwrap(history.undo.first); XCTAssertEqual(undo.teamTaskBatch?.restores, change.id)
        snapshot.apply(undo)
        XCTAssertEqual(Set(snapshot.tables["tasks"]!.map(\.id)), Set(rows.map(\.id)))
        let restored = snapshot.tables["tasks"]!.first { $0.id == rows[1].id }!
        XCTAssertEqual(restored["recurrence_parent_id"], rows[0]["id"]); XCTAssertNotEqual(restored["task_generation"], rows[1]["task_generation"])
    }
    func testDeletionSelectionRefusesAnyMissingChangedOrRecreatedMemberAsAWhole() throws {
        let (selection, cache, rows, workspace, session) = try deletionSelectionContext()
        let current = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        for key in ["title", "description", "user_id", "project_id", "task_generation", "opaque_future"] {
            var changed = current; changed[rows[1].id]![key] = .string("Changed elsewhere")
            XCTAssertThrowsError(try selection.mutation(current: changed, workspace: workspace, session: session, cache: cache, enabled: true), key)
            XCTAssertEqual(current[rows[0].id], rows[0])
        }
        var missing = current; missing.removeValue(forKey: rows[1].id)
        XCTAssertThrowsError(try selection.mutation(current: missing, workspace: workspace, session: session, cache: cache, enabled: true))
    }
    func testDeletionSelectionRefusesWorkspaceSessionRoleAndRolloutChanges() throws {
        let (selection, cache, rows, workspace, session) = try deletionSelectionContext()
        let current = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let viewer = try TeamWorkspaceCache(boundary: boundary("viewer"), previous: cache, pending: [], tasks: rows)
        XCTAssertThrowsError(try selection.mutation(current: current, workspace: workspace, session: session, cache: viewer, enabled: true))
        XCTAssertThrowsError(try selection.mutation(current: current, workspace: .init(account: workspace.account, generation: UUID()), session: session, cache: cache, enabled: true))
        XCTAssertThrowsError(try selection.mutation(current: current, workspace: workspace, session: UUID(), cache: cache, enabled: true))
        XCTAssertThrowsError(try selection.mutation(current: current, workspace: workspace, session: session, cache: cache, enabled: false))
    }
    func testDeletionSelectionRefusesDuplicateEmptySingleAndCreationAdmissions() throws {
        let (selection, _, _, _, _) = try deletionSelectionContext()
        XCTAssertThrowsError(try TeamTaskDeletionSelection(drafts: []))
        XCTAssertThrowsError(try TeamTaskDeletionSelection(drafts: [selection.drafts[0]]))
        XCTAssertThrowsError(try TeamTaskDeletionSelection(drafts: [selection.drafts[0], selection.drafts[0]]))
        let (creation, _, _, _, _) = try creationContext()
        XCTAssertThrowsError(try TeamTaskDeletionSelection(drafts: [selection.drafts[0], creation]))
        XCTAssertThrowsError(try TeamTaskDeletionSelection(drafts: Array(repeating: selection.drafts[0], count: 101)))
    }
    func testDeletionSelectionRefusesMixedOpeningSessionAndWorkspace() throws {
        let (selection, cache, rows, workspace, session) = try deletionSelectionContext()
        let foreign = try TeamTaskEditorDraft(source: rows[1], workspace: workspace, session: UUID(), cache: cache, enabled: true)
        XCTAssertThrowsError(try TeamTaskDeletionSelection(drafts: [selection.drafts[0], foreign]))
        let other = try TeamTaskEditorDraft(source: rows[1], workspace: .init(account: workspace.account, generation: UUID()), session: session, cache: cache, enabled: true)
        XCTAssertThrowsError(try TeamTaskDeletionSelection(drafts: [selection.drafts[0], other]))
    }
    func testDeletionSelectionRejectsCyclesAndOverlargeWholePayloadWithoutTruncation() throws {
        let (_, cache, rows, workspace, session) = try deletionSelectionContext()
        var cyclic = rows; cyclic[0]["recurrence_parent_id"] = cyclic[1]["id"]
        let drafts = try cyclic.prefix(2).map { try TeamTaskEditorDraft(source: $0, workspace: workspace, session: session, cache: cache, enabled: true) }
        XCTAssertThrowsError(try TeamTaskDeletionSelection(drafts: drafts))
        let (_, largeCache, largeRows, binding, incarnation) = try deletionSelectionContext(count: 17, notes: 96000)
        let largeDrafts = try largeRows.map { try TeamTaskEditorDraft(source: $0, workspace: binding, session: incarnation, cache: largeCache, enabled: true) }
        let large = try TeamTaskDeletionSelection(drafts: largeDrafts)
        XCTAssertThrowsError(try large.mutation(current: Dictionary(uniqueKeysWithValues: largeRows.map { ($0.id, $0) }), workspace: binding, session: incarnation, cache: largeCache, enabled: true))
        XCTAssertEqual(large.drafts.count, 17); XCTAssertEqual(large.drafts[0].source.string("description").count, 96000)
    }
    func testDeletionSelectionAllowsDifferentProjectsOnlyInsideSameCurrentTeam() throws {
        let (_, cache, rows, workspace, session) = try deletionSelectionContext()
        let otherProject = UUID().uuidString.lowercased()
        var raw = cache.boundary.raw, projects = raw["projects"]!.list
        var permission = projects.first { $0.object["id"] == rows[0]["project_id"] }!.object
        permission["id"] = .string(otherProject); projects.append(.object(permission)); raw["projects"] = .array(projects.sorted { $0.object["id"]!.text < $1.object["id"]!.text })
        let boundary = try TeamWorkspaceBoundary(raw, account: workspace.account, origin: cache.boundary.origin)
        var across = rows; across[1]["project_id"] = .string(otherProject)
        let newCache = try TeamWorkspaceCache(boundary: boundary, previous: cache, pending: [], tasks: across)
        let drafts = try across.prefix(2).map { try TeamTaskEditorDraft(source: $0, workspace: workspace, session: session, cache: newCache, enabled: true) }
        let selection = try TeamTaskDeletionSelection(drafts: drafts)
        let change = try selection.mutation(current: Dictionary(uniqueKeysWithValues: across.map { ($0.id, $0) }), workspace: workspace, session: session, cache: newCache, enabled: true)
        XCTAssertEqual(Set(change.teamTaskBatch!.items.map { $0.teamTaskScope!.project }).count, 2)
        permission["role"] = .string("viewer"); permission["can_send_tasks"] = .bool(false); projects[projects.count - 1] = .object(permission); raw["projects"] = .array(projects.sorted { $0.object["id"]!.text < $1.object["id"]!.text })
        let reduced = try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(raw, account: workspace.account, origin: cache.boundary.origin), previous: newCache, pending: [], tasks: across)
        XCTAssertThrowsError(try selection.mutation(current: Dictionary(uniqueKeysWithValues: across.map { ($0.id, $0) }), workspace: workspace, session: session, cache: reduced, enabled: true))
    }
    func testDeletionSelectionAcceptsHundredUniqueTasksAndRefusesTheHundredAndFirst() throws {
        let (_, cache, rows, workspace, session) = try deletionSelectionContext(count: 101)
        let drafts = try rows.map { try TeamTaskEditorDraft(source: $0, workspace: workspace, session: session, cache: cache, enabled: true) }
        XCTAssertThrowsError(try TeamTaskDeletionSelection(drafts: drafts))
        let selection = try TeamTaskDeletionSelection(drafts: Array(drafts.prefix(100)))
        let change = try selection.mutation(current: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) }), workspace: workspace, session: session, cache: cache, enabled: true)
        XCTAssertEqual(change.teamTaskBatch?.items.count, 100)
    }
    func testDeletionSelectionRefusesAnotherTeamEvenWithCurrentEditorRights() throws {
        let (selection, cache, rows, workspace, session) = try deletionSelectionContext()
        let otherTeam = UUID().uuidString.lowercased(), otherProject = UUID().uuidString.lowercased()
        var raw = cache.boundary.raw, teams = raw["teams"]!.list, projects = raw["projects"]!.list
        var team = teams[0].object; team["id"] = .string(otherTeam); teams.append(.object(team)); raw["teams"] = .array(teams.sorted { $0.object["id"]!.text < $1.object["id"]!.text })
        var permission = projects.first { $0.object["id"] == rows[0]["project_id"] }!.object
        permission["id"] = .string(otherProject); permission["team_id"] = .string(otherTeam); projects.append(.object(permission)); raw["projects"] = .array(projects.sorted { $0.object["id"]!.text < $1.object["id"]!.text })
        let boundary = try TeamWorkspaceBoundary(raw, account: workspace.account, origin: cache.boundary.origin)
        let changedCache = try TeamWorkspaceCache(boundary: boundary, previous: cache, pending: [], tasks: rows)
        var other = rows[1]; other["project_id"] = .string(otherProject)
        let foreign = try TeamTaskEditorDraft(source: other, workspace: workspace, session: session, cache: changedCache, enabled: true)
        XCTAssertThrowsError(try TeamTaskDeletionSelection(drafts: [selection.drafts[0], foreign]))
    }
    private func creationContext() throws -> (TeamTaskEditorDraft, TeamWorkspaceCache, Record, WorkspaceBinding, UUID) {
        let (_, cache, existing, workspace, session) = try editorContext()
        var row = Record.task(user: workspace.account, project: existing.string("project_id"))
        row["title"] = .string("Prepare shared launch")
        return (try TeamTaskEditorDraft(creating: row, workspace: workspace, session: session, cache: cache, enabled: true), cache, row, workspace, session)
    }
    func testCreationCarriesFullAuthoredTaskAsScopedInsertOnlyCommand() throws {
        let (draft, cache, row, workspace, session) = try creationContext()
        var proposed = row
        proposed["description"] = .string("Review the three-line instructions\nCheck contrast\nPublish")
        proposed["labels"] = .array([.string("Design"), .string(UUID().uuidString.lowercased())])
        proposed["priority"] = .number(1); proposed["due_date"] = .string("2026-12-01")
        proposed["duration_minutes"] = .number(45)
        proposed["subtasks"] = .array([.object(["id": .string(UUID().uuidString.lowercased()), "title": .string("Review contrast"), "completed": .bool(false)])])
        let id = UUID()
        let change = try XCTUnwrap(draft.mutation(desired: proposed, current: nil, workspace: workspace, session: session, cache: cache, enabled: true, requestID: id))
        XCTAssertEqual(change.id, id); XCTAssertEqual(change.method, "POST"); XCTAssertEqual(change.insertOnly, true)
        XCTAssertNil(change.baseline); XCTAssertEqual(change.teamTaskScope, draft.scope)
        for key in ["id", "user_id", "task_generation", "project_id", "description", "labels", "priority", "due_date", "duration_minutes"] { XCTAssertEqual(change.fields[key], proposed.fields[key], key) }
        XCTAssertEqual(change.fields["subtasks"]?.list.count, 1)
        XCTAssertEqual(try draft.scope.lifecycleAction(for: change), "create")
        XCTAssertEqual(try draft.scope.lifecycleBody(for: change)["request_id"], .string(id.uuidString.lowercased()))
        XCTAssertFalse(cache.canSend(Mutation(table: "tasks", recordID: row.id, method: "POST", fields: proposed.fields), in: try snapshot()), "Ordinary writers stay closed")
    }
    func testPrefilledCreationStillCreatesAndRetryKeepsIdentity() throws {
        let (draft, cache, row, workspace, session) = try creationContext(), id = UUID()
        let first = try draft.mutation(desired: row, current: nil, workspace: workspace, session: session, cache: cache, enabled: true, requestID: id)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, try draft.mutation(desired: row, current: nil, workspace: workspace, session: session, cache: cache, enabled: true, requestID: id))
    }
    func testCreationRefusesExistingRowAndCannotBecomeEditOrDelete() throws {
        let (draft, cache, row, workspace, session) = try creationContext()
        XCTAssertFalse(draft.permits(current: row, workspace: workspace, session: session, cache: cache, enabled: true))
        XCTAssertThrowsError(try draft.mutation(desired: row, current: row, workspace: workspace, session: session, cache: cache, enabled: true))
        XCTAssertThrowsError(try draft.deletion(current: row, workspace: workspace, session: session, cache: cache, enabled: true, requestID: UUID()))
        let admission = TaskEditorAdmission(workspace: workspace, record: row, root: row, kind: .existing, teamDraft: draft)
        XCTAssertFalse(admission.matches(account: workspace.account, generation: workspace.generation, currentRoot: row))
    }
    func testCreationAdmissionAndNestedEditorsKeepOriginalUnpersistedIdentity() throws {
        let (draft, _, row, workspace, _) = try creationContext()
        for kind in [TaskEditorAdmission.Kind.new, .nested] {
            let opening = TaskEditorAdmission(workspace: workspace, record: row, root: nil, kind: kind, teamDraft: draft)
            XCTAssertTrue(opening.matches(account: workspace.account, generation: workspace.generation, currentRoot: nil))
            XCTAssertFalse(opening.matches(account: workspace.account, generation: UUID(), currentRoot: nil))
            XCTAssertFalse(opening.matches(account: workspace.account, generation: workspace.generation, currentRoot: row))
            var other = row; other["id"] = .string(UUID().uuidString.lowercased())
            XCTAssertFalse(TaskEditorAdmission(workspace: workspace, record: other, root: nil, kind: kind, teamDraft: draft).matches(account: workspace.account, generation: workspace.generation, currentRoot: nil))
        }
    }
    func testCreationRefusesCopiedBookkeepingPrivateContentAndUnknownFields() throws {
        let (_, cache, row, workspace, session) = try creationContext()
        for (key, value) in ["user_id": JSON.string(UUID().uuidString.lowercased()), "completed": .bool(true), "completion_version": .number(1), "comments": .array([.string("private")]), "attachments": .array([.string("private")]), "reminders": .array([.string("legacy")]), "recurrence_parent_id": .string(UUID().uuidString.lowercased()), "opaque_future": .string("unsupported")] {
            var copied = row; copied[key] = value
            XCTAssertThrowsError(try TeamTaskEditorDraft(creating: copied, workspace: workspace, session: session, cache: cache, enabled: true), key)
        }
    }
    func testCreationRejectsUnsupportedEditsWithoutDroppingAuthoredFields() throws {
        let (draft, cache, row, workspace, session) = try creationContext()
        for key in ["id", "user_id", "project_id", "task_generation", "created_at", "completion_version", "completed", "comments", "attachments", "opaque_future"] {
            var proposed = row; proposed["title"] = .string("Keep this title"); proposed[key] = .string("unsupported")
            XCTAssertThrowsError(try draft.mutation(desired: proposed, current: nil, workspace: workspace, session: session, cache: cache, enabled: true), key)
            XCTAssertEqual(proposed.title, "Keep this title")
        }
    }
    func testCreationRequiresCurrentRoleTokenSessionWorkspaceAndRollout() throws {
        let (draft, cache, row, workspace, session) = try creationContext()
        let viewer = try TeamWorkspaceCache(boundary: boundary("viewer"), previous: cache, pending: [], tasks: [])
        XCTAssertThrowsError(try TeamTaskEditorDraft(creating: row, workspace: workspace, session: session, cache: viewer, enabled: true))
        XCTAssertThrowsError(try TeamTaskEditorDraft(creating: row, workspace: workspace, session: session, cache: cache, enabled: false))
        XCTAssertThrowsError(try draft.mutation(desired: row, current: nil, workspace: workspace, session: session, cache: viewer, enabled: true))
        XCTAssertThrowsError(try draft.mutation(desired: row, current: nil, workspace: workspace, session: UUID(), cache: cache, enabled: true))
        XCTAssertThrowsError(try draft.mutation(desired: row, current: nil, workspace: .init(account: workspace.account, generation: UUID()), session: session, cache: cache, enabled: true))
        XCTAssertThrowsError(try draft.mutation(desired: row, current: nil, workspace: workspace, session: session, cache: cache, enabled: false))
    }
    func testCreationRequiresNameAndCoherentRepeatPlan() throws {
        let (draft, cache, row, workspace, session) = try creationContext()
        var proposed = row; proposed["title"] = .string("  ")
        XCTAssertThrowsError(try draft.mutation(desired: proposed, current: nil, workspace: workspace, session: session, cache: cache, enabled: true))
        proposed = row; proposed["is_recurring"] = .bool(true); proposed["recurrence_pattern"] = .object(["type": .string("daily"), "interval": .number(1)])
        XCTAssertThrowsError(try draft.mutation(desired: proposed, current: nil, workspace: workspace, session: session, cache: cache, enabled: true))
        proposed["due_date"] = .string("2026-12-01")
        XCTAssertNotNil(try draft.mutation(desired: proposed, current: nil, workspace: workspace, session: session, cache: cache, enabled: true))
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
        for key in ["id", "user_id", "project_id", "task_generation", "completion_version", "completed", "completed_at", "attachments", "comments", "is_recurring", "source_metadata", "opaque_future"] {
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

extension TeamWorkspaceTests {
    func testDeletionReviewKeepsWholeSourceAndStableIntentWithRetainedCreator() throws {
        let (draft, cache, row, workspace, session) = try editorContext(), request = UUID()
        let change = try draft.deletion(current: row, workspace: workspace, session: session, cache: cache, enabled: true, requestID: request)
        XCTAssertEqual(change.id, request); XCTAssertEqual(change.method, "DELETE"); XCTAssertTrue(change.fields.isEmpty)
        XCTAssertEqual(change.baseline, row.fields); XCTAssertEqual(change.teamTaskScope, draft.scope)
        XCTAssertNotEqual(row.string("user_id"), workspace.account)
        XCTAssertEqual(try draft.scope.lifecycleBody(for: change)["record"], .object(row.fields))
        XCTAssertEqual(try draft.deletion(current: row, workspace: workspace, session: session, cache: cache, enabled: true, requestID: request), change)
        XCTAssertEqual(try JSONDecoder().decode(Mutation.self, from: JSONEncoder().encode(change)), change)
    }
    func testDeletionReviewRejectsEveryChangedSavedFieldInsteadOfRetargetingBaseline() throws {
        let (draft, cache, row, workspace, session) = try editorContext()
        for (key, value): (String, JSON) in [("title", .string("New title")), ("description", .string("A colleague's new notes")), ("priority", .number(1)), ("subtasks", .array([])), ("attachments", .array([.object(["name": .string("new.pdf")])])), ("comments", .array([.string("new history")])), ("completion_version", .number(2)), ("opaque_future", .object(["new": .bool(true)]))] {
            var current = row; current[key] = value
            if current[key] != row[key] { XCTAssertThrowsError(try draft.deletion(current: current, workspace: workspace, session: session, cache: cache, enabled: true, requestID: UUID()), key) }
        }
    }
    func testDeletionReviewRejectsRecreatedRemovedMovedAndReassignedCreator() throws {
        let (draft, cache, row, workspace, session) = try editorContext()
        XCTAssertThrowsError(try draft.deletion(current: nil, workspace: workspace, session: session, cache: cache, enabled: true, requestID: UUID()))
        for key in ["id", "project_id", "task_generation", "user_id"] {
            var current = row; current[key] = .string(UUID().uuidString.lowercased())
            XCTAssertThrowsError(try draft.deletion(current: current, workspace: workspace, session: session, cache: cache, enabled: true, requestID: UUID()), key)
        }
    }
    func testDeletionReviewCannotAcquireNewWorkspaceSessionOrBackendAuthority() throws {
        let (draft, cache, row, workspace, session) = try editorContext()
        for next in [WorkspaceBinding(account: workspace.account, generation: UUID()), WorkspaceBinding(account: UUID().uuidString.lowercased(), generation: workspace.generation)] {
            XCTAssertThrowsError(try draft.deletion(current: row, workspace: next, session: session, cache: cache, enabled: true, requestID: UUID()))
        }
        XCTAssertThrowsError(try draft.deletion(current: row, workspace: workspace, session: UUID(), cache: cache, enabled: true, requestID: UUID()))
        let other = try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(cache.boundary.raw, account: workspace.account, origin: "https://other.example"), previous: nil, pending: [], tasks: [row])
        XCTAssertThrowsError(try draft.deletion(current: row, workspace: workspace, session: session, cache: other, enabled: true, requestID: UUID()))
        XCTAssertThrowsError(try draft.deletion(current: row, workspace: workspace, session: session, cache: cache, enabled: false, requestID: UUID()))
    }
    func testDeletionReviewRejectsChangedAndRestoredAccessFence() throws {
        let (draft, cache, row, workspace, session) = try editorContext()
        var raw = cache.boundary.raw; raw["token"] = .string(String(repeating: "b", count: 64))
        let later = try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(raw, account: workspace.account, origin: origin), previous: cache, pending: [], tasks: [row])
        XCTAssertThrowsError(try draft.deletion(current: row, workspace: workspace, session: session, cache: later, enabled: true, requestID: UUID()))
    }
    func testDeletionReviewUsesCanonicalClockAndTimestampSpellingWithoutDroppingSource() throws {
        let (_, cache, initial, workspace, session) = try editorContext()
        var row = initial; row["due_time"] = .string("09:00"); row["created_at"] = .string("2026-10-25T10:00:00Z")
        let draft = try TeamTaskEditorDraft(source: row, workspace: workspace, session: session, cache: cache, enabled: true)
        var current = row; current["due_time"] = .string("09:00:00"); current["created_at"] = .string("2026-10-25T10:00:00+00:00")
        let change = try draft.deletion(current: current, workspace: workspace, session: session, cache: cache, enabled: true, requestID: UUID())
        XCTAssertEqual(change.baseline, row.fields); XCTAssertEqual(change.baseline?["opaque_future"], initial["opaque_future"])
    }
    func testDeletionReviewUndoUsesExactDeletionReceiptAndFreshGeneration() throws {
        let (draft, cache, row, workspace, session) = try editorContext()
        let change = try draft.deletion(current: row, workspace: workspace, session: session, cache: cache, enabled: true, requestID: UUID())
        var snapshot = Snapshot(tables: ["tasks": [row]])
        let history = EditHistory(changes: [change], snapshot: snapshot); snapshot.apply(change)
        XCTAssertTrue(snapshot.tables["tasks"]!.isEmpty)
        let undo = TaskGeneration.restoring(TeamTaskEditScope.historyAction(try XCTUnwrap(history.undo.first)), existing: nil)
        XCTAssertEqual(undo.teamTaskScope?.restoreRequest, change.id); XCTAssertNotEqual(undo.fields["task_generation"], row["task_generation"])
        XCTAssertEqual(undo.fields["user_id"], row["user_id"]); XCTAssertEqual(undo.fields["opaque_future"], row["opaque_future"])
        XCTAssertNoThrow(try undo.teamTaskScope!.lifecycleBody(for: undo))
    }
    func testDeletionReviewRefusesOversizedPayloadRatherThanTruncatingSavedContents() throws {
        let (_, cache, initial, workspace, session) = try editorContext()
        var row = initial; row["description"] = .string(String(repeating: "x", count: 128001))
        let draft = try TeamTaskEditorDraft(source: row, workspace: workspace, session: session, cache: cache, enabled: true)
        XCTAssertThrowsError(try draft.deletion(current: row, workspace: workspace, session: session, cache: cache, enabled: true, requestID: UUID()))
        XCTAssertEqual(row.string("description").count, 128001)
    }
}

extension TeamWorkspaceTests {
    private func connectionDestination(_ id: String?, _ rows: [Record], _ cache: TeamWorkspaceCache?, account: String? = nil, server: String? = nil) throws -> PersonalConnectionDestination {
        PersonalConnectionDestination.resolve(project: id, projects: rows, cache: cache, account: try account ?? boundary().account, origin: server ?? origin)
    }
    func testPersonalConnectionsUseCertifiedPersonalProjectsAndInbox() throws {
        let b = try boundary(), rows = try snapshot().tables["projects"]!, f = try fixture()
        let c = try TeamWorkspaceCache(boundary: b, previous: nil, pending: [])
        XCTAssertEqual(try connectionDestination(nil, rows, c), .inbox)
        XCTAssertEqual(try connectionDestination(f["personal"]!.text, rows, c), .personal)
        XCTAssertEqual(try connectionDestination(f["project"]!.text, rows, c), .team)
        XCTAssertEqual(try rows.filter { try connectionDestination($0.id, rows, c).supported }.map(\.id), [f["personal"]!.text, f["legacy"]!.text])
    }
    func testPersonalConnectionsRememberTeamCustodyAfterAccessIsLost() throws {
        let f = try fixture(), b = try boundary(), old = try TeamWorkspaceCache(boundary: b, previous: nil, pending: [])
        let left = try TeamWorkspaceCache(boundary: boundary("left"), previous: old, pending: [])
        let id = f["project"]!.text
        XCTAssertNil(left.boundary.projects[id])
        XCTAssertEqual(try connectionDestination(id, [], left), .team)
        XCTAssertFalse(try connectionDestination(id, snapshot().tables["projects"]!, left).supported)
    }
    func testPersonalConnectionsRejectForeignAccountAndServerCaches() throws {
        let rows = try snapshot().tables["projects"]!, f = try fixture(), c = try TeamWorkspaceCache(boundary: boundary(), previous: nil, pending: [])
        XCTAssertEqual(try connectionDestination(f["personal"]!.text, rows, c, account: UUID().uuidString.lowercased()), .unavailable)
        XCTAssertEqual(try connectionDestination(f["personal"]!.text, rows, c, server: "https://other.example"), .unavailable)
        XCTAssertEqual(PersonalConnectionDestination.resolve(project: f["personal"]!.text, projects: rows, cache: c, account: c.boundary.account, origin: nil), .unavailable)
    }
    func testPersonalConnectionsRequireBothCurrentAccessAndAVisibleRow() throws {
        let f = try fixture(), c = try TeamWorkspaceCache(boundary: boundary(), previous: nil, pending: [])
        XCTAssertEqual(try connectionDestination(f["personal"]!.text, [], c), .unavailable)
        let unknown = Record(["id": .string(UUID().uuidString.lowercased()), "name": .string("Unconfirmed project")])
        XCTAssertEqual(try connectionDestination(unknown.id, [unknown], c), .unavailable)
        XCTAssertFalse(try connectionDestination(unknown.id, [], nil).supported)
    }
    func testPersonalConnectionsPreserveLegacyPersonalSharingWithoutInventingTeamAccess() throws {
        let f = try fixture(), rows = try snapshot().tables["projects"]!
        XCTAssertEqual(try connectionDestination(f["personal"]!.text, rows, nil), .personal)
        for marker: JSON in [.string(f["team"]!.text), .string(""), .number(1)] {
            var row = rows[0]; row["team_id"] = marker
            XCTAssertFalse(try connectionDestination(row.id, [row], nil).supported)
        }
    }
    func testPersonalConnectionExplanationsRetainSafeControlsWithoutExposingNames() {
        XCTAssertNil(PersonalConnectionDestination.inbox.explanation)
        XCTAssertNil(PersonalConnectionDestination.personal.explanation)
        XCTAssertTrue(PersonalConnectionDestination.team.explanation!.contains("revoke"))
        XCTAssertTrue(PersonalConnectionDestination.unavailable.explanation!.contains("Refresh"))
        XCTAssertFalse(PersonalConnectionDestination.team.supported)
        XCTAssertFalse(PersonalConnectionDestination.unavailable.supported)
    }
}


extension TeamWorkspaceTests {
    func testNativeSharedCheckboxUsesCapturedAtomicCompletionAndUndo() throws {
        let (draft, cache, row, workspace, session) = try editorContext()
        let change = try draft.completionMutation(current: row, tasks: [row], workspace: workspace, session: session, cache: cache, enabled: true)
        XCTAssertEqual(change.method, "TEAM_COMPLETE"); XCTAssertNil(change.teamTaskScope)
        let command = try XCTUnwrap(change.teamCompletion)
        XCTAssertEqual(command.source, row); XCTAssertEqual(command.scope, draft.scope)
        XCTAssertNil(command.proposed)
        var saved = Snapshot(tables: ["tasks": [row], "projects": [Record(["id": row["project_id"]])]])
        XCTAssertTrue(command.apply(to: &saved, header: change))
        XCTAssertTrue(saved.tables["tasks"]![0].completed)
        XCTAssertEqual(saved.tables["tasks"]![0]["opaque_future"], row["opaque_future"])
        let undo = try command.inverse(of: change)
        XCTAssertEqual(undo.teamCompletion?.related, change.id)
        XCTAssertTrue(undo.teamCompletion!.apply(to: &saved, header: undo))
        XCTAssertFalse(saved.tables["tasks"]![0].completed)
    }
    func testNativeSharedCheckboxRefusesStaleOrMissingVisibleRow() throws {
        let (draft, cache, row, workspace, session) = try editorContext()
        for key in ["title", "description", "project_id", "task_generation", "completion_version", "opaque_future"] {
            var changed = row; changed[key] = .string("changed")
            XCTAssertThrowsError(try draft.completionMutation(current: changed, tasks: [changed], workspace: workspace, session: session, cache: cache, enabled: true), key)
        }
        XCTAssertThrowsError(try draft.completionMutation(current: nil, tasks: [], workspace: workspace, session: session, cache: cache, enabled: true))
        XCTAssertThrowsError(try draft.completionMutation(current: row, tasks: [], workspace: workspace, session: session, cache: cache, enabled: true))
    }
    func testNativeSharedCheckboxRefusesWorkspaceSessionRoleAndRolloutChanges() throws {
        let (draft, cache, row, workspace, session) = try editorContext()
        let viewer = try TeamWorkspaceCache(boundary: boundary("viewer"), previous: cache, pending: [], tasks: [row])
        for context in [cache, viewer] {
            XCTAssertThrowsError(try draft.completionMutation(current: row, tasks: [row], workspace: workspace, session: UUID(), cache: context, enabled: true))
        }
        XCTAssertThrowsError(try draft.completionMutation(current: row, tasks: [row], workspace: workspace, session: session, cache: viewer, enabled: true))
        XCTAssertThrowsError(try draft.completionMutation(current: row, tasks: [row], workspace: .init(account: workspace.account, generation: UUID()), session: session, cache: cache, enabled: true))
        XCTAssertThrowsError(try draft.completionMutation(current: row, tasks: [row], workspace: .init(account: "other", generation: workspace.generation), session: session, cache: cache, enabled: true))
        XCTAssertThrowsError(try draft.completionMutation(current: row, tasks: [row], workspace: workspace, session: session, cache: cache, enabled: false))
    }
    func testNativeSharedRecurringCheckboxKeepsOneCommandAndOwnedSuccessor() throws {
        let (_, cache, original, workspace, session) = try editorContext()
        var row = original; row["is_recurring"] = .bool(true); row["recurrence_pattern"] = .object(["type": .string("daily"), "interval": .number(1)]); row["due_date"] = .string("2026-10-25")
        let draft = try TeamTaskEditorDraft(source: row, workspace: workspace, session: session, cache: cache, enabled: true)
        let change = try draft.completionMutation(current: row, tasks: [row], workspace: workspace, session: session, cache: cache, enabled: true, at: TaskPlanning.instant("2026-10-25T12:00:00Z")!, zone: "UTC")
        let command = try XCTUnwrap(change.teamCompletion), next = try XCTUnwrap(command.proposed)
        XCTAssertEqual(next["user_id"], .string(workspace.account)); XCTAssertEqual(next["project_id"], row["project_id"])
        XCTAssertEqual(next["due_date"], .string("2026-10-26")); XCTAssertEqual(command.source["user_id"], row["user_id"])
        var saved = Snapshot(tables: ["tasks": [row], "projects": [Record(["id": row["project_id"]])]])
        XCTAssertTrue(command.apply(to: &saved, header: change)); XCTAssertEqual(saved.tables["tasks"]?.count, 2)
        let undo = try command.inverse(of: change)
        XCTAssertTrue(undo.teamCompletion!.apply(to: &saved, header: undo)); XCTAssertEqual(saved.tables["tasks"]?.count, 1)
    }
    func testNativeSharedReopenPreservesLaterOccurrenceAndUsesScopedRevision() throws {
        let (_, cache, original, workspace, session) = try editorContext()
        var row = original; row["completed"] = .bool(true); row["completed_at"] = .string("2026-10-25T12:00:00Z"); row["completion_version"] = .number(3)
        var later = original; later["id"] = .string(UUID().uuidString.lowercased()); later["recurrence_parent_id"] = .string(row.id)
        let draft = try TeamTaskEditorDraft(source: row, workspace: workspace, session: session, cache: cache, enabled: true)
        let change = try draft.completionMutation(current: row, tasks: [row, later], workspace: workspace, session: session, cache: cache, enabled: true)
        XCTAssertEqual(change.method, "PATCH"); XCTAssertNil(change.teamCompletion); XCTAssertEqual(change.teamTaskScope, draft.scope)
        XCTAssertEqual(change.fields, ["completed": .bool(false), "completed_at": .null]); XCTAssertEqual(change.baseline?["completion_version"], .number(3))
        XCTAssertEqual(try draft.scope.body(for: change)["task_generation"], row["task_generation"])
        var saved = Snapshot(tables: ["tasks": [row, later]]); saved.apply(change)
        XCTAssertFalse(saved.tables["tasks"]![0].completed); XCTAssertEqual(saved.tables["tasks"]![1], later)
    }
}


extension TeamWorkspaceTests {
    func testNativeSharedCheckboxKeepsUnknownRepeatSemanticsUnchanged() throws {
        let (_, cache, original, workspace, session) = try editorContext()
        var row = original; row["is_recurring"] = .bool(true); row["due_date"] = .string("2026-10-25")
        row["recurrence_pattern"] = .object(["type": .string("daily"), "interval": .number(1), "futurePolicy": .string("keep")])
        let draft = try TeamTaskEditorDraft(source: row, workspace: workspace, session: session, cache: cache, enabled: true)
        XCTAssertThrowsError(try draft.completionMutation(current: row, tasks: [row], workspace: workspace, session: session, cache: cache, enabled: true))
        XCTAssertEqual(draft.source, row)
    }
    func testChildHistoryUsesSameScopeMaskAndPrunesActorsAfterRevocation() throws {
        let b = try boundary(); var local = try snapshot(); var task = local.tables["tasks"]![0]
        task["task_generation"] = .string(UUID().uuidString.lowercased())
        task["subtasks"] = .array([.object(["id": .string("child"), "title": .string("Synthetic child"), "completed": .bool(false)])])
        local.tables["tasks"]![0] = task
        let change = Mutation(table: "tasks", recordID: task.id, method: "POST", fields: task.fields)
        var events = TaskNodeActivity.localRows(change, before: nil, after: task, account: b.account, recordedAt: Date())
        XCTAssertEqual(events.count, 1)
        let actor = UUID().uuidString.lowercased(); events[0]["actor_id"] = .string(actor)
        local.tables[TaskNodeActivity.table] = events
        local.tables[TaskNodeActivity.epochTable] = [Record(["id": .string("current"), "recorded_from": .string(Dates.timestamp())])]
        local.tables["profiles", default: []].append(Record(["user_id": .string(actor), "display_name": .string("Synthetic actor")]))
        let previous = try TeamWorkspaceCache(boundary: b, previous: nil, pending: [], tasks: local.tables["tasks"]!)
        XCTAssertEqual(previous.filtering(local.tables)[TaskNodeActivity.table], events)
        XCTAssertNotNil(previous.filtering(local.tables)["profiles"]?.first { $0.string("user_id") == actor })
        let revoked = try TeamWorkspaceCache(boundary: boundary("left"), previous: previous, pending: [])
        let hidden = revoked.presentation(local)
        XCTAssertEqual(hidden[TaskNodeActivity.table], []); XCTAssertNil(hidden["profiles"]?.first { $0.string("user_id") == actor })
        let merged = previous.merging(["tasks": local.tables["tasks"]!], into: local)
        XCTAssertNil(merged.tables[TaskNodeActivity.table]); XCTAssertNil(merged.tables[TaskNodeActivity.epochTable])
        // An event spanning an unavailable prior project must not disclose it,
        // even if its current root is in a readable project.
        var moved = events[0]; var before = moved["after_state"].object
        before["project_id"] = .string(UUID().uuidString.lowercased()); moved["before_state"] = .object(before)
        local.tables[TaskNodeActivity.table] = [moved]
        XCTAssertEqual(previous.filtering(local.tables)[TaskNodeActivity.table], [])
    }
    @MainActor func testWorkspaceStillRefreshesTasksWhenOptionalChildHistoryFails() async throws {
        let f = try fixture(), b = try boundary(), api = try backend(b.account), local = try snapshot()
        WorkspaceHTTP.handler = { request, peer in
            switch request.url!.lastPathComponent {
            case "taskfold_workspace_boundary": peer.finish(f["active"]!)
            case "task_node_activity_epoch": peer.finish(.object(["message": .string("Not installed")]), status: 404)
            case "tasks": peer.finish(.array(local.tables["tasks"]!.map { .object($0.fields) }))
            case "projects": peer.finish(.array(local.tables["projects"]!.map { .object($0.fields) }))
            default: peer.finish(.array([]))
            }
        }
        defer { WorkspaceHTTP.handler = nil }
        let read = try await api.workspaceRead(account: b.account, initial: nil, allowLegacy: false)
        XCTAssertEqual(read.tables["tasks"]?.count, local.tables["tasks"]?.count)
        XCTAssertNil(read.tables[TaskNodeActivity.table]); XCTAssertNil(read.tables[TaskNodeActivity.epochTable]); XCTAssertEqual(read.boundary, b)
    }

}


extension TeamWorkspaceTests {
    func testSharedHeadingAuthoringRequiresAppOptInAndBothLiveCapturedCapabilities() throws {
        let f = try fixture(); var raw = try boundary().raw
        raw["task_types_protocol"] = .number(1); raw["task_type_lifecycle_protocol"] = .number(1)
        let boundary = try TeamWorkspaceBoundary(raw, account: f["account"]!.text, origin: origin)
        var row = Record.task(user: boundary.account, project: f["project"]!.text); row["title"] = .string("Shared heading proof"); row["task_generation"] = .string(UUID().uuidString.lowercased())
        let cache = try TeamWorkspaceCache(boundary: boundary, previous: nil, pending: [], tasks: [row])
        let draft = try TeamTaskEditorDraft(source: row, workspace: WorkspaceBinding(account: boundary.account, generation: UUID()), session: UUID(), cache: cache, enabled: true)
        XCTAssertTrue(TeamTaskTypes.authoringAvailable(scope: draft.scope, cache: cache, enabled: true))
        XCTAssertFalse(TeamTaskTypes.authoringAvailable(scope: draft.scope, cache: cache, enabled: false))
        var legacy = draft.scope; legacy.taskTypesProtocol = nil
        XCTAssertFalse(TeamTaskTypes.authoringAvailable(scope: legacy, cache: cache, enabled: true))
        legacy = draft.scope; legacy.taskTypeLifecycleProtocol = nil
        XCTAssertFalse(TeamTaskTypes.authoringAvailable(scope: legacy, cache: cache, enabled: true))
        for key in ["task_types_protocol", "task_type_lifecycle_protocol"] {
            for value in [JSON.number(0), .number(2), .null] {
                var changed = raw; changed[key] = value
                let live = try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(changed, account: boundary.account, origin: origin), previous: cache, pending: [], tasks: [row])
                XCTAssertFalse(TeamTaskTypes.authoringAvailable(scope: draft.scope, cache: live, enabled: true), key)
            }
        }
        let otherOrigin = try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(raw, account: boundary.account, origin: "https://other.example"), previous: nil, pending: [], tasks: [row])
        XCTAssertFalse(TeamTaskTypes.authoringAvailable(scope: draft.scope, cache: otherOrigin, enabled: true))
        var viewer = try self.boundary("viewer").raw; viewer["task_types_protocol"] = .number(1); viewer["task_type_lifecycle_protocol"] = .number(1)
        let revoked = try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(viewer, account: boundary.account, origin: origin), previous: cache, pending: [], tasks: [row])
        XCTAssertFalse(TeamTaskTypes.authoringAvailable(scope: draft.scope, cache: revoked, enabled: true))
    }
}
