import XCTest
@testable import TaskfoldCore

final class TeamTaskLabelsTests: XCTestCase {
    func testAddRemovePreservesExactLegacyValuesDuplicatesAndOrder() throws {
        let legacy = "ec250000-0000-4000-8000-000000000009"
        var draft = TeamTaskLabelsDraft(.array([.string("Design"), .string(legacy), .string("Design"), .string("  old name  ")]))
        XCTAssertTrue(draft.supported); XCTAssertNil(draft.entries[1].name)
        draft.remove(2); try draft.add("  Ready to ship  ")
        XCTAssertEqual(draft.value, .array([.string("Design"), .string(legacy), .string("  old name  "), .string("Ready to ship")]))
        XCTAssertEqual(draft.original.list.count, 4); XCTAssertTrue(draft.changed)
        XCTAssertThrowsError(try draft.add("Design"))
    }
    func testNewNamesRejectControlsBidiIDsAndOversizeWhileUnicodeWorks() throws {
        for input in ["", " \n ", "Line\nbreak", "Hidden\u{202e}name", "Hidden\u{2066}name", String(repeating: "a", count: 101), "ec250000-0000-4000-8000-000000000009"] {
            XCTAssertThrowsError(try TeamTaskLabelsDraft.name(input), input)
        }
        XCTAssertEqual(try TeamTaskLabelsDraft.name("  Diseño – 日本語 🧭  "), "Diseño – 日本語 🧭")
        XCTAssertNoThrow(try TeamTaskLabelsDraft.name(String(repeating: "🧭", count: 100)))
    }
    func testUnknownFormatsStayUntouchedAndLimitsNeverTruncate() throws {
        for value in [JSON.object(["future": .bool(true)]), .array([.number(42)]), .array([.string("")]), .array(Array(repeating: .string("Design"), count: 257)), .array([.string(String(repeating: "é", count: 513))])] {
            var draft = TeamTaskLabelsDraft(value); XCTAssertFalse(draft.supported)
            XCTAssertThrowsError(try draft.add("New")); draft.remove(0); XCTAssertEqual(draft.value, value); XCTAssertFalse(draft.changed)
        }
        var full = TeamTaskLabelsDraft(.array((0..<256).map { .string("Label \($0)") }))
        XCTAssertThrowsError(try full.add("Extra")); XCTAssertEqual(full.entries.count, 256)
        var empty = TeamTaskLabelsDraft(.null); XCTAssertFalse(empty.changed)
        try empty.add("Design"); empty.remove(0); XCTAssertFalse(empty.changed)
    }
    func testSuggestionsUseOnlyBoundedVisibleProjectTaskTextIncludingChildren() throws {
        let project = "ec250000-0000-4000-8000-000000000003"
        var task = Record.task(user: "actor", project: project); task["labels"] = .array([.string("Design"), .string("Design"), .string("ec250000-0000-4000-8000-000000000009"), .string("Hidden\u{202e}name")])
        task["subtasks"] = .array([.object(["labels": .array([.string("Review")])])])
        var privateTask = task; privateTask["project_id"] = .string("other-project"); privateTask["labels"] = .array([.string("Private label")]); privateTask["subtasks"] = .array([])
        XCTAssertEqual(TeamTaskLabelsDraft.suggestions(project: project, roots: [task, privateTask]), ["Design", "Review"])
        task["labels"] = .array((0..<256).map { .string("Name \($0)") }); XCTAssertEqual(TeamTaskLabelsDraft.suggestions(project: project, roots: [task]).count, 200)
    }
    private func scope() throws -> (Record, TeamTaskEditorDraft, TeamWorkspaceCache) {
        let actor = "ec250000-0000-4000-8000-000000000001", team = "ec250000-0000-4000-8000-000000000004", project = "ec250000-0000-4000-8000-000000000003"
        var task = Record.task(user: "ec250000-0000-4000-8000-000000000099", project: project); task["title"] = .string("Shared work"); task["labels"] = .array([.string("Design")])
        let boundary = try TeamWorkspaceBoundary(["workspace_boundary_protocol": .number(1), "account": .string(actor), "native_team_reads_enabled": .bool(true), "setup_paused": .bool(false), "token": .string(String(repeating: "a", count: 64)), "teams": .array([.object(["id": .string(team), "state": .string("active"), "revision": .number(1), "access_revision": .number(1)])]), "projects": .array([.object(["id": .string(project), "team_id": .string(team), "role": .string("editor"), "archived": .bool(false), "can_send_tasks": .bool(true)])])], account: actor, origin: "https://synthetic.example")
        let cache = try TeamWorkspaceCache(boundary: boundary, previous: nil, pending: [], tasks: [task])
        let draft = try TeamTaskEditorDraft(source: task, workspace: WorkspaceBinding(account: actor, generation: UUID()), session: UUID(), cache: cache, enabled: true)
        return (task, draft, cache)
    }
    func testScopedLabelMutationNeverMapsNamesToPersonalIDsAndPersistsBaseline() throws {
        let (task, draft, cache) = try scope()
        let catalog = [Record(["id": .string("ec250000-0000-4000-8000-000000000008"), "name": .string("Design")])]
        var desired = task; desired["labels"] = .array([.string("Design"), .string("Ready")])
        let change = try XCTUnwrap(draft.mutation(desired: desired, current: task, workspace: draft.workspace, session: draft.session, cache: cache, enabled: true))
        let actual = TeamTaskLabelsDraft.normalizing(change, existing: task, catalog: catalog, cache: cache)
        XCTAssertEqual(actual, change); XCTAssertEqual(actual.fields["labels"], desired["labels"])
        XCTAssertEqual(actual.baseline?["labels"], task["labels"]); XCTAssertEqual(actual.teamTaskScope, draft.scope)
        XCTAssertEqual(try JSONDecoder().decode(Mutation.self, from: JSONEncoder().encode(actual)), actual)
        var concurrent = task; concurrent["labels"] = .array([.string("Another edit")])
        let frozen = try XCTUnwrap(draft.mutation(desired: desired, current: concurrent, workspace: draft.workspace, session: draft.session, cache: cache, enabled: true))
        XCTAssertEqual(frozen.baseline?["labels"], task["labels"], "A concurrent replacement must retain the opening baseline for service review")
    }
    func testPersonalNormalizationStillWorksAndCatalogRenameDeleteExcludeSharedTasks() throws {
        let (task, draft, cache) = try scope()
        let id = "ec250000-0000-4000-8000-000000000008", catalog = [Record(["id": .string(id), "name": .string("Design")])]
        var personal = Record.task(user: draft.scope.account); personal["labels"] = .array([.string("Design")])
        let personalEdit = Mutation(table: "tasks", recordID: personal.id, method: "PATCH", fields: ["labels": personal["labels"]])
        XCTAssertEqual(TeamTaskLabelsDraft.normalizing(personalEdit, existing: personal, catalog: catalog, cache: cache).fields["labels"], .array([.string(id)]))
        XCTAssertTrue(TeamTaskLabelsDraft.usesPersonalCatalog(personal, cache: cache)); XCTAssertFalse(TeamTaskLabelsDraft.usesPersonalCatalog(task, cache: cache))
        var stale = task; stale["project_id"] = .null
        XCTAssertFalse(TeamTaskLabelsDraft.usesPersonalCatalog(stale, cache: cache), "Retained shared identity cannot become personal from a changed project field")
    }
    func testDraftCanBeReturnedToItsSourceWithoutNormalizingOrKeepingAnEdit() throws {
        let value: JSON = .array([.string("Design"), .string("Review")]); var draft = TeamTaskLabelsDraft(value)
        try draft.add("Temporary"); draft.remove(2)
        XCTAssertEqual(draft.value, value); XCTAssertFalse(draft.changed)
    }
}
