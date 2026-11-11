import XCTest
@testable import TaskfoldCore

final class SpotlightIndexingTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private let locale = Locale(identifier: "en_US_POSIX")
    private func project(_ id: String, _ name: String, parent: String = "", archived: Bool = false) -> Record {
        Record(["id": .string(id), "name": .string(name), "parent_id": parent.isEmpty ? .null : .string(parent), "is_archived": .bool(archived)])
    }
    private func task(_ id: String, _ title: String, project: String = "", due: String = "", notes: String = "", labels: [String] = [], done: Bool = false) -> Record {
        Record(["id": .string(id), "title": .string(title), "description": .string(notes), "project_id": project.isEmpty ? .null : .string(project),
                "due_date": due.isEmpty ? .null : .string(due), "labels": .array(labels.map { .string($0) }), "completed": .bool(done)])
    }
    private func documents(_ tasks: [Record], projects: [Record] = [], labels: [Record] = []) -> [SpotlightDocument] {
        SpotlightMapper.documents(tasks: tasks, projects: projects, labels: labels, calendar: calendar, locale: locale)
    }

    func testTaskMapsTitleDescriptionProjectDueAndLabels() {
        let label = Record(["id": .string("l1"), "name": .string("errand")])
        let docs = documents([task("t1", "  Buy stamps ", project: "p1", due: "2026-11-12", notes: "Books of ten", labels: ["l1", "plain"])],
                             projects: [project("p1", "Home")], labels: [label])
        let doc = docs.first { $0.kind == .task }
        XCTAssertEqual(doc?.title, "Buy stamps")
        XCTAssertEqual(doc?.textContent, "Books of ten")
        XCTAssertEqual(doc?.contentDescription, "Home · Due Thu, Nov 12")
        XCTAssertEqual(doc?.keywords, ["errand", "plain"])
        XCTAssertEqual(doc?.identifier, "task:t1")
        XCTAssertEqual(doc?.domain, "com.dbakp.taskfold.spotlight.task")
        XCTAssertNotNil(doc?.dueDate)
    }

    func testDescriptionIsCutAtTwoHundredCharacters() {
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(documents([task("t1", "Long", notes: long)]).first?.textContent.count, 200)
        XCTAssertEqual(SpotlightMapper.excerpt("short"), "short")
    }

    func testInboxTaskIsDescribedAsInboxAndUndatedHasNoDue() {
        let doc = documents([task("t1", "Call back")]).first
        XCTAssertEqual(doc?.contentDescription, "Inbox")
        XCTAssertNil(doc?.dueDate)
    }

    func testCompletedHeadingsAndUntitledTasksAreNeverIndexed() {
        var heading = task("h1", "A heading"); heading["is_heading"] = .bool(true)
        let docs = documents([task("t1", "Done", done: true), heading, task("t2", "   "), task("t3", "Keep")])
        XCTAssertEqual(docs.map(\.identifier), ["task:t3"])
    }

    func testProjectsAreIndexedWithOpenTaskCountsAndArchivedAreNot() {
        let docs = documents([task("t1", "A", project: "p1"), task("t2", "B", project: "p1"), task("t3", "C", project: "p2", done: true)],
                             projects: [project("p1", "Work"), project("p2", "Quiet"), project("p3", "Old", archived: true)])
        XCTAssertEqual(docs.filter { $0.kind == .project }.map(\.identifier), ["project:p1", "project:p2"])
        XCTAssertEqual(docs.first { $0.identifier == "project:p1" }?.contentDescription, "Project · 2 open tasks")
        XCTAssertEqual(docs.first { $0.identifier == "project:p2" }?.contentDescription, "Project · 0 open tasks")
    }

    func testDuplicateIdentifiersCollapseAndOutputIsStablyOrdered() {
        let docs = documents([task("b", "Two"), task("a", "One"), task("a", "One again")])
        XCTAssertEqual(docs.map(\.identifier), ["task:a", "task:b"])
    }

    func testFingerprintIsDeterministicAndChangesWithAnySearchableField() {
        let base = documents([task("t1", "Same", notes: "n")]).first!
        XCTAssertEqual(base.fingerprint, documents([task("t1", "Same", notes: "n")]).first!.fingerprint)
        XCTAssertEqual(base.fingerprint, SpotlightDigest.hex(["task", "t1", "Same", "n", "Inbox", "", ""].joined(separator: "\u{1E}")))
        for changed in [task("t1", "Other", notes: "n"), task("t1", "Same", notes: "m"), task("t1", "Same", due: "2026-01-02", notes: "n"),
                        task("t1", "Same", notes: "n", labels: ["x"]), task("t1", "Same", project: "p", notes: "n")] {
            XCTAssertNotEqual(base.fingerprint, documents([changed], projects: [project("p", "P")]).first { $0.kind == .task }!.fingerprint)
        }
    }

    func testDiffAddsChangesAndRemovesOnlyWhatDiffers() {
        let a = documents([task("a", "One"), task("b", "Two"), task("c", "Three")])
        let indexed = Dictionary(uniqueKeysWithValues: a.map { ($0.identifier, $0.fingerprint) })
        XCTAssertTrue(SpotlightIndexPlan.diff(indexed: indexed, current: a).isEmpty)
        // b edited, c completed (so absent), d created.
        let now = documents([task("a", "One"), task("b", "Two!"), task("c", "Three", done: true), task("d", "Four")])
        let plan = SpotlightIndexPlan.diff(indexed: indexed, current: now)
        XCTAssertEqual(plan.upserts.map(\.identifier), ["task:b", "task:d"])
        XCTAssertEqual(plan.removals, ["task:c"])
        XCTAssertEqual(plan.applying(to: indexed), Dictionary(uniqueKeysWithValues: now.map { ($0.identifier, $0.fingerprint) }))
    }

    func testDeletedTasksAndAnEmptyWorkspaceRemoveEverything() {
        let a = documents([task("a", "One"), task("b", "Two")])
        let indexed = Dictionary(uniqueKeysWithValues: a.map { ($0.identifier, $0.fingerprint) })
        XCTAssertEqual(SpotlightIndexPlan.diff(indexed: indexed, current: []).removals, ["task:a", "task:b"])
    }

    func testBatchesKeepEveryOperationUnderTheLimitAndRemoveFirst() {
        let docs = documents((0..<250).map { task(String(format: "t%03d", $0), "Task \($0)") })
        let plan = SpotlightIndexPlan(upserts: docs, removals: (0..<130).map { "task:old\($0)" })
        let batches = plan.batches(size: 100)
        XCTAssertEqual(batches.count, 2 + 3)
        XCTAssertTrue(batches.allSatisfy { $0.upserts.count + $0.removals.count <= 100 })
        XCTAssertTrue(batches[0].upserts.isEmpty && batches[1].upserts.isEmpty && !batches[2].upserts.isEmpty)
        XCTAssertEqual(batches.flatMap(\.upserts), docs)
        XCTAssertEqual(batches.flatMap(\.removals), plan.removals)
        XCTAssertTrue(SpotlightIndexPlan(upserts: [], removals: []).batches().isEmpty)
        XCTAssertEqual(plan.batches(size: 0).count, 380, "A non-positive size still makes progress, one operation at a time.")
    }

    func testDebounceWaitsTwoSecondsAfterTheLastChangeButNotPastTheCeiling() {
        var debouncer = SpotlightDebouncer(interval: 2, maximumDelay: 10)
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(debouncer.fireDate); XCTAssertFalse(debouncer.isDue(at: start))
        debouncer.request(at: start)
        XCTAssertEqual(debouncer.fireDate, start.addingTimeInterval(2))
        debouncer.request(at: start.addingTimeInterval(1.5))
        XCTAssertEqual(debouncer.fireDate, start.addingTimeInterval(3.5))
        XCTAssertFalse(debouncer.isDue(at: start.addingTimeInterval(3)))
        XCTAssertTrue(debouncer.isDue(at: start.addingTimeInterval(3.5)))
        // A constant stream of edits is still indexed once the ceiling is reached.
        for second in stride(from: 2.0, through: 9.0, by: 1.0) { debouncer.request(at: start.addingTimeInterval(second)) }
        XCTAssertEqual(debouncer.fireDate, start.addingTimeInterval(10))
        debouncer.fired()
        XCTAssertNil(debouncer.fireDate); XCTAssertFalse(debouncer.isPending)
        debouncer.request(at: start.addingTimeInterval(20)); debouncer.cancel()
        XCTAssertFalse(debouncer.isPending)
    }

    func testSchemaBuildOrAccountChangeForcesAFullReindex() {
        var state = SpotlightIndexState.empty(build: "1.0.1", account: "acct")
        XCTAssertFalse(state.requiresFullReindex(build: "1.0.1", account: "acct"))
        XCTAssertTrue(state.requiresFullReindex(build: "1.0.2", account: "acct"), "An upgrade reindexes once")
        XCTAssertTrue(state.requiresFullReindex(build: "1.0.1", account: "other"), "An account switch never reuses the old index")
        XCTAssertTrue(state.requiresFullReindex(schema: SpotlightIndexState.schemaVersion + 1, build: "1.0.1", account: "acct"), "A schema change reindexes")
        XCTAssertTrue(state.requiresFullReindex(build: "1.0.1", account: ""), "No workspace, no index")
        state.schema = 0
        XCTAssertTrue(state.requiresFullReindex(build: "1.0.1", account: "acct"))
        let data = try! JSONEncoder().encode(SpotlightIndexState(schema: 1, build: "b", account: "a", fingerprints: ["task:1": "ff"]))
        XCTAssertEqual(try JSONDecoder().decode(SpotlightIndexState.self, from: data).fingerprints, ["task:1": "ff"])
    }

    func testPolicyIndexesOnlyARealSignedInWorkspaceAndClearsOnSignOut() {
        func decide(_ account: String, _ args: [String] = [], signedIn: Bool = true, debug: Bool = true) -> SpotlightIndexPolicy.Decision {
            SpotlightIndexPolicy.decide(account: account, arguments: args, signedIn: signedIn, debugBuild: debug)
        }
        XCTAssertEqual(decide("user-1"), .index)
        XCTAssertEqual(decide("local"), .index)
        XCTAssertEqual(decide("", signedIn: false), .clear, "Signed out clears the index")
        XCTAssertEqual(decide("user-1", signedIn: false), .clear)
        XCTAssertEqual(decide("preview"), .leaveAlone)
        XCTAssertEqual(decide("ui-testing", ["--uitesting"]), .leaveAlone)
        XCTAssertEqual(decide("", ["--preview"], signedIn: false), .leaveAlone, "A fixture run before sign-in must not wipe a real index")
        XCTAssertEqual(decide("preview", ["--preview", "--spotlight-index-fixture"]), .index)
        XCTAssertEqual(decide("preview", ["--preview", "--spotlight-index-fixture"], debug: false), .leaveAlone, "Release builds ignore the flag")
        XCTAssertEqual(decide("user-1", ["--uitesting"]), .leaveAlone)
    }

    func testSelectedResultRoutesToTheExistingTaskAndProjectLinks() throws {
        XCTAssertEqual(SpotlightRoute(identifier: "task:abc"), .task("abc"))
        XCTAssertEqual(SpotlightRoute(identifier: "project:p-1"), .project("p-1"))
        XCTAssertNil(SpotlightRoute(identifier: "task:")); XCTAssertNil(SpotlightRoute(identifier: "note:1")); XCTAssertNil(SpotlightRoute(identifier: "plain"))
        let url = try XCTUnwrap(SpotlightRoute.task("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa").url(account: "acct"))
        XCTAssertEqual(url.absoluteString, "taskfold://task/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa?account=acct")
        XCTAssertTrue(WidgetRecordLink.allows(url, account: "acct", available: true))
        XCTAssertFalse(WidgetRecordLink.allows(url, account: "someone-else", available: true), "A stale result from another account is refused")
        let project = try XCTUnwrap(SpotlightRoute.project("p1").url(account: "acct"))
        XCTAssertEqual(project.host, "project"); XCTAssertEqual(project.lastPathComponent, "p1")
        XCTAssertTrue(WidgetRecordLink.allows(project, account: "acct", available: true))
        XCTAssertNil(SpotlightRoute.task("x").url(account: ""))
    }
}
