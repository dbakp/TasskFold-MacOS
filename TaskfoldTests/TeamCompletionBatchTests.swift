import XCTest
import CryptoKit
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
        let before = local; XCTAssertTrue(local.acknowledge(header, saved: receipt(header, reply))); XCTAssertEqual(local.pending, [undo])
        for row in before.tables["tasks"]! { XCTAssertTrue(TeamCompletion.sameLocal(row, local.tables["tasks"]!.first { $0.id == row.id }!)) }
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

extension TeamCompletionBatchTests {
    private func append(_ change: Mutation, to value: inout Snapshot) { value.apply(change); value.pending.append(change) }
    private func patch(_ row: Record, _ fields: [String: JSON], scope: TeamTaskEditScope) throws -> Mutation {
        try scope.capturing(Mutation(table: "tasks", recordID: row.id, method: "PATCH", fields: fields, baseline: TaskCompletionRevision.editBaseline(for: fields, from: row), teamTaskScope: scope), existing: row)
    }
    private func sameRows(_ a: Snapshot, _ b: Snapshot, file: StaticString = #filePath, line: UInt = #line) {
        let left = a.tables["tasks"] ?? [], right = b.tables["tasks"] ?? []
        XCTAssertEqual(Set(left.map(\.id)), Set(right.map(\.id)), file: file, line: line)
        for row in left {
            guard let other = right.first(where: { $0.id == row.id }) else { continue }
            XCTAssertTrue(TeamCompletion.sameLocal(row, other), row.id, file: file, line: line)
        }
    }
    private func recurringChain() throws -> (Mutation, TeamTaskBatch, [String: JSON], Mutation, Mutation, Snapshot) {
        let (_, header, batch, reply) = try fixture("recurring_"); var local = snapshot(batch)
        append(header, to: &local)
        let firstHistory = EditHistory(changes: [header], snapshot: snapshot(batch))
        let undo = TeamCompletion.historyAction(firstHistory.undo[0], snapshot: local)
        let undoHistory = EditHistory(changes: [undo], snapshot: local); append(undo, to: &local)
        let redo = TeamCompletion.historyAction(undoHistory.undo[0], snapshot: local); append(redo, to: &local)
        return (header, batch, reply, undo, redo, local)
    }
    func testSQLCompleteUndoRedoChainConfirmsSequentiallyWithoutRewritingRemainingRequests() throws {
        let (_, header, batch, reply) = try fixture(), (_, undo, _, undoReply) = try fixture("undo_"), (_, redo, _, redoReply) = try fixture("redo_")
        var local = snapshot(batch); append(header, to: &local); append(undo, to: &local); append(redo, to: &local)
        let before = local, frozen = try JSONEncoder().encode(local.pending)
        XCTAssertTrue(local.acknowledge(header, saved: receipt(header, reply))); XCTAssertEqual(local.pending, [undo, redo]); sameRows(local, before)
        XCTAssertEqual(try JSONDecoder().decode([Mutation].self, from: frozen).dropFirst().map { $0 }, local.pending)
        XCTAssertTrue(local.acknowledge(undo, saved: receipt(undo, undoReply))); XCTAssertEqual(local.pending, [redo]); sameRows(local, before)
        XCTAssertTrue(local.acknowledge(redo, saved: receipt(redo, redoReply))); XCTAssertTrue(local.pending.isEmpty); sameRows(local, before)
    }
    func testRecurringUndoRedoProjectionKeepsLatestSuccessorGenerationsAndExactQueue() throws {
        let (header, _, reply, undo, redo, current) = try recurringChain(); var local = current
        XCTAssertTrue(local.acknowledge(header, saved: receipt(header, reply))); XCTAssertEqual(local.pending, [undo, redo]); sameRows(local, current)
        XCTAssertEqual(Set(local.tables["tasks"]!.filter { !$0.completed }.map { $0.string("task_generation") }), Set(redo.teamTaskBatch!.items.map { $0.teamCompletion!.nextGeneration }))
    }
    func testQueuedScopedRootEditReplaysAndRetainsItsOriginalBaselineAndNonce() throws {
        let (_, header, batch, reply) = try fixture(); var local = snapshot(batch); append(header, to: &local)
        let row = local.tables["tasks"]![0], change = try patch(row, ["description": .string("Authored while completion was syncing")], scope: batch.items[0].teamCompletion!.scope)
        append(change, to: &local); let before = local
        XCTAssertTrue(local.acknowledge(header, saved: receipt(header, reply))); XCTAssertEqual(local.pending, [change]); sameRows(local, before)
    }
    func testQueuedProvisionalEditSurvivesWhenServerConfirmsItsSameGeneration() throws {
        let (_, header, batch, reply) = try fixture("recurring_"); var local = snapshot(batch); append(header, to: &local)
        let next = batch.items[0].teamCompletion!.proposed!, change = try patch(next, ["title": .string("Authored future occurrence")], scope: batch.items[0].teamCompletion!.scope)
        append(change, to: &local); let before = local
        XCTAssertTrue(local.acknowledge(header, saved: receipt(header, reply))); XCTAssertEqual(local.pending, [change]); sameRows(local, before)
    }
    func testAdoptedSuccessorCannotStealQueuedProvisionalEdits() throws {
        let (_, header, batch, reply) = try fixture("recurring_"); var local = snapshot(batch); append(header, to: &local)
        let next = batch.items.last!.teamCompletion!.proposed!, change = try patch(next, ["description": .string("Keep my provisional instructions")], scope: batch.items.last!.teamCompletion!.scope)
        append(change, to: &local)
        var adopted = reply, rows = reply["items"]!.list, member = rows[1].object, successor = member["successor"]!.object
        let other = UUID().uuidString.lowercased(); successor["task_generation"] = .string(other); member["successor_generation"] = .string(other); member["successor"] = .object(successor); member["created_successor"] = .bool(false); rows[1] = .object(member); adopted["items"] = .array(rows)
        let before = local; XCTAssertFalse(local.acknowledge(header, saved: receipt(header, adopted))); XCTAssertEqual(local, before)
    }
    func testUntrackedChangedRootCannotBeLostDuringDependentReplay() throws {
        let (_, header, batch, reply) = try fixture(); var local = snapshot(batch); append(header, to: &local)
        let change = try patch(local.tables["tasks"]![0], ["title": .string("Tracked title")], scope: batch.items[0].teamCompletion!.scope)
        append(change, to: &local); local.tables["tasks"]![1]["description"] = .string("Untracked authored content")
        let before = local; XCTAssertFalse(local.acknowledge(header, saved: receipt(header, reply))); XCTAssertEqual(local, before)
    }
    func testNewerConfirmedUnrelatedFieldIsPreservedAlongsideLocalEdit() throws {
        let (_, header, batch, reply) = try fixture(); var local = snapshot(batch); append(header, to: &local)
        let change = try patch(local.tables["tasks"]![0], ["title": .string("Tracked title")], scope: batch.items[0].teamCompletion!.scope)
        append(change, to: &local)
        var changed = reply, rows = reply["items"]!.list, member = rows[0].object, task = member["task"]!.object
        task["description"] = .string("Confirmed remote note"); member["task"] = .object(task); rows[0] = .object(member); changed["items"] = .array(rows)
        local.tables["tasks"]![0]["description"] = .string("Confirmed remote note")
        let before = local; XCTAssertTrue(local.acknowledge(header, saved: receipt(header, changed))); sameRows(local, before); XCTAssertEqual(local.pending, [change])
    }
    func testConflictingConfirmedFieldKeepsEntireOriginalCohort() throws {
        let (_, header, batch, reply) = try fixture(); var local = snapshot(batch); append(header, to: &local)
        let change = try patch(local.tables["tasks"]![0], ["title": .string("Tracked title")], scope: batch.items[0].teamCompletion!.scope)
        append(change, to: &local)
        var changed = reply, rows = reply["items"]!.list, member = rows[0].object, task = member["task"]!.object
        task["title"] = .string("Other person's newer title"); member["task"] = .object(task); rows[0] = .object(member); changed["items"] = .array(rows)
        let before = local; XCTAssertFalse(local.acknowledge(header, saved: receipt(header, changed))); XCTAssertEqual(local, before)
    }
    func testMixedPlanningCohortReconstructsEveryMemberIncludingOutsideTheOriginalBatch() throws {
        let (_, header, batch, reply) = try fixture(); var local = snapshot(batch)
        var outside = batch.items[0].teamCompletion!.source; outside["id"] = .string(UUID().uuidString.lowercased()); outside["task_generation"] = .string(UUID().uuidString.lowercased()); outside["title"] = .string("Other selected work")
        local.tables["tasks"]!.append(outside); append(header, to: &local)
        let chosen = [local.tables["tasks"]![0], outside]
        let members = chosen.map { row in Mutation(table: "tasks", recordID: row.id, method: "PATCH", fields: ["priority": .number(1)], baseline: row.fields, teamTaskScope: batch.items[0].teamCompletion!.scope) }.sorted { $0.recordID < $1.recordID }
        let planning = TeamTaskBatch(account: batch.account, origin: batch.origin, team: batch.team, operation: .edit, restores: nil, items: members), action = TeamTaskBatch.header(planning)
        append(action, to: &local); let before = local
        XCTAssertTrue(local.acknowledge(header, saved: receipt(header, reply))); XCTAssertEqual(local.pending, [action]); sameRows(local, before)
    }
    func testTouchingPersonalWriterCannotAcquireSharedScopeFromAcknowledgement() throws {
        let (_, header, batch, reply) = try fixture(); var local = snapshot(batch); append(header, to: &local)
        let change = Mutation(table: "tasks", recordID: batch.items[0].recordID, method: "PATCH", fields: ["title": .string("Unscoped draft")])
        append(change, to: &local); let before = local
        XCTAssertFalse(local.acknowledge(header, saved: receipt(header, reply))); XCTAssertEqual(local, before)
    }
    func testChangedProjectOrDuplicateCohortRowKeepsAllPendingWork() throws {
        let (_, header, batch, reply) = try fixture(); var local = snapshot(batch); append(header, to: &local)
        let change = try patch(local.tables["tasks"]![0], ["title": .string("Tracked title")], scope: batch.items[0].teamCompletion!.scope); append(change, to: &local)
        var missing = local; missing.tables["projects"] = []; let noProject = missing
        XCTAssertFalse(missing.acknowledge(header, saved: receipt(header, reply))); XCTAssertEqual(missing, noProject)
        local.tables["tasks"]!.append(local.tables["tasks"]![0]); let before = local
        XCTAssertFalse(local.acknowledge(header, saved: receipt(header, reply))); XCTAssertEqual(local, before)
    }
}

extension TeamCompletionBatchTests {
    func testQueuedScopedDeletionKeepsItsIntentAfterCompletionConfirmation() throws {
        let (_, header, batch, reply) = try fixture(); var local = snapshot(batch); append(header, to: &local)
        let row = local.tables["tasks"]![0], scope = batch.items[0].teamCompletion!.scope
        let deletion = try scope.capturing(Mutation(table: "tasks", recordID: row.id, method: "DELETE", fields: [:], baseline: row.fields, teamTaskScope: scope), existing: row)
        append(deletion, to: &local); let before = local
        XCTAssertTrue(local.acknowledge(header, saved: receipt(header, reply))); XCTAssertEqual(local.pending, [deletion]); sameRows(local, before)
    }
    func testAuthoredLatestRedoSuccessorSurvivesWholeCohortReplay() throws {
        let (header, _, reply, undo, redo, current) = try recurringChain(); var local = current
        let next = redo.teamTaskBatch!.items.last!.teamCompletion!.proposed!, scope = redo.teamTaskBatch!.items.last!.teamCompletion!.scope
        let change = try patch(next, ["description": .string("Authored after Redo")], scope: scope); append(change, to: &local); let before = local
        XCTAssertTrue(local.acknowledge(header, saved: receipt(header, reply))); XCTAssertEqual(local.pending, [undo, redo, change]); sameRows(local, before)
    }
    func testAdoptionKeepsEntireUndoRedoCohortWhenLatestSuccessorHasAuthoredWork() throws {
        let (header, _, reply, _, redo, current) = try recurringChain(); var local = current
        let next = redo.teamTaskBatch!.items.last!.teamCompletion!.proposed!, scope = redo.teamTaskBatch!.items.last!.teamCompletion!.scope
        let change = try patch(next, ["description": .string("Authored after Redo")], scope: scope); append(change, to: &local)
        var adopted = reply, values = reply["items"]!.list, member = values[1].object, successor = member["successor"]!.object
        let generation = UUID().uuidString.lowercased(); successor["task_generation"] = .string(generation); member["successor_generation"] = .string(generation); member["successor"] = .object(successor); member["created_successor"] = .bool(false); values[1] = .object(member); adopted["items"] = .array(values)
        let before = local; XCTAssertFalse(local.acknowledge(header, saved: receipt(header, adopted))); XCTAssertEqual(local, before)
    }
    func testEarlierOutsideEditJoinsLaterMixedCohortInOriginalQueueOrder() throws {
        let (_, header, batch, reply) = try fixture(); var local = snapshot(batch)
        var outside = batch.items[0].teamCompletion!.source; outside["id"] = .string(UUID().uuidString.lowercased()); outside["task_generation"] = .string(UUID().uuidString.lowercased()); outside["title"] = .string("Outside original selection")
        local.tables["tasks"]!.append(outside); append(header, to: &local)
        let earlier = try patch(outside, ["title": .string("Earlier outside title edit")], scope: batch.items[0].teamCompletion!.scope); append(earlier, to: &local)
        let chosen = [local.tables["tasks"]!.first { $0.id == batch.items[0].recordID }!, local.tables["tasks"]!.first { $0.id == outside.id }!]
        let members = chosen.map { Mutation(table: "tasks", recordID: $0.id, method: "PATCH", fields: ["priority": .number(1)], baseline: $0.fields, teamTaskScope: batch.items[0].teamCompletion!.scope) }.sorted { $0.recordID < $1.recordID }
        let planning = TeamTaskBatch.header(TeamTaskBatch(account: batch.account, origin: batch.origin, team: batch.team, operation: .edit, restores: nil, items: members)); append(planning, to: &local)
        let before = local; XCTAssertTrue(local.acknowledge(header, saved: receipt(header, reply))); XCTAssertEqual(local.pending, [earlier, planning]); sameRows(local, before)
    }
    func testUndoCohortRetainsAlreadyConfirmedNotesFromBeforeUndo() throws {
        let (_, original, batch, _) = try fixture(), (_, undo, _, undoReply) = try fixture("undo_")
        var local = snapshot(batch); local.apply(original)
        for i in local.tables["tasks"]!.indices { local.tables["tasks"]![i]["description"] = .string("Already confirmed note") }
        let history = EditHistory(changes: [undo], snapshot: local); append(undo, to: &local)
        let redo = TeamCompletion.historyAction(history.undo[0], snapshot: local); append(redo, to: &local)
        var response = undoReply, values = undoReply["items"]!.list
        for i in values.indices { var item = values[i].object, task = item["task"]!.object; task["description"] = .string("Already confirmed note"); item["task"] = .object(task); values[i] = .object(item) }
        response["items"] = .array(values)
        let before = local; XCTAssertTrue(local.acknowledge(undo, saved: receipt(undo, response))); XCTAssertEqual(local.pending, [redo]); sameRows(local, before)
    }
}

