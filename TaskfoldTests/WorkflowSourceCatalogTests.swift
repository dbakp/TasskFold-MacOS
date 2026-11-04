import XCTest
@testable import TaskfoldCore

final class WorkflowSourceCatalogTests: XCTestCase {
    func project(_ id: String, _ name: String, parent: String = "", archived: Bool = false) -> Record {
        Record(["id": .string(id), "name": .string(name), "parent_id": .string(parent), "is_archived": .bool(archived)])
    }
    func task(_ id: String, _ title: String, project: String = "", section: String = "") -> Record {
        Record(["id": .string(id), "title": .string(title), "project_id": .string(project), "section_id": .string(section)])
    }
    func testRepeatedTaskNamesKeepProjectSectionAndArchiveContext() throws {
        let projects = [project("work", "Work"), project("client", "Client", parent: "work"), project("past", "Past", archived: true)]
        let sections = [Record(["id": .string("design"), "name": .string("Design"), "project_id": .string("client")])]
        let tasks = [task("one", "Review", project: "client", section: "design"), task("two", "Review", project: "past"), task("three", "Review")]
        let catalog = try WorkflowSourceCatalog(kind: .task, projects: projects, sections: sections, tasks: tasks)
        XCTAssertEqual(catalog.options.first { $0.id == "one" }?.location, "Work › Client › Design")
        XCTAssertEqual(catalog.options.first { $0.id == "two" }?.location, "Archived · Past")
        XCTAssertEqual(catalog.options.first { $0.id == "three" }?.location, "Inbox")
        XCTAssertEqual(catalog.page(query: "client review").options.map(\.id), ["one"])
        XCTAssertEqual(catalog.page(query: "archived").options.map(\.id), ["two"])
    }
    func testProjectAndSectionChoicesHaveDistinctLocations() throws {
        let projects = [project("a", "Cedar"), project("b", "Maple"), project("ap", "Plan", parent: "a"), project("bp", "Plan", parent: "b")]
        let catalog = try WorkflowSourceCatalog(kind: .project, projects: projects, sections: [], tasks: [])
        XCTAssertEqual(catalog.page(query: "plan cedar").options.map(\.id), ["ap"])
        let sections = [Record(["id": .string("as"), "name": .string("Ready"), "project_id": .string("ap")]), Record(["id": .string("bs"), "name": .string("Ready"), "project_id": .string("bp")])]
        let sectionCatalog = try WorkflowSourceCatalog(kind: .section, projects: projects, sections: sections, tasks: [])
        XCTAssertEqual(sectionCatalog.page(query: "maple ready").options.map(\.id), ["bs"])
    }
    func testMissingAndAmbiguousProjectsCannotExposeSelectableSources() throws {
        let ambiguous = [project("same", "First"), project("same", "Second")]
        let tasks = [task("bad", "Unavailable", project: "same"), task("missing", "Removed project", project: "gone"), task("inbox", "Keep me")]
        let catalog = try WorkflowSourceCatalog(kind: .task, projects: ambiguous, sections: [], tasks: tasks)
        XCTAssertEqual(catalog.options.map(\.id), ["inbox"])
        XCTAssertNil(WorkflowSourceCatalog.current("bad", kind: .task, projects: ambiguous, sections: [], tasks: tasks))
        XCTAssertNil(WorkflowSourceCatalog.current("missing", kind: .task, projects: [], sections: [], tasks: tasks))
        XCTAssertEqual(WorkflowSourceCatalog.current("inbox", kind: .task, projects: [], sections: [], tasks: tasks)?.id, "inbox")
    }
    func testSelectionRechecksRemovalAndDuplicateIdentity() throws {
        let projects = [project("p", "Project")], chosen = task("one", "Review", project: "p")
        let catalog = try WorkflowSourceCatalog(kind: .task, projects: projects, sections: [], tasks: [chosen])
        XCTAssertEqual(catalog.options.count, 1)
        XCTAssertNil(WorkflowSourceCatalog.current("one", kind: .task, projects: projects, sections: [], tasks: []))
        XCTAssertNil(WorkflowSourceCatalog.current("one", kind: .task, projects: projects, sections: [], tasks: [chosen, chosen]))
        XCTAssertTrue(try WorkflowSourceCatalog(kind: .task, projects: projects, sections: [], tasks: [chosen, chosen]).options.isEmpty)
        let section = Record(["id": .string("s"), "name": .string("Section"), "project_id": .string("p")])
        XCTAssertNil(WorkflowSourceCatalog.current("s", kind: .section, projects: [], sections: [section], tasks: []))
    }
    func testFiveThousandSourcesRemainReachableInBoundedPages() throws {
        let tasks = (0..<5000).map { task("task-\($0)", "Task \($0)") }
        let start = Date()
        let catalog = try WorkflowSourceCatalog(kind: .task, projects: [], sections: [], tasks: tasks)
        let built = Date()
        let first = catalog.page(query: ""), second = catalog.page(query: "", limit: 200)
        XCTAssertEqual(first.total, 5000); XCTAssertEqual(first.options.count, 100)
        XCTAssertEqual(second.options.count, 200); XCTAssertEqual(Array(second.options.prefix(100)), first.options)
        XCTAssertEqual(catalog.page(query: "4999").options.map(\.id), ["task-4999"])
        XCTAssertEqual(Set(catalog.page(query: "", limit: 5000).options.map(\.id)).count, 5000)
        XCTAssertEqual(catalog.page(query: "", limit: 0).options.count, 0)
        print("SOURCE_CATALOG_5000 build_ms=\(Int(built.timeIntervalSince(start)*1000)) search_checks_ms=\(Int(Date().timeIntervalSince(built)*1000))")
    }
    func testSearchUsesAllWordsAndLocalizedMatchingWithoutMutatingRows() throws {
        let projects = [project("p", "Studio")], tasks = [task("t", "Café review", project: "p")]
        let catalog = try WorkflowSourceCatalog(kind: .task, projects: projects, sections: [], tasks: tasks)
        XCTAssertEqual(catalog.page(query: "  CAFE   studio  ").options.map(\.id), ["t"])
        XCTAssertTrue(catalog.page(query: "no such source").options.isEmpty)
        XCTAssertEqual(tasks[0].title, "Café review")
        XCTAssertEqual(catalog.page(query: "cafe cafe").total, 1)
    }
    func testDamagedParentGraphsStayBoundedAndConstructionCanCancel() throws {
        let projects = [project("a", "A", parent: "b"), project("b", "B", parent: "a")]
        let catalog = try WorkflowSourceCatalog(kind: .project, projects: projects, sections: [], tasks: [])
        XCTAssertEqual(catalog.options.count, 2)
        XCTAssertTrue(catalog.options.allSatisfy { $0.location.count < 100 })
        XCTAssertThrowsError(try WorkflowSourceCatalog(kind: .project, projects: projects, sections: [], tasks: [], checkCancellation: { throw CancellationError() })) { XCTAssertTrue($0 is CancellationError) }
    }
    func testBackgroundConstructionMatchesSynchronousIndexAndHonorsCancellation() async throws {
        let tasks = (0..<5000).map { task("task-\($0)", "Task \($0)") }
        let index = try await WorkflowSourceCatalog.load(kind: .task, projects: [], sections: [], tasks: tasks)
        XCTAssertEqual(index.options.count, 5000)
        let work = Task { try await WorkflowSourceCatalog.load(kind: .task, projects: [], sections: [], tasks: tasks) }
        work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled source presentation should not be published") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
