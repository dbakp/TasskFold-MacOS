import XCTest
@testable import TaskfoldCore

final class TeamProjectFileInventoryTests: XCTestCase {
    private func fixture() throws -> ([String: JSON], TeamProjectAdoptionScope) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-project-file-inventory-v1", withExtension: "json", subdirectory: "Fixtures"))
        let raw = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url)), s = raw["scope"]!.object
        XCTAssertEqual(raw["syntheticOnly"], .bool(true))
        return (raw, try .init(account: s["account"]!.text, origin: s["origin"]!.text, team: s["team_id"]!.text, roots: s["roots"]!.list.map(\.text), visibility: .private))
    }
    func testRealLocalInspectionDistinguishesReferenceKindsAndKeepsProviderDetailsPrivate() throws {
        let (raw, scope) = try fixture(), inspection = try TeamProjectAdoptionInspection(raw["inspection"]!.object, scope: scope)
        let files = try XCTUnwrap(inspection.fileInventory)
        XCTAssertEqual(files.stored, 3); XCTAssertEqual(files.legacy, 1); XCTAssertEqual(files.unavailable, 1); XCTAssertEqual(files.count, 4)
        XCTAssertFalse(inspection.commitSupported)
        let serialized = String(decoding: try JSONEncoder().encode(raw["inspection"]!), as: UTF8.self)
        for privateValue in ["storage_object_id", "Do not reveal", "inventory_hash", "/storage/v1/"] { XCTAssertFalse(serialized.contains(privateValue), privateValue) }
    }
    func testStoredReferenceInventoryDoesNotAuthorizeTransferOrStripItsFileRequirement() throws {
        let (raw, scope) = try fixture(), i = try TeamProjectAdoptionInspection(raw["inspection"]!.object, scope: scope)
        let review = try TeamProjectAdoptionReview(raw["review"]!.object, inspection: i, decisions: [])
        XCTAssertTrue(review.needsFileCustody); XCTAssertFalse(review.canCommit)
        XCTAssertThrowsError(try TeamProjectAdoptionCommand(review: review, now: review.expires.addingTimeInterval(-60)))
        var stripped = raw["review"]!.object; stripped["requires_provider_custody"] = .bool(false)
        XCTAssertThrowsError(try TeamProjectAdoptionReview(stripped, inspection: i, decisions: []))
    }
    func testMalformedFutureAndContradictoryCountsRefuseWithoutNormalizing() throws {
        let base: [String: JSON] = ["protocol": .number(1), "stored": .number(3), "legacy": .number(1), "unavailable": .number(1)]
        for key in base.keys {
            var missing = base; missing.removeValue(forKey: key); XCTAssertThrowsError(try TeamProjectFileInventory(.object(missing)))
        }
        var extra = base; extra["provider_path"] = .string("private"); XCTAssertThrowsError(try TeamProjectFileInventory(.object(extra)))
        var future = base; future["protocol"] = .number(2); XCTAssertThrowsError(try TeamProjectFileInventory(.object(future)))
        for key in ["stored", "legacy", "unavailable"] {
            for value in [JSON.number(-1), .number(0.5), .number(10001), .number(.infinity), .number(.nan), .bool(true), .string("1"), .null] {
                var corrupt = base; corrupt[key] = value; XCTAssertThrowsError(try TeamProjectFileInventory(.object(corrupt)), key)
            }
        }
        var total = base; total["stored"] = .number(10000); XCTAssertThrowsError(try TeamProjectFileInventory(.object(total)))
        var unavailable = base; unavailable["unavailable"] = .number(4); XCTAssertThrowsError(try TeamProjectFileInventory(.object(unavailable)))
    }
    func testInspectionCannotClaimUncountedOrAlreadyApprovedFiles() throws {
        let (raw, scope) = try fixture()
        var inspection = raw["inspection"]!.object, contents = inspection["contents"]!.object
        contents["provider_files"] = .number(0); inspection["contents"] = .object(contents)
        XCTAssertThrowsError(try TeamProjectAdoptionInspection(inspection, scope: scope))
        inspection = raw["inspection"]!.object; inspection["commit_supported"] = .bool(true)
        XCTAssertThrowsError(try TeamProjectAdoptionInspection(inspection, scope: scope))
    }
    func testColdRoundTripPreservesExactInventoryAndOlderServerPayloadsStayReadable() throws {
        let (raw, scope) = try fixture(), original = raw["inspection"]!.object
        let copied = try JSONDecoder().decode([String: JSON].self, from: JSONEncoder().encode(original))
        let inspection = try TeamProjectAdoptionInspection(copied, scope: scope)
        XCTAssertEqual(inspection.contents, original["contents"]!.object)
        XCTAssertEqual(inspection, try TeamProjectAdoptionInspection(original, scope: scope))
        var older = original, contents = older["contents"]!.object; contents.removeValue(forKey: "file_custody"); older["contents"] = .object(contents)
        let legacy = try TeamProjectAdoptionInspection(older, scope: scope)
        XCTAssertNil(legacy.fileInventory); XCTAssertFalse(legacy.commitSupported)
        XCTAssertEqual(original["contents"]!.object["file_custody"], .object(["protocol": .number(1), "stored": .number(3), "legacy": .number(1), "unavailable": .number(1)]))
    }
}
