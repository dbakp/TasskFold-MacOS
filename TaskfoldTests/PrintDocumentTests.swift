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


final class TaskRowCSVTests: XCTestCase {
    func task(_ id: String, _ title: String, notes: String = "") -> Record {
        Record(["id": .string(id), "title": .string(title), "description": .string(notes), "priority": .number(4), "completed": .bool(false), "labels": .array([]), "subtasks": .array([])])
    }
    func doc(_ tasks: [Record], projects: [Record] = [], labels: [Record] = []) throws -> PrintDocument {
        try PrintDocument.capture(title: "Review", subtitle: "", groups: [("Work",tasks)], projects: projects, labels: labels, assigneeName: { _ in "Sam" })
    }

    func testDatedHeadingContextCountsAsARowAndNestedPathsRetainItsTitle() throws {
        var child = task("child","First"), second = task("second","Second"), root = task("root","Context")
        child["due_date"] = .string("2026-10-26"); second["due_date"] = .string("2026-10-26")
        child["subtasks"] = .array([.object(task("detail","Checklist").fields)])
        root["is_heading"] = .bool(true); root["due_date"] = .string("2026-10-26"); root["subtasks"] = .array([.object(child.fields),.object(second.fields)])
        let cache = TaskCache(); cache.update([root])
        let shown = cache.matching(TaskQuery(scope:.today,today:"2026-10-26"))
        XCTAssertEqual(shown.count,3); XCTAssertEqual(shown.filter{TaskKind.mayComplete($0)}.count,2)
        let captured = try PrintDocument.capture(title:"Today",subtitle:"",groups:[("Today",shown)],projects:[],labels:[],hierarchyRoots:[root],expandOrdinaryChecklists:true)
        let full = try TaskRowCSV.make(captured); XCTAssertEqual(full.rows.count,4)
        XCTAssertEqual(try TaskRowCSV.make(captured,options:.init(checklists:false)).rows.count,3)
        XCTAssertEqual(full.rows.first{$0[6]=="Checklist"}?[4],"Context › First")
    }
    func testArchivedProjectIsReadableForExportWithoutRestoringOrMutatingIt() throws {
        var root = task("root","Archived work"); root["project_id"] = .string("project")
        let project = Record(["id":.string("project"),"name":.string("Saved project"),"is_archived":.bool(true)])
        let captured = try PrintDocument.capture(title:"Saved project",subtitle:"Archived",groups:[("Tasks",[root])],projects:[project],labels:[],hierarchyRoots:[root])
        let file = try TaskRowCSV.make(captured)
        XCTAssertEqual(file.rows.count,1); XCTAssertEqual(file.rows[0][9],"Saved project")
        XCTAssertEqual(project["is_archived"],.bool(true)); XCTAssertEqual(root["project_id"],.string("project"))
    }
    func testStructuredFieldsAndStatusExportWithoutLiveIdentifiersOrPrivatePayloads() throws {
        var row = task("private-task", "Review", notes: "Keep **all** notes")
        for (key,value) in ["user_id":"private-user","task_generation":"private-generation","project_id":"private-project","assigned_to":"private-person","due_date":"2026-10-26","due_time":"09:00","time_zone":"Europe/Copenhagen","scheduled_at":"2026-10-26T08:00:00Z","deadline_date":"2026-10-28"] { row[key] = .string(value) }
        row["completed"] = .bool(true); row["duration_minutes"] = .number(45); row["labels"] = .array([.string("private-label")]); row["comments"] = .array([.string("PRIVATE-DISCUSSION")]); row["attachments"] = .array([.string("PRIVATE-ATTACHMENT")])
        let before = row, output = try TaskRowCSV.make(doc([row], projects: [Record(["id":.string("private-project"),"name":.string("Studio")])], labels: [Record(["id":.string("private-label"),"name":.string("Design")])]))
        let cells = output.rows[0], raw = String(decoding: output.data, as: UTF8.self)
        XCTAssertEqual(cells[8], "true"); XCTAssertEqual(cells[9], "Studio"); XCTAssertEqual(cells[11], "2026-10-26"); XCTAssertEqual(cells[14], "2026-10-26T08:00:00Z"); XCTAssertEqual(cells[16], "45"); XCTAssertEqual(cells[18], "Sam")
        for secret in ["private-task","private-user","private-generation","private-project","private-person","private-label","PRIVATE-DISCUSSION","PRIVATE-ATTACHMENT"] { XCTAssertFalse(raw.contains(secret), secret) }
        XCTAssertEqual(row, before); XCTAssertEqual(try WorkflowTemplateCSV.rows(output.data).first, TaskRowCSVFormat.columns)
    }
    func testHierarchyReferencesAreScopedToPositionsEvenWhenLegacyChildKeysRepeat() throws {
        var a = task("a", "First"), b = task("b", "Second")
        let child = task("same", "Checklist"); a["subtasks"] = .array([.object(child.fields)]); b["subtasks"] = a["subtasks"]
        let output = try TaskRowCSV.make(doc([a,b]))
        XCTAssertEqual(output.rows.map { $0[1] }, ["row-1","row-2","row-3","row-4"])
        XCTAssertEqual(output.rows.map { $0[2] }, ["","row-1","","row-3"])
        XCTAssertEqual(output.rows.map { $0[4] }, ["","First","","Second"])
    }
    func testExplicitNotesAndChecklistExclusionsRemoveTheirActualContent() throws {
        var row = task("root", "Parent", notes: "SECRET-PARENT-NOTES")
        row["subtasks"] = .array([.object(task("child", "SECRET-CHILD-TITLE", notes: "SECRET-CHILD-NOTES").fields)])
        let output = try TaskRowCSV.make(doc([row]), options: .init(notes:false,checklists:false))
        XCTAssertEqual(output.rows.count,1); XCTAssertEqual(output.rows[0][7], "")
        XCTAssertFalse(String(decoding:output.data,as:UTF8.self).contains("SECRET"))
    }
    func testSpreadsheetProtectionIsReversibleOnlyForTheRecognizedTransport() throws {
        for value in ["=SUM(A1:A2)","  @formula","'literal","'=literal","First, \"quoted\"\r\nSecond 👩🏽‍💻"] {
            let output = try TaskRowCSV.make(doc([task("root",value,notes:value)]))
            XCTAssertEqual(try WorkflowTemplateCSV.rows(output.data)[1][6],WorkflowTemplateCSV.escape(value))
            let source = try WorkflowCSVSource(data: output.data)
            XCTAssertEqual(source.records[0][6],value); XCTAssertEqual(source.records[0][7],value)
        }
        let generic = try WorkflowCSVSource(data: Data("Title\n'=literal".utf8))
        XCTAssertEqual(generic.records[0][0],"'=literal")
    }
    func testCanonicalLabelArraysPreserveSemicolonsBackslashesAndLiteralWhitespace() throws {
        var row = task("root", "Labels")
        row["labels"] = .array([.object(["name":.string("Design; Review")]),.object(["name":.string("Path\\Name")]),.object(["name":.string(" Spaced ")])])
        let output = try TaskRowCSV.make(doc([row])), source = try WorkflowCSVSource(data:output.data)
        var mapping = WorkflowCSVMapping(); mapping.columns = [.title:6,.labels:17]
        let template = try source.template(name:"Workflow",mapping:mapping,anchor:Date(),headings:false)
        XCTAssertEqual(template.template.tasks[0]["labels"].list.map{$0.object["name"]?.text},["Design; Review","Path\\Name"," Spaced "])
    }
    func testHeadingsAndChildrenRoundtripAsFreshReviewedWorkflowWithoutCompletionHistory() throws {
        var root = task("private-root", "Context"), child = task("private-child", "Action")
        root["is_heading"] = .bool(true); child["completed"] = .bool(true); root["subtasks"] = .array([.object(child.fields)])
        let source = try WorkflowCSVSource(data: TaskRowCSV.make(doc([root])).data)
        var mapping = WorkflowCSVMapping(); mapping.columns = [.identifier:1,.parent:2,.type:5,.title:6,.notes:7,.labels:17]
        let file = try source.template(name:"Reusable",mapping:mapping,anchor:Date(),headings:true)
        XCTAssertEqual(TaskKind(file.template.tasks[0]),.heading)
        XCTAssertEqual(file.template.tasks[0]["subtasks"].list[0].object["title"],.string("Action"))
        XCTAssertNil(file.template.tasks[0]["subtasks"].list[0].object["completed"])
        XCTAssertThrowsError(try source.template(name:"Reusable",mapping:mapping,anchor:Date(),headings:false))
    }
    func testFilteredChildKeepsParentContextWithoutInventingNonmatchingRows() throws {
        var root = task("root","Parent"); root["subtasks"] = .array([.object(task("leaf","Match").fields)])
        let binding = WorkspaceBinding(account:"print-review",generation:UUID())
        let index = try TaskHierarchyIndex(roots:[root],projects:[],workspace:binding)
        let reference = SubtaskTree.reference(parent:root.id,key:"leaf"), child = try XCTUnwrap(index.item(reference)?.record)
        let capture = try PrintDocument.capture(title:"Filtered",subtitle:"",groups:[("Matches",[child])],projects:[],labels:[],hierarchyRoots:[root])
        let rows = try TaskRowCSV.make(capture).rows
        XCTAssertEqual(rows.count,1); XCTAssertEqual(rows[0][2],""); XCTAssertEqual(rows[0][4],"Parent"); XCTAssertEqual(rows[0][6],"Match")
    }
    func testVisibleHeadingAndProjectedChildResolveLocalParentReference() throws {
        var root = task("root","Context"); root["is_heading"] = .bool(true); root["subtasks"] = .array([.object(task("child","Action").fields)])
        let work = ProductiveTaskReading(tasks:[root])
        let capture = try PrintDocument.capture(title:"Project",subtitle:"",groups:[("Work",work.presentation)],projects:[],labels:[],hierarchyRoots:[root],expandOrdinaryChecklists:true)
        let output = try TaskRowCSV.make(capture), heading = try XCTUnwrap(output.rows.first{$0[5]=="heading"}), child = try XCTUnwrap(output.rows.first{$0[6]=="Action"})
        XCTAssertEqual(child[2],heading[1]); XCTAssertEqual(output.rows.count,2)
    }
    func testRepeatedQueryGroupsKeepSeparateRowsAndReferences() throws {
        let row = task("same","Task")
        let capture = try PrintDocument.capture(title:"Queries",subtitle:"",groups:[("First",[row]),("Second",[row])],projects:[],labels:[])
        let output = try TaskRowCSV.make(capture)
        XCTAssertEqual(output.rows.map{$0[3]},["First","Second"]); XCTAssertEqual(Set(output.rows.map{$0[1]}).count,2)
    }
    func testUnknownMetadataRefusesCSVWithoutBreakingReadablePDF() throws {
        var row = task("root","Keep work"); row["priority"] = .string("future")
        let capture = try doc([row]); XCTAssertThrowsError(try TaskRowCSV.make(capture)); XCTAssertGreaterThan(try TaskPrintRenderer.render(capture).data.count,0)
        row = task("root","Label unavailable"); row["labels"] = .array([.string("private-missing-label")]); XCTAssertThrowsError(try TaskRowCSV.make(doc([row])))
        row = task("root","Type unavailable"); row["is_heading"] = .string("future")
        XCTAssertEqual(try TaskRowCSV.make(doc([row])).rows[0][5],"unavailable")
    }
    func testCanonicalMarkerDamageAndInvalidLabelCellsAreRefused() throws {
        let output = try TaskRowCSV.make(doc([task("root","Task")]))
        func data(_ rows:[[String]]) -> Data {Data(rows.map{$0.map(WorkflowTemplateCSV.quote).joined(separator:",")}.joined(separator:"\r\n").utf8)}
        var rows = try WorkflowTemplateCSV.rows(output.data); rows[1][0]="future-format"; XCTAssertThrowsError(try WorkflowCSVSource(data:data(rows)))
        rows = try WorkflowTemplateCSV.rows(output.data); rows[1][17]="not a list"
        let source = try WorkflowCSVSource(data:data(rows)); var mapping = WorkflowCSVMapping(); mapping.columns=[.title:6,.labels:17]
        XCTAssertThrowsError(try source.template(name:"Workflow",mapping:mapping,anchor:Date(),headings:false))
    }
    func testRowAndByteBoundsRefuseWholeFilesWithoutTruncation() throws {
        let rows=(0..<5001).map{task("\($0)","Task")}
        XCTAssertEqual(try TaskRowCSV.make(doc(Array(rows.prefix(5000)))).rows.count,5000)
        XCTAssertThrowsError(try TaskRowCSV.make(doc(rows)))
        let large = try doc([task("root","Task",notes:String(repeating:"x",count:2_100_000))])
        XCTAssertThrowsError(try TaskRowCSV.make(large)); XCTAssertEqual(try TaskRowCSV.make(large,options:.init(notes:false)).rows.count,1)
        XCTAssertThrowsError(try TaskRowCSV.make(doc([])))
    }
}
