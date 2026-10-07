import XCTest
import AppKit

final class TaskfoldMacUITests: XCTestCase {
    @MainActor func testOpenListAndFilterPreviewRefreshWithCivilClockEvents() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--calendar-context-testing"]; app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["Complete Yesterday plan"].waitForExistence(timeout: 10))
        func advance(_ action: String, editor: Bool = false) { app.buttons[editor ? "calendarEditorFixtureClock" : "calendarFixtureClock"].click(); app.menuItems[action].click() }
        advance("Fixture silent next day")
        XCTAssertTrue(app.buttons["Complete Today plan A"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["Complete Fixed Copenhagen plan"].exists); XCTAssertFalse(app.buttons["Complete Yesterday plan"].exists)
        advance("Fixture Honolulu")
        XCTAssertTrue(app.buttons["Complete Yesterday plan"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["Complete Fixed Copenhagen plan"].exists); XCTAssertFalse(app.buttons["Complete Today plan A"].exists)
        let view = app.staticTexts["Live calendar"].firstMatch; view.rightClick(); app.menuItems["Edit filter"].click()
        app.descendants(matching: .any)["advancedFilter"].click()
        let expression = app.textFields["filterExpression"]; app.buttons["clearFilterExpression"].click(); expression.click(); expression.typeText("effective-due:today")
        let preview = app.descendants(matching: .any)["filterPreviewCount"].firstMatch
        XCTAssertEqual(preview.value as? String, "3")
        advance("Prepare fixture resume", editor: true); app.typeKey("h", modifierFlags: .command); app.activate()
        let value = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "4"), object: preview)
        XCTAssertEqual(XCTWaiter.wait(for: [value], timeout: 5), .completed)
        XCTAssertEqual(expression.value as? String, "effective-due:today")
        XCTAssertEqual(app.staticTexts["calendarEditorFixtureDataStatus"].label, "Workspace unchanged")
        app.buttons["Cancel"].click(); XCTAssertTrue(app.buttons["Complete Today plan A"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["Complete Today deadline"].exists)
    }

