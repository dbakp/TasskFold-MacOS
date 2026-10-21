import XCTest
@testable import TaskfoldCore

private final class ConversationHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((URLRequest, ConversationHTTP) -> Void)?
    func set(_ value: ((URLRequest, ConversationHTTP) -> Void)?) { lock.lock(); handler = value; lock.unlock() }
    func run(_ request: URLRequest, _ transport: ConversationHTTP) { lock.lock(); let current = handler; lock.unlock(); current?(request, transport) }
}
private final class ConversationHTTP: URLProtocol {
    static let state = ConversationHTTPState()
    private let lock = NSLock(); private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.state.run(request, self) }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
    func finish(_ status: Int, _ data: Data) {
        lock.lock(); let active = !stopped; lock.unlock(); guard active else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
private final class ConversationGate: @unchecked Sendable {
    private let lock = NSLock(); private var held: ConversationHTTP?; private var calls = 0
    func hold(_ value: ConversationHTTP) { lock.lock(); held = value; calls += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func release(_ code: Int, _ data: Data) { lock.lock(); let value = held; held = nil; lock.unlock(); value?.finish(code, data) }
}

final class SharedCommentsTests: XCTestCase {
    func id(_ n: Int) -> String { String(format: "f1781000-0000-4000-8000-%012d", n) }
    var owner: String { id(1) }
    func comment() -> Record {
        Record(["id": .string(id(10)), "task_id": .string(id(20)), "task_generation": .string(id(30)), "project_id": .string(id(40)),
                "author_id": .string(owner), "body": .string("Useful discussion"), "mention_ids": .array([.string(id(2))]),
                "revision": .number(1), "created_at": .string("2026-10-21T02:00:00.123456+00:00"), "updated_at": .string("2026-10-21T02:00:00.123456+00:00"), "deleted_at": .null])
    }
    func mention() -> Record {
        Record(["id": .string(id(50)), "comment_id": .string(id(10)), "recipient_id": .string(owner), "revision": .number(1), "created_at": .string("2026-10-21T02:00:00Z"), "read_at": .null])
    }
    func change(revision: Int64 = 0, deleting: Bool = false) throws -> SharedCommentChange {
        try SharedCommentChange(account: owner, taskID: id(20), taskGeneration: id(30), projectID: id(40), commentID: id(10), expectedRevision: revision, body: deleting ? "" : "Useful discussion", mentionIDs: deleting ? [] : [id(2)], deleting: deleting, operationID: id(60))
    }
    func response(_ row: Record, status: String = "saved", revision: Int = 1, operation: String? = nil) throws -> Data {
        try JSONEncoder().encode(Record(["status": .string(status), "operation_id": .string(operation ?? id(60)), "acknowledged_revision": .number(Double(revision)), "current": .object(row.fields)]))
    }
    func testLosslessRecordsRetainUnknownMetadataAndAbsentAuthorWithoutInventingIdentity() throws {
        var row = comment(); row["future"] = .object(["opaque": .string("retained")]); row["author_id"] = .null
        let parsed = try XCTUnwrap(SharedComment(row)); XCTAssertNil(parsed.authorID); XCTAssertEqual(parsed.row, row)
        var notification = mention(); notification["future"] = .number(3)
        XCTAssertEqual(SharedMention(notification)?.row, notification)
        XCTAssertFalse(try XCTUnwrap(SharedMention(notification)).isRead)
    }
    func testStrictCommentRecordBoundsTypesIdentitiesAndTombstones() throws {
        for (key, bad) in [("id", JSON.string("bad")), ("task_generation", .string("00000000-0000-0000-0000-000000000000")), ("author_id", .string("")), ("revision", .number(1.5)), ("revision", .number(0)), ("revision", .number(9_007_199_254_740_992)), ("created_at", .string("bad")), ("deleted_at", .bool(false)), ("body", .number(2)), ("body", .string(String(repeating: "😀", count: 4001))), ("mention_ids", .array([.string(id(2)), .string(id(2).uppercased())])), ("mention_ids", .array([.null]))] {
            var row = comment(); row[key] = bad; XCTAssertNil(SharedComment(row), key)
        }
        var row = comment(); row.fields.removeValue(forKey: "author_id"); XCTAssertNil(SharedComment(row))
        row = comment(); row["deleted_at"] = .string("2026-10-21T02:01:00Z"); XCTAssertNil(SharedComment(row))
        row["body"] = .string(""); row["mention_ids"] = .array([]); XCTAssertTrue(try XCTUnwrap(SharedComment(row)).isDeleted)
    }
    func testStrictMentionRecordReadStateAndRecipientIdentity() throws {
        for (key, bad) in [("recipient_id", JSON.string("unknown")), ("comment_id", .null), ("revision", .number(-1)), ("read_at", .bool(true)), ("created_at", .string("infinity"))] {
            var row = mention(); row[key] = bad; XCTAssertNil(SharedMention(row), key)
        }
        var row = mention(); row["read_at"] = .string("2026-10-21T02:01:00Z"); XCTAssertTrue(try XCTUnwrap(SharedMention(row)).isRead)
    }
    func testDurableCommentIntentNormalizesRecipientsAndPayloadCannotSupplyAuthorship() throws {
        let value = try SharedCommentChange(account: owner.uppercased(), taskID: id(20), taskGeneration: id(30), projectID: id(40), commentID: id(10), body: "Literal @person", mentionIDs: [id(3), id(2).uppercased(), id(2)], operationID: id(60))
        XCTAssertEqual(value.account, owner); XCTAssertEqual(value.mentionIDs, [id(2), id(3)])
        XCTAssertEqual(try JSONDecoder().decode(SharedCommentChange.self, from: JSONEncoder().encode(value)), value)
        XCTAssertEqual(Set(value.payload.keys), ["_operation_id", "_comment_id", "_task_id", "_task_generation", "_project_id", "_expected_revision", "_body", "_mentions", "_delete"])
        XCTAssertEqual(value.payload["_mentions"]?.list.count, 2); XCTAssertEqual(value.body, "Literal @person")
        XCTAssertNil(value.payload["author_id"]); XCTAssertNil(value.payload["authorName"]); XCTAssertNil(value.payload["account"])
    }
    func testInvalidOrNewerSavedIntentsAreRefusedWithoutAlteringTheirRawEnvelope() throws {
        let good = try change().record
        for (key, bad) in [("version", JSON.number(2)), ("kind", .string("future")), ("task_generation", .string("00000000-0000-0000-0000-000000000000")), ("body", .string(" \n\t")), ("body", .string("nul\u{0}")), ("body", .string(String(repeating: "😀", count: 4001))), ("mention_ids", .array(Array(repeating: .string(id(2)), count: 26))), ("expected_revision", .number(-1)), ("delete", .bool(true)), ("author_id", .string(owner))] {
            var row = good; row[key] = bad; let original = row
            XCTAssertThrowsError(try SharedCommentChange(record: row), key); XCTAssertEqual(row, original)
            XCTAssertThrowsError(try JSONDecoder().decode(SharedCommentChange.self, from: JSONEncoder().encode(row)))
        }
        _ = try SharedCommentChange(account: owner, taskID: id(20), taskGeneration: id(30), projectID: id(40), body: String(repeating: "😀", count: 4000))
        XCTAssertThrowsError(try SharedCommentChange(account: owner, taskID: id(20), taskGeneration: id(30), projectID: id(40), expectedRevision: Int64.max, body: "Too new"))
    }
    func testSavedReplyAcknowledgesOriginalWriteButPreservesNewerCurrentTombstone() throws {
        var row = comment(); row["revision"] = .number(5); row["body"] = .string(""); row["mention_ids"] = .array([]); row["deleted_at"] = .string("2026-10-21T02:01:00Z")
        let reply = try SharedCommentReply(data: response(row), change: change())
        XCTAssertEqual(reply.acknowledgedRevision, 1); XCTAssertEqual(reply.current?.revision, 5); XCTAssertEqual(reply.current?.isDeleted, true)
        var moderated = row; moderated["author_id"] = .string(id(2))
        let deletion = try SharedCommentReply(data: response(moderated, revision: 5), change: change(revision: 4, deleting: true))
        XCTAssertEqual(deletion.current?.authorID, id(2)); XCTAssertEqual(deletion.acknowledgedRevision, 5)
    }
    func testReplyCannotCrossTaskGenerationProjectAuthorOrOperationAndCannotForgeRevision() throws {
        for (key, bad) in [("id", JSON.string(id(11))), ("task_id", .string(id(21))), ("task_generation", .string(id(31))), ("project_id", .string(id(41))), ("author_id", .string(id(2)))] {
            var row = comment(); row[key] = bad; XCTAssertThrowsError(try SharedCommentReply(data: response(row), change: change()), key)
        }
        XCTAssertThrowsError(try SharedCommentReply(data: response(comment(), operation: id(61)), change: change()))
        XCTAssertThrowsError(try SharedCommentReply(data: response(comment(), revision: 2), change: change()))
        var row = comment(); row["revision"] = .number(8)
        XCTAssertThrowsError(try SharedCommentReply(data: response(row, revision: 8), change: change(revision: 1)))
        let conflict = try SharedCommentReply(data: response(row, status: "conflict"), change: change(revision: 1))
        XCTAssertEqual(conflict.status, .conflict); XCTAssertNil(conflict.acknowledgedRevision)
    }
    func testCurrentAcknowledgementMustActuallyMatchTheRequestedCommentOrReadState() throws {
        var row = comment(); row["body"] = .string("Different content")
        XCTAssertThrowsError(try SharedCommentReply(data: response(row), change: change()))
        row = comment(); row["mention_ids"] = .array([])
        XCTAssertThrowsError(try SharedCommentReply(data: response(row), change: change()))
        XCTAssertThrowsError(try SharedCommentReply(data: response(comment()), change: change(revision: 1, deleting: true)))
        let read = try SharedMentionChange(mention: XCTUnwrap(SharedMention(mention())), account: owner, read: true, operationID: id(60))
        XCTAssertThrowsError(try SharedMentionReply(data: response(mention()), change: read))
    }
    func testUnavailableStatusesNeverAcknowledgeOrApplyPayload() throws {
        for status in ["unavailable", "archived", "forbidden", "recipients_changed"] {
            let data = try JSONEncoder().encode(Record(["status": .string(status)]))
            let reply = try SharedCommentReply(data: data, change: change()); XCTAssertNil(reply.current); XCTAssertNil(reply.acknowledgedRevision)
            XCTAssertThrowsError(try SharedCommentReply(data: response(comment(), status: status), change: change()))
        }
        XCTAssertThrowsError(try SharedCommentReply(data: Data(#"{"status":"future"}"#.utf8), change: change()))
    }
    func testMentionIntentAndLateReadAcknowledgementKeepTheNewerUnreadState() throws {
        let original = try XCTUnwrap(SharedMention(mention())), change = try SharedMentionChange(mention: original, account: owner, read: true, operationID: id(60))
        XCTAssertEqual(try JSONDecoder().decode(SharedMentionChange.self, from: JSONEncoder().encode(change)), change)
        XCTAssertEqual(Set(change.payload.keys), ["_operation_id", "_mention_id", "_expected_revision", "_read"])
        var newer = mention(); newer["revision"] = .number(3)
        let reply = try SharedMentionReply(data: response(newer, revision: 2), change: change)
        XCTAssertEqual(reply.acknowledgedRevision, 2); XCTAssertEqual(reply.current?.revision, 3); XCTAssertEqual(reply.current?.isRead, false)
        XCTAssertThrowsError(try SharedMentionChange(mention: original, account: id(2), read: true))
        var raw = change.record; raw["version"] = .number(2); XCTAssertThrowsError(try SharedMentionChange(record: raw))
    }
    func testMentionReplyCannotApplyAnotherRecipientCommentOrIdentity() throws {
        let value = try SharedMentionChange(mention: XCTUnwrap(SharedMention(mention())), account: owner, read: true, operationID: id(60))
        for key in ["id", "recipient_id", "comment_id"] {
            var row = mention(); row[key] = .string(id(99)); XCTAssertThrowsError(try SharedMentionReply(data: response(row), change: value), key)
        }
        XCTAssertThrowsError(try SharedMentionReply(data: response(mention(), operation: id(61)), change: value))
        XCTAssertThrowsError(try SharedMentionReply(data: response(mention(), revision: 2), change: value))
        XCTAssertThrowsError(try SharedMentionReply(data: response(mention(), status: "archived"), change: value))
    }
    @MainActor private func api(_ account: String) throws -> Backend {
        let session = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(Record(["access_token": .string("synthetic"), "refresh_token": .string("synthetic-refresh"), "expires_in": .number(3600), "user": .object(["id": .string(account)])])))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ConversationHTTP.self]
        return Backend(configuration: ["URL": "https://conversation.example.invalid", "Key": "public-fixture"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
    }
    private func body(_ request: URLRequest) throws -> Record {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        }
        return try JSONDecoder().decode(Record.self, from: data)
    }
    @MainActor func testNativeRPCPayloadsUseOnlyVerifiedAccountBoundArguments() async throws {
        let backend = try api(owner), change = try change(), reply = try response(comment())
        ConversationHTTP.state.set { request, transport in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_write_comment"); XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
            XCTAssertEqual(try? self.body(request).fields, change.payload); transport.finish(200, reply)
        }; defer { ConversationHTTP.state.set(nil) }
        let written = try await backend.writeSharedComment(change); XCTAssertEqual(written.current?.id, change.commentID)
        let read = try SharedMentionChange(mention: XCTUnwrap(SharedMention(mention())), account: owner, read: true, operationID: id(60))
        var next = mention(); next["revision"] = .number(2); next["read_at"] = .string("2026-10-21T02:01:00Z"); let result = try response(next, revision: 2)
        ConversationHTTP.state.set { request, transport in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_mark_mention"); XCTAssertEqual(try? self.body(request).fields, read.payload); transport.finish(200, result)
        }
        let marked = try await backend.markSharedMention(read); XCTAssertEqual(marked.current?.isRead, true)
    }
    @MainActor func testStaleAccountIsRefusedBeforeAnyHTTP() async throws {
        let backend = try api(id(2)), gate = ConversationGate()
        backend.session?.expires_at = 0
        ConversationHTTP.state.set { _, transport in gate.hold(transport); transport.finish(200, Data("{}".utf8)) }; defer { ConversationHTTP.state.set(nil) }
        do { _ = try await backend.writeSharedComment(change()); XCTFail("Old account was sent") } catch { XCTAssertTrue(error is CancellationError) }
        let read = try SharedMentionChange(mention: XCTUnwrap(SharedMention(mention())), account: owner, read: true)
        do { _ = try await backend.markSharedMention(read); XCTFail("Old inbox was sent") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(gate.count, 0)
    }
    @MainActor func testHeldWriteCannotApplyAfterLeavingAndReturningToSameAccount() async throws {
        let backend = try api(owner), gate = ConversationGate(), started = expectation(description: "Comment held")
        let change = try change(), result = try response(comment())
        ConversationHTTP.state.set { _, transport in gate.hold(transport); started.fulfill() }; defer { ConversationHTTP.state.set(nil) }
        let request = Task { @MainActor in try await backend.writeSharedComment(change) }
        await fulfillment(of: [started], timeout: 3)
        let same = try XCTUnwrap(backend.session); try await backend.clearSession(); try await backend.accept(same)
        gate.release(200, result)
        do { _ = try await request.value; XCTFail("Late write crossed session incarnation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(gate.count, 1)
    }
    @MainActor func testHeldReadCannotRetry401UnderAnotherAccount() async throws {
        let backend = try api(owner), gate = ConversationGate(), started = expectation(description: "Mention held")
        let read = try SharedMentionChange(mention: XCTUnwrap(SharedMention(mention())), account: owner, read: true)
        ConversationHTTP.state.set { _, transport in gate.hold(transport); started.fulfill() }; defer { ConversationHTTP.state.set(nil) }
        let request = Task { @MainActor in try await backend.markSharedMention(read) }
        await fulfillment(of: [started], timeout: 3)
        let next = try XCTUnwrap(api(id(2)).session); try await backend.accept(next); gate.release(401, Data(#"{"message":"Expired"}"#.utf8))
        do { _ = try await request.value; XCTFail("Old read retried with new account") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(gate.count, 1)
    }
}
