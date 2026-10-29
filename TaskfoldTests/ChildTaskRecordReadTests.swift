import XCTest
@testable import TaskfoldCore

private final class ChildRecordHTTP: URLProtocol {
    private static let handlerLock=NSLock()
    private static var storedHandler:((URLRequest,ChildRecordHTTP)->Void)?
    static var handler:((URLRequest,ChildRecordHTTP)->Void)? {
        get {handlerLock.lock();defer{handlerLock.unlock()};return storedHandler}
        set {handlerLock.lock();storedHandler=newValue;handlerLock.unlock()}
    }
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {Self.handler?(request,self)}
    override func stopLoading() {}
    func finish(_ status:Int,_ data:Data,headers:[String:String]=[:]) {
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:headers)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
}
private final class ChildRecordGate: @unchecked Sendable {
    private let lock=NSLock()
    private var held:ChildRecordHTTP?
    func hold(_ value:ChildRecordHTTP) {lock.lock();held=value;lock.unlock()}
    func release(_ status:Int,_ data:Data) {lock.lock();let value=held;held=nil;lock.unlock();value?.finish(status,data)}
}
final class ChildTaskRecordReadTests: XCTestCase {
    private func fixture() throws -> (String,Record,[String:JSON]) {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"child-task-record-read",withExtension:"json",subdirectory:"Fixtures"))
        let raw=try JSONDecoder().decode([String:JSON].self,from:Data(contentsOf:url))
        return (try XCTUnwrap(raw["account"]?.text),Record(try XCTUnwrap(raw["root"]?.object)),try XCTUnwrap(raw["response"]?.object))
    }
    private func context(_ root:Record,account:String,session:UUID=UUID(),workspace:UUID=UUID(),access:UUID=UUID(),snapshot:UUID=UUID()) throws -> ChildTaskRecordContext {
        try .init(account:account,origin:"https://child-record.test",workspace:workspace,session:session,access:access,snapshot:snapshot,root:root)
    }
    private func decode(_ raw:[String:JSON],_ root:Record,account:String) throws -> ChildTaskRecordRead {
        try .init(data:JSONEncoder().encode(raw),context:context(root,account:account))
    }
    func testActualPostgresEnvelopeReconstructsExactSavedTree() throws {
        let (account,root,raw)=try fixture(),read=try decode(raw,root,account:account)
        XCTAssertTrue(AuthoredValueComparison.exactJSON(read.tree,root["subtasks"]))
        XCTAssertEqual(read.nodes.count,2);XCTAssertEqual(read.nodes["parent"]?.fields["future"],.object(["keep":.array([.null,.bool(false)])]))
        XCTAssertEqual(read.nodes["child"]?.parent,"parent");XCTAssertEqual(read.nodes["child"]?.path,["parent","child"])
    }
    func testResponseArrayOrderDoesNotControlSiblingOrHierarchyOrder() throws {
        let (account,root,original)=try fixture();var raw=original
        raw["records"] = .array(original["records"]!.list.reversed())
        XCTAssertEqual(try decode(raw,root,account:account).tree,root["subtasks"])
    }
    func testEnvelopeBindingAndFutureProtocolFailClosed() throws {
        let (account,root,original)=try fixture()
        for (key,value): (String,JSON) in [("account",.string(UUID().uuidString.lowercased())),("task_id",.string(UUID().uuidString.lowercased())),("project_id",.null),("task_generation",.null),("protocol",.number(2)),("projection_revision",.number(0)),("projection_revision",.number(9_007_199_254_740_992)),("root_kind",.string("future")),("unexpected",.bool(true))] {
            var raw=original;raw[key]=value;XCTAssertThrowsError(try decode(raw,root,account:account),key)
        }
        for key in original.keys {var raw=original;raw.removeValue(forKey:key);XCTAssertThrowsError(try decode(raw,root,account:account),key)}
    }
    func testMalformedNodeIdentityStructureAndCountersAreRefused() throws {
        let (account,root,original)=try fixture()
        let edits:[(String,JSON)]=[("node_key",.string("")),("incarnation",.string("not-a-uuid")),("revision",.number(1.5)),("parent_key",.string("missing")),("sibling_order",.number(-1)),("sibling_order",.number(3)),("identity_path",.array([.string("wrong")])),("children_kind",.string("future")),("fields",.object(["id":.string("wrong")])),("extra",.null)]
        for (key,value) in edits {var raw=original,rows=original["records"]!.list,row=rows[0].object;row[key]=value;rows[0] = .object(row);raw["records"] = .array(rows);XCTAssertThrowsError(try decode(raw,root,account:account),key)}
    }
    func testDuplicateKeysAndIncarnationsAreRefused() throws {
        let (account,root,original)=try fixture();var raw=original
        raw["records"] = .array([original["records"]!.list[0],original["records"]!.list[0]])
        XCTAssertThrowsError(try decode(raw,root,account:account))
        var rows=original["records"]!.list,row=rows[1].object;row["incarnation"]=rows[0].object["incarnation"];rows[1] = .object(row);raw["records"] = .array(rows)
        XCTAssertThrowsError(try decode(raw,root,account:account))
    }
    func testCycleOrDisconnectedChildrenCannotDisappearFromReconstruction() throws {
        let (account,root,original)=try fixture();var raw=original,rows=original["records"]!.list
        for i in rows.indices {var r=rows[i].object;r["parent_key"] = .string(r["node_key"]!.text=="parent" ? "child":"parent");r["children_kind"] = .string("array");rows[i] = .object(r)}
        raw["records"] = .array(rows);XCTAssertThrowsError(try decode(raw,root,account:account))
    }
    func testSourceMismatchNeverOverwritesLocalDraft() throws {
        let (account,original,raw)=try fixture();var root=original;root["subtasks"] = .array([])
        XCTAssertThrowsError(try decode(raw,root,account:account));XCTAssertEqual(root["subtasks"],.array([]))
    }
    func testNullRootAndLegacyGenerationRemainNull() throws {
        let (account,original,raw)=try fixture();var root=original,response=raw
        root["subtasks"] = .null;root["task_generation"] = .null;response["task_generation"] = .null;response["records"] = .array([]);response["root_kind"] = .string("null")
        XCTAssertEqual(try decode(response,root,account:account).tree,.null)
        response["root_kind"] = .string("array");XCTAssertThrowsError(try decode(response,root,account:account))
    }
    func testEmptyArrayAndContainerShapesAreNotInterchangeable() throws {
        let (account,original,raw)=try fixture();var root=original,response=raw
        root["subtasks"] = .array([]);response["records"] = .array([]);XCTAssertEqual(try decode(response,root,account:account).tree,.array([]))
        var rows=raw["records"]!.list;let index=try XCTUnwrap(rows.firstIndex{$0.object["node_key"] == .string("child")})
        var row=rows[index].object;row["children_kind"] = .string("null");rows[index] = .object(row);response=raw;response["records"] = .array(rows)
        XCTAssertThrowsError(try decode(response,original,account:account),"Missing child list cannot silently become null")
    }
    func testBoundedInputAndUnsafeNumbersAreRefused() throws {
        let (account,root,raw)=try fixture(),scope=try context(root,account:account)
        XCTAssertThrowsError(try ChildTaskRecordRead(data:Data(repeating:32,count:2_000_001),context:scope))
        var response=raw,rows=raw["records"]!.list,row=rows[0].object,fields=row["fields"]!.object
        fields["future_number"] = .number(9_007_199_254_740_992);row["fields"] = .object(fields);rows[0] = .object(row);response["records"] = .array(rows)
        XCTAssertThrowsError(try decode(response,root,account:account))
    }
    func testDuplicateAndCanonicallyEquivalentJSONMemberNamesAreRefused() throws {
        let (account,root,raw)=try fixture(),scope=try context(root,account:account)
        let text=String(decoding:try JSONEncoder().encode(raw),as:UTF8.self)
        for injected in ["\"protocol\":1,", "\"é\":1,\"e\\u0301\":2,"] {
            let modified="{"+injected+text.dropFirst()
            XCTAssertThrowsError(try ChildTaskRecordRead(data:Data(modified.utf8),context:scope))
        }
        // These keys are inside supported opaque metadata. Without preflight,
        // Swift dictionaries collapse them and the ordinary tree check passes.
        var response=raw,rows=raw["records"]!.list,changed=root
        let index=try XCTUnwrap(rows.firstIndex{$0.object["node_key"] == .string("parent")})
        var row=rows[index].object,fields=row["fields"]!.object
        fields["future"] = .object(["é":.number(2)]);row["fields"] = .object(fields);rows[index] = .object(row);response["records"] = .array(rows)
        var parent=changed["subtasks"].list[0].object;parent["future"]=fields["future"];changed["subtasks"] = .array([.object(parent)])
        let metadataScope=try context(changed,account:account),clean=try JSONEncoder().encode(response)
        _=try ChildTaskRecordRead(data:clean,context:metadataScope)
        let cleanText=String(decoding:clean,as:UTF8.self)
        let ambiguous=cleanText.replacingOccurrences(of:"\"é\":2",with:"\"é\":2,\"e\\u0301\":2")
        XCTAssertNotEqual(ambiguous,cleanText)
        XCTAssertThrowsError(try ChildTaskRecordRead(data:Data(ambiguous.utf8),context:metadataScope))
    }
    func testContextRejectsEachChangedLeaseAndExactRootField() throws {
        let (account,root,_)=try fixture(),scope=try context(root,account:account)
        XCTAssertTrue(scope.matches(scope))
        let changed=[try context(root,account:account,session:scope.session,workspace:UUID(),access:scope.access,snapshot:scope.snapshot),try context(root,account:account,session:UUID(),workspace:scope.workspace,access:scope.access,snapshot:scope.snapshot),try context(root,account:account,session:scope.session,workspace:scope.workspace,access:UUID(),snapshot:scope.snapshot),try context(root,account:account,session:scope.session,workspace:scope.workspace,access:scope.access,snapshot:UUID())]
        for value in changed {XCTAssertFalse(scope.matches(value))}
        var edited=root;edited["title"] = .string("New local title")
        XCTAssertFalse(scope.matches(try context(edited,account:account,session:scope.session,workspace:scope.workspace,access:scope.access,snapshot:scope.snapshot)))
    }
    @MainActor private func backend(_ account:String) throws -> Backend {
        let session=try JSONDecoder().decode(Session.self,from:Data("{\"access_token\":\"synthetic\",\"refresh_token\":\"synthetic\",\"expires_in\":3600,\"user\":{\"id\":\"\(account)\"}}".utf8))
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ChildRecordHTTP.self]
        return Backend(configuration:["URL":"https://child-record.test","Key":"synthetic-public"],http:URLSession(configuration:config),session:session,persistSession:{_ in})
    }
    @MainActor func testActualBackendPostsScopedBoundedUncachedRead() async throws {
        let (account,root,raw)=try fixture(),api=try backend(account),data=try JSONEncoder().encode(raw)
        ChildRecordHTTP.handler={request,transport in
            XCTAssertEqual(request.url?.path,"/rest/v1/rpc/taskfold_read_child_tasks");XCTAssertEqual(request.httpMethod,"POST")
            XCTAssertEqual(request.value(forHTTPHeaderField:"Cache-Control"),"no-store");XCTAssertFalse(request.httpShouldHandleCookies)
            transport.finish(200,data)
        };defer{ChildRecordHTTP.handler=nil}
        let scope=try context(root,account:account,session:api.reminderSessionIncarnation)
        let value=try await api.childTaskRecords(scope);XCTAssertEqual(value.tree,root["subtasks"])
    }
    @MainActor func testBackendGateAndReviewErrorsDoNotExposeServerDetails() async throws {
        let (account,root,_)=try fixture(),api=try backend(account),scope=try context(root,account:account,session:api.reminderSessionIncarnation)
        defer{ChildRecordHTTP.handler=nil}
        for code in ["PT503","PGRST202","42501","PT409","54000"] {
            ChildRecordHTTP.handler={_,transport in transport.finish(403,Data("{\"code\":\"\(code)\",\"message\":\"private diagnostic\"}".utf8))}
            do{_=try await api.childTaskRecords(scope);XCTFail("Expected refusal")}catch{XCTAssertTrue(error is ChildTaskRecordFailure);XCTAssertFalse(error.localizedDescription.contains("private diagnostic"))}
        }
    }
    @MainActor func testBackendRefusesOversizedDeclaredResponse() async throws {
        let (account,root,_)=try fixture(),api=try backend(account),scope=try context(root,account:account,session:api.reminderSessionIncarnation)
        ChildRecordHTTP.handler={_,transport in transport.finish(200,Data("{}".utf8),headers:["Content-Length":"2000001"])};defer{ChildRecordHTTP.handler=nil}
        do{_=try await api.childTaskRecords(scope);XCTFail("Expected bounded refusal")}catch{XCTAssertTrue(error.localizedDescription.contains("too large"))}
    }
    func testCanonicalNodeKeyPreservesDecomposedOriginalIdentityAndPath() throws {
        let (account,original,base)=try fixture();var root=original,raw=base,rows=base["records"]!.list
        let index=try XCTUnwrap(rows.firstIndex{$0.object["node_key"] == .string("child")})
        var row=rows[index].object,fields=row["fields"]!.object;fields["id"] = .string("e\u{301}")
        row["fields"] = .object(fields);row["node_key"] = .string("é");row["identity_path"] = .array([.string("parent"),.string("e\u{301}")]);rows[index] = .object(row);raw["records"] = .array(rows)
        var parent=root["subtasks"].list[0].object;parent["subtasks"] = .array([.object(fields)]);root["subtasks"] = .array([.object(parent)])
        let value=try decode(raw,root,account:account);XCTAssertTrue(AuthoredValueComparison.exactJSON(value.tree,root["subtasks"]))
        row["node_key"] = .string("e\u{301}");rows[index] = .object(row);raw["records"] = .array(rows)
        XCTAssertThrowsError(try decode(raw,root,account:account),"Address keys must actually be NFC bytes")
    }
    func testOneThousandRowsReconstructInSiblingOrderAndLargerListsRefuse() throws {
        let (account,original,base)=try fixture();var root=original,raw=base,rows:[JSON]=[],fields:[JSON]=[]
        for i in 0..<1000 {
            let item:JSON = .object(["id":.string("node-\(i)"),"title":.string("Task \(i)")]);fields.append(item)
            rows.append(.object(["node_key":.string("node-\(i)"),"incarnation":.string(UUID().uuidString.lowercased()),"revision":.number(1),"parent_key":.null,"sibling_order":.number(Double(i)),"identity_path":.array([.string("node-\(i)")]),"fields":item,"children_kind":.string("absent")]))
        }
        root["subtasks"] = .array(fields);raw["records"] = .array(rows.reversed())
        XCTAssertEqual(try decode(raw,root,account:account).tree,root["subtasks"])
        rows.append(rows[0]);raw["records"] = .array(rows);XCTAssertThrowsError(try decode(raw,root,account:account))
    }
    @MainActor func testHeldSuccessAndRefusalCannotEscapeAnAccountSwitch() async throws {
        let (account,root,raw)=try fixture();defer{ChildRecordHTTP.handler=nil}
        for status in [200,403] {
            let api=try backend(account),scope=try context(root,account:account,session:api.reminderSessionIncarnation),gate=ChildRecordGate(),started=expectation(description:"Child read held \(status)")
            ChildRecordHTTP.handler={_,transport in gate.hold(transport);started.fulfill()}
            let pending=Task{@MainActor in try await api.childTaskRecords(scope)}
            await fulfillment(of:[started],timeout:3)
            let other=try backend(UUID().uuidString.lowercased());api.session=other.session
            gate.release(status,status==200 ? try JSONEncoder().encode(raw):Data("{\"code\":\"PT409\"}".utf8))
            do{_=try await pending.value;XCTFail("Stale read escaped")}catch{XCTAssertTrue(error is CancellationError)}
        }
    }
    @MainActor func testSameAccountNewSignInInvalidatesHeldRead() async throws {
        let (account,root,raw)=try fixture(),api=try backend(account),scope=try context(root,account:account,session:api.reminderSessionIncarnation),gate=ChildRecordGate(),started=expectation(description:"Original sign-in read held")
        let renewed=Data("{\"access_token\":\"renewed-synthetic\",\"refresh_token\":\"synthetic\",\"expires_in\":3600,\"user\":{\"id\":\"\(account)\"}}".utf8)
        ChildRecordHTTP.handler={request,transport in
            if request.url?.path=="/auth/v1/token" {transport.finish(200,renewed)}else{gate.hold(transport);started.fulfill()}
        };defer{ChildRecordHTTP.handler=nil}
        let pending=Task{@MainActor in try await api.childTaskRecords(scope)}
        await fulfillment(of:[started],timeout:3)
        _=try await api.signIn(email:"synthetic@example.invalid",password:"synthetic",signup:false)
        gate.release(200,try JSONEncoder().encode(raw))
        do{_=try await pending.value;XCTFail("Old sign-in accepted") }catch{XCTAssertTrue(error is CancellationError)}
    }

}
