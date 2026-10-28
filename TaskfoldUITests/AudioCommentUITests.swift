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
    @MainActor private func audioOpen(_ app: XCUIApplication, reset: Bool = true, denied: Bool = false, large: Bool = false, lostSave: Bool = false, beforeDraft: Bool = false, lostDiscard: Bool = false, lookupLock: Bool = false) {
        app.launchArguments = ["--uitesting", "--team-editor-testing", "--audio-comment-testing", "-appearance", large || denied ? "dark" : "light"]
        if reset { app.launchArguments.append("--audio-comment-reset") }
        if lostSave { app.launchArguments.append("--audio-save-lost-ack") }
        if beforeDraft { app.launchArguments.append("--audio-save-before-draft") }
        if lostDiscard { app.launchArguments.append("--audio-discard-lost-ack") }
        if lookupLock { app.launchArguments.append("--audio-save-lookup-lock") }
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
