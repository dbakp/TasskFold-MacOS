import XCTest
import AppKit
import PDFKit
import Darwin

extension TaskfoldMacUITests {
    @MainActor private func outputTables() throws -> NSDictionary {
        let cache = URL(fileURLWithPath: "/Users/" + NSUserName()).appendingPathComponent("Library/Containers/com.dbakp.taskfold.mac.workflowteststeameditbridge/Data/Library/Application Support/Taskfold/ui-testing.json")
        return try XCTUnwrap((JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? NSDictionary)?["tables"] as? NSDictionary)
    }
    @MainActor private func outputFront(_ app: XCUIApplication) -> XCUIElement {
        app.sheets.count > 0 ? app.sheets.element(boundBy: app.sheets.count - 1) : app.windows.firstMatch
    }
    @MainActor private func outputReveal(_ control: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<15 where !control.isHittable { outputFront(app).scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -280) }
        XCTAssertTrue(control.exists && control.isHittable, app.debugDescription)
    }
    @MainActor private func outputStart(_ app: XCUIApplication, longNotes: Bool) throws {
        guard ["com.dbakp.taskfold.mac.workflowteststeameditbridge.runner", "com.dbakp.taskfold.mac.workflowteststeameditbridge.runner.xctrunner"].contains(Bundle.main.bundleIdentifier ?? "") else { throw XCTSkip("Reserved isolated host required") }
        continueAfterFailure = false
        app.launchArguments = ["--uitesting", "--workflow-fixture", "--task-heading-fixture", "-localMode", "YES", "-appearance", "light"]
        app.launchArguments += longNotes ? ["--print-output-fixture"] : ["--heading-progress-fixture", "--heading-planner-fixture"]
        try launchHeadingWorkspace(app)
        let today = app.staticTexts["Today"].firstMatch; XCTAssertTrue(today.waitForExistence(timeout: 15), app.debugDescription); today.click()
        if longNotes {
            app.menuBars.menuBarItems["File"].click()
            let command = app.menuItems["Print or Export…"]
            XCTAssertTrue(command.waitForExistence(timeout: 5)); XCTAssertTrue(command.isEnabled); command.click()
        } else {
            let menu = app.menuButtons["Task options"].firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription); menu.click()
            let command = app.menuItems["openPrintReview"]
            XCTAssertTrue(command.waitForExistence(timeout: 5), app.debugDescription); command.click()
        }
        XCTAssertTrue(app.staticTexts["printPageCount"].waitForExistence(timeout: 15), app.debugDescription)
    }
    @MainActor private func outputSave(_ button: String, suffix: String, _ app: XCUIApplication) throws -> URL {
        let control = app.buttons[button]; outputReveal(control, app); control.click()
        let panel = app.sheets["save-panel"], save = panel.buttons["OKButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), app.debugDescription)
        let file = URL(fileURLWithPath: "/tmp/taskfold-output-proof-" + UUID().uuidString.lowercased() + "." + suffix)
        let name = panel.textFields["saveAsNameTextField"]; name.click(); name.typeKey("a", modifierFlags: .command); name.typeText(file.lastPathComponent)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let location = outputFront(app).textFields.firstMatch; XCTAssertTrue(location.waitForExistence(timeout: 5))
        location.click(); location.typeKey("a", modifierFlags: .command); location.typeText("/tmp"); location.typeKey(.return, modifierFlags: [])
        save.click()
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: file.path) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 15), .completed)
        return file
    }
    @MainActor func testTaskCSVActualSaveOptionsCancelAndColdReturn() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try outputStart(app, longNotes: false)
        let before = try outputTables()
        app.buttons["openTaskCSV"].click()
        let count = app.staticTexts["csvRowCount"]; XCTAssertTrue(count.waitForExistence(timeout: 10))
        XCTAssertEqual(count.value as? String ?? count.label, "4 rows · CSV")
        let file = try outputSave("saveTaskCSV", suffix: "csv", app)
        let bytes = try Data(contentsOf: file), text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("taskfold-task-rows-v1")); XCTAssertTrue(text.contains("Launch context")); XCTAssertTrue(text.contains("Keep the work’s own notes."))
        XCTAssertFalse(text.contains("f1810000-0000-4000-8000-000000000001"))
        let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.comma-separated-values-text"); attachment.name = "Actual Mac task-row CSV"; attachment.lifetime = .keepAlways; add(attachment)
        app.switches["csvIncludeNotes"].click(); app.switches["csvIncludeChecklists"].click()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@ OR label == %@", "3 rows · CSV", "3 rows · CSV"), object: count)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        let reduced = try outputSave("saveTaskCSV", suffix: "csv", app)
        let trimmed = try Data(contentsOf: reduced); XCTAssertFalse(String(decoding: trimmed, as: UTF8.self).contains("Keep the work’s own notes."))
        let second = XCTAttachment(data: trimmed, uniformTypeIdentifier: "public.comma-separated-values-text"); second.name = "Actual Mac CSV without notes or checklists"; second.lifetime = .keepAlways; add(second)
        let image = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); image.name = "Mac task CSV review"; image.lifetime = .keepAlways; add(image)
        app.buttons["saveTaskCSV"].click(); let cancel = app.sheets["save-panel"].buttons["CancelButton"]; XCTAssertTrue(cancel.waitForExistence(timeout: 10)); cancel.click()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 10)); XCTAssertFalse(app.staticTexts["csvExportStatus"].exists); XCTAssertEqual(try outputTables(), before)
        app.buttons["closeTaskCSV"].click(); app.buttons["closePrintReview"].click()
        app.terminate(); app.launchArguments = ["--uitesting", "-localMode", "YES"]; try launchHeadingWorkspace(app); XCTAssertEqual(try outputTables(), before)
        // The outer acceptance driver removes only verified synthetic outputs. The UI runner has read access, not delete authority, for files saved by the host.
    }
    @MainActor func testTaskPDFActualSaveCompletePagesPrintCancelAndColdReturn() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try outputStart(app, longNotes: true)
        let before = try outputTables(), file = try outputSave("saveTaskPDF", suffix: "pdf", app)
        let bytes = try Data(contentsOf: file), pdf = try XCTUnwrap(PDFDocument(data: bytes)), text = try XCTUnwrap(pdf.string)
        XCTAssertGreaterThan(pdf.pageCount, 1); XCTAssertTrue(text.contains("FINAL-NATIVE-PRINT-INSTRUCTION")); XCTAssertTrue(text.contains("Design section 1")); XCTAssertTrue(text.contains("Design section 8"))
        for index in 0..<pdf.pageCount { let bounds = try XCTUnwrap(pdf.page(at: index)).bounds(for: .mediaBox); XCTAssertEqual(bounds.width, 595, accuracy: 1); XCTAssertEqual(bounds.height, 842, accuracy: 1) }
        let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "com.adobe.pdf"); attachment.name = "Actual Mac complete A4 task PDF"; attachment.lifetime = .keepAlways; add(attachment)
        let image = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); image.name = "Mac PDF review"; image.lifetime = .keepAlways; add(image)
        app.buttons["printTaskPDF"].click()
        let cancel = app.windows.buttons["Cancel"].firstMatch; XCTAssertTrue(cancel.waitForExistence(timeout: 15), app.debugDescription); cancel.click()
        XCTAssertTrue(app.buttons["saveTaskPDF"].isHittable); XCTAssertEqual(try outputTables(), before)
        app.buttons["saveTaskPDF"].click(); let saveCancel = app.sheets["save-panel"].buttons["CancelButton"]; XCTAssertTrue(saveCancel.waitForExistence(timeout: 10)); saveCancel.click()
        XCTAssertTrue(saveCancel.waitForNonExistence(timeout: 10)); app.buttons["closePrintReview"].click()
        app.terminate(); app.launchArguments = ["--uitesting", "-localMode", "YES"]; try launchHeadingWorkspace(app); XCTAssertEqual(try outputTables(), before)
        // Verified synthetic output cleanup belongs to the outer acceptance driver.
    }
}

final class TaskfoldMacUITests: XCTestCase {
    @MainActor func testTeamOrganizationOverviewAndRoleScopedDetail() {
        let app = XCUIApplication()
        app.launchArguments = ["--team-overview-testing"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["A place for shared work"].waitForExistence(timeout: 15))
        let overview = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        overview.name = "Mac team organization overview"; overview.lifetime = .keepAlways; add(overview)
        let team = app.descendants(matching: .any)["team-ea300000-0000-4000-8000-000000000002"].firstMatch
        XCTAssertTrue(team.waitForExistence(timeout: 5)); team.click()
        XCTAssertTrue(app.staticTexts["Product design"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Launch planning"].exists)
        XCTAssertTrue(app.staticTexts["Your role: Owner"].exists)
        XCTAssertTrue(app.staticTexts["You"].exists)
        let detail = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        detail.name = "Mac team organization detail"; detail.lifetime = .keepAlways; add(detail)
        app.buttons["Refresh teams"].click()
        XCTAssertTrue(app.staticTexts["Product design"].waitForExistence(timeout: 10))
    }

    @MainActor func testNormalQuitRetainsLatestInspectorEdit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--quick-entry-fixture", "--section=inbox"]
        app.launch()
        defer { app.terminate() }
        app.typeKey("n", modifierFlags: .command)
        let input = app.textFields["quickAdd"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let name = "Quit retains estimate change"
        input.typeText(name + " ~25m")
        app.buttons["Add Task"].click()
        XCTAssertTrue(app.descendants(matching: .any)["taskDuration"].waitForExistence(timeout: 5))
        app.switches["Time estimate"].click()
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5), "Exercise normal Quit, not runner force termination")
        app.launchArguments = ["--uitesting", "--section=inbox"]
        app.launch()
        let row = app.staticTexts[name].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.click()
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(app.textFields["taskTitle"].value as? String, name)
        XCTAssertFalse(app.descendants(matching: .any)["taskDuration"].exists)
    }

    @MainActor func testInspectorChipCanBeDeclinedBeforeApplyingTitle() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--quick-entry-fixture"]
        app.launch()
        defer { app.terminate() }
        app.typeKey("n", modifierFlags: .command)
        let capture = app.textFields["quickAdd"]
        XCTAssertTrue(capture.waitForExistence(timeout: 5))
        capture.typeText("Inspector keyboard regression")
        app.buttons["Add Task"].click()
        let title = app.textFields["taskTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click(); app.typeKey("a", modifierFlags: .command)
        let raw = "Inspector keyboard regression ~25m"
        title.typeText(raw)
        let chip = app.buttons["decline-duration_minutes"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(chip.exists, "Tab must reach the chip before applying parsed values")
        app.typeKey(.delete, modifierFlags: [])
        let declined = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: chip)
        XCTAssertEqual(XCTWaiter.wait(for: [declined], timeout: 5), .completed)
        app.typeText(" retained")
        XCTAssertEqual(title.value as? String, raw + " retained")
        app.textViews["taskDescription"].click()
        XCTAssertEqual(title.value as? String, raw + " retained")
        XCTAssertFalse(app.descendants(matching: .any)["taskDuration"].exists)
    }

    @MainActor func testCaptureChipKeyboardReturnKeepsEntireDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--quick-entry-fixture"]
        app.launch()
        defer { app.terminate() }
        app.typeKey("n", modifierFlags: .command)
        let input = app.textFields["quickAdd"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let actions: [(String, String, Bool)] = [
            ("Space", " ", false),
            ("Delete", XCUIKeyboardKey.delete.rawValue, false),
            ("Escape", XCUIKeyboardKey.escape.rawValue, true)
        ]
        for (name, key, retainsChip) in actions {
            input.click()
            app.typeKey("a", modifierFlags: .command)
            app.typeKey(.delete, modifierFlags: [])
            let draft = "Keyboard \(name) preserves draft ~25m"
            input.typeText(draft)
            let chip = app.buttons["decline-duration_minutes"]
            XCTAssertTrue(chip.waitForExistence(timeout: 5))
            app.typeKey(.tab, modifierFlags: [])
            app.typeKey(key, modifierFlags: [])
            let chipState = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == %@", NSNumber(value: retainsChip)), object: chip)
            XCTAssertEqual(XCTWaiter.wait(for: [chipState], timeout: 5), .completed, name)
            app.typeText(" continued")
            XCTAssertEqual(input.value as? String, draft + " continued", name)
        }
        input.click(); app.typeKey("a", modifierFlags: .command); app.typeKey(.delete, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor func testQuickCaptureImmediatelyRefreshesSelectedInspector() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--quick-entry-fixture"]
        app.launch()
        defer { app.terminate() }
        for title in ["Inspector first capture", "Inspector second capture"] {
            app.typeKey("n", modifierFlags: .command)
            let input = app.textFields["quickAdd"]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.click(); input.typeText(title)
            app.buttons["Add Task"].click()
            let editor = app.descendants(matching: .any)["taskTitle"].firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", title), object: editor)
            XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed,
                           "New capture must show its inspector without navigating or reselecting")
            XCTAssertFalse(app.staticTexts["No Task Selected"].exists)
        }
    }

    @MainActor func testBackupFilePickerCancelAndReopenFromSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--widget-action-testing"]
        app.launch()
        defer { app.terminate() }
        app.typeKey(",", modifierFlags: .command)
        let account = app.buttons["Account"].firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.click()
        let restore = app.buttons["backupImport"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        for _ in 0..<2 {
            restore.click()
            let open = app.sheets.buttons["Open"].firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 5), "Restore must present a native file picker from Settings")
            app.sheets.buttons["Cancel"].firstMatch.click()
            XCTAssertTrue(restore.waitForExistence(timeout: 5))
        }
    }

    @MainActor func testTodoistImportPreviewFailureAndSafeRetry() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--todoist-import-testing"]; app.launch(); defer { app.terminate() }
        app.menuBars.menuBarItems["Account"].click(); app.menuItems["Import from Todoist…"].click()
        let field = app.secureTextFields["todoistToken"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.click(); field.typeText("fixture-native-token-0001")
        app.buttons["todoistPreview"].click()
        let importer = app.buttons["todoistImport"]
        XCTAssertTrue(importer.waitForExistence(timeout: 5))
        for (key, value) in [("projects", "2"), ("sections", "3"), ("labels", "2"), ("tasks", "4"), ("subtasks", "2"), ("comments", "3")] {
            let count = app.descendants(matching: .any)["todoistCount-" + key].firstMatch
            XCTAssertTrue(count.exists, "Each preview count must remain independently accessible")
            XCTAssertEqual(count.label, key.capitalized)
            XCTAssertEqual(count.value as? String, value)
        }
        for _ in 0..<8 where !importer.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -400) }
        XCTAssertTrue(app.descendants(matching: .any)["todoistWarning-1"].firstMatch.exists); importer.click()
        XCTAssertTrue(app.staticTexts["todoistImportError"].waitForExistence(timeout: 5))
        let failure = app.staticTexts["todoistImportError"]
        let failedSave = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "connection was lost", "connection was lost"), object: failure)
        XCTAssertEqual(XCTWaiter.wait(for: [failedSave], timeout: 5), .completed,
                       "Import must explain its save failure: label=\(failure.label), value=\(String(describing: failure.value))")
        XCTAssertTrue(failure.isHittable, "The failure explanation should be visible next to its retry action")
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "Todoist failed-save retry"; capture.lifetime = .keepAlways; add(capture)
        XCTAssertTrue(importer.isEnabled, "A failed save must leave the approved import retry enabled")
        importer.click()
        XCTAssertTrue(app.descendants(matching: .any)["todoistReceipt-tasksSkipped"].waitForExistence(timeout: 5)); XCTAssertFalse(importer.exists)
        for key in ["projectsImported", "sectionsImported", "labelsImported", "tasksImported", "subtasksImported", "commentsImported", "projectsSkipped", "sectionsSkipped", "labelsSkipped", "tasksSkipped"] {
            let count = app.descendants(matching: .any)["todoistReceipt-" + key].firstMatch
            XCTAssertTrue(count.exists, "Each receipt must retain its own label and value")
            let skipped = key.hasSuffix("Skipped")
            let noun = String(key.dropLast(skipped ? 7 : 8)).capitalized
            XCTAssertEqual(count.label, noun + (skipped ? " already imported" : " imported"))
            XCTAssertEqual(count.value as? String, skipped ? (key == "tasksSkipped" ? "4" : "2") : "0")
        }
    }


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
        picker.click(); app.buttons["focusTaskChoice-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa31"].click(); app.buttons["startFocus"].click()
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
        XCTAssertTrue(picker.waitForExistence(timeout: 10)); picker.click(); app.buttons["focusTaskChoice-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa31"].click(); app.buttons["startFocus"].click()
        XCTAssertTrue(app.staticTexts["focusStatus"].waitForExistence(timeout: 5)); app.buttons["pauseResumeFocus"].click()
        XCTAssertEqual(app.staticTexts["focusStatus"].label, "Paused"); let remaining = app.staticTexts["focusRemaining"].label
        app.buttons["closeFocusSession"].click(); app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        let open = app.buttons["openFocusSession"]; XCTAssertTrue(open.waitForExistence(timeout: 10)); open.click()
        XCTAssertEqual(app.staticTexts["focusStatus"].label, "Paused"); XCTAssertEqual(app.staticTexts["focusRemaining"].label, remaining)
        app.buttons["pauseResumeFocus"].click(); XCTAssertEqual(app.staticTexts["focusStatus"].label, "Time to focus")
        app.buttons["endFocus"].click(); XCTAssertEqual(app.staticTexts["focusStatus"].label, "Session ended"); app.terminate()
    }
    @MainActor func testStrictClockFeedbackSuggestionAndRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--quick-entry-fixture"]; app.launch(); defer { app.terminate() }
        app.typeKey("n", modifierFlags: .command)
        let input = app.textFields["quickAdd"]; XCTAssertTrue(input.waitForExistence(timeout: 5)); input.click(); input.typeText("Literal clock at 13pm")
        let warning = app.staticTexts["quickEntryWarning"].firstMatch; XCTAssertTrue(warning.waitForExistence(timeout: 5)); XCTAssertTrue(warning.label.contains("valid planned time"))
        app.buttons["Add Task"].click(); app.typeKey("n", modifierFlags: .command); input.click(); input.typeText("Clock plan tomorrow in the mor")
        let choice = app.buttons["referenceSuggestion-due_time:planning:in the morning"]; XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.click(); app.buttons["Add Task"].click()
        app.buttons["Inbox"].firstMatch.click(); XCTAssertTrue(app.staticTexts["Clock plan"].waitForExistence(timeout: 5))
        app.typeKey("n", modifierFlags: .command); input.click(); input.typeText("Clock shift at midnight")
        let rollover = app.descendants(matching: .any).matching(identifier: "chip-due_time").firstMatch
        XCTAssertTrue(rollover.waitForExistence(timeout: 5)); XCTAssertTrue(rollover.label.contains("Tomorrow")); app.buttons["Add Task"].click()
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch(); XCTAssertTrue(app.staticTexts["Clock plan"].waitForExistence(timeout: 5)); XCTAssertTrue(app.staticTexts["Clock shift"].exists); XCTAssertTrue(app.staticTexts["Literal clock at 13pm"].exists)
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
        let link = app.buttons["taskRepeat"]
        for _ in 0..<8 where !link.isHittable { app.scrollViews.element(boundBy: max(0, app.scrollViews.count - 1)).swipeUp() }
        XCTAssertTrue(link.isHittable); link.click(); XCTAssertTrue(app.staticTexts["repeatRuleSummary"].waitForExistence(timeout: 5))
        XCTAssertTrue((link.value as? String)?.hasPrefix("Expanded.") == true)
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue((link.value as? String)?.hasPrefix("Collapsed.") == true)
        XCTAssertFalse(app.staticTexts["repeatRuleSummary"].exists)
        XCTAssertEqual(app.textFields["taskTitle"].value as? String, name, "Space on Repeat must not complete the selected task")
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(app.staticTexts["repeatRuleSummary"].waitForExistence(timeout: 5))
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
        let link = app.buttons["taskRepeat"]
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

    @MainActor func testPlannerEstimateValidationCancelAndRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--planner-fixture"]; app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["plannerShowAllDay"].waitForExistence(timeout: 10)); app.buttons["plannerShowAllDay"].click()
        let report = app.buttons["plannerAllDay-planner-report"]; XCTAssertTrue(report.waitForExistence(timeout: 5)); report.click()
        let estimate = app.textFields["plannerEstimate"]; XCTAssertTrue(estimate.waitForExistence(timeout: 5)); XCTAssertEqual(estimate.value as? String, "25")
        estimate.click(); estimate.typeKey("a", modifierFlags: .command); estimate.typeText("0")
        XCTAssertFalse(app.buttons["plannerSave"].isEnabled); XCTAssertTrue(app.staticTexts["plannerEstimateValidation"].exists)
        estimate.click(); estimate.typeKey("a", modifierFlags: .command); estimate.typeText("45")
        XCTAssertTrue(app.buttons["plannerSave"].isEnabled); XCTAssertFalse(app.staticTexts["plannerEstimateValidation"].exists)
        app.buttons["Cancel"].click(); XCTAssertTrue(report.waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["plannerUndo"].exists)
        app.terminate(); app.launchArguments = ["--uitesting", "--section=calendar", "--calendar-mode=day"]; app.launch()
        app.buttons["Calendar"].firstMatch.click(); XCTAssertTrue(app.buttons["plannerShowAllDay"].waitForExistence(timeout: 10)); app.buttons["plannerShowAllDay"].click()
        XCTAssertTrue(report.waitForExistence(timeout: 5)); report.click(); XCTAssertEqual(estimate.value as? String, "25"); app.buttons["Cancel"].click()
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



    @MainActor func testCreationFiltersValidationAndRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--filter-creation-fixture"]; app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["newSavedView"].waitForExistence(timeout: 10)); app.buttons["newSavedView"].click()
        let name = "Creation dates " + String(UUID().uuidString.prefix(6))
        let field = app.textFields["savedViewName"]; XCTAssertTrue(field.waitForExistence(timeout: 5)); field.click(); field.typeText(name)
        app.descendants(matching: .any)["advancedFilter"].click()
        let expression = app.textFields["filterExpression"]; XCTAssertTrue(expression.waitForExistence(timeout: 5)); app.buttons["clearFilterExpression"].click(); expression.click(); expression.typeText("created:today at 14:00")
        XCTAssertFalse(app.buttons["saveSavedView"].isEnabled); XCTAssertTrue(app.staticTexts["filterValidationError"].label.contains("creation date without a time"))
        app.buttons["clearFilterExpression"].click(); expression.click(); expression.typeText("created before:-30 days"); XCTAssertTrue(app.buttons["saveSavedView"].isEnabled); app.buttons["saveSavedView"].click()
        let view = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", name, name)).firstMatch; XCTAssertTrue(view.waitForExistence(timeout: 5)); view.click()
        XCTAssertTrue(app.buttons["Complete Older reference"].waitForExistence(timeout: 5)); for title in ["Recent addition", "Unknown creation", "Old completed task"] { XCTAssertFalse(app.buttons["Complete " + title].exists) }
        view.rightClick(); app.menuItems["Edit filter"].click(); app.descendants(matching: .any)["advancedFilter"].click()
        app.buttons["clearFilterExpression"].click(); expression.click(); expression.typeText("created after:-30 days"); app.buttons["saveSavedView"].click()
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch(); XCTAssertTrue(view.waitForExistence(timeout: 5)); view.click()
        XCTAssertTrue(app.buttons["Complete Recent addition"].waitForExistence(timeout: 5)); for title in ["Older reference", "Unknown creation", "Old completed task"] { XCTAssertFalse(app.buttons["Complete " + title].exists) }
        view.rightClick(); app.menuItems["Edit filter"].click()
        let value = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "filterConditionValue-")).firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 5)); XCTAssertEqual(value.value as? String, "30 days ago"); app.buttons["Cancel"].click()
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


    @MainActor func testConflictUseSyncedPreservesLaterOfflineEstimateAndRelaunch() throws {
        try walkCommentConflict(keepLocal: false, legacyEmpty: false)
    }
    @MainActor func testLegacyNullCollectionKeepMyEditRetainsRemoteCommentsAndRelaunch() throws {
        try walkCommentConflict(keepLocal: true, legacyEmpty: true)
    }
    @MainActor func testLegacyNullCollectionUseSyncedRetainsRemoteCommentsAndRelaunch() throws {
        try walkCommentConflict(keepLocal: false, legacyEmpty: true)
    }
    @MainActor private func walkCommentConflict(keepLocal: Bool, legacyEmpty: Bool) throws {
        guard Bundle(for: Self.self).bundleIdentifier == "com.dbakp.taskfold.mac.backupcanceltests.runner" else {
            throw XCTSkip("Dedicated isolated native acceptance app required")
        }
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--conflict-fixture"] + (legacyEmpty ? ["--legacy-null-collection-fixture"] : [])
        liveConflictLaunch(app); defer { app.terminate() }
        let cache = URL(fileURLWithPath: "/Users/" + NSUserName() + "/Library/Containers/com.dbakp.taskfold.mac.backupcanceltests/Data/Library/Application Support/Taskfold/ui-testing.json")
        func saved() throws -> NSDictionary { try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! NSDictionary }
        let review = app.links["reviewSyncConflict"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Retry"].exists, "A conflict needs Review, not another retry")
        XCTAssertFalse(app.links["Retry"].exists, "Link-styled retry must also be absent")
        let before = try saved()
        let originalPending = try XCTUnwrap(before["pending"] as? [NSDictionary])
        XCTAssertEqual(originalPending.count, 2)
        if legacyEmpty {
            XCTAssertTrue((originalPending[0]["baseline"] as? NSDictionary)?["comments"] is NSNull)
        }
        let seededTables = try XCTUnwrap(before["tables"] as? NSDictionary)
        XCTAssertEqual((seededTables["tasks"] as? [NSDictionary])?.first?["duration_minutes"] as? Int, 45)
        review.click()
        XCTAssertTrue(app.buttons["conflictLater"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Later")).count, 1)
        XCTAssertTrue(app.buttons["conflictLater"].isEnabled)
        app.buttons["conflictLater"].click()
        XCTAssertTrue(review.waitForExistence(timeout: 5)); XCTAssertEqual(try saved(), before)
        review.click()
        let sheet = app.sheets.firstMatch
        let capture = XCTAttachment(screenshot: sheet.screenshot())
        capture.name = "Mac offline conflict before choosing synced comment"; capture.lifetime = .keepAlways; add(capture)
        app.buttons[keepLocal ? "keepMyEdit" : "useSharedEdit"].click()
        XCTAssertTrue(waitForDisappearance(review, timeout: 5))
        let after = try saved()
        let afterPending = try XCTUnwrap(after["pending"] as? [NSDictionary])
        if keepLocal {
            XCTAssertEqual(afterPending.count, 2)
            XCTAssertEqual(afterPending.last, originalPending.last, "Retain the exact later estimate")
        } else { XCTAssertEqual(afterPending, [originalPending[1]], "Discard only the reviewed comment edit") }
        let beforeTables = try XCTUnwrap(before["tables"] as? NSDictionary)
        let afterTables = try XCTUnwrap(after["tables"] as? NSDictionary)
        let originalTask = try XCTUnwrap((beforeTables["tasks"] as? [NSDictionary])?.first)
        let currentTask = try XCTUnwrap((afterTables["tasks"] as? [NSDictionary])?.first)
        let expectedTask = originalTask.mutableCopy() as! NSMutableDictionary
        var expectedComments = [["id": legacyEmpty ? "remote" : "a", "text": "Shared revised comment"], ["id": "b", "text": "Independent teammate comment"]]
        if keepLocal { expectedComments.append(["id": "a", "text": "My revised comment"]) }
        expectedTask["comments"] = expectedComments
        XCTAssertEqual(currentTask, expectedTask, "Retain every other task field, including the later estimate")
        for key in beforeTables.allKeys as! [String] where key != "tasks" { XCTAssertEqual(afterTables[key] as? NSArray, beforeTables[key] as? NSArray) }
        app.staticTexts["title-conflict-task"].click()
        XCTAssertTrue(app.staticTexts["Shared revised comment"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.steppers["taskDuration"].exists)
        XCTAssertTrue(app.staticTexts["Estimate · 45 min"].exists || (app.steppers["taskDuration"].value as? NSNumber)?.intValue == 45 || app.steppers["taskDuration"].value as? String == "45", app.steppers["taskDuration"].debugDescription)
        XCTAssertTrue(app.staticTexts["Independent teammate comment"].exists)
        if keepLocal { XCTAssertTrue(app.staticTexts["My revised comment"].exists) }
        else { XCTAssertFalse(app.staticTexts["My revised comment"].exists) }
        retainWindow(app, name: "Mac synced comment keeps independent work")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        app.launchArguments = ["--uitesting"]; liveConflictLaunch(app)
        XCTAssertTrue(app.staticTexts["title-conflict-task"].waitForExistence(timeout: 10))
        app.staticTexts["title-conflict-task"].click()
        XCTAssertTrue(app.staticTexts["Shared revised comment"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.steppers["taskDuration"].exists)
        XCTAssertTrue(app.staticTexts["Estimate · 45 min"].exists || (app.steppers["taskDuration"].value as? NSNumber)?.intValue == 45 || app.steppers["taskDuration"].value as? String == "45", app.steppers["taskDuration"].debugDescription)
        XCTAssertTrue(app.staticTexts["Independent teammate comment"].exists)
        if keepLocal { XCTAssertTrue(app.staticTexts["My revised comment"].exists) }
        XCTAssertEqual(try saved(), after, "Normal Quit/relaunch must preserve the whole resolved workspace")
        retainWindow(app, name: "Mac offline conflict resolution retained after normal Quit")
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
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--deletion-conflict-fixture"]; app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.links["reviewSyncConflict"].waitForExistence(timeout: 10)); app.links["reviewSyncConflict"].click()
        XCTAssertTrue(app.buttons["useSharedEdit"].waitForExistence(timeout: 5)); XCTAssertEqual(app.buttons["useSharedEdit"].label, "Keep task")
        XCTAssertEqual(app.buttons["keepMyEdit"].label, "Delete task")
        let form = app.sheets.scrollViews.firstMatch
        for _ in 0..<3 { form.scroll(byDeltaX: 0, deltaY: -600) }
        let capture = XCTAttachment(screenshot: app.sheets.firstMatch.screenshot())
        capture.name = "Mac deletion review task contents and actions"; capture.lifetime = .keepAlways; add(capture)
        app.buttons["useSharedEdit"].click()
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

    private func renderedText(_ element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    private func retainWindow(_ app: XCUIApplication, name: String) {
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = name; capture.lifetime = .keepAlways; add(capture)
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
    @MainActor func testPinnedNoteReadEditUnpinUndoAndRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--pinned-notes-seed", "--widget-action-testing", "--pinned-notes-testing"]; app.launch()
        XCTAssertTrue(app.staticTexts["noteProjection"].waitForExistence(timeout: 10)); XCTAssertEqual(renderedText(app.staticTexts["noteProjection"]), "Notes: 2 · Private: hidden")
        app.buttons["openPinnedNotes"].click(); XCTAssertTrue(app.buttons["pinnedNote-note-first"].waitForExistence(timeout: 5)); app.buttons["pinnedNote-note-first"].click()
        XCTAssertTrue(app.staticTexts["pinnedNoteText"].waitForExistence(timeout: 5)); XCTAssertTrue(renderedText(app.staticTexts["pinnedNoteText"]).contains("Final instruction"))
        app.buttons["editPinnedNote"].click()
        let input = app.descendants(matching: .any).matching(identifier: "taskDescription").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.click(); input.typeText("\nEdited on Mac.")
        XCTAssertTrue(app.buttons["Done"].exists, "Return in notes must insert a line break rather than close the editor")
        XCTAssertTrue((input.value as? String ?? "").contains("\nEdited on Mac."))
        app.buttons["Done"].click(); XCTAssertTrue(renderedText(app.staticTexts["pinnedNoteText"]).contains("Edited on Mac."))
        retainWindow(app, name: "Pinned note edited on Mac")
        app.buttons["unpinNote"].click(); app.buttons["closePinnedNotes"].click()
        XCTAssertEqual(renderedText(app.staticTexts["noteProjection"]), "Notes: 1 · Private: hidden")
        app.typeKey("z", modifierFlags: .command); XCTAssertEqual(renderedText(app.staticTexts["noteProjection"]), "Notes: 2 · Private: hidden")
        app.terminate(); app.launchArguments.removeAll { $0 == "--pinned-notes-seed" }; app.launch()
        XCTAssertTrue(app.staticTexts["noteProjection"].waitForExistence(timeout: 10)); XCTAssertEqual(renderedText(app.staticTexts["noteProjection"]), "Notes: 2 · Private: hidden")
        app.buttons["openPinnedNotes"].click(); app.buttons["pinnedNote-note-first"].click()
        XCTAssertTrue(app.staticTexts["pinnedNoteText"].waitForExistence(timeout: 5))
        XCTAssertTrue(renderedText(app.staticTexts["pinnedNoteText"]).contains("Edited on Mac."))
        retainWindow(app, name: "Pinned note edit survives Mac relaunch")
        app.terminate()
    }

}

extension TaskfoldMacUITests {
    @MainActor func testProjectPulseCurrentScopeRecordedHistoryAndRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--project-pulse-seed"]; app.launch()
        XCTAssertTrue(app.buttons["openProjectPulse"].waitForExistence(timeout: 10)); app.buttons["openProjectPulse"].click()
        let picker = app.descendants(matching: .any).matching(identifier: "pulseProjectPicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.click(); picker.menuItems["Studio"].click()
        XCTAssertTrue(app.staticTexts["pulseProgress"].waitForExistence(timeout: 5)); XCTAssertEqual(renderedText(app.staticTexts["pulseProgress"]), "1 of 3 completed")
        let counts = app.staticTexts["pulseActivityCounts"]
        for _ in 0..<8 where !counts.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -350) }
        XCTAssertEqual(renderedText(counts), "2 completion events · 1 reopen event")
        XCTAssertTrue(renderedText(app.staticTexts["pulseHistoryCoverage"]).contains("Earlier work has no recorded timeline."))
        retainWindow(app, name: "Project pulse history on Mac")
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(app.buttons["openProjectPulse"].waitForExistence(timeout: 10)); app.buttons["openProjectPulse"].click()
        let again = app.descendants(matching: .any).matching(identifier: "pulseProjectPicker").firstMatch
        again.click(); again.menuItems["Studio"].click()
        XCTAssertEqual(renderedText(app.staticTexts["pulseProgress"]), "1 of 3 completed")
        for _ in 0..<8 where !counts.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -350) }
        XCTAssertEqual(renderedText(counts), "2 completion events · 1 reopen event"); app.terminate()
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


extension TaskfoldMacUITests {
    @MainActor func testFocusSearchDuplicateContextCancelAndRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--focus-session-seed", "--focus-catalog-seed"]; app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["openFocusSession"].waitForExistence(timeout: 10)); app.buttons["openFocusSession"].click()
        app.buttons["focusTaskPicker"].click()
        let search = app.descendants(matching: .any)["focusTaskSearch"].firstMatch; XCTAssertTrue(search.waitForExistence(timeout: 5)); search.click(); search.typeText("proposal")
        let home = app.buttons["focusTaskChoice-aaaaaaaa-aaaa-4aaa-8aaa-000000001249"], studio = app.buttons["focusTaskChoice-aaaaaaaa-aaaa-4aaa-8aaa-000000001248"]
        XCTAssertTrue(home.waitForExistence(timeout: 5)); XCTAssertTrue(studio.exists); XCTAssertTrue(home.label.contains("Home")); XCTAssertTrue(studio.label.contains("Client launch"))
        home.click(); app.buttons["focusTaskPicker"].click(); app.buttons["cancelFocusTaskChoice"].click()
        XCTAssertTrue(app.buttons["focusTaskPicker"].label.contains("Home")); app.buttons["startFocus"].click()
        XCTAssertTrue(app.staticTexts["focusStatus"].waitForExistence(timeout: 5)); XCTAssertEqual(renderedText(app.staticTexts["focusTaskContext"]), "Home"); app.buttons["pauseResumeFocus"].click()
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch(); app.buttons["openFocusSession"].click()
        XCTAssertEqual(renderedText(app.staticTexts["focusStatus"]), "Paused"); XCTAssertEqual(renderedText(app.staticTexts["focusTaskContext"]), "Home")
        retainWindow(app, name: "Focus paused context after Mac relaunch")
    }
}

extension TaskfoldMacUITests {
    @MainActor func testElapsedFilterMinuteRefreshValidationAndRelaunch() throws {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--clock-window-testing", "--clock-window-fixture"]; app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["newSavedView"].waitForExistence(timeout: 10)); app.buttons["newSavedView"].click()
        let name = "Next minute " + String(UUID().uuidString.prefix(6))
        let field = app.textFields["savedViewName"]; XCTAssertTrue(field.waitForExistence(timeout: 5)); field.click(); field.typeText(name)
        app.descendants(matching: .any)["advancedFilter"].click()
        let expression = app.textFields["filterExpression"]; XCTAssertTrue(expression.waitForExistence(timeout: 5)); app.buttons["clearFilterExpression"].click(); expression.click(); expression.typeText("date before:+169 hours")
        XCTAssertFalse(app.buttons["saveSavedView"].isEnabled)
        app.buttons["clearFilterExpression"].click(); expression.click(); expression.typeText("date before:+1 minute"); XCTAssertTrue(app.buttons["saveSavedView"].isEnabled); app.buttons["saveSavedView"].click()
        let view = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", name, name)).firstMatch; XCTAssertTrue(view.waitForExistence(timeout: 5)); view.click()
        XCTAssertTrue(app.buttons["Complete Window past"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["Complete Window boundary"].exists)
        app.buttons["calendarFixtureAdvanceWindow"].click()
        XCTAssertTrue(app.buttons["Complete Window boundary"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["Complete Window later"].exists)
        XCTAssertEqual(app.staticTexts["calendarFixtureWindowStatus"].label, "Task plans unchanged")
        app.terminate(); app.launchArguments = ["--uitesting", "--clock-window-testing", "--clock-window-shifted"]; app.launch(); XCTAssertTrue(view.waitForExistence(timeout: 5)); view.click()
        XCTAssertTrue(app.buttons["Complete Window boundary"].waitForExistence(timeout: 5)); for title in ["Window later", "Window all day", "Window deadline only"] { XCTAssertFalse(app.buttons["Complete " + title].exists) }
        view.rightClick(); app.menuItems["Edit filter"].click()
        let value = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "filterConditionValue-")).firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 5)); XCTAssertEqual(value.value as? String, "+1 minute"); app.buttons["Cancel"].click()
    }
}


extension TaskfoldMacUITests {
    @MainActor func testDatePhrasePreferencesGeneralSettingsPersist() throws {
        let app=XCUIApplication();app.launchArguments=["--uitesting","--date-phrase-testing","--date-phrase-fixture","--open-settings=general"];app.launch();defer { app.terminate() }
        let week=app.popUpButtons["datePhraseNextWeek"].firstMatch
        XCTAssertTrue(week.waitForExistence(timeout:8));week.click();app.menuItems["Friday"].firstMatch.click()
        let weekend=app.popUpButtons["datePhraseWeekend"].firstMatch;weekend.click();app.menuItems["Sunday"].firstMatch.click()
        XCTAssertTrue(week.value as? String=="Friday");XCTAssertTrue(weekend.value as? String=="Sunday")
        app.terminate();app.launchArguments.removeAll { $0=="--date-phrase-fixture" };app.launch()
        XCTAssertTrue(week.waitForExistence(timeout:8));XCTAssertTrue(week.value as? String=="Friday");XCTAssertTrue(weekend.value as? String=="Sunday")
    }
}


extension TaskfoldMacUITests {
    @MainActor func testLiveLocalToCloudProfileAndPhoneEditReceive() throws {
        let fixtureURL = URL(fileURLWithPath: "/private/tmp/taskfold-live-verification.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else { throw XCTSkip("Disposable continuity account not configured") }
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fixtureURL))
        let account = try XCTUnwrap(fixture["userID"])
        guard UUID(uuidString: account) != nil,
              fixture["email"] == "taskfold-continuity-" + account + "@example.invalid" else {
            throw XCTSkip("Native cloud walk requires the disposable account namespace")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--live-auth-ui-test"]
        app.launch(); defer { app.terminate() }
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Account"].firstMatch.waitForExistence(timeout: 8))
        app.buttons["Account"].firstMatch.click()
        let login = app.buttons["accountSignIn"]
        XCTAssertTrue(login.waitForExistence(timeout: 5)); login.click()
        let email = app.textFields["authEmail"], password = app.secureTextFields["authPassword"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.click(); email.typeText(try XCTUnwrap(fixture["email"]))
        password.click(); password.typeText(try XCTUnwrap(fixture["password"]))
        app.buttons["nativeSignIn"].click()
        XCTAssertTrue(app.buttons["Save Profile"].waitForExistence(timeout: 25), "Cloud account must replace the local Account form")
        let name = app.windows["Account"].textFields.firstMatch
        XCTAssertTrue(name.exists, "Account form must expose its profile-name field")
        XCTAssertEqual(name.value as? String, "Native Handoff Test", "Untouched profile draft must follow the signed-in account")
        retainWindow(app, name: "Local to cloud profile draft on Mac")
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("2", modifierFlags: .command)
        let title = "Continuity 9a8bfc3d revised"
        let row = app.descendants(matching: .any)["title-101fbaab-af99-480c-97a6-4876bc3e7389"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.click()
        let editor = app.descendants(matching: .any)["taskTitle"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); XCTAssertEqual(editor.value as? String, title)
        let notes = app.descendants(matching: .any)["taskDescription"].firstMatch
        XCTAssertEqual(notes.value as? String, "Created in the native Mac app for device-switch verification.")
        retainWindow(app, name: "Phone edit received in native Mac inspector")
        let pin = app.descendants(matching: .any)["pinTaskNotes"].firstMatch
        XCTAssertEqual((pin.value as? NSNumber)?.intValue, 0, "Disposable task should begin unpinned; observed \(String(describing: pin.value))")
        pin.click(); XCTAssertEqual((pin.value as? NSNumber)?.intValue, 1)
        app.buttons["openFocusSession"].click()
        app.buttons["focusTaskPicker"].click()
        let search = app.descendants(matching: .any)["focusTaskSearch"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.click(); search.typeText("Continuity")
        let choice = app.buttons["focusTaskChoice-101fbaab-af99-480c-97a6-4876bc3e7389"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.click()
        app.buttons["startFocus"].click(); app.buttons["pauseResumeFocus"].click()
        XCTAssertEqual(renderedText(app.staticTexts["focusStatus"]), "Paused")
        retainWindow(app, name: "Cloud task pinned and Focus paused on Mac")
        app.buttons["closeFocusSession"].click()
        app.typeKey("r", modifierFlags: .command)
    }
}


extension TaskfoldMacUITests {
    @MainActor func testLivePhoneNoteAndEndedFocusReturnToMac() throws {
        let fixtureURL = URL(fileURLWithPath: "/private/tmp/taskfold-live-verification.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else { throw XCTSkip("Disposable continuity account not configured") }
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fixtureURL))
        guard fixture["userID"] == "9a8bfc3d-42ec-4c89-8f1d-c830b2215152",
              fixture["email"] == "taskfold-continuity-9a8bfc3d-42ec-4c89-8f1d-c830b2215152@example.invalid" else { throw XCTSkip("Disposable fixture required") }
        let app = XCUIApplication(); app.launchArguments = []; app.launch(); defer { app.terminate() }
        for pass in 0..<2 {
            app.typeKey("2", modifierFlags: .command)
            let row = app.descendants(matching: .any)["title-101fbaab-af99-480c-97a6-4876bc3e7389"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20)); row.click()
            let notes = app.descendants(matching: .any)["taskDescription"].firstMatch
            XCTAssertTrue(notes.waitForExistence(timeout: 5))
            let received = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Phone added a durable handoff note."), object: notes)
            XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 20), .completed)
            XCTAssertTrue((notes.value as? String ?? "").contains("Created in the native Mac app for device-switch verification."))
            XCTAssertEqual((app.descendants(matching: .any)["pinTaskNotes"].firstMatch.value as? NSNumber)?.intValue, 1)
            retainWindow(app, name: "Phone note and Mac pin retained — pass \(pass)")
            app.buttons["openFocusSession"].click()
            let status = app.staticTexts["focusStatus"]
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            let ended = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@ OR label == %@", "Session ended", "Session ended"), object: status)
            XCTAssertEqual(XCTWaiter.wait(for: [ended], timeout: 20), .completed)
            XCTAssertEqual(renderedText(app.staticTexts["focusTaskTitle"]), "Continuity 9a8bfc3d revised")
            retainWindow(app, name: "Phone-ended Focus received on Mac — pass \(pass)")
            app.buttons["closeFocusSession"].click()
            if pass == 0 { app.terminate(); app.launch() }
        }
    }

    /// Checks the native-created cloud organization without rebuilding or seeding data.
    @MainActor func testLiveOrganizationAndFilterPersistAfterMacRelaunch() throws {
        let fixtureURL = URL(fileURLWithPath: "/private/tmp/taskfold-live-verification.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else { throw XCTSkip("Disposable continuity account not configured") }
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fixtureURL))
        guard fixture["userID"] == "9a8bfc3d-42ec-4c89-8f1d-c830b2215152" else { throw XCTSkip("Dedicated organization fixture required") }
        let app = XCUIApplication(); app.launchArguments = []; app.launch(); defer { app.terminate() }
        for pass in 0..<2 {
            let project = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", "Continuity Studio", "Continuity Studio")).firstMatch
            XCTAssertTrue(project.waitForExistence(timeout: 15)); project.click()
            let row = app.descendants(matching: .any)["title-101fbaab-af99-480c-97a6-4876bc3e7389"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10)); row.click()
            let section = app.popUpButtons.matching(NSPredicate(format: "value == %@", "Ready")).firstMatch
            XCTAssertTrue(section.waitForExistence(timeout: 5)); XCTAssertEqual(section.value as? String, "Ready")
            XCTAssertTrue(app.popUpButtons.matching(NSPredicate(format: "value == %@", "Continuity Studio")).firstMatch.exists)
            XCTAssertTrue(app.scrollViews["inspector"].staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", "handoff", "handoff")).firstMatch.exists)
            XCTAssertEqual((app.descendants(matching: .any)["pinTaskNotes"].firstMatch.value as? NSNumber)?.intValue, 1)
            XCTAssertEqual(app.descendants(matching: .any)["taskDescription"].firstMatch.value as? String, "\nPhone added a durable handoff note.Created in the native Mac app for device-switch verification.")
            retainWindow(app, name: "Native Mac project section label and notes — pass \(pass)")
            let filter = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", "Handoff priorities", "Handoff priorities")).firstMatch
            XCTAssertTrue(filter.exists); filter.click()
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            retainWindow(app, name: "Native Mac label priority filter — pass \(pass)")
            if pass == 0 { app.terminate(); app.launch() }
        }
    }

    @MainActor func testLivePhoneOfflineOrganizationRenameReturnsToMac() throws {
        let fixtureURL = URL(fileURLWithPath: "/private/tmp/taskfold-live-verification.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else { throw XCTSkip("Disposable continuity account not configured") }
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fixtureURL))
        guard fixture["userID"] == "9a8bfc3d-42ec-4c89-8f1d-c830b2215152" else { throw XCTSkip("Dedicated organization fixture required") }
        let app = XCUIApplication(); app.launchArguments = []; app.launch(); defer { app.terminate() }
        for pass in 0..<2 {
            let project = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", "Continuity Studio revised", "Continuity Studio revised")).firstMatch
            XCTAssertTrue(project.waitForExistence(timeout: 20)); project.click()
            let row = app.descendants(matching: .any)["title-101fbaab-af99-480c-97a6-4876bc3e7389"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10)); row.click()
            XCTAssertTrue(app.popUpButtons.matching(NSPredicate(format: "value == %@", "Ready on phone")).firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(app.popUpButtons.matching(NSPredicate(format: "value == %@", "Continuity Studio revised")).firstMatch.exists)
            XCTAssertEqual(app.descendants(matching: .any)["taskDescription"].firstMatch.value as? String, "\nPhone added a durable handoff note.Created in the native Mac app for device-switch verification.")
            XCTAssertEqual((app.descendants(matching: .any)["pinTaskNotes"].firstMatch.value as? NSNumber)?.intValue, 1)
            retainWindow(app, name: "Phone offline project and section renames received on Mac — pass \(pass)")
            let label = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", "handoff-ready", "handoff-ready")).firstMatch
            XCTAssertTrue(label.exists); label.click(); XCTAssertTrue(row.waitForExistence(timeout: 5))
            let filter = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", "Handoff priorities", "Handoff priorities")).firstMatch
            XCTAssertTrue(filter.exists); filter.click(); XCTAssertTrue(row.waitForExistence(timeout: 5))
            retainWindow(app, name: "Mac filter retains original task after phone label rename — pass \(pass)")
            if pass == 0 { app.terminate(); app.launch() }
        }
    }

    @MainActor func testLiveRichPlanningCaptureOnMac() throws {
        let fixtureURL = URL(fileURLWithPath: "/private/tmp/taskfold-live-verification.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else { throw XCTSkip("Disposable continuity account not configured") }
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fixtureURL))
        guard fixture["userID"] == "9a8bfc3d-42ec-4c89-8f1d-c830b2215152" else { throw XCTSkip("Dedicated planning fixture required") }
        let app = XCUIApplication(); app.launchArguments = []; app.launch(); defer { app.terminate() }
        app.typeKey("n", modifierFlags: .command)
        let input = app.textFields["quickAdd"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.click()
        input.typeText(#"Planning 9a8bfc3d #"Continuity Studio revised" /"Ready on phone" @"handoff-ready" p1 every day from 3 January 2028 until 5 January 2028 for 3 occurrences at 09:00 ~45m {6 January 2028} !15mb !30mb"#)
        for field in ["project_id", "section_id", "labels", "priority", "recurrence", "due_time", "duration_minutes", "deadline_date"] {
            XCTAssertTrue(app.buttons["decline-" + field].waitForExistence(timeout: 5), "Missing capture chip: \(field)")
        }
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "decline-reminder_specs:")).count, 2)
        let summary = renderedText(app.staticTexts["quickRepeatSummary"])
        for phrase in ["Every day", "2028-01-05", "3 left"] { XCTAssertTrue(summary.contains(phrase), summary) }
        retainWindow(app, name: "Native Mac rich planning capture preview")
        app.buttons["Add Task"].click()
        let complete = app.buttons["Complete Planning 9a8bfc3d"]
        XCTAssertTrue(complete.waitForExistence(timeout: 10))
        let taskID = String(complete.identifier.dropFirst("complete-".count))
        XCTAssertNotNil(UUID(uuidString: taskID))
        for pass in 0..<2 {
            let row = app.descendants(matching: .any)["title-" + taskID].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10)); row.click()
            let estimate = app.descendants(matching: .any)["taskDuration"].firstMatch.value
            XCTAssertEqual((estimate as? String) ?? (estimate as? NSNumber)?.stringValue, "45")
            XCTAssertTrue(app.descendants(matching: .any)["taskDeadline"].firstMatch.exists)
            XCTAssertTrue(app.popUpButtons.matching(NSPredicate(format: "value == %@", "Ready on phone")).firstMatch.exists)
            retainWindow(app, name: "Native Mac rich planning inspector — pass \(pass)")
            let reminders = app.buttons["taskReminders"]
            for _ in 0..<8 where !reminders.isHittable { app.scrollViews["inspector"].swipeUp() }
            XCTAssertTrue(reminders.isHittable); reminders.click()
            XCTAssertTrue(app.buttons["15 min before"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["30 min before"].exists)
            retainWindow(app, name: "Native Mac multiple planning reminders — pass \(pass)")
            app.buttons["Done"].click()
            if pass == 0 { app.terminate(); app.launch() }
        }
    }

    @MainActor func testLiveResolvedPlanningSuggestionOnMac() throws {
        let fixtureURL = URL(fileURLWithPath: "/private/tmp/taskfold-live-verification.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else { throw XCTSkip("Disposable continuity account not configured") }
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fixtureURL))
        guard fixture["userID"] == "9a8bfc3d-42ec-4c89-8f1d-c830b2215152" else { throw XCTSkip("Dedicated planning fixture required") }
        let app = XCUIApplication(); app.launchArguments = []; app.launch(); defer { app.terminate() }
        app.typeKey("n", modifierFlags: .command)
        let input = app.textFields["quickAdd"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.click()
        input.typeText(#"Preview #"Continuity Studio revised" /"Ready on phone" tomorrow at 09:00 !30mb"#)
        let option = app.buttons["referenceSuggestion-reminder_specs:planning:!30mb"]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        XCTAssertFalse(option.label.contains("Choose a section"), option.label)
        XCTAssertTrue(app.buttons["decline-section_id"].exists)
        retainWindow(app, name: "Resolved section reminder preview on Mac")
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor private func inspectReturnedPlanningOccurrence(_ app: XCUIApplication, id: String, remaining: Int) {
        let row = app.descendants(matching: .any)["title-" + id].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.click()
        let estimate = app.descendants(matching: .any)["taskDuration"].firstMatch.value
        XCTAssertEqual((estimate as? String) ?? (estimate as? NSNumber)?.stringValue, "45")
        XCTAssertEqual(app.descendants(matching: .any)["taskDeadline"].firstMatch.exists, remaining == 3)
        let rule = app.descendants(matching: .any)["taskRepeat"].firstMatch
        for _ in 0..<8 where !rule.isHittable { app.scrollViews["inspector"].swipeUp() }
        XCTAssertTrue(rule.isHittable)
        for phrase in ["Every day", "2028-01-05", "\(remaining) left"] { XCTAssertTrue(rule.label.contains(phrase), rule.label) }
        retainWindow(app, name: "Phone completion returned to Mac — \(remaining) left")
        let reminders = app.buttons["taskReminders"]
        for _ in 0..<8 where !reminders.isHittable { app.scrollViews["inspector"].swipeUp() }
        XCTAssertTrue(reminders.isHittable); reminders.click()
        XCTAssertTrue(app.buttons["15 min before"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["30 min before"].exists)
        retainWindow(app, name: "Returned occurrence retains multiple reminders — \(remaining) left")
        let availability = app.staticTexts["remoteReminderAvailability"]
        XCTAssertTrue(availability.exists)
        XCTAssertFalse(renderedText(availability).contains("continue on this device"), renderedText(availability))
        XCTAssertFalse(app.staticTexts["remoteReminderStatus"].exists, "Unavailable remote status must appear once")
        app.buttons["Done"].click()
    }

    @MainActor func testLivePhonePlanningCompletionReturnsToMac() throws {
        let fixtureURL = URL(fileURLWithPath: "/private/tmp/taskfold-live-verification.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else { throw XCTSkip("Disposable continuity account not configured") }
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fixtureURL))
        guard fixture["userID"] == "9a8bfc3d-42ec-4c89-8f1d-c830b2215152" else { throw XCTSkip("Dedicated planning fixture required") }
        let original = try XCTUnwrap(fixture["planningTaskID"]), successor = try XCTUnwrap(fixture["planningSuccessorID"])
        XCTAssertNotNil(UUID(uuidString: original)); XCTAssertNotNil(UUID(uuidString: successor)); XCTAssertNotEqual(original, successor)
        let app = XCUIApplication(); app.launchArguments = []; app.launch(); defer { app.terminate() }
        for pass in 0..<2 {
            let project = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", "Continuity Studio revised", "Continuity Studio revised")).firstMatch
            XCTAssertTrue(project.waitForExistence(timeout: 15)); project.click()
            XCTAssertEqual(app.buttons.matching(identifier: "Complete Planning 9a8bfc3d").count, 1)
            inspectReturnedPlanningOccurrence(app, id: successor, remaining: 2)
            let completed = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", "Completed", "Completed")).firstMatch
            XCTAssertTrue(completed.exists); completed.click()
            XCTAssertTrue(app.buttons["Reopen Planning 9a8bfc3d"].waitForExistence(timeout: 10))
            inspectReturnedPlanningOccurrence(app, id: original, remaining: 3)
            if pass == 0 { app.terminate(); app.launch() }
        }
    }
}


extension TaskfoldMacUITests {
    @MainActor func testCompactCalendarCardsOwnKeyboardFocus() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--planner-fixture", "-localMode", "YES"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["Week"].waitForExistence(timeout: 10)); app.buttons["Week"].click()
        let window = app.windows.firstMatch
        if window.frame.width > 1080 {
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -3, dy: -3))
            corner.press(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: 1080 - window.frame.width, dy: 0)))
        }
        XCTAssertFalse(app.otherElements["calendarDayPanel"].exists)
        let report = app.buttons["calendar-card-planner-report"]
        XCTAssertTrue(report.waitForExistence(timeout: 5)); report.click()
        XCTAssertEqual(report.value as? String, "Open")
        let title = app.textFields["taskTitle"]
        if title.exists { app.typeKey("i", modifierFlags: [.command, .option]) }
        report.click(); XCTAssertFalse(title.exists)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(title.waitForExistence(timeout: 5)); XCTAssertEqual(title.value as? String, "Prepare report")
        app.typeKey("i", modifierFlags: [.command, .option])
        report.click(); app.typeKey(" ", modifierFlags: [])
        XCTAssertEqual(report.value as? String, "Completed")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(report.value as? String, "Open")
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "calendar-card-"))
        XCTAssertGreaterThanOrEqual(cards.count, 2)
        let firstID = cards.element(boundBy: 0).identifier, secondID = cards.element(boundBy: 1).identifier
        app.buttons[firstID].click(); app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(app.buttons[secondID].isSelected)
        app.typeKey(.upArrow, modifierFlags: []); XCTAssertTrue(app.buttons[firstID].isSelected)
        app.typeKey(.escape, modifierFlags: []); XCTAssertFalse(app.buttons[firstID].isSelected)
        retainWindow(app, name: "Compact Calendar cards keep their own keyboard focus")
    }
}


