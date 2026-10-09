import XCTest
@testable import TaskfoldCore

final class NativeBehaviorTests: XCTestCase {
    func task(_ id: String = "one", date: String = "2026-09-06", time: String = "") -> Record {
        Record(["id": .string(id), "title": .string("Focus"), "due_date": .string(date), "due_time": time.isEmpty ? .null : .string(time), "completed": .bool(false)])
    }
    func testDayDropPreservesTimeAndOtherFieldsAndCanUndo() throws {
        let original = task("moving", date: "2026-09-01", time: "14:30")
        var snapshot = Snapshot(); snapshot.tables["tasks"] = [original]
        let changes = DayPlacement.changes(task: original, day: "2026-09-06", orderedIDs: ["a", "b"], before: "b")
        let history = EditHistory(changes: changes, snapshot: snapshot)
        for change in changes { snapshot.apply(change) }
        XCTAssertEqual(snapshot.tables["tasks"]?.first?.string("due_date"), "2026-09-06")
        XCTAssertEqual(snapshot.tables["tasks"]?.first?.string("due_time"), "14:30")
        XCTAssertEqual(snapshot.tables[DayPlacement.table]?.first?["ids"].list.map(\.text), ["a", "moving", "b"])
        for change in history.undo { snapshot.apply(change) }
        XCTAssertEqual(snapshot.tables["tasks"], [original])
        for change in history.redo { snapshot.apply(change) }
        let restored = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored, snapshot)
    }
    func testSameDayReorderEmptyDayAndStaleAnchor() {
        let row = task("b")
        let changes = DayPlacement.changes(task: row, day: "2026-09-06", orderedIDs: ["a", "b", "c"], before: "a")
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].fields["ids"]?.list.map(\.text), ["b", "a", "c"])
        for ids in [[], ["a"]] as [[String]] {
            let result = DayPlacement.changes(task: row, day: "2026-09-07", orderedIDs: ids, before: "deleted")
            XCTAssertEqual(result.last?.fields["ids"]?.list.map(\.text), ids + ["b"])
        }
        var completed = row; completed["completed"] = .bool(true)
        XCTAssertTrue(DayPlacement.changes(task: completed, day: "2026-09-07", orderedIDs: [], before: nil).isEmpty)
        XCTAssertTrue(DayPlacement.changes(task: row, day: "invalid", orderedIDs: [], before: nil).isEmpty)
    }
    func testArrangedKeepsPriorityBandsAndManualOrderWithin() {
        func prioritised(_ id: String, _ priority: Int) -> Record { var r = task(id); r["priority"] = .number(Double(priority)); return r }
        let rows = [prioritised("a", 3), prioritised("b", 1), prioritised("c", 3), prioritised("d", 1), prioritised("e", 4)]
        // Manual order says c before a and d before b; bands still win.
        XCTAssertEqual(DayPlacement.arranged(rows, ids: ["c", "a", "d", "b"]).map(\.id), ["d", "b", "c", "a", "e"])
        let arranged = DayPlacement.arranged(rows, ids: ["c", "a", "d", "b"])
        // A P3 dropped above the P1s snaps to the top of the P3 band; dropped on another P3 it stays.
        XCTAssertEqual(DayPlacement.constrained(before: "d", priority: 3, in: arranged), "c")
        XCTAssertEqual(DayPlacement.constrained(before: "a", priority: 3, in: arranged), "a")
        // A P1 dropped at the end snaps to just above the first lower-priority task.
        XCTAssertEqual(DayPlacement.constrained(before: nil, priority: 1, in: arranged), "c")
        XCTAssertNil(DayPlacement.constrained(before: nil, priority: 4, in: arranged))
    }
    func testDayOrderHandlesStaleAndDuplicateIDs() {
        XCTAssertEqual(DayPlacement.ordered([task("a"), task("b"), task("c")], ids: ["deleted", "b", "b"]).map(\.id), ["b", "a", "c"])
    }
    func testDefaultViewRoundTrip() {
        for scope in [TaskScope.today, .inbox, .upcoming, .all, .completed, .project("project-id"), .label("label-id")] {
            XCTAssertEqual(TaskScope(preferenceKey: scope.preferenceKey), scope)
        }
        XCTAssertNil(TaskScope(preferenceKey: "project:"))
        XCTAssertNil(TaskScope(preferenceKey: "unknown"))
    }
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
        return calendar
    }
    func testDateOnlyReminderIsEightAM() {
        let plan = DueReminder.plan(tasks: [task()], now: Dates.parse("2026-09-05", calendar: calendar)!, calendar: calendar)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(calendar.component(.hour, from: plan[0].date), 8)
        XCTAssertEqual(calendar.component(.minute, from: plan[0].date), 0)
    }
    func testTimedReminderUsesExactDueTime() {
        let plan = DueReminder.plan(tasks: [task(time: "15:37:00")], now: Dates.parse("2026-09-05", calendar: calendar)!, calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: plan[0].date), 15)
        XCTAssertEqual(calendar.component(.minute, from: plan[0].date), 37)
    }
    func testReminderExcludesCompletedPastAndInvalidTasks() {
        var completed = task("done"); completed["completed"] = .bool(true)
        let plan = DueReminder.plan(tasks: [completed, task("past", date: "2026-09-04"), task("invalid", time: "25:00"), task("none", date: ""), task("valid")], now: Dates.parse("2026-09-05", calendar: calendar)!, calendar: calendar)
        XCTAssertEqual(plan.map(\.id), ["valid"])
    }
    func testReminderStaysAtEightAcrossDaylightSaving() {
        let plan = DueReminder.plan(tasks: [task(date: "2026-10-25")], now: Dates.parse("2026-10-24", calendar: calendar)!, calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: plan[0].date), 8)
        XCTAssertEqual(calendar.component(.day, from: plan[0].date), 25)
    }
    func testReminderLimitKeepsEarliestTasksAndNoOldOffsets() {
        var row = task(); row["reminders"] = .array([.string("1d"), .string("1h")])
        let plan = DueReminder.plan(tasks: [row, task("later", date: "2026-09-07")], now: Dates.parse("2026-09-05", calendar: calendar)!, calendar: calendar, limit: 1)
        XCTAssertEqual(plan.count, 1); XCTAssertEqual(plan[0].id, "one")
        XCTAssertEqual(calendar.component(.hour, from: plan[0].date), 8)
    }
    func testInvalidCalendarDateIsRejected() { XCTAssertNil(Dates.parse("2026-02-31")) }
    func testTabCacheSurvivesRepeatedQueriesAndUnchangedRefresh() {
        let cache = TaskCache(); cache.update([task()])
        let query = TaskQuery(scope: .inbox)
        XCTAssertEqual(cache.matching(query).count, 1)
        _ = cache.matching(TaskQuery(scope: .today, today: "2026-09-06"))
        _ = cache.matching(query); XCTAssertEqual(cache.computationCount, 2)
        XCTAssertFalse(cache.update([task()]))
        _ = cache.matching(query); XCTAssertEqual(cache.computationCount, 2)
    }
    func testTabCacheInvalidatesOnEditAndCompletion() {
        let cache = TaskCache(); cache.update([task()]); let query = TaskQuery(scope: .inbox)
        XCTAssertEqual(cache.matching(query).count, 1)
        var row = task(); row["completed"] = .bool(true)
        cache.update([row]); XCTAssertTrue(cache.matching(query).isEmpty)
        XCTAssertEqual(cache.matching(TaskQuery(scope: .completed)).count, 1)
    }
    func testOAuthOnlyAcceptsExactNativeCallback() throws {
        XCTAssertEqual(try OAuthCallback.code(from: URL(string: "taskfold://auth/callback?code=valid-code")!), "valid-code")
        for url in ["https://taskfold.co/?code=wrong", "taskfold://auth/other?code=wrong", "taskfold://auth/callback?error=denied", "taskfold://auth/callback?code="] {
            XCTAssertThrowsError(try OAuthCallback.code(from: URL(string: url)!))
        }
    }
    func testSessionDerivesExpiryFromSupabaseExpiresIn() throws {
        let start = Date().timeIntervalSince1970
        let data = Data(#"{"access_token":"test","refresh_token":"refresh","expires_in":3600,"user":{"id":"one"}}"#.utf8)
        let session = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertGreaterThanOrEqual(session.expires_at, start + 3600)
        XCTAssertLessThan(session.expires_at, start + 3602)
        let cached = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(cached.expires_at, session.expires_at)
    }
}