    @MainActor func testFocusFinishAlertPreferencePauseResumeAndRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--focus-session-seed", "--focus-finish-testing"]; app.launch()
        XCTAssertTrue(app.buttons["openFocusSession"].waitForExistence(timeout: 10)); app.buttons["openFocusSession"].click()
        let toggle = app.descendants(matching: .any).matching(identifier: "focusAlerts").firstMatch
        for _ in 0..<5 where !toggle.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -400) }
        XCTAssertTrue(toggle.isHittable); toggle.click()
        if app.alerts.buttons["Allow"].waitForExistence(timeout: 3) { app.alerts.buttons["Allow"].click() }
        let picker = app.descendants(matching: .any).matching(identifier: "focusTaskPicker").firstMatch
        for _ in 0..<5 where !picker.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 400) }
        picker.click(); app.menuItems["Focus on the next useful step"].click(); app.buttons["startFocus"].click()
        func pending(_ count: Int) {
            let refresh = app.buttons["focusRefreshAlerts"]
            for _ in 0..<5 where !refresh.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -400) }
            refresh.click()
            XCTAssertTrue(app.staticTexts["Pending Focus alerts: \(count)"].waitForExistence(timeout: 5))
        }
        pending(1)
        let pause = app.buttons["pauseResumeFocus"]
        for _ in 0..<5 where !pause.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 400) }
        pause.click(); pending(0)
        for _ in 0..<5 where !pause.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 400) }
        pause.click(); pending(1)
        app.terminate(); app.launchArguments = ["--uitesting", "--focus-finish-testing"]; app.launch()
        XCTAssertTrue(app.buttons["openFocusSession"].waitForExistence(timeout: 10)); app.buttons["openFocusSession"].click(); pending(1); app.terminate()
    }
    @MainActor func testFocusPauseResumeEndAndRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--focus-session-seed"]; app.launch()
        XCTAssertTrue(app.buttons["openFocusSession"].waitForExistence(timeout: 10)); app.buttons["openFocusSession"].click()
        let picker = app.descendants(matching: .any).matching(identifier: "focusTaskPicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10)); picker.click(); app.menuItems["Focus on the next useful step"].click(); app.buttons["startFocus"].click()
        XCTAssertTrue(app.staticTexts["focusStatus"].waitForExistence(timeout: 5)); app.buttons["pauseResumeFocus"].click()
        XCTAssertEqual(app.staticTexts["focusStatus"].label, "Paused"); let remaining = app.staticTexts["focusRemaining"].label
        app.buttons["closeFocusSession"].click(); app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        let open = app.buttons["openFocusSession"]; XCTAssertTrue(open.waitForExistence(timeout: 10)); open.click()
        XCTAssertEqual(app.staticTexts["focusStatus"].label, "Paused"); XCTAssertEqual(app.staticTexts["focusRemaining"].label, remaining)
        app.buttons["pauseResumeFocus"].click(); XCTAssertEqual(app.staticTexts["focusStatus"].label, "Time to focus")
        app.buttons["endFocus"].click(); XCTAssertEqual(app.staticTexts["focusStatus"].label, "Session ended"); app.terminate()
    }
    @MainActor func testPlanningSuggestionsKeyboardCaptureAndRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--quick-entry-fixture"]; app.launch(); app.typeKey("n", modifierFlags: .command)
        let input = app.textFields["quickAdd"]; XCTAssertTrue(input.waitForExistence(timeout: 5)); input.click(); input.typeText("Planned conversation tom")
        XCTAssertTrue(app.buttons["referenceSuggestion-due_date:planning:tomorrow"].waitForExistence(timeout: 5)); app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue((input.value as? String ?? "").contains("tomorrow")); input.typeText("every d")
        app.buttons["referenceSuggestion-recurrence:planning:every day"].click(); input.typeText("!30mb"); app.buttons["referenceSuggestion-reminder_specs:planning:!30mb"].click(); app.buttons["Add Task"].click()
        XCTAssertTrue(app.staticTexts["Planned conversation"].waitForExistence(timeout: 5)); app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(app.staticTexts["Planned conversation"].waitForExistence(timeout: 5)); app.terminate()
    }

    @MainActor func testReferenceSuggestionsKeyboardCaptureAndRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--quick-entry-fixture"]; app.launch()
        app.typeKey("n", modifierFlags: .command)
        let input = app.textFields["quickAdd"]; XCTAssertTrue(input.waitForExistence(timeout: 5)); input.click(); input.typeText("Suggested proposal #Cli")
        XCTAssertTrue(app.buttons["referenceSuggestion-project_id:qe-work"].waitForExistence(timeout: 5))
        app.typeKey(.downArrow, modifierFlags: []); app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue((input.value as? String ?? "").contains("Client Work")); XCTAssertTrue(app.buttons["Add Task"].exists)
        input.typeText("/Ne"); app.buttons["referenceSuggestion-section_id:qe-next"].click()
        input.typeText("@Cli"); app.buttons["referenceSuggestion-labels:qe-client-label"].click()
        app.buttons["Add Task"].click(); app.buttons["Client Work"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Suggested proposal"].waitForExistence(timeout: 5)); app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        app.buttons["Client Work"].firstMatch.click(); XCTAssertTrue(app.staticTexts["Suggested proposal"].waitForExistence(timeout: 5)); app.terminate()
    }

    @MainActor func testNamedRepeatBoundariesCaptureInspectorAndRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--quick-entry-fixture"]; app.launch(); app.typeKey("n", modifierFlags: .command)
        let input = app.textFields["quickAdd"]; XCTAssertTrue(input.waitForExistence(timeout: 5)); input.click()
        let name = "Boundary review " + String(UUID().uuidString.prefix(6))
        input.typeText(name + " every day from 3 January 2028 until 5 January 2028 for 3 occurrences {6 January 2028} ~25m")
        let summary = app.staticTexts["quickRepeatSummary"]; XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("2028-01-05")); XCTAssertTrue(summary.label.contains("3 left"))
        app.buttons["Add Task"].click(); app.buttons["Inbox"].firstMatch.click(); XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5)); app.staticTexts[name].click()
        let link = app.disclosureTriangles["taskRepeat"]
        for _ in 0..<8 where !link.isHittable { app.scrollViews.element(boundBy: max(0, app.scrollViews.count - 1)).swipeUp() }
        XCTAssertTrue(link.isHittable); link.click(); XCTAssertTrue(app.staticTexts["repeatRuleSummary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["repeatRuleSummary"].label.contains("2028-01-05")); XCTAssertTrue(app.staticTexts["repeatRuleSummary"].label.contains("3 left"))
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch(); XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5)); app.staticTexts[name].click()
        for _ in 0..<8 where !link.isHittable { app.scrollViews.element(boundBy: max(0, app.scrollViews.count - 1)).swipeUp() }; if link.isHittable { link.click() }
        XCTAssertTrue(app.staticTexts["repeatRuleSummary"].waitForExistence(timeout: 5)); XCTAssertTrue(app.staticTexts["repeatRuleSummary"].label.contains("2028-01-05")); app.terminate()
    }

    @MainActor func testRecurrenceCaptureInspectorAndRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--quick-entry-fixture"]; app.launch()
        app.typeKey("n", modifierFlags: .command)
        let input = app.textFields["quickAdd"]; XCTAssertTrue(input.waitForExistence(timeout: 5)); input.click()
        let name = "Studio review " + String(UUID().uuidString.prefix(6))
        input.typeText(name + " every 2 months on last friday starting 2027-01-01 until 2027-06-30 for 3 occurrences")
        XCTAssertTrue(app.staticTexts["quickRepeatSummary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["quickRepeatSummary"].label.contains("Last Friday"))
        app.buttons["Add Task"].click(); app.buttons["Inbox"].firstMatch.click()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5)); app.staticTexts[name].click()
        let link = app.disclosureTriangles["taskRepeat"]
        for _ in 0..<8 where !link.isHittable { app.scrollViews.element(boundBy: max(0, app.scrollViews.count - 1)).swipeUp() }
        XCTAssertTrue(link.isHittable); link.click()
        XCTAssertTrue(app.staticTexts["repeatRuleSummary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["repeatRuleSummary"].label.contains("3 left"))
        app.buttons["Today"].firstMatch.click(); app.terminate(); app.launchArguments = ["--uitesting", "--section=inbox"]; app.launch()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5)); app.staticTexts[name].click()
        for _ in 0..<8 where !link.isHittable { app.scrollViews.element(boundBy: max(0, app.scrollViews.count - 1)).swipeUp() }
        link.click(); XCTAssertTrue(app.staticTexts["repeatRuleSummary"].label.contains("Last Friday")); app.terminate()
    }

    @MainActor func testInboxReviewMoveKeepCompleteUndoAndRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--widget-action-testing", "--inbox-review-testing", "--inbox-review-seed"]; app.launch()
        XCTAssertTrue(app.staticTexts["inboxProjection"].waitForExistence(timeout: 10)); XCTAssertEqual(app.staticTexts["inboxProjection"].label, "Inbox: 3")
        let plan = app.staticTexts["inboxFixturePlan"].label
        app.buttons["reviewInbox"].click(); XCTAssertTrue(app.staticTexts["inboxReviewTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["inboxReviewTitle"].label, "Inbox launch notes")
        app.buttons["inboxReviewMove"].click(); app.buttons["Studio"].click()
        XCTAssertEqual(app.staticTexts["inboxReviewTitle"].label, "Inbox studio sketch"); app.buttons["inboxReviewKeep"].click()
        XCTAssertEqual(app.staticTexts["inboxReviewTitle"].label, "Inbox reference"); app.buttons["inboxReviewComplete"].click()
        XCTAssertTrue(app.staticTexts["inboxReviewSummary"].waitForExistence(timeout: 5)); app.buttons["inboxReviewUndo"].click()
        XCTAssertEqual(app.staticTexts["inboxReviewTitle"].label, "Inbox reference"); app.buttons["inboxReviewComplete"].click()
        XCTAssertEqual(app.staticTexts["inboxReviewRemaining"].label, "1 open task remains in Inbox."); app.buttons["inboxReviewClose"].click()
        XCTAssertEqual(app.staticTexts["inboxProjection"].label, "Inbox: 1"); XCTAssertEqual(app.staticTexts["inboxFixturePlan"].label, plan)
        app.terminate(); app.launchArguments.removeAll { $0 == "--inbox-review-seed" }; app.launch()
        XCTAssertTrue(app.staticTexts["inboxProjection"].waitForExistence(timeout: 10)); XCTAssertEqual(app.staticTexts["inboxProjection"].label, "Inbox: 1")
        app.buttons["reviewInbox"].click(); XCTAssertTrue(app.staticTexts["inboxReviewTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["inboxReviewTitle"].label, "Inbox studio sketch"); app.buttons["inboxReviewClose"].click(); app.terminate()
    }

    @MainActor func testBulkDeadlineInspectorSetUndoAndRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--deadline-fixture"]; app.launch()
        let first = app.staticTexts["Prepare launch"], second = app.staticTexts["Review copy"]
        XCTAssertTrue(first.waitForExistence(timeout: 10)); first.click()
        XCUIElement.perform(withKeyModifiers: [.command]) { second.click() }
        XCTAssertTrue(app.buttons["bulkDeadlines"].waitForExistence(timeout: 5)); app.buttons["bulkDeadlines"].click()
        XCTAssertTrue(app.buttons["bulkDeadlineApply"].waitForExistence(timeout: 5)); app.buttons["bulkDeadlineApply"].click()
        XCTAssertTrue(app.buttons["undoConfirmation"].waitForExistence(timeout: 5)); app.buttons["undoConfirmation"].click()
        app.typeKey("z", modifierFlags: [.command, .shift])
        app.terminate(); app.launchArguments = ["--uitesting", "--section=inbox"]; app.launch()
        XCTAssertTrue(first.waitForExistence(timeout: 10)); first.click()
        XCUIElement.perform(withKeyModifiers: [.command]) { second.click() }
        app.buttons["bulkDeadlines"].click()
        XCTAssertFalse(app.staticTexts["No deadline"].exists)
        XCTAssertFalse(app.buttons["bulkDeadlineApply"].isEnabled); app.buttons["bulkDeadlineCancel"].click(); app.terminate()
    }

    @MainActor func testQuickReminderCaptureInspectorAndRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--quick-entry-fixture"]; app.launch()
        app.typeKey("n", modifierFlags: .command)
        let input = app.textFields["quickAdd"]; XCTAssertTrue(input.waitForExistence(timeout: 5)); input.click()
        let name = "Reminder capture " + String(UUID().uuidString.prefix(6))
        input.typeText(name + " tomorrow at 4pm !30mb !2h !tomorrow 9am")
        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "decline-reminder_specs:"))
        XCTAssertTrue(chips.firstMatch.waitForExistence(timeout: 5)); XCTAssertEqual(chips.count, 3)
        app.buttons["Add Task"].click(); app.buttons["Inbox"].firstMatch.click()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5)); app.staticTexts[name].click()
        let link = app.buttons["taskReminders"]
        for _ in 0..<6 where !link.isHittable { app.scrollViews.element(boundBy: max(0, app.scrollViews.count - 1)).swipeUp() }
        XCTAssertTrue(link.isHittable); link.click()
        XCTAssertTrue(app.buttons["30 min before"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", "Fixed instant", "Fixed instant")).count, 2)
        app.buttons["Done"].click(); app.terminate(); app.launchArguments = ["--uitesting", "--section=inbox"]; app.launch()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5)); app.staticTexts[name].click()
        for _ in 0..<6 where !link.isHittable { app.scrollViews.element(boundBy: max(0, app.scrollViews.count - 1)).swipeUp() }
        link.click(); XCTAssertTrue(app.buttons["30 min before"].waitForExistence(timeout: 5)); app.terminate()
    }

    @MainActor func testIndependentReminderEditorValidationAutosaveAndRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--reminder-fixture"]; app.launch(); defer { app.terminate() }
        let title = app.staticTexts["title-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.click()
        let reminders = app.buttons["taskReminders"]
        for _ in 0..<6 where !reminders.isHittable { app.scrollViews.element(boundBy: max(0, app.scrollViews.count - 1)).swipeUp() }; reminders.click()
        app.buttons["reminderAdd"].click(); app.popUpButtons["reminderKind"].click(); app.menuItems["Repeats"].click()
        let rule = app.textFields["reminderRepeatRule"]; XCTAssertTrue(rule.waitForExistence(timeout: 5))
        rule.click(); app.typeKey("a", modifierFlags: .command); rule.typeText("every! day"); XCTAssertFalse(app.buttons["reminderSave"].isEnabled)
        app.typeKey("a", modifierFlags: .command); rule.typeText("every 2 weeks on monday and friday for 5 occurrences")
        XCTAssertTrue(app.buttons["reminderSave"].isEnabled); XCTAssertTrue(app.staticTexts["reminderRepeatSummary"].label.contains("5 occurrences total")); app.buttons["reminderSave"].click()
        XCTAssertTrue(app.buttons["reminderEdit-1"].waitForExistence(timeout: 5)); app.buttons["Done"].click(); app.buttons["Today"].firstMatch.click()
        app.terminate(); app.launchArguments = ["--uitesting", "--section=inbox"]; app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.click()
        for _ in 0..<6 where !reminders.isHittable { app.scrollViews.element(boundBy: max(0, app.scrollViews.count - 1)).swipeUp() }; reminders.click()
        app.buttons["reminderEdit-1"].click(); XCTAssertEqual(rule.value as? String, "every 2 weeks on monday and friday for 5 occurrences")
        app.buttons["Cancel"].click(); app.buttons["reminderDelete-1"].click(); XCTAssertFalse(app.buttons["reminderEdit-1"].exists); app.buttons["Done"].click()
    }

    @MainActor func testMultipleRemindersInspectorAutosaveAndRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--reminder-fixture"]; app.launch()
        let title = app.staticTexts["title-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.click()
        let reminders = app.buttons["taskReminders"]
        for _ in 0..<6 where !reminders.isHittable { app.scrollViews.element(boundBy: max(0, app.scrollViews.count - 1)).swipeUp() }
        XCTAssertTrue(reminders.isHittable); reminders.click()
        XCTAssertTrue(app.buttons["reminderAdd"].waitForExistence(timeout: 5)); app.buttons["reminderAdd"].click()
        XCTAssertTrue(app.buttons["reminderSave"].waitForExistence(timeout: 5)); app.buttons["reminderSave"].click()
        XCTAssertTrue(app.buttons["reminderEdit-1"].waitForExistence(timeout: 5))
        app.buttons["Done"].click()
        // Selecting another scope flushes the inspector's autosave before relaunch.
        app.buttons["Today"].firstMatch.click()
        app.terminate(); app.launchArguments = ["--uitesting", "--section=inbox"]; app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.click()
        for _ in 0..<6 where !reminders.isHittable { app.scrollViews.element(boundBy: max(0, app.scrollViews.count - 1)).swipeUp() }
        reminders.click(); XCTAssertTrue(app.buttons["reminderEdit-1"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["reminderEdit-1"].label, "10 min before")
        app.buttons["reminderDelete-1"].click(); XCTAssertFalse(app.buttons["reminderEdit-1"].exists)
        app.buttons["Done"].click(); app.terminate()
    }

    @MainActor func testQuickEntryProjectSectionAndAssignment() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--quick-entry-fixture"]; app.launch()
        app.typeKey("n", modifierFlags: .command)
        let input = app.textFields["quickAdd"]; XCTAssertTrue(input.waitForExistence(timeout: 5)); input.click()
        let title = "Client proposal " + String(UUID().uuidString.prefix(6))
        input.typeText(title + #" #"Client Work" /"Next steps" +Alex @"Client notes""#)
        XCTAssertTrue(app.buttons["decline-project_id"].waitForExistence(timeout: 5))
        app.buttons["Add Task"].click()
        app.buttons["Client Work"].firstMatch.click()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Next steps"].exists)
        app.terminate(); app.launchArguments = ["--uitesting", "--section=project:qe-work"]; app.launch()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
    }
    override func setUp() { continueAfterFailure = false }


    @MainActor func testHourlyPlannerScheduleAndUndo() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--planner-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["plannerSchedule"].waitForExistence(timeout: 10))
        app.buttons["plannerShowAllDay"].tap()
        XCTAssertTrue(app.buttons["plannerAllDay-planner-report"].waitForExistence(timeout: 5))
        app.buttons["plannerAllDay-planner-report"].tap()
        XCTAssertTrue(app.textFields["plannerEstimate"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["plannerEstimate"].value as? String, "25")
        app.buttons["plannerSave"].tap()
        XCTAssertTrue(app.buttons["plannerUndo"].waitForExistence(timeout: 5)); app.buttons["plannerUndo"].tap()
        app.buttons["plannerShowAllDay"].tap()
        XCTAssertTrue(app.buttons["plannerAllDay-planner-report"].waitForExistence(timeout: 5))
        app.buttons["plannerAllDay-planner-report"].tap(); app.buttons["plannerSave"].tap()
        app.terminate(); app.launchArguments = ["--uitesting", "--section=calendar", "--calendar-mode=day"]; app.launch()
        app.buttons["Calendar"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["plannerBlock-planner-report"].waitForExistence(timeout: 10))
    }

    @MainActor func testSavedFilterBoardLastCardCompletionAndRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--parity-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["newSavedView"].waitForExistence(timeout: 10)); app.buttons["newSavedView"].click()
        let name = "Workshop board " + String(UUID().uuidString.prefix(6))
        let field = app.textFields["savedViewName"]; XCTAssertTrue(field.waitForExistence(timeout: 5)); field.click(); field.typeText(name)
        app.descendants(matching: .any)["advancedFilter"].click()
        let expression = app.textFields["filterExpression"]; XCTAssertTrue(expression.waitForExistence(timeout: 5)); app.buttons["clearFilterExpression"].click(); expression.click(); expression.typeText("project:parity-project AND no date")
        app.popUpButtons["savedViewLayout"].click(); app.menuItems["Board"].click(); app.buttons["saveSavedView"].click()
        let view = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", name, name)).firstMatch; XCTAssertTrue(view.waitForExistence(timeout: 5)); view.click()
        let column = app.scrollViews["savedFilterColumn-all"]; XCTAssertTrue(column.waitForExistence(timeout: 5))
        let last = app.buttons["savedFilterOpen-parity-44"]
        for _ in 0..<30 where !last.isHittable { column.swipeUp(velocity: .slow) }
        XCTAssertTrue(last.isHittable); XCTAssertGreaterThanOrEqual(last.frame.minY, column.frame.minY); XCTAssertLessThanOrEqual(last.frame.maxY, column.frame.maxY)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Saved filter lower card on Mac"; shot.lifetime = .keepAlways; add(shot)
        last.click(); XCTAssertEqual(app.textFields["taskTitle"].value as? String, "Workshop task 44")
        app.buttons["Complete Workshop task 44"].click(); XCTAssertFalse(app.buttons["Complete Workshop task 44"].waitForExistence(timeout: 2))
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch(); XCTAssertTrue(view.waitForExistence(timeout: 5)); view.click()
        XCTAssertTrue(column.waitForExistence(timeout: 5)); for _ in 0..<30 where !app.buttons["savedFilterOpen-parity-43"].isHittable { column.swipeUp(velocity: .slow) }
        XCTAssertTrue(app.buttons["savedFilterOpen-parity-43"].exists); XCTAssertFalse(app.buttons["Complete Workshop task 44"].exists)
    }



    @MainActor func testTimeFiltersAndDatedBoundarySurviveRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--filter-times-fixture"]; app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["newSavedView"].waitForExistence(timeout: 10)); app.buttons["newSavedView"].click()
        let name = "Morning work " + String(UUID().uuidString.prefix(6))
        let field = app.textFields["savedViewName"]; XCTAssertTrue(field.waitForExistence(timeout: 5)); field.click(); field.typeText(name)
        app.descendants(matching: .any)["advancedFilter"].click()
        let expression = app.textFields["filterExpression"]; XCTAssertTrue(expression.waitForExistence(timeout: 5)); app.buttons["clearFilterExpression"].click(); expression.click(); expression.typeText("time before:25:00")
        XCTAssertFalse(app.buttons["saveSavedView"].isEnabled)
        app.buttons["clearFilterExpression"].click(); expression.click(); expression.typeText("time before:2pm"); XCTAssertTrue(app.buttons["saveSavedView"].isEnabled); app.buttons["saveSavedView"].click()
        let view = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", name, name)).firstMatch; XCTAssertTrue(view.waitForExistence(timeout: 5)); view.click()
        XCTAssertTrue(app.buttons["Complete Morning plan"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["Complete Tomorrow morning"].exists); XCTAssertFalse(app.buttons["Complete On the hour"].exists)
        view.rightClick(); app.menuItems["Edit filter"].click(); app.descendants(matching: .any)["advancedFilter"].click()
        app.buttons["clearFilterExpression"].click(); expression.click(); expression.typeText("date before:today at 2pm"); app.buttons["saveSavedView"].click()
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch(); XCTAssertTrue(view.waitForExistence(timeout: 5)); view.click()
        XCTAssertTrue(app.buttons["Complete Morning plan"].waitForExistence(timeout: 5)); for title in ["Tomorrow morning", "On the hour", "Afternoon plan", "All-day plan", "Deadline only"] { XCTAssertFalse(app.buttons["Complete " + title].exists) }
        view.rightClick(); app.menuItems["Edit filter"].click()
        let value = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "filterConditionValue-")).firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 5)); XCTAssertEqual(value.value as? String, "today at 14:00"); app.buttons["Cancel"].click()
    }

    @MainActor func testExplicitDateSourcesAndRelativeFilterSurviveRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--filter-dates-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["newSavedView"].waitForExistence(timeout: 10)); app.buttons["newSavedView"].click()
        let name = "Date sources " + String(UUID().uuidString.prefix(6))
        let field = app.textFields["savedViewName"]; XCTAssertTrue(field.waitForExistence(timeout: 5)); field.click(); field.typeText(name)
        app.descendants(matching: .any)["advancedFilter"].click()
        let expression = app.textFields["filterExpression"]; XCTAssertTrue(expression.waitForExistence(timeout: 5)); app.buttons["clearFilterExpression"].click(); expression.click(); expression.typeText("effective-due:today")
        XCTAssertTrue(app.buttons["saveSavedView"].isEnabled); app.buttons["saveSavedView"].click()
        let view = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", name, name)).firstMatch; XCTAssertTrue(view.waitForExistence(timeout: 5)); view.click()
        XCTAssertTrue(app.buttons["Complete Plan only"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["Complete Deadline only"].exists)
        XCTAssertFalse(app.buttons["Complete Both uses plan"].exists); XCTAssertFalse(app.buttons["Complete Neither date"].exists)
        view.rightClick(); app.menuItems["Edit filter"].click(); app.descendants(matching: .any)["advancedFilter"].click()
        XCTAssertTrue((expression.value as? String ?? "").contains(#"effective-due:"today""#))
        app.buttons["clearFilterExpression"].click(); expression.click(); expression.typeText("date: tomorrow"); app.buttons["saveSavedView"].click()
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch(); XCTAssertTrue(view.waitForExistence(timeout: 5)); view.click()
        XCTAssertTrue(app.buttons["Complete Both uses plan"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["Complete Plan only"].exists); XCTAssertFalse(app.buttons["Complete Deadline only"].exists)
        view.rightClick(); app.menuItems["Edit filter"].click()
        let value = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "filterConditionValue-")).firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 5)); XCTAssertEqual(value.value as? String, "tomorrow"); app.buttons["Cancel"].click()
    }

    @MainActor func testKeywordFilterAndUnsupportedQueryPreservation() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--filter-primitives-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["newSavedView"].waitForExistence(timeout: 10)); app.buttons["newSavedView"].click()
        let name = "Email review " + String(UUID().uuidString.prefix(6))
        let field = app.textFields["savedViewName"]; XCTAssertTrue(field.waitForExistence(timeout: 5)); field.click(); field.typeText(name)
        app.descendants(matching: .any)["advancedFilter"].click()
        let expression = app.textFields["filterExpression"]; XCTAssertTrue(expression.waitForExistence(timeout: 5)); app.buttons["clearFilterExpression"].click(); expression.click(); expression.typeText(#"search:"cafe email" & recurring & no time & no labels & #Studio"#)
        XCTAssertTrue(app.buttons["saveSavedView"].isEnabled); app.buttons["saveSavedView"].click()
        let view = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", name, name)).firstMatch; XCTAssertTrue(view.waitForExistence(timeout: 5)); view.click()
        XCTAssertTrue(app.buttons["Complete Send email agenda"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["Complete Send email call"].exists); XCTAssertFalse(app.buttons["Complete Email café notes"].exists); XCTAssertFalse(app.buttons["Complete Send email café report"].exists)
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch(); XCTAssertTrue(view.waitForExistence(timeout: 5)); view.click(); XCTAssertTrue(app.buttons["Complete Send email agenda"].exists)
        app.staticTexts["Future filter"].click(); app.buttons["Edit filter"].click()
        XCTAssertFalse(app.buttons["saveSavedView"].isEnabled); XCTAssertFalse(app.descendants(matching: .any)["advancedFilter"].isEnabled)
        XCTAssertTrue(app.staticTexts["filterValidationError"].firstMatch.label.contains("preserved")); app.buttons["Cancel"].click()
        app.terminate(); app.launch(); app.staticTexts["Future filter"].click(); XCTAssertTrue(app.descendants(matching: .any)["savedFilterError"].exists)
    }

    @MainActor func testSavedFilterSurvivesRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--parity-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["newSavedView"].waitForExistence(timeout: 10)); app.buttons["newSavedView"].click()
        let name = "Workshop focus " + String(UUID().uuidString.prefix(6))
        let nameField = app.textFields["savedViewName"]; XCTAssertTrue(nameField.waitForExistence(timeout: 5)); nameField.click(); nameField.typeText(name)
        let expressionSwitch = app.descendants(matching: .any)["advancedFilter"]; expressionSwitch.click()
        let expression = app.textFields["filterExpression"]; XCTAssertTrue(expression.waitForExistence(timeout: 5))
        app.buttons["clearFilterExpression"].click(); expression.click(); expression.typeText("project:parity-project AND no date")
        XCTAssertTrue(app.buttons["saveSavedView"].isEnabled); app.buttons["saveSavedView"].click()
        let view = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", name, name)).firstMatch
        XCTAssertTrue(view.waitForExistence(timeout: 5)); view.click()
        XCTAssertTrue(app.descendants(matching: .any)["task-parity-1"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Saved filter list on Mac"; shot.lifetime = .keepAlways; add(shot)
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(view.waitForExistence(timeout: 5)); view.click()
        XCTAssertTrue(app.descendants(matching: .any)["task-parity-1"].waitForExistence(timeout: 5))
    }
    @MainActor func testDeadlineEstimateQuickEntrySurvivesRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--day-drag-fixture"]; app.launch()
        XCTAssertTrue(app.textFields["listFilter"].waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textFields["quickAdd"].waitForExistence(timeout: 5))
        app.typeText("Planning capture ~25m {2026-10-09}")
        XCTAssertTrue(app.buttons["decline-deadline_date"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["decline-duration_minutes"].exists)
        app.typeKey(.return, modifierFlags: [])
        let created = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "Planning capture")).firstMatch
        XCTAssertTrue(created.waitForExistence(timeout: 5)); created.click()
        XCTAssertTrue(app.descendants(matching: .any)["taskDeadline"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["taskDuration"].exists)
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(created.waitForExistence(timeout: 5)); created.click()
        XCTAssertTrue(app.descendants(matching: .any)["taskDeadline"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["taskDuration"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Deadline and estimate inspector"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testAppearanceDensityAndCustomAccentStayInSettings() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--parity-fixture"]; app.launch()
        let first = app.descendants(matching: .any)["task-parity-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let roomy = first.frame.height
        app.typeKey(",", modifierFlags: .command)
        app.buttons["Appearance"].click()
        XCTAssertTrue(app.buttons["Save Custom Accent"].waitForExistence(timeout: 5))
        app.radioButtons["Compact"].click()
        app.buttons["customAccentPicker"].click()
        let colors = app.windows["Colors"]
        XCTAssertTrue(colors.waitForExistence(timeout: 5))
        colors.buttons["Color Sliders"].click()
        colors.popUpButtons.firstMatch.click(); app.menuItems["RGB Sliders"].click()
        let hex = colors.textFields["hex"]
        XCTAssertTrue(hex.waitForExistence(timeout: 5)); hex.click()
        app.typeKey("a", modifierFlags: .command); app.typeText("FFD95A"); app.typeKey(.return, modifierFlags: [])
        app.typeKey("w", modifierFlags: .command)
        app.buttons["saveCustomAccent"].click()
        XCTAssertTrue(app.buttons["accent-custom:FFD95A"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["saveCustomAccent"].exists, "Accent changes must preserve this page")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Appearance and saved custom accent"; shot.lifetime = .keepAlways; self.add(shot)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertLessThan(first.frame.height, roomy - 3, "Compact must reduce the actual native row height")
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        app.staticTexts["Release workshop"].firstMatch.click()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertLessThan(first.frame.height, roomy - 3)
    }

    @MainActor func testProjectCollapseBoardCreationAndMove() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--parity-fixture"]; app.launch()
        let collapse = app.buttons["section-collapse-group:parity-project:planning"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 10)); collapse.click()
        XCTAssertFalse(app.staticTexts["title-parity-0"].exists)
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        app.staticTexts["Release workshop"].firstMatch.click()
        XCTAssertTrue(collapse.waitForExistence(timeout: 5)); XCTAssertEqual(collapse.value as? String, "Collapsed")
        collapse.click()
        app.menuButtons["Task options"].click(); app.menuItems["Layout"].hover(); app.menuItems["Board"].click()
        XCTAssertTrue(app.scrollViews["projectBoard"].waitForExistence(timeout: 5))
        let add = app.buttons["board-add-ready"]
        for _ in 0..<3 {
            if add.isHittable { break }
            app.scrollViews["projectBoard"].scroll(byDeltaX: -450, deltaY: 0)
        }
        XCTAssertTrue(add.isHittable, "Ready creation control must be visible before clicking"); add.click()
        let capture = app.textFields["quickAdd"]
        XCTAssertTrue(capture.waitForExistence(timeout: 5)); capture.click()
        app.typeText("Prepare final handoff"); app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.scrollViews["projectBoard"].waitForExistence(timeout: 5), app.debugDescription)
        let complete = app.buttons["Complete Prepare final handoff"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        let createdID = String(complete.identifier.dropFirst("complete-".count))
        let added = app.staticTexts["title-" + createdID]
        XCTAssertTrue(added.waitForExistence(timeout: 5)); added.rightClick()
        app.menuItems["Move to Section"].hover(); app.menuItems["Planning"].click()
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(added.waitForExistence(timeout: 5))
        // Ready contains only this task: completion removes the last row, and one undo restores it.
        added.rightClick(); app.menuItems["Complete / Reopen"].click()
        XCTAssertTrue(waitForDisappearance(added, timeout: 5))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(added.waitForExistence(timeout: 5))
        XCTAssertTrue(added.isHittable, "The restored column must remain visible")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Project board with sections"; shot.lifetime = .keepAlways; self.add(shot)
    }

    @MainActor func testInvitationLinkSurvivesSignedOutDestination() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--invitation-link-fixture"]; app.launch()
        XCTAssertTrue(app.staticTexts["Project invitations"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Sign In…"].exists || app.buttons["Sign In"].exists)
        app.terminate(); app.launchArguments = ["--uitesting", "--keep-invitation-route"]; app.launch()
        XCTAssertTrue(app.staticTexts["Project invitations"].waitForExistence(timeout: 10))
    }

    @MainActor func testMemberPhotoLoadsAndNamesSurviveRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--parity-fixture"]; app.launch()
        let person = app.buttons["assignee-parity-0"]
        XCTAssertTrue(person.waitForExistence(timeout: 10)); XCTAssertTrue(person.label.contains("Morgan Lee"))
        let photo = person
        let loaded = NSPredicate(format: "value == %@", "Photo loaded")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: loaded, object: photo)], timeout: 25), .completed, "A real remote image must decode and render")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Live remote image"; shot.lifetime = .keepAlways; self.add(shot)
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        app.staticTexts["Release workshop"].firstMatch.click()
        XCTAssertTrue(person.waitForExistence(timeout: 5)); XCTAssertTrue(person.label.contains("Morgan Lee"))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: loaded, object: photo)], timeout: 5), .completed)
    }

    @MainActor func testUpcomingStickyDatesAndCompletionViewport() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--sticky-fixture"]; app.launch()
        let list = app.outlines["taskList"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.scroll(byDeltaX: 0, deltaY: -400)
        let before = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); before.name = "Upcoming pinned active date"; before.lifetime = .keepAlways; self.add(before)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "complete-sticky-"))
        let visible = rows.allElementsBoundByIndex.prefix(30).filter(\.isHittable)
        let target = app.buttons[try XCTUnwrap(visible.dropFirst(3).first).identifier]
        // Measure above the removed row: following rows correctly move up when a task disappears.
        let anchor = app.buttons[try XCTUnwrap(visible.dropFirst().first).identifier]
        let y = anchor.frame.minY
        target.click()
        XCTAssertTrue(anchor.waitForExistence(timeout: 5))
        XCTAssertLessThan(abs(anchor.frame.minY - y), 3, "Completion must not reset the viewport")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        let after = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); after.name = "Upcoming after completion and undo"; after.lifetime = .keepAlways; self.add(after)
    }

    @MainActor func testProjectCompletionAndNavigationKeepViewport() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--parity-fixture"]; app.launch()
        let list = app.outlines["taskList"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        list.scroll(byDeltaX: 0, deltaY: -600)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "complete-parity-"))
            .allElementsBoundByIndex.prefix(30).filter(\.isHittable)
        let anchor = app.buttons[try XCTUnwrap(rows.first).identifier]
        let target = app.buttons[try XCTUnwrap(rows.dropFirst(3).first).identifier]
        let y = anchor.frame.minY
        target.click()
        XCTAssertTrue(waitForDisappearance(target, timeout: 5))
        XCTAssertLessThan(abs(anchor.frame.minY - y), 3, "Completion below the anchor must preserve its position")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertLessThan(abs(anchor.frame.minY - y), 3, "Undo must preserve the anchor")
        app.typeKey("4", modifierFlags: .command)
        app.staticTexts["Release workshop"].firstMatch.click()
        XCTAssertTrue(anchor.waitForExistence(timeout: 5))
        XCTAssertLessThan(abs(anchor.frame.minY - y), 3, "Returning to the project must restore the viewport")
    }

    @MainActor func testAssignmentsIncludeNestedTasksAndPersist() throws {
        func nestedID(_ path: [String]) throws -> String { "subtask:" + (try JSONEncoder().encode(path)).base64EncodedString() }
        let child = try nestedID(["assignment-root", "assigned-child"])
        let grand = try nestedID(["assignment-root", "assigned-child", "assigned-grand"])
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--assignment-fixture"]; app.launch()
        XCTAssertTrue(app.staticTexts["title-assignment-root"].waitForExistence(timeout: 10))
        app.staticTexts["Assigned to Me"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["title-" + child].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["title-assignment-personal"].exists)
        XCTAssertFalse(app.staticTexts["title-assignment-root"].exists)
        app.staticTexts["title-" + child].click()
        XCTAssertTrue(app.descendants(matching: .any)["taskTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any)["taskTitle"].value as? String, "Prepare launch notes")
        app.staticTexts["Today"].firstMatch.click()
        app.buttons["expand-assignment-root"].click(); app.buttons["expand-" + child].click()
        app.staticTexts["title-" + grand].click()
        let assignee = app.buttons["taskAssignee"]
        XCTAssertTrue(assignee.waitForExistence(timeout: 5)); assignee.click(); app.buttons["assign-member-ui-testing"].click()
        // Changing selection flushes the inspector's debounced save.
        app.staticTexts["title-assignment-root"].click()
        app.staticTexts["Assigned to Me"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["title-" + grand].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(app.staticTexts["Assigned to Me"].firstMatch.waitForExistence(timeout: 10))
        app.staticTexts["Assigned to Me"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["title-" + grand].waitForExistence(timeout: 10))
        app.buttons["complete-" + grand].click()
        XCTAssertTrue(waitForDisappearance(app.staticTexts["title-" + grand], timeout: 5))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["title-" + grand].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Assigned tasks with nested work"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor func testConflictResolutionKeepsIndependentComment() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--conflict-fixture"]; app.launch()
        XCTAssertTrue(app.links["reviewSyncConflict"].waitForExistence(timeout: 10))
        app.links["reviewSyncConflict"].click()
        XCTAssertTrue(app.buttons["keepMyEdit"].waitForExistence(timeout: 5))
        app.buttons["keepMyEdit"].click()
        XCTAssertTrue(waitForDisappearance(app.links["reviewSyncConflict"], timeout: 5))
        app.staticTexts["title-conflict-task"].click()
        XCTAssertTrue(app.staticTexts["My revised comment"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Independent teammate comment"].exists)
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(app.staticTexts["title-conflict-task"].waitForExistence(timeout: 10))
        app.staticTexts["title-conflict-task"].click()
        XCTAssertTrue(app.staticTexts["Independent teammate comment"].waitForExistence(timeout: 5))
    }


    @MainActor func testCapacityWidgetDayLinksAndRetainedProjection() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--widget-action-testing", "--capacity-widget-testing", "--capacity-widget-seed"]; app.launch()
        let projection = app.staticTexts["capacityProjection"]
        XCTAssertTrue(projection.waitForExistence(timeout: 10)); XCTAssertEqual(projection.label, "Work 480 · Tasks 90 · Unknown 1 · Calendar off")
        app.links["capacityOpenTomorrow"].click(); XCTAssertTrue(app.otherElements["hourlyPlanner"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["plannerCapacity"].label, "30 min estimated · 0 without estimates")
        app.buttons["plannerShowAllDay"].click(); XCTAssertTrue(app.buttons["plannerAllDay-capacity-tomorrow"].waitForExistence(timeout: 5))
        app.links["capacityOpenToday"].click(); XCTAssertEqual(app.staticTexts["plannerCapacity"].label, "90 min estimated · 1 without estimates")
        app.terminate(); app.launchArguments = ["--uitesting", "--widget-action-testing", "--capacity-widget-testing"]; app.launch()
        XCTAssertTrue(projection.waitForExistence(timeout: 10)); XCTAssertEqual(projection.label, "Work 480 · Tasks 90 · Unknown 1 · Calendar off"); app.terminate()
    }

    @MainActor func testCompletionCycleUseSyncedKeepsLaterOccurrenceDraftAndSurvivesRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--widget-action-testing", "--completion-cycle-fixture", "--edited-occurrence-fixture"]; app.launch()
        XCTAssertTrue(app.links["reviewSyncConflict"].waitForExistence(timeout: 10)); app.links["reviewSyncConflict"].click()
        XCTAssertTrue(app.buttons["useSharedEdit"].waitForExistence(timeout: 5)); app.buttons["useSharedEdit"].click()
        XCTAssertEqual(app.staticTexts["widgetRootState"].label, "Original: open")
        XCTAssertEqual(app.staticTexts["widgetCopyCount"].label, "Next copies: 0")
        XCTAssertEqual(app.staticTexts["widgetDraftCount"].label, "Drafts: 1")
        app.terminate(); app.launchArguments = ["--uitesting", "--widget-action-testing"]; app.launch()
        XCTAssertTrue(app.staticTexts["widgetRootState"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["widgetRootState"].label, "Original: open")
        XCTAssertEqual(app.staticTexts["widgetDraftCount"].label, "Drafts: 1"); app.terminate()
    }
    @MainActor func testWidgetIntentRecurringCompletionRetryUndoAndOldTap() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--widget-action-testing", "--widget-action-seed"]; app.launch()
        XCTAssertTrue(app.staticTexts["widgetRootState"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["widgetRootState"].label, "Original: open")
        app.buttons["widgetCompleteFixture"].click()
        XCTAssertEqual(app.staticTexts["widgetRootState"].label, "Original: completed"); XCTAssertEqual(app.staticTexts["widgetCopyCount"].label, "Next copies: 1")
        app.buttons["widgetRetryFixture"].click(); XCTAssertEqual(app.staticTexts["widgetCopyCount"].label, "Next copies: 1")
        app.buttons["widgetUndoFixture"].click(); app.buttons["widgetRetryFixture"].click()
        XCTAssertEqual(app.staticTexts["widgetRootState"].label, "Original: open"); XCTAssertEqual(app.staticTexts["widgetCopyCount"].label, "Next copies: 0")
        app.terminate(); app.launchArguments = ["--uitesting", "--widget-action-testing"]; app.launch()
        XCTAssertTrue(app.staticTexts["widgetRootState"].waitForExistence(timeout: 10)); XCTAssertEqual(app.staticTexts["widgetCopyCount"].label, "Next copies: 0")
    }

    @MainActor func testDeletionReviewKeepsTaskContentsAndRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--deletion-conflict-fixture"]; app.launch()
        XCTAssertTrue(app.links["reviewSyncConflict"].waitForExistence(timeout: 10)); app.links["reviewSyncConflict"].click()
        XCTAssertTrue(app.buttons["useSharedEdit"].waitForExistence(timeout: 5)); XCTAssertEqual(app.buttons["useSharedEdit"].label, "Keep task")
        XCTAssertEqual(app.buttons["keepMyEdit"].label, "Delete task"); app.buttons["useSharedEdit"].click()
        XCTAssertTrue(waitForDisappearance(app.links["reviewSyncConflict"], timeout: 5))
        app.staticTexts["title-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"].click()
        XCTAssertTrue(app.staticTexts["New work from another device"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(app.staticTexts["title-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"].waitForExistence(timeout: 10))
    }

    @MainActor func testExpandableSubtasksEditCompleteAndPersist() throws {
        func nestedID(_ path: [String]) throws -> String { "subtask:" + (try JSONEncoder().encode(path)).base64EncodedString() }
        let childID = try nestedID(["hierarchy-root", "child-one"])
        let grandchildID = try nestedID(["hierarchy-root", "child-one", "grandchild-one"])
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--hierarchy-fixture"]; app.launch()
        let root = app.staticTexts["title-hierarchy-root"], child = app.staticTexts["title-" + childID], grandchild = app.staticTexts["title-" + grandchildID]
        XCTAssertTrue(root.waitForExistence(timeout: 10))
        XCTAssertFalse(child.exists)
        app.buttons["expand-hierarchy-root"].click()
        XCTAssertTrue(child.waitForExistence(timeout: 5))
        app.buttons["expand-" + childID].click()
        XCTAssertTrue(grandchild.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(child.frame.minX, root.frame.minX)
        XCTAssertGreaterThan(grandchild.frame.minX, child.frame.minX)
        grandchild.click()
        let title = app.descendants(matching: .any)["taskTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Review checklist")
        XCTAssertFalse(app.textFields["addSubtask"].exists, "Sub-subtasks cannot have another level")
        title.click(); app.typeKey("a", modifierFlags: .command); app.typeText("Review final checklist"); app.typeKey(.return, modifierFlags: [])
        app.buttons["complete-" + grandchildID].click()
        XCTAssertTrue(app.buttons["reopen-" + grandchildID].waitForExistence(timeout: 5))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.buttons["complete-" + grandchildID].waitForExistence(timeout: 5))
        child.click(); app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(app.buttons["reopen-" + childID].waitForExistence(timeout: 5), "Space completes the selected subtask")
        XCTAssertTrue(app.buttons["complete-hierarchy-root"].exists, "The parent stays independent")
        app.buttons["expand-hierarchy-root"].click()
        XCTAssertTrue(waitForDisappearance(child, timeout: 5))
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(root.waitForExistence(timeout: 10))
        app.buttons["expand-hierarchy-root"].click(); app.buttons["expand-" + childID].click()
        XCTAssertTrue(app.buttons["reopen-" + childID].waitForExistence(timeout: 5))
        grandchild.click()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Review final checklist")
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Expanded subtasks and inspector"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor func testDraggingParentKeepsExpandedChildrenTogether() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--hierarchy-fixture"]; app.launch()
        let root = app.staticTexts["title-hierarchy-root"], other = app.staticTexts["title-hierarchy-other"]
        XCTAssertTrue(root.waitForExistence(timeout: 10))
        app.buttons["expand-hierarchy-root"].click()
        let childID = "subtask:" + (try JSONEncoder().encode(["hierarchy-root", "child-one"])).base64EncodedString()
        let child = app.staticTexts["title-" + childID]
        XCTAssertTrue(child.waitForExistence(timeout: 5))
        other.press(forDuration: 0.4, thenDragTo: root)
        sleep(1)
        XCTAssertLessThan(other.frame.minY, root.frame.minY)
        XCTAssertGreaterThan(child.frame.minY, root.frame.minY)
        app.typeKey("z", modifierFlags: .command)
        sleep(1)
        XCTAssertLessThan(root.frame.minY, other.frame.minY)
        XCTAssertGreaterThan(other.frame.minY, child.frame.minY)
    }

    @MainActor func testCreateSubSubtaskAndEnforceDepthLimit() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--hierarchy-fixture"]; app.launch()
        let childID = "subtask:" + (try JSONEncoder().encode(["hierarchy-root", "child-two"])).base64EncodedString()
        XCTAssertTrue(app.buttons["expand-hierarchy-root"].waitForExistence(timeout: 10))
        app.buttons["expand-hierarchy-root"].click()
        app.staticTexts["title-" + childID].click()
        let input = app.textFields["addSubtask"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.click(); input.typeText("Write release email"); app.typeKey(.return, modifierFlags: [])
        let created = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "Write release email")).firstMatch
        XCTAssertTrue(created.waitForExistence(timeout: 5))
        created.click()
        XCTAssertFalse(input.exists)
        XCTAssertEqual(app.descendants(matching: .any)["taskTitle"].value as? String, "Write release email")
    }

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

    @MainActor func testInboxReorderAndOverdueCollapse() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--day-drag-fixture", "--extra-overdue"]; app.launch()
        let overdue = app.staticTexts["title-drag-fixture-0"]
        XCTAssertTrue(overdue.waitForExistence(timeout: 10))
        for key in ["1", "2", "3", "5"] {
            app.typeKey(key, modifierFlags: .command)
            let toggle = app.buttons["overdueToggle"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            toggle.click()
            XCTAssertTrue(waitForDisappearance(overdue, timeout: 5))
            toggle.click()
            XCTAssertTrue(overdue.waitForExistence(timeout: 5))
        }
        app.typeKey("2", modifierFlags: .command)
        let first = app.staticTexts["title-drag-fixture-1"], last = app.staticTexts["title-drag-fixture-2"]
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        last.press(forDuration: 0.4, thenDragTo: first)
        sleep(1)
        XCTAssertLessThan(last.frame.minY, first.frame.minY)
        let snapshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        snapshot.name = "Inbox after drop"; snapshot.lifetime = .keepAlways; add(snapshot)
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(last.waitForExistence(timeout: 10))
        XCTAssertLessThan(last.frame.minY, first.frame.minY)
    }

    @MainActor func testOverdueReorderAndReschedule() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--day-drag-fixture", "--extra-overdue"]; app.launch()
        let first = app.staticTexts["title-drag-fixture-0"], second = app.staticTexts["title-overdue-extra"]
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        // Reordering this section must not change either task's due date.
        let source = first.frame.minY > second.frame.minY ? first : second
        let target = first.frame.minY > second.frame.minY ? second : first
        source.press(forDuration: 0.4, thenDragTo: target)
        sleep(1)
        XCTAssertLessThan(source.frame.minY, target.frame.minY)
        app.buttons["overdueToggle"].click()
        XCTAssertTrue(waitForDisappearance(second, timeout: 5))
        app.buttons["overdueToggle"].click()
        app.typeKey("3", modifierFlags: .command)
        let tomorrow = app.staticTexts["title-drag-fixture-3"]
        XCTAssertTrue(tomorrow.waitForExistence(timeout: 5))
        second.press(forDuration: 0.4, thenDragTo: tomorrow)
        sleep(1)
        XCTAssertGreaterThan(second.frame.minY, first.frame.minY)
        let snapshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        snapshot.name = "Upcoming after overdue drop"; snapshot.lifetime = .keepAlways; add(snapshot)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertLessThan(second.frame.minY, app.staticTexts["title-drag-fixture-1"].frame.minY, "One undo restores the overdue date")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(second.frame.minY, first.frame.minY, "Redo restores the scheduled destination")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(waitForDisappearance(second, timeout: 5))
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

    /// Clicking a link opens it (recorded in fixture mode) and leaves the row selection untouched.
    @MainActor func testLinkClickDoesNotSelectRow() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--link-fixture"]; app.launch()
        let linked = app.staticTexts["title-link-0"]
        XCTAssertTrue(linked.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["taskTitle"].exists)
        // "Read example.com › focus before Friday": the link starts after "Read ", so click a third of the way in.
        linked.coordinate(withNormalizedOffset: CGVector(dx: 0.33, dy: 0.5)).click()
        let opened = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Would open")).firstMatch
        XCTAssertTrue(opened.waitForExistence(timeout: 5), "The click opened the link\n" + app.debugDescription.components(separatedBy: "\n").filter { $0.contains("title-link") || $0.contains("Would open") || $0.contains("taskTitle") }.joined(separator: "\n"))
        sleep(1)
        XCTAssertFalse(app.descendants(matching: .any)["taskTitle"].exists, "A link click must not select the row: \(opened.value.debugDescription)")
        app.staticTexts["title-link-1"].click()
        XCTAssertTrue(app.descendants(matching: .any)["taskTitle"].waitForExistence(timeout: 5), "Plain rows still select on click")
    }

    /// Plan Your Day walks overdue and today's tasks; Space completes the current card and the list reflects it.
    @MainActor func testPlanSheetCompletesTask() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--day-drag-fixture"]; app.launch()
        let overdue = app.staticTexts["title-drag-fixture-0"]
        XCTAssertTrue(overdue.waitForExistence(timeout: 10))
        app.typeKey("p", modifierFlags: [.command, .option])
        let card = app.staticTexts["planCardTitle"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertEqual(card.value as? String, "Overdue sample")
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == %@", "Today first")).firstMatch.waitForExistence(timeout: 5), "Space completes the card and advances; card now: \(card.value.debugDescription); focused: \(app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == 1")).allElementsBoundByIndex.map { $0.identifier + "/" + $0.elementType.rawValue.description })")
        app.typeKey(.rightArrow, modifierFlags: [])
        sleep(1)
        let afterFirstSkip = card.value as? String
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(app.descendants(matching: .any)["finishPlan"].waitForExistence(timeout: 5), "Skipping the rest reaches the summary; after first skip: \(afterFirstSkip ?? "nil"), now: \(card.exists ? (card.value as? String ?? "") : "no card")\n" + app.debugDescription.components(separatedBy: "\n").filter { $0.contains("Start the Day") || $0.contains("finishPlan") || $0.contains("planned") }.joined(separator: "\n"))
        app.descendants(matching: .any)["finishPlan"].click()
        XCTAssertTrue(waitForDisappearance(overdue, timeout: 5), "The completed task left Today")
        XCTAssertTrue(app.staticTexts["title-drag-fixture-1"].exists, "Skipped tasks are untouched")
    }

    /// The welcome tour pages with Continue and →, and Escape dismisses it for good.
    @MainActor func testOnboardingPagesAndDismisses() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--day-drag-fixture", "--onboarding"]; app.launch()
        let next = app.buttons["onboardingContinue"]
        XCTAssertTrue(next.waitForExistence(timeout: 10), "The tour appears on request")
        next.click()
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Order that stays put"].waitForExistence(timeout: 5), "Continue and → advance pages")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(next, timeout: 5), "Escape dismisses the tour")
        XCTAssertTrue(app.staticTexts["title-drag-fixture-1"].exists, "The list is usable afterwards")
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
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("2", modifierFlags: .command)
        app.typeKey("n", modifierFlags: .command)
        XCTAssertEqual(input.value as? String, "")
        input.click(); input.typeText("Unfinished inbox draft")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("1", modifierFlags: .command)
        app.typeKey("n", modifierFlags: .command)
        XCTAssertEqual(input.value as? String, "Unfinished today draft")
        app.typeKey(.escape, modifierFlags: [])
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
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.textFields["finderSearch"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForDisappearance(app.textFields["finderSearch"], timeout: 5))
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.click(); app.typeKey(.rightArrow, modifierFlags: [])
        app.typeText(" continued")
        XCTAssertEqual(input.value as? String, "Draft continued")
        app.typeKey(.escape, modifierFlags: [])
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
        app.menuButtons["Task options"].click(); app.menuItems["Filter"].hover(); app.menuItems["Show Completed"].click()
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
            ("today-sky-accent", ["--preview", "--section=today", "--appearance=light", "--accent=sky", "--select-title=Make time for the big idea"]),
        ]
        for (name, arguments) in shots {
            let app = XCUIApplication(); app.launchArguments = arguments; app.launch()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
            sleep(2)
            let png = app.windows.firstMatch.screenshot().pngRepresentation
            try png.write(to: URL(fileURLWithPath: directory).appending(path: "\(name).png"))
            app.terminate()
        }
        // Welcome tour pages.
        for page in 0..<5 {
            let tour = XCUIApplication(); tour.launchArguments = ["--preview", "--onboarding", "--appearance=light"]; tour.launch()
            XCTAssertTrue(tour.buttons["skipOnboarding"].waitForExistence(timeout: 10))
            for _ in 0..<page { tour.buttons["onboardingContinue"].click() }
            sleep(page == 1 ? 4 : 2)
            let sheet = tour.sheets.firstMatch.exists ? tour.sheets.firstMatch : tour.windows.firstMatch
            try sheet.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appending(path: "onboarding-\(page + 1).png"))
            tour.terminate()
        }
        // Quick-add with chips: type a sentence the parser understands, capture before submitting.
        let chips = XCUIApplication(); chips.launchArguments = ["--preview", "--section=today", "--appearance=light"]; chips.launch()
        XCTAssertTrue(chips.windows.firstMatch.waitForExistence(timeout: 10)); sleep(1)
        chips.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(chips.textFields["quickAdd"].waitForExistence(timeout: 5))
        chips.typeText("Call the studio tomorrow at 14.30 p2 #calls")
        sleep(1)
        try chips.windows.firstMatch.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appending(path: "quick-add-chips.png"))
        chips.terminate()
        // Settings ▸ Account with the security actions previewed.
        let settings = XCUIApplication(); settings.launchArguments = ["--preview", "--preview-account", "--appearance=light"]; settings.launch()
        XCTAssertTrue(settings.windows.firstMatch.waitForExistence(timeout: 10)); sleep(1)
        settings.menuButtons["accountMenu"].click()
        settings.menuItems["Account…"].click()
        let changeEmail = settings.descendants(matching: .any)["changeEmail"]
        XCTAssertTrue(changeEmail.waitForExistence(timeout: 10), "The Account tab should open in the Settings window"); sleep(1)
        let window = settings.windows.allElementsBoundByIndex.first { $0.descendants(matching: .any)["changeEmail"].exists } ?? settings.windows.firstMatch
        try window.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appending(path: "settings-account.png"))
        settings.terminate()
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
    @MainActor func testPinnedNoteReadEditUnpinUndoAndRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--pinned-notes-seed", "--widget-action-testing", "--pinned-notes-testing"]; app.launch()
        XCTAssertTrue(app.staticTexts["noteProjection"].waitForExistence(timeout: 10)); XCTAssertEqual(app.staticTexts["noteProjection"].label, "Notes: 2 · Private: hidden")
        app.buttons["openPinnedNotes"].click(); XCTAssertTrue(app.buttons["pinnedNote-note-first"].waitForExistence(timeout: 5)); app.buttons["pinnedNote-note-first"].click()
        XCTAssertTrue(app.staticTexts["pinnedNoteText"].waitForExistence(timeout: 5)); XCTAssertTrue(app.staticTexts["pinnedNoteText"].label.contains("Final instruction"))
        app.buttons["editPinnedNote"].click()
        let input = app.descendants(matching: .any).matching(identifier: "taskDescription").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.click(); input.typeText("\nEdited on Mac.")
        app.buttons["Done"].click(); XCTAssertTrue(app.staticTexts["pinnedNoteText"].label.contains("Edited on Mac."))
        app.buttons["unpinNote"].click(); app.buttons["closePinnedNotes"].click()
        XCTAssertEqual(app.staticTexts["noteProjection"].label, "Notes: 1 · Private: hidden")
        app.typeKey("z", modifierFlags: .command); XCTAssertEqual(app.staticTexts["noteProjection"].label, "Notes: 2 · Private: hidden")
        app.terminate(); app.launchArguments.removeAll { $0 == "--pinned-notes-seed" }; app.launch()
        XCTAssertTrue(app.staticTexts["noteProjection"].waitForExistence(timeout: 10)); XCTAssertEqual(app.staticTexts["noteProjection"].label, "Notes: 2 · Private: hidden")
        app.terminate()
    }

}

