import XCTest
@testable import TaskfoldCore

private final class AdoptionIO: CalendarSecureItemIO, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: Data] = [:]
    var failWrite = false, failRemove = false
    func read(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return rows[key] }
    func write(_ data: Data, key: String) throws { lock.lock(); defer { lock.unlock() }; if failWrite { throw URLError(.cannotWriteToFile) }; rows[key] = data }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; if failRemove { throw URLError(.cannotRemoveFile) }; rows.removeValue(forKey: key) }
    var encoded: String { lock.lock(); defer { lock.unlock() }; return rows.values.map { String(decoding: $0, as: UTF8.self) }.joined() }
}
@MainActor private final class AdoptionPeer: TeamProjectAdoptionService {
    var calls: [TeamProjectAdoptionCommand] = []
    private var applied: Set<String> = []
    var lose = false, hold = false, foreign = false
    var continuation: CheckedContinuation<Void, Never>?
    var onReply: (() -> Void)?
    let raw: [String: JSON]
    init(_ raw: [String: JSON]) { self.raw = raw }
    func inspectProjectAdoption(_ scope: TeamProjectAdoptionScope) async throws -> TeamProjectAdoptionInspection { throw TeamProjectAdoptionValue.invalid }
    func reviewProjectAdoption(_ inspection: TeamProjectAdoptionInspection, decisions: [TeamProjectAdoptionDecision]) async throws -> TeamProjectAdoptionReview { throw TeamProjectAdoptionValue.invalid }
    func adoptProjects(_ command: TeamProjectAdoptionCommand) async throws -> TeamProjectAdoptionReceipt {
        calls.append(command)
        if hold { await withCheckedContinuation { continuation = $0 } }
        if lose { lose = false; applied.insert(command.id); throw URLError(.networkConnectionLost) }
        var reply = raw; reply["request_id"] = .string(command.id); reply["replayed"] = .bool(!applied.insert(command.id).inserted)
        if foreign { reply["account"] = .string(UUID().uuidString.lowercased()) }
        let result = try command.confirmed(reply); onReply?(); return result
    }
}
private final class AdoptionHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, AdoptionHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func finish(_ raw: [String: JSON]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(raw)); client?.urlProtocolDidFinishLoading(self)
    }
}

