import XCTest
@testable import TaskfoldCore

/// Dependencies lite (Core/TaskDependencies.swift): cycle detection, the blocker cap, visibility
/// filtering, unreadable-blocker wording, the picker and the row indicator.
final class TaskDependenciesTests: XCTestCase {
    func task(_ id: String, title: String? = nil, completed: Bool = false) -> Record {
        Record(["id": .string(id), "user_id": .string("owner"), "title": .string(title ?? "Task " + id), "completed": .bool(completed)])
    }
    func dep(_ task: String, _ blocker: String) -> Record {
        Record(["id": .string(TaskDependencies.id(task: task, blocker: blocker)), "user_id": .string("owner"),
                "task_id": .string(task), "blocked_by_task_id": .string(blocker)])
    }
    func edges(_ pairs: [(String, String)]) -> [TaskDependencies.Edge] { pairs.map { .init(task: $0.0, blocker: $0.1) } }

    // MARK: cycles and self-blocking

    func testSelfBlockIsRejectedEvenWithDifferentCase() {
        XCTAssertEqual(TaskDependencies.rejection(adding: "A", to: "a", edges: []), .selfBlock)
    }
    func testDuplicateIsRejected() {
        XCTAssertEqual(TaskDependencies.rejection(adding: "b", to: "a", edges: edges([("a", "b")])), .duplicate)
    }
    func testDirectCycleIsRejected() {
        // b is already blocked by a, so a cannot be blocked by b.
        XCTAssertEqual(TaskDependencies.rejection(adding: "b", to: "a", edges: edges([("b", "a")])), .cycle)
    }
    func testTransitiveCycleIsRejected() {
        let chain = edges([("b", "c"), ("c", "d"), ("d", "a")])  // b<-c<-d<-a
        XCTAssertEqual(TaskDependencies.rejection(adding: "b", to: "a", edges: chain), .cycle)
        XCTAssertNil(TaskDependencies.rejection(adding: "z", to: "a", edges: chain))
    }
    func testDiamondIsNotACycle() {
        let diamond = edges([("a", "b"), ("a", "c"), ("b", "d")])
        XCTAssertNil(TaskDependencies.rejection(adding: "d", to: "c", edges: diamond))
        XCTAssertNil(TaskDependencies.rejection(adding: "c", to: "b", edges: diamond))
    }
    func testWalkTerminatesOnExistingLoopData() {
        // Corrupt data with a loop elsewhere must not hang the walk.
        let loop = edges([("x", "y"), ("y", "x")])
        XCTAssertNil(TaskDependencies.rejection(adding: "x", to: "a", edges: loop))
        XCTAssertFalse(TaskDependencies.reaches(from: "x", to: "a", edges: loop))
    }
    func testEmptyIdentifiersAreUnavailable() {
        XCTAssertEqual(TaskDependencies.rejection(adding: "", to: "a", edges: []), .unavailable)
    }

    // MARK: the cap

    func testCapAllowsTenAndRejectsTheEleventh() {
        var current: [TaskDependencies.Edge] = []
        for index in 1...TaskDependencies.maximumBlockers {
            XCTAssertNil(TaskDependencies.rejection(adding: "b\(index)", to: "a", edges: current))
            current.append(.init(task: "a", blocker: "b\(index)"))
        }
        XCTAssertEqual(TaskDependencies.maximumBlockers, 10)
        XCTAssertEqual(TaskDependencies.rejection(adding: "b11", to: "a", edges: current), .tooMany)
        // The cap is per blocked task, not global.
        XCTAssertNil(TaskDependencies.rejection(adding: "b1", to: "other", edges: current))
    }

    // MARK: visibility