extension TaskfoldMacUITests {
    @MainActor func testCompactMonthOpensSelectedDayTasks() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--planner-fixture", "-localMode", "YES"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["Month"].waitForExistence(timeout: 10)); app.buttons["Month"].click()
        let window = app.windows.firstMatch
        if window.frame.width > 1080 {
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -3, dy: -3))
            corner.press(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: 1080 - window.frame.width, dy: 0)))
        }
        XCTAssertFalse(app.otherElements["calendarDayPanel"].exists)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        let day = app.buttons["calendar-day-" + today]
        XCTAssertTrue(day.waitForExistence(timeout: 5)); day.click()
        XCTAssertTrue(app.buttons["Day"].isSelected)
        XCTAssertTrue(app.otherElements["hourlyPlanner"].waitForExistence(timeout: 5))
        app.buttons["plannerShowAllDay"].click()
        let task = app.buttons["Prepare report"]
        XCTAssertTrue(task.waitForExistence(timeout: 5)); task.click()
        let title = app.textFields["taskTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); XCTAssertEqual(title.value as? String, "Prepare report")
        retainWindow(app, name: "Compact Month opens its selected day's tasks")
    }
}


extension TaskfoldMacUITests {
    @MainActor func testWidgetQueueRecoveryClearsLocalWarningWithoutRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--widget-action-testing", "--widget-action-seed", "--widget-action-fail-save", "-localMode", "YES"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["widgetQueueFixture"].waitForExistence(timeout: 10))
        app.buttons["widgetQueueFixture"].click()
        app.buttons["widgetConsumeFixture"].click()
        let notice = app.staticTexts["widgetNoticeFixture"]
        XCTAssertTrue(NSPredicate(format: "label CONTAINS %@", "Widget actions need attention:").evaluate(with: notice))
        app.buttons["widgetRecoverFixture"].click()
        let clear = NSPredicate(format: "label == %@", "No widget warning")
        expectation(for: clear, evaluatedWith: notice)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "Original: completed", "Original: completed").evaluate(with: app.staticTexts["widgetRootState"]))
    }
}


extension TaskfoldMacUITests {
    @MainActor func testMonthGridKeyboardMovesDatesAcrossBoundary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--planner-fixture", "-localMode", "YES"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["Month"].waitForExistence(timeout: 10)); app.buttons["Month"].click()
        let window = app.windows.firstMatch
        if window.frame.width < 1380 {
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -3, dy: -3))
            corner.press(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: 1380 - window.frame.width, dy: 0)))
        }
        XCTAssertTrue(app.otherElements["calendarDayPanel"].exists)
        let calendar = Calendar.current
        let start = try XCTUnwrap(calendar.dateInterval(of: .month, for: Date())?.start)
        let next = try XCTUnwrap(calendar.date(byAdding: .month, value: 1, to: start))
        let last = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: next))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        func day(_ date: Date) -> XCUIElement { app.buttons["calendar-day-" + formatter.string(from: date)] }
        XCTAssertTrue(day(last).waitForExistence(timeout: 5)); day(last).click()
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(day(next).waitForExistence(timeout: 5)); XCTAssertTrue(day(next).isSelected)
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertTrue(day(last).waitForExistence(timeout: 5)); XCTAssertTrue(day(last).isSelected)
        app.typeKey(.upArrow, modifierFlags: [])
        let earlier = try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: last))
        XCTAssertTrue(day(earlier).isSelected)
        app.typeKey(.downArrow, modifierFlags: []); XCTAssertTrue(day(last).isSelected)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["Day"].isSelected)
        XCTAssertTrue(app.otherElements["hourlyPlanner"].waitForExistence(timeout: 5))
        retainWindow(app, name: "Month date keyboard movement opens exact day")
    }
}


extension TaskfoldMacUITests {
    @MainActor func testYearGridKeyboardSelectsMonthsAcrossYears() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--planner-fixture", "-localMode", "YES"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["Year"].waitForExistence(timeout: 10)); app.buttons["Year"].click()
        let calendar = Calendar.current
        let current = try XCTUnwrap(calendar.dateInterval(of: .month, for: Date())?.start)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        func month(_ date: Date) -> XCUIElement { app.buttons["calendar-month-" + formatter.string(from: date)] }
        XCTAssertTrue(month(current).waitForExistence(timeout: 5)); XCTAssertTrue(month(current).isSelected)
        app.typeKey(.downArrow, modifierFlags: [])
        let next = try XCTUnwrap(calendar.date(byAdding: .month, value: 1, to: current))
        app.typeKey(.rightArrow, modifierFlags: []); XCTAssertTrue(month(next).isSelected)
        let rowDown = try XCTUnwrap(calendar.date(byAdding: .month, value: 4, to: next))
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(month(rowDown).waitForExistence(timeout: 5)); XCTAssertTrue(month(rowDown).isSelected)
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(month(next).waitForExistence(timeout: 5)); XCTAssertTrue(month(next).isSelected)
        app.typeKey(.leftArrow, modifierFlags: []); XCTAssertTrue(month(current).isSelected)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["Month"].isSelected)
        let today = app.buttons["calendar-day-" + formatter.string(from: Date())]
        XCTAssertTrue(today.waitForExistence(timeout: 5)); XCTAssertTrue(today.isSelected)
        retainWindow(app, name: "Year keyboard month selection opens populated current month")
    }
}


extension TaskfoldMacUITests {
    @MainActor func testFocusKeyboardSearchEmptyCancelAndRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--focus-session-seed", "--focus-catalog-seed"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["openFocusSession"].waitForExistence(timeout: 10))
        app.buttons["openFocusSession"].click(); app.buttons["focusTaskPicker"].click()
        let search = app.descendants(matching: .any)["focusTaskSearch"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("proposal")
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        let picker = app.buttons["focusTaskPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.label.contains("Studio · Client launch"))
        XCTAssertTrue(renderedText(app.staticTexts["focusSelectedTaskFixture"]).contains("aaaaaaaa-aaaa-4aaa-8aaa-000000001248"))
        picker.click(); XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("zzzz-no-task")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(search.exists, "Empty search must not activate a stale selection")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.label.contains("Studio · Client launch"))
        app.buttons["startFocus"].click()
        XCTAssertTrue(app.buttons["pauseResumeFocus"].waitForExistence(timeout: 5))
        app.buttons["pauseResumeFocus"].click()
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(app.buttons["openFocusSession"].waitForExistence(timeout: 10))
        app.buttons["openFocusSession"].click()
        XCTAssertTrue(app.staticTexts["focusStatus"].waitForExistence(timeout: 5))
        XCTAssertEqual(renderedText(app.staticTexts["focusStatus"]), "Paused")
        XCTAssertEqual(renderedText(app.staticTexts["focusTaskContext"]), "Studio · Client launch")
        retainWindow(app, name: "Keyboard-selected Focus task after Mac relaunch")
    }
    @MainActor func testBackupProviderWaitCancelRetryAndNormalRelaunch() throws {
        guard Bundle(for: Self.self).bundleIdentifier == "com.dbakp.taskfold.mac.backupcanceltests.runner" else {
            throw XCTSkip("Dedicated backup cancellation app required")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Taskfold-mac-backup-cancel-" + UUID().uuidString + ".json")
        let task: [String: Any] = ["id": UUID().uuidString.lowercased(), "user_id": "synthetic", "title": "Synthetic backup preview task", "completed": false, "priority": 4]
        let backup: [String: Any] = ["format": "com.taskfold.workspace", "version": 1, "id": UUID().uuidString.lowercased(), "createdAt": ISO8601DateFormatter().string(from: Date()), "sourceAccount": "synthetic", "tables": ["tasks": [task]], "unsyncedChanges": 0, "legacy": false]
        try JSONSerialization.data(withJSONObject: backup).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--quick-entry-fixture", "--backup-provider-wait-testing", "--section=inbox"]
        app.launch(); defer { app.terminate() }
        app.typeKey("n", modifierFlags: .command)
        let input = app.textFields["quickAdd"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.typeText("Backup wait preserves Mac task")
        app.buttons["Add Task"].click()
        XCTAssertTrue(app.descendants(matching: .any)["taskTitle"].firstMatch.waitForExistence(timeout: 5))
        let cache = URL(fileURLWithPath: "/Users/" + NSUserName() + "/Library/Containers/com.dbakp.taskfold.mac.backupcanceltests/Data/Library/Application Support/Taskfold/ui-testing.json")
        let before = try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! NSDictionary
        app.typeKey(",", modifierFlags: .command)
        app.buttons["Account"].firstMatch.click()
        func choose() {
            app.buttons["backupImport"].click()
            XCTAssertTrue(app.sheets.buttons["Open"].firstMatch.waitForExistence(timeout: 5))
            app.typeKey("g", modifierFlags: [.command, .shift])
            let path = app.sheets.comboBoxes.firstMatch.exists ? app.sheets.comboBoxes.firstMatch : app.sheets.textFields.firstMatch
            XCTAssertTrue(path.waitForExistence(timeout: 5), app.debugDescription)
            path.click(); app.typeKey("a", modifierFlags: .command); path.typeText(file.path)
            app.typeKey(.return, modifierFlags: [])
            let fileRow = app.sheets.textFields.matching(NSPredicate(format: "value == %@", file.lastPathComponent)).firstMatch
            XCTAssertTrue(fileRow.waitForExistence(timeout: 5)); fileRow.click()
            let open = app.sheets.buttons["Open"].firstMatch
            let available = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: open)
            XCTAssertEqual(XCTWaiter.wait(for: [available], timeout: 5), .completed)
            open.click()
        }
        choose()
        let cancel = app.buttons["backupReadCancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        retainWindow(app, name: "Mac backup provider wait offers cancellation")
        let state = XCTAttachment(string: app.debugDescription); state.name = "Mac backup wait accessibility"; state.lifetime = .keepAlways; add(state)
        XCTAssertTrue(cancel.isEnabled, "Backup cancel must be enabled")
        XCTAssertFalse(app.buttons["backupImport"].isEnabled)
        // XCTest reports this visible Settings footer as non-hittable even though
        // native AX activation works. Click its real frame and verify the effect.
        cancel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let cancelled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: cancel)
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["backupImport"].isEnabled)
        choose()
        XCTAssertTrue(app.descendants(matching: .any)["restoreAdded"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        retainWindow(app, name: "Mac backup retry opens restore review")
        let sheet = app.sheets.firstMatch
        let apply = sheet.buttons["restoreApply"].firstMatch
        let reviewCancel = sheet.buttons["Cancel"].firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertTrue(apply.isHittable, "Restore must be reachable without resizing the review")
        XCTAssertTrue(reviewCancel.isHittable, "Cancel must remain reachable")
        let desktopTop = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        let visibleScreens = NSScreen.screens.map { screen in
            CGRect(x: screen.visibleFrame.minX, y: desktopTop - screen.visibleFrame.maxY,
                   width: screen.visibleFrame.width, height: screen.visibleFrame.height)
        }
        XCTAssertTrue(visibleScreens.contains { $0.insetBy(dx: -1, dy: -1).contains(sheet.frame) },
                      "The complete restore sheet must fit a visible display: \(sheet.frame)")
        let capture = XCTAttachment(screenshot: sheet.screenshot())
        capture.name = "Complete Mac restore review and reachable actions"; capture.lifetime = .keepAlways
        add(capture)
        reviewCancel.click()
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! NSDictionary, before)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        app.launchArguments = ["--uitesting", "--section=inbox"]
        app.launch()
        XCTAssertTrue(app.outlines.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! NSDictionary, before)
        retainWindow(app, name: "Mac backup cancellation retains workspace after normal Quit")
    }
    @MainActor func testBackupProviderFailureRetryPreservesWorkspace() throws {
        guard Bundle(for: Self.self).bundleIdentifier == "com.dbakp.taskfold.mac.backupcanceltests.runner" else {
            throw XCTSkip("Dedicated backup cancellation app required")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Taskfold-mac-backup-cancel-" + UUID().uuidString + ".json")
        let task: [String: Any] = ["id": UUID().uuidString.lowercased(), "user_id": "synthetic", "title": "Synthetic backup preview task", "completed": false, "priority": 4]
        let backup: [String: Any] = ["format": "com.taskfold.workspace", "version": 1, "id": UUID().uuidString.lowercased(), "createdAt": ISO8601DateFormatter().string(from: Date()), "sourceAccount": "synthetic", "tables": ["tasks": [task]], "unsyncedChanges": 0, "legacy": false]
        try JSONSerialization.data(withJSONObject: backup).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--quick-entry-fixture", "--backup-provider-failure-testing", "--section=inbox"]
        app.launch(); defer { app.terminate() }
        app.typeKey("n", modifierFlags: .command)
        let input = app.textFields["quickAdd"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.typeText("Backup wait preserves Mac task")
        app.buttons["Add Task"].click()
        XCTAssertTrue(app.descendants(matching: .any)["taskTitle"].firstMatch.waitForExistence(timeout: 5))
        let cache = URL(fileURLWithPath: "/Users/" + NSUserName() + "/Library/Containers/com.dbakp.taskfold.mac.backupcanceltests/Data/Library/Application Support/Taskfold/ui-testing.json")
        let before = try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! NSDictionary
        app.typeKey(",", modifierFlags: .command)
        app.buttons["Account"].firstMatch.click()
        func choose() {
            app.buttons["backupImport"].click()
            XCTAssertTrue(app.sheets.buttons["Open"].firstMatch.waitForExistence(timeout: 5))
            app.typeKey("g", modifierFlags: [.command, .shift])
            let path = app.sheets.comboBoxes.firstMatch.exists ? app.sheets.comboBoxes.firstMatch : app.sheets.textFields.firstMatch
            XCTAssertTrue(path.waitForExistence(timeout: 5), app.debugDescription)
            path.click(); app.typeKey("a", modifierFlags: .command); path.typeText(file.path)
            app.typeKey(.return, modifierFlags: [])
            let fileRow = app.sheets.textFields.matching(NSPredicate(format: "value == %@", file.lastPathComponent)).firstMatch
            XCTAssertTrue(fileRow.waitForExistence(timeout: 5)); fileRow.click()
            let open = app.sheets.buttons["Open"].firstMatch
            let available = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: open)
            XCTAssertEqual(XCTWaiter.wait(for: [available], timeout: 5), .completed)
            open.click()
        }
        choose()
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Your current work is unchanged.", "Your current work is unchanged.")).firstMatch
        let ok = app.buttons["OK"].firstMatch
        XCTAssertTrue(ok.waitForExistence(timeout: 10), app.debugDescription)
        retainWindow(app, name: "Mac coordinated backup read failure")
        XCTAssertTrue(error.exists, "File-provider errors need recovery guidance and preservation reassurance")
        XCTAssertFalse(app.descendants(matching: .any)["restoreAdded"].exists)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! NSDictionary, before)
        // Return activates the alert's default action without selecting its Touch Bar duplicate.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: error)], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["backupImport"].isEnabled)
        XCTAssertFalse(app.buttons["backupReadCancel"].exists)
        choose()
        XCTAssertTrue(app.descendants(matching: .any)["restoreAdded"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        retainWindow(app, name: "Mac backup retry opens restore review")
        let sheet = app.sheets.firstMatch
        let apply = sheet.buttons["restoreApply"].firstMatch
        let reviewCancel = sheet.buttons["Cancel"].firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertTrue(apply.isHittable, "Restore must be reachable without resizing the review")
        XCTAssertTrue(reviewCancel.isHittable, "Cancel must remain reachable")
        let desktopTop = try XCTUnwrap(NSScreen.screens.first).frame.maxY
        let visibleScreens = NSScreen.screens.map { screen in
            CGRect(x: screen.visibleFrame.minX, y: desktopTop - screen.visibleFrame.maxY,
                   width: screen.visibleFrame.width, height: screen.visibleFrame.height)
        }
        XCTAssertTrue(visibleScreens.contains { $0.insetBy(dx: -1, dy: -1).contains(sheet.frame) },
                      "The complete restore sheet must fit a visible display: \(sheet.frame)")
        let capture = XCTAttachment(screenshot: sheet.screenshot())
        capture.name = "Complete Mac restore review and reachable actions"; capture.lifetime = .keepAlways
        add(capture)
        reviewCancel.click()
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! NSDictionary, before)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        app.launchArguments = ["--uitesting", "--section=inbox"]
        app.launch()
        XCTAssertTrue(app.outlines.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! NSDictionary, before)
        retainWindow(app, name: "Mac backup cancellation retains workspace after normal Quit")
    }
    @MainActor func testBackupProviderWaitNavigationAndWorkspaceReturn() throws {
        guard Bundle(for: Self.self).bundleIdentifier == "com.dbakp.taskfold.mac.backupcanceltests.runner" else {
            throw XCTSkip("Dedicated backup cancellation app required")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Taskfold-mac-backup-cancel-" + UUID().uuidString + ".json")
        let task: [String: Any] = ["id": UUID().uuidString.lowercased(), "user_id": "synthetic", "title": "Synthetic backup preview task", "completed": false, "priority": 4]
        let backup: [String: Any] = ["format": "com.taskfold.workspace", "version": 1, "id": UUID().uuidString.lowercased(), "createdAt": ISO8601DateFormatter().string(from: Date()), "sourceAccount": "synthetic", "tables": ["tasks": [task]], "unsyncedChanges": 0, "legacy": false]
        try JSONSerialization.data(withJSONObject: backup).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--quick-entry-fixture", "--backup-provider-wait-testing", "--section=inbox"]
        app.launch(); defer { app.terminate() }
        app.typeKey("n", modifierFlags: .command)
        let input = app.textFields["quickAdd"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.typeText("Backup workspace return proof")
        app.buttons["Add Task"].click()
        XCTAssertTrue(app.descendants(matching: .any)["taskTitle"].firstMatch.waitForExistence(timeout: 5))
        let cache = URL(fileURLWithPath: "/Users/" + NSUserName() + "/Library/Containers/com.dbakp.taskfold.mac.backupcanceltests/Data/Library/Application Support/Taskfold/ui-testing.json")
        let before = try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! NSDictionary
        app.typeKey(",", modifierFlags: .command)
        app.buttons["Account"].firstMatch.click()
        func choose() {
            app.buttons["backupImport"].click()
            XCTAssertTrue(app.sheets.buttons["Open"].firstMatch.waitForExistence(timeout: 5))
            app.typeKey("g", modifierFlags: [.command, .shift])
            let path = app.sheets.comboBoxes.firstMatch.exists ? app.sheets.comboBoxes.firstMatch : app.sheets.textFields.firstMatch
            XCTAssertTrue(path.waitForExistence(timeout: 5), app.debugDescription)
            path.click(); app.typeKey("a", modifierFlags: .command); path.typeText(file.path)
            app.typeKey(.return, modifierFlags: [])
            let fileRow = app.sheets.textFields.matching(NSPredicate(format: "value == %@", file.lastPathComponent)).firstMatch
            XCTAssertTrue(fileRow.waitForExistence(timeout: 5)); fileRow.click()
            let open = app.sheets.buttons["Open"].firstMatch
            let available = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: open)
            XCTAssertEqual(XCTWaiter.wait(for: [available], timeout: 5), .completed)
            open.click()
        }
        choose()
        XCTAssertTrue(app.buttons["backupReadCancel"].waitForExistence(timeout: 10))
        retainWindow(app, name: "Mac held backup before leaving Account settings")
        app.buttons["General"].firstMatch.click()
        app.buttons["Account"].firstMatch.click()
        let leave = app.buttons["Leave Local Workspace…"]
        for _ in 0..<5 where !leave.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -400) }
        XCTAssertTrue(leave.isHittable); leave.click()
        XCTAssertTrue(app.sheets.buttons["Leave"].firstMatch.waitForExistence(timeout: 5)); app.sheets.buttons["Leave"].firstMatch.click()
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! NSDictionary, before)
        app.windows["Account"].buttons["_XCUI:CloseWindow"].click()
        let local = app.links["useLocally"]
        XCTAssertTrue(local.waitForExistence(timeout: 5)); local.click()
        XCTAssertTrue(app.outlines.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! NSDictionary, before)
        app.typeKey(",", modifierFlags: .command); app.buttons["Account"].firstMatch.click()
        for _ in 0..<5 where !app.buttons["backupImport"].isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 400) }
        choose()
        XCTAssertTrue(app.descendants(matching: .any)["restoreAdded"].firstMatch.waitForExistence(timeout: 10), "The old view must release its coordinated read before retry")
        retainWindow(app, name: "Mac backup retry after navigation and workspace return")
        app.sheets.buttons["Cancel"].firstMatch.click()
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! NSDictionary, before)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(app.outlines.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! NSDictionary, before)
        retainWindow(app, name: "Mac returned workspace preserved after backup wait and normal Quit")
    }

    @MainActor func testBackupWaitCannotFollowAuthenticatedAccountSwitch() throws {
        guard Bundle(for: Self.self).bundleIdentifier == "com.dbakp.taskfold.mac.backupcanceltests.runner" else { throw XCTSkip("Dedicated backup app required") }

        let config = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: URL(fileURLWithPath: "/private/tmp/taskfold-backup-account-switch.json")))
        let first = try XCTUnwrap(config["first"]), second = try XCTUnwrap(config["second"])
        for account in [first, second] {
            let id = try XCTUnwrap(account["userID"])
            guard UUID(uuidString: id) != nil, account["email"]?.hasSuffix("@example.invalid") == true else { throw XCTSkip("Disposable accounts required") }
        }
        XCTAssertNotEqual(first["userID"], second["userID"])
        let app = XCUIApplication(); defer { app.terminate() }
        let defaults = ["-onboardingSeen", "YES", "-dailyBackups." + first["userID"]!, "NO", "-dailyBackups." + second["userID"]!, "NO"]
        app.launchArguments = ["--live-auth-ui-test", "--backup-provider-wait-testing"] + defaults
        app.launch()

        func signIn(_ account: [String: String]) throws {
            let email = app.textFields["authEmail"], secret = app.secureTextFields["authPassword"]
            XCTAssertTrue(email.waitForExistence(timeout: 10)); email.click(); app.typeKey("a", modifierFlags: .command); email.typeText(try XCTUnwrap(account["email"]))
            secret.click()
            let clipboard = NSPasteboard.general
            let saved = (clipboard.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType:type).map { (type,$0) } } }
            clipboard.clearContents(); clipboard.setString(try XCTUnwrap(account["password"]),forType:.string)
            app.typeKey("v",modifierFlags:.command)
            clipboard.clearContents(); clipboard.writeObjects(saved.map { values in let item = NSPasteboardItem(); for (type,data) in values { item.setData(data,forType:type) };return item })
            app.buttons["nativeSignIn"].click()
            XCTAssertTrue(app.outlines.firstMatch.waitForExistence(timeout: 30))
        }
        func settings() {
            app.typeKey(",", modifierFlags: .command); XCTAssertTrue(app.buttons["Account"].firstMatch.waitForExistence(timeout: 8)); app.buttons["Account"].firstMatch.click()
        }
        func signOut() {
            let leave = app.buttons["Sign Out…"]
            let scroll = app.windows["Account"].scrollViews.firstMatch
            // macOS can report clipped controls as hittable. Check the actual viewport.
            for _ in 0..<10 {
                if scroll.frame.contains(leave.frame) { break }
                scroll.scroll(byDeltaX: 0, deltaY: -300)
            }
            XCTAssertTrue(scroll.frame.contains(leave.frame))
            leave.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            let confirm = app.sheets.buttons["Sign Out"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.click()
            app.windows["Account"].buttons["_XCUI:CloseWindow"].click()
            XCTAssertTrue(app.textFields["authEmail"].waitForExistence(timeout: 10))
        }
        let folder = URL(fileURLWithPath: "/Users/" + NSUserName() + "/Library/Containers/com.dbakp.taskfold.mac.backupcanceltests/Data/Library/Application Support/Taskfold")
        func cache(_ account: [String: String]) throws -> NSDictionary {
            try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(account["userID"]! + ".json"))) as! NSDictionary
        }
        func settled(_ account: [String: String]) throws -> NSDictionary {
            let path = folder.appendingPathComponent(account["userID"]! + ".json")
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _,_ in
                guard let data = try? Data(contentsOf: path), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tables = value["tables"] as? [String: Any], let tasks = tables["tasks"] as? [[String: Any]], let pending = value["pending"] as? [Any] else { return false }
                return !tasks.isEmpty && pending.isEmpty
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
            return try cache(account)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Taskfold-account-backup-" + UUID().uuidString + ".json")
        let backup: [String: Any] = ["format":"com.taskfold.workspace", "version":1, "id":UUID().uuidString.lowercased(), "createdAt":ISO8601DateFormatter().string(from:Date()), "sourceAccount":"synthetic", "tables":["tasks":[["id":UUID().uuidString.lowercased(),"user_id":"synthetic","title":"Account-isolated backup proof","completed":false,"priority":4]]], "unsyncedChanges":0, "legacy":false]
        try JSONSerialization.data(withJSONObject: backup).write(to:file); defer { try? FileManager.default.removeItem(at:file) }
        func choose() {
            let restore = app.buttons["backupImport"]
            let scroll = app.windows["Account"].scrollViews.firstMatch
            for _ in 0..<2 {
                if scroll.frame.contains(restore.frame) { break }
                scroll.scroll(byDeltaX: 0, deltaY: restore.frame.midY > scroll.frame.maxY ? -300 : 300)
            }
            if scroll.frame.contains(restore.frame) {
                restore.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            } else {
                // Use the settings window rather than the task window behind it.
                // The actual Open panel and saved-account checks still prove the action.
                restore.click()
            }
            XCTAssertTrue(app.sheets.buttons["Open"].firstMatch.waitForExistence(timeout:5))
            app.typeKey("g",modifierFlags:[.command,.shift])
            let path = app.sheets.comboBoxes.firstMatch.exists ? app.sheets.comboBoxes.firstMatch : app.sheets.textFields.firstMatch
            XCTAssertTrue(path.waitForExistence(timeout:5)); path.click(); app.typeKey("a",modifierFlags:.command); path.typeText(file.path); app.typeKey(.return,modifierFlags:[])
            let row = app.sheets.textFields.matching(NSPredicate(format:"value == %@",file.lastPathComponent)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout:5)); row.click(); app.sheets.buttons["Open"].firstMatch.click()
        }
        try signIn(first); let beforeA = try settled(first); settings(); choose()
        XCTAssertTrue(app.buttons["backupReadCancel"].waitForExistence(timeout:10)); retainWindow(app,name:"Mac held backup in account A")
        signOut(); try signIn(second); let beforeB = try settled(second); settings()
        XCTAssertFalse(app.buttons["backupReadCancel"].exists); XCTAssertFalse(app.descendants(matching:.any)["restoreAdded"].exists)
        XCTAssertEqual(try cache(first),beforeA)
        choose(); XCTAssertTrue(app.descendants(matching:.any)["restoreAdded"].firstMatch.waitForExistence(timeout:10),"Same-file retry must be independent in account B")
        retainWindow(app,name:"Mac account B fresh backup review")
        app.sheets.buttons["Cancel"].firstMatch.click(); XCTAssertEqual(try cache(second),beforeB); signOut()
        try signIn(first); _ = try settled(first); XCTAssertEqual(try cache(first),beforeA); XCTAssertEqual(try cache(second),beforeB)
        app.typeKey("q",modifierFlags:.command); XCTAssertTrue(app.wait(for:.notRunning,timeout:5))
        app.launchArguments = defaults; app.launch(); XCTAssertTrue(app.outlines.firstMatch.waitForExistence(timeout:15)); _ = try settled(first)
        XCTAssertEqual(try cache(first),beforeA); XCTAssertEqual(try cache(second),beforeB)
        retainWindow(app,name:"Mac account A work retained after backup switch and relaunch")
        settings(); signOut()
    }

    @MainActor func testPendingSignInCanOpenLocalWorkspaceAndRetainNewWork() throws {
        let app = XCUIApplication(); defer { app.terminate() }
        let defaults = ["-ApplePersistenceIgnoreState", "YES", "-onboardingSeen", "YES", "-dailyBackups.local", "NO"]
        app.launchArguments = ["--live-auth-ui-test", "--auth-response-wait-testing"] + defaults
        app.launch()
        let folder = URL(fileURLWithPath: "/Users/" + NSUserName() + "/Library/Containers/com.dbakp.taskfold.mac.backupcanceltests/Data/Library/Application Support/Taskfold")
        let path = folder.appendingPathComponent("local.json")
        // The runner can read but cannot write the other app's sandbox on macOS.
        // Fixture removal belongs to the isolated-build orchestration, after termination.
        let local = app.links["useLocally"]
        XCTAssertTrue(local.waitForExistence(timeout: 10)); XCTAssertTrue(local.isEnabled)
        app.textFields["authEmail"].click(); app.textFields["authEmail"].typeText("pending@example.invalid")
        app.secureTextFields["authPassword"].click(); app.secureTextFields["authPassword"].typeText("synthetic-password")
        app.buttons["nativeSignIn"].click()
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: app.buttons["googleSignIn"])
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 5), .completed)
        XCTAssertTrue(local.isEnabled)
        retainWindow(app, name:"Mac local choice remains available during sign-in")
        local.click()
        XCTAssertTrue(app.outlines.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["authEmail"].exists)
        let title = "Local connection recovery " + String(UUID().uuidString.prefix(6))
        app.staticTexts["Inbox"].firstMatch.click()
        app.typeKey("n", modifierFlags: .command)
        let input = app.textFields["quickAdd"]; XCTAssertTrue(input.waitForExistence(timeout: 5)); input.typeText(title)
        app.buttons["Add Task"].click()
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 5))
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! NSDictionary
        retainWindow(app, name:"Mac work saved after cancelling sign-in")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        app.launchArguments = defaults; app.launch()
        XCTAssertTrue(app.outlines.firstMatch.waitForExistence(timeout: 10))
        app.staticTexts["Inbox"].firstMatch.click()
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! NSDictionary, saved)
        XCTAssertFalse(app.textFields["authEmail"].exists)
        retainWindow(app, name:"Mac local work retained after normal relaunch")
        // Leave the isolated app signed out before external fixture cleanup.
        app.terminate(); app.launchArguments = ["--live-auth-ui-test", "--auth-response-wait-testing"] + defaults; app.launch()
        XCTAssertTrue(local.waitForExistence(timeout: 10)); XCTAssertTrue(local.isEnabled)
    }

}

