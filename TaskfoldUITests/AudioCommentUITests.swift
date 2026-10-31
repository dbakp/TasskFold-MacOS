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
    @MainActor private func audioOpen(_ app: XCUIApplication, reset: Bool = true, denied: Bool = false, large: Bool = false, lostSave: Bool = false, beforeDraft: Bool = false, lostDiscard: Bool = false, lookupLock: Bool = false, prejournal: Bool = false, interrupted: Bool = false, interruptedCopy: Bool = false) {
        app.launchArguments = ["--uitesting", "--team-editor-testing", "--audio-comment-testing", "-appearance", large || denied ? "dark" : "light"]
        if reset { app.launchArguments.append("--audio-comment-reset") }
        if lostSave { app.launchArguments.append("--audio-save-lost-ack") }
        if beforeDraft { app.launchArguments.append("--audio-save-before-draft") }
        if lostDiscard { app.launchArguments.append("--audio-discard-lost-ack") }
        if lookupLock { app.launchArguments.append("--audio-save-lookup-lock") }
        if prejournal { app.launchArguments.append("--audio-save-before-journal") }
        if denied { app.launchArguments.append("--audio-comment-denied") }
        if interrupted { app.launchArguments.append("--audio-interrupted-stage-testing") }
        if interruptedCopy { app.launchArguments.append("--audio-interrupted-copy-testing") }
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
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["audioRecord"])], timeout: 10) == .completed)
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

    @MainActor func testAudioInterruptedReviewRecoversAfterColdLaunchWithoutExplicitSave() throws {
        try audioGuard(); let app = XCUIApplication(); defer { app.terminate() }
        audioOpen(app); audioRecord(app)
        let caption = app.textViews["audioCaption"]; audioReveal(caption, app); audioPress(caption)
        caption.typeText("Keep this interrupted review with its original audio.")
        #if os(iOS)
        if app.buttons["audioHideKeyboard"].exists { audioPress(app.buttons["audioHideKeyboard"]) }
        #endif
        let status = app.staticTexts["audioRecoveryStatus"]; audioReveal(status, app)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND (label == %@ OR value == %@)", "Recovery copy kept privately on this device.", "Recovery copy kept privately on this device."), object: status)], timeout: 10) == .completed)
        audioScreenshot(app, "Private recovery copy before interrupted review")
        app.terminate(); audioOpen(app, reset: false)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioSaved-")).firstMatch.exists)
        let recovery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioRecovery-")).firstMatch
        XCTAssertTrue(recovery.waitForExistence(timeout: 8)); audioReveal(recovery, app); audioPress(recovery)
        let restored = app.textViews["audioCaption"]; XCTAssertTrue(restored.waitForExistence(timeout: 10))
        audioReveal(restored, app)
        XCTAssertEqual(restored.value as? String, "Keep this interrupted review with its original audio.")
        audioScreenshot(app, "Recovered unsaved review after cold launch")
        let save = app.buttons["audioSave"]; audioReveal(save, app); audioPress(save)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ AND enabled == false", "Saved on this device"), object: save)], timeout: 10) == .completed)
        audioPress(app.buttons["audioClose"])
        XCTAssertTrue(app.buttons["audioFixtureOpen"].waitForExistence(timeout: 8))
        app.terminate(); audioOpen(app, reset: false)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioRecovery-")).firstMatch.exists)
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioSaved-")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 8)); audioReveal(saved, app); audioPress(saved)
        XCTAssertTrue(app.textViews["audioCaption"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textViews["audioCaption"].value as? String, "Keep this interrupted review with its original audio.")
    }
    @MainActor func testAudioExplicitDiscardRemovesRecoveryWithoutCreatingSavedDraft() throws {
        try audioGuard(); let app = XCUIApplication(); defer { app.terminate() }
        audioOpen(app); audioRecord(app)
        let status = app.staticTexts["audioRecoveryStatus"]; audioReveal(status, app)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND (label == %@ OR value == %@)", "Recovery copy kept privately on this device.", "Recovery copy kept privately on this device."), object: status)], timeout: 10) == .completed)
        audioPress(app.buttons["audioClose"])
        let discard = app.sheets.buttons["Discard unsaved changes"]
        XCTAssertTrue(discard.waitForExistence(timeout: 8)); audioPress(discard)
        XCTAssertTrue(app.buttons["audioFixtureOpen"].waitForExistence(timeout: 8))
        app.terminate(); audioOpen(app, reset: false)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioRecovery-")).firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioSaved-")).firstMatch.exists)
        XCTAssertFalse(app.textViews["audioCaption"].exists)
        audioScreenshot(app, "Explicitly discarded review stays discarded after relaunch")
    }

    @MainActor func testAudioPreparedSaveFinishesOnceAfterColdLaunchAtLargestText() throws {
        try audioGuard(); let app = XCUIApplication(); defer { app.terminate() }
        audioOpen(app, large: true, lostSave: true); audioRecord(app)
        let caption = app.textViews["audioCaption"]; audioReveal(caption, app); audioPress(caption)
        caption.typeText("Keep this Save exactly once")
        #if os(iOS)
        if app.buttons["audioHideKeyboard"].exists { audioPress(app.buttons["audioHideKeyboard"]) }
        #endif
        let save = app.buttons["audioSave"]; audioReveal(save, app); audioPress(save)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ AND enabled == true", "Retry save"), object: save)], timeout: 10) == .completed)
        audioScreenshot(app, "Prepared Save after lost acknowledgement")
        audioPress(app.buttons["audioClose"])
        XCTAssertTrue(app.buttons["audioFixtureOpen"].waitForExistence(timeout: 8))
        app.terminate(); audioOpen(app, reset: false, large: true)
        let pending = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioPendingSave-")).firstMatch
        audioReveal(pending, app)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioRecovery-")).firstMatch.exists)
        audioScreenshot(app, "Finish prepared Save after cold launch at largest text")
        audioPress(pending)
        XCTAssertFalse(app.sheets["Discard this pending recording?"].exists, "Finish must not also open Discard")
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["audioSaveClose"])], timeout: 12) == .completed)
        #if os(iOS)
        audioReveal(save, app, towardTop: true)
        #else
        audioReveal(save, app)
        #endif
        XCTAssertEqual(save.label, "Saved on this device"); XCTAssertFalse(save.isEnabled)
        audioPress(app.buttons["audioClose"])
        XCTAssertTrue(app.buttons["audioFixtureOpen"].waitForExistence(timeout: 8))
        app.terminate(); audioOpen(app, reset: false, large: true)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioPendingSave-")).firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioRecovery-")).firstMatch.exists)
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioSaved-"))
        audioReveal(saved.firstMatch, app); XCTAssertEqual(saved.count, 1); audioPress(saved.firstMatch)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["audioSaveClose"])], timeout: 12) == .completed)
        let restored = app.textViews["audioCaption"]
        #if os(iOS)
        audioReveal(restored, app, towardTop: true)
        #else
        audioReveal(restored, app)
        #endif
        XCTAssertEqual(restored.value as? String, "Keep this Save exactly once")
        audioScreenshot(app, "One exact saved recording after prepared Save recovery")
    }

    @MainActor func testAudioPendingDiscardSurvivesColdLaunchWithoutSavingAtLargestText() throws {
        try audioGuard(); let app = XCUIApplication(); defer { app.terminate() }
        audioOpen(app, large: true, lostSave: true, beforeDraft: true); audioRecord(app)
        let save = app.buttons["audioSave"]; audioReveal(save, app); audioPress(save)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ AND enabled == true", "Retry save"), object: save)], timeout: 10) == .completed)
        audioPress(app.buttons["audioClose"]); XCTAssertTrue(app.buttons["audioFixtureOpen"].waitForExistence(timeout: 8))
        app.terminate(); audioOpen(app, reset: false, large: true, lostDiscard: true)
        let discard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioDiscardPending-")).firstMatch
        audioReveal(discard, app); audioPress(discard)
        #if os(macOS)
        let confirm = app.sheets.buttons["audioConfirmDiscardPending"]
        #else
        let controls = app.sheets["Discard this pending recording?"].buttons.matching(identifier: "audioConfirmDiscardPending")
        XCTAssertTrue(controls.firstMatch.waitForExistence(timeout: 8))
        let count = controls.count
        XCTAssertTrue((1...2).contains(count), "One logical discard action expected")
        // UIKit exposes SwiftUI's action as a nested pair on this runtime.
        // Check it is one action before selecting its innermost control.
        if count == 2 {
            XCTAssertEqual(controls.element(boundBy: 0).frame, controls.element(boundBy: 1).frame)
            XCTAssertEqual(controls.element(boundBy: 0).label, controls.element(boundBy: 1).label)
        }
        let confirm = controls.element(boundBy: max(0, count - 1))
        #endif
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        XCTAssertFalse(app.textViews["audioCaption"].exists, "Opening discard must not also resume the Save")
        audioPress(confirm)
        let pending = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioPendingSave-")).firstMatch
        audioReveal(pending, app)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label CONTAINS[c] %@", "Finish discarding"), object: pending)], timeout: 12) == .completed)
        audioReveal(pending, app); audioScreenshot(app, "Discard kept after acknowledgement loss")
        audioPress(app.buttons["audioClose"]); XCTAssertTrue(app.buttons["audioFixtureOpen"].waitForExistence(timeout: 8))
        app.terminate(); audioOpen(app, reset: false, large: true)
        audioReveal(pending, app)
        XCTAssertTrue(pending.label.localizedCaseInsensitiveContains("Finish discarding"))
        audioScreenshot(app, "Finish durable discard after cold launch at largest text")
        audioPress(pending)
        XCTAssertFalse(app.sheets["Discard this pending recording?"].exists, "Finish must not also open Discard")
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: pending)], timeout: 10) == .completed)
        audioPress(app.buttons["audioClose"]); XCTAssertTrue(app.buttons["audioFixtureOpen"].waitForExistence(timeout: 8))
        app.terminate(); audioOpen(app, reset: false, large: true)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioPendingSave-")).firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioSaved-")).firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioRecovery-")).firstMatch.exists)
        audioScreenshot(app, "Durable discard leaves no recording after cold return")
    }
    @MainActor func testAudioPendingDiscardRefusesAlreadySavedRecording() throws {
        try audioGuard(); let app = XCUIApplication(); defer { app.terminate() }
        audioOpen(app, lostSave: true); audioRecord(app)
        let save = app.buttons["audioSave"]; audioReveal(save, app); audioPress(save)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ AND enabled == true", "Retry save"), object: save)], timeout: 10) == .completed)
        audioPress(app.buttons["audioClose"]); XCTAssertTrue(app.buttons["audioFixtureOpen"].waitForExistence(timeout: 8))
        app.terminate(); audioOpen(app, reset: false)
        let discard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioDiscardPending-")).firstMatch
        audioReveal(discard, app); audioPress(discard)
        #if os(macOS)
        let confirm = app.sheets.buttons["audioConfirmDiscardPending"]
        #else
        let controls = app.sheets["Discard this pending recording?"].buttons.matching(identifier: "audioConfirmDiscardPending")
        XCTAssertTrue(controls.firstMatch.waitForExistence(timeout: 8))
        let count = controls.count
        XCTAssertTrue((1...2).contains(count), "One logical discard action expected")
        // UIKit exposes SwiftUI's action as a nested pair on this runtime.
        // Check it is one action before selecting its innermost control.
        if count == 2 {
            XCTAssertEqual(controls.element(boundBy: 0).frame, controls.element(boundBy: 1).frame)
            XCTAssertEqual(controls.element(boundBy: 0).label, controls.element(boundBy: 1).label)
        }
        let confirm = controls.element(boundBy: max(0, count - 1))
        #endif
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        XCTAssertFalse(app.textViews["audioCaption"].exists, "Opening discard must not also resume the Save")
        audioPress(confirm)
        let notice = app.staticTexts["audioNotice"]; audioReveal(notice, app)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND (label CONTAINS[c] %@ OR value CONTAINS[c] %@)", "already saved", "already saved"), object: notice)], timeout: 10) == .completed)
        audioScreenshot(app, "Already saved recording cannot be discarded as pending")
        let pending = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioPendingSave-")).firstMatch
        audioReveal(pending, app); audioPress(pending)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["audioSaveClose"])], timeout: 12) == .completed)
        audioPress(app.buttons["audioClose"]); XCTAssertTrue(app.buttons["audioFixtureOpen"].waitForExistence(timeout: 8))
        app.terminate(); audioOpen(app, reset: false)
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioSaved-"))
        audioReveal(saved.firstMatch, app); XCTAssertEqual(saved.count, 1)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioPendingSave-")).firstMatch.exists)
        audioScreenshot(app, "Refused pending discard preserves one saved recording")
    }


    @MainActor func testAudioUnwrittenSaveSurvivesWorkspaceDepartureAndExplicitFinish() throws {
        try audioGuard(); let app = XCUIApplication(); defer { app.terminate() }
        audioOpen(app, lookupLock: true, prejournal: true); audioRecord(app)
        let caption = app.textViews["audioCaption"], wording = "Keep my original workspace recording"
        audioReveal(caption, app); audioPress(caption); caption.typeText(wording)
        #if os(iOS)
        if app.buttons["audioHideKeyboard"].exists { audioPress(app.buttons["audioHideKeyboard"]) }
        #endif
        let recovery = app.buttons["audioRetryRecovery"]
        audioReveal(recovery, app); XCTAssertTrue(recovery.exists, "The real checkpoint lock must first refuse private recovery")
        audioPress(app.buttons["audioFixtureReleaseCheckpoint"])
        let save = app.buttons["audioSave"], probe = app.staticTexts["audioFixtureLookupProbe"]
        audioReveal(save, app); audioPress(save)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Storage reads: 1 · locked"), object: probe)], timeout: 10), .completed)
        XCTAssertEqual(save.label, "Retry save")
        audioPress(app.buttons["audioFixtureResumeStorage"])
        audioPress(app.buttons["audioFixtureLeave"])
        XCTAssertTrue(app.buttons["audioFixtureOpen"].waitForExistence(timeout: 8))
        audioPress(app.buttons["audioFixtureOpen"])
        XCTAssertTrue(app.buttons["audioRecord"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.textViews["audioCaption"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioPendingSave-")).firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioRecovery-")).firstMatch.exists)
        audioScreenshot(app, "The foreign workspace exposes no original recording")
        audioPress(app.buttons["audioClose"])
        XCTAssertTrue(app.buttons["audioFixtureReturn"].waitForExistence(timeout: 8)); audioPress(app.buttons["audioFixtureReturn"])
        audioPress(app.buttons["audioFixtureOpen"])
        let pending = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioPendingSave-"))
        audioReveal(pending.firstMatch, app); XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(pending.firstMatch.label.contains(wording))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioDiscardPending-")).firstMatch.exists)
        XCTAssertFalse(app.buttons["audioRetryInterrupted"].exists, "Unwritten Save has one focused recovery action")
        audioScreenshot(app, "The original workspace offers one exact unwritten Save")
        audioPress(pending.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ AND enabled == false", "Saved on this device"), object: save)], timeout: 12), .completed)
        audioReveal(caption, app); XCTAssertEqual(caption.value as? String, wording)
        XCTAssertFalse(app.buttons["audioRetryInterrupted"].exists, "Successful Finish clears the stale recovery warning")
        audioScreenshot(app, "Explicit Finish saves the original workspace recording")
        audioPress(app.buttons["audioSaveClose"])
        XCTAssertTrue(app.buttons["audioFixtureOpen"].waitForExistence(timeout: 8))
        app.terminate(); audioOpen(app, reset: false)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioPendingSave-")).firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioRecovery-")).firstMatch.exists)
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioSaved-"))
        audioReveal(saved.firstMatch, app); XCTAssertEqual(saved.count, 1); audioPress(saved.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["audioSaveClose"])], timeout: 12), .completed)
        audioReveal(caption, app); XCTAssertEqual(caption.value as? String, wording)
        audioScreenshot(app, "Cold return retains the finished original workspace recording")
    }

    @MainActor func testAudioUnknownSaveRetryKeepsOriginalDraftAfterLockRelease() throws { try audioUnknownSaveJourney(beforeDraft: false) }
    @MainActor func testAudioUnknownPreparedSaveRetryKeepsOriginalIDsAfterLockRelease() throws { try audioUnknownSaveJourney(beforeDraft: true) }
    @MainActor func testAudioUnknownSaveColdLaunchRecoversTheOriginalAuthorization() throws { try audioUnknownSaveJourney(beforeDraft: true, coldWhileLocked: true) }
    @MainActor private func audioUnknownSaveJourney(beforeDraft: Bool, coldWhileLocked: Bool = false) throws {
        try audioGuard(); let app = XCUIApplication(); defer { app.terminate() }
        audioOpen(app, large: true, beforeDraft: beforeDraft, lookupLock: true); audioRecord(app)
        let caption = app.textViews["audioCaption"], wording = "Keep this exact retry as one recording"
        audioReveal(caption, app); audioPress(caption); caption.typeText(wording)
        #if os(iOS)
        if app.buttons["audioHideKeyboard"].exists { audioPress(app.buttons["audioHideKeyboard"]) }
        #endif
        let save = app.buttons["audioSave"], probe = app.staticTexts["audioFixtureLookupProbe"]
        func lookup(_ count: Int) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Storage reads: \(count) · locked"), object: probe)], timeout: 10), .completed)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ AND enabled == true", "Retry save"), object: save)], timeout: 10), .completed)
        }
        audioReveal(save, app); audioPress(save); lookup(1)
        audioReveal(save, app); audioPress(save); lookup(2)
        #if os(iOS)
        audioReveal(caption, app, towardTop: true)
        #else
        audioReveal(caption, app)
        #endif
        XCTAssertFalse(caption.isEnabled); XCTAssertEqual(caption.value as? String, wording)
        audioScreenshot(app, "Unknown Save remains frozen after the second real-lock refusal")
        if coldWhileLocked {
            app.terminate(); audioOpen(app, reset: false, large: true)
            let pending = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioPendingSave-"))
            audioReveal(pending.firstMatch, app); XCTAssertEqual(pending.count, 1)
            audioPress(pending.firstMatch)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["audioSaveClose"])], timeout: 12), .completed)
            #if os(iOS)
            audioReveal(save, app, towardTop: true)
            #else
            audioReveal(save, app)
            #endif
        } else {
            audioPress(app.buttons["audioFixtureResumeStorage"])
            audioReveal(save, app); audioPress(save)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ AND enabled == false", "Saved on this device"), object: save)], timeout: 12), .completed)
        audioScreenshot(app, "The original recording is saved after releasing the private lock")
        audioPress(app.buttons["audioSaveClose"])
        XCTAssertTrue(app.buttons["audioFixtureOpen"].waitForExistence(timeout: 8))
        app.terminate(); audioOpen(app, reset: false, large: true)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioPendingSave-")).firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioRecovery-")).firstMatch.exists)
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioSaved-"))
        audioReveal(saved.firstMatch, app); XCTAssertEqual(saved.count, 1); audioPress(saved.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["audioSaveClose"])], timeout: 12), .completed)
        #if os(iOS)
        audioReveal(caption, app, towardTop: true)
        #else
        audioReveal(caption, app)
        #endif
        XCTAssertEqual(caption.value as? String, wording)
        audioScreenshot(app, "Cold return retains one exact recording with no unfinished Save")
    }

}

