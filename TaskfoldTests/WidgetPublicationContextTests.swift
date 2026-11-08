import XCTest
@testable import TaskfoldCore

final class WidgetPublicationContextTests: XCTestCase {
    private let account = "owner"
    private func fixture() -> Snapshot {
        let projects = [Record(["id": .string("a"), "user_id": .string(account), "name": .string("Studio")]),
                        Record(["id": .string("b"), "user_id": .string("other"), "name": .string("Shared")])]
        func member(_ project: String, _ id: String, _ name: String, _ status: String = "accepted") -> Record {
            Record(["project_id": .string(project), "user_id": .string(id), "display_name": .string(name), "status": .string(status)])
        }
        var value = Snapshot(tables: ["projects": projects,
            "tasks": [Record(["id": .string("task"), "title": .string("Review"), "user_id": .string(account), "project_id": .string("a"), "completed": .bool(false)])],
            "project_collaborators": [member("a", "older", "Older directory"), member("b", "member", "Current member"), member("b", "invited", "Pending", "pending")],
            "profiles": [Record(["user_id": .string(account), "display_name": .string("Current person"), "avatar_url": .string("private-avatar")])]])
        WidgetCompletion.prepare(&value); return value
    }
    /// The previous Store path, including repeated per-project filtering and
    /// authoritative loaded directories. Used as a semantic/timing reference.
    private func previous(_ source: Snapshot, projects: [Record], local: Bool = false, mask: TeamWorkspaceCache? = nil) -> WidgetPublicationInput {
        var value = WidgetPublicationInput(tasks: source.tables["tasks"] ?? [], projects: projects, account: account)
        value.completionTokens = mask?.widgetTokens(source) ?? WidgetCompletion.tokens(source)
        let profile = source.tables["profiles"]?.first { $0.string("user_id") == account } ?? Record()
        // Store's record-read cache already indexes projects. Do not inflate
        // the old-directory timing with an unrelated repeated project scan.
        let indexed = Dictionary((source.tables["projects"] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        value.people = projects.flatMap { shown -> [Record] in
            guard let project = indexed[shown.id] else { return [] }
            let members = source.tables["project_members:" + shown.id] ?? (source.tables["project_collaborators"] ?? []).filter { $0.string("project_id") == shown.id }
            return TaskAssignment.members(project: project, collaborators: members, currentUser: account, profile: profile).map { person in
                var scoped = person; scoped["project_id"] = .string(shown.id); return scoped
            }
        }
        value.assignments = .init(source.tables[TaskAssignmentProvenance.table] ?? (local ? [] : nil), localAccount: local ? account : nil)
        return value
    }
    private func context(_ source: Snapshot, local: Bool = false, mask: TeamWorkspaceCache? = nil) -> WidgetPublicationContext {
        .init(snapshot: source, account: account, localAccount: local ? account : nil, tokenMask: mask)
    }
    func testMemberPrecedenceScopingProfileAndFullProjectionMatchPrevious() throws {
        var source = fixture(); source.tables["project_members:a"] = []
        let projects = [source.tables["projects"]![1], source.tables["projects"]![0]]
        var before = previous(source, projects: projects), captured = WidgetPublicationInput(tasks: source.tables["tasks"]!, projects: projects, account: account)
        captured.now = before.now; captured.context = context(source)
        let prepared = try captured.context!.prepare(captured)
        XCTAssertEqual(prepared.people, before.people)
        XCTAssertFalse(prepared.people.contains { $0.id == "older" || $0.id == "invited" })
        XCTAssertEqual(prepared.people.first { $0.id == account }?.string("display_name"), "Current person")
        XCTAssertEqual(prepared.people.first { $0.id == account }?.string("project_id"), "a")
        XCTAssertEqual(prepared.completionTokens, before.completionTokens)
        XCTAssertEqual(prepared.assignments, before.assignments)
        XCTAssertNil(prepared.context)
        let now = before.now
        let feedback = WidgetCompletionFeedback(account: account, taskID: "task", title: "Review", listIDs: ["inbox"], savedAt: now)
        before.feedback = feedback; captured.feedback = feedback
        XCTAssertEqual(try JSONDecoder().decode(JSON.self, from: captured.encoded()), try JSONDecoder().decode(JSON.self, from: before.encoded()))
    }
    func testLoadedMemberRowsOverrideStaleCollaboratorsAndAccountChangesRefuse() throws {
        var source = fixture(); source.tables["project_members:b"] = [Record(["user_id": .string("member"), "display_name": .string("Fresh name"), "status": .string("accepted")])]
        var input = WidgetPublicationInput(tasks: [], projects: source.tables["projects"]!, account: account); input.context = context(source)
        XCTAssertEqual(try input.context!.prepare(input).people.first { $0.id == "member" }?.string("display_name"), "Fresh name")
        input.account = "different"
        XCTAssertThrowsError(try input.encoded())
        input.account = ""
        XCTAssertEqual(try JSONDecoder().decode(JSON.self, from: input.encoded()), .object(["version": .number(2), "updated": .number(0), "account": .string(""), "tasks": .array([])]))
    }
    func testCapturedValuesRemainIndependentAndNewContextSeesChanges() throws {
        var source = fixture()
        var input = WidgetPublicationInput(tasks: source.tables["tasks"]!, projects: source.tables["projects"]!, account: account); input.context = context(source)
        let original = try input.context!.prepare(input)
        source.tables["profiles"]![0]["display_name"] = .string("Renamed")
        source.widgetCompletion.states["task"]!.token = "new-token"
        source.tables["project_members:b"] = []
        XCTAssertEqual(try input.context!.prepare(input).people, original.people)
        XCTAssertEqual(try input.context!.prepare(input).completionTokens, original.completionTokens)
        let current = try context(source).prepare(input)
        XCTAssertNotEqual(current.people, original.people); XCTAssertEqual(current.completionTokens["task"], "new-token")
        XCTAssertFalse(current.people.contains { $0.id == "member" })
    }
    func testLocalEmptyAssignmentHistoryStaysDistinctFromUnavailableCloudHistory() throws {
        let source = fixture(), input = WidgetPublicationInput(tasks: [], projects: [], account: account)
        XCTAssertEqual(try context(source).prepare(input).assignments, .init(nil))
        XCTAssertEqual(try context(source, local: true).prepare(input).assignments, .init([], localAccount: account))
        XCTAssertNotEqual(try context(source).prepare(input).assignments, try context(source, local: true).prepare(input).assignments)
    }
    func testTeamTokensRetainTheExistingMask() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-workspace-boundary-v1", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url)), account = fixture["account"]!.text
        let boundary = try TeamWorkspaceBoundary(fixture["active"]!.object, account: account, origin: "https://backend.example")
        var source = Snapshot(tables: ["tasks": [Record.task(user: account, project: fixture["project"]!.text), Record.task(user: account, project: fixture["personal"]!.text)]])
        WidgetCompletion.prepare(&source)
        let mask = try TeamWorkspaceCache(boundary: boundary, previous: nil, pending: [], tasks: source.tables["tasks"]!)
        let context = WidgetPublicationContext(snapshot: source, account: account, localAccount: nil, tokenMask: mask)
        let prepared = try context.prepare(WidgetPublicationInput(tasks: source.tables["tasks"]!, projects: [], account: account))
        XCTAssertEqual(prepared.completionTokens, mask.widgetTokens(source)); XCTAssertEqual(prepared.completionTokens.count, 1)
    }
    func testLargeDirectoryDiagnosticPreservesEveryMemberWithoutRepeatedScans() throws {
        let projects = (0..<1000).map { Record(["id": .string("p\($0)"), "user_id": .string(account), "name": .string("Project \($0)")]) }
        let members = (0..<3000).map { Record(["project_id": .string("p\($0 / 3)"), "user_id": .string("member\($0)"), "display_name": .string("Person \($0)"), "status": .string("accepted")]) }
        let source = Snapshot(tables: ["projects": projects, "project_collaborators": members])
        let clock = ContinuousClock(), oldStart = clock.now
        let before = previous(source, projects: projects), oldTime = oldStart.duration(to: clock.now)
        let captureStart = clock.now
        let captured = context(source), input = WidgetPublicationInput(tasks: [], projects: projects, account: account)
        let captureTime = captureStart.duration(to: clock.now), prepareStart = clock.now
        let result = try captured.prepare(input), newTime = prepareStart.duration(to: clock.now)
        XCTAssertEqual(result.people, before.people); XCTAssertEqual(result.people.count, 4000)
        func seconds(_ value: Duration) -> Double { Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18 }
        print("WIDGET_CONTEXT_DIAGNOSTIC " + String(data: try JSONSerialization.data(withJSONObject: ["projects": 1000, "members": 3000, "previousPreparationSeconds": seconds(oldTime), "captureSeconds": seconds(captureTime), "indexedWorkerPreparationSeconds": seconds(newTime)], options: .sortedKeys), encoding: .utf8)!)
    }
}