// Run these live phases individually in the order recorded in
// docs/live-native-task-conflict-evidence.json, with the guarded private fixture.
// The ordinary runner skips them; credentials never belong in the repository.
private struct LiveConflictFixture: Decodable {
    let account: [String: String]
    let taskID: String
    let originalTitle: String
    let offlineTitle: String
    let remoteTitle: String
    let remoteNotes: String
}
extension TaskfoldMacUITests {
    @MainActor private func liveConflictFixture(keepLocal: Bool = false) throws -> LiveConflictFixture {
        guard Bundle(for: Self.self).bundleIdentifier == "com.dbakp.taskfold.mac.backupcanceltests.runner" else { throw XCTSkip("Dedicated native conflict app required") }
        let f = try JSONDecoder().decode(LiveConflictFixture.self, from: Data(contentsOf: URL(fileURLWithPath: keepLocal ? "/private/tmp/taskfold-keep-conflict-native-v1.json" : "/private/tmp/taskfold-live-conflict-native.json")))
        guard f.account["userID"] == "9a8bfc3d-42ec-4c89-8f1d-c830b2215152", f.account["email"] == "taskfold-continuity-" + f.account["userID"]! + "@example.invalid", UUID(uuidString: f.taskID) != nil else { throw XCTSkip("Disposable continuity fixture required") }
        return f
    }
    @MainActor private func liveConflictCache(_ f: LiveConflictFixture) throws -> NSDictionary {
        let path = "/Users/" + NSUserName() + "/Library/Containers/com.dbakp.taskfold.mac.backupcanceltests/Data/Library/Application Support/Taskfold/" + f.account["userID"]! + ".json"
        return try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! NSDictionary
    }
    @MainActor private func waitLiveConflict(_ f: LiveConflictFixture, _ condition: @escaping (NSDictionary) -> Bool) throws -> NSDictionary {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let cache = try? self.liveConflictCache(f) else { return false }; return condition(cache)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 35), .completed)
        return try liveConflictCache(f)
    }
    @MainActor private func liveConflictTask(_ cache: NSDictionary, _ f: LiveConflictFixture) -> NSDictionary? {
        (cache["tables"] as? NSDictionary)?["tasks"].flatMap { $0 as? [NSDictionary] }?.first { $0["id"] as? String == f.taskID }
    }
    @MainActor private func liveConflictLaunch(_ app: XCUIApplication) {
        app.launch()
        // A Dock-style reopen is needed when XCTest restores an app with no window.
        if let url = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.dbakp.taskfold.mac.backupcanceltests" })?.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        }
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30))
    }
    @MainActor private func liveConflictArguments(_ f: LiveConflictFixture) -> [String] {
        ["-ApplePersistenceIgnoreState", "YES", "-onboardingSeen", "YES", "-dailyBackups." + f.account["userID"]!, "NO"]
    }
    @MainActor private func liveConflictRow(_ app: XCUIApplication, _ taskID: String) -> XCUIElement {
        app.staticTexts["title-" + taskID]
    }
    @MainActor func testLiveMacQueuesTwoOfflineEditsAndRetainsThemAfterRelaunch() throws { try queueLiveConflict(keepLocal: false) }
    @MainActor func testLiveMacQueuesKeepLocalConflict() throws { try queueLiveConflict(keepLocal: true) }
    @MainActor private func queueLiveConflict(keepLocal: Bool) throws {
        continueAfterFailure = false
        let f = try liveConflictFixture(keepLocal: keepLocal), app = XCUIApplication(); defer { app.terminate() }
        let args = liveConflictArguments(f)
        app.launchArguments = ["--live-auth-ui-test"] + args; liveConflictLaunch(app)
        let email = app.textFields["authEmail"], password = app.secureTextFields["authPassword"]
        XCTAssertTrue(email.waitForExistence(timeout: 30)); email.click(); email.typeText(f.account["email"]!)
        password.click()
        password.typeText(f.account["password"]!)
        app.buttons["nativeSignIn"].click(); XCTAssertTrue(app.outlines.firstMatch.waitForExistence(timeout: 30))
        app.staticTexts["Inbox"].firstMatch.click(); XCTAssertTrue(liveConflictRow(app, f.taskID).waitForExistence(timeout: 30))
        _ = try waitLiveConflict(f) { self.liveConflictTask($0, f)?["title"] as? String == f.originalTitle && ($0["pending"] as? [Any])?.isEmpty == true }
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        app.launchArguments = ["--continuity-offline"] + args; liveConflictLaunch(app); app.staticTexts["Inbox"].firstMatch.click()
        liveConflictRow(app, f.taskID).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let title = app.descendants(matching: .any)["taskTitle"].firstMatch
        if !title.waitForExistence(timeout: 3) { app.buttons["Inspector"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click() }
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.click(); app.typeKey("a", modifierFlags: .command); title.typeText(f.offlineTitle); app.typeKey(.tab, modifierFlags: [])
        _ = try waitLiveConflict(f) { self.liveConflictTask($0, f)?["title"] as? String == f.offlineTitle && ($0["pending"] as? [Any])?.count == 1 }
        let priority = app.menuButtons["priority-" + f.taskID]
        XCTAssertTrue(priority.waitForExistence(timeout: 5)); priority.click(); app.menuItems["Priority 1"].firstMatch.click()
        let queued = try waitLiveConflict(f) { self.liveConflictTask($0, f)?["priority"] as? Int == 1 && ($0["pending"] as? [Any])?.count == 2 }
        retainWindow(app, name: "Mac two real offline edits queued")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 5)); liveConflictLaunch(app)
        XCTAssertTrue(liveConflictRow(app, f.taskID).waitForExistence(timeout: 10)); XCTAssertEqual(try liveConflictCache(f), queued)
        retainWindow(app, name: "Mac offline queue retained after normal Quit")
    }
    @MainActor func testLiveMacReviewsCollisionAndPreservesLaterOfflinePriority() throws { try reviewLiveConflict(keepLocal: false) }
    @MainActor func testLiveMacKeepsOfflineTitleAndPhoneNotes() throws { try reviewLiveConflict(keepLocal: true) }
    @MainActor private func reviewLiveConflict(keepLocal: Bool) throws {
        continueAfterFailure = false
        let f = try liveConflictFixture(keepLocal: keepLocal), app = XCUIApplication(); defer { app.terminate() }
        app.launchArguments = liveConflictArguments(f); liveConflictLaunch(app)
        let review = app.links["reviewSyncConflict"]
        XCTAssertTrue(review.waitForExistence(timeout: 35)); let queued = try liveConflictCache(f)
        XCTAssertEqual((queued["pending"] as? [Any])?.count, 2)
        review.click(); XCTAssertTrue(app.buttons["conflictLater"].waitForExistence(timeout: 5)); app.buttons["conflictLater"].click()
        XCTAssertEqual(try liveConflictCache(f), queued)
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 5)); liveConflictLaunch(app)
        XCTAssertTrue(review.waitForExistence(timeout: 35)); review.click()
        let capture = XCTAttachment(screenshot: app.sheets.firstMatch.screenshot()); capture.name = "Mac real phone collision after Later and relaunch"; capture.lifetime = .keepAlways; add(capture)
        app.buttons[keepLocal ? "keepMyEdit" : "useSharedEdit"].click()
        let settled = try waitLiveConflict(f) { cache in
            let task = self.liveConflictTask(cache, f)
            return task?["title"] as? String == (keepLocal ? f.offlineTitle : f.remoteTitle) && task?["description"] as? String == f.remoteNotes && task?["priority"] as? Int == 1 && (cache["pending"] as? [Any])?.isEmpty == true
        }
        app.staticTexts["Inbox"].firstMatch.click(); XCTAssertTrue(liveConflictRow(app, f.taskID).waitForExistence(timeout: 10)); liveConflictRow(app, f.taskID).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertEqual(app.textViews["taskDescription"].value as? String, f.remoteNotes)
        retainWindow(app, name: "Mac synced phone title and notes retain later offline priority")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 5)); liveConflictLaunch(app)
        XCTAssertTrue(liveConflictRow(app, f.taskID).waitForExistence(timeout: 10)); XCTAssertEqual(try liveConflictCache(f), settled)
        retainWindow(app, name: "Mac resolved real collision retained after normal Quit")
    }
    @MainActor func testLiveMacRemovesOnlySyntheticCollisionTask() throws { try removeLiveConflict(keepLocal: false) }
    @MainActor func testLiveMacRemovesKeepLocalSyntheticTask() throws { try removeLiveConflict(keepLocal: true) }
    @MainActor private func removeLiveConflict(keepLocal: Bool) throws {
        continueAfterFailure = false
        let f = try liveConflictFixture(keepLocal: keepLocal), app = XCUIApplication(); defer { app.terminate() }
        app.launchArguments = liveConflictArguments(f); liveConflictLaunch(app); app.staticTexts["Inbox"].firstMatch.click()
        let row = liveConflictRow(app, f.taskID); XCTAssertTrue(row.waitForExistence(timeout: 20)); row.click()
        app.typeKey(.delete, modifierFlags: .command)
        _ = try waitLiveConflict(f) { self.liveConflictTask($0, f) == nil && ($0["pending"] as? [Any])?.isEmpty == true }
        XCTAssertFalse(row.exists)
        retainWindow(app, name: "Mac removes only the synthetic collision task")
    }
}


// Run these phases explicitly and in order with the private disposable fixture.
// The owner revokes membership between phases; a full-suite run cannot seed it.
extension TaskfoldMacUITests {
    @MainActor private func newCreationFixture() throws -> NSDictionary {
        guard Bundle(for: Self.self).bundleIdentifier == "com.dbakp.taskfold.mac.backupcanceltests.runner" else { throw XCTSkip("Dedicated recovery app required") }
        let f = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "/Users/davidbakposada/.codex/workspaces/taskfold-acceptance/new-task-revocation-native-v1.json"))) as! NSDictionary
        let a = f["account"] as! [String: String]
        guard a["userID"] == "9a8bfc3d-42ec-4c89-8f1d-c830b2215152", a["email"] == "taskfold-continuity-" + a["userID"]! + "@example.invalid", UUID(uuidString: f["project"] as! String) != nil else { throw XCTSkip("Disposable recovery fixture required") }
        return f
    }
    @MainActor private func newCreationCache(_ f: NSDictionary) throws -> NSDictionary {
        let a = f["account"] as! [String: String]
        let url = URL(fileURLWithPath: "/Users/" + NSUserName()).appendingPathComponent("Library/Containers/com.dbakp.taskfold.mac.backupcanceltests/Data/Library/Application Support/Taskfold/" + a["userID"]! + ".json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! NSDictionary
    }
    @MainActor private func waitNewCreation(_ f: NSDictionary, _ condition: @escaping (NSDictionary) -> Bool) throws -> NSDictionary {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let cache = try? self.newCreationCache(f) else { return false }; return condition(cache)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 40), .completed)
        return try newCreationCache(f)
    }
    @MainActor private func newCreationTasks(_ c: NSDictionary, _ f: NSDictionary) -> [NSDictionary] {
        ((c["tables"] as? NSDictionary)?["tasks"] as? [NSDictionary] ?? []).filter { $0["title"] as? String == f["title"] as? String }
    }
    @MainActor private func newCreationArguments(_ f: NSDictionary) -> [String] {
        let a = f["account"] as! [String: String]
        return ["-ApplePersistenceIgnoreState", "YES", "-onboardingSeen", "YES", "-dailyBackups." + a["userID"]!, "NO"]
    }
    @MainActor func testLiveMacCreatesSharedTaskOfflineBeforeRevocation() throws {
        continueAfterFailure = false
        let f = try newCreationFixture(), a = f["account"] as! [String: String], app = XCUIApplication()
        defer { app.terminate() }
        let args = newCreationArguments(f)
        // A driver retry must keep the draft offline instead of signing in and flushing it.
        let existing = try? newCreationCache(f)
        let resume = existing.flatMap { newCreationTasks($0, f).first }
        if resume == nil {
            app.launchArguments = ["--live-auth-ui-test"] + args; liveConflictLaunch(app)
            let email = app.textFields["authEmail"], password = app.secureTextFields["authPassword"]
            XCTAssertTrue(email.waitForExistence(timeout: 30)); email.click(); email.typeText(a["email"]!)
            password.click()
            let board = NSPasteboard.general
            let saved = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
            board.clearContents(); board.setString(a["password"]!, forType: .string); app.typeKey("v", modifierFlags: .command)
            board.clearContents(); board.writeObjects(saved.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item })
            app.buttons["nativeSignIn"].click(); XCTAssertTrue(app.outlines.firstMatch.waitForExistence(timeout: 30))
            let loadedProject = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", f["projectName"] as! String, f["projectName"] as! String)).firstMatch
            XCTAssertTrue(loadedProject.waitForExistence(timeout: 30))
            _ = try waitNewCreation(f) { ($0["pending"] as? [Any])?.isEmpty == true && (($0["tables"] as? NSDictionary)?["projects"] as? [NSDictionary])?.contains(where: { $0["id"] as? String == f["project"] as? String }) == true }
            app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        }
        app.launchArguments = ["--continuity-offline"] + args; liveConflictLaunch(app)
        let project = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", f["projectName"] as! String, f["projectName"] as! String)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10)); project.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        if let resume {
            let row = app.staticTexts["title-" + (resume["id"] as! String)]
            XCTAssertTrue(row.waitForExistence(timeout: 10)); row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        } else {
            app.typeKey("n", modifierFlags: .command)
            let input = app.textFields["quickAdd"]
            XCTAssertTrue(input.waitForExistence(timeout: 5)); input.typeText((f["title"] as! String) + " ~25m"); app.buttons["Add Task"].click()
        }
        let notes = app.textViews["taskDescription"]
        XCTAssertTrue(notes.waitForExistence(timeout: 5)); notes.click(); app.typeKey("a", modifierFlags: .command); notes.typeText(f["notes"] as! String); app.textFields["taskTitle"].click()
        let queued = try waitNewCreation(f) { c in
            guard let t = self.newCreationTasks(c, f).first else { return false }
            return t["project_id"] as? String == f["project"] as? String && t["description"] as? String == f["notes"] as? String && t["duration_minutes"] as? Int == 25 && (c["pending"] as? [NSDictionary])?.contains(where: { $0["recordID"] as? String == t["id"] as? String && $0["method"] as? String == "POST" }) == true
        }
        XCTAssertEqual(newCreationTasks(queued, f).count, 1)
        retainWindow(app, name: "New shared task and notes saved offline")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 5)); liveConflictLaunch(app)
        XCTAssertEqual(try newCreationCache(f), queued)
        retainWindow(app, name: "New task pending POST retained after normal Quit")
    }
    @MainActor func testLiveMacRestoresNewTaskAfterOwnerRevokesAccess() throws {
        continueAfterFailure = false
        let f = try newCreationFixture(), a = f["account"] as! [String: String], app = XCUIApplication()
        defer { app.terminate() }
        XCTAssertNotNil(f["taskID"], "Run owner revocation before this phase")
        app.launchArguments = newCreationArguments(f); liveConflictLaunch(app)
        let review = app.buttons["reviewAccessRecovery"]
        XCTAssertTrue(review.waitForExistence(timeout: 40))
        _ = try waitNewCreation(f) { self.newCreationTasks($0, f).isEmpty && ($0["pending"] as? [Any])?.isEmpty == true }
        retainWindow(app, name: "Actual forbidden new task retained in encrypted recovery")
        review.click()
        let copy = app.menuButtons["recovery-Access removed"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 10)); copy.click(); app.menuItems["Preview restore"].firstMatch.click()
        let apply = app.buttons["restoreApply"].firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 10)); XCTAssertTrue(apply.isEnabled)
        retainWindow(app, name: "New task encrypted restore preview")
        apply.click()
        let ok = app.buttons["OK"].firstMatch
        XCTAssertTrue(ok.waitForExistence(timeout: 20)); app.typeKey(.return, modifierFlags: [])
        let restored = try waitNewCreation(f) { c in
            guard let t = self.newCreationTasks(c, f).first, let projects = (c["tables"] as? NSDictionary)?["projects"] as? [NSDictionary] else { return false }
            return t["description"] as? String == f["notes"] as? String && t["duration_minutes"] as? Int == 25 && t["user_id"] as? String == a["userID"] && projects.contains { $0["id"] as? String == t["project_id"] as? String && $0["user_id"] as? String == a["userID"] && $0["id"] as? String != f["project"] as? String } && (c["pending"] as? [Any])?.isEmpty == true
        }
        XCTAssertEqual(newCreationTasks(restored, f).count, 1)
        app.buttons["Done"].firstMatch.click()
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 5)); liveConflictLaunch(app)
        _ = try waitNewCreation(f) { self.newCreationTasks($0, f) == self.newCreationTasks(restored, f) && ($0["pending"] as? [Any])?.isEmpty == true }
        XCTAssertTrue(app.buttons["reviewAccessRecovery"].exists)
        retainWindow(app, name: "Restored new task persists after normal Quit")
    }
}


extension TaskfoldMacUITests {
    @MainActor private func phoneRecoveryReceiptFixture() throws -> (LiveConflictFixture, String) {
        guard Bundle(for: Self.self).bundleIdentifier == "com.dbakp.taskfold.mac.backupcanceltests.runner" else { throw XCTSkip("Dedicated Mac receipt app required") }
        let f = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "/private/tmp/taskfold-phone-creation-receipt-v1.json"))) as! NSDictionary
        let a = f["account"] as! [String: String]
        guard a["userID"] == "9a8bfc3d-42ec-4c89-8f1d-c830b2215152", a["email"] == "taskfold-continuity-" + a["userID"]! + "@example.invalid", UUID(uuidString: f["restoredTaskID"] as! String) != nil, UUID(uuidString: f["restoredProjectID"] as! String) != nil else { throw XCTSkip("Disposable phone recovery receipt required") }
        return (LiveConflictFixture(account: a, taskID: f["restoredTaskID"] as! String, originalTitle: f["title"] as! String, offlineTitle: f["title"] as! String, remoteTitle: f["title"] as! String, remoteNotes: f["notes"] as! String), f["restoredProjectID"] as! String)
    }
    @MainActor func testLiveMacReceivesPhoneRecoveredNewTaskAndRelaunches() throws {
        continueAfterFailure = false
        let (f, projectID) = try phoneRecoveryReceiptFixture(), app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = liveConflictArguments(f); liveConflictLaunch(app)
        let received = try waitLiveConflict(f) { c in
            guard let t = self.liveConflictTask(c, f), let projects = (c["tables"] as? NSDictionary)?["projects"] as? [NSDictionary] else { return false }
            return t["title"] as? String == f.originalTitle && t["description"] as? String == f.remoteNotes && t["duration_minutes"] as? Int == 45 && t["priority"] as? Int == 2 && t["project_id"] as? String == projectID && t["user_id"] as? String == f.account["userID"] && projects.contains { $0["id"] as? String == projectID && $0["user_id"] as? String == f.account["userID"] } && (c["pending"] as? [Any])?.isEmpty == true
        }
        // Acknowledge only the previous disposable Mac case's retained notice.
        if app.buttons["dismissAccessRecovery"].exists { app.buttons["dismissAccessRecovery"].click() }
        func inspect() {
            app.staticTexts["All Tasks"].firstMatch.click()
            let row = liveConflictRow(app, f.taskID)
            XCTAssertTrue(row.waitForExistence(timeout: 15)); row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            let title = app.textFields["taskTitle"]
            if !title.waitForExistence(timeout: 3) { app.buttons["Inspector"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click() }
            XCTAssertTrue(title.waitForExistence(timeout: 5)); XCTAssertEqual(title.value as? String, f.originalTitle)
            XCTAssertEqual(app.textViews["taskDescription"].value as? String, f.remoteNotes)
        }
        inspect(); retainWindow(app, name: "Mac opens phone-owned recovery copy with full notes and estimate")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 5)); liveConflictLaunch(app)
        _ = try waitLiveConflict(f) { self.liveConflictTask($0, f) == self.liveConflictTask(received, f) && ($0["pending"] as? [Any])?.isEmpty == true }
        inspect(); retainWindow(app, name: "Mac signed-in normal Quit retains phone recovery copy")
    }
    @MainActor func testLiveMacReceivesPhoneRecoverySyntheticCleanup() throws {
        continueAfterFailure = false
        let (f, projectID) = try phoneRecoveryReceiptFixture(), app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = liveConflictArguments(f); liveConflictLaunch(app)
        _ = try waitLiveConflict(f) { c in
            self.liveConflictTask(c, f) == nil && !((c["tables"] as? NSDictionary)?["projects"] as? [NSDictionary] ?? []).contains { $0["id"] as? String == projectID } && (c["pending"] as? [Any])?.isEmpty == true
        }
        app.staticTexts["All Tasks"].firstMatch.click(); XCTAssertFalse(liveConflictRow(app, f.taskID).exists)
        retainWindow(app, name: "Mac receives exact synthetic phone recovery cleanup")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }
}

extension TaskfoldMacUITests {

    @MainActor private func labelFixture() throws -> (LiveConflictFixture, [String: String]) {
        guard Bundle(for: Self.self).bundleIdentifier == "com.dbakp.taskfold.mac.backupcanceltests.runner" else { throw XCTSkip("Dedicated label continuity runner required") }
        let values = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "/private/tmp/taskfold-label-native-v1.json"))) as! [String: Any]
        let account = values["account"] as! [String: String], labels = values["labels"] as! [String: String]
        guard account["userID"] == "9a8bfc3d-42ec-4c89-8f1d-c830b2215152", account["email"] == "taskfold-continuity-" + account["userID"]! + "@example.invalid", UUID(uuidString: values["taskID"] as! String) != nil, labels.count == 4, labels.values.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw XCTSkip("Disposable label fixture required") }
        let title = values["title"] as! String
        return (LiveConflictFixture(account: account, taskID: values["taskID"] as! String, originalTitle: title, offlineTitle: title, remoteTitle: title, remoteNotes: values["notes"] as! String), labels)
    }
    @MainActor private func hasLabels(_ cache: NSDictionary, _ f: LiveConflictFixture, _ ids: [String]) -> Bool {
        Set(liveConflictTask(cache, f)?["labels"] as? [String] ?? []) == Set(ids)
    }

    @MainActor private func labelControl(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let control = app.descendants(matching: .any)["taskLabel-" + id].firstMatch
        for _ in 0..<12 { if control.exists && control.isHittable { break }; app.scrollViews["inspector"].firstMatch.swipeUp() }
        XCTAssertTrue(control.exists); XCTAssertTrue(control.isHittable); return control
    }
    @MainActor private func openLabelTask(_ app: XCUIApplication, _ f: LiveConflictFixture) {
        app.staticTexts["Inbox"].firstMatch.click()
        let row = liveConflictRow(app, f.taskID); XCTAssertTrue(row.waitForExistence(timeout: 30)); row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        if !app.descendants(matching: .any)["taskTitle"].firstMatch.waitForExistence(timeout: 3) { app.buttons["Inspector"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click() }
    }
    @MainActor func testLiveMacQueuesIndependentLabelMembership() throws {
        continueAfterFailure = false
        let (f, labels) = try labelFixture(), app = XCUIApplication(); defer { app.terminate() }
        app.launchArguments = ["--live-auth-ui-test"] + liveConflictArguments(f); liveConflictLaunch(app)
        let email = app.textFields["authEmail"], password = app.secureTextFields["authPassword"]
        XCTAssertTrue(email.waitForExistence(timeout: 30)); email.click(); email.typeText(f.account["email"]!); password.click(); password.typeText(f.account["password"]!); app.buttons["nativeSignIn"].click()
        XCTAssertTrue(app.outlines.firstMatch.waitForExistence(timeout: 30))
        _ = try waitLiveConflict(f) { self.hasLabels($0, f, [labels["shared"]!]) && ($0["pending"] as? [Any])?.isEmpty == true }
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        app.launchArguments = ["--continuity-offline"] + liveConflictArguments(f); liveConflictLaunch(app); openLabelTask(app, f)
        labelControl(app, labels["mac"]!).click()
        _ = try waitLiveConflict(f) { self.hasLabels($0, f, [labels["shared"]!, labels["mac"]!]) && ($0["pending"] as? [Any])?.count == 1 }
        labelControl(app, labels["later"]!).click()
        let queued = try waitLiveConflict(f) { self.hasLabels($0, f, [labels["shared"]!, labels["mac"]!, labels["later"]!]) && ($0["pending"] as? [Any])?.count == 2 }
        retainWindow(app, name: "Two offline label memberships queued")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 5)); liveConflictLaunch(app)
        XCTAssertEqual(try liveConflictCache(f), queued)
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }
    @MainActor func testLiveMacKeepsLabelsWithoutLosingPhoneMembership() throws {
        continueAfterFailure = false
        let (f, labels) = try labelFixture(), app = XCUIApplication(); defer { app.terminate() }
        app.launchArguments = liveConflictArguments(f); liveConflictLaunch(app)
        let review = app.links["reviewSyncConflict"]; XCTAssertTrue(review.waitForExistence(timeout: 35)); review.click()
        XCTAssertTrue(app.buttons["keepMyEdit"].waitForExistence(timeout: 5)); retainWindow(app, name: "Real phone and Mac label conflict review")
        app.buttons["keepMyEdit"].click()
        try verifyResolvedLabels(app, f, labels)
    }
    @MainActor func testLiveMacRetainsResolvedLabelMembershipAfterRelaunch() throws {
        continueAfterFailure = false
        let (f, labels) = try labelFixture(), app = XCUIApplication(); defer { app.terminate() }
        app.launchArguments = liveConflictArguments(f); liveConflictLaunch(app)
        try verifyResolvedLabels(app, f, labels)
    }
    @MainActor private func verifyResolvedLabels(_ app: XCUIApplication, _ f: LiveConflictFixture, _ labels: [String: String]) throws {
        let settled = try waitLiveConflict(f) { self.hasLabels($0, f, Array(labels.values)) && self.liveConflictTask($0, f)?["description"] as? String == f.remoteNotes && ($0["pending"] as? [Any])?.isEmpty == true }
        openLabelTask(app, f)
        XCTAssertEqual(app.textViews["taskDescription"].value as? String, f.remoteNotes)
        // Native macOS switches return NSNumber; iOS switches return String.
        for id in labels.values { XCTAssertEqual((labelControl(app, id).value as? NSNumber)?.intValue, 1) }
        retainWindow(app, name: "All independent labels preserved after Keep my edit")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 5)); liveConflictLaunch(app)
        _ = try waitLiveConflict(f) { self.hasLabels($0, f, Array(labels.values)) && ($0["pending"] as? [Any])?.isEmpty == true }
        XCTAssertEqual(try liveConflictCache(f), settled)
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }
}

