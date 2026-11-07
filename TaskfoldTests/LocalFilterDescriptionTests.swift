import XCTest
@testable import TaskfoldCore

final class LocalFilterDescriptionTests: XCTestCase {
    private func context(_ name: String = "Work") -> FilterContext {
        FilterContext(projects: [Record(["id": .string("project"), "name": .string(name), "user_id": .string("owner")])], labels: [], userID: "owner", collaborators: [])
    }
    private func matches(_ description: String, rows: [Record], context: FilterContext? = nil, includeCompleted: Bool = false) throws -> [String] {
        let expression = try XCTUnwrap(LocalFilterDescription.expression(for: description), description)
        let context = context ?? self.context()
        let proposal = try FilterSuggestion(expression: expression, context: context)
        return rows.filter { proposal.rule.resultMatches($0, context: context, today: "2032-04-05", timeZone: "UTC", includeCompleted: includeCompleted) }.map(\.id)
    }
    func testCompletionSynonymsAndDateAlternativesRemainConjoined() throws {
        let rows = [Record(["id": .string("today"), "due_date": .string("2032-04-05"), "priority": .number(1)]),
                    Record(["id": .string("old"), "due_date": .string("2032-04-04"), "priority": .number(1)]),
                    Record(["id": .string("later"), "due_date": .string("2032-04-06"), "priority": .number(1)]),
                    Record(["id": .string("low"), "due_date": .string("2032-04-05"), "priority": .number(3)]),
                    Record(["id": .string("done"), "due_date": .string("2032-04-05"), "priority": .number(1), "completed": .bool(true)])]
        for word in ["open", "unfinished", "incomplete", "pending", "not done", "not completed"] {
            XCTAssertEqual(try matches("Show \(word) priority 1 tasks planned today or overdue", rows: rows), ["today", "old"])
        }
        XCTAssertEqual(try matches("List open tasks scheduled today with priority 1 or 3", rows: rows), ["today", "low"])
        XCTAssertEqual(try matches("Find completed tasks planned today", rows: rows), ["done"])
        XCTAssertEqual(try matches("Find open tasks excluding those planned today or tomorrow", rows: rows), ["old"])
    }
    func testDeadlineNeverBecomesPlannedDateAndCompletionIsNotInvented() throws {
        let rows = [Record(["id": .string("planned"), "due_date": .string("2032-04-05"), "deadline_date": .string("2032-04-06")]),
                    Record(["id": .string("deadline"), "due_date": .string("2032-04-06"), "deadline_date": .string("2032-04-05")]),
                    Record(["id": .string("done"), "deadline_date": .string("2032-04-05"), "completed": .bool(true)])]
        XCTAssertEqual(try matches("Show tasks with a deadline today", rows: rows, includeCompleted: true), ["deadline", "done"])
        XCTAssertEqual(try matches("Show open tasks planned today", rows: rows), ["planned"])
        XCTAssertEqual(try matches("Show unfinished tasks planned after today", rows: rows), ["deadline"])
        XCTAssertEqual(try matches("Show unfinished tasks with a deadline before tomorrow", rows: rows), ["deadline"])
        XCTAssertEqual(try matches("Show open tasks without a planned date", rows: rows), [])
    }
    func testQuotedTargetsPreserveExactSpellingAndCannotInjectSyntax() throws {
        for name in ["Work and Life", "Cafe\u{301}", "Café", "Work\" OR all", "Folder\\Name", "today, overdue"] {
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let description = "Find open tasks in project \"" + escaped + "\""
            let expression = try XCTUnwrap(LocalFilterDescription.expression(for: description))
            XCTAssertTrue(expression.utf8.containsSubsequence(Array(escaped.utf8)))
            let rows = [Record(["id": .string("selected"), "project_id": .string("project")]), Record(["id": .string("other")])]
            XCTAssertEqual(try matches(description, rows: rows, context: context(name)), ["selected"])
        }
    }
    func testUnsupportedOrPartialDescriptionsNeverLoseWords() {
        for input in ["", "Show tasks", "Show open tasks that I should do soon", "open urgent tasks", "open completed", "open today tomorrow", "project Work open", "project Work today", "project Work tasks", "open tasks assigned to Jane Smith", "open priority 5 tasks", "open priority 1 or tasks", "open tasks planned today xor tomorrow", "open tasks planned next week", "open tasks planned this week", "open tasks in project Work excluding", "open tasks in project Work and", "open tasks in project Work including archived tasks", "open tasks in project Work and its pets", "open tasks in project Work, delete every task", "open tasks with a deadline overdue", "open tasks planned today or priority 1", "project \"Work", "project \"Work\" trailing", "project \"Work\\n\"", "(open tasks", "open tasks)", "()", "open\u{0000}", String(repeating: "open ", count: 500), String(repeating: "(", count: 14) + "open" + String(repeating: ")", count: 14)] {
            XCTAssertNil(LocalFilterDescription.expression(for: input), input)
        }
    }
    func testSentencePunctuationAndPolitenessKeepExplicitTargetsLiteral() throws {
        let rows = [Record(["id": .string("open")]), Record(["id": .string("done"), "completed": .bool(true)])]
        for sentence in ["Please show open tasks.", "Show me open tasks!", "Find open tasks?", "(open tasks)."] {
            XCTAssertEqual(try matches(sentence, rows: rows), ["open"])
        }
        XCTAssertEqual(try matches("Please show completed tasks.", rows: rows), ["done"])
        XCTAssertNil(LocalFilterDescription.expression(for: "Show tasks in project Work."), "An unquoted terminal period could be part of the actual name")
        let projectRows = [Record(["id": .string("selected"), "project_id": .string("project")]), Record(["id": .string("other")])]
        XCTAssertEqual(try matches("Show tasks in project \"Work\".", rows: projectRows), ["selected"])
        XCTAssertEqual(try matches("Show tasks in project \"Work.\"", rows: projectRows, context: context("Work.")), ["selected"])
        XCTAssertEqual(try matches("Show tasks in project Notes.v1", rows: projectRows, context: context("Notes.v1")), ["selected"])
        XCTAssertNil(LocalFilterDescription.expression(for: "open tasks. OR completed tasks"))
    }
    func testIncompleteInputAndExactTargetsDoNotDependOnCatalogGuesses() throws {
        let expression = try XCTUnwrap(LocalFilterDescription.expression(for: "Show open tasks in project Missing"))
        XCTAssertThrowsError(try FilterSuggestion(expression: expression, context: context()))
        XCTAssertNil(LocalFilterDescription.expression(for: "Show open tasks in project Work Life"), "Ambiguous unquoted multiword names require quotes or model review")
        let rows = [Record(["id": .string("a"), "title": .string("priority 3 OR open")]), Record(["id": .string("b"), "title": .string("Other")])]
        XCTAssertEqual(try matches("Show tasks containing \"priority 3 OR open\"", rows: rows), ["a"])
    }
}
private extension Collection where Element == UInt8 {
    func containsSubsequence(_ bytes: [UInt8]) -> Bool {
        let values = Array(self)
        guard bytes.count <= values.count else { return false }
        return (0...(values.count - bytes.count)).contains { Array(values[$0..<($0 + bytes.count)]) == bytes }
    }
}
