import XCTest
@testable import TaskfoldCore

/// Captured from the owning full-schema Auth/REST/Storage integration, not a mocked union.
final class CombinedProjectCustodyTests: XCTestCase {
    private func fixture() throws -> ([String: JSON], TeamProjectAdoptionInspection, ProjectFileConsent) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "combined-project-custody-v1", withExtension: "json", subdirectory: "Fixtures"))
        let raw = try TaskfoldJSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        XCTAssertEqual(raw["syntheticOnly"], .bool(true))
        let request = try ProjectFilePreparationRequest(account: raw["account"]!.text, origin: raw["origin"]!.text, body: raw["request"]!.object, expectedCount: raw["expectedCount"]!.integer)
        let inspection = try TeamProjectAdoptionInspection(raw["inspection"]!.object, scope: request.scope)
        XCTAssertTrue(request.matches(inspection))
        let ready = try ProjectFilePreparationPage(raw["ready"]!.object, request: request)
        return (raw, inspection, try ProjectFileConsent(pages: [ready]))
    }
    private func command() throws -> ([String: JSON], TeamProjectAdoptionCommand) {
        let (raw, inspection, files) = try fixture()
        let decisions = try raw["command"]!.object["decisions"]!.list.map { try TeamProjectAdoptionDecision($0.object) }
        let review = try TeamProjectAdoptionReview(raw["review"]!.object, inspection: inspection, decisions: decisions, connectionPolicy: .pause, recordingPolicy: .privateHistory, fileConsent: files)
        XCTAssertTrue(review.canCommit)
        let command = try TeamProjectAdoptionCommand(review: review, requestID: XCTUnwrap(UUID(uuidString: raw["command"]!.object["request_id"]!.text)), now: review.expires.addingTimeInterval(-60))
        XCTAssertEqual(command.body, raw["command"]!.object)
        return (raw, command)
    }
    func testOneReviewBindsFilesRecordingsAndConnectionsThroughColdRecovery() throws {
        let (raw, command) = try command()
        let cold = try TaskfoldJSONDecoder().decode(TeamProjectAdoptionCommand.self, from: TaskfoldJSONEncoder().encode(command))
        XCTAssertEqual(cold, command)
        XCTAssertEqual(cold.connectionPolicy, .pause)
        XCTAssertEqual(cold.recordingPolicy, .privateHistory)
        XCTAssertNotNil(cold.fileConsent)
        XCTAssertEqual(try cold.confirmed(raw["receipt"]!.object).command, command)
        var replay = raw["receipt"]!.object; replay["replayed"] = .bool(true)
        XCTAssertTrue(try cold.confirmed(replay).replayed)
    }
    func testReceiptCannotOmitOrChangeAnyReviewedEffect() throws {
        let (raw, command) = try command()
        for key in ["file_transfer", "recording_policy", "recording_count", "unfinished_recording_count", "retained_recording_count", "connection_policy", "connection_effects"] {
            var receipt = raw["receipt"]!.object; receipt.removeValue(forKey: key)
            XCTAssertThrowsError(try command.confirmed(receipt), key)
        }
        for key in ["recording_count", "unfinished_recording_count", "retained_recording_count"] {
            var receipt = raw["receipt"]!.object; receipt[key] = .number(0)
            XCTAssertThrowsError(try command.confirmed(receipt), key)
        }
        var receipt = raw["receipt"]!.object
        var effects = receipt["connection_effects"]!.object; effects["email_routes_paused"] = .number(0)
        receipt["connection_effects"] = .object(effects)
        XCTAssertThrowsError(try command.confirmed(receipt))
        receipt = raw["receipt"]!.object
        var files = receipt["file_transfer"]!.object; files["byte_count"] = .number(0)
        receipt["file_transfer"] = .object(files)
        XCTAssertThrowsError(try command.confirmed(receipt))
    }
    func testReviewCannotSilentlyDropAnyConsent() throws {
        let (raw, inspection, files) = try fixture()
        let decisions = try raw["command"]!.object["decisions"]!.list.map { try TeamProjectAdoptionDecision($0.object) }
        XCTAssertThrowsError(try TeamProjectAdoptionReview(raw["review"]!.object, inspection: inspection, decisions: decisions, recordingPolicy: .privateHistory, fileConsent: files))
        XCTAssertThrowsError(try TeamProjectAdoptionReview(raw["review"]!.object, inspection: inspection, decisions: decisions, connectionPolicy: .pause, fileConsent: files))
        XCTAssertThrowsError(try TeamProjectAdoptionReview(raw["review"]!.object, inspection: inspection, decisions: decisions, connectionPolicy: .pause, recordingPolicy: .privateHistory))
    }
}