// Scoped read-only regression for retained cold cloud/Settings runtime findings.
// No fixture records are created, edited or removed. Run explicitly with the
// existing guarded account and a fresh private server baseline.
extension TaskfoldMacUITests {
    @MainActor func testLiveMacColdCloudSettingsReadOnlyAndRelaunch() throws {
        continueAfterFailure = false
        let f = try liveConflictFixture(), app = XCUIApplication(); defer { app.terminate() }
        let server = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "/private/tmp/taskfold-cold-cloud-settings-server-before.json"))) as! NSDictionary
        let expectedIDs = Set((server["tasks"] as! [NSDictionary]).compactMap { $0["id"] as? String })
        XCTAssertFalse(expectedIDs.isEmpty)
        func settled() throws -> NSDictionary {
            try waitLiveConflict(f) { cache in
                let tables = cache["tables"] as? NSDictionary
                let tasks = tables?["tasks"] as? [NSDictionary] ?? []
                return Set(tasks.compactMap { $0["id"] as? String }) == expectedIDs && (cache["pending"] as? [Any])?.isEmpty == true
            }
        }
        func stableTables(_ cache: NSDictionary) throws -> [String: [String]] {
            let tables = cache["tables"] as! NSDictionary
            return try Dictionary(uniqueKeysWithValues: (server.allKeys as! [String]).map { table in
                let rows = try XCTUnwrap(tables[table] as? [NSDictionary], "Missing synced table")
                return (table, try rows.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]).base64EncodedString() }.sorted())
            })
        }
        app.launchArguments = ["--live-auth-ui-test"] + liveConflictArguments(f); liveConflictLaunch(app)
        let email = app.textFields["authEmail"], password = app.secureTextFields["authPassword"]
        XCTAssertTrue(email.waitForExistence(timeout: 20)); email.click(); email.typeText(f.account["email"]!)
        password.click(); password.typeText(f.account["password"]!); app.buttons["nativeSignIn"].click()
        XCTAssertTrue(app.outlines.firstMatch.waitForExistence(timeout: 30))
        let before = try stableTables(settled())
        app.staticTexts["All Tasks"].firstMatch.click()
        let id = try XCTUnwrap(expectedIDs.sorted().first), row = liveConflictRow(app, id)
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let title = app.descendants(matching: .any)["taskTitle"].firstMatch
        if !title.waitForExistence(timeout: 3) { app.buttons["Inspector"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click() }
        XCTAssertTrue(title.waitForExistence(timeout: 5)); retainWindow(app, name: "Cold cloud list and inspector without edits")
        func settingsWalk(_ name: String) {
            app.typeKey(",", modifierFlags: .command)
            for tab in ["General", "Appearance", "Account"] {
                let button = app.buttons[tab].firstMatch; XCTAssertTrue(button.waitForExistence(timeout: 8)); button.click()
            }
            XCTAssertTrue(app.buttons["Save Profile"].waitForExistence(timeout: 5))
            let restore = app.buttons["backupImport"]; XCTAssertTrue(restore.exists)
            retainWindow(app, name: name)
            restore.click(); XCTAssertTrue(app.sheets.buttons["Cancel"].firstMatch.waitForExistence(timeout: 5)); app.sheets.buttons["Cancel"].firstMatch.click()
            XCTAssertTrue(restore.waitForExistence(timeout: 5))
            app.windows["Account"].buttons["_XCUI:CloseWindow"].click()
        }
        settingsWalk("Cloud Account and recovery controls before normal Quit")
        XCTAssertEqual(try stableTables(settled()), before)
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        app.launchArguments = liveConflictArguments(f); liveConflictLaunch(app)
        XCTAssertEqual(try stableTables(settled()), before)
        settingsWalk("Cloud Account and recovery controls after ordinary relaunch")
        XCTAssertEqual(try stableTables(settled()), before)
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
    }
}

// Read-only original imported-account startup and open-Settings relaunch probe.
// Explicit private fixture and runner guards prevent ordinary suite execution.
extension TaskfoldMacUITests {
    @MainActor func testImportedWorkspaceStartupAndOpenSettingsRelaunchReadOnly() throws {
        continueAfterFailure = false
        guard Bundle(for: Self.self).bundleIdentifier == "com.dbakp.taskfold.mac.backupcanceltests.runner" else { throw XCTSkip("Dedicated isolated app required") }
        let account = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: "/private/tmp/taskfold-provider-import-native.txt")))
        guard account["userID"] == "316d6706-449c-4ab8-8480-db12e7d92642",
              account["email"]?.hasPrefix("taskfold-todoist-readonly-") == true,
              account["email"]?.hasSuffix("@example.invalid") == true else { throw XCTSkip("Original disposable imported owner required") }
        let baselineURL = URL(fileURLWithPath: "/Users/" + NSUserName() + "/.codex/workspaces/taskfold-acceptance/mac-imported-runtime-server-before-v1.json")
        let server = try JSONSerialization.jsonObject(with: Data(contentsOf: baselineURL)) as! NSDictionary
        let taskCount = (server["tasks"] as! [NSDictionary]).count
        XCTAssertGreaterThanOrEqual(taskCount, 256)
        let cacheURL = URL(fileURLWithPath: "/Users/" + NSUserName() + "/Library/Containers/com.dbakp.taskfold.mac.backupcanceltests/Data/Library/Application Support/Taskfold/" + account["userID"]! + ".json")
        func cache() throws -> NSDictionary { try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as! NSDictionary }
        func tables(_ snapshot: NSDictionary) throws -> [String: [String]] {
            let source = snapshot["tables"] as! NSDictionary
            return try Dictionary(uniqueKeysWithValues: (source.allKeys as! [String]).map { table in
                let rows = try XCTUnwrap(source[table] as? [NSDictionary])
                return (table, try rows.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]).base64EncodedString() }.sorted())
            })
        }
        func settled() throws -> NSDictionary {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let snapshot = try? cache(), let t = snapshot["tables"] as? NSDictionary else { return false }
                return (t["tasks"] as? [Any])?.count == taskCount && (snapshot["pending"] as? [Any])?.isEmpty == true
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 40), .completed)
            return try cache()
        }
        let app = XCUIApplication(); defer { app.terminate() }
        let arguments = ["-ApplePersistenceIgnoreState", "NO", "-onboardingSeen", "YES", "-dailyBackups." + account["userID"]!, "NO"]
        app.launchArguments = ["--live-auth-ui-test"] + arguments; liveConflictLaunch(app)
        let email = app.textFields["authEmail"], password = app.secureTextFields["authPassword"]
        XCTAssertTrue(email.waitForExistence(timeout: 25)); email.click(); email.typeText(account["email"]!)
        password.click(); password.typeText(account["password"]!); app.buttons["nativeSignIn"].click()
        XCTAssertTrue(app.outlines.firstMatch.waitForExistence(timeout: 30))
        // Open Account while initial cloud loading may still be in progress.
        app.typeKey(",", modifierFlags: .command)
        let accountTab = app.buttons["Account"].firstMatch; XCTAssertTrue(accountTab.waitForExistence(timeout: 8)); accountTab.click()
        XCTAssertTrue(app.buttons["Save Profile"].waitForExistence(timeout: 8))
        let before = try tables(settled())
        XCTAssertEqual(before.count, 14)
        retainWindow(app, name: "Imported Account open during initial cloud startup")
        // Leave Settings open; do not override OS window restoration on relaunch.
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
        app.launchArguments = arguments; liveConflictLaunch(app)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30))
        let restoredAccount = app.buttons["Save Profile"].waitForExistence(timeout: 3)
        let receipt = XCTAttachment(string: "Account controls restored automatically: \(restoredAccount); OS restoration enabled; Settings left open at Quit")
        receipt.name = "Settings restoration observation"; receipt.lifetime = .keepAlways; add(receipt)
        XCTAssertEqual(try tables(settled()), before)
        if !restoredAccount {
            app.typeKey(",", modifierFlags: .command)
            let tab = app.buttons["Account"].firstMatch; XCTAssertTrue(tab.waitForExistence(timeout: 8)); tab.click()
        }
        XCTAssertTrue(app.buttons["Save Profile"].waitForExistence(timeout: 8))
        retainWindow(app, name: "Imported Account after open-Settings normal relaunch")
        app.windows["Account"].buttons["_XCUI:CloseWindow"].click()
        app.staticTexts["All Tasks"].firstMatch.click()
        XCTAssertTrue(app.outlines.firstMatch.exists)
        XCTAssertEqual(try tables(settled()), before)
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
    }
}

// Exercise the actual local Account -> authenticated Account transition and
// unsaved profile draft during sync. The server profile must never be saved.
extension TaskfoldMacUITests {
    @MainActor func testLiveLocalAccountDirtyProfileSyncAndRelaunchReadOnly() throws {
        continueAfterFailure = false
        let f = try liveConflictFixture(), app = XCUIApplication(); defer { app.terminate() }
        let server = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "/private/tmp/taskfold-cold-cloud-settings-server-before.json"))) as! NSDictionary
        let profile = try XCTUnwrap((server["profiles"] as? [NSDictionary])?.first { $0["user_id"] as? String == f.account["userID"] })
        // This guarded continuity account has Native Handoff Test in sign-in metadata;
        // a null profile display_name legitimately falls back to that identity.
        let storedName = profile["display_name"] as? String ?? ""
        let savedName = storedName.isEmpty ? "Native Handoff Test" : storedName
        let draft = "Unsaved isolated profile runtime check"
        func cacheTables() throws -> NSDictionary { try XCTUnwrap(try liveConflictCache(f)["tables"] as? NSDictionary) }
        app.launchArguments = ["--uitesting", "--live-auth-ui-test"] + liveConflictArguments(f); liveConflictLaunch(app)
        app.typeKey(",", modifierFlags: .command)
        let account = app.buttons["Account"].firstMatch; XCTAssertTrue(account.waitForExistence(timeout: 8)); account.click()
        let login = app.buttons["accountSignIn"]; XCTAssertTrue(login.waitForExistence(timeout: 5)); login.click()
        let email = app.textFields["authEmail"], password = app.secureTextFields["authPassword"]
        XCTAssertTrue(email.waitForExistence(timeout: 8)); email.click(); email.typeText(f.account["email"]!)
        password.click(); password.typeText(f.account["password"]!); app.buttons["nativeSignIn"].click()
        XCTAssertTrue(app.buttons["Save Profile"].waitForExistence(timeout: 30))
        let name = app.windows["Account"].textFields.firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in name.value as? String == savedName }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        _ = try waitLiveConflict(f) { snapshot in
            guard let tables = snapshot["tables"] as? NSDictionary else { return false }
            return (snapshot["pending"] as? [Any])?.isEmpty == true && Set(server.allKeys as! [String]).isSubset(of: Set(tables.allKeys as! [String]))
        }
        let before = try cacheTables()
        name.click(); name.typeKey("a", modifierFlags: .command); name.typeText(draft)
        let sync = app.buttons["Sync Now"]; XCTAssertTrue(sync.waitForExistence(timeout: 15)); sync.click()
        XCTAssertTrue(sync.waitForExistence(timeout: 15))
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in sync.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 25), .completed)
        XCTAssertEqual(name.value as? String, draft)
        XCTAssertEqual(try cacheTables(), before)
        retainWindow(app, name: "Unsaved profile draft retained through live sync")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
        app.launchArguments = liveConflictArguments(f); liveConflictLaunch(app)
        app.typeKey(",", modifierFlags: .command)
        let tab = app.buttons["Account"].firstMatch; XCTAssertTrue(tab.waitForExistence(timeout: 8)); tab.click()
        XCTAssertTrue(app.buttons["Save Profile"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.windows["Account"].textFields.firstMatch.value as? String, savedName)
        XCTAssertEqual(try cacheTables(), before)
        retainWindow(app, name: "Saved cloud profile restored after unsaved draft Quit")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
    }
}

// Mirrors the human listening sequence and checks durable state, not just speech
// or an Undo menu's enabled state. Isolated runner only; no cloud records.
extension TaskfoldMacUITests {
    @MainActor func testKeyboardUndoAfterAutosavedTitleAndCompletionFeedbackExpires() throws {
        continueAfterFailure = false
        guard Bundle(for: Self.self).bundleIdentifier == "com.dbakp.taskfold.mac.backupcanceltests.runner" else { throw XCTSkip("Dedicated local keyboard app required") }
        let modeFile = URL(fileURLWithPath: "/private/tmp/taskfold-keyboard-undo-expected-voiceover.json")
        let expectsVoiceOver = FileManager.default.fileExists(atPath: modeFile.path) ? try JSONDecoder().decode(Bool.self, from: Data(contentsOf: modeFile)) : false
        XCTAssertEqual(NSWorkspace.shared.isVoiceOverEnabled, expectsVoiceOver)
        defer { XCTAssertEqual(NSWorkspace.shared.isVoiceOverEnabled, expectsVoiceOver, "VoiceOver mode must remain stable through the native case") }
        let modeReceipt = XCTAttachment(string: "Expected VoiceOver enabled: \(expectsVoiceOver); observed: \(NSWorkspace.shared.isVoiceOverEnabled)")
        modeReceipt.name = "Native VoiceOver mode"; modeReceipt.lifetime = .keepAlways; add(modeReceipt)
        let app = XCUIApplication(); defer { app.terminate() }
        app.launchArguments = ["--uitesting", "--live-auth-ui-test", "--quick-entry-fixture", "-onboardingSeen", "YES"]
        liveConflictLaunch(app)
        XCTAssertTrue(app.buttons["addTask"].waitForExistence(timeout: 20), "Local workspace must be ready before capture")
        app.typeKey("n", modifierFlags: .command)
        let input = app.textFields["quickAdd"]; XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.typeText("Keyboard capture proof"); app.buttons["Add Task"].click()
        let title = app.textFields["taskTitle"]; XCTAssertTrue(title.waitForExistence(timeout: 8))
        title.click(); title.typeKey("a", modifierFlags: .command); title.typeText("Keyboard editing proof")
        let cacheURL = URL(fileURLWithPath: "/Users/" + NSUserName() + "/Library/Containers/com.dbakp.taskfold.mac.backupcanceltests/Data/Library/Application Support/Taskfold/ui-testing.json")
        func cache() throws -> NSDictionary { try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as! NSDictionary }
        func sample() throws -> NSDictionary {
            let tables = try XCTUnwrap(try cache()["tables"] as? NSDictionary)
            let tasks = try XCTUnwrap(tables["tasks"] as? [NSDictionary]); XCTAssertEqual(tasks.count, 1)
            return try XCTUnwrap(tasks.first)
        }
        func waitCompleted(_ completed: Bool) throws {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let task = try? sample() else { return false }
                return task["title"] as? String == "Keyboard editing proof" && (task["completed"] as? NSNumber)?.boolValue == completed
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        }
        try waitCompleted(false)
        let id = try XCTUnwrap(try sample()["id"] as? String)
        let row = app.staticTexts["title-" + id]
        XCTAssertTrue(row.waitForExistence(timeout: 8)); row.click()
        app.typeKey(" ", modifierFlags: []); try waitCompleted(true)
        XCTAssertTrue(waitForDisappearance(row, timeout: 8))
        let feedback = app.descendants(matching: .any)["undoConfirmation"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 2))
        XCTAssertTrue(waitForDisappearance(feedback, timeout: 8), "Undo must survive feedback dismissal while the user listens")
        app.typeKey("z", modifierFlags: .command); try waitCompleted(false)
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        let reopened = try sample()
        let undoReceipt = XCTAttachment(string: "Saved title: \(reopened["title"] ?? NSNull()); completed: \(reopened["completed"] ?? NSNull())")
        undoReceipt.name = "Keyboard Undo durable state after feedback expiry"; undoReceipt.lifetime = .keepAlways; add(undoReceipt)
        app.typeKey("z", modifierFlags: [.command, .shift]); try waitCompleted(true)
        app.typeKey("z", modifierFlags: .command); try waitCompleted(false)
        let before = try cache()
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
        app.launchArguments = ["--uitesting", "-onboardingSeen", "YES"]; liveConflictLaunch(app)
        XCTAssertTrue(app.buttons["addTask"].waitForExistence(timeout: 20))
        app.staticTexts["All Tasks"].firstMatch.click()
        XCTAssertTrue(row.waitForExistence(timeout: 10)); try waitCompleted(false)
        XCTAssertEqual(try cache(), before)
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
    }
}

extension TaskfoldMacUITests {

    @MainActor private func collectionFixture() throws -> (LiveConflictFixture, [String: Any]) {
        guard Bundle(for: Self.self).bundleIdentifier == "com.dbakp.taskfold.mac.backupcanceltests.runner" else { throw XCTSkip("Dedicated collection test app required") }
        let v = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "/private/tmp/taskfold-collection-native-v1.json"))) as! [String: Any]
        let a = v["account"] as! [String: String]
        guard a["userID"] == "9a8bfc3d-42ec-4c89-8f1d-c830b2215152", a["email"] == "taskfold-continuity-" + a["userID"]! + "@example.invalid", UUID(uuidString: v["taskID"] as! String) != nil, (v["originalTitle"] as! String).hasPrefix("Collection continuity proof ") else { throw XCTSkip("Disposable collection fixture required") }
        return (LiveConflictFixture(account: a, taskID: v["taskID"] as! String, originalTitle: v["originalTitle"] as! String, offlineTitle: v["offlineTitle"] as! String, remoteTitle: v["remoteTitle"] as! String, remoteNotes: v["remoteNotes"] as! String), v)
    }
    @MainActor private func collectionTexts(_ cache: NSDictionary, _ f: LiveConflictFixture) -> [String] {
        (liveConflictTask(cache, f)?["comments"] as? [NSDictionary] ?? []).map { $0["text"] as? String ?? "" }
    }
    @MainActor private func expectedCollectionTexts(_ v: [String: Any]) -> [String] {
        [v["remoteComment"] as! String] + ((v["keepLocal"] as! Bool) ? [v["firstComment"] as! String] : []) + [v["laterComment"] as! String]
    }

    @MainActor private func openCollectionTask(_ app: XCUIApplication, _ f: LiveConflictFixture) {
        app.staticTexts["Inbox"].firstMatch.click()
        let row = liveConflictRow(app, f.taskID); XCTAssertTrue(row.waitForExistence(timeout: 30)); row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        if !app.descendants(matching: .any)["taskTitle"].firstMatch.waitForExistence(timeout: 3) { app.buttons["Inspector"].click() }
        XCTAssertTrue(app.descendants(matching: .any)["taskTitle"].firstMatch.waitForExistence(timeout: 5))
    }
    @MainActor private func revealCollectionComments(_ app: XCUIApplication) -> XCUIElement {
        let editor = app.textViews["commentEditor"]
        let form = app.scrollViews.containing(.textView, identifier: "commentEditor").firstMatch
        for _ in 0..<15 { if editor.exists && editor.isHittable { break }; form.scroll(byDeltaX: 0, deltaY: -400) }
        XCTAssertTrue(editor.exists); XCTAssertTrue(editor.isHittable); return editor
    }
    @MainActor func testLiveMacAddsIndependentCommentWhilePhoneHasTwoOfflineEdits() throws {
        continueAfterFailure = false
        let (f, v) = try collectionFixture(), app = XCUIApplication(); defer { app.terminate() }
        app.launchArguments = ["--live-auth-ui-test"] + liveConflictArguments(f); liveConflictLaunch(app)
        let email = app.textFields["authEmail"], password = app.secureTextFields["authPassword"]
        XCTAssertTrue(email.waitForExistence(timeout: 30)); email.click(); email.typeText(f.account["email"]!); password.click(); password.typeText(f.account["password"]!); app.buttons["nativeSignIn"].click()
        openCollectionTask(app, f)
        let title = app.descendants(matching: .any)["taskTitle"].firstMatch
        title.click(); title.typeKey("a", modifierFlags: .command); title.typeText(f.remoteTitle); app.typeKey(.tab, modifierFlags: [])
        _ = try waitLiveConflict(f) { self.liveConflictTask($0, f)?["title"] as? String == f.remoteTitle && ($0["pending"] as? [Any])?.isEmpty == true }
        let notes = app.descendants(matching: .any)["taskDescription"].firstMatch
        notes.click(); notes.typeKey("a", modifierFlags: .command); notes.typeText(f.remoteNotes); title.click()
        _ = try waitLiveConflict(f) { self.liveConflictTask($0, f)?["description"] as? String == f.remoteNotes && ($0["pending"] as? [Any])?.isEmpty == true }
        let editor = revealCollectionComments(app); editor.click(); editor.typeText(v["remoteComment"] as! String); app.buttons["Add Comment"].click()
        let settled = try waitLiveConflict(f) { self.collectionTexts($0, f) == [v["remoteComment"] as! String] && ($0["pending"] as? [Any])?.isEmpty == true }
        retainWindow(app, name: "Mac independent comment before phone review")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
        app.launchArguments = liveConflictArguments(f); liveConflictLaunch(app)
        let restored = try waitLiveConflict(f) { self.collectionTexts($0, f) == [v["remoteComment"] as! String] && ($0["pending"] as? [Any])?.isEmpty == true }
        XCTAssertEqual(liveConflictTask(restored, f), liveConflictTask(settled, f))
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
    }
    @MainActor func testLiveMacReceivesReviewedCollectionAndRetainsWholeTaskAfterRelaunch() throws {
        continueAfterFailure = false
        let (f, v) = try collectionFixture(), app = XCUIApplication(); defer { app.terminate() }
        app.launchArguments = liveConflictArguments(f); liveConflictLaunch(app)
        let expected = expectedCollectionTexts(v), title = (v["keepLocal"] as! Bool) ? f.offlineTitle : f.remoteTitle
        let settled = try waitLiveConflict(f) { self.collectionTexts($0, f) == expected && self.liveConflictTask($0, f)?["title"] as? String == title && self.liveConflictTask($0, f)?["description"] as? String == f.remoteNotes && ($0["pending"] as? [Any])?.isEmpty == true }
        openCollectionTask(app, f)
        XCTAssertEqual(app.descendants(matching: .any)["taskTitle"].firstMatch.value as? String, title)
        _ = revealCollectionComments(app)
        for text in expected { XCTAssertTrue(app.staticTexts[text].exists) }
        retainWindow(app, name: "Mac receives preserved reviewed comments")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 8)); liveConflictLaunch(app)
        let restored = try waitLiveConflict(f) { self.collectionTexts($0, f) == expected && ($0["pending"] as? [Any])?.isEmpty == true }
        XCTAssertEqual(liveConflictTask(restored, f), liveConflictTask(settled, f))
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
    }
}


extension TaskfoldMacUITests {
    @MainActor func testWidgetRecordWorkspaceGuardAndMatchingRoutesPreserveWork() throws {
        guard Bundle(for: Self.self).bundleIdentifier == "com.dbakp.taskfold.mac.backupcanceltests.runner" else { throw XCTSkip("Requires isolated backup acceptance workspace") }
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--widget-list-fixture", "-onboardingSeen", "YES"]
        liveConflictLaunch(app); defer { app.terminate() }
        let cache = URL(fileURLWithPath: "/Users/" + NSUserName() + "/Library/Containers/com.dbakp.taskfold.mac.backupcanceltests/Data/Library/Application Support/Taskfold/ui-testing.json")
        func saved() throws -> NSDictionary { try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! NSDictionary }
        let before = try saved()
        let bundle = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.dbakp.taskfold.mac.backupcanceltests" }?.bundleURL)
        func route(_ host: String, _ id: String, _ owner: String) {
            var parts = URLComponents(); parts.scheme = "taskfold"; parts.host = host; parts.path = "/" + id; parts.queryItems = [URLQueryItem(name: "account", value: owner)]
            NSWorkspace.shared.open([parts.url!], withApplicationAt: bundle, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
        let project = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01", task = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeee04"
        for (host, id) in [("project", project), ("label", "eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02"), ("view", "eeeeeeee-eeee-4eee-8eee-eeeeeeeeee03"), ("task", task)] {
            route(host, id, "other-workspace")
            XCTAssertTrue(app.sheets.buttons["OK"].firstMatch.waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["This widget belongs to another workspace or is unavailable. Open a task or list in your current workspace."].exists)
            app.sheets.buttons["OK"].firstMatch.click(); XCTAssertEqual(try saved(), before)
            XCTAssertFalse(app.textFields["taskTitle"].exists)
        }
        route("project", project, "ui-testing")
        let projectShown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "title CONTAINS %@", "Widget Studio"), object: app.windows.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [projectShown], timeout: 10), .completed)
        route("task", task, "ui-testing")
        XCTAssertTrue(app.textFields["taskTitle"].waitForExistence(timeout: 10)); XCTAssertEqual(app.textFields["taskTitle"].value as? String, "Sketch widget concept")
        XCTAssertEqual(try saved(), before)
        retainWindow(app, name: "Matching widget task opens only its workspace")
        app.typeKey("q", modifierFlags: .command); XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
        app.launchArguments = ["--uitesting", "-onboardingSeen", "YES"]; liveConflictLaunch(app)
        XCTAssertEqual(try saved(), before)
    }
}

// Explicit installed-host acceptance only. This driver preserves the normal app
// launch and existing desktop configurations; it never seeds or edits task data.
extension TaskfoldMacUITests {
    @MainActor func testInstalledWidgetHostCloudPhaseReadOnly() throws {
        guard Bundle(for: Self.self).bundleIdentifier == "com.dbakp.taskfold.mac.p0widgethosts.runner" else {
            throw XCTSkip("Dedicated installed widget host runner required")
        }
        continueAfterFailure = false
        let controlURL = URL(fileURLWithPath: "/private/tmp/taskfold-widget-cloud-control.json")
        guard FileManager.default.fileExists(atPath: controlURL.path) else { throw XCTSkip("Explicit private control required") }
        let control = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: controlURL))
        XCTAssertEqual(control["bundleID"], "com.dbakp.taskfold.mac.p0widgethosts")
        let phase = try XCTUnwrap(control["phase"])
        XCTAssertTrue(["first", "second", "local"].contains(phase))
        let accounts = try JSONDecoder().decode([String: [String: String]].self,
            from: Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(control["credentialsPath"]))))
        for key in ["first", "second"] {
            let account = try XCTUnwrap(accounts[key])
            XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(account["userID"])))
            XCTAssertTrue(account["email"]?.hasSuffix("@example.invalid") == true)
        }
        XCTAssertNotEqual(accounts["first"]?["userID"], accounts["second"]?["userID"])
        let directory = URL(fileURLWithPath: "/Users/" + NSUserName() + "/Library/Containers/com.dbakp.taskfold.mac.p0widgethosts/Data/Library/Application Support/Taskfold")
        let baseline = try JSONSerialization.jsonObject(with: Data(contentsOf:
            URL(fileURLWithPath: try XCTUnwrap(control["localBaselinePath"])))) as! NSDictionary
        func localUnchanged() throws {
            let local = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("local.json"))) as! NSDictionary
            XCTAssertEqual(local, baseline, "Normal local workspace must remain exact")
        }
        try localUnchanged()
        let app = XCUIApplication(bundleIdentifier: "com.dbakp.taskfold.mac.p0widgethosts")
        app.launchArguments = []; app.launchEnvironment = [:]
        XCTAssertEqual(app.state, .notRunning, "Start only after prior normal Quit")
        app.launch()
        // Leave the current readable workspace using the real confirmation.
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Account"]
        let accountTab = app.buttons["Account"].firstMatch
        XCTAssertTrue(accountTab.waitForExistence(timeout: 10)); accountTab.click()
        let label = phase == "first" ? "Leave Local Workspace…" : "Sign Out…"
        let leave = settings.buttons[label]
        XCTAssertTrue(leave.waitForExistence(timeout: 10))
        let scroll = settings.scrollViews.firstMatch
        for _ in 0..<10 {
            if scroll.frame.contains(leave.frame) { break }
            scroll.scroll(byDeltaX: 0, deltaY: -300)
        }
        XCTAssertTrue(scroll.frame.contains(leave.frame))
        leave.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let confirmation = app.sheets.buttons[phase == "first" ? "Leave" : "Sign Out"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5)); confirmation.click()
        let close = settings.buttons["_XCUI:CloseWindow"]
        XCTAssertTrue(close.waitForExistence(timeout: 10)); close.click()
        XCTAssertTrue(app.textFields["authEmail"].waitForExistence(timeout: 15))
        if phase == "local" {
            app.links["useLocally"].click()
            XCTAssertTrue(app.outlines.firstMatch.waitForExistence(timeout: 20))
            try localUnchanged()
        } else {
            let account = try XCTUnwrap(accounts[phase])
            let email = app.textFields["authEmail"], secret = app.secureTextFields["authPassword"]
            email.click(); email.typeText(try XCTUnwrap(account["email"]))
            secret.click()
            // Keep credentials out of test typing logs; restore the clipboard.
            let clipboard = NSPasteboard.general
            let saved = (clipboard.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
            clipboard.clearContents(); clipboard.setString(try XCTUnwrap(account["password"]), forType: .string)
            app.typeKey("v", modifierFlags: .command)
            clipboard.clearContents(); clipboard.writeObjects(saved.map { values in
                let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
            })
            app.buttons["nativeSignIn"].click()
            XCTAssertTrue(app.outlines.firstMatch.waitForExistence(timeout: 40))
            let server = try JSONSerialization.jsonObject(with: Data(contentsOf:
                URL(fileURLWithPath: try XCTUnwrap(control["baselinePath"])))) as! [String: Any]
            let expected = server[phase] as! [String: Any]
            let tables = expected["tables"] as! [String: Any]
            let expectedIDs = Set((tables["tasks"] as! [[String: Any]]).compactMap { $0["id"] as? String })
            let accountID = try XCTUnwrap(account["userID"])
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(accountID + ".json")),
                      let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let savedTables = value["tables"] as? [String: Any],
                      let tasks = savedTables["tasks"] as? [[String: Any]],
                      let pending = value["pending"] as? [Any] else { return false }
                return Set(tasks.compactMap { $0["id"] as? String }) == expectedIDs && pending.isEmpty
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 60), .completed)
            try localUnchanged()
        }
        retainWindow(app, name: "Installed widget host normal workspace phase " + phase)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        try localUnchanged()
    }
}

extension TaskfoldMacUITests {
    @MainActor func testProjectWorkflowMultiLineTemplateArchiveAndRelaunch() throws {
        guard Bundle(for: Self.self).bundleIdentifier?.contains("workflowtests") == true else { throw XCTSkip("Requires a disposable workflow test app") }
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--workflow-fixture", "--section=inbox"]
        app.launch(); defer { app.terminate() }
        let capture = app.buttons["openMultiLineCapture"]
        XCTAssertTrue(capture.waitForExistence(timeout: 8)); capture.click()
        let input = app.textViews["multiLineText"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.click(); input.typeText("- Capture Mac workflow idea\n- Review Mac workflow sketch tomorrow p1")
        app.buttons["reviewMultiLine"].click()
        XCTAssertTrue(app.buttons["saveMultiLine"].waitForExistence(timeout: 5)); app.buttons["saveMultiLine"].click()
        app.staticTexts["Inbox"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Capture Mac workflow idea"].waitForExistence(timeout: 8))
        app.buttons["openTemplates"].click()
        let name = app.textFields["templateName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.click(); name.typeText("Weekly Mac launch")
        app.buttons["saveWorkflowTemplate"].click()
        let template = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workflowTemplate-")).firstMatch
        XCTAssertTrue(template.waitForExistence(timeout: 8)); template.click()
        XCTAssertTrue(app.buttons["applyWorkflowTemplate"].waitForExistence(timeout: 5)); app.buttons["applyWorkflowTemplate"].click()
        XCTAssertTrue(NSPredicate(format: "exists == false").evaluate(with: app.buttons["applyWorkflowTemplate"]) || XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["applyWorkflowTemplate"])], timeout: 5) == .completed)
        app.buttons["Done"].firstMatch.click()
        let root = app.descendants(matching: .any)["project-f0742000-1111-4111-8111-000000000001"].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 5)); root.rightClick(); app.menuItems["Edit Project…"].click()
        let archived = app.checkBoxes["projectArchived"]
        XCTAssertTrue(archived.waitForExistence(timeout: 5)); archived.click(); app.buttons["saveRecord"].click()
        app.buttons["openArchivedProjects"].click()
        XCTAssertTrue(app.staticTexts["Design studio"].waitForExistence(timeout: 5))
        app.buttons["restoreProject-f0742000-1111-4111-8111-000000000001"].click()
        app.buttons["Done"].firstMatch.click()
        app.terminate(); app.launchArguments = ["--uitesting", "--section=inbox"]; app.launch()
        app.staticTexts["Inbox"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Capture Mac workflow idea"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Weekly Mac launch"].exists)
    }
}

/// Native controls and durable recovery in the exact, network-isolated Mac host.
final class TeamWorkflowMacUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private let bundle = "com.dbakp.taskfold.mac.workflowteststeameditbridge"
    private let definition = "ec240000-0000-4000-8000-000000000061"
    @MainActor private func support() throws -> URL {
        // Resolve the app's reserved container independently of the runner's home.
        let user = try XCTUnwrap(getpwuid(getuid()))
        return URL(fileURLWithPath: String(cString: user.pointee.pw_dir), isDirectory: true)
            .appendingPathComponent("Library/Containers/" + bundle + "/Data/Library/Application Support")
    }
    @MainActor private func cache() throws -> [String:Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: support().appendingPathComponent("Taskfold/ec240000-0000-4000-8000-000000000001.json"))) as! [String:Any] }
    private func rows(_ cache: [String:Any], _ table: String) -> NSArray { ((cache["tables"] as? [String:[[String:Any]]])?[table] ?? []) as NSArray }
    @MainActor private func stateFile() throws -> URL { try support().appendingPathComponent("TaskfoldTeamLibraryNativeFixture-workflowteststeameditbridge/state.json") }
    @MainActor private func state() throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: stateFile())) as! [String: Any] }
    @MainActor private func launch(_ app: XCUIApplication, reset: Bool = true, lost: Bool = false, headings: Bool = false, capabilityOff: Bool = false) throws {
        guard Bundle(for: Self.self).bundleIdentifier == bundle + ".runner" else { throw XCTSkip("Requires the reserved isolated Mac host") }
        app.launchArguments = ["--team-editor-testing", "--team-library-testing", "-appearance", "light"] + (reset ? ["--team-editor-reset"] : []) + (lost ? ["--workflow-run-lose-reply"] : []) + (headings ? ["--team-heading-testing", "--workflow-heading-testing"] : []) + (capabilityOff ? ["--team-heading-capability-off"] : [])
        app.launch(); app.activate()
        XCTAssertTrue(app.buttons["openTeamTemplateLibraryFixture"].waitForExistence(timeout: 15), app.debugDescription)
    }
    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        let form = app.descendants(matching: .scrollView).matching(identifier: "sharedWorkflowForm").firstMatch
        for _ in 0..<12 {
            if element.exists, element.isHittable { return }
            XCTAssertTrue(form.exists, app.debugDescription); form.scroll(byDeltaX: 0, deltaY: -250)
        }
        XCTFail("Workflow control could not be reached: " + app.debugDescription)
    }
    @MainActor private func choose(_ id: String, title: String, app: XCUIApplication) {
        let picker = app.popUpButtons[id]; XCTAssertTrue(picker.waitForExistence(timeout: 12), app.debugDescription); picker.click()
        let item = app.menuItems[title].firstMatch; XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription); item.click()
    }
    @MainActor private func review(_ app: XCUIApplication, personal: Bool = false, available: Bool = true) {
        if personal {
            app.buttons["openPrivateWorkflowRunFixture"].click()
            let run = app.buttons["runPrivateTemplateShared"]; XCTAssertTrue(run.waitForExistence(timeout: 10)); run.click()
        } else {
            app.buttons["openTeamTemplateLibraryFixture"].click()
            let item = app.buttons["teamTemplate-" + definition]; XCTAssertTrue(item.waitForExistence(timeout: 12)); item.click()
            let run = app.buttons["runTeamTemplate"]; XCTAssertTrue(run.waitForExistence(timeout: 10)); run.click()
        }
        choose("sharedWorkflowTeam", title: "Widget Studio", app: app)
        choose("sharedWorkflowProject", title: "Design board", app: app)
        let preview = app.buttons["reviewSharedWorkflow"]; reveal(preview, app: app); preview.click()
        if !available { return }
        let create = app.buttons["createSharedWorkflow"]; reveal(create, app: app); XCTAssertTrue(create.exists); XCTAssertFalse(create.isEnabled)
    }
    @MainActor private func create(_ app: XCUIApplication) {
        let acknowledge = app.switches["acknowledgeSharedWorkflow"]; reveal(acknowledge, app: app); acknowledge.click()
        let create = app.buttons["createSharedWorkflow"]; reveal(create, app: app); XCTAssertTrue(create.isEnabled); create.click()
    }
    @MainActor func testReviewAndBackCreateNothing() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try launch(app); review(app)
        shot(app, "mac-shared-workflow-review")
        let back = app.buttons["backSharedWorkflow"]; reveal(back, app: app); back.click()
        XCTAssertTrue(app.buttons["reviewSharedWorkflow"].waitForExistence(timeout: 5))
        let value = try state(); XCTAssertEqual(value["workflowCalls"] as? Int, 0); XCTAssertTrue((value["workflowRequests"] as? [String: Any])?.isEmpty == true)
    }
    @MainActor func testChangedSourceRefusesBeforeSend() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try launch(app); review(app)
        var value = try state(), items = try XCTUnwrap(value["items"] as? [[String: Any]])
        let index = try XCTUnwrap(items.firstIndex { $0["id"] as? String == definition })
        var document = try XCTUnwrap(items[index]["document"] as? [String: Any]), tasks = try XCTUnwrap((items[index]["document"] as? [String: Any])?["tasks"] as? [[String: Any]])
        tasks[0]["title"] = "Changed shared review"; document["tasks"] = tasks
        items[index]["document"] = document; items[index]["revision"] = (items[index]["revision"] as? Int ?? 0) + 1
        value["items"] = items; value["revision"] = (value["revision"] as? Int ?? 0) + 1
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: stateFile(), options: .atomic)
        create(app); XCTAssertTrue(app.staticTexts["sharedWorkflowMessage"].waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertEqual(try state()["workflowCalls"] as? Int, 0); shot(app, "mac-shared-workflow-source-changed")
    }
    @MainActor func testPrivateTemplateCreatesInSharedProject() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try launch(app); review(app, personal: true); create(app)
        XCTAssertTrue(app.staticTexts["sharedWorkflowSuccess"].waitForExistence(timeout: 12), app.debugDescription)
        let requests = try XCTUnwrap(state()["workflowRequests"] as? [String: [String: Any]]); XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(requests.values.first?["_body"] as? [String: Any]); XCTAssertEqual((body["source"] as? [String: Any])?["kind"] as? String, "personal")
        shot(app, "mac-private-template-shared-workflow")
    }
    @MainActor func testLostReplyRelaunchAndExactRecovery() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try launch(app, lost: true); review(app); create(app)
        XCTAssertTrue(app.staticTexts["sharedWorkflowRecoveryMessage"].waitForExistence(timeout: 12), app.debugDescription)
        let original = try XCTUnwrap(state()["workflowRequests"] as? NSDictionary); XCTAssertEqual(original.count, 1); shot(app, "mac-shared-workflow-saved")
        app.terminate(); try launch(app, reset: false)
        app.buttons["openWorkflowRecoveryFixture"].click()
        let entry = app.buttons["savedTeamWorkflowRequest"]; XCTAssertTrue(entry.waitForExistence(timeout: 12)); entry.click()
        let retry = app.buttons["retrySharedWorkflow"]; XCTAssertTrue(retry.waitForExistence(timeout: 10)); retry.click()
        let confirm = app.buttons.matching(identifier: "confirmSharedWorkflowRetry").firstMatch; XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.click()
        XCTAssertTrue(app.staticTexts["sharedWorkflowSuccess"].waitForExistence(timeout: 12), app.debugDescription)
        let result = try state(); XCTAssertEqual(result["workflowRequests"] as? NSDictionary, original); XCTAssertEqual((result["workflowReceipts"] as? [String: Any])?.count, 1); XCTAssertEqual(result["workflowCalls"] as? Int, 2)
        shot(app, "mac-shared-workflow-original-confirmed")
    }
}

