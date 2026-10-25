import XCTest
@testable import TaskfoldCore

private final class CompletionBatchHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, CompletionBatchHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var value = request
        if value.httpBody == nil, let stream = value.httpBodyStream {
            stream.open(); defer { stream.close() }; var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
            value.httpBody = data
        }
        Self.handler?(value, self)
    }
    func finish(_ data: Data, status: Int = 200) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json", "Content-Length": String(data.count)])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
private final class CompletionBatchGate: @unchecked Sendable {
    private let lock = NSLock(); private var peer: CompletionBatchHTTP?
    func hold(_ value: CompletionBatchHTTP) { lock.lock(); peer = value; lock.unlock() }
    func release(_ data: Data) { lock.lock(); let value = peer; peer = nil; lock.unlock(); value?.finish(data) }
}
final class TeamCompletionBatchTests: XCTestCase {
    private let origin = "https://backend.example"
    private func fixture(_ phase: String = "") throws -> ([String: JSON], Mutation, TeamTaskBatch, [String: JSON]) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-completion-batch-v1", withExtension: "json", subdirectory: "Fixtures"))
        let f = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url)), body = f[phase + "body"]!.object
        let action: TeamCompletion.Operation = phase == "undo_" ? .undo : .complete
        let items = try body["items"]!.list.map { value -> Mutation in
            let b = value.object, source = Record(b["record"]!.object), nonce = UUID(uuidString: b["request_id"]!.text)!
            let related = b[action == .undo ? "undoes" : "redo_of"].flatMap { UUID(uuidString: $0.text) }
            let scope = TeamTaskEditScope(account: f["account"]!.text, origin: origin, team: body["team_id"]!.text, project: b["project_id"]!.text)
            let predicted = try TeamCompletion.complete(source, tasks: [source], scope: scope, at: TaskPlanning.instant(b["completed_at"]!.text)!, zone: b["input_zone"]!.text, id: action == .undo ? related! : nonce)
            var proposed = predicted.teamCompletion!.proposed; proposed?["task_generation"] = b["next_generation"]!
            let command = TeamCompletion(scope: scope, operation: action, source: source, completedAt: b["completed_at"]!.text, inputZone: b["input_zone"]!.text,
                seriesID: b["series_id"]!.text, seriesGeneration: b["series_generation"]!.text, seriesProject: b["series_project_id"]!.text,
                nextGeneration: b["next_generation"]!.text, proposed: proposed, related: related)
            return TeamCompletion.header(command, id: nonce)
        }
        let batch = TeamTaskBatch(account: f["account"]!.text, origin: origin, team: body["team_id"]!.text, operation: action == .undo ? .undoComplete : .complete,
            restores: body["related_request"].flatMap { UUID(uuidString: $0.text) }, items: items)
        return (body, TeamTaskBatch.header(batch, id: UUID(uuidString: body["request_id"]!.text)!), batch, f[phase + "reply"]!.object)
    }
    private func snapshot(_ batch: TeamTaskBatch) -> Snapshot {
        let ids = Set(batch.items.flatMap { [$0.teamCompletion!.scope.project, $0.teamCompletion!.seriesProject] })
        return Snapshot(tables: ["tasks": batch.items.map { $0.teamCompletion!.source }, "projects": ids.sorted().map { Record(["id": .string($0)]) }])
    }
    private func receipt(_ header: Mutation, _ raw: [String: JSON]) -> Record { Record(["id": .string(header.recordID), "team_completion_batch_reply": .object(raw)]) }
    func testFrozenCommandsMatchActualSQLCompleteUndoRedoAndRecurringEnvelopes() throws {
        for phase in ["", "undo_", "redo_", "recurring_"] {
            let (body, header, batch, reply) = try fixture(phase)
            XCTAssertEqual(try batch.body(for: header), body)
            XCTAssertEqual(try batch.completionReceipts(reply, for: header).count, batch.items.count)
            XCTAssertEqual(try JSONDecoder().decode(Mutation.self, from: JSONEncoder().encode(header)), header)
            XCTAssertEqual(try TeamTaskBatch.preparing([header], snapshot: snapshot(batch)), [header])
        }
    }
    func testMalformedForeignNestedAndPartiallyGroupedCommandsAreRefused() throws {
        let (_, header, batch, _) = try fixture()
        var wrong = header; wrong.teamCompletion = batch.items.first!.teamCompletion
        XCTAssertThrowsError(try batch.body(for: wrong))
        var nested = batch; nested.items[0].teamTaskBatch = batch; XCTAssertThrowsError(try nested.body(for: TeamTaskBatch.header(nested)))
        var duplicate = batch; duplicate.items[1].id = duplicate.items[0].id; XCTAssertThrowsError(try duplicate.body(for: TeamTaskBatch.header(duplicate)))
        var reordered = batch; reordered.items.reverse(); XCTAssertThrowsError(try reordered.body(for: TeamTaskBatch.header(reordered)))
        var mixed = batch; mixed.items[0] = Mutation(table: "tasks", recordID: mixed.items[0].recordID, method: "PATCH", fields: ["completed": .bool(true)])
        XCTAssertThrowsError(try mixed.body(for: TeamTaskBatch.header(mixed)))
        let foreign = TeamTaskBatch(account: UUID().uuidString.lowercased(), origin: batch.origin, team: batch.team, operation: batch.operation, restores: nil, items: batch.items)
        XCTAssertThrowsError(try foreign.body(for: TeamTaskBatch.header(foreign)))
        XCTAssertThrowsError(try TeamTaskBatch.preparing(batch.items, snapshot: snapshot(batch)), "No loop of independently queued completions")
    }
    func testLocalProjectionIsAtomicOnMissingRecreatedAndChangedLastSource() throws {
        let (_, header, batch, _) = try fixture()
        for key in ["task_generation", "description", "completion_version"] {
            var local = snapshot(batch); local.tables["tasks"]![1][key] = .string("newer")
            let before = local; XCTAssertFalse(batch.apply(to: &local, header: header)); XCTAssertEqual(local, before)
        }
        var local = snapshot(batch); local.tables["tasks"]!.removeLast(); let missing = local
        XCTAssertFalse(batch.apply(to: &local, header: header)); XCTAssertEqual(local, missing)
        local = snapshot(batch); local.tables["projects"] = []; let denied = local
        XCTAssertFalse(batch.apply(to: &local, header: header)); XCTAssertEqual(local, denied)
    }
    func testOneHistoryEntryCarriesAllMemberInverseAndFreshRedoIdentities() throws {
        let (_, header, batch, _) = try fixture("recurring_"); let before = snapshot(batch)
        let history = EditHistory(changes: [header], snapshot: before); var local = before; local.apply(header)
        XCTAssertEqual(local.tables["tasks"]?.filter(\.completed).count, 2)
        XCTAssertEqual(local.tables["tasks"]?.count, 4)
        let inverse = TeamCompletion.historyAction(try XCTUnwrap(history.undo.first), snapshot: local), undo = try XCTUnwrap(inverse.teamTaskBatch)
        XCTAssertEqual(undo.operation, .undoComplete); XCTAssertEqual(undo.restores, header.id)
        XCTAssertEqual(undo.items.compactMap { $0.teamCompletion?.related }, batch.items.map(\.id))
        XCTAssertTrue(Set(undo.items.map(\.id)).isDisjoint(with: batch.items.map(\.id)))
        let undoHistory = EditHistory(changes: [inverse], snapshot: local)
        local.apply(inverse); XCTAssertEqual(local.tables["tasks"]?.count, 2); XCTAssertTrue(local.tables["tasks"]!.allSatisfy { !$0.completed })
        let redo = TeamCompletion.historyAction(try XCTUnwrap(undoHistory.undo.first), snapshot: local), redone = try XCTUnwrap(redo.teamTaskBatch)
        XCTAssertEqual(redone.operation, .complete); XCTAssertEqual(redone.restores, inverse.id)
        XCTAssertEqual(redone.items.compactMap { $0.teamCompletion?.related }, undo.items.map(\.id))
        XCTAssertTrue(Set(redone.items.map(\.id)).isDisjoint(with: undo.items.map(\.id)))
        XCTAssertNotEqual(redone.items.compactMap { $0.teamCompletion?.proposed?["task_generation"] }, batch.items.compactMap { $0.teamCompletion?.proposed?["task_generation"] })
        local.apply(redo); XCTAssertEqual(local.tables["tasks"]?.count, 4)
        XCTAssertNoThrow(try redone.body(for: redo))
    }
    func testWholeReplyMustValidateBeforeAnyPendingActionIsRemoved() throws {
        let (_, header, batch, reply) = try fixture(); var local = snapshot(batch); local.apply(header); local.pending = [header]
        for key in ["account", "team_id", "request_id", "operation", "related_request", "batch_protocol"] {
            var wrong = reply; wrong[key] = .string("wrong"); let before = local
            XCTAssertFalse(local.acknowledge(header, saved: receipt(header, wrong))); XCTAssertEqual(local, before, key)
        }
        var partial = reply; partial["items"] = .array(Array(reply["items"]!.list.dropLast()))
        let before = local; XCTAssertFalse(local.acknowledge(header, saved: receipt(header, partial))); XCTAssertEqual(local, before)
        var swapped = reply; swapped["items"] = .array(reply["items"]!.list.reversed()); XCTAssertFalse(local.acknowledge(header, saved: receipt(header, swapped))); XCTAssertEqual(local, before)
        var badLast = reply, members = reply["items"]!.list; var last = members[1].object; last["source_revision"] = .number(-1); members[1] = .object(last); badLast["items"] = .array(members)
        XCTAssertFalse(local.acknowledge(header, saved: receipt(header, badLast))); XCTAssertEqual(local, before)
        XCTAssertTrue(local.acknowledge(header, saved: receipt(header, reply))); XCTAssertTrue(local.pending.isEmpty)
    }
    func testUnrelatedQueuedWorkIsPreservedAndTouchingCohortsStayDurable() throws {
        let (_, header, batch, reply) = try fixture(); var local = snapshot(batch); local.apply(header)
        let other = Mutation(table: "tasks", recordID: UUID().uuidString.lowercased(), method: "POST", fields: ["title": .string("Unrelated private draft")])
        local.apply(other); local.pending = [header, other]; let outside = local.tables["tasks"]!.last!
        XCTAssertTrue(local.acknowledge(header, saved: receipt(header, reply))); XCTAssertEqual(local.pending, [other]); XCTAssertEqual(local.tables["tasks"]!.last, outside)
        local = snapshot(batch); local.apply(header); let undo = try batch.inverse(of: header, snapshot: local); local.apply(undo); local.pending = [header, undo]
        let before = local; XCTAssertFalse(local.acknowledge(header, saved: receipt(header, reply))); XCTAssertEqual(local, before, "Dependent Undo requires cohort reconciliation; it cannot be dropped")
    }
    func testLastMemberProvisionalDraftPreventsPartialAcknowledgement() throws {
        let (_, header, batch, reply) = try fixture("recurring_"); var local = snapshot(batch); local.apply(header); local.pending = [header]
        let last = batch.items.last!.teamCompletion!.proposed!
        let index = try XCTUnwrap(local.tables["tasks"]?.firstIndex { $0.id == last.id }); local.tables["tasks"]![index]["title"] = .string("Authored provisional draft")
        var adopted = reply, members = reply["items"]!.list, value = members[1].object, successor = value["successor"]!.object
        let generation = UUID().uuidString.lowercased(); successor["task_generation"] = .string(generation); value["successor"] = .object(successor); value["successor_generation"] = .string(generation); value["created_successor"] = .bool(false); members[1] = .object(value); adopted["items"] = .array(members)
        let before = local; XCTAssertFalse(local.acknowledge(header, saved: receipt(header, adopted))); XCTAssertEqual(local, before)
    }
    @MainActor private func backend(_ account: String) throws -> Backend {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CompletionBatchHTTP.self]
        let session = try JSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(account)\"}}".utf8))
        return Backend(configuration: ["URL": origin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
    }
    @MainActor func testBackendUsesOnePrivateBoundedRPCAndKeepsFrozenRetry() async throws {
        let (body, header, batch, reply) = try fixture(), api = try backend(batch.account); var requests = [URLRequest]()
        CompletionBatchHTTP.handler = { request, peer in
            requests.append(request); XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_complete_team_tasks")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store"); XCTAssertFalse(request.httpShouldHandleCookies); XCTAssertEqual(request.timeoutInterval, 25)
            let sent = try! JSONDecoder().decode([String: JSON].self, from: request.httpBody!)
            XCTAssertEqual(sent, ["_action": .string("complete"), "_body": .object(body)]); peer.finish(try! JSONEncoder().encode(reply))
        }; defer { CompletionBatchHTTP.handler = nil }
        let first = try await api.send(header); let retry = try await api.send(header); XCTAssertEqual(first, retry); XCTAssertEqual(requests.count, 2); XCTAssertEqual(try JSONDecoder().decode([String: JSON].self, from: requests[0].httpBody!), try JSONDecoder().decode([String: JSON].self, from: requests[1].httpBody!))
        CompletionBatchHTTP.handler = { _, peer in peer.finish(Data("{\"code\":\"PT409\",\"message\":\"private server details\"}".utf8), status: 409) }
        do { _ = try await api.send(header); XCTFail("Rejected group acknowledged") } catch { XCTAssertFalse(error.localizedDescription.contains("private server details")); XCTAssertTrue(error.localizedDescription.contains("selection")) }
    }
    @MainActor func testBackendCannotSendOrAcknowledgeAnotherAccount() async throws {
        let (_, header, batch, reply) = try fixture(), api = try backend(batch.account), gate = CompletionBatchGate(), started = expectation(description: "Batch response held")
        CompletionBatchHTTP.handler = { _, peer in gate.hold(peer); started.fulfill() }; defer { CompletionBatchHTTP.handler = nil }
        let pending = Task { @MainActor in try await api.send(header) }; await fulfillment(of: [started], timeout: 3)
        var other = api.session!; other.user.id = UUID().uuidString.lowercased(); try await api.accept(other); gate.release(try JSONEncoder().encode(reply))
        do { _ = try await pending.value; XCTFail("Late group reply reached another account") } catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await api.send(header); XCTFail("Foreign group sent") } catch { XCTAssertTrue(error is CancellationError) }
    }
}