final class TeamProjectAdoptionTests: XCTestCase {
    func testActualChildRecordAdoptionSQLReviewAndReceipt() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-child-project-adoption-v1", withExtension: "json", subdirectory: "Fixtures"))
        let raw = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url)), b = raw["body"]!.object
        XCTAssertEqual(raw["syntheticOnly"], .bool(true)); XCTAssertEqual(raw["containerRemoved"], .bool(true))
        let scope = try TeamProjectAdoptionScope(account: raw["account"]!.text, origin: raw["origin"]!.text, team: b["team_id"]!.text, roots: b["roots"]!.list.map(\.text), visibility: .private)
        let i = try TeamProjectAdoptionInspection(raw["inspect"]!.object, scope: scope)
        let decisions = try raw["decisions"]!.list.map { try TeamProjectAdoptionDecision($0.object) }
        let review = try TeamProjectAdoptionReview(raw["review"]!.object, inspection: i, decisions: decisions)
        XCTAssertTrue(i.supportsChildRecordCustody); XCTAssertEqual(i.privateSubtaskUndoCount, 1)
        XCTAssertEqual(i.projects.count, 2); XCTAssertEqual(review.assignmentsCleared, 1)
        let command = try TeamProjectAdoptionCommand(review: review, requestID: UUID(uuidString: raw["command"]!.object["request_id"]!.text)!, now: review.expires.addingTimeInterval(-60))
        XCTAssertEqual(command.body, raw["command"]!.object)
        XCTAssertNil(command.body["subtask_undo_policy"]); XCTAssertNil(command.body["private_subtask_undo_count"])
        XCTAssertFalse(try command.confirmed(raw["receipt"]!.object).replayed)
        XCTAssertEqual(try JSONDecoder().decode(TeamProjectAdoptionCommand.self, from: JSONEncoder().encode(command)), command)
        XCTAssertFalse(String(describing: command).contains(i.scope.team))
    }
    func testLegacyInspectionDoesNotClaimPrivateSubtaskRetention() throws {
        let (_, inspection, _, _) = try fixture()
        XCTAssertFalse(inspection.supportsChildRecordCustody)
        XCTAssertEqual(inspection.privateSubtaskUndoCount, 0)
    }
    func testChildCustodyNeedsPairedVersionPolicyAndBoundedCount() throws {
        let (raw, old, _, _) = try fixture()
        func value(_ count: JSON) -> [String: JSON] {
            var v = raw["inspect"]!.object, c = v["contents"]!.object
            v["child_record_custody_protocol"] = .number(1)
            c["child_record_custody_protocol"] = .number(1)
            c["subtask_undo_policy"] = .string("kept_private_no_restore")
            c["private_subtask_undo_count"] = count; v["contents"] = .object(c)
            return v
        }
        for n in [0, 1, 64] {
            let i = try TeamProjectAdoptionInspection(value(.number(Double(n))), scope: old.scope)
            XCTAssertTrue(i.supportsChildRecordCustody); XCTAssertEqual(i.privateSubtaskUndoCount, n)
        }
        for n in [JSON.number(-1), .number(65), .number(0.5), .string("1"), .null, .bool(true)] {
            XCTAssertThrowsError(try TeamProjectAdoptionInspection(value(n), scope: old.scope))
        }
        for key in ["child_record_custody_protocol", "subtask_undo_policy", "private_subtask_undo_count"] {
            var v = value(.number(1)), c = v["contents"]!.object; c.removeValue(forKey: key); v["contents"] = .object(c)
            XCTAssertThrowsError(try TeamProjectAdoptionInspection(v, scope: old.scope))
        }
        for version in [JSON.number(2), .string("1"), .null, .bool(true)] {
            var v = value(.number(1)); v["child_record_custody_protocol"] = version
            XCTAssertThrowsError(try TeamProjectAdoptionInspection(v, scope: old.scope))
        }
        var unknown = value(.number(1)), c = unknown["contents"]!.object; c["subtask_undo_policy"] = .string("publish"); unknown["contents"] = .object(c)
        XCTAssertThrowsError(try TeamProjectAdoptionInspection(unknown, scope: old.scope))
        var unversioned = value(.number(1)); unversioned.removeValue(forKey: "child_record_custody_protocol")
        XCTAssertThrowsError(try TeamProjectAdoptionInspection(unversioned, scope: old.scope))
    }
    func testCustodyPolicyCannotChangeBetweenInspectionAndReview() throws {
        let (raw, i, _, _) = try fixture()
        let decisions = try raw["decisions"]!.list.map { try TeamProjectAdoptionDecision($0.object) }
        var review = raw["review"]!.object, c = review["contents"]!.object
        review["child_record_custody_protocol"] = .number(1); c["child_record_custody_protocol"] = .number(1)
        c["subtask_undo_policy"] = .string("kept_private_no_restore"); c["private_subtask_undo_count"] = .number(0); review["contents"] = .object(c)
        XCTAssertThrowsError(try TeamProjectAdoptionReview(review, inspection: i, decisions: decisions))
    }
    func testRecordingInventoryCannotEnableTransferBeforeCustodyCommit() throws {
        let (wire, legacy, _, _) = try fixture()
        var inspectionRaw = wire["inspect"]!.object, reviewRaw = wire["review"]!.object
        var contents = inspectionRaw["contents"]!.object
        contents["recording_custody"] = .object(["protocol": .number(1), "published": .number(2), "pending": .number(1), "retained": .number(1), "unavailable": .number(1)])
        inspectionRaw["contents"] = .object(contents); reviewRaw["contents"] = .object(contents)
        let inspection = try TeamProjectAdoptionInspection(inspectionRaw, scope: legacy.scope)
        let decisions = try wire["decisions"]!.list.map { try TeamProjectAdoptionDecision($0.object) }
        let review = try TeamProjectAdoptionReview(reviewRaw, inspection: inspection, decisions: decisions)
        XCTAssertFalse(review.canCommit, "Even an enabled service flag cannot imply recording custody approval")
        XCTAssertThrowsError(try TeamProjectAdoptionCommand(review: review, now: review.expires.addingTimeInterval(-60)))
    }
    func testMalformedRecordingInventoryNeverBecomesTransferConsent() throws {
        let (wire, legacy, _, _) = try fixture()
        let summary: [String: JSON] = ["protocol": .number(1), "published": .number(1), "pending": .number(0), "retained": .number(0), "unavailable": .number(0)]
        var invalid: [JSON] = [.null, .string("1"), .object([:])]
        for (key, value) in [("protocol", JSON.number(2)), ("published", .number(-1)), ("pending", .number(0.5)), ("retained", .bool(true)), ("unavailable", .number(2)), ("published", .number(10001)), ("inventory_hash", .string(String(repeating: "a", count: 64)))] {
            var bad = summary; bad[key] = value; invalid.append(.object(bad))
        }
        var missing = summary; missing.removeValue(forKey: "pending"); invalid.append(.object(missing))
        var excessive = summary; excessive["published"] = .number(10000); excessive["pending"] = .number(1); invalid.append(.object(excessive))
        for bad in invalid {
            var raw = wire["inspect"]!.object, contents = raw["contents"]!.object
            contents["recording_custody"] = bad; raw["contents"] = .object(contents)
            XCTAssertThrowsError(try TeamProjectAdoptionInspection(raw, scope: legacy.scope))
        }
    }
    func testRecordingInventoryCannotChangeBetweenInspectionAndReview() throws {
        let (wire, legacy, _, _) = try fixture()
        var raw = wire["inspect"]!.object, contents = raw["contents"]!.object
        contents["recording_custody"] = .object(["protocol": .number(1), "published": .number(1), "pending": .number(0), "retained": .number(0), "unavailable": .number(0)])
        raw["contents"] = .object(contents)
        let inspection = try TeamProjectAdoptionInspection(raw, scope: legacy.scope)
        let decisions = try wire["decisions"]!.list.map { try TeamProjectAdoptionDecision($0.object) }
        XCTAssertThrowsError(try TeamProjectAdoptionReview(wire["review"]!.object, inspection: inspection, decisions: decisions))
    }
    func testActualSQLRecordingInventoryKeepsPrivateDetailsOnServer() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-project-recordings-v1", withExtension: "json", subdirectory: "Fixtures"))
        let wire = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url)), body = wire["body"]!.object
        XCTAssertEqual(wire["syntheticOnly"], .bool(true)); XCTAssertEqual(wire["containerRemoved"], .bool(true))
        let scope = try TeamProjectAdoptionScope(account: wire["account"]!.text, origin: wire["origin"]!.text, team: body["team_id"]!.text, roots: body["roots"]!.list.map(\.text), visibility: .private)
        let inspection = try TeamProjectAdoptionInspection(wire["inspect"]!.object, scope: scope)
        XCTAssertEqual(inspection.contents["recording_custody"]?.object["published"], .number(2))
        let review = try TeamProjectAdoptionReview(wire["review"]!.object, inspection: inspection, decisions: [])
        XCTAssertFalse(review.canCommit)
        XCTAssertThrowsError(try TeamProjectAdoptionCommand(review: review, now: review.expires.addingTimeInterval(-60)))
    }
    private func recordingTransferFixture() throws -> ([String: JSON], TeamProjectAdoptionInspection, TeamProjectAdoptionReview, TeamProjectAdoptionCommand) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-project-recording-transfer-v1", withExtension: "json", subdirectory: "Fixtures"))
        let raw = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url)), b = raw["body"]!.object
        XCTAssertEqual(raw["syntheticOnly"], .bool(true)); XCTAssertEqual(raw["containerRemoved"], .bool(true))
        let scope = try TeamProjectAdoptionScope(account: raw["account"]!.text, origin: raw["origin"]!.text, team: b["team_id"]!.text, roots: b["roots"]!.list.map(\.text), visibility: .team)
        let inspection = try TeamProjectAdoptionInspection(raw["inspect"]!.object, scope: scope)
        let decisions = try raw["decisions"]!.list.map { try TeamProjectAdoptionDecision($0.object) }
        let review = try TeamProjectAdoptionReview(raw["review"]!.object, inspection: inspection, decisions: decisions, recordingPolicy: .published)
        let command = try TeamProjectAdoptionCommand(review: review, requestID: UUID(uuidString: raw["command"]!.object["request_id"]!.text)!, now: review.expires.addingTimeInterval(-60))
        return (raw, inspection, review, command)
    }
    func testActualSQLRecordingConsentCommandAndReceipt() throws {
        let (raw, inspection, review, command) = try recordingTransferFixture()
        XCTAssertTrue(inspection.recordingTransferSupported); XCTAssertTrue(review.canCommit)
        XCTAssertEqual(review.recordingPolicy, .published); XCTAssertEqual(command.recordingCount, 2)
        XCTAssertEqual(command.body, raw["command"]!.object)
        XCTAssertFalse(try command.confirmed(raw["receipt"]!.object).replayed)
        XCTAssertTrue(try command.confirmed(raw["replayed"]!.object).replayed)
        XCTAssertEqual(try JSONDecoder().decode(TeamProjectAdoptionCommand.self, from: JSONEncoder().encode(command)), command)
    }
    func testRecordingSupportNeverSubstitutesForExplicitConsent() throws {
        let (raw, inspection, approved, _) = try recordingTransferFixture()
        XCTAssertThrowsError(try TeamProjectAdoptionReview(raw["review"]!.object, inspection: inspection, decisions: approved.decisions))
        var noConsent = raw["review"]!.object; noConsent.removeValue(forKey: "recording_policy"); noConsent.removeValue(forKey: "recording_count")
        let review = try TeamProjectAdoptionReview(noConsent, inspection: inspection, decisions: approved.decisions)
        XCTAssertFalse(review.canCommit)
        XCTAssertThrowsError(try TeamProjectAdoptionCommand(review: review, now: review.expires.addingTimeInterval(-60)))
        XCTAssertNil(try inspection.reviewBody(approved.decisions)["recording_policy"])
        XCTAssertEqual(try inspection.reviewBody(approved.decisions, recordingPolicy: .published)["recording_policy"], .string("published_recordings_v1"))
    }
    func testRecordingCapabilityMustMatchAvailableInventory() throws {
        let (raw, inspection, _, _) = try recordingTransferFixture()
        for capability in [JSON.null, .object(["protocol": .number(2), "supported": .bool(true)]), .object(["protocol": .number(1), "supported": .string("true")]), .object(["protocol": .number(1), "supported": .bool(true), "extra": .bool(true)])] {
            var response = raw["inspect"]!.object, contents = response["contents"]!.object; contents["recording_transfer"] = capability; response["contents"] = .object(contents)
            XCTAssertThrowsError(try TeamProjectAdoptionInspection(response, scope: inspection.scope))
        }
        for key in ["pending", "retained", "unavailable"] {
            var response = raw["inspect"]!.object, contents = response["contents"]!.object, recordings = contents["recording_custody"]!.object
            recordings[key] = .number(1); contents["recording_custody"] = .object(recordings); response["contents"] = .object(contents)
            XCTAssertThrowsError(try TeamProjectAdoptionInspection(response, scope: inspection.scope))
        }
    }
    func testSavedRecordingConsentAndAcknowledgedCountAreBoundTogether() throws {
        let (raw, _, _, command) = try recordingTransferFixture()
        let encoded = try JSONDecoder().decode([String: JSON].self, from: JSONEncoder().encode(command))
        for count in [JSON.null, .number(0), .number(-1), .number(10001), .bool(true)] {
            var bad = encoded; bad["recordingCount"] = count
            XCTAssertThrowsError(try JSONDecoder().decode(TeamProjectAdoptionCommand.self, from: JSONEncoder().encode(bad)))
        }
        for count in [JSON.null, .number(1), .number(2.5), .bool(true)] {
            var receipt = raw["receipt"]!.object; receipt["recording_count"] = count; XCTAssertThrowsError(try command.confirmed(receipt))
        }
        var receipt = raw["receipt"]!.object; receipt["recording_policy"] = .null; XCTAssertThrowsError(try command.confirmed(receipt))
        var review = raw["review"]!.object; review["recording_count"] = .number(1)
        let (_, i, approved, _) = try recordingTransferFixture()
        XCTAssertThrowsError(try TeamProjectAdoptionReview(review, inspection: i, decisions: approved.decisions, recordingPolicy: .published))
    }
    @MainActor func testRecordingConsentSurvivesSecureItemColdRetryAfterLostReply() async throws {
        let (raw, _, review, command) = try recordingTransferFixture(), io = AdoptionIO(), vault = TeamProjectAdoptionVault(io: io), peer = AdoptionPeer(raw["receipt"]!.object)
        peer.lose = true
        let first = TeamProjectAdoptionModel(account: command.account, origin: command.origin, vault: vault, service: peer, current: { true })
        await first.send(command, canAuthor: { true }, now: review.expires.addingTimeInterval(-60))
        XCTAssertEqual(first.pending, command); XCTAssertNil(first.receipt)
        XCTAssertFalse(io.encoded.contains("audio_base64")); XCTAssertFalse(io.encoded.contains("Preserve the original published recording")); first.close()
        let cold = TeamProjectAdoptionModel(account: command.account, origin: command.origin, vault: vault, service: peer, current: { true })
        await cold.load(); XCTAssertEqual(cold.pending, command); XCTAssertEqual(cold.pending?.recordingCount, 2)
        await cold.retry(); XCTAssertNil(cold.pending); XCTAssertEqual(cold.receipt?.command, command)
        XCTAssertEqual(peer.calls, [command, command])
    }
    @MainActor func testBackendSendsRecordingConsentOnlyWhenExplicitlyRequested() async throws {
        let (raw, inspection, review, command) = try recordingTransferFixture()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AdoptionHTTP.self]
        let session = try JSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(command.account)\"}}".utf8))
        let backend = Backend(configuration: ["URL": command.origin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        var calls = 0
        AdoptionHTTP.handler = { request, peer in
            calls += 1; var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) } }
            let body = try! JSONDecoder().decode([String: JSON].self, from: data)
            XCTAssertEqual(body["operation"], .string("review")); XCTAssertEqual(body["body"], .object(try! inspection.reviewBody(review.decisions, recordingPolicy: .published)))
            peer.finish(raw["review"]!.object)
        }; defer { AdoptionHTTP.handler = nil }
        let result = try await backend.reviewProjectAdoption(inspection, decisions: review.decisions, connectionPolicy: nil, recordingPolicy: .published)
        XCTAssertEqual(result, review); XCTAssertEqual(calls, 1)
    }
    private func fixture(connections: Bool = false) throws -> ([String: JSON], TeamProjectAdoptionInspection, TeamProjectAdoptionReview, TeamProjectAdoptionCommand) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: connections ? "team-project-adoption-connections-v1" : "team-project-adoption-v1", withExtension: "json", subdirectory: "Fixtures"))
        let raw = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url)), b = raw["body"]!.object
        XCTAssertEqual(raw["syntheticOnly"], .bool(true)); XCTAssertEqual(raw["containerRemoved"], .bool(true))
        let scope = try TeamProjectAdoptionScope(account: raw["account"]!.text, origin: raw["origin"]!.text, team: b["team_id"]!.text, roots: b["roots"]!.list.map(\.text), visibility: .private)
        let i = try TeamProjectAdoptionInspection(raw["inspect"]!.object, scope: scope)
        let decisions = try raw["decisions"]!.list.map { try TeamProjectAdoptionDecision($0.object) }
        let r = try TeamProjectAdoptionReview(raw["review"]!.object, inspection: i, decisions: decisions, connectionPolicy: connections ? .pause : nil)
        let c = try TeamProjectAdoptionCommand(review: r, requestID: UUID(uuidString: raw["command"]!.object["request_id"]!.text)!, now: r.expires.addingTimeInterval(-60))
        return (raw, i, r, c)
    }
    func testActualSQLInspectionReviewAndReceipt() throws {
        let (raw, i, r, c) = try fixture()
        XCTAssertEqual(i.projects.count, 2); XCTAssertTrue(i.projects.contains { $0.archived }); XCTAssertEqual(i.people.count, 2)
        XCTAssertEqual(r.assignmentsCleared, 1); XCTAssertEqual(r.invitationsClosed, 2); XCTAssertTrue(r.canCommit)
        XCTAssertEqual(c.body, raw["command"]!.object); XCTAssertFalse(try c.confirmed(raw["receipt"]!.object).replayed)
        XCTAssertEqual(try JSONDecoder().decode(TeamProjectAdoptionCommand.self, from: JSONEncoder().encode(c)), c)
    }
    func testChildHistoryReviewHasAnExplicitBoundedVersion() throws {
        let (raw, old, _, _) = try fixture()
        XCTAssertFalse(old.supportsChildHistory)
        var value = raw["inspect"]!.object
        var contents = value["contents"]!.object
        var counts = contents["counts"]!.object
        counts["task_node_activity"] = .number(12)
        contents["counts"] = .object(counts); value["contents"] = .object(contents)
        // Never accept an unversioned extra category or silently infer support.
        XCTAssertThrowsError(try TeamProjectAdoptionInspection(value, scope: old.scope))
        value["child_history_protocol"] = .number(1)
        let reading = try TeamProjectAdoptionInspection(value, scope: old.scope)
        XCTAssertTrue(reading.supportsChildHistory)
        XCTAssertEqual(reading.contents["counts"]?.object["task_node_activity"], .number(12))
        for version in [JSON.number(2), .string("1"), .null, .bool(true)] {
            var invalid = value; invalid["child_history_protocol"] = version
            XCTAssertThrowsError(try TeamProjectAdoptionInspection(invalid, scope: old.scope))
        }
        for count in [JSON.number(-1), .number(1.5), .number(100000), .number(100001), .string("12"), .null] {
            var invalidCounts = counts; invalidCounts["task_node_activity"] = count
            var invalidContents = contents; invalidContents["counts"] = .object(invalidCounts)
            var invalid = value; invalid["contents"] = .object(invalidContents)
            XCTAssertThrowsError(try TeamProjectAdoptionInspection(invalid, scope: old.scope))
        }
        var missing = raw["inspect"]!.object; missing["child_history_protocol"] = .number(1)
        XCTAssertThrowsError(try TeamProjectAdoptionInspection(missing, scope: old.scope))
    }
    func testActualSQLChildHistoryInspectionReviewAndReceipt() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-project-adoption-child-history-v1", withExtension: "json", subdirectory: "Fixtures"))
        let raw = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        let b = raw["body"]!.object
        let scope = try TeamProjectAdoptionScope(account: raw["account"]!.text, origin: raw["origin"]!.text, team: b["team_id"]!.text, roots: b["roots"]!.list.map(\.text), visibility: .private)
        let i = try TeamProjectAdoptionInspection(raw["inspect"]!.object, scope: scope)
        XCTAssertTrue(i.supportsChildHistory)
        XCTAssertGreaterThan(i.contents["counts"]!.object["task_node_activity"]!.integer, 0)
        let decisions = try raw["decisions"]!.list.map { try TeamProjectAdoptionDecision($0.object) }
        let review = try TeamProjectAdoptionReview(raw["review"]!.object, inspection: i, decisions: decisions, connectionPolicy: .pause)
        let command = try TeamProjectAdoptionCommand(review: review, requestID: UUID(uuidString: raw["command"]!.object["request_id"]!.text)!, now: review.expires.addingTimeInterval(-60))
        XCTAssertEqual(command.body, raw["command"]!.object)
        XCTAssertTrue(try command.confirmed(raw["receipt"]!.object).command.connectionEffects != nil)
        var stale = raw["review"]!.object
        var contents = stale["contents"]!.object
        var counts = contents["counts"]!.object
        counts["task_node_activity"] = .number(Double(counts["task_node_activity"]!.integer + 1))
        contents["counts"] = .object(counts); stale["contents"] = .object(contents)
        XCTAssertThrowsError(try TeamProjectAdoptionReview(stale, inspection: i, decisions: decisions, connectionPolicy: .pause))
    }
    func testEveryAcceptedCollaboratorNeedsAnExplicitDecision() throws {
        let (_, i, r, _) = try fixture()
        XCTAssertThrowsError(try i.reviewBody([])); XCTAssertThrowsError(try i.reviewBody(r.decisions + [r.decisions[0]]))
        let outsider = try XCTUnwrap(i.people.first { !$0.eligible })
        let bad = try r.decisions.map { d in try TeamProjectAdoptionDecision(project: d.project, user: d.user, choice: d.user == outsider.user ? .editor : d.choice) }
        XCTAssertThrowsError(try i.reviewBody(bad))
    }
    func testSourceForestCannotBeRetargetedOrFabricated() throws {
        let (raw, i, _, _) = try fixture()
        for (k, value) in ["account": JSON.string(UUID().uuidString.lowercased()), "team_id": .string(UUID().uuidString.lowercased()), "creates_memberships": .bool(true), "automatic_undo": .bool(true), "inspection_token": .string("bad"), "destination_archived": .null] {
            var x = raw["inspect"]!.object; x[k] = value; XCTAssertThrowsError(try TeamProjectAdoptionInspection(x, scope: i.scope), k)
        }
        var x = raw["inspect"]!.object, projects = x["projects"]!.list
        var child = projects[1].object; child["parent_id"] = .string(UUID().uuidString.lowercased()); projects[1] = .object(child); x["projects"] = .array(projects)
        XCTAssertThrowsError(try TeamProjectAdoptionInspection(x, scope: i.scope))
        x = raw["inspect"]!.object; x["projects"] = .array([projects[0], projects[0]]); XCTAssertThrowsError(try TeamProjectAdoptionInspection(x, scope: i.scope))
        XCTAssertThrowsError(try TeamProjectAdoptionScope(account: i.scope.account, origin: "http://synthetic.example", team: i.scope.team, roots: i.scope.roots, visibility: .private))
    }
    func testReviewCannotChangeAChoiceOrHideAnInvitation() throws {
        let (raw, i, r, _) = try fixture()
        for (k, value) in ["assignments_cleared": JSON.number(-1), "invitations_closed": .number(0), "expires_at": .string("2026-10-25T10:00:00+01:00"), "review_token": .string("bad"), "requires_provider_custody": .bool(true)] {
            var x = raw["review"]!.object; x[k] = value; XCTAssertThrowsError(try TeamProjectAdoptionReview(x, inspection: i, decisions: r.decisions), k)
        }
        var x = raw["review"]!.object, decisions = x["decisions"]!.list; var d = decisions[0].object; d["role"] = .string("viewer"); decisions[0] = .object(d); x["decisions"] = .array(decisions)
        XCTAssertThrowsError(try TeamProjectAdoptionReview(x, inspection: i, decisions: r.decisions))
    }
    func testFreshAuthoringAndExpiredRetryAreDifferent() throws {
        let (_, _, r, c) = try fixture()
        XCTAssertThrowsError(try TeamProjectAdoptionCommand(review: r, now: r.expires)); XCTAssertThrowsError(try TeamProjectAdoptionCommand(review: r, now: r.expires.addingTimeInterval(-17 * 60)))
        XCTAssertNotEqual(try TeamProjectAdoptionCommand(review: r, now: r.expires.addingTimeInterval(-60)).id, c.id)
        // Decoding preserves a saved request even after its review expires.
        XCTAssertEqual(try JSONDecoder().decode(TeamProjectAdoptionCommand.self, from: JSONEncoder().encode(c)), c)
    }
    func testOnlyIdentityAndProofFieldsEnterThePrivateRetry() throws {
        let (_, _, _, c) = try fixture(); let data = try JSONEncoder().encode(c), text = String(decoding: data, as: UTF8.self)
        for privateText in ["Studio plan", "Never put task text", "example.invalid", "data:text/plain", "Design Studio"] { XCTAssertFalse(text.contains(privateText)) }
        XCTAssertEqual(String(reflecting: c), "Private project transfer request")
        for (key, value) in ["task": JSON.string("Private text"), "review_token": .string("bad"), "request_id": .null, "expires_at": .string("bad")] {
            var b = c.body; b[key] = value; XCTAssertThrowsError(try TeamProjectAdoptionCommand(account: c.account, origin: c.origin, body: b, projects: c.projects, assignmentsCleared: c.assignmentsCleared, invitationsClosed: c.invitationsClosed))
        }
    }
    func testReceiptRequiresTheWholeReviewedForestAndExactCounts() throws {
        let (raw, _, _, c) = try fixture()
        for (key, value) in ["account": JSON.string(UUID().uuidString.lowercased()), "request_id": .string(UUID().uuidString.lowercased()), "project_ids": .array([.string(c.projects[0])]), "assignments_cleared": .number(0), "invitations_closed": .number(0), "applied": .bool(false), "automatic_undo": .bool(true)] {
            var x = raw["receipt"]!.object; x[key] = value; XCTAssertThrowsError(try c.confirmed(x), key)
        }
    }
    @MainActor func testLostReplyRelaunchRetriesTheExactNonce() async throws {
        let (raw, _, r, c) = try fixture(), io = AdoptionIO(), vault = TeamProjectAdoptionVault(io: io), peer = AdoptionPeer(raw["receipt"]!.object)
        peer.lose = true
        let first = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: vault, service: peer, current: { true })
        await first.send(c, canAuthor: { true }, now: r.expires.addingTimeInterval(-60)); XCTAssertEqual(first.pending, c); XCTAssertNil(first.receipt); first.close()
        let second = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: vault, service: peer, current: { true })
        await second.load(); XCTAssertEqual(second.pending, c); await second.retry()
        XCTAssertEqual(peer.calls, [c,c]); XCTAssertEqual(second.receipt?.command, c); XCTAssertEqual(second.receipt?.replayed, true); XCTAssertNil(second.pending)
    }
    @MainActor func testNoNetworkWriteBeforeDurablePrivateSave() async throws {
        let (raw, _, r, c) = try fixture(), io = AdoptionIO(); io.failWrite = true
        let peer = AdoptionPeer(raw["receipt"]!.object), model = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: TeamProjectAdoptionVault(io: io), service: peer, current: { true })
        await model.send(c, canAuthor: { true }, now: r.expires.addingTimeInterval(-60)); XCTAssertTrue(peer.calls.isEmpty); XCTAssertNil(model.receipt)
    }
    @MainActor func testOtherWindowsCannotReplaceThePendingTransfer() async throws {
        let (raw, _, r, c) = try fixture(), io = AdoptionIO(), vault = TeamProjectAdoptionVault(io: io), peer = AdoptionPeer(raw["receipt"]!.object)
        peer.lose = true
        let first = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: vault, service: peer, current: { true })
        await first.send(c, canAuthor: { true }, now: r.expires.addingTimeInterval(-60))
        let second = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: vault, service: peer, current: { true }), other = try TeamProjectAdoptionCommand(review: r, now: r.expires.addingTimeInterval(-60))
        await second.send(other, canAuthor: { true }, now: r.expires.addingTimeInterval(-60)); XCTAssertEqual(peer.calls, [c]); XCTAssertEqual(second.pending, c)
        await second.clear(other); XCTAssertEqual(second.pending, c)
    }
    @MainActor func testAccountSwitchDuringReplyCannotClearPrivateRecovery() async throws {
        let (raw, _, r, c) = try fixture(), io = AdoptionIO(), vault = TeamProjectAdoptionVault(io: io), peer = AdoptionPeer(raw["receipt"]!.object)
        var current = true; peer.onReply = { current = false }
        let model = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: vault, service: peer, current: { current })
        await model.send(c, canAuthor: { true }, now: r.expires.addingTimeInterval(-60)); XCTAssertNil(model.receipt)
        let saved = try await vault.pending(account: c.account, origin: c.origin); XCTAssertEqual(saved, c)
    }
    @MainActor func testForeignReplyAndCleanupFailureKeepTheRequest() async throws {
        let (raw, _, r, c) = try fixture(), io = AdoptionIO(), vault = TeamProjectAdoptionVault(io: io), peer = AdoptionPeer(raw["receipt"]!.object)
        peer.foreign = true
        let model = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: vault, service: peer, current: { true })
        await model.send(c, canAuthor: { true }, now: r.expires.addingTimeInterval(-60)); XCTAssertEqual(model.pending, c)
        peer.foreign = false; io.failRemove = true; await model.retry(); XCTAssertEqual(model.pending, c); XCTAssertNil(model.receipt)
        io.failRemove = false; await model.retry(); XCTAssertNotNil(model.receipt)
    }
    @MainActor func testNewAuthoringCannotBypassTheCleanWorkspaceGate() async throws {
        let (raw, _, r, c) = try fixture(), peer = AdoptionPeer(raw["receipt"]!.object), model = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: TeamProjectAdoptionVault(io: AdoptionIO()), service: peer, current: { true })
        await model.send(c, canAuthor: { false }, now: r.expires.addingTimeInterval(-60)); XCTAssertTrue(peer.calls.isEmpty); XCTAssertNil(model.pending)
    }
    @MainActor func testReviewedClearIsLocalAndDoesNotSendOrUndo() async throws {
        let (raw, _, r, c) = try fixture(), peer = AdoptionPeer(raw["receipt"]!.object), io = AdoptionIO(), vault = TeamProjectAdoptionVault(io: io)
        peer.lose = true; let model = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: vault, service: peer, current: { true })
        await model.send(c, canAuthor: { true }, now: r.expires.addingTimeInterval(-60)); await model.clear(c); XCTAssertNil(model.pending); XCTAssertEqual(peer.calls, [c]); XCTAssertTrue(io.encoded.isEmpty)
    }
    func testVaultCapacitySupports1000IdentityOnlyDecisions() async throws {
        let (_, _, _, c) = try fixture()
        let choices: [JSON] = (1...1000).map { n in .object(["project_id": .string(c.scope.roots[0]), "user_id": .string(String(format:"a0000000-0000-4000-8000-%012d",n)), "role": .null]) }
        var body = c.body; body["decisions"] = .array(choices)
        let big = try TeamProjectAdoptionCommand(account: c.account, origin: c.origin, body: body, projects: c.projects, assignmentsCleared: 0, invitationsClosed: 1000)
        XCTAssertGreaterThan(try JSONEncoder().encode(big).count, 20_000)
        let vault = TeamProjectAdoptionVault(io: AdoptionIO()); try await vault.begin(big, lease: CalendarReadLease())
        let saved = try await vault.pending(account: big.account, origin: big.origin); XCTAssertEqual(saved, big)
    }
    func testRemovalAndLeaseFencesProtectAdoptionRecovery() async throws {
        let (_, _, _, c) = try fixture(), io = AdoptionIO(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = TeamProjectAdoptionVault(io: io, removalDirectory: root)
        let lease = CalendarReadLease(); lease.cancel()
        do { try await vault.begin(c, lease: lease); XCTFail("Cancelled writer persisted") } catch {}
        try await vault.begin(c, lease: CalendarReadLease())
        do { try await vault.clear(c, lease: lease); XCTFail("Cancelled clear removed recovery") } catch {}
        let saved = try await vault.pending(account: c.account, origin: c.origin); XCTAssertEqual(saved, c)
        try AccountRemovalDisk(directory: root, account: c.account).removeCache()
        do { _ = try await vault.pending(account: c.account, origin: c.origin); XCTFail("Removed account read recovery") } catch {}
        do { try await vault.begin(c, lease: CalendarReadLease()); XCTFail("Removed account recreated recovery") } catch {}
        try await vault.removeAccount(c.account, origin: c.origin); XCTAssertTrue(io.encoded.isEmpty)
    }
    func testDifferentOriginAndAccountNeverShareRecovery() async throws {
        let (_, _, _, c) = try fixture(), io = AdoptionIO(), vault = TeamProjectAdoptionVault(io: io)
        try await vault.begin(c, lease: CalendarReadLease())
        let otherAccount = try await vault.pending(account: UUID().uuidString.lowercased(), origin: c.origin), otherOrigin = try await vault.pending(account: c.account, origin: "https://other.example")
        XCTAssertNil(otherAccount); XCTAssertNil(otherOrigin)
        try await vault.removeAccount(c.account, origin: "https://other.example")
        let saved = try await vault.pending(account: c.account, origin: c.origin); XCTAssertEqual(saved, c)
    }
    @MainActor func testClosingAnInFlightTransferKeepsOriginalRecovery() async throws {
        let (raw, _, r, c) = try fixture(), vault = TeamProjectAdoptionVault(io: AdoptionIO()), peer = AdoptionPeer(raw["receipt"]!.object)
        peer.hold = true; let model = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: vault, service: peer, current: { true })
        let work = Task { await model.send(c, canAuthor: { true }, now: r.expires.addingTimeInterval(-60)) }
        while peer.continuation == nil { await Task.yield() }
        model.close(); peer.continuation?.resume(); await work.value
        XCTAssertNil(model.receipt); let saved = try await vault.pending(account: c.account, origin: c.origin); XCTAssertEqual(saved, c)
    }
    @MainActor func testBackendUsesTheActualAdoptionProtocolAndSessionFence() async throws {
        let (raw, i, r, c) = try fixture()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AdoptionHTTP.self]
        let session = try JSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(c.account)\"}}".utf8))
        let api = Backend(configuration: ["URL": c.origin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        var operations: [String] = []
        AdoptionHTTP.handler = { request, peer in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_team_project_adoption"); XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store"); XCTAssertFalse(request.httpShouldHandleCookies)
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(contentsOf: bytes.prefix(n)) } }
            let body = try! JSONDecoder().decode([String: JSON].self, from: data), op = body["operation"]!.text; operations.append(op)
            XCTAssertEqual(Set(body.keys), ["operation", "body"])
            if op == "inspect" { XCTAssertEqual(body["body"], .object(i.scope.body)); peer.finish(raw["inspect"]!.object) }
            else if op == "review" { XCTAssertEqual(body["body"], .object(try! i.reviewBody(r.decisions))); peer.finish(raw["review"]!.object) }
            else { XCTAssertEqual(body["body"], .object(c.body)); peer.finish(raw["receipt"]!.object) }
        }; defer { AdoptionHTTP.handler = nil }
        let inspected = try await api.inspectProjectAdoption(i.scope); XCTAssertEqual(inspected, i)
        let reviewed = try await api.reviewProjectAdoption(i, decisions: r.decisions); XCTAssertEqual(reviewed, r)
        let receipt = try await api.adoptProjects(c); XCTAssertEqual(receipt.command, c)
        let foreign = try TeamProjectAdoptionCommand(account: UUID().uuidString.lowercased(), origin: c.origin, body: c.body, projects: c.projects, assignmentsCleared: c.assignmentsCleared, invitationsClosed: c.invitationsClosed)
        do { _ = try await api.adoptProjects(foreign); XCTFail("Foreign account sent") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(operations, ["inspect", "review", "adopt"])
    }

    @MainActor func testUnreadableRecoveryCannotStartAFreshTransfer() async throws {
        let (raw, _, r, c) = try fixture(), io = AdoptionIO(), vault = TeamProjectAdoptionVault(io: io), peer = AdoptionPeer(raw["receipt"]!.object)
        let key = TeamProjectAdoptionCommand.storagePrefix + c.account + "." + CalendarOAuthConfiguration.digest(c.origin)
        try io.write(Data("broken private recovery".utf8), key: key)
        let model = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: vault, service: peer, current: { true })
        await model.load(); XCTAssertFalse(model.recoveryLoaded)
        await model.send(c, canAuthor: { true }, now: r.expires.addingTimeInterval(-60))
        XCTAssertTrue(peer.calls.isEmpty); XCTAssertFalse(model.recoveryLoaded); XCTAssertTrue(io.encoded.contains("broken private recovery"))
    }

    func testArchivePreviewSeparatesOwnStateFromDestinationInheritance() throws {
        let (raw, i, _, _) = try fixture(); var response = raw["inspect"]!.object
        var rows = response["projects"]!.list, root = rows[0].object, child = rows[1].object
        root["source_ancestor_archived"] = .bool(true); root["is_archived"] = .bool(false)
        rows[0] = .object(root); response["projects"] = .array(rows)
        let detached = try TeamProjectAdoptionInspection(response, scope: i.scope)
        XCTAssertTrue(detached.projects[0].inherited); XCTAssertFalse(detached.inheritsArchiveAfter(detached.projects[0])); XCTAssertTrue(detached.projects[1].archived)
        root["is_archived"] = .bool(true); child["is_archived"] = .bool(false); child["source_ancestor_archived"] = .bool(true)
        response["projects"] = .array([.object(root),.object(child)])
        let withParent = try TeamProjectAdoptionInspection(response, scope: i.scope)
        XCTAssertTrue(withParent.inheritsArchiveAfter(withParent.projects[1]))
        root["is_archived"] = .bool(false); response["projects"] = .array([.object(root),.object(child)]); response["destination_archived"] = .bool(true)
        let archivedDestination = try TeamProjectAdoptionInspection(response, scope: i.scope)
        XCTAssertTrue(archivedDestination.inheritsArchiveAfter(archivedDestination.projects[0])); XCTAssertTrue(archivedDestination.inheritsArchiveAfter(archivedDestination.projects[1]))
    }

    func testActualSQLPausePolicyAndReceiptCounts() throws {
        let (raw,i,r,c)=try fixture(connections:true)
        XCTAssertTrue(i.hasConnections);XCTAssertTrue(i.supportsConnectionPause);XCTAssertTrue(i.connectionPauseSupported);XCTAssertFalse(i.commitSupported)
        XCTAssertTrue(r.canCommit);XCTAssertEqual(r.connectionPolicy,.pause);XCTAssertEqual(r.connectionEffects?.values,["email_routes_paused":1,"project_webhooks_paused":1,"pending_webhooks_cancelled":1,"global_webhooks_excluded":1,"queued_updates_discarded":2])
        XCTAssertEqual(c.body,raw["command"]!.object);XCTAssertEqual(try c.confirmed(raw["receipt"]!.object).command,c)
        XCTAssertEqual(try JSONDecoder().decode(TeamProjectAdoptionCommand.self,from:JSONEncoder().encode(c)),c)
    }
    func testPauseRequiresExplicitConsentAndMatchingSummary() throws {
        let (raw,i,r,_)=try fixture(connections:true)
        XCTAssertThrowsError(try TeamProjectAdoptionReview(raw["review"]!.object,inspection:i,decisions:r.decisions))
        var unchosen=raw["review"]!.object;unchosen["connection_policy"] = .null;unchosen["connection_effects"] = .null;unchosen["requires_integration_pause"] = .bool(true)
        let blocked=try TeamProjectAdoptionReview(unchosen,inspection:i,decisions:r.decisions)
        XCTAssertFalse(blocked.canCommit);XCTAssertThrowsError(try TeamProjectAdoptionCommand(review:blocked,now:blocked.expires.addingTimeInterval(-60)))
        for key in TeamProjectConnectionEffects.keys {
            var forged=raw["review"]!.object,values=forged["connection_effects"]!.object;values[key] = .number(Double(values[key]!.integer+1));forged["connection_effects"] = .object(values)
            XCTAssertThrowsError(try TeamProjectAdoptionReview(forged,inspection:i,decisions:r.decisions,connectionPolicy:.pause))
        }
    }
    func testPauseReceiptCannotHideActionsOrChangeCounts() throws {
        let (raw,_,_,c)=try fixture(connections:true)
        var absent=raw["receipt"]!.object;absent.removeValue(forKey:"connection_policy");XCTAssertThrowsError(try c.confirmed(absent))
        absent=raw["receipt"]!.object;absent.removeValue(forKey:"connection_effects");XCTAssertThrowsError(try c.confirmed(absent))
        for key in TeamProjectConnectionEffects.keys {
            var forged=raw["receipt"]!.object,values=forged["connection_effects"]!.object;values[key] = .number(999);forged["connection_effects"] = .object(values);XCTAssertThrowsError(try c.confirmed(forged))
        }
        let (old,_,_,legacy)=try fixture();var unexpected=old["receipt"]!.object;unexpected["connection_policy"] = .string("pause");unexpected["connection_effects"] = c.connectionEffects!.body
        XCTAssertThrowsError(try legacy.confirmed(unexpected))
    }
    func testPausePrivateCommandKeepsOnlyActionAndBoundedCounts() throws {
        let (_,_,_,c)=try fixture(connections:true),data=try JSONEncoder().encode(c),text=String(decoding:data,as:UTF8.self)
        XCTAssertTrue(text.contains("connection_policy"));XCTAssertTrue(text.contains("queued_updates_discarded"))
        for secret in ["Never put task text", "Workshop address", "receiver.example", "capture.example", "@example.invalid", "secret_envelope"] {XCTAssertFalse(text.contains(secret))}
        XCTAssertThrowsError(try TeamProjectAdoptionCommand(account:c.account,origin:c.origin,body:c.body,projects:c.projects,assignmentsCleared:c.assignmentsCleared,invitationsClosed:c.invitationsClosed))
        var unknown=c.body;unknown["connection_policy"] = .string("retarget")
        XCTAssertThrowsError(try TeamProjectAdoptionCommand(account:c.account,origin:c.origin,body:unknown,projects:c.projects,assignmentsCleared:c.assignmentsCleared,invitationsClosed:c.invitationsClosed,connectionEffects:c.connectionEffects))
        var malformed=c.connectionEffects!.body.object;malformed["queued_updates_discarded"] = .number(-1);XCTAssertThrowsError(try TeamProjectConnectionEffects(malformed))
        malformed=c.connectionEffects!.body.object;malformed["sender_email"] = .string("hidden@example.invalid");XCTAssertThrowsError(try TeamProjectConnectionEffects(malformed))
        var stored=try JSONDecoder().decode([String:JSON].self,from:data);stored["connectionEffects"] = .object(malformed)
        XCTAssertThrowsError(try JSONDecoder().decode(TeamProjectAdoptionCommand.self,from:JSONEncoder().encode(stored)))
    }
    @MainActor func testAppliedPauseReplyLossPreservesExactPolicyAcrossRelaunch() async throws {
        let (raw,_,r,c)=try fixture(connections:true),io=AdoptionIO(),vault=TeamProjectAdoptionVault(io:io),peer=AdoptionPeer(raw["receipt"]!.object);peer.lose=true
        let first=TeamProjectAdoptionModel(account:c.account,origin:c.origin,vault:vault,service:peer,current:{true})
        await first.send(c,canAuthor:{true},now:r.expires.addingTimeInterval(-60));XCTAssertEqual(first.pending?.connectionEffects,c.connectionEffects);first.close()
        let next=TeamProjectAdoptionModel(account:c.account,origin:c.origin,vault:TeamProjectAdoptionVault(io:io),service:peer,current:{true});await next.load();XCTAssertEqual(next.pending,c);await next.retry()
        XCTAssertEqual(peer.calls,[c,c]);XCTAssertEqual(next.receipt?.command.connectionEffects,c.connectionEffects);XCTAssertTrue(next.receipt?.replayed == true);XCTAssertNil(next.pending)
    }

    func testActualPausedConnectionStillLoadsInExistingSettingsDecoder() throws {
        let (raw,_,_,_)=try fixture(connections:true)
        let connection=try WebhookConnection(raw["connection_receipt"]!.object)
        XCTAssertEqual(connection.state,"paused");XCTAssertEqual(connection.delivery.error,"resource_unavailable");XCTAssertEqual(connection.delivery.pending,0)
        XCTAssertNil(connection.delivery.blocked)
    }

}

