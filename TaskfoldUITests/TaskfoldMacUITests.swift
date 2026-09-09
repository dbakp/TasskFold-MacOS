import XCTest

final class TaskfoldMacUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Selecting a row and pressing Space completes it; ⌘Z brings it back through the system undo manager.
    @MainActor func testKeyboardCompletionAndUndo() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--day-drag-fixture"]; app.launch()
        let row = app.staticTexts["Today first"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(row, timeout: 5), "Space should complete the selected task and remove it from Today")
        XCTAssertTrue(app.buttons["undoConfirmation"].waitForExistence(timeout: 2))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "⌘Z should reopen the task")
    }

    /// Dragging a task from Today onto Tomorrow reschedules it, preserving day placement, and it survives relaunch.
    @MainActor func testDayToDayDrag() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--day-drag-fixture"]; app.launch()
        app.typeKey("3", modifierFlags: .command) // Upcoming
        let source = app.staticTexts["Today last"]
        let target = app.staticTexts["Tomorrow sample"]
        XCTAssertTrue(source.waitForExistence(timeout: 10)); XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertLessThan(source.frame.minY, target.frame.minY)
        source.press(forDuration: 0.4, thenDragTo: target)
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(source.frame.minY, target.frame.minY, "The dragged task should now sit inside Tomorrow, below the task it was dropped onto")
        app.typeKey("1", modifierFlags: .command) // Today
        XCTAssertTrue(waitForDisappearance(app.staticTexts["Today last"], timeout: 5))
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Tomorrow sample"].waitForExistence(timeout: 10))
        XCTAssertGreaterThan(app.staticTexts["Today last"].frame.minY, app.staticTexts["Tomorrow sample"].frame.minY)
    }

    /// Renders the report screenshots. Set TASKFOLD_SCREENSHOT_DIR to write PNGs to a folder.
    @MainActor func testCaptureScreenshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["TASKFOLD_SCREENSHOT_DIR"] else { throw XCTSkip("Screenshot directory not requested") }
        let shots: [(String, [String])] = [
            ("today-light", ["--preview", "--section=today", "--appearance=light", "--select-title=Make time for the big idea"]),
            ("today-dark", ["--preview", "--section=today", "--appearance=dark", "--select-title=Make time for the big idea"]),
            ("upcoming-light", ["--preview", "--section=upcoming", "--appearance=light"]),
            ("calendar-week-light", ["--preview", "--section=calendar", "--calendar-mode=week", "--appearance=light", "--select-title=Review the onboarding flow"]),
            ("calendar-month-dark", ["--preview", "--section=calendar", "--calendar-mode=month", "--appearance=dark"]),
            ("calendar-year-light", ["--preview", "--section=calendar", "--calendar-mode=year", "--appearance=light"]),
        ]
        for (name, arguments) in shots {
            let app = XCUIApplication(); app.launchArguments = arguments; app.launch()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
            sleep(2)
            let png = app.windows.firstMatch.screenshot().pngRepresentation
            try png.write(to: URL(fileURLWithPath: directory).appending(path: "\(name).png"))
            app.terminate()
        }
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
