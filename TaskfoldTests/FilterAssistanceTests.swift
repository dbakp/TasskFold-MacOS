import XCTest
@testable import TaskfoldCore

final class FilterAssistanceTests: XCTestCase {
    private func context() -> FilterContext {
        FilterContext(projects: [Record(["id": .string("project-a"), "name": .string("Work"), "user_id": .string("owner")])],
            labels: [Record(["id": .string("label-a"), "name": .string("Focus")])], userID: "owner", collaborators: [])
    }
    func testGeneratedGrammarUsesOrdinaryMatchingWithoutChangingTasks() throws {
        let c = context(), p = try FilterSuggestion(expression: "(today OR overdue) AND p1 AND open", context: c)
        let tasks = [Record(["id": .string("today"), "due_date": .string("2026-11-05"), "priority": .number(1)]),
            Record(["id": .string("old"), "due_date": .string("2026-11-04"), "priority": .number(1)]),
            Record(["id": .string("later"), "due_date": .string("2026-11-06"), "priority": .number(1)]),
            Record(["id": .string("done"), "due_date": .string("2026-11-05"), "priority": .number(1), "completed": .bool(true)])]
        XCTAssertEqual(tasks.filter { p.rule.resultMatches($0, context: c, today: "2026-11-05", timeZone: "UTC") }.map(\.id), ["today", "old"])
        XCTAssertEqual(tasks.count, 4)
        XCTAssertTrue(AuthoredValueComparison.exactJSON(p.rule.document, try p.revalidated(in: c).rule.document))
    }
    func testPriorityComparisonsMatchCanonicalPredicatesAndRejectOtherNumbers() throws {
        for level in 1...4 {
            let canonical = try FilterSuggestion(expression: "p" + String(level), context: context())
            for spelling in ["priority=" + String(level), "priority:" + String(level), "PRIORITY=" + String(level), "priority " + String(level)] {
                let proposal = try FilterSuggestion(expression: spelling, context: context())
                XCTAssertTrue(AuthoredValueComparison.exactJSON(proposal.rule.document, canonical.rule.document), spelling)
            }
        }
        for expression in ["priority=0", "priority=5", "priority=-1", "priority=1.0", "priority=11", "priority=", "priority=1x", "priority 0", "priority 5", "priority 11", "priority", #""priority=1""#] {
            XCTAssertThrowsError(try FilterSuggestion(expression: expression, context: context()), expression)
        }
        let c = context(), query = try FilterSuggestion(expression: "(today OR overdue) AND priority=1 AND open", context: c)
        XCTAssertTrue(query.rule.resultMatches(Record(["due_date": .string("2032-04-04"), "priority": .number(1)]), context: c, today: "2032-04-05", timeZone: "UTC"))
        XCTAssertFalse(query.rule.resultMatches(Record(["due_date": .string("2032-04-04"), "priority": .number(3)]), context: c, today: "2032-04-05", timeZone: "UTC"))
    }
    func testKnownFieldPrefixesCanOmitColonWithoutChangingTheirStoredMeaning() throws {
        let cases = [("deadline today", "deadline:today"), ("project Work", "project:Work"), ("project-tree Work", "project-tree:Work"), ("date tomorrow", "date:tomorrow"), ("date before tomorrow", "date before:tomorrow"), ("time after 14:00", "time after:14:00"), ("created today", "created:today"), ("project matching W*", "project matching:W*"), ("label Focus", "label:Focus"), (#"search "priority 1""#, #"search:"priority 1""#)]
        for (words, colon) in cases {
            let a = try FilterSuggestion(expression: words, context: context())
            let b = try FilterSuggestion(expression: colon, context: context())
            XCTAssertTrue(AuthoredValueComparison.exactJSON(a.rule.document, b.rule.document), words)
        }
        for input in ["project AND open", "deadline OR today", "search", "date before", #""deadline today""#] {
            XCTAssertThrowsError(try FilterSuggestion(expression: input, context: context()), input)
        }
    }
    func testPlannedAndScheduledDateQualifiersRetainTheOriginalPlannedMeaning() throws {
        for day in ["today", "overdue"] {
            let canonical = try FilterSuggestion(expression: day, context: context())
            for qualifier in ["planned", "scheduled"] {
                let proposal = try FilterSuggestion(expression: qualifier + " " + day, context: context())
                XCTAssertTrue(AuthoredValueComparison.exactJSON(proposal.rule.document, canonical.rule.document))
            }
        }
        let (c, today, rows, _) = qualityFixture()
        let proposal = try FilterSuggestion(expression: "open AND priority 1 AND (planned today OR overdue)", context: c)
        XCTAssertEqual(rows.filter { proposal.rule.resultMatches($0, context: c, today: today, timeZone: "UTC") }.map(\.id), ["today", "old"])
        let literal = try FilterSuggestion(expression: #"search:"planned today priority 1""#, context: c)
        XCTAssertTrue(literal.rule.resultMatches(Record(["title": .string("planned today priority 1"), "priority": .number(4)]), context: c, today: today, timeZone: "UTC"))
        XCTAssertThrowsError(try FilterSuggestion(expression: #""planned today""#, context: c))
    }
    func testPriorityComparisonInsideQuotedTargetsAndSearchStaysLiteral() throws {
        var c = context(); c.projects.append(Record(["id": .string("literal"), "name": .string("priority=1")]))
        let project = try FilterSuggestion(expression: #"project:"priority=1""#, context: c)
        XCTAssertTrue(project.rule.resultMatches(Record(["project_id": .string("literal"), "priority": .number(4)]), context: c, today: "2032-04-05", timeZone: "UTC"))
        let search = try FilterSuggestion(expression: #"search:"priority=1""#, context: c)
        XCTAssertTrue(search.rule.resultMatches(Record(["title": .string("Check priority=1"), "priority": .number(4)]), context: c, today: "2032-04-05", timeZone: "UTC"))
        XCTAssertFalse(search.rule.resultMatches(Record(["title": .string("Other work"), "priority": .number(1)]), context: c, today: "2032-04-05", timeZone: "UTC"))
    }
    func testMalformedOrOversizedOutputNeverBecomesAFilter() {
        for input in ["", "today AND", "SELECT * FROM tasks", "```today```", "open\0", String(repeating: "x", count: 4001)] {
            XCTAssertThrowsError(try FilterSuggestion(expression: input, context: context()), input.prefix(30).description)
        }
        XCTAssertNoThrow(try FilterSuggestion(expression: "today\nAND\topen", context: context()))
    }
    func testExactDraftAndWorkspaceSessionBinding() {
        let w = WorkspaceBinding(account: "owner", generation: UUID()), session = UUID()
        let source = JSON.object(["name": .string("Cafe\u{301}"), "opaque": .array([.number(-0.0), .object(["keep": .bool(true)])])])
        let request = FilterAssistanceRequest(workspace: w, session: session, source: source, expression: "today", includeCompleted: false)
        XCTAssertTrue(request.matches(source, workspace: w, session: session))
        var changed = source.object; changed["name"] = .string("Caf\u{e9}")
        XCTAssertFalse(request.matches(.object(changed), workspace: w, session: session))
        XCTAssertFalse(request.matches(source, workspace: .init(account: "other", generation: w.generation), session: session))
        XCTAssertFalse(request.matches(source, workspace: .init(account: "owner", generation: UUID()), session: session))
        XCTAssertFalse(request.matches(source, workspace: w, session: UUID()))
    }
    func testProjectNameCannotRetargetToDifferentIdentity() throws {
        let c = context(), p = try FilterSuggestion(expression: "project:Work", context: c)
        var changed = c; changed.projects[0]["id"] = .string("project-b")
        XCTAssertThrowsError(try p.revalidated(in: changed))
        changed = c; changed.projects.append(Record(["id": .string("other"), "name": .string("Work")]))
        XCTAssertThrowsError(try p.revalidated(in: changed))
        changed = c; changed.projects = []
        XCTAssertThrowsError(try p.revalidated(in: changed))
    }
    func testDuplicateIDsAndUnavailableProjectsRefusePreview() throws {
        var c = context(); c.projects.append(c.projects[0])
        XCTAssertThrowsError(try FilterSuggestion(expression: "project:project-a", context: c))
        c = context(); c.projects[0]["is_archived"] = .bool(true)
        XCTAssertThrowsError(try FilterSuggestion(expression: "project:project-a", context: c))
    }
    func testWildcardScopesRequireNewPreviewWhenTheirTargetsChange() throws {
        let c = context(), p = try FilterSuggestion(expression: "#W*", context: c)
        var unrelated = c; unrelated.projects.append(Record(["id": .string("other"), "name": .string("Home")]))
        XCTAssertNoThrow(try p.revalidated(in: unrelated))
        var changed = c; changed.projects.append(Record(["id": .string("other"), "name": .string("Workshop")]))
        XCTAssertThrowsError(try p.revalidated(in: changed))
        changed = c; changed.projects[0]["name"] = .string("Workshop")
        XCTAssertThrowsError(try p.revalidated(in: changed))
    }
    func testPatternAvailabilityAndSectionParentChangesRequireReview() throws {
        var c = context()
        let project = try FilterSuggestion(expression: "#W*", context: c)
        var changed = c; changed.projects[0]["is_archived"] = .bool(true)
        XCTAssertThrowsError(try project.revalidated(in: changed))
        c.sections = [Record(["id": .string("section"), "name": .string("Design"), "project_id": .string("project-a")])]
        let section = try FilterSuggestion(expression: "/D*", context: c)
        changed = c; changed.sections[0]["project_id"] = .string("other-project")
        XCTAssertThrowsError(try section.revalidated(in: changed))
    }
    func testDescendantScopeAndLabelIdentityStayBound() throws {
        var c = context(); c.projects.append(Record(["id": .string("child"), "name": .string("Child"), "parent_id": .string("project-a")]))
        let tree = try FilterSuggestion(expression: "project-tree:Work", context: c)
        var changed = c; changed.projects[1]["parent_id"] = .null
        XCTAssertThrowsError(try tree.revalidated(in: changed))
        let label = try FilterSuggestion(expression: "label:Focus", context: c)
        changed = c; changed.labels[0]["id"] = .string("replacement")
        XCTAssertThrowsError(try label.revalidated(in: changed))
    }
    func testKnownPeopleOnlyAndScopedRenameRefusal() throws {
        let id = "11111111-1111-4111-8111-111111111111"
        var c = context()
        XCTAssertThrowsError(try FilterSuggestion(expression: "assignee:" + id, context: c))
        c.people = [Record(["id": .string(id), "display_name": .string("Amy"), "project_id": .string("project-a")])]
        let p = try FilterSuggestion(expression: "assignee:Amy", context: c)
        var changed = c; changed.people[0]["project_id"] = .string("other-project")
        XCTAssertThrowsError(try p.revalidated(in: changed))
        changed = c; changed.people[0]["display_name"] = .string("A different person")
        XCTAssertThrowsError(try p.revalidated(in: changed))
        XCTAssertNoThrow(try FilterSuggestion(expression: "assignee:me", context: c))
    }
    func testPeopleReadsAreRequestedOnlyForDirectoryDependentQueries() throws {
        let c = context()
        for query in ["today AND p1", "inbox", "assigned", "assignee:me", "assignee:unassigned"] {
            XCTAssertFalse(try FilterSuggestion(expression: query, context: c).needsPeopleDirectory, query)
        }
        XCTAssertTrue(try FilterSuggestion(expression: "assignee:A*", context: c).needsPeopleDirectory)
        do { _ = try FilterSuggestion(expression: "assignee:Amy", context: c); XCTFail("Unloaded name resolved") }
        catch { XCTAssertEqual((error as? FilterFailure)?.needsPeopleDirectory, true) }
    }
    func testKnownEmailWithFallbackNameRemainsAnExactTarget() throws {
        var c = context()
        c.people = [Record(["id": .string("11111111-1111-4111-8111-111111111111"), "display_name": .string("amy@example.test"), "email": .string("amy@example.test"), "display_name_is_fallback": .bool(true), "project_id": .string("project-a")])]
        let p = try FilterSuggestion(expression: "assignee:amy@example.test", context: c)
        XCTAssertTrue(p.needsPeopleDirectory)
        XCTAssertNoThrow(try p.revalidated(in: c))
        var changed = c; changed.people[0]["id"] = .string("22222222-2222-4222-8222-222222222222")
        XCTAssertThrowsError(try p.revalidated(in: changed))
    }
    func testRelativeDatePreferencesStayReviewed() throws {
        let c = context(), p = try FilterSuggestion(expression: "date:\"next week\"", context: c)
        var changed = c; changed.datePreferences = DatePhrasePreferences(nextWeek: 3)
        XCTAssertThrowsError(try p.revalidated(in: changed))
        let ordinary = try FilterSuggestion(expression: "p1", context: c)
        XCTAssertNoThrow(try ordinary.revalidated(in: changed))
    }
    func testAsyncInputFenceDistinguishesHydrationAndExactAuthoredChanges() {
        let c = context()
        XCTAssertTrue(FilterSuggestion.sameInputs(c, c))
        var changed = c; changed.collaborators = nil
        XCTAssertFalse(FilterSuggestion.sameInputs(c, changed))
        changed = c; changed.projects[0]["extension"] = .bool(true)
        XCTAssertFalse(FilterSuggestion.sameInputs(c, changed))
        changed = c; changed.userID = "other"
        XCTAssertFalse(FilterSuggestion.sameInputs(c, changed))
    }
    func testCancelledAndSupersededRunsCannotReturn() {
        let request = FilterAssistanceRequest(workspace: .init(account: "owner", generation: UUID()), session: UUID(), source: .null, expression: "", includeCompleted: false)
        var run = FilterAssistanceRun(request: request)
        let old = run.begin()!; run.stop(); XCTAssertFalse(run.accepts(old))
        let current = run.begin()!; XCTAssertFalse(run.accepts(old)); XCTAssertTrue(run.accepts(current))
        run.close(); XCTAssertFalse(run.accepts(current)); XCTAssertNil(run.begin())
    }
    func testBackgroundPreparationAndReviewedRevalidation() async throws {
        let c = context(), p = try await FilterSuggestion.prepare("label:Focus AND open", context: c)
        let current = try await FilterSuggestion.prepare(p.expression, context: c, reviewed: p)
        XCTAssertTrue(AuthoredValueComparison.exactJSON(p.rule.document, current.rule.document))
        let cancelled = Task { () throws -> FilterSuggestion in
            while !Task.isCancelled { await Task.yield() }
            return try await FilterSuggestion.prepare("today", context: c)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled preparation returned") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testCancelledGenerationStopsBeforeInputOrAvailabilityChecks() async throws {
        for input in ["", "Prepare a workshop"] {
            let worker = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await FilterAssistanceEngine.generate(input)
            }
            do { _ = try await worker.value; XCTFail("A cancelled request returned suggestions") }
            catch { XCTAssertTrue(error is CancellationError, "Cancellation must win over input or availability: \(error)") }
        }
    }
    private func qualityFixture() -> (FilterContext, String, [Record], [(String, [String], String, String)]) {
        // A future reference day catches invented absolute dates for "today".
        let today = "2032-04-05"
        var modelContext = context()
        modelContext.projects.append(Record(["id": .string("child-project"), "name": .string("Workshop"), "parent_id": .string("project-a"), "user_id": .string("owner")]))
        let rows = [
            Record(["id": .string("today"), "project_id": .string("project-a"), "due_date": .string(today), "deadline_date": .string("2032-04-06"), "priority": .number(1)]),
            Record(["id": .string("old"), "project_id": .string("project-a"), "due_date": .string("2032-04-04"), "priority": .number(1)]),
            Record(["id": .string("deadline"), "project_id": .string("project-a"), "due_date": .string("2032-04-06"), "deadline_date": .string(today), "priority": .number(1)]),
            Record(["id": .string("low"), "due_date": .string(today), "priority": .number(3)]),
            Record(["id": .string("done"), "project_id": .string("project-a"), "due_date": .string(today), "priority": .number(1), "completed": .bool(true)]),
            Record(["id": .string("child-project-task"), "project_id": .string("child-project"), "due_date": .string("2032-04-06"), "priority": .number(1)]),
            Record(["id": .string("old-low"), "due_date": .string("2032-04-04"), "priority": .number(3)]),
            Record(["id": .string("future-low"), "due_date": .string("2032-04-06"), "priority": .number(3)]),
            Record(["id": .string("done-low"), "due_date": .string(today), "priority": .number(3), "completed": .bool(true)]),
            // Distinguish required open AND p1 from the plausible but wrong
            // open OR p1 on an otherwise matching deadline.
            Record(["id": .string("deadline-low"), "due_date": .string("2032-04-08"), "deadline_date": .string("2032-04-06"), "priority": .number(3)]),
            Record(["id": .string("deadline-done"), "due_date": .string("2032-04-08"), "deadline_date": .string("2032-04-06"), "priority": .number(1), "completed": .bool(true)])
        ]
        let cases: [(String, [String], String, String)] = [
            ("Show open priority 1 tasks planned today or overdue", ["today", "old"], "(today OR overdue) AND p1 AND open", "today OR overdue OR p1"),
            ("Show tasks with a deadline today", ["deadline"], "deadline:today", "today"),
            ("Show unfinished tasks in project Work", ["today", "old", "deadline"], "project:\"Work\" AND open", "project-tree:\"Work\" AND open"),
            ("Find unfinished priority 3 tasks planned for today", ["low"], "today AND p3 AND open", "today AND p1 AND open"),
            ("Find open work in project Work, including its subprojects", ["today", "old", "deadline", "child-project-task"], "project-tree:\"Work\" AND open", "project:\"Work\" AND open"),
            ("Find unfinished priority 3 tasks planned for tomorrow", ["future-low"], "date:tomorrow AND p3 AND open", "date:tomorrow AND p1 AND open"),
            ("Show completed priority 3 tasks", ["done-low"], "completed AND p3", "open AND p3"),
            ("Find open priority 1 tasks planned tomorrow in project Work and its child projects", ["deadline", "child-project-task"], "date:tomorrow AND p1 AND project-tree:Work AND open", "date:tomorrow AND p1 AND project:Work AND open"),
            ("Show open tasks in project Work, excluding those planned today", ["old", "deadline"], "project:Work AND open AND NOT today", "project:Work AND open AND today"),
            ("Show open tasks planned today with priority 1 or priority 3", ["today", "low"], "today AND (p1 OR p3) AND open", "today AND p1 AND open"),
            ("Find open priority 1 tasks with a deadline tomorrow", ["today"], "deadline:tomorrow AND p1 AND open", "date:tomorrow AND p1 AND open"),
            ("Show open tasks planned before today", ["old", "old-low"], "date before:today AND open", "deadline before:today AND open")
        ]
        return (modelContext, today, rows, cases)
    }
    func testModelQualityOracleDistinguishesPlannedDateDeadlineAndExactProject() throws {
        let (modelContext, today, rows, cases) = qualityFixture()
        for (goal, expected, correct, incorrect) in cases {
            let intended = try FilterSuggestion(expression: correct, context: modelContext)
            let wrong = try FilterSuggestion(expression: incorrect, context: modelContext)
            XCTAssertEqual(rows.filter { intended.rule.resultMatches($0, context: modelContext, today: today, timeZone: "UTC") }.map(\.id), expected, goal)
            XCTAssertNotEqual(rows.filter { wrong.rule.resultMatches($0, context: modelContext, today: today, timeZone: "UTC") }.map(\.id), expected, "A plausible wrong expression must fail the oracle: " + goal)
        }
    }
    func testLocalDescriptionsMatchFullSemanticOracleWithoutInference() async throws {
        let (context, today, rows, cases) = qualityFixture()
        for (goal, expected, _, _) in cases {
            _ = try XCTUnwrap(LocalFilterDescription.expression(for: goal), goal)
            let draft = try await FilterAssistanceEngine.draft(goal)
            XCTAssertEqual(draft.origin, .localDescription)
            let suggestion = try FilterSuggestion(expression: draft.expression, context: context)
            XCTAssertEqual(rows.filter { suggestion.rule.resultMatches($0, context: context, today: today, timeZone: "UTC") }.map(\.id), expected, goal)
        }
    }
    func testActualOnDeviceFilterEngineWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["TASKFOLD_TEST_ON_DEVICE_MODEL"] == "1" else { throw XCTSkip("Actual model probe is opt-in.") }
        if let reason = OnDeviceAssistance.unavailableReason {
            print("FILTER_ASSISTANCE_MODEL_UNAVAILABLE " + reason); throw XCTSkip(reason)
        }
        let (modelContext, today, rows, cases) = qualityFixture()
        var allAccepted = true
        for (goal, expected, _, _) in cases {
            let start = ContinuousClock.now
            var generated: String?
            do {
                let text = try await FilterAssistanceEngine.generateModel(goal)
                generated = text
                let duration = start.duration(to: .now).components
                let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                print("TASKFOLD_MODEL_RAW_EXPRESSION " + text)
                let suggestion = try FilterSuggestion(expression: text, context: modelContext)
                let matches = rows.filter { suggestion.rule.resultMatches($0, context: modelContext, today: today, timeZone: "UTC") }.map(\.id)
                let observation: [String: Any] = ["engine": "filter", "generationPath": "systemModel", "syntheticGoal": goal, "seconds": seconds, "expression": text, "matchedIDs": matches, "expectedIDs": expected]
                print("TASKFOLD_MODEL_OBSERVATION " + String(data: try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys]), encoding: .utf8)!)
                if matches != expected { allAccepted = false }
                XCTAssertEqual(matches, expected, "The generated query must mean what was requested: " + text)
            } catch {
                allAccepted = false
                let duration = start.duration(to: .now).components
                let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                var observation: [String: Any] = ["engine": "filter", "generationPath": "systemModel", "syntheticGoal": goal, "seconds": seconds, "expectedIDs": expected, "error": String(describing: error)]
                if let generated { observation["expression"] = generated }
                print("TASKFOLD_MODEL_OBSERVATION " + String(data: try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys]), encoding: .utf8)!)
                XCTFail("The actual model did not return a usable query: " + String(describing: error))
            }
        }
        if allAccepted { print("FILTER_ASSISTANCE_MODEL_ACCEPTED twelve semantic samples; no saved-filter or task writes") }
    }
}
