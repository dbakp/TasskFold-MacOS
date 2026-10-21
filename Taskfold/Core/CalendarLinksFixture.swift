#if DEBUG
import Foundation

/// Opt-in native acceptance fixture. Its session intercepts every request and never opens a socket.
@MainActor enum CalendarLinksFixture {
    static func make()->CalendarLinksStore {
        let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[CalendarFixtureProtocol.self]
        return CalendarLinksStore(authorizer:CalendarFixtureAuthorization(),api:CalendarReadAPI(session:URLSession(configuration:configuration)))
    }
}
@MainActor private final class CalendarFixtureAuthorization:CalendarAuthorizing {
    let configured=Set(CalendarService.allCases)
    private var owner=""
    private var attempts:[UUID:CalendarService]=[:]
    private var reset=Set<String>()
    func bind(owner:String) {self.owner=owner;attempts=[:]}
    func restore(owner:String,service:CalendarService) async throws ->CalendarAccountIdentity? {
        let key="calendar.fixture."+owner+service.rawValue
        if ProcessInfo.processInfo.arguments.contains("--planner-fixture"),reset.insert(key).inserted {
            UserDefaults.standard.removeObject(forKey:key)
            for suffix in [".identity",".selected"] {UserDefaults.standard.removeObject(forKey:"planner.linked."+owner+"."+service.rawValue+suffix)}
        }
        if service == .google,ProcessInfo.processInfo.arguments.contains("--planner-fixture"),ProcessInfo.processInfo.arguments.contains("--calendar-layout-ready") {
            UserDefaults.standard.set("workshop@example.invalid",forKey:"planner.linked."+owner+".google.identity")
            UserDefaults.standard.set(["workshop@example.invalid"],forKey:"planner.linked."+owner+".google.selected")
            CalendarBusyStore.shared.setTitles(true)
        }
        let stored=UserDefaults.standard.object(forKey:key) as? Bool
        guard stored ?? (service == .google) else {return nil}
        return CalendarAccountIdentity(id:service == .google ? "workshop@example.invalid":"fixture-default",label:"workshop@example.invalid")
    }
    func begin(owner:String,service:CalendarService) async throws ->UUID {guard owner==self.owner else {throw CancellationError()};let id=UUID();attempts[id]=service;return id}
    func token(owner:String,service:CalendarService,pending:UUID?,forceRefresh:Bool) async throws ->String {guard owner==self.owner else {throw CancellationError()};return "synthetic-native-calendar-fixture"}
    func accept(owner:String,service:CalendarService,pending:UUID,identity:CalendarAccountIdentity) async throws {
        guard owner==self.owner,attempts[pending]==service else {throw CancellationError()};attempts.removeValue(forKey:pending)
        UserDefaults.standard.set(true,forKey:"calendar.fixture."+owner+service.rawValue)
    }
    func discard(_ pending:UUID) {attempts.removeValue(forKey:pending)}
    func cancel(service:CalendarService?) {attempts=attempts.filter{service != nil && $0.value != service}}
    func disconnect(owner:String,service:CalendarService) async throws {UserDefaults.standard.set(false,forKey:"calendar.fixture."+owner+service.rawValue)}
}
private final class CalendarFixtureProtocol:URLProtocol,@unchecked Sendable {
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        guard let url=request.url else {client?.urlProtocol(self,didFailWithError:URLError(.badURL));return}
        let google=url.host=="www.googleapis.com",list=url.path.hasSuffix("calendarList") || url.path=="/v1.0/me/calendars"
        let object:[String:Any]
        if list {
            object=google ? ["items":[["id":"workshop@example.invalid","summary":"Workshop","primary":true,"timeZone":"Europe/Copenhagen"],["id":"personal@example.invalid","summary":"Personal","primary":false,"timeZone":"Europe/Copenhagen"]]]:["value":[["id":"fixture-default","name":"Studio","isDefaultCalendar":true,"owner":["address":"workshop@example.invalid"]]]]
        } else {
            let query=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []
            let start=query.first{$0.name==(google ? "timeMin":"startDateTime")}?.value.flatMap{ISO8601DateFormatter().date(from:$0)} ?? Date()
            let formatter=ISO8601DateFormatter(),from=formatter.string(from:start.addingTimeInterval(9*3600)),to=formatter.string(from:start.addingTimeInterval(10*3600))
            object=google ? ["items":[["id":"synthetic-review","summary":"Design review","visibility":"default","start":["dateTime":from],"end":["dateTime":to]]]]:["value":[["id":"synthetic-review","subject":"Studio review","sensitivity":"normal","start":["dateTime":from,"timeZone":"UTC"],"end":["dateTime":to,"timeZone":"UTC"]]]]
        }
        var payload=object
        if google,!list,ProcessInfo.processInfo.arguments.contains("--calendar-layout-all-day") {
            let query=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []
            let start=query.first{$0.name=="timeMin"}?.value.flatMap{ISO8601DateFormatter().date(from:$0)} ?? Date()
            var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"Europe/Copenhagen")!
            let day=calendar.startOfDay(for:start.addingTimeInterval(12*3600)),end=calendar.date(byAdding:.day,value:1,to:day)!
            var rows=payload["items"] as? [[String:Any]] ?? []
            rows.append(["id":"synthetic-offsite","summary":"Workshop offsite","visibility":"default","start":["date":TaskPlanner.dayKey(day,calendar:calendar)],"end":["date":TaskPlanner.dayKey(end,calendar:calendar)]])
            payload["items"]=rows
        }
        let data=try! JSONSerialization.data(withJSONObject:payload)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