extension TeamCompletionBatchTests {
    func testAccessMaskKnowsEverySourceAndSuccessorAndBlocksWholeGroup() throws {
        let (_, header, batch, _) = try fixture("recurring_")
        let projectIDs = Set(batch.items.map { $0.teamCompletion!.scope.project }).sorted()
        var raw: [String: JSON] = ["workspace_boundary_protocol": .number(1), "account": .string(batch.account), "native_team_reads_enabled": .bool(true), "setup_paused": .bool(false), "token": .string(String(repeating: "a", count: 64)),
            "teams": .array([.object(["id": .string(batch.team), "state": .string("active"), "revision": .number(1), "access_revision": .number(1)])]),
            "projects": .array(projectIDs.map { .object(["id": .string($0), "team_id": .string(batch.team), "role": .string("editor"), "archived": .bool(false), "can_send_tasks": .bool(true)]) })]
        let boundary = try TeamWorkspaceBoundary(raw, account: batch.account, origin: batch.origin)
        let active = try TeamWorkspaceCache(boundary: boundary, previous: nil, pending: [header])
        var local = snapshot(batch); local.apply(header); local.pending = [header]
        XCTAssertTrue(active.canSend(header, in: local))
        for item in batch.items { XCTAssertTrue(active.knownTasks.contains(item.recordID)); XCTAssertTrue(active.knownTasks.contains(item.teamCompletion!.proposed!.id)) }
        raw["teams"] = .array([]); raw["projects"] = .array([])
        let left = try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(raw, account: batch.account, origin: batch.origin), previous: active, pending: [header])
        XCTAssertFalse(left.canSend(header, in: local)); XCTAssertTrue(left.blocked(local).contains(header.id))
        XCTAssertEqual(left.filtering(local.tables)["tasks"], [])
        XCTAssertEqual(left.knownTasks, active.knownTasks)
        XCTAssertNil(local.recoveryProjectIDs(for: header).first, "Shared groups cannot be mistaken for personal project recovery")
    }
    @MainActor func testSameAccountReauthenticationRejectsInFlightBatchReply() async throws {
        let (_, header, batch, reply) = try fixture(), api = try backend(batch.account), gate = CompletionBatchGate(), started = expectation(description: "Same-account batch held")
        CompletionBatchHTTP.handler = { _, peer in gate.hold(peer); started.fulfill() }; defer { CompletionBatchHTTP.handler = nil }
        let pending = Task { @MainActor in try await api.send(header) }; await fulfillment(of: [started], timeout: 3)
        var next = api.session!; next.access_token = "different-synthetic-session"; try await api.accept(next); gate.release(try JSONEncoder().encode(reply))
        do { _ = try await pending.value; XCTFail("Old batch response reached a new session for the same account") } catch { XCTAssertTrue(error is CancellationError) }
    }
}