extension TeamCompletionBatchTests {
    func testObservedRoleLossRefusesLateReceiptForEntireDependentCohort() throws {
        let (_, header, batch, reply) = try fixture(); var local = snapshot(batch); append(header, to: &local)
        let undo = try batch.inverse(of: header, snapshot: local); append(undo, to: &local)
        let projectIDs = Set(batch.items.map { $0.teamCompletion!.scope.project }).sorted()
        let raw: [String: JSON] = ["workspace_boundary_protocol": .number(1), "account": .string(batch.account), "native_team_reads_enabled": .bool(true), "setup_paused": .bool(false), "token": .string(String(repeating: "b", count: 64)),
            "teams": .array([.object(["id": .string(batch.team), "state": .string("active"), "revision": .number(1), "access_revision": .number(2)])]),
            "projects": .array(projectIDs.map { .object(["id": .string($0), "team_id": .string(batch.team), "role": .string("viewer"), "archived": .bool(false), "can_send_tasks": .bool(false)]) })]
        local.teamWorkspace = try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(raw, account: batch.account, origin: batch.origin), previous: nil, pending: local.pending)
        let before = local; XCTAssertFalse(local.acknowledge(header, saved: receipt(header, reply))); XCTAssertEqual(local, before)
    }
}

extension TeamCompletionBatchTests {
    func testUneditedRedoProjectionCanAdoptTheConfirmedSuccessorWithoutChangingHistory() throws {
        let (header, _, reply, undo, redo, current) = try recurringChain(); var local = current
        var adopted = reply, values = reply["items"]!.list, member = values[0].object, successor = member["successor"]!.object
        let generation = UUID().uuidString.lowercased(); successor["task_generation"] = .string(generation); member["successor_generation"] = .string(generation); member["successor"] = .object(successor); member["created_successor"] = .bool(false); values[0] = .object(member); adopted["items"] = .array(values)
        XCTAssertTrue(local.acknowledge(header, saved: receipt(header, adopted))); XCTAssertEqual(local.pending, [undo, redo])
        let id = redo.teamTaskBatch!.items[0].teamCompletion!.proposed!.id
        XCTAssertEqual(local.tables["tasks"]!.first { $0.id == id }?["task_generation"], .string(generation))
        XCTAssertEqual(redo.teamTaskBatch!.items[0].teamCompletion!.nextGeneration, current.pending.last!.teamTaskBatch!.items[0].teamCompletion!.nextGeneration)
    }
    func testObservedAccessLossOnNewMixedCohortMemberStopsTheWholeConfirmation() throws {
        let (_, header, batch, reply) = try fixture(); var local = snapshot(batch)
        let otherProject = UUID().uuidString.lowercased(), scope = TeamTaskEditScope(account: batch.account, origin: batch.origin, team: batch.team, project: otherProject)
        var outside = batch.items[0].teamCompletion!.source; outside["id"] = .string(UUID().uuidString.lowercased()); outside["project_id"] = .string(otherProject); outside["task_generation"] = .string(UUID().uuidString.lowercased())
        local.tables["tasks"]!.append(outside); local.tables["projects"]!.append(Record(["id": .string(otherProject)])); append(header, to: &local)
        let selected = [local.tables["tasks"]!.first { $0.id == batch.items[0].recordID }!, outside]
        let members = selected.map { row in Mutation(table: "tasks", recordID: row.id, method: "PATCH", fields: ["priority": .number(1)], baseline: row.fields, teamTaskScope: row.id == outside.id ? scope : batch.items[0].teamCompletion!.scope) }.sorted { $0.recordID < $1.recordID }
        let planning = TeamTaskBatch.header(TeamTaskBatch(account: batch.account, origin: batch.origin, team: batch.team, operation: .edit, restores: nil, items: members)); append(planning, to: &local)
        let projects = Set(local.tables["projects"]!.map(\.id)).sorted()
        let raw: [String: JSON] = ["workspace_boundary_protocol": .number(1), "account": .string(batch.account), "native_team_reads_enabled": .bool(true), "setup_paused": .bool(false), "token": .string(String(repeating: "c", count: 64)),
            "teams": .array([.object(["id": .string(batch.team), "state": .string("active"), "revision": .number(1), "access_revision": .number(2)])]),
            "projects": .array(projects.map { .object(["id": .string($0), "team_id": .string(batch.team), "role": .string($0 == otherProject ? "viewer" : "editor"), "archived": .bool(false), "can_send_tasks": .bool($0 != otherProject)]) })]
        local.teamWorkspace = try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(raw, account: batch.account, origin: batch.origin), previous: nil, pending: local.pending)
        XCTAssertTrue(local.teamWorkspace!.canSend(header, in: local)); XCTAssertFalse(local.teamWorkspace!.canSend(planning, in: local))
        let before = local; XCTAssertFalse(local.acknowledge(header, saved: receipt(header, reply))); XCTAssertEqual(local, before)
    }
}

extension TeamCompletionBatchTests {
    private func queuedDeletion(_ batch: TeamTaskBatch, in snapshot: Snapshot) throws -> Mutation {
        let changes = batch.items.map { member in Mutation(table: "tasks", recordID: member.recordID, method: "DELETE", fields: [:], baseline: snapshot.tables["tasks"]!.first { $0.id == member.recordID }!.fields, teamTaskScope: member.teamCompletion!.scope) }
        return try XCTUnwrap(TeamTaskBatch.preparing(changes, snapshot: snapshot).first)
    }
    func testQueuedWholeSelectionDeletionReplaysWithoutDecomposingItsSavedCommand() throws {
        let (_, header, batch, reply) = try fixture(); var local = snapshot(batch); append(header, to: &local)
        let deletion = try queuedDeletion(batch, in: local); append(deletion, to: &local)
        XCTAssertEqual(local.tables["tasks"], [])
        XCTAssertTrue(local.acknowledge(header, saved: receipt(header, reply))); XCTAssertEqual(local.tables["tasks"], []); XCTAssertEqual(local.pending, [deletion])
    }
    func testChangedDeletionSourcePreventsAnyPartOfTheCohortFromBeingAcknowledged() throws {
        let (_, header, batch, reply) = try fixture(); var local = snapshot(batch); append(header, to: &local)
        let deletion = try queuedDeletion(batch, in: local); append(deletion, to: &local)
        var changed = reply, values = reply["items"]!.list, member = values[1].object, task = member["task"]!.object
        task["description"] = .string("New server instructions after completion"); member["task"] = .object(task); values[1] = .object(member); changed["items"] = .array(values)
        let before = local; XCTAssertFalse(local.acknowledge(header, saved: receipt(header, changed))); XCTAssertEqual(local, before)
    }
}

extension TeamCompletionBatchTests {
    func testQueuedDeletionAndRestorationKeepTheNewIncarnationAndBothHistoryRequests() throws {
        let (_, header, batch, reply) = try fixture(); var local = snapshot(batch); append(header, to: &local)
        let deletion = try queuedDeletion(batch, in: local)
        let history = EditHistory(changes: [deletion], snapshot: local); append(deletion, to: &local)
        let restore = TeamTaskBatch.historyAction(history.undo[0]); append(restore, to: &local)
        let before = local
        XCTAssertTrue(local.acknowledge(header, saved: receipt(header, reply))); XCTAssertEqual(local.pending, [deletion, restore]); sameRows(local, before)
        for root in batch.items { XCTAssertNotEqual(local.tables["tasks"]!.first { $0.id == root.recordID }?["task_generation"], root.teamCompletion!.source["task_generation"]) }
    }
}

extension TeamCompletionBatchTests {
    func testObservedProjectArchiveRefusesLateReceiptWithoutDiscardingHistory() throws {
        let (_, header, batch, reply) = try fixture()
        for key in ["is_archived", "ancestor_archived"] {
            var local = snapshot(batch); append(header, to: &local)
            let undo = try batch.inverse(of: header, snapshot: local); append(undo, to: &local)
            local.tables["projects"]![0][key] = .bool(true)
            let before = local; XCTAssertFalse(local.acknowledge(header, saved: receipt(header, reply))); XCTAssertEqual(local, before, key)
        }
    }
}

extension TeamCompletionBatchTests {
    private func completionOpening(_ phase: String = "") throws -> (TeamTaskCompletionSelection, [Record], WorkspaceBinding, UUID, TeamWorkspaceCache) {
        let (_, header, batch, _) = try fixture(phase)
        let projects = Set(batch.items.map { $0.teamCompletion!.scope.project }).sorted()
        let raw: [String: JSON] = ["workspace_boundary_protocol": .number(1), "account": .string(batch.account), "native_team_reads_enabled": .bool(true), "setup_paused": .bool(false), "token": .string(String(repeating: "a", count: 64)),
            "teams": .array([.object(["id": .string(batch.team), "state": .string("active"), "revision": .number(1), "access_revision": .number(1)])]),
            "projects": .array(projects.map { .object(["id": .string($0), "team_id": .string(batch.team), "role": .string("editor"), "archived": .bool(false), "can_send_tasks": .bool(true)]) })]
        let cache = try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(raw, account: batch.account, origin: batch.origin), previous: nil, pending: [header])
        let workspace = WorkspaceBinding(account: batch.account, generation: UUID()), session = UUID(), tasks = batch.items.map { $0.teamCompletion!.source }
        let drafts = try tasks.map { try TeamTaskEditorDraft(source: $0, workspace: workspace, session: session, cache: cache, enabled: true) }
        return (try TeamTaskCompletionSelection(drafts: drafts, tasks: tasks, at: TaskPlanning.instant("2026-10-25T12:00:00Z")!, zone: "UTC"), tasks, workspace, session, cache)
    }
    func testCompletionReviewFreezesOneEnvelopeAndEveryNonceAcrossRepeatedValidation() throws {
        let (opening, tasks, workspace, session, cache) = try completionOpening("recurring_")
        let first = try opening.mutation(tasks: tasks, workspace: workspace, session: session, cache: cache, enabled: true)
        XCTAssertEqual(first, try opening.mutation(tasks: tasks.reversed(), workspace: workspace, session: session, cache: cache, enabled: true))
        XCTAssertEqual(first.method, "TEAM_BATCH"); XCTAssertEqual(first.teamTaskBatch?.operation, .complete)
        XCTAssertEqual(opening.successors.count, 2); XCTAssertEqual(opening.completingCount, 2)
        var projection = snapshot(first.teamTaskBatch!); XCTAssertTrue(first.teamTaskBatch!.apply(to: &projection, header: first))
        XCTAssertEqual(projection.tables["tasks"]?.count, 4)
    }
    func testCompletionReviewRefusesChangedMissingAndDuplicateMembersWithoutRebuildingCommand() throws {
        let (opening, tasks, workspace, session, cache) = try completionOpening()
        let frozen = opening.command
        for key in ["title", "task_generation", "completion_version", "due_date"] {
            var changed = tasks; changed[1][key] = .string("changed")
            XCTAssertThrowsError(try opening.mutation(tasks: changed, workspace: workspace, session: session, cache: cache, enabled: true))
        }
        XCTAssertThrowsError(try opening.mutation(tasks: Array(tasks.dropLast()), workspace: workspace, session: session, cache: cache, enabled: true))
        XCTAssertThrowsError(try opening.mutation(tasks: tasks + [tasks[0]], workspace: workspace, session: session, cache: cache, enabled: true))
        XCTAssertEqual(opening.command, frozen)
    }
    func testCompletionReviewRefusesAccountWorkspaceSessionAndDisabledRollout() throws {
        let (opening, tasks, workspace, session, cache) = try completionOpening()
        XCTAssertThrowsError(try opening.mutation(tasks: tasks, workspace: WorkspaceBinding(account: workspace.account, generation: UUID()), session: session, cache: cache, enabled: true))
        XCTAssertThrowsError(try opening.mutation(tasks: tasks, workspace: WorkspaceBinding(account: UUID().uuidString.lowercased(), generation: workspace.generation), session: session, cache: cache, enabled: true))
        XCTAssertThrowsError(try opening.mutation(tasks: tasks, workspace: workspace, session: UUID(), cache: cache, enabled: true))
        XCTAssertThrowsError(try opening.mutation(tasks: tasks, workspace: workspace, session: session, cache: cache, enabled: false))
    }
    func testCompletionReviewRefusesNewOrEditedRepeatOccurrenceButAllowsUnrelatedTask() throws {
        let (opening, tasks, workspace, session, cache) = try completionOpening("recurring_")
        var new = opening.successors[0]
        XCTAssertThrowsError(try opening.mutation(tasks: tasks + [new], workspace: workspace, session: session, cache: cache, enabled: true))
        new["recurrence_parent_id"] = .null; new["id"] = .string(UUID().uuidString.lowercased())
        XCTAssertEqual(try opening.mutation(tasks: tasks + [new], workspace: workspace, session: session, cache: cache, enabled: true), opening.command)
    }
    func testCompletionReviewIncludesCompletedSelectionWithoutReopeningIt() throws {
        let (_, tasks, workspace, session, cache) = try completionOpening()
        var mixed = tasks; mixed[1]["completed"] = .bool(true)
        let drafts = try mixed.map { try TeamTaskEditorDraft(source: $0, workspace: workspace, session: session, cache: cache, enabled: true) }
        let opening = try TeamTaskCompletionSelection(drafts: drafts, tasks: mixed)
        XCTAssertEqual(opening.drafts.count, 2); XCTAssertEqual(opening.completingCount, 1)
        XCTAssertEqual(opening.command.teamTaskBatch?.items.map(\.recordID), [tasks[0].id])
        var completed = mixed; completed[0]["completed"] = .bool(true)
        let closed = try completed.map { try TeamTaskEditorDraft(source: $0, workspace: workspace, session: session, cache: cache, enabled: true) }
        XCTAssertThrowsError(try TeamTaskCompletionSelection(drafts: closed, tasks: completed))
    }
    func testCompletionReviewCannotCaptureDuplicateOrForeignSourceRows() throws {
        let (opening, tasks, _, _, _) = try completionOpening()
        XCTAssertThrowsError(try TeamTaskCompletionSelection(drafts: opening.drafts + [opening.drafts[0]], tasks: tasks))
        XCTAssertThrowsError(try TeamTaskCompletionSelection(drafts: opening.drafts, tasks: tasks + [tasks[0]]))
        var changed = tasks; changed[0]["title"] = .string("not the captured row")
        XCTAssertThrowsError(try TeamTaskCompletionSelection(drafts: opening.drafts, tasks: changed))
    }
}

