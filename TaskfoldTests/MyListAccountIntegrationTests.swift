import XCTest
@testable import TaskfoldCore
@testable import WidgetModel

/// Real authentication and Mac-owned projection; no Mac GUI or Keychain access.
final class MyListAccountIntegrationTests: XCTestCase {
    @MainActor func testAuthenticatedAccountSwitchRejectsForeignListAndRestoresOriginalKey() async throws {
        guard let path = ProcessInfo.processInfo.environment["TASKFOLD_MYLIST_ACCOUNT_FIXTURES"] else {
            throw XCTSkip("Disposable My list accounts not configured")
        }
        let fixtures = try JSONDecoder().decode([[String: String]].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(fixtures.count, 2)
        for f in fixtures {
            let owner = try XCTUnwrap(f["userID"])
            guard UUID(uuidString: owner) != nil, f["email"] == "taskfold-continuity-" + owner + "@example.invalid" else {
                throw XCTSkip("Requires disposable account namespace")
            }
        }
        XCTAssertNotEqual(fixtures[0]["userID"], fixtures[1]["userID"])
        let backend = Backend(configuration: ["URL": try XCTUnwrap(fixtures[0]["url"]), "Key": try XCTUnwrap(fixtures[0]["key"])], session: nil, persistSession: { _ in })
        var originalKey: String?
        for index in [0, 1, 0] {
            let f = fixtures[index], owner = try XCTUnwrap(f["userID"])
            let signedIn = try await backend.signIn(email: try XCTUnwrap(f["email"]), password: try XCTUnwrap(f["password"]), signup: false)
            XCTAssertTrue(signedIn); XCTAssertEqual(backend.session?.user.id, owner)
            let tasks = try await backend.rows("tasks"), projects = try await backend.rows("projects")
            XCTAssertEqual(tasks.count, 1); XCTAssertEqual(projects.count, 1)
            XCTAssertTrue((tasks + projects).allSatisfy { $0.string("user_id") == owner })
            XCTAssertEqual(tasks.first?.id, f["taskID"]); XCTAssertEqual(tasks.first?.title, f["taskTitle"])
            XCTAssertEqual(tasks.first?.durationMinutes, 25); XCTAssertEqual(tasks.first?.completed, false)
            XCTAssertEqual(projects.first?.id, f["projectID"])
            let now = Date()
            let payload = WidgetProjection.payload(tasks: tasks, projects: projects, account: owner, now: now)
            let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(payload))
            let ownList = try XCTUnwrap(snapshot.availableLists.first { $0.recordID == f["projectID"] })
            XCTAssertEqual(snapshot.listTasks(ownList.id, at: now).map(\.id), [try XCTUnwrap(f["taskID"])])
            if originalKey == nil { originalKey = ownList.id }
            let selected = try XCTUnwrap(originalKey)
            if index == 0 {
                XCTAssertEqual(ownList.id, selected)
                XCTAssertEqual(snapshot.listStatus(selected, at: now), .ready)
                XCTAssertEqual(snapshot.list(selected)?.name, fixtures[0]["projectName"])
                XCTAssertEqual(snapshot.listTasks(selected, at: now).map(\.id), [try XCTUnwrap(fixtures[0]["taskID"])])
            } else {
                XCTAssertNotEqual(ownList.id, selected)
                XCTAssertNil(snapshot.list(selected))
                XCTAssertEqual(snapshot.listStatus(selected, at: now), .unavailable)
                XCTAssertTrue(snapshot.listTasks(selected, at: now).isEmpty)
            }
        }
    }
}
