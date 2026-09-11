import XCTest
import AppKit

final class TaskfoldMacUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func testTaskEntryIsExplicitAndFilterLivesAboveTasks() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--day-drag-fixture"]; app.launch()
        let filter = app.textFields["listFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        let sidebar = app.outlines["Sidebar"]
        XCTAssertFalse(sidebar.textFields["listFilter"].exists)
        XCTAssertFalse(app.textFields["quickAdd"].exists)
        app.buttons["addTask"].click()
        let input = app.textFields["quickAdd"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        app.typeText("Explicit entry task")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(input, timeout: 5))
        app.buttons["addTask"].click()
        XCTAssertEqual(input.value as? String, "Explicit entry task")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(input, timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "Explicit entry task", "Explicit entry task")).firstMatch.waitForExistence(timeout: 5))
        app.typeKey("f", modifierFlags: [.command, .shift])
        app.typeText("Today first")
        XCTAssertEqual(filter.value as? String, "Today first")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "Explicit entry task", "Explicit entry task")).firstMatch.exists)
    }

    /// Selecting a row and pressing Space completes it; ⌘Z brings it back through the system undo manager.
    @MainActor func testKeyboardCompletionAndUndo() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--day-drag-fixture"]; app.launch()
        let row = app.staticTexts["title-drag-fixture-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Fixture rows should appear\n" + app.debugDescription.prefix(6000))
        row.click()
        XCTAssertTrue(app.descendants(matching: .any)["taskTitle"].waitForExistence(timeout: 5), "Clicking a row should select it and show it in the inspector")
        sleep(2) // Let native selection appearance settle before the visual attachment.
        let contrast = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        contrast.name = "Selected row contrast"; contrast.lifetime = .keepAlways; add(contrast)
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

    /// A P3 task dragged above the P1 band lands at the top of its own band, not where the pointer was.
    @MainActor func testDropStaysInsidePriorityBand() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--priority-fixture"]; app.launch()
        let alpha = app.staticTexts["title-band-0"], beta = app.staticTexts["title-band-1"]
        let gamma = app.staticTexts["title-band-2"], delta = app.staticTexts["title-band-3"]
        XCTAssertTrue(delta.waitForExistence(timeout: 10))
        XCTAssertLessThan(beta.frame.minY, gamma.frame.minY, "Bands order P1 before P3")
        // Aim delta above the whole P1 band.
        delta.press(forDuration: 0.4, thenDragTo: alpha)
        sleep(1)
        XCTAssertGreaterThan(delta.frame.minY, beta.frame.minY, "The drop must stay below the P1 band")
        XCTAssertLessThan(delta.frame.minY, gamma.frame.minY, "Aimed above the band, the task lands at the top of its band")
        app.typeKey("z", modifierFlags: .command)
        sleep(1)
        XCTAssertGreaterThan(delta.frame.minY, gamma.frame.minY, "Undo restores the previous order in one step")
    }

    /// Declining the date chip keeps "tomorrow" in the title while the priority chip still applies.
    @MainActor func testDeclinedChipKeepsWordsInTitle() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--day-drag-fixture"]; app.launch()
        XCTAssertTrue(app.textFields["listFilter"].waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        let input = app.textFields["quickAdd"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        app.typeText("Call Sam tomorrow p1")
        XCTAssertTrue(app.buttons["decline-due_date"].waitForExistence(timeout: 5), "Date and priority chips appear while typing")
        XCTAssertTrue(app.buttons["decline-priority"].exists)
        app.buttons["decline-due_date"].click()
        XCTAssertTrue(waitForDisappearance(app.buttons["decline-due_date"], timeout: 3))
        XCTAssertTrue(app.buttons["decline-priority"].waitForExistence(timeout: 3), "Declining one group leaves the others")
        app.typeKey(.return, modifierFlags: [])
        let created = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "Call Sam tomorrow")).firstMatch
        XCTAssertTrue(created.waitForExistence(timeout: 5), "The declined words stay in the title")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "p1")).firstMatch.exists, "The accepted priority left the title")
    }

    @MainActor func testNavigationPreservesDraftAndSelection() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--day-drag-fixture"]; app.launch()
        let row = app.staticTexts["title-drag-fixture-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["taskTitle"].exists)
        row.click()
        XCTAssertTrue(app.descendants(matching: .any)["taskTitle"].waitForExistence(timeout: 5))
        app.typeKey("n", modifierFlags: .command)
        let input = app.textFields["quickAdd"]
        input.click(); input.typeText("Unfinished today draft")
        app.typeKey("2", modifierFlags: .command)
        app.typeKey("n", modifierFlags: .command)
        XCTAssertEqual(input.value as? String, "")
        input.click(); input.typeText("Unfinished inbox draft")
        app.typeKey("1", modifierFlags: .command)
        app.typeKey("n", modifierFlags: .command)
        XCTAssertEqual(input.value as? String, "Unfinished today draft")
        XCTAssertTrue(app.descendants(matching: .any)["taskTitle"].waitForExistence(timeout: 5))
        app.typeKey("2", modifierFlags: .command)
        app.typeKey("n", modifierFlags: .command)
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

    @MainActor func testFinderOpensCompletedTaskWithoutChangingListFilter() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--navigation-fixture"]; app.launch()
        XCTAssertTrue(app.textFields["listFilter"].waitForExistence(timeout: 10))
        app.typeKey("f", modifierFlags: [.command, .shift])
        app.typeText("Navigation task 003")
        app.typeKey("f", modifierFlags: .command)
        let finder = app.textFields["finderSearch"]
        XCTAssertTrue(finder.waitForExistence(timeout: 5))
        finder.typeText("Archived navigation target")
        app.typeKey(.return, modifierFlags: [])
        let title = app.descendants(matching: .any)["taskTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Archived navigation target")
        XCTAssertEqual(app.textFields["listFilter"].value as? String, "Navigation task 003")
        XCTAssertTrue(app.staticTexts["title-nav-3"].exists)
    }

    @MainActor func testFinderCancelRestoresDraftFocusAndProjectNavigation() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--navigation-fixture"]; app.launch()
        app.typeKey("n", modifierFlags: .command)
        let input = app.textFields["quickAdd"]
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.click(); input.typeText("Draft")
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.textFields["finderSearch"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(app.textFields["finderSearch"], timeout: 5))
        app.typeText(" continued")
        XCTAssertEqual(input.value as? String, "Draft continued")
        app.typeKey("f", modifierFlags: .command)
        let finder = app.textFields["finderSearch"]
        XCTAssertTrue(finder.waitForExistence(timeout: 5)); finder.typeText("Navigation Studio")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(finder, timeout: 5))
        XCTAssertFalse(input.exists)
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.placeholderValue, "Add a task to Navigation Studio")
    }

    @MainActor func testListScrollRestoresAcrossCalendarAndAfterDeletion() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--navigation-fixture"]; app.launch()
        let list = app.outlines["taskList"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let target = app.staticTexts["title-nav-40"]
        for _ in 0..<8 {
            if target.isHittable { break }
            list.scroll(byDeltaX: 0, deltaY: -400)
        }
        XCTAssertTrue(target.isHittable, "Long-list fixture should scroll to task 40")
        let beforeImage = app.windows.firstMatch.screenshot()
        let before = XCTAttachment(screenshot: beforeImage); before.name = "Before restore"; before.lifetime = .keepAlways; add(before)
        app.typeKey("4", modifierFlags: .command)
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.outlines["taskList"].waitForExistence(timeout: 5))
        let afterImage = app.windows.firstMatch.screenshot()
        let after = XCTAttachment(screenshot: afterImage); after.name = "After restore"; after.lifetime = .keepAlways; add(after)
        try assertSameListViewport(beforeImage, afterImage)
        target.click(); app.typeKey(.delete, modifierFlags: .command)
        XCTAssertTrue(waitForDisappearance(target, timeout: 5))
        let deletionImage = app.windows.firstMatch.screenshot()
        let deleted = XCTAttachment(screenshot: deletionImage); deleted.name = "After deletion"; deleted.lifetime = .keepAlways; add(deleted)
        let successor = app.staticTexts["title-nav-41"]
        XCTAssertTrue(successor.exists)
        app.typeKey("2", modifierFlags: .command)
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(successor.exists)
        let returnedImage = app.windows.firstMatch.screenshot()
        let returned = XCTAttachment(screenshot: returnedImage); returned.name = "Return after deletion"; returned.lifetime = .keepAlways; add(returned)
        try assertSameListViewport(deletionImage, returnedImage)
    }

    @MainActor func testFinderKeyboardSelectionAndCommand() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--navigation-fixture"]; app.launch()
        XCTAssertTrue(app.textFields["listFilter"].waitForExistence(timeout: 10))
        app.typeKey("f", modifierFlags: .command)
        let finder = app.textFields["finderSearch"]
        XCTAssertTrue(finder.waitForExistence(timeout: 5)); finder.typeText("Navigation task 00")
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        let title = app.descendants(matching: .any)["taskTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Navigation task 001")
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(finder.waitForExistence(timeout: 5)); finder.typeText("New Project")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.textFields["recordName"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
    }

    @MainActor func testCompletedFilterBelongsToItsDestination() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--navigation-fixture"]; app.launch()
        XCTAssertTrue(app.textFields["listFilter"].waitForExistence(timeout: 10))
        app.typeKey("5", modifierFlags: .command)
        let archived = app.staticTexts["title-nav-archived"]
        XCTAssertFalse(archived.exists)
        app.menuButtons["Task options"].click(); app.menuItems["Show Completed"].click()
        XCTAssertTrue(archived.waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertFalse(archived.exists, "Today should retain its own completed filter")
        app.typeKey("5", modifierFlags: .command)
        XCTAssertTrue(archived.waitForExistence(timeout: 5))
    }

    @MainActor func testAccountLoginAndTodoistAreReachableFromSidebar() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--day-drag-fixture"]; app.launch()
        let account = app.menuButtons["accountMenu"]
        XCTAssertTrue(account.waitForExistence(timeout: 10)); account.click()
        app.menuItems["Account…"].click()
        XCTAssertTrue(app.buttons["accountSignIn"].waitForExistence(timeout: 5))
        app.buttons["accountSignIn"].click()
        XCTAssertTrue(app.textFields["authEmail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["authPassword"].exists)
        XCTAssertTrue(app.buttons["googleSignIn"].exists)
        app.buttons["Close"].click()
        app.menuBars.menuBarItems["Account"].click()
        app.menuItems["Import from Todoist…"].click()
        XCTAssertTrue(app.descendants(matching: .any)["todoistImportSettings"].waitForExistence(timeout: 5))
        app.buttons["Sign In…"].click()
        XCTAssertTrue(app.textFields["authEmail"].waitForExistence(timeout: 5))
        app.buttons["Close"].click()
    }

    @MainActor func testPastingCommentImageSavesAttachmentAndPreservesText() throws {
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        } ?? []
        var lastChange = board.changeCount
        defer {
            if board.changeCount == lastChange {
                board.clearContents()
                let restored = saved.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item }
                board.writeObjects(restored)
            }
        }
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--day-drag-fixture"]; app.launch()
        let row = app.staticTexts["title-drag-fixture-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.click()
        let editor = app.textViews["commentEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let form = app.scrollViews.containing(.textView, identifier: "commentEditor").firstMatch
        for _ in 0..<5 { if editor.isHittable { break }; form.scroll(byDeltaX: 0, deltaY: -400) }
        editor.click(); editor.typeText("Keep this text")
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in NSColor.systemBlue.setFill(); rect.fill(); return true }
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        board.clearContents(); board.setData(png, forType: .png); lastChange = board.changeCount
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(app.buttons["commentImageAttachment"].waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Keep this text")
        board.clearContents(); board.setString(" and more", forType: .string); lastChange = board.changeCount
        app.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, "Keep this text and more")
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.click()
        XCTAssertTrue(app.buttons["commentImageAttachment"].waitForExistence(timeout: 5), "Image-only comment should be saved without submitting the text draft")
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

    /// NSTableView accessibility can return estimated/stale row frames after rebuilding.
    /// Compare the actual rendered task-text region, excluding toolbar and sidebar.
    private func assertSameListViewport(_ before: XCUIScreenshot, _ after: XCUIScreenshot,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let left = try XCTUnwrap(NSBitmapImageRep(data: before.pngRepresentation))
        let right = try XCTUnwrap(NSBitmapImageRep(data: after.pngRepresentation))
        XCTAssertEqual(left.pixelsWide, right.pixelsWide, file: file, line: line)
        XCTAssertEqual(left.pixelsHigh, right.pixelsHigh, file: file, line: line)
        guard left.pixelsWide == right.pixelsWide, left.pixelsHigh == right.pixelsHigh else { return }
        var ink = 0, different = 0
        for y in stride(from: left.pixelsHigh / 5, to: left.pixelsHigh * 9 / 10, by: 3) {
            for x in stride(from: left.pixelsWide / 3, to: left.pixelsWide * 7 / 10, by: 3) {
                guard let a = left.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let b = right.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if min(a.redComponent, a.greenComponent, a.blueComponent, b.redComponent, b.greenComponent, b.blueComponent) > 0.7 { continue }
                ink += 1
                if max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent)) > 0.08 { different += 1 }
            }
        }
        XCTAssertGreaterThan(ink, 100, "The comparison must include visible task text", file: file, line: line)
        XCTAssertLessThan(Double(different) / Double(max(ink, 1)), 0.08, "Returning should preserve the rendered list position", file: file, line: line)
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