extension TeamCompletionBatchTests {
    func testCompletionReviewRefusesChangedBoundaryTokenRoleAndArchivedProject() throws {
        let (opening, tasks, workspace, session, cache) = try completionOpening()
        for change in ["token", "role", "archived", "can_send_tasks"] {
            var raw = cache.boundary.raw
            if change == "token" { raw["token"] = .string(String(repeating: "b", count: 64)) }
            else {
                var projects = raw["projects"]!.list
                var first = projects[0].object
                first[change] = change == "role" ? .string("viewer") : .bool(change == "archived")
                first["can_send_tasks"] = .bool(false)
                projects[0] = .object(first); raw["projects"] = .array(projects)
            }
            let revoked = try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(raw, account: cache.boundary.account, origin: cache.boundary.origin), previous: cache, pending: [])
            XCTAssertThrowsError(try opening.mutation(tasks: tasks, workspace: workspace, session: session, cache: revoked, enabled: true), change)
        }
    }
}

extension TeamCompletionBatchTests {
    private func groupReviewFixture(_ phase: String = "unrecorded") throws -> ([String: JSON], Mutation, TeamTaskBatch.Review) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-completion-batch-recovery-v1", withExtension: "json", subdirectory: "Fixtures"))
        let f = try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        let body = f[phase == "cancelled" ? "unrecorded_body" : phase + "_body"]!.object, raw = f[phase == "cancelled" ? "cancelled_review" : phase + "_review"]!.object
        let action: TeamCompletion.Operation = raw["operation"] == .string("undo") ? .undo : .complete
        let items = try body["items"]!.list.map { value -> Mutation in
            let b = value.object, source = Record(b["record"]!.object), nonce = UUID(uuidString: b["request_id"]!.text)!
            let scope = TeamTaskEditScope(account: f["account"]!.text, origin: origin, team: body["team_id"]!.text, project: b["project_id"]!.text)
            let command = TeamCompletion(scope: scope, operation: action, source: source, completedAt: b["completed_at"]!.text, inputZone: b["input_zone"]!.text,
                seriesID: b["series_id"]!.text, seriesGeneration: b["series_generation"]!.text, seriesProject: b["series_project_id"]!.text,
                nextGeneration: b["next_generation"]!.text, proposed: nil, related: b[action == .undo ? "undoes" : "redo_of"].flatMap { UUID(uuidString: $0.text) })
            return TeamCompletion.header(command, id: nonce)
        }
        let batch = TeamTaskBatch(account: f["account"]!.text, origin: origin, team: body["team_id"]!.text, operation: action == .complete ? .complete : .undoComplete,
            restores: body["related_request"].flatMap { UUID(uuidString: $0.text) }, items: items)
        let header = TeamTaskBatch.header(batch, id: UUID(uuidString: body["request_id"]!.text)!)
        XCTAssertEqual(try batch.body(for: header), body)
        return (raw, header, try TeamTaskBatch.Review(raw, for: header))
    }
    private func groupReviewProjection(_ header: Mutation) -> Snapshot {
        let batch = header.teamTaskBatch!
        var before = snapshot(batch)
        if batch.operation == .undoComplete {
            before.tables["tasks"] = batch.items.map { item in
                let c = item.teamCompletion!
                return TaskCompletionRevision.applying(["completed": .bool(true), "completed_at": .string(c.completedAt)], to: c.source)
            }
        }
        XCTAssertTrue(batch.apply(to: &before, header: header)); before.pending = [header]; return before
    }
    func testGroupReviewParsesActualSQLUnrecordedCancelledCompleteUndoRedo() throws {
        for phase in ["unrecorded", "cancelled", "recorded", "undo", "redo"] {
            let (_, header, review) = try groupReviewFixture(phase)
            XCTAssertEqual(review.members.count, header.teamTaskBatch!.items.count)
            XCTAssertEqual(review.isCancelled, phase == "cancelled")
            XCTAssertEqual(review.isRecorded, ["recorded", "undo", "redo"].contains(phase))
            if let recorded = review.recorded { XCTAssertNoThrow(try header.teamTaskBatch!.confirm(recorded, for: header)) }
        }
    }
    func testGroupReviewRejectsForeignPartialReorderedAndMixedMemberObservations() throws {
        let (raw, header, _) = try groupReviewFixture()
        for key in ["account", "team_id", "request_id", "operation", "related_request", "group_review_protocol", "state"] {
            var wrong = raw; wrong[key] = .string("foreign"); XCTAssertThrowsError(try TeamTaskBatch.Review(wrong, for: header), key)
        }
        var wrong = raw; wrong["extra"] = .bool(true); XCTAssertThrowsError(try TeamTaskBatch.Review(wrong, for: header))
        for mode in ["missing", "reverse", "mixed", "foreign", "capability", "duplicate"] {
            var rows = raw["items"]!.list
            if mode == "missing" { rows.removeLast() }
            if mode == "reverse" { rows.reverse() }
            if mode == "duplicate" { rows[1] = rows[0] }
            if mode == "mixed" || mode == "foreign" || mode == "capability" {
                var item = rows[1].object
                item[mode == "mixed" ? "state" : mode == "foreign" ? "request_id" : "can_edit_current"] = .string("wrong")
                rows[1] = .object(item)
            }
            wrong = raw; wrong["items"] = .array(rows); XCTAssertThrowsError(try TeamTaskBatch.Review(wrong, for: header), mode)
        }
    }
    func testGroupReviewRejectsPartialReceiptAndMemberReceiptMismatch() throws {
        let (raw, header, _) = try groupReviewFixture("recorded")
        var wrong = raw; wrong["receipt"] = .null; XCTAssertThrowsError(try TeamTaskBatch.Review(wrong, for: header))
        var receipt = raw["receipt"]!.object; receipt["items"] = .array(Array(receipt["items"]!.list.dropLast())); wrong = raw; wrong["receipt"] = .object(receipt)
        XCTAssertThrowsError(try TeamTaskBatch.Review(wrong, for: header))
        var members = raw["items"]!.list, item = members[1].object, row = item["task"]!.object
        row["title"] = .string("unmatched observation"); item["task"] = .object(row); members[1] = .object(item); wrong = raw; wrong["items"] = .array(members)
        XCTAssertThrowsError(try TeamTaskBatch.Review(wrong, for: header))
    }
    func testGroupReviewRejectsContradictoryRepeatedIdentityAndOversizedObservation() throws {
        let (raw, header, _) = try groupReviewFixture()
        var members = raw["items"]!.list, item = members[0].object, series = item["series"]!.object
        series["title"] = .string("different same identity"); item["series"] = .object(series); members[0] = .object(item)
        var wrong = raw; wrong["items"] = .array(members); XCTAssertThrowsError(try TeamTaskBatch.Review(wrong, for: header))
        members = raw["items"]!.list; item = members[0].object; var task = item["task"]!.object
        task["description"] = .string(String(repeating: "x", count: 4_300_001)); item["task"] = .object(task)
        var sameSeries = item["series"]!.object; sameSeries["description"] = task["description"]; item["series"] = .object(sameSeries)
        members[0] = .object(item); wrong = raw; wrong["items"] = .array(members)
        XCTAssertThrowsError(try TeamTaskBatch.Review(wrong, for: header))
    }
    func testGroupReviewUnrecordedObservationNeverRemovesQueue() throws {
        let (_, header, review) = try groupReviewFixture(), local = groupReviewProjection(header)
        XCTAssertNil(review.acknowledging(local)); XCTAssertNil(review.cancelling(local)); XCTAssertTrue(review.canRequestCancellation(local))
        XCTAssertEqual(local.pending, [header])
    }
    func testGroupReviewRecordedAcknowledgementKeepsUnrelatedWorkAndRejectsStaleHead() throws {
        let (_, header, review) = try groupReviewFixture("recorded")
        var local = groupReviewProjection(header)
        let unrelated = Mutation(table: "view_preferences", recordID: "unrelated", method: "PATCH", fields: ["choice": .string("saved")])
        local.pending.append(unrelated); local.tables["labels"] = [Record(["id": .string("untouched")])]
        let next = try XCTUnwrap(review.acknowledging(local)); XCTAssertEqual(next.pending, [unrelated]); XCTAssertEqual(next.tables["labels"], local.tables["labels"])
        local.pending.reverse(); XCTAssertNil(review.acknowledging(local)); XCTAssertNil(review.cancelling(local))
    }
    func testGroupReviewCancellationUsesWholeTerminalProofAndKeepsIndependentTailByteForByte() throws {
        let (_, header, review) = try groupReviewFixture("cancelled")
        var local = groupReviewProjection(header)
        let independent = Mutation(table: "tasks", recordID: UUID().uuidString.lowercased(), method: "PATCH", fields: ["title": .string("independent saved draft")])
        local.pending.append(independent); let original = local
        let next = try XCTUnwrap(review.cancelling(local)); XCTAssertEqual(next.pending, [independent])
        for member in review.members { XCTAssertEqual(next.tables["tasks"]?.first { $0.id == member.task?.id }, member.task) }
        XCTAssertEqual(local, original); XCTAssertNil(review.acknowledging(local))
    }
    func testGroupReviewCancellationPreservesDependentGroupsNotesAndConversationDrafts() throws {
        let (_, header, review) = try groupReviewFixture("cancelled"), id = header.teamTaskBatch!.items[0].recordID
        for later in [Mutation(table: "tasks", recordID: id, method: "PATCH", fields: ["title": .string("authored later")]), Mutation(table: "view_preferences", recordID: "pinned", method: "PATCH", fields: ["note": .string(id)])] {
            var local = groupReviewProjection(header); local.pending.append(later); let before = local
            XCTAssertNil(review.cancelling(local)); XCTAssertFalse(review.canRequestCancellation(local)); XCTAssertEqual(local, before)
        }
        var local = groupReviewProjection(header); local.tables[ConversationOutbox.table] = [Record(["id": .string("draft"), "task_id": .string(id)])]
        XCTAssertNil(review.cancelling(local))
        local = groupReviewProjection(header); local.tables["tasks"]![0]["title"] = .string("unexplained local edit"); XCTAssertNil(review.cancelling(local))
    }
    func testGroupCancellationDoesNotRefreshSeparateSeriesParent() throws {
        let (raw, header, _) = try groupReviewFixture("cancelled")
        var batch = header.teamTaskBatch!, items = raw["items"]!.list
        let old = batch.items[0].teamCompletion!, parentID = UUID().uuidString.lowercased()
        var parent = old.source; parent["id"] = .string(parentID)
        let command = TeamCompletion(scope: old.scope, operation: old.operation, source: old.source, completedAt: old.completedAt, inputZone: old.inputZone,
            seriesID: parentID, seriesGeneration: parent.string("task_generation"), seriesProject: old.seriesProject, nextGeneration: old.nextGeneration, proposed: nil, related: old.related)
        batch.items[0] = TeamCompletion.header(command, id: batch.items[0].id)
        let changed = TeamTaskBatch.header(batch, id: header.id)
        var member = items[0].object; member["series_id"] = .string(parentID); member["series"] = .object(parent.fields); items[0] = .object(member)
        var response = raw; response["items"] = .array(items)
        let review = try TeamTaskBatch.Review(response, for: changed)
        var local = groupReviewProjection(changed)
        parent["description"] = .string("local series notes must stay exactly saved")
        local.tables["tasks", default: []].append(parent)
        let next = try XCTUnwrap(review.cancelling(local))
        XCTAssertEqual(next.tables["tasks"]?.first { $0.id == parentID }, parent)
        XCTAssertTrue(next.pending.isEmpty)
    }
    @MainActor func testGroupReviewBackendUsesPrivateExactBoundedRequestAndTerminalCancellation() async throws {
        let (raw, header, _) = try groupReviewFixture(), api = try backend(header.teamTaskBatch!.account)
        var paths = [String](); CompletionBatchHTTP.handler = { request, peer in
            paths.append(request.url!.path); XCTAssertEqual(request.timeoutInterval, 25); XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            let params = try! JSONDecoder().decode([String: JSON].self, from: request.httpBody!)
            XCTAssertEqual(params["_body"], .object(try! header.teamTaskBatch!.body(for: header))); XCTAssertEqual(params["_action"], .string("complete"))
            peer.finish(try! JSONEncoder().encode(raw))
        }; defer { CompletionBatchHTTP.handler = nil }
        _ = try await api.reviewTeamCompletionBatch(header, expectedAccount: header.teamTaskBatch!.account)
        do { _ = try await api.reviewTeamCompletionBatch(header, expectedAccount: header.teamTaskBatch!.account, cancel: true); XCTFail("Unrecorded is not cancellation proof") } catch {}
        XCTAssertEqual(paths, ["/rest/v1/rpc/taskfold_review_team_completion_batch", "/rest/v1/rpc/taskfold_cancel_team_completion_batch"])
    }
    @MainActor func testGroupReviewBackendSanitizesErrorsAndRejectsLateAccountResponse() async throws {
        let (raw, header, _) = try groupReviewFixture(), api = try backend(header.teamTaskBatch!.account)
        CompletionBatchHTTP.handler = { _, peer in peer.finish(Data("{\"code\":\"PT409\",\"message\":\"private server contents\"}".utf8), status: 409) }; defer { CompletionBatchHTTP.handler = nil }
        do { _ = try await api.reviewTeamCompletionBatch(header, expectedAccount: header.teamTaskBatch!.account); XCTFail() } catch { XCTAssertFalse(error.localizedDescription.contains("private server contents")) }
        let gate = CompletionBatchGate(), started = expectation(description: "Group review held")
        CompletionBatchHTTP.handler = { _, peer in gate.hold(peer); started.fulfill() }
        let pending = Task { try await api.reviewTeamCompletionBatch(header, expectedAccount: header.teamTaskBatch!.account) }; await fulfillment(of: [started], timeout: 3)
        var other = api.session!; other.user.id = UUID().uuidString.lowercased(); try await api.accept(other); gate.release(try JSONEncoder().encode(raw))
        do { _ = try await pending.value; XCTFail("Late review reached another account") } catch { XCTAssertTrue(error is CancellationError) }
    }
}

