import XCTest
@testable import TaskfoldCore

final class ProjectActivityContextTests: XCTestCase {
    let account = "owner"
    let project = Record(["id": .string("studio"), "user_id": .string("owner"), "name": .string("Studio")])
    func fixture() throws -> (TaskActivity, Record) {
        var task = Record.task(user: account, project: project.id); task["title"] = .string("Current title")
        var snapshot = Snapshot(tables: ["tasks": [task]])
        TaskActivity.recordLocal(Mutation(table: "tasks", recordID: task.id, method: "POST", fields: task.fields), before: nil, after: task, snapshot: &snapshot, account: account)
        return (try XCTUnwrap(snapshot.tables[TaskActivity.table]?.first.flatMap { TaskActivity(row: $0) }), task)
    }
    func context(_ event: TaskActivity, tasks: [Record], projects: [Record]? = nil, members: [Record] = [], account: String = "owner") -> ProjectActivityContext {
        ProjectActivityContext(event: event, project: project.id, tasks: tasks, projects: projects ?? [project], members: members, account: account)
    }
    func testCurrentIdentityAndTitleResolveFreshWithoutMutatingLedger() throws {
        let (event, original) = try fixture()
        var renamed = original; renamed["title"] = .string("Renamed after the event")
        XCTAssertEqual(context(event, tasks: [renamed]).task?.title, "Renamed after the event")
        XCTAssertEqual(context(event, tasks: [renamed]).actorLabel, "You")
        XCTAssertNil(context(event, tasks: []).task)
        XCTAssertEqual(original.title, "Current title")
        XCTAssertFalse(event.after.keys.contains("title"))
    }
    func testRemovedProjectOrInaccessibleDestinationCannotRouteFromCachedTaskOrMember() throws {
        let (event, original) = try fixture()
        XCTAssertNil(context(event, tasks: [original], projects: []).task)
        var moved = original; moved["project_id"] = .string("private-project")
        let member = Record(["id": .string("collaborator"), "display_name": .string("Known person")])
        XCTAssertNil(context(event, tasks: [moved], members: [member]).task)
        let accessible = Record(["id": .string("private-project")])
        XCTAssertEqual(context(event, tasks: [moved], projects: [project, accessible]).task?.id, original.id)
    }
    func testInboxRouteRequiresCurrentOwnership() throws {
        let (event, original) = try fixture()
        var inbox = original; inbox["project_id"] = .null
        XCTAssertEqual(context(event, tasks: [inbox]).task?.id, inbox.id)
        inbox["user_id"] = .string("someone-else")
        XCTAssertNil(context(event, tasks: [inbox]).task)
    }
    func testActorUsesStableLedgerIdentityAndNeverTreatsDisplayNameAsAccount() throws {
        var (event, task) = try fixture()
        event.actor = "teammate"
        let member = Record(["id": .string("teammate"), "display_name": .string("You")])
        XCTAssertFalse(ProjectActivityContext.isMine(event, account: account))
        XCTAssertEqual(context(event, tasks: [task], members: [member]).actorLabel, "You")
        XCTAssertEqual(context(event, tasks: [task]).actorLabel, "Collaborator")
        event.actor = nil
        XCTAssertFalse(ProjectActivityContext.isMine(event, account: account))
        XCTAssertEqual(context(event, tasks: [task]).actorLabel, "Name unavailable")
    }
    func testScopesNormalizeIdentityButRejectMissingAccountAndOtherProject() throws {
        var (event, task) = try fixture(); event.actor = "OWNER"
        XCTAssertTrue(ProjectActivityContext.isMine(event, account: account))
        XCTAssertFalse(ProjectActivityContext.isMine(event, account: ""))
        XCTAssertNil(context(event, tasks: [task], account: "").task)
        let other = ProjectActivityContext(event: event, project: "other", tasks: [task], projects: [project, Record(["id": .string("other")])], members: [], account: account)
        XCTAssertNil(other.task); XCTAssertEqual(other.actorLabel, "Name unavailable")
    }
}