extension TeamProjectAdoptionTests {
    private func unfinishedFixture(only: Bool = false) throws -> ([String: JSON], TeamProjectAdoptionInspection, TeamProjectAdoptionReview, TeamProjectAdoptionCommand) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-project-unfinished-recordings-v1", withExtension: "json", subdirectory: "Fixtures"))
        let captured = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        XCTAssertEqual(captured["syntheticOnly"], .bool(true)); XCTAssertEqual(captured["containerRemoved"], .bool(true))
        var raw = only ? captured["pendingOnly"]!.object : captured
        raw["account"] = captured["account"]; raw["origin"] = captured["origin"]
        let b = raw["body"]!.object
        let scope = try TeamProjectAdoptionScope(account: raw["account"]!.text, origin: raw["origin"]!.text, team: b["team_id"]!.text, roots: b["roots"]!.list.map(\.text), visibility: .team)
        let inspection = try TeamProjectAdoptionInspection(raw["inspect"]!.object, scope: scope)
        let decisions = try raw["decisions"]!.list.map { try TeamProjectAdoptionDecision($0.object) }
        let review = try TeamProjectAdoptionReview(raw["review"]!.object, inspection: inspection, decisions: decisions, recordingPolicy: .stopUnfinished)
        let command = try TeamProjectAdoptionCommand(review: review, requestID: UUID(uuidString: raw["command"]!.object["request_id"]!.text)!, now: review.expires.addingTimeInterval(-60))
        return (raw, inspection, review, command)
    }
    func testActualSQLMixedRecordingMoveAndStopContract() throws {
        let (raw, i, review, command) = try unfinishedFixture()
        XCTAssertFalse(i.recordingTransferSupported); XCTAssertTrue(i.recordingUnfinishedTransferSupported)
        XCTAssertEqual(i.supportedRecordingPolicy, .stopUnfinished); XCTAssertTrue(review.canCommit)
        XCTAssertEqual(command.recordingCount, 1); XCTAssertEqual(command.unfinishedRecordingCount, 2)
        XCTAssertEqual(command.body, raw["command"]!.object)
        XCTAssertEqual(command.body["recording_count"], .number(1)); XCTAssertEqual(command.body["unfinished_recording_count"], .number(2))
        XCTAssertFalse(try command.confirmed(raw["receipt"]!.object).replayed)
        XCTAssertTrue(try command.confirmed(raw["replayed"]!.object).replayed)
        XCTAssertEqual(try JSONDecoder().decode(TeamProjectAdoptionCommand.self, from: JSONEncoder().encode(command)), command)
    }
    func testActualSQLPendingOnlyMoveDoesNotInventPublishedRecordings() throws {
        let (raw, i, review, command) = try unfinishedFixture(only: true)
        XCTAssertTrue(review.canCommit); XCTAssertFalse(i.recordingTransferSupported)
        XCTAssertEqual(command.recordingPolicy, .stopUnfinished); XCTAssertEqual(command.recordingCount, 0); XCTAssertEqual(command.unfinishedRecordingCount, 1)
        XCTAssertEqual(command.body, raw["command"]!.object); XCTAssertFalse(try command.confirmed(raw["receipt"]!.object).replayed)
    }
    func testUnfinishedStoppingRequiresItsOwnExplicitPolicy() throws {
        let (raw, i, review, _) = try unfinishedFixture()
        XCTAssertThrowsError(try i.reviewBody(review.decisions, recordingPolicy: .published))
        let none = try i.reviewBody(review.decisions)
        XCTAssertNil(none["recording_policy"]); XCTAssertNil(none["recording_count"]); XCTAssertNil(none["unfinished_recording_count"])
        var without = raw["review"]!.object
        for key in ["recording_policy", "recording_count", "unfinished_recording_count"] { without.removeValue(forKey: key) }
        let noChoice = try TeamProjectAdoptionReview(without, inspection: i, decisions: review.decisions)
        XCTAssertFalse(noChoice.canCommit)
        XCTAssertThrowsError(try TeamProjectAdoptionCommand(review: noChoice, now: review.expires.addingTimeInterval(-60)))
    }
    func testUnfinishedStoredCountsCannotBeStrippedOrChangeTheSavedBody() throws {
        let (_, _, _, command) = try unfinishedFixture()
        let encoded = try JSONDecoder().decode([String: JSON].self, from: JSONEncoder().encode(command))
        for value in [JSON.null, .number(-1), .number(0), .number(1), .number(10001), .number(1.5), .bool(true)] {
            var bad = encoded; bad["unfinishedRecordingCount"] = value
            XCTAssertThrowsError(try JSONDecoder().decode(TeamProjectAdoptionCommand.self, from: JSONEncoder().encode(bad)))
        }
        var stripped = encoded; stripped.removeValue(forKey: "unfinishedRecordingCount")
        XCTAssertThrowsError(try JSONDecoder().decode(TeamProjectAdoptionCommand.self, from: JSONEncoder().encode(stripped)))
        var body = command.body; body["unfinished_recording_count"] = .number(1)
        XCTAssertThrowsError(try TeamProjectAdoptionCommand(account: command.account, origin: command.origin, body: body, projects: command.projects, assignmentsCleared: command.assignmentsCleared, invitationsClosed: command.invitationsClosed, recordingCount: 1, unfinishedRecordingCount: 2))
        body = command.body; body.removeValue(forKey: "recording_count")
        XCTAssertThrowsError(try TeamProjectAdoptionCommand(account: command.account, origin: command.origin, body: body, projects: command.projects, assignmentsCleared: command.assignmentsCleared, invitationsClosed: command.invitationsClosed, recordingCount: 1, unfinishedRecordingCount: 2))
    }
    func testUnfinishedReceiptMustConfirmBothOriginalCountsAndPolicy() throws {
        let (raw, _, _, command) = try unfinishedFixture()
        for value in [JSON.null, .number(0), .number(1), .number(10001), .bool(true)] {
            var changed = raw["receipt"]!.object; changed["unfinished_recording_count"] = value
            XCTAssertThrowsError(try command.confirmed(changed))
        }
        var changed = raw["receipt"]!.object; changed["recording_count"] = .number(0)
        XCTAssertThrowsError(try command.confirmed(changed))
        changed = raw["receipt"]!.object; changed["recording_policy"] = .string(TeamProjectRecordingPolicy.published.rawValue)
        XCTAssertThrowsError(try command.confirmed(changed))
    }
    func testUnfinishedCapabilityRejectsUnsupportedInventoryAndProtocol() throws {
        let (raw, i, _, _) = try unfinishedFixture()
        for key in ["pending", "retained", "unavailable"] {
            var response = raw["inspect"]!.object, contents = response["contents"]!.object, inventory = contents["recording_custody"]!.object
            inventory[key] = .number(key == "pending" ? 0 : 1); contents["recording_custody"] = .object(inventory); response["contents"] = .object(contents)
            XCTAssertThrowsError(try TeamProjectAdoptionInspection(response, scope: i.scope))
        }
        var response = raw["inspect"]!.object, contents = response["contents"]!.object
        contents["recording_unfinished_transfer"] = .object(["protocol": .number(2), "supported": .bool(true)])
        response["contents"] = .object(contents); XCTAssertThrowsError(try TeamProjectAdoptionInspection(response, scope: i.scope))
    }
    @MainActor func testMixedRecordingConsentSurvivesColdExactRetry() async throws {
        let (raw, _, review, command) = try unfinishedFixture(), io = AdoptionIO(), vault = TeamProjectAdoptionVault(io: io), peer = AdoptionPeer(raw["receipt"]!.object)
        peer.lose = true
        let first = TeamProjectAdoptionModel(account: command.account, origin: command.origin, vault: vault, service: peer, current: { true })
        await first.send(command, canAuthor: { true }, now: review.expires.addingTimeInterval(-60))
        XCTAssertEqual(first.pending, command); XCTAssertNil(first.receipt); first.close()
        XCTAssertFalse(io.encoded.contains("audio_base64")); XCTAssertFalse(io.encoded.contains("Synthetic unfinished original kept privately"))
        let cold = TeamProjectAdoptionModel(account: command.account, origin: command.origin, vault: vault, service: peer, current: { true })
        await cold.load(); XCTAssertEqual(cold.pending?.unfinishedRecordingCount, 2)
        await cold.retry(); XCTAssertNil(cold.pending); XCTAssertEqual(cold.receipt?.command, command)
        XCTAssertEqual(peer.calls, [command, command])
    }
    @MainActor func testBackendCarriesExactPublishedAndUnfinishedChoices() async throws {
        let (raw, i, review, command) = try unfinishedFixture()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AdoptionHTTP.self]
        let session = try JSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(command.account)\"}}".utf8))
        let backend = Backend(configuration: ["URL": command.origin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        var calls = 0
        AdoptionHTTP.handler = { request, peer in
            calls += 1; var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) } }
            let body = try! JSONDecoder().decode([String: JSON].self, from: data)
            XCTAssertEqual(body["body"], .object(try! i.reviewBody(review.decisions, recordingPolicy: .stopUnfinished)))
            peer.finish(raw["review"]!.object)
        }; defer { AdoptionHTTP.handler = nil }
        let result = try await backend.reviewProjectAdoption(i, decisions: review.decisions, connectionPolicy: nil, recordingPolicy: .stopUnfinished)
        XCTAssertEqual(result, review); XCTAssertEqual(calls, 1)
    }
}