#if os(iOS)
extension TaskfoldMacUITests {
    @MainActor func testInterruptedRecordingFilesRequireExplicitRecoveryAndSurviveColdReturn() throws {
        try audioGuard(); let app = XCUIApplication(); defer { app.terminate() }
        audioOpen(app, large: true, interrupted: true)
        XCTAssertTrue(try audioPrivateFiles().isEmpty, "Discovering staged files must not promote them")
        let warning = app.staticTexts["audioInterruptedWarning"]
        audioReveal(warning, app); XCTAssertTrue(warning.label.contains("kept"))
        audioScreenshot(app, "Interrupted recordings and kept incomplete-file warning at AX5")
        let primary = app.buttons["audioInterrupted-ac282000-0000-4000-8000-000000000001"]
        audioReveal(primary, app, towardTop: true); audioPress(primary)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: primary)], timeout: 12), .completed)
        let files = try audioPrivateFiles()
        XCTAssertEqual(files.count, 1)
        let savedFile = try XCTUnwrap(files.first)
        let original = try Data(contentsOf: savedFile)
        let fields = try XCTUnwrap(try PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any])
        XCTAssertEqual(fields["caption"] as? String, "Recovered workshop draft")
        XCTAssertFalse((fields["audio"] as? Data ?? Data()).isEmpty)
        let review = app.buttons["audioInterrupted-ac282000-0000-4000-8000-000000000002"]
        audioReveal(review, app); audioPress(review)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: review)], timeout: 12), .completed)
        let afterRecovery = try audioPrivateFiles()
        XCTAssertEqual(afterRecovery.count, 2)
        XCTAssertEqual(afterRecovery.filter { $0.lastPathComponent.hasPrefix("review-") }.count, 1, "Recovery must not save an unsaved review")
        XCTAssertEqual(try Data(contentsOf: savedFile), original)
        let recovered = app.buttons["audioRecovery-ac281000-0000-4000-8000-000000000002"]
        audioReveal(recovered, app); audioPress(recovered)
        let caption = app.textViews["audioCaption"]
        audioReveal(caption, app, towardTop: true)
        XCTAssertEqual(caption.value as? String, "Recovered workshop review")
        let save = app.buttons["audioSave"]
        audioReveal(save, app); audioPress(save)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ AND enabled == false", "Saved on this device"), object: save)], timeout: 12), .completed)
        let committed = try audioPrivateFiles()
        XCTAssertEqual(committed.count, 2)
        XCTAssertTrue(committed.allSatisfy { $0.lastPathComponent.hasPrefix("draft-") })
        XCTAssertEqual(try Data(contentsOf: savedFile), original)
        let incomplete = savedFile.deletingLastPathComponent().appendingPathComponent(".write-ac282000-0000-4000-8000-000000000003")
        XCTAssertEqual(try Data(contentsOf: incomplete), Data("Synthetic incomplete recording payload".utf8))
        audioScreenshot(app, "Explicitly reviewed interrupted recording saved locally at AX5")
        app.terminate(); audioOpen(app, reset: false, large: true)
        audioReveal(warning, app); XCTAssertTrue(warning.label.contains("kept"))
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioSaved-"))
        audioReveal(saved.firstMatch, app); XCTAssertEqual(saved.count, 2)
        let returnedReview = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "audioSaved-", "Recovered workshop review")).firstMatch
        audioReveal(returnedReview, app); audioPress(returnedReview)
        audioReveal(caption, app, towardTop: true)
        XCTAssertEqual(caption.value as? String, "Recovered workshop review")
        XCTAssertEqual(try Data(contentsOf: savedFile), original)
        XCTAssertEqual(try Data(contentsOf: incomplete), Data("Synthetic incomplete recording payload".utf8))
        XCTAssertEqual(try audioPrivateFiles().count, 2)
        audioScreenshot(app, "Cold return keeps exact recovered review and original draft")
    }
}
#endif

#if os(iOS)
extension TaskfoldMacUITests {
    @MainActor func testInterruptedKeepBothReviewCancelAndJournalColdFinish() throws {
        try audioGuard(); let app = XCUIApplication(); defer { app.terminate() }
        audioOpen(app, large: true, lostSave: true, beforeDraft: true, interruptedCopy: true)
        let original = try XCTUnwrap(try audioPrivateFiles().first), originalBytes = try Data(contentsOf: original)
        XCTAssertEqual(try audioPrivateFiles().count, 1)
        let staged = original.deletingLastPathComponent().appendingPathComponent(".write-ac282000-0000-4000-8000-000000000001")
        let stagedBytes = try Data(contentsOf: staged)
        let keep = app.buttons["audioInterruptedCopy-ac282000-0000-4000-8000-000000000001"]
        audioReveal(keep, app); audioPress(keep)
        let copyCaption = app.staticTexts["audioCopyCaption"], confirm = app.buttons["audioCopyConfirm"]
        audioReveal(copyCaption, app, formIdentifier: "audioCopyForm", navigationTitle: "Keep both")
        XCTAssertEqual(copyCaption.label, "Earlier workshop recording")
        audioScreenshot(app, "Keep both reviews full staged caption at AX5")
        audioPress(app.buttons["audioCopyCancel"])
        XCTAssertTrue(app.navigationBars["Audio draft"].waitForExistence(timeout: 8))
        XCTAssertEqual(try audioPrivateFiles().count, 1); XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertEqual(try Data(contentsOf: staged), stagedBytes)
        audioReveal(keep, app); audioPress(keep)
        audioReveal(confirm, app, formIdentifier: "audioCopyForm", navigationTitle: "Keep both"); audioPress(confirm)
        let save = app.buttons["audioSave"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", "Retry save"), object: save)], timeout: 15), .completed)
        let journal = try XCTUnwrap(try audioPrivateFiles().first { $0.lastPathComponent.hasPrefix("save-") })
        let fields = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: journal), format: nil) as? [String: Any])
        XCTAssertEqual(fields["format"] as? String, "taskfold-audio-save-v3"); XCTAssertNotNil(fields["stage"] as? Data)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes); XCTAssertEqual(try Data(contentsOf: staged), stagedBytes)
        XCTAssertEqual(try audioPrivateFiles().count, 2)
        app.terminate(); audioOpen(app, reset: false, large: true)
        let pending = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioPendingSave-"))
        audioReveal(pending.firstMatch, app); XCTAssertEqual(pending.count, 1)
        XCTAssertFalse(app.buttons["audioInterruptedCopy-ac282000-0000-4000-8000-000000000001"].exists)
        XCTAssertEqual(try audioPrivateFiles().count, 2); XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        audioScreenshot(app, "Cold return retains one explicit copy Save without replacing latest version")
        audioPress(pending.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ AND enabled == false", "Saved on this device"), object: save)], timeout: 15), .completed)
        let final = try audioPrivateFiles(); XCTAssertEqual(final.count, 2)
        XCTAssertTrue(final.allSatisfy { $0.lastPathComponent.hasPrefix("draft-") })
        XCTAssertEqual(try Data(contentsOf: original), originalBytes); XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        let copy = try XCTUnwrap(final.first { $0 != original })
        let copyBytes = try Data(contentsOf: copy), copyFields = try XCTUnwrap(try PropertyListSerialization.propertyList(from: copyBytes, format: nil) as? [String: Any])
        let originalFields = try XCTUnwrap(try PropertyListSerialization.propertyList(from: originalBytes, format: nil) as? [String: Any])
        XCTAssertEqual(copyFields["caption"] as? String, "Earlier workshop recording")
        XCTAssertEqual(copyFields["audio"] as? Data, originalFields["audio"] as? Data)
        XCTAssertNotEqual(copyFields["id"] as? String, originalFields["id"] as? String)
        app.terminate(); audioOpen(app, reset: false, large: true)
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "audioSaved-"))
        audioReveal(saved.firstMatch, app); XCTAssertEqual(saved.count, 2)
        let returned = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "audioSaved-", "Earlier workshop recording")).firstMatch
        audioReveal(returned, app); audioPress(returned)
        let caption = app.textViews["audioCaption"]; audioReveal(caption, app, towardTop: true)
        XCTAssertEqual(caption.value as? String, "Earlier workshop recording")
        XCTAssertEqual(try Data(contentsOf: original), originalBytes); XCTAssertEqual(try Data(contentsOf: copy), copyBytes)
        XCTAssertEqual(try audioPrivateFiles().count, 2)
        audioScreenshot(app, "Both exact recording versions survive explicit Finish and cold return")
    }
}
#endif

extension TaskfoldMacUITests {
    @MainActor private func conversationOpen(_ app:XCUIApplication,owner:Bool=false,short:Bool=false,large:Bool=false,extra:String?=nil) throws {
        try audioGuard()
        app.launchArguments=["--uitesting","--team-editor-testing","--audio-conversation-testing","-appearance",large ? "dark":"light","-UIPreferredContentSizeCategoryName",large ? "UICTContentSizeCategoryAccessibilityXXXL":"UICTContentSizeCategoryL"]
        if owner {app.launchArguments.append("--audio-conversation-owner")};if short {app.launchArguments.append("--audio-conversation-short")};if let extra {app.launchArguments.append(extra)}
        app.launchArguments += ["-ApplePersistenceIgnoreState","YES"]
        app.launch();app.activate()
        let open=app.buttons["audioConversationFixtureOpen"];XCTAssertTrue(open.waitForExistence(timeout:20),app.debugDescription);audioPress(open)
        XCTAssertTrue(app.buttons["audioConversationPlay-ad311000-0000-4000-8000-000000000001"].waitForExistence(timeout:12),app.debugDescription)
    }
    @MainActor private func conversationReveal(_ element:XCUIElement,_ app:XCUIApplication) {
        #if os(iOS)
        audioReveal(element,app,formIdentifier:"audioConversationForm",navigationTitle:"Audio comments")
        #else
        for _ in 0..<30 {if element.exists && element.isHittable {break};app.scrollViews.firstMatch.scroll(byDeltaX:0,deltaY:-300)}
        XCTAssertTrue(element.exists && element.isHittable,app.debugDescription)
        #endif
    }
    @MainActor func testAudioConversationReadOnlyNativePlaybackAndClose() throws {
        let app=XCUIApplication();defer{app.terminate()};try conversationOpen(app,short:true)
        let play=app.buttons["audioConversationPlay-ad311000-0000-4000-8000-000000000001"]
        conversationReveal(play,app);audioPress(play)
        XCTAssertTrue(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"label == %@","Stop recording playback"),object:play)],timeout:5) == .completed)
        audioPress(play);XCTAssertEqual(play.label,"Play recording")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","audioConversationRemove-")).count,0)
        audioScreenshot(app,"Read-only audio conversation - native controls")
        audioPress(app.buttons["audioConversationClose"])
        XCTAssertTrue(app.buttons["audioConversationFixtureOpen"].waitForExistence(timeout:5));XCTAssertTrue(app.staticTexts["audioConversationFixtureCount"].label.contains("Records kept: 2 Removals: 0 Plays: 1 Workspace active"))
    }
    @MainActor func testAudioConversationNativePaginationAndRemovalConfirmation() throws {
        let app=XCUIApplication();defer{app.terminate()};try conversationOpen(app,owner:true)
        let remove=app.buttons["audioConversationRemove-ad311000-0000-4000-8000-000000000001"]
        conversationReveal(remove,app);audioPress(remove);XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout:5));audioScreenshot(app,"Audio comment removal - explicit Cancel and Remove");audioPress(app.buttons["Cancel"])
        XCTAssertTrue(remove.waitForExistence(timeout:5));conversationReveal(remove,app);audioPress(remove)
        let confirm=app.buttons.matching(NSPredicate(format:"label == %@ AND NOT identifier BEGINSWITH %@","Remove audio comment","audioConversationRemove-")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout:5),app.debugDescription);audioPress(confirm)
        XCTAssertTrue(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:remove)],timeout:5) == .completed)
        let more=app.buttons["audioConversationMore"];conversationReveal(more,app);audioPress(more)
        let last=app.staticTexts["Design review 21"];XCTAssertTrue(last.waitForExistence(timeout:5));conversationReveal(last,app)
        XCTAssertFalse(more.exists);audioScreenshot(app,"Audio conversation - final loaded page")
        audioPress(app.buttons["audioConversationClose"]);XCTAssertTrue(app.buttons["audioConversationFixtureOpen"].waitForExistence(timeout:5));XCTAssertTrue(app.staticTexts["audioConversationFixtureCount"].label.contains("Records kept: 20 Removals: 1 Plays: 0 Workspace active"))
    }
    @MainActor func testAudioConversationLargestTextControlsAndDeniedPage() throws {
        let app=XCUIApplication();defer{app.terminate()};try conversationOpen(app,owner:true,short:true,large:true)
        for name in ["audioConversationPlay-ad311000-0000-4000-8000-000000000001","audioConversationRemove-ad311000-0000-4000-8000-000000000001"] {
            let button=app.buttons[name];conversationReveal(button,app);XCTAssertGreaterThanOrEqual(button.frame.height,44)
        }
        audioScreenshot(app,"Audio conversation - dark Accessibility XXXL")
        app.terminate();try conversationOpen(app,extra:"--audio-conversation-denied-page")
        let more=app.buttons["audioConversationMore"];conversationReveal(more,app);audioPress(more)
        let notice=app.staticTexts["audioConversationNotice"];XCTAssertTrue(notice.waitForExistence(timeout:5));conversationReveal(notice,app)
        XCTAssertTrue(notice.label.contains("no longer available"));XCTAssertFalse(app.staticTexts["No audio comments"].exists);XCTAssertFalse(app.buttons["audioConversationPlay-ad311000-0000-4000-8000-000000000001"].exists);XCTAssertFalse(more.exists)
        audioScreenshot(app,"Audio conversation - denied access clears rows")
    }
    @MainActor func testAudioConversationDepartureRejectsLatePlayback() throws {
        let app=XCUIApplication();defer{app.terminate()};try conversationOpen(app,short:true,extra:"--audio-conversation-departure")
        let play=app.buttons["audioConversationPlay-ad311000-0000-4000-8000-000000000001"];conversationReveal(play,app);audioPress(play)
        XCTAssertTrue(app.buttons["audioConversationFixtureOpen"].waitForExistence(timeout:8),app.debugDescription)
        XCTAssertTrue(app.staticTexts["audioConversationFixtureCount"].label.contains("Records kept: 2 Removals: 0 Plays: 0 Workspace closed"))
    }
    #if os(iOS)
    @MainActor func testAudioConversationVoiceOverNamesAndLiteralCaption() throws {
        guard #available(iOS 27.0,*) else {throw XCTSkip("Actual VoiceOver output requires iOS 27")}
        let voice=XCUIDevice.shared.voiceOverService,previous=voice.isEnabled,app=XCUIApplication()
        defer {try? voice.disable();if previous {try? voice.enable()};app.terminate()}
        if previous {try voice.disable()}
        try conversationOpen(app,short:true)
        try voice.enable();XCTAssertTrue(voice.isEnabled)
        var utterances:[String]=[]
        func caption()->Bool {utterances.contains{$0.localizedCaseInsensitiveContains("Design review 01")}}
        func button()->Bool {utterances.contains{$0.localizedCaseInsensitiveContains("Play recording") && $0.localizedCaseInsensitiveContains("button")}}
        if let current=try? voice.currentSpeech() {utterances.append(current.utterance)}
        for _ in 0..<50 {if caption() && button() {break};utterances.append(try voice.moveForward().utterance)}
        let attachment=XCTAttachment(data:try JSONSerialization.data(withJSONObject:["source":"XCUIVoiceOverService.Output.utterance","utterances":utterances,"captionSpoken":caption(),"playButtonSpoken":button()],options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json");attachment.lifetime = .keepAlways;add(attachment)
        XCTAssertTrue(caption(),utterances.joined(separator:"\n"));XCTAssertTrue(button(),utterances.joined(separator:"\n"))
    }
    #endif
    @MainActor func testUnifiedConversationTimelinePlaybackRemovalAndTextPreservation() throws {
        let app=XCUIApplication();defer{app.terminate()}
        try conversationOpen(app,owner:true,short:true,extra:"--audio-timeline-testing")
        let before=app.staticTexts["Shared text before the recording"],after=app.staticTexts["Shared text after the recording"]
        XCTAssertTrue(before.waitForExistence(timeout:5))
        let play=app.buttons["audioConversationPlay-ad311000-0000-4000-8000-000000000001"]
        XCTAssertLessThan(before.frame.minY,play.frame.minY)
        audioPress(play)
        XCTAssertTrue(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"label == %@","Stop recording playback"),object:play)],timeout:5) == .completed)
        audioPress(play);XCTAssertEqual(play.label,"Play recording")
        let remove=app.buttons["audioConversationRemove-ad311000-0000-4000-8000-000000000001"]
        #if os(iOS)
        for _ in 0..<8 {if remove.isHittable {break};app.scrollViews["timelineFixtureScroll"].swipeUp()}
        #endif
        audioPress(remove);XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout:5));audioPress(app.buttons["Cancel"])
        XCTAssertTrue(remove.waitForExistence(timeout:5));audioPress(remove)
        let confirm=app.buttons.matching(identifier:"audioConversationConfirmRemove").firstMatch;XCTAssertTrue(confirm.waitForExistence(timeout:5));audioPress(confirm)
        XCTAssertTrue(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:remove)],timeout:5) == .completed)
        XCTAssertTrue(before.exists);XCTAssertTrue(after.exists)
        audioScreenshot(app,"Unified timeline - audio removal preserves shared text")
        audioPress(app.buttons["timelineFixtureClose"])
        let count=app.staticTexts["audioConversationFixtureCount"];XCTAssertTrue(count.waitForExistence(timeout:5))
        #if os(iOS)
        XCTAssertEqual(count.label,"Records kept: 1");XCTAssertEqual(app.staticTexts["audioConversationFixtureRemovals"].label,"Removals: 1")
        #else
        XCTAssertTrue(count.label.contains("Records kept: 1 Removals: 1 Plays: 1 Workspace active"))
        #endif
    }
    @MainActor func testUnifiedConversationTimelineAccessLossPreservesTextAndRejectsPlayback() throws {
        let app=XCUIApplication();defer{app.terminate()};try audioGuard()
        app.launchArguments=["--uitesting","--team-editor-testing","--audio-conversation-testing","--audio-conversation-short","--audio-timeline-testing","--audio-conversation-departure"]
        app.launch();let open=app.buttons["audioConversationFixtureOpen"];XCTAssertTrue(open.waitForExistence(timeout:20));audioPress(open)
        let play=app.buttons["audioConversationPlay-ad311000-0000-4000-8000-000000000001"];XCTAssertTrue(play.waitForExistence(timeout:10));audioPress(play)
        XCTAssertTrue(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:play)],timeout:5) == .completed)
        XCTAssertTrue(app.staticTexts["Shared text before the recording"].exists);XCTAssertTrue(app.staticTexts["Shared text after the recording"].exists)
        audioScreenshot(app,"Unified timeline - lost audio access clears recordings and retains text")
        audioPress(app.buttons["timelineFixtureClose"])
        let count=app.staticTexts["audioConversationFixtureCount"];XCTAssertTrue(count.waitForExistence(timeout:5))
        #if os(iOS)
        XCTAssertEqual(count.label,"Records kept: 2");XCTAssertEqual(app.staticTexts["audioConversationFixturePlays"].label,"Plays: 0")
        #else
        XCTAssertTrue(count.label.contains("Records kept: 2 Removals: 0 Plays: 0 Workspace closed"))
        #endif
    }

}

