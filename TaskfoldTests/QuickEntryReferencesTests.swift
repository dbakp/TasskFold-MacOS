import XCTest
@testable import TaskfoldCore

final class QuickEntryReferencesTests: XCTestCase {
    private func row(_ id: String, _ name: String, project: String = "") -> Record {
        Record(["id": .string(id), "name": .string(name), "project_id": .string(project)])
    }
    private func person(_ id: String, _ name: String, status: String = "accepted") -> Record {
        Record(["id": .string(id), "display_name": .string(name), "status": .string(status)])
    }
    private var context: QuickEntryContext {
        QuickEntryContext(projects: [row("work", "Client Work"), row("home", "Home")],
            sections: [row("next", "Next steps", project: "work"), row("home-next", "Next steps", project: "home")],
            labels: [row("client-label", "Client notes")], members: ["work": [person("alex", "Alex Morgan"), person("self", "Morgan Lee")]],
            currentUser: "self")
    }
    func testQuotedReferencesAndPlanningResolveTogether() {
        let parsed = QuickEntry(#"Draft proposal #"Client Work" /"Next steps" +Alex @"Client notes" tomorrow p2 ~25m {2026-10-09}"#,
            now: Dates.parse("2026-10-05")!, context: context)
        XCTAssertEqual(parsed.title, "Draft proposal")
        XCTAssertEqual(parsed.updates["project_id"], .string("work"))
        XCTAssertEqual(parsed.updates["section_id"], .string("next"))
        XCTAssertEqual(parsed.updates["assigned_to"], .string("alex"))
        XCTAssertEqual(parsed.updates["labels"], .array([.string("Client notes")]))
        XCTAssertEqual(parsed.updates["due_date"], .string("2026-10-06"))
        XCTAssertEqual(parsed.updates["duration_minutes"], .number(25))
        XCTAssertEqual(parsed.updates["deadline_date"], .string("2026-10-09"))
        XCTAssertTrue(parsed.warnings.isEmpty)
        XCTAssertEqual(parsed.applying(to: Record.task(user: "self"))["labels"], .array([.string("client-label")]))
    }
    func testUnknownExplicitTargetsCannotTurnIntoPlanningFields() {
        let parsed = QuickEntry("Write #project:tomorrow /p1 +tomorrow", context: context)
        XCTAssertEqual(parsed.title, "Write #project:tomorrow /p1 +tomorrow")
        XCTAssertTrue(parsed.updates.isEmpty)
        XCTAssertFalse(parsed.warnings.isEmpty)
    }
    func testProjectLabelCollisionRequiresExplicitChoiceAndLegacyLabelsRemain() {
        var ctx = context; ctx.labels.append(row("home-label", "Home"))
        let collision = QuickEntry("Tidy #Home", context: ctx)
        XCTAssertEqual(collision.title, "Tidy #Home"); XCTAssertTrue(collision.updates.isEmpty)
        XCTAssertEqual(collision.warnings.count, 1)
        let explicit = QuickEntry("Tidy #project:Home @Home #errands %mail", context: ctx)
        XCTAssertEqual(explicit.title, "Tidy")
        XCTAssertEqual(explicit.updates["project_id"], .string("home"))
        XCTAssertEqual(explicit.updates["labels"], .array([.string("Home"), .string("errands"), .string("mail")]))
    }
    func testAmbiguousOrMultipleProjectsNeverChooseFirst() {
        var ctx = context; ctx.projects.append(row("work-2", "Client Work"))
        let duplicate = QuickEntry(#"Write #"Client Work" /"Next steps" +Alex"#, context: ctx)
        XCTAssertTrue(duplicate.updates.isEmpty)
        XCTAssertFalse(duplicate.warnings.isEmpty)
        let multiple = QuickEntry(#"Write #"Client Work" #Home"#, context: context)
        XCTAssertTrue(multiple.updates.isEmpty)
    }
    func testSectionsAreScopedToTheSelectedProject() {
        var ctx = context; ctx.currentProject = "home"
        XCTAssertEqual(QuickEntry(#"Tidy /"Next steps""#, context: ctx).updates["section_id"], .string("home-next"))
        let noProject = QuickEntry(#"Tidy /"Next steps""#, context: context)
        XCTAssertNil(noProject.updates["section_id"]); XCTAssertFalse(noProject.warnings.isEmpty)
    }
    func testAssigneesAreScopedAndAmbiguousNamesOrPendingInvitesStayLiteral() {
        var ctx = context; ctx.currentProject = "work"
        XCTAssertEqual(QuickEntry("Draft +me", context: ctx).updates["assigned_to"], .string("self"))
        ctx.members["work"]?.append(person("alex-2", "Alex Chen"))
        ctx.members["work"]?.append(person("pending", "Pat", status: "pending"))
        XCTAssertNil(QuickEntry("Draft +Alex", context: ctx).updates["assigned_to"])
        XCTAssertEqual(QuickEntry(#"Draft +"Alex Morgan""#, context: ctx).updates["assigned_to"], .string("alex"))
        XCTAssertNil(QuickEntry("Draft +Pat", context: ctx).updates["assigned_to"])
        ctx.currentProject = "home"
        XCTAssertNil(QuickEntry("Draft +Alex", context: ctx).updates["assigned_to"])
    }
    func testDeclinedProjectAlsoKeepsDependentTargetsAndNeverBecomesALabel() {
        let input = #"Draft #"Client Work" /"Next steps" +Alex tomorrow"#
        let parsed = QuickEntry(input, now: Dates.parse("2026-10-05")!, disabled: ["project_id"], context: context)
        XCTAssertEqual(parsed.title, #"Draft #"Client Work" /"Next steps" +Alex"#)
        XCTAssertNil(parsed.updates["project_id"]); XCTAssertNil(parsed.updates["section_id"])
        XCTAssertNil(parsed.updates["assigned_to"]); XCTAssertNil(parsed.updates["labels"])
        XCTAssertEqual(parsed.updates["due_date"], .string("2026-10-06"))
        let all = QuickEntry(input, disabled: Set(QuickEntry.groups), context: context)
        XCTAssertEqual(all.title, input); XCTAssertTrue(all.updates.isEmpty)
    }
    func testEscapedAndQuotedLiteralsAndNonReferenceBoundaries() {
        let escaped = QuickEntry(##"Write \#"Client Work" \/"Next steps" \+Alex \@"Client notes""##, context: context)
        XCTAssertEqual(escaped.title, #"Write #"Client Work" /"Next steps" +Alex @"Client notes""#)
        XCTAssertTrue(escaped.updates.isEmpty)
        XCTAssertTrue(QuickEntry(##"Write "#Home +Alex tomorrow p1""##, context: context).updates.isEmpty)
        let literal = "Use https://example.com/#Home /tmp/file #Client/Next C++ mail+Alex@example.com"
        XCTAssertEqual(QuickEntry(literal, context: context).title, literal)
        XCTAssertTrue(QuickEntry(literal, context: context).updates.isEmpty)
        XCTAssertEqual(QuickEntry("Look at").title, "Look at")
    }
    func testMovingProjectsClearsOldAssignmentsAndMergesLabelsWithoutDuplicateIDs() {
        var task = Record.task(user: "self", project: "home")
        task["section_id"] = .string("home-next"); task["assigned_to"] = .string("old")
        task["deadline_date"] = .string("2026-10-09"); task["duration_minutes"] = .number(25)
        task["labels"] = .array([.string("client-label"), .string("keep")])
        task["subtasks"] = .array([.object(["title": .string("Child"), "assigned_to": .string("old")])])
        let result = QuickEntry(#"Draft #"Client Work" /"Next steps" +Alex @"client notes""#, context: context).applying(to: task)
        XCTAssertEqual(result.string("project_id"), "work"); XCTAssertEqual(result.string("section_id"), "next")
        XCTAssertEqual(result.string("assigned_to"), "alex"); XCTAssertEqual(result["subtasks"].list[0].object["assigned_to"], .null)
        XCTAssertEqual(result["labels"], task["labels"])
        XCTAssertEqual(result["deadline_date"], task["deadline_date"]); XCTAssertEqual(result["duration_minutes"], task["duration_minutes"])
        let withoutDestination = QuickEntry(#"Draft #"Client Work""#, context: context).applying(to: task)
        XCTAssertEqual(withoutDestination["section_id"], .null); XCTAssertEqual(withoutDestination["assigned_to"], .null)
    }
    func testDuplicateTokensHaveStableUniqueIdentifiers() {
        let parsed = QuickEntry("Draft @mail @mail %mail #errands", context: context)
        XCTAssertEqual(parsed.title, "Draft")
        XCTAssertEqual(parsed.updates["labels"], .array([.string("mail"), .string("errands")]))
        XCTAssertEqual(Set(parsed.tokens.map(\.id)).count, parsed.tokens.count)
    }
    func testLabelNormalizationIsStableAcrossRenameAndKeepsUnknownLegacyValues() {
        let labels = [row("id-one", "Client notes"), row("id-two", "Other")]
        let normalized = TaskLabels.normalized([.string("Client notes"), .string("id-one"), .string("legacy"), .object(["old": .bool(true)])], labels: labels)
        XCTAssertEqual(normalized, [.string("id-one"), .string("legacy"), .object(["old": .bool(true)])])
        var renamed = labels; renamed[0]["name"] = .string("Renamed")
        XCTAssertEqual(TaskLabels.normalized(normalized, labels: renamed), normalized)
        XCTAssertEqual(TaskLabels.normalized(normalized, labels: []), normalized)
        XCTAssertEqual(TaskLabels.normalized([.string("duplicate")], labels: [row("a", "duplicate"), row("b", "duplicate")]), [.string("duplicate")])
    }
    func testLabelNamesAndIDsRemainDistinctDuringReferenceResolution() {
        var ctx = context
        XCTAssertTrue(QuickEntry("Draft @client-label", context: ctx).updates.isEmpty)
        ctx.labels.append(row("another", "client-label"))
        var task = Record.task(user: "self"); task["labels"] = .array([.string("client-label")])
        let result = QuickEntry("Draft @client-label", context: ctx).applying(to: task)
        XCTAssertEqual(result["labels"], .array([.string("client-label"), .string("another")]))
    }
}
