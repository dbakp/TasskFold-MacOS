import XCTest
import PDFKit
@testable import TaskfoldCore

final class PrintHierarchyRawSourceTests: XCTestCase {
    private func root() -> Record {
        Record(["id": .string("root"), "title": .string("Café"), "description": .string("Résumé"),
                "opaque": .object(["Café": .number(-0.0)]), "priority": .number(4),
                "subtasks": .array([.object(["id": .string("child"), "title": .string("Café"),
                    "description": .string("Résumé"), "completed": .bool(false),
                    "opaque": .object(["Café": .number(-0.0)])])])])
    }
    private func children(_ root: Record) throws -> [Record] {
        let index = try TaskHierarchyIndex(roots: [root], projects: [], workspace: WorkspaceBinding(account: "print-test", generation: UUID()))
        return index.items.filter(\.isSubtask).map(\.record)
    }
    private func capture(_ shown: Record, _ live: Record) throws -> PrintDocument {
        try PrintDocument.capture(title: "Current filtered results", subtitle: "", groups: [("Matches", [shown])], projects: [], labels: [], hierarchyRoots: [live])
    }
    private func rawEdits(_ original: Record) -> [Record] {
        var title = original; title["title"] = .string("Cafe\u{301}")
        var notes = original; notes["description"] = .string("Re\u{301}sume\u{301}")
        var key = original; key["opaque"] = .object(["Cafe\u{301}": .number(-0.0)])
        var number = original; number["opaque"] = .object(["Café": .number(0.0)])
        return [title,notes,key,number]
    }
    func testRootFilteredOutputRefusesEveryRawSourceChangeBeforeRendering() throws {
        let original = root()
        XCTAssertNoThrow(try capture(original, original))
        for edited in rawEdits(original) {
            XCTAssertEqual(edited,original,"This regression requires a change hidden by semantic Record equality")
            XCTAssertThrowsError(try capture(original, edited), "A stale selection must require refresh")
            XCTAssertThrowsError(try capture(edited, original), "A changed displayed row must not impersonate the live row")
        }
    }
    func testChildFilteredOutputRefusesEveryRawSourceChangeBeforeRendering() throws {
        let original = root(), shown = try XCTUnwrap(children(original).first)
        for edited in rawEdits(shown) {
            XCTAssertEqual(edited,shown)
            XCTAssertThrowsError(try capture(edited, original), "A child with changed raw fields must require refresh")
        }
        var live = original
        if case .array(var rows) = live["subtasks"], case .object(var fields) = rows[0] {
            fields["title"] = .string("Cafe\u{301}"); rows[0] = .object(fields); live["subtasks"] = .array(rows)
        }
        XCTAssertThrowsError(try capture(shown,live),"A stale child cannot be exported after its source changed")
    }
    func testRefreshedRootAndChildExportCurrentSpellingAndKeepReadablePDF() throws {
        var live = root(); live["title"] = .string("Cafe\u{301}")
        if case .array(var rows) = live["subtasks"], case .object(var fields) = rows[0] {
            fields["title"] = .string("Cafe\u{301}"); fields["description"] = .string("Re\u{301}sume\u{301}")
            rows[0] = .object(fields); live["subtasks"] = .array(rows)
        }
        let child = try XCTUnwrap(children(live).first)
        for shown in [live,child] {
            let document = try capture(shown,live), item = try XCTUnwrap(document.groups.first?.items.first)
            XCTAssertTrue(item.title.utf8.elementsEqual(shown.title.utf8))
            XCTAssertTrue(item.notes.utf8.elementsEqual(shown.string("description").utf8))
            let csv = try TaskRowCSV.make(document)
            XCTAssertNotNil(csv.data.range(of: Data(shown.title.utf8)), "CSV must retain refreshed authored bytes")
            let pdf = try TaskPrintRenderer.render(document)
            XCTAssertGreaterThan(pdf.pages,0)
            XCTAssertTrue(try XCTUnwrap(PDFDocument(data:pdf.data)?.string).contains("Café"))
        }
        // Dictionary insertion order is not a source edit.
        let reordered = Record(Dictionary(uniqueKeysWithValues:live.fields.sorted{$0.key > $1.key}))
        XCTAssertNoThrow(try capture(reordered,live))
    }
}