extension TaskfoldMacUITests {
    @MainActor private func ownerVoiceDisabled() throws -> Bool {
        try audioGuard()
        #if os(iOS)
        if #available(iOS 27.0, *) {
            let voice = XCUIDevice.shared.voiceOverService, previous = voice.isEnabled
            if previous { try voice.disable() }; return previous
        }
        #endif
        return false
    }
    @MainActor private func ownerRestoreVoice(_ enabled: Bool) {
        #if os(iOS)
        if #available(iOS 27.0, *) {
            let voice = XCUIDevice.shared.voiceOverService
            if enabled { try? voice.enable() } else { try? voice.disable() }
        }
        #endif
    }
    @MainActor private func ownerReviewOpen(_ app: XCUIApplication, reset: Bool = true, large: Bool = false, extra: String? = nil) throws {
        try audioGuard()
        app.launchArguments = ["--uitesting", "--team-editor-testing", "--audio-owner-review-testing", "-appearance", large ? "dark" : "light", "-UIPreferredContentSizeCategoryName", large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        if reset { app.launchArguments.append("--audio-owner-reset") }; if let extra { app.launchArguments.append(extra) }
        app.launch(); app.activate()
        let open = app.buttons["audioOwnerFixtureOpen"]; XCTAssertTrue(open.waitForExistence(timeout: 20), app.debugDescription); audioPress(open)
        XCTAssertTrue(app.buttons["audioPendingDismiss"].waitForExistence(timeout: 12), app.debugDescription)
        ownerReveal(app.buttons["audioPendingPlay"], app)
    }
    @MainActor private func ownerReveal(_ element: XCUIElement, _ app: XCUIApplication, towardTop: Bool = false) {
        #if os(iOS)
        audioReveal(element, app, towardTop: towardTop, formIdentifier: "audioPendingForm", navigationTitle: "Publication review")
        #else
        for _ in 0..<30 { if element.exists && element.isHittable { break }; app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: towardTop ? 250 : -250) }
        XCTAssertTrue(element.exists && element.isHittable, app.debugDescription)
        #endif
    }
    @MainActor private func ownerSaved(_ app: XCUIApplication, _ expected: String, requests: String) {
        audioPress(app.buttons["audioPendingDismiss"])
        let saved = app.staticTexts["audioOwnerFixtureSaved"]
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: saved)], timeout: 8) == .completed, app.debugDescription)
        XCTAssertEqual(app.staticTexts["audioOwnerFixtureRequests"].label, requests)
    }
    @MainActor func testAudioOwnerReviewCheckCloseCancelColdAndPrivateRemoval() throws {
        let voiceWasOn = try ownerVoiceDisabled(); let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate(); self.ownerRestoreVoice(voiceWasOn) }; try ownerReviewOpen(app, large: true)
        ownerReveal(app.staticTexts["Original task unavailable"], app)
        XCTAssertFalse(app.buttons["audioPendingResume"].exists)
        let check = app.buttons["audioPendingRetry"]; ownerReveal(check, app); XCTAssertGreaterThanOrEqual(check.frame.height, 44); audioPress(check)
        let notice = app.staticTexts["audioPendingNotice"]; ownerReveal(notice, app); XCTAssertTrue(notice.label.localizedCaseInsensitiveContains("still unconfirmed"))
        ownerReveal(notice, app); audioScreenshot(app, "Sender metadata check at largest text")
        let close = app.buttons["audioPendingCloseOriginal"]; ownerReveal(close, app); audioPress(close)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); audioPress(app.alerts.buttons["Cancel"])
        ownerReveal(check, app, towardTop: true)
        ownerReveal(close, app); audioPress(close); audioPress(app.alerts.buttons.matching(identifier: "audioPendingConfirm").firstMatch)
        ownerReveal(app.buttons["audioPendingRemove"], app); XCTAssertFalse(check.exists)
        ownerReveal(notice, app); XCTAssertTrue(notice.label.contains("Original publication closed")); audioScreenshot(app, "Closed original retains private recording")
        ownerSaved(app, "Closed · private audio kept", requests: "Checks: 2 · closures: 1 · uploads: 0")
        app.terminate(); try ownerReviewOpen(app, reset: false, large: true)
        XCTAssertFalse(app.buttons["audioPendingRetry"].exists); XCTAssertFalse(app.buttons["audioPendingResume"].exists)
        let remove = app.buttons["audioPendingRemove"]; ownerReveal(remove, app); audioPress(remove); audioPress(app.alerts.buttons["Cancel"])
        ownerReveal(app.buttons["audioPendingPlay"], app, towardTop: true)
        ownerReveal(remove, app); audioPress(remove); audioPress(app.alerts.buttons.matching(identifier: "audioPendingConfirm").firstMatch)
        let saved = app.staticTexts["audioOwnerFixtureSaved"]; XCTAssertTrue(saved.waitForExistence(timeout: 8))
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Closed · private audio removed"), object: saved)], timeout: 8) == .completed)
        XCTAssertEqual(app.staticTexts["audioOwnerFixtureRequests"].label, "Checks: 0 · closures: 0 · uploads: 0")
    }
    @MainActor func testAudioOwnerReviewCloseKeepsPublishedHistory() throws {
        let voiceWasOn = try ownerVoiceDisabled(); let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate(); self.ownerRestoreVoice(voiceWasOn) }; try ownerReviewOpen(app, extra: "--audio-owner-published")
        let close = app.buttons["audioPendingCloseOriginal"]; ownerReveal(close, app); audioPress(close); audioPress(app.alerts.buttons.matching(identifier: "audioPendingConfirm").firstMatch)
        ownerReveal(app.buttons["audioPendingRemove"], app); XCTAssertTrue(app.staticTexts["This device kept the server confirmation"].exists)
        ownerSaved(app, "Published · private audio kept", requests: "Checks: 1 · closures: 1 · uploads: 0")
    }
    @MainActor func testAudioOwnerReviewResumeNeedsSeparateConfirmation() throws {
        let voiceWasOn = try ownerVoiceDisabled(); let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate(); self.ownerRestoreVoice(voiceWasOn) }; try ownerReviewOpen(app, extra: "--audio-owner-resumable")
        let resume = app.buttons["audioPendingResume"]; ownerReveal(resume, app); audioPress(resume); audioPress(app.alerts.buttons["Cancel"])
        ownerSaved(app, "Pending · private audio kept", requests: "Checks: 0 · closures: 0 · uploads: 0")
        audioPress(app.buttons["audioOwnerFixtureOpen"]); XCTAssertTrue(app.buttons["audioPendingPlay"].waitForExistence(timeout: 8))
        ownerReveal(resume, app); audioPress(resume); audioPress(app.alerts.buttons.matching(identifier: "audioPendingConfirm").firstMatch)
        ownerReveal(app.buttons["audioPendingRemove"], app)
        ownerSaved(app, "Published · private audio kept", requests: "Checks: 0 · closures: 0 · uploads: 1")
    }
    @MainActor func testAudioOwnerReviewFailedCheckPreservesOriginal() throws {
        let voiceWasOn = try ownerVoiceDisabled(); let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate(); self.ownerRestoreVoice(voiceWasOn) }; try ownerReviewOpen(app, extra: "--audio-owner-error")
        let check = app.buttons["audioPendingRetry"]; ownerReveal(check, app); audioPress(check)
        let notice = app.staticTexts["audioPendingNotice"]; ownerReveal(notice, app); XCTAssertTrue(notice.label.contains("private recording is preserved"))
        XCTAssertFalse(app.buttons["audioPendingRemove"].exists)
        ownerSaved(app, "Pending · private audio kept", requests: "Checks: 1 · closures: 0 · uploads: 0")
    }
}

#if os(iOS)
extension TaskfoldMacUITests {
    @MainActor func testAudioOwnerReviewVoiceOverStatusResult() throws {
        try audioGuard()
        guard #available(iOS 27.0, *) else { throw XCTSkip("System VoiceOver output requires iOS 27") }
        let voice = XCUIDevice.shared.voiceOverService, previous = voice.isEnabled, app = XCUIApplication()
        addTeardownBlock { @MainActor in
            app.terminate()
            if previous && !voice.isEnabled { try voice.enable() }
            if !previous && voice.isEnabled { try voice.disable() }
            XCTAssertEqual(voice.isEnabled, previous)
        }
        if previous { try voice.disable() }
        try ownerReviewOpen(app, extra: "--audio-owner-wait-for-voiceover")
        let check = app.buttons["audioPendingRetry"]; ownerReveal(check, app)
        audioPress(check)
        try voice.enable(); XCTAssertTrue(voice.isEnabled)
        let initialSpeech = try voice.currentSpeech().utterance
        let ready = try audioTaskHome().appendingPathComponent("Library/Application Support/TaskfoldAudioNative/owner-review/voiceover-ready")
        try Data("ready".utf8).write(to: ready, options: .atomic)
        var utterance = ""
        let result = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            utterance = (try? voice.currentSpeech().utterance) ?? ""
            return utterance.localizedCaseInsensitiveContains("still unconfirmed") && utterance.localizedCaseInsensitiveContains("did not upload audio")
        }, object: nil)
        let announced = XCTWaiter.wait(for: [result], timeout: 12) == .completed
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: ["source": "XCUIVoiceOverService.Output.utterance", "initialSpeech": initialSpeech, "statusResult": utterance], options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "Sender status VoiceOver output"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(announced, utterance)
        try voice.disable()
        ownerSaved(app, "Pending · private audio kept", requests: "Checks: 1 · closures: 0 · uploads: 0")
    }
}
#endif

import XCTest
#if os(macOS)
import AppKit
#endif

