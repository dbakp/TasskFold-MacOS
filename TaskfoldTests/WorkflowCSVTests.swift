import XCTest
@testable import TaskfoldCore

final class WorkflowCSVTests: XCTestCase {
    func file(heading: Bool = true, title: String = "Reference, \"design\"", notes: String = "First line\r\nSecond line 👩🏽‍💻") throws -> WorkflowTemplateFile {
        let grand: JSON = .object(["id": .string("grand"), "title": .string("* Literal ordinary title"), "description": .string("Keep action notes"), "priority": .number(3), "labels": .array([]), "subtasks": .array([])])
        var child: [String:JSON] = ["id": .string("child"), "title": .string("Child context"), "description": .string("Notes"), "labels": .array([]), "subtasks": .array([grand])]
        var root: [String:JSON] = ["id": .string("root"), "title": .string(title), "description": .string(notes), "project_id": .string("p"), "section_id": .string("s"), "priority": .number(1), "duration_minutes": .number(45), "labels": .array([.object(["name": .string("Design"), "color": .string("#884dff")])]), "planned_offset": .number(-2), "deadline_offset": .number(3), "due_time": .string("09:30"), "time_zone": .string("Europe/Copenhagen"), "is_recurring": .bool(true), "recurrence_pattern": .object(["type": .string("weekly"), "interval": .number(2)]), "repeat_end_offset": .number(14)]
        if heading { root["is_heading"] = .bool(true); child["is_heading"] = .bool(true) }
        root["subtasks"] = .array([.object(child)])
        var document: [String:JSON] = ["version": .number(heading ? 2 : 1), "kind": .string("project"), "projects": .array([.object(["id": .string("p"), "name": .string("=Project title"), "description": .string("Project notes"), "color": .string("#884dff"), "order_index": .number(0)])]), "sections": .array([.object(["id": .string("s"), "project_id": .string("p"), "name": .string("Research"), "order_index": .number(0)])]), "tasks": .array([.object(root)])]
        if heading { document["capabilities"] = .array([.string("task_headings")]) }
        return try WorkflowTemplateFile(name: "Reference workflow", document: .object(document))
    }
    func rewrite(_ data: Data, _ edit: (inout [[String]]) -> Void) throws -> Data {
        var rows = try WorkflowTemplateCSV.rows(data); edit(&rows)
        return Data((rows.map { $0.map(WorkflowTemplateCSV.quote).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n").utf8)
    }
    func testCSVPreservesHeadingsHierarchyNotesLabelsPlansAndRepeatFields() throws {
        let original = try file(), read = try WorkflowTemplateFile(data: original.encodedCSV())
        XCTAssertTrue(read.template.requiresHeadingSupport); XCTAssertEqual(read.name, original.name)
        XCTAssertEqual(read.template.projects[0].name, "=Project title"); XCTAssertEqual(read.template.sections[0].name, "Research")
        let before = try WorkflowTemplateFile(data: original.encoded()).template.tasks[0], after = read.template.tasks[0]
        for key in ["title", "description", "priority", "duration_minutes", "labels", "planned_offset", "deadline_offset", "due_time", "time_zone", "is_recurring", "recurrence_pattern", "repeat_end_offset"] { XCTAssertEqual(after[key], before[key], key) }
        XCTAssertEqual(TaskKind(after), .heading)
        XCTAssertEqual(after["subtasks"].list[0].object["is_heading"], .bool(true))
        XCTAssertEqual(after["subtasks"].list[0].object["subtasks"]?.list[0].object["title"], .string("* Literal ordinary title"))
        XCTAssertEqual(TemplateEditing.summary(read.template.document), "1 project · 1 section · 1 task · 2 headings")
    }
    func testOrdinaryVersionOneLiteralPrefixDoesNotBecomeHeading() throws {
        let read = try WorkflowTemplateFile(data: file(heading: false, title: "* Literal text").encodedCSV())
        XCTAssertFalse(read.template.requiresHeadingSupport); XCTAssertEqual(read.template.tasks[0].title, "* Literal text")
        XCTAssertEqual(TaskKind(read.template.tasks[0]), .task); XCTAssertNil(read.template.tasks[0].fields["is_heading"])
    }
    func testSpreadsheetTextEscapesAndRestoresFormulaPrefixesApostrophesAndWhitespace() throws {
        for text in ["=SUM(A1:A2)", "+task", "-task", "@name", "  =formula", "'literal", "'=literal", "\tTask", "\nNew line", " Plain title "] {
            let read = try WorkflowTemplateFile(data: file(title: text, notes: text).encodedCSV())
            XCTAssertEqual(read.template.tasks[0].title, text); XCTAssertEqual(read.template.tasks[0].string("description"), text)
            XCTAssertEqual(WorkflowTemplateCSV.unescape(WorkflowTemplateCSV.escape(text)), text)
        }
    }
    func testCSVUsesFileLocalReferencesAndFreshRunIdentities() throws {
        let data = try file().encodedCSV(), text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("\"root\"")); XCTAssertTrue(text.contains("task-1")); XCTAssertFalse(text.contains("user_id"))
        let read = try WorkflowTemplateFile(data: data), first = try read.template.instantiate(account: "new-account", name: "Fresh project"), second = try read.template.instantiate(account: "new-account", name: "Fresh project")
        let a = try XCTUnwrap(first.first { $0.table == "tasks" }), b = try XCTUnwrap(second.first { $0.table == "tasks" })
        XCTAssertNotEqual(a.recordID, b.recordID); XCTAssertEqual(a.fields["is_heading"], .bool(true)); XCTAssertEqual(a.fields["user_id"], .string("new-account"))
    }
    func testCSVQuotingAcceptsUnicodeDoubledQuotesNewlinesBOMAndNoFinalNewline() throws {
        let data = try file().encodedCSV(), text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"\"design\"\"")); XCTAssertTrue(text.contains("First line\r\nSecond line"))
        let bom = Data([239,187,191]) + data; XCTAssertEqual(try WorkflowTemplateFile(data: bom).template.tasks[0].title, "Reference, \"design\"")
        XCTAssertEqual(try WorkflowTemplateFile(data: Data(data.dropLast(2))).name, "Reference workflow")
        XCTAssertEqual(try WorkflowTemplateCSV.rows(Data("a,\"b,b\",\"c\"\"d\"\r\nx,y,z".utf8)), [["a","b,b","c\"d"],["x","y","z"]])
    }
    func testMalformedUTF8QuotesAndColumnCountsRefuseWithoutTruncation() throws {
        for text in ["a,\"unfinished", "a,\"closed\"tail", "a,b\"quote"] { XCTAssertThrowsError(try WorkflowTemplateCSV.rows(Data(text.utf8))) }
        XCTAssertThrowsError(try WorkflowTemplateCSV.rows(Data([255])))
        let data = try file().encodedCSV(); let bad = try rewrite(data) { $0[2].append("future") }
        XCTAssertThrowsError(try WorkflowTemplateFile(data: bad))
    }
    func testDowngradeFutureVersionMixedMetadataAndUnknownTypeRefuse() throws {
        let data = try file().encodedCSV(), version = WorkflowTemplateCSV.columns.firstIndex(of: "document_version")!, capability = WorkflowTemplateCSV.columns.firstIndex(of: "capabilities")!, type = WorkflowTemplateCSV.columns.firstIndex(of: "type")!
        let downgraded = try rewrite(data) { rows in for i in 1..<rows.count { rows[i][version] = "1"; rows[i][capability] = "" } }
        XCTAssertThrowsError(try WorkflowTemplateFile(data: downgraded))
        for change in ["version", "metadata", "type"] {
            let bad = try rewrite(data) { rows in if change == "version" { rows[1][version] = "3" } else if change == "metadata" { rows[2][capability] = "future" } else { rows[4][type] = "future" } }
            XCTAssertThrowsError(try WorkflowTemplateFile(data: bad))
        }
    }
    func testMissingParentsCyclesAndDuplicateTaskIDsRefuseAsWholeDefinition() throws {
        let data = try file().encodedCSV(), parent = WorkflowTemplateCSV.columns.firstIndex(of: "parent_id")!, id = WorkflowTemplateCSV.columns.firstIndex(of: "id")!
        for mode in ["missing", "cycle", "duplicate"] {
            let bad = try rewrite(data) { rows in if mode == "missing" { rows[5][parent] = "absent" } else if mode == "cycle" { rows[4][parent] = rows[6][id] } else { rows[5][id] = rows[4][id] } }
            XCTAssertThrowsError(try WorkflowTemplateFile(data: bad))
        }
        XCTAssertEqual(try WorkflowTemplateFile(data: data).template.tasks[0].title, "Reference, \"design\"")
    }
    func testParentCanFollowChildWithoutLosingSiblingOrder() throws {
        let data = try rewrite(file().encodedCSV()) { rows in rows.swapAt(4,6) }
        let read = try WorkflowTemplateFile(data: data)
        XCTAssertEqual(read.template.tasks[0]["subtasks"].list[0].object["title"], .string("Child context"))
    }
    func testUnexpectedEntityFieldsAndExtraMetadataCannotBeSilentlyDiscarded() throws {
        let data = try file().encodedCSV(), notes = WorkflowTemplateCSV.columns.firstIndex(of: "notes")!, type = WorkflowTemplateCSV.columns.firstIndex(of: "type")!
        for row in [1,2,3] {
            let bad = try rewrite(data) { $0[row][row == 1 ? notes : type] = "Keep this field" }
            XCTAssertThrowsError(try WorkflowTemplateFile(data: bad))
        }
    }
    func testCoordinatedCSVFileReadAndBounds() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-workflow-csv-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Reference.csv"); try file().encodedCSV().write(to: url)
        XCTAssertTrue(try WorkflowTemplateFile.read(url).template.requiresHeadingSupport)
        XCTAssertThrowsError(try WorkflowTemplateFile(data: Data(repeating: 65, count: WorkflowTemplateFile.maximumBytes + 1)))
        XCTAssertThrowsError(try WorkflowTemplateCSV.rows(Data(repeating: 65, count: WorkflowTemplateFile.maximumBytes + 1)))
    }
    func testTaskAndSectionDefinitionsRoundTripAndUnquotedHeaderIsAccepted() throws {
        let original = try file()
        for kind in ["task", "section"] {
            var document = original.template.document.object
            document["kind"] = .string(kind)
            if kind == "task" { document["sections"] = .array([]) }
            var task = original.template.tasks[0]
            if kind == "task" { task.fields.removeValue(forKey: "section_id") }
            document["tasks"] = .array([.object(task.fields)])
            let source = try WorkflowTemplateFile(name: "Portable " + kind, document: .object(document))
            let csv = try source.encodedCSV(), decoded = try WorkflowTemplateFile(data: csv)
            XCTAssertEqual(decoded.template.kind.rawValue, kind); XCTAssertTrue(decoded.template.requiresHeadingSupport)
            let text = String(decoding: csv, as: UTF8.self)
            let headerEnd = try XCTUnwrap(text.range(of: "\r\n"))
            let plainHeader = WorkflowTemplateCSV.columns.joined(separator: ",") + String(text[headerEnd.lowerBound...])
            XCTAssertEqual(try WorkflowTemplateFile(data: Data(plainHeader.utf8)).name, "Portable " + kind)
        }
    }

}
