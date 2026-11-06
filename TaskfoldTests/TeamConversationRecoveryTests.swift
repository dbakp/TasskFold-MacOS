import XCTest
@testable import TaskfoldCore

private final class ConversationExpiryHTTP: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        XCTAssertEqual(request.url?.path,"/rest/v1/rpc/taskfold_team_task_lifecycle")
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:410,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data("{\"code\":\"PT410\",\"message\":\"private-storage-details\"}".utf8));client?.urlProtocolDidFinishLoading(self)
    }
}
final class TeamConversationRecoveryTests: XCTestCase {
    private func fixture() throws -> [String:JSON] {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"team-conversation-recovery-v1",withExtension:"json",subdirectory:"Fixtures"))
        return try JSONDecoder().decode([String:JSON].self,from:Data(contentsOf:url))
    }
    private func snapshot(_ raw:[String:JSON]) -> Snapshot {
        Snapshot(tables:["projects":[Record(["id":raw["project"]!])],"tasks":[Record(raw["taskRow"]!.object)]])
    }
    func testSQLRecoveredDiscussionHasFreshIdentityAndPreservedReadHistory() throws {
        let f=try fixture(),before=f["before"]!.list.map{Record($0.object)},after=f["after"]!.list.map{Record($0.object)}
        XCTAssertEqual(after.count,2);XCTAssertTrue(after.allSatisfy{SharedComment($0) != nil})
        XCTAssertTrue(Set(before.map(\.id)).isDisjoint(with:Set(after.map(\.id))))
        XCTAssertTrue(after.allSatisfy{$0["task_generation"] == f["newGeneration"]})
        let active=try XCTUnwrap(after.compactMap(SharedComment.init).first{!$0.isDeleted})
        XCTAssertEqual(active.body,"Keep the design review discussion");XCTAssertNil(active.authorID)
        let messages=f["mentions"]!.list.compactMap{SharedMention(Record($0.object))}
        XCTAssertEqual(messages.count,1);XCTAssertTrue(messages[0].isRead)
        XCTAssertEqual(messages[0].row["created_at"],.string("2026-10-01T08:00:00+00:00"))
        XCTAssertEqual(messages[0].row["read_at"],.string("2026-10-02T08:00:00+00:00"))
    }
    func testLateOldGenerationCommentCannotReplaceRecoveredThread() throws {
        let f=try fixture();var value=snapshot(f)
        for row in f["after"]!.list {ConversationCache.upsert(Record(row.object),table:SharedComment.table,in:&value)}
        for row in f["before"]!.list {
            var old=Record(row.object);old["revision"] = .number(9_007_199_254_740_991)
            ConversationCache.upsert(old,table:SharedComment.table,in:&value)
        }
        ConversationCache.prune(&value)
        XCTAssertEqual(Set(value.tables[SharedComment.table]!.map(\.id)),Set(f["after"]!.list.map{$0.object["id"]!.text}))
        XCTAssertTrue(value.tables[SharedComment.table]!.allSatisfy{$0["task_generation"] == f["newGeneration"]})
    }
    func testUnsentFollowupSurvivesWithoutBindingToRecoveredGeneration() throws {
        let f=try fixture();var value=snapshot(f)
        let change=try SharedCommentChange(account:f["account"]!.text,taskID:f["task"]!.text,taskGeneration:f["oldGeneration"]!.text,projectID:f["project"]!.text,body:"Unsent follow-up")
        try ConversationOutbox.enqueue(change.record,into:&value)
        let reply=try SharedCommentReply(data:Data("{\"status\":\"unavailable\"}".utf8),change:change)
        ConversationOutbox.apply(reply,change:change,to:&value);ConversationCache.prune(&value)
        let retained=try XCTUnwrap(ConversationOutbox.rows(value,account:change.account).first)
        XCTAssertEqual(retained.string("state"),"unavailable");XCTAssertEqual(ConversationOutbox.comment(retained)?.body,"Unsent follow-up")
        XCTAssertEqual(ConversationOutbox.comment(retained)?.taskGeneration,f["oldGeneration"]!.text)
    }
    @MainActor func testExpiredRecoveryExplainsSavedTaskWithoutExposingServerDetails() async throws {
        let f=try fixture(),body=f["undoBody"]!.object,account=f["account"]!.text
        let scope=TeamTaskEditScope(account:account,origin:"https://backend.example",team:body["team_id"]!.text,project:body["project_id"]!.text,restoreRequest:UUID(uuidString:body["restore_from"]!.text))
        let change=Mutation(id:UUID(uuidString:body["request_id"]!.text)!,table:"tasks",recordID:body["task_id"]!.text,method:"POST",fields:body["record"]!.object,insertOnly:true,teamTaskScope:scope)
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ConversationExpiryHTTP.self]
        let session=try JSONDecoder().decode(Session.self,from:Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(account)\"}}".utf8))
        let api=Backend(configuration:["URL":scope.origin,"Key":"synthetic-public"],http:URLSession(configuration:config),session:session,persistSession:{_ in})
        do {_=try await api.send(change);XCTFail("Expired Undo acknowledged")}
        catch {XCTAssertTrue(error is TeamConversationRecoveryExpired);XCTAssertTrue(error.localizedDescription.contains("saved task"));XCTAssertFalse(error.localizedDescription.contains("private-storage-details"))}
    }
}
