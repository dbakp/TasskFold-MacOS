import XCTest
@testable import TaskfoldCore

private let libraryAccount = "ec250000-0000-4000-8000-000000000001", libraryTeam = "ec250000-0000-4000-8000-000000000002", libraryOrigin = "https://library.example"
private func libraryID(_ n: Int) -> String { String(format: "ec250000-0000-4000-8001-%012d", n) }
private final class LibraryHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, LibraryHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func finish(_ raw: [String: JSON], status: Int = 200, length: Int? = nil) {
        var headers = ["Content-Type": "application/json"]
        if let length { headers["Content-Length"] = String(length) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(raw)); client?.urlProtocolDidFinishLoading(self)
    }
}
final class TeamTemplateLibraryTests: XCTestCase {
    func scope(role: String = "owner", archived: Bool = false) -> [String: JSON] {
        ["library_protocol": .number(1), "account": .string(libraryAccount), "team_id": .string(libraryTeam), "team_state": .string(archived ? "archived" : "active"), "role": .string(role), "can_manage": .bool(!archived && ["owner", "admin"].contains(role))]
    }
    func metadata(_ n: Int = 1) -> [String: JSON] {
        ["id": .string(libraryID(n)), "name": .string("Design review"), "revision": .number(1), "created_at": .string("2026-10-25T10:00:00+00:00"), "updated_at": .string("2026-10-25T10:00:00.123456+00:00")]
    }
    func pageRaw(_ numbers: [Int] = [1], next: Bool = false, revision: Double = 1, role: String = "owner") -> [String: JSON] {
        var raw = scope(role: role); raw["library_revision"] = .number(revision)
        raw["items"] = .array(numbers.map { .object(metadata($0)) }); raw["next_cursor"] = next ? .string(libraryID(numbers.last!)) : .null; return raw
    }
    func page(_ raw: [String: JSON]? = nil, after: String? = nil, revision: Double? = nil) throws -> TeamTemplatePage {
        try .init(raw ?? pageRaw(), account: libraryAccount, origin: libraryOrigin, team: libraryTeam, after: after, revision: revision)
    }
    func detailRaw(document: JSON? = nil) -> [String: JSON] {
        var raw = scope(), item = metadata(); item["document"] = document ?? .object(["version": .number(1), "kind": .string("task"), "projects": .array([]), "sections": .array([]), "tasks": .array([.object(["id": .string("task"), "title": .string("Review sketch"), "labels": .array([]), "subtasks": .array([])])])]); raw["item"] = .object(item); return raw
    }
    func detail(_ raw: [String: JSON]? = nil) throws -> TeamTemplateDetail {
        try .init(raw ?? detailRaw(), account: libraryAccount, origin: libraryOrigin, team: libraryTeam, template: libraryID(1))
    }
    func testAcceptedRolesAndArchivedCapabilities() throws {
        for role in ["owner", "admin", "member"] {
            for archived in [false, true] {
                let value = try TeamTemplateLibraryScope(scope(role: role, archived: archived), account: libraryAccount, origin: libraryOrigin, team: libraryTeam)
                XCTAssertEqual(value.canManage, !archived && role != "member")
            }
        }
        XCTAssertThrowsError(try TeamTemplateLibraryScope(scope(role: "guest"), account: libraryAccount, origin: libraryOrigin, team: libraryTeam))
    }
    func testScopeRejectsForeignIdentityProtocolAndForgedCapability() throws {
        for (key, value) in [("account", JSON.string(libraryTeam)), ("team_id", .string(libraryAccount)), ("library_protocol", .number(2)), ("team_state", .string("deleted")), ("role", .string("viewer")), ("can_manage", .bool(false))] {
            var raw = pageRaw(); raw[key] = value; XCTAssertThrowsError(try page(raw), key)
        }
        XCTAssertThrowsError(try TeamTemplateLibraryScope(scope(), account: libraryAccount, origin: libraryOrigin + "/", team: libraryTeam))
    }
    func testMetadataRejectsContentIdentityAndMalformedDates() throws {
        for (key, value) in [("document", JSON.object([:])), ("created_by", .string(libraryAccount)), ("id", .string("bad")), ("created_at", .string("yesterday")), ("revision", .number(0))] {
            var raw = metadata(); raw[key] = value; XCTAssertThrowsError(try TeamTemplateMetadata(raw), key)
        }
    }
    func testNamesAndExactIntegerBounds() throws {
        for bad in ["", "  ", "bad\nname", "bad\u{202e}name", String(repeating: "a", count: 161)] { XCTAssertThrowsError(try TeamTemplateLibraryValue.name(.string(bad))) }
        XCTAssertEqual(try TeamTemplateLibraryValue.name(.string(String(repeating: "a", count: 160))).count, 160)
        for value in [-1.0, 0, 1.5, Double.infinity, Double.nan, 9_007_199_254_740_992] { XCTAssertThrowsError(try TeamTemplateLibraryValue.revision(.number(value))) }
        XCTAssertEqual(try TeamTemplateLibraryValue.revision(.number(0), zero: true), 0)
        XCTAssertEqual(try TeamTemplateLibraryValue.revision(.number(9_007_199_254_740_991)), 9_007_199_254_740_991)
    }
    func testEmptyLibraryAndFullContinuation() throws {
        XCTAssertTrue(try page(pageRaw([], revision: 0)).items.isEmpty)
        let first = try page(pageRaw(Array(1...50), next: true, revision: 5)); XCTAssertEqual(first.next, libraryID(50))
        let last = try page(pageRaw([51], revision: 5), after: first.next, revision: first.revision); XCTAssertNil(last.next)
        XCTAssertThrowsError(try page(pageRaw([51], revision: 6), after: first.next, revision: first.revision))
    }
    func testPaginationRejectsDuplicateUnorderedAndNonadvancingRows() throws {
        for raw in [pageRaw([2, 1]), pageRaw([1, 1]), pageRaw(Array(1...51)), pageRaw([1], revision: 0), pageRaw([1], next: true)] { XCTAssertThrowsError(try page(raw)) }
        XCTAssertThrowsError(try page(pageRaw([50]), after: libraryID(50), revision: 1))
        XCTAssertThrowsError(try page(pageRaw([51]), after: libraryID(50)))
        var raw = pageRaw(Array(1...50), next: true); raw["next_cursor"] = .string(libraryID(49)); XCTAssertThrowsError(try page(raw))
    }
    func testDetailPreservesOpaqueFutureDocumentWithoutUsePermission() throws {
        let document = JSON.object(["version": .number(2), "future": .array([.string("keep intact")])]), result = try detail(detailRaw(document: document))
        XCTAssertEqual(result.document, document); XCTAssertNil(result.supported)
        XCTAssertFalse(String(reflecting: result).contains("keep intact"))
    }
    func testDetailFullyValidatesCurrentDocumentBeforeUse() throws {
        XCTAssertNotNil(try detail().supported)
        let result = try detail(detailRaw(document: .object(["version": .number(1), "kind": .string("task")]))); XCTAssertNil(result.supported)
    }
    func testDetailRejectsForeignItemAndUnboundedOrInvalidEnvelope() throws {
        var raw = detailRaw(), item = raw["item"]!.object; item["id"] = .string(libraryID(2)); raw["item"] = .object(item); XCTAssertThrowsError(try detail(raw))
        for document in [JSON.array([]), .object([:]), .object(["version": .number(0)]), .object(["version": .number(1), "text": .string(String(repeating: "a", count: 2_000_000))])] { XCTAssertThrowsError(try detail(detailRaw(document: document))) }
    }
    @MainActor func browser(current: @escaping () -> Bool = { true }, fence: @escaping () async throws -> String = { String(repeating: "a", count: 64) }, read: @escaping (String?, Double?) async throws -> TeamTemplatePage) -> TeamTemplateBrowser {
        TeamTemplateBrowser(account: libraryAccount, origin: libraryOrigin, team: libraryTeam, current: current, fence: fence, page: read, detail: { _ in try self.detail() })
    }
    @MainActor func testBrowserPublishesOnlyCompleteCoherentCatalog() async throws {
        let first = try page(pageRaw(Array(1...50), next: true, revision: 9)), last = try page(pageRaw([51], revision: 9), after: libraryID(50), revision: 9)
        var model: TeamTemplateBrowser!
        model = browser { cursor, revision in
            XCTAssertTrue(model.items.isEmpty)
            if cursor == nil { XCTAssertNil(revision); return first }
            XCTAssertEqual(cursor, libraryID(50)); XCTAssertEqual(revision, 9); return last
        }
        await model.refresh(); XCTAssertEqual(model.items.count, 51); XCTAssertNil(model.message); XCTAssertFalse(model.loading)
    }
    @MainActor func testBrowserDiscardsFailedContinuation() async throws {
        let first = try page(pageRaw(Array(1...50), next: true))
        let model = browser { cursor, _ in if cursor == nil { return first }; throw URLError(.notConnectedToInternet) }
        await model.refresh(); XCTAssertTrue(model.items.isEmpty); XCTAssertNil(model.scope); XCTAssertNotNil(model.message)
    }
    @MainActor func testBrowserRejectsRoleOrRevisionChangeBetweenPages() async throws {
        let first = try page(pageRaw(Array(1...50), next: true))
        for last in [try page(pageRaw([51], revision: 2), after: libraryID(50), revision: 2), try page(pageRaw([51], role: "member"), after: libraryID(50), revision: 1)] {
            let model = browser { cursor, _ in cursor == nil ? first : last }; await model.refresh(); XCTAssertTrue(model.items.isEmpty); XCTAssertNil(model.scope)
        }
    }
    @MainActor func testBrowserRejectsWorkspaceBoundaryChangeAndMalformedFence() async throws {
        for malformed in [false, true] {
            var calls = 0
            let model = browser(fence: { calls += 1; return malformed ? "bad" : String(repeating: calls == 1 ? "a" : "b", count: 64) }, read: { _, _ in try self.page() })
            await model.refresh(); XCTAssertTrue(model.items.isEmpty); XCTAssertNotNil(model.message)
        }
    }
    @MainActor func testBrowserDiscardsLateAccountAndInvalidatedReplies() async throws {
        for invalidate in [false, true] {
            var current = true, continuation: CheckedContinuation<Void, Never>?
            let p = try page()
            let model = browser(current: { current }) { _, _ in await withCheckedContinuation { continuation = $0 }; return p }
            let task = Task { await model.refresh() }
            while continuation == nil { await Task.yield() }
            if invalidate { model.invalidate() } else { current = false }
            continuation?.resume(); await task.value
            XCTAssertTrue(model.items.isEmpty); XCTAssertNil(model.scope); XCTAssertFalse(model.loading)
        }
    }
    @MainActor func testBrowserDetailAndSynchronousClear() async throws {
        let model = browser { _, _ in try self.page() }; await model.refresh(template: libraryID(1))
        XCTAssertNotNil(model.detail); XCTAssertTrue(model.items.isEmpty)
        model.invalidate(); XCTAssertNil(model.detail); XCTAssertNil(model.scope)
    }
    @MainActor func backend() throws -> Backend {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LibraryHTTP.self]
        let session = try JSONDecoder().decode(Session.self, from: Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(libraryAccount)\"}}".utf8))
        return Backend(configuration: ["URL": libraryOrigin, "Key": "synthetic-public"], http: URLSession(configuration: config), session: session, persistSession: { _ in })
    }
    @MainActor func testHTTPUsesExactReadContractAndPrivateRequestPolicy() async throws {
        let api = try backend(); var calls = 0
        LibraryHTTP.handler = { request, peer in
            calls += 1
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/taskfold_team_templates"); XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertFalse(request.httpShouldHandleCookies); XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(contentsOf: bytes.prefix(n)) } }
            let body = try! JSONDecoder().decode([String: JSON].self, from: data)
            XCTAssertEqual(Set(body.keys), ["_operation", "_body"])
            if calls == 1 { XCTAssertEqual(body["_operation"], .string("list")); XCTAssertEqual(body["_body"]?.object, ["team_id": .string(libraryTeam)]); peer.finish(self.pageRaw()) }
            else { XCTAssertEqual(body["_operation"], .string("get")); XCTAssertEqual(body["_body"]?.object, ["team_id": .string(libraryTeam), "template_id": .string(libraryID(1))]); peer.finish(self.detailRaw()) }
        }
        defer { LibraryHTTP.handler = nil }
        _ = try await api.teamTemplatePage(team: libraryTeam, account: libraryAccount, origin: libraryOrigin)
        _ = try await api.teamTemplateDetail(team: libraryTeam, template: libraryID(1), account: libraryAccount, origin: libraryOrigin)
        XCTAssertEqual(calls, 2)
        do { _ = try await api.teamTemplatePage(team: libraryTeam, account: libraryAccount, origin: "https://foreign.example"); XCTFail("Foreign origin") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 2)
    }
    @MainActor func testHTTPRejectsOversizedResponseAndSanitizesServerText() async throws {
        let api = try backend()
        defer { LibraryHTTP.handler = nil }
        LibraryHTTP.handler = { _, peer in peer.finish(self.pageRaw(), length: 3_000_001) }
        do { _ = try await api.teamTemplatePage(team: libraryTeam, account: libraryAccount, origin: libraryOrigin); XCTFail("Oversized") } catch {}
        LibraryHTTP.handler = { _, peer in peer.finish(["message": .string("private server text"), "code": .string("PT404")], status: 403) }
        do { _ = try await api.teamTemplatePage(team: libraryTeam, account: libraryAccount, origin: libraryOrigin); XCTFail("Denied") } catch { XCTAssertEqual((error as? AppFailure)?.message, TeamTemplateLibraryValue.invalid.message) }
    }
    @MainActor func testHTTPContinuationCarriesExactReviewedRevision() async throws {
        let api = try backend(); let raw = pageRaw([51], revision: 7)
        LibraryHTTP.handler = { request, peer in
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(contentsOf: bytes.prefix(n)) } }
            let body = try! JSONDecoder().decode([String: JSON].self, from: data)
            XCTAssertEqual(body["_body"], .object(["team_id": .string(libraryTeam), "cursor": .string(libraryID(50)), "library_revision": .number(7)])); peer.finish(raw)
        }
        defer { LibraryHTTP.handler = nil }
        let result = try await api.teamTemplatePage(team: libraryTeam, account: libraryAccount, origin: libraryOrigin, after: libraryID(50), revision: 7)
        XCTAssertEqual(result.items.first?.id, libraryID(51))
    }
    @MainActor func testHTTPInvalidContinuationIsRejectedBeforeNetwork() async throws {
        let api = try backend(); var calls = 0
        LibraryHTTP.handler = { _, _ in calls += 1; XCTFail("Invalid request reached network") }
        defer { LibraryHTTP.handler = nil }
        for revision: Double? in [nil, -1, 1.5, Double.infinity] {
            do { _ = try await api.teamTemplatePage(team: libraryTeam, account: libraryAccount, origin: libraryOrigin, after: libraryID(50), revision: revision); XCTFail("Invalid continuation") } catch {}
        }
        XCTAssertEqual(calls, 0)
    }
    @MainActor func testHTTPAuthorizationFailureIsRecognized() async throws {
        let api = try backend()
        LibraryHTTP.handler = { _, peer in peer.finish(["code": .string("28000"), "message": .string("private auth detail")], status: 403) }
        defer { LibraryHTTP.handler = nil }
        do { _ = try await api.teamTemplatePage(team: libraryTeam, account: libraryAccount, origin: libraryOrigin); XCTFail("Authorization") } catch { XCTAssertTrue(error is AccountSessionAuthorizationRequired) }
    }
    @MainActor func testHTTPReplyAfterSignOutCannotPublishContent() async throws {
        let api = try backend(); var held: LibraryHTTP?
        LibraryHTTP.handler = { _, peer in held = peer }
        defer { LibraryHTTP.handler = nil }
        let work = Task { try await api.teamTemplateDetail(team: libraryTeam, template: libraryID(1), account: libraryAccount, origin: libraryOrigin) }
        while held == nil { await Task.yield() }
        try await api.clearSession(); held?.finish(detailRaw())
        do { _ = try await work.value; XCTFail("Late content") } catch { XCTAssertTrue(error is CancellationError) }
    }
    @MainActor func testBrowserNewRefreshWinsOverOlderReply() async throws {
        var held: CheckedContinuation<Void, Never>?, calls = 0
        let old = try page(), fresh = try page(pageRaw([2], revision: 2))
        let model = browser { _, _ in calls += 1; if calls == 1 { await withCheckedContinuation { held = $0 }; return old }; return fresh }
        let work = Task { await model.refresh() }
        while held == nil { await Task.yield() }
        await model.refresh(); XCTAssertEqual(model.items.map(\.id), [libraryID(2)])
        held?.resume(); await work.value; XCTAssertEqual(model.items.map(\.id), [libraryID(2)]); XCTAssertNil(model.message)
    }

    func testLargeOpaqueDocumentIsNotRejectedByOptionalSlashEscaping() throws {
        let document = JSON.object(["version": .number(2), "future": .string(String(repeating: "/", count: 1_100_000))])
        let result = try detail(detailRaw(document: document)); XCTAssertEqual(result.document, document); XCTAssertNil(result.supported)
    }

    @MainActor func testAudienceIsFencedWithCatalogAndRoleMismatchCannotPublish() async throws {
        let organization = try TeamOrganizationDetail(["id": .string(libraryTeam), "name": .string("Design team"), "role": .string("owner"), "state": .string("active"), "revision": .number(1), "folders": .array([]), "members": .array([.object(["user_id": .string(libraryAccount), "role": .string("owner")])]), "invitations": .array([])], team: libraryTeam, account: libraryAccount, origin: libraryOrigin)
        for mismatch in [false, true] {
            let result = try page(pageRaw(role: mismatch ? "member" : "owner"))
            let model = TeamTemplateBrowser(account: libraryAccount, origin: libraryOrigin, team: libraryTeam, current: { true }, fence: { String(repeating: "a", count: 64) }, page: { _, _ in result }, detail: { _ in try self.detail() }, readTeam: { organization })
            await model.refresh()
            XCTAssertEqual(model.organization?.team.name, mismatch ? nil : "Design team")
            if mismatch { XCTAssertTrue(model.items.isEmpty); XCTAssertNotNil(model.message) }
            model.invalidate(); XCTAssertNil(model.organization)
        }
    }

    func testTransferMakesOneStablePrivateIdentityWithoutSharedMetadata() throws {
        let d = try detail(), workspace = WorkspaceBinding(account: libraryAccount, generation: UUID()), session = UUID()
        let review = try TeamTemplateTransferReview(detail: d, workspace: workspace, session: session)
        let copy = try review.privateCopy(name: "  My routine  ")
        XCTAssertEqual(Set(copy.fields.keys), ["id", "user_id", "name", "document"])
        XCTAssertEqual(copy.string("user_id"), libraryAccount); XCTAssertEqual(copy.name, "My routine"); XCTAssertEqual(copy["document"], d.document)
        XCTAssertNotEqual(copy.id, d.metadata.id); XCTAssertEqual(try review.privateCopy(name: "My routine"), copy)
        XCTAssertFalse(String(reflecting: review).contains("Design review"))
    }
    func testTransferExportIsPortableAndDoesNotContainAccountOrLibraryAuthority() throws {
        let d = try detail(), review = try TeamTemplateTransferReview(detail: d, workspace: WorkspaceBinding(account: libraryAccount, generation: UUID()), session: UUID())
        let bytes = try review.export(name: "Review kit").encoded(), file = try WorkflowTemplateFile(data: bytes)
        XCTAssertEqual(file.template.kind, d.supported?.kind); XCTAssertEqual(file.template.tasks.first?.title, d.supported?.tasks.first?.title); XCTAssertEqual(file.template.tasks.count, d.supported?.tasks.count); XCTAssertEqual(file.name, "Review kit")
        let raw = try JSONDecoder().decode([String: JSON].self, from: bytes)
        XCTAssertEqual(Set(raw.keys), ["format", "version", "name", "document"])
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(libraryAccount)); XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(d.metadata.id))
    }
    func testTransferRejectsForeignWorkspaceAndReuseOfTheSharedIdentity() throws {
        let d = try detail()
        XCTAssertThrowsError(try TeamTemplateTransferReview(detail: d, workspace: WorkspaceBinding(account: libraryTeam, generation: UUID()), session: UUID()))
        XCTAssertThrowsError(try TeamTemplateTransferReview(detail: d, workspace: WorkspaceBinding(account: libraryAccount, generation: UUID()), session: UUID(), id: UUID(uuidString: d.metadata.id)!))
    }
    func testFutureAndMalformedDefinitionsCannotBecomePrivateArtifacts() throws {
        for document in [JSON.object(["version": .number(2), "future": .string("preserved")]), .object(["version": .number(1)])] {
            let d = try detail(detailRaw(document: document))
            XCTAssertThrowsError(try TeamTemplateTransferReview(detail: d, workspace: WorkspaceBinding(account: libraryAccount, generation: UUID()), session: UUID()))
        }
    }
    func testTransferRequiresTheOriginalWorkspaceAndSessionIncarnations() throws {
        let d = try detail(), workspace = WorkspaceBinding(account: libraryAccount, generation: UUID()), session = UUID(), review = try TeamTemplateTransferReview(detail: d, workspace: workspace, session: session)
        XCTAssertNoThrow(try review.verify(latest: d, workspace: workspace, session: session))
        XCTAssertThrowsError(try review.verify(latest: d, workspace: WorkspaceBinding(account: libraryAccount, generation: UUID()), session: session))
        XCTAssertThrowsError(try review.verify(latest: d, workspace: workspace, session: UUID()))
    }
    func testTransferRefusesChangedDefinitionMetadataAndAccess() throws {
        let d = try detail(), workspace = WorkspaceBinding(account: libraryAccount, generation: UUID()), session = UUID(), review = try TeamTemplateTransferReview(detail: d, workspace: workspace, session: session)
        for key in ["name", "revision", "document"] {
            var raw = detailRaw(), item = raw["item"]!.object
            item[key] = key == "name" ? .string("Updated") : key == "revision" ? .number(2) : .object(["version": .number(2)])
            raw["item"] = .object(item); let changed = try detail(raw)
            XCTAssertThrowsError(try review.verify(latest: changed, workspace: workspace, session: session))
        }
        var raw = detailRaw(); raw["role"] = .string("member"); raw["can_manage"] = .bool(false)
        XCTAssertThrowsError(try review.verify(latest: detail(raw), workspace: workspace, session: session))
    }
    func testTransferNameValidationCannotMakeInvalidPrivateRecordsOrFiles() throws {
        let review = try TeamTemplateTransferReview(detail: detail(), workspace: WorkspaceBinding(account: libraryAccount, generation: UUID()), session: UUID())
        for name in ["", " ", "bad\u{202e}name", String(repeating: "a", count: 161)] {
            XCTAssertThrowsError(try review.privateCopy(name: name)); XCTAssertThrowsError(try review.export(name: name))
        }
    }

}
