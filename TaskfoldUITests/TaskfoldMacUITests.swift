import XCTest

final class TaskfoldMacUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Selecting a row and pressing Space completes it; ⌘Z brings it back through the system undo manager.
    @MainActor func testKeyboardCompletionAndUndo() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--day-drag-fixture"]; app.launch()
        let row = app.staticTexts["title-drag-fixture-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Fixture rows should appear\n" + app.debugDescription.prefix(6000))
        row.click()
        XCTAssertTrue(app.descendants(matching: .any)["taskTitle"].waitForExistence(timeout: 5), "Clicking a row should select it and show it in the inspector")
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(row, timeout: 5), "Space should complete the selected task and remove it from Today; quick add value: \(String(describing: app.textFields["quickAdd"].value))")
        XCTAssertTrue(app.descendants(matching: .any)["undoConfirmation"].waitForExistence(timeout: 2))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "⌘Z should reopen the task")
    }

    /// Dragging a task from Today onto Tomorrow reschedules it, preserving day placement, and it survives relaunch.
    @MainActor func testDayToDayDrag() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--day-drag-fixture"]; app.launch()
        app.typeKey("3", modifierFlags: .command) // Upcoming
        let source = app.staticTexts["title-drag-fixture-2"]
        let target = app.staticTexts["title-drag-fixture-3"]
        XCTAssertTrue(source.waitForExistence(timeout: 10), "Fixture rows should appear\n" + app.debugDescription.prefix(6000)); XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertLessThan(source.frame.minY, target.frame.minY)
        source.press(forDuration: 0.4, thenDragTo: target)
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let tomorrowHeader = app.descendants(matching: .any)["day-" + formatter.string(from: Calendar.current.date(byAdding: .day, value: 1, to: Date())!)]
        XCTAssertTrue(tomorrowHeader.waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertGreaterThan(source.frame.minY, tomorrowHeader.frame.minY, "The dragged task should now sit inside Tomorrow\n" + app.debugDescription.components(separatedBy: "\n").filter { $0.contains("title-drag") || $0.contains("day-") }.joined(separator: "\n"))
        app.typeKey("1", modifierFlags: .command) // Today
        XCTAssertTrue(waitForDisappearance(app.staticTexts["title-drag-fixture-2"], timeout: 5))
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["title-drag-fixture-3"].waitForExistence(timeout: 10))
        XCTAssertGreaterThan(app.staticTexts["title-drag-fixture-2"].frame.minY, app.staticTexts["title-drag-fixture-3"].frame.minY)
    }

    @MainActor func testNavigationPreservesDraftAndSelection() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--day-drag-fixture"]; app.launch()
        let row = app.staticTexts["title-drag-fixture-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["taskTitle"].exists)
        row.click()
        XCTAssertTrue(app.descendants(matching: .any)["taskTitle"].waitForExistence(timeout: 5))
        let input = app.textFields["quickAdd"]
        input.click(); input.typeText("Unfinished today draft")
        app.typeKey("2", modifierFlags: .command)
        XCTAssertEqual(input.value as? String, "")
        input.click(); input.typeText("Unfinished inbox draft")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertEqual(input.value as? String, "Unfinished today draft")
        XCTAssertTrue(app.descendants(matching: .any)["taskTitle"].waitForExistence(timeout: 5))
        app.typeKey("2", modifierFlags: .command)
        XCTAssertEqual(input.value as? String, "Unfinished inbox draft")
    }

    @MainActor func testInlineDateChangeAndUndo() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--day-drag-fixture"]; app.launch()
        let row = app.staticTexts["title-drag-fixture-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        app.menuButtons["actions-drag-fixture-1"].click()
        app.menuItems["Change Date…"].click()
        XCTAssertTrue(app.buttons["Tomorrow"].waitForExistence(timeout: 5))
        app.buttons["Tomorrow"].click()
        XCTAssertTrue(waitForDisappearance(row, timeout: 5))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    /// Renders the report screenshots into the runner's temporary directory (printed in the log) when
    /// TEST_RUNNER_TASKFOLD_SCREENSHOTS=1 is passed to xcodebuild.
    @MainActor func testCaptureScreenshots() throws {
        guard ProcessInfo.processInfo.environment["TASKFOLD_SCREENSHOTS"] == "1" else { throw XCTSkip("Screenshots not requested") }
        let directory = FileManager.default.temporaryDirectory.appending(path: "taskfold-screenshots").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        print("TASKFOLD_SCREENSHOT_DIR=\(directory)")
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
