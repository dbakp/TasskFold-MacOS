import XCTest
@testable import TaskfoldCore

final class CalendarBlocksTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!; return c
    }()
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 10))! }
    private func task(_ id: String, title: String = "Write report", day: String = "2026-11-15", time: String = "09:00", minutes: Int? = 30, completed: Bool = false, extra: [String: JSON] = [:]) -> Record {
        var fields: [String: JSON] = ["id": .string(id), "title": .string(title), "due_date": .string(day), "due_time": .string(time), "completed": .bool(completed), "description": .string("Private note")]
        if let minutes { fields["duration_minutes"] = .number(Double(minutes)) }
        for (key, value) in extra { fields[key] = value }
        return Record(fields)
    }

    // MARK: Marker and busy-time exclusion

    func testMarkerRoundTripsInURLAndNotes() {
        let id = "3f2a9c1e-0000-4000-8000-123456789abc"
        XCTAssertEqual(CalendarBlocks.marker(for: id), "taskfold://task/" + id)
        XCTAssertEqual(CalendarBlocks.taskID(url: CalendarBlocks.markerURL(for: id), notes: nil), id)
        XCTAssertEqual(CalendarBlocks.taskID(url: nil, notes: CalendarBlocks.marker(for: id)), id)
        XCTAssertEqual(CalendarBlocks.taskID(url: nil, notes: "Server added text\n" + CalendarBlocks.marker(for: id) + "\nmore"), id)
        XCTAssertEqual(CalendarBlocks.taskID(inMarker: CalendarBlocks.marker(for: "a b/c")), "a b/c")
        XCTAssertNil(CalendarBlocks.taskID(url: URL(string: "https://example.com/taskfold"), notes: "Lunch with Sam"))
        XCTAssertNil(CalendarBlocks.taskID(inMarker: "taskfold://task/"))
        XCTAssertFalse(CalendarBlocks.isBlock(url: nil, notes: nil))
    }

    func testBusyTimeExcludesMarkedEventsWhateverTheirTitle() {
        struct Item { var title: String; var url: URL?; var notes: String? }
        let items = [
            Item(title: "Write report", url: CalendarBlocks.markerURL(for: "a"), notes: nil),
            Item(title: "Standup", url: nil, notes: nil),
            Item(title: "Taskfold", url: nil, notes: CalendarBlocks.marker(for: "b")),
            Item(title: "Taskfold lookalike title", url: URL(string: "https://example.com"), notes: "agenda"),
        ]
        let kept = CalendarBlocks.withoutBlocks(items, marker: { ($0.url, $0.notes) })
        XCTAssertEqual(kept.map(\.title), ["Standup", "Taskfold lookalike title"])
    }

    // MARK: Window and desired blocks

    func testWindowIsTodayPlusThirteenDays() {
        let window = CalendarBlocks.window(now: now, calendar: calendar)
        XCTAssertEqual(window.start, calendar.startOfDay(for: now))
        XCTAssertEqual(window.end, calendar.date(from: DateComponents(year: 2026, month: 11, day: 28)))
        var dst = Calendar(identifier: .gregorian); dst.timeZone = TimeZone(identifier: "America/New_York")!
        let spring = dst.date(from: DateComponents(year: 2026, month: 3, day: 3, hour: 12))!
        XCTAssertEqual(CalendarBlocks.window(now: spring, calendar: dst).end, dst.date(from: DateComponents(year: 2026, month: 3, day: 17)))
    }

    func testBlocksNeedStartTimeAndDurationAndAnOpenTask() {
        let window = CalendarBlocks.window(now: now, calendar: calendar)
        let tasks = [
            task("ok"),
            task("no-duration", minutes: nil),
            task("no-time", time: ""),
            task("done", completed: true),
            task("heading", extra: ["is_heading": .bool(true)]),
            task("later", day: "2026-11-28"),
            task("last-day", day: "2026-11-27"),
            task("yesterday", day: "2026-11-12"),
            task("earlier-today", day: "2026-11-14", time: "07:00"),
            task("", title: "No id"),
        ]
        let blocks = CalendarBlocks.blocks(from: tasks, window: window, calendar: calendar)
        XCTAssertEqual(Set(blocks.map(\.taskID)), ["ok", "last-day", "earlier-today"])
        let ok = blocks.first { $0.taskID == "ok" }!
        XCTAssertEqual(ok.title, "Write report")
        XCTAssertEqual(ok.end.timeIntervalSince(ok.start), 1800)
    }

    func testBlockSpanningIntoTheWindowCountsAndTitleNeverCarriesNotes() {
        let window = CalendarBlocks.window(now: now, calendar: calendar)
        let overnight = task("late", day: "2026-11-13", time: "23:00", minutes: 180)
        let blocks = CalendarBlocks.blocks(from: [overnight, task("blank", title: "  ")], window: window, calendar: calendar)
        XCTAssertEqual(blocks.map(\.taskID).sorted(), ["blank", "late"])
        XCTAssertEqual(blocks.first { $0.taskID == "blank" }?.title, CalendarBlocks.untitled)
        XCTAssertFalse(blocks.contains { $0.title.contains("Private note") })
    }

    // MARK: Diff

    private func block(_ id: String, title: String = "T", hour: Int = 9, minutes: Int = 30) -> CalendarBlocks.Block {
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: hour))!
        return CalendarBlocks.Block(taskID: id, title: title, start: start, end: start.addingTimeInterval(Double(minutes) * 60))
    }
    private func event(_ identifier: String, for block: CalendarBlocks.Block, created: Date? = nil) -> CalendarBlocks.Event {
        CalendarBlocks.Event(identifier: identifier, taskID: block.taskID, title: block.title, start: block.start, end: block.end, created: created)
    }

    func testPlanCreatesUpdatesAndDeletes() {
        let a = block("a"), b = block("b"), c = block("c")
        var changed = event("e-b", for: b); changed.title = "Old title"
        let plan = CalendarBlocks.plan(desired: [a, b], existing: [event("e-a", for: a), changed, event("e-c", for: c)])
        XCTAssertEqual(plan.creates, [])
        XCTAssertEqual(plan.updates, [CalendarBlocks.Update(identifier: "e-b", block: b)])
        XCTAssertEqual(plan.deletes, ["e-c"])
        XCTAssertEqual(plan.keep, ["a": "e-a", "b": "e-b"])
        XCTAssertEqual(CalendarBlocks.plan(desired: [a, c], existing: [event("e-a", for: a)]).creates, [c])
    }

    func testMovedTimeUpdatesInPlaceAndMatchingEventsNeedNoWrite() {
        let a = block("a", hour: 9), moved = block("a", hour: 14)
        XCTAssertTrue(CalendarBlocks.plan(desired: [a], existing: [event("e", for: a)]).isEmpty)
        let plan = CalendarBlocks.plan(desired: [moved], existing: [event("e", for: a)])
        XCTAssertEqual(plan.updates, [CalendarBlocks.Update(identifier: "e", block: moved)])
        XCTAssertTrue(plan.creates.isEmpty && plan.deletes.isEmpty)
    }

    func testDuplicatesKeepTheEarliestCreatedOnEveryDevice() {
        let a = block("a")
        let early = Date(timeIntervalSince1970: 1_000), late = Date(timeIntervalSince1970: 2_000)
        let events = [event("z-first", for: a, created: early), event("a-second", for: a, created: late), event("m-unknown", for: a, created: nil)]
        for ordering in [events, events.reversed()] {
            let plan = CalendarBlocks.plan(desired: [a], existing: ordering, mapping: ["a": "a-second"])
            XCTAssertEqual(plan.keep["a"], "z-first")
            XCTAssertEqual(Set(plan.deletes), ["a-second", "m-unknown"])
            XCTAssertTrue(plan.updates.isEmpty && plan.creates.isEmpty)
        }
        let tie = CalendarBlocks.plan(desired: [a], existing: [event("b", for: a), event("a", for: a)])
        XCTAssertEqual(tie.keep["a"], "a"); XCTAssertEqual(tie.deletes, ["b"])
    }

    func testStaleMappingRemovesEventsThatLeftTheReadWindowOnly() {
        let a = block("a")
        let plan = CalendarBlocks.plan(desired: [a], existing: [event("e-a", for: a)], mapping: ["a": "e-a", "gone": "e-gone", "other": "e-a"])
        XCTAssertEqual(plan.deletes, ["e-gone"])
    }

    // MARK: Sync against a fake calendar

    actor Fake: CalendarBlockStoring {
        struct Stored { var identifier: String, calendarID: String, title: String, start: Date, end: Date, url: URL?, notes: String?, created: Date }
        var items: [Stored] = []
        var level = CalendarBlockAccess.full
        var accessRequests = 0, writes = 0, next = 0
        var grant = true
        func access() -> CalendarBlockAccess { level }
        func requestFullAccess() -> Bool { accessRequests += 1; if grant { level = .full }; return grant }
        func writableCalendars() -> [PlannerCalendar] { [PlannerCalendar(id: "taskfold", title: "Taskfold", source: "iCloud"), PlannerCalendar(id: "work", title: "Work", source: "Exchange")] }
        func resolveCalendar(preferredID: String?) throws -> PlannerCalendar {
            guard level == .full else { throw CalendarBlockFailure.accessNeeded }
            let all = writableCalendars()
            if let preferredID { guard let match = all.first(where: { $0.id == preferredID }) else { throw CalendarBlockFailure.calendarUnavailable }; return match }
            return all[0]
        }
        func seed(_ item: Stored) { items.append(item) }
        func markedEvents(calendarID: String, window: DateInterval) throws -> [CalendarBlocks.Event] {
            items.filter { $0.calendarID == calendarID && CalendarBlocks.isBlock(url: $0.url, notes: $0.notes) && $0.start < window.end && $0.end > window.start }
                .map { CalendarBlocks.Event(identifier: $0.identifier, taskID: CalendarBlocks.taskID(url: $0.url, notes: $0.notes)!, title: $0.title, start: $0.start, end: $0.end, created: $0.created) }
        }
        func apply(_ plan: CalendarBlocks.Plan, calendarID: String) throws -> [String: String] {
            var created: [String: String] = [:]
            for block in plan.creates {
                next += 1; writes += 1
                let id = "ev-\(next)"
                items.append(Stored(identifier: id, calendarID: calendarID, title: block.title, start: block.start, end: block.end, url: CalendarBlocks.markerURL(for: block.taskID), notes: CalendarBlocks.marker(for: block.taskID), created: Date(timeIntervalSince1970: Double(next))))
                created[block.taskID] = id
            }
            for update in plan.updates {
                guard let i = items.firstIndex(where: { $0.identifier == update.identifier && $0.calendarID == calendarID && CalendarBlocks.isBlock(url: $0.url, notes: $0.notes) }) else { continue }
                writes += 1; items[i].title = update.block.title; items[i].start = update.block.start; items[i].end = update.block.end
            }
            for id in plan.deletes {
                guard let i = items.firstIndex(where: { $0.identifier == id && $0.calendarID == calendarID && CalendarBlocks.isBlock(url: $0.url, notes: $0.notes) }) else { continue }
                writes += 1; items.remove(at: i)
            }
            return created
        }
        func removeAll(calendarID: String) throws -> Int {
            let before = items.count
            items.removeAll { $0.calendarID == calendarID && CalendarBlocks.isBlock(url: $0.url, notes: $0.notes) }
            return before - items.count
        }
        func count(_ calendarID: String) -> Int { items.filter { $0.calendarID == calendarID }.count }
        func titles(_ calendarID: String) -> [String] { items.filter { $0.calendarID == calendarID }.map(\.title).sorted() }
        func setGrant(_ value: Bool) { grant = value; level = .notDetermined }
    }
    private func foreign(calendarID: String, marked: Bool = false) -> Fake.Stored {
        Fake.Stored(identifier: "foreign-" + calendarID + (marked ? "-m" : ""), calendarID: calendarID, title: "Dentist", start: now.addingTimeInterval(86400), end: now.addingTimeInterval(90000),
                    url: marked ? CalendarBlocks.markerURL(for: "elsewhere") : nil, notes: marked ? CalendarBlocks.marker(for: "elsewhere") : "Bring forms", created: .distantPast)
    }

    func testSyncIsIdempotentAndNeverTouchesOtherEvents() async throws {
        let store = Fake()
        await store.seed(foreign(calendarID: "taskfold")); await store.seed(foreign(calendarID: "work", marked: true))
        let tasks = [task("a"), task("b", title: "Plan trip", time: "13:00")]
        let first = try await CalendarBlockSync.run(tasks: tasks, store: store, calendarID: "taskfold", mapping: [:], now: now, calendar: calendar)
        XCTAssertEqual(first.created, 2)
        let writes = await store.writes
        let second = try await CalendarBlockSync.run(tasks: tasks, store: store, calendarID: "taskfold", mapping: first.mapping, now: now, calendar: calendar)
        XCTAssertEqual([second.created, second.updated, second.deleted], [0, 0, 0])
        let writesAfter = await store.writes, titles = await store.titles("taskfold"), work = await store.count("work")
        XCTAssertEqual(writes, writesAfter)
        XCTAssertEqual(titles, ["Dentist", "Plan trip", "Write report"])
        XCTAssertEqual(work, 1)
    }

    func testTwoDevicesWithoutMappingsDoNotDuplicateAndConverge() async throws {
        let store = Fake()
        let tasks = [task("a")]
        _ = try await CalendarBlockSync.run(tasks: tasks, store: store, calendarID: "taskfold", mapping: [:], now: now, calendar: calendar)
        let second = try await CalendarBlockSync.run(tasks: tasks, store: store, calendarID: "taskfold", mapping: [:], now: now, calendar: calendar)
        XCTAssertEqual(second.created, 0)
        // Simulate a race that wrote the same block twice, then let each device clean up.
        let window = CalendarBlocks.window(now: now, calendar: calendar)
        let desired = CalendarBlocks.blocks(from: tasks, window: window, calendar: calendar)
        _ = try await store.apply(CalendarBlocks.Plan(creates: desired), calendarID: "taskfold")
        let before = await store.count("taskfold")
        XCTAssertEqual(before, 2)
        _ = try await CalendarBlockSync.run(tasks: tasks, store: store, calendarID: "taskfold", mapping: [:], now: now, calendar: calendar)
        let after = await store.count("taskfold")
        XCTAssertEqual(after, 1)
        let again = try await CalendarBlockSync.run(tasks: tasks, store: store, calendarID: "taskfold", mapping: [:], now: now, calendar: calendar)
        XCTAssertEqual([again.created, again.updated, again.deleted], [0, 0, 0])
    }

    func testCompletedDeletedAndMovedAwayTasksLoseTheirEvent() async throws {
        let store = Fake()
        var tasks = [task("a"), task("b"), task("c"), task("d", day: "2026-11-20")]
        var outcome = try await CalendarBlockSync.run(tasks: tasks, store: store, calendarID: "taskfold", mapping: [:], now: now, calendar: calendar)
        XCTAssertEqual(outcome.created, 4)
        tasks[0] = task("a", completed: true)                  // completed
        tasks.remove(at: 1)                                    // deleted
        tasks[1] = task("c", day: "2026-12-30")                // moved beyond the window
        tasks[2] = task("d", day: "2026-11-20", time: "15:00") // rescheduled
        outcome = try await CalendarBlockSync.run(tasks: tasks, store: store, calendarID: "taskfold", mapping: outcome.mapping, now: now, calendar: calendar)
        XCTAssertEqual([outcome.created, outcome.updated, outcome.deleted], [0, 1, 3])
        let count = await store.count("taskfold")
        XCTAssertEqual(count, 1)
    }

    // MARK: Controller

    @MainActor func testOffByDefaultAndAccessIsRequestedOnlyWhenSwitchedOn() async throws {
        let name = "calendar-blocks-" + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = Fake(); await store.setGrant(true)
        let controller = CalendarBlocksController(store: store, defaults: defaults)
        controller.bind(account: "owner")
        await controller.sync(tasks: [task("a")], now: now, calendar: calendar)
        var requests = await store.accessRequests, writes = await store.writes
        XCTAssertFalse(controller.active); XCTAssertEqual(requests, 0); XCTAssertEqual(writes, 0)
        await controller.enable()
        requests = await store.accessRequests
        XCTAssertEqual(requests, 1); XCTAssertTrue(controller.active)
        await controller.sync(tasks: [task("a")], now: now, calendar: calendar)
        let count = await store.count("taskfold")
        XCTAssertEqual(count, 1)
        // A fresh controller on the same defaults restores the choice, and another account does not inherit it.
        let restored = CalendarBlocksController(store: store, defaults: defaults); restored.bind(account: "owner"); XCTAssertTrue(restored.active)
        let other = CalendarBlocksController(store: store, defaults: defaults); other.bind(account: "someone-else"); XCTAssertFalse(other.active)
    }

    @MainActor func testDeniedAccessLeavesItOffAndTurningOffCanRemoveEvents() async throws {
        let name = "calendar-blocks-" + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let denied = Fake(); await denied.setGrant(false)
        let refused = CalendarBlocksController(store: denied, defaults: defaults); refused.bind(account: "owner")
        await refused.enable()
        XCTAssertFalse(refused.active); XCTAssertFalse(refused.status.isEmpty)
        let store = Fake(); await store.seed(foreign(calendarID: "taskfold"))
        let controller = CalendarBlocksController(store: store, defaults: defaults); controller.bind(account: "owner")
        await controller.enable(); await controller.sync(tasks: [task("a"), task("b")], now: now, calendar: calendar)
        var count = await store.count("taskfold")
        XCTAssertEqual(count, 3)
        await controller.disable(removeEvents: false)
        count = await store.count("taskfold")
        XCTAssertFalse(controller.active); XCTAssertEqual(count, 3)
        await controller.sync(tasks: [], now: now, calendar: calendar)
        count = await store.count("taskfold")
        XCTAssertEqual(count, 3)
        await controller.enable(); await controller.sync(tasks: [task("a"), task("b")], now: now, calendar: calendar)
        await controller.disable(removeEvents: true)
        let titles = await store.titles("taskfold")
        XCTAssertEqual(titles, ["Dentist"])
    }

    @MainActor func testChoosingAnotherCalendarMovesTheBlocks() async throws {
        let name = "calendar-blocks-" + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = Fake()
        let controller = CalendarBlocksController(store: store, defaults: defaults); controller.bind(account: "owner")
        await controller.enable(); await controller.sync(tasks: [task("a")], now: now, calendar: calendar)
        await controller.chooseCalendar("work")
        await controller.sync(tasks: [task("a")], now: now, calendar: calendar)
        let taskfold = await store.count("taskfold"), work = await store.count("work")
        XCTAssertEqual([taskfold, work], [0, 1])
    }
}
