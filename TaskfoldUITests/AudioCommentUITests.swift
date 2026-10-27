import XCTest
import AppKit

extension TaskfoldMacUITests {
    @MainActor private func audioGuard() throws {
        #if os(macOS)
        let allowed = ["com.dbakp.taskfold.mac.workflowteststeameditbridge.runner", "com.dbakp.taskfold.mac.workflowteststeameditbridge.runner.xctrunner"]
        #else
        let allowed = ["com.dbakp.taskfold.workflowteststeameditbridge.uitests.xctrunner"]
        #endif
        guard allowed.contains(Bundle.main.bundleIdentifier ?? "") else { throw XCTSkip("Exact isolated audio host required") }
        continueAfterFailure = false
    }
    @MainActor private func audioPress(_ button: XCUIElement) {
        #if os(macOS)
        button.click()
        #else
        button.tap()
        #endif
    }
    @MainActor private func audioReveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<14 where !element.isHittable {
            #if os(macOS)
            let front = app.sheets.count > 0 ? app.sheets.firstMatch : app.windows.firstMatch
            let above = element.exists && element.frame.minY < front.frame.minY + 50
            front.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: above ? 240 : -240)
            #else
            app.swipeUp()
            #endif
        }
        XCTAssertTrue(element.exists && element.isHittable, app.debugDescription)
    }
    @MainActor private func audioOpen(_ app: XCUIApplication, reset: Bool = true, denied: Bool = false, large: Bool = false) {
        app.launchArguments = ["--uitesting", "--team-editor-testing", "--audio-comment-testing", "-appearance", large || denied ? "dark" : "light"]
        if reset { app.launchArguments.append("--audio-comment-reset") }
        if denied { app.launchArguments.append("--audio-comment-denied") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: "com.dbakp.taskfold.mac.workflowteststeameditbridge")
        XCTAssertEqual(instances.count, 1)
        guard let url = instances.first?.bundleURL else { XCTFail("Isolated host did not launch"); return }
        let opened = expectation(description: "Open isolated audio workshop")
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true; configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in XCTAssertNil(error); opened.fulfill() }
        wait(for: [opened], timeout: 10); app.activate()
        let open = app.buttons["audioFixtureOpen"]; XCTAssertTrue(open.waitForExistence(timeout: 15)); audioPress(open)
        XCTAssertTrue(app.buttons["audioRecord"].waitForExistence(timeout: 8))
    }
    @MainActor private func audioRecord(_ app: XCUIApplication) {
        let record = app.buttons["audioRecord"]; audioReveal(record, app); audioPress(record)
        let stop = app.buttons["audioStop"]
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", "Stop recording"), object: stop)], timeout: 8) == .completed)
        audioPress(stop)
        XCTAssertTrue(app.textViews["audioCaption"].waitForExistence(timeout: 10), app.debugDescription)
    }
    @MainActor private func audioScreenshot(_ app: XCUIApplication, _ name: String) {
        #if os(macOS)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        #else
        let attachment = XCTAttachment(screenshot: app.screenshot())
        #endif
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testAudioDraftReviewSavePlaybackAndColdReturn() throws {
        try audioGuard(); let app = XCUIApplication(); defer { app.terminate() }
        audioOpen(app); audioRecord(app)
        let caption = app.textViews["audioCaption"]; audioReveal(caption, app); audioPress(caption)
        caption.typeText("Review the design layout and keep the original notes.")
        #if os(iOS)
        if app.buttons["audioHideKeyboard"].exists { audioPress(app.buttons["audioHideKeyboard"]) }
        #endif
        let save = app.buttons["audioSave"]; audioReveal(save, app); audioPress(save)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ AND enabled == false", "Saved on this device"), object: save)], timeout: 8) == .completed)
        audioScreenshot(app, "Reviewed and saved audio draft")
        audioPress(app.buttons["audioSaveClose"])
        XCTAssertTrue(app.buttons["audioFixtureOpen"].waitForExistence(timeout: 8))
        app.terminate(); audioOpen(app, reset: false)
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioSaved-")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 8)); audioReveal(saved, app); audioPress(saved)
        let restored = app.textViews["audioCaption"]; XCTAssertTrue(restored.waitForExistence(timeout: 8))
        XCTAssertEqual(restored.value as? String, "Review the design layout and keep the original notes.")
        let play = app.buttons["audioPlayback"]; audioReveal(play, app); audioPress(play)
        XCTAssertEqual(play.label, "Stop playback"); audioPress(play)
        XCTAssertEqual(play.label, "Play recording")
        audioScreenshot(app, "Restored audio recording after cold launch")
        audioPress(app.buttons["audioClose"])
        XCTAssertTrue(app.buttons["audioFixtureOpen"].waitForExistence(timeout: 8))
    }
    @MainActor func testAudioDraftSyntheticPermissionRefusalDoesNotCreateRecording() throws {
        try audioGuard(); let app = XCUIApplication(); defer { app.terminate() }
        audioOpen(app, denied: true)
        audioPress(app.buttons["audioRecord"])
        let notice = app.staticTexts["audioNotice"]
        audioReveal(notice, app)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND (label CONTAINS %@ OR value CONTAINS %@)", "Microphone access is off", "Microphone access is off"), object: notice)], timeout: 8) == .completed)
        XCTAssertFalse(app.textViews["audioCaption"].exists)
        audioReveal(notice, app); audioScreenshot(app, "Audio draft synthetic permission refusal")
        audioPress(app.buttons["audioClose"])
        XCTAssertTrue(app.buttons["audioFixtureOpen"].waitForExistence(timeout: 8))
    }
    @MainActor func testAudioDraftDarkReviewControlsRemainReachable() throws {
        try audioGuard(); let app = XCUIApplication(); defer { app.terminate() }
        audioOpen(app, large: true); audioRecord(app)
        let record = app.buttons["audioRecord"], caption = app.textViews["audioCaption"]
        audioReveal(record, app); XCTAssertEqual(record.label, "Replace recording")
        audioScreenshot(app, "Mac audio review controls dark")
        audioReveal(caption, app)
        let bounds = app.sheets.count > 0 ? app.sheets.firstMatch.frame : app.windows.firstMatch.frame
        XCTAssertTrue(bounds.contains(caption.frame), app.debugDescription)
        audioScreenshot(app, "Mac audio caption dark")
        XCTAssertTrue(app.buttons["audioSaveClose"].isHittable)
        audioPress(app.buttons["audioSaveClose"])
        XCTAssertTrue(app.buttons["audioFixtureOpen"].waitForExistence(timeout: 8))
    }
    @MainActor func testAudioDraftReplacementRefusalPreservesSavedCaptionAndDuration() throws {
        try audioGuard(); let app = XCUIApplication(); defer { app.terminate() }
        audioOpen(app); audioRecord(app)
        let caption = app.textViews["audioCaption"]; audioReveal(caption, app); audioPress(caption); caption.typeText("Keep this saved recording")
        #if os(iOS)
        if app.buttons["audioHideKeyboard"].exists { audioPress(app.buttons["audioHideKeyboard"]) }
        #endif
        audioPress(app.buttons["audioSaveClose"])
        XCTAssertTrue(app.buttons["audioFixtureOpen"].waitForExistence(timeout: 8))
        app.terminate(); audioOpen(app, reset: false, denied: true)
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioSaved-")).firstMatch
        audioReveal(saved, app); audioPress(saved)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["audioSaveClose"])], timeout: 10) == .completed)
        let record = app.buttons["audioRecord"]; audioReveal(record, app); audioPress(record)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", "Replace recording"), object: record)], timeout: 8) == .completed)
        let notice = app.staticTexts["audioNotice"]; audioReveal(notice, app)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND (label CONTAINS %@ OR value CONTAINS %@)", "Microphone access is off", "Microphone access is off"), object: notice)], timeout: 8) == .completed)
        let duration = app.staticTexts["audioDuration"]; audioReveal(duration, app)
        XCTAssertEqual(duration.value as? String, "0:01")
        let restored = app.textViews["audioCaption"]; audioReveal(restored, app)
        XCTAssertEqual(restored.value as? String, "Keep this saved recording")
        audioScreenshot(app, "Refused replacement retains saved caption and duration")
        audioPress(app.buttons["audioClose"])
        XCTAssertTrue(app.buttons["audioFixtureOpen"].waitForExistence(timeout: 8))
    }

}