extension TeamCompletionBatchTests {
    @MainActor func testGroupReviewBackendRejectsAnnouncedOversizeAndForeignOriginBeforeDispatch() async throws {
        let (_, header, _) = try groupReviewFixture(), api = try backend(header.teamTaskBatch!.account)
        var calls = 0
        CompletionBatchHTTP.handler = { request, peer in
            calls += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json", "Content-Length": "8500001"])!
            peer.client?.urlProtocol(peer, didReceive: response, cacheStoragePolicy: .notAllowed)
            peer.client?.urlProtocol(peer, didLoad: Data("{}".utf8)); peer.client?.urlProtocolDidFinishLoading(peer)
        }; defer { CompletionBatchHTTP.handler = nil }
        do { _ = try await api.reviewTeamCompletionBatch(header, expectedAccount: header.teamTaskBatch!.account); XCTFail("Oversized review accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("too large"), error.localizedDescription) }
        var foreign = header; let batch = header.teamTaskBatch!
        foreign.teamTaskBatch = TeamTaskBatch(account: batch.account, origin: "https://another.example", team: batch.team, operation: batch.operation, restores: batch.restores, items: batch.items)
        do { _ = try await api.reviewTeamCompletionBatch(foreign, expectedAccount: header.teamTaskBatch!.account); XCTFail("Foreign request dispatched") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 1)
    }
}

extension TeamCompletionBatchTests {
    private func parkingReview(_ header: Mutation, cancelled: Bool = true) throws -> TeamTaskBatch.Review {
        let batch = header.teamTaskBatch!, body = try batch.body(for: header)
        let state = JSON.string(cancelled ? "cancelled" : "unrecorded")
        let members = try batch.items.map { item -> JSON in
            let command = item.teamCompletion!, b = try command.body(for: item)
            var raw: [String: JSON] = ["review_protocol": .number(1), "account": .string(batch.account), "operation": .string(command.operation.rawValue), "state": state, "project_role": .string("editor"), "can_edit_current": .bool(true), "can_edit_series": .bool(true), "receipt": .null, "task": .object(command.source.fields), "successor": .null]
            for key in ["team_id", "project_id", "task_id", "task_generation", "request_id", "series_id", "series_generation", "series_project_id", "planned_next_id"] { raw[key] = b[key] }
            var series = command.source; series["id"] = .string(command.seriesID); series["task_generation"] = .string(command.seriesGeneration); series["project_id"] = .string(command.seriesProject)
            raw["series"] = .object(series.fields)
            return .object(raw)
        }
        return try TeamTaskBatch.Review(["group_review_protocol": .number(1), "account": .string(batch.account), "team_id": .string(batch.team), "request_id": body["request_id"]!, "operation": .string(batch.completionOperation!.rawValue), "related_request": body["related_request"] ?? .null, "state": state, "items": .array(members), "receipt": .null], for: header)
    }
    private func authoredParking() throws -> (TeamTaskBatch.Review, Snapshot, Mutation) {
        let (_, header, batch, _) = try fixture(); var local = snapshot(batch); append(header, to: &local)
        let edit = try patch(local.tables["tasks"]![0], ["title": .string("Authored selection title"), "description": .string("Keep every authored note")], scope: batch.items[0].teamCompletion!.scope)
        append(edit, to: &local); return (try parkingReview(header), local, edit)
    }
    func testParkingPreservesIndependentTailAndArchivesExactAuthoredSelection() throws {
        let (review, current, edit) = try authoredParking(); var local = current
        let other = Mutation(table: "view_preferences", recordID: "independent", method: "PATCH", fields: ["name": .string("untouched")]); local.pending.append(other)
        let original = local, next = try XCTUnwrap(review.parkingCancellation(local)), draft = try TeamCompletionBatchDraft(review: review, snapshot: local)
        XCTAssertEqual(next.pending, [other]); XCTAssertEqual(draft.parkedChanges, [review.mutation, edit]); XCTAssertEqual(draft.snapshot, original)
        XCTAssertTrue(next.tables["tasks"]!.allSatisfy { !$0.completed }); XCTAssertTrue(draft.text.contains("Keep every authored note")); XCTAssertEqual(local, original)
    }
    func testParkingTransitiveMixedSelectionsRetainAllRowsAndOriginalQueueOrder() throws {
        let (_, header, batch, _) = try fixture(); var local = snapshot(batch)
        var outside = batch.items[0].teamCompletion!.source; outside["id"] = .string(UUID().uuidString.lowercased()); outside["task_generation"] = .string(UUID().uuidString.lowercased()); outside["title"] = .string("Outside selection")
        local.tables["tasks"]!.append(outside); append(header, to: &local)
        let scope = batch.items[0].teamCompletion!.scope
        let earlier = try patch(outside, ["title": .string("Earlier authored outside title")], scope: scope); append(earlier, to: &local)
        let chosen = [local.tables["tasks"]![0], local.tables["tasks"]!.first { $0.id == outside.id }!]
        let members = chosen.map { Mutation(table: "tasks", recordID: $0.id, method: "PATCH", fields: ["priority": .number(1)], baseline: $0.fields, teamTaskScope: scope) }.sorted { $0.recordID < $1.recordID }
        let mixed = TeamTaskBatch.header(TeamTaskBatch(account: batch.account, origin: batch.origin, team: batch.team, operation: .edit, restores: nil, items: members)); append(mixed, to: &local)
        let review = try parkingReview(header), next = try XCTUnwrap(review.parkingCancellation(local)), draft = try TeamCompletionBatchDraft(review: review, snapshot: local)
        XCTAssertEqual(draft.parkedChanges, [header, earlier, mixed]); XCTAssertEqual(draft.records.count, 3); XCTAssertTrue(draft.text.contains("Earlier authored outside title"))
        XCTAssertEqual(next.tables["tasks"]?.first { $0.id == outside.id }, outside); XCTAssertTrue(next.pending.isEmpty)
    }
    func testParkingRecurringUndoRedoAndLatestSuccessorEditsStayInOneDraft() throws {
        let (header, batch, _, undo, redo, current) = try recurringChain(); var local = current
        let next = redo.teamTaskBatch!.items.last!.teamCompletion!.proposed!, scope = batch.items.last!.teamCompletion!.scope
        let edit = try patch(next, ["description": .string("Latest future occurrence instructions")], scope: scope); append(edit, to: &local)
        let review = try parkingReview(header), draft = try TeamCompletionBatchDraft(review: review, snapshot: local), kept = try XCTUnwrap(review.parkingCancellation(local))
        XCTAssertEqual(draft.parkedChanges, [header, undo, redo, edit]); XCTAssertTrue(draft.text.contains("Latest future occurrence instructions"))
        XCTAssertEqual(Set(kept.tables["tasks"]!.map(\.id)), Set(batch.items.map(\.recordID))); XCTAssertTrue(kept.pending.isEmpty)
    }
    func testParkingDeletedTaskKeepsItsLastAuthoredNotes() throws {
        let (review, current, _) = try authoredParking(); var local = current
        let row = local.tables["tasks"]![0], scope = review.mutation.teamTaskBatch!.items[0].teamCompletion!.scope
        let delete = try scope.capturing(Mutation(table: "tasks", recordID: row.id, method: "DELETE", fields: [:], baseline: row.fields, teamTaskScope: scope), existing: row); append(delete, to: &local)
        let draft = try TeamCompletionBatchDraft(review: review, snapshot: local)
        XCTAssertTrue(draft.text.contains("Removed in the saved selection")); XCTAssertTrue(draft.text.contains("Keep every authored note")); XCTAssertNotNil(review.parkingCancellation(local)?.tables["tasks"]?.first { $0.id == row.id })
    }
    func testParkingCommentDraftsUsesExactTaskGenerationAndKeepsIndependentComments() throws {
        let (review, current, _) = try authoredParking(); var local = current
        let row = local.tables["tasks"]![0], account = review.mutation.teamTaskBatch!.account
        let comment = try SharedCommentChange(account: account, taskID: row.id, taskGeneration: row.string("task_generation"), projectID: row.string("project_id"), body: "Keep the conversation draft")
        try ConversationOutbox.enqueue(comment.record, into: &local)
        let outside = try SharedCommentChange(account: account, taskID: UUID().uuidString.lowercased(), taskGeneration: UUID().uuidString.lowercased(), projectID: row.string("project_id"), body: "Independent comment")
        try ConversationOutbox.enqueue(outside.record, into: &local)
        let draft = try TeamCompletionBatchDraft(review: review, snapshot: local), next = try XCTUnwrap(review.parkingCancellation(local))
        XCTAssertEqual(draft.parkedConversations.count, 1); XCTAssertTrue(draft.text.contains(comment.body)); XCTAssertFalse(draft.text.contains(outside.body))
        XCTAssertEqual(next.tables[ConversationOutbox.table]?.map(\.id), [outside.operationID])
        var wrong = comment.record; wrong["task_generation"] = .string(UUID().uuidString.lowercased()); local.tables[ConversationOutbox.table]![0]["intent"] = .object(wrong.fields)
        XCTAssertNil(review.parkingCancellation(local))
    }
    func testParkingRefusesUnexplainedRowsForeignScopeMissingProjectsAndIndirectPreferences() throws {
        let (review, local, _) = try authoredParking()
        for mode in ["untracked", "duplicate", "project", "preference", "foreign", "unscoped"] {
            var value = local
            if mode == "untracked" { value.tables["tasks"]![1]["description"] = .string("Must not lose") }
            if mode == "duplicate" { value.tables["tasks"]!.append(value.tables["tasks"]![0]) }
            if mode == "project" { value.tables["projects"] = [] }
            if mode == "preference" { value.pending.append(Mutation(table: "view_preferences", recordID: "pin", method: "PATCH", fields: ["task": .string(review.mutation.teamTaskBatch!.items[0].recordID)])) }
            if mode == "foreign" { value.pending[1].teamTaskScope = TeamTaskEditScope(account: UUID().uuidString.lowercased(), origin: origin, team: review.mutation.teamTaskBatch!.team, project: value.pending[1].teamTaskScope!.project) }
            if mode == "unscoped" { value.pending[1].teamTaskScope = nil }
            let before = value; XCTAssertNil(review.parkingCancellation(value), mode); XCTAssertThrowsError(try TeamCompletionBatchDraft(review: review, snapshot: value), mode); XCTAssertEqual(value, before)
        }
    }
    func testParkingNeverReinterpretsRecordedProofAsCancellation() throws {
        let (opening, local, _) = try authoredParking()
        let unrecorded = try parkingReview(opening.mutation, cancelled: false)
        XCTAssertNotNil(unrecorded.parkingPreview(local)); XCTAssertNil(unrecorded.parkingCancellation(local))
        XCTAssertNoThrow(try TeamCompletionBatchDraft(review: unrecorded, snapshot: local))
        let (_, header, recorded) = try groupReviewFixture("recorded")
        XCTAssertNil(recorded.parkingCancellation(groupReviewProjection(header)))
        XCTAssertThrowsError(try TeamCompletionBatchDraft(review: recorded, snapshot: groupReviewProjection(header)))
    }
    func testSelectionExportContainsOnlyConnectedTaskWorkWithoutWorkspaceCapabilities() throws {
        let (review, current, _) = try authoredParking(); var local = current
        local.tables["profiles"] = [Record(["id": .string("private"), "private": .string("unrelated private profile")])]
        let other = Mutation(table: "view_preferences", recordID: "private", method: "PATCH", fields: ["name": .string("unrelated private preference")]); local.pending.append(other)
        let draft = try TeamCompletionBatchDraft(review: review, snapshot: local), bytes = try draft.data(), raw = try JSONDecoder().decode([String: JSON].self, from: bytes)
        XCTAssertEqual(Set(raw.keys), ["format", "version", "created_at", "original", "changes", "tasks", "conversations"])
        XCTAssertEqual(raw["format"], .string("com.taskfold.saved-selection")); XCTAssertEqual(raw["changes"]?.list.count, 2)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("unrelated private"))
        XCTAssertEqual(try JSONDecoder().decode(TeamCompletionBatchDraft.self, from: JSONEncoder().encode(draft)), draft)
    }
    func testSelectionVaultEncryptsDeduplicatesChecksContextAndSurvivesOrdinaryBackupRotation() throws {
        let (review, local, _) = try authoredParking(), draft = try TeamCompletionBatchDraft(review: review, snapshot: local)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-selection-vault-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256), vault = TeamCompletionBatchDraftVault(directory: directory.appendingPathComponent("Selections"), account: draft.scope.account, origin: draft.scope.origin, key: { key })
        let saved = try vault.save(draft); XCTAssertEqual(saved, draft); XCTAssertEqual(try vault.save(TeamCompletionBatchDraft(review: review, snapshot: local)).id, draft.id); XCTAssertEqual(try vault.entries().count, 1)
        XCTAssertFalse(String(decoding: try Data(contentsOf: vault.file(draft.id)), as: UTF8.self).contains("Keep every authored note"))
        for foreign in [TeamCompletionBatchDraftVault(directory: vault.directory, account: UUID().uuidString.lowercased(), origin: vault.origin, key: { key }), TeamCompletionBatchDraftVault(directory: vault.directory, account: vault.account, origin: "https://foreign.example", key: { key }), TeamCompletionBatchDraftVault(directory: vault.directory, account: vault.account, origin: vault.origin, key: { SymmetricKey(size: .bits256) })] { XCTAssertThrowsError(try foreign.load(draft.id)) }
        let backups = BackupVault(directory: directory, account: vault.account, key: { key }, retention: 1)
        _ = try backups.save(local, kind: "Daily"); _ = try backups.save(local, kind: "Daily")
        XCTAssertEqual(try vault.load(draft.id), draft); try vault.remove(draft.id); XCTAssertTrue(try vault.entries().isEmpty)
    }
    func testSelectionVaultCorruptionWriteFailureAndSymlinkNeverAuthorizeDiscard() throws {
        let (review, local, _) = try authoredParking(), draft = try TeamCompletionBatchDraft(review: review, snapshot: local)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-selection-fault-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256), vault = TeamCompletionBatchDraftVault(directory: directory, account: draft.scope.account, origin: draft.scope.origin, key: { key })
        _ = try vault.save(draft); let bytes = try Data(contentsOf: vault.file(draft.id))
        try Data("corrupt".utf8).write(to: vault.file(draft.id)); XCTAssertThrowsError(try vault.load(draft.id)); XCTAssertThrowsError(try vault.save(draft))
        try FileManager.default.removeItem(at: vault.file(draft.id)); let outside = directory.appendingPathComponent("outside"); try bytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: vault.file(draft.id), withDestinationURL: outside); XCTAssertThrowsError(try vault.load(draft.id))
        let blocked = directory.appendingPathComponent("not-directory"); try Data().write(to: blocked)
        let badVault = TeamCompletionBatchDraftVault(directory: blocked.appendingPathComponent("child"), account: vault.account, origin: vault.origin, key: { key }); XCTAssertThrowsError(try badVault.save(draft)); XCTAssertEqual(local.pending.first, review.mutation)
    }
}

