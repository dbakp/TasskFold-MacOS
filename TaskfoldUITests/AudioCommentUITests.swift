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
        app.activate(); XCTAssertTrue(app.buttons["childNativeEditor"].waitForExistence(timeout: 25), app.debugDescription)
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
            let bottom = min(bounds.maxY, keyboard.exists && !keyboard.frame.isEmpty ? keyboard.frame.minY : bounds.maxY)
            return CGRect(x: bounds.minX + 4, y: top + 4, width: bounds.width - 8, height: max(0, bottom - top - 8))
        }
        func visible() -> Bool {
            guard value.exists, !value.frame.isEmpty else { return false }
            #if os(iOS)
            let viewport = area()
            if diagnosticText && value.frame.height > viewport.height { return value.frame.intersection(viewport).height >= 24 }
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
        let probe = app.staticTexts["childNativeProbe"]; childReveal(probe, app, diagnosticText: true)
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

}