/// Recovery acceptance in the reserved, signed Mac host only.
final class TeamCompletionRecoveryMacUITests: XCTestCase {
    private let bundle = "com.dbakp.taskfold.mac.workflowteststeameditbridge"
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private func support() throws -> URL {
        // Foundation resolves the current user's home to the runner's sandbox.
        // The passwd record locates the separate, reserved app container instead.
        let user = try XCTUnwrap(getpwuid(getuid()))
        let home = URL(fileURLWithPath: String(cString: user.pointee.pw_dir), isDirectory: true)
        return home.appendingPathComponent("Library/Containers/" + bundle + "/Data/Library/Application Support")
    }
    private func saved() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: support().appendingPathComponent("Taskfold/ec240000-0000-4000-8000-000000000001.json"))) as! [String: Any]
    }
    private func pending(_ value: [String: Any]) -> [[String: Any]] { value["pending"] as? [[String: Any]] ?? [] }
    private func canonical(_ value: [String: Any]) -> NSDictionary {
        var result = value
        if var cache = result["teamWorkspace"] as? [String: Any] {
            for key in ["knownTasks", "quarantined"] { if let ids = cache[key] as? [String] { cache[key] = ids.sorted() } }; result["teamWorkspace"] = cache
        }
        return result as NSDictionary
    }
    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); capture.name = name; capture.lifetime = .keepAlways; add(capture)
    }
    private func attach(_ value: Any, _ name: String) throws {
        let proof = XCTAttachment(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), uniformTypeIdentifier: "public.json"); proof.name = name; proof.lifetime = .keepAlways; add(proof)
    }
    /// XCTest starts the process; Launch Services supplies the user-open event
    /// that Finder/Dock normally send. Never create a second app instance.
    @MainActor private func open(_ app: XCUIApplication) throws {
        app.launch()
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
        XCTAssertEqual(instances.count, 1)
        let url = try XCTUnwrap(instances.first?.bundleURL)
        let opened = expectation(description: "Open the reserved Mac workspace")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            XCTAssertNil(error); opened.fulfill()
        }
        wait(for: [opened], timeout: 10)
        app.activate()
    }
    @MainActor private func launch(_ app: XCUIApplication, mode: String, single: Bool, refresh: Bool = false, recorded: Bool = true, storage: String? = nil, race: String? = nil, dependent: Bool = true, recordedDraft: Bool = false, mentions: Bool = false, preferences: Bool = false, cancelling: Bool = false, cancellationRace: Bool = false, capturedMentions: Bool = false, connectedProvisional: Bool = false) throws {
        guard Bundle(for: Self.self).bundleIdentifier == bundle + ".runner" else { throw XCTSkip("Reserved isolated Mac host required") }
        app.launchArguments = ["--team-editor-testing", "--team-editor-reset", "--team-batch-testing", "--team-batch-recovery-testing", "--team-batch-recovery-recorded", "--team-batch-recovery-" + mode, "-appearance", "light"]
        if !recorded { app.launchArguments.removeAll { $0 == "--team-batch-recovery-recorded" } }
        if let storage { app.launchArguments.append("--team-recovery-storage=" + storage) }
        if recordedDraft { app.launchArguments.append("--team-recorded-draft-testing") }
        if mentions { app.launchArguments.append("--team-recorded-mention-testing") }
        if capturedMentions { app.launchArguments.append("--team-captured-mention-testing") }
        if connectedProvisional { app.launchArguments += ["--team-connected-provisional-testing", "--team-batch-recovery-recurring"] }
        if preferences { app.launchArguments.append("--team-recorded-order-testing") }
        if cancelling { app.launchArguments.append("--team-cancelled-draft-testing") }
        if cancellationRace { app.launchArguments.append("--team-cancelled-draft-recorded-race") }
        if let race { app.launchArguments.append("--team-recovery-race=" + race) }
        if single { app.launchArguments.append("--team-single-recovery-testing") }
        if refresh { app.launchArguments.append("--team-single-recovery-refresh") }
        else if dependent { app.launchArguments.append("--team-batch-recovery-dependent") }
        try open(app)
        XCTAssertTrue(app.buttons["openMacCompletionRecovery"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.windows.count, 1)
    }
    @MainActor private func cold(_ mode: String, single: Bool) throws {
        let app = XCUIApplication(); defer { app.terminate() }; try launch(app, mode: mode, single: single)
        app.buttons["openMacCompletionRecovery"].click()
        let confirm = app.buttons[single ? "continueTeamCompletionReview" : "continueTeamBatchRecovery"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 12), app.debugDescription)
        let before = try saved(), tail = Array(pending(before).dropFirst())
        XCTAssertFalse(tail.isEmpty)
        app.buttons[single ? "Later" : "laterTeamBatchRecovery"].click()
        XCTAssertTrue(app.buttons["openMacCompletionRecovery"].waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments.removeAll { $0 == "--team-editor-reset" }; app.launchArguments.append("--team-batch-recovery-blocked-sync"); try open(app)
        let reviewAppeared = confirm.waitForExistence(timeout: 15)
        if !reviewAppeared {
            try attach(try saved(), "Mac cold discovery failed snapshot")
            if let data = try? Data(contentsOf: support().appendingPathComponent("taskfold-cold-discovery-diagnostic.json")), let diagnostic = try? JSONSerialization.jsonObject(with: data) { try attach(diagnostic, "Mac cold discovery diagnostic") }
            let traceURL = try support().appendingPathComponent("taskfold-cold-discovery-trace.json")
            if let data = try? Data(contentsOf: traceURL), let trace = try? JSONSerialization.jsonObject(with: data) { try attach(trace, "Mac cold discovery failed trace") }
        }
        XCTAssertTrue(reviewAppeared, app.debugDescription)
        let discovered = try saved()
        XCTAssertEqual(pending(discovered) as NSArray, pending(before) as NSArray)
        XCTAssertEqual(discovered["tables"] as? NSDictionary, before["tables"] as? NSDictionary)
        let trace = try JSONSerialization.jsonObject(with: Data(contentsOf: support().appendingPathComponent("taskfold-cold-discovery-trace.json"))) as! [[String: String]]
        XCTAssertEqual(trace, [["method": "POST", "path": "/rest/v1/rpc/taskfold_workspace_boundary"], ["method": "POST", "path": "/rest/v1/rpc/taskfold_review_team_completion" + (single ? "" : "_batch")]])
        try attach(trace, "Mac recovery read trace " + (single ? "single " : "group ") + mode)
        shot(app, "Mac recorded recovery " + (single ? "single " : "group ") + mode)
        XCTAssertTrue(confirm.isEnabled); confirm.click()
        XCTAssertTrue(app.buttons["openMacCompletionRecovery"].waitForExistence(timeout: 12))
        let after = try saved()
        XCTAssertEqual(pending(after) as NSArray, tail as NSArray)
        XCTAssertEqual(after["tables"] as? NSDictionary, before["tables"] as? NSDictionary)
        let cache = try XCTUnwrap(after["teamWorkspace"] as? [String: Any]), boundary = try XCTUnwrap(cache["boundary"] as? [String: Any]), raw = try XCTUnwrap(boundary["raw"] as? [String: Any])
        XCTAssertEqual((raw["projects"] as? [[String: Any]])?.first?["can_send_tasks"] as? Bool, false)
        XCTAssertEqual((raw["projects"] as? [[String: Any]])?.first?["archived"] as? Bool, mode == "archived")
        XCTAssertEqual(raw["setup_paused"] as? Bool, mode == "paused")
        XCTAssertEqual(app.windows.count, 1)
        app.terminate(); app.launchArguments.removeAll { $0 == "--team-batch-recovery-blocked-sync" }; try open(app)
        XCTAssertTrue(app.buttons["openMacCompletionRecovery"].waitForExistence(timeout: 12))
        let restarted = try saved(); XCTAssertEqual(canonical(after), canonical(restarted)); XCTAssertEqual(app.windows.count, 1)
        try attach(after, "Mac recovery after acceptance " + (single ? "single " : "group ") + mode)
        try attach(restarted, "Mac recovery after relaunch " + (single ? "single " : "group ") + mode)
    }
    @MainActor func testRecordedSingleViewerColdRecovery() throws { try cold("viewer", single: true) }
    @MainActor func testRecordedSingleArchiveColdRecovery() throws { try cold("archived", single: true) }
    @MainActor func testRecordedSinglePauseColdRecovery() throws { try cold("paused", single: true) }
    @MainActor func testRecordedGroupViewerColdRecovery() throws { try cold("viewer", single: false) }
    @MainActor func testRecordedGroupArchiveColdRecovery() throws { try cold("archived", single: false) }
    @MainActor func testRecordedGroupPauseColdRecovery() throws { try cold("paused", single: false) }
    @MainActor func testRecordedSingleRefreshShowsCurrentObservation() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try launch(app, mode: "viewer", single: true, refresh: true)
        app.buttons["openMacCompletionRecovery"].click()
        let initial = app.staticTexts["Initial synced instructions"]; XCTAssertTrue(initial.waitForExistence(timeout: 12), app.debugDescription)
        let before = try saved(); app.buttons["refreshTeamCompletionReview"].click()
        XCTAssertTrue(app.staticTexts["Updated synced instructions"].waitForExistence(timeout: 10)); XCTAssertFalse(initial.exists)
        XCTAssertEqual(canonical(try saved()), canonical(before))
        shot(app, "Mac completion refresh current observation")
        let confirm = app.buttons["continueTeamCompletionReview"]; XCTAssertTrue(confirm.isEnabled); confirm.click()
        XCTAssertTrue(app.buttons["openMacCompletionRecovery"].waitForExistence(timeout: 10))
        let after = try saved(); XCTAssertTrue(pending(after).isEmpty)
        XCTAssertTrue(((after["tables"] as? [String: Any])?["tasks"] as? [[String: Any]])?.contains { $0["description"] as? String == "Updated synced instructions" } == true)
        try attach(after, "Mac refreshed recovery saved state"); XCTAssertEqual(app.windows.count, 1)
    }
}


extension TeamCompletionRecoveryMacUITests {
    @MainActor private func storageRecovery(_ fault: String) throws {
        let app = XCUIApplication(); defer { app.terminate() }
        try launch(app, mode: "viewer", single: false, recorded: fault == "cache", storage: fault)
        app.buttons["openMacCompletionRecovery"].click()
        XCTAssertTrue(app.buttons[fault == "cache" ? "continueTeamBatchRecovery" : "cancelTeamBatchRecovery"].waitForExistence(timeout: 12))
        let fm = FileManager.default, support = try support()
        let cacheFile = support.appendingPathComponent("Taskfold/ec240000-0000-4000-8000-000000000001.json")
        // These deterministic paths belong only to the reserved synthetic account/origin.
        let vault = cacheFile.deletingLastPathComponent().appendingPathComponent("Backups/d2be2d54-84e6-8f3d-8850-546d0835535a")
        let selections = vault.appendingPathComponent("Team drafts/1d019528-c5bc-8e72-8e2a-1305600e9a82/Selections")
        defer {
            app.terminate()
            app.launchArguments = ["--team-editor-testing", "--team-recovery-storage-cleanup"]
            do { try open(app); XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("taskfold-storage-proof-journal.json").path)) }
            catch { XCTFail("Could not restore reserved storage fixture: \(error)") }
            app.terminate()
        }
        let before = try saved(), expected = pending(before), nonce = try XCTUnwrap(expected.first?["id"] as? String).lowercased()
        let ledger = support.appendingPathComponent("taskfold-group-review-peer.json")
        func cancellationLedger() throws -> [String: Any] {
            guard fm.fileExists(atPath: ledger.path) else { return [:] }
            return try JSONSerialization.jsonObject(with: Data(contentsOf: ledger)) as! [String: Any]
        }
        XCTAssertNil(try cancellationLedger()[nonce])
        app.buttons["blockNativeRecoveryStorage"].click()
        XCTAssertTrue(app.staticTexts["Storage blocked"].waitForExistence(timeout: 8), app.debugDescription)
        let button = app.buttons[fault == "cache" ? "continueTeamBatchRecovery" : "cancelTeamBatchRecovery"]
        button.click()
        let error = app.descendants(matching: .any)["teamBatchRecoveryError"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Taskfold couldn’t finish saving this review. Your queued work is unchanged. Check storage access and try again."].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(button.isEnabled, "The exact review remains retryable after storage failure")
        XCTAssertNil(try cancellationLedger()[nonce], "No cancellation can precede the required durable safety copies")
        let durableURL = fault == "cache" ? cacheFile.appendingPathExtension("storage-proof-held") : cacheFile
        let durable = try JSONSerialization.jsonObject(with: Data(contentsOf: durableURL)) as! NSDictionary
        XCTAssertEqual(durable, before as NSDictionary)
        if fault == "backup" {
            let files = try fm.contentsOfDirectory(at: selections, includingPropertiesForKeys: nil).filter { $0.pathExtension == "taskfoldselection" }
            XCTAssertEqual(files.count, 1, "Draft persists even if the following workspace backup fails")
        }
        shot(app, "Storage failure keeps reviewed work " + fault)
        app.buttons["repairNativeRecoveryStorage"].click()
        XCTAssertTrue(app.staticTexts["Storage available"].waitForExistence(timeout: 8))
        button.click()
        XCTAssertTrue(app.buttons["openMacCompletionRecovery"].waitForExistence(timeout: 20), app.debugDescription)
        let after = try saved()
        if fault == "cache" {
            XCTAssertEqual(pending(after) as NSArray, Array(expected.dropFirst()) as NSArray)
            XCTAssertEqual(after["tables"] as? NSDictionary, before["tables"] as? NSDictionary)
        } else {
            XCTAssertTrue(pending(after).isEmpty); XCTAssertNotNil(try cancellationLedger()[nonce])
            let files = try fm.contentsOfDirectory(at: selections, includingPropertiesForKeys: nil).filter { $0.pathExtension == "taskfoldselection" }
            XCTAssertEqual(files.count, 1, "Retry reuses the verified permanent draft")
            XCTAssertFalse(String(decoding: try Data(contentsOf: XCTUnwrap(files.first)), as: UTF8.self).contains("Keep these later workshop instructions"))
        }
        app.terminate(); app.launchArguments.removeAll { $0 == "--team-editor-reset" }; try open(app)
        XCTAssertTrue(app.buttons["openMacCompletionRecovery"].waitForExistence(timeout: 15))
        func canonical(_ value: [String: Any]) -> NSDictionary {
            var result = value
            if var access = result["teamWorkspace"] as? [String: Any] {
                for key in ["knownTasks", "quarantined"] { if let ids = access[key] as? [String] { access[key] = ids.sorted() } }; result["teamWorkspace"] = access
            }
            return result as NSDictionary
        }
        let restarted = try saved(); XCTAssertEqual(canonical(after), canonical(restarted))
        for (phase, value) in [("before", before), ("failed durable", durable as! [String: Any]), ("after retry", after), ("after relaunch", restarted)] {
            let proof = XCTAttachment(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), uniformTypeIdentifier: "public.json"); proof.name = "Storage " + fault + " " + phase; proof.lifetime = .keepAlways; add(proof)
        }
        if fault != "cache" {
            app.buttons["openMacSavedDrafts"].click()
            let draft = app.buttons["savedTeamSelectionDraft"].firstMatch; XCTAssertTrue(draft.waitForExistence(timeout: 12)); draft.click()
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Keep these later workshop instructions", "Keep these later workshop instructions")).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
            shot(app, "Storage repaired permanent draft " + fault)
        }
    }
    @MainActor func testRecordedRecoveryWorkspaceWriteFailureRetainsExactQueueAndRetry() throws { try storageRecovery("cache") }
    @MainActor func testCancelledRecoveryDraftWriteFailureKeepsActionBeforeSafeRetry() throws { try storageRecovery("draft") }
    @MainActor func testCancelledRecoveryBackupIndexFailureKeepsSavedDraftBeforeSafeRetry() throws { try storageRecovery("backup") }
}


extension TeamCompletionRecoveryMacUITests {
    @MainActor private func delayedRecovery(_ mode: String) throws {
        let app = XCUIApplication(); defer { app.terminate() }
        try launch(app, mode: "editor", single: mode.hasPrefix("single"), recorded: !mode.contains("cancel"), race: mode)
        if mode.hasPrefix("single-cancel") {
            app.terminate(); app.launchArguments.removeAll { $0 == "--team-batch-recovery-dependent" }; try open(app)
        }
        app.buttons["openMacCompletionRecovery"].click()
        let later = app.buttons[mode.hasPrefix("single") ? "Later" : "laterTeamBatchRecovery"]
        XCTAssertTrue(later.waitForExistence(timeout: 12)); later.click()
        app.buttons["runTeamRecoveryRace"].click()

        let finished = app.staticTexts["Passed " + mode]
        let didFinish = finished.waitForExistence(timeout: 30)
        if !didFinish, let data = try? Data(contentsOf: support().appendingPathComponent("taskfold-completion-race-proof.json")) {
            let failure = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); failure.name = "Delayed recovery failure " + mode; failure.lifetime = .keepAlways; add(failure)
        }
        XCTAssertTrue(didFinish, app.debugDescription)
        let file = try support().appendingPathComponent("taskfold-completion-race-proof.json")
        let data = try Data(contentsOf: file), proof = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(proof["status"] as? String, "passed"); XCTAssertEqual(proof["mode"] as? String, mode)
        let checks = try XCTUnwrap(proof["checks"] as? [String: Bool]); XCTAssertGreaterThanOrEqual(checks.count, 6); XCTAssertTrue(checks.values.allSatisfy { $0 })
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); attachment.name = "Delayed recovery proof " + mode; attachment.lifetime = .keepAlways; add(attachment)
        shot(app, "Delayed recovery checked context " + mode)
        app.terminate(); app.launchArguments.removeAll { $0 == "--team-editor-reset" }; try open(app)
        XCTAssertTrue(app.buttons["openMacCompletionRecovery"].waitForExistence(timeout: 15))
        func canonical(_ value: [String: Any]) -> NSDictionary {
            var value = value
            if var cache = value["teamWorkspace"] as? [String: Any] {
                for key in ["knownTasks", "quarantined"] { if let ids = cache[key] as? [String] { cache[key] = ids.sorted() } }; value["teamWorkspace"] = cache
            }
            return value as NSDictionary
        }
        let current = try saved()
        XCTAssertEqual(canonical(current), canonical(try XCTUnwrap(proof["restored"] as? [String: Any])))
        let restarted = XCTAttachment(data: try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]), uniformTypeIdentifier: "public.json"); restarted.name = "Delayed recovery after relaunch " + mode; restarted.lifetime = .keepAlways; add(restarted)
    }
    @MainActor func testGroupRefreshRefusesResponseAfterAccessDowngrade() throws { try delayedRecovery("refresh-access") }
    @MainActor func testGroupRefreshKeepsCurrentMessageAfterDelayedErrorAndAccessChange() throws { try delayedRecovery("refresh-access-error") }
    @MainActor func testSingleRefreshKeepsCurrentMessageAfterDelayedErrorAndAccessChange() throws { try delayedRecovery("single-refresh-access-error") }
    @MainActor func testGroupCancellationReplyCannotAffectSwitchedAccount() throws { try delayedRecovery("cancel-account") }
    @MainActor func testSingleCancellationReplyCannotAffectSwitchedAccount() throws { try delayedRecovery("single-cancel-account") }
    @MainActor func testGroupRefreshRefusesOldSessionAfterAccountSwitchAndReturn() throws { try delayedRecovery("refresh-account-return") }
    @MainActor func testGroupRefreshKeepsEditsMadeWhileResponseIsHeld() throws { try delayedRecovery("refresh-edit") }
}


extension TeamCompletionRecoveryMacUITests {
    @MainActor func testGroupRefreshKeepsCurrentMessageAfterDelayedErrorAndNewEdit() throws { try delayedRecovery("refresh-edit-error") }
    @MainActor func testSingleRefreshKeepsCurrentMessageAfterDelayedErrorAndNewEdit() throws { try delayedRecovery("single-refresh-edit-error") }
}


extension TeamCompletionRecoveryMacUITests {
    @MainActor func testGroupRefreshAcceptsDelayedResponseWhenContextIsUnchanged() throws { try delayedRecovery("refresh-current") }
}


extension TeamCompletionRecoveryMacUITests {
    @MainActor func testCurrentRefreshFailureStillReachesItsOwnPresentation() throws { try delayedRecovery("refresh-current-error") }
    @MainActor func testRefreshRefusesCredentialRenewalBeforeWorkspaceReload() throws { try delayedRecovery("refresh-session") }
}


extension TeamCompletionRecoveryMacUITests {
    @MainActor func testGroupCancellationErrorCannotReplaceMessageAfterAccessChange() throws { try delayedRecovery("cancel-access-error") }
    @MainActor func testSingleCancellationErrorKeepsNewEditsAndTheirCurrentMessage() throws { try delayedRecovery("single-cancel-edit-error") }
}


extension TeamCompletionRecoveryMacUITests {
    /// Exercise real filesystem failures through the individual review's alert,
    /// including a remote cancellation that outlives a failed local save.
    @MainActor private func singleStorageRecovery(_ scenario: String) throws {
        let app = XCUIApplication(); defer { app.terminate() }
        let recorded = scenario == "recorded-cache", fault = scenario == "cancel-backup" ? "backup" : "cache"
        try launch(app, mode: "viewer", single: true, recorded: recorded, storage: fault, dependent: recorded)
        app.buttons["openMacCompletionRecovery"].click()
        XCTAssertTrue(app.buttons[recorded ? "continueTeamCompletionReview" : "cancelSavedTeamCompletion"].waitForExistence(timeout: 12))
        let fm = FileManager.default, support = try support()
        let cacheFile = support.appendingPathComponent("Taskfold/ec240000-0000-4000-8000-000000000001.json")
        let vault = cacheFile.deletingLastPathComponent().appendingPathComponent("Backups/d2be2d54-84e6-8f3d-8850-546d0835535a")
        defer {
            app.terminate(); app.launchArguments = ["--team-editor-testing", "--team-recovery-storage-cleanup"]
            do { try open(app); XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("taskfold-storage-proof-journal.json").path)) }
            catch { XCTFail("Could not restore reserved individual storage fixture: \(error)") }
            app.terminate()
        }
        let before = try saved(), bytes = try Data(contentsOf: cacheFile), expected = pending(before)
        let head = try XCTUnwrap(expected.first), nonce = try XCTUnwrap(head["id"] as? String).lowercased()
        let command = try XCTUnwrap(head["teamCompletion"] as? [String: Any]), source = try XCTUnwrap(command["source"] as? [String: Any])
        XCTAssertEqual(expected.count, recorded ? 2 : 1); XCTAssertNil(head["teamTaskBatch"])
        let ledgerURL = support.appendingPathComponent("taskfold-group-review-peer.json")
        func ledger() throws -> [String: Any] {
            guard fm.fileExists(atPath: ledgerURL.path) else { return [:] }
            return try JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as! [String: Any]
        }
        XCTAssertNil(try ledger()[nonce])
        app.buttons["blockNativeRecoveryStorage"].click()
        XCTAssertTrue(app.staticTexts["Storage blocked"].waitForExistence(timeout: 8), app.debugDescription)
        let button = app.buttons[recorded ? "continueTeamCompletionReview" : "cancelSavedTeamCompletion"]
        XCTAssertTrue(button.isEnabled); button.click()
        let message = "Taskfold couldn’t finish saving this review. Your queued work is unchanged. Check storage access and try again."
        let warning = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", message, message)).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 15), app.debugDescription)
        shot(app, "Individual storage alert " + scenario)
        let failedLedger = try ledger()
        if scenario == "cancel-cache" { XCTAssertNotNil(failedLedger[nonce], "Remote cancellation is durable even though local cache write failed") }
        else { XCTAssertNil(failedLedger[nonce], "Required safety copy must precede cancellation") }
        let durableURL = fault == "cache" ? cacheFile.appendingPathExtension("storage-proof-held") : cacheFile
        let failedBytes = try Data(contentsOf: durableURL)
        XCTAssertEqual(failedBytes, bytes, "Failure cannot rewrite even the durable workspace bytes")
        let failed = try JSONSerialization.jsonObject(with: failedBytes) as! [String: Any]
        XCTAssertEqual(canonicalSingleStorage(failed), canonicalSingleStorage(before))
        let ok = app.windows.buttons["OK"].firstMatch; XCTAssertTrue(ok.waitForExistence(timeout: 5)); ok.click()
        app.buttons["repairNativeRecoveryStorage"].click()
        XCTAssertTrue(app.staticTexts["Storage available"].waitForExistence(timeout: 8))
        var reopened: [String: Any]?
        if scenario == "cancel-cache" {
            app.terminate(); app.launchArguments.removeAll { $0 == "--team-editor-reset" }; try open(app)
            let review = app.buttons["openMacCompletionRecovery"]; XCTAssertTrue(review.waitForExistence(timeout: 15)); review.click()
            XCTAssertTrue(button.waitForExistence(timeout: 12)); reopened = try saved()
            XCTAssertEqual(canonicalSingleStorage(try XCTUnwrap(reopened)), canonicalSingleStorage(before))
            XCTAssertEqual(try ledger() as NSDictionary, failedLedger as NSDictionary, "Reading cancelled status cannot replace the frozen cancellation")
        }
        XCTAssertTrue(button.isEnabled, "The same individual review remains retryable"); button.click()
        XCTAssertTrue(app.buttons["openMacCompletionRecovery"].waitForExistence(timeout: 20), app.debugDescription)
        let after = try saved()
        if recorded {
            XCTAssertEqual(pending(after) as NSArray, Array(expected.dropFirst()) as NSArray)
            XCTAssertEqual(after["tables"] as? NSDictionary, before["tables"] as? NSDictionary)
            XCTAssertNil(try ledger()[nonce])
        } else {
            XCTAssertTrue(pending(after).isEmpty); XCTAssertNotNil(try ledger()[nonce])
            let afterRows = try XCTUnwrap((after["tables"] as? [String: Any])?["tasks"] as? [[String: Any]])
            XCTAssertEqual(try XCTUnwrap(afterRows.first { $0["id"] as? String == source["id"] as? String }) as NSDictionary, source as NSDictionary)
            let oldRows = try XCTUnwrap((before["tables"] as? [String: Any])?["tasks"] as? [[String: Any]])
            XCTAssertEqual(afterRows.filter { $0["id"] as? String != source["id"] as? String } as NSArray, oldRows.filter { $0["id"] as? String != source["id"] as? String } as NSArray)
            if scenario == "cancel-cache" { XCTAssertEqual(try ledger() as NSDictionary, failedLedger as NSDictionary) }
        }
        let metadata = try XCTUnwrap(after["teamWorkspace"] as? [String: Any]), boundary = try XCTUnwrap(metadata["boundary"] as? [String: Any]), raw = try XCTUnwrap(boundary["raw"] as? [String: Any])
        XCTAssertEqual((raw["projects"] as? [[String: Any]])?.first?["can_send_tasks"] as? Bool, false)
        app.terminate(); app.launchArguments.removeAll { $0 == "--team-editor-reset" }; try open(app)
        XCTAssertTrue(app.buttons["openMacCompletionRecovery"].waitForExistence(timeout: 15))
        let restarted = try saved(); XCTAssertEqual(canonicalSingleStorage(after), canonicalSingleStorage(restarted))
        var phases: [(String, [String: Any])] = [("before", before), ("failed durable", failed), ("after retry", after), ("after relaunch", restarted), ("cancellation ledger after failure", failedLedger), ("cancellation ledger after retry", try ledger())]
        if let reopened { phases.append(("reopened after failure", reopened)) }
        for (phase, value) in phases {
            let proof = XCTAttachment(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            proof.name = "Individual storage " + scenario + " " + phase; proof.lifetime = .keepAlways; add(proof)
        }
        shot(app, "Individual storage repaired " + scenario)
    }
    private func canonicalSingleStorage(_ value: [String: Any]) -> NSDictionary {
        var value = value
        if var access = value["teamWorkspace"] as? [String: Any] {
            for key in ["knownTasks", "quarantined"] { if let ids = access[key] as? [String] { access[key] = ids.sorted() } }; value["teamWorkspace"] = access
        }
        return value as NSDictionary
    }
    @MainActor func testIndividualRecordedCacheFailureKeepsAuthoredTailAndRetry() throws { try singleStorageRecovery("recorded-cache") }
    @MainActor func testIndividualCancellationBackupFailureCannotSendBeforeRetry() throws { try singleStorageRecovery("cancel-backup") }
    @MainActor func testIndividualCancellationCacheFailureRecoversReceiptAfterRelaunch() throws { try singleStorageRecovery("cancel-cache") }
}


