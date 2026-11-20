import XCTest
import AppKit

/// Child task rows (`tasks.parent_id`) on the Mac, driven through the isolated `--child-rows-fixture` workspace:
/// a project "Q4 offsite" with "Prepare the Q4 offsite" (children: Book the venue, dated today; Draft the agenda, dated
/// tomorrow, with two grandchildren; Send invitations) and a plain "Order catering".
/// Needs an unlocked Mac with accessibility granted to the test runner. Nothing here reaches the hosted project.
final class ChildRowsUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private let parent = "cr-parent", venue = "cr-venue", agenda = "cr-agenda", invite = "cr-invite"
    private let topics = "cr-topics", timebox = "cr-timebox", catering = "cr-catering"

    @MainActor private func launch(keep: Bool = false, replacing app: XCUIApplication = XCUIApplication()) -> XCUIApplication {
        app.launchArguments = ["--uitesting", "--child-rows-fixture"] + (keep ? ["--child-rows-keep"] : [])
        app.launch()
        return app
    }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func title(_ app: XCUIApplication) -> String { (element(app, "taskTitle").value as? String) ?? "" }
    @MainActor private func select(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.staticTexts["title-" + id]
        XCTAssertTrue(row.waitForExistence(timeout: 12), app.debugDescription, file: file, line: line)
        row.click()
        XCTAssertTrue(element(app, "taskTitle").waitForExistence(timeout: 6), "The inspector opens for the selected task", file: file, line: line)
    }
    /// Polls until the condition holds (the inspector and list update asynchronously).
    @MainActor private func eventually(_ timeout: TimeInterval = 6, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if condition() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        return condition()
    }
    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }

    /// Add: the inline field parses like Quick Add (a date word becomes the date) and the child joins the parent.
    @MainActor func testAddSubtaskFromInspector() throws {
        let app = launch(); defer { app.terminate() }
        select(app, catering)
        let field = element(app, "addSubtask")
        XCTAssertTrue(field.waitForExistence(timeout: 6)); field.click(); field.typeText("Print badges tomorrow\n")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", "Print badges", "Print badges")).firstMatch.waitForExistence(timeout: 6), "The new subtask row appears")
        XCTAssertTrue(element(app, "childSummary-" + catering).waitForExistence(timeout: 5), "The parent now counts its subtask")
    }

    /// Complete: the circle completes the subtask and the parent's progress follows.
    @MainActor func testCompleteChildFromInspector() throws {
        let app = launch(); defer { app.terminate() }
        select(app, parent)
        let circle = app.buttons["complete-" + invite]
        XCTAssertTrue(circle.waitForExistence(timeout: 6), app.debugDescription); circle.click()
        XCTAssertTrue(app.buttons["reopen-" + invite].waitForExistence(timeout: 6), "The subtask is completed")
        let summary = element(app, "childSummary-" + parent)
        XCTAssertTrue(eventually { summary.shownText.contains("1 of 5") }, "Parent progress reads 1 of 5, got \(summary.shownText)")
        shot(app, "Inspector with subtasks")
    }

    /// Open child, back, grandchild: a row opens its details, "‹ Parent" returns and the stack is two deep.
    @MainActor func testOpenChildBackAndGrandchild() throws {
        let app = launch(); defer { app.terminate() }
        select(app, parent)
        XCTAssertEqual(title(app), "Prepare the Q4 offsite")
        XCTAssertFalse(app.buttons["inspectorBack"].exists, "The parent has no back button")
        let child = element(app, "childRow-" + agenda)
        XCTAssertTrue(child.waitForExistence(timeout: 6)); child.click()
        XCTAssertTrue(app.buttons["inspectorBack"].waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertEqual(title(app), "Draft the agenda")
        XCTAssertTrue(app.buttons["subtaskOf"].exists, "A Subtask of link sits under the title")
        let grandchild = element(app, "childRow-" + topics)
        XCTAssertTrue(grandchild.waitForExistence(timeout: 6)); grandchild.click()
        XCTAssertTrue(eventually { self.title(app) == "Collect topics from the team" }, title(app))
        shot(app, "Child selected with the back stack")
        app.buttons["inspectorBack"].click()
        XCTAssertTrue(eventually { self.title(app) == "Draft the agenda" }, title(app))
        app.buttons["inspectorBack"].click()
        XCTAssertTrue(eventually { self.title(app) == "Prepare the Q4 offsite" }, title(app))
        XCTAssertFalse(app.buttons["inspectorBack"].exists, "Back at the parent the stack is empty")
        // The Subtask of link goes up too.
        element(app, "childRow-" + agenda).click()
        app.buttons["subtaskOf"].click()
        XCTAssertTrue(app.buttons["inspectorBack"].waitForExistence(timeout: 4))
    }

    /// Reorder: "Move Up" (the keyboard and VoiceOver route to the same move that drag uses) puts the last child first.
    @MainActor func testReorderSubtasks() throws {
        let app = launch(); defer { app.terminate() }
        select(app, parent)
        let last = element(app, "childRow-" + invite), first = element(app, "childRow-" + venue)
        XCTAssertTrue(last.waitForExistence(timeout: 6)); XCTAssertGreaterThan(last.frame.minY, first.frame.minY)
        last.rightClick()
        let up = app.menuItems["Move Up"]; XCTAssertTrue(up.waitForExistence(timeout: 4)); up.click()
        let second = element(app, "childRow-" + agenda)
        XCTAssertTrue(eventually { last.frame.minY < second.frame.minY }, "Send invitations moved above Draft the agenda")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(eventually { last.frame.minY > second.frame.minY }, "Undo restores the order")
    }

    /// Indent and outdent with ⌘] and ⌘[: the task nests under the one above it and comes back.
    @MainActor func testIndentAndOutdentWithShortcuts() throws {
        let app = launch(); defer { app.terminate() }
        select(app, catering)
        XCTAssertFalse(app.buttons["subtaskOf"].exists)
        app.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(app.buttons["subtaskOf"].waitForExistence(timeout: 6), "⌘] makes it a subtask of the task above\n" + app.debugDescription)
        XCTAssertEqual(app.buttons["subtaskOf"].label, "Subtask of Prepare the Q4 offsite")
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(eventually { !app.buttons["subtaskOf"].exists }, "⌘[ lifts it back to the list")
    }

    /// A child dated today shows in Today by its own date, with the "↳ Parent" line.
    @MainActor func testDatedChildInTodayShowsParentLine() throws {
        let app = launch(); defer { app.terminate() }
        let today = app.textNamed("Today").firstMatch
        XCTAssertTrue(today.waitForExistence(timeout: 12)); today.click()
        let row = app.staticTexts["title-" + venue]
        XCTAssertTrue(row.waitForExistence(timeout: 8), "The dated child is a row of its own in Today\n" + app.debugDescription)
        let line = element(app, "parentLine-" + venue)
        XCTAssertTrue(line.waitForExistence(timeout: 4)); XCTAssertTrue(line.shownText.contains("↳ Prepare the Q4 offsite"), line.shownText)
        XCTAssertFalse(app.staticTexts["title-" + agenda].exists, "The child dated tomorrow is not in Today")
        shot(app, "Today with a parent line")
    }

    /// A project nests children under their parent behind a disclosure triangle.
    @MainActor func testProjectListNestsChildren() throws {
        let app = launch(); defer { app.terminate() }
        let toggle = app.buttons["expand-" + parent]
        XCTAssertTrue(toggle.waitForExistence(timeout: 12))
        XCTAssertFalse(app.staticTexts["title-" + venue].exists, "Children start folded")
        toggle.click()
        XCTAssertTrue(app.staticTexts["title-" + venue].waitForExistence(timeout: 5))
        let nested = app.buttons["expand-" + agenda]
        XCTAssertTrue(nested.waitForExistence(timeout: 5)); nested.click()
        XCTAssertTrue(app.staticTexts["title-" + topics].waitForExistence(timeout: 5), "A grandchild nests one level further")
        XCTAssertGreaterThan(app.staticTexts["title-" + topics].frame.minX, app.staticTexts["title-" + agenda].frame.minX)
        shot(app, "Project with nested children")
    }

    /// Complete a parent: every open descendant completes in one step, and one Undo reopens them all.
    @MainActor func testCompleteParentThenUndo() throws {
        let app = launch(); defer { app.terminate() }
        select(app, parent)
        element(app, "taskComplete").click()
        XCTAssertTrue(app.buttons["reopen-" + venue].waitForExistence(timeout: 6), "Completing the parent completed its children\n" + app.debugDescription)
        XCTAssertTrue(app.buttons["reopen-" + invite].exists)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.buttons["complete-" + venue].waitForExistence(timeout: 6), "One Undo reopens the parent and every child")
        XCTAssertTrue(app.buttons["complete-" + invite].exists)
    }

    /// Delete a parent: the subtree goes with it, and one Undo brings the parent and its children back.
    @MainActor func testDeleteParentThenUndo() throws {
        let app = launch(); defer { app.terminate() }
        select(app, parent)
        app.menuButtons["taskMoreMenu"].firstMatch.click()
        let delete = app.menuItems["taskDelete"].firstMatch.exists ? app.menuItems["taskDelete"].firstMatch : app.menuItems["Delete Task…"]
        XCTAssertTrue(delete.waitForExistence(timeout: 4)); delete.click()
        let confirm = app.sheets.buttons["Delete"].firstMatch.exists ? app.sheets.buttons["Delete"].firstMatch : app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 4)); confirm.click()
        XCTAssertTrue(app.staticTexts["title-" + parent].waitForNonExistence(timeout: 8), "The parent is deleted")
        let today = app.textNamed("Today").firstMatch; today.click()
        XCTAssertTrue(app.staticTexts["title-" + venue].waitForNonExistence(timeout: 6), "The dated child went with its parent")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["title-" + venue].waitForExistence(timeout: 8), "Undo restores the child")
        app.textNamed("Q4 offsite").firstMatch.click()
        XCTAssertTrue(app.staticTexts["title-" + parent].waitForExistence(timeout: 6), "Undo restores the parent")
    }

    /// Relaunch: a subtask added in one launch is still under its parent in the next.
    @MainActor func testSubtaskSurvivesRelaunch() throws {
        let app = launch()
        select(app, catering)
        let field = element(app, "addSubtask")
        XCTAssertTrue(field.waitForExistence(timeout: 6)); field.click(); field.typeText("Confirm dietary needs\n")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", "Confirm dietary", "Confirm dietary")).firstMatch.waitForExistence(timeout: 6))
        app.terminate()
        _ = launch(keep: true, replacing: app); defer { app.terminate() }
        let toggle = app.buttons["expand-" + catering]
        XCTAssertTrue(toggle.waitForExistence(timeout: 12), "The reloaded list shows Order catering as a parent\n" + app.debugDescription)
        toggle.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", "Confirm dietary", "Confirm dietary")).firstMatch.waitForExistence(timeout: 6))
    }
}