extension TaskfoldMacUITests {
    @MainActor func testProjectPulseCurrentScopeRecordedHistoryAndRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--project-pulse-seed"]; app.launch()
        XCTAssertTrue(app.buttons["openProjectPulse"].waitForExistence(timeout: 10)); app.buttons["openProjectPulse"].click()
        let picker = app.descendants(matching: .any).matching(identifier: "pulseProjectPicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.click(); app.menuItems["Studio"].click()
        XCTAssertTrue(app.staticTexts["pulseProgress"].waitForExistence(timeout: 5)); XCTAssertEqual(app.staticTexts["pulseProgress"].label, "1 of 3 completed")
        let counts = app.staticTexts["pulseActivityCounts"]
        for _ in 0..<8 where !counts.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -350) }
        XCTAssertEqual(counts.label, "2 completion events · 1 reopen event")
        XCTAssertTrue(app.staticTexts["pulseHistoryCoverage"].label.contains("Earlier work has no recorded timeline."))
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(app.buttons["openProjectPulse"].waitForExistence(timeout: 10)); app.buttons["openProjectPulse"].click()
        let again = app.descendants(matching: .any).matching(identifier: "pulseProjectPicker").firstMatch
        again.click(); app.menuItems["Studio"].click()
        XCTAssertEqual(app.staticTexts["pulseProgress"].label, "1 of 3 completed")
        for _ in 0..<8 where !counts.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -350) }
        XCTAssertEqual(counts.label, "2 completion events · 1 reopen event"); app.terminate()
    }
}

