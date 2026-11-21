import XCTest
@testable import InspectorTextSaveModel

/// The Mac inspector's team-text save rule: typing in a team task's title or notes waits for a commit point.
final class InspectorTextSaveTests: XCTestCase {
    /// Mirrors the inspector: each keystroke either starts the 0.6 s debounce or defers; a blur, Return or close commits once.
    private func saves(isTeam: Bool, focused: Bool, keystrokes: Int, key: String, commitAtEnd: Bool) -> Int {
        var scheduled = 0, commits = 0, pending = false
        for _ in 0..<keystrokes {
            if InspectorTextSave.defersAutosave(isTeamTask: isTeam, textFieldFocused: focused, changedKeys: [key]) { pending = true }
            else { scheduled += 1 } // each debounce window that elapses is one save; typing without pauses collapses to one
        }
        if commitAtEnd, pending { commits += 1 }
        return scheduled + commits
    }

    func testTeamTitleTypingThenBlurSavesExactlyOnce() {
        XCTAssertEqual(saves(isTeam: true, focused: true, keystrokes: 25, key: "title", commitAtEnd: true), 1)
    }
    func testTeamNotesTypingThenBlurSavesExactlyOnce() {
        XCTAssertEqual(saves(isTeam: true, focused: true, keystrokes: 40, key: "description", commitAtEnd: true), 1)
    }
    func testTeamTypingSchedulesNoDebounceWhileFocused() {
        for key in ["title", "description"] {
            XCTAssertTrue(InspectorTextSave.defersAutosave(isTeamTask: true, textFieldFocused: true, changedKeys: [key]))
        }
        XCTAssertTrue(InspectorTextSave.defersAutosave(isTeamTask: true, textFieldFocused: true, changedKeys: ["title", "description"]))
    }
    func testPersonalTasksKeepTheDebounce() {
        XCTAssertFalse(InspectorTextSave.defersAutosave(isTeamTask: false, textFieldFocused: true, changedKeys: ["title"]))
        XCTAssertFalse(InspectorTextSave.defersAutosave(isTeamTask: false, textFieldFocused: true, changedKeys: ["description"]))
    }
    func testNonTextTeamFieldsStillSaveImmediately() {
        for key in ["priority", "due_date", "assigned_to", "labels", "reminder_specs", "recurrence"] {
            XCTAssertFalse(InspectorTextSave.defersAutosave(isTeamTask: true, textFieldFocused: true, changedKeys: [key]), key)
            XCTAssertFalse(InspectorTextSave.defersAutosave(isTeamTask: true, textFieldFocused: true, changedKeys: ["title", key]), key)
        }
    }
    func testTextWithoutFocusOrChangeIsNotDeferred() {
        // Programmatic text changes (formatting, sync merge) with no focused field follow the normal path.
        XCTAssertFalse(InspectorTextSave.defersAutosave(isTeamTask: true, textFieldFocused: false, changedKeys: ["description"]))
        XCTAssertFalse(InspectorTextSave.defersAutosave(isTeamTask: true, textFieldFocused: true, changedKeys: []))
    }
}
