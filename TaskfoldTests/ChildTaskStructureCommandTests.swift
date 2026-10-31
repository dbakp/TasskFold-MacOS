import XCTest
import CryptoKit
@testable import TaskfoldCore

final class ChildTaskStructureCommandTests: XCTestCase {
    private let origin = "https://child-record.test"
    private func fixture(_ name: String = "child-task-structure-proofs") throws -> [String: JSON] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
    }
    private func bytes(_ raw: [String: JSON]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(raw)
    }
    private func source() throws -> ChildTaskStructureCommand {
        let raw = try fixture()["fixtureCommand"]!.object
        return try .init(account: raw["account"]!.text, origin: origin, body: raw)
    }
    private func read(changing: ((inout Record, inout [String: JSON]) -> Void)? = nil) throws -> ChildTaskStructureRead {
        let f = try fixture(); var root = Record(f["fixtureRoot"]!.object), raw = f["fixtureRead"]!.object
        changing?(&root, &raw)
        let scope = try ChildTaskRecordContext(account: f["fixtureCommand"]!.object["account"]!.text, origin: origin, workspace: UUID(), session: UUID(), access: UUID(), snapshot: UUID(), root: root)
        return try .init(data: bytes(raw), context: scope)
    }
    private func receipt(_ command: ChildTaskStructureCommand) throws -> [String: JSON] {
        var raw = command.body.filter { ChildTaskStructureCommand.scopeKeys.contains($0.key) || ["request_id", "action"].contains($0.key) }
        raw["before_revision"] = command.body["structure_revision"]; raw["after_revision"] = .number(Double(command.body["structure_revision"]!.integer + 1))
        raw["undo_of"] = command.body["undo_of"] ?? .null; raw["replayed"] = .bool(false)
        raw["node_key"] = command.body["node_key"] ?? command.body["node"]?.object["id"] ?? command.original?.receipt["node_key"]
        if command.action == .delete || command.original?.receipt["action"] == .string("insert") { raw["incarnation"] = .null }
        else { raw["incarnation"] = command.body["incarnation"] ?? command.original?.receipt["incarnation"] ?? .string(UUID().uuidString.lowercased()) }
        return raw
    }
    private func historyRead(revision: Double, removing: Set<String> = [], restored: (String, String)? = nil, edited: String? = nil) throws -> ChildTaskStructureRead {
        try read { root, raw in
            raw["structure_revision"] = .number(revision); raw["projection_revision"] = .number(revision)
            var rows = raw["records"]!.list.filter { !removing.contains($0.object["node_key"]!.text) }
            for i in rows.indices {
                var row = rows[i].object
                if let restored, row["identity_path"]!.list.first?.text == restored.0 {
                    row["incarnation"] = .string(row["node_key"]!.text == restored.0 ? restored.1 : UUID().uuidString.lowercased()); row["revision"] = .number(1)
                }
                if row["node_key"]?.text == edited { row["revision"] = .number(Double(row["revision"]!.integer + 1)) }
                rows[i] = .object(row)
            }
            for parent in Set(rows.map { $0.object["parent_key"]!.text }) {
                let indices = rows.indices.filter { rows[$0].object["parent_key"]!.text == parent }.sorted { rows[$0].object["sibling_order"]!.integer < rows[$1].object["sibling_order"]!.integer }
                for (position, index) in indices.enumerated() { var row = rows[index].object; row["sibling_order"] = .number(Double(position)); rows[index] = .object(row) }
            }
            func tree(_ parent: JSON) -> [JSON] {
                rows.filter { $0.object["parent_key"] == parent }.sorted { $0.object["sibling_order"]!.integer < $1.object["sibling_order"]!.integer }.map { node in
                    let row = node.object; var fields = row["fields"]!.object
                    if row["children_kind"] == .string("array") { fields["subtasks"] = .array(tree(row["node_key"]!)) }
                    else if row["children_kind"] == .string("null") { fields["subtasks"] = .null }
                    return .object(fields)
                }
            }
            raw["records"] = .array(rows); root["subtasks"] = .array(tree(.null))
        }
    }
    private func history(_ stem: String) throws -> (ChildTaskStructureCommand, ChildTaskStructureReceipt, ChildTaskStructureCommand, ChildTaskStructureReceipt) {
        let f = try fixture(), body = f["fixture" + stem + "Command"]!.object
        let forward = try ChildTaskStructureCommand(account: body["account"]!.text, origin: origin, body: body), proof = try forward.confirmed(f["fixture" + stem + "Receipt"]!.object)
        var undoBody = body.filter { ChildTaskStructureCommand.scopeKeys.contains($0.key) }
        undoBody["action"] = .string("undo"); undoBody["request_id"] = .string(UUID().uuidString.lowercased()); undoBody["undo_of"] = .string(forward.id); undoBody["structure_revision"] = proof.raw["after_revision"]
        let undo = try ChildTaskStructureCommand(account: forward.account, origin: origin, body: undoBody, original: .init(body: body, receipt: proof.raw))
        var reply = try receipt(undo)
        if stem == "Delete" { reply["incarnation"] = .string(UUID().uuidString.lowercased()) }
        return (forward, proof, undo, try undo.confirmed(reply))
    }
    func testHierarchyRedoInsertUsesFreshIdentityAndExactOriginalNode() throws {
        let (forward, _, undo, proof) = try history("")
        let current = try historyRead(revision: Double(proof.raw["after_revision"]!.integer), removing: ["fresh"])
        let redo = try ChildTaskStructureCommand(redo: undo, receipt: proof, read: current)
        XCTAssertEqual(redo.action, .insert); XCTAssertNotEqual(redo.id, forward.id); XCTAssertNotEqual(redo.id, undo.id)
        XCTAssertEqual(redo.body["node"], forward.body["node"]); XCTAssertNil(redo.body["undo_of"])
        XCTAssertEqual(redo.body["structure_revision"], proof.raw["after_revision"])
        XCTAssertThrowsError(try ChildTaskStructureCommand(redo: undo, receipt: proof, read: historyRead(revision: current.structureRevision + 1, removing: ["fresh"])))
        XCTAssertThrowsError(try ChildTaskStructureCommand(redo: undo, receipt: proof, read: current, requestID: UUID(uuidString: forward.id)!))
    }
    func testHierarchyRedoMoveKeepsAuthoredDestinationAndRejectsAlteredPlacement() throws {
        let (forward, _, undo, proof) = try history("Move"), current = try historyRead(revision: Double(proof.raw["after_revision"]!.integer))
        let redo = try ChildTaskStructureCommand(redo: undo, receipt: proof, read: current)
        XCTAssertEqual(redo.action, .move); XCTAssertEqual(redo.body["parent_key"], forward.body["parent_key"]); XCTAssertEqual(redo.body["index"], forward.body["index"])
        var body = redo.body; body["parent_key"] = .null
        let retargeted = try ChildTaskStructureCommand(account: redo.account, origin: origin, body: body)
        XCTAssertThrowsError(try retargeted.validateRedo(of: undo, receipt: proof))
    }
    func testHierarchyRedoDeleteFencesEveryRestoredNodeAndSupportsArchiveRecovery() throws {
        let (forward, originalProof, undo, proof) = try history("Delete"), key = proof.raw["node_key"]!.text
        let current = try historyRead(revision: Double(proof.raw["after_revision"]!.integer), restored: (key, proof.raw["incarnation"]!.text))
        let redo = try ChildTaskStructureCommand(redo: undo, receipt: proof, read: current)
        XCTAssertEqual(redo.action, .delete); XCTAssertEqual(Set(redo.body["subtree_versions"]!.object.keys), Set(forward.body["subtree_versions"]!.object.keys))
        XCTAssertNotEqual(redo.body["incarnation"], forward.body["incarnation"])
        for edited in [key, "nested"] {
            XCTAssertThrowsError(try ChildTaskStructureCommand(redo: undo, receipt: proof, read: historyRead(revision: current.structureRevision, restored: (key, proof.raw["incarnation"]!.text), edited: edited)))
        }
        var archive = originalProof.raw; archive["replayed"] = .bool(true)
        let recoveredUndo = try ChildTaskStructureCommand(account: undo.account, origin: origin, body: undo.body, original: .init(body: nil, receipt: archive))
        XCTAssertNoThrow(try ChildTaskStructureCommand(redo: recoveredUndo, receipt: proof, read: current))
        var changed = redo.body; changed["node_key"] = .string("nested"); changed["incarnation"] = current.records.nodes["nested"].map { .string($0.incarnation) }
        XCTAssertThrowsError(try ChildTaskStructureCommand(account: redo.account, origin: origin, body: changed).validateRedo(of: undo, receipt: proof))
    }
    func testHierarchyRedoJournalRejectsMissingLineageAndVersionDowngrade() throws {
        let (forward, first, undo, proof) = try history(""), current = try historyRead(revision: Double(proof.raw["after_revision"]!.integer), removing: ["fresh"])
        let redo = try ChildTaskStructureCommand(redo: undo, receipt: proof, read: current)
        let rows: [ChildTaskStructureJournalState.Entry] = [.init(command: forward, phase: .confirmed, receipt: first), .init(command: undo, phase: .confirmed, receipt: proof), .init(command: redo, redoOf: undo.id)]
        let state = try ChildTaskStructureJournalState(account: forward.account, origin: origin, entries: rows)
        let encoded = try TaskfoldJSONEncoder().encode(state); XCTAssertEqual(try ChildTaskStructureJournalState(data: encoded), state)
        XCTAssertEqual(Set(try ChildTaskStructureJournalState.families(rows).values), [forward.id])
        var raw = try JSONDecoder().decode([String: JSON].self, from: encoded); XCTAssertEqual(raw["version"], .number(2)); raw["version"] = .number(1)
        XCTAssertThrowsError(try ChildTaskStructureJournalState(data: JSONEncoder().encode(raw)))
        var missing = rows; missing.remove(at: 1)
        XCTAssertThrowsError(try ChildTaskStructureJournalState(account: forward.account, origin: origin, entries: missing))
    }
    func testHierarchyRedoEncryptedColdRecoveryAndCompetingWindowsKeepOneIdentity() async throws {
        let (forward, proof, _, _) = try history("")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-hierarchy-redo-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let io = try ChildTaskStructureJournalFileIO(directory: root.appendingPathComponent("vault"), account: forward.account, origin: origin, encryptionKey: { key })
        func journal() throws -> ChildTaskStructureJournal { try .init(account: forward.account, origin: origin, io: io, coordinationDirectory: root.appendingPathComponent("locks"), removalDirectory: root.appendingPathComponent("removal")) }
        let a = try journal(), lease = CalendarReadLease()
        try await a.enqueue(forward, lease: lease); _ = try await a.attempt(forward, lease: lease); try await a.confirm(forward, receipt: proof, lease: lease)
        let first = try await a.load(), parent = try XCTUnwrap(first.entries.first)
        let undo = try await a.enqueueInverse(of: parent, read: read(), lease: lease)
        _ = try await a.attempt(undo, lease: lease); let undone = try undo.confirmed(receipt(undo)); try await a.confirm(undo, receipt: undone, lease: lease)
        let b = try journal(), cold = try await b.load(), undoEntry = try XCTUnwrap(cold.entries.last)
        let fresh = try historyRead(revision: Double(undone.raw["after_revision"]!.integer), removing: ["fresh"])
        async let one = a.enqueueInverse(of: undoEntry, read: fresh, lease: lease)
        async let two = b.enqueueInverse(of: undoEntry, read: fresh, lease: lease)
        let (redo, duplicate) = try await (one, two); XCTAssertEqual(redo, duplicate)
        let saved = try await b.load(); XCTAssertEqual(saved.entries.count, 3); XCTAssertEqual(saved.entries.last?.redoOf, undo.id)
        _ = try await b.attempt(redo, lease: lease); let redone = try redo.confirmed(receipt(redo)); try await b.confirm(redo, receipt: redone, lease: lease)
        let latest = try await a.load(), redoEntry = try XCTUnwrap(latest.entries.last)
        let afterRedo = try historyRead(revision: Double(redone.raw["after_revision"]!.integer), restored: ("fresh", redone.raw["incarnation"]!.text))
        let undoAgain = try await a.enqueueInverse(of: redoEntry, read: afterRedo, lease: lease)
        _ = try await a.attempt(undoAgain, lease: lease); try await a.confirm(undoAgain, receipt: undoAgain.confirmed(receipt(undoAgain)), lease: lease)
        let final = try await journal().load(); XCTAssertEqual(final.entries.count, 4); XCTAssertEqual(Set(try ChildTaskStructureJournalState.families(final.entries).values), [forward.id])
        XCTAssertFalse(String(decoding: try Data(contentsOf: io.file), as: UTF8.self).contains("Fresh subtask"))
    }
    func testHierarchyRedoCapacityKeepsNewestLiveDeletionArchive() throws {
        let (forward, first, undo, proof) = try history("Delete"), current = try historyRead(revision: Double(proof.raw["after_revision"]!.integer), restored: (proof.raw["node_key"]!.text, proof.raw["incarnation"]!.text))
        let redo = try ChildTaskStructureCommand(redo: undo, receipt: proof, read: current)
        var rows: [ChildTaskStructureJournalState.Entry] = [.init(command: forward, phase: .confirmed, receipt: first), .init(command: undo, phase: .confirmed, receipt: proof), .init(command: redo, phase: .confirmed, receipt: try redo.confirmed(receipt(redo)), redoOf: undo.id)]
        let template = try source()
        for _ in 0..<61 {
            var body = template.body; body["request_id"] = .string(UUID().uuidString.lowercased()); let c = try ChildTaskStructureCommand(account: template.account, origin: origin, body: body)
            rows.append(.init(command: c, phase: .confirmed, receipt: try c.confirmed(receipt(c))))
        }
        var state = try ChildTaskStructureJournalState(account: forward.account, origin: origin, entries: rows)
        // One further settled family forces capacity pruning. A prior Undo must
        // never make the latest Redo deletion look safe to forget.
        var body = template.body; body["request_id"] = .string(UUID().uuidString.lowercased()); let c = try ChildTaskStructureCommand(account: template.account, origin: origin, body: body)
        state.entries.append(.init(command: c, phase: .confirmed, receipt: try c.confirmed(receipt(c))))
        try state.makeRoom()
        XCTAssertTrue([forward.id, undo.id, redo.id].allSatisfy { id in state.entries.contains { $0.command.id == id } }); XCTAssertEqual(state.entries.count, 64)
    }

    func testActualInsertReceiptAndCertifiedUndoBindExactly() throws {
        let command = try source(), f = try fixture(), proof = try command.confirmed(f["fixtureReceipt"]!.object)
        XCTAssertEqual(proof.raw["after_revision"], .number(2))
        let undo = try ChildTaskStructureCommand(undo: command, receipt: proof, read: read())
        XCTAssertEqual(undo.body["undo_of"], .string(command.id)); XCTAssertEqual(undo.body["structure_revision"], .number(2))
        XCTAssertNoThrow(try undo.confirmed(receipt(undo)))
        XCTAssertThrowsError(try ChildTaskStructureCommand(undo: undo, receipt: undo.confirmed(receipt(undo)), read: read()))
    }
    func testActualRestoreMetadataValidatesButCannotAuthorizeUnattachedUndo() throws {
        let f = try fixture(), body = f["fixtureRestoreCommand"]!.object
        XCTAssertNoThrow(try ChildTaskStructureReceipt(account: body["account"]!.text, raw: f["fixtureRestoreReceipt"]!.object))
        XCTAssertThrowsError(try ChildTaskStructureCommand(account: body["account"]!.text, origin: origin, body: body))
    }
    func testInsertPreservesRawIdentityAndContainerShapes() throws {
        let node: JSON = .object(["id": .string("Cafe\u{301}"), "title": .string("New workflow"), "subtasks": .array([
            .object(["id": .string("one"), "title": .string("First")]),
            .object(["id": .string("two"), "title": .string("Second"), "subtasks": .null]),
            .object(["id": .string("three"), "title": .string("Third"), "subtasks": .array([])])])])
        let command = try ChildTaskStructureCommand(insert: node, parent: "b", index: 0, read: read())
        XCTAssertTrue(AuthoredValueComparison.exactJSON(command.body["node"]!, node))
        var proof = try receipt(command); proof["node_key"] = .string("Café")
        XCTAssertNoThrow(try command.confirmed(proof))
    }
    func testNewNodesRefuseHistoryFilesOpaqueFieldsOrForgedCompletion() throws {
        for (key, value) in [("comments", JSON.array([])), ("attachments", .array([])), ("future", .bool(true)), ("taskfold_completion_v1", .object([:])), ("completed", .bool(true)), ("completed_at", .string("2026-10-01T00:00:00Z")), ("is_heading", .string("true"))] {
            XCTAssertThrowsError(try ChildTaskStructureCommand(insert: .object(["id": .string("new"), "title": .string("New"), key: value]), parent: nil, index: 0, read: read()), key)
        }
    }
    func testNewNodesRejectDuplicateNormalizedIDsInvalidFieldsAndUnsupportedContainers() throws {
        let invalid: [JSON] = [
            .object(["id": .string(""), "title": .string("New")]), .object(["id": .string("x"), "title": .string(" ")]),
            .object(["id": .string("x"), "title": .string("New"), "priority": .number(5)]),
            .object(["id": .string("x"), "title": .string("New"), "subtasks": .object([:])]),
            .object(["id": .string("Café"), "title": .string("New"), "subtasks": .array([.object(["id": .string("Cafe\u{301}"), "title": .string("Duplicate")])])])]
        for node in invalid { XCTAssertThrowsError(try ChildTaskStructureCommand(insert: node, parent: nil, index: 0, read: read())) }
    }
    func testNewTreeDepthCountAndRequestBounds() throws {
        var node: JSON = .object(["id": .string("deepest"), "title": .string("Leaf")])
        for depth in 1...24 { node = .object(["id": .string("depth-\(depth)"), "title": .string("Parent"), "subtasks": .array([node])]) }
        XCTAssertThrowsError(try ChildTaskStructureCommand(insert: node, parent: nil, index: 0, read: read()))
        let many: JSON = .object(["id": .string("many"), "title": .string("Many"), "subtasks": .array((0..<1000).map { .object(["id": .string("leaf-\($0)"), "title": .string("Leaf")]) })])
        XCTAssertThrowsError(try ChildTaskStructureCommand(insert: many, parent: nil, index: 0, read: read()))
        let large: JSON = .object(["id": .string("large"), "title": .string("Large"), "description": .string(String(repeating: "😀", count: 100_000))])
        XCTAssertThrowsError(try ChildTaskStructureCommand(insert: large, parent: nil, index: 0, read: read()))
    }
    func testInsertChecksExistingIdentityDestinationAndSlot() throws {
        let current = try read(), node: JSON = .object(["id": .string("new"), "title": .string("New")])
        XCTAssertThrowsError(try ChildTaskStructureCommand(insert: .object(["id": .string("a"), "title": .string("Duplicate")]), parent: nil, index: 0, read: current))
        XCTAssertThrowsError(try ChildTaskStructureCommand(insert: node, parent: "missing", index: 0, read: current))
        for index in [-1, 4, 1001] { XCTAssertThrowsError(try ChildTaskStructureCommand(insert: node, parent: nil, index: index, read: current)) }
    }
    func testMoveUsesPostRemovalIndexAndPreservesIndependentFields() throws {
        let current = try read(), command = try ChildTaskStructureCommand(move: "a", parent: "b", index: 0, read: current)
        XCTAssertEqual(command.body["incarnation"], .string(current.records.nodes["a"]!.incarnation))
        XCTAssertNil(command.body["node"]); XCTAssertNil(command.body["changes"])
        XCTAssertNoThrow(try command.review(read { _, raw in
            var rows = raw["records"]!.list, row = rows[1].object; row["revision"] = .number(99); rows[1] = .object(row); raw["records"] = .array(rows)
        }))
        XCTAssertNoThrow(try command.confirmed(receipt(command)))
        XCTAssertNoThrow(try ChildTaskStructureCommand(move: "a", parent: nil, index: 2, read: current))
    }
    func testMoveRefusesCyclesNoOpAndAbsentChildren() throws {
        let current = try read()
        for parent in ["a", "nested"] { XCTAssertThrowsError(try ChildTaskStructureCommand(move: "a", parent: parent, index: 0, read: current)) }
        XCTAssertThrowsError(try ChildTaskStructureCommand(move: "missing", parent: nil, index: 0, read: current))
        XCTAssertThrowsError(try ChildTaskStructureCommand(move: "a", parent: nil, index: 1, read: current))
        XCTAssertThrowsError(try ChildTaskStructureCommand(move: "a", parent: "b", index: 1, read: current))
    }
    func testDeleteReviewsEveryDescendantButNotUnrelatedFields() throws {
        let command = try ChildTaskStructureCommand(delete: "a", read: read())
        XCTAssertEqual(Set(command.body["subtree_versions"]!.object.keys), ["a", "nested"])
        XCTAssertNil(command.body["node"])
        for key in ["a", "nested", "b"] {
            let changed = try read { _, raw in
                var rows = raw["records"]!.list
                let index = rows.firstIndex { $0.object["node_key"] == .string(key) }!
                var row = rows[index].object; row["revision"] = .number(row["revision"]!.integer == 1 ? 2 : 100)
                rows[index] = .object(row); raw["records"] = .array(rows)
            }
            if key == "b" { XCTAssertNoThrow(try command.review(changed)) } else { XCTAssertThrowsError(try command.review(changed), key) }
        }
        XCTAssertNoThrow(try command.confirmed(receipt(command)))
    }
    func testDeleteVersionsCannotOmitOrAddUnreviewedNodes() throws {
        let command = try ChildTaskStructureCommand(delete: "a", read: read())
        for key in ["nested", "a"] {
            var body = command.body, versions = body["subtree_versions"]!.object; versions.removeValue(forKey: key); body["subtree_versions"] = .object(versions)
            if key == "a" { XCTAssertThrowsError(try ChildTaskStructureCommand(account: command.account, origin: origin, body: body)) }
            else { XCTAssertThrowsError(try ChildTaskStructureCommand(account: command.account, origin: origin, body: body).review(read())) }
        }
    }
    func testScopeAndStructuralABARejectSavedReview() throws {
        let command = try ChildTaskStructureCommand(move: "a", parent: "b", index: 0, read: read())
        XCTAssertThrowsError(try command.review(read { _, raw in raw["structure_revision"] = .number(4) }))
        let replacement = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try command.review(read { root, raw in root["task_generation"] = .string(replacement); raw["task_generation"] = .string(replacement) }))
        XCTAssertThrowsError(try command.review(read { root, raw in root["project_id"] = .null; raw["project_id"] = .null }))
    }
    func testUndoRequiresExactParentReceiptRootAndRevision() throws {
        let command = try source(), proof = try command.confirmed(fixture()["fixtureReceipt"]!.object)
        XCTAssertThrowsError(try ChildTaskStructureCommand(undo: command, receipt: proof, read: read { _, raw in raw["structure_revision"] = .number(3) }))
        var raw = proof.raw; raw["request_id"] = .string(UUID().uuidString.lowercased())
        let wrong = try ChildTaskStructureReceipt(account: command.account, raw: raw)
        XCTAssertThrowsError(try ChildTaskStructureCommand(undo: command, receipt: wrong, read: read()))
        XCTAssertThrowsError(try ChildTaskStructureCommand(undo: command, receipt: proof, read: read(), requestID: UUID(uuidString: command.id)!))
    }
    func testReceiptsRejectScopeActionNodeAndRevisionTampering() throws {
        let command = try source(), original = try fixture()["fixtureReceipt"]!.object
        for (key, value) in [("account", JSON.string(UUID().uuidString.lowercased())), ("request_id", .string(UUID().uuidString.lowercased())), ("node_key", .string("other")), ("task_generation", .null), ("project_id", .null), ("action", .string("move")), ("before_revision", .number(2)), ("after_revision", .number(4)), ("undo_of", .string(UUID().uuidString.lowercased())), ("incarnation", .null), ("replayed", .number(1)), ("title", .string("forged content"))] {
            var raw = original; raw[key] = value; XCTAssertThrowsError(try command.confirmed(raw), key)
        }
        for key in original.keys { var raw = original; raw.removeValue(forKey: key); XCTAssertThrowsError(try command.confirmed(raw), key) }
    }
    func testMoveDeleteAndUndoIncarnationContracts() throws {
        let command = try ChildTaskStructureCommand(move: "a", parent: "b", index: 0, read: read())
        var raw = try receipt(command); raw["incarnation"] = .string(UUID().uuidString.lowercased()); XCTAssertThrowsError(try command.confirmed(raw))
        let deletion = try ChildTaskStructureCommand(delete: "a", read: read()); var deleted = try receipt(deletion)
        deleted["incarnation"] = deletion.body["incarnation"]; XCTAssertThrowsError(try deletion.confirmed(deleted))
    }
    func testReplayAgreementIgnoresOnlyReplayMarker() throws {
        let command = try source(), a = try command.confirmed(fixture()["fixtureReceipt"]!.object); var raw = a.raw
        raw["replayed"] = .bool(true); let b = try command.confirmed(raw); XCTAssertTrue(a.agrees(b))
        raw["incarnation"] = .string(UUID().uuidString.lowercased()); XCTAssertFalse(a.agrees(try command.confirmed(raw)))
    }
    func testStoredCommandRoundTripAndStrictSchema() throws {
        let command = try source(), proof = try command.confirmed(fixture()["fixtureReceipt"]!.object)
        for c in [command, try ChildTaskStructureCommand(undo: command, receipt: proof, read: read()), try ChildTaskStructureCommand(delete: "a", read: read())] {
            let data = try JSONEncoder().encode(c); XCTAssertEqual(try ChildTaskStructureCommand(data: data), c)
            var raw = try JSONDecoder().decode([String: JSON].self, from: data); raw["unexpected"] = .bool(true)
            XCTAssertThrowsError(try ChildTaskStructureCommand(data: bytes(raw)))
        }
    }
    func testStoredWireRejectsRoundedNestedCountersAndDuplicates() throws {
        let command = try ChildTaskStructureCommand(delete: "a", read: read())
        let text = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
        for (name, current) in [("structure_revision", "2"), ("revision", "1"), ("protocol", "1")] {
            let bad = text.replacingOccurrences(of: "\"\(name)\":\(current)", with: "\"\(name)\":1.00000000000000000000000001")
            XCTAssertNotEqual(text, bad); XCTAssertThrowsError(try ChildTaskStructureCommand(data: Data(bad.utf8)), name)
        }
        XCTAssertThrowsError(try ChildTaskStructureCommand(data: Data((String(text.dropLast()) + ",\"account\":\"\(command.account)\"}").utf8)))
        XCTAssertThrowsError(try ChildTaskStructureCommand(data: Data(repeating: 32, count: 800_001)))
    }
    func testReceiptWireRejectsFractionalExponentAndDuplicateProofs() throws {
        let command = try source(), raw = try fixture()["fixtureReceipt"]!.object
        let text = String(decoding: try bytes(raw), as: UTF8.self)
        for value in ["1.0", "1e0", "1.00000000000000000000001", "9007199254740990.5"] {
            let bad = text.replacingOccurrences(of: "\"before_revision\":1", with: "\"before_revision\":" + value)
            XCTAssertThrowsError(try ChildTaskStructureReceipt(command: command, data: Data(bad.utf8)), value)
        }
        XCTAssertThrowsError(try ChildTaskStructureReceipt(command: command, data: Data((String(text.dropLast()) + ",\"protocol\":1}").utf8)))
    }
    func testTerminalDecisionsRequireExactOriginalRequest() throws {
        let command = try source(), receipt = try fixture()["fixtureReceipt"]!.object
        let closed: [String: JSON] = ["protocol": .number(1), "account": .string(command.account), "request_id": .string(command.id), "outcome": .string("closed"), "receipt": .null]
        XCTAssertTrue(try ChildTaskStructureResolution(command: command, data: bytes(closed)).closed)
        var applied = closed; applied["outcome"] = .string("applied"); applied["receipt"] = .object(receipt)
        XCTAssertFalse(try ChildTaskStructureResolution(command: command, data: bytes(applied)).closed)
        for (key, value) in [("account", JSON.string(UUID().uuidString.lowercased())), ("request_id", .string(UUID().uuidString.lowercased())), ("receipt", .object(receipt)), ("title", .string("leak")), ("outcome", .string("unknown"))] {
            var raw = closed; raw[key] = value; XCTAssertThrowsError(try ChildTaskStructureResolution(command: command, data: bytes(raw)), key)
        }
    }
    func testArchiveDiscoveryIsAccountOnlyBoundedUniqueDeleteMetadata() throws {
        let deletion = try ChildTaskStructureCommand(delete: "a", read: read()); var proof = try receipt(deletion); proof["replayed"] = .bool(true)
        let raw: [String: JSON] = ["protocol": .number(1), "account": .string(deletion.account), "entries": .array([.object(proof)])]
        XCTAssertEqual(try ChildTaskStructureUndoArchives(account: deletion.account, data: bytes(raw)).entries.count, 1)
        for entries in [[proof, proof], Array(repeating: proof, count: 65), [try fixture()["fixtureReceipt"]!.object]] {
            var bad = raw; bad["entries"] = .array(entries.map(JSON.object)); XCTAssertThrowsError(try ChildTaskStructureUndoArchives(account: deletion.account, data: bytes(bad)))
        }
        XCTAssertThrowsError(try ChildTaskStructureUndoArchives(account: UUID().uuidString.lowercased(), data: bytes(raw)))
        var leak = proof; leak["node"] = .object(["title": .string("Archived private task")]); var bad = raw; bad["entries"] = .array([.object(leak)])
        XCTAssertThrowsError(try ChildTaskStructureUndoArchives(account: deletion.account, data: bytes(bad)))
    }
    func testDisposalConfirmsOnlyExactActorAndRequestMetadata() throws {
        let command = try ChildTaskStructureCommand(delete: "a", read: read()), disposal = try ChildTaskStructureUndoDisposal(account: command.account, origin: origin, requestID: command.id)
        let raw: [String: JSON] = ["protocol": .number(1), "account": .string(command.account), "request_id": .string(command.id), "outcome": .string("forgotten")]
        XCTAssertNoThrow(try disposal.confirmed(bytes(raw)))
        for (key, value) in [("request_id", JSON.string(UUID().uuidString.lowercased())), ("outcome", .string("applied")), ("receipt", .object([:]))] {
            var bad = raw; bad[key] = value; XCTAssertThrowsError(try disposal.confirmed(bytes(bad)))
        }
    }
    func testDescriptionsDoNotExposeAuthoredContent() throws {
        let command = try source()
        XCTAssertFalse(String(describing: command).contains("Fresh subtask")); XCTAssertFalse(String(reflecting: command).contains("Fresh subtask"))
    }
    func testRequestSchemaIdentityAndSafeCounterBoundaries() throws {
        let command = try source()
        for (key, value) in [("protocol", JSON.number(2)), ("account", .string(UUID().uuidString.lowercased())), ("action", .string("replace")), ("task_id", .string("not-a-task")), ("structure_revision", .number(0)), ("index", .number(-0.0)), ("structure_revision", .number(9_007_199_254_740_991)), ("extra", .null)] {
            var body = command.body; body[key] = value
            XCTAssertThrowsError(try ChildTaskStructureCommand(account: command.account, origin: origin, body: body), key)
        }
        var body = command.body; body["structure_revision"] = .number(9_007_199_254_740_990)
        let high = try ChildTaskStructureCommand(account: command.account, origin: origin, body: body)
        var raw = try fixture()["fixtureReceipt"]!.object; raw["before_revision"] = .number(9_007_199_254_740_990); raw["after_revision"] = .number(9_007_199_254_740_991)
        XCTAssertNoThrow(try high.confirmed(raw))
    }
    func testStoredUndoRejectsRoundedOriginalReceiptCounters() throws {
        let command = try source(), proof = try command.confirmed(fixture()["fixtureReceipt"]!.object)
        let undo = try ChildTaskStructureCommand(undo: command, receipt: proof, read: read())
        let text = String(decoding: try JSONEncoder().encode(undo), as: UTF8.self)
        let bad = text.replacingOccurrences(of: "\"before_revision\":1", with: "\"before_revision\":1.0000000000000000000000001")
        XCTAssertNotEqual(bad, text)
        XCTAssertThrowsError(try ChildTaskStructureCommand(data: Data(bad.utf8)))
    }

    func testActualMoveAndDeleteReceiptsMatchSavedIntent() throws {
        let f = try fixture()
        for stem in ["Move", "Delete"] {
            let body = f["fixture" + stem + "Command"]!.object
            let command = try ChildTaskStructureCommand(account: body["account"]!.text, origin: origin, body: body)
            XCTAssertNoThrow(try command.confirmed(f["fixture" + stem + "Receipt"]!.object))
        }
    }
    func testActualRestorationReceiptRequiresItsDeletionLineageAndFreshIncarnation() throws {
        let f = try fixture(), body = f["fixtureDeleteCommand"]!.object
        let deletion = try ChildTaskStructureCommand(account: body["account"]!.text, origin: origin, body: body)
        let proof = try deletion.confirmed(f["fixtureDeleteReceipt"]!.object)
        let restore = try ChildTaskStructureCommand(account: deletion.account, origin: origin, body: f["fixtureRestoreCommand"]!.object,
            original: .init(body: deletion.body, receipt: proof.raw))
        let result = try restore.confirmed(f["fixtureRestoreReceipt"]!.object)
        XCTAssertNotEqual(result.raw["incarnation"], deletion.body["incarnation"])
        var reused = result.raw; reused["incarnation"] = deletion.body["incarnation"]
        XCTAssertThrowsError(try restore.confirmed(reused))
        var parent = proof.raw; parent["request_id"] = .string(UUID().uuidString.lowercased())
        XCTAssertThrowsError(try ChildTaskStructureCommand(account: deletion.account, origin: origin, body: restore.body, original: .init(body: deletion.body, receipt: parent)))
    }
    func testActualClosedDecisionAndBoundedArchiveDisposalMetadata() throws {
        let f = try fixture(), body = f["fixtureClosedCommand"]!.object, account = body["account"]!.text
        let command = try ChildTaskStructureCommand(account: account, origin: origin, body: body)
        XCTAssertTrue(try ChildTaskStructureResolution(command: command, data: bytes(f["fixtureClosed"]!.object)).closed)
        let list = try ChildTaskStructureUndoArchives(account: account, data: bytes(f["fixtureUndoArchives"]!.object))
        let disposal = f["fixtureDisposal"]!.object
        XCTAssertTrue(list.entries.contains { $0.raw["request_id"] == disposal["request_id"] })
        let action = try ChildTaskStructureUndoDisposal(account: account, origin: origin, requestID: disposal["request_id"]!.text)
        XCTAssertNoThrow(try action.confirmed(bytes(disposal)))
    }

    func testRecoveredDeletionUndoNeedsNoOriginalTaskContentOrJournal() throws {
        let f = try fixture(), body = f["fixtureRestoreCommand"]!.object
        var archived = f["fixtureDeleteReceipt"]!.object; archived["replayed"] = .bool(true)
        let proof = try ChildTaskStructureReceipt(account: body["account"]!.text, raw: archived)
        // Simulate the current survivor-only read after deletion. No archived
        // subtree is present locally; both receipt proofs come from PostgreSQL.
        let survivors = try read { root, raw in
            let records = raw["records"]!.list.filter { $0.object["node_key"] == .string("b") }.map { value -> JSON in
                var row = value.object; row["sibling_order"] = .number(0); return .object(row)
            }
            raw["records"] = .array(records); raw["structure_revision"] = body["structure_revision"]
            root["subtasks"] = .array(root["subtasks"].list.filter { $0.object["id"] == .string("b") })
        }
        let recovered = try ChildTaskStructureCommand(restoring: proof, read: survivors, requestID: UUID(uuidString: body["request_id"]!.text)!)
        XCTAssertNil(recovered.original?.body)
        XCTAssertTrue(AuthoredValueComparison.exactJSON(.object(recovered.body), .object(body)))
        XCTAssertNoThrow(try recovered.confirmed(f["fixtureRestoreReceipt"]!.object))
        XCTAssertEqual(try ChildTaskStructureCommand(data: JSONEncoder().encode(recovered)), recovered)
        XCTAssertThrowsError(try ChildTaskStructureCommand(restoring: proof, read: read()))
        XCTAssertThrowsError(try ChildTaskStructureCommand(restoring: source().confirmed(f["fixtureReceipt"]!.object), read: survivors))
    }

}