extension TaskfoldMacUITests {
    @MainActor func testPulseWidgetPublicationAndCurrentProjectRoute() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--project-pulse-seed", "--widget-action-testing", "--pulse-widget-testing"]; app.launch()
        XCTAssertTrue(app.staticTexts["pulseProjection"].waitForExistence(timeout: 10)); XCTAssertEqual(app.staticTexts["pulseProjection"].label, "Pulse: 1/3 · 2 completion events · 1 reopen events")
        app.buttons["pulseWidgetOpen"].click()
        XCTAssertTrue(app.staticTexts["pulseProgress"].waitForExistence(timeout: 5)); XCTAssertEqual(app.staticTexts["pulseProgress"].label, "1 of 3 completed")
        let counts = app.staticTexts["pulseActivityCounts"]
        for _ in 0..<8 where !counts.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -300) }
        XCTAssertEqual(counts.label, "2 completion events · 1 reopen event")
        app.buttons["closeProjectPulse"].click(); app.terminate()
    }
}


extension TaskfoldMacUITests {
    @MainActor func testPendingReminderRouteEditorAndRejectedWorkspaceReentry() throws {
        let app=XCUIApplication(); app.launchArguments=["--uitesting","--reminder-route-testing","--widget-action-testing"]; app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["holdReminderRoute"].waitForExistence(timeout:10)); app.buttons["holdReminderRoute"].click(); app.buttons["renewReminderWorkspace"].click(); app.buttons["releaseReminderRoute"].click()
        let ignored=XCTNSPredicateExpectation(predicate:NSPredicate(format:"label == %@","Ignored"),object:app.staticTexts["reminderRouteOutcome"])
        XCTAssertEqual(XCTWaiter.wait(for:[ignored],timeout:5),.completed); XCTAssertFalse(app.descendants(matching:.any)["taskTitle"].exists)
        app.buttons["holdReminderRoute"].click(); app.buttons["releaseReminderRoute"].click()
        XCTAssertTrue(app.descendants(matching:.any)["taskTitle"].waitForExistence(timeout:5)); XCTAssertEqual(app.descendants(matching:.any)["taskTitle"].value as? String,"Reminder route check")
        app.buttons["endReminderRouteFixture"].click()
    }
}


