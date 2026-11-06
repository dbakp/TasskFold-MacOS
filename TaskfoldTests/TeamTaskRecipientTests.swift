import XCTest
@testable import TaskfoldCore

private final class RecipientHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, RecipientHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }; if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count)); if result.count > 64_000 { return nil }
        }
    }
    func finishData(_ data: Data, headers: [String: String]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    func finish(_ raw: [String: JSON]) {
        let data = try! JSONEncoder().encode(raw)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
final class TeamTaskRecipientTests: XCTestCase {
    private func fixture() throws -> [String: JSON] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "team-task-recipients-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
    }
    private func context(session: UUID = UUID(), project: String? = nil) throws -> (TeamTaskEditorDraft, TeamTaskRecipientCatalog, [String: JSON], TeamWorkspaceCache) {
        let f = try fixture(), account = f["account"]!.text, team = f["team"]!.text, project = project ?? f["project"]!.text
        var reply = f["reply"]!.object; reply["project_id"] = .string(project)
        let raw: [String: JSON] = ["workspace_boundary_protocol": .number(1), "account": .string(account), "native_team_reads_enabled": .bool(true), "setup_paused": .bool(false), "token": reply["access_token"]!, "teams": .array([.object(["id": .string(team), "state": .string("active"), "revision": .number(1), "access_revision": .number(1)])]), "projects": .array([.object(["id": .string(project), "team_id": .string(team), "role": .string("editor"), "archived": .bool(false), "can_send_tasks": .bool(true)])])]
        var row = Record.task(user: "ec240000-0000-4000-8000-000000000099", project: project); row["title"] = .string("Retained team work")
        let boundary = try TeamWorkspaceBoundary(raw, account: account, origin: f["origin"]!.text)
        let cache = try TeamWorkspaceCache(boundary: boundary, previous: nil, pending: [], tasks: [row])
        let draft = try TeamTaskEditorDraft(source: row, workspace: WorkspaceBinding(account: account, generation: UUID()), session: session, cache: cache, enabled: true)
        return (draft, try TeamTaskRecipientCatalog(reply, draft: draft), reply, cache)
    }
    func testActualSQLReplyIsProjectBoundAndDoesNotPromoteCreatorAuthority() throws {
        let (draft, catalog, _, cache) = try context()
        XCTAssertNotEqual(draft.source.string("user_id"), draft.scope.account)
        XCTAssertEqual(draft.role, .editor); XCTAssertEqual(catalog.people.count, 3)
        XCTAssertTrue(catalog.belongs(to: draft)); XCTAssertTrue(catalog.people.contains { $0.id == draft.scope.account && $0.displayName == nil })
        let recipient = try XCTUnwrap(catalog.people.first { $0.id != draft.scope.account })
        var desired = draft.source; desired["assigned_to"] = .string(recipient.id)
        let change = try XCTUnwrap(draft.mutation(desired: desired, current: draft.source, workspace: draft.workspace, session: draft.session, cache: cache, enabled: true))
        XCTAssertEqual(change.fields, ["assigned_to": .string(recipient.id)])
        XCTAssertEqual(change.teamTaskScope, draft.scope)
        XCTAssertEqual(change.baseline?["assigned_to"], .null)
    }
    func testCatalogRejectsWrongContextUnsupportedProtocolExtraDataAndUnsafeRows() throws {
        let (draft, _, raw, _) = try context()
        for key in ["account", "team_id", "project_id", "access_token"] {
            var bad = raw; bad[key] = .string(UUID().uuidString.lowercased())
            XCTAssertThrowsError(try TeamTaskRecipientCatalog(bad, draft: draft), key)
        }
        var bad = raw; bad["recipient_protocol"] = .number(2); XCTAssertThrowsError(try TeamTaskRecipientCatalog(bad, draft: draft))
        bad = raw; bad["email"] = .string("hidden@example.invalid"); XCTAssertThrowsError(try TeamTaskRecipientCatalog(bad, draft: draft))
        for field in ["role", "user_id", "display_name", "verified_email"] {
            bad = raw; var rows = raw["recipients"]!.list; var first = rows[0].object
            first[field] = .string(field == "role" ? "viewer" : field == "user_id" ? "invalid" : field == "display_name" ? "Spoof\u{202e}name" : "hidden@example.invalid")
            rows[0] = .object(first); bad["recipients"] = .array(rows)
            XCTAssertThrowsError(try TeamTaskRecipientCatalog(bad, draft: draft), field)
        }
        bad = raw; bad["recipients"] = .array(raw["recipients"]!.list.reversed()); XCTAssertThrowsError(try TeamTaskRecipientCatalog(bad, draft: draft))
        bad = raw; bad["recipients"] = .array(raw["recipients"]!.list + [raw["recipients"]!.list[0]]); XCTAssertThrowsError(try TeamTaskRecipientCatalog(bad, draft: draft))
        bad = raw; bad["recipients"] = .array(Array(repeating: raw["recipients"]!.list[0], count: 501)); XCTAssertThrowsError(try TeamTaskRecipientCatalog(bad, draft: draft))
    }
    @MainActor func testChoiceRechecksRosterAndRejectsDepartedRecipient() async throws {
        let (draft, catalog, raw, _) = try context(); let other = try XCTUnwrap(catalog.people.first { $0.id != draft.scope.account })
        var changed = raw; changed["recipients"] = .array(raw["recipients"]!.list.filter { $0.object["user_id"] != .string(other.id) })
        let fresh = try TeamTaskRecipientCatalog(changed, draft: draft)
        var reads = 0, applies = 0
        let picker = TeamTaskRecipientPicker(draft: draft, current: { true }, read: { reads += 1; return reads == 1 ? catalog : fresh }, apply: { _ in applies += 1; return nil })
        await picker.refresh(); let accepted = await picker.choose(other.id)
        XCTAssertFalse(accepted); XCTAssertEqual(reads, 2); XCTAssertEqual(applies, 0)
        XCTAssertEqual(picker.catalog, fresh); XCTAssertTrue(picker.message?.contains("no longer") == true)
    }
    @MainActor func testClearAndSelfRemainAvailableWithoutDirectoryOrNetwork() async throws {
        let (draft, _, _, _) = try context(); var choices: [String?] = [], reads = 0
        let picker = TeamTaskRecipientPicker(draft: draft, current: { true }, read: { reads += 1; throw URLError(.notConnectedToInternet) }, apply: { choices.append($0?.id); return nil })
        let clear = await picker.choose(nil), myself = await picker.choose(draft.scope.account)
        XCTAssertTrue(clear); XCTAssertTrue(myself); XCTAssertEqual(choices, [nil, draft.scope.account]); XCTAssertEqual(reads, 0)
    }
    @MainActor func testConnectivityLossKeepsReviewedIdentityAsIntentButOtherErrorsDoNot() async throws {
        let (draft, catalog, _, _) = try context(); let other = try XCTUnwrap(catalog.people.first { $0.id != draft.scope.account })
        for offline in [true, false] {
            var reads = 0, applies: [String] = []
            let picker = TeamTaskRecipientPicker(draft: draft, current: { true }, read: { reads += 1; if reads > 1 { if offline { throw URLError(.notConnectedToInternet) }; throw TeamTaskRecipientCatalog.invalid }; return catalog }, apply: { applies.append($0!.id); return nil })
            await picker.refresh(); let accepted = await picker.choose(other.id)
            XCTAssertEqual(accepted, offline); XCTAssertEqual(applies, offline ? [other.id] : [])
            if !offline { XCTAssertNil(picker.catalog) }
        }
    }
    @MainActor func testLateReplyAfterClosingOrRoleLossCannotApplyOrRetainNames() async throws {
        let (draft, catalog, _, _) = try context(); let other = try XCTUnwrap(catalog.people.first { $0.id != draft.scope.account })
        for close in [true, false] {
            var reads = 0, applies = 0, current = true
            var continuation: CheckedContinuation<TeamTaskRecipientCatalog, Error>?
            let picker = TeamTaskRecipientPicker(draft: draft, current: { current }, read: { reads += 1; if reads == 1 { return catalog }; return try await withCheckedThrowingContinuation { continuation = $0 } }, apply: { _ in applies += 1; return nil })
            await picker.refresh(); let choosing = Task { await picker.choose(other.id) }
            for _ in 0..<100 where continuation == nil { await Task.yield() }
            let waiting = try XCTUnwrap(continuation)
            if close { picker.invalidate() } else { current = false }
            waiting.resume(returning: catalog)
            let accepted = await choosing.value
            XCTAssertFalse(accepted); XCTAssertEqual(applies, 0); XCTAssertNil(picker.catalog)
        }
    }
    @MainActor func testDifferentProjectReplyAndUnlistedIdentityNeverReachEditor() async throws {
        let (draft, catalog, _, _) = try context(), (_, other, _, _) = try context(project: UUID().uuidString.lowercased())
        var applies = 0, reads = 0
        let picker = TeamTaskRecipientPicker(draft: draft, current: { true }, read: { reads += 1; return reads == 1 ? catalog : other }, apply: { _ in applies += 1; return nil })
        await picker.refresh(); let unknown = await picker.choose(UUID().uuidString.lowercased())
        XCTAssertFalse(unknown); XCTAssertEqual(reads, 1)
        let selected = try XCTUnwrap(catalog.people.first { $0.id != draft.scope.account })
        let wrong = await picker.choose(selected.id); XCTAssertFalse(wrong); XCTAssertEqual(applies, 0); XCTAssertNil(picker.catalog)
    }
    @MainActor func testBackendUsesOnlyScopedRecipientRPCAndRejectsStaleSession() async throws {
        let f = try fixture(), account = f["account"]!.text
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RecipientHTTP.self]
        let session = try JSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(account)\"}}".utf8))
        let backend = Backend(configuration: ["URL": f["origin"]!.text, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
        let (draft, expected, reply, _) = try context(session: backend.reminderSessionIncarnation)
        var calls = 0
        RecipientHTTP.handler = { request, http in
            calls += 1; XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_team_task_recipients")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertEqual(request.timeoutInterval, 25)
            let body = RecipientHTTP.body(request).flatMap { try? JSONDecoder().decode([String: JSON].self, from: $0) }
            XCTAssertEqual(body, ["_team_id": .string(draft.scope.team), "_project_id": .string(draft.scope.project)])
            http.finish(reply)
        }
        defer { RecipientHTTP.handler = nil }
        let actual = try await backend.teamTaskRecipients(draft); XCTAssertEqual(actual, expected); XCTAssertEqual(calls, 1)
        let (stale, _, _, _) = try context()
        do { _ = try await backend.teamTaskRecipients(stale); XCTFail("Stale session must not call HTTP") } catch { }
        XCTAssertEqual(calls, 1)
    }
}