extension TeamCompletionBatchTests {
    func testRecurringReceiptsAndExactReplayConfirmAllSourcesAndSuccessors() throws {
        let (_, header, batch, reply) = try fixture("recurring_")
        var local = snapshot(batch); local.apply(header); local.pending = [header]
        XCTAssertTrue(local.acknowledge(header, saved: receipt(header, reply))); XCTAssertTrue(local.pending.isEmpty)
        XCTAssertEqual(local.tables["tasks"]?.count, 4)
        var repeated = reply, rows = reply["items"]!.list
        repeated["replayed"] = .bool(true)
        for i in rows.indices { var row = rows[i].object; row["replayed"] = .bool(true); rows[i] = .object(row) }
        repeated["items"] = .array(rows)
        XCTAssertNoThrow(try batch.confirm(repeated, for: header))
        repeated["items"] = reply["items"]
        XCTAssertThrowsError(try batch.confirm(repeated, for: header), "A replay cannot mix fresh and recorded member responses")
    }
    func testConvergingLocalMembersShareOneSuccessorAndUndoAsOneGroup() throws {
        let (_, _, original, _) = try fixture("recurring_")
        let first = original.items[0].teamCompletion!, second = original.items[1].teamCompletion!
        var child = second.source; child["recurrence_parent_id"] = .string(first.source.id)
        let roots = [first.source, child]
        let items = try roots.enumerated().map { i, row in
            try TeamCompletion.complete(row, tasks: roots, scope: i == 0 ? first.scope : second.scope,
                at: TaskPlanning.instant(first.completedAt)!, zone: first.inputZone)
        }
        let batch = TeamTaskBatch(account: original.account, origin: original.origin, team: original.team, operation: .complete, restores: nil, items: items)
        let header = TeamTaskBatch.header(batch)
        XCTAssertEqual(items[0].teamCompletion?.proposed?.id, items[1].teamCompletion?.proposed?.id)
        var local = snapshot(batch); XCTAssertTrue(batch.apply(to: &local, header: header)); XCTAssertEqual(local.tables["tasks"]?.count, 3)
        let undo = try batch.inverse(of: header, snapshot: local)
        XCTAssertTrue(undo.teamTaskBatch!.apply(to: &local, header: undo)); XCTAssertEqual(local.tables["tasks"]?.count, 2)
        XCTAssertTrue(local.tables["tasks"]!.allSatisfy { !$0.completed })
    }
}
