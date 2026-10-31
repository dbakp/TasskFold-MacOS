import XCTest
import CryptoKit
@testable import TaskfoldCore

private final class RepairMemoryIO: CalendarSecureItemIO, @unchecked Sendable {
    private let lock = NSLock(); private var bytes: Data?
    var failWrite = false, failAfterWrite = false
    func read(key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return bytes }
    func write(_ data: Data, key: String) throws { lock.lock(); defer { lock.unlock() }; if failWrite { throw URLError(.cannotWriteToFile) }; bytes = data; if failAfterWrite { throw URLError(.cannotWriteToFile) } }
    func remove(key: String) throws { lock.lock(); defer { lock.unlock() }; bytes = nil }
}
@MainActor private final class RepairServiceDouble: ChildTaskRepairService {
    var raw: [String: JSON], calls: [ChildTaskRepairOperation] = [], loseReply = false
    var callback: (() -> Void)?
    init(_ raw: [String: JSON]) { self.raw = raw }
    func childTaskRepair(_ command: ChildTaskRepairCommand, operation: ChildTaskRepairOperation, session: UUID) async throws -> ChildTaskRepairResult {
        calls.append(operation); callback?(); if loseReply { throw URLError(.networkConnectionLost) }; return try command.result(raw)
    }
}
private final class RepairHTTP: URLProtocol {
    static var handler: ((URLRequest, RepairHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }; override func stopLoading() {}
    func finish(_ status: Int, _ data: Data, headers: [String: String] = [:]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers.merging(["Content-Type":"application/json"], uniquingKeysWith: { a,_ in a }))!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
final class ChildTaskRepairTests: XCTestCase {
    private func verifyTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(value, file: file, line: line) }
    private func verifyFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(value, file: file, line: line) }
    private func verifyEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(a,b,file:file,line:line) }
    private func verifyGreater<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { XCTAssertGreaterThan(a,b,file:file,line:line) }
    private func requestBody(_ request: URLRequest) -> Data {
        if let data=request.httpBody{return data};guard let stream=request.httpBodyStream else{return Data()};stream.open();defer{stream.close()};var result=Data(),buffer=[UInt8](repeating:0,count:4096)
        while stream.hasBytesAvailable{let n=stream.read(&buffer,maxLength:buffer.count);if n<=0{break};result.append(contentsOf:buffer.prefix(n))};return result
    }
    let origin = "https://repair.test"
    func bytes(_ value: [String: JSON]) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(value) }
    func fixture(_ name: String) throws -> Data { try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "child-repair-" + name + "-v1", withExtension: "json", subdirectory: "Fixtures"))) }
    func manifest() throws -> [String: JSON] { try JSONDecoder().decode([String: JSON].self, from: fixture("contract")) }
    func context(session: UUID = UUID()) throws -> ChildTaskRecordContext { let f = try manifest(); return try .init(account: f["account"]!.text, origin: origin, workspace: UUID(), session: session, access: UUID(), snapshot: UUID(), root: Record(f["root"]!.object)) }
    func review(session: UUID = UUID()) throws -> ChildTaskAdoptionReview { try .init(data: fixture("review"), context: context(session: session), workspaceID: nil) }
    func changes() throws -> [ChildTaskRepairChange] { try manifest()["command"]!.object["changes"]!.list.map { try .init(raw: $0.object) } }
    func preview(session: UUID = UUID()) throws -> ChildTaskRepairPreview { try .init(data: fixture("preview"), review: review(session: session), changes: changes()) }
    func command(_ key: String = "command") throws -> ChildTaskRepairCommand { let f = try manifest(); return try .init(account: f["account"]!.text, origin: origin, body: f[key]!.object, nodeCount: f["nodeCount"]!.integer) }
    func result(_ key: String = "receipt", command: ChildTaskRepairCommand? = nil) throws -> ChildTaskRepairResult { try .init(command: command ?? self.command(), data: fixture(key)) }
    func mutatePreview(_ edit: (inout [String: JSON]) -> Void) throws -> Data {
        let p = try ChildTaskRecordRead.separatingJSONFields(["original_tree","proposed_tree"], data: fixture("preview"), maximum: ChildTaskRepairPreview.maximumBytes)
        var raw = try JSONDecoder().decode([String:JSON].self,from:p.metadata); edit(&raw)
        var text = String(decoding: try bytes(raw), as: UTF8.self)
        for field in ["original_tree","proposed_tree"] { text = text.replacingOccurrences(of: "\""+field+"\":null", with: "\""+field+"\":"+String(decoding:p.values[field]!,as:UTF8.self)) }
        return Data(text.utf8)
    }
    func directory() throws -> URL { let d=FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-repair-unit-"+UUID().uuidString);try FileManager.default.createDirectory(at:d,withIntermediateDirectories:true);addTeardownBlock {try? FileManager.default.removeItem(at:d)};return d }
    func journal(_ c: ChildTaskRepairCommand, _ io: any CalendarSecureItemIO, _ d: URL) throws -> ChildTaskRepairJournal { try .init(account:c.account,origin:c.origin,io:io,coordinationDirectory:d.appendingPathComponent("locks"),removalDirectory:d.appendingPathComponent("removal")) }
    @MainActor private func model(_ scope: ChildTaskFieldClientScope,_ journal: ChildTaskRepairJournal,_ service: RepairServiceDouble,current:@escaping()->ChildTaskFieldClientScope?,canSend:@escaping(ChildTaskRepairCommand)->Bool={_ in true},admit:@escaping(ChildTaskRepairCommand)async throws->Void={_ in},reviewCurrent:@escaping(ChildTaskRepairPreview)->Bool={_ in true})->ChildTaskRepairModel { .init(scope:scope,journal:journal,service:service,current:current,canSend:canSend,admit:admit,reviewCurrent:reviewCurrent) }
    @MainActor private func backend() throws -> Backend {
        let f=try manifest(),configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[RepairHTTP.self]
        let s=try JSONDecoder().decode(Session.self,from:bytes(["access_token":.string("synthetic"),"refresh_token":.string("synthetic"),"expires_in":.number(3600),"user":.object(["id":f["account"]!])]))
        return Backend(configuration:["URL":origin,"Key":"synthetic-public"],http:URLSession(configuration:configuration),session:s,persistSession:{_ in})
    }
    func testOwnedSQLFixtureHashesAndExactOpaqueSiblings() throws {
        let f=try manifest();for name in ["review","preview","receipt","closed","unknown","original"] { self.verifyEqual(SHA256.hash(data:try fixture(name)).map{String(format:"%02x",$0)}.joined(),f["hashes"]!.object[name]!.text) }
        let p=try preview();self.verifyTrue(p.eligible);self.verifyTrue(p.valid);self.verifyEqual(p.items.map(\.id),["repaired-reference"])
        for data in [p.original,p.proposed] {let s=String(decoding:data,as:UTF8.self);self.verifyTrue(s.contains("9007199254740993"));self.verifyTrue(s.contains("1"+String(repeating:"0",count:1000)));self.verifyTrue(s.contains("é"));self.verifyTrue(s.contains("e\u{301}"))}
    }
    func testActualPreviewBuildsOnlySmallExactOperationsAndReceipt() throws {
        let c=try command(),p=try preview(),made=try ChildTaskRepairCommand(preview:p,requestID:UUID(uuidString:c.id)!);self.verifyEqual(c,made)
        self.verifyTrue(try result().applied);self.verifyTrue(try result("closed",command:command("closedCommand")).closed);self.verifyTrue(try result("unknown",command:command("unknownCommand")).unknown)
        let data=try JSONEncoder().encode(c);self.verifyEqual(try ChildTaskRepairCommand(data:data),c);XCTAssertLessThan(data.count,2000);self.verifyFalse(String(decoding:data,as:UTF8.self).contains("9007199254740993"));self.verifyFalse(c.debugDescription.contains("repaired-reference"))
    }
    func testOriginalDeliveryMatchesCanonicalArchiveHashAndPreservesAllBytes() throws {
        let c=try command(),r=try result(),value=try ChildTaskRepairOriginal(data:fixture("original"),command:c,result:r)
        self.verifyGreater(value.data.count,16_384);self.verifyEqual(value.data.count,r.raw["archive_bytes"]!.integer)
        self.verifyEqual(SHA256.hash(data:value.data).map{String(format:"%02x",$0)}.joined(),r.raw["archive_digest"]!.text)
        self.verifyTrue(String(decoding:value.data,as:UTF8.self).contains("9007199254740993"));self.verifyFalse(value.description.contains("Keep exact"))
    }
    func testOriginalRejectsChangedContentsHashAndContext() throws {
        let c=try command(),r=try result(),wire=String(decoding:try fixture("original"),as:UTF8.self)
        for pair in [("Keep exact content","Changed text"),("9007199254740993","9007199254740992"),(c.account,UUID().uuidString.lowercased()),(r.raw["archive_digest"]!.text,String(repeating:"0",count:64))] {XCTAssertThrowsError(try ChildTaskRepairOriginal(data:Data(wire.replacingOccurrences(of:pair.0,with:pair.1).utf8),command:c,result:r))}
        XCTAssertThrowsError(try ChildTaskRepairOriginal(data:fixture("original"),command:command("closedCommand"),result:result("closed",command:command("closedCommand"))))
    }
    func testMultipleOpaqueFieldsAllowDistinctUnicodeButRejectDuplicateKeys() throws {
        let good=Data(#"{"original_tree":{"é":1,"e\u0301":1e1000},"proposed_tree":{"é":9007199254740993,"e\u0301":2},"protocol":1}"#.utf8)
        let p=try ChildTaskRecordRead.separatingJSONFields(["original_tree","proposed_tree"],data:good,maximum:1000,integerPaths:[["protocol"]]);self.verifyEqual(p.values.count,2)
        for bad in [#"{"original_tree":{"a":1,"\u0061":2},"proposed_tree":[]}"#,#"{"original_tree":[],"original_tree":[],"proposed_tree":[]}"#,#"{"original_tree":[],"protocol":1,"protocol":1,"proposed_tree":[]}"#,#"{"original_tree":[],"é":1,"e\u0301":2,"proposed_tree":[]}"#,#"{"original_tree":[]}"#] {XCTAssertThrowsError(try ChildTaskRecordRead.separatingJSONFields(["original_tree","proposed_tree"],data:Data(bad.utf8),maximum:1000))}
    }
    func testOpaqueSyntaxAndDepthRemainBounded() throws {
        for value in ["01","1e","NaN","[1,]","{\"a\":1,}"] {XCTAssertThrowsError(try ChildTaskRecordRead.separatingJSONFields(["original_tree","proposed_tree"],data:Data(("{\"original_tree\":"+value+",\"proposed_tree\":[]}").utf8),maximum:3000))}
        let deep="{\"original_tree\":"+String(repeating:"[",count:300)+"null"+String(repeating:"]",count:300)+",\"proposed_tree\":[]}"
        _=try ChildTaskRecordRead.separatingJSONFields(["original_tree","proposed_tree"],data:Data(deep.utf8),maximum:3000)
        let excessive=deep.replacingOccurrences(of:String(repeating:"[",count:300),with:String(repeating:"[",count:513)).replacingOccurrences(of:String(repeating:"]",count:300),with:String(repeating:"]",count:513))
        XCTAssertThrowsError(try ChildTaskRecordRead.separatingJSONFields(["original_tree","proposed_tree"],data:Data(excessive.utf8),maximum:3000))
        XCTAssertThrowsError(try ChildTaskRecordRead.separatingJSONFields(["original_tree","proposed_tree"],data:Data(deep.utf8),maximum:10))
    }
    func testReviewRejectsWrongMetadataChangesCountsAndStepClaims() throws {
        let p=try preview(),r=try review(),changes=try self.changes()
        for pair in [("account",JSON.string(UUID().uuidString.lowercased())),("review_digest",.string(String(repeating:"0",count:64))),("repair_digest",.string("bad")),("node_count",.number(8)),("extra",.bool(true)),("original_sql_null",.bool(true)),("custody_blocker",.string("unknown")),("steps",.array([]))] {XCTAssertThrowsError(try ChildTaskRepairPreview(data:mutatePreview{$0[pair.0]=pair.1},review:r,changes:changes))}
        let other=try ChildTaskRepairChange(.assignReference,path:[0],reference:"different");XCTAssertThrowsError(try ChildTaskRepairPreview(data:fixture("preview"),review:r,changes:[other]))
        self.verifyTrue(ChildTaskRepairPreview.sameJSONValue(p.original,Data(("  "+String(decoding:p.original,as:UTF8.self)+" \n").utf8)))
        self.verifyFalse(ChildTaskRepairPreview.sameJSONValue(Data("\"a b\"".utf8),Data("\"ab\"".utf8)))
    }
    func testUnavailableAndUnresolvedPreviewsCannotBecomeCommands() throws {
        let r=try review(),changes=try self.changes()
        let readOnly=try ChildTaskRepairPreview(data:mutatePreview{$0["mutation_available"] = .bool(false)},review:r,changes:changes);XCTAssertThrowsError(try ChildTaskRepairCommand(preview:readOnly))
        let unresolved=try ChildTaskRepairPreview(data:mutatePreview{$0["mutation_available"] = .bool(false);$0["proposal_valid"] = .bool(false);$0["remaining_issue"] = .string("identity");$0["node_count"] = .null},review:r,changes:changes);self.verifyFalse(unresolved.valid);self.verifyTrue(unresolved.items.isEmpty);XCTAssertThrowsError(try ChildTaskRepairCommand(preview:unresolved))
        XCTAssertThrowsError(try ChildTaskRepairPreview(data:mutatePreview{$0["custody_blocker"] = .string("history_custody")},review:r,changes:changes))
    }
    func testOperationVocabularyAndBounds() throws {
        _=try ChildTaskRepairChange(.makeRootList,path:[]);_=try ChildTaskRepairChange(.makeChildrenList,path:[0,1]);_=try ChildTaskRepairChange(.wrapItem,path:[0],reference:"new",title:"Title");_=try ChildTaskRepairChange(.moveItem,path:[0,0],parent:[],index:1000)
        let invalid:[[String:JSON]]=[[:],["kind":.string("drop"),"path":.array([])],["kind":.string("make_root_list"),"path":.array([.number(0)])],["kind":.string("assign_reference"),"path":.array([]),"reference":.string("x")],["kind":.string("assign_reference"),"path":.array([.number(0.5)]),"reference":.string("x")],["kind":.string("assign_reference"),"path":.array([.number(1000)]),"reference":.string("x")],["kind":.string("assign_reference"),"path":.array([.number(0)]),"reference":.string(""),"extra":.bool(true)]]
        for raw in invalid {XCTAssertThrowsError(try ChildTaskRepairChange(raw:raw))}
        XCTAssertThrowsError(try ChildTaskRepairChange(raw:["kind":.string("assign_reference"),"path":.array([.number(-0.0)]),"reference":.string("new")]))
        XCTAssertThrowsError(try ChildTaskRepairChange(.assignReference,path:Array(repeating:0,count:65),reference:"x"));XCTAssertThrowsError(try ChildTaskRepairChange(.assignReference,path:[0],reference:String(repeating:"é",count:65)))
        XCTAssertThrowsError(try ChildTaskRepairChange(.wrapItem,path:[0],reference:"x",title:" \n\t"));XCTAssertThrowsError(try ChildTaskRepairChange(.wrapItem,path:[0],reference:"x",title:String(repeating:"A",count:501)))
        XCTAssertThrowsError(try ChildTaskRepairChange(.moveItem,path:[0],parent:[0,1],index:0));XCTAssertThrowsError(try ChildTaskRepairChange(.moveItem,path:[0],parent:[],index:-1))
        XCTAssertThrowsError(try ChildTaskRepairChange.validate([]));XCTAssertThrowsError(try ChildTaskRepairChange.validate(Array(repeating:changes()[0],count:65)))
    }
    func testWireCountersCannotRoundOrAcceptFractionalSpelling() throws {
        let p=String(decoding:try fixture("preview"),as:UTF8.self)
        for old in ["\"protocol\": 1","\"node_count\": 1","\"ordinal\": 1"] {for value in ["1.0","1e0","-0","9007199254740993"] {XCTAssertThrowsError(try ChildTaskRepairPreview(data:Data(p.replacingOccurrences(of:old,with:String(old.dropLast())+value).utf8),review:review(),changes:changes()))}}
        let c=try command();var encoded=String(decoding:try JSONEncoder().encode(c),as:UTF8.self);encoded=encoded.replacingOccurrences(of:"\"path\":[0]",with:"\"path\":[0.0]");XCTAssertThrowsError(try ChildTaskRepairCommand(data:Data(encoded.utf8)))
    }
    func testSharedParserChecksWholeIntegerTokensInArrays() throws {
        try ChildTaskRecordRead.validateUniqueJSON(Data("{\"positions\":[0,1,999]}".utf8),maximum:1000,integerPaths:[["positions","[]"]])
        for token in ["0.0","1e0","-0","true","null","{}","[]"] {
            XCTAssertThrowsError(try ChildTaskRecordRead.validateUniqueJSON(Data(("{\"positions\":["+token+"]}").utf8),maximum:1000,integerPaths:[["positions","[]"]]))
        }
    }
    func testReceiptsRejectWrongScopeArchiveAndCompletionClaims() throws {
        let c=try command(),raw=try JSONDecoder().decode([String:JSON].self,from:fixture("receipt"))
        for pair in [("request_id",JSON.string(UUID().uuidString.lowercased())),("project_id",.string(UUID().uuidString.lowercased())),("archive_digest",.string("bad")),("archive_bytes",.number(0)),("node_count",.number(2)),("repair_digest",.string("bad")),("extra",.bool(true))] {var changed=raw;changed[pair.0]=pair.1;XCTAssertThrowsError(try c.result(changed))}
        var closed=raw;closed["state"] = .string("closed");XCTAssertThrowsError(try c.result(closed))
        var unknown=raw;unknown["state"] = .string("unknown");XCTAssertThrowsError(try c.result(unknown))
    }
    func testStoredStateRequiresBoundTerminalProofAndUniquePendingRoot() throws {
        let c=try command(),r=try result(),state=try ChildTaskRepairState(account:c.account,origin:c.origin,entries:[.init(command:c,phase:.applied,result:r)])
        self.verifyEqual(try ChildTaskRepairState(data:JSONEncoder().encode(state)).entries.first?.phase,.applied)
        XCTAssertThrowsError(try ChildTaskRepairState(account:c.account,origin:c.origin,entries:[.init(command:c),.init(command:c)]))
        XCTAssertThrowsError(try ChildTaskRepairState(account:c.account,origin:c.origin,entries:[.init(command:c,phase:.closed,result:r)]))
        let other=try command("unknownCommand");XCTAssertThrowsError(try ChildTaskRepairState(account:c.account,origin:c.origin,entries:[.init(command:c),.init(command:other)]))
    }
    func testJournalRetainsAttemptedIdentityAndImmutableConfirmation() async throws {
        let c=try command(),io=RepairMemoryIO(),j=try journal(c,io,directory()),lease=CalendarReadLease();try await j.enqueue(c,lease:lease)
        _=try await j.attempt(c,lease:lease);do{try await j.discard(c,lease:lease);XCTFail("Attempt needs terminal check/close")}catch{}
        try await j.settle(c,result:result(),lease:lease);let loaded=try await j.load();self.verifyEqual(loaded.entries.first?.phase,.applied)
        var raw=try result().raw;raw["archive_digest"] = .string(String(repeating:"0",count:64));do{try await j.settle(c,result:c.result(raw),lease:lease);XCTFail("Cannot replace settled archive proof")}catch{}
    }
    func testEncryptedFileWrongKeyAndRemovalNeverExposeOrErasePendingData() async throws {
        let c=try command(),d=try directory(),key=SymmetricKey(size:.bits256),io=ReviewedTeamCommandFileIO<ChildTaskRepairState>(directory:d.appendingPathComponent("vault"),account:c.account,origin:c.origin,encryptionKey:{key}),j=try journal(c,io,d),lease=CalendarReadLease()
        try await j.enqueue(c,lease:lease);let encrypted=try Data(contentsOf:io.file);self.verifyFalse(String(decoding:encrypted,as:UTF8.self).contains("repaired-reference"))
        let wrong=ReviewedTeamCommandFileIO<ChildTaskRepairState>(directory:d.appendingPathComponent("vault"),account:c.account,origin:c.origin,encryptionKey:{SymmetricKey(size:.bits256)})
        do{_=try await journal(c,wrong,d).load();XCTFail("Refuse unreadable journal")}catch{};self.verifyEqual(try Data(contentsOf:io.file),encrypted)
        try await j.removeAccount();self.verifyFalse(FileManager.default.fileExists(atPath:io.file.path));try AccountRemovalDisk(directory:d.appendingPathComponent("removal"),account:c.account).removeCache()
        do{try await j.enqueue(c,lease:lease);XCTFail("No resurrection after removal")}catch{}
    }
    @MainActor func testLostReplyColdCheckRecoversOriginalRequestWithoutSendingAgain() async throws {
        let p=try preview(),c=try command(),scope=ChildTaskFieldClientScope(p.context),io=RepairMemoryIO(),d=try directory(),j=try journal(c,io,d),service=RepairServiceDouble(try result().raw),m=model(scope,j,service,current:{scope})
        self.verifyTrue(await m.queue(c,review:p));service.loseReply=true;self.verifyFalse(await m.run(c,operation:.send));self.verifyEqual(m.entries.first?.phase,.attempted);m.close();service.loseReply=false
        let cold=model(scope,try journal(c,io,d),service,current:{scope},canSend:{_ in false});await cold.load();self.verifyTrue(await cold.run(c,operation:.check));self.verifyEqual(cold.entries.first?.phase,.applied);self.verifyEqual(service.calls,[.send,.check]);self.verifyEqual(cold.entries.first?.command,c)
    }
    @MainActor func testDurableAdmissionFailurePreventsAnyNetworkCall() async throws {
        let p=try preview(),c=try command(),scope=ChildTaskFieldClientScope(p.context),io=RepairMemoryIO(),service=RepairServiceDouble(try result().raw),m=model(scope,try journal(c,io,directory()),service,current:{scope},admit:{_ in throw ChildTaskRepairCommand.invalid})
        self.verifyFalse(await m.queue(c,review:p));self.verifyTrue(service.calls.isEmpty);self.verifyTrue(m.entries.isEmpty)
    }
    @MainActor func testWriteFailureBeforeAttemptCannotSend() async throws {
        let p=try preview(),c=try command(),scope=ChildTaskFieldClientScope(p.context),io=RepairMemoryIO(),service=RepairServiceDouble(try result().raw),m=model(scope,try journal(c,io,directory()),service,current:{scope})
        self.verifyTrue(await m.queue(c,review:p));io.failWrite=true;self.verifyFalse(await m.run(c,operation:.send));self.verifyTrue(service.calls.isEmpty);self.verifyEqual(m.entries.first?.phase,.queued)
    }
    @MainActor func testAfterWriteFailureTrustsOnlyReloadedTerminalProof() async throws {
        let p=try preview(),c=try command(),scope=ChildTaskFieldClientScope(p.context),io=RepairMemoryIO(),service=RepairServiceDouble(try result().raw),m=model(scope,try journal(c,io,directory()),service,current:{scope})
        self.verifyTrue(await m.queue(c,review:p));service.callback={io.failAfterWrite=true};self.verifyTrue(await m.run(c,operation:.send));self.verifyEqual(m.entries.first?.phase,.applied);self.verifyEqual(service.calls,[.send])
    }
    @MainActor func testAccountChangeSuppressesLateReplyAndKeepsAttemptedRecovery() async throws {
        let p=try preview(),c=try command(),scope=ChildTaskFieldClientScope(p.context),io=RepairMemoryIO(),d=try directory(),j=try journal(c,io,d),service=RepairServiceDouble(try result().raw);var current:ChildTaskFieldClientScope?=scope
        let m=model(scope,j,service,current:{current});self.verifyTrue(await m.queue(c,review:p));service.callback={current=nil};self.verifyFalse(await m.run(c,operation:.send));self.verifyTrue(m.entries.isEmpty);self.verifyEqual(try await j.load().entries.first?.phase,.attempted)
    }
    @MainActor func testCheckAndCloseNeedNoCurrentSendPermission() async throws {
        let p=try preview(),c=try command("closedCommand"),scope=ChildTaskFieldClientScope(p.context),io=RepairMemoryIO(),service=RepairServiceDouble(try result("closed",command:c).raw),m=model(scope,try journal(c,io,directory()),service,current:{scope},canSend:{_ in false})
        self.verifyTrue(await m.queue(c,review:p));self.verifyFalse(await m.run(c,operation:.send));self.verifyTrue(await m.run(c,operation:.close));self.verifyEqual(m.entries.first?.phase,.closed);self.verifyEqual(service.calls,[.close])
    }
    @MainActor func testUnknownCheckKeepsOriginalPendingUntilClosed() async throws {
        let p=try preview(),c=try command("unknownCommand"),scope=ChildTaskFieldClientScope(p.context),io=RepairMemoryIO(),service=RepairServiceDouble(try result("unknown",command:c).raw),m=model(scope,try journal(c,io,directory()),service,current:{scope},canSend:{_ in false})
        self.verifyTrue(await m.queue(c,review:p));self.verifyTrue(await m.run(c,operation:.check));self.verifyEqual(m.entries.first?.phase,.attempted);self.verifyTrue(m.entries.first?.result == nil)
        var closed=try result("closed",command:command("closedCommand")).raw;closed["request_id"] = .string(c.id);service.raw=closed
        self.verifyTrue(await m.run(c,operation:.close));self.verifyEqual(m.entries.first?.phase,.closed);self.verifyEqual(service.calls,[.check,.close]);self.verifyEqual(m.entries.first?.command,c)
    }
    @MainActor func testBackendPreviewRepairOriginalRoutesUsePrivateExactRequests() async throws {
        let api=try backend(),c=try command(),r=try result(),review=try self.review(session:api.reminderSessionIncarnation);var paths:[String]=[]
        RepairHTTP.handler={request,peer in
            paths.append(request.url!.path);self.verifyEqual(request.timeoutInterval,25);self.verifyFalse(request.httpShouldHandleCookies);self.verifyEqual(request.value(forHTTPHeaderField:"Cache-Control"),"no-store")
            let b=try! JSONDecoder().decode([String:JSON].self,from:self.requestBody(request));let op=b["_operation"]?.text
            if request.url!.path.hasSuffix("taskfold_preview_child_repair") {peer.finish(200,try! self.fixture("preview"))}
            else {self.verifyTrue(ChildTaskStructureCommand.exact(b["_body"],.object(c.body)));peer.finish(200,try! self.fixture(op == "original" ? "original" : "receipt"))}
        };defer{RepairHTTP.handler=nil}
        self.verifyTrue(try await api.childTaskRepairPreview(review,changes:changes()).eligible)
        for op in [ChildTaskRepairOperation.send,.check,.close] {_=try await api.childTaskRepair(c,operation:op,session:api.reminderSessionIncarnation)}
        self.verifyGreater(try await api.childTaskRepairOriginal(c,result:r,session:api.reminderSessionIncarnation).data.count,16_384);self.verifyEqual(paths.count,5)
    }
    @MainActor func testBackendRejectsStaleSessionBeforeRequestAndLateSuccess() async throws {
        let api=try backend(),c=try command(),old=api.reminderSessionIncarnation;try await api.clearSession();var calls=0
        RepairHTTP.handler={_,_ in calls+=1};defer{RepairHTTP.handler=nil};do{_=try await api.childTaskRepair(c,operation:.check,session:old);XCTFail("Stale session")}catch{self.verifyTrue(error is CancellationError)};self.verifyEqual(calls,0)
        let live=try backend(),generation=live.reminderSessionIncarnation;RepairHTTP.handler={_,peer in Task{@MainActor in try await live.clearSession();peer.finish(200,try self.fixture("receipt"))}}
        do{_=try await live.childTaskRepair(c,operation:.send,session:generation);XCTFail("Late account response")}catch{self.verifyTrue(error is CancellationError)}
    }
    @MainActor func testBackendSanitizesLimitsAndUnknownDecision() async throws {
        let api=try backend(),c=try command();defer{RepairHTTP.handler=nil}
        for code in ["PT413","PT429","PT409","55P03","42501"] {RepairHTTP.handler={_,peer in peer.finish(409,try! self.bytes(["code":.string(code),"message":.string("Private source text")]))};do{_=try await api.childTaskRepair(c,operation:.send,session:api.reminderSessionIncarnation);XCTFail("Refuse error")}catch{self.verifyTrue(error is ChildTaskRepairFailure);self.verifyFalse(error.localizedDescription.contains("Private source text"))}}
        RepairHTTP.handler={_,peer in peer.finish(200,try! self.bytes(["protocol":.number(1),"account":.string(c.account),"request_id":.string(c.id),"state":.string("unknown")]))};do{_=try await api.childTaskRepair(c,operation:.send,session:api.reminderSessionIncarnation);XCTFail("Unknown cannot certify send")}catch{self.verifyTrue(error is ChildTaskRepairFailure)}
        RepairHTTP.handler={_,peer in peer.finish(200,Data(repeating:32,count:16_385))};do{_=try await api.childTaskRepair(c,operation:.check,session:api.reminderSessionIncarnation);XCTFail("Bound streamed receipt without declared length")}catch{guard let e=error as? ChildTaskRepairFailure else{return XCTFail("Repair failure required")};if case .limit=e.reason{}else{XCTFail("Size limit")}}
        RepairHTTP.handler={_,peer in peer.finish(200,Data(),headers:["Content-Length":"4300001"])};do{_=try await api.childTaskRepairPreview(review(session:api.reminderSessionIncarnation),changes:changes());XCTFail("Declared oversized preview")}catch{guard let e=error as? ChildTaskRepairFailure else{return XCTFail("Repair failure required")};if case .limit=e.reason{}else{XCTFail("Size limit")}}
        RepairHTTP.handler={_,peer in peer.finish(200,Data(),headers:["Content-Length":"8100001"])};do{_=try await api.childTaskRepairOriginal(c,result:result(),session:api.reminderSessionIncarnation);XCTFail("Declared oversized original")}catch{guard let e=error as? ChildTaskRepairFailure else{return XCTFail("Repair failure required")};if case .limit=e.reason{}else{XCTFail("Size limit")}}
    }
    func testRepairOutlineUsesPositionsAndMarksDuplicateCanonicalReferences() throws {
        let raw = Data(#"[{"id":"é","title":"  First\n task ","subtasks":[{"id":"ok","title":"Child"}]},{"id":"e\u0301","title":"Second"},{"id":7,"subtasks":"keep this"}]"#.utf8)
        let outline = try ChildTaskRepairOutline(data: raw)
        XCTAssertEqual(outline.items.map(\.id), ["0","0.0","1","2"])
        XCTAssertEqual(outline.items.map(\.referenceNeedsRepair), [true,false,true,true])
        XCTAssertEqual(outline.items.map(\.malformedChildren), [false,false,false,true])
        XCTAssertEqual(outline.items[0].title,"First task")
        XCTAssertEqual(outline.items.map(\.siblings),[3,1,3,3])
    }
    func testRepairOutlineClassifiesOpaqueScalarsWithoutNumericConversion() throws {
        let data = Data(#"[1e1000,9007199254740993,true,null,[{"opaque":"kept"}],"Keep this note"]"#.utf8)
        let outline = try ChildTaskRepairOutline(data: data)
        XCTAssertEqual(outline.items.map(\.kind),[.number,.number,.boolean,.null,.array,.string])
        XCTAssertEqual(outline.items.last?.title,"Keep this note")
        XCTAssertEqual(outline.rootCount,6)
    }
    func testRepairOutlineBoundsLabelsAndDoesNotEnumerateUnknownContents() throws {
        let title=String(repeating:"🪴",count:200)
        let raw=try JSONSerialization.data(withJSONObject:[["id":"safe","title":title,"opaque":["nested":["id":7]],"subtasks":NSNull()]])
        let outline=try ChildTaskRepairOutline(data:raw)
        XCTAssertEqual(outline.items.count,1);XCTAssertEqual(outline.items[0].title.unicodeScalars.count,160)
        XCTAssertFalse(outline.items[0].referenceNeedsRepair);XCTAssertFalse(outline.items[0].malformedChildren)
    }
    func testRepairOutlineRefusesWholeOverLimitTreeInsteadOfPartialItems() throws {
        let row="{\"id\":\"ok\"}"
        XCTAssertEqual(try ChildTaskRepairOutline(data:Data(("["+Array(repeating:row,count:1000).joined(separator:",")+"]").utf8)).items.count,1000)
        XCTAssertThrowsError(try ChildTaskRepairOutline(data:Data(("["+Array(repeating:row,count:1001).joined(separator:",")+"]").utf8)))
        var nested=row
        for _ in 0..<64 { nested="{\"id\":\"nested\",\"subtasks\":["+nested+"]}" }
        XCTAssertThrowsError(try ChildTaskRepairOutline(data:Data(("["+nested+"]").utf8)))
    }
    func testRepairOutlineRecognizesRootShapeAndRejectsMalformedInput() throws {
        for (text,kind) in [("null",ChildTaskRepairOutline.Kind.null),("{}",.object),("1e1000",.number),("[]",.array)] {
            let outline=try ChildTaskRepairOutline(data:Data(text.utf8));XCTAssertEqual(outline.rootKind,kind);XCTAssertTrue(outline.items.isEmpty)
        }
        for raw in ["[1,]","{broken}","[NaN]","[01]"] { XCTAssertThrowsError(try ChildTaskRepairOutline(data:Data(raw.utf8))) }
    }

}

extension ChildTaskRepairTests {
    func savedDraft() throws -> ChildTaskRepairDraft {
        try .init(review: review(), changes: changes(), labels: changes().map { _ in "Repair older task" })
    }
    func testSavedReviewRoundTripRequiresExactOriginalAndNeverStoresOpaqueTree() throws {
        let draft = try savedDraft(), c = try command()
        let state = try ChildTaskRepairState(account: c.account, origin: c.origin, drafts: [draft])
        let data = try JSONEncoder().encode(state), cold = try ChildTaskRepairState(data: data)
        XCTAssertEqual(cold.drafts, [draft]); XCTAssertTrue(draft.matches(try review()))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("9007199254740993")); XCTAssertFalse(text.contains("original_tree")); XCTAssertFalse(draft.debugDescription.contains(c.rootID))
        var identity = draft.identity; identity["task_generation"] = .string(UUID().uuidString.lowercased())
        let recreated = try ChildTaskRepairDraft(account: draft.account, origin: draft.origin, identity: identity, changes: draft.changes, labels: draft.labels)
        XCTAssertFalse(recreated.matches(try review()))
        identity = draft.identity; identity["review_digest"] = .string(String(repeating: "0", count: 64))
        XCTAssertFalse(try ChildTaskRepairDraft(account: draft.account, origin: draft.origin, identity: identity, changes: draft.changes, labels: draft.labels).matches(review()))
        let older = try ChildTaskRepairState(account: c.account, origin: c.origin, entries: [.init(command: c)])
        XCTAssertTrue(try ChildTaskRepairState(data: JSONEncoder().encode(older)).drafts.isEmpty)
        XCTAssertThrowsError(try ChildTaskRepairState(account: c.account, origin: c.origin, entries: [.init(command: c)], drafts: [draft]))
        XCTAssertThrowsError(try ChildTaskRepairState(account: c.account, origin: c.origin, drafts: [draft, draft]))
    }
    func testTwoWindowsCannotOverwriteOrDiscardNewerSavedReview() async throws {
        let first = try savedDraft(), c = try command(), io = RepairMemoryIO(), d = try directory(), one = try journal(c, io, d), two = try journal(c, io, d), lease = CalendarReadLease()
        try await one.saveDraft(first, rootID: first.rootID, expected: nil, lease: lease)
        let newer = try savedDraft(); try await two.saveDraft(newer, rootID: first.rootID, expected: first.token, lease: lease)
        let bytes = try io.read(key: "synthetic")
        do { try await one.saveDraft(first, rootID: first.rootID, expected: first.token, lease: lease); XCTFail("Stale window overwrote newer choices") } catch {}
        do { try await one.saveDraft(nil, rootID: first.rootID, expected: first.token, lease: lease); XCTFail("Stale window discarded newer choices") } catch {}
        XCTAssertEqual(try io.read(key: "synthetic"), bytes)
        let cold = try await one.load(); XCTAssertEqual(cold.drafts, [newer])
    }
    func testQueueAtomicallyConsumesOnlyTheReviewedDraft() async throws {
        let draft = try savedDraft(), c = try command(), io = RepairMemoryIO(), j = try journal(c, io, directory()), lease = CalendarReadLease()
        try await j.saveDraft(draft, rootID: draft.rootID, expected: nil, lease: lease)
        do { try await j.enqueue(c, lease: lease); XCTFail("Must bind the reviewed draft") } catch {}
        var state = try await j.load(); XCTAssertEqual(state.drafts, [draft]); XCTAssertTrue(state.entries.isEmpty)
        try await j.enqueue(c, lease: lease, draftToken: draft.token)
        state = try await j.load(); XCTAssertTrue(state.drafts.isEmpty); XCTAssertEqual(state.entries.first?.command, c)
        do { try await j.saveDraft(draft, rootID: draft.rootID, expected: nil, lease: lease); XCTFail("Cannot reintroduce draft beside queued mutation") } catch {}
    }
    func testSavedDraftEncryptedColdReturnWrongKeyAndAccountRemoval() async throws {
        let c = try command(), draft = try savedDraft(), d = try directory(), key = SymmetricKey(size: .bits256)
        let io = ReviewedTeamCommandFileIO<ChildTaskRepairState>(directory: d.appendingPathComponent("vault"), account: c.account, origin: c.origin, encryptionKey: { key }), j = try journal(c, io, d), lease = CalendarReadLease()
        try await j.saveDraft(draft, rootID: draft.rootID, expected: nil, lease: lease)
        let bytes = try Data(contentsOf: io.file); XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("Repair older task"))
        let cold = try await journal(c, io, d).load(); XCTAssertEqual(cold.drafts, [draft])
        let wrong = ReviewedTeamCommandFileIO<ChildTaskRepairState>(directory: d.appendingPathComponent("vault"), account: c.account, origin: c.origin, encryptionKey: { SymmetricKey(size: .bits256) })
        do { try await journal(c, wrong, d).saveDraft(nil, rootID: draft.rootID, expected: draft.token, lease: lease); XCTFail("Wrong key discarded draft") } catch {}
        XCTAssertEqual(try Data(contentsOf: io.file), bytes)
        lease.cancel(); do { try await j.saveDraft(nil, rootID: draft.rootID, expected: draft.token, lease: lease); XCTFail("Cancelled lease changed draft") } catch {}
        XCTAssertEqual(try Data(contentsOf: io.file), bytes)
        try await j.removeAccount(); XCTAssertFalse(FileManager.default.fileExists(atPath: io.file.path))
    }
    @MainActor func testSavedDraftSurvivesModelCloseWithoutSendingAndScopeChangeHidesIt() async throws {
        let p = try preview(), c = try command(), scope = ChildTaskFieldClientScope(p.context), io = RepairMemoryIO(), d = try directory(), service = RepairServiceDouble(try result().raw), draft = try savedDraft()
        var current: ChildTaskFieldClientScope? = scope
        let first = model(scope, try journal(c, io, d), service, current: { current })
        verifyTrue(await first.saveDraft(draft, rootID: c.rootID, expected: nil)); first.close(); XCTAssertTrue(first.drafts.isEmpty)
        let cold = model(scope, try journal(c, io, d), service, current: { current }); await cold.load(); XCTAssertEqual(cold.drafts, [draft]); XCTAssertTrue(service.calls.isEmpty)
        current = nil; verifyFalse(await cold.saveDraft(nil, rootID: c.rootID, expected: draft.token)); XCTAssertTrue(cold.drafts.isEmpty)
        let saved = try await journal(c, io, d).load(); XCTAssertEqual(saved.drafts, [draft])
    }
    @MainActor func testSavedDraftWriteFailureKeepsPreviousChoicesAndAfterWriteReloadsProof() async throws {
        let p = try preview(), c = try command(), scope = ChildTaskFieldClientScope(p.context), io = RepairMemoryIO(), service = RepairServiceDouble(try result().raw), m = model(scope, try journal(c, io, directory()), service, current: { scope }), first = try savedDraft()
        verifyTrue(await m.saveDraft(first, rootID: c.rootID, expected: nil)); io.failWrite = true
        verifyFalse(await m.saveDraft(try savedDraft(), rootID: c.rootID, expected: first.token)); XCTAssertEqual(m.drafts, [first])
        io.failWrite = false; io.failAfterWrite = true; let second = try savedDraft()
        verifyTrue(await m.saveDraft(second, rootID: c.rootID, expected: first.token)); XCTAssertEqual(m.drafts, [second]); XCTAssertTrue(service.calls.isEmpty)
    }
    func testRepairCommandLifecyclePreservesAnotherTasksDraftAndRefusesMalformedSavedChoices() async throws {
        let c = try command(), first = try savedDraft(), io = RepairMemoryIO(), j = try journal(c, io, directory()), lease = CalendarReadLease()
        var identity = first.identity; identity["task_id"] = .string(UUID().uuidString.lowercased())
        let other = try ChildTaskRepairDraft(account: first.account, origin: first.origin, identity: identity, changes: first.changes, labels: first.labels)
        try await j.saveDraft(other, rootID: other.rootID, expected: nil, lease: lease)
        try await j.enqueue(c, lease: lease); _ = try await j.attempt(c, lease: lease); try await j.settle(c, result: result(), lease: lease); try await j.discard(c, lease: lease)
        let state = try await j.load(); XCTAssertEqual(state.drafts, [other]); XCTAssertTrue(state.entries.isEmpty)
        let raw = try JSONEncoder().encode(state), wire = String(decoding: raw, as: UTF8.self)
        XCTAssertThrowsError(try ChildTaskRepairState(data: Data(wire.replacingOccurrences(of: "\"path\":[0]", with: "\"path\":[0.0]").utf8)))
        var fields = try JSONDecoder().decode([String: JSON].self, from: raw); fields["drafts"] = .null
        XCTAssertThrowsError(try ChildTaskRepairState(data: JSONEncoder().encode(fields)))
    }

}
