import XCTest
@testable import TaskfoldCore

/// mac-r2 OA-1: fixture runs never save local mode, and a leaked flag is cleared once when the local workspace
/// holds only seed or preview rows. Uses a private defaults suite; never the app's own defaults.
final class LocalModeDefaultsTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private let launch = ["/Applications/Taskfold.app/Contents/MacOS/Taskfold"]

    override func setUp() {
        suite = "taskfold.tests.localmode." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite); defaults = nil }

    private func seedSnapshot(extraTask: String? = nil, extraTable: String? = nil) -> Snapshot {
        let project = Record(["id": .string("p1"), "user_id": .string("local"), "name": .string(LocalModeDefaults.gettingStartedProject), "description": .string(LocalModeDefaults.gettingStartedDescription)])
        var tasks = ["Press Space to complete this task", "Swipe right to complete this task"].enumerated().map { index, title in
            Record(["id": .string("t\(index)"), "user_id": .string("local"), "project_id": .string("p1"), "title": .string(title)])
        }
        if let extraTask { tasks.append(Record(["id": .string("mine"), "user_id": .string("local"), "project_id": .string(""), "title": .string(extraTask)])) }
        var tables: [String: [Record]] = ["projects": [project], "tasks": tasks,
                                          "view_preferences": [Record(["id": .string("today"), "user_id": .string("local"), "sort_by": .string("manual")])]]
        if let extraTable { tables[extraTable] = [Record(["id": .string("x"), "user_id": .string("local")])] }
        return Snapshot(tables: tables)
    }

    func testStartLocalPersistsOnlyWhenAsked() {
        LocalModeDefaults.recordStart(persist: false, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: LocalModeDefaults.key), "A fixture start must not save local mode")
        LocalModeDefaults.recordStart(persist: true, defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: LocalModeDefaults.key), "Choosing local mode saves it")
    }

    func testSeedAndPreviewRowsCountAsSeedOnly() {
        XCTAssertTrue(LocalModeDefaults.holdsOnlySeedRows(Snapshot()))
        XCTAssertTrue(LocalModeDefaults.holdsOnlySeedRows(seedSnapshot()))
        var preview = seedSnapshot()
        preview.tables["tasks", default: []].append(Record(["id": .string("abc"), "user_id": .string("preview"), "title": .string("Make time for the big idea")]))
        preview.tables["labels"] = [Record(["id": .string("preview-label"), "user_id": .string("local"), "name": .string("deep work")])]
        XCTAssertTrue(LocalModeDefaults.holdsOnlySeedRows(preview))
    }

    func testAnyUserRowKeepsLocalMode() {
        XCTAssertFalse(LocalModeDefaults.holdsOnlySeedRows(seedSnapshot(extraTask: "Buy milk")))
        XCTAssertFalse(LocalModeDefaults.holdsOnlySeedRows(seedSnapshot(extraTable: "labels")))
        XCTAssertFalse(LocalModeDefaults.holdsOnlySeedRows(seedSnapshot(extraTable: "view_orders")), "Unknown or planning tables are kept")
        var renamed = seedSnapshot(); renamed.tables["tasks"]![0]["title"] = .string("Press Space, then call the bank")
        XCTAssertFalse(LocalModeDefaults.holdsOnlySeedRows(renamed), "An edited seed task is the person's work")
        var moved = seedSnapshot(); moved.tables["tasks"]![0]["project_id"] = .string("other")
        XCTAssertFalse(LocalModeDefaults.holdsOnlySeedRows(moved))
        var project = seedSnapshot(); project.tables["projects"]!.append(Record(["id": .string("p2"), "user_id": .string("local"), "name": .string("Home")]))
        XCTAssertFalse(LocalModeDefaults.holdsOnlySeedRows(project))
    }

    func testRepairClearsLeakedFlagOnceForSeedOnlyWorkspace() {
        defaults.set(true, forKey: LocalModeDefaults.key)
        XCTAssertTrue(LocalModeDefaults.shouldClearLeakedFlag(defaults: defaults, arguments: launch) { .some(self.seedSnapshot()) })
        XCTAssertTrue(defaults.bool(forKey: LocalModeDefaults.repairKey))
        XCTAssertFalse(LocalModeDefaults.shouldClearLeakedFlag(defaults: defaults, arguments: launch) { .some(self.seedSnapshot()) }, "The repair runs once")
    }

    func testRepairClearsWhenNoLocalWorkspaceExists() {
        defaults.set(true, forKey: LocalModeDefaults.key)
        XCTAssertTrue(LocalModeDefaults.shouldClearLeakedFlag(defaults: defaults, arguments: launch) { .some(nil) })
    }

    func testRepairKeepsLocalModeWhenConservative() {
        defaults.set(true, forKey: LocalModeDefaults.key)
        XCTAssertFalse(LocalModeDefaults.shouldClearLeakedFlag(defaults: defaults, arguments: launch) { .some(self.seedSnapshot(extraTask: "Buy milk")) })
        defaults.removeObject(forKey: LocalModeDefaults.repairKey)
        XCTAssertFalse(LocalModeDefaults.shouldClearLeakedFlag(defaults: defaults, arguments: launch) { nil }, "An unreadable workspace keeps local mode")
    }

    func testRepairSkipsFixtureLaunchesWithoutUsingItsOneRun() {
        defaults.set(true, forKey: LocalModeDefaults.key)
        for arguments in [launch + ["--uitesting"], launch + ["--preview"], launch + ["-localMode", "YES"]] {
            XCTAssertFalse(LocalModeDefaults.shouldClearLeakedFlag(defaults: defaults, arguments: arguments) { .some(nil) })
        }
        XCTAssertFalse(defaults.bool(forKey: LocalModeDefaults.repairKey), "A fixture launch leaves the repair for the next normal launch")
        XCTAssertTrue(LocalModeDefaults.shouldClearLeakedFlag(defaults: defaults, arguments: launch) { .some(nil) })
    }

    func testRepairDoesNothingWhenLocalModeIsOff() {
        XCTAssertFalse(LocalModeDefaults.shouldClearLeakedFlag(defaults: defaults, arguments: launch) { .some(nil) })
        XCTAssertTrue(defaults.bool(forKey: LocalModeDefaults.repairKey), "Marked done, so a later real local workspace is never bounced")
        defaults.set(true, forKey: LocalModeDefaults.key)
        XCTAssertFalse(LocalModeDefaults.shouldClearLeakedFlag(defaults: defaults, arguments: launch) { .some(nil) })
    }

    func testRepairLeavesTheWorkspaceFileAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "localmode-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "local.json")
        let data = try JSONEncoder().encode(seedSnapshot())
        try data.write(to: file)
        defaults.set(true, forKey: LocalModeDefaults.key)
        LocalModeDefaults.repairLeakedFlag(defaults: defaults, arguments: launch, workspace: file)
        XCTAssertFalse(defaults.bool(forKey: LocalModeDefaults.key))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
}
