import XCTest
@testable import TaskfoldCore

final class PrivacyFactsTests: XCTestCase {
    private var allText: String {
        ([PrivacyFacts.intro, PrivacyFacts.footer] + PrivacyFacts.items.flatMap { [$0.title, $0.summary] + $0.points }
         + PrivacyFacts.controls.flatMap { [$0.title, $0.detail] }).joined(separator: "\n")
    }

    func testItemsAreUniqueAndComplete() {
        let ids = PrivacyFacts.items.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids, ["ai", "sync", "local", "calendar", "location", "voice", "analytics", "links", "holidays"])
        for item in PrivacyFacts.items {
            XCTAssertFalse(item.title.isEmpty, item.id)
            XCTAssertFalse(item.summary.isEmpty, item.id)
            XCTAssertFalse(item.points.isEmpty, item.id)
            XCTAssertTrue(item.points.allSatisfy { $0.hasSuffix(".") && $0.count < 400 }, item.id)
            XCTAssertTrue(item.summary.hasSuffix("."), item.id)
        }
    }

    func testPlacementMatchesTheClaim() {
        XCTAssertEqual(PrivacyFacts.item("ai")?.location, .onDevice)
        XCTAssertEqual(PrivacyFacts.item("sync")?.location, .syncs)
        XCTAssertEqual(PrivacyFacts.item("local")?.location, .onDevice)
        XCTAssertEqual(PrivacyFacts.item("calendar")?.location, .onDevice)
        XCTAssertEqual(PrivacyFacts.item("analytics")?.location, PrivacyFacts.Location.none)
        XCTAssertEqual(PrivacyFacts.item("links")?.location, .otherServices)
        XCTAssertEqual(PrivacyFacts.item("holidays")?.location, .otherServices)
        XCTAssertEqual(Set(PrivacyFacts.Location.allCases.map(\.label)).count, PrivacyFacts.Location.allCases.count)
        XCTAssertEqual(Set(PrivacyFacts.Location.allCases.map(\.symbol)).count, PrivacyFacts.Location.allCases.count)
    }

    func testAIClaimsNoCloudPath() throws {
        let ai = try XCTUnwrap(PrivacyFacts.item("ai"))
        let text = ([ai.summary] + ai.points).joined(separator: " ")
        XCTAssertTrue(text.contains("on this device"))
        XCTAssertTrue(text.contains("no code path"))
        for feature in ["Brain dump", "Suggest steps", "Smart reschedule", "Suggest a filter"] { XCTAssertTrue(text.contains(feature), feature) }
    }

    func testAnalyticsSaysOnlyWhatTheCodeShows() throws {
        let analytics = try XCTUnwrap(PrivacyFacts.item("analytics"))
        XCTAssertEqual(analytics.summary, "No third-party analytics.")
        XCTAssertTrue(analytics.points.joined().contains("AppAuth"))
    }

    func testSyncNamesCloudAndLocalModeBoundaries() throws {
        let sync = try XCTUnwrap(PrivacyFacts.item("sync")), local = try XCTUnwrap(PrivacyFacts.item("local"))
        XCTAssertTrue(sync.summary.contains("Supabase"))
        XCTAssertTrue(sync.points.joined().contains("only while you are signed in"))
        XCTAssertTrue(local.points.joined().contains("not uploaded"))
        XCTAssertTrue(local.points.joined().contains("not upload your local tasks automatically"))
    }

    func testCalendarLocationVoiceAndLinksStatements() throws {
        XCTAssertTrue(try XCTUnwrap(PrivacyFacts.item("calendar")).points.joined().contains("EventKit"))
        XCTAssertTrue(try XCTUnwrap(PrivacyFacts.item("calendar")).points.joined().contains("read-only"))
        XCTAssertTrue(try XCTUnwrap(PrivacyFacts.item("location")).points.joined().contains("Exception"))
        XCTAssertTrue(try XCTUnwrap(PrivacyFacts.item("voice")).points.joined().contains("on-device speech recognition"))
        let links = try XCTUnwrap(PrivacyFacts.item("links"))
        XCTAssertTrue(links.points.joined().contains("project that isn’t shared"))
        XCTAssertTrue(links.points.joined().contains("not through Taskfold’s server") || links.points.joined().contains("does not go through Taskfold’s server"))
    }

    func testControlsAndIdentifiers() {
        XCTAssertEqual(PrivacyFacts.controls.map(\.id), ["export", "local", "delete"])
        XCTAssertEqual(PrivacyFacts.screenIdentifier, "privacyScreen")
        XCTAssertEqual(PrivacyFacts.badgeIdentifier, "onDeviceBadge")
        XCTAssertTrue(PrivacyFacts.badgeAccessibilityLabel.hasPrefix(PrivacyFacts.badgeLabel))
    }

    func testNoOverclaimingWords() {
        let lowered = allText.lowercased()
        for word in ["end-to-end", "guarantee", "anonymous", "100%", "unhackable", "military", "completely private", "zero data"] {
            XCTAssertFalse(lowered.contains(word), word)
        }
        XCTAssertFalse(allText.contains("Ask Cody"))
    }

    func testAccessibilityLabelLeadsWithPlacement() throws {
        let item = try XCTUnwrap(PrivacyFacts.item("ai"))
        XCTAssertTrue(item.accessibilityLabel.hasPrefix("AI suggestions. On device."))
        XCTAssertTrue(item.accessibilityLabel.contains(item.points[0]))
    }
}
