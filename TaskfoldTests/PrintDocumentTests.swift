import XCTest
import PDFKit
@testable import TaskfoldCore

final class PrintDocumentTests: XCTestCase {
    private func task(_ id: String, _ title: String, notes: String = "") -> Record {
        Record(["id": .string(id), "title": .string(title), "description": .string(notes), "priority": .number(4)])
    }
    func testCapturePreservesGroupingOrderMetadataAndUniqueCountWithoutPrivateFields() throws {
        var first = task("private-record-one", "First", notes: "**Keep** the original")
        first["assigned_to"] = .string("private-collaborator"); first["project_id"] = .string("project"); first["due_date"] = .string("2026-10-21"); first["due_time"] = .string("14:30"); first["time_zone"] = .string("Europe/Copenhagen")
        first["deadline_date"] = .string("2026-10-22"); first["duration_minutes"] = .number(25); first["priority"] = .number(1); first["labels"] = .array([.string("label")])
        first["comments"] = .array([.object(["text": .string("Never print this discussion")])]); first["user_id"] = .string("private-account")
        let before = first
        let result = try PrintDocument.capture(title: "Review", subtitle: "Filtered", groups: [("Design", [first, task("two", "Second")]), ("Overlapping query", [first])], projects: [Record(["id": .string("project"), "name": .string("Launch")])], labels: [Record(["id": .string("label"), "name": .string("Studio")])], assigneeName: { _ in "Sam" })
        XCTAssertEqual(result.groups.map(\.title), ["Design", "Overlapping query"])
        XCTAssertEqual(result.groups[0].items.map(\.title), ["First", "Second"]); XCTAssertEqual(result.count, 2)
        let item = result.groups[0].items[0]
        for text in ["Launch", "P1", "Due 2026-10-21 14:30 Europe/Copenhagen", "Deadline 2026-10-22", "25 min", "@Studio", "Assigned to Sam"] { XCTAssertTrue(item.metadata.contains(text), text) }
        XCTAssertEqual(item.notes, "**Keep** the original"); XCTAssertEqual(first, before)
        let pdf = try TaskPrintRenderer.render(result)
        let read = try XCTUnwrap(PDFDocument(data: pdf.data)?.string)
        XCTAssertFalse(read.contains("private-record")); XCTAssertFalse(read.contains("private-account")); XCTAssertFalse(read.contains("Never print this discussion"))
    }
    func testChecklistsAreCompleteOrderedAndOptionalAndPinnedNotePrintsOnlyItsOwnText() throws {
        var parent = task("p", "Parent", notes: "Parent note")
        parent["subtasks"] = .array([.object(["id": .string("c"), "title": .string("Child"), "description": .string("Child note"), "completed": .bool(true), "subtasks": .array([.object(["id": .string("g"), "title": .string("Grandchild")])])])])
        let doc = try PrintDocument.capture(title: "Checklist", subtitle: "", groups: [("", [parent])], projects: [], labels: [])
        XCTAssertEqual(doc.groups[0].items.map(\.depth), [0, 1, 2]); XCTAssertTrue(doc.groups[0].items[1].completed)
        let full = try XCTUnwrap(PDFDocument(data: TaskPrintRenderer.render(doc).data)?.string)
        for text in ["Parent", "Child", "Grandchild", "Child note"] { XCTAssertTrue(full.contains(text), text) }
        let compact = try XCTUnwrap(PDFDocument(data: TaskPrintRenderer.render(doc, options: .init(notes: false, checklists: false)).data)?.string)
        XCTAssertFalse(compact.contains("Parent note")); XCTAssertFalse(compact.contains("Child"))
        let note = try PrintDocument.capture(title: "Pinned", subtitle: "Note", groups: [("", [parent])], projects: [], labels: [], noteOnly: true)
        XCTAssertEqual(note.groups[0].items.count, 1)
        let noteText = try XCTUnwrap(PDFDocument(data: TaskPrintRenderer.render(note).data)?.string)
        XCTAssertTrue(noteText.contains("Parent note")); XCTAssertFalse(noteText.contains("Child note"))
    }
    func testUnsupportedAndExcessivelyDeepChecklistsRefuseInsteadOfSilentlyDroppingContent() {
        var invalid = task("one", "Invalid"); invalid["subtasks"] = .object(["unknown": .bool(true)])
        XCTAssertThrowsError(try PrintDocument.capture(title: "", subtitle: "", groups: [("", [invalid])], projects: [], labels: []))
        var nested: JSON = .object(["id": .string("leaf"), "title": .string("Final leaf")])
        for index in 0...SubtaskTree.readableDepth { nested = .object(["id": .string("level-\(index)"), "title": .string("Nested"), "subtasks": .array([nested])]) }
        var deep = task("root", "Deep"); deep["subtasks"] = .array([nested])
        XCTAssertThrowsError(try PrintDocument.capture(title: "", subtitle: "", groups: [("", [deep])], projects: [], labels: []))
    }
    func testLargeSelectionRefusesWithNoPartialExport() {
        let huge = task("huge", "Huge", notes: String(repeating: "a", count: 16_000_001))
        XCTAssertThrowsError(try PrintDocument.capture(title: "Review", subtitle: "", groups: [("", [huge])], projects: [], labels: []))
        let many = (0...10_000).map { task("\($0)", "Task") }
        XCTAssertThrowsError(try PrintDocument.capture(title: "Review", subtitle: "", groups: [("", many)], projects: [], labels: []))
    }
    func testLongUnicodeAndCodePaginateCompletelyOnBothPaperSizes() throws {
        let body = (1...36).map { index in
            "## Section \(index)\nParagraph \(index): Résumé, København, 東京, العربية, 🙂. Keep **important words** and _gentle emphasis_. A useful [reference](https://example.com/guide) stays readable in print.\n- Review all edges\n- Preserve the complete instructions\n```text\nLiteral **code** \(index)\n```"
        }.joined(separator: "\n\n") + "\nLAST-INSTRUCTION-SENTINEL"
        let doc = try PrintDocument.capture(title: "Design workshop", subtitle: "A complete, portable review", groups: [("Design review", [task("one", "Prepare the design review", notes: body)]), ("Ready to ship", [task("two", "Publish the design", notes: "FINAL-TASK-SENTINEL")])], projects: [], labels: [])
        for paper in TaskPrintRenderer.Paper.allCases {
            let output = try TaskPrintRenderer.render(doc, options: .init(paper: paper))
            let pdf = try XCTUnwrap(PDFDocument(data: output.data)), text = pdf.string ?? ""
            XCTAssertGreaterThan(output.pages, 2); XCTAssertEqual(pdf.pageCount, output.pages)
            XCTAssertTrue(text.contains("LAST-INSTRUCTION-SENTINEL")); XCTAssertTrue(text.contains("FINAL-TASK-SENTINEL"))
            for index in 1...36 { XCTAssertTrue(text.contains("Section \(index)"), "Missing section \(index) on \(paper)") }
            XCTAssertTrue(text.contains("العربية"), "Arabic text must remain selectable as authored"); XCTAssertTrue(text.contains("🙂")); XCTAssertTrue(text.contains("København")); XCTAssertTrue(text.contains("東京")); XCTAssertTrue(text.contains("https://example.com/guide"))
            for index in 0..<pdf.pageCount {
                let page = try XCTUnwrap(pdf.page(at: index))
                XCTAssertEqual(page.bounds(for: .mediaBox).width, paper.size.width, accuracy: 0.1)
                XCTAssertTrue((page.string ?? "").contains("Page \(index + 1) of \(pdf.pageCount)"))
                XCTAssertTrue(page.annotations.isEmpty)
                let contentLines = (page.string ?? "").components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("Page ") }
                XCTAssertFalse(contentLines.last?.hasPrefix("Section ") == true, "A note heading must not be orphaned at a page end")
            }
            if let path = ProcessInfo.processInfo.environment["TASKFOLD_PDF_QA_DIRECTORY"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try output.data.write(to: directory.appendingPathComponent("taskfold-review-" + paper.nameForTest + ".pdf"), options: .atomic)
            }
        }
    }
    func testOneLongParagraphSplitsWithoutLosingTheEnd() throws {
        let raw = String(repeating: "Every instruction remains readable across page boundaries. ", count: 500) + "LONG-PARAGRAPH-FINAL-SENTINEL"
        let doc = try PrintDocument.capture(title: "Long paragraph", subtitle: "", groups: [("", [task("one", "Read completely", notes: raw)])], projects: [], labels: [])
        let output = try TaskPrintRenderer.render(doc)
        XCTAssertGreaterThan(output.pages, 2)
        let text = try XCTUnwrap(PDFDocument(data: output.data)?.string)
        XCTAssertTrue(text.contains("LONG-PARAGRAPH-FINAL-SENTINEL"))
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        // PDF extraction inserts line/page breaks between words. Verify every
        // source word, without treating those physical breaks as missing text.
        for word in ["Every", "instruction", "remains", "readable", "across", "page", "boundaries."] { XCTAssertEqual(words.filter { $0 == word }.count, 500, word) }
    }
    func testPageLimitRefusesWithoutCreatingAPartialDocument() throws {
        let raw = String(repeating: "A complete instruction that must never be silently lost.\n", count: 25_000)
        let doc = try PrintDocument.capture(title: "Too many pages", subtitle: "", groups: [("", [task("one", "Keep all content", notes: raw)])], projects: [], labels: [])
        XCTAssertThrowsError(try TaskPrintRenderer.render(doc)) { XCTAssertTrue($0.localizedDescription.contains("500 pages"), $0.localizedDescription) }
    }
    func testEmptyViewStillProducesAnHonestPage() throws {
        let doc = try PrintDocument.capture(title: "Inbox", subtitle: "Current filters", groups: [], projects: [], labels: [])
        let output = try TaskPrintRenderer.render(doc)
        XCTAssertEqual(output.pages, 1); XCTAssertTrue(PDFDocument(data: output.data)?.string?.contains("No matching tasks") == true)
    }
}
private extension TaskPrintRenderer.Paper { var nameForTest: String { self == .a4 ? "a4" : "letter" } }