extension TeamCompletionRecoveryMacUITests {
    @MainActor private func recordedDraftRecovery(_ scenario: String, mentions: Bool = false, preferences: Bool = false, capturedMentions: Bool = false) throws {
        let app = XCUIApplication(); defer { app.terminate() }
        let single = scenario == "single", fault = scenario == "vault" ? "draft" : "cache"
        try launch(app, mode: "viewer", single: single, recorded: true, storage: fault, recordedDraft: true, mentions: mentions, preferences: preferences, capturedMentions: capturedMentions)
        app.buttons["openMacCompletionRecovery"].click()
        let fm = FileManager.default, support = try support()
        let cacheFile = support.appendingPathComponent("Taskfold/ec240000-0000-4000-8000-000000000001.json")
        let vault = cacheFile.deletingLastPathComponent().appendingPathComponent("Backups/d2be2d54-84e6-8f3d-8850-546d0835535a")
        let archive = vault.appendingPathComponent("Team drafts/1d019528-c5bc-8e72-8e2a-1305600e9a82/Recorded recovery")
        addTeardownBlock {
            await MainActor.run {
                let fm = FileManager.default
                app.terminate(); app.launchArguments = ["--team-editor-testing", "--team-recovery-storage-cleanup"]
                do { try self.open(app); XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("taskfold-storage-proof-journal.json").path)) }
                catch { XCTFail("Could not restore recorded draft fixture: \(error)") }
                app.terminate()
            }
        }
        let later = app.buttons[single ? "Later" : "laterTeamBatchRecovery"]
        XCTAssertTrue(later.waitForExistence(timeout: 10)); later.click()
        let admission = app.buttons["checkRecordedDraftAdmission"]; XCTAssertTrue(admission.waitForExistence(timeout: 10)); admission.click()
        XCTAssertTrue(app.staticTexts["Saved draft context protected"].waitForExistence(timeout: 12), app.debugDescription)
        app.buttons["openMacCompletionRecovery"].click()
        let before = try saved(), bytes = try Data(contentsOf: cacheFile), queue = pending(before)
        XCTAssertEqual(queue.count, preferences ? 6 : 2); XCTAssertEqual(queue[0]["teamCompletion"] != nil, single)
        let keep = app.buttons["preserveRecordedCompletionDraft"]
        XCTAssertTrue(keep.waitForExistence(timeout: 15), app.debugDescription)

        XCTAssertTrue(keep.isEnabled); shot(app, "Recorded draft review " + scenario)
        app.buttons["blockNativeRecoveryStorage"].click(); XCTAssertTrue(app.staticTexts["Storage blocked"].waitForExistence(timeout: 8))
        if scenario == "single" || scenario == "group" {
            app.buttons["repairNativeRecoveryStorage"].click(); XCTAssertTrue(app.staticTexts["Storage available"].waitForExistence(timeout: 8))
        }

        keep.click()
        if scenario == "cache" || scenario == "vault" {
            let warning = app.descendants(matching: .any)["teamBatchRecoveryError"].firstMatch
            XCTAssertTrue(warning.waitForExistence(timeout: 15), app.debugDescription)
            let durable = try Data(contentsOf: scenario == "cache" ? cacheFile.appendingPathExtension("storage-proof-held") : cacheFile)
            XCTAssertEqual(durable, bytes)
            if scenario == "cache" {
                let files = try fm.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil).filter { $0.pathExtension == "taskfoldrecovery" }
                XCTAssertEqual(files.count, 1, "Verified encrypted draft precedes retiring local work")
                let cipher = try Data(contentsOf: XCTUnwrap(files.first)); XCTAssertFalse(String(decoding: cipher, as: UTF8.self).contains("Keep these later workshop instructions"))
            } else { XCTAssertFalse(fm.fileExists(atPath: archive.appendingPathComponent("unexpected.taskfoldrecovery").path)) }
            shot(app, "Recorded draft storage failure " + scenario)
            app.buttons["repairNativeRecoveryStorage"].click(); XCTAssertTrue(app.staticTexts["Storage available"].waitForExistence(timeout: 8))
            XCTAssertTrue(keep.waitForExistence(timeout: 15));
            XCTAssertTrue(keep.isEnabled); keep.click()
        }
        XCTAssertTrue(app.buttons["openMacCompletionRecovery"].waitForExistence(timeout: 25), app.debugDescription)
        let after = try saved(); XCTAssertTrue(pending(after).isEmpty)
        let files = try fm.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil).filter { $0.pathExtension == "taskfoldrecovery" }
        XCTAssertEqual(files.count, 1, "Retry must reuse the same complete encrypted draft")
        let encrypted = try Data(contentsOf: XCTUnwrap(files.first)); XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains("Keep these later workshop instructions"))
        let oldRows = try XCTUnwrap((before["tables"] as? [String: Any])?["tasks"] as? [[String: Any]])
        let newRows = try XCTUnwrap((after["tables"] as? [String: Any])?["tasks"] as? [[String: Any]])
        let target = try XCTUnwrap(queue[1]["recordID"] as? String)
        XCTAssertFalse(newRows.contains { $0["id"] as? String == target })
        XCTAssertEqual(newRows.filter { $0["id"] as? String != target } as NSArray, oldRows.filter { $0["id"] as? String != target } as NSArray)
        let metadata = try XCTUnwrap(after["teamWorkspace"] as? [String: Any]), boundary = try XCTUnwrap(metadata["boundary"] as? [String: Any]), raw = try XCTUnwrap(boundary["raw"] as? [String: Any])
        XCTAssertEqual((raw["projects"] as? [[String: Any]])?.first?["can_send_tasks"] as? Bool, false)
        app.terminate(); app.launchArguments.removeAll { $0 == "--team-editor-reset" }; try open(app)
        let drafts = app.buttons["openMacSavedDrafts"]; XCTAssertTrue(drafts.waitForExistence(timeout: 15)); drafts.click()
        let item = app.buttons["savedRecordedCompletionDraft"].firstMatch; XCTAssertTrue(item.waitForExistence(timeout: 12), app.debugDescription); item.click()
        let preview = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Keep these later workshop instructions", "Keep these later workshop instructions")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 12), app.debugDescription)
        let detail = try Data(contentsOf: support.appendingPathComponent("taskfold-recorded-draft-proof.json"))
        let exported = try Data(contentsOf: support.appendingPathComponent("taskfold-recorded-export-proof.json"))
        let draft = try JSONSerialization.jsonObject(with: detail) as! [String: Any]
        XCTAssertEqual(draft["original"] as? NSDictionary, queue[0] as NSDictionary)
        XCTAssertEqual(canonicalRecordedDraft(try XCTUnwrap(draft["snapshot"] as? [String: Any])), canonicalRecordedDraft(before))
        XCTAssertEqual((draft["id"] as? String)?.lowercased(), files.first!.deletingPathExtension().lastPathComponent)
        let json = try JSONSerialization.jsonObject(with: exported) as! [String: Any]
        if preferences {
            let oldTables = before["tables"] as! [String: Any], newTables = after["tables"] as! [String: Any]
            let oldRows = try XCTUnwrap(oldTables["view_orders"] as? [[String: Any]]), newRows = try XCTUnwrap(newTables["view_orders"] as? [[String: Any]])
            XCTAssertEqual(newRows.count, 2)
            let oldIndependent = try XCTUnwrap(oldRows.first { $0["id"] as? String == "scope:inbox" }), newIndependent = try XCTUnwrap(newRows.first { $0["id"] as? String == "scope:inbox" })
            XCTAssertEqual(oldIndependent as NSDictionary, newIndependent as NSDictionary)
            let orders = queue.filter { $0["table"] as? String == "view_orders" }; XCTAssertEqual(orders.count, 4)
            let savedBefore = try XCTUnwrap((orders[0]["orderRecovery"] as? [String: Any])?["before"] as? [String: Any])
            XCTAssertEqual(newRows.first { $0["id"] as? String == "scope:today" } as NSDictionary?, savedBefore as NSDictionary)
            XCTAssertTrue(orders.allSatisfy { $0["orderRecovery"] != nil })
            let bindings = try XCTUnwrap((orders[0]["orderRecovery"] as? [String: Any])?["tasks"] as? [[String: Any]])
            let opaque = try XCTUnwrap(bindings.first { $0["id"] as? String == "ec240000-0000-4000-8000-000000000099" })
            XCTAssertNil(opaque["generation"]); XCTAssertNil(opaque["project"])
            XCTAssertFalse((newTables["tasks"] as! [[String: Any]]).contains { $0["id"] as? String == opaque["id"] as? String })

            XCTAssertEqual(Set(orders.compactMap { $0["id"] as? String }).count, 4)
            XCTAssertFalse(newRows.contains { ($0["id"] as? String)?.hasPrefix("widget-note:") == true })
            XCTAssertEqual((json["changes"] as? [[String: Any]])?.filter { $0["table"] as? String == "view_orders" } as NSArray?, orders as NSArray)
            let choices = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Pinned note choice:", "Pinned note choice:")).firstMatch
            XCTAssertTrue(choices.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(String(decoding: exported, as: UTF8.self).contains("orderRecovery"))
        }

        if mentions {
            let beforeRows = before["tables"] as! [String: Any], afterRows = after["tables"] as! [String: Any]
            let originalMarkers = try XCTUnwrap(beforeRows["_conversation_outbox"] as? [[String: Any]])
            XCTAssertEqual(originalMarkers.count, 1)
            if capturedMentions {
                XCTAssertNotNil(originalMarkers[0]["mention_recovery"])
                XCTAssertTrue((beforeRows["task_comments"] as? [[String: Any]])?.isEmpty == true)
                XCTAssertTrue((beforeRows["task_mentions"] as? [[String: Any]])?.isEmpty == true)
                XCTAssertTrue((afterRows["task_comments"] as? [[String: Any]])?.isEmpty == true)
                XCTAssertTrue((afterRows["task_mentions"] as? [[String: Any]])?.isEmpty == true)
                XCTAssertTrue(((json["conversation_context"] as? [[String: Any]]) ?? []).allSatisfy { $0["source"] as? String == "captured" })
            }
            XCTAssertEqual((originalMarkers[0]["intent"] as? [String: Any])?["kind"] as? String, "mention-read")
            XCTAssertEqual((afterRows["_conversation_outbox"] as? [[String: Any]])?.count, 0)
            XCTAssertEqual(json["conversations"] as? NSArray, originalMarkers as NSArray)
            XCTAssertEqual((json["conversation_context"] as? [[String: Any]])?.count, 2)
            XCTAssertTrue(String(decoding: exported, as: UTF8.self).contains("Native connected mention recovery proof"))
            let markerText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Mention marked read:", "Mention marked read:")).firstMatch
            XCTAssertTrue(markerText.waitForExistence(timeout: 10), app.debugDescription)
        }

        XCTAssertEqual(json["format"] as? String, "com.taskfold.saved-edits")
        XCTAssertEqual(json["changes"] as? NSArray, queue as NSArray)
        XCTAssertNil(json["snapshot"]); XCTAssertNil(json["review"]); XCTAssertNil(json["teamWorkspace"])
        XCTAssertTrue(String(decoding: exported, as: UTF8.self).contains("Keep these later workshop instructions"))
        shot(app, "Recorded draft retained preview " + scenario)
        let export = app.buttons["exportRecordedEdits"]
        for _ in 0..<8 where !export.isHittable { app.descendants(matching: .any)["savedRecordedEditsForm"].firstMatch.swipeUp() }
        XCTAssertTrue(export.isEnabled)
        if scenario == "group" {
            export.click()
            let cancel = app.sheets.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 12), app.debugDescription)
            let name = app.sheets.textFields.matching(NSPredicate(format: "value CONTAINS %@", "Taskfold-saved-edits")).firstMatch
            XCTAssertTrue(name.waitForExistence(timeout: 8), app.debugDescription)
            let filename = "Taskfold-recovery-" + UUID().uuidString.lowercased() + ".json"
            let destination = fm.temporaryDirectory.appendingPathComponent("taskfold-recorded-recovery-native-exports", isDirectory: true).appendingPathComponent(filename)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: destination) }
            name.click(); app.typeKey("a", modifierFlags: .command); name.typeText(filename)
            app.typeKey("g", modifierFlags: [.command, .shift])
            let path = app.sheets.textFields["PathTextField"].firstMatch
            XCTAssertTrue(path.waitForExistence(timeout: 8), app.debugDescription)
            path.click(); app.typeKey("a", modifierFlags: .command); path.typeText(destination.deletingLastPathComponent().path); app.typeKey(.return, modifierFlags: [])
            let selectedName = app.sheets.textFields.matching(NSPredicate(format: "value == %@", filename)).firstMatch
            XCTAssertTrue(selectedName.waitForExistence(timeout: 8), app.debugDescription)
            let selectedFolder = app.sheets.popUpButtons["where popup"].firstMatch
            XCTAssertTrue(selectedFolder.waitForExistence(timeout: 8), app.debugDescription)
            XCTAssertEqual(selectedFolder.value as? String, "taskfold-recorded-recovery-native-exports")
            let save = app.sheets.buttons["Save"].firstMatch.exists ? app.sheets.buttons["Save"].firstMatch : app.sheets.buttons["Export"].firstMatch
            XCTAssertTrue(save.waitForExistence(timeout: 8), app.debugDescription); XCTAssertTrue(save.isEnabled)
            shot(app, "Recorded draft native save picker"); save.click()
            XCTAssertTrue(app.staticTexts["Details saved."].waitForExistence(timeout: 12), app.debugDescription)
            let delivery = try Data(contentsOf: destination); XCTAssertEqual(delivery, exported)
            let delivered = XCTAttachment(data: delivery, uniformTypeIdentifier: "public.json"); delivered.name = "Recorded draft local delivery"; delivered.lifetime = .keepAlways; add(delivered)
            export.click(); XCTAssertTrue(cancel.waitForExistence(timeout: 12), app.debugDescription)
            shot(app, "Recorded draft native export picker"); cancel.click()
            XCTAssertTrue(cancel.waitForNonExistence(timeout: 12), app.debugDescription)
            XCTAssertTrue(export.waitForExistence(timeout: 10)); XCTAssertTrue(export.isEnabled)
            XCTAssertEqual(try Data(contentsOf: destination), delivery)
            shot(app, "Recorded draft export cancelled safely")
            XCTAssertEqual(canonicalRecordedDraft(try saved()), canonicalRecordedDraft(after), "Opening and cancelling export cannot replay saved edits")
        }
        let restarted = try saved(); XCTAssertEqual(canonicalRecordedDraft(after), canonicalRecordedDraft(restarted))
        for (phase, value) in [("before", before), ("after", after), ("relaunch", restarted), ("draft", draft), ("export", json)] {
            let proof = XCTAttachment(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            proof.name = "Recorded draft " + scenario + " " + phase; proof.lifetime = .keepAlways; add(proof)
        }
    }
    private func canonicalRecordedDraft(_ value: [String: Any]) -> NSDictionary {
        var value = value
        if var access = value["teamWorkspace"] as? [String: Any] {
            for key in ["knownTasks", "quarantined"] { if let ids = access[key] as? [String] { access[key] = ids.sorted() } }; value["teamWorkspace"] = access
        }
        return value as NSDictionary
    }
    @MainActor func testRecordedMissingSingleKeepsAuthoredEditsAndExportAfterRelaunch() throws { try recordedDraftRecovery("single") }
    @MainActor func testRecordedMissingSelectionKeepsAuthoredEditsAndExportAfterRelaunch() throws { try recordedDraftRecovery("group") }
    @MainActor func testRecordedDraftCacheFailurePreservesQueueAndReusesArchiveOnRetry() throws { try recordedDraftRecovery("cache") }
    @MainActor func testRecordedDraftVaultFailurePreservesQueueBeforeRetry() throws { try recordedDraftRecovery("vault") }
}

extension TeamCompletionRecoveryMacUITests {
    @MainActor func testRecordedMissingTaskKeepsConnectedMentionMarkerAfterRelaunch() throws { try recordedDraftRecovery("group", mentions: true) }
}

extension TeamCompletionRecoveryMacUITests {
    @MainActor func testRecordedMissingTaskKeepsOrderAndPinHistoryAfterRelaunch() throws { try recordedDraftRecovery("group", mentions: true, preferences: true) }
}

extension TeamCompletionRecoveryMacUITests {
    @MainActor private func cancelledDraftRecovery(_ scenario: String) throws {
        let app = XCUIApplication(); defer { app.terminate() }
        let single = true, mentions = true, preferences = true, fault = scenario == "vault" ? "draft" : "cache"
        try launch(app, mode: "viewer", single: single, recorded: false, storage: fault, recordedDraft: true, mentions: mentions, preferences: preferences, cancelling: true, cancellationRace: scenario == "race")
        app.buttons["openMacCompletionRecovery"].click()
        let fm = FileManager.default, support = try support()
        let cacheFile = support.appendingPathComponent("Taskfold/ec240000-0000-4000-8000-000000000001.json")
        let vault = cacheFile.deletingLastPathComponent().appendingPathComponent("Backups/d2be2d54-84e6-8f3d-8850-546d0835535a")
        let archive = vault.appendingPathComponent("Team drafts/1d019528-c5bc-8e72-8e2a-1305600e9a82/Cancelled recovery")
        addTeardownBlock {
            await MainActor.run {
                let fm = FileManager.default
                app.terminate(); app.launchArguments = ["--team-editor-testing", "--team-recovery-storage-cleanup"]
                do { try self.open(app); XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("taskfold-storage-proof-journal.json").path)) }
                catch { XCTFail("Could not restore recorded draft fixture: \(error)") }
                app.terminate()
            }
        }
        let later = app.buttons[single ? "Later" : "laterTeamBatchRecovery"]
        XCTAssertTrue(later.waitForExistence(timeout: 10)); later.click()
        let admission = app.buttons["checkRecordedDraftAdmission"]; XCTAssertTrue(admission.waitForExistence(timeout: 10)); admission.click()
        XCTAssertTrue(app.staticTexts["Saved draft context protected"].waitForExistence(timeout: 12), app.debugDescription)
        app.buttons["openMacCompletionRecovery"].click()
        let before = try saved(), bytes = try Data(contentsOf: cacheFile), queue = pending(before)
        XCTAssertEqual(queue.count, preferences ? 6 : 2); XCTAssertEqual(queue[0]["teamCompletion"] != nil, single)
        let keep = app.buttons["preserveCancelledCompletionDraft"]
        XCTAssertTrue(keep.waitForExistence(timeout: 15), app.debugDescription)

        XCTAssertTrue(keep.isEnabled); shot(app, "Cancelled draft review " + scenario)
        app.buttons["blockNativeRecoveryStorage"].click(); XCTAssertTrue(app.staticTexts["Storage blocked"].waitForExistence(timeout: 8))
        if scenario == "success" || scenario == "race" {
            app.buttons["repairNativeRecoveryStorage"].click(); XCTAssertTrue(app.staticTexts["Storage available"].waitForExistence(timeout: 8))
        }

        keep.click()
        if scenario == "cache" || scenario == "vault" {
            let ok = app.windows.buttons["OK"].firstMatch
            XCTAssertTrue(ok.waitForExistence(timeout: 15), app.debugDescription)
            let durable = try Data(contentsOf: scenario == "cache" ? cacheFile.appendingPathExtension("storage-proof-held") : cacheFile)
            XCTAssertEqual(durable, bytes)
            if scenario == "cache" {
                let files = try fm.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil).filter { $0.pathExtension == "taskfoldrecovery" }
                XCTAssertEqual(files.count, 1, "Verified encrypted draft precedes retiring local work")
                let cipher = try Data(contentsOf: XCTUnwrap(files.first)); XCTAssertFalse(String(decoding: cipher, as: UTF8.self).contains("Keep these later workshop instructions"))
            } else { XCTAssertFalse(fm.fileExists(atPath: archive.appendingPathComponent("unexpected.taskfoldrecovery").path)) }
            let attemptsFile = support.appendingPathComponent("taskfold-single-cancel-attempts.json")
            let attemptsBeforeRepair = fm.fileExists(atPath: attemptsFile.path) ? try JSONSerialization.jsonObject(with: Data(contentsOf: attemptsFile)) as! [[String: Any]] : []
            XCTAssertEqual(attemptsBeforeRepair.filter { $0["request_id"] as? String == (queue[0]["id"] as! String).lowercased() }.count, scenario == "vault" ? 0 : 1, "Vault admission fails before cancellation; cache failure follows exactly one terminal response")
            shot(app, "Cancelled draft storage failure " + scenario)
            ok.click()
            app.buttons["repairNativeRecoveryStorage"].click(); XCTAssertTrue(app.staticTexts["Storage available"].waitForExistence(timeout: 8))
            XCTAssertTrue(keep.waitForExistence(timeout: 15));
            if scenario == "cache" {
                app.terminate(); app.launchArguments.removeAll { $0 == "--team-editor-reset" }
                try open(app); app.buttons["openMacCompletionRecovery"].click()
                XCTAssertEqual(canonicalRecordedDraft(try saved()), canonicalRecordedDraft(before))
                XCTAssertTrue(keep.waitForExistence(timeout: 15))
            }
            XCTAssertTrue(keep.isEnabled); keep.click()
        }
        if scenario == "race" {
            let ok = app.windows.buttons["OK"].firstMatch; XCTAssertTrue(ok.waitForExistence(timeout: 15), app.debugDescription); ok.click()
            XCTAssertEqual(try Data(contentsOf: cacheFile), bytes)
            let later = app.buttons["Later"]; XCTAssertTrue(later.waitForExistence(timeout: 10)); later.click()
        }
        XCTAssertTrue(app.buttons["openMacCompletionRecovery"].waitForExistence(timeout: 25), app.debugDescription)
        let after = try saved(); XCTAssertEqual(pending(after) as NSArray, (scenario == "race" ? queue : []) as NSArray)
        let files = try fm.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil).filter { $0.pathExtension == "taskfoldrecovery" }
        XCTAssertEqual(files.count, 1, "Retry must reuse the same complete encrypted draft")
        let encrypted = try Data(contentsOf: XCTUnwrap(files.first)); XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains("Keep these later workshop instructions"))
        let oldRows = try XCTUnwrap((before["tables"] as? [String: Any])?["tasks"] as? [[String: Any]])
        let newRows = try XCTUnwrap((after["tables"] as? [String: Any])?["tasks"] as? [[String: Any]])
        let target = try XCTUnwrap(queue[1]["recordID"] as? String)
        if scenario == "race" { XCTAssertEqual(newRows as NSArray, oldRows as NSArray) }
        else {
            let source = try XCTUnwrap((queue[0]["teamCompletion"] as? [String: Any])?["source"] as? [String: Any])
            XCTAssertEqual(newRows.first { $0["id"] as? String == target } as NSDictionary?, source as NSDictionary)
        }
        XCTAssertEqual(newRows.filter { $0["id"] as? String != target } as NSArray, oldRows.filter { $0["id"] as? String != target } as NSArray)
        let metadata = try XCTUnwrap(after["teamWorkspace"] as? [String: Any]), boundary = try XCTUnwrap(metadata["boundary"] as? [String: Any]), raw = try XCTUnwrap(boundary["raw"] as? [String: Any])
        if scenario == "race" { XCTAssertEqual(canonicalRecordedDraft(after), canonicalRecordedDraft(before)) }
        else { XCTAssertEqual((raw["projects"] as? [[String: Any]])?.first?["can_send_tasks"] as? Bool, false) }
        app.terminate(); app.launchArguments.removeAll { $0 == "--team-editor-reset" }; try open(app)
        let drafts = app.buttons["openMacSavedDrafts"]; XCTAssertTrue(drafts.waitForExistence(timeout: 15)); drafts.click()
        let item = app.buttons["savedRecordedCompletionDraft"].firstMatch; XCTAssertTrue(item.waitForExistence(timeout: 12), app.debugDescription); item.click()
        let preview = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Keep these later workshop instructions", "Keep these later workshop instructions")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 12), app.debugDescription)
        let detail = try Data(contentsOf: support.appendingPathComponent("taskfold-recorded-draft-proof.json"))
        let exported = try Data(contentsOf: support.appendingPathComponent("taskfold-recorded-export-proof.json"))
        let draft = try JSONSerialization.jsonObject(with: detail) as! [String: Any]
        XCTAssertEqual(draft["original"] as? NSDictionary, queue[0] as NSDictionary)
        XCTAssertEqual(canonicalRecordedDraft(try XCTUnwrap(draft["snapshot"] as? [String: Any])), canonicalRecordedDraft(before))
        XCTAssertEqual((draft["id"] as? String)?.lowercased(), files.first!.deletingPathExtension().lastPathComponent)
        let json = try JSONSerialization.jsonObject(with: exported) as! [String: Any]
        if preferences && scenario != "race" {
            let oldTables = before["tables"] as! [String: Any], newTables = after["tables"] as! [String: Any]
            let oldRows = try XCTUnwrap(oldTables["view_orders"] as? [[String: Any]]), newRows = try XCTUnwrap(newTables["view_orders"] as? [[String: Any]])
            XCTAssertEqual(newRows.count, 2)
            let oldIndependent = try XCTUnwrap(oldRows.first { $0["id"] as? String == "scope:inbox" }), newIndependent = try XCTUnwrap(newRows.first { $0["id"] as? String == "scope:inbox" })
            XCTAssertEqual(oldIndependent as NSDictionary, newIndependent as NSDictionary)
            let orders = queue.filter { $0["table"] as? String == "view_orders" }; XCTAssertEqual(orders.count, 4)
            let savedBefore = try XCTUnwrap((orders[0]["orderRecovery"] as? [String: Any])?["before"] as? [String: Any])
            XCTAssertEqual(newRows.first { $0["id"] as? String == "scope:today" } as NSDictionary?, savedBefore as NSDictionary)
            XCTAssertTrue(orders.allSatisfy { $0["orderRecovery"] != nil })
            let bindings = try XCTUnwrap((orders[0]["orderRecovery"] as? [String: Any])?["tasks"] as? [[String: Any]])
            let opaque = try XCTUnwrap(bindings.first { $0["id"] as? String == "ec240000-0000-4000-8000-000000000099" })
            XCTAssertNil(opaque["generation"]); XCTAssertNil(opaque["project"])
            XCTAssertFalse((newTables["tasks"] as! [[String: Any]]).contains { $0["id"] as? String == opaque["id"] as? String })

            XCTAssertEqual(Set(orders.compactMap { $0["id"] as? String }).count, 4)
            XCTAssertFalse(newRows.contains { ($0["id"] as? String)?.hasPrefix("widget-note:") == true })
            XCTAssertEqual((json["changes"] as? [[String: Any]])?.filter { $0["table"] as? String == "view_orders" } as NSArray?, orders as NSArray)
            let choices = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Pinned note choice:", "Pinned note choice:")).firstMatch
            XCTAssertTrue(choices.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(String(decoding: exported, as: UTF8.self).contains("orderRecovery"))
        }

        if mentions {
            let beforeRows = before["tables"] as! [String: Any], afterRows = after["tables"] as! [String: Any]
            let originalMarkers = try XCTUnwrap(beforeRows["_conversation_outbox"] as? [[String: Any]])
            XCTAssertEqual(originalMarkers.count, 1)
            XCTAssertEqual((originalMarkers[0]["intent"] as? [String: Any])?["kind"] as? String, "mention-read")
            XCTAssertEqual((afterRows["_conversation_outbox"] as? [[String: Any]])?.count, scenario == "race" ? originalMarkers.count : 0)
            XCTAssertEqual(json["conversations"] as? NSArray, originalMarkers as NSArray)
            XCTAssertEqual((json["conversation_context"] as? [[String: Any]])?.count, 2)
            XCTAssertTrue(String(decoding: exported, as: UTF8.self).contains("Native connected mention recovery proof"))
            let markerText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Mention marked read:", "Mention marked read:")).firstMatch
            XCTAssertTrue(markerText.waitForExistence(timeout: 10), app.debugDescription)
        }

        XCTAssertEqual(json["format"] as? String, "com.taskfold.saved-edits")
        XCTAssertEqual(draft["version"] as? Int, 2); XCTAssertEqual((draft["review"] as? [String: Any])?["state"] as? String, "unrecorded")
        XCTAssertEqual(json["version"] as? Int, 2); XCTAssertEqual(json["state"] as? String, scenario == "race" ? "unconfirmed" : "cancelled")
        let proofs = draft["cancellations"] as? [[String: Any]]
        if scenario == "race" { XCTAssertNil(proofs) } else { XCTAssertEqual(proofs?.count, 1); XCTAssertEqual(proofs?[0]["state"] as? String, "cancelled") }
        let trace = try JSONSerialization.jsonObject(with: Data(contentsOf: support.appendingPathComponent("taskfold-single-cancel-attempts.json"))) as! [[String: Any]]
        let nonce = (queue[0]["id"] as! String).lowercased(), attempts = trace.filter { $0["request_id"] as? String == nonce }
        XCTAssertEqual(attempts.count, 1, "A verified cancelled retry must not send another cancellation")
        XCTAssertEqual(attempts[0]["path"] as? String, "/rest/v1/rpc/taskfold_cancel_team_completion")
        let body = try XCTUnwrap(attempts[0]["body"] as? [String: Any]); XCTAssertEqual(body["task_id"] as? String, queue[0]["recordID"] as? String); XCTAssertNil(body["items"])
        let calls = XCTAttachment(data: try JSONSerialization.data(withJSONObject: attempts, options: [.sortedKeys]), uniformTypeIdentifier: "public.json"); calls.name = "Cancelled draft " + scenario + " actual cancellation attempts"; calls.lifetime = .keepAlways; add(calls)

        XCTAssertEqual(json["changes"] as? NSArray, queue as NSArray)
        XCTAssertNil(json["snapshot"]); XCTAssertNil(json["review"]); XCTAssertNil(json["teamWorkspace"])
        XCTAssertTrue(String(decoding: exported, as: UTF8.self).contains("Keep these later workshop instructions"))
        shot(app, "Cancelled draft retained preview " + scenario)
        let export = app.buttons["exportRecordedEdits"]
        for _ in 0..<8 where !export.isHittable { app.descendants(matching: .any)["savedRecordedEditsForm"].firstMatch.swipeUp() }
        XCTAssertTrue(export.isEnabled)
        if scenario == "success" {
            export.click()
            let cancel = app.sheets.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 12), app.debugDescription)
            let name = app.sheets.textFields.matching(NSPredicate(format: "value CONTAINS %@", "Taskfold-saved-edits")).firstMatch
            XCTAssertTrue(name.waitForExistence(timeout: 8), app.debugDescription)
            let filename = "Taskfold-recovery-" + UUID().uuidString.lowercased() + ".json"
            let destination = fm.temporaryDirectory.appendingPathComponent("taskfold-recorded-recovery-native-exports", isDirectory: true).appendingPathComponent(filename)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: destination) }
            name.click(); app.typeKey("a", modifierFlags: .command); name.typeText(filename)
            app.typeKey("g", modifierFlags: [.command, .shift])
            let path = app.sheets.textFields["PathTextField"].firstMatch
            XCTAssertTrue(path.waitForExistence(timeout: 8), app.debugDescription)
            path.click(); app.typeKey("a", modifierFlags: .command); path.typeText(destination.deletingLastPathComponent().path); app.typeKey(.return, modifierFlags: [])
            let selectedName = app.sheets.textFields.matching(NSPredicate(format: "value == %@", filename)).firstMatch
            XCTAssertTrue(selectedName.waitForExistence(timeout: 8), app.debugDescription)
            let selectedFolder = app.sheets.popUpButtons["where popup"].firstMatch
            XCTAssertTrue(selectedFolder.waitForExistence(timeout: 8), app.debugDescription)
            XCTAssertEqual(selectedFolder.value as? String, "taskfold-recorded-recovery-native-exports")
            let save = app.sheets.buttons["Save"].firstMatch.exists ? app.sheets.buttons["Save"].firstMatch : app.sheets.buttons["Export"].firstMatch
            XCTAssertTrue(save.waitForExistence(timeout: 8), app.debugDescription); XCTAssertTrue(save.isEnabled)
            shot(app, "Cancelled draft native save picker"); save.click()
            XCTAssertTrue(app.staticTexts["Details saved."].waitForExistence(timeout: 12), app.debugDescription)
            let delivery = try Data(contentsOf: destination); XCTAssertEqual(delivery, exported)
            let delivered = XCTAttachment(data: delivery, uniformTypeIdentifier: "public.json"); delivered.name = "Cancelled draft local delivery"; delivered.lifetime = .keepAlways; add(delivered)
            export.click(); XCTAssertTrue(cancel.waitForExistence(timeout: 12), app.debugDescription)
            shot(app, "Cancelled draft native export picker"); cancel.click()
            XCTAssertTrue(cancel.waitForNonExistence(timeout: 12), app.debugDescription)
            XCTAssertTrue(export.waitForExistence(timeout: 10)); XCTAssertTrue(export.isEnabled)
            XCTAssertEqual(try Data(contentsOf: destination), delivery)
            shot(app, "Cancelled draft export cancelled safely")
            XCTAssertEqual(canonicalRecordedDraft(try saved()), canonicalRecordedDraft(after), "Opening and cancelling export cannot replay saved edits")
        }
        let restarted = try saved(); XCTAssertEqual(canonicalRecordedDraft(after), canonicalRecordedDraft(restarted))
        for (phase, value) in [("before", before), ("after", after), ("relaunch", restarted), ("draft", draft), ("export", json)] {
            let proof = XCTAttachment(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            proof.name = "Cancelled draft " + scenario + " " + phase; proof.lifetime = .keepAlways; add(proof)
        }
    }
}

extension TeamCompletionRecoveryMacUITests {
    @MainActor func testSingleCancellationKeepsConnectedDraftAndExportAfterRelaunch() throws { try cancelledDraftRecovery("success") }
}

extension TeamCompletionRecoveryMacUITests {
    @MainActor func testSingleCancellationDraftCacheFailureReopensAndReusesTerminalProof() throws { try cancelledDraftRecovery("cache") }
}

extension TeamCompletionRecoveryMacUITests {
    @MainActor func testSingleCancellationDraftVaultFailureCannotRequestCancellation() throws { try cancelledDraftRecovery("vault") }
}

extension TeamCompletionRecoveryMacUITests {
    @MainActor func testSingleCancellationAlreadyRecordedRaceKeepsPreflightDraftAndQueue() throws { try cancelledDraftRecovery("race") }
}

extension TeamCompletionRecoveryMacUITests {
    @MainActor func testRecordedDraftRecoversCapturedDiscussionAfterCacheDisappears() throws { try recordedDraftRecovery("group", mentions: true, preferences: true, capturedMentions: true) }
}

extension TeamCompletionRecoveryMacUITests {
    @MainActor private func connectedProvisionalRecovery(_ scenario: String) throws {
        let app = XCUIApplication(); defer { app.terminate() }
        try launch(app, mode: "viewer", single: true, recorded: true, storage: scenario == "vault" ? "connected-copy" : "cache", recordedDraft: true, mentions: true, preferences: true, capturedMentions: true, connectedProvisional: true)
        app.buttons["openMacCompletionRecovery"].click()
        let fm = FileManager.default, support = try support()
        let cacheFile = support.appendingPathComponent("Taskfold/ec240000-0000-4000-8000-000000000001.json")
        let vault = cacheFile.deletingLastPathComponent().appendingPathComponent("Backups/d2be2d54-84e6-8f3d-8850-546d0835535a")
        let copies = vault.appendingPathComponent("Team drafts/1d019528-c5bc-8e72-8e2a-1305600e9a82")
        let archives = copies.appendingPathComponent("Recorded recovery")
        let callFile = support.appendingPathComponent("taskfold-connected-provisional-rpc-proof.json")
        if fm.fileExists(atPath: callFile.path) { try fm.removeItem(at: callFile) }
        addTeardownBlock {
            await MainActor.run {
                app.terminate(); app.launchArguments.removeAll { $0 == "--team-editor-reset" }; app.launchArguments.append("--team-recovery-storage-cleanup")
                app.launch(); app.terminate()
            }
        }
        func saved() throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: cacheFile)) as! [String: Any] }
        func calls() throws -> [[String: Any]] { fm.fileExists(atPath: callFile.path) ? try JSONSerialization.jsonObject(with: Data(contentsOf: callFile)) as! [[String: Any]] : [] }
        let before = try saved(), bytes = try Data(contentsOf: cacheFile), queue = before["pending"] as! [[String: Any]]
        XCTAssertEqual(queue.count, 6)
        let command = try XCTUnwrap(queue[0]["teamCompletion"] as? [String: Any]), proposed = try XCTUnwrap(command["proposed"] as? [String: Any])
        let target = proposed["id"] as! String, generation = proposed["task_generation"] as! String
        let keep = app.buttons["parkConnectedTeamCompletionDraft"]
        XCTAssertTrue(keep.waitForExistence(timeout: 25), app.debugDescription); XCTAssertTrue(keep.isEnabled)
        app.buttons["blockNativeRecoveryStorage"].click(); XCTAssertTrue(app.staticTexts["Storage blocked"].waitForExistence(timeout: 8))
        if scenario == "success" { app.buttons["repairNativeRecoveryStorage"].click(); XCTAssertTrue(app.staticTexts["Storage available"].waitForExistence(timeout: 8)) }
        keep.click()
        if scenario != "success" {
            let ok = app.windows.buttons["OK"].firstMatch
            XCTAssertTrue(ok.waitForExistence(timeout: 25), app.debugDescription)
            let old = try Data(contentsOf: scenario == "cache" ? cacheFile.appendingPathExtension("storage-proof-held") : cacheFile)
            XCTAssertEqual(old, bytes)
            XCTAssertEqual(try calls().count, scenario == "cache" ? 1 : 0)
            let files = try fm.contentsOfDirectory(at: archives, includingPropertiesForKeys: nil).filter { $0.pathExtension == "taskfoldrecovery" }
            XCTAssertEqual(files.count, 1, "The complete connected archive precedes the copy-vault write and retirement request")
            shot(app, "Connected provisional failure " + scenario)
            ok.click()
            app.buttons["repairNativeRecoveryStorage"].click(); XCTAssertTrue(app.staticTexts["Storage available"].waitForExistence(timeout: 8))
            if scenario == "cache" {
                app.terminate(); app.launchArguments.removeAll { $0 == "--team-editor-reset" }
                try open(app); app.buttons["openMacCompletionRecovery"].click()
                XCTAssertEqual(canonicalRecordedDraft(try saved()), canonicalRecordedDraft(before))
            }
            XCTAssertTrue(keep.waitForExistence(timeout: 25), app.debugDescription); XCTAssertTrue(keep.isEnabled); keep.click()
        }
        XCTAssertTrue(app.buttons["openMacCompletionRecovery"].waitForExistence(timeout: 30), app.debugDescription)
        let after = try saved(); XCTAssertTrue((after["pending"] as! [Any]).isEmpty)
        let observed = try calls(); XCTAssertEqual(observed.count, scenario == "cache" ? 2 : 1)
        for call in observed {
            XCTAssertEqual(call["path"] as? String, "/rest/v1/rpc/taskfold_retire_team_provisional")
            let request = try XCTUnwrap(call["body"] as? [String: Any]); XCTAssertEqual(Set(request.keys), ["_body"])
            let body = try XCTUnwrap(request["_body"] as? [String: Any]); XCTAssertEqual(body["request_id"] as? String, (queue[0]["id"] as! String).lowercased())
            XCTAssertEqual(body["planned_next_id"] as? String, target); XCTAssertEqual(body["next_generation"] as? String, generation)
        }
        let response = try XCTUnwrap(observed.last?["response"] as? [String: Any]), replacement = try XCTUnwrap(response["current_proposed"] as? [String: Any])
        let oldTables = before["tables"] as! [String: Any], newTables = after["tables"] as! [String: Any]
        let oldTasks = oldTables["tasks"] as! [[String: Any]], newTasks = newTables["tasks"] as! [[String: Any]]
        XCTAssertEqual(newTasks.first { $0["id"] as? String == target } as NSDictionary?, replacement as NSDictionary)
        XCTAssertNotEqual(replacement["task_generation"] as? String, generation)
        XCTAssertEqual(newTasks.filter { $0["id"] as? String != target } as NSArray, oldTasks.filter { $0["id"] as? String != target } as NSArray)
        XCTAssertTrue((newTables["_conversation_outbox"] as! [Any]).isEmpty)
        XCTAssertTrue((newTables["task_comments"] as? [Any])?.isEmpty == true); XCTAssertTrue((newTables["task_mentions"] as? [Any])?.isEmpty == true)
        let preferenceCommands = queue.filter { $0["table"] as? String == "view_orders" }; XCTAssertEqual(preferenceCommands.count, 4)
        let beforeOrder = (preferenceCommands[0]["orderRecovery"] as! [String: Any])["before"] as! [String: Any]
        let orders = newTables["view_orders"] as! [[String: Any]]
        XCTAssertEqual(orders.first { $0["id"] as? String == "scope:today" } as NSDictionary?, beforeOrder as NSDictionary)
        XCTAssertFalse(orders.contains { ($0["id"] as? String)?.hasPrefix("widget-note:") == true })
        let oldIndependent = (oldTables["view_orders"] as! [[String: Any]]).first { $0["id"] as? String == "scope:inbox" }
        XCTAssertEqual(orders.first { $0["id"] as? String == "scope:inbox" } as NSDictionary?, oldIndependent as NSDictionary?)
        let copyFiles = try fm.contentsOfDirectory(at: copies, includingPropertiesForKeys: nil).filter { $0.pathExtension == "taskfolddraft" }
        let archiveFiles = try fm.contentsOfDirectory(at: archives, includingPropertiesForKeys: nil).filter { $0.pathExtension == "taskfoldrecovery" }
        XCTAssertEqual(copyFiles.count, 1); XCTAssertEqual(archiveFiles.count, 1)
        XCTAssertFalse(String(decoding: try Data(contentsOf: copyFiles[0]), as: UTF8.self).contains("Connected recurring draft"))
        XCTAssertFalse(String(decoding: try Data(contentsOf: archiveFiles[0]), as: UTF8.self).contains("Native connected mention recovery proof"))
        app.terminate(); app.launchArguments.removeAll { $0 == "--team-editor-reset" }; try open(app)
        let drafts = app.buttons["openMacSavedDrafts"]
        XCTAssertTrue(drafts.waitForExistence(timeout: 15)); drafts.click()
        let item = app.buttons["savedProvisionalTaskDraft"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 15), app.debugDescription); item.click()
        let copy = try JSONSerialization.jsonObject(with: Data(contentsOf: support.appendingPathComponent("taskfold-connected-provisional-copy-proof.json"))) as! [String: Any]
        XCTAssertEqual((copy["id"] as! String).lowercased(), copyFiles[0].deletingPathExtension().lastPathComponent)
        XCTAssertEqual((copy["connectedRecoveryIDs"] as? [String])?.map { $0.lowercased() }, [archiveFiles[0].deletingPathExtension().lastPathComponent])
        XCTAssertEqual(copy["original"] as? NSDictionary, queue[0] as NSDictionary); XCTAssertNil(copy["copyAttempt"])
        let record = try XCTUnwrap(copy["record"] as? [String: Any]); XCTAssertEqual(record["id"] as? String, target); XCTAssertEqual(record["task_generation"] as? String, generation)
        XCTAssertEqual(record["title"] as? String, "Connected recurring draft"); XCTAssertEqual(record["description"] as? String, "Keep the connected recurring instructions")
        XCTAssertTrue(app.buttons["reviewSavedTeamDraftCopy"].exists, "The explicit task-copy workflow stays available")
        let related = app.buttons["reviewConnectedProvisionalEdits"]

        XCTAssertTrue(related.waitForExistence(timeout: 15), app.debugDescription); related.click()
        let preview = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Provisional task retired", "Provisional task retired")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 15), app.debugDescription)
        let archive = try JSONSerialization.jsonObject(with: Data(contentsOf: support.appendingPathComponent("taskfold-recorded-draft-proof.json"))) as! [String: Any]
        let data = try Data(contentsOf: support.appendingPathComponent("taskfold-recorded-export-proof.json")), exported = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(canonicalRecordedDraft(archive["snapshot"] as! [String: Any]), canonicalRecordedDraft(before))
        XCTAssertEqual((archive["id"] as! String).lowercased(), archiveFiles[0].deletingPathExtension().lastPathComponent)
        let proofs = archive["provisionalRetirements"] as! [[String: Any]]; XCTAssertEqual(proofs.count, 1); XCTAssertEqual(proofs[0] as NSDictionary, response as NSDictionary)
        XCTAssertEqual(exported["changes"] as? NSArray, queue as NSArray)
        XCTAssertEqual(exported["conversations"] as? NSArray, oldTables["_conversation_outbox"] as? NSArray)
        XCTAssertEqual((exported["conversation_context"] as? [Any])?.count, 2)
        XCTAssertNil(exported["provisionalRetirements"]); XCTAssertNil(exported["snapshot"]); XCTAssertNil(exported["review"])
        shot(app, "Connected provisional saved edits " + scenario)
        let export = app.buttons["exportRecordedEdits"]
        for _ in 0..<8 where !export.isHittable { app.descendants(matching: .any)["savedRecordedEditsForm"].firstMatch.swipeUp() }
        XCTAssertTrue(export.isEnabled)

        XCTAssertEqual(canonicalRecordedDraft(try saved()), canonicalRecordedDraft(after))
        let values: [String: Any] = ["before": before, "after": after, "relaunch": try saved(), "copy": copy, "archive": archive, "export": exported, "actualRetirementRequests": observed]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "Connected provisional " + scenario + " complete proof"; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testConnectedProvisionalDraftKeepsCopyAndLinkedEditsAfterRelaunch() throws { try connectedProvisionalRecovery("success") }
    @MainActor func testConnectedProvisionalCopyVaultFailureKeepsQueueBeforeRetirement() throws { try connectedProvisionalRecovery("vault") }
    @MainActor func testConnectedProvisionalCacheFailureReopensSameLinkedDrafts() throws { try connectedProvisionalRecovery("cache") }
}


