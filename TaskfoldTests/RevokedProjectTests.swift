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
        let remote: [String: [Record]] = ["projects": [], "sections": [], "tasks": [Record(["id": .string("personal"), "title": .string("Synced title")])]]
        let recovered = try XCTUnwrap(source.removingUnavailableProject(project, blockedTaskID: task, remote: remote))
        XCTAssertEqual(recovered.pending, [personal])
        XCTAssertEqual(recovered.tables["tasks"]?.map(\.title), ["Keep my edit"])
        XCTAssertTrue(recovered.tables["projects"]!.isEmpty); XCTAssertTrue(recovered.tables["sections"]!.isEmpty)
        XCTAssertEqual(source.pending, [shared, newTask, sectionEdit, personal], "Original recovery input must remain intact")
        XCTAssertEqual(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(source)), source)
    }
    func testMissingOrContradictoryRemoteEvidenceCannotRemoveWork() {
        let source = Snapshot()
        for remote: [String: [Record]] in [[:], ["projects": []], ["tasks": []], ["projects": [Record(["id": .string("shared")])], "tasks": []], ["projects": [], "tasks": [Record(["id": .string("task")])]], ["projects": [], "tasks": [Record(["id": .string("other"), "project_id": .string("shared")])]]] {
            XCTAssertNil(source.removingUnavailableProject("shared", blockedTaskID: "task", remote: remote))
        }
    }
}