extension TaskfoldMacUITests {
    @MainActor func testEarlierReminderSignatureOpensCurrentEditor() throws {
        let app=XCUIApplication(); app.launchArguments=["--uitesting","--reminder-route-testing","--widget-action-testing"]; app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["openLegacyReminderRoute"].waitForExistence(timeout:10)); app.buttons["openLegacyReminderRoute"].click()
        let title=app.descendants(matching:.any)["taskTitle"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout:5)); XCTAssertEqual(title.value as? String,"Reminder route check")
        app.buttons["endReminderRouteFixture"].click()
    }
}

extension TaskfoldMacUITests {
    @MainActor func testEarlierReminderCannotOpenRecreatedTaskAndCurrentReminderStillWorks() throws {
        let app=XCUIApplication(); app.launchArguments=["--uitesting","--reminder-route-testing","--widget-action-testing"]; app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["holdReminderRoute"].waitForExistence(timeout:10)); app.buttons["holdReminderRoute"].tap()
        app.buttons["restoreReminderTask"].tap(); app.buttons["releaseReminderRoute"].tap()
        let ignored=XCTNSPredicateExpectation(predicate:NSPredicate(format:"label == %@","Ignored"),object:app.staticTexts["reminderRouteOutcome"])
        XCTAssertEqual(XCTWaiter.wait(for:[ignored],timeout:5),.completed)
        XCTAssertFalse(app.descendants(matching:.any)["taskTitle"].firstMatch.exists)
        app.buttons["holdReminderRoute"].tap(); app.buttons["releaseReminderRoute"].tap()
        let title=app.descendants(matching:.any)["taskTitle"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout:5)); XCTAssertEqual(title.value as? String,"Reminder route check")
        app.buttons["Cancel"].firstMatch.tap(); app.buttons["endReminderRouteFixture"].tap()
    }
}
