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
    private func read(revision: Double? = nil, context: ChildTaskRecordContext? = nil) throws -> ChildTaskStructureRead {
        let f = try fixture(); var raw = f["fixtureRead"]!.object
        if let revision { raw["structure_revision"] = .number(revision) }
        let binding = try context ?? ChildTaskRecordContext(account: f["fixtureCommand"]!.object["account"]!.text, origin: origin, workspace: UUID(), session: UUID(), access: UUID(), snapshot: UUID(), root: Record(f["fixtureRoot"]!.object))
        return try .init(data: bytes(raw), context: binding)
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
    func testReviewedCommandKeepsChosenOrderAfterEditsAndExclusions() throws {
        var steps = ["Inspect", "Review", "Publish"].map { TaskBreakdownReview.Step(title: $0) }
        steps[1].included = false; let last = steps[2].id
        TaskBreakdownReview.move(last, by: -1, in: &steps); TaskBreakdownReview.move(last, by: -1, in: &steps)
        steps[0].title = "Publish #work tomorrow p1"
        let current = try read(), c = try ReviewedTaskStepsCommand(titles: steps.filter(\.included).map(\.title), parent: nil, read: current)
        XCTAssertEqual(c.body["steps"]!.list.map { $0.object["title"]!.text }, ["Publish #work tomorrow p1", "Inspect"])
        try c.review(current)
        let decoded = try ReviewedTaskStepsCommand(account: c.account, origin: c.origin, body: c.body)
        XCTAssertEqual(decoded, c)
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
        XCTAssertNoThrow(try ReviewedTaskStepsCommand(undo: c, receipt: r, read: read(revision: 3)))
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
    @MainActor func testStoppingSavedUndoKeepsTheAdditionAndExplainsTheStoppedRemoval() async throws {
        let original = try command(), applied = try result(original), undo = try undoFixture().0
        let read = try read(), scope = ChildTaskFieldClientScope(read.context)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-step-stop-undo-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), lease = CalendarReadLease()
        let io = ReviewedTeamCommandFileIO<ReviewedTaskStepsState>(directory: root.appendingPathComponent("vault"), account: original.account, origin: origin, encryptionKey: { key })
        let journal = try ReviewedTaskStepsJournal(account: original.account, origin: origin, io: io, coordinationDirectory: root.appendingPathComponent("locks"), removalDirectory: root)
        _ = try await journal.enqueue(original, lease: lease)
        _ = try await journal.attempt(original, lease: lease, resolving: false)
        try await journal.settle(original, result: applied, lease: lease)
        _ = try await journal.enqueue(undo, lease: lease)
        let service = Stub(availability: try .init(data: bytes(fixture()["fixtureAvailability"]!.object), read: read), result: try result(undo, outcome: "closed"))
        let model = ReviewedTaskStepsModel(scope: scope, journal: journal, service: service, current: { scope }, canSend: { _ in false }, isCurrent: { _ in true }, refresh: {})
        await model.load()
        let stopped = await model.run(undo, operation: .close)
        XCTAssertTrue(stopped); XCTAssertEqual(service.operations, [.close])
        XCTAssertEqual(model.entries.map(\.phase), [.applied, .closed])
        XCTAssertEqual(model.message, "Undo stopped. This request can’t remove steps later.")
        let cold = try await journal.load()
        XCTAssertEqual(cold.entries.first?.result, applied)
        XCTAssertEqual(cold.entries.last?.phase, .closed)
    }
    private func undoFixture() throws -> (ReviewedTaskStepsCommand, ReviewedTaskStepsResult) {
        let f = try fixture(), b = f["fixtureUndoCommand"]!.object
        let c = try ReviewedTaskStepsCommand(account: b["account"]!.text, origin: origin, body: b)
        return (c, try result(c))
    }
    private func proof(_ c: ReviewedTaskStepsCommand, original: ReviewedTaskStepsResult? = nil) throws -> ReviewedTaskStepsResult {
        var r = try fixture()["fixtureReceipt"]!.object
        r["request_id"] = .string(c.id); r["action"] = c.body["action"]; r["undo_of"] = c.body["undo_of"] ?? .null
        r["before_revision"] = c.body["structure_revision"]; r["after_revision"] = .number(Double(c.body["structure_revision"]!.integer + 1))
        if c.undoing { r["nodes"] = original!.receipt!["nodes"] }
        else { r["nodes"] = .array(c.body["steps"]!.list.map { .object(["node_key": $0.object["id"]!, "incarnation": .string(UUID().uuidString.lowercased())]) }) }
        return try c.result(["protocol": .number(1), "account": .string(c.account), "request_id": .string(c.id), "outcome": .string("applied"), "receipt": .object(r)])
    }
    func testRedoKeepsReviewedTitlesAndPlacementButUsesFreshIdentities() throws {
        let original = try command(), receipt = try result(original), (undo, reversed) = try undoFixture(), current = try read(revision: Double(reversed.receipt!["after_revision"]!.integer))
        let redo = try ReviewedTaskStepsCommand(redo: original, receipt: receipt, undo: undo, undoReceipt: reversed, read: current)
        XCTAssertNotEqual(redo.id, original.id); XCTAssertNotEqual(redo.id, undo.id)
        XCTAssertEqual(redo.body["steps"]!.list.map { $0.object["title"]! }, original.body["steps"]!.list.map { $0.object["title"]! })
        XCTAssertNotEqual(redo.body["steps"], original.body["steps"])
        for field in ["source_title", "index", "parent_key", "parent_incarnation"] { XCTAssertEqual(redo.body[field], original.body[field]) }
        for field in ["source_title", "index", "steps"] {
            var b = redo.body
            if field == "source_title" { b[field] = .string("A different goal") }
            else if field == "index" { b[field] = .number(0) }
            else { b[field] = original.body["steps"] }
            let changed = try ReviewedTaskStepsCommand(account: redo.account, origin: redo.origin, body: b)
            XCTAssertThrowsError(try changed.validateRedo(original: original, receipt: receipt, undo: undo, undoReceipt: reversed), field)
        }
        XCTAssertNoThrow(try ReviewedTaskStepsCommand(redo: original, receipt: receipt, undo: undo, undoReceipt: reversed, read: read(revision: current.structureRevision + 1)))
    }
    func testHistoricalRedoRestoresOriginalSlotAheadOfUnrelatedLaterWork() throws {
        let f = try fixture(), original = try command(), receipt = try result(original), (undo, reversed) = try undoFixture()
        var raw = f["fixtureRead"]!.object, root = Record(f["fixtureRoot"]!.object), later = raw["records"]!.list[0].object
        later["node_key"] = .string("later"); later["incarnation"] = .string(UUID().uuidString.lowercased()); later["sibling_order"] = .number(1); later["identity_path"] = .array([.string("later")])
        var fields = later["fields"]!.object; fields["id"] = .string("later"); fields["title"] = .string("Unrelated later work"); later["fields"] = .object(fields)
        raw["records"] = .array(raw["records"]!.list + [.object(later)]); raw["structure_revision"] = .number(Double(reversed.receipt!["after_revision"]!.integer + 2)); fields["subtasks"] = .null; root["subtasks"] = .array(root["subtasks"].list + [.object(fields)])
        let scope = try ChildTaskRecordContext(account: original.account, origin: origin, workspace: UUID(), session: UUID(), access: UUID(), snapshot: UUID(), root: root)
        let current = try ChildTaskStructureRead(data: bytes(raw), context: scope)
        let redo = try ReviewedTaskStepsCommand(redo: original, receipt: receipt, undo: undo, undoReceipt: reversed, read: current)
        XCTAssertEqual(redo.body["index"], .number(1)); XCTAssertEqual(current.records.nodes["later"]?.fields["title"], .string("Unrelated later work"))
    }
    func testRedoJournalVersionLineageAndFullFamilyForget() async throws {
        let original = try command(), receipt = try result(original), (undo, reversed) = try undoFixture(), current = try read(revision: Double(reversed.receipt!["after_revision"]!.integer))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-step-redo-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), io = ReviewedTeamCommandFileIO<ReviewedTaskStepsState>(directory: root.appendingPathComponent("vault"), account: original.account, origin: origin, encryptionKey: { key })
        func journal() throws -> ReviewedTaskStepsJournal { try .init(account: original.account, origin: origin, io: io, coordinationDirectory: root.appendingPathComponent("locks"), removalDirectory: root) }
        let a = try journal(), b = try journal(), lease = CalendarReadLease()
        for (c, r) in [(original, receipt), (undo, reversed)] { _ = try await a.enqueue(c, lease: lease); _ = try await a.attempt(c, lease: lease, resolving: false); try await a.settle(c, result: r, lease: lease) }
        let redo = try ReviewedTaskStepsCommand(redo: original, receipt: receipt, undo: undo, undoReceipt: reversed, read: current)
        let competitor = try ReviewedTaskStepsCommand(redo: original, receipt: receipt, undo: undo, undoReceipt: reversed, read: current)
        let saved = try await a.enqueue(redo, lease: lease, redoOf: undo.id), recovered = try await b.enqueue(competitor, lease: lease, redoOf: undo.id)
        XCTAssertEqual(saved, recovered)
        let state = try await b.load(), data = try TaskfoldJSONEncoder().encode(state)
        XCTAssertEqual(try ReviewedTaskStepsState(data: data), state); XCTAssertEqual(Set(try ReviewedTaskStepsState.families(state.entries).values), [original.id])
        var raw = try TaskfoldJSONDecoder().decode([String: JSON].self, from: data); XCTAssertEqual(raw["version"], .number(2)); raw["version"] = .number(1)
        XCTAssertThrowsError(try ReviewedTaskStepsState(data: bytes(raw)))
        var missing = state.entries; missing.remove(at: 1); XCTAssertThrowsError(try ReviewedTaskStepsState(account: original.account, origin: origin, entries: missing))
        do { try await a.forget(original, lease: lease); XCTFail("Keep a pending Redo") } catch {}
        _ = try await b.attempt(saved, lease: lease, resolving: false); try await b.settle(saved, result: proof(saved), lease: lease)
        try await a.forget(saved, lease: lease); let empty = try await b.load(); XCTAssertTrue(empty.entries.isEmpty)
    }
    @MainActor func testConfirmedScreenInverseAdvancesNativeHistoryWithoutSendingTwice() async throws {
        let c = try command(), read = try read(), scope = ChildTaskFieldClientScope(read.context)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-step-history-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), io = ReviewedTeamCommandFileIO<ReviewedTaskStepsState>(directory: root.appendingPathComponent("vault"), account: c.account, origin: origin, encryptionKey: { key })
        let journal = try ReviewedTaskStepsJournal(account: c.account, origin: origin, io: io, coordinationDirectory: root.appendingPathComponent("locks"), removalDirectory: root)
        let service = Stub(availability: try .init(data: bytes(fixture()["fixtureAvailability"]!.object), read: read), result: try result(c))
        let manager = UndoManager(); manager.groupsByEvent = false; let history = ConfirmedHistoryBridge(manager: manager)
        var active: ChildTaskFieldClientScope? = scope, confirmations: [String] = []
        let model = ReviewedTaskStepsModel(scope: scope, journal: journal, service: service, current: { active }, canSend: { _ in true }, isCurrent: { _ in true }, refresh: {}, didApply: { entry, _ in
            confirmations.append(entry.command.id)
            let step = ConfirmedHistoryBridge.Step(name: "Add Task Steps", key: entry.command.id, retained: { active == scope })
            if let parent = entry.redoOf ?? entry.command.body["undo_of"]?.text, history.acceptConfirmedInverse(of: parent, next: step) { return }
            history.record(step)
        })
        await model.load(); let queued = await model.queue(c, read: read); XCTAssertNotNil(queued)
        let applied = await model.run(c, operation: .apply); XCTAssertTrue(applied); XCTAssertTrue(history.canUndo); XCTAssertEqual(confirmations, [c.id])
        let repeated = await model.run(c, operation: .resolve); XCTAssertTrue(repeated); XCTAssertEqual(confirmations.count, 1)
        let original = try XCTUnwrap(model.entries.first), nextRead = try self.read(revision: Double(service.result.receipt!["after_revision"]!.integer), context: read.context)
        let pendingUndo = await model.queueInverse(original, read: nextRead); let u = try XCTUnwrap(pendingUndo); service.result = try proof(u, original: original.result)
        let undone = await model.run(u, operation: .apply); XCTAssertTrue(undone); XCTAssertFalse(history.canUndo); XCTAssertTrue(history.canRedo); XCTAssertEqual(confirmations, [c.id, u.id]); XCTAssertEqual(service.operations, [.apply, .apply])
        active = nil; XCTAssertFalse(history.canRedo)
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
