import XCTest
@testable import TaskfoldCore

final class ChildTaskCompletionDraftTests: XCTestCase {
    let workspace = UUID(), session = UUID(), access = UUID()
    let epoch = "2927994b-2e36-4460-8683-fef792648841"
    func token(_ version: Double = 0) -> JSON { .object(["epoch": .string(epoch), "version": .number(version)]) }
    func read(_ changes: [String: JSON] = [:], remove: [String] = [], revision: Double = 1,
              incarnation: String? = nil, rootID: String? = nil, generation: String? = nil, project: String? = nil,
              workspace: UUID? = nil, session: UUID? = nil, access: UUID? = nil,
              origin: String = "https://child-record.test", account: String? = nil) throws -> ChildTaskRecordRead {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "child-task-record-read", withExtension: "json", subdirectory: "Fixtures"))
        let raw = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        var response = raw["response"]!.object, root = raw["root"]!.object
        var rows = response["records"]!.list
        var child = rows[1].object, fields = child["fields"]!.object
        fields[TeamChecklist.key] = token()
        fields.merge(changes) { _, value in value }
        for key in remove { fields.removeValue(forKey: key) }
        child["fields"] = .object(fields); child["revision"] = .number(revision)
        if let incarnation { child["incarnation"] = .string(incarnation) }
        rows[1] = .object(child); response["records"] = .array(rows)
        response["projection_revision"] = .number(revision)
        var parent = root["subtasks"]!.list[0].object
        parent["subtasks"] = .array([.object(fields)]); root["subtasks"] = .array([.object(parent)])
        if let rootID { root["id"] = .string(rootID); response["task_id"] = .string(rootID) }
        if let generation { root["task_generation"] = .string(generation); response["task_generation"] = .string(generation) }
        if let project { root["project_id"] = .string(project); response["project_id"] = .string(project) }
        let account = account ?? raw["account"]!.text
        response["account"] = .string(account)
        let context = try ChildTaskRecordContext(account: account, origin: origin, workspace: workspace ?? self.workspace,
                                                session: session ?? self.session, access: access ?? self.access,
                                                snapshot: UUID(), root: Record(root))
        return try ChildTaskRecordRead(data: JSONEncoder().encode(response), context: context)
    }
    func draft(_ read: ChildTaskRecordRead? = nil, action: ChildTaskCompletionDraft.Action = .complete) throws -> ChildTaskCompletionDraft {
        try .init(read: read ?? self.read(), key: "child", action: action)
    }
    func testCaptureAndRoundTripContainsNoTreeOrPrivateFields() throws {
        let r = try read(["description": .string("Private note"), "title": .string("Private title")]), d = try draft(r)
        XCTAssertEqual(d.body["incarnation"], .string(r.nodes["child"]!.incarnation))
        XCTAssertEqual(d.body["task_generation"], r.context.root["task_generation"])
        XCTAssertTrue(d.desiredCompleted)
        XCTAssertEqual(try JSONDecoder().decode(ChildTaskCompletionDraft.self, from: JSONEncoder().encode(d)), d)
        let encoded = String(decoding: try JSONEncoder().encode(d), as: UTF8.self)
        for text in ["Private note", "Private title", "subtasks"] { XCTAssertFalse(encoded.contains(text)) }
        XCTAssertEqual(String(reflecting: d), "Private child completion intent")
    }
    func testFreshReadAllowsDisjointFieldsWithoutReplacingRequest() throws {
        let d = try draft()
        try d.review(read(["title": .string("New title"), "future": .object(["opaque": .null]), "priority": .number(1)], revision: 4))
        XCTAssertEqual(d, try JSONDecoder().decode(ChildTaskCompletionDraft.self, from: JSONEncoder().encode(d)))
    }
    func testSameStateAfterCompletionCycleRefuses() throws {
        let d = try draft()
        XCTAssertThrowsError(try d.review(read([TeamChecklist.key: token(2)], revision: 3)))
    }
    func testReplacedEpochRefusesEvenAtSameVersion() throws {
        let d = try draft()
        XCTAssertThrowsError(try d.review(read([TeamChecklist.key: .object(["epoch": .string(UUID().uuidString.lowercased()), "version": .number(0)])])))
    }
    func testEveryLiveContextFenceRefuses() throws {
        let d = try draft()
        for r in [try read(workspace: UUID()), try read(session: UUID()), try read(access: UUID()),
                  try read(origin: "https://other.test"), try read(account: UUID().uuidString.lowercased()),
                  try read(rootID: UUID().uuidString.lowercased()),
                  try read(incarnation: UUID().uuidString.lowercased()), try read(generation: UUID().uuidString.lowercased()),
                  try read(project: UUID().uuidString.lowercased())] { XCTAssertThrowsError(try d.review(r)) }
    }
    func testLegacyTokenAbsenceRequiresExactRevision() throws {
        let r = try read(remove: [TeamChecklist.key]), d = try draft(r)
        try d.review(r)
        XCTAssertThrowsError(try d.review(read(remove: [TeamChecklist.key], revision: 2)))
        XCTAssertThrowsError(try d.review(read()))
    }
    func testReopenRequiresActualCompletedTimestamp() throws {
        let r = try read(["completed": .bool(true), "completed_at": .string("2026-10-29T12:00:00Z")]), d = try draft(r, action: .reopen)
        XCTAssertFalse(d.desiredCompleted); try d.review(r)
        XCTAssertThrowsError(try d.review(read(["completed": .bool(true), "completed_at": .string("2026-10-29T12:00:01Z")], revision: 2)))
        XCTAssertThrowsError(try draft(r))
        XCTAssertThrowsError(try draft(action: .reopen))
    }
    func testCompletionCohortMalformedValuesRefuse() throws {
        let invalid: [[String: JSON]] = [
            ["completed": .null], ["completed": .string("false")], ["completed": .bool(true)],
            ["completed_at": .string("2026-10-29T12:00:00Z")],
            ["completed": .bool(true), "completed_at": .string("nonsense")],
            ["is_heading": .bool(true)], ["is_heading": .string("future")],
            [TeamChecklist.key: .null], [TeamChecklist.key: .object([:])],
            [TeamChecklist.key: token(-1)], [TeamChecklist.key: token(0.5)],
            [TeamChecklist.key: token(TeamChecklist.maximumVersion)]
        ]
        for fields in invalid { XCTAssertThrowsError(try draft(read(fields)), "\(fields.keys)") }
    }
    func testPresenceChangesInCohortNeedReview() throws {
        let d = try draft()
        for fields: [String: JSON] in [["completed": .bool(false)], ["completed_at": .null], ["is_heading": .bool(false)]] {
            XCTAssertThrowsError(try d.review(read(fields)))
        }
    }
    func testDecodedIntentRevalidatesActionAndBaseline() throws {
        let d = try draft()
        var stored = try JSONDecoder().decode([String: JSON].self, from: JSONEncoder().encode(d))
        for key in d.body.keys {
            var changed = stored, body = d.body; body.removeValue(forKey: key); changed["body"] = .object(body)
            XCTAssertThrowsError(try JSONDecoder().decode(ChildTaskCompletionDraft.self, from: JSONEncoder().encode(changed)), key)
        }
        let malformed: [String: JSON] = ["action": .string("undo"), "revision": .number(-1), "node_key": .string(""),
                                       "request_id": .string("bad"), "baseline": .object(["title": .string("not completion")])]
        for (key, value) in malformed {
            var changed = stored, body = d.body; body[key] = value; changed["body"] = .object(body)
            XCTAssertThrowsError(try JSONDecoder().decode(ChildTaskCompletionDraft.self, from: JSONEncoder().encode(changed)), key)
        }
        stored["body"] = .object(d.body.merging(["subtasks": .array([])]) { _, v in v })
        XCTAssertThrowsError(try JSONDecoder().decode(ChildTaskCompletionDraft.self, from: JSONEncoder().encode(stored)))
    }
    func testUnknownPersistedScopeKeysAndInvalidScopeRefuse() throws {
        let d = try draft()
        let stored = try JSONDecoder().decode([String: JSON].self, from: JSONEncoder().encode(d))
        for (key, value) in ["unexpected": JSON.bool(true), "account": .string("wrong"), "origin": .string("http://unsafe.test"), "session": .string("invalid")] {
            var changed = stored; changed[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(ChildTaskCompletionDraft.self, from: JSONEncoder().encode(changed)), key)
        }
    }
    func testReviewRetainsRawTreeAndDoesNotCompleteAnythingLocally() throws {
        let r = try read(["future": .object(["nested": .array([.null, .bool(false)])]), "description": .null]), d = try draft(r)
        let before = r.tree
        try d.review(r)
        XCTAssertTrue(AuthoredValueComparison.exactJSON(before, r.tree))
        XCTAssertNil(r.nodes["child"]!.fields["completed"])
        XCTAssertNil(d.body["completed_at"])
    }
    func testMissingChildAndFutureRevisionRefuse() throws {
        let r = try read()
        XCTAssertThrowsError(try ChildTaskCompletionDraft(read: r, key: "missing", action: .complete))
        let d = try draft(read(revision: 3))
        XCTAssertThrowsError(try d.review(r))
    }
}