extension TeamCompletionBatchTests {
    func testSelectionVaultFullNeverEvictsAndAccountRemovalStopsDelayedSave() throws {
        let (review, current, _) = try authoredParking()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-selection-retention-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256), gate = AccountRemovalDisk(directory: directory, account: review.mutation.teamTaskBatch!.account)
        let vault = TeamCompletionBatchDraftVault(directory: directory.appendingPathComponent("Selections"), account: gate.account, origin: origin, key: { key }, removalGate: gate)
        var saved = [UUID]()
        for i in 0..<20 {
            var local = current; local.tables["view_preferences"] = [Record(["id": .string("choice"), "value": .number(Double(i))])]
            saved.append(try vault.save(TeamCompletionBatchDraft(review: review, snapshot: local)).id)
        }
        var extra = current; extra.tables["view_preferences"] = [Record(["id": .string("choice"), "value": .number(20)])]
        XCTAssertThrowsError(try vault.save(TeamCompletionBatchDraft(review: review, snapshot: extra)))
        XCTAssertEqual(Set(try vault.entries().map(\.id)), Set(saved))
        try gate.removeCache(); try FileManager.default.removeItem(at: vault.directory)
        XCTAssertThrowsError(try vault.save(TeamCompletionBatchDraft(review: review, snapshot: current)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.directory.path))
        let denied = TeamCompletionBatchDraftVault(directory: vault.directory, account: vault.account, origin: vault.origin, key: { XCTFail("Removed-account reader must not request or recreate its key"); return key }, removalGate: gate)
        XCTAssertThrowsError(try denied.load(saved[0])); XCTAssertThrowsError(try denied.remove(saved[0])); XCTAssertThrowsError(try denied.entries())
    }
    func testSelectionDraftRejectsOversizedSnapshotAndDuplicatePendingIdentity() throws {
        let (review, current, _) = try authoredParking(); var duplicate = current
        duplicate.pending.append(duplicate.pending[1]); XCTAssertNil(review.parkingCancellation(duplicate))
        XCTAssertThrowsError(try TeamCompletionBatchDraft(review: review, snapshot: duplicate))
        var large = current; large.tables["view_preferences"] = [Record(["id": .string("local"), "text": .string(String(repeating: "x", count: 16_000_001))])]
        XCTAssertThrowsError(try TeamCompletionBatchDraft(review: review, snapshot: large))
    }
}

extension TeamCompletionBatchTests {
    func testSelectionReaderWaitingForAccountFenceDoesNotHoldProcessLock() throws {
        let (review, local, _) = try authoredParking(), draft = try TeamCompletionBatchDraft(review: review, snapshot: local)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-selection-lock-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256), gate = AccountRemovalDisk(directory: directory, account: draft.scope.account)
        let gated = TeamCompletionBatchDraftVault(directory: directory.appendingPathComponent("Selections"), account: gate.account, origin: origin, key: { key }, removalGate: gate)
        _ = try gated.save(draft)
        var unguarded = gated; unguarded.removalGate = nil
        let free = unguarded, held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), started = DispatchSemaphore(value: 0)
        let holderDone = expectation(description: "account fence released"), readerDone = expectation(description: "reader drained"), writerDone = expectation(description: "in-fence save completed")
        DispatchQueue.global().async {
            do { try gate.writable { held.signal(); _ = release.wait(timeout: .now() + 5) } } catch { XCTFail(String(describing: error)) }
            holderDone.fulfill()
        }
        XCTAssertEqual(held.wait(timeout: .now() + 2), .success)
        defer { release.signal() }
        DispatchQueue.global().async {
            started.signal(); do { _ = try gated.entries() } catch { XCTFail(String(describing: error)) }; readerDone.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        // Let the reader reach the held disk fence. It must not hold the
        // process lock needed by work already inside that account fence.
        Thread.sleep(forTimeInterval: 0.05)
        DispatchQueue.global().async {
            do { _ = try free.save(draft) } catch { XCTFail(String(describing: error)) }; writerDone.fulfill()
        }
        let writer = XCTWaiter.wait(for: [writerDone], timeout: 1)
        release.signal()
        XCTAssertEqual(writer, .completed, "Reader and saver must share disk-then-process lock order")
        XCTAssertEqual(XCTWaiter.wait(for: [readerDone, holderDone], timeout: 3), .completed)
    }
}

extension TeamCompletionBatchTests {
    private func readRecoveryCache(_ header: Mutation, local: Snapshot, role: String = "viewer", archived: Bool = false, paused: Bool = false,
                                   missing: Set<String> = [], reads: Bool = true, active: Bool = true, account: String? = nil, origin alternateOrigin: String? = nil) throws -> TeamWorkspaceCache {
        let batch = header.teamTaskBatch!, owner = account ?? batch.account
        let projects = Set((local.tables["projects"] ?? []).map(\.id)).subtracting(missing).sorted()
        let raw: [String: JSON] = ["workspace_boundary_protocol": .number(1), "account": .string(owner), "native_team_reads_enabled": .bool(reads), "setup_paused": .bool(paused), "token": .string(String(repeating: "d", count: 64)),
            "teams": .array(reads ? [.object(["id": .string(batch.team), "state": .string(active ? "active" : "archived"), "revision": .number(1), "access_revision": .number(3)])] : []),
            "projects": .array(reads ? projects.map { .object(["id": .string($0), "team_id": .string(batch.team), "role": .string(role), "archived": .bool(archived), "can_send_tasks": .bool(role != "viewer" && !archived && !paused && active)]) } : [])]
        return try TeamWorkspaceCache(boundary: TeamWorkspaceBoundary(raw, account: owner, origin: alternateOrigin ?? batch.origin), previous: local.teamWorkspace, pending: local.pending, tasks: local.tables["tasks"] ?? [])
    }
    private func recordedReadReview(_ header: Mutation, reply: [String: JSON], series: [Record] = []) throws -> TeamTaskBatch.Review {
        let batch = header.teamTaskBatch!, body = try batch.body(for: header)
        var receipt = reply; receipt["replayed"] = .bool(true)
        let members = try zip(batch.items, reply["items"]!.list).map { item, raw -> JSON in
            let command = item.teamCompletion!, request = try command.body(for: item)
            var memberReceipt = raw.object; memberReceipt["replayed"] = .bool(true)
            var member: [String: JSON] = ["review_protocol": .number(1), "account": .string(batch.account), "operation": .string(command.operation.rawValue), "state": .string("recorded"), "project_role": .string("viewer"), "can_edit_current": .bool(false), "can_edit_series": .bool(false), "receipt": .object(memberReceipt), "task": memberReceipt["task"]!, "successor": memberReceipt["successor"]!]
            for key in ["team_id", "project_id", "task_id", "task_generation", "request_id", "series_id", "series_generation", "series_project_id", "planned_next_id"] { member[key] = request[key] }
            member["series"] = command.seriesID == command.source.id ? memberReceipt["task"] : series.first { $0.id == command.seriesID }.map { .object($0.fields) } ?? .null
            return .object(member)
        }
        receipt["items"] = .array(members.map { $0.object["receipt"]! })
        return try TeamTaskBatch.Review(["group_review_protocol": .number(1), "account": .string(batch.account), "team_id": .string(batch.team), "request_id": body["request_id"]!, "operation": .string(batch.completionOperation!.rawValue), "related_request": body["related_request"] ?? .null, "state": .string("recorded"), "items": .array(members), "receipt": .object(receipt)], for: header)
    }
    func testExplicitRecordedReadReviewAcknowledgesAfterViewerArchiveAndWritePauseWithoutAuthorizingWrites() throws {
        let (_, header, review) = try groupReviewFixture("recorded")
        for mode in ["viewer", "archive", "pause"] {
            var local = groupReviewProjection(header)
            let access = try readRecoveryCache(header, local: local, role: mode == "viewer" ? "viewer" : "editor", archived: mode == "archive", paused: mode == "pause")
            local.teamWorkspace = access
            if mode == "archive" { for i in local.tables["projects"]!.indices { local.tables["projects"]![i]["is_archived"] = .bool(true) } }
            let before = local, saved = receipt(header, review.recorded!)
            XCTAssertFalse(local.acknowledge(header, saved: saved), "Ordinary send acknowledgement still needs edit access")
            XCTAssertEqual(local, before)
            let next = try XCTUnwrap(review.acknowledging(local, readable: access), mode)
            XCTAssertTrue(next.pending.isEmpty); XCTAssertEqual(next.teamWorkspace?.boundary, access.boundary)
            XCTAssertFalse(next.teamWorkspace!.canSend(header, in: next), mode)
            XCTAssertEqual(local, before)
        }
    }
    func testRecordedReadReviewPreservesTypedLaterEditsAndKeepsThemBlockedByteForByte() throws {
        let (_, header, review) = try groupReviewFixture("recorded"), batch = header.teamTaskBatch!
        var local = groupReviewProjection(header)
        let row = local.tables["tasks"]![0], change = try patch(row, ["title": .string("My unsent review title"), "description": .string("Keep offline instructions")], scope: batch.items[0].teamCompletion!.scope)
        append(change, to: &local)
        let access = try readRecoveryCache(header, local: local), before = local
        let next = try XCTUnwrap(review.acknowledging(local, readable: access))
        XCTAssertEqual(next.pending, [change]); sameRows(next, before)
        XCTAssertEqual(next.teamWorkspace?.blocked(next), [change.id]); XCTAssertFalse(next.teamWorkspace!.canSend(change, in: next)); XCTAssertEqual(local, before)
    }
    func testRecordedReadReviewUsesCapturedMaskInsteadOfPersistingAnOlderWriterBoundary() throws {
        let (_, header, review) = try groupReviewFixture("recorded"); var local = groupReviewProjection(header)
        local.teamWorkspace = try readRecoveryCache(header, local: local, role: "editor")
        XCTAssertTrue(local.teamWorkspace!.canSend(header, in: local))
        let fresh = try readRecoveryCache(header, local: local, role: "viewer")
        let next = try XCTUnwrap(review.acknowledging(local, readable: fresh))
        XCTAssertEqual(next.teamWorkspace!.boundary, fresh.boundary); XCTAssertFalse(next.teamWorkspace!.canSend(header, in: next))
        XCTAssertTrue(local.teamWorkspace!.canSend(header, in: local))
    }
    func testRecordedReadReviewRequiresEveryConnectedMixedProjectToRemainReadable() throws {
        let (_, header, batch, reply) = try fixture(); let review = try recordedReadReview(header, reply: reply)
        var local = snapshot(batch), outside = batch.items[0].teamCompletion!.source
        let project = UUID().uuidString.lowercased(); outside["id"] = .string(UUID().uuidString.lowercased()); outside["project_id"] = .string(project); outside["task_generation"] = .string(UUID().uuidString.lowercased())
        local.tables["projects"]!.append(Record(["id": .string(project)])); local.tables["tasks"]!.append(outside); append(header, to: &local)
        let chosen = [local.tables["tasks"]![0], outside]
        let members = chosen.map { row in Mutation(table: "tasks", recordID: row.id, method: "PATCH", fields: ["priority": .number(1)], baseline: row.fields, teamTaskScope: TeamTaskEditScope(account: batch.account, origin: batch.origin, team: batch.team, project: row.string("project_id"))) }.sorted { $0.recordID < $1.recordID }
        let mixed = TeamTaskBatch.header(TeamTaskBatch(account: batch.account, origin: batch.origin, team: batch.team, operation: .edit, restores: nil, items: members)); append(mixed, to: &local)
        let before = local, access = try readRecoveryCache(header, local: local)
        let next = try XCTUnwrap(review.acknowledging(local, readable: access)); XCTAssertEqual(next.pending, [mixed]); sameRows(next, before)
        XCTAssertEqual(next.teamWorkspace?.blocked(next), [mixed.id])
        XCTAssertNil(review.acknowledging(local, readable: try readRecoveryCache(header, local: local, missing: [project]))); XCTAssertEqual(local, before)
    }
    func testRecordedReadReviewRejectsForeignDisabledInactiveMissingAndForgottenCustodyBoundaries() throws {
        let (_, header, review) = try groupReviewFixture("recorded"), local = groupReviewProjection(header)
        for access in [try readRecoveryCache(header, local: local, account: UUID().uuidString.lowercased()), try readRecoveryCache(header, local: local, origin: "https://foreign.example"), try readRecoveryCache(header, local: local, reads: false), try readRecoveryCache(header, local: local, active: false), try readRecoveryCache(header, local: local, missing: [header.teamTaskBatch!.items[0].teamCompletion!.scope.project])] {
            XCTAssertNil(review.acknowledging(local, readable: access))
        }
        var remembered = local
        let oldProject = UUID().uuidString.lowercased(), oldTask = UUID().uuidString.lowercased()
        remembered.tables["projects"]!.append(Record(["id": .string(oldProject)])); var row = remembered.tables["tasks"]![0]; row["id"] = .string(oldTask); row["project_id"] = .string(oldProject); remembered.tables["tasks"]!.append(row)
        remembered.teamWorkspace = try readRecoveryCache(header, local: remembered, role: "editor")
        remembered.tables["projects"]!.removeAll { $0.id == oldProject }; remembered.tables["tasks"]!.removeAll { $0.id == oldTask }
        let forgetful = try readRecoveryCache(header, local: local)
        XCTAssertNil(review.acknowledging(remembered, readable: forgetful))
        let next = try XCTUnwrap(review.acknowledging(remembered, readable: try readRecoveryCache(header, local: remembered)))
        XCTAssertTrue(next.teamWorkspace!.knownTasks.contains(oldTask)); XCTAssertNotNil(next.teamWorkspace!.knownTeams[oldProject])
    }
    func testReadAccessCannotRetireUnrecordedCancelledStaleOrDuplicateEnvelopes() throws {
        for phase in ["unrecorded", "cancelled"] {
            let (_, header, review) = try groupReviewFixture(phase), local = groupReviewProjection(header)
            XCTAssertNil(review.acknowledging(local, readable: try readRecoveryCache(header, local: local)))
        }
        let (_, header, review) = try groupReviewFixture("recorded"); var local = groupReviewProjection(header)
        let access = try readRecoveryCache(header, local: local)
        local.pending.insert(Mutation(table: "view_preferences", recordID: "other", method: "PATCH", fields: [:]), at: 0)
        XCTAssertNil(review.acknowledging(local, readable: access)); local = groupReviewProjection(header); local.pending.append(header)
        XCTAssertNil(review.acknowledging(local, readable: access))
    }
    func testRecordedReadReviewRefusesUntrackedEditsEvenWithoutAQueuedCohort() throws {
        let (_, header, review) = try groupReviewFixture("recorded"); var local = groupReviewProjection(header)
        local.tables["tasks"]![1]["description"] = .string("Untracked authored instructions")
        let before = local; XCTAssertNil(review.acknowledging(local, readable: try readRecoveryCache(header, local: local))); XCTAssertEqual(local, before)
    }
    func testRecordedReadReviewReconcilesRecurringUndoRedoWithoutRewritingOrSendingAnyHistory() throws {
        let (header, _, reply, undo, redo, local) = try recurringChain(), review = try recordedReadReview(header, reply: reply)
        let next = try XCTUnwrap(review.acknowledging(local, readable: try readRecoveryCache(header, local: local)))
        XCTAssertEqual(next.pending, [undo, redo]); sameRows(next, local); XCTAssertEqual(next.teamWorkspace?.blocked(next), [undo.id, redo.id])
        for phase in ["undo", "redo"] {
            let (_, exact, observation) = try groupReviewFixture(phase), projection = groupReviewProjection(exact)
            let kept = try XCTUnwrap(observation.acknowledging(projection, readable: try readRecoveryCache(exact, local: projection)))
            XCTAssertTrue(kept.pending.isEmpty)
        }
    }
    func testRecordedReadReviewPreservesValidCommentsAndRefusesOrphanedSuccessorDrafts() throws {
        let (_, header, batch, reply) = try fixture("recurring_"); var local = snapshot(batch); append(header, to: &local)
        let proposed = batch.items[0].teamCompletion!.proposed!
        let comment = try SharedCommentChange(account: batch.account, taskID: proposed.id, taskGeneration: proposed.string("task_generation"), projectID: proposed.string("project_id"), body: "Keep my future occurrence comment")
        try ConversationOutbox.enqueue(comment.record, into: &local)
        let access = try readRecoveryCache(header, local: local), review = try recordedReadReview(header, reply: reply)
        let next = try XCTUnwrap(review.acknowledging(local, readable: access)); XCTAssertEqual(next.tables[ConversationOutbox.table], local.tables[ConversationOutbox.table])
        var changed = reply, items = reply["items"]!.list, member = items[0].object, successor = member["successor"]!.object
        let newGeneration = UUID().uuidString.lowercased(); successor["task_generation"] = .string(newGeneration); member["successor"] = .object(successor); member["successor_generation"] = .string(newGeneration); member["created_successor"] = .bool(false); items[0] = .object(member); changed["items"] = .array(items)
        let adopted = try recordedReadReview(header, reply: changed), before = local
        XCTAssertNil(adopted.acknowledging(local, readable: access)); XCTAssertEqual(local, before)
        local.tables[ConversationOutbox.table] = []
        local.pending.append(Mutation(table: "view_preferences", recordID: "pinned", method: "PATCH", fields: ["task": .string(proposed.id)]))
        XCTAssertNil(adopted.acknowledging(local, readable: access))
    }
}

