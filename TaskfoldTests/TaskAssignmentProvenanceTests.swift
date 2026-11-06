import XCTest
@testable import TaskfoldCore

final class TaskAssignmentProvenanceTests: XCTestCase {
    typealias Provenance = TaskAssignmentProvenance
    let owner = "f01dcafe-8200-4000-8000-000000000001"
    let member = "f01dcafe-8200-4000-8000-000000000002"
    let taskID = "f01dcafe-8200-4000-8000-000000000010"
    let generation = "f01dcafe-8200-4000-8000-000000000020"
    let event = "f01dcafe-8200-4000-8000-000000000030"
    let stamp = "2026-10-21T12:00:00Z"
    func task() -> Record {
        Record(["id":.string(taskID),"user_id":.string(owner),"title":.string("Handoff"),"assigned_to":.string(member),"task_generation":.string(generation)])
    }
    func row(node: String = "", path: [String] = []) -> Record {
        Record(["id":.string("f01dcafe-8200-4000-8000-000000000040"),"task_id":.string(taskID),"task_generation":.string(generation),"node_key":.string(node),"node_path":.array(path.map(JSON.string)),"assignee_id":.string(member),"actor_id":.string(owner),"event_id":.string(event),"assigned_at":.string(stamp),"origin":.string("recorded"),"active":.bool(true)])
    }
    var known: Provenance.Resolution { .known(actor:owner,event:event,recordedAt:TaskPlanning.instant(stamp)!) }
    func testConfirmedActorIsIndependentOfTaskAuthorAndAssignee() {
        var task = task(); task["user_id"] = .string(member)
        var row = row(); row["task_id"] = .string(taskID.uppercased()); row["actor_id"] = .string(owner.uppercased())
        XCTAssertEqual(Provenance.Catalog([row]).resolution(root:task),known)
        task["title"] = .string("Renamed"); task["completed"] = .bool(true)
        XCTAssertEqual(Provenance.Catalog([row]).resolution(root:task),known)
        row["actor_id"] = .string(member)
        XCTAssertNotEqual(Provenance.Catalog([row]),Provenance.Catalog([self.row()]),"Metadata participates in future query cache identity")
    }
    func testUnknownHistoryNeverUsesAuthorAssigneeOrUntrustedActor() {
        let task = task()
        XCTAssertEqual(Provenance.Catalog(nil).resolution(root:task),.unknown(.unavailable))
        XCTAssertEqual(Provenance.Catalog([]).resolution(root:task),.unknown(.legacy))
        for reason in [Provenance.Unknown.legacy,.system,.recurrence,.unsupported] {
            var row = row(); row["origin"] = .string(reason.rawValue)
            XCTAssertEqual(Provenance.Catalog([row]).resolution(root:task),.unknown(reason))
        }
        var row = row(); row["actor_id"] = .null
        XCTAssertEqual(Provenance.Catalog([row]).resolution(root:task),.unknown(.deletedActor))
        row["actor_id"] = .string("Task owner")
        XCTAssertEqual(Provenance.Catalog([row]).resolution(root:task),.unknown(.unsupported))
    }
    func testUnassignedIsDistinctFromMissingOrUnknownHistory() {
        for recipient in [JSON.null,.string("")] {
            var task = task(); task["assigned_to"] = recipient
            XCTAssertEqual(Provenance.Catalog(nil).resolution(root:task),.unassigned)
            XCTAssertEqual(Provenance.Catalog([row()]).resolution(root:task),.unassigned)
        }
        var task = task(); task["assigned_to"] = .number(3)
        XCTAssertEqual(Provenance.Catalog([row()]).resolution(root:task),.unknown(.unsupported))
    }
    func testIncarnationLegacyAndDuplicateRowsFailClosed() {
        var task = task(); task["task_generation"] = .string(UUID().uuidString)
        XCTAssertEqual(Provenance.Catalog([row()]).resolution(root:task),.unknown(.legacy))
        task["task_generation"] = .null
        var row = row(); row["task_generation"] = .string(Provenance.legacyGeneration)
        XCTAssertEqual(Provenance.Catalog([row]).resolution(root:task),known,"A genuine new assignment on a pre-migration task can be recorded")
        task["task_generation"] = .string(Provenance.legacyGeneration)
        XCTAssertEqual(Provenance.Catalog([row]).resolution(root:task),.unknown(.unsupported))
        XCTAssertEqual(Provenance.Catalog([self.row(),self.row()]).resolution(root:self.task()),.unknown(.ambiguous))
    }
    func testOfflineRecipientChangeAndMalformedCurrentRowsCannotReuseActor() throws {
        let row = row(); var task = task(); task["assigned_to"] = .string(owner)
        XCTAssertEqual(Provenance.Catalog([row]).resolution(root:task),.unknown(.stale))
        for (field,value) in [("active",JSON.bool(false)),("node_path",.array([.string("moved")])),("event_id",.string("bad")),("assigned_at",.string("bad")),("origin",.string("future")),("node_path",.array([.number(2)]))] {
            var bad = row; bad[field] = value
            let result = Provenance.Catalog([bad]).resolution(root:self.task())
            if case .unknown = result {} else { XCTFail("Malformed \(field) became confirmed") }
        }
        let snapshot = Snapshot(tables:["tasks":[task],Provenance.table:[row]])
        let saved = try JSONDecoder().decode(Snapshot.self,from:JSONEncoder().encode(snapshot))
        XCTAssertEqual(Provenance.Catalog(saved.tables[Provenance.table]).resolution(root:saved.tables["tasks"]![0]),.unknown(.stale))
    }
    func testNestedPathsAreCaseSensitiveAndOwnAssignmentDoesNotInherit() throws {
        var task = task()
        task["subtasks"] = .array([.object(["id":.string("A"),"title":.string("Upper"),"assigned_to":.string(member)]),.object(["id":.string("a"),"title":.string("Lower")])])
        let index = try TaskHierarchyIndex(roots:[task],projects:[],workspace:WorkspaceBinding(account:owner,generation:UUID()))
        let upper = try XCTUnwrap(index.items.first(where:{$0.path == ["A"]}))
        let lower = try XCTUnwrap(index.items.first(where:{$0.path == ["a"]}))
        let catalog = Provenance.Catalog([row(node:"A",path:["A"])])
        XCTAssertEqual(catalog.resolution(item:upper),known)
        XCTAssertEqual(catalog.resolution(item:lower),.unassigned)
        var moved = row(node:"A",path:["branch","A"])
        XCTAssertEqual(Provenance.Catalog([moved]).resolution(item:upper),.unknown(.stale))
        moved["node_key"] = .string("a")
        XCTAssertEqual(Provenance.Catalog([moved]).resolution(item:upper),.unknown(.legacy))
    }
    @MainActor func testGenericWritesCannotForgeReadOnlyHistoryAndPortableFilesExcludeIt() async throws {
        let row = row(); let original = Snapshot(tables:["tasks":[task()],Provenance.table:[row]])
        let backend = Backend(configuration:["URL":"https://assignment.test","Key":"public"],session:nil,persistSession:{ _ in })
        for method in ["POST","PATCH","DELETE"] {
            let change = Mutation(table:Provenance.table,recordID:row.id,method:method,fields:["actor_id":.string(member)])
            var snapshot = original; snapshot.apply(change)
            XCTAssertEqual(snapshot,original)
            do { _ = try await backend.send(change); XCTFail("Read-only mutation was sent") }
            catch { XCTAssertEqual(error.localizedDescription,"Activity history is read-only.") }
        }
        let backup = WorkspaceBackup.make(original,account:owner)
        XCTAssertNil(backup.tables[Provenance.table])
        let decoded = try WorkspaceBackup.read(backup.data())
        XCTAssertNil(decoded.tables[Provenance.table]); XCTAssertEqual(decoded.tables["tasks"],original.tables["tasks"])
        var forged = backup; forged.tables[Provenance.table] = [row]
        XCTAssertThrowsError(try WorkspaceBackup.read(forged.data()),"A portable file cannot certify an actor")
    }
}

