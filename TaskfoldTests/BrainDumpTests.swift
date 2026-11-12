import XCTest
@testable import TaskfoldCore

/// Brain dump (Core/BrainDump.swift): bounds, the deterministic splitter, sanitising model output, Quick Add parsing,
/// the review rows and the generation-token rules. The on-device model itself is never needed here.
final class BrainDumpTests: XCTestCase {
    private let account = "owner"
    private let workspace = WorkspaceBinding(account: "owner", generation: UUID())
    private let session = UUID()
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!; return c }
    private var now: Date { calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 11, day: 11, hour: 9))! }
    private func context() -> QuickEntryContext {
        QuickEntryContext(projects: [Record(["id": .string("work"), "name": .string("Work"), "user_id": .string(account)])], labels: [], currentUser: account)
    }

    // MARK: Bounds

    func testInputBounds() throws {
        XCTAssertEqual(try BrainDump.input("  call Anna \n"), "call Anna")
        for bad in ["", "  \n ", "a\0b", String(repeating: "x", count: 8_001)] { XCTAssertThrowsError(try BrainDump.input(bad), bad.prefix(5).description) }
        XCTAssertEqual(try BrainDump.input(String(repeating: "x", count: 8_000)).count, 8_000)
        XCTAssertEqual(try BrainDump.input(String(repeating: "é", count: 8_000)).count, 8_000, "The bound counts characters, not bytes")
    }

    // MARK: Deterministic splitter

    func testSplitsOnNewlinesBulletsNumbersAndCheckboxes() {
        let text = "- Buy milk\n* Call Anna\n• Book dentist\n1. Pay rent\n2) Send invoice\n[ ] Water plants\n[x] Take out bins\n\n   \nPlain line"
        XCTAssertEqual(BrainDump.split(text).phrases, ["Buy milk", "Call Anna", "Book dentist", "Pay rent", "Send invoice", "Water plants", "Take out bins", "Plain line"])
    }
    func testSplitsOnSemicolonsAndAndThen() {
        XCTAssertEqual(BrainDump.split("Email Sam; book flights and then pack the bag AND THEN sleep").phrases, ["Email Sam", "book flights", "pack the bag", "sleep"])
        XCTAssertEqual(BrainDump.split("Call Anna;").phrases, ["Call Anna"])
        XCTAssertEqual(BrainDump.split("salt;pepper").phrases, ["salt;pepper"], "A semicolon needs a following space")
        XCTAssertEqual(BrainDump.split("Rock and roll and then some").phrases, ["Rock and roll", "some"])
    }
    func testParagraphWithoutSeparatorsStaysOneTask() {
        XCTAssertEqual(BrainDump.split("Buy milk and eggs for the party on Friday").phrases, ["Buy milk and eggs for the party on Friday"])
        XCTAssertEqual(BrainDump.split("Windows\r\nlines\rand more\u{2028}here").phrases, ["Windows", "lines", "and more", "here"])
    }
    func testSplitterIsDeterministicAndKeepsOrder() {
        let text = "b\na\nc; d\ne"
        XCTAssertEqual(BrainDump.split(text), BrainDump.split(text))
        XCTAssertEqual(BrainDump.split(text).phrases, ["b", "a", "c", "d", "e"])
    }

    // MARK: Sanitising

    func testSanitizeTrimsDedupesAndDropsEmptyAndControlCharacters() {
        let result = BrainDump.sanitize(["  Call Anna  ", "call anna", "CALL ANNA ", "", "   ", "Tab\there", "Line\nbreak", "nul\0byte", "Cafe\u{301}", "café"])
        XCTAssertEqual(result.phrases, ["Call Anna", "Tab here", "Line break", "nulbyte", "Cafe\u{301}"])
        XCTAssertEqual(result.omitted, 0)
    }
    func testSanitizeLimitsLengthAndCount() {
        let long = String(repeating: "a", count: 300)
        XCTAssertEqual(BrainDump.sanitize([long]).phrases[0].count, 200)
        XCTAssertEqual(BrainDump.sanitize([String(repeating: "👩‍👧‍👦", count: 250)]).phrases[0].count, 200)
        let many = BrainDump.sanitize((1...40).map { "Task \($0)" })
        XCTAssertEqual(many.phrases.count, 25); XCTAssertEqual(many.omitted, 15)
        XCTAssertEqual(many.phrases.first, "Task 1"); XCTAssertEqual(many.phrases.last, "Task 25")
    }
    func testModelOutputCannotCarryMetadataBeyondText() {
        // The only thing a phrase can do is be text: every field comes from the Quick Add parser.
        let parsed = BrainDump.parse("{\"project_id\":\"x\",\"priority\":1}", account: account, context: context(), now: now, calendar: calendar)
        XCTAssertEqual(parsed.task.priority, 4)
        XCTAssertEqual(parsed.task.string("user_id"), account)
        XCTAssertTrue(parsed.task.string("project_id").isEmpty)
    }

    // MARK: Quick Add parsing

    func testPhrasesGoThroughTheQuickAddParser() {
        let parsed = BrainDump.parse("Call Anna tomorrow p1 #Work", account: account, context: context(), now: now, calendar: calendar)
        XCTAssertEqual(parsed.task.title, "Call Anna")
        XCTAssertEqual(parsed.task.priority, 1)
        XCTAssertEqual(parsed.task.string("due_date"), "2026-11-12")
        XCTAssertEqual(parsed.task.string("project_id"), "work")
        XCTAssertEqual(parsed.chips.map(\.group), ["due_date", "priority", "project_id"])
        XCTAssertTrue(parsed.isValid)
        let plain = BrainDump.parse("Water the plants", account: account, context: context(), now: now, calendar: calendar)
        XCTAssertTrue(plain.chips.isEmpty); XCTAssertEqual(plain.task.title, "Water the plants")
        XCTAssertEqual(plain.task.string("user_id"), account)
    }
    func testThisEveningAndSomedayAreRecognisedLikeInQuickAdd() {
        let evening = BrainDump.parse("Read a book this evening", account: account, context: context(), now: now, calendar: calendar)
        XCTAssertEqual(evening.task.title, "Read a book"); XCTAssertEqual(evening.planning, .evening)
        XCTAssertEqual(evening.task.string("due_date"), "2026-11-11", "An undated This Evening task is planned for today")
        XCTAssertTrue(evening.chips.contains { $0.group == "planning" })
        let later = BrainDump.parse("Read a book tomorrow this evening", account: account, context: context(), now: now, calendar: calendar)
        XCTAssertNil(later.planning); XCTAssertEqual(later.task.string("due_date"), "2026-11-12"); XCTAssertFalse(later.warnings.isEmpty)
        let someday = BrainDump.parse("Learn piano someday", account: account, context: context(), now: now, calendar: calendar)
        XCTAssertEqual(someday.planning, .someday); XCTAssertEqual(someday.task.title, "Learn piano")
        XCTAssertNil(BrainDump.parse("Plain task", account: account, context: context(), now: now, calendar: calendar).planning)
    }
    func testFilingBuildsOneListPerSlotAcrossSeveralTasks() throws {
        let a = BrainDump.parse("One this evening", account: account, context: context(), now: now, calendar: calendar)
        let b = BrainDump.parse("Two this evening", account: account, context: context(), now: now, calendar: calendar)
        let c = BrainDump.parse("Three someday", account: account, context: context(), now: now, calendar: calendar)
        let d = BrainDump.parse("Four someday", account: account, context: context(), now: now, calendar: calendar)
        let changes = try BrainDump.filing([(a.task, .evening), (b.task, .evening), (c.task, .someday), (d.task, .someday)], tasks: [], rows: [], account: account, today: "2026-11-11", calendar: calendar)
        XCTAssertEqual(changes.count, 2, "One evening list and one someday list")
        let evening = try XCTUnwrap(changes.first { $0.recordID == Planning.eveningKey("2026-11-11") })
        XCTAssertEqual(evening.fields["ids"]?.list.map(\.text), [a.task.id, b.task.id])
        XCTAssertEqual(evening.method, "POST")
        let someday = try XCTUnwrap(changes.first { $0.recordID == Planning.somedayKey })
        XCTAssertEqual(Set(someday.fields["ids"]?.list.map(\.text) ?? []), [c.task.id, d.task.id])
    }
    func testPhraseThatIsOnlyMetadataIsInvalid() {
        XCTAssertFalse(BrainDump.parse("tomorrow", account: account, context: context(), now: now, calendar: calendar).isValid)
    }
    func testAccessibilityLabel() {
        let parsed = BrainDump.parse("Call Anna tomorrow #Work", account: account, context: context(), now: now, calendar: calendar)
        let label = BrainDump.accessibilityLabel(position: 3, count: 7, title: parsed.task.title, chips: parsed.chips)
        XCTAssertTrue(label.hasPrefix("Proposed task 3 of 7, Call Anna, "), label)
        XCTAssertTrue(label.hasSuffix("Work project"), label)
    }

    // MARK: Review rows

    func testReviewMoveEditToggleAndLines() {
        var rows = ["One", "Two", "Three"].map { BrainDumpReview.Row(text: $0) }
        let ids = rows.map(\.id)
        XCTAssertEqual(BrainDumpReview.move(ids[2], by: -1, in: &rows), 1)
        XCTAssertEqual(rows.map(\.text), ["One", "Three", "Two"])
        XCTAssertNil(BrainDumpReview.move(ids[0], by: -1, in: &rows)); XCTAssertNil(BrainDumpReview.move(ids[1], by: 2, in: &rows)); XCTAssertNil(BrainDumpReview.move(UUID(), by: 1, in: &rows))
        rows[0].text = "One tomorrow"; rows[2].included = false
        let lines = BrainDumpReview.lines(rows) { BrainDump.parse($0, account: account, context: context(), now: now, calendar: calendar) }
        XCTAssertEqual(lines.map(\.task.title), ["One", "Three"], "The edited row re-parses and the excluded row is left out")
        XCTAssertEqual(lines.map(\.number), [1, 2])
        XCTAssertEqual(lines[0].task.string("due_date"), "2026-11-12")
        rows[1].text = "tomorrow"
        XCTAssertEqual(BrainDumpReview.lines(rows) { BrainDump.parse($0, account: account, context: context(), now: now, calendar: calendar) }.count, 1, "A row with no title is never added")
    }
    func testAddTitleCounts() { XCTAssertEqual(BrainDump.summary(count: 1), "Add 1 task"); XCTAssertEqual(BrainDump.summary(count: 7), "Add 7 tasks") }

    // MARK: Generation tokens

    func testSessionAcceptsOnlyTheLiveGeneration() throws {
        let request = try BrainDumpRequest(workspace: workspace, session: session)
        var run = BrainDumpSession(request: request)
        let first = try XCTUnwrap(run.begin(workspace: workspace, session: session))
        let second = try XCTUnwrap(run.begin(workspace: workspace, session: session))
        XCTAssertNil(try run.receive(["Old"], token: first, workspace: workspace, session: session), "A superseded generation is ignored")
        XCTAssertEqual(try run.receive([" New ", "new"], token: second, workspace: workspace, session: session)?.phrases, ["New"])
        XCTAssertNil(try run.receive(["Again"], token: second, workspace: workspace, session: session), "A token works once")
    }
    func testCancelCloseAndWorkspaceChangeDiscardResults() throws {
        let request = try BrainDumpRequest(workspace: workspace, session: session)
        var run = BrainDumpSession(request: request)
        let stopped = try XCTUnwrap(run.begin(workspace: workspace, session: session)); run.stop()
        XCTAssertNil(try run.receive(["A"], token: stopped, workspace: workspace, session: session))
        let token = try XCTUnwrap(run.begin(workspace: workspace, session: session))
        XCTAssertNil(try run.receive(["A"], token: token, workspace: WorkspaceBinding(account: "other", generation: workspace.generation), session: session))
        XCTAssertNil(try run.receive(["A"], token: token, workspace: workspace, session: UUID()))
        run.close()
        XCTAssertNil(run.begin(workspace: workspace, session: session))
        XCTAssertNil(try run.receive(["A"], token: token, workspace: workspace, session: session))
        var other = BrainDumpSession(request: request)
        XCTAssertNil(other.begin(workspace: WorkspaceBinding(account: "owner", generation: UUID()), session: session))
    }
    func testEmptyModelResultFailsWithoutConsumingTheToken() throws {
        var run = BrainDumpSession(request: try BrainDumpRequest(workspace: workspace, session: session))
        let token = try XCTUnwrap(run.begin(workspace: workspace, session: session))
        XCTAssertThrowsError(try run.receive(["", "  "], token: token, workspace: workspace, session: session))
        XCTAssertThrowsError(try BrainDumpRequest(workspace: WorkspaceBinding(account: "", generation: UUID()), session: session))
    }
    func testEngineRefusesBadInputBeforeAnyModelWork() async {
        do { _ = try await BrainDumpEngine.generate("   "); XCTFail("empty input must throw") } catch {}
        do { _ = try await BrainDumpEngine.generate(String(repeating: "x", count: 9_000)); XCTFail("oversized input must throw") } catch {}
    }
}
