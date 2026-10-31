import XCTest
@testable import TaskfoldCore

private final class RootReadHTTP: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, RootReadHTTP) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func finish(_ status: Int, _ data: Data, headers: [String: String] = [:]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
final class CompletionSelectionRootReadTests: XCTestCase {
    private let origin = "https://root-read.test"
    private func data() throws -> Data { try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "completion-selection-root-observations", withExtension: "json", subdirectory: "Fixtures"))) }
    private func raw() throws -> [String: JSON] { try TaskfoldJSONDecoder().decode([String: JSON].self, from: data()) }
    private func scope() throws -> ChildTaskFieldClientScope { .init(account: try raw()["account"]!.text, origin: origin, workspace: UUID(), session: UUID(), access: UUID()) }
    private func ids(_ value: [String: JSON]) -> [String] { value["roots"]!.list.map { $0.object["task"]!.object["id"]!.text } }
    private func read(_ value: [String: JSON]? = nil, scope: ChildTaskFieldClientScope? = nil) throws -> CompletionSelectionRootRead {
        let value = try value ?? raw(); return try .init(data: TaskfoldJSONEncoder().encode(value), taskIDs: ids(try raw()), scope: try scope ?? self.scope())
    }
    private func projects(_ tasks: [Record]) -> [Record] { Set(tasks.map { $0.string("project_id") }.filter { !$0.isEmpty }).map { Record(["id": .string($0), "is_archived": .bool(false)]) } }
    private func mutateTask(_ raw: [String: JSON], _ action: (inout [String: JSON]) -> Void) -> [String: JSON] {
        var raw = raw, values = raw["roots"]!.list, row = values[0].object, task = row["task"]!.object
        action(&task); row["task"] = .object(task); values[0] = .object(row); raw["roots"] = .array(values); return raw
    }
    func testActualPostgresWireRetainsOrderScopeAndFieldOnlyGuards() throws {
        let s = try scope(), source = try raw(), r = try CompletionSelectionRootRead(data: data(), taskIDs: ids(source), scope: s)
        XCTAssertEqual(r.scope, s); XCTAssertEqual(r.roots.map { $0.task.id }, ids(source)); XCTAssertEqual(r.roots.count, 3)
        XCTAssertEqual(r.guardBody["roots"]!.list.map { $0.object["task_id"]!.text }, ids(source))
        let body = String(decoding: try TaskfoldJSONEncoder().encode(r.guardBody), as: UTF8.self)
        for text in ["subtasks", "source_metadata", "title", "description", "attachments", "comments"] { XCTAssertFalse(body.contains("\"" + text + "\"")) }
        XCTAssertFalse(r.description.contains(s.account)); XCTAssertFalse(r.debugDescription.contains(r.roots[0].task.id))
    }
    func testOpaquePostgresNumbersAndDistinctUnicodeKeysSurviveClientRoundTrip() throws {
        let r = try read(), bytes = try TaskfoldJSONEncoder().encode(JSON.object(r.roots[0].task.fields)), text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("9007199254740993")); XCTAssertTrue(text.contains("1" + String(repeating: "0", count: 1000)))
        guard case .preserved = r.roots[0].task["source_metadata"] else { return XCTFail("Opaque metadata must remain exact") }
        let roundtrip = try TaskfoldJSONDecoder().decode([String: JSON].self, from: bytes)
        XCTAssertTrue(AuthoredValueComparison.exactJSON(.object(roundtrip), .object(r.roots[0].task.fields)))
    }
    func testRequestRefusesEmptyOversizedDuplicateMalformedAndNonCanonicalIDs() throws {
        let s = try scope(), id = try ids(raw())[0]
        for values in [[], Array(repeating: id, count: 33), [id,id], ["broken"], [id.uppercased()]] { XCTAssertThrowsError(try CompletionSelectionRootRead.request(taskIDs: values, scope: s)) }
        XCTAssertNoThrow(try CompletionSelectionRootRead.request(taskIDs: (0..<32).map { _ in UUID().uuidString.lowercased() }, scope: s))
    }
    func testEnvelopeRefusesWrongAccountProtocolUnknownKeysAndMissingRows() throws {
        let original = try raw()
        for (key,value) in [("account",JSON.string(UUID().uuidString.lowercased())),("protocol",.number(2)),("future",.bool(true)),("roots",.array([]))] {
            var bad = original;bad[key] = value;XCTAssertThrowsError(try read(bad),key)
        }
    }
    func testRootOrderDuplicatesAndExtraRowsCannotBeReinterpreted() throws {
        let original = try raw(), values = original["roots"]!.list
        for rows in [Array(values.reversed()), [values[0],values[0],values[2]], values+[values[0]]] { var bad = original;bad["roots"] = .array(rows);XCTAssertThrowsError(try read(bad)) }
    }
    func testBaselineMustMatchEverySourceIdentityAndCompletionValue() throws {
        let original = try raw()
        for key in CompletionSelectionRootRead.baselineKeys {
            let bad = mutateTask(original) { $0[key] = .string("changed") };XCTAssertThrowsError(try read(bad),key)
        }
        var bad = original, rows = bad["roots"]!.list, row = rows[0].object, baseline = row["baseline"]!.object
        baseline["future"] = .bool(true);row["baseline"] = .object(baseline);rows[0] = .object(row);bad["roots"] = .array(rows);XCTAssertThrowsError(try read(bad))
    }
    func testHashAndObservationShapeMustBeExact() throws {
        let original = try raw()
        for hash in [JSON.null,.string(""),.string(String(repeating:"A",count:64)),.string(String(repeating:"g",count:64)),.string(String(repeating:"0",count:63))] {
            var bad = original, values = bad["roots"]!.list, row = values[0].object;row["source_hash"] = hash;values[0] = .object(row);bad["roots"] = .array(values);XCTAssertThrowsError(try read(bad))
        }
        var bad = original, values = bad["roots"]!.list, row = values[0].object;row["unexpected"] = .bool(true);values[0] = .object(row);bad["roots"] = .array(values);XCTAssertThrowsError(try read(bad))
    }
    func testDuplicateKeysInEnvelopeOrTaskAndFractionalCountersAreRejected() throws {
        let original = try raw(), s = try scope(), source = String(decoding: try data(), as: UTF8.self)
        let duplicates = [source.replacingOccurrences(of: "\"protocol\": 1", with: "\"protocol\":1,\"protocol\":1"),
                          source.replacingOccurrences(of: "\"completed\": false", with: "\"completed\":false,\"completed\":false"),
                          source.replacingOccurrences(of: "\"completion_version\": 0", with: "\"completion_version\":0.1")]
        for bad in duplicates { XCTAssertNotEqual(bad,source);XCTAssertThrowsError(try CompletionSelectionRootRead(data: Data(bad.utf8), taskIDs: ids(original), scope: s)) }
    }
    func testRootAndEnvelopeSizeLimitsAreIndependent() throws {
        let original = try raw(), s = try scope()
        XCTAssertThrowsError(try CompletionSelectionRootRead(data: Data(repeating:32,count:CompletionSelectionRootRead.maximumBytes+1),taskIDs:ids(original),scope:s))
        let tooLarge = mutateTask(original) { $0["description"] = .string(String(repeating:"x",count:CompletionSelectionRootRead.maximumRootBytes)) }
        XCTAssertThrowsError(try read(tooLarge))
    }
    func testRootOnlyPreparationBindsTheOriginalSelectionAndRetainsNoOpGuards() throws {
        let s = try scope(), r = try read(scope:s), tasks = r.roots.map(\.task), projects = projects(tasks)
        let selection = try TaskListCompletionSelectionIntent(tasks: tasks, roots: tasks, projects: projects, scope: s, completed: true)
        let prepared = try r.prepare(selection, projects: projects, childReads: [:], current: s)
        XCTAssertEqual(prepared.members.count, 3);XCTAssertEqual(prepared.observations.count, 3);XCTAssertEqual(r.guardBody["roots"]!.list.count,3)
        let subset = try TaskListCompletionSelectionIntent(tasks: [tasks[0]], roots: tasks, projects: projects, scope: s, completed: true)
        XCTAssertThrowsError(try r.prepare(subset, projects: projects, childReads: [:], current: s))
    }
    func testPreparationCannotCrossWorkspaceAccessOrSession() throws {
        let s = try scope(), r = try read(scope:s), tasks = r.roots.map(\.task), p = projects(tasks)
        let selection = try TaskListCompletionSelectionIntent(tasks: tasks, roots: tasks, projects: p, scope:s, completed:true)
        for other in [ChildTaskFieldClientScope(account:s.account,origin:s.origin,workspace:UUID(),session:s.session,access:s.access),.init(account:s.account,origin:s.origin,workspace:s.workspace,session:UUID(),access:s.access),.init(account:s.account,origin:s.origin,workspace:s.workspace,session:s.session,access:UUID())] { XCTAssertThrowsError(try r.prepare(selection,projects:p,childReads:[:],current:other)) }
    }
    func testFreshRecurringSourceCannotSilentlyReplaceCapturedUserIntent() throws {
        let s = try scope(), r = try read(scope:s), tasks = r.roots.map(\.task), p = projects(tasks)
        let selection = try TaskListCompletionSelectionIntent(tasks:tasks,roots:tasks,projects:p,scope:s,completed:true)
        var changed = try raw(), rows = changed["roots"]!.list, row = rows[2].object, task = row["task"]!.object
        XCTAssertEqual(task["is_recurring"],.bool(true));task["title"] = .string("New successor content");row["task"] = .object(task);rows[2] = .object(row);changed["roots"] = .array(rows)
        let fresh = try read(changed,scope:s)
        XCTAssertThrowsError(try fresh.prepare(selection,projects:p,childReads:[:],current:s))
    }
    @MainActor private func backend() throws -> (Backend,ChildTaskFieldClientScope) {
        let s = try scope(), raw: [String:JSON] = ["access_token":.string("synthetic"),"refresh_token":.string("synthetic"),"expires_in":.number(3600),"user":.object(["id":.string(s.account)])]
        let session = try TaskfoldJSONDecoder().decode(Session.self,from:TaskfoldJSONEncoder().encode(raw))
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses=[RootReadHTTP.self]
        let backend = Backend(configuration:["URL":origin,"Key":"synthetic-public"],http:URLSession(configuration:config),session:session,persistSession:{_ in})
        return (backend,.init(account:s.account,origin:s.origin,workspace:s.workspace,session:backend.reminderSessionIncarnation,access:s.access))
    }
    private func requestBody(_ request: URLRequest) -> Data {
        if let bytes=request.httpBody{return bytes};var result=Data();guard let stream=request.httpBodyStream else{return result};stream.open();defer{stream.close()};var b=[UInt8](repeating:0,count:4096)
        while stream.hasBytesAvailable{let n=stream.read(&b,maxLength:b.count);if n<=0{break};result.append(contentsOf:b.prefix(n))};return result
    }
    @MainActor func testBackendUsesExactBoundedPrivateReadRequest() async throws {
        let (backend,s)=try backend(), data=try data(), ids=ids(try raw());defer{RootReadHTTP.handler=nil}
        RootReadHTTP.handler={request,pipe in
            XCTAssertEqual(request.url?.path,"/rest/v1/rpc/taskfold_read_completion_selection_roots");XCTAssertEqual(request.httpMethod,"POST");XCTAssertFalse(request.httpShouldHandleCookies);XCTAssertEqual(request.cachePolicy,.reloadIgnoringLocalCacheData);XCTAssertEqual(request.value(forHTTPHeaderField:"Cache-Control"),"no-store")
            XCTAssertEqual(try! TaskfoldJSONDecoder().decode([String:JSON].self,from:self.requestBody(request)),["_body":.object(try! CompletionSelectionRootRead.request(taskIDs:ids,scope:s))]);pipe.finish(200,data)
        }
        let result=try await backend.completionSelectionRoots(ids,scope:s);XCTAssertEqual(result.scope,s);XCTAssertEqual(result.roots.count,3)
    }
    @MainActor func testBackendRefusesStaleSessionAccountAndOriginBeforeHTTP() async throws {
        let (backend,s)=try backend(), ids=ids(try raw());defer{RootReadHTTP.handler=nil};RootReadHTTP.handler={_,_ in XCTFail("Stale read must never access network")}
        for bad in [ChildTaskFieldClientScope(account:s.account,origin:s.origin,workspace:s.workspace,session:UUID(),access:s.access),.init(account:UUID().uuidString.lowercased(),origin:s.origin,workspace:s.workspace,session:s.session,access:s.access),.init(account:s.account,origin:"https://other.test",workspace:s.workspace,session:s.session,access:s.access)] {
            do{_ = try await backend.completionSelectionRoots(ids,scope:bad);XCTFail("Stale read")}catch is CancellationError{}catch{XCTFail("Unexpected error: \(error)")}
        }
    }
    @MainActor func testBackendMapsPausedMissingAccessAndSessionRefusals() async throws {
        let (backend,s)=try backend(), ids=ids(try raw());defer{RootReadHTTP.handler=nil}
        for (status,code) in [(503,"PT503"),(403,"42501"),(404,"PGRST202"),(400,"54000"),(409,"PT409"),(401,"28000")] {
            RootReadHTTP.handler={_,pipe in pipe.finish(status,Data("{\"code\":\"\(code)\",\"message\":\"synthetic\"}".utf8))}
            do{_ = try await backend.completionSelectionRoots(ids,scope:s);XCTFail("Refusal must not return a read")}catch is AccountSessionAuthorizationRequired{XCTAssertEqual(code,"28000")}catch let failure as ChildTaskRecordFailure{XCTAssertEqual(failure,code=="54000" ? .oversized : code=="PT409" ? .review : .unavailable)}catch{XCTFail("Unexpected error \(error)")}
        }
    }
    @MainActor func testBackendRefusesDeclaredAndStreamingResponseOverflow() async throws {
        let (backend,s)=try backend(), ids=ids(try raw());defer{RootReadHTTP.handler=nil}
        for declared in [true,false] {
            RootReadHTTP.handler={_,pipe in pipe.finish(200,Data(repeating:32,count:declared ? 1:CompletionSelectionRootRead.maximumBytes+1),headers:declared ? ["Content-Length":String(CompletionSelectionRootRead.maximumBytes+1)]:[:])}
            do{_ = try await backend.completionSelectionRoots(ids,scope:s);XCTFail("Oversized response")}catch{}
        }
    }
    @MainActor func testBackendAcceptsAValidResponseAboveTheOlderChildReadLimit() async throws {
        let (backend,s)=try backend();var value=try raw(), rows=value["roots"]!.list
        for i in [0,1] {var row=rows[i].object,task=row["task"]!.object;task["description"] = .string(String(repeating:"x",count:1_100_000));row["task"] = .object(task);rows[i] = .object(row)}
        value["roots"] = .array(rows);let data=try TaskfoldJSONEncoder().encode(value);XCTAssertGreaterThan(data.count,ChildTaskRecordRead.maximumBytes);XCTAssertLessThan(data.count,CompletionSelectionRootRead.maximumBytes)
        defer{RootReadHTTP.handler=nil};RootReadHTTP.handler={_,pipe in pipe.finish(200,data)}
        let r=try await backend.completionSelectionRoots(ids(value),scope:s);XCTAssertEqual(r.roots.count,3)
    }
    @MainActor func testBackendRejectsLateReplyAfterSessionReplacement() async throws {
        for status in [200,503] {
            let (backend,s)=try backend(), data=try data(), ids=ids(try raw());defer{RootReadHTTP.handler=nil}
            let reply=status==200 ? data:Data("{\"code\":\"PT503\",\"message\":\"synthetic\"}".utf8)
            RootReadHTTP.handler={_,pipe in Task{@MainActor in
                let raw:[String:JSON] = ["access_token":.string("synthetic-next"),"refresh_token":.string("synthetic-next"),"expires_in":.number(3600),"user":.object(["id":.string(UUID().uuidString.lowercased())])]
                try! await backend.accept(TaskfoldJSONDecoder().decode(Session.self,from:TaskfoldJSONEncoder().encode(raw)));pipe.finish(status,reply)
            }}
            do{_ = try await backend.completionSelectionRoots(ids,scope:s);XCTFail("Late previous-account read or error")}catch is CancellationError{}catch{XCTFail("Unexpected late response: \(error)")}
        }
    }
}