extension TaskAssignmentProvenanceTests {
    func testCloudAssignmentCycleStaysUnconfirmedThroughAcknowledgementsAndRelaunch() throws {
        var snapshot = Snapshot(tables:["tasks":[task()],Provenance.table:[row()]])
        let toOwner = Mutation(table:"tasks",recordID:taskID,method:"PATCH",fields:["assigned_to":.string(owner)])
        let toMember = Mutation(table:"tasks",recordID:taskID,method:"PATCH",fields:["assigned_to":.string(member)])
        snapshot.apply(toOwner); snapshot.pending.append(toOwner)
        snapshot.apply(toMember); snapshot.pending.append(toMember)
        XCTAssertEqual(Provenance.Catalog(snapshot.tables[Provenance.table]).resolution(root:snapshot.tables["tasks"]![0]),.unknown(.pending))
        snapshot = try JSONDecoder().decode(Snapshot.self,from:JSONEncoder().encode(snapshot))
        var saved = task(); saved["assigned_to"] = .string(owner)
        snapshot.acknowledge(toOwner,saved:saved); snapshot.acknowledge(toMember,saved:task())
        XCTAssertTrue(snapshot.pending.isEmpty)
        XCTAssertEqual(Provenance.Catalog(snapshot.tables[Provenance.table]).resolution(root:task()),.unknown(.pending))
        var confirmed = row(); confirmed["event_id"] = .string(UUID().uuidString)
        snapshot.mergeRemote(["tasks":[task()],Provenance.table:[confirmed]])
        guard case .known(_,let event,_) = Provenance.Catalog(snapshot.tables[Provenance.table]).resolution(root:task()) else { return XCTFail("Fresh server assignment missing") }
        XCTAssertNotEqual(event,self.event)
    }
    func testFreshTasksCannotReuseMissingCatalogAndPendingReplayInvalidatesFreshMetadata() {
        var snapshot = Snapshot(tables:["tasks":[task()],Provenance.table:[row()]])
        snapshot.mergeRemote(["tasks":[task()]])
        XCTAssertNil(snapshot.tables[Provenance.table]); XCTAssertFalse(Provenance.Catalog(snapshot.tables[Provenance.table]).available)
        snapshot.pending = [Mutation(table:"tasks",recordID:taskID,method:"PATCH",fields:["assigned_to":.string(owner)]),Mutation(table:"tasks",recordID:taskID,method:"PATCH",fields:["assigned_to":.string(member)])]
        snapshot.mergeRemote(["tasks":[task()],Provenance.table:[row()]])
        XCTAssertEqual(Provenance.Catalog(snapshot.tables[Provenance.table]).resolution(root:task()),.unknown(.pending))
    }
    func testNewUnconfirmedAssignmentsAreNotMisclassifiedAsLegacyUnknownAndLocalActionsStillRecord() {
        var snapshot = Snapshot(tables:[Provenance.table:[]])
        let create = Mutation(table:"tasks",recordID:taskID,method:"POST",fields:task().fields)
        snapshot.apply(create)
        let pending = Provenance.Catalog(snapshot.tables[Provenance.table])
        XCTAssertEqual(pending.resolution(root:task()),.unknown(.pending))
        XCTAssertFalse(FilterRule.predicate("assigned_by","unknown").matches(task(),today:"2026-10-21",userID:owner,labels:[],timeZone:"UTC",assignments:pending))
        var before = task(); before["assigned_to"] = .null
        before["subtasks"] = .array([.object(["id":.string("child"),"title":.string("Child")])])
        var after = before; after["subtasks"] = .array([.object(["id":.string("child"),"title":.string("Child"),"assigned_to":.string(member)])])
        snapshot = Snapshot(tables:["tasks":[before],Provenance.table:[]])
        snapshot.apply(Mutation(table:"tasks",recordID:taskID,method:"PATCH",fields:["subtasks":after["subtasks"]]))
        XCTAssertEqual(snapshot.tables[Provenance.table]?.first?.string("origin"),"pending")
        snapshot = Snapshot(tables:[Provenance.table:[]]); snapshot.apply(create)
        Provenance.recordLocal(create,before:nil,after:task(),snapshot:&snapshot,account:"local")
        guard case .known(let actor,_,_) = Provenance.Catalog(snapshot.tables[Provenance.table],localAccount:"local").resolution(root:task()) else { return XCTFail("Local creation retained a cloud pending marker") }
        XCTAssertEqual(actor,"local")
    }
    func testCaseOnlyRecipientSpellingAndEmptyClearsAreNotNewAssignments() {
        var before = task(), after = task(); after["assigned_to"] = .string(member.uppercased())
        var snapshot = Snapshot(tables:["tasks":[before],Provenance.table:[row()]])
        snapshot.apply(Mutation(table:"tasks",recordID:taskID,method:"PATCH",fields:["assigned_to":after["assigned_to"]]))
        XCTAssertEqual(Provenance.Catalog(snapshot.tables[Provenance.table]).resolution(root:after),known)
        snapshot = Snapshot()
        let create = Mutation(table:"tasks",recordID:taskID,method:"POST",fields:before.fields)
        Provenance.recordLocal(create,before:nil,after:before,snapshot:&snapshot,account:"local")
        let original = snapshot.tables[Provenance.table]
        Provenance.recordLocal(create,before:before,after:after,snapshot:&snapshot,account:"local")
        XCTAssertEqual(snapshot.tables[Provenance.table],original)
        before["assigned_to"] = .string(""); after["assigned_to"] = .null; snapshot = Snapshot()
        Provenance.recordLocal(create,before:before,after:after,snapshot:&snapshot,account:"local")
        XCTAssertNil(snapshot.tables[Provenance.table])
    }
    func testLocalWorkspaceCapturesOnlyRealActionsAndSurvivesUndoStyleCycles() throws {
        var t = task(); t["assigned_to"] = .string("local"); var snapshot = Snapshot()
        let create = Mutation(table:"tasks",recordID:taskID,method:"POST",fields:t.fields)
        snapshot.apply(create); Provenance.recordLocal(create,before:nil,after:t,snapshot:&snapshot,account:"local")
        let first = Provenance.Catalog(snapshot.tables[Provenance.table],localAccount:"local").resolution(root:t)
        guard case .known(let actor,let event,_) = first else { return XCTFail("Local action unrecorded") }
        XCTAssertEqual(actor,"local")
        XCTAssertEqual(Provenance.Catalog(snapshot.tables[Provenance.table]).resolution(root:t),.unknown(.unsupported),"A cloud reader cannot certify a local alias")
        XCTAssertEqual(Provenance.Catalog(snapshot.tables[Provenance.table],localAccount:"another").resolution(root:t),.unknown(.unsupported))
        var renamed = t; renamed["title"] = .string("Renamed")
        Provenance.recordLocal(Mutation(table:"tasks",recordID:taskID,method:"PATCH",fields:["title":renamed["title"]]),before:t,after:renamed,snapshot:&snapshot,account:"local")
        XCTAssertEqual(Provenance.Catalog(snapshot.tables[Provenance.table],localAccount:"local").resolution(root:renamed),first)
        var unassigned = renamed; unassigned["assigned_to"] = .null
        Provenance.recordLocal(Mutation(table:"tasks",recordID:taskID,method:"PATCH",fields:["assigned_to":.null]),before:renamed,after:unassigned,snapshot:&snapshot,account:"local")
        Provenance.recordLocal(Mutation(table:"tasks",recordID:taskID,method:"PATCH",fields:["assigned_to":.string("local")]),before:unassigned,after:renamed,snapshot:&snapshot,account:"local")
        let saved = try JSONDecoder().decode(Snapshot.self,from:JSONEncoder().encode(snapshot))
        guard case .known(let currentActor,let currentEvent,_) = Provenance.Catalog(saved.tables[Provenance.table],localAccount:"local").resolution(root:renamed) else { return XCTFail("Local reassignment missing") }
        XCTAssertEqual(currentActor,"local"); XCTAssertNotEqual(currentEvent,event)
        XCTAssertNil(WorkspaceBackup.make(saved,account:"local").tables[Provenance.table])
    }
    func testLocalNestedMovesAndRemovalUndoPreserveEventButLegacyNormalizationDoesNotInventOne() throws {
        var t = task(); t["assigned_to"] = .null
        t["subtasks"] = .array([.object(["id":.string("child"),"title":.string("Child"),"assigned_to":.string("local")]),.object(["id":.string("branch"),"title":.string("Branch")])])
        var snapshot = Snapshot(); let create = Mutation(table:"tasks",recordID:taskID,method:"POST",fields:t.fields)
        Provenance.recordLocal(create,before:nil,after:t,snapshot:&snapshot,account:"local")
        let original = try XCTUnwrap(snapshot.tables[Provenance.table]?.first { $0.string("node_key") == "child" })
        var moved = t; moved["subtasks"] = .array([.object(["id":.string("branch"),"title":.string("Branch"),"subtasks":.array([t["subtasks"].list[0]])])])
        let change = Mutation(table:"tasks",recordID:taskID,method:"PATCH",fields:["subtasks":moved["subtasks"]])
        Provenance.recordLocal(change,before:t,after:moved,snapshot:&snapshot,account:"local")
        var removed = moved; removed["subtasks"] = .array([])
        Provenance.recordLocal(change,before:moved,after:removed,snapshot:&snapshot,account:"local")
        Provenance.recordLocal(change,before:removed,after:moved,snapshot:&snapshot,account:"local")
        let restored = try XCTUnwrap(snapshot.tables[Provenance.table]?.first { $0.string("node_key") == "child" })
        XCTAssertEqual(restored["event_id"],original["event_id"]); XCTAssertEqual(restored["node_path"],.array([.string("branch"),.string("child")])); XCTAssertTrue(restored["active"].flag)
        var legacy = t; legacy["subtasks"] = .array([.object(["title":.string("Legacy"),"assigned_to":.string("local")])])
        snapshot = Snapshot(); Provenance.recordLocal(change,before:legacy,after:t,snapshot:&snapshot,account:"local")
        XCTAssertEqual(snapshot.tables[Provenance.table]?.first { $0.string("node_key") == "child" }?.string("origin"),"legacy")
        var recurring = t; recurring["recurrence_parent_id"] = .string(UUID().uuidString)
        snapshot = Snapshot(); Provenance.recordLocal(create,before:nil,after:recurring,snapshot:&snapshot,account:"local")
        XCTAssertEqual(snapshot.tables[Provenance.table]?.first { $0.string("node_key") == "child" }?.string("origin"),"recurrence")
    }
    func testParserStrictRoundTripNamesAndNoCaptureAssigner() throws {
        let context = FilterContext(userID:owner,people:[Record(["id":.string(member),"display_name":.string("Morgan Lee")])],assignments:.init([row()]))
        for expression in ["assigned-by:me","assigned by:others","assigned-by:unknown","assigned-by:\"Morgan Lee\"","NOT assigned-by:me", "assigned-by:unknown OR assigned-by:me"] {
            var parser = try FilterParser(expression,context:context); let rule = try parser.parse()
            try rule.validate(in:context)
            var roundTrip = try FilterParser(rule.expression(in:context),context:context)
            XCTAssertEqual(try roundTrip.parse(),rule); XCTAssertEqual(try FilterRule(document:rule.document),rule)
            XCTAssertTrue(rule.usesAssignmentHistory); XCTAssertTrue(rule.captureDefaults(in:context,today:"2026-10-21").isEmpty)
        }
        for value in ["", "unassigned", "someone", "ME"] { XCTAssertThrowsError(try FilterRule(document:FilterRule.predicate("assigned_by",value).document)) }
        XCTAssertThrowsError(try FilterRule.predicate("assigned_by","me").validate(in:FilterContext(userID:owner)))
        var unsupported = FilterRule.predicate("assigned_by","me").document.object; unsupported["version"] = .number(2)
        XCTAssertThrowsError(try FilterRule(document:.object(unsupported)))
        XCTAssertEqual(FilterRule.predicate("assigned_by",member).sectionTitle(in:context),"Assigned by Morgan Lee")
    }
    func testUnknownAuthorThreeStateLogicNegationAndIndependentQueries() {
        func matches(_ rule: FilterRule,_ catalog: Provenance.Catalog = .init([])) -> Bool { rule.matches(task(),today:"2026-10-21",userID:owner,labels:[],timeZone:"UTC",assignments:catalog) }
        let me = FilterRule.predicate("assigned_by","me"), unknown = FilterRule.predicate("assigned_by","unknown"), all = FilterRule.predicate("all","")
        XCTAssertFalse(matches(me)); XCTAssertFalse(matches(.not(me))); XCTAssertTrue(matches(unknown))
        XCTAssertFalse(matches(.not(unknown))); XCTAssertTrue(matches(.or([me,unknown])))
        XCTAssertTrue(matches(.or([me,all]))); XCTAssertFalse(matches(.not(.or([me,all]))))
        XCTAssertFalse(matches(.and([me,all]))); XCTAssertFalse(matches(.not(.and([me,all]))))
        XCTAssertTrue(matches(.not(.and([me,.not(all)]))))
        XCTAssertFalse(matches(.or([me,all]),.init(nil)),"An unread catalog is not known empty")
        XCTAssertTrue(matches(.sections([me,all]),.init(nil)),"Independent safe sections retain their own scope")
        XCTAssertTrue(matches(me,.init([row()]))); XCTAssertFalse(matches(.predicate("assigned_by","others"),.init([row()])))
        var other = row(); other["actor_id"] = .string(member)
        XCTAssertTrue(matches(.not(me),.init([other]))); XCTAssertTrue(matches(.predicate("assigned_by","others"),.init([other])))
        for origin in ["pending","unsupported"] {
            var row = row(); row["origin"] = .string(origin)
            XCTAssertFalse(matches(unknown,.init([row]))); XCTAssertFalse(matches(.not(unknown),.init([row])))
        }
        var unassigned = task(); unassigned["assigned_to"] = .null
        XCTAssertTrue(FilterRule.not(me).matches(unassigned,today:"2026-10-21",userID:owner,labels:[],timeZone:"UTC",assignments:.init([])))
    }
    func testCatalogHashCacheAndNestedQueryGroupingUseCurrentEvidence() throws {
        var childRoot = task(); childRoot["assigned_to"] = .null
        childRoot["subtasks"] = .array([.object(["id":.string("child"),"title":.string("Nested handoff"),"assigned_to":.string(member)])])
        let childRow = row(node:"child",path:["child"])
        XCTAssertEqual(Provenance.Catalog([row(),childRow]),Provenance.Catalog([childRow,row()]))
        XCTAssertEqual(Set([Provenance.Catalog([row(),childRow]),Provenance.Catalog([childRow,row()])]).count,1)
        let rule = FilterRule.and([.predicate("subtask",""),.predicate("assigned_by","me")])
        let cache = TaskCache(); cache.update([childRoot])
        var query = TaskQuery(scope:.all,filter:rule,filterAssignments:.init([childRow]),userID:owner,timeZone:"UTC")
        XCTAssertEqual(cache.matching(query).map(\.title),["Nested handoff"])
        XCTAssertEqual(cache.matching(query).count,1); let computations = cache.computationCount
        var changed = childRow; changed["actor_id"] = .string(member); changed["event_id"] = .string(UUID().uuidString)
        query.filterAssignments = .init([changed]); XCTAssertTrue(cache.matching(query).isEmpty); XCTAssertEqual(cache.computationCount,computations+1)
        let context = FilterContext(userID:owner,assignments:.init([childRow]))
        let records = try cache.hierarchyCandidates(for:rule,projects:[],userID:owner)
        let groups = TaskGrouping.queryGroups(records,rule:.sections([rule,.predicate("assigned_by","unknown")]),by:"none",context:context,today:"2026-10-21",timeZone:"UTC")
        XCTAssertEqual(groups.first?.tasks.map(\.title),["Nested handoff"])
    }
    func testWidgetMembershipOmitsRawActorsAndBecomesUnavailableWithoutCatalog() throws {
        let viewID = "f01dcafe-8200-4000-8000-000000000050"
        let rule = FilterRule.predicate("assigned_by","others")
        let view = Record(["id":.string(viewID),"user_id":.string(owner),"name":.string("Handoffs"),"query_ast":rule.document])
        var t = task(); t["assigned_to"] = .string(owner)
        var row = row(); row["actor_id"] = .string(member); row["assignee_id"] = .string(owner)
        let payload = WidgetProjection.payload(tasks:[t],projects:[],account:owner,savedViews:[view],assignments:.init([row]))
        let list = try XCTUnwrap(payload["lists"]?.list.first { $0.object["recordID"] == .string(viewID) })
        XCTAssertFalse(list.object["invalid"]!.flag); XCTAssertTrue(list.object["days"]!.object.values.contains { $0.list.contains(.string(taskID)) })
        let text = String(data:try JSONEncoder().encode(payload),encoding:.utf8)!
        XCTAssertFalse(text.contains(member)); XCTAssertFalse(text.contains("actor_id")); XCTAssertFalse(text.contains("assigned_at"))
        let unavailable = WidgetProjection.payload(tasks:[t],projects:[],account:owner,savedViews:[view])
        XCTAssertTrue(unavailable["lists"]!.list.first { $0.object["recordID"] == .string(viewID) }!.object["invalid"]!.flag)
    }
    @MainActor func testOptionalHTTPHistoryReadDistinguishesUnavailableFromEmptyAndDiscardsAccountCycle() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AuthTransportTests.Stub.self]
        let session = try JSONDecoder().decode(Session.self,from:Data(("{\"access_token\":\"test\",\"refresh_token\":\"refresh\",\"expires_in\":3600,\"user\":{\"id\":\""+owner+"\"}}").utf8))
        let backend = Backend(configuration:["URL":"https://native-auth.test","Key":"public"],http:URLSession(configuration:configuration),session:session,persistSession:{ _ in })
        defer { AuthTransportTests.Stub.handler = nil }
        AuthTransportTests.Stub.handler = { request in XCTAssertEqual(request.url?.path,"/rest/v1/task_assignment_provenance"); return (200,Data("[]".utf8)) }
        let empty = await backend.assignmentProvenanceRows(); XCTAssertEqual(empty,[])
        for status in [403,404,500] {
            AuthTransportTests.Stub.handler = { _ in (status,Data("{\"message\":\"Unavailable\"}".utf8)) }
            let unavailable = await backend.assignmentProvenanceRows(); XCTAssertNil(unavailable)
        }
        let page = try JSONEncoder().encode(Array(repeating:row(),count:500))
        var pages = 0
        AuthTransportTests.Stub.handler = { request in
            pages += 1
            if pages == 1 { return (200,page) }
            XCTAssertTrue(request.url!.query!.contains("offset=500"))
            return (500,Data("{\"message\":\"Page unavailable\"}".utf8))
        }
        let incomplete = await backend.assignmentProvenanceRows(); XCTAssertNil(incomplete); XCTAssertEqual(pages,2)
        let started = expectation(description:"Assignment HTTP started"), gate = DispatchSemaphore(value:0)
        AuthTransportTests.Stub.handler = { _ in started.fulfill(); _ = gate.wait(timeout:.now()+10); return (200,Data("[]".utf8)) }
        let read = Task { await backend.assignmentProvenanceRows() }
        await fulfillment(of:[started],timeout:5)
        var other = session; other.user.id = member
        try await backend.accept(other); try await backend.accept(session); gate.signal()
        let stale = await read.value; XCTAssertNil(stale)
    }
    func testFiveThousandAssignmentsCacheAndRemoteActorChange() {
        var tasks:[Record] = [], rows:[Record] = []
        for i in 0..<5000 {
            let id = WorkspaceBackup.stableID("assignment-perf",String(i))
            var task = task(); task["id"] = .string(id); tasks.append(task)
            var row = row(); row["id"] = .string(WorkspaceBackup.stableID("assignment-row",String(i))); row["task_id"] = .string(id); rows.append(row)
        }
        let start = Date(), cache = TaskCache(); cache.update(tasks)
        var query = TaskQuery(scope:.all,filter:.predicate("assigned_by","me"),filterAssignments:.init(rows),userID:owner)
        XCTAssertEqual(cache.matching(query).count,5000); XCTAssertEqual(cache.matching(query).count,5000); XCTAssertEqual(cache.computationCount,1)
        rows[0]["actor_id"] = .string(member); rows[0]["event_id"] = .string(UUID().uuidString)
        query.filterAssignments = .init(rows)
        XCTAssertEqual(cache.matching(query).count,4999); XCTAssertEqual(cache.computationCount,2)
        print("ASSIGNMENT_5000_CATALOG_AND_MATCH_SECONDS=\(Date().timeIntervalSince(start))")
    }
}