extension TaskfoldMacUITests {
    @MainActor private func childGuard() throws {
        let allowed = ["com.dbakp.taskfold.mac.workflowteststeameditbridge.runner", "com.dbakp.taskfold.mac.workflowteststeameditbridge.runner.xctrunner", "com.dbakp.taskfold.workflowteststeameditbridge.uitests.xctrunner"]
        guard allowed.contains(Bundle.main.bundleIdentifier ?? "") else { throw XCTSkip("Reserved child field host required") }
        continueAfterFailure = false
    }
    @MainActor private func childPress(_ value: XCUIElement) {
        XCTAssertTrue(value.waitForExistence(timeout: 12))
        #if os(macOS)
        value.click()
        #else
        value.tap()
        #endif
    }
    @MainActor private func childOpen(_ app: XCUIApplication, reset: Bool = true, extra: String? = nil, large: Bool = false) throws {
        try childGuard()
        let voiceWasOn = try ownerVoiceDisabled()
        addTeardownBlock { @MainActor in self.ownerRestoreVoice(voiceWasOn) }
        app.launchArguments = ["--uitesting", "--team-editor-testing", "--child-fields-native", "-appearance", "dark", "-UIPreferredContentSizeCategoryName", large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        if reset { app.launchArguments.append("--child-fields-native-reset") }; if let extra { app.launchArguments.append(extra) }
        if extra?.hasPrefix("--child-structure") == true, extra != "--child-structure-native" { app.launchArguments.append("--child-structure-native") }
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        // Like launchHeadingWorkspace, normal Launch Services reopening creates
        // the SwiftUI workspace window that XCTest activation alone can omit.
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: "com.dbakp.taskfold.mac.workflowteststeameditbridge")
        XCTAssertEqual(instances.count, 1)
        let url = try XCTUnwrap(instances.first?.bundleURL)
        let expected = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Taskfold.app")
        XCTAssertEqual(url.resolvingSymlinksInPath(), expected.resolvingSymlinksInPath(), "Only the current isolated product may be tested")
        let opened = expectation(description: "Open isolated child workspace")
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true; configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in XCTAssertNil(error); opened.fulfill() }
        wait(for: [opened], timeout: 10)
        app.activate(); XCTAssertTrue(app.buttons[extra?.hasPrefix("--child-adoption") == true ? "childNativeAdoption" : (extra?.hasPrefix("--child-structure") == true || extra?.hasPrefix("--child-transfer") == true) ? "childNativeStructure" : "childNativeEditor"].waitForExistence(timeout: 25), app.debugDescription)
    }
    @MainActor private func childField(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    @MainActor private func childType(_ text: String, _ field: XCUIElement) {
        childPress(field)
        #if os(macOS)
        field.typeKey("a", modifierFlags: .command)
        #else
        let app = XCUIApplication(); field.press(forDuration: 1)
        var select = app.menuItems["Select All"].firstMatch
        for _ in 0..<8 {
            if select.waitForExistence(timeout: 1), select.isHittable { break }
            let button = app.buttons["Select All"].firstMatch
            if button.exists, button.isHittable { select = button; break }
            let next = app.buttons["Next Page"].firstMatch
            guard next.exists, next.isEnabled else { break }; next.tap()
        }
        XCTAssertTrue(select.exists && select.isHittable, app.debugDescription); select.tap()
        #endif
        field.typeText(text); XCTAssertEqual(field.value as? String, text)
    }
    @MainActor private func childSavedText(_ value: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", value, value)).firstMatch
    }
    @MainActor private func childReveal(_ value: XCUIElement, _ app: XCUIApplication, towardTop initialDirection: Bool = false, diagnosticText: Bool = false) {
        _ = value.waitForExistence(timeout: 2)
        func area() -> CGRect {
            let form = app.collectionViews.allElementsBoundByIndex.last(where: { $0.exists && $0.isHittable }) ?? ["reminderSpecForm", "teamRemindersForm", "childFieldEditorForm"].map { childField($0, app) }.first { $0.exists && $0.isHittable }
            let bounds = form?.frame ?? app.frame
            let top = max(bounds.minY, app.navigationBars.allElementsBoundByIndex.last(where: { !$0.frame.isEmpty })?.frame.maxY ?? bounds.minY)
            let keyboard = app.keyboards.firstMatch
            var bottom = min(bounds.maxY, keyboard.exists && !keyboard.frame.isEmpty ? keyboard.frame.minY : bounds.maxY)
            #if os(iOS)
            // A docked native search field can cover content inside List's frame.
            let search = app.searchFields["Find a task"]
            if search.exists, !search.frame.isEmpty, search.frame.minY > bounds.midY {
                bottom = min(bottom, search.frame.minY - 4)
            }
            #endif
            // A first List row can begin exactly below the native navigation bar.
            // The adoption warning must fit below that bar; it cannot acquire
            // extra top padding by scrolling beyond the beginning of the list.
            let topInset: CGFloat = app.navigationBars["Subtask storage"].exists ? 0.0 : 4.0
            return CGRect(x: bounds.minX + 4, y: top + topInset, width: bounds.width - 8, height: max(0, bottom - top - topInset - 4))
        }
        func visible() -> Bool {
            guard value.exists, !value.frame.isEmpty else { return false }
            #if os(iOS)
            let viewport = area()
            // Reading a static label does not require a tappable hit target.
            // Geometry still verifies the complete text, or a scrollable slice
            // for diagnostic paragraphs taller than the available viewport.
            if diagnosticText {
                return value.frame.height > viewport.height ? value.frame.intersection(viewport).height >= 24 : viewport.contains(value.frame)
            }
            return value.isHittable && viewport.contains(value.frame)
            #else
            return value.isHittable
            #endif
        }
        for attempt in 0..<24 {
            if visible() { return }
            let viewport = area()
            let towardTop = value.exists && !value.frame.isEmpty ? value.frame.midY < viewport.midY : (attempt < 12 ? initialDirection : !initialDirection)
            #if os(macOS)
            let scroll = app.sheets.scrollViews.firstMatch.exists ? app.sheets.scrollViews.firstMatch : app.scrollViews.firstMatch
            scroll.scroll(byDeltaX: 0, deltaY: towardTop ? 200 : -200)
            #else
            XCTAssertGreaterThan(viewport.height, 40, app.debugDescription)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let x = viewport.minX + 20 - app.frame.minX
            let from = viewport.minY + viewport.height * (towardTop ? 0.25 : 0.8) - app.frame.minY
            let to = viewport.minY + viewport.height * (towardTop ? 0.8 : 0.25) - app.frame.minY
            origin.withOffset(CGVector(dx: x, dy: from)).press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x, dy: to)), withVelocity: .slow, thenHoldForDuration: 0.1)
            #endif
        }
        XCTAssertTrue(visible(), app.debugDescription)
    }
    @MainActor private func childHomePress(_ identifier: String, _ app: XCUIApplication) {
        let button = app.buttons[identifier]; childReveal(button, app, towardTop: true); childPress(button)
    }
    @MainActor private func childDone(_ app: XCUIApplication) {
        #if os(macOS)
        // Native nested sheets can report the covered sheet's button hittable.
        // Dismiss the frontmost sheet, rather than a Done button behind it.
        let done = app.sheets.allElementsBoundByIndex.last?.buttons.matching(identifier: "Done").firstMatch
            ?? app.buttons.matching(identifier: "Done").allElementsBoundByIndex.first { $0.isHittable }
        #else
        let done = app.buttons.matching(identifier: "Done").allElementsBoundByIndex.first { $0.isHittable }
        #endif
        XCTAssertNotNil(done, app.debugDescription); if let done { childPress(done) }
    }
    @MainActor private func childProbe(_ app: XCUIApplication, _ text: String) {
        let probe = app.staticTexts[text.hasPrefix("structure") ? "childNativeStructureProbe" : "childNativeProbe"]; childReveal(probe, app, diagnosticText: true)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text), object: probe)], timeout: 12) == .completed, app.debugDescription)
    }
    @MainActor private func childSave(_ app: XCUIApplication, title: String) {
        childHomePress("childNativeEditor", app)
        let field = childField("independentChildTitle", app); childReveal(field, app)
        childType(title, field)
        let save = app.buttons["saveIndependentChildFields"]; childReveal(save, app); childPress(save)
        childSavedNoticeVisible(app)
    }
    @MainActor private func childSavedNoticeVisible(_ app: XCUIApplication, name: String = "child-field-saved-editor") {
        let status = app.staticTexts["independentChildSaveStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), app.debugDescription); XCTAssertTrue((status.label + (status.value as? String ?? "")).contains("Saved on this device"), app.debugDescription)
        #if os(iOS)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)], timeout: 8) == .completed, app.debugDescription)
        let form = childField("childFieldEditorForm", app)
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard status.exists, status.isHittable, form.exists else { return false }
            let top = app.navigationBars.allElementsBoundByIndex.last(where: { !$0.frame.isEmpty })?.frame.maxY ?? form.frame.minY
            return status.frame.minY >= top - 2 && status.frame.maxY <= form.frame.maxY + 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 12), .completed, app.debugDescription)
        #endif
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor private func completionReadyPress(_ value: XCUIElement, _ app: XCUIApplication) {
        childReveal(value, app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: value)], timeout: 15), .completed, app.debugDescription)
        childPress(value)
    }
    @MainActor private func completionMessage(_ text: String, _ app: XCUIApplication, recovery: Bool = false) {
        let status = app.staticTexts[recovery ? "childCompletionRecoveryStatus" : "childCompletionStatus"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text), object: status)], timeout: 15), .completed, app.debugDescription)
        childReveal(status, app, diagnosticText: true)
    }
    @MainActor private func stopSavedCompletion(_ app: XCUIApplication) {
        let stop = app.buttons["Check and stop if pending"]; childReveal(stop, app); childPress(stop)
        childPress(app.buttons["Check and stop"])
    }
    @MainActor func testChildCompletionNativeReopenAndUndoRestoreOriginalTime() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app)
        childHomePress("childNativeEditor", app)
        let action = app.buttons["childCompletionAction"]; completionReadyPress(action, app); completionMessage("Completion confirmed", app)
        childDone(app); childProbe(app, "completionConfirmed=1 completionClosed=0 completionWrites=1 completionRequests=1 done=true")
        let probe = app.staticTexts["childNativeProbe"], contents = probe.label + (probe.value as? String ?? "")
        let stamp = try XCTUnwrap(contents.components(separatedBy: "stamp=").last?.components(separatedBy: .whitespacesAndNewlines).first)
        XCTAssertNotEqual(stamp, "none"); XCTAssertTrue(stamp.contains("T"))
        childHomePress("childNativeEditor", app)
        XCTAssertTrue(action.waitForExistence(timeout: 12)); XCTAssertTrue(action.label.contains("Reopen"), app.debugDescription)
        completionReadyPress(action, app); completionMessage("Reopened", app)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = "Subtask reopened with current state"; shot.lifetime = .keepAlways; add(shot)
        completionReadyPress(app.buttons["childCompletionUndo"], app); completionMessage("Undo confirmed", app)
        childDone(app); childProbe(app, "completionConfirmed=3 completionClosed=0 completionWrites=3 completionRequests=3 done=true")
        childProbe(app, "stamp=" + stamp)
        app.terminate(); try childOpen(app, reset: false); childProbe(app, "stamp=" + stamp)
        childProbe(app, "completionConfirmed=3 completionClosed=0 completionWrites=3 completionRequests=3 done=true")
    }
    @MainActor func testChildCompletionNativeStopReviewFreshReplacementAndNoOp() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app)
        childHomePress("childNativeQueueCompletion", app)
        childProbe(app, "completionQueued=1 completionAttempted=0 completionConfirmed=0 completionClosed=0 completionWrites=0 completionRequests=0")
        childHomePress("childNativeCompletionRecovery", app); stopSavedCompletion(app)
        completionMessage("stopped before applying", app, recovery: true)
        XCTAssertTrue(childSavedText("Stopped · cannot send again", app).waitForExistence(timeout: 12))
        childDone(app); childProbe(app, "completionClosed=1 completionWrites=0 completionRequests=0 done=false")
        childProbe(app, "completionCloses=1")
        app.terminate(); try childOpen(app, reset: false)
        childHomePress("childNativeCompletionRecovery", app)
        let review = app.buttons["Review a fresh action"]; childReveal(review, app); childPress(review)
        XCTAssertTrue(childSavedText("Prepare the review", app).waitForExistence(timeout: 12), app.debugDescription)
        let save = app.buttons["Save fresh action"]; childReveal(save, app); childPress(save)
        let send = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sendChildCompletion-")).firstMatch
        childReveal(send, app)
        XCTAssertTrue(send.waitForExistence(timeout: 12), app.debugDescription)
        childDone(app); childProbe(app, "completionQueued=1 completionAttempted=0 completionConfirmed=0 completionClosed=1 completionWrites=0 completionRequests=0")
        childHomePress("childNativeCompletionRecovery", app)
        let current = app.buttons["Review current subtask"]; childReveal(current, app); childPress(current)
        XCTAssertTrue(childSavedText("Prepare the review", app).waitForExistence(timeout: 12), app.debugDescription)
        completionReadyPress(app.buttons["reviewSendChildCompletion"], app)
        completionMessage("Completion confirmed", app, recovery: true)
        childReveal(review, app, towardTop: true); childPress(review)
        XCTAssertTrue(childSavedText("This subtask is already completed. No new action is needed.", app).waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertFalse(save.isEnabled, app.debugDescription)
        XCTAssertFalse(app.staticTexts["childCompletionReviewStatus"].exists, "A new review must not repeat the parent’s prior confirmation")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = "Closed action reviews current completed subtask without another write"; shot.lifetime = .keepAlways; add(shot)
        childDone(app); childDone(app)
        childProbe(app, "completionQueued=0 completionAttempted=0 completionConfirmed=1 completionClosed=1 completionWrites=1 completionRequests=1 done=true")
        app.terminate(); try childOpen(app, reset: false)
        childProbe(app, "completionConfirmed=1 completionClosed=1 completionWrites=1 completionRequests=1 done=true")
    }
    @MainActor func testChildCompletionNativeCheckAppliedAfterLostReply() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app, extra: "--child-completion-lose-reply")
        childHomePress("childNativeEditor", app); completionReadyPress(app.buttons["childCompletionAction"], app)
        completionMessage("couldn’t be confirmed", app); childDone(app)
        childProbe(app, "completionAttempted=1 completionConfirmed=0 completionClosed=0 completionWrites=1 completionRequests=1")
        app.terminate(); try childOpen(app, reset: false)
        childHomePress("childNativeCompletionRecovery", app); stopSavedCompletion(app)
        completionMessage("already applied", app, recovery: true)
        XCTAssertTrue(childSavedText("Confirmed · task may have changed since", app).waitForExistence(timeout: 12), app.debugDescription)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = "Uncertain completion resolves to its original confirmation"; shot.lifetime = .keepAlways; add(shot)
        childDone(app)
        childProbe(app, "completionAttempted=0 completionConfirmed=1 completionClosed=0 completionWrites=1 completionRequests=1 done=true")
        childProbe(app, "completionCloses=1")
    }
    @MainActor private func completionProbeInteger(_ name: String, _ app: XCUIApplication) throws -> Int {
        let probe = app.staticTexts["childNativeProbe"], text = probe.label + (probe.value as? String ?? "")
        let value = text.components(separatedBy: name + "=").last?.components(separatedBy: .whitespacesAndNewlines).first
        return try XCTUnwrap(value.flatMap(Int.init), "Missing synthetic probe value: " + name)
    }
    @MainActor func testChildCompletionNativeSustainedHistoryAndBatchedNames() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app)
        childHomePress("childNativeExerciseHistory", app)
        let probe = app.staticTexts["childNativeProbe"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "(label CONTAINS %@ AND label CONTAINS %@) OR (value CONTAINS %@ AND value CONTAINS %@)", "completionConfirmed=64 completionClosed=0 completionWrites=70 completionRequests=70 done=false", "history=70", "completionConfirmed=64 completionClosed=0 completionWrites=70 completionRequests=70 done=false", "history=70"), object: probe)], timeout: 120), .completed, app.debugDescription)
        childProbe(app, "completionConfirmed=64 completionClosed=0 completionWrites=70 completionRequests=70 done=false")
        let before = try completionProbeInteger("childReads", app)
        childHomePress("childNativeCompletionRecovery", app)
        XCTAssertTrue(childSavedText("Prepare the review", app).waitForExistence(timeout: 15), app.debugDescription)
        #if os(iOS)
        let list = try XCTUnwrap(app.collectionViews.allElementsBoundByIndex.last { $0.exists && $0.isHittable })
        list.swipeUp(); list.swipeUp()
        #else
        app.scrollViews.allElementsBoundByIndex.last?.scroll(byDeltaX: 0, deltaY: -700)
        #endif
        childDone(app); childProbe(app, "childReads=\(before + 1)")
        app.terminate(); try childOpen(app, reset: false)
        childProbe(app, "completionConfirmed=64 completionClosed=0 completionWrites=70 completionRequests=70 done=false")
        childHomePress("childNativeEditor", app); completionReadyPress(app.buttons["childCompletionUndo"], app)
        completionMessage("Undo confirmed", app)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = "Recent Undo survives sustained completion history"; shot.lifetime = .keepAlways; add(shot)
        childDone(app); childProbe(app, "completionConfirmed=64 completionClosed=0 completionWrites=71 completionRequests=71 done=true")
    }
    @MainActor func testChildCompletionNativeUndoPreservesUnsentFields() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app)
        childHomePress("childNativeEditor", app)
        let title = childField("independentChildTitle", app); childReveal(title, app); childType("Unsent premium review draft", title)
        let action = app.buttons["childCompletionAction"]; completionReadyPress(action, app)
        let status = app.staticTexts["childCompletionStatus"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Completion confirmed", "Completion confirmed"), object: status)], timeout: 15), .completed, app.debugDescription)
        #if os(iOS)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 8), "Completion should dismiss the keyboard without saving the title draft")
        #endif
        let undo = app.buttons["childCompletionUndo"]; completionReadyPress(undo, app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Undo confirmed", "Undo confirmed"), object: status)], timeout: 15), .completed, app.debugDescription)
        childReveal(title, app, towardTop: true); XCTAssertEqual(title.value as? String, "Unsent premium review draft")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = "Subtask completion and preserved draft"; shot.lifetime = .keepAlways; add(shot)
        childDone(app); childProbe(app, "completionConfirmed=2 completionClosed=0 completionWrites=2 completionRequests=2 done=false notes=Original saved notes")
        childProbe(app, "current=Prepare the review")
        app.terminate(); try childOpen(app, reset: false)
        childProbe(app, "completionConfirmed=2 completionClosed=0 completionWrites=2 completionRequests=2 done=false")
    }
    @MainActor func testChildCompletionNativeLostReplyColdRetryOnce() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app, extra: "--child-completion-lose-reply")
        childHomePress("childNativeEditor", app)
        let action = app.buttons["childCompletionAction"]; completionReadyPress(action, app)
        let status = app.staticTexts["childCompletionStatus"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "couldn’t be confirmed", "couldn’t be confirmed"), object: status)], timeout: 15), .completed, app.debugDescription)
        childDone(app); childProbe(app, "completionAttempted=1 completionConfirmed=0 completionClosed=0 completionWrites=1 completionRequests=1")
        app.terminate(); try childOpen(app, reset: false)
        childHomePress("childNativeCompletionRecovery", app)
        let retry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sendChildCompletion-")).firstMatch
        childReveal(retry, app); childPress(retry)
        XCTAssertTrue(childSavedText("Confirmed · task may have changed since", app).waitForExistence(timeout: 15), app.debugDescription)
        childDone(app); childProbe(app, "completionAttempted=0 completionConfirmed=1 completionClosed=0 completionWrites=1 completionRequests=2 done=true")
    }
    @MainActor func testChildFieldsNativeSaveSendColdReceipt() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app)
        childSave(app, title: "Review the polished child screen")
        childDone(app); childProbe(app, "queued=1 attempted=0 confirmed=0 writes=0")
        childHomePress("childNativeRecovery", app)
        let send = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sendChildField-")).firstMatch
        childReveal(send, app); childPress(send)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "childFieldPhase-", "Confirmed", "Confirmed")).firstMatch.waitForExistence(timeout: 12), app.debugDescription)
        childDone(app); childProbe(app, "confirmed=1 writes=1 requests=1 current=Review the polished child screen")
        app.terminate(); try childOpen(app, reset: false); childProbe(app, "confirmed=1 writes=1 requests=1")
        childHomePress("childNativeRecovery", app)
        XCTAssertTrue(childSavedText("Review the polished child screen", app).waitForExistence(timeout: 10), app.debugDescription); XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sendChildField-")).firstMatch.exists)
    }

    @MainActor private func childPausedRecoveryLaunch(_ app: XCUIApplication, reset: Bool, draftOnly: Bool = false) throws {
        try childGuard()
        app.launchArguments = ["--uitesting", "--team-editor-testing", "--child-fields-native", "--child-fields-main-list", "--child-recovery-paused", "-appearance", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL", "-ApplePersistenceIgnoreState", "YES"]
        if reset { app.launchArguments.append("--child-fields-native-reset") }
        if draftOnly { app.launchArguments.append("--child-recovery-draft-only") }
        else { app.launchArguments.append("--child-transfer-native") }
        app.launch(); app.activate()
        #if os(macOS)
        throw XCTSkip("Paused Mac recovery uses authorized direct computer use")
        #else
        let settings = app.buttons["openSettings"]; XCTAssertTrue(settings.waitForExistence(timeout: 30), app.debugDescription); childPress(settings)
        let account = app.buttons["settings-Account"]; childReveal(account, app); XCTAssertTrue(account.exists, app.debugDescription); childPress(account)
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 15), app.debugDescription)
        #endif
    }
    @MainActor func testChildPausedRecoveryLinksKeepOriginalsAcrossColdReturn() throws {
        let voiceWasOn = try ownerVoiceDisabled(); addTeardownBlock { @MainActor in self.ownerRestoreVoice(voiceWasOn) }
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childPausedRecoveryLaunch(app, reset: true)
        for (id, retry) in [("savedChildTransfers", "Retry original move"), ("savedChildAdoptions", "Retry original upgrade"), ("savedChildRepairs", "childRepairRetry"), ("savedChildStructure", "sendChildStructure-"), ("savedChildFieldChanges", "sendChildField-"), ("savedChildCompletions", "sendChildCompletion-"), ("savedChildGroups", "sendChildGroup-")] {
            let link = app.buttons[id]; childReveal(link, app); XCTAssertTrue(link.exists, app.debugDescription); childPress(link)
            if retry.hasPrefix("sendChild") {
                let send = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", retry)).firstMatch
                childReveal(send, app, diagnosticText: true); XCTAssertTrue(send.exists, app.debugDescription); XCTAssertFalse(send.isEnabled)
            } else {
                let send = app.buttons[retry]; childReveal(send, app, diagnosticText: true); XCTAssertTrue(send.exists, app.debugDescription); XCTAssertFalse(send.isEnabled)
                let check = app.buttons["Check status"].firstMatch; XCTAssertTrue(check.exists); XCTAssertTrue(check.isEnabled)
                if id == "savedChildTransfers" {
                    childPress(check); XCTAssertTrue(app.staticTexts["Awaiting confirmation"].waitForExistence(timeout: 15), app.debugDescription)
                }
            }
            structureSnapshot(app, "Paused recovery " + id)
            if id == "savedChildRepairs" { childPress(app.buttons["Close"]) } else { childDone(app) }
        }
        app.terminate(); try childPausedRecoveryLaunch(app, reset: false)
        for id in ["savedChildFieldChanges", "savedChildCompletions", "savedChildGroups", "savedChildTransfers", "savedChildAdoptions", "savedChildRepairs", "savedChildStructure"] {
            let link = app.buttons[id]; childReveal(link, app); XCTAssertTrue(link.exists, app.debugDescription)
        }
        structureSnapshot(app, "Paused recovery links survive cold return")
    }
    @MainActor func testChildPausedRecoveryFindsPrivateDraftWithoutSavedCommand() throws {
        let voiceWasOn = try ownerVoiceDisabled(); addTeardownBlock { @MainActor in self.ownerRestoreVoice(voiceWasOn) }
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childPausedRecoveryLaunch(app, reset: true, draftOnly: true)
        let link = app.buttons["savedChildStructure"]; childReveal(link, app); XCTAssertTrue(link.exists, app.debugDescription); childPress(link)
        let draft = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "childStructureDraftTitle-", "Saved recovery draft")).firstMatch
        childReveal(draft, app); XCTAssertTrue(draft.exists, app.debugDescription)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sendChildStructure-")).firstMatch.exists)
        structureSnapshot(app, "Paused private hierarchy draft remains discoverable")
        app.terminate(); try childPausedRecoveryLaunch(app, reset: false, draftOnly: true)
        childReveal(link, app); XCTAssertTrue(link.exists, app.debugDescription); childPress(link)
        childReveal(draft, app); XCTAssertTrue(draft.exists, app.debugDescription)
        structureSnapshot(app, "Private draft survives cold return with gates paused")
    }

    @MainActor private func childCompletionListLaunch(_ app: XCUIApplication, reset: Bool, lost: Bool = false, groupLost: Bool = false, blocking: Bool = false) throws -> String {
        try childGuard()
        app.launchArguments = ["--uitesting", "--team-editor-testing", "--child-fields-native", "--child-fields-main-list", "--child-fields-opaque", "--child-fields-list-completion", "-appearance", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL", "-ApplePersistenceIgnoreState", "YES"]
        if reset { app.launchArguments.append("--child-fields-native-reset") }
        if lost { app.launchArguments.append("--child-completion-lose-reply") }
        if groupLost { app.launchArguments.append("--child-batch-lose-reply") }
        if blocking { app.launchArguments.append("--child-batch-blocking-single") }
        app.launch(); app.activate()
        let root = "ec990000-0000-4000-8000-000000000002"
        let ref = "subtask:" + (try JSONSerialization.data(withJSONObject: [root, "review"])).base64EncodedString()
        #if os(iOS)
        let expand = app.buttons["expandChildRows-" + root]
        XCTAssertTrue(expand.waitForExistence(timeout: 30), app.debugDescription)
        if expand.value as? String != "Expanded" { childPress(expand) }
        #endif
        return ref
    }

    @MainActor private func childGroupListLaunch(_ app: XCUIApplication, reset: Bool, lost: Bool = false, blocking: Bool = false) throws {
        _ = try childCompletionListLaunch(app, reset: reset, groupLost: lost, blocking: blocking)
    }
    @MainActor private func childGroupSelectBoth(_ app: XCUIApplication) throws {
        #if os(macOS)
        throw XCTSkip("Mac group interaction uses authorized direct computer use after XCTest initialization failure")
        #else
        let options = app.buttons["Task options"]
        XCTAssertTrue(options.waitForExistence(timeout: 20), app.debugDescription); childPress(options)
        let select = app.buttons["Select tasks"]; XCTAssertTrue(select.waitForExistence(timeout: 10), app.debugDescription); childPress(select)
        for title in ["Prepare the review", "Publish the summary"] {
            let row = app.buttons["Select " + title]; childReveal(row, app); XCTAssertTrue(row.waitForExistence(timeout: 12), app.debugDescription); childPress(row)
        }
        let complete = app.buttons["Complete selected tasks"].firstMatch; XCTAssertTrue(complete.waitForExistence(timeout: 12), app.debugDescription); childPress(complete)
        #endif
    }
    @MainActor func testChildGroupMainListWholeUndoAndColdReturn() throws {
        let voiceWasOn = try ownerVoiceDisabled(); addTeardownBlock { @MainActor in self.ownerRestoreVoice(voiceWasOn) }
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childGroupListLaunch(app, reset: true); try childGroupSelectBoth(app)
        let undo = app.buttons["undoToast"]; XCTAssertTrue(undo.waitForExistence(timeout: 20), app.debugDescription); childPress(undo)
        for title in ["Prepare the review", "Publish the summary"] { XCTAssertTrue(app.buttons["Complete " + title].waitForExistence(timeout: 20), app.debugDescription) }
        app.terminate(); try childGroupListLaunch(app, reset: false)
        for title in ["Prepare the review", "Publish the summary"] { XCTAssertTrue(app.buttons["Complete " + title].waitForExistence(timeout: 20), app.debugDescription) }
        structureSnapshot(app, "Whole selection and receipt-based Undo survive cold return")
    }
    @MainActor func testChildGroupMainListUncertainReviewRetriesOriginal() throws {
        let voiceWasOn = try ownerVoiceDisabled(); addTeardownBlock { @MainActor in self.ownerRestoreVoice(voiceWasOn) }
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childGroupListLaunch(app, reset: true, lost: true); try childGroupSelectBoth(app)
        let review = app.buttons["reviewListChildGroup"]; XCTAssertTrue(review.waitForExistence(timeout: 20), app.debugDescription); XCTAssertFalse(app.buttons["undoToast"].exists); childPress(review)
        let retry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sendChildGroup-")).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 15), app.debugDescription); childReveal(retry,app); childPress(retry)
        let confirmed = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "childGroupPhase-", "Confirmed", "Confirmed")).firstMatch
        XCTAssertTrue(confirmed.waitForExistence(timeout: 20), app.debugDescription); XCTAssertFalse(retry.exists)
        structureSnapshot(app, "Lost group reply confirms its original request")
        childDone(app); XCTAssertFalse(review.exists)
    }
    @MainActor func testChildGroupMainListPreservesEarlierSingleAction() throws {
        let voiceWasOn = try ownerVoiceDisabled(); addTeardownBlock { @MainActor in self.ownerRestoreVoice(voiceWasOn) }
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childGroupListLaunch(app, reset: true, blocking: true); try childGroupSelectBoth(app)
        let review = app.buttons["reviewListChildGroup"]; XCTAssertTrue(review.waitForExistence(timeout: 20), app.debugDescription); childPress(review)
        let single = app.buttons["savedChildCompletions"]; childReveal(single,app); XCTAssertTrue(single.waitForExistence(timeout: 15), app.debugDescription); childPress(single)
        let queued = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "childCompletionPhase-", "not sent", "not sent")).firstMatch
        XCTAssertTrue(queued.waitForExistence(timeout: 20), app.debugDescription)
        structureSnapshot(app, "Earlier single action remains saved and blocks overlapping bulk work")
    }
    @MainActor func testChildCompletionMainListUndoAndColdReturn() throws {
        let voiceWasOn = try ownerVoiceDisabled(); addTeardownBlock { @MainActor in self.ownerRestoreVoice(voiceWasOn) }
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        let ref = try childCompletionListLaunch(app, reset: true)
        #if os(macOS)
        let complete = app.buttons["complete-" + ref], undo = app.buttons["undoConfirmation"]
        #else
        let complete = app.buttons["Complete Publish the summary"], undo = app.buttons["undoToast"]
        #endif
        childReveal(complete, app); XCTAssertTrue(complete.waitForExistence(timeout: 20), app.debugDescription); childPress(complete)
        XCTAssertTrue(undo.waitForExistence(timeout: 20), app.debugDescription)
        childPress(undo)
        XCTAssertTrue(complete.waitForExistence(timeout: 20), app.debugDescription)
        app.terminate(); _ = try childCompletionListLaunch(app, reset: false)
        XCTAssertTrue(complete.waitForExistence(timeout: 20), app.debugDescription)
        structureSnapshot(app, "List completion and receipt-based Undo survive cold return")
    }
    @MainActor func testChildCompletionMainListUncertainReviewRetriesOnce() throws {
        let voiceWasOn = try ownerVoiceDisabled(); addTeardownBlock { @MainActor in self.ownerRestoreVoice(voiceWasOn) }
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        let ref = try childCompletionListLaunch(app, reset: true, lost: true)
        #if os(macOS)
        let complete = app.buttons["complete-" + ref], undo = app.buttons["undoConfirmation"]
        #else
        let complete = app.buttons["Complete Publish the summary"], undo = app.buttons["undoToast"]
        #endif
        childReveal(complete, app); XCTAssertTrue(complete.waitForExistence(timeout: 20), app.debugDescription); childPress(complete)
        let review = app.buttons["reviewListChildCompletion"]
        XCTAssertTrue(review.waitForExistence(timeout: 20), app.debugDescription); XCTAssertFalse(undo.exists)
        childPress(review)
        let send = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sendChildCompletion-")).firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 15), app.debugDescription); childReveal(send, app); childPress(send)
        let confirmed = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "childCompletionPhase-", "Confirmed", "Confirmed")).firstMatch
        XCTAssertTrue(confirmed.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(send.exists)
        structureSnapshot(app, "Uncertain list completion confirms its original saved request")
        childDone(app); XCTAssertFalse(review.exists, "Review must dismiss its obsolete warning")
    }
    @MainActor func testChildFieldsMainListOpensSelectedChildAndColdReturn() throws {
        try childGuard()
        let voiceWasOn = try ownerVoiceDisabled()
        addTeardownBlock { @MainActor in self.ownerRestoreVoice(voiceWasOn) }
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        let reference = "subtask:" + (try JSONSerialization.data(withJSONObject: ["ec990000-0000-4000-8000-000000000002", "review"])).base64EncodedString()
        func row() -> XCUIElement {
            #if os(macOS)
            return app.descendants(matching: .any).matching(identifier: "task-" + reference).firstMatch
            #else
            return app.buttons["taskDetails-" + reference]
            #endif
        }
        func launch(_ reset: Bool) {
            app.launchArguments = ["--uitesting", "--team-editor-testing", "--child-fields-native", "--child-fields-main-list", "--child-fields-opaque", "-appearance", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL", "-ApplePersistenceIgnoreState", "YES"]
            if reset { app.launchArguments.append("--child-fields-native-reset") }
            app.launch(); app.activate()
            XCTAssertTrue(row().waitForExistence(timeout: 30), app.debugDescription)
        }
        launch(true); childPress(row())
        let title = childField("independentChildTitle", app)
        XCTAssertTrue(title.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(title.value as? String, "Publish the summary")
        XCTAssertFalse(app.buttons["independentChildSelection"].exists, "A list opening must stay on the selected child")
        childType("Selected list child saved", title)
        let save = app.buttons["saveIndependentChildFields"]; childReveal(save, app); childPress(save)
        XCTAssertTrue(childField("independentChildDetailSaved", app).waitForExistence(timeout: 20), app.debugDescription)
        #if os(iOS)
        childDone(app)
        #endif
        app.terminate(); launch(false); childPress(row())
        XCTAssertTrue(title.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(title.value as? String, "Selected list child saved")
        structureSnapshot(app, "Task list opens the selected child after a cold return")
    }
    @MainActor func testChildFieldsNativeOpaqueValuesSurviveSaveSendAndColdReturn() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app, extra: "--child-fields-opaque")
        childProbe(app,"opaqueRoot=true opaqueChild=true"); childProbe(app,"opaqueChildMetadata=true")
        childSave(app, title: "Keep exact older content")
        childDone(app); childProbe(app, "queued=1 attempted=0 confirmed=0 writes=0")
        childHomePress("childNativeRecovery", app)
        let send = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sendChildField-")).firstMatch
        childReveal(send, app); childPress(send)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "childFieldPhase-", "Confirmed", "Confirmed")).firstMatch.waitForExistence(timeout: 12), app.debugDescription)
        childDone(app); childProbe(app, "confirmed=1 writes=1 requests=1 current=Keep exact older content")
        app.terminate(); try childOpen(app, reset: false, extra: "--child-fields-opaque"); childProbe(app,"opaqueRoot=true opaqueChild=true"); childProbe(app,"opaqueChildMetadata=true"); childProbe(app, "confirmed=1 writes=1 requests=1")
        structureSnapshot(app,"Exact numeric and Unicode content survives field send and cold return")
        childHomePress("childNativeRecovery", app)
        XCTAssertTrue(childSavedText("Keep exact older content", app).waitForExistence(timeout: 10), app.debugDescription); XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sendChildField-")).firstMatch.exists)
    }
    @MainActor func testChildFieldsNativeLostReplyColdRetryOnce() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app, extra: "--child-fields-lose-reply")
        childSave(app, title: "Retry the exact saved child request"); childDone(app)
        childHomePress("childNativeRecovery", app)
        let send = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sendChildField-")).firstMatch
        childReveal(send, app); childPress(send)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "childFieldPhase-", "Unconfirmed", "Unconfirmed")).firstMatch.waitForExistence(timeout: 12), app.debugDescription)
        childDone(app); childProbe(app, "attempted=1 confirmed=0 writes=1 requests=1")
        app.terminate(); try childOpen(app, reset: false)
        childHomePress("childNativeRecovery", app); childReveal(send, app); childPress(send)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "childFieldPhase-", "Confirmed", "Confirmed")).firstMatch.waitForExistence(timeout: 12))
        childDone(app); childProbe(app, "confirmed=1 writes=1 requests=2 current=Retry the exact saved child request")
    }
    @MainActor func testChildFieldsNativeLargestTextPreservesUnsentTypingCold() throws {
        #if os(macOS)
        throw XCTSkip("iOS Dynamic Type case; Mac layout acceptance is separate")
        #else
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app, large: true)
        childSave(app, title: "Checkpoint a large-text child"); childDone(app); childProbe(app, "queued=1 attempted=0 confirmed=0 writes=0")
        childHomePress("childNativeEditor", app)
        let field = childField("independentChildTitle", app); childReveal(field, app); childType("Private unsent large-text draft", field)
        childDone(app); childProbe(app, "private=1")
        let privateTitle = app.staticTexts["childNativePrivateTitle"]; childReveal(privateTitle, app); XCTAssertEqual(privateTitle.label, "Private unsent large-text draft")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = "child-private-cold-proof"; shot.lifetime = .keepAlways; add(shot)
        app.terminate(); try childOpen(app, reset: false); childProbe(app, "private=1"); XCTAssertEqual(privateTitle.label, "Private unsent large-text draft")
        childProbe(app, "queued=1 attempted=0 confirmed=0 writes=0 requests=0")
        #endif
    }
    @MainActor func testChildFieldsNativeUncertainDiscardCancelAndColdState() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app, extra: "--child-fields-lose-reply")
        childSave(app, title: "A discarded receipt cannot undo this change"); childDone(app); childHomePress("childNativeRecovery", app)
        let send = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sendChildField-")).firstMatch
        childReveal(send, app); childPress(send)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "childFieldPhase-", "Unconfirmed", "Unconfirmed")).firstMatch.waitForExistence(timeout: 12))
        let discard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "discardChildField-")).firstMatch
        childReveal(discard, app); childPress(discard)
        let confirm = app.buttons["Discard unconfirmed request"]; XCTAssertTrue(confirm.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "cannot cancel or undo")).firstMatch.exists)
        childPress(app.buttons["Cancel"]); XCTAssertTrue(send.exists)
        childPress(discard); childPress(confirm)
        XCTAssertTrue(app.staticTexts["No saved changes"].waitForExistence(timeout: 10)); childDone(app)
        childProbe(app, "queued=0 attempted=0 confirmed=0 writes=1 requests=1")
        app.terminate(); try childOpen(app, reset: false)
        childProbe(app, "writes=1 requests=1 current=A discarded receipt cannot undo this change")
    }
    @MainActor func testChildFieldsNativeAccountSwitchKeepsOriginalPrivateAttempt() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app, extra: "--child-fields-switch-on-send")
        childSave(app, title: "Keep this request with account A"); childDone(app)
        childHomePress("childNativeRecovery", app)
        let send = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sendChildField-")).firstMatch
        childReveal(send, app); childPress(send)
        XCTAssertTrue(app.staticTexts["No saved changes"].waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertFalse(childSavedText("Keep this request with account A", app).exists)
        childDone(app); childProbe(app, "attempted=1 confirmed=0 writes=1 requests=1 current=hidden account=B")
        app.terminate(); try childOpen(app, reset: false)
        childHomePress("childNativeRecovery", app); XCTAssertTrue(childSavedText("Keep this request with account A", app).waitForExistence(timeout: 12), app.debugDescription)
        childReveal(send, app); childPress(send); childDone(app); childProbe(app, "confirmed=1 writes=1 requests=2")
    }
    @MainActor func testChildFieldsNativeEstimateSendAndColdState() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app)
        childHomePress("childNativeEditor", app)
        let plan = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Plan")).firstMatch
        childReveal(plan, app); childPress(plan)
        let estimate = childField("childEstimateEnabled", app); childReveal(estimate, app)
        #if os(iOS)
        // SwiftUI exposes both the labeled row and the actual switch. Tapping
        // the row's center leaves the thumb unchanged; use the real control.
        let thumb = estimate.descendants(matching: .switch).firstMatch
        childPress(thumb)
        XCTAssertEqual(estimate.value as? String, "1", app.debugDescription)
        #else
        childPress(estimate)
        #endif
        let save = app.buttons["saveIndependentChildFields"]; childReveal(save, app); XCTAssertTrue(save.isEnabled); childPress(save)
        childSavedNoticeVisible(app, name: "child-planning-saved")
        childDone(app); childProbe(app, "queued=1 attempted=0 confirmed=0 writes=0")
        childHomePress("childNativeRecovery", app)
        XCTAssertTrue(childSavedText("30 min", app).waitForExistence(timeout: 10), app.debugDescription)
        let reviewShot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); reviewShot.name = "child-planning-review"; reviewShot.lifetime = .keepAlways; add(reviewShot)
        let send = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sendChildField-")).firstMatch
        childReveal(send, app); childPress(send)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "childFieldPhase-", "Confirmed", "Confirmed")).firstMatch.waitForExistence(timeout: 12), app.debugDescription)
        childDone(app); childProbe(app, "writes=1 requests=1 current=Prepare the review")
        childProbe(app, "minutes=30")
        app.terminate(); try childOpen(app, reset: false); childProbe(app, "confirmed=1 writes=1 requests=1"); childProbe(app, "minutes=30")
    }

    @MainActor func testChildFieldsNativeLabelsAndUnsubmittedInputCold() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app)
        childHomePress("childNativeEditor", app)
        let section = app.buttons.matching(NSPredicate(format: "label == %@", "Labels")).firstMatch; childReveal(section, app); childPress(section)
        let input = childField("childLabelName", app); childReveal(input, app); childPress(input); input.typeText("Review")
        let addLabel = app.buttons["addChildLabel"]; childReveal(addLabel, app); childPress(addLabel)
        childReveal(input, app); childPress(input); input.typeText("Later")
        let save = app.buttons["saveIndependentChildFields"]; childReveal(save, app); XCTAssertTrue(save.isEnabled); childPress(save)
        childSavedNoticeVisible(app, name: "child-labels-saved")
        childDone(app); childProbe(app, "queued=1 attempted=0 confirmed=0 writes=0")
        childProbe(app, "private=1"); childProbe(app, "pendingLabel=Later")
        childHomePress("childNativeRecovery", app)
        XCTAssertTrue(childSavedText("Review", app).waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(childSavedText("Later", app).exists)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = "child-labels-review"; shot.lifetime = .keepAlways; add(shot)
        let send = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sendChildField-")).firstMatch
        childReveal(send, app); childPress(send)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "childFieldPhase-", "Confirmed", "Confirmed")).firstMatch.waitForExistence(timeout: 12), app.debugDescription)
        childDone(app); childProbe(app, "writes=1 requests=1 current=Prepare the review"); childProbe(app, "labels=Review pendingLabel=Later")
        app.terminate(); try childOpen(app, reset: false)
        childProbe(app, "confirmed=1 writes=1 requests=1"); childProbe(app, "labels=Review pendingLabel=Later"); childProbe(app, "private=1")
    }

    @MainActor func testChildFieldsNativeAssignmentAndClearCold() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app)
        for (choice, caption, count) in [("self", "You", 1), ("unassigned", "Unassigned", 2)] {
            childHomePress("childNativeEditor", app)
            let assign = app.buttons["childAssignee"]; childReveal(assign, app); childPress(assign)
            let button = app.buttons["childAssignee-" + choice]
            XCTAssertTrue(button.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: button)], timeout: 10) == .completed)
            childPress(button)
            let save = app.buttons["saveIndependentChildFields"]; childReveal(save, app); XCTAssertTrue(save.isEnabled); childPress(save)
            childSavedNoticeVisible(app, name: "child-assignment-\(choice)-saved")
            childDone(app); childHomePress("childNativeRecovery", app)
            XCTAssertTrue(childSavedText(caption, app).waitForExistence(timeout: 10), app.debugDescription)
            let send = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sendChildField-")).firstMatch
            childReveal(send, app); childPress(send)
            let confirmed = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "childFieldPhase-", "Confirmed", "Confirmed"))
            XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in confirmed.count == count }, object: nil)], timeout: 12) == .completed, app.debugDescription)
            childDone(app); childProbe(app, "confirmed=\(count) writes=\(count) requests=\(count)")
            let suffix = choice == "self" ? "assigned=ec990000-0000-4000-8000-000000000001" : "assigned="
            XCTAssertTrue(app.staticTexts["childNativeProbe"].label.hasSuffix(suffix), app.debugDescription)
            app.terminate(); try childOpen(app, reset: false)
            childProbe(app, "confirmed=\(count) writes=\(count) requests=\(count)")
            childProbe(app, "current=Prepare the review"); childProbe(app, "private=0")
            XCTAssertTrue(app.staticTexts["childNativeProbe"].label.hasSuffix(suffix), app.debugDescription)
        }
    }

    @MainActor private func childReminderToggleOff(_ app: XCUIApplication) {
        let planned = childField("teamReminderPlanned", app)
        XCTAssertTrue(planned.waitForExistence(timeout: 10), app.debugDescription)
        childReveal(planned, app)
        #if os(iOS)
        let thumb = planned.descendants(matching: .switch).firstMatch
        childPress(thumb)
        #else
        childPress(planned)
        #endif
        XCTAssertEqual(planned.value as? String, "0", app.debugDescription)
    }
    @MainActor func testChildFieldsNativeReminderComposeCancelAndCold() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app)
        childHomePress("childNativeEditor", app)
        let open = app.buttons["childReminders"]; childReveal(open, app); childPress(open)
        XCTAssertTrue(childField("teamReminderPlanned", app).waitForExistence(timeout: 10), app.debugDescription)
        let initialAdd = app.buttons["addTeamReminder"]; childReveal(initialAdd, app); childPress(initialAdd)
        XCTAssertTrue(app.buttons["reminderCancel"].waitForExistence(timeout: 10), app.debugDescription)
        let probe = app.staticTexts["childNativeProbe"]
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "reminderDraft=1"), object: probe)], timeout: 12) == .completed, app.debugDescription)
        childPress(app.buttons["reminderCancel"])
        childReminderToggleOff(app)
        childPress(app.buttons["cancelTeamReminders"])
        let save = app.buttons["saveIndependentChildFields"]; childReveal(save, app); XCTAssertFalse(save.isEnabled)
        childDone(app); childProbe(app, "queued=0 attempted=0 confirmed=0 writes=0"); childProbe(app, "private=0")
        for count in 1...2 {
            childHomePress("childNativeEditor", app); childReveal(open, app); childPress(open)
            XCTAssertTrue(childField("teamReminderPlanned", app).waitForExistence(timeout: 10), app.debugDescription)
            if count == 1 {
                childReminderToggleOff(app)
                let addReminder = app.buttons["addTeamReminder"]; childReveal(addReminder, app); childPress(addReminder)
                let done = app.buttons["reminderSave"]; XCTAssertTrue(done.waitForExistence(timeout: 10), app.debugDescription); childPress(done)
                let edit = app.buttons["teamReminderEdit-1"]
                XCTAssertTrue(edit.waitForExistence(timeout: 10), app.debugDescription)
                childReveal(edit, app); childPress(edit)
                XCTAssertTrue(app.buttons["reminderSave"].waitForExistence(timeout: 10)); childPress(app.buttons["reminderSave"])
            } else {
                let remove = app.buttons["teamReminderRemove-1"]; childReveal(remove, app); childPress(remove)
            }
            childReveal(childField("teamReminderPlanned", app), app, towardTop: true)
            let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = "child-reminders-compose-\(count)"; shot.lifetime = .keepAlways; add(shot)
            childPress(app.buttons["saveTeamReminders"])
            childReveal(save, app); XCTAssertTrue(save.isEnabled); childPress(save)
            childSavedNoticeVisible(app, name: "child-reminders-saved-\(count)")
            childDone(app); childHomePress("childNativeRecovery", app)
            XCTAssertTrue(childSavedText("Reminders", app).waitForExistence(timeout: 10), app.debugDescription)
            let send = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sendChildField-")).firstMatch
            childReveal(send, app); childPress(send)
            let confirmed = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "childFieldPhase-", "Confirmed", "Confirmed"))
            XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in confirmed.count == count }, object: nil)], timeout: 12) == .completed, app.debugDescription)
            childDone(app); childProbe(app, "confirmed=\(count) writes=\(count) requests=\(count)")
            let expected = count == 1 ? "schedules=2 enabled=1 before10=1" : "schedules=1 enabled=0 before10=0"
            childProbe(app, expected); childProbe(app, "private=0")
            app.terminate(); try childOpen(app, reset: false)
            childProbe(app, "confirmed=\(count) writes=\(count) requests=\(count)"); childProbe(app, expected); childProbe(app, "current=Prepare the review"); childProbe(app, "private=0")
        }
    }

    @MainActor private func childCloseConfirmation(_ app: XCUIApplication) {
        let close = app.buttons["closeOriginalChildField"]; childReveal(close, app); childPress(close)
        #if os(macOS)
        let confirm = app.sheets.buttons.matching(identifier: "Close original request").firstMatch
        #else
        let confirm = app.alerts.buttons["Close original request"]
        #endif
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), app.debugDescription); childPress(confirm)
    }
    @MainActor private func childConflictReplacement(_ app: XCUIApplication, loseClose: Bool) throws {
        try childOpen(app, extra: loseClose ? "--child-fields-lose-close-reply" : nil)
        childSave(app, title: "My reviewed child title"); childDone(app)
        childHomePress("childNativeForeignEdit", app); childHomePress("childNativeRecovery", app)
        let send = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sendChildField-")).firstMatch
        childReveal(send, app); childPress(send)
        let unconfirmed = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "childFieldPhase-", "Unconfirmed", "Unconfirmed")).firstMatch
        XCTAssertTrue(unconfirmed.waitForExistence(timeout: 12), app.debugDescription)
        let compare = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "compareChildField-")).firstMatch
        childReveal(compare, app); childPress(compare)
        let savedTitle = childSavedText("My reviewed child title", app), currentTitle = childSavedText("Updated on another device", app)
        XCTAssertTrue(currentTitle.waitForExistence(timeout: 15), app.debugDescription); XCTAssertTrue(savedTitle.exists, app.debugDescription)
        let choose = childField("chooseChildField-title", app); childReveal(choose, app); XCTAssertFalse(choose.isEnabled)
        let before = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); before.name = "child-conflict-current-and-saved"; before.lifetime = .keepAlways; add(before)
        childCloseConfirmation(app)
        if loseClose {
            let message = app.staticTexts["childComparisonStatus"]
            XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "couldn’t be confirmed", "couldn’t be confirmed"), object: message)], timeout: 12) == .completed, app.debugDescription)
            XCTAssertFalse(app.staticTexts["childOriginalClosed"].exists)
            childCloseConfirmation(app)
        }
        XCTAssertTrue(app.staticTexts["childOriginalClosed"].waitForExistence(timeout: 15), app.debugDescription)
        childReveal(choose, app)
        XCTAssertEqual(choose.value.map { String(describing: $0) }, "0", app.debugDescription)
        #if os(iOS)
        childPress(choose.descendants(matching: .switch).firstMatch)
        #else
        childPress(choose)
        #endif
        XCTAssertEqual(choose.value.map { String(describing: $0) }, "1", app.debugDescription)
        let save = app.buttons["saveReviewedChildFields"]; childReveal(save, app); XCTAssertTrue(save.isEnabled); childPress(save)
        let status = app.staticTexts["childComparisonStatus"]; childReveal(status, app)
        XCTAssertTrue((status.label + (status.value as? String ?? "")).contains("Reviewed changes saved"), app.debugDescription)
        let after = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); after.name = "child-conflict-reviewed-replacement"; after.lifetime = .keepAlways; add(after)
        childDone(app); childReveal(send, app); childPress(send)
        let confirmed = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "childFieldPhase-", "Confirmed", "Confirmed")).firstMatch
        XCTAssertTrue(confirmed.waitForExistence(timeout: 12), app.debugDescription)
        childDone(app); childProbe(app, "confirmed=1 writes=1 requests=2 current=My reviewed child title")
        childProbe(app, loseClose ? "closed=1 closes=2" : "closed=1 closes=1"); childProbe(app, "private=0")
        app.terminate(); try childOpen(app, reset: false)
        childProbe(app, "queued=0 attempted=0 confirmed=1 writes=1 requests=2 current=My reviewed child title")
        childProbe(app, "closed=1")
    }
    @MainActor func testChildFieldsNativeDistinctSavedValues() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app)
        childSave(app, title: "First saved child version"); childDone(app); childHomePress("childNativeRecovery", app)
        let send = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sendChildField-")).firstMatch
        childReveal(send, app); childPress(send)
        let confirmed = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)", "childFieldPhase-", "Confirmed", "Confirmed")).firstMatch
        XCTAssertTrue(confirmed.waitForExistence(timeout: 12), app.debugDescription); childDone(app)
        childSave(app, title: "Second saved child version"); childDone(app); childHomePress("childNativeRecovery", app)
        let values = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "childFieldValue-", "-title"))
        let second = values.element(boundBy: 1); childReveal(second, app)
        let names = values.allElementsBoundByIndex.map { $0.label + " " + (($0.value as? String) ?? "") }
        XCTAssertTrue(names.contains(where: { $0.contains("First saved child version") }), app.debugDescription)
        XCTAssertTrue(names.contains(where: { $0.contains("Second saved child version") }), app.debugDescription)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = "child-distinct-saved-values"; shot.lifetime = .keepAlways; add(shot)
        childDone(app); childProbe(app, "queued=1 attempted=0 confirmed=1 writes=1 requests=1 current=First saved child version")
    }

    @MainActor func testChildFieldsNativeConflictReplacementAndColdProof() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childConflictReplacement(app, loseClose: false)
    }
    @MainActor func testChildFieldsNativeLostCloseReplyAndColdProof() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childConflictReplacement(app, loseClose: true)
    }
    @MainActor func testChildFieldsNativeCloseRecoversAlreadyAppliedOriginal() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childOpen(app, extra: "--child-fields-lose-reply")
        childSave(app, title: "Already applied child change"); childDone(app); childHomePress("childNativeRecovery", app)
        let send = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sendChildField-")).firstMatch
        childReveal(send, app); childPress(send)
        let compare = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "compareChildField-")).firstMatch
        childReveal(compare, app); childPress(compare); childCloseConfirmation(app)
        let status = app.staticTexts["childComparisonStatus"]; childReveal(status, app)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "already applied", "already applied"), object: status)], timeout: 12) == .completed, app.debugDescription)
        XCTAssertFalse(app.buttons["saveReviewedChildFields"].exists); XCTAssertFalse(app.staticTexts["childOriginalClosed"].exists)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = "child-conflict-already-applied"; shot.lifetime = .keepAlways; add(shot)
        childDone(app); childDone(app); childProbe(app, "confirmed=1 writes=1 requests=1 current=Already applied child change"); childProbe(app, "closed=0 closes=1")
        app.terminate(); try childOpen(app, reset: false); childProbe(app, "confirmed=1 writes=1 requests=1"); childProbe(app, "closed=0 closes=1")
    }

    @MainActor func testChildFieldsHeadingDoesNotOfferReminderOrPlan() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childOpen(app, extra: "--child-fields-native-heading")
        childHomePress("childNativeEditor", app)
        let title = childField("independentChildTitle", app)
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        childReveal(app.buttons["saveIndependentChildFields"], app)
        XCTAssertFalse(app.buttons["childReminders"].exists)
        childReveal(title, app, towardTop: true)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", "Plan")).firstMatch.exists)
        childDone(app); childProbe(app, "queued=0 attempted=0 confirmed=0 writes=0"); childProbe(app, "private=0"); childProbe(app, "kind=heading")
    }

    @MainActor private func structureSaveNew(_ app: XCUIApplication, title: String) {
        completionReadyPress(app.buttons["childStructureAdd"], app)
        let field = childField("childStructureNewTitle", app); childPress(field); field.typeText(title)
        XCTAssertEqual(field.value as? String, title)
        completionReadyPress(app.buttons["childStructureReviewApply"], app)
        XCTAssertTrue(app.staticTexts["childStructureNotice"].waitForExistence(timeout: 12), app.debugDescription)
    }
    @MainActor private func structureOpenRecovery(_ app: XCUIApplication) {
        let statusAction = app.buttons["Open saved hierarchy actions"]
        if statusAction.exists && statusAction.isHittable { completionReadyPress(statusAction, app) }
        else { completionReadyPress(app.buttons["childStructureRecovery"], app) }
    }
    @MainActor private func structureSend(_ app: XCUIApplication) {
        let send = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sendChildStructure-")).firstMatch
        completionReadyPress(send, app)
        let status = app.staticTexts["childStructureRecoveryStatus"]
        childReveal(status, app, towardTop: true)
        XCTAssertTrue(status.waitForExistence(timeout: 12), app.debugDescription)
    }
    @MainActor private func structureSnapshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testChildStructureNativeInsertSavedSendAndColdReceipt() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app, extra: "--child-structure-native")
        childHomePress("childNativeStructure", app); structureSaveNew(app, title: "Sketch the follow-up")
        structureOpenRecovery(app); structureSend(app)
        XCTAssertTrue(childSavedText("Confirmed · current tasks may have changed", app).waitForExistence(timeout: 12), app.debugDescription)
        structureSnapshot(app, "Hierarchy insertion confirmed")
        childDone(app); childDone(app); childProbe(app, "structureQueued=0 structureAttempted=0 structureConfirmed=1 structureClosed=0 structureWrites=1 structureRequests=1")
        app.terminate(); try childOpen(app, reset: false, extra: "--child-structure-native")
        childProbe(app, "structureConfirmed=1 structureClosed=0 structureWrites=1 structureRequests=1")
        childHomePress("childNativeStructure", app); XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Sketch the follow-up, level ")).firstMatch.waitForExistence(timeout: 12), app.debugDescription)
    }
    @MainActor func testChildStructureDraftColdResumeAndSeparateActionSave() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childOpen(app, extra: "--child-structure-native", large: true)
        childHomePress("childNativeStructure", app)
        completionReadyPress(app.buttons["childStructureAdd"], app)
        let title = "Keep this organizer draft"
        let field = childField("childStructureNewTitle", app); childPress(field); field.typeText(title)
        XCTAssertEqual(field.value as? String, title)
        childDone(app)
        let resume = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "resumeChildStructureDraft-")).firstMatch
        childReveal(resume, app)
        XCTAssertTrue(resume.waitForExistence(timeout: 12), app.debugDescription)
        structureSnapshot(app, "Organizer unfinished draft saved")
        childDone(app); childProbe(app, "structureDrafts=1 structureDraftPending=0 structureQueued=0 structureAttempted=0 structureConfirmed=0 structureClosed=0 structureWrites=0 structureRequests=0")
        app.terminate(); try childOpen(app, reset: false, extra: "--child-structure-native", large: true)
        childProbe(app, "structureDrafts=1 structureDraftPending=0")
        childHomePress("childNativeStructure", app); completionReadyPress(resume, app)
        let restored = childField("childStructureNewTitle", app)
        XCTAssertEqual(restored.value as? String, title)
        childPress(restored); restored.typeText(" revised")
        let updated = try XCTUnwrap(restored.value as? String)
        XCTAssertEqual(updated.replacingOccurrences(of: " revised", with: ""), title)
        structureSnapshot(app, "Organizer draft restored after cold launch")
        completionReadyPress(app.buttons["childStructureReviewApply"], app)
        XCTAssertTrue(app.staticTexts["childStructureNotice"].waitForExistence(timeout: 12), app.debugDescription)
        structureOpenRecovery(app)
        childReveal(childSavedText(updated, app), app)
        XCTAssertTrue(childSavedText(updated, app).waitForExistence(timeout: 12), app.debugDescription)
        structureSnapshot(app, "Draft becomes a saved unsent action")
        childDone(app); childDone(app)
        childProbe(app, "structureDrafts=0 structureDraftPending=0 structureQueued=1 structureAttempted=0 structureConfirmed=0 structureClosed=0 structureWrites=0 structureRequests=0")
        app.terminate(); try childOpen(app, reset: false, extra: "--child-structure-native", large: true)
        childProbe(app, "structureDrafts=0 structureDraftPending=0 structureQueued=1 structureAttempted=0 structureConfirmed=0 structureClosed=0 structureWrites=0 structureRequests=0")
    }
    @MainActor func testChildStructureFrozenDraftFinishesWithoutAvailableTaskRead() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childOpen(app, extra: "--child-structure-duplicate-draft", large: true)
        childProbe(app, "structureReadUnavailable=true")
        childProbe(app, "structureDrafts=1 structureDraftPending=1 structureQueued=1 structureAttempted=0 structureConfirmed=0 structureClosed=0 structureWrites=0 structureRequests=0")
        childHomePress("childNativeStructureRecovery", app)
        let title = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "childStructureDraftTitle-")).firstMatch
        childReveal(title, app)
        XCTAssertEqual(title.label, "Keep the original saved action")
        let phase = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "childStructurePhase-")).firstMatch
        childReveal(phase, app); XCTAssertEqual(phase.label, "Saved · not sent")
        let resume = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "resumeChildStructureDraft-")).firstMatch
        childReveal(resume, app, towardTop: true); completionReadyPress(resume, app)
        let finish = app.buttons["finishChildStructureDraftRecovery"]; childReveal(finish, app)
        XCTAssertGreaterThanOrEqual(finish.frame.height, 44)
        XCTAssertEqual(childField("childStructureNewTitle", app).value as? String, "Keep the original saved action")
        XCTAssertFalse(childField("childStructureNewTitle", app).isEnabled)
        structureSnapshot(app, "Finish recovery without current task access")
        completionReadyPress(finish, app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: title)], timeout: 12), .completed, app.debugDescription)
        childDone(app)
        childProbe(app, "structureDrafts=0 structureDraftPending=0 structureQueued=1 structureAttempted=0 structureConfirmed=0 structureClosed=0 structureWrites=0 structureRequests=0")
        app.terminate(); try childOpen(app, reset: false, extra: "--child-structure-native", large: true)
        childProbe(app, "structureDrafts=0 structureDraftPending=0 structureQueued=1 structureAttempted=0 structureConfirmed=0 structureClosed=0 structureWrites=0 structureRequests=0")
        childHomePress("childNativeStructureRecovery", app); childReveal(phase, app)
        XCTAssertEqual(phase.label, "Saved · not sent")
        XCTAssertFalse(title.exists)
        structureSnapshot(app, "Only the original unsent action remains after cold return")
    }
    @MainActor func testChildStructureDiscardConfirmationKeepsConcurrentDraftUpdate() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childOpen(app, extra: "--child-structure-discard-refresh", large: true)
        childHomePress("childNativeStructure", app); completionReadyPress(app.buttons["childStructureAdd"], app)
        let field = childField("childStructureNewTitle", app); childPress(field); field.typeText("Original reviewed draft")
        childDone(app)
        let discard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "discardChildStructureDraft-")).firstMatch
        completionReadyPress(discard, app)
        let alert = app.alerts.firstMatch; XCTAssertTrue(alert.waitForExistence(timeout: 10), app.debugDescription)
        let title = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "childStructureDraftTitle-")).firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Updated while confirmation is open"), object: title)], timeout: 12), .completed, app.debugDescription)
        XCTAssertTrue(alert.exists)
        childPress(alert.buttons["Discard draft"])
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(title.label, "Updated while confirmation is open")
        let resume = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "resumeChildStructureDraft-")).firstMatch
        completionReadyPress(resume, app)
        XCTAssertEqual(childField("childStructureNewTitle", app).value as? String, "Updated while confirmation is open")
        childDone(app); childDone(app)
        childProbe(app, "structureDrafts=1 structureDraftPending=0 structureQueued=0 structureAttempted=0 structureConfirmed=0 structureClosed=0 structureWrites=0 structureRequests=0")
        app.terminate(); try childOpen(app, reset: false, extra: "--child-structure-native", large: true)
        childHomePress("childNativeStructureRecovery", app)
        childReveal(title, app)
        XCTAssertEqual(title.label, "Updated while confirmation is open")
        structureSnapshot(app, "Concurrent draft survives reviewed Discard and cold return")
    }
    @MainActor func testChildStructureDraftDiscardCancelAndConfirmation() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childOpen(app, extra: "--child-structure-native", large: true)
        childHomePress("childNativeStructure", app); completionReadyPress(app.buttons["childStructureAdd"], app)
        let field = childField("childStructureNewTitle", app); childPress(field); field.typeText("Discard only this draft")
        childDone(app)
        let discard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "discardChildStructureDraft-")).firstMatch
        childReveal(discard, app)
        let resumeBefore = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "resumeChildStructureDraft-")).firstMatch
        XCTAssertGreaterThanOrEqual(discard.frame.height, 44)
        XCTAssertGreaterThanOrEqual(resumeBefore.frame.height, 44)
        XCTAssertGreaterThanOrEqual(discard.frame.minY, resumeBefore.frame.maxY)
        XCTAssertLessThan(discard.frame.height, 80)
        structureSnapshot(app, "Readable draft actions at largest text")
        completionReadyPress(discard, app)
        let alert = app.alerts.firstMatch; XCTAssertTrue(alert.waitForExistence(timeout: 10), app.debugDescription)
        childPress(alert.buttons["Cancel"])
        let resume = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "resumeChildStructureDraft-")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 10), app.debugDescription)
        completionReadyPress(resume, app)
        XCTAssertEqual(childField("childStructureNewTitle", app).value as? String, "Discard only this draft")
        childDone(app)
        completionReadyPress(discard, app); XCTAssertTrue(alert.waitForExistence(timeout: 10), app.debugDescription)
        childPress(alert.buttons["Discard draft"])
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: resume)], timeout: 12) == .completed, app.debugDescription)
        structureSnapshot(app, "Only the unfinished draft is removed")
        childDone(app); childProbe(app, "structureDrafts=0 structureDraftPending=0")
        childProbe(app, "structureQueued=0 structureAttempted=0 structureConfirmed=0 structureClosed=0 structureWrites=0 structureRequests=0")
    }
    @MainActor func testChildStructureNativeLostReplyColdRetryOnlyOnce() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app, extra: "--child-structure-lose-reply")
        childHomePress("childNativeStructure", app); structureSaveNew(app, title: "Keep the original request")
        structureOpenRecovery(app); structureSend(app)
        XCTAssertTrue(childSavedText("Needs attention · original action kept", app).waitForExistence(timeout: 12), app.debugDescription)
        childDone(app); childDone(app); childProbe(app, "structureQueued=0 structureAttempted=1 structureConfirmed=0 structureClosed=0 structureWrites=1 structureRequests=1")
        app.terminate(); try childOpen(app, reset: false, extra: "--child-structure-native")
        childHomePress("childNativeStructureRecovery", app); structureSend(app)
        childReveal(childSavedText("Confirmed · current tasks may have changed", app), app)
        XCTAssertTrue(childSavedText("Confirmed · current tasks may have changed", app).waitForExistence(timeout: 12), app.debugDescription)
        childDone(app); childProbe(app, "structureQueued=0 structureAttempted=0 structureConfirmed=1 structureClosed=0 structureWrites=1 structureRequests=2")
    }
    @MainActor func testChildStructureNativeDeleteReviewUndoAndColdRestoration() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app, extra: "--child-structure-nested", large: true)
        childHomePress("childNativeStructure", app); completionReadyPress(app.buttons["removeChildStructure-concept"], app)
        childReveal(childSavedText("2 items will be removed, including nested subtasks.", app), app)
        XCTAssertTrue(childSavedText("2 items will be removed, including nested subtasks.", app).waitForExistence(timeout: 12), app.debugDescription)
        childReveal(childSavedText("Keep these nested instructions", app), app)
        XCTAssertTrue(childSavedText("Keep these nested instructions", app).waitForExistence(timeout: 12), app.debugDescription)
        structureSnapshot(app, "Reviewed hierarchy deletion")
        completionReadyPress(app.buttons["childStructureReviewApply"], app); structureOpenRecovery(app); structureSend(app)
        completionReadyPress(app.buttons["Review Undo"].firstMatch, app)
        completionReadyPress(app.buttons["childStructureReviewApply"], app)
        structureSend(app)
        XCTAssertTrue(childSavedText("Undo confirmed.", app).waitForExistence(timeout: 12), app.debugDescription)
        childDone(app); childDone(app); childProbe(app, "structureConfirmed=2 structureClosed=0 structureWrites=2 structureRequests=2 structureArchives=0 structureOrder=concept>nested>review")
        app.terminate(); try childOpen(app, reset: false, extra: "--child-structure-nested", large: true)
        childProbe(app, "structureConfirmed=2 structureClosed=0 structureWrites=2 structureRequests=2 structureArchives=0 structureOrder=concept>nested>review")
    }
    @MainActor func testChildStructureNativeUndoDisposalCancelThenExplicitConfirmation() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app, extra: "--child-structure-native")
        childHomePress("childNativeStructure", app); completionReadyPress(app.buttons["removeChildStructure-concept"], app)
        completionReadyPress(app.buttons["childStructureReviewApply"], app); structureOpenRecovery(app); structureSend(app)
        let remove = app.buttons["Remove saved Undo content…"].firstMatch; completionReadyPress(remove, app)
        childPress(app.alerts.buttons["Cancel"].firstMatch)
        XCTAssertTrue(remove.waitForExistence(timeout: 8), app.debugDescription)
        completionReadyPress(remove, app); childPress(app.alerts.buttons["Remove Undo content"].firstMatch)
        XCTAssertTrue(childSavedText("Undo content removed", app).waitForExistence(timeout: 12), app.debugDescription)
        structureSnapshot(app, "Confirmed private Undo disposal")
        childDone(app); childDone(app); childProbe(app, "structureArchives=0 structureOrder=review structureDisposals=1")
    }
    @MainActor func testChildStructureMoveDraftColdResumePreservesTargetAndDestination() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childOpen(app, extra: "--child-structure-native", large: true)
        childHomePress("childNativeStructure", app); completionReadyPress(app.buttons["moveChildStructure-concept"], app)
        let parent = childField("childStructureParent", app); childReveal(parent, app); childPress(parent)
        #if os(macOS)
        childPress(app.menuItems["Publish the summary"].firstMatch)
        #else
        childPress(app.buttons["Publish the summary"].firstMatch)
        #endif
        childDone(app)
        let draftName = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "childStructureDraftTitle-")).firstMatch
        childReveal(draftName, app, towardTop: true)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Prepare the review"), object: draftName)], timeout: 12) == .completed, app.debugDescription)
        structureSnapshot(app, "Current move draft target in organizer")
        childDone(app); childProbe(app, "structureDrafts=1 structureDraftPending=0 structureQueued=0 structureAttempted=0 structureConfirmed=0 structureClosed=0 structureWrites=0 structureRequests=0")
        app.terminate(); try childOpen(app, reset: false, extra: "--child-structure-native", large: true)
        childHomePress("childNativeStructureRecovery", app)
        childReveal(draftName, app)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Prepare the review"), object: draftName)], timeout: 12) == .completed, app.debugDescription)
        structureSnapshot(app, "Current move target after cold recovery")
        let resume = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "resumeChildStructureDraft-")).firstMatch
        completionReadyPress(resume, app)
        let restoredParent = childField("childStructureParent", app); childReveal(restoredParent, app)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Publish the summary", "Publish the summary"), object: restoredParent)], timeout: 12) == .completed, app.debugDescription)
        structureSnapshot(app, "Saved move destination survives cold resume")
        completionReadyPress(app.buttons["childStructureReviewApply"], app)
        let saved = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "childStructurePhase-")).firstMatch
        childReveal(saved, app)
        XCTAssertEqual(saved.label, "Saved · not sent")
        childDone(app)
        childProbe(app, "structureDrafts=0 structureDraftPending=0 structureQueued=1 structureAttempted=0 structureConfirmed=0 structureClosed=0 structureWrites=0 structureRequests=0")
        childProbe(app, "structureOrder=concept>review")
        app.terminate(); try childOpen(app, reset: false, extra: "--child-structure-native", large: true)
        childProbe(app, "structureDrafts=0 structureDraftPending=0 structureQueued=1 structureAttempted=0 structureConfirmed=0 structureClosed=0 structureWrites=0 structureRequests=0")
    }
    @MainActor func testChildStructureNativeDestinationPickerAndMove() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app, extra: "--child-structure-native")
        childHomePress("childNativeStructure", app); completionReadyPress(app.buttons["moveChildStructure-concept"], app)
        let parent = childField("childStructureParent", app); childPress(parent)
        #if os(macOS)
        childPress(app.menuItems["Publish the summary"].firstMatch)
        #else
        childPress(app.buttons["Publish the summary"].firstMatch)
        #endif
        completionReadyPress(app.buttons["childStructureReviewApply"], app); structureOpenRecovery(app); structureSend(app)
        childDone(app); structureSnapshot(app, "Nested hierarchy after reviewed move"); childDone(app)
        childProbe(app, "structureConfirmed=1 structureClosed=0 structureWrites=1 structureRequests=1 structureArchives=0 structureOrder=review>concept")
    }
    @MainActor func testChildStructureNativePreservesPrivateFieldDraftAndSelection() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app, extra: "--child-structure-native", large: true)
        completionReadyPress(app.buttons["childNativeEditor"], app)
        let title = childField("independentChildTitle", app); childReveal(title, app); childPress(title)
        title.typeText("Private hierarchy review draft")
        let privateTitle = try XCTUnwrap(title.value as? String)
        XCTAssertTrue(privateTitle.contains("Private hierarchy review draft"))
        XCTAssertNotEqual(privateTitle, "Prepare the review")
        completionReadyPress(app.buttons["childFieldOrganizeStructure"], app)
        structureSaveNew(app, title: "Keep the next step")
        let statusCard = app.descendants(matching: .any).matching(identifier: "childStructureStatusCard").firstMatch
        XCTAssertTrue(statusCard.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertGreaterThan(statusCard.frame.height, 0)
        XCTAssertLessThan(statusCard.frame.height, app.windows.firstMatch.frame.height * 0.45, "Status must leave the largest-text organizer usable")
        structureSnapshot(app, "Compact largest-text hierarchy status")
        structureOpenRecovery(app); structureSend(app); childDone(app); childDone(app)
        childReveal(title, app, towardTop: true); XCTAssertEqual(title.value as? String, privateTitle)
        structureSnapshot(app, "Large text hierarchy return preserves field draft")
        childDone(app); childHomePress("childNativeStructure", app)
        let original = app.descendants(matching: .any).matching(identifier: "childStructureNode-concept").firstMatch
        childReveal(original, app)
        XCTAssertEqual(original.label, "Prepare the review, level 1", "Unsent typing must not change the saved original node after insertion reorders the list")
        childDone(app); childProbe(app, "queued=0 attempted=0 confirmed=0 writes=0 requests=0")
        childProbe(app, "structureConfirmed=1 structureClosed=0 structureWrites=1 structureRequests=1")
    }

    @MainActor func testChildStructureNativeStopCancelFreshReviewAndSeparateSend() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app, extra: "--child-structure-native")
        childHomePress("childNativeStructure", app); structureSaveNew(app, title: "Fresh action after review")
        structureOpenRecovery(app)
        let stop = app.buttons["Check and stop if pending"].firstMatch
        completionReadyPress(stop, app); childPress(app.alerts.buttons["Cancel"].firstMatch)
        XCTAssertTrue(childSavedText("Saved · not sent", app).waitForExistence(timeout: 8), app.debugDescription)
        completionReadyPress(stop, app); childPress(app.alerts.buttons["Check and stop"].firstMatch)
        XCTAssertTrue(childSavedText("Stopped · review to try again", app).waitForExistence(timeout: 12), app.debugDescription)
        completionReadyPress(app.buttons["Review a fresh action"].firstMatch, app)
        completionReadyPress(app.buttons["childStructureReviewApply"], app)
        childDone(app); childDone(app); childProbe(app, "structureQueued=1 structureAttempted=0 structureConfirmed=0 structureClosed=1 structureWrites=0 structureRequests=0")
        childHomePress("childNativeStructureRecovery", app); structureSend(app)
        childReveal(childSavedText("Confirmed · current tasks may have changed", app), app)
        XCTAssertTrue(childSavedText("Confirmed · current tasks may have changed", app).waitForExistence(timeout: 12), app.debugDescription)
        structureSnapshot(app, "Stopped hierarchy action and fresh confirmed request")
        childDone(app); childProbe(app, "structureQueued=0 structureAttempted=0 structureConfirmed=1 structureClosed=1 structureWrites=1 structureRequests=1")
    }
    @MainActor func testChildStructureNativeArchiveDiscoveryAfterLocalJournalLoss() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }; try childOpen(app, extra: "--child-structure-native")
        childHomePress("childNativeStructure", app); completionReadyPress(app.buttons["removeChildStructure-concept"], app)
        completionReadyPress(app.buttons["childStructureReviewApply"], app); structureOpenRecovery(app); structureSend(app)
        childDone(app); childDone(app); childProbe(app, "structureConfirmed=1 structureClosed=0 structureWrites=1 structureRequests=1 structureArchives=1")
        childHomePress("childNativeLoseStructureJournal", app); childProbe(app, "structureQueued=0 structureAttempted=0 structureConfirmed=0 structureClosed=0")
        app.terminate(); try childOpen(app, reset: false, extra: "--child-structure-native")
        childHomePress("childNativeStructureRecovery", app); completionReadyPress(app.buttons["discoverChildStructureUndo"], app)
        completionReadyPress(app.buttons["Review restore"].firstMatch, app)
        XCTAssertTrue(childSavedText("Undo hierarchy change", app).waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertFalse(app.alerts["Remove saved Undo content?"].exists)
        completionReadyPress(app.buttons["childStructureReviewApply"], app)
        structureSend(app); XCTAssertTrue(childSavedText("Undo confirmed.", app).waitForExistence(timeout: 12), app.debugDescription)
        structureSnapshot(app, "Server metadata restores Undo after local journal loss")
        childDone(app); childProbe(app, "structureQueued=0 structureAttempted=0 structureConfirmed=1 structureClosed=0 structureWrites=2 structureRequests=2 structureArchives=0 structureOrder=concept>review")
    }


    @MainActor func testChildFieldsReadableSelectionPreservesDraftAndCancel() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childOpen(app, extra: "--child-structure-nested", large: true)
        completionReadyPress(app.buttons["childNativeEditor"], app)
        let title = childField("independentChildTitle", app)
        childReveal(title, app); childPress(title); title.typeText("Private ")
        let privateTitle = try XCTUnwrap(title.value as? String); XCTAssertTrue(privateTitle.contains("Private "))
        let selection = app.buttons["independentChildSelection"]
        childReveal(selection, app, towardTop: true)
        XCTAssertEqual(selection.value as? String, "Prepare the review")
        XCTAssertGreaterThanOrEqual(selection.frame.height, 44)
        structureSnapshot(app, "Largest text wrapping subtask selection")
        completionReadyPress(selection, app)
        let parent = app.buttons["chooseIndependentChild-concept"], nested = app.buttons["chooseIndependentChild-nested"], other = app.buttons["chooseIndependentChild-review"]
        XCTAssertTrue(parent.waitForExistence(timeout: 12)); XCTAssertTrue(nested.exists); XCTAssertTrue(other.exists)
        XCTAssertLessThan(parent.frame.minY, nested.frame.minY); XCTAssertLessThan(nested.frame.minY, other.frame.minY)
        XCTAssertGreaterThanOrEqual(parent.frame.height, 44); XCTAssertGreaterThanOrEqual(nested.frame.height, 44)
        structureSnapshot(app, "Largest text ordered subtask choices")
        XCTAssertTrue(nested.isHittable); childPress(nested)
        childReveal(title, app); XCTAssertEqual(title.value as? String, "Collect supporting notes")
        childReveal(selection, app, towardTop: true); XCTAssertEqual(selection.value as? String, "Collect supporting notes, nested level 2")
        completionReadyPress(selection, app); childDone(app)
        childReveal(title, app); XCTAssertEqual(title.value as? String, "Collect supporting notes")
        childReveal(selection, app, towardTop: true); completionReadyPress(selection, app)
        let originalChoice = app.buttons["chooseIndependentChild-concept"]
        XCTAssertTrue(originalChoice.waitForExistence(timeout: 12)); XCTAssertTrue(originalChoice.isHittable)
        childPress(originalChoice)
        childReveal(title, app); XCTAssertEqual(title.value as? String, privateTitle)
        structureSnapshot(app, "Subtask selection returns private title")
        childDone(app); childProbe(app, "queued=0 attempted=0 confirmed=0 writes=0 requests=0")
        childProbe(app, "structureQueued=0 structureAttempted=0 structureConfirmed=0 structureClosed=0 structureWrites=0 structureRequests=0")
    }

    @MainActor private func transferReview(_ app: XCUIApplication) {
        childHomePress("childNativeStructure", app)
        let move = app.buttons["transferChild-concept"]; childReveal(move, app); completionReadyPress(move, app)
        let target = app.buttons["childTransferTarget-ec990000-0000-4000-8000-000000000020"]
        childReveal(target, app)
        XCTAssertTrue(target.waitForExistence(timeout: 12), app.debugDescription); childPress(target)
        let send = app.buttons["childTransferSend"]; childReveal(send, app)
        XCTAssertTrue(send.waitForExistence(timeout: 15), app.debugDescription)
        structureSnapshot(app, "Subtask transfer review preserves nested work")
        completionReadyPress(send, app)
    }
    @MainActor func testChildTransferNativeMoveColdUndoAndReturn() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childOpen(app, extra: "--child-transfer-native", large: true)
        transferReview(app)
        let confirmed = childSavedText("Move confirmed", app); childReveal(confirmed, app)
        XCTAssertTrue(confirmed.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["childTransferStatus"].label.contains("Subtask moved"))
        structureSnapshot(app, "Transfer confirmation remains open after source row disappears")
        let immediateUndo = app.buttons["Undo move"]; childReveal(immediateUndo, app)
        XCTAssertTrue(immediateUndo.isHittable, app.debugDescription)
        XCTAssertGreaterThan(immediateUndo.frame.height, 44)
        structureSnapshot(app, "Largest text Undo action remains readable and reachable")
        childDone(app); childDone(app)
        childProbe(app, "transferWrites=1 transferRequests=1 transferSource=review transferDestination=concept>nested")
        app.terminate(); try childOpen(app, reset: false, extra: "--child-transfer-native", large: true)
        childHomePress("childNativeTransfers", app)
        let undo = app.buttons["Undo move"]; childReveal(undo, app); completionReadyPress(undo, app)
        let restored = childSavedText("Move undone", app); childReveal(restored, app)
        XCTAssertTrue(restored.waitForExistence(timeout: 15), app.debugDescription)
        structureSnapshot(app, "Certified Undo restores original branch after relaunch")
        childDone(app); childProbe(app, "transferWrites=2 transferRequests=2 transferSource=concept>nested>review transferDestination=")
    }
    @MainActor func testChildTransferNativeLostReplyColdRetryUsesOriginalRequest() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childOpen(app, extra: "--child-transfer-lose-reply")
        transferReview(app)
        XCTAssertTrue(childSavedText("Awaiting confirmation", app).waitForExistence(timeout: 15), app.debugDescription)
        childDone(app); childDone(app); childProbe(app, "transferQueued=0 transferAttempted=1 transferApplied=0 transferClosed=0 transferWrites=1 transferRequests=1")
        app.terminate(); try childOpen(app, reset: false, extra: "--child-transfer-native")
        childHomePress("childNativeTransfers", app)
        let retry = app.buttons["Retry original move"]; childReveal(retry, app); completionReadyPress(retry, app)
        let confirmed = childSavedText("Move confirmed", app); childReveal(confirmed, app)
        XCTAssertTrue(confirmed.waitForExistence(timeout: 15), app.debugDescription)
        structureSnapshot(app, "Original transfer retry confirms without a second write")
        childDone(app); childProbe(app, "transferQueued=0 transferAttempted=0 transferApplied=1 transferClosed=0 transferWrites=1 transferRequests=2")
    }

    @MainActor private func adoptionProbeValue(_ key: String, _ app: XCUIApplication) -> String {
        let probe = app.staticTexts["childNativeProbe"]; childReveal(probe, app, diagnosticText: true)
        let prefix = key + "="
        return probe.label.split(separator: " ").first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) } ?? "missing"
    }
    @MainActor private func adoptionReview(_ app: XCUIApplication) {
        childHomePress("childNativeAdoption", app)
        let count = app.staticTexts["childAdoptionCount"]; childReveal(count, app)
        XCTAssertEqual(count.label, "3 saved subtasks", app.debugDescription)
        let send = app.buttons["childAdoptionSend"]; childReveal(send, app)
        XCTAssertTrue(send.isEnabled, app.debugDescription)
        structureSnapshot(app, "Review original older subtasks before upgrade")
        completionReadyPress(send, app)
    }
    @MainActor func testChildAdoptionNativeUnreadableWorkspaceAllowsReviewButRefusesUpgrade() throws {
        let app=XCUIApplication();addTeardownBlock { @MainActor in app.terminate() }
        try childOpen(app,extra:"--child-adoption-unreadable-cache",large:true)
        let original=adoptionProbeValue("adoptionRootHash",app)
        childHomePress("childNativeAdoptionRecovery",app)
        let target=app.buttons["childAdoptionTarget-ec990000-0000-4000-8000-000000000002"];childReveal(target,app);completionReadyPress(target,app)
        let count=app.staticTexts["childAdoptionCount"];childReveal(count,app);XCTAssertEqual(count.label,"3 saved subtasks")
        let send=app.buttons["childAdoptionSend"];childReveal(send,app,diagnosticText:true);XCTAssertFalse(send.isEnabled)
        let hint=app.staticTexts["childAdoptionLocalReviewOnly"];childReveal(hint,app,diagnosticText:true);XCTAssertTrue(hint.label.contains("workspace needs recovery"))
        let export=app.buttons["childAdoptionExport"];childReveal(export,app);XCTAssertTrue(export.isEnabled)
        structureSnapshot(app,"Unreadable saved workspace keeps remote review and export available but blocks upgrade")
        childDone(app);childProbe(app,"adoptionWrites=0 adoptionRequests=0");XCTAssertEqual(adoptionProbeValue("adoptionRootHash",app),original)
        childHomePress("childNativeAdoptionDirectAdmission",app)
        let admission=app.staticTexts["childNativeAdoptionAdmissionResult"];childReveal(admission,app,diagnosticText:true)
        XCTAssertEqual(admission.label,"Unverified saved edits protected")
        childProbe(app,"adoptionWrites=0 adoptionRequests=0");XCTAssertEqual(adoptionProbeValue("adoptionRootHash",app),original)
    }
    @MainActor func testChildAdoptionNativeDiscoveryWithoutEditableTaskCache() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childOpen(app, extra: "--child-adoption-empty-cache", large: true)
        let original = adoptionProbeValue("adoptionRootHash", app)
        childHomePress("childNativeAdoptionRecovery", app)
        let target = app.buttons["childAdoptionTarget-ec990000-0000-4000-8000-000000000002"]
        childReveal(target,app); XCTAssertTrue(target.isEnabled); structureSnapshot(app,"Live metadata finds older work without editable task cache")
        completionReadyPress(target,app)
        let count=app.staticTexts["childAdoptionCount"];childReveal(count,app);XCTAssertEqual(count.label,"3 saved subtasks")
        let title=app.staticTexts["childAdoptionTaskTitle"];childReveal(title,app);XCTAssertEqual(title.label,"Native child workspace")
        let send=app.buttons["childAdoptionSend"];childReveal(send,app);completionReadyPress(send,app)
        let status=childSavedText("Subtasks upgraded",app);childReveal(status,app);XCTAssertTrue(status.waitForExistence(timeout:15))
        structureSnapshot(app,"Metadata-only older work upgrades with a retained decision")
        childDone(app);childProbe(app,"adoptionWrites=1 adoptionRequests=1");XCTAssertEqual(adoptionProbeValue("adoptionRootHash",app),original)
        app.terminate();try childOpen(app,reset:false,extra:"--child-adoption-empty-cache",large:true)
        childHomePress("childNativeAdoptionRecovery",app)
        let coldStatus=childSavedText("Subtasks upgraded",app);childReveal(coldStatus,app,diagnosticText:true)
        XCTAssertTrue(coldStatus.waitForExistence(timeout:15));structureSnapshot(app,"Older-work decision survives cold return without task cache")
        childDone(app);childProbe(app,"adoptionWrites=1 adoptionRequests=1");XCTAssertEqual(adoptionProbeValue("adoptionRootHash",app),original)
    }
    @MainActor func testChildAdoptionNativeLargestReviewUpgradeAndColdStatus() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childOpen(app, extra: "--child-adoption-native", large: true)
        let original = adoptionProbeValue("adoptionRootHash", app); XCTAssertEqual(original.count, 64)
        childProbe(app, "adoptionWrites=0 adoptionRequests=0")
        adoptionReview(app)
        let status = childSavedText("Subtasks upgraded", app); childReveal(status, app)
        XCTAssertTrue(status.waitForExistence(timeout: 15), app.debugDescription)
        structureSnapshot(app, "Largest text subtask upgrade confirmation")
        childDone(app); childProbe(app, "adoptionWrites=1 adoptionRequests=1")
        XCTAssertEqual(adoptionProbeValue("adoptionRootHash", app), original)
        app.terminate(); try childOpen(app, reset: false, extra: "--child-adoption-native", large: true)
        childHomePress("childNativeAdoption", app)
        let current = app.staticTexts["childAdoptionCurrent"]; childReveal(current, app)
        XCTAssertTrue(current.waitForExistence(timeout: 15), app.debugDescription)
        structureSnapshot(app, "Cold launch reports previously upgraded subtasks")
        childDone(app); childProbe(app, "adoptionWrites=1 adoptionRequests=1")
        XCTAssertEqual(adoptionProbeValue("adoptionRootHash", app), original)
    }
    @MainActor func testChildAdoptionNativeLostReplyColdRetryUsesOriginalRequest() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childOpen(app, extra: "--child-adoption-lose-reply")
        let original = adoptionProbeValue("adoptionRootHash", app); XCTAssertEqual(original.count, 64)
        adoptionReview(app)
        XCTAssertTrue(childSavedText("Awaiting confirmation", app).waitForExistence(timeout: 15), app.debugDescription)
        childDone(app); childProbe(app, "adoptionQueued=0 adoptionAttempted=1 adoptionApplied=0 adoptionClosed=0 adoptionWrites=1 adoptionRequests=1")
        app.terminate(); try childOpen(app, reset: false, extra: "--child-adoption-native")
        childHomePress("childNativeAdoptionRecovery", app)
        let retry = app.buttons["Retry original upgrade"]; childReveal(retry, app); completionReadyPress(retry, app)
        let status = childSavedText("Subtasks upgraded", app); childReveal(status, app)
        XCTAssertTrue(status.waitForExistence(timeout: 15), app.debugDescription)
        structureSnapshot(app, "Cold original upgrade retry confirms without duplicate writes")
        childDone(app); childProbe(app, "adoptionQueued=0 adoptionAttempted=0 adoptionApplied=1 adoptionClosed=0 adoptionWrites=1 adoptionRequests=2")
        XCTAssertEqual(adoptionProbeValue("adoptionRootHash", app), original)
    }
    @MainActor func testChildAdoptionNativePrivateDraftProtectionAndUnappliedStop() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childOpen(app, extra: "--child-adoption-unapplied")
        let original = adoptionProbeValue("adoptionRootHash", app); XCTAssertEqual(original.count, 64)
        childHomePress("childNativeAdoptionPrivate", app)
        let hash = adoptionProbeValue("adoptionPrivateHash", app); XCTAssertEqual(hash.count, 64)
        adoptionReview(app)
        let feedback = app.staticTexts["childAdoptionFeedback"]; childReveal(feedback, app)
        XCTAssertTrue(feedback.label.contains("saved edits"), app.debugDescription)
        structureSnapshot(app, "Private saved edits prevent older-subtask upgrade")
        childDone(app); childProbe(app, "adoptionWrites=0 adoptionRequests=0")
        XCTAssertEqual(adoptionProbeValue("adoptionPrivateHash", app), hash)
        app.terminate(); try childOpen(app, reset: false, extra: "--child-adoption-unapplied")
        XCTAssertEqual(adoptionProbeValue("adoptionPrivateHash", app), hash)
        XCTAssertEqual(adoptionProbeValue("adoptionRootHash", app), original)
        childHomePress("childNativeAdoptionRemovePrivate", app)
        adoptionReview(app)
        XCTAssertTrue(childSavedText("Awaiting confirmation", app).waitForExistence(timeout: 15), app.debugDescription)
        let stop = app.buttons["Check and stop upgrade"]; childReveal(stop, app); completionReadyPress(stop, app)
        childPress(app.buttons["Check and stop"].firstMatch)
        let closed = childSavedText("Upgrade stopped", app); childReveal(closed, app)
        XCTAssertTrue(closed.waitForExistence(timeout: 15), app.debugDescription)
        structureSnapshot(app, "Unapplied upgrade safely stopped")
        childDone(app); childProbe(app, "adoptionQueued=0 adoptionAttempted=0 adoptionApplied=0 adoptionClosed=1 adoptionWrites=0 adoptionRequests=2")
        XCTAssertEqual(adoptionProbeValue("adoptionRootHash", app), original)
    }
    @MainActor private func repairReview(_ app: XCUIApplication) {
        childHomePress("childNativeRepair", app)
        let reference = app.buttons["childRepairReference-0"];childReveal(reference,app);XCTAssertTrue(reference.waitForExistence(timeout:15),app.debugDescription);completionReadyPress(reference,app)
        let wrap = app.buttons["childRepairWrap-1"];childReveal(wrap,app);completionReadyPress(wrap,app)
        let ready = app.staticTexts["childRepairReady"];childReveal(ready,app);XCTAssertTrue(ready.waitForExistence(timeout:15),app.debugDescription)
    }
    @MainActor func testChildRepairNativeReviewSaveAndColdConfirmation() throws {
        let app=XCUIApplication();addTeardownBlock { @MainActor in app.terminate() }
        try childOpen(app,extra:"--child-adoption-repair")
        let before=adoptionProbeValue("adoptionRootHash",app);XCTAssertEqual(before.count,64)
        repairReview(app)
        structureSnapshot(app,"Review keeps original and lists two repaired tasks")
        let save=app.buttons["childRepairSave"];childReveal(save,app);XCTAssertTrue(save.isEnabled);completionReadyPress(save,app)
        childPress(app.buttons["Save repair"].firstMatch)
        let status=app.staticTexts["childRepairStatus"];childReveal(status,app)
        XCTAssertTrue(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"label == %@","Repair saved"),object:status)],timeout:15) == .completed,app.debugDescription)
        XCTAssertTrue(app.buttons["childRepairExportSaved"].exists)
        structureSnapshot(app,"Repair confirmed with original available")
        childPress(app.buttons["Close"].firstMatch)
        childProbe(app,"repairWrites=1 repairApplied=1 repairPending=0")
        XCTAssertEqual(adoptionProbeValue("repairOriginalRootHash",app),before)
        let after=adoptionProbeValue("adoptionRootHash",app);XCTAssertNotEqual(before,after)
        app.terminate();try childOpen(app,reset:false,extra:"--child-adoption-repair")
        XCTAssertEqual(adoptionProbeValue("adoptionRootHash",app),after)
        childProbe(app,"repairWrites=1 repairApplied=1 repairPending=0")
        XCTAssertEqual(adoptionProbeValue("repairOriginalRootHash",app),before)
        childHomePress("childNativeRepairRecovery",app)
        let saved=app.staticTexts["childRepairStatus"];childReveal(saved,app);XCTAssertEqual(saved.label,"Repair saved")
        XCTAssertTrue(app.buttons["childRepairExportSaved"].isEnabled)
        structureSnapshot(app,"Cold saved repair and original access survive relaunch")
    }
    @MainActor func testChildRepairNativePrivateDraftBlocksSaving() throws {
        let app=XCUIApplication();addTeardownBlock { @MainActor in app.terminate() }
        try childOpen(app,extra:"--child-adoption-repair")
        let before=adoptionProbeValue("adoptionRootHash",app)
        childHomePress("childNativeAdoptionPrivate",app)
        repairReview(app)
        let save=app.buttons["childRepairSave"];childReveal(save,app);completionReadyPress(save,app);childPress(app.buttons["Save repair"].firstMatch)
        let feedback=app.staticTexts["childRepairFeedback"];childReveal(feedback,app)
        XCTAssertTrue(feedback.label.contains("saved edits"),app.debugDescription)
        XCTAssertFalse(app.staticTexts["childRepairStatus"].exists)
        structureSnapshot(app,"Private editor recovery blocks repair submission")
        childPress(app.buttons["Close"].firstMatch)
        childPress(app.buttons["Discard review"].firstMatch)
        XCTAssertEqual(adoptionProbeValue("adoptionRootHash",app),before)
        XCTAssertEqual(adoptionProbeValue("adoptionPrivateHash",app).count,64)
    }

    @MainActor func testChildAdoptionNativeMalformedReviewAndOriginalExportCancel() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childOpen(app, extra: "--child-adoption-malformed")
        let original = adoptionProbeValue("adoptionRootHash", app); XCTAssertEqual(original.count, 64)
        childHomePress("childNativeAdoption", app)
        let warning = app.staticTexts["childAdoptionNeedsReview"]; childReveal(warning, app)
        XCTAssertTrue(warning.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.buttons["childAdoptionSend"].exists)
        let export = app.buttons["childAdoptionExport"]; childReveal(export, app); XCTAssertTrue(export.isEnabled)
        structureSnapshot(app, "Malformed older content retained with original export")
        completionReadyPress(export, app)
        let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == 'Close'")).firstMatch
        #if os(iOS)
        let save = app.buttons["DOCPicker.actionButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 20), app.debugDescription)
        if cancel.waitForExistence(timeout: 3) { childPress(cancel) }
        else {
            // The native iOS picker can omit Cancel. Dismiss that verified
            // picker using its ordinary interactive dismissal, without Save.
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let x = save.frame.minX - 12 - app.frame.minX, y = save.frame.midY - app.frame.minY
            origin.withOffset(CGVector(dx: x, dy: y)).press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x, dy: app.frame.height - 30)), withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(save.waitForNonExistence(timeout: 15), app.debugDescription)
        #else
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), app.debugDescription); childPress(cancel)
        #endif
        XCTAssertTrue(warning.waitForExistence(timeout: 15), app.debugDescription)
        structureSnapshot(app, "Original export cancelled without changing older content")
        childDone(app); childProbe(app, "adoptionWrites=0 adoptionRequests=0")
        XCTAssertEqual(adoptionProbeValue("adoptionRootHash", app), original)
    }

    @MainActor private func adoptionExportHome() throws -> URL {
        #if os(iOS)
        return try audioTaskHome()
        #else
        return URL(fileURLWithPath: "/Users/" + NSUserName() + "/Library/Containers/com.dbakp.taskfold.mac.workflowteststeameditbridge/Data", isDirectory: true)
        #endif
    }
    @MainActor func testChildAdoptionNativeOriginalExportSaveAndColdReadback() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try childOpen(app, extra: "--child-adoption-export", large: true)
        let home = try adoptionExportHome(), peer = home.appendingPathComponent("Library/Application Support/Child field native peer", isDirectory: true)
        let expectedFile = peer.appendingPathComponent("adoption-export-original.json"), receipt = peer.appendingPathComponent("adoption-export-receipt.json")
        let destination = home.appendingPathComponent("Documents/Taskfold-original-subtasks-proof.json")
        let expected = try Data(contentsOf: expectedFile)
        XCTAssertTrue(expected.range(of: Data("9007199254740993".utf8)) != nil)
        XCTAssertTrue(expected.range(of: Data("1e1000".utf8)) != nil)
        XCTAssertTrue(expected.range(of: Data("\"é\"".utf8)) != nil)
        XCTAssertTrue(expected.range(of: Data("\"e\u{0301}\"".utf8)) != nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
        let originalRoot = adoptionProbeValue("adoptionRootHash", app); XCTAssertEqual(originalRoot.count, 64)
        childHomePress("childNativeAdoption", app)
        let warning = app.staticTexts["childAdoptionNeedsReview"]; childReveal(warning, app)
        XCTAssertFalse(app.buttons["childAdoptionSend"].exists)
        let export = app.buttons["childAdoptionExport"]; childReveal(export, app); completionReadyPress(export, app)
        #if os(iOS)
        let save = app.buttons["DOCPicker.actionButton"]; XCTAssertTrue(save.waitForExistence(timeout: 25), app.debugDescription)
        let folder = app.collectionViews.staticTexts["Taskfold Team Editor Test"].firstMatch
        if folder.waitForExistence(timeout: 3), folder.isHittable { childPress(folder) }
        let provider = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "DOC.browsingRoot Source: com.apple.FileProvider.LocalStorage,")).firstMatch
        let namedRoot = app.otherElements["DOC.browsingRoot Source: com.apple.FileProvider.LocalStorage, Title: Taskfold Team Editor Test"]
        let namedToolbar = app.buttons["Taskfold Team Editor Test, Actions Menu"]
        let marker = app.collectionViews.staticTexts["Taskfold-originals-destination"].firstMatch
        guard provider.waitForExistence(timeout: 8), namedRoot.exists || namedToolbar.exists, marker.waitForExistence(timeout: 8) else {
            XCTFail("Save only to the isolated app’s observed local Documents: " + app.debugDescription); return
        }
        structureSnapshot(app, "Original subtask export uses observed local Files destination")
        childPress(save); XCTAssertTrue(save.waitForNonExistence(timeout: 15), app.debugDescription)
        #else
        let save = app.sheets.buttons["Save"].firstMatch.exists ? app.sheets.buttons["Save"].firstMatch : app.sheets.buttons["Export"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 15), app.debugDescription)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.sheets.textFields["PathTextField"].firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 8), app.debugDescription)
        path.click(); app.typeKey("a", modifierFlags: .command); path.typeText(destination.deletingLastPathComponent().path); app.typeKey(.return, modifierFlags: [])
        let name = app.sheets.textFields.matching(NSPredicate(format: "value CONTAINS %@", "Taskfold-original-subtasks-proof")).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 8), app.debugDescription)
        structureSnapshot(app, "Original subtask export uses isolated local Documents")
        childPress(save)
        #endif
        let delivered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: receipt.path) && FileManager.default.fileExists(atPath: destination.path) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [delivered], timeout: 15), .completed)
        let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: String])
        XCTAssertNotNil(result["request"].flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(result["account"], "ec990000-0000-4000-8000-000000000001")
        XCTAssertEqual(result["root"], "ec990000-0000-4000-8000-000000000002")
        let picked = try XCTUnwrap(result["url"].flatMap(URL.init(string:)))
        XCTAssertTrue(picked.isFileURL); XCTAssertEqual(picked.resolvingSymlinksInPath(), destination.resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: picked), expected); XCTAssertEqual(try Data(contentsOf: expectedFile), expected)
        let feedback = app.staticTexts["childAdoptionExportFeedback"]; childReveal(feedback, app, diagnosticText: true)
        XCTAssertEqual(feedback.label, "Original content exported. Your saved task is unchanged.")
        let proof = XCTAttachment(data: try Data(contentsOf: destination), uniformTypeIdentifier: "public.json"); proof.name = "Original subtask bytes delivered by native Save"; proof.lifetime = .keepAlways; add(proof)
        structureSnapshot(app, "Original subtask export confirms complete byte preservation")
        childDone(app); childProbe(app, "adoptionWrites=0 adoptionRequests=0")
        XCTAssertEqual(adoptionProbeValue("adoptionRootHash", app), originalRoot)
        app.terminate(); try childOpen(app, reset: false, extra: "--child-adoption-export", large: true)
        XCTAssertEqual(try Data(contentsOf: picked), expected); XCTAssertEqual(try Data(contentsOf: expectedFile), expected)
        XCTAssertEqual(adoptionProbeValue("adoptionRootHash", app), originalRoot)
        childHomePress("childNativeAdoption", app)
        childReveal(warning, app)
        XCTAssertTrue(warning.waitForExistence(timeout: 15), app.debugDescription); XCTAssertFalse(app.buttons["childAdoptionSend"].exists)
        XCTAssertFalse(app.staticTexts["childAdoptionExportFeedback"].exists, "Fresh review must not inherit old export feedback")
        structureSnapshot(app, "Saved original export and malformed review survive cold return")
    }

}

