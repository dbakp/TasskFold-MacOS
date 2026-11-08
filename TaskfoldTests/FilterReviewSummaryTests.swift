import XCTest
@testable import TaskfoldCore

final class FilterReviewSummaryTests: XCTestCase {
    private let context = FilterContext(projects: [Record(["id": .string("p"), "name": .string("Work")])], labels: [], userID: "owner", collaborators: [])
    private func rule(_ expression: String) throws -> FilterRule { try FilterSuggestion(expression: expression, context: context).rule }
    func testLongTaskSummaryExplainsTheGuardedLowerBound() throws {
        let text = try XCTUnwrap(LocalFilterDescription.expression(for: "Open tasks taking at least one hour"))
        XCTAssertEqual(try rule(text).reviewSummary(in: context, includeCompleted: false), "All of: (Unfinished tasks); (Estimate at least 1 hour)")
        let strict = try XCTUnwrap(LocalFilterDescription.expression(for: "Open tasks taking more than one hour"))
        XCTAssertEqual(try rule(strict).reviewSummary(in: context, includeCompleted: false), "All of: (Unfinished tasks); (Estimate at least 61 minutes)")
    }
    func testAnUnguardedNegatedMaximumNeverPretendsMissingEstimatesAreLong() throws {
        let unguarded = try rule("NOT duration<=59"), guarded = try rule("NOT no estimate AND NOT duration<=59")
        let unknown = Record(["id": .string("missing")]), long = Record(["id": .string("known"), "duration_minutes": .number(60)])
        XCTAssertTrue(unguarded.resultMatches(unknown, context: context, today: "2032-04-05", timeZone: "UTC"))
        XCTAssertFalse(guarded.resultMatches(unknown, context: context, today: "2032-04-05", timeZone: "UTC"))
        XCTAssertTrue(guarded.resultMatches(long, context: context, today: "2032-04-05", timeZone: "UTC"))
        XCTAssertEqual(unguarded.reviewSummary(in: context, includeCompleted: true), "Not: (Estimate at most 59 minutes)")
        XCTAssertEqual(guarded.reviewSummary(in: context, includeCompleted: true), "Estimate at least 1 hour")
        let different = FilterRule.and([.not(.predicate("no_estimate", "")), .predicate("duration_max", "59")])
        XCTAssertEqual(different.reviewSummary(in: context, includeCompleted: true), "All of: (Has an estimate); (Estimate at most 59 minutes)")
    }
    func testDefaultCompletionVisibilityBelongsToEachOrderedList() {
        let lists = FilterRule.sections([.predicate("completed", "true"), .predicate("project", "p")])
        XCTAssertEqual(lists.reviewSummary(in: context, includeCompleted: false), "List 1: (Completed tasks); List 2: (Unfinished tasks only. In project “Work”)")
        XCTAssertEqual(lists.reviewSummary(in: context, includeCompleted: true), "List 1: (Completed tasks); List 2: (In project “Work”)")
        XCTAssertEqual(FilterRule.predicate("all", "").reviewSummary(in: context, includeCompleted: false), "Unfinished tasks")
    }
    func testBooleanAlternativesAndExclusionsStayExplicit() throws {
        let union = try rule("open AND (p1 OR p3) AND NOT today")
        XCTAssertEqual(union.reviewSummary(in: context, includeCompleted: false), "All of: (Unfinished tasks); (Any of: (Priority 1); (Priority 3)); (Not: (Planned today))")
        XCTAssertNotEqual(union.reviewSummary(in: context, includeCompleted: false), try rule("open AND p1 AND p3 AND NOT today").reviewSummary(in: context, includeCompleted: false))
    }
    func testDateSourcesAndStrictBoundariesAreDistinct() {
        let cases = [("planned_before", "Planned before"), ("planned_after", "Planned after"), ("deadline_before_day", "Deadline before"), ("deadline_after", "Deadline after"), ("effective_due_on", "Effective due date on"), ("planned_time_before", "Planned time before"), ("created_after", "Created after")]
        for (field, title) in cases {
            XCTAssertEqual(FilterRule.predicate(field, "tomorrow").reviewSummary(in: context, includeCompleted: true), title + " “tomorrow”")
        }
        XCTAssertEqual(FilterRule.predicate("planned_next_days", "3").reviewSummary(in: context, includeCompleted: true), "Planned date in a 3-day window including today")
        XCTAssertEqual(FilterRule.predicate("deadline_past_days", "3").reviewSummary(in: context, includeCompleted: true), "Deadline in the previous 3 days, excluding today")
    }
    func testLiteralTargetsAndStoredExpressionsRemainExact() throws {
        for name in ["Café", "Cafe\u{301}", "Work OR all", "Work“ (priority 1)"] {
            let context = FilterContext(projects: [Record(["id": .string("p"), "name": .string(name)])], labels: [], userID: "owner")
            let exact = FilterRule.predicate("project", "p"), tree = FilterRule.predicate("project_tree", "p")
            let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = .sortedKeys
            let before = try encoder.encode(tree.document), expression = tree.expression(in: context)
            XCTAssertTrue(exact.reviewSummary(in: context, includeCompleted: true).utf8.elementsEqual("In project “\(name)”".utf8))
            XCTAssertTrue(tree.reviewSummary(in: context, includeCompleted: true).utf8.elementsEqual("In project “\(name)” and its subprojects".utf8))
            XCTAssertEqual(try encoder.encode(tree.document), before)
            XCTAssertTrue(tree.expression(in: context).utf8.elementsEqual(expression.utf8))
        }
    }
    func testPeopleUseAvailableNamesWithoutExposingStoredIdentifiers() {
        let id = "a8100000-0000-4000-8000-000000000001"
        let context = FilterContext(userID: "owner", people: [Record(["id": .string(id), "display_name": .string("Morgan")])])
        XCTAssertEqual(FilterRule.predicate("assignee", id).reviewSummary(in: context, includeCompleted: true), "Assigned to Morgan")
        XCTAssertFalse(FilterRule.predicate("assigned_by", id).reviewSummary(in: context, includeCompleted: true).contains(id))
    }
    func testStoredSelfReferencesRemainMeWithoutAPeopleDirectory() throws {
        let id = "a8100000-0000-4000-8000-000000000001"
        let context = FilterContext(userID: id, people: [], assignments: .init([]))
        for (field, value, expected) in [("assignee", id, "Assigned to me"), ("assigned_by", id, "Assigned by me"), ("assigned_by", id.uppercased(), "Assigned by me")] {
            let rule = FilterRule.predicate(field, value)
            XCTAssertNoThrow(try rule.validate(in: context))
            XCTAssertEqual(rule.reviewSummary(in: context, includeCompleted: true), expected)
            XCTAssertFalse(rule.reviewSummary(in: context, includeCompleted: true).contains(id))
        }
    }
    func testExactAssigneeComparisonIsNotSilentlyNormalizedByItsSummary() {
        let id = "a8100000-0000-4000-8000-000000000001"
        let context = FilterContext(userID: id)
        let rule = FilterRule.predicate("assignee", id.uppercased())
        let task = Record(["id": .string("task"), "assigned_to": .string(id)])
        XCTAssertFalse(rule.resultMatches(task, context: context, today: "2032-04-05", timeZone: "UTC"))
        XCTAssertNotEqual(rule.reviewSummary(in: context, includeCompleted: true), "Assigned to me")
    }
    func testEveryCurrentPredicateHasAPlainLanguagePresentation() {
        // Coverage of the language contract; semantic counterexamples are above.
        for field in FilterRule.fields {
            let value = field == "duration_max" ? "30" : field == "completed" ? "false" : "1"
            let summary = FilterRule.predicate(field, value).reviewSummary(in: context, includeCompleted: true)
            XCTAssertFalse(summary.hasPrefix("Condition “"), field)
            XCTAssertFalse(summary.isEmpty, field)
        }
    }
    func testUnknownPresentationKeepsBothFieldAndValue() {
        let summary = FilterRule.predicate("future-condition", "preserve this value").reviewSummary(in: context, includeCompleted: true)
        XCTAssertEqual(summary, "Condition “future-condition”: “preserve this value”")
    }
}
