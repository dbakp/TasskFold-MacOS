import Foundation
import Observation
import EventKit

struct PlannerCalendar: Identifiable, Equatable, Sendable {
    var id: String, title: String, source: String
}
protocol PlannerCalendarProviding: Sendable {
    func authorized() async -> Bool
    func requestAccess() async throws -> Bool
    func calendars() async -> [PlannerCalendar]
    func events(ids: Set<String>, window: DateInterval, titles: Bool) async -> [PlannerEvent]
}
/// EventKit stays on one actor. The app reads selected events and never writes to calendars.
actor SystemPlannerCalendarProvider: PlannerCalendarProviding {
    private let store = EKEventStore()
    func authorized() -> Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestFullAccessToEvents { granted, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: granted) }
            }
        }
    }
    func calendars() -> [PlannerCalendar] {
        guard authorized() else { return [] }
        return store.calendars(for: .event).map { PlannerCalendar(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title) }.sorted { ($0.source, $0.title, $0.id) < ($1.source, $1.title, $1.id) }
    }
    func events(ids: Set<String>, window: DateInterval, titles: Bool) -> [PlannerEvent] {
        guard authorized() else { return [] }
        let calendars = store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
        // EventKit interprets nil as all calendars. An empty selection must read nothing.
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: calendars)
        let events = store.events(matching: predicate).filter { event in
            event.availability != .free && event.status != .canceled && event.endDate > event.startDate
                && !(event.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }
        }.map { event in
            PlannerEvent(id: event.calendar.calendarIdentifier + ":" + (event.eventIdentifier ?? event.calendarItemIdentifier) + ":" + String(event.startDate.timeIntervalSinceReferenceDate),
                calendarID: event.calendar.calendarIdentifier, title: titles ? (event.title ?? "Busy") : "Busy", source: event.calendar.title,
                start: event.startDate, end: event.endDate, allDay: event.isAllDay)
        }
        return Array(Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values).sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
}
/// Debug workspaces never read the user's calendar or request OS permission.
struct EmptyPlannerCalendarProvider: PlannerCalendarProviding {
    func authorized() async -> Bool { false }
    func requestAccess() async throws -> Bool { false }
    func calendars() async -> [PlannerCalendar] { [] }
    func events(ids: Set<String>, window: DateInterval, titles: Bool) async -> [PlannerEvent] { [] }
}