extension TaskfoldMacUITests {
    @MainActor func testTodoistHeadingReviewAvailabilityAndTypedRetry() throws {
        guard ["com.dbakp.taskfold.mac.workflowteststeameditbridge.runner.xctrunner", "com.dbakp.taskfold.mac.workflowteststeameditbridge.runner"].contains(Bundle.main.bundleIdentifier ?? "") else { throw XCTSkip("Reserved isolated Mac heading host required") }
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--workflow-fixture", "--todoist-import-testing", "-localMode", "YES"]; app.launch(); defer { app.terminate() }
        app.menuBars.menuBarItems["Account"].click(); app.menuItems["Import from Todoist…"].click()
        let field = app.secureTextFields["todoistToken"]; XCTAssertTrue(field.waitForExistence(timeout: 8))
        let window = app.windows.containing(.secureTextField, identifier: "todoistToken").firstMatch
        func reveal(_ control: XCUIElement, top: Bool = false) {
            for _ in 0..<12 where !control.isHittable { window.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: top ? 400 : -400) }
            XCTAssertTrue(control.exists && control.isHittable, app.debugDescription)
        }
        field.click(); field.typeText("fixture-heading-blocked-token"); app.buttons["todoistPreview"].click()
        let count = app.descendants(matching: .any)["todoistHeadingCount"].firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 6)); XCTAssertEqual(count.value as? String, "2")
        let save = app.buttons["todoistImport"]; reveal(save); XCTAssertFalse(save.isEnabled)
        let blocked = XCTAttachment(screenshot: window.screenshot()); blocked.name = "Mac Todoist headings unavailable with source retained"; blocked.lifetime = .keepAlways; add(blocked)
        let clear = app.buttons["todoistClearToken"]; reveal(clear, top: true); clear.click(); reveal(field, top: true); field.click(); field.typeText("fixture-heading-ready-token"); app.buttons["todoistPreview"].click()
        XCTAssertTrue(count.waitForExistence(timeout: 6)); reveal(save); XCTAssertTrue(save.isEnabled); save.click()
        let failure = app.staticTexts["todoistImportError"]; XCTAssertTrue(failure.waitForExistence(timeout: 6)); reveal(save); XCTAssertTrue(save.isEnabled); save.click()
        let receipt = app.descendants(matching: .any)["todoistReceipt-tasksSkipped"].firstMatch
        XCTAssertTrue(receipt.waitForExistence(timeout: 6)); XCTAssertFalse(save.exists)
        let confirmed = XCTAttachment(screenshot: window.screenshot()); confirmed.name = "Mac typed Todoist receipt after safe retry"; confirmed.lifetime = .keepAlways; add(confirmed)
    }
}

extension TaskfoldMacUITests {
    @MainActor func testWorkflowCSVClipboardReviewCancelSaveAndColdReturn() throws {
        guard ["com.dbakp.taskfold.mac.workflowteststeameditbridge.runner.xctrunner", "com.dbakp.taskfold.mac.workflowteststeameditbridge.runner"].contains(Bundle.main.bundleIdentifier ?? "") else { throw XCTSkip("Reserved isolated host required") }
        continueAfterFailure = false
        let board = NSPasteboard.general
        let previous = board.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } } ?? []
        var copiedChange: Int?
        defer { if let copiedChange, board.changeCount == copiedChange { board.clearContents(); let items = previous.map { values in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item }; if !items.isEmpty { board.writeObjects(items) } } }
        let app = XCUIApplication(); defer { app.terminate() }
        app.launchArguments = ["--uitesting", "--workflow-fixture", "--task-heading-fixture", "--subtask-organizer-fixture", "--heading-portability-template-fixture", "-localMode", "YES"]
        try launchHeadingWorkspace(app)
        let cacheURL = URL(fileURLWithPath: "/Users/" + NSUserName() + "/Library/Containers/com.dbakp.taskfold.mac.workflowteststeameditbridge/Data/Library/Application Support/Taskfold/ui-testing.json")
        func tables() throws -> [String: Any] { try XCTUnwrap((JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])?["tables"] as? [String: Any]) }
        XCTAssertTrue(app.buttons["openTemplates"].waitForExistence(timeout: 15), app.debugDescription)
        let before = try tables()
        app.buttons["openTemplates"].click()

        func reveal(_ control: XCUIElement) {
            for _ in 0..<15 where !control.isHittable {
                let sheets = app.sheets
                let surface = sheets.count > 0 ? sheets.element(boundBy: sheets.count - 1) : app.windows.firstMatch
                surface.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -350)
            }
            XCTAssertTrue(control.exists && control.isHittable, app.debugDescription)
        }
        let template = app.buttons["workflowTemplate-f2810000-0000-4000-8000-000000000003"]
        XCTAssertTrue(template.waitForExistence(timeout: 8), app.debugDescription)

        template.rightClick(); app.menuItems["Export template…"].click()
        let toggle = app.switches["templateCSVFormat"]
        reveal(toggle); toggle.click()
        reveal(app.buttons["copyTemplateText"]); app.buttons["copyTemplateText"].click(); copiedChange = board.changeCount
        XCTAssertTrue(board.string(forType: .string)?.hasPrefix("\"format\"") == true)
        reveal(app.buttons["Cancel"].firstMatch); app.buttons["Cancel"].firstMatch.click()
        app.buttons["importWorkflowText"].click()
        let text = app.textViews["templateImportText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5)); text.click(); text.typeKey("v", modifierFlags: .command)
        reveal(app.buttons["reviewTemplateText"]); app.buttons["reviewTemplateText"].click()
        let save = app.buttons["confirmImportTemplate"]
        reveal(save)
        reveal(app.buttons["editTemplateText"]); app.buttons["editTemplateText"].click()
        XCTAssertTrue(text.waitForExistence(timeout: 5)); XCTAssertTrue((text.value as? String)?.contains("task_headings") == true)
        reveal(app.buttons["reviewTemplateText"]); app.buttons["reviewTemplateText"].click(); reveal(save)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = "Mac CSV pasted workflow review before Save"; shot.lifetime = .keepAlways; add(shot)
        reveal(app.buttons["Cancel"].firstMatch); app.buttons["Cancel"].firstMatch.click()
        XCTAssertEqual(try tables()["project_templates"] as? NSArray, before["project_templates"] as? NSArray)
        app.buttons["importWorkflowText"].click(); XCTAssertTrue(text.waitForExistence(timeout: 5)); text.click(); text.typeKey("v", modifierFlags: .command)
        reveal(app.buttons["reviewTemplateText"]); app.buttons["reviewTemplateText"].click(); reveal(save); save.click()
        XCTAssertTrue(app.buttons["importWorkflowText"].waitForExistence(timeout: 8))
        let after = try tables(), definitions = try XCTUnwrap(after["project_templates"] as? [[String: Any]])
        XCTAssertEqual(definitions.count, 2); XCTAssertEqual(after["tasks"] as? NSArray, before["tasks"] as? NSArray)
        let source = try XCTUnwrap((before["project_templates"] as? [[String: Any]])?.first)
        let imported = try XCTUnwrap(definitions.first { $0["id"] as? String != source["id"] as? String })
        XCTAssertEqual((imported["document"] as? [String: Any])?["version"] as? Int, 2)
        app.terminate(); app.launchArguments = ["--uitesting", "-localMode", "YES"]; try launchHeadingWorkspace(app); XCTAssertTrue(app.buttons["openTemplates"].waitForExistence(timeout: 15), app.debugDescription); app.buttons["openTemplates"].click()
        XCTAssertTrue(app.buttons["workflowTemplate-" + (imported["id"] as! String)].waitForExistence(timeout: 8))
        XCTAssertEqual(try tables()["tasks"] as? NSArray, before["tasks"] as? NSArray)
    }
}


extension TaskfoldMacUITests {
    @MainActor func testHeadingProjectWorkCountsExactChildAndColdReturn() throws {
        guard ["com.dbakp.taskfold.mac.workflowteststeameditbridge.runner.xctrunner", "com.dbakp.taskfold.mac.workflowteststeameditbridge.runner"].contains(Bundle.main.bundleIdentifier ?? "") else { throw XCTSkip("Reserved isolated host required") }
        continueAfterFailure = false
        let app = XCUIApplication(); defer { app.terminate() }
        app.launchArguments = ["--uitesting", "--workflow-fixture", "--task-heading-fixture", "--heading-progress-fixture", "-localMode", "YES"]
        try launchHeadingWorkspace(app)
        func pulse(_ expected: String = "1 of 3 completed") {
            XCTAssertTrue(app.buttons["openProjectPulse"].waitForExistence(timeout: 15), app.debugDescription)
            app.buttons["openProjectPulse"].click()
            let picker = app.descendants(matching: .any).matching(identifier: "pulseProjectPicker").firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.click(); picker.menuItems["Launch lab"].click()
            XCTAssertTrue(app.staticTexts["pulseProgress"].waitForExistence(timeout: 5)); XCTAssertEqual(renderedText(app.staticTexts["pulseProgress"]), expected)
        }
        pulse()
        let attention = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pulseAttention-")).firstMatch
        for _ in 0..<10 where !attention.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -350) }
        XCTAssertTrue(attention.isHittable); attention.click()
        let title = app.descendants(matching: .any)["taskTitle"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8)); XCTAssertEqual(title.value as? String, "Draft the launch note")
        retainWindow(app, name: "Mac project attention opens exact ordinary child under heading")
        let cache = URL(fileURLWithPath: "/Users/" + NSUserName() + "/Library/Containers/com.dbakp.taskfold.mac.workflowteststeameditbridge/Data/Library/Application Support/Taskfold/ui-testing.json")
        func savedRoot() throws -> [String: Any] {
            let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
            return try XCTUnwrap(((document["tables"] as? [String: Any])?["tasks"] as? [[String: Any]])?.first { $0["id"] as? String == "f1810000-0000-4000-8000-000000000001" })
        }
        let original = try savedRoot()
        func waitCompleted(_ value: Bool) {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let root = try? savedRoot(), let children = root["subtasks"] as? [[String: Any]] else { return false }
                return children.first?["completed"] as? Bool == value && root["is_heading"] as? Bool == true && root["completed"] as? Bool == false
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        }
        let child = "subtask:" + (try JSONEncoder().encode(["f1810000-0000-4000-8000-000000000001", "f5810000-0000-4000-8000-000000000001"])).base64EncodedString()
        let complete = app.buttons["complete-" + child]; XCTAssertTrue(complete.waitForExistence(timeout: 5)); complete.click(); waitCompleted(true)
        app.typeKey("z", modifierFlags: .command); waitCompleted(false)
        app.typeKey("z", modifierFlags: [.command, .shift]); waitCompleted(true)
        let completed = try savedRoot(); XCTAssertEqual(completed["description"] as? String, original["description"] as? String)
        let children = try XCTUnwrap(completed["subtasks"] as? [[String: Any]])
        XCTAssertEqual(children[2]["is_heading"] as? Bool, true)
        pulse("2 of 3 completed"); retainWindow(app, name: "Mac heading child completion Undo Redo updates project totals")
        app.terminate(); app.launchArguments = ["--uitesting", "-localMode", "YES"]; try launchHeadingWorkspace(app); pulse("2 of 3 completed")
        XCTAssertEqual(try savedRoot() as NSDictionary, completed as NSDictionary)
    }
}


extension TaskfoldMacUITests {
    /// Match Finder/Dock opening the already-started isolated process. XCTest
    /// launch alone may restore no visible workspace window after a force quit.
    @MainActor private func launchHeadingWorkspace(_ app: XCUIApplication) throws {
        app.launch()
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: "com.dbakp.taskfold.mac.workflowteststeameditbridge")
        XCTAssertEqual(instances.count, 1)
        let url = try XCTUnwrap(instances.first?.bundleURL)
        let opened = expectation(description: "Open isolated heading workspace")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true; configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            XCTAssertNil(error); opened.fulfill()
        }
        wait(for: [opened], timeout: 10)
        app.activate()
    }
}

extension TaskfoldMacUITests {
    @MainActor func testWorkflowCSVNativeFileSaveImportReviewAndCancel() throws {
        guard ["com.dbakp.taskfold.mac.workflowteststeameditbridge.runner.xctrunner", "com.dbakp.taskfold.mac.workflowteststeameditbridge.runner"].contains(Bundle.main.bundleIdentifier ?? "") else { throw XCTSkip("Reserved isolated host required") }
        continueAfterFailure = false
        let app = XCUIApplication(); defer { app.terminate() }
        app.launchArguments = ["--uitesting", "--workflow-fixture", "--task-heading-fixture", "--subtask-organizer-fixture", "--heading-portability-template-fixture", "-localMode", "YES"]
        try launchHeadingWorkspace(app)
        let cache = URL(fileURLWithPath: "/Users/" + NSUserName() + "/Library/Containers/com.dbakp.taskfold.mac.workflowteststeameditbridge/Data/Library/Application Support/Taskfold/ui-testing.json")
        func tables() throws -> NSDictionary { try XCTUnwrap((JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? NSDictionary)?["tables"] as? NSDictionary) }
        func front() -> XCUIElement { let sheets = app.sheets; return sheets.count > 0 ? sheets.element(boundBy: sheets.count - 1) : app.windows.firstMatch }
        func reveal(_ control: XCUIElement) {
            for _ in 0..<15 where !control.isHittable { front().scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -350) }
            XCTAssertTrue(control.exists && control.isHittable, app.debugDescription)
        }
        XCTAssertTrue(app.buttons["openTemplates"].waitForExistence(timeout: 15)); let before = try tables()
        app.buttons["openTemplates"].click()
        let template = app.buttons["workflowTemplate-f2810000-0000-4000-8000-000000000003"]
        XCTAssertTrue(template.waitForExistence(timeout: 8)); template.rightClick(); app.menuItems["Export template…"].click()
        let format = app.switches["templateCSVFormat"]; reveal(format); format.click()
        let saveFile = app.buttons["saveTemplateFile"]; reveal(saveFile); saveFile.click()
        let filename = "taskfold-mac-native-csv-" + UUID().uuidString.lowercased() + ".csv"
        let file = URL(fileURLWithPath: "/tmp").appendingPathComponent(filename)
        let save = app.sheets["save-panel"].buttons["OKButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), app.debugDescription)
        let name = app.sheets["save-panel"].textFields["saveAsNameTextField"]; XCTAssertTrue(name.exists, app.debugDescription)
        name.click(); name.typeKey("a", modifierFlags: .command); name.typeText(filename)
        func goTo(_ path: String) {
            app.typeKey("g", modifierFlags: [.command, .shift])
            let field = front().textFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
            field.click(); field.typeKey("a", modifierFlags: .command); field.typeText(path); field.typeKey(.return, modifierFlags: [])
        }
        goTo("/tmp"); save.click()
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: file.path) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 10), .completed)
        let bytes = try Data(contentsOf: file), csv = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(csv.hasPrefix("\"format\",\"document_version\"")); XCTAssertTrue(csv.contains("task_headings")); XCTAssertFalse(csv.contains("f1810000-0000-4000-8000-000000000001"))
        let proof = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.comma-separated-values-text"); proof.name = "Actual native CSV export"; proof.lifetime = .keepAlways; add(proof)
        let importFile = app.buttons["importWorkflowTemplate"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == YES"), object: importFile)], timeout: 10), .completed)
        importFile.click(); goTo(file.path)
        let open = app.sheets["open-panel"].buttons["OKButton"]
        if open.waitForExistence(timeout: 3) { open.click() }
        let confirm = app.buttons["confirmImportTemplate"]; reveal(confirm)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "2 headings", "2 headings")).firstMatch.exists)
        let image = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); image.name = "Mac actual CSV file import review"; image.lifetime = .keepAlways; add(image)
        let cancel = front().buttons["Cancel"].firstMatch; reveal(cancel); cancel.click()
        XCTAssertEqual(try tables(), before)
    }
}

extension TaskfoldMacUITests {
    @MainActor func testHeadingPlannerChildScheduleUndoCompleteAndColdReturn() throws {
        guard ["com.dbakp.taskfold.mac.workflowteststeameditbridge.runner.xctrunner", "com.dbakp.taskfold.mac.workflowteststeameditbridge.runner"].contains(Bundle.main.bundleIdentifier ?? "") else { throw XCTSkip("Reserved isolated host required") }
        continueAfterFailure = false
        let app = XCUIApplication(); defer { app.terminate() }
        app.launchArguments = ["--uitesting", "--workflow-fixture", "--task-heading-fixture", "--heading-progress-fixture", "--heading-planner-fixture", "--section=calendar", "--calendar-mode=day", "-localMode", "YES"]
        try launchHeadingWorkspace(app)
        let calendar = app.buttons["Calendar"].firstMatch
        XCTAssertTrue(calendar.waitForExistence(timeout: 15)); calendar.click()
        let cache = URL(fileURLWithPath: "/Users/" + NSUserName() + "/Library/Containers/com.dbakp.taskfold.mac.workflowteststeameditbridge/Data/Library/Application Support/Taskfold/ui-testing.json")
        func root() throws -> NSDictionary {
            let data = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
            return try XCTUnwrap(((data["tables"] as? [String: Any])?["tasks"] as? [NSDictionary])?.first { $0["id"] as? String == "f1810000-0000-4000-8000-000000000001" })
        }
        func capacity(_ expected: String) {
            let text = app.staticTexts["plannerCapacity"]; XCTAssertTrue(text.waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertEqual(renderedText(text), expected)
        }
        capacity("75 min estimated · 0 without estimates"); let original = try root()
        let child = "subtask:" + (try JSONEncoder().encode(["f1810000-0000-4000-8000-000000000001", "f5810000-0000-4000-8000-000000000001"])).base64EncodedString()
        let schedule = app.buttons.matching(NSPredicate(format: "identifier == %@", "plannerAllDay-" + child)).firstMatch
        app.buttons["plannerShowAllDay"].click(); XCTAssertTrue(schedule.waitForExistence(timeout: 5)); schedule.click()
        let estimate = app.textFields["plannerEstimate"]; XCTAssertTrue(estimate.waitForExistence(timeout: 5)); XCTAssertEqual(estimate.value as? String, "45")
        app.buttons["Cancel"].firstMatch.click(); XCTAssertEqual(try root(), original)
        schedule.click(); XCTAssertTrue(estimate.waitForExistence(timeout: 5)); estimate.click(); estimate.typeKey("a", modifierFlags: .command); estimate.typeText("60")
        app.buttons["plannerSave"].click(); capacity("90 min estimated · 0 without estimates")
        let changed = try root(), children = try XCTUnwrap(changed["subtasks"] as? [[String: Any]])
        XCTAssertEqual(children[0]["duration_minutes"] as? Int, 60); XCTAssertNil(children[0]["project_id"])
        XCTAssertEqual(changed["is_heading"] as? Bool, true); XCTAssertEqual(changed["duration_minutes"] as? Int, 999)
        app.buttons["plannerUndo"].click(); capacity("75 min estimated · 0 without estimates")
        app.buttons["plannerShowAllDay"].click(); retainWindow(app, name: "Mac grouped work capacity and heading context")
        let complete = app.buttons.matching(NSPredicate(format: "identifier == %@", "plannerComplete-" + child)).firstMatch; XCTAssertTrue(complete.waitForExistence(timeout: 5)); complete.click()
        capacity("30 min estimated · 0 without estimates")
        let completed = try root(); XCTAssertEqual((completed["subtasks"] as? [[String: Any]])?[0]["completed"] as? Bool, true); XCTAssertEqual(completed["completed"] as? Bool, false)
        app.terminate(); app.launchArguments = ["--uitesting", "--section=calendar", "--calendar-mode=day", "-localMode", "YES"]; try launchHeadingWorkspace(app)
        capacity("30 min estimated · 0 without estimates"); XCTAssertEqual(try root(), completed)
    }
}

extension TaskfoldMacUITests {
    @MainActor func testHeadingTodayChildDetailsCompletionUndoAndColdReturn() throws {
        guard ["com.dbakp.taskfold.mac.workflowteststeameditbridge.runner.xctrunner","com.dbakp.taskfold.mac.workflowteststeameditbridge.runner"].contains(Bundle.main.bundleIdentifier ?? "") else { throw XCTSkip("Reserved isolated host required") }
        continueAfterFailure=false
        let app=XCUIApplication();defer{app.terminate()}
        app.launchArguments=["--uitesting","--workflow-fixture","--task-heading-fixture","--heading-progress-fixture","--heading-planner-fixture","-localMode","YES"]
        try launchHeadingWorkspace(app)
        let cache=URL(fileURLWithPath:"/Users/"+NSUserName()+"/Library/Containers/com.dbakp.taskfold.mac.workflowteststeameditbridge/Data/Library/Application Support/Taskfold/ui-testing.json")
        func root() throws -> NSDictionary {
            let data=try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as? [String:Any])
            return try XCTUnwrap(((data["tables"] as? [String:Any])?["tasks"] as? [NSDictionary])?.first{$0["id"] as? String == "f1810000-0000-4000-8000-000000000001"})
        }
        func waitChild(_ key:String,_ expected:AnyHashable) {
            let ready=XCTNSPredicateExpectation(predicate:NSPredicate{_,_ in guard let row=try? root(), let children=row["subtasks"] as? [[String:Any]] else{return false}; return children.first?[key] as? AnyHashable == expected},object:nil)
            XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:8),.completed)
        }
        let today=app.buttons["Today"].firstMatch;XCTAssertTrue(today.waitForExistence(timeout:15));today.click()
        let child="subtask:" + (try JSONEncoder().encode(["f1810000-0000-4000-8000-000000000001","f5810000-0000-4000-8000-000000000001"])).base64EncodedString()
        let title=app.staticTexts.matching(NSPredicate(format:"identifier == %@","title-" + child)).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout:10));title.click()
        let field=app.descendants(matching:.any).matching(identifier:"taskTitle").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout:8));XCTAssertEqual(field.value as? String,"Draft the launch note")
        retainWindow(app,name:"Mac Today heading child and exact inspector")
        field.click();field.typeKey("a",modifierFlags:.command);field.typeText("Revised launch note");field.typeKey(.tab,modifierFlags:[]);waitChild("title","Revised launch note")
        let complete=app.buttons.matching(NSPredicate(format:"identifier == %@","complete-" + child)).firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout:5));complete.click()
        waitChild("completed",true);XCTAssertEqual(try root()["completed"] as? Bool,false)
        app.typeKey("z",modifierFlags:.command);waitChild("completed",false);XCTAssertTrue(title.waitForExistence(timeout:8));let restored=try root()
        app.terminate();app.launchArguments=["--uitesting","--section=today","-localMode","YES"];try launchHeadingWorkspace(app)
        XCTAssertTrue(title.waitForExistence(timeout:10));XCTAssertEqual(try root(),restored);app.buttons["Upcoming"].firstMatch.click();XCTAssertTrue(title.waitForExistence(timeout:8))
    }
}

extension TaskfoldMacUITests {
    @MainActor func testHeadingInboxGroupMoveReviewCancelUndoAndColdReturn() throws {
        guard ["com.dbakp.taskfold.mac.workflowteststeameditbridge.runner.xctrunner","com.dbakp.taskfold.mac.workflowteststeameditbridge.runner"].contains(Bundle.main.bundleIdentifier ?? "") else {throw XCTSkip("Reserved isolated host required")}
        continueAfterFailure=false
        let app=XCUIApplication();defer{app.terminate()}
        app.launchArguments=["--uitesting","--workflow-fixture","--task-heading-fixture","--heading-progress-fixture","--heading-planner-fixture","--heading-inbox-work-fixture","--widget-action-testing","--inbox-review-testing","-localMode","YES"]
        try launchHeadingWorkspace(app)
        let cache=URL(fileURLWithPath:"/Users/"+NSUserName()+"/Library/Containers/com.dbakp.taskfold.mac.workflowteststeameditbridge/Data/Library/Application Support/Taskfold/ui-testing.json")
        func root() throws -> NSDictionary {let data=try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as? [String:Any]);return try XCTUnwrap(((data["tables"] as? [String:Any])?["tasks"] as? [NSDictionary])?.first{$0["id"] as? String == "f1810000-0000-4000-8000-000000000001"})}
        let projection=app.staticTexts["inboxProjection"];XCTAssertTrue(projection.waitForExistence(timeout:15));XCTAssertEqual(renderedText(projection),"Inbox: 2");let original=try root()
        app.buttons["reviewInbox"].click();XCTAssertTrue(app.staticTexts["inboxReviewTitle"].waitForExistence(timeout:8));XCTAssertEqual(renderedText(app.staticTexts["inboxReviewTitle"]),"Draft the launch note")
        func chooseProject(){app.buttons["inboxReviewMove"].click();let target=app.descendants(matching:.any).matching(identifier:"inboxReviewProject-f0742000-1111-4111-8111-000000000001").firstMatch;XCTAssertTrue(target.waitForExistence(timeout:5));target.click();XCTAssertTrue(app.staticTexts["inboxHeadingMoveSummary"].waitForExistence(timeout:5))}
        chooseProject();retainWindow(app,name:"Mac Inbox whole-heading move review");app.buttons["inboxHeadingMoveCancel"].click();XCTAssertEqual(try root(),original)
        chooseProject();app.buttons["inboxHeadingMoveConfirm"].click();XCTAssertTrue(app.staticTexts["inboxReviewSummary"].waitForExistence(timeout:8));XCTAssertEqual(try root()["project_id"] as? String,"f0742000-1111-4111-8111-000000000001")
        app.buttons["inboxReviewUndo"].click();XCTAssertTrue(app.staticTexts["inboxReviewTitle"].waitForExistence(timeout:8));XCTAssertEqual((try root())["subtasks"] as? NSArray,original["subtasks"] as? NSArray)
        app.buttons["inboxReviewComplete"].click();XCTAssertTrue(app.staticTexts["inboxReviewTitle"].waitForExistence(timeout:5));XCTAssertEqual(renderedText(app.staticTexts["inboxReviewTitle"]),"Check the layout");let saved=try root()
        app.terminate();app.launchArguments=["--uitesting","--widget-action-testing","--inbox-review-testing","--section=inbox","-localMode","YES"];try launchHeadingWorkspace(app)
        XCTAssertTrue(projection.waitForExistence(timeout:15));XCTAssertEqual(renderedText(projection),"Inbox: 1");XCTAssertEqual(try root(),saved)
    }
}

extension TaskfoldMacUITests {
    @MainActor func testHeadingProjectLabelFilterCompletionUndoAndColdReturn() throws {
        guard ["com.dbakp.taskfold.mac.workflowteststeameditbridge.runner.xctrunner","com.dbakp.taskfold.mac.workflowteststeameditbridge.runner"].contains(Bundle.main.bundleIdentifier ?? "") else { throw XCTSkip("Reserved isolated host required") }
        continueAfterFailure=false
        let app=XCUIApplication();defer{app.terminate()}
        app.launchArguments=["--uitesting","--workflow-fixture","--task-heading-fixture","--heading-progress-fixture","--heading-planner-fixture","--heading-list-work-fixture","-localMode","YES"]
        try launchHeadingWorkspace(app)
        let cache=URL(fileURLWithPath:"/Users/"+NSUserName()+"/Library/Containers/com.dbakp.taskfold.mac.workflowteststeameditbridge/Data/Library/Application Support/Taskfold/ui-testing.json")
        func root() throws -> NSDictionary {let data=try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as? [String:Any]);return try XCTUnwrap(((data["tables"] as? [String:Any])?["tasks"] as? [NSDictionary])?.first{$0["id"] as? String == "f1810000-0000-4000-8000-000000000001"})}
        let child="subtask:"+(try JSONEncoder().encode(["f1810000-0000-4000-8000-000000000001","f5810000-0000-4000-8000-000000000001"])).base64EncodedString()
        let title=app.staticTexts.matching(NSPredicate(format:"identifier == %@","title-"+child)).firstMatch
        func choose(_ name:String){let row=app.staticTexts.matching(NSPredicate(format:"value == %@ OR label == %@",name,name)).firstMatch;XCTAssertTrue(row.waitForExistence(timeout:8));row.click()}
        choose("Launch lab");XCTAssertTrue(title.waitForExistence(timeout:8));retainWindow(app,name:"Mac project independent heading work")
        choose("Design work");XCTAssertTrue(title.waitForExistence(timeout:8));retainWindow(app,name:"Mac label own child metadata")
        choose("Priority work");XCTAssertTrue(title.waitForExistence(timeout:8));retainWindow(app,name:"Mac default saved filter child priority")
        let complete=app.buttons.matching(NSPredicate(format:"identifier == %@","complete-"+child)).firstMatch;XCTAssertTrue(complete.waitForExistence(timeout:5));complete.click()
        func state(_ expected:Bool){let ready=XCTNSPredicateExpectation(predicate:NSPredicate{_,_ in guard let row=try? root(),let children=row["subtasks"] as? [[String:Any]] else{return false};return children.first?["completed"] as? Bool == expected},object:nil);XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:8),.completed)}
        state(true);app.typeKey("z",modifierFlags:.command);state(false);XCTAssertTrue(title.waitForExistence(timeout:8));app.typeKey("z",modifierFlags:[.command,.shift]);state(true);let saved=try root();XCTAssertEqual(saved["completed"] as? Bool,false)
        app.terminate();app.launchArguments=["--uitesting","-localMode","YES"];try launchHeadingWorkspace(app)
        choose("Design work");XCTAssertFalse(title.waitForExistence(timeout:3));choose("Completed");XCTAssertTrue(title.waitForExistence(timeout:8));XCTAssertEqual(try root(),saved)
        let cacheValue = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
        let history = try XCTUnwrap((cacheValue["tables"] as? [String: Any])?["task_node_activity"] as? [[String: Any]])
        let childEvents = history.filter { $0["node_key"] as? String == "f5810000-0000-4000-8000-000000000001" }
        XCTAssertEqual(childEvents.suffix(3).compactMap { ($0["kinds"] as? [String])?.first }, ["completed", "reopened", "completed"])
        XCTAssertTrue(childEvents.allSatisfy { $0["work_before"] as? Bool == true && $0["work_after"] as? Bool == true })
        XCTAssertEqual(Set(childEvents.compactMap { $0["id"] as? String }).count, childEvents.count)

    }
}


extension TaskfoldMacUITests {
    @MainActor func testSourceCSVFileMappingReviewCancelSaveAndColdReturn() throws {
        guard ["com.dbakp.taskfold.mac.workflowteststeameditbridge.runner.xctrunner", "com.dbakp.taskfold.mac.workflowteststeameditbridge.runner"].contains(Bundle.main.bundleIdentifier ?? "") else { throw XCTSkip("Reserved isolated host required") }
        continueAfterFailure = false
        let app = XCUIApplication(); defer { app.terminate() }
        app.launchArguments = ["--uitesting", "--workflow-fixture", "--task-heading-fixture", "--subtask-organizer-fixture", "--heading-portability-template-fixture", "-localMode", "YES"]
        try launchHeadingWorkspace(app)
        let cache = URL(fileURLWithPath: "/Users/" + NSUserName() + "/Library/Containers/com.dbakp.taskfold.mac.workflowteststeameditbridge/Data/Library/Application Support/Taskfold/ui-testing.json")
        func tables() throws -> NSDictionary { try XCTUnwrap((JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? NSDictionary)?["tables"] as? NSDictionary) }
        func front() -> XCUIElement { app.sheets.count > 0 ? app.sheets.element(boundBy: app.sheets.count - 1) : app.windows.firstMatch }
        func reveal(_ control: XCUIElement) {
            for _ in 0..<15 where !control.isHittable { front().scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -350) }
            XCTAssertTrue(control.exists && control.isHittable, app.debugDescription)
        }
        XCTAssertTrue(app.buttons["openTemplates"].waitForExistence(timeout: 15)); let before = try tables()
        app.buttons["openTemplates"].click()
        let file = URL(fileURLWithPath: "/tmp/taskfold-source-mapping-" + UUID().uuidString.lowercased() + ".csv")
        try Data("Name,Details,Kind,Done\nDesign context,Keep the context,heading,true\n* Ordinary action,Keep the action,task,true".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        func prepare() {
            let importFile = app.buttons["mapWorkflowCSVFile"]; reveal(importFile); importFile.click()
            app.typeKey("g", modifierFlags: [.command, .shift])
            let field = front().textFields.firstMatch; XCTAssertTrue(field.waitForExistence(timeout: 5)); field.click(); field.typeKey("a", modifierFlags: .command); field.typeText(file.path); field.typeKey(.return, modifierFlags: [])
            let open = app.sheets["open-panel"].buttons["OKButton"]; if open.waitForExistence(timeout: 3) { open.click() }
            for (key, value) in [("title","Name"),("notes","Details"),("type","Kind")] {
                let picker = app.descendants(matching: .any).matching(identifier: "mappedCSVColumn-" + key).firstMatch
                XCTAssertTrue(picker.waitForExistence(timeout: 8)); reveal(picker); picker.click()
                let option = app.menuItems[value]; XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription); option.click()
            }
            let review = app.buttons["reviewMappedCSV"]; reveal(review)
            XCTAssertTrue(renderedText(app.staticTexts["mappedCSVIgnoredColumns"]).contains("Done"))
            review.click(); reveal(app.buttons["confirmImportTemplate"])
        }
        prepare(); retainWindow(app, name: "Mac mapped source CSV full review before saving")
        let cancel = front().buttons["Cancel"].firstMatch; reveal(cancel); cancel.click(); XCTAssertEqual(try tables(), before)
        prepare(); app.buttons["confirmImportTemplate"].click()
        let after = try tables(), definitions = try XCTUnwrap(after["project_templates"] as? [[String: Any]])
        XCTAssertEqual(after["tasks"] as? NSArray, before["tasks"] as? NSArray)
        XCTAssertEqual(definitions.count, (before["project_templates"] as? [Any])!.count + 1)
        let imported = try XCTUnwrap(definitions.first { $0["name"] as? String == "Imported workflow" })
        let document = try XCTUnwrap(imported["document"] as? [String: Any]), tasks = try XCTUnwrap(document["tasks"] as? [[String: Any]])
        XCTAssertEqual(document["version"] as? Int, 2); XCTAssertEqual(tasks[0]["is_heading"] as? Bool, true)
        XCTAssertEqual(tasks[1]["title"] as? String, "* Ordinary action"); XCTAssertNil(tasks[0]["completed"])
        app.terminate(); app.launchArguments = ["--uitesting", "-localMode", "YES"]; try launchHeadingWorkspace(app)
        XCTAssertTrue(app.buttons["openTemplates"].waitForExistence(timeout: 15)); app.buttons["openTemplates"].click()
        XCTAssertTrue(app.buttons["workflowTemplate-" + (imported["id"] as! String)].waitForExistence(timeout: 8))
        XCTAssertEqual((try tables())["tasks"] as? NSArray, before["tasks"] as? NSArray)
        XCTAssertEqual(((try tables())["project_templates"] as? [[String: Any]])?.first { $0["id"] as? String == imported["id"] as? String } as NSDictionary?, imported as NSDictionary)
    }
}

final class SharedHeadingNativeTests: XCTestCase {
    private let bundle = "com.dbakp.taskfold.mac.workflowteststeameditbridge"
    private func saved() throws -> [String: Any] {
        let url = URL(fileURLWithPath: "/Users/" + NSUserName() + "/Library/Containers/" + bundle + "/Data/Library/Application Support/Taskfold/ec240000-0000-4000-8000-000000000001.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
    private func root() throws -> [String: Any] { try XCTUnwrap((try saved()["tables"] as? [String: [[String: Any]]])?["tasks"]?.first) }
    @MainActor private func open(_ app: XCUIApplication) throws {
        app.launch(); let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
        XCTAssertEqual(running.count, 1); let url = try XCTUnwrap(running.first?.bundleURL)
        let opened = expectation(description: "Open isolated shared heading workspace")
        let config = NSWorkspace.OpenConfiguration(); config.activates = true; config.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in XCTAssertNil(error); opened.fulfill() }
        wait(for: [opened], timeout: 10); app.activate()
    }
    @MainActor func testSharedHeadingAutosaveUndoRedoAndColdQueue() throws {
        guard Bundle(for: Self.self).bundleIdentifier == bundle + ".runner" else { throw XCTSkip("Reserved isolated Mac host required") }
        continueAfterFailure = false; let app = XCUIApplication(); defer { app.terminate() }
        app.launchArguments = ["--team-editor-testing", "--team-editor-reset", "--team-heading-testing", "-appearance", "light"]
        try open(app); let picker = app.descendants(matching: .any).matching(identifier: "taskKindPicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 12), app.debugDescription); let before = try root(); picker.click()
        XCTAssertTrue(app.menuItems["Heading"].waitForExistence(timeout: 5), app.debugDescription); app.menuItems["Heading"].click()
        func waitType(_ heading: Bool) {
            let changed = expectation(for: NSPredicate { _, _ in (try? self.root())?["is_heading"] as? Bool == heading }, evaluatedWith: nil)
            wait(for: [changed], timeout: 12)
        }
        waitType(true); let after = try root()
        for key in ["title", "description", "user_id", "project_id", "task_generation", "subtasks", "opaque_future"] { XCTAssertEqual(after[key] as? NSObject, before[key] as? NSObject, key) }
        app.buttons["undoTeamHeading"].click(); waitType(false); app.buttons["redoTeamHeading"].click(); waitType(true)
        let final = try saved(), picture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); picture.name = "Mac shared heading autosave and typed Undo"; picture.lifetime = .keepAlways; add(picture)
        app.terminate(); app.launchArguments.removeAll { $0 == "--team-editor-reset" }; try open(app)
        XCTAssertTrue(picker.waitForExistence(timeout: 12)); XCTAssertEqual(try saved() as NSDictionary, final as NSDictionary)
    }
}

extension TeamWorkflowMacUITests {
    @MainActor func testHeadingWorkflowLostReplyColdRetryPreservesTypes() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try launch(app, lost: true, headings: true)
        review(app); shot(app, "mac-heading-workflow-review"); create(app)
        XCTAssertTrue(app.staticTexts["sharedWorkflowRecoveryMessage"].waitForExistence(timeout: 12), app.debugDescription)
        let requests = try XCTUnwrap(try state()["workflowRequests"] as? [String:[String:Any]])
        XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(requests.values.first?["_body"] as? [String:Any]); XCTAssertEqual(body["workflow_types_protocol"] as? Int, 1)
        let root = try XCTUnwrap((body["tasks"] as? [[String:Any]])?.first); XCTAssertEqual(root["is_heading"] as? Bool, true)
        let child = try XCTUnwrap((root["subtasks"] as? [[String:Any]])?.first); XCTAssertEqual(child["is_heading"] as? Bool, true)
        let work = try XCTUnwrap((child["subtasks"] as? [[String:Any]])?.first); XCTAssertNil(work["is_heading"]); XCTAssertEqual(work["title"] as? String, "Approve the design")
        app.terminate(); try launch(app, reset: false, headings: true)
        app.buttons["openWorkflowRecoveryFixture"].click()
        let saved = app.buttons["savedTeamWorkflowRequest"]; XCTAssertTrue(saved.waitForExistence(timeout: 10)); saved.click()
        let retry = app.buttons["retrySharedWorkflow"]; XCTAssertTrue(retry.waitForExistence(timeout: 8)); retry.click()
        let confirm = app.buttons.matching(identifier: "confirmSharedWorkflowRetry").firstMatch; XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.click()
        XCTAssertTrue(app.staticTexts["sharedWorkflowSuccess"].waitForExistence(timeout: 12), app.debugDescription)
        let after = try state(); XCTAssertEqual(after["workflowRequests"] as? NSDictionary, requests as NSDictionary); XCTAssertEqual(after["workflowCalls"] as? Int, 2)
        XCTAssertEqual((after["workflowReceipts"] as? [String:[String:Any]])?.values.first?["workflow_types_protocol"] as? Int, 1)
        shot(app, "mac-heading-workflow-original-confirmed")
    }
}

