import XCTest
@testable import TaskfoldCore

private final class HandoffHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var block: ((URLRequest,HandoffHTTP) -> Void)?
    private var requests: [URLRequest] = []
    func set(_ block: ((URLRequest,HandoffHTTP) -> Void)?) { lock.lock(); self.block = block; requests = []; lock.unlock() }
    func start(_ request: URLRequest,_ transport: HandoffHTTP) { lock.lock(); requests.append(request); let callback = block; lock.unlock(); callback?(request,transport) }
    var calls: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}
private final class HandoffHTTP: URLProtocol, @unchecked Sendable {
    static let state = HandoffHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.state.start(request,self) }
    override func stopLoading() {}
    func finish(_ status: Int,_ data: Data,headers: [String:String] = [:]) {
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:headers.merging(["Content-Type":"application/json"]){a,_ in a})!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    func redirect() {
        let destination = URL(string:"https://foreign-handoff.test/collect")!
        var next = request; next.url = destination
        client?.urlProtocol(self,wasRedirectedTo:next,redirectResponse:HTTPURLResponse(url:request.url!,statusCode:307,httpVersion:nil,headerFields:["Location":destination.absoluteString])!)
        client?.urlProtocolDidFinishLoading(self)
    }
}
final class LocationHandoffTests: XCTestCase {
    let owner = "f083cafe-8100-4000-8000-000000000001", other = "f083cafe-8100-4000-8000-000000000002"
    let device = "f083cafe-8700-4000-8000-000000000001", otherDevice = "f083cafe-8700-4000-8000-000000000002"
    func golden(_ name: String) throws -> Data { try Data(contentsOf:XCTUnwrap(Bundle.module.url(forResource:"location-handoff-"+name,withExtension:"json",subdirectory:"Fixtures"))) }
    func read(_ name: String,device: String? = nil) throws -> LocationHandoffResponse { try .read(golden(name),account:owner,device:device) }
    func pending() throws -> LocationHandoffRecord { try XCTUnwrap(read("pending").records.first) }
    func proposal() throws -> LocationHandoffProposal { try XCTUnwrap(pending().proposal) }
    func altered(_ edit: (inout [String:JSON]) -> Void) throws -> Data {
        var json = try JSONDecoder().decode(JSON.self,from:golden("pending")).object;edit(&json);return try JSONEncoder().encode(json)
    }
    func alteredRow(_ edit: (inout [String:JSON]) -> Void) throws -> Data {
        try altered { json in var rows=json["items"]!.list;var row=rows[0].object;edit(&row);rows[0] = .object(row);json["items"] = .array(rows) }
    }
    func testActualPostgreSQLGoldenPendingClaimedImportedAndRedactedResponses() throws {
        let pending=try pending();XCTAssertEqual(pending.state,.pending);XCTAssertNotNil(pending.proposal)
        let claimed=try XCTUnwrap(read("claimed",device:device).records.first);XCTAssertEqual(claimed.state,.claimed);XCTAssertNotNil(claimed.proposal)
        let redacted=try XCTUnwrap(read("other-device",device:otherDevice).records.first{$0.id==pending.id});XCTAssertEqual(redacted.state,.claimed);XCTAssertNil(redacted.proposal)
        let imported=try XCTUnwrap(read("imported",device:device).records.first);XCTAssertEqual(imported.state,.imported);XCTAssertNil(imported.proposal)
        for name in ["pending","claimed","imported","other-device"] { XCTAssertFalse(String(decoding:try golden(name),as:UTF8.self).contains("claim_nonce")) }
    }
    func testProposalIsAccountBoundAndCannotBecomeAnArmedTaskSetting() throws {
        let p=try proposal();XCTAssertEqual(Set(p.raw.keys),LocationHandoffProposal.requestKeys)
        XCTAssertNil(p.raw["account_id"]);XCTAssertNil(ReminderSpec(row:.object(p.raw)));XCTAssertNil(LocationReminderSettings(raw:p.raw))
        XCTAssertNotNil(try LocationHandoffCommand.put(p).body(account:owner)["_request"])
        XCTAssertThrowsError(try LocationHandoffCommand.put(p).body(account:other))
        XCTAssertThrowsError(try LocationHandoffCommand.list(device:nil).body(account:"local"))
    }
    func testProposalRejectsFutureFieldsMalformedIdentityAndGeometries() throws {
        let original=try proposal()
        let bad: [String:JSON] = ["version":.number(2),"extra":.bool(true),"latitude_e6":.number(90_000_001),"longitude_e6":.number(0.5),"radius_m":.number(99),"repeats":.string("false"),"transition":.string("enter"),"id":.string("BAD"),"authored_at_ms":.number(-1),"completion_version":.number(.infinity),"place_name":.string("  ")]
        for (key,value) in bad {var raw=original.raw;raw[key]=value;XCTAssertNil(LocationHandoffProposal(account:owner,raw:raw),key)}
        var raw=original.raw;raw["place_name"] = .string(String(repeating:"東",count:121));XCTAssertNil(LocationHandoffProposal(account:owner,raw:raw))
        raw["place_name"] = .string("line\nname");XCTAssertNil(LocationHandoffProposal(account:owner,raw:raw))
    }
    func testMakeRequiresSavedOpenRootAndCurrentAccountPlace() throws {
        var root=Record.task(user:owner);root["title"] = .string("Task target")
        let place=try XCTUnwrap(LocationPrivatePlace.make(account:owner,name:"Private synthetic pin",latitude:55.67,longitude:12.56,radius:250))
        let p=try XCTUnwrap(LocationHandoffProposal.make(account:owner,task:root,place:place,transition:.leave,repeats:true))
        XCTAssertTrue(p.matches(task:root,account:owner));root["completed"] = .bool(true)
        XCTAssertNil(LocationHandoffProposal.make(account:owner,task:root,place:place,transition:.arrive,repeats:false));root["completed"] = .bool(false)
        XCTAssertNil(LocationHandoffProposal.make(account:other,task:root,place:place,transition:.arrive,repeats:false))
        root.fields.removeValue(forKey:"task_generation");XCTAssertNil(LocationHandoffProposal.make(account:owner,task:root,place:place,transition:.arrive,repeats:false))
    }
    func testWholeResponseRefusesAnotherAccountFutureVersionDuplicateAndPartialRows() throws {
        XCTAssertThrowsError(try LocationHandoffResponse.read(golden("pending"),account:other,device:nil))
        for data in [try altered{$0["version"] = .number(2)},try altered{$0["extra"] = .bool(true)},try altered{$0["items"] = .array($0["items"]!.list+$0["items"]!.list)},try altered{$0["items"] = .array($0["items"]!.list+[.null])}] {
            XCTAssertThrowsError(try LocationHandoffResponse.read(data,account:owner,device:nil))
        }
    }
    func testRedactionRegressionsNeverExposeClaimedOrUnavailableGeometry() throws {
        XCTAssertThrowsError(try LocationHandoffResponse.read(golden("claimed"),account:owner,device:otherDevice))
        XCTAssertThrowsError(try LocationHandoffResponse.read(alteredRow{$0["available"] = .bool(false)},account:owner,device:nil))
        XCTAssertThrowsError(try LocationHandoffResponse.read(alteredRow{$0["claim_nonce"] = .string(self.device)},account:owner,device:nil))
        XCTAssertThrowsError(try LocationHandoffResponse.read(alteredRow{$0["claim_device"] = .string(self.device)},account:owner,device:nil))
    }
    func testServerTimeAndImmutableFixedExpiryAreValidated() throws {
        for data in [try altered{$0["server_now_ms"] = .number(-1)},try alteredRow{$0["expires_at_ms"] = .number(Double($0["created_at_ms"]!.integer+604_800_001))},try alteredRow{$0["created_at_ms"] = .number(0)},try alteredRow{$0["expires_at_ms"] = $0["created_at_ms"]}] {
            XCTAssertThrowsError(try LocationHandoffResponse.read(data,account:owner,device:nil))
        }
    }
    func testTicketContainsNoGeometryRequiresPendingReviewAndSurvivesCodec() throws {
        let pending=try pending(),ticket=try XCTUnwrap(LocationHandoffReviewTicket(record:pending,device:device))
        let data=try JSONEncoder().encode(ticket),text=String(decoding:data,as:UTF8.self)
        XCTAssertFalse(text.contains("latitude"));XCTAssertFalse(text.contains("workshop"));XCTAssertTrue(ticket.valid)
        XCTAssertEqual(try JSONDecoder().decode(LocationHandoffReviewTicket.self,from:data),ticket)
        XCTAssertNil(LocationHandoffReviewTicket(record:try XCTUnwrap(read("claimed",device:device).records.first),device:device),"A fresh nonce must never replace the saved nonce of an already claimed review")
        XCTAssertNil(LocationHandoffReviewTicket(record:pending,device:"not-a-device"))
    }
    func testTicketRefusesChangedPayloadHeaderExpiryAndAccount() throws {
        let pending=try pending(),ticket=try XCTUnwrap(LocationHandoffReviewTicket(record:pending,device:device))
        XCTAssertTrue(ticket.matches(pending))
        for data in [try alteredRow {row in var p=row["payload"]!.object;p["radius_m"] = .number(500);row["payload"] = .object(p)},try alteredRow{$0["completion_version"] = .number(1)},try alteredRow{$0["expires_at_ms"] = .number(Double($0["expires_at_ms"]!.integer-1000))}] {
            let response=try LocationHandoffResponse.read(data,account:owner,device:nil);XCTAssertFalse(ticket.matches(try XCTUnwrap(response.records.first)))
        }
        XCTAssertThrowsError(try LocationHandoffCommand.claim(ticket).body(account:other))
    }
    func testCommandRepliesCannotSubstituteAnotherTaskOrDraft() throws {
        let response=try read("pending"),p=try proposal(),ticket=try XCTUnwrap(LocationHandoffReviewTicket(record:pending(),device:device))
        XCTAssertTrue(LocationHandoffCommand.put(p).accepts(response));XCTAssertFalse(LocationHandoffCommand.discard(id:device).accepts(response))
        let changed=try LocationHandoffResponse.read(alteredRow{$0["task_generation"] = .string(self.device)},account:owner,device:nil)
        XCTAssertFalse(LocationHandoffCommand.put(p).accepts(changed));XCTAssertFalse(LocationHandoffCommand.claim(ticket).accepts(changed))
    }
    func testRequestAndResponseBoundsRefuseWithoutTruncatingAnInbox() throws {
        XCTAssertThrowsError(try LocationHandoffResponse.read(Data(repeating:32,count:LocationHandoffResponse.maximumBytes+1),account:owner,device:nil))
        let many=try altered {json in json["items"] = .array(Array(repeating:json["items"]!.list[0],count:257))}
        XCTAssertThrowsError(try LocationHandoffResponse.read(many,account:owner,device:nil))
    }
    func testPrivateGeometryNeverEntersOrdinaryTaskBackupOrNotificationFormat() throws {
        var root=Record.task(user:owner);root["title"] = .string("Separate task")
        let cache=Snapshot(tables:["tasks":[root]])
        let exported=String(decoding:try WorkspaceBackup.make(cache,account:owner).data(),as:UTF8.self)
        XCTAssertFalse(exported.contains("latitude_e6"));XCTAssertFalse(exported.contains("Synthetic private workshop"))
        XCTAssertTrue(DueReminder.events(tasks:[root]).isEmpty)
        XCTAssertThrowsError(try LocationPrivateArchive.decode(JSONEncoder().encode(proposal().raw)))
    }
    @MainActor private func backend() -> Backend {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[HandoffHTTP.self]
        let session=try! JSONDecoder().decode(Session.self,from:Data(("{\"access_token\":\"handoff-fixture-token\",\"refresh_token\":\"fixture-refresh\",\"expires_in\":3600,\"user\":{\"id\":\""+owner+"\",\"email\":\"handoff-fixture@example.invalid\"}}").utf8))
        return Backend(configuration:["URL":"https://private-handoff.test","Key":"public-fixture-key"],http:URLSession(configuration:config),session:session,persistSession:{_ in})
    }
    @MainActor func testAuthenticatedPrivateTransportUsesFixedRPCNoCookiesAndNoCache() async throws {
        let data=try golden("pending"),backend=backend()
        HandoffHTTP.state.set {request,http in
            XCTAssertEqual(request.url?.path,"/rest/v1/rpc/taskfold_location_handoff_list");XCTAssertEqual(request.httpMethod,"POST")
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer handoff-fixture-token")
            XCTAssertEqual(request.value(forHTTPHeaderField:"Cache-Control"),"no-store");XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.cachePolicy,.reloadIgnoringLocalCacheData);http.finish(200,data)
        };defer{HandoffHTTP.state.set(nil)}
        let response=try await LocationHandoffAPI(backend:backend).perform(.list(device:nil),account:owner,isCurrent:{true})
        XCTAssertEqual(response.records.count,1)
    }
    @MainActor func testStaleAccountAndWorkspaceAreRejectedBeforeOrAfterHeldResponse() async throws {
        let backend=backend(),data=try golden("pending"),started=expectation(description:"Private request held")
        var held:HandoffHTTP?,current=true
        HandoffHTTP.state.set {_,http in held=http;started.fulfill()};defer{HandoffHTTP.state.set(nil)}
        do{_ = try await LocationHandoffAPI(backend:backend).perform(.list(device:nil),account:other,isCurrent:{true});XCTFail("Wrong account uploaded data")}catch{XCTAssertTrue(error is CancellationError)}
        XCTAssertTrue(HandoffHTTP.state.calls.isEmpty)
        let task=Task{@MainActor in try await LocationHandoffAPI(backend:backend).perform(.list(device:nil),account:self.owner,isCurrent:{current})}
        await fulfillment(of:[started],timeout:3);current=false;held?.finish(200,data)
        do{_ = try await task.value;XCTFail("Stale workspace consumed a private response")}catch{XCTAssertTrue(error is CancellationError)}
    }
    @MainActor func testPrivateTransportRejectsDeclaredAndStreamedOversize() async throws {
        for declared in [true,false] {
            let backend=backend()
            HandoffHTTP.state.set {_,http in http.finish(200,declared ? Data("{}".utf8) : Data(repeating:32,count:LocationHandoffResponse.maximumBytes+1),headers:declared ? ["Content-Length":String(LocationHandoffResponse.maximumBytes+1)] : [:])}
            do{_ = try await LocationHandoffAPI(backend:backend).perform(.list(device:nil),account:owner,isCurrent:{true});XCTFail("Oversized private response accepted")}catch{XCTAssertTrue(error.localizedDescription.contains("too large"),error.localizedDescription)}
            HandoffHTTP.state.set(nil)
        }
    }
    @MainActor func testPrivateRPCDoesNotFollowAnHTTPRedirectWithGeometryOrCredentials() async throws {
        let backend=backend();HandoffHTTP.state.set {request,http in
            if request.url?.host=="private-handoff.test"{http.redirect()}else{http.finish(200,Data("{}".utf8))}
        };defer{HandoffHTTP.state.set(nil)}
        do{_ = try await LocationHandoffAPI(backend:backend).perform(.put(proposal()),account:owner,isCurrent:{true});XCTFail("Redirect accepted as a successful private draft")}catch{}
        XCTAssertEqual(HandoffHTTP.state.calls.count,1);XCTAssertEqual(HandoffHTTP.state.calls.first?.url?.host,"private-handoff.test")
    }
}
