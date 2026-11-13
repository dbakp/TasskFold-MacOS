import XCTest
@testable import TaskfoldCore

final class ClientHardeningTests: XCTestCase {
    func testPasswordMinimumIsTenCharacters() {
        XCTAssertFalse(ClientHardening.passwordIsAcceptable(""))
        XCTAssertFalse(ClientHardening.passwordIsAcceptable("123456"))
        XCTAssertFalse(ClientHardening.passwordIsAcceptable("123456789"))
        XCTAssertTrue(ClientHardening.passwordIsAcceptable("1234567890"))
        XCTAssertTrue(ClientHardening.passwordIsAcceptable("a much longer passphrase"))
        XCTAssertEqual(ClientHardening.passwordRequirement, "at least 10 characters")
    }

    func testLabelAlwaysKeepsTheRealHost() {
        XCTAssertEqual(ClientHardening.linkLabel(host: "example.com", title: nil, fallback: "example.com › docs"), "example.com › docs")
        XCTAssertEqual(ClientHardening.linkLabel(host: "example.com", title: "   ", fallback: "example.com"), "example.com")
        XCTAssertEqual(ClientHardening.linkLabel(host: "example.com", title: "Quarterly report", fallback: "example.com"), "Quarterly report · example.com")
        XCTAssertEqual(ClientHardening.linkLabel(host: "evil.example", title: "Sign in to bank.com", fallback: "evil.example"), "Sign in to bank.com · evil.example")
        XCTAssertEqual(ClientHardening.linkLabel(host: "example.com", title: "Example.com", fallback: "example.com"), "example.com")
    }

    func testLongTitlesAreTruncatedButHostSurvives() {
        let label = ClientHardening.linkLabel(host: "example.com", title: String(repeating: "x", count: 500), fallback: "example.com")
        XCTAssertTrue(label.hasSuffix(" · example.com"))
        XCTAssertLessThanOrEqual(label.count, 60 + " · example.com".count)
    }

    func testTitlesAreStrippedOfBidiAndControlCharacters() {
        let spoof = "safe\u{202E}moc.elgoog\u{202C}\nline\u{0007}"
        let cleaned = ClientHardening.sanitizedTitle(spoof)
        XCTAssertEqual(cleaned, "safemoc.elgoog line")
        XCTAssertNil(ClientHardening.sanitizedTitle("\u{202E}\u{2066}\n"))
        XCTAssertNil(ClientHardening.sanitizedTitle(nil))
        XCTAssertFalse(ClientHardening.linkLabel(host: "example.com", title: spoof, fallback: "x").unicodeScalars.contains { $0.value == 0x202E })
    }

    func testMissingProjectRecordFailsClosed() {
        XCTAssertTrue(ClientHardening.projectIsShared(projectID: "p1", projectRecordExists: false, inTeamCache: false))
        XCTAssertFalse(ClientHardening.projectIsShared(projectID: "p1", projectRecordExists: true, inTeamCache: false))
        XCTAssertTrue(ClientHardening.projectIsShared(projectID: "p1", projectRecordExists: true, inTeamCache: true))
    }

    func testTaskWithoutProjectIsNotShared() {
        XCTAssertFalse(ClientHardening.projectIsShared(projectID: "", projectRecordExists: false, inTeamCache: false))
        XCTAssertTrue(ClientHardening.mayAutoFetchLinkTitle(taskOwner: "me", currentUser: "me", shared: ClientHardening.projectIsShared(projectID: "", projectRecordExists: false, inTeamCache: false)))
        XCTAssertFalse(ClientHardening.mayAutoFetchLinkTitle(taskOwner: "me", currentUser: "me", shared: ClientHardening.projectIsShared(projectID: "gone", projectRecordExists: false, inTeamCache: false)))
    }

    func testAutoFetchOnlyForOwnTasksInUnsharedProjects() {
        XCTAssertTrue(ClientHardening.mayAutoFetchLinkTitle(taskOwner: "me", currentUser: "me", shared: false))
        XCTAssertFalse(ClientHardening.mayAutoFetchLinkTitle(taskOwner: "me", currentUser: "me", shared: true))
        XCTAssertFalse(ClientHardening.mayAutoFetchLinkTitle(taskOwner: "them", currentUser: "me", shared: false))
        XCTAssertFalse(ClientHardening.mayAutoFetchLinkTitle(taskOwner: "", currentUser: "", shared: false))
        XCTAssertFalse(ClientHardening.mayAutoFetchLinkTitle(taskOwner: "them", currentUser: "me", shared: true))
    }
}