extension PrintDocumentTests {
    private func hierarchyFixture() throws -> (Record, [Record], [Record]) {
        let leaf: JSON = .object(["id": .string("leaf"), "title": .string("Approve contrast"), "description": .string("Check **contrast**, keyboard focus and legible task titles."), "priority": .number(1), "completed": .bool(false)])
        let nested: JSON = .object(["id": .string("branch"), "title": .string("Design review"), "subtasks": .array([leaf])])
        var root = task("root", "Prepare release"); root["project_id"] = .string("p"); root["task_generation"] = .string("generation"); root["subtasks"] = .array([nested, .object(["id": .string("hidden"), "title": .string("UNMATCHED-TASK-SENTINEL")])])
        let projects = [Record(["id": .string("p"), "name": .string("Widget workshop")])]
        let index = try TaskHierarchyIndex(roots: [root], projects: projects, workspace: WorkspaceBinding(account: "test", generation: UUID()))
        return (root, index.items.filter(\.isSubtask).map(\.record), projects)
    }
    func testHierarchyPrintAddsAncestorsAndDoesNotExpandUnmatchedChildren() throws {
        let (root, children, projects) = try hierarchyFixture(), selected = children.filter { ["Design review", "Approve contrast"].contains($0.title) }
        let document = try PrintDocument.capture(title: "Design review", subtitle: "Current filtered results", groups: [("Review", selected), ("Main task", [root])], projects: projects, labels: [], hierarchyRoots: [root])
        XCTAssertTrue(document.hierarchyResults)
        XCTAssertEqual(document.count, 3); XCTAssertEqual(document.groups[0].items.map(\.depth), [0, 0]); XCTAssertEqual(document.groups[1].items.count, 1)
        XCTAssertTrue(document.groups[0].items[1].metadata.contains("Subtask of Prepare release › Design review"))
        for paper in TaskPrintRenderer.Paper.allCases {
            let output = try TaskPrintRenderer.render(document, options: .init(paper: paper))
            let text = try XCTUnwrap(PDFDocument(data: output.data)?.string)
            XCTAssertTrue(text.contains("Subtask of Prepare release")); XCTAssertTrue(text.contains("Approve contrast")); XCTAssertFalse(text.contains("UNMATCHED-TASK-SENTINEL"))
            if let directory = ProcessInfo.processInfo.environment["TASKFOLD_HIERARCHY_PDF_DIR"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try output.data.write(to: folder.appendingPathComponent(paper == .a4 ? "hierarchy-a4.pdf" : "hierarchy-letter.pdf"))
            }
        }
    }
    func testHierarchyPrintRefusesStaleMovedMissingAndMalformedReferences() throws {
        let (root, children, projects) = try hierarchyFixture(); let selected = children.filter { $0.title == "Approve contrast" }
        var changed = root; changed["task_generation"] = .string("replaced")
        for roots in [[], [changed]] {
            XCTAssertThrowsError(try PrintDocument.capture(title: "Review", subtitle: "", groups: [("", selected)], projects: projects, labels: [], hierarchyRoots: roots))
        }
        var stale = selected[0]; stale["title"] = .string("Old title")
        XCTAssertThrowsError(try PrintDocument.capture(title: "", subtitle: "", groups: [("", [stale])], projects: projects, labels: [], hierarchyRoots: [root]))
        var malformed = selected[0]; malformed["id"] = .string("subtask:invalid")
        XCTAssertThrowsError(try PrintDocument.capture(title: "", subtitle: "", groups: [("", [malformed])], projects: projects, labels: [], hierarchyRoots: [root]))
        XCTAssertThrowsError(try PrintDocument.capture(title: "", subtitle: "", groups: [("", selected)], projects: [], labels: [], hierarchyRoots: [root]))
    }
}
