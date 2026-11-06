import XCTest
@testable import TaskfoldCore

final class ProfileNameDraftTests: XCTestCase {
    func testAccountSwitchDiscardsPreviousOwnersDraft() {
        var draft = ProfileNameDraft()
        let generation = UUID()
        draft.refresh(account: "local", generation: generation, name: "Local Workspace")
        draft.text = "Unsubmitted local edit"
        XCTAssertFalse(draft.matches(account: "cloud", generation: generation))
        draft.refresh(account: "cloud", generation: generation, name: "Cloud Name")
        XCTAssertEqual(draft.text, "Cloud Name")
    }
    func testReturningToSameAccountStartsNewDraft() {
        var draft = ProfileNameDraft()
        let before = UUID(), after = UUID()
        draft.refresh(account: "a", generation: before, name: "Before")
        draft.text = "Unsaved"
        XCTAssertFalse(draft.matches(account: "a", generation: after))
        draft.refresh(account: "a", generation: after, name: "After")
        XCTAssertEqual(draft.text, "After")
    }
    func testSyncRefreshesUntouchedNameButPreservesTyping() {
        var draft = ProfileNameDraft()
        let generation = UUID()
        draft.refresh(account: "a", generation: generation, name: "")
        draft.refresh(account: "a", generation: generation, name: "Loaded")
        XCTAssertEqual(draft.text, "Loaded")
        draft.text = "Typing"
        draft.refresh(account: "a", generation: generation, name: "Remote edit")
        XCTAssertEqual(draft.text, "Typing")
        draft.refresh(account: "a", generation: generation, name: "Typing")
        draft.refresh(account: "a", generation: generation, name: "Later remote edit")
        XCTAssertEqual(draft.text, "Later remote edit")
        XCTAssertTrue(draft.matches(account: "a", generation: generation))
    }
}
