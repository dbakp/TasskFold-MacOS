import XCTest
import CryptoKit
@testable import TaskfoldCore

final class ReviewedTaskStepsTests: XCTestCase {
    private let origin = "https://reviewed-steps.test"
    private func fixture() throws -> [String: JSON] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "reviewed-task-steps-proofs", withExtension: "json", subdirectory: "Fixtures"))
        return try TaskfoldJSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
    }
    private func bytes(_ value: [String: JSON]) throws -> Data { try TaskfoldJSONEncoder().encode(value) }
    private func read(revision: Double? = nil) throws -> ChildTaskStructureRead {
        let f = try fixture(); var raw = f["fixtureRead"]!.object
        if let revision { raw["structure_revision"] = .number(revision) }
        let context = try ChildTaskRecordContext(account: f["fixtureCommand"]!.object["account"]!.text, origin: origin, workspace: UUID(), session: UUID(), access: UUID(), snapshot: UUID(), root: Record(f["fixtureRoot"]!.object))
        return try .init(data: bytes(raw), context: context)
    }
    private func command() throws -> ReviewedTaskStepsCommand {
        let b = try fixture()["fixtureCommand"]!.object; return try .init(account: b["account"]!.text, origin: origin, body: b)
    }
    private func result(_ command: ReviewedTaskStepsCommand, outcome: String = "applied") throws -> ReviewedTaskStepsResult {
        let f = try fixture()
        let proof = command.undoing ? f["fixtureUndoReceipt"]! : f["fixtureReceipt"]!
        return try command.result(["protocol": .number(1), "account": .string(command.account), "request_id": .string(command.id), "outcome": .string(outcome), "receipt": outcome == "applied" ? proof : .null])
    }
    func testGenuineReceiptAndReadBindLiteralBatch() throws {
        let read = try read(), c = try command(), r = try result(c)
        XCTAssertTrue(r.applied); XCTAssertEqual(r.receipt?["count"], .number(2)); try c.review(read)
        let made = try ReviewedTaskStepsCommand(titles: ["Tomorrow #work @Pat", "Review draft"], parent: nil, read: read)
        XCTAssertEqual(made.body["steps"]!.list[0].object["title"], .string("Tomorrow #work @Pat"))
        XCTAssertEqual(made.body["index"], .number(1)); XCTAssertNotEqual(made.id, c.id)
        XCTAssertEqual(Set(made.body["steps"]!.list[0].object.keys), ["id", "title"])
        XCTAssertFalse(String(describing: made).contains("Tomorrow"))
    }
    func testNestedDestinationBindsVersionAndTitle() throws {
        let read = try read(), node = try XCTUnwrap(read.records.nodes["existing"])
        let c = try ReviewedTaskStepsCommand(titles: ["Nested work"], parent: node.key, read: read)
        XCTAssertEqual(c.body["parent_incarnation"], .string(node.incarnation)); XCTAssertEqual(c.body["parent_revision"], .number(node.revision)); XCTAssertEqual(c.body["source_title"], node.fields["title"])
        XCTAssertThrowsError(try ReviewedTaskStepsCommand(titles: ["Step"], parent: "missing", read: read))
        var body = c.body; body["source_title"] = .string("Changed")
        XCTAssertThrowsError(try ReviewedTaskStepsCommand(account: c.account, origin: c.origin, body: body).review(read))
    }
    func testMalformedRequestsAndMetadataCannotEnterBatch() throws {
        let c = try command()
        for key in ["action", "account", "task_id", "request_id", "parent_key", "parent_revision", "source_title", "structure_revision", "index", "steps"] {
            var b = c.body; b[key] = .bool(true)
            XCTAssertThrowsError(try ReviewedTaskStepsCommand(account: c.account, origin: c.origin, body: b), key)
        }
        for titles in [[""], [String(repeating: "e\u{301}", count: 151)], ["A", "a"], ["a\nb"], ["a\u{2028}b"], Array(repeating: "Step", count: 13)] { XCTAssertThrowsError(try ReviewedTaskStepsCommand(titles: titles, parent: nil, read: read())) }
        var b = c.body, rows = b["steps"]!.list, item = rows[0].object; item["assigned_to"] = .string(UUID().uuidString); rows[0] = .object(item); b["steps"] = .array(rows)
        XCTAssertThrowsError(try ReviewedTaskStepsCommand(account: c.account, origin: c.origin, body: b))
        b = c.body; b["unexpected"] = .bool(true); XCTAssertThrowsError(try ReviewedTaskStepsCommand(account: c.account, origin: c.origin, body: b))
    }
    func testReceiptRejectsWrongCountIdentityOrderAndScope() throws {
        let c = try command(), r = try result(c)
        for key in ["count", "nodes", "before_revision", "after_revision", "request_id", "account", "task_generation", "project_id", "action", "undo_of", "replayed"] {
            var proof = r.receipt!; proof[key] = .string("wrong"); var raw = r.raw; raw["receipt"] = .object(proof)
            XCTAssertThrowsError(try c.result(raw), key)
        }
        var proof = r.receipt!; proof["nodes"] = .array(Array(proof["nodes"]!.list.reversed())); var raw = r.raw; raw["receipt"] = .object(proof); XCTAssertThrowsError(try c.result(raw))
        proof = r.receipt!; proof["title"] = .string("Unexpected private text"); raw = r.raw; raw["receipt"] = .object(proof); XCTAssertThrowsError(try c.result(raw))
    }
    func testWireRejectsDuplicateFieldsAndLossyCounters() throws {
        let c = try command(), proof = try bytes(result(c).receipt!)
        XCTAssertTrue(try ReviewedTaskStepsResult(data: proof, command: c, applying: true).applied)
        let raw = String(decoding: proof, as: UTF8.self)
        let duplicate = Data(("{\"protocol\":1," + raw.dropFirst()).utf8)
        XCTAssertThrowsError(try ReviewedTaskStepsResult(data: duplicate, command: c, applying: true))
        let lossy = raw.replacingOccurrences(of: "\"before_revision\":1", with: "\"before_revision\":1.00000000000000000001")
        XCTAssertNotEqual(lossy, raw); XCTAssertThrowsError(try ReviewedTaskStepsResult(data: Data(lossy.utf8), command: c, applying: true))
    }
    func testAvailabilityIsExactAndCannotAuthorizeNewerRead() throws {
        let f = try fixture(), current = try read()
        XCTAssertTrue(try ReviewedTaskStepsAvailability(data: bytes(f["fixtureAvailability"]!.object), read: current).enabled)
        XCTAssertFalse(try ReviewedTaskStepsAvailability(data: bytes(f["fixturePausedAvailability"]!.object), read: current).enabled)
        XCTAssertThrowsError(try ReviewedTaskStepsAvailability(data: bytes(f["fixtureAvailability"]!.object), read: read(revision: 2)))
    }
    func testOneUndoUsesOriginalScopeAndAllNodeProofs() throws {
        let c = try command(), r = try result(c), current = try read(revision: Double(r.receipt!["after_revision"]!.integer))
        let undo = try ReviewedTaskStepsCommand(undo: c, receipt: r, read: current)
        XCTAssertEqual(undo.body["undo_of"], .string(c.id)); XCTAssertNil(undo.body["steps"])
        XCTAssertThrowsError(try ReviewedTaskStepsCommand(undo: c, receipt: r, read: read(revision: 3)))
        let entry = ReviewedTaskStepsState.Entry(command: c, phase: .applied, result: r)
        var rawProof = try fixture()["fixtureUndoReceipt"]!.object; rawProof["request_id"] = undo.body["request_id"]
        let value = try undo.result(["protocol": .number(1), "account": .string(c.account), "request_id": .string(undo.id), "outcome": .string("applied"), "receipt": .object(rawProof)])
        let state = try ReviewedTaskStepsState(account: c.account, origin: c.origin, entries: [entry, .init(command: undo, phase: .applied, result: value)])
        XCTAssertEqual(try ReviewedTaskStepsState(data: TaskfoldJSONEncoder().encode(state)), state)
        XCTAssertThrowsError(try ReviewedTaskStepsState(account: c.account, origin: c.origin, entries: [.init(command: undo)]))
    }
    func testEncryptedColdJournalRetainsExactRequestAndRefusesCompetingIdentity() async throws {
        let c = try command(), root = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-reviewed-steps-" + UUID().uuidString), key = SymmetricKey(size: .bits256)
        defer { try? FileManager.default.removeItem(at: root) }
        let io = ReviewedTeamCommandFileIO<ReviewedTaskStepsState>(directory: root.appendingPathComponent("vault"), account: c.account, origin: origin, encryptionKey: { key })
        func journal() throws -> ReviewedTaskStepsJournal { try .init(account: c.account, origin: origin, io: io, coordinationDirectory: root.appendingPathComponent("locks"), removalDirectory: root) }
        let a = try journal(), lease = CalendarReadLease(); _ = try await a.enqueue(c, lease: lease); _ = try await a.attempt(c, lease: lease, resolving: false)
        let cold = try journal(), saved = try await cold.load(); XCTAssertEqual(saved.entries.first?.command, c); XCTAssertEqual(saved.entries.first?.phase, .attempted)
        XCTAssertFalse(String(decoding: try Data(contentsOf: io.file), as: UTF8.self).contains("Inspect the brief"))
        let other = try ReviewedTaskStepsCommand(titles: ["Another addition"], parent: nil, read: read())
        do { _ = try await cold.enqueue(other, lease: lease); XCTFail("Competing pending root") } catch {}
        do { try await cold.forget(c, lease: lease); XCTFail("Cannot forget uncertainty") } catch {}
        try await cold.settle(c, result: result(c, outcome: "closed"), lease: lease)
        let recovered = try await a.load(); XCTAssertEqual(recovered.entries.first?.phase, .closed)
        do { try await a.settle(c, result: result(c), lease: lease); XCTFail("Terminal result cannot change") } catch {}
        try await a.forget(c, lease: lease); let empty = try await cold.load(); XCTAssertTrue(empty.entries.isEmpty)
    }
    @MainActor func testLostReplyColdRetryAndReadOnlyCheckKeepOneIdentity() async throws {
        let c = try command(), read = try read(), scope = ChildTaskFieldClientScope(read.context)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-step-model-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), io = ReviewedTeamCommandFileIO<ReviewedTaskStepsState>(directory: root.appendingPathComponent("vault"), account: c.account, origin: origin, encryptionKey: { key })
        let journal = try ReviewedTaskStepsJournal(account: c.account, origin: origin, io: io, coordinationDirectory: root.appendingPathComponent("locks"), removalDirectory: root)
        let service = Stub(availability: try .init(data: bytes(fixture()["fixtureAvailability"]!.object), read: read), result: try result(c))
        var active: ChildTaskFieldClientScope? = scope
        func model() -> ReviewedTaskStepsModel { .init(scope: scope, journal: journal, service: service, current: { active }, canSend: { _ in true }, isCurrent: { _ in true }, refresh: {}) }
        let first = model(); await first.load(); let queued = await first.queue(c, read: read); XCTAssertNotNil(queued)
        service.loseReply = true; let sent = await first.run(c, operation: .apply); XCTAssertFalse(sent); first.close()
        let cold = model(); await cold.load(); XCTAssertEqual(cold.entries.first?.phase, .attempted)
        service.loseReply = false; let checked = await cold.run(c, operation: .resolve); XCTAssertTrue(checked); XCTAssertEqual(service.operations, [.apply, .resolve]); XCTAssertEqual(service.ids, [c.id, c.id]); XCTAssertEqual(cold.entries.first?.phase, .applied)
        active = nil; await cold.load(); XCTAssertFalse(cold.loaded); XCTAssertTrue(cold.entries.isEmpty)
    }
    func testCompetingWindowsRecoverOneUndoIdentityAndCancelledLeaseCannotWrite() async throws {
        let c = try command(), proof = try result(c), current = try read(revision: Double(proof.receipt!["after_revision"]!.integer))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-step-undo-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), io = ReviewedTeamCommandFileIO<ReviewedTaskStepsState>(directory: root.appendingPathComponent("vault"), account: c.account, origin: origin, encryptionKey: { key })
        func journal() throws -> ReviewedTaskStepsJournal { try .init(account: c.account, origin: origin, io: io, coordinationDirectory: root.appendingPathComponent("locks"), removalDirectory: root) }
        let a = try journal(), b = try journal(), lease = CalendarReadLease()
        _ = try await a.enqueue(c, lease: lease); _ = try await a.attempt(c, lease: lease, resolving: false); try await a.settle(c, result: proof, lease: lease)
        let first = try ReviewedTaskStepsCommand(undo: c, receipt: proof, read: current), second = try ReviewedTaskStepsCommand(undo: c, receipt: proof, read: current)
        let one = try await a.enqueue(first, lease: lease), two = try await b.enqueue(second, lease: lease)
        XCTAssertEqual(one, two); XCTAssertEqual(one.id, first.id)
        let before = try Data(contentsOf: io.file), cancelled = CalendarReadLease(); cancelled.cancel()
        do { _ = try await a.attempt(first, lease: cancelled, resolving: false); XCTFail("Cancelled lease") } catch {}
        XCTAssertEqual(try Data(contentsOf: io.file), before)
    }
    func testPendingStepsFenceOtherChildActionFamilies() async throws {
        let c = try command(), root = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-step-admission-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), directory = root.appendingPathComponent("Reviewed task steps").appendingPathComponent(c.account).appendingPathComponent(CalendarOAuthConfiguration.digest(origin))
        let io = ReviewedTeamCommandFileIO<ReviewedTaskStepsState>(directory: directory, account: c.account, origin: origin, encryptionKey: { key })
        let journal = try ReviewedTaskStepsJournal(account: c.account, origin: origin, io: io, coordinationDirectory: root.appendingPathComponent("locks"), removalDirectory: root)
        _ = try await journal.enqueue(c, lease: CalendarReadLease())
        let admission = ChildTaskActionAdmission(account: c.account, origin: origin, directory: root, encryptionKey: { key })
        XCTAssertThrowsError(try admission.checkOther([c.root])); XCTAssertThrowsError(try admission.checkBatch([c.root])); XCTAssertThrowsError(try admission.checkForMixed([c.root]))
        XCTAssertNoThrow(try admission.checkOther([UUID().uuidString.lowercased()]))
    }
    @MainActor func testAbsentCheckNeverSendsAndStopWorksWhenNewWritesArePaused() async throws {
        let c = try command(), read = try read(), scope = ChildTaskFieldClientScope(read.context)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-step-stop-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), io = ReviewedTeamCommandFileIO<ReviewedTaskStepsState>(directory: root.appendingPathComponent("vault"), account: c.account, origin: origin, encryptionKey: { key })
        let journal = try ReviewedTaskStepsJournal(account: c.account, origin: origin, io: io, coordinationDirectory: root.appendingPathComponent("locks"), removalDirectory: root)
        _ = try await journal.enqueue(c, lease: CalendarReadLease())
        let service = Stub(availability: try .init(data: bytes(fixture()["fixtureAvailability"]!.object), read: read), result: try result(c, outcome: "absent"))
        let model = ReviewedTaskStepsModel(scope: scope, journal: journal, service: service, current: { scope }, canSend: { _ in false }, isCurrent: { _ in true }, refresh: {})
        await model.load(); let checked = await model.run(c, operation: .resolve); XCTAssertTrue(checked); XCTAssertEqual(model.entries.first?.phase, .attempted)
        let refused = await model.run(c, operation: .apply); XCTAssertFalse(refused); XCTAssertEqual(service.operations, [.resolve])
        service.result = try result(c, outcome: "closed"); let stopped = await model.run(c, operation: .close); XCTAssertTrue(stopped); XCTAssertEqual(model.entries.first?.phase, .closed); XCTAssertEqual(service.operations, [.resolve, .close])
    }
    @MainActor private final class Stub: ReviewedTaskStepsService {
        let availability: ReviewedTaskStepsAvailability
        var result: ReviewedTaskStepsResult
        var loseReply = false, operations: [ReviewedTaskStepsOperation] = [], ids: [String] = []
        init(availability: ReviewedTaskStepsAvailability, result: ReviewedTaskStepsResult) { self.availability = availability; self.result = result }
        func reviewedTaskStepsAvailability(_ read: ChildTaskStructureRead) async throws -> ReviewedTaskStepsAvailability { availability }
        func reviewedTaskSteps(_ command: ReviewedTaskStepsCommand, operation: ReviewedTaskStepsOperation, session: UUID) async throws -> ReviewedTaskStepsResult {
            operations.append(operation); ids.append(command.id); if loseReply { throw AppFailure(message: "Lost reply") }; return result
        }
    }
}
