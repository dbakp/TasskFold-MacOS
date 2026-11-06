import XCTest
@testable import TaskfoldCore

final class PrintDocumentSourceTests: XCTestCase {
    func testCanonicallyEquivalentTextEditInvalidatesCapturedOutput() throws {
        let composed = "Café", edited = "Cafe\u{301}"
        XCTAssertEqual(composed, edited)
        let base = PrintDocument(title: composed, subtitle: composed, groups: [.init(title: composed, items: [
            .init(sourceID: composed, title: composed, metadata: composed, notes: composed, completed: false, depth: 0)
        ])], noteOnly: false, hierarchyResults: false)
        func changed(_ index: Int) -> PrintDocument {
            .init(title: index == 0 ? edited : composed, subtitle: index == 1 ? edited : composed,
                  groups: [.init(title: index == 2 ? edited : composed, items: [
                    .init(sourceID: index == 3 ? edited : composed, title: index == 4 ? edited : composed,
                          metadata: index == 5 ? edited : composed, notes: index == 6 ? edited : composed, completed: false, depth: 0)
                  ])], noteOnly: false, hierarchyResults: false)
        }
        for index in 0...6 { XCTAssertNotEqual(base, changed(index), "Exact reviewed text field \(index) changed") }
    }
}

extension PrintDocumentSourceTests {
    func testCSVContextAndOpaqueValuesKeepExactAuthoredSpelling() {
        let original = "Café", edited = "Cafe\u{301}"
        let base = PrintDocument.CSVSource(values: ["title": .string(original)], project: original, labels: [original], assignee: original, parentPath: original, parentSource: original, readable: true)
        var next = base; XCTAssertEqual(base, next)
        next.project = edited; XCTAssertNotEqual(base, next)
        next = base; next.labels = [edited]; XCTAssertNotEqual(base, next)
        next = base; next.assignee = edited; XCTAssertNotEqual(base, next)
        next = base; next.parentPath = edited; XCTAssertNotEqual(base, next)
        next = base; next.parentSource = edited; XCTAssertNotEqual(base, next)
        next = base; next.values["title"] = .string(edited); XCTAssertNotEqual(base, next)
        next = base; next.values = [edited: .array([.object(["keep": .string(original)])])]
        var other = next; other.values = [original: .array([.object(["keep": .string(original)])])]
        XCTAssertNotEqual(next, other)
        other = next; other.values = [edited: .array([.object(["keep": .string(edited)])])]
        XCTAssertNotEqual(next, other)
    }
    func testPinnedRecordSourceRefusesRawEditsAndMissingOrReplacedValues() {
        let original = Record(["title": .string("Café"), "opaque": .object(["Café": .number(-0.0)])])
        XCTAssertTrue(PrintDocument.matchesSource(original, original)); XCTAssertFalse(PrintDocument.matchesSource(nil, original))
        var edited = original; edited["title"] = .string("Cafe\u{301}")
        XCTAssertEqual(edited, original); XCTAssertFalse(PrintDocument.matchesSource(edited, original))
        edited = original; edited["opaque"] = .object(["Cafe\u{301}": .number(-0.0)])
        XCTAssertFalse(PrintDocument.matchesSource(edited, original))
        edited = original; edited["opaque"] = .object(["Café": .number(0.0)])
        XCTAssertFalse(PrintDocument.matchesSource(edited, original))
        edited = Record(["opaque": original["opaque"], "title": original["title"]])
        XCTAssertTrue(PrintDocument.matchesSource(edited, original), "Object insertion order is not authored content")
    }
    func testDeepOpaqueSourceComparisonDoesNotAddRecursiveStackDepth() {
        var a = JSON.string("Café"), b = JSON.string("Cafe\u{301}")
        for _ in 0..<4_096 { a = .array([a]); b = .array([b]) }
        let original = Record(["opaque": a])
        XCTAssertTrue(PrintDocument.matchesSource(original, original))
        XCTAssertFalse(PrintDocument.matchesSource(Record(["opaque": b]), original))
    }
}

final class TaskCacheRawSourceTests: XCTestCase {
    func testCanonicalTextEditUpdatesVisibleRowsInsteadOfReusingOldCache() {
        let cache = TaskCache()
        var row = Record(["id": .string("synthetic-output-row"), "title": .string("Café"), "description": .string("Résumé"), "completed": .bool(false), "priority": .number(4)])
        XCTAssertTrue(cache.update([row]))
        let query = TaskQuery(scope: .inbox)
        XCTAssertEqual(cache.matching(query).count, 1); XCTAssertEqual(cache.computationCount, 1)
        row["title"] = .string("Cafe\u{301}"); row["description"] = .string("Re\u{301}sume\u{301}")
        XCTAssertTrue(cache.update([row]), "Authored byte changes must invalidate cached projections")
        XCTAssertTrue(cache.tasks[0].title.utf8.elementsEqual(row.title.utf8))
        XCTAssertTrue(cache.tasks[0].string("description").utf8.elementsEqual(row.string("description").utf8))
        XCTAssertTrue(cache.matching(query)[0].title.utf8.elementsEqual(row.title.utf8))
        XCTAssertEqual(cache.computationCount, 2)
        XCTAssertFalse(cache.update([row]), "Unchanged byte-exact refresh stays cached")
        _ = cache.matching(query); XCTAssertEqual(cache.computationCount, 2)
    }
}