@MainActor @Observable final class CalendarBusyStore {
    static let shared: CalendarBusyStore = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting") || ProcessInfo.processInfo.arguments.contains("--preview") { return CalendarBusyStore(provider: EmptyPlannerCalendarProvider(), links: CalendarLinksStore.shared) }
        #endif
        return CalendarBusyStore(provider: SystemPlannerCalendarProvider(), links: CalendarLinksStore.shared)
    }()
    let links: CalendarLinksStore?
    var anyConnected: Bool { connected || links?.active == true }
    private let provider: any PlannerCalendarProviding
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var accountGeneration = UUID()
    @ObservationIgnored private var capacityGeneration = UUID()
    private(set) var account = ""
    private(set) var connected = false
    private(set) var selected = Set<String>()
    private(set) var showTitles = false
    private(set) var calendars: [PlannerCalendar] = []
    private(set) var events: [PlannerEvent] = []
    private(set) var status = "Calendar busy time is not connected."
    private(set) var deviceStatus = "Calendar busy time is not connected."
    private(set) var ready = false
    private(set) var revision = 0
    init(provider: any PlannerCalendarProviding, defaults: UserDefaults = .standard, links:CalendarLinksStore?=nil) {
        self.provider=provider;self.defaults=defaults;self.links=links
        links?.changed={ [weak self] in guard let self else {return};self.generation=UUID();self.capacityGeneration=UUID();self.events=[];self.ready=false;self.revision+=1 }
    }
    private var key: String { "planner.calendar." + account }
    func bind(account: String) {
        guard self.account != account else { return }
        generation = UUID(); accountGeneration = UUID(); self.account = account; events = []; calendars = []; ready = false
        connected = !account.isEmpty && defaults.bool(forKey: key + ".connected")
        selected = Set(defaults.stringArray(forKey: key + ".selected") ?? []); showTitles = defaults.bool(forKey: key + ".titles")
        status = connected ? "Loading selected calendars…" : "Calendar busy time is not connected."
        deviceStatus=status
        links?.bind(owner:account)
    }
    func connect() async {
        guard !account.isEmpty else { return }
        let token = accountGeneration
        do {
            let allowed = try await provider.requestAccess()
            guard token == accountGeneration else { return }
            connected = allowed; defaults.set(allowed, forKey: key + ".connected")
            status = allowed ? "Choose calendars to show busy time." : "Calendar access was not granted. Enable full calendar access in system settings to connect."
            deviceStatus=status;revision += 1
        } catch { guard token == accountGeneration else { return }; status = "Could not connect calendars: " + error.localizedDescription;deviceStatus=status }
    }
    func eraseAccount(_ account:String) async throws {
        if self.account==account { bind(account:"") }
        try await links?.eraseAccount(account)
        for suffix in [".connected", ".selected", ".titles"] { defaults.removeObject(forKey:"planner.calendar."+account+suffix) }
    }
    func disconnect() {
        generation = UUID(); accountGeneration = UUID(); connected = false; ready = false; events = []; calendars = []; selected = []; if links?.active != true { showTitles = false }
        for suffix in (links?.active == true ? [".connected", ".selected"] : [".connected", ".selected", ".titles"]) { defaults.removeObject(forKey: key + suffix) }
        status = "Calendar busy time is not connected."; deviceStatus=status;revision += 1
    }
    func select(_ ids: Set<String>) { generation = UUID(); selected = ids; defaults.set(ids.sorted(), forKey: key + ".selected"); events = []; ready = false; revision += 1 }
    func setTitles(_ value: Bool) { generation = UUID(); showTitles = value; defaults.set(value, forKey: key + ".titles"); events = []; ready = false; revision += 1 }
    /// Device and direct connections share the same readiness rules, but keep separate permissions and selections.
    private func deviceWindow(_ window:DateInterval,titles:Bool,publishCalendars:Bool,current:()->Bool) async ->LinkedCalendarWindow? {
        func result(state:String,events:[PlannerEvent]=[],status:String)->LinkedCalendarWindow {
            if publishCalendars {deviceStatus=status};return LinkedCalendarWindow(state:state,events:events,status:status)
        }
        guard connected else {return result(state:"off",status:deviceStatus)}
        let authorized=await provider.authorized();guard current() else {return nil}
        guard authorized else {if publishCalendars {calendars=[]};return result(state:"unavailable",status:"Calendar access is unavailable. Enable full access in system settings, or disconnect.")}
        let calendars=await provider.calendars();guard current() else {return nil}
        if publishCalendars {self.calendars=calendars}
        let available=selected.intersection(calendars.map(\.id))
        guard !available.isEmpty else {return result(state:selected.isEmpty ? "choose":"unavailable",status:selected.isEmpty ? "Choose calendars to show busy time.":"Selected calendars are unavailable on this device.")}
        let values=await provider.events(ids:available,window:window,titles:titles);guard current() else {return nil}
        let stillAuthorized=await provider.authorized();guard current() else {return nil}
        guard stillAuthorized else {if publishCalendars {self.calendars=[]};return result(state:"unavailable",status:"Calendar access is unavailable.")}
        let known=values.filter{available.contains($0.calendarID) && $0.end>$0.start}
        return result(state:available==selected ? "ready":"incomplete",events:known,status:available==selected ? "Busy time from \(available.count) selected calendar\(available.count==1 ? "":"s").":"Some selected calendars are unavailable; busy time is incomplete.")
    }
    private func combinedWindow(_ window:DateInterval,titles:Bool,publishCalendars:Bool,current:()->Bool) async ->LinkedCalendarWindow? {
        guard let device=await deviceWindow(window,titles:titles,publishCalendars:publishCalendars,current:current),current() else {return nil}
        var sources=[device]
        if let links,links.active {
            guard let direct=await links.read(window:window,titles:titles),current() else {return nil};sources.append(direct)
        }
        sources.removeAll{$0.state=="off"}
        guard !sources.isEmpty else {return device}
        let states=Set(sources.map(\.state)),hasKnown=states.contains("ready") || states.contains("incomplete")
        let state=states==["ready"] ? "ready":states==["choose"] ? "choose":hasKnown ? "incomplete":"unavailable"
        let values=sources.flatMap(\.events).sorted{$0.start==$1.start ? $0.id<$1.id:$0.start<$1.start}
        return LinkedCalendarWindow(state:state,events:values,status:sources.map(\.status).joined(separator:"\n"))
    }
    func refresh(on day:Date,calendar:Calendar = .current) async {
        let token=UUID();generation=token;events=[];ready=false
        let binding=accountGeneration,settings=revision
        func current()->Bool {generation==token && accountGeneration==binding && settings==revision && !Task.isCancelled}
        guard !account.isEmpty else {return}
        guard let window=calendar.dateInterval(of:.day,for:day) else {status="Could not read this calendar day.";return}
        guard let result=await combinedWindow(window,titles:showTitles,publishCalendars:true,current:current),current() else {return}
        events=result.events;ready=result.state=="ready";status=result.status
    }
    /// An independent eight-day read never replaces the planner's visible day. Event names never enter capacity snapshots.
    func capacityWindow(now:Date=Date(),calendar input:Calendar = .current) async ->CalendarCapacityWindow? {
        let token=UUID();capacityGeneration=token
        let owner=account,settings=revision,binding=accountGeneration
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=input.timeZone
        func current()->Bool {token==capacityGeneration && binding==accountGeneration && owner==account && settings==revision && !Task.isCancelled}
        guard !owner.isEmpty else {return nil}
        let start=calendar.startOfDay(for:now)
        guard let end=calendar.date(byAdding:.day,value:8,to:start),let result=await combinedWindow(DateInterval(start:start,end:end),titles:false,publishCalendars:false,current:current),current() else {return nil}
        return CalendarCapacityWindow(account:owner,timeZone:calendar.timeZone.identifier,updated:now,state:result.state,events:result.events)
    }
}
