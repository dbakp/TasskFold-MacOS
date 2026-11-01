import XCTest
import CryptoKit
@testable import TaskfoldCore

final class ExactChildFieldProjectionTests: XCTestCase {
    private let opaque = #"{ "id":"child", "title":"Keep café", "description":"Keep notes", "\u00e9":9007199254740993, "e\u0301":1e1000, "future":{"é":1,"é":2}, "array":[null,false,1e-1000] }"#
    private func value(_ text: String) throws -> JSON { try TaskfoldJSONDecoder().decode(JSON.self, from: Data(text.utf8)) }
    private func bytes<T: Encodable>(_ value: T) throws -> Data { let encoder = TaskfoldJSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    func testFieldProjectionIsExplicitAndRetainsTheAuthoritativeSource() throws {
        let source = try value(opaque), original = try bytes(source), fields = try source.fieldEditingProjection()
        XCTAssertEqual(fields["id"], .string("child")); XCTAssertEqual(fields["title"], .string("Keep café"))
        XCTAssertNil(fields["é"]); XCTAssertNil(fields["e\u{0301}"])
        XCTAssertTrue(try String(decoding: bytes(fields["future"]!), as: UTF8.self).contains("é"))
        XCTAssertEqual(try bytes(source), original)
        XCTAssertThrowsError(try TaskfoldJSONDecoder().decode(Record.self, from: original))
        XCTAssertThrowsError(try Foundation.JSONEncoder().encode(source))
    }
    func testKnownEditsRetainUnknownMemberTokensWithoutHiddenTags() throws {
        let original = try value(opaque)
        let edited = try original.editingASCIIFields(["title": .string("Edited title"), "priority": .number(2)], removing: ["description"])
        let fields = try edited.fieldEditingProjection(), data = try bytes(edited), text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(fields["title"], .string("Edited title")); XCTAssertEqual(fields["priority"], .number(2)); XCTAssertNil(fields["description"])
        for token in [#""\u00e9":9007199254740993"#, #""e\u0301":1e1000"#, #""future":{"é":1,"é":2}"#, #""array":[null,false,1e-1000]"#] { XCTAssertTrue(text.contains(token), text) }
        XCTAssertFalse(text.contains("taskfold-preserved-json-")); XCTAssertEqual(try bytes(value(text)), data)
        XCTAssertEqual(try bytes(original), Data(opaque.utf8))
    }
    func testNoOpRetainsFormattingAndAuthoredUnicodeStringChangesAreNotNormalized() throws {
        let source = try value(opaque)
        XCTAssertEqual(try bytes(source.editingASCIIFields([:])), Data(opaque.utf8))
        XCTAssertEqual(try bytes(source.editingASCIIFields(["title": .string("Keep café")], removing: ["missing"])), Data(opaque.utf8))
        let changed = try source.editingASCIIFields(["title": .string("Keep cafe\u{0301}")])
        XCTAssertTrue(try changed.fieldEditingProjection()["title"]!.text.utf8.elementsEqual("Keep cafe\u{0301}".utf8))
        XCTAssertFalse(AuthoredValueComparison.exactJSON(source, changed))
    }
    func testUnicodeAliasOfAnASCIIMemberCannotBeOverwrittenByLookup() throws {
        let source = try value(#"{"K":1,"K":9007199254740993,"id":"child"}"#)
        XCTAssertEqual(try source.fieldEditingProjection()["K"], .number(1))
        let updated = try source.editingASCIIFields(["K": .number(3)])
        XCTAssertNotNil(try bytes(updated).range(of: Data(#""K":9007199254740993"#.utf8)))
        XCTAssertEqual(try updated.fieldEditingProjection()["K"], .number(3))
        let removed = try source.editingASCIIFields([:], removing: ["K"])
        XCTAssertNotNil(try bytes(removed).range(of: Data(#""K":9007199254740993"#.utf8)))
        XCTAssertNil(try bytes(removed).range(of: Data(#""K":"#.utf8)))
        XCTAssertNil(try removed.fieldEditingProjection()["K"])
        let single = try value(#"{"K":2,"id":"child"}"#)
        XCTAssertNil(try single.fieldEditingProjection()["K"])
        let appended = try single.editingASCIIFields(["K": .number(3)])
        let text = String(decoding: try bytes(appended), as: UTF8.self)
        XCTAssertTrue(text.contains(#""K":2"#)); XCTAssertTrue(text.contains(#""K":3"#))

    }
    func testInvalidFieldEditsAndNonObjectsFailWithoutAlteringOriginal() throws {
        let source = try value(opaque), before = try bytes(source)
        for key in ["", "é", String(repeating: "x", count: 201)] { XCTAssertThrowsError(try source.editingASCIIFields([key: .null])) }
        XCTAssertThrowsError(try source.editingASCIIFields(["title": .null], removing: ["title"]))
        for raw in ["null", "[]", "1e1000", "true"] { let other = try value(raw); XCTAssertThrowsError(try other.fieldEditingProjection()); XCTAssertThrowsError(try other.editingASCIIFields(["title": .string("Invalid")])) }
        XCTAssertEqual(try bytes(source), before)
    }
    private struct Fixture { let owner: String; let root: Record; let context: ChildTaskRecordContext; let response: [String: JSON]; let key: String; let originalFields: JSON }
    private func fixture(_ version: Int, changedUnknownValue: Bool = false, forbiddenChildren: Bool = false, futureValue: String = "1e1000") throws -> Fixture {
        let name = version == 1 ? "child-task-record-read" : "child-task-structure-read"
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        let file = try TaskfoldJSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        var root = Record(file["root"]!.object), response = file["response"]!.object, children = root["subtasks"].list, rows = response["records"]!.list
        let old = children[0].object, key = old["id"]!.text, index = try XCTUnwrap(rows.firstIndex { $0.object["node_key"] == .string(key) })
        var row = rows[index].object
        let existing = String(decoding: try bytes(row["fields"]!), as: UTF8.self)
        let prefix = #"{"é":9007199254740993,"e\u0301":1e1000,"#
        let exact = try value((prefix + existing.dropFirst()).replacingOccurrences(of: "1e1000", with: futureValue))
        var complete = exact
        if let nested = old["subtasks"] { complete = try complete.editingASCIIFields(["subtasks": nested]) }
        children[0] = complete; root["subtasks"] = .array(children)
        row["fields"] = changedUnknownValue ? try value((prefix + existing.dropFirst()).replacingOccurrences(of: "1e1000", with: "2e1000")) : exact
        if forbiddenChildren { row["fields"] = try row["fields"]!.editingASCIIFields(["subtasks": .null]) }
        rows[index] = .object(row); response["records"] = .array(rows)
        let owner = file["account"]!.text, context = try ChildTaskRecordContext(account: owner, origin: "https://exact-child.test", workspace: UUID(), session: UUID(), access: UUID(), snapshot: UUID(), root: root)
        return Fixture(owner: owner, root: root, context: context, response: response, key: key, originalFields: exact)
    }
    private func read(_ fixture: Fixture, version: Int) throws -> ChildTaskRecordRead {
        if version == 1 { return try .init(data: bytes(fixture.response), context: fixture.context) }
        return try ChildTaskStructureRead(data: bytes(fixture.response), context: fixture.context).records
    }
    func testBothAuthoritativeReadsRetainCollidingUnknownFieldsAndOnlySendExplicitEdits() throws {
        for version in [1, 2] {
            let fixture = try fixture(version), rootBytes = try bytes(fixture.root), read = try read(fixture, version: version), node = try XCTUnwrap(read.nodes[fixture.key])
            XCTAssertEqual(try bytes(node.sourceFields), try bytes(fixture.originalFields))
            XCTAssertTrue(AuthoredValueComparison.exactJSON(read.tree, fixture.root["subtasks"]))
            XCTAssertEqual(node.fields["id"]?.text, fixture.key); XCTAssertNil(node.fields["é"])
            let command = try ChildTaskFieldCommand(read: read, key: fixture.key, changes: ["title": .string("Only title changes")])
            XCTAssertEqual(command.body["changes"], .object(["title": .string("Only title changes")]))
            let wire = try bytes(command); XCTAssertFalse(String(decoding: wire, as: UTF8.self).contains("9007199254740993"))
            XCTAssertEqual(try TaskfoldJSONDecoder().decode(ChildTaskFieldCommand.self, from: wire), command)
            XCTAssertEqual(try bytes(fixture.root), rootBytes)
        }
    }
    func testUnknownContentMismatchAndSmuggledChildrenStillRejectFreshReads() throws {
        for version in [1, 2] {
            XCTAssertThrowsError(try read(fixture(version, changedUnknownValue: true), version: version))
            XCTAssertThrowsError(try read(fixture(version, forbiddenChildren: true), version: version))
        }
    }
    func testCacheAndActualEncryptedDraftRetainTheOriginalObjectAcrossColdReturn() throws {
        let f = try fixture(1), result = try read(f, version: 1), node = try XCTUnwrap(result.nodes[f.key])
        var snapshot = Snapshot(); snapshot.tables["tasks"] = [f.root]
        XCTAssertEqual(try TaskfoldJSONDecoder().decode(Snapshot.self, from: bytes(snapshot)), snapshot)
        let original = Record(node.fields); var edited = original; edited["title"] = .string("Saved explicit title")
        let edit = try TaskEditorRecovery(account: f.owner, origin: f.context.origin, original: original, draft: edited, extras: ["original_child_fields": node.sourceFields])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-exact-child-draft-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256), vault = BackupVault(directory: directory, account: f.owner, key: { key })
        try vault.saveEditorDraft(edit)
        let cold = try BackupVault(directory: directory, account: f.owner, key: { key }).editorDraft(edit.id, origin: f.context.origin)
        XCTAssertEqual(cold.draft.title, "Saved explicit title")
        XCTAssertEqual(try bytes(cold.extras["original_child_fields"]!), try bytes(node.sourceFields))
        let exported = String(decoding: try bytes(cold), as: UTF8.self)
        XCTAssertTrue(exported.contains("9007199254740993")); XCTAssertTrue(exported.contains("1e1000")); XCTAssertFalse(exported.contains("taskfold-preserved-json-"))
    }
    @MainActor func testSessionFreezesExactOriginalAcrossNewerReadsAndColdRecovery() throws {
        let source = try value(opaque), original = Record(try source.fieldEditingProjection())
        let newer = try value(opaque.replacingOccurrences(of: "1e1000", with: "2e1000"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-exact-session-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256), vault = BackupVault(directory: directory, account: "owner", key: { key })
        let session = TaskEditorSession(vault: vault, origin: nil, original: original, labels: [], exactOriginalFields: source)
        var edited = original; edited["title"] = .string("Changed title")
        session.capture(edited, extras: ["original_child_fields": newer])
        XCTAssertTrue(session.flush())
        let cold = try vault.editorDraft(session.id, origin: nil)
        XCTAssertEqual(try bytes(cold.extras["original_child_fields"]!), try bytes(source))
        XCTAssertEqual(cold.draft.title, "Changed title")
        let mismatched = try source.editingASCIIFields(["title": .string("Other task version")])
        XCTAssertThrowsError(try TaskEditorRecovery(account: "owner", origin: nil, original: original, draft: edited, extras: ["original_child_fields": mismatched]))
        XCTAssertThrowsError(try TaskEditorRecovery(account: "owner", origin: nil, original: original, draft: edited, extras: ["original_child_fields": .null]))
        XCTAssertTrue(session.finish())
    }

    func testRefreshedDraftCannotIgnoreChangedUnknownOriginalFields() throws {
        let before = try fixture(1), changed = try fixture(1, futureValue: "2e1000")
        let context = try ChildTaskRecordContext(account: before.owner, origin: before.context.origin, workspace: before.context.workspace, session: before.context.session, access: before.context.access, snapshot: UUID(), root: changed.root)
        let a = try read(before, version: 1), b = try ChildTaskRecordRead(data: bytes(changed.response), context: context)
        XCTAssertTrue(AuthoredValueComparison.exactJSON(.object(a.nodes[before.key]!.fields), .object(b.nodes[before.key]!.fields)))
        XCTAssertFalse(ChildTaskFieldDraftContinuation.retainedKeys(from: a, to: b).contains(before.key))
        XCTAssertTrue(ChildTaskFieldDraftContinuation.retainedKeys(from: a, to: a).contains(before.key))
    }

    private func hierarchy(_ f: Fixture) throws -> TaskHierarchyIndex {
        let projects = f.root.string("project_id").isEmpty ? [] : [Record(["id": f.root["project_id"], "name": .string("Project")])]
        return try TaskHierarchyIndex(roots: [f.root], projects: projects, workspace: .init(account: f.owner, generation: f.context.workspace))
    }
    func testFullSourceSurvivesColdCacheAndIndexedNestedRouting() throws {
        let f = try fixture(1), index = try hierarchy(f)
        let parent = try XCTUnwrap(index.items.first { $0.isSubtask && $0.source.id == f.key })
        XCTAssertEqual(parent.source.title, "Keep all fields")
        XCTAssertEqual(try bytes(parent.sourceFields), try bytes(f.root["subtasks"].list[0]))
        let nested = try XCTUnwrap(index.items.first { $0.isSubtask && $0.path.count == 2 })
        XCTAssertEqual(nested.parentTitles.last, parent.source.title)
        XCTAssertTrue(parent.requiresIndependentWriter); XCTAssertTrue(nested.requiresIndependentWriter)
        let opening = try ChildTaskFieldOpening(reference: parent.record.id, root: f.root, workspace: index.workspace)
        XCTAssertEqual(try opening.key(in: read(f, version: 1)), f.key)
        var snapshot = Snapshot(); snapshot.tables["tasks"] = [f.root]
        let restored = try TaskfoldJSONDecoder().decode(Snapshot.self, from: bytes(snapshot))
        let cold = try TaskHierarchyIndex(roots: restored.tables["tasks"]!, projects: [Record(["id": f.root["project_id"]])], workspace: index.workspace)
        XCTAssertEqual(cold.items.map(\.id), index.items.map(\.id))
        XCTAssertEqual(try bytes(cold.item(parent.id)!.sourceFields), try bytes(parent.sourceFields))
    }
    func testIndexedOpaqueChildCanUseFreshIndependentCompletionWithoutReplacingFields() throws {
        let f = try fixture(1), index = try hierarchy(f), read = try read(f, version: 1)
        let item = try XCTUnwrap(index.items.first { $0.source.id == f.key })
        let intent = try ChildTaskListCompletionIntent(task: item.record, root: f.root, projects: [Record(["id": f.root["project_id"]])], scope: .init(f.context))
        let key = try intent.key(in: read)
        let command = try ChildTaskCompletionCommand(ChildTaskCompletionDraft(read: read, key: key, action: .complete))
        XCTAssertEqual(command.body["node_key"], .string(f.key))
        XCTAssertNil(command.body["subtasks"]); XCTAssertNil(command.body["fields"])
        XCTAssertNil(try bytes(command).range(of: Data("9007199254740993".utf8)))
        let rows = try ChildTaskListOutline.rows([f.root], expanded: [f.root.id, item.id], projects: [Record(["id": f.root["project_id"]])], workspace: index.workspace, includeCompleted: true)
        XCTAssertEqual(rows.map(\.title), index.items.map { $0.record.title })
    }
    func testLegacyWholeObjectWritersCannotFlattenProjectedAncestorsOrChildren() throws {
        let f = try fixture(1), index = try hierarchy(f), before = try bytes(f.root)
        for item in index.items where item.isSubtask {
            let selection = try XCTUnwrap(index.selection(item.id))
            for edit in [TaskHierarchyIndex.Edit.patch(selection, ["title": .string("Changed")]), .delete(selection)] {
                XCTAssertThrowsError(try TaskHierarchyIndex.changes([edit], accessibleRoots: [f.root], projects: [Record(["id": f.root["project_id"]])], workspace: index.workspace))
            }
        }
        XCTAssertEqual(try bytes(f.root), before)
        var normal = f.root
        normal["subtasks"] = .array([.object(["id": .string("plain"), "title": .string("Plain"), "é": .string("Keep this unambiguous field")])])
        let simple = try TaskHierarchyIndex(roots: [normal], projects: [Record(["id": normal["project_id"]])], workspace: index.workspace)
        let item = try XCTUnwrap(simple.items.last); XCTAssertFalse(item.requiresIndependentWriter)
        XCTAssertEqual(item.source["é"], .string("Keep this unambiguous field"))
        let selection = try XCTUnwrap(simple.selection(item.id))
        let changed = try TaskHierarchyIndex.changes([.patch(selection, ["title": .string("Edited")])], accessibleRoots: [normal], projects: [Record(["id": normal["project_id"]])], workspace: index.workspace)
        XCTAssertEqual(changed.first?.fields["subtasks"]?.list.first?.object["é"], .string("Keep this unambiguous field"))
    }

    func testOversizedPreservedIndexProjectionRefusesWithoutChangingTheCache() throws {
        let f = try fixture(1)
        let raw = #"{"id":"large","title":"Large","é":0,"e\u0301":1,"padding":""# + String(repeating: "x", count: TaskHierarchyIndex.maximumPreservedProjectionBytes) + #""}"#
        let source = try value(raw); var root = f.root; root["subtasks"] = .array([source])
        XCTAssertThrowsError(try TaskHierarchyIndex(roots: [root], projects: [Record(["id": root["project_id"]])], workspace: .init(account: f.owner, generation: f.context.workspace)))
        XCTAssertEqual(try bytes(root["subtasks"].list[0]), Data(raw.utf8))
    }

    func testLegacySiblingEditsNeverConvertPreservedOrUnsupportedValuesToEmptyObjects() throws {
        let original = try value(opaque)
        let plain = JSON.object(["id": .string("plain"), "title": .string("Plain")])
        let source = JSON.array([original, .string("Legacy text"), .number(2), plain])
        let result = SubtaskTree.changing(source, id: "plain", fields: ["title": .string("Edited")])
        for index in 0..<3 { XCTAssertEqual(try bytes(result.list[index]), try bytes(source.list[index])) }
        XCTAssertEqual(result.list[3].object["title"], .string("Edited"))
        XCTAssertEqual(try bytes(SubtaskTree.changing(original, id: "child", fields: ["title": .string("Must not replace")])) , try bytes(original))
    }
    func testLegacyIndentCannotReplaceAnOpaqueParentOrAnUnknownChildContainer() throws {
        let original = try value(opaque), plain = JSON.object(["id": .string("plain"), "title": .string("Plain")])
        let unsupported = JSON.object(["id": .string("parent"), "title": .string("Parent"), "subtasks": .string("Future checklist")])
        for parent in [original, unsupported] {
            let source = JSON.array([parent, plain]), before = try bytes(source)
            XCTAssertThrowsError(try SubtaskTree.moving(source, id: "plain", direction: .indent))
            XCTAssertEqual(try bytes(source), before)
        }
    }

}
