import Foundation
import XCTest
@testable import TaskfoldCore

private final class CalendarScript:@unchecked Sendable {
    struct Reply {var status=200;var body:JSON}
    private let lock=NSLock()
    private var replies:[Reply]
    private var requests:[URLRequest]=[]
    var onRequest:(@Sendable ()->Void)?
    init(_ replies:[Reply]) {self.replies=replies}
    func request(_ request:URLRequest)->Reply {lock.lock();defer{lock.unlock()};requests.append(request);return replies.isEmpty ? Reply(status:500,body:.object([:])):replies.removeFirst()}
    var captured:[URLRequest] {lock.lock();defer{lock.unlock()};return requests}
}
private final class CalendarProtocol:URLProtocol,@unchecked Sendable {
    static let lock=NSLock()
    nonisolated(unsafe) static var scripts:[String:CalendarScript]=[:]
    static func register(_ value:CalendarScript,id:String) {lock.lock();defer{lock.unlock()};scripts[id]=value}
    static func remove(_ id:String) {lock.lock();defer{lock.unlock()};scripts.removeValue(forKey:id)}
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        Self.lock.lock();let script=request.value(forHTTPHeaderField:"X-Calendar-Fixture").flatMap{Self.scripts[$0]};Self.lock.unlock()
        guard let script else {client?.urlProtocol(self,didFailWithError:URLError(.badURL));return}
        let reply=script.request(request);script.onRequest?();let data=try! JSONEncoder().encode(reply.body)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:reply.status,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class CloudCalendarTests:XCTestCase {
    private let token="synthetic-calendar-access"
    private func fixture(_ replies:[CalendarScript.Reply],pages:Int=40,items:Int=5000)->(CalendarReadAPI,CalendarScript,()->Void) {
        let id=UUID().uuidString,script=CalendarScript(replies);CalendarProtocol.register(script,id:id)
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[CalendarProtocol.self];config.httpAdditionalHeaders=["X-Calendar-Fixture":id]
        let session=URLSession(configuration:config)
        return (CalendarReadAPI(session:session,maximumPages:pages,maximumItems:items),script,{session.invalidateAndCancel();CalendarProtocol.remove(id)})
    }
    private func google(_ rows:[[String:JSON]],next:String?=nil)->JSON {
        var result:[String:JSON]=["items":.array(rows.map(JSON.object))];if let next {result["nextPageToken"] = .string(next)};return .object(result)
    }
    private func graph(_ rows:[[String:JSON]],next:String?=nil)->JSON {
        var result:[String:JSON]=["value":.array(rows.map(JSON.object))];if let next {result["@odata.nextLink"] = .string(next)};return .object(result)
    }
    private var calendar:LinkedCalendar {LinkedCalendar(service:.google,remoteID:"work/a+@example.invalid",title:"Workshop",timeZone:"Europe/Copenhagen",primary:true,ownerLabel:nil)}
    private var window:DateInterval {DateInterval(start:TaskPlanning.instant("2026-10-24T00:00:00Z")!,end:TaskPlanning.instant("2026-10-27T00:00:00Z")!)}
    private func event(_ id:String,start:String="2026-10-25T09:00:00+01:00",end:String="2026-10-25T10:00:00+01:00")->[String:JSON] { ["id":.string(id),"start":.object(["dateTime":.string(start)]),"end":.object(["dateTime":.string(end)]),"summary":.string("Review the workshop")] }
    func testGoogleCatalogPagesAndExplicitAccountIdentity() async throws {
        let first:[String:JSON]=["id":.string("owner@example.invalid"),"summary":.string("Personal"),"primary":.bool(true),"timeZone":.string("Europe/Copenhagen")]
        let second:[String:JSON]=["id":.string("team@example.invalid"),"summary":.string("Team")]
        let (api,script,close)=fixture([.init(body:google([first],next:"page +/&")),.init(body:google([second]))]);defer{close()}
        let result=try await api.calendars(.google,accessToken:token)
        XCTAssertEqual(result.identity,"owner@example.invalid");XCTAssertEqual(result.accountLabel,"owner@example.invalid");XCTAssertEqual(result.calendars.count,2)
        XCTAssertNotEqual(result.calendars[0].id,result.calendars[1].id)
        let requests=script.captured;XCTAssertEqual(requests.count,2)
        XCTAssertEqual(URLComponents(url:requests[1].url!,resolvingAgainstBaseURL:false)?.queryItems?.first{$0.name=="pageToken"}?.value,"page +/&")
        for request in requests {XCTAssertEqual(request.httpMethod,"GET");XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer "+token);XCTAssertNil(request.httpBody)}
    }
    func testOutlookCatalogUsesReadOnlyBasicScopeAndOwnerLabel() async throws {
        let row:[String:JSON]=["id":.string("mailbox-default"),"name":.string("Calendar"),"isDefaultCalendar":.bool(true),"owner":.object(["address":.string("owner@example.invalid")])]
        let (api,_,close)=fixture([.init(body:graph([row]))]);defer{close()}
        let catalog=try await api.calendars(.outlook,accessToken:token)
        XCTAssertEqual(catalog.identity,"mailbox-default");XCTAssertEqual(catalog.accountLabel,"owner@example.invalid")
        XCTAssertEqual(CalendarService.outlook.scopes,["https://graph.microsoft.com/Calendars.ReadBasic","offline_access"])
        XCTAssertEqual(CalendarService.google.scopes,["https://www.googleapis.com/auth/calendar.readonly"])
    }
    func testGooglePrivateFreeDeclinedCanceledAndDuplicateOccurrences() async throws {
        var publicEvent=event("public"),privateEvent=event("private");privateEvent["visibility"] = .string("private")
        var free=event("free");free["transparency"] = .string("transparent")
        var declined=event("declined");declined["attendees"] = .array([.object(["self":.bool(true),"responseStatus":.string("declined")])])
        publicEvent["visibility"] = .string("default")
        let (api,script,close)=fixture([.init(body:google([publicEvent,privateEvent,free,declined,["id":.string("gone"),"status":.string("cancelled")],publicEvent]))]);defer{close()}
        let result=try await api.events(calendar,window:window,titles:true,accessToken:token)
        XCTAssertEqual(result.count,2);XCTAssertEqual(Set(result.map(\.title)),["Busy","Review the workshop"])
        let parts=URLComponents(url:script.captured[0].url!,resolvingAgainstBaseURL:false)!
        XCTAssertTrue(parts.percentEncodedPath.contains("work%2Fa%2B%40example.invalid"));XCTAssertEqual(parts.queryItems?.first{$0.name=="singleEvents"}?.value,"true")
    }
    func testHiddenTitlesAreNotRequestedAndAllDayKeepsSourceZoneAcrossDST() async throws {
        let allDay:[String:JSON]=["id":.string("offsite"),"summary":.string("Do not reveal"),"start":.object(["date":.string("2026-10-25")]),"end":.object(["date":.string("2026-10-26")])]
        let (api,script,close)=fixture([.init(body:google([allDay]))]);defer{close()}
        let result=try await api.events(calendar,window:window,titles:false,accessToken:token),event=try XCTUnwrap(result.first)
        XCTAssertEqual(event.title,"Busy");XCTAssertTrue(event.allDay);XCTAssertEqual(event.start,TaskPlanning.instant("2026-10-24T22:00:00Z"));XCTAssertEqual(event.end.timeIntervalSince(event.start),25*3600)
        let fields=URLComponents(url:script.captured[0].url!,resolvingAgainstBaseURL:false)?.queryItems?.first{$0.name=="fields"}?.value ?? ""
        XCTAssertFalse(fields.contains("summary"));XCTAssertFalse(fields.contains("description"));XCTAssertFalse(fields.contains("location"))
    }
    func testOutlookExpandedInstancesUTCAndPrivacy() async throws {
        let c=LinkedCalendar(service:.outlook,remoteID:"opaque=",title:"Team",timeZone:nil,primary:true,ownerLabel:nil)
        func row(_ id:String,_ privacy:String)->[String:JSON] { ["id":.string(id),"start":.object(["dateTime":.string("2026-10-25T08:00:00.0000000"),"timeZone":.string("UTC")]),"end":.object(["dateTime":.string("2026-10-25T09:00:00.0000000"),"timeZone":.string("UTC")]),"subject":.string("Workshop review"),"sensitivity":.string(privacy)] }
        let (api,script,close)=fixture([.init(body:graph([row("occurrence","normal")],next:"https://graph.microsoft.com/v1.0/me/calendars/opaque=/calendarView?$skiptoken=next")),.init(body:graph([row("private","private")]))]);defer{close()}
        let events=try await api.events(c,window:window,titles:true,accessToken:token)
        XCTAssertEqual(events.count,2);XCTAssertEqual(Set(events.map(\.title)),["Busy","Workshop review"])
        XCTAssertEqual(events[0].start,TaskPlanning.instant("2026-10-25T08:00:00Z"));XCTAssertEqual(script.captured[0].value(forHTTPHeaderField:"Prefer"),"outlook.timezone=\"UTC\"")
    }
    func testMalformedPrivacyTimesOrUnknownAllDayZoneNeverReturnPartialBusyTime() async throws {
        var wrongPrivacy=event("bad");wrongPrivacy["visibility"] = .number(2)
        var wrongTime=event("bad");wrongTime["end"] = .object(["dateTime":.string("unknown")])
        let day:[String:JSON]=["id":.string("day"),"start":.object(["date":.string("2026-02-30")]),"end":.object(["date":.string("2026-03-01")])]
        for row in [wrongPrivacy,wrongTime,day] {
            let (api,_,close)=fixture([.init(body:google([event("good"),row]))]);defer{close()}
            do {_ = try await api.events(calendar,window:window,titles:true,accessToken:token);XCTFail("Malformed source returned partial busy time")}catch{XCTAssertEqual(error as? CalendarReadFailure,.invalidResponse)}
        }
        let noZone=LinkedCalendar(service:.google,remoteID:"unknown-zone",title:"Team",timeZone:nil,primary:false,ownerLabel:nil)
        let row:[String:JSON]=["id":.string("day"),"start":.object(["date":.string("2026-10-25")]),"end":.object(["date":.string("2026-10-26")])]
        let (api,_,close)=fixture([.init(body:google([row]))]);defer{close()}
        do {_ = try await api.events(noZone,window:window,titles:false,accessToken:token);XCTFail("Guessed calendar zone")}catch{XCTAssertEqual(error as? CalendarReadFailure,.invalidResponse)}
    }
    func testUntrustedContinuationDoesNotReceiveToken() async throws {
        let bad=["https://graph.microsoft.com.evil.invalid/v1.0/me/calendars?next=1","https://user@graph.microsoft.com/v1.0/me/calendars?next=1","http://graph.microsoft.com/v1.0/me/calendars?next=1","https://graph.microsoft.com/v1.0/me/messages?next=1","https://graph.microsoft.com:8443/v1.0/me/calendars?next=1","https://graph.microsoft.com/v1.0/me/calendars#fragment"]
        for url in bad {
            let (api,script,close)=fixture([.init(body:graph([],next:url))]);defer{close()}
            do {_ = try await api.calendars(.outlook,accessToken:token);XCTFail("Untrusted continuation followed")}catch{XCTAssertEqual(error as? CalendarReadFailure,.invalidResponse)}
            XCTAssertEqual(script.captured.count,1)
        }
    }
    func testPaginationLimitsAndConflictingDuplicatesRefuseIncompleteCatalog() async throws {
        let row:[String:JSON]=["id":.string("primary"),"primary":.bool(true),"summary":.string("One")]
        var different=row;different["summary"] = .string("Two")
        for (replies,pages,items,expected) in [([CalendarScript.Reply(body:google([row],next:"more"))],1,5000,CalendarReadFailure.tooManyResults),([.init(body:google([row,different]))],40,5000,.invalidResponse),([.init(body:google([row,row]))],40,1,.tooManyResults),([.init(body:google([row],next:"loop")),.init(body:google([],next:"loop"))],40,5000,.invalidResponse)] {
            let (api,_,close)=fixture(replies,pages:pages,items:items);defer{close()}
            do {_ = try await api.calendars(.google,accessToken:token);XCTFail("Incomplete catalog accepted")}catch{XCTAssertEqual(error as? CalendarReadFailure,expected)}
        }
    }
    func testErrorMessagesDoNotEchoResponseOrAccessToken() async throws {
        for (status,expected) in [(401,CalendarReadFailure.signIn),(403,.permission),(429,.throttled),(302,.unavailable),(503,.unavailable)] {
            let (api,script,close)=fixture([.init(status:status,body:.object(["error":.string(token+" Private event details")]))]);defer{close()}
            do {_ = try await api.calendars(.google,accessToken:token);XCTFail("HTTP failure accepted")}catch{XCTAssertEqual(error as? CalendarReadFailure,expected);XCTAssertFalse(error.localizedDescription.contains(token));XCTAssertFalse(error.localizedDescription.contains("Private event"))}
            XCTAssertEqual(script.captured.count,1)
        }
    }
    func testEmptySelectionContractAndServiceNamespace() async throws {
        let (api,_,close)=fixture([.init(body:google([]))]);defer{close()}
        let empty=try await api.events(calendar,window:window,titles:false,accessToken:token);XCTAssertTrue(empty.isEmpty)
        let other=LinkedCalendar(service:.outlook,remoteID:calendar.remoteID,title:calendar.title,timeZone:calendar.timeZone,primary:true,ownerLabel:nil)
        XCTAssertNotEqual(calendar.id,other.id)
        let invalid=DateInterval(start:window.start,duration:40*86400)
        do {_ = try await api.events(calendar,window:invalid,titles:false,accessToken:token);XCTFail("Unbounded event read accepted")}catch{XCTAssertEqual(error as? CalendarReadFailure,.invalidResponse)}
    }
}

@MainActor private final class CalendarAuthorizationFixture:CalendarAuthorizing {
    var configured=Set(CalendarService.allCases)
    var owner=""
    var saved:[String:[CalendarService:CalendarAccountIdentity]]=[:]
    var restoreFailure:CalendarService?
    var deleteFailure=false
    var tokens:[Bool]=[]
    var accepted:[CalendarAccountIdentity]=[]
    var discarded=Set<UUID>()
    var tokenGate:CheckedContinuation<String,Error>?
    var gateNextToken=false
    var tokenStarted:(()->Void)?
    func bind(owner:String) {self.owner=owner}
    func restore(owner:String,service:CalendarService) async throws ->CalendarAccountIdentity? {
        if restoreFailure==service {throw CalendarReadFailure.unavailable};return saved[owner]?[service]
    }
    func begin(owner:String,service:CalendarService) async throws ->UUID {UUID()}
    func token(owner:String,service:CalendarService,pending:UUID?,forceRefresh:Bool) async throws ->String {
        tokens.append(forceRefresh)
        if gateNextToken {gateNextToken=false;return try await withCheckedThrowingContinuation {tokenGate=$0;tokenStarted?()}}
        return "synthetic-calendar-access"
    }
    func accept(owner:String,service:CalendarService,pending:UUID,identity:CalendarAccountIdentity) async throws {
        guard self.owner==owner,!discarded.contains(pending) else {throw CancellationError()}
        accepted.append(identity);saved[owner,default:[:]][service]=identity
    }
    func discard(_ pending:UUID) {discarded.insert(pending)}
    func cancel(service:CalendarService?) {}
    func disconnect(owner:String,service:CalendarService) async throws {
        if deleteFailure {throw CalendarReadFailure.unavailable};saved[owner]?[service]=nil
    }
}
extension CloudCalendarTests {
    private func catalog(_ id:String="primary")->JSON {
        google([["id":.string(id),"primary":.bool(true),"summary":.string("Workshop"),"timeZone":.string("Europe/Copenhagen")]])
    }
    @MainActor private func linked(_ api:CalendarReadAPI,auth:CalendarAuthorizationFixture,selected:Bool=false) async ->(CalendarLinksStore,UserDefaults,()->Void) {
        let name="taskfold-calendar-test-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        auth.saved["workspace-a"]=[.google:CalendarAccountIdentity(id:"primary",label:"Synthetic account")]
        if selected {defaults.set("primary",forKey:"planner.linked.workspace-a.google.identity");defaults.set(["primary"],forKey:"planner.linked.workspace-a.google.selected")}
        let store=CalendarLinksStore(authorizer:auth,api:api,defaults:defaults);store.bind(owner:"workspace-a")
        // A read awaits restoration; no calendar is fetched when the fixture restores no connection.
        while store.restoring {await Task.yield()}
        return (store,defaults,{defaults.removePersistentDomain(forName:name)})
    }
    func testCancelledLeaseDiscardsResponseAndStopsPagination() async throws {
        let (api,script,close)=fixture([.init(body:google([["id":.string("primary"),"primary":.bool(true)]],next:"next")),.init(body:catalog())]);defer{close()}
        let lease=CalendarReadLease();script.onRequest={lease.cancel()}
        do {_ = try await api.calendars(.google,accessToken:token,lease:lease);XCTFail("Cancelled response accepted")}catch{XCTAssertTrue(error is CancellationError)}
        XCTAssertEqual(script.captured.count,1)
    }
    @MainActor func testConnectionRequiresExplicitSelectionAndKeepsTokensOutOfDefaults() async throws {
        let (api,script,close)=fixture([.init(body:catalog()),.init(body:catalog()),.init(body:catalog()),.init(body:google([event("review")]))]);defer{close()}
        let auth=CalendarAuthorizationFixture(),name="taskfold-calendar-test-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        let store=CalendarLinksStore(authorizer:auth,api:api,defaults:defaults);store.bind(owner:"workspace-a");await store.connect(.google)
        XCTAssertEqual(auth.accepted.count,1);XCTAssertTrue(store.links[.google]?.selected.isEmpty==true)
        let unselected=await store.read(window:window,titles:false);XCTAssertEqual(unselected?.state,"choose");XCTAssertEqual(script.captured.count,2)
        store.select(.google,id:"unknown",enabled:true);XCTAssertTrue(store.links[.google]?.selected.isEmpty==true)
        store.select(.google,id:"primary",enabled:true)
        let chosen=await store.read(window:window,titles:false);XCTAssertEqual(chosen?.state,"ready");XCTAssertEqual(chosen?.events.count,1)
        XCTAssertFalse(String(describing:defaults.dictionaryRepresentation()).contains(token))
        XCTAssertEqual(defaults.stringArray(forKey:"planner.linked.workspace-a.google.selected"),["primary"])
    }
    @MainActor func testDifferentAccountNeedsConfirmationAndCancelPreservesEarlierSelection() async throws {
        let (api,_,close)=fixture([.init(body:catalog("other")),.init(body:catalog("other"))]);defer{close()}
        let auth=CalendarAuthorizationFixture();let (store,_,cleanup)=await linked(api,auth:auth,selected:true);defer{cleanup()}
        await store.connect(.google)
        XCTAssertNotNil(store.replacement);XCTAssertTrue(auth.accepted.isEmpty);XCTAssertEqual(store.links[.google]?.identity.id,"primary")
        let cancelled=try XCTUnwrap(store.replacement?.id);store.cancelReplacement()
        XCTAssertTrue(auth.discarded.contains(cancelled));XCTAssertEqual(store.links[.google]?.selected,["primary"])
        await store.connect(.google);await store.confirmReplacement()
        XCTAssertNil(store.replacement);XCTAssertEqual(store.links[.google]?.identity.id,"other");XCTAssertTrue(store.links[.google]?.selected.isEmpty==true)
    }
    @MainActor func testSameAccountReconnectPreservesSelection() async throws {
        let (api,_,close)=fixture([.init(body:catalog())]);defer{close()}
        let auth=CalendarAuthorizationFixture();let (store,_,cleanup)=await linked(api,auth:auth,selected:true);defer{cleanup()}
        await store.connect(.google);XCTAssertNil(store.replacement);XCTAssertEqual(store.links[.google]?.selected,["primary"])
    }
    @MainActor func testWorkspaceSwitchDuringTokenDoesNotFetchOrExposeOldConnection() async throws {
        let (api,script,close)=fixture([]);defer{close()}
        let auth=CalendarAuthorizationFixture();let (store,_,cleanup)=await linked(api,auth:auth,selected:true);defer{cleanup()}
        let started=expectation(description:"Token requested");auth.gateNextToken=true;auth.tokenStarted={started.fulfill()}
        let reading=Task {await store.read(window:window,titles:true)}
        await fulfillment(of:[started],timeout:2)
        store.bind(owner:"workspace-b");auth.tokenGate?.resume(returning:token);auth.tokenGate=nil
        let result=await reading.value;XCTAssertNil(result);XCTAssertTrue(store.links.isEmpty);XCTAssertTrue(script.captured.isEmpty)
    }
    @MainActor func testDisconnectDuringConnectionDoesNotAcceptLateToken() async throws {
        let (api,script,close)=fixture([]);defer{close()}
        let auth=CalendarAuthorizationFixture();let (store,_,cleanup)=await linked(api,auth:auth,selected:true);defer{cleanup()}
        let started=expectation(description:"Connect token requested");auth.gateNextToken=true;auth.tokenStarted={started.fulfill()}
        let connecting=Task {await store.connect(.google)};await fulfillment(of:[started],timeout:2)
        await store.disconnect(.google);auth.tokenGate?.resume(returning:token);auth.tokenGate=nil;await connecting.value
        XCTAssertTrue(store.links.isEmpty);XCTAssertNil(store.connecting);XCTAssertTrue(auth.accepted.isEmpty);XCTAssertTrue(script.captured.isEmpty)
    }
    @MainActor func testCancelledConnectClearsProgress() async throws {
        let (api,_,close)=fixture([]);defer{close()}
        let auth=CalendarAuthorizationFixture();let (store,_,cleanup)=await linked(api,auth:auth);defer{cleanup()}
        let started=expectation(description:"Token requested");auth.gateNextToken=true;auth.tokenStarted={started.fulfill()}
        let connecting=Task {await store.connect(.google)};await fulfillment(of:[started],timeout:2)
        connecting.cancel();auth.tokenGate?.resume(returning:token);auth.tokenGate=nil;await connecting.value
        XCTAssertNil(store.connecting);XCTAssertNil(store.message);XCTAssertTrue(auth.accepted.isEmpty)
    }
    @MainActor func testRestoreFailureIsUnavailableRatherThanFreeTime() async throws {
        let (api,script,close)=fixture([]);defer{close()}
        let auth=CalendarAuthorizationFixture();auth.restoreFailure = .google
        let (store,_,cleanup)=await linked(api,auth:auth);defer{cleanup()}
        XCTAssertTrue(store.active);let result=await store.read(window:window,titles:false)
        XCTAssertEqual(result?.state,"unavailable");XCTAssertTrue(script.captured.isEmpty)
    }
    @MainActor func testUnauthorizedRefreshesExactlyOnceAndPermissionRevocationInvalidatesReads() async throws {
        let (api,script,close)=fixture([.init(status:401,body:.object([:])),.init(body:catalog()),.init(body:google([event("review")])),.init(status:403,body:.object([:]))]);defer{close()}
        let auth=CalendarAuthorizationFixture();let (store,_,cleanup)=await linked(api,auth:auth,selected:true);defer{cleanup()}
        let result=await store.read(window:window,titles:false);XCTAssertEqual(result?.state,"ready");XCTAssertEqual(auth.tokens,[false,true])
        let denied=await store.read(window:window,titles:false);XCTAssertNil(denied);XCTAssertTrue(store.links[.google]?.needsReconnect==true)
        let subsequent=await store.read(window:window,titles:false);XCTAssertEqual(subsequent?.state,"unavailable");XCTAssertEqual(script.captured.count,4)
    }
    @MainActor func testFailedDisconnectHidesCalendarsAndCanBeRetried() async throws {
        let (api,script,close)=fixture([]);defer{close()}
        let auth=CalendarAuthorizationFixture();let (store,defaults,cleanup)=await linked(api,auth:auth,selected:true);defer{cleanup()}
        auth.deleteFailure=true;await store.disconnect(.google)
        XCTAssertTrue(store.links[.google]?.selected.isEmpty==true);XCTAssertTrue(store.links[.google]?.needsReconnect==true);XCTAssertNotNil(store.message)
        let hidden=await store.read(window:window,titles:false);XCTAssertEqual(hidden?.state,"unavailable");XCTAssertTrue(script.captured.isEmpty)
        auth.deleteFailure=false;await store.disconnect(.google);XCTAssertTrue(store.links.isEmpty);XCTAssertNil(defaults.object(forKey:"planner.linked.workspace-a.google.selected"))
    }
}

extension CloudCalendarTests {
    @MainActor func testSelectionChangeDuringTokenStopsRequests() async throws {
        let (api,script,close)=fixture([]);defer{close()}
        let auth=CalendarAuthorizationFixture();let (store,_,cleanup)=await linked(api,auth:auth,selected:true);defer{cleanup()}
        let started=expectation(description:"Token requested");auth.gateNextToken=true;auth.tokenStarted={started.fulfill()}
        let reading=Task {await store.read(window:window,titles:false)};await fulfillment(of:[started],timeout:2)
        store.select(.google,id:"primary",enabled:false);auth.tokenGate?.resume(returning:token);auth.tokenGate=nil
        let result=await reading.value;XCTAssertNil(result);XCTAssertTrue(script.captured.isEmpty)
    }
    @MainActor func testCancelNewConnectionDiscardsLateResult() async throws {
        let (api,script,close)=fixture([]);defer{close()}
        let auth=CalendarAuthorizationFixture(),store=CalendarLinksStore(authorizer:auth,api:api);store.bind(owner:"new-workspace")
        let started=expectation(description:"Token requested");auth.gateNextToken=true;auth.tokenStarted={started.fulfill()}
        let connecting=Task {await store.connect(.google)};await fulfillment(of:[started],timeout:2)
        store.cancelConnection();auth.tokenGate?.resume(returning:token);auth.tokenGate=nil;await connecting.value
        XCTAssertNil(store.connecting);XCTAssertTrue(store.links.isEmpty);XCTAssertTrue(auth.accepted.isEmpty);XCTAssertTrue(script.captured.isEmpty)
    }
    @MainActor func testUnrestorableConnectionCanBeRemoved() async throws {
        let (api,_,close)=fixture([]);defer{close()}
        let auth=CalendarAuthorizationFixture();auth.restoreFailure = .google
        let (store,_,cleanup)=await linked(api,auth:auth);defer{cleanup()}
        XCTAssertTrue(store.active);await store.disconnect(.google);XCTAssertFalse(store.active)
        let result=await store.read(window:window,titles:false);XCTAssertEqual(result?.state,"off")
    }
    @MainActor func testUnavailableSelectedCalendarDoesNotBecomeFreeCapacity() async throws {
        let (api,_,close)=fixture([.init(body:catalog())]);defer{close()}
        let auth=CalendarAuthorizationFixture();let (store,defaults,cleanup)=await linked(api,auth:auth);defer{cleanup()}
        defaults.set("primary",forKey:"planner.linked.workspace-a.google.identity");defaults.set(["removed"],forKey:"planner.linked.workspace-a.google.selected")
        store.bind(owner:"");store.bind(owner:"workspace-a")
        let result=await store.read(window:window,titles:false);XCTAssertEqual(result?.state,"unavailable");XCTAssertTrue(result?.events.isEmpty==true)
        XCTAssertEqual(store.links[.google]?.selected,["removed"]);store.removeUnavailable(.google);XCTAssertTrue(store.links[.google]?.selected.isEmpty==true)
    }
    func testUnknownPrivacyDoesNotRevealTitle() async throws {
        var row=event("future-privacy");row["visibility"] = .string("unknown-future-policy")
        let (api,_,close)=fixture([.init(body:google([row]))]);defer{close()}
        do {_ = try await api.events(calendar,window:window,titles:true,accessToken:token);XCTFail("Unknown privacy exposed an event")}catch{XCTAssertEqual(error as? CalendarReadFailure,.invalidResponse)}
    }
}
