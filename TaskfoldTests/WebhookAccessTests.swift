import XCTest
@testable import TaskfoldCore

private final class WebhookMemory: CalendarSecureItemIO, @unchecked Sendable {
    var data: [String: Data] = [:]
    var failing = false
    func read(key: String) throws -> Data? { if failing { throw WebhookValue.invalid }; return data[key] }
    func write(_ data: Data, key: String) throws { if failing { throw WebhookValue.invalid }; self.data[key] = data }
    func remove(key: String) throws { if failing { throw WebhookValue.invalid }; data.removeValue(forKey:key) }
}
private func wid(_ n:Int)->String { "f0b1cafe-0000-4000-8000-" + String(format:"%012d",n) }
private let wa = wid(1), wo = "https://backend.example"
private func summary() -> [String: JSON] { ["version":.number(1),"pending":.number(1),"retained_bytes":.number(100),"missed":.number(0),"capture_issue":.null,"missed_since":.null,"missed_until":.null,"blocked_reason":.null,"last_error":.null,"last_success":.null,"last_failure":.null,"delivered":.number(0),"failed":.number(0)] }
private func connection(_ d:WebhookDraft? = nil, state:String="pending") -> [String:JSON] { ["id":.string(d?.id ?? wid(21)),"revision":.string(wid(22)),"name":.string(d?.name ?? "Design pipeline"),"origin":.string("https://receiver.example"),"scope":.string(d?.scope ?? "inbox"),"project_id":d?.project.map(JSON.string) ?? .null,"events":.array((d?.events ?? [.created]).map{.string($0.rawValue)}),"state":.string(state),"created_at":.string("2026-10-23T00:00:00Z"),"expires_at":.string("2026-11-22T00:00:00Z"),"verified_at":.null,"revoked_at":.null,"delivery":.object(summary())] }
private func eventRow() -> [String:JSON] { ["id":.string(wid(31)),"task_id":.string(wid(32)),"task_generation":.string(wid(33)),"type":.string("task.created"),"status":.string("failed"),"created_at":.string("2026-10-23T00:00:00Z"),"expires_at":.string("2026-10-24T00:00:00Z"),"finished_at":.string("2026-10-23T01:00:00Z"),"next_attempt_at":.string("2026-10-23T01:00:00Z"),"parts":.number(3),"parts_delivered":.number(1),"attempts":.number(12),"manual_retries":.number(0),"error":.string("attempts_exhausted"),"http_status":.number(503)] }
@MainActor private final class WebhookMock: WebhookService {
    var calls: [(String,[String:JSON])] = []
    var reply: ((String,[String:JSON]) async throws -> [String:JSON])?
    func webhookReceipt(action:String,body:[String:JSON],account:String,origin:String) async throws -> [String:JSON] { calls.append((action,body)); return try await reply?(action,body) ?? ["account":.string(account),"subscriptions":.array([]),"next_cursor":.null] }
}
final class WebhookAccessTests: XCTestCase {
    private func draft(_ id:Int=21) throws -> WebhookDraft { try WebhookDraft(account:wa,origin:wo,name:"Design pipeline",endpoint:"https://receiver.example/events?private=fixture",scope:"inbox",project:nil,events:[.created],days:30,id:UUID(uuidString:wid(id))!,entropy:{Data(0..<32)}) }
    func testSecretValidationAndRedaction() throws {
        let d = try draft(); XCTAssertEqual(d.secret,"tfwh_v1_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        XCTAssertFalse(String(reflecting:d).contains(d.secret)); XCTAssertFalse(String(describing:d).contains("private=fixture"))
        XCTAssertTrue(WebhookValue.sameReceiverOrigin("https://receiver.example","https://RECEIVER.example:443/path?private=x"))
        XCTAssertTrue(WebhookValue.sameReceiverOrigin("https://[2606:4700:4700::1111]","https://[2606:4700:4700:0:0:0:0:1111]/events"))
        XCTAssertFalse(WebhookValue.sameReceiverOrigin("https://other.example","https://receiver.example/events"))
        XCTAssertEqual(d.body["secret"],.string(d.secret)); XCTAssertEqual(d.body["project_id"],.null)
        for address in ["http://receiver.example/","https://user:pass@receiver.example/","https://receiver.example/#secret","https://receiver.example:444/","https://receiver.example/ bad"] { XCTAssertFalse(WebhookValue.endpoint(address)) }
        XCTAssertThrowsError(try WebhookDraft(account:wa,origin:wo,name:"Bad",endpoint:"https://receiver.example",scope:"project",project:nil,events:[.created],days:30))
        XCTAssertThrowsError(try WebhookDraft(account:wa,origin:wo,name:"Bad",endpoint:"https://receiver.example",scope:"inbox",project:nil,events:[],days:30))
    }
    func testStrictMetadataAndWarnings() throws {
        XCTAssertEqual(try WebhookConnection(connection()).delivery.pending,1)
        for (key,value) in [("revision",JSON.string("bad")),("events",.array([.string("task.other")])),("delivery",.null),("origin",.string("https://receiver.example/private?secret=x")),("state",.string("enabled"))] { var row = connection();row[key] = value;XCTAssertThrowsError(try WebhookConnection(row)) }
        var s = summary();s["missed"] = .number(3);s["capture_issue"] = .string("event_quota");XCTAssertTrue(try WebhookDelivery(s).recovery!.contains("3 changes"))
        s["pending"] = .number(257);XCTAssertThrowsError(try WebhookDelivery(s))
        let e = try WebhookHistoryEvent(eventRow());XCTAssertEqual(e.partsDelivered,1)
        var er = eventRow();er["parts_delivered"] = .number(4);XCTAssertThrowsError(try WebhookHistoryEvent(er))
    }
    func testVaultRetainsExactSetupCancellationAndOriginFence() async throws {
        let io = WebhookMemory(), vault = WebhookEnrollmentVault(io:io), lease = CalendarReadLease(), d = try draft()
        let first = try await vault.begin(d,lease:lease);XCTAssertEqual(first.draft.body,d.body)
        let old = try await vault.begin(draft(24),lease:lease);XCTAssertEqual(old.draft.body,d.body)
        let restarted = WebhookEnrollmentVault(io:io);let recovered = try await restarted.recovery(account:wa,origin:wo);XCTAssertEqual(recovered?.draft.secret,d.secret)
        do { _ = try await vault.recovery(account:wa,origin:"https://other.example");XCTFail() } catch { }
        try await restarted.cancel(d,lease:lease)
        do { try await vault.finish(d,lease:lease);XCTFail() } catch { }
        let cancelled = try await vault.recovery(account:wa,origin:wo);XCTAssertTrue(cancelled?.cancelling == true)
        try await restarted.finish(d,lease:lease,cancelled:true);XCTAssertTrue(io.data.isEmpty)
    }
    func testVaultCannotClearNewerSetupAndFailsClosedOnStorage() async throws {
        let io = WebhookMemory(),v = WebhookEnrollmentVault(io:io),lease = CalendarReadLease(),d = try draft()
        _ = try await v.begin(d,lease:lease)
        do { try await v.finish(draft(25),lease:lease);XCTFail() } catch { }
        io.failing = true
        do { _ = try await v.recovery(account:wa,origin:wo);XCTFail() } catch { }
        io.failing = false;let saved = try await v.recovery(account:wa,origin:wo);XCTAssertEqual(saved?.draft.id,d.id)
        try await v.removeAccount(wa,origin:"https://other.example");XCTAssertFalse(io.data.isEmpty)
        try await v.removeAccount(wa,origin:wo);XCTAssertTrue(io.data.isEmpty)
    }
    @MainActor func testFailedCreateRelaunchUsesExactDraftAndPrivateSecret() async throws {
        let io = WebhookMemory(),v = WebhookEnrollmentVault(io:io),service = WebhookMock()
        service.reply = { _,_ in throw WebhookValue.invalid }
        let model = WebhookAccessModel(account:wa,origin:wo,service:service,vault:v,isCurrent:{true})
        await model.create(name:"Design pipeline",endpoint:"https://receiver.example/events",scope:"inbox",project:nil,events:[.created],days:30)
        let original = service.calls[0].1;XCTAssertNotNil(model.pending);XCTAssertNil(model.secret);model.close()
        let next = WebhookAccessModel(account:wa,origin:wo,service:service,vault:WebhookEnrollmentVault(io:io),isCurrent:{true})
        service.reply = { action,b in if action == "list" { return ["account":.string(wa),"subscriptions":.array([]),"next_cursor":.null] };var row = connection();row["id"] = b["id"];return ["account":.string(wa),"subscription":.object(row)] }
        await next.load();await next.resumeSetup();XCTAssertEqual(service.calls.last?.1,original);XCTAssertNotNil(next.secret)
        await next.acknowledgeSaved();XCTAssertNil(next.secret);XCTAssertTrue(io.data.isEmpty)
    }
    @MainActor func testDiscardBeforeCreateResponseAndStorageFailureKeepsRecovery() async throws {
        let io = WebhookMemory(),v = WebhookEnrollmentVault(io:io),s = WebhookMock(),d = try draft();_ = try await v.begin(d,lease:CalendarReadLease())
        let m = WebhookAccessModel(account:wa,origin:wo,service:s,vault:v,isCurrent:{true});await m.load()
        s.reply = { action,b in XCTAssertEqual(action,"cancel");return ["account":.string(wa),"id":b["id"]!,"cancelled":.bool(true)] }
        io.failing = true;await m.discard();XCTAssertEqual(s.calls.count,1);XCTAssertNotNil(m.pending)
        io.failing = false;await m.discard();XCTAssertNil(m.pending);XCTAssertTrue(io.data.isEmpty)
    }
    @MainActor func testControlsKeepSameIntentOnLostReplyAndRequireBoundConfirmation() async throws {
        let s = WebhookMock(),m = WebhookAccessModel(account:wa,origin:wo,service:s,vault:WebhookEnrollmentVault(io:WebhookMemory()),isCurrent:{true}),c = try WebhookConnection(connection(state:"active"))
        s.reply = { _,_ in throw WebhookValue.invalid };await m.control("pause",connection:c);let body = s.calls[0].1
        XCTAssertEqual(body["revision"],.string(c.revision));XCTAssertNotNil(m.uncertainAction)
        s.reply = { _,b in ["account":.string(wa),"subscription":.object(connection(state:"paused")),"command":.object(["request_id":b["request_id"]!,"applied":.bool(true)])] }
        await m.retryControl();XCTAssertEqual(s.calls.last?.1,body);XCTAssertNil(m.uncertainAction);XCTAssertEqual(m.connections.first?.state,"paused")
    }
    @MainActor func testForeignAndLateRepliesNeverExposeContent() async throws {
        let s = WebhookMock();var current = true
        let m = WebhookAccessModel(account:wa,origin:wo,service:s,vault:WebhookEnrollmentVault(io:WebhookMemory()),isCurrent:{current})
        s.reply = { _,_ in ["account":.string(wid(99)),"subscriptions":.array([.object(connection())]),"next_cursor":.null] };await m.load();XCTAssertTrue(m.connections.isEmpty)
        s.reply = { _,_ in current = false;return ["account":.string(wa),"subscriptions":.array([.object(connection())]),"next_cursor":.null] };await m.load();XCTAssertTrue(m.connections.isEmpty);XCTAssertNil(m.secret)
    }
    @MainActor func testHistoryPaginationIdentityAndRetryReceipt() async throws {
        let s = WebhookMock(),m = WebhookAccessModel(account:wa,origin:wo,service:s,vault:WebhookEnrollmentVault(io:WebhookMemory()),isCurrent:{true}),c = try WebhookConnection(connection(state:"active"))
        s.reply = { _,_ in ["account":.string(wa),"subscription":.object(connection(state:"active")),"events":.array([.object(eventRow())]),"next_cursor":.null] }
        await m.loadHistory(c);XCTAssertEqual(m.history.count,1);XCTAssertEqual(m.historyID,c.id)
        s.reply = { _,b in ["account":.string(wa),"subscription":.object(connection(state:"active")),"event":.object(eventRow()),"retry":.object(["event_id":b["event_id"]!,"request_id":b["request_id"]!,"applied":.bool(true)])] }
        await m.control("retry_delivery",connection:c,event:m.history[0]);XCTAssertNil(m.uncertainAction);XCTAssertEqual(s.calls.last?.1["event_id"],.string(wid(31)))
    }
}

private final class WebhookHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest,WebhookHTTP)->Void)?
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func stopLoading() {}
    override func startLoading() { Self.handler?(request,self) }
    func finish(_ data:Data) { client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self) }
}
extension WebhookAccessTests {
    @MainActor private func backend() throws -> Backend {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [WebhookHTTP.self]
        let session = try JSONDecoder().decode(Session.self,from:Data(("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\""+wa+"\"}}").utf8))
        return Backend(configuration:["URL":wo,"Key":"synthetic-public"],http:URLSession(configuration:config),session:session,persistSession:{_ in})
    }
    @MainActor func testHTTPUsesFixedBoundedPrivateRouteAndSameCreateIntent() async throws {
        let b = try backend(), d = try draft();var bodies:[Data] = []
        WebhookHTTP.handler = { req,http in
            XCTAssertEqual(req.url?.absoluteString,wo+"/functions/v1/automation-webhooks");XCTAssertEqual(req.httpMethod,"POST")
            XCTAssertEqual(req.value(forHTTPHeaderField:"Authorization"),"Bearer synthetic-auth");XCTAssertEqual(req.value(forHTTPHeaderField:"X-Taskfold-Automation"),"1")
            XCTAssertEqual(req.value(forHTTPHeaderField:"Cache-Control"),"no-store");XCTAssertFalse(req.httpShouldHandleCookies);XCTAssertEqual(req.timeoutInterval,25)
            var data = req.httpBody ?? Data()
            if let stream = req.httpBodyStream { stream.open();defer{stream.close()};var bytes = [UInt8](repeating:0,count:4096);while stream.hasBytesAvailable { let n = stream.read(&bytes,maxLength:bytes.count);if n<=0 {break};data.append(bytes,count:n) } }
            bodies.append(data)
            http.finish(try! JSONEncoder().encode(["account":JSON.string(wa)]))
        }
        _ = try await b.webhookReceipt(action:"create",body:d.body,account:wa,origin:wo)
        _ = try await b.webhookReceipt(action:"create",body:d.body,account:wa,origin:wo)
        XCTAssertEqual(bodies.count,2)
        let first = try JSONDecoder().decode([String:JSON].self,from:bodies[0]),second = try JSONDecoder().decode([String:JSON].self,from:bodies[1]);XCTAssertEqual(first,second)
        XCTAssertEqual(first["body"],.object(d.body));WebhookHTTP.handler = nil
    }
    @MainActor func testHTTPRejectsForeignOriginAccountReplyAndOversizedResponse() async throws {
        let b = try backend();var calls = 0
        WebhookHTTP.handler = { _,http in calls += 1;http.finish(try! JSONEncoder().encode(["account":JSON.string(wid(99))])) }
        do { _ = try await b.webhookReceipt(action:"list",body:[:],account:wa,origin:"https://other.example");XCTFail() } catch { }
        do { _ = try await b.webhookReceipt(action:"list",body:[:],account:wid(99),origin:wo);XCTFail() } catch { }
        XCTAssertEqual(calls,0)
        do { _ = try await b.webhookReceipt(action:"list",body:[:],account:wa,origin:wo);XCTFail() } catch { }
        XCTAssertEqual(calls,1)
        WebhookHTTP.handler = { _,http in http.finish(Data(repeating:65,count:256001)) }
        do { _ = try await b.webhookReceipt(action:"list",body:[:],account:wa,origin:wo);XCTFail() } catch { }
        WebhookHTTP.handler = nil
    }
}
