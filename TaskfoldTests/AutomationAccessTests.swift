import XCTest
import CryptoKit
@testable import TaskfoldCore

private final class AutomationHTTP: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest, AutomationHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() { Self.handler?(request, self) }
    func finish(_ data: Data, status: Int = 200) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
private final class AutomationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held: AutomationHTTP?
    func hold(_ transport: AutomationHTTP) { lock.lock(); held = transport; lock.unlock() }
    func release(_ data: Data) { lock.lock(); let value = held; held = nil; lock.unlock(); value?.finish(data) }
}
final class AutomationAccessTests: XCTestCase {
    let owner="f091cafe-0000-4000-8000-000000000001", other="f091cafe-0000-4000-8000-000000000002"
    let keyID="f091cafe-0000-4000-8000-000000000021", origin="https://automation-native.test"
    func draft() throws -> AutomationKeyDraft { try AutomationKeyDraft(account: owner, origin: origin, name: "Build script", scopes: [.create,.read], days: 30, id: UUID(uuidString:keyID)!, entropy: { Data(0..<32) }) }
    func row(_ id: String? = nil, revoked: Bool = false) -> [String: JSON] {
        let id=id ?? keyID
        return ["id":.string(id),"name":.string("Build script"),"prefix":.string("tfk_v1_" + id.replacingOccurrences(of:"-",with:"").prefix(8)),"scopes":.array([.string("tasks:create"),.string("tasks:read")]),"created_at":.string("2026-10-22T12:00:00+00:00"),"expires_at":.string("2026-11-21T12:00:00+00:00"),"revoked_at":revoked ? .string("2026-10-23T12:00:00Z") : .null,"last_used_at":.null]
    }
    func testSecretIsBoundToIDAndOnlyHashEntersRegistration() throws {
        let draft=try draft(), expected="tfk_v1_" + keyID.replacingOccurrences(of:"-",with:"") + "_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        XCTAssertEqual(draft.secretForOneTimeReview,expected)
        XCTAssertEqual(draft.body["token_hash"],.string(SHA256.hash(data:Data(expected.utf8)).map{String(format:"%02x",$0)}.joined()))
        let encoded=String(data:try JSONEncoder().encode(draft.body),encoding:.utf8)!
        XCTAssertFalse(encoded.contains(expected));XCTAssertFalse(String(reflecting:draft).contains(expected));XCTAssertFalse(String(describing:draft).contains(expected))
        XCTAssertEqual(Set(draft.body.keys),["id","name","scopes","token_hash","ttl_days"])
    }
    func testInvalidSettingsFailBeforeRequestOrEntropy() throws {
        var entropyCalls=0
        for input in [("",Set([AutomationScope.create]),30),(String(repeating:"🙂",count:81),Set([.create]),30),("line\nbreak",Set([.read]),30),("Script",Set<AutomationScope>(),30),("Script",Set([.read]),0)] {
            XCTAssertThrowsError(try AutomationKeyDraft(account:owner,origin:origin,name:input.0,scopes:input.1,days:input.2,entropy:{entropyCalls+=1;return Data(0..<32)}))
        }
        XCTAssertEqual(entropyCalls,0)
        for bad in ["http://automation-native.test","https://user:pass@automation-native.test","https://automation-native.test/other","https://automation-native.test?target=other","https://"] {
            XCTAssertThrowsError(try AutomationKeyDraft(account:owner,origin:bad,name:"Script",scopes:[.create],days:30))
        }
        XCTAssertThrowsError(try AutomationKeyDraft(account:"../other",origin:origin,name:"Script",scopes:[.create],days:30))
        XCTAssertThrowsError(try AutomationKeyDraft(account:owner,origin:origin,name:"Script",scopes:[.create],days:30,entropy:{Data([1])}))
    }
    func testNewEnrollmentUsesFreshSystemEntropyAndIdentity() throws {
        let a=try AutomationKeyDraft(account:owner,origin:origin,name:"One",scopes:[.create],days:30)
        let b=try AutomationKeyDraft(account:owner,origin:origin,name:"Two",scopes:[.create],days:30)
        XCTAssertNotEqual(a.id,b.id);XCTAssertNotEqual(a.secretForOneTimeReview,b.secretForOneTimeReview)
        XCTAssertEqual(a.secretForOneTimeReview.utf8.count,83)
    }
    func testMetadataStatusAndStrictUnknownScopeRejection() throws {
        let key=try AutomationKey(row());XCTAssertTrue(key.active(at:key.created));XCTAssertFalse(key.active(at:key.expires));XCTAssertFalse(try AutomationKey(row(revoked:true)).active(at:key.created))
        for (field,value) in [("scopes",JSON.array([.string("admin")])),("scopes",.array([.string("tasks:create"),.string("tasks:create")])),("expires_at",.string("not a date")),("prefix",.string("PRIVATE TOKEN")),("revoked_at",.string(""))] {
            var fields=row();fields[field]=value;XCTAssertThrowsError(try AutomationKey(fields))
        }
    }
    func testCatalogRejectsForeignOwnerDuplicateKeysAndInvalidCursor() throws {
        let good:[String:JSON]=["account":.string(owner),"keys":.array([.object(row())]),"next_cursor":.null]
        XCTAssertEqual(try AutomationKeyPage(good,account:owner).keys.count,1)
        for changed in [["account":JSON.string(other)],["keys":.array([.object(row()),.object(row())])],["next_cursor":.string(other)],["next_cursor":.string("")]] {
            XCTAssertThrowsError(try AutomationKeyPage(good.merging(changed){_,new in new},account:owner))
        }
    }
    @MainActor func backend(_ account: String? = nil) throws -> Backend {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[AutomationHTTP.self]
        let session=try JSONDecoder().decode(Session.self,from:Data(("{\"access_token\":\"synthetic-auth\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600,\"user\":{\"id\":\""+(account ?? owner)+"\"}}").utf8))
        return Backend(configuration:["URL":origin,"Key":"synthetic-public"],http:URLSession(configuration:config),session:session,persistSession:{_ in})
    }
    @MainActor func testNativeRegistrationRetriesSameIDAndHashWithoutSendingSecret() async throws {
        let api=try backend(),draft=try draft();var requests:[Data]=[]
        let reply=try JSONEncoder().encode(["account":JSON.string(owner),"key":.object(row())])
        AutomationHTTP.handler={request,transport in
            XCTAssertEqual(request.url?.path,"/functions/v1/automation-keys");XCTAssertEqual(request.value(forHTTPHeaderField:"X-Taskfold-Automation"),"1");XCTAssertFalse(request.httpShouldHandleCookies)
            let data=request.httpBody ?? {let stream=request.httpBodyStream!;stream.open();defer{stream.close()};var data=Data(),buffer=[UInt8](repeating:0,count:4096);while stream.hasBytesAvailable {let n=stream.read(&buffer,maxLength:buffer.count);if n<=0{break};data.append(buffer,count:n)};return data}()
            requests.append(data);XCTAssertFalse(String(decoding:data,as:UTF8.self).contains(draft.secretForOneTimeReview))
            transport.finish(requests.count==1 ? Data(#"{"error":"Retry"}"#.utf8) : reply,status:requests.count==1 ? 503 : 200)
        };defer{AutomationHTTP.handler=nil}
        do{_ = try await api.registerAutomationKey(draft);XCTFail("Failure accepted")}catch{}
        let registered = try await api.registerAutomationKey(draft)
        XCTAssertEqual(registered.id,draft.id)
        XCTAssertEqual(requests.count,2);XCTAssertEqual(try JSONDecoder().decode(JSON.self,from:requests[0]),try JSONDecoder().decode(JSON.self,from:requests[1]))
    }
    @MainActor func testChangedAccountOrServerCannotSendOriginalDraft() async throws {
        let api=try backend(other);var requests=0
        AutomationHTTP.handler={_,_ in requests+=1};defer{AutomationHTTP.handler=nil}
        do{_ = try await api.registerAutomationKey(draft());XCTFail("Foreign account used draft")}catch{}
        let foreign=try AutomationKeyDraft(account:other,origin:"https://another.test",name:"Script",scopes:[.create],days:30)
        do{_ = try await api.registerAutomationKey(foreign);XCTFail("Original draft sent to another server")}catch{}
        XCTAssertEqual(requests,0)
    }
    @MainActor func testUnconfirmedOrForeignReceiptsNeverAcknowledgeEnrollmentOrRevocation() async throws {
        let api=try backend();defer{AutomationHTTP.handler=nil}
        for receipt in [["account":JSON.string(other),"key":.object(row())],["account":.string(owner),"key":.object(row(other))],["account":.string(owner),"key":.object(row(revoked:true))]] {
            let data=try JSONEncoder().encode(receipt);AutomationHTTP.handler={_,transport in transport.finish(data)}
            do{_ = try await api.registerAutomationKey(draft());XCTFail("Unconfirmed key accepted")}catch{}
        }
        let data=try JSONEncoder().encode(["account":JSON.string(owner),"key":.object(row())]);AutomationHTTP.handler={_,transport in transport.finish(data)}
        do{_ = try await api.revokeAutomationKey(id:keyID,account:owner,origin:origin);XCTFail("Non-revoked response accepted")}catch{}
    }
}

extension AutomationAccessTests {
    @MainActor func testLateRegistrationReplyCannotAcknowledgeAnotherAccount() async throws {
        let api = try backend(), draft = try draft(), gate = AutomationGate(), started = expectation(description: "Original registration held")
        let reply = try JSONEncoder().encode(["account": JSON.string(owner), "key": .object(row())])
        AutomationHTTP.handler = { _, transport in gate.hold(transport); started.fulfill() }; defer { AutomationHTTP.handler = nil }
        let creating = Task { @MainActor in try await api.registerAutomationKey(draft) }
        await fulfillment(of: [started], timeout: 3)
        let next = try backend(other)
        try await api.accept(XCTUnwrap(next.session))
        gate.release(reply)
        do { _ = try await creating.value; XCTFail("Late enrollment reached the new account") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(api.session?.user.id, other)
    }
    @MainActor func testOversizedManagementResponseIsBoundedAndUnconfirmed() async throws {
        let api = try backend()
        AutomationHTTP.handler = { _, transport in transport.finish(Data(repeating: 32, count: 256001)) }; defer { AutomationHTTP.handler = nil }
        do { _ = try await api.automationKeyPage(account: owner, origin: origin); XCTFail("Oversized response accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("too large")) }
        XCTAssertEqual(api.session?.user.id, owner)
    }
}

extension AutomationAccessTests {
    @MainActor func testCancellationRequiresMatchingPositiveReceipt() async throws {
        let api = try backend(); defer { AutomationHTTP.handler = nil }
        for receipt: [String: JSON] in [
            ["account": .string(other), "id": .string(keyID), "cancelled": .bool(true)],
            ["account": .string(owner), "id": .string(other), "cancelled": .bool(true)],
            ["account": .string(owner), "id": .string(keyID), "cancelled": .bool(false)],
            ["account": .string(owner), "id": .string(keyID), "cancelled": .string("true")],
            ["account": .string(owner), "id": .string(keyID)]
        ] {
            let reply = try JSONEncoder().encode(receipt)
            AutomationHTTP.handler = { _, transport in transport.finish(reply) }
            do { try await api.cancelAutomationKey(id: keyID, account: owner, origin: origin); XCTFail("Unconfirmed cancellation accepted") } catch { }
        }
        let reply = try JSONEncoder().encode(["account": JSON.string(owner), "id": .string(keyID), "cancelled": .bool(true)])
        AutomationHTTP.handler = { _, transport in transport.finish(reply) }
        try await api.cancelAutomationKey(id: keyID, account: owner, origin: origin)
    }
    @MainActor func testCancellationCannotSendForAnotherAccountOrOrigin() async throws {
        let api = try backend(); var calls = 0
        AutomationHTTP.handler = { _, _ in calls += 1 }; defer { AutomationHTTP.handler = nil }
        for (account, server) in [(other, origin), (owner, "https://foreign.test")] {
            do { try await api.cancelAutomationKey(id: keyID, account: account, origin: server); XCTFail("Foreign cancellation sent") } catch { }
        }
        XCTAssertEqual(calls, 0)
    }
}
