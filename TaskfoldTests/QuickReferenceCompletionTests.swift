import XCTest
@testable import TaskfoldCore

final class QuickReferenceCompletionTests: XCTestCase {
    func context() -> QuickEntryContext {
        QuickEntryContext(projects: [Record(["id": .string("work"), "name": .string("Client Work")]), Record(["id": .string("home"), "name": .string("Home")]), Record(["id": .string("archived"), "name": .string("Client archive"), "is_archived": .bool(true)])], sections: [Record(["id": .string("next"), "name": .string("Next steps"), "project_id": .string("work")]), Record(["id": .string("other"), "name": .string("Next steps"), "project_id": .string("home")])], labels: [Record(["id": .string("notes"), "name": .string("Client notes")]), Record(["id": .string("home-label"), "name": .string("Home")])], members: ["work": [Record(["id": .string("alex"), "display_name": .string("Alex Morgan"), "status": .string("accepted")]), Record(["id": .string("pending"), "display_name": .string("Alex Pending"), "status": .string("pending")])]], currentProject: "", currentUser: "alex")
    }
    func testProjectAndLabelCollisionShowsExplicitChoices() {
        let result = QuickReferenceCompletion("Plan #ho", context: context())
        XCTAssertEqual(result.options.map(\.group), ["labels", "project_id"])
        XCTAssertEqual(Set(result.options.map(\.reference)), ["@\"Home\"", "#project:\"Home\""])
        let option = result.options.first { $0.group == "project_id" }!
        let chosen = result.choosing(option, in: "Plan #ho")!
        var c = context(); c.referenceChoices[option.reference] = option.recordID
        let parsed = QuickEntry(chosen.text, context: c)
        XCTAssertEqual(parsed.title, "Plan"); XCTAssertEqual(parsed.updates["project_id"], .string("home")); XCTAssertTrue(parsed.warnings.isEmpty)
    }
    func testPartialQuotedNamesAndUnicodeCursorPreserveSuffix() {
        let input = "☎️ Review #\"Client W\" tomorrow p1"
        let caret = (input as NSString).range(of: "W\"").location + 1
        let result = QuickReferenceCompletion(input, caretUTF16: caret, context: context())
        let chosen = result.choosing(result.options[0], in: input)!
        XCTAssertEqual(chosen.text, "☎️ Review #project:\"Client Work\" tomorrow p1")
        XCTAssertEqual((chosen.text as NSString).substring(from: chosen.caretUTF16), " tomorrow p1")
        let parsed = QuickEntry(chosen.text, context: context())
        XCTAssertEqual(parsed.title, "☎️ Review"); XCTAssertEqual(parsed.updates["project_id"], .string("work")); XCTAssertEqual(parsed.updates["priority"], .number(1))
    }
    func testLiteralURLMailArithmeticAndEscapesNeverOfferReferences() {
        for text in ["https://site.test/#ho", "name@exa", "work/path", "2+al", "\\#ho", "Say \"#ho", "Say \"@Client\"", "\\@Client", "\\/Ne", "\\+Al"] {
            XCTAssertNil(QuickReferenceCompletion(text, context: context()).range, text)
        }
    }
    func testInvalidCursorAndUnrelatedWordsAreIgnored() {
        for caret in [-1, 500] { XCTAssertNil(QuickReferenceCompletion("Plan #", caretUTF16: caret, context: context()).range) }
        XCTAssertNil(QuickReferenceCompletion("Plan ordinary", context: context()).range)
        XCTAssertNil(QuickReferenceCompletion("Plan @\"Client notes\" ", context: context()).range)
        let split = QuickReferenceCompletion("😀 #ho", caretUTF16: 1, context: context()); XCTAssertNil(split.range)
    }
    func testScopedSectionsAndMembersFollowAcceptedProject() {
        let c = context()
        XCTAssertEqual(QuickReferenceCompletion("Plan #project:\"Client Work\" /Ne", context: c).options.map(\.recordID), ["next"])
        XCTAssertEqual(QuickReferenceCompletion("Plan #project:\"Client Work\" +Al", context: c).options.map(\.recordID), ["alex"])
        XCTAssertTrue(QuickReferenceCompletion("Plan /Ne", context: c).options.isEmpty)
        XCTAssertTrue(QuickReferenceCompletion("Plan +Al", context: c).options.isEmpty)
        XCTAssertTrue(QuickReferenceCompletion("Plan #project:\"Client Work\" /Ne", context: c, disabled: ["project_id"]).options.isEmpty)
    }
    func testAmbiguousProjectDoesNotLeakScope() {
        var c = context(); c.currentProject = "home"
        c.projects.append(Record(["id": .string("second-work"), "name": .string("Client Work")]))
        XCTAssertTrue(QuickReferenceCompletion("Plan #project:\"Client Work\" /Ne", context: c).options.isEmpty)
        c.referenceChoices["#project:\"Client Work\""] = "work"
        XCTAssertEqual(QuickReferenceCompletion("Plan #project:\"Client Work\" /Ne", context: c).options.map(\.recordID), ["next"])
    }
    func testDuplicateNamesResolveOnlyExplicitCurrentIdentity() {
        var c = context()
        c.projects.append(Record(["id": .string("second-work"), "name": .string("Client Work"), "description": .string("Archived client's new work")]))
        let result = QuickReferenceCompletion("Plan #Cli", context: c)
        XCTAssertEqual(result.options.filter { $0.group == "project_id" }.count, 2)
        let selected = result.options.first { $0.recordID == "work" }!
        c.referenceChoices[selected.reference] = selected.recordID
        let parsed = QuickEntry(result.choosing(selected, in: "Plan #Cli")!.text, context: c)
        XCTAssertEqual(parsed.updates["project_id"], .string("work")); XCTAssertEqual(parsed.title, "Plan")
        c.projects.removeAll { $0.id == "work" }
        let unavailable = QuickEntry("Plan " + selected.reference, context: c)
        XCTAssertNil(unavailable.updates["project_id"]); XCTAssertTrue(unavailable.title.contains("Client Work")); XCTAssertFalse(unavailable.warnings.isEmpty)
    }
    func testChosenLabelsUseIDsAndCannotRecreateDeletedLabels() {
        var c = context(); c.labels.append(Record(["id": .string("other-notes"), "name": .string("Client notes")]))
        c.referenceChoices["@\"Client notes\""] = "notes"
        let parsed = QuickEntry("Plan @\"Client notes\"", context: c)
        XCTAssertEqual(parsed.updates["labels"], .array([.string("notes")]))
        XCTAssertEqual(parsed.tokens.first { $0.group == "labels" }?.label, "Client notes")
        XCTAssertEqual(parsed.applying(to: Record.task(user: "owner")).fields["labels"]?.list.map(\.text), ["notes"])
        c.labels.removeAll { $0.id == "notes" }
        let missing = QuickEntry("Plan @\"Client notes\"", context: c)
        XCTAssertNil(missing.updates["labels"]); XCTAssertEqual(missing.title, "Plan @\"Client notes\"")
    }
    func testMemberRevocationAndProjectChangeInvalidateChoices() {
        var c = context(); c.currentProject = "work"; c.referenceChoices["+\"Alex Morgan\""] = "alex"
        XCTAssertEqual(QuickEntry("Plan +\"Alex Morgan\"", context: c).updates["assigned_to"], .string("alex"))
        c.members["work"]![0]["status"] = .string("revoked")
        XCTAssertNil(QuickEntry("Plan +\"Alex Morgan\"", context: c).updates["assigned_to"])
        c.currentProject = "home"
        XCTAssertNil(QuickEntry("Plan +\"Alex Morgan\"", context: c).updates["assigned_to"])
    }
    func testDecliningChosenReferenceRetainsExactLiteral() {
        var c = context(); c.referenceChoices["#project:\"Client Work\""] = "work"
        let input = "Plan #project:\"Client Work\" tomorrow"
        let parsed = QuickEntry(input, disabled: ["project_id"], context: c)
        XCTAssertNil(parsed.updates["project_id"]); XCTAssertEqual(parsed.title, "Plan #project:\"Client Work\"")
    }
    func testChosenSectionsCannotFollowAnotherProject() {
        var c = context(); c.referenceChoices["/\"Next steps\""] = "next"; c.currentProject = "work"
        XCTAssertEqual(QuickEntry("Plan /\"Next steps\"", context: c).updates["section_id"], .string("next"))
        c.currentProject = "home"
        XCTAssertNil(QuickEntry("Plan /\"Next steps\"", context: c).updates["section_id"])
    }
    func testSearchRankingAndBlankPrefixesRemainDeterministic() {
        var c = context(); c.labels.append(Record(["id": .string("client"), "name": .string("Notes Client")]))
        XCTAssertEqual(QuickReferenceCompletion("Plan @cli", context: c).options.map(\.recordID), ["notes", "client"])
        XCTAssertEqual(QuickReferenceCompletion("Plan #", context: c).options.count, 5)
        XCTAssertFalse(QuickReferenceCompletion("Plan @unknown", context: c).options.contains { $0.name == "unknown" })
    }
    func testStaleCompletionCannotReplaceNewText() {
        let result = QuickReferenceCompletion("Plan #Ho", context: context())
        XCTAssertNil(result.choosing(result.options[0], in: "Changed #Ho"))
    }
    func testReferenceChoiceLeavesOtherGroupsAvailableToDecline() {
        var c = context(); c.referenceChoices["#project:\"Client Work\""] = "work"
        let disabled = Set(QuickEntry.groups).subtracting(["project_id", "section_id", "assigned_to", "labels"])
        let parsed = QuickEntry("Plan #project:\"Client Work\" tomorrow p1", disabled: disabled, context: c)
        XCTAssertEqual(parsed.title, "Plan tomorrow p1"); XCTAssertEqual(parsed.updates["project_id"], .string("work")); XCTAssertNil(parsed.updates["due_date"]); XCTAssertNil(parsed.updates["priority"])
    }

