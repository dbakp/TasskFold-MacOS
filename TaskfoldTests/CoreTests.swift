import XCTest
@testable import TaskfoldCore

final class CoreTests: XCTestCase {
    func recurring(_ date: String, _ pattern: [String: JSON]) -> Record {
        Record(["due_date": .string(date), "is_recurring": .bool(true), "recurrence_pattern": .object(pattern)])
    }
    func testMonthlyClampsToShortMonth() {
        let task = recurring("2026-01-31", ["type": .string("monthly"), "interval": .number(1), "dayOfMonth": .number(31)])
        XCTAssertEqual(Dates.next(task).map(Dates.day), "2026-02-28")
    }
    func testWeeklySelectedDaysAndInterval() {
        let pattern: [String: JSON] = ["type": .string("weekly"), "interval": .number(2), "daysOfWeek": .array([.number(1), .number(3)])]
        XCTAssertEqual(Dates.next(recurring("2026-09-07", pattern)).map(Dates.day), "2026-09-09")
        XCTAssertEqual(Dates.next(recurring("2026-09-09", pattern)).map(Dates.day), "2026-09-21")
    }
    func testRecurrenceStopsAtEndDateAndCount() {
        XCTAssertNil(Dates.next(recurring("2026-09-05", ["type": .string("daily"), "interval": .number(1), "endDate": .string("2026-09-05")])))
        XCTAssertNil(Dates.next(recurring("2026-09-05", ["type": .string("daily"), "interval": .number(1), "count": .number(1)])))
    }
    func testOfflinePatchPreservesUnrelatedRemoteEdits() {
        var snapshot = Snapshot(tables: ["tasks": [Record(["id": .string("one"), "title": .string("Old"), "description": .string("Old notes")])]])
        let mutation = Mutation(table: "tasks", recordID: "one", method: "PATCH", fields: ["title": .string("Offline title")])
        snapshot.pending = [mutation]
        snapshot.mergeRemote(["tasks": [Record(["id": .string("one"), "title": .string("Old"), "description": .string("Remote notes")])]])
        XCTAssertEqual(snapshot.tables["tasks"]?.first?.title, "Offline title")
        XCTAssertEqual(snapshot.tables["tasks"]?.first?.string("description"), "Remote notes")
    }
    func testPendingDeleteDoesNotResurrectOnRefresh() {
        var snapshot = Snapshot(pending: [Mutation(table: "tasks", recordID: "one", method: "DELETE", fields: [:])])
        snapshot.mergeRemote(["tasks": [Record(["id": .string("one")])]])
        XCTAssertEqual(snapshot.tables["tasks"], [])
    }
    func testPendingCreateSurvivesRefresh() {
        let mutation = Mutation(table: "tasks", recordID: "one", method: "POST", fields: ["id": .string("one"), "title": .string("New task")])
        var snapshot = Snapshot(pending: [mutation]); snapshot.mergeRemote(["tasks": []])
        XCTAssertEqual(snapshot.tables["tasks"]?.first?.title, "New task")
    }
    func testLosslessBackendRoundTrip() throws {
        let data = Data(#"{"id":"one","due_date":null,"completed":false,"priority":1,"comments":[{"id":"comment","text":"Hello","attachment":{"url":"data:image/png;base64,AA=="}}],"future_field":{"enabled":true}}"#.utf8)
        let row = try JSONDecoder().decode(Record.self, from: data)
        let encoded = try JSONEncoder().encode(row)
        XCTAssertEqual(try JSONDecoder().decode(Record.self, from: encoded), row)
        XCTAssertEqual(row["future_field"].object["enabled"], .bool(true))
    }
    func testQueueSurvivesDiskEncoding() throws {
        let snapshot = Snapshot(pending: [Mutation(table: "tasks", recordID: "one", method: "PATCH", fields: ["due_date": .null])])
        let restored = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored, snapshot)
    }
    func testQuickEntryExtractsAndCleansTitle() {
        let now = Dates.parse("2026-09-05")!
        let parsed = QuickEntry("Buy milk tomorrow at 4pm p2 #errands", now: now)
        XCTAssertEqual(parsed.title, "Buy milk")
        XCTAssertEqual(parsed.updates["due_date"], .string("2026-09-06"))
        XCTAssertEqual(parsed.updates["due_time"], .string("16:00"))
        XCTAssertEqual(parsed.updates["priority"], .number(2))
        XCTAssertEqual(parsed.updates["labels"], .array([.string("errands")]))
    }
    func testQuickEntryDottedTimeAndDeclinedGroups() {
        let now = Dates.parse("2026-09-05")!
        let parsed = QuickEntry("Call mom tomorrow at 20.51", now: now)
        XCTAssertEqual(parsed.title, "Call mom")
        XCTAssertEqual(parsed.updates["due_date"], .string("2026-09-06"))
        XCTAssertEqual(parsed.updates["due_time"], .string("20:51"))
        XCTAssertEqual(parsed.tokens.map(\.group), ["due_time", "due_date"])
        // Declining the date keeps "tomorrow" in the name and defaults the time to today.
        let keptDate = QuickEntry("Call mom tomorrow at 20.51", now: now, disabled: ["due_date"])
        XCTAssertEqual(keptDate.title, "Call mom tomorrow")
        XCTAssertEqual(keptDate.updates["due_date"], .string("2026-09-05"))
        XCTAssertEqual(keptDate.updates["due_time"], .string("20:51"))
        // Declining the time keeps it in the name and leaves no dangling "at".
        let keptTime = QuickEntry("Call mom tomorrow at 20.51", now: now, disabled: ["due_time"])
        XCTAssertEqual(keptTime.title, "Call mom at 20.51")
        XCTAssertNil(keptTime.updates["due_time"])
        XCTAssertEqual(keptTime.updates["due_date"], .string("2026-09-06"))
        let nothing = QuickEntry("Call mom tomorrow at 20.51", now: now, disabled: Set(QuickEntry.groups))
        XCTAssertEqual(nothing.title, "Call mom tomorrow at 20.51")
        XCTAssertFalse(nothing.hasSuggestions)
    }
    func testQuickEntryRecurringWeekday() {
        let parsed = QuickEntry("Review every monday", now: Dates.parse("2026-09-05")!)
        XCTAssertEqual(parsed.title, "Review")
        XCTAssertEqual(parsed.updates["due_date"], .string("2026-09-07"))
        XCTAssertEqual(parsed.updates["is_recurring"], .bool(true))
    }

