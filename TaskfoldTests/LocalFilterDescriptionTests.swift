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
    func testEffortBoundsMatchActualMinutesAndExcludeMissingEstimates() throws {
        let rows = [15, 29, 30, 31, 59, 60, 61].map { Record(["id": .string("m\($0)"), "duration_minutes": .number(Double($0))]) } + [Record(["id": .string("unknown")])]
        let thirty = ["m15", "m29", "m30"]
        for description in ["Show open tasks estimated at 30 minutes or less", "Open tasks with an estimate of at most 30 minutes", "Tasks taking no more than 30 minutes", "Tasks taking up to 30 minutes", "Tasks estimated at most 30 minutes"] {
            XCTAssertEqual(try matches(description, rows: rows), thirty, description)
        }
        XCTAssertEqual(try matches("Tasks estimated under 1 hour", rows: rows), ["m15", "m29", "m30", "m31", "m59"])
        XCTAssertEqual(try matches("Tasks with an estimate of less than 30 minutes", rows: rows), ["m15", "m29"])
        XCTAssertEqual(try matches("Tasks estimated at 1 hour or less", rows: rows), ["m15", "m29", "m30", "m31", "m59", "m60"])
        XCTAssertEqual(try matches("Tasks taking at most one minute", rows: rows), [])
        XCTAssertNotNil(LocalFilterDescription.expression(for: "Tasks estimated at most 168 hours"))
        XCTAssertNotNil(LocalFilterDescription.expression(for: "Tasks estimated at most 10080 minutes"))
    }
    func testLowerEffortBoundsIncludeTheBoundaryAndExcludeUnknownEstimates() throws {
        let rows = [29, 30, 31, 59, 60, 61].map { Record(["id": .string("m\($0)"), "duration_minutes": .number(Double($0))]) }
            + [Record(["id": .string("missing")]), Record(["id": .string("null"), "duration_minutes": .null]), Record(["id": .string("zero"), "duration_minutes": .number(0)]), Record(["id": .string("oversized"), "duration_minutes": .number(10081)])]
        for goal in ["Open tasks taking at least 30 minutes", "Tasks with an estimate of no less than 30 minutes", "Tasks estimated at 30 minutes or more", "Tasks taking 30 minutes or longer"] {
            XCTAssertEqual(try matches(goal, rows: rows), ["m30", "m31", "m59", "m60", "m61"], goal)
        }
        for goal in ["Tasks taking more than 30 minutes", "Tasks estimated over 30 minutes"] {
            XCTAssertEqual(try matches(goal, rows: rows), ["m31", "m59", "m60", "m61"], goal)
        }
        XCTAssertEqual(try matches("Tasks taking at least one hour", rows: rows), ["m60", "m61"])
        XCTAssertEqual(try matches("Tasks estimated over one hour", rows: rows), ["m61"])
    }
    func testLowerEffortBoundExtremesHaveExactMeaning() throws {
        let rows = [1, 2, 10079, 10080].map { Record(["id": .string("m\($0)"), "duration_minutes": .number(Double($0))]) } + [Record(["id": .string("missing")])]
        XCTAssertEqual(try matches("Tasks taking at least one minute", rows: rows), ["m1", "m2", "m10079", "m10080"])
        XCTAssertEqual(try matches("Tasks taking over one minute", rows: rows), ["m2", "m10079", "m10080"])
        XCTAssertEqual(try matches("Tasks estimated at least 168 hours", rows: rows), ["m10080"])
        XCTAssertEqual(try matches("Tasks estimated more than 10080 minutes", rows: rows), [])
    }
    func testLowerEffortBoundStillConjoinsDatesPriorityCompletionAndProject() throws {
        let base: [String: JSON] = ["duration_minutes": .number(60), "priority": .number(1), "due_date": .string("2032-04-05"), "project_id": .string("project")]
        var rows = [Record(base.merging(["id": .string("match")], uniquingKeysWith: { _, new in new }))]
        for (id, field, value) in [("short", "duration_minutes", JSON.number(59)), ("missing", "duration_minutes", .null), ("done", "completed", .bool(true)), ("priority", "priority", .number(2)), ("later", "due_date", .string("2032-04-06")), ("other", "project_id", .string("other"))] {
            rows.append(Record(base.merging(["id": .string(id), field: value], uniquingKeysWith: { _, new in new })))
        }
        XCTAssertEqual(try matches("Open priority 1 tasks planned today and taking at least one hour and in project Work", rows: rows), ["match"])
        XCTAssertEqual(try matches("Tasks taking at least one hour and taking at most one hour", rows: rows), ["match", "priority", "later", "other"])
    }
    func testLowerBoundsPreserveAlternativeAndExclusionGrouping() throws {
        let rows = [29, 30, 60, 61].map { Record(["id": .string("m\($0)"), "duration_minutes": .number(Double($0))]) } + [Record(["id": .string("missing")])]
        XCTAssertEqual(try matches("Open tasks taking at least one hour or taking under 30 minutes", rows: rows), ["m29", "m60", "m61"])
        XCTAssertEqual(try matches("Open tasks excluding those taking at least one hour", rows: rows), ["m29", "m30", "missing"])
    }
    func testLowerBoundPhrasesNeverDiscardAnIncompleteOrContradictorySuffix() {
        for goal in ["Tasks taking at least", "Tasks taking over one", "Tasks taking at least 0 minutes", "Tasks taking at least 169 hours", "Tasks taking at least 1.5 hours", "Tasks taking at least 30 minutes or less", "Tasks taking under 30 minutes or more", "Tasks taking at least 30 minutes approximately", "Tasks taking at least 30 minutes or tomorrow", "Tasks taking at least 30 days", "Tasks taking at least -1 minute"] {
            XCTAssertNil(LocalFilterDescription.expression(for: goal), goal)
        }
    }
    func testLongTaskDraftsUseLocalAssistanceWithoutInference() async throws {
        for goal in ["Open tasks taking at least one hour", "Tasks estimated over 30 minutes", "Tasks taking 60 minutes or longer"] {
            let draft = try await FilterAssistanceEngine.draft(goal)
            XCTAssertEqual(draft.origin, .localDescription)
            _ = try FilterSuggestion(expression: draft.expression, context: context())
        }
    }
    func testEffortRemainsConjoinedWithDatesPriorityCompletionAndProject() throws {
        let base: [String: JSON] = ["duration_minutes": .number(30), "priority": .number(1), "due_date": .string("2032-04-05"), "project_id": .string("project")]
        var rows = [Record(base.merging(["id": .string("match")], uniquingKeysWith: { _, new in new }))]
        for (id, field, value) in [("long", "duration_minutes", JSON.number(31)), ("missing", "duration_minutes", .null), ("done", "completed", .bool(true)), ("priority", "priority", .number(2)), ("later", "due_date", .string("2032-04-06")), ("other", "project_id", .string("other"))] {
            rows.append(Record(base.merging(["id": .string(id), field: value], uniquingKeysWith: { _, new in new })))
        }
        XCTAssertEqual(try matches("Open priority 1 tasks planned today and estimated at most 30 minutes and in project Work", rows: rows), ["match"])
    }
    func testAmbiguousOrUnsupportedEffortCannotSilentlyBecomeAnUpperBound() {
        for description in ["Tasks estimated at 30 minutes", "Tasks estimated 30 minutes", "Tasks taking 30 minutes", "Tasks estimated at most 0 minutes", "Tasks estimated under 1 minute", "Tasks estimated at most -5 minutes", "Tasks estimated at most 1.5 hours", "Tasks estimated at most 1 hour 30 minutes", "Tasks estimated at most 169 hours", "Tasks estimated at most 10081 minutes", "Tasks estimated at most 999999999999999999999999 hours", "Tasks estimated at most 30 days", "Tasks estimated at most 30", "Tasks estimated at most 30 minutes or tomorrow", "Tasks estimated at most 30 minutes approximately", "Tasks taking up to 30 minutes but not meetings", "Tasks in 30 minutes"] {
            XCTAssertNil(LocalFilterDescription.expression(for: description), description)
        }
    }
    func testAssignedByUsesRecordedActorRatherThanAuthorOrRecipient() throws {
        let me = "f01dcafe-8200-4000-8000-000000000001", other = "f01dcafe-8200-4000-8000-000000000002"
        let generation = "f01dcafe-8200-4000-8000-000000000020"
        let ids = (10...13).map { "f01dcafe-8200-4000-8000-0000000000\($0)" }
        let rows = ids.enumerated().map { index, id in Record(["id": .string(id), "user_id": .string(other), "assigned_to": index == 3 ? .null : .string(index == 0 ? other : me), "task_generation": .string(generation), "duration_minutes": .number(15)]) }
        let history = (0...1).map { index in Record(["id": .string(UUID().uuidString), "task_id": .string(ids[index]), "task_generation": .string(generation), "node_key": .string(""), "node_path": .array([]), "assignee_id": .string(index == 0 ? other : me), "actor_id": .string(index == 0 ? me : other), "event_id": .string(UUID().uuidString), "assigned_at": .string("2032-04-04T12:00:00Z"), "origin": .string("recorded"), "active": .bool(true)]) }
        let context = FilterContext(userID: me, people: [Record(["id": .string(other), "display_name": .string("Morgan Lee")])], assignments: .init(history))
        XCTAssertEqual(try matches("Open tasks assigned by me and estimated at most 30 minutes", rows: rows, context: context), [ids[0]])
        XCTAssertEqual(try matches("Open tasks assigned by others", rows: rows, context: context), [ids[1]])
        XCTAssertEqual(try matches("Open tasks assigned by \"Morgan Lee\"", rows: rows, context: context), [ids[1]])
        XCTAssertEqual(try matches("Open tasks assigned by unknown", rows: rows, context: context), [ids[2]])
        XCTAssertEqual(try matches("Open tasks assigned to me", rows: rows, context: context), [ids[1], ids[2]])
        XCTAssertEqual(try matches("Open tasks assigned by me or others", rows: rows, context: context), [ids[0], ids[1]])
        let unavailable = FilterContext(userID: me, assignments: .init(nil))
        XCTAssertThrowsError(try matches("Open tasks assigned by me", rows: rows, context: unavailable))
        XCTAssertNil(LocalFilterDescription.expression(for: "Open tasks assigned by unassigned"))
        XCTAssertNil(LocalFilterDescription.expression(for: "Open tasks assigned by Morgan Lee"))
        XCTAssertNil(LocalFilterDescription.expression(for: "Open tasks assigned by me to others"))
        XCTAssertNil(LocalFilterDescription.expression(for: "Open tasks assigned by me or tomorrow"))
        XCTAssertNil(LocalFilterDescription.expression(for: "Open tasks assigned by me or Morgan"))
    }
    func testEffortAndAssignmentDraftsUseLocalEngine() async throws {
        for goal in ["Open tasks estimated at most 30 minutes", "Open tasks assigned by me", "Tasks assigned by others and taking up to 1 hour"] {
            let draft = try await FilterAssistanceEngine.draft(goal)
            XCTAssertEqual(draft.origin, .localDescription, goal)
            XCTAssertNotNil(LocalFilterDescription.expression(for: goal))
        }
    }
    func testSpokenPriorityWordsAndExtremesDoNotBroadenMatches() throws {
        let rows = (1...4).map { Record(["id": .string("p\($0)"), "priority": .number(Double($0))]) }
        XCTAssertEqual(try matches("Only the highest priority open tasks", rows: rows), ["p1"])
        XCTAssertEqual(try matches("Only lowest priority open tasks", rows: rows), ["p4"])
        for (index, word) in ["one", "two", "three", "four"].enumerated() {
            XCTAssertEqual(try matches("Open items marked priority \(word)", rows: rows), ["p\(index + 1)"])
        }
        XCTAssertEqual(try matches("Open items with priority three or four", rows: rows), ["p3", "p4"])
    }
    func testParaphraseModifiersCannotSilentlyDiscardUnsupportedConditions() {
        for input in ["Only", "Anything", "Only highest tasks", "open tasks marked priority five", "open tasks marked priority highest", "unfinished under Work, also looking in archived projects", "unfinished under Work later", "open tasks with a deadline the current day or earlier", "open tasks scheduled for the current day or earlier with snooze", "open tasks scheduled for the current day or sometime"] {
            XCTAssertNil(LocalFilterDescription.expression(for: input), input)
        }
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
