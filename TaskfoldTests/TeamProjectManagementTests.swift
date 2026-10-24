import XCTest
@testable import TaskfoldCore
private let pmAccount = "ea340000-0000-4000-8000-000000000001", pmTeam = "ea340000-0000-4000-8000-000000000002", pmProject = "ea340000-0000-4000-8000-000000000003", pmMember = "ea340000-0000-4000-8000-000000000004", pmGuest = "ea340000-0000-4000-8000-000000000005", pmOrigin = "https://backend.example"
private final class ProjectCommandIO: CalendarSecureItemIO, @unchecked Sendable {
    let lock = NSLock(); var values: [String: Data] = [:]; var failWrite = false, failRemove = false
    func read(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func write(_ data: Data, key: String) throws { lock.lock(); defer { lock.unlock() }; if failWrite { throw URLError(.cannotWriteToFile) }; values[key] = data }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; if failRemove { throw URLError(.cannotRemoveFile) }; values.removeValue(forKey: key) }
}
@MainActor private final class ProjectCommandPeer: TeamProjectCommandService {
    var calls: [TeamProjectCommand] = [], applied: [String: TeamProjectCommandReceipt] = [:]
    var loseReply = false, foreign = false, hold = false
    var continuation: CheckedContinuation<Void, Never>?
    func teamProjectCommand(_ command: TeamProjectCommand) async throws -> TeamProjectCommandReceipt {
        calls.append(command)
        if hold { await withCheckedContinuation { continuation = $0 } }
        var raw: [String: JSON] = ["protocol": .number(1), "account": .string(foreign ? pmGuest : command.account), "team_id": .string(command.team), "id": .string(command.project), "request_id": .string(command.id), "team_revision": command.body["team_revision"]!, "revision": .number(command.action.creation ? 1 : Double(command.body["revision"]!.integer + 1))]
        if command.action.structural { raw["project_state_protocol"] = .number(1); raw["is_archived"] = .bool(command.action == .archive); raw["ancestor_archived"] = .bool(false); raw["affected_count"] = command.body["affected_count"] }
        if command.action.hierarchical { raw["project_hierarchy_protocol"] = .number(1); raw["parent_id"] = command.body["parent_id"]; raw["affected_count"] = command.body["affected_count"]; raw["is_archived"] = command.body["is_archived"]; raw["ancestor_archived"] = command.body["destination_archived"] }
        let result = applied[command.id] ?? TeamProjectCommandReceipt(raw: raw); applied[command.id] = result
        if loseReply { loseReply = false; throw URLError(.networkConnectionLost) }; return result
    }
}
final class TeamProjectManagementTests: XCTestCase {
    func command(_ action: TeamProjectCommand.Action = .create, now: Date = Date()) throws -> TeamProjectCommand {
        try .init(account: pmAccount, origin: pmOrigin, action: action, team: pmTeam, project: pmProject, teamRevision: 3, revision: action.creation ? nil : 2, name: action.creation || action == .rename ? "Reading room" : nil, visibility: action.creation || action == .settings ? .private : nil, user: [.setAccess, .resetAccess].contains(action) ? pmMember : nil, role: action == .setAccess ? .viewer : nil, review: action.structural ? review(action) : nil, hierarchy: action.hierarchical ? hierarchy(action) : nil, issuedAt: now)
    }
    func hierarchyRaw(_ action: TeamProjectCommand.Action = .move) -> [String: JSON] {
        ["protocol": .number(1), "project_hierarchy_protocol": .number(1), "account": .string(pmAccount), "team_id": .string(pmTeam), "id": .string(pmProject), "operation": .string(action.rawValue), "team_revision": .number(3), "revision": action.creation ? .null : .number(2), "parent_id": .string(pmMember), "parent_revision": .number(5), "tree_token": .string(String(repeating: "b", count: 64)), "affected_count": .number(action.creation ? 1 : 4), "destination_archived": .bool(true), "is_archived": .bool(false)]
    }
    func hierarchy(_ action: TeamProjectCommand.Action = .move, raw: [String: JSON]? = nil) throws -> TeamProjectHierarchyReview {
        try .init(raw ?? hierarchyRaw(action), account: pmAccount, origin: pmOrigin, team: pmTeam, project: pmProject, action: action)
    }
    func reviewRaw(_ action: TeamProjectCommand.Action = .archive) -> [String: JSON] {
        ["protocol": .number(1), "project_state_protocol": .number(1), "account": .string(pmAccount), "team_id": .string(pmTeam), "id": .string(pmProject), "operation": .string(action.rawValue), "team_revision": .number(3), "revision": .number(2), "tree_token": .string(String(repeating: "a", count: 64)), "affected_count": .number(4), "is_archived": .bool(action == .unarchive), "ancestor_archived": .bool(false)]
    }
    func review(_ action: TeamProjectCommand.Action = .archive, raw: [String: JSON]? = nil) throws -> TeamProjectStructureReview { try .init(raw ?? reviewRaw(action), account: pmAccount, origin: pmOrigin, team: pmTeam, project: pmProject, action: action) }
    func raw(_ role: String = "manager", visibility: String = "team", paused: Bool = false, grant: String = "viewer") -> [String: JSON] {
        var raw: [String: JSON] = ["protocol": .number(1), "account": .string(pmAccount), "team_id": .string(pmTeam), "id": .string(pmProject), "team_revision": .number(3), "revision": .number(2), "team_state": .string("active"), "setup_paused": .bool(paused), "role": .string(role), "visibility": .string(visibility), "folder_id": .null, "name": .string("Reading room"), "can_edit_tasks": .bool(false), "can_manage_access": .bool(role == "manager")]
        if role == "manager" {
            raw["eligible_members"] = .array([(pmAccount,"owner"),(pmMember,"member"),(pmGuest,"guest")].map { .object(["user_id": .string($0.0), "role": .string($0.1), "display_name": .string("Sam Chen")]) })
            raw["grants"] = .array([.object(["user_id": .string(pmMember), "role": .string(grant)]), .object(["user_id": .string(pmGuest), "role": .string("viewer")])])
        }
        return raw
    }
    func detail(_ raw: [String: JSON]? = nil) throws -> TeamProjectManagementDetail { try .init(raw ?? self.raw(), account: pmAccount, origin: pmOrigin, team: pmTeam, project: pmProject) }
    func team() throws -> TeamOrganizationDetail { try .init(["id": .string(pmTeam), "name": .string("Studio"), "role": .string("owner"), "state": .string("active"), "revision": .number(3), "folders": .array([]), "members": .array([.object(["user_id": .string(pmAccount), "role": .string("owner")])]), "invitations": .array([])], team: pmTeam, account: pmAccount, origin: pmOrigin) }
    func page(_ row: [String: JSON]? = nil) throws -> TeamProjectPage {
        var p = raw(); p["projects"] = .array([.object(row ?? raw())]); p["next_cursor"] = .null; p["task_writes_enabled"] = .bool(false)
        return try .init(p, account: pmAccount, origin: pmOrigin, team: pmTeam, after: nil)
    }
    func testNineActionsHaveExactStableBodiesAndPrivateRoundTrip() throws {
        for action in TeamProjectCommand.Action.allCases {
            let command = try command(action), restored = try JSONDecoder().decode(TeamProjectCommand.self, from: JSONEncoder().encode(command))
            XCTAssertEqual(command, restored); XCTAssertEqual(command.id, restored.id)
            var wrong = command.body; wrong["display_name"] = .string("unreviewed")
            XCTAssertThrowsError(try TeamProjectCommand(account: pmAccount, origin: pmOrigin, action: action, body: wrong))
            wrong = command.body; wrong.removeValue(forKey: "team_revision")
            XCTAssertThrowsError(try TeamProjectCommand(account: pmAccount, origin: pmOrigin, action: action, body: wrong))
            XCTAssertEqual(String(describing: command), "Private project administration request")
        }
    }
    func testMalformedTimeScopeRoleFolderAndRevisionsCannotBecomeCommands() throws {
        let command = try command(.setAccess)
        for change in [["role": JSON.string("owner")], ["revision": .number(1.5)], ["team_revision": .number(0)], ["issued_at": .string("2030-01-01T10:00:00+02:00")], ["project_id": .string("personal")], ["user_id": .null]] {
            XCTAssertThrowsError(try TeamProjectCommand(account: pmAccount, origin: pmOrigin, action: .setAccess, body: command.body.merging(change) { _, b in b }))
        }
        XCTAssertThrowsError(try TeamProjectCommand(account: pmAccount, origin: "https://other.example/path", action: command.action, body: command.body))
        XCTAssertThrowsError(try TeamProjectCommand(account: pmAccount, origin: pmOrigin, action: .settings, team: pmTeam, project: pmProject, teamRevision: 3, revision: 2, visibility: .private, folder: "bad"))
        XCTAssertThrowsError(try TeamProjectCommand(account: pmAccount, origin: pmOrigin, action: .resetAccess, team: pmTeam, project: pmProject, teamRevision: 3, revision: 2, folder: pmMember, user: pmMember))
        let old = try self.command(now: Date(timeIntervalSince1970: 1000)); XCTAssertFalse(old.canRetry)
    }
    func testSQLLegacyReceiptsCoverFourActionsAndActualManagerDirectory() throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "team-project-commands-v1", withExtension: "json", subdirectory: "Fixtures"))
        let rows = try JSONDecoder().decode([[String: JSON]].self, from: Data(contentsOf: file)); var actions = Set<String>()
        for row in rows {
            let action = try XCTUnwrap(TeamProjectCommand.Action(rawValue: row["action"]!.text)); actions.insert(action.rawValue)
            let command = try TeamProjectCommand(account: row["account"]!.text, origin: pmOrigin, action: action, body: row["body"]!.object)
            XCTAssertEqual(try command.confirmed(row["result"]!.object).project, command.project)
            var foreign = row["result"]!.object; foreign["account"] = .string(pmGuest)
            XCTAssertThrowsError(try command.confirmed(foreign))
        }
        XCTAssertEqual(actions, Set(["create", "settings", "set_access", "reset_access"]))
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-project-management-v1", withExtension: "json", subdirectory: "Fixtures"))
        let value = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        let directory = try TeamProjectManagementDetail(value["management"]!.object, account: value["managerAccount"]!.text, origin: pmOrigin, team: value["team"]!.text, project: value["project"]!.text)
        XCTAssertEqual(directory.access.name, "team project"); XCTAssertEqual(directory.members.count, 7); XCTAssertTrue(directory.members.allSatisfy { $0.verifiedEmail == nil })
    }
    func testResetNeverMistakesTeamDefaultForRevocation() throws {
        let normal = try detail(), member = normal.members[1], guest = normal.members[2]
        XCTAssertEqual(normal.effective(member), .viewer); XCTAssertTrue(normal.canReset(member)); XCTAssertTrue(normal.canReset(guest))
        XCTAssertTrue(normal.resetDescription(member).contains("Editor")); XCTAssertTrue(normal.resetDescription(guest).contains("lose access"))
        let paused = try detail(raw(paused: true)); XCTAssertFalse(paused.canReset(paused.members[1])); XCTAssertTrue(paused.canReset(paused.members[2]))
        let pausedManager = try detail(raw(paused: true, grant: "manager")); XCTAssertTrue(pausedManager.canReset(pausedManager.members[1]))
        let privatePaused = try detail(raw(visibility: "private", paused: true)); XCTAssertTrue(privatePaused.canReset(privatePaused.members[1]))
        XCTAssertFalse(normal.canReset(normal.members[0])); XCTAssertTrue(normal.roles(for: normal.members[0]).isEmpty)
        XCTAssertEqual(normal.roles(for: guest), [.editor, .viewer]); XCTAssertTrue(paused.roles(for: paused.members[1]).isEmpty)
    }
    func testManagerDirectoryCannotLeakThroughLowerRolesOrAcceptDuplicates() throws {
        for role in ["editor", "viewer"] {
            var value = raw(role); value["eligible_members"] = .array([]); XCTAssertThrowsError(try detail(value))
            value = raw(role); value["grants"] = .array([]); XCTAssertThrowsError(try detail(value))
        }
        var value = raw(); value["eligible_members"] = .array(value["eligible_members"]!.list + value["eligible_members"]!.list); XCTAssertThrowsError(try detail(value))
        value = raw(); value["eligible_members"] = .array([]); XCTAssertThrowsError(try detail(value))
        value = raw(); value["eligible_members"] = .array([.object(["user_id": .string(pmAccount), "role": .string("owner"), "verified_email": .string("private@example.invalid")])]); XCTAssertThrowsError(try detail(value))
    }
    @MainActor func testLostReplySurvivesRelaunchAndReusesSameProjectRequest() async throws {
        let io = ProjectCommandIO(), vault = TeamProjectCommandVault(io: io), peer = ProjectCommandPeer(); peer.loseReply = true
        var model = TeamProjectCommandModel(account: pmAccount, origin: pmOrigin, vault: vault, service: peer, isCurrent: { true })
        let command = try command(); await model.send(command); XCTAssertEqual(model.pending, command); XCTAssertEqual(peer.applied.count, 1)
        model.close(); model = TeamProjectCommandModel(account: pmAccount, origin: pmOrigin, vault: vault, service: peer, isCurrent: { true }); await model.load(); await model.retry()
        XCTAssertNil(model.pending); XCTAssertEqual(peer.calls, [command, command]); XCTAssertEqual(peer.applied.count, 1); XCTAssertNotNil(model.receipt)
    }
    @MainActor func testPrivateWriteFailurePreventsSendAndClearFailureRetainsIntent() async throws {
        let io = ProjectCommandIO(), vault = TeamProjectCommandVault(io: io), peer = ProjectCommandPeer()
        let model = TeamProjectCommandModel(account: pmAccount, origin: pmOrigin, vault: vault, service: peer, isCurrent: { true })
        io.failWrite = true; await model.send(try command()); XCTAssertTrue(peer.calls.isEmpty)
        io.failWrite = false; io.failRemove = true; let command = try command(); await model.send(command); XCTAssertEqual(model.pending, command)
        io.failRemove = false; await model.retry(); XCTAssertNil(model.pending); XCTAssertEqual(peer.applied.count, 1)
    }
    @MainActor func testLateForeignAndAccountChangedRepliesCannotClearJournal() async throws {
        let io = ProjectCommandIO(), vault = TeamProjectCommandVault(io: io), peer = ProjectCommandPeer(); var current = true
        let model = TeamProjectCommandModel(account: pmAccount, origin: pmOrigin, vault: vault, service: peer, isCurrent: { current })
        let command = try command(); peer.hold = true
        let task = Task { await model.send(command) }; while peer.continuation == nil { await Task.yield() }
        current = false; model.close(); peer.continuation?.resume(); await task.value
        let saved = try await vault.pending(account: pmAccount, origin: pmOrigin); XCTAssertEqual(saved, command); XCTAssertNil(model.receipt)
        peer.hold = false; peer.foreign = true; peer.applied = [:]
        let retry = TeamProjectCommandModel(account: pmAccount, origin: pmOrigin, vault: vault, service: peer, isCurrent: { true }); await retry.load(); await retry.retry()
        XCTAssertEqual(retry.pending, command); XCTAssertNil(retry.receipt)
    }
    func testProjectAndTeamJournalsCannotReplaceOrClearOneAnother() async throws {
        let io = ProjectCommandIO(), team = TeamOrganizationCommandVault(io: io), project = TeamProjectCommandVault(io: io), lease = CalendarReadLease()
        let org = try TeamOrganizationCommand(account: pmAccount, origin: pmOrigin, action: .create, team: pmTeam, name: "Studio")
        let command = try command(); try await team.begin(org, lease: lease); try await project.begin(command, lease: lease)
        XCTAssertEqual(io.values.count, 2); try await project.removeAccount(pmAccount, origin: pmOrigin)
        let savedTeam = try await team.pending(account: pmAccount, origin: pmOrigin), savedProject = try await project.pending(account: pmAccount, origin: pmOrigin)
        XCTAssertEqual(savedTeam, org); XCTAssertNil(savedProject)
    }
    @MainActor func testAccessFenceChangeAndLateAccountReadNeverPublishProjectNames() async throws {
        var calls = 0, current = true
        let browser = TeamProjectBrowser(account: pmAccount, origin: pmOrigin, team: pmTeam, current: { current }, fence: { calls += 1; return String(repeating: calls == 1 ? "a" : "b", count: 64) }, readTeam: { try self.team() }, page: { _ in try self.page() }, detail: { _ in try self.detail() })
        await browser.refresh(); XCTAssertTrue(browser.projects.isEmpty); XCTAssertNotNil(browser.message)
        var suspended: CheckedContinuation<TeamProjectManagementDetail, Never>?
        let late = TeamProjectBrowser(account: pmAccount, origin: pmOrigin, team: pmTeam, current: { current }, fence: { String(repeating: "a", count: 64) }, readTeam: { try self.team() }, page: { _ in try self.page() }, detail: { _ in await withCheckedContinuation { suspended = $0 } })
        let task = Task { await late.refresh(project: pmProject) }; while suspended == nil { await Task.yield() }; current = false; late.invalidate(); suspended?.resume(returning: try detail()); await task.value
        XCTAssertNil(late.detail); XCTAssertNil(late.team); XCTAssertTrue(late.projects.isEmpty)
    }
    func testArchiveStatusIsVersionedAndOldServicesRemainUnknown() throws {
        XCTAssertNil(try detail().access.archive)
        for own in [false, true] { for inherited in [false, true] {
            var value = raw(); value["project_state_protocol"] = .number(1); value["is_archived"] = .bool(own); value["ancestor_archived"] = .bool(inherited)
            let state = try XCTUnwrap(detail(value).access.archive)
            XCTAssertEqual(state.effective, own || inherited); XCTAssertEqual(state.own, own); XCTAssertEqual(state.inherited, inherited)
        } }
        for change: [String: JSON] in [["is_archived": .bool(false)], ["project_state_protocol": .number(2), "is_archived": .bool(false), "ancestor_archived": .bool(false)], ["project_state_protocol": .number(1), "is_archived": .string("false"), "ancestor_archived": .bool(false)]] {
            XCTAssertThrowsError(try detail(raw().merging(change) { _, b in b }))
        }
    }
    func testBranchReviewRejectsWrongScopeOperationBoundsAndProjection() throws {
        for change: [String: JSON] in [["account": .string(pmGuest)], ["team_id": .string(pmMember)], ["id": .string(pmMember)], ["operation": .string("unarchive")], ["revision": .number(0)], ["team_revision": .number(1.5)], ["tree_token": .string("A" + String(repeating: "a", count: 63))], ["affected_count": .number(1001)], ["affected_count": .number(1.1)], ["affected_count": .string("4")], ["is_archived": .bool(true)], ["project_state_protocol": .null]] {
            XCTAssertThrowsError(try review(raw: reviewRaw().merging(change) { _, b in b }))
        }
        var inherited = reviewRaw(.unarchive); inherited["ancestor_archived"] = .bool(true); XCTAssertThrowsError(try review(.unarchive, raw: inherited))
        XCTAssertThrowsError(try review(.rename))
    }
    func testReviewedBranchCannotBeReusedForAnotherProjectAccountOrRevision() throws {
        let reviewed = try review()
        for (account, project, revision, action) in [(pmGuest,pmProject,2.0,TeamProjectCommand.Action.archive),(pmAccount,pmMember,2.0,.archive),(pmAccount,pmProject,3.0,.archive),(pmAccount,pmProject,2.0,.unarchive)] {
            XCTAssertThrowsError(try TeamProjectCommand(account: account, origin: pmOrigin, action: action, team: pmTeam, project: project, teamRevision: 3, revision: revision, review: reviewed))
        }
        XCTAssertThrowsError(try TeamProjectCommand(account: pmAccount, origin: pmOrigin, action: .rename, team: pmTeam, project: pmProject, teamRevision: 3, revision: 2, name: "New", review: reviewed))
    }
    func testActualSQLBranchReviewsAndThreeMetadataReceipts() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-project-archiving-v1", withExtension: "json", subdirectory: "Fixtures"))
        let value = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url)); var actions = Set<String>()
        for row in value["reviews"]!.list.map(\.object) {
            let action = try XCTUnwrap(TeamProjectCommand.Action(rawValue: row["body"]!.object["operation"]!.text)), result = row["result"]!.object
            let reviewed = try TeamProjectStructureReview(result, account: row["account"]!.text, origin: pmOrigin, team: result["team_id"]!.text, project: result["id"]!.text, action: action)
            XCTAssertTrue((1...1000).contains(reviewed.count))
        }
        for row in value["commands"]!.list.map(\.object) {
            let action = try XCTUnwrap(TeamProjectCommand.Action(rawValue: row["action"]!.text)); actions.insert(action.rawValue)
            let command = try TeamProjectCommand(account: row["account"]!.text, origin: pmOrigin, action: action, body: row["body"]!.object)
            XCTAssertEqual(try command.confirmed(row["result"]!.object).project, command.project)
            if action.structural {
                for change: [String: JSON] in [["affected_count": .number(1001)], ["project_state_protocol": .number(2)], ["is_archived": .bool(action != .archive)], ["ancestor_archived": .string("false")]] {
                    XCTAssertThrowsError(try command.confirmed(row["result"]!.object.merging(change) { _, b in b }))
                }
            }
        }
        XCTAssertEqual(actions, ["rename", "archive", "unarchive"])
    }
    @MainActor func testLostArchiveReplyRetainsReviewedBranchAcrossRelaunch() async throws {
        let io = ProjectCommandIO(), vault = TeamProjectCommandVault(io: io), peer = ProjectCommandPeer(); peer.loseReply = true
        let command = try command(.archive)
        var model = TeamProjectCommandModel(account: pmAccount, origin: pmOrigin, vault: vault, service: peer, isCurrent: { true })
        await model.send(command); XCTAssertEqual(model.pending, command); XCTAssertNil(model.receipt)
        model.close(); model = TeamProjectCommandModel(account: pmAccount, origin: pmOrigin, vault: vault, service: peer, isCurrent: { true })
        await model.load(); await model.retry()
        XCTAssertEqual(peer.calls, [command, command]); XCTAssertEqual(peer.applied.count, 1); XCTAssertNil(model.pending); XCTAssertEqual(model.success, "Project archived")
    }

    func testHierarchyReviewRejectsPartialMalformedOrCrossScopeValues() throws {
        for action: TeamProjectCommand.Action in [.move, .createSubproject] {
            let original = hierarchyRaw(action)
            for key in original.keys { var value = original; value.removeValue(forKey: key); XCTAssertThrowsError(try hierarchy(action, raw: value), key) }
            for patch: [String: JSON] in [["project_hierarchy_protocol": .number(2)], ["account": .string(pmGuest)], ["team_id": .string(pmGuest)], ["id": .string(pmGuest)], ["operation": .string("rename")], ["parent_id": .string(pmProject)], ["parent_revision": .number(0)], ["tree_token": .string("unreviewed")], ["affected_count": .number(1001)], ["affected_count": .number(1.5)], ["destination_archived": .string("true")], ["is_archived": .number(0)]] {
                XCTAssertThrowsError(try hierarchy(action, raw: original.merging(patch) { _, b in b }))
            }
        }
        for patch: [String: JSON] in [["revision": .number(1)], ["affected_count": .number(2)], ["is_archived": .bool(true)], ["parent_id": .null, "parent_revision": .null, "destination_archived": .bool(false)]] {
            XCTAssertThrowsError(try hierarchy(.createSubproject, raw: hierarchyRaw(.createSubproject).merging(patch) { _, b in b }))
        }
        let top: [String: JSON] = ["parent_id": .null, "parent_revision": .null, "destination_archived": .bool(false)]
        XCTAssertNil(try hierarchy(raw: hierarchyRaw().merging(top) { _, b in b }).parent)
        for patch: [String: JSON] in [["parent_id": .null], ["parent_id": .null, "parent_revision": .null]] {
            XCTAssertThrowsError(try hierarchy(raw: hierarchyRaw().merging(patch) { _, b in b }))
        }
    }
    func testHierarchyReviewCannotBeReusedAcrossAccountProjectActionOrRevision() throws {
        let reviewed = try hierarchy()
        for (account, origin, team, project, revision, action) in [(pmGuest,pmOrigin,pmTeam,pmProject,2.0,TeamProjectCommand.Action.move),(pmAccount,"https://other.example",pmTeam,pmProject,2.0,.move),(pmAccount,pmOrigin,pmGuest,pmProject,2.0,.move),(pmAccount,pmOrigin,pmTeam,pmGuest,2.0,.move),(pmAccount,pmOrigin,pmTeam,pmProject,3.0,.move),(pmAccount,pmOrigin,pmTeam,pmProject,2.0,.archive)] {
            XCTAssertThrowsError(try TeamProjectCommand(account: account, origin: origin, action: action, team: team, project: project, teamRevision: 3, revision: revision, hierarchy: reviewed))
        }
        XCTAssertThrowsError(try TeamProjectCommand(account: pmAccount, origin: pmOrigin, action: .move, team: pmTeam, project: pmProject, teamRevision: 4, revision: 2, hierarchy: reviewed))
        for action: TeamProjectCommand.Action in [.move, .createSubproject] {
            let original = try command(action)
            for patch: [String: JSON] in [["parent_id": .string(pmProject)], ["affected_count": .number(0)], ["parent_revision": .null], ["is_archived": .string("false")], ["destination_archived": .null], ["tree_token": .string("B".padding(toLength: 64, withPad: "B", startingAt: 0))]] {
                XCTAssertThrowsError(try TeamProjectCommand(account: pmAccount, origin: pmOrigin, action: action, body: original.body.merging(patch) { _, b in b }))
            }
        }
    }
    func testHierarchyProjectionIsOptionalButCannotPublishPartialOrHiddenParentIdentity() throws {
        XCTAssertNil(try detail().access.hierarchy)
        let group: [String: JSON] = ["project_hierarchy_protocol": .number(1), "parent_id": .string(pmMember), "parent_unavailable": .bool(false)]
        XCTAssertEqual(try detail(raw().merging(group) { _, b in b }).access.hierarchy?.parent, pmMember)
        XCTAssertEqual(try detail(raw().merging(group.merging(["parent_id": .null, "parent_unavailable": .bool(true)]) { _, b in b }) { _, b in b }).access.hierarchy?.parentUnavailable, true)
        for key in group.keys { var patch = group; patch.removeValue(forKey: key); XCTAssertThrowsError(try detail(raw().merging(patch) { _, b in b })) }
        for patch: [String: JSON] in [["parent_unavailable": .bool(true)], ["parent_id": .string(pmProject)], ["project_hierarchy_protocol": .number(2)]] {
            XCTAssertThrowsError(try detail(raw().merging(group.merging(patch) { _, b in b }) { _, b in b }))
        }
    }
    func testActualSQLHierarchyReviewsAndReceipts() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-project-hierarchy-v1", withExtension: "json", subdirectory: "Fixtures"))
        let value = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url)); var actions = Set<String>()
        for row in value["reviews"]!.list.map(\.object) {
            let action = try XCTUnwrap(TeamProjectCommand.Action(rawValue: row["body"]!.object["operation"]!.text)), result = row["result"]!.object
            let reviewed = try TeamProjectHierarchyReview(result, account: row["account"]!.text, origin: pmOrigin, team: result["team_id"]!.text, project: result["id"]!.text, action: action)
            XCTAssertEqual(reviewed.parent, try TeamProjectValue.optionalID(row["body"]!.object["parent_id"]))
        }
        for row in value["commands"]!.list.map(\.object) {
            let action = try XCTUnwrap(TeamProjectCommand.Action(rawValue: row["action"]!.text)); actions.insert(action.rawValue)
            let command = try TeamProjectCommand(account: row["account"]!.text, origin: pmOrigin, action: action, body: row["body"]!.object)
            XCTAssertEqual(try command.confirmed(row["result"]!.object).project, command.project)
            for patch: [String: JSON] in [["project_hierarchy_protocol": .number(2)], ["parent_id": .string(command.project)], ["affected_count": .number(1001)], ["is_archived": .string("false")], ["ancestor_archived": .string("true")]] {
                XCTAssertThrowsError(try command.confirmed(row["result"]!.object.merging(patch) { _, b in b }))
            }
        }
        XCTAssertEqual(actions, ["move", "create_subproject"])
    }
    @MainActor func testLostHierarchyRepliesKeepExactDestinationAcrossRelaunch() async throws {
        for action: TeamProjectCommand.Action in [.move, .createSubproject] {
            let io = ProjectCommandIO(), vault = TeamProjectCommandVault(io: io), peer = ProjectCommandPeer(); peer.loseReply = true
            let command = try command(action)
            var model = TeamProjectCommandModel(account: pmAccount, origin: pmOrigin, vault: vault, service: peer, isCurrent: { true })
            await model.send(command); XCTAssertEqual(model.pending, command); XCTAssertNil(model.receipt)
            model.close(); model = TeamProjectCommandModel(account: pmAccount, origin: pmOrigin, vault: vault, service: peer, isCurrent: { true })
            await model.load(); await model.retry()
            XCTAssertEqual(peer.calls, [command, command]); XCTAssertEqual(peer.applied.count, 1); XCTAssertNil(model.pending); XCTAssertEqual(model.success, action.success)
        }
    }

}
