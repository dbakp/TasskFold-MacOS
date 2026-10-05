import XCTest
@testable import TaskfoldCore

final class CalendarEventsTests: XCTestCase {
    actor Provider: PlannerCalendarProviding {
        var allowed = true, requests = 0, reads = 0, titlesRequested = false, gated = false
        var continuation: CheckedContinuation<Void, Never>?
        func authorized() -> Bool { allowed }
        func requestAccess() -> Bool { requests += 1; return allowed }
        func calendars() -> [PlannerCalendar] { [PlannerCalendar(id: "work", title: "Work", source: "Fixture")] }
        func events(ids: Set<String>, window: DateInterval, titles: Bool) async -> [PlannerEvent] {
            reads += 1; titlesRequested = titles
            if gated { await withCheckedContinuation { continuation = $0 } }
            return [PlannerEvent(id: "fixture", calendarID: "work", title: titles ? "Private event" : "Busy", start: window.start.addingTimeInterval(3600), end: window.start.addingTimeInterval(7200))]
        }
        func setAllowed(_ value: Bool) { allowed = value }
        func gate() { gated = true }
        func release() { continuation?.resume(); continuation = nil }
    }
    @MainActor func testReadingRequiresConnectionAndExplicitCalendarSelection() async {
        let name = "planner-tests-" + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let provider = Provider(), store = CalendarBusyStore(provider: provider, defaults: defaults)
        store.bind(account: "owner"); await store.refresh(on: Date())
        let initialRequests = await provider.requests, initialReads = await provider.reads
        XCTAssertEqual(initialRequests, 0); XCTAssertEqual(initialReads, 0); XCTAssertFalse(store.ready)
        await store.connect(); await store.refresh(on: Date())
        let readsBeforeSelection = await provider.reads
        XCTAssertEqual(readsBeforeSelection, 0); XCTAssertEqual(store.calendars.map(\.id), ["work"])
        store.select(["work"]); await store.refresh(on: Date())
        XCTAssertEqual(store.events.first?.title, "Busy"); XCTAssertTrue(store.ready)
        store.setTitles(true); XCTAssertTrue(store.events.isEmpty)
        await store.refresh(on: Date()); XCTAssertEqual(store.events.first?.title, "Private event")
        store.disconnect(); XCTAssertTrue(store.events.isEmpty); XCTAssertTrue(store.selected.isEmpty); XCTAssertFalse(store.connected)
    }
    @MainActor func testAccountSwitchAndRevokedAccessClearBusyData() async {
        let name = "planner-tests-" + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let provider = Provider(), store = CalendarBusyStore(provider: provider, defaults: defaults)
        store.bind(account: "owner"); await store.connect(); store.select(["work"]); await store.refresh(on: Date())
        store.bind(account: "other"); XCTAssertTrue(store.events.isEmpty); XCTAssertTrue(store.selected.isEmpty); XCTAssertFalse(store.connected)
        await store.refresh(on: Date()); XCTAssertTrue(store.events.isEmpty)
        store.bind(account: "owner"); XCTAssertTrue(store.connected); XCTAssertEqual(store.selected, ["work"])
        await provider.setAllowed(false); await store.refresh(on: Date())
        XCTAssertTrue(store.events.isEmpty); XCTAssertFalse(store.ready); XCTAssertTrue(store.status.contains("unavailable"))
    }
    @MainActor func testUnavailableSelectionNeverClaimsCompleteBusyTime() async {
        let name = "planner-tests-" + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CalendarBusyStore(provider: Provider(), defaults: defaults)
        store.bind(account: "owner"); await store.connect(); store.select(["work", "deleted"]); await store.refresh(on: Date())
        XCTAssertFalse(store.ready); XCTAssertEqual(store.events.count, 1); XCTAssertTrue(store.status.contains("incomplete"))
        store.select(["deleted"]); await store.refresh(on: Date()); XCTAssertTrue(store.events.isEmpty); XCTAssertFalse(store.ready)
    }
    @MainActor func testInFlightEventReadCannotRepopulatePreviousAccount() async {
        let name = "planner-tests-" + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let provider = Provider(), store = CalendarBusyStore(provider: provider, defaults: defaults)
        store.bind(account: "owner"); await store.connect(); store.select(["work"]); await provider.gate()
        let read = Task { await store.refresh(on: Date()) }
        while await provider.reads == 0 { await Task.yield() }
        store.bind(account: "other"); await provider.release(); await read.value
        XCTAssertTrue(store.events.isEmpty); XCTAssertTrue(store.calendars.isEmpty); XCTAssertFalse(store.ready)
        XCTAssertEqual(store.status, "Calendar busy time is not connected.")
    }
}