extension TeamCompletionBatchTests {
    func testRecordedReadReviewRequiresSeparateSeriesProjectWithoutChangingItsLocalParent() throws {
        let (_, oldHeader, original, oldReply) = try fixture("recurring_")
        let previous = original.items[0].teamCompletion!
        var parent = previous.source; parent["id"] = .string(UUID().uuidString.lowercased()); parent["task_generation"] = .string(UUID().uuidString.lowercased()); parent["project_id"] = .string(UUID().uuidString.lowercased())
        var source = previous.source; source["recurrence_parent_id"] = .string(parent.id)
        let member = try TeamCompletion.complete(source, tasks: [source, parent], scope: previous.scope, at: TaskPlanning.instant(previous.completedAt)!, zone: previous.inputZone, id: original.items[0].id)
        let command = try XCTUnwrap(member.teamCompletion), body = try command.body(for: member)
        var batch = original; batch.items[0] = member
        let header = TeamTaskBatch.header(batch, id: oldHeader.id)
        var reply = oldReply, receipts = oldReply["items"]!.list, result = receipts[0].object
        for key in ["team_id", "project_id", "task_id", "task_generation", "request_id", "series_id", "series_generation", "series_project_id", "planned_next_id"] { result[key] = body[key] }
        let completed = TaskCompletionRevision.applying(["completed": .bool(true), "completed_at": .string(command.completedAt)], to: source), successor = try XCTUnwrap(command.proposed)
        result["task"] = .object(completed.fields); result["source_revision"] = completed["completion_version"]
        result["successor"] = .object(successor.fields); result["successor_id"] = .string(successor.id); result["successor_generation"] = successor["task_generation"]
        receipts[0] = .object(result); reply["items"] = .array(receipts)
        let review = try recordedReadReview(header, reply: reply, series: [parent])
        var local = snapshot(batch); local.tables["tasks"]!.append(parent); append(header, to: &local)
        let before = local, access = try readRecoveryCache(header, local: local)
        let next = try XCTUnwrap(review.acknowledging(local, readable: access))
        XCTAssertEqual(next.tables["tasks"]?.first { $0.id == parent.id }, parent); XCTAssertTrue(next.pending.isEmpty)
        XCTAssertNil(review.acknowledging(local, readable: try readRecoveryCache(header, local: local, missing: [parent.string("project_id")])))
        XCTAssertEqual(local, before)
    }
}

extension TeamCompletionBatchTests {
    func testColdDiscoveryRequiresBlockedCompletionAndFreshReadableScope() throws {
        let (_, header, _) = try groupReviewFixture("recorded"), local = groupReviewProjection(header)
        for mode in ["viewer", "archive", "pause"] {
            let access = try readRecoveryCache(header, local: local, role: mode == "viewer" ? "viewer" : "editor", archived: mode == "archive", paused: mode == "pause")
            let request = try XCTUnwrap(TeamCompletionBatchDiscovery(snapshot: local, access: access), mode)
            XCTAssertEqual(request.mutation, header); XCTAssertEqual(request.snapshot, local); XCTAssertEqual(request.access, access)
        }
        XCTAssertNil(TeamCompletionBatchDiscovery(snapshot: local, access: try readRecoveryCache(header, local: local, role: "editor")))
        for access in [try readRecoveryCache(header, local: local, reads: false), try readRecoveryCache(header, local: local, active: false), try readRecoveryCache(header, local: local, account: UUID().uuidString.lowercased()), try readRecoveryCache(header, local: local, origin: "https://foreign.example"), try readRecoveryCache(header, local: local, missing: [header.teamTaskBatch!.items[0].teamCompletion!.scope.project])] {
            XCTAssertNil(TeamCompletionBatchDiscovery(snapshot: local, access: access))
        }
    }
    func testColdDiscoveryOnlySurfacesExactTerminalReviewWithoutRetiringAnything() throws {
        let (_, header, recorded) = try groupReviewFixture("recorded"), local = groupReviewProjection(header), access = try readRecoveryCache(header, local: local)
        let request = try XCTUnwrap(TeamCompletionBatchDiscovery(snapshot: local, access: access)), before = local
        XCTAssertEqual(request.terminal(recorded, current: local, readable: access), recorded); XCTAssertEqual(local, before); XCTAssertEqual(local.pending, [header])
        var response = recorded.response; response["state"] = .string("unrecorded"); response["receipt"] = .null
        response["items"] = .array(response["items"]!.list.map { item in var raw = item.object; raw["state"] = .string("unrecorded"); raw["receipt"] = .null; return .object(raw) })
        let unrecorded = try TeamTaskBatch.Review(response, for: header)
        XCTAssertNil(request.terminal(unrecorded, current: local, readable: access))
        response["state"] = .string("cancelled"); response["items"] = .array(response["items"]!.list.map { item in var raw = item.object; raw["state"] = .string("cancelled"); return .object(raw) })
        let cancelled = try TeamTaskBatch.Review(response, for: header)
        XCTAssertEqual(request.terminal(cancelled, current: local, readable: access), cancelled)
    }
    func testColdDiscoveryRejectsLateSnapshotAccessHeadAndBodyChanges() throws {
        let (_, header, review) = try groupReviewFixture("recorded"), local = groupReviewProjection(header), access = try readRecoveryCache(header, local: local)
        let request = try XCTUnwrap(TeamCompletionBatchDiscovery(snapshot: local, access: access))
        var changed = local; changed.tables["tasks"]![0]["description"] = .string("Authored while checking")
        XCTAssertNil(request.terminal(review, current: changed, readable: access))
        changed = local; changed.pending.append(Mutation(table: "view_preferences", recordID: "choice", method: "PATCH", fields: ["name": .string("Later work")]))
        XCTAssertNil(request.terminal(review, current: changed, readable: access))
        changed = local; changed.pending = []
        XCTAssertNil(request.terminal(review, current: changed, readable: access))
        XCTAssertNil(request.terminal(review, current: local, readable: try readRecoveryCache(header, local: local, role: "editor", paused: true)))
        let (_, undo, observation) = try groupReviewFixture("undo"); XCTAssertNotEqual(undo, header)
        XCTAssertNil(request.terminal(observation, current: local, readable: access))
    }
    func testColdDiscoveryDoesNotProbeUnrelatedOrMalformedQueueHeads() throws {
        let (_, header, _) = try groupReviewFixture("recorded"), local = groupReviewProjection(header), access = try readRecoveryCache(header, local: local)
        for mode in ["empty", "personal", "single", "duplicate", "nested"] {
            var changed = local
            if mode == "empty" { changed.pending = [] }
            if mode == "personal" { changed.pending.insert(Mutation(table: "tasks", recordID: UUID().uuidString.lowercased(), method: "POST", fields: [:]), at: 0) }
            if mode == "single" { changed.pending = [header.teamTaskBatch!.items[0]] }
            if mode == "duplicate" { changed.pending.append(header) }
            if mode == "nested" { changed.pending[0].teamTaskBatch!.items[0].teamTaskBatch = header.teamTaskBatch }
            XCTAssertNil(TeamCompletionBatchDiscovery(snapshot: changed, access: access), mode)
        }
    }
    func testColdDiscoveryRetainsBlockedUndoRedoAndIndependentTailCommands() throws {
        for phase in ["recorded", "undo", "redo"] {
            let (_, header, review) = try groupReviewFixture(phase); var local = groupReviewProjection(header)
            let other = Mutation(table: "view_preferences", recordID: "independent", method: "PATCH", fields: ["name": .string("Keep this saved choice")]); local.pending.append(other)
            let access = try readRecoveryCache(header, local: local), before = local, request = try XCTUnwrap(TeamCompletionBatchDiscovery(snapshot: local, access: access))
            XCTAssertEqual(request.terminal(review, current: local, readable: access), review); XCTAssertEqual(local, before); XCTAssertEqual(local.pending, [header, other])
        }
    }
}

extension TeamCompletionBatchTests {
    func testCancelledGroupColdDiscoveryUsesActualWholeTerminalProofWithoutRetiringAnything() throws {
        let (_, header, review) = try groupReviewFixture("cancelled"), local = groupReviewProjection(header)
        for mode in ["viewer", "archive", "pause"] {
            let access = try readRecoveryCache(header, local: local, role: mode == "viewer" ? "viewer" : "editor", archived: mode == "archive", paused: mode == "pause")
            let request = try XCTUnwrap(TeamCompletionBatchDiscovery(snapshot: local, access: access))
            XCTAssertEqual(request.terminal(review, current: local, readable: access), review)
            XCTAssertEqual(local.pending, [header]); XCTAssertNil(review.acknowledging(local, readable: access))
            var changed = local; changed.tables["tasks"]![0]["title"] = .string("New local work")
            XCTAssertNil(request.terminal(review, current: changed, readable: access))
        }
    }
    func testCancelledWholeGroupRetainsCurrentReadRestrictionsAndIndependentWork() throws {
        let (_, header, review) = try groupReviewFixture("cancelled"); var local = groupReviewProjection(header)
        let independent = Mutation(table: "view_preferences", recordID: UUID().uuidString.lowercased(), method: "PATCH", fields: ["layout": .string("board")])
        local.pending.append(independent); local.teamWorkspace = try readRecoveryCache(header, local: local, role: "editor")
        let before = local
        for mode in ["viewer", "archive", "pause"] {
            let access = try readRecoveryCache(header, local: local, role: mode == "viewer" ? "viewer" : "editor", archived: mode == "archive", paused: mode == "pause")
            let next = try XCTUnwrap(review.cancelling(local, readable: access))
            XCTAssertEqual(next.pending, [independent]); XCTAssertEqual(next.teamWorkspace?.boundary, access.boundary)
            XCTAssertFalse(try XCTUnwrap(next.teamWorkspace).canSend(header, in: next)); XCTAssertEqual(local, before)
            XCTAssertEqual(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(next)), next)
        }
    }
    func testCancelledGroupParkingWithReadAccessRetainsVerifiedEncryptedAuthoredWork() throws {
        let (review, original, edit) = try authoredParking(); var local = original
        local.teamWorkspace = try readRecoveryCache(review.mutation, local: local, role: "editor")
        let draft = try TeamCompletionBatchDraft(review: review, snapshot: local)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256), vault = TeamCompletionBatchDraftVault(directory: directory, account: draft.scope.account, origin: draft.scope.origin, key: { key })
        let verified = try vault.save(draft); XCTAssertEqual(verified.snapshot, local); XCTAssertTrue(verified.parkedChanges.contains(edit)); XCTAssertEqual(try vault.load(draft.id), verified)
        let before = local
        for mode in ["viewer", "archive", "pause"] {
            let access = try readRecoveryCache(review.mutation, local: local, role: mode == "viewer" ? "viewer" : "editor", archived: mode == "archive", paused: mode == "pause")
            XCTAssertNil(review.cancelling(local, readable: access))
            let next = try XCTUnwrap(review.parkingCancellation(local, readable: access))
            XCTAssertTrue(next.pending.isEmpty); XCTAssertEqual(next.teamWorkspace?.boundary, access.boundary)
            XCTAssertEqual(try vault.load(draft.id).snapshot, before); XCTAssertEqual(local, before)
        }
    }
    func testCancelledReadProjectionRefusesUnrecordedProofMissingScopeAndLostCustody() throws {
        let (_, header, review) = try groupReviewFixture("cancelled"), local = groupReviewProjection(header)
        for access in [try readRecoveryCache(header, local: local, reads: false), try readRecoveryCache(header, local: local, active: false), try readRecoveryCache(header, local: local, missing: [header.teamTaskBatch!.items[0].teamCompletion!.scope.project]), try readRecoveryCache(header, local: local, account: UUID().uuidString.lowercased())] {
            XCTAssertNil(review.cancelling(local, readable: access)); XCTAssertNil(review.parkingCancellation(local, readable: access))
        }
        let (_, unrecordedHeader, unrecorded) = try groupReviewFixture("unrecorded"), unrecordedLocal = groupReviewProjection(unrecordedHeader)
        XCTAssertNil(unrecorded.cancelling(unrecordedLocal, readable: try readRecoveryCache(unrecordedHeader, local: unrecordedLocal)))
        XCTAssertNil(unrecorded.parkingCancellation(unrecordedLocal, readable: try readRecoveryCache(unrecordedHeader, local: unrecordedLocal)))
        var remembered = local, encoded = try JSONDecoder().decode([String: JSON].self, from: JSONEncoder().encode(try readRecoveryCache(header, local: local, role: "editor")))
        encoded["knownTasks"] = .array(encoded["knownTasks"]!.list + [.string(UUID().uuidString.lowercased())])
        remembered.teamWorkspace = try JSONDecoder().decode(TeamWorkspaceCache.self, from: JSONEncoder().encode(encoded))
        XCTAssertNil(review.cancelling(remembered, readable: try readRecoveryCache(header, local: local)))
    }
}

