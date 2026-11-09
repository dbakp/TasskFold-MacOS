import XCTest
@testable import TaskfoldCore

final class AbsoluteFilterDescriptionTests: XCTestCase {
    private var context: FilterContext {
        FilterContext(projects: [Record(["id": .string("work"), "name": .string("Work"), "user_id": .string("owner")]),
                      Record(["id": .string("literal"), "name": .string("2032-04-05"), "user_id": .string("owner")])],
                      labels: [], userID: "owner", collaborators: [])
    }
    private var rows: [Record] {
        [
            Record(["id": .string("planned"), "due_date": .string("2032-04-05"), "deadline_date": .string("2032-04-06"), "priority": .number(1), "project_id": .string("work")]),
            Record(["id": .string("deadline"), "due_date": .string("2032-04-04"), "deadline_date": .string("2032-04-05")]),
            Record(["id": .string("later"), "due_date": .string("2032-04-06"), "deadline_date": .string("2032-04-08"), "priority": .number(3)]),
            Record(["id": .string("missing")]),
            Record(["id": .string("done"), "due_date": .string("2032-04-05"), "completed": .bool(true)])
        ]
    }
    private func matches(_ goal: String, rows: [Record]? = nil) throws -> [String] {
        let text = try XCTUnwrap(LocalFilterDescription.expression(for: goal), goal)
        let value = try FilterSuggestion(expression: text, context: context)
        return (rows ?? self.rows).filter {
            value.rule.resultMatches($0, context: context, today: "2040-01-01", timeZone: "UTC")
        }.map(\.id)
    }
    func testExactPlannedAndDeadlineDatesStayDistinctAndAbsolute() throws {
        XCTAssertEqual(try matches("Open tasks planned on 2032-04-05"), ["planned"])
        XCTAssertEqual(try matches("Tasks with a deadline on 2032-04-05"), ["deadline"])
        XCTAssertEqual(try matches("Completed tasks scheduled for 2032-04-05."), ["done"])
        let expression = try XCTUnwrap(LocalFilterDescription.expression(for: "Tasks planned on 2032-04-05"))
        let canonical = try FilterSuggestion(expression: #"date:"2032-04-05""#, context: context)
        let actual = try FilterSuggestion(expression: expression, context: context)
        XCTAssertTrue(AuthoredValueComparison.exactJSON(canonical.rule.document, actual.rule.document))
    }
    func testBeforeAndAfterAreStrictAndExcludeUndatedWork() throws {
        XCTAssertEqual(try matches("Tasks planned before 2032-04-05"), ["deadline"])
        XCTAssertEqual(try matches("Tasks scheduled after 2032-04-05"), ["later"])
        XCTAssertEqual(try matches("Tasks with a deadline before 2032-04-06"), ["deadline"])
        XCTAssertEqual(try matches("Tasks with a deadline after 2032-04-06"), ["later"])
    }
    func testAbsoluteDatesComposeWithoutDroppingOtherConditions() throws {
        XCTAssertEqual(try matches(#"Open priority 1 tasks planned after 2032-04-04 and with a deadline before 2032-04-07 and in project "Work""#), ["planned"])
        XCTAssertEqual(try matches("Open tasks planned on 2032-04-04 or 2032-04-06"), ["deadline", "later"])
        XCTAssertEqual(try matches("Open tasks excluding those planned on 2032-04-05"), ["deadline", "later", "missing"])
        XCTAssertNil(LocalFilterDescription.expression(for: "Open tasks planned after 2032-04-04 approximately"))
    }
    func testLeapDaysRequireExactCompleteAsciiGregorianDates() {
        for value in ["2032-02-29", "2000-02-29", "2032-12-31", "2033-01-01"] {
            XCTAssertNotNil(LocalFilterDescription.expression(for: "Tasks planned on " + value), value)
        }
        for value in ["2031-02-29", "2100-02-29", "2032-04-31", "2032-00-01", "2032-13-01", "2032-01-00", "0000-01-01", "2032-4-05", "32-04-05", "2032/04/05", "٢٠٣٢-٠٤-٠٥", "2032-04-05T10:00:00Z", "2032-04-05UTC", #""2032-04-05""#] {
            XCTAssertNil(LocalFilterDescription.expression(for: "Tasks planned on " + value), value)
            XCTAssertNil(LocalFilterDescription.expression(for: "Tasks with a deadline after " + value), value)
        }
    }
    func testQuotedDateLikeNamesAndSearchRemainLiteral() throws {
        let rows = [Record(["id": .string("text"), "title": .string("Discuss 2032-04-05"), "project_id": .string("literal")]),
                    Record(["id": .string("date"), "due_date": .string("2032-04-05")])]
        XCTAssertEqual(try matches(#"Tasks containing "2032-04-05""#, rows: rows), ["text"])
        XCTAssertEqual(try matches(#"Tasks in project "2032-04-05""#, rows: rows), ["text"])
    }
    func testAbsoluteDescriptionsUseLocalDraftWithoutModel() async throws {
        for goal in ["Tasks planned on 2032-02-29", "Open tasks with a deadline after 2032-04-05"] {
            let draft = try await FilterAssistanceEngine.draft(goal)
            XCTAssertEqual(draft.origin, .localDescription)
            _ = try FilterSuggestion(expression: draft.expression, context: context)
        }
    }
}