extension TeamProjectAdoptionTests {
    private func privateHistoryFixture(_ variant: String? = nil) throws -> ([String: JSON], TeamProjectAdoptionInspection, TeamProjectAdoptionReview, TeamProjectAdoptionCommand) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-project-private-history-v1", withExtension: "json", subdirectory: "Fixtures"))
        let captured = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        XCTAssertEqual(captured["syntheticOnly"], .bool(true)); XCTAssertEqual(captured["containerRemoved"], .bool(true))
        var raw = variant.map { captured[$0]!.object } ?? captured
        raw["account"] = captured["account"]; raw["origin"] = captured["origin"]
        let b = raw["body"]!.object
        let scope = try TeamProjectAdoptionScope(account: raw["account"]!.text, origin: raw["origin"]!.text, team: b["team_id"]!.text, roots: b["roots"]!.list.map(\.text), visibility: .team)
        let i = try TeamProjectAdoptionInspection(raw["inspect"]!.object, scope: scope)
        let decisions = try raw["decisions"]!.list.map { try TeamProjectAdoptionDecision($0.object) }
        let policy = try XCTUnwrap(TeamProjectRecordingPolicy(rawValue: raw["review"]!.object["recording_policy"]!.text))
        let connection = raw["review"]!.object["connection_policy"].flatMap { TeamProjectConnectionPolicy(rawValue: $0.text) }
        let review = try TeamProjectAdoptionReview(raw["review"]!.object, inspection: i, decisions: decisions, connectionPolicy: connection, recordingPolicy: policy)
        let c = try TeamProjectAdoptionCommand(review: review, requestID: UUID(uuidString: raw["command"]!.object["request_id"]!.text)!, now: review.expires.addingTimeInterval(-60))
        return (raw, i, review, c)
    }
    func testActualSQLPrivateHistoryBindsAllCountsAndConnectionPause() throws {
        let (raw, i, review, c) = try privateHistoryFixture()
        XCTAssertTrue(i.recordingPrivateHistoryTransferSupported); XCTAssertFalse(i.recordingTransferSupported); XCTAssertFalse(i.recordingUnfinishedTransferSupported)
        XCTAssertEqual(i.supportedRecordingPolicy, .privateHistory); XCTAssertTrue(review.canCommit)
        XCTAssertEqual(c.recordingCount, 1); XCTAssertEqual(c.unfinishedRecordingCount, 1); XCTAssertEqual(c.retainedRecordingCount, 2)
        XCTAssertEqual(c.connectionPolicy, .pause); XCTAssertEqual(c.connectionEffects?.values["email_routes_paused"], 1)
        XCTAssertEqual(c.body, raw["command"]!.object)
        XCTAssertFalse(try c.confirmed(raw["receipt"]!.object).replayed)
        XCTAssertTrue(try c.confirmed(raw["replayed"]!.object).replayed)
        XCTAssertEqual(try JSONDecoder().decode(TeamProjectAdoptionCommand.self, from: JSONEncoder().encode(c)), c)
    }
    func testActualSQLRemovedOnlyDoesNotInventMovingOrStoppedRecordings() throws {
        let (raw, i, review, c) = try privateHistoryFixture("removedOnly")
        XCTAssertTrue(review.canCommit); XCTAssertEqual(i.supportedRecordingPolicy, .privateHistory)
        XCTAssertEqual(c.recordingCount, 0); XCTAssertEqual(c.unfinishedRecordingCount, 0); XCTAssertEqual(c.retainedRecordingCount, 1)
        XCTAssertEqual(c.body, raw["command"]!.object); XCTAssertNotNil(try c.confirmed(raw["receipt"]!.object))
    }
    func testActualSQLCombinedStopAndConnectionPreservesExistingWire() throws {
        let (raw, i, review, c) = try privateHistoryFixture("combinedUnfinished")
        XCTAssertTrue(review.canCommit); XCTAssertEqual(i.supportedRecordingPolicy, .stopUnfinished)
        XCTAssertEqual(c.connectionPolicy, .pause); XCTAssertEqual(c.recordingCount, 0); XCTAssertEqual(c.unfinishedRecordingCount, 1); XCTAssertNil(c.retainedRecordingCount)
        XCTAssertNil(c.body["retained_recording_count"]); XCTAssertEqual(c.body, raw["command"]!.object)
        XCTAssertNotNil(try c.confirmed(raw["receipt"]!.object))
        var extra = raw["receipt"]!.object; extra["retained_recording_count"] = .number(0)
        XCTAssertThrowsError(try c.confirmed(extra))
    }
    func testRemovedHistoryRequiresItsOwnExplicitChoice() throws {
        let (raw, i, review, _) = try privateHistoryFixture()
        for policy in [TeamProjectRecordingPolicy.published, .stopUnfinished] { XCTAssertThrowsError(try i.reviewBody(review.decisions, connectionPolicy: .pause, recordingPolicy: policy)) }
        var response = raw["review"]!.object
        for key in ["recording_policy", "recording_count", "unfinished_recording_count", "retained_recording_count"] { response.removeValue(forKey: key) }
        let omitted = try TeamProjectAdoptionReview(response, inspection: i, decisions: review.decisions, connectionPolicy: .pause)
        XCTAssertFalse(omitted.canCommit)
        XCTAssertThrowsError(try TeamProjectAdoptionCommand(review: omitted, now: review.expires.addingTimeInterval(-60)))
    }
    func testPrivateHistorySavedMetadataAndBodyCountsCannotDiverge() throws {
        let (_, _, _, c) = try privateHistoryFixture()
        let encoded = try JSONDecoder().decode([String: JSON].self, from: JSONEncoder().encode(c))
        for value in [JSON.null, .number(0), .number(1), .number(10001), .number(1.5), .bool(true)] {
            var changed = encoded; changed["retainedRecordingCount"] = value
            XCTAssertThrowsError(try JSONDecoder().decode(TeamProjectAdoptionCommand.self, from: JSONEncoder().encode(changed)))
        }
        var changed = encoded; changed.removeValue(forKey: "retainedRecordingCount")
        XCTAssertThrowsError(try JSONDecoder().decode(TeamProjectAdoptionCommand.self, from: JSONEncoder().encode(changed)))
        for key in ["recording_count", "unfinished_recording_count", "retained_recording_count"] {
            changed = encoded; var body = changed["body"]!.object; body.removeValue(forKey: key); changed["body"] = .object(body)
            XCTAssertThrowsError(try JSONDecoder().decode(TeamProjectAdoptionCommand.self, from: JSONEncoder().encode(changed)))
        }
    }
    func testPrivateHistoryReceiptMustConfirmExactRetentionChoice() throws {
        let (raw, _, _, c) = try privateHistoryFixture()
        for value in [JSON.null, .number(0), .number(1), .number(3), .number(2.5), .bool(true)] {
            var changed = raw["receipt"]!.object; changed["retained_recording_count"] = value
            XCTAssertThrowsError(try c.confirmed(changed))
        }
        var changed = raw["receipt"]!.object; changed["recording_policy"] = .string(TeamProjectRecordingPolicy.stopUnfinished.rawValue)
        XCTAssertThrowsError(try c.confirmed(changed))
    }
    func testPrivateHistoryCapabilityRejectsInvalidInventoryAndProtocol() throws {
        let (raw, i, _, _) = try privateHistoryFixture()
        for key in ["retained", "unavailable"] {
            var response = raw["inspect"]!.object, contents = response["contents"]!.object, inventory = contents["recording_custody"]!.object
            inventory[key] = .number(key == "retained" ? 0 : 1); contents["recording_custody"] = .object(inventory); response["contents"] = .object(contents)
            XCTAssertThrowsError(try TeamProjectAdoptionInspection(response, scope: i.scope))
        }
        var response = raw["inspect"]!.object, contents = response["contents"]!.object
        contents["recording_private_history_transfer"] = .object(["protocol": .number(2), "supported": .bool(true)])
        response["contents"] = .object(contents); XCTAssertThrowsError(try TeamProjectAdoptionInspection(response, scope: i.scope))
    }
    @MainActor func testPrivateHistoryAndConnectionConsentSurviveColdExactRetry() async throws {
        let (raw, _, review, c) = try privateHistoryFixture(), io = AdoptionIO(), peer = AdoptionPeer(raw["receipt"]!.object)
        peer.lose = true
        let first = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: TeamProjectAdoptionVault(io: io), service: peer, current: { true })
        await first.send(c, canAuthor: { true }, now: review.expires.addingTimeInterval(-60)); XCTAssertEqual(first.pending, c); first.close()
        let cold = TeamProjectAdoptionModel(account: c.account, origin: c.origin, vault: TeamProjectAdoptionVault(io: io), service: peer, current: { true })
        await cold.load(); XCTAssertEqual(cold.pending?.retainedRecordingCount, 2); XCTAssertEqual(cold.pending?.connectionPolicy, .pause)
        await cold.retry(); XCTAssertNil(cold.pending); XCTAssertEqual(cold.receipt?.command, c); XCTAssertEqual(peer.calls, [c, c])
        XCTAssertFalse(io.encoded.contains("Synthetic private removed history")); XCTAssertFalse(io.encoded.contains("audio_base64"))
    }
}
