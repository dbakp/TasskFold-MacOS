import XCTest
@testable import TaskfoldCore

final class FocusFilterTests: XCTestCase {
    private func project(_ id: String, _ name: String, parent: String = "") -> Record {
        Record(["id": .string(id), "name": .string(name), "parent_id": parent.isEmpty ? .null : .string(parent)])
    }
    private func task(_ id: String, project: String = "", done: Bool = false) -> Record {
        Record(["id": .string(id), "title": .string("Task " + id), "project_id": project.isEmpty ? .null : .string(project), "completed": .bool(done)])
    }
    private let projects: [Record] = [
        Record(["id": .string("work"), "name": .string("Work")]),
        Record(["id": .string("work-sub"), "name": .string("Reports"), "parent_id": .string("work")]),
        Record(["id": .string("work-deep"), "name": .string("Q4"), "parent_id": .string("work-sub")]),
        Record(["id": .string("client"), "name": .string("Client")]),
        Record(["id": .string("home"), "name": .string("Home")]),
    ]
    private func state(_ ids: [String], name: String = "Work", hide: Bool = false, account: String = "acct") -> FocusFilterState {
        FocusFilterState(account: account, name: name, projectIDs: ids, hideOtherBadges: hide)
    }

    func testScopeIncludesChosenProjectsAndEverySubproject() throws {
        let scope = try XCTUnwrap(FocusFilterScope.resolve(state(["work", "client"]), account: "acct", projects: projects))
        XCTAssertEqual(scope.projectIDs, ["work", "work-sub", "work-deep", "client"])
        XCTAssertEqual(scope.chosenCount, 2)
        XCTAssertFalse(scope.allows(project: "home"))
    }

    func testApplyKeepsTasksInScopeAndDropsInboxAndOtherProjectsWithoutChangingThem() throws {
        let scope = try XCTUnwrap(FocusFilterScope.resolve(state(["work"]), account: "acct", projects: projects))
        let all = [task("1", project: "work"), task("2", project: "work-deep"), task("3", project: "home"), task("4"), task("5", project: "client")]
        let shown = scope.apply(to: all)
        XCTAssertEqual(shown.map(\.id), ["1", "2"])
        XCTAssertEqual(all.count, 5, "The filter is a view; the source is untouched")
        XCTAssertEqual(scope.apply(toProjects: projects).map(\.id), ["work", "work-sub", "work-deep"])
    }

    func testNoScopeWhenInactiveForAnotherAccountOrWithNoSurvivingProjects() {
        XCTAssertNil(FocusFilterScope.resolve(nil, account: "acct", projects: projects))
        XCTAssertNil(FocusFilterScope.resolve(state([]), account: "acct", projects: projects))
        XCTAssertNil(FocusFilterScope.resolve(state(["work"], account: "someone"), account: "acct", projects: projects), "Another account's filter is ignored")
        XCTAssertNil(FocusFilterScope.resolve(state(["deleted"]), account: "acct", projects: projects), "A filter whose projects are gone must not hide everything")
        XCTAssertNil(FocusFilterScope.resolve(state(["work"]), account: "", projects: projects))
        XCTAssertNotNil(FocusFilterScope.resolve(state(["work"], account: ""), account: "acct", projects: projects), "A filter applied before sign-in binds to the workspace that resolves it")
        XCTAssertEqual(FocusFilterScope.resolve(state(["deleted", "home"]), account: "acct", projects: projects)?.chosenCount, 1)
    }

    func testBadgeExclusionsListOtherProjectsAndInbox() throws {
        let scope = try XCTUnwrap(FocusFilterScope.resolve(state(["work"], hide: true), account: "acct", projects: projects))
        XCTAssertEqual(scope.excludedProjectIDs(allProjects: projects), ["client", "home", ""])
        XCTAssertTrue(scope.hideOtherBadges)
    }

    func testBannerReadsCalmlyAndCountsProjects() throws {
        let three = try XCTUnwrap(FocusFilterScope.resolve(state(["work", "client", "home"]), account: "acct", projects: projects))
        XCTAssertEqual(three.bannerText, "Focus: Work · showing 3 projects")
        let one = try XCTUnwrap(FocusFilterScope.resolve(state(["home"], name: ""), account: "acct", projects: projects))
        XCTAssertEqual(one.bannerText, "Focus filter · showing 1 project")
        XCTAssertTrue(three.bannerAccessibilityLabel.contains("hidden from view, not changed"))
    }

    func testOnlyBrowsingListsAreNarrowedAndSavedFilterQueriesAreUntouched() {
        for scope in [TaskScope.today, .upcoming, .inbox, .all, .label("l"), .saved("s")] { XCTAssertTrue(scope.focusFilterApplies) }
        for scope in [TaskScope.completed, .project("p")] { XCTAssertFalse(scope.focusFilterApplies) }
        var query = TaskQuery(scope: .saved("s")); let before = query
        query.focusProjects = ["work"]
        XCTAssertNotEqual(query, before, "The scope is part of the cache key")
        XCTAssertNil(before.filter)
    }

    func testTaskCacheAppliesTheScopeAndLeavesTheSourceAlone() {
        let rows = [task("1", project: "work"), task("2", project: "home"), task("3")]
        let cache = TaskCache()
        _ = cache.update(rows)
        var query = TaskQuery(scope: .all)
        XCTAssertEqual(Set(cache.matching(query).map(\.id)), ["1", "2", "3"])
        query.focusProjects = ["work"]
        XCTAssertEqual(cache.matching(query).map(\.id), ["1"])
        query.focusProjects = nil
        XCTAssertEqual(Set(cache.matching(query).map(\.id)), ["1", "2", "3"], "Turning the Focus off restores every task")
        query.scope = .inbox; query.focusProjects = ["work"]
        XCTAssertTrue(cache.matching(query).isEmpty)
        XCTAssertEqual(cache.tasks.count, 3)
    }

    func testStateRoundTripsThroughTheSharedDefaultsAndClears() throws {
        let suite = "taskfold.focusfilter.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(FocusFilterStore.load(defaults))
        let value = state(["work", "client"], hide: true)
        FocusFilterStore.save(value, to: defaults)
        XCTAssertEqual(FocusFilterStore.load(defaults), value)
        FocusFilterStore.save(state([]), to: defaults)
        XCTAssertNil(FocusFilterStore.load(defaults), "An empty filter is the same as no filter")
        FocusFilterStore.save(value, to: defaults); FocusFilterStore.save(nil, to: defaults)
        XCTAssertNil(FocusFilterStore.load(defaults))
        defaults.set(Data("{}".utf8), forKey: FocusFilterStore.key)
        XCTAssertNil(FocusFilterStore.load(defaults), "Unreadable state is ignored, never partly applied")
    }
}
