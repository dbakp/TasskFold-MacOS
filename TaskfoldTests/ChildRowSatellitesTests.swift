import XCTest
import CryptoKit
@testable import TaskfoldCore

/// Phase 5 satellites: legacy references, templates, filters, Breakdown, widgets, print and local-mode conversion.
final class ChildRowSatellitesTests: XCTestCase {
    func row(_ id: String, parent: String? = nil, order: Double? = nil, project: String? = "p", section: String? = nil,
             title: String? = nil, due: String? = nil, completed: Bool = false, subtasks: JSON = .array([])) -> Record {
        var fields: [String: JSON] = ["id": .string(id), "user_id": .string("u"), "title": .string(title ?? id), "completed": .bool(completed),
                                      "created_at": .string("2026-01-01T00:00:00Z"), "task_generation": .string("gen-" + id), "completion_version": .number(0),
                                      "description": .string(""), "priority": .number(4), "labels": .array([]), "subtasks": subtasks]
        fields["project_id"] = project.map(JSON.string) ?? .null
        fields["section_id"] = section.map(JSON.string) ?? .null
        fields["parent_id"] = parent.map(JSON.string) ?? .null
        fields["child_order"] = order.map(JSON.number) ?? .null
        fields["due_date"] = due.map(JSON.string) ?? .null
        return Record(fields)
    }
    func node(_ id: String, _ title: String, _ children: [JSON] = []) -> JSON {
        .object(["id": .string(id), "title": .string(title), "completed": .bool(false), "subtasks": .array(children)])
    }
    let root = "8f0d7f52-5a0e-4a36-9a43-6c1d1f1f0001"

    // MARK: Legacy references (widgets, Spotlight, Handoff, list orders)

    func testLegacyReferenceResolvesToDeterministicRowID() {
        let reference = LegacySubtaskReference.reference([root, "a", "b"])
        let expected = LegacySubtaskConversion.legacyChildID(root: root, path: ["a", "b"])
        XCTAssertEqual(LegacyTaskReference.resolve(reference, enabled: true), expected)
        XCTAssertEqual(LegacyTaskReference.resolve(reference, enabled: false), reference, "Flag off keeps the legacy id")
        XCTAssertEqual(LegacyTaskReference.resolve(root, enabled: true), root)
        XCTAssertEqual(LegacyTaskReference.resolve("subtask:not-base64", enabled: true), "subtask:not-base64")
    }

