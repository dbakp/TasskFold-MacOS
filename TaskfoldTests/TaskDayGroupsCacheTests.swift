import XCTest
@testable import TaskfoldCore

final class TaskDayGroupsCacheTests: XCTestCase {
    private let day = "2026-11-08"
    private let source = UUID(), access = UUID(), session = UUID(), generation = UUID()
    private func calendar(_ zone: String = "Europe/Copenhagen", id: Calendar.Identifier = .gregorian) -> Calendar { var c = Calendar(identifier: id); c.timeZone = TimeZone(identifier: zone)!; return c }
    private func context(source: UUID? = nil, access: UUID? = nil, session: UUID? = nil, account: String = "owner", generation: UUID? = nil, origin: String? = "https://example.invalid", readable: Bool = true) -> TaskDayGroupsReadCache.Context {
        .init(source: source ?? self.source, access: access ?? self.access, session: session ?? self.session, workspace: .init(account: account, generation: generation ?? self.generation), origin: origin, readable: readable)
    }
    private func row(_ id: String, day: String = "2026-11-08", done: Bool = false) -> Record {
        Record(["id": .string(id), "title": .string("Task " + id), "due_date": .string(day), "completed": .bool(done), "priority": .number(4)])
    }
    private func clock(_ zone: String = "Europe/Copenhagen", date: String = "2026-11-08T10:00:00Z") -> TaskCalendarContext {
        .init(now: TaskPlanning.instant(date)!, timeZone: TimeZone(identifier: zone)!)
    }
    private func equal(_ a: TaskDayGroupsRead, _ b: TaskDayGroupsRead, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.today, b.today, file: file, line: line)
        XCTAssertTrue(AuthoredValueComparison.sameRows(a.overdue, b.overdue), file: file, line: line)
        XCTAssertEqual(Set(a.rowsByDay.keys), Set(b.rowsByDay.keys), file: file, line: line)
        for (key, value) in a.rowsByDay { XCTAssertTrue(AuthoredValueComparison.sameRows(value, b.rowsByDay[key] ?? []), file: file, line: line) }
    }
    func testAlternatingDatedQueriesReuseCurrentRowsWithoutCallingProducer() {
        let cache = TaskDayGroupsReadCache(), rows = [row("a"), row("b", day: "2026-11-07")]
        var reads = 0
        for _ in 0..<10 { for scope in [TaskScope.today, .upcoming] {
            let value = cache.read(query: .init(scope: scope), clock: clock(), today: day, calendar: calendar(), context: context()) { reads += 1; return rows }
            equal(value, TaskDayGroupsRead(tasks: rows, today: day, calendar: calendar()))
        } }
        XCTAssertEqual(reads, 2); XCTAssertEqual(cache.computationCount, 2); XCTAssertEqual(cache.retainedEntryCount, 2)
    }
    func testSourceAccountAccessSessionGenerationOriginAndUnreadableReturnInvalidate() {
        let cache = TaskDayGroupsReadCache(), old = [row("old")], fresh = [row("fresh", day: "2026-11-09")]
        let contexts = [context(), context(source: UUID()), context(access: UUID()), context(session: UUID()), context(account: "other"), context(generation: UUID()), context(origin: "https://other.invalid")]
        for c in contexts {
            let rows = c == contexts[0] ? old : fresh
            let value = cache.read(query: .init(scope: .upcoming), clock: clock(), today: day, calendar: calendar(), context: c) { rows }
            equal(value, TaskDayGroupsRead(tasks: rows, today: day, calendar: calendar()))
            XCTAssertEqual(cache.retainedEntryCount, 1)
        }
        var called = false
        let hidden = cache.read(query: .init(scope: .upcoming), clock: clock(), today: day, calendar: calendar(), context: context(readable: false)) { called = true; return old }
        XCTAssertFalse(called); XCTAssertTrue(hidden.rowsByDay.isEmpty); XCTAssertEqual(cache.retainedEntryCount, 0)
        let returned = cache.read(query: .init(scope: .upcoming), clock: clock(), today: day, calendar: calendar(), context: context()) { fresh }
        equal(returned, TaskDayGroupsRead(tasks: fresh, today: day, calendar: calendar()))
        cache.clear(); XCTAssertEqual(cache.retainedEntryCount, 0)
    }
    func testSearchSortCompletionPrioritySelectedDateAndClockInvalidate() {
        let cache = TaskDayGroupsReadCache(); var count = 0
        let variants = [TaskQuery(scope: .today), .init(scope: .today, text: "review"), .init(scope: .today, includeCompleted: true), .init(scope: .today, priority: 1), .init(scope: .today, sort: "title"), .init(scope: .upcoming, selectedDay: "2026-11-09")]
        for q in variants { _ = cache.read(query: q, clock: clock(), today: day, calendar: calendar(), context: context()) { count += 1; return [row(String(count))] } }
        XCTAssertEqual(count, variants.count)
        for c in [clock(date: "2026-11-08T10:01:00Z"), clock(date: "2026-11-09T10:00:00Z"), clock("America/New_York")] {
            _ = cache.read(query: .init(scope: .today), clock: c, today: c.today, calendar: calendar(), context: context()) { count += 1; return [] }
        }
        XCTAssertEqual(count, variants.count + 3)
    }
    func testOrdinaryDatedReadsIgnoreMinuteTicksButRefreshDayAndZone() {
        let cache = TaskDayGroupsReadCache(); var produced = 0
        for minute in 0..<59 {
            let tick = clock(date: String(format: "2026-11-08T10:%02d:00Z", minute))
            for scope in [TaskScope.today, .upcoming] {
                let read = cache.read(query: .init(scope: scope), clock: tick, today: day, calendar: calendar(), context: context()) { produced += 1; return [row("current")] }
                XCTAssertEqual(read.rowsByDay[day]?.first?.id, "current")
            }
        }
        XCTAssertEqual(produced, 2)
        for tick in [clock(date: "2026-11-09T10:00:00Z"), clock("America/New_York", date: "2026-11-09T10:00:00Z")] {
            _ = cache.read(query: .init(scope: .today), clock: tick, today: tick.today, calendar: calendar(), context: context()) { produced += 1; return [row("fresh")] }
        }
        XCTAssertEqual(produced, 4)
    }
    func testClockWindowAndOpaqueSavedFiltersStillRefreshOnMinuteTicks() {
        for query in [TaskQuery(scope: .upcoming, filter: .predicate("planned_before", "+5 minutes")), TaskQuery(scope: .saved("existing-view"))] {
            let cache = TaskDayGroupsReadCache(); var produced = 0
            for minute in 0..<3 {
                let tick = clock(date: String(format: "2026-11-08T10:%02d:00Z", minute))
                let read = cache.read(query: query, clock: tick, today: day, calendar: calendar(), context: context()) { produced += 1; return [row("minute-\(minute)")] }
                XCTAssertEqual(read.rowsByDay[day]?.first?.id, "minute-\(minute)")
            }
            XCTAssertEqual(produced, 3)
        }
    }
    func testCalendarTravelDSTDuplicateAndOpaqueValuesMatchUncachedReader() throws {
        var timed = row("fixed"); timed["due_time"] = .string("23:30"); timed["time_zone"] = .string("UTC"); timed["scheduled_at"] = .string("2026-11-08T23:30:00Z")
        timed["future"] = try TaskfoldJSONDecoder().decode(JSON.self, from: Data("9007199254740993".utf8))
        let rows = [timed, row("dup", day: "2026-11-07"), row("dup", day: "2026-11-07"), row("done", done: true), row("bad", day: "invalid"), row("none", day: "")]
        let cache = TaskDayGroupsReadCache()
        for zone in ["Europe/Copenhagen", "America/New_York", "Australia/Lord_Howe", "Pacific/Apia"] { for id in [Calendar.Identifier.gregorian, .japanese, .buddhist] {
            let c = calendar(zone, id: id)
            for current in ["2026-10-25", day, "2026-11-09"] {
                let read = cache.read(query: .init(scope: .upcoming), clock: clock(), today: current, calendar: c, context: context()) { rows }
                equal(read, TaskDayGroupsRead(tasks: rows, today: current, calendar: c))
                XCTAssertEqual(read.upcomingDays(adding: [current, "2099-01-01"]), TaskDayGroupsRead(tasks: rows, today: current, calendar: c).upcomingDays(adding: [current, "2099-01-01"]))
            }
        } }
    }
    func testFourEntryLRUBoundAndProducerLaziness() {
        let cache = TaskDayGroupsReadCache(); var count = 0
        func read(_ text: String) { _ = cache.read(query: .init(scope: .upcoming, text: text), clock: clock(), today: day, calendar: calendar(), context: context()) { count += 1; return [row(text)] } }
        for i in 0..<4 { read(String(i)) }; read("0"); read("4"); read("0")
        XCTAssertEqual(count, 5); XCTAssertEqual(cache.retainedEntryCount, 4)
        read("1"); XCTAssertEqual(count, 6); XCTAssertEqual(cache.retainedEntryCount, 4)
    }
    func testEditedCompletionDatesNotesAndHeadingChildrenReplaceOldRead() {
        let cache = TaskDayGroupsReadCache(); var heading = row("h"); heading["is_heading"] = .bool(true)
        heading["subtasks"] = .array([.object(row("child").fields)])
        let original = ProductiveTaskReading(tasks: [heading]).presentation
        let first = cache.read(query: .init(scope: .upcoming), clock: clock(), today: day, calendar: calendar(), context: context()) { original }
        heading["subtasks"] = .array([.object(["id": .string("child"), "title": .string("Edited"), "due_date": .string("2026-11-09"), "completed": .bool(true), "description": .string("Full new notes")])])
        let changed = ProductiveTaskReading(tasks: [heading]).presentation
        let second = cache.read(query: .init(scope: .upcoming), clock: clock(), today: day, calendar: calendar(), context: context(source: UUID())) { changed }
        equal(second, TaskDayGroupsRead(tasks: changed, today: day, calendar: calendar()))
        equal(first, TaskDayGroupsRead(tasks: original, today: day, calendar: calendar()))
    }
    func testRepeatedTimedWorkloadDiagnostic() throws {
        let rows = (0..<500).map { i -> Record in
            var r = row("r\(i)", day: String(format: "2026-11-%02d", 8 + i % 14)); r["due_time"] = .string("09:30"); r["time_zone"] = .string("UTC"); r["scheduled_at"] = .string(String(format: "2026-11-%02dT09:30:00Z", 8 + i % 14)); return r
        }
        let cache = TaskDayGroupsReadCache(), c = calendar(), q = TaskQuery(scope: .upcoming), ct = context(), clk = clock()
        let timer = ContinuousClock(), start = timer.now; var expected: TaskDayGroupsRead?
        for _ in 0..<12 { expected = TaskDayGroupsRead(tasks: rows, today: day, calendar: c) }
        let old = start.duration(to: timer.now), next = timer.now
        for _ in 0..<12 { equal(cache.read(query: q, clock: clk, today: day, calendar: c, context: ct) { rows }, expected!) }
        let current = next.duration(to: timer.now)
        func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
        XCTAssertEqual(cache.computationCount, 1)
        print("DATED_GROUP_CACHE_DIAGNOSTIC " + String(decoding: try JSONSerialization.data(withJSONObject: ["rows": 500, "reads": 12, "uncachedSeconds": seconds(old), "cachedWithEqualityChecksSeconds": seconds(current), "computations": cache.computationCount], options: .sortedKeys), as: UTF8.self))
    }
}
