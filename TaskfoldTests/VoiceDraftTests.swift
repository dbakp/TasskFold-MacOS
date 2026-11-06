import XCTest
@testable import TaskfoldCore

final class VoiceDraftTests: XCTestCase {
    let binding = WorkspaceBinding(account: "a", generation: UUID())
    func testPartialResultsReplaceRatherThanDuplicateWords() throws {
        var s = VoiceDraftSession(request: VoiceDraftRequest(workspace: binding, original: "Original"))
        let token = try XCTUnwrap(s.begin(account: binding.account, generation: binding.generation))
        s.started(token, account: binding.account, generation: binding.generation)
        XCTAssertTrue(try s.receive("Review", token: token, account: binding.account, generation: binding.generation))
        XCTAssertTrue(try s.receive("Review the layout", token: token, account: binding.account, generation: binding.generation))
        XCTAssertEqual(s.text, "Review the layout")
    }
    func testAnotherRecordingAddsALineAndKeepsCorrections() throws {
        var s = VoiceDraftSession(request: VoiceDraftRequest(workspace: binding, original: "Original")); try s.edit("Corrected first task")
        let token = try XCTUnwrap(s.begin(account: binding.account, generation: binding.generation))
        s.started(token, account: binding.account, generation: binding.generation)
        _ = try s.receive("Next task", token: token, account: binding.account, generation: binding.generation)
        _ = try s.receive("Next task tomorrow", token: token, account: binding.account, generation: binding.generation)
        XCTAssertEqual(s.text, "Corrected first task\nNext task tomorrow")
    }
    func testPermissionRefusalKeepsEarlierTextAndInvalidatesCallbacks() throws {
        var s = VoiceDraftSession(request: VoiceDraftRequest(workspace: binding, original: "Original")); try s.edit("Keep this draft")
        let token = try XCTUnwrap(s.begin(account: binding.account, generation: binding.generation)); s.stop()
        XCTAssertEqual(s.text, "Keep this draft")
        XCTAssertFalse(try s.receive("late result", token: token, account: binding.account, generation: binding.generation))
        XCTAssertEqual(s.text, "Keep this draft")
    }
    func testFinishingAllowsFinalCorrectionThenFreezesTheTranscript() throws {
        var s = VoiceDraftSession(request: VoiceDraftRequest(workspace: binding, original: "Original"))
        let token = try XCTUnwrap(s.begin(account: binding.account, generation: binding.generation)); s.started(token, account: binding.account, generation: binding.generation)
        _ = try s.receive("Send design", token: token, account: binding.account, generation: binding.generation)
        s.finishing(); _ = try s.receive("Send the design notes", token: token, account: binding.account, generation: binding.generation)
        s.stop(); try s.edit("Send the corrected notes")
        XCTAssertFalse(try s.receive("late overwrite", token: token, account: binding.account, generation: binding.generation))
        XCTAssertEqual(s.text, "Send the corrected notes")
    }
    func testOldRecordingCannotReplaceNewRecording() throws {
        var s = VoiceDraftSession(request: VoiceDraftRequest(workspace: binding, original: "Original"))
        let old = try XCTUnwrap(s.begin(account: binding.account, generation: binding.generation)); s.stop()
        let current = try XCTUnwrap(s.begin(account: binding.account, generation: binding.generation)); s.started(current, account: binding.account, generation: binding.generation)
        XCTAssertNotEqual(old, current)
        XCTAssertFalse(try s.receive("wrong", token: old, account: binding.account, generation: binding.generation))
        XCTAssertTrue(try s.receive("right", token: current, account: binding.account, generation: binding.generation))
        XCTAssertEqual(s.text, "right")
    }
    func testAccountSwitchAndReturnCannotDeliverOldResultsOrApply() throws {
        var s = VoiceDraftSession(request: VoiceDraftRequest(workspace: binding, original: "Original"))
        let token = try XCTUnwrap(s.begin(account: binding.account, generation: binding.generation)); s.started(token, account: binding.account, generation: binding.generation)
        XCTAssertFalse(try s.receive("other account", token: token, account: "b", generation: binding.generation))
        XCTAssertFalse(try s.receive("returned account", token: token, account: binding.account, generation: UUID()))
        s.stop(); try s.edit("Reviewed")
        let request = s.request
        XCTAssertThrowsError(try s.applying(to: "Original", request: request, account: binding.account, generation: UUID()))
        XCTAssertThrowsError(try s.applying(to: "Original", request: request, account: "b", generation: binding.generation))
    }
    func testNoOverlappingRecordingAndNoEditingWhileBusy() throws {
        var s = VoiceDraftSession(request: VoiceDraftRequest(workspace: binding, original: "Original")); try s.edit("Keep")
        let token = try XCTUnwrap(s.begin(account: binding.account, generation: binding.generation))
        XCTAssertNil(s.begin(account: binding.account, generation: binding.generation)); try s.edit("Overwrite")
        XCTAssertEqual(s.text, "Keep")
        XCTAssertFalse(try s.receive("premature partial", token: token, account: binding.account, generation: binding.generation))
    }
    func testApplyRequiresReviewAndAnUnchangedSource() throws {
        let request = VoiceDraftRequest(workspace: binding, original: "Keep original  \n")
        var s = VoiceDraftSession(request: request); try s.edit("New task")
        XCTAssertEqual(try s.applying(to: request.original, request: request, account: binding.account, generation: binding.generation), "Keep original  \nNew task")
        XCTAssertThrowsError(try s.applying(to: "Externally changed", request: request, account: binding.account, generation: binding.generation))
        _ = s.begin(account: binding.account, generation: binding.generation)
        XCTAssertThrowsError(try s.applying(to: request.original, request: request, account: binding.account, generation: binding.generation))
        s.close(); XCTAssertThrowsError(try s.applying(to: request.original, request: request, account: binding.account, generation: binding.generation))
        XCTAssertNil(s.begin(account: binding.account, generation: binding.generation))
    }
    func testAnEquivalentNewRequestCannotRetargetAnOldTranscript() throws {
        let request = VoiceDraftRequest(workspace: binding, original: "Original")
        var s = VoiceDraftSession(request: request); try s.edit("Only this review")
        let replacement = VoiceDraftRequest(workspace: binding, original: "Original")
        XCTAssertThrowsError(try s.applying(to: replacement.original, request: replacement, account: binding.account, generation: binding.generation))
        XCTAssertEqual(try s.applying(to: request.original, request: request, account: binding.account, generation: binding.generation), "Original\nOnly this review")
    }
    func testCompositionPreservesOriginalAndUnicodeWithoutInventingTasks() throws {
        XCTAssertEqual(try VoiceDraftSession.appending("  مراجعة التصميم 🪴\r\n買い物  ", to: "Original  "), "Original  \nمراجعة التصميم 🪴\n買い物")
        XCTAssertEqual(try VoiceDraftSession.appending("one and two", to: ""), "one and two")
        XCTAssertEqual(try VoiceDraftSession.appending("", to: "Original", allowEmpty: true), "Original")
        XCTAssertThrowsError(try VoiceDraftSession.appending("  \n", to: "Original"))
    }
    func testOversizedResultsNeverTruncateOrOverwriteTheLastValidText() throws {
        var s = VoiceDraftSession(request: VoiceDraftRequest(workspace: binding, original: "Original")); try s.edit("Keep")
        let token = try XCTUnwrap(s.begin(account: binding.account, generation: binding.generation)); s.started(token, account: binding.account, generation: binding.generation)
        XCTAssertThrowsError(try s.receive(String(repeating: "🪴", count: 25_001), token: token, account: binding.account, generation: binding.generation))
        XCTAssertEqual(s.text, "Keep")
        XCTAssertThrowsError(try VoiceDraftSession.appending("one more", to: String(repeating: "x", count: 100_000)))
        XCTAssertThrowsError(try VoiceDraftSession.appending("bad\0text", to: ""))
    }
    func testAppliedTextUsesExistingParserAndExplicitBulkValidation() throws {
        let text = try VoiceDraftSession.appending("Send review tomorrow p2\nBook studio", to: "Original task")
        let preview = try MultiLineCapture.preview(text, account: binding.account, recognize: true)
        XCTAssertEqual(preview.count, 3); XCTAssertEqual(preview[1].task.title, "Send review"); XCTAssertEqual(preview[1].task.priority, 2)
        XCTAssertFalse(preview[1].task.string("due_date").isEmpty)
        let tooMany = (1...201).map { "Task \($0)" }.joined(separator: "\n")
        XCTAssertThrowsError(try MultiLineCapture.preview(VoiceDraftSession.appending(tooMany, to: ""), account: binding.account))
    }
}


extension VoiceDraftTests {
    func testCanonicallyEquivalentParentEditsCannotReceiveAnOlderTranscript() throws {
        let spellings = [("Café", "Cafe\u{301}"), ("각", "\u{1100}\u{1161}\u{11a8}"), ("a\u{323}\u{301}", "a\u{301}\u{323}")]
        for (captured, edited) in spellings {
            XCTAssertEqual(captured, edited, "The regression needs semantically equal but raw-different text")
            XCTAssertNotEqual(Array(captured.utf8), Array(edited.utf8))
            let request = VoiceDraftRequest(workspace: binding, original: captured)
            XCTAssertFalse(request.matchesOriginal(edited), "The parent adapter uses the same exact-source guard")
            XCTAssertTrue(request.matchesOriginal(captured))
            var session = VoiceDraftSession(request: request); try session.edit("Reviewed task")
            XCTAssertThrowsError(try session.applying(to: edited, request: request, account: binding.account, generation: binding.generation))
            XCTAssertEqual(Array(try session.applying(to: captured, request: request, account: binding.account, generation: binding.generation).utf8), Array((captured + "\nReviewed task").utf8))
            XCTAssertEqual(session.text, "Reviewed task", "Refusal must preserve the transcript for recovery")
        }
    }
}