    func testLegacyWidgetLinkRemapsToRowLinkInSameAccount() throws {
        let reference = LegacySubtaskReference.reference([root, "a"])
        var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "/?#%")
        let encoded = reference.addingPercentEncoding(withAllowedCharacters: allowed)!
        let url = URL(string: "taskfold://task/" + encoded + "?account=acct&context=" + String(repeating: "a", count: 64))!
        let mapped = LegacyTaskReference.remap(url, enabled: true)
        XCTAssertEqual(mapped.absoluteString, "taskfold://task/" + LegacySubtaskConversion.legacyChildID(root: root, path: ["a"]) + "?account=acct")
        XCTAssertEqual(LegacyTaskReference.remap(url, enabled: false), url)
        let plain = URL(string: "taskfold://task/" + root + "?account=acct")!
        XCTAssertEqual(LegacyTaskReference.remap(plain, enabled: true), plain)
        XCTAssertTrue(WidgetRecordLink.allows(mapped, account: "acct", available: true))
    }

    func testListOrderIDsRemapWithoutDuplicates() {
        let reference = LegacySubtaskReference.reference([root, "a"])
        let mapped = LegacySubtaskConversion.legacyChildID(root: root, path: ["a"])
        XCTAssertEqual(LegacyTaskReference.remapIDs(.array([.string(root), .string(reference), .string(mapped)]), enabled: true),
                       .array([.string(root), .string(mapped)]))
        let untouched = JSON.array([.string(root)])
        XCTAssertEqual(LegacyTaskReference.remapIDs(untouched, enabled: true), untouched)
    }

    // MARK: Templates

    func testTemplateCaptureNestsChildRowsAndApplyCreatesRows() throws {
        let tasks = [row("r", title: "Launch"), row("c1", parent: "r", order: 2, title: "Second"), row("c0", parent: "r", order: 1, title: "First"),
                     row("g", parent: "c0", order: 1, title: "Deep"), row("other", title: "Other")]
        let snapshot = Snapshot(tables: ["projects": [Record(["id": .string("p"), "user_id": .string("u"), "name": .string("Plan")])], "tasks": tasks])
        let template = try WorkflowTemplate.capture(kind: .task, id: "r", snapshot: snapshot, childRows: true)
        XCTAssertEqual(template.tasks.count, 1)
        let top = template.tasks[0]["subtasks"].list
        XCTAssertEqual(top.map { $0.object["title"]?.text }, ["First", "Second"], "Children are nested in sibling order")
        XCTAssertEqual(top[0].object["subtasks"]?.list.first?.object["title"]?.text, "Deep")
        XCTAssertNil(top[0].object["parent_id"], "The template document keeps no row links")

        let changes = try template.instantiate(account: "u", name: "", checkCancellation: {})
        let created = changes.filter { $0.table == "tasks" }.map { Record($0.fields) }
        XCTAssertEqual(created.count, 4)
        let byTitle = Dictionary(uniqueKeysWithValues: created.map { ($0.title, $0) })
        XCTAssertTrue(byTitle["Launch"]!["subtasks"].list.isEmpty)
        XCTAssertEqual(byTitle["Launch"]!.string("parent_id"), "")
        XCTAssertEqual(byTitle["First"]!.string("parent_id"), byTitle["Launch"]!.id)
        XCTAssertEqual(byTitle["Second"]!["child_order"], .number(2))
        XCTAssertEqual(byTitle["Deep"]!.string("parent_id"), byTitle["First"]!.id)
        XCTAssertNoThrow(try TaskTree.validate(changes.filter { $0.table == "tasks" }, tasks: []))
        XCTAssertEqual(created.map(\.title), ["Launch", "First", "Deep", "Second"], "Parents are created before their children")

        let legacy = try template.instantiate(account: "u", name: "", nestSubtasks: true, checkCancellation: {})
        XCTAssertEqual(legacy.filter { $0.table == "tasks" }.count, 1, "nestSubtasks keeps the nested tree on one row")
    }

    func testProjectTemplateDoesNotRepeatChildrenAtTopLevel() throws {
        let tasks = [row("r", title: "Root"), row("c", parent: "r", order: 1, title: "Child")]
        let snapshot = Snapshot(tables: ["projects": [Record(["id": .string("p"), "user_id": .string("u"), "name": .string("Plan")])], "tasks": tasks])
        let template = try WorkflowTemplate.capture(kind: .project, id: "p", snapshot: snapshot, childRows: true)
        XCTAssertEqual(template.tasks.map(\.title), ["Root"])
        XCTAssertEqual(template.tasks[0]["subtasks"].list.count, 1)
    }

    func testFlattenInheritsContainerFromRoot() {
        var created = row("n", project: "p2", section: "s2", title: "New")
        created["subtasks"] = .array([.object(row("k", project: nil, section: nil, title: "Kid").fields)])
        let rows = ChildRowTemplates.flatten(created)
        XCTAssertEqual(rows.map(\.id), ["n", "k"])
        XCTAssertEqual(rows[1].string("project_id"), "p2"); XCTAssertEqual(rows[1].string("section_id"), "s2")
        XCTAssertEqual(rows[1]["child_order"], .number(1))
    }

    // MARK: Filters

    func matches(_ rule: FilterRule, _ task: Record, tasks: [Record]) -> Bool {
        ChildRowFilterScope.with(tasks, enabled: true) { rule.matches(task, today: "2026-11-16", userID: "u", labels: [], timeZone: "UTC") }
    }

    func testHierarchyPredicatesReadParentID() {
        let tasks = [row("r"), row("c", parent: "r", order: 1), row("g", parent: "c", order: 1), row("solo")]
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        XCTAssertEqual(tasks.filter { matches(.predicate("root", ""), $0, tasks: tasks) }.map(\.id), ["r", "solo"])
        XCTAssertEqual(tasks.filter { matches(.predicate("subtask", ""), $0, tasks: tasks) }.map(\.id), ["c", "g"])
        XCTAssertEqual(tasks.filter { matches(.predicate("parent", ""), $0, tasks: tasks) }.map(\.id), ["r", "c"])
        XCTAssertTrue(matches(.and([.predicate("subtask", ""), .predicate("parent", "")]), byID["c"]!, tasks: tasks))
        XCTAssertFalse(matches(.not(.predicate("root", "")), byID["solo"]!, tasks: tasks))
    }

    func testParentPredicateNeedsBoundParents() {
        let tasks = [row("r"), row("c", parent: "r", order: 1)]
        XCTAssertFalse(FilterRule.predicate("parent", "").matches(tasks[0], today: "2026-11-16", userID: "u", labels: [], timeZone: "UTC"))
        XCTAssertEqual(ChildRowFilterScope.parents(of: tasks), ["r"])
    }

    // MARK: Breakdown and AI steps

    func testSuggestedStepsBecomeChildRows() {
        let parent = row("r", section: "s")
        let tree = TaskTree([parent, row("old", parent: "r", order: 3)])
        let proposed = JSON.array([.object(["title": .string("Draft")]), .string("Review"), .object(["title": .string("  ")])])
        let titles = ChildRowSteps.addedTitles(proposed, previous: .array([]))
        XCTAssertEqual(titles, ["Draft", "Review"])
        XCTAssertEqual(ChildRowSteps.addedTitles(proposed, previous: .array([.string("kept")])), ["Review"])
        let rows = ChildRowSteps.rows(titles, under: parent, tree: tree, account: "u")
        XCTAssertEqual(rows.map { $0.string("parent_id") }, ["r", "r"])
        XCTAssertEqual(rows.map { $0["child_order"] }, [.number(4), .number(5)])
        XCTAssertEqual(rows.map { $0.string("section_id") }, ["s", "s"])
        XCTAssertNoThrow(try TaskTree.validate(rows.map { Mutation(table: "tasks", recordID: $0.id, method: "POST", fields: $0.fields) }, tasks: [parent]))
    }

    // MARK: Widgets and completion

    func testWidgetRowsCarryParentTitle() throws {
        let tasks = [row("8f0d7f52-5a0e-4a36-9a43-6c1d1f1f0010", title: "Trip", due: "2026-11-16"),
                     row("8f0d7f52-5a0e-4a36-9a43-6c1d1f1f0011", parent: "8f0d7f52-5a0e-4a36-9a43-6c1d1f1f0010", order: 1, title: "Book train", due: "2026-11-16")]
        let payload = WidgetProjection.payload(tasks: tasks, projects: [Record(["id": .string("p"), "name": .string("Home")])], account: "u")
        let rows = payload["tasks"]!.list.map(\.object)
        XCTAssertEqual(rows.first { $0["title"]?.text == "Book train" }?["parent"], .string("Trip"))
        XCTAssertEqual(rows.first { $0["title"]?.text == "Trip" }?["parent"], .null)
    }

    func testWidgetAndWatchCompletionCascadeToChildRows() {
        let tasks = [row("r"), row("c", parent: "r", order: 1), row("done", parent: "r", order: 2, completed: true)]
        let changes = ChildRowCompletion.complete(tasks[0], tasks: tasks, at: Date(timeIntervalSince1970: 1_800_000_000), calendar: .current, account: "u", enabled: true)
        XCTAssertEqual(Set(changes.map(\.recordID)), ["r", "c"])
        let legacy = ChildRowCompletion.complete(tasks[0], tasks: tasks, at: Date(timeIntervalSince1970: 1_800_000_000), calendar: .current, account: "u", enabled: false)
        XCTAssertEqual(legacy.map(\.recordID), ["r"])
    }

    func testDisplayParentTitle() {
        let tree = TaskTree([row("r", title: ""), row("c", parent: "r", order: 1)])
        XCTAssertEqual(ChildRowDisplay.parentTitle(of: row("c", parent: "r", order: 1), tree: tree), "Untitled task")
        XCTAssertNil(ChildRowDisplay.parentTitle(of: row("r"), tree: tree))
    }

    // MARK: Print

    func testPrintNestsShownChildrenAndFlattensFilterResults() throws {
        let tasks = [row("r", title: "Trip"), row("c", parent: "r", order: 1, title: "Pack"), row("g", parent: "c", order: 1, title: "Socks")]
        let nested = try PrintDocument.capture(title: "Plan", subtitle: "", groups: [("", tasks)], projects: [], labels: [])
        XCTAssertEqual(nested.groups[0].items.map { "\($0.depth):\($0.title)" }, ["0:Trip", "1:Pack", "2:Socks"])
        let skipped = try PrintDocument.capture(title: "Plan", subtitle: "", groups: [("", [tasks[0], tasks[2]])], projects: [], labels: [], hierarchyRoots: tasks, expandOrdinaryChecklists: true)
        XCTAssertEqual(skipped.groups[0].items.map { "\($0.depth):\($0.title)" }, ["0:Trip", "1:Socks"], "A hidden level in between is skipped")
        let flat = try PrintDocument.capture(title: "Filter", subtitle: "", groups: [("", [tasks[2]])], projects: [], labels: [], hierarchyRoots: tasks)
        XCTAssertEqual(flat.groups[0].items.map(\.depth), [0])
        XCTAssertTrue(flat.groups[0].items[0].metadata.contains("Subtask of Trip › Pack"))
    }

    func testPrintNestsShownRowsUnderAHeading() throws {
        var heading = row("h", title: "Launch context"); heading["is_heading"] = .bool(true)
        let tasks = [heading, row("a", parent: "h", order: 1, title: "Draft"), row("s", parent: "h", order: 2, title: "Second phase"),
                     row("l", parent: "s", order: 1, title: "Layout")]
        let shown = [tasks[1], tasks[3], tasks[0]] // Today: the dated rows and their heading, as the list orders them
        let document = try PrintDocument.capture(title: "Today", subtitle: "", groups: [("", shown)], projects: [], labels: [], hierarchyRoots: tasks, expandOrdinaryChecklists: true)
        XCTAssertEqual(document.groups[0].items.map { "\($0.depth):\($0.title)" }, ["0:Launch context", "1:Draft", "1:Layout"], "No shown row is dropped")
        let csv = try TaskRowCSV.make(document)
        XCTAssertEqual(csv.rows.map { $0[2] }, ["", "row-1", "row-1"], "Both rows reference the heading row")
        XCTAssertEqual(try TaskRowCSV.make(document, options: .init(notes: true, checklists: false)).rows.count, 1)
    }

    // MARK: Local mode

    func testLocalWorkspaceConvertsOnceWithMarker() throws {
        let tree = JSON.array([node("a", "Alpha", [node("b", "Beta")]), .string("Plain item")])
        let reference = LegacySubtaskReference.reference([root, "a"])
        let tables: [String: [Record]] = ["tasks": [row(root, title: "Root", subtasks: tree)],
                                         "view_orders": [Record(["id": .string("group:p:none"), "user_id": .string("u"), "ids": .array([.string(root), .string(reference)])])]]
        let outcome = try XCTUnwrap(LocalChildRows.convert(tables, now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(outcome.roots, 1); XCTAssertEqual(outcome.rows, 3)
        let tasks = outcome.tables["tasks"]!
        XCTAssertNil(tasks.first { $0.id == root }?.fields["subtasks"], "The key is removed, not emptied")
        let alpha = LegacySubtaskConversion.legacyChildID(root: root, path: ["a"])
        XCTAssertEqual(tasks.first { $0.id == alpha }?.string("parent_id"), root)
        XCTAssertEqual(tasks.first { $0.title == "Beta" }?.string("parent_id"), alpha)
        XCTAssertEqual(outcome.tables["view_orders"]![0]["ids"], .array([.string(root), .string(alpha)]))
        XCTAssertTrue(LocalChildRows.converted(outcome.tables))
        XCTAssertEqual(outcome.tables[LocalChildRows.markerTable]![0]["archive"].object[root]?.object["original"], tree, "The original tree is kept")
        XCTAssertNil(LocalChildRows.convert(outcome.tables), "The marker stops a second conversion")
        XCTAssertNoThrow(try TaskTree.validate(tasks.filter { !$0.string("parent_id").isEmpty }.map { Mutation(table: "tasks", recordID: $0.id, method: "POST", fields: $0.fields) },
                                               tasks: tasks.filter { $0.string("parent_id").isEmpty }))
    }

    func testLocalWorkspaceWithoutJSONSubtasksIsLeftUntouched() {
        XCTAssertNil(LocalChildRows.convert(["tasks": [row("plain"), row("kid", parent: "plain", order: 1)]]), "No marker and no rewrite when nothing is in the old shape")
    }

    func testLocalConversionMarkerIsNotBackedUp() throws {
        var source = row(root, project: nil, subtasks: .array([node("a", "Alpha")])); source["task_generation"] = .string("8f0d7f52-5a0e-4a36-9a43-6c1d1f1f00aa")
        let outcome = try XCTUnwrap(LocalChildRows.convert(["tasks": [source]]))
        let backup = WorkspaceBackup.make(Snapshot(tables: outcome.tables), account: "u", childRows: true)
        XCTAssertNil(backup.tables[LocalChildRows.markerTable])
        XCTAssertNoThrow(try backup.plan(current: Snapshot(), account: "u", childRows: true))
    }

    // MARK: Legacy journals

    func testLegacyJournalExportIsOneSortedDocument() throws {
        let data = try LegacyChildJournalExport.document(["fields": Data(#"{"entries":[1]}"#.utf8)], now: Date(timeIntervalSince1970: 0))
        let decoded = try TaskfoldJSONDecoder().decode(JSON.self, from: data)
        XCTAssertEqual(decoded.object["version"], .number(1))
        XCTAssertEqual(decoded.object["journals"]?.object["fields"]?.object["entries"], .array([.number(1)]))
    }

    /// The export reads the files the retired journals sealed, offers only saved work, and account removal unlinks them.
    func testLegacyJournalsAreReadAsSealedAndRemoved() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        let scope = LegacyChildJournalExport.Scope(account: "8f0d7f52-5a0e-4a36-9a43-6c1d1f1f00ab", origin: "https://synthetic.example")
        let key = SymmetricKey(size: .bits256), digest = CalendarOAuthConfiguration.digest(scope.origin)
        func seal(_ kind: String, _ state: String) throws {
            let journal = try XCTUnwrap(LegacyChildJournalExport.journals.first { $0.kind == kind })
            let url = LegacyChildJournalExport.file(journal, vault: vault, scope: scope)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let context = Data((journal.context + "|" + journal.prefix + scope.account + "." + digest).utf8)
            try XCTUnwrap(AES.GCM.seal(Data(state.utf8), using: key, authenticating: context).combined).write(to: url)
        }
        XCTAssertEqual(try LegacyChildJournalExport.load(vault: vault, scope: scope) { XCTFail("No file, no key"); return key }, [:])
        let saved = #"{"version":1,"account":"\#(scope.account)","origin":"\#(scope.origin)","entries":[{"phase":"queued"}]}"#
        try seal("fields", saved)
        try seal("transfers", #"{"version":1,"account":"\#(scope.account)","origin":"\#(scope.origin)","entries":[]}"#)
        try seal("repairs", #"{"version":1,"account":"other","origin":"\#(scope.origin)","entries":[1],"drafts":[]}"#)
        XCTAssertEqual(try LegacyChildJournalExport.load(vault: vault, scope: scope) { key }, ["fields": Data(saved.utf8)])
        XCTAssertThrowsError(try LegacyChildJournalExport.load(vault: vault, scope: scope) { SymmetricKey(size: .bits256) })
        try LegacyChildJournalExport.remove(vault: vault, scope: scope)
        XCTAssertEqual(try LegacyChildJournalExport.load(vault: vault, scope: scope) { key }, [:])
        XCTAssertNoThrow(try LegacyChildJournalExport.remove(vault: vault, scope: scope))
    }
}