extension TaskfoldMacUITests {
    @MainActor private func mixedLaunch(_ app: XCUIApplication, reset: Bool, lost: Bool = false) throws {
        try childGuard()
        #if os(macOS)
        throw XCTSkip("Mac mixed selection uses the authorized direct app walkthrough")
        #else
        app.launchArguments = ["--uitesting", "--team-editor-testing", "--child-fields-native", "--child-fields-main-list", "--child-fields-list-completion", "--mixed-completion-native", "-appearance", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL", "-ApplePersistenceIgnoreState", "YES"]
        if reset { app.launchArguments.append("--child-fields-native-reset") }
        if lost { app.launchArguments.append("--mixed-completion-lose-reply") }
        app.launch(); app.activate()
        let expand = app.buttons["expandChildRows-ec990000-0000-4000-8000-000000000002"]
        XCTAssertTrue(expand.waitForExistence(timeout: 30), app.debugDescription)
        if expand.value as? String != "Expanded" { childPress(expand) }
        #endif
    }
    @MainActor private func mixedSelectAndComplete(_ app: XCUIApplication) throws {
        let options = app.buttons["Task options"]; XCTAssertTrue(options.waitForExistence(timeout: 15), app.debugDescription); childPress(options)
        let select = app.buttons["Select tasks"]; XCTAssertTrue(select.waitForExistence(timeout: 10), app.debugDescription); childPress(select)
        for title in ["Plan the workshop", "Prepare the review"] {
            let row = app.buttons["Select " + title]; childReveal(row, app); XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription); childPress(row)
        }
        let complete = app.buttons["Complete selected tasks"].firstMatch; XCTAssertTrue(complete.waitForExistence(timeout: 10), app.debugDescription); childPress(complete)
    }
    @MainActor private func mixedAssertRestored(_ app: XCUIApplication) {
        let root = app.buttons["Complete Plan the workshop"]; XCTAssertTrue(root.waitForExistence(timeout: 20), app.debugDescription)
        let expand = app.buttons["expandChildRows-ec990000-0000-4000-8000-000000000002"]
        if expand.exists, expand.value as? String != "Expanded" { childPress(expand) }
        XCTAssertTrue(app.buttons["Complete Prepare the review"].waitForExistence(timeout: 15), app.debugDescription)
    }
    @MainActor func testMixedSelectionWholeUndoAndColdReturn() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try mixedLaunch(app, reset: true); try mixedSelectAndComplete(app)
        let undo = app.buttons["undoToast"]; XCTAssertTrue(undo.waitForExistence(timeout: 20), app.debugDescription)
        structureSnapshot(app, "Parent and subtask completed together with Undo")
        childPress(undo); mixedAssertRestored(app)
        app.terminate(); try mixedLaunch(app, reset: false); mixedAssertRestored(app)
        structureSnapshot(app, "Parent and subtask Undo survive cold return")
    }
    @MainActor func testMixedLostReplyColdReturnRetriesOriginalAndUndoesWholeSelection() throws {
        let app = XCUIApplication(); addTeardownBlock { @MainActor in app.terminate() }
        try mixedLaunch(app, reset: true, lost: true); try mixedSelectAndComplete(app)
        XCTAssertTrue(app.buttons["reviewListMixedGroup"].waitForExistence(timeout: 20), app.debugDescription)
        app.terminate(); try mixedLaunch(app, reset: false, lost: true)
        let settings = app.buttons["openSettings"]; XCTAssertTrue(settings.waitForExistence(timeout: 20), app.debugDescription); childPress(settings)
        let account = app.buttons["settings-Account"]; childReveal(account,app); XCTAssertTrue(account.exists,app.debugDescription);childPress(account)
        let saved = app.buttons["savedMixedGroups"]; childReveal(saved,app);XCTAssertTrue(saved.waitForExistence(timeout:15),app.debugDescription);childPress(saved)
        let retry = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","sendMixedGroup-")).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout:20),app.debugDescription);childPress(retry)
        let confirmed = app.staticTexts.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)","mixedGroupPhase-","Confirmed","Confirmed")).firstMatch
        XCTAssertTrue(confirmed.waitForExistence(timeout:20),app.debugDescription)
        let undo=app.buttons["undoSavedMixedGroup"];XCTAssertTrue(undo.waitForExistence(timeout:10),app.debugDescription);childPress(undo)
        let confirm=app.alerts.firstMatch.buttons["Undo selection"];XCTAssertTrue(confirm.waitForExistence(timeout:10),app.debugDescription);childPress(confirm)
        let undone=app.staticTexts.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND (label == %@ OR value == %@)","mixedGroupPhase-","Undone","Undone")).firstMatch
        XCTAssertTrue(undone.waitForExistence(timeout:20),app.debugDescription)
        structureSnapshot(app,"Interrupted mixed selection recovered after cold return and undone together")
    }
}
