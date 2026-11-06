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
    func testRegistryLookupPreservesFirstMatchAndTaskIdentityRules() {
        let ids = ["", "a", "A", "with:colon", "with|pipe", String(repeating: "x", count: 200), String(repeating: "x", count: 201), "é", "e\u{301}", "👩🏽‍💻"]
        let tasks = ids.flatMap { id -> [Record] in
            var first = task(id); first["title"] = .string("First " + id)
            var duplicate = first; duplicate["title"] = .string("Later " + id)
            return [first, duplicate]
        }
        for owner in [account, other, ""] {
            for variant in 0..<6 {
                let pins = ids.flatMap { id -> [Record] in
                    var malformed = pin(id); malformed["ids"] = .array([.string(id), .string(id)])
                    switch variant {
                    case 0: return [pin(id)]
                    case 1: return [pin(id, user: other), pin(id)]
                    case 2: return [malformed, pin(id)]
                    case 3: return [pin(id), malformed, pin(id, user: other)]
                    case 4: return [Record(["id": .string("scope:" + id), "user_id": .string(account)]), pin(id)]
                    default: return []
                    }
                }
                // The single-pin reader remains the independent legacy oracle.
                var seen = Set<String>()
                let expected = tasks.filter { seen.insert($0.id).inserted && PinnedNotes.contains($0.id, pins: pins, account: owner) }
                XCTAssertEqual(PinnedNotes.tasks(tasks, pins: pins, account: owner), expected, "Owner \(owner), registry \(variant)")
                XCTAssertEqual(PinnedNotes.tasks(tasks, pins: pins.reversed(), account: owner), {
                    var seen = Set<String>()
                    return tasks.filter { seen.insert($0.id).inserted && PinnedNotes.contains($0.id, pins: pins.reversed(), account: owner) }
                }())
            }
        }
    }

    func testLargeUnrelatedOrderingRegistryKeepsOnlyExplicitPins() {
        let rows = (0..<5000).map { Record(["id": .string("task-\($0)"), "title": .string("Task \($0)"), "description": .string("Private \($0)")]) }
        var pins = (0..<5000).map { Record(["id": .string("group:project:section-\($0)"), "user_id": .string(account), "ids": .array([.string("task-\($0)")])]) }
        pins += [pin(rows[17].id), pin(rows[4999].id)]
        let clock = ContinuousClock(), start = clock.now
        let selected = PinnedNotes.tasks(rows, pins: pins, account: account)
        let elapsed = start.duration(to: clock.now)
        print("PIN_REGISTRY_5000_SECONDS \(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)")
        XCTAssertEqual(selected, [rows[17], rows[4999]])
        XCTAssertEqual(PinnedNotes.payload(tasks: rows, pins: pins, account: account).compactMap { $0.object["taskID"]?.text }, [rows[17].id, rows[4999].id])
        XCTAssertTrue(PinnedNotes.tasks(rows, pins: pins, account: other).isEmpty)
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

private actor PinnedNoteSearchGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if opened { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { opened = true; waiters.forEach { $0.resume() }; waiters = [] }
}

final class PinnedNoteCatalogTests: XCTestCase {
    private let account = "owner"
    private func task(_ id: String, _ title: String = "Handbook", body: JSON = .string("Review café contrast"), project: String = "design") -> Record {
        Record(["id": .string(id), "user_id": .string(account), "title": .string(title), "description": body, "project_id": .string(project), "section_id": .string("review"), "task_generation": .string("original"), "completed": .bool(false)])
    }
    private func pin(_ id: String, owner: String = "owner") -> Record { Record(["id": .string(PinnedNotes.key(id)), "user_id": .string(owner), "ids": .array([.string(id)])]) }
    private var projects: [Record] { [Record(["id": .string("personal"), "name": .string("Personal")]), Record(["id": .string("design"), "name": .string("Design"), "parent_id": .string("personal")])] }
    private var sections: [Record] { [Record(["id": .string("review"), "project_id": .string("design"), "name": .string("Research")])] }
    private func catalog(_ tasks: [Record], pins: [Record]? = nil) throws -> PinnedNoteCatalog { try .init(tasks: tasks, pins: pins ?? tasks.map { pin($0.id) }, projects: projects, sections: sections, account: account) }
    func testSearchCombinesTitleFullNoteUnicodeAndProjectSectionPath() throws {
        let note = task("one", body: .string("# Handoff\n" + String(repeating: "Introduction ", count: 500) + "\nCafé contrast decision"))
        let index = try catalog([note, task("two", "Handbook", body: .string("Other text"), project: "")])
        XCTAssertEqual(try index.page(query: "CAFE personal research handbook").options.map(\.id), ["one"])
        XCTAssertEqual(try index.page(query: "handbook").total, 2)
        let match = try XCTUnwrap(try index.page(query: "decision").options.first)
        XCTAssertEqual(match.location, "Personal › Design › Research"); XCTAssertFalse(match.preview.contains("decision")); XCTAssertTrue(match.preview.hasSuffix("…"))
        XCTAssertLessThanOrEqual(match.preview.utf8.count, 1203)
        XCTAssertEqual(try index.page(query: "cafe missing").total, 0)
    }
    func testCompletedArchivedAndMissingProjectNotesStayReadableWithoutInventingLocation() throws {
        var note = task("one"); note["completed"] = .bool(true)
        var archived = projects; archived[0]["is_archived"] = .bool(true)
        let index = try PinnedNoteCatalog(tasks: [note, task("orphan", project: "missing")], pins: [pin("one"), pin("orphan")], projects: archived, sections: sections, account: account)
        XCTAssertTrue(try XCTUnwrap(index.options.first { $0.id == "one" }).completed)
        XCTAssertTrue(try XCTUnwrap(index.options.first { $0.id == "one" }).location.hasPrefix("Archived · "))
        XCTAssertEqual(try XCTUnwrap(index.options.first { $0.id == "orphan" }).location, "Project unavailable")
    }
    func testPinAuthorityAndAmbiguousTaskIdentitiesCannotExposeAnotherNote() throws {
        let rows = [task("duplicate"), task("duplicate", "Different"), task("shadow"), task("good")]
        let pins = [pin("duplicate"), pin("shadow", owner: "other"), pin("shadow"), pin("good")]
        XCTAssertEqual(try catalog(rows, pins: pins).options.map(\.id), ["good"])
        XCTAssertTrue(try PinnedNoteCatalog(tasks: rows, pins: pins, projects: projects, sections: sections, account: "").options.isEmpty)
    }
    func testCurrentSelectionFollowsTextButRejectsReplacementMoveUnpinAndAccount() throws {
        let original = task("one"), pins = [pin("one")], option = try XCTUnwrap(try catalog([original]).options.first)
        var current = original; current["title"] = .string("Updated"); current["description"] = .string("New words"); current["completed"] = .bool(true)
        XCTAssertEqual(PinnedNoteCatalog.current(option, tasks: [current], pins: pins, account: account), current)
        for field in ["user_id", "project_id", "section_id", "task_generation", "created_at"] {
            var changed = current; changed[field] = .string("changed")
            XCTAssertNil(PinnedNoteCatalog.current(option, tasks: [changed], pins: pins, account: account))
        }
        XCTAssertNil(PinnedNoteCatalog.current(option, tasks: [current, current], pins: pins, account: account))
        XCTAssertNil(PinnedNoteCatalog.current(option, tasks: [current], pins: [], account: account))
        XCTAssertNil(PinnedNoteCatalog.current(option, tasks: [current], pins: pins, account: "other"))
    }
    func testBlankOpaqueAndUnsafeMarkupRemainUnmodified() throws {
        let opaque = try TaskfoldJSONDecoder().decode(JSON.self, from: Data("9007199254740993".utf8))
        let rows = [task("blank", body: .null), task("opaque", body: opaque), task("link", body: .string("[Keep](javascript:alert(1))"))]
        let original = rows; let index = try catalog(rows)
        XCTAssertEqual(index.options.first { $0.id == "blank" }?.preview, "Add instructions or an idea")
        XCTAssertEqual(index.options.first { $0.id == "opaque" }?.preview, "Open task details to review this saved note")
        XCTAssertEqual(rows, original)
        XCTAssertEqual(try index.page(query: "javascript").options.map(\.id), ["link"])
    }
    func testBoundedPagesStableOrderAndCooperativeCancellation() throws {
        let rows = (0..<3000).map { task("\($0)", String(format: "Note %04d", $0), body: .string("# Instructions\nRead the design brief.")) }
        let start = Date(), index = try catalog(rows)
        print("PINNED_NOTE_CATALOG_3000_SECONDS \(Date().timeIntervalSince(start))")
        XCTAssertEqual(try index.page(query: "").options.count, 60)
        XCTAssertEqual(try index.page(query: "", limit: 120).options.map(\.id).prefix(60), try index.page(query: "").options.map(\.id)[...])
        XCTAssertEqual(try index.page(query: "instructions", limit: 0).total, 3000)
        var checks = 0
        XCTAssertThrowsError(try index.page(query: "missing", checkCancellation: { checks += 1; if checks == 4 { throw CancellationError() } }))
        checks = 0
        XCTAssertThrowsError(try PinnedNoteCatalog(tasks: rows, pins: rows.map { pin($0.id) }, projects: projects, sections: sections, account: account, checkCancellation: { checks += 1; if checks == 4 { throw CancellationError() } }))
    }
    func testAsyncLoadAndSearchRejectCancelledWork() async throws {
        let rows = (0..<3000).map { task("\($0)", "Note \($0)") }, pins = rows.map { pin($0.id) }
        let loadGate = PinnedNoteSearchGate(), projectRows = projects, sectionRows = sections, owner = account
        let load = Task { await loadGate.wait(); return try await PinnedNoteCatalog.load(tasks: rows, pins: pins, projects: projectRows, sections: sectionRows, account: owner) }
        load.cancel(); await loadGate.release()
        do { _ = try await load.value; XCTFail("Cancelled load published") } catch is CancellationError { }
        let index = try catalog([task("one")])
        let searchGate = PinnedNoteSearchGate()
        let search = Task { await searchGate.wait(); return try await index.search(query: "cafe", limit: 60) }; search.cancel(); await searchGate.release()
        do { _ = try await search.value; XCTFail("Cancelled search published") } catch is CancellationError { }
    }
}
