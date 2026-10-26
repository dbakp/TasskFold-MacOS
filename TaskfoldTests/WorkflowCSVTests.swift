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


final class SourceCSVMappingTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Copenhagen")!; return c }
    var anchor: Date { Dates.parse("2026-10-26", calendar: calendar)! }
    func source(_ text: String) throws -> WorkflowCSVSource { try WorkflowCSVSource(data: Data(text.utf8)) }
    func mapping(_ fields: [WorkflowCSVMapping.Field]) -> WorkflowCSVMapping { var result = WorkflowCSVMapping(); for (index, field) in fields.enumerated() { result.columns[field] = index }; return result }
    func file(_ text: String, fields: [WorkflowCSVMapping.Field], headings: Bool = true) throws -> WorkflowTemplateFile {
        try source(text).template(name: "Design workflow", mapping: mapping(fields), anchor: anchor, headings: headings, calendar: calendar)
    }
    func testExplicitHierarchyTypeAndForwardReferencesPreserveRowOrderAndNotes() throws {
        let read = try file("Key,Parent,Title,Notes,Kind\nchild,root,First task,\"Line one\nLine two\",task\nroot,,Design phase,Keep context,heading\nsecond,root,Second task,Notes,task", fields: [.identifier,.parent,.title,.notes,.type])
        XCTAssertEqual(read.template.kind, .project); XCTAssertTrue(read.template.requiresHeadingSupport)
        let root = try XCTUnwrap(read.template.tasks.first); XCTAssertEqual(TaskKind(root), .heading)
        XCTAssertEqual(root["subtasks"].list.map { $0.object["title"]?.text }, ["First task","Second task"])
        XCTAssertEqual(root["subtasks"].list[0].object["description"], .string("Line one\nLine two"))
        XCTAssertEqual(root.id, "csv-task-2"); XCTAssertFalse(String(decoding: try read.encoded(), as: UTF8.self).contains("\"root\""))
    }
    func testLiteralTitlePrefixesApostrophesAndFormulasNeverInferTypesOrExecute() throws {
        for title in ["* Context", "=SUM(A1:A2)", "'literal", "  @name", "+task"] {
            let read = try file("Title\n" + WorkflowTemplateCSV.quote(title), fields: [.title])
            XCTAssertEqual(read.template.tasks.first?.title, title); XCTAssertFalse(read.template.requiresHeadingSupport)
        }
    }
    func testCustomSourceTypeValuesAreExplicitAndCaseSensitiveAndHeadingsStayGated() throws {
        let source = try source("Title,Kind\nPlan,section\nAction,")
        var selected = mapping([.title,.type]); selected.headingValue = "section"; selected.taskValue = "action"
        XCTAssertThrowsError(try source.template(name: "Workflow", mapping: selected, anchor: anchor, headings: false))
        let result = try source.template(name: "Workflow", mapping: selected, anchor: anchor, headings: true)
        XCTAssertTrue(result.template.requiresHeadingSupport); XCTAssertEqual(TaskKind(result.template.tasks[0]), .heading)
        selected.headingValue = "Section"
        XCTAssertThrowsError(try source.template(name: "Workflow", mapping: selected, anchor: anchor, headings: true))
        selected.headingValue = "action"; XCTAssertThrowsError(try source.template(name: "Workflow", mapping: selected, anchor: anchor, headings: true))
    }
    func testCalendarDatesBecomeCivilOffsetsAcrossDSTAndRunAtFreshDates() throws {
        let file = try file("Title,Planned,Deadline,Clock,Zone,Priority,Minutes,Tags\nReview,2026-10-25,2026-10-28,09:30,Europe/Copenhagen,2,45,Design; Review;Design", fields: [.title,.plannedDate,.deadlineDate,.dueTime,.timeZone,.priority,.estimate,.labels])
        let task = file.template.tasks[0]
        XCTAssertEqual(task["planned_offset"], .number(-1)); XCTAssertEqual(task["deadline_offset"], .number(2)); XCTAssertEqual(task.durationMinutes, 45)
        XCTAssertEqual(task["labels"].list.map { $0.object["name"]?.text }, ["Design","Review"])
        XCTAssertEqual(task.priority, 2); XCTAssertEqual(task.string("due_time"), "09:30")
        let start = Dates.parse("2026-11-02", calendar: calendar)!
        let run = try file.template.instantiate(account: "synthetic", name: "New run", start: start)
        let created = try XCTUnwrap(run.first { $0.table == "tasks" }); XCTAssertEqual(created.fields["due_date"], .string("2026-11-01"))
        XCTAssertEqual(created.fields["deadline_date"], .string("2026-11-04"))
    }
    func testIgnoredColumnsCannotBecomeAccountIdentityOrCompletedHistory() throws {
        let source = try source("Title,user_id,completed,attachments\nFresh,other,true,secret")
        let selected = mapping([.title])
        XCTAssertEqual(source.ignoredColumns(selected), ["user_id","completed","attachments"])
        let file = try source.template(name: "Workflow", mapping: selected, anchor: anchor, headings: false)
        let a = try XCTUnwrap(file.template.instantiate(account: "new-account", name: "A").first { $0.table == "tasks" })
        let b = try XCTUnwrap(file.template.instantiate(account: "new-account", name: "B").first { $0.table == "tasks" })
        XCTAssertNotEqual(a.recordID, b.recordID); XCTAssertEqual(a.fields["user_id"], .string("new-account")); XCTAssertEqual(a.fields["completed"], .bool(false)); XCTAssertNil(file.template.tasks[0].fields["attachments"])
    }
    func testClockWithoutPlannedDateCannotBeSilentlyDroppedOnInstantiation() throws {
        XCTAssertThrowsError(try file("Title,Clock\nTask,09:00", fields: [.title,.dueTime]))
        XCTAssertThrowsError(try file("Title,Zone\nTask,Europe/Copenhagen", fields: [.title,.timeZone]))
    }
    func testMissingTitleDuplicateColumnOutOfRangeAndMissingIdentifierAreRefused() throws {
        let source = try source("A,B\nOne,Two")
        for columns: [WorkflowCSVMapping.Field:Int] in [[:], [.title:0,.notes:0], [.title:2], [.title:0,.parent:1], [.title: -1]] {
            var selected = WorkflowCSVMapping(); selected.columns = columns
            XCTAssertThrowsError(try source.template(name: "Workflow", mapping: selected, anchor: anchor, headings: true))
        }
    }
    func testBadReferencesDuplicateIdentifiersAndDisconnectedCyclesRefuseWholeDefinition() throws {
        for rows in ["a,missing,Task", "a,,One\na,,Two", "a,b,One\nb,a,Two", ",,Task", "a,a,Self"] {
            XCTAssertThrowsError(try file("ID,Parent,Title\n" + rows, fields: [.identifier,.parent,.title]))
        }
    }
    func testUnknownTypesInvalidDatesNumbersClockAndZoneRefuseWithoutRepairingInput() throws {
        for (header, value, field) in [("Kind","future",WorkflowCSVMapping.Field.type), ("Date","2026-02-30",.plannedDate), ("Date","26/10/2026",.deadlineDate), ("Priority","5",.priority), ("Minutes","0",.estimate), ("Minutes","1.5",.estimate), ("Clock","25:00",.dueTime), ("Zone","Mars/Olympus",.timeZone)] {
            XCTAssertThrowsError(try file("Title," + header + "\nTask," + value, fields: [.title,field]))
        }
        XCTAssertThrowsError(try file("Title\n\"  \"", fields: [.title]))
    }
    func testMalformedHeadersRowsQuotesUTF8AndVersionedWorkflowCannotBeMapped() throws {
        for input in ["A,A\nOne,Two", ",Title\na,b", "Title,Notes\nOnly one", "Title\n\"unterminated", "Title", "format,document_version\nother,1"] {
            XCTAssertThrowsError(try source(input))
        }
        XCTAssertThrowsError(try WorkflowCSVSource(data: Data([255])))
        XCTAssertThrowsError(try WorkflowCSVSource(data: Data(repeating: 65, count: WorkflowTemplateFile.maximumBytes + 1)))
    }
    func testSourceBoundsKeepAllRowsAndWideGenericColumnsWithoutRelaxingWorkflowSchema() throws {
        let header = (0..<64).map { "Column\($0)" }.joined(separator: ",")
        let row = Array(repeating: "Task", count: 64).joined(separator: ",")
        let wide = try source(header + "\n" + row); XCTAssertEqual(wide.headers.count, 64)
        XCTAssertThrowsError(try WorkflowTemplateCSV.rows(Data((header + "\n" + row).utf8)))
        XCTAssertThrowsError(try source(header + ",Extra\n" + row + ",Task"))
        let full = try source("Title\n" + Array(repeating: "Task", count: 5000).joined(separator: "\n"))
        XCTAssertEqual(try full.template(name: "Full workflow", mapping: mapping([.title]), anchor: anchor, headings: false).template.tasks.count, 5000)
        XCTAssertThrowsError(try source("Title\n" + Array(repeating: "Task", count: 5001).joined(separator: "\n")))
    }
    func testDepthBoundAndUnknownColumnsAreNotSilentlyTruncated() throws {
        let rows = (0..<13).map { "r\($0),\($0 == 0 ? "" : "r\($0 - 1)"),Task\($0)" }.joined(separator: "\n")
        XCTAssertThrowsError(try file("ID,Parent,Title\n" + rows, fields: [.identifier,.parent,.title]))
        let source = try source("Title,Future\nTask,Keep elsewhere\n\n")
        XCTAssertEqual(source.records.count, 1); XCTAssertEqual(source.ignoredColumns(mapping([.title])), ["Future"])
    }
}