    func testTaskIsHiddenUntilEveryBlockerIsCompleted() {
        let tasks = [task("a"), task("b"), task("c", completed: true), task("d")]
        let deps = [dep("a", "b"), dep("a", "c")]
        XCTAssertEqual(TaskDependencies.blockedTaskIDs(tasks: tasks, dependencies: deps), ["a"])
        let afterB = [task("a"), task("b", completed: true), task("c", completed: true), task("d")]
        XCTAssertEqual(TaskDependencies.blockedTaskIDs(tasks: afterB, dependencies: deps), [])
    }
    func testDeletedOrUnreadableBlockerDoesNotHide() {
        // "ghost" is not among the readable tasks (deleted, or in a project this reader cannot see).
        XCTAssertEqual(TaskDependencies.blockedTaskIDs(tasks: [task("a")], dependencies: [dep("a", "ghost")]), [])
    }
    func testOneOpenBlockerAmongManyKeepsTheTaskHidden() {
        let tasks = [task("a"), task("b", completed: true), task("c")]
        XCTAssertEqual(TaskDependencies.blockedTaskIDs(tasks: tasks, dependencies: [dep("a", "b"), dep("a", "c")]), ["a"])
    }
    func testIdentifiersCompareCaseInsensitively() {
        let blocked = TaskDependencies.blockedTaskIDs(tasks: [task("AAAA"), task("BBBB")], dependencies: [dep("aaaa", "bbbb")])
        XCTAssertEqual(blocked, ["aaaa"])
        let rows = TaskDependencies.visible([task("AAAA"), task("CCCC")], blocked: blocked, showBlocked: false)
        XCTAssertEqual(rows.map(\.id), ["CCCC"])
    }
    func testVisibilityFilterHonoursTheToggle() {
        let rows = [task("a"), task("b")]
        XCTAssertEqual(TaskDependencies.visible(rows, blocked: ["a"], showBlocked: false).map(\.id), ["b"])
        XCTAssertEqual(TaskDependencies.visible(rows, blocked: ["a"], showBlocked: true).map(\.id), ["a", "b"])
        XCTAssertEqual(TaskDependencies.visible(rows, blocked: [], showBlocked: false).map(\.id), ["a", "b"])
    }
    func testMalformedAndSelfRowsAreIgnored() {
        let bad = [Record(["id": .string("1"), "task_id": .string("a")]), dep("a", "a"),
                   Record(["id": .string("2"), "task_id": .string(""), "blocked_by_task_id": .string("b")])]
        XCTAssertTrue(TaskDependencies.edges(bad).isEmpty)
        XCTAssertEqual(TaskDependencies.blockedTaskIDs(tasks: [task("a"), task("b")], dependencies: bad), [])
    }

    // MARK: sharing: never name a task the reader cannot see

    func testUnreadableBlockerIsNamedGenerically() {
        let lines = TaskDependencies.blockerLines(for: "a", dependencies: [dep("a", "secret"), dep("a", "b")],
                                                  tasks: [task("a"), task("b", title: "Draft brief")])
        XCTAssertEqual(lines.map(\.title).sorted(), ["Draft brief", "a task you can't see"])
        XCTAssertFalse(lines.contains { $0.title.contains("secret") })
        XCTAssertEqual(lines.first { !$0.readable }?.title, TaskDependencies.hiddenBlockerTitle)
    }
    func testIndicatorNeverNamesUnreadableBlockerAndIgnoresIt() {
        let hidden = TaskDependencies.blockerLines(for: "a", dependencies: [dep("a", "secret")], tasks: [task("a")])
        XCTAssertNil(TaskDependencies.indicator(openBlockers: hidden, waitingOn: nil))
    }
    func testBlockerLinesOnlyCoverTheRequestedTask() {
        let lines = TaskDependencies.blockerLines(for: "a", dependencies: [dep("a", "b"), dep("c", "b")], tasks: [task("a"), task("b"), task("c")])
        XCTAssertEqual(lines.count, 1)
    }

    // MARK: picker

    func testCandidatesExcludeSelfExistingBlockersAndLoops() {
        let tasks = [task("a", title: "Write report"), task("b", title: "Write outline"), task("c", title: "Write intro"),
                     task("d", title: "Write summary"), task("e", title: "Done thing", completed: true)]
        // d is already blocked by a, so d cannot become a blocker of a. b is already a blocker of a.
        let deps = [dep("d", "a"), dep("a", "b")]
        let found = TaskDependencies.candidates(for: "a", search: "write", tasks: tasks, dependencies: deps).map(\.id)
        XCTAssertEqual(found, ["c"])
        XCTAssertFalse(TaskDependencies.candidates(for: "a", search: "", tasks: tasks, dependencies: deps).map(\.id).contains("e"))
    }
    func testCandidatesAreEmptyAtTheCap() {
        let blockers = (1...10).map { task("b\($0)") }
        let deps = (1...10).map { dep("a", "b\($0)") }
        XCTAssertTrue(TaskDependencies.candidates(for: "a", search: "task", tasks: [task("a"), task("extra")] + blockers, dependencies: deps).isEmpty)
    }

