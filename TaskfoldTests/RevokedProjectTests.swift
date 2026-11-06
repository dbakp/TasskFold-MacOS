import XCTest
@testable import TaskfoldCore

final class RevokedProjectTests: XCTestCase {
    func testConfirmedRevocationRemovesDependentQueueButPreservesOtherEdits() throws {
        let project = "shared", task = "shared-task", section = "shared-section"
        var source = Snapshot()
        source.tables["projects"] = [Record(["id": .string(project)])]
        source.tables["tasks"] = [Record(["id": .string(task), "project_id": .string(project), "title": .string("Offline draft")])]
        source.tables["sections"] = [Record(["id": .string(section), "project_id": .string(project)])]
        let shared = Mutation(table: "tasks", recordID: task, method: "PATCH", fields: ["title": .string("Offline draft")])
        let newTask = Mutation(table: "tasks", recordID: "new-shared", method: "POST", fields: ["id": .string("new-shared"), "project_id": .string(project)])
        let sectionEdit = Mutation(table: "sections", recordID: section, method: "PATCH", fields: ["name": .string("New name")])
        let personal = Mutation(table: "tasks", recordID: "personal", method: "PATCH", fields: ["title": .string("Keep my edit")])
        source.pending = [shared, newTask, sectionEdit, personal]
        let remote: [String: [Record]] = ["projects": [], "sections": [], "project_collaborators": [], "tasks": [Record(["id": .string("personal"), "title": .string("Synced title")])]]
        let recovered = try XCTUnwrap(source.recoveringUnavailableProject(for: shared, remote: remote))
        XCTAssertEqual(recovered.pending, [personal])
        XCTAssertEqual(recovered.tables["tasks"]?.map(\.title), ["Keep my edit"])
        XCTAssertTrue(recovered.tables["projects"]!.isEmpty); XCTAssertTrue(recovered.tables["sections"]!.isEmpty)
        XCTAssertEqual(source.pending, [shared, newTask, sectionEdit, personal], "Original recovery input must remain intact")
        XCTAssertEqual(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(source)), source)
    }
    private let emptyRemote: [String: [Record]] = ["projects": [], "tasks": [], "sections": [], "project_collaborators": []]
    func testMissingOrContradictoryRemoteEvidenceCannotRemoveWork() {
        let change = Mutation(table: "tasks", recordID: "task", method: "PATCH", fields: ["title": .string("Draft")], baseline: ["project_id": .string("shared")])
        var source = Snapshot(); source.pending = [change]
        for remote: [String: [Record]] in [[:], ["projects": []], ["tasks": []], emptyRemote.merging(["projects": [Record(["id": .string("shared")])]]) { _, new in new }, emptyRemote.merging(["tasks": [Record(["id": .string("task")])]]) { _, new in new }, emptyRemote.merging(["tasks": [Record(["id": .string("other"), "project_id": .string("shared")])]]) { _, new in new }] {
            XCTAssertNil(source.recoveringUnavailableProject(for: change, remote: remote))
        }
    }
    func testNewSharedTaskAndSectionAndProjectEditsCanRecover() throws {
        for (table, method, id) in [("tasks", "POST", "new-task"), ("sections", "POST", "new-section"), ("sections", "PATCH", "section"), ("projects", "PATCH", "shared"), ("project_collaborators", "POST", "invite")] {
            var source = Snapshot()
            let blocked = Mutation(table: table, recordID: id, method: method, fields: ["id": .string(id), "project_id": .string("shared"), "name": .string("Local draft")])
            let personal = Mutation(table: "tasks", recordID: "personal", method: "POST", fields: ["id": .string("personal"), "title": .string("Personal task")])
            source.pending = [blocked, personal]; source.apply(blocked); source.apply(personal)
            let result = try XCTUnwrap(source.recoveringUnavailableProject(for: blocked, remote: emptyRemote), table)
            XCTAssertEqual(result.pending, [personal]); XCTAssertEqual(result.tables["tasks"]?.map(\.title), ["Personal task"])
            XCTAssertEqual(source.pending, [blocked, personal])
        }
    }
    func testLocallyMovedOutTaskUsesOriginalProjectAndPreservesRecoveryInput() throws {
        var source = Snapshot()
        let move = Mutation(table: "tasks", recordID: "task", method: "PATCH", fields: ["project_id": .null], baseline: ["project_id": .string("SHARED")])
        let edit = Mutation(table: "tasks", recordID: "task", method: "PATCH", fields: ["title": .string("Later draft")])
        source.tables["tasks"] = [Record(["id": .string("task"), "title": .string("Later draft"), "project_id": .null])]
        source.pending = [edit, move]
        XCTAssertEqual(source.recoveryProjectIDs(for: edit), ["shared"])
        XCTAssertNotNil(source.recoveringUnavailableProject(for: edit, remote: emptyRemote))
        XCTAssertEqual(source.recoveryProjectIDs(for: move), ["shared"])
        let recovered = try XCTUnwrap(source.recoveringUnavailableProject(for: move, remote: emptyRemote))
        XCTAssertTrue(recovered.pending.isEmpty); XCTAssertTrue(recovered.tables["tasks"]!.isEmpty)
        XCTAssertEqual(source.pending, [edit, move]); XCTAssertEqual(source.tables["tasks"]?.first?.title, "Later draft")
    }
    func testOfflineNewProjectIsNeverMistakenForRevokedAccess() {
        var source = Snapshot()
        let project = Mutation(table: "projects", recordID: "shared", method: "POST", fields: ["id": .string("shared")])
        let task = Mutation(table: "tasks", recordID: "task", method: "POST", fields: ["id": .string("task"), "project_id": .string("shared")])
        source.pending = [project, task]
        XCTAssertTrue(source.recoveryProjectIDs(for: project).isEmpty)
        XCTAssertTrue(source.recoveryProjectIDs(for: task).isEmpty)
        XCTAssertNil(source.recoveringUnavailableProject(for: project, remote: emptyRemote))
        XCTAssertNil(source.recoveringUnavailableProject(for: task, remote: emptyRemote))
    }
    func testVisibleMovedTaskAndPartialReadPreserveQueue() {
        var source = Snapshot()
        let blocked = Mutation(table: "tasks", recordID: "new", method: "POST", fields: ["id": .string("new"), "project_id": .string("shared")])
        let edit = Mutation(table: "tasks", recordID: "other", method: "PATCH", fields: ["title": .string("Local draft")])
        source.tables["tasks"] = [Record(["id": .string("other"), "project_id": .string("shared")])]; source.pending = [blocked, edit]
        var moved = emptyRemote; moved["tasks"] = [Record(["id": .string("other"), "project_id": .null])]
        XCTAssertNil(source.recoveringUnavailableProject(for: blocked, remote: moved))
        for table in emptyRemote.keys {
            var partial = emptyRemote; partial.removeValue(forKey: table)
            XCTAssertNil(source.recoveringUnavailableProject(for: blocked, remote: partial))
        }
    }
}