extension TeamWorkflowMacUITests {
    @MainActor func testPrivateHeadingWorkflowLostReplyColdRetryPreservesTypes() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try launch(app, lost: true, headings: true)
        let before = try cache(); review(app, personal: true); shot(app, "mac-private-heading-workflow-review"); create(app)
        XCTAssertTrue(app.staticTexts["sharedWorkflowRecoveryMessage"].waitForExistence(timeout: 12), app.debugDescription)
        let requests = try XCTUnwrap(try state()["workflowRequests"] as? [String:[String:Any]])
        XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(requests.values.first?["_body"] as? [String:Any]); XCTAssertEqual(body["workflow_types_protocol"] as? Int, 1)
        XCTAssertEqual((body["source"] as? [String:Any])?["kind"] as? String, "personal")
        let root = try XCTUnwrap((body["tasks"] as? [[String:Any]])?.first); XCTAssertEqual(root["is_heading"] as? Bool, true)
        let child = try XCTUnwrap((root["subtasks"] as? [[String:Any]])?.first); XCTAssertEqual(child["is_heading"] as? Bool, true)
        let work = try XCTUnwrap((child["subtasks"] as? [[String:Any]])?.first); XCTAssertNil(work["is_heading"]); XCTAssertEqual(work["title"] as? String, "Approve the design")
        app.terminate(); try launch(app, reset: false, headings: true)
        app.buttons["openWorkflowRecoveryFixture"].click()
        let saved = app.buttons["savedTeamWorkflowRequest"]; XCTAssertTrue(saved.waitForExistence(timeout: 10)); saved.click()
        let retry = app.buttons["retrySharedWorkflow"]; XCTAssertTrue(retry.waitForExistence(timeout: 8)); retry.click()
        let confirm = app.buttons.matching(identifier: "confirmSharedWorkflowRetry").firstMatch; XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.click()
        XCTAssertTrue(app.staticTexts["sharedWorkflowSuccess"].waitForExistence(timeout: 12), app.debugDescription)
        let after = try state(); XCTAssertEqual(after["workflowRequests"] as? NSDictionary, requests as NSDictionary); XCTAssertEqual(after["workflowCalls"] as? Int, 2)
        XCTAssertEqual((after["workflowReceipts"] as? [String:[String:Any]])?.values.first?["workflow_types_protocol"] as? Int, 1)
        XCTAssertEqual(rows(try cache(), "project_templates"), rows(before, "project_templates")); XCTAssertEqual(rows(try cache(), "tasks"), rows(before, "tasks"))
        shot(app, "mac-private-heading-workflow-original-confirmed")
    }
    @MainActor func testPrivateHeadingReviewBackPreservesSourceAfterRelaunch() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try launch(app, headings: true)
        let before = try cache(); review(app, personal: true)
        let back = app.buttons["backSharedWorkflow"]; reveal(back, app: app); back.click()
        XCTAssertTrue(app.buttons["reviewSharedWorkflow"].waitForExistence(timeout: 8)); XCTAssertEqual(try state()["workflowCalls"] as? Int, 0)
        app.terminate(); try launch(app, reset: false, headings: true)
        XCTAssertEqual(rows(try cache(), "project_templates"), rows(before, "project_templates")); XCTAssertEqual(rows(try cache(), "tasks"), rows(before, "tasks"))
        XCTAssertEqual(try state()["workflowCalls"] as? Int, 0)
    }
    @MainActor func testPrivateHeadingMissingWorkspaceSupportExplainsAndCreatesNothing() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try launch(app, headings: true, capabilityOff: true)
        let before = try cache(); review(app, personal: true, available: false)
        let message = app.staticTexts["sharedWorkflowMessage"]; XCTAssertTrue(message.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertTrue((message.value as? String ?? message.label).contains("Headings aren’t available in this shared workspace"))
        XCTAssertFalse(app.buttons["createSharedWorkflow"].exists); XCTAssertEqual(try state()["workflowCalls"] as? Int, 0)
        XCTAssertEqual(rows(try cache(), "project_templates"), rows(before, "project_templates"))
        shot(app, "mac-private-heading-workspace-unavailable")
    }
    @MainActor func testHeadingClientGateKeepsDefinitionsAndTransferAvailable() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try launch(app, headings: true)
        let before = try cache(); app.buttons["openPrivateWorkflowRunFixture"].click()
        let run = app.buttons["runPrivateTemplateShared"]; XCTAssertTrue(run.waitForExistence(timeout: 10)); XCTAssertFalse(run.isEnabled)
        XCTAssertTrue(app.staticTexts["privateWorkflowHeadingUnavailable"].exists)
        app.terminate(); try launch(app, reset: false, headings: true)
        app.buttons["openTeamTemplateLibraryFixture"].click(); let item = app.buttons["teamTemplate-" + definition]; XCTAssertTrue(item.waitForExistence(timeout: 10)); item.click()
        let copy = app.buttons["copyTeamTemplate"]; XCTAssertTrue(copy.waitForExistence(timeout: 8)); XCTAssertTrue(copy.isEnabled)
        XCTAssertFalse(app.buttons["runTeamTemplate"].isEnabled); XCTAssertTrue(app.staticTexts["teamWorkflowHeadingUnavailable"].exists); XCTAssertTrue(app.buttons["exportTeamTemplate"].isEnabled)
        shot(app, "mac-heading-client-support-unavailable")
        let document = try XCTUnwrap((try state()["items"] as? [[String:Any]])?.first { $0["id"] as? String == self.definition }?["document"] as? NSDictionary)
        copy.click(); let save = app.buttons["saveTeamTemplateCopy"]; XCTAssertTrue(save.waitForExistence(timeout: 8)); save.click()
        XCTAssertTrue(app.buttons["copyTeamTemplate"].waitForExistence(timeout: 10))
        let templates = rows(try cache(), "project_templates") as! [[String:Any]], original = rows(before, "project_templates") as! [[String:Any]]
        let copies = templates.filter { $0["id"] as? String != original.first?["id"] as? String }
        XCTAssertEqual(copies.count, 1); XCTAssertEqual(copies[0]["document"] as? NSDictionary, document)
        XCTAssertEqual(templates.first { $0["id"] as? String == original.first?["id"] as? String } as NSDictionary?, original.first as NSDictionary?)
        XCTAssertEqual(rows(try cache(), "tasks"), rows(before, "tasks")); XCTAssertEqual(try state()["workflowCalls"] as? Int, 0)
        shot(app, "mac-heading-client-private-copy")
    }
}

extension TeamWorkflowMacUITests {
    @MainActor private func definitionReveal(_ control: XCUIElement, _ app: XCUIApplication, towardTop: Bool = false) {
        for _ in 0..<16 {
            if control.exists, control.isHittable { return }
            let surface = app.sheets.count > 0 ? app.sheets.element(boundBy: app.sheets.count - 1) : app.windows.firstMatch
            surface.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: towardTop ? 280 : -280)
        }
        XCTAssertTrue(control.exists && control.isHittable, app.debugDescription)
    }
    @MainActor private func definitionChoose(_ id: String, _ title: String, _ app: XCUIApplication, towardTop: Bool = false) {
        let picker = app.popUpButtons[id]; definitionReveal(picker, app, towardTop: towardTop); picker.click()
        let option = app.menuItems[title].firstMatch; XCTAssertTrue(option.waitForExistence(timeout: 5)); option.click()
    }
    @MainActor private func definitionRows(_ name: String) throws -> [[String:Any]] {
        let value = try cache(); return (value["tables"] as? [String:[[String:Any]]])?[name] ?? []
    }
    @MainActor private func definitionSaved(_ id: String) throws -> [String:Any] {
        try XCTUnwrap(try definitionRows("project_templates").first { $0["id"] as? String == id })
    }
    @MainActor private func definitionPrepareCSV(_ app: XCUIApplication) {
        app.buttons["openSharedTemplateFixture"].click()
        let intake = app.buttons["importWorkflowText"]; definitionReveal(intake, app); intake.click()
        let input = app.textViews["templateImportText"]; XCTAssertTrue(input.waitForExistence(timeout: 8)); input.click()
        input.typeText("Name,Kind,Done\nDesign context,heading,true\n* Ordinary action,task,true")
        let map = app.buttons["mapTemplateCSVText"]; definitionReveal(map, app); map.click()
        definitionChoose("mappedCSVColumn-title", "Name", app); definitionChoose("mappedCSVColumn-type", "Kind", app)
    }
    @MainActor func testCloudCSVHeadingDefinitionCancelSaveAndColdReturn() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try launch(app)
        let original = try definitionRows("tasks"), before = try definitionRows("project_templates")
        definitionPrepareCSV(app)
        let review = app.buttons["reviewMappedCSV"]; definitionReveal(review, app); review.click()
        let save = app.buttons["confirmImportTemplate"]; definitionReveal(save, app)
        let cancel = app.buttons["cancelImportTemplateReview"]; definitionReveal(cancel, app); cancel.click()
        XCTAssertEqual(try definitionRows("project_templates") as NSArray, before as NSArray)
        // The intake sheet is dismissed. Reopen it from the current template library.
        let intake = app.buttons["importWorkflowText"]; XCTAssertTrue(intake.waitForExistence(timeout: 8)); intake.click()
        let input = app.textViews["templateImportText"]; XCTAssertTrue(input.waitForExistence(timeout: 8)); input.click(); input.typeText("Name,Kind,Done\nDesign context,heading,true\n* Ordinary action,task,true")
        let map = app.buttons["mapTemplateCSVText"]; definitionReveal(map, app); map.click()
        definitionChoose("mappedCSVColumn-title", "Name", app); definitionChoose("mappedCSVColumn-type", "Kind", app)
        definitionReveal(review, app); review.click(); definitionReveal(save, app); shot(app, "cloud-heading-csv-review"); save.click()
        XCTAssertTrue(intake.waitForExistence(timeout: 10))
        let imported = try XCTUnwrap(try definitionRows("project_templates").first { $0["name"] as? String == "Imported workflow" })
        let document = try XCTUnwrap(imported["document"] as? [String:Any]), tasks = try XCTUnwrap(document["tasks"] as? [[String:Any]])
        XCTAssertEqual(document["version"] as? Int, 2); XCTAssertEqual(tasks[0]["is_heading"] as? Bool, true)
        XCTAssertEqual(tasks[1]["title"] as? String, "* Ordinary action"); XCTAssertNil(tasks[1]["is_heading"])
        XCTAssertTrue(tasks.allSatisfy { $0["completed"] == nil }); XCTAssertEqual(try definitionRows("tasks") as NSArray, original as NSArray)
        let open = app.buttons["workflowTemplate-" + (imported["id"] as! String)]; definitionReveal(open, app); open.click()
        let create = app.buttons["applyWorkflowTemplate"]; definitionReveal(create, app); XCTAssertFalse(create.isEnabled)
        app.terminate(); try launch(app, reset: false)
        XCTAssertEqual(try definitionSaved(imported["id"] as! String) as NSDictionary, imported as NSDictionary)
        XCTAssertEqual(try definitionRows("tasks") as NSArray, original as NSArray)
    }
    @MainActor private func definitionEditTask(_ app: XCUIApplication, id: String = "0") {
        app.buttons["openPrivateWorkflowRunFixture"].click()
        let edit = app.buttons["editTemplateDefinition"]; XCTAssertTrue(edit.waitForExistence(timeout: 8)); edit.click()
        let item = app.buttons["editTemplateTask-" + id]; definitionReveal(item, app); item.click()
        XCTAssertTrue(app.buttons["saveTemplateTask"].waitForExistence(timeout: 8))
    }
    @MainActor func testCloudTemplateHeadingDraftCancelSaveAndColdReturn() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try launch(app)
        let original = try definitionRows("tasks"), before = try definitionRows("project_templates")
        definitionEditTask(app); definitionChoose("templateTaskKind", "Heading", app)
        app.buttons["saveTemplateTask"].click(); XCTAssertTrue(app.buttons["saveTemplateDefinition"].waitForExistence(timeout: 8))
        XCTAssertEqual(try definitionRows("project_templates") as NSArray, before as NSArray)
        app.buttons["cancelTemplateDefinition"].click(); let discard = app.windows.buttons.matching(identifier: "Discard changes").firstMatch; XCTAssertTrue(discard.waitForExistence(timeout: 5)); discard.click()
        XCTAssertEqual(try definitionRows("project_templates") as NSArray, before as NSArray)
        app.buttons["editTemplateDefinition"].click(); let task = app.buttons["editTemplateTask-0"]; definitionReveal(task, app); task.click()
        definitionChoose("templateTaskKind", "Heading", app); app.buttons["saveTemplateTask"].click()
        shot(app, "cloud-template-heading-draft"); app.buttons["saveTemplateDefinition"].click()
        let id = try XCTUnwrap(before.first?["id"] as? String), saved = try definitionSaved(id)
        let doc = try XCTUnwrap(saved["document"] as? [String:Any]), root = try XCTUnwrap((doc["tasks"] as? [[String:Any]])?.first)
        XCTAssertEqual(doc["version"] as? Int, 2); XCTAssertEqual(root["is_heading"] as? Bool, true)
        XCTAssertEqual(try definitionRows("tasks") as NSArray, original as NSArray)
        app.terminate(); try launch(app, reset: false); XCTAssertEqual(try definitionSaved(id) as NSDictionary, saved as NSDictionary)
    }
    @MainActor func testNestedTemplateTypeEditPreservesWholeDefinition() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try launch(app, headings: true)
        let tasks = try definitionRows("tasks"), before = try XCTUnwrap(try definitionRows("project_templates").first), id = try XCTUnwrap(before["id"] as? String)
        definitionEditTask(app, id: "0.0"); definitionChoose("templateTaskKind", "Task", app)
        app.buttons["saveTemplateTask"].click(); app.buttons["saveTemplateDefinition"].click()
        let saved = try definitionSaved(id), doc = try XCTUnwrap(saved["document"] as? [String:Any]), root = try XCTUnwrap((doc["tasks"] as? [[String:Any]])?.first), child = try XCTUnwrap((root["subtasks"] as? [[String:Any]])?.first)
        XCTAssertEqual(doc["version"] as? Int, 2); XCTAssertEqual(root["is_heading"] as? Bool, true); XCTAssertEqual(child["is_heading"] as? Bool, false)
        XCTAssertEqual((child["subtasks"] as? [[String:Any]])?.first?["title"] as? String, "Approve the design")
        XCTAssertEqual(try definitionRows("tasks") as NSArray, tasks as NSArray)
        app.terminate(); try launch(app, reset: false, headings: true); XCTAssertEqual(try definitionSaved(id) as NSDictionary, saved as NSDictionary)
    }
    @MainActor func testCSVHeadingClientGateStillAllowsOrdinaryMapping() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try launch(app)
        let before = try definitionRows("project_templates"), tasks = try definitionRows("tasks")
        definitionPrepareCSV(app); let review = app.buttons["reviewMappedCSV"]; definitionReveal(review, app); review.click()
        let error = app.staticTexts["mappedCSVError"]; definitionReveal(error, app); XCTAssertTrue((error.value as? String ?? error.label).contains("cannot create heading templates"))
        XCTAssertEqual(try definitionRows("project_templates") as NSArray, before as NSArray)
        definitionChoose("mappedCSVColumn-type", "Not copied", app, towardTop: true); definitionReveal(review, app); review.click()
        let save = app.buttons["confirmImportTemplate"]; definitionReveal(save, app); XCTAssertTrue(save.isEnabled)
        shot(app, "client-off-ordinary-csv-review")
        app.buttons["cancelImportTemplateReview"].click(); XCTAssertEqual(try definitionRows("tasks") as NSArray, tasks as NSArray)
    }
    @MainActor func testClientOffTemplateEditsKeepExistingHeadingType() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try launch(app, headings: true)
        let before = try XCTUnwrap(try definitionRows("project_templates").first), id = try XCTUnwrap(before["id"] as? String), tasks = try definitionRows("tasks")
        definitionEditTask(app); let type = app.popUpButtons["templateTaskKind"]; XCTAssertTrue(type.exists); XCTAssertFalse(type.isEnabled)
        let title = app.textFields["templateTaskTitle"]; title.click(); title.typeText(" revised")
        app.buttons["saveTemplateTask"].click(); app.buttons["saveTemplateDefinition"].click()
        let saved = try definitionSaved(id), doc = try XCTUnwrap(saved["document"] as? [String:Any]), root = try XCTUnwrap((doc["tasks"] as? [[String:Any]])?.first)
        XCTAssertEqual(doc["version"] as? Int, 2); XCTAssertEqual(root["is_heading"] as? Bool, true); XCTAssertTrue((root["title"] as? String ?? "").contains("revised"))
        XCTAssertEqual(try definitionRows("tasks") as NSArray, tasks as NSArray)
        app.terminate(); try launch(app, reset: false, headings: true); XCTAssertEqual(try definitionSaved(id) as NSDictionary, saved as NSDictionary)
    }
}

extension SharedHeadingNativeTests {
    private func personalStateFile() -> URL {
        URL(fileURLWithPath: "/Users/" + NSUserName() + "/Library/Containers/" + bundle + "/Data/Library/Application Support/TaskfoldPersonalHeadingNativeFixture-workflowteststeameditbridge.json")
    }
    private func personalState() throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: personalStateFile())) as? [String: Any]) }
    private func personalCachedSupport() throws -> Int? {
        let cache = try saved()
        return (((cache["teamWorkspace"] as? [String: Any])?["boundary"] as? [String: Any])?["raw"] as? [String: Any])?["personal_task_types_protocol"] as? Int
    }
    private func personalDelivered(_ attempts: Int) throws -> Bool {
        let cache = try saved(), state = try personalState()
        return (cache["pending"] as? [Any])?.isEmpty == true && (state["attempts"] as? [Any])?.count == attempts
    }
    private func personalUnconfirmed(_ attempts: Int) throws -> Bool {
        let cache = try saved(), state = try personalState()
        return (cache["pending"] as? [Any])?.count == 1 && (state["attempts"] as? [Any])?.count == attempts
    }
    private func personalPaused(_ attempts: Int) throws -> Bool {
        let cache = try saved(), state = try personalState(), support = try personalCachedSupport()
        return (cache["pending"] as? [Any])?.count == 1 && support == 0 && (state["attempts"] as? [Any])?.count == attempts
    }
    @MainActor private func personalWait(_ condition: @escaping () throws -> Bool) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (try? condition()) == true }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
    }
    @MainActor private func personalStart(_ app: XCUIApplication, reset: Bool = true, lost: Bool = false, unsupported: Bool = false) throws {
        guard [bundle + ".runner", bundle + ".runner.xctrunner"].contains(Bundle(for: Self.self).bundleIdentifier ?? "") else { throw XCTSkip("Reserved isolated Mac host required") }
        continueAfterFailure = false
        app.launchArguments = ["--team-editor-testing", "--team-heading-testing", "--personal-heading-testing", "-appearance", "light"] + (reset ? ["--team-editor-reset"] : []) + (lost ? ["--personal-heading-lose-reply"] : []) + (unsupported ? ["--personal-heading-capability-off"] : [])
        try open(app); XCTAssertTrue(app.descendants(matching: .any)["taskTitle"].waitForExistence(timeout: 15), app.debugDescription)
    }
    @MainActor private func personalChooseHeading(_ app: XCUIApplication, pause: Bool = false) throws {
        if pause { app.buttons["pausePersonalHeadingSupport"].click() }
        let picker = app.descendants(matching: .any)["taskKindPicker"]; XCTAssertTrue(picker.waitForExistence(timeout: 8)); picker.click()
        XCTAssertTrue(app.menuItems["Heading"].waitForExistence(timeout: 5)); app.menuItems["Heading"].click()
    }
    @MainActor func testPersonalHeadingLostReplyPauseColdExactRetry() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try personalStart(app, lost: true)
        let before = try root(); try personalChooseHeading(app)
        personalWait { try self.personalUnconfirmed(1) }
        let state = try personalState(), queued = try XCTUnwrap((try saved()["pending"] as? [[String: Any]])?.first)
        XCTAssertNil(queued["teamTaskScope"]); XCTAssertEqual(state["transitions"] as? Int, 1); XCTAssertEqual(try root()["is_heading"] as? Bool, true)
        app.terminate(); try personalStart(app, reset: false)
        personalWait { try self.personalPaused(1) }
        app.buttons["restorePersonalHeadingSupport"].click(); app.terminate(); try personalStart(app, reset: false)
        personalWait { try self.personalDelivered(2) }
        let after = try root(), final = try personalState(), attempts = try XCTUnwrap(final["attempts"] as? [[String: Any]])
        XCTAssertEqual(attempts[0] as NSDictionary, attempts[1] as NSDictionary); XCTAssertEqual(final["transitions"] as? Int, 1); XCTAssertEqual(after["completion_version"] as? Int, 1)
        for key in ["title", "description", "subtasks", "task_generation", "user_id", "project_id", "opaque_future"] { XCTAssertEqual(after[key] as? NSObject, before[key] as? NSObject, key) }
        let image = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); image.name = "Mac personal heading original response confirmed after cold retry"; image.lifetime = .keepAlways; add(image)
    }
    @MainActor func testPersonalHeadingMissingSupportBeforeAutosaveKeepsVisibleQueue() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try personalStart(app); try personalChooseHeading(app, pause: true)
        personalWait { (try self.saved()["pending"] as? [Any])?.count == 1 }
        app.terminate(); try personalStart(app, reset: false)
        personalWait { try self.personalPaused(0) }
        XCTAssertEqual(try root()["is_heading"] as? Bool, true)
        app.buttons["restorePersonalHeadingSupport"].click(); app.terminate(); try personalStart(app, reset: false)
        personalWait { try self.personalDelivered(1) }
        XCTAssertEqual(try personalState()["transitions"] as? Int, 1); XCTAssertEqual(try root()["is_heading"] as? Bool, true)
    }
    @MainActor func testPersonalHeadingUnsupportedServiceKeepsOrdinaryEditing() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try personalStart(app, unsupported: true)
        let before = try root(); XCTAssertFalse(app.descendants(matching: .any)["taskKindPicker"].exists)
        let title = app.textFields["taskTitle"]; XCTAssertTrue(title.exists); title.click(); title.typeKey("a", modifierFlags: .command); title.typeText("Personal heading proof revised"); title.typeKey(.tab, modifierFlags: [])
        personalWait { try self.personalDelivered(1) }
        XCTAssertEqual(try root()["title"] as? String, "Personal heading proof revised"); XCTAssertTrue(try root()["is_heading"] is NSNull)
        XCTAssertEqual(try root()["description"] as? String, before["description"] as? String); XCTAssertEqual(try personalState()["transitions"] as? Int, 0)
    }
}


extension SharedHeadingNativeTests {
    private func workflowPeerFile() throws -> URL { return personalStateFile().deletingLastPathComponent().appendingPathComponent("TaskfoldWorkflowUndoNativeFixture-workflowteststeameditbridge.json") }
    private func workflowPeer() throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: workflowPeerFile())) as? [String: Any]) }
    private func workflowCache() throws -> [String: Any] { return try saved() }
    private func workflowRows() throws -> [String: [[String: Any]]] { try XCTUnwrap(workflowPeer()["rows"] as? [String: [[String: Any]]]) }
    @MainActor private func workflowWait(_ condition: @escaping () throws -> Bool) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (try? condition()) == true }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed)
    }
    @MainActor private func workflowStart(_ app: XCUIApplication, reset: Bool = true, lost: Bool = false, hold: Bool = false) throws {
        guard [bundle + ".runner", bundle + ".runner.xctrunner"].contains(Bundle(for: Self.self).bundleIdentifier ?? "") else { throw XCTSkip("Reserved isolated Mac host required") }
        continueAfterFailure = false
        app.launchArguments = ["--team-editor-testing", "--team-heading-testing", "--personal-heading-testing", "--personal-workflow-undo-testing", "-appearance", "light"] + (reset ? ["--team-editor-reset"] : []) + (lost ? ["--workflow-undo-lose-reply"] : []) + (hold ? ["--workflow-preparation-hold"] : [])
        try open(app)
        XCTAssertTrue(app.buttons["openNativeWorkflow"].waitForExistence(timeout: 15), app.debugDescription)
        workflowWait { try self.workflowCachedSupport() == 1 || !reset }
    }
    private func workflowCachedSupport() throws -> Int? {
        let cache = try workflowCache()
        return (((cache["teamWorkspace"] as? [String: Any])?["boundary"] as? [String: Any])?["raw"] as? [String: Any])?["personal_workflow_undo_protocol"] as? Int
    }
    @MainActor private func workflowCreate(_ app: XCUIApplication) throws {
        app.buttons["openNativeWorkflow"].click()
        let create = app.buttons["applyWorkflowTemplate"]

        XCTAssertTrue(create.waitForExistence(timeout: 8), app.debugDescription); create.click()
        workflowWait { try self.workflowSettled(tasks: 3, attempts: 0) }
        let rows = try workflowRows()
        XCTAssertEqual(rows["projects"]?.count, 2); XCTAssertEqual(rows["sections"]?.count, 1); XCTAssertEqual(rows["labels"]?.count, 1); XCTAssertEqual(rows["view_orders"]?.count, 2)
        let heading = try XCTUnwrap(rows["tasks"]?.first { $0["title"] as? String == "Design instructions" })
        XCTAssertEqual(heading["is_heading"] as? Bool, true)
        XCTAssertEqual(heading["description"] as? String, "Keep the layout readable.\nCheck contrast and spacing.")
        XCTAssertEqual((heading["subtasks"] as? [[String: Any]])?.first?["title"] as? String, "Approve the layout")
    }
    private func workflowSettled(tasks: Int, attempts: Int) throws -> Bool {
        let cache = try workflowCache(), peer = try workflowPeer(), remote = try workflowRows()
        guard (cache["pending"] as? [Any])?.isEmpty == true, (peer["attempts"] as? [Any])?.count == attempts,
              remote["tasks"]?.count == tasks, let local = cache["tables"] as? [String: [[String: Any]]] else { return false }
        for table in ["projects", "sections", "labels", "tasks", "view_orders", "project_templates"] {
            let expected = Dictionary((remote[table] ?? []).map { ($0["id"] as! String, $0 as NSDictionary) }, uniquingKeysWith: { a, _ in a })
            let actual = Dictionary((local[table] ?? []).map { ($0["id"] as! String, $0 as NSDictionary) }, uniquingKeysWith: { a, _ in a })
            if expected as NSDictionary != actual as NSDictionary { return false }
        }
        return true
    }
    @MainActor func testPrivateWorkflowNativeCreateUndoRedoAndColdReturn() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try workflowStart(app); try workflowCreate(app)
        let first = try workflowRows()
        app.buttons["undoNativeWorkflow"].click(); workflowWait { try self.workflowSettled(tasks: 1, attempts: 1) }
        XCTAssertEqual(try workflowPeer()["transitions"] as? Int, 1)
        app.buttons["redoNativeWorkflow"].click(); workflowWait { try self.workflowSettled(tasks: 3, attempts: 1) }
        let restored = try workflowRows()
        for table in ["projects", "sections", "labels", "tasks", "view_orders"] {
            XCTAssertEqual(Set((first[table] ?? []).compactMap { $0["id"] as? String }), Set((restored[table] ?? []).compactMap { $0["id"] as? String }))
        }
        for old in first["tasks"] ?? [] where old["title"] as? String != "Personal heading proof" {
            let current = try XCTUnwrap(restored["tasks"]?.first { $0["id"] as? String == old["id"] as? String })
            XCTAssertNotEqual(current["task_generation"] as? String, old["task_generation"] as? String)
            for key in ["title", "description", "subtasks", "labels", "is_heading", "project_id", "section_id"] { XCTAssertEqual(current[key] as? NSObject, old[key] as? NSObject, key) }
        }
        app.buttons["undoNativeWorkflow"].click(); workflowWait { try self.workflowSettled(tasks: 1, attempts: 2) }
        app.buttons["redoNativeWorkflow"].click(); workflowWait { try self.workflowSettled(tasks: 3, attempts: 2) }
        let final = try workflowRows(); app.terminate(); try workflowStart(app, reset: false)
        workflowWait { try self.workflowSettled(tasks: 3, attempts: 2) }; XCTAssertEqual(try workflowRows() as NSDictionary, final as NSDictionary)
        let picture = XCTAttachment(screenshot: app.screenshot()); picture.name = "Private workflow restored after cold return"; picture.lifetime = .keepAlways; add(picture)
    }
    @MainActor func testPrivateWorkflowNativeLostUndoReplyPausesAndRetriesExactly() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try workflowStart(app, lost: true); try workflowCreate(app)
        app.buttons["undoNativeWorkflow"].click()
        workflowWait { let cache = try self.workflowCache(), peer = try self.workflowPeer(); return (cache["pending"] as? [Any])?.count == 1 && (peer["attempts"] as? [Any])?.count == 1 }
        let first = try XCTUnwrap((try workflowPeer()["attempts"] as? [[String: Any]])?.first)
        let pending = try XCTUnwrap((try workflowCache()["pending"] as? [[String: Any]])?.first)
        XCTAssertEqual(pending["method"] as? String, "WORKFLOW_UNDO")
        app.terminate(); try workflowStart(app, reset: false)
        workflowWait { try self.workflowCachedSupport() == 0 && (self.workflowCache()["pending"] as? [Any])?.count == 1 }
        XCTAssertEqual((try workflowPeer()["attempts"] as? [Any])?.count, 1)
        app.buttons["restoreNativeWorkflowSupport"].click()
        workflowWait { try self.workflowSettled(tasks: 1, attempts: 2) }
        XCTAssertEqual((try workflowPeer()["attempts"] as? [[String: Any]])?.last as NSDictionary?, first as NSDictionary)
        XCTAssertEqual(try workflowPeer()["transitions"] as? Int, 1)
        XCTAssertEqual((try workflowPeer()["receipts"] as? [String: Any])?.count, 1)
    }
    @MainActor func testPrivateWorkflowNativeIncomingWorkRefusesWholeUndo() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try workflowStart(app); try workflowCreate(app)
        let first = try workflowRows(); app.buttons["addIncomingWorkflowTask"].click(); app.buttons["undoNativeWorkflow"].click()
        workflowWait { try self.workflowSettled(tasks: 4, attempts: 1) }
        XCTAssertEqual(try workflowPeer()["transitions"] as? Int, 0)
        let after = try workflowRows()
        for (table, rows) in first { for row in rows { XCTAssertEqual(after[table]?.first { $0["id"] as? String == row["id"] as? String } as NSDictionary?, row as NSDictionary) } }
        let incoming = app.staticTexts["Later incoming work"]
        for _ in 0..<4 { if incoming.exists && incoming.isHittable { break }; app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -350) }
        XCTAssertTrue(incoming.waitForExistence(timeout: 5)); XCTAssertTrue(incoming.isHittable)
        let picture = XCTAttachment(screenshot: app.screenshot()); picture.name = "Refused workflow Undo preserves incoming work"; picture.lifetime = .keepAlways; add(picture)
        app.terminate(); try workflowStart(app, reset: false); workflowWait { try self.workflowSettled(tasks: 4, attempts: 1) }
    }

    @MainActor private func workflowBeginHeldPreparation(_ app: XCUIApplication) {
        app.buttons["openNativeWorkflow"].click()
        let create = app.buttons["applyWorkflowTemplate"]
        XCTAssertTrue(create.waitForExistence(timeout: 8)); create.click()
        XCTAssertTrue(app.buttons["cancelWorkflowPreparation"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(create.isEnabled, "One preparation must not start duplicate runs")
        XCTAssertTrue(app.staticTexts["workflowPreparationStatus"].exists)
    }
    @MainActor private func workflowAssertNoLateSave(cache: [String: Any], remote: [String: [[String: Any]]]) throws {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let current = try? self.workflowCache(), let peer = try? self.workflowRows() else { return true }
            return current as NSDictionary != cache as NSDictionary || peer as NSDictionary != remote as NSDictionary
        }, object: nil)
        changed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 12), .completed, "Cancelled preparation must not save after its worker returns")
        XCTAssertEqual(try workflowCache() as NSDictionary, cache as NSDictionary)
        XCTAssertEqual(try workflowRows() as NSDictionary, remote as NSDictionary)
    }
    @MainActor func testPrivateWorkflowNativePreparationCancelKeepsWorkspaceAndCanRetry() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try workflowStart(app, hold: true)
        let before = try workflowCache(), remote = try workflowRows()
        workflowBeginHeldPreparation(app)
        let picture = XCTAttachment(screenshot: app.screenshot()); picture.name = "Cancellable workflow preparation"; picture.lifetime = .keepAlways; add(picture)
        app.buttons["cancelWorkflowPreparation"].click()
        XCTAssertTrue(app.buttons["applyWorkflowTemplate"].isEnabled)
        try workflowAssertNoLateSave(cache: before, remote: remote)
        app.buttons["Done"].firstMatch.click()
        try workflowCreate(app)
    }
    @MainActor func testPrivateWorkflowNativePreparationDismissKeepsWorkspaceAfterColdReturn() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try workflowStart(app, hold: true)
        let before = try workflowCache(), remote = try workflowRows()
        workflowBeginHeldPreparation(app)
        app.buttons["Done"].firstMatch.click()
        XCTAssertTrue(app.buttons["openNativeWorkflow"].waitForExistence(timeout: 5))
        try workflowAssertNoLateSave(cache: before, remote: remote)
        app.terminate(); try workflowStart(app, reset: false)
        XCTAssertEqual(try workflowCache() as NSDictionary, before as NSDictionary)
        XCTAssertEqual(try workflowRows() as NSDictionary, remote as NSDictionary)
    }

    @MainActor func testPrivateWorkflowNativeOversizeRefusalRollsBackBeforeSave() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try workflowStart(app)
        let before = try workflowCache(), remote = try workflowRows()
        app.buttons["oversizedNativeWorkflow"].click()
        let warning = app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "too large to create")).firstMatch
        if warning.waitForExistence(timeout: 8) { XCTAssertTrue(warning.exists) }
        else { XCTAssertTrue(app.staticTexts["nativeWorkflowStatus"].label.contains("too large to create"), app.debugDescription) }
        if app.alerts.buttons["OK"].exists { app.alerts.buttons["OK"].click() }
        XCTAssertEqual(try workflowCache() as NSDictionary, before as NSDictionary)
        XCTAssertEqual(try workflowRows() as NSDictionary, remote as NSDictionary)
        XCTAssertFalse(app.buttons["undoNativeWorkflow"].isEnabled)
        app.terminate(); try workflowStart(app, reset: false)
        XCTAssertEqual(try workflowCache() as NSDictionary, before as NSDictionary)
    }

    @MainActor func testPrivateWorkflowNativeUnsupportedUndoPreservesWorkspace() throws {
        let app = XCUIApplication(); defer { app.terminate() }; try workflowStart(app); try workflowCreate(app)
        let first = try workflowRows(); app.buttons["pauseNativeWorkflowSupport"].click()
        workflowWait { try self.workflowCachedSupport() == 0 }
        app.buttons["undoNativeWorkflow"].click()
        let warning = app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "safely undo workflows")).firstMatch
        if warning.waitForExistence(timeout: 2) { XCTAssertTrue(warning.exists) }
        else { XCTAssertTrue(app.staticTexts["nativeWorkflowStatus"].label.contains("safely undo workflows"), app.debugDescription) }
        if app.alerts.buttons["OK"].exists { app.alerts.buttons["OK"].click() }
        XCTAssertTrue(try workflowSettled(tasks: 3, attempts: 0)); XCTAssertEqual(try workflowRows() as NSDictionary, first as NSDictionary)
        app.buttons["restoreNativeWorkflowSupport"].click(); workflowWait { try self.workflowCachedSupport() == 1 }
        app.buttons["undoNativeWorkflow"].click(); workflowWait { try self.workflowSettled(tasks: 1, attempts: 1) }
    }
}