final class AuthTransportTests: XCTestCase {
    class Stub: URLProtocol {
        static var handler: ((URLRequest) throws -> (Int, Data))?
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "native-auth.test" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let (status, data) = try Self.handler!(request)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        override func stopLoading() {}
    }
    @MainActor func testRefreshUserHydratesAndPersistsGooglePhoto() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Stub.self]
        let old = try JSONDecoder().decode(Session.self, from: Data(#"{"access_token":"test","refresh_token":"refresh","expires_in":3600,"user":{"id":"one"}}"#.utf8))
        var saved: Session?
        Stub.handler = { request in
            XCTAssertEqual(request.url?.path, "/auth/v1/user")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test")
            return (200, Data(#"{"id":"one","app_metadata":{"provider":"google"},"user_metadata":{"avatar_url":"https://lh3.googleusercontent.com/photo"}}"#.utf8))
        }
        defer { Stub.handler = nil }
        let backend = Backend(configuration: ["URL": "https://native-auth.test", "Key": "public"], http: URLSession(configuration: config), session: old, persistSession: { saved = $0 })
        try await backend.refreshUser()
        XCTAssertEqual(saved?.user.googleAvatarURL?.absoluteString, "https://lh3.googleusercontent.com/photo")
        XCTAssertEqual(saved?.access_token, old.access_token)
        let custom = "https://storage.example.com/custom.jpg"
        XCTAssertEqual(ProfileAvatar.resolved(uploaded: custom, google: saved?.user.googleAvatarURL)?.absoluteString, custom)
        XCTAssertEqual(ProfileAvatar.resolved(uploaded: "", google: saved?.user.googleAvatarURL), saved?.user.googleAvatarURL)
    }

    @MainActor func testNativeSignInPersistsSessionAndDoesNotRefreshForEveryRequest() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Stub.self]
        var saved: Session?; var paths: [String] = []
        Stub.handler = { request in
            paths.append(request.url!.path)
            if request.url!.path == "/auth/v1/token" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, Data(#"{"access_token":"test","refresh_token":"refresh","expires_in":3600,"user":{"id":"one","email":"native@example.com"}}"#.utf8))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test")
            return (200, Data("[]".utf8))
        }
        defer { Stub.handler = nil }
        let backend = Backend(configuration: ["URL": "https://native-auth.test", "Key": "public"], http: URLSession(configuration: config), session: nil, persistSession: { saved = $0 })
        let signedIn = try await backend.signIn(email: "native@example.com", password: "password", signup: false)
        XCTAssertTrue(signedIn); XCTAssertEqual(saved?.user.id, "one")
        _ = try await backend.rows("tasks"); _ = try await backend.rows("projects")
        XCTAssertEqual(paths, ["/auth/v1/token", "/rest/v1/tasks", "/rest/v1/projects"])
    }
    @MainActor func testRejectedCredentialsStayNativeAndNeverCreateSession() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Stub.self]
        Stub.handler = { _ in (400, Data(#"{"msg":"Invalid login credentials"}"#.utf8)) }
        defer { Stub.handler = nil }
        var saved = false
        let backend = Backend(configuration: ["URL": "https://native-auth.test", "Key": "public"], http: URLSession(configuration: config), session: nil, persistSession: { _ in saved = true })
        do { _ = try await backend.signIn(email: "native@example.com", password: "wrong", signup: false); XCTFail("Must reject") }
        catch { XCTAssertEqual(error.localizedDescription, "Invalid login credentials") }
        XCTAssertFalse(saved); XCTAssertNil(backend.session)
    }
    @MainActor func testLiveNativeSignInAndTaskCRUD() async throws {
        guard let path = ProcessInfo.processInfo.environment["TASKFOLD_LIVE_FIXTURE"] else { throw XCTSkip("Live fixture not supplied") }
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let backend = Backend(configuration: ["URL": fixture["url"]!, "Key": fixture["key"]!], session: nil, persistSession: { _ in })
        let signedIn = try await backend.signIn(email: fixture["email"]!, password: fixture["password"]!, signup: false)
        XCTAssertTrue(signedIn)
        XCTAssertEqual(backend.session?.user.id, fixture["userID"])
        var task = Record.task(user: fixture["userID"]!, date: Date().addingTimeInterval(86400)); task["title"] = .string("Native integration verification")
        try await backend.send(Mutation(table: "tasks", recordID: task.id, method: "POST", fields: task.fields))
        let created = try await backend.rows("tasks"); XCTAssertTrue(created.contains { $0.id == task.id })
        try await backend.send(Mutation(table: "tasks", recordID: task.id, method: "PATCH", fields: ["completed": .bool(true)], baseline: ["task_generation": task["task_generation"], "completed": .bool(false), "completion_version": .number(0)]))
        let edited = try await backend.rows("tasks"); XCTAssertEqual(edited.first { $0.id == task.id }?.completed, true)
        try await backend.send(Mutation(table: "tasks", recordID: task.id, method: "DELETE", fields: [:], baseline: try XCTUnwrap(edited.first { $0.id == task.id }).fields))
        let removed = try await backend.rows("tasks"); XCTAssertFalse(removed.contains { $0.id == task.id })
    }
}


final class ProfileAvatarTests: XCTestCase {
    func testLinkedGoogleIdentityAndMetadataSurviveCacheRoundTrip() throws {
        let data = Data(#"{"id":"one","app_metadata":{"provider":"email"},"identities":[{"provider":"google","identity_data":{"picture":"https://lh3.googleusercontent.com/identity"}}],"user_metadata":{"avatar_url":"https://example.com/metadata"}}"#.utf8)
        let user = try JSONDecoder().decode(Session.User.self, from: data)
        let restored = try JSONDecoder().decode(Session.User.self, from: JSONEncoder().encode(user))
        XCTAssertEqual(restored.googleAvatarURL?.absoluteString, "https://lh3.googleusercontent.com/identity")
    }
    func testNonGoogleAndMissingPhotosUseInitials() throws {
        for json in [#"{"id":"one"}"#, #"{"id":"one","app_metadata":{"provider":"email"},"user_metadata":{"avatar_url":"https://example.com/other"}}"#, #"{"id":"one","app_metadata":{"provider":"google"}}"#] {
            let user = try JSONDecoder().decode(Session.User.self, from: Data(json.utf8))
            XCTAssertNil(user.googleAvatarURL)
        }
    }
    func testUnsafeOrEmptyAvatarURLsAreIgnored() {
        for url in ["", "file:///private/photo", "javascript:alert(1)", "http://example.com/photo", "https:"] { XCTAssertNil(ProfileAvatar.url(url)) }
    }
}

/// Companion to the two-Simulator continuity walk. This exercises the Mac-owned
/// transport and decoding without opening the installed Mac app or its Keychain.
final class NativeContinuityTests: XCTestCase {
    @MainActor func testMacTransportReadsTaskCreatedAndEditedOnIOS() async throws {
        guard let path = ProcessInfo.processInfo.environment["TASKFOLD_CONTINUITY_FIXTURE"] else {
            throw XCTSkip("Disposable iOS continuity fixture not supplied")
        }
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let owner = try XCTUnwrap(fixture["userID"])
        XCTAssertNotNil(UUID(uuidString: owner))
        guard fixture["email"] == "taskfold-continuity-" + owner + "@example.invalid" else {
            throw XCTSkip("Requires the disposable continuity account namespace")
        }
        let backend = Backend(configuration: ["URL": try XCTUnwrap(fixture["url"]), "Key": try XCTUnwrap(fixture["key"])], session: nil, persistSession: { _ in })
        let signedIn = try await backend.signIn(email: try XCTUnwrap(fixture["email"]), password: try XCTUnwrap(fixture["password"]), signup: false)
        XCTAssertTrue(signedIn); XCTAssertEqual(backend.session?.user.id, owner)
        let rows = try await backend.rows("tasks")
        XCTAssertEqual(rows.count, 1, "The fixture must contain only the task created through iOS")
        let task = try XCTUnwrap(rows.first)
        XCTAssertEqual(task.title, "Continuity " + String(owner.prefix(8)) + " revised")
        XCTAssertEqual(task.string("user_id"), owner)
        XCTAssertFalse(task.completed)
        XCTAssertFalse(task.string("task_generation").isEmpty)
    }
}