extension TeamTaskRecipientTests {
    @MainActor func testTransportRejectsDeclaredAndStreamedOversizeBeforeCatalogParsing() async throws {
        let f = try fixture(), account = f["account"]!.text
        for declared in [true, false] {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RecipientHTTP.self]
            let session = try JSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(account)\"}}".utf8))
            let backend = Backend(configuration: ["URL": f["origin"]!.text, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
            let (draft, _, _, _) = try context(session: backend.reminderSessionIncarnation)
            RecipientHTTP.handler = { _, http in
                http.finishData(declared ? Data("{}".utf8) : Data(repeating: 32, count: 350_001), headers: declared ? ["Content-Length": "350001"] : [:])
            }
            defer { RecipientHTTP.handler = nil }
            do { _ = try await backend.teamTaskRecipients(draft); XCTFail("Oversize must fail") }
            catch { XCTAssertTrue(error.localizedDescription.contains("too large"), error.localizedDescription) }
        }
    }
}

extension TeamTaskRecipientTests {
    private func batchContext() throws -> (TeamTaskPlanningAdmission, [String: TeamTaskRecipientCatalog], [String: JSON]) {
        let (first, _, reply, initial) = try context()
        let secondProject = UUID().uuidString.lowercased()
        var second = first.source; second["id"] = .string(UUID().uuidString.lowercased()); second["project_id"] = .string(secondProject)
        var sibling = first.source; sibling["id"] = .string(UUID().uuidString.lowercased())
        var raw = initial.boundary.raw
        raw["projects"] = .array((raw["projects"]!.list + [.object(["id": .string(secondProject), "team_id": .string(first.scope.team), "role": .string("editor"), "archived": .bool(false), "can_send_tasks": .bool(true)])]).sorted { $0.object["id"]!.text < $1.object["id"]!.text })
        let boundary = try TeamWorkspaceBoundary(raw, account: first.scope.account, origin: first.scope.origin)
        let cache = try TeamWorkspaceCache(boundary: boundary, previous: nil, pending: [], tasks: [first.source, second, sibling])
        let admission = try TeamTaskPlanningAdmission(drafts: [first.source, second, sibling].map { try TeamTaskEditorDraft(source: $0, workspace: first.workspace, session: first.session, cache: cache, enabled: true) })
        var catalogs: [String: TeamTaskRecipientCatalog] = [:]
        for draft in admission.drafts {
            var raw = reply; raw["project_id"] = .string(draft.scope.project)
            catalogs[draft.scope.project] = try TeamTaskRecipientCatalog(raw, draft: draft)
        }
        return (admission, catalogs, reply)
    }
    @MainActor func testBatchIntersectionReadsEveryProjectOnceAndRefusesPartialRecipient() async throws {
        let (admission, initial, reply) = try batchContext(); var catalogs = initial, reads: [String: Int] = [:], applies = 0
        let target = try XCTUnwrap(initial.values.first!.people.first { $0.id != admission.drafts[0].scope.account })
        let second = admission.drafts.first { $0.scope.project != admission.drafts[0].scope.project }!
        var raw = reply; raw["project_id"] = .string(second.scope.project); raw["recipients"] = .array(raw["recipients"]!.list.filter { $0.object["user_id"] != .string(target.id) })
        catalogs[second.scope.project] = try TeamTaskRecipientCatalog(raw, draft: second)
        let picker = TeamTaskBatchRecipientPicker(admission: admission, current: { true }, read: { reads[$0.scope.project, default: 0] += 1; return catalogs[$0.scope.project]! }, apply: { _ in applies += 1; return nil })
        await picker.refresh(); XCTAssertEqual(reads.count, 2); XCTAssertTrue(reads.values.allSatisfy { $0 == 1 }); XCTAssertFalse(picker.people.contains { $0.id == target.id })
        let accepted = await picker.choose(target.id); XCTAssertFalse(accepted); XCTAssertEqual(applies, 0)
    }
    @MainActor func testBatchChoiceRechecksAllProjectsAndRejectsDepartedRecipient() async throws {
        let (admission, initial, reply) = try batchContext(); var catalogs = initial, applies = 0
        let target = try XCTUnwrap(initial.values.first!.people.first { $0.id != admission.drafts[0].scope.account })
        let picker = TeamTaskBatchRecipientPicker(admission: admission, current: { true }, read: { catalogs[$0.scope.project]! }, apply: { _ in applies += 1; return nil })
        await picker.refresh(); XCTAssertTrue(picker.people.contains { $0.id == target.id })
        let changed = admission.drafts.last!
        var raw = reply; raw["project_id"] = .string(changed.scope.project); raw["recipients"] = .array(raw["recipients"]!.list.filter { $0.object["user_id"] != .string(target.id) })
        catalogs[changed.scope.project] = try TeamTaskRecipientCatalog(raw, draft: changed)
        let accepted = await picker.choose(target.id); XCTAssertFalse(accepted); XCTAssertEqual(applies, 0); XCTAssertNotNil(picker.message)
        XCTAssertFalse(picker.people.contains { $0.id == target.id })
    }
    @MainActor func testBatchActorAndClearChoicesWorkOfflineButDoNotBypassChangedSource() async throws {
        let (admission, _, _) = try batchContext(); var current = true, applied: [String?] = []
        let picker = TeamTaskBatchRecipientPicker(admission: admission, current: { current }, read: { _ in throw URLError(.notConnectedToInternet) }, apply: { applied.append($0?.id); return nil })
        await picker.refresh(); XCTAssertNotNil(picker.message)
        let selfAccepted = await picker.choose(admission.drafts[0].scope.account), clearAccepted = await picker.choose(nil)
        XCTAssertTrue(selfAccepted); XCTAssertTrue(clearAccepted); XCTAssertEqual(applied.count, 2); XCTAssertNil(applied.last!)
        current = false
        let refused = await picker.choose(nil); XCTAssertFalse(refused); XCTAssertEqual(applied.count, 2); XCTAssertTrue(picker.people.isEmpty)
    }
    @MainActor func testBatchLateReplyCannotRetainDirectoryOrCreateReview() async throws {
        let (admission, catalogs, _) = try batchContext(); var current = true, applies = 0
        let picker = TeamTaskBatchRecipientPicker(admission: admission, current: { current }, read: { draft in current = false; return catalogs[draft.scope.project]! }, apply: { _ in applies += 1; return nil })
        await picker.refresh(); XCTAssertTrue(picker.people.isEmpty); XCTAssertEqual(applies, 0)
        let refused = await picker.choose(admission.drafts[0].scope.account); XCTAssertFalse(refused); XCTAssertEqual(applies, 0)
    }
    @MainActor func testBatchConnectivityRetainsReviewedIdentityButAuthorizationFailureClearsChoices() async throws {
        let (admission, catalogs, _) = try batchContext(); var failure: Error?, applies = 0
        let target = try XCTUnwrap(catalogs.values.first!.people.first { $0.id != admission.drafts[0].scope.account })
        let picker = TeamTaskBatchRecipientPicker(admission: admission, current: { true }, read: { draft in if let failure { throw failure }; return catalogs[draft.scope.project]! }, apply: { _ in applies += 1; return nil })
        await picker.refresh(); failure = URLError(.notConnectedToInternet)
        let offline = await picker.choose(target.id); XCTAssertTrue(offline); XCTAssertEqual(applies, 1)
        failure = AppFailure(message: "Access changed")
        let denied = await picker.choose(target.id); XCTAssertFalse(denied); XCTAssertEqual(applies, 1); XCTAssertTrue(picker.people.isEmpty)
    }
    @MainActor func testBatchCatalogForDifferentProjectCannotPopulateChoices() async throws {
        let (admission, catalogs, _) = try batchContext(); let wrong = catalogs[admission.drafts[0].scope.project]!
        let picker = TeamTaskBatchRecipientPicker(admission: admission, current: { true }, read: { _ in wrong }, apply: { _ in XCTFail("Unexpected review"); return nil })
        await picker.refresh(); XCTAssertTrue(picker.people.isEmpty); XCTAssertNotNil(picker.message)
    }
}