    func testUndoPreservesUnrelatedRemoteChanges() {
        var snapshot = Snapshot(tables: ["tasks": [Record(["id": .string("one"), "title": .string("Original"), "description": .string("Original notes")])]])
        let change = Mutation(table: "tasks", recordID: "one", method: "PATCH", fields: ["title": .string("Edited")])
        let history = EditHistory(changes: [change], snapshot: snapshot)
        snapshot.apply(change)
        snapshot.apply(Mutation(table: "tasks", recordID: "one", method: "PATCH", fields: ["description": .string("Remote notes")]))
        snapshot.apply(Mutation(table: "tasks", recordID: "two", method: "POST", fields: ["id": .string("two"), "title": .string("Remote task")]))
        for inverse in history.undo { snapshot.apply(inverse) }
        XCTAssertEqual(snapshot.tables["tasks"]?.first?.title, "Original")
        XCTAssertEqual(snapshot.tables["tasks"]?.first?.string("description"), "Remote notes")
        XCTAssertEqual(snapshot.tables["tasks"]?.count, 2)
    }
    func testUndoDeletionRestoresDependenciesFirst() {
        let snapshot = Snapshot(tables: ["projects": [Record(["id": .string("project")])], "sections": [Record(["id": .string("section"), "project_id": .string("project")])]])
        let history = EditHistory(changes: [Mutation(table: "sections", recordID: "section", method: "DELETE", fields: [:]), Mutation(table: "projects", recordID: "project", method: "DELETE", fields: [:])], snapshot: snapshot)
        XCTAssertEqual(history.undo.map(\.table), ["projects", "sections"])
        XCTAssertEqual(history.undo.map(\.method), ["POST", "POST"])
    }

}
