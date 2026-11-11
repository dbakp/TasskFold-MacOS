import XCTest
@testable import TaskfoldCore

/// This Evening and Someday (Core/Planning.swift): expiry, zones, pruning, parser tokens, limits and compatibility.
final class EveningSomedayTests: XCTestCase {
    let account = "owner"
    func cal(_ zone: String = "Europe/Copenhagen") -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; return c }
    func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    func task(_ id: String, due: String? = nil, completed: Bool = false, created: String = "2026-10-01T09:00:00Z", extra: [String: JSON] = [:]) -> Record {
        var row = Record.task(user: account, createdAt: created)
        row["id"] = .string(id); row["title"] = .string("Task " + id); row["completed"] = .bool(completed)
        row["due_date"] = due.map(JSON.string) ?? .null
        for (key, value) in extra { row[key] = value }
        return row
    }
    func order(_ key: String, _ ids: [String], user: String = "owner", extra: [String: JSON] = [:]) -> Record {
        var fields: [String: JSON] = ["id": .string(key), "user_id": .string(user), "ids": .array(ids.map(JSON.string))]
        for (name, value) in extra { fields[name] = value }
        return Record(fields)
    }
    func apply(_ changes: [Mutation], to snapshot: Snapshot) -> Snapshot { var copy = snapshot; for change in changes { copy.apply(change) }; return copy }
    func ids(_ snapshot: Snapshot, _ key: String) -> [String]? { snapshot.tables["view_orders"]?.first { $0.id == key }.map { $0["ids"].list.map(\.text) } }

    // MARK: Expiry and zones

    func testEveningIsValidOnlyForItsDayAndExpiresAtMidnight() {
        let rows = [order("planning:evening:2026-10-07", ["a", "b"])]
        let calendar = cal()
        let lastSecond = Planning.day(date("2026-10-07T21:59:59Z"), calendar: calendar)   // 23:59:59 Copenhagen
        let midnight = Planning.day(date("2026-10-07T22:00:00Z"), calendar: calendar)     // 00:00:00 next day
        XCTAssertEqual(lastSecond, "2026-10-07"); XCTAssertEqual(midnight, "2026-10-08")
        XCTAssertEqual(Planning.state(rows: rows, account: account, today: lastSecond).evening, ["a", "b"])
        let next = Planning.state(rows: rows, account: account, today: midnight)
        XCTAssertEqual(next.evening, []); XCTAssertEqual(next.expiredEveningKeys, ["planning:evening:2026-10-07"])
    }
    func testExpiredEveningTaskShowsInTodayOrOverdueAsUsualWithNoRescheduling() {
        let state = Planning.state(rows: [order("planning:evening:2026-10-07", ["a"])], account: account, today: "2026-10-08")
        let rows = [task("a", due: "2026-10-07"), task("b", due: "2026-10-08")]
        let split = Planning.partition(rows, state: state)
        XCTAssertEqual(split.regular.map(\.id), ["a", "b"]); XCTAssertTrue(split.evening.isEmpty)
        XCTAssertEqual(rows[0].string("due_date"), "2026-10-07")
    }
    func testDayFollowsTheCalendarZoneForTheSameInstant() {
        let instant = date("2026-10-07T12:30:00Z")
        XCTAssertEqual(Planning.day(instant, calendar: cal("Pacific/Auckland")), "2026-10-08")
        XCTAssertEqual(Planning.day(instant, calendar: cal("America/Los_Angeles")), "2026-10-07")
        let rows = [order("planning:evening:2026-10-08", ["a"])]
        XCTAssertEqual(Planning.state(rows: rows, account: account, today: Planning.day(instant, calendar: cal("Pacific/Auckland"))).evening, ["a"])
        XCTAssertEqual(Planning.state(rows: rows, account: account, today: Planning.day(instant, calendar: cal("America/Los_Angeles"))).evening, [])
    }
    func testDaylightSavingDaysRolloverOnTheCivilDay() {
        let calendar = cal()
        XCTAssertEqual(Planning.day(date("2026-03-28T22:59:59Z"), calendar: calendar), "2026-03-28")   // 23:59:59 CET
        XCTAssertEqual(Planning.day(date("2026-03-28T23:00:00Z"), calendar: calendar), "2026-03-29")   // 23-hour day starts
        XCTAssertEqual(Planning.day(date("2026-03-29T21:59:59Z"), calendar: calendar), "2026-03-29")
        XCTAssertEqual(Planning.day(date("2026-03-29T22:00:00Z"), calendar: calendar), "2026-03-30")
        XCTAssertEqual(Planning.day(date("2026-10-25T22:59:59Z"), calendar: calendar), "2026-10-25")   // 25-hour day
        XCTAssertEqual(Planning.day(date("2026-10-25T23:00:00Z"), calendar: calendar), "2026-10-26")
    }
    func testWritingRemovesExpiredRowsButKeepsUnknownAndForeignKeys() throws {
        let rows = [order("planning:evening:2026-10-06", ["x"]), order("planning:evening:2026-10-07", ["a"], user: "someone-else"),
                    order("planning:future-thing", ["q"]), order("planning:evening:not-a-day", ["z"]), order("planning:evening:2026-10-08", ["a"])]
        let tasks = [task("a", due: "2026-10-08")]
        let changes = try Planning.moveToEvening(["a"], tasks: tasks, rows: rows, account: account, today: "2026-10-08")
        XCTAssertEqual(changes.filter { $0.method == "DELETE" }.map(\.recordID), ["planning:evening:2026-10-06"])
        XCTAssertFalse(changes.contains { ["planning:future-thing", "planning:evening:not-a-day", "planning:evening:2026-10-07"].contains($0.recordID) })
    }

    // MARK: Moving, ordering, pruning

    func testMovingToEveningKeepsTheDueDateAndOrdersManually() throws {
        let tasks = [task("a", due: "2026-10-08"), task("b", due: "2026-10-07"), task("c", due: "2026-10-08")]
        var snapshot = Snapshot(tables: ["tasks": tasks])
        snapshot = apply(try Planning.moveToEvening(["a", "b"], tasks: tasks, rows: [], account: account, today: "2026-10-08"), to: snapshot)
        XCTAssertEqual(ids(snapshot, "planning:evening:2026-10-08"), ["a", "b"])
        snapshot = apply(try Planning.moveToEvening(["c"], before: "a", tasks: tasks, rows: snapshot.tables["view_orders"] ?? [], account: account, today: "2026-10-08"), to: snapshot)
        XCTAssertEqual(ids(snapshot, "planning:evening:2026-10-08"), ["c", "a", "b"])
        snapshot = apply(try Planning.reorderEvening(["b", "c", "a"], tasks: tasks, rows: snapshot.tables["view_orders"] ?? [], account: account, today: "2026-10-08"), to: snapshot)
        XCTAssertEqual(ids(snapshot, "planning:evening:2026-10-08"), ["b", "c", "a"])
        XCTAssertEqual(snapshot.tables["tasks"]?.map { $0.string("due_date") }, ["2026-10-08", "2026-10-07", "2026-10-08"])
        let state = Planning.state(rows: snapshot.tables["view_orders"] ?? [], account: account, today: "2026-10-08")
        let split = Planning.partition(tasks, state: state)
        XCTAssertEqual(split.evening.map(\.id), ["b", "c", "a"]); XCTAssertTrue(split.regular.isEmpty)
    }
    func testOnlyOpenTasksDueTodayOrEarlierQualifyForEvening() {
        let tasks = [task("future", due: "2026-10-09"), task("undated"), task("done", due: "2026-10-08", completed: true),
                     task("heading", due: "2026-10-08", extra: ["is_heading": .bool(true)]), task(SubtaskTree.reference(parent: "a", key: "k"), due: "2026-10-08")]
        for id in ["future", "undated", "done", "heading", SubtaskTree.reference(parent: "a", key: "k")] {
            XCTAssertThrowsError(try Planning.moveToEvening([id], tasks: tasks, rows: [], account: account, today: "2026-10-08"), id)
        }
    }
    func testPruningDropsDeletedCompletedRescheduledAndDuplicateIDs() {
        let state = PlanningState(today: "2026-10-08", evening: ["a", "gone", "done", "later", "a"], someday: ["s", "dated", "gone"])
        let tasks = [task("a", due: "2026-10-08"), task("done", due: "2026-10-08", completed: true), task("later", due: "2026-10-12"),
                     task("s"), task("dated", due: "2026-10-09")]
        XCTAssertEqual(Planning.pruned(.evening, ids: state.evening, tasks: tasks, state: state), ["a"])
        XCTAssertEqual(Planning.pruned(.someday, ids: state.someday, tasks: tasks, state: state), ["s"])
    }
    func testWritesPersistThePrunedList() throws {
        let rows = [order("planning:evening:2026-10-08", ["gone", "a"])]
        let tasks = [task("a", due: "2026-10-08"), task("b", due: "2026-10-08")]
        let changes = try Planning.moveToEvening(["b"], tasks: tasks, rows: rows, account: account, today: "2026-10-08")
        XCTAssertEqual(changes.last?.fields["ids"], .array([.string("a"), .string("b")]))
        XCTAssertEqual(changes.last?.method, "PATCH")
    }

    // MARK: Someday

    func testMoveToSomedayClearsTheScheduleFilesTheTaskAndDropsEvening() throws {
        let tasks = [task("a", due: "2026-10-08", extra: ["due_time": .string("09:00")]), task("b", due: "2026-10-08")]
        let rows = [order("planning:evening:2026-10-08", ["a", "b"])]
        let changes = try Planning.moveToSomeday(["a"], tasks: tasks, rows: rows, account: account, today: "2026-10-08")
        var snapshot = Snapshot(tables: ["tasks": tasks, "view_orders": rows]); snapshot = apply(changes, to: snapshot)
        let moved = snapshot.tables["tasks"]!.first { $0.id == "a" }!
        XCTAssertEqual(moved["due_date"], .null); XCTAssertEqual(moved["due_time"], .null)
        XCTAssertEqual(ids(snapshot, "planning:someday"), ["a"]); XCTAssertEqual(ids(snapshot, "planning:evening:2026-10-08"), ["b"])
        let state = Planning.state(rows: snapshot.tables["view_orders"] ?? [], account: account, today: "2026-10-08")
        XCTAssertEqual(Planning.somedayTasks(snapshot.tables["tasks"] ?? [], state: state).map(\.id), ["a"])
        XCTAssertTrue(Planning.hides(moved, listed: Set(state.someday)))
        XCTAssertFalse(Planning.hides(snapshot.tables["tasks"]!.first { $0.id == "b" }!, listed: Set(state.someday)))
    }
    func testNewestSomedayFirstAndRepeatingTasksStayScheduled() throws {
        let tasks = [task("a", due: "2026-10-08"), task("b"), task("r", due: "2026-10-08", extra: ["is_recurring": .bool(true)])]
        let rows = [order("planning:someday", ["b"])]
        let changes = try Planning.moveToSomeday(["a", "r"], tasks: tasks, rows: rows, account: account, today: "2026-10-08")
        XCTAssertEqual(changes.last?.fields["ids"], .array([.string("a"), .string("b")]))
        XCTAssertFalse(changes.contains { $0.recordID == "r" })
        XCTAssertThrowsError(try Planning.moveToSomeday(["r"], tasks: tasks, rows: rows, account: account, today: "2026-10-08"))
    }
    func testSchedulingAnywhereReleasesSomedayEvenWithoutCleanup() {
        let state = PlanningState(today: "2026-10-08", someday: ["a", "b"])
        let tasks = [task("a", due: "2026-10-20"), task("b")]
        XCTAssertEqual(Planning.somedayTasks(tasks, state: state).map(\.id), ["b"])
        XCTAssertFalse(Planning.hides(tasks[0], listed: Set(state.someday)))
        let done = [task("b", completed: true)]
        XCTAssertTrue(Planning.somedayTasks(done, state: state).isEmpty)
    }
    func testRemovalAfterSchedulingWritesThePrunedList() throws {
        let tasks = [task("a"), task("b")]
        let rows = [order("planning:someday", ["a", "b"])]
        let changes = try Planning.removeFromSomeday(["a"], tasks: tasks, rows: rows, account: account, today: "2026-10-08")
        XCTAssertEqual(changes.first?.fields["ids"], .array([.string("b")]))
        XCTAssertTrue(try Planning.removeFromSomeday(["zzz"], tasks: tasks, rows: rows, account: account, today: "2026-10-08").isEmpty)
    }
    func testCompletedEveningTasksStillCountAsCompletedWork() {
        // Evening is only a list: completion is the ordinary task field, so history and streaks are untouched.
        let state = PlanningState(today: "2026-10-08", evening: ["a"])
        var row = task("a", due: "2026-10-08"); row["completed"] = .bool(true)
        XCTAssertFalse(Planning.isEvening(row, state: state))
        XCTAssertTrue(row.completed)
    }

    // MARK: Review

    func testReviewIsWeeklyAndOnlyForItemsOlderThanThirtyDays() {
        let now = date("2026-11-11T10:00:00Z")
        let old = task("old", created: "2026-09-01T09:00:00Z"), fresh = task("fresh", created: "2026-11-01T09:00:00Z")
        XCTAssertEqual(Planning.review([old, fresh], now: now, lastReviewed: nil)?.staleIDs, ["old"])
        XCTAssertNil(Planning.review([fresh], now: now, lastReviewed: nil))
        XCTAssertNil(Planning.review([old], now: now, lastReviewed: date("2026-11-06T10:00:00Z")))
        XCTAssertNotNil(Planning.review([old], now: now, lastReviewed: date("2026-11-04T09:59:00Z")))
        XCTAssertEqual(Planning.review([old], now: now, lastReviewed: nil)?.message, "1 idea has been here for over a month.")
    }

    // MARK: Limits

    func testThreeHundredSomedayTasksFitInOneRow() throws {
        let tasks = (0..<300).map { _ in task(UUID().uuidString.lowercased(), created: "2026-01-01T00:00:00Z") }
        var snapshot = Snapshot(tables: ["tasks": tasks]); var rows: [Record] = []
        for chunk in stride(from: 0, to: 300, by: 50) {
            let changes = try Planning.moveToSomeday(tasks[chunk..<chunk + 50].map { $0.id }, tasks: snapshot.tables["tasks"]!, rows: rows, account: account, today: "2026-10-08")
            snapshot = apply(changes, to: snapshot); rows = snapshot.tables["view_orders"] ?? []
        }
        XCTAssertEqual(ids(snapshot, "planning:someday")?.count, 300)
        let bytes = try TaskfoldJSONEncoder().encode(rows.first { $0.id == "planning:someday" }!["ids"]).count
        XCTAssertLessThan(bytes, 16 * 1024)
        XCTAssertGreaterThan(bytes, 4096, "this is why the 4,096-byte productivity_goals document cannot hold Someday")
    }
    func testAListBeyondTheServerLimitIsRefusedNotTruncated() {
        let many = (0..<Planning.maxIDs).map { "id\($0)" }
        let tasks = [task("new", due: "2026-10-08")] + many.map { task($0) }
        let rows = [order("planning:someday", many)]
        XCTAssertThrowsError(try Planning.moveToSomeday(["new"], tasks: tasks, rows: rows, account: account, today: "2026-10-08")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Someday is full"))
        }
        XCTAssertLessThanOrEqual(Planning.somedayKey.utf8.count, Planning.maxKeyBytes)
        XCTAssertLessThanOrEqual(Planning.eveningKey("2026-10-08").utf8.count, Planning.maxKeyBytes)
    }

    // MARK: Compatibility

    func testMutationsCarryOnlyTheOrderColumnsAndPreserveUnknownRowFields() throws {
        let rows = [order("planning:someday", ["b"], extra: ["future_field": .string("keep"), "updated_at": .string("2026-10-07T00:00:00Z")])]
        let tasks = [task("a", due: "2026-10-08"), task("b")]
        let changes = try Planning.moveToSomeday(["a"], tasks: tasks, rows: rows, account: account, today: "2026-10-08")
        let list = changes.last!
        XCTAssertEqual(Set(list.fields.keys), ["id", "user_id", "ids"]); XCTAssertEqual(list.table, "view_orders")
        var snapshot = Snapshot(tables: ["tasks": tasks, "view_orders": rows]); snapshot = apply(changes, to: snapshot)
        let row = snapshot.tables["view_orders"]!.first { $0.id == "planning:someday" }!
        XCTAssertEqual(row["future_field"], .string("keep")); XCTAssertEqual(row["updated_at"], .string("2026-10-07T00:00:00Z"))
        XCTAssertEqual(row["ids"].list.map(\.text), ["a", "b"])
    }
    func testOlderClientAndMalformedDocumentsReadSafely() {
        let rows = [Record(["id": .string("planning:someday"), "user_id": .string(account), "ids": .array([.string("a"), .number(5), .null, .string("a"), .string(""), .string("b")])]),
                    Record(["id": .string("planning:evening:2026-10-08"), "user_id": .string(account), "ids": .string("oops")]),
                    Record(["id": .string("planning:other"), "user_id": .string(account)])]
        let state = Planning.state(rows: rows, account: account, today: "2026-10-08")
        XCTAssertEqual(state.someday, ["a", "b"]); XCTAssertEqual(state.evening, [])
        XCTAssertEqual(Planning.state(rows: rows, account: "other", today: "2026-10-08").someday, [])
        XCTAssertEqual(Planning.state(rows: [], account: account, today: "2026-10-08"), PlanningState(today: "2026-10-08"))
    }
    func testAnotherAccountsRowIsNeverOverwritten() {
        let rows = [order("planning:someday", ["x"], user: "someone-else")]
        XCTAssertThrowsError(try Planning.moveToSomeday(["a"], tasks: [task("a", due: "2026-10-08")], rows: rows, account: account, today: "2026-10-08"))
        XCTAssertThrowsError(try Planning.moveToSomeday(["a"], tasks: [task("a", due: "2026-10-08")], rows: [], account: "", today: "2026-10-08"))
    }
    func testSomedayTasksAreHiddenFromWidgetPayloadsButTheRestRemain() throws {
        let tasks = [task("a"), task("b"), task("c", due: "2026-10-08")]
        let payload = WidgetProjection.payload(tasks: tasks, projects: [], account: account, now: date("2026-10-08T10:00:00Z"), calendar: cal("UTC"), viewOrders: [order("planning:someday", ["a"])])
        let shown = payload["tasks"]?.list.map { $0.object["id"]?.text ?? "" } ?? []
        XCTAssertFalse(shown.contains("a")); XCTAssertTrue(shown.contains("b")); XCTAssertTrue(shown.contains("c"))
    }

    // MARK: Quick Add tokens

    func entry(_ text: String, now: String = "2026-10-07T10:00:00Z", planning: Bool = true, disabled: Set<String> = [], task: Record = Record()) -> QuickEntry {
        var context = QuickEntryContext(); context.planning = planning
        return QuickEntry(text, now: date(now), calendar: cal(), disabled: disabled, context: context, task: task)
    }
    func testThisEveningSetsTodayAndEveningWithoutReadingItAsAClock() {
        let value = entry("Call Sam this evening p2")
        XCTAssertEqual(value.title, "Call Sam"); XCTAssertEqual(value.planning, .evening)
        XCTAssertEqual(value.updates["due_date"], .string("2026-10-07")); XCTAssertNil(value.updates["due_time"])
        XCTAssertEqual(value.updates["priority"], .number(2))
        XCTAssertEqual(value.tokens.first { $0.group == "planning" }?.label, "This Evening")
        XCTAssertEqual(entry("This Evening: pack the bag").planning, .evening)
        XCTAssertEqual(entry("Wrap gifts THIS  EVENING").title, "Wrap gifts")
    }
    func testSomedayClearsTheScheduleAndFilesTheTask() {
        let task = Record(["due_date": .string("2026-10-07")])
        let value = entry("Learn the cello someday", task: task)
        XCTAssertEqual(value.title, "Learn the cello"); XCTAssertEqual(value.planning, .someday)
        let applied = value.applying(to: task)
        XCTAssertEqual(applied["due_date"], .null); XCTAssertEqual(applied["due_time"], .null)
        XCTAssertEqual(value.tokens.first { $0.group == "planning" }?.label, "Someday")
    }
    func testPlanningTokensAreOptInDeclinableAndLiteralInQuotesAndEscapes() {
        // Off (or declined) the words fall back to their older meaning: "evening" is a 7 PM clock.
        let off = entry("Call Sam this evening", planning: false)
        XCTAssertNil(off.planning); XCTAssertNil(off.tokens.first { $0.group == "planning" }); XCTAssertEqual(off.updates["due_time"], .string("19:00"))
        let declined = entry("Call Sam this evening", disabled: ["planning"])
        XCTAssertNil(declined.planning); XCTAssertNil(declined.tokens.first { $0.group == "planning" }); XCTAssertEqual(declined.updates["due_time"], .string("19:00"))
        XCTAssertEqual(entry("Learn cello someday", disabled: ["planning"]).title, "Learn cello someday")
        for input in [#"Read "someday maybe""#, #"Read \someday"#, "Read https://site.test/someday", "Read somedays", "Read this eveningish"] {
            XCTAssertNil(entry(input).planning, input)
        }
        XCTAssertEqual(entry(#"Read \someday"#).title, "Read someday")
    }
    func testConflictingPlanningAndDateTokensStayInTheTitleWithAWarning() {
        let tomorrow = entry("Call Sam tomorrow this evening")
        XCTAssertNil(tomorrow.planning); XCTAssertEqual(tomorrow.updates["due_date"], .string("2026-10-08")); XCTAssertFalse(tomorrow.warnings.isEmpty)
        XCTAssertTrue(tomorrow.title.contains("this evening"))
        let both = entry("Call someday this evening")
        XCTAssertNil(both.planning); XCTAssertEqual(both.title, "Call someday this evening"); XCTAssertFalse(both.warnings.isEmpty)
        let dated = entry("Call Sam someday friday")
        XCTAssertNil(dated.planning); XCTAssertTrue(dated.title.contains("someday")); XCTAssertFalse(dated.warnings.isEmpty)
        let repeating = entry("Water plants someday every day")
        XCTAssertNil(repeating.planning)
    }
    func testBareEveningKeepsItsExistingClockMeaning() {
        let value = entry("Brief evening")
        XCTAssertNil(value.planning); XCTAssertEqual(value.updates["due_time"], .string("19:00"))
        let inEvening = entry("Brief tomorrow in the evening")
        XCTAssertNil(inEvening.planning); XCTAssertEqual(inEvening.updates["due_time"], .string("19:00"))
    }
    func testEveningFollowsTheCapturingCalendarsDay() {
        let tokyo = QuickEntry("Call Sam this evening", now: date("2026-10-07T22:30:00Z"), calendar: cal("Asia/Tokyo"), context: { var c = QuickEntryContext(); c.planning = true; return c }())
        XCTAssertEqual(tokyo.updates["due_date"], .string("2026-10-08"))
    }
    func testNewTaskIsFiledInTheSameCommitAsItsCreation() throws {
        let created = task("n", due: "2026-10-08")
        let evening = try Planning.filingNewTask(created, slot: .evening, tasks: [], rows: [], account: account, today: "2026-10-08")
        XCTAssertEqual(evening.last?.recordID, "planning:evening:2026-10-08"); XCTAssertEqual(evening.last?.fields["ids"], .array([.string("n")]))
        let undated = task("m")
        let someday = try Planning.filingNewTask(undated, slot: .someday, tasks: [task("old")], rows: [order("planning:someday", ["old"])], account: account, today: "2026-10-08")
        XCTAssertEqual(someday.last?.fields["ids"], .array([.string("m"), .string("old")]))
    }
}