extension TeamTaskRecipientTests {
    @MainActor func testBatchDismissalStopsReadingRemainingProjects() async throws {
        let (admission, catalogs, _) = try batchContext(); var reads = 0
        var picker: TeamTaskBatchRecipientPicker?
        picker = TeamTaskBatchRecipientPicker(admission: admission, current: { true }, read: { draft in
            reads += 1; picker?.invalidate(); return catalogs[draft.scope.project]!
        }, apply: { _ in XCTFail("Dismissed picker must not review"); return nil })
        await picker?.refresh(); XCTAssertEqual(reads, 1); XCTAssertTrue(picker?.people.isEmpty == true)
    }
}

extension TeamTaskRecipientTests {
    @MainActor func testBatchConfirmedRecipientLossCannotBecomeCachedOfflineIntent() async throws {
        let (admission, catalogs, reply) = try batchContext(); var choosing = false, reads = 0, applies = 0
        let target = try XCTUnwrap(catalogs.values.first!.people.first { $0.id != admission.drafts[0].scope.account })
        let picker = TeamTaskBatchRecipientPicker(admission: admission, current: { true }, read: { draft in
            guard choosing else { return catalogs[draft.scope.project]! }
            reads += 1
            if reads > 1 { throw URLError(.notConnectedToInternet) }
            var raw = reply; raw["project_id"] = .string(draft.scope.project)
            raw["recipients"] = .array(raw["recipients"]!.list.filter { $0.object["user_id"] != .string(target.id) })
            return try TeamTaskRecipientCatalog(raw, draft: draft)
        }, apply: { _ in applies += 1; return nil })
        await picker.refresh(); XCTAssertTrue(picker.people.contains { $0.id == target.id }); choosing = true
        let accepted = await picker.choose(target.id)
        XCTAssertFalse(accepted); XCTAssertEqual(applies, 0); XCTAssertEqual(reads, 1)
        XCTAssertTrue(picker.people.isEmpty); XCTAssertNotNil(picker.message)
    }
}
