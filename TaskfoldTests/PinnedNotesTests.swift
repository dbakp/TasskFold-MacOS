import XCTest
@testable import TaskfoldCore
@testable import WidgetModel

final class PinnedNotesTests: XCTestCase {
    private let account = "11111111-1111-4111-8111-111111111111"
    private let other = "22222222-2222-4222-8222-222222222222"
    private let id = "33333333-3333-4333-8333-333333333333"
    private func task(_ id: String, text: String = "Instructions\nKeep all the details.", done: Bool = false) -> Record {
        var row = Record.task(user: account); row["id"] = .string(id); row["title"] = .string("Reference")
        row["description"] = .string(text); row["completed"] = .bool(done); return row
    }
    private func pin(_ id: String, user: String? = nil) -> Record {
        Record(["id": .string(PinnedNotes.key(id)), "user_id": .string(user ?? account), "ids": .array([.string(id)])])
    }
    private func snapshot(tasks: [Record], pins: [Record], account: String? = nil) throws -> WidgetSnapshot {
        try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(WidgetProjection.payload(tasks: tasks, projects: [], account: account ?? self.account, notePins: pins)))
    }
    func testOnlyExplicitlyPinnedDescriptionsLeaveAppIncludingCompletedTasks() throws {
        let tasks = [task(id, done: true), task("private", text: "private text"), task("second")]
        let projection = WidgetProjection.payload(tasks: tasks, projects: [], account: account, notePins: [pin(id)])
        let widget = try snapshot(tasks: tasks, pins: [pin(id)])
        XCTAssertEqual(widget.availableNotes.map(\.taskID), [id]); XCTAssertTrue(widget.availableNotes[0].completed)
        XCTAssertEqual(widget.availableNotes[0].text, tasks[0].string("description"))
        XCTAssertFalse(String(data: try JSONEncoder().encode(projection), encoding: .utf8)!.contains("private text"))
        XCTAssertFalse(projection["tasks"]!.list.contains { $0.object["description"] != nil })
    }
    func testDeletionUnpinForeignAndMalformedRegistryNeverFallBackToAnotherNote() throws {
        let rows = [task(id), task("second")], pins = [pin(id), pin("second")]
        let selected = try snapshot(tasks: rows, pins: pins).availableNotes.first { $0.taskID == id }!.id
        let missing = try snapshot(tasks: [rows[1]], pins: pins)
        XCTAssertEqual(missing.noteStatus(selected, at: Date()), .unavailable); XCTAssertNil(missing.note(selected))
        XCTAssertEqual(try snapshot(tasks: rows, pins: [pins[1]]).noteStatus(selected, at: Date()), .unavailable)
        XCTAssertTrue(try snapshot(tasks: rows, pins: pins, account: other).availableNotes.isEmpty)
        XCTAssertTrue(try snapshot(tasks: rows, pins: pins, account: "").availableNotes.isEmpty)
        var wrong = pin(id); wrong["ids"] = .array([.string("second")])
        XCTAssertFalse(PinnedNotes.contains(id, pins: [wrong, pin(id)], account: account))
        XCTAssertFalse(PinnedNotes.contains(id, pins: [pin(id, user: other)], account: account))
    }
    func testOldPublisherAndStaleSnapshotRequireRefreshButEmptyCatalogueOffersSelection() throws {
        var old = WidgetSnapshot(updated: Date().timeIntervalSinceReferenceDate, tasks: [], account: account)
        XCTAssertEqual(old.noteStatus(nil, at: Date()), .refresh)
        old.notes = []; XCTAssertEqual(old.noteStatus(nil, at: Date()), .choose)
        old.updated -= 86_401; XCTAssertEqual(old.noteStatus(nil, at: Date()), .refresh)
        old.updated = .infinity; XCTAssertEqual(old.noteStatus(nil, at: Date()), .refresh)
        let legacy = try JSONDecoder().decode(WidgetSnapshot.self, from: Data("{\"updated\":1,\"tasks\":[]}".utf8))
        XCTAssertNil(legacy.notes); XCTAssertEqual(legacy.noteStatus(nil, at: Date()), .refresh)
    }
    func testUnicodeNewlinesAndBothBoundsPreserveCanonicalFullText() throws {
        let text = String(repeating: "👩🏽‍💻 café\r\n", count: 1500)
        let row = task(id, text: text), widget = try snapshot(tasks: [row], pins: [pin(id)])
        let note = widget.availableNotes[0]
        XCTAssertLessThanOrEqual(note.text.count, 1200); XCTAssertLessThanOrEqual(note.text.utf8.count, 6000)
        XCTAssertTrue(note.truncated); XCTAssertFalse(note.text.contains("\r")); XCTAssertEqual(row.string("description"), text)
        let hugeGrapheme = "a" + String(repeating: "\u{301}", count: 8000)
        let huge = PinnedNotes.excerpt(hugeGrapheme, characters: 1200, bytes: 6000)
        XCTAssertEqual(huge.0, ""); XCTAssertTrue(huge.1)
        let blank = try snapshot(tasks: [task(id, text: "")], pins: [pin(id)])
        XCTAssertEqual(blank.availableNotes[0].text, ""); XCTAssertEqual(blank.noteStatus(blank.availableNotes[0].id, at: Date()), .ready)
    }
    func testIdentityBoundsDuplicatesRenameAndLiteralText() throws {
        var widget = try snapshot(tasks: [task(id, text: "[link](https://example.com) <script>literal</script>"), task("second")], pins: [pin(id), pin("second")])
        let note = widget.availableNotes.first { $0.taskID == id }!
        XCTAssertTrue(widget.noteSubtitle(note).contains(id))
        var renamed = note; renamed.title = "Renamed"; widget.notes = [renamed]
        XCTAssertEqual(widget.note(note.id)?.title, "Renamed")
        var foreign = note; foreign.id = try JSONEncoder().encode([other,"note",id]).base64EncodedString()
        widget.notes = [foreign, note]; XCTAssertTrue(widget.availableNotes.isEmpty)
        var malformed = note; malformed.text = String(repeating: "x", count: 1201)
        widget.notes = [malformed]; XCTAssertTrue(widget.availableNotes.isEmpty)
    }
    func testIndependentPinRowsAndUnpinDoNotModifyNotesOrOtherPins() throws {
        var state = Snapshot(tables: ["tasks": [task(id), task("second")]])
        let first = PinnedNotes.change(taskID: id, enabled: true, pins: [], account: account)!
        let second = PinnedNotes.change(taskID: "second", enabled: true, pins: [], account: account)!
        XCTAssertNotEqual(first.recordID, second.recordID)
        state.apply(first); state.apply(second)
        XCTAssertEqual(PinnedNotes.tasks(state.tables["tasks"]!, pins: state.tables["view_orders"]!, account: account).count, 2)
        let remove = PinnedNotes.change(taskID: id, enabled: false, pins: state.tables["view_orders"]!, account: account)!
        state.apply(remove)
        XCTAssertEqual(state.tables["tasks"]![0].string("description"), "Instructions\nKeep all the details.")
        XCTAssertTrue(PinnedNotes.contains("second", pins: state.tables["view_orders"]!, account: account))
        XCTAssertNil(PinnedNotes.change(taskID: "second", enabled: true, pins: state.tables["view_orders"]!, account: account))
    }
    func testTaskEditKeepsConcurrentUntouchedFieldsAndCompletionBaseline() {
        var old = task(id); old["completion_version"] = .number(6)
        var current = old; current["duration_minutes"] = .number(45)
        var edited = old; edited["description"] = .string("Edited text")
        let mutation = PinnedNotes.edit(edited, existing: current, baseline: old)!
        XCTAssertEqual(mutation.fields, ["description": .string("Edited text")])
        var state = Snapshot(tables: ["tasks": [current]]); state.apply(mutation)
        XCTAssertEqual(state.tables["tasks"]![0]["duration_minutes"], .number(45))
        XCTAssertEqual(state.tables["tasks"]![0]["completion_version"], .number(6))
        XCTAssertNil(PinnedNotes.edit(current, existing: current, baseline: nil))
    }
    func testForeignBackupRemapsPinKeyAndReferenceTogether() throws {
        var state = Snapshot(tables: ["tasks": [task(id)], "view_orders": [pin(id)]])
        let backup = WorkspaceBackup.make(state, account: account)
        let plan = try backup.plan(current: Snapshot(), account: other)
        let remapped = plan.mappedIDs["tasks"]![id]!
        let order = plan.changes.first { $0.table == "view_orders" }!
        XCTAssertEqual(order.recordID, PinnedNotes.key(remapped)); XCTAssertEqual(order.fields["ids"], .array([.string(remapped)]))
        state = Snapshot(); for change in plan.changes { state.apply(change) }
        XCTAssertTrue(PinnedNotes.contains(remapped, pins: state.tables["view_orders"]!, account: other))
        XCTAssertEqual(state.tables["tasks"]![0].string("description"), "Instructions\nKeep all the details.")
    }
    func testTimelineSchedulesExactExpiryBetweenDailyEntriesAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
        let now = ISO8601DateFormatter().date(from: "2026-10-24T12:34:00Z")!
        var widget = try snapshot(tasks: [task(id)], pins: [pin(id)])
        widget.updated = now.timeIntervalSinceReferenceDate
        let selected = widget.availableNotes[0].id
        let dates = widget.noteTimelineDates(from: now, calendar: calendar)
        let expiry = now.addingTimeInterval(86_400)
        XCTAssertTrue(dates.contains(expiry)); XCTAssertEqual(dates.first, now)
        XCTAssertEqual(Set(dates).count, dates.count)
        XCTAssertEqual(widget.noteStatus(selected, at: expiry.addingTimeInterval(-1)), .ready)
        XCTAssertEqual(widget.noteStatus(selected, at: expiry), .refresh)
        XCTAssertEqual(widget.noteTimelineDates(from: expiry, calendar: calendar), WidgetSnapshot.timelineDates(from: expiry, calendar: calendar))
    }
    func testUntouchedSelectionFollowsSyncAndFirstTapCapturesTheVisibleState() {
        var selection = PinnedNoteSelection()
        XCTAssertNil(selection.desired); XCTAssertNil(selection.change)
        // The task was unpinned when the editor opened; it became pinned before this tap.
        selection.choose(false, current: true)
        XCTAssertEqual(selection.change, false)
        // Returning to the visible original choice is an unchanged selection.
        selection.choose(true, current: false)
        XCTAssertNil(selection.change)
        var enabled = PinnedNoteSelection(); enabled.choose(true, current: false)
        XCTAssertEqual(enabled.change, true)
    }
    func testStrictAccountLinksDecodeEscapedPathExactlyOnce() throws {
        let widget = try snapshot(tasks: [task("id/ ?#%é")], pins: [pin("id/ ?#%é")])
        let note = widget.availableNotes[0], link = note.url(account: account)
        XCTAssertEqual(PinnedNoteLink.parse(link), PinnedNoteLink(account: account, taskID: "id/ ?#%é"))
        XCTAssertEqual(PinnedNoteLink.parse(widget.notesURL), PinnedNoteLink(account: account, taskID: nil))
        for value in ["https://note/id?account=owner", "taskfold://note/id?account=", "taskfold://note/id?account=a&account=b", "taskfold://note/id/extra?account=a", "taskfold://u@note/id?account=a", "taskfold://note:80/id?account=a", "taskfold://note/id?account=a#fragment", "taskfold://notes/extra?account=a"] {
            XCTAssertNil(PinnedNoteLink.parse(URL(string: value)!), value)
        }
    }
}
