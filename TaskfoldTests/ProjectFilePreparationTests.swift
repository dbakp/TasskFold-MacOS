import XCTest
@testable import TaskfoldCore

private final class FilePreparationIO: CalendarSecureItemIO, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: Data] = [:]
    var failWrite = false
    func read(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return rows[key] }
    func write(_ data: Data, key: String) throws { lock.lock(); defer { lock.unlock() }; if failWrite { throw URLError(.cannotWriteToFile) }; rows[key] = data }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; rows.removeValue(forKey: key) }
}
@MainActor private final class FilePreparationPeer: ProjectFilePreparationService {
    let raw: [String: JSON]
    var calls: [(ProjectFilePreparationRequest, ProjectFilePreparationAction)] = []
    var stored: ProjectFilePreparationRequest?
    var ready = false, losePrepare = false, cancelled = false, foreign = false, holdCopy = false
    var continuation: CheckedContinuation<Void, Never>?
    init(_ raw: [String: JSON]) { self.raw = raw }
    func projectFilePreparation(_ request: ProjectFilePreparationRequest, action: ProjectFilePreparationAction, incarnation: UUID) async throws -> ProjectFilePreparationPage? {
        calls.append((request, action))
        if action == .resolve && stored == nil { return nil }
        let hadPlan = stored != nil
        if stored == nil { stored = request }; guard stored == request else { throw ProjectFilePreparationRequest.invalid }
        switch action {
        case .prepare: if losePrepare { losePrepare = false; throw URLError(.networkConnectionLost) }
        case .copy: if holdCopy { await withCheckedContinuation { continuation = $0 } }; ready = true
        case .cancelRequest: cancelled = true
        default: break
        }
        var value = raw[cancelled && !hadPlan ? "cancelledEmpty" : ready ? "ready" : "prepared"]!.object
        if cancelled { value["state"] = .string("cancelled"); value["project_transferred"] = .bool(false) }
        value["expires_at"] = .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400)))
        value["request_id"] = request.body["request_id"]; value["scope"] = .object(request.scope.body)
        let expected = foreign ? try ProjectFilePreparationRequest(account: UUID().uuidString.lowercased(), origin: request.origin, body: request.body, expectedCount: request.expectedCount) : request
        return try ProjectFilePreparationPage(value, request: expected)
    }
}
@MainActor private final class PagedFilePeer: ProjectFilePreparationService {
    var actions:[ProjectFilePreparationAction]=[]
    var completed:Set<String>=[]
    let plan=UUID().uuidString.lowercased()
    let ids=(1...101).map { String(format:"11111111-1111-4111-8111-%012d",$0) }
    let expiry=ISO8601DateFormatter().string(from:Date().addingTimeInterval(86400))
    func projectFilePreparation(_ request:ProjectFilePreparationRequest,action:ProjectFilePreparationAction,incarnation:UUID) async throws -> ProjectFilePreparationPage? {
        actions.append(action);var cursor:String?
        switch action {case .copy(_,let operation):completed.insert(operation);case .check(_,let after):cursor=after;default:break}
        let offset=cursor.flatMap{ids.firstIndex(of:$0)}.map{$0+1} ?? 0, batch=Array(ids.dropFirst(offset).prefix(100))
        let next=offset+batch.count<ids.count ? batch.last.map(JSON.string) ?? .null : .null
        let items=batch.map { id in JSON.object(["operation_id":.string(id),"label":.string("Prepared file"),"byte_count":.number(1),"type":.string("application/pdf"),"state":.string(completed.contains(id) ? "ready" : "waiting")]) }
        return try ProjectFilePreparationPage(["protocol":.number(1),"plan_id":.string(plan),"request_id":request.body["request_id"]!,"scope":.object(request.scope.body),"state":.string(completed.count==ids.count ? "ready" : "preparing"),"total":.number(101),"prepared":.number(Double(completed.count)),"expires_at":.string(expiry),"items":.array(items),"next":next,"project_transferred":.bool(false)],request:request,plan:plan,after:cursor)
    }
}
private final class ProjectFileHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, ProjectFileHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request,self) }
    override func stopLoading() {}
    func reply(_ value: [String: JSON], status: Int = 200) {
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! TaskfoldJSONEncoder().encode(value));client?.urlProtocolDidFinishLoading(self)
    }
    static func body(_ request: URLRequest) throws -> [String: JSON] {
        var data=request.httpBody ?? Data()
        if let stream=request.httpBodyStream { stream.open();defer{stream.close()};var buffer=[UInt8](repeating:0,count:4096);while stream.hasBytesAvailable {let n=stream.read(&buffer,maxLength:buffer.count);if n<=0{break};data.append(contentsOf:buffer.prefix(n))} }
        return try TaskfoldJSONDecoder().decode([String:JSON].self,from:data)
    }
}
final class ProjectFilePreparationTests: XCTestCase {
    private func fixture() throws -> ([String: JSON], TeamProjectAdoptionInspection, ProjectFilePreparationRequest, ProjectFilePreparationPage) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "project-file-preparation-native-v1", withExtension: "json", subdirectory: "Fixtures"))
        let raw = try TaskfoldJSONDecoder().decode([String: JSON].self, from: Data(contentsOf: url))
        XCTAssertEqual(raw["syntheticOnly"], .bool(true)); XCTAssertEqual(raw["containerRemoved"], .bool(true))
        let request = try ProjectFilePreparationRequest(account: raw["account"]!.text, origin: raw["origin"]!.text, body: raw["request"]!.object, expectedCount: raw["expectedCount"]!.integer)
        return try (raw, TeamProjectAdoptionInspection(raw["inspection"]!.object, scope: request.scope), request, ProjectFilePreparationPage(raw["ready"]!.object, request: request))
    }
    func testGenuineServiceContractProducesExplicitSignedCommandAndExactColdReceipt() throws {
        let (raw, inspection, request, ready) = try fixture()
        XCTAssertTrue(inspection.filePreparationSupported); XCTAssertTrue(request.matches(inspection)); XCTAssertFalse(inspection.commitSupported)
        let consent = try ProjectFileConsent(pages: [ready]), decisions = try raw["command"]!.object["decisions"]!.list.map { try TeamProjectAdoptionDecision($0.object) }
        let review = try TeamProjectAdoptionReview(raw["review"]!.object, inspection: inspection, decisions: decisions, fileConsent: consent)
        XCTAssertTrue(review.canCommit); XCTAssertFalse(review.needsFileCustody)
        let command = try TeamProjectAdoptionCommand(review: review, requestID: UUID(uuidString: raw["command"]!.object["request_id"]!.text)!, now: review.expires.addingTimeInterval(-60))
        XCTAssertEqual(command.body, raw["command"]!.object); XCTAssertEqual(command.fileConsent, consent)
        XCTAssertFalse(try command.confirmed(raw["receipt"]!.object).replayed)
        let cold = try TaskfoldJSONDecoder().decode(TeamProjectAdoptionCommand.self, from: TaskfoldJSONEncoder().encode(command))
        XCTAssertEqual(cold, command); XCTAssertEqual(try cold.confirmed(raw["receipt"]!.object).command, command)
        XCTAssertFalse(String(reflecting: request).contains(request.inspectionToken))
    }
    func testInventoryPreparationOrUnrequestedReceiptNeverSubstituteForConsent() throws {
        let (raw, i, request, ready) = try fixture()
        XCTAssertThrowsError(try ProjectFileConsent(pages: [ProjectFilePreparationPage(raw["prepared"]!.object, request: request)]))
        let decisions = try raw["command"]!.object["decisions"]!.list.map { try TeamProjectAdoptionDecision($0.object) }
        XCTAssertThrowsError(try TeamProjectAdoptionReview(raw["review"]!.object, inspection: i, decisions: decisions))
        let consent = try ProjectFileConsent(pages: [ready]); var fields = raw["review"]!.object
        fields["file_transfer"] = .object(consent.receipt.object); XCTAssertThrowsError(try TeamProjectAdoptionReview(fields, inspection: i, decisions: decisions, fileConsent: consent))
        fields = raw["review"]!.object; var facts = fields["file_transfer"]!.object; facts["byte_count"] = .number(Double(consent.bytes + 1)); fields["file_transfer"] = .object(facts)
        XCTAssertThrowsError(try TeamProjectAdoptionReview(fields, inspection: i, decisions: decisions, fileConsent: consent))
    }
    func testPlanRejectsForeignScopeMissingKeysOverexposureAndFalseCommit() throws {
        let (raw, _, request, _) = try fixture()
        for key in ["scope", "request_id", "plan_id", "next"] { var p = raw["ready"]!.object; p.removeValue(forKey: key); XCTAssertThrowsError(try ProjectFilePreparationPage(p, request: request)) }
        for (key, value) in ["request_id": JSON.string(UUID().uuidString.lowercased()), "source_name": .string("private/provider"), "project_transferred": .bool(true), "prepared": .number(0), "next": .string(UUID().uuidString.lowercased())] {
            var p = raw["ready"]!.object; p[key] = value; XCTAssertThrowsError(try ProjectFilePreparationPage(p, request: request))
        }
        var p = raw["ready"]!.object; p["state"] = .string("committed"); p["project_transferred"] = .bool(true)
        XCTAssertEqual(try ProjectFilePreparationPage(p, request: request).state, .committed)
        p["prepared"] = .number(0); XCTAssertThrowsError(try ProjectFilePreparationPage(p, request: request))
    }
    func testEmptyCancellationIsClosedButCannotAuthorizeSharing() throws {
        let (raw, _, request, _) = try fixture()
        let cancelled = try ProjectFilePreparationRequest(account: request.account, origin: request.origin, body: raw["cancelledRequest"]!.object, expectedCount: request.expectedCount)
        let page = try ProjectFilePreparationPage(raw["cancelledEmpty"]!.object, request: cancelled)
        XCTAssertEqual(page.total, 0); XCTAssertEqual(page.state, .cancelled); XCTAssertThrowsError(try ProjectFileConsent(pages: [page]))
        var value = raw["cancelledEmpty"]!.object; value["state"] = .string("ready"); XCTAssertThrowsError(try ProjectFilePreparationPage(value, request: cancelled))
    }
    func testRequestColdDecodeRevalidatesBodyAndBoundedCounts() throws {
        let (_, i, request, _) = try fixture()
        XCTAssertEqual(try ProjectFilePreparationRequest(i, requestID: UUID(uuidString: request.id)!), request)
        XCTAssertEqual(try TaskfoldJSONDecoder().decode(ProjectFilePreparationRequest.self, from: TaskfoldJSONEncoder().encode(request)), request)
        for count in [0,10001] { XCTAssertThrowsError(try ProjectFilePreparationRequest(account: request.account, origin: request.origin, body: request.body, expectedCount: count)) }
        var body = request.body; body["provider_path"] = .string("secret"); XCTAssertThrowsError(try ProjectFilePreparationRequest(account: request.account, origin: request.origin, body: body, expectedCount: 1))
        body = request.body; body["inspection_token"] = .string("weak"); XCTAssertThrowsError(try ProjectFilePreparationRequest(account: request.account, origin: request.origin, body: body, expectedCount: 1))
    }
    @MainActor func testLostFirstReplyColdLoadIsReadOnlyThenExplicitResumeReusesExactRequest() async throws {
        let (raw, i, _, _) = try fixture(), io = FilePreparationIO(), vault = ProjectFilePreparationVault(io: io), peer = FilePreparationPeer(raw), incarnation = UUID()
        peer.losePrepare = true
        let first = ProjectFilePreparationModel(account: i.scope.account, origin: i.scope.origin, incarnation: incarnation, vault: vault, service: peer, current: { true })
        await first.prepare(i); let saved = try XCTUnwrap(first.request); XCTAssertNil(first.consent); XCTAssertEqual(peer.calls.count, 1); first.close()
        let cold = ProjectFilePreparationModel(account: i.scope.account, origin: i.scope.origin, incarnation: incarnation, vault: vault, service: peer, current: { true })
        await cold.load(); XCTAssertEqual(cold.request, saved); XCTAssertEqual(peer.calls.last?.1, .resolve); XCTAssertEqual(peer.calls.count, 2); XCTAssertNil(cold.consent)
        await cold.resume(); XCTAssertEqual(cold.request, saved); XCTAssertNotNil(cold.consent); XCTAssertTrue(peer.calls.allSatisfy { $0.0 == saved })
        XCTAssertEqual(peer.calls.filter { if case .copy = $0.1 { return true }; return false }.count, 1)
        await cold.cancel(); XCTAssertNil(cold.request); XCTAssertNil(cold.consent); let remaining = try await vault.pending(account: saved.account, origin: saved.origin); XCTAssertNil(remaining)
    }
    @MainActor func testSecureWriteFailureMakesNoNetworkCallOrSavedClaim() async throws {
        let (raw, i, _, _) = try fixture(), io = FilePreparationIO(), peer = FilePreparationPeer(raw); io.failWrite = true
        let model = ProjectFilePreparationModel(account: i.scope.account, origin: i.scope.origin, incarnation: UUID(), vault: ProjectFilePreparationVault(io: io), service: peer, current: { true })
        await model.prepare(i); XCTAssertEqual(peer.calls.count, 0); XCTAssertNil(model.request); XCTAssertFalse(model.message?.contains("exact request is saved") ?? true)
    }
    @MainActor func testForeignResponseAndClosedContextCannotProduceConsent() async throws {
        let (raw, i, _, _) = try fixture(), io = FilePreparationIO(), peer = FilePreparationPeer(raw); peer.foreign = true
        var current = true
        let model = ProjectFilePreparationModel(account: i.scope.account, origin: i.scope.origin, incarnation: UUID(), vault: ProjectFilePreparationVault(io: io), service: peer, current: { current })
        await model.prepare(i); XCTAssertNil(model.consent); XCTAssertEqual(peer.calls.count, 1); current = false; await model.resume(); XCTAssertEqual(peer.calls.count, 1); model.close(); XCTAssertNil(model.request); XCTAssertTrue(model.pages.isEmpty)
    }
    @MainActor func testStopKeepsRequestAndIgnoresLateCopyResult() async throws {
        let (raw, i, _, _) = try fixture(), io = FilePreparationIO(), peer = FilePreparationPeer(raw); peer.holdCopy = true
        let vault = ProjectFilePreparationVault(io: io), model = ProjectFilePreparationModel(account: i.scope.account, origin: i.scope.origin, incarnation: UUID(), vault: vault, service: peer, current: { true })
        let task = Task { await model.prepare(i) }; for _ in 0..<10000 { if peer.continuation != nil { break }; await Task.yield() }
        let continuation = try XCTUnwrap(peer.continuation), saved = try XCTUnwrap(model.request); model.stop(); XCTAssertFalse(model.busy); XCTAssertTrue(model.paused); XCTAssertNil(model.consent); continuation.resume(); await task.value
        XCTAssertNil(model.consent); XCTAssertEqual(model.request, saved); let retained = try await vault.pending(account: saved.account, origin: saved.origin); XCTAssertEqual(retained, saved)
        await model.resume(); XCTAssertNotNil(model.consent)
    }
    @MainActor func testLateStoppedRunCannotUnlockOrReplaceNewRun() async throws {
        let (raw, inspection, _, _) = try fixture(), io = FilePreparationIO(), peer = FilePreparationPeer(raw)
        peer.holdCopy = true
        let vault = ProjectFilePreparationVault(io: io)
        let model = ProjectFilePreparationModel(account: inspection.scope.account, origin: inspection.scope.origin, incarnation: UUID(), vault: vault, service: peer, current: { true })
        let first = Task { await model.prepare(inspection) }
        for _ in 0..<10000 { if peer.continuation != nil { break }; await Task.yield() }
        let oldReply = try XCTUnwrap(peer.continuation), saved = try XCTUnwrap(model.request)
        model.stop(); XCTAssertFalse(model.busy)
        peer.continuation = nil
        let second = Task { await model.resume() }
        for _ in 0..<10000 { if peer.continuation != nil { break }; await Task.yield() }
        let newReply = try XCTUnwrap(peer.continuation)
        XCTAssertTrue(model.busy); XCTAssertFalse(model.paused)
        oldReply.resume(); await first.value
        XCTAssertTrue(model.busy); XCTAssertNil(model.consent)
        XCTAssertEqual(model.request, saved); XCTAssertEqual(model.page?.state, .preparing)
        newReply.resume(); await second.value
        XCTAssertFalse(model.busy); XCTAssertNotNil(model.consent)
        XCTAssertTrue(peer.calls.allSatisfy { $0.0 == saved })
    }
    @MainActor func testCloseImmediatelyReleasesControlsAndFencesHeldReply() async throws {
        let (raw, inspection, _, _) = try fixture(), io = FilePreparationIO(), peer = FilePreparationPeer(raw)
        peer.holdCopy = true
        let vault = ProjectFilePreparationVault(io: io)
        let model = ProjectFilePreparationModel(account: inspection.scope.account, origin: inspection.scope.origin, incarnation: UUID(), vault: vault, service: peer, current: { true })
        let task = Task { await model.prepare(inspection) }
        for _ in 0..<10000 { if peer.continuation != nil { break }; await Task.yield() }
        let reply = try XCTUnwrap(peer.continuation), saved = try XCTUnwrap(model.request)
        model.stop(); model.close()
        XCTAssertFalse(model.busy); XCTAssertNil(model.request); XCTAssertTrue(model.pages.isEmpty)
        reply.resume(); await task.value
        XCTAssertNil(model.consent); XCTAssertTrue(model.pages.isEmpty); XCTAssertNil(model.message)
        let retained = try await vault.pending(account: saved.account, origin: saved.origin)
        XCTAssertEqual(retained, saved)
    }
    @MainActor func testPausedServiceCannotOfferReadyCopyConsent() async throws {
        let (raw, inspection, _, _) = try fixture(), peer = FilePreparationPeer(raw)
        let model = ProjectFilePreparationModel(account: inspection.scope.account, origin: inspection.scope.origin, incarnation: UUID(), vault: ProjectFilePreparationVault(io: FilePreparationIO()), service: peer, current: { true })
        await model.prepare(inspection); XCTAssertNotNil(model.consent(for: inspection))
        var fields = raw["inspection"]!.object
        fields["file_preparation"] = .object(["protocol": .number(1), "enabled": .bool(false)])
        let paused = try TeamProjectAdoptionInspection(fields, scope: inspection.scope)
        XCTAssertTrue(model.request?.matches(paused) == true)
        XCTAssertNil(model.consent(for: paused)); XCTAssertNotNil(model.consent(for: inspection))
        // Idle Stop must not revoke an already reviewed, ready preparation.
        model.stop(); XCTAssertNotNil(model.consent(for: inspection))
    }

    @MainActor func testAnotherWindowClearingSavedRequestRevokesLocalConsent() async throws {
        let (raw,i,_,_) = try fixture(), io=FilePreparationIO(), peer=FilePreparationPeer(raw), vault=ProjectFilePreparationVault(io: io)
        let model=ProjectFilePreparationModel(account:i.scope.account,origin:i.scope.origin,incarnation:UUID(),vault:vault,service:peer,current:{true})
        await model.prepare(i); let saved=try XCTUnwrap(model.request); XCTAssertNotNil(model.consent)
        try await vault.clear(saved,lease:CalendarReadLease()); await model.load()
        XCTAssertNil(model.request); XCTAssertNil(model.consent); XCTAssertTrue(model.pages.isEmpty)
    }

    @MainActor func testBackendUsesFixedPrivateGatewayWithExactFrozenBodyAndExplicitConsent() async throws {
        let (raw,i,request,ready)=try fixture(), config=URLSessionConfiguration.ephemeral
        config.protocolClasses=[ProjectFileHTTP.self]
        let session=try TaskfoldJSONDecoder().decode(Session.self,from:Data("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(request.account)\"}}".utf8))
        let api=Backend(configuration:["URL":request.origin,"Key":"synthetic-public"],http:URLSession(configuration:config),session:session,persistSession:{_ in})
        var calls=0
        ProjectFileHTTP.handler={ r,peer in
            calls+=1;XCTAssertEqual(r.url?.absoluteString,request.origin+"/functions/v1/project-files?action=resolve");XCTAssertEqual(r.httpMethod,"POST")
            XCTAssertEqual(r.value(forHTTPHeaderField:"Authorization"),"Bearer synthetic-auth");XCTAssertEqual(r.value(forHTTPHeaderField:"Cache-Control"),"no-store")
            XCTAssertEqual(try! ProjectFileHTTP.body(r),request.body);peer.reply(["absent":.bool(true)])
        };defer{ProjectFileHTTP.handler=nil}
        let absent=try await api.projectFilePreparation(request,action:.resolve,incarnation:api.reminderSessionIncarnation);XCTAssertNil(absent);XCTAssertEqual(calls,1)
        let consent=try ProjectFileConsent(pages:[ready]),decisions=try raw["command"]!.object["decisions"]!.list.map{try TeamProjectAdoptionDecision($0.object)}
        ProjectFileHTTP.handler={r,peer in
            calls+=1;XCTAssertEqual(r.url?.path,"/rest/v1/rpc/taskfold_team_project_adoption")
            let b=try! ProjectFileHTTP.body(r);XCTAssertEqual(b["operation"],.string("review"));XCTAssertEqual(b["body"]!.object["file_policy"],consent.policy)
            peer.reply(raw["review"]!.object)
        }
        let reviewed=try await api.reviewProjectAdoption(i,decisions:decisions,connectionPolicy:nil,fileConsent:consent)
        XCTAssertEqual(reviewed.fileConsent,consent);XCTAssertTrue(reviewed.canCommit);XCTAssertEqual(calls,2)
    }
    @MainActor func testBackendRefusesWrongAccountBeforeNetwork() async throws {
        let (_,_,request,_)=try fixture(),config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ProjectFileHTTP.self]
        let api=Backend(configuration:["URL":request.origin,"Key":"synthetic-public"],http:URLSession(configuration:config),session:nil,persistSession:{_ in})
        var calls=0;ProjectFileHTTP.handler={_,_ in calls+=1};defer{ProjectFileHTTP.handler=nil}
        do{_ = try await api.projectFilePreparation(request,action:.prepare,incarnation:api.reminderSessionIncarnation);XCTFail("Wrong account must be refused")}catch{}
        XCTAssertEqual(calls,0)
    }

    @MainActor func testLargeManifestPagesOnlyAtStartAndFinish() async throws {
        let (raw,old,_,_)=try fixture();var fields=raw["inspection"]!.object,contents=fields["contents"]!.object
        contents["file_custody"] = .object(["protocol":.number(1),"stored":.number(101),"legacy":.number(0),"unavailable":.number(0)])
        contents["attachments"] = .number(102);contents["provider_files"] = .number(101);fields["contents"] = .object(contents)
        let inspection=try TeamProjectAdoptionInspection(fields,scope:old.scope),peer=PagedFilePeer(),io=FilePreparationIO()
        let model=ProjectFilePreparationModel(account:old.scope.account,origin:old.scope.origin,incarnation:UUID(),vault:ProjectFilePreparationVault(io:io),service:peer,current:{true})
        await model.prepare(inspection)
        XCTAssertEqual(model.consent?.count,101);XCTAssertEqual(peer.completed.count,101)
        XCTAssertEqual(peer.actions.filter{if case .check = $0{return true};return false}.count,2)
    }

    func testTransferredCopyRetainsExistingUploadReceiptCodec() throws {
        let (raw,_,request,_)=try fixture(),intent=Record(raw["taskFileResolveIntent"]!.object)
        let bytes=try XCTUnwrap(Data(base64Encoded:raw["syntheticSourceBase64"]!.text))
        let operation=try XCTUnwrap(UUID(uuidString:intent.string("operation_id")))
        let journal=try TaskFileUploadJournal(account:request.account,origin:request.origin,target:Record(intent["target"].object),bytes:bytes,name:intent.string("name"),type:intent.string("type"),operation:operation)
        let attempted=try journal.markingAttempted()
        let received=try attempted.receiving(TaskfoldJSONEncoder().encode(["receipt":raw["taskFileResolveReceipt"]!]))
        XCTAssertEqual(received.phase,.published);XCTAssertEqual(received.bytes,bytes)
        XCTAssertEqual(received.receipt?["attachment"].object["name"],intent["name"])
    }

}
