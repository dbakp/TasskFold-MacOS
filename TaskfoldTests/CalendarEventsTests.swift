import XCTest
@testable import TaskfoldCore

final class CalendarEventsTests: XCTestCase {
    actor Provider: PlannerCalendarProviding {
        var allowed = true, requests = 0, reads = 0, titlesRequested = false, gated = false
        var continuation: CheckedContinuation<Void, Never>?
        var lastWindow: DateInterval?
        func authorized() -> Bool { allowed }
        func requestAccess() -> Bool { requests += 1; return allowed }
        func calendars() -> [PlannerCalendar] { [PlannerCalendar(id: "work", title: "Work", source: "Fixture")] }
        func events(ids: Set<String>, window: DateInterval, titles: Bool) async -> [PlannerEvent] {
            reads += 1; titlesRequested = titles; lastWindow = window
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

    @MainActor func testCapacityReadDoesNotAskPermissionExposeTitlesOrReplaceVisibleDay() async throws {
        let name = "capacity-calendar-" + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "planner.calendar.owner.connected"); defaults.set(["work"], forKey: "planner.calendar.owner.selected")
        let provider = Provider(), store = CalendarBusyStore(provider: provider, defaults: defaults)
        store.bind(account: "owner"); store.setTitles(true)
        let now = TaskPlanning.instant("2026-10-06T08:00:00Z")!
        await store.refresh(on: now.addingTimeInterval(86400)); let visible = store.events
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
        let readResult = await store.capacityWindow(now: now, calendar: calendar)
        let result = try XCTUnwrap(readResult)
        XCTAssertEqual(result.state, "ready"); XCTAssertEqual(result.account, "owner")
        XCTAssertEqual(store.events, visible); XCTAssertTrue(store.ready)
        let requests = await provider.requests, titles = await provider.titlesRequested
        XCTAssertEqual(requests, 0); XCTAssertFalse(titles); XCTAssertEqual(result.events.first?.title, "Busy")
        let range = await provider.lastWindow
        XCTAssertEqual(range?.start, calendar.startOfDay(for: now))
        XCTAssertEqual(range?.end, calendar.date(byAdding: .day, value: 8, to: calendar.startOfDay(for: now)))
        let dst = TaskPlanning.instant("2026-10-24T10:00:00Z")!
        _ = await store.capacityWindow(now: dst, calendar: calendar)
        let dstRange = await provider.lastWindow
        XCTAssertEqual(dstRange?.duration, 8 * 86400 + 3600)

        store.select(["work", "missing"])
        let partial = await store.capacityWindow(now: now, calendar: calendar)
        XCTAssertEqual(partial?.state, "incomplete")
        await provider.setAllowed(false)
        let revoked = await store.capacityWindow(now: now, calendar: calendar)
        XCTAssertEqual(revoked?.state, "unavailable"); XCTAssertTrue(revoked?.events.isEmpty == true)
    }
    @MainActor func testInFlightCapacityReadRejectsAccountCycleAndSelectionChanges() async {
        let name = "capacity-calendar-" + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "planner.calendar.owner.connected"); defaults.set(["work"], forKey: "planner.calendar.owner.selected")
        let provider = Provider(), store = CalendarBusyStore(provider: provider, defaults: defaults)
        store.bind(account: "owner"); await provider.gate()
        let read = Task { await store.capacityWindow() }
        while await provider.reads == 0 { await Task.yield() }
        store.bind(account: "other"); store.bind(account: "owner")
        await provider.release(); let value = await read.value; XCTAssertNil(value)
        let second = Task { await store.capacityWindow() }
        while await provider.reads < 2 { await Task.yield() }
        store.select(["work", "missing"])
        await provider.release(); let changed = await second.value; XCTAssertNil(changed)

    }

}
