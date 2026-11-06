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

final class TaskCacheRawSourceTests: XCTestCase {
    func testCanonicalTextEditUpdatesVisibleRowsInsteadOfReusingOldCache() {
        let cache = TaskCache()
        var row = Record(["id": .string("synthetic-output-row"), "title": .string("Café"), "description": .string("Résumé"), "completed": .bool(false), "priority": .number(4)])
        XCTAssertTrue(cache.update([row]))
        row["title"] = .string("Cafe\u{301}"); row["description"] = .string("Re\u{301}sume\u{301}")
        XCTAssertTrue(cache.update([row]), "Authored byte changes must invalidate cached projections")
        XCTAssertTrue(cache.tasks[0].title.utf8.elementsEqual(row.title.utf8))
        XCTAssertTrue(cache.tasks[0].string("description").utf8.elementsEqual(row.string("description").utf8))
        XCTAssertFalse(cache.update([row]), "Unchanged byte-exact refresh stays cached")
    }
}