    func testCursorInsidePathDoesNotReplaceItsSuffix() {
        let input = "Plan #Home/path tomorrow"
        let caret = (input as NSString).range(of: "/path").location
        XCTAssertNil(QuickReferenceCompletion(input, caretUTF16: caret, context: context()).range)
        let active = QuickReferenceCompletion("Plan #Ho", context: context())
        let parsed = QuickEntry("Plan #Ho", disabled: active.literalGroups, context: context())
        XCTAssertEqual(parsed.title, "Plan #Ho"); XCTAssertNil(parsed.updates["labels"]); XCTAssertNil(parsed.updates["project_id"])
    }

    func testDeclinedDifferentProjectBlocksDependentSuggestions() {
        var c = context(); c.currentProject = "home"
        XCTAssertTrue(QuickEntry("Plan #project:\"Client Work\"", disabled: ["project_id"], context: c).referenceProjectBlocked)
        XCTAssertTrue(QuickReferenceCompletion("Plan #project:\"Client Work\" /Ne", context: c, disabled: ["project_id"]).options.isEmpty)
        XCTAssertEqual(QuickReferenceCompletion("Plan #project:\"Home\" /Ne", context: c, disabled: ["project_id"]).options.map(\.recordID), ["other"])
    }

    func testSingleReturnIsDistinctFromMultilinePasteOrOrdinaryTyping() {
        XCTAssertEqual(QuickReferenceCompletion.returnInsertion(before: "Plan #Ho", after: "Plan #Ho\n"), 8)
        XCTAssertEqual(QuickReferenceCompletion.returnInsertion(before: "☎️ Plan #Ho tomorrow", after: "☎️ Plan #Ho\n tomorrow"), ("☎️ Plan #Ho" as NSString).length)
        XCTAssertNil(QuickReferenceCompletion.returnInsertion(before: "Plan", after: "Plan\nAnother task"))
        XCTAssertNil(QuickReferenceCompletion.returnInsertion(before: "Plan", after: "Plans"))
        XCTAssertNil(QuickReferenceCompletion.returnInsertion(before: "Plan", after: "Plan\r\n"))
    }

}
