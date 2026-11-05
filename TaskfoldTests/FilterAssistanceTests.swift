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
    func testActualOnDeviceFilterEngineWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["TASKFOLD_TEST_ON_DEVICE_MODEL"] == "1" else { throw XCTSkip("Actual model probe is opt-in.") }
        if let reason = OnDeviceAssistance.unavailableReason {
            print("FILTER_ASSISTANCE_MODEL_UNAVAILABLE " + reason); throw XCTSkip(reason)
        }
        let text = try await FilterAssistanceEngine.generate("Show unfinished high-priority tasks planned today or overdue")
        _ = try FilterSuggestion(expression: text, context: context())
        print("FILTER_ASSISTANCE_MODEL_ACCEPTED synthetic input; no saved-filter or task writes")
    }
}