extension TeamCompletionBatchTests {
    private func recoveryFixture(single: Bool = false, recurring: Bool = false, comment: Bool = false) throws -> (TeamCompletionRecoveryDraft, TeamWorkspaceCache, Mutation, TeamTaskBatch.Review) {
        let (_, group, batch, reply) = try fixture(recurring ? "recurring_" : "")
        let header = single ? batch.items[0] : group
        var local = snapshot(batch); append(header, to: &local)
        let command = batch.items[0].teamCompletion!, target = recurring ? command.proposed! : local.tables["tasks"]!.first { $0.id == command.source.id }!
        let edit = try patch(target, ["title": .string("Keep the authored review"), "description": .string("Retain every line\nSecond line 🌱")], scope: command.scope)
        append(edit, to: &local)
        if comment {
            let value = try SharedCommentChange(account: batch.account, taskID: target.id, taskGeneration: target.string("task_generation"), projectID: target.string("project_id"), body: "Authored conversation retained")
            try ConversationOutbox.enqueue(value.record, into: &local)
        }
        var raw = reply, items = reply["items"]!.list, member = items[0].object
        if recurring {
            var next = member["successor"]!.object; next["task_generation"] = .string(UUID().uuidString.lowercased())
            member["successor"] = .object(next); member["successor_generation"] = next["task_generation"]; member["created_successor"] = .bool(false)
        } else { member["task"] = .null }
        items[0] = .object(member); raw["items"] = .array(items)
        let observed = try recordedReadReview(group, reply: raw), access = try readRecoveryCache(group, local: local)
        local.teamWorkspace = access
        let draft = single ? try TeamCompletionRecoveryDraft(single: observed.members[0], snapshot: local) : try TeamCompletionRecoveryDraft(group: observed, snapshot: local)
        return (draft, access, edit, observed)
    }
    func testRecordedMissingSourceArchivesExactAuthoredCohortAndKeepsIndependentWork() throws {
        let (base, cache, edit, observed) = try recoveryFixture()
        var local = base.snapshot
        local.tables["profiles"] = [Record(["id": .string("private"), "notes": .string("Unrelated private material")])]
        let independent = Mutation(table: "view_preferences", recordID: "personal", method: "PATCH", fields: ["name": .string("Unrelated private material")]); local.pending.append(independent)
        let draft = try TeamCompletionRecoveryDraft(group: observed, snapshot: local), next = try XCTUnwrap(draft.preserving(readable: cache))
        XCTAssertEqual(draft.parkedChanges, [base.original, edit]); XCTAssertEqual(next.pending, [independent])
        XCTAssertFalse(next.tables["tasks"]!.contains { $0.id == edit.recordID }); XCTAssertEqual(next.tables["profiles"], local.tables["profiles"])
        XCTAssertEqual(draft.snapshot, local); XCTAssertEqual(next.teamWorkspace?.boundary, cache.boundary); XCTAssertFalse(next.teamWorkspace!.canSend(base.original, in: next))
        let raw = try JSONDecoder().decode([String: JSON].self, from: draft.data())
        XCTAssertEqual(Set(raw.keys), ["format", "version", "created_at", "original", "changes", "tasks", "conversations"])
        XCTAssertEqual(raw["format"], .string("com.taskfold.saved-edits")); XCTAssertEqual(raw["changes"]?.list.count, 2)
        XCTAssertTrue(draft.text.contains("Second line 🌱")); XCTAssertFalse(String(decoding: try draft.data(), as: UTF8.self).contains("Unrelated private material"))
    }
    func testSingleRecordedRecoveryRetainsActualEnvelopeAndNeverExportsAnalysisHeader() throws {
        let (draft, cache, edit, _) = try recoveryFixture(single: true, comment: true)
        XCTAssertEqual(draft.snapshot.pending, [draft.original, edit]); XCTAssertNil(draft.original.teamTaskBatch)
        let next = try XCTUnwrap(draft.preserving(readable: cache)); XCTAssertTrue(next.pending.isEmpty)
        XCTAssertEqual(next.tables[ConversationOutbox.table], []); XCTAssertEqual(draft.parkedConversations.count, 1)
        let raw = try JSONDecoder().decode([String: JSON].self, from: draft.data())
        let original = try JSONDecoder().decode(Mutation.self, from: JSONEncoder().encode(raw["original"]!))
        XCTAssertEqual(original, draft.original); XCTAssertEqual(raw["changes"]?.list.count, 2)
        let analysis = WorkspaceBackup.stableID("recorded-recovery-analysis", draft.original.id.uuidString)
        XCTAssertFalse(String(decoding: try draft.data(), as: UTF8.self).lowercased().contains(analysis))
        XCTAssertEqual(try JSONDecoder().decode(TeamCompletionRecoveryDraft.self, from: JSONEncoder().encode(draft)), draft)
    }
    func testRecordedCanonicalSuccessorKeepsOldIncarnationNotesAndCommentsInDraft() throws {
        for single in [false, true] {
            let (draft, cache, edit, observed) = try recoveryFixture(single: single, recurring: true, comment: true)
            let next = try XCTUnwrap(draft.preserving(readable: cache)), canonical = try XCTUnwrap(observed.members[0].successor)
            XCTAssertEqual(next.tables["tasks"]?.first { $0.id == canonical.id }, canonical)
            XCTAssertNotEqual(canonical["task_generation"], edit.baseline?["task_generation"])
            XCTAssertTrue(next.pending.isEmpty); XCTAssertEqual(next.tables[ConversationOutbox.table], [])
            XCTAssertTrue(draft.text.contains("Retain every line")); XCTAssertTrue(draft.text.contains("Authored conversation retained"))
            XCTAssertFalse(next.teamWorkspace!.canSend(draft.original, in: next))
        }
    }
    func testRecordedRecoveryArchivesTransitiveMixedSelectionWithoutLosingOutsideBaseline() throws {
        let (base, _, _, observed) = try recoveryFixture(); var local = base.snapshot
        let batch = base.original.teamTaskBatch!, scope = batch.items[0].teamCompletion!.scope
        var outside = batch.items[0].teamCompletion!.source; outside["id"] = .string(UUID().uuidString.lowercased()); outside["task_generation"] = .string(UUID().uuidString.lowercased()); outside["title"] = .string("Outside baseline")
        local.tables["tasks"]!.append(outside)
        let earlier = try patch(outside, ["title": .string("Outside authored title")], scope: scope); append(earlier, to: &local)
        let chosen = [local.tables["tasks"]!.first { $0.id == batch.items[0].recordID }!, local.tables["tasks"]!.first { $0.id == outside.id }!]
        let items = chosen.map { Mutation(table: "tasks", recordID: $0.id, method: "PATCH", fields: ["priority": .number(1)], baseline: $0.fields, teamTaskScope: scope) }.sorted { $0.recordID < $1.recordID }
        let mixed = TeamTaskBatch.header(TeamTaskBatch(account: batch.account, origin: batch.origin, team: batch.team, operation: .edit, restores: nil, items: items)); append(mixed, to: &local)
        let cache = try readRecoveryCache(base.original, local: local), draft = try TeamCompletionRecoveryDraft(group: observed, snapshot: local)
        let next = try XCTUnwrap(draft.preserving(readable: cache)); XCTAssertTrue(next.pending.isEmpty)
        XCTAssertEqual(next.tables["tasks"]?.first { $0.id == outside.id }, outside)
        XCTAssertEqual(draft.parkedChanges.map(\.id), local.pending.map(\.id)); XCTAssertTrue(draft.text.contains("Outside authored title"))
    }
    func testRecordedRecoveryRetainsDeletedRowNotesAndTypedConversation() throws {
        let (base, _, _, observed) = try recoveryFixture(comment: true); var local = base.snapshot
        let row = local.tables["tasks"]!.first { $0.id == base.parkedChanges[1].recordID }!, scope = base.original.teamTaskBatch!.items[0].teamCompletion!.scope
        let deletion = try scope.capturing(Mutation(table: "tasks", recordID: row.id, method: "DELETE", fields: [:], baseline: row.fields, teamTaskScope: scope), existing: row); append(deletion, to: &local)
        let draft = try TeamCompletionRecoveryDraft(group: observed, snapshot: local)
        XCTAssertNotNil(draft.preserving(readable: try readRecoveryCache(base.original, local: local)))
        XCTAssertTrue(draft.text.contains("Second line 🌱")); XCTAssertTrue(draft.text.contains("Removed in the saved edits")); XCTAssertEqual(draft.parkedConversations.count, 1)
    }
    func testRecordedRecoveryNeverGrantsAccessAndRejectsForeignOrForgottenReadCustody() throws {
        let (draft, _, _, _) = try recoveryFixture()
        for cache in [try readRecoveryCache(draft.original, local: draft.snapshot, reads: false), try readRecoveryCache(draft.original, local: draft.snapshot, active: false), try readRecoveryCache(draft.original, local: draft.snapshot, account: UUID().uuidString.lowercased()), try readRecoveryCache(draft.original, local: draft.snapshot, origin: "https://foreign.example"), try readRecoveryCache(draft.original, local: draft.snapshot, missing: [draft.original.teamTaskBatch!.items[0].teamCompletion!.scope.project])] {
            XCTAssertNil(draft.preserving(readable: cache))
        }
        for mode in ["viewer", "archived", "paused"] {
            let cache = try readRecoveryCache(draft.original, local: draft.snapshot, role: mode == "viewer" ? "viewer" : "editor", archived: mode == "archived", paused: mode == "paused")
            let next = try XCTUnwrap(draft.preserving(readable: cache)); XCTAssertEqual(next.teamWorkspace?.boundary, cache.boundary); XCTAssertFalse(next.teamWorkspace!.canSend(draft.original, in: next))
        }
    }
    func testRecordedRecoveryRefusesUntrackedForeignDuplicateAndIndirectIntent() throws {
        let (draft, _, _, observed) = try recoveryFixture(comment: true)
        for mode in ["untracked", "duplicate", "unscoped", "foreign", "preference", "comment", "mention", "replacement", "missing-project"] {
            var local = draft.snapshot
            if mode == "untracked" { local.tables["tasks"]![0]["opaque_authored_field"] = .string("Keep it") }
            if mode == "duplicate" { local.pending.append(local.pending[1]) }
            if mode == "unscoped" { local.pending[1].teamTaskScope = nil }
            if mode == "foreign" { local.pending[1].teamTaskScope = TeamTaskEditScope(account: UUID().uuidString.lowercased(), origin: draft.origin, team: draft.original.teamTaskBatch!.team, project: local.pending[1].teamTaskScope!.project) }
            if mode == "preference" { local.pending.append(Mutation(table: "view_preferences", recordID: "pin", method: "PATCH", fields: ["task": .string(local.pending[1].recordID)])) }
            if mode == "comment" { var fields = local.tables[ConversationOutbox.table]![0]["intent"].object; fields["task_generation"] = .string(UUID().uuidString.lowercased()); local.tables[ConversationOutbox.table]![0]["intent"] = .object(fields) }
            if mode == "mention" { local.tables[ConversationOutbox.table]![0]["intent"] = .object(["kind": .string("unsupported mention"), "task_id": .string(local.pending[1].recordID)]) }
            if mode == "replacement" { local.tables["tasks"]![0]["task_generation"] = .string(UUID().uuidString.lowercased()) }
            if mode == "missing-project" { local.tables["projects"] = [] }
            let before = local; XCTAssertThrowsError(try TeamCompletionRecoveryDraft(group: observed, snapshot: local), mode); XCTAssertEqual(local, before)
        }
    }
    func testRecordedRecoveryRequiresMissingIncarnationAuthoredWorkAndTerminalReceipt() throws {
        let (_, header, batch, raw) = try fixture(); var local = snapshot(batch); append(header, to: &local)
        let intact = try recordedReadReview(header, reply: raw)
        XCTAssertThrowsError(try TeamCompletionRecoveryDraft(group: intact, snapshot: local))
        let unrecorded = try parkingReview(header, cancelled: false)
        XCTAssertThrowsError(try TeamCompletionRecoveryDraft(group: unrecorded, snapshot: local))
        XCTAssertThrowsError(try TeamCompletionRecoveryDraft(group: try parkingReview(header), snapshot: local))
        var missing = raw, items = raw["items"]!.list, member = items[0].object; member["task"] = .null; items[0] = .object(member); missing["items"] = .array(items)
        XCTAssertThrowsError(try TeamCompletionRecoveryDraft(group: recordedReadReview(header, reply: missing), snapshot: local), "No later authored work needs a separate permanent draft")
    }
    func testRecordedRecoveryVaultEncryptsDeduplicatesAndKeepsLegacySelectionsIndependent() throws {
        let (draft, _, _, _) = try recoveryFixture(single: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recorded-draft-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256), vault = TeamCompletionRecoveryDraftVault(directory: directory.appendingPathComponent("Recorded recovery"), account: draft.account, origin: draft.origin, key: { key })
        XCTAssertEqual(try vault.save(draft), draft); XCTAssertEqual(try vault.save(TeamCompletionRecoveryDraft(single: TeamCompletion.Review(draft.review, for: draft.original), snapshot: draft.snapshot)).id, draft.id)
        XCTAssertEqual(try vault.entries(), [draft]); XCTAssertFalse(String(decoding: try Data(contentsOf: vault.file(draft.id)), as: UTF8.self).contains("Second line"))
        let legacy = TeamCompletionBatchDraftVault(directory: directory.appendingPathComponent("Selections"), account: draft.account, origin: draft.origin, key: { key })
        XCTAssertEqual(try legacy.entries(), [])
        for other in [TeamCompletionRecoveryDraftVault(directory: vault.directory, account: UUID().uuidString.lowercased(), origin: draft.origin, key: { key }), TeamCompletionRecoveryDraftVault(directory: vault.directory, account: draft.account, origin: "https://foreign.example", key: { key }), TeamCompletionRecoveryDraftVault(directory: vault.directory, account: draft.account, origin: draft.origin, key: { SymmetricKey(size: .bits256) })] { XCTAssertThrowsError(try other.load(draft.id)) }
        try vault.remove(draft.id); XCTAssertEqual(try vault.entries(), [])
    }
    func testRecordedRecoveryVaultRejectsCorruptionSymlinksAndBlockedWrites() throws {
        let (draft, _, _, _) = try recoveryFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recorded-fault-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256), vault = TeamCompletionRecoveryDraftVault(directory: directory, account: draft.account, origin: draft.origin, key: { key })
        _ = try vault.save(draft); let bytes = try Data(contentsOf: vault.file(draft.id))
        try Data("bad".utf8).write(to: vault.file(draft.id)); XCTAssertThrowsError(try vault.load(draft.id)); XCTAssertThrowsError(try vault.save(draft))
        try FileManager.default.removeItem(at: vault.file(draft.id)); let outside = directory.appendingPathComponent("outside"); try bytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: vault.file(draft.id), withDestinationURL: outside); XCTAssertThrowsError(try vault.load(draft.id))
        let blocked = directory.appendingPathComponent("blocked"); try Data().write(to: blocked)
        XCTAssertThrowsError(try TeamCompletionRecoveryDraftVault(directory: blocked, account: draft.account, origin: draft.origin, key: { key }).save(draft))
    }
}

