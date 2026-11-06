import XCTest
@testable import TaskfoldCore

final class WorkflowStarterTests: XCTestCase {
    let owner = "ca000000-0000-4000-8000-000000000001"

    func testEveryStarterCanBeSavedAndTransferredWithoutAnAccount() throws {
        XCTAssertEqual(Set(WorkflowStarter.allCases.map(\.id)).count, 4)
        for starter in WorkflowStarter.allCases {
            let file = try starter.file()
            XCTAssertEqual(file.template.kind, .project)
            XCTAssertFalse(file.template.requiresHeadingSupport)
            XCTAssertFalse(file.template.tasks.isEmpty)
            let encoded = try file.encoded()
            let reopened = try WorkflowTemplateFile(data: encoded)
            XCTAssertEqual(reopened.name, starter.name)
            XCTAssertEqual(reopened.template.tasks.map(\.title), file.template.tasks.map(\.title))
            XCTAssertEqual(reopened.template.sections.map(\.name), file.template.sections.map(\.name))
            XCTAssertEqual(try WorkflowTemplateFile(data: file.encodedCSV()).template.tasks.map(\.title), file.template.tasks.map(\.title))
            for row in file.template.projects + file.template.sections + file.template.tasks {
                XCTAssertNil(row.fields["user_id"])
                XCTAssertNil(row.fields["assigned_to"])
                XCTAssertNil(row.fields["completed_at"])
            }
        }
    }

    func testRunsGetFreshIdentitiesAndRetainSectionOrderAndNotes() throws {
        for starter in WorkflowStarter.allCases {
            let template = try starter.file().template
            let first = try template.instantiate(account: owner, name: "My workflow")
            let second = try template.instantiate(account: owner, name: "Another workflow")
            XCTAssertTrue(Set(first.map(\.recordID)).isDisjoint(with: Set(second.map(\.recordID))))
            let tasks = first.filter { $0.table == "tasks" }.map { Record($0.fields) }
            XCTAssertEqual(tasks.map(\.title), template.tasks.map(\.title))
            XCTAssertEqual(tasks.map { $0.string("description") }, template.tasks.map { $0.string("description") })
            let sections = first.filter { $0.table == "sections" }
            XCTAssertEqual(sections.map { $0.fields["name"] }, template.sections.map { $0["name"] })
            for section in sections {
                let key = "group:" + section.fields["project_id"]!.text + ":" + section.recordID
                let order = try XCTUnwrap(first.first { $0.table == "view_orders" && $0.recordID == key })
                XCTAssertEqual(order.fields["ids"]?.list.map(\.text), tasks.filter { $0.string("section_id") == section.recordID }.map(\.id))
            }
            XCTAssertTrue(first.allSatisfy { $0.fields["user_id"] == .string(owner) && $0.insertOnly == true })
        }
    }

    func testStartersDoNotInventDatesRecurrenceOrReminders() throws {
        for starter in WorkflowStarter.allCases {
            let run = try starter.file().template.instantiate(account: owner, name: starter.name, start: Date())
            for change in run where change.table == "tasks" {
                let task = Record(change.fields)
                XCTAssertTrue(task.string("due_date").isEmpty)
                XCTAssertTrue(task.string("deadline_date").isEmpty)
                XCTAssertFalse(task["is_recurring"].flag)
                XCTAssertTrue(ReminderSpec.rows(task).isEmpty)
                XCTAssertFalse(task.completed)
                XCTAssertTrue((1...10080).contains(task.durationMinutes ?? 0))
            }
        }
    }

    func testRunUndoAndRedoPreserveExistingWorkAndSavedDefinition() throws {
        for starter in WorkflowStarter.allCases {
            let file = try starter.file()
            var old = Record.task(user: owner); old["title"] = .string("Already saved")
            let definition = Record(["id": .string(UUID().uuidString.lowercased()), "user_id": .string(owner), "name": .string(file.name), "document": file.template.document])
            var snapshot = Snapshot(tables: ["tasks": [old], WorkflowTemplate.table: [definition]])
            let changes = try file.template.instantiate(account: owner, name: starter.name)
            let undo = try XCTUnwrap(WorkflowUndo.deleting(changes, snapshot: snapshot))
            changes.forEach { snapshot.apply($0) }
            try WorkflowUndo.validate(undo, snapshot: snapshot, account: owner)
            snapshot.apply(undo)
            XCTAssertEqual(snapshot.tables["tasks"], [old])
            XCTAssertEqual(snapshot.tables[WorkflowTemplate.table], [definition])
            let redo = try XCTUnwrap(WorkflowUndo.restoring(undo))
            redo.forEach { snapshot.apply($0) }
            XCTAssertEqual(snapshot.tables["tasks"]?.count, file.template.tasks.count + 1)
            XCTAssertEqual(snapshot.tables[WorkflowTemplate.table], [definition])
        }
    }

    func testSearchFindsPurposeAndTrimsWhitespace() {
        XCTAssertEqual(WorkflowStarter.matching("  WEEKLY  "), [.weeklyReset])
        XCTAssertEqual(WorkflowStarter.matching("bookings"), [.tripPreparation])
        XCTAssertEqual(WorkflowStarter.matching("discussion"), [.meetingFollowUp])
        XCTAssertEqual(WorkflowStarter.matching(""), WorkflowStarter.allCases)
        XCTAssertTrue(WorkflowStarter.matching("no such workflow").isEmpty)
    }
}