    // MARK: ids and notes

    func testRowIdentityIsStableAndOrdered() {
        XCTAssertEqual(TaskDependencies.id(task: "A", blocker: "B"), TaskDependencies.id(task: "a", blocker: "b"))
        XCTAssertNotEqual(TaskDependencies.id(task: "a", blocker: "b"), TaskDependencies.id(task: "b", blocker: "a"))
        XCTAssertNotNil(UUID(uuidString: TaskDependencies.id(task: "a", blocker: "b")))
    }
    func testWaitingOnNormalisation() {
        XCTAssertNil(TaskDependencies.normalizedWaitingOn("  \n\t "))
        XCTAssertEqual(TaskDependencies.normalizedWaitingOn("  Anna's \n  reply "), "Anna's reply")
        let long = String(repeating: "é", count: 300)
        XCTAssertEqual(TaskDependencies.normalizedWaitingOn(long)?.unicodeScalars.count, TaskDependencies.maximumWaitingOnLength)
    }

    // MARK: indicator

    func testIndicatorWordingForBlockedWaitingAndBoth() {
        let one = TaskDependencies.blockerLines(for: "a", dependencies: [dep("a", "b")], tasks: [task("a"), task("b", title: "Draft brief")])
        XCTAssertEqual(TaskDependencies.indicator(openBlockers: one, waitingOn: nil), .init(symbol: "lock", label: "Blocked by Draft brief"))
        XCTAssertEqual(TaskDependencies.indicator(openBlockers: [], waitingOn: "Anna's reply"), .init(symbol: "hourglass", label: "Waiting on Anna's reply"))
        XCTAssertEqual(TaskDependencies.indicator(openBlockers: one, waitingOn: "Anna")?.label, "Blocked by Draft brief. Waiting on Anna")
        let two = TaskDependencies.blockerLines(for: "a", dependencies: [dep("a", "b"), dep("a", "c")], tasks: [task("a"), task("b"), task("c")])
        XCTAssertEqual(TaskDependencies.indicator(openBlockers: two, waitingOn: "  ")?.label, "Blocked by 2 tasks")
        XCTAssertNil(TaskDependencies.indicator(openBlockers: [], waitingOn: nil))
    }
    func testCompletedBlockerNoLongerShowsAnIndicator() {
        let done = TaskDependencies.blockerLines(for: "a", dependencies: [dep("a", "b")], tasks: [task("a"), task("b", completed: true)])
        XCTAssertNil(TaskDependencies.indicator(openBlockers: done, waitingOn: nil))
    }
}

final class TaskDependencyIndexTests: XCTestCase {
    func task(_ id: String, title: String? = nil, completed: Bool = false) -> Record {
        Record(["id": .string(id), "title": .string(title ?? "Task " + id), "completed": .bool(completed)])
    }
    func dep(_ task: String, _ blocker: String) -> Record {
        Record(["id": .string(TaskDependencies.id(task: task, blocker: blocker)), "task_id": .string(task), "blocked_by_task_id": .string(blocker)])
    }
    func testIndexAgreesWithTheStandaloneFunctions() {
        let tasks = [task("a"), task("b"), task("c", completed: true), task("d"), task("e")]
        let deps = [dep("a", "b"), dep("a", "c"), dep("d", "c"), dep("e", "ghost")]
        let index = TaskDependencies.Index(tasks: tasks, dependencies: deps)
        XCTAssertEqual(index.blocked, TaskDependencies.blockedTaskIDs(tasks: tasks, dependencies: deps))
        XCTAssertEqual(index.blocked, ["a"])
        XCTAssertEqual(index.lines(for: "A"), TaskDependencies.blockerLines(for: "a", dependencies: deps, tasks: tasks))
        XCTAssertEqual(index.lines(for: "e").map(\.title), ["a task you can't see"])
        XCTAssertTrue(index.isBlocked("A"))
        XCTAssertFalse(index.isBlocked("d"))
    }
    func testEmptyIndexHidesNothing() {
        XCTAssertTrue(TaskDependencies.Index.empty.blocked.isEmpty)
        XCTAssertTrue(TaskDependencies.Index(tasks: [Record(["id": .string("a")])], dependencies: []).lines(for: "a").isEmpty)
    }
}