extension TeamCompletionBatchTests {
    func testRecordedRecoveryVaultCapacityNeverEvictsAndRemovalFenceStopsDelayedWork() throws {
        let (base, _, _, observed) = try recoveryFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recorded-capacity-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256), gate = AccountRemovalDisk(directory: directory, account: base.account)
        let vault = TeamCompletionRecoveryDraftVault(directory: directory.appendingPathComponent("Recorded recovery"), account: base.account, origin: base.origin, key: { key }, removalGate: gate)
        var ids = Set<UUID>()
        for i in 0..<20 {
            var local = base.snapshot; local.tables["view_preferences"] = [Record(["id": .string("choice"), "value": .number(Double(i))])]
            ids.insert(try vault.save(TeamCompletionRecoveryDraft(group: observed, snapshot: local)).id)
        }
        XCTAssertThrowsError(try vault.save(base)); XCTAssertEqual(Set(try vault.entries().map(\.id)), ids)
        try gate.removeCache(); try FileManager.default.removeItem(at: vault.directory)
        let denied = TeamCompletionRecoveryDraftVault(directory: vault.directory, account: base.account, origin: base.origin, key: { XCTFail("Removed account must not recreate its key"); return key }, removalGate: gate)
        XCTAssertThrowsError(try denied.save(base)); XCTAssertThrowsError(try denied.entries()); XCTAssertThrowsError(try denied.load(ids.first!)); XCTAssertThrowsError(try denied.remove(ids.first!))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.directory.path))
    }
    func testRecordedRecoveryValidatesEncodedProofAndRejectsDirectoryAlias() throws {
        let (draft, _, _, _) = try recoveryFixture(single: true)
        var raw = try JSONDecoder().decode([String: JSON].self, from: JSONEncoder().encode(draft))
        var response = raw["review"]!.object; response["state"] = .string("unrecorded"); raw["review"] = .object(response)
        let changed = try JSONDecoder().decode(TeamCompletionRecoveryDraft.self, from: JSONEncoder().encode(raw)); XCTAssertThrowsError(try changed.validate())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recorded-alias-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let alias = directory.appendingPathComponent("alias"); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let vault = TeamCompletionRecoveryDraftVault(directory: alias, account: draft.account, origin: draft.origin, key: { SymmetricKey(size: .bits256) })
        XCTAssertThrowsError(try vault.entries()); XCTAssertThrowsError(try vault.save(draft))
    }
}

extension TeamCompletionBatchTests {
    private func attachRecoveryMention(_ snapshot: inout Snapshot, task: Record, account: String, read: Bool = true, draftOnly: Bool = false) throws -> (Record, SharedMentionChange) {
        let commentID = UUID().uuidString.lowercased(), stamp = "2026-10-25T12:00:00Z"
        let comment = Record(["id": .string(commentID), "task_id": .string(task.id), "task_generation": task["task_generation"], "project_id": task["project_id"], "author_id": .string(account), "body": .string("Read the connected workshop discussion"), "mention_ids": .array([.string(account)]), "revision": .number(2), "created_at": .string(stamp), "updated_at": .string(stamp), "deleted_at": .null])
        if draftOnly {
            let draft = try SharedCommentChange(account: account, taskID: task.id, taskGeneration: task.string("task_generation"), projectID: task.string("project_id"), commentID: commentID, body: "Unsent connected discussion")
            try ConversationOutbox.enqueue(draft.record, into: &snapshot)
        } else { snapshot.tables[SharedComment.table, default: []].append(comment) }
        let row = Record(["id": .string(UUID().uuidString.lowercased()), "comment_id": .string(commentID), "recipient_id": .string(account), "revision": .number(3), "created_at": .string(stamp), "read_at": .null])
        snapshot.tables[SharedMention.table, default: []].append(row)
        let change = try SharedMentionChange(mention: XCTUnwrap(SharedMention(row)), account: account, read: read)
        try ConversationOutbox.enqueue(change.record, into: &snapshot)
        return (comment, change)
    }
    func testRecordedRecoveryParksReadAndUnreadMarkersWithTheirIndirectTaskContext() throws {
        for single in [false, true] { for read in [false, true] {
            let (base, cache, edit, review) = try recoveryFixture(single: single)
            var local = base.snapshot; let task = try XCTUnwrap(local.tables["tasks"]?.first { $0.id == edit.recordID })
            let (comment, marker) = try attachRecoveryMention(&local, task: task, account: base.account, read: read)
            let draft = single ? try TeamCompletionRecoveryDraft(single: review.members[0], snapshot: local) : try TeamCompletionRecoveryDraft(group: review, snapshot: local)
            let next = try XCTUnwrap(draft.preserving(readable: cache))
            XCTAssertEqual(draft.parkedConversations, local.tables[ConversationOutbox.table]); XCTAssertTrue(next.tables[ConversationOutbox.table]!.isEmpty)
            XCTAssertEqual(draft.snapshot, local); XCTAssertEqual(ConversationOutbox.mention(draft.parkedConversations[0]), marker)
            XCTAssertTrue(draft.text.contains(read ? "Mention marked read:" : "Mention marked unread:")); XCTAssertTrue(draft.text.contains(comment.string("body")))
            let json = try JSONDecoder().decode([String: JSON].self, from: draft.data())
            XCTAssertEqual(json["conversation_context"]?.list.count, 2); XCTAssertEqual(json["conversations"]?.list.count, 1)
            XCTAssertFalse(next.teamWorkspace!.canSend(base.original, in: next)); XCTAssertEqual(local.pending, base.snapshot.pending)
        } }
    }
    func testCancelledSelectionCannotBypassIndirectMentionAndParksItExplicitly() throws {
        let (review, base, edit) = try authoredParking(); var local = base
        let task = try XCTUnwrap(local.tables["tasks"]?.first { $0.id == edit.recordID })
        _ = try attachRecoveryMention(&local, task: task, account: review.mutation.teamTaskBatch!.account)
        XCTAssertNil(review.cancelling(local)); XCTAssertFalse(review.canRequestCancellation(local))
        let draft = try TeamCompletionBatchDraft(review: review, snapshot: local)
        XCTAssertEqual(draft.parkedConversations, local.tables[ConversationOutbox.table]); XCTAssertTrue(draft.text.contains("Mention marked read:"))
        let next = try XCTUnwrap(review.parkingCancellation(local)); XCTAssertTrue(next.tables[ConversationOutbox.table]!.isEmpty)
        let json = try JSONDecoder().decode([String: JSON].self, from: draft.data()); XCTAssertEqual(json["conversation_context"]?.list.count, 2)
    }
    func testMentionRecoveryKeepsIndependentConversationsAndPrivateContextOutOfExport() throws {
        let (base, cache, edit, review) = try recoveryFixture(); var local = base.snapshot
        _ = try attachRecoveryMention(&local, task: XCTUnwrap(local.tables["tasks"]?.first { $0.id == edit.recordID }), account: base.account)
        var outside = local.tables["tasks"]![0]; outside["id"] = .string(UUID().uuidString.lowercased()); outside["task_generation"] = .string(UUID().uuidString.lowercased())
        local.tables["tasks"]!.append(outside)
        let (privateComment, unrelated) = try attachRecoveryMention(&local, task: outside, account: base.account)
        let privateRow = local.tables[ConversationOutbox.table]!.last!
        let draft = try TeamCompletionRecoveryDraft(group: review, snapshot: local), next = try XCTUnwrap(draft.preserving(readable: cache))
        XCTAssertEqual(next.tables[ConversationOutbox.table], [privateRow]); XCTAssertEqual(ConversationOutbox.mention(next.tables[ConversationOutbox.table]![0]), unrelated)
        let data = String(decoding: try draft.data(), as: UTF8.self)
        XCTAssertFalse(data.contains(privateComment.id)); XCTAssertFalse(data.contains(unrelated.mentionID)); XCTAssertTrue(next.tables["tasks"]!.contains(outside))
    }
    func testMentionRecoveryRejectsForeignForgedStaleAndAmbiguousContextAtomically() throws {
        let (base, _, edit, review) = try recoveryFixture()
        for mode in ["foreign", "generation", "project", "missing-mention", "future-revision", "comment-id", "recipient", "duplicate-comment", "duplicate-mention", "duplicate-outbox", "malformed-comment", "malformed-mention", "unknown-intent"] {
            var local = base.snapshot
            _ = try attachRecoveryMention(&local, task: XCTUnwrap(local.tables["tasks"]?.first { $0.id == edit.recordID }), account: base.account)
            var intent = local.tables[ConversationOutbox.table]![0]["intent"].object
            if mode == "foreign" { intent["account"] = .string(UUID().uuidString.lowercased()); local.tables[ConversationOutbox.table]![0]["account"] = intent["account"]! }
            if mode == "generation" { local.tables[SharedComment.table]![0]["task_generation"] = .string(UUID().uuidString.lowercased()) }
            if mode == "project" { local.tables[SharedComment.table]![0]["project_id"] = .string(UUID().uuidString.lowercased()) }
            if mode == "missing-mention" { local.tables[SharedMention.table] = [] }
            if mode == "future-revision" { intent["expected_revision"] = .number(4) }
            if mode == "comment-id" { intent["comment_id"] = .string(UUID().uuidString.lowercased()) }
            if mode == "recipient" { local.tables[SharedMention.table]![0]["recipient_id"] = .string(UUID().uuidString.lowercased()) }
            if mode == "duplicate-comment" { local.tables[SharedComment.table]!.append(local.tables[SharedComment.table]![0]) }
            if mode == "duplicate-mention" { local.tables[SharedMention.table]!.append(local.tables[SharedMention.table]![0]) }
            if mode == "malformed-comment" { local.tables[SharedComment.table]![0]["revision"] = .number(0) }
            if mode == "malformed-mention" { local.tables[SharedMention.table]![0]["revision"] = .number(0) }
            if mode == "unknown-intent" { intent["version"] = .number(2) }
            local.tables[ConversationOutbox.table]![0]["intent"] = .object(intent)
            if mode == "duplicate-outbox" { local.tables[ConversationOutbox.table]!.append(local.tables[ConversationOutbox.table]![0]) }
            let before = local; XCTAssertThrowsError(try TeamCompletionRecoveryDraft(group: review, snapshot: local), mode); XCTAssertEqual(local, before)
        }
    }
    func testMentionRecoveryBindsDraftCommentsAndQueuedDeletionWithoutChangingOriginalBodies() throws {
        let (base, cache, edit, review) = try recoveryFixture(); var local = base.snapshot
        _ = try attachRecoveryMention(&local, task: XCTUnwrap(local.tables["tasks"]?.first { $0.id == edit.recordID }), account: base.account, draftOnly: true)
        let row = try XCTUnwrap(local.tables["tasks"]?.first { $0.id == edit.recordID }), scope = edit.teamTaskScope!
        let deletion = Mutation(table: "tasks", recordID: row.id, method: "DELETE", fields: [:], baseline: row.fields, teamTaskScope: scope)
        append(deletion, to: &local)
        let draft = try TeamCompletionRecoveryDraft(group: review, snapshot: local)
        XCTAssertEqual(draft.parkedConversations, local.tables[ConversationOutbox.table]); XCTAssertEqual(draft.parkedChanges, local.pending)
        XCTAssertTrue(try XCTUnwrap(draft.preserving(readable: cache)).tables[ConversationOutbox.table]!.isEmpty)
        XCTAssertTrue(draft.text.contains("Unsent connected discussion"))
    }
    func testMentionRecoveryVaultRoundTripRetainsActualMarkerAndScopedExport() throws {
        let (base, cache, edit, review) = try recoveryFixture(); var local = base.snapshot
        _ = try attachRecoveryMention(&local, task: XCTUnwrap(local.tables["tasks"]?.first { $0.id == edit.recordID }), account: base.account)
        let draft = try TeamCompletionRecoveryDraft(group: review, snapshot: local)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256), vault = TeamCompletionRecoveryDraftVault(directory: directory, account: base.account, origin: base.origin, key: { key })
        let saved = try vault.save(draft), reopened = try vault.load(saved.id)
        XCTAssertEqual(reopened, draft); XCTAssertEqual(try reopened.data(), try draft.data()); XCTAssertEqual(reopened.preserving(readable: cache), draft.preserving(readable: cache))
        XCTAssertFalse(String(decoding: try Data(contentsOf: vault.file(saved.id)), as: UTF8.self).contains("workshop discussion"))
    }
}


extension TeamCompletionBatchTests {
    func testRecordedReceiptCannotSilentlyOrphanMentionOnlyWork() throws {
        for single in [false, true] {
            let (base, _, edit, review) = try recoveryFixture(single: single)
            var local = base.snapshot
            let task = try XCTUnwrap(local.tables["tasks"]?.first { $0.id == edit.recordID })
            local.pending.removeLast(); local.tables["tasks"]![local.tables["tasks"]!.firstIndex { $0.id == task.id }!] = TaskCompletionRevision.applying(["completed": .bool(true), "completed_at": .string(base.original.teamCompletion?.completedAt ?? base.original.teamTaskBatch!.items[0].teamCompletion!.completedAt)], to: base.original.teamCompletion?.source ?? base.original.teamTaskBatch!.items[0].teamCompletion!.source)
            _ = try attachRecoveryMention(&local, task: task, account: base.account)
            let before = local
            if single { XCTAssertNil(review.members[0].acknowledging(local)) }
            else { XCTAssertNil(review.acknowledging(local)) }
            XCTAssertEqual(local, before)
            let draft = single ? try TeamCompletionRecoveryDraft(single: review.members[0], snapshot: local) : try TeamCompletionRecoveryDraft(group: review, snapshot: local)
            XCTAssertEqual(draft.parkedChanges, [base.original]); XCTAssertEqual(draft.parkedConversations.count, 1)
        }
    }
}