extension CompletionSelectionRootReadTests {
    private func childRead(_ root: Record, scope: ChildTaskFieldClientScope) throws -> ChildTaskRecordRead {
        let context = try ChildTaskRecordContext(account:scope.account,origin:scope.origin,workspace:scope.workspace,session:scope.session,access:scope.access,snapshot:UUID(),root:root)
        let fields=root["subtasks"].list[0].object,key=fields["id"]!.text
        let raw:[String:JSON] = ["protocol":.number(1),"account":.string(scope.account),"task_id":.string(root.id),"task_generation":root["task_generation"],"project_id":root["project_id"],"projection_revision":.number(1),"root_kind":.string("array"),"records":.array([.object(["node_key":.string(key),"incarnation":.string(UUID().uuidString.lowercased()),"revision":.number(1),"parent_key":.null,"sibling_order":.number(0),"identity_path":.array([.string(key)]),"fields":.object(fields),"children_kind":.string("absent")])])]
        return try .init(data:TaskfoldJSONEncoder().encode(raw),context:context)
    }
    private func firstRootRead(scope: ChildTaskFieldClientScope) throws -> CompletionSelectionRootRead {
        var value=try raw();value["roots"] = .array(Array(value["roots"]!.list.prefix(1)))
        return try .init(data:TaskfoldJSONEncoder().encode(value),taskIDs:ids(value),scope:scope)
    }
    func testMixedRootAndChildPreparationUsesOneCoherentRootSnapshot() throws {
        let s=try scope(),r=try firstRootRead(scope:s),root=r.roots[0].task,p=projects([root])
        let child=try XCTUnwrap(TaskHierarchyIndex(roots:[root],projects:p,workspace:.init(account:s.account,generation:s.workspace)).items.last?.record)
        let selection=try TaskListCompletionSelectionIntent(tasks:[root,child],roots:[root],projects:p,scope:s,completed:true)
        let prepared=try r.prepare(selection,projects:p,childReads:[root.id:childRead(root,scope:s)],current:s)
        XCTAssertEqual(prepared.members.count,2);XCTAssertEqual(prepared.observations.count,2);XCTAssertEqual(r.guardBody["roots"]!.list.count,1)
        guard case .child(let command)=prepared.members[1] else{return XCTFail("Missing child command")};XCTAssertEqual(command.body["task_id"],.string(root.id))
    }
    func testMixedPreparationRejectsMissingForeignScopeOrDifferentChildSnapshots() throws {
        let s=try scope(),r=try firstRootRead(scope:s),root=r.roots[0].task,p=projects([root])
        let child=try XCTUnwrap(TaskHierarchyIndex(roots:[root],projects:p,workspace:.init(account:s.account,generation:s.workspace)).items.last?.record)
        let selection=try TaskListCompletionSelectionIntent(tasks:[root,child],roots:[root],projects:p,scope:s,completed:true)
        XCTAssertThrowsError(try r.prepare(selection,projects:p,childReads:[:],current:s))
        var different=root;different["description"] = .string("Different root observation")
        XCTAssertThrowsError(try r.prepare(selection,projects:p,childReads:[root.id:childRead(different,scope:s)],current:s))
        let other=ChildTaskFieldClientScope(account:s.account,origin:s.origin,workspace:s.workspace,session:s.session,access:UUID())
        XCTAssertThrowsError(try r.prepare(selection,projects:p,childReads:[root.id:childRead(root,scope:other)],current:s))
    }
    func testMixedPreparationKeepsAnIndependentChildBranchIncludingHeadingParents() throws {
        let s=try scope(),r=try firstRootRead(scope:s),root=r.roots[0].task,other=(try read(scope:s)).roots[1].task
        for heading in [false,true] {
            var parent=other;parent["is_heading"] = .bool(heading);let roots=[root,parent],p=projects(roots)
            let child=try XCTUnwrap(TaskHierarchyIndex(roots:[parent],projects:p,workspace:.init(account:s.account,generation:s.workspace)).items.last?.record)
            let selection=try TaskListCompletionSelectionIntent(tasks:[root,child],roots:roots,projects:p,scope:s,completed:true)
            let prepared=try r.prepare(selection,projects:p,childReads:[parent.id:childRead(parent,scope:s)],current:s)
            XCTAssertEqual(prepared.members.count,2);XCTAssertEqual(r.guardBody["roots"]!.list.count,1)
        }
    }
    func testMatchingBaselineCannotMakeInvalidRootFieldsAcceptable() throws {
        let original=try raw()
        for (key,value) in [("user_id",JSON.string("not-a-uuid")),("task_generation",.null),("project_id",.string("not-a-uuid")),("section_id",.string("not-a-uuid")),("is_heading",.bool(true)),("is_recurring",.string("true")),("completed",.null),("completion_version",.number(-1)),("completion_version",.number(9_007_199_254_740_991)),("completed_at",.string("2026-10-31T00:00:00Z"))] {
            var bad=original,rows=bad["roots"]!.list,row=rows[0].object,task=row["task"]!.object,baseline=row["baseline"]!.object
            task[key]=value;baseline[key]=value;row["task"] = .object(task);row["baseline"] = .object(baseline);rows[0] = .object(row);bad["roots"] = .array(rows)
            XCTAssertThrowsError(try read(bad),key)
        }
    }
}


extension CompletionSelectionRootReadTests {
    func testLegacyNullFlagsAreKeptAsAuthoredInSourceAndGuards() throws {
        var value=try raw(),rows=value["roots"]!.list,row=rows[0].object,task=row["task"]!.object,baseline=row["baseline"]!.object
        task["is_heading"] = .null;baseline["is_heading"] = .null;task["is_recurring"] = .null;baseline["is_recurring"] = .null
        row["task"] = .object(task);row["baseline"] = .object(baseline);rows[0] = .object(row);value["roots"] = .array(rows)
        let r=try read(value);XCTAssertEqual(r.roots[0].task["is_heading"],.null);XCTAssertEqual(r.roots[0].task["is_recurring"],.null)
        XCTAssertEqual(r.roots[0].guardBody["baseline"]!.object["is_heading"],.null);XCTAssertEqual(r.roots[0].guardBody["baseline"]!.object["is_recurring"],.null)
    }
}
