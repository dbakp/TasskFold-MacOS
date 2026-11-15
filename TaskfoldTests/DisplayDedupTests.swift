import XCTest
@testable import TaskfoldCore

final class DisplayDedupTests: XCTestCase {
    func row(_ id: String, parent: String? = nil, order: Double? = nil, completed: Bool = false, due: String? = nil, heading: Bool = false) -> Record {
        var fields: [String: JSON] = ["id": .string(id), "title": .string("T-" + id), "completed": .bool(completed), "project_id": .string("p"), "user_id": .string("u")]
        if let parent { fields["parent_id"] = .string(parent) }
        if let order { fields["child_order"] = .number(order) }
        if let due { fields["due_date"] = .string(due) }
        if heading { fields["is_heading"] = .bool(true) }
        return Record(fields)
    }
    var rows: [Record] { [row("r1"), row("c1", parent: "r1", order: 1, due: "2026-11-16"), row("c2", parent: "r1", order: 2, completed: true), row("g1", parent: "c1", order: 1, due: "2026-11-17"), row("r2"), row("h", parent: "r2", order: 1, heading: true)] }

    func testOutlineNestsChildrenUnderRootsDepthFirst() {
        let outline = TaskTreeDisplay.outline(rows)
        XCTAssertEqual(outline.map(\.record.id), ["r1", "c1", "g1", "c2", "r2", "h"])
        XCTAssertEqual(outline.map(\.depth), [0, 1, 2, 1, 0, 1])
        XCTAssertEqual(outline.map(\.hasChildren), [true, true, false, false, true, false])
    }
    func testOutlineHidesCollapsedSubtreesAndCompletedRows() {
        let collapsed = TaskTreeDisplay.outline(rows, collapsed: ["R1"])
        XCTAssertEqual(collapsed.map(\.record.id), ["r1", "r2", "h"]); XCTAssertTrue(collapsed[0].isCollapsed)
        XCTAssertEqual(TaskTreeDisplay.outline(rows, includeCompleted: false).map(\.record.id), ["r1", "c1", "g1", "r2", "h"])
        XCTAssertFalse(TaskTreeDisplay.outline(rows, collapsed: ["c2"])[3].isCollapsed, "a leaf cannot collapse")
    }
    func testOutlineNeverShowsARowTwice() {
        let duplicated = rows + [row("c1", parent: "r1", order: 1), row("R1")]
        let ids = TaskTreeDisplay.outline(duplicated).map(\.record.id)
        XCTAssertEqual(ids.count, Set(ids.map { $0.lowercased() }).count)
        XCTAssertEqual(ids, ["r1", "c1", "g1", "c2", "r2", "h"])
    }
    func testOrphansAppearAtTheTopLevel() {
        let outline = TaskTreeDisplay.outline([row("a"), row("lost", parent: "gone", order: 1)])
        XCTAssertEqual(outline.map(\.depth), [0, 0])
    }
    func testFlatListsShowEveryDatedTaskOnceWithItsBreadcrumb() {
        let tree = TaskTree(rows)
        let matches = [rows[3], rows[1], rows[3], rows[0]]
        let flat = TaskTreeDisplay.flat(matches, tree: tree, datedOnly: true)
        XCTAssertEqual(flat.map(\.record.id), ["g1", "c1"])
        XCTAssertEqual(flat[0].breadcrumb.map(\.id), ["r1", "c1"]); XCTAssertEqual(flat[0].breadcrumbText, "T-r1 › T-c1")
        XCTAssertEqual(flat[0].parentLine, "↳ T-c1"); XCTAssertEqual(flat[1].parentLine, "↳ T-r1")
        let undated = TaskTreeDisplay.flat(rows, tree: tree)
        XCTAssertEqual(undated.count, 6); XCTAssertNil(undated[0].parentLine); XCTAssertEqual(undated[0].breadcrumbText, "")
    }
    func testFlatListKeepsAParentAndItsChildBothWhenBothMatch() {
        let flat = TaskTreeDisplay.flat([rows[0], rows[1]], tree: TaskTree(rows))
        XCTAssertEqual(flat.map(\.record.id), ["r1", "c1"])
    }
    func testDeduplicatedIsCaseInsensitiveAndKeepsTheFirst() {
        let list = TaskTreeDisplay.deduplicated([row("A"), row("a"), row("b"), Record(["title": .string("no id")])])
        XCTAssertEqual(list.map(\.id), ["A", "b"])
    }
    func testCountsIncludeSubtasksAndSeparateHeadings() {
        let counts = TaskTreeDisplay.counts(rows)
        XCTAssertEqual(counts, TaskTreeDisplay.Counts(open: 4, completed: 1, headings: 1))
        XCTAssertEqual(counts.total, 5)
        XCTAssertEqual(TaskTreeDisplay.counts(rows + rows).total, 5, "duplicates count once")
        let tree = TaskTree(rows)
        XCTAssertEqual(TaskTreeDisplay.openCount(under: "r1", tree: tree), 3); XCTAssertEqual(TaskTreeDisplay.openCount(under: "r2", tree: tree), 1)
        XCTAssertEqual(TaskTreeDisplay.openCount(under: "nope", tree: tree), 0)
    }
}
