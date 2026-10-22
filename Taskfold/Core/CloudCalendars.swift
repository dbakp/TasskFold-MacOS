import Foundation

/// Provider credentials stay outside these models, workspace backups and widget projections.
enum CalendarService:String,CaseIterable,Codable,Sendable,Identifiable {
    case google,outlook
    var id:String {rawValue}
    var title:String {self == .google ? "Google Calendar":"Outlook"}
    var scopes:[String] {self == .google ? ["https://www.googleapis.com/auth/calendar.readonly"]:["https://graph.microsoft.com/Calendars.ReadBasic","offline_access"]}
    var host:String {self == .google ? "www.googleapis.com":"graph.microsoft.com"}
}
struct LinkedCalendar:Identifiable,Equatable,Sendable {
    let service:CalendarService
    let remoteID:String
    let title:String
    let timeZone:String?
    let primary:Bool
    let ownerLabel:String?
    var id:String {service.rawValue+"."+Data(remoteID.utf8).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")}
}
struct CalendarCatalog:Equatable,Sendable {
    let service:CalendarService
    let calendars:[LinkedCalendar]
    /// An API-confirmed default calendar identifies this read-only calendar account.
    var identity:String? {calendars.first(where:{$0.primary})?.remoteID}
    var accountLabel:String? {
        guard let primary=calendars.first(where:{$0.primary}) else {return nil}
        if let owner=primary.ownerLabel,!owner.isEmpty {return owner}
        return service == .google ? primary.remoteID:primary.title
    }
}
enum CalendarReadFailure:Error,LocalizedError,Equatable {
    case signIn,permission,unavailable,throttled,invalidResponse,tooManyResults,changedAccount
    var errorDescription:String? {
        switch self {
        case .signIn:return "Reconnect this calendar account to refresh busy time."
        case .permission:return "Calendar access changed. Reconnect and allow read access."
        case .unavailable:return "Calendar busy time could not be refreshed. Try again."
        case .throttled:return "The calendar service is busy. Try again shortly."
        case .invalidResponse:return "Some calendar details could not be read. Busy time is incomplete."
        case .tooManyResults:return "This calendar has more results than Taskfold can safely load. Busy time is incomplete."
        case .changedAccount:return "The connected calendar account changed. Reconnect before using its busy time."
        }
    }
}
/// In-flight responses are discarded after a workspace, selection or connection change.
final class CalendarReadLease:@unchecked Sendable {
    private let lock=NSLock()
    private var cancelled=false
    func cancel() {lock.lock();cancelled=true;lock.unlock()}
    func check() throws {lock.lock();let stopped=cancelled;lock.unlock();if stopped || Task.isCancelled {throw CancellationError()}}
}
private final class CalendarRedirectGuard:NSObject,URLSessionTaskDelegate,@unchecked Sendable {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) {completionHandler(nil)}
}
/// All requests are read-only. Server-provided continuation URLs cannot redirect a bearer token.
actor CalendarReadAPI {
    private let session:URLSession
    private let maximumPages:Int
    private let maximumItems:Int
    init(session:URLSession?=nil,maximumPages:Int=40,maximumItems:Int=5000) {
        if let session {self.session=session}
        else {
            let configuration=URLSessionConfiguration.ephemeral
            configuration.urlCache=nil;configuration.httpCookieStorage=nil;configuration.urlCredentialStorage=nil
            configuration.httpShouldSetCookies=false;configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest=30;configuration.timeoutIntervalForResource=60
            self.session=URLSession(configuration:configuration,delegate:CalendarRedirectGuard(),delegateQueue:nil)
        }
        self.maximumPages=min(100,max(1,maximumPages));self.maximumItems=min(10000,max(1,maximumItems))
    }
    static func segment(_ value:String)->String {
        value.addingPercentEncoding(withAllowedCharacters:CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? ""
    }
    static func url(_ service:CalendarService,path:String,query:[URLQueryItem])->URL {
        var parts=URLComponents();parts.scheme="https";parts.host=service.host;parts.percentEncodedPath=path;parts.queryItems=query;return parts.url!
    }
    static func validContinuation(_ url:URL,original:URL,service:CalendarService)->Bool {
        guard let parts=URLComponents(url:url,resolvingAgainstBaseURL:false),let initial=URLComponents(url:original,resolvingAgainstBaseURL:false) else {return false}
        let path=parts.percentEncodedPath.split(separator:"/",omittingEmptySubsequences:false).map{String($0).removingPercentEncoding}
        let originalPath=initial.percentEncodedPath.split(separator:"/",omittingEmptySubsequences:false).map{String($0).removingPercentEncoding}
        guard !path.contains(nil),path==originalPath else {return false}
        return parts.scheme=="https" && parts.host?.lowercased()==service.host && (parts.port==nil || parts.port==443) && parts.user==nil && parts.password==nil && parts.fragment==nil && url.absoluteString.utf8.count<=32768
    }
    private func pages(_ service:CalendarService,url initial:URL,token:String,lease:CalendarReadLease?) async throws ->[[String:JSON]] {
        guard !token.isEmpty,token.utf8.count<=32768,!token.contains("\r"),!token.contains("\n") else {throw CalendarReadFailure.signIn}
        var url=initial,visited=Set<String>(),rows:[[String:JSON]]=[]
        for _ in 0..<maximumPages {
            try Task.checkCancellation();try lease?.check()
            guard Self.validContinuation(url,original:initial,service:service),visited.insert(url.absoluteString).inserted else {throw CalendarReadFailure.invalidResponse}
            var request=URLRequest(url:url);request.httpMethod="GET";request.timeoutInterval=30
            request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Accept")
            if service == .outlook {request.setValue("outlook.timezone=\"UTC\"",forHTTPHeaderField:"Prefer")}
            let data:Data,response:URLResponse
            do {(data,response)=try await session.data(for:request)} catch is CancellationError {throw CancellationError()} catch {if Task.isCancelled {throw CancellationError()};throw CalendarReadFailure.unavailable}
            try Task.checkCancellation();try lease?.check()
            guard let http=response as? HTTPURLResponse else {throw CalendarReadFailure.invalidResponse}
            switch http.statusCode {case 200:break;case 401:throw CalendarReadFailure.signIn;case 403:throw CalendarReadFailure.permission;case 429:throw CalendarReadFailure.throttled;default:throw CalendarReadFailure.unavailable}
            guard data.count<=6*1024*1024,case .object(let object)=try? JSONDecoder().decode(JSON.self,from:data),case .array(let items)=object[service == .google ? "items":"value"] else {throw CalendarReadFailure.invalidResponse}
            for item in items {guard case .object(let row)=item else {throw CalendarReadFailure.invalidResponse};rows.append(row);guard rows.count<=maximumItems else {throw CalendarReadFailure.tooManyResults}}
            let continuation=object[service == .google ? "nextPageToken":"@odata.nextLink"] ?? .null
            if continuation == .null {return rows}
            guard case .string(let next)=continuation,!next.isEmpty,next.utf8.count<=16384 else {throw CalendarReadFailure.invalidResponse}
            if service == .google {
                var parts=URLComponents(url:initial,resolvingAgainstBaseURL:false)!;var query=parts.queryItems ?? []
                query.removeAll{$0.name=="pageToken"};query.append(URLQueryItem(name:"pageToken",value:next));parts.queryItems=query
                guard let following=parts.url else {throw CalendarReadFailure.invalidResponse};url=following
            } else {guard let following=URL(string:next),Self.validContinuation(following,original:initial,service:service) else {throw CalendarReadFailure.invalidResponse};url=following}
        }
        throw CalendarReadFailure.tooManyResults
    }
    func calendars(_ service:CalendarService,accessToken:String,lease:CalendarReadLease?=nil) async throws ->CalendarCatalog {
        let path=service == .google ? "/calendar/v3/users/me/calendarList":"/v1.0/me/calendars"
        let query=service == .google ? [URLQueryItem(name:"maxResults",value:"250"),URLQueryItem(name:"showHidden",value:"true"),URLQueryItem(name:"fields",value:"items(id,summary,timeZone,primary,deleted,accessRole),nextPageToken")]:[URLQueryItem(name:"$top",value:"250"),URLQueryItem(name:"$select",value:"id,name,isDefaultCalendar,owner")]
        let rows=try await pages(service,url:Self.url(service,path:path,query:query),token:accessToken,lease:lease)
        var values:[String:LinkedCalendar]=[:]
        for row in rows {
            if row["deleted"] == .bool(true) {continue}
            guard let id=row["id"]?.text,!id.isEmpty,id.utf8.count<=4096,id != ".",id != "..",id.unicodeScalars.allSatisfy({!CharacterSet.controlCharacters.contains($0)}) else {throw CalendarReadFailure.invalidResponse}
            let name=row[service == .google ? "summary":"name"]?.text ?? ""
            let choice=LinkedCalendar(service:service,remoteID:id,title:name.isEmpty ? "Calendar":String(name.prefix(500)),timeZone:row["timeZone"]?.text,primary:row[service == .google ? "primary":"isDefaultCalendar"] == .bool(true),ownerLabel:service == .outlook ? row["owner"]?.object["address"]?.text:nil)
            if let previous=values[id],previous != choice {throw CalendarReadFailure.invalidResponse};values[id]=choice
        }
        let calendars=values.values.sorted{($0.title,$0.remoteID)<($1.title,$1.remoteID)}
        guard calendars.filter({$0.primary}).count==1 else {throw CalendarReadFailure.invalidResponse}
        return CalendarCatalog(service:service,calendars:calendars)
    }
    func events(_ calendar:LinkedCalendar,window:DateInterval,titles:Bool,accessToken:String,lease:CalendarReadLease?=nil) async throws ->[PlannerEvent] {
        guard window.start.timeIntervalSince1970.isFinite,window.end.timeIntervalSince1970.isFinite,window.duration>0,window.duration<=32*86400 else {throw CalendarReadFailure.invalidResponse}
        let formatter=ISO8601DateFormatter(),service=calendar.service
        let path=service == .google ? "/calendar/v3/calendars/"+Self.segment(calendar.remoteID)+"/events":"/v1.0/me/calendars/"+Self.segment(calendar.remoteID)+"/calendarView"
        let fields=service == .google ? "items(id,status,transparency,visibility,start,end,attendees(self,responseStatus)"+(titles ? ",summary":"")+"),nextPageToken":"id,start,end,isAllDay,isCancelled,showAs,sensitivity,responseStatus,type"+(titles ? ",subject":"")
        let query=service == .google ? [URLQueryItem(name:"singleEvents",value:"true"),URLQueryItem(name:"showDeleted",value:"false"),URLQueryItem(name:"timeZone",value:"UTC"),URLQueryItem(name:"maxAttendees",value:"1"),URLQueryItem(name:"orderBy",value:"startTime"),URLQueryItem(name:"timeMin",value:formatter.string(from:window.start)),URLQueryItem(name:"timeMax",value:formatter.string(from:window.end)),URLQueryItem(name:"maxResults",value:"250"),URLQueryItem(name:"fields",value:fields)]:[URLQueryItem(name:"startDateTime",value:formatter.string(from:window.start)),URLQueryItem(name:"endDateTime",value:formatter.string(from:window.end)),URLQueryItem(name:"$top",value:"250"),URLQueryItem(name:"$select",value:fields)]
        let rows=try await pages(service,url:Self.url(service,path:path,query:query),token:accessToken,lease:lease)
        let decoder=CalendarEventDecoder();var result:[String:PlannerEvent]=[:]
        for row in rows {
            guard let event=try decoder.event(row,calendar:calendar,titles:titles) else {continue}
            guard event.start<window.end,event.end>window.start else {continue}
            if let existing=result[event.id],existing != event {throw CalendarReadFailure.invalidResponse};result[event.id]=event
        }
        return result.values.sorted{$0.start==$1.start ? $0.id<$1.id:$0.start<$1.start}
    }
}
private final class CalendarEventDecoder {
    let whole=ISO8601DateFormatter(),fractional=ISO8601DateFormatter()
    init(){fractional.formatOptions=[.withInternetDateTime,.withFractionalSeconds]}
    func instant(_ text:String)->Date? {fractional.date(from:text) ?? whole.date(from:text)}
    func day(_ text:String,zone:String?) throws ->Date {
        guard text.range(of:#"^\d{4}-\d{2}-\d{2}$"#,options:.regularExpression) != nil,let zone,let timeZone=TimeZone(identifier:zone) else {throw CalendarReadFailure.invalidResponse}
        let parts=text.split(separator:"-").compactMap{Int($0)}
        guard parts.count==3,(1...9999).contains(parts[0]),(1...12).contains(parts[1]),(1...31).contains(parts[2]) else {throw CalendarReadFailure.invalidResponse}
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=timeZone
        guard let date=calendar.date(from:DateComponents(year:parts[0],month:parts[1],day:parts[2])),calendar.component(.year,from:date)==parts[0],calendar.component(.month,from:date)==parts[1],calendar.component(.day,from:date)==parts[2] else {throw CalendarReadFailure.invalidResponse}
        return date
    }
    func boundary(_ value:JSON?,calendar:LinkedCalendar) throws ->(Date,Bool) {
            guard case .object(let object)=value else {throw CalendarReadFailure.invalidResponse}
            if calendar.service == .google,let value=object["date"]?.text,!value.isEmpty {return (try day(value,zone:calendar.timeZone),true)}
            guard let text=object["dateTime"]?.text,!text.isEmpty else {throw CalendarReadFailure.invalidResponse}
            if let date=instant(text) {return (date,false)}
            if calendar.service == .outlook,["UTC","Etc/UTC"].contains(object["timeZone"]?.text ?? ""),let date=instant(text+"Z") {return (date,false)}
            throw CalendarReadFailure.invalidResponse
    }
    func event(_ row:[String:JSON],calendar:LinkedCalendar,titles:Bool) throws ->PlannerEvent? {
        let service=calendar.service
        if row["status"] == .string("cancelled") || row["transparency"] == .string("transparent") || row["isCancelled"] == .bool(true) || row["showAs"] == .string("free") || row["type"] == .string("seriesMaster") {return nil}
        if service == .google,row["attendees"]?.list.contains(where:{$0.object["self"] == .bool(true) && $0.object["responseStatus"] == .string("declined")}) == true {return nil}
        if service == .outlook,row["responseStatus"]?.object["response"] == .string("declined") {return nil}
        guard let id=row["id"]?.text,!id.isEmpty,id.utf8.count<=4096,id != ".",id != "..",id.unicodeScalars.allSatisfy({!CharacterSet.controlCharacters.contains($0)}) else {throw CalendarReadFailure.invalidResponse}
        let (start,dateOnly)=try boundary(row["start"],calendar:calendar),(end,endOnly)=try boundary(row["end"],calendar:calendar)
        guard end>start,dateOnly==endOnly else {throw CalendarReadFailure.invalidResponse}
        let privacy=row[service == .google ? "visibility":"sensitivity"] ?? .null
        if privacy != .null {guard case .string=privacy else {throw CalendarReadFailure.invalidResponse}}
        let knownPrivacy=service == .google ? ["default","public","private","confidential"]:["normal","personal","private","confidential"]
        if privacy != .null,!knownPrivacy.contains(privacy.text) {throw CalendarReadFailure.invalidResponse}
        let isPrivate=["private","confidential","personal"].contains(privacy.text)
        let subject=row[service == .google ? "summary":"subject"]?.text.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        return PlannerEvent(id:calendar.id+":"+CalendarReadAPI.segment(id)+":"+String(start.timeIntervalSince1970),calendarID:calendar.id,title:titles && !isPrivate && !subject.isEmpty ? String(subject.prefix(500)):"Busy",source:calendar.title+" · "+service.title,start:start,end:end,allDay:dateOnly || row["isAllDay"] == .bool(true))
    }
}

import Observation

struct CalendarAccountIdentity:Codable,Equatable,Sendable {var id:String;var label:String}
/// Native authentication owns opaque secure state. No token is a property of a UI model.
@MainActor protocol CalendarAuthorizing:AnyObject {
    var configured:Set<CalendarService> {get}
    func bind(owner:String)
    func restore(owner:String,service:CalendarService) async throws ->CalendarAccountIdentity?
    func begin(owner:String,service:CalendarService) async throws ->UUID
    func token(owner:String,service:CalendarService,pending:UUID?,forceRefresh:Bool) async throws ->String
    func accept(owner:String,service:CalendarService,pending:UUID,identity:CalendarAccountIdentity) async throws
    func discard(_ pending:UUID)
    func cancel(service:CalendarService?)
    func disconnect(owner:String,service:CalendarService) async throws
    func eraseAccount(_ owner:String) async throws
}
extension CalendarAuthorizing {
    func eraseAccount(_ owner:String) async throws { for service in CalendarService.allCases { try await disconnect(owner:owner,service:service) } }
}
@MainActor final class UnavailableCalendarAuthorization:CalendarAuthorizing {
    var configured:Set<CalendarService> {[]}
    func bind(owner:String) {}
    func restore(owner:String,service:CalendarService) async throws ->CalendarAccountIdentity? {nil}
    func begin(owner:String,service:CalendarService) async throws ->UUID {throw CalendarReadFailure.unavailable}
    func token(owner:String,service:CalendarService,pending:UUID?,forceRefresh:Bool) async throws ->String {throw CalendarReadFailure.signIn}
    func accept(owner:String,service:CalendarService,pending:UUID,identity:CalendarAccountIdentity) async throws {throw CalendarReadFailure.unavailable}
    func discard(_ pending:UUID) {}
    func cancel(service:CalendarService?) {}
    func disconnect(owner:String,service:CalendarService) async throws {}
    func eraseAccount(_ owner:String) async throws { for service in CalendarService.allCases { try await disconnect(owner:owner,service:service) } }
}
struct LinkedCalendarProfile:Identifiable,Equatable,Sendable {
    var service:CalendarService
    var identity:CalendarAccountIdentity
    var calendars:[LinkedCalendar]=[]
    var selected=Set<String>()
    var needsReconnect=false
    var notice:String?
    var id:String {service.rawValue}
}
struct PendingCalendarReplacement:Identifiable,Sendable {
    let id:UUID
    let owner:String
    let generation:UUID
    let previousID:String
    let catalog:CalendarCatalog
    let lease:CalendarReadLease
    var service:CalendarService {catalog.service}
}
struct LinkedCalendarWindow:Sendable {
    var state:String
    var events:[PlannerEvent]=[]
    var status:String
}
/// Credentials and selections are independently bound to a Taskfold workspace on this device.
@MainActor @Observable final class CalendarLinksStore {
    static let shared:CalendarLinksStore = {
        #if DEBUG
        let arguments=ProcessInfo.processInfo.arguments
        if arguments.contains("--uitesting") && arguments.contains("--calendar-links-fixture") {return CalendarLinksFixture.make()}
        if arguments.contains("--uitesting") || arguments.contains("--preview") {
            return CalendarLinksStore(authorizer:UnavailableCalendarAuthorization(),defaults:UserDefaults(suiteName:"taskfold-calendar-empty-test-"+UUID().uuidString)!)
        }
        #endif
        return CalendarLinksStore(authorizer:UnavailableCalendarAuthorization())
    }()
    @ObservationIgnored private var authorizer:any CalendarAuthorizing
    @ObservationIgnored private let api:CalendarReadAPI
    @ObservationIgnored private let defaults:UserDefaults
    @ObservationIgnored private var restoration:Task<Void,Never>?
    @ObservationIgnored private var generation=UUID()
    @ObservationIgnored var changed:(()->Void)?
    @ObservationIgnored private var reads:[UUID:CalendarReadLease]=[:]
    @ObservationIgnored private var connections:[CalendarService:CalendarReadLease]=[:]
    private(set) var restorationFailures=Set<CalendarService>()
    private(set) var owner=""
    private(set) var links:[CalendarService:LinkedCalendarProfile]=[:]
    private(set) var connecting:CalendarService?
    private(set) var disconnecting=Set<CalendarService>()
    private(set) var refreshing=Set<CalendarService>()
    private(set) var replacement:PendingCalendarReplacement?
    private(set) var message:String?
    private(set) var restoring=false
    private(set) var revision=0
    var profiles:[LinkedCalendarProfile] {CalendarService.allCases.compactMap{links[$0]}}
    var connected:Bool {!links.isEmpty}
    var active:Bool {connected || restoring || !restorationFailures.isEmpty}
    var configured:Set<CalendarService> {authorizer.configured}
    init(authorizer:any CalendarAuthorizing,api:CalendarReadAPI=CalendarReadAPI(),defaults:UserDefaults = .standard) {self.authorizer=authorizer;self.api=api;self.defaults=defaults}
    func install(_ authorizer:any CalendarAuthorizing) {
        self.authorizer.cancel(service:nil);self.authorizer.bind(owner:"");self.authorizer=authorizer
        let previous=owner;owner="";bind(owner:previous)
    }
    func bind(owner:String) {
        guard self.owner != owner else {return}
        restoration?.cancel();connections.values.forEach{$0.cancel()};connections=[:];replacement?.lease.cancel();restorationFailures=[]
        generation=UUID();self.owner=owner;links=[:];connecting=nil;disconnecting=[];refreshing=[];replacement=nil;message=nil
        authorizer.bind(owner:owner);restoring = !owner.isEmpty;mutated()
        guard !owner.isEmpty else {restoration=nil;return}
        let binding=generation
        restoration=Task { [weak self] in
            guard let self else {return}
            for service in CalendarService.allCases {
                do {
                    let identity=try await self.authorizer.restore(owner:owner,service:service)
                    guard self.current(owner,binding) else {return}
                    if let identity,!identity.id.isEmpty {
                        var profile=LinkedCalendarProfile(service:service,identity:identity)
                        if self.defaults.string(forKey:self.key(service)+".identity")==identity.id {profile.selected=Set((self.defaults.stringArray(forKey:self.key(service)+".selected") ?? []).filter{!$0.isEmpty && $0.utf8.count<=4096}.prefix(500))}
                        self.links[service]=profile
                    } else if self.defaults.string(forKey:self.key(service)+".identity") != nil {
                        self.restorationFailures.insert(service);self.message="A saved calendar connection is missing. Reconnect it to refresh busy time."
                    }
                } catch {guard self.current(owner,binding) else {return};self.restorationFailures.insert(service);self.message="A calendar connection could not be restored. Reconnect it to read busy time."}
            }
            guard self.current(owner,binding) else {return};self.restoring=false;self.mutated()
        }
    }
    private func matches(_ owner:String,_ generation:UUID)->Bool {self.owner==owner && self.generation==generation}
    private func current(_ owner:String,_ generation:UUID)->Bool {matches(owner,generation) && !Task.isCancelled}
    func eraseAccount(_ account:String) async throws {
        if owner==account { bind(owner:"") }
        try await authorizer.eraseAccount(account)
        for service in CalendarService.allCases {
            let prefix="planner.linked."+account+"."+service.rawValue
            defaults.removeObject(forKey:prefix+".identity");defaults.removeObject(forKey:prefix+".selected")
        }
    }
    private func key(_ service:CalendarService)->String {"planner.linked."+owner+"."+service.rawValue}
    private func mutated() {reads.values.forEach{$0.cancel()};reads=[:];revision+=1;changed?()}
    private func persist(_ profile:LinkedCalendarProfile) {defaults.set(profile.identity.id,forKey:key(profile.service)+".identity");defaults.set(profile.selected.sorted(),forKey:key(profile.service)+".selected")}
    func connect(_ service:CalendarService) async {
        guard !owner.isEmpty,connecting==nil,replacement==nil,!disconnecting.contains(service) else {return}
        guard configured.contains(service) else {message=service.title+" connections are not available in this build.";return}
        let account=owner,binding=generation
        await restoration?.value;guard current(account,binding),connecting==nil,replacement==nil,!disconnecting.contains(service) else {return}
        let lease=CalendarReadLease();connections[service]=lease;connecting=service;message=nil
        defer{if matches(account,binding),connections[service] === lease {connections.removeValue(forKey:service);if connecting==service {connecting=nil}}}
        var attempt:UUID?
        do {
            let pending=try await authorizer.begin(owner:account,service:service);attempt=pending
            guard current(account,binding),!disconnecting.contains(service) else {authorizer.discard(pending);return}
            try lease.check()
            let token=try await authorizer.token(owner:account,service:service,pending:pending,forceRefresh:false)
            try lease.check()
            let catalog=try await api.calendars(service,accessToken:token,lease:lease)
            guard current(account,binding),!disconnecting.contains(service),let identity=catalog.identity else {authorizer.discard(pending);return}
            if let previous=links[service],previous.identity.id != identity {
                replacement=PendingCalendarReplacement(id:pending,owner:account,generation:binding,previousID:previous.identity.id,catalog:catalog,lease:lease);return
            }
            try await commit(catalog,pending:pending,account:account,binding:binding,lease:lease)
        } catch {
            if let attempt {authorizer.discard(attempt)}
            guard current(account,binding) else {return}
            if !(error is CancellationError) {message=(error as? CalendarReadFailure)?.localizedDescription ?? "Could not connect this calendar account. Try again."}
        }
    }
    private func commit(_ catalog:CalendarCatalog,pending:UUID,account:String,binding:UUID,lease:CalendarReadLease) async throws {
        try lease.check()
        guard current(account,binding),let id=catalog.identity else {authorizer.discard(pending);throw CancellationError()}
        let identity=CalendarAccountIdentity(id:id,label:String((catalog.accountLabel ?? catalog.service.title).prefix(500)))
        try await authorizer.accept(owner:account,service:catalog.service,pending:pending,identity:identity)
        try lease.check()
        guard current(account,binding),!disconnecting.contains(catalog.service) else {throw CancellationError()}
        var profile=LinkedCalendarProfile(service:catalog.service,identity:identity,calendars:catalog.calendars)
        if let previous=links[catalog.service],previous.identity.id==id {profile.selected=previous.selected}
        links[catalog.service]=profile;restorationFailures.remove(catalog.service);persist(profile);replacement=nil;mutated()
    }
    func clearMessage() {message=nil}
    func cancelConnection() {
        guard let service=connecting else {return}
        connections.removeValue(forKey:service)?.cancel();authorizer.cancel(service:service);connecting=nil
    }
    func cancelReplacement() {if let replacement {replacement.lease.cancel();authorizer.discard(replacement.id)};replacement=nil}
    func confirmReplacement() async {
        guard let pending=replacement,current(pending.owner,pending.generation),links[pending.service]?.identity.id==pending.previousID else {cancelReplacement();return}
        connecting=pending.service;connections[pending.service]=pending.lease
        defer{if matches(pending.owner,pending.generation),connections[pending.service] === pending.lease {connections.removeValue(forKey:pending.service);if connecting==pending.service {connecting=nil}}}
        do {try await commit(pending.catalog,pending:pending.id,account:pending.owner,binding:pending.generation,lease:pending.lease)} catch {
            authorizer.discard(pending.id)
            if current(pending.owner,pending.generation) {replacement=nil;if !(error is CancellationError) {message="Could not replace this calendar account. Your earlier connection is kept."}}
        }
    }
    func refreshCalendars(_ service:CalendarService) async {
        let account=owner,binding=generation
        guard let profile=links[service],!profile.needsReconnect,!disconnecting.contains(service),!refreshing.contains(service),!account.isEmpty else {return}
        refreshing.insert(service)
        let version=revision,id=UUID(),lease=CalendarReadLease();reads[id]=lease
        defer{reads.removeValue(forKey:id);if matches(account,binding) {refreshing.remove(service)}}
        do {
            let catalog=try await authorized(service,account:account,binding:binding) { token in
                try lease.check();return try await self.api.calendars(service,accessToken:token,lease:lease)
            }
            guard current(account,binding),version==revision else {return}
            guard catalog.identity==profile.identity.id else {throw CalendarReadFailure.changedAccount}
            links[service]?.calendars=catalog.calendars;links[service]?.notice=nil;mutated()
        } catch {
            guard current(account,binding),version==revision,!(error is CancellationError) else {return}
            let failure=error as? CalendarReadFailure ?? .unavailable;links[service]?.notice=failure.localizedDescription
            if [.signIn,.permission,.changedAccount].contains(failure) {links[service]?.needsReconnect=true;mutated()}
        }
    }
    func select(_ service:CalendarService,id:String,enabled:Bool) {
        guard var profile=links[service],!disconnecting.contains(service),!profile.needsReconnect else {return}
        if enabled {guard profile.calendars.contains(where:{$0.remoteID==id}),profile.selected.count<500 else {return};profile.selected.insert(id)} else {profile.selected.remove(id)}
        links[service]=profile;persist(profile);mutated()
    }
    func removeUnavailable(_ service:CalendarService) {
        guard var profile=links[service] else {return};profile.selected.formIntersection(profile.calendars.map(\.remoteID));links[service]=profile;persist(profile);mutated()
    }
    func disconnect(_ service:CalendarService) async {
        guard !owner.isEmpty,!disconnecting.contains(service),links[service] != nil || restorationFailures.contains(service) else {return}
        let account=owner,binding=generation;connections.removeValue(forKey:service)?.cancel();if connecting==service {connecting=nil};authorizer.cancel(service:service)
        if replacement?.service==service {cancelReplacement()}
        disconnecting.insert(service)
        if var profile=links[service] {profile.selected=[];profile.needsReconnect=true;links[service]=profile;persist(profile)}
        mutated()
        defer{if matches(account,binding){disconnecting.remove(service)}}
        do {
            try await authorizer.disconnect(owner:account,service:service)
            guard current(account,binding) else {return}
            links.removeValue(forKey:service);restorationFailures.remove(service);defaults.removeObject(forKey:key(service)+".identity");defaults.removeObject(forKey:key(service)+".selected");mutated()
        } catch {guard current(account,binding) else {return};message="This connection could not be removed securely. Its calendars are hidden; try Disconnect again."}
    }
    private func authorized<T>(_ service:CalendarService,account:String,binding:UUID,_ operation:(String) async throws ->T) async throws ->T {
        let token=try await authorizer.token(owner:account,service:service,pending:nil,forceRefresh:false)
        guard current(account,binding) else {throw CancellationError()}
        do {return try await operation(token)} catch CalendarReadFailure.signIn {
            guard current(account,binding) else {throw CancellationError()}
            let renewed=try await authorizer.token(owner:account,service:service,pending:nil,forceRefresh:true)
            guard current(account,binding) else {throw CancellationError()};return try await operation(renewed)
        }
    }
    func read(window:DateInterval,titles:Bool) async ->LinkedCalendarWindow? {
        let account=owner,binding=generation
        await restoration?.value
        guard current(account,binding),!account.isEmpty else {return nil}
        let version=revision,profiles=profiles,id=UUID(),lease=CalendarReadLease();reads[id]=lease
        defer{reads.removeValue(forKey:id)}
        guard !profiles.isEmpty else {return LinkedCalendarWindow(state:restorationFailures.isEmpty ? "off":"unavailable",status:restorationFailures.isEmpty ? "No linked calendar accounts.":"A calendar connection could not be restored. Reconnect it to refresh busy time.")}
        var events:[PlannerEvent]=[],notes=restorationFailures.map{$0.title+": Connection could not be restored."},failures=restorationFailures.count,choosing=0
        for profile in profiles {
            let service=profile.service
            if profile.needsReconnect || disconnecting.contains(service) {failures+=1;notes.append(service.title+": Reconnect to read busy time.");continue}
            do {
                let result:(CalendarCatalog,[PlannerEvent],Bool)=try await authorized(service,account:account,binding:binding) { token in
                    try lease.check()
                    let catalog=try await self.api.calendars(service,accessToken:token,lease:lease)
                    guard catalog.identity==profile.identity.id else {throw CalendarReadFailure.changedAccount}
                    let chosen=catalog.calendars.filter{profile.selected.contains($0.remoteID)}
                    var values:[PlannerEvent]=[]
                    for choice in chosen {values += try await self.api.events(choice,window:window,titles:titles,accessToken:token,lease:lease)}
                    return (catalog,values,chosen.count==profile.selected.count)
                }
                guard current(account,binding),revision==version else {return nil}
                links[service]?.calendars=result.0.calendars;links[service]?.notice=nil
                if profile.selected.isEmpty {choosing+=1;notes.append(service.title+": Choose calendars.")}
                else if !result.2 {failures+=1;notes.append(service.title+": Some selected calendars are unavailable.")}
                else {notes.append(service.title+": Busy time refreshed.")}
                events += result.1
            } catch {
                guard current(account,binding),revision==version else {return nil}
                if error is CancellationError {return nil}
                failures+=1
                let failure=error as? CalendarReadFailure ?? .unavailable
                links[service]?.notice=failure.localizedDescription
                if [.signIn,.permission,.changedAccount].contains(failure) {links[service]?.needsReconnect=true;mutated()}
                notes.append(service.title+": "+failure.localizedDescription)
            }
        }
        guard current(account,binding),revision==version else {return nil}
        let state=failures>0 ? (events.isEmpty ? "unavailable":"incomplete"):choosing>0 ? (events.isEmpty ? "choose":"incomplete"):"ready"
        return LinkedCalendarWindow(state:state,events:events.sorted{$0.start==$1.start ? $0.id<$1.id:$0.start<$1.start},status:notes.joined(separator:"\n"))
    }
}
