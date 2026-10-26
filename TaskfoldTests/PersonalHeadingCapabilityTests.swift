import XCTest
@testable import TaskfoldCore

final class PersonalHeadingCapabilityTests: XCTestCase {
    let account = "f6310000-0000-4000-8000-000000000001"
    let origin = "https://personal.example"
    func boundary(_ protocolValue: JSON? = .number(1)) throws -> TeamWorkspaceBoundary {
        var raw: [String: JSON] = ["workspace_boundary_protocol": .number(1), "account": .string(account),
            "native_team_reads_enabled": .bool(false), "setup_paused": .bool(true), "projects": .array([]), "teams": .array([]), "token": .string(String(repeating: "a", count: 64))]
        raw["personal_task_types_protocol"] = protocolValue
        return try TeamWorkspaceBoundary(raw, account: account, origin: origin)
    }
    func task() -> Record { var row = Record.task(user: account); row["task_generation"] = .string(UUID().uuidString.lowercased()); row["completion_version"] = .number(0); return row }
    func typeEdit(_ row: Record, heading: Bool = true) -> Mutation {
        let fields: [String: JSON] = ["is_heading": .bool(heading)]
        return Mutation(table: "tasks", recordID: row.id, method: "PATCH", fields: fields, baseline: TaskCompletionRevision.editBaseline(for: fields, from: row))
    }
    func testPersonalSupportIsExactAndIndependentOfTeamRollout() throws {
        let supported = try boundary()
        XCTAssertTrue(PersonalTaskTypes.authoringAvailable(boundary: supported, account: account, origin: origin, enabled: true))
        for value: JSON? in [nil, .null, .number(0), .number(2), .string("1"), .bool(true)] {
            XCTAssertFalse(PersonalTaskTypes.authoringAvailable(boundary: try boundary(value), account: account, origin: origin, enabled: true))
        }
        XCTAssertFalse(PersonalTaskTypes.authoringAvailable(boundary: supported, account: account, origin: origin, enabled: false))
        XCTAssertFalse(PersonalTaskTypes.authoringAvailable(boundary: supported, account: UUID().uuidString.lowercased(), origin: origin, enabled: true))
        XCTAssertFalse(PersonalTaskTypes.authoringAvailable(boundary: supported, account: account, origin: "https://another.example", enabled: true))
        XCTAssertFalse(PersonalTaskTypes.authoringAvailable(boundary: supported, account: account, origin: nil, enabled: true))
        XCTAssertFalse(PersonalTaskTypes.authoringAvailable(boundary: nil, account: account, origin: origin, enabled: true))
    }
    func testRootQueueUsesCompatibilityForExplicitTypesAndNoLegacyFallback() throws {
        let original = task(), edit = typeEdit(original)
        for change in [edit, Mutation(table: "tasks", recordID: original.id, method: "POST", fields: try TaskKind.setting(original, heading: true).fields), typeEdit(try TaskKind.setting(original, heading: true), heading: false)] {
            XCTAssertTrue(PersonalTaskTypes.requiresService(change))
            XCTAssertTrue(PersonalTaskTypes.canSend(change, boundary: try boundary()))
            XCTAssertFalse(PersonalTaskTypes.canSend(change, boundary: try boundary(nil)))
            XCTAssertFalse(PersonalTaskTypes.canSend(change, boundary: nil))
        }
        for value in [JSON.null, .bool(false)] {
            XCTAssertTrue(PersonalTaskTypes.requiresService(Mutation(table: "tasks", recordID: original.id, method: "POST", fields: ["is_heading": value])))
        }
        XCTAssertFalse(PersonalTaskTypes.requiresService(Mutation(table: "tasks", recordID: original.id, method: "POST", fields: original.fields)))
        XCTAssertFalse(PersonalTaskTypes.requiresService(Mutation(table: "tasks", recordID: original.id, method: "PATCH", fields: ["description": .string("Keep the instructions")])))
        XCTAssertFalse(PersonalTaskTypes.requiresService(Mutation(table: "tasks", recordID: original.id, method: "DELETE", fields: [:], baseline: try TaskKind.setting(original, heading: true).fields)))
    }
    func testNestedTypeChangesUseCapturedTreeRatherThanOptimisticState() throws {
        var original = task()
        let child: JSON = .object(["id": .string("child"), "title": .string("Keep context"), "completed": .bool(false), "subtasks": .array([])])
        original["subtasks"] = .array([child])
        var typed = child.object; typed["is_heading"] = .bool(true)
        let edit = Mutation(table: "tasks", recordID: original.id, method: "PATCH", fields: ["subtasks": .array([.object(typed)])], baseline: original.fields)
        XCTAssertTrue(PersonalTaskTypes.requiresService(edit))
        typed["description"] = .string("Edited notes")
        var existing = original; existing["subtasks"] = edit.fields["subtasks"]!
        let notes = Mutation(table: "tasks", recordID: original.id, method: "PATCH", fields: ["subtasks": .array([.object(typed)])], baseline: existing.fields)
        XCTAssertFalse(PersonalTaskTypes.requiresService(notes), "Metadata edits do not acquire type-changing authority")
        let unbased = Mutation(table: "tasks", recordID: original.id, method: "PATCH", fields: edit.fields)
        XCTAssertTrue(PersonalTaskTypes.requiresService(unbased))
        typed["is_heading"] = .bool(false)
        XCTAssertTrue(PersonalTaskTypes.requiresService(Mutation(table: "tasks", recordID: original.id, method: "PATCH", fields: ["subtasks": .array([.object(typed)])], baseline: existing.fields)))
    }
    func testCompatibilityPauseDoesNotQuarantineOrEraseVisibleOfflineWork() throws {
        let original = task(), edit = typeEdit(original), supported = try boundary(), unavailable = try boundary(nil)
        var snapshot = Snapshot(tables: ["tasks": [original]])
        snapshot.pending = [edit]; snapshot.apply(edit)
        let cache = try TeamWorkspaceCache(boundary: unavailable, previous: TeamWorkspaceCache(boundary: supported, previous: nil, pending: [], tasks: [original]), pending: snapshot.pending, tasks: [original])
        XCTAssertTrue(cache.canSend(edit, in: snapshot), "Access and service compatibility are distinct")
        XCTAssertFalse(cache.requiresRecovery(snapshot)); XCTAssertTrue(cache.blocked(snapshot).isEmpty)
        let refreshed = cache.merging(["tasks": [original]], into: snapshot)
        XCTAssertEqual(refreshed.pending, [edit]); XCTAssertEqual(refreshed.tables["tasks"]?.first?["is_heading"], .bool(true))
        XCTAssertFalse(PersonalTaskTypes.canSend(edit, boundary: refreshed.teamWorkspace?.boundary))
        let cold = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(refreshed))
        XCTAssertEqual(cold.pending, [edit]); XCTAssertEqual(cold.tables, refreshed.tables)
        XCTAssertFalse(PersonalTaskTypes.canSend(try XCTUnwrap(cold.pending.first), boundary: cold.teamWorkspace?.boundary))
        XCTAssertTrue(PersonalTaskTypes.canSend(edit, boundary: supported), "Restored support resumes the exact original intention")
    }
    func testPersonalMarkerCannotGrantTeamAccessOrReplaceScopedWriter() throws {
        let b = try boundary(), row = task(), team = "f6310000-0000-4000-8000-000000000002", project = "f6310000-0000-4000-8000-000000000003"
        let scope = TeamTaskEditScope(account: account, origin: origin, team: team, project: project)
        var edit = typeEdit(row); edit.teamTaskScope = scope
        XCTAssertFalse(PersonalTaskTypes.requiresService(edit))
        let cache = try TeamWorkspaceCache(boundary: b, previous: nil, pending: [], tasks: [])
        XCTAssertFalse(cache.canSend(edit, in: Snapshot()), "The personal marker cannot authorize a team project")
    }
}
