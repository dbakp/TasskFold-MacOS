import XCTest
@testable import TaskfoldCore

final class ProjectSectionTaskReadTests: XCTestCase {
    private func section(_ id: String, project: String = "studio", order: Int = 0) -> Record {
        Record(["id": .string(id), "project_id": .string(project), "name": .string("Section \(id)"), "order_index": .number(Double(order))])
    }
    private func task(_ id: String, section: JSON = .null) -> Record {
        Record(["id": .string(id), "title": .string(id), "section_id": section, "opaque": .object(["keep": .string("Café 🪴")])])
    }
    private func assertLegacy(_ read: ProjectSectionTaskRead, tasks: [Record], sections: [Record], project: String = "studio", file: StaticString = #filePath, line: UInt = #line) {
        let expected = OrganizationOrder.sorted(sections.filter { $0.string("project_id") == project })
        XCTAssertTrue(AuthoredValueComparison.sameRows(read.sections, expected), file: file, line: line)
        for id in [""] + expected.map(\.id) {
            XCTAssertTrue(AuthoredValueComparison.sameRows(read.tasks(in: id), tasks.filter { $0.string("section_id") == id }), id, file: file, line: line)
        }
    }
    func testSectionCatalogAndTaskOrderPreserveEmptyMissingForeignAndDuplicateRows() {
        let sections = [section("b", order: 2), section("a", order: 1), section("empty"), section("foreign", project: "other"), section("a", order: 3), section("", order: 4)]
        let rows = [task("loose"), task("one", section: .string("a")), task("duplicate", section: .string("b")), task("duplicate", section: .string("b")), task("unknown", section: .string("missing")), task("typed", section: .number(2))]
        let read = ProjectSectionTaskRead(project: "studio", sections: sections, tasks: rows)
        assertLegacy(read, tasks: rows, sections: sections)
        XCTAssertEqual(read.tasks(in: "b").map(\.id), ["duplicate", "duplicate"])
        XCTAssertEqual(read.tasks(in: "empty").count, 0)
        XCTAssertFalse(read.sections.contains { $0.id == "foreign" })
        XCTAssertFalse(read.tasks(in: "").contains { $0.id == "unknown" })
    }
    func testHeadingsCompletedChildReferencesAndOpaqueValuesStayExact() throws {
        var heading = task("heading", section: .string("a")); heading["is_heading"] = .bool(true)
        var child = task("subtask:root/child", section: .string("a")); child["future"] = try TaskfoldJSONDecoder().decode(JSON.self, from: Data("9007199254740993".utf8))
        var done = task("done", section: .string("b")); done["completed"] = .bool(true)
        let rows = [heading, child, done], sections = [section("a"), section("b")]
        let read = ProjectSectionTaskRead(project: "studio", sections: sections, tasks: rows)
        assertLegacy(read, tasks: rows, sections: sections)
        let ids = ["done", child.id, "heading"]
        for section in sections {
            XCTAssertTrue(AuthoredValueComparison.sameRows(DayPlacement.arrangedOutline(read.tasks(in: section.id), ids: ids), DayPlacement.arrangedOutline(rows.filter { $0.string("section_id") == section.id }, ids: ids)))
        }
    }
    func testFreshEditsMovesOrderingAndEmptyWorkspaceNeverMutateRetainedSnapshot() {
        var rows = [task("one", section: .string("a")), task("two", section: .string("b"))]
        var sections = [section("a", order: 1), section("b", order: 2)]
        let original = ProjectSectionTaskRead(project: "studio", sections: sections, tasks: rows)
        rows[0]["section_id"] = .string("b"); rows[0]["title"] = .string("Edited")
        sections[0]["order_index"] = .number(3)
        let edited = ProjectSectionTaskRead(project: "studio", sections: sections, tasks: rows)
        assertLegacy(edited, tasks: rows, sections: sections)
        XCTAssertEqual(edited.sections.map(\.id), ["b", "a"])
        XCTAssertEqual(edited.tasks(in: "b").map(\.title), ["Edited", "two"])
        XCTAssertEqual(original.sections.map(\.id), ["a", "b"])
        XCTAssertEqual(original.tasks(in: "a").map(\.title), ["one"])
        let empty = ProjectSectionTaskRead(project: "studio", sections: [], tasks: [])
        XCTAssertTrue(empty.sections.isEmpty); XCTAssertTrue(empty.tasks(in: "a").isEmpty)
    }
    func testProjectSectionPreparationMeasurementWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["TASKFOLD_SECTION_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in same-host section read; not native FPS") }
        let sections = (0..<80).map { section("s-\($0)", order: 80 - $0) }
        let rows = (0..<4000).map { task("work-\($0)", section: .string("s-\($0 % 80)")) }
        var legacy: [Double] = [], singlePass: [Double] = []
        func milliseconds(_ start: ContinuousClock.Instant) -> Double {
            let c = start.duration(to: .now).components
            return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
        }
        for _ in 0..<3 {
            let oldStart = ContinuousClock.now
            let oldSections = OrganizationOrder.sorted(sections.filter { $0.string("project_id") == "studio" })
            let old = [rows.filter { $0.string("section_id").isEmpty }] + oldSections.map { section in rows.filter { $0.string("section_id") == section.id } }
            legacy.append(milliseconds(oldStart))
            let newStart = ContinuousClock.now
            let read = ProjectSectionTaskRead(project: "studio", sections: sections, tasks: rows)
            let fresh = [read.tasks(in: "")] + read.sections.map { read.tasks(in: $0.id) }
            singlePass.append(milliseconds(newStart))
            XCTAssertEqual(old.count, fresh.count)
            for (a, b) in zip(old, fresh) { XCTAssertTrue(AuthoredValueComparison.sameRows(a, b)) }
        }
        let proof: [String: Any] = ["taskCount": rows.count, "sectionCount": sections.count, "legacyMilliseconds": legacy, "singlePassMilliseconds": singlePass, "legacyMedian": legacy.sorted()[1], "singlePassMedian": singlePass.sorted()[1], "exactGroupsEqual": true, "sameHostDebugOnly": true, "physicalFPSClaim": false]
        print("TASKFOLD_SECTION_MEASUREMENT " + String(data: try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