/// Sync, local-mode and backup seams around the dependency rows.
final class TaskDependencySyncTests: XCTestCase {
    func task(_ id: String) -> Record { Record(["id": .string(id), "user_id": .string("owner"), "title": .string("Task " + id), "completed": .bool(false)]) }
    func dep(_ task: String, _ blocker: String) -> Record {
        Record(["id": .string(TaskDependencies.id(task: task, blocker: blocker)), "user_id": .string("owner"), "task_id": .string(task), "blocked_by_task_id": .string(blocker)])
    }
    @MainActor func testDependencyChangesArePlannedAsAnOrdinaryTable() {
        XCTAssertTrue(WorkspaceReadPlanner.ordinaryTables.contains(TaskDependencies.table))
        XCTAssertFalse(Backend.workspaceTables.contains(TaskDependencies.table), "the required full read must not depend on the optional table")
        XCTAssertTrue(Backend.optionalWorkspaceTables.contains(TaskDependencies.table))
    }
    func testDependencyRowsPersistInTheLocalSnapshotAndRoundTrip() throws {
        var snapshot = Snapshot(tables: ["tasks": [task("a"), task("b")]])
        snapshot.apply(Mutation(table: TaskDependencies.table, recordID: TaskDependencies.id(task: "a", blocker: "b"), method: "POST",
                                fields: dep("a", "b").fields, insertOnly: true))
        XCTAssertEqual(snapshot.tables[TaskDependencies.table]?.count, 1)
        // A retried insert never duplicates the row.
        snapshot.apply(Mutation(table: TaskDependencies.table, recordID: TaskDependencies.id(task: "a", blocker: "b"), method: "POST",
                                fields: dep("a", "b").fields, insertOnly: true))
        XCTAssertEqual(snapshot.tables[TaskDependencies.table]?.count, 1)
        let decoded = try TaskfoldJSONDecoder().decode(Snapshot.self, from: TaskfoldJSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.tables[TaskDependencies.table]?.map(\.id), snapshot.tables[TaskDependencies.table]?.map(\.id))
        XCTAssertEqual(TaskDependencies.blockedTaskIDs(tasks: decoded.tables["tasks"] ?? [], dependencies: decoded.tables[TaskDependencies.table] ?? []), ["a"])
        snapshot.apply(Mutation(table: TaskDependencies.table, recordID: TaskDependencies.id(task: "a", blocker: "b"), method: "DELETE", fields: [:]))
        XCTAssertEqual(snapshot.tables[TaskDependencies.table]?.count, 0)
    }
    func testDeletingATaskDropsItsLinksAtOnce() {
        var snapshot = Snapshot(tables: ["tasks": [task("a"), task("b"), task("c")], TaskDependencies.table: [dep("a", "b"), dep("c", "a"), dep("c", "b")]])
        snapshot.apply(Mutation(table: "tasks", recordID: "a", method: "DELETE", fields: [:]))
        XCTAssertEqual(snapshot.tables[TaskDependencies.table]?.map(\.id), [TaskDependencies.id(task: "c", blocker: "b")])
    }
    func testBackupsOmitDependencyRowsAndStillValidate() throws {
        let snapshot = Snapshot(tables: ["tasks": [task("a"), task("b")], TaskDependencies.table: [dep("a", "b")]])
        let backup = WorkspaceBackup.make(snapshot, account: "owner")
        XCTAssertNil(backup.tables[TaskDependencies.table])
        try backup.validate()
    }
    func testBackupKeepsTheWaitingOnNote() throws {
        var waiting = task("a"); waiting["waiting_on"] = .string("Anna's reply")
        let backup = WorkspaceBackup.make(Snapshot(tables: ["tasks": [waiting]]), account: "owner")
        try backup.validate()
        XCTAssertEqual(backup.tables["tasks"]?.first?.string("waiting_on"), "Anna's reply")
    }
    func testShowBlockedIsPartOfTheQueryIdentity() {
        XCTAssertNotEqual(TaskQuery(scope: .today), TaskQuery(scope: .today, showBlocked: true))
        XCTAssertFalse(TaskQuery(scope: .today).showBlocked)
    }
}
