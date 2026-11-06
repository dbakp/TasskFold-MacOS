import XCTest
@testable import TaskfoldCore

private final class CopyReviewHTTP: URLProtocol {
    static var handler: ((URLRequest, CopyReviewHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func finish(_ status: Int, _ data: Data, headers: [String:String] = [:]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
final class ChildTaskCopyReviewTests: XCTestCase {
    let origin = "https://copies.test"
    func fixture(_ name: String) throws -> Data { try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "child-copy-" + name + "-v1", withExtension: "json", subdirectory: "Fixtures"))) }
    func manifest() throws -> [String:JSON] { try TaskfoldJSONDecoder().decode([String:JSON].self, from: fixture("review")) }
    func encode(_ value: JSON) throws -> Data { let e=TaskfoldJSONEncoder();e.outputFormatting = [.sortedKeys];return try e.encode(value) }
    func ordinary() throws -> [String:JSON] { try manifest()["ordinary"]!.object }
    func context(_ value: [String:JSON], session: UUID = UUID()) throws -> ChildTaskRecordContext {
        try .init(account: value["account"]!.text, origin: origin, workspace: UUID(), session: session, access: UUID(), snapshot: UUID(), root: Record(value["root"]!.object))
    }
    func review(session: UUID = UUID()) throws -> ChildTaskAdoptionReview {
        let f=try ordinary();return try .init(data: encode(f["review"]!), context: context(["account":f["body"]!.object["account"]!,"root":f["root"]!],session:session), workspaceID:nil)
    }
    func reply() throws -> Data { try encode(ordinary()["reply"]!) }
    func mutate(_ change: (inout [String:JSON])->Void) throws -> Data { var r=try ordinary()["reply"]!.object;change(&r);return try encode(.object(r)) }
    func testRealSQLDiscrepancyShowsSeparateCopiesAndExactExport() throws {
        let value=try ChildTaskCopyReview(data:reply(),review:review())
        XCTAssertEqual(value.metadata["state"],.string("different"));XCTAssertEqual(value.copies.map(\.id),["task","projection","records"])
        XCTAssertNotEqual(value.copies[0].items.first?.notes,value.copies[2].items.first?.notes)
        XCTAssertEqual(value.copies.map(\.count),[1,1,1]);XCTAssertTrue(value.omitted.isEmpty)
        XCTAssertEqual(value.description,"Private saved-copy comparison");XCTAssertEqual(value.description,value.debugDescription)
        let bundle=try TaskfoldJSONDecoder().decode([String:JSON].self,from:value.exportBundle)
        XCTAssertTrue(ChildTaskStructureCommand.exact(bundle["root"],try ordinary()["root"]))
        XCTAssertEqual(Set(ChildTaskCopyReview.body(try review()).keys),ChildTaskCopyReview.fields)
    }
    func testOpaqueActualSQLRepliesRetainNumbersAndDistinctUnicodeKeys() throws {
        let context=try context(manifest()["opaque"]!.object)
        func value(_ name:String) throws -> Data { try XCTUnwrap(ChildTaskRecordRead.separatingJSONFields(["value"],data:fixture(name),maximum:14_300_000,integerPaths:[],nullableIntegerPaths:[]).values["value"]) }
        let r=try ChildTaskAdoptionReview(data:value("opaque-review"),context:context,workspaceID:nil)
        let compared=try ChildTaskCopyReview(data:value("opaque-reply"),review:r)
        for bytes in [compared.exportBundle] + compared.copies.map(\.tree) {
            let text=String(decoding:bytes,as:UTF8.self)
            XCTAssertTrue(text.contains("9007199254740993"));XCTAssertTrue(text.contains("1"+String(repeating:"0",count:1000)))
            XCTAssertTrue(text.contains("é"));XCTAssertTrue(text.contains("e\u{301}"))
        }
        XCTAssertEqual(compared.copies[0].items.count,1)
    }
    func testRejectsWrongContextSchemaDigestAndFalseAgreement() throws {
        let r=try review()
        for field in ["account","task_id","task_generation","project_id","review_digest","copy_digest"] {
            XCTAssertThrowsError(try ChildTaskCopyReview(data:mutate{$0[field] = .string("invalid")},review:r),field)
        }
        XCTAssertThrowsError(try ChildTaskCopyReview(data:mutate{$0["extra"] = .bool(true)},review:r))
        XCTAssertThrowsError(try ChildTaskCopyReview(data:mutate{$0.removeValue(forKey:"copies")},review:r))
        XCTAssertThrowsError(try ChildTaskCopyReview(data:mutate{$0["state"] = .string("aligned")},review:r))
        XCTAssertThrowsError(try ChildTaskCopyReview(data:mutate{$0["task_tree"] = .array([])},review:r))
        XCTAssertThrowsError(try ChildTaskCopyReview(data:Data(repeating:32,count:ChildTaskCopyReview.maximumBytes+1),review:r))
    }
    func testRejectsForeignExportAndUnexpectedPrivateCopyData() throws {
        let r=try review()
        for key in ["root","projection","authority"] {
            XCTAssertThrowsError(try ChildTaskCopyReview(data:mutate { value in
                var b=value["export_bundle"]!.object,v=b[key]!.object;v[key == "root" ? "id" : "task_id"] = .string(UUID().uuidString.lowercased());b[key] = .object(v);value["export_bundle"] = .object(b)
            },review:r),key)
        }
        XCTAssertThrowsError(try ChildTaskCopyReview(data:mutate { value in
            var b=value["export_bundle"]!.object;guard case .array(var rows)=b["records"] else{return};var row=rows[0].object;row["task_id"] = .string(UUID().uuidString.lowercased());rows[0] = .object(row);b["records"] = .array(rows);value["export_bundle"] = .object(b)
        },review:r))
        XCTAssertThrowsError(try ChildTaskCopyReview(data:mutate { value in
            guard case .array(var rows)=value["copies"] else{return};var row=rows[2].object;row["state"] = .string("unavailable");row["issue"] = .string("access_review");for k in ["node_count","max_depth","bytes"]{row[k] = .null};rows[2] = .object(row);value["copies"] = .array(rows)
        },review:r))
    }
    func testRejectsCountDepthAndWireCounterSpelling() throws {
        let r=try review()
        for key in ["node_count","max_depth","bytes"] {
            XCTAssertThrowsError(try ChildTaskCopyReview(data:mutate { value in
                guard case .array(var rows)=value["copies"] else{return};var row=rows[0].object;row[key] = .number(-1);rows[0] = .object(row);value["copies"] = .array(rows)
            },review:r))
        }
        let text=String(decoding:try reply(),as:UTF8.self)
        for n in ["1.0","1e0","-0","9007199254740993"] {
            XCTAssertThrowsError(try ChildTaskCopyReview(data:Data(text.replacingOccurrences(of:"\"node_count\":1",with:"\"node_count\":"+n).utf8),review:r))
        }
    }
    @MainActor func backend() throws -> Backend {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[CopyReviewHTTP.self]
        let s=try TaskfoldJSONDecoder().decode(Session.self,from:encode(.object(["access_token":.string("synthetic"),"refresh_token":.string("synthetic"),"expires_in":.number(3600),"user":.object(["id":try ordinary()["body"]!.object["account"]!])])))
        return Backend(configuration:["URL":origin,"Key":"synthetic-public"],http:URLSession(configuration:config),session:s,persistSession:{_ in})
    }
    @MainActor func testPrivateHTTPRouteAndSessionCancellation() async throws {
        let api=try backend(),r=try review(session:api.reminderSessionIncarnation),data=try reply();var calls=0
        CopyReviewHTTP.handler={request,peer in
            calls+=1;XCTAssertEqual(request.url?.path,"/rest/v1/rpc/taskfold_review_child_copies");XCTAssertEqual(request.httpMethod,"POST")
            XCTAssertFalse(request.httpShouldHandleCookies);XCTAssertEqual(request.cachePolicy,.reloadIgnoringLocalCacheData);XCTAssertEqual(request.value(forHTTPHeaderField:"Cache-Control"),"no-store");peer.finish(200,data)
        };defer{CopyReviewHTTP.handler=nil}
        let value=try await api.childTaskCopyReview(r);XCTAssertEqual(value.copies.count,3);XCTAssertEqual(calls,1)
        try await api.clearSession()
        do{_=try await api.childTaskCopyReview(r);XCTFail("Old session accepted")}catch{XCTAssertTrue(error is CancellationError)}
        XCTAssertEqual(calls,1)
    }
    @MainActor func testLateReplyAfterAccountSessionEndsIsDiscarded() async throws {
        let api=try backend(),r=try review(session:api.reminderSessionIncarnation),data=try reply()
        CopyReviewHTTP.handler={_,peer in Task{@MainActor in try await api.clearSession();peer.finish(200,data)}}
        defer{CopyReviewHTTP.handler=nil}
        do{_=try await api.childTaskCopyReview(r);XCTFail("Late private reply accepted")}catch{XCTAssertTrue(error is CancellationError)}
    }
    @MainActor func testHTTPResponseLimitAndRevokedSession() async throws {
        let api=try backend(),r=try review(session:api.reminderSessionIncarnation)
        defer{CopyReviewHTTP.handler=nil}
        CopyReviewHTTP.handler={_,peer in peer.finish(200,Data(),headers:["Content-Length":String(ChildTaskCopyReview.maximumBytes+1)])}
        do{_=try await api.childTaskCopyReview(r);XCTFail("Oversize accepted")}catch{XCTAssertTrue(error is ChildTaskRepairFailure)}
        CopyReviewHTTP.handler={_,peer in peer.finish(400,Data("{\"code\":\"28000\",\"message\":\"expired\"}".utf8))}
        do{_=try await api.childTaskCopyReview(r);XCTFail("Expired accepted")}catch{XCTAssertTrue(error is AccountSessionAuthorizationRequired)}
    }
}
