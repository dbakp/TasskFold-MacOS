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
        XCTAssertTrue(text.contains("on " + PrivacyFacts.deviceNoun))
        // The lead says it once; no bullet repeats it.
        XCTAssertFalse(text.contains("never leaves"))
        XCTAssertFalse(ai.points.contains { $0.contains("without sending") || $0.contains("for AI") })
        XCTAssertTrue(ai.points.contains("Tasks you accept are saved like any other, and sync only if you sign in."))
        XCTAssertEqual(ai.points.count, 2)
        XCTAssertFalse(text.contains("code path"))
        // Round 3 copy: what happens, in plain words, not a list of feature names.
        XCTAssertTrue(ai.summary.hasPrefix("Suggestions use Apple Intelligence on "), ai.summary)
        XCTAssertTrue(ai.summary.contains("without sending your words anywhere"), ai.summary)
        XCTAssertTrue(ai.points.contains("Without Apple Intelligence, simpler rules run instead."))
        XCTAssertFalse(ai.summary.contains("Suggest a filter"), "no feature-name list")
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
        let calendar = try XCTUnwrap(PrivacyFacts.item("calendar"))
        let text = ([calendar.summary] + calendar.points).joined(separator: " ")
        XCTAssertFalse(text.contains("does not change your calendars"))
        for phrase in ["Show time blocks in Calendar", "off until you switch it on", "full calendar access", "calendar named Taskfold", "task title", "Task notes are never copied", "only events it created", "Turning it off"] {
            XCTAssertTrue(text.contains(phrase), phrase)
        }
        XCTAssertTrue(try XCTUnwrap(PrivacyFacts.item("location")).points.joined().contains("Exception"))
        XCTAssertTrue(try XCTUnwrap(PrivacyFacts.item("voice")).points.joined().contains("on-device speech recognition"))
        let links = try XCTUnwrap(PrivacyFacts.item("links"))
        XCTAssertTrue(links.points.joined().contains("project that isn’t shared"))
        XCTAssertTrue(links.points.joined().contains("not through TaskFold’s server") || links.points.joined().contains("does not go through TaskFold’s server"))
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
        XCTAssertFalse(allText.replacingOccurrences(of: "calendar named Taskfold", with: "").contains("Taskfold"), "The product is spelled TaskFold")
        XCTAssertFalse(allText.contains("as the app works today"))
    }

    func testAccessibilityLabelLeadsWithPlacement() throws {
        let item = try XCTUnwrap(PrivacyFacts.item("ai"))
        XCTAssertTrue(item.accessibilityLabel.hasPrefix("AI suggestions. On device."))
        XCTAssertTrue(item.accessibilityLabel.contains(item.points[0]))
    }
}
