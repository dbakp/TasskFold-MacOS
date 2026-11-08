import XCTest
@testable import TaskfoldCore

final class ChildTaskNewerVersionTests: XCTestCase {
    private let origin = "https://newer-version.example.invalid"
    private func fixture() throws -> [String: JSON] {
        try TaskfoldJSONDecoder().decode([String: JSON].self, from: Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "child-newer-version-contract-v1", withExtension: "json", subdirectory: "Fixtures"))))
    }
    private func command(_ body: [String: JSON]) throws -> ChildTaskRestoreCommand { try .init(account: body["account"]!.text, origin: origin, body: body) }
    private func scope(_ command: ChildTaskRestoreCommand) -> ChildTaskFieldClientScope { .init(account: command.account, origin: origin, workspace: UUID(), session: UUID(), access: UUID()) }
    private func wire(_ raw: [String: JSON]) throws -> Data { try TaskfoldJSONEncoder().encode(raw) }
    func testActualNewerReviewNamesExactSourceAndKeepsItsOwnCycleIdentity() throws {
        let f = try fixture(), saved = try command(f["command"]!.object), scope = scope(saved)
        let review = try ChildTaskRestoreReview(data: Data(f["newerReviewWire"]!.text.utf8), scope: scope, snapshot: UUID(), identity: saved.identity, mode: .restoreNewer)
        XCTAssertTrue(review.hasNewerVersion); XCTAssertTrue(review.enabled); XCTAssertEqual(review.mode, .restoreNewer)
        XCTAssertTrue(review.mode.startsCycle); XCTAssertTrue(ChildTaskRestoreMode.restore.startsCycle)
        let c = try ChildTaskRestoreCommand(review: review, requestID: UUID(uuidString: saved.id)!)
        XCTAssertEqual(c, saved); XCTAssertTrue(try c.result(f["reply"]!.object).applied)
        XCTAssertTrue(String(decoding: review.target.source, as: UTF8.self).contains("9007199254740993"))
        XCTAssertFalse(ChildTaskRepairPreview.sameJSONValue(review.current.source, review.target.source))
        var older = saved.body; older["mode"] = .string("restore")
        XCTAssertThrowsError(try command(older).review(review))
    }
    func testNewerChoiceCannotBorrowAReversalOrUnreviewedSource() throws {
        let f = try fixture(), c = try command(f["command"]!.object)
        var forged = c.body; forged["restore_id"] = .string(c.id); forged["revision"] = .number(1)
        XCTAssertThrowsError(try command(forged))
        forged = c.body; forged["target_source"] = .array([])
        XCTAssertThrowsError(try command(forged))
        var wrongReply = f["reply"]!.object; wrongReply["mode"] = .string("restore")
        XCTAssertThrowsError(try c.result(wrongReply))
        wrongReply = f["reply"]!.object; wrongReply["restoration_id"] = .string(UUID().uuidString.lowercased())
        XCTAssertThrowsError(try c.result(wrongReply))
    }
    func testNewerReviewRequiresExplicitTypedAvailabilityAndExactMode() throws {
        let f = try fixture(), c = try command(f["command"]!.object), scope = scope(c)
        for value in [JSON.null, .bool(false), .string("true"), .number(1)] {
            var raw = f["newerReview"]!.object; raw["has_newer_version"] = value
            XCTAssertThrowsError(try ChildTaskRestoreReview(data: wire(raw), scope: scope, snapshot: UUID(), identity: c.identity, mode: .restoreNewer))
        }
        var raw = f["newerReview"]!.object; raw.removeValue(forKey: "has_newer_version")
        XCTAssertThrowsError(try ChildTaskRestoreReview(data: wire(raw), scope: scope, snapshot: UUID(), identity: c.identity, mode: .restoreNewer))
        XCTAssertThrowsError(try ChildTaskRestoreReview(data: Data(f["newerReviewWire"]!.text.utf8), scope: scope, snapshot: UUID(), identity: c.identity, mode: .restore))
        var legacy = f["olderReview"]!.object; legacy.removeValue(forKey: "has_newer_version")
        let older = try ChildTaskRestoreReview(data: wire(legacy), scope: scope, snapshot: UUID(), identity: c.identity, mode: .restore)
        XCTAssertFalse(older.hasNewerVersion)
    }
    func testActualUndoRedoFinishStayInNewerFamilyAcrossColdState() throws {
        let f = try fixture(), c = try command(f["command"]!.object)
        var entries: [ChildTaskRestoreState.Entry] = [.init(command: c, phase: .applied, result: try c.result(f["reply"]!.object))]
        guard case .array(let cycle)? = f["cycle"] else { return XCTFail("Missing genuine cycle") }
        for value in cycle {
            let raw = value.object, next = try command(raw["command"]!.object), result = try next.result(raw["reply"]!.object)
            XCTAssertEqual(next.body["restore_id"], .string(c.id)); XCTAssertFalse(next.mode.startsCycle)
            entries.append(.init(command: next, phase: .applied, result: result))
        }
        let state = try ChildTaskRestoreState(account: c.account, origin: origin, entries: entries)
        let recovered = try ChildTaskRestoreState(data: wire(["version": .number(1), "account": .string(c.account), "origin": .string(origin), "entries": TaskfoldJSONDecoder().decode(JSON.self, from: TaskfoldJSONEncoder().encode(entries))]))
        XCTAssertEqual(state.entries, recovered.entries)
        XCTAssertEqual(ChildTaskRestoreState.visibleEntries(recovered.entries).map(\.command.mode), [.finish])
        XCTAssertTrue(ChildTaskRestoreState.unconfirmedRoots(recovered.entries).isEmpty)
    }
    func testSavedChoiceContainsOnlyBoundMetadataNeverArchivedTree() throws {
        let f = try fixture(), c = try command(f["command"]!.object), data = try TaskfoldJSONEncoder().encode(c)
        XCTAssertLessThan(data.count, 4096)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("restore_newer")); XCTAssertFalse(text.contains("target_source")); XCTAssertFalse(text.contains("9007199254740993"))
        XCTAssertEqual(try ChildTaskRestoreCommand(data: data), c)
        let queued = try ChildTaskRestoreState(account: c.account, origin: c.origin, entries: [.init(command: c, phase: .attempted)])
        XCTAssertEqual(ChildTaskRestoreState.unconfirmedRoots(queued.entries), [c.rootID])
    }
}
